require "json"

# Independent semantic expectations for the W115 capture. Each returned row is
# keyed by pk and contains the expected payload document; it is not a physical
# layout or production-reader certificate.
W115_SEMANTIC_KEYS = [1_i64, 2_i64, 3_i64, 4_i64, 5_i64, 6_i64, 7_i64, 8_i64]

W115_SEMANTIC_PAYLOADS = [
  %({"a":10,"s":"alpha","flag":true,"arr":[1,2],"nest":{"leaf":"one"},"dot":{"key":101}}),
  %({"s":"","flag":false,"arr":[],"nest":{"leaf":"two"},"dot":{"key":102}}),
  %({"a":3,"s":"nul-placeholder","arr":[3],"dot":{"key":103}}),
  %({}),
  %({"a":5,"s":42,"flag":true,"arr":[4,5],"nest":{"leaf":"five"},"dot":{"key":105}}),
  %({"a":6,"flag":false,"dot":{"key":106}}),
  %({"a":7,"s":"last","arr":[6],"nest":{"leaf":"end"},"dot":{"key":107}}),
  %({"a":8,"s":true,"flag":true,"arr":[7],"nest":{"leaf":""},"dot":{"key":108}}),
]

def w115_semantic_expected(profile : String, selected : Bool = false) : Array(JSON::Any)
  unless {"dynamic_paths", "dynamic_shared_only", "typed_mixed"}.includes?(profile)
    raise "unknown W115 semantic profile: #{profile}"
  end

  first_index = selected ? 2 : 0
  end_index = selected ? 6 : W115_SEMANTIC_KEYS.size
  rows = [] of JSON::Any

  first_index.upto(end_index - 1) do |index|
    payload = JSON.parse(W115_SEMANTIC_PAYLOADS[index]).as_h

    # Keep this value as an actual NUL in the expected document. The TSVRaw
    # capture contains JSON text and should therefore expose the escaped form.
    payload["s"] = JSON::Any.new("a\0b") if index == 2

    if profile == "typed_mixed" && (index == 1 || index == 3)
      payload["a"] = JSON::Any.new(0_i64)
    end

    row = {
      "pk"      => JSON::Any.new(W115_SEMANTIC_KEYS[index]),
      "payload" => JSON::Any.new(payload),
    } of String => JSON::Any
    rows << JSON::Any.new(row)
  end

  rows
end

# JSON::Any equality can conflate values from different JSON scalar types in
# some contexts. Compare the raw variants recursively so (for example) true
# never matches 1, and distinguish an absent key from a present empty value.
def w115_semantic_json_equal?(expected : JSON::Any, actual : JSON::Any) : Bool
  expected_raw = expected.raw
  actual_raw = actual.raw

  case expected_raw
  when Nil
    actual_raw.nil?
  when Bool
    actual_raw.is_a?(Bool) && actual_raw == expected_raw
  when Int64
    actual_raw.is_a?(Int64) && actual_raw == expected_raw
  when Float64
    actual_raw.is_a?(Float64) && actual_raw == expected_raw
  when String
    actual_raw.is_a?(String) && actual_raw == expected_raw
  when Array(JSON::Any)
    return false unless actual_raw.is_a?(Array(JSON::Any))
    actual_array = actual_raw.as(Array(JSON::Any))
    expected_raw.size == actual_array.size && expected_raw.each_with_index.all? do |value, index|
      w115_semantic_json_equal?(value, actual_array[index])
    end
  when Hash(String, JSON::Any)
    return false unless actual_raw.is_a?(Hash(String, JSON::Any))
    actual_hash = actual_raw.as(Hash(String, JSON::Any))
    expected_raw.size == actual_hash.size && expected_raw.all? do |key, value|
      if actual_value = actual_hash[key]?
        w115_semantic_json_equal?(value, actual_value)
      else
        false
      end
    end
  else
    false
  end
end

# Compare keyed `pk<TAB>toJSONString(payload)` rows saved as TSVRaw. Object
# member ordering is ignored; row keys, document shape, and scalar types are
# exact. Set output_format_json_quote_64bit_integers=0 on the capture query.
def w115_assert_semantic_documents(actual_tsv : String, profile : String, selected : Bool = false, label : String = "W115") : Nil
  expected_rows = w115_semantic_expected(profile, selected)
  actual_lines = actual_tsv.lines
  actual_lines.pop if actual_lines.last?.try(&.empty?)

  unless actual_lines.size == expected_rows.size
    raise "#{label} #{profile}: expected #{expected_rows.size} keyed documents, got #{actual_lines.size}"
  end

  actual_lines.each_with_index do |line, index|
    separator = line.index('\t') || raise "#{label} #{profile}: row #{index} has no TSVRaw key separator"
    key_text = line[0, separator]
    document_text = line[(separator + 1)..]
    actual_key = key_text.to_i64?
    expected_row = expected_rows[index].as_h
    expected_key = expected_row["pk"].as_i

    unless actual_key == expected_key
      raise "#{label} #{profile}: row #{index} key differs: got #{key_text.inspect}, expected #{expected_key}"
    end

    actual_document = JSON.parse(document_text)
    expected_document = expected_row["payload"]
    unless w115_semantic_json_equal?(expected_document, actual_document)
      raise "#{label} #{profile}: document for pk=#{expected_key} differs; actual=#{actual_document.to_json} expected=#{expected_document.to_json}"
    end
  end
end
