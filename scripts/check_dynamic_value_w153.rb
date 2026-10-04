#!/usr/bin/env ruby
# Paired Dynamic RowBinary value qualification plus a stock-only prerequisite.
# Ruby supplies independent literal fixtures; root supplies the built driver.
require "digest"
require "open3"
require "optparse"

VERSION = "26.10.1.1201"
BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-b94acbe3"
SOURCE_REVISION = "b94acbe318f8459ac88b35647f4e2293d8e225db"
SCRATCH_ROOT_PREFIX = "/private/tmp/crystal-click-w153-"
DEFAULT_BINARY = "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped"

class W153Failure < StandardError; end

def w153_fail!(message)
  raise W153Failure, "W153 stock probe: #{message}"
end

def w153_require(condition, message)
  w153_fail!(message) unless condition
end

def write_new_file(path, bytes)
  File.open(path, "wbx", 0o600) { |file| file.write(bytes) }
rescue Errno::EEXIST
  w153_fail!("refusing to overwrite #{path}")
end

def validate_scratch(path)
  w153_require(Dir.exist?(path) && !File.symlink?(path), "caller scratch directory is absent or a symlink")
  scratch = File.realpath(path)
  w153_require(File.expand_path(path) == scratch, "caller scratch path is not canonical")
  parent = File.dirname(scratch)
  w153_require(File.realpath(parent) == parent, "scratch parent is not canonical")
  w153_require(File.dirname(parent) == "/private/tmp" && File.basename(parent).start_with?(SCRATCH_ROOT_PREFIX.delete_prefix("/private/tmp/")),
    "scratch must be a direct child of a /private/tmp/crystal-click-w153-* root")
  w153_require(File.dirname(scratch) == parent, "scratch must be a direct child of its W153 root")
  w153_require(Dir.children(scratch).empty?, "caller scratch directory must be empty")
  scratch
end

class W153StockQueries
  attr_reader :sequence

  def initialize(binary, root)
    @binary = binary
    @query_dir = File.join(root, "results", "stock")
    @store_root = File.join(root, "stores")
    Dir.mkdir(@query_dir, 0o700)
    Dir.mkdir(@store_root, 0o700)
    @sequence = 0
  end

  def call(label, sql)
    @sequence += 1
    safe_label = label.gsub(/[^A-Za-z0-9_.-]/, "_")
    base = File.join(@query_dir, format("%03d-%s", @sequence, safe_label))
    store = File.join(@store_root, format("%03d-%s", @sequence, safe_label))
    Dir.mkdir(store, 0o700)
    write_new_file(base + ".sql", sql + ";\n")

    args = [
      @binary, "local", "--path", store, "--session_timezone=UTC",
      "--print_pretty_type_names=0", "--max_threads=1",
      "--max_memory_usage=536870912", "--query", sql,
    ]
    stdout, stderr, status = Open3.capture3({"TZ" => "UTC"}, *args)
    write_new_file(base + ".stdout", stdout.b)
    write_new_file(base + ".stderr", stderr.b)
    [base + ".sql", base + ".stdout", base + ".stderr"].each do |path|
      w153_require(File.size(path) <= 16 * 1024 * 1024, "evidence file exceeds 16 MiB: #{path}")
    end
    {success: status.success?, exitstatus: status.exitstatus, stdout: stdout.b, stderr: stderr.b}
  end
end

def probe_cases
  # Dynamic RowBinary is <binary type descriptor><typed scalar body>. These
  # literal descriptors intentionally come from the pinned source grammar,
  # not from the Crystal codec under investigation.
  u64_42 = "04 2a 00 00 00 00 00 00 00".delete(" ")
  u64_43 = "04 2b 00 00 00 00 00 00 00".delete(" ")
  nullable_u64_42 = "23 04 00 2a 00 00 00 00 00 00 00".delete(" ")
  variant_u64_42 = "2a 01 04 00 2a 00 00 00 00 00 00 00".delete(" ")
  nested_dynamic_u64_42 = "2b 20 04 2a 00 00 00 00 00 00 00".delete(" ")

  cases = [
    ["null", "00"],
    ["u64-42", u64_42],
    ["u64-43-control", u64_43],
    ["nullable-u64-42", nullable_u64_42],
    ["variant-u64-42", variant_u64_42],
    ["dynamic-u64-42", nested_dynamic_u64_42],
  ]
  [0, 1].flat_map do |cap|
    cases.map { |label, row_hex| ["#{label}-cap#{cap}", cap, row_hex] }
  end
end

def qualification_cases
  u64_42 = "042a00000000000000"

  [
    {label: "null", cap: 0, declared: "Dynamic(max_types=0)", actual: "None", hex: "00"},
    {label: "null-explicit-nothing", cap: 0, declared: "Dynamic(max_types=0)", actual: "None", hex: "00"},
    {label: "u64-42", cap: 0, declared: "Dynamic(max_types=0)", actual: "UInt64", hex: u64_42},
    {label: "u64-42", cap: 1, declared: "Dynamic(max_types=1)", actual: "UInt64", hex: u64_42},
    {label: "u64-42", cap: 254, declared: "Dynamic(max_types=254)", actual: "UInt64", hex: u64_42},
    {label: "string-nul", cap: 0, declared: "Dynamic(max_types=0)", actual: "String", hex: "1503610062"},
    {label: "nullable-null", cap: 0, declared: "Dynamic(max_types=0)", actual: "Nullable(UInt64)", hex: "230401"},
    {label: "nullable-u64-42", cap: 0, declared: "Dynamic(max_types=0)", actual: "Nullable(UInt64)", hex: "2304002a00000000000000"},
    {label: "variant-null", cap: 0, declared: "Dynamic(max_types=0)", actual: "Variant(UInt64)", hex: "2a0104ff"},
    {label: "variant-u64-42", cap: 0, declared: "Dynamic(max_types=0)", actual: "Variant(UInt64)", hex: "2a0104002a00000000000000"},
    {label: "nested-dynamic-null", cap: 0, declared: "Dynamic(max_types=0)", actual: "Dynamic", hex: "2b2000"},
    {label: "nested-dynamic-u64-42", cap: 0, declared: "Dynamic(max_types=0)", actual: "Dynamic", hex: "2b20042a00000000000000"},
    {label: "array-dynamic-mixed", cap: 0, declared: "Dynamic(max_types=0)", actual: "Array(Dynamic)", hex: "1e2b2003042a0000000000000015017800"},
    {label: "array-nothing-empty", cap: 0, declared: "Dynamic(max_types=0)", actual: "Array(Nothing)", hex: "1e0000"},
  ]
end

def qualification_native_expressions
  {
    "null" => "CAST(NULL, 'Dynamic(max_types=0)')",
    "u64-42" => "CAST(toUInt64(42), 'Dynamic(max_types=0)')",
    "string-nul" => "CAST(unhex('610062'), 'Dynamic(max_types=0)')",
    "array-dynamic-mixed" => "CAST([CAST(toUInt64(42), 'Dynamic'), CAST('x', 'Dynamic'), CAST(NULL, 'Dynamic')], 'Dynamic(max_types=0)')",
  }
end

def validate_driver(path)
  w153_require(File.file?(path) && File.executable?(path) && !File.symlink?(path),
    "compiled Crystal driver is absent, non-executable, or a symlink")
  digest = Digest::SHA256.file(path).hexdigest
  [File.expand_path(path), digest]
end

def call_driver(driver, root, label, *arguments)
  directory = File.join(root, "results", "driver")
  safe_label = label.gsub(/[^A-Za-z0-9_.-]/, "_")
  base = File.join(directory, safe_label)
  stdout, stderr, status = Open3.capture3({}, driver, *arguments)
  write_new_file(base + ".stdout", stdout.b)
  write_new_file(base + ".stderr", stderr.b)
  [base + ".stdout", base + ".stderr"].each do |path|
    w153_require(File.size(path) <= 16 * 1024 * 1024, "driver evidence file exceeds 16 MiB: #{path}")
  end
  {success: status.success?, exitstatus: status.exitstatus, stdout: stdout.b, stderr: stderr.b}
end

def check_observation(result, expected_actual, expected_hex, label)
  w153_require(result[:success], "#{label}: stock query failed: #{result[:stderr].inspect}")
  rows = result[:stdout].lines.map { |line| line.chomp.split("\t", -1) }
  w153_require(rows.size == 1 && rows.first.size == 2, "#{label}: expected one dynamicType/body row, got #{result[:stdout].inspect}")
  actual, row_hex = rows.first
  w153_require(actual == expected_actual, "#{label}: expected dynamicType #{expected_actual.inspect}, got #{actual.inspect}")
  w153_require(row_hex.downcase == expected_hex, "#{label}: expected literal RowBinary body #{expected_hex}, got #{row_hex.inspect}")
  [actual, row_hex.downcase]
end

def qualification_main(options)
  w153_require(!options[:probe_only], "--driver and --probe-only are mutually exclusive")
  w153_require(options[:scratch], "--scratch is required; runner never creates or reuses a scratch directory")
  root = validate_scratch(options[:scratch])
  results = File.join(root, "results")
  Dir.mkdir(results, 0o700)
  driver_dir = File.join(results, "driver")
  Dir.mkdir(driver_dir, 0o700)

  driver, driver_digest = validate_driver(options[:driver])
  binary = options[:binary]
  w153_require(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary),
    "pinned ClickHouse executable is absent, non-executable, or a symlink")
  digest = Digest::SHA256.file(binary).hexdigest
  w153_require(digest == EXECUTABLE_SHA256, "runtime SHA-256 differs: #{digest}")

  source, source_error, source_status = Open3.capture3("git", "-C", SOURCE_ROOT, "rev-parse", "HEAD")
  w153_require(source_status.success? && source.strip == SOURCE_REVISION,
    "pinned shallow source revision differs: #{source.strip.inspect} #{source_error}")
  source_changes, source_changes_error, source_changes_status = Open3.capture3(
    "git", "-C", SOURCE_ROOT, "status", "--porcelain", "--untracked-files=normal"
  )
  w153_require(source_changes_status.success? && source_changes.empty?,
    "pinned source tree is not clean: #{source_changes.inspect} #{source_changes_error}")

  queries = W153StockQueries.new(binary, root)
  version = queries.call("version", "SELECT version() FORMAT TSVRaw")
  w153_require(version[:success] && version[:stdout].strip == VERSION,
    "runtime version differs: #{version[:stdout].inspect} #{version[:stderr]}")
  build = queries.call("build-identity",
    "SELECT concat(name, '=', value) FROM system.build_options " \
    "WHERE name IN ('GIT_HASH','VERSION_GITHASH') ORDER BY name FORMAT TSVRaw")
  expected_build = "GIT_HASH=#{BUILD_HASH}\nVERSION_GITHASH=#{BUILD_HASH}\n"
  w153_require(build[:success] && build[:stdout] == expected_build,
    "runtime build identity differs: #{build[:stdout].inspect} #{build[:stderr]}")

  manifest = [
    "qualification=typed Dynamic logical RowBinary value kernel",
    "runtime_version=#{VERSION}",
    "runtime_sha256=#{digest}",
    "runtime_build_hash=#{BUILD_HASH}",
    "source_reference=#{SOURCE_ROOT}@#{source.strip}",
    "source_worktree=clean",
    "source_is_reference_only; it is not asserted to build the runtime",
    "driver=#{driver}",
    "driver_sha256=#{driver_digest}",
    "literal_expectations=independent Ruby fixtures from the pinned binary type grammar and ordinary RowBinary scalar bodies",
    "directions=Crystal public encode_value to stock parse/dynamicType/exact re-encode; stock SQL expressions to Ruby literal check and Crystal decode_value/semantic comparison/exact re-encode",
    "nominal_caps=0,1,254 cross-checked on UInt64; recursive selected types use cap0",
    "physical_boundary=separate --probe-only evidence records cap0/cap1 wrapper outcomes; cap1 ColumnDynamic admission is not a logical codec reject",
    "nothing_boundary=Dynamic Nothing NULL is admitted; empty Array(Nothing) is admitted; ordinary nonempty Nothing remains refused",
    "negative_control=valid UInt64 43 body is accepted and re-encoded by stock but must fail Crystal semantic expectation for UInt64 42",
    "not_a_gate=does not qualify stored Dynamic layouts, bulk/default, Object/JSON, Compact, projections, or part support",
  ].join("\n") + "\n"
  write_new_file(File.join(results, "manifest.txt"), manifest)

  emitted = call_driver(driver, root, "emit", "--emit")
  w153_require(emitted[:success], "Crystal emitter failed: #{emitted[:stderr].inspect}")
  cases = qualification_cases
  expected_lines = cases.map do |entry|
    ["VALUE", entry[:label], entry[:cap], entry[:declared], entry[:actual], entry[:hex]].join("\t")
  end
  expected_lines << "GUARD\tarray-nothing-nonempty\trefused\tNothing has no ordinary non-NULL scalar representation"
  observed_lines = emitted[:stdout].lines.map(&:chomp)
  w153_require(observed_lines == expected_lines,
    "Crystal public encoder differs from independent literal fixtures or Nothing guard; expected #{expected_lines.inspect}, got #{observed_lines.inspect}")
  emitted_values = observed_lines.take(cases.size).to_h do |line|
    fields = line.split("\t", -1)
    [[fields[1], fields[2].to_i], fields[5]]
  end

  summary = ["direction\tcase\tcap\tresult\tdynamic_type\trowbinary_hex\tstock_stdout\tstock_stderr\tdriver_stdout\tdriver_stderr"]
  cases.each do |entry|
    emitted_hex = emitted_values.fetch([entry[:label], entry[:cap]])
    sql = "SELECT dynamicType(d), lower(hex(formatRow('RowBinary', d))) " \
          "FROM format('RowBinary', 'd Dynamic(max_types=#{entry[:cap]})', unhex('#{emitted_hex}')) " \
          "SETTINGS print_pretty_type_names=0 FORMAT TSVRaw"
    result = queries.call("library-to-stock-#{entry[:label]}-cap#{entry[:cap]}", sql)
    actual, row_hex = check_observation(result, entry[:actual], entry[:hex], "library-to-stock #{entry[:label]} cap#{entry[:cap]}")
    verify = call_driver(driver, root, "verify-library-to-stock-#{entry[:label]}-cap#{entry[:cap]}",
      "--verify", entry[:label], entry[:cap].to_s, row_hex)
    expected_verify = ["VERIFIED", entry[:label], entry[:cap], entry[:declared], entry[:actual], row_hex].join("\t") + "\n"
    w153_require(verify[:success] && verify[:stdout] == expected_verify,
      "Crystal did not semantically verify the stock re-encoded #{entry[:label]} body: status=#{verify[:exitstatus].inspect} stdout=#{verify[:stdout].inspect} stderr=#{verify[:stderr].inspect}")
    base = format("%03d-library-to-stock-%s-cap%d", queries.sequence, entry[:label], entry[:cap])
    summary << ["library-to-stock", entry[:label], entry[:cap], "exact", actual, row_hex,
      "stock/#{base}.stdout", "stock/#{base}.stderr",
      "driver/verify-library-to-stock-#{entry[:label]}-cap#{entry[:cap]}.stdout",
      "driver/verify-library-to-stock-#{entry[:label]}-cap#{entry[:cap]}.stderr"].join("\t")
  end

  native_cases = qualification_cases.select { |entry| qualification_native_expressions.key?(entry[:label]) }.uniq { |entry| entry[:label] }
  native_cases.each do |entry|
    expression = qualification_native_expressions.fetch(entry[:label])
    sql = "SELECT dynamicType(d), lower(hex(formatRow('RowBinary', d))) " \
          "FROM (SELECT #{expression} AS d) " \
          "SETTINGS print_pretty_type_names=0 FORMAT TSVRaw"
    result = queries.call("stock-to-library-#{entry[:label]}", sql)
    actual, row_hex = check_observation(result, entry[:actual], entry[:hex], "stock generated #{entry[:label]}")
    verify = call_driver(driver, root, "verify-stock-#{entry[:label]}", "--verify", entry[:label], "0", row_hex)
    expected_verify = ["VERIFIED", entry[:label], 0, entry[:declared], entry[:actual], row_hex].join("\t") + "\n"
    w153_require(verify[:success] && verify[:stdout] == expected_verify,
      "Crystal stock-byte semantic verification failed for #{entry[:label]}: status=#{verify[:exitstatus].inspect} stdout=#{verify[:stdout].inspect} stderr=#{verify[:stderr].inspect}")
    base = format("%03d-stock-to-library-%s", queries.sequence, entry[:label])
    summary << ["stock-to-library", entry[:label], 0, "literal-and-semantic-exact", actual, row_hex,
      "stock/#{base}.stdout", "stock/#{base}.stderr", "driver/verify-stock-#{entry[:label]}.stdout", "driver/verify-stock-#{entry[:label]}.stderr"].join("\t")
  end

  u64_43 = "042b00000000000000"
  wrong_sql = "SELECT dynamicType(d), lower(hex(formatRow('RowBinary', d))) " \
              "FROM format('RowBinary', 'd Dynamic(max_types=0)', unhex('#{u64_43}')) " \
              "SETTINGS print_pretty_type_names=0 FORMAT TSVRaw"
  wrong_result = queries.call("wrong-value-42-to-43-stock-control", wrong_sql)
  actual, row_hex = check_observation(wrong_result, "UInt64", u64_43, "valid stock 42-to-43 control")
  wrong_verify = call_driver(driver, root, "wrong-value-semantic-control", "--verify", "u64-42", "0", row_hex)
  w153_require(!wrong_verify[:success] && wrong_verify[:stderr].include?("W153 semantic mismatch [u64-42]"),
    "valid wrong-value control was not rejected for semantic mismatch: status=#{wrong_verify[:exitstatus].inspect} stderr=#{wrong_verify[:stderr].inspect}")
  summary << ["negative-control", "u64-43-rejected-by-42-expectation", 0, "stock-valid-crystal-semantic-mismatch", actual, row_hex,
    "stock/#{format('%03d-wrong-value-42-to-43-stock-control', queries.sequence)}.stdout",
    "stock/#{format('%03d-wrong-value-42-to-43-stock-control', queries.sequence)}.stderr",
    "driver/wrong-value-semantic-control.stdout", "driver/wrong-value-semantic-control.stderr"].join("\t")

  write_new_file(File.join(results, "summary.tsv"), summary.join("\n") + "\n")
  puts "W153 typed Dynamic value qualification captured #{cases.size} literal cases, #{native_cases.size} stock-generated cases, and the semantic negative control under #{root}"
end

def main
  options = {binary: DEFAULT_BINARY, scratch: nil, probe_only: false, driver: nil}
  OptionParser.new do |parser|
    parser.banner = "Usage: ruby scripts/check_dynamic_value_w153.rb (--probe-only | --driver PATH) --scratch EMPTY_W153_SUBDIR [--binary PATH]"
    parser.on("--binary PATH", "Pinned ClickHouse executable") { |value| options[:binary] = value }
    parser.on("--scratch PATH", "Caller-created empty direct child of a /private/tmp/crystal-click-w153-* root") { |value| options[:scratch] = value }
    parser.on("--probe-only", "Run the stock-only actual-type admission prerequisite") { options[:probe_only] = true }
    parser.on("--driver PATH", "Run paired library/stock Dynamic value qualification using a caller-built Crystal driver") { |value| options[:driver] = value }
  end.parse!

  if options[:driver]
    qualification_main(options)
    return
  end

  w153_require(options[:probe_only], "--probe-only is required until the library Dynamic value API is confirmed")
  w153_require(options[:scratch], "--scratch is required; runner never creates or reuses a scratch directory")
  root = validate_scratch(options[:scratch])
  results = File.join(root, "results")
  Dir.mkdir(results, 0o700)

  binary = options[:binary]
  w153_require(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary),
    "pinned ClickHouse executable is absent, non-executable, or a symlink")
  digest = Digest::SHA256.file(binary).hexdigest
  w153_require(digest == EXECUTABLE_SHA256, "runtime SHA-256 differs: #{digest}")

  source, source_error, source_status = Open3.capture3("git", "-C", SOURCE_ROOT, "rev-parse", "HEAD")
  w153_require(source_status.success? && source.strip == SOURCE_REVISION,
    "pinned shallow source revision differs: #{source.strip.inspect} #{source_error}")
  source_changes, source_changes_error, source_changes_status = Open3.capture3(
    "git", "-C", SOURCE_ROOT, "status", "--porcelain", "--untracked-files=normal"
  )
  w153_require(source_changes_status.success? && source_changes.empty?,
    "pinned source tree is not clean: #{source_changes.inspect} #{source_changes_error}")

  queries = W153StockQueries.new(binary, root)
  version = queries.call("version", "SELECT version() FORMAT TSVRaw")
  w153_require(version[:success] && version[:stdout].strip == VERSION,
    "runtime version differs: #{version[:stdout].inspect} #{version[:stderr]}")
  build = queries.call("build-identity",
    "SELECT concat(name, '=', value) FROM system.build_options " \
    "WHERE name IN ('GIT_HASH','VERSION_GITHASH') ORDER BY name FORMAT TSVRaw")
  expected_build = "GIT_HASH=#{BUILD_HASH}\nVERSION_GITHASH=#{BUILD_HASH}\n"
  w153_require(build[:success] && build[:stdout] == expected_build,
    "runtime build identity differs: #{build[:stdout].inspect} #{build[:stderr]}")

  manifest = [
    "probe=Dynamic RowBinary actual-type admission only",
    "runtime_version=#{VERSION}",
    "runtime_sha256=#{digest}",
    "runtime_build_hash=#{BUILD_HASH}",
    "source_reference=#{SOURCE_ROOT}@#{source.strip}",
    "source_worktree=clean",
    "source_is_reference_only; it is not asserted to build the runtime",
    "schema_caps=0,1; every case uses a fresh stock local store",
    "observations=toTypeName,dynamicType,isDynamicElementInSharedData,hex(formatRow(RowBinary,value))",
    "scope=one-value Dynamic RowBinary decode, ColumnDynamic placement, and RowBinary re-encode only",
    "not_a_gate=successful capture does not qualify decoding or prove a claimed layout",
    "interpretation=toTypeName is declared cap; dynamicType is logical actual type (None for NULL); shared flag distinguishes shared placement; RowBinary hex is the re-encoded logical envelope",
    "controls=UInt64 42/43 differ only in payload bytes; compare cap0/cap1 for the same envelope; NULL alone cannot distinguish caps",
    "wrapper_readout=cap0 shared acceptance plus cap1 query error is evidence consistent with no-room spill preceding direct Variant-arm admission; inspect exact stderr and all four outputs before claiming it",
    "query_error=not automatically semantic rejection; inspect captured stderr for decoder, arm-admission, or unrelated query/setup failure",
  ].join("\n") + "\n"
  write_new_file(File.join(results, "manifest.txt"), manifest)

  summary = ["case\tcap\tresult\tdeclared_type\tdynamic_type\tin_shared\trowbinary_hex\tstdout_file\tstderr_file"]
  probe_cases.each do |label, cap, row_hex|
    sql = "SELECT toTypeName(d), dynamicType(d), isDynamicElementInSharedData(d), " \
          "hex(formatRow('RowBinary', d)) " \
          "FROM format('RowBinary', 'd Dynamic(max_types=#{cap})', unhex('#{row_hex}')) " \
          "SETTINGS print_pretty_type_names=0 FORMAT TSVRaw"
    result = queries.call(label, sql)
    fields = result[:stdout].lines.map { |line| line.chomp.split("\t", -1) }
    result_name = if !result[:success]
                    "query-error"
                  elsif fields.size == 1 && fields.first.size == 4
                    "one-row"
                  else
                    "unexpected-output"
                  end
    base = format("%03d-%s", queries.sequence, label)
    stdout_file = "stock/#{base}.stdout"
    stderr_file = "stock/#{base}.stderr"
    observed = result_name == "one-row" ? fields.first : ["", "", "", ""]
    summary << [label, cap, result_name, *observed, stdout_file, stderr_file].join("\t")
  end
  write_new_file(File.join(results, "summary.tsv"), summary.join("\n") + "\n")
  puts "W153 stock-only probe captured #{probe_cases.size} case outcomes under #{root}"
end

begin
  main
rescue W153Failure => error
  warn error.message
  exit 1
end
