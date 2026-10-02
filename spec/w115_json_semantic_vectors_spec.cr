require "spec"
require "../scripts/w115_json_semantic_vectors"

private def w115_spec_json(value : JSON::Any, reverse_hash_order : Bool) : String
  case raw = value.raw
  when Hash(String, JSON::Any)
    entries = raw.to_a
    entries.reverse! if reverse_hash_order
    "{" + entries.map do |key, child|
      "#{key.to_json}:#{w115_spec_json(child, reverse_hash_order)}"
    end.join(",") + "}"
  when Array(JSON::Any)
    "[" + raw.map { |child| w115_spec_json(child, reverse_hash_order) }.join(",") + "]"
  else
    value.to_json
  end
end

private def w115_spec_tsv(rows : Array(JSON::Any), reverse_hash_order : Bool = false) : String
  rows.map do |row|
    record = row.as_h
    key = record["pk"].as_i
    payload = record["payload"]
    "#{key}\t#{w115_spec_json(payload, reverse_hash_order)}"
  end.join("\n") + "\n"
end

private def w115_spec_document_mismatch(actual : String, profile : String) : String
  begin
    w115_assert_semantic_documents(actual, profile)
  rescue error : Exception
    return error.message || ""
  end
  raise "expected semantic document mismatch"
end

describe "W115 independent JSON semantic vectors" do
  it "pins eight literal rows and the four-key nonzero-origin selection" do
    W115_SEMANTIC_KEYS.size.should eq(8)
    W115_SEMANTIC_PAYLOADS.size.should eq(8)

    {"dynamic_paths", "dynamic_shared_only", "typed_mixed"}.each do |profile|
      full = w115_semantic_expected(profile)
      selected = w115_semantic_expected(profile, selected: true)

      full.size.should eq(8)
      selected.map { |row| row.as_h["pk"].as_i }.should eq([3_i64, 4_i64, 5_i64, 6_i64])
      w115_assert_semantic_documents(w115_spec_tsv(full), profile)
      w115_assert_semantic_documents(w115_spec_tsv(selected), profile, selected: true)
    end
  end

  it "keeps typed defaults distinct from absence and retains edge values" do
    dynamic_rows = w115_semantic_expected("dynamic_paths")
    typed_rows = w115_semantic_expected("typed_mixed")

    dynamic_rows[1].as_h["payload"].as_h.has_key?("a").should be_false
    typed_rows[1].as_h["payload"].as_h["a"].as_i.should eq(0_i64)
    dynamic_rows[3].as_h["payload"].as_h.has_key?("a").should be_false
    typed_rows[3].as_h["payload"].as_h["a"].as_i.should eq(0_i64)

    payload = dynamic_rows[2].as_h["payload"].as_h
    payload["s"].as_s.should eq("a\0b")
    payload["dot"].as_h["key"].as_i.should eq(103_i64)
    dynamic_rows[0].as_h["payload"].as_h["nest"].as_h["leaf"].as_s.should eq("one")
    dynamic_rows[1].as_h["payload"].as_h["s"].as_s.should eq("")
    dynamic_rows[1].as_h["payload"].as_h["arr"].as_a.should be_empty
    dynamic_rows[1].as_h["payload"].as_h["flag"].as_bool.should be_false
  end

  it "accepts reordered JSON object members without relaxing row order or value types" do
    rows = w115_semantic_expected("dynamic_paths")
    ordered = w115_spec_tsv(rows)
    reversed = w115_spec_tsv(rows, reverse_hash_order: true)

    reversed.should_not eq(ordered)
    w115_assert_semantic_documents(reversed, "dynamic_paths")
  end

  it "reports wrong keys, wrong scalars, and Bool-to-integer substitutions as semantic mismatches" do
    rows = w115_semantic_expected("dynamic_paths")
    valid_tsv = w115_spec_tsv(rows)
    separator = valid_tsv.index('\t').not_nil!
    error = expect_raises(Exception) do
      w115_assert_semantic_documents("99\t#{valid_tsv[(separator + 1)..]}", "dynamic_paths")
    end
    error.message.should eq("W115 dynamic_paths: row 0 key differs: got \"99\", expected 1")

    wrong_scalar = w115_semantic_expected("dynamic_paths")
    wrong_scalar[0].as_h["payload"].as_h["a"] = JSON::Any.new(11_i64)
    w115_spec_document_mismatch(w115_spec_tsv(wrong_scalar), "dynamic_paths").should contain("document for pk=1 differs;")

    wrong_bool = w115_semantic_expected("dynamic_paths")
    wrong_bool[0].as_h["payload"].as_h["flag"] = JSON::Any.new(1_i64)
    w115_spec_document_mismatch(w115_spec_tsv(wrong_bool), "dynamic_paths").should contain("document for pk=1 differs;")
  end

  it "distinguishes missing keys from present empty String and Array values" do
    missing_string = w115_semantic_expected("dynamic_paths")
    missing_string[1].as_h["payload"].as_h.delete("s")
    w115_spec_document_mismatch(w115_spec_tsv(missing_string), "dynamic_paths").should contain("document for pk=2 differs;")

    missing_array = w115_semantic_expected("dynamic_paths")
    missing_array[1].as_h["payload"].as_h.delete("arr")
    w115_spec_document_mismatch(w115_spec_tsv(missing_array), "dynamic_paths").should contain("document for pk=2 differs;")
  end

  it "rejects an omitted expected row with an exact cardinality diagnostic" do
    lines = w115_spec_tsv(w115_semantic_expected("dynamic_paths")).lines
    truncated = lines[0, 7].join("\n") + "\n"

    error = expect_raises(Exception) do
      w115_assert_semantic_documents(truncated, "dynamic_paths")
    end
    error.message.should eq("W115 dynamic_paths: expected 8 keyed documents, got 7")
  end

  it "compares JSON scalar types and preserves present false and null properties" do
    w115_semantic_json_equal?(JSON.parse("true"), JSON.parse("1")).should be_false
    w115_semantic_json_equal?(JSON.parse("null"), JSON.parse("0")).should be_false

    expected = JSON.parse(%({"false_value":false,"null_value":null,"string_value":"","array_value":[]}))
    reordered = JSON.parse(%({"array_value":[],"null_value":null,"false_value":false,"string_value":""}))
    absent = JSON.parse(%({"false_value":false,"string_value":"","array_value":[]}))

    w115_semantic_json_equal?(expected, reordered).should be_true
    w115_semantic_json_equal?(expected, absent).should be_false
  end

  it "rejects an unknown semantic profile with a specific diagnostic" do
    error = expect_raises(Exception) do
      w115_semantic_expected("unknown")
    end
    error.message.should eq("unknown W115 semantic profile: unknown")
  end
end
