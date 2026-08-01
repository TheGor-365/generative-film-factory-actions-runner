# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"

ROOT = File.expand_path("../..", __dir__)
VALIDATOR = File.join(ROOT, ".github/gff/wave_d_no_media_gate/v01/validator.rb")
require VALIDATOR

module WaveDNoMediaGateTestSupport
  Gate = FactoryMvp::Runner::WaveDNoMediaGate::V01
  Rejection = Gate::Rejection

  def fresh_documents
    expected = Gate.send(:__expected_for_test__)
    [deep_copy(expected.fetch("docs")), deep_copy(expected.fetch("schemas"))]
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def validate_documents!(documents, schemas)
    Gate.send(:__validate_documents_for_test__, documents, schemas)
  end

  def assert_rejected(code)
    error = assert_raises(Rejection) { yield }
    assert_equal code, error.code
  end

  def canonical_sha(value)
    normalized = case value
                 when Hash
                   value.keys.sort.to_h { |key| [key, canonical_value(value.fetch(key))] }
                 else
                   canonical_value(value)
                 end
    Digest::SHA256.hexdigest(JSON.generate(normalized))
  end

  def canonical_value(value)
    case value
    when Hash
      value.keys.sort.to_h { |key| [key, canonical_value(value.fetch(key))] }
    when Array
      value.map { |item| canonical_value(item) }
    else
      value
    end
  end

  def rehash_member!(member)
    member["content_sha256"] = canonical_sha(member.reject { |key, _| key == "content_sha256" })
  end
end
