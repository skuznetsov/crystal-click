require "../src/crystal_click"
require "json"
require "file_utils"
require "./support/dynamic_owned_values_w220"

module CheckAggregateDynamicW226
  extend self

  FORMAT_INPUT       = "aggregate_dynamic_w226_input_v1"
  FORMAT_OUTPUT      = "aggregate_dynamic_w226_helper_v1"
  SOURCE_ROOT_PREFIX = "crystal-click-w226-native"
  KEY_COLUMN         = "pk"
  COLUMN             = "v"
  ROW_KEYS           = [11_u64, 22_u64, 33_u64, 44_u64, 55_u64]
  MARK_ROWS          = [2_u64, 2_u64, 1_u64]
  CASE_IDS           = [
    "known_count_shared_sum",
    "all_shared",
    "actual_array_sum",
    "outer_array_dynamic",
  ]
  PROFILE_NAMES = ["single_stream", "with_size_stream"]
  CHECKS        = [
    "source_full",
    "source_middle",
    "source_zero",
    "library_full",
    "library_middle",
    "library_zero",
    "typed_scan_callbacks",
    "generic_scan_values",
    "window_middle",
    "window_eof",
    "owned_values",
    "rowbinary_full",
    "rowbinary_middle",
    "rowbinary_zero",
    "pqr_schedule",
    "source_roster_placement_expectation",
  ]

  alias Fixture = NamedTuple(
    case_id: String,
    type: CrystalClick::BinaryDataType,
    structures: Hash(String, CrystalClick::DynamicStructure),
    marks: Array(Array(CrystalClick::BinaryValue)),
  )

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W226 Dynamic helper: #{message}") unless condition
  end

  private def sum_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.aggregate_function(
      "sum",
      CrystalClick::BinaryDataType.primitive("UInt8"),
    )
  end

  private def u64_le(value : UInt64) : Bytes
    Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end

  private def count_value(type : CrystalClick::BinaryDataType, value : UInt64) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.aggregate_count_state(type, value)
  end

  private def sum_value(type : CrystalClick::BinaryDataType, value : UInt64) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.aggregate_function_state(type, u64_le(value))
  end

  private def split_marks(rows : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
    [rows[0, 2], rows[2, 2], rows[4, 1]]
  end

  private def fixture(case_id : String) : Fixture
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: case_id == "all_shared" ? 0 : 1)
    count = CrystalClick::BinaryDataType.aggregate_count
    sum = sum_type
    array_sum = CrystalClick::BinaryDataType.array(sum)
    dynamic_value = ->(child : CrystalClick::BinaryValue?) {
      CrystalClick::BinaryValue.dynamic(dynamic, child)
    }
    dynamic_count = ->(value : UInt64) { dynamic_value.call(count_value(count, value)) }
    dynamic_sum = ->(value : UInt64) { dynamic_value.call(sum_value(sum, value)) }
    empty_dynamic = -> { dynamic_value.call(nil) }
    array_sum_dynamic = ->(values : Array(CrystalClick::BinaryValue)) {
      dynamic_value.call(CrystalClick::BinaryValue.array(array_sum, values))
    }

    case case_id
    when "known_count_shared_sum"
      rows = [
        dynamic_count.call(1_u64),
        dynamic_sum.call(256_u64),
        empty_dynamic.call,
        dynamic_count.call(UInt64::MAX),
        dynamic_count.call(0_u64),
      ] of CrystalClick::BinaryValue
      {
        case_id:    case_id,
        type:       dynamic,
        structures: {"root" => CrystalClick::DynamicStructure.new([count] of CrystalClick::BinaryDataType)},
        marks:      split_marks(rows),
      }
    when "all_shared"
      rows = [
        dynamic_count.call(1_u64),
        dynamic_sum.call(256_u64),
        empty_dynamic.call,
        dynamic_count.call(UInt64::MAX),
        dynamic_count.call(0_u64),
      ] of CrystalClick::BinaryValue
      {
        case_id:    case_id,
        type:       dynamic,
        structures: {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
        marks:      split_marks(rows),
      }
    when "actual_array_sum"
      rows = [
        array_sum_dynamic.call([] of CrystalClick::BinaryValue),
        dynamic_count.call(256_u64),
        empty_dynamic.call,
        array_sum_dynamic.call([sum_value(sum, 7_u64), sum_value(sum, 17_u64)] of CrystalClick::BinaryValue),
        array_sum_dynamic.call([sum_value(sum, 0_u64)] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue
      {
        case_id:    case_id,
        type:       dynamic,
        structures: {"root" => CrystalClick::DynamicStructure.new([array_sum] of CrystalClick::BinaryDataType)},
        marks:      split_marks(rows),
      }
    when "outer_array_dynamic"
      outer_type = CrystalClick::BinaryDataType.array(dynamic)
      outer_row = ->(values : Array(CrystalClick::BinaryValue)) {
        CrystalClick::BinaryValue.array(outer_type, values)
      }
      rows = [
        outer_row.call([] of CrystalClick::BinaryValue),
        outer_row.call([] of CrystalClick::BinaryValue),
        outer_row.call([
          dynamic_count.call(1_u64),
          dynamic_sum.call(256_u64),
          empty_dynamic.call,
        ] of CrystalClick::BinaryValue),
        outer_row.call([dynamic_count.call(256_u64)] of CrystalClick::BinaryValue),
        outer_row.call([dynamic_sum.call(0_u64), dynamic_count.call(UInt64::MAX)] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue
      {
        case_id:    case_id,
        type:       outer_type,
        structures: {
          "root.elements" => CrystalClick::DynamicStructure.new([count] of CrystalClick::BinaryDataType),
        },
        marks: split_marks(rows),
      }
    else
      raise ArgumentError.new("W226 case is outside the exact four-case roster")
    end
  end

  private def profile_for(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"
      CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("unlisted W226 ordinary String profile: #{name}")
    end
  end

  private def expected_ids : Array(String)
    CASE_IDS.flat_map do |case_id|
      PROFILE_NAMES.map { |profile| "#{case_id}_#{profile}" }
    end
  end

  private def expected_id(case_id : String, profile : String) : String
    "#{case_id}_#{profile}"
  end

  private def flatten(marks : Array(Array(CrystalClick::BinaryValue))) : Array(CrystalClick::BinaryValue)
    values = [] of CrystalClick::BinaryValue
    marks.each { |mark| values.concat(mark) }
    values
  end

  private def equal_values!(actual : Array(CrystalClick::BinaryValue), expected : Array(CrystalClick::BinaryValue), label : String) : Nil
    require!(actual.size == expected.size, "#{label} value count differs")
    actual.each_with_index do |value, index|
      fixture_value = expected[index]
      require!(
        value.type == fixture_value.type &&
        CrystalClick::BinaryValueCodec.encode(value) == CrystalClick::BinaryValueCodec.encode(fixture_value),
        "#{label} exact nominal value differs at row #{index}",
      )
    end
  end

  private def equal_marks!(actual : Array(Array(CrystalClick::BinaryValue)), expected : Array(Array(CrystalClick::BinaryValue)), label : String) : Nil
    require!(actual.size == expected.size, "#{label} mark count differs")
    actual.each_with_index do |mark, mark_index|
      equal_values!(mark, expected[mark_index], "#{label} mark #{mark_index}")
    end
  end

  private def rowbinary(values : Array(CrystalClick::BinaryValue)) : Bytes
    encoded = values.map { |value| CrystalClick::BinaryValueCodec.encode_value(value) }
    byte_count = 0
    encoded.each { |item| byte_count += item.size }
    result = Bytes.new(byte_count)
    offset = 0
    encoded.each do |item|
      item.each do |byte|
        result[offset] = byte
        offset += 1
      end
    end
    result
  end

  private def encode_hex(bytes : Bytes) : String
    String.build { |io| bytes.each { |byte| io << byte.to_s(16).rjust(2, '0') } }
  end

  private def nibble(byte : UInt8) : UInt8
    if byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
      return (byte - '0'.ord.to_u8).to_u8
    end
    if byte >= 'a'.ord.to_u8 && byte <= 'f'.ord.to_u8
      return (byte - 'a'.ord.to_u8 + 10).to_u8
    end
    raise ArgumentError.new("W226 literal bytes must be lowercase hexadecimal")
  end

  private def decode_hex(hex : String) : Bytes
    unless hex.bytesize.even? && hex.matches?(/\A(?:[0-9a-f]{2})*\z/)
      raise ArgumentError.new("W226 literal bytes must be even lowercase hexadecimal")
    end
    Bytes.new(hex.bytesize // 2) do |index|
      ((nibble(hex.byte_at(index * 2)) << 4) | nibble(hex.byte_at(index * 2 + 1))).to_u8
    end
  end

  private def parse_type_name(name : String) : CrystalClick::BinaryDataType
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(name) ||
      raise ArgumentError.new("W226 source roster contains a noncanonical descriptor")
  end

  private def expected_source_types(case_id : String) : Hash(String, Array(CrystalClick::BinaryDataType))
    count = CrystalClick::BinaryDataType.aggregate_count
    array_sum = CrystalClick::BinaryDataType.array(sum_type)
    case case_id
    when "known_count_shared_sum"
      {"root" => [count] of CrystalClick::BinaryDataType}
    when "all_shared"
      {"root" => [] of CrystalClick::BinaryDataType}
    when "actual_array_sum"
      {"root" => [array_sum] of CrystalClick::BinaryDataType}
    when "outer_array_dynamic"
      {"root.elements" => [count] of CrystalClick::BinaryDataType}
    else
      raise ArgumentError.new("W226 source roster case is outside the finite plan")
    end
  end

  private def parse_source_types(item : JSON::Any, case_id : String) : Hash(String, CrystalClick::DynamicStructure)
    expected = expected_source_types(case_id)
    source_types = item["source_types"].as_h
    require!(source_types.keys.sort == expected.keys.sort, "#{case_id} source Dynamic sites differ")
    structures = Hash(String, CrystalClick::DynamicStructure).new
    source_types.each do |site, roster_any|
      roster = roster_any.as_a.map { |entry| parse_type_name(entry.as_s) }
      expected_roster = expected[site]
      require!(roster == expected_roster, "#{case_id} source ordinary roster differs at #{site}")
      require!(roster.map(&.name) == roster.map(&.name).sort, "#{case_id} source ordinary roster is not canonical order")
      structures[site] = CrystalClick::DynamicStructure.new(roster)
    end
    structures
  end

  private def dynamic_occurrences(value : CrystalClick::BinaryValue, type : CrystalClick::BinaryDataType) : Array(CrystalClick::BinaryValue)
    if type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC
      [value]
    elsif type.tag == CrystalClick::BinaryDataType::TAG_ARRAY && type.child_at(0).tag == CrystalClick::BinaryDataType::TAG_DYNAMIC
      value.elements
    else
      raise ArgumentError.new("W226 P/Q/R fixture has an unlisted Dynamic shape")
    end
  end

  private def shared_grid(
    marks : Array(Array(CrystalClick::BinaryValue)),
    type : CrystalClick::BinaryDataType,
    structures : Hash(String, CrystalClick::DynamicStructure),
  ) : Array(Array(Bool?))
    roster = structures[type.tag == CrystalClick::BinaryDataType::TAG_ARRAY ? "root.elements" : "root"]
    rows = [] of Array(Bool?)
    flatten(marks).each do |parent|
      flags = [] of Bool?
      dynamic_occurrences(parent, type).each do |occurrence|
        if occurrence.child_count == 0
          flags << nil
        else
          actual_type = occurrence.child_at(0).type
          flags << !roster.types.includes?(actual_type)
        end
      end
      rows << flags
    end
    rows
  end

  private def parse_shared_grid_for_site(item : JSON::Any, site : String) : Array(Array(Bool?))
    grid = item.as_h
    require!(grid.keys == [site], "source shared grid has an unexpected site path")
    grid[site].as_a.map do |row_any|
      row_any.as_a.map do |flag|
        flag.raw.nil? ? nil : flag.as_bool
      end
    end
  end

  private def expected_rowbinary(item : JSON::Any, fixture : Fixture) : Hash(String, Bytes)
    hex = item["expected_rowbinary_hex"].as_h
    require!(hex.keys.sort == ["full", "middle", "zero"], "#{fixture[:case_id]} RowBinary body roster differs")
    expected_values = flatten(fixture[:marks])
    actual = {
      "full"   => rowbinary(expected_values),
      "middle" => rowbinary(expected_values[2, 2]),
      "zero"   => Bytes.empty,
    }
    actual.each do |name, bytes|
      supplied = decode_hex(hex[name].as_s)
      require!(supplied == bytes, "#{fixture[:case_id]} independent #{name} value-body literal differs")
    end
    actual
  end

  private def part_read(
    part_path : String,
    fixture : Fixture,
    source_structures : Hash(String, CrystalClick::DynamicStructure),
    profile : CrystalClick::BinaryBulkProfile,
    expected_bodies : Hash(String, Bytes),
    label : String,
  ) : NamedTuple(reader: CrystalClick::DynamicBulkColumnReader, marks: Array(Array(CrystalClick::BinaryValue)))
    reader = CrystalClick::DynamicBulkColumnReader.open(part_path, COLUMN, fixture[:type])
    require!(reader.schema_declaration == fixture[:type].name, "#{label} schema descriptor differs")
    require!(reader.row_count == ROW_KEYS.size.to_u64 && reader.mark_row_counts == MARK_ROWS, "#{label} axes or P marks differ")
    require!(reader.ordinary_profile == profile, "#{label} ordinary String profile differs")

    plan = CrystalClick::BinaryDynamicBulkPlan.new(fixture[:type], source_structures, profile)
    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, COLUMN)
    planned_streams = physical.stream_names.values.sort!
    actual_streams = reader.physical_stream_names.sort!
    require!(actual_streams == planned_streams, "#{label} physical streams do not match its exact source roster")

    full_marks = reader.read_marks(0, MARK_ROWS.size)
    equal_marks!(full_marks, fixture[:marks], "#{label} full")
    middle = reader.read_marks(1, 1)
    equal_marks!(middle, [fixture[:marks][1]], "#{label} middle")
    zero = reader.read_marks(MARK_ROWS.size, 0)
    require!(zero.empty?, "#{label} EOF zero-mark read is not empty")

    values = flatten(full_marks)
    require!(encode_hex(rowbinary(values)) == encode_hex(expected_bodies["full"]), "#{label} full value-body bytes differ")
    require!(encode_hex(rowbinary(flatten(middle))) == encode_hex(expected_bodies["middle"]), "#{label} middle value-body bytes differ")
    require!(encode_hex(rowbinary([] of CrystalClick::BinaryValue)) == encode_hex(expected_bodies["zero"]), "#{label} zero value-body bytes differ")
    {reader: reader, marks: full_marks}
  end

  private def logical_roles(plan : CrystalClick::BinaryDynamicBulkPlan) : JSON::Any
    ordinary = {} of String => JSON::Any
    plan.site_paths.each do |site|
      ordinary[site] = JSON::Any.new(plan.structure_for(site).types.map { |type| JSON::Any.new(type.name) })
    end
    JSON::Any.new({
      "ordinary" => JSON::Any.new(ordinary),
    } of String => JSON::Any)
  end

  private def stream_names(names : Array(String)) : JSON::Any
    JSON::Any.new(names.sort!.map { |name| JSON::Any.new(name) })
  end

  private def value_signatures(values : Array(CrystalClick::BinaryValue)) : Array(JSON::Any)
    values.map do |value|
      signature = "#{value.type.name}|#{encode_hex(CrystalClick::BinaryValueCodec.encode(value))}"
      JSON::Any.new(signature)
    end
  end

  private def pqr_schedule(fixture : Fixture, values : Array(CrystalClick::BinaryValue)) : JSON::Any
    q = [] of UInt64
    r = [] of UInt64
    values.each do |parent|
      occurrences = dynamic_occurrences(parent, fixture[:type])
      q << occurrences.size.to_u64
      r << occurrences.count { |occurrence| occurrence.child_count > 0 }.to_u64
    end
    expected_q = fixture[:case_id] == "outer_array_dynamic" ? [0_u64, 0_u64, 3_u64, 1_u64, 2_u64] : [1_u64, 1_u64, 1_u64, 1_u64, 1_u64]
    expected_r = fixture[:case_id] == "outer_array_dynamic" ? [0_u64, 0_u64, 2_u64, 1_u64, 2_u64] : [1_u64, 1_u64, 0_u64, 1_u64, 1_u64]
    require!(q == expected_q && r == expected_r, "P/Q/R occurrence schedule differs from the finite fixture")
    q_by_mark = [] of UInt64
    r_by_mark = [] of UInt64
    offset = 0
    MARK_ROWS.each do |rows|
      count = rows.to_i
      q_by_mark << q[offset, count].sum(0_u64)
      r_by_mark << r[offset, count].sum(0_u64)
      offset += count
    end
    JSON::Any.new({
      "parent_mark_rows"                        => JSON::Any.new(MARK_ROWS.map { |rows| JSON::Any.new(rows.to_i64) }),
      "dynamic_values_by_parent_row"            => JSON::Any.new(q.map { |rows| JSON::Any.new(rows.to_i64) }),
      "selected_non_null_actuals_by_parent_row" => JSON::Any.new(r.map { |rows| JSON::Any.new(rows.to_i64) }),
      "dynamic_values_by_mark"                  => JSON::Any.new(q_by_mark.map { |rows| JSON::Any.new(rows.to_i64) }),
      "selected_non_null_actuals_by_mark"       => JSON::Any.new(r_by_mark.map { |rows| JSON::Any.new(rows.to_i64) }),
    } of String => JSON::Any)
  end

  private def public_consumers!(part_path : String, fixture : Fixture) : Tuple(Int32, Array(CrystalClick::BinaryValue))
    table = CrystalClick::WidePartTable.open_selected_typed([part_path], [KEY_COLUMN, COLUMN])
    callback_count = 0
    generic_values = [] of CrystalClick::BinaryValue
    schedule = [] of Tuple(Int32, UInt64, Int32)
    table.scan_typed(batch_rows: 2) do |batch|
      callback_count += 1
      dynamic_values = batch.dynamic_bulk_values_for(COLUMN).to_a
      binary_values = batch.binary_bulk_values_for(COLUMN).to_a
      equal_values!(dynamic_values, binary_values, "public generic versus Dynamic accessor")
      generic_values.concat(binary_values)
      schedule << {batch.mark_index, batch.part_row_offset, binary_values.size}
    end
    require!(callback_count == 3, "typed Dynamic scan did not publish exactly three P callbacks")
    require!(schedule == [{0_i32, 0_u64, 2_i32}, {1_i32, 2_u64, 2_i32}, {2_i32, 4_u64, 1_i32}], "typed callback P schedule differs")
    equal_values!(generic_values, flatten(fixture[:marks]), "public generic scan values")

    windowed = [] of CrystalClick::BinaryValue
    window_callbacks = 0
    table.scan_typed_window(2_u64, max_rows: 2) do |batch|
      window_callbacks += 1
      windowed.concat(batch.dynamic_bulk_values_for(COLUMN))
    end
    require!(window_callbacks == 1, "middle Dynamic window did not publish one callback")
    equal_values!(windowed, fixture[:marks][1], "middle Dynamic window")

    eof_callbacks = 0
    table.scan_typed_window(5_u64, max_rows: 2) { |_batch| eof_callbacks += 1 }
    require!(eof_callbacks == 0, "EOF Dynamic window emitted a callback")
    {callback_count, generic_values}
  end

  private def validate_input!(
    input : JSON::Any,
    input_path : String,
    output_root : String,
    source_root : String,
  ) : Array(JSON::Any)
    require!(input.as_h.keys.sort == ["format", "profiles"] && input["format"].as_s == FORMAT_INPUT, "helper input contract differs")
    require!(Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root, "generated root is absent, symlinked, or noncanonical")
    require!(File.file?(input_path) && !File.symlink?(input_path) && File.realpath(input_path) == input_path &&
             input_path.starts_with?(output_root + File::SEPARATOR), "helper input is not a canonical plain file under generated root")
    require!(Dir.exists?(source_root) && !File.symlink?(source_root) && File.realpath(source_root) == source_root, "stock source root is absent, symlinked, or noncanonical")
    require!(File.dirname(source_root) == "/private/tmp" && File.basename(source_root).starts_with?(SOURCE_ROOT_PREFIX), "stock source root escaped its bounded W226 prefix")

    profiles = input["profiles"].as_a
    ids = expected_ids
    require!(profiles.size == ids.size, "profile count differs from the exact eight-profile roster")
    profiles.each_with_index do |item, index|
      require!(item.as_h.keys.sort == %w[case_id declared_type destination_path expected_rowbinary_hex id profile source_part_path source_shared source_types].sort,
        "W226 profile input fields differ")
      case_id = item["case_id"].as_s
      profile_name = item["profile"].as_s
      id = item["id"].as_s
      require!(id == ids[index] && id == expected_id(case_id, profile_name), "profile ID/order differs from the exact roster")
      require!(CASE_IDS.includes?(case_id) && PROFILE_NAMES.includes?(profile_name), "profile case or String profile is unlisted")

      expected_fixture = fixture(case_id)
      require!(item["declared_type"].as_s == expected_fixture[:type].name, "#{id} declared type differs from the finite fixture")
      source_part = File.expand_path(item["source_part_path"].as_s)
      destination = File.expand_path(item["destination_path"].as_s)
      require!(source_part.starts_with?(source_root + File::SEPARATOR) && Dir.exists?(source_part) && !File.symlink?(source_part) && File.realpath(source_part) == source_part,
        "#{id} stock part escaped, is symlinked, or is absent")
      require!(destination.starts_with?(output_root + File::SEPARATOR) && !File.exists?(destination) && !File.symlink?(destination),
        "#{id} library destination exists or escaped generated root")
      require!(Dir.exists?(File.dirname(destination)) && File.realpath(File.dirname(destination)) == File.dirname(destination),
        "#{id} destination parent is absent, symlinked, or noncanonical")
      parse_source_types(item, case_id)
      expected_rowbinary(item, expected_fixture)
    end
    profiles
  end

  private def process_profile(item : JSON::Any, output_root : String) : JSON::Any
    id = item["id"].as_s
    case_id = item["case_id"].as_s
    profile_name = item["profile"].as_s
    fixture_value = fixture(case_id)
    profile = profile_for(profile_name)
    source_part = File.expand_path(item["source_part_path"].as_s)
    destination = File.expand_path(item["destination_path"].as_s)
    source_structures = parse_source_types(item, case_id)
    source_sites = source_structures.keys.sort!
    expected_bodies = expected_rowbinary(item, fixture_value)

    stock = part_read(source_part, fixture_value, source_structures, profile, expected_bodies, "stock/#{id}")
    # The raw native audit supplies source_shared. This check only verifies
    # that those independently captured flags satisfy the finite law implied
    # by the native roster and the values read back from the stock part.
    expected_flags = shared_grid(stock[:marks], fixture_value[:type], source_structures)
    supplied_flags = parse_shared_grid_for_site(item["source_shared"], source_sites[0])
    require!(supplied_flags == expected_flags, "#{id} source shared/ordinary placement expectation differs from native flags and stock values")
    library_plan = CrystalClick::BinaryDynamicBulkPlan.new(fixture_value[:type], fixture_value[:structures], profile)
    library_physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(library_plan, COLUMN)
    written = CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
      destination,
      KEY_COLUMN,
      Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64],
      COLUMN,
      fixture_value[:type],
      fixture_value[:structures],
      fixture_value[:marks],
      rows_per_mark: 2,
      profile: profile,
    )
    require!(written == destination && Dir.exists?(written) && !File.symlink?(written), "#{id} Dynamic writer did not publish the exact destination")
    library = part_read(written, fixture_value, fixture_value[:structures], profile, expected_bodies, "library/#{id}")
    require!(stock[:reader].physical_stream_names.sort! == library[:reader].physical_stream_names.sort!, "#{id} stock/library physical stream rosters differ")

    callback_count, generic_values = public_consumers!(written, fixture_value)
    require!(callback_count == 3, "#{id} typed callback count differs")
    qrs = pqr_schedule(fixture_value, flatten(library[:marks]))
    owned = CrystalClick::DynamicOwnedValuesW220.materialize(
      written,
      COLUMN,
      fixture_value[:type],
      5_u64,
      MARK_ROWS,
      fixture_value[:marks],
      library[:marks],
    )
    require!(owned.mark_row_counts == MARK_ROWS, "#{id} W220 owned mark counts differ")
    owned_values = flatten(owned.values_by_mark)
    equal_values!(owned_values, flatten(fixture_value[:marks]), "#{id} owned W220 values")
    equal_values!(generic_values, owned_values, "#{id} generic scan versus owned values")

    stock_plan = CrystalClick::BinaryDynamicBulkPlan.new(fixture_value[:type], source_structures, profile)
    checks = CHECKS.map { |check| JSON::Any.new(check) }
    stock_streams = stock[:reader].physical_stream_names
    library_streams = library[:reader].physical_stream_names
    JSON::Any.new({
      "id"         => JSON::Any.new(id),
      "case_id"    => JSON::Any.new(case_id),
      "profile"    => JSON::Any.new(profile_name),
      "type"       => JSON::Any.new(fixture_value[:type].name),
      "stock_part" => JSON::Any.new({
        "path"                 => JSON::Any.new(source_part),
        "full_rowbinary_hex"   => JSON::Any.new(encode_hex(expected_bodies["full"])),
        "middle_rowbinary_hex" => JSON::Any.new(encode_hex(expected_bodies["middle"])),
        "zero_rowbinary_hex"   => JSON::Any.new(encode_hex(expected_bodies["zero"])),
      } of String => JSON::Any),
      "library_part" => JSON::Any.new({
        "path"                 => JSON::Any.new(written),
        "full_rowbinary_hex"   => JSON::Any.new(encode_hex(expected_bodies["full"])),
        "middle_rowbinary_hex" => JSON::Any.new(encode_hex(expected_bodies["middle"])),
        "zero_rowbinary_hex"   => JSON::Any.new(encode_hex(expected_bodies["zero"])),
      } of String => JSON::Any),
      "checks"          => JSON::Any.new(checks),
      "physicalstreams" => JSON::Any.new({
        "stock"   => stream_names(stock_streams),
        "library" => stream_names(library_streams),
      } of String => JSON::Any),
      "logicalroles" => JSON::Any.new({
        "stock"   => logical_roles(stock_plan),
        "library" => logical_roles(library_plan),
      } of String => JSON::Any),
      "mark_rows"        => JSON::Any.new(MARK_ROWS.map { |rows| JSON::Any.new(rows.to_i64) }),
      "owned_signatures" => JSON::Any.new(value_signatures(owned_values)),
      "pqr"              => qrs,
    } of String => JSON::Any)
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 3
      raise ArgumentError.new("usage: check_aggregate_dynamic_w226.cr INPUT.json OUTPUT_ROOT CAPTURE_ROOT")
    end
    input_path, output_root, source_root = args.map { |path| File.expand_path(path) }
    input = JSON.parse(File.read(input_path))
    profiles = validate_input!(input, input_path, output_root, source_root)
    output_profiles = profiles.map { |item| process_profile(item, output_root) }
    output = JSON::Any.new({
      "format"   => JSON::Any.new(FORMAT_OUTPUT),
      "profiles" => JSON::Any.new(output_profiles),
    } of String => JSON::Any)
    puts output.to_json
  rescue ex : Exception
    STDERR.puts "W226 Dynamic helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckAggregateDynamicW226.main(ARGV)
