#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-fixed-string-oracle.XXXXXX")"
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

STORE="$TMP_ROOT/clickhouse-store"
STOCK_PART="$TMP_ROOT/stock-part"
WRITER_PART="$TMP_ROOT/writer-part"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
CREATE TABLE default.fixed_string_source
(
    pk UInt64,
    payload FixedString(3)
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

INSERT INTO default.fixed_string_source
SELECT pk, toFixedString(unhex(raw), 3)
FROM values('pk UInt64, raw String',
    (1, '61'),
    (2, '780079'),
    (4, '414243'),
    (6, 'c3a9'),
    (9, '00'));
"

SOURCE_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT path FROM system.parts WHERE database = 'default' AND table = 'fixed_string_source' AND active FORMAT TSVRaw")"
if [[ -z "$SOURCE_PATH" ]]; then
  printf 'ClickHouse did not report the stock FixedString part path\n' >&2
  exit 1
fi
cp -R "$SOURCE_PATH" "$STOCK_PART"

cd "$ROOT"
export CLICKHOUSE_BIN STORE STOCK_PART WRITER_PART
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_fixed_string_oracle.cr" <<'CRYSTAL'
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

def bytes_hex(value : String) : String
  value.to_slice.map { |byte| byte.to_s(16).upcase.rjust(2, '0') }.join
end

def verify_stock_reader(stock_part : String) : Nil
  reader = CrystalClick::WidePart.open_typed(stock_part, "payload")
  expected_rows = [2_u64, 2_u64, 1_u64]
  raise "stock FixedString marks differ: #{reader.mark_row_counts.inspect}" unless reader.mark_row_counts == expected_rows

  expected = ["a\x00\x00", "x\x00y", "ABC", "é\x00", "\x00\x00\x00"]
  actual = reader.read_fixed_string_mark_range("payload", 0, reader.mark_count)
  unless actual == expected
    raise "stock FixedString reader bytes differ; expected #{expected.map { |value| bytes_hex(value) }.inspect}, got #{actual.map { |value| bytes_hex(value) }.inspect}"
  end

  second_mark = reader.read_fixed_string_mark_range("payload", 1, 1)
  raise "stock FixedString mark-range bytes differ: #{second_mark.map { |value| bytes_hex(value) }.inspect}" unless second_mark == expected[2, 2]

  puts "PASS stock FixedString(3) reader: mark rows [2, 2, 1], exact NUL/padding/UTF-8 bytes, and cross-mark range"
end

def verify_writer(binary : String, store : String, writer_part : String) : Nil
  keys = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64]
  inputs = ["a", "x\x00y", "ABC", "é", "\x00"]
  CrystalClick::WidePartWriter.write_uint64_fixed_string_pair(
    writer_part,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    inputs.to_unsafe.to_slice(inputs.size),
    width: 3,
    rows_per_mark: 2
  )

  run_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.fixed_string_writer
  (
      pk UInt64,
      payload FixedString(3)
  )
  ENGINE = MergeTree
  ORDER BY pk
  SETTINGS
      index_granularity = 2,
      enable_mixed_granularity_parts = 1,
      min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0,
      compress_marks = 0,
      ratio_of_defaults_for_sparse_serialization = 1.0;
  SQL

  data_path = run_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = 'fixed_string_writer' FORMAT TSVRaw"
  ).strip
  raise "ClickHouse returned no writer target data path" if data_path.empty?

  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(writer_part, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.fixed_string_writer ATTACH PART 'all_1_1_0'")

  expected_full = "1\t610000\n2\t780079\n4\t414243\n6\tC3A900\n9\t000000\n"
  full = run_clickhouse(
    binary,
    store,
    "SELECT pk, hex(payload) FROM default.fixed_string_writer ORDER BY pk FORMAT TabSeparatedRaw"
  )
  raise "attached FixedString full rows differ: #{full.inspect}" unless full == expected_full

  expected_range = "2\t780079\n4\t414243\n6\tC3A900\n"
  range = run_clickhouse(
    binary,
    store,
    "SELECT pk, hex(payload) FROM default.fixed_string_writer WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT TabSeparatedRaw"
  )
  raise "attached FixedString key-range rows differ: #{range.inspect}" unless range == expected_range

  integrity = run_clickhouse(binary, store, "CHECK TABLE default.fixed_string_writer FORMAT TabSeparated").strip
  raise "attached FixedString CHECK TABLE failed: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"

  logical_name = "#{CrystalClick::StreamName.hash("payload")}.bin"
  payload_path = File.join(data_path, "all_1_1_0", logical_name)
  original = File.open(payload_path, "r") do |file|
    file.read_byte || raise "writer FixedString payload stream is empty"
  end
  damaged = ""
  begin
    File.open(payload_path, "r+") do |file|
      file.pos = 0
      file.write_byte(original ^ 1_u8)
    end
    damaged = run_clickhouse(binary, store, "CHECK TABLE default.fixed_string_writer FORMAT TabSeparated").strip
  ensure
    File.open(payload_path, "r+") do |file|
      file.pos = 0
      file.write_byte(original)
    end
  end

  restored = run_clickhouse(binary, store, "CHECK TABLE default.fixed_string_writer FORMAT TabSeparated").strip
  raise "writer FixedString CHECK TABLE still fails after restoring payload: #{restored.inspect}" unless restored == "all_1_1_0\t1"
  fields = damaged.split('\t', 3)
  unless fields.size == 3 && fields[0] == "all_1_1_0" && fields[1] == "0" && fields[2].includes?("CHECKSUM_DOESNT_MATCH")
    raise "writer FixedString CHECK TABLE missed payload corruption: #{damaged.inspect}"
  end

  puts "PASS FixedString(3) writer: ATTACH PART, exact full/key-range hex rows, CHECK TABLE, and checksum corruption negative control"
end

verify_stock_reader(ENV.fetch("STOCK_PART"))
verify_writer(ENV.fetch("CLICKHOUSE_BIN"), ENV.fetch("STORE"), ENV.fetch("WRITER_PART"))
CRYSTAL

printf 'PASS FixedString(3) reader/writer oracle on ClickHouse %s\n' "$ACTUAL_VERSION"
