require "json"
require "digest/sha256"
require "file_utils"
require "set"
require "../../scripts/support/compact_json_w263_fixture"

# Authentication and independent native/public oracles for the captured W263
# recursive JSON declaration matrix. The native capture remains baseline data:
# this helper neither upgrades its mode nor regenerates any native bytes.
module CompactJsonRecursivePublicW263Fixture
  extend self

  EVIDENCE_ROOT = "/private/tmp/crystal-click-w263-multichunk-baseline.b1p2QS"
  SUMMARY_SHA256 = "da4492e3cd037298d27ccabb4d415d16dc5b38fc54071c42183b3a45b642ca4b"
  MANIFEST_SHA256 = "3061107cdf55f6547c03bf210822902202839f84280b45da9379c3ae94b8fffb"
  FIXTURE_SOURCE_PATH = "/Users/sergey/Projects/Crystal/crystal-click/scripts/support/compact_json_w263_fixture.cr"
  FIXTURE_SOURCE_SHA256 = "dead84dd7b465297336e2ba98c219995e9b85929f3fcdeb6d333b869eaf44a30"

  JSON_ROW_FIELDS = {
    "root"   => 7,
    "docs"   => 14,
    "tagged" => 15,
    "pair"   => 16,
  } of String => Int32
  JSON_COLUMNS = ["root", "docs", "tagged", "pair"]
  MIXED_COLUMNS = ["pk", "root", "docs", "tagged", "pair"]

  EXPECTED_SOURCE_HASHES = [
    {"/Users/sergey/Projects/Crystal/crystal-click/scripts/check_array_json_parts_w185.rb", "a71366bf4e87ed7649373c0c251b865e75ac6cbe67263605a6ceb576ec4b1451"},
    {"/Users/sergey/Projects/Crystal/crystal-click/scripts/check_compact_json_w263.cr", "6752000d59766d12e9231de1064fabe74a3c1318db2b6835c430af587fbd4986"},
    {"/Users/sergey/Projects/Crystal/crystal-click/scripts/check_json_binary_kernel_w180.rb", "f4da2177f787fd1dc5a511cb6de8c47d7a44538efda4d26a25c4af1fb47b0c05"},
    {"/Users/sergey/Projects/Crystal/crystal-click/scripts/probe_compact_json_w263.rb", "8a5de3df7f4080daae0e345fa8241cf7ac21206affcbcab417c82d3fa77b7360"},
    {"/Users/sergey/Projects/Crystal/crystal-click/scripts/probe_json_array_storage_w183.rb", "ba628aa7037bb4421a0e7456d282e359b6ff2ae1aab9a4667776742237697adf"},
    {"/Users/sergey/Projects/Crystal/crystal-click/scripts/stock_part_probe_support_w191.rb", "f8302039adc306c4d94d0d4ea28919616eb1dc50ca2c7540c0d861e0282009e1"},
    {FIXTURE_SOURCE_PATH, FIXTURE_SOURCE_SHA256},
  ] of Tuple(String, String)

  def all_labels : Array(String)
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

  def evidence_root : String
    supplied = ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]? ||
               raise "CRYSTAL_CLICK_W263_EVIDENCE_ROOT must name the authenticated baseline capture"
    root = File.realpath(supplied)
    raise ArgumentError.new("W263 evidence root must be supplied canonically") unless File.expand_path(supplied) == root
    raise ArgumentError.new("W263 evidence root is not the original baseline capture") unless root == EVIDENCE_ROOT
    root
  end

  def authenticate(root : String) : Tuple(JSON::Any, JSON::Any, String)
    summary_path = File.join(root, "summary.json")
    manifest_path = File.join(root, "parts", "native_manifest.json")
    {summary_path, manifest_path}.each do |path|
      unless File.file?(path) && !File.symlink?(path) && File.realpath(path) == path
        raise CrystalClick::CorruptPartError.new("W263 evidence metadata is absent, linked or noncanonical")
      end
    end
    raise CrystalClick::CorruptPartError.new("W263 summary exceeds its evidence size bound") if File.size(summary_path) > 16 * 1024 * 1024
    raise CrystalClick::CorruptPartError.new("W263 native manifest exceeds its evidence size bound") if File.size(manifest_path) > 4 * 1024 * 1024
    raise CrystalClick::CorruptPartError.new("W263 original summary SHA256 differs") unless Digest::SHA256.hexdigest(File.read(summary_path)) == SUMMARY_SHA256
    raise CrystalClick::CorruptPartError.new("W263 original native manifest SHA256 differs") unless Digest::SHA256.hexdigest(File.read(manifest_path)) == MANIFEST_SHA256

    summary = JSON.parse(File.read(summary_path))
    manifest = JSON.parse(File.read(manifest_path))
    labels = all_labels
    labels.size.should eq(48)
    labels.uniq.size.should eq(48)
    {"mrk3", "mrk4"}.each do |format|
      labels.count { |label| label.includes?("_#{format}_") }.should eq(24)
    end
    {0, 1}.each do |version|
      labels.count { |label| label.includes?("_s#{version}_") }.should eq(24)
    end
    {"basic", "compact"}.each do |mode|
      labels.count { |label| label.ends_with?("_variant_#{mode}") }.should eq(24)
    end

    summary["format"].as_s.should eq("compact_json_w263_probe_summary_v1")
    summary["mode"].as_s.should eq("baseline")
    summary["status"].as_s.should eq("expected_json_unsupported")
    summary["row_count"].as_i.should eq(CompactJsonW263Fixture::ROWS)
    summary["mark_rows"].as_a.map { |rows| rows.as_i64.to_u64 }.should eq(CompactJsonW263Fixture::MARK_ROWS)
    summary["cells"].as_a.map(&.as_s).sort.should eq(labels.sort)
    summary["parts"].as_h.size.should eq(labels.size)
    summary["native_rows"].as_h.size.should eq(labels.size * CompactJsonW263Fixture::ROWS)
    summary_hashes = summary["source_hashes"].as_a.map do |record|
      {record["path"].as_s, record["sha256"].as_s}
    end
    summary_hashes.should eq(EXPECTED_SOURCE_HASHES)
    File.realpath(FIXTURE_SOURCE_PATH).should eq(FIXTURE_SOURCE_PATH)
    Digest::SHA256.hexdigest(File.read(FIXTURE_SOURCE_PATH)).should eq(FIXTURE_SOURCE_SHA256)

    invocation = summary["native_invocation"]
    invocation["exit"].as_i.should eq(0)
    invocation["process_classification"].as_s.should eq("success")
    invocation["process_kind"].as_s.should eq("clickhouse local")
    invocation["timed_out"].as_bool.should be_false
    invocation["max_threads"].as_i.should eq(1)
    invocation["max_memory_usage_bytes"].as_i64.should eq(536_870_912_i64)
    invocation["max_memory_usage_applicable"].as_bool.should be_true
    invocation["expected_binary_sha256"].as_s.should eq(CompactJsonW263Fixture::NATIVE_BINARY_SHA256)
    invocation["binary_sha_after"].as_s.should eq(CompactJsonW263Fixture::NATIVE_BINARY_SHA256)
    summary["clickhouse"]["sha256"].as_s.should eq(CompactJsonW263Fixture::NATIVE_BINARY_SHA256)
    summary["clickhouse"]["version"].as_s.should eq(CompactJsonW263Fixture::NATIVE_VERSION)
    summary["clickhouse"]["build"].as_s.should eq(CompactJsonW263Fixture::NATIVE_BUILD)
    summary["source_snapshot"]["path"].as_s.should eq(CompactJsonW263Fixture::NATIVE_SOURCE_PATH)
    summary["source_snapshot"]["revision"].as_s.should eq(CompactJsonW263Fixture::NATIVE_SOURCE_REVISION)
    summary["source_snapshot"]["observed_revision"].as_s.should eq(CompactJsonW263Fixture::NATIVE_SOURCE_REVISION)
    summary["source_snapshot"]["runtime_provenance_claimed"].as_bool.should be_false

    manifest["format"].as_s.should eq(CompactJsonW263Fixture::NATIVE_MANIFEST_FORMAT)
    manifest["mode"].as_s.should eq("baseline")
    manifest["clickhouse"]["sha256"].as_s.should eq(CompactJsonW263Fixture::NATIVE_BINARY_SHA256)
    manifest["clickhouse"]["version"].as_s.should eq(CompactJsonW263Fixture::NATIVE_VERSION)
    manifest["clickhouse"]["build"].as_s.should eq(CompactJsonW263Fixture::NATIVE_BUILD)
    manifest_source = manifest["source_snapshot"]
    manifest_source["path"].as_s.should eq(CompactJsonW263Fixture::NATIVE_SOURCE_PATH)
    manifest_source["revision"].as_s.should eq(CompactJsonW263Fixture::NATIVE_SOURCE_REVISION)
    manifest_source["observed_revision"].as_s.should eq(CompactJsonW263Fixture::NATIVE_SOURCE_REVISION)
    manifest_source["runtime_provenance_claimed"].as_bool.should be_false
    manifest["parts"].as_a.size.should eq(labels.size)
    manifest["parts"].as_a.map { |entry| entry["label"].as_s }.sort.should eq(labels.sort)

    store_root_path = manifest["store_root"].as_s
    unless !File.symlink?(store_root_path) && File.realpath(store_root_path) == store_root_path
      raise CrystalClick::CorruptPartError.new("W263 native store root is linked or noncanonical")
    end
    store_root = store_root_path
    store_root.should eq(File.realpath(File.join(root, "stores", "native")))
    {summary, manifest, store_root}
  end

  def source_part(evidence : Tuple(JSON::Any, JSON::Any, String), label : String)
    summary, manifest, store_root = evidence
    raise ArgumentError.new("W263 selected cell is outside the authenticated roster") unless all_labels.includes?(label)
    summary_record = summary["parts"][label]
    manifest_entry = manifest["parts"].as_a.find { |entry| entry["label"].as_s == label } ||
                     raise CrystalClick::CorruptPartError.new("W263 native manifest lacks #{label}")
    table_name = "w263_#{label}"
    extension = label.includes?("_mrk3_") ? ".mrk3" : ".mrk4"
    summary_record["part_type"].as_s.should eq("Compact")
    summary_record["rows"].as_s.should eq(CompactJsonW263Fixture::ROWS.to_s)
    summary_record["marks"].as_s.should eq((CompactJsonW263Fixture::MARK_ROWS.size + 1).to_s)
    summary_record["mark_extension"].as_s.should eq(extension)
    summary_record["part_name"].as_s.should eq(CompactJsonW263Fixture::PART_NAME)
    manifest_entry["table"].as_s.should eq(table_name)
    manifest_entry["part_type"].as_s.should eq("Compact")
    manifest_entry["rows"].as_s.should eq(CompactJsonW263Fixture::ROWS.to_s)
    manifest_entry["marks"].as_s.should eq((CompactJsonW263Fixture::MARK_ROWS.size + 1).to_s)
    manifest_entry["mark_extension"].as_s.should eq(extension)
    manifest_entry["part_name"].as_s.should eq(CompactJsonW263Fixture::PART_NAME)
    manifest_entry["path"].as_s.should eq(summary_record["path"].as_s)

    part_path = manifest_entry["path"].as_s
    unless !File.symlink?(part_path) && File.realpath(part_path) == part_path
      raise CrystalClick::CorruptPartError.new("W263 native part is linked or noncanonical")
    end
    prefix = File.join(store_root, "store") + File::SEPARATOR
    raise CrystalClick::CorruptPartError.new("W263 part escapes authenticated native store") unless part_path.starts_with?(prefix)
    File.basename(part_path).should eq(CompactJsonW263Fixture::PART_NAME)
    inventory = manifest_entry["file_inventory"].as_a.map do |item|
      {item["path"].as_s, item["bytes"].as_i64, item["sha256"].as_s}
    end
    CompactJsonW263Fixture.assert_native_inventory!(part_path, inventory)

    expected_columns = ["columns format version: 1", "#{CompactJsonW263Fixture::SCHEMA.size} columns:"]
    CompactJsonW263Fixture::SCHEMA.each do |name, type|
      expected_columns << "`#{name}` #{type}"
    end
    File.read(File.join(part_path, "columns.txt")).should eq(expected_columns.join("\n") + "\n")
    serialization = JSON.parse(File.read(File.join(part_path, "serialization.json")))
    serialization.should eq(summary_record["serialization"])
    expected_string_version = label.includes?("_s1_") ? 1 : 0
    summary_record["string_version"].as_i.should eq(expected_string_version)
    serialization["types_serialization_versions"]["string"].as_i.should eq(expected_string_version)
    serialization["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true
    {path: part_path, inventory: inventory, label: label}
  end

  def assert_native_json_rows!(summary : JSON::Any, label : String) : Nil
    table = "w263_#{label}"
    expected_by_column = {
      "root"   => CompactJsonW263Fixture.root_values,
      "docs"   => CompactJsonW263Fixture.docs_values,
      "tagged" => CompactJsonW263Fixture.tagged_values,
      "pair"   => CompactJsonW263Fixture.pair_values,
    } of String => Array(CrystalClick::BinaryValue)
    expected_by_column.each do |column, values|
      field_index = JSON_ROW_FIELDS[column]
      values.each_with_index do |expected_value, row_index|
        key = "#{table}|#{row_index + 1}"
        row = summary["native_rows"][key]?.try(&.as_a) ||
              raise CrystalClick::CorruptPartError.new("W263 native JSON oracle lacks #{key}")
        raise CrystalClick::CorruptPartError.new("W263 native JSON row shape differs for #{key}") unless row.size == 17
        actual = JSON.parse(String.new(decode_hex(row[field_index].as_s)))
        expected = json_value(expected_value)
        unless equal_json?(actual, expected)
          raise CrystalClick::CorruptPartError.new("W263 native #{column} JSON differs from its independent fixture for #{key}")
        end
      end
    end
    nil
  end

  def json_value(value : CrystalClick::BinaryValue) : JSON::Any
    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_JSON
      fields = Hash(String, JSON::Any).new
      value.json_row.entries.each do |path, child|
        fields[path] = json_value(child)
      end
      JSON::Any.new(fields)
    when CrystalClick::BinaryDataType::TAG_ARRAY,
         CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
         CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      JSON::Any.new(value.elements.map { |child| json_value(child) })
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

  def equal_json?(actual : JSON::Any, expected : JSON::Any) : Bool
    case expected.raw
    when Nil
      actual.raw.nil?
    when Bool
      actual.raw.is_a?(Bool) && actual.as_bool == expected.as_bool
    when Int64
      actual.raw.is_a?(Int64) && actual.as_i == expected.as_i
    when Float64
      if actual.raw.is_a?(Float64)
        actual.as_f.unsafe_as(UInt64) == expected.as_f.unsafe_as(UInt64)
      elsif actual.raw.is_a?(Int64)
        actual.as_i.to_f64.unsafe_as(UInt64) == expected.as_f.unsafe_as(UInt64)
      else
        false
      end
    when String
      actual.raw.is_a?(String) && actual.as_s == expected.as_s
    when Array(JSON::Any)
      return false unless actual.raw.is_a?(Array(JSON::Any))
      left = actual.as_a
      right = expected.as_a
      left.size == right.size && left.each_with_index.all? { |child, index| equal_json?(child, right[index]) }
    when Hash(String, JSON::Any)
      return false unless actual.raw.is_a?(Hash(String, JSON::Any))
      left = actual.as_h
      right = expected.as_h
      return false unless left.size == right.size && left.keys.to_set == right.keys.to_set
      right.all? { |key, child| equal_json?(left[key], child) }
    else
      false
    end
  end

  def decode_hex(hex : String) : Bytes
    source = hex.to_slice
    raise CrystalClick::CorruptPartError.new("W263 native JSON hex has odd length") unless source.size.even?
    bytes = Bytes.new(source.size // 2)
    bytes.size.times do |index|
      high = hex_nibble(source[index * 2])
      low = hex_nibble(source[index * 2 + 1])
      bytes[index] = ((high << 4) | low).to_u8
    end
    bytes
  end

  def hex_nibble(byte : UInt8) : UInt8
    case byte
    when '0'.ord.to_u8..'9'.ord.to_u8
      (byte - '0'.ord.to_u8).to_u8
    when 'a'.ord.to_u8..'f'.ord.to_u8
      (byte - 'a'.ord.to_u8 + 10).to_u8
    when 'A'.ord.to_u8..'F'.ord.to_u8
      (byte - 'A'.ord.to_u8 + 10).to_u8
    else
      raise CrystalClick::CorruptPartError.new("W263 native JSON hex contains a non-hex byte")
    end
  end

  def document_signature(document : CrystalClick::ObjectDocument) : String
    entries = document.paths.sort.map do |path|
      "#{path}=#{CompactJsonW263Fixture.value_signature(document.value_for(path))}"
    end
    "#{CompactJsonW263Fixture.json_type.name}{#{entries.join(",")}}"
  end

  def recursive_signature(
    schema : CrystalClick::StorageColumnSchema,
    value : CrystalClick::StorageColumnValue,
  ) : String
    if schema.tuple?
      raise CrystalClick::CorruptPartError.new("W263 recursive Tuple value/schema arity differs") unless value.tuple? && schema.child_count == value.child_count
      children = schema.child_count.times.map do |index|
        recursive_signature(schema.child_at(index), value.child_at(index))
      end
      "#{schema.declaration}(#{children.join(",")})"
    elsif schema.array?
      raise CrystalClick::CorruptPartError.new("W263 recursive Array value/schema differs") unless value.array?
      children = value.array_values.map { |child| recursive_signature(schema.child_at(0), child) }
      "#{schema.declaration}[#{children.join(";")}]"
    elsif schema.object?
      raise CrystalClick::CorruptPartError.new("W263 recursive JSON leaf differs") unless value.object?
      document_signature(value.object_document)
    elsif schema.bulk?
      raise CrystalClick::CorruptPartError.new("W263 recursive BinaryBulk leaf differs") unless value.bulk?
      CompactJsonW263Fixture.value_signature(value.bulk_value)
    else
      raise CrystalClick::UnsupportedFormatError.new("W263 recursive signature has an unknown schema node")
    end
  end

  def variant_signature(value : CrystalClick::VariantStringUInt64Value) : String
    case value
    when String
      "Variant(String, UInt64)#0(String:#{JSON::Any.new(value).to_json})"
    when UInt64
      "Variant(String, UInt64)#1(UInt64:#{value})"
    else
      "Variant(String, UInt64)#255(NULL)"
    end
  end

  def batch_column_signatures(batch : CrystalClick::WidePartTableBatch, column : String) : Array(String)
    signatures = [] of String
    case column
    when "pk"
      batch.values_for(column, UInt64).each { |value| signatures << "UInt64:#{value}" }
    when "root"
      batch.object_documents_for(column).each { |document| signatures << document_signature(document) }
    when "docs"
      batch.array_object_documents_for(column).each do |documents|
        children = documents.map { |document| document_signature(document) }
        signatures << "#{CompactJsonW263Fixture.docs_type.name}[#{children.join(";")}]"
      end
    when "tagged", "pair"
      type = column == "tagged" ? CompactJsonW263Fixture.tagged_type.name : CompactJsonW263Fixture.pair_type.name
      schema = CrystalClick::StorageColumnSchema.parse(type)
      batch.recursive_values_for(column).each do |value|
        signatures << recursive_signature(schema, value)
      end
    else
      raise CrystalClick::UnsupportedFormatError.new("W263 public batch has no recursive carrier for #{column}")
    end
    signatures
  end

  def scan_signatures(
    table : CrystalClick::CompactPartTable | CrystalClick::TypedPartTable,
    columns : Array(String),
  ) : Hash(String, Array(String))
    actual = Hash(String, Array(String)).new
    columns.each { |column| actual[column] = [] of String }
    table.scan_typed(batch_rows: 8) do |batch|
      batch.part_index.should eq(0)
      batch.part_name.should eq(CompactJsonW263Fixture::PART_NAME)
      columns.each do |column|
        actual[column].concat(batch_column_signatures(batch, column))
      end
    end
    actual
  end

  def primary_keys(table : CrystalClick::CompactPartTable | CrystalClick::TypedPartTable) : Array(UInt64)
    keys = [] of UInt64
    table.scan_typed do |batch|
      keys.concat(batch.values_for("pk", UInt64).to_a)
    end
    keys
  end

  def expected_signatures : Hash(String, Array(String))
    expected = CompactJsonW263Fixture.expected_signatures
    expected["pk"] = (1_u64..CompactJsonW263Fixture::ROWS.to_u64).map { |key| "UInt64:#{key}" }.to_a
    expected
  end

  def subset(expected : Hash(String, Array(String)), start : Int32, count : Int32) : Hash(String, Array(String))
    expected.keys.each_with_object(Hash(String, Array(String)).new) do |column, selected|
      selected[column] = expected[column][start, count]
    end
  end

  def assert_public_matrix!(
    table : CrystalClick::CompactPartTable | CrystalClick::TypedPartTable,
    expected : Hash(String, Array(String)),
  ) : Nil
    table.part_mark_row_counts.should eq([CompactJsonW263Fixture::MARK_ROWS])
    table.total_row_count.should eq(CompactJsonW263Fixture::ROWS.to_u64)

    scan_signatures(table, MIXED_COLUMNS).should eq(expected.select { |column, _| MIXED_COLUMNS.includes?(column) })

    single = Hash(String, Array(String)).new
    MIXED_COLUMNS.each { |column| single[column] = [] of String }
    table.scan_typed_candidate_marks([[0_i32]]) do |batch|
      batch.mark_index.should eq(0)
      batch.part_row_offset.should eq(0_u64)
      MIXED_COLUMNS.each { |column| single[column].concat(batch_column_signatures(batch, column)) }
    end
    single.should eq(subset(expected.select { |column, _| MIXED_COLUMNS.includes?(column) }, 0, 2))

    cross = Hash(String, Array(String)).new
    MIXED_COLUMNS.each { |column| cross[column] = [] of String }
    table.scan_typed_window(1_u64, max_rows: 4) do |batch|
      MIXED_COLUMNS.each { |column| cross[column].concat(batch_column_signatures(batch, column)) }
    end
    cross.should eq(subset(expected.select { |column, _| MIXED_COLUMNS.includes?(column) }, 1, 4))

    later = Hash(String, Array(String)).new
    MIXED_COLUMNS.each { |column| later[column] = [] of String }
    table.scan_typed_window(3_u64, max_rows: 3) do |batch|
      MIXED_COLUMNS.each { |column| later[column].concat(batch_column_signatures(batch, column)) }
    end
    later.should eq(subset(expected.select { |column, _| MIXED_COLUMNS.includes?(column) }, 3, 3))

    eof_callbacks = 0
    table.scan_typed_window(CompactJsonW263Fixture::ROWS.to_u64, max_rows: 1) { |_batch| eof_callbacks += 1 }
    eof_callbacks.should eq(0)
    empty_candidate_callbacks = 0
    table.scan_typed_candidate_marks([[] of Int32]) { |_batch| empty_candidate_callbacks += 1 }
    empty_candidate_callbacks.should eq(0)
    nil
  end

  def offline_value_signature(
    value : CrystalClick::OfflineColumnValue | Array(CrystalClick::ObjectDocument) | CrystalClick::StorageColumnValue,
    column : String,
  ) : String
    case column
    when "root"
      document_signature(value.as(CrystalClick::ObjectDocument))
    when "docs"
      documents = value.as?(Array(CrystalClick::ObjectDocument)) ||
                  raise CrystalClick::UnsupportedFormatError.new("W263 offline docs carrier missing: expected Array(ObjectDocument)")
      children = documents.map { |document| document_signature(document) }
      "#{CompactJsonW263Fixture.docs_type.name}[#{children.join(";")}]"
    when "tagged", "pair"
      declaration = column == "tagged" ? CompactJsonW263Fixture.tagged_type.name : CompactJsonW263Fixture.pair_type.name
      schema = CrystalClick::StorageColumnSchema.parse(declaration)
      recursive = value.as?(CrystalClick::StorageColumnValue) ||
                  raise CrystalClick::UnsupportedFormatError.new("W263 offline #{column} carrier missing: expected StorageColumnValue")
      recursive_signature(schema, recursive)
    else
      raise CrystalClick::UnsupportedFormatError.new("W263 offline recursive carrier is not defined for #{column}")
    end
  end

  def offline_signatures(table : CrystalClick::OfflineTable, column : String) : Array(String)
    table[column].values(max_rows: CompactJsonW263Fixture::ROWS.to_u64)
      .map { |value| offline_value_signature(value, column) }
  end

  def prepare_offline_catalog(part_path : String, work_root : String) : NamedTuple(root: String, part: String)
    expanded = File.expand_path(work_root)
    raise ArgumentError.new("W263 offline work root already exists") if File.exists?(expanded) || File.symlink?(expanded)
    parent = File.dirname(expanded)
    raise ArgumentError.new("W263 offline work root parent is absent or linked") unless Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent
    Dir.mkdir(expanded, 0o700)
    root = File.join(expanded, "catalog")
    metadata = File.join(root, "metadata")
    store = File.join(root, "store")
    database_path = File.join(store, CompactJsonW263Fixture::CATALOG_DATABASE_UUID[0, 3], CompactJsonW263Fixture::CATALOG_DATABASE_UUID)
    table_path = File.join(store, CompactJsonW263Fixture::CATALOG_TABLE_UUID[0, 3], CompactJsonW263Fixture::CATALOG_TABLE_UUID)
    FileUtils.mkdir_p(metadata)
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{CompactJsonW263Fixture::CATALOG_DATABASE_UUID}'\nENGINE = Atomic\n")
    declarations = CompactJsonW263Fixture::SCHEMA.map { |name, type| "    `#{name}` #{type}" }.join(",\n")
    File.write(File.join(database_path, "events.sql"), "ATTACH TABLE _ UUID '#{CompactJsonW263Fixture::CATALOG_TABLE_UUID}'\n(\n#{declarations}\n)\nENGINE = MergeTree\nORDER BY pk\n")
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"), 0o700)
    copied = File.join(table_path, CompactJsonW263Fixture::PART_NAME)
    FileUtils.cp_r(part_path, copied)
    {root: root, part: copied}
  end
end
