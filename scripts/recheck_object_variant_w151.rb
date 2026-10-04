#!/usr/bin/env ruby
# Independent stock-side recheck for W151. Expected RowBinary is hand-packed
# from the six literal rows below; no Crystal output or generated manifest is
# used as the value oracle.
require "digest"
require "fileutils"
require "open3"

VERSION = "26.10.1.1201"
BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-37a251ff"
SOURCE_REVISION = "37a251ffa2805b33201486306db980bfa96d73e7"
ROOT_PREFIX = "/private/tmp/crystal-click-object-variant-w151."
FIELDS = %w[aav av mv nested ntv tv v].freeze
TYPE_NAMES = [
  "Array(Array(Variant(Array(UInt8), UInt64)))",
  "Array(Variant(LowCardinality(String), UInt64))",
  "Map(String, Variant(String, UInt64))",
  "Variant(Array(Variant(String, UInt64)), UInt64)",
  "Nullable(Tuple(v Variant(String, UInt64), note String))",
  "Variant(Tuple(label String, score UInt32), UInt64)",
  "Variant(Array(UInt8), String, UInt64)",
].freeze
MATRIX = [
  ["native-s0", "single_stream", "basic"],
  ["native-s1", "with_size_stream", "basic"],
  ["native-compact-typed", "single_stream", "compact"],
  ["library-s0-d0", "single_stream", "basic"],
  ["library-s0-d1", "single_stream", "compact"],
  ["library-s1-d0", "with_size_stream", "basic"],
  ["library-s1-d1", "with_size_stream", "compact"],
  ["library-mutant", "single_stream", "basic"],
].freeze

def fail!(message)
  raise "W151 independent Ruby recheck failed: #{message}"
end

def require_true(condition, message)
  fail!(message) unless condition
end

def var_uint(value)
  value = Integer(value)
  bytes = +"".b
  while value >= 0x80
    bytes << ((value & 0x7f) | 0x80)
    value >>= 7
  end
  bytes << value
end

def ch_string(value)
  bytes = value.to_s.b
  var_uint(bytes.bytesize) + bytes
end

def u8(value)
  [value].pack("C")
end

def u32(value)
  [value].pack("L<")
end

def u64(value)
  [value].pack("Q<")
end

def variant(tag, payload = "".b)
  u8(tag) + payload
end

def array(items)
  var_uint(items.length) + items.join.b
end

def map(items)
  var_uint(items.length) + items.flat_map { |key, value| [ch_string(key), value] }.join.b
end

def row_values(mutant: false)
  inner_v = ->(tag, value = nil) do
    case tag
    when :null then variant(255)
    when :string then variant(0, ch_string(value))
    when :uint64 then variant(1, u64(value))
    else raise "unknown nested Variant literal #{tag.inspect}"
    end
  end
  array_u8_arm = ->(numbers) { variant(0, array(numbers.map { |number| u8(number) })) }
  av_string = ->(text) { variant(0, ch_string(text)) } # LC(String) is transparent in RowBinary.
  av_uint = ->(number) { variant(1, u64(number)) }
  mv_string = ->(text) { variant(0, ch_string(text)) }
  mv_uint = ->(number) { variant(1, u64(number)) }
  nested_array = ->(items) { variant(0, array(items)) }
  tuple_variant = ->(name, score) { variant(0, ch_string(name) + u32(score)) }
  ntv = ->(v, note) { "\x00".b + v + ch_string(note) }

  [
    [
      array([]), array([]), map([["one", mv_string.call("alpha")]]),
      variant(255), "\x01".b, variant(255), variant(255),
    ],
    [
      array([
        array([array_u8_arm.call([1, 2]), variant(1, u64(3))]),
        array([]),
      ]),
      array([av_string.call("alpha"), av_uint.call(2)]),
      map([["a", mv_uint.call(2)], ["z", mv_string.call("two")]]),
      nested_array.call([inner_v.call(:string, "nested2"), inner_v.call(:uint64, 200)]),
      ntv.call(inner_v.call(:string, "inner2"), "note2"),
      tuple_variant.call("row2", 22),
      variant(2, u64(mutant ? 43 : 42)),
    ],
    [
      array([array([]), array([array_u8_arm.call([9])])]),
      array([av_string.call("alpha"), av_uint.call(3)]),
      map([]),
      variant(1, u64(300)),
      ntv.call(inner_v.call(:uint64, 3), "note3"),
      variant(1, u64(33)),
      variant(1, ch_string("three")),
    ],
    [
      array([array([array_u8_arm.call([])])]),
      array([av_string.call("mid")]),
      map([["b", mv_uint.call(4)]]),
      nested_array.call([]),
      "\x01".b,
      variant(1, u64(44)),
      array_u8_arm.call([4, 5]),
    ],
    [
      array([]),
      array([av_string.call("last"), av_uint.call(5)]),
      map([["z", mv_string.call("five")]]),
      nested_array.call([inner_v.call(:null), inner_v.call(:string, "nested5")]),
      ntv.call(variant(255), "note5"),
      tuple_variant.call("row5", 55),
      variant(255),
    ],
    [
      array([array([variant(1, u64(6)), array_u8_arm.call([6])])]),
      array([av_uint.call(6)]),
      map([["a", mv_uint.call(0xffff_ffff_ffff_ffff)]]),
      variant(1, u64(600)),
      ntv.call(inner_v.call(:string, "six"), "note6"),
      variant(1, u64(66)),
      variant(2, u64(0xffff_ffff_ffff_ffff)),
    ],
  ]
end

def expected_rowbinary(mutant: false, rows: (0...6).to_a)
  literals = row_values(mutant: mutant)
  rows.map do |index|
    u64(index + 1) + literals.fetch(index).join.b
  end.join.b
end

class StockQueries
  def initialize(binary, root)
    @binary = binary
    @root = root
    @query_dir = File.join(root, "results", "ruby-oracle")
    require_true(!File.exist?(@query_dir) && !File.symlink?(@query_dir), "Ruby evidence directory already exists")
    FileUtils.mkdir_p(@query_dir, mode: 0o700)
    @sequence = 0
  end

  def call(label, store, sql, input = nil)
    @sequence += 1
    base = File.join(@query_dir, format("%03d-%s", @sequence, label.gsub(/[^A-Za-z0-9_.-]/, "_")))
    {".sql" => sql + ";\n"}.each do |suffix, body|
      path = base + suffix
      require_true(!File.exist?(path) && !File.symlink?(path), "refusing evidence overwrite at #{path}")
      File.binwrite(path, body)
    end
    args = [
      @binary, "local", "--path", store, "--session_timezone=UTC",
      "--print_pretty_type_names=0", "--allow_suspicious_variant_types=1",
      "--allow_suspicious_low_cardinality_types=1", "--max_threads=1",
      "--max_memory_usage=536870912", "--query", sql,
    ]
    stdout, stderr, status = Open3.capture3({"TZ" => "UTC"}, *args, stdin_data: input || "")
    File.binwrite(base + ".stdout", stdout.b)
    File.binwrite(base + ".stderr", stderr.b)
    [base + ".sql", base + ".stdout", base + ".stderr"].each do |path|
      require_true(File.size(path) <= 8 * 1024 * 1024, "artifact exceeds 8 MiB: #{path}")
    end
    fail!("stock query failed at #{label}: #{stderr}\nSQL=#{sql}") unless status.success?
    stdout.b
  end
end

def verify_pins(binary, source_root, queries, root)
  require_true(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary),
    "ClickHouse binary is missing, non-executable, or a symlink")
  digest = Digest::SHA256.file(binary).hexdigest
  require_true(digest == EXECUTABLE_SHA256, "runtime SHA-256 differs: #{digest}")
  source = Open3.capture3("git", "-C", source_root, "rev-parse", "HEAD")
  require_true(source[2].success? && source[0].strip == SOURCE_REVISION,
    "pinned shallow source revision differs")
  identity_store = File.join(root, "stores", "identity")
  version = queries.call("version", identity_store, "SELECT version() FORMAT TSVRaw").strip
  require_true(version == VERSION, "runtime version differs: #{version.inspect}")
  build = queries.call("build-identity", identity_store,
    "SELECT concat(name, '=', value) FROM system.build_options WHERE name IN ('GIT_HASH','VERSION_GITHASH') ORDER BY name FORMAT TSVRaw")
  expected = "GIT_HASH=#{BUILD_HASH}\nVERSION_GITHASH=#{BUILD_HASH}\n"
  require_true(build == expected, "runtime build identity differs: #{build.inspect}")
  File.write(File.join(root, "results", "ruby-oracle", "pins.txt"), [
    "runtime_version=#{version}", "runtime_sha256=#{digest}", "runtime_build_hash=#{BUILD_HASH}",
    "source_reference=#{source_root}@#{source[0].strip}",
    "source_is_not_asserted_to_build_runtime=true",
  ].join("\n") + "\n")
end

def verify_cell(label, string_profile, dynamic_mode, root, queries, mutant: false)
  store = File.join(root, "stores", label)
  require_true(Dir.exist?(store) && !File.symlink?(store), "#{label}: expected stock store is missing")
  part = queries.call("#{label}-part-grid", store,
    "SELECT toString(rows), toString(marks), part_type FROM system.parts WHERE database='default' AND table='p' AND active ORDER BY name FORMAT TSVRaw")
  require_true(part == "6\t4\tWide\n", "#{label}: expected six rows, three real marks plus terminal record, Wide; got #{part.inspect}")

  check = queries.call("#{label}-check", store, "CHECK TABLE default.p FORMAT TabSeparated")
  require_true(check == "all_1_1_0\t1\t\n", "#{label}: stock CHECK TABLE raw output differs: #{check.inspect}")

  type_sql = "SELECT #{FIELDS.map { |field| "toTypeName(j.#{field})" }.join(", ")} FROM default.p ORDER BY pk LIMIT 1 FORMAT TSVRaw"
  type_output = queries.call("#{label}-types", store, type_sql)
  require_true(type_output == TYPE_NAMES.join("\t") + "\n",
    "#{label}: exact declared nominal type witness differs: #{type_output.inspect}")

  dynamic = queries.call("#{label}-dynamic", store,
    "SELECT pk, dynamicType(j.d), isDynamicElementInSharedData(j.d) FROM default.p ORDER BY pk FORMAT TSVRaw")
  expected_dynamic = (1..6).map { |key| "#{key}\tInt64\tfalse\n" }.join
  require_true(dynamic == expected_dynamic, "#{label}: Dynamic d ordinary arm witness differs")
  paths = queries.call("#{label}-object-path-layout", store,
    "SELECT pk, toJSONString(JSONDynamicPaths(j)), toJSONString(JSONSharedDataPaths(j)) FROM default.p ORDER BY pk FORMAT TSVRaw")
  expected_paths = (1..6).map do |key|
    shared_paths = [2, 4, 6].include?(key) ? '["spill"]' : "[]"
    "#{key}\t[\"d\"]\t#{shared_paths}\n"
  end.join
  require_true(paths == expected_paths,
    "#{label}: exact Object dynamic/shared path layout differs: #{paths.inspect}")
  spill = queries.call("#{label}-object-shared-spill", store,
    "SELECT pk, CAST(j.spill AS String), dynamicType(j.spill), isDynamicElementInSharedData(j.spill) FROM default.p WHERE pk IN (2,4,6) ORDER BY pk FORMAT TSVRaw")
  require_true(spill == "2\tspill-two\tString\tfalse\n4\tspill-four\tString\tfalse\n6\tspill-six\tString\tfalse\n",
    "#{label}: Object-shared spill path / Dynamic-element discriminator witness differs: #{spill.inspect}")

  projection = (["pk"] + FIELDS.map { |field| "j.#{field}" }).join(", ")
  full = queries.call("#{label}-rowbinary-full", store,
    "SELECT #{projection} FROM default.p ORDER BY pk FORMAT RowBinary")
  middle = queries.call("#{label}-rowbinary-middle", store,
    "SELECT #{projection} FROM default.p WHERE pk IN (3,4) ORDER BY pk FORMAT RowBinary")
  zero = queries.call("#{label}-rowbinary-zero", store,
    "SELECT #{projection} FROM default.p WHERE 0 ORDER BY pk FORMAT RowBinary")
  expected_full = expected_rowbinary(mutant: mutant)
  expected_middle = expected_rowbinary(mutant: mutant, rows: [2, 3])
  require_true(full == expected_full, "#{label}: independent hand-packed full RowBinary differs")
  require_true(middle == expected_middle, "#{label}: independent hand-packed middle RowBinary differs")
  require_true(zero.empty?, "#{label}: zero-row query emitted bytes")
  if mutant
    original = expected_rowbinary
    require_true(full != original, "valid 42-to-43 mutant did not change the complete literal")
  end
  puts "PASS W151 independent Ruby stock oracle #{label} (#{string_profile}, Dynamic #{dynamic_mode})"
end

def main
  fail!("root execution requires W151_EXECUTE_AS_ROOT=YES") unless ENV["W151_EXECUTE_AS_ROOT"] == "YES"
  root = ENV.fetch("W151_PAIR_ROOT")
  require_true(root.start_with?(ROOT_PREFIX) && root.bytesize > ROOT_PREFIX.bytesize,
    "W151_PAIR_ROOT must be a direct safe /private/tmp child")
  require_true(Dir.exist?(root) && !File.symlink?(root) && File.realpath(root) == root,
    "W151 evidence root is absent, noncanonical, or a symlink")
  binary = ENV.fetch("CLICKHOUSE_BIN", "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped")
  queries = StockQueries.new(binary, root)
  verify_pins(binary, SOURCE_ROOT, queries, root)

  cells_file = File.join(root, "cells.tsv")
  require_true(File.file?(cells_file) && !File.symlink?(cells_file), "Crystal cell roster is absent or unsafe")
  lines = File.readlines(cells_file, chomp: true)
  require_true(lines.first == "label\tdirection\tstring_profile\tdynamic_mode\tstore\ttable\tpart_path",
    "cell roster header differs")
  expected_labels = MATRIX.map(&:first)
  require_true(lines.drop(1).map { |line| line.split("\t").first } == expected_labels,
    "cell roster labels/order differ from independent expected roster")

  MATRIX.each do |label, profile, mode|
    verify_cell(label, profile, mode, root, queries, mutant: label == "library-mutant")
  end

  File.write(File.join(root, "results", "ruby-oracle", "summary.txt"), <<~TEXT)
    PASS independent Ruby literal oracle queried eight fresh stock stores (2 native BASIC, 1 typed-COMPACT guard, 4 library, 1 mutant)
    PASS exact types, Dynamic ordinary/shared values, CHECK TABLE, full/middle/zero RowBinary
    PASS mutant v UInt64 42->43 agrees with changed literal and differs from original
    source_reference=#{SOURCE_ROOT}@#{SOURCE_REVISION}
    runtime=#{VERSION} build=#{BUILD_HASH} sha256=#{EXECUTABLE_SHA256}
    source_is_not_asserted_to_build_runtime=true
  TEXT
  puts "PASS W151 independent Ruby stock/literal recheck"
end

main
