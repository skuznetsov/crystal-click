require "file_utils"

module WideRaggedSelectedMetadataW261Fixture
  FORMAT     = "wide_ragged_selected_metadata_w261_fixture_v1"
  PART_NAME  = "all_1_1_0"
  ROW_COUNT  = 8_u64
  KEY_VALUES = [8101_u64, 8102_u64, 8103_u64, 8104_u64, 8105_u64, 8106_u64, 8107_u64, 8108_u64]

  SCHEMA = [
    {"pk", "UInt64"},
    {"u", "UInt64"},
    {"side", "String"},
    {"seq", "Array(Tuple(id UInt64, details Tuple(note Nullable(String), score UInt32)))"},
    {"mapped", "Map(String, Tuple(meta Tuple(note Nullable(String), id UInt64), score Nullable(Float64)))"},
    {"simple", "Map(UInt64, Nullable(UInt64))"},
    {"lookup", "Map(String, Array(Nullable(UInt64)))"},
    {"tup", "Tuple(n UInt64, s String)"},
    {"lc", "LowCardinality(String)"},
    {"v", "Variant(String, UInt64)"},
  ] of Tuple(String, String)

  SELECTED_COLUMNS         = ["u", "side", "seq", "mapped", "simple", "lookup", "tup", "lc", "v"] of String
  MARK_ROW_COUNTS          = [2_u64, 2_u64, 2_u64, 2_u64]
  MARK_ROW_COUNTS_WITH_EOF = [2_u64, 2_u64, 2_u64, 2_u64, 0_u64]
  ARRAY_COUNTS             = [0_i32, 0_i32, 2_i32, 0_i32, 0_i32, 0_i32, 1_i32, 2_i32]
  MAP_TUPLE_COUNTS         = [0_i32, 0_i32, 3_i32, 0_i32, 0_i32, 0_i32, 1_i32, 2_i32]

  # Each budget is the exact materializer charge for this literal fixture:
  # String bytes include embedded NUL and UTF-8 payload bytes; Tuple cells count
  # the flattened leaf fields charged for each materialized Tuple element.
  VALUE_BUDGETS = {
    "u"      => {string_bytes: 0_u64, tuple_cells: 0_u64},
    "side"   => {string_bytes: 64_u64, tuple_cells: 0_u64},
    "seq"    => {string_bytes: 17_u64, tuple_cells: 15_u64},
    "mapped" => {string_bytes: 30_u64, tuple_cells: 18_u64},
    "simple" => {string_bytes: 0_u64, tuple_cells: 0_u64},
    "lookup" => {string_bytes: 17_u64, tuple_cells: 0_u64},
    "tup"    => {string_bytes: 64_u64, tuple_cells: 16_u64},
    "lc"     => {string_bytes: 24_u64, tuple_cells: 0_u64},
    "v"      => {string_bytes: 19_u64, tuple_cells: 0_u64},
  }

  CATALOG_DATABASE_UUID = "26100000-0000-4000-8000-000000000001"
  CATALOG_TABLE_UUID    = "26100000-0000-4000-8000-000000000002"

  def self.expected_signatures : Hash(String, Array(String))
    {
      "u" => [
        "uint64:9101", "uint64:9102", "uint64:9103", "uint64:9104",
        "uint64:9105", "uint64:9106", "uint64:9107", "uint64:9108",
      ],
      "side" => [
        "string:736964652d30", "string:736964652d31", "string:6d61726b2d31006d6964",
        "string:cf802d736e6f772de99baa", "string:736964652d34", "string:6e756c00616e642de5b0be",
        "string:736964652d36", "string:7461696c2de29c93",
      ],
      "seq" => [
        "array[]", "array[]",
        "array[tuple[id=uint64:1201,details=tuple[note=string:610062,score=uint32:21]],tuple[id=uint64:1202,details=tuple[note=null,score=uint32:22]]]",
        "array[]", "array[]", "array[]",
        "array[tuple[id=uint64:1601,details=tuple[note=string:cf80,score=uint32:61]]]",
        "array[tuple[id=uint64:1701,details=tuple[note=string:7461696c2de99baa,score=uint32:71]],tuple[id=uint64:1702,details=tuple[note=string:6c617374,score=uint32:72]]]",
      ],
      "mapped" => [
        "map[]", "map[]",
        "map[647570:tuple[meta=tuple[note=null,id=uint64:2201],score=float64:1.5],647570:tuple[meta=tuple[note=string:6d00,id=uint64:2202],score=null],e99baa:tuple[meta=tuple[note=string:636166c3a9,id=uint64:2203],score=float64:-2.25]]",
        "map[]", "map[]", "map[]",
        "map[7461696c:tuple[meta=tuple[note=string:e5b0be,id=uint64:2601],score=float64:0.5]]",
        "map[656e64:tuple[meta=tuple[note=string:21,id=uint64:2701],score=null],656e64:tuple[meta=tuple[note=null,id=uint64:2702],score=float64:8.0]]",
      ],
      "simple" => [
        "map[uint64:1:null]", "map[]", "map[]",
        "map[uint64:3:uint64:3003,uint64:3:uint64:3004]", "map[]",
        "map[uint64:5:uint64:5005]", "map[]", "map[uint64:7:null]",
      ],
      "lookup" => [
        "map[]", "map[6f6e65:[null,uint64:9202]]", "map[]",
        "map[656d707479:[],647570:[null,uint64:9401]]", "map[]", "map[]",
        "map[cf80:[uint64:9606,null]]", "map[7461696c:[uint64:9707]]",
      ],
      "tup" => [
        "tuple[n=uint64:3101,s=string:7475706c652d30]", "tuple[n=uint64:3102,s=string:7475706c652d31]",
        "tuple[n=uint64:3103,s=string:7475706c652d3200cebb]", "tuple[n=uint64:3104,s=string:e99baa2d7475706c652d33]",
        "tuple[n=uint64:3105,s=string:7475706c652d34]", "tuple[n=uint64:3106,s=string:6e756c0066697665]",
        "tuple[n=uint64:3107,s=string:7475706c652d36]", "tuple[n=uint64:3108,s=string:7461696c2dceb1]",
      ],
      "lc" => [
        "string:647570", "string:726564", "string:647570", "string:",
        "string:626c7565", "string:647570", "string:626c7565", "string:7461696c",
      ],
      "v" => [
        "variant<String>(string:76617269616e742d30)", "variant<UInt64>(uint64:4202)", "variant<NULL>(null)",
        "variant<String>(string:76007468726565)", "variant<UInt64>(uint64:4205)",
        "variant<String>(string:e5b0be)", "variant<UInt64>(uint64:4207)", "variant<NULL>(null)",
      ],
    }
  end

  def self.schema_hash : Hash(String, String)
    SCHEMA.to_h
  end

  # Preserve an observed stock part as a copied byte fixture. This deliberately
  # accepts no symlinks and never regenerates files through a local writer.
  def self.copy_part_bytes(source : String, destination : String) : Nil
    expanded_source = File.expand_path(source)
    raise ArgumentError.new("W261 stock part source is absent or symlinked") unless Dir.exists?(expanded_source) && !File.symlink?(expanded_source) && File.realpath(expanded_source) == expanded_source
    expanded_destination = File.expand_path(destination)
    raise ArgumentError.new("W261 copied fixture destination already exists") if File.exists?(expanded_destination) || File.symlink?(expanded_destination)
    parent = File.dirname(expanded_destination)
    raise ArgumentError.new("W261 copied fixture parent is absent or symlinked") unless Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent

    counts = [0_i64, 0_i64]
    inspect_part_tree(expanded_source, counts)
    raise ArgumentError.new("W261 stock fixture is empty") if counts[0] == 0
    FileUtils.cp_r(expanded_source, expanded_destination)
    nil
  end

  # Install a copied real stock part into the smallest supported on-disk
  # catalog shape. The caller supplies a fresh work-root child; this helper
  # never invokes the local part writer or mutates the stock source.
  def self.prepare_offline_catalog(stock_part : String, work_root : String) : {root: String, part: String}
    expanded_work_root = File.expand_path(work_root)
    raise ArgumentError.new("W261 offline work root already exists") if File.exists?(expanded_work_root) || File.symlink?(expanded_work_root)
    parent = File.dirname(expanded_work_root)
    raise ArgumentError.new("W261 offline work root parent is absent or symlinked") unless Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent

    Dir.mkdir(expanded_work_root, 0o700)
    root = File.join(expanded_work_root, "catalog")
    metadata = File.join(root, "metadata")
    store = File.join(root, "store")
    database_path = File.join(store, CATALOG_DATABASE_UUID[0, 3], CATALOG_DATABASE_UUID)
    table_path = File.join(store, CATALOG_TABLE_UUID[0, 3], CATALOG_TABLE_UUID)
    FileUtils.mkdir_p(metadata)
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)

    File.write(
      File.join(metadata, "lab.sql"),
      "ATTACH DATABASE _ UUID '#{CATALOG_DATABASE_UUID}'\nENGINE = Atomic\n"
    )
    declarations = SCHEMA.map { |name, type| "    `#{name}` #{type}" }.join(",\n")
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{CATALOG_TABLE_UUID}'\n(\n#{declarations}\n)\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"), 0o700)
    copied_part = File.join(table_path, PART_NAME)
    copy_part_bytes(stock_part, copied_part)
    {root: root, part: copied_part}
  end

  private def self.inspect_part_tree(path : String, counts : Array(Int64)) : Nil
    raise ArgumentError.new("W261 stock fixture contains a symlink") if File.symlink?(path)
    if Dir.exists?(path)
      Dir.children(path).each do |name|
        inspect_part_tree(File.join(path, name), counts)
      end
    elsif File.file?(path)
      counts[0] += 1
      size = File.size(path).to_i64
      raise ArgumentError.new("W261 stock fixture exceeds byte bound") if size > 64_i64 * 1024 * 1024 - counts[1]
      counts[1] += size
      raise ArgumentError.new("W261 stock fixture exceeds file bound") if counts[0] > 4096
    else
      raise ArgumentError.new("W261 stock fixture contains a non-regular entry")
    end
    nil
  end
end
