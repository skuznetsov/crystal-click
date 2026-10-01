# W112 stock-first certificate for nominal MultiPoint under ClickHouse
# 26.10.1.1201. All physical and RowBinary expectations are independently
# encoded from the literal key/array/IEEE fixtures below. This probe does not
# substitute Array(Point) for the nominal MultiPoint declaration.
require "json"
require "file_utils"
require "../src/crystal_click"

W112_VERSION    = "26.10.1.1201"
W112_BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W112_TYPE       = "MultiPoint"
W112_LINE_TYPE  = "LineString"
W112_SETTINGS   = "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"
W112_MARK_BYTES = 24

class W112Mismatch < Exception
end

struct W112Profile
  getter name : String
  getter type_name : String
  getter keys : Array(UInt64)
  getter row_sizes : Array(UInt64)
  getter x_bits : Array(UInt64)
  getter y_bits : Array(UInt64)
  getter boundaries : Array(Int32)
  getter mark_rows : Array(UInt64)
  getter selected_min : UInt64
  getter selected_max : UInt64
  getter ratio : String

  def initialize(
    @name : String,
    @type_name : String,
    @keys : Array(UInt64),
    @row_sizes : Array(UInt64),
    @x_bits : Array(UInt64),
    @y_bits : Array(UInt64),
    @boundaries : Array(Int32),
    @mark_rows : Array(UInt64),
    @selected_min : UInt64,
    @selected_max : UInt64,
    @ratio : String,
  )
  end

  def settings : String
    "#{W112_SETTINGS}, ratio_of_defaults_for_sparse_serialization = #{ratio}"
  end

  def no_statistics? : Bool
    ratio == "1.0"
  end
end

# Nine literal rows preserve tied zero-key rows, a nonempty prefix before the
# selected PK window, three empty outer arrays, and a nonempty excluded suffix.
# Point tuples are represented by raw X/Y IEEE-754 words, not Float arithmetic.
W112_MIXED = W112Profile.new(
  "mixed9", W112_TYPE,
  [0_u64, 0_u64, 2_u64, 3_u64, 4_u64, 4_u64, 5_u64, 7_u64, 9_u64],
  [1_u64, 1_u64, 2_u64, 0_u64, 0_u64, 0_u64, 1_u64, 1_u64, 1_u64],
  [
    0x8000_0000_0000_0000_u64, 0x8000_0000_0000_0000_u64,
    0x8000_0000_0000_0000_u64, 0x7ff8_0000_0000_1234_u64,
    0xfff0_0000_0000_0000_u64, 0x4002_0000_0000_0000_u64,
    0x7ff8_0000_0000_1234_u64,
  ],
  [
    0_u64, 0_u64, 0_u64, 0x400c_0000_0000_0000_u64,
    0x0000_0000_0000_0001_u64, 0x7ff8_0000_0000_5678_u64,
    0x400c_0000_0000_0000_u64,
  ],
  [0, 2, 4, 6, 8, 9],
  [2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64],
  2_u64, 8_u64, "0.9375"
)

# A small independent profile matches the separately observed 26.10 metadata
# witness: one default PK row and one MultiPoint containing (1.0, 2.0).
W112_TWO_ROW = W112Profile.new(
  "two_row", W112_TYPE,
  [0_u64, 1_u64], [0_u64, 1_u64],
  [0x3ff0_0000_0000_0000_u64], [0x4000_0000_0000_0000_u64],
  [0, 2], [2_u64, 0_u64],
  1_u64, 2_u64, "0.9375"
)

# Empty coordinates do not imply omitted statistics under the ordinary
# sparse-serialization threshold; this separately checks a PK-only exact
# Default record with no Point coordinate lanes.
W112_ALL_EMPTY_SPARSE = W112Profile.new(
  "all_empty_sparse", W112_TYPE,
  [0_u64, 1_u64], [0_u64, 0_u64], [] of UInt64, [] of UInt64,
  [0, 2], [2_u64, 0_u64],
  1_u64, 2_u64, "0.9375"
)

# Ratio 1.0 is a distinct stock profile: serialization.json must contain an
# exact empty columns array even though statistics.packed remains in the part.
W112_ALL_EMPTY = W112Profile.new(
  "all_empty_ratio_one", W112_TYPE,
  [0_u64, 1_u64], [0_u64, 0_u64], [] of UInt64, [] of UInt64,
  [0, 2], [2_u64, 0_u64],
  1_u64, 2_u64, "1.0"
)

# Same physical fixture as TWO_ROW but with an already admitted nominal Geo
# type. This separates the new serializer-field RED from MultiPoint type
# admission; both checks happen only after every source/ATTACH certificate.
W112_GEO_METADATA_CONTROL = W112Profile.new(
  "line_string_metadata_control", W112_LINE_TYPE,
  W112_TWO_ROW.keys, W112_TWO_ROW.row_sizes,
  W112_TWO_ROW.x_bits, W112_TWO_ROW.y_bits,
  W112_TWO_ROW.boundaries, W112_TWO_ROW.mark_rows,
  W112_TWO_ROW.selected_min, W112_TWO_ROW.selected_max, W112_TWO_ROW.ratio
)

W112_PROFILES = [W112_MIXED, W112_TWO_ROW, W112_ALL_EMPTY_SPARSE, W112_ALL_EMPTY, W112_GEO_METADATA_CONTROL]

struct W112Stream
  getter name : String
  getter row_fragments : Array(Array(String))

  def initialize(@name : String, @row_fragments : Array(Array(String)))
  end

  def raw : String
    row_fragments.flat_map { |fragments| fragments }.join
  end
end

def w112_fail(message : String) : NoReturn
  raise W112Mismatch.new(message)
end

def w112_require(condition : Bool, message : String) : Nil
  w112_fail(message) unless condition
end

def w112_u64(value : UInt64) : String
  String.build do |io|
    8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
  end
end

def w112_varuint(value : UInt64) : String
  String.build do |io|
    rest = value
    while rest >= 0x80_u64
      io.write_byte(((rest & 0x7f_u64) | 0x80_u64).to_u8)
      rest >>= 7
    end
    io.write_byte(rest.to_u8)
  end
end

def w112_streams(profile : W112Profile) : Array(W112Stream)
  w112_require(profile.keys.size == profile.row_sizes.size, "#{profile.name}: PK and size0 row counts differ")
  x_rows = [] of Array(String)
  y_rows = [] of Array(String)
  point_index = 0
  profile.row_sizes.each_with_index do |count, row|
    w112_require(count <= Int32::MAX.to_u64, "#{profile.name}: point count exceeds fixture bound at row #{row}")
    xs = [] of String
    ys = [] of String
    count.to_i.times do
      w112_require(point_index < profile.x_bits.size && point_index < profile.y_bits.size, "#{profile.name}: size0 exceeds literal point lanes")
      xs << w112_u64(profile.x_bits[point_index])
      ys << w112_u64(profile.y_bits[point_index])
      point_index += 1
    end
    x_rows << xs
    y_rows << ys
  end
  w112_require(point_index == profile.x_bits.size && point_index == profile.y_bits.size, "#{profile.name}: literal point lanes contain unreferenced trailing coordinates")
  [
    W112Stream.new("pk", profile.keys.map { |key| [w112_u64(key)] }),
    W112Stream.new("payload.size0", profile.row_sizes.map { |size| [w112_u64(size)] }),
    W112Stream.new("payload%2E1", x_rows),
    W112Stream.new("payload%2E2", y_rows),
  ]
end

def w112_expected_columns(profile : W112Profile) : Array(String)
  ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{profile.type_name}"]
end

def w112_expected_substreams(streams : Array(W112Stream)) : String
  payload = streams.reject { |stream| stream.name == "pk" }
  w112_require(streams.count { |stream| stream.name == "pk" } == 1, "expected one PK stream")
  lines = [
    "columns substreams version: 1", "2 columns:",
    "1 substreams for column `pk`:", "\tpk",
    "#{payload.size} substreams for column `payload`:",
  ]
  payload.each { |stream| lines << "\t#{stream.name}" }
  lines.join("\n") + "\n"
end

def w112_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  index = 0
  while index < limit && actual.to_slice[index] == expected.to_slice[index]
    index += 1
  end
  got = index < actual.bytesize ? actual.to_slice[index].to_s(16).rjust(2, '0') : "<eof>"
  wanted = index < expected.bytesize ? expected.to_slice[index].to_s(16).rjust(2, '0') : "<eof>"
  raise W112Mismatch.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first diff #{index}: expected #{wanted}, got #{got}")
end

def w112_seeded_bytes(actual : String, expected : String, label : String) : Nil
  w112_assert_bytes(actual, expected, label)
  w112_require(!expected.empty?, "#{label}: cannot seed a mutation from empty bytes")
  altered = String.new(expected.to_slice)
  altered.to_unsafe[0] = altered.to_slice[0] ^ 0x01_u8
  rejected = false
  begin
    w112_assert_bytes(actual, altered, label)
  rescue ex : W112Mismatch
    rejected = true
  end
  w112_require(rejected, "#{label}: seeded one-byte expectation drift was accepted")
end

def w112_marks(part : String, name : String) : Array({UInt64, UInt64, UInt64})
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(name)}.mrk2")).to_slice
  w112_require(bytes.size % W112_MARK_BYTES == 0, "#{name}: partial literal 24-byte mark record")
  Array({UInt64, UInt64, UInt64}).new(bytes.size // W112_MARK_BYTES) do |record|
    start = record * W112_MARK_BYTES
    fields = Array(UInt64).new(3) do |field|
      at = start + field * 8
      8.times.reduce(0_u64) { |value, byte| value | (bytes[at + byte].to_u64 << (byte * 8)) }
    end
    {fields[0], fields[1], fields[2]}
  end
end

def w112_expected_marks(profile : W112Profile, stream : W112Stream) : Array({UInt64, UInt64, UInt64})
  w112_require(profile.boundaries.size == profile.mark_rows.size, "#{profile.name}: mark fixture vectors differ in length")
  profile.boundaries.map_with_index do |boundary, mark|
    decompressed = 0_u64
    stream.row_fragments[0, boundary].each { |row| row.each { |fragment| decompressed += fragment.bytesize.to_u64 } }
    {0_u64, decompressed, profile.mark_rows[mark]}
  end.to_a
end

def w112_read_raw(part : String, stream : String) : String
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  return "" if encoded.empty?
  String.new(CrystalClick::CompressedBlock.decode_all(encoded))
end

def w112_u64_from_le(bytes : String) : UInt64
  w112_require(bytes.bytesize == 8, "expected literal 8-byte UInt64 fragment")
  8.times.reduce(0_u64) { |value, index| value | (bytes.to_slice[index].to_u64 << (index * 8)) }
end

def w112_seeded_size_topology(actual : String, profile : W112Profile, label : String) : Nil
  expected = profile.row_sizes.map { |size| w112_u64(size) }.join
  w112_assert_bytes(actual, expected, "#{label} literal size0")
  return unless profile.name == "mixed9"

  # This is a same-width expected-oracle mutation, not a malformed-part test:
  # transfer one count from populated row 2 to empty row 3, retaining the sum.
  altered_sizes = profile.row_sizes.dup
  w112_require(altered_sizes[2] == 2_u64 && altered_sizes[3] == 0_u64, "#{label}: topology donor/receiver fixture changed")
  altered_sizes[2] -= 1_u64
  altered_sizes[3] += 1_u64
  w112_require(altered_sizes.sum == profile.row_sizes.sum, "#{label}: seeded topology mutation changed total element count")
  altered = altered_sizes.map { |size| w112_u64(size) }.join
  w112_require(altered.bytesize == expected.bytesize, "#{label}: seeded topology mutation changed stream width")
  rejected = false
  begin
    w112_assert_bytes(actual, altered, "#{label} seeded size0 topology")
  rescue ex : W112Mismatch
    rejected = true
  end
  w112_require(rejected, "#{label}: same-width size0 topology drift was accepted")
end

def w112_validate_pk_record(record : Hash(String, JSON::Any), defaults : Int32, rows : Int32, exact : Bool, label : String) : Nil
  wanted_keys = ["exact_num_defaults", "kind", "name", "num_defaults", "num_rows"].sort
  w112_fail("#{label}: exact PK record keys differ: #{record.keys.sort.inspect}") unless record.keys.sort == wanted_keys
  w112_fail("#{label}: PK kind differs") unless record["kind"]?.try(&.as_s) == "Default"
  w112_fail("#{label}: PK name differs") unless record["name"]?.try(&.as_s) == "pk"
  w112_fail("#{label}: PK row count differs") unless record["num_rows"]?.try(&.as_i) == rows.to_i64
  w112_fail("#{label}: PK default count differs") unless record["num_defaults"]?.try(&.as_i) == defaults.to_i64
  w112_fail("#{label}: exact_num_defaults differs") unless record["exact_num_defaults"]?.try(&.as_bool) == exact
end

def w112_validate_writer_pk_record(record : Hash(String, JSON::Any), defaults : Int32, rows : Int32, label : String) : Nil
  wanted_keys = ["kind", "name", "num_defaults", "num_rows"].sort
  w112_fail("#{label}: exact producer PK record keys differ: #{record.keys.sort.inspect}") unless record.keys.sort == wanted_keys
  w112_fail("#{label}: producer PK kind differs") unless record["kind"]?.try(&.as_s) == "Default"
  w112_fail("#{label}: producer PK name differs") unless record["name"]?.try(&.as_s) == "pk"
  w112_fail("#{label}: producer PK row count differs") unless record["num_rows"]?.try(&.as_i) == rows.to_i64
  w112_fail("#{label}: producer PK default count differs") unless record["num_defaults"]?.try(&.as_i) == defaults.to_i64
end

def w112_assert_serialization(part : String, profile : W112Profile, label : String, writer_profile : Bool = false) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  expected_envelope = ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"].sort
  w112_fail("#{label}: exact serialization envelope differs: #{info.keys.sort.inspect}") unless info.keys.sort == expected_envelope
  w112_fail("#{label}: serialization version differs") unless info["version"]?.try(&.as_i) == 1_i64
  w112_fail("#{label}: nested type-version propagation differs") unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: type-version map missing"
  w112_fail("#{label}: exact String version map differs") unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1_i64
  records = info["columns"]?.try(&.as_a) || raise "#{label}: column statistics array missing"

  if writer_profile
    # The Crystal Geo-array producer has a distinct, explicit contract: one
    # PK Default record, with no stock-generated exact_num_defaults key and no
    # Point/Array statistics. This remains true for ratio=1.0 input fixtures.
    w112_require(records.size == 1, "#{label}: producer must emit exactly one PK Default record")
    record = records[0].as_h
    defaults = profile.keys.count(0_u64).to_i32
    w112_validate_writer_pk_record(record, defaults, profile.keys.size.to_i32, "#{label} producer PK")
    rejected = false
    begin
      w112_validate_writer_pk_record(record, defaults + 1, profile.keys.size.to_i32, "#{label} seeded producer counter")
    rescue ex : W112Mismatch
      rejected = true
    end
    w112_require(rejected, "#{label}: producer metadata comparator accepted seeded PK default-counter drift")
  elsif profile.no_statistics?
    w112_require(records.empty?, "#{label}: ratio=1.0 must emit exactly columns=[]")
    rejected = false
    begin
      w112_require(records.size == 1, "#{label}: seeded unexpected PK statistics record")
    rescue ex : W112Mismatch
      rejected = true
    end
    w112_require(rejected, "#{label}: empty-statistics comparator accepted a seeded record")
  else
    w112_require(records.size == 1, "#{label}: expected only one PK Default record, got #{records.size}")
    record = records[0].as_h
    actual_name = record["name"]?.try(&.as_s) || raise "#{label}: PK metadata name missing"
    w112_require(actual_name == "pk", "#{label}: unexpected statistics root #{actual_name.inspect}")
    defaults = profile.keys.count(0_u64).to_i32
    w112_validate_pk_record(record, defaults, profile.keys.size.to_i32, true, "#{label} PK")

    # Ensure both the exactness field and its value participate in the strict
    # comparator; neither an omitted key nor an inexact counter may pass.
    rejected_counter = false
    begin
      w112_validate_pk_record(record, defaults + 1, profile.keys.size.to_i32, true, "#{label} seeded counter")
    rescue ex : W112Mismatch
      rejected_counter = true
    end
    w112_require(rejected_counter, "#{label}: seeded PK default-counter drift was accepted")
    rejected_flag = false
    begin
      w112_validate_pk_record(record, defaults, profile.keys.size.to_i32, false, "#{label} seeded exactness")
    rescue ex : W112Mismatch
      rejected_flag = true
    end
    w112_require(rejected_flag, "#{label}: seeded exact_num_defaults drift was accepted")
  end
end

def w112_assert_checksum_hashes(part : String, checksums : CrystalClick::PartChecksums, label : String, expect_statistics_packed : Bool = true) : Nil
  saw_packed_statistics = false
  checksums.entries.each do |name, entry|
    file_bytes = File.read(File.join(part, name))
    actual_hash = CrystalClick::CityHashV1.file_hash(file_bytes.to_slice)
    w112_require(actual_hash == entry.file_hash, "#{label} #{name}: content hash differs from checksums.txt")

    next unless name == "statistics.packed"
    saw_packed_statistics = true
    w112_require(!file_bytes.empty?, "#{label}: expected observed nonempty statistics.packed witness")
    seeded = String.new(file_bytes.to_slice)
    seeded.to_unsafe[0] = seeded.to_slice[0] ^ 0x01_u8
    w112_require(seeded.bytesize == file_bytes.bytesize, "#{label}: seeded ancillary mutation changed file length")
    w112_require(CrystalClick::CityHashV1.file_hash(seeded.to_slice) != entry.file_hash, "#{label}: same-length statistics.packed drift matched the recorded file hash")
  end
  w112_require(saw_packed_statistics == expect_statistics_packed, "#{label}: statistics.packed presence differs from the exact producer/stock profile")
end

def w112_assert_invalidated_system_columns(part : String, label : String) : Nil
  path = File.join(part, "invalidated_system_columns.txt")
  contents = File.read(path)
  w112_require(
    contents == "_block_number\n_block_offset\n" || contents == "_block_offset\n_block_number\n",
    "#{label}: invalidated_system_columns.txt must contain exactly _block_number and _block_offset, one escaped line each; got #{contents.inspect}",
  )
  nil
end

def w112_lz4_literal_frame_size(raw_size : Int32) : UInt64
  w112_require(raw_size > 0, "writer mark fixture must omit empty frames")
  extensions = raw_size < 15 ? 0 : ((raw_size - 15) // 255) + 1
  # Independently derived literal-only ClickHouse frame: checksum + LZ4
  # header + token + raw bytes + literal-length extensions.
  (26 + raw_size + extensions).to_u64
end

def w112_expected_writer_marks(profile : W112Profile, stream : W112Stream) : Array({UInt64, UInt64, UInt64})
  result = [] of {UInt64, UInt64, UInt64}
  compressed_offset = 0_u64
  data_marks = profile.boundaries.size - 1
  data_marks.times do |mark|
    first = profile.boundaries[mark]
    after = profile.boundaries[mark + 1]
    raw_size = stream.row_fragments[first, after - first].sum do |row|
      row.sum(&.bytesize)
    end
    result << {compressed_offset, 0_u64, profile.mark_rows[mark]}
    compressed_offset += w112_lz4_literal_frame_size(raw_size) unless raw_size == 0
  end
  result << {compressed_offset, 0_u64, 0_u64}
  result
end

def w112_assert_layout(
  part : String,
  profile : W112Profile,
  label : String,
  attached : Bool = false,
  writer_profile : Bool = false,
) : Nil
  streams = w112_streams(profile)
  actual_columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  w112_fail("#{label}: exact nominal declaration differs: #{actual_columns.inspect}") unless actual_columns == w112_expected_columns(profile)
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  expected_substreams = w112_expected_substreams(streams)
  w112_fail("#{label}: exact substream inventory/order differs:\nexpected:\n#{expected_substreams}actual:\n#{actual_substreams}") unless actual_substreams == expected_substreams
  w112_require(File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)", "#{label}: default codec differs")
  w112_require(File.read(File.join(part, "metadata_version.txt")) == "0", "#{label}: metadata version differs")
  w112_require(File.read(File.join(part, "count.txt")) == profile.keys.size.to_s, "#{label}: outer row count differs")

  expected_files = [
    "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
    "default_compression_codec.txt", "metadata_version.txt", "primary.idx",
    "serialization.json",
  ]
  expected_files << "statistics.packed" unless writer_profile
  # Loading/attaching a non-patch part persists the exact virtual columns whose
  # stored values must be ignored. This sidecar is not part of checksums.txt.
  if attached
    expected_files << "invalidated_system_columns.txt"
    w112_assert_invalidated_system_columns(part, label)
  end
  streams.each do |stream|
    hashed = CrystalClick::StreamName.hash(stream.name)
    expected_files << "#{hashed}.bin" << "#{hashed}.mrk2"
  end
  actual_files = Dir.children(part).sort
  w112_fail("#{label}: exact part inventory differs (missing=#{(expected_files - actual_files).sort.inspect}, extra=#{(actual_files - expected_files).sort.inspect})") unless actual_files == expected_files.sort

  checksums = CrystalClick::PartChecksums.open(part)
  checksum_files = expected_files - [
    "checksums.txt", "columns.txt", "columns_substreams.txt", "default_compression_codec.txt",
    "metadata_version.txt", "invalidated_system_columns.txt",
  ]
  w112_require(checksums.entries.keys.sort == checksum_files.sort, "#{label}: exact checksum inventory differs")
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }
  w112_assert_checksum_hashes(part, checksums, label, expect_statistics_packed: !writer_profile)

  # With plain primary.idx, retain the key at each data-mark start and the
  # terminal key. Mark width is the literal three-UInt64/24-byte W112 record.
  data_boundaries = profile.boundaries[0, profile.boundaries.size - 1]
  primary_expected = data_boundaries.map { |row| w112_u64(profile.keys[row]) }.join + w112_u64(profile.keys.last)
  primary_actual = File.read(File.join(part, "primary.idx"))
  w112_seeded_bytes(primary_actual, primary_expected, "#{label} literal plain primary.idx")

  streams.each do |stream|
    expected_raw = stream.raw
    actual_raw = w112_read_raw(part, stream.name)
    if expected_raw.empty?
      w112_require(actual_raw.empty?, "#{label} #{stream.name}: expected exactly empty raw stream")
      # Empty coordinate lanes have no byte to mutate; exact file inventory,
      # checksums and the literal 24-byte mark schedule still qualify them.
    elsif stream.name == "payload.size0"
      w112_seeded_size_topology(actual_raw, profile, "#{label} #{stream.name}")
      w112_seeded_bytes(actual_raw, expected_raw, "#{label} #{stream.name} byte comparator")
    else
      w112_seeded_bytes(actual_raw, expected_raw, "#{label} #{stream.name} raw bytes")
    end
    expected_marks = writer_profile ? w112_expected_writer_marks(profile, stream) : w112_expected_marks(profile, stream)
    actual_marks = w112_marks(part, stream.name)
    w112_fail("#{label} #{stream.name}: literal mark tuples differ; expected #{expected_marks.inspect}, got #{actual_marks.inspect}") unless actual_marks == expected_marks
  end
  w112_assert_serialization(part, profile, label, writer_profile)
  puts "PASS #{label}: exact schema, 3 payload streams, raw bytes, marks, plain PK, checksums and statistics"
end

def w112_run(binary : String, store : String, query : String, input : IO? = nil) : String
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

def w112_create(binary : String, store : String, table : String, profile : W112Profile) : Nil
  w112_run(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{profile.type_name}) ENGINE = MergeTree ORDER BY pk SETTINGS #{profile.settings}")
  nil
end

def w112_rowbinary(profile : W112Profile, indexes : Array(Int32)) : String
  String.build do |io|
    indexes.each do |index|
      io << w112_u64(profile.keys[index])
      count = profile.row_sizes[index]
      io << w112_varuint(count)
      start = 0_u64
      index.times { |before| start += profile.row_sizes[before] }
      count.to_i.times do |point|
        flat_index = (start + point).to_i
        io << w112_u64(profile.x_bits[flat_index])
        io << w112_u64(profile.y_bits[flat_index])
      end
    end
  end
end

def w112_part_path(binary : String, store : String, table : String, profile : W112Profile) : String
  rows = w112_run(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  w112_require(rows.size == 1, "#{table}: expected exactly one active part, got #{rows.inspect}")
  columns = rows[0].split('\t')
  w112_require(columns.size == 3 && columns[1] == "Wide" && columns[2] == profile.keys.size.to_s, "#{table}: not one expected Wide part: #{rows[0].inspect}")
  columns[0]
end

def w112_assert_schema(binary : String, store : String, table : String, profile : W112Profile) : Nil
  actual = w112_run(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  expected = ["pk UInt64", "payload #{profile.type_name}"]
  w112_fail("#{table}: exact system.columns identity differs: #{actual.inspect}") unless actual == expected
end

def w112_check(binary : String, store : String, table : String, part : String) : Nil
  actual = w112_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  w112_require(actual == expected, "#{table}: CHECK must be exact part name + tab + 1, got #{actual.inspect}")
  puts "PASS #{table}: CHECK=1"
end

def w112_rowbinary_checks(binary : String, store : String, table : String, profile : W112Profile, label : String) : Nil
  all = (0...profile.keys.size).map(&.to_i32)
  expected_full = w112_rowbinary(profile, all)
  actual_full = w112_run(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w112_assert_bytes(actual_full, expected_full, "#{label} independent full RowBinary")
  selected = profile.keys.each_with_index.select { |key, _index| key >= profile.selected_min && key < profile.selected_max }.map { |_key, index| index.to_i32 }.to_a
  expected_selected = w112_rowbinary(profile, selected)
  actual_selected = w112_run(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= #{profile.selected_min} AND pk < #{profile.selected_max} ORDER BY pk FORMAT RowBinary")
  w112_assert_bytes(actual_selected, expected_selected, "#{label} independent selected RowBinary")
  puts "PASS #{label}: full and nonzero-PK-selected RowBinary"
end

def w112_insert(binary : String, store : String, table : String, profile : W112Profile) : Nil
  indexes = (0...profile.keys.size).map(&.to_i32)
  input = IO::Memory.new(w112_rowbinary(profile, indexes).to_slice)
  w112_run(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  nil
end

def w112_attach(binary : String, store : String, table : String, profile : W112Profile, source_part : String) : String
  w112_create(binary, store, table, profile)
  data_path = w112_run(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  w112_require(!data_path.empty?, "#{table}: ATTACH destination path missing")
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(source_part, File.join(detached, "all_1_1_0"))
  w112_run(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w112_part_path(binary, store, table, profile)
end

def w112_qualify_profile(binary : String, store : String, profile : W112Profile) : {String, String}
  source_table = "w112_source_#{profile.name}"
  attached_table = "w112_attached_#{profile.name}"
  w112_create(binary, store, source_table, profile)
  w112_insert(binary, store, source_table, profile)
  source_part = w112_part_path(binary, store, source_table, profile)
  w112_assert_schema(binary, store, source_table, profile)
  w112_assert_layout(source_part, profile, "W112 #{profile.name} source")
  w112_check(binary, store, source_table, source_part)
  w112_rowbinary_checks(binary, store, source_table, profile, "W112 #{profile.name} source")

  attached_part = w112_attach(binary, store, attached_table, profile, source_part)
  w112_assert_schema(binary, store, attached_table, profile)
  w112_assert_layout(attached_part, profile, "W112 #{profile.name} fresh ATTACH", attached: true)
  w112_check(binary, store, attached_table, attached_part)
  w112_rowbinary_checks(binary, store, attached_table, profile, "W112 #{profile.name} fresh ATTACH")
  {source_part, attached_part}
end

def w112_expect_refusal(part : String, profile : W112Profile, expected_message : String) : Nil
  begin
    CrystalClick::WidePart.open_typed(part, "payload")
  rescue ex : CrystalClick::UnsupportedFormatError
    puts "OBSERVED #{profile.type_name} typed-open refusal: #{ex.message}"
    w112_require(ex.message == expected_message, "#{profile.type_name}: refusal differs from expected independent discriminator #{expected_message.inspect}")
    puts "EXPECTED RED #{profile.type_name}: #{ex.message}"
    return
  end
  raise "#{profile.type_name}: predecessor unexpectedly admitted the qualified typed column"
end

def w112_point_offset(profile : W112Profile, row_index : Int32) : Int32
  profile.row_sizes[0, row_index].sum.to_i32
end

def w112_assert_geo_row(row : CrystalClick::WideGeoArrayRow, profile : W112Profile, row_index : Int32, label : String) : Nil
  w112_require(row.type_name == profile.type_name, "#{label}: nominal row type differs")
  w112_require(row.level == 0, "#{label}: outer Geo row level differs")
  expected_size = profile.row_sizes[row_index].to_i32
  w112_require(row.size == expected_size, "#{label}: row #{row_index} size differs")
  point_offset = w112_point_offset(profile, row_index)
  expected_size.times do |point_index|
    actual = row.point_at(point_index)
    flat_index = point_offset + point_index
    w112_require(actual.x_bits == profile.x_bits[flat_index], "#{label}: row #{row_index} point #{point_index} X bits differ")
    w112_require(actual.y_bits == profile.y_bits[flat_index], "#{label}: row #{row_index} point #{point_index} Y bits differ")
  end
end

def w112_assert_geo_data(
  data : CrystalClick::WideGeoArrayColumnData,
  profile : W112Profile,
  first_row : Int32,
  row_count : Int32,
  label : String,
) : Nil
  expected_sizes = profile.row_sizes[first_row, row_count]
  w112_require(data.type_name == profile.type_name, "#{label}: exact nominal Geo type differs")
  w112_require(data.row_count == row_count, "#{label}: outer row count differs")
  w112_require(data.topology.level_count == 1, "#{label}: Geo Array nesting depth differs")
  w112_require(data.topology.sizes(0) == expected_sizes, "#{label}: literal size0 topology differs")
  expected_points = expected_sizes.sum.to_i32
  w112_require(data.point_count == expected_points, "#{label}: flattened Point count differs")
  first_point = w112_point_offset(profile, first_row)
  expected_points.times do |index|
    actual = data.point_at(index)
    flat_index = first_point + index
    w112_require(actual.x_bits == profile.x_bits[flat_index], "#{label}: flattened Point #{index} X bits differ")
    w112_require(actual.y_bits == profile.y_bits[flat_index], "#{label}: flattened Point #{index} Y bits differ")
  end
  row_count.times do |local_row|
    w112_assert_geo_row(data.row(local_row), profile, first_row + local_row, "#{label} row #{local_row}")
  end
end

def w112_assert_direct_geo_reader(part : String, profile : W112Profile, label : String) : Nil
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  w112_require(reader.column_type == profile.type_name, "#{label}: exact physical declaration differs")
  mark_count = profile.boundaries.size - 1
  w112_require(reader.mark_count == mark_count, "#{label}: data mark count differs")
  full = reader.read_geo_array_mark_range("payload", 0, mark_count)
  w112_assert_geo_data(full, profile, 0, profile.keys.size.to_i32, "#{label} full range")

  # Mark 2 begins after four literal outer rows and four points, so this
  # selection distinguishes flattened-element origin from an accidentally
  # mark-local zero origin. Small profiles still exercise an explicit range.
  if profile.name == "mixed9"
    first_mark = 2
    first_row = profile.boundaries[first_mark]
    after_row = profile.boundaries[first_mark + 2]
    selected = reader.read_geo_array_mark_range("payload", first_mark, 2)
    w112_assert_geo_data(selected, profile, first_row, after_row - first_row, "#{label} nonzero-origin selected range")
  else
    selected = reader.read_geo_array_mark_range("payload", 0, 1)
    w112_assert_geo_data(selected, profile, 0, profile.boundaries[1], "#{label} first-mark range")
  end

  seen_marks = [] of Int32
  reader.each_geo_array_mark_range("payload", 0, mark_count) do |data, mark_index|
    w112_require(mark_index == seen_marks.size, "#{label}: lazy mark index order differs")
    first_row = profile.boundaries[mark_index]
    row_count = profile.boundaries[mark_index + 1] - first_row
    w112_assert_geo_data(data, profile, first_row, row_count, "#{label} lazy mark #{mark_index}")
    seen_marks << mark_index
    nil
  end
  w112_require(seen_marks == (0...mark_count).map(&.to_i32).to_a, "#{label}: lazy mark coverage differs")
  puts "PASS #{label}: typed full/range/lazy read, nominal type and independent IEEE/topology"
end

def w112_expected_candidate_marks(profile : W112Profile) : Array(Int32)
  # Literal PK fence expectations for the fixed fixtures: mixed9 selects the
  # four granules whose start keys are 0,2,4,5; the final granule starts at 9.
  profile.name == "mixed9" ? [0_i32, 1_i32, 2_i32, 3_i32] : [0_i32]
end

def w112_assert_table_consumers(part : String, profile : W112Profile, label : String) : Nil
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
  w112_require(table.column_types == [{"pk", "UInt64"}, {"payload", profile.type_name}], "#{label}: table exact column identities differ")
  expected_mark_rows = profile.mark_rows[0, profile.mark_rows.size - 1]
  w112_require(table.part_mark_row_counts == [expected_mark_rows], "#{label}: table mark row schedule differs")

  next_row = 0_i32
  table.scan_typed(batch_rows: 2) do |batch|
    w112_require(batch.column_type_for("payload") == profile.type_name, "#{label}: full-scan batch nominal type differs")
    keys = batch.values_for("pk")
    rows = batch.geo_array_rows_for("payload")
    w112_require(keys.size == rows.size, "#{label}: full-scan key/Geo row counts differ")
    rows.each_with_index do |row, local_index|
      expected_index = next_row + local_index
      w112_require(keys[local_index] == profile.keys[expected_index], "#{label}: full-scan PK order differs")
      w112_assert_geo_row(row, profile, expected_index, "#{label} full-scan row")
    end
    next_row += rows.size.to_i32
    nil
  end
  w112_require(next_row == profile.keys.size, "#{label}: full scan omitted outer rows")

  window_start = profile.keys.size > 2 ? 2_i32 : 1_i32
  window_count = Math.min(3, profile.keys.size - window_start)
  window_next = window_start
  table.scan_typed_window(window_start.to_u64, window_count) do |batch|
    keys = batch.values_for("pk")
    rows = batch.geo_array_rows_for("payload")
    w112_require(keys.size == rows.size, "#{label}: window key/Geo row counts differ")
    rows.each_with_index do |row, local_index|
      expected_index = window_next + local_index
      w112_require(keys[local_index] == profile.keys[expected_index], "#{label}: window PK order differs")
      w112_assert_geo_row(row, profile, expected_index, "#{label} window row")
    end
    window_next += rows.size.to_i32
    nil
  end
  w112_require(window_next == window_start + window_count, "#{label}: bounded window row coverage differs")

  mark_count = table.part_mark_row_counts[0].size
  index = CrystalClick::PrimaryKeyIndex.open(part, mark_count, CrystalClick::PartChecksums.open(part), verify_recorded_hash: true)
  candidates = index.candidate_marks(profile.selected_min, profile.selected_max - 1_u64)
  expected_candidates = w112_expected_candidate_marks(profile)
  w112_require(candidates == expected_candidates, "#{label}: literal PK candidate marks differ: #{candidates.inspect}")
  candidate_rows = [] of Int32
  candidates.each do |mark|
    (profile.boundaries[mark]...profile.boundaries[mark + 1]).each { |row| candidate_rows << row }
  end
  candidate_offset = 0
  table.scan_typed_candidate_marks([candidates]) do |batch|
    keys = batch.values_for("pk")
    rows = batch.geo_array_rows_for("payload")
    w112_require(keys.size == rows.size, "#{label}: candidate key/Geo row counts differ")
    rows.each_with_index do |row, local_index|
      expected_index = candidate_rows[candidate_offset + local_index]
      w112_require(keys[local_index] == profile.keys[expected_index], "#{label}: candidate PK differs")
      w112_assert_geo_row(row, profile, expected_index, "#{label} candidate row")
    end
    candidate_offset += rows.size
    nil
  end
  w112_require(candidate_offset == candidate_rows.size, "#{label}: candidate scan row coverage differs")
  puts "PASS #{label}: table full/window/PK-candidate typed consumers"
end

def w112_run_reader_phase(qualified_parts : Hash(String, {String, String})) : Nil
  W112_PROFILES.each do |profile|
    source_part, attached_part = qualified_parts[profile.name]
    w112_assert_direct_geo_reader(source_part, profile, "W112 reader #{profile.name} source")
    w112_assert_direct_geo_reader(attached_part, profile, "W112 reader #{profile.name} fresh ATTACH")
    w112_assert_table_consumers(attached_part, profile, "W112 reader #{profile.name} table")
  end
  puts "PASS W112 reader GREEN: #{W112_PROFILES.size} source+ATTACH profiles; direct, lazy, table full/window/PK paths"
end

def w112_run_writer_phase(binary : String, store : String) : Nil
  writer_root = File.join(store, "w112-writer-parts")
  Dir.mkdir_p(writer_root)
  profiles = [W112_MIXED, W112_TWO_ROW, W112_ALL_EMPTY_SPARSE, W112_ALL_EMPTY]
  attached_parts = {} of String => String

  profiles.each do |profile|
    destination = File.join(writer_root, profile.name)
    points = Array(CrystalClick::WidePointValue).new(profile.x_bits.size) do |index|
      CrystalClick::WidePointValue.from_bits(profile.x_bits[index], profile.y_bits[index])
    end
    actual_path = CrystalClick::WidePartWriter.write_uint64_geo_array_pair(
      destination,
      "pk",
      profile.keys.to_unsafe.to_slice(profile.keys.size),
      "payload",
      profile.type_name,
      [profile.row_sizes],
      points,
      rows_per_mark: 2
    )
    w112_require(actual_path == destination, "W112 writer #{profile.name}: returned destination differs")
    w112_assert_layout(destination, profile, "W112 writer #{profile.name} producer", writer_profile: true)

    table = "w112_writer_#{profile.name}"
    attached_part = w112_attach(binary, store, table, profile, destination)
    w112_assert_schema(binary, store, table, profile)
    w112_assert_layout(attached_part, profile, "W112 writer #{profile.name} fresh ATTACH", attached: true, writer_profile: true)
    w112_check(binary, store, table, attached_part)
    w112_rowbinary_checks(binary, store, table, profile, "W112 writer #{profile.name} fresh ATTACH")
    attached_parts[profile.name] = attached_part
  end

  profiles.each do |profile|
    w112_assert_direct_geo_reader(attached_parts[profile.name], profile, "W112 writer #{profile.name} typed readback")
    w112_assert_table_consumers(attached_parts[profile.name], profile, "W112 writer #{profile.name} table readback")
  end
  puts "PASS W112 writer GREEN: #{profiles.size} MultiPoint writer profiles; producer inventory, fresh stock ATTACH/CHECK=1/RowBinary and typed readback"
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to the isolated, SHA-pinned ClickHouse 26.10 executable"
store = ENV["W112_STORE"]? || raise "set W112_STORE to a fresh temporary ClickHouse store"
mode = ARGV.size == 1 ? ARGV[0] : raise "usage: probe_multipoint_w112.cr qualify|red|reader|writer"
unless {"qualify", "red", "reader", "writer"}.includes?(mode)
  raise "unsupported W112 mode #{mode.inspect}"
end
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary W112 store path: #{store}"
end
if Dir.exists?(store)
  raise "W112 store must be fresh and empty: #{store}" unless Dir.empty?(store)
else
  Dir.mkdir_p(store)
end

version_output = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version_output)
raise "could not inspect ClickHouse version" unless version_status.success?
expected_version = "ClickHouse local version #{W112_VERSION} (official build)."
raise "W112 requires #{expected_version}, got #{version_output.to_s.strip}" unless version_output.to_s.strip == expected_version
build_options = w112_run(binary, store, "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
expected_build_options = ["GIT_HASH=#{W112_BUILD_HASH}", "VERSION_GITHASH=#{W112_BUILD_HASH}"]
w112_require(build_options == expected_build_options, "W112 binary build identity differs: #{build_options.inspect}")
puts "W112 stock certificate: #{version_output.to_s.strip}; build=#{W112_BUILD_HASH}; mode=#{mode}"

qualified_parts = {} of String => {String, String}
W112_PROFILES.each do |profile|
  qualified_parts[profile.name] = w112_qualify_profile(binary, store, profile)
end
puts "PASS W112 stock qualification: #{W112_PROFILES.size} profiles, source+fresh ATTACH exact physical/layout/metadata/CHECK=1/full+selected RowBinary"

if mode == "red"
  # Physical and RowBinary controls for every source/ATTACH profile complete
  # before these existing-reader admission failures are evaluated.
  w112_expect_refusal(qualified_parts["mixed9"][1], W112_MIXED, "unsupported exact typed column")
  w112_expect_refusal(qualified_parts["line_string_metadata_control"][1], W112_GEO_METADATA_CONTROL, "unsupported Geo Array primary-key serializer fields")
  puts "EXPECTED W112 RED: MultiPoint type admission and the new exact_num_defaults Geo metadata field remain distinct guards"
  exit 1
end

case mode
when "reader"
  w112_run_reader_phase(qualified_parts)
  puts "W112 reader mode exits 0 after stock and typed reader qualification"
when "writer"
  w112_run_writer_phase(binary, store)
  puts "W112 writer mode exits 0 after producer, stock ATTACH and typed readback qualification"
else
  puts "W112 qualify mode exits 0 after stock-only physical qualification"
end
