require "./spec_helper"
require "json"
require "set"
require "../scripts/support/compact_json_w263_fixture"

private def w263_root_matrix_all_labels : Array(String)
  layouts = [
    "obj_v1_dyn_v1_map",
    "obj_v2_dyn_v2_map",
    "obj_v3_dyn_v3_map",
    "obj_v3_dyn_v3_map_with_buckets",
    "obj_v3_dyn_v3_advanced",
    "obj_v3_dyn_v3_advanced_chunked",
  ]
  labels = [] of String
  layouts.each do |layout|
    {"mrk3", "mrk4"}.each do |mark_format|
      {0, 1}.each do |string_version|
        {"basic", "compact"}.each do |variant_mode|
          labels << "#{layout}_#{mark_format}_s#{string_version}_variant_#{variant_mode}"
        end
      end
    end
  end
  labels
end

private def w263_root_matrix_positive_labels : Array(String)
  layouts = [] of String
  {
    "obj_v1_dyn_v1_map",
    "obj_v2_dyn_v2_map",
    "obj_v3_dyn_v3_map",
  }.each do |layout|
    {"mrk3", "mrk4"}.each do |mark_format|
      layouts << "#{layout}_#{mark_format}"
    end
  end
  layouts << "obj_v3_dyn_v3_advanced_chunked_mrk4"
  w263_root_matrix_expand_layouts(layouts)
end

private def w263_root_matrix_guard_labels : Array(String)
  layouts = [
    "obj_v3_dyn_v3_map_with_buckets_mrk3",
    "obj_v3_dyn_v3_advanced_mrk3",
    "obj_v3_dyn_v3_advanced_chunked_mrk3",
  ]
  w263_root_matrix_expand_layouts(layouts)
end

private def w263_root_matrix_held_out_labels : Array(String)
  layouts = [
    "obj_v3_dyn_v3_map_with_buckets_mrk4",
    "obj_v3_dyn_v3_advanced_mrk4",
  ]
  w263_root_matrix_expand_layouts(layouts)
end

private def w263_root_matrix_expand_layouts(layouts : Array(String)) : Array(String)
  labels = [] of String
  layouts.each do |layout|
    {0, 1}.each do |string_version|
      {"basic", "compact"}.each do |variant_mode|
        labels << "#{layout}_s#{string_version}_variant_#{variant_mode}"
      end
    end
  end
  labels
end

private def w263_root_matrix_signature(document : CrystalClick::ObjectDocument) : String
  entries = document.paths.sort.map do |path|
    "#{path}=#{CompactJsonW263Fixture.value_signature(document.value_for(path))}"
  end
  "#{CompactJsonW263Fixture.json_type.name}{#{entries.join(",")}}"
end

private def w263_root_matrix_json_value(value : CrystalClick::BinaryValue) : JSON::Any
  case value.type.tag
  when CrystalClick::BinaryDataType::TAG_JSON
    fields = Hash(String, JSON::Any).new
    value.json_row.entries.each do |path, child|
      fields[path] = w263_root_matrix_json_value(child)
    end
    JSON::Any.new(fields)
  when CrystalClick::BinaryDataType::TAG_STRING
    JSON::Any.new(value.as_string)
  when CrystalClick::BinaryDataType::TAG_UINT8
    JSON::Any.new(value.byte_at(0).to_i64)
  when CrystalClick::BinaryDataType::TAG_UINT64
    JSON::Any.new(value.as_uint64.to_i64)
  when CrystalClick::BinaryDataType::TAG_INT64
    JSON::Any.new(value.as_int64)
  when CrystalClick::BinaryDataType::TAG_FLOAT64
    JSON::Any.new(value.as_float64_bits.unsafe_as(Float64))
  else
    raise CrystalClick::UnsupportedFormatError.new("W263 native JSON literal lacks #{value.type.name}")
  end
end

private def w263_root_matrix_decode_hex(hex : String) : Bytes
  source = hex.to_slice
  raise CrystalClick::CorruptPartError.new("W263 native root JSON hex has odd length") unless source.size.even?
  bytes = Bytes.new(source.size // 2)
  bytes.size.times do |index|
    high = w263_root_matrix_hex_nibble(source[index * 2])
    low = w263_root_matrix_hex_nibble(source[index * 2 + 1])
    bytes[index] = ((high << 4) | low).to_u8
  end
  bytes
end

private def w263_root_matrix_hex_nibble(byte : UInt8) : UInt8
  case byte
  when '0'.ord.to_u8..'9'.ord.to_u8
    (byte - '0'.ord.to_u8).to_u8
  when 'a'.ord.to_u8..'f'.ord.to_u8
    (byte - 'a'.ord.to_u8 + 10).to_u8
  when 'A'.ord.to_u8..'F'.ord.to_u8
    (byte - 'A'.ord.to_u8 + 10).to_u8
  else
    raise CrystalClick::CorruptPartError.new("W263 native root JSON hex contains a non-hex byte")
  end
end

private def w263_root_matrix_assert_native_rows!(summary : JSON::Any, label : String) : Nil
  table = "w263_#{label}"
  expected_values = CompactJsonW263Fixture.root_values
  native_rows = summary["native_rows"].as_h
  expected_values.each_with_index do |expected_value, index|
    key = "#{table}|#{index + 1}"
    row = native_rows[key]?.try(&.as_a) ||
          raise CrystalClick::CorruptPartError.new("W263 native root JSON oracle lacks #{key}")
    raise CrystalClick::CorruptPartError.new("W263 native root JSON row is truncated for #{key}") unless row.size > 7
    actual = JSON.parse(String.new(w263_root_matrix_decode_hex(row[7].as_s)))
    expected = w263_root_matrix_json_value(expected_value)
    unless actual.as_h == expected.as_h
      raise CrystalClick::CorruptPartError.new("W263 native JSON differs from the independent fixture for #{key}")
    end
  end
  nil
end

private def w263_root_matrix_evidence_root : String
  supplied = ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]? ||
             raise "CRYSTAL_CLICK_W263_EVIDENCE_ROOT must name the authenticated baseline capture"
  root = File.realpath(supplied)
  raise ArgumentError.new("W263 evidence root must be supplied canonically") unless File.expand_path(supplied) == root
  root
end

private def w263_root_matrix_authenticate(root : String) : {JSON::Any, JSON::Any, String}
  summary_path = File.join(root, "summary.json")
  manifest_path = File.join(root, "parts", "native_manifest.json")
  {summary_path, manifest_path}.each do |path|
    unless File.file?(path) && !File.symlink?(path) && File.realpath(path) == path
      raise CrystalClick::CorruptPartError.new("W263 evidence metadata is absent, linked or noncanonical")
    end
  end
  raise CrystalClick::CorruptPartError.new("W263 summary exceeds the evidence size bound") if File.size(summary_path) > 16 * 1024 * 1024
  raise CrystalClick::CorruptPartError.new("W263 native manifest exceeds the evidence size bound") if File.size(manifest_path) > 4 * 1024 * 1024

  summary = JSON.parse(File.read(summary_path))
  manifest = JSON.parse(File.read(manifest_path))
  labels = w263_root_matrix_all_labels

  summary["format"].as_s.should eq("compact_json_w263_probe_summary_v1")
  summary["mode"].as_s.should eq("baseline")
  summary["status"].as_s.should eq("expected_json_unsupported") # capture provenance, not expected reader behavior
  summary["row_count"].as_i.should eq(CompactJsonW263Fixture::ROWS)
  summary["mark_rows"].as_a.map { |rows| rows.as_i64.to_u64 }.should eq(CompactJsonW263Fixture::MARK_ROWS)
  summary["cells"].as_a.map(&.as_s).sort.should eq(labels.sort)
  summary["parts"].as_h.size.should eq(labels.size)
  summary["native_rows"].as_h.size.should eq(labels.size * CompactJsonW263Fixture::ROWS)
  summary["native_invocation"]["exit"].as_i.should eq(0)
  summary["native_invocation"]["process_classification"].as_s.should eq("success")
  summary["clickhouse"]["sha256"].as_s.should eq(CompactJsonW263Fixture::NATIVE_BINARY_SHA256)
  summary["clickhouse"]["version"].as_s.should eq(CompactJsonW263Fixture::NATIVE_VERSION)
  summary["clickhouse"]["build"].as_s.should eq(CompactJsonW263Fixture::NATIVE_BUILD)
  summary["native_invocation"]["binary_sha_after"].as_s.should eq(CompactJsonW263Fixture::NATIVE_BINARY_SHA256)
  summary["source_snapshot"]["revision"].as_s.should eq(CompactJsonW263Fixture::NATIVE_SOURCE_REVISION)

  manifest["format"].as_s.should eq(CompactJsonW263Fixture::NATIVE_MANIFEST_FORMAT)
  manifest["mode"].as_s.should eq("baseline")
  manifest["clickhouse"]["sha256"].as_s.should eq(CompactJsonW263Fixture::NATIVE_BINARY_SHA256)
  manifest["clickhouse"]["version"].as_s.should eq(CompactJsonW263Fixture::NATIVE_VERSION)
  manifest["clickhouse"]["build"].as_s.should eq(CompactJsonW263Fixture::NATIVE_BUILD)
  manifest["source_snapshot"]["revision"].as_s.should eq(CompactJsonW263Fixture::NATIVE_SOURCE_REVISION)
  manifest["source_snapshot"]["runtime_provenance_claimed"].as_bool.should be_false
  manifest["parts"].as_a.size.should eq(labels.size)
  manifest_labels = manifest["parts"].as_a.map { |entry| entry["label"].as_s }
  manifest_labels.sort.should eq(labels.sort)

  store_root = File.realpath(manifest["store_root"].as_s)
  expected_store = File.realpath(File.join(root, "stores", "native"))
  store_root.should eq(expected_store)
  {summary, manifest, store_root}
end

private def w263_root_matrix_part_path(
  summary : JSON::Any,
  manifest : JSON::Any,
  store_root : String,
  label : String,
) : String
  summary_record = summary["parts"][label]
  manifest_entry = manifest["parts"].as_a.find { |entry| entry["label"].as_s == label } ||
                   raise CrystalClick::CorruptPartError.new("W263 native manifest lacks #{label}")
  table = "w263_#{label}"
  extension = label.includes?("_mrk3_") ? ".mrk3" : ".mrk4"

  summary_record["part_type"].as_s.should eq("Compact")
  summary_record["rows"].as_s.should eq(CompactJsonW263Fixture::ROWS.to_s)
  summary_record["marks"].as_s.should eq((CompactJsonW263Fixture::MARK_ROWS.size + 1).to_s)
  summary_record["mark_extension"].as_s.should eq(extension)
  summary_record["part_name"].as_s.should eq(CompactJsonW263Fixture::PART_NAME)
  manifest_entry["table"].as_s.should eq(table)
  manifest_entry["part_type"].as_s.should eq("Compact")
  manifest_entry["rows"].as_s.should eq(CompactJsonW263Fixture::ROWS.to_s)
  manifest_entry["marks"].as_s.should eq((CompactJsonW263Fixture::MARK_ROWS.size + 1).to_s)
  manifest_entry["mark_extension"].as_s.should eq(extension)
  manifest_entry["part_name"].as_s.should eq(CompactJsonW263Fixture::PART_NAME)
  manifest_entry["path"].as_s.should eq(summary_record["path"].as_s)

  part_path = File.realpath(manifest_entry["path"].as_s)
  store_prefix = store_root.ends_with?(File::SEPARATOR) ? store_root : store_root + File::SEPARATOR
  raise CrystalClick::CorruptPartError.new("W263 part escapes authenticated native store") unless part_path.starts_with?(store_prefix)
  File.basename(part_path).should eq(CompactJsonW263Fixture::PART_NAME)

  inventory = manifest_entry["file_inventory"].as_a.map do |item|
    {item["path"].as_s, item["bytes"].as_i64, item["sha256"].as_s}
  end
  CompactJsonW263Fixture.assert_native_inventory!(part_path, inventory)
  serialization = JSON.parse(File.read(File.join(part_path, "serialization.json")))
  serialization.should eq(summary_record["serialization"])
  expected_string_version = label.includes?("_s1_") ? 1 : 0
  serialization["types_serialization_versions"]["string"].as_i.should eq(expected_string_version)
  serialization["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true
  part_path
end

private def w263_root_matrix_open(part_path : String, label : String) : CrystalClick::CompactStaticJsonBulkColumnReader
  reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
    part_path,
    "root",
    CompactJsonW263Fixture.json_type,
  )
  expected_profile = label.includes?("_s1_") ? CrystalClick::BinaryBulkProfile.with_size_stream : CrystalClick::BinaryBulkProfile.single_stream
  # This is the target profile-selection contract, asserted before preparation
  # or decode can mask a metadata-to-profile error as a serde failure.
  reader.ordinary_profile.should eq(expected_profile)
  reader.row_count.should eq(CompactJsonW263Fixture::ROWS.to_u64)
  reader.mark_count.should eq(CompactJsonW263Fixture::MARK_ROWS.size)
  reader.mark_row_counts.should eq(CompactJsonW263Fixture::MARK_ROWS)
  reader
end

describe "Compact static root-JSON matrix scope (W263)" do
  it "partitions all 48 captured cells into 28 targets, 12 MRK3 guards, and 8 held-out layouts" do
    all = w263_root_matrix_all_labels
    positive = w263_root_matrix_positive_labels
    guards = w263_root_matrix_guard_labels
    held_out = w263_root_matrix_held_out_labels
    plain_maps = [
      "obj_v1_dyn_v1_map",
      "obj_v2_dyn_v2_map",
      "obj_v3_dyn_v3_map",
    ]
    expected_positive = all.select do |label|
      plain_map = plain_maps.any? do |layout|
        label.starts_with?(layout + "_mrk3_") || label.starts_with?(layout + "_mrk4_")
      end
      if label.includes?("_mrk3_")
        plain_map
      else
        plain_map || label.starts_with?("obj_v3_dyn_v3_advanced_chunked_mrk4_")
      end
    end
    guarded_v3_mrk3_layouts = [
      "obj_v3_dyn_v3_map_with_buckets_mrk3_",
      "obj_v3_dyn_v3_advanced_mrk3_",
      "obj_v3_dyn_v3_advanced_chunked_mrk3_",
    ]
    expected_guards = all.select do |label|
      label.includes?("_mrk3_") && guarded_v3_mrk3_layouts.any? { |layout| label.starts_with?(layout) }
    end
    held_out_mrk4_layouts = [
      "obj_v3_dyn_v3_map_with_buckets_mrk4_",
      "obj_v3_dyn_v3_advanced_mrk4_",
    ]
    expected_held_out = all.select do |label|
      label.includes?("_mrk4_") && held_out_mrk4_layouts.any? { |layout| label.starts_with?(layout) }
    end

    all.size.should eq(48)
    positive.size.should eq(28)
    guards.size.should eq(12)
    held_out.size.should eq(8)
    positive.to_set.should eq(expected_positive.to_set)
    guards.to_set.should eq(expected_guards.to_set)
    held_out.to_set.should eq(expected_held_out.to_set)
    (positive + guards + held_out).uniq.size.should eq(48)
    (positive + guards + held_out).to_set.should eq(all.to_set)
    positive_set = positive.to_set
    guard_set = guards.to_set
    held_out_set = held_out.to_set
    (positive_set & guard_set).should be_empty
    (positive_set & held_out_set).should be_empty
    (guard_set & held_out_set).should be_empty
  end
end

if ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]?
  describe "Compact static root-JSON matrix native qualification (W263)" do
    root = w263_root_matrix_evidence_root
    summary, manifest, store_root = w263_root_matrix_authenticate(root)
    expected = CompactJsonW263Fixture.expected_signatures["root"]

    w263_root_matrix_positive_labels.each do |label|
      it "reads #{label} with the declared String profile and native root literals" do
        part_path = w263_root_matrix_part_path(summary, manifest, store_root, label)
        w263_root_matrix_assert_native_rows!(summary, label)

        # Use a fresh reader for each selection so each EOF-first operation is
        # an independently exercised preparation/decode request.
        eof_reader = w263_root_matrix_open(part_path, label)
        eof_reader.read_marks(eof_reader.mark_count, 0).should be_empty
        eof_reader.prepared_context.mark_count.should eq(4)

        single_reader = w263_root_matrix_open(part_path, label)
        single = single_reader.read_marks(0, 1).flatten
        single.map { |document| w263_root_matrix_signature(document) }.should eq(expected[0, 2])

        cross_reader = w263_root_matrix_open(part_path, label)
        cross = cross_reader.read_marks(1, 2).flatten
        cross.map { |document| w263_root_matrix_signature(document) }.should eq(expected[2, 4])

        full_reader = w263_root_matrix_open(part_path, label)
        full = full_reader.read_marks(0, full_reader.mark_count).flatten
        full.map { |document| w263_root_matrix_signature(document) }.should eq(expected)
        full_reader.prepared_context.mark_count.should eq(4)
      end
    end

    w263_root_matrix_guard_labels.each do |label|
      it "keeps #{label} behind the explicit MRK3 UnsupportedFormat guard" do
        part_path = w263_root_matrix_part_path(summary, manifest, store_root, label)
        reader = nil.as(CrystalClick::CompactStaticJsonBulkColumnReader?)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          current = CrystalClick::CompactStaticJsonBulkColumnReader.open(
            part_path,
            "root",
            CompactJsonW263Fixture.json_type,
          )
          reader = current
          current.read_marks(current.mark_count, 0)
        end
        if current = reader
          expect_raises(ArgumentError) { current.prepared_context }
        end
      end
    end
  end
end
