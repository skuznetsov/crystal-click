#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-clickhouse}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-typed-writer-oracle.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

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

cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_typed_writer_oracle.cr" <<'CRYSTAL'
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

def typed_oracle_value(value : T) : String forall T
  {% if T == String %}
    value.to_slice.map { |byte| byte.to_s(16).upcase.rjust(2, '0') }.join
  {% elsif T == Float32 %}
    value.unsafe_as(UInt32).to_s
  {% elsif T == Float64 %}
    value.unsafe_as(UInt64).to_s
  {% else %}
    value.to_s
  {% end %}
end

def typed_oracle_expected(
  keys : Array(UInt64),
  values : Array(T),
  type_name : String,
  nullable : Bool,
  range_only : Bool,
) : String forall T
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    next if range_only && (key < 2_u64 || key >= 9_u64)
    value = values[index]
    if nullable
      if value.nil?
        nested = type_name.includes?("String") ? "" : "0"
        output << key << '\t' << "1\t" << nested << '\n'
      else
        output << key << '\t' << "0\t" << typed_oracle_value(value) << '\n'
      end
    else
      output << key << '\t' << typed_oracle_value(value) << '\n'
    end
  end
  output.to_s
end

def expected_type_expression(type_name : String, nullable : Bool) : String
  base_type = nullable ? type_name.byte_slice("Nullable(".bytesize, type_name.bytesize - "Nullable()".bytesize) : type_name
  if base_type == "String"
    nullable ? "hex(ifNull(payload, ''))" : "hex(payload)"
  elsif base_type == "Float32"
    nullable ? "ifNull(reinterpretAsUInt32(payload), 0)" : "reinterpretAsUInt32(payload)"
  elsif base_type == "Float64"
    nullable ? "ifNull(reinterpretAsUInt64(payload), 0)" : "reinterpretAsUInt64(payload)"
  else
    nullable ? "ifNull(payload, 0)" : "payload"
  end
end

def verify_typed_shape(
  binary : String,
  store : String,
  root : String,
  label : String,
  type_name : String,
  values : Array(T),
  nullable : Bool,
  corrupt_logical_streams : Array(String),
) : Nil forall T
  keys = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64]
  raise "#{label}: fixture row count must be five" unless values.size == keys.size
  table = "typed_#{label}"
  part = File.join(root, "part_#{label}")
  CrystalClick::WidePartWriter.write_uint64_typed_pair(
    part,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    values.to_unsafe.to_slice(values.size),
    rows_per_mark: 2
  )

  run_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      `pk` UInt64,
      `payload` #{type_name}
  )
  ENGINE = MergeTree
  ORDER BY pk
  SETTINGS
      index_granularity = 2,
      index_granularity_bytes = 0,
      min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0,
      compress_marks = 0,
      ratio_of_defaults_for_sparse_serialization = 1.0;
  SQL

  data_path = run_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "#{label}: ClickHouse returned no data path" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")

  value_expression = expected_type_expression(type_name, nullable)
  selection = nullable ? "pk, isNull(payload), #{value_expression}" : "pk, #{value_expression}"
  actual = run_clickhouse(binary, store, "SELECT #{selection} FROM default.#{table} ORDER BY pk FORMAT TabSeparated")
  expected = typed_oracle_expected(keys, values, type_name, nullable, false)
  unless actual == expected
    raise "#{type_name} (#{label}) exact rows differ; expected #{expected.inspect}, got #{actual.inspect}"
  end

  indexed = run_clickhouse(
    binary,
    store,
    "SELECT #{selection} FROM default.#{table} WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT TabSeparated"
  )
  expected_indexed = typed_oracle_expected(keys, values, type_name, nullable, true)
  unless indexed == expected_indexed
    raise "#{type_name} (#{label}) key-range rows differ; expected #{expected_indexed.inspect}, got #{indexed.inspect}"
  end

  integrity = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{type_name} (#{label}) CHECK TABLE failed: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"

  corrupt_logical_streams.each do |corrupt_logical_stream|
    logical_name = "#{CrystalClick::StreamName.hash(corrupt_logical_stream)}.bin"
    corrupt_path = File.join(data_path, "all_1_1_0", logical_name)
    original = File.open(corrupt_path, "r") do |file|
      file.read_byte || raise "#{type_name} (#{label}) corruption target is empty: #{corrupt_logical_stream}"
    end
    damaged = ""
    begin
      File.open(corrupt_path, "r+") do |file|
        file.pos = 0
        file.write_byte(original ^ 1_u8)
      end
      damaged = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
    ensure
      File.open(corrupt_path, "r+") do |file|
        file.pos = 0
        file.write_byte(original)
      end
    end

    restored = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
    raise "#{type_name} (#{label}) CHECK TABLE still fails after restoring #{corrupt_logical_stream}: #{restored.inspect}" unless restored == "all_1_1_0\t1"

    fields = damaged.split('\t', 3)
    unless fields.size == 3 && fields[0] == "all_1_1_0" && fields[1] == "0" && fields[2].includes?("CHECKSUM_DOESNT_MATCH")
      raise "#{type_name} (#{label}) CHECK TABLE missed #{corrupt_logical_stream} corruption: #{damaged.inspect}"
    end
  end

  puts "PASS #{type_name} shape=#{label}: attach, exact typed rows, UInt64 key range, CHECK TABLE, and independent corruption for #{corrupt_logical_streams.join(", ")}"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")

verify_typed_shape(binary, store, root, "u8", "UInt8", [0_u8, 1_u8, 127_u8, 128_u8, UInt8::MAX], false, ["payload"])
verify_typed_shape(binary, store, root, "u16", "UInt16", [0_u16, 1_u16, 0x7fff_u16, 0x8000_u16, UInt16::MAX], false, ["payload"])
verify_typed_shape(binary, store, root, "u32", "UInt32", [0_u32, 1_u32, 0x7fff_ffff_u32, 0x8000_0000_u32, UInt32::MAX], false, ["payload"])
verify_typed_shape(binary, store, root, "u64", "UInt64", [0_u64, 1_u64, 0x7fff_ffff_ffff_ffff_u64, 0x8000_0000_0000_0000_u64, UInt64::MAX], false, ["payload"])
verify_typed_shape(binary, store, root, "i8", "Int8", [Int8::MIN, -1_i8, 0_i8, 127_i8, 1_i8], false, ["payload"])
verify_typed_shape(binary, store, root, "i16", "Int16", [Int16::MIN, -1_i16, 0_i16, 1_i16, Int16::MAX], false, ["payload"])
verify_typed_shape(binary, store, root, "i32", "Int32", [Int32::MIN, -1_i32, 0_i32, 1_i32, Int32::MAX], false, ["payload"])
verify_typed_shape(binary, store, root, "i64", "Int64", [Int64::MIN, -1_i64, 0_i64, 1_i64, Int64::MAX], false, ["payload"])
verify_typed_shape(binary, store, root, "f32", "Float32", [0x0000_0000_u32.unsafe_as(Float32), 0x8000_0000_u32.unsafe_as(Float32), 0x3f80_0000_u32.unsafe_as(Float32), 0x7fc1_2345_u32.unsafe_as(Float32), 0xff80_0000_u32.unsafe_as(Float32)], false, ["payload"])
verify_typed_shape(binary, store, root, "f64", "Float64", [0x0000_0000_0000_0000_u64.unsafe_as(Float64), 0x8000_0000_0000_0000_u64.unsafe_as(Float64), 0x3ff8_0000_0000_0000_u64.unsafe_as(Float64), 0x7ff8_0000_0000_1234_u64.unsafe_as(Float64), 0xfff0_0000_0000_0000_u64.unsafe_as(Float64)], false, ["payload"])
verify_typed_shape(binary, store, root, "string", "String", ["", "a\0b", "alpha", "é", "tail"], false, ["payload", "payload.size"])

verify_typed_shape(binary, store, root, "nullable_u8", "Nullable(UInt8)", [nil, 0_u8.as(UInt8?), UInt8::MAX.as(UInt8?), nil, 1_u8.as(UInt8?)], true, ["payload.null", "payload"])
verify_typed_shape(binary, store, root, "nullable_u16", "Nullable(UInt16)", [nil, 0_u16.as(UInt16?), UInt16::MAX.as(UInt16?), nil, 1_u16.as(UInt16?)], true, ["payload.null", "payload"])
verify_typed_shape(binary, store, root, "nullable_u32", "Nullable(UInt32)", [nil, 0_u32.as(UInt32?), UInt32::MAX.as(UInt32?), nil, 1_u32.as(UInt32?)], true, ["payload.null", "payload"])
verify_typed_shape(binary, store, root, "nullable_u64", "Nullable(UInt64)", [nil, 0_u64.as(UInt64?), UInt64::MAX.as(UInt64?), nil, 1_u64.as(UInt64?)], true, ["payload.null", "payload"])
verify_typed_shape(binary, store, root, "nullable_i8", "Nullable(Int8)", [nil, Int8::MIN.as(Int8?), 0_i8.as(Int8?), nil, Int8::MAX.as(Int8?)], true, ["payload.null", "payload"])
verify_typed_shape(binary, store, root, "nullable_i16", "Nullable(Int16)", [nil, Int16::MIN.as(Int16?), 0_i16.as(Int16?), nil, Int16::MAX.as(Int16?)], true, ["payload.null", "payload"])
verify_typed_shape(binary, store, root, "nullable_i32", "Nullable(Int32)", [nil, Int32::MIN.as(Int32?), 0_i32.as(Int32?), nil, Int32::MAX.as(Int32?)], true, ["payload.null", "payload"])
verify_typed_shape(binary, store, root, "nullable_i64", "Nullable(Int64)", [nil, Int64::MIN.as(Int64?), 0_i64.as(Int64?), nil, Int64::MAX.as(Int64?)], true, ["payload.null", "payload"])
verify_typed_shape(binary, store, root, "nullable_f32", "Nullable(Float32)", [nil, 0x0000_0000_u32.unsafe_as(Float32).as(Float32?), 0x8000_0000_u32.unsafe_as(Float32).as(Float32?), nil, 0x7fc1_2345_u32.unsafe_as(Float32).as(Float32?)], true, ["payload.null", "payload"])
verify_typed_shape(binary, store, root, "nullable_f64", "Nullable(Float64)", [nil, 0x0000_0000_0000_0000_u64.unsafe_as(Float64).as(Float64?), 0x8000_0000_0000_0000_u64.unsafe_as(Float64).as(Float64?), nil, 0x7ff8_0000_0000_1234_u64.unsafe_as(Float64).as(Float64?)], true, ["payload.null", "payload"])
verify_typed_shape(binary, store, root, "nullable_string", "Nullable(String)", [nil, "".as(String?), "x\0y".as(String?), nil, "é".as(String?)], true, ["payload.null", "payload.size", "payload"])

verify_typed_shape(binary, store, root, "nullable_u64_all_null", "Nullable(UInt64)", Array(UInt64?).new(5, nil), true, ["payload.null", "payload"])
verify_typed_shape(binary, store, root, "nullable_string_all_null", "Nullable(String)", Array(String?).new(5, nil), true, ["payload.null", "payload.size"])
verify_typed_shape(binary, store, root, "string_all_empty", "String", Array(String).new(5, ""), false, ["payload.size"])

puts "PASS all 22 scalar/Nullable type shapes plus all-null and all-empty controls on ClickHouse #{binary}"
CRYSTAL
