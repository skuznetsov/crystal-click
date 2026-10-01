# Independent stock and Crystal-writer certificates for one outer Array over
# a recursive named Tuple. The 13-leaf profile complements (does not replace)
# W105's all-53 flat Nullable-leaf matrix; it is not an all-family Array matrix.
#
# Run in fresh stores with:
#   --green-reader  stock create/ATTACH certificate, then typed consumers
#   --green-writer  stock seed -> typed read -> Crystal write -> stock attach
require "json"
require "file_utils"
require "../src/crystal_click"

W107G_STOCK_VERSION = "26.7.1.1315"
W107G_TUPLE_TYPE    = "Tuple(id UInt64, left Tuple(details Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), flag Nullable(Bool), note Nullable(String), event DateTime64(3, 'America/New_York'), amount Nullable(Decimal(9, 2))), fixed FixedString(3), count UInt32), right Tuple(details Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), note Nullable(String), event DateTime64(9, 'UTC')), fixed FixedString(3), count UInt64))"
W107G_TYPE          = "Array(Tuple(id UInt64, left Tuple(details Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), flag Nullable(Bool), note Nullable(String), event DateTime64(3, 'America/New_York'), amount Nullable(Decimal(9, 2))), fixed FixedString(3), count UInt32), right Tuple(details Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), note Nullable(String), event DateTime64(9, 'UTC')), fixed FixedString(3), count UInt64)))"
W107G_KEYS          = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64, 60_u64, 70_u64, 80_u64, 90_u64]
W107G_ROW_SIZES     = [0_u64, 0_u64, 2_u64, 0_u64, 0_u64, 0_u64, 1_u64, 1_u64, 0_u64]
W107G_SIZE0         = [0_u64, 0_u64, 2_u64, 2_u64, 2_u64, 2_u64, 3_u64, 4_u64, 4_u64]
W107G_ROW_ELEMENTS  = [
  [] of Int32, [] of Int32, [0_i32, 1_i32], [] of Int32, [] of Int32,
  [] of Int32, [2_i32], [3_i32], [] of Int32,
]
W107G_BOUNDARIES = [0, 2, 4, 6, 8, 9]
W107G_MARK_ROWS  = [2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
W107G_SETTINGS   = "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 0.9375, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"

class W107GreenByteMismatch < Exception
end

class W107GreenField
  getter name : String
  getter base_type : String
  getter nullable : Bool
  getter values : Array(String?)

  def initialize(@name : String, @base_type : String, @nullable : Bool, values : Array(String?))
    raise "#{name}: expected four flattened elements or an empty all-empty profile" unless values.size == 4 || values.empty?
    raise "#{name}: bare field contains NULL" if !nullable && values.any?(&.nil?)
    @values = values.dup
  end

  def type_name : String
    nullable ? "Nullable(#{base_type})" : base_type
  end

  def string? : Bool
    base_type == "String"
  end

  def width : Int32
    case base_type
    when "Enum8('neg' = -7, 'pos' = 7)", "Bool"                                then 1
    when "UInt32", "Decimal(9, 2)"                                             then 4
    when "UInt64", "DateTime64(3, 'America/New_York')", "DateTime64(9, 'UTC')" then 8
    when "FixedString(3)"                                                      then 3
    when "String"                                                              then 0
    else                                                                            raise "#{name}: no independently enumerated width for #{base_type}"
    end
  end

  def stream_name : String
    "payload%2E#{name.gsub(".", "%2E")}"
  end

  def default_fragment : String
    string? ? "" : String.new(Bytes.new(width, 0_u8))
  end

  # The writer profile changes bytes hidden by NULL, and carries one visible
  # noncanonical Bool byte. The mask, logical values, and SQL NULL wire form
  # remain unchanged.
  def stream_rows(writer_profile : Bool = false) : Array(String)
    values.map_with_index do |value, row|
      if writer_profile
        case name
        when "left.details.state", "right.details.state"
          if value.nil?
            next row == 0 ? w107g_signed_le(127_i64, 1) : w107g_signed_le(-128_i64, 1)
          end
        when "left.details.flag"
          if row == 2 && !value.nil?
            next w107g_byte(2_u8)
          elsif value.nil?
            next w107g_byte(row == 0 ? 0xfe_u8 : 0xff_u8)
          end
        when "left.details.note", "right.details.note"
          if value.nil?
            next name == "left.details.note" ? "hidden-null-left" : "hidden-null-right"
          end
        when "left.details.amount"
          if value.nil?
            next w107g_signed_le(row == 0 ? Int32::MIN.to_i64 : Int32::MAX.to_i64, 4)
          end
        end
      end
      value || default_fragment
    end
  end

  def null_rows : Array(UInt8)
    values.map { |value| value.nil? ? 1_u8 : 0_u8 }
  end

  def rowbinary_at(row : Int32, writer_profile : Bool = false) : String
    value = values[row]
    if nullable
      return "\x01" if value.nil?
      fragment = stream_rows(writer_profile)[row]
      return "\x00" + (string? ? w107g_varuint(fragment.bytesize.to_u64) + fragment : fragment)
    end
    fragment = stream_rows(writer_profile)[row]
    string? ? w107g_varuint(fragment.bytesize.to_u64) + fragment : fragment
  end
end

class W107GreenNode
  getter name : String
  getter path : String
  getter children : Array(W107GreenNode)

  def initialize(@name : String, @path : String, @children : Array(W107GreenNode) = [] of W107GreenNode)
  end

  def tuple? : Bool
    !children.empty?
  end
end

def w107g_byte(value : UInt8) : String
  String.new(Bytes[value])
end

def w107g_unsigned_le(value : UInt64, width : Int32) : String
  raise "negative byte width" if width < 0
  low_width = Math.min(width, 8)
  String.build do |output|
    low_width.times { |index| output.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
    (width - low_width).times { output.write_byte(0_u8) }
  end
end

def w107g_signed_le(value : Int64, width : Int32) : String
  raise "negative byte width" if width < 0
  low_width = Math.min(width, 8)
  low = w107g_unsigned_le(value.unsafe_as(UInt64), low_width)
  extension = value < 0 ? 0xff_u8 : 0_u8
  low + String.new(Bytes.new(width - low_width, extension))
end

def w107g_varuint(value : UInt64) : String
  String.build do |output|
    remaining = value
    while remaining >= 0x80_u64
      output.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
      remaining >>= 7
    end
    output.write_byte(remaining.to_u8)
  end
end

def w107g_fields(all_empty : Bool = false) : Array(W107GreenField)
  enum_type = "Enum8('neg' = -7, 'pos' = 7)"
  fields = [
    W107GreenField.new("id", "UInt64", false, [
      w107g_unsigned_le(0_u64, 8), w107g_unsigned_le(UInt64::MAX, 8),
      w107g_unsigned_le(7_u64, 8), w107g_unsigned_le(2_u64, 8),
    ] of String?),
    W107GreenField.new("left.details.state", enum_type, true, [nil, w107g_signed_le(-7_i64, 1), w107g_signed_le(7_i64, 1), nil] of String?),
    W107GreenField.new("left.details.flag", "Bool", true, [nil, w107g_byte(0_u8), w107g_byte(1_u8), nil] of String?),
    W107GreenField.new("left.details.note", "String", true, [nil, "", "a\0b", "tail"] of String?),
    W107GreenField.new("left.details.event", "DateTime64(3, 'America/New_York')", false, [
      w107g_signed_le(0_i64, 8), w107g_signed_le(-1_i64, 8),
      w107g_signed_le(1_615_705_200_001_i64, 8), w107g_signed_le(Int64::MAX, 8),
    ] of String?),
    W107GreenField.new("left.details.amount", "Decimal(9, 2)", true, [
      nil, w107g_signed_le(100_i64, 4), w107g_signed_le(-22_i64, 4), nil,
    ] of String?),
    W107GreenField.new("left.fixed", "FixedString(3)", false, ["\0\0\0", "abc", "xyz", "end"] of String?),
    W107GreenField.new("left.count", "UInt32", false, [
      w107g_unsigned_le(0_u64, 4), w107g_unsigned_le(UInt32::MAX.to_u64, 4),
      w107g_unsigned_le(7_u64, 4), w107g_unsigned_le(0_u64, 4),
    ] of String?),
    W107GreenField.new("right.details.state", enum_type, true, [nil, w107g_signed_le(7_i64, 1), w107g_signed_le(-7_i64, 1), nil] of String?),
    W107GreenField.new("right.details.note", "String", true, ["", nil, "right", "end"] of String?),
    W107GreenField.new("right.details.event", "DateTime64(9, 'UTC')", false, [
      w107g_signed_le(Int64::MIN, 8), w107g_signed_le(-1_i64, 8),
      w107g_signed_le(1_636_264_800_000_000_001_i64, 8), w107g_signed_le(Int64::MAX, 8),
    ] of String?),
    W107GreenField.new("right.fixed", "FixedString(3)", false, ["abc", "\0\0\0", "def", "xyz"] of String?),
    W107GreenField.new("right.count", "UInt64", false, [
      w107g_unsigned_le(UInt64::MAX, 8), w107g_unsigned_le(0_u64, 8),
      w107g_unsigned_le(0_u64, 8), w107g_unsigned_le(10_u64, 8),
    ] of String?),
  ] of W107GreenField
  return fields unless all_empty
  fields.map { |field| W107GreenField.new(field.name, field.base_type, field.nullable, [] of String?) }
end

def w107g_streams(fields : Array(W107GreenField), writer_profile : Bool = false, all_empty : Bool = false) : Array({String, Array(String)})
  streams = [{"pk", W107G_KEYS.map { |key| w107g_unsigned_le(key, 8) }}] of {String, Array(String)}
  sizes = all_empty ? Array(UInt64).new(W107G_KEYS.size, 0_u64) : W107G_ROW_SIZES
  streams << {"payload.size0", sizes.map { |size| w107g_unsigned_le(size, 8) }}
  fields.each do |field|
    rows = field.stream_rows(writer_profile)
    streams << {"#{field.stream_name}.null", field.null_rows.map { |value| w107g_byte(value) }} if field.nullable
    streams << {"#{field.stream_name}.size", rows.map { |value| w107g_unsigned_le(value.bytesize.to_u64, 8) }} if field.string?
    streams << {field.stream_name, rows}
  end
  streams
end

def w107g_expected_columns : String
  "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{W107G_TYPE}\n"
end

def w107g_expected_substreams(fields : Array(W107GreenField)) : String
  names = ["payload.size0"] + fields.flat_map do |field|
    streams = [] of String
    streams << "#{field.stream_name}.null" if field.nullable
    streams << "#{field.stream_name}.size" if field.string?
    streams << field.stream_name
    streams
  end
  lines = [
    "columns substreams version: 1", "2 columns:",
    "1 substreams for column `pk`:", "\tpk",
    "#{names.size} substreams for column `payload`:",
  ]
  names.each { |name| lines << "\t#{name}" }
  lines.join("\n") + "\n"
end

def w107g_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  offset = 0
  while offset < limit && actual.to_slice[offset] == expected.to_slice[offset]
    offset += 1
  end
  got = offset < actual.bytesize ? actual.to_slice[offset].to_s(16).rjust(2, '0') : "<eof>"
  wanted = offset < expected.bytesize ? expected.to_slice[offset].to_s(16).rjust(2, '0') : "<eof>"
  raise W107GreenByteMismatch.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first difference #{offset}: expected #{wanted}, got #{got}")
end

def w107g_seeded_comparator(actual : String, expected : String, label : String) : Nil
  w107g_assert_bytes(actual, expected, "#{label} baseline")
  raise "#{label}: cannot seed empty stream" if expected.empty?
  damaged = String.new(expected.to_slice)
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 0x01_u8
  rejected = false
  begin
    w107g_assert_bytes(actual, damaged, "#{label} seeded mismatch")
  rescue ex : W107GreenByteMismatch
    rejected = true
  end
  raise "#{label}: seeded comparator accepted the mismatch" unless rejected
  puts "PASS #{label}: seeded one-byte mismatch rejected"
end

def w107g_run(binary : String, store : String, query : String, input : IO? = nil) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = if input
             Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  raise "ClickHouse failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w107g_create_table(binary : String, store : String, table : String) : Nil
  w107g_run(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{W107G_TYPE}) ENGINE = MergeTree ORDER BY pk SETTINGS #{W107G_SETTINGS}")
  nil
end

def w107g_expected_rowbinary(fields : Array(W107GreenField), indexes : Array(Int32), writer_profile : Bool = false, all_empty : Bool = false) : String
  String.build do |output|
    indexes.each do |row|
      output << w107g_unsigned_le(W107G_KEYS[row], 8)
      element_indexes = all_empty ? [] of Int32 : W107G_ROW_ELEMENTS[row]
      output << w107g_varuint(element_indexes.size.to_u64)
      element_indexes.each do |element|
        fields.each { |field| output << field.rowbinary_at(element, writer_profile) }
      end
    end
  end
end

def w107g_insert(binary : String, store : String, table : String, fields : Array(W107GreenField), all_empty : Bool = false) : Nil
  data = w107g_expected_rowbinary(fields, (0...W107G_KEYS.size).map(&.to_i32), false, all_empty)
  w107g_run(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", IO::Memory.new(data.to_slice))
  nil
end

def w107g_part_path(binary : String, store : String, table : String) : String
  rows = w107g_run(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{table}: expected one nine-row Wide part, got #{rows.inspect}" unless rows.size == 1
  parts = rows[0].split('\t')
  raise "#{table}: malformed active-part record #{rows[0].inspect}" unless parts.size == 3 && parts[1] == "Wide" && parts[2] == W107G_KEYS.size.to_s
  parts[0]
end

def w107g_schema(binary : String, store : String, table : String) : Nil
  actual = w107g_run(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  expected = ["pk UInt64", "payload #{W107G_TYPE}"]
  raise "#{table}: exact schema differs: #{actual.inspect}" unless actual == expected
  nil
end

def w107g_attach(binary : String, store : String, table : String, source_part : String) : String
  w107g_create_table(binary, store, table)
  data_path = w107g_run(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: empty ClickHouse data path" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(source_part, File.join(detached, "all_1_1_0"))
  w107g_run(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w107g_part_path(binary, store, table)
end

def w107g_check(binary : String, store : String, table : String, part : String) : Nil
  actual = w107g_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table}: CHECK TABLE differs: #{actual.inspect}" unless actual == expected
  nil
end

def w107g_select(binary : String, store : String, table : String, selected : Bool = false) : String
  predicate = selected ? " WHERE pk >= 30 AND pk < 80" : ""
  w107g_run(binary, store, "SELECT pk, payload FROM default.#{table}#{predicate} ORDER BY pk FORMAT RowBinary")
end

def w107g_assert_rowbinary(binary : String, store : String, table : String, fields : Array(W107GreenField), label : String, writer_profile : Bool = false, all_empty : Bool = false) : Nil
  full = w107g_select(binary, store, table)
  w107g_assert_bytes(full, w107g_expected_rowbinary(fields, (0...W107G_KEYS.size).map(&.to_i32), writer_profile, all_empty), "#{label} full RowBinary")
  selected = w107g_select(binary, store, table, true)
  w107g_assert_bytes(selected, w107g_expected_rowbinary(fields, [2_i32, 3_i32, 4_i32, 5_i32, 6_i32], writer_profile, all_empty), "#{label} selected RowBinary")
  puts "PASS #{label}: independently encoded full and selected RowBinary"
  nil
end

def w107g_actual_marks(part : String, stream : String) : Array({UInt64, UInt64, UInt64})
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  size = CrystalClick::WidePart::MARK_SIZE
  raise "#{stream}: partial .mrk2 record" unless bytes.size % size == 0
  Array({UInt64, UInt64, UInt64}).new(bytes.size // size) do |index|
    offset = index * size
    values = Array(UInt64).new(3) do |field|
      start = offset + field * 8
      8.times.reduce(0_u64) { |acc, byte| acc | (bytes[start + byte].to_u64 << (byte * 8)) }
    end
    {values[0], values[1], values[2]}
  end
end

def w107g_lz4_literal_frame_size(raw_size : Int32) : UInt64
  raise "empty raw chunk has no writer frame" if raw_size <= 0
  extensions = raw_size < 15 ? 0 : ((raw_size - 15) // 255) + 1
  (25 + 1 + raw_size + extensions).to_u64
end

def w107g_outer_axis?(stream : String) : Bool
  stream == "pk" || stream == "payload.size0"
end

def w107g_element_boundary(outer_boundary : Int32, all_empty : Bool = false) : Int32
  return 0_i32 if all_empty
  return 0_i32 if outer_boundary == 0
  W107G_SIZE0[outer_boundary - 1].to_i32
end

def w107g_expected_stock_marks(stream : String, fragments : Array(String), all_empty : Bool = false) : Array({UInt64, UInt64, UInt64})
  W107G_BOUNDARIES.each_with_index.map do |boundary, index|
    consumed = w107g_outer_axis?(stream) ? boundary : w107g_element_boundary(boundary, all_empty)
    raw_offset = fragments[0, consumed].sum(&.bytesize).to_u64
    {0_u64, raw_offset, W107G_MARK_ROWS[index]}
  end.to_a
end

def w107g_expected_writer_marks(stream : String, fragments : Array(String), all_empty : Bool = false) : Array({UInt64, UInt64, UInt64})
  marks = [] of {UInt64, UInt64, UInt64}
  compressed_offset = 0_u64
  (W107G_MARK_ROWS.size - 1).times do |mark|
    outer_first = W107G_BOUNDARIES[mark]
    outer_after = W107G_BOUNDARIES[mark + 1]
    first = w107g_outer_axis?(stream) ? outer_first : w107g_element_boundary(outer_first, all_empty)
    after = w107g_outer_axis?(stream) ? outer_after : w107g_element_boundary(outer_after, all_empty)
    raw_chunk = fragments[first, after - first].join
    marks << {compressed_offset, 0_u64, W107G_MARK_ROWS[mark]}
    compressed_offset += w107g_lz4_literal_frame_size(raw_chunk.bytesize) unless raw_chunk.empty?
  end
  marks << {compressed_offset, 0_u64, 0_u64}
  marks
end

def w107g_expected_node_tree(fields : Array(W107GreenField)) : W107GreenNode
  leaves = fields.to_h { |field| {field.name, W107GreenNode.new(field.name.split('.').last, field.name)} }
  W107GreenNode.new("payload", "", [
    leaves["id"],
    W107GreenNode.new("left", "left", [
      W107GreenNode.new("details", "left.details", [
        leaves["left.details.state"], leaves["left.details.flag"], leaves["left.details.note"],
        leaves["left.details.event"], leaves["left.details.amount"],
      ]),
      leaves["left.fixed"], leaves["left.count"],
    ]),
    W107GreenNode.new("right", "right", [
      W107GreenNode.new("details", "right.details", [
        leaves["right.details.state"], leaves["right.details.note"], leaves["right.details.event"],
      ]),
      leaves["right.fixed"], leaves["right.count"],
    ]),
  ])
end

def w107g_field_index(fields : Array(W107GreenField), path : String) : Int32
  fields.index { |field| field.name == path } || raise "missing independent fixture path #{path}"
end

def w107g_assert_json_keys(record : Hash(String, JSON::Any), keys : Array(String), label : String) : Nil
  actual = record.keys.sort
  wanted = keys.sort
  raise "#{label}: exact metadata keys differ; expected #{wanted.inspect}, got #{actual.inspect}" unless actual == wanted
end

def w107g_assert_serialization(part : String, label : String) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  w107g_assert_json_keys(info, ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"], "#{label} serialization envelope")
  raise "#{label}: serializer version differs" unless info["version"]?.try(&.as_i) == 1
  raise "#{label}: nested type propagation differs" unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: serialization version map missing"
  raise "#{label}: exact type-version map differs" unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
  records = info["columns"]?.try(&.as_a) || raise "#{label}: serializer columns missing"
  names = records.map { |record| record.as_h["name"]?.try(&.as_s) || raise "#{label}: serializer root name missing" }
  # Pinned stock RED observed the generic Array root omitted from Default
  # serializer statistics; only the independent UInt64 key is recorded.
  raise "#{label}: generic Array unexpectedly acquired recursive serializer records: #{names.inspect}" unless names == ["pk"]
  pk = records[0].as_h
  w107g_assert_json_keys(pk, ["kind", "name", "num_defaults", "num_rows"], "#{label} primary key")
  raise "#{label}: primary key serializer differs" unless pk["kind"]?.try(&.as_s) == "Default" && pk["name"]?.try(&.as_s) == "pk" && pk["num_rows"]?.try(&.as_i) == W107G_KEYS.size.to_i64 && pk["num_defaults"]?.try(&.as_i) == 0_i64
  puts "PASS #{label}: exact generic Array metadata envelope; no invented recursive Tuple statistics"
  nil
end

def w107g_assert_layout(part : String, fields : Array(W107GreenField), writer_profile : Bool, label : String, all_empty : Bool = false) : Nil
  actual_columns = File.read(File.join(part, "columns.txt"))
  raise "#{label}: exact columns.txt differs" unless actual_columns == w107g_expected_columns
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  expected_substreams = w107g_expected_substreams(fields)
  raise "#{label}: exact recursive substream order differs:\nexpected:\n#{expected_substreams}actual:\n#{actual_substreams}" unless actual_substreams == expected_substreams
  raise "#{label}: LZ4 codec differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  raise "#{label}: metadata version differs" unless File.read(File.join(part, "metadata_version.txt")) == "0"
  raise "#{label}: checksums.txt is missing" unless File.file?(File.join(part, "checksums.txt"))
  raise "#{label}: outer row count differs" unless File.read(File.join(part, "count.txt")) == W107G_KEYS.size.to_s

  streams = w107g_streams(fields, writer_profile, all_empty)
  expected_bins = streams.map { |(name, _)| "#{CrystalClick::StreamName.hash(name)}.bin" }.sort
  expected_marks = streams.map { |(name, _)| "#{CrystalClick::StreamName.hash(name)}.mrk2" }.sort
  entries = Dir.children(part)
  actual_bins = entries.select(&.ends_with?(".bin")).sort
  actual_marks = entries.select(&.ends_with?(".mrk2")).sort
  raise "#{label}: exact data-stream inventory differs: #{actual_bins.inspect}" unless actual_bins == expected_bins
  raise "#{label}: exact marks inventory differs: #{actual_marks.inspect}" unless actual_marks == expected_marks
  raise "#{label}: unexpected alternate mark files" if entries.any? { |entry| entry.ends_with?(".cmrk2") || entry.ends_with?(".mrk") }

  streams.each do |name, fragments|
    encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(name)}.bin")).to_slice
    expected_raw = fragments.join
    # A whole all-empty Array(Tuple) profile has legal zero-byte leaf files.
    # Accept that representation only when the independently encoded stream
    # is also empty; non-empty files still pass through the normal decoder and
    # exact byte comparison below.
    raw = if encoded.empty?
            raise "#{label} #{name}: empty encoded file has non-empty independent raw expectation" unless expected_raw.empty?
            ""
          else
            String.new(CrystalClick::CompressedBlock.decode_all(encoded))
          end
    w107g_assert_bytes(raw, expected_raw, "#{label} #{name} raw bytes")
    actual_marks = w107g_actual_marks(part, name)
    expected_marks = writer_profile ? w107g_expected_writer_marks(name, fragments, all_empty) : w107g_expected_stock_marks(name, fragments, all_empty)
    raise "#{label} #{name}: exact mark tuples differ; expected #{expected_marks.inspect}, got #{actual_marks.inspect}" unless actual_marks == expected_marks
    if name == "payload%2Eleft%2Edetails%2Estate" && !expected_raw.empty?
      w107g_seeded_comparator(raw, expected_raw, "#{label} nested Enum leaf")
    end
  end
  w107g_assert_serialization(part, label)
  puts "PASS #{label}: declaration, escaped paths, #{streams.size} raw streams, exact outer/element-axis marks and generic Array metadata"
  nil
end

def w107g_insert_into(binary : String, store : String, table : String, fields : Array(W107GreenField), all_empty : Bool = false) : Nil
  w107g_create_table(binary, store, table)
  w107g_insert(binary, store, table, fields, all_empty)
  nil
end

def w107g_stock_seed(binary : String, store : String, table : String, fields : Array(W107GreenField), all_empty : Bool = false) : String
  w107g_insert_into(binary, store, table, fields, all_empty)
  source_part = w107g_part_path(binary, store, table)
  w107g_schema(binary, store, table)
  w107g_assert_layout(source_part, fields, false, "W107 stock #{table}", all_empty)
  w107g_check(binary, store, table, source_part)
  w107g_assert_rowbinary(binary, store, table, fields, "W107 stock #{table}", false, all_empty)
  source_part
end

def w107g_attach_and_certify(binary : String, store : String, table : String, source_part : String, fields : Array(W107GreenField), writer_profile : Bool, label : String, all_empty : Bool = false) : String
  attached_part = w107g_attach(binary, store, table, source_part)
  w107g_schema(binary, store, table)
  w107g_assert_layout(attached_part, fields, writer_profile, "#{label} ATTACH", all_empty)
  w107g_check(binary, store, table, attached_part)
  w107g_assert_rowbinary(binary, store, table, fields, "#{label} ATTACH", writer_profile, all_empty)
  attached_part
end

def w107g_expected_node_type(node : W107GreenNode, fields : Array(W107GreenField)) : String
  if node.tuple?
    "Tuple(#{node.children.map { |child| "#{child.name} #{w107g_expected_node_type(child, fields)}" }.join(", ")})"
  else
    fields[w107g_field_index(fields, node.path)].type_name
  end
end

def w107g_assert_schema_tree(actual_nodes : Array(CrystalClick::WideTupleSchemaNode), expected_nodes : Array(W107GreenNode), fields : Array(W107GreenField), label : String) : Nil
  raise "#{label}: schema tree width differs" unless actual_nodes.size == expected_nodes.size
  actual_nodes.each_with_index do |actual, index|
    expected = expected_nodes[index]
    raise "#{label}: local node name differs at #{expected.path}" unless actual.name == expected.name
    raise "#{label}: exact subtree declaration differs at #{expected.path}" unless actual.type_name == w107g_expected_node_type(expected, fields)
    if expected.tuple?
      raise "#{label}: tuple node unexpectedly exposes a terminal leaf" unless actual.leaf_field?.nil?
      w107g_assert_schema_tree(actual.children, expected.children, fields, label)
    else
      leaf = actual.leaf_field? || raise "#{label}: terminal schema node lost its leaf descriptor"
      field = fields[w107g_field_index(fields, expected.path)]
      raise "#{label}: local terminal type differs at #{expected.path}" unless leaf.type_name == field.type_name
    end
  end
  nil
end

def w107g_physical_bytes(column : CrystalClick::WideTupleLeafColumn, field : W107GreenField, row : Int32) : String
  values = column.physical_values
  case field.base_type
  when "String"
    values.as(Array(String))[row]
  when "UInt64"
    w107g_unsigned_le(values.as(Array(UInt64))[row], 8)
  when "UInt32"
    w107g_unsigned_le(values.as(Array(UInt32))[row].to_u64, 4)
  when "Bool"
    w107g_byte(values.as(Array(UInt8))[row])
  when "Enum8('neg' = -7, 'pos' = 7)"
    w107g_signed_le(values.as(Array(Int8))[row].to_i64, 1)
  when "Decimal(9, 2)"
    w107g_signed_le(values.as(Array(Int32))[row].to_i64, 4)
  when "DateTime64(3, 'America/New_York')", "DateTime64(9, 'UTC')"
    w107g_signed_le(values.as(Array(CrystalClick::DateTime64Value))[row].raw, 8)
  when "FixedString(3)"
    String.new(values.as(Array(CrystalClick::FixedStringValue))[row].raw_bytes)
  else
    raise "#{field.name}: no physical decoder in independent W107 fixture"
  end
end

def w107g_read_unsigned_le(bytes : Bytes) : UInt64
  raise "independent W107 decoder supports at most eight bytes" if bytes.size > 8
  value = 0_u64
  bytes.each_with_index do |byte, index|
    value |= byte.to_u64 << (index * 8)
  end
  value
end

def w107g_assert_logical(column : CrystalClick::WideTupleLeafColumn, field : W107GreenField, row : Int32, fragment : String, label : String, expected_row : Int32) : Nil
  value = column.value_at(row)
  if field.nullable && field.values[expected_row].nil?
    raise "#{label}: #{field.name} row #{row} must be logically NULL" unless value.nil?
    return
  end
  raise "#{label}: #{field.name} row #{row} unexpectedly NULL" if value.nil?
  case field.base_type
  when "String"
    raise "#{label}: String semantic value differs" unless value.as(String) == fragment
  when "Bool"
    wanted = fragment.to_slice[0] != 0_u8
    raise "#{label}: Bool false/true/nonzero interpretation differs" unless value.as(Bool) == wanted
  when "Enum8('neg' = -7, 'pos' = 7)"
    enum_value = value.as(CrystalClick::Enum8Value)
    wanted = fragment.to_slice[0].unsafe_as(Int8)
    expected_label = wanted == -7_i8 ? "neg" : wanted == 7_i8 ? "pos" : raise "#{label}: fixture Enum code is not declared"
    raise "#{label}: Enum physical code differs" unless enum_value.code == wanted
    raise "#{label}: Enum label differs" unless enum_value.label == expected_label
  when "Decimal(9, 2)"
    decimal = value.as(CrystalClick::Decimal32Value)
    wanted = w107g_read_unsigned_le(fragment.to_slice[0, 4]).to_u32.unsafe_as(Int32)
    raise "#{label}: Decimal coefficient differs" unless decimal.raw == wanted
    raise "#{label}: Decimal precision/scale differs" unless decimal.precision == 9 && decimal.scale == 2
  when "DateTime64(3, 'America/New_York')", "DateTime64(9, 'UTC')"
    temporal = value.as(CrystalClick::DateTime64Value)
    wanted = w107g_read_unsigned_le(fragment.to_slice[0, 8]).unsafe_as(Int64)
    precision = field.base_type == "DateTime64(3, 'America/New_York')" ? 3_u8 : 9_u8
    raise "#{label}: raw DateTime64 ticks/precision differ" unless temporal.raw == wanted && temporal.precision == precision
  when "UInt64"
    wanted = w107g_read_unsigned_le(fragment.to_slice[0, 8])
    raise "#{label}: UInt64 semantic value differs" unless value.as(UInt64) == wanted
  when "UInt32"
    wanted = w107g_read_unsigned_le(fragment.to_slice[0, 4]).to_u32
    raise "#{label}: UInt32 semantic value differs" unless value.as(UInt32) == wanted
  when "FixedString(3)"
    raise "#{label}: FixedString raw bytes differ" unless value.as(CrystalClick::FixedStringValue).raw_bytes == fragment.to_slice
  else
    raise "#{label}: missing logical assertion for #{field.base_type}"
  end
  nil
end

def w107g_assert_datetime_identity(column : CrystalClick::WideTupleLeafColumn, field : W107GreenField, label : String) : Nil
  return unless field.base_type.starts_with?("DateTime64")
  descriptor = column.datetime_type || raise "#{label}: #{field.name} lost DateTime64 descriptor"
  expected_zone = field.base_type.includes?("America/New_York") ? "America/New_York" : "UTC"
  expected_precision = expected_zone == "UTC" ? 9_u8 : 3_u8
  raise "#{label}: exact timezone or scale differs for #{field.name}" unless descriptor.time_zone?.try(&.name) == expected_zone && descriptor.precision? == expected_precision
end

def w107g_check_tuple_data(tuple_data : CrystalClick::WideTupleColumnData, fields : Array(W107GreenField), element_count : Int32, label : String, writer_profile : Bool, first_element : Int32 = 0) : Nil
  raise "#{label}: flattened element count differs" unless tuple_data.row_count == element_count
  raise "#{label}: exact inner Tuple declaration differs" unless tuple_data.type_name == W107G_TUPLE_TYPE
  expected_fields = fields.map { |field| {field.name, field.type_name} }
  raise "#{label}: flattened declaration order/path differs" unless tuple_data.fields.map { |field| {field.name, field.type_name} } == expected_fields
  tree = w107g_expected_node_tree(fields)
  w107g_assert_schema_tree(tuple_data.root_fields, tree.children, fields, label)

  tuple_data.columns.each_with_index do |column, index|
    field = fields[index]
    raise "#{label}: leaf exact path/type differs for #{field.name}" unless column.name == field.name && column.type_name == field.type_name
    w107g_assert_datetime_identity(column, field, label)
    expected_nulls = field.nullable ? field.null_rows[first_element, element_count] : [] of UInt8
    if field.nullable
      raise "#{label}: null map differs for #{field.name}" unless column.null_map.try(&.bytes) == expected_nulls
    else
      raise "#{label}: bare field acquired null-map metadata" unless column.null_map.nil?
    end
    fragments = field.stream_rows(writer_profile)[first_element, element_count]
    element_count.times do |element|
      w107g_assert_bytes(w107g_physical_bytes(column, field, element), fragments[element], "#{label} #{field.name} element #{element} physical carrier")
      w107g_assert_logical(column, field, element, fragments[element], label, first_element + element)
    end
    copy = column.owned_copy
    raise "#{label}: owned copy lost exact leaf type/path" unless copy.name == field.name && copy.type_name == field.type_name
    element_count.times do |element|
      w107g_assert_bytes(w107g_physical_bytes(copy, field, element), fragments[element], "#{label} #{field.name} copied element #{element}")
    end
    if field.nullable
      raise "#{label}: owned copy lost null mask" unless copy.null_map.try(&.bytes) == expected_nulls
    end
  end
  nil
end

def w107g_assert_typed(part : String, fields : Array(W107GreenField), label : String, writer_profile : Bool, all_empty : Bool = false) : CrystalClick::WideArrayTupleColumnData
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "#{label}: exact outer column type differs" unless reader.column_type == W107G_TYPE
  expected_rows = all_empty ? Array(UInt64).new(W107G_KEYS.size, 0_u64) : W107G_ROW_SIZES
  expected_offsets = Array(UInt64).new(expected_rows.size + 1, 0_u64)
  expected_rows.each_with_index { |size, index| expected_offsets[index + 1] = expected_offsets[index] + size }
  data = reader.read_array_tuple_mark_range("payload", 0, reader.mark_count)
  raise "#{label}: outer row count differs" unless data.row_count == W107G_KEYS.size
  raise "#{label}: flattened element count differs" unless data.element_count == expected_offsets.last.to_i32
  raise "#{label}: detached physical row-size schedule differs" unless data.row_sizes == expected_rows
  raise "#{label}: detached cumulative offsets differ" unless data.offsets == expected_offsets
  raise "#{label}: exact outer mark schedule differs" unless reader.mark_row_counts == W107G_MARK_ROWS[0, W107G_MARK_ROWS.size - 1]
  w107g_check_tuple_data(data.tuple_data, fields, data.element_count, label, writer_profile)

  W107G_KEYS.size.times do |row_index|
    outer_row = data.row(row_index.to_i32)
    expected_indices = all_empty ? [] of Int32 : W107G_ROW_ELEMENTS[row_index]
    raise "#{label}: outer row #{row_index} element count differs" unless outer_row.size == expected_indices.size
    expected_indices.each_with_index do |element_index, slot|
      tuple_row = outer_row[slot]
      raise "#{label}: nested element declaration differs" unless tuple_row.type_name == W107G_TUPLE_TYPE
      raise "#{label}: repeated local names collided across paths" unless tuple_row.tuple("left.details").fields.map(&.name) == ["state", "flag", "note", "event", "amount"] && tuple_row.tuple("right.details").fields.map(&.name) == ["state", "note", "event"]
      raise "#{label}: independent id carrier differs" unless tuple_row["id"].as(UInt64) == w107g_read_unsigned_le(fields[0].stream_rows(writer_profile)[element_index].to_slice)
      if element_index == 2
        raise "#{label}: left Enum visible code/label differs" unless tuple_row.tuple("left.details").value_as("state", CrystalClick::Enum8Value).label == "pos"
        raise "#{label}: right Enum visible code/label differs" unless tuple_row.tuple("right.details").value_as("state", CrystalClick::Enum8Value).label == "neg"
        raise "#{label}: noncanonical visible Bool must remain true" unless tuple_row.tuple("left.details").value_as("flag", Bool)
      end
    end
  end

  # Mark 0, 2, and 4 are empty-element ranges: they must still retain their
  # outer rows and invoke the lazy callback while yielding zero Tuple leaves.
  empty_mark = reader.read_array_tuple_mark_range("payload", 0, 1)
  raise "#{label}: empty-element selected mark lost its outer rows" unless empty_mark.row_count == 2 && empty_mark.element_count == 0 && empty_mark.row_sizes == [0_u64, 0_u64]
  selected = reader.read_array_tuple_mark_range("payload", 1, 1)
  raise "#{label}: selected ragged mark schedule differs" unless selected.row_count == 2 && selected.row_sizes == (all_empty ? [0_u64, 0_u64] : [2_u64, 0_u64])
  raise "#{label}: selected element count differs" unless selected.element_count == (all_empty ? 0 : 2)
  selected_first_element = w107g_element_boundary(W107G_BOUNDARIES[1], all_empty)
  w107g_check_tuple_data(selected.tuple_data, fields, selected.element_count, "#{label} selected mark", writer_profile, selected_first_element)

  # Mark 3 starts after the two populated elements from mark 1. This separate
  # control exercises a nonzero flattened-element origin; the all-empty part
  # keeps the same two outer rows but correctly has no flattened offset.
  offset_control = reader.read_array_tuple_mark_range("payload", 3, 1)
  expected_offset_sizes = all_empty ? [0_u64, 0_u64] : [1_u64, 1_u64]
  expected_offset_prefixes = all_empty ? [0_u64, 0_u64, 0_u64] : [0_u64, 1_u64, 2_u64]
  raise "#{label}: nonzero-origin selected outer schedule differs" unless offset_control.row_count == 2 && offset_control.row_sizes == expected_offset_sizes &&
                                                                          offset_control.offsets == expected_offset_prefixes && offset_control.element_count == (all_empty ? 0 : 2)
  offset_first_element = w107g_element_boundary(W107G_BOUNDARIES[3], all_empty)
  raise "#{label}: fixture must exercise flat element origin 2" unless all_empty || offset_first_element == 2
  w107g_check_tuple_data(
    offset_control.tuple_data,
    fields,
    offset_control.element_count,
    "#{label} nonzero-origin selected mark",
    writer_profile,
    offset_first_element
  )
  unless all_empty
    raise "#{label}: first outer row did not map from flat element 2" unless offset_control.row(0)[0]["id"].as(UInt64) == 7_u64
    raise "#{label}: second outer row did not map from flat element 3" unless offset_control.row(1)[0]["id"].as(UInt64) == 2_u64
  end

  callbacks = [] of {Int32, Int32, Int32}
  row_cursor = 0
  reader.each_array_tuple_mark_range("payload", 0, reader.mark_count) do |mark_data, mark_index|
    expected_rows = W107G_MARK_ROWS[mark_index].to_i32
    expected_size_slice = if all_empty
                            Array(UInt64).new(expected_rows, 0_u64)
                          elsif expected_rows == 0
                            [] of UInt64
                          else
                            W107G_ROW_SIZES[row_cursor, expected_rows]
                          end
    expected_elements = expected_size_slice.sum.to_i32
    raise "#{label}: lazy mark #{mark_index} row/element schedule differs" unless mark_data.row_count == expected_rows && mark_data.row_sizes == expected_size_slice && mark_data.element_count == expected_elements
    expected_first_element = w107g_element_boundary(row_cursor.to_i32, all_empty)
    w107g_check_tuple_data(
      mark_data.tuple_data,
      fields,
      expected_elements,
      "#{label} lazy mark #{mark_index}",
      writer_profile,
      expected_first_element
    )
    callbacks << {mark_index, mark_data.row_count, mark_data.element_count}
    row_cursor += mark_data.row_count
  end
  raise "#{label}: lazy callbacks lost empty-element marks or row count" unless callbacks.map { |entry| entry[0] } == [0_i32, 1_i32, 2_i32, 3_i32, 4_i32] && row_cursor == W107G_KEYS.size
  puts "PASS #{label}: 13 nested leaves, raw carriers/NULL masks, exact scopes, empty-element marks, selected/lazy reads"
  data
end

def w107g_assert_consumers(part : String, fields : Array(W107GreenField), label : String, writer_profile : Bool = false, all_empty : Bool = false) : Nil
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
  raise "#{label}: table exact payload declaration differs" unless table.column_types.any? { |name, type| name == "payload" && type == W107G_TYPE }
  table_rows = [] of CrystalClick::WideArrayTupleRow
  table.scan_typed(batch_rows: 3) do |batch|
    batch.values_for("pk").each_with_index do |key, offset|
      index = (key / 10_u64 - 1_u64).to_i32
      row = batch.array_tuple_rows_for("payload")[offset]
      expected_size = all_empty ? 0_u64 : W107G_ROW_SIZES[index]
      raise "#{label}: table row size/type identity differs" unless row.size.to_u64 == expected_size
      if row.size > 0
        raise "#{label}: table nested scope differs" unless row[0].tuple("right.details").fields.map(&.name) == ["state", "note", "event"]
      end
      table_rows << row
      raise "#{label}: table PK-to-fixture alignment differs" unless key == W107G_KEYS[index]
    end
  end
  raise "#{label}: table full scan row count differs" unless table_rows.size == W107G_KEYS.size

  table_window = [] of CrystalClick::WideArrayTupleRow
  table.scan_typed_window(2_u64, 3) do |batch|
    table_window.concat(batch.array_tuple_rows_for("payload"))
  end
  raise "#{label}: table window lost empty/nested rows" unless table_window.size == 3 && table_window.map(&.size) == (all_empty ? [0, 0, 0] : [2, 0, 0])

  catalog_base = ENV["W107G_CATALOG_ROOT"]? || raise "set W107G_CATALOG_ROOT to an isolated temporary catalog directory"
  catalog_suffix = label.downcase.gsub(/[^a-z0-9]+/, "-").strip('-')
  catalog_root = File.join(catalog_base, catalog_suffix)
  w107g_catalog_root(catalog_root, part)
  offline = CrystalClick::OfflineCatalog.open(catalog_root)["lab"]["events"]
  values = offline["payload"].values(max_tuple_cells: 1000_u64)
  raise "#{label}: catalog materialized outer row count differs" unless values.size == W107G_KEYS.size
  enum_field = fields.find { |field| field.name == "left.details.state" } || raise "W107 consumer fixture has no left Enum leaf"
  enum_part = CrystalClick::WidePart.open_typed(part, "payload")
  enum_data = enum_part.read_array_tuple_mark_range("payload", 0, enum_part.mark_count)
  enum_column = enum_data.tuple_data[enum_field.name]
  raise "#{label}: consumer source Enum mask differs" unless enum_column.null_map.try(&.bytes) == enum_field.null_rows

  values.each_with_index do |value, index|
    row = value.as(CrystalClick::WideArrayTupleRow)
    expected_size = all_empty ? 0_u64 : W107G_ROW_SIZES[index]
    raise "#{label}: catalog values lost row size" unless row.size.to_u64 == expected_size
    if row.size > 0 && index == 2
      flat_origin = W107G_ROW_SIZES[0, index].sum.to_i32
      left_first = row[0].tuple("left.details")
      raise "#{label}: first catalog nested Enum should be NULL" unless left_first["state"].nil?
      raise "#{label}: consumer source NULL Enum lost its exact hidden carrier" unless w107g_physical_bytes(enum_column, enum_field, flat_origin) == enum_field.stream_rows(writer_profile)[flat_origin]
      raise "#{label}: consumer source NULL Enum lost its exact mask byte" unless enum_column.null_map.not_nil!.bytes[flat_origin] == 1_u8 && enum_field.null_rows[flat_origin] == 1_u8

      flat_next = flat_origin + 1
      left_next = row[1].tuple("left.details")
      right_next = row[1].tuple("right.details")
      raise "#{label}: second catalog element lost left Enum 'neg'" unless left_next.value_as("state", CrystalClick::Enum8Value).label == "neg"
      raise "#{label}: second catalog element lost right Enum 'pos'" unless right_next.value_as("state", CrystalClick::Enum8Value).label == "pos"
      raise "#{label}: consumer Enum flat-prefix fixture is misaligned" unless enum_field.values[flat_origin].nil? && enum_field.values[flat_next] == w107g_signed_le(-7_i64, 1)
    end
  end
  catalog_scan = [] of CrystalClick::WideArrayTupleRow
  offline.scan_typed(["pk", "payload"], batch_rows: 3) do |batch|
    catalog_scan.concat(batch.array_tuple_rows_for("payload"))
  end
  raise "#{label}: catalog full scan lost rows" unless catalog_scan.size == W107G_KEYS.size
  catalog_window = [] of CrystalClick::WideArrayTupleRow
  offline.scan_typed_window(["pk", "payload"], 2_u64, 3) do |batch|
    catalog_window.concat(batch.array_tuple_rows_for("payload"))
  end
  raise "#{label}: catalog window lost empty-element alignment" unless catalog_window.size == 3 && catalog_window.map(&.size) == table_window.map(&.size)
  puts "PASS #{label}: table/catalog values, full scans and windows retain outer rows, empty elements and nested identity"
  nil
end

def w107g_catalog_root(root : String, part : String) : String
  raise "refusing existing W107 catalog path: #{root}" if Dir.exists?(root)
  metadata = File.join(root, "metadata")
  database_uuid = "10700000-0000-4000-8000-000000000001"
  table_uuid = "10700000-0000-4000-8000-000000000002"
  database = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(File.join(database, "events.sql"), "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{W107G_TYPE}\n)\nENGINE = MergeTree\nORDER BY pk\n")
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  FileUtils.cp_r(part, File.join(table, "all_1_1_0"))
  root
end

def w107g_writer_columns(source : Array(CrystalClick::WideTupleLeafColumn), fields : Array(W107GreenField), all_empty : Bool = false) : Array(CrystalClick::WideTupleLeafColumn)
  raise "writer source/fixture leaf count differs" unless source.size == fields.size
  source.map_with_index do |column, index|
    field = fields[index]
    raise "writer source order/path differs at #{field.name}" unless column.name == field.name && column.type_name == field.type_name
    next column.owned_copy if all_empty
    fragments = field.stream_rows(true)
    null_map = column.null_map
    case field.base_type
    when "Enum8('neg' = -7, 'pos' = 7)"
      raw = column.physical_values.as(Array(Int8))
      fragments.each_with_index do |fragment, row|
        raw[row] = fragment.to_slice[0].unsafe_as(Int8) if null_map.try(&.null_at?(row))
      end
      CrystalClick::WideTupleLeafColumn.new(column.name, column.leaf_type, raw, null_map)
    when "Bool"
      raw = column.physical_values.as(Array(UInt8))
      fragments.each_with_index do |fragment, row|
        raw[row] = fragment.to_slice[0] if null_map.try(&.null_at?(row))
      end
      # A visible noncanonical true byte is a separate adversarial control.
      raw[2] = 2_u8
      CrystalClick::WideTupleLeafColumn.new(column.name, column.leaf_type, raw, null_map)
    when "String"
      raw = column.physical_values.as(Array(String))
      fragments.each_with_index do |fragment, row|
        raw[row] = fragment if null_map.try(&.null_at?(row))
      end
      CrystalClick::WideTupleLeafColumn.new(column.name, column.leaf_type, raw, null_map)
    when "Decimal(9, 2)"
      raw = column.physical_values.as(Array(Int32))
      fragments.each_with_index do |fragment, row|
        raw[row] = w107g_read_unsigned_le(fragment.to_slice[0, 4]).to_u32.unsafe_as(Int32) if null_map.try(&.null_at?(row))
      end
      CrystalClick::WideTupleLeafColumn.new(column.name, column.leaf_type, raw, null_map)
    else
      column.owned_copy
    end
  end
end

def w107g_assert_fixture_shape(fields : Array(W107GreenField)) : Nil
  raise "W107 profile must contain exactly thirteen terminal leaves" unless fields.size == 13
  raise "W107 independent mixed fixture must flatten to four Tuple rows" unless fields.all? { |field| field.values.size == 4 }
  raise "W107 outer row sizes do not sum to four elements" unless W107G_ROW_SIZES.sum == 4_u64
  raise "W107 outer row/element fixture cardinalities differ" unless W107G_ROW_SIZES.map(&.to_i32) == W107G_ROW_ELEMENTS.map(&.size)
  offsets = [0_u64]
  W107G_ROW_SIZES.each { |size| offsets << offsets.last + size }
  raise "W107 cumulative element offsets differ from independently listed values" unless offsets[1, W107G_SIZE0.size] == W107G_SIZE0
  raise "W107 mark boundaries differ from two-row source granules plus final row" unless W107G_BOUNDARIES == [0, 2, 4, 6, 8, 9]
  raise "W107 fixture declaration differs from independently listed nested Tuple" unless W107G_TYPE == "Array(#{W107G_TUPLE_TYPE})"
  nil
end

def w107g_assert_writer_inputs(columns : Array(CrystalClick::WideTupleLeafColumn), fields : Array(W107GreenField), all_empty : Bool = false) : Nil
  raise "writer input/fixture leaf count differs" unless columns.size == fields.size
  columns.each_with_index do |column, index|
    field = fields[index]
    expected = all_empty ? [] of String : field.stream_rows(true)
    raise "writer input path/type differs at #{field.name}" unless column.name == field.name && column.type_name == field.type_name
    raise "writer input cardinality differs at #{field.name}" unless column.size == expected.size
    if field.nullable
      raise "writer input mask differs at #{field.name}" unless column.null_map.try(&.bytes) == field.null_rows
    else
      raise "bare writer input has a NULL mask at #{field.name}" unless column.null_map.nil?
    end
    expected.each_with_index do |fragment, row|
      w107g_assert_bytes(w107g_physical_bytes(column, field, row.to_i32), fragment, "independent writer input #{field.name} row #{row}")
      w107g_assert_logical(column, field, row.to_i32, fragment, "independent writer input", row.to_i32)
    end
  end
  puts "PASS independent writer inputs: #{fields.size} exact nested leaves#{all_empty ? " (zero elements)" : ", including masked adversarial carriers"}"
  nil
end

def w107g_run_reader(binary : String, store : String, fields : Array(W107GreenField)) : Nil
  source = w107g_stock_seed(binary, store, "w107g_reader_source", fields)
  attached = w107g_attach_and_certify(binary, store, "w107g_reader_attached", source, fields, false, "W107 reader stock")
  w107g_assert_typed(attached, fields, "W107 stock typed reader", false)
  w107g_assert_consumers(attached, fields, "W107 stock consumers")

  empty_fields = w107g_fields(true)
  empty_source = w107g_stock_seed(binary, store, "w107g_reader_empty_source", empty_fields, true)
  empty_attached = w107g_attach_and_certify(binary, store, "w107g_reader_empty_attached", empty_source, empty_fields, false, "W107 all-empty stock", true)
  w107g_assert_typed(empty_attached, empty_fields, "W107 all-empty typed reader", false, true)
  w107g_assert_consumers(empty_attached, empty_fields, "W107 all-empty consumers", false, true)
  puts "PASS W107 --green-reader: nested representative profile; W105 separately certifies all 53 flat Nullable declarations"
  nil
end

def w107g_run_writer(binary : String, store : String, fields : Array(W107GreenField)) : Nil
  source = w107g_stock_seed(binary, store, "w107g_writer_seed", fields)
  attached_seed = w107g_attach_and_certify(binary, store, "w107g_writer_seed_attached", source, fields, false, "W107 writer input stock")
  typed_seed = w107g_assert_typed(attached_seed, fields, "W107 writer input typed seed", false)
  writer_columns = w107g_writer_columns(typed_seed.tuple_data.columns, fields)
  w107g_assert_writer_inputs(writer_columns, fields)
  writer_parent = File.join(store, "w107g_writer_output")
  FileUtils.mkdir_p(writer_parent)
  writer_part = File.join(writer_parent, "all_1_1_0")
  actual = CrystalClick::WidePartWriter.write_uint64_array_tuple_part(
    writer_part, "pk", W107G_KEYS.to_unsafe.to_slice(W107G_KEYS.size),
    "payload", W107G_TYPE, W107G_ROW_SIZES.to_unsafe.to_slice(W107G_ROW_SIZES.size), writer_columns, rows_per_mark: 2
  )
  raise "W107 writer returned another destination" unless actual == writer_part
  w107g_assert_layout(writer_part, fields, true, "W107 Crystal writer")
  attached = w107g_attach_and_certify(binary, store, "w107g_writer_attached", writer_part, fields, true, "W107 writer output")
  w107g_assert_typed(attached, fields, "W107 writer typed roundtrip", true)
  w107g_assert_consumers(attached, fields, "W107 writer consumers", true)

  empty_fields = w107g_fields(true)
  empty_source = w107g_stock_seed(binary, store, "w107g_writer_empty_source", empty_fields, true)
  empty_seed = w107g_attach_and_certify(binary, store, "w107g_writer_empty_seed_attached", empty_source, empty_fields, false, "W107 all-empty writer input", true)
  empty_seed_data = w107g_assert_typed(empty_seed, empty_fields, "W107 all-empty writer typed seed", false, true)
  empty_columns = w107g_writer_columns(empty_seed_data.tuple_data.columns, empty_fields, true)
  w107g_assert_writer_inputs(empty_columns, empty_fields, true)
  empty_sizes = Array(UInt64).new(W107G_KEYS.size, 0_u64)
  empty_writer_parent = File.join(store, "w107g_writer_empty_output")
  FileUtils.mkdir_p(empty_writer_parent)
  empty_writer_part = File.join(empty_writer_parent, "all_1_1_0")
  empty_actual = CrystalClick::WidePartWriter.write_uint64_array_tuple_part(
    empty_writer_part, "pk", W107G_KEYS.to_unsafe.to_slice(W107G_KEYS.size),
    "payload", W107G_TYPE, empty_sizes.to_unsafe.to_slice(empty_sizes.size), empty_columns, rows_per_mark: 2
  )
  raise "W107 all-empty writer returned another destination" unless empty_actual == empty_writer_part
  w107g_assert_layout(empty_writer_part, empty_fields, true, "W107 all-empty Crystal writer", true)
  empty_output = w107g_attach_and_certify(binary, store, "w107g_writer_empty_attached", empty_writer_part, empty_fields, true, "W107 all-empty writer output", true)
  w107g_assert_typed(empty_output, empty_fields, "W107 all-empty writer typed roundtrip", true, true)
  w107g_assert_consumers(empty_output, empty_fields, "W107 all-empty writer consumers", true, true)
  puts "PASS W107 --green-writer: recursive writer frames, masked hidden bytes, stock ATTACH/CHECK/RowBinary and typed copy verified"
  nil
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["W107G_STORE"]? || raise "set W107G_STORE to an empty temporary ClickHouse store"
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary W107G_STORE path: #{store}"
end
if Dir.exists?(store)
  raise "W107G_STORE must be empty: #{store}" unless Dir.empty?(store)
else
  Dir.mkdir_p(store)
end
mode = ARGV.shift? || raise "usage: --green-reader | --green-writer"
raise "unknown W107 GREEN mode: #{mode}" unless {"--green-reader", "--green-writer"}.includes?(mode)
version_output = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version_output)
raise "could not read stock ClickHouse version" unless version_status.success?
expected_version = "ClickHouse local version #{W107G_STOCK_VERSION} (official build)."
raise "W107 GREEN requires #{expected_version}, got #{version_output.to_s.strip}" unless version_output.to_s.strip == expected_version
puts "Stock oracle: #{version_output.to_s.strip}"
fields = w107g_fields
w107g_assert_fixture_shape(fields)
if mode == "--green-reader"
  w107g_run_reader(binary, store, fields)
else
  w107g_run_writer(binary, store, fields)
end
