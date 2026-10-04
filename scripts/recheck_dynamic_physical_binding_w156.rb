#!/usr/bin/env ruby
# Independent literal stock consumer for W156; reads only the three bounded stores.
require "digest"
require "open3"

module DynamicPhysicalW156Recheck
  BINARY = "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped"
  SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  BUILD = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  VERSION = "26.10.1.1201"
  SOURCE = "/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-b94acbe3"
  REVISION = "b94acbe318f8459ac88b35647f4e2293d8e225db"
  MAX_CAPTURE = 1_048_576
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
    "stock" => ["w156_stock", "dynamic_bulk_physical_w156", CLEAN_FULL],
    "library" => ["w156_library", "dynamic_bulk_physical_w156_library", CLEAN_FULL],
    "mutant" => ["w156_mutant", "dynamic_bulk_physical_w156_mutant", MUTANT_FULL],
  }.freeze

  def self.assert(ok, message)
    raise message unless ok
  end

  def self.write_new(path, bytes)
    File.open(path, "wbx", 0o600) { |file| file.write(bytes) }
  rescue Errno::EEXIST
    assert(false, "refusing to overwrite evidence: #{path}")
  end

  def self.checked_root(path)
    assert(path.match?(%r{\A/private/tmp/crystal-click-w156-[A-Za-z0-9._-]+/child\z}), "invalid W156 child path")
    assert(File.directory?(path) && !File.symlink?(path), "missing or symlinked W156 child")
    root = File.realpath(path)
    parent = File.dirname(root)
    assert(root == File.expand_path(path) && File.basename(root) == "child", "W156 child path is not canonical")
    assert(File.realpath(parent) == parent && File.dirname(parent) == "/private/tmp" && File.basename(parent).start_with?("crystal-click-w156-"), "W156 root is outside the bounded /private/tmp scope")
    root
  end

  def self.query(store, sql, output, label)
    assert(File.directory?(store) && !File.symlink?(store), "missing or symlinked store: #{store}")
    assert(File.realpath(store) == File.expand_path(store), "store path traverses a symlink: #{store}")
    assert(File.realpath(store).start_with?(File.dirname(File.dirname(output)) + File::SEPARATOR), "store escaped W156 child")
    base = File.join(output, label)
    write_new(base + ".sql", sql + ";\n")
    stdout, stderr, status = Open3.capture3(
      {"TZ" => "UTC"}, BINARY, "local", "--path", store,
      "--session_timezone=UTC", "--max_threads=1", "--max_insert_threads=1",
      "--max_block_size=1000", "--max_memory_usage=536870912",
      "--max_query_size=1048576", "--allow_suspicious_variant_types=1",
      "--allow_suspicious_low_cardinality_types=1", "--print_pretty_type_names=0",
      "--query", sql
    )
    assert(stdout.bytesize <= MAX_CAPTURE && stderr.bytesize <= MAX_CAPTURE, "oversized ClickHouse capture: #{label}")
    write_new(base + ".stdout", stdout.b)
    write_new(base + ".stderr", stderr.b)
    write_new(base + ".status", status.exitstatus.to_s + "\n")
    assert(status.success?, "stock query failed: #{label}: #{stderr.inspect}")
    stdout.b
  end

  def self.state_sql(table, filter = "")
    "SELECT id, if(isNull(root_dynamic), 'NULL', concat(dynamicType(root_dynamic), ':', toString(toUInt8(isDynamicElementInSharedData(root_dynamic))))), " \
      "ifNull(toString(dynamicElement(root_dynamic, 'UInt64')), ''), ifNull(dynamicElement(root_dynamic, 'String'), ''), " \
      "concat(dynamicType(tupleElement(pair, 1)), ':', toString(toUInt8(isDynamicElementInSharedData(tupleElement(pair, 1))))), " \
      "concat(dynamicType(tupleElement(pair, 2)), ':', toString(toUInt8(isDynamicElementInSharedData(tupleElement(pair, 2))))), " \
      "ifNull(toString(dynamicElement(tupleElement(pair, 1), 'UInt64')), ''), ifNull(dynamicElement(tupleElement(pair, 2), 'String'), ''), " \
      "arrayStringConcat(arrayMap(x -> concat(dynamicType(x), ':', toString(toUInt8(isDynamicElementInSharedData(x)))), nested), ','), " \
      "arrayStringConcat(arrayMap(x -> ifNull(toString(x), ''), dynamicElement(nested, 'UInt64')), ','), " \
      "toString(variantElement(unused_variant, 'UInt8')) FROM default.#{table} #{filter} ORDER BY id SETTINGS print_pretty_type_names=0 FORMAT TSVRaw"
  end

  def self.check_table(root, output, key, expected_full)
    store_name, table, = TABLES.fetch(key)
    store = File.join(root, "stores", store_name)
    type_sql = "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
    actual_types = query(store, type_sql, output, "#{key}_types")
    assert(actual_types == TYPES, "nominal SQL type mismatch for #{key}: #{actual_types.inspect}")
    [["full", "", expected_full], ["middle", " WHERE id IN (3,4)", CLEAN_MIDDLE]].each do |window, filter, expected|
      actual = query(store, state_sql(table, filter), output, "#{key}_#{window}")
      assert(actual == expected, "independent literal value mismatch: #{key} #{window}: #{actual.inspect}")
    end
    check = query(store, "CHECK TABLE default.#{table} FORMAT TSVRaw", output, "#{key}_check")
    assert(["1\t\n", "1\n", "all_1_1_0\t1\t\n"].include?(check), "actual CHECK failed for #{key}: #{check.inspect}")
  end

  def self.run
    assert(ENV["W156_EXECUTE_AS_ROOT"] == "YES", "root-owned serial guard required")
    root = checked_root(ARGV.fetch(0))
    stores = File.join(root, "stores")
    assert(File.directory?(stores) && !File.symlink?(stores) && File.realpath(stores) == stores, "missing or symlinked W156 stores directory")
    assert(File.file?(BINARY) && File.executable?(BINARY) && !File.symlink?(BINARY), "missing pinned ClickHouse executable")
    runtime_sha = Digest::SHA256.file(BINARY).hexdigest
    assert(runtime_sha == SHA256, "pinned runtime SHA mismatch: #{runtime_sha}")
    assert(File.directory?(SOURCE) && !File.symlink?(SOURCE), "missing pinned source reference")
    source, source_error, source_status = Open3.capture3("git", "-C", SOURCE, "rev-parse", "HEAD")
    assert(source_status.success? && source.strip == REVISION, "source HEAD mismatch: #{source.strip.inspect} #{source_error}")
    output = File.join(root, "results", "ruby-recheck")
    assert(!File.exist?(output) && !File.symlink?(output), "refusing to overwrite Ruby recheck output")
    Dir.mkdir(File.dirname(output), 0o700) unless File.directory?(File.dirname(output))
    assert(!File.symlink?(File.dirname(output)) && File.realpath(File.dirname(output)) == File.dirname(output), "unsafe results directory")
    Dir.mkdir(output, 0o700)

    TABLES.each_key do |key|
      store = File.join(root, "stores", TABLES.fetch(key)[0])
      version = query(store, "SELECT version() FORMAT TSVRaw", output, "#{key}_identity_version")
      assert(version == "#{VERSION}\n", "runtime version mismatch in #{key}: #{version.inspect}")
      build = query(store, "SELECT concat(name,'=',value) FROM system.build_options WHERE name IN ('GIT_HASH','VERSION_GITHASH') ORDER BY name FORMAT TSVRaw", output, "#{key}_identity_build")
      assert(build.lines.map(&:strip) == ["GIT_HASH=#{BUILD}", "VERSION_GITHASH=#{BUILD}"], "runtime build mismatch in #{key}")
      expected = key == "mutant" ? MUTANT_FULL : CLEAN_FULL
      check_table(root, output, key, expected)
    end
    mutant_actual = query(File.join(root, "stores", "w156_mutant"), state_sql("dynamic_bulk_physical_w156_mutant"), output, "mutant_sensitivity_control")
    assert(mutant_actual != CLEAN_FULL && mutant_actual == MUTANT_FULL, "43 mutant did not independently distinguish the clean literal")
    summary = "PASS independent Ruby W156 literal stock recheck: 3 stores, exact types, full/middle values, and actual CHECK\nsource_reference=#{REVISION} (unbuilt; runtime lineage not asserted)\nruntime_version=#{VERSION} build=#{BUILD} sha256=#{runtime_sha}\ncontrol=mutant root UInt64 43 matches its independent literal and differs from clean 42; CHECK remains valid\nscope=stock/library/mutant six-row fixture only; no driver, decoded bytes, or manifest used as oracle\n"
    write_new(File.join(output, "summary.txt"), summary)
    puts "PASS independent Ruby W156 literal oracle: stock + library + CHECK-valid 43 mutant"
  end
end

DynamicPhysicalW156Recheck.run
