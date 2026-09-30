# W101 stock-first discriminator for the unchanged 4303639 predecessor.
# The stock fixtures and their expected bytes are qualified independently of
# the missing Tuple type parser. Exit 1 at the final marker is the expected
# current-reader RED; any earlier error is an unqualified instrument failure.
require "json"
require "set"
require "../src/crystal_click"

W101_STOCK_VERSION = "26.7.1.1315"
W101_EXPECTED_HEAD = "4303639b1cfd9613c4e68e97be45a90a119bcf91"
W101_KEYS          = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W101_FULL          = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32]
W101_KEY_RANGE     = [1_i32, 2_i32, 3_i32]
W101_MARK_ROWS     = [2_u64, 2_u64, 1_u64, 0_u64]

struct W101EnumPair
  getter code : Int32
  getter label : String

  def initialize(@code : Int32, @label : String)
  end
end

struct W101Field
  getter name : String
  getter input_type : String
  getter canonical_type : String
  getter width : Int32
  getter rows : Array(String)

  def initialize(
    @name : String,
    @input_type : String,
    @canonical_type : String,
    @width : Int32,
    rows : Array(String),
  )
    raise "#{@name}: empty Tuple field name" if @name.empty?
    raise "#{@name}: nonpositive physical width" unless @width > 0
    raise "#{@name}: expected five raw rows" unless rows.size == W101_KEYS.size
    rows.each_with_index do |row, index|
      raise "#{@name}: row #{index} has #{row.bytesize} bytes, expected #{@width}" unless row.bytesize == @width
    end
    @rows = rows.dup
  end

  def storage_default_count : Int32
    @rows.count { |row| w101_all_zero?(row) }
  end

  def row_default?(index : Int32) : Bool
    w101_all_zero?(@rows[index])
  end
end

struct W101Profile
  getter label : String
  getter fields : Array(W101Field)
  getter ratio : String

  def initialize(@label : String, fields : Array(W101Field), @ratio : String = "1.0")
    raise "#{@label}: Tuple fixture must be nonempty" if fields.empty?
    names = Set(String).new
    fields.each do |field|
      raise "#{@label}: duplicate child name #{field.name}" unless names.add?(field.name)
    end
    @fields = fields.dup
  end

  def input_type_name : String
    "Tuple(#{@fields.map { |field| "#{field.name} #{field.input_type}" }.join(", ")})"
  end

  def canonical_type_name : String
    "Tuple(#{@fields.map { |field| "#{field.name} #{field.canonical_type}" }.join(", ")})"
  end

  def table_name : String
    "w101_#{@label}"
  end

  def streams : Array(String)
    ["pk"] + @fields.map { |field| "payload%2E#{field.name}" }
  end

  def expected_rowbinary(indexes : Array(Int32)) : String
    output = IO::Memory.new
    indexes.each do |index|
      output << w101_unsigned_le(W101_KEYS[index], 8)
      @fields.each { |field| output << field.rows[index] }
    end
    output.to_s
  end

  def expected_stream(stream : String) : String
    return W101_KEYS.map { |key| w101_unsigned_le(key, 8) }.join if stream == "pk"
    field = @fields.find { |entry| "payload%2E#{entry.name}" == stream }
    raise "#{@label}: no raw bytes for stream #{stream.inspect}" unless field
    field.rows.join
  end

  def tuple_default_count : Int32
    W101_FULL.count { |index| @fields.all? { |field| field.row_default?(index) } }
  end
end

class W101ByteMismatchError < Exception
end

def w101_all_zero?(bytes : String) : Bool
  bytes.to_slice.all?(&.==(0_u8))
end

def w101_unsigned_le(value : UInt64, width : Int32) : String
  output = IO::Memory.new
  width.times { |index| output.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
  output.to_s
end

def w101_signed_le(value : Int64, width : Int32) : String
  w101_unsigned_le(value.unsafe_as(UInt64), width)
end

def w101_negate_twos_complement(positive : Array(UInt8)) : Array(UInt8)
  negative = positive.map { |byte| ~byte }
  carry = 1_u16
  negative.each_index do |index|
    value = negative[index].to_u16 + carry
    negative[index] = (value & 0xff_u16).to_u8
    carry = value >> 8
  end
  raise "W101 two's-complement negation overflow" unless carry == 0
  negative
end

def w101_decimal_max_coefficient(precision : Int32, width : Int32) : Array(UInt8)
  bytes = Array(UInt8).new(width, 0_u8)
  precision.times do
    carry = 9_u16
    bytes.each_index do |index|
      value = bytes[index].to_u16 * 10_u16 + carry
      bytes[index] = (value & 0xff_u16).to_u8
      carry = value >> 8
    end
    raise "W101 decimal max coefficient overflow for P=#{precision}" unless carry == 0
  end
  bytes
end

def w101_string_from_bytes(bytes : Array(UInt8)) : String
  return "" if bytes.empty?
  String.new(bytes.to_unsafe, bytes.size)
end

def w101_decimal_rows(precision : Int32, width : Int32) : Array(String)
  positive_max = w101_decimal_max_coefficient(precision, width)
  negative_max = w101_negate_twos_complement(positive_max)
  negative_one = Array(UInt8).new(width, 0xff_u8)
  zero = Array(UInt8).new(width, 0_u8)
  positive_one = Array(UInt8).new(width, 0_u8)
  positive_one[0] = 1_u8
  [negative_max, negative_one, zero, positive_one, positive_max].map { |bytes| w101_string_from_bytes(bytes) }
end

def w101_carrier_extrema(width : Int32) : Array(String)
  minimum = Array(UInt8).new(width, 0_u8)
  minimum[width - 1] = 0x80_u8
  maximum = Array(UInt8).new(width, 0xff_u8)
  maximum[width - 1] = 0x7f_u8
  negative_one = Array(UInt8).new(width, 0xff_u8)
  zero = Array(UInt8).new(width, 0_u8)
  positive_one = Array(UInt8).new(width, 0_u8)
  positive_one[0] = 1_u8
  [minimum, negative_one, zero, positive_one, maximum].map { |bytes| w101_string_from_bytes(bytes) }
end

def w101_fixed_bytes(value : String, width : Int32) : String
  raise "FixedString input is wider than N=#{width}" if value.bytesize > width
  output = IO::Memory.new
  output << value
  (width - value.bytesize).times { output.write_byte(0_u8) }
  output.to_s
end

def w101_fixed_hex(value : String) : String
  value.to_slice.map { |byte| byte.to_s(16).rjust(2, '0') }.join
end

def w101_quote_enum_label(label : String) : String
  String.build do |output|
    output << '\''
    label.to_slice.each do |byte|
      if byte == '\''.ord.to_u8
        output << "\\'"
      elsif byte == '\\'.ord.to_u8
        output << "\\\\"
      elsif byte == 0x08_u8
        output << "\\b"
      elsif byte == 0x0c_u8
        output << "\\f"
      elsif byte == 0x0a_u8
        output << "\\n"
      elsif byte == 0x0d_u8
        output << "\\r"
      elsif byte == 0x09_u8
        output << "\\t"
      elsif byte == 0x00_u8
        output << "\\0"
      else
        output.write_byte(byte)
      end
    end
    output << '\''
  end
end

def w101_enum_type(family : String, pairs : Array(W101EnumPair), declaration_order : Array(W101EnumPair)) : String
  body = declaration_order.map { |pair| "#{w101_quote_enum_label(pair.label)} = #{pair.code}" }.join(", ")
  "#{family}(#{body})"
end

def w101_enum_canonical_type(family : String, pairs : Array(W101EnumPair)) : String
  sorted = pairs.sort_by(&.code)
  body = sorted.map { |pair| "#{w101_quote_enum_label(pair.label)} = #{pair.code}" }.join(", ")
  "#{family}(#{body})"
end

W101_ENUM8_PAIRS = [
  W101EnumPair.new(-128, "min8"),
  W101EnumPair.new(-127, "quote'x"),
  W101EnumPair.new(-126, "back\\slash"),
  W101EnumPair.new(-125, "b\b"),
  W101EnumPair.new(-124, "f\f"),
  W101EnumPair.new(-123, "n\n"),
  W101EnumPair.new(-122, "r\r"),
  W101EnumPair.new(-121, "t\t"),
  W101EnumPair.new(-120, "z\0"),
  W101EnumPair.new(-119, ""),
  W101EnumPair.new(-118, "café"),
  W101EnumPair.new(-117, ",=(x)"),
  W101EnumPair.new(-116, "SELECT"),
  W101EnumPair.new(-7, "negative-seven"),
  W101EnumPair.new(-1, "negative-one"),
  W101EnumPair.new(0, "zero8"),
  W101EnumPair.new(127, "max8"),
]

W101_ENUM16_PAIRS = [
  W101EnumPair.new(-32768, "min16"),
  W101EnumPair.new(-30000, "quote'x16"),
  W101EnumPair.new(-20000, "back\\slash16"),
  W101EnumPair.new(-10000, "b\b16"),
  W101EnumPair.new(-5000, "f\f16"),
  W101EnumPair.new(-1000, "n\n16"),
  W101EnumPair.new(-100, "r\r16"),
  W101EnumPair.new(-10, "t\t16"),
  W101EnumPair.new(-1, "empty-adjacent"),
  W101EnumPair.new(0, "zero16"),
  W101EnumPair.new(1, "z\0"),
  W101EnumPair.new(2, ""),
  W101EnumPair.new(3, "café16"),
  W101EnumPair.new(42, "a,b=(c)"),
  W101EnumPair.new(30000, "SELECT16"),
  W101EnumPair.new(32767, "max16"),
]

def w101_enum_field(name : String, family : String, pairs : Array(W101EnumPair), codes : Array(Int32)) : W101Field
  raise "#{name}: duplicate Enum label" unless pairs.map(&.label).uniq.size == pairs.size
  raise "#{name}: duplicate Enum code" unless pairs.map(&.code).uniq.size == pairs.size
  codes.each do |code|
    raise "#{name}: undeclared Enum code #{code}" unless pairs.any? { |pair| pair.code == code }
  end
  width = family == "Enum8" ? 1 : 2
  input_type = w101_enum_type(family, pairs, pairs.reverse)
  canonical_type = w101_enum_canonical_type(family, pairs)
  rows = codes.map { |code| w101_signed_le(code.to_i64, width) }
  W101Field.new(name, input_type, canonical_type, width, rows)
end

def w101_fixed_field(name : String, width : Int32, inputs : Array(String)) : W101Field
  type_name = "FixedString(#{width})"
  rows = inputs.map { |value| w101_fixed_bytes(value, width) }
  W101Field.new(name, type_name, type_name, width, rows)
end

def w101_decimal_width(precision : Int32) : Int32
  return 4 if precision <= 9
  return 8 if precision <= 18
  return 16 if precision <= 38
  32
end

def w101_decimal_field(name : String, precision : Int32, scale : Int32, input_type : String) : W101Field
  width = w101_decimal_width(precision)
  W101Field.new(name, input_type, "Decimal(#{precision}, #{scale})", width, w101_decimal_rows(precision, width))
end

def w101_fixed_inputs(width : Int32) : Array(String)
  if width == 1
    ["", "\0", "A", "\xff", "z"]
  else
    ["a", "x\0yZ", "é", "\0\xff", "ABCD"]
  end
end

def w101_decimal_matrix : Array(W101Field)
  fields = [] of W101Field
  [1, 9, 10, 18, 19, 38, 39, 76].each do |precision|
    [0, precision].uniq.each do |scale|
      fields << w101_decimal_field("d_p#{precision}_s#{scale}", precision, scale, "Decimal(#{precision}, #{scale})")
    end
  end

  [
    {"d_p3_s1", 3, 1},
    {"d_p14_s7", 14, 7},
    {"d_p32_s16", 32, 16},
    {"d_p60_s30", 60, 30},
  ].each do |label, precision, scale|
    fields << w101_decimal_field(label, precision, scale, "Decimal(#{precision}, #{scale})")
  end

  [
    {"Decimal32", 9, 9},
    {"Decimal64", 18, 18},
    {"Decimal128", 38, 38},
    {"Decimal256", 76, 76},
  ].each do |family, precision, max_scale|
    [0, max_scale].uniq.each do |scale|
      fields << w101_decimal_field("a_#{family.downcase}_s#{scale}", precision, scale, "#{family}(#{scale})")
    end
  end

  fields << w101_decimal_field("d_p9_implicit_s0", 9, 0, "Decimal(9)")
  fields << w101_decimal_field("d_bare_s0", 10, 0, "Decimal")
  fields
end

def w101_primary_fields : Array(W101Field)
  fields = [] of W101Field
  fields << w101_fixed_field("fixed1", 1, w101_fixed_inputs(1))
  fields << w101_fixed_field("fixed4", 4, w101_fixed_inputs(4))
  fields << w101_enum_field("enum8", "Enum8", W101_ENUM8_PAIRS, [-128, -1, 0, 127, -7])
  fields << w101_enum_field("enum16", "Enum16", W101_ENUM16_PAIRS, [-32768, -30000, 0, 32767, 42])
  fields.concat(w101_decimal_matrix)
  fields
end

def w101_zero_profile(profile : W101Profile, label : String) : W101Profile
  zeros = profile.fields.map do |field|
    row = String.new(Bytes.new(field.width, 0_u8))
    W101Field.new(field.name, field.input_type, field.canonical_type, field.width, Array.new(W101_KEYS.size, row))
  end
  W101Profile.new(label, zeros, "1.0")
end

def w101_attempt_clickhouse(binary : String, store : String, query : String, input : IO? = nil) : {Bool, String, String}
  output = IO::Memory.new
  error = IO::Memory.new
  status = if input
             Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  {status.success?, output.to_s, error.to_s}
end

def w101_clickhouse(binary : String, store : String, query : String, input : IO? = nil) : String
  succeeded, output, error = w101_attempt_clickhouse(binary, store, query, input)
  raise "ClickHouse local failed: #{error}\n#{query}" unless succeeded
  output
end

def w101_settings(ratio : String) : String
  "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = #{ratio}, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"
end

def w101_create_table(binary : String, store : String, profile : W101Profile) : Nil
  w101_clickhouse(
    binary,
    store,
    "CREATE TABLE default.#{profile.table_name} (pk UInt64, payload #{profile.input_type_name}) ENGINE = MergeTree ORDER BY pk SETTINGS #{w101_settings(profile.ratio)}"
  )
  nil
end

def w101_rowbinary_input(profile : W101Profile) : String
  profile.expected_rowbinary(W101_FULL)
end

def w101_insert_rowbinary(binary : String, store : String, profile : W101Profile) : Nil
  input = IO::Memory.new(w101_rowbinary_input(profile).to_slice)
  w101_clickhouse(binary, store, "INSERT INTO default.#{profile.table_name} FORMAT RowBinary", input)
  nil
end

def w101_fixed_sql_insert(table : String, width : Int32, inputs : Array(String)) : String
  values = inputs.each_with_index.map do |value, index|
    "(#{index + 1}, '#{w101_fixed_hex(value)}')"
  end.join(", ")
  "INSERT INTO default.#{table} SELECT pk, tuple(toFixedString(unhex(raw), #{width})) FROM values('pk UInt64, raw String', #{values})"
end

def w101_part_path(binary : String, store : String, table : String) : String
  lines = w101_clickhouse(
    binary,
    store,
    "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw"
  ).lines.map(&.strip).reject(&.empty?)
  raise "#{table}: expected one active part, got #{lines.inspect}" unless lines.size == 1
  columns = lines[0].split('\t')
  raise "#{table}: malformed part row #{lines[0].inspect}" unless columns.size == 3
  raise "#{table}: expected Wide part, got #{columns[1]}" unless columns[1] == "Wide"
  raise "#{table}: expected five rows, got #{columns[2]}" unless columns[2] == W101_KEYS.size.to_s
  columns[0]
end

def w101_schema(binary : String, store : String, profile : W101Profile) : Nil
  actual = w101_clickhouse(
    binary,
    store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{profile.table_name}' ORDER BY position FORMAT TSVRaw"
  ).lines.map(&.strip)
  expected = ["pk UInt64", "payload #{profile.canonical_type_name}"]
  raise "#{profile.label}: stock system.columns differs: #{actual.inspect}" unless actual == expected
  nil
end

def w101_mark_rows(part : String, stream : String) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{stream}: partial .mrk2 row" unless bytes.size % mark_size == 0
  Array(UInt64).new(bytes.size // mark_size) do |index|
    offset = index * mark_size + 16
    8.times.reduce(0_u64) { |value, byte| value | (bytes[offset + byte].to_u64 << (byte * 8)) }
  end
end

def w101_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  difference = 0
  while difference < limit && actual.to_slice[difference] == expected.to_slice[difference]
    difference += 1
  end
  got = difference < actual.bytesize ? actual.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  wanted = difference < expected.bytesize ? expected.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  raise W101ByteMismatchError.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first difference #{difference}: expected #{wanted}, got #{got}")
end

def w101_seeded_wrong_expectation_rejected(actual : String, expected : String, label : String) : Nil
  raise "#{label}: baseline comparator did not match" unless actual == expected
  damaged = String.new(expected.to_slice)
  raise "#{label}: cannot mutate empty expected data" if damaged.empty?
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 0x01_u8
  begin
    w101_assert_bytes(actual, damaged, "#{label} seeded wrong expectation")
    raise "#{label}: comparator accepted a one-byte wrong expectation"
  rescue ex : W101ByteMismatchError
  end
  puts "PASS #{label}: comparator rejects seeded one-byte wrong expectation"
end

def w101_expected_substreams(profile : W101Profile) : String
  lines = [
    "columns substreams version: 1",
    "2 columns:",
    "1 substreams for column `pk`:",
    "\tpk",
    "#{profile.fields.size} substreams for column `payload`:",
  ]
  profile.fields.each { |field| lines << "\tpayload%2E#{field.name}" }
  lines.join("\n") + "\n"
end

def w101_validate_counter(row : Hash(String, JSON::Any), expected_defaults : Int32, label : String, ratio_one : Bool = true) : Nil
  kind = row["kind"]?.try(&.as_s) || raise "#{label}: serializer kind missing"
  raise "#{label}: expected Default serializer, got #{kind}" if ratio_one && kind != "Default"
  rows = row["num_rows"]?.try(&.as_i) || raise "#{label}: num_rows missing"
  defaults = row["num_defaults"]?.try(&.as_i) || raise "#{label}: num_defaults missing"
  raise "#{label}: num_rows=#{rows}, expected five" unless rows == W101_KEYS.size.to_i64
  raise "#{label}: num_defaults=#{defaults}, expected #{expected_defaults}" unless defaults == expected_defaults.to_i64
  puts "OBSERVED #{label}: kind=#{kind}, rows=#{rows}, num_defaults=#{defaults}"
end

def w101_validate_metadata_envelope(info : Hash(String, JSON::Any), label : String) : Nil
  expected_keys = [
    "columns",
    "propagate_types_serialization_versions_to_nested_types",
    "types_serialization_versions",
    "version",
  ].sort
  actual_keys = info.keys.sort
  raise "#{label}: serialization metadata keys differ: #{actual_keys.inspect}" unless actual_keys == expected_keys
  raise "#{label}: serialization metadata version differs" unless info["version"]?.try(&.as_i) == 1
  raise "#{label}: nested type-version propagation is false" unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: type-version map missing"
  unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
    raise "#{label}: type-version map differs from the pinned profile: #{versions.to_json}"
  end
  nil
end

def w101_validate_metadata(profile : W101Profile, part : String, stats_only : Bool = false) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  w101_validate_metadata_envelope(info, profile.label)
  records = info["columns"]?.try(&.as_a) || raise "#{profile.label}: serialization columns absent"
  if records.empty?
    raise "#{profile.label}: empty serialization columns are only admitted for ratio >= 1.0" unless profile.ratio.to_f >= 1.0
    puts "OBSERVED #{profile.label}: serialization.json columns=[] at ratio=#{profile.ratio}; serializer default counters are unavailable, no counter claim"
    return nil
  end
  names = records.map { |entry| entry.as_h["name"]?.try(&.as_s) || raise "#{profile.label}: serializer name absent" }
  raise "#{profile.label}: serializer roots/order differ: #{names.inspect}" unless names == ["payload", "pk"]
  payload = records[0].as_h
  children = payload["subcolumns"]?.try(&.as_a) || raise "#{profile.label}: Tuple child statistics absent"
  raise "#{profile.label}: child count differs: #{children.size}" unless children.size == profile.fields.size

  profile.fields.each_with_index do |field, index|
    w101_validate_counter(children[index].as_h, field.storage_default_count, "#{profile.label} #{field.name}", !stats_only)
  end
  unless stats_only
    tuple_defaults = profile.tuple_default_count
    w101_validate_counter(payload, tuple_defaults, "#{profile.label} Tuple root")
    w101_validate_counter(records[1].as_h, 0, "#{profile.label} primary key")
  end
  nil
end

def w101_assert_stock_layout(profile : W101Profile, part : String, stats_only : Bool = false) : Nil
  expected_columns = [
    "columns format version: 1",
    "2 columns:",
    "`pk` UInt64",
    "`payload` #{profile.canonical_type_name}",
  ]
  actual_columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  raise "#{profile.label}: columns.txt differs: #{actual_columns.inspect}" unless actual_columns == expected_columns

  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  expected_substreams = w101_expected_substreams(profile)
  raise "#{profile.label}: columns_substreams.txt differs:\n#{actual_substreams}" unless actual_substreams == expected_substreams

  stream_names = profile.streams
  expected_bins = stream_names.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.bin" }.sort
  expected_marks = stream_names.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.mrk2" }.sort
  entries = Dir.children(part)
  actual_bins = entries.select(&.ends_with?(".bin")).sort
  actual_marks = entries.select(&.ends_with?(".mrk2")).sort
  raise "#{profile.label}: complete .bin inventory differs: #{actual_bins.inspect}" unless actual_bins == expected_bins
  raise "#{profile.label}: complete .mrk2 inventory differs: #{actual_marks.inspect}" unless actual_marks == expected_marks

  stream_names.each do |stream|
    rows = w101_mark_rows(part, stream)
    raise "#{profile.label} #{stream}: mark rows #{rows.inspect}, expected #{W101_MARK_ROWS.inspect}" unless rows == W101_MARK_ROWS
    next if stats_only && stream != "pk"
    encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
    actual = CrystalClick::CompressedBlock.decode_all(encoded)
    expected = profile.expected_stream(stream).to_slice
    w101_assert_bytes(String.new(actual), String.new(expected), "#{profile.label} #{stream} physical bytes")
  end
  w101_validate_metadata(profile, part, stats_only)
  puts "PASS #{profile.label}: exact canonical schema/substreams, complete streams and marks#{stats_only ? " (child payload intentionally not decoded)" : " and all physical bytes"}"
  nil
end

def w101_validate_zero_metadata_row(row : Hash(String, JSON::Any), expected_defaults : Int32, label : String) : Nil
  kind = row["kind"]?.try(&.as_s) || raise "#{label}: serializer kind missing"
  raise "#{label}: unexpected serializer kind #{kind}" unless ["Default", "AlwaysDefault", "Sparse"].includes?(kind)
  has_rows = row.has_key?("num_rows")
  has_defaults = row.has_key?("num_defaults")
  raise "#{label}: incomplete serialized default counters" unless has_rows == has_defaults
  if has_rows
    w101_validate_counter(row, expected_defaults, label, false)
  elsif kind != "AlwaysDefault"
    raise "#{label}: #{kind} serializer omitted observed defaults"
  end
  (row["subcolumns"]?.try(&.as_a) || [] of JSON::Any).each_with_index do |child, index|
    w101_validate_zero_metadata_row(child.as_h, expected_defaults, "#{label} child #{index}")
  end
end

def w101_assert_zero_metadata(profile : W101Profile, part : String) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  w101_validate_metadata_envelope(info, profile.label)
  records = info["columns"]?.try(&.as_a) || raise "#{profile.label}: serialization columns absent"
  if records.empty?
    raise "#{profile.label}: empty serialization columns are only admitted for ratio >= 1.0" unless profile.ratio.to_f >= 1.0
    puts "OBSERVED #{profile.label}: serialization.json columns=[] at ratio=#{profile.ratio}; serializer default counters are unavailable, no counter claim"
    puts "OBSERVED #{profile.label}: serialization.json=#{info.to_json}"
    return nil
  end
  names = records.map { |entry| entry.as_h["name"]?.try(&.as_s) || raise "#{profile.label}: serializer name missing" }
  raise "#{profile.label}: serializer roots/order differ: #{names.inspect}" unless names == ["payload", "pk"]
  payload = records[0].as_h
  children = payload["subcolumns"]?.try(&.as_a) || raise "#{profile.label}: Tuple child statistics absent"
  raise "#{profile.label}: child count differs: #{children.size}" unless children.size == profile.fields.size
  w101_validate_zero_metadata_row(payload, profile.tuple_default_count, "#{profile.label} Tuple root")
  profile.fields.each_with_index do |field, index|
    w101_validate_zero_metadata_row(children[index].as_h, field.storage_default_count, "#{profile.label} #{field.name}")
  end
  w101_validate_zero_metadata_row(records[1].as_h, 0, "#{profile.label} primary key")
  nil
end

def w101_assert_sparse_tolerant_layout(profile : W101Profile, part : String, allow_sparse_substreams : Bool) : Nil
  expected_columns = [
    "columns format version: 1",
    "2 columns:",
    "`pk` UInt64",
    "`payload` #{profile.canonical_type_name}",
  ]
  actual_columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  raise "#{profile.label}: columns.txt differs: #{actual_columns.inspect}" unless actual_columns == expected_columns

  substreams_path = File.join(part, "columns_substreams.txt")
  if File.exists?(substreams_path)
    actual_substreams = File.read(substreams_path)
    if allow_sparse_substreams
      puts "OBSERVED #{profile.label}: columns_substreams.txt=#{actual_substreams.inspect}"
    else
      expected_substreams = w101_expected_substreams(profile)
      raise "#{profile.label}: columns_substreams.txt differs:\n#{actual_substreams}" unless actual_substreams == expected_substreams
    end
  elsif !allow_sparse_substreams
    raise "#{profile.label}: columns_substreams.txt absent"
  else
    puts "OBSERVED #{profile.label}: columns_substreams.txt absent under default-profile guard"
  end

  expected_streams = profile.streams
  expected_bins = expected_streams.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.bin" }
  expected_marks = expected_bins.map { |name| name.sub(/\.bin$/, ".mrk2") }.sort
  entries = Dir.children(part)
  actual_bins = entries.select(&.ends_with?(".bin")).sort
  actual_marks = entries.select(&.ends_with?(".mrk2")).sort
  raise "#{profile.label}: undeclared stream present in .bin inventory: #{actual_bins.inspect}" unless actual_bins.all? { |name| expected_bins.includes?(name) }
  raise "#{profile.label}: undeclared mark present in .mrk2 inventory: #{actual_marks.inspect}" unless actual_marks.all? { |name| expected_marks.includes?(name) }
  expected_marks_for_bins = actual_bins.map { |name| name.sub(/\.bin$/, ".mrk2") }.sort
  raise "#{profile.label}: marks do not match present data streams: #{actual_marks.inspect}" unless actual_marks == expected_marks_for_bins

  key_bin = "#{CrystalClick::StreamName.hash("pk")}.bin"
  key_mark = "#{CrystalClick::StreamName.hash("pk")}.mrk2"
  raise "#{profile.label}: primary-key data stream absent" unless actual_bins.includes?(key_bin)
  raise "#{profile.label}: primary-key mark stream absent" unless actual_marks.includes?(key_mark)
  rows = w101_mark_rows(part, "pk")
  raise "#{profile.label}: primary-key mark rows #{rows.inspect}, expected #{W101_MARK_ROWS.inspect}" unless rows == W101_MARK_ROWS
  encoded = File.read(File.join(part, key_bin)).to_slice
  actual = CrystalClick::CompressedBlock.decode_all(encoded)
  expected = profile.expected_stream("pk").to_slice
  w101_assert_bytes(String.new(actual), String.new(expected), "#{profile.label} primary-key physical bytes")
  puts "PASS #{profile.label}: exact schema, present stream/mark inventory #{actual_bins.inspect} / #{actual_marks.inspect}; payload child streams intentionally not decoded"
  nil
end

def w101_observe_stats_layout(profile : W101Profile, part : String) : Nil
  expected_columns = [
    "columns format version: 1",
    "2 columns:",
    "`pk` UInt64",
    "`payload` #{profile.canonical_type_name}",
  ]
  actual_columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  raise "#{profile.label}: columns.txt differs: #{actual_columns.inspect}" unless actual_columns == expected_columns

  substreams_path = File.join(part, "columns_substreams.txt")
  substreams = File.exists?(substreams_path) ? File.read(substreams_path) : "<absent>"
  entries = Dir.children(part)
  actual_bins = entries.select(&.ends_with?(".bin")).sort
  actual_marks = entries.select(&.ends_with?(".mrk2")).sort
  puts "OBSERVED #{profile.label}: sparse columns_substreams.txt=#{substreams.inspect}, bins=#{actual_bins.inspect}, marks=#{actual_marks.inspect}; child layout is not constrained or decoded"

  key_bin = "#{CrystalClick::StreamName.hash("pk")}.bin"
  key_mark = "#{CrystalClick::StreamName.hash("pk")}.mrk2"
  raise "#{profile.label}: primary-key data stream absent" unless actual_bins.includes?(key_bin)
  raise "#{profile.label}: primary-key mark stream absent" unless actual_marks.includes?(key_mark)
  rows = w101_mark_rows(part, "pk")
  raise "#{profile.label}: primary-key mark rows #{rows.inspect}, expected #{W101_MARK_ROWS.inspect}" unless rows == W101_MARK_ROWS
  encoded = File.read(File.join(part, key_bin)).to_slice
  actual = CrystalClick::CompressedBlock.decode_all(encoded)
  expected = profile.expected_stream("pk").to_slice
  w101_assert_bytes(String.new(actual), String.new(expected), "#{profile.label} primary-key physical bytes")
  nil
end

def w101_check_table(binary : String, store : String, profile : W101Profile, part : String) : Nil
  actual = w101_clickhouse(binary, store, "CHECK TABLE default.#{profile.table_name} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{profile.label}: CHECK TABLE differs: #{actual.inspect}" unless actual == expected
  nil
end

def w101_select(binary : String, store : String, profile : W101Profile, key_range : Bool = false) : String
  selections = ["pk"] + profile.fields.map { |field| "payload.#{field.name}" }
  predicate = key_range ? " WHERE pk >= 2 AND pk < 5" : ""
  w101_clickhouse(binary, store, "SELECT #{selections.join(", ")} FROM default.#{profile.table_name}#{predicate} ORDER BY pk FORMAT RowBinary")
end

def w101_check_stock_profile(binary : String, store : String, profile : W101Profile, insert_query : String? = nil, sparse_default_profile : Bool = false) : String
  w101_create_table(binary, store, profile)
  if insert_query
    w101_clickhouse(binary, store, insert_query)
  else
    w101_insert_rowbinary(binary, store, profile)
  end
  part = w101_part_path(binary, store, profile.table_name)
  w101_schema(binary, store, profile)
  if sparse_default_profile
    w101_assert_sparse_tolerant_layout(profile, part, true)
    w101_assert_zero_metadata(profile, part)
  else
    w101_assert_stock_layout(profile, part)
  end
  w101_check_table(binary, store, profile, part)
  full = w101_select(binary, store, profile)
  w101_assert_bytes(full, profile.expected_rowbinary(W101_FULL), "#{profile.label} independent stock full RowBinary")
  keyed = w101_select(binary, store, profile, true)
  w101_assert_bytes(keyed, profile.expected_rowbinary(W101_KEY_RANGE), "#{profile.label} independent stock key-range RowBinary")
  puts "PASS #{profile.label}: stock CHECK plus full/key-range RowBinary"
  part
end

def w101_stats_metadata(profile : W101Profile, part : String, expected_defaults : Int32) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  w101_validate_metadata_envelope(info, profile.label)
  records = info["columns"]?.try(&.as_a) || raise "#{profile.label}: serialization columns absent"
  names = records.map { |entry| entry.as_h["name"]?.try(&.as_s) || raise "#{profile.label}: serializer name absent" }
  raise "#{profile.label}: serializer roots/order differ: #{names.inspect}" unless names == ["payload", "pk"]
  payload = records[0].as_h
  children = payload["subcolumns"]?.try(&.as_a) || raise "#{profile.label}: Tuple child stats absent"
  raise "#{profile.label}: expected one child stat, got #{children.size}" unless children.size == 1
  w101_validate_counter(children[0].as_h, expected_defaults, "#{profile.label} child", false)
  nil
end

def w101_check_stats_profile(binary : String, store : String, profile : W101Profile, insert_query : String?, expected_defaults : Int32) : Nil
  w101_create_table(binary, store, profile)
  if insert_query
    w101_clickhouse(binary, store, insert_query)
  else
    w101_insert_rowbinary(binary, store, profile)
  end
  part = w101_part_path(binary, store, profile.table_name)
  w101_schema(binary, store, profile)
  # Sparse child substreams, inventory and offsets are observed rather than
  # constrained here; the primary-key stream and marks remain fully checked.
  w101_observe_stats_layout(profile, part)
  w101_stats_metadata(profile, part, expected_defaults)
  w101_check_table(binary, store, profile, part)
  full = w101_select(binary, store, profile)
  w101_assert_bytes(full, profile.expected_rowbinary(W101_FULL), "#{profile.label} stock full RowBinary")
  keyed = w101_select(binary, store, profile, true)
  w101_assert_bytes(keyed, profile.expected_rowbinary(W101_KEY_RANGE), "#{profile.label} stock key-range RowBinary")
  puts "PASS #{profile.label}: stock CHECK, RowBinary and storage-default statistic; child payload data not manually decoded"
  nil
end

def w101_attempt_tuple_reader(part : String, label : String) : Nil
  begin
    CrystalClick::WidePart.open_typed(part, "payload")
  rescue ex : CrystalClick::UnsupportedFormatError
    raise "#{label}: typed reader rejected for an unqualified reason: #{ex.message}" unless ex.message == "unsupported exact typed column"
    puts "OBSERVED expected typed-reader rejection after stock qualification: #{label}: #{ex.class}: #{ex.message}"
    return
  end
  raise "#{label}: current typed reader unexpectedly admitted the W101 type"
end

def w101_positive_control(binary : String, store : String) : Nil
  type_name = "Tuple(a UInt64, b String)"
  table = "w101_existing_control"
  keys = W101_KEYS
  numbers = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]
  strings = ["alpha", "beta", "gamma", "delta", "epsilon"]
  query = "CREATE TABLE default.#{table} (pk UInt64, payload #{type_name}) ENGINE = MergeTree ORDER BY pk SETTINGS #{w101_settings("1.0")}"
  w101_clickhouse(binary, store, query)
  input = IO::Memory.new
  keys.each_with_index do |key, index|
    input << w101_unsigned_le(key, 8)
    input << w101_unsigned_le(numbers[index], 8)
    value = strings[index]
    remaining = value.bytesize.to_u64
    while remaining >= 0x80_u64
      input.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
      remaining >>= 7
    end
    input.write_byte(remaining.to_u8)
    input << value
  end
  input.rewind
  w101_clickhouse(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  part = w101_part_path(binary, store, table)
  actual_columns = w101_clickhouse(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  raise "existing positive control system.columns differs: #{actual_columns.inspect}" unless actual_columns == ["pk UInt64", "payload #{type_name}"]
  actual_column_file = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  expected_column_file = ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{type_name}"]
  raise "existing positive control columns.txt differs: #{actual_column_file.inspect}" unless actual_column_file == expected_column_file
  control_streams = ["pk", "payload%2Ea", "payload%2Eb.size", "payload%2Eb"]
  expected_substreams = [
    "columns substreams version: 1",
    "2 columns:",
    "1 substreams for column `pk`:",
    "\tpk",
    "3 substreams for column `payload`:",
    "\tpayload%2Ea",
    "\tpayload%2Eb.size",
    "\tpayload%2Eb",
  ].join("\n") + "\n"
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  raise "existing positive control columns_substreams.txt differs: #{actual_substreams.inspect}" unless actual_substreams == expected_substreams
  expected_bins = control_streams.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.bin" }.sort
  expected_marks = control_streams.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.mrk2" }.sort
  entries = Dir.children(part)
  actual_bins = entries.select(&.ends_with?(".bin")).sort
  actual_marks = entries.select(&.ends_with?(".mrk2")).sort
  raise "existing positive control .bin inventory differs: #{actual_bins.inspect}" unless actual_bins == expected_bins
  raise "existing positive control .mrk2 inventory differs: #{actual_marks.inspect}" unless actual_marks == expected_marks
  physical = Hash(String, String).new
  physical["pk"] = keys.map { |key| w101_unsigned_le(key, 8) }.join
  physical["payload%2Ea"] = numbers.map { |number| w101_unsigned_le(number, 8) }.join
  physical["payload%2Eb.size"] = strings.map { |value| w101_unsigned_le(value.bytesize.to_u64, 8) }.join
  physical["payload%2Eb"] = strings.join
  control_streams.each do |stream|
    rows = w101_mark_rows(part, stream)
    raise "existing positive control #{stream} marks differ: #{rows.inspect}" unless rows == W101_MARK_ROWS
    compressed = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
    decoded = CrystalClick::CompressedBlock.decode_all(compressed)
    w101_assert_bytes(String.new(decoded), physical[stream], "existing positive control #{stream} physical bytes")
  end
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "existing positive control type differs" unless reader.column_type == type_name
  raise "existing positive control marks differ" unless reader.mark_row_counts == [2_u64, 2_u64, 1_u64]
  data = reader.read_tuple_mark_range("payload", 0, reader.mark_count)
  raise "existing positive control UInt64 values differ" unless data["a"].uint64_values == numbers
  raise "existing positive control String values differ" unless data["b"].string_values == strings
  full = w101_clickhouse(binary, store, "SELECT pk, payload.a, payload.b FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "existing positive control RowBinary differs" unless full == input.to_s
  actual_check = w101_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "existing positive control CHECK TABLE differs: #{actual_check.inspect}" unless actual_check == "#{File.basename(part.chomp("/"))}\t1"
  puts "PASS existing Tuple UInt64/String positive control: current reader, physical mark range, stock RowBinary and CHECK"
  nil
end

def w101_fixed_sql_insert_for_profile(profile : W101Profile, width : Int32, inputs : Array(String)) : String
  w101_fixed_sql_insert(profile.table_name, width, inputs)
end

def w101_enum_default_field : W101Field
  w101_enum_field("value", "Enum8", W101_ENUM8_PAIRS, Array.new(W101_KEYS.size, -128))
end

def w101_zero_enum_field : W101Field
  w101_enum_field("value", "Enum8", W101_ENUM8_PAIRS, Array.new(W101_KEYS.size, 0))
end

def w101_fixed_zero_field(width : Int32) : W101Field
  type_name = "FixedString(#{width})"
  zero = String.new(Bytes.new(width, 0_u8))
  W101Field.new("value", type_name, type_name, width, Array.new(W101_KEYS.size, zero))
end

def w101_default_insert_query(profile : W101Profile) : String
  "INSERT INTO default.#{profile.table_name} (pk) SELECT toUInt64(number + 1) FROM numbers(5)"
end

def w101_carrier_profile(width : Int32, precision : Int32, family : String) : W101Profile
  scale = 0
  input_type = family.empty? ? "Decimal(#{precision}, #{scale})" : "#{family}(#{scale})"
  field = W101Field.new("value", input_type, "Decimal(#{precision}, #{scale})", width, w101_carrier_extrema(width))
  W101Profile.new("carrier_#{width}", [field] of W101Field)
end

def w101_optional_carrier_probe(binary : String, store : String, profile : W101Profile) : Bool
  w101_create_table(binary, store, profile)
  input = IO::Memory.new(w101_rowbinary_input(profile).to_slice)
  succeeded, output, error = w101_attempt_clickhouse(binary, store, "INSERT INTO default.#{profile.table_name} FORMAT RowBinary", input)
  unless succeeded
    puts "OBSERVED optional raw Decimal#{profile.fields[0].width * 8} carrier extrema refused by stock RowBinary insert: #{error.lines.first? || output.lines.first?}"
    return false
  end
  part = w101_part_path(binary, store, profile.table_name)
  w101_schema(binary, store, profile)
  w101_assert_stock_layout(profile, part)
  w101_check_table(binary, store, profile, part)
  full = w101_select(binary, store, profile)
  w101_assert_bytes(full, profile.expected_rowbinary(W101_FULL), "#{profile.label} stock raw carrier RowBinary")
  puts "PASS optional #{profile.label}: ClickHouse retains complete native carrier extrema beyond declared decimal value range"
  true
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("W101_STORE")
head_output = IO::Memory.new
head_status = Process.run("git", ["rev-parse", "HEAD"], output: head_output)
raise "could not read predecessor Git HEAD" unless head_status.success?
raise "W101 RED probe requires predecessor #{W101_EXPECTED_HEAD}, got #{head_output.to_s.strip}" unless head_output.to_s.strip == W101_EXPECTED_HEAD
source_status = Process.run("git", ["diff", "--quiet", "HEAD", "--", "src"])
raise "W101 RED probe requires unchanged tracked production source" unless source_status.success?
version = w101_clickhouse(binary, store, "SELECT version() FORMAT TSVRaw").strip
raise "W101 requires ClickHouse #{W101_STOCK_VERSION}, got #{version}" unless version == W101_STOCK_VERSION

w101_positive_control(binary, store)

fixed_one_inputs = w101_fixed_inputs(1)
fixed_four_inputs = w101_fixed_inputs(4)
fixed_one = W101Field.new("value", "FixedString(1)", "FixedString(1)", 1, fixed_one_inputs.map { |value| w101_fixed_bytes(value, 1) })
fixed_four = W101Field.new("value", "FixedString(4)", "FixedString(4)", 4, fixed_four_inputs.map { |value| w101_fixed_bytes(value, 4) })
singleton_profiles = [
  W101Profile.new("fixed1_singleton", [fixed_one] of W101Field),
  W101Profile.new("fixed4_singleton", [fixed_four] of W101Field),
  W101Profile.new("enum8_singleton", [w101_enum_field("value", "Enum8", W101_ENUM8_PAIRS, [-128, -1, 0, 127, -7])] of W101Field),
  W101Profile.new("enum16_singleton", [w101_enum_field("value", "Enum16", W101_ENUM16_PAIRS, [-32768, -30000, 0, 32767, 42])] of W101Field),
  W101Profile.new("decimal32_singleton", [w101_decimal_field("value", 9, 9, "Decimal(9, 9)")] of W101Field),
  W101Profile.new("decimal64_singleton", [w101_decimal_field("value", 18, 18, "Decimal(18, 18)")] of W101Field),
  W101Profile.new("decimal128_singleton", [w101_decimal_field("value", 38, 38, "Decimal(38, 38)")] of W101Field),
  W101Profile.new("decimal256_singleton", [w101_decimal_field("value", 76, 76, "Decimal(76, 76)")] of W101Field),
]

singleton_profiles.each do |profile|
  fixed_width = case profile.label
                when "fixed1_singleton" then 1
                when "fixed4_singleton" then 4
                else                         nil
                end
  if fixed_width
    inputs = fixed_width == 1 ? fixed_one_inputs : fixed_four_inputs
    w101_check_stock_profile(binary, store, profile, w101_fixed_sql_insert_for_profile(profile, fixed_width, inputs))
  else
    w101_check_stock_profile(binary, store, profile)
  end
end

mixed_fields = w101_primary_fields
mixed = W101Profile.new("mixed", mixed_fields)
mixed_part = w101_check_stock_profile(binary, store, mixed)

# Guard-only stock profile: these all-zero rows may use sparse/default storage,
# so this result is not an ordinary physical-layout control and is never sent
# to the typed-reader RED loop below.
all_zero_guard = w101_zero_profile(mixed, "allzero_guard_only")
w101_check_stock_profile(binary, store, all_zero_guard, nil, true)

# An independent byte comparator positive control and seeded wrong expectation
# make the high-value mixed result sensitive to a one-byte oracle defect.
mixed_full = w101_select(binary, store, mixed)
w101_seeded_wrong_expectation_rejected(mixed_full, mixed.expected_rowbinary(W101_FULL), "W101 mixed full RowBinary comparator")

# Stock-only statistics probes deliberately do not feed a Sparse child stream
# to CrystalClick's plain compressed-block decoder.
enum_zero = W101Profile.new("enum_rawzero_stats", [w101_zero_enum_field] of W101Field, "0.9375")
enum_min = W101Profile.new("enum_minimum_stats", [w101_enum_default_field] of W101Field, "0.9375")
fixed_zero = W101Profile.new("fixedstring_zero_stats", [w101_fixed_zero_field(4)] of W101Field, "0.9375")
w101_check_stats_profile(binary, store, enum_zero, nil, W101_KEYS.size)
w101_check_stats_profile(binary, store, enum_min, w101_default_insert_query(enum_min), 0)
w101_check_stats_profile(binary, store, fixed_zero, w101_default_insert_query(fixed_zero), W101_KEYS.size)

# Native carrier extrema are outside Decimal(P,S)'s semantic number range.
# Stock RowBinary acceptance is observed, never assumed or required for RED.
carrier_profiles = [
  w101_carrier_profile(4, 9, "Decimal32"),
  w101_carrier_profile(8, 18, "Decimal64"),
  w101_carrier_profile(16, 38, "Decimal128"),
  w101_carrier_profile(32, 76, "Decimal256"),
]
carrier_profiles.each { |profile| w101_optional_carrier_probe(binary, store, profile) }

# Attempt current typed reads only after every ordinary stock singleton, mixed
# boundary matrix, statistics control, and comparator control has passed its
# independent positive assertions. The all-zero profile above is guard-only.
(singleton_profiles + [mixed]).each do |profile|
  part = if profile.label == "mixed"
           mixed_part
         else
           w101_part_path(binary, store, profile.table_name)
         end
  w101_attempt_tuple_reader(part, profile.label)
end

puts "EXPECTED RED: stock-qualified FixedString/Enum/Decimal named-flat Tuple fixtures pass schema, substreams, complete physical bytes and marks, CHECK, full/key-range RowBinary and seeded comparator, then the current typed reader rejects."
exit 1
