require "../src/crystal_click"
require "json"
require "file_utils"

module CheckAggregateVariantW225
  extend self

  FORMAT_INPUT  = "aggregate_variant_w225_helper_v1"
  FORMAT_OUTPUT = "aggregate_variant_w225_helper_output_v1"
  SOURCE_PREFIX = "/private/tmp/crystal-click-w225-physical."
  KEY_COLUMN    = "pk"
  COLUMN        = "v"
  ROW_KEYS      = [11_u64, 22_u64, 33_u64, 44_u64, 55_u64]
  MARK_ROWS     = [2_u64, 2_u64, 1_u64]
  PROFILE_IDS   = [
    "root_variant_single",
    "root_variant_with_size",
    "root_variant_null_unused_string",
    "root_variant_null_unused_sum",
    "array_variant",
    "variant_array_sum",
    "variant_tuple",
  ]
  PROFILE_TYPES = {
    "root_variant_single"             => "Variant(AggregateFunction(count), AggregateFunction(sum, UInt8), String)",
    "root_variant_with_size"          => "Variant(AggregateFunction(count), AggregateFunction(sum, UInt8), String)",
    "array_variant"                   => "Array(Variant(AggregateFunction(count), AggregateFunction(sum, UInt8), String))",
    "variant_array_sum"               => "Variant(Array(AggregateFunction(sum, UInt8)), String)",
    "variant_tuple"                   => "Variant(String, Tuple(AggregateFunction(count), AggregateFunction(sum, UInt8)))",
    "root_variant_null_unused_string" => "Variant(AggregateFunction(count), AggregateFunction(sum, UInt8), String)",
    "root_variant_null_unused_sum"    => "Variant(AggregateFunction(count), AggregateFunction(sum, UInt8), String)",
  }

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W225 Variant helper: #{message}") unless condition
  end

  private def nibble(byte : UInt8) : UInt8
    if byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
      return (byte - '0'.ord.to_u8).to_u8
    end
    if byte >= 'a'.ord.to_u8 && byte <= 'f'.ord.to_u8
      return (byte - 'a'.ord.to_u8 + 10).to_u8
    end
    raise ArgumentError.new("W225 literal bytes must be lowercase hexadecimal")
  end

  private def decode_hex(hex : String) : Bytes
    unless hex.bytesize.even? && hex.matches?(/\A(?:[0-9a-f]{2})*\z/)
      raise ArgumentError.new("W225 literal bytes must be even lowercase hexadecimal")
    end
    Bytes.new(hex.bytesize // 2) do |index|
      ((nibble(hex.byte_at(index * 2)) << 4) | nibble(hex.byte_at(index * 2 + 1))).to_u8
    end
  end

  private def encode_hex(bytes : Bytes) : String
    String.build { |io| bytes.each { |byte| io << byte.to_s(16).rjust(2, '0') } }
  end

  private def u64_le(value : UInt64) : Bytes
    Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end

  private def decimal_u64(value : JSON::Any, label : String) : UInt64
    decimal = value.as_s
    parsed = decimal.to_u64
    require!(parsed.to_s == decimal, "#{label} must be canonical unsigned decimal")
    parsed
  end

  private def profile_for(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"
      CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("unlisted W225 String profile: #{name}")
    end
  end

  private def variant_index(type : CrystalClick::BinaryDataType, alternative : String) : UInt8
    index = type.children.index { |child| child.name == alternative } ||
            raise ArgumentError.new("W225 Variant alternative is absent from its canonical descriptor: #{alternative}")
    index.to_u8
  end

  private def build_tagged_value(type : CrystalClick::BinaryDataType, spec : JSON::Any) : CrystalClick::BinaryValue
    kind = spec["kind"].as_s
    case kind
    when "variant_null"
      require!(type.tag == CrystalClick::BinaryDataType::TAG_VARIANT && spec.as_h.keys == ["kind"],
        "Variant NULL fixture has the wrong type or fields")
      CrystalClick::BinaryValue.variant_null(type)
    when "variant"
      require!(type.tag == CrystalClick::BinaryDataType::TAG_VARIANT &&
               spec.as_h.keys.sort == ["alternative", "kind", "value"], "Variant fixture has the wrong type or fields")
      alternative = spec["alternative"].as_s
      index = variant_index(type, alternative)
      child_type = type.child_at(index)
      child = build_tagged_value(child_type, spec["value"])
      CrystalClick::BinaryValue.variant(type, index, child)
    when "count"
      require!(type.tag == CrystalClick::BinaryDataType::TAG_AGGREGATE_FUNCTION && !type.aggregate_count_type.nil?,
        "Count fixture does not target AggregateFunction(count)")
      require!(spec.as_h.keys.sort == ["kind", "value"], "Count fixture fields differ")
      CrystalClick::BinaryValue.aggregate_count_state(type, decimal_u64(spec["value"], "Count value"))
    when "aggregate_state"
      require!(type.tag == CrystalClick::BinaryDataType::TAG_AGGREGATE_FUNCTION && type.aggregate_count_type.nil?,
        "opaque state fixture does not target a non-Count AggregateFunction leaf")
      require!(spec.as_h.keys.sort == ["bytes_hex", "kind", "type"], "opaque state fixture fields differ")
      require!(spec["type"].as_s == type.name, "opaque state fixture has a wrong nominal type")
      CrystalClick::BinaryValue.aggregate_function_state(type, decode_hex(spec["bytes_hex"].as_s))
    when "string"
      require!(type.tag == CrystalClick::BinaryDataType::TAG_STRING, "String fixture has a non-String descriptor")
      require!(spec.as_h.keys.sort == ["kind", "value"], "String fixture fields differ")
      CrystalClick::BinaryValue.string(spec["value"].as_s)
    when "array"
      require!(type.tag == CrystalClick::BinaryDataType::TAG_ARRAY, "Array fixture has a non-Array descriptor")
      require!(spec.as_h.keys.sort == ["items", "kind"], "Array fixture fields differ")
      values = spec["items"].as_a.map { |item| build_tagged_value(type.child_at(0), item) }
      CrystalClick::BinaryValue.array(type, values)
    when "tuple"
      require!(type.tag == CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, "Tuple fixture has a non-unnamed Tuple descriptor")
      require!(spec.as_h.keys.sort == ["fields", "kind"], "Tuple fixture fields differ")
      fields = spec["fields"].as_a
      require!(fields.size == type.child_count, "Tuple fixture field count differs")
      values = fields.each_with_index.map { |field, index| build_tagged_value(type.child_at(index), field) }.to_a
      CrystalClick::BinaryValue.tuple(type, values)
    else
      raise ArgumentError.new("unlisted W225 tagged value kind: #{kind}")
    end
  end

  # Builds a second value tree from logical metadata, not from the tagged
  # opaque-state fixture. Aggregate state bytes are derived only from the
  # independently supplied semantic UInt64 values.
  private def build_metadata_value(type : CrystalClick::BinaryDataType, spec : JSON::Any) : CrystalClick::BinaryValue
    if type.tag == CrystalClick::BinaryDataType::TAG_AGGREGATE_FUNCTION
      value = decimal_u64(spec, "metadata #{type.name}")
      if !type.aggregate_count_type.nil?
        return CrystalClick::BinaryValue.aggregate_count_state(type, value)
      end
      return CrystalClick::BinaryValue.aggregate_function_state(type, u64_le(value))
    end

    case type.tag
    when CrystalClick::BinaryDataType::TAG_VARIANT
      if spec.raw.nil?
        return CrystalClick::BinaryValue.variant_null(type)
      end
      require!(spec.as_h.keys.sort == ["alternative", "value"], "Variant metadata fields differ")
      alternative = spec["alternative"].as_s
      index = variant_index(type, alternative)
      child = build_metadata_value(type.child_at(index), spec["value"])
      CrystalClick::BinaryValue.variant(type, index, child)
    when CrystalClick::BinaryDataType::TAG_STRING
      CrystalClick::BinaryValue.string(spec.as_s)
    when CrystalClick::BinaryDataType::TAG_ARRAY
      values = spec.as_a.map { |item| build_metadata_value(type.child_at(0), item) }
      CrystalClick::BinaryValue.array(type, values)
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE
      fields = spec.as_a
      require!(fields.size == type.child_count, "Tuple metadata field count differs")
      values = fields.each_with_index.map { |field, index| build_metadata_value(type.child_at(index), field) }.to_a
      CrystalClick::BinaryValue.tuple(type, values)
    else
      raise ArgumentError.new("unlisted W225 metadata type: #{type.name}")
    end
  end

  private def same_value!(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue, label : String) : Nil
    require!(actual.type == expected.type, "#{label} nominal descriptor differs: #{actual.type.name} != #{expected.type.name}")
    require!(actual.is_null? == expected.is_null?, "#{label} NULL state differs")
    return if actual.is_null?

    if actual.type.tag == CrystalClick::BinaryDataType::TAG_AGGREGATE_FUNCTION
      if !actual.type.aggregate_count_type.nil?
        require!(actual.count_state == expected.count_state, "#{label} Count value differs")
      else
        require!(actual.aggregate_function_state_bytes == expected.aggregate_function_state_bytes,
          "#{label} opaque AggregateFunction bytes differ")
      end
    elsif actual.type.tag == CrystalClick::BinaryDataType::TAG_VARIANT
      actual_index = actual.variant_index? || raise CrystalClick::CorruptPartError.new("#{label} selected Variant has no arm")
      expected_index = expected.variant_index? || raise CrystalClick::CorruptPartError.new("#{label} expected Variant has no arm")
      require!(actual_index == expected_index, "#{label} Variant selected arm differs")
      actual_child = actual.variant_child? || raise CrystalClick::CorruptPartError.new("#{label} selected Variant has no child")
      expected_child = expected.variant_child? || raise CrystalClick::CorruptPartError.new("#{label} expected Variant has no child")
      same_value!(actual_child, expected_child, "#{label}.#{actual.type.child_at(actual_index).name}")
    elsif actual.type.tag == CrystalClick::BinaryDataType::TAG_STRING
      require!(actual.as_string == expected.as_string, "#{label} String differs")
    elsif actual.type.tag == CrystalClick::BinaryDataType::TAG_ARRAY ||
          actual.type.tag == CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE
      require!(actual.element_count == expected.element_count, "#{label} child count differs")
      actual.element_count.times do |index|
        same_value!(actual.element_at(index), expected.element_at(index), "#{label}[#{index}]")
      end
    else
      require!(actual.bytes == expected.bytes, "#{label} raw bytes differ")
    end
    nil
  end

  private def same_rows!(actual : Array(CrystalClick::BinaryValue), expected : Array(CrystalClick::BinaryValue), label : String) : Nil
    require!(actual.size == expected.size, "#{label} row count differs")
    actual.each_with_index { |value, index| same_value!(value, expected[index], "#{label}[#{index}]") }
    nil
  end

  private def same_marks!(actual : Array(Array(CrystalClick::BinaryValue)), expected : Array(Array(CrystalClick::BinaryValue)), label : String) : Nil
    require!(actual.size == expected.size, "#{label} mark count differs")
    actual.each_with_index do |mark, mark_index|
      same_rows!(mark, expected[mark_index], "#{label}/mark#{mark_index}")
    end
    nil
  end

  private def append_varuint(value : UInt64, output : Array(UInt8)) : Nil
    remaining = value
    while remaining >= 0x80_u64
      output << ((remaining & 0x7f_u64).to_u8 | 0x80_u8)
      remaining >>= 7
    end
    output << remaining.to_u8
  end

  private def append_u64(value : UInt64, output : Array(UInt8)) : Nil
    u64_le(value).each { |byte| output << byte }
  end

  # Small independent RowBinary encoder for this seven-profile finite roster.
  # It follows the independent logical metadata tree and never calls the
  # library BinaryValue codec or BinaryBulk codec.
  private def append_rowbinary(type : CrystalClick::BinaryDataType, value : JSON::Any, output : Array(UInt8)) : Nil
    if type.tag == CrystalClick::BinaryDataType::TAG_AGGREGATE_FUNCTION
      semantic = decimal_u64(value, "RowBinary #{type.name}")
      if !type.aggregate_count_type.nil?
        append_varuint(semantic, output)
      else
        append_u64(semantic, output)
      end
      return nil
    end

    case type.tag
    when CrystalClick::BinaryDataType::TAG_VARIANT
      if value.raw.nil?
        output << 0xff_u8
        return nil
      end
      alternative = value["alternative"].as_s
      index = variant_index(type, alternative)
      output << index
      append_rowbinary(type.child_at(index), value["value"], output)
    when CrystalClick::BinaryDataType::TAG_STRING
      string = value.as_s
      append_varuint(string.bytesize.to_u64, output)
      string.to_slice.each { |byte| output << byte }
    when CrystalClick::BinaryDataType::TAG_ARRAY
      items = value.as_a
      append_varuint(items.size.to_u64, output)
      items.each { |item| append_rowbinary(type.child_at(0), item, output) }
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE
      fields = value.as_a
      require!(fields.size == type.child_count, "RowBinary Tuple field count differs")
      fields.each_with_index { |field, index| append_rowbinary(type.child_at(index), field, output) }
    else
      raise ArgumentError.new("unlisted W225 RowBinary type: #{type.name}")
    end
    nil
  end

  private def rowbinary_hex(type : CrystalClick::BinaryDataType, keys : Array(UInt64), values : Array(JSON::Any)) : String
    output = [] of UInt8
    keys.each_with_index do |key, index|
      append_u64(key, output)
      append_rowbinary(type, values[index], output)
    end
    encode_hex(Bytes.new(output.size) { |index| output[index] })
  end

  private def marks(values : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
    [values[0, 2], values[2, 2], values[4, 1]]
  end

  private def expected_lane_map(lanes : JSON::Any, id : String) : Hash(String, JSON::Any)
    result = Hash(String, JSON::Any).new
    lanes.as_a.each do |lane|
      require!(lane.as_h.keys.sort == ["hex", "mark_offsets", "role_path"], "#{id} independent lane fields differ")
      role = lane["role_path"].as_s
      require!(role.matches?(/\A[A-Za-z0-9_.-]+\z/) && !result.has_key?(role), "#{id} lane role is unsafe or duplicated")
      bytes = decode_hex(lane["hex"].as_s)
      lane_size = bytes.size.to_i64
      offsets = lane["mark_offsets"].as_a.map(&.as_i64)
      require!(offsets.size == 4 && offsets[0] == 0 && offsets.each_cons(2).all? { |pair| pair[0] <= pair[1] },
        "#{id}/#{role} independent mark offset grid is invalid")
      require!(offsets.all? { |offset| offset >= 0 && offset <= lane_size },
        "#{id}/#{role} independent mark offset exceeds its literal lane")
      # Reject literal trailing bytes beyond the final row/mark boundary.
      require!(offsets.last == lane_size, "#{id}/#{role} final mark offset does not cover its literal lane")
      result[role] = lane
    end
    result
  end

  private def lane_literals!(encoded : CrystalClick::BinaryBulkStreams, expected : Hash(String, JSON::Any), id : String) : Array(JSON::Any)
    roles = encoded.roles
    require!(roles == expected.keys.sort, "#{id} independent lane role roster differs")
    records = [] of JSON::Any
    roles.each do |role|
      stream = encoded.stream(role)
      expected_lane = expected[role]
      expected_hex = expected_lane["hex"].as_s
      expected_offsets = expected_lane["mark_offsets"].as_a.map(&.as_i64)
      actual_hex = encode_hex(stream.bytes)
      actual_offsets = stream.offsets.map(&.to_i64)
      require!(actual_hex == expected_hex, "#{id}/#{role} codec lane bytes differ from independent literal")
      require!(actual_offsets == expected_offsets, "#{id}/#{role} codec mark offsets differ from independent literal")
      records << JSON::Any.new({
        "role_path"    => JSON::Any.new(role),
        "hex"          => JSON::Any.new(actual_hex),
        "mark_offsets" => JSON::Any.new(actual_offsets.map { |offset| JSON::Any.new(offset) }),
      } of String => JSON::Any)
    end
    records
  end

  private def physical_lanes!(part : String, type : CrystalClick::BinaryDataType, profile : CrystalClick::BinaryBulkProfile,
                              expected : Hash(String, JSON::Any), id : String, label : String) : Array(JSON::Any)
    physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, COLUMN, profile)
    roles = physical.stream_names.keys.sort
    require!(roles == expected.keys.sort, "#{label}/#{id} physical role roster differs from independent fixture")
    source = CrystalClick::PartStreamSource.new(part)
    records = [] of JSON::Any
    roles.each do |role|
      data_name = physical.data_file_for(role, true)
      marks_name = physical.marks_file_for(role, true)
      prefix = physical.prefix_size_for(role)
      grid = source.inspect_grid(data_name, marks_name, prefix)
      require!(grid.rows_per_mark == MARK_ROWS, "#{label}/#{id}/#{role} physical row schedule differs")
      raw = grid.logical_size == 0_i64 ? Bytes.new(0) : source.read_all(data_name)
      physical_offsets = grid.positions.map(&.to_u64)
      logical, offsets, returned_prefix = CrystalClick::BinaryBulkPhysicalPrefixAdapter.read_lane(
        role, raw, physical_offsets, prefix
      )
      require!(returned_prefix == 0, "#{label}/#{id}/#{role} prefix was not normalized")
      expected_lane = expected[role]
      bytes_hex = encode_hex(logical)
      expected_offsets = expected_lane["mark_offsets"].as_a.map(&.as_i64)
      actual_offsets = offsets.map(&.to_i64)
      require!(bytes_hex == expected_lane["hex"].as_s, "#{label}/#{id}/#{role} physical lane bytes differ")
      require!(actual_offsets == expected_offsets, "#{label}/#{id}/#{role} physical mark offsets differ")
      records << JSON::Any.new({
        "role_path"             => JSON::Any.new(role),
        "data_path"             => JSON::Any.new(File.join(part, data_name)),
        "mrk2_path"             => JSON::Any.new(File.join(part, marks_name)),
        "hex"                   => JSON::Any.new(bytes_hex),
        "mark_offsets"          => JSON::Any.new(actual_offsets.map { |offset| JSON::Any.new(offset) }),
        "physical_prefix_bytes" => JSON::Any.new(prefix.to_i64),
        "rows_per_mark"         => JSON::Any.new(grid.rows_per_mark.map { |rows| JSON::Any.new(rows.to_i64) }),
      } of String => JSON::Any)
    end
    records
  end

  private def profile_name(profile : CrystalClick::BinaryBulkProfile) : String
    profile.with_size_stream? ? "with_size_stream" : "single_stream"
  end

  private def inspect_part!(part : String, type : CrystalClick::BinaryDataType, profile : CrystalClick::BinaryBulkProfile,
                            expected : Array(CrystalClick::BinaryValue), lanes : Hash(String, JSON::Any),
                            id : String, label : String) : JSON::Any
    reader = CrystalClick::BinaryBulkColumnReader.open(part, COLUMN, type)
    require!(reader.schema_declaration == type.name && reader.source_declaration == type.name,
      "#{label}/#{id} exact nominal declaration differs")
    require!(reader.ordinary_profile == profile, "#{label}/#{id} String profile differs")
    require!(reader.row_count == 5_u64 && reader.mark_row_counts == MARK_ROWS,
      "#{label}/#{id} row/mark axes differ")
    expected_roles = CrystalClick::BinaryBulkPhysicalPlan.new(type, COLUMN, profile).stream_names.values.sort
    require!(reader.physical_stream_names == expected_roles, "#{label}/#{id} actual physical stream roster differs")
    observed = reader.read_marks(0, reader.mark_count)
    same_marks!(observed, marks(expected), "#{label}/#{id}/reader")
    require!(reader.read_marks(reader.mark_count, 0).empty?, "#{label}/#{id} terminal empty window is not empty")
    lane_records = physical_lanes!(part, type, profile, lanes, id, label)
    JSON::Any.new({
      "part_path"             => JSON::Any.new(part),
      "schema_declaration"    => JSON::Any.new(reader.schema_declaration),
      "source_declaration"    => JSON::Any.new(reader.source_declaration),
      "profile"               => JSON::Any.new(profile_name(reader.ordinary_profile)),
      "row_count"             => JSON::Any.new(reader.row_count.to_i64),
      "mark_rows"             => JSON::Any.new(reader.mark_row_counts.map { |count| JSON::Any.new(count.to_i64) }),
      "physical_stream_names" => JSON::Any.new(reader.physical_stream_names.map { |name| JSON::Any.new(name) }),
      "mark_reads"            => JSON::Any.new([
        JSON::Any.new({"first_mark" => JSON::Any.new(0_i64), "mark_count" => JSON::Any.new(3_i64), "rows" => JSON::Any.new(5_i64)} of String => JSON::Any),
        JSON::Any.new({"first_mark" => JSON::Any.new(3_i64), "mark_count" => JSON::Any.new(0_i64), "rows" => JSON::Any.new(0_i64)} of String => JSON::Any),
      ]),
      "physical_lanes"       => JSON::Any.new(lane_records),
      "exact_nominal_states" => JSON::Any.new(true),
    } of String => JSON::Any)
  end

  private def public_consumers!(part : String, type : CrystalClick::BinaryDataType,
                                expected : Array(CrystalClick::BinaryValue), label : String) : JSON::Any
    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_COLUMN, COLUMN])
    values = [] of CrystalClick::BinaryValue
    schedule = [] of Tuple(Int32, Int64, Int32)
    table.scan_typed(batch_rows: 2) do |batch|
      selected = batch.binary_bulk_values_for(COLUMN)
      selected.each do |value|
        require!(value.type == type, "#{label} typed callback lost the exact descriptor")
        values << value
      end
      schedule << {batch.mark_index, batch.part_row_offset.to_i64, selected.size}
    end
    same_rows!(values, expected, "#{label}/WidePartTable.scan_typed")
    require!(schedule == [{0, 0_i64, 2}, {1, 2_i64, 2}, {2, 4_i64, 1}], "#{label} callback batch schedule differs")
    window = [] of CrystalClick::BinaryValue
    table.scan_typed_window(1_u64, 3) do |batch|
      batch.binary_bulk_values_for(COLUMN).each { |value| window << value }
    end
    same_rows!(window, expected[1, 3], "#{label}/WidePartTable.scan_typed_window")

    info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
    candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part, info, 5_u64)
    offline = CrystalClick::OfflineTable.new(
      "w225_events", "w225-variant-helper", "MergeTree",
      [CrystalClick::OfflineColumn.new(KEY_COLUMN, "UInt64"), CrystalClick::OfflineColumn.new(COLUMN, type.name)] of CrystalClick::OfflineColumn,
      [candidate] of CrystalClick::OfflinePartCandidate
    )
    owned = offline[COLUMN].values.map(&.as(CrystalClick::BinaryValue))
    same_rows!(owned, expected, "#{label}/OfflineColumn.values")
    offline_scanned = [] of CrystalClick::BinaryValue
    offline.scan_typed([KEY_COLUMN, COLUMN], batch_rows: 2) do |batch|
      batch.binary_bulk_values_for(COLUMN).each { |value| offline_scanned << value }
    end
    same_rows!(offline_scanned, expected, "#{label}/OfflineTable.scan_typed")
    offline_window = [] of CrystalClick::BinaryValue
    offline.scan_typed_window([KEY_COLUMN, COLUMN], 1_u64, 3) do |batch|
      batch.binary_bulk_values_for(COLUMN).each { |value| offline_window << value }
    end
    same_rows!(offline_window, expected[1, 3], "#{label}/OfflineTable.scan_typed_window")

    schedule_json = schedule.map do |mark, offset, row_count|
      JSON::Any.new([JSON::Any.new(mark.to_i64), JSON::Any.new(offset), JSON::Any.new(row_count.to_i64)])
    end
    JSON::Any.new({
      "wide_part_scan" => JSON::Any.new({
        "api"            => JSON::Any.new("WidePartTable.open_selected_typed + generic BinaryBulk callback values"),
        "batch_schedule" => JSON::Any.new(schedule_json),
        "window_rows"    => JSON::Any.new(window.size.to_i64),
      } of String => JSON::Any),
      "offline_values"       => JSON::Any.new({"rows" => JSON::Any.new(owned.size.to_i64), "detached_values" => JSON::Any.new(true)} of String => JSON::Any),
      "offline_scan"         => JSON::Any.new({"rows" => JSON::Any.new(offline_scanned.size.to_i64), "window_rows" => JSON::Any.new(offline_window.size.to_i64)} of String => JSON::Any),
      "exact_nominal_states" => JSON::Any.new(true),
    } of String => JSON::Any)
  end

  private def validate_paths!(profile : JSON::Any, id : String, output_root : String,
                              capture_root : String) : Tuple(String, String)
    stock_input = profile["stockpart"].as_s
    library_input = profile["librarydest"].as_s
    stock = File.expand_path(stock_input)
    library = File.expand_path(library_input)
    require!(stock_input == stock && library_input == library,
      "#{id} stock/library paths must be canonical absolute paths")
    require!(stock.starts_with?(capture_root + File::SEPARATOR) && Dir.exists?(stock) && !File.symlink?(stock) && File.realpath(stock) == stock,
      "#{id} stock part escaped, is symlinked, or absent")
    profile_index = PROFILE_IDS.index(id).not_nil!
    destination_parent = File.join(output_root, "parts", "#{profile_index.to_s.rjust(2, '0')}-#{id}")
    expected_library = File.join(destination_parent, "all_1_1_0")
    require!(library == expected_library && Dir.exists?(destination_parent) &&
             !File.symlink?(destination_parent) && File.realpath(destination_parent) == destination_parent &&
             !File.exists?(library) && !File.symlink?(library),
      "#{id} library destination or precreated parent differs from the finite output layout")
    require!(!stock.starts_with?(output_root + File::SEPARATOR) && !library.starts_with?(capture_root + File::SEPARATOR),
      "#{id} stock and generated roots overlap")
    {stock, library}
  end

  private def process_profile(profile : JSON::Any, output_root : String, capture_root : String) : JSON::Any
    id = profile["id"].as_s
    declared = profile["declared_type"].as_s
    expected_name = PROFILE_TYPES[id]? || raise ArgumentError.new("unknown W225 profile #{id}")
    require!(declared == expected_name, "#{id} is outside the finite canonical nominal roster")
    type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(declared) ||
           raise ArgumentError.new("#{id} descriptor is not canonical")
    require!(type.name == declared && type.contains_aggregate_function?, "#{id} nominal AggregateFunction descriptor differs")
    CrystalClick::BinaryAggregateFunctionRecursiveAdmission.require_static_tree!(type)
    profile_name = profile["profile"].as_s
    bulk_profile = profile_for(profile_name)
    require!(profile_name == (id == "root_variant_with_size" ? "with_size_stream" : "single_stream"),
      "#{id} String profile differs from the finite selected profile")
    require!(profile["row_keys"].as_a.map(&.as_i64) == ROW_KEYS.map(&.to_i64), "#{id} key fixture differs")
    require!(profile["mark_rows"].as_a.map(&.as_i64) == MARK_ROWS.map(&.to_i64), "#{id} mark schedule differs")
    metadata = profile["metadata"].as_a
    tagged = profile["values"].as_a
    require!(metadata.size == ROW_KEYS.size && tagged.size == ROW_KEYS.size, "#{id} metadata/value row count differs")
    expected_metadata = metadata.map { |item| build_metadata_value(type, item) }
    expected_tagged = tagged.map { |item| build_tagged_value(type, item) }
    same_rows!(expected_tagged, expected_metadata, "#{id}/independent_metadata_binding")
    require!(expected_tagged.all? { |value| value.type == type }, "#{id} values lost their exact nominal parent descriptor")

    rowbinary = profile["rowbinary"]
    require!(rowbinary.as_h.keys.sort == ["empty_hex", "full_hex", "middle_hex"], "#{id} RowBinary fixture fields differ")
    full_hex = rowbinary_hex(type, ROW_KEYS.to_a, metadata)
    middle_hex = rowbinary_hex(type, ROW_KEYS[2, 2], metadata[2, 2])
    empty_hex = rowbinary_hex(type, [] of UInt64, [] of JSON::Any)
    require!(full_hex == rowbinary["full_hex"].as_s, "#{id} full independent RowBinary bytes differ")
    require!(middle_hex == rowbinary["middle_hex"].as_s, "#{id} middle-mark RowBinary bytes differ")
    require!(empty_hex == rowbinary["empty_hex"].as_s && empty_hex.empty?, "#{id} empty RowBinary bytes differ")

    literal_lanes = expected_lane_map(profile["expected_lanes"], id)
    marks = marks(expected_tagged)
    encoded = CrystalClick::BinaryBulkCodec.encode(type, marks, profile: bulk_profile)
    encoded_lanes = lane_literals!(encoded, literal_lanes, id)
    stock_path, library_path = validate_paths!(profile, id, output_root, capture_root)
    stock = inspect_part!(stock_path, type, bulk_profile, expected_tagged, literal_lanes, id, "stock")
    stock_public = public_consumers!(stock_path, type, expected_tagged, "stock/#{id}")

    written = CrystalClick::WidePartWriter.write_uint64_and_aggregate_function_part(
      library_path,
      KEY_COLUMN,
      Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64],
      COLUMN,
      type,
      marks,
      rows_per_mark: 2,
      profile: bulk_profile,
      frame_bytes: 64
    )
    require!(written == library_path && Dir.exists?(written) && !File.symlink?(written),
      "#{id} paired writer did not publish the exact target")
    library = inspect_part!(written, type, bulk_profile, expected_tagged, literal_lanes, id, "library")
    library_public = public_consumers!(written, type, expected_tagged, "library/#{id}")

    JSON::Any.new({
      "id"                    => JSON::Any.new(id),
      "classification"        => JSON::Any.new("generic_stock_read_library_write_read_observed"),
      "declared_type"         => JSON::Any.new(type.name),
      "profile"               => JSON::Any.new(profile_name),
      "row_keys"              => JSON::Any.new(ROW_KEYS.map { |key| JSON::Any.new(key.to_i64) }),
      "mark_rows"             => JSON::Any.new(MARK_ROWS.map { |rows| JSON::Any.new(rows.to_i64) }),
      "stockpart"             => JSON::Any.new(stock_path),
      "librarydest"           => JSON::Any.new(library_path),
      "stock"                 => stock,
      "stock_consumers"       => stock_public,
      "library"               => library,
      "library_consumers"     => library_public,
      "metadata_values"       => JSON::Any.new(metadata),
      "tagged_state_values"   => JSON::Any.new(tagged),
      "independent_lanes"     => JSON::Any.new(profile["expected_lanes"].as_a),
      "encoded_literal_lanes" => JSON::Any.new(encoded_lanes),
      "rowbinary"             => JSON::Any.new({
        "full_hex" => JSON::Any.new(full_hex), "middle_hex" => JSON::Any.new(middle_hex),
        "empty_hex" => JSON::Any.new(empty_hex), "matches_independent_literals" => JSON::Any.new(true),
      } of String => JSON::Any),
      "exact_nominal_states" => JSON::Any.new(true),
    } of String => JSON::Any)
  end

  private def validate_input!(input : JSON::Any, input_path : String, output_root : String,
                              capture_root : String) : Array(JSON::Any)
    require!(input.as_h.keys.sort == ["capture_root", "format", "profiles"] && input["format"].as_s == FORMAT_INPUT,
      "helper input format differs")
    require!(input["capture_root"].as_s == capture_root, "capture root differs")
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "stock capture root is absent, symlinked, or noncanonical")
    require!(capture_root.starts_with?(SOURCE_PREFIX) && File.dirname(capture_root) == "/private/tmp",
      "stock capture root escaped its pinned direct-child prefix")
    require!(input_path.starts_with?(output_root + File::SEPARATOR) && File.file?(input_path) && !File.symlink?(input_path),
      "helper input is not a plain file under generated output root")
    require!(!capture_root.starts_with?(output_root + File::SEPARATOR) && !output_root.starts_with?(capture_root + File::SEPARATOR),
      "source capture and generated output roots overlap")

    profiles = input["profiles"].as_a
    require!(profiles.size == PROFILE_IDS.size && profiles.map { |profile| profile["id"].as_s } == PROFILE_IDS,
      "W225 finite profile roster differs")
    profiles.each do |profile|
      id = profile["id"].as_s
      fields = %w[declared_type expected_lanes id librarydest mark_rows metadata profile row_keys rowbinary stockpart values]
      require!(profile.as_h.keys.sort == fields, "#{id} helper profile fields differ")
      require!(profile["row_keys"].as_a.map(&.as_i64) == ROW_KEYS.map(&.to_i64), "#{id} key roster differs")
      require!(profile["mark_rows"].as_a.map(&.as_i64) == MARK_ROWS.map(&.to_i64), "#{id} mark grid differs")
      expected_name = PROFILE_TYPES[id]? || raise ArgumentError.new("unknown W225 profile #{id}")
      declared = profile["declared_type"].as_s
      require!(declared == expected_name, "#{id} is outside the finite canonical type roster")
      type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(declared) ||
             raise ArgumentError.new("#{id} type name is not canonical")
      require!(type.name == declared && type.contains_aggregate_function?, "#{id} nominal type differs")
      CrystalClick::BinaryAggregateFunctionRecursiveAdmission.require_static_tree!(type)
      profile_for(profile["profile"].as_s)
      require!(profile["metadata"].as_a.size == ROW_KEYS.size && profile["values"].as_a.size == ROW_KEYS.size,
        "#{id} metadata/value count differs")
      require!(profile["rowbinary"].as_h.keys.sort == ["empty_hex", "full_hex", "middle_hex"], "#{id} RowBinary fields differ")
      %w[empty_hex full_hex middle_hex].each { |key| decode_hex(profile["rowbinary"][key].as_s) }
      lanes = expected_lane_map(profile["expected_lanes"], id)
      physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, COLUMN, profile_for(profile["profile"].as_s))
      require!(lanes.keys.sort == physical.stream_names.keys.sort, "#{id} expected literal roles do not cover the physical plan")
      validate_paths!(profile, id, output_root, capture_root)
    end
    profiles
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 3
      raise ArgumentError.new("usage: check_aggregate_variant_w225.cr INPUT.json OUTPUT_ROOT CAPTURE_ROOT")
    end
    require!(args.all? { |path| path == File.expand_path(path) },
      "input and roots must be canonical absolute paths")
    input_path, output_root, capture_root = args.map { |path| File.expand_path(path) }
    require!(Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root,
      "generated output root is not canonical")
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "stock capture root is not canonical")
    require!(File.file?(input_path) && !File.symlink?(input_path) && File.realpath(input_path) == input_path,
      "helper input is missing, symlinked, or noncanonical")
    input = JSON.parse(File.read(input_path))
    profiles = validate_input!(input, input_path, output_root, capture_root)
    results = profiles.map { |profile| process_profile(profile, output_root, capture_root) }
    output = JSON::Any.new({
      "format"         => JSON::Any.new(FORMAT_OUTPUT),
      "profile_count"  => JSON::Any.new(results.size.to_i64),
      "observed_count" => JSON::Any.new(results.size.to_i64),
      "mismatch_count" => JSON::Any.new(0_i64),
      "profiles"       => JSON::Any.new(results),
    } of String => JSON::Any)
    puts output.to_json
  rescue ex : Exception
    STDERR.puts "W225 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckAggregateVariantW225.main(ARGV)
