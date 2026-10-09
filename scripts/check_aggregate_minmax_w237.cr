require "../src/crystal_click"
require "json"
require "set"

module CheckAggregateMinMaxW237
  extend self

  FORMAT_INPUT     = "aggregate_minmax_w237_stock_v1"
  FORMAT_OUTPUT    = "aggregate_minmax_w237_helper_v1"
  OUTPUT_PREFIX    = "/private/tmp/crystal-click-w237-generated."
  MAX_MATRIX_BYTES = 16 * 1024 * 1024
  KEY_COLUMN       = "pk"
  COLUMN           = "v"
  ROW_KEYS         = [11_u64, 22_u64, 33_u64, 44_u64, 55_u64]
  MARK_ROWS        = [2_u64, 2_u64, 1_u64]

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W237 MinMax helper: #{message}") unless condition
  end

  private def nibble(byte : UInt8) : UInt8
    if byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
      return (byte - '0'.ord.to_u8).to_u8
    end
    if byte >= 'a'.ord.to_u8 && byte <= 'f'.ord.to_u8
      return (byte - 'a'.ord.to_u8 + 10).to_u8
    end
    raise ArgumentError.new("W237 state literals must be lowercase hexadecimal")
  end

  private def decode_hex(hex : String) : Bytes
    unless hex.bytesize.even? && hex.matches?(/\A(?:[0-9a-f]{2})*\z/)
      raise ArgumentError.new("W237 state literals must be even lowercase hexadecimal")
    end
    Bytes.new(hex.bytesize // 2) do |index|
      high = nibble(hex.byte_at(index * 2))
      low = nibble(hex.byte_at(index * 2 + 1))
      ((high << 4) | low).to_u8
    end
  end

  private def encode_hex(bytes : Bytes) : String
    String.build { |io| bytes.each { |byte| io << byte.to_s(16).rjust(2, '0') } }
  end

  private def json_strings(values : Array(String)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private def json_ints(values : Array(Int64)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private def json_u64s(values : Array(UInt64)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value.to_i64) })
  end

  private def equal_states!(actual : Array(CrystalClick::BinaryValue), expected : Array(CrystalClick::BinaryValue), label : String) : Nil
    require!(actual.size == expected.size, "#{label} row count differs")
    actual.each_with_index do |value, index|
      require!(value.type == expected[index].type, "#{label} nominal type differs at row #{index}")
      require!(
        value.aggregate_function_state_bytes == expected[index].aggregate_function_state_bytes,
        "#{label} state bytes differ at row #{index}"
      )
    end
    nil
  end

  private def expected_values(profile : JSON::Any, type : CrystalClick::BinaryDataType) : Array(CrystalClick::BinaryValue)
    values = profile["states_hex"].as_a.map do |item|
      CrystalClick::BinaryValue.aggregate_function_state(type, decode_hex(item.as_s))
    end
    require!(values.size == ROW_KEYS.size, "#{profile["id"].as_s} does not contain five state literals")
    values
  end

  private def parsed_type!(profile : JSON::Any) : CrystalClick::BinaryDataType
    id = profile["id"].as_s
    declared_name = profile["declared_type"].as_s
    type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(declared_name) ||
           raise ArgumentError.new("#{id} declared type is not canonical")
    descriptor = type.aggregate_function_type
    require!(type.tag == CrystalClick::BinaryDataType::TAG_AGGREGATE_FUNCTION && descriptor != nil,
      "#{id} type is not a nominal AggregateFunction declaration")
    require!(["min", "max"].includes?(descriptor.not_nil!.function_name), "#{id} function is outside the Min/Max frontier")
    require!(type.name == declared_name, "#{id} declared type differs from its canonical descriptor")
    type
  end

  private def expected_state_hex(values : Array(CrystalClick::BinaryValue)) : Array(String)
    values.map { |value| encode_hex(value.aggregate_function_state_bytes) }
  end

  private def window_json(first_mark : Int32, mark_count : Int32, first_row : Int32, values : Array(CrystalClick::BinaryValue)) : JSON::Any
    JSON::Any.new({
      "first_mark" => JSON::Any.new(first_mark),
      "mark_count" => JSON::Any.new(mark_count),
      "row_keys"   => json_u64s(ROW_KEYS[first_row, values.size]),
      "states_hex" => json_strings(expected_state_hex(values)),
    } of String => JSON::Any)
  end

  private def binary_reader_record(
    part : String,
    type : CrystalClick::BinaryDataType,
    expected : Array(CrystalClick::BinaryValue),
    label : String,
  ) : JSON::Any
    reader = CrystalClick::BinaryBulkColumnReader.open(part, COLUMN, type)
    require!(reader.schema_declaration == type.name, "#{label} selected schema differs")
    require!(reader.source_declaration == type.name, "#{label} source schema differs")
    require!(reader.row_count == ROW_KEYS.size.to_u64, "#{label} row count differs")
    require!(reader.mark_row_counts == MARK_ROWS, "#{label} mark schedule differs")
    require!(reader.mark_count == MARK_ROWS.size, "#{label} mark count differs")

    full = reader.read_marks(0, 3).flatten
    first = reader.read_marks(0, 1).first
    middle = reader.read_marks(1, 1).first
    final = reader.read_marks(2, 1).first
    eof = reader.read_marks(3, 0)
    equal_states!(full, expected, "#{label} full marks")
    equal_states!(first, expected[0, 2], "#{label} first mark")
    equal_states!(middle, expected[2, 2], "#{label} middle mark")
    equal_states!(final, expected[4, 1], "#{label} final short mark")
    require!(eof.empty?, "#{label} EOF selection is not empty")

    plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, COLUMN, CrystalClick::BinaryBulkProfile.single_stream)
    role_names = plan.stream_names.keys.sort!
    physical_names = plan.stream_names.values.sort!
    require!(reader.physical_stream_names.sort! == physical_names, "#{label} physical stream roster differs from its type plan")
    source = CrystalClick::PartStreamSource.new(part)
    streams = role_names.map do |role|
      prefix = plan.prefix_size_for(role)
      grid = source.inspect_grid(plan.data_file_for(role, true), plan.marks_file_for(role, true), prefix)
      data = source.read_all(plan.data_file_for(role, true))
      positions = grid.positions.map do |position|
        logical_position = position - prefix
        require!(logical_position >= 0, "#{label} #{role} has a negative logical mark offset")
        logical_position.to_i64
      end
      require!(positions.first? == 0_i64, "#{label} #{role} does not begin at offset zero")
      require!(positions.last? == data.size.to_i64, "#{label} #{role} EOF offset differs from stream size")
      JSON::Any.new({
        "role"         => JSON::Any.new(role),
        "byte_count"   => JSON::Any.new(data.size),
        "mark_offsets" => json_ints(positions),
      } of String => JSON::Any)
    end

    JSON::Any.new({
      "schema_declaration" => JSON::Any.new(reader.schema_declaration),
      "source_declaration" => JSON::Any.new(reader.source_declaration),
      "grid"               => JSON::Any.new({
        "row_count"               => JSON::Any.new(reader.row_count.to_i64),
        "mark_rows"               => json_u64s(reader.mark_row_counts),
        "mark_count"              => JSON::Any.new(reader.mark_count),
        "physical_stream_names"   => json_strings(reader.physical_stream_names),
        "logical_read_bytes"      => JSON::Any.new(reader.logical_read_bytes.to_i64),
        "selected_checksum_names" => json_strings(reader.selected_checksum_names),
      } of String => JSON::Any),
      "streams" => JSON::Any.new(streams),
      "windows" => JSON::Any.new({
        "full"             => window_json(0, 3, 0, full),
        "first_mark"       => window_json(0, 1, 0, first),
        "middle_mark"      => window_json(1, 1, 2, middle),
        "final_short_mark" => window_json(2, 1, 4, final),
        "eof_empty"        => window_json(3, 0, 5, [] of CrystalClick::BinaryValue),
      } of String => JSON::Any),
    } of String => JSON::Any)
  end

  private def typed_rows(
    table : CrystalClick::WidePartTable,
    type : CrystalClick::BinaryDataType,
    expected : Array(CrystalClick::BinaryValue),
    start_row : Int32,
    max_rows : Int32,
    label : String,
    whole_scan : Bool = false,
  ) : Array(JSON::Any)
    rows = [] of JSON::Any
    scan = ->(batch : CrystalClick::WidePartTableBatch) do
      keys = batch.values_for(KEY_COLUMN)
      values = batch.binary_bulk_values_for(COLUMN)
      require!(keys.size == values.size, "#{label} typed batch columns differ in length")
      keys.each_with_index do |key, index|
        offset = rows.size
        expected_index = start_row + offset
        require!(expected_index < start_row + max_rows, "#{label} returned too many rows")
        require!(key == ROW_KEYS[expected_index], "#{label} typed key differs at row #{expected_index}")
        value = values[index]
        require!(value.type == type, "#{label} typed nominal descriptor differs at row #{expected_index}")
        require!(
          value.aggregate_function_state_bytes == expected[expected_index].aggregate_function_state_bytes,
          "#{label} typed state differs at row #{expected_index}"
        )
        rows << JSON::Any.new({
          "key"       => JSON::Any.new(key.to_i64),
          "type"      => JSON::Any.new(value.type.name),
          "state_hex" => JSON::Any.new(encode_hex(value.aggregate_function_state_bytes)),
        } of String => JSON::Any)
      end
    end
    if whole_scan
      table.scan_typed(batch_rows: 2) { |batch| scan.call(batch) }
    else
      table.scan_typed_window(start_row.to_u64, max_rows: max_rows) { |batch| scan.call(batch) }
    end
    require!(rows.size == max_rows, "#{label} typed row count differs")
    rows
  end

  private def public_record(
    part : String,
    type : CrystalClick::BinaryDataType,
    expected : Array(CrystalClick::BinaryValue),
    label : String,
  ) : JSON::Any
    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_COLUMN, COLUMN])
    require!(table.column_types == [{KEY_COLUMN, "UInt64"}, {COLUMN, type.name}], "#{label} typed table schema differs")
    full = typed_rows(table, type, expected, 0, 5, "#{label} typed full scan", whole_scan: true)
    first = typed_rows(table, type, expected, 0, 2, "#{label} typed first window")
    middle = typed_rows(table, type, expected, 2, 2, "#{label} typed middle window")
    final = typed_rows(table, type, expected, 4, 1, "#{label} typed final window")

    eof_rows = [] of JSON::Any
    table.scan_typed_window(5_u64, max_rows: 1) do |batch|
      eof_rows.concat(batch.binary_bulk_values_for(COLUMN).map do |value|
        JSON::Any.new({
          "type"      => JSON::Any.new(value.type.name),
          "state_hex" => JSON::Any.new(encode_hex(value.aggregate_function_state_bytes)),
        } of String => JSON::Any)
      end)
    end
    require!(eof_rows.empty?, "#{label} typed EOF window is not empty")

    JSON::Any.new({
      "full"            => JSON::Any.new(full),
      "first_two_rows"  => JSON::Any.new(first),
      "middle_two_rows" => JSON::Any.new(middle),
      "final_one_row"   => JSON::Any.new(final),
      "eof_empty"       => JSON::Any.new(eof_rows),
    } of String => JSON::Any)
  end

  private def process_profile(profile : JSON::Any, generated_root : String) : JSON::Any
    id = profile["id"].as_s
    type = parsed_type!(profile)
    expected = expected_values(profile, type)
    literals = profile["states_hex"].as_a.map(&.as_s)
    require!(literals == expected_state_hex(expected), "#{id} raw Min/Max state literals changed during ownership")

    stock_part = profile["stock_part_path"].as_s
    require!(stock_part == File.expand_path(stock_part), "#{id} stock part path is not canonical")
    require!(Dir.exists?(stock_part) && !File.symlink?(stock_part) && File.realpath(stock_part) == stock_part,
      "#{id} stock part path is absent, symlinked, or noncanonical")
    stock_record = binary_reader_record(stock_part, type, expected, "stock/#{id}")
    stock_public = public_record(stock_part, type, expected, "stock/#{id}")

    slot = File.join(generated_root, id)
    require!(!File.exists?(slot) && !File.symlink?(slot), "#{id} generated profile slot is not fresh")
    Dir.mkdir(slot)
    require!(Dir.exists?(slot) && !File.symlink?(slot) && File.realpath(slot) == slot,
      "#{id} generated profile slot is noncanonical")
    library_part = File.join(slot, "all_1_1_0")
    marks = [expected[0, 2], expected[2, 2], expected[4, 1]]
    written = CrystalClick::WidePartWriter.write_uint64_and_aggregate_function_part(
      library_part,
      KEY_COLUMN,
      Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64],
      COLUMN,
      type,
      marks,
      rows_per_mark: 2,
      frame_bytes: 64,
    )
    require!(written == library_part && Dir.exists?(written) && !File.symlink?(written),
      "#{id} paired writer did not publish its exact profile part")
    library_record = binary_reader_record(written, type, expected, "library/#{id}")
    library_public = public_record(written, type, expected, "library/#{id}")

    JSON::Any.new({
      "id"                => JSON::Any.new(id),
      "declared_type"     => JSON::Any.new(type.name),
      "stock_part_path"   => JSON::Any.new(stock_part),
      "library_part_path" => JSON::Any.new(File.expand_path(written)),
      "row_keys"          => json_u64s(ROW_KEYS),
      "mark_rows"         => json_u64s(MARK_ROWS),
      "states_hex"        => json_strings(literals),
      "stock"             => stock_record,
      "library"           => library_record,
      "public_typed"      => JSON::Any.new({
        "stock"   => stock_public,
        "library" => library_public,
      } of String => JSON::Any),
    } of String => JSON::Any)
  end

  private def canonical_empty_output_root!(path : String) : Nil
    require!(path == File.expand_path(path), "output root is not canonical")
    require!(path.starts_with?(OUTPUT_PREFIX) && File.dirname(path) == "/private/tmp",
      "output root escaped its canonical /private/tmp W237 prefix")
    require!(Dir.exists?(path) && !File.symlink?(path) && File.realpath(path) == path,
      "output root is absent, symlinked, or noncanonical")
    require!(Dir.children(path).empty?, "output root is not empty")
    nil
  end

  private def validate_matrix!(input : JSON::Any) : Array(JSON::Any)
    require!(input["format"].as_s == FORMAT_INPUT, "input matrix format differs")
    require!(input["row_keys"].as_a.map(&.as_i64) == ROW_KEYS.map(&.to_i64), "input row keys differ")
    require!(input["mark_rows"].as_a.map(&.as_i64) == MARK_ROWS.map(&.to_i64), "input mark schedule differs")
    profiles = input["profiles"].as_a
    require!(profiles.size >= 1 && profiles.size <= 256, "profile roster is outside bounded 1..256 cases")
    ids = Set(String).new
    profiles.each do |profile|
      require!(profile.as_h.keys.sort == %w[declared_type id states_hex stock_part_path].sort,
        "profile fields differ from the W237 stock matrix contract")
      id = profile["id"].as_s
      require!(id != "." && id != ".." && id.matches?(/\A[A-Za-z0-9_.-]+\z/) && !ids.includes?(id),
        "unsafe or duplicate profile id")
      ids << id
      require!(profile["states_hex"].as_a.size == ROW_KEYS.size, "#{id} does not contain five states")
      profile["states_hex"].as_a.each { |state| decode_hex(state.as_s) }
    end
    profiles
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 4 && args.includes?("--stock-matrix") && args.includes?("--output-root")
      raise ArgumentError.new("usage: check_aggregate_minmax_w237.cr --stock-matrix PATH --output-root ROOT")
    end
    matrix_index = args.index("--stock-matrix").not_nil!
    output_index = args.index("--output-root").not_nil!
    unless matrix_index != output_index && matrix_index + 1 != output_index && output_index + 1 != matrix_index
      raise ArgumentError.new("W237 helper options require one path each")
    end
    matrix_path = args[matrix_index + 1]
    output_root_argument = args[output_index + 1]
    output_root = File.expand_path(output_root_argument)
    require!(output_root_argument == output_root, "output root argument is not canonical")
    require!(matrix_path == File.expand_path(matrix_path), "stock matrix path is not canonical")
    require!(File.file?(matrix_path) && !File.symlink?(matrix_path) && File.realpath(matrix_path) == matrix_path,
      "stock matrix is absent, symlinked, or noncanonical")
    require!(File.size(matrix_path) <= MAX_MATRIX_BYTES, "stock matrix exceeds the bounded input size")
    canonical_empty_output_root!(output_root)

    input = JSON.parse(File.read(matrix_path))
    profiles = validate_matrix!(input)
    generated_root = File.join(output_root, "generated")
    Dir.mkdir(generated_root)
    require!(Dir.exists?(generated_root) && !File.symlink?(generated_root) && File.realpath(generated_root) == generated_root,
      "generated directory is absent, symlinked, or noncanonical")
    output_profiles = profiles.map { |profile| process_profile(profile, generated_root) }
    puts JSON::Any.new({
      "format"        => JSON::Any.new(FORMAT_OUTPUT),
      "profile_count" => JSON::Any.new(output_profiles.size),
      "profiles"      => JSON::Any.new(output_profiles),
    } of String => JSON::Any).to_json
  rescue ex : Exception
    STDERR.puts "W237 MinMax Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckAggregateMinMaxW237.main(ARGV)
