require "../src/crystal_click"
require "json"
require "set"
require "file_utils"

module CheckAggregateAvgW227
  extend self

  FORMAT_INPUT    = "aggregate_avg_w227_input_v1"
  FORMAT_OUTPUT   = "aggregate_avg_w227_helper_v1"
  CAPTURE_PREFIX  = "/private/tmp/crystal-click-w227-native."
  EVIDENCE_PREFIX = "/private/tmp/crystal-click-w227-evidence."
  KEY_COLUMN      = "pk"
  COLUMN          = "v"
  ROW_KEYS        = [11_u64, 22_u64, 33_u64, 44_u64, 55_u64]
  MARK_ROWS       = [2_u64, 2_u64, 1_u64]

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W227 Avg helper: #{message}") unless condition
  end

  private def nibble(byte : UInt8) : UInt8
    if byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
      return (byte - '0'.ord.to_u8).to_u8
    end
    if byte >= 'a'.ord.to_u8 && byte <= 'f'.ord.to_u8
      return (byte - 'a'.ord.to_u8 + 10).to_u8
    end
    raise ArgumentError.new("W227 literal bytes must be lowercase hexadecimal")
  end

  private def decode_hex(hex : String) : Bytes
    unless hex.bytesize.even? && hex.matches?(/\A(?:[0-9a-f]{2})*\z/)
      raise ArgumentError.new("W227 literal bytes must be even lowercase hexadecimal")
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

  private def key_bytes(key : UInt64) : Bytes
    Bytes.new(8) { |index| ((key >> (index * 8)) & 0xff_u64).to_u8 }
  end

  private def join_bytes(parts : Array(Bytes)) : Bytes
    byte_count = 0
    parts.each do |part|
      if part.size > Int32::MAX - byte_count
        raise ArgumentError.new("W227 raw lane exceeds the in-memory byte domain")
      end
      byte_count += part.size
    end
    result = Bytes.new(byte_count)
    offset = 0
    parts.each do |part|
      part.size.times { |index| result[offset + index] = part[index] }
      offset += part.size
    end
    result
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

  private def require_equal_values!(
    actual : Array(CrystalClick::BinaryValue),
    expected : Array(CrystalClick::BinaryValue),
    label : String,
  ) : Nil
    require!(actual.size == expected.size, "#{label} row count differs")
    actual.each_with_index do |value, index|
      require!(value.type == expected[index].type, "#{label} nominal descriptor differs at row #{index}")
      require!(
        value.aggregate_function_state_bytes == expected[index].aggregate_function_state_bytes,
        "#{label} raw state bytes differ at row #{index}"
      )
    end
    nil
  end

  private def expected_values(profile : JSON::Any, type : CrystalClick::BinaryDataType) : Array(CrystalClick::BinaryValue)
    states = profile["state_hex"].as_a.map do |item|
      CrystalClick::BinaryValue.aggregate_function_state(type, decode_hex(item.as_s))
    end
    require!(states.size == 5, "#{profile["id"].as_s} does not contain five raw states")
    states
  end

  private def literal_rowbinary!(profile : JSON::Any, expected : Array(CrystalClick::BinaryValue)) : Nil
    actual = profile["literal_rowbinary_hex"].as_a.map(&.as_s)
    require!(actual.size == 5, "#{profile["id"].as_s} does not contain five RowBinary literals")
    ROW_KEYS.each_with_index do |key, index|
      expected_bytes = join_bytes([key_bytes(key), expected[index].aggregate_function_state_bytes] of Bytes)
      require!(decode_hex(actual[index]) == expected_bytes, "#{profile["id"].as_s} RowBinary literal differs at row #{index}")
    end
    nil
  end

  private def window_json(
    first_mark : Int32,
    mark_count : Int32,
    first_row : Int32,
    values : Array(CrystalClick::BinaryValue),
  ) : JSON::Any
    keys = ROW_KEYS[first_row, values.size]
    JSON::Any.new({
      "first_mark" => JSON::Any.new(first_mark),
      "mark_count" => JSON::Any.new(mark_count),
      "row_keys"   => json_u64s(keys),
      "state_hex"  => json_strings(values.map { |value| encode_hex(value.aggregate_function_state_bytes) }),
    } of String => JSON::Any)
  end

  private def part_record(
    part : String,
    type : CrystalClick::BinaryDataType,
    expected : Array(CrystalClick::BinaryValue),
    label : String,
  ) : JSON::Any
    reader = CrystalClick::BinaryBulkColumnReader.open(part, COLUMN, type)
    require!(reader.schema_declaration == type.name, "#{label} declared schema differs")
    require!(reader.row_count == ROW_KEYS.size.to_u64, "#{label} row count differs")
    require!(reader.mark_row_counts == MARK_ROWS, "#{label} source mark grid differs")
    require!(reader.mark_count == MARK_ROWS.size, "#{label} mark count differs")

    full = reader.read_marks(0, 3).flatten
    first = reader.read_marks(0, 1).first
    middle = reader.read_marks(1, 1).first
    final = reader.read_marks(2, 1).first
    eof = reader.read_marks(3, 0)
    require_equal_values!(full, expected, "#{label} full range")
    require_equal_values!(first, expected[0, 2], "#{label} first mark")
    require_equal_values!(middle, expected[2, 2], "#{label} middle mark")
    require_equal_values!(final, expected[4, 1], "#{label} final short mark")
    require!(eof.empty?, "#{label} EOF empty range is nonempty")

    plan = CrystalClick::BinaryBulkPhysicalPlan.new(
      type,
      COLUMN,
      CrystalClick::BinaryBulkProfile.single_stream,
    )
    part_source = CrystalClick::PartStreamSource.new(part)
    streams = plan.stream_names.keys.sort!.map do |role|
      data_name = plan.data_file_for(role, true)
      marks_name = plan.marks_file_for(role, true)
      prefix = plan.prefix_size_for(role)
      grid = part_source.inspect_grid(data_name, marks_name, prefix)
      bytes = part_source.read_all(data_name)
      positions = grid.positions.map do |position|
        logical_position = position - prefix
        require!(logical_position >= 0, "#{label} #{role} stream has an invalid mark offset")
        logical_position.to_i64
      end
      require!(positions.first? == 0_i64, "#{label} #{role} stream does not start at offset zero")
      require!(positions.last? == bytes.size.to_i64, "#{label} #{role} EOF offset differs from stream length")
      JSON::Any.new({
        "role"         => JSON::Any.new(role),
        "byte_count"   => JSON::Any.new(bytes.size),
        "bytes_hex"    => JSON::Any.new(encode_hex(bytes)),
        "mark_offsets" => json_ints(positions),
      } of String => JSON::Any)
    end
    role_names = plan.stream_names.keys.sort!
    require!(role_names == ["root.data"], "#{label} Avg leaf physical roles differ")
    require!(streams.size == 1, "#{label} Avg physical stream count differs")

    JSON::Any.new({
      "grid" => JSON::Any.new({
        "row_count"             => JSON::Any.new(reader.row_count.to_i64),
        "mark_rows"             => json_u64s(reader.mark_row_counts),
        "mark_count"            => JSON::Any.new(reader.mark_count),
        "physical_stream_names" => json_strings(reader.physical_stream_names),
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

  private def public_scan(
    part : String,
    type : CrystalClick::BinaryDataType,
    expected : Array(CrystalClick::BinaryValue),
    label : String,
  ) : Array(JSON::Any)
    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_COLUMN, COLUMN])
    require!(table.column_types == [{KEY_COLUMN, "UInt64"}, {COLUMN, type.name}], "#{label} typed table schema differs")
    rows = [] of JSON::Any
    schedule = [] of Tuple(Int32, UInt64, Int32)
    table.scan_typed(batch_rows: 2) do |batch|
      keys = batch.values_for(KEY_COLUMN)
      values = batch.binary_bulk_values_for(COLUMN)
      require!(keys.size == values.size, "#{label} typed batch column lengths differ")
      keys.each_with_index do |key, index|
        value = values[index]
        require!(key == ROW_KEYS[rows.size], "#{label} typed batch key differs at row #{rows.size}")
        require!(value.type == type, "#{label} typed batch loses nominal Avg descriptor")
        require!(
          value.aggregate_function_state_bytes == expected[rows.size].aggregate_function_state_bytes,
          "#{label} typed batch state differs at row #{rows.size}"
        )
        rows << JSON::Any.new({
          "key"       => JSON::Any.new(key.to_i64),
          "type"      => JSON::Any.new(value.type.name),
          "state_hex" => JSON::Any.new(encode_hex(value.aggregate_function_state_bytes)),
        } of String => JSON::Any)
      end
      schedule << {batch.mark_index, batch.part_row_offset, values.size}
    end
    require!(rows.size == expected.size, "#{label} typed batch row count differs")
    require!(
      schedule == [{0_i32, 0_u64, 2_i32}, {1_i32, 2_u64, 2_i32}, {2_i32, 4_u64, 1_i32}],
      "#{label} typed batch schedule differs"
    )
    rows
  end

  private def offline_table(
    part : String,
    output_root : String,
    type : CrystalClick::BinaryDataType,
    index : Int32,
    side : String,
  ) : CrystalClick::OfflineTable
    token = index.to_s(16).rjust(12, '0')
    suffix = side == "source" ? "0" : "1"
    db_uuid = "22700000-0000-4000-8000-#{suffix}#{token[1, 11]}"
    table_uuid = "22710000-0000-4000-8000-#{suffix}#{token[1, 11]}"
    catalog = File.join(output_root, "offline-#{index}-#{side}")
    raise ArgumentError.new("W227 offline catalog destination already exists") if File.exists?(catalog) || File.symlink?(catalog)
    metadata = File.join(catalog, "metadata")
    db_store = File.join(catalog, "store", db_uuid[0, 3], db_uuid)
    table_store = File.join(catalog, "store", table_uuid[0, 3], table_uuid)
    [metadata, db_store, table_store].each { |path| FileUtils.mkdir_p(path) }
    File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{db_uuid}'\nENGINE = Atomic\n")
    File.write(File.join(db_store, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `v` #{type.name}\n)\nENGINE = MergeTree\nPRIMARY KEY pk\nORDER BY pk\n")
    File.write(File.join(table_store, "format_version.txt"), "1\n")
    FileUtils.mkdir_p(File.join(table_store, "detached"))
    FileUtils.cp_r(part, File.join(table_store, "all_1_1_0"))
    CrystalClick::OfflineCatalog.open(catalog)["lab"]["events"]
  end

  private def offline_values(
    part : String,
    output_root : String,
    type : CrystalClick::BinaryDataType,
    expected : Array(CrystalClick::BinaryValue),
    index : Int32,
    side : String,
  ) : Array(JSON::Any)
    column = offline_table(part, output_root, type, index, side)[COLUMN]
    values = column.values(max_rows: expected.size.to_u64).map(&.as(CrystalClick::BinaryValue))
    require_equal_values!(values, expected, "offline #{side} values")
    values.map do |value|
      JSON::Any.new({
        "type"      => JSON::Any.new(value.type.name),
        "state_hex" => JSON::Any.new(encode_hex(value.aggregate_function_state_bytes)),
      } of String => JSON::Any)
    end
  end

  private def process_profile(profile : JSON::Any, output_root : String, index : Int32) : JSON::Any
    id = profile["id"].as_s
    argument_name = profile["argument_type"].as_s
    declared_name = profile["declared_type"].as_s
    argument = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(argument_name) ||
               raise ArgumentError.new("#{id} Avg argument type is not canonical")
    type = CrystalClick::BinaryDataType.aggregate_function("avg", argument)
    require!(type.name == declared_name, "#{id} declared Avg type differs from its canonical descriptor")
    require!(type.aggregate_function_type.try(&.function_name) == "avg", "#{id} function identity is not avg")

    expected = expected_values(profile, type)
    literal_rowbinary!(profile, expected)
    expected_state_hex = profile["state_hex"].as_a.map(&.as_s)
    require!(expected_state_hex == expected.map { |value| encode_hex(value.aggregate_function_state_bytes) }, "#{id} raw Avg state literals changed")

    source_part = File.expand_path(profile["source_part"].as_s)
    library_part = File.expand_path(profile["library_part"].as_s)
    library_slot = File.dirname(library_part)
    source_record = part_record(source_part, type, expected, "source/#{id}")
    source_public = public_scan(source_part, type, expected, "source/#{id}")

    marks = [expected[0, 2], expected[2, 2], expected[4, 1]]
    require!(!File.exists?(library_slot) && !File.symlink?(library_slot), "#{id} validated library slot is no longer fresh")
    Dir.mkdir(library_slot)
    require!(Dir.exists?(library_slot) && !File.symlink?(library_slot) && File.realpath(library_slot) == library_slot,
      "#{id} library slot is absent, symlinked, or noncanonical after creation")
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
    require!(written == library_part && Dir.exists?(written), "#{id} paired library writer did not publish its exact destination")
    library_record = part_record(written, type, expected, "library/#{id}")
    library_public = public_scan(written, type, expected, "library/#{id}")
    source_owned = offline_values(source_part, output_root, type, expected, index, "source")
    library_owned = offline_values(written, output_root, type, expected, index, "library")

    JSON::Any.new({
      "id"                => JSON::Any.new(id),
      "declared_type"     => JSON::Any.new(type.name),
      "argument_type"     => JSON::Any.new(argument.name),
      "library_part_path" => JSON::Any.new(File.expand_path(written)),
      "row_keys"          => json_u64s(ROW_KEYS),
      "mark_rows"         => json_u64s(MARK_ROWS),
      "exact_state_hex"   => json_strings(expected_state_hex),
      "source"            => source_record,
      "library"           => library_record,
      "public_values"     => JSON::Any.new({
        "source"  => JSON::Any.new(source_public),
        "library" => JSON::Any.new(library_public),
      } of String => JSON::Any),
      "owned_values" => JSON::Any.new({
        "source"  => JSON::Any.new(source_owned),
        "library" => JSON::Any.new(library_owned),
      } of String => JSON::Any),
    } of String => JSON::Any)
  end

  private def validate_input!(input : JSON::Any, output_root : String, capture_root : String) : Array(JSON::Any)
    require!(
      input.as_h.keys.sort == ["capture_root", "format", "profiles"] && input["format"].as_s == FORMAT_INPUT,
      "input format differs"
    )
    require!(input["capture_root"].as_s == capture_root, "input capture root differs from argv")
    require!(
      Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "capture root is absent, symlinked, or noncanonical"
    )
    require!(
      capture_root.starts_with?(CAPTURE_PREFIX) && File.dirname(capture_root) == "/private/tmp",
      "capture root escaped its W227 prefix"
    )
    require!(
      Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root,
      "generated output root is absent, symlinked, or noncanonical"
    )
    require!(
      output_root.ends_with?("/generated") && File.dirname(output_root).starts_with?(EVIDENCE_PREFIX) &&
      File.dirname(File.dirname(output_root)) == "/private/tmp",
      "generated root escaped its W227 evidence prefix"
    )
    parts_root = File.join(output_root, "parts")
    require!(
      Dir.exists?(parts_root) && !File.symlink?(parts_root) && File.realpath(parts_root) == parts_root,
      "generated parts root is absent, symlinked, or noncanonical"
    )

    profiles = input["profiles"].as_a
    require!(profiles.size >= 1 && profiles.size <= 256, "profile roster is outside bounded 1..256 cases")
    ids = Set(String).new
    profiles.each_with_index do |profile, index|
      id = profile["id"].as_s
      require!(id.matches?(/\A[A-Za-z0-9_.-]+\z/) && !ids.includes?(id), "unsafe or duplicate profile id")
      ids << id
      require!(
        profile.as_h.keys.sort == %w[argument_type declared_type id library_part literal_rowbinary_hex mark_rows row_keys source_part state_hex].sort,
        "#{id} fields differ from the exact W227 input contract"
      )
      require!(profile["row_keys"].as_a.map(&.as_i64) == ROW_KEYS.map(&.to_i64), "#{id} row keys differ")
      require!(profile["mark_rows"].as_a.map(&.as_i64) == MARK_ROWS.map(&.to_i64), "#{id} mark rows differ")
      require!(profile["state_hex"].as_a.size == 5 && profile["literal_rowbinary_hex"].as_a.size == 5, "#{id} literal array lengths differ")

      source = File.expand_path(profile["source_part"].as_s)
      generated = File.expand_path(profile["library_part"].as_s)
      slot = File.join(parts_root, "library-#{index.to_s.rjust(3, '0')}-#{id}")
      expected_generated = File.join(slot, "all_1_1_0")
      require!(
        source.starts_with?(capture_root + File::SEPARATOR) && Dir.exists?(source) &&
        !File.symlink?(source) && File.realpath(source) == source,
        "#{id} source part escaped, is symlinked, or is absent"
      )
      require!(
        generated == expected_generated,
        "#{id} library part does not match its exact profile-index slot"
      )
      require!(
        !File.exists?(slot) && !File.symlink?(slot) && !File.exists?(generated) && !File.symlink?(generated),
        "#{id} library slot or part is not fresh"
      )
    end
    profiles
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 3
      raise ArgumentError.new("usage: check_aggregate_avg_w227.cr INPUT.json OUTPUT_ROOT CAPTURE_ROOT")
    end
    input_path, output_root, capture_root = args.map { |path| File.expand_path(path) }
    require!(
      File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR),
      "helper input is not a plain file under generated root"
    )
    profiles = validate_input!(JSON.parse(File.read(input_path)), output_root, capture_root)
    output_profiles = profiles.each_with_index.map do |profile, index|
      process_profile(profile, output_root, index)
    end.to_a
    output = JSON::Any.new({
      "format"        => JSON::Any.new(FORMAT_OUTPUT),
      "profile_count" => JSON::Any.new(output_profiles.size),
      "profiles"      => JSON::Any.new(output_profiles),
    } of String => JSON::Any)
    puts output.to_json
  rescue ex : Exception
    STDERR.puts "W227 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckAggregateAvgW227.main(ARGV)
