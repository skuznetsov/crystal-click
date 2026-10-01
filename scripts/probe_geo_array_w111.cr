# Stock-only W111 qualification for completely empty Geo Array payloads.
# Expected bytes come only from the literal nine-key/empty-array fixture.
require "json"
require "file_utils"
require "../src/crystal_click/errors"
require "../src/crystal_click/metadata"
require "../src/crystal_click/city_hash_v1"
require "../src/crystal_click/stream_name"
require "../src/crystal_click/lz4"
require "../src/crystal_click/zstd"
require "../src/crystal_click/compressed_block"
require "../src/crystal_click/part_checksums"

W111_VERSION    = "26.7.1.1315"
W111_KEYS       = [0_u64, 0_u64, 2_u64, 3_u64, 4_u64, 4_u64, 5_u64, 7_u64, 9_u64]
W111_BOUNDARIES = [0, 2, 4, 6, 8, 9]
W111_MARK_ROWS  = [2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
W111_MARK_BYTES = 24
W111_TYPES      = [{"LineString", 1}, {"Ring", 1}, {"Polygon", 2}, {"MultiLineString", 2}, {"MultiPolygon", 3}]
W111_SETTINGS   = "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"

class W111Mismatch < Exception
end

struct W111Profile
  getter type_name : String
  getter depth : Int32
  getter ratio : String

  def initialize(@type_name : String, @depth : Int32, @ratio : String)
  end

  def label : String
    "#{type_name} ratio=#{ratio}"
  end

  def suffix : String
    ratio == "1.0" ? "r1" : "r09375"
  end
end

struct W111Stream
  getter name : String
  getter row_bytes : Array(String)

  def initialize(@name : String, @row_bytes : Array(String))
  end

  def raw : String
    row_bytes.join
  end
end

def w111_fail(message : String) : NoReturn
  raise W111Mismatch.new(message)
end

def w111_require(condition : Bool, message : String) : Nil
  w111_fail(message) unless condition
end

def w111_u64(value : UInt64) : String
  String.build do |io|
    8.times { |i| io.write_byte(((value >> (8 * i)) & 0xff_u64).to_u8) }
  end
end

def w111_varuint(value : UInt64) : String
  String.build do |io|
    n = value
    while n >= 0x80_u64
      io.write_byte(((n & 0x7f_u64) | 0x80_u64).to_u8)
      n >>= 7
    end
    io.write_byte(n.to_u8)
  end
end

def w111_streams(profile : W111Profile) : Array(W111Stream)
  streams = [W111Stream.new("pk", W111_KEYS.map { |key| w111_u64(key) })]
  profile.depth.times do |level|
    # Root size0 has one zero per outer row. No nested child exists, so all
    # deeper size lanes and both terminal Point coordinate lanes have 0 rows.
    bytes = level == 0 ? Array(String).new(W111_KEYS.size) { w111_u64(0_u64) } : Array(String).new(W111_KEYS.size) { "" }
    streams << W111Stream.new("payload.size#{level}", bytes)
  end
  streams << W111Stream.new("payload%2E1", Array(String).new(W111_KEYS.size) { "" })
  streams << W111Stream.new("payload%2E2", Array(String).new(W111_KEYS.size) { "" })
  streams
end

def w111_expected_columns(profile : W111Profile) : Array(String)
  ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{profile.type_name}"]
end

def w111_expected_substreams(streams : Array(W111Stream)) : String
  payload = streams.reject { |stream| stream.name == "pk" }
  w111_require(streams.count { |stream| stream.name == "pk" } == 1, "expected exactly one PK substream")
  lines = ["columns substreams version: 1", "2 columns:", "1 substreams for column `pk`:", "\tpk", "#{payload.size} substreams for column `payload`:"]
  payload.each { |stream| lines << "\t#{stream.name}" }
  lines.join("\n") + "\n"
end

def w111_marks(part : String, stream : String) : Array({UInt64, UInt64, UInt64})
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  w111_require(bytes.size % W111_MARK_BYTES == 0, "#{stream}: partial literal 24-byte mark record")
  Array({UInt64, UInt64, UInt64}).new(bytes.size // W111_MARK_BYTES) do |index|
    offset = index * W111_MARK_BYTES
    fields = Array(UInt64).new(3) do |field|
      first = offset + field * 8
      8.times.reduce(0_u64) { |n, i| n | (bytes[first + i].to_u64 << (8 * i)) }
    end
    {fields[0], fields[1], fields[2]}
  end
end

def w111_expected_marks(stream : W111Stream) : Array({UInt64, UInt64, UInt64})
  W111_BOUNDARIES.map_with_index do |boundary, index|
    offset = 0_u64
    boundary.times { |row| offset += stream.row_bytes[row].bytesize.to_u64 }
    {0_u64, offset, W111_MARK_ROWS[index]}
  end.to_a
end

def w111_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  i = 0
  while i < limit && actual.to_slice[i] == expected.to_slice[i]
    i += 1
  end
  got = i < actual.bytesize ? actual.to_slice[i].to_s(16).rjust(2, '0') : "<eof>"
  want = i < expected.bytesize ? expected.to_slice[i].to_s(16).rjust(2, '0') : "<eof>"
  raise W111Mismatch.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first diff #{i}: expected #{want}, got #{got}")
end

def w111_seeded_byte(actual : String, expected : String, label : String) : Nil
  w111_assert_bytes(actual, expected, label)
  w111_require(!expected.empty?, "#{label}: cannot seed mutation from empty bytes")
  altered = String.new(expected.to_slice)
  altered.to_unsafe[0] = altered.to_slice[0] ^ 0x01_u8
  rejected = false
  begin
    w111_assert_bytes(actual, altered, label)
  rescue ex : W111Mismatch
    rejected = true
  end
  w111_require(rejected, "#{label}: seeded one-byte drift was accepted")
end

def w111_read_u64(bytes : String) : UInt64
  w111_require(bytes.bytesize == 8, "expected 8-byte literal size record")
  8.times.reduce(0_u64) { |value, i| value | (bytes.to_slice[i].to_u64 << (8 * i)) }
end

def w111_seeded_root_size(actual : String, expected : String, label : String) : Nil
  w111_assert_bytes(actual, expected, label)
  w111_require(expected.bytesize == W111_KEYS.size * 8, "root size0 expected one UInt64 per outer row")
  values = Array(UInt64).new(W111_KEYS.size) { |i| w111_read_u64(expected[i * 8, 8]) }
  values[0] = 1_u64
  altered = values.map { |value| w111_u64(value) }.join
  w111_require(altered.bytesize == expected.bytesize, "seeded root size mutation changed length")
  rejected = false
  begin
    w111_assert_bytes(actual, altered, "#{label} seeded root-size drift")
  rescue ex : W111Mismatch
    rejected = true
  end
  w111_require(rejected, "root size comparator accepted a same-width nonempty mutation")
end

def w111_validate_pk_counter(record : Hash(String, JSON::Any), defaults : Int32, label : String) : Nil
  keys = ["kind", "name", "num_defaults", "num_rows"].sort
  w111_fail("#{label}: PK metadata keys differ: #{record.keys.sort.inspect}") unless record.keys.sort == keys
  w111_fail("#{label}: PK kind differs") unless record["kind"]?.try(&.as_s) == "Default"
  w111_fail("#{label}: PK name differs") unless record["name"]?.try(&.as_s) == "pk"
  w111_fail("#{label}: PK rows differ") unless record["num_rows"]?.try(&.as_i) == W111_KEYS.size.to_i64
  w111_fail("#{label}: PK defaults differ") unless record["num_defaults"]?.try(&.as_i) == defaults.to_i64
end

def w111_assert_serialization(part : String, profile : W111Profile, label : String) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  envelope = ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"].sort
  w111_fail("#{label}: metadata envelope differs") unless info.keys.sort == envelope
  w111_fail("#{label}: metadata version differs") unless info["version"]?.try(&.as_i) == 1_i64
  w111_fail("#{label}: nested version propagation differs") unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: type versions missing"
  w111_fail("#{label}: exact String version map differs") unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1_i64
  records = info["columns"]?.try(&.as_a) || raise "#{label}: columns metadata missing"
  expected_names = profile.ratio == "1.0" ? [] of String : ["pk"]
  actual_names = records.map { |record| record.as_h["name"]?.try(&.as_s) || raise "#{label}: named metadata record missing" }
  w111_fail("#{label}: exact empty-payload metadata policy differs: #{actual_names.inspect}") unless actual_names == expected_names
  if profile.ratio == "0.9375"
    w111_validate_pk_counter(records[0].as_h, 2, "#{label} PK")
    rejected = false
    begin
      w111_validate_pk_counter(records[0].as_h, 3, "#{label} seeded counter")
    rescue ex : W111Mismatch
      rejected = true
    end
    w111_require(rejected, "metadata comparator accepted seeded PK-counter drift")
  else
    w111_require(records.empty?, "ratio 1.0 must have an exact empty statistics array")
  end
end

def w111_raw(part : String, name : String) : String
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(name)}.bin")).to_slice
  return "" if encoded.empty?
  String.new(CrystalClick::CompressedBlock.decode_all(encoded))
end

def w111_assert_layout(part : String, profile : W111Profile, label : String) : Nil
  streams = w111_streams(profile)
  columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  w111_fail("#{label}: exact nominal columns differ: #{columns.inspect}") unless columns == w111_expected_columns(profile)
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  expected_substreams = w111_expected_substreams(streams)
  w111_fail("#{label}: physical stream tree differs:\nexpected:\n#{expected_substreams}actual:\n#{actual_substreams}") unless actual_substreams == expected_substreams
  w111_require(File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)", "#{label}: codec differs")
  w111_require(File.read(File.join(part, "metadata_version.txt")) == "0", "#{label}: metadata version differs")
  w111_require(File.read(File.join(part, "count.txt")) == W111_KEYS.size.to_s, "#{label}: outer count differs")

  expected_files = ["checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt", "default_compression_codec.txt", "metadata_version.txt", "primary.idx", "serialization.json"]
  streams.each do |stream|
    hash = CrystalClick::StreamName.hash(stream.name)
    expected_files << "#{hash}.bin" << "#{hash}.mrk2"
  end
  actual_files = Dir.children(part).sort
  w111_fail("#{label}: exact file inventory differs (missing=#{(expected_files - actual_files).sort.inspect}, extra=#{(actual_files - expected_files).sort.inspect})") unless actual_files == expected_files.sort
  checksums = CrystalClick::PartChecksums.open(part)
  checksum_files = expected_files - ["checksums.txt", "columns.txt", "columns_substreams.txt", "default_compression_codec.txt", "metadata_version.txt"]
  w111_require(checksums.entries.keys.sort == checksum_files.sort, "#{label}: checksum inventory differs")
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }

  primary_expected = W111_BOUNDARIES[0, W111_BOUNDARIES.size - 1].map { |boundary| w111_u64(W111_KEYS[boundary]) }.join + w111_u64(W111_KEYS.last)
  w111_seeded_byte(File.read(File.join(part, "primary.idx")), primary_expected, "#{label} literal plain primary.idx")
  streams.each do |stream|
    expected = stream.raw
    actual = w111_raw(part, stream.name)
    if expected.empty?
      w111_require(actual.empty?, "#{label} #{stream.name}: expected exactly zero raw bytes")
    elsif stream.name == "payload.size0"
      w111_seeded_root_size(actual, expected, "#{label} literal root size0")
    else
      w111_assert_bytes(actual, expected, "#{label} #{stream.name} literal raw bytes")
    end
    actual_marks = w111_marks(part, stream.name)
    expected_marks = w111_expected_marks(stream)
    w111_fail("#{label} #{stream.name}: exact marks differ; expected #{expected_marks.inspect}, got #{actual_marks.inspect}") unless actual_marks == expected_marks
  end
  w111_assert_serialization(part, profile, label)
  puts "PASS #{label}: exact schema, all #{profile.depth} size lanes, zero Point lanes, marks, checksums and statistics"
end

def w111_run(binary : String, store : String, query : String, input : IO? = nil) : String
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = if input
             Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: stdout, error: stderr)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: stdout, error: stderr)
           end
  raise "ClickHouse query failed: #{stderr}\n#{query}" unless status.success?
  stdout.to_s
end

def w111_settings(profile : W111Profile) : String
  "#{W111_SETTINGS}, ratio_of_defaults_for_sparse_serialization = #{profile.ratio}"
end

def w111_create(binary : String, store : String, table : String, profile : W111Profile) : Nil
  w111_run(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{profile.type_name}) ENGINE = MergeTree ORDER BY pk SETTINGS #{w111_settings(profile)}")
  nil
end

def w111_part_path(binary : String, store : String, table : String) : String
  rows = w111_run(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  w111_require(rows.size == 1, "#{table}: expected one active part, got #{rows.inspect}")
  fields = rows[0].split('\t')
  w111_require(fields.size == 3 && fields[1] == "Wide" && fields[2] == W111_KEYS.size.to_s, "#{table}: not one nine-row Wide part: #{rows[0].inspect}")
  fields[0]
end

def w111_schema(binary : String, store : String, table : String, profile : W111Profile) : Nil
  actual = w111_run(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  expected = ["pk UInt64", "payload #{profile.type_name}"]
  w111_fail("#{table}: exact system.columns declaration differs: #{actual.inspect}") unless actual == expected
end

def w111_check(binary : String, store : String, table : String, part : String) : Nil
  actual = w111_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  w111_require(actual == expected, "#{table}: CHECK must equal exact part name + tab + 1; got #{actual.inspect}")
  puts "PASS #{table}: CHECK=1"
end

def w111_rowbinary(indexes : Array(Int32)) : String
  String.build do |io|
    indexes.each do |index|
      io << w111_u64(W111_KEYS[index])
      io << w111_varuint(0_u64)
    end
  end
end

def w111_rowbinary_checks(binary : String, store : String, table : String, label : String) : Nil
  full_indexes = (0...W111_KEYS.size).map(&.to_i32)
  actual_full = w111_run(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w111_assert_bytes(actual_full, w111_rowbinary(full_indexes), "#{label} full literal RowBinary")
  selected_indexes = W111_KEYS.each_with_index.select { |key, _index| key >= 2_u64 && key < 8_u64 }.map { |_key, index| index.to_i32 }.to_a
  actual_selected = w111_run(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 8 ORDER BY pk FORMAT RowBinary")
  w111_assert_bytes(actual_selected, w111_rowbinary(selected_indexes), "#{label} nonzero selected literal RowBinary")
  puts "PASS #{label}: full and six-row selected RowBinary"
end

def w111_insert(binary : String, store : String, table : String) : Nil
  indexes = (0...W111_KEYS.size).map(&.to_i32)
  input = IO::Memory.new(w111_rowbinary(indexes).to_slice)
  w111_run(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  nil
end

def w111_attach(binary : String, store : String, table : String, profile : W111Profile, source_part : String) : String
  w111_create(binary, store, table, profile)
  data_path = w111_run(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  w111_require(!data_path.empty?, "#{table}: ATTACH destination data path missing")
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(source_part, File.join(detached, "all_1_1_0"))
  w111_run(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w111_part_path(binary, store, table)
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["W111_EMPTY_STORE"]? || raise "set W111_EMPTY_STORE to a fresh temporary store"
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary W111 store path: #{store}"
end
if Dir.exists?(store)
  raise "W111 store must be fresh and empty: #{store}" unless Dir.empty?(store)
else
  Dir.mkdir_p(store)
end

version_output = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version_output)
raise "could not inspect ClickHouse version" unless version_status.success?
expected_version = "ClickHouse local version #{W111_VERSION} (official build)."
raise "W111 requires #{expected_version}, got #{version_output.to_s.strip}" unless version_output.to_s.strip == expected_version
puts "W111 stock-only all-empty qualification: #{version_output.to_s.strip}"
puts "The qualification path has no Geo typed API reference."

W111_TYPES.each do |type_name, depth|
  {"0.9375", "1.0"}.each do |ratio|
    profile = W111Profile.new(type_name, depth, ratio)
    tag = "#{type_name.downcase}_#{profile.suffix}"
    source = "w111_empty_source_#{tag}"
    attached = "w111_empty_attached_#{tag}"
    w111_create(binary, store, source, profile)
    w111_insert(binary, store, source)
    source_part = w111_part_path(binary, store, source)
    w111_schema(binary, store, source, profile)
    w111_assert_layout(source_part, profile, "W111 #{profile.label} source")
    w111_check(binary, store, source, source_part)
    w111_rowbinary_checks(binary, store, source, "W111 #{profile.label} source")

    attached_part = w111_attach(binary, store, attached, profile, source_part)
    w111_schema(binary, store, attached, profile)
    w111_assert_layout(attached_part, profile, "W111 #{profile.label} fresh ATTACH")
    w111_check(binary, store, attached, attached_part)
    w111_rowbinary_checks(binary, store, attached, "W111 #{profile.label} fresh ATTACH")
  end
end

puts "PASS W111 qualify-empty: five nominal Geo Arrays x two statistics settings; source and fresh ATTACH verified with exact raw layout, CHECK=1 and full/selected RowBinary."
