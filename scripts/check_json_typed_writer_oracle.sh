#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse
TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-json-typed-writer-oracle.XXXXXX)"
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

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_json_typed_writer_oracle.cr" <<'CRYSTAL'
require "json"
require "../src/crystal_click"

def run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(
    binary,
    ["local", "--path", store, "--query", query],
    output: output,
    error: Process::Redirect::Inherit
  )
  raise "ClickHouse local query failed (status #{status.exit_code})" unless status.success?
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
  values : Array(Tuple(UInt64, String)),
  range_only : Bool,
) : Bytes
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    next if range_only && (key < 2_u64 || key >= 9_u64)
    a_value, b_value = values[index]
    output.write_bytes(key, IO::ByteFormat::LittleEndian)
    output.write_bytes(a_value, IO::ByteFormat::LittleEndian)
    b_bytes = b_value.to_slice
    write_var_uint(output, b_bytes.size.to_u64)
    output.write(b_bytes)
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

def assert_shared_empty_shape(part : String, groups : Array(UInt64)) : Nil
  expected_marks = (groups + [0_u64]).map { |count| {0_u64, 0_u64, count} }
  ["j.object_shared_data.0%2Epaths", "j.object_shared_data.0%2Evalues"].each do |logical_name|
    path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
    raise "#{logical_name}: expected a zero-byte stream" unless File.size(path) == 0
    actual_marks = read_mark_triples(part, logical_name)
    raise "#{logical_name}: empty shared stream marks differ: #{actual_marks.inspect}" unless actual_marks == expected_marks
  end

  size0 = decode_stream(part, "j.object_shared_data.0.size0")
  expected_size = groups.reduce(0) { |total, count| total + count.to_i } * 8
  raise "shared size0 stream has #{size0.size} bytes, expected #{expected_size}" unless size0.size == expected_size
  raise "shared size0 stream contains a nonzero byte" unless size0.all?(&.zero?)
end

def write_json_part(
  destination : String,
  keys : Array(UInt64),
  values : Array(Tuple(UInt64, String)),
  rows_per_mark : Int32,
  key_name : String = "pk",
  value_name : String = "j",
) : String
  CrystalClick::WidePartWriter.write_uint64_json_typed_a_uint64_b_string_pair(
    destination,
    key_name,
    keys.to_unsafe.to_slice(keys.size),
    value_name,
    values,
    rows_per_mark: rows_per_mark
  )
end

def assert_rejected_without_publication(
  root : String,
  label : String,
  key_name : String,
  keys : Array(UInt64),
  value_name : String,
  values : Array(Tuple(UInt64, String)),
) : Nil
  parent = File.join(root, "invalid_#{label}")
  Dir.mkdir(parent)
  destination = File.join(parent, "part")
  begin
    begin
      write_json_part(destination, keys, values, 2, key_name, value_name)
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
keys = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64]
values = [
  {10_u64, "alpha"},
  {0_u64, ""},
  {30_u64, "x\0y"},
  {40_u64, ""},
  {50_u64, "é"},
] of Tuple(UInt64, String)
part = File.join(root, "json_typed_part")
write_json_part(part, keys, values, 2)

run_clickhouse(binary, store, <<-SQL)
CREATE TABLE default.json_typed_writer_oracle
(
    pk UInt64,
    j JSON(a UInt64, b String)
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
  "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = 'json_typed_writer_oracle' FORMAT TSVRaw"
).strip
raise "ClickHouse returned no data path" if data_path.empty?
detached = File.join(data_path, "detached")
FileUtils.mkdir_p(detached)
FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
run_clickhouse(binary, store, "ALTER TABLE default.json_typed_writer_oracle ATTACH PART 'all_1_1_0'")

typed_query = "SELECT pk, j.a, j.b FROM default.json_typed_writer_oracle ORDER BY pk FORMAT RowBinary"
typed_actual = run_clickhouse(binary, store, typed_query).to_slice
raise "full typed-path RowBinary differs from positional input" unless typed_actual == expected_rowbinary(keys, values, false)

range_query = "SELECT pk, j.a, j.b FROM default.json_typed_writer_oracle WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT RowBinary"
range_actual = run_clickhouse(binary, store, range_query).to_slice
raise "key-range typed-path RowBinary differs from positional input" unless range_actual == expected_rowbinary(keys, values, true)

whole_rows = run_clickhouse(
  binary,
  store,
  "SELECT pk, j FROM default.json_typed_writer_oracle ORDER BY pk FORMAT JSONEachRow"
).lines
raise "whole-object JSONEachRow row count differs" unless whole_rows.size == keys.size
whole_rows.each_with_index do |line, index|
  row = JSON.parse(line).as_h
  raise "whole-object JSONEachRow key differs at row #{index}" unless row["pk"].as_i.to_u64 == keys[index]
  object = row["j"].as_h
  raise "whole-object JSONEachRow paths differ at row #{index}" unless object.keys.sort == ["a", "b"]
  raise "whole-object normalized a differs at row #{index}" unless object["a"].as_i.to_u64 == values[index][0]
  raise "whole-object normalized b differs at row #{index}" unless object["b"].as_s == values[index][1]
end

integrity = run_clickhouse(binary, store, "CHECK TABLE default.json_typed_writer_oracle FORMAT TabSeparated").strip
raise "ClickHouse CHECK TABLE failed: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"

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
assert_shared_empty_shape(part, [2_u64, 2_u64, 1_u64])

puts "PASS ClickHouse #{binary}: attached JSON(a UInt64, b String), exact full/range typed RowBinary, normalized whole-object JSONEachRow, three granules with a short final granule, pinned Object V3/shared marks and streams, and CHECK TABLE"

empty_keys = [3_u64, 5_u64, 8_u64]
empty_values = [
  {11_u64, ""},
  {0_u64, ""},
  {19_u64, ""},
] of Tuple(UInt64, String)
empty_part = File.join(root, "json_typed_empty_b_part")
write_json_part(empty_part, empty_keys, empty_values, 2)

run_clickhouse(binary, store, <<-SQL)
CREATE TABLE default.json_typed_writer_empty_b_oracle
(
    pk UInt64,
    j JSON(a UInt64, b String)
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

empty_data_path = run_clickhouse(
  binary,
  store,
  "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = 'json_typed_writer_empty_b_oracle' FORMAT TSVRaw"
).strip
raise "ClickHouse returned no all-empty-b data path" if empty_data_path.empty?
empty_detached = File.join(empty_data_path, "detached")
FileUtils.mkdir_p(empty_detached)
FileUtils.cp_r(empty_part, File.join(empty_detached, "all_1_1_0"))
run_clickhouse(binary, store, "ALTER TABLE default.json_typed_writer_empty_b_oracle ATTACH PART 'all_1_1_0'")

b_path = File.join(empty_part, "#{CrystalClick::StreamName.hash("j.b")}.bin")
raise "all-empty b payload must have a zero-byte stream" unless File.size(b_path) == 0
expected_empty_b_marks = [
  {0_u64, 0_u64, 2_u64},
  {0_u64, 0_u64, 1_u64},
  {0_u64, 0_u64, 0_u64},
]
empty_b_marks = read_mark_triples(empty_part, "j.b")
raise "all-empty b marks differ: #{empty_b_marks.inspect}" unless empty_b_marks == expected_empty_b_marks
assert_shared_empty_shape(empty_part, [2_u64, 1_u64])

empty_actual = run_clickhouse(
  binary,
  store,
  "SELECT pk, j.a, j.b FROM default.json_typed_writer_empty_b_oracle ORDER BY pk FORMAT RowBinary"
).to_slice
raise "all-empty b typed-path RowBinary differs" unless empty_actual == expected_rowbinary(empty_keys, empty_values, false)
empty_integrity = run_clickhouse(binary, store, "CHECK TABLE default.json_typed_writer_empty_b_oracle FORMAT TabSeparated").strip
raise "all-empty b CHECK TABLE failed: #{empty_integrity.inspect}" unless empty_integrity == "all_1_1_0\t1"
puts "PASS all-empty b stream and marks attach and read correctly on ClickHouse"

one_key = [1_u64]
one_value = [{1_u64, "x"}] of Tuple(UInt64, String)
assert_rejected_without_publication(root, "invalid_key_name", "../pk", one_key, "j", one_value)
assert_rejected_without_publication(root, "unequal_rows", "pk", one_key, "j", [] of Tuple(UInt64, String))
assert_rejected_without_publication(root, "unsorted_keys", "pk", [2_u64, 1_u64], "j", [{1_u64, "x"}, {2_u64, "y"}] of Tuple(UInt64, String))

existing_parent = File.join(root, "invalid_existing_destination")
Dir.mkdir(existing_parent)
existing_destination = File.join(existing_parent, "part")
Dir.mkdir(existing_destination)
marker = File.join(existing_destination, "keep.txt")
File.write(marker, "preserve")
begin
  begin
    write_json_part(existing_destination, one_key, one_value, 2)
  rescue ArgumentError
    # Expected: exclusive publication preserves the existing destination.
  else
    raise "pre-existing destination was accepted"
  end
  raise "pre-existing destination marker changed" unless File.read(marker) == "preserve"
  raise "pre-existing destination gained entries" unless Dir.children(existing_destination) == ["keep.txt"]
ensure
  # This destination is under TMP_ROOT and is removed by the outer trap.
end

puts "PASS invalid names, unequal rows, unsorted keys, and existing destinations reject without publication"
CRYSTAL
