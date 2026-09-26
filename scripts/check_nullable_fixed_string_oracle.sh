#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"

if ! command -v "$CLICKHOUSE_BIN" >/dev/null 2>&1; then
  printf 'ClickHouse executable not found: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi

EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-nullable-fixed-string-oracle.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_nullable_fixed_string_oracle.cr" <<'CRYSTAL'
require "../src/crystal_click"

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

def stream_path(part : String, logical_name : String) : String
  File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
end

def bytes_hex(value : String) : String
  value.to_slice.map { |byte| byte.to_s(16).upcase.rjust(2, '0') }.join
end

def create_table(binary : String, store : String, table : String) : Nil
  run_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      pk UInt64,
      payload Nullable(FixedString(3))
  )
  ENGINE = MergeTree
  ORDER BY pk
  SETTINGS
      index_granularity = 2,
      enable_mixed_granularity_parts = 1,
      min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0,
      compress_marks = 0,
      min_compress_block_size = 0,
      max_compress_block_size = 4096,
      ratio_of_defaults_for_sparse_serialization = 1.0;
  SQL
end

def verify_two_stream_shape(part : String, expected_marks : Array(UInt64)) : CrystalClick::WidePart
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `payload`:\n\tpayload.null\n\tpayload\n"
  observed_substreams = File.read(File.join(part, "columns_substreams.txt"))
  raise "Nullable(FixedString(3)) substreams differ: #{observed_substreams.inspect}" unless observed_substreams == expected_substreams
  raise "Nullable(FixedString(3)) .size stream exists" if File.exists?(stream_path(part, "payload.size"))
  raise "Nullable(FixedString(3)) codec is not LZ4" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"

  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "selected column type differs: #{reader.column_type}" unless reader.column_type == "Nullable(FixedString(3))"
  raise "Nullable(FixedString(3)) mark rows differ: #{reader.mark_row_counts.inspect}" unless reader.mark_row_counts == expected_marks
  reader
end

def verify_stock_reader(binary : String, store : String, root : String) : Nil
  create_table(binary, store, "nullable_fixed_source")
  run_clickhouse(binary, store, <<-SQL)
  INSERT INTO default.nullable_fixed_source
  SELECT pk, if(pk IN (1, 12), CAST(NULL, 'Nullable(FixedString(3))'), toFixedString(unhex(raw), 3))
  FROM values('pk UInt64, raw String',
      (1, ''),
      (2, ''),
      (4, '61'),
      (6, '414243'),
      (9, '610062'),
      (10, 'FF00FE'),
      (12, ''));
  SQL

  source_path = run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = 'nullable_fixed_source' AND active FORMAT TSVRaw").strip
  raise "stock Nullable(FixedString(3)) part path is missing" if source_path.empty?
  stock_part = File.join(root, "stock-part")
  FileUtils.cp_r(source_path, stock_part)

  reader = verify_two_stream_shape(stock_part, [2_u64, 2_u64, 2_u64, 1_u64])
  raise "stock row count differs" unless reader.row_count == 7_u64
  null_map = CrystalClick::CompressedBlock.decode_all(File.read(stream_path(stock_part, "payload.null")).to_slice)
  raise "stock null-map bytes differ: #{null_map.to_a.inspect}" unless null_map.to_a == [1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8]
  nested = CrystalClick::CompressedBlock.decode_all(File.read(stream_path(stock_part, "payload")).to_slice)
  raise "stock nested stream is not 3 bytes per row" unless nested.size == 21
  non_null_hex = {1 => "000000", 2 => "610000", 3 => "414243", 4 => "610062", 5 => "FF00FE"}
  non_null_hex.each do |index, expected|
    actual = bytes_hex(String.new(nested[index * 3, 3]))
    raise "stock nested row #{index} differs: #{actual}" unless actual == expected
  end

  expected = [nil, "\0\0\0", "a\0\0", "ABC", "a\0b", String.new(Bytes[0xff_u8, 0_u8, 0xfe_u8]), nil] of String?
  observed = reader.read_nullable_fixed_string_mark_range("payload", 0, reader.mark_count)
  raise "stock Nullable(FixedString(3)) values differ: #{observed.map { |value| value.try { |item| bytes_hex(item) } }.inspect}" unless observed == expected
  middle = reader.read_nullable_fixed_string_mark_range("payload", 1, 2)
  raise "stock middle marks differ" unless middle == expected[2, 4]

  puts "PASS stock Nullable(FixedString(3)) reader: two streams, mark rows [2, 2, 2, 1], exact NULL/empty/padded/NUL/invalid-UTF8 bytes"
end

def attach_part(binary : String, store : String, table : String, part : String) : String
  create_table(binary, store, table)
  data_path = run_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse returned no data path" if data_path.empty?
  FileUtils.mkdir_p(File.join(data_path, "detached"))
  FileUtils.cp_r(part, File.join(data_path, "detached", "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  File.join(data_path, "all_1_1_0")
end

def assert_rows(binary : String, store : String, table : String, expected_full : String, expected_range : String) : Nil
  projection = "pk, isNull(payload), hex(ifNull(payload, toFixedString('', 3)))"
  actual = run_clickhouse(binary, store, "SELECT #{projection} FROM default.#{table} ORDER BY pk FORMAT TabSeparated")
  raise "#{table}: full rows differ; expected #{expected_full.inspect}, got #{actual.inspect}" unless actual == expected_full
  ranged = run_clickhouse(binary, store, "SELECT #{projection} FROM default.#{table} WHERE pk >= 2 AND pk < 12 ORDER BY pk FORMAT TabSeparated")
  raise "#{table}: key-range rows differ; expected #{expected_range.inspect}, got #{ranged.inspect}" unless ranged == expected_range
end

def assert_check_table(binary : String, store : String, table : String) : Nil
  result = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: CHECK TABLE failed: #{result.inspect}" unless result == "all_1_1_0\t1"
end

def assert_stream_corruption(binary : String, store : String, table : String, attached_part : String, logical_name : String) : Nil
  path = stream_path(attached_part, logical_name)
  original = File.open(path, "r") { |file| file.read_byte || raise "#{logical_name} stream is empty" }
  damaged = ""
  begin
    File.open(path, "r+") do |file|
      file.pos = 0
      file.write_byte(original ^ 1_u8)
    end
    damaged = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  ensure
    File.open(path, "r+") do |file|
      file.pos = 0
      file.write_byte(original)
    end
  end
  fields = damaged.split('\t', 3)
  unless fields.size == 3 && fields[0] == "all_1_1_0" && fields[1] == "0" && fields[2].includes?("CHECKSUM_DOESNT_MATCH")
    raise "#{table}: CHECK TABLE missed #{logical_name} corruption: #{damaged.inspect}"
  end
  assert_check_table(binary, store, table)
end

def write_hash128(bytes : Bytes, hash : {UInt64, UInt64}) : Nil
  hash.each_with_index do |word, word_index|
    8.times do |byte_index|
      bytes[word_index * 8 + byte_index] = ((word >> (byte_index * 8)) & 0xff_u64).to_u8
    end
  end
end

def assert_invalid_null_flag(part : String, root : String) : Nil
  malformed = File.join(root, "invalid-null-flag")
  FileUtils.cp_r(part, malformed)
  null_path = stream_path(malformed, "payload.null")
  encoded = File.read(null_path).to_slice.dup
  unless encoded.size >= 28 && encoded[16] == CrystalClick::CompressedBlock::METHOD_LZ4 && encoded[25] == 0x20_u8 && encoded[26] == 1_u8
    raise "writer null-map first frame is not the expected two-row literal LZ4 frame"
  end
  encoded[26] = 2_u8
  write_hash128(encoded, CrystalClick::CityHashV1.hash128(encoded[16, 12]))
  File.write(null_path, encoded)

  begin
    reader = CrystalClick::WidePart.open_typed(malformed, "payload")
    reader.read_nullable_fixed_string_mark_range("payload", 0, 1)
    raise "Nullable(FixedString(3)) reader accepted a null-map byte of 2"
  rescue ex : CrystalClick::CorruptPartError
    raise "invalid null flag failed for a different reason: #{ex.message}" unless ex.message.to_s.includes?("null-map")
  end
end

def verify_writer(binary : String, store : String, root : String) : Nil
  keys = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 10_u64, 12_u64]
  values = [nil, "", "a", "ABC", "a\0b", String.new(Bytes[0xff_u8, 0_u8, 0xfe_u8]), nil] of String?
  part = File.join(root, "writer-part")
  CrystalClick::WidePartWriter.write_uint64_nullable_fixed_string_pair(
    part,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    values.to_unsafe.to_slice(values.size),
    width: 3,
    rows_per_mark: 2
  )
  verify_two_stream_shape(part, [2_u64, 2_u64, 2_u64, 1_u64])
  null_map = CrystalClick::CompressedBlock.decode_all(File.read(stream_path(part, "payload.null")).to_slice)
  raise "writer null-map bytes differ" unless null_map.to_a == [1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8]
  nested = CrystalClick::CompressedBlock.decode_all(File.read(stream_path(part, "payload")).to_slice)
  expected_nested = "\0\0\0\0\0\0a\0\0ABCa\0b".to_slice.to_a + [0xff_u8, 0_u8, 0xfe_u8] + [0_u8, 0_u8, 0_u8]
  raise "writer nested bytes differ: #{nested.to_a.inspect}" unless nested.to_a == expected_nested

  attached = attach_part(binary, store, "nullable_fixed_writer", part)
  expected_full = "1\t1\t000000\n2\t0\t000000\n4\t0\t610000\n6\t0\t414243\n9\t0\t610062\n10\t0\tFF00FE\n12\t1\t000000\n"
  expected_range = "2\t0\t000000\n4\t0\t610000\n6\t0\t414243\n9\t0\t610062\n10\t0\tFF00FE\n"
  assert_rows(binary, store, "nullable_fixed_writer", expected_full, expected_range)
  assert_check_table(binary, store, "nullable_fixed_writer")
  assert_stream_corruption(binary, store, "nullable_fixed_writer", attached, "payload")
  assert_stream_corruption(binary, store, "nullable_fixed_writer", attached, "payload.null")
  assert_invalid_null_flag(part, root)

  all_null_keys = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64]
  all_null_values = Array(String?).new(5, nil)
  all_null_part = File.join(root, "writer-all-null-part")
  CrystalClick::WidePartWriter.write_uint64_nullable_fixed_string_pair(
    all_null_part,
    "pk",
    all_null_keys.to_unsafe.to_slice(all_null_keys.size),
    "payload",
    all_null_values.to_unsafe.to_slice(all_null_values.size),
    width: 3,
    rows_per_mark: 2
  )
  verify_two_stream_shape(all_null_part, [2_u64, 2_u64, 1_u64])
  all_null_map = CrystalClick::CompressedBlock.decode_all(File.read(stream_path(all_null_part, "payload.null")).to_slice)
  raise "all-NULL control flags differ" unless all_null_map.to_a == [1_u8, 1_u8, 1_u8, 1_u8, 1_u8]
  all_null_nested = CrystalClick::CompressedBlock.decode_all(File.read(stream_path(all_null_part, "payload")).to_slice)
  raise "all-NULL control nested slots are not zero" unless all_null_nested.to_a == Array(UInt8).new(15, 0_u8)
  attach_part(binary, store, "nullable_fixed_all_null", all_null_part)
  all_null_full = "1\t1\t000000\n2\t1\t000000\n4\t1\t000000\n6\t1\t000000\n9\t1\t000000\n"
  all_null_range = "2\t1\t000000\n4\t1\t000000\n6\t1\t000000\n9\t1\t000000\n"
  assert_rows(binary, store, "nullable_fixed_all_null", all_null_full, all_null_range)
  assert_check_table(binary, store, "nullable_fixed_all_null")

  puts "PASS Nullable(FixedString(3)) writer: two streams, exact full/key-range null and hex rows, CHECK TABLE, payload/null-map corruption, invalid null flag, all-NULL control"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")
verify_stock_reader(binary, store, root)
verify_writer(binary, store, root)
CRYSTAL

printf 'PASS Nullable(FixedString(3)) differential oracle on ClickHouse %s\n' "$ACTUAL_VERSION"
