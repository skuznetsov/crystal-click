require "../src/crystal_click"
require "json"
require "file_utils"

module CheckAggregateBitwiseW255
  extend self

  FORMAT        = "aggregate_bitwise_w255_helper_v1"
  KEY_COLUMN    = "id"
  CHILD_COLUMN  = "states"
  ROW_KEYS      = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  MARK_ROWS     = [2_u64, 2_u64, 2_u64]
  CHILD_ROWS    = [0, 3, 1, 0, 2, 0]
  FUNCTIONS     = ["groupBitOr", "groupBitAnd", "groupBitXor"]
  CODES         = ["or", "and", "xor"]
  INTEGER_TYPES = [
    {"UInt8", 1}, {"UInt16", 2}, {"UInt32", 4}, {"UInt64", 8},
    {"UInt128", 16}, {"UInt256", 32}, {"Int8", 1}, {"Int16", 2},
    {"Int32", 4}, {"Int64", 8}, {"Int128", 16}, {"Int256", 32},
  ]
  # Five literal little-endian operands are shared by the independent native
  # script. Each non-empty state is initializeAggregation(functionState, operand).
  PATTERNS = [
    "0123456789abcdeffedcba987654321000112233445566778899aabbccddeeff",
    "80ff7f0181fe7e0293ec6d1485fa2b7c92eb6c1584fb2a7d0f1e2d3c4b5a69f8",
    "f0e1d2c3b4a5968700112233445566778899aabbccddeefffedcba9876543210",
    "102030405060708090a0b0c0d0e0f001112233445566778899aabbccddeeff7f",
    "ff00aa5501807f031029384756abcdeffedcba9876543210deadbeef01234567",
  ]

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W255 bitwise helper: #{message}") unless condition
  end

  private def decode_hex(hex : String) : Bytes
    unless hex.bytesize.even? && hex.matches?(/\A(?:[0-9a-f]{2})*\z/)
      raise ArgumentError.new("W255 literal is not even lowercase hexadecimal")
    end
    Bytes.new(hex.bytesize // 2) do |index|
      ((nibble(hex.byte_at(index * 2)) << 4) | nibble(hex.byte_at(index * 2 + 1))).to_u8
    end
  end

  private def nibble(byte : UInt8) : UInt8
    if byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
      return (byte - '0'.ord.to_u8).to_u8
    end
    if byte >= 'a'.ord.to_u8 && byte <= 'f'.ord.to_u8
      return (byte - 'a'.ord.to_u8 + 10).to_u8
    end
    raise ArgumentError.new("W255 literal contains a non-hexadecimal byte")
  end

  private def encode_hex(bytes : Bytes) : String
    String.build { |io| bytes.each { |byte| io << byte.to_s(16).rjust(2, '0') } }
  end

  private def operand(pattern_index : Int32, width : Int32) : Bytes
    full = decode_hex(PATTERNS[pattern_index % PATTERNS.size])
    Bytes.new(width) { |index| full[index] }
  end

  private def state_type(function_index : Int32, type_index : Int32) : CrystalClick::BinaryDataType
    function = FUNCTIONS[function_index]
    argument = CrystalClick::BinaryDataType.primitive(INTEGER_TYPES[type_index][0])
    CrystalClick::BinaryDataType.aggregate_function(function, argument)
  end

  private def root_name(function_index : Int32, type_index : Int32) : String
    "state_#{CODES[function_index]}_#{INTEGER_TYPES[type_index][0].downcase}"
  end

  private def root_roster : Array(Tuple(String, CrystalClick::BinaryDataType, Array(CrystalClick::BinaryValue)))
    result = [] of Tuple(String, CrystalClick::BinaryDataType, Array(CrystalClick::BinaryValue))
    INTEGER_TYPES.each_with_index do |(_, width), type_index|
      FUNCTIONS.each_index do |function_index|
        type = state_type(function_index, type_index)
        values = Array(CrystalClick::BinaryValue).new(ROW_KEYS.size)
        5.times do |row|
          pattern_index = (row + type_index + function_index) % PATTERNS.size
          values << CrystalClick::BinaryValue.aggregate_function_state(type, operand(pattern_index, width))
        end
        empty = function_index == 1 ? Bytes.new(width, 0xff_u8) : Bytes.new(width, 0_u8)
        values << CrystalClick::BinaryValue.aggregate_function_state(type, empty)
        result << {root_name(function_index, type_index), type, values}
      end
    end
    result
  end

  private def child_type : CrystalClick::BinaryDataType
    fields = [
      state_type(0, 1),  # groupBitOr(UInt16)
      state_type(1, 10), # groupBitAnd(Int128)
      state_type(2, 5),  # groupBitXor(UInt256)
    ] of CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.tuple(fields, ["or_u16", "and_i128", "xor_u256"] of String)
  end

  private def children_roster : Tuple(CrystalClick::BinaryDataType, Array(CrystalClick::BinaryValue))
    tuple = child_type
    type = CrystalClick::BinaryDataType.array(tuple)
    rows = Array(CrystalClick::BinaryValue).new(ROW_KEYS.size)
    CHILD_ROWS.each_with_index do |count, parent|
      tuples = Array(CrystalClick::BinaryValue).new(count)
      count.times do |child_index|
        values = [] of CrystalClick::BinaryValue
        [{0, 1}, {1, 10}, {2, 5}].each_with_index do |(function_index, type_index), lane|
          width = INTEGER_TYPES[type_index][1]
          pattern_index = (parent + child_index + lane * 2) % PATTERNS.size
          values << CrystalClick::BinaryValue.aggregate_function_state(
            state_type(function_index, type_index), operand(pattern_index, width)
          )
        end
        tuples << CrystalClick::BinaryValue.tuple(tuple, values)
      end
      rows << CrystalClick::BinaryValue.array(type, tuples)
    end
    {type, rows}
  end

  private def same_value!(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue, path : String) : Nil
    require!(actual.type == expected.type, "#{path} nominal type differs")
    require!(actual.is_null? == expected.is_null?, "#{path} null marker differs")
    return if actual.is_null?

    if actual.type.tag == CrystalClick::BinaryDataType::TAG_AGGREGATE_FUNCTION
      require!(actual.aggregate_function_state_bytes == expected.aggregate_function_state_bytes,
        "#{path} raw aggregate-state bytes differ")
      return
    end

    if actual.type.tag == CrystalClick::BinaryDataType::TAG_ARRAY ||
       actual.type.tag == CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE ||
       actual.type.tag == CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      require!(actual.element_count == expected.element_count, "#{path} child count differs")
      actual.element_count.times do |index|
        same_value!(actual.element_at(index), expected.element_at(index), "#{path}[#{index}]")
      end
      return
    end

    require!(actual.bytes == expected.bytes, "#{path} fixed bytes differ")
    nil
  end

  private def same_rows!(actual : Array(CrystalClick::BinaryValue), expected : Array(CrystalClick::BinaryValue), label : String) : Nil
    require!(actual.size == expected.size, "#{label} row count differs")
    actual.each_with_index { |value, index| same_value!(value, expected[index], "#{label}[#{index}]") }
  end

  private def expected_hex(values : Array(CrystalClick::BinaryValue)) : Array(JSON::Any)
    values.map { |value| JSON::Any.new(encode_hex(value.aggregate_function_state_bytes)) }
  end

  private def state_hex(value : CrystalClick::BinaryValue, path : String) : String
    if value.type.tag == CrystalClick::BinaryDataType::TAG_AGGREGATE_FUNCTION
      return encode_hex(value.aggregate_function_state_bytes)
    end
    String.build do |io|
      io << '['
      value.element_count.times do |index|
        io << ',' if index > 0
        child = value.element_at(index)
        if child.type.tag == CrystalClick::BinaryDataType::TAG_AGGREGATE_FUNCTION
          io << '"' << encode_hex(child.aggregate_function_state_bytes) << '"'
        else
          io << state_hex(child, "#{path}[#{index}]")
        end
      end
      io << ']'
    end
  end

  private def read_column(part : String, name : String, type : CrystalClick::BinaryDataType,
                          expected : Array(CrystalClick::BinaryValue), origin : String) : JSON::Any
    reader = CrystalClick::BinaryBulkColumnReader.open(part, name, type)
    require!(reader.schema_declaration == type.name && reader.source_declaration == type.name,
      "#{origin}/#{name} nominal declaration differs")
    require!(reader.row_count == ROW_KEYS.size.to_u64 && reader.mark_row_counts == MARK_ROWS,
      "#{origin}/#{name} row/mark grid differs")
    actual = reader.read_marks(0, reader.mark_count).flat_map { |mark| mark }.to_a
    same_rows!(actual, expected, "#{origin}/#{name}")
    require!(reader.read_marks(reader.mark_count, 0).empty?, "#{origin}/#{name} EOF-zero window is nonempty")

    windows = [
      {"first", 0, 1, 0, 2}, {"middle", 1, 1, 2, 2}, {"final", 2, 1, 4, 2},
    ].map do |window|
      label, first_mark, mark_count, row_offset, row_count = window
      selected = reader.read_marks(first_mark, mark_count).flat_map { |mark| mark }.to_a
      same_rows!(selected, expected[row_offset, row_count], "#{origin}/#{name}/#{label}")
      JSON::Any.new({"name" => JSON::Any.new(label), "rows" => JSON::Any.new(row_count.to_i64)} of String => JSON::Any)
    end
    values = expected.map { |value| JSON::Any.new(state_hex(value, name)) }
    JSON::Any.new({
      "type"                  => JSON::Any.new(type.name),
      "row_count"             => JSON::Any.new(reader.row_count.to_i64),
      "mark_row_counts"       => JSON::Any.new(reader.mark_row_counts.map { |count| JSON::Any.new(count.to_i64) }),
      "physical_stream_names" => JSON::Any.new(reader.physical_stream_names.map { |stream| JSON::Any.new(stream) }),
      "windows"               => JSON::Any.new(windows),
      "state_hex_by_row"      => JSON::Any.new(values),
      "eof_zero_window"       => JSON::Any.new(true),
    } of String => JSON::Any)
  end

  private def public_scan(part : String, columns : Array(Tuple(String, CrystalClick::BinaryDataType, Array(CrystalClick::BinaryValue))), origin : String) : JSON::Any
    reports = [] of JSON::Any
    columns.each_slice(15) do |group|
      names = group.map(&.[0])
      table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_COLUMN] + names)
      collected = names.to_h { |name| {name, [] of CrystalClick::BinaryValue} }
      schedule = [] of Tuple(Int32, UInt64, Int32)
      table.scan_typed(batch_rows: 2) do |batch|
        group.each do |name, type, _expected|
          values = batch.binary_bulk_values_for(name)
          values.each do |value|
            require!(value.type == type, "#{origin}/#{name} public batch nominal type differs")
            collected[name] << value
          end
        end
        schedule << {batch.mark_index, batch.part_row_offset, batch.binary_bulk_values_for(names.first).size}
      end
      group.each do |name, _type, expected|
        same_rows!(collected[name], expected, "#{origin}/public/#{name}")
      end
      require!(schedule == [{0, 0_u64, 2}, {1, 2_u64, 2}, {2, 4_u64, 2}], "#{origin} public batch schedule differs")
      reports << JSON::Any.new({"columns"     => JSON::Any.new(names.map { |name| JSON::Any.new(name) }),
                                "batch_marks" => JSON::Any.new([0_i64, 1_i64, 2_i64].map { |mark| JSON::Any.new(mark) }),
                                "row_count"   => JSON::Any.new(6_i64)} of String => JSON::Any)
    end
    JSON::Any.new(reports)
  end

  private def offline_values(part : String, parent : String, origin : String, columns : Array(Tuple(String, CrystalClick::BinaryDataType, Array(CrystalClick::BinaryValue)))) : JSON::Any
    catalog_root = File.join(parent, "offline_catalog_#{origin}")
    require!(!File.exists?(catalog_root) && !File.symlink?(catalog_root), "offline catalog destination already exists")
    db_uuid = "25500000-0000-4000-8000-000000000001"
    table_uuid = "25510000-0000-4000-8000-000000000001"
    metadata = File.join(catalog_root, "metadata")
    db_store = File.join(catalog_root, "store", db_uuid[0, 3], db_uuid)
    table_store = File.join(catalog_root, "store", table_uuid[0, 3], table_uuid)
    [metadata, db_store, table_store].each { |path| FileUtils.mkdir_p(path) }
    File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{db_uuid}'\nENGINE = Atomic\n")
    ddl = String.build do |io|
      io << "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `id` UInt64,\n"
      columns.each_with_index do |(name, type, _), index|
        io << "    `#{name}` #{type.name}"
        io << ',' unless index == columns.size - 1
        io << '\n'
      end
      io << ")\nENGINE = MergeTree\nPRIMARY KEY id\nORDER BY id\n"
    end
    File.write(File.join(db_store, "events.sql"), ddl)
    File.write(File.join(table_store, "format_version.txt"), "1\n")
    FileUtils.mkdir_p(File.join(table_store, "detached"))
    FileUtils.cp_r(part, File.join(table_store, "all_1_1_0"))
    table = CrystalClick::OfflineCatalog.open(catalog_root)["lab"]["events"]
    columns.each do |name, _type, expected|
      actual = table[name].values.map(&.as(CrystalClick::BinaryValue))
      same_rows!(actual, expected, "offline/#{name}")
    end
    JSON::Any.new({"column_count" => JSON::Any.new(columns.size.to_i64), "row_count" => JSON::Any.new(6_i64),
                   "exact_nominal_states" => JSON::Any.new(true)} of String => JSON::Any)
  end

  private def validate_part!(part : String, label : String) : Nil
    full = File.expand_path(part)
    require!(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full, "#{label} part is absent or non-canonical")
    nil
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 2
      raise ArgumentError.new("usage: check_aggregate_bitwise_w255.cr STOCK_PART LIBRARY_PART")
    end
    source_part, library_part = args.map { |path| File.expand_path(path) }
    validate_part!(source_part, "stock source")
    require!(!File.exists?(library_part) && !File.symlink?(library_part), "library destination already exists")
    parent = File.dirname(library_part)
    root_values = root_roster
    array_type, array_values = children_roster
    all_columns = root_values + [{CHILD_COLUMN, array_type, array_values}]

    source_roots = root_values.map { |name, type, values| {name, type, values, read_column(source_part, name, type, values, "stock")} }
    source_array = read_column(source_part, CHILD_COLUMN, array_type, array_values, "stock")

    write_columns = all_columns.map do |name, type, values|
      marks = [values[0, 2], values[2, 2], values[4, 2]]
      CrystalClick::WidePartColumn.binary_bulk(name, type, marks)
    end
    CrystalClick::WidePartWriter.write_uint64_columns(
      library_part, KEY_COLUMN, ROW_KEYS.to_unsafe.to_slice(ROW_KEYS.size), write_columns,
      rows_per_mark: 2,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      shared_profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      frame_bytes: 64,
    )
    validate_part!(library_part, "library output")

    library_roots = root_values.map { |name, type, values| {name, type, values, read_column(library_part, name, type, values, "library")} }
    library_array = read_column(library_part, CHILD_COLUMN, array_type, array_values, "library")
    public_source = public_scan(source_part, all_columns, "stock")
    public_library = public_scan(library_part, all_columns, "library")
    offline_stock = offline_values(source_part, parent, "stock", all_columns)
    offline_library = offline_values(library_part, parent, "library", all_columns)

    root_evidence = all_columns.map do |name, type, values|
      JSON::Any.new({"name" => JSON::Any.new(name), "type" => JSON::Any.new(type.name),
                     "rows" => JSON::Any.new(values.map { |value| JSON::Any.new(state_hex(value, name)) })} of String => JSON::Any)
    end
    report = JSON::Any.new({
      "format"                => JSON::Any.new(FORMAT),
      "row_keys"              => JSON::Any.new(ROW_KEYS.map { |key| JSON::Any.new(key.to_i64) }),
      "mark_rows"             => JSON::Any.new(MARK_ROWS.map { |count| JSON::Any.new(count.to_i64) }),
      "child_row_counts"      => JSON::Any.new(CHILD_ROWS.map { |count| JSON::Any.new(count.to_i64) }),
      "root_state_count"      => JSON::Any.new(root_values.size.to_i64),
      "child_state_lanes"     => JSON::Any.new(3_i64),
      "bulk_profile"          => JSON::Any.new("with_size_stream"),
      "column_roster"         => JSON::Any.new(all_columns.map { |name, type, _| JSON::Any.new([JSON::Any.new(name), JSON::Any.new(type.name)]) }),
      "independent_state_hex" => JSON::Any.new(root_evidence),
      "source"                => JSON::Any.new({"path" => JSON::Any.new(source_part), "root_columns" => JSON::Any.new(source_roots.map { |entry| entry[3] }), "states" => source_array}),
      "library"               => JSON::Any.new({"path" => JSON::Any.new(library_part), "root_columns" => JSON::Any.new(library_roots.map { |entry| entry[3] }), "states" => library_array}),
      "public_stock"          => public_source,
      "public_library"        => public_library,
      "offline_stock"         => offline_stock,
      "offline_library"       => offline_library,
    } of String => JSON::Any)
    puts report.to_json
  rescue ex : Exception
    STDERR.puts "W255 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckAggregateBitwiseW255.main(ARGV)
