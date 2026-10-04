#!/usr/bin/env ruby
# Finite stock-produced Wide Dynamic V3 normalized-bulk qualifier for W155.
# This binds a pinned stock part into a separate Crystal codec driver; it does
# not qualify complete-part writing or general physical reader admission.
require "digest"
require "open3"
require "optparse"

VERSION = "26.10.1.1201"
BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-b94acbe3"
SOURCE_REVISION = "b94acbe318f8459ac88b35647f4e2293d8e225db"
SCRATCH_ROOT_PREFIX = "/private/tmp/crystal-click-w155-"
DEFAULT_BINARY = "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped"
TABLE = "dynamic_bulk_values_w155"

class W155Failure < StandardError; end

def w155_fail!(message)
  raise W155Failure, "W155 stock probe: #{message}"
end

def w155_require(condition, message)
  w155_fail!(message) unless condition
end

def w155_write_new_file(path, bytes)
  File.open(path, "wbx", 0o600) { |file| file.write(bytes) }
rescue Errno::EEXIST
  w155_fail!("refusing to overwrite #{path}")
end

def w155_validate_scratch(path)
  w155_require(Dir.exist?(path) && !File.symlink?(path), "caller scratch directory is absent or a symlink")
  scratch = File.realpath(path)
  w155_require(File.expand_path(path) == scratch, "scratch path is not canonical")
  parent = File.dirname(scratch)
  w155_require(File.realpath(parent) == parent, "scratch parent is not canonical")
  w155_require(File.dirname(parent) == "/private/tmp" && File.basename(parent).start_with?(SCRATCH_ROOT_PREFIX.delete_prefix("/private/tmp/")),
    "scratch must be a direct child of a /private/tmp/crystal-click-w155-* root")
  w155_require(File.dirname(scratch) == parent, "scratch must be a direct child of its W155 root")
  w155_require(Dir.children(scratch).empty?, "caller scratch directory must be empty")
  scratch
end

class W155StockQueries
  def initialize(binary, root)
    @binary = binary
    @root = root
    @query_dir = File.join(root, "results", "stock")
    @store = File.join(root, "stores", "w155")
    Dir.mkdir(@query_dir, 0o700)
    Dir.mkdir(File.dirname(@store), 0o700)
    Dir.mkdir(@store, 0o700)
    @sequence = 0
  end

  def call(label, sql)
    @sequence += 1
    safe_label = label.gsub(/[^A-Za-z0-9_.-]/, "_")
    base = File.join(@query_dir, format("%03d-%s", @sequence, safe_label))
    w155_write_new_file(base + ".sql", sql + ";\n")
    args = [
      @binary, "local", "--path", @store, "--session_timezone=UTC",
      "--print_pretty_type_names=0", "--max_threads=1", "--max_insert_threads=1",
      "--max_block_size=1000", "--max_memory_usage=536870912",
      "--max_query_size=1048576", "--allow_suspicious_variant_types=1",
      "--allow_suspicious_low_cardinality_types=1", "--query", sql,
    ]
    stdout, stderr, status = Open3.capture3({"TZ" => "UTC"}, *args)
    w155_write_new_file(base + ".stdout", stdout.b)
    w155_write_new_file(base + ".stderr", stderr.b)
    [base + ".sql", base + ".stdout", base + ".stderr"].each do |path|
      w155_require(File.size(path) <= 16 * 1024 * 1024, "evidence file exceeds 16 MiB: #{path}")
    end
    {success: status.success?, exitstatus: status.exitstatus, stdout: stdout.b, stderr: stderr.b}
  end

  def require_success(result, label)
    w155_require(result[:success], "#{label} failed (exit #{result[:exitstatus]}): #{result[:stderr].inspect}")
  end

  def call_success(label, sql)
    result = call(label, sql)
    require_success(result, label)
    result[:stdout]
  end
end

def w155_validate_driver(path)
  w155_require(File.file?(path) && File.executable?(path) && !File.symlink?(path),
    "compiled Crystal driver is absent, non-executable, or a symlink")
  [File.expand_path(path), Digest::SHA256.file(path).hexdigest]
end

def w155_call_driver(driver, root, label, *arguments)
  directory = File.join(root, "results", "driver")
  safe_label = label.gsub(/[^A-Za-z0-9_.-]/, "_")
  base = File.join(directory, safe_label)
  stdout, stderr, status = Open3.capture3({}, driver, *arguments)
  w155_write_new_file(base + ".stdout", stdout.b)
  w155_write_new_file(base + ".stderr", stderr.b)
  [base + ".stdout", base + ".stderr"].each do |path|
    w155_require(File.size(path) <= 16 * 1024 * 1024, "driver evidence exceeds 16 MiB: #{path}")
  end
  {success: status.success?, exitstatus: status.exitstatus, stdout: stdout.b, stderr: stderr.b}
end

def w155_check_source_identity
  source, source_error, source_status = Open3.capture3("git", "-C", SOURCE_ROOT, "rev-parse", "HEAD")
  w155_require(source_status.success? && source.strip == SOURCE_REVISION,
    "pinned shallow source revision differs: #{source.strip.inspect} #{source_error}")
  changes, changes_error, changes_status = Open3.capture3(
    "git", "-C", SOURCE_ROOT, "status", "--porcelain", "--untracked-files=normal"
  )
  w155_require(changes_status.success? && changes.empty?,
    "pinned source tree is not clean: #{changes.inspect} #{changes_error}")
  source.strip
end

def w155_create_sql
  <<~SQL.strip
    CREATE TABLE default.#{TABLE}
    (
      id UInt64,
      root_dynamic Dynamic(max_types=1),
      pair Tuple(left Dynamic(max_types=1), right Dynamic(max_types=1)),
      nested Array(Dynamic(max_types=1)),
      unused_variant Variant(Array(Dynamic(max_types=0)), UInt8)
    )
    ENGINE = MergeTree
    ORDER BY id
    SETTINGS
      index_granularity=2,
      index_granularity_bytes=10485760,
      enable_mixed_granularity_parts=1,
      min_rows_for_wide_part=0,
      min_bytes_for_wide_part=0,
      min_level_for_wide_part=0,
      escape_variant_subcolumn_filenames=1,
      default_compression_codec='LZ4',
      compress_marks=0,
      write_final_mark=1,
      min_compress_block_size=0,
      max_compress_block_size=4096,
      serialization_info_version='with_types',
      string_serialization_version='single_stream',
      dynamic_serialization_version='v3',
      propagate_types_serialization_versions_to_nested_types=1,
      use_compact_variant_discriminators_serialization=0
  SQL
end

def w155_dynamic(value)
  "CAST(#{value}, 'Dynamic(max_types=1)')"
end

def w155_variant_u8(value)
  "CAST(toUInt8(#{value}), 'Variant(Array(Dynamic(max_types=0)), UInt8)')"
end

def w155_insert_sql
  u64 = ->(value) { w155_dynamic("toUInt64(#{value})") }
  string = ->(value) { w155_dynamic("'#{value}'") }
  nested = ->(values) do
    values.empty? ? "CAST([], 'Array(Dynamic(max_types=1))')" : "[#{values.map { |value| u64.call(value) }.join(', ')}]"
  end
  rows = [
    "(1, #{u64.call(42)}, tuple(#{u64.call(100)}, #{string.call('r0')}), #{nested.call([10])}, #{w155_variant_u8(20)})",
    "(2, #{string.call('spill')}, tuple(#{u64.call(101)}, #{string.call('r1')}), #{nested.call([])}, #{w155_variant_u8(21)})",
    "(3, CAST(NULL, 'Dynamic(max_types=1)'), tuple(#{u64.call(102)}, #{string.call('r2')}), #{nested.call([12, 13])}, #{w155_variant_u8(22)})",
    "(4, #{u64.call(43)}, tuple(#{u64.call(103)}, #{string.call('r3')}), #{nested.call([14])}, #{w155_variant_u8(23)})",
    "(5, #{u64.call(44)}, tuple(#{u64.call(104)}, #{string.call('r4')}), #{nested.call([])}, #{w155_variant_u8(24)})",
    "(6, #{u64.call(45)}, tuple(#{u64.call(105)}, #{string.call('r5')}), #{nested.call([15])}, #{w155_variant_u8(25)})",
  ]
  "INSERT INTO default.#{TABLE} (id, root_dynamic, pair, nested, unused_variant) VALUES\n" + rows.join(",\n")
end

def w155_main(options)
  w155_require(options[:scratch], "--scratch is required; runner never creates or reuses its scratch directory")
  w155_require(options[:driver], "--driver is required")
  root = w155_validate_scratch(options[:scratch])
  results = File.join(root, "results")
  Dir.mkdir(results, 0o700)
  Dir.mkdir(File.join(results, "driver"), 0o700)

  driver, driver_digest = w155_validate_driver(options[:driver])
  binary = options[:binary]
  w155_require(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary),
    "pinned ClickHouse executable is absent, non-executable, or a symlink")
  digest = Digest::SHA256.file(binary).hexdigest
  w155_require(digest == EXECUTABLE_SHA256, "runtime SHA-256 differs: #{digest}")
  source_revision = w155_check_source_identity

  manifest = [
    "qualification=finite stock-produced Dynamic V3 BASIC normalized bulk values and complete mark grids",
    "runtime_version=#{VERSION}",
    "runtime_sha256=#{digest}",
    "runtime_build_hash=#{BUILD_HASH}",
    "source_reference=#{SOURCE_ROOT}@#{source_revision}",
    "source_worktree=clean",
    "source_is_unbuilt_reference_only; no runtime build lineage is asserted",
    "profile=single_stream; serialization_info_version=with_types; dynamic_serialization_version=v3; BASIC discriminator mode; nested type-version propagation enabled",
    "fixture=one six-row Wide part, three marks of two rows; root Dynamic(max_types=1) with U64 ordinary, String shared spill and NULL; Tuple Dynamic sites have separate U64/String rosters; Array(Dynamic) includes empty rows; unused Variant(Array(Dynamic(max_types=0))) site has no child values",
    "oracle=literal expected SQL runtime type/shared-state rows and independently authored BinaryValue rows; actual per-site roster bytes and roles are asserted before normalized decoding",
    "scope=selected compressed physical lanes normalized into paired Dynamic bulk streams; not complete part writing, a general physical binder, COMPACT, with_size_stream, older versions, Object, or storage admission",
    "control=the Crystal codec decodes a wire-valid 42-to-43 mutation of the normalized U64 lane extracted from the stock-produced part, then the independent literal comparator rejects it; ClickHouse did not re-read or CHECK the mutated lane/part",
    "driver=#{driver}",
    "driver_sha256=#{driver_digest}",
  ].join("\n") + "\n"
  w155_write_new_file(File.join(results, "manifest.txt"), manifest)

  queries = W155StockQueries.new(binary, root)
  version = queries.call_success("version", "SELECT version() FORMAT TSVRaw")
  w155_require(version.strip == VERSION, "runtime version differs: #{version.inspect}")
  build = queries.call_success("build-identity",
    "SELECT concat(name, '=', value) FROM system.build_options WHERE name IN ('GIT_HASH','VERSION_GITHASH') ORDER BY name FORMAT TSVRaw")
  expected_build = "GIT_HASH=#{BUILD_HASH}\nVERSION_GITHASH=#{BUILD_HASH}\n"
  w155_require(build == expected_build, "runtime build identity differs: #{build.inspect}")

  create = queries.call("create-wide-fixture", w155_create_sql)
  queries.require_success(create, "CREATE W155 stock fixture")
  insert = queries.call("insert-wide-fixture", w155_insert_sql)
  queries.require_success(insert, "INSERT W155 stock fixture")

  columns = queries.call_success("column-types",
    "SELECT name, type FROM system.columns WHERE database='default' AND table='#{TABLE}' ORDER BY position FORMAT TSVRaw")
  expected_columns = [
    "id\tUInt64",
    "root_dynamic\tDynamic(max_types=1)",
    "pair\tTuple(left Dynamic(max_types=1), right Dynamic(max_types=1))",
    "nested\tArray(Dynamic(max_types=1))",
    "unused_variant\tVariant(Array(Dynamic(max_types=0)), UInt8)",
  ].join("\n") + "\n"
  w155_require(columns == expected_columns, "stock-normalized fixture column types differ: #{columns.inspect}")

  fixture_values = queries.call_success("literal-row-state-control",
    "SELECT id, if(isNull(root_dynamic), 'NULL', concat(dynamicType(root_dynamic), ':', toString(toUInt8(isDynamicElementInSharedData(root_dynamic))))), " +
    "ifNull(toString(dynamicElement(root_dynamic, 'UInt64')), ''), ifNull(dynamicElement(root_dynamic, 'String'), ''), " +
    "concat(dynamicType(tupleElement(pair, 1)), ':', toString(toUInt8(isDynamicElementInSharedData(tupleElement(pair, 1))))), " +
    "concat(dynamicType(tupleElement(pair, 2)), ':', toString(toUInt8(isDynamicElementInSharedData(tupleElement(pair, 2))))), " +
    "ifNull(toString(dynamicElement(tupleElement(pair, 1), 'UInt64')), ''), ifNull(dynamicElement(tupleElement(pair, 2), 'String'), ''), " +
    "arrayStringConcat(arrayMap(x -> concat(dynamicType(x), ':', toString(toUInt8(isDynamicElementInSharedData(x)))), nested), ','), " +
    "arrayStringConcat(arrayMap(x -> ifNull(toString(x), ''), dynamicElement(nested, 'UInt64')), ','), " +
    "toString(variantElement(unused_variant, 'UInt8')) " +
    "FROM default.#{TABLE} ORDER BY id SETTINGS print_pretty_type_names=0 FORMAT TSVRaw")
  expected_fixture_values = [
    "1\tUInt64:0\t42\t\tUInt64:0\tString:0\t100\tr0\tUInt64:0\t10\t20",
    "2\tString:1\t\tspill\tUInt64:0\tString:0\t101\tr1\t\t\t21",
    "3\tNULL\t\t\tUInt64:0\tString:0\t102\tr2\tUInt64:0,UInt64:0\t12,13\t22",
    "4\tUInt64:0\t43\t\tUInt64:0\tString:0\t103\tr3\tUInt64:0\t14\t23",
    "5\tUInt64:0\t44\t\tUInt64:0\tString:0\t104\tr4\t\t\t24",
    "6\tUInt64:0\t45\t\tUInt64:0\tString:0\t105\tr5\tUInt64:0\t15\t25",
  ].join("\n") + "\n"
  w155_require(fixture_values == expected_fixture_values,
    "stock rows/ordinary-vs-shared state differ from independent literal expectations: #{fixture_values.inspect}")

  part_rows = queries.call_success("active-wide-part",
    "SELECT name, partition_id, min_block_number, max_block_number, level, rows, part_type, path FROM system.parts WHERE database='default' AND table='#{TABLE}' AND active=1 ORDER BY name FORMAT TSVRaw")
  entries = part_rows.lines.map { |line| line.chomp.split("\t", -1) }
  w155_require(entries.size == 1 && entries.first.size == 8, "expected one active part, got #{part_rows.inspect}")
  part_name, partition_id, min_block, max_block, level, rows, part_type, part = entries.first
  w155_require([min_block, max_block, level].all? { |value| value.match?(/\A\d+\z/) },
    "part block identity fields are not unsigned integers: #{part_rows.inspect}")
  w155_require(part_name == "#{partition_id}_#{min_block}_#{max_block}_#{level}" && min_block == max_block && level == "0",
    "stock fixture part identity is not the exact single-insert part: #{part_rows.inspect}")
  w155_require(rows == "6" && part_type == "Wide", "fixture is not one six-row Wide part: #{part_rows.inspect}")
  part = File.realpath(part)
  store = File.realpath(File.join(root, "stores", "w155"))
  w155_require(part.start_with?(store + File::SEPARATOR), "stock part escaped the isolated W155 store")
  w155_require(File.basename(part) == part_name, "resolved stock part directory does not match system.parts identity")

  qualified = w155_call_driver(driver, root, "paired-normalized-stock-qualification", "--qualify", part)
  w155_require(qualified[:success], "Crystal stock Dynamic bulk qualification failed: #{qualified[:stderr].inspect}")
  w155_require(qualified[:stdout].include?("NEGATIVE-CONTROL\tnormalized-stock-lane-42-to-43\tcrystal-decode=accepted\tindependent-literal-values=REJECTED"),
    "Crystal driver omitted the valid wrong-value semantic rejection control: #{qualified[:stdout].inspect}")
  w155_require(qualified[:stdout].include?("W155 stock Dynamic bulk qualification PASS columns=4 rows=6 marks=3"),
    "Crystal driver omitted finite stock bulk summary: #{qualified[:stdout].inspect}")

  summary = [
    "PASS finite stock W155 paired Dynamic bulk qualification",
    "runtime=#{VERSION} build=#{BUILD_HASH} sha256=#{digest}",
    "source_reference=#{SOURCE_REVISION} (unbuilt; runtime lineage not asserted)",
    "fixture=4 typed columns, 6 rows, 3 marks, exact expected rosters and row-level shared flags",
    "scope=single_stream BASIC normalized Dynamic bulk bytes/grids with per-occurrence V3 structure pairing",
    "negative_control=Crystal codec accepted a wire-valid 42-to-43 mutation of normalized UInt64 bytes extracted from the stock-produced part, then independent expected values rejected it; ClickHouse did not re-read or CHECK the mutation",
    "not_qualified=other String profiles, COMPACT, other structure versions, complete physical writing, Object, or general storage admission",
  ].join("\n") + "\n"
  w155_write_new_file(File.join(results, "summary.txt"), summary)
  puts "PASS W155 finite stock Dynamic bulk qualifier: 4 columns, 6 rows, 3 marks; source reference and runtime identity remain separate"
end

options = {binary: DEFAULT_BINARY}
OptionParser.new do |parser|
  parser.banner = "Usage: check_dynamic_bulk_values_w155.rb --scratch EMPTY_W155_SCRATCH --driver CRYSTAL_DRIVER [--binary PINNED_CLICKHOUSE]"
  parser.on("--scratch PATH") { |value| options[:scratch] = value }
  parser.on("--driver PATH") { |value| options[:driver] = value }
  parser.on("--binary PATH") { |value| options[:binary] = value }
end.parse!

begin
  w155_main(options)
rescue W155Failure => ex
  warn ex.message
  exit 1
end
