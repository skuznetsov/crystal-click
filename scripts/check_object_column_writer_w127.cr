# W127 column writer oracle. The only physical shell input is created by the
# pinned stock ClickHouse binary in this run; W123 supplies authored logical
# documents, never output rosters or retained bytes.
require "file_utils"
require "json"
require "../src/crystal_click"
require "./w115_json_semantic_vectors"
require "./w123_object_vectors"

W127_VERSION             = "26.10.1.1201"
W127_BUILD_HASH          = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W127_EXECUTABLE_SHA256   = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W127_FRAME_BYTES         = 16
W127_LITERAL_FRAME_BYTES = 43
W127_SETTINGS            = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version_for_zero_level_parts='map'"
W127_JSON_ROWS           = [
  %({"pk":1,"payload":{"a":10,"s":"alpha","flag":true,"arr":[1,2],"nest":{"leaf":"one"},"dot.key":101}}),
  %({"pk":2,"payload":{"a":null,"s":"","flag":false,"arr":[],"nest":{"leaf":"two"},"dot.key":102}}),
  %({"pk":3,"payload":{"a":3,"s":"a\\u0000b","flag":null,"arr":[3],"nest":{"leaf":null},"dot.key":103}}),
  %({"pk":4,"payload":{}}),
  %({"pk":5,"payload":{"a":5,"s":42,"flag":true,"arr":[4,5],"nest":{"leaf":"five"},"dot.key":105}}),
  %({"pk":6,"payload":{"a":6,"s":null,"flag":false,"arr":null,"nest":{},"dot.key":106}}),
  %({"pk":7,"payload":{"a":7,"s":"last","flag":null,"arr":[6],"nest":{"leaf":"end"},"dot.key":107}}),
  %({"pk":8,"payload":{"a":8,"s":true,"flag":true,"arr":[7],"nest":{"leaf":""},"dot.key":108}}),
]
W127_SHELL_SIDECARS = [
  "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
  "default_compression_codec.txt", "metadata_version.txt", "primary.idx",
  "serialization.json", "statistics.packed",
]

alias W127Grid = Array(Tuple(UInt64, UInt64, UInt64))

class W127Mismatch < Exception
end

def w127_fail(message : String) : NoReturn
  raise W127Mismatch.new(message)
end

def w127_require(condition : Bool, message : String) : Nil
  w127_fail(message) unless condition
end

def w127_run(binary : String, store : String, query : String, input : IO? = nil) : String
  output = IO::Memory.new
  error = IO::Memory.new
  arguments = ["local", "--path", store, "--query", query]
  status = if input
             Process.run(binary, arguments, input: input, output: output, error: error)
           else
             Process.run(binary, arguments, output: output, error: error)
           end
  raise "ClickHouse local query failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w127_run_status(binary : String, arguments : Array(String)) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, arguments, output: output, error: error)
  raise "ClickHouse command failed: #{error}" unless status.success?
  output.to_s
end

def w127_verify_runtime(binary : String, store : String) : Nil
  version = w127_run_status(binary, ["local", "--version"]).strip
  w127_require(version == "ClickHouse local version #{W127_VERSION} (official build).",
    "unexpected ClickHouse version: #{version.inspect}")
  digest = w127_run_status("shasum", ["-a", "256", binary]).split(' ').first? || ""
  w127_require(digest == W127_EXECUTABLE_SHA256, "unexpected ClickHouse executable SHA-256")
  build = w127_run(binary, store,
    "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
  w127_require(build == ["GIT_HASH=#{W127_BUILD_HASH}", "VERSION_GITHASH=#{W127_BUILD_HASH}"],
    "unexpected ClickHouse build identity")
end

def w127_store_child(path : String, store : String, label : String) : String
  real_store = File.realpath(store)
  real_path = File.realpath(path)
  unless real_path.starts_with?(real_store + "/") && !File.symlink?(path)
    w127_fail("#{label}: path escapes isolated store or is a symlink")
  end
  relative = real_path[(real_store.size + 1)..]
  cursor = real_store
  relative.split('/').each do |component|
    cursor = File.join(cursor, component)
    w127_fail("#{label}: symlink in store path") if File.symlink?(cursor)
  end
  real_path
end

def w127_assert_tree(path : String, label : String) : Nil
  w127_require(Dir.exists?(path) && !File.symlink?(path), "#{label}: unsafe/missing directory")
  Dir.children(path).each do |name|
    child = File.join(path, name)
    w127_require(!File.symlink?(child), "#{label}: symlink child #{name.inspect}")
    if Dir.exists?(child)
      w127_assert_tree(child, "#{label}/#{name}")
    else
      w127_require(File.file?(child), "#{label}: non-file child #{name.inspect}")
    end
  end
end

def w127_part(binary : String, store : String, table : String, label : String) : Tuple(String, String)
  rows = w127_run(binary, store,
    "SELECT name, path, part_type, toString(rows) FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines
  w127_require(rows.size == 1, "#{label}: expected one active part, got #{rows.size}")
  fields = rows.first.split('\t')
  w127_require(fields.size == 4 && fields[2] == "Wide" && fields[3] == "8",
    "#{label}: expected one Wide eight-row part")
  part = w127_store_child(fields[1], store, "#{label} part")
  w127_assert_tree(part, "#{label} part")
  {fields[0], part}
end

def w127_canonical_type(profile : String) : String
  case profile
  when "dynamic_paths"
    "JSON(max_dynamic_types=8, max_dynamic_paths=16)"
  when "typed_mixed"
    "JSON(max_dynamic_types=1, max_dynamic_paths=1, a UInt64)"
  else
    raise "unknown W127 profile: #{profile.inspect}"
  end
end

def w127_create_table(binary : String, store : String, table : String, profile : String) : Nil
  json_type = profile == "typed_mixed" ? "JSON(a UInt64, max_dynamic_paths=1, max_dynamic_types=1)" : "JSON(max_dynamic_paths=16, max_dynamic_types=8)"
  w127_run(binary, store,
    "CREATE TABLE default.#{table} (pk UInt64, payload #{json_type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{W127_SETTINGS}")
  actual = w127_run(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  expected = "pk UInt64\npayload #{w127_canonical_type(profile)}\n"
  w127_require(actual == expected, "#{table}: live schema differs from the explicit W127 schema")
end

def w127_insert_rows(binary : String, store : String, table : String) : Nil
  input = IO::Memory.new(W127_JSON_ROWS.join("\n") + "\n")
  w127_run(binary, store, "INSERT INTO default.#{table} FORMAT JSONEachRow", input)
end

def w127_table_data_path(binary : String, store : String, table : String) : String
  path = w127_run(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  w127_store_child(path, store, "#{table} data path")
end

def w127_dynamic_paths(profile : String) : Array(String)
  profile == "dynamic_paths" ? ["a", "arr", "dot.key", "flag", "nest.leaf", "s"] : ["s"]
end

def w127_dynamic_types(profile : String) : Hash(String, Array(CrystalClick::BinaryDataType))
  int64 = CrystalClick::BinaryDataType.primitive("Int64")
  bool = CrystalClick::BinaryDataType.primitive("Bool")
  string = CrystalClick::BinaryDataType.primitive("String")
  array_int64 = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.nullable(int64))
  if profile == "dynamic_paths"
    {
      "a"         => [int64],
      "arr"       => [array_int64],
      "dot.key"   => [int64],
      "flag"      => [bool],
      "nest.leaf" => [string],
      "s"         => [bool, int64, string],
    } of String => Array(CrystalClick::BinaryDataType)
  elsif profile == "typed_mixed"
    {"s" => [string]} of String => Array(CrystalClick::BinaryDataType)
  else
    raise "unknown W127 profile: #{profile.inspect}"
  end
end

def w127_typed_paths(profile : String) : Hash(String, CrystalClick::BinaryDataType)
  if profile == "typed_mixed"
    {"a" => CrystalClick::BinaryDataType.primitive("UInt64")}
  else
    {} of String => CrystalClick::BinaryDataType
  end
end

def w127_poisoned_plan(profile : String) : CrystalClick::ObjectDocumentPlan
  paths = w127_dynamic_paths(profile)
  types = w127_dynamic_types(profile)
  object_poison = CrystalClick::StructureStatistics.new(
    Array(UInt64).new(paths.size, 99_u64),
    [CrystalClick::StructureStatistic.new("wrong-object-stat", 99_u64)])
  dynamics = Hash(String, CrystalClick::DynamicStructure).new
  types.each do |path, alternatives|
    poison = CrystalClick::StructureStatistics.new(
      Array(UInt64).new(alternatives.size + 1, 99_u64),
      [CrystalClick::StructureStatistic.new("wrong-dynamic-stat", 99_u64)])
    dynamics[path] = CrystalClick::DynamicStructure.new(alternatives, poison)
  end
  set = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(paths, statistics: object_poison), dynamics)
  CrystalClick::ObjectDocumentPlan.new(set, w127_typed_paths(profile))
end

def w127_is_countable?(value : CrystalClick::BinaryValue) : Bool
  !value.is_null? && value.type.tag != CrystalClick::BinaryDataType::TAG_NOTHING
end

def w127_statistics(counts : Array(UInt64), shared_counts : Hash(String, UInt64)) : CrystalClick::StructureStatistics
  shared = Array(CrystalClick::StructureStatistic).new(shared_counts.size)
  shared_counts.each { |name, count| shared << CrystalClick::StructureStatistic.new(name, count) }
  CrystalClick::StructureStatistics.new(counts, shared)
end

# Independent model: traverse authored W123 values in granule, row, then raw
# path order. Exact descriptor matches are ordinary Dynamic variants; every
# other non-NULL value routes to SharedVariant. This does not call production
# recomputation or inspect captured metadata.
def w127_expected_plan(profile : String, documents : Array(Array(CrystalClick::ObjectDocument))) : CrystalClick::ObjectDocumentPlan
  paths = w127_dynamic_paths(profile)
  alternatives = w127_dynamic_types(profile)
  typed = w127_typed_paths(profile)
  zero_object_counts = Array(UInt64).new(paths.size, 0_u64)
  object_counts_by_path = Hash(String, UInt64).new
  retained_object_paths = [] of String
  object_shared_cap = 10_000

  documents.each do |granule|
    granule.each do |document|
      document.paths.each do |path|
        next if typed.has_key?(path)
        next unless document.has_path?(path)
        value = document.value_for(path)
        next unless w127_is_countable?(value)
        if index = paths.index(path)
          zero_object_counts[index] += 1_u64
        else
          if object_counts_by_path.has_key?(path)
            object_counts_by_path[path] += 1_u64
          elsif retained_object_paths.size < object_shared_cap
            retained_object_paths << String.new(path.to_slice)
            object_counts_by_path[String.new(path.to_slice)] = 1_u64
          end
        end
      end
    end
  end

  object_statistics = w127_statistics(zero_object_counts, object_counts_by_path)
  dynamic_statistics = Hash(String, CrystalClick::StructureStatistics).new
  paths.each do |path|
    choices = alternatives[path]
    names = [CrystalClick::DynamicStructure::SHARED_VARIANT_NAME] of String
    choices.each { |type| names << type.name }
    names.sort!
    positional = Array(UInt64).new(names.size, 0_u64)
    shared_types = Hash(String, UInt64).new
    retained_shared_types = [] of String

    documents.each do |granule|
      granule.each do |document|
        next unless document.has_path?(path)
        value = document.value_for(path)
        next unless w127_is_countable?(value)
        ordinary = choices.index { |type| type == value.type }
        if type_index = ordinary
          variant_index = names.index(choices[type_index].name) || w127_fail("W127 expected type name missing from canonical variants")
          positional[variant_index] += 1_u64
        else
          shared_index = names.index(CrystalClick::DynamicStructure::SHARED_VARIANT_NAME).not_nil!
          positional[shared_index] += 1_u64
          type_name = value.type.name
          if shared_types.has_key?(type_name)
            shared_types[type_name] += 1_u64
          elsif retained_shared_types.size < 256
            retained_shared_types << String.new(type_name.to_slice)
            shared_types[String.new(type_name.to_slice)] = 1_u64
          end
        end
      end
    end
    dynamic_statistics[path] = w127_statistics(positional, shared_types)
  end

  dynamics = Hash(String, CrystalClick::DynamicStructure).new
  alternatives.each do |path, types|
    dynamics[path] = CrystalClick::DynamicStructure.new(types, dynamic_statistics[path])
  end
  object = CrystalClick::ObjectStructure.new(paths, statistics: object_statistics)
  structures = CrystalClick::ObjectDynamicStructureSet.new(object, dynamics)
  CrystalClick::ObjectDocumentPlan.new(structures, typed)
end

def w127_assert_fresh_plan(actual : CrystalClick::ObjectDocumentPlan, expected : CrystalClick::ObjectDocumentPlan, input : CrystalClick::ObjectDocumentPlan, label : String) : Nil
  w127_require(actual.structures.object == expected.structures.object,
    "#{label}: Object statistics or explicit roster differ from independent model")
  w127_require(actual.typed_paths == expected.typed_paths, "#{label}: typed schema changed")
  expected_dynamics = expected.structures.dynamics
  actual_dynamics = actual.structures.dynamics
  w127_require(actual_dynamics.keys.sort == expected_dynamics.keys.sort, "#{label}: Dynamic roster changed")
  expected_dynamics.each do |path, structure|
    w127_require(actual_dynamics[path]? == structure, "#{label}: Dynamic statistics differ at #{path.inspect}")
  end
  w127_require(input.structures.object.statistics.not_nil!.counts.all? { |count| count == 99_u64 },
    "#{label}: writer mutated caller Object statistics")
  input.structures.dynamics.each do |path, structure|
    w127_require(structure.statistics.not_nil!.counts.all? { |count| count == 99_u64 },
      "#{label}: writer mutated caller Dynamic statistics at #{path.inspect}")
  end
end

def w127_grid(bytes : Bytes, label : String) : W127Grid
  w127_require(bytes.size % 24 == 0, "#{label}: marks are not 24-byte records")
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // 24) do |index|
    words = StaticArray(UInt64, 3).new(0_u64)
    3.times do |word|
      8.times { |byte| words[word] |= bytes[index * 24 + word * 8 + byte].to_u64 << (8 * byte) }
    end
    {words[0], words[1], words[2]}
  end
end

def w127_assert_writer_inventory(files : CrystalClick::ObjectDocumentColumnFiles, profile : String, label : String) : Nil
  logical = files.stream_names
  w127_require(logical.uniq.size == logical.size, "#{label}: writer stream roster has duplicates")
  expected_files = logical.flat_map do |stream|
    basename = CrystalClick::StreamName.hash(stream)
    ["#{basename}.bin", "#{basename}.mrk2"]
  end.sort
  w127_require(files.file_names.sort == expected_files, "#{label}: filename roster does not pair every logical stream")

  logical.each do |stream|
    pair = files.pair_for(stream)
    bin_name = "#{CrystalClick::StreamName.hash(stream)}.bin"
    marks_name = "#{CrystalClick::StreamName.hash(stream)}.mrk2"
    w127_require(files.file_bytes(bin_name) == pair.data, "#{label}: detached .bin differs from pair_for(#{stream.inspect})")
    w127_require(files.file_bytes(marks_name) == pair.marks, "#{label}: detached .mrk2 differs from pair_for(#{stream.inspect})")
  end

  w127_require(profile == "dynamic_paths" || profile == "typed_mixed", "#{label}: unsupported profile")
end

def w127_assert_metadata_marks(files : CrystalClick::ObjectDocumentColumnFiles, profile : String, label : String) : Nil
  paths = w127_dynamic_paths(profile)
  w127_require(paths.size < 128, "#{label}: independent W127 path roster exceeds one-byte count encoding")
  paths.each do |path|
    w127_require(path.bytesize < 128, "#{label}: independent W127 path exceeds one-byte length encoding")
  end
  object_prefix_bytes = 8 + 1 + paths.sum { |path| 1 + path.bytesize } + 1
  expected_object_position = {
    ((object_prefix_bytes // W127_FRAME_BYTES) * W127_LITERAL_FRAME_BYTES).to_u64,
    (object_prefix_bytes % W127_FRAME_BYTES).to_u64,
  }

  object_pair = files.pair_for(files.physical.object_structure_stream)
  object_grid = w127_grid(object_pair.marks, "#{label} Object structure")
  w127_require(object_grid.size == 5 && object_grid.map(&.[2]) == [2_u64, 2_u64, 2_u64, 2_u64, 0_u64],
    "#{label}: Object metadata grid does not preserve four outer marks plus EOF")
  object_grid[0, 4].each do |record|
    w127_require({record[0], record[1]} == {object_grid[0][0], object_grid[0][1]},
      "#{label}: Object metadata marks do not repeat the pre-statistics prefix")
    w127_require({record[0], record[1]} == expected_object_position,
      "#{label}: Object metadata mark differs from the independently derived pre-statistics position")
  end

  files.plan.structures.object.dynamic_paths.each do |path|
    pair = files.pair_for(files.physical.discriminator_stream(path))
    grid = w127_grid(pair.marks, "#{label} Dynamic discriminator #{path}")
    w127_require(grid.size == 5 && grid.map(&.[2]) == [2_u64, 2_u64, 2_u64, 2_u64, 0_u64],
      "#{label}: discriminator grid does not use outer document counts")
    w127_require({grid[0][0], grid[0][1]} == {0_u64, 8_u64},
      "#{label}: first discriminator mark does not follow the eight-byte prefix in frame zero")
    previous = grid[0]
    1.upto(grid.size - 1) do |index|
      current = grid[index]
      monotone = current[0] > previous[0] ||
                 (current[0] == previous[0] && current[1] >= previous[1])
      w127_require(monotone,
        "#{label}: discriminator marks move backward at record #{index}")
      previous = current
    end
  end
end

def w127_read_u32(bytes : Bytes, offset : Int32) : UInt32
  bytes[offset].to_u32 |
    (bytes[offset + 1].to_u32 << 8) |
    (bytes[offset + 2].to_u32 << 16) |
    (bytes[offset + 3].to_u32 << 24)
end

def w127_write_u32(bytes : Bytes, offset : Int32, value : UInt32) : Nil
  4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
end

def w127_write_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w127_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  w127_write_u64(io, hash[0])
  w127_write_u64(io, hash[1])
end

def w127_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w127_literal_lz4_frame(raw : Bytes) : Bytes
  raise "cannot encode empty W127 checksum payload" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w127_write_u32(frame, header + 1, compressed_size.to_u32)
  w127_write_u32(frame, header + 5, raw.size.to_u32)
  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  if raw.size < 15
    frame[cursor] = (raw.size << 4).to_u8
    cursor += 1
  else
    frame[cursor] = 0xf0_u8
    cursor += 1
    remaining = raw.size - 15
    while remaining >= 255
      frame[cursor] = 255_u8
      cursor += 1
      remaining -= 255
    end
    frame[cursor] = remaining.to_u8
    cursor += 1
  end
  raw.copy_to(frame[cursor, raw.size])
  hash = CrystalClick::CityHashV1.hash128(frame[CrystalClick::CompressedBlock::CHECKSUM_SIZE, compressed_size])
  8.times do |index|
    frame[index] = ((hash[0] >> (8 * index)) & 0xff_u64).to_u8
    frame[8 + index] = ((hash[1] >> (8 * index)) & 0xff_u64).to_u8
  end
  frame
end

def w127_rewrite_checksums(part : String, changed_files : Array(String)) : Nil
  original = CrystalClick::PartChecksums.open(part)
  names = original.entries.keys.sort
  w127_require(!names.empty? && !names.includes?("checksums.txt"), "W127 shell has invalid checksums inventory")
  changed_files.each do |name|
    w127_require(names.includes?(name), "W127 writer output is missing from checksums inventory: #{name}")
  end

  budget = CrystalClick::CompressedStreamBudget.read_default
  payload = IO::Memory.new
  w127_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    w127_require(name == File.basename(name) && name != "." && name != "..", "unsafe W127 checksum path #{name.inspect}")
    path = File.join(part, name)
    w127_require(File.file?(path) && !File.symlink?(path), "W127 copied part has unsafe/missing #{name}")
    physical = File.read(path).to_slice
    entry = original.entry(name) || w127_fail("W127 copied part lost checksum entry #{name}")
    raw = if entry.compressed
            physical.empty? ? Bytes.empty : CrystalClick::CompressedMarkReader.read_all(
              path, expected_size: physical.size.to_i64, budget: budget
            )
          else
            physical
          end

    w127_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w127_write_varuint(payload, physical.size.to_u64)
    w127_write_hash(payload, CrystalClick::CityHashV1.file_hash(physical))
    if entry.compressed
      payload.write_byte(1_u8)
      w127_write_varuint(payload, raw.size.to_u64)
      w127_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end

  manifest = IO::Memory.new
  manifest << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  manifest.write(w127_literal_lz4_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), manifest.to_slice)
  rewritten = CrystalClick::PartChecksums.open(part)
  w127_require(rewritten.entries.keys.sort == names, "W127 regenerated checksum inventory changed")
  names.each { |name| rewritten.validate_selected_entries(part, name) }
end

def w127_assert_equal_documents(expected : Array(CrystalClick::ObjectDocument), actual : Array(CrystalClick::ObjectDocument), label : String) : Nil
  w127_require(expected.size == actual.size, "#{label}: row count differs")
  expected.each_with_index do |document, row_index|
    observed = actual[row_index]
    w127_require(document.paths == observed.paths, "#{label}: paths differ at row #{row_index}")
    document.paths.each do |path|
      w127_require(W122BulkVectors.value_equal?(document.value_for(path), observed.value_for(path)),
        "#{label}: value differs at row #{row_index}, path #{path.inspect}")
    end
  end
end

def w127_assert_granules(expected : Array(Array(CrystalClick::ObjectDocument)), actual : Array(Array(CrystalClick::ObjectDocument)), label : String) : Nil
  w127_require(expected.size == actual.size, "#{label}: granule count differs")
  expected.each_with_index { |rows, index| w127_assert_equal_documents(rows, actual[index], "#{label} granule #{index}") }
end

def w127_read(part : String, profile : String, first_mark : Int32, mark_count : Int32) : Array(Array(CrystalClick::ObjectDocument))
  CrystalClick::ObjectDocumentFileReader.read(
    part,
    "payload",
    w127_typed_paths(profile),
    first_mark: first_mark,
    mark_count: mark_count,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
    hashed: true,
    limits: CrystalClick::BinaryCodecLimits.default,
    transport_limits: CrystalClick::CompressedStreamLimits.new
  )
end

def w127_assert_check(actual : String, part_name : String, label : String) : Nil
  expected = "#{part_name}\t1\t\n"
  w127_fail("#{label}: CHECK output mismatch: #{actual.inspect}") unless actual == expected
end

def w127_stock_queries(binary : String, store : String, table : String, profile : String, label : String) : Nil
  part_name, _part = w127_part(binary, store, table, label)
  check = w127_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  w127_assert_check(check, part_name, "#{label} CHECK TABLE")
  full = "SELECT pk, toJSONString(payload) FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
  selected = "SELECT pk, toJSONString(payload) FROM default.#{table} WHERE pk >= 3 AND pk <= 6 ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
  w115_assert_semantic_documents(w127_run(binary, store, full), profile, false, "#{label} stock full")
  w115_assert_semantic_documents(w127_run(binary, store, selected), profile, true, "#{label} stock pk3..6")
end

def w127_case(binary : String, root : String, profile : String, mode_name : String, mode : UInt64) : Nil
  label = "W127 #{profile}/#{mode_name}"
  store = File.join(root, "stores", "#{profile}_#{mode_name}")
  w127_require(!File.exists?(store) && !File.symlink?(File.dirname(store)), "#{label}: store is already present/unsafe")
  FileUtils.mkdir_p(store)
  table_shell = "w127_shell_#{profile}_#{mode_name}"
  table_target = "w127_target_#{profile}_#{mode_name}"
  w127_create_table(binary, store, table_shell, profile)
  w127_create_table(binary, store, table_target, profile)
  w127_insert_rows(binary, store, table_shell)

  shell_part_name, shell_part = w127_part(binary, store, table_shell, "#{label} fresh shell")
  w127_stock_queries(binary, store, table_shell, profile, "#{label} source shell")
  documents = W123ObjectVectors.documents(profile)
  w127_require(documents.size == 4 && documents.all? { |mark| mark.size == 2 }, "#{label}: authored W123 outer grid changed")
  input_plan = w127_poisoned_plan(profile)
  expected_plan = w127_expected_plan(profile, documents)
  files = CrystalClick::ObjectDocumentColumnWriter.encode(
    "payload", input_plan, documents,
    mode: mode,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
    hashed: true,
    frame_bytes: W127_FRAME_BYTES,
    limits: CrystalClick::BinaryCodecLimits.default,
    transport_limits: CrystalClick::CompressedStreamLimits.new
  )
  w127_assert_fresh_plan(files.plan, expected_plan, input_plan, label)
  w127_assert_writer_inventory(files, profile, label)
  w127_assert_metadata_marks(files, profile, label)

  pk = CrystalClick::BinaryBulkPhysicalPlan.new(
    CrystalClick::BinaryDataType.primitive("UInt64"), "pk",
    CrystalClick::BinaryBulkProfile.with_size_stream)
  pk_files = [pk.data_file_for("root.data", hashed: true), pk.marks_file_for("root.data", hashed: true)]
  w127_require((files.file_names + pk_files).uniq.size == files.file_names.size + pk_files.size,
    "#{label}: writer roster collides with primary-key pair")
  stream_files = Dir.children(shell_part).select { |name| name.ends_with?(".bin") || name.ends_with?(".mrk2") }.sort
  w127_require(stream_files == (files.file_names + pk_files).sort,
    "#{label}: fresh shell JSON/PK file inventory differs from complete writer roster")
  sidecars = Dir.children(shell_part).reject { |name| name.ends_with?(".bin") || name.ends_with?(".mrk2") }.sort
  w127_require(sidecars == W127_SHELL_SIDECARS.sort, "#{label}: fresh shell sidecar inventory changed: #{sidecars.inspect}")
  w127_require(File.read(File.join(shell_part, "count.txt")).strip == "8", "#{label}: matching shell count sidecar is not eight")

  detached = File.join(w127_table_data_path(binary, store, table_target), "detached")
  FileUtils.mkdir_p(detached)
  w127_store_child(detached, store, "#{label} detached directory")
  copied_part = File.join(detached, shell_part_name)
  w127_require(!File.exists?(copied_part) && !File.symlink?(detached), "#{label}: detached part path is occupied/unsafe")
  FileUtils.cp_r(shell_part, copied_part)
  copied_part = w127_store_child(copied_part, store, "#{label} copied shell")
  w127_assert_tree(copied_part, "#{label} copied shell")
  before_names = Dir.children(copied_part).sort

  # The production writer owns every JSON output placement. No fixture-derived
  # map or shell JSON lane is retained; exact roster equality was established
  # above before any file was replaced.
  files.file_names.each do |name|
    w127_require(name == File.basename(name) && !File.symlink?(File.join(copied_part, name)),
      "#{label}: unsafe production writer filename #{name.inspect}")
    File.write(File.join(copied_part, name), files.file_bytes(name))
    w127_require(File.read(File.join(copied_part, name)).to_slice == files.file_bytes(name),
      "#{label}: production output was not installed byte-for-byte for #{name}")
  end
  changed = files.file_names
  w127_rewrite_checksums(copied_part, changed)
  w127_assert_tree(copied_part, "#{label} rewritten part")
  w127_require(Dir.children(copied_part).sort == before_names, "#{label}: rewrite changed part inventory")

  w127_run(binary, store, "ALTER TABLE default.#{table_target} ATTACH PART '#{shell_part_name}'")
  attached_name, attached_part = w127_part(binary, store, table_target, "#{label} attached part")
  w127_require(attached_name == shell_part_name, "#{label}: attached part identity changed")
  w127_require(Dir.children(attached_part).sort == (before_names + ["invalidated_system_columns.txt"]).sort,
    "#{label}: ATTACH changed more than the expected invalidation marker")
  checksums = CrystalClick::PartChecksums.open(attached_part)
  checksums.entries.keys.each { |name| checksums.validate_selected_entries(attached_part, name) }

  actual_full = w127_read(attached_part, profile, 0, 4)
  w127_assert_granules(documents, actual_full, "#{label} W126 reader full")
  actual_middle = w127_read(attached_part, profile, 1, 2)
  w127_assert_granules(documents[1, 2], actual_middle, "#{label} W126 reader marks 1..2")
  actual_zero = w127_read(attached_part, profile, 4, 0)
  w127_assert_granules([] of Array(CrystalClick::ObjectDocument), actual_zero, "#{label} W126 reader terminal zero window")
  w127_stock_queries(binary, store, table_target, profile, label)
  puts "PASS W127 fresh production Object column writer + stock ATTACH/CHECK=1/full/pk3..6 + W126 full/middle/zero: #{profile}/#{mode_name} part=#{attached_name}"
end

def w127_expect_comparator_controls : Nil
  document = CrystalClick::ObjectDocument.new({"x" => CrystalClick::BinaryValue.uint64(1_u64)})
  wrong = CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)
  begin
    w127_assert_equal_documents([document], [wrong], "W127 wrong-document control")
  rescue error : W127Mismatch
    w127_require(error.message.to_s.starts_with?("W127 wrong-document control: paths differ"),
      "W127 wrong-document control failed unexpectedly")
  else
    w127_fail("W127 wrong document was accepted")
  end
  begin
    w127_assert_check("w127_control\t0\t\n", "w127_control", "W127 CHECK=0 control")
  rescue error : W127Mismatch
    w127_require(error.message.to_s.starts_with?("W127 CHECK=0 control: CHECK output mismatch"),
      "W127 CHECK=0 control failed unexpectedly")
  else
    w127_fail("W127 CHECK=0 was accepted")
  end
  begin
    w127_assert_granules([[document], [document]], [[document, document]], "W127 wrong-grid control")
  rescue error : W127Mismatch
    w127_require(error.message.to_s.starts_with?("W127 wrong-grid control: granule count differs"),
      "W127 wrong-grid control failed unexpectedly")
  else
    w127_fail("W127 wrong grid was accepted")
  end
  puts "PASS W127 wrong-document, wrong-grid and CHECK=0 comparator controls"
end

def w127_check : Nil
  binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
  root = ENV["W127_TMP_ROOT"]? || raise "W127_TMP_ROOT is required"
  w127_require(!File.symlink?(root) && Dir.exists?(root), "W127 temporary root must be an existing non-symlink directory")
  root = File.realpath(root)
  w127_require(root.starts_with?("/private/tmp/crystal-click-json-w127."), "unsafe W127 temporary root")
  w127_require(W123ObjectVectors::PROFILES.to_a.sort == ["dynamic_paths", "typed_mixed"].sort,
    "W127 W123 authored profile inventory changed")
  w127_require(W115_SEMANTIC_PAYLOADS.size == 8 && W127_JSON_ROWS.size == 8,
    "W127 literal source/readback row count changed")

  bootstrap_store = File.join(root, "bootstrap")
  FileUtils.mkdir_p(bootstrap_store)
  w127_run(binary, bootstrap_store, "SELECT 1")
  w127_verify_runtime(binary, bootstrap_store)
  w127_expect_comparator_controls
  {"dynamic_paths", "typed_mixed"}.each do |profile|
    {"basic"   => CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
     "compact" => CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE}.each do |mode_name, mode|
      w127_case(binary, root, profile, mode_name, mode)
    end
  end
  puts "PASS W127 scope: fresh matching Wide shells, production-created complete Object/Dynamic MAP V3 column files, no schema-sidecar synthesis or publication claim"
end

w127_check
