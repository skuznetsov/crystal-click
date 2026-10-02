# W128 whole-part oracle. Every positive part is constructed by the library
# from authored keys, schemas, plans and documents; ClickHouse only supplies an
# empty target table and independently checks the resulting detached part.
require "file_utils"
require "json"
require "../src/crystal_click"
require "./w115_json_semantic_vectors"
require "./w116_json_physical_vectors"
require "./w120_structure_vectors"
require "./w122_bulk_vectors"
require "./w123_object_vectors"

W128_VERSION           = "26.10.1.1201"
W128_BUILD_HASH        = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W128_EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W128_FRAME_BYTES       = 16
W128_LITERAL_FRAME     = 43
W128_SETTINGS          = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version_for_zero_level_parts='map'"
W128_SIDECARS          = [
  "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
  "default_compression_codec.txt", "metadata_version.txt", "primary.idx",
  "serialization.json",
]

alias W128Grid = Array(Tuple(UInt64, UInt64, UInt64))

struct W128ChecksumEntry
  getter physical_size : UInt64
  getter physical_hash : {UInt64, UInt64}
  getter compressed : Bool
  getter uncompressed_size : UInt64?
  getter uncompressed_hash : {UInt64, UInt64}?

  def initialize(
    @physical_size : UInt64,
    @physical_hash : {UInt64, UInt64},
    @compressed : Bool,
    @uncompressed_size : UInt64?,
    @uncompressed_hash : {UInt64, UInt64}?,
  )
  end
end

class W128Mismatch < Exception
end

def w128_fail(message : String) : NoReturn
  raise W128Mismatch.new(message)
end

def w128_require(condition : Bool, message : String) : Nil
  w128_fail(message) unless condition
end

def w128_run(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
  raise "ClickHouse local query failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w128_run_status(binary : String, arguments : Array(String)) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, arguments, output: output, error: error)
  raise "ClickHouse command failed: #{error}" unless status.success?
  output.to_s
end

def w128_verify_runtime(binary : String, store : String) : Nil
  version = w128_run_status(binary, ["local", "--version"]).strip
  w128_require(version == "ClickHouse local version #{W128_VERSION} (official build).",
    "unexpected ClickHouse version: #{version.inspect}")
  digest = w128_run_status("shasum", ["-a", "256", binary]).split(' ').first? || ""
  w128_require(digest == W128_EXECUTABLE_SHA256, "unexpected ClickHouse executable SHA-256")
  build = w128_run(binary, store,
    "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
  w128_require(build == ["GIT_HASH=#{W128_BUILD_HASH}", "VERSION_GITHASH=#{W128_BUILD_HASH}"],
    "unexpected ClickHouse build identity")
end

def w128_store_child(path : String, store : String, label : String) : String
  real_store = File.realpath(store)
  real_path = File.realpath(path)
  unless real_path.starts_with?(real_store + "/") && !File.symlink?(path)
    w128_fail("#{label}: path escapes isolated store or is a symlink")
  end
  relative = real_path[(real_store.size + 1)..]
  cursor = real_store
  relative.split('/').each do |component|
    cursor = File.join(cursor, component)
    w128_fail("#{label}: symlink in store path") if File.symlink?(cursor)
  end
  real_path
end

def w128_assert_tree(path : String, label : String) : Nil
  w128_require(Dir.exists?(path) && !File.symlink?(path), "#{label}: unsafe/missing directory")
  Dir.children(path).each do |name|
    child = File.join(path, name)
    w128_require(!File.symlink?(child), "#{label}: symlink child #{name.inspect}")
    if Dir.exists?(child)
      w128_assert_tree(child, "#{label}/#{name}")
    else
      w128_require(File.file?(child), "#{label}: non-file child #{name.inspect}")
    end
  end
end

def w128_table_data_path(binary : String, store : String, table : String) : String
  path = w128_run(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  w128_store_child(path, store, "#{table} data path")
end

def w128_create_empty_table(binary : String, store : String, table : String, schema : CrystalClick::ObjectDocumentSchema, declaration : String) : Nil
  w128_run(binary, store,
    "CREATE TABLE default.#{table} (pk UInt64, payload #{declaration}) ENGINE=MergeTree ORDER BY pk SETTINGS #{W128_SETTINGS}")
  actual = w128_run(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  expected = "pk UInt64\npayload #{declaration}\n"
  w128_require(actual == expected, "#{table}: empty target schema differs from the authored declaration")
  active = w128_run(binary, store,
    "SELECT count() FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").strip
  w128_require(active == "0", "#{table}: target table is not empty before library publication")
  # Keep the schema's library-rendered declaration aligned with this
  # independently authored DDL string without deriving one from the other.
  w128_require(schema.declaration == declaration, "#{table}: schema differs from the authored DDL declaration")
end

def w128_dynamic_paths(profile : String) : Array(String)
  W120StructureVectors.dynamic_paths(profile)
end

def w128_poisoned_plan(profile : String) : CrystalClick::ObjectDocumentPlan
  expected = W123ObjectVectors.plan(profile)
  object = expected.structures.object
  object_statistics = object.statistics || raise "W128 authored plan has no Object statistics"
  poisoned_object = CrystalClick::StructureStatistics.new(
    Array(UInt64).new(object_statistics.count_count, 99_u64),
    object_statistics.shared.map { |entry| CrystalClick::StructureStatistic.new(entry.name, 99_u64) }
  )
  poisoned_object_structure = CrystalClick::ObjectStructure.new(
    object.dynamic_paths,
    version: object.version,
    shared_data_version: object.shared_data_version,
    bucket_count: object.bucket_count,
    legacy_max_dynamic_paths: object.legacy_max_dynamic_paths,
    statistics: poisoned_object
  )
  dynamics = {} of String => CrystalClick::DynamicStructure
  expected.structures.dynamics.each do |path, dynamic|
    statistics = dynamic.statistics || raise "W128 authored plan has no Dynamic statistics at #{path.inspect}"
    poisoned = CrystalClick::StructureStatistics.new(
      Array(UInt64).new(statistics.count_count, 99_u64),
      statistics.shared.map { |entry| CrystalClick::StructureStatistic.new(entry.name, 99_u64) }
    )
    dynamics[String.new(path.to_slice)] = CrystalClick::DynamicStructure.new(dynamic.types, poisoned)
  end
  set = CrystalClick::ObjectDynamicStructureSet.new(poisoned_object_structure, dynamics)
  CrystalClick::ObjectDocumentPlan.new(set, expected.typed_paths)
end

def w128_main_schema(profile : String) : CrystalClick::ObjectDocumentSchema
  case profile
  when "dynamic_paths"
    CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType,
      max_dynamic_paths: 16, max_dynamic_types: 8)
  when "typed_mixed"
    CrystalClick::ObjectDocumentSchema.new(
      {"a" => CrystalClick::BinaryDataType.primitive("UInt64")},
      max_dynamic_paths: 1, max_dynamic_types: 1)
  else
    raise "unknown W128 main profile #{profile.inspect}"
  end
end

def w128_main_declaration(profile : String) : String
  case profile
  when "dynamic_paths" then "JSON(max_dynamic_types=8, max_dynamic_paths=16)"
  when "typed_mixed"   then "JSON(max_dynamic_types=1, max_dynamic_paths=1, a UInt64)"
  else                      raise "unknown W128 main profile #{profile.inspect}"
  end
end

def w128_typed_string_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(
    {"t" => CrystalClick::BinaryDataType.primitive("String")},
    max_dynamic_paths: 0, max_dynamic_types: 0)
end

def w128_write_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w128_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w128_expected_discriminator(profile : String, path : String, mode : UInt64) : Tuple(Bytes, Array(UInt64))
  tags = case {profile, path}
         when {"dynamic_paths", "a"}         then [0, 255, 0, 255, 0, 0, 0, 0].map(&.to_u8)
         when {"dynamic_paths", "arr"}       then [0, 0, 0, 255, 0, 255, 0, 0].map(&.to_u8)
         when {"dynamic_paths", "dot.key"}   then [0, 0, 0, 255, 0, 0, 0, 0].map(&.to_u8)
         when {"dynamic_paths", "flag"}      then [0, 0, 255, 255, 0, 0, 255, 0].map(&.to_u8)
         when {"dynamic_paths", "nest.leaf"} then [1, 1, 255, 255, 1, 255, 1, 1].map(&.to_u8)
         when {"dynamic_paths", "s"}         then [3, 3, 3, 255, 1, 255, 3, 0].map(&.to_u8)
         when {"typed_mixed", "s"}           then [1, 1, 1, 255, 0, 255, 1, 0].map(&.to_u8)
         else                                     raise "unmodeled W128 discriminator #{profile}/#{path}"
         end
  io = IO::Memory.new
  w128_write_u64(io, mode)
  offsets = [8_u64]
  tags.each_slice(2) do |pair|
    if mode == CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE
      pair.each { |tag| io.write_byte(tag) }
    else
      w128_write_varuint(io, pair.size.to_u64)
      if pair.size == 2 && pair[0] == pair[1]
        io.write_byte(1_u8)
        io.write_byte(pair[0])
      else
        io.write_byte(0_u8)
        pair.each { |tag| io.write_byte(tag) }
      end
    end
    offsets << io.pos.to_u64
  end
  {io.to_slice, offsets}
end

def w128_expected_streams(profile : String) : Array(String)
  W116JsonPhysicalVectors.expected_stream_names(profile)
end

def w128_expected_string_streams : Array(String)
  [
    "pk", "payload.object_structure", "payload.object_shared_data.size0",
    "payload.object_shared_data%2Epaths", "payload.object_shared_data%2Evalues",
    "payload.t",
  ]
end

def w128_hashed_pair(logical : String) : Array(String)
  base = CrystalClick::StreamName.hash(logical)
  ["#{base}.bin", "#{base}.mrk2"]
end

def w128_expected_inventory(streams : Array(String)) : Array(String)
  (W128_SIDECARS + streams.flat_map { |stream| w128_hashed_pair(stream) }).sort
end

def w128_assert_inventory(actual : Array(String), expected : Array(String), label : String) : Nil
  w128_require(actual == expected, "#{label}: complete file inventory differs: #{actual.inspect}")
end

def w128_assert_names(actual : Array(String), expected : Array(String), label : String) : Nil
  w128_require(actual == expected, "#{label}: name inventory differs: #{actual.inspect}")
end

def w128_assert_count(actual : String, expected_count : Int32, label : String) : Nil
  w128_require(actual == expected_count.to_s, "#{label}: count.txt differs from authored row count")
end

def w128_assert_substreams(actual : String, streams : Array(String), label : String) : Nil
  w128_require(actual == w128_expected_substreams(streams), "#{label}: columns_substreams.txt differs from independent stream roster")
end

def w128_expected_raw(profile : String, logical : String, mode : UInt64) : Bytes
  if logical.ends_with?(".variant_discr")
    encoded, _offsets = w128_expected_discriminator(
      profile,
      logical.lchop("payload.").rchop(".variant_discr").gsub("%2E", "."),
      mode
    )
    return encoded
  end
  W116JsonPhysicalVectors.expected_raw_stream(profile, logical)
end

def w128_expected_string_raw(logical : String, keys : Array(UInt64)) : Bytes
  io = IO::Memory.new
  case logical
  when "pk"
    keys.each { |key| w128_write_u64(io, key) }
  when "payload.object_structure"
    # Object V3 / MAP / one bucket / zero Dynamic paths / present empty stats.
    w128_write_u64(io, 4_u64)
    w128_write_varuint(io, 0_u64)
    w128_write_varuint(io, 0_u64)
    io.write_byte(1_u8)
    w128_write_varuint(io, 0_u64)
  when "payload.object_shared_data.size0"
    keys.each { |_key| w128_write_u64(io, 0_u64) }
  when "payload.object_shared_data%2Epaths", "payload.object_shared_data%2Evalues"
  when "payload.t"
    ["", "a\0b", "é"].each do |value|
      w128_write_varuint(io, value.bytesize.to_u64)
      io.write(value.to_slice)
    end
  else
    raise "unknown W128 typed-String physical stream #{logical.inspect}"
  end
  io.to_slice
end

def w128_expected_substreams(streams : Array(String)) : String
  payload = streams.reject { |name| name == "pk" }.sort
  String.build do |io|
    io << "columns substreams version: 1\n2 columns:\n"
    io << "1 substreams for column `pk`:\n\tpk\n"
    io << payload.size << " substreams for column `payload`:\n"
    payload.each { |name| io << '\t' << name << '\n' }
  end
end

def w128_expected_columns(profile : String, string_case : Bool = false) : String
  declaration = string_case ? "JSON(max_dynamic_types=0, max_dynamic_paths=0, t String)" : w128_main_declaration(profile)
  "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{declaration}\n"
end

def w128_expected_serialization(rows : Int32, defaults : Int32, string_version : Int32) : JSON::Any
  JSON.parse(%({"columns":[{"exact_num_defaults":true,"kind":"Default","name":"pk","num_defaults":#{defaults},"num_rows":#{rows}}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":#{string_version}},"version":1}))
end

def w128_read_u64(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def w128_checksum_varuint(bytes : Bytes, start : Int32) : Tuple(UInt64, Int32)
  value = 0_u64
  cursor = start
  index = 0
  loop do
    w128_fail("W128 checksum payload has a truncated VarUInt") if cursor >= bytes.size
    byte = bytes[cursor]
    cursor += 1
    payload = (byte & 0x7f_u8).to_u64
    if index == 9 && (payload > 1_u64 || (byte & 0x80_u8) != 0_u8)
      w128_fail("W128 checksum payload VarUInt overflows UInt64")
    end
    value |= payload << (index * 7)
    unless (byte & 0x80_u8) != 0_u8
      if index > 0 && value < (1_u64 << (index * 7))
        w128_fail("W128 checksum payload has a noncanonical VarUInt")
      end
      return {value, cursor}
    end
    index += 1
    w128_fail("W128 checksum payload VarUInt is too long") if index > 9
  end
end

def w128_checksum_hash128(bytes : Bytes, cursor : Int32) : Tuple({UInt64, UInt64}, Int32)
  w128_fail("W128 checksum payload has a truncated hash") if cursor < 0 || cursor > bytes.size - 16
  { {w128_read_u64(bytes, cursor), w128_read_u64(bytes, cursor + 8)}, cursor + 16 }
end

# PartChecksums intentionally exposes physical hash/size and raw size, but not
# the serialized raw hash. Decode the v4 envelope separately so each authored
# lane can be checked against its independent uncompressed bytes.
def w128_independent_checksum_records(part : String) : Hash(String, W128ChecksumEntry)
  bytes = File.read(File.join(part, "checksums.txt")).to_slice
  header = CrystalClick::PartChecksums::CHECKSUMS_HEADER.to_slice
  w128_fail("W128 checksum header differs") if bytes.size < header.size
  w128_fail("W128 checksum header differs") unless bytes[0, header.size] == header
  payload = CrystalClick::CompressedBlock.decode_all(
    bytes[header.size, bytes.size - header.size],
    CrystalClick::PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
    CrystalClick::PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES,
    CrystalClick::PartChecksums::MAX_PAYLOAD_BYTES
  )
  count, cursor = w128_checksum_varuint(payload, 0)
  w128_fail("W128 checksum entry count is invalid") if count == 0_u64 || count > CrystalClick::PartChecksums::MAX_ENTRIES.to_u64
  records = Hash(String, W128ChecksumEntry).new
  count.to_i.times do
    name_size, cursor = w128_checksum_varuint(payload, cursor)
    w128_fail("W128 checksum name length exceeds limit") if name_size == 0_u64 || name_size > CrystalClick::PartChecksums::MAX_NAME_BYTES.to_u64
    name_bytes = name_size.to_i32
    w128_fail("W128 checksum name is truncated") if cursor < 0 || cursor > payload.size - name_bytes
    name = String.new(payload[cursor, name_bytes])
    cursor += name_bytes
    physical_size, cursor = w128_checksum_varuint(payload, cursor)
    physical_hash, cursor = w128_checksum_hash128(payload, cursor)
    flag = payload[cursor]? || w128_fail("W128 checksum record is truncated")
    cursor += 1
    compressed = flag == 1_u8
    w128_fail("W128 checksum compression flag is invalid") unless compressed || flag == 0_u8
    uncompressed_size : UInt64? = nil
    uncompressed_hash : {UInt64, UInt64}? = nil
    if compressed
      raw_size, cursor = w128_checksum_varuint(payload, cursor)
      raw_hash, cursor = w128_checksum_hash128(payload, cursor)
      uncompressed_size = raw_size
      uncompressed_hash = raw_hash
    end
    w128_fail("W128 checksum contains a duplicate name") if records.has_key?(name)
    records[name] = W128ChecksumEntry.new(
      physical_size, physical_hash, compressed, uncompressed_size, uncompressed_hash
    )
  end
  w128_fail("W128 checksum payload has trailing bytes") unless cursor == payload.size
  records
end

def w128_primary_index(keys : Array(UInt64), rows_per_mark : Int32) : Bytes
  values = [] of UInt64
  index = 0
  while index < keys.size
    values << keys[index]
    index += rows_per_mark
  end
  values << keys.last
  io = IO::Memory.new
  values.each { |value| w128_write_u64(io, value) }
  io.to_slice
end

def w128_assert_primary_index(actual : Bytes, expected : Bytes, label : String) : Nil
  w128_fail("#{label}: primary.idx differs from independent mark-start/sentinel model") unless actual == expected
end

def w128_assert_serialization(actual : String, expected : JSON::Any, label : String) : Nil
  parsed = JSON.parse(actual)
  w128_fail("#{label}: serialization metadata differs") unless parsed == expected
rescue error : W128Mismatch
  raise error
rescue
  w128_fail("#{label}: serialization metadata is malformed")
end

def w128_assert_documents(expected : Array(CrystalClick::ObjectDocument), actual : Array(CrystalClick::ObjectDocument), label : String) : Nil
  w128_require(expected.size == actual.size, "#{label}: document count differs")
  expected.each_with_index do |document, index|
    found = actual[index]
    w128_require(document.paths == found.paths, "#{label}: path roster differs at row #{index}")
    document.paths.each do |path|
      w128_require(W122BulkVectors.value_equal?(document.value_for(path), found.value_for(path)),
        "#{label}: value differs at row #{index}, path #{path.inspect}")
    end
  end
end

def w128_assert_granules(expected : Array(Array(CrystalClick::ObjectDocument)), actual : Array(Array(CrystalClick::ObjectDocument)), label : String) : Nil
  w128_require(expected.size == actual.size, "#{label}: granule count differs")
  expected.each_with_index { |rows, index| w128_assert_documents(rows, actual[index], "#{label} granule #{index}") }
end

def w128_assert_check(actual : String, part_name : String, label : String) : Nil
  expected = "#{part_name}\t1\t\n"
  w128_fail("#{label}: CHECK output mismatch: #{actual.inspect}") unless actual == expected
end

def w128_expect_rejected(label : String, &)
  begin
    yield
  rescue error : W128Mismatch
    return
  end
  w128_fail("#{label}: seeded defect was accepted")
end

def w128_expect_comparator_controls : Nil
  w128_expect_rejected("W128 wrong count control") do
    w128_assert_count("7", 8, "W128 wrong count control")
  end
  w128_expect_rejected("W128 wrong roster control") do
    expected = ["pk", "payload.object_structure", "payload.t"]
    actual = ["pk", "payload.object_structure", "payload.wrong"]
    w128_assert_inventory(w128_expected_inventory(actual), w128_expected_inventory(expected), "W128 wrong roster control")
  end
  w128_expect_rejected("W128 wrong substream metadata control") do
    expected = ["pk", "payload.object_structure", "payload.t"]
    actual = ["pk", "payload.object_structure", "payload.wrong"]
    w128_assert_substreams(w128_expected_substreams(actual), expected, "W128 wrong substream metadata control")
  end
  expected_serialization = w128_expected_serialization(3, 1, 0)
  w128_expect_rejected("W128 wrong num_defaults control") do
    actual = w128_expected_serialization(3, 0, 0)
    w128_assert_serialization(actual.to_json, expected_serialization, "W128 wrong num_defaults control")
  end
  w128_expect_rejected("W128 wrong num_rows control") do
    actual = w128_expected_serialization(4, 1, 0)
    w128_assert_serialization(actual.to_json, expected_serialization, "W128 wrong num_rows control")
  end
  w128_expect_rejected("W128 wrong String version control") do
    actual = w128_expected_serialization(3, 1, 1)
    w128_assert_serialization(actual.to_json, expected_serialization, "W128 wrong String version control")
  end
  w128_expect_rejected("W128 wrong primary index control") do
    expected = w128_primary_index([1_u64, 1_u64, 9_u64], 2)
    wrong = expected.dup
    wrong[0] ^= 1_u8
    w128_assert_primary_index(wrong, expected, "W128 wrong primary index control")
  end
  w128_expect_rejected("W128 CHECK=0 control") do
    w128_assert_check("w128_control\t0\t\n", "w128_control", "W128 CHECK=0 control")
  end
  document = CrystalClick::ObjectDocument.new({"x" => CrystalClick::BinaryValue.uint64(1_u64)})
  wrong = CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)
  w128_expect_rejected("W128 wrong document control") do
    w128_assert_documents([document], [wrong], "W128 wrong document control")
  end
  seed = [[document], [document], [document], [document]]
  regrouped = [[document, document], [document, document]]
  w128_expect_rejected("W128 wrong grid control") do
    w128_assert_granules(seed, regrouped, "W128 wrong grid control")
  end
  puts "PASS W128 wrong-count, wrong-roster/substreams, wrong-serialization counters, wrong-index, wrong-document/grid and CHECK=0 comparator controls"
end

def w128_expected_mark_positions(profile : String, logical : String, mode : UInt64, raw : Bytes, string_case : Bool = false) : Array(UInt64)
  if string_case
    case logical
    when "pk", "payload.object_shared_data.size0"
      [0_u64, 16_u64, 24_u64]
    when "payload.object_structure"
      [10_u64, 10_u64, raw.size.to_u64]
    when "payload.object_shared_data%2Epaths", "payload.object_shared_data%2Evalues"
      [0_u64, 0_u64, 0_u64]
    when "payload.t"
      [0_u64, 5_u64, 8_u64]
    else
      raise "unmodeled W128 String marks #{logical.inspect}"
    end
  elsif logical.ends_with?(".variant_discr")
    _bytes, offsets = w128_expected_discriminator(
      profile,
      logical.lchop("payload.").rchop(".variant_discr").gsub("%2E", "."),
      mode
    )
    offsets
  else
    W116JsonPhysicalVectors.expected_mark_grid(profile, logical, 0, 5).map(&.[1])
  end
end

def w128_read_grid(data_path : String, mark_path : String, expected_data_size : Int64, expected_mark_size : Int64, prefix : Int? = nil) : CrystalClick::CompressedMarkGrid
  CrystalClick::CompressedMarkReader.inspect(
    data_path, mark_path, expected_data_size, expected_mark_size,
    prefix_size: prefix
  )
end

def w128_assert_raw_pair(part : String, logical : String, expected_raw : Bytes, expected_positions : Array(UInt64), expected_rows : Array(UInt64), label : String, prefix : Int? = nil) : Nil
  files = w128_hashed_pair(logical)
  bin_path = File.join(part, files[0])
  marks_path = File.join(part, files[1])
  data = File.read(bin_path).to_slice
  raw = if expected_raw.empty?
          w128_require(data.empty?, "#{label}: expected empty stream has physical bytes")
          Bytes.empty
        else
          CrystalClick::CompressedBlock.decode_all(data)
        end
  w128_require(raw == expected_raw, "#{label}: decompressed bytes differ from independent vector")
  mark_bytes = File.read(marks_path).to_slice
  w128_require(mark_bytes.size % 24 == 0, "#{label}: mark records are truncated")
  grid = w128_read_grid(bin_path, marks_path, data.size.to_i64, mark_bytes.size.to_i64, prefix)
  w128_require(grid.positions.map(&.to_u64) == expected_positions,
    "#{label}: independently expected decompressed positions differ")
  w128_require(grid.rows_per_mark == expected_rows, "#{label}: outer row counts differ")
  w128_require(grid.logical_size == expected_raw.size.to_i64, "#{label}: logical stream size differs")
  w128_require(grid.mark_count == expected_rows.size, "#{label}: real mark count differs")
end

def w128_assert_part(part : String, streams : Array(String), expected_count : Int32, keys : Array(UInt64), profile : String, mode : UInt64, label : String, string_case : Bool = false) : Nil
  w128_assert_tree(part, label)
  expected_inventory = w128_expected_inventory(streams)
  actual_inventory = Dir.children(part).sort
  w128_assert_inventory(actual_inventory, expected_inventory, label)

  w128_assert_count(File.read(File.join(part, "count.txt")), expected_count, label)
  expected_columns = w128_expected_columns(profile, string_case)
  w128_require(File.read(File.join(part, "columns.txt")) == expected_columns,
    "#{label}: columns.txt differs from explicit schema model")
  w128_assert_substreams(File.read(File.join(part, "columns_substreams.txt")), streams, label)
  w128_require(File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)",
    "#{label}: default codec differs")
  w128_require(File.read(File.join(part, "metadata_version.txt")) == "0",
    "#{label}: metadata version differs")
  w128_assert_serialization(
    File.read(File.join(part, "serialization.json")),
    w128_expected_serialization(expected_count, keys.count(&.zero?), string_case ? 0 : 1),
    label
  )
  w128_assert_primary_index(
    File.read(File.join(part, "primary.idx")).to_slice,
    w128_primary_index(keys, 2), label
  )
  w128_require(!actual_inventory.any? { |name| name.starts_with?("statistics") },
    "#{label}: unexpected optimizer statistics sidecar")

  checksum = CrystalClick::PartChecksums.open(part)
  expected_checksum_names = (streams.flat_map { |stream| w128_hashed_pair(stream) } + ["count.txt", "primary.idx", "serialization.json"]).sort
  w128_assert_names(checksum.entries.keys.sort, expected_checksum_names, "#{label} checksums.txt")
  independent_checksum_records = w128_independent_checksum_records(part)
  w128_assert_names(independent_checksum_records.keys.sort, expected_checksum_names,
    "#{label} independently decoded checksums.txt")
  expected_checksum_names.each do |name|
    entry = checksum.entry(name) || w128_fail("#{label}: missing checksum entry for #{name}")
    record = independent_checksum_records[name]? || w128_fail("#{label}: missing independent checksum record for #{name}")
    path = File.join(part, name)
    w128_require(!File.symlink?(path) && File.file?(path), "#{label}: unsafe or missing checksummed file #{name}")
    physical = File.read(path).to_slice
    w128_require(CrystalClick::CityHashV1.file_hash(physical) == entry.file_hash,
      "#{label}: recorded physical hash differs for #{name}")
    w128_require(physical.size.to_u64 == entry.physical_size, "#{label}: physical size differs for #{name}")
    w128_require(record.physical_hash == entry.file_hash && record.physical_size == entry.physical_size,
      "#{label}: independent checksums decoder disagrees on physical record for #{name}")
    if name.ends_with?(".mrk2") || {"primary.idx", "count.txt", "serialization.json"}.includes?(name)
      w128_require(!entry.compressed && entry.uncompressed_size.nil? && record.uncompressed_hash.nil?,
        "#{label}: unexpected compressed checksum flag for #{name}")
    elsif name.ends_with?(".bin")
      expected_raw = if string_case
                       w128_expected_string_raw(streams.find { |stream| w128_hashed_pair(stream)[0] == name }.not_nil!, keys)
                     else
                       logical = streams.find { |stream| w128_hashed_pair(stream)[0] == name }.not_nil!
                       w128_expected_raw(profile, logical, mode)
                     end
      expected_uncompressed_hash = CrystalClick::CityHashV1.file_hash(expected_raw)
      w128_require(entry.compressed && entry.uncompressed_size == expected_raw.size.to_u64,
        "#{label}: compressed lane metadata differs for #{name}")
      w128_require(record.compressed && record.uncompressed_size == expected_raw.size.to_u64 &&
                   record.uncompressed_hash == expected_uncompressed_hash,
        "#{label}: independent uncompressed checksum differs for #{name}")
      w128_require(physical.empty? == expected_raw.empty?, "#{label}: empty-lane frame representation differs for #{name}")
    end
    checksum.validate_selected_entries(part, name)
  end

  streams.each do |logical|
    raw = string_case ? w128_expected_string_raw(logical, keys) : w128_expected_raw(profile, logical, mode)
    positions = w128_expected_mark_positions(profile, logical, mode, raw, string_case)
    rows = expected_count == 8 ? [2_u64, 2_u64, 2_u64, 2_u64] : [2_u64, 1_u64]
    prefix = if string_case && logical == "payload.object_structure"
               10
             elsif !string_case && logical == "payload.object_structure"
               W120StructureVectors.object_header(W123ObjectVectors.plan(profile).structures.object).size
             elsif !string_case && logical.ends_with?(".dynamic_structure")
               path = W120StructureVectors.dynamic_paths(profile).find do |candidate|
                 "payload.#{W120StructureVectors.physical_path(candidate)}.dynamic_structure" == logical
               end || w128_fail("#{label}: no authored Dynamic path for #{logical}")
               W120StructureVectors.dynamic_header(W123ObjectVectors.plan(profile).structures.dynamic_for(path)).size
             elsif logical.ends_with?(".variant_discr")
               8
             else
               nil
             end
    w128_assert_raw_pair(part, logical, raw, positions, rows, "#{label} #{logical}", prefix)
  end
end

def w128_assert_part_name(binary : String, store : String, table : String, label : String, rows : Int32) : Tuple(String, String)
  active = w128_run(binary, store,
    "SELECT name, path, part_type, toString(rows) FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines
  w128_require(active.size == 1, "#{label}: expected one active part, found #{active.size}")
  fields = active.first.split('\t')
  w128_require(fields.size == 4 && fields[0] == "all_1_1_0" && fields[2] == "Wide" && fields[3] == rows.to_s,
    "#{label}: attached part identity/type/count differs")
  {fields[0], w128_store_child(fields[1], store, "#{label} active part")}
end

def w128_assert_stock(binary : String, store : String, table : String, profile : String, keys : Array(UInt64), label : String, string_case : Bool = false) : Nil
  part_name, _part = w128_assert_part_name(binary, store, table, label, keys.size)
  check = w128_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  w128_assert_check(check, part_name, "#{label} CHECK TABLE")
  if string_case
    full = w128_run(binary, store,
      "SELECT pk, hex(payload.t) FROM default.#{table} ORDER BY pk FORMAT TSVRaw")
    selected = w128_run(binary, store,
      "SELECT pk, hex(payload.t) FROM default.#{table} WHERE pk >= 1 AND pk <= 1 ORDER BY pk FORMAT TSVRaw")
    w128_require(full == "0\t\n1\t610062\n9\tC3A9\n", "#{label}: stock full typed-String SQL differs: #{full.inspect}")
    w128_require(selected == "1\t610062\n", "#{label}: stock typed-String PK-window SQL differs: #{selected.inspect}")
  else
    full = "SELECT pk, toJSONString(payload) FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
    selected = "SELECT pk, toJSONString(payload) FROM default.#{table} WHERE pk >= 3 AND pk <= 6 ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
    w115_assert_semantic_documents(w128_run(binary, store, full), profile, false, "#{label} stock full")
    w115_assert_semantic_documents(w128_run(binary, store, selected), profile, true, "#{label} stock pk3..6")
  end
end

def w128_reader(
  part : String,
  typed : Hash(String, CrystalClick::BinaryDataType),
  first_mark : Int32,
  mark_count : Int32,
  profile : CrystalClick::BinaryBulkProfile,
) : Array(Array(CrystalClick::ObjectDocument))
  CrystalClick::ObjectDocumentFileReader.read(
    part, "payload", typed,
    first_mark: first_mark,
    mark_count: mark_count,
    profile: profile,
    shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
    hashed: true,
    limits: CrystalClick::BinaryCodecLimits.default,
    transport_limits: CrystalClick::CompressedStreamLimits.new
  )
end

def w128_install_case(binary : String, root : String, label : String, declaration : String, schema : CrystalClick::ObjectDocumentSchema, plan : CrystalClick::ObjectDocumentPlan, documents : Array(Array(CrystalClick::ObjectDocument)), keys : Array(UInt64), mode : UInt64, profile : String, typed : Hash(String, CrystalClick::BinaryDataType), string_case : Bool = false) : Nil
  store = File.join(root, "stores", label.gsub(' ', "_").downcase)
  w128_require(!File.exists?(store) && !File.symlink?(File.dirname(store)), "#{label}: store path is occupied or unsafe")
  FileUtils.mkdir_p(store)
  table = "w128_#{label.gsub(' ', "_").downcase}"
  w128_create_empty_table(binary, store, table, schema, declaration)
  data_path = w128_table_data_path(binary, store, table)
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  w128_store_child(detached, store, "#{label} detached directory")
  part_name = "all_1_1_0"
  part = File.join(detached, part_name)
  w128_require(!File.exists?(part) && !File.symlink?(part), "#{label}: target path exists before writer call")

  # Production chooses every path/filename. Expected names, bytes and marks
  # below are separately assembled from W116/W120/W122/W123 authored models.
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    part, "pk", Slice(UInt64).new(keys.size) { |index| keys[index] }, "payload",
    schema, plan, documents,
    rows_per_mark: 2,
    mode: mode,
    profile: string_case ? CrystalClick::BinaryBulkProfile.single_stream : CrystalClick::BinaryBulkProfile.with_size_stream,
    shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
    frame_bytes: W128_FRAME_BYTES,
    metadata_version: 0_i64
  )
  part = w128_store_child(part, store, "#{label} library-generated detached part")
  expected_streams = string_case ? w128_expected_string_streams : w128_expected_streams(profile)
  w128_assert_part(part, expected_streams, keys.size, keys, profile, mode, label, string_case)

  w128_run(binary, store, "ALTER TABLE default.#{table} ATTACH PART '#{part_name}'")
  active_name, attached = w128_assert_part_name(binary, store, table, label, keys.size)
  w128_require(active_name == part_name, "#{label}: attach changed part identity")
  expected_after_attach = (w128_expected_inventory(expected_streams) + ["invalidated_system_columns.txt"]).sort
  w128_require(Dir.children(attached).sort == expected_after_attach,
    "#{label}: ATTACH changed unexpected part inventory")
  checksum = CrystalClick::PartChecksums.open(attached)
  checksum.entries.keys.each { |name| checksum.validate_selected_entries(attached, name) }

  if string_case
    expected_docs = documents
  else
    expected_docs = W123ObjectVectors.documents(profile)
  end
  expected_marks = expected_docs.size
  full = w128_reader(attached, typed, 0, expected_marks, string_case ? CrystalClick::BinaryBulkProfile.single_stream : CrystalClick::BinaryBulkProfile.with_size_stream)
  w128_assert_granules(expected_docs, full, "#{label} W126 reader full")
  middle_start = 1
  middle_count = 1
  middle = w128_reader(attached, typed, middle_start, middle_count, string_case ? CrystalClick::BinaryBulkProfile.single_stream : CrystalClick::BinaryBulkProfile.with_size_stream)
  w128_assert_granules(expected_docs[middle_start, middle_count], middle, "#{label} W126 reader middle window")
  zero = w128_reader(attached, typed, expected_marks, 0, string_case ? CrystalClick::BinaryBulkProfile.single_stream : CrystalClick::BinaryBulkProfile.with_size_stream)
  w128_assert_granules([] of Array(CrystalClick::ObjectDocument), zero, "#{label} W126 terminal zero window")
  w128_assert_stock(binary, store, table, profile, keys, label, string_case)
  puts "PASS W128 library-created complete Wide Object part + exact inventory/checksums/marks + stock CHECK=1/full/PK + W126 full/middle/zero: #{label} part=#{active_name}"
end

def w128_main_case(binary : String, root : String, profile : String, mode_name : String, mode : UInt64) : Nil
  label = "#{profile}_#{mode_name}"
  documents = W123ObjectVectors.documents(profile)
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
  schema = w128_main_schema(profile)
  # Deliberately poison every supplied Object/Dynamic statistic. The writer
  # must publish fresh model-derived values rather than trusting this plan.
  input_plan = w128_poisoned_plan(profile)
  typed = W123ObjectVectors.plan(profile).typed_paths
  w128_install_case(binary, root, label, w128_main_declaration(profile), schema,
    input_plan, documents, keys, mode, profile, typed)
end

def w128_string_case(binary : String, root : String) : Nil
  profile = "typed_string"
  keys = [0_u64, 1_u64, 9_u64]
  rows = [
    CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.string("")}),
    CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.string("a\0b")}),
    CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.string("é")}),
  ]
  documents = [[rows[0], rows[1]], [rows[2]]]
  schema = w128_typed_string_schema
  empty_statistics = CrystalClick::StructureStatistics.new([] of UInt64, [] of CrystalClick::StructureStatistic)
  object = CrystalClick::ObjectStructure.new([] of String, statistics: empty_statistics)
  plan = CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(object, {} of String => CrystalClick::DynamicStructure),
    {"t" => CrystalClick::BinaryDataType.primitive("String")}
  )
  typed = {"t" => CrystalClick::BinaryDataType.primitive("String")}
  w128_install_case(binary, root, profile,
    "JSON(max_dynamic_types=0, max_dynamic_paths=0, t String)", schema, plan,
    documents, keys, CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
    "dynamic_shared_only", typed, string_case: true)
end

def w128_check : Nil
  binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
  root = ENV["W128_TMP_ROOT"]? || raise "W128_TMP_ROOT is required"
  w128_require(!File.symlink?(root) && Dir.exists?(root), "W128 temporary root must be an existing non-symlink directory")
  root = File.realpath(root)
  w128_require(root.starts_with?("/private/tmp/crystal-click-json-w128."), "unsafe W128 temporary root")
  w128_require(W123ObjectVectors::PROFILES.to_a.sort == ["dynamic_paths", "typed_mixed"].sort,
    "W128 independent W123 profile inventory changed")
  w128_require(W115_SEMANTIC_PAYLOADS.size == 8, "W128 independent W115 literal row inventory changed")

  bootstrap_store = File.join(root, "bootstrap")
  FileUtils.mkdir_p(bootstrap_store)
  w128_run(binary, bootstrap_store, "SELECT 1")
  w128_verify_runtime(binary, bootstrap_store)
  w128_expect_comparator_controls
  {"dynamic_paths", "typed_mixed"}.each do |profile|
    {"basic"   => CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
     "compact" => CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE}.each do |mode_name, mode|
      w128_main_case(binary, root, profile, mode_name, mode)
    end
  end
  w128_string_case(binary, root)
  puts "PASS W128 scope: hashed library-only normalized Object V3/MAP Wide parts; no source parts, borrowed sidecars, optimizer stats, partitions, or lifecycle claim"
end

w128_check
