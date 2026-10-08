require "../src/crystal_click"
require "json"
require "file_utils"
require "set"

module CheckAggregateRecursiveW224
  extend self

  FORMAT_INPUT  = "aggregate_recursive_w224_input_v1"
  FORMAT_OUTPUT = "aggregate_recursive_w224_helper_v1"
  ROOT_PREFIX   = "/private/tmp/crystal-click-w224-physical."
  KEY_COLUMN    = "pk"
  COLUMN        = "v"
  ROW_KEYS      = [11_u64, 22_u64, 33_u64, 44_u64, 55_u64]
  MARK_ROWS     = [2_u64, 2_u64, 1_u64]
  PROFILE_IDS   = [
    "array_sum_uint8",
    "array_array_tuple_count_sum_empty_child_mark",
    "tuple_count_sum_string_single",
    "tuple_count_sum_string_with_size",
    "map_uint8_count",
    "map_uint8_sum_uint8",
    "nullable_tuple_count_sum",
    "nested_count_sum_flatten_nested_0",
    "tuple_count_low_cardinality_string",
  ]

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W224 recursive helper: #{message}") unless condition
  end

  private def decode_hex(hex : String) : Bytes
    unless hex.bytesize.even? && hex.matches?(/\A(?:[0-9a-f]{2})*\z/)
      raise ArgumentError.new("W224 literal bytes must be even lowercase hexadecimal")
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
    raise ArgumentError.new("W224 literal bytes are not lowercase hexadecimal")
  end

  private def encode_hex(bytes : Bytes) : String
    String.build { |io| bytes.each { |byte| io << byte.to_s(16).rjust(2, '0') } }
  end

  private def profile_for(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"
      CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("unlisted W224 String profile: #{name}")
    end
  end

  private def build_value(type : CrystalClick::BinaryDataType, spec : JSON::Any) : CrystalClick::BinaryValue
    kind = spec["kind"].as_s
    case kind
    when "count"
      CrystalClick::BinaryValue.aggregate_count_state(type, spec["value"].as_s.to_u64)
    when "state"
      CrystalClick::BinaryValue.aggregate_function_state(type, decode_hex(spec["hex"].as_s))
    when "fixed_u8"
      value = spec["value"].as_i64
      raise ArgumentError.new("W224 UInt8 key is outside range") unless 0 <= value && value <= 255
      CrystalClick::BinaryValue.fixed(type, Bytes[value.to_u8])
    when "string"
      CrystalClick::BinaryValue.string(spec["value"].as_s)
    when "array"
      values = spec["items"].as_a.map { |item| build_value(type.child_at(0), item) }
      CrystalClick::BinaryValue.array(type, values)
    when "nested"
      tuple_type = CrystalClick::BinaryNestedType.tuple_for(type)
      values = spec["rows"].as_a.map { |item| build_value(tuple_type, item) }
      CrystalClick::BinaryValue.nested(type, values)
    when "tuple"
      fields = spec["fields"].as_a
      require!(fields.size == type.child_count, "Tuple fixture field count differs")
      values = fields.each_with_index.map { |item, index| build_value(type.child_at(index), item) }.to_a
      CrystalClick::BinaryValue.tuple(type, values)
    when "map"
      flat = [] of CrystalClick::BinaryValue
      spec["entries"].as_a.each do |entry|
        flat << build_value(type.child_at(0), entry["key"])
        flat << build_value(type.child_at(1), entry["value"])
      end
      CrystalClick::BinaryValue.map(type, flat)
    when "nullable"
      if spec["null"].as_bool
        CrystalClick::BinaryValue.nullable(type)
      else
        CrystalClick::BinaryValue.nullable(type, build_value(type.child_at(0), spec["value"]))
      end
    when "low_cardinality"
      CrystalClick::BinaryValue.low_cardinality(type, build_value(type.child_at(0), spec["value"]))
    else
      raise ArgumentError.new("unlisted W224 value kind: #{kind}")
    end
  end

  private def same_value!(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue, path : String) : Nil
    require!(actual.type == expected.type, "#{path} nominal type differs: #{actual.type.name} != #{expected.type.name}")
    require!(actual.is_null? == expected.is_null?, "#{path} NULL marker differs")
    return if actual.is_null?

    if actual.type.aggregate_count_type
      require!(actual.count_state == expected.count_state, "#{path} Count state differs")
    elsif actual.type.tag == CrystalClick::BinaryDataType::TAG_AGGREGATE_FUNCTION
      require!(actual.aggregate_function_state_bytes == expected.aggregate_function_state_bytes, "#{path} opaque state bytes differ")
    else
      case actual.type.tag
      when CrystalClick::BinaryDataType::TAG_STRING
        require!(actual.as_string == expected.as_string, "#{path} String differs")
      when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY, CrystalClick::BinaryDataType::TAG_NULLABLE
        same_value!(actual.child_at(0), expected.child_at(0), "#{path}.child")
      when CrystalClick::BinaryDataType::TAG_ARRAY, CrystalClick::BinaryDataType::TAG_NESTED,
           CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE,
           CrystalClick::BinaryDataType::TAG_MAP
        require!(actual.element_count == expected.element_count, "#{path} child count differs")
        actual.element_count.times do |index|
          child_type = case actual.type.tag
                       when CrystalClick::BinaryDataType::TAG_ARRAY
                         actual.type.child_at(0)
                       when CrystalClick::BinaryDataType::TAG_NESTED
                         CrystalClick::BinaryNestedType.tuple_for(actual.type)
                       when CrystalClick::BinaryDataType::TAG_MAP
                         actual.type.child_at(index.even? ? 0 : 1)
                       else
                         actual.type.child_at(index)
                       end
          require!(actual.element_at(index).type == child_type, "#{path}[#{index}] child type differs")
          same_value!(actual.element_at(index), expected.element_at(index), "#{path}[#{index}]")
        end
      else
        require!(actual.bytes == expected.bytes, "#{path} raw bytes differ")
      end
    end
    nil
  end

  private def same_rows!(actual : Array(CrystalClick::BinaryValue), expected : Array(CrystalClick::BinaryValue), label : String) : Nil
    require!(actual.size == expected.size, "#{label} row count differs")
    actual.each_with_index { |value, index| same_value!(value, expected[index], "#{label}[#{index}]") }
    nil
  end

  private def fixture_values(type : CrystalClick::BinaryDataType, specs : Array(JSON::Any)) : Array(CrystalClick::BinaryValue)
    specs.map { |item| build_value(type, item) }
  end

  private def expected_lanes!(encoded : CrystalClick::BinaryBulkStreams, expected : JSON::Any, id : String) : JSON::Any
    map = expected.as_h
    roles = map.keys.sort
    require!(encoded.roles == roles, "#{id} independent lane role roster differs")
    records = [] of JSON::Any
    roles.each do |role|
      expected_lane = map[role]
      stream = encoded.stream(role)
      bytes_hex = encode_hex(stream.bytes)
      expected_hex = expected_lane["hex"].as_s
      offsets = stream.offsets.map(&.to_i64)
      expected_offsets = expected_lane["offsets"].as_a.map(&.as_i64)
      require!(bytes_hex == expected_hex, "#{id}/#{role} BinaryBulk bytes differ from independent Ruby literal encoder")
      require!(offsets == expected_offsets, "#{id}/#{role} BinaryBulk mark offsets differ from independent Ruby literal encoder")
      records << JSON::Any.new({"role" => JSON::Any.new(role), "hex" => JSON::Any.new(bytes_hex),
                                "offsets" => JSON::Any.new(offsets.map { |item| JSON::Any.new(item) })} of String => JSON::Any)
    end
    JSON::Any.new(records)
  end

  private def profile_name(profile : CrystalClick::BinaryBulkProfile) : String
    profile.with_size_stream? ? "with_size_stream" : "single_stream"
  end

  private def read_part(part : String, type : CrystalClick::BinaryDataType, expected : Array(CrystalClick::BinaryValue),
                        expected_lanes : JSON::Any, profile : CrystalClick::BinaryBulkProfile, label : String) : JSON::Any
    reader = CrystalClick::BinaryBulkColumnReader.open(part, COLUMN, type)
    require!(reader.schema_declaration == type.name && reader.source_declaration == type.name,
      "#{label} stored nominal declaration differs")
    require!(reader.mark_row_counts == MARK_ROWS, "#{label} mark grid differs")
    require!(reader.row_count == 5_u64 && reader.mark_count == 3, "#{label} parent row/mark axes differ")
    require!(reader.ordinary_profile == profile, "#{label} ordinary String profile differs")

    full = [] of CrystalClick::BinaryValue
    windows = [
      {"first_mark", 0, 1, 0, 2},
      {"middle_mark", 1, 1, 2, 2},
      {"final_short_mark", 2, 1, 4, 1},
    ]
    windows_json = [] of JSON::Any
    windows.each do |window|
      window_name, first_mark, mark_count, start_row, row_count = window
      selected = reader.read_marks(first_mark, mark_count)
      require!(selected.size == 1 && selected[0].size == row_count, "#{label} #{window_name} coordinate differs")
      expected_window = expected[start_row, row_count]
      same_rows!(selected[0], expected_window, "#{label}/#{window_name}")
      full.concat(selected[0])
      windows_json << JSON::Any.new({"name"       => JSON::Any.new(window_name),
                                     "first_mark" => JSON::Any.new(first_mark.to_i64),
                                     "mark_count" => JSON::Any.new(mark_count.to_i64),
                                     "row_count"  => JSON::Any.new(row_count.to_i64)} of String => JSON::Any)
    end
    same_rows!(full, expected, "#{label}/all_marks")
    require!(reader.read_marks(3, 0).empty?, "#{label} terminal zero-mark read is not empty")
    lanes = CrystalClick::BinaryBulkCodec.encode(type, [expected[0, 2], expected[2, 2], expected[4, 1]], profile: profile)
    lane_evidence = expected_lanes!(lanes, expected_lanes, label)

    JSON::Any.new({
      "schema_declaration"     => JSON::Any.new(reader.schema_declaration),
      "source_declaration"     => JSON::Any.new(reader.source_declaration),
      "ordinary_profile"       => JSON::Any.new(profile_name(reader.ordinary_profile)),
      "row_count"              => JSON::Any.new(reader.row_count.to_i64),
      "mark_row_counts"        => JSON::Any.new(reader.mark_row_counts.map { |item| JSON::Any.new(item.to_i64) }),
      "physical_stream_names"  => JSON::Any.new(reader.physical_stream_names.map { |name| JSON::Any.new(name) }),
      "windows"                => JSON::Any.new(windows_json),
      "terminal_empty_window"  => JSON::Any.new(true),
      "independent_lane_bytes" => lane_evidence,
      "exact_nominal_states"   => JSON::Any.new(true),
    } of String => JSON::Any)
  end

  private def public_scan(part : String, type : CrystalClick::BinaryDataType, expected : Array(CrystalClick::BinaryValue), label : String) : JSON::Any
    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_COLUMN, COLUMN])
    values = [] of CrystalClick::BinaryValue
    schedule = [] of Tuple(Int32, Int64, Int32)
    table.scan_typed(batch_rows: 2) do |batch|
      rows = batch.binary_bulk_values_for(COLUMN)
      rows.each do |value|
        require!(value.type == type, "#{label} public typed batch lost nominal descriptor")
        values << value
      end
      schedule << {batch.mark_index, batch.part_row_offset.to_i64, rows.size}
    end
    same_rows!(values, expected, "#{label}/public_scan")
    require!(schedule == [{0, 0_i64, 2}, {1, 2_i64, 2}, {2, 4_i64, 1}],
      "#{label} generic batch schedule differs")
    window = [] of CrystalClick::BinaryValue
    table.scan_typed_window(1_u64, 3) do |batch|
      batch.binary_bulk_values_for(COLUMN).each { |value| window << value }
    end
    same_rows!(window, expected[1, 3], "#{label}/public_window")
    schedule_json = schedule.map do |mark, offset, count|
      JSON::Any.new([JSON::Any.new(mark.to_i64), JSON::Any.new(offset), JSON::Any.new(count.to_i64)])
    end
    JSON::Any.new({"api" => JSON::Any.new("WidePartTable.open_selected_typed + scan_typed + scan_typed_window"),
                   "batch_schedule" => JSON::Any.new(schedule_json), "window_rows" => JSON::Any.new(window.size.to_i64),
                   "exact_nominal_states" => JSON::Any.new(true)} of String => JSON::Any)
  end

  private def offline_table_for(part : String, root : String, type_name : String, index : Int32) : CrystalClick::OfflineTable
    token = index.to_s(16).rjust(12, '0')
    db_uuid = "22400000-0000-4000-8000-#{token}"
    table_uuid = "22410000-0000-4000-8000-#{token}"
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

  private def offline_values(part : String, root : String, type : CrystalClick::BinaryDataType,
                             expected : Array(CrystalClick::BinaryValue), index : Int32, label : String) : JSON::Any
    table = offline_table_for(part, root, type.name, index)
    actual = table[COLUMN].values.map(&.as(CrystalClick::BinaryValue))
    same_rows!(actual, expected, "#{label}/offline_values")
    scanned = [] of CrystalClick::BinaryValue
    table.scan_typed([KEY_COLUMN, COLUMN], batch_rows: 2) do |batch|
      batch.binary_bulk_values_for(COLUMN).each { |value| scanned << value }
    end
    same_rows!(scanned, expected, "#{label}/offline_scan")
    window = [] of CrystalClick::BinaryValue
    table.scan_typed_window([KEY_COLUMN, COLUMN], 1_u64, 3) do |batch|
      batch.binary_bulk_values_for(COLUMN).each { |value| window << value }
    end
    same_rows!(window, expected[1, 3], "#{label}/offline_window")
    JSON::Any.new({"api" => JSON::Any.new("OfflineCatalog owned values + scan_typed + scan_typed_window"),
                   "rows" => JSON::Any.new(actual.size.to_i64), "window_rows" => JSON::Any.new(window.size.to_i64),
                   "exact_nominal_states" => JSON::Any.new(true)} of String => JSON::Any)
  end

  private def process_profile(profile : JSON::Any, output_root : String, capture_root : String, index : Int32) : JSON::Any
    id = profile["id"].as_s
    type_name = profile["declared_type"].as_s
    type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(type_name) ||
           raise ArgumentError.new("#{id} type name is not canonical")
    unless type.contains_aggregate_function?
      raise ArgumentError.new("#{id} does not contain a nominal AggregateFunction leaf")
    end
    CrystalClick::BinaryAggregateFunctionRecursiveAdmission.require_static_tree!(type)
    source_type_name = profile["source_type"].as_s
    source_type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(source_type_name) ||
                  raise ArgumentError.new("#{id} source type name is not canonical")
    unless source_type.contains_aggregate_function?
      raise ArgumentError.new("#{id} source type does not contain a nominal AggregateFunction leaf")
    end
    CrystalClick::BinaryAggregateFunctionRecursiveAdmission.require_static_tree!(source_type)
    bulk_profile = profile_for(profile["profile"].as_s)
    expected = fixture_values(type, profile["values"].as_a)
    source_expected = fixture_values(source_type, profile["source_values"].as_a)
    require!(expected.size == 5 && expected.all? { |value| value.type == type }, "#{id} expected value roster differs")
    require!(source_expected.size == 5 && source_expected.all? { |value| value.type == source_type }, "#{id} stock source value roster differs")

    source_part = File.expand_path(profile["source_part"].as_s)
    library_part = File.expand_path(profile["library_part"].as_s)
    read_source = read_part(source_part, source_type, source_expected, profile["source_expected_lanes"], bulk_profile, "stock/#{id}")
    source_public = public_scan(source_part, source_type, source_expected, "stock/#{id}")
    marks = [expected[0, 2], expected[2, 2], expected[4, 1]]
    written = CrystalClick::WidePartWriter.write_uint64_and_aggregate_function_part(
      library_part, KEY_COLUMN, ROW_KEYS.to_unsafe.to_slice(ROW_KEYS.size), COLUMN, type, marks,
      rows_per_mark: 2, profile: bulk_profile, frame_bytes: 64
    )
    require!(written == library_part && Dir.exists?(written) && !File.symlink?(written), "#{id} writer did not publish exact destination")
    read_library = read_part(written, type, expected, profile["expected_lanes"], bulk_profile, "library/#{id}")
    library_public = public_scan(written, type, expected, "library/#{id}")
    offline = offline_values(written, output_root, type, expected, index, "library/#{id}")
    same_stream_roles = read_source["physical_stream_names"] == read_library["physical_stream_names"]

    JSON::Any.new({
      "id" => JSON::Any.new(id), "classification" => JSON::Any.new("generic_stock_read_library_write_read_observed"),
      "declared_type" => JSON::Any.new(type.name), "source_type" => JSON::Any.new(source_type.name),
      "source_and_library_stream_roles_equal" => JSON::Any.new(same_stream_roles),
      "profile" => JSON::Any.new(profile["profile"].as_s),
      "row_keys" => JSON::Any.new(ROW_KEYS.map { |key| JSON::Any.new(key.to_i64) }),
      "mark_rows" => JSON::Any.new(MARK_ROWS.map { |rows| JSON::Any.new(rows.to_i64) }),
      "source_part_path" => JSON::Any.new(source_part), "library_part_path" => JSON::Any.new(written),
      "source" => read_source, "source_public_scan" => source_public,
      "library" => read_library, "library_public_scan" => library_public,
      "offline_values" => offline, "independent_values" => profile["values"],
      "source_independent_lanes" => profile["source_expected_lanes"],
      "independent_lanes" => profile["expected_lanes"],
    } of String => JSON::Any)
  end

  private def validate_input!(input : JSON::Any, output_root : String, capture_root : String) : Array(JSON::Any)
    require!(input.as_h.keys.sort == ["capture_root", "format", "profiles"] && input["format"].as_s == FORMAT_INPUT,
      "helper input format differs")
    require!(input["capture_root"].as_s == capture_root, "capture root differs")
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "stock capture root is absent, symlinked, or noncanonical")
    require!(capture_root.starts_with?(ROOT_PREFIX) && File.dirname(capture_root) == "/private/tmp", "stock capture root escaped the fixed prefix")
    profiles = input["profiles"].as_a
    require!(profiles.size == PROFILE_IDS.size, "W224 profile count differs")
    require!(profiles.map { |profile| profile["id"].as_s } == PROFILE_IDS, "W224 profile order differs")
    profiles.each do |profile|
      id = profile["id"].as_s
      keys = %w[declared_type expected_lanes id library_part mark_rows profile row_keys source_expected_lanes source_part source_type source_values values]
      require!(profile.as_h.keys.sort == keys, "#{id} helper input fields differ")
      require!(profile["row_keys"].as_a.map(&.as_i64) == ROW_KEYS.map(&.to_i64), "#{id} key roster differs")
      require!(profile["mark_rows"].as_a.map(&.as_i64) == MARK_ROWS.map(&.to_i64), "#{id} mark grid differs")
      require!(profile["values"].as_a.size == 5 && profile["source_values"].as_a.size == 5, "#{id} value count differs")
      source_type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(profile["source_type"].as_s) ||
                    raise ArgumentError.new("#{id} source type name is not canonical")
      CrystalClick::BinaryAggregateFunctionRecursiveAdmission.require_static_tree!(source_type)
      profile_for(profile["profile"].as_s)
      source = File.expand_path(profile["source_part"].as_s)
      generated = File.expand_path(profile["library_part"].as_s)
      require!(source.starts_with?(capture_root + File::SEPARATOR) && Dir.exists?(source) && !File.symlink?(source) && File.realpath(source) == source,
        "#{id} source part escaped, symlinked, or absent")
      require!(generated.starts_with?(output_root + File::SEPARATOR) && !File.exists?(generated) && !File.symlink?(generated),
        "#{id} library destination exists or escaped")
      profile["expected_lanes"].as_h.each do |role, lane|
        require!(role.matches?(/\A[A-Za-z0-9_.-]+\z/) && lane.as_h.keys.sort == ["hex", "offsets"], "#{id} lane contract differs")
        decode_hex(lane["hex"].as_s)
        offsets = lane["offsets"].as_a.map(&.as_i64)
        require!(offsets.size == 4 && offsets[0] >= 0 && offsets.each_cons(2).all? { |pair| pair[0] <= pair[1] },
          "#{id}/#{role} expected offset grid is invalid")
      end
      profile["source_expected_lanes"].as_h.each do |role, lane|
        require!(role.matches?(/\A[A-Za-z0-9_.-]+\z/) && lane.as_h.keys.sort == ["hex", "offsets"], "#{id} source lane contract differs")
        decode_hex(lane["hex"].as_s)
        offsets = lane["offsets"].as_a.map(&.as_i64)
        require!(offsets.size == 4 && offsets[0] >= 0 && offsets.each_cons(2).all? { |pair| pair[0] <= pair[1] },
          "#{id}/#{role} source expected offset grid is invalid")
      end
    end
    profiles
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 3
      raise ArgumentError.new("usage: check_aggregate_recursive_w224.cr INPUT.json OUTPUT_ROOT CAPTURE_ROOT")
    end
    input_path, output_root, capture_root = args.map { |path| File.expand_path(path) }
    require!(Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root,
      "generated root is not canonical")
    require!(File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR),
      "helper input is not a plain file under generated root")
    input = JSON.parse(File.read(input_path))
    profiles = validate_input!(input, output_root, capture_root)
    results = profiles.each_with_index.map { |profile, index| process_profile(profile, output_root, capture_root, index) }.to_a
    output = JSON::Any.new({
      "format" => JSON::Any.new(FORMAT_OUTPUT), "profile_count" => JSON::Any.new(results.size.to_i64),
      "observed_count" => JSON::Any.new(results.size.to_i64), "mismatch_count" => JSON::Any.new(0_i64),
      "profiles" => JSON::Any.new(results),
    } of String => JSON::Any)
    puts output.to_json
  rescue ex : Exception
    STDERR.puts "W224 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckAggregateRecursiveW224.main(ARGV)
