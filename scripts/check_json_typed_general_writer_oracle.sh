#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse
TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-json-typed-general-writer-oracle.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable not found or not executable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi

EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_json_typed_general_writer_oracle.cr" <<'CRYSTAL'
require "json"
require "file_utils"
require "../src/crystal_click"

alias JSONTypedPathColumn = CrystalClick::WidePartWriter::JSONTypedPathColumn

def run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(
    binary,
    ["local", "--path", store, "--query", query],
    output: output,
    error: Process::Redirect::Inherit
  )
  raise "ClickHouse local query failed (status #{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def write_var_uint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def expected_rowbinary(
  keys : Array(UInt64),
  a_values : Array(Int16),
  m_values : Array(Float32),
  z_values : Array(String),
  range_only : Bool,
) : Bytes
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    next if range_only && (key < 2_u64 || key >= 9_u64)
    output.write_bytes(key, IO::ByteFormat::LittleEndian)
    output.write_bytes(a_values[index], IO::ByteFormat::LittleEndian)
    output.write_bytes(m_values[index].unsafe_as(UInt32), IO::ByteFormat::LittleEndian)
    value_bytes = z_values[index].to_slice
    write_var_uint(output, value_bytes.size.to_u64)
    output.write(value_bytes)
  end
  output.to_slice
end

def read_uint64_le(bytes : Bytes, offset : Int) : UInt64
  raise "truncated UInt64 at byte #{offset}" if offset < 0 || offset > bytes.size - 8
  value = 0_u64
  8.times do |index|
    value |= bytes[offset + index].to_u64 << (index * 8)
  end
  value
end

def read_mark_triples(part : String, logical_name : String) : Array(Tuple(UInt64, UInt64, UInt64))
  mark_path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  bytes = File.read(mark_path).to_slice
  raise "#{logical_name}: plain .mrk2 size is not a multiple of 24 bytes" unless bytes.size % 24 == 0

  records = [] of Tuple(UInt64, UInt64, UInt64)
  (bytes.size // 24).times do |index|
    offset = index * 24
    records << {
      read_uint64_le(bytes, offset),
      read_uint64_le(bytes, offset + 8),
      read_uint64_le(bytes, offset + 16),
    }
  end
  records
end

def decode_stream(part : String, logical_name : String) : Bytes
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  compressed = File.read(path).to_slice
  raise "#{logical_name}: expected a nonempty compressed stream" if compressed.empty?
  # Decode compression frames only. Stock ClickHouse attach, reads, and CHECK TABLE
  # remain the format oracle; no Crystal part reader is used to establish semantics.
  CrystalClick::CompressedBlock.decode_all(compressed)
end

def expected_checksum_inventory(key_name : String, value_name : String) : Array(String)
  logical_streams = [
    key_name,
    "#{value_name}.object_structure",
    "#{value_name}.a",
    "#{value_name}.m",
    "#{value_name}.z.size",
    "#{value_name}.z",
    "#{value_name}.object_shared_data.0.size0",
    "#{value_name}.object_shared_data.0%2Epaths",
    "#{value_name}.object_shared_data.0%2Evalues",
  ]
  stream_files = logical_streams.flat_map do |logical_name|
    hash = CrystalClick::StreamName.hash(logical_name)
    ["#{hash}.bin", "#{hash}.mrk2"]
  end
  (stream_files + ["count.txt", "primary.idx", "serialization.json"]).sort
end

def write_json_part(
  destination : String,
  keys : Array(UInt64),
  value_name : String,
  paths : Array(JSONTypedPathColumn),
  rows_per_mark : Int32,
  key_name : String = "pk",
) : String
  CrystalClick::WidePartWriter.write_uint64_json_typed_paths(
    destination,
    key_name,
    keys.to_unsafe.to_slice(keys.size),
    value_name,
    paths,
    rows_per_mark: rows_per_mark
  )
end

def assert_rejected_without_publication(
  root : String,
  label : String,
  key_name : String,
  keys : Array(UInt64),
  value_name : String,
  paths : Array(JSONTypedPathColumn),
) : Nil
  parent = File.join(root, "invalid_#{label}")
  Dir.mkdir(parent)
  destination = File.join(parent, "part")
  begin
    begin
      write_json_part(destination, keys, value_name, paths, 2, key_name)
    rescue ArgumentError
      # Expected: validation rejects before publication.
    else
      raise "#{label}: invalid input was accepted"
    end
    raise "#{label}: invalid input published a destination" if File.exists?(destination)
    raise "#{label}: invalid input left staged entries" unless Dir.children(parent).empty?
  ensure
    # This parent is under TMP_ROOT and is removed by the outer trap.
  end
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")
key_name = "pk"
value_name = "j"
keys = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64]
a_values = [11_i16, -2_i16, 32_767_i16, -32_768_i16, 0_i16]
m_values = [1.25_f32, -0.5_f32, 3.5_f32, 0.0_f32, -4.25_f32]
z_values = ["alpha", "", "x\0y", "tail", ""]
paths = [
  JSONTypedPathColumn.new("z", "String", z_values),
  JSONTypedPathColumn.new("a", "Int16", a_values),
  JSONTypedPathColumn.new("m", "Float32", m_values),
]
part = File.join(root, "json_typed_general_part")
CrystalClick::WidePartWriter.write_uint64_json_typed_paths(
  part,
  key_name,
  keys.to_unsafe.to_slice(keys.size),
  value_name,
  paths,
  rows_per_mark: 2
)

run_clickhouse(binary, store, <<-SQL)
CREATE TABLE default.json_typed_general_writer_oracle
(
    pk UInt64,
    j JSON(z String, a Int16, m Float32)
)
ENGINE = MergeTree
ORDER BY pk
SETTINGS
    index_granularity = 2,
    index_granularity_bytes = 0,
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    compress_marks = 0,
    default_compression_codec = 'LZ4',
    ratio_of_defaults_for_sparse_serialization = 1.0;
SQL

data_path = run_clickhouse(
  binary,
  store,
  "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = 'json_typed_general_writer_oracle' FORMAT TSVRaw"
).strip
raise "ClickHouse returned no data path" if data_path.empty?
detached = File.join(data_path, "detached")
FileUtils.mkdir_p(detached)
FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
run_clickhouse(binary, store, "ALTER TABLE default.json_typed_general_writer_oracle ATTACH PART 'all_1_1_0'")

typed_actual = run_clickhouse(
  binary,
  store,
  "SELECT pk, j.a, j.m, j.z FROM default.json_typed_general_writer_oracle ORDER BY pk FORMAT RowBinary"
).to_slice
raise "full typed-path RowBinary differs from positional input" unless typed_actual == expected_rowbinary(keys, a_values, m_values, z_values, false)

range_actual = run_clickhouse(
  binary,
  store,
  "SELECT pk, j.a, j.m, j.z FROM default.json_typed_general_writer_oracle WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT RowBinary"
).to_slice
raise "key-range typed-path RowBinary differs from positional input" unless range_actual == expected_rowbinary(keys, a_values, m_values, z_values, true)

whole_rows = run_clickhouse(
  binary,
  store,
  "SELECT pk, j FROM default.json_typed_general_writer_oracle ORDER BY pk FORMAT JSONEachRow"
).lines
raise "whole-object JSONEachRow row count differs" unless whole_rows.size == keys.size
whole_rows.each_with_index do |line, index|
  row = JSON.parse(line).as_h
  raise "whole-object JSONEachRow key differs at row #{index}" unless row["pk"].as_i.to_u64 == keys[index]
  object = row["j"].as_h
  raise "whole-object JSONEachRow paths differ at row #{index}" unless object.keys.sort == ["a", "m", "z"]
  raise "whole-object normalized a differs at row #{index}" unless object["a"].as_i == a_values[index]
  raise "whole-object normalized m differs at row #{index}" unless object["m"].as_f == m_values[index].to_f64
  raise "whole-object normalized z differs at row #{index}" unless object["z"].as_s == z_values[index]
end

integrity = run_clickhouse(binary, store, "CHECK TABLE default.json_typed_general_writer_oracle FORMAT TabSeparated").strip
raise "ClickHouse CHECK TABLE failed: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"

columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
raise "columns.txt does not canonicalize typed paths by name: #{columns.inspect}" unless columns.last == "`j` JSON(a Int16, m Float32, z String)"

expected_substreams = [
  "j.object_structure",
  "j.a",
  "j.m",
  "j.z.size",
  "j.z",
  "j.object_shared_data.0.size0",
  "j.object_shared_data.0%2Epaths",
  "j.object_shared_data.0%2Evalues",
]
actual_substreams = File.read(File.join(part, "columns_substreams.txt")).lines.compact_map do |line|
  value = line.strip
  value if value.starts_with?("j.")
end
raise "JSON substream metadata differs: #{actual_substreams.inspect}" unless actual_substreams == expected_substreams

structure = decode_stream(part, "j.object_structure")
structure_hex = structure.map { |byte| byte.to_s(16).upcase.rjust(2, '0') }.join
raise "object_structure raw bytes differ: #{structure_hex}" unless structure_hex == "04000000000000000001010100"
expected_structure_marks = [
  {0_u64, 11_u64, 2_u64},
  {0_u64, 11_u64, 2_u64},
  {0_u64, 11_u64, 1_u64},
  {0_u64, 13_u64, 0_u64},
]
structure_marks = read_mark_triples(part, "j.object_structure")
raise "object_structure marks differ: #{structure_marks.inspect}" unless structure_marks == expected_structure_marks

expected_a = IO::Memory.new
a_values.each { |value| expected_a.write_bytes(value, IO::ByteFormat::LittleEndian) }
raise "Int16 path stream differs" unless decode_stream(part, "j.a") == expected_a.to_slice

expected_m = IO::Memory.new
m_values.each { |value| expected_m.write_bytes(value.unsafe_as(UInt32), IO::ByteFormat::LittleEndian) }
raise "Float32 path stream differs" unless decode_stream(part, "j.m") == expected_m.to_slice

expected_z_sizes = IO::Memory.new
z_values.each { |value| expected_z_sizes.write_bytes(value.bytesize.to_u64, IO::ByteFormat::LittleEndian) }
raise "String path size stream differs" unless decode_stream(part, "j.z.size") == expected_z_sizes.to_slice
raise "String path payload differs" unless decode_stream(part, "j.z") == z_values.join.to_slice

logical_streams = [
  key_name,
  "j.object_structure",
  "j.a",
  "j.m",
  "j.z.size",
  "j.z",
  "j.object_shared_data.0.size0",
  "j.object_shared_data.0%2Epaths",
  "j.object_shared_data.0%2Evalues",
]
expected_checksums = expected_checksum_inventory(key_name, value_name)
actual_checksums = CrystalClick::PartChecksums.open(part).entries.keys.sort
raise "checksum inventory differs: #{actual_checksums.inspect}" unless actual_checksums == expected_checksums
expected_part_files = (expected_checksums + [
  "checksums.txt",
  "columns.txt",
  "columns_substreams.txt",
  "default_compression_codec.txt",
  "metadata_version.txt",
]).sort
raise "part file inventory differs: #{Dir.children(part).sort.inspect}" unless Dir.children(part).sort == expected_part_files

puts "PASS ClickHouse #{binary}: declaration-order z/a/m maps to sorted a/m/z streams; exact full/range typed RowBinary, normalized whole-object JSONEachRow, Object V3 bytes and marks, String empty/NUL payloads, canonical metadata, exact checksum/file inventory, and CHECK TABLE"

one_key = [1_u64]
one_paths = [
  JSONTypedPathColumn.new("z", "String", ["x"] of String),
  JSONTypedPathColumn.new("a", "Int16", [1_i16]),
  JSONTypedPathColumn.new("m", "Float32", [1.0_f32]),
]
assert_rejected_without_publication(root, "invalid_key_name", "../pk", one_key, value_name, one_paths)
assert_rejected_without_publication(root, "unequal_path_rows", "pk", one_key, value_name, [
  JSONTypedPathColumn.new("z", "String", ["x"] of String),
  JSONTypedPathColumn.new("a", "Int16", [1_i16, 2_i16]),
])
assert_rejected_without_publication(root, "duplicate_path", "pk", one_key, value_name, [
  JSONTypedPathColumn.new("a", "Int16", [1_i16]),
  JSONTypedPathColumn.new("a", "Int16", [2_i16]),
])
assert_rejected_without_publication(root, "mismatched_path_type", "pk", one_key, value_name, [
  JSONTypedPathColumn.new("a", "Int16", [1_i32]),
])
assert_rejected_without_publication(root, "unsorted_keys", "pk", [2_u64, 1_u64], value_name, [
  JSONTypedPathColumn.new("z", "String", ["x", "y"] of String),
])

puts "PASS invalid names, path row-count mismatches, duplicate paths, mismatched scalar types, and unsorted keys reject without publishing a part"
CRYSTAL
