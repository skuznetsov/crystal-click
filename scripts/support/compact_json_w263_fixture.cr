require "json"
require "digest/sha256"
require "file_utils"
require "set"

# Independent logical fixture for the W263 stock-authored Compact JSON probe.
# The Ruby probe has a separately authored copy of all row literals and is the
# cross-language oracle; these constructors only provide Crystal-side carrier
# values and deterministic signatures for values returned by public readers.
module CompactJsonW263Fixture
  extend self

  NATIVE_MANIFEST_FORMAT = "compact_json_w263_native_manifest_v1"
  NATIVE_LABEL = "obj_v3_dyn_v3_advanced_chunked_mrk4_s1_variant_compact"
  NATIVE_BINARY_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  NATIVE_VERSION = "26.10.1.1201"
  NATIVE_BUILD = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  NATIVE_SOURCE_PATH = "/private/tmp/clickhouse-w254-upstream.AqeqyC"
  NATIVE_SOURCE_REVISION = "ed30948f095ecb70679986d7d60e27ad770ae27a"
  PART_NAME = "all_1_1_0"
  CATALOG_DATABASE_UUID = "26300000-0000-4000-8000-000000000001"
  CATALOG_TABLE_UUID = "26300000-0000-4000-8000-000000000002"
  MAX_PART_FILES = 4096
  MAX_PART_BYTES = 64_i64 * 1024 * 1024

  ROWS = 8
  MARK_ROWS = [2_u64, 2_u64, 2_u64, 2_u64]
  DOC_COUNTS = [0, 1, 3, 2, 0, 2, 1, 4]
  TAGGED_COUNTS = [2, 0, 1, 0, 3, 1, 0, 2]
  FLOAT_BITS = [
    0x3ff8_0000_0000_0000_u64, 0x4004_0000_0000_0000_u64,
    0x400e_0000_0000_0000_u64, 0x4014_0000_0000_0000_u64,
    0x4019_0000_0000_0000_u64, 0x401e_0000_0000_0000_u64,
    0x4021_0000_0000_0000_u64, 0x4023_0000_0000_0000_u64,
  ]

  SCHEMA = [
    {"pk", "UInt64"},
    {"scalar", "UInt8"},
    {"text", "String"},
    {"payload", "Dynamic(max_types=1)"},
    {"choice", "Variant(String, UInt64)"},
    {"root", "JSON(max_dynamic_types=1, max_dynamic_paths=2, id UInt8, label String)"},
    {"docs", "Array(JSON(max_dynamic_types=1, max_dynamic_paths=2, id UInt8, label String))"},
    {"tagged", "Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=2, id UInt8, label String), slot UInt8))"},
    {"pair", "Tuple(left JSON(max_dynamic_types=1, max_dynamic_paths=2, id UInt8, label String), right JSON(max_dynamic_types=1, max_dynamic_paths=2, id UInt8, label String))"},
  ] of Tuple(String, String)

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      # Three inferred paths compete for two admitted Dynamic paths. The
      # native probe separately records JSONSharedDataPaths, so the shared
      # spill is observed from the persisted stock part rather than inferred
      # here.
      max_dynamic_paths: 2,
      max_dynamic_types: 1,
      typed_paths: {
        "id"    => CrystalClick::BinaryDataType.primitive("UInt8"),
        "label" => CrystalClick::BinaryDataType.primitive("String"),
      } of String => CrystalClick::BinaryDataType,
    )
  end

  def dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  def variant_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("String"),
      CrystalClick::BinaryDataType.primitive("UInt64"),
    ] of CrystalClick::BinaryDataType)
  end

  def docs_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(json_type)
  end

  def tagged_item_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.tuple(
      [json_type, CrystalClick::BinaryDataType.primitive("UInt8")] of CrystalClick::BinaryDataType,
      ["doc", "slot"],
    )
  end

  def tagged_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(tagged_item_type)
  end

  def pair_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.tuple(
      [json_type, json_type] of CrystalClick::BinaryDataType,
      ["left", "right"],
    )
  end

  def sample_value(identity : Int32) : CrystalClick::BinaryValue
    if identity.odd?
      CrystalClick::BinaryValue.int64((identity * 10).to_i64)
    else
      CrystalClick::BinaryValue.float64_bits(FLOAT_BITS[(identity - 1) % FLOAT_BITS.size])
    end
  end

  def json_value(identity : Int32, label : String = "json-#{identity}") : CrystalClick::BinaryValue
    type = json_type
    row = CrystalClick::BinaryJsonRow.new(
      type,
      [
        {"id", uint8(identity.to_u8)},
        {"label", CrystalClick::BinaryValue.string(label)},
        {"note", CrystalClick::BinaryValue.string("note-#{identity}")},
        {"sample", sample_value(identity)},
        {"zz_overflow", CrystalClick::BinaryValue.string("overflow-#{identity}")},
      ] of Tuple(String, CrystalClick::BinaryValue),
    )
    CrystalClick::BinaryValue.json(type, row)
  end

  def root_values : Array(CrystalClick::BinaryValue)
    (1..ROWS).map { |index| json_value(index) }.to_a
  end

  def docs_values : Array(CrystalClick::BinaryValue)
    type = docs_type
    DOC_COUNTS.each_with_index.map do |count, row_index|
      values = Array(CrystalClick::BinaryValue).new(count)
      count.times do |child_index|
        identity = 20 + row_index * 4 + child_index
        values << json_value(identity, "doc-#{row_index + 1}-#{child_index + 1}")
      end
      CrystalClick::BinaryValue.array(type, values)
    end.to_a
  end

  def tagged_values : Array(CrystalClick::BinaryValue)
    array_type = tagged_type
    item_type = tagged_item_type
    TAGGED_COUNTS.each_with_index.map do |count, row_index|
      items = Array(CrystalClick::BinaryValue).new(count)
      count.times do |child_index|
        identity = 80 + row_index * 4 + child_index
        items << CrystalClick::BinaryValue.tuple(
          item_type,
          [
            json_value(identity, "tag-#{row_index + 1}-#{child_index + 1}"),
            uint8((child_index + 1).to_u8),
          ] of CrystalClick::BinaryValue,
        )
      end
      CrystalClick::BinaryValue.array(array_type, items)
    end.to_a
  end

  def pair_values : Array(CrystalClick::BinaryValue)
    type = pair_type
    (1..ROWS).map do |index|
      CrystalClick::BinaryValue.tuple(
        type,
        [
          json_value(120 + index, "left-#{index}"),
          json_value(140 + index, "right-#{index}"),
        ] of CrystalClick::BinaryValue,
      )
    end.to_a
  end

  def scalar_values : Array(CrystalClick::BinaryValue)
    (1..ROWS).map { |index| uint8(index.to_u8) }.to_a
  end

  def text_values : Array(CrystalClick::BinaryValue)
    (1..ROWS).map { |index| CrystalClick::BinaryValue.string("text-#{index}") }.to_a
  end

  def payload_values : Array(CrystalClick::BinaryValue)
    type = dynamic_type
    leaves = [
      uint8(7_u8),
      CrystalClick::BinaryValue.string("payload-two"),
      CrystalClick::BinaryValue.float64_bits(0x3ff8_0000_0000_0000_u64),
      CrystalClick::BinaryValue.uint64(44_u64),
      uint8(15_u8),
      CrystalClick::BinaryValue.string("payload-six"),
      CrystalClick::BinaryValue.float64_bits(0xc002_0000_0000_0000_u64),
      CrystalClick::BinaryValue.uint64(88_u64),
    ] of CrystalClick::BinaryValue
    leaves.map { |leaf| CrystalClick::BinaryValue.dynamic(type, leaf) }.to_a
  end

  def choice_values : Array(CrystalClick::BinaryValue)
    type = variant_type
    [
      CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.string("choice-one")),
      CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.uint64(22_u64)),
      CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.string("choice-three")),
      CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.uint64(44_u64)),
      CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.string("choice-five")),
      CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.uint64(66_u64)),
      CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.string("choice-seven")),
      CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.uint64(88_u64)),
    ] of CrystalClick::BinaryValue
  end

  def value_signature(value : CrystalClick::BinaryValue) : String
    type = value.type
    return "#{type.name}=NULL" if value.is_null?

    case type.tag
    when CrystalClick::BinaryDataType::TAG_JSON
      entries = value.json_row.entries.sort_by { |path, _child| path }
        .map { |path, child| "#{path}=#{value_signature(child)}" }
      "#{type.name}{#{entries.join(",")}}"
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      "#{type.name}<#{value_signature(value.child_at(0))}>"
    when CrystalClick::BinaryDataType::TAG_ARRAY
      "#{type.name}[#{value.elements.map { |child| value_signature(child) }.join(";")}]"
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      "#{type.name}(#{value.elements.map { |child| value_signature(child) }.join(",")})"
    when CrystalClick::BinaryDataType::TAG_VARIANT
      index = value.variant_index? || raise CrystalClick::CorruptPartError.new("W263 literal Variant lacks an arm index")
      child = value.variant_child? || raise CrystalClick::CorruptPartError.new("W263 literal Variant lacks its arm value")
      "#{type.name}##{index}(#{value_signature(child)})"
    when CrystalClick::BinaryDataType::TAG_STRING
      "String:#{JSON::Any.new(value.as_string).to_json}"
    when CrystalClick::BinaryDataType::TAG_UINT8
      "UInt8:#{value.byte_at(0)}"
    when CrystalClick::BinaryDataType::TAG_UINT64
      "UInt64:#{value.as_uint64}"
    when CrystalClick::BinaryDataType::TAG_INT64
      "Int64:#{value.as_int64}"
    when CrystalClick::BinaryDataType::TAG_FLOAT64
      "Float64:0x#{value.as_float64_bits.to_s(16).rjust(16, '0')}"
    else
      raise CrystalClick::UnsupportedFormatError.new("W263 literal signature lacks #{type.name}")
    end
  end

  def values_by_column : Hash(String, Array(CrystalClick::BinaryValue))
    {
      "scalar"  => scalar_values,
      "text"    => text_values,
      "payload" => payload_values,
      "choice"  => choice_values,
      "root"    => root_values,
      "docs"    => docs_values,
      "tagged"  => tagged_values,
      "pair"    => pair_values,
    } of String => Array(CrystalClick::BinaryValue)
  end

  # Expected public/offline signatures are assembled only from this fixture's
  # authored values. They are never learned from a decoded part.
  def expected_signatures : Hash(String, Array(String))
    expected = Hash(String, Array(String)).new
    values_by_column.each do |column, values|
      expected[column] = values.map { |value| expected_signature(column, value) }
    end
    expected
  end

  def expected_signature(column : String, value : CrystalClick::BinaryValue) : String
    case column
    when "scalar"
      "UInt8:#{value.byte_at(0)}"
    when "text"
      "String:#{JSON::Any.new(value.as_string).to_json}"
    when "choice"
      index = value.variant_index? || raise CrystalClick::CorruptPartError.new("W263 literal Variant lacks an arm index")
      child = value.variant_child? || raise CrystalClick::CorruptPartError.new("W263 literal Variant lacks its arm value")
      case index
      when 0
        "Variant(String, UInt64)#0(String:#{JSON::Any.new(child.as_string).to_json})"
      when 1
        "Variant(String, UInt64)#1(UInt64:#{child.as_uint64})"
      else
        raise CrystalClick::UnsupportedFormatError.new("W263 literal Variant arm is outside the expected declaration")
      end
    else
      value_signature(value)
    end
  end

  # Validate the exact stock-authored green evidence entry before copying it
  # into a minimal OfflineCatalog. This helper does not start ClickHouse or
  # synthesize/repair any part bytes.
  def prepare_offline_catalog(native_manifest_path : String, work_root : String) : {root: String, part: String, source_part: String, table: String, inventory: Array(Tuple(String, Int64, String))}
    manifest_path = File.expand_path(native_manifest_path)
    raise ArgumentError.new("W263 native manifest is absent or linked") unless File.file?(manifest_path) && !File.symlink?(manifest_path) && File.realpath(manifest_path) == manifest_path
    raise ArgumentError.new("W263 native manifest exceeds its byte bound") if File.size(manifest_path) > 4 * 1024 * 1024
    manifest = JSON.parse(File.read(manifest_path)).as_h
    raise ArgumentError.new("W263 native manifest format differs") unless manifest["format"].as_s == NATIVE_MANIFEST_FORMAT
    raise ArgumentError.new("W263 native manifest is not a Green capture") unless manifest["mode"].as_s == "green"

    clickhouse = manifest["clickhouse"].as_h
    raise ArgumentError.new("W263 ClickHouse SHA differs") unless clickhouse["sha256"].as_s == NATIVE_BINARY_SHA256
    raise ArgumentError.new("W263 ClickHouse version differs") unless clickhouse["version"].as_s == NATIVE_VERSION
    raise ArgumentError.new("W263 ClickHouse build differs") unless clickhouse["build"].as_s == NATIVE_BUILD

    source = manifest["source_snapshot"].as_h
    raise ArgumentError.new("W263 source snapshot path differs") unless source["path"].as_s == NATIVE_SOURCE_PATH
    raise ArgumentError.new("W263 source snapshot revision differs") unless source["revision"].as_s == NATIVE_SOURCE_REVISION
    raise ArgumentError.new("W263 source observation revision differs") unless source["observed_revision"].as_s == NATIVE_SOURCE_REVISION
    raise ArgumentError.new("W263 source/runtime identity is incorrectly claimed") unless source["runtime_provenance_claimed"].as_bool == false

    entry = manifest["parts"].as_a.find { |item| item.as_h["label"].as_s == NATIVE_LABEL }
      .try(&.as_h) || raise ArgumentError.new("W263 native manifest lacks its exact selected cell")
    raise ArgumentError.new("W263 selected part is not Compact") unless entry["part_type"].as_s == "Compact"
    raise ArgumentError.new("W263 selected part row/mark metadata differs") unless entry["rows"].as_s == "8" && entry["marks"].as_s == "5"
    raise ArgumentError.new("W263 selected part identity differs") unless entry["part_name"].as_s == PART_NAME
    raise ArgumentError.new("W263 selected mark format differs") unless entry["mark_extension"].as_s == ".mrk4"
    table_name = entry["table"].as_s
    raise ArgumentError.new("W263 selected table name differs") unless table_name == "w263_#{NATIVE_LABEL}"

    store_root = File.expand_path(manifest["store_root"].as_s)
    raise ArgumentError.new("W263 native store root is absent or linked") unless Dir.exists?(store_root) && !File.symlink?(store_root) && File.realpath(store_root) == store_root
    source_part = File.expand_path(entry["path"].as_s)
    unless source_part.starts_with?(File.join(store_root, "store") + "/") && Dir.exists?(source_part) && !File.symlink?(source_part) && File.realpath(source_part) == source_part
      raise ArgumentError.new("W263 selected native part path is absent, linked or outside its store")
    end
    inventory = validate_native_inventory(source_part, entry["file_inventory"].as_a)

    expanded_work_root = File.expand_path(work_root)
    raise ArgumentError.new("W263 offline work root already exists") if File.exists?(expanded_work_root) || File.symlink?(expanded_work_root)
    parent = File.dirname(expanded_work_root)
    raise ArgumentError.new("W263 offline work root parent is absent or linked") unless Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent

    Dir.mkdir(expanded_work_root, 0o700)
    root = File.join(expanded_work_root, "catalog")
    metadata = File.join(root, "metadata")
    store = File.join(root, "store")
    database_path = File.join(store, CATALOG_DATABASE_UUID[0, 3], CATALOG_DATABASE_UUID)
    table_path = File.join(store, CATALOG_TABLE_UUID[0, 3], CATALOG_TABLE_UUID)
    FileUtils.mkdir_p(metadata)
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{CATALOG_DATABASE_UUID}'\nENGINE = Atomic\n")
    declarations = SCHEMA.map { |name, type| "    `#{name}` #{type}" }.join(",\n")
    File.write(File.join(database_path, "events.sql"), "ATTACH TABLE _ UUID '#{CATALOG_TABLE_UUID}'\n(\n#{declarations}\n)\nENGINE = MergeTree\nORDER BY pk\n")
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"), 0o700)
    copied_part = File.join(table_path, PART_NAME)
    FileUtils.cp_r(source_part, copied_part)
    verify_native_inventory(copied_part, inventory)
    {root: root, part: copied_part, source_part: source_part, table: table_name, inventory: inventory}
  end

  def assert_native_inventory!(source_part : String, expected : Array(Tuple(String, Int64, String))) : Nil
    actual = verify_native_inventory(source_part, expected)
    raise CrystalClick::CorruptPartError.new("W263 native part inventory changed after offline reads") unless actual == expected
    nil
  end

  private def uint8(value : UInt8) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"),
      Bytes[value],
    )
  end

  private def validate_native_inventory(source_part : String, inventory : Array(JSON::Any)) : Array(Tuple(String, Int64, String))
    raise ArgumentError.new("W263 native file inventory is empty or too large") if inventory.empty? || inventory.size > MAX_PART_FILES
    expected = Array(Tuple(String, Int64, String)).new(inventory.size)
    names = Set(String).new
    inventory.each do |record|
      item = record.as_h
      relative = item["path"].as_s
      components = relative.split('/')
      if relative.empty? || relative.starts_with?('/') || components.any? { |component| component.empty? || component == "." || component == ".." }
        raise ArgumentError.new("W263 native inventory path is not relative and canonical")
      end
      raise ArgumentError.new("W263 native inventory repeats a path") unless names.add?(relative)
      bytes = item["bytes"].as_i64
      digest = item["sha256"].as_s
      raise ArgumentError.new("W263 native inventory size is invalid") if bytes < 0 || bytes > MAX_PART_BYTES
      raise ArgumentError.new("W263 native inventory SHA256 is malformed") unless digest.matches?(/\A[0-9a-f]{64}\z/)
      expected << {relative, bytes, digest}
    end

    verify_native_inventory(source_part, expected)
  end

  private def verify_native_inventory(source_part : String, expected : Array(Tuple(String, Int64, String))) : Array(Tuple(String, Int64, String))
    actual_names = [] of String
    collect_native_files(source_part, "", actual_names, 0_i64)
    names = expected.map(&.[0]).to_set
    raise ArgumentError.new("W263 native part file roster differs from its manifest") unless actual_names.sort == names.to_a.sort
    expected.each do |relative, bytes, digest|
      path = File.join(source_part, relative)
      raise ArgumentError.new("W263 native inventory entry is absent, linked or noncanonical") unless File.file?(path) && !File.symlink?(path) && File.realpath(path) == path
      raise ArgumentError.new("W263 native inventory byte length differs") unless File.size(path).to_i64 == bytes
      raise ArgumentError.new("W263 native inventory SHA256 differs") unless Digest::SHA256.hexdigest(File.read(path)) == digest
    end
    expected.sort_by(&.[0])
  end

  private def collect_native_files(path : String, prefix : String, files : Array(String), total_bytes : Int64) : Int64
    raise ArgumentError.new("W263 native part contains a symlink") if File.symlink?(path)
    total = total_bytes
    if Dir.exists?(path)
      Dir.children(path).sort.each do |name|
        child = prefix.empty? ? name : "#{prefix}/#{name}"
        total = collect_native_files(File.join(path, name), child, files, total)
      end
    elsif File.file?(path)
      files << prefix
      size = File.size(path).to_i64
      raise ArgumentError.new("W263 native part exceeds byte bound") if size > MAX_PART_BYTES - total
      total += size
      raise ArgumentError.new("W263 native part exceeds file bound") if files.size > MAX_PART_FILES
    else
      raise ArgumentError.new("W263 native part contains a non-regular entry")
    end
    total
  end
end
