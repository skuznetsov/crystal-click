#!/usr/bin/env ruby
# Bounded stock Wide Dynamic physical-binder qualification for W156.
# This runner owns only a caller-created empty scratch child and copied parts.
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"

W156_VERSION = "26.10.1.1201"
W156_BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W156_RUNTIME_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W156_SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-b94acbe3"
W156_SOURCE_REVISION = "b94acbe318f8459ac88b35647f4e2293d8e225db"
W156_DEFAULT_BINARY = "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped"
W156_MAX_CAPTURE = 16 * 1024 * 1024
W156_SOURCE_ORACLE = File.expand_path("recheck_dynamic_physical_binding_w156.rb", __dir__)

class W156Failure < StandardError; end

class W156Runner
  TYPES = [
    "id\tUInt64",
    "root_dynamic\tDynamic(max_types=1)",
    "pair\tTuple(left Dynamic(max_types=1), right Dynamic(max_types=1))",
    "nested\tArray(Dynamic(max_types=1))",
    "unused_variant\tVariant(Array(Dynamic(max_types=0)), UInt8)",
  ].join("\n") + "\n"

  CLEAN_FULL = [
    "1\tUInt64:0\t42\t\tUInt64:0\tString:0\t100\tr0\tUInt64:0\t10\t20",
    "2\tString:1\t\tspill\tUInt64:0\tString:0\t101\tr1\t\t\t21",
    "3\tNULL\t\t\tUInt64:0\tString:0\t102\tr2\tUInt64:0,UInt64:0\t12,13\t22",
    "4\tUInt64:0\t43\t\tUInt64:0\tString:0\t103\tr3\tUInt64:0\t14\t23",
    "5\tUInt64:0\t44\t\tUInt64:0\tString:0\t104\tr4\t\t\t24",
    "6\tUInt64:0\t45\t\tUInt64:0\tString:0\t105\tr5\tUInt64:0\t15\t25",
  ].join("\n") + "\n"

  CLEAN_MIDDLE = [
    "3\tNULL\t\t\tUInt64:0\tString:0\t102\tr2\tUInt64:0,UInt64:0\t12,13\t22",
    "4\tUInt64:0\t43\t\tUInt64:0\tString:0\t103\tr3\tUInt64:0\t14\t23",
  ].join("\n") + "\n"

  MUTANT_FULL = CLEAN_FULL.sub("1\tUInt64:0\t42\t", "1\tUInt64:0\t43\t")

  TABLES = {
    stock: {store: "w156_stock", table: "dynamic_bulk_physical_w156", expected: CLEAN_FULL},
    library: {store: "w156_library", table: "dynamic_bulk_physical_w156_library", expected: CLEAN_FULL},
    mutant: {store: "w156_mutant", table: "dynamic_bulk_physical_w156_mutant", expected: MUTANT_FULL},
  }.freeze

  def initialize(options)
    @options = options
    @commands = []
    @sequence = 0
  end

  def fail!(message)
    raise W156Failure, "W156 stock physical-binding qualifier: #{message}"
  end

  def require!(condition, message)
    fail!(message) unless condition
  end

  def write_new(path, bytes)
    File.open(path, "wbx", 0o600) { |file| file.write(bytes) }
  rescue Errno::EEXIST
    fail!("refusing to overwrite evidence or output: #{path}")
  end

  def mkdir(path)
    require!(!File.exist?(path) && !File.symlink?(path), "refusing to reuse directory: #{path}")
    Dir.mkdir(path, 0o700)
  end

  def validate_scratch(path)
    require!(path.match?(%r{\A/private/tmp/crystal-click-w156-[A-Za-z0-9._-]+/child\z}),
      "scratch must be /private/tmp/crystal-click-w156-*/child")
    require!(File.directory?(path) && !File.symlink?(path), "caller scratch child is absent or symlinked")
    root = File.realpath(path)
    parent = File.dirname(root)
    require!(File.expand_path(path) == root && File.basename(root) == "child", "scratch child is not canonical")
    require!(File.realpath(parent) == parent && File.dirname(parent) == "/private/tmp" &&
      File.basename(parent).start_with?("crystal-click-w156-"), "scratch root is outside bounded /private/tmp scope")
    require!(Dir.children(root).empty?, "caller scratch child must be new and empty")
    root
  end

  def record_process(label, argv, env = {})
    stdout, stderr, status = Open3.capture3(env, *argv)
    require!(stdout.bytesize <= W156_MAX_CAPTURE && stderr.bytesize <= W156_MAX_CAPTURE,
      "#{label}: process output exceeded 16 MiB")
    @commands << {
      label: label,
      argv: argv,
      exitstatus: status.exitstatus,
      success: status.success?,
      stdout_sha256: Digest::SHA256.hexdigest(stdout.b),
      stderr_sha256: Digest::SHA256.hexdigest(stderr.b),
    }
    {stdout: stdout.b, stderr: stderr.b, status: status}
  end

  def write_process_evidence(base, result)
    write_new(base + ".stdout", result[:stdout])
    write_new(base + ".stderr", result[:stderr])
    write_new(base + ".status", "#{result[:status].exitstatus}\n")
  end

  def command_args(store, sql)
    [
      @binary, "local", "--path", store, "--session_timezone=UTC",
      "--print_pretty_type_names=0", "--max_threads=1", "--max_insert_threads=1",
      "--max_block_size=1000", "--max_memory_usage=536870912",
      "--max_query_size=1048576", "--allow_suspicious_variant_types=1",
      "--allow_suspicious_low_cardinality_types=1", "--query", sql,
    ]
  end

  def query(key, label, sql)
    store = File.join(@root, "stores", TABLES.fetch(key)[:store])
    require!(File.directory?(store) && !File.symlink?(store), "missing or symlinked store: #{store}")
    @sequence += 1
    base = File.join(@root, "results", "queries", format("%03d-%s", @sequence, label.gsub(/[^A-Za-z0-9_.-]/, "_")))
    write_new(base + ".sql", sql + ";\n")
    result = record_process("clickhouse:#{key}:#{label}", command_args(store, sql), {"TZ" => "UTC"})
    write_process_evidence(base, result)
    result
  end

  def query_success(key, label, sql)
    result = query(key, label, sql)
    require!(result[:status].success?, "#{label} failed with exit #{result[:status].exitstatus}: #{result[:stderr].inspect}")
    result[:stdout]
  end

  def table_create_sql(table)
    <<~SQL.strip
      CREATE TABLE default.#{table}
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

  def dynamic(value)
    "CAST(#{value}, 'Dynamic(max_types=1)')"
  end

  def insert_sql(table)
    u64 = ->(value) { dynamic("toUInt64(#{value})") }
    string = ->(value) { dynamic("'#{value}'") }
    variant_u8 = ->(value) { "CAST(toUInt8(#{value}), 'Variant(Array(Dynamic(max_types=0)), UInt8)')" }
    nested = ->(values) do
      values.empty? ? "CAST([], 'Array(Dynamic(max_types=1))')" : "[#{values.map { |value| u64.call(value) }.join(', ')}]"
    end
    rows = [
      "(1, #{u64.call(42)}, tuple(#{u64.call(100)}, #{string.call('r0')}), #{nested.call([10])}, #{variant_u8.call(20)})",
      "(2, #{string.call('spill')}, tuple(#{u64.call(101)}, #{string.call('r1')}), #{nested.call([])}, #{variant_u8.call(21)})",
      "(3, CAST(NULL, 'Dynamic(max_types=1)'), tuple(#{u64.call(102)}, #{string.call('r2')}), #{nested.call([12, 13])}, #{variant_u8.call(22)})",
      "(4, #{u64.call(43)}, tuple(#{u64.call(103)}, #{string.call('r3')}), #{nested.call([14])}, #{variant_u8.call(23)})",
      "(5, #{u64.call(44)}, tuple(#{u64.call(104)}, #{string.call('r4')}), #{nested.call([])}, #{variant_u8.call(24)})",
      "(6, #{u64.call(45)}, tuple(#{u64.call(105)}, #{string.call('r5')}), #{nested.call([15])}, #{variant_u8.call(25)})",
    ]
    "INSERT INTO default.#{table} (id, root_dynamic, pair, nested, unused_variant) VALUES\n" + rows.join(",\n")
  end

  def state_sql(table, filter = "")
    "SELECT id, if(isNull(root_dynamic), 'NULL', concat(dynamicType(root_dynamic), ':', toString(toUInt8(isDynamicElementInSharedData(root_dynamic))))), " \
      "ifNull(toString(dynamicElement(root_dynamic, 'UInt64')), ''), ifNull(dynamicElement(root_dynamic, 'String'), ''), " \
      "concat(dynamicType(tupleElement(pair, 1)), ':', toString(toUInt8(isDynamicElementInSharedData(tupleElement(pair, 1))))), " \
      "concat(dynamicType(tupleElement(pair, 2)), ':', toString(toUInt8(isDynamicElementInSharedData(tupleElement(pair, 2))))), " \
      "ifNull(toString(dynamicElement(tupleElement(pair, 1), 'UInt64')), ''), ifNull(dynamicElement(tupleElement(pair, 2), 'String'), ''), " \
      "arrayStringConcat(arrayMap(x -> concat(dynamicType(x), ':', toString(toUInt8(isDynamicElementInSharedData(x)))), nested), ','), " \
      "arrayStringConcat(arrayMap(x -> ifNull(toString(x), ''), dynamicElement(nested, 'UInt64')), ','), " \
      "toString(variantElement(unused_variant, 'UInt8')) FROM default.#{table} #{filter} ORDER BY id " \
      "SETTINGS print_pretty_type_names=0 FORMAT TSVRaw"
  end

  def check_table_values(key, expected)
    table = TABLES.fetch(key)[:table]
    types = query_success(key, "types", "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
    require!(types == TYPES, "#{key}: system.columns differs from the independent literal type roster: #{types.inspect}")
    check = query_success(key, "check", "CHECK TABLE default.#{table} FORMAT TSVRaw")
    require!(["1\t\n", "1\n", "all_1_1_0\t1\t\n"].include?(check), "#{key}: CHECK TABLE did not report success: #{check.inspect}")
    full = query_success(key, "full-values", state_sql(table))
    require!(full == expected, "#{key}: full six-row literal oracle mismatch: #{full.inspect}")
    middle = query_success(key, "middle-values", state_sql(table, "WHERE id IN (3,4)"))
    require!(middle == CLEAN_MIDDLE, "#{key}: middle-window literal oracle mismatch: #{middle.inspect}")
    {full: full, middle: middle}
  end

  def source_identity
    require!(File.directory?(W156_SOURCE_ROOT) && !File.symlink?(W156_SOURCE_ROOT), "pinned unbuilt source reference is absent or symlinked")
    revision = record_process("source:rev-parse", ["git", "-C", W156_SOURCE_ROOT, "rev-parse", "HEAD"])
    require!(revision[:status].success? && revision[:stdout].strip == W156_SOURCE_REVISION,
      "source HEAD differs from pinned reference: #{revision[:stdout].inspect} #{revision[:stderr]}")
    dirty = record_process("source:status", ["git", "-C", W156_SOURCE_ROOT, "status", "--porcelain", "--untracked-files=normal"])
    require!(dirty[:status].success? && dirty[:stdout].empty?, "pinned source reference is not clean: #{dirty[:stdout].inspect}")
    W156_SOURCE_REVISION
  end

  def validate_binary_and_driver
    require!(File.file?(@binary) && File.executable?(@binary) && !File.symlink?(@binary), "pinned ClickHouse executable absent, non-executable, or symlinked")
    digest = Digest::SHA256.file(@binary).hexdigest
    require!(digest == W156_RUNTIME_SHA256, "pinned runtime SHA-256 differs: #{digest}")
    require!(File.file?(@driver) && File.executable?(@driver) && !File.symlink?(@driver), "compiled Crystal driver absent, non-executable, or symlinked")
    [digest, Digest::SHA256.file(@driver).hexdigest]
  end

  def identify_runtime(key)
    version = query_success(key, "runtime-version", "SELECT version() FORMAT TSVRaw")
    require!(version.strip == W156_VERSION, "#{key}: runtime version differs: #{version.inspect}")
    build = query_success(key, "runtime-build", "SELECT concat(name, '=', value) FROM system.build_options WHERE name IN ('GIT_HASH','VERSION_GITHASH') ORDER BY name FORMAT TSVRaw")
    expected = "GIT_HASH=#{W156_BUILD_HASH}\nVERSION_GITHASH=#{W156_BUILD_HASH}\n"
    require!(build == expected, "#{key}: runtime build identity differs: #{build.inspect}")
  end

  def create_table(key, with_rows: false)
    table = TABLES.fetch(key)[:table]
    query_success(key, "create-table", table_create_sql(table))
    query_success(key, "insert-six-rows", insert_sql(table)) if with_rows
  end

  def find_stock_part
    table = TABLES.fetch(:stock)[:table]
    output = query_success(:stock, "active-wide-part",
      "SELECT name, rows, part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active=1 ORDER BY name FORMAT TSVRaw")
    rows = output.lines.map { |line| line.chomp.split("\t", -1) }
    require!(rows.size == 1 && rows.first.size == 4, "expected exactly one active stock part: #{output.inspect}")
    name, count, type, path = rows.first
    require!(name == "all_1_1_0" && count == "6" && type == "Wide", "stock fixture is not one six-row all_1_1_0 Wide part: #{rows.first.inspect}")
    store = File.realpath(File.join(@root, "stores", TABLES.fetch(:stock)[:store]))
    part = File.realpath(path)
    require!(part.start_with?(store + File::SEPARATOR) && File.basename(part) == name,
      "stock part path escaped isolated stock store or part identity differs")
    part
  end

  def copy_borrowed_part(source, lane)
    destination = File.join(@root, "parts", lane, "all_1_1_0")
    parent = File.join(@root, "parts", lane)
    Dir.mkdir(parent, 0o700)
    require!(!File.exist?(destination) && !File.symlink?(destination), "refusing to overwrite copied #{lane} part")
    FileUtils.cp_r(source, destination)
    require!(File.directory?(destination) && !File.symlink?(destination), "copied #{lane} part is absent or symlinked")
    destination
  end

  def data_path(key)
    table = TABLES.fetch(key)[:table]
    output = query_success(key, "table-data-path", "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw")
    path = output.strip
    store = File.realpath(File.join(@root, "stores", TABLES.fetch(key)[:store]))
    expanded = File.expand_path(path)
    require!(path.start_with?("/") && expanded.start_with?(store + File::SEPARATOR), "#{key}: ClickHouse data path escaped isolated store")
    cursor = "/"
    expanded.split("/").reject(&:empty?).each do |component|
      cursor = File.join(cursor, component)
      require!(!File.symlink?(cursor), "#{key}: data path traverses symlink #{cursor}")
    end
    require!(File.directory?(expanded), "#{key}: data path is not a directory")
    expanded
  end

  def attach_part(key, part)
    path = data_path(key)
    detached = File.join(path, "detached")
    Dir.mkdir(detached, 0o700) unless File.directory?(detached)
    require!(!File.symlink?(detached) && File.realpath(detached) == detached, "#{key}: detached directory is symlinked")
    destination = File.join(detached, "all_1_1_0")
    require!(!File.exist?(destination) && !File.symlink?(destination), "#{key}: refusing to overwrite detached part")
    FileUtils.cp_r(part, destination)
    result = query(key, "attach-part", "ALTER TABLE default.#{TABLES.fetch(key)[:table]} ATTACH PART 'all_1_1_0'")
    require!(result[:status].success?, "#{key}: ATTACH PART failed: #{result[:stderr].inspect}")
  end

  def call_crystal_driver(stock_part, library_part, mutant_part)
    argv = [@driver, "--qualify", @root, stock_part, library_part, mutant_part]
    result = record_process("crystal-physical-binding-driver", argv)
    base = File.join(@root, "results", "driver", "w156")
    write_process_evidence(base, result)
    require!(result[:status].success?, "Crystal physical-binding consumer failed: #{result[:stderr].inspect}")
    require!(result[:stdout].include?("W156 stock Dynamic physical binder qualification PASS columns=4 rows=6 marks=3 profile=single_stream"),
      "Crystal consumer omitted its finite PASS witness: #{result[:stdout].inspect}")
    result
  end

  def run_independent_oracle
    require!(File.file?(W156_SOURCE_ORACLE) && !File.symlink?(W156_SOURCE_ORACLE), "independent Ruby literal recheck is missing or symlinked")
    digest = Digest::SHA256.file(W156_SOURCE_ORACLE).hexdigest
    result = record_process("independent-ruby-literal-recheck",
      [RbConfig.ruby, W156_SOURCE_ORACLE, @root], {"TZ" => "UTC", "W156_EXECUTE_AS_ROOT" => "YES"})
    require!(Digest::SHA256.file(W156_SOURCE_ORACLE).hexdigest == digest,
      "independent Ruby literal recheck changed while it was being executed")
    base = File.join(@root, "results", "independent-recheck")
    write_process_evidence(base, result)
    require!(result[:status].success? && result[:stdout].include?("PASS independent Ruby W156 literal oracle"),
      "independent Ruby stock/library/mutant recheck failed: #{result[:stderr].inspect} #{result[:stdout].inspect}")
    digest
  end

  def write_logs(runtime_sha, driver_sha, source_revision, oracle_sha)
    command_lines = @commands.each_with_index.map do |command, index|
      [format("%03d", index + 1), command[:label], command[:exitstatus], command[:success],
       command[:stdout_sha256], command[:stderr_sha256], JSON.generate(command[:argv])].join("\t")
    end
    write_new(File.join(@root, "results", "commands.tsv"),
      "sequence\tlabel\texitstatus\tsuccess\tstdout_sha256\tstderr_sha256\targv_json\n" + command_lines.join("\n") + "\n")
    manifest = [
      "qualification=finite stock Wide Dynamic physical binder in borrowed stock envelopes",
      "runtime_version=#{W156_VERSION}",
      "runtime_build_hash=#{W156_BUILD_HASH}",
      "runtime_sha256=#{runtime_sha}",
      "source_reference=#{W156_SOURCE_ROOT}@#{source_revision}",
      "source_worktree=clean",
      "source_is_unbuilt_reference_only; runtime build lineage is not asserted",
      "driver=#{@driver}",
      "driver_sha256=#{driver_sha}",
      "independent_ruby_oracle=#{W156_SOURCE_ORACLE}",
      "independent_ruby_oracle_sha256=#{oracle_sha}",
      "profile=single_stream; serialization_info_version=with_types; Dynamic V3; BASIC discriminators; nested type-version propagation enabled",
      "fixture=4 typed columns; 6 rows; 3 real marks with 2 rows each; exact W155 literal rosters/grids/values",
      "library=all planner-mapped Dynamic structure/data files re-encoded inside copied borrowed Wide envelope; checksums rebuilt",
      "mutant=valid root UInt64 42-to-43 physical lane rewrite; checksums rebuilt; stock CHECK must pass while independent full-value literal differs",
      "scope=finite runtime evidence only for this exact single_stream fixture; no native claim for other String profiles, LowCardinality profiles, COMPACT, with_size_stream, older structure versions, Object, complete-part writing, or general storage admission",
      "source_only=physical basenames/prefix ownership follow supplied normalized BinaryDynamicBulkPlan; other serializer and LC layouts remain source/spec observations without native qualification",
      "actual_processes=#{@commands.size}; exact argv, exit statuses, and stdout/stderr digests are in results/commands.tsv",
    ].join("\n") + "\n"
    write_new(File.join(@root, "results", "manifest.txt"), manifest)
  end

  def run
    require!(ENV["W156_EXECUTE_AS_ROOT"] == "YES", "explicit W156_EXECUTE_AS_ROOT=YES guard required")
    @root = validate_scratch(@options.fetch(:scratch))
    @driver = File.expand_path(@options.fetch(:driver))
    @binary = File.expand_path(@options.fetch(:binary))
    results = File.join(@root, "results")
    Dir.mkdir(results, 0o700)
    Dir.mkdir(File.join(results, "queries"), 0o700)
    Dir.mkdir(File.join(results, "driver"), 0o700)
    %w[stock library mutant].each { |lane| Dir.mkdir(File.join(results, "queries", lane), 0o700) }
    Dir.mkdir(File.join(@root, "stores"), 0o700)
    Dir.mkdir(File.join(@root, "parts"), 0o700)

    runtime_sha, driver_sha = validate_binary_and_driver
    source_revision = source_identity

    TABLES.each_value do |spec|
      store = File.join(@root, "stores", spec[:store])
      Dir.mkdir(store, 0o700)
    end

    create_table(:stock, with_rows: true)
    identify_runtime(:stock)
    check_table_values(:stock, CLEAN_FULL)

    TABLES.each_key do |key|
      next if key == :stock
      create_table(key)
      identify_runtime(key)
    end

    stock_part = find_stock_part
    library_part = copy_borrowed_part(stock_part, "library")
    mutant_part = copy_borrowed_part(stock_part, "mutant")
    driver_result = call_crystal_driver(stock_part, library_part, mutant_part)

    attach_part(:library, library_part)
    attach_part(:mutant, mutant_part)
    library_values = check_table_values(:library, CLEAN_FULL)
    mutant_values = check_table_values(:mutant, MUTANT_FULL)
    require!(library_values[:full] == CLEAN_FULL && library_values[:middle] == CLEAN_MIDDLE,
      "library borrowed envelope differs from exact clean literals")
    require!(mutant_values[:full] != CLEAN_FULL && mutant_values[:middle] == CLEAN_MIDDLE,
      "mutant did not remain CHECK-valid while distinguishing the full-value oracle")

    oracle_sha = run_independent_oracle
    write_logs(runtime_sha, driver_sha, source_revision, oracle_sha)
    summary = [
      "PASS finite W156 stock Dynamic physical-binding qualification",
      "runtime=#{W156_VERSION} build=#{W156_BUILD_HASH} sha256=#{runtime_sha}",
      "source_reference=#{source_revision} (unbuilt; runtime lineage not asserted)",
      "fixture=4 typed columns, 6 rows, 3 real marks; stock, attached library, and attached valid mutant all CHECKed",
      "library=planner consumed and rewrote all Dynamic structure/data files in a copied stock envelope; independent exact value oracle matched",
      "mutant=UInt64 42-to-43 lane rewrite passed CHECK; full literal oracle rejected clean expectation while middle rows remained exact",
      "driver_exit=#{driver_result[:status].exitstatus}; independent_ruby_oracle=#{oracle_sha}",
      "not_qualified=other String/LC profiles, with_size_stream, COMPACT, older versions, complete-part writing, Object, or general storage admission",
    ].join("\n") + "\n"
    write_new(File.join(@root, "results", "summary.txt"), summary)
    puts "PASS W156 finite stock Dynamic physical binder: 4 columns, 6 rows, 3 marks; library + CHECK-valid mutant rechecked independently"
  end
end

options = {binary: W156_DEFAULT_BINARY}
OptionParser.new do |parser|
  parser.banner = "Usage: W156_EXECUTE_AS_ROOT=YES ruby check_dynamic_physical_binding_w156.rb --scratch EMPTY_W156_CHILD --driver COMPILED_CRYSTAL_DRIVER [--binary PINNED_CLICKHOUSE]"
  parser.on("--scratch PATH") { |value| options[:scratch] = value }
  parser.on("--driver PATH") { |value| options[:driver] = value }
  parser.on("--binary PATH") { |value| options[:binary] = value }
end.parse!

begin
  W156Runner.new(options).run
rescue W156Failure => ex
  warn ex.message
  exit 1
end
