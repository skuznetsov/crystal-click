# W110 stock-first qualification for the five Geo Array types recognized by
# pinned ClickHouse 26.7.1.1315. Expected bytes are built from literal tree
# nodes below, independently of Crystal's reader/writer.
require "json"
require "file_utils"
require "../src/crystal_click"

W110_STOCK_VERSION     = "26.7.1.1315"
W110_SOURCE_TABLE      = "w110_geo_source"
W110_SETTINGS          = "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 0.9375, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"
W110_KEYS              = [0_u64, 0_u64, 2_u64, 3_u64, 4_u64, 4_u64, 5_u64, 7_u64, 9_u64]
W110_BOUNDARIES        = [0, 2, 4, 6, 8, 9]
W110_MARK_ROWS         = [2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
W110_SELECTED_MIN      = 2_u64
W110_SELECTED_MAX      = 8_u64
W110_MARK_RECORD_BYTES =    24
W110_TYPES             = [
  {"LineString", 1},
  {"Ring", 1},
  {"Polygon", 2},
  {"MultiLineString", 2},
  {"MultiPolygon", 3},
]

class W110OracleMismatchError < Exception
end

struct W110Profile
  getter type_name : String
  getter depth : Int32

  def initialize(@type_name : String, @depth : Int32)
  end
end

struct W110Point
  getter x_bits : UInt64
  getter y_bits : UInt64

  def initialize(@x_bits : UInt64, @y_bits : UInt64)
  end
end

# Each node is one Array at its current nesting level. At the terminal level,
# `points` are the Point tuple leaves; earlier levels use `children`.
class W110Node
  getter children : Array(W110Node)
  getter points : Array(W110Point)

  def initialize(@children : Array(W110Node), @points : Array(W110Point))
  end
end

struct W110Stream
  getter name : String
  getter row_fragments : Array(Array(String))

  def initialize(@name : String, @row_fragments : Array(Array(String)))
  end

  def fragments : Array(String)
    result = [] of String
    row_fragments.each { |row| result.concat(row) }
    result
  end
end

W110_POINTS = [
  W110Point.new(0x8000_0000_0000_0000_u64, 0x0000_0000_0000_0000_u64), # -0,+0
  W110Point.new(0x7ff8_0000_0000_1234_u64, 0x400c_0000_0000_0000_u64), # NaN payload,3.5
  W110Point.new(0xfff0_0000_0000_0000_u64, 0x0000_0000_0000_0001_u64), # -Inf,min subnormal
  W110Point.new(0x4002_0000_0000_0000_u64, 0x7ff8_0000_0000_5678_u64), # 2.25,distinct NaN
]

def w110_fail(message : String) : NoReturn
  raise W110OracleMismatchError.new(message)
end

def w110_require(condition : Bool, message : String) : Nil
  w110_fail(message) unless condition
end

def w110_u64_le(value : UInt64) : String
  String.build do |output|
    8.times { |index| output.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
  end
end

def w110_varuint(value : UInt64) : String
  String.build do |output|
    remaining = value
    while remaining >= 0x80_u64
      output.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
      remaining >>= 7
    end
    output.write_byte(remaining.to_u8)
  end
end

def w110_leaf(points : Array(W110Point)) : W110Node
  W110Node.new([] of W110Node, points)
end

def w110_branch(children : Array(W110Node)) : W110Node
  W110Node.new(children, [] of W110Point)
end

def w110_empty : W110Node
  W110Node.new([] of W110Node, [] of W110Point)
end

def w110_point_count(node : W110Node, depth : Int32, level : Int32) : UInt64
  if level == depth - 1
    node.points.size.to_u64
  else
    total = 0_u64
    node.children.each { |child| total += w110_point_count(child, depth, level + 1) }
    total
  end
end

def w110_node_signature(node : W110Node, depth : Int32, level : Int32) : String
  String.build do |output|
    if level == depth - 1
      output << "P#{node.points.size}["
      node.points.each { |point| output << point.x_bits.to_s(16) << "/" << point.y_bits.to_s(16) << ";" }
      output << "]"
    else
      output << "A#{node.children.size}["
      node.children.each { |child| output << w110_node_signature(child, depth, level + 1) << ";" }
      output << "]"
    end
  end
end

def w110_fixture(profile : W110Profile) : Array(W110Node)
  rows = Array(W110Node).new(W110_KEYS.size) { w110_empty }
  if profile.depth == 1
    rows[0] = w110_leaf([W110_POINTS[0]])
    rows[1] = w110_leaf([W110_POINTS[0]])
    rows[2] = w110_leaf([W110_POINTS[0], W110_POINTS[1]])
    rows[6] = w110_leaf([W110_POINTS[2]])
    rows[7] = w110_leaf([W110_POINTS[3]])
    rows[8] = w110_leaf([W110_POINTS[1]])
  elsif profile.depth == 2
    rows[0] = w110_branch([w110_leaf([W110_POINTS[0]])])
    rows[1] = w110_branch([w110_leaf([W110_POINTS[0]])])
    rows[2] = w110_branch([w110_leaf([] of W110Point), w110_leaf([W110_POINTS[0], W110_POINTS[1]])])
    rows[6] = w110_branch([w110_leaf([W110_POINTS[2]])])
    rows[7] = w110_branch([w110_leaf([] of W110Point), w110_leaf([W110_POINTS[3]])])
    rows[8] = w110_branch([w110_leaf([W110_POINTS[1]])])
  elsif profile.depth == 3
    rows[0] = w110_branch([w110_branch([w110_leaf([W110_POINTS[0]])])])
    rows[1] = w110_branch([w110_branch([w110_leaf([W110_POINTS[0]])])])
    rows[2] = w110_branch([
      w110_branch([] of W110Node),
      # Three rings in this polygon distinguish ring counts from polygon
      # counts, while the additional empty ring does not add Point leaves.
      w110_branch([w110_leaf([] of W110Point), w110_leaf([W110_POINTS[0], W110_POINTS[1]]), w110_leaf([] of W110Point)]),
    ])
    rows[6] = w110_branch([w110_branch([w110_leaf([W110_POINTS[2]])])])
    rows[7] = w110_branch([
      w110_branch([] of W110Node),
      w110_branch([w110_leaf([] of W110Point), w110_leaf([W110_POINTS[3]])]),
    ])
    rows[8] = w110_branch([w110_branch([w110_leaf([W110_POINTS[1]])])])
    w110_require(rows[2].children.size == 2 && rows[2].children.sum(&.children.size) == 3, "#{profile.type_name}: depth-three fixture must distinguish polygon and ring counts")
  else
    raise "unsupported W110 fixture depth #{profile.depth}"
  end
  w110_require(w110_node_signature(rows[0], profile.depth, 0) == w110_node_signature(rows[1], profile.depth, 0), "#{profile.type_name}: tied PK prelude rows must be byte-identical")
  prelude_points = w110_point_count(rows[0], profile.depth, 0) + w110_point_count(rows[1], profile.depth, 0)
  w110_require(prelude_points > 0, "#{profile.type_name}: selected PK window must begin after nonempty flattened data")
  w110_require(w110_point_count(rows[8], profile.depth, 0) > 0, "#{profile.type_name}: key-9 suffix must be nonempty")
  rows.each_with_index { |row, index| w110_validate_node(row, profile.depth, 0, "#{profile.type_name} row #{index}") }
  rows
end

def w110_validate_node(node : W110Node, depth : Int32, level : Int32, label : String) : Nil
  if level == depth - 1
    w110_require(node.children.empty?, "#{label}: terminal Array unexpectedly has child arrays")
  else
    w110_require(node.points.empty?, "#{label}: nonterminal Array unexpectedly has Point leaves")
    node.children.each { |child| w110_validate_node(child, depth, level + 1, label) }
  end
end

def w110_collect(node : W110Node, profile : W110Profile, level : Int32, size_fragments : Array(Array(String)), xs : Array(String), ys : Array(String)) : Nil
  if level == profile.depth - 1
    size_fragments[level] << w110_u64_le(node.points.size.to_u64)
    node.points.each do |point|
      xs << w110_u64_le(point.x_bits)
      ys << w110_u64_le(point.y_bits)
    end
  else
    size_fragments[level] << w110_u64_le(node.children.size.to_u64)
    node.children.each { |child| w110_collect(child, profile, level + 1, size_fragments, xs, ys) }
  end
end

def w110_streams(profile : W110Profile, rows : Array(W110Node)) : Array(W110Stream)
  level_rows = Array(Array(Array(String))).new(profile.depth) { [] of Array(String) }
  x_rows = [] of Array(String)
  y_rows = [] of Array(String)
  rows.each do |root|
    size_fragments = Array(Array(String)).new(profile.depth) { [] of String }
    xs = [] of String
    ys = [] of String
    w110_collect(root, profile, 0, size_fragments, xs, ys)
    profile.depth.times { |level| level_rows[level] << size_fragments[level] }
    x_rows << xs
    y_rows << ys
  end
  streams = [W110Stream.new("pk", W110_KEYS.map { |key| [w110_u64_le(key)] })]
  profile.depth.times { |level| streams << W110Stream.new("payload.size#{level}", level_rows[level]) }
  streams << W110Stream.new("payload%2E1", x_rows)
  streams << W110Stream.new("payload%2E2", y_rows)
  streams
end

def w110_write_array_rowbinary(output : IO, node : W110Node, profile : W110Profile, level : Int32) : Nil
  if level == profile.depth - 1
    output << w110_varuint(node.points.size.to_u64)
    node.points.each do |point|
      output << w110_u64_le(point.x_bits)
      output << w110_u64_le(point.y_bits)
    end
  else
    output << w110_varuint(node.children.size.to_u64)
    node.children.each { |child| w110_write_array_rowbinary(output, child, profile, level + 1) }
  end
end

def w110_expected_rowbinary(profile : W110Profile, rows : Array(W110Node), indexes : Array(Int32)) : String
  String.build do |output|
    indexes.each do |index|
      output << w110_u64_le(W110_KEYS[index])
      w110_write_array_rowbinary(output, rows[index], profile, 0)
    end
  end
end

def w110_expected_columns(profile : W110Profile) : Array(String)
  ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{profile.type_name}"]
end

def w110_expected_substreams(streams : Array(W110Stream)) : String
  payload_streams = streams.reject { |stream| stream.name == "pk" }
  w110_require(streams.count { |stream| stream.name == "pk" } == 1, "expected exactly one literal PK stream")
  lines = [
    "columns substreams version: 1",
    "2 columns:",
    "1 substreams for column `pk`:",
    "\tpk",
    "#{payload_streams.size} substreams for column `payload`:",
  ]
  payload_streams.each { |stream| lines << "\t#{stream.name}" }
  lines.join("\n") + "\n"
end

def w110_actual_marks(part : String, stream_name : String) : Array({UInt64, UInt64, UInt64})
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream_name)}.mrk2")).to_slice
  mark_size = W110_MARK_RECORD_BYTES
  w110_require(bytes.size % mark_size == 0, "#{stream_name}: partial .mrk2 record")
  Array({UInt64, UInt64, UInt64}).new(bytes.size // mark_size) do |index|
    offset = index * mark_size
    fields = Array(UInt64).new(3) do |field|
      start = offset + field * 8
      8.times.reduce(0_u64) { |value, byte| value | (bytes[start + byte].to_u64 << (byte * 8)) }
    end
    {fields[0], fields[1], fields[2]}
  end
end

def w110_expected_marks(stream : W110Stream) : Array({UInt64, UInt64, UInt64})
  W110_BOUNDARIES.map_with_index do |boundary, mark_index|
    decompressed_offset = 0_u64
    boundary.times do |row_index|
      stream.row_fragments[row_index].each { |fragment| decompressed_offset += fragment.bytesize.to_u64 }
    end
    {0_u64, decompressed_offset, W110_MARK_ROWS[mark_index]}
  end.to_a
end

def w110_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  difference = 0
  while difference < limit && actual.to_slice[difference] == expected.to_slice[difference]
    difference += 1
  end
  got = difference < actual.bytesize ? actual.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  wanted = difference < expected.bytesize ? expected.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  raise W110OracleMismatchError.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first diff #{difference}: expected #{wanted}, got #{got}")
end

def w110_seeded_byte_control(actual : String, expected : String, label : String) : Nil
  w110_assert_bytes(actual, expected, label)
  w110_require(!expected.empty?, "#{label}: cannot seed a changed-byte control from empty bytes")
  damaged = String.new(expected.to_slice)
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 0x01_u8
  rejected = false
  begin
    w110_assert_bytes(actual, damaged, label)
  rescue ex : W110OracleMismatchError
    rejected = true
  end
  w110_require(rejected, "#{label}: comparator accepted seeded one-byte corruption")
  puts "PASS #{label}: seeded byte-drift control"
end

def w110_u64_from_le(bytes : String) : UInt64
  w110_require(bytes.bytesize == 8, "expected one literal UInt64 fragment, got #{bytes.bytesize} bytes")
  slice = bytes.to_slice
  8.times.reduce(0_u64) { |value, index| value | (slice[index].to_u64 << (index * 8)) }
end

def w110_seeded_size_topology_control(actual : String, stream : W110Stream, profile : W110Profile, label : String) : Nil
  expected = stream.fragments.join
  w110_assert_bytes(actual, expected, label)
  w110_require(stream.row_fragments.size == W110_KEYS.size, "#{label}: size-record row count differs")
  values = stream.row_fragments.map do |fragments|
    fragments.map { |fragment| w110_u64_from_le(fragment) }
  end

  # This is only a seeded expected-oracle mutation, not a claim that a
  # malformed serialized part was accepted or rejected. Move one count from
  # a populated child array to an empty child array (or, at depth one, to the
  # next empty outer row), preserving total size-stream cardinality and bytes.
  if profile.depth == 1
    donor = {2, 0}
    receiver = {3, 0}
  else
    donor = {2, 1}
    receiver = {2, 0}
  end
  w110_require(values[donor[0]][donor[1]] > 0 && values[receiver[0]][receiver[1]] == 0, "#{label}: literal donor/receiver records are not positive/empty")
  original_total = 0_u64
  values.each { |row| row.each { |value| original_total += value } }
  values[donor[0]][donor[1]] -= 1
  values[receiver[0]][receiver[1]] += 1
  mutated_total = 0_u64
  values.each { |row| row.each { |value| mutated_total += value } }
  damaged = values.map { |row| row.map { |value| w110_u64_le(value) }.join }.join
  w110_require(damaged.bytesize == expected.bytesize, "#{label}: topology mutation changed encoded byte length")
  w110_require(mutated_total == original_total, "#{label}: topology mutation changed total cardinality")

  rejected = false
  begin
    w110_assert_bytes(actual, damaged, "#{label} seeded same-cardinality topology mutation")
  rescue ex : W110OracleMismatchError
    rejected = true
  end
  w110_require(rejected, "#{label}: comparator accepted same-cardinality size/topology expectation drift")
  puts "PASS #{label}: seeded same-cardinality size/topology expectation-drift control"
end

def w110_validate_pk_counter(record : Hash(String, JSON::Any), defaults : Int32, rows : Int32, label : String) : Nil
  expected_keys = ["kind", "name", "num_defaults", "num_rows"].sort
  w110_fail("#{label}: exact PK metadata keys differ: #{record.keys.sort.inspect}") unless record.keys.sort == expected_keys
  w110_fail("#{label}: PK metadata kind is not Default") unless record["kind"]?.try(&.as_s) == "Default"
  w110_fail("#{label}: PK metadata name differs") unless record["name"]?.try(&.as_s) == "pk"
  w110_fail("#{label}: PK metadata row count differs") unless record["num_rows"]?.try(&.as_i) == rows.to_i64
  w110_fail("#{label}: PK metadata default count differs") unless record["num_defaults"]?.try(&.as_i) == defaults.to_i64
end

def w110_assert_serialization(part : String, label : String) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  expected_envelope = ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"].sort
  w110_fail("#{label}: serialization envelope differs: #{info.keys.sort.inspect}") unless info.keys.sort == expected_envelope
  w110_fail("#{label}: serialization version differs") unless info["version"]?.try(&.as_i) == 1_i64
  w110_fail("#{label}: nested type-version propagation differs") unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: type-version map missing"
  w110_fail("#{label}: type-version map differs: #{versions.to_json}") unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1_i64
  records = info["columns"]?.try(&.as_a) || raise "#{label}: serialization columns missing"
  names = records.map { |record| record.as_h["name"]?.try(&.as_s) || raise "#{label}: top-level serializer name missing" }
  # DataTypeArray is not sparse-serialization-capable (it has subtypes), so
  # this pinned profile serializes only the external PK record, not Array or
  # recursively nested Point statistics.
  w110_fail("#{label}: exact Array-root metadata policy differs: #{names.inspect}") unless names == ["pk"]
  record = records[0].as_h
  w110_validate_pk_counter(record, 2, W110_KEYS.size, "#{label} PK")
  wrong_counter_rejected = false
  begin
    w110_validate_pk_counter(record, 3, W110_KEYS.size, "#{label} seeded PK counter")
  rescue ex : W110OracleMismatchError
    wrong_counter_rejected = true
  end
  w110_require(wrong_counter_rejected, "#{label}: metadata comparator accepted seeded default-counter drift")
  puts "PASS #{label}: exact PK-only Default metadata and seeded counter-drift control"
end

def w110_raw_stream(part : String, name : String) : String
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(name)}.bin")).to_slice
  String.new(CrystalClick::CompressedBlock.decode_all(encoded))
end

def w110_assert_layout(part : String, profile : W110Profile, label : String) : Nil
  rows = w110_fixture(profile)
  streams = w110_streams(profile, rows)
  columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  w110_fail("#{label}: exact nominal columns.txt differs: #{columns.inspect}") unless columns == w110_expected_columns(profile)
  substreams = File.read(File.join(part, "columns_substreams.txt"))
  wanted_substreams = w110_expected_substreams(streams)
  w110_fail("#{label}: exact size/coordinate stream topology differs:\nexpected:\n#{wanted_substreams}actual:\n#{substreams}") unless substreams == wanted_substreams
  w110_require(File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)", "#{label}: codec differs")
  w110_require(File.read(File.join(part, "metadata_version.txt")) == "0", "#{label}: metadata version differs")
  w110_require(File.read(File.join(part, "count.txt")) == W110_KEYS.size.to_s, "#{label}: count.txt differs")

  expected_files = ["checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt", "default_compression_codec.txt", "metadata_version.txt", "primary.idx", "serialization.json"]
  streams.each do |stream|
    hash = CrystalClick::StreamName.hash(stream.name)
    expected_files << "#{hash}.bin" << "#{hash}.mrk2"
  end
  actual_files = Dir.children(part).sort
  w110_fail("#{label}: exact file inventory differs (missing=#{(expected_files - actual_files).sort.inspect}, extra=#{(actual_files - expected_files).sort.inspect})") unless actual_files == expected_files.sort

  checksums = CrystalClick::PartChecksums.open(part)
  checksum_files = expected_files - ["checksums.txt", "columns.txt", "columns_substreams.txt", "default_compression_codec.txt", "metadata_version.txt"]
  w110_require(checksums.entries.keys.sort == checksum_files.sort, "#{label}: checksum inventory differs")
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }

  primary_expected = W110_BOUNDARIES[0, W110_BOUNDARIES.size - 1].map { |boundary| w110_u64_le(W110_KEYS[boundary]) }.join + w110_u64_le(W110_KEYS.last)
  primary = File.read(File.join(part, "primary.idx"))
  w110_seeded_byte_control(primary, primary_expected, "#{label} independent plain primary.idx")
  streams.each do |stream|
    expected = stream.fragments.join
    actual = w110_raw_stream(part, stream.name)
    w110_assert_bytes(actual, expected, "#{label} #{stream.name} raw bytes")
    marks = w110_actual_marks(part, stream.name)
    expected_marks = w110_expected_marks(stream)
    w110_fail("#{label} #{stream.name}: exact mark tuples differ; expected #{expected_marks.inspect}, got #{marks.inspect}") unless marks == expected_marks
    if stream.name == "payload%2E1" || stream.name == "payload%2E2"
      w110_seeded_byte_control(actual, expected, "#{label} #{stream.name} coordinate stream")
    elsif stream.name == "payload.size#{profile.depth - 1}"
      w110_seeded_size_topology_control(actual, stream, profile, "#{label} #{stream.name}")
    end
  end
  w110_assert_serialization(part, label)
  puts "PASS #{label}: #{profile.type_name}, depth #{profile.depth}, exact nominal schema, all size streams, raw IEEE coordinates, marks, checksums and metadata"
end

def w110_run(binary : String, store : String, query : String, input : IO? = nil) : String
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

def w110_create_table(binary : String, store : String, table : String, type_name : String) : Nil
  w110_run(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{type_name}) ENGINE = MergeTree ORDER BY pk SETTINGS #{W110_SETTINGS}")
  nil
end

def w110_part_path(binary : String, store : String, table : String) : String
  rows = w110_run(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  w110_require(rows.size == 1, "#{table}: expected exactly one active Wide part, got #{rows.inspect}")
  fields = rows[0].split('\t')
  w110_require(fields.size == 3 && fields[1] == "Wide" && fields[2] == W110_KEYS.size.to_s, "#{table}: malformed/non-Wide system.parts row #{rows[0].inspect}")
  fields[0]
end

def w110_assert_schema(binary : String, store : String, table : String, profile : W110Profile) : Nil
  actual = w110_run(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  expected = ["pk UInt64", "payload #{profile.type_name}"]
  w110_fail("#{table}: exact system.columns declaration differs: #{actual.inspect}") unless actual == expected
end

def w110_check_table(binary : String, store : String, table : String, part : String) : Nil
  actual = w110_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  w110_require(actual == expected, "#{table}: CHECK TABLE must return exact part and 1; got #{actual.inspect}")
end

def w110_assert_rowbinary(binary : String, store : String, table : String, profile : W110Profile, label : String) : Nil
  rows = w110_fixture(profile)
  indexes = (0...W110_KEYS.size).map(&.to_i32)
  actual_full = w110_run(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w110_assert_bytes(actual_full, w110_expected_rowbinary(profile, rows, indexes), "#{label} full RowBinary")
  selected_indexes = W110_KEYS.each_with_index.select { |key, _index| key >= W110_SELECTED_MIN && key < W110_SELECTED_MAX }.map { |_key, index| index.to_i32 }.to_a
  actual_selected = w110_run(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= #{W110_SELECTED_MIN} AND pk < #{W110_SELECTED_MAX} ORDER BY pk FORMAT RowBinary")
  w110_assert_bytes(actual_selected, w110_expected_rowbinary(profile, rows, selected_indexes), "#{label} nonzero selected-PK RowBinary")
  puts "PASS #{label}: independent full and nonzero-PK-selected RowBinary"
end

def w110_insert(binary : String, store : String, table : String, profile : W110Profile) : Nil
  rows = w110_fixture(profile)
  indexes = (0...W110_KEYS.size).map(&.to_i32)
  input = IO::Memory.new(w110_expected_rowbinary(profile, rows, indexes).to_slice)
  w110_run(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  nil
end

def w110_attach(binary : String, store : String, table : String, profile : W110Profile, source_part : String) : String
  w110_create_table(binary, store, table, profile.type_name)
  data_path = w110_run(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  w110_require(!data_path.empty?, "#{table}: ATTACH destination data path is empty")
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(source_part, File.join(detached, "all_1_1_0"))
  w110_run(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w110_part_path(binary, store, table)
end

def w110_expect_reader_refusal(part : String, profile : W110Profile) : Nil
  begin
    CrystalClick::WidePart.open_typed(part, "payload")
  rescue ex : CrystalClick::UnsupportedFormatError
    w110_require(ex.message == "unsupported exact typed column", "#{profile.type_name}: typed refusal occurred for unrelated reason: #{ex.message}")
    puts "EXPECTED REFUSAL #{profile.type_name}: exact unsupported typed column"
    return
  end
  raise "#{profile.type_name}: predecessor typed reader unexpectedly admitted the type"
end

def w110_expect_multipoint_unknown(binary : String, store : String) : Nil
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", "CREATE TABLE default.w110_multipoint_capability (pk UInt64, payload MultiPoint) ENGINE = MergeTree ORDER BY pk"], output: output, error: error)
  detail = "#{output}\n#{error}"
  w110_require(!status.success? && detail.includes?("UNKNOWN_TYPE"), "pinned MultiPoint capability changed; expected UNKNOWN_TYPE, got status=#{status.exit_code}, #{detail}")
  puts "CAPABILITY MultiPoint: pinned ClickHouse 26.7.1.1315 reports UNKNOWN_TYPE (not counted as a typed-reader RED)"
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["W110_STORE"]? || raise "set W110_STORE to a fresh temporary ClickHouse store"
mode = ENV["W110_MODE"]? || "qualify"
raise "unsupported W110 mode #{mode.inspect}" unless mode == "qualify" || mode == "red" || mode == "capability-only"
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary W110_STORE path: #{store}"
end
if Dir.exists?(store)
  raise "W110_STORE must be empty: #{store}" unless Dir.empty?(store)
else
  Dir.mkdir_p(store)
end

version_output = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version_output)
raise "could not read pinned ClickHouse version" unless version_status.success?
expected_version = "ClickHouse local version #{W110_STOCK_VERSION} (official build)."
raise "W110 requires #{expected_version}, got #{version_output.to_s.strip}" unless version_output.to_s.strip == expected_version
puts "Stock oracle: #{version_output.to_s.strip}"
w110_expect_multipoint_unknown(binary, store)
if mode == "capability-only"
  puts "W110 capability-only check complete"
  exit 0
end

attached_parts = [] of String
W110_TYPES.each do |entry|
  type_name = entry[0]
  depth = entry[1]
  profile = W110Profile.new(type_name, depth)
  source_table = "#{W110_SOURCE_TABLE}_#{type_name.downcase}"
  attach_table = "w110_geo_attached_#{type_name.downcase}"
  w110_create_table(binary, store, source_table, type_name)
  w110_insert(binary, store, source_table, profile)
  source_part = w110_part_path(binary, store, source_table)
  w110_assert_schema(binary, store, source_table, profile)
  w110_assert_layout(source_part, profile, "W110 #{type_name} source")
  w110_check_table(binary, store, source_table, source_part)
  w110_assert_rowbinary(binary, store, source_table, profile, "W110 #{type_name} source")

  attached_part = w110_attach(binary, store, attach_table, profile, source_part)
  w110_assert_schema(binary, store, attach_table, profile)
  w110_assert_layout(attached_part, profile, "W110 #{type_name} fresh ATTACH")
  w110_check_table(binary, store, attach_table, attached_part)
  w110_assert_rowbinary(binary, store, attach_table, profile, "W110 #{type_name} fresh ATTACH")
  attached_parts << attached_part
end

# Typed rejection is evaluated only after all five source parts and fresh
# ATTACH copies have passed independent layout, byte, mark, checksum, CHECK=1,
# full RowBinary, and nonzero-PK selected RowBinary controls.
W110_TYPES.each_with_index do |entry, index|
  type_name = entry[0]
  depth = entry[1]
  w110_expect_reader_refusal(attached_parts[index], W110Profile.new(type_name, depth))
end

puts "PASS W110 qualification: all five supported nominal Geo Array profiles certified before typed-reader refusal"
if mode == "red"
  puts "EXPECTED W110 RED: stock-certified nominal Geo Arrays are still refused by the predecessor typed reader"
  exit 1
end
puts "W110 qualify mode exits 0 after expected predecessor refusals"
