# Independent stock and Crystal-writer certificates for recursive named Tuple
# leaves. The representative nested family profile complements (does not
# replace) the separate W105 all-53 flat Nullable-leaf matrix.
#
# Run in fresh stores with:
#   --green-reader  stock create/ATTACH certificate, then typed consumers
#   --green-writer  stock seed -> typed read -> Crystal write -> stock attach
require "json"
require "file_utils"
require "../src/crystal_click"

W106G_STOCK_VERSION = "26.7.1.1315"
W106G_TYPE          = "Tuple(id UInt64, left Tuple(details Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), flag Nullable(Bool), note Nullable(String), event DateTime64(3, 'America/New_York'), amount Nullable(Decimal(9, 2))), fixed FixedString(3), count UInt32), right Tuple(details Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), note Nullable(String), event DateTime64(9, 'UTC')), fixed FixedString(3), count UInt64))"
W106G_KEYS          = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]
W106G_BOUNDARIES    = [0, 2, 4, 5]
W106G_MARK_ROWS     = [2_u64, 2_u64, 1_u64, 0_u64]
W106G_SETTINGS      = "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 0.9375, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"

class W106GreenByteMismatch < Exception
end

class W106GreenField
  getter name : String
  getter base_type : String
  getter nullable : Bool
  getter values : Array(String?)

  def initialize(@name : String, @base_type : String, @nullable : Bool, values : Array(String?))
    raise "#{name}: expected five fixture rows" unless values.size == W106G_KEYS.size
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
            next row == 0 ? w106g_signed_le(127_i64, 1) : w106g_signed_le(-128_i64, 1)
          end
        when "left.details.flag"
          if row == 3 && !value.nil?
            next w106g_byte(2_u8)
          elsif value.nil?
            next w106g_byte(row == 0 ? 0xfe_u8 : 0xff_u8)
          end
        when "left.details.note", "right.details.note"
          if value.nil?
            next row == 0 ? "hidden-null-left" : "hidden-null-right"
          end
        when "left.details.amount"
          if value.nil?
            next w106g_signed_le(row == 0 ? Int32::MIN.to_i64 : Int32::MAX.to_i64, 4)
          end
        end
      end
      value || default_fragment
    end
  end

  def null_rows : Array(UInt8)
    values.map { |value| value.nil? ? 1_u8 : 0_u8 }
  end

  def default_at?(row : Int32, writer_profile : Bool = false) : Bool
    return values[row].nil? if nullable
    stream_rows(writer_profile)[row] == default_fragment
  end

  def default_count(writer_profile : Bool = false) : Int32
    values.size.times.count { |row| default_at?(row.to_i32, writer_profile) }.to_i32
  end

  def rowbinary_at(row : Int32, writer_profile : Bool = false) : String
    value = values[row]
    if nullable
      return "\x01" if value.nil?
      fragment = stream_rows(writer_profile)[row]
      return "\x00" + (string? ? w106g_varuint(fragment.bytesize.to_u64) + fragment : fragment)
    end
    fragment = stream_rows(writer_profile)[row]
    string? ? w106g_varuint(fragment.bytesize.to_u64) + fragment : fragment
  end
end

class W106GreenNode
  getter name : String
  getter path : String
  getter children : Array(W106GreenNode)

  def initialize(@name : String, @path : String, @children : Array(W106GreenNode) = [] of W106GreenNode)
  end

  def tuple? : Bool
    !children.empty?
  end
end

def w106g_byte(value : UInt8) : String
  String.new(Bytes[value])
end

def w106g_unsigned_le(value : UInt64, width : Int32) : String
  raise "negative byte width" if width < 0
  low_width = Math.min(width, 8)
  String.build do |output|
    low_width.times { |index| output.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
    (width - low_width).times { output.write_byte(0_u8) }
  end
end

def w106g_signed_le(value : Int64, width : Int32) : String
  raise "negative byte width" if width < 0
  low_width = Math.min(width, 8)
  low = w106g_unsigned_le(value.unsafe_as(UInt64), low_width)
  extension = value < 0 ? 0xff_u8 : 0_u8
  low + String.new(Bytes.new(width - low_width, extension))
end

def w106g_varuint(value : UInt64) : String
  String.build do |output|
    remaining = value
    while remaining >= 0x80_u64
      output.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
      remaining >>= 7
    end
    output.write_byte(remaining.to_u8)
  end
end

def w106g_fields : Array(W106GreenField)
  enum_type = "Enum8('neg' = -7, 'pos' = 7)"
  [
    W106GreenField.new("id", "UInt64", false, [
      w106g_unsigned_le(0_u64, 8), w106g_unsigned_le(100_u64, 8),
      w106g_unsigned_le(2_u64, 8), w106g_unsigned_le(UInt64::MAX, 8), w106g_unsigned_le(0_u64, 8),
    ] of String?),
    W106GreenField.new("left.details.state", enum_type, true, [nil, w106g_signed_le(-7_i64, 1), w106g_signed_le(7_i64, 1), nil, nil] of String?),
    W106GreenField.new("left.details.flag", "Bool", true, [nil, w106g_byte(0_u8), w106g_byte(1_u8), w106g_byte(1_u8), nil] of String?),
    W106GreenField.new("left.details.note", "String", true, [nil, "", "a\0b", "tail", nil] of String?),
    W106GreenField.new("left.details.event", "DateTime64(3, 'America/New_York')", false, [
      w106g_signed_le(0_i64, 8), w106g_signed_le(-1_i64, 8),
      w106g_signed_le(1_615_705_200_001_i64, 8), w106g_signed_le(1_636_264_800_001_i64, 8), w106g_signed_le(0_i64, 8),
    ] of String?),
    W106GreenField.new("left.details.amount", "Decimal(9, 2)", true, [
      nil, w106g_signed_le(100_i64, 4), w106g_signed_le(-22_i64, 4), w106g_signed_le(-999_999_999_i64, 4), nil,
    ] of String?),
    W106GreenField.new("left.fixed", "FixedString(3)", false, ["\0\0\0", "abc", "xyz", "end", "\0\0\0"] of String?),
    W106GreenField.new("left.count", "UInt32", false, [
      w106g_unsigned_le(0_u64, 4), w106g_unsigned_le(0_u64, 4),
      w106g_unsigned_le(UInt32::MAX.to_u64, 4), w106g_unsigned_le(7_u64, 4), w106g_unsigned_le(0_u64, 4),
    ] of String?),
    W106GreenField.new("right.details.state", enum_type, true, [nil, w106g_signed_le(7_i64, 1), w106g_signed_le(-7_i64, 1), nil, nil] of String?),
    W106GreenField.new("right.details.note", "String", true, [nil, "right", "", "end", nil] of String?),
    W106GreenField.new("right.details.event", "DateTime64(9, 'UTC')", false, [
      w106g_signed_le(0_i64, 8), w106g_signed_le(-1_i64, 8),
      w106g_signed_le(1_615_705_200_000_000_001_i64, 8), w106g_signed_le(1_636_264_800_000_000_001_i64, 8),
      w106g_signed_le(0_i64, 8),
    ] of String?),
    W106GreenField.new("right.fixed", "FixedString(3)", false, ["\0\0\0", "def", "rst", "hi!", "\0\0\0"] of String?),
    W106GreenField.new("right.count", "UInt64", false, [
      w106g_unsigned_le(0_u64, 8), w106g_unsigned_le(99_u64, 8),
      w106g_unsigned_le(0_u64, 8), w106g_unsigned_le(UInt64::MAX, 8), w106g_unsigned_le(0_u64, 8),
    ] of String?),
  ] of W106GreenField
end

def w106g_streams(fields : Array(W106GreenField), writer_profile : Bool = false) : Array({String, Array(String)})
  streams = [{"pk", W106G_KEYS.map { |key| w106g_unsigned_le(key, 8) }}] of {String, Array(String)}
  fields.each do |field|
    rows = field.stream_rows(writer_profile)
    streams << {"#{field.stream_name}.null", field.null_rows.map { |value| w106g_byte(value) }} if field.nullable
    streams << {"#{field.stream_name}.size", rows.map { |value| w106g_unsigned_le(value.bytesize.to_u64, 8) }} if field.string?
    streams << {field.stream_name, rows}
  end
  streams
end

def w106g_expected_columns : String
  "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{W106G_TYPE}\n"
end

def w106g_expected_substreams(fields : Array(W106GreenField)) : String
  names = fields.flat_map do |field|
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

def w106g_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  offset = 0
  while offset < limit && actual.to_slice[offset] == expected.to_slice[offset]
    offset += 1
  end
  got = offset < actual.bytesize ? actual.to_slice[offset].to_s(16).rjust(2, '0') : "<eof>"
  wanted = offset < expected.bytesize ? expected.to_slice[offset].to_s(16).rjust(2, '0') : "<eof>"
  raise W106GreenByteMismatch.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first difference #{offset}: expected #{wanted}, got #{got}")
end

def w106g_seeded_comparator(actual : String, expected : String, label : String) : Nil
  w106g_assert_bytes(actual, expected, "#{label} baseline")
  raise "#{label}: cannot seed empty stream" if expected.empty?
  damaged = String.new(expected.to_slice)
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 0x01_u8
  rejected = false
  begin
    w106g_assert_bytes(actual, damaged, "#{label} seeded mismatch")
  rescue ex : W106GreenByteMismatch
    rejected = true
  end
  raise "#{label}: seeded comparator accepted the mismatch" unless rejected
  puts "PASS #{label}: seeded one-byte mismatch rejected"
end

def w106g_run(binary : String, store : String, query : String, input : IO? = nil) : String
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

def w106g_create_table(binary : String, store : String, table : String) : Nil
  w106g_run(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{W106G_TYPE}) ENGINE = MergeTree ORDER BY pk SETTINGS #{W106G_SETTINGS}")
  nil
end

def w106g_expected_rowbinary(fields : Array(W106GreenField), indexes : Array(Int32), writer_profile : Bool = false) : String
  String.build do |output|
    indexes.each do |row|
      output << w106g_unsigned_le(W106G_KEYS[row], 8)
      fields.each { |field| output << field.rowbinary_at(row, writer_profile) }
    end
  end
end

def w106g_insert(binary : String, store : String, table : String, fields : Array(W106GreenField)) : Nil
  data = w106g_expected_rowbinary(fields, [0, 1, 2, 3, 4])
  w106g_run(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", IO::Memory.new(data.to_slice))
  nil
end

def w106g_part_path(binary : String, store : String, table : String) : String
  rows = w106g_run(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{table}: expected one five-row Wide part, got #{rows.inspect}" unless rows.size == 1
  parts = rows[0].split('\t')
  raise "#{table}: malformed active-part record #{rows[0].inspect}" unless parts.size == 3 && parts[1] == "Wide" && parts[2] == W106G_KEYS.size.to_s
  parts[0]
end

def w106g_schema(binary : String, store : String, table : String) : Nil
  actual = w106g_run(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  expected = ["pk UInt64", "payload #{W106G_TYPE}"]
  raise "#{table}: exact schema differs: #{actual.inspect}" unless actual == expected
  nil
end

def w106g_attach(binary : String, store : String, table : String, source_part : String) : String
  w106g_create_table(binary, store, table)
  data_path = w106g_run(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: empty ClickHouse data path" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(source_part, File.join(detached, "all_1_1_0"))
  w106g_run(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w106g_part_path(binary, store, table)
end

def w106g_check(binary : String, store : String, table : String, part : String) : Nil
  actual = w106g_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table}: CHECK TABLE differs: #{actual.inspect}" unless actual == expected
  nil
end

def w106g_select(binary : String, store : String, table : String, fields : Array(W106GreenField), selected : Bool = false) : String
  projection = ["pk"] + fields.map { |field| "payload.#{field.name}" }
  predicate = selected ? " WHERE pk >= 20 AND pk < 50" : ""
  w106g_run(binary, store, "SELECT #{projection.join(", ")} FROM default.#{table}#{predicate} ORDER BY pk FORMAT RowBinary")
end

def w106g_assert_rowbinary(binary : String, store : String, table : String, fields : Array(W106GreenField), label : String, writer_profile : Bool = false) : Nil
  full = w106g_select(binary, store, table, fields)
  w106g_assert_bytes(full, w106g_expected_rowbinary(fields, [0, 1, 2, 3, 4], writer_profile), "#{label} full RowBinary")
  selected = w106g_select(binary, store, table, fields, true)
  w106g_assert_bytes(selected, w106g_expected_rowbinary(fields, [1, 2, 3], writer_profile), "#{label} selected RowBinary")
  puts "PASS #{label}: independently encoded full and selected RowBinary"
  nil
end

def w106g_actual_marks(part : String, stream : String) : Array({UInt64, UInt64, UInt64})
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

def w106g_lz4_literal_frame_size(raw_size : Int32) : UInt64
  raise "empty raw chunk has no writer frame" if raw_size <= 0
  extensions = raw_size < 15 ? 0 : ((raw_size - 15) // 255) + 1
  (25 + 1 + raw_size + extensions).to_u64
end

def w106g_expected_stock_marks(fragments : Array(String)) : Array({UInt64, UInt64, UInt64})
  W106G_BOUNDARIES.each_with_index.map do |boundary, index|
    raw_offset = fragments[0, boundary].sum(&.bytesize).to_u64
    {0_u64, raw_offset, W106G_MARK_ROWS[index]}
  end.to_a
end

def w106g_expected_writer_marks(fragments : Array(String)) : Array({UInt64, UInt64, UInt64})
  marks = [] of {UInt64, UInt64, UInt64}
  compressed_offset = 0_u64
  (W106G_MARK_ROWS.size - 1).times do |mark|
    first = W106G_BOUNDARIES[mark]
    after = W106G_BOUNDARIES[mark + 1]
    row_count = after - first
    raw_chunk = fragments[first, row_count].join
    marks << {compressed_offset, 0_u64, row_count.to_u64}
    compressed_offset += w106g_lz4_literal_frame_size(raw_chunk.bytesize) unless raw_chunk.empty?
  end
  marks << {compressed_offset, 0_u64, 0_u64}
  marks
end

def w106g_expected_node_tree(fields : Array(W106GreenField)) : W106GreenNode
  leaves = fields.to_h { |field| {field.name, W106GreenNode.new(field.name.split('.').last, field.name)} }
  W106GreenNode.new("payload", "", [
    leaves["id"],
    W106GreenNode.new("left", "left", [
      W106GreenNode.new("details", "left.details", [
        leaves["left.details.state"], leaves["left.details.flag"], leaves["left.details.note"],
        leaves["left.details.event"], leaves["left.details.amount"],
      ]),
      leaves["left.fixed"], leaves["left.count"],
    ]),
    W106GreenNode.new("right", "right", [
      W106GreenNode.new("details", "right.details", [
        leaves["right.details.state"], leaves["right.details.note"], leaves["right.details.event"],
      ]),
      leaves["right.fixed"], leaves["right.count"],
    ]),
  ])
end

def w106g_field_index(fields : Array(W106GreenField), path : String) : Int32
  fields.index { |field| field.name == path } || raise "missing independent fixture path #{path}"
end

def w106g_node_default_at?(node : W106GreenNode, fields : Array(W106GreenField), row : Int32, writer_profile : Bool) : Bool
  return node.children.all? { |child| w106g_node_default_at?(child, fields, row, writer_profile) } if node.tuple?
  fields[w106g_field_index(fields, node.path)].default_at?(row, writer_profile)
end

def w106g_node_defaults(node : W106GreenNode, fields : Array(W106GreenField), writer_profile : Bool) : Int32
  W106G_KEYS.size.times.count { |row| w106g_node_default_at?(node, fields, row.to_i32, writer_profile) }.to_i32
end

def w106g_assert_json_keys(record : Hash(String, JSON::Any), keys : Array(String), label : String) : Nil
  actual = record.keys.sort
  wanted = keys.sort
  raise "#{label}: exact metadata keys differ; expected #{wanted.inspect}, got #{actual.inspect}" unless actual == wanted
end

def w106g_assert_stats_node(record : Hash(String, JSON::Any), node : W106GreenNode, fields : Array(W106GreenField), writer_profile : Bool, top : Bool = false) : Nil
  keys = if node.tuple?
           top ? ["kind", "name", "num_defaults", "num_rows", "subcolumns"] : ["kind", "num_defaults", "num_rows", "subcolumns"]
         else
           top ? ["kind", "name", "num_defaults", "num_rows"] : ["kind", "num_defaults", "num_rows"]
         end
  w106g_assert_json_keys(record, keys, "serializer #{node.path.empty? ? "payload" : node.path}")
  raise "serializer #{node.path}: kind differs" unless record["kind"]?.try(&.as_s) == "Default"
  raise "serializer #{node.path}: row count differs" unless record["num_rows"]?.try(&.as_i) == W106G_KEYS.size.to_i64
  expected_defaults = w106g_node_defaults(node, fields, writer_profile)
  raise "serializer #{node.path}: expected #{expected_defaults} defaults, got #{record["num_defaults"]?.try(&.as_i)}" unless record["num_defaults"]?.try(&.as_i) == expected_defaults.to_i64
  if top
    raise "serializer root name differs" unless record["name"]?.try(&.as_s) == "payload"
  end
  return unless node.tuple?
  children = record["subcolumns"]?.try(&.as_a) || raise "serializer #{node.path}: children missing"
  raise "serializer #{node.path}: child count differs" unless children.size == node.children.size
  node.children.each_with_index do |child, index|
    w106g_assert_stats_node(children[index].as_h, child, fields, writer_profile)
  end
end

def w106g_assert_serialization(part : String, fields : Array(W106GreenField), writer_profile : Bool, label : String) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  w106g_assert_json_keys(info, ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"], "#{label} serialization envelope")
  raise "#{label}: serializer version differs" unless info["version"]?.try(&.as_i) == 1
  raise "#{label}: nested type propagation differs" unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: serialization version map missing"
  raise "#{label}: exact type-version map differs" unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
  records = info["columns"]?.try(&.as_a) || raise "#{label}: serializer columns missing"
  names = records.map { |record| record.as_h["name"]?.try(&.as_s) || raise "#{label}: serializer root name missing" }
  raise "#{label}: root serializer order differs: #{names.inspect}" unless names == ["payload", "pk"]
  tree = w106g_expected_node_tree(fields)
  w106g_assert_stats_node(records[0].as_h, tree, fields, writer_profile, true)
  pk = records[1].as_h
  w106g_assert_json_keys(pk, ["kind", "name", "num_defaults", "num_rows"], "#{label} primary key")
  raise "#{label}: primary key serializer differs" unless pk["kind"]?.try(&.as_s) == "Default" && pk["name"]?.try(&.as_s) == "pk" && pk["num_rows"]?.try(&.as_i) == 5_i64 && pk["num_defaults"]?.try(&.as_i) == 0_i64
  puts "PASS #{label}: exact recursive metadata keys/topology/counters; both all-default rows retained"
  nil
end

def w106g_assert_layout(part : String, fields : Array(W106GreenField), writer_profile : Bool, label : String) : Nil
  actual_columns = File.read(File.join(part, "columns.txt"))
  raise "#{label}: exact columns.txt differs" unless actual_columns == w106g_expected_columns
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  expected_substreams = w106g_expected_substreams(fields)
  raise "#{label}: exact recursive substream order differs:\nexpected:\n#{expected_substreams}actual:\n#{actual_substreams}" unless actual_substreams == expected_substreams
  raise "#{label}: LZ4 codec differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  raise "#{label}: metadata version differs" unless File.read(File.join(part, "metadata_version.txt")) == "0"
  raise "#{label}: checksums.txt is missing" unless File.file?(File.join(part, "checksums.txt"))

  streams = w106g_streams(fields, writer_profile)
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
    raw = String.new(CrystalClick::CompressedBlock.decode_all(encoded))
    expected_raw = fragments.join
    w106g_assert_bytes(raw, expected_raw, "#{label} #{name} raw bytes")
    actual_marks = w106g_actual_marks(part, name)
    expected_marks = writer_profile ? w106g_expected_writer_marks(fragments) : w106g_expected_stock_marks(fragments)
    raise "#{label} #{name}: exact mark tuples differ; expected #{expected_marks.inspect}, got #{actual_marks.inspect}" unless actual_marks == expected_marks
    if name == "payload%2Eright%2Edetails%2Estate"
      w106g_seeded_comparator(raw, expected_raw, "#{label} repeated-terminal Enum leaf")
    end
  end
  w106g_assert_serialization(part, fields, writer_profile, label)
  puts "PASS #{label}: declaration, escaped paths, #{streams.size} raw streams, exact marks and recursive metadata"
  nil
end

def w106g_insert_into(binary : String, store : String, table : String, fields : Array(W106GreenField)) : Nil
  w106g_create_table(binary, store, table)
  w106g_insert(binary, store, table, fields)
  nil
end

def w106g_stock_seed(binary : String, store : String, table : String, fields : Array(W106GreenField)) : String
  w106g_insert_into(binary, store, table, fields)
  source_part = w106g_part_path(binary, store, table)
  w106g_schema(binary, store, table)
  w106g_assert_layout(source_part, fields, false, "W106 stock #{table}")
  w106g_check(binary, store, table, source_part)
  w106g_assert_rowbinary(binary, store, table, fields, "W106 stock #{table}")
  source_part
end

def w106g_attach_and_certify(binary : String, store : String, table : String, source_part : String, fields : Array(W106GreenField), writer_profile : Bool, label : String) : String
  attached_part = w106g_attach(binary, store, table, source_part)
  w106g_schema(binary, store, table)
  w106g_assert_layout(attached_part, fields, writer_profile, "#{label} ATTACH")
  w106g_check(binary, store, table, attached_part)
  w106g_assert_rowbinary(binary, store, table, fields, "#{label} ATTACH", writer_profile)
  attached_part
end

def w106g_expected_node_type(node : W106GreenNode, fields : Array(W106GreenField)) : String
  if node.tuple?
    "Tuple(#{node.children.map { |child| "#{child.name} #{w106g_expected_node_type(child, fields)}" }.join(", ")})"
  else
    fields[w106g_field_index(fields, node.path)].type_name
  end
end

def w106g_assert_schema_tree(actual_nodes : Array(CrystalClick::WideTupleSchemaNode), expected_nodes : Array(W106GreenNode), fields : Array(W106GreenField), label : String) : Nil
  raise "#{label}: schema tree width differs" unless actual_nodes.size == expected_nodes.size
  actual_nodes.each_with_index do |actual, index|
    expected = expected_nodes[index]
    raise "#{label}: local node name differs at #{expected.path}" unless actual.name == expected.name
    raise "#{label}: exact subtree declaration differs at #{expected.path}" unless actual.type_name == w106g_expected_node_type(expected, fields)
    if expected.tuple?
      raise "#{label}: tuple node unexpectedly exposes a terminal leaf" unless actual.leaf_field?.nil?
      w106g_assert_schema_tree(actual.children, expected.children, fields, label)
    else
      leaf = actual.leaf_field? || raise "#{label}: terminal schema node lost its leaf descriptor"
      field = fields[w106g_field_index(fields, expected.path)]
      raise "#{label}: local terminal type differs at #{expected.path}" unless leaf.type_name == field.type_name
    end
  end
  nil
end

def w106g_physical_bytes(column : CrystalClick::WideTupleLeafColumn, field : W106GreenField, row : Int32) : String
  values = column.physical_values
  case field.base_type
  when "String"
    values.as(Array(String))[row]
  when "UInt64"
    w106g_unsigned_le(values.as(Array(UInt64))[row], 8)
  when "UInt32"
    w106g_unsigned_le(values.as(Array(UInt32))[row].to_u64, 4)
  when "Bool"
    w106g_byte(values.as(Array(UInt8))[row])
  when "Enum8('neg' = -7, 'pos' = 7)"
    w106g_signed_le(values.as(Array(Int8))[row].to_i64, 1)
  when "Decimal(9, 2)"
    w106g_signed_le(values.as(Array(Int32))[row].to_i64, 4)
  when "DateTime64(3, 'America/New_York')", "DateTime64(9, 'UTC')"
    w106g_signed_le(values.as(Array(CrystalClick::DateTime64Value))[row].raw, 8)
  when "FixedString(3)"
    String.new(values.as(Array(CrystalClick::FixedStringValue))[row].raw_bytes)
  else
    raise "#{field.name}: no physical decoder in independent W106 fixture"
  end
end

def w106g_read_unsigned_le(bytes : Bytes) : UInt64
  raise "independent W106 decoder supports at most eight bytes" if bytes.size > 8
  value = 0_u64
  bytes.each_with_index do |byte, index|
    value |= byte.to_u64 << (index * 8)
  end
  value
end

def w106g_assert_logical(column : CrystalClick::WideTupleLeafColumn, field : W106GreenField, row : Int32, fragment : String, label : String) : Nil
  value = column.value_at(row)
  if field.nullable && field.values[row].nil?
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
    wanted = w106g_read_unsigned_le(fragment.to_slice[0, 4]).to_u32.unsafe_as(Int32)
    raise "#{label}: Decimal coefficient differs" unless decimal.raw == wanted
    raise "#{label}: Decimal precision/scale differs" unless decimal.precision == 9 && decimal.scale == 2
  when "DateTime64(3, 'America/New_York')", "DateTime64(9, 'UTC')"
    temporal = value.as(CrystalClick::DateTime64Value)
    wanted = w106g_read_unsigned_le(fragment.to_slice[0, 8]).unsafe_as(Int64)
    precision = field.base_type == "DateTime64(3, 'America/New_York')" ? 3_u8 : 9_u8
    raise "#{label}: raw DateTime64 ticks/precision differ" unless temporal.raw == wanted && temporal.precision == precision
  when "UInt64"
    wanted = w106g_read_unsigned_le(fragment.to_slice[0, 8])
    raise "#{label}: UInt64 semantic value differs" unless value.as(UInt64) == wanted
  when "UInt32"
    wanted = w106g_read_unsigned_le(fragment.to_slice[0, 4]).to_u32
    raise "#{label}: UInt32 semantic value differs" unless value.as(UInt32) == wanted
  when "FixedString(3)"
    raise "#{label}: FixedString raw bytes differ" unless value.as(CrystalClick::FixedStringValue).raw_bytes == fragment.to_slice
  else
    raise "#{label}: missing logical assertion for #{field.base_type}"
  end
  nil
end

def w106g_assert_datetime_identity(column : CrystalClick::WideTupleLeafColumn, field : W106GreenField, label : String) : Nil
  return unless field.base_type.starts_with?("DateTime64")
  descriptor = column.datetime_type || raise "#{label}: #{field.name} lost DateTime64 descriptor"
  expected_zone = field.base_type.includes?("America/New_York") ? "America/New_York" : "UTC"
  expected_precision = expected_zone == "UTC" ? 9_u8 : 3_u8
  raise "#{label}: exact timezone or scale differs for #{field.name}" unless descriptor.time_zone?.try(&.name) == expected_zone && descriptor.precision? == expected_precision
end

def w106g_assert_typed(part : String, fields : Array(W106GreenField), label : String, writer_profile : Bool) : CrystalClick::WideTupleColumnData
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "#{label}: exact column type differs" unless reader.column_type == W106G_TYPE
  raise "#{label}: mark row schedule differs" unless reader.mark_row_counts == W106G_MARK_ROWS[0, 3]
  data = reader.read_tuple_mark_range("payload", 0, reader.mark_count)
  raise "#{label}: row or field count differs" unless data.row_count == W106G_KEYS.size && data.fields.size == fields.size
  raise "#{label}: exact top-level nested schema differs" unless data.type_name == W106G_TYPE
  expected_fields = fields.map { |field| {field.name, field.type_name} }
  raise "#{label}: flattened declaration order/path differs" unless data.fields.map { |field| {field.name, field.type_name} } == expected_fields
  tree = w106g_expected_node_tree(fields)
  w106g_assert_schema_tree(data.root_fields, tree.children, fields, label)

  data.columns.each_with_index do |column, index|
    field = fields[index]
    raise "#{label}: leaf exact path/type differs for #{field.name}" unless column.name == field.name && column.type_name == field.type_name
    w106g_assert_datetime_identity(column, field, label)
    if field.nullable
      raise "#{label}: null map differs for #{field.name}" unless column.null_map.try(&.bytes) == field.null_rows
    else
      raise "#{label}: bare field acquired null-map metadata" unless column.null_map.nil?
    end
    fragments = field.stream_rows(writer_profile)
    W106G_KEYS.size.times do |row|
      physical = w106g_physical_bytes(column, field, row.to_i32)
      w106g_assert_bytes(physical, fragments[row], "#{label} #{field.name} row #{row} physical carrier")
      w106g_assert_logical(column, field, row.to_i32, fragments[row], label)
    end
    copy = column.owned_copy
    raise "#{label}: owned copy lost exact leaf type/path" unless copy.name == field.name && copy.type_name == field.type_name
    W106G_KEYS.size.times do |row|
      w106g_assert_bytes(w106g_physical_bytes(copy, field, row.to_i32), fragments[row], "#{label} #{field.name} copied row #{row}")
    end
    if field.nullable
      raise "#{label}: owned copy lost null mask" unless copy.null_map.try(&.bytes) == field.null_rows
    end
  end

  5.times do |row|
    root_row = data.row(row)
    raise "#{label}: top-level id lookup differs" unless root_row["id"].as(UInt64) == (row == 1 ? 100_u64 : row == 3 ? UInt64::MAX : row == 2 ? 2_u64 : 0_u64)
    left = root_row.tuple("left")
    right = root_row.tuple("right")
    raise "#{label}: left scoped type differs" unless left.type_name == "Tuple(details Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), flag Nullable(Bool), note Nullable(String), event DateTime64(3, 'America/New_York'), amount Nullable(Decimal(9, 2))), fixed FixedString(3), count UInt32)"
    raise "#{label}: right scoped type differs" unless right.type_name == "Tuple(details Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), note Nullable(String), event DateTime64(9, 'UTC')), fixed FixedString(3), count UInt64)"
    left_details = root_row.tuple("left.details")
    right_details = root_row.tuple("right.details")
    raise "#{label}: repeated terminal labels collided across branches" unless left_details.fields.map(&.name) == ["state", "flag", "note", "event", "amount"] && right_details.fields.map(&.name) == ["state", "note", "event"]
    if row == 2
      raise "#{label}: left scoped Enum label differs" unless left_details.value_as("state", CrystalClick::Enum8Value).label == "pos"
      raise "#{label}: right scoped Enum label differs" unless right_details.value_as("state", CrystalClick::Enum8Value).label == "neg"
    end
  end

  selected = reader.read_tuple_mark_range("payload", 1, 1)
  raise "#{label}: selected-mark rows differ" unless selected.row_count == 2
  selected.columns.each_with_index do |column, index|
    field = fields[index]
    [2, 3].each_with_index do |source_row, selected_row|
      w106g_assert_bytes(w106g_physical_bytes(column, field, selected_row.to_i32), field.stream_rows(writer_profile)[source_row], "#{label} selected #{field.name} row #{source_row}")
    end
  end
  empty_range_rejected = false
  begin
    reader.read_tuple_mark_range("payload", reader.mark_count, 0)
  rescue ex : CrystalClick::BoundsError
    empty_range_rejected = ex.message == "empty mark range"
  end
  raise "#{label}: zero-mark range did not follow the public rejection contract" unless empty_range_rejected

  mark_indices = [] of Int32
  lazy_rows = [] of CrystalClick::WideTupleRow
  reader.each_tuple_mark_range("payload", 0, reader.mark_count) do |mark_data, mark_index|
    mark_indices << mark_index
    mark_data.row_count.times { |index| lazy_rows << mark_data.row(index) }
  end
  raise "#{label}: lazy mark indices/row total differ" unless mark_indices == [0_i32, 1_i32, 2_i32] && lazy_rows.size == W106G_KEYS.size
  puts "PASS #{label}: #{fields.size} exact nested leaves, all raw carriers/NULL masks, scopes, copies, selected/lazy reads; zero-mark range rejected"
  data
end

def w106g_assert_consumers(part : String, fields : Array(W106GreenField), label : String) : Nil
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
  raise "#{label}: table exact payload declaration differs" unless table.column_types.any? { |name, type| name == "payload" && type == W106G_TYPE }
  table_rows = [] of CrystalClick::WideTupleRow
  table.scan_typed(batch_rows: 3) do |batch|
    batch.values_for("pk").each_with_index do |key, offset|
      index = (key / 10_u64 - 1_u64).to_i32
      row = batch.tuple_rows_for("payload")[offset]
      raise "#{label}: table row full type differs" unless row.type_name == W106G_TYPE
      raise "#{label}: table scoped repeated-name lookup differs" unless row.tuple("left.details").fields.map(&.name) == ["state", "flag", "note", "event", "amount"]
      table_rows << row
      raise "#{label}: table PK-to-fixture alignment differs" unless key == W106G_KEYS[index]
    end
  end
  raise "#{label}: table full scan row count differs" unless table_rows.size == W106G_KEYS.size

  table_window = [] of CrystalClick::WideTupleRow
  table.scan_typed_window(1_u64, 3) do |batch|
    batch.tuple_rows_for("payload").each { |row| table_window << row }
  end
  raise "#{label}: table window rows lost nested identity" unless table_window.size == 3 && table_window.all? { |row| row.tuple("right.details").type_name == "Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), note Nullable(String), event DateTime64(9, 'UTC'))" }

  catalog_root = ENV["W106G_CATALOG_ROOT"]? || raise "set W106G_CATALOG_ROOT to an isolated temporary catalog directory"
  w106g_catalog_root(catalog_root, part)
  offline = CrystalClick::OfflineCatalog.open(catalog_root)["lab"]["events"]
  values = offline["payload"].values(max_tuple_cells: 100_u64)
  raise "#{label}: catalog values row count differs" unless values.size == W106G_KEYS.size
  values.each_with_index do |value, index|
    row = value.as(CrystalClick::WideTupleRow)
    raise "#{label}: catalog materialized nested type differs" unless row.type_name == W106G_TYPE
    raise "#{label}: catalog materialized path scope differs" unless row.tuple("right.details").fields.map(&.name) == ["state", "note", "event"]
    if index == 2
      raise "#{label}: catalog value materialization lost enum label" unless row.tuple("left.details").value_as("state", CrystalClick::Enum8Value).label == "pos"
    end
  end
  catalog_scan = [] of CrystalClick::WideTupleRow
  offline.scan_typed(["pk", "payload"], batch_rows: 3) do |batch|
    batch.tuple_rows_for("payload").each { |row| catalog_scan << row }
  end
  raise "#{label}: catalog scan row count differs" unless catalog_scan.size == W106G_KEYS.size
  catalog_window = [] of CrystalClick::WideTupleRow
  offline.scan_typed_window(["pk", "payload"], 1_u64, 3) do |batch|
    batch.tuple_rows_for("payload").each { |row| catalog_window << row }
  end
  raise "#{label}: catalog window nested lookup differs" unless catalog_window.size == 3 && catalog_window[0].tuple("left.details").value_as("event", CrystalClick::DateTime64Value).precision == 3_u8
  puts "PASS #{label}: table full/window and OfflineCatalog values/full/window retain nested paths and scopes"
  nil
end

def w106g_catalog_root(root : String, part : String) : String
  raise "refusing existing W106 catalog path: #{root}" if Dir.exists?(root)
  metadata = File.join(root, "metadata")
  database_uuid = "10600000-0000-4000-8000-000000000001"
  table_uuid = "10600000-0000-4000-8000-000000000002"
  database = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(File.join(database, "events.sql"), "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{W106G_TYPE}\n)\nENGINE = MergeTree\nORDER BY pk\n")
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  FileUtils.cp_r(part, File.join(table, "all_1_1_0"))
  root
end

def w106g_writer_columns(source : Array(CrystalClick::WideTupleLeafColumn)) : Array(CrystalClick::WideTupleLeafColumn)
  source.map do |column|
    case column.name
    when "left.details.state", "right.details.state"
      raw = column.physical_values.as(Array(Int8))
      raw[0] = Int8::MAX
      raw[3] = Int8::MIN
      raw[4] = Int8::MIN
      CrystalClick::WideTupleLeafColumn.new(column.name, column.leaf_type, raw, column.null_map)
    when "left.details.flag"
      raw = column.physical_values.as(Array(UInt8))
      raw[0] = 0xfe_u8
      raw[3] = 2_u8
      raw[4] = 0xff_u8
      CrystalClick::WideTupleLeafColumn.new(column.name, column.leaf_type, raw, column.null_map)
    when "left.details.note", "right.details.note"
      raw = column.physical_values.as(Array(String))
      raw[0] = "hidden-null-left"
      raw[4] = "hidden-null-right"
      CrystalClick::WideTupleLeafColumn.new(column.name, column.leaf_type, raw, column.null_map)
    when "left.details.amount"
      raw = column.physical_values.as(Array(Int32))
      raw[0] = Int32::MIN
      raw[4] = Int32::MAX
      CrystalClick::WideTupleLeafColumn.new(column.name, column.leaf_type, raw, column.null_map)
    else
      column.owned_copy
    end
  end
end

def w106g_run_reader(binary : String, store : String, fields : Array(W106GreenField)) : Nil
  source = w106g_stock_seed(binary, store, "w106g_reader_source", fields)
  attached = w106g_attach_and_certify(binary, store, "w106g_reader_attached", source, fields, false, "W106 reader stock")
  w106g_assert_typed(attached, fields, "W106 stock typed reader", false)
  w106g_assert_consumers(attached, fields, "W106 stock consumers")
  puts "PASS W106 --green-reader: nested representative profile; W105 separately certifies all 53 flat Nullable declarations"
  nil
end

def w106g_run_writer(binary : String, store : String, fields : Array(W106GreenField)) : Nil
  source = w106g_stock_seed(binary, store, "w106g_writer_seed", fields)
  attached_seed = w106g_attach_and_certify(binary, store, "w106g_writer_seed_attached", source, fields, false, "W106 writer input stock")
  typed_seed = w106g_assert_typed(attached_seed, fields, "W106 writer input typed seed", false)
  writer_columns = w106g_writer_columns(typed_seed.columns)
  writer_parent = File.join(store, "w106g_writer_output")
  FileUtils.mkdir_p(writer_parent)
  writer_part = File.join(writer_parent, "all_1_1_0")
  actual = CrystalClick::WidePartWriter.write_uint64_tuple_pair(
    writer_part, "pk", W106G_KEYS.to_unsafe.to_slice(W106G_KEYS.size),
    "payload", W106G_TYPE, writer_columns, rows_per_mark: 2
  )
  raise "W106 writer returned another destination" unless actual == writer_part
  w106g_assert_layout(writer_part, fields, true, "W106 Crystal writer")
  attached = w106g_attach_and_certify(binary, store, "w106g_writer_attached", writer_part, fields, true, "W106 writer output")
  w106g_assert_typed(attached, fields, "W106 writer typed roundtrip", true)
  w106g_assert_consumers(attached, fields, "W106 writer consumers")
  puts "PASS W106 --green-writer: recursive writer frames, masked hidden bytes, stock ATTACH/CHECK/RowBinary and typed copy verified"
  nil
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["W106G_STORE"]? || raise "set W106G_STORE to an empty temporary ClickHouse store"
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary W106G_STORE path: #{store}"
end
if Dir.exists?(store)
  raise "W106G_STORE must be empty: #{store}" unless Dir.empty?(store)
else
  Dir.mkdir_p(store)
end
mode = ARGV.shift? || raise "usage: --green-reader | --green-writer"
raise "unknown W106 GREEN mode: #{mode}" unless {"--green-reader", "--green-writer"}.includes?(mode)
version_output = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version_output)
raise "could not read stock ClickHouse version" unless version_status.success?
expected_version = "ClickHouse local version #{W106G_STOCK_VERSION} (official build)."
raise "W106 GREEN requires #{expected_version}, got #{version_output.to_s.strip}" unless version_output.to_s.strip == expected_version
puts "Stock oracle: #{version_output.to_s.strip}"
fields = w106g_fields
raise "W106 fixture leaf count differs" unless fields.size == 13
raise "W106 fixture type differs from explicit independent declaration" unless W106G_TYPE == "Tuple(id UInt64, left Tuple(details Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), flag Nullable(Bool), note Nullable(String), event DateTime64(3, 'America/New_York'), amount Nullable(Decimal(9, 2))), fixed FixedString(3), count UInt32), right Tuple(details Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), note Nullable(String), event DateTime64(9, 'UTC')), fixed FixedString(3), count UInt64))"
if mode == "--green-reader"
  w106g_run_reader(binary, store, fields)
else
  w106g_run_writer(binary, store, fields)
end
