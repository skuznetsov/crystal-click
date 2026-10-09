require "digest/sha256"
require "json"
require "../src/crystal_click"

module CheckObjectDeclaredNestedPartsW236
  extend self

  FORMAT                     = "object_declared_nested_parts_w236_v1"
  STOCK_FORMAT               = "object_declared_nested_stock_w236_v1"
  SOURCE_REFERENCE           = "/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1@0ca8150d9b1d0886edb2e3b4ab65eebb768d0357"
  RUNTIME_VERSION            = "26.10.1.1201"
  RUNTIME_BUILD              = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  RUNTIME_SHA256             = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  RUNTIME_PATH               = "/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped"
  PROCESS_TIMEOUT_SECONDS    =            90_i64
  MAX_EXECUTION_TIME_SECONDS =            30_i64
  MAX_MEMORY_USAGE_BYTES     = 1_073_741_824_i64
  STOCK_SETTINGS             = [
    "index_granularity=2", "index_granularity_bytes=10485760",
    "enable_mixed_granularity_parts=1", "min_rows_for_wide_part=0",
    "min_bytes_for_wide_part=0", "min_level_for_wide_part=0",
    "compress_marks=0", "compress_primary_key=0", "min_compress_block_size=0",
    "max_compress_block_size=4096", "ratio_of_defaults_for_sparse_serialization=1.0",
    "default_compression_codec='LZ4'", "string_serialization_version='single_stream'",
    "nullable_serialization_version='basic'", "serialization_info_version='with_types'",
    "propagate_types_serialization_versions_to_nested_types=1",
    "dynamic_serialization_version='v3'", "object_serialization_version='v3'",
    "object_shared_data_serialization_version='advanced_chunked'",
    "object_shared_data_serialization_version_for_zero_level_parts='advanced_chunked'",
    "object_shared_data_buckets_for_wide_part=2", "object_shared_data_target_chunk_rows=1",
    "map_serialization_version='basic'", "map_serialization_version_for_zero_level_parts='basic'",
    "use_compact_variant_discriminators_serialization=0", "flatten_nested=0",
  ]
  IDS    = ["direct_nested", "array_nested", "tuple_nested", "map_nested", "variant_nested"]
  TABLES = [
    "w236_json_nested_direct",
    "w236_json_nested_array",
    "w236_json_nested_tuple",
    "w236_json_nested_map",
    "w236_json_nested_variant",
  ]
  ROW_KEYS           = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  NESTED_TYPE        = "Nested(n UInt8, s String)"
  NESTED_ARRAY_TUPLE = "Array(Tuple(n UInt8, s String))"
  MAX_STOCK_BYTES    = 64 * 1024 * 1024

  private class Case
    getter id : String
    getter table : String
    getter kind : String
    getter type : CrystalClick::BinaryDataType
    getter nested_type : CrystalClick::BinaryDataType
    getter schema : CrystalClick::ObjectDocumentSchema
    getter plan : CrystalClick::ObjectDocumentPlan
    getter literals : Array(JSON::Any)
    getter declared_type : String
    getter canonical_type : String

    def initialize(
      @id : String,
      @table : String,
      @kind : String,
      @type : CrystalClick::BinaryDataType,
      @nested_type : CrystalClick::BinaryDataType,
      @literals : Array(JSON::Any),
      @declared_type : String,
      @canonical_type : String,
    )
      @schema = CrystalClick::ObjectDocumentSchema.new(
        {"q" => @type} of String => CrystalClick::BinaryDataType,
      )
      structures = CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new([] of String),
        {} of String => CrystalClick::DynamicStructure,
      )
      @plan = CrystalClick::ObjectDocumentPlan.new(structures, @schema.typed_paths)
      unless @literals.size == ROW_KEYS.size
        raise ArgumentError.new("W236 #{id} fixture must define six semantic rows")
      end
    end

    def documents : Array(CrystalClick::ObjectDocument)
      @literals.map do |literal|
        value = if literal.to_json == "null"
                  CrystalClick::BinaryBulkDefaultValue.build(@type)
                else
                  CheckObjectDeclaredNestedPartsW236.value_for(self, literal)
                end
        CrystalClick::ObjectDocument.new({"q" => value} of String => CrystalClick::BinaryValue)
      end
    end

    def granules : Array(Array(CrystalClick::ObjectDocument))
      rows = documents
      [
        [rows[0], rows[1]] of CrystalClick::ObjectDocument,
        [rows[2], rows[3]] of CrystalClick::ObjectDocument,
        [rows[4], rows[5]] of CrystalClick::ObjectDocument,
      ] of Array(CrystalClick::ObjectDocument)
    end
  end

  private def fail!(message : String) : NoReturn
    raise ArgumentError.new("W236: #{message}")
  end

  private def require!(condition : Bool, message : String) : Nil
    fail!(message) unless condition
  end

  private def object(value : JSON::Any, label : String) : Hash(String, JSON::Any)
    value.as_h
  rescue TypeCastError
    fail!("#{label} must be an object")
  end

  private def array(value : JSON::Any, label : String) : Array(JSON::Any)
    value.as_a
  rescue TypeCastError
    fail!("#{label} must be an array")
  end

  private def string(value : JSON::Any, label : String) : String
    value.as_s
  rescue TypeCastError
    fail!("#{label} must be a string")
  end

  private def integer(value : JSON::Any, label : String, maximum : Int64 = Int64::MAX) : Int64
    parsed = value.as_i64
    require!(parsed >= 0 && parsed <= maximum, "#{label} is outside the bounded integer domain")
    parsed
  rescue TypeCastError
    fail!("#{label} must be a bounded integer")
  end

  private def exact_keys!(fields : Hash(String, JSON::Any), expected : Array(String), label : String) : Nil
    require!(fields.keys.sort == expected.sort, "#{label} fields differ from the fixed schema")
  end

  private def json_string(value : String) : JSON::Any
    JSON::Any.new(value)
  end

  private def json_integer(value : Int64) : JSON::Any
    JSON::Any.new(value)
  end

  private def json_boolean(value : Bool) : JSON::Any
    JSON::Any.new(value)
  end

  private def json_object(fields : Hash(String, JSON::Any)) : JSON::Any
    JSON::Any.new(fields)
  end

  private def json_array(values : Array(JSON::Any)) : JSON::Any
    JSON::Any.new(values)
  end

  private def uint8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  private def string_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("String")
  end

  private def nested_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.nested(
      [uint8_type, string_type] of CrystalClick::BinaryDataType,
      ["n", "s"] of String,
    )
  end

  private def cases : Array(Case)
    nested = nested_type
    uint8 = uint8_type
    string = string_type
    array_nested = CrystalClick::BinaryDataType.array(nested)
    tuple_nested = CrystalClick::BinaryDataType.tuple(
      [nested, uint8] of CrystalClick::BinaryDataType,
      ["items", "tag"] of String,
    )
    map_nested = CrystalClick::BinaryDataType.map(string, nested)
    variant_nested = CrystalClick::BinaryDataType.variant(
      [nested, string] of CrystalClick::BinaryDataType,
    )
    nested_canonical = NESTED_ARRAY_TUPLE
    array_canonical = "Array(#{nested_canonical})"
    tuple_canonical = "Tuple(items #{nested_canonical}, tag UInt8)"
    map_canonical = "Map(String, #{nested_canonical})"
    variant_canonical = "Variant(#{nested_canonical}, String)"

    [
      Case.new(
        IDS[0], TABLES[0], "nested", nested, nested,
        parse_rows("[[[1,\"a\"],[2,\"long\"]],[],null,[[255,\"x\"]],[[0,\"left\"],[17,\"r\"],[42,\"longer-right\"]],null]"),
        NESTED_TYPE, nested_canonical,
      ),
      Case.new(
        IDS[1], TABLES[1], "array_nested", array_nested, nested,
        parse_rows("[[[[1,\"a\"],[2,\"long\"]],[[3,\"m\"]]],[],null,[[]],[[[0,\"left\"],[17,\"r\"]]],[[[4,\"tail\"],[8,\"x\"]],[[9,\"long\"]]]]"),
        "Array(#{NESTED_TYPE})", array_canonical,
      ),
      Case.new(
        IDS[2], TABLES[2], "tuple_nested", tuple_nested, nested,
        parse_rows("[{\"items\":[[1,\"t\"],[2,\"side\"]],\"tag\":7},{\"items\":[],\"tag\":9},null,{\"items\":[[255,\"x\"]],\"tag\":255},{\"items\":[[0,\"left\"],[17,\"r\"],[42,\"longer-right\"]],\"tag\":5},{\"items\":[],\"tag\":0}]"),
        "Tuple(items #{NESTED_TYPE}, tag UInt8)", tuple_canonical,
      ),
      Case.new(
        IDS[3], TABLES[3], "map_nested", map_nested, nested,
        parse_rows("[[[\"a\",[[1,\"a\"],[2,\"long\"]]],[\"long-key\",[[3,\"m\"]]]],[],null,[[\"x\",[]]],[[\"left\",[[0,\"left\"],[17,\"r\"],[42,\"longer-right\"]]]],[[\"tail\",[[9,\"z\"]]]]]"),
        "Map(String, #{NESTED_TYPE})", map_canonical,
      ),
      Case.new(
        IDS[4], TABLES[4], "variant_nested", variant_nested, nested,
        parse_rows("[{\"variant\":\"nested\",\"value\":[[1,\"a\"],[2,\"long\"]]},{\"variant\":\"string\",\"value\":\"v\"},null,{\"variant\":\"nested\",\"value\":[[255,\"x\"]]},{\"variant\":\"string\",\"value\":\"much-longer\"},{\"variant\":\"nested\",\"value\":[[0,\"left\"],[17,\"r\"],[42,\"longer-right\"]]}]"),
        "Variant(#{NESTED_TYPE}, String)", variant_canonical,
      ),
    ] of Case
  end

  private def parse_rows(literal : String) : Array(JSON::Any)
    JSON.parse(literal).as_a
  end

  private def u8(type : CrystalClick::BinaryDataType, value : JSON::Any) : CrystalClick::BinaryValue
    parsed = integer(value, "UInt8 literal", 255).to_u8
    CrystalClick::BinaryValue.fixed(type, Bytes[parsed])
  end

  private def nested_value(type : CrystalClick::BinaryDataType, literal : JSON::Any) : CrystalClick::BinaryValue
    tuple = type.child_at(0)
    fields = array(literal, "Nested literal").map do |record|
      pair = array(record, "Nested tuple")
      require!(pair.size == 2, "Nested tuple must have exactly n and s fields")
      CrystalClick::BinaryValue.tuple(
        tuple,
        [u8(tuple.child_at(0), pair[0]), CrystalClick::BinaryValue.string(string(pair[1], "Nested s"))] of CrystalClick::BinaryValue,
      )
    end
    CrystalClick::BinaryValue.nested(type, fields)
  end

  def value_for(fixture : Case, literal : JSON::Any) : CrystalClick::BinaryValue
    case fixture.kind
    when "nested"
      nested_value(fixture.nested_type, literal)
    when "array_nested"
      items = array(literal, "Array(Nested) literal").map { |item| nested_value(fixture.nested_type, item) }
      CrystalClick::BinaryValue.array(fixture.type, items)
    when "tuple_nested"
      fields = object(literal, "Tuple literal")
      CrystalClick::BinaryValue.tuple(
        fixture.type,
        [nested_value(fixture.nested_type, fields["items"]), u8(fixture.type.child_at(1), fields["tag"])] of CrystalClick::BinaryValue,
      )
    when "map_nested"
      entries = [] of CrystalClick::BinaryValue
      array(literal, "Map literal").each do |pair_value|
        pair = array(pair_value, "Map entry")
        require!(pair.size == 2, "Map entry must contain a String key and Nested value")
        entries << CrystalClick::BinaryValue.string(string(pair[0], "Map key"))
        entries << nested_value(fixture.nested_type, pair[1])
      end
      CrystalClick::BinaryValue.map(fixture.type, entries)
    when "variant_nested"
      fields = object(literal, "Variant literal")
      arm = string(fields["variant"], "Variant arm")
      nested_index = fixture.type.children.index(fixture.nested_type).not_nil!
      string_index = fixture.type.children.index(string_type).not_nil!
      if arm == "nested"
        CrystalClick::BinaryValue.variant(
          fixture.type, nested_index, nested_value(fixture.nested_type, fields["value"]),
        )
      elsif arm == "string"
        CrystalClick::BinaryValue.variant(
          fixture.type, string_index, CrystalClick::BinaryValue.string(string(fields["value"], "Variant String")),
        )
      else
        fail!("unlisted Variant arm #{arm.inspect}")
      end
    else
      fail!("unlisted Nested fixture kind #{fixture.kind.inspect}")
    end
  end

  private def write_u8(io : IO, value : UInt8) : Nil
    io.write_byte(value)
  end

  private def write_u64(io : IO, value : UInt64) : Nil
    8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
  end

  private def write_varuint(io : IO, value : UInt64) : Nil
    rest = value
    while rest >= 0x80_u64
      io.write_byte(((rest & 0x7f_u64) | 0x80_u64).to_u8)
      rest >>= 7
    end
    io.write_byte(rest.to_u8)
  end

  private def write_string(io : IO, value : String) : Nil
    bytes = value.to_slice
    write_varuint(io, bytes.size.to_u64)
    io.write(bytes)
  end

  private def write_nested_body(io : IO, literal : JSON::Any) : Nil
    records = array(literal, "Nested RowBinary literal")
    write_varuint(io, records.size.to_u64)
    records.each do |record_value|
      record = array(record_value, "Nested RowBinary tuple")
      require!(record.size == 2, "Nested RowBinary tuple must have exactly two fields")
      write_u8(io, integer(record[0], "Nested UInt8", 255).to_u8)
      write_string(io, string(record[1], "Nested String"))
    end
  end

  private def write_default_body(io : IO, fixture : Case) : Nil
    case fixture.kind
    when "nested", "array_nested", "map_nested"
      write_varuint(io, 0_u64)
    when "tuple_nested"
      write_varuint(io, 0_u64)
      write_u8(io, 0_u8)
    when "variant_nested"
      write_u8(io, 0xff_u8)
    else
      fail!("unlisted default RowBinary kind #{fixture.kind.inspect}")
    end
  end

  private def write_typed_body(io : IO, fixture : Case, literal : JSON::Any) : Nil
    if literal.to_json == "null"
      return write_default_body(io, fixture)
    end
    case fixture.kind
    when "nested"
      write_nested_body(io, literal)
    when "array_nested"
      values = array(literal, "Array(Nested) RowBinary literal")
      write_varuint(io, values.size.to_u64)
      values.each { |nested| write_nested_body(io, nested) }
    when "tuple_nested"
      fields = object(literal, "Tuple RowBinary literal")
      write_nested_body(io, fields["items"])
      write_u8(io, integer(fields["tag"], "Tuple UInt8", 255).to_u8)
    when "map_nested"
      entries = array(literal, "Map RowBinary literal")
      write_varuint(io, entries.size.to_u64)
      entries.each do |entry_value|
        entry = array(entry_value, "Map RowBinary entry")
        require!(entry.size == 2, "Map RowBinary entry must have two fields")
        write_string(io, string(entry[0], "Map key"))
        write_nested_body(io, entry[1])
      end
    when "variant_nested"
      fields = object(literal, "Variant RowBinary literal")
      case string(fields["variant"], "Variant arm")
      when "nested"
        write_u8(io, 0_u8)
        write_nested_body(io, fields["value"])
      when "string"
        write_u8(io, 1_u8)
        write_string(io, string(fields["value"], "Variant String"))
      else
        fail!("unlisted Variant RowBinary arm")
      end
    else
      fail!("unlisted RowBinary fixture kind #{fixture.kind.inspect}")
    end
  end

  private def bytes_for(&block : IO::Memory -> Nil) : Bytes
    io = IO::Memory.new
    yield io
    io.to_slice.dup
  end

  private def input_rowbinary(fixture : Case) : Bytes
    bytes_for do |io|
      fixture.literals.each_with_index do |literal, index|
        write_u64(io, ROW_KEYS[index])
        if literal.to_json == "null"
          write_varuint(io, 0_u64)
        else
          write_varuint(io, 1_u64)
          write_string(io, "q")
          write_typed_body(io, fixture, literal)
        end
      end
    end
  end

  private def expected_rowbinary(fixture : Case, window : String) : Bytes
    start_index, end_index = case window
                             when "full"   then {0, 6}
                             when "middle" then {2, 4}
                             when "empty"  then {0, 0}
                             else               fail!("unlisted RowBinary window #{window.inspect}")
                             end
    bytes_for do |io|
      (start_index...end_index).each do |index|
        write_u64(io, ROW_KEYS[index])
        write_typed_body(io, fixture, fixture.literals[index])
      end
    end
  end

  private def expected_schema_spellings(fixture : Case) : Array(String)
    nominal = "id\tUInt64\nj\tJSON(q #{fixture.declared_type})\n"
    canonical = "id\tUInt64\nj\tJSON(q #{fixture.canonical_type})\n"
    [nominal, canonical].uniq
  end

  private def expected_create_sql(fixture : Case, settings : Array(JSON::Any)) : String
    setting_text = settings.map { |entry| string(entry, "stock setting") }.join(", ")
    "CREATE TABLE default.#{fixture.table} (id UInt64, j JSON(q #{fixture.declared_type})) " \
    "ENGINE=MergeTree ORDER BY id SETTINGS #{setting_text}\n"
  end

  private def expected_schema_sql(table : String) : String
    "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw\n"
  end

  private def expected_check_sql(table : String) : String
    "CHECK TABLE default.#{table} FORMAT TSVRaw\n"
  end

  private def expected_insert_sql(table : String) : String
    "INSERT INTO default.#{table} SETTINGS input_format_binary_read_json_as_string=0 FORMAT RowBinary\n"
  end

  private def expected_part_sql(table : String) : String
    "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts " \
    "WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw\n"
  end

  private def expected_window_sql(table : String, window : String) : String
    predicate = case window
                when "full"   then ""
                when "middle" then " WHERE id BETWEEN 3 AND 4"
                when "empty"  then " WHERE id=0"
                else               fail!("unlisted RowBinary window #{window.inspect}")
                end
    "SELECT id, j.q FROM default.#{table}#{predicate} ORDER BY id " \
    "SETTINGS output_format_binary_write_json_as_string=0 FORMAT RowBinary\n"
  end

  private def safe_root(path : String, label : String) : String
    full = File.expand_path(path)
    require!(Dir.exists?(full) && !File.symlink?(full) && File.realpath(full) == full, "#{label} must be a canonical non-symlink directory")
    require!(full.starts_with?("/private/tmp/"), "#{label} must be below /private/tmp")
    full
  end

  private def fresh_output_root(path : String) : String
    full = safe_root(path, "output root")
    require!(Dir.children(full).empty?, "output root must be fresh and empty")
    full
  end

  private def path_under(root : String, relative : String, label : String) : String
    require!(!relative.empty? && !relative.starts_with?("/") && !relative.includes?("\\"), "#{label} must be a root-relative path")
    components = relative.split(File::SEPARATOR)
    require!(components.all? { |component| !component.empty? && component != "." && component != ".." }, "#{label} contains traversal")
    path = File.join(root, relative)
    require!(path.starts_with?(root + File::SEPARATOR), "#{label} escaped its root")
    path
  end

  private def read_plain_file(root : String, relative : String, label : String, max_bytes : Int64 = MAX_STOCK_BYTES.to_i64) : Bytes
    path = path_under(root, relative, label)
    require!(File.file?(path) && !File.symlink?(path) && File.realpath(path) == path, "#{label} is absent, non-regular, or noncanonical")
    size = File.info(path).size
    require!(size >= 0 && size <= max_bytes, "#{label} exceeds its fixed read bound")
    File.read(path).to_slice.dup
  end

  private def read_json_file(root : String, relative : String, label : String) : JSON::Any
    JSON.parse(String.new(read_plain_file(root, relative, label)))
  rescue ex : JSON::ParseException
    fail!("#{label} is not valid JSON: #{ex.message}")
  end

  private def canonical_stock_file(path : String, root : String, label : String) : String
    full = File.expand_path(path)
    require!(full.starts_with?(root + File::SEPARATOR) && File.file?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} must be a canonical file below stock root")
    full
  end

  private def canonical_stock_part(path : String, relative : String, root : String, id : String) : String
    full = File.expand_path(path)
    expected = path_under(root, relative, "stock part relative path")
    require!(full == expected && full.starts_with?(File.join(root, "stores", id) + File::SEPARATOR),
      "stock part path differs from its isolated case store")
    require!(Dir.exists?(full) && !File.symlink?(full) && File.realpath(full) == full, "stock part is absent or noncanonical")
    full
  end

  private def capture_base(root : String, prefix : String, label : String) : String
    require!(prefix.starts_with?("invocations/"), "#{label} capture must be under invocations")
    relative = "#{prefix}.stdout"
    path_under(root, relative, "#{label} capture")
  end

  private def validate_process_capture!(
    root : String,
    prefix : String,
    label : String,
    expected_sql : String,
    expected_store : String,
    expected_stdin : Bytes? = nil,
  ) : Bytes
    base = capture_base(root, prefix, label)
    stem = prefix
    stdout = read_plain_file(root, "#{stem}.stdout", "#{label} stdout")
    stderr = read_plain_file(root, "#{stem}.stderr", "#{label} stderr")
    status = read_json_file(root, "#{stem}.status.json", "#{label} status")
    require!(status["classification"].as_s == "process_success" && status["exitstatus"].as_i64 == 0 &&
             status["signaled"].as_bool == false && status["termsig"].to_json == "null" &&
             status["timed_out"].as_bool == false && status["spawn_error"].to_json == "null" &&
             status["stdout_bytes"].as_i64 == stdout.size.to_i64 && status["stderr_bytes"].as_i64 == stderr.size.to_i64,
      "#{label} process capture is not a successful stock child")
    argv_fields = object(read_json_file(root, "#{stem}.argv.json", "#{label} argv"), "#{label} argv")
    exact_keys!(argv_fields, ["label", "argv", "environment", "timeout_seconds", "stdin_bytes", "stdin_sha256"], "#{label} argv")
    argv = array(argv_fields["argv"], "#{label} argv vector").map { |entry| string(entry, "#{label} argv entry") }
    expected_argv = [
      RUNTIME_PATH, "local", "--path", expected_store, "--session_timezone=UTC", "--max_threads=1",
      "--max_insert_threads=1", "--max_execution_time=#{MAX_EXECUTION_TIME_SECONDS}",
      "--max_memory_usage=#{MAX_MEMORY_USAGE_BYTES}", "--print_pretty_type_names=0", "--flatten_nested=0",
      "--multiquery", "--query", expected_sql.chomp("\n"),
    ]
    require!(argv == expected_argv, "#{label} argv differs from the fixed runtime, store, query, or resource bounds")
    environment = object(argv_fields["environment"], "#{label} environment")
    exact_keys!(environment, ["TZ"], "#{label} environment")
    require!(string(environment["TZ"], "#{label} timezone") == "UTC" &&
             argv_fields["timeout_seconds"].as_i64 == PROCESS_TIMEOUT_SECONDS,
      "#{label} process environment or timeout differs from the fixed bounds")

    sql_bytes = read_plain_file(root, "#{stem}.sql", "#{label} SQL")
    require!(String.new(sql_bytes) == expected_sql, "#{label} SQL differs from the fixed source query")
    stdin_path = path_under(root, "#{stem}.stdin.bin", "#{label} stdin")
    if input = expected_stdin
      stdin = read_plain_file(root, "#{stem}.stdin.bin", "#{label} stdin", input.size.to_i64)
      require!(stdin == input && argv_fields["stdin_bytes"].as_i64 == input.size.to_i64 &&
               string(argv_fields["stdin_sha256"], "#{label} stdin SHA") == sha256(input),
        "#{label} input bytes differ from the independent RowBinary literal")
    else
      require!(argv_fields["stdin_bytes"].to_json == "null" && argv_fields["stdin_sha256"].to_json == "null" &&
               !File.exists?(stdin_path) && !File.symlink?(stdin_path),
        "#{label} unexpectedly records process input")
    end
    _ = base
    stdout
  end

  private def sha256(bytes : Bytes) : String
    Digest::SHA256.hexdigest(bytes)
  end

  private def plain_inventory(part : String) : Array(Hash(String, JSON::Any))
    files = [] of Hash(String, JSON::Any)
    walk_inventory(part, part, files)
    files.sort_by! { |file| file["path"].as_s }
    files
  end

  private def walk_inventory(root : String, current : String, files : Array(Hash(String, JSON::Any))) : Nil
    Dir.children(current).sort.each do |name|
      child = File.join(current, name)
      require!(!File.symlink?(child), "part inventory contains a symlink")
      if Dir.exists?(child)
        require!(File.realpath(child) == child, "part inventory directory is noncanonical")
        walk_inventory(root, child, files)
      else
        require!(File.file?(child) && File.realpath(child) == child, "part inventory contains a non-regular file")
        relative = child.byte_slice(root.bytesize + 1, child.bytesize - root.bytesize - 1)
        contents = File.read(child).to_slice
        files << {
          "path"   => json_string(relative),
          "size"   => json_integer(contents.size.to_i64),
          "sha256" => json_string(sha256(contents)),
        } of String => JSON::Any
      end
    end
  end

  private def normalize_inventory(value : JSON::Any, label : String) : Array(Hash(String, JSON::Any))
    array(value, label).map do |entry|
      fields = object(entry, label)
      exact_keys!(fields, ["path", "size", "sha256"], label)
      {
        "path"   => json_string(string(fields["path"], "#{label} path")),
        "size"   => json_integer(integer(fields["size"], "#{label} size")),
        "sha256" => json_string(string(fields["sha256"], "#{label} SHA-256")),
      } of String => JSON::Any
    end.sort_by { |entry| entry["path"].as_s }
  end

  private def verify_stock_inventory!(root : String, id : String, part : String, witness_profile : JSON::Any) : Array(Hash(String, JSON::Any))
    inventory_path = read_json_file(root, "part_inventories.json", "stock part inventories")
    parts = array(inventory_path["parts"], "stock part inventory list")
    matching = parts.select { |entry| entry["id"].as_s == id }
    require!(matching.size == 1, "stock part inventory must contain exactly one #{id} entry")
    fields = object(matching.first, "stock part inventory")
    require!(string(fields["part_path"], "stock inventory path") == part, "stock inventory absolute path differs")
    source_relative = string(witness_profile["part_path_relative"], "stock part path relative")
    require!(string(fields["part_path_relative"], "stock inventory relative path") == source_relative, "stock inventory relative path differs")
    expected = normalize_inventory(JSON::Any.new(fields["files"].as_a), "stock part file inventory")
    actual = plain_inventory(part)
    require!(expected.to_json == actual.to_json, "stock part file inventory/hash differs from the capture")
    require!(witness_profile["part_inventory_file_count"].as_i64 == actual.size.to_i64, "stock part inventory count differs")
    actual
  end

  private def profile_by_id(profiles : Array(JSON::Any), id : String) : JSON::Any
    matching = profiles.select { |profile| profile["id"].as_s == id }
    require!(matching.size == 1, "stock witnesses must contain exactly one #{id} profile")
    matching.first
  end

  private def validate_runtime!(root : String, witnesses : JSON::Any) : JSON::Any
    runtime = object(witnesses["runtime"], "stock runtime pin")
    require!(string(runtime["version"], "runtime version") == RUNTIME_VERSION &&
             string(runtime["build_hash"], "runtime build") == RUNTIME_BUILD &&
             string(runtime["sha256"], "runtime SHA") == RUNTIME_SHA256,
      "stock runtime pin differs from W236's fixed 26.10.1.1201 runtime")
    path = string(runtime["path"], "runtime path")
    require!(path == RUNTIME_PATH, "stock runtime path differs from the W235 pin")
    runtime_store = File.join(root, "stores", IDS[0])
    version_stdout = validate_process_capture!(
      root, string(runtime["version_capture"], "runtime version capture"), "runtime version",
      "SELECT version() FORMAT TSVRaw\n", runtime_store,
    )
    build_stdout = validate_process_capture!(
      root, string(runtime["build_capture"], "runtime build capture"), "runtime build",
      "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw\n",
      runtime_store,
    )
    require!(String.new(version_stdout) == "#{RUNTIME_VERSION}\n" &&
             String.new(build_stdout) == "VERSION_GITHASH=#{RUNTIME_BUILD}\n", "stock runtime query captures differ from the pin")
    witnesses["runtime"]
  end

  private def validate_stock_case!(root : String, settings : Array(JSON::Any), fixture : Case, witness_profile : JSON::Any) : Hash(String, JSON::Any)
    fields = object(witness_profile, "stock profile #{fixture.id}")
    require!(string(fields["id"], "profile id") == fixture.id && string(fields["table"], "profile table") == fixture.table,
      "stock profile id/table differs from the fixed roster")
    require!(string(fields["declared_type"], "declared type") == "JSON(q #{fixture.declared_type})", "declared JSON type differs")
    require!(array(fields["expected_schema_spellings"], "expected schema spellings").map { |v| string(v, "schema spelling") } == expected_schema_spellings(fixture),
      "stock schema alternatives differ from the exact nominal/canonical roster")
    require!(array(fields["row_keys"], "row keys").map { |v| integer(v, "row key") } == ROW_KEYS.map(&.to_i64), "stock row keys differ")
    require!(array(fields["rows_per_mark"], "rows per mark").map { |v| integer(v, "rows per mark") } == [2_i64, 2_i64, 2_i64],
      "stock parent data-row groups differ")
    require!(string(fields["part_type_expected"], "stock part type") == "Wide" && fields["part_marks_expected"].as_i64 == 4,
      "stock system.parts part shape differs from the captured W236 convention")
    require!(string(fields["status"], "stock profile status") == "persisted_and_literal_rowbinary_matched", "stock profile did not pass persistence and literal windows")
    require!(fields["failures"].as_a.empty?, "stock profile records failures")

    row_values = array(fields["row_values"], "stock semantic row values")
    require!(row_values.size == ROW_KEYS.size, "stock semantic row count differs")
    fixture.literals.each_with_index do |literal, index|
      row = object(row_values[index], "stock row #{index + 1}")
      exact_keys!(row, ["id", "q_present", "value"], "stock row #{index + 1}")
      require!(row["id"].as_i64 == ROW_KEYS[index].to_i64, "stock row id differs")
      present = literal.to_json != "null"
      require!(row["q_present"].as_bool == present && row["value"].to_json == literal.to_json,
        "stock row #{index + 1} presence/value differs from independent literal")
    end

    expected_schema = expected_schema_spellings(fixture)
    schema_stdout = string(fields["schema_stdout"], "captured schema stdout")
    require!(expected_schema.includes?(schema_stdout), "captured system.columns bytes are not one exact allowed spelling")
    schema_capture = string(object(fields["steps"], "stock steps")["schema"]["capture_prefix"], "schema capture prefix")
    store = File.join(root, "stores", fixture.id)
    schema_bytes = validate_process_capture!(
      root, schema_capture, "#{fixture.id} schema", expected_schema_sql(fixture.table), store,
    )
    require!(schema_bytes == schema_stdout.to_slice, "raw schema stdout differs from witness text")
    spelling_class = string(fields["nested_type_spelling_class"], "Nested spelling class")
    if schema_stdout == expected_schema.first
      require!(spelling_class == "nominal_custom_nested_name_preserved", "nominal Nested spelling was mislabeled")
    else
      require!(spelling_class == "canonicalized_to_array_tuple_spelling", "canonical Nested spelling was mislabeled")
    end

    steps = object(fields["steps"], "stock process steps")
    input_relative = string(fields["input_literal"], "stock RowBinary INSERT literal")
    require!(input_relative == "literal_rowbinary/#{fixture.id}-input.rowbin", "stock RowBinary INSERT literal path differs")
    input_literal = read_plain_file(root, input_relative, "stock RowBinary INSERT literal", 16_i64 * 1024 * 1024)
    expected_input = input_rowbinary(fixture)
    require!(input_literal == expected_input, "stock RowBinary INSERT literal differs from the independent input packer")

    create_capture = string(steps["create"]["capture_prefix"], "create capture prefix")
    _ = validate_process_capture!(root, create_capture, "#{fixture.id} create", expected_create_sql(fixture, settings), store)
    insert_capture = string(steps["insert"]["capture_prefix"], "insert capture prefix")
    _ = validate_process_capture!(
      root, insert_capture, "#{fixture.id} insert", expected_insert_sql(fixture.table), store, expected_input,
    )
    check_capture = string(steps["check"]["capture_prefix"], "check capture prefix")
    check_stdout = string(fields["check_stdout"], "CHECK TABLE stdout")
    check_bytes = validate_process_capture!(root, check_capture, "#{fixture.id} CHECK", expected_check_sql(fixture.table), store)
    require!(check_bytes == "all_1_1_0\t1\t\n".to_slice && check_stdout == "all_1_1_0\t1\t\n" &&
             check_bytes == check_stdout.to_slice && fields["check_matches_expected"].as_bool,
      "stock CHECK TABLE output is not the captured successful expected result")

    part_capture = string(fields["part_capture"], "part capture")
    require!(string(steps["part"]["capture_prefix"], "system.parts step capture") == part_capture,
      "stock system.parts capture prefix differs between witness fields")
    part_bytes = validate_process_capture!(
      root, part_capture, "#{fixture.id} system.parts", expected_part_sql(fixture.table), store,
    )
    require!(String.new(part_bytes) == string(fields["part_stdout"], "part stdout"), "raw system.parts output differs from witness text")
    lines = String.new(part_bytes).lines.map(&.chomp).reject(&.empty?)
    require!(lines.size == 1, "stock system.parts must return exactly one active part")
    columns = lines.first.split('\t', remove_empty: false)
    require!(columns.size == 5 && columns[0] == "all_1_1_0" && columns[1] == "6" &&
             columns[2].to_i64 == fields["part_marks_expected"].as_i64 && columns[3] == "Wide",
      "captured system.parts row/marks/type differs from its exact witness")

    part_relative = string(fields["part_path_relative"], "stock part relative path")
    part = canonical_stock_part(string(fields["part_path"], "stock part absolute path"), part_relative, root, fixture.id)
    require!(columns[4] == part || columns[4] == part + File::SEPARATOR,
      "captured system.parts absolute path differs from witness part path")
    source_part_inventory = verify_stock_inventory!(root, fixture.id, part, witness_profile)

    # Consume the stock-produced part through the library, independently of
    # the stock query RowBinary comparison below. Preserve whichever exact
    # Nested spelling system.columns observed; the checker fixture remains
    # nominal Nested and value comparison handles its source-confirmed
    # Array(Tuple(...)) representation equivalence recursively.
    stock_schema_type = if schema_stdout == expected_schema.first
                          fixture.declared_type
                        else
                          fixture.canonical_type
                        end
    stock_schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(q #{stock_schema_type})")
    stock_reader = CrystalClick::ObjectColumnReader.open(part, "j", stock_schema)
    require!(stock_reader.row_count == 6_u64 && stock_reader.mark_row_counts == [2_u64, 2_u64, 2_u64],
      "#{fixture.id} stock Object reader row/mark grid differs")

    stock_library_windows = {} of String => JSON::Any
    {"full" => {0, 3, 0}, "middle" => {1, 1, 2}, "empty" => {0, 0, 0}, "eof" => {3, 0, 6}}.each do |window, selection|
      first_mark, mark_count, first_row = selection
      actual = CrystalClick::ObjectDocumentFileReader.read(
        part, "j", stock_schema.typed_paths,
        first_mark: first_mark, mark_count: mark_count,
        profile: stock_reader.ordinary_profile, hashed: true,
      )
      if mark_count == 0
        require!(actual.empty?, "#{fixture.id} stock #{window} Object reader window is not empty")
      else
        expected_rows = window == "full" ? 6 : 2
        compare_stock_documents!(actual, fixture, first_row, expected_rows, "#{fixture.id} stock #{window} ObjectDocumentFileReader")
      end
      stock_library_windows[window] = json_object({
        "first_mark"                   => json_integer(first_mark.to_i64),
        "mark_count"                   => json_integer(mark_count.to_i64),
        "first_parent_row"             => json_integer(first_row.to_i64),
        "returned_marks"               => json_integer(actual.size.to_i64),
        "returned_rows"                => json_integer(actual.sum(&.size).to_i64),
        "all_rows_have_materialized_q" => json_boolean(actual.flatten.all?(&.has_path?("q"))),
      } of String => JSON::Any)
    end

    windows = object(fields["rowbinary_windows"], "stock RowBinary windows")
    stock_windows = {} of String => JSON::Any
    {"full", "middle", "empty"}.each do |window|
      stock_window = object(windows[window], "stock #{window} RowBinary window")
      expected = expected_rowbinary(fixture, window)
      stock_literal = string(stock_window["expected_literal"], "stock expected literal path")
      literal_bytes = read_plain_file(root, stock_literal, "stock #{window} expected RowBinary", 16_i64 * 1024 * 1024)
      require!(literal_bytes == expected && stock_window["expected_bytes"].as_i64 == expected.size.to_i64 &&
               string(stock_window["expected_sha256"], "stock expected SHA") == sha256(expected),
        "stock #{window} expected literal differs from the independent RowBinary packer")
      capture_prefix = string(stock_window["capture_prefix"], "stock #{window} stdout capture")
      stdout = validate_process_capture!(
        root, capture_prefix, "#{fixture.id} #{window} RowBinary", expected_window_sql(fixture.table, window), store,
      )
      require!(stdout == expected && stock_window["matches_independent_literal"].as_bool,
        "stock #{window} query output differs from independent RowBinary bytes")
      stock_windows[window] = json_object({
        "capture_prefix"               => json_string(capture_prefix),
        "expected_literal"             => json_string(stock_literal),
        "expected_bytes"               => json_integer(expected.size.to_i64),
        "expected_sha256"              => json_string(sha256(expected)),
        "observed_matches_independent" => json_boolean(true),
      } of String => JSON::Any)
    end

    {
      "part_path"          => json_string(part),
      "part_path_relative" => json_string(part_relative),
      "part_capture"       => json_string(part_capture),
      "check_capture"      => json_string(check_capture),
      "check_stdout"       => json_string(check_stdout),
      "schema_capture"     => json_string(schema_capture),
      "schema_stdout"      => json_string(schema_stdout),
      "settings"           => json_array(settings.map { |entry| json_string(string(entry, "stock setting")) }),
      "rowbinary_windows"  => json_object(stock_windows),
      "part_inventory"     => json_array(source_part_inventory.map { |file| json_object(file) }),
      "library_read"       => json_object({
        "column"                          => json_string("j"),
        "schema_type_from_system_columns" => json_string(stock_schema_type),
        "ordinary_profile"                => json_string(stock_reader.ordinary_profile.with_size_stream? ? "with_size_stream" : "single_stream"),
        "row_count"                       => json_integer(stock_reader.row_count.to_i64),
        "mark_row_counts"                 => json_array(stock_reader.mark_row_counts.map { |count| json_integer(count.to_i64) }),
        "source_q_presence"               => json_array(fixture.literals.map { |literal| json_boolean(literal.to_json != "null") }),
        "typed_q_default_materialized"    => json_boolean(true),
        "windows"                         => json_object(stock_library_windows),
      } of String => JSON::Any),
    } of String => JSON::Any
  end

  private def tuple_tag?(tag : UInt8) : Bool
    tag == CrystalClick::BinaryDataType::TAG_NAMED_TUPLE || tag == CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE
  end

  private def sequence_tag?(tag : UInt8) : Bool
    tag == CrystalClick::BinaryDataType::TAG_ARRAY || tag == CrystalClick::BinaryDataType::TAG_NESTED
  end

  # The stock witness permits one observed spelling equivalence: Nested may
  # be represented in system.columns and decoded as Array(Tuple(...)). The
  # comparison crosses only that sequence-tag boundary, recursively.
  private def same_semantic_value?(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue) : Bool
    actual_tag = actual.type.tag
    expected_tag = expected.type.tag
    if sequence_tag?(actual_tag) && sequence_tag?(expected_tag)
      return false unless actual.element_count == expected.element_count
      return (0...actual.element_count).all? do |index|
        same_semantic_value?(actual.element_at(index), expected.element_at(index))
      end
    end
    if tuple_tag?(actual_tag) && tuple_tag?(expected_tag)
      return false unless actual.child_count == expected.child_count
      return (0...actual.child_count).all? do |index|
        same_semantic_value?(actual.child_at(index), expected.child_at(index))
      end
    end
    return false unless actual_tag == expected_tag

    case actual_tag
    when CrystalClick::BinaryDataType::TAG_STRING
      actual.as_string == expected.as_string
    when CrystalClick::BinaryDataType::TAG_UINT8
      actual.byte_at(0) == expected.byte_at(0)
    when CrystalClick::BinaryDataType::TAG_MAP
      return false unless actual.child_count == expected.child_count
      (0...actual.child_count).all? do |index|
        same_semantic_value?(actual.child_at(index), expected.child_at(index))
      end
    when CrystalClick::BinaryDataType::TAG_VARIANT
      actual_index = actual.variant_index?
      expected_index = expected.variant_index?
      return actual_index.nil? && expected_index.nil? if actual_index.nil? || expected_index.nil?
      actual_index == expected_index && same_semantic_value?(actual.variant_child?.not_nil!, expected.variant_child?.not_nil!)
    else
      CrystalClick::BinaryValueCodec.encode(actual) == CrystalClick::BinaryValueCodec.encode(expected)
    end
  end

  private def compare_stock_documents!(
    actual : Array(Array(CrystalClick::ObjectDocument)), fixture : Case, first_row : Int, row_count : Int, label : String,
  ) : Nil
    expected_rows = fixture.documents
    require!(first_row >= 0 && row_count > 0 && first_row + row_count <= expected_rows.size &&
             actual.size == row_count // 2 && actual.all?(&.size.==(2)),
      "#{label} row selection or parent mark shape differs")
    actual.flatten.each_with_index do |document, index|
      row_index = first_row + index
      expected = expected_rows[row_index].value_for("q")
      require!(document.has_path?("q") && same_semantic_value?(document.value_for("q"), expected),
        "#{label} row #{row_index + 1} differs from the independent typed value/default")
    end
  end

  private def compare_documents!(actual : Array(Array(CrystalClick::ObjectDocument)), fixture : Case, label : String) : Nil
    rows = fixture.documents
    require!(actual.size == 3 && actual.all?(&.size.==(2)), "#{label} mark grid differs")
    actual.each_with_index do |mark, mark_index|
      mark.each_with_index do |document, row_index|
        expected = rows[mark_index * 2 + row_index].value_for("q")
        value = document.value_for("q")
        require!(document.has_path?("q"), "#{label} row #{mark_index * 2 + row_index + 1} lost explicit typed q value")
        require!(same_semantic_value?(value, expected),
          "#{label} row #{mark_index * 2 + row_index + 1} differs from the independent semantic literal")
      end
    end
  end

  private def validate_library_part!(part : String, fixture : Case) : Hash(String, JSON::Any)
    profile = CrystalClick::BinaryBulkProfile.with_size_stream
    reader = CrystalClick::ObjectColumnReader.open(part, "j", fixture.schema)
    require!(reader.row_count == 6_u64 && reader.mark_row_counts == [2_u64, 2_u64, 2_u64],
      "#{fixture.id} generated library part row/mark grid differs")
    require!(reader.ordinary_profile == profile, "#{fixture.id} generated library String profile differs")
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new("j", fixture.plan, profile)
    require!(reader.physical_stream_names == physical.stream_names, "#{fixture.id} generated physical stream roster differs")

    full = CrystalClick::ObjectDocumentFileReader.read(
      part, "j", fixture.schema.typed_paths,
      first_mark: 0, mark_count: 3, profile: profile, hashed: true,
    )
    compare_documents!(full, fixture, "#{fixture.id} full read")
    middle = CrystalClick::ObjectDocumentFileReader.read(
      part, "j", fixture.schema.typed_paths,
      first_mark: 1, mark_count: 1, profile: profile, hashed: true,
    )
    require!(middle.size == 1 && middle[0].size == 2, "#{fixture.id} middle window shape differs")
    middle_values = middle[0].map { |document| document.value_for("q") }
    expected_values = fixture.documents[2, 2].map { |document| document.value_for("q") }
    middle_values.each_with_index do |value, index|
      require!(same_semantic_value?(value, expected_values[index]),
        "#{fixture.id} middle window row #{index} differs")
    end
    zero = CrystalClick::ObjectDocumentFileReader.read(
      part, "j", fixture.schema.typed_paths,
      first_mark: 0, mark_count: 0, profile: profile, hashed: true,
    )
    eof = CrystalClick::ObjectDocumentFileReader.read(
      part, "j", fixture.schema.typed_paths,
      first_mark: 3, mark_count: 0, profile: profile, hashed: true,
    )
    require!(zero.empty? && eof.empty?, "#{fixture.id} zero/EOF windows are not empty")

    column_full = reader.read_marks(0, 3)
    compare_documents!(column_full, fixture, "#{fixture.id} ObjectColumnReader full read")
    column_middle = reader.read_marks(1, 1)
    require!(column_middle.size == 1 && column_middle[0].size == 2, "#{fixture.id} ObjectColumnReader middle window differs")
    require!(reader.read_marks(0, 0).empty? && reader.read_marks(3, 0).empty?, "#{fixture.id} ObjectColumnReader zero/EOF windows differ")

    {
      "row_count"             => json_integer(reader.row_count.to_i64),
      "mark_row_counts"       => json_array(reader.mark_row_counts.map { |rows| json_integer(rows.to_i64) }),
      "ordinary_profile"      => json_string("with_size_stream"),
      "physical_stream_names" => json_array(reader.physical_stream_names.sort.map { |name| json_string(name) }),
      "windows"               => json_array(["full", "middle", "zero", "eof"].map { |window| json_string(window) }),
    } of String => JSON::Any
  end

  private def write_part!(part : String, fixture : Case) : Nil
    written = CrystalClick::WidePartWriter.write_uint64_object_pair(
      part,
      "id",
      Slice.new(ROW_KEYS.to_unsafe, ROW_KEYS.size),
      "j",
      fixture.schema,
      fixture.plan,
      fixture.granules,
      rows_per_mark: 2,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      frame_bytes: 64,
    )
    require!(written == part, "#{fixture.id} WidePartWriter returned a different part path")
  end

  private def write_new(path : String, contents : Bytes) : Nil
    require!(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite #{path}")
    File.write(path, contents)
  end

  private def write_new(path : String, contents : String) : Nil
    write_new(path, contents.to_slice)
  end

  private def generated_case!(root : String, fixture : Case, stock : Hash(String, JSON::Any)) : JSON::Any
    part_relative = "parts/#{fixture.id}"
    part = path_under(root, part_relative, "generated part destination")
    require!(!File.exists?(part) && !File.symlink?(part), "generated part destination already exists")
    write_part!(part, fixture)
    library_read = validate_library_part!(part, fixture)
    inventory = plain_inventory(part)
    require!(!inventory.empty?, "generated library part has no physical files")

    literal_relative = "literal_rowbinary/#{fixture.id}-input.rowbin"
    input = input_rowbinary(fixture)
    write_new(path_under(root, literal_relative, "generated input literal"), input)
    windows = {} of String => JSON::Any
    expected = {} of String => JSON::Any
    {"full", "middle", "empty"}.each do |window|
      bytes = expected_rowbinary(fixture, window)
      relative = "literal_rowbinary/#{fixture.id}-#{window}-expected.rowbin"
      write_new(path_under(root, relative, "generated expected literal"), bytes)
      windows[window] = json_object({
        "file"   => json_string(relative),
        "bytes"  => json_integer(bytes.size.to_i64),
        "sha256" => json_string(sha256(bytes)),
      } of String => JSON::Any)
      stock_window = stock["rowbinary_windows"][window]
      require!(stock_window["observed_matches_independent"].as_bool &&
               stock_window["expected_bytes"].as_i64 == bytes.size.to_i64 &&
               stock_window["expected_sha256"].as_s == sha256(bytes),
        "#{fixture.id} stock #{window} evidence differs from generated independent output bytes")
      expected[window] = windows[window]
    end

    nominal_schema = expected_schema_spellings(fixture).first
    canonical_schema = expected_schema_spellings(fixture).last
    observed_schema = stock["schema_stdout"].as_s
    stock_inventory = stock["part_inventory"]
    part_shape = json_object({
      "rows"                           => json_integer(6_i64),
      "library_mark_row_counts"        => json_array([2_i64, 2_i64, 2_i64].map { |count| json_integer(count) }),
      "library_data_mark_count"        => json_integer(3_i64),
      "stock_system_parts_marks_count" => json_integer(4_i64),
      "part_type"                      => json_string("Wide"),
    } of String => JSON::Any)

    json_object({
      "id"                         => json_string(fixture.id),
      "table"                      => json_string(fixture.table),
      "declared_type"              => json_string("JSON(q #{fixture.declared_type})"),
      "ddl"                        => json_string("CREATE TABLE default.#{fixture.table} (id UInt64, j JSON(q #{fixture.declared_type})) ENGINE=MergeTree ORDER BY id SETTINGS #{settings_text(stock["settings"])}"),
      "schema_stdout"              => json_string(observed_schema),
      "nominal_schema_stdout"      => json_string(nominal_schema),
      "canonical_schema_stdout"    => json_string(canonical_schema),
      "nested_type_spelling_class" => json_string(if observed_schema == nominal_schema
        "nominal_custom_nested_name_preserved"
      else
        "canonicalized_to_array_tuple_spelling"
      end),
      "generated_part_path"          => json_string(part),
      "generated_part_path_relative" => json_string(part_relative),
      "part_shape"                   => part_shape,
      "row_values"                   => json_array(fixture.literals.map_with_index do |literal, index|
        json_object({
          "id"        => json_integer(ROW_KEYS[index].to_i64),
          "q_present" => json_boolean(literal.to_json != "null"),
          "value"     => literal,
        } of String => JSON::Any)
      end),
      "input_rowbinary" => json_object({
        "file"   => json_string(literal_relative),
        "bytes"  => json_integer(input.size.to_i64),
        "sha256" => json_string(sha256(input)),
      } of String => JSON::Any),
      "expected_rowbinary"   => json_object(expected),
      "stock"                => json_object(stock),
      "stock_part_inventory" => json_array(stock_inventory.as_a),
      "part_inventory"       => json_array(inventory.map { |file| json_object(file) }),
      "library_read"         => json_object(library_read),
    } of String => JSON::Any)
  end

  private def settings_text(value : JSON::Any) : String
    array(value, "stock settings").map { |entry| string(entry, "stock setting") }.join(", ")
  end

  def run(args : Array(String)) : Nil
    unless args.size == 4 && args[0] == "--stock-root" && args[2] == "--output-root"
      fail!("usage: check_object_declared_nested_parts_w236.cr --stock-root CAPTURE_ROOT --output-root FRESH_ROOT")
    end
    stock_root = safe_root(args[1], "stock root")
    output_root = fresh_output_root(args[3])
    require!(stock_root != output_root && !stock_root.starts_with?(output_root + File::SEPARATOR) &&
             !output_root.starts_with?(stock_root + File::SEPARATOR), "stock and generated roots must be disjoint")

    witness_bytes = read_plain_file(stock_root, "witnesses.json", "stock witness")
    require!(witness_bytes.size <= MAX_STOCK_BYTES, "stock witness exceeds the fixed bound")
    witnesses = JSON.parse(String.new(witness_bytes))
    require!(string(witnesses["format"], "stock witness format") == STOCK_FORMAT, "stock witness format differs")
    require!(string(witnesses["source_reference"], "stock source reference") == SOURCE_REFERENCE, "stock source pin differs")
    require!(witnesses["fatal_error"].to_json == "null", "stock probe records a fatal error")
    require!(integer(witnesses["process_count"], "stock process count") == 50_i64 &&
             integer(witnesses["process_cap"], "stock process cap") == 64_i64 &&
             integer(witnesses["process_timeout_seconds"], "stock timeout bound") == PROCESS_TIMEOUT_SECONDS &&
             integer(witnesses["max_execution_time_seconds"], "stock execution bound") == MAX_EXECUTION_TIME_SECONDS &&
             integer(witnesses["max_memory_usage_bytes"], "stock memory bound") == MAX_MEMORY_USAGE_BYTES,
      "stock witness process count or resource bounds differ from the fixed W236 contract")
    runtime = validate_runtime!(stock_root, witnesses)

    stock_profiles = array(witnesses["profiles"], "stock profile roster")
    expected_ids = IDS + ["ordinary_json_control"]
    require!(stock_profiles.map { |profile| string(profile["id"], "profile id") } == expected_ids,
      "stock witness profile order differs from the bounded W236 matrix")
    settings = array(witnesses["settings"], "stock MergeTree settings")
    require!(settings.map { |entry| string(entry, "stock setting") } == STOCK_SETTINGS,
      "stock MergeTree settings differ from the fixed W234/W235/W236 storage profile")
    fixture_cases = cases

    parts_root = File.join(output_root, "parts")
    literals_root = File.join(output_root, "literal_rowbinary")
    Dir.mkdir(parts_root, 0o700)
    Dir.mkdir(literals_root, 0o700)

    records = fixture_cases.map do |fixture|
      witness_profile = profile_by_id(stock_profiles, fixture.id)
      stock = validate_stock_case!(stock_root, settings, fixture, witness_profile)
      generated_case!(output_root, fixture, stock)
    end
    manifest = json_object({
      "format"           => json_string(FORMAT),
      "source_reference" => json_string(SOURCE_REFERENCE),
      "runtime"          => runtime,
      "stock_root"       => json_string(stock_root),
      "generated_root"   => json_string(output_root),
      "profiles"         => json_array(records),
      "limitations"      => json_array([
        json_string("Stock system.columns spelling is retained verbatim; canonical Array(Tuple(...)) is not relabeled as nominal Nested."),
        json_string("Each generated library part has three parent data groups of two rows. Stock system.parts marks_count is reported independently and is not equated to those groups."),
        json_string("RowBinary literals are independently packed from fixed semantic values and cross-checked against stock captures; they do not authenticate arbitrary payload bytes."),
        json_string("Part SHA-256 values bind inventoried file bytes only; they are not signatures or payload authentication."),
        json_string("This bounded checker covers the five Nested-bearing declared paths only; it does not admit production types or claim general recursive Nested support."),
      ]),
    } of String => JSON::Any)
    manifest_path = File.join(output_root, "object_declared_nested_parts_w236.json")
    write_new(manifest_path, manifest.to_json + "\n")
    puts JSON::Any.new({
      "status"   => json_string("all_five_nested_library_parts_generated_and_stock_literals_matched"),
      "manifest" => json_string(manifest_path),
      "profiles" => json_array(records.map { |record| json_string(record["id"].as_s) }),
    } of String => JSON::Any).to_json
  end
end

CheckObjectDeclaredNestedPartsW236.run(ARGV)
