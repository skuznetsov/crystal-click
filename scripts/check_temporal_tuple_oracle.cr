require "json"
require "file_utils"
require "../src/crystal_click"

W100O_VERSION      = "26.7.1.1315"
W100O_KEYS         = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W100O_MARK_ROWS    = [2_u64, 2_u64, 1_u64, 0_u64]
W100O_FULL_INDEXES = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32]
W100O_KEY_RANGE    = [1_i32, 2_i32, 3_i32]
W100O_MARK_RANGE   = [2_i32, 3_i32, 4_i32]
W100O_WINDOW       = [1_i32, 2_i32, 3_i32]
W100O_CANDIDATE    = [2_i32, 3_i32, 4_i32]

struct W100TemporalSpec
  getter label : String
  getter type_name : String
  getter width : Int32

  def initialize(@label : String, @type_name : String, @width : Int32)
  end
end

struct W100OracleField
  getter name : String
  getter type_name : String
  getter column : CrystalClick::WideTupleLeafColumn
  getter expected_rows : Array(String)
  getter rowbinary_rows : Array(String)

  def initialize(
    @name : String,
    @type_name : String,
    column : CrystalClick::WideTupleLeafColumn,
    expected_rows : Array(String),
    rowbinary_rows : Array(String),
  )
    @column = column.owned_copy
    @expected_rows = expected_rows.dup
    @rowbinary_rows = rowbinary_rows.dup
    raise "#{@name}: independent row fixture count differs" unless @expected_rows.size == W100O_KEYS.size
    raise "#{@name}: independent RowBinary fixture count differs" unless @rowbinary_rows.size == W100O_KEYS.size
    raise "#{@name}: declared type differs from leaf" unless @column.type_name == @type_name
  end

  def string? : Bool
    @type_name == "String"
  end
end

struct W100OracleProfile
  getter label : String
  getter fields : Array(W100OracleField)
  getter ratio : String

  def initialize(@label : String, fields : Array(W100OracleField), @ratio : String = "0.9375")
    raise "#{@label}: profile has no fields" if fields.empty?
    @fields = fields.dup
    @fields.each do |field|
      raise "#{@label}: field row counts do not align" unless field.column.size == W100O_KEYS.size
    end
  end

  def type_name : String
    "Tuple(#{@fields.map { |field| "#{field.name} #{field.type_name}" }.join(", ")})"
  end

  def source_table : String
    "w100o_source_#{@label}"
  end

  def writer_table : String
    "w100o_writer_#{@label}"
  end

  def columns : Array(CrystalClick::WideTupleLeafColumn)
    @fields.map(&.column)
  end
end

class W100OracleByteMismatchError < Exception
end

def w100o_u64_le(value : UInt64, width : Int32 = 8) : String
  output = IO::Memory.new
  width.times { |index| output.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
  output.to_s
end

def w100o_i64_le(value : Int64, width : Int32 = 8) : String
  w100o_u64_le(value.unsafe_as(UInt64), width)
end

def w100o_varuint(value : UInt64) : String
  output = IO::Memory.new
  remaining = value
  while remaining >= 0x80_u64
    output.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  output.write_byte(remaining.to_u8)
  output.to_s
end

def w100o_temporal_specs : Array(W100TemporalSpec)
  specs = [
    W100TemporalSpec.new("date", "Date", 2),
    W100TemporalSpec.new("date32", "Date32", 4),
    W100TemporalSpec.new("datetime", "DateTime", 4),
    W100TemporalSpec.new("time", "Time", 4),
  ] of W100TemporalSpec
  (0..9).each do |precision|
    specs << W100TemporalSpec.new("datetime64_p#{precision}", "DateTime64(#{precision})", 8)
    specs << W100TemporalSpec.new("time64_p#{precision}", "Time64(#{precision})", 8)
  end
  raise "expected 24 exact temporal declarations, got #{specs.size}" unless specs.size == 24
  specs
end

def w100o_precision(type_name : String) : Int32
  match = type_name.match(/\((\d+)\)/) || raise "scaled temporal type has no exact precision: #{type_name}"
  match[1].to_i32
end

def w100o_temporal_raws(type_name : String) : Array(Int64)
  case type_name
  when "Date"
    [0_i64, 1_i64, 32_767_i64, 32_768_i64, 65_535_i64]
  when "Date32"
    [-25_567_i64, -1_i64, 0_i64, 1_i64, 24_854_i64]
  when "DateTime"
    [0_i64, 1_i64, 1_000_000_000_i64, 1_700_000_000_i64, 2_000_000_000_i64]
  when "Time"
    [-3_723_i64, 0_i64, 1_i64, 59_i64, 52_225_i64]
  when .starts_with?("DateTime64(")
    precision = w100o_precision(type_name)
    factor = 1_i64
    precision.times { factor *= 10_i64 }
    [-1_i64, 0_i64, factor, 1_700_000_000_i64 * factor, 2_000_000_000_i64 * factor]
  when .starts_with?("Time64(")
    precision = w100o_precision(type_name)
    factor = 1_i64
    precision.times { factor *= 10_i64 }
    half_tick = factor // 2_i64
    [
      -3_723_i64 * factor - half_tick,
      0_i64,
      factor,
      59_i64 * factor + half_tick,
      3_600_i64 * factor + factor - 1_i64,
    ]
  else
    raise "unsupported temporal fixture type #{type_name}"
  end
end

def w100o_temporal_bytes(type_name : String, raw : Int64) : String
  case type_name
  when "Date"
    w100o_u64_le(raw.to_u16.to_u64, 2)
  when "Date32", "Time"
    w100o_i64_le(raw, 4)
  when "DateTime"
    w100o_u64_le(raw.to_u32.to_u64, 4)
  when .starts_with?("DateTime64("), .starts_with?("Time64(")
    w100o_i64_le(raw, 8)
  else
    raise "no independent temporal byte encoder for #{type_name}"
  end
end

def w100o_temporal_column(name : String, type_name : String, raws : Array(Int64)) : CrystalClick::WideTupleLeafColumn
  case type_name
  when "Date"
    values = raws.map { |raw| CrystalClick::DateValue.new(raw.to_u16) }
    CrystalClick::WideTupleLeafColumn.new(name, type_name, values)
  when "Date32"
    values = raws.map { |raw| CrystalClick::Date32Value.new(raw.to_i32) }
    CrystalClick::WideTupleLeafColumn.new(name, type_name, values)
  when "DateTime"
    values = raws.map { |raw| CrystalClick::DateTimeValue.new(raw.to_u32) }
    CrystalClick::WideTupleLeafColumn.new(name, type_name, values)
  when "Time"
    values = raws.map { |raw| CrystalClick::TimeValue.new(raw.to_i32) }
    CrystalClick::WideTupleLeafColumn.new(name, type_name, values)
  when .starts_with?("DateTime64(")
    precision = w100o_precision(type_name)
    values = raws.map { |raw| CrystalClick::DateTime64Value.new(raw, precision) }
    CrystalClick::WideTupleLeafColumn.new(name, type_name, values)
  when .starts_with?("Time64(")
    precision = w100o_precision(type_name)
    values = raws.map { |raw| CrystalClick::Time64Value.new(raw, precision) }
    CrystalClick::WideTupleLeafColumn.new(name, type_name, values)
  else
    raise "no nominal temporal leaf constructor for #{type_name}"
  end
end

def w100o_temporal_field(name : String, type_name : String, raws : Array(Int64)) : W100OracleField
  bytes = raws.map { |raw| w100o_temporal_bytes(type_name, raw) }
  W100OracleField.new(name, type_name, w100o_temporal_column(name, type_name, raws), bytes, bytes)
end

def w100o_uint64_field(name : String, values : Array(UInt64)) : W100OracleField
  bytes = values.map { |value| w100o_u64_le(value) }
  W100OracleField.new(
    name,
    "UInt64",
    CrystalClick::WideTupleLeafColumn.new(name, values),
    bytes,
    bytes
  )
end

def w100o_bool_field(name : String, values : Array(Bool)) : W100OracleField
  bytes = values.map { |value| value ? "\x01" : "\x00" }
  W100OracleField.new(name, "Bool", CrystalClick::WideTupleLeafColumn.new(name, values), bytes, bytes)
end

def w100o_string_field(name : String, values : Array(String)) : W100OracleField
  raw = values.map { |value| String.new(value.to_slice) }
  rowbinary = raw.map { |value| w100o_varuint(value.bytesize.to_u64) + value }
  W100OracleField.new(name, "String", CrystalClick::WideTupleLeafColumn.new(name, raw), raw, rowbinary)
end

def w100o_uuid_field(name : String, values : Array(CrystalClick::UUIDValue)) : W100OracleField
  bytes = values.map { |value| w100o_u64_le(value.high) + w100o_u64_le(value.low) }
  W100OracleField.new(name, "UUID", CrystalClick::WideTupleLeafColumn.new(name, values), bytes, bytes)
end

def w100o_ipv4_field(name : String, values : Array(CrystalClick::IPv4Value)) : W100OracleField
  bytes = values.map { |value| w100o_u64_le(value.network_order.to_u64, 4) }
  W100OracleField.new(name, "IPv4", CrystalClick::WideTupleLeafColumn.new(name, values), bytes, bytes)
end

def w100o_singleton_profiles : Array(W100OracleProfile)
  w100o_temporal_specs.map do |spec|
    W100OracleProfile.new(spec.label, [w100o_temporal_field("event", spec.type_name, w100o_temporal_raws(spec.type_name))] of W100OracleField)
  end
end

def w100o_mixed_profile : W100OracleProfile
  uuid = [
    CrystalClick::UUIDValue.new(0x0011_2233_4455_6677_u64, 0x8899_aabb_ccdd_eeff_u64),
    CrystalClick::UUIDValue.new(UInt64::MAX, 0_u64),
    CrystalClick::UUIDValue.new(0_u64, 0_u64),
    CrystalClick::UUIDValue.new(0x0123_4567_89ab_cdef_u64, 0xfedc_ba98_7654_3210_u64),
    CrystalClick::UUIDValue.new(0x7f00_ff01_fe02_fd03_u64, 0x04fc_05fb_06fa_07f9_u64),
  ]
  ipv4 = [
    CrystalClick::IPv4Value.from_octets(1_u8, 2_u8, 3_u8, 4_u8),
    CrystalClick::IPv4Value.from_octets(4_u8, 3_u8, 2_u8, 1_u8),
    CrystalClick::IPv4Value.from_octets(0_u8, 0_u8, 0_u8, 0_u8),
    CrystalClick::IPv4Value.from_octets(255_u8, 255_u8, 255_u8, 255_u8),
    CrystalClick::IPv4Value.from_octets(192_u8, 168_u8, 1_u8, 7_u8),
  ]
  fields = [
    w100o_uint64_field("count", [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]),
    w100o_temporal_field("event_p3_first", "DateTime64(3)", w100o_temporal_raws("DateTime64(3)")),
    w100o_uuid_field("id", uuid),
    w100o_bool_field("flag", [false, true, false, true, true]),
    w100o_string_field("text", ["alpha", String.new(Bytes[0x62_u8, 0_u8, 0xff_u8]), "", "delta", "epsilon"]),
  ] of W100OracleField
  w100o_temporal_specs.reverse_each do |spec|
    fields << w100o_temporal_field("t_#{spec.label}", spec.type_name, w100o_temporal_raws(spec.type_name))
  end
  fields << w100o_ipv4_field("address", ipv4)
  fields << w100o_temporal_field("event_p3_repeat", "DateTime64(3)", w100o_temporal_raws("DateTime64(3)"))
  fields << w100o_temporal_field("event_p9_repeat", "DateTime64(9)", w100o_temporal_raws("DateTime64(9)"))
  fields << w100o_temporal_field("time_p9_repeat", "Time64(9)", w100o_temporal_raws("Time64(9)"))
  raise "mixed fixture lost one of the 24 canonical declarations" unless w100o_temporal_specs.all? { |spec| fields.count { |field| field.type_name == spec.type_name } >= 1 }
  W100OracleProfile.new("mixed", fields)
end

def w100o_zero_profile : W100OracleProfile
  fields = w100o_temporal_specs.map do |spec|
    w100o_temporal_field("z_#{spec.label}", spec.type_name, Array.new(W100O_KEYS.size, 0_i64))
  end
  W100OracleProfile.new("allzero24", fields, "1.0")
end

def w100o_date32_default_profile(label : String, raw : Int64, ratio : String = "1.0") : W100OracleProfile
  W100OracleProfile.new(
    label,
    [w100o_temporal_field("event", "Date32", Array.new(W100O_KEYS.size, raw))] of W100OracleField,
    ratio
  )
end

def w100o_legacy_positive_control : W100OracleProfile
  W100OracleProfile.new(
    "legacy_control",
    [
      w100o_uint64_field("a", [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]),
      w100o_string_field("b", ["alpha", "beta", "gamma", "delta", "epsilon"]),
    ] of W100OracleField
  )
end

def w100o_tuple_default?(profile : W100OracleProfile, row : Int32) : Bool
  profile.fields.all? { |field| w100o_field_default?(field, row) }
end

def w100o_field_default?(field : W100OracleField, row : Int32) : Bool
  if field.string?
    field.expected_rows[row].empty?
  else
    field.expected_rows[row].to_slice.all?(&.==(0_u8))
  end
end

def w100o_expected_rowbinary(profile : W100OracleProfile, indexes : Array(Int32), include_keys : Bool = true) : String
  output = IO::Memory.new
  indexes.each do |index|
    output << w100o_u64_le(W100O_KEYS[index]) if include_keys
    profile.fields.each { |field| output << field.rowbinary_rows[index] }
  end
  output.to_s
end

def w100o_insert_rowbinary(profile : W100OracleProfile) : String
  w100o_expected_rowbinary(profile, W100O_FULL_INDEXES)
end

def w100o_expected_streams(profile : W100OracleProfile) : Array(String)
  streams = ["pk"]
  profile.fields.each do |field|
    child = "payload%2E#{field.name}"
    if field.string?
      streams << "#{child}.size"
      streams << child
    else
      streams << child
    end
  end
  streams
end

def w100o_stream_expected(profile : W100OracleProfile, stream : String) : String
  return W100O_KEYS.map { |key| w100o_u64_le(key) }.join if stream == "pk"
  profile.fields.each do |field|
    child = "payload%2E#{field.name}"
    if field.string?
      if stream == "#{child}.size"
        return field.expected_rows.map { |value| w100o_u64_le(value.bytesize.to_u64) }.join
      elsif stream == child
        return field.expected_rows.join
      end
    elsif stream == child
      return field.expected_rows.join
    end
  end
  raise "#{profile.label}: no independent expected bytes for physical stream #{stream.inspect}"
end

def w100o_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  difference = 0
  while difference < limit && actual.to_slice[difference] == expected.to_slice[difference]
    difference += 1
  end
  got = difference < actual.bytesize ? actual.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  wanted = difference < expected.bytesize ? expected.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  raise W100OracleByteMismatchError.new("#{label} differs: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first difference #{difference}: expected #{wanted}, got #{got}")
end

def w100o_seeded_wrong_expectation_rejected(actual : String, expected : String, label : String) : Nil
  raise "#{label}: baseline independent expectation did not match" unless actual == expected
  damaged = String.new(expected.to_slice)
  raise "#{label}: cannot mutate an empty baseline" if damaged.empty?
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 0x01_u8
  begin
    w100o_assert_bytes(actual, damaged, "#{label} seeded wrong expectation")
    raise "#{label}: comparator accepted a one-byte wrong expectation"
  rescue ex : W100OracleByteMismatchError
  end
  puts "PASS #{label}: actual comparator rejects a one-byte seeded wrong expectation"
end

def w100o_clickhouse(binary : String, store : String, query : String, input : IO? = nil) : String
  output = IO::Memory.new
  error = IO::Memory.new
  result = if input
             Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  raise "ClickHouse query failed (#{result.exit_code}): #{error}\n#{query}" unless result.success?
  output.to_s
end

def w100o_create_table(binary : String, store : String, table : String, profile : W100OracleProfile) : Nil
  settings = "index_granularity = 2, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, ratio_of_defaults_for_sparse_serialization = #{profile.ratio}"
  w100o_clickhouse(
    binary,
    store,
    "CREATE TABLE default.#{table} (pk UInt64, payload #{profile.type_name}) ENGINE = MergeTree ORDER BY pk SETTINGS #{settings}"
  )
  nil
end

def w100o_insert(binary : String, store : String, table : String, profile : W100OracleProfile) : Nil
  input = IO::Memory.new(w100o_insert_rowbinary(profile).to_slice)
  w100o_clickhouse(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  nil
end

def w100o_part_path(binary : String, store : String, table : String) : String
  lines = w100o_clickhouse(
    binary,
    store,
    "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw"
  ).lines.map(&.strip).reject(&.empty?)
  raise "#{table}: expected one active part, got #{lines.inspect}" unless lines.size == 1
  fields = lines[0].split('\t')
  raise "#{table}: malformed part metadata #{lines[0].inspect}" unless fields.size == 3
  raise "#{table}: expected Wide part, got #{fields[1]}" unless fields[1] == "Wide"
  raise "#{table}: expected five rows, got #{fields[2]}" unless fields[2] == W100O_KEYS.size.to_s
  fields[0]
end

def w100o_check_table(binary : String, store : String, table : String, part : String) : Nil
  actual = w100o_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table} CHECK TABLE mismatch: #{actual.inspect}" unless actual == expected
  nil
end

def w100o_schema(binary : String, store : String, table : String, profile : W100OracleProfile) : Nil
  actual = w100o_clickhouse(
    binary,
    store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
  ).lines.map(&.strip)
  expected = ["pk UInt64", "payload #{profile.type_name}"]
  raise "#{table} system.columns mismatch: #{actual.inspect}" unless actual == expected
  nil
end

def w100o_mark_rows(part : String, stream : String) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{stream}: partial .mrk2 record" unless bytes.size % mark_size == 0
  Array(UInt64).new(bytes.size // mark_size) do |index|
    offset = index * mark_size + 16
    8.times.reduce(0_u64) { |value, byte| value | (bytes[offset + byte].to_u64 << (byte * 8)) }
  end
end

def w100o_validate_counter(row : Hash(String, JSON::Any), expected_defaults : Int32, label : String) : Nil
  kind = row["kind"]?.try(&.as_s) || raise "#{label}: serializer kind missing"
  raise "#{label}: expected Default serializer, got #{kind}" unless kind == "Default"
  rows = row["num_rows"]?.try(&.as_i) || raise "#{label}: num_rows missing"
  defaults = row["num_defaults"]?.try(&.as_i) || raise "#{label}: num_defaults missing"
  raise "#{label}: num_rows=#{rows}, expected 5" unless rows == W100O_KEYS.size.to_i64
  raise "#{label}: num_defaults=#{defaults}, expected #{expected_defaults}" unless defaults == expected_defaults.to_i64
end

def w100o_validate_metadata(profile : W100OracleProfile, part : String, label : String, optional_observation : Bool = false) : JSON::Any
  info = JSON.parse(File.read(File.join(part, "serialization.json")))
  metadata = info.as_h
  raise "#{label}: serialization.json version is not 1" unless metadata["version"]?.try(&.as_i) == 1
  raise "#{label}: nested type-version propagation is false" unless metadata["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  records = metadata["columns"]?.try(&.as_a) || raise "#{label}: columns metadata missing"
  if records.empty?
    raise "#{label}: empty columns metadata not qualified for this profile" unless optional_observation
    puts "OBSERVED #{label}: legal serialization.json columns=[]; child counters not exposed"
    return info
  end

  if optional_observation
    puts "OBSERVED #{label}: serialization metadata is present; no child default counters assumed: #{info.to_json}"
    return info
  end

  names = records.map { |entry| entry.as_h["name"]?.try(&.as_s) || raise "#{label}: serializer name missing" }
  raise "#{label}: serializer roots/order differ: #{names.inspect}" unless names == ["payload", "pk"]
  payload = records[0].as_h
  w100o_validate_counter(payload, W100O_FULL_INDEXES.count { |index| w100o_tuple_default?(profile, index) }.to_i32, "#{label} Tuple root")
  children = payload["subcolumns"]?.try(&.as_a) || raise "#{label}: Tuple child counters missing"
  raise "#{label}: Tuple child count #{children.size}, expected #{profile.fields.size}" unless children.size == profile.fields.size
  profile.fields.each_with_index do |field, index|
    defaults = W100O_FULL_INDEXES.count { |row| w100o_field_default?(field, row) }.to_i32
    w100o_validate_counter(children[index].as_h, defaults, "#{label} child #{field.name}")
  end
  w100o_validate_counter(records[1].as_h, 0, "#{label} primary key")
  puts "OBSERVED #{label} serialization.json=#{info.to_json}"
  info
end

def w100o_expected_substreams(profile : W100OracleProfile) : String
  streams = w100o_expected_streams(profile).select { |stream| stream != "pk" }
  lines = [
    "columns substreams version: 1",
    "2 columns:",
    "1 substreams for column \x60pk\x60:",
    "\tpk",
    "#{streams.size} substreams for column \x60payload\x60:",
  ]
  streams.each { |stream| lines << "\t#{stream}" }
  lines.join("\n") + "\n"
end

def w100o_assert_layout(profile : W100OracleProfile, part : String, label : String, optional_empty_metadata : Bool = false) : Nil
  expected_columns = ["columns format version: 1", "2 columns:", "\x60pk\x60 UInt64", "\x60payload\x60 #{profile.type_name}"]
  actual_columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  raise "#{label}: columns.txt mismatch: #{actual_columns.inspect}" unless actual_columns == expected_columns
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  expected_substreams = w100o_expected_substreams(profile)
  raise "#{label}: columns_substreams.txt mismatch:\n#{actual_substreams}" unless actual_substreams == expected_substreams

  streams = w100o_expected_streams(profile)
  expected_bins = streams.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.bin" }.sort
  expected_marks = streams.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.mrk2" }.sort
  entries = Dir.children(part)
  actual_bins = entries.select(&.ends_with?(".bin")).sort
  actual_marks = entries.select(&.ends_with?(".mrk2")).sort
  raise "#{label}: complete .bin inventory mismatch: #{actual_bins.inspect}" unless actual_bins == expected_bins
  raise "#{label}: complete .mrk2 inventory mismatch: #{actual_marks.inspect}" unless actual_marks == expected_marks

  streams.each do |stream|
    observed_marks = w100o_mark_rows(part, stream)
    raise "#{label}: #{stream} mark rows #{observed_marks.inspect}, expected #{W100O_MARK_ROWS.inspect}" unless observed_marks == W100O_MARK_ROWS
    encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
    actual = CrystalClick::CompressedBlock.decode_all(encoded)
    expected = w100o_stream_expected(profile, stream).to_slice
    raise "#{label}: #{stream} full decoded bytes differ (#{actual.size} vs #{expected.size})" unless actual == expected
  end
  w100o_validate_metadata(profile, part, label, optional_empty_metadata)
  puts "PASS #{label}: exact logical schema/substreams, complete physical bytes, [2,2,1,0] marks and metadata policy"
end

def w100o_observe_date32_stats_profile(binary : String, store : String, profile : W100OracleProfile, part : String, raw : Int64, expected_defaults : Int32, label : String) : Nil
  w100o_schema(binary, store, profile.source_table, profile)
  expected_columns = ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{profile.type_name}"]
  actual_columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  raise "#{label}: columns.txt schema differs" unless actual_columns == expected_columns
  substreams = File.read(File.join(part, "columns_substreams.txt"))
  raise "#{label}: columns_substreams.txt header differs" unless substreams.starts_with?("columns substreams version: 1\n2 columns:\n")
  raise "#{label}: actual substream inventory omits key/Tuple roots" unless substreams.includes?("\tpk\n") && substreams.includes?("\tpayload%2Eevent")
  puts "OBSERVED #{label}: actual columns_substreams.txt:\n#{substreams}"
  expected_key_bin = "#{CrystalClick::StreamName.hash("pk")}.bin"
  expected_key_mark = "#{CrystalClick::StreamName.hash("pk")}.mrk2"
  entries = Dir.children(part)
  bins = entries.select(&.ends_with?(".bin")).sort
  marks = entries.select(&.ends_with?(".mrk2")).sort
  raise "#{label}: primary-key data stream missing" unless bins.includes?(expected_key_bin)
  raise "#{label}: primary-key mark stream missing" unless marks.includes?(expected_key_mark)
  puts "OBSERVED #{label}: actual .bin inventory=#{bins.inspect}; actual .mrk2 inventory=#{marks.inspect}"
  raise "#{label}: primary-key mark rows differ" unless w100o_mark_rows(part, "pk") == W100O_MARK_ROWS
  actual_pk = CrystalClick::CompressedBlock.decode_all(File.read(File.join(part, expected_key_bin)).to_slice)
  w100o_assert_bytes(String.new(actual_pk), W100O_KEYS.map { |key| w100o_u64_le(key) }.join, "#{label} independent primary-key physical bytes")

  child = "payload%2Eevent"
  child_bin = "#{CrystalClick::StreamName.hash(child)}.bin"
  child_streams = entries.select { |entry| entry.ends_with?(".bin") || entry.ends_with?(".mrk2") }.sort
  if bins.includes?(child_bin)
    puts "OBSERVED #{label}: child .bin present, #{File.size(File.join(part, child_bin))} bytes; no sparse physical decoding asserted"
  else
    puts "OBSERVED #{label}: child .bin absent; no sparse physical layout asserted"
  end
  puts "OBSERVED #{label}: actual data/mark stream inventory=#{child_streams.inspect}"

  info = JSON.parse(File.read(File.join(part, "serialization.json")))
  metadata = info.as_h
  raise "#{label}: serialization.json version is not 1" unless metadata["version"]?.try(&.as_i) == 1
  raise "#{label}: nested type-version propagation is false" unless metadata["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  records = info.as_h["columns"]?.try(&.as_a) || raise "#{label}: stats metadata columns not exposed"
  payload = records.find { |entry| entry.as_h["name"]?.try(&.as_s) == "payload" }.try(&.as_h) || raise "#{label}: Tuple statistics missing"
  child_info = payload["subcolumns"]?.try(&.as_a).try(&.first?).try(&.as_h) || raise "#{label}: Date32 child statistics missing"
  rows = child_info["num_rows"]?.try(&.as_i) || raise "#{label}: Date32 num_rows not exposed"
  defaults = child_info["num_defaults"]?.try(&.as_i) || raise "#{label}: Date32 num_defaults not exposed"
  raise "#{label}: child num_rows=#{rows}, expected 5" unless rows == W100O_KEYS.size.to_i64
  raise "#{label}: child num_defaults=#{defaults}, expected #{expected_defaults}" unless defaults == expected_defaults.to_i64
  puts "OBSERVED #{label}: Date32 raw=#{raw}, child num_defaults=#{defaults}, kind=#{child_info["kind"]?.try(&.as_s) || "unreported"}"

  actual_full = w100o_clickhouse(binary, store, "SELECT pk, payload.event FROM default.#{profile.source_table} ORDER BY pk FORMAT RowBinary")
  w100o_assert_bytes(actual_full, w100o_expected_rowbinary(profile, W100O_FULL_INDEXES), "#{label} stock full RowBinary")
  actual_key_range = w100o_clickhouse(binary, store, "SELECT pk, payload.event FROM default.#{profile.source_table} WHERE pk >= 2 AND pk < 5 ORDER BY pk FORMAT RowBinary")
  w100o_assert_bytes(actual_key_range, w100o_expected_rowbinary(profile, W100O_KEY_RANGE), "#{label} stock key-range RowBinary")
  w100o_check_table(binary, store, profile.source_table, part)
  puts "PASS #{label}: stock CHECK, full/key-range RowBinary and observed stats only; Sparse admission is not claimed"
end

def w100o_check_stock_sql(binary : String, store : String, profile : W100OracleProfile, table : String) : Nil
  fields = profile.fields.map { |field| "payload.#{field.name}" }
  selection = (["pk"] + fields).join(", ")
  full = w100o_clickhouse(binary, store, "SELECT #{selection} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w100o_assert_bytes(full, w100o_expected_rowbinary(profile, W100O_FULL_INDEXES), "#{table} stock full RowBinary")
  selected = w100o_clickhouse(binary, store, "SELECT #{selection} FROM default.#{table} WHERE pk >= 2 AND pk < 5 ORDER BY pk FORMAT RowBinary")
  w100o_assert_bytes(selected, w100o_expected_rowbinary(profile, W100O_KEY_RANGE), "#{table} stock independent SQL key-range RowBinary")
  puts "PASS #{table}: independent stock full and SQL key-range RowBinary"
  nil
end

def w100o_check_stock_profile(binary : String, store : String, profile : W100OracleProfile, label : String, optional_metadata_observation : Bool = false) : String
  w100o_create_table(binary, store, profile.source_table, profile)
  w100o_insert(binary, store, profile.source_table, profile)
  part = w100o_part_path(binary, store, profile.source_table)
  w100o_schema(binary, store, profile.source_table, profile)
  w100o_assert_layout(profile, part, label, optional_metadata_observation)
  w100o_check_table(binary, store, profile.source_table, part)
  w100o_check_stock_sql(binary, store, profile, profile.source_table)
  part
end

def w100o_actual_physical(field : W100OracleField, column : CrystalClick::WideTupleLeafColumn, row : Int32) : String
  case field.type_name
  when "Date"
    w100o_u64_le(column.value_at(row, CrystalClick::DateValue).raw.to_u64, 2)
  when "Date32"
    w100o_i64_le(column.value_at(row, CrystalClick::Date32Value).raw.to_i64, 4)
  when "DateTime"
    w100o_u64_le(column.value_at(row, CrystalClick::DateTimeValue).raw.to_u64, 4)
  when "Time"
    w100o_i64_le(column.value_at(row, CrystalClick::TimeValue).raw.to_i64, 4)
  when .starts_with?("DateTime64(")
    value = column.value_at(row, CrystalClick::DateTime64Value)
    raise "#{field.name}: DateTime64 precision changed" unless value.precision.to_i32 == w100o_precision(field.type_name)
    w100o_i64_le(value.raw)
  when .starts_with?("Time64(")
    value = column.value_at(row, CrystalClick::Time64Value)
    raise "#{field.name}: Time64 precision changed" unless value.precision.to_i32 == w100o_precision(field.type_name)
    w100o_i64_le(value.raw)
  when "UInt64"
    w100o_u64_le(column.value_at(row, UInt64))
  when "Bool"
    column.value_at(row, Bool) ? "\x01" : "\x00"
  when "String"
    column.value_at(row, String)
  when "UUID"
    value = column.value_at(row, CrystalClick::UUIDValue)
    w100o_u64_le(value.high) + w100o_u64_le(value.low)
  when "IPv4"
    w100o_u64_le(column.value_at(row, CrystalClick::IPv4Value).network_order.to_u64, 4)
  else
    raise "no exact nominal physical encoder for #{field.type_name}"
  end
end

def w100o_actual_row_physical(field : W100OracleField, row : CrystalClick::WideTupleRow) : String
  case field.type_name
  when "Date"
    w100o_u64_le(row.value_as(field.name, CrystalClick::DateValue).raw.to_u64, 2)
  when "Date32"
    w100o_i64_le(row.value_as(field.name, CrystalClick::Date32Value).raw.to_i64, 4)
  when "DateTime"
    w100o_u64_le(row.value_as(field.name, CrystalClick::DateTimeValue).raw.to_u64, 4)
  when "Time"
    w100o_i64_le(row.value_as(field.name, CrystalClick::TimeValue).raw.to_i64, 4)
  when .starts_with?("DateTime64(")
    value = row.value_as(field.name, CrystalClick::DateTime64Value)
    raise "#{field.name}: row DateTime64 precision changed" unless value.precision.to_i32 == w100o_precision(field.type_name)
    w100o_i64_le(value.raw)
  when .starts_with?("Time64(")
    value = row.value_as(field.name, CrystalClick::Time64Value)
    raise "#{field.name}: row Time64 precision changed" unless value.precision.to_i32 == w100o_precision(field.type_name)
    w100o_i64_le(value.raw)
  when "UInt64"
    w100o_u64_le(row.value_as(field.name, UInt64))
  when "Bool"
    row.value_as(field.name, Bool) ? "\x01" : "\x00"
  when "String"
    row.value_as(field.name, String)
  when "UUID"
    value = row.value_as(field.name, CrystalClick::UUIDValue)
    w100o_u64_le(value.high) + w100o_u64_le(value.low)
  when "IPv4"
    w100o_u64_le(row.value_as(field.name, CrystalClick::IPv4Value).network_order.to_u64, 4)
  else
    raise "no exact nominal row encoder for #{field.type_name}"
  end
end

def w100o_expected_payload_rowbinary(profile : W100OracleProfile, indexes : Array(Int32)) : String
  output = IO::Memory.new
  indexes.each do |index|
    profile.fields.each { |field| output << field.rowbinary_rows[index] }
  end
  output.to_s
end

def w100o_assert_data(data : CrystalClick::WideTupleColumnData, profile : W100OracleProfile, indexes : Array(Int32), label : String) : Nil
  raise "#{label}: Tuple schema differs" unless data.type_name == profile.type_name
  raise "#{label}: Tuple row count differs" unless data.row_count == indexes.size
  expected_schema = profile.fields.map { |field| {field.name, field.type_name} }
  raise "#{label}: nominal field order/type differs" unless data.fields.map { |field| {field.name, field.type_name} } == expected_schema
  actual_columns = data.columns
  profile.fields.each_with_index do |field, field_index|
    indexes.each_with_index do |source_index, output_index|
      expected = field.expected_rows[source_index]
      actual = w100o_actual_physical(field, actual_columns[field_index], output_index.to_i32)
      raise "#{label}: #{field.name} exact raw value differs at source row #{source_index}" unless actual == expected
    end
  end
  nil
end

def w100o_append_rowbinary_value(output : IO, field : W100OracleField, actual_physical : String) : Nil
  if field.string?
    output << w100o_varuint(actual_physical.bytesize.to_u64) << actual_physical
  else
    output << actual_physical
  end
  nil
end

def w100o_actual_rowbinary(data : CrystalClick::WideTupleColumnData, profile : W100OracleProfile, indexes : Array(Int32), keys : Array(UInt64), label : String) : String
  output = IO::Memory.new
  columns = data.columns
  raise "#{label}: keys/rows differ" unless keys.size == indexes.size
  keys.each_with_index do |key, output_index|
    output << w100o_u64_le(key)
    profile.fields.each_with_index do |field, field_index|
      w100o_append_rowbinary_value(output, field, w100o_actual_physical(field, columns[field_index], output_index.to_i32))
    end
  end
  output.to_s
end

def w100o_check_source_reader(part : String, profile : W100OracleProfile, label : String) : CrystalClick::WideTupleColumnData
  key_reader = CrystalClick::WidePart.open_typed(part, "pk")
  tuple_reader = CrystalClick::WidePart.open_typed(part, "payload")
  expected_marks = [2_u64, 2_u64, 1_u64]
  raise "#{label}: key mark rows differ" unless key_reader.mark_row_counts == expected_marks
  raise "#{label}: Tuple mark rows differ" unless tuple_reader.mark_row_counts == expected_marks
  keys = key_reader.read_uint64_mark_range("pk", 0, key_reader.mark_count)
  data = tuple_reader.read_tuple_mark_range("payload", 0, tuple_reader.mark_count)
  w100o_assert_data(data, profile, W100O_FULL_INDEXES, "#{label} full read")
  w100o_assert_bytes(
    w100o_actual_rowbinary(data, profile, W100O_FULL_INDEXES, keys, label),
    w100o_expected_rowbinary(profile, W100O_FULL_INDEXES),
    "#{label} stock -> Crystal full RowBinary"
  )

  # Marks [1,3) select physical rows 3,4,5; the SQL predicate above selects
  # keys 2,3,4, so these independent selection paths must not be conflated.
  selected_keys = key_reader.read_uint64_mark_range("pk", 1, 2)
  selected = tuple_reader.read_tuple_mark_range("payload", 1, 2)
  w100o_assert_data(selected, profile, W100O_MARK_RANGE, "#{label} selected physical mark range")
  w100o_assert_bytes(
    w100o_actual_rowbinary(selected, profile, W100O_MARK_RANGE, selected_keys, label),
    w100o_expected_rowbinary(profile, W100O_MARK_RANGE),
    "#{label} selected physical mark-range RowBinary"
  )
  puts "PASS #{label}: exact nominal values plus independent physical mark range rows [3,4,5]"
  data
end

def w100o_append_table_batch(output : IO, batch : CrystalClick::WidePartTableBatch, profile : W100OracleProfile, allowed_indexes : Array(Int32), label : String) : Array(Int32)
  keys = batch.values_for("pk")
  rows = batch.tuple_rows_for("payload")
  raise "#{label}: batch key/row counts differ" unless keys.size == rows.size
  indexes = [] of Int32
  keys.each_with_index do |key, offset|
    raise "#{label}: invalid source key #{key}" unless key >= 1_u64 && key <= W100O_KEYS.size.to_u64
    source_index = (key - 1_u64).to_i32
    raise "#{label}: unexpected source row #{source_index}" unless allowed_indexes.includes?(source_index)
    indexes << source_index
    row = rows[offset]
    raise "#{label}: exact Tuple schema differs" unless row.type_name == profile.type_name
    output << w100o_u64_le(key)
    profile.fields.each do |field|
      actual = w100o_actual_row_physical(field, row)
      w100o_assert_bytes(actual, field.expected_rows[source_index], "#{label} #{field.name} source row #{source_index}")
      w100o_append_rowbinary_value(output, field, actual)
    end
  end
  indexes
end

def w100o_check_table_consumers(part : String, profile : W100OracleProfile, label : String) : Nil
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])

  full = IO::Memory.new
  full_seen = [] of Int32
  table.scan_typed do |batch|
    full_seen.concat(w100o_append_table_batch(full, batch, profile, W100O_FULL_INDEXES, "#{label} table full"))
    nil
  end
  raise "#{label}: full table rows differ: #{full_seen.inspect}" unless full_seen == W100O_FULL_INDEXES
  w100o_assert_bytes(full.to_s, w100o_expected_rowbinary(profile, W100O_FULL_INDEXES), "#{label} table full RowBinary")

  window = IO::Memory.new
  window_seen = [] of Int32
  table.scan_typed_window(1_u64, 3) do |batch|
    window_seen.concat(w100o_append_table_batch(window, batch, profile, W100O_WINDOW, "#{label} table window"))
    nil
  end
  raise "#{label}: table window rows differ: #{window_seen.inspect}" unless window_seen == W100O_WINDOW
  w100o_assert_bytes(window.to_s, w100o_expected_rowbinary(profile, W100O_WINDOW), "#{label} table positional window")

  candidate = IO::Memory.new
  candidate_seen = [] of Int32
  table.scan_typed_candidate_marks([[1_i32, 2_i32]]) do |batch|
    candidate_seen.concat(w100o_append_table_batch(candidate, batch, profile, W100O_CANDIDATE, "#{label} table candidate mark"))
    nil
  end
  raise "#{label}: candidate physical rows differ: #{candidate_seen.inspect}" unless candidate_seen == W100O_CANDIDATE
  w100o_assert_bytes(candidate.to_s, w100o_expected_rowbinary(profile, W100O_CANDIDATE), "#{label} candidate marks 1,2 physical rows [3,4,5]")
  puts "PASS #{label}: table full/window and candidate marks 1,2 rows [3,4,5], exact nominal access"
  nil
end

def w100o_prepare_catalog_root(root : String, part : String, profile : W100OracleProfile) : String
  database_uuid = "10000000-0000-4000-8000-000000000001"
  table_uuid = "10000000-0000-4000-8000-000000000002"
  metadata_path = File.join(root, "metadata")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata_path)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(metadata_path, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{profile.type_name}\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  copied = File.join(table_path, "all_1_1_0")
  FileUtils.cp_r(part, copied)
  copied
end

def w100o_check_catalog_consumers(root : String, part : String, profile : W100OracleProfile, label : String) : Nil
  copied = w100o_prepare_catalog_root(root, part, profile)
  table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
  parts = table.resolved_scan_parts
  raise "#{label}: catalog did not resolve its copied part" unless parts.size == 1 && File.realpath(parts[0].path) == File.realpath(copied)

  values = table["payload"].values(max_tuple_cells: 1_000_u64)
  raise "#{label}: catalog full value count differs" unless values.size == W100O_KEYS.size
  payload = IO::Memory.new
  values.each_with_index do |value, row_index|
    row = value.as(CrystalClick::WideTupleRow)
    raise "#{label}: catalog Tuple schema differs" unless row.type_name == profile.type_name
    profile.fields.each do |field|
      actual = w100o_actual_row_physical(field, row)
      w100o_assert_bytes(actual, field.expected_rows[row_index], "#{label} catalog #{field.name} row #{row_index}")
      w100o_append_rowbinary_value(payload, field, actual)
    end
  end
  w100o_assert_bytes(payload.to_s, w100o_expected_payload_rowbinary(profile, W100O_FULL_INDEXES), "#{label} catalog full values")

  scan = IO::Memory.new
  table_seen = [] of Int32
  table.scan_typed(["pk", "payload"]) do |batch|
    table_seen.concat(w100o_append_table_batch(scan, batch, profile, W100O_FULL_INDEXES, "#{label} catalog full scan"))
    nil
  end
  raise "#{label}: catalog scan rows differ: #{table_seen.inspect}" unless table_seen == W100O_FULL_INDEXES
  w100o_assert_bytes(scan.to_s, w100o_expected_rowbinary(profile, W100O_FULL_INDEXES), "#{label} catalog full scan")

  window = IO::Memory.new
  window_seen = [] of Int32
  table.scan_typed_window(["pk", "payload"], 1_u64, 3) do |batch|
    window_seen.concat(w100o_append_table_batch(window, batch, profile, W100O_WINDOW, "#{label} catalog window"))
    nil
  end
  raise "#{label}: catalog window rows differ: #{window_seen.inspect}" unless window_seen == W100O_WINDOW
  w100o_assert_bytes(window.to_s, w100o_expected_rowbinary(profile, W100O_WINDOW), "#{label} catalog positional window")
  puts "PASS #{label}: catalog values, full scan and positional window retain exact nominal values"
  nil
end

def w100o_attach_stock_part(binary : String, store : String, profile : W100OracleProfile, table : String, part : String) : String
  w100o_create_table(binary, store, table, profile)
  data_path = w100o_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse did not return a data path" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w100o_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  attached = w100o_part_path(binary, store, table)
  w100o_schema(binary, store, table, profile)
  w100o_check_table(binary, store, table, attached)
  attached
end

def w100o_attach_writer(binary : String, store : String, profile : W100OracleProfile, part : String) : String
  w100o_attach_stock_part(binary, store, profile, profile.writer_table, part)
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["TEMPORAL_TUPLE_STORE"]? || raise "set TEMPORAL_TUPLE_STORE to a fresh temporary ClickHouse store"
writer_root = ENV["TEMPORAL_TUPLE_WRITER_ROOT"]? || raise "set TEMPORAL_TUPLE_WRITER_ROOT to an empty temporary directory"
catalog_root = ENV["TEMPORAL_TUPLE_CATALOG_ROOT"]? || raise "set TEMPORAL_TUPLE_CATALOG_ROOT to an empty temporary directory"
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary ClickHouse store path: #{store}"
end
raise "ClickHouse store must be fresh and empty" unless Dir.exists?(store) && Dir.empty?(store)
raise "writer output root must be empty" unless Dir.exists?(writer_root) && Dir.empty?(writer_root)
raise "catalog root must be empty" unless Dir.exists?(catalog_root) && Dir.empty?(catalog_root)

version = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version)
raise "cannot inspect pinned ClickHouse version" unless version_status.success?
expected_version = "ClickHouse local version #{W100O_VERSION} (official build)."
raise "expected #{expected_version}, got #{version.to_s.strip}" unless version.to_s.strip == expected_version
puts "Stock oracle: #{version.to_s.strip}"

legacy = w100o_legacy_positive_control
singleton_profiles = w100o_singleton_profiles
mixed = w100o_mixed_profile
zero = w100o_zero_profile
date32_raw_zero = w100o_date32_default_profile("date32_raw_zero", 0_i64)
date32_sql_default = w100o_date32_default_profile("date32_sql_default", -25_567_i64)

# Preserve the established non-temporal Tuple as a positive reader control
# before applying the same reader path to any temporal declaration.
legacy_part = w100o_check_stock_profile(binary, store, legacy, "legacy Tuple positive control")
w100o_check_source_reader(legacy_part, legacy, "legacy Tuple positive control")

source_parts = {} of String => String
source_data_by_profile = {} of String => CrystalClick::WideTupleColumnData
profiles = singleton_profiles + [mixed, zero, date32_raw_zero, date32_sql_default]
profiles.each do |profile|
  optional_metadata_observation = profile.ratio == "1.0"
  part = w100o_check_stock_profile(binary, store, profile, profile.label, optional_metadata_observation)
  source_parts[profile.label] = part
  source_data = w100o_check_source_reader(part, profile, "stock source #{profile.label}")
  source_data_by_profile[profile.label] = source_data
  if profile.label == "mixed"
    actual = w100o_clickhouse(
      binary,
      store,
      "SELECT pk, #{profile.fields.map { |field| "payload.#{field.name}" }.join(", ")} FROM default.#{profile.source_table} ORDER BY pk FORMAT RowBinary"
    )
    w100o_seeded_wrong_expectation_rejected(
      actual,
      w100o_expected_rowbinary(profile, W100O_FULL_INDEXES),
      "stock mixed RowBinary comparator"
    )

    writer_part = File.join(writer_root, "mixed", "all_1_1_0")
    FileUtils.mkdir_p(File.dirname(writer_part))
    key_reader = CrystalClick::WidePart.open_typed(part, "pk")
    keys = key_reader.read_uint64_mark_range("pk", 0, key_reader.mark_count)
    CrystalClick::WidePartWriter.write_uint64_tuple_pair(
      writer_part,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      profile.type_name,
      source_data.columns,
      rows_per_mark: 2
    )
    w100o_assert_layout(profile, writer_part, "Crystal writer mixed")
    w100o_check_source_reader(writer_part, profile, "Crystal writer mixed")

    attached = w100o_attach_writer(binary, store, profile, writer_part)
    w100o_assert_layout(profile, attached, "attached Crystal writer mixed")
    w100o_check_stock_sql(binary, store, profile, profile.writer_table)
    w100o_check_table(binary, store, profile.writer_table, attached)
    w100o_check_table_consumers(attached, profile, "attached Crystal writer mixed")
    w100o_check_catalog_consumers(File.join(catalog_root, "mixed-writer"), attached, profile, "attached Crystal writer mixed")
    puts "PASS W100 bidirectional mixed: stock -> exact reader -> writer from stock-decoded columns -> ATTACH/CHECK -> table/catalog consumers"
  end
end

# Ratio-1 Crystal-written parts exercise the writer's explicit default
# counters and stock's native ATTACH path. Their values and keys come from the
# separately validated stock-created source parts above.
[zero, date32_raw_zero, date32_sql_default].each do |profile|
  source_part = source_parts[profile.label]
  source_data = source_data_by_profile[profile.label]
  writer_part = File.join(writer_root, profile.label, "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(writer_part))
  key_reader = CrystalClick::WidePart.open_typed(source_part, "pk")
  keys = key_reader.read_uint64_mark_range("pk", 0, key_reader.mark_count)
  CrystalClick::WidePartWriter.write_uint64_tuple_pair(
    writer_part,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    profile.type_name,
    source_data.columns,
    rows_per_mark: 2
  )
  w100o_assert_layout(profile, writer_part, "Crystal writer #{profile.label}")
  w100o_check_source_reader(writer_part, profile, "Crystal writer #{profile.label}")
  attached = w100o_attach_writer(binary, store, profile, writer_part)
  w100o_assert_layout(profile, attached, "attached Crystal writer #{profile.label}")
  w100o_check_stock_sql(binary, store, profile, profile.writer_table)
  w100o_check_table(binary, store, profile.writer_table, attached)
  puts "PASS Crystal writer #{profile.label}: stock-decoded values -> exact native bytes/counts -> ATTACH/CHECK and full/key-range RowBinary"
end

date32_stats_zero = w100o_date32_default_profile("date32_stats_raw_zero", 0_i64, "0.9375")
date32_stats_type_default = w100o_date32_default_profile("date32_stats_sql_default", -25_567_i64, "0.9375")
[
  {date32_stats_zero, 0_i64, 5_i32},
  {date32_stats_type_default, -25_567_i64, 0_i32},
].each do |profile, raw, expected_defaults|
  w100o_create_table(binary, store, profile.source_table, profile)
  w100o_insert(binary, store, profile.source_table, profile)
  part = w100o_part_path(binary, store, profile.source_table)
  w100o_observe_date32_stats_profile(binary, store, profile, part, raw, expected_defaults, profile.label)
end

puts "PASS temporal named-flat Tuple stock oracle: all 24 declarations, mixed/reordered/repeated composition, ratio-1 allzero and Date32 profiles, separate raw-default statistics controls, independent bytes/RowBinary, full/selected reads, writer round trip, ATTACH/CHECK and table/catalog consumers"
