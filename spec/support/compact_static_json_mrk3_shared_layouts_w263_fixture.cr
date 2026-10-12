require "json"
require "digest/sha256"
require "../../scripts/support/compact_json_w263_fixture"

module CompactStaticJsonMrk3SharedLayoutsW263Fixture
  extend self

  HELPER_BINARY_SHA256 = "f8c28dec05cecb4a0de424d1163e8eb72a6de1d21d79273cee312505718ff194"
  TARGET_LAYOUTS = [
    {"obj_v3_dyn_v3_map_with_buckets", 1_u64},
    {"obj_v3_dyn_v3_advanced", 2_u64},
    {"obj_v3_dyn_v3_advanced_chunked", 3_u64},
  ]
  ROWS = [2_u64, 2_u64, 2_u64, 2_u64]

  def all_labels : Array(String)
    layouts = {
      "obj_v1_dyn_v1_map",
      "obj_v2_dyn_v2_map",
      "obj_v3_dyn_v3_map",
      "obj_v3_dyn_v3_map_with_buckets",
      "obj_v3_dyn_v3_advanced",
      "obj_v3_dyn_v3_advanced_chunked",
    }
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

  def target_labels : Array(String)
    labels = [] of String
    TARGET_LAYOUTS.each do |layout, _shared_version|
      {0, 1}.each do |string_version|
        {"basic", "compact"}.each do |variant_mode|
          labels << "#{layout}_mrk3_s#{string_version}_variant_#{variant_mode}"
        end
      end
    end
    labels
  end

  def evidence_root : String
    supplied = ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]? ||
               raise "CRYSTAL_CLICK_W263_EVIDENCE_ROOT must name the authenticated baseline capture"
    root = File.realpath(supplied)
    raise ArgumentError.new("W263 evidence root must be supplied canonically") unless File.expand_path(supplied) == root
    root
  end

  def source_part(
    root : String,
    label : String,
  ) : NamedTuple(path: String, inventory: Array(Tuple(String, Int64, String)))
    unless target_labels.includes?(label)
      raise ArgumentError.new("W263 shared-layout fixture label is outside the 12 MRK3 target cells")
    end

    summary_path = canonical_file!(root, "summary.json", 16_i64 * 1024 * 1024)
    manifest_path = canonical_file!(root, "parts/native_manifest.json", 4_i64 * 1024 * 1024)
    summary = JSON.parse(File.read(summary_path))
    manifest = JSON.parse(File.read(manifest_path))
    labels = all_labels

    summary["format"].as_s.should eq("compact_json_w263_probe_summary_v1")
    summary["mode"].as_s.should eq("baseline")
    # This describes the captured ClickHouse helper path only; it is not the
    # expected result of the Crystal reader under test.
    summary["status"].as_s.should eq("expected_json_unsupported")
    summary["row_count"].as_i.should eq(CompactJsonW263Fixture::ROWS.to_i64)
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
    manifest_labels = manifest["parts"].as_a.map { |entry| entry["label"].as_s }
    manifest_labels.sort.should eq(labels.sort)

    store_root_literal = manifest["store_root"].as_s
    unless Dir.exists?(store_root_literal) && !File.symlink?(store_root_literal) && File.realpath(store_root_literal) == store_root_literal
      raise CrystalClick::CorruptPartError.new("W263 native store root is absent, linked or noncanonical")
    end
    store_root = store_root_literal
    store_root.should eq(File.realpath(File.join(root, "stores", "native")))

    assert_authenticated_helper_witness!(root, summary)
    assert_native_rows!(summary, label)
    assert_layout_witness!(summary, label)

    summary_record = summary["parts"][label]
    manifest_entry = manifest["parts"].as_a.find { |entry| entry["label"].as_s == label } ||
                     raise CrystalClick::CorruptPartError.new("W263 native manifest lacks #{label}")
    summary_record["part_type"].as_s.should eq("Compact")
    summary_record["rows"].as_s.should eq(CompactJsonW263Fixture::ROWS.to_s)
    summary_record["marks"].as_s.should eq((CompactJsonW263Fixture::MARK_ROWS.size + 1).to_s)
    summary_record["mark_extension"].as_s.should eq(".mrk3")
    summary_record["part_name"].as_s.should eq(CompactJsonW263Fixture::PART_NAME)
    manifest_entry["table"].as_s.should eq("w263_#{label}")
    manifest_entry["part_type"].as_s.should eq("Compact")
    manifest_entry["rows"].as_s.should eq(CompactJsonW263Fixture::ROWS.to_s)
    manifest_entry["marks"].as_s.should eq((CompactJsonW263Fixture::MARK_ROWS.size + 1).to_s)
    manifest_entry["mark_extension"].as_s.should eq(".mrk3")
    manifest_entry["part_name"].as_s.should eq(CompactJsonW263Fixture::PART_NAME)
    manifest_entry["path"].as_s.should eq(summary_record["path"].as_s)

    part_path = manifest_entry["path"].as_s
    unless Dir.exists?(part_path) && !File.symlink?(part_path) && File.realpath(part_path) == part_path
      raise CrystalClick::CorruptPartError.new("W263 native part is absent, linked or noncanonical")
    end
    root_prefix = root.ends_with?(File::SEPARATOR) ? root : root + File::SEPARATOR
    store_prefix = store_root.ends_with?(File::SEPARATOR) ? store_root : store_root + File::SEPARATOR
    unless part_path.starts_with?(root_prefix) && part_path.starts_with?(store_prefix)
      raise CrystalClick::CorruptPartError.new("W263 part escapes the authenticated native store")
    end
    File.basename(part_path).should eq(CompactJsonW263Fixture::PART_NAME)

    inventory = manifest_entry["file_inventory"].as_a.map do |item|
      {item["path"].as_s, item["bytes"].as_i64, item["sha256"].as_s}
    end
    CompactJsonW263Fixture.assert_native_inventory!(part_path, inventory)
    serialization = JSON.parse(File.read(File.join(part_path, "serialization.json")))
    serialization.should eq(summary_record["serialization"])
    expected_string_version = label.includes?("_s1_") ? 1 : 0
    serialization["version"].as_i.should eq(1_i64)
    serialization["columns"].as_a.should be_empty
    serialization["types_serialization_versions"]["string"].as_i.should eq(expected_string_version.to_i64)
    serialization["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true

    {path: part_path, inventory: inventory}
  end

  def assert_layout_witness!(summary : JSON::Any, label : String) : Nil
    shared_version = TARGET_LAYOUTS.find { |layout, _version| label.starts_with?(layout + "_mrk3_") }
      .try(&.[1]) || raise ArgumentError.new("W263 label has no shared-layout version")
    helper_cells = summary["helper"]["result"]["cells"].as_a
    cell = helper_cells.find { |entry| entry["label"].as_s == label } ||
           raise CrystalClick::CorruptPartError.new("W263 authenticated helper lacks #{label}")
    persisted = cell["persisted_root_layout"]
    persisted["mark_format"].as_s.should eq("mrk3")
    granules = persisted["granules"].as_a
    granules.size.should eq(ROWS.size)

    granules.each_with_index do |granule, mark|
      granule["mark"].as_i.should eq(mark.to_i64)
      granule["row_offset"].as_i.should eq((mark * 2).to_i64)
      granule["row_count"].as_i.should eq(2_i64)
      granule["wire_version"].as_i.should eq(4_i64)
      granule["shared_data_version"].as_i.should eq(shared_version.to_i64)
      granule["bucket_count"].as_i.should eq(2_i64)
      granule["dynamic_paths"].as_a.map(&.as_s).should eq(["note", "sample"])
      granule["first_stream"].raw.should be_nil
      granule["structure_prefix_bytes"].as_i.should eq(mark == 0 ? 40 : 24)

      if mark == 0
        granule["statistics_present"].as_bool.should be_true
        granule["statistics_counts"].as_a.map(&.as_i).should eq([8_i64, 8_i64])
        granule["statistics_shared"].as_a.map do |entry|
          {entry["name"].as_s, entry["count"].as_i}
        end.should eq([{ "zz_overflow", 8_i64 }])
      else
        granule["statistics_present"].as_bool.should be_false
        granule["statistics_counts"].as_a.should be_empty
        granule["statistics_shared"].as_a.should be_empty
      end

      sites = granule["object_sites"].as_a
      if shared_version == 3_u64
        sites.map { |site| {site["column"].as_s, site["owner"].as_s} }.should eq([
          {"root", "root"}, {"docs", "docs"}, {"tagged", "tagged%2Edoc"},
          {"pair", "pair%2Eleft"}, {"pair", "pair%2Eright"},
        ])
        root_sites = sites.select { |site| site["column"].as_s == "root" && site["owner"].as_s == "root" }
        root_sites.size.should eq(1)
        root_site = root_sites[0]
        root_site["wire_version"].as_i.should eq(4_i64)
        root_site["shared_data_version"].as_i.should eq(3_i64)
        root_site["bucket_count"].as_i.should eq(2_i64)
        root_site["dynamic_paths"].as_a.map(&.as_s).should eq(["note", "sample"])
        root_site["parent_occurrence_source"].as_s.should eq("one_object_per_parent_row")
        occurrences = root_site["parent_row_occurrences"].as_a.map(&.as_i)
        occurrences.should eq([1, 1])
        buckets = root_site["buckets"].as_a
        buckets.map { |bucket| bucket["bucket"].as_i }.should eq([0_i64, 1_i64])
        buckets.each_with_index do |bucket, bucket_index|
          chunks = bucket["chunks"].as_a
          chunks.size.should eq(2)
          chunks.map { |chunk| chunk["row_count"].as_i }.should eq([1_i64, 1_i64])
          expected_paths = bucket_index == 0 ? [] of String : ["zz_overflow"]
          chunks.each do |chunk|
            chunk["paths"].as_a.map(&.as_s).should eq(expected_paths)
          end
        end
      else
        sites.should be_empty
      end
    end
    nil
  end

  def assert_native_inventory!(source : NamedTuple(path: String, inventory: Array(Tuple(String, Int64, String)))) : Nil
    CompactJsonW263Fixture.assert_native_inventory!(source[:path], source[:inventory])
  end

  private def assert_native_rows!(summary : JSON::Any, label : String) : Nil
    native_rows = summary["native_rows"].as_h
    expected = CompactJsonW263Fixture.root_values
    expected.each_with_index do |value, index|
      key = "w263_#{label}|#{index + 1}"
      row = native_rows[key]?.try(&.as_a) ||
            raise CrystalClick::CorruptPartError.new("W263 native root JSON oracle lacks #{key}")
      raise CrystalClick::CorruptPartError.new("W263 native JSON row is truncated for #{key}") unless row.size > 7
      actual = JSON.parse(String.new(decode_hex(row[7].as_s)))
      unless actual.as_h == json_value(value).as_h
        raise CrystalClick::CorruptPartError.new("W263 native root JSON differs from the independent fixture for #{key}")
      end
    end
    nil
  end

  private def assert_authenticated_helper_witness!(root : String, summary : JSON::Any) : Nil
    helper = summary["helper"]
    helper["sha256"].as_s.should eq(HELPER_BINARY_SHA256)
    invocation = summary["helper_invocation"]
    invocation["exit"].as_i.should eq(0_i64)
    invocation["process_classification"].as_s.should eq("success")
    invocation["expected_binary_sha256"].as_s.should eq(HELPER_BINARY_SHA256)
    invocation["binary_sha_after"].as_s.should eq(HELPER_BINARY_SHA256)
    invocation["stdout_file"].as_s.should eq("baseline_helper.stdout")

    stdout_path = canonical_file!(root, "invocations/baseline_helper.stdout", 2_i64 * 1024 * 1024)
    File.size(stdout_path).to_i64.should eq(invocation["stdout_bytes"].as_i64)
    Digest::SHA256.hexdigest(File.read(stdout_path)).should eq(invocation["stdout_sha256"].as_s)
    stdout = JSON.parse(File.read(stdout_path))
    stdout.should eq(helper["result"])
    stdout["format"].as_s.should eq("compact_json_w263_baseline_helper_v1")
    # Capture provenance only. Crystal-side positive expectations live in this spec.
    stdout["status"].as_s.should eq("expected_unsupported")
    stdout["cells"].as_a.map { |entry| entry["label"].as_s }.sort.should eq(all_labels.sort)
    nil
  end

  private def canonical_file!(root : String, relative : String, maximum_bytes : Int64) : String
    path = File.join(root, relative)
    unless File.file?(path) && !File.symlink?(path) && File.realpath(path) == path
      raise CrystalClick::CorruptPartError.new("W263 evidence file is absent, linked or noncanonical: #{relative}")
    end
    raise CrystalClick::CorruptPartError.new("W263 evidence file exceeds its size bound: #{relative}") if File.size(path).to_i64 > maximum_bytes
    path
  end

  private def decode_hex(hex : String) : Bytes
    source = hex.to_slice
    raise CrystalClick::CorruptPartError.new("W263 native root JSON hex has odd length") unless source.size.even?
    bytes = Bytes.new(source.size // 2)
    bytes.size.times do |index|
      begin
        bytes[index] = String.new(source[index * 2, 2]).to_i(16).to_u8
      rescue ex : ArgumentError
        raise CrystalClick::CorruptPartError.new("W263 native root JSON hex is malformed: #{ex.message}")
      end
    end
    bytes
  end

  private def json_value(value : CrystalClick::BinaryValue) : JSON::Any
    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_JSON
      fields = Hash(String, JSON::Any).new
      value.json_row.entries.each do |path, child|
        fields[path] = json_value(child)
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
end
