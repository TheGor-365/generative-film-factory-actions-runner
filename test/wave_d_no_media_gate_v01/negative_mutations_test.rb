# frozen_string_literal: true

require_relative "test_helper"

class NegativeMutationsTest < Minitest::Test
  include WaveDNoMediaGateTestSupport

  MUTATION_CODES = [
    ["missing_wave2_lane", "missing_lane"],
    ["extra_undeclared_member", "unexpected_member"],
    ["wrong_merge_sha", "wrong_merge_sha"],
    ["wrong_blob_sha", "wrong_blob_sha"],
    ["recomputed_content_hash_with_stale_authority", "wrong_merge_sha"],
    ["cross_lane_artifact_substitution", "cross_lane_artifact_substitution"],
    ["private_story_insertion", "private_story_material"],
    ["prompt_insertion", "prompt_material"],
    ["absolute_private_path", "absolute_or_private_path"],
    ["secret_like_value", "secret_like_value"],
    ["provider_response", "provider_response_material"],
    ["binary_or_base64_media", "binary_or_base64_media"],
    ["data_url", "data_url"],
    ["q0_placeholder_as_production_media", "q0_production_media"],
    ["public_runner_sha_drift", "public_runner_sha_drift"],
    ["frozen_private_sha_drift", "frozen_private_sha_drift"],
    ["workflow_dispatch_authority_injection", "workflow_dispatch_authority"],
    ["media_execution_authority_injection", "media_execution_authority"],
    ["paid_authority_injection", "paid_execution_authority"],
    ["reverse_authority_injection", "reverse_authority"],
    ["receipt_empty_checks_rebound", "receipt_check_set"],
    ["receipt_reduced_checks_rebound", "receipt_check_set"],
    ["receipt_non_string_pass_rebound", "receipt_check_set"],
    ["mutation_duplicate_id_rebound", "mutation_matrix"],
    ["mutation_missing_id_rebound", "mutation_matrix"],
    ["mutation_unknown_id_rebound", "mutation_matrix"],
    ["mutation_error_code_mismatch_rebound", "mutation_matrix"],
    ["mutation_order_changed_rebound", "mutation_matrix"],
    ["handoff_semantics_empty_rebound", "handoff_validation_semantics"],
    ["handoff_semantics_substituted_rebound", "handoff_validation_semantics"],
    ["handoff_semantics_order_changed_rebound", "handoff_validation_semantics"],
    ["receipt_integer_float_rebound", "public_runner_writes"],
    ["fixture_integer_float_rebound", "media_asset_count"],
    ["nested_boolean_integer_rebound", "required_for_gate"],
    ["schema_required_key_rebound", "schema_required"],
    ["schema_exact_type_rebound", "schema_type"],
    ["schema_const_rebound", "schema_const"],
    ["schema_enum_rebound", "schema_enum"],
    ["schema_minimum_rebound", "schema_minimum"],
    ["schema_maximum_rebound", "schema_maximum"],
    ["schema_array_cardinality_rebound", "schema_max_items"],
    ["schema_item_rebound", "schema_type"],
    ["schema_nested_closure_rebound", "schema_additional_property"],
    ["schema_additional_property_rebound", "schema_additional_property"],
    ["duplicate_artifact_key_bypass", "duplicate_json_key"],
    ["duplicate_schema_key_bypass", "duplicate_json_key"],
    ["schema_pattern_rebound", "schema_pattern"],
    ["schema_min_length_rebound", "schema_min_length"],
    ["schema_unique_items_rebound", "schema_unique_items"]
  ].freeze

  def test_catalog_order_matches_all_49_attacks
    docs, = fresh_documents
    assert_equal MUTATION_CODES, docs.fetch("catalog").fetch("mutations").map { |row| row.values_at("mutation_id", "error_code") }
  end

  MUTATION_CODES.each_with_index do |(mutation_id, expected_code), index|
    define_method("test_%02d_%s" % [index + 1, mutation_id]) do
      assert_rejected(expected_code) { execute_mutation(mutation_id) }
    end
  end

  private

  def execute_mutation(mutation_id)
    docs, schemas = fresh_documents
    manifest = docs.fetch("manifest")
    fixture = docs.fetch("fixture")
    receipt = docs.fetch("receipt")
    handoff = docs.fetch("handoff")

    case mutation_id
    when "missing_wave2_lane"
      manifest["members"].delete_at(0)
      validate_documents!(docs, schemas)
    when "extra_undeclared_member"
      manifest["members"] << deep_copy(manifest["members"].last)
      validate_documents!(docs, schemas)
    when "wrong_merge_sha", "recomputed_content_hash_with_stale_authority"
      manifest["members"][0]["merge_sha"] = "0" * 40
      rehash_member!(manifest["members"][0])
      validate_documents!(docs, schemas)
    when "wrong_blob_sha"
      manifest["members"][0]["git_blob_sha"] = "0" * 40
      rehash_member!(manifest["members"][0])
      validate_documents!(docs, schemas)
    when "cross_lane_artifact_substitution"
      manifest["members"][0]["path"] = manifest["members"][1]["path"]
      rehash_member!(manifest["members"][0])
      validate_documents!(docs, schemas)
    when "private_story_insertion"
      fixture["records"][0]["private_story"] = "real customer story"
      validate_documents!(docs, schemas)
    when "prompt_insertion"
      fixture["records"][0]["prompt"] = "generate a shot"
      validate_documents!(docs, schemas)
    when "absolute_private_path"
      fixture["records"][0]["notes"] = "/home/gor/private/story.json"
      validate_documents!(docs, schemas)
    when "secret_like_value"
      fixture["records"][0]["notes"] = "sk-abcdefghijklmnopQRST"
      validate_documents!(docs, schemas)
    when "provider_response"
      fixture["records"][0]["provider_response"] = {"status" => "ok"}
      validate_documents!(docs, schemas)
    when "binary_or_base64_media"
      fixture["records"][0]["notes"] = "iVBORw0KGgoAAAANSUhEUg"
      validate_documents!(docs, schemas)
    when "data_url"
      fixture["records"][0]["notes"] = "data:image/png;base64,AAAA"
      validate_documents!(docs, schemas)
    when "q0_placeholder_as_production_media"
      fixture["records"][0]["q0_placeholder"]["production_media"] = true
      validate_documents!(docs, schemas)
    when "public_runner_sha_drift"
      receipt["validated_public_runner_main_sha"] = "0" * 40
      validate_documents!(docs, schemas)
    when "frozen_private_sha_drift"
      handoff["frozen_private_source_sha"] = "0" * 40
      validate_documents!(docs, schemas)
    when "workflow_dispatch_authority_injection"
      handoff["workflow_dispatch_authority"] = true
      validate_documents!(docs, schemas)
    when "media_execution_authority_injection"
      handoff["media_execution_authority"] = true
      validate_documents!(docs, schemas)
    when "paid_authority_injection"
      handoff["paid_execution_authority"] = true
      validate_documents!(docs, schemas)
    when "reverse_authority_injection"
      handoff["reverse_authority"] = true
      validate_documents!(docs, schemas)
    when "receipt_empty_checks_rebound"
      receipt["checks"] = {}
      validate_documents!(docs, schemas)
    when "receipt_reduced_checks_rebound"
      receipt["checks"].delete(receipt["checks"].keys.first)
      validate_documents!(docs, schemas)
    when "receipt_non_string_pass_rebound"
      receipt["checks"][receipt["checks"].keys.first] = true
      validate_documents!(docs, schemas)
    when "mutation_duplicate_id_rebound"
      receipt["negative_mutations"][1]["mutation_id"] = receipt["negative_mutations"][0]["mutation_id"]
      validate_documents!(docs, schemas)
    when "mutation_missing_id_rebound"
      receipt["negative_mutations"].delete_at(0)
      validate_documents!(docs, schemas)
    when "mutation_unknown_id_rebound"
      receipt["negative_mutations"][0]["mutation_id"] = "unknown"
      validate_documents!(docs, schemas)
    when "mutation_error_code_mismatch_rebound"
      receipt["negative_mutations"][0]["error_code"] = "wrong"
      validate_documents!(docs, schemas)
    when "mutation_order_changed_rebound"
      receipt["negative_mutations"][0], receipt["negative_mutations"][1] = receipt["negative_mutations"][1], receipt["negative_mutations"][0]
      validate_documents!(docs, schemas)
    when "handoff_semantics_empty_rebound"
      handoff["expected_validation_semantics"] = []
      validate_documents!(docs, schemas)
    when "handoff_semantics_substituted_rebound"
      handoff["expected_validation_semantics"][0] = "FOREIGN"
      validate_documents!(docs, schemas)
    when "handoff_semantics_order_changed_rebound"
      handoff["expected_validation_semantics"][0], handoff["expected_validation_semantics"][1] = handoff["expected_validation_semantics"][1], handoff["expected_validation_semantics"][0]
      validate_documents!(docs, schemas)
    when "receipt_integer_float_rebound"
      receipt["public_runner_writes"] = 0.0
      validate_documents!(docs, schemas)
    when "fixture_integer_float_rebound"
      fixture["records"][0]["zero_media"]["media_asset_count"] = 0.0
      validate_documents!(docs, schemas)
    when "nested_boolean_integer_rebound"
      manifest["members"][0]["required_for_gate"] = 1
      rehash_member!(manifest["members"][0])
      validate_documents!(docs, schemas)
    when "schema_required_key_rebound"
      Gate.send(:__schema_validate_for_test__, {}, {"type" => "object", "additionalProperties" => false, "required" => ["x"], "properties" => {"x" => {"type" => "string"}}})
    when "schema_exact_type_rebound"
      Gate.send(:__schema_validate_for_test__, "x", {"type" => "integer"})
    when "schema_const_rebound"
      Gate.send(:__schema_validate_for_test__, "x", {"const" => "y"})
    when "schema_enum_rebound"
      Gate.send(:__schema_validate_for_test__, "x", {"enum" => ["y"]})
    when "schema_minimum_rebound"
      Gate.send(:__schema_validate_for_test__, 0, {"minimum" => 1})
    when "schema_maximum_rebound"
      Gate.send(:__schema_validate_for_test__, 2, {"maximum" => 1})
    when "schema_array_cardinality_rebound"
      Gate.send(:__schema_validate_for_test__, [1, 2], {"type" => "array", "maxItems" => 1})
    when "schema_item_rebound"
      Gate.send(:__schema_validate_for_test__, ["x"], {"type" => "array", "items" => {"type" => "integer"}})
    when "schema_nested_closure_rebound"
      value = {"nested" => {"x" => 1, "extra" => 2}}
      schema = {"type" => "object", "additionalProperties" => false, "properties" => {"nested" => {"type" => "object", "additionalProperties" => false, "properties" => {"x" => {"type" => "integer"}}}}}
      Gate.send(:__schema_validate_for_test__, value, schema)
    when "schema_additional_property_rebound"
      Gate.send(:__schema_validate_for_test__, {"x" => 1, "extra" => 2}, {"type" => "object", "additionalProperties" => false, "properties" => {"x" => {"type" => "integer"}}})
    when "duplicate_artifact_key_bypass"
      Gate.send(:__strict_parse_for_test__, '{"fixture_id":"A","fixture_id":"B"}')
    when "duplicate_schema_key_bypass"
      Gate.send(:__strict_parse_for_test__, '{"type":"string","type":"integer"}')
    when "schema_pattern_rebound"
      Gate.send(:__schema_validate_for_test__, "abc", {"type" => "string", "pattern" => "^z$"})
    when "schema_min_length_rebound"
      Gate.send(:__schema_validate_for_test__, "", {"type" => "string", "minLength" => 1})
    when "schema_unique_items_rebound"
      Gate.send(:__schema_validate_for_test__, ["x", "x"], {"type" => "array", "uniqueItems" => true})
    else
      flunk "unknown mutation #{mutation_id}"
    end
  end
end
