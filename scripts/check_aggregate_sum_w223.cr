require "../src/crystal_click"
require "json"
require "set"
require "file_utils"

module CheckAggregateSumW223
  extend self

  FORMAT_INPUT  = "aggregate_sum_w223_input_v1"
  FORMAT_OUTPUT = "aggregate_sum_w223_helper_v1"
  ROOT_PREFIX   = "/private/tmp/crystal-click-w223-physical."
  KEY_COLUMN    = "pk"
  COLUMN        = "v"
  KEYS          = Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64]
  MARK_ROWS     = [2_u64, 2_u64, 1_u64]
  ROW_KEYS      = [11_u64, 22_u64, 33_u64, 44_u64, 55_u64]

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W223 aggregate bulk: #{message}") unless condition
  end

  private def decode_hex(hex : String) : Bytes
    unless hex.bytesize.even? && hex.matches?(/\A(?:[0-9a-f]{2})*\z/)
      raise ArgumentError.new("W223 literal bytes must be even lowercase hexadecimal")
    end
    Bytes.new(hex.bytesize // 2) do |index|
      high = nibble(hex.byte_at(index * 2))
      low = nibble(hex.byte_at(index * 2 + 1))
      ((high << 4) | low).to_u8
    end
  end

  private def nibble(byte : UInt8) : UInt8
    if byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
      return (byte - '0'.ord.to_u8).to_u8
    end
    if byte >= 'a'.ord.to_u8 && byte <= 'f'.ord.to_u8
      return (byte - 'a'.ord.to_u8 + 10).to_u8
    end
    raise ArgumentError.new("W223 literal bytes are not lowercase hexadecimal")
  end

  private def encode_hex(bytes : Bytes) : String
    String.build { |io| bytes.each { |byte| io << byte.to_s(16).rjust(2, '0') } }
  end

  private def same_sum_value?(left : CrystalClick::BinaryValue, right : CrystalClick::BinaryValue) : Bool
    left.type == right.type && left.aggregate_function_state_bytes == right.aggregate_function_state_bytes
  end

  private def same_count_value?(left : CrystalClick::BinaryValue, right : CrystalClick::BinaryValue) : Bool
    left.type == right.type && left.count_state == right.count_state
  end

  private def require_equal_values!(actual : Array(CrystalClick::BinaryValue), expected : Array(CrystalClick::BinaryValue), label : String, count : Bool = false) : Nil
    require!(actual.size == expected.size, "#{label} row count differs")
    actual.each_with_index do |value, index|
      equal = count ? same_count_value?(value, expected[index]) : same_sum_value?(value, expected[index])
      require!(equal, "#{label} nominal descriptor/state bytes differ at row #{index}")
    end
  end

  private def expected_sum_values(profile : JSON::Any, type : CrystalClick::BinaryDataType) : Array(CrystalClick::BinaryValue)
    profile["state_hex"].as_a.map do |item|
      CrystalClick::BinaryValue.aggregate_function_state(type, decode_hex(item.as_s))
    end
  end

  private def expected_count_values(profile : JSON::Any, type : CrystalClick::BinaryDataType) : Array(CrystalClick::BinaryValue)
    profile["counts"].as_a.map do |item|
      CrystalClick::BinaryValue.aggregate_count_state(type, item.as_s.to_u64)
    end
  end

  private def read_sum_part(part : String, type : CrystalClick::BinaryDataType, expected : Array(CrystalClick::BinaryValue), label : String) : JSON::Any
    reader = CrystalClick::BinaryBulkColumnReader.open(part, COLUMN, type)
    require!(reader.schema_declaration == type.name, "#{label} bulk schema declaration differs")
    require!(reader.mark_row_counts == MARK_ROWS, "#{label} real mark grid differs")
    require!(reader.row_count == 5_u64 && reader.mark_count == 3, "#{label} bulk axes differ")

    full = [] of CrystalClick::BinaryValue
    MARK_ROWS.each_with_index do |rows, mark|
      values = reader.read_marks(mark, 1)
      require!(values.size == 1 && values[0].size.to_u64 == rows, "#{label} mark #{mark} row count differs")
      full.concat(values[0])
    end
    require_equal_values!(full, expected, "#{label} full read")
    require_equal_values!(reader.read_marks(0, 1)[0], expected[0, 2], "#{label} first mark")
    require_equal_values!(reader.read_marks(1, 1)[0], expected[2, 2], "#{label} middle mark")
    require_equal_values!(reader.read_marks(2, 1)[0], expected[4, 1], "#{label} final short mark")
    require!(reader.read_marks(3, 0).empty?, "#{label} EOF empty range is not empty")

    JSON::Any.new({
      "schema_declaration"    => JSON::Any.new(reader.schema_declaration),
      "source_declaration"    => JSON::Any.new(reader.source_declaration),
      "row_count"             => JSON::Any.new(reader.row_count.to_i64),
      "mark_row_counts"       => JSON::Any.new(reader.mark_row_counts.map { |n| JSON::Any.new(n.to_i64) }),
      "physical_stream_names" => JSON::Any.new(reader.physical_stream_names.map { |name| JSON::Any.new(name) }),
      "windows"               => JSON::Any.new(["full", "first_mark", "middle_mark", "final_short_mark", "eof_empty"].map { |label| JSON::Any.new(label) }),
      "exact_nominal_states"  => JSON::Any.new(true),
    } of String => JSON::Any)
  end

  private def read_count_part(part : String, type : CrystalClick::BinaryDataType, expected : Array(CrystalClick::BinaryValue), label : String) : JSON::Any
    reader = CrystalClick::WidePart.open_typed(part, COLUMN)
    require!(reader.column_type == type.name, "#{label} Count declaration differs")
    require!(reader.row_count == 5_u64 && reader.mark_row_counts == MARK_ROWS, "#{label} Count axes differ")
    full = reader.read_aggregate_count_mark_range(COLUMN, 0, 3, type)
    require_equal_values!(full, expected, "#{label} Count full read", true)
    require_equal_values!(reader.read_aggregate_count_mark_range(COLUMN, 0, 1, type), expected[0, 2], "#{label} Count first mark", true)
    require_equal_values!(reader.read_aggregate_count_mark_range(COLUMN, 1, 1, type), expected[2, 2], "#{label} Count middle mark", true)
    require_equal_values!(reader.read_aggregate_count_mark_range(COLUMN, 2, 1, type), expected[4, 1], "#{label} Count final short mark", true)
    count_plan = CrystalClick::WideAggregateCountStoragePlan.require(type)
    JSON::Any.new({"declaration" => JSON::Any.new(reader.column_type), "row_count" => JSON::Any.new(reader.row_count.to_i64),
                   "mark_row_counts" => JSON::Any.new(reader.mark_row_counts.map { |n| JSON::Any.new(n.to_i64) }),
                   "physical_stream_names" => JSON::Any.new(count_plan.physical_streams(COLUMN).map { |name| JSON::Any.new(name) }),
                   "exact_nominal_count_states" => JSON::Any.new(true)} of String => JSON::Any)
  end

  private def public_sum_scan(part : String, type : CrystalClick::BinaryDataType, expected : Array(CrystalClick::BinaryValue), label : String) : JSON::Any
    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_COLUMN, COLUMN])
    actual = [] of CrystalClick::BinaryValue
    schedule = [] of Tuple(Int32, UInt64, Int32)
    table.scan_typed(batch_rows: 2) do |batch|
      row_count = 0
      batch.binary_bulk_values_for(COLUMN).each do |value|
        require!(value.type == type, "#{label} public typed batch lost nominal descriptor")
        actual << value
        row_count += 1
      end
      schedule << {batch.mark_index, batch.part_row_offset, row_count}
    end
    require_equal_values!(actual, expected, "#{label} public scan")
    require!(schedule == [{0_i32, 0_u64, 2_i32}, {1_i32, 2_u64, 2_i32}, {2_i32, 4_u64, 1_i32}], "#{label} typed scan schedule differs")
    JSON::Any.new({"api"                  => JSON::Any.new("WidePartTable.open_selected_typed + scan_typed + binary_bulk_values_for"),
                   "batch_schedule"       => JSON::Any.new(schedule.map { |entry| JSON::Any.new([JSON::Any.new(entry[0]), JSON::Any.new(entry[1].to_i64), JSON::Any.new(entry[2])]) }),
                   "exact_nominal_states" => JSON::Any.new(true)} of String => JSON::Any)
  end

  private def public_count_scan(part : String, type : CrystalClick::BinaryDataType, expected : Array(CrystalClick::BinaryValue), label : String) : JSON::Any
    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_COLUMN, COLUMN])
    actual = [] of CrystalClick::BinaryValue
    table.scan_typed(batch_rows: 2) do |batch|
      batch.aggregate_count_states_for(COLUMN, type).each { |value| actual << value }
    end
    require_equal_values!(actual, expected, "#{label} public Count scan", true)
    JSON::Any.new({"api" => JSON::Any.new("WidePartTable.scan_typed + aggregate_count_states_for"),
                   "rows" => JSON::Any.new(actual.size), "exact_nominal_count_states" => JSON::Any.new(true)} of String => JSON::Any)
  end

  private def offline_table_for(part : String, root : String, type_name : String, index : Int32) : CrystalClick::OfflineTable
    token = index.to_s(16).rjust(12, '0')
    db_uuid = "22300000-0000-4000-8000-#{token}"
    table_uuid = "22310000-0000-4000-8000-#{token}"
    catalog = File.join(root, "catalog-#{index}")
    raise ArgumentError.new("offline catalog destination already exists") if File.exists?(catalog) || File.symlink?(catalog)
    metadata = File.join(catalog, "metadata")
    db_store = File.join(catalog, "store", db_uuid[0, 3], db_uuid)
    table_store = File.join(catalog, "store", table_uuid[0, 3], table_uuid)
    [metadata, db_store, table_store].each { |path| FileUtils.mkdir_p(path) }
    File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{db_uuid}'\nENGINE = Atomic\n")
    File.write(File.join(db_store, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `v` #{type_name}\n)\nENGINE = MergeTree\nPRIMARY KEY pk\nORDER BY pk\n")
    File.write(File.join(table_store, "format_version.txt"), "1\n")
    FileUtils.mkdir_p(File.join(table_store, "detached"))
    FileUtils.cp_r(part, File.join(table_store, "all_1_1_0"))
    CrystalClick::OfflineCatalog.open(catalog)["lab"]["events"]
  end

  private def offline_sum_values(part : String, root : String, type : CrystalClick::BinaryDataType, expected : Array(CrystalClick::BinaryValue), index : Int32) : JSON::Any
    table = offline_table_for(part, root, type.name, index)
    actual = table[COLUMN].values.map(&.as(CrystalClick::BinaryValue))
    require_equal_values!(actual, expected, "offline AggregateFunction values")
    JSON::Any.new({"api" => JSON::Any.new("OfflineCatalog table column values"), "rows" => JSON::Any.new(actual.size),
                   "exact_nominal_states" => JSON::Any.new(true)} of String => JSON::Any)
  end

  private def offline_count_values(part : String, root : String, type : CrystalClick::BinaryDataType, expected : Array(CrystalClick::BinaryValue), index : Int32) : JSON::Any
    table = offline_table_for(part, root, type.name, index)
    actual = table[COLUMN].values.map(&.as(CrystalClick::BinaryValue))
    require_equal_values!(actual, expected, "offline Count values", true)
    JSON::Any.new({"api" => JSON::Any.new("OfflineCatalog table column values"), "rows" => JSON::Any.new(actual.size),
                   "exact_nominal_count_states" => JSON::Any.new(true)} of String => JSON::Any)
  end

  private def process_sum(profile : JSON::Any, root : String, index : Int32) : JSON::Any
    id = profile["id"].as_s
    argument_name = profile["argument_type"].as_s
    source_function = profile["source_function"].as_s
    expected_type_name = profile["declared_type"].as_s
    argument = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(argument_name) ||
               raise ArgumentError.new("W223 argument type is not canonical")
    type = CrystalClick::BinaryDataType.aggregate_function(source_function, argument)
    require!(type.name == expected_type_name, "#{id} aggregate factory canonical name differs")
    descriptor = type.aggregate_function_type || raise ArgumentError.new("#{id} aggregate descriptor is missing")
    require!(descriptor.function_name == profile["canonical_function"].as_s && descriptor.argument_type == argument && descriptor.version == 0_u8,
      "#{id} aggregate descriptor identity differs")

    expected = expected_sum_values(profile, type)
    require!(expected.size == 5 && expected.all? { |value| value.type == type }, "#{id} literal state roster differs")
    source_part = profile["source_part"].as_s
    library_part = profile["library_part"].as_s
    source_record = read_sum_part(source_part, type, expected, "stock/#{id}")
    source_public = public_sum_scan(source_part, type, expected, "stock/#{id}")
    marks = [expected[0, 2], expected[2, 2], expected[4, 1]]
    written = CrystalClick::WidePartWriter.write_uint64_and_aggregate_function_part(
      library_part, KEY_COLUMN, KEYS, COLUMN, type, marks, rows_per_mark: 2, frame_bytes: 64
    )
    require!(written == library_part && Dir.exists?(library_part), "#{id} paired writer did not publish exact destination")
    library_record = read_sum_part(written, type, expected, "library/#{id}")
    library_public = public_sum_scan(written, type, expected, "library/#{id}")
    offline = offline_sum_values(written, root, type, expected, index)
    require!(source_record["physical_stream_names"] == library_record["physical_stream_names"], "#{id} physical stream roster differs")
    JSON::Any.new({"id" => JSON::Any.new(id), "kind" => JSON::Any.new("sum"), "source_function" => JSON::Any.new(source_function),
                   "canonical_function" => JSON::Any.new(descriptor.function_name), "argument_type" => JSON::Any.new(argument.name),
                   "declared_type" => JSON::Any.new(type.name), "row_keys" => JSON::Any.new(ROW_KEYS.map { |key| JSON::Any.new(key.to_i64) }),
                   "mark_rows" => JSON::Any.new(MARK_ROWS.map { |rows| JSON::Any.new(rows.to_i64) }),
                   "classification" => JSON::Any.new("physical_observed"), "source_part_path" => JSON::Any.new(File.expand_path(source_part)),
                   "library_part_path" => JSON::Any.new(File.expand_path(written)), "source" => source_record, "source_public_scan" => source_public,
                   "library" => library_record, "library_public_scan" => library_public, "offline_values" => offline,
                   "literal_state_hex" => profile["state_hex"]} of String => JSON::Any)
  end

  private def process_count(profile : JSON::Any, root : String, index : Int32) : JSON::Any
    id = profile["id"].as_s
    type = CrystalClick::BinaryDataType.aggregate_count
    require!(type.name == profile["declared_type"].as_s, "Count compatibility declaration differs")
    expected = expected_count_values(profile, type)
    source_part = profile["source_part"].as_s
    library_part = profile["library_part"].as_s
    source_record = read_count_part(source_part, type, expected, "stock/#{id}")
    source_public = public_count_scan(source_part, type, expected, "stock/#{id}")
    value_states = Slice(CrystalClick::BinaryValue).new(expected.size) { |value_index| expected[value_index] }
    written = CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
      library_part, KEY_COLUMN, KEYS, COLUMN, type, value_states, rows_per_mark: 2
    )
    require!(written == library_part && Dir.exists?(library_part), "Count compatibility writer did not publish exact destination")
    library_record = read_count_part(written, type, expected, "library/#{id}")
    library_public = public_count_scan(written, type, expected, "library/#{id}")
    offline = offline_count_values(written, root, type, expected, index)
    JSON::Any.new({"id" => JSON::Any.new(id), "kind" => JSON::Any.new("count"), "canonical_function" => JSON::Any.new("count"),
                   "declared_type" => JSON::Any.new(type.name), "row_keys" => JSON::Any.new(ROW_KEYS.map { |key| JSON::Any.new(key.to_i64) }),
                   "mark_rows" => JSON::Any.new(MARK_ROWS.map { |rows| JSON::Any.new(rows.to_i64) }),
                   "classification" => JSON::Any.new("physical_observed"), "source_part_path" => JSON::Any.new(File.expand_path(source_part)),
                   "library_part_path" => JSON::Any.new(File.expand_path(written)), "source" => source_record, "source_public_scan" => source_public,
                   "library" => library_record, "library_public_scan" => library_public, "offline_values" => offline,
                   "counts" => profile["counts"], "literal_state_hex" => profile["state_hex"]} of String => JSON::Any)
  end

  private def validate_input!(input : JSON::Any, output_root : String, capture_root : String) : Array(JSON::Any)
    require!(input.as_h.keys.sort == ["capture_root", "format", "profiles"] && input["format"].as_s == FORMAT_INPUT,
      "helper input format differs")
    require!(input["capture_root"].as_s == capture_root, "capture root differs")
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "stock physical root is absent, symlinked, or noncanonical")
    require!(capture_root.starts_with?(ROOT_PREFIX) && File.dirname(capture_root) == "/private/tmp", "stock root escaped fixed prefix")
    profiles = input["profiles"].as_a
    require!(profiles.size >= 25 && profiles.size <= 64, "W223 physical roster is outside bounded 25..64 cases")
    ids = Set(String).new
    profiles.each do |profile|
      id = profile["id"].as_s
      require!(id.matches?(/\A[A-Za-z0-9_.-]+\z/) && !ids.includes?(id), "unsafe or duplicate W223 case id")
      ids << id
      require!(profile["row_keys"].as_a.map(&.as_i64) == ROW_KEYS.map(&.to_i64), "#{id} exact keys differ")
      require!(profile["mark_rows"].as_a.map(&.as_i64) == MARK_ROWS.map(&.to_i64), "#{id} real mark grid differs")
      source = File.expand_path(profile["source_part"].as_s)
      generated = File.expand_path(profile["library_part"].as_s)
      require!(source.starts_with?(capture_root + File::SEPARATOR) && Dir.exists?(source) && !File.symlink?(source) && File.realpath(source) == source, "#{id} source part escaped, symlinked, or absent")
      require!(generated.starts_with?(output_root + File::SEPARATOR) && !File.exists?(generated) && !File.symlink?(generated), "#{id} generated part exists or escaped")
      kind = profile["kind"].as_s
      if kind == "sum"
        expected_keys = %w[argument_type canonical_function declared_type id kind library_part mark_rows row_keys source_function source_part source_type state_hex]
        require!(profile.as_h.keys.sort == expected_keys.sort, "#{id} Sum fields differ from exact input contract")
        require!(profile["state_hex"].as_a.size == 5 && profile["source_type"].as_s == profile["declared_type"].as_s,
          "#{id} Sum raw states/declaration differ")
      elsif kind == "count"
        expected_keys = %w[counts declared_type id kind library_part mark_rows row_keys source_part source_type state_hex]
        require!(profile.as_h.keys.sort == expected_keys.sort, "#{id} Count fields differ from exact input contract")
        require!(profile["counts"].as_a.size == 5 && profile["counts"].as_a.all? { |count| count.as_s.matches?(/\A(?:0|[1-9][0-9]*)\z/) } && profile["state_hex"].as_a.size == 5 &&
                 profile["source_type"].as_s == profile["declared_type"].as_s, "#{id} Count literals/declaration differ")
      else
        raise ArgumentError.new("#{id} has an unlisted profile kind")
      end
    end
    profiles
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 3
      raise ArgumentError.new("usage: check_aggregate_sum_w223.cr INPUT.json OUTPUT_ROOT CAPTURE_ROOT")
    end
    input_path, output_root, capture_root = args.map { |path| File.expand_path(path) }
    require!(Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root,
      "generated root is not canonical")
    require!(File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR),
      "helper input is not a plain file under generated root")
    input = JSON.parse(File.read(input_path))
    profiles = validate_input!(input, output_root, capture_root)
    output_profiles = profiles.each_with_index.map do |profile, index|
      profile["kind"].as_s == "count" ? process_count(profile, output_root, index) : process_sum(profile, output_root, index)
    end.to_a
    output = JSON::Any.new({"format" => JSON::Any.new(FORMAT_OUTPUT), "profile_count" => JSON::Any.new(output_profiles.size),
                            "physical_observed" => JSON::Any.new(output_profiles.size), "mismatch_count" => JSON::Any.new(0),
                            "profiles" => JSON::Any.new(output_profiles)} of String => JSON::Any)
    puts output.to_json
  rescue ex : Exception
    STDERR.puts "W223 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckAggregateSumW223.main(ARGV)
