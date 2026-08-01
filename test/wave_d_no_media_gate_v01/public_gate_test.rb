# frozen_string_literal: true

require_relative "test_helper"

class PublicGateTest < Minitest::Test
  include WaveDNoMediaGateTestSupport

  def test_exact_public_entrypoint
    assert_equal 0, Gate.method(:validate!).arity
    assert Gate.validate!
  end

  def test_all_nine_package_blob_bindings
    root = File.join(ROOT, ".github/gff/wave_d_no_media_gate/v01/package")
    expected = {
      "wave2_private_gate_manifest_v01.json" => "7464e001733b3eaba29d65bc2ee9c0f0f2f60dfd",
      "sanitized_fixture_bundle_v01.json" => "ac3a040ca9a606de6ffb7637ac091965d705a903",
      "wave2_private_validation_receipt_v01.json" => "24e7b40f45af91fe096121e6cc7c20743c6de2d7",
      "public_runner_handoff_manifest_v01.json" => "6f3012952c6453712d0aaa36b95f0501db930a54",
      "mutation_catalog_v01.json" => "d13e067480df3011993c7498c081c2bd195373fc",
      "schemas/wave2_private_gate_manifest_v01.schema.json" => "2ce5733ffa3f75880f85fbd718c5d5cea4ae5541",
      "schemas/sanitized_fixture_bundle_v01.schema.json" => "7b39b8154f627077f03b421cf45b399d2c76c38f",
      "schemas/wave2_private_validation_receipt_v01.schema.json" => "133e4684361eb8b080c834d058759a96ce95cf24",
      "schemas/public_runner_handoff_manifest_v01.schema.json" => "45ba8f879715a88377ce9387f822479412c8d08f"
    }
    expected.each do |relative, blob|
      bytes = File.binread(File.join(root, relative))
      actual = Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0#{bytes}")
      assert_equal blob, actual, relative
    end
  end

  def test_primary_sha256_bindings
    root = File.join(ROOT, ".github/gff/wave_d_no_media_gate/v01/package")
    assert_equal "d6a4ffa47d4ea72a05954b03deaf411bd86d68671be377add30b8b50e866d3ae", Digest::SHA256.file(File.join(root, "wave2_private_gate_manifest_v01.json")).hexdigest
    assert_equal "ba22a801b1ed87c959dbb451a4114d440a5881648237753faa6e12cafcf3d0a7", Digest::SHA256.file(File.join(root, "sanitized_fixture_bundle_v01.json")).hexdigest
    assert_equal "7fcf4939bd899e31cf3b396e6ca8cf15d03cfcde9c05f8f1c9d1dc02f9ca1279", Digest::SHA256.file(File.join(root, "wave2_private_validation_receipt_v01.json")).hexdigest
  end

  def test_ordered_mutation_matrix_has_49_rows
    docs, = fresh_documents
    rows = docs.fetch("catalog").fetch("mutations")
    assert_equal 49, rows.length
    assert_equal rows.map { |row| row.values_at("mutation_id", "error_code") }, docs.fetch("receipt").fetch("negative_mutations").map { |row| row.values_at("mutation_id", "error_code") }
  end

  def test_closed_schema_documents_validate
    _, schemas = fresh_documents
    schemas.each_value { |schema| assert Gate.send(:__schema_definition_for_test__, schema) }
  end

  def test_zero_media_and_synthetic_only
    docs, = fresh_documents
    fixture = docs.fetch("fixture")
    assert_equal false, fixture.fetch("contains_media_bytes")
    assert_equal false, fixture.fetch("contains_private_material")
    fixture.fetch("records").each do |record|
      assert_match(/\ASYNTHETIC_STORY_PLACEHOLDER_\d+\z/, record.fetch("story_placeholder"))
      assert_equal 0, record.dig("zero_media", "media_asset_count")
      assert_equal false, record.dig("zero_media", "media_bytes_present")
      assert_empty record.dig("zero_media", "external_asset_locators")
    end
  end

  def test_execution_authority_is_absent
    docs, = fresh_documents
    handoff = docs.fetch("handoff")
    %w[workflow_dispatch_authority media_execution_authority paid_execution_authority private_repository_write_authority reverse_authority].each do |key|
      assert_equal false, handoff.fetch(key)
    end
    receipt = docs.fetch("receipt")
    assert_equal false, receipt.fetch("workflow_dispatched")
    assert_equal 0, receipt.fetch("provider_calls")
    assert_equal 0, receipt.fetch("paid_provider_calls")
    assert_equal 0, receipt.fetch("media_execution")
  end

  def test_embedded_runner_and_private_authority
    docs, = fresh_documents
    assert_equal "f056424c1ba40c044cdc31ee38b6fe441e2ec8d3", docs.dig("handoff", "public_runner_main_sha")
    assert_equal "f056424c1ba40c044cdc31ee38b6fe441e2ec8d3", docs.dig("receipt", "validated_public_runner_main_sha")
    assert_equal "be76c8be95fa61d175c4c99ea16b4bf670510560", docs.dig("handoff", "frozen_private_source_sha")
  end

  def test_environment_and_argv_do_not_supply_authority
    old_env = ENV["PUBLIC_RUNNER_MAIN_SHA"]
    old_argv = ARGV.dup
    ENV["PUBLIC_RUNNER_MAIN_SHA"] = "0" * 40
    ARGV.replace(["--public-runner-main", "0" * 40])
    assert Gate.validate!
  ensure
    old_env.nil? ? ENV.delete("PUBLIC_RUNNER_MAIN_SHA") : ENV["PUBLIC_RUNNER_MAIN_SHA"] = old_env
    ARGV.replace(old_argv)
  end

  def test_caller_cannot_pass_authority_or_config
    assert_raises(ArgumentError) { Gate.validate!(public_runner_main: "0" * 40) }
  end

  def test_runtime_constant_shadowing_cannot_override_authority
    Gate.const_set(:PUBLIC_RUNNER_MAIN_SHA, "0" * 40)
    Gate.const_set(:FROZEN_PRIVATE_SOURCE_SHA, "1" * 40)
    Gate.const_set(:PACKAGE_ROOT, "/tmp/foreign")
    Gate.const_set(:CONFIG, {"allow" => true})
    assert Gate.validate!
  ensure
    %i[PUBLIC_RUNNER_MAIN_SHA FROZEN_PRIVATE_SOURCE_SHA PACKAGE_ROOT CONFIG].each do |name|
      Gate.send(:remove_const, name) if Gate.const_defined?(name, false)
    end
  end

  def test_no_network_or_process_execution_surface
    source = File.read(VALIDATOR)
    refute_match(/Net::HTTP|OpenURI|TCPSocket|UDPSocket|Kernel\.system|Open3|IO\.popen|`/, source)
    refute_match(/ENV\[|ARGV|git merge-base|rev-list|ancestor|fallback|attr_writer|attr_accessor/, source)
  end
end
