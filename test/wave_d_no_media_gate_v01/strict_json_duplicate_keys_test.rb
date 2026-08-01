# frozen_string_literal: true

require_relative "test_helper"

class StrictJsonDuplicateKeysTest < Minitest::Test
  include WaveDNoMediaGateTestSupport

  def test_top_level_duplicate
    assert_duplicate('{"a":1,"a":2}')
  end

  def test_nested_object_duplicate
    assert_duplicate('{"outer":{"a":1,"a":2}}')
  end

  def test_object_in_array_duplicate
    assert_duplicate('[{"a":1,"a":2}]')
  end

  def test_escaped_equivalent_key_duplicate
    assert_duplicate('{"a":1,"\\u0061":2}')
    assert_duplicate('{"j":1,"\\u006A":2}')
    assert_duplicate('{"/":1,"\\/":2}')
    assert_duplicate('{"😀":1,"\\uD83D\\uDE00":2}')
  end

  def test_whitespace_variants
    [
      "{ \"a\" : 1 , \"a\" : 2 }",
      "{\n\t\"a\"\r:1,\n\"a\"\t:2\n}",
      '{"outer" : [ { "a" : 1 , "a" : 2 } ]}'
    ].each { |text| assert_duplicate(text) }
  end

  def test_comments_cannot_bypass_duplicate_detection
    [
      '/* head */{"a":1,"a":2}',
      "// head\n{\"a\":1,\"a\":2}",
      '{"outer":/* before nested value */{"a":1,"a":2}}',
      '{"a":1,/* before duplicate key */"a":2}'
    ].each { |text| assert_duplicate(text) }
  end

  def test_different_objects_same_key_accepted
    expected = {"left" => {"a" => 1}, "right" => {"a" => 2}}
    assert_equal expected, parse('{"left":{"a":1},"right":{"a":2}}')
  end

  def test_key_like_text_inside_string_accepted
    expected = {"value" => '"a":1,"a":2,{"nested":true}'}
    assert_equal expected, parse(JSON.generate(expected))
  end

  def test_escaped_quotes_and_backslashes_accepted
    expected = {'a"b' => 'c\\d'}
    assert_equal expected, parse(JSON.generate(expected))
  end

  def test_existing_json_comment_semantics_preserved
    assert_equal({"a" => 1}, parse('{/* before key */"a"/* before colon */:/* before value */1/* trailing */}'))
    assert_equal [1, 2], parse("[1/* after scalar */,// before next value\n2]")
    assert_equal({"a" => 1, "b" => 2}, parse('/* prefix */{"a":1,/* between members */"b":2}// suffix'))
  end

  def test_supported_unicode_encodings_preserve_valid_json
    %w[UTF-16LE UTF-16BE UTF-32LE UTF-32BE].each do |encoding|
      assert_equal({"a" => 1}, parse('{"a":1}'.encode(encoding)), encoding)
    end

    binary_utf8 = '{"é":1}'.encode(Encoding::UTF_8).b
    assert_equal({"é" => 1}, parse(binary_utf8))
  end

  def test_supported_unicode_encodings_reject_decoded_duplicates
    %w[UTF-16LE UTF-16BE UTF-32LE UTF-32BE].each do |encoding|
      assert_duplicate('{"a":1,"\\u0061":2}'.encode(encoding))
    end
  end

  def test_empty_object_and_array_accepted
    assert_equal({}, parse("{}"))
    assert_equal([], parse("[]"))
    assert_equal({"empty_object" => {}, "empty_array" => []}, parse('{"empty_object":{},"empty_array":[]}'))
  end

  def test_malformed_json_remains_json_parse
    [
      '{"a":',
      '{"a":1,}',
      '{"a":1,"a":}',
      '[1,]'
    ].each { |text| assert_rejected("json_parse") { parse(text) } }
  end

  def test_existing_valid_package_parse_accepted
    assert Gate.validate!
  end

  def test_root_scalars_and_arrays_preserve_semantics
    assert_equal "value", parse('"value"')
    assert_equal 42, parse("42")
    assert_equal true, parse("true")
    assert_nil parse("null")
    assert_equal [1, {"a" => 2}, 3], parse('[1,{"a":2},3]')
  end

  private

  def parse(text)
    Gate.send(:__strict_parse_for_test__, text)
  end

  def assert_duplicate(text)
    assert_rejected("duplicate_json_key") { parse(text) }
  end
end
