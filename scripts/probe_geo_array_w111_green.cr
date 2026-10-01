# W111 paired Geo Array GREEN oracle. Fixture bytes, logical topology, marks,
# and RowBinary expectations are built from literal nested-array trees below;
# neither the Crystal reader nor writer supplies its own expected output.
require "json"
require "file_utils"
require "../src/crystal_click"

W111G_VERSION    = "26.7.1.1315"
W111G_SETTINGS   = "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"
W111G_KEYS       = [0_u64, 0_u64, 2_u64, 3_u64, 4_u64, 4_u64, 5_u64, 7_u64, 9_u64]
W111G_BOUNDARIES = [0, 2, 4, 6, 8, 9]
W111G_MARK_ROWS  = [2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
W111G_MARK_BYTES = 24
W111G_TYPES      = [
  {"LineString", 1},
  {"Ring", 1},
  {"Polygon", 2},
  {"MultiLineString", 2},
  {"MultiPolygon", 3},
]

struct W111GPoint
  getter x_bits : UInt64
  getter y_bits : UInt64

  def initialize(@x_bits : UInt64, @y_bits : UInt64)
  end
end

class W111GNode
  getter children : Array(W111GNode)
  getter points : Array(W111GPoint)

  def initialize(@children : Array(W111GNode), @points : Array(W111GPoint))
  end
end

struct W111GProfile
  getter type_name : String
  getter depth : Int32
  getter shape : String
  getter ratio : String

  def initialize(@type_name : String, @depth : Int32, @shape : String, @ratio : String)
  end

  def rows : Int32
    W111G_KEYS.size.to_i32
  end

  def data_mark_count : Int32
    W111G_MARK_ROWS.size.to_i32 - 1
  end

  def label : String
    "#{type_name}/#{shape}/ratio=#{ratio}"
  end

  def safe_suffix : String
    "#{type_name.downcase}_#{shape}_#{ratio == "1.0" ? "r1" : "r09375"}"
  end
end

struct W111GStream
  getter name : String
  getter row_fragments : Array(Array(String))

  def initialize(@name : String, @row_fragments : Array(Array(String)))
  end

  def fragments : Array(String)
    result = [] of String
    @row_fragments.each { |row| result.concat(row) }
    result
  end

  def raw : String
    fragments.join
  end
end

class W111GOracleError < Exception
end

W111G_POINTS = [
  W111GPoint.new(0x8000_0000_0000_0000_u64, 0x0000_0000_0000_0000_u64), # -0,+0
  W111GPoint.new(0x7ff8_0000_0000_1234_u64, 0x400c_0000_0000_0000_u64), # NaN payload,3.5
  W111GPoint.new(0xfff0_0000_0000_0000_u64, 0x0000_0000_0000_0001_u64), # -Inf,min subnormal
  W111GPoint.new(0x4002_0000_0000_0000_u64, 0x7ff8_0000_0000_5678_u64), # 2.25,distinct NaN
]

def w111g_fail(message : String) : NoReturn
  raise W111GOracleError.new(message)
end

def w111g_require(condition : Bool, message : String) : Nil
  w111g_fail(message) unless condition
end

def w111g_u64(value : UInt64) : String
  String.build do |io|
    8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
  end
end

def w111g_varuint(value : UInt64) : String
  String.build do |io|
    current = value
    while current >= 0x80_u64
      io.write_byte(((current & 0x7f_u64) | 0x80_u64).to_u8)
      current >>= 7
    end
    io.write_byte(current.to_u8)
  end
end

def w111g_empty_node : W111GNode
  W111GNode.new([] of W111GNode, [] of W111GPoint)
end

def w111g_leaf(points : Array(W111GPoint)) : W111GNode
  W111GNode.new([] of W111GNode, points)
end

def w111g_branch(children : Array(W111GNode)) : W111GNode
  W111GNode.new(children, [] of W111GPoint)
end

def w111g_fixture(profile : W111GProfile) : Array(W111GNode)
  rows = Array(W111GNode).new(W111G_KEYS.size) { w111g_empty_node }
  if profile.shape == "empty"
    return rows
  end

  case profile.depth
  when 1
    rows[0] = w111g_leaf([W111G_POINTS[0]])
    rows[1] = w111g_leaf([W111G_POINTS[0]])
    rows[2] = w111g_leaf([W111G_POINTS[0], W111G_POINTS[1]])
    rows[6] = w111g_leaf([W111G_POINTS[2]])
    rows[7] = w111g_leaf([W111G_POINTS[3]])
    rows[8] = w111g_leaf([W111G_POINTS[1]])
  when 2
    rows[0] = w111g_branch([w111g_leaf([W111G_POINTS[0]])])
    rows[1] = w111g_branch([w111g_leaf([W111G_POINTS[0]])])
    rows[2] = w111g_branch([w111g_leaf([] of W111GPoint), w111g_leaf([W111G_POINTS[0], W111G_POINTS[1]])])
    rows[6] = w111g_branch([w111g_leaf([W111G_POINTS[2]])])
    rows[7] = w111g_branch([w111g_leaf([] of W111GPoint), w111g_leaf([W111G_POINTS[3]])])
    rows[8] = w111g_branch([w111g_leaf([W111G_POINTS[1]])])
  when 3
    rows[0] = w111g_branch([w111g_branch([w111g_leaf([W111G_POINTS[0]])])])
    rows[1] = w111g_branch([w111g_branch([w111g_leaf([W111G_POINTS[0]])])])
    rows[2] = w111g_branch([
      w111g_branch([] of W111GNode),
      w111g_branch([w111g_leaf([] of W111GPoint), w111g_leaf([W111G_POINTS[0], W111G_POINTS[1]]), w111g_leaf([] of W111GPoint)]),
    ])
    rows[6] = w111g_branch([w111g_branch([w111g_leaf([W111G_POINTS[2]])])])
    rows[7] = w111g_branch([
      w111g_branch([] of W111GNode),
      w111g_branch([w111g_leaf([] of W111GPoint), w111g_leaf([W111G_POINTS[3]])]),
    ])
    rows[8] = w111g_branch([w111g_branch([w111g_leaf([W111G_POINTS[1]])])])
    w111g_require(rows[2].children.size == 2 && rows[2].children.sum(&.children.size) == 3, "MultiPolygon fixture must distinguish polygon and ring counts")
  else
    w111g_fail("unsupported Geo Array depth #{profile.depth}")
  end

  w111g_require(w111g_signature(rows[0], profile.depth, 0) == w111g_signature(rows[1], profile.depth, 0), "duplicate-key prelude rows must be byte-identical")
  w111g_require(w111g_point_count(rows[0], profile.depth, 0) > 0, "selected key range must have a nonzero flattened origin")
  w111g_require(w111g_point_count(rows[8], profile.depth, 0) > 0, "key-9 suffix must be nonempty")
  rows.each_with_index { |row, index| w111g_validate_node(row, profile.depth, 0, "#{profile.type_name} row #{index}") }
  rows
end

def w111g_signature(node : W111GNode, depth : Int32, level : Int32) : String
  String.build do |io|
    if level == depth - 1
      io << "P#{node.points.size}["
      node.points.each { |point| io << point.x_bits.to_s(16) << "/" << point.y_bits.to_s(16) << ";" }
      io << "]"
    else
      io << "A#{node.children.size}["
      node.children.each { |child| io << w111g_signature(child, depth, level + 1) << ";" }
      io << "]"
    end
  end
end

def w111g_point_count(node : W111GNode, depth : Int32, level : Int32) : Int32
  if level == depth - 1
    node.points.size
  else
    node.children.sum { |child| w111g_point_count(child, depth, level + 1) }
  end
end

def w111g_validate_node(node : W111GNode, depth : Int32, level : Int32, label : String) : Nil
  if level == depth - 1
    w111g_require(node.children.empty?, "#{label}: terminal array contains child arrays")
  else
    w111g_require(node.points.empty?, "#{label}: nonterminal array contains Points")
    node.children.each { |child| w111g_validate_node(child, depth, level + 1, label) }
  end
end

def w111g_collect(
  node : W111GNode,
  depth : Int32,
  level : Int32,
  sizes : Array(Array(String)),
  x_fragments : Array(String),
  y_fragments : Array(String),
  points : Array(W111GPoint),
) : Nil
  if level == depth - 1
    sizes[level] << w111g_u64(node.points.size.to_u64)
    node.points.each do |point|
      x_fragments << w111g_u64(point.x_bits)
      y_fragments << w111g_u64(point.y_bits)
      points << point
    end
  else
    sizes[level] << w111g_u64(node.children.size.to_u64)
    node.children.each { |child| w111g_collect(child, depth, level + 1, sizes, x_fragments, y_fragments, points) }
  end
  nil
end

def w111g_streams(profile : W111GProfile, rows : Array(W111GNode)) : Array(W111GStream)
  level_fragments = Array(Array(Array(String))).new(profile.depth) { [] of Array(String) }
  x_rows = [] of Array(String)
  y_rows = [] of Array(String)
  rows.each do |root|
    sizes = Array(Array(String)).new(profile.depth) { [] of String }
    xs = [] of String
    ys = [] of String
    points = [] of W111GPoint
    w111g_collect(root, profile.depth, 0, sizes, xs, ys, points)
    profile.depth.times { |level| level_fragments[level] << sizes[level] }
    x_rows << xs
    y_rows << ys
  end
  result = [W111GStream.new("pk", W111G_KEYS.map { |key| [w111g_u64(key)] })]
  profile.depth.times { |level| result << W111GStream.new("payload.size#{level}", level_fragments[level]) }
  result << W111GStream.new("payload%2E1", x_rows)
  result << W111GStream.new("payload%2E2", y_rows)
  result
end

def w111g_points(profile : W111GProfile, rows : Array(W111GNode)) : Array(W111GPoint)
  result = [] of W111GPoint
  rows.each do |row|
    sizes = Array(Array(String)).new(profile.depth) { [] of String }
    w111g_collect(row, profile.depth, 0, sizes, [] of String, [] of String, result)
  end
  result
end

def w111g_level_sizes(profile : W111GProfile, rows : Array(W111GNode)) : Array(Array(UInt64))
  streams = w111g_streams(profile, rows)
  Array(Array(UInt64)).new(profile.depth) do |level|
    stream = streams[level + 1]
    stream.fragments.map { |fragment| w111g_u64_from_le(fragment) }
  end
end

def w111g_u64_from_le(bytes : String) : UInt64
  w111g_require(bytes.bytesize == 8, "expected an independent UInt64 size fragment")
  8.times.reduce(0_u64) { |value, index| value | (bytes.to_slice[index].to_u64 << (index * 8)) }
end

def w111g_write_rowbinary_array(io : IO, node : W111GNode, depth : Int32, level : Int32) : Nil
  if level == depth - 1
    io << w111g_varuint(node.points.size.to_u64)
    node.points.each do |point|
      io << w111g_u64(point.x_bits)
      io << w111g_u64(point.y_bits)
    end
  else
    io << w111g_varuint(node.children.size.to_u64)
    node.children.each { |child| w111g_write_rowbinary_array(io, child, depth, level + 1) }
  end
end

def w111g_rowbinary(profile : W111GProfile, rows : Array(W111GNode), indexes : Array(Int32)) : String
  String.build do |io|
    indexes.each do |index|
      io << w111g_u64(W111G_KEYS[index])
      w111g_write_rowbinary_array(io, rows[index], profile.depth, 0)
    end
  end
end

def w111g_selected_indexes : Array(Int32)
  W111G_KEYS.each_with_index.select { |key, _index| key >= 2_u64 && key < 8_u64 }.map { |_key, index| index.to_i32 }.to_a
end

def w111g_expected_substreams(streams : Array(W111GStream)) : String
  payload = streams.reject { |stream| stream.name == "pk" }
  lines = ["columns substreams version: 1", "2 columns:", "1 substreams for column `pk`:", "\tpk", "#{payload.size} substreams for column `payload`:"]
  payload.each { |stream| lines << "\t#{stream.name}" }
  lines.join("\n") + "\n"
end

def w111g_stock_marks(stream : W111GStream) : Array({UInt64, UInt64, UInt64})
  W111G_BOUNDARIES.map_with_index do |boundary, mark_index|
    offset = 0_u64
    boundary.times { |row| stream.row_fragments[row].each { |fragment| offset += fragment.bytesize.to_u64 } }
    {0_u64, offset, W111G_MARK_ROWS[mark_index]}
  end.to_a
end

def w111g_frame_size(raw_size : Int32) : UInt64
  w111g_require(raw_size > 0, "empty chunks do not get a writer frame")
  extension_bytes = raw_size < 15 ? 0 : ((raw_size - 15) // 255) + 1
  # Literal-only ClickHouse compressed frame: 16 checksum + 9 LZ4 header +
  # token, raw bytes, and independently computed literal-length extensions.
  (26 + raw_size + extension_bytes).to_u64
end

def w111g_writer_marks(stream : W111GStream) : Array({UInt64, UInt64, UInt64})
  result = [] of {UInt64, UInt64, UInt64}
  compressed_offset = 0_u64
  (W111G_BOUNDARIES.size - 1).times do |mark|
    first = W111G_BOUNDARIES[mark]
    after = W111G_BOUNDARIES[mark + 1]
    fragments = stream.row_fragments[first, after - first].flatten
    result << {compressed_offset, 0_u64, W111G_MARK_ROWS[mark]}
    raw_size = fragments.sum(&.bytesize)
    compressed_offset += w111g_frame_size(raw_size) unless raw_size == 0
  end
  result << {compressed_offset, 0_u64, 0_u64}
  result
end

def w111g_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  index = 0
  while index < limit && actual.to_slice[index] == expected.to_slice[index]
    index += 1
  end
  got = index < actual.bytesize ? actual.to_slice[index].to_s(16).rjust(2, '0') : "<eof>"
  wanted = index < expected.bytesize ? expected.to_slice[index].to_s(16).rjust(2, '0') : "<eof>"
  raise W111GOracleError.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first diff #{index}: expected #{wanted}, got #{got}")
end

def w111g_seed_byte(actual : String, expected : String, label : String) : Nil
  w111g_assert_bytes(actual, expected, label)
  w111g_require(!expected.empty?, "#{label}: cannot seed a byte mutation from empty bytes")
  damaged = String.new(expected.to_slice)
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 0x01_u8
  rejected = false
  begin
    w111g_assert_bytes(actual, damaged, label)
  rescue ex : W111GOracleError
    rejected = true
  end
  w111g_require(rejected, "#{label}: wrong-byte control was accepted")
end

def w111g_raw(part : String, name : String) : String
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(name)}.bin")).to_slice
  return "" if encoded.empty?
  String.new(CrystalClick::CompressedBlock.decode_all(encoded))
end

def w111g_actual_marks(part : String, name : String) : Array({UInt64, UInt64, UInt64})
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(name)}.mrk2")).to_slice
  w111g_require(bytes.size % W111G_MARK_BYTES == 0, "#{name}: partial literal 24-byte mark record")
  Array({UInt64, UInt64, UInt64}).new(bytes.size // W111G_MARK_BYTES) do |mark|
    offset = mark * W111G_MARK_BYTES
    fields = Array(UInt64).new(3) do |field|
      first = offset + field * 8
      8.times.reduce(0_u64) { |value, byte| value | (bytes[first + byte].to_u64 << (byte * 8)) }
    end
    {fields[0], fields[1], fields[2]}
  end
end

def w111g_validate_pk_defaults(record : Hash(String, JSON::Any), expected : Int64, label : String) : Nil
  actual = record["num_defaults"]?.try(&.as_i) || raise "#{label}: PK default counter missing"
  w111g_require(actual == expected, "#{label}: expected PK default count #{expected}, got #{actual}")
end

def w111g_assert_metadata(part : String, profile : W111GProfile, label : String, writer_profile : Bool = false) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  expected_envelope = ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"].sort
  w111g_require(info.keys.sort == expected_envelope, "#{label}: exact serialization envelope differs")
  w111g_require(info["version"]?.try(&.as_i) == 1_i64, "#{label}: metadata version differs")
  w111g_require(info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true, "#{label}: nested version propagation differs")
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: type-version map missing"
  w111g_require(versions.size == 1 && versions["string"]?.try(&.as_i) == 1_i64, "#{label}: exact String serializer version map differs")
  records = info["columns"]?.try(&.as_a) || raise "#{label}: columns records missing"
  no_statistics = profile.ratio == "1.0" && !writer_profile
  if no_statistics
    w111g_require(records.empty?, "#{label}: ratio=1.0 must produce exact columns=[]")
    return
  end
  w111g_require(records.size == 1, "#{label}: only the external PK record is qualified for this Array profile")
  record = records.first.as_h
  w111g_require(record.keys.sort == ["kind", "name", "num_defaults", "num_rows"].sort, "#{label}: exact PK statistics keys differ")
  w111g_require(record["kind"]?.try(&.as_s) == "Default" && record["name"]?.try(&.as_s) == "pk", "#{label}: exact PK Default record identity differs")
  defaults = W111G_KEYS.count { |key| key == 0_u64 }.to_i64
  w111g_require(record["num_rows"]?.try(&.as_i) == W111G_KEYS.size.to_i64, "#{label}: PK row count differs")
  w111g_validate_pk_defaults(record, defaults, label)
  mutated = record.dup
  mutated["num_defaults"] = JSON::Any.new((defaults + 1).to_i64)
  rejected = false
  begin
    w111g_validate_pk_defaults(mutated, defaults, "#{label} seeded counter")
  rescue ex : W111GOracleError
    rejected = true
  end
  w111g_require(rejected, "#{label}: metadata comparator accepted seeded PK counter drift")
end

def w111g_assert_layout(part : String, profile : W111GProfile, rows : Array(W111GNode), label : String, writer_profile : Bool = false) : Nil
  streams = w111g_streams(profile, rows)
  expected_columns = ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{profile.type_name}"]
  actual_columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  w111g_require(actual_columns == expected_columns, "#{label}: exact nominal columns differ: #{actual_columns.inspect}")
  w111g_require(File.read(File.join(part, "columns_substreams.txt")) == w111g_expected_substreams(streams), "#{label}: exact nested stream topology/order differs")
  w111g_require(File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)", "#{label}: codec differs")
  w111g_require(File.read(File.join(part, "metadata_version.txt")) == "0", "#{label}: metadata_version differs")
  w111g_require(File.read(File.join(part, "count.txt")) == W111G_KEYS.size.to_s, "#{label}: outer row count differs")

  expected_files = ["checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt", "default_compression_codec.txt", "metadata_version.txt", "primary.idx", "serialization.json"]
  streams.each do |stream|
    base = CrystalClick::StreamName.hash(stream.name)
    expected_files << "#{base}.bin" << "#{base}.mrk2"
  end
  actual_files = Dir.children(part).sort
  w111g_require(actual_files == expected_files.sort, "#{label}: exact file inventory differs (missing=#{(expected_files - actual_files).sort.inspect}, extra=#{(actual_files - expected_files).sort.inspect})")
  checksums = CrystalClick::PartChecksums.open(part)
  checksum_files = expected_files - ["checksums.txt", "columns.txt", "columns_substreams.txt", "default_compression_codec.txt", "metadata_version.txt"]
  w111g_require(checksums.entries.keys.sort == checksum_files.sort, "#{label}: exact checksum inventory differs")
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }

  primary = File.read(File.join(part, "primary.idx"))
  expected_primary = W111G_BOUNDARIES[0, W111G_BOUNDARIES.size - 1].map { |row| w111g_u64(W111G_KEYS[row]) }.join + w111g_u64(W111G_KEYS.last)
  w111g_seed_byte(primary, expected_primary, "#{label} independently encoded primary.idx")
  streams.each do |stream|
    actual = w111g_raw(part, stream.name)
    expected = stream.raw
    w111g_assert_bytes(actual, expected, "#{label} #{stream.name} literal raw stream")
    expected_marks = writer_profile ? w111g_writer_marks(stream) : w111g_stock_marks(stream)
    actual_marks = w111g_actual_marks(part, stream.name)
    w111g_require(actual_marks == expected_marks, "#{label} #{stream.name}: exact marks differ; expected #{expected_marks.inspect}, got #{actual_marks.inspect}")
    if stream.name == "payload%2E1"
      w111g_seed_byte(actual, expected, "#{label} X-coordinate seeded wrong-byte control") unless expected.empty?
    elsif stream.name == "payload.size#{profile.depth - 1}" && !expected.empty?
      w111g_seed_byte(actual, expected, "#{label} terminal-size seeded wrong-byte control")
    end
  end
  w111g_assert_metadata(part, profile, label, writer_profile)
  puts "PASS #{label}: #{profile.type_name} depth=#{profile.depth}, #{writer_profile ? "independent per-mark frames" : "stock offsets"}, exact streams/marks/metadata/checksums"
end

def w111g_run(binary : String, store : String, query : String, input : IO? = nil) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = if input
             Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  raise "ClickHouse query failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w111g_create(binary : String, store : String, table : String, profile : W111GProfile) : Nil
  settings = "#{W111G_SETTINGS}, ratio_of_defaults_for_sparse_serialization = #{profile.ratio}"
  w111g_run(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{profile.type_name}) ENGINE = MergeTree ORDER BY pk SETTINGS #{settings}")
  nil
end

def w111g_insert(binary : String, store : String, table : String, profile : W111GProfile, rows : Array(W111GNode)) : Nil
  indexes = (0...W111G_KEYS.size).map(&.to_i32).to_a
  input = IO::Memory.new(w111g_rowbinary(profile, rows, indexes).to_slice)
  w111g_run(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  nil
end

def w111g_part_path(binary : String, store : String, table : String) : String
  records = w111g_run(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  w111g_require(records.size == 1, "#{table}: expected one active part, got #{records.inspect}")
  fields = records[0].split('\t')
  w111g_require(fields.size == 3 && fields[1] == "Wide" && fields[2] == W111G_KEYS.size.to_s, "#{table}: part is not exactly nine-row Wide")
  fields[0]
end

def w111g_schema(binary : String, store : String, table : String, profile : W111GProfile) : Nil
  actual = w111g_run(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  expected = ["pk UInt64", "payload #{profile.type_name}"]
  w111g_require(actual == expected, "#{table}: exact declared schema differs: #{actual.inspect}")
end

def w111g_check(binary : String, store : String, table : String, part : String) : Nil
  actual = w111g_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  w111g_require(actual == expected, "#{table}: CHECK TABLE must equal exact part name + tab + 1; got #{actual.inspect}")
end

def w111g_rowbinary_checks(binary : String, store : String, table : String, profile : W111GProfile, rows : Array(W111GNode), label : String) : Nil
  full = (0...W111G_KEYS.size).map(&.to_i32).to_a
  selected = w111g_selected_indexes
  actual_full = w111g_run(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w111g_assert_bytes(actual_full, w111g_rowbinary(profile, rows, full), "#{label} independent full RowBinary")
  actual_selected = w111g_run(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 8 ORDER BY pk FORMAT RowBinary")
  w111g_assert_bytes(actual_selected, w111g_rowbinary(profile, rows, selected), "#{label} independent nonzero-PK RowBinary")
end

def w111g_attach(binary : String, store : String, table : String, profile : W111GProfile, source_part : String) : String
  w111g_create(binary, store, table, profile)
  data_path = w111g_run(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  w111g_require(!data_path.empty?, "#{table}: ATTACH destination path missing")
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(source_part, File.join(detached, "all_1_1_0"))
  w111g_run(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w111g_part_path(binary, store, table)
end

def w111g_qualify(binary : String, store : String, table : String, profile : W111GProfile, rows : Array(W111GNode), part : String, label : String, writer_profile : Bool = false) : Nil
  w111g_schema(binary, store, table, profile)
  w111g_assert_layout(part, profile, rows, label, writer_profile)
  w111g_check(binary, store, table, part)
  w111g_rowbinary_checks(binary, store, table, profile, rows, label)
  puts "PASS #{label}: CHECK=1 and exact full/selected RowBinary"
end

def w111g_check_actual_node(actual : CrystalClick::WideGeoArrayRow, expected : W111GNode, depth : Int32, level : Int32, label : String) : Nil
  if level == depth - 1
    w111g_require(actual.terminal?, "#{label}: expected terminal Point array")
    w111g_require(actual.size == expected.points.size, "#{label}: terminal length differs")
    expected.points.each_with_index do |point, index|
      got = actual.point_at(index)
      w111g_require(got.x_bits == point.x_bits && got.y_bits == point.y_bits, "#{label}[#{index}]: raw Point bits differ")
    end
  else
    w111g_require(!actual.terminal?, "#{label}: expected nested array")
    w111g_require(actual.size == expected.children.size, "#{label}: nested array length differs")
    expected.children.each_with_index do |child, index|
      w111g_check_actual_node(actual.array_at(index), child, depth, level + 1, "#{label}[#{index}]")
    end
  end
end

def w111g_assert_data(data : CrystalClick::WideGeoArrayColumnData, profile : W111GProfile, expected_rows : Array(W111GNode), label : String) : Nil
  w111g_require(data.type_name == profile.type_name, "#{label}: nominal Geo identity differs: #{data.type_name.inspect}")
  w111g_require(data.row_count == expected_rows.size, "#{label}: outer row count differs")
  expected_levels = w111g_level_sizes(profile, expected_rows)
  profile.depth.times do |level|
    w111g_require(data.topology.sizes(level) == expected_levels[level], "#{label}: level #{level} size vector differs")
  end
  expected_points = w111g_points(profile, expected_rows)
  w111g_require(data.point_count == expected_points.size, "#{label}: flattened Point count differs")
  actual_points = data.points
  expected_points.each_with_index do |point, index|
    got = actual_points[index]
    w111g_require(got.x_bits == point.x_bits && got.y_bits == point.y_bits, "#{label}: flattened Point #{index} raw bits differ")
  end
  expected_rows.each_with_index do |row, index|
    w111g_check_actual_node(data.row(index), row, profile.depth, 0, "#{label} row #{index}")
  end
end

def w111g_selected_rows(profile : W111GProfile, rows : Array(W111GNode)) : Array(W111GNode)
  start = W111G_BOUNDARIES[1]
  finish = W111G_BOUNDARIES[3]
  rows[start, finish - start]
end

def w111g_typed_reader(profile : W111GProfile, path : String, rows : Array(W111GNode), label : String) : Nil
  reader = CrystalClick::WidePart.open_typed(path, column: "payload")
  w111g_require(reader.column_type == profile.type_name, "#{label}: exact persisted type identity differs")
  all = reader.read_geo_array_mark_range("payload", 0, profile.data_mark_count)
  w111g_assert_data(all, profile, rows, "#{label} full range")
  selected = reader.read_geo_array_mark_range("payload", 1, 2)
  w111g_assert_data(selected, profile, w111g_selected_rows(profile, rows), "#{label} selected marks 1..3 / nonzero flattened origin")
  seen = 0
  reader.each_geo_array_mark_range("payload", 0, profile.data_mark_count) do |data, mark_index|
    first = W111G_BOUNDARIES[mark_index]
    after = W111G_BOUNDARIES[mark_index + 1]
    expected = rows[first, after - first]
    w111g_assert_data(data, profile, expected, "#{label} lazy mark #{mark_index}")
    seen += 1
  end
  w111g_require(seen == profile.data_mark_count, "#{label}: lazy callback count differs")
  puts "PASS #{label}: exact identity, full/selected topology+bits and each-mark lazy reads"
end

def w111g_profiles : Array(W111GProfile)
  profiles = [] of W111GProfile
  W111G_TYPES.each do |entry|
    type_name, depth = entry
    profiles << W111GProfile.new(type_name, depth, "mixed", "0.9375")
    profiles << W111GProfile.new(type_name, depth, "empty", "0.9375")
    profiles << W111GProfile.new(type_name, depth, "empty", "1.0")
  end
  profiles
end

def w111g_run_reader(binary : String, store : String) : Nil
  attached = [] of {W111GProfile, String, Array(W111GNode)}
  w111g_profiles.each do |profile|
    rows = w111g_fixture(profile)
    source_table = "w111g_reader_source_#{profile.safe_suffix}"
    attach_table = "w111g_reader_attach_#{profile.safe_suffix}"
    w111g_create(binary, store, source_table, profile)
    w111g_insert(binary, store, source_table, profile, rows)
    source_part = w111g_part_path(binary, store, source_table)
    w111g_qualify(binary, store, source_table, profile, rows, source_part, "W111 reader source #{profile.label}")
    attached_part = w111g_attach(binary, store, attach_table, profile, source_part)
    w111g_qualify(binary, store, attach_table, profile, rows, attached_part, "W111 reader fresh ATTACH #{profile.label}")
    attached << {profile, attached_part, rows}
  end
  attached.each do |profile, part, rows|
    w111g_typed_reader(profile, part, rows, "W111 typed stock #{profile.label}")
  end
  puts "PASS W111 --green-reader: #{attached.size} profiles (five mixed plus ten all-empty settings), source+ATTACH qualified before typed reads"
end

def w111g_writer_levels(profile : W111GProfile, rows : Array(W111GNode)) : Array(Array(UInt64))
  w111g_level_sizes(profile, rows)
end

def w111g_writer_points(profile : W111GProfile, rows : Array(W111GNode)) : Array(CrystalClick::WidePointValue)
  w111g_points(profile, rows).map { |point| CrystalClick::WidePointValue.from_bits(point.x_bits, point.y_bits) }
end

def w111g_run_writer(binary : String, store : String) : Nil
  profiles = [] of W111GProfile
  W111G_TYPES.each do |entry|
    profiles << W111GProfile.new(entry[0], entry[1], "mixed", "0.9375")
    profiles << W111GProfile.new(entry[0], entry[1], "empty", "0.9375")
  end
  profiles.each do |profile|
    rows = w111g_fixture(profile)
    parent = File.join(store, "w111g_writer_#{profile.safe_suffix}")
    FileUtils.mkdir_p(parent)
    output_part = File.join(parent, "all_1_1_0")
    keys = W111G_KEYS.to_unsafe.to_slice(W111G_KEYS.size)
    levels = w111g_writer_levels(profile, rows)
    points = w111g_writer_points(profile, rows)
    actual_path = CrystalClick::WidePartWriter.write_uint64_geo_array_pair(
      output_part, "pk", keys, "payload", profile.type_name, levels, points, rows_per_mark: 2
    )
    w111g_require(actual_path == output_part, "#{profile.label}: writer returned unexpected destination")
    w111g_assert_layout(output_part, profile, rows, "W111 Crystal writer #{profile.label}", true)
    attached_table = "w111g_writer_attach_#{profile.safe_suffix}"
    attached_part = w111g_attach(binary, store, attached_table, profile, output_part)
    w111g_qualify(binary, store, attached_table, profile, rows, attached_part, "W111 writer fresh ATTACH #{profile.label}", true)
    w111g_typed_reader(profile, attached_part, rows, "W111 typed writer ATTACH #{profile.label}")
  end
  puts "PASS W111 --green-writer: ten writer profiles (five mixed and five all-empty), per-mark framing + ATTACH CHECK=1 + RowBinary + typed read"
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["W111G_STORE"]? || raise "set W111G_STORE to a fresh temporary ClickHouse store"
mode = ARGV.shift? || raise "usage: --green-reader | --green-writer"
mode = case mode
       when "reader", "--green-reader" then "reader"
       when "writer", "--green-writer" then "writer"
       else                                 raise "usage: --green-reader | --green-writer"
       end
w111g_require(ARGV.empty?, "unexpected extra arguments")
w111g_require(store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/"), "refusing non-temporary W111G store: #{store}")
if Dir.exists?(store)
  w111g_require(Dir.empty?(store), "W111G store must be fresh and empty")
else
  Dir.mkdir_p(store)
end

version = IO::Memory.new
status = Process.run(binary, ["local", "--version"], output: version)
w111g_require(status.success?, "could not inspect ClickHouse version")
expected_version = "ClickHouse local version #{W111G_VERSION} (official build)."
w111g_require(version.to_s.strip == expected_version, "W111 requires #{expected_version}, got #{version.to_s.strip}")
puts "Pinned independent storage peer: #{version.to_s.strip}"

case mode
when "reader"
  w111g_run_reader(binary, store)
when "writer"
  w111g_run_writer(binary, store)
end
