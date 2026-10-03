#!/usr/bin/env ruby
# Runtime-only JSON/Object LowCardinality discriminator. Root owns execution
# under the serial resource guard; this file must not be run by an authoring
# worker. The executable and source reference are deliberately pinned apart.

require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

module ObjectLowCardinalityW146
  BIN = ENV.fetch("CLICKHOUSE_BIN", "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped")
  EXPECTED_VERSION = "26.10.1.1201"
  EXPECTED_BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  EXPECTED_BINARY_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-9007d227"
  SOURCE_REVISION = "9007d227b64a3f8b667fc5258ceb2923f3cf477d"

  SETTINGS = [
    "index_granularity=2",
    "index_granularity_bytes=10485760",
    "enable_mixed_granularity_parts=1",
    "min_rows_for_wide_part=0",
    "min_bytes_for_wide_part=0",
    "compress_marks=0",
    "compress_primary_key=0",
    "min_compress_block_size=0",
    "max_compress_block_size=4096",
    "ratio_of_defaults_for_sparse_serialization=1",
    "default_compression_codec='LZ4'",
    "object_serialization_version='v3'",
    "object_shared_data_serialization_version_for_zero_level_parts='map'",
    "propagate_types_serialization_versions_to_nested_types=true",
    "map_serialization_version='basic'",
    "map_serialization_version_for_zero_level_parts='basic'"
  ].join(", ")

  TYPES = [
    "LowCardinality(String)",
    "LowCardinality(Nullable(String))",
    "LowCardinality(UInt64)",
    "LowCardinality(Float32)",
    "Array(LowCardinality(String))",
    "Map(String, LowCardinality(String))",
    "Tuple(maybe LowCardinality(Nullable(UInt64)), label String)"
  ].freeze
  JSON_COLUMN_TYPE = "JSON(arr Array(LowCardinality(String)), f LowCardinality(Float32), mp Map(String, LowCardinality(String)), n LowCardinality(UInt64), ns LowCardinality(Nullable(String)), s LowCardinality(String), t Tuple(maybe LowCardinality(Nullable(UInt64)), label String))"
  BFLOAT_JSON_SCHEMA_ERROR = "Code: 43. DB::Exception: JSON serialization doesn't support the return type schema: BFloat16. (ILLEGAL_TYPE_OF_ARGUMENT)"

  ROWS = [
    {"id" => 1, "s" => "red",   "ns" => "a",    "n" => 11, "f" => 1.25,  "arr" => ["red", "blue"], "mp" => {"a" => "red", "b" => "blue"}, "t" => [nil, "t0"]},
    {"id" => 2, "s" => "blue",  "ns" => nil,     "n" => 22, "f" => -3.5,  "arr" => [],               "mp" => {},                             "t" => [11, "t1"]},
    {"id" => 3, "s" => "red",   "ns" => "a",    "n" => 11, "f" => 1.25,  "arr" => ["red"],          "mp" => {"a" => "red"},                  "t" => [nil, "t2"]},
    {"id" => 4, "s" => "",      "ns" => "",     "n" => 33, "f" => 0.0,   "arr" => ["green", ""],   "mp" => {"a" => "green", "c" => ""},  "t" => [33, "t3"]},
    {"id" => 5, "s" => "green", "ns" => nil,     "n" => 22, "f" => 1.25,  "arr" => ["blue", "red"], "mp" => {"b" => "blue"},                 "t" => [22, "t4"]},
    {"id" => 6, "s" => "blue",  "ns" => "b",    "n" => 44, "f" => -3.5,  "arr" => [""],             "mp" => {"a" => ""},                      "t" => [nil, "t5"]},
    {"id" => 7, "s" => "雪",    "ns" => "a",    "n" => 11, "f" => 2.5,   "arr" => ["雪"],           "mp" => {"z" => "雪"},                    "t" => [44, "t6"]}
  ].freeze

  MAIN_DDL = <<~SQL.gsub(/\s+/, " ").strip.freeze
    CREATE TABLE default.p (
      id UInt8,
      j JSON(
        s LowCardinality(String),
        ns LowCardinality(Nullable(String)),
        n LowCardinality(UInt64),
        f LowCardinality(Float32),
        arr Array(LowCardinality(String)),
        mp Map(String, LowCardinality(String)),
        t Tuple(maybe LowCardinality(Nullable(UInt64)), label String)
      )
    ) ENGINE=MergeTree ORDER BY id SETTINGS #{SETTINGS}
  SQL

  def self.fail!(message)
    raise RuntimeError, message
  end

  def self.assert(condition, message)
    fail!(message) unless condition
  end

  def self.write(path, bytes)
    File.binwrite(path, bytes)
  end

  def self.local(binary, store, query, stdin_data: "", extra: [])
    arguments = [
      "local", "--path", store, "--session_timezone=UTC",
      "--enable_time_time64_type=1", "--print_pretty_type_names=0",
      "--query", query
    ] + extra
    Open3.capture3({"TZ" => "UTC"}, binary, *arguments, stdin_data: stdin_data)
  end

  def self.local!(binary, store, query, out_path, extra: [], stdin_data: "")
    stdout, stderr, status = local(binary, store, query, stdin_data: stdin_data, extra: extra)
    write("#{out_path}.stdout", stdout)
    write("#{out_path}.stderr", stderr)
    fail!("ClickHouse command failed (#{status.exitstatus}): #{query}\n#{stderr}") unless status.success?
    stdout
  end

  def self.var_uint(number)
    raise ArgumentError, "negative RowBinary varint" if number.negative?
    output = +"".b
    loop do
      byte = number & 0x7f
      number >>= 7
      if number.zero?
        output << byte
        break
      end
      output << (byte | 0x80)
    end
    output
  end

  def self.rb_string(value)
    bytes = value.encode(Encoding::UTF_8).b
    var_uint(bytes.bytesize) + bytes
  end

  def self.rb_nullable_string(value)
    value.nil? ? "\x01".b : "\x00".b + rb_string(value)
  end

  def self.rb_nullable_uint64(value)
    value.nil? ? "\x01".b : "\x00".b + [value].pack("Q<")
  end

  def self.rowbinary(rows)
    rows.map do |row|
      map_pairs = row.fetch("mp").sort_by { |key, _| key.b }
      [row.fetch("id")].pack("C") +
        rb_string(row.fetch("s")) +
        rb_nullable_string(row.fetch("ns")) +
        [row.fetch("n")].pack("Q<") +
        [row.fetch("f")].pack("e") +
        var_uint(row.fetch("arr").length) + row.fetch("arr").map { |value| rb_string(value) }.join.b +
        var_uint(map_pairs.length) + map_pairs.map { |key, value| rb_string(key) + rb_string(value) }.join.b +
        rb_nullable_uint64(row.fetch("t")[0]) + rb_string(row.fetch("t")[1])
    end.join.b
  end

  def self.json_rows
    ROWS.map do |row|
      {
        "id" => row.fetch("id"),
        "j" => {
          "s" => row.fetch("s"), "ns" => row.fetch("ns"),
          "n" => row.fetch("n"), "f" => row.fetch("f"),
          "arr" => row.fetch("arr"), "mp" => row.fetch("mp"),
          "t" => row.fetch("t")
        }
      }
    end.map { |row| JSON.generate(row) + "\n" }.join
  end

  def self.choose_root
    requested = ENV["W146_PROBE_ROOT"]
    unless requested.nil? || requested.empty?
      match = %r{\A/private/tmp/crystal-click-object-low-cardinality-w146\.([A-Za-z0-9_-]+)\z}.match(requested)
      fail!("W146 root must be a direct /private/tmp namespace child") unless match
      expanded = File.expand_path(requested)
      fail!("W146 root path must already be canonical") unless expanded == requested
      fail!("refusing to overwrite W146 root: #{expanded}") if File.exist?(expanded) || File.symlink?(expanded)
      Dir.mkdir(expanded, 0o700)
      return expanded
    end
    Dir.mktmpdir("crystal-click-object-low-cardinality-w146.", "/private/tmp")
  end

  def self.validate_root(root)
    canonical = File.realpath(root)
    assert(canonical == root, "W146 root is not canonical")
    assert(!File.symlink?(root), "W146 root must not be a symlink")
    assert(%r{\A/private/tmp/crystal-click-object-low-cardinality-w146\.[A-Za-z0-9_-]+\z}.match?(root), "W146 root escaped its direct namespace")
    assert(Dir.children(root).empty?, "W146 output root must be fresh")
  end

  def self.require_expected_rejection(binary, root, label, declaration, cause)
    store = File.join(root, "stores", "reject-#{label}")
    out = File.join(root, "results", "reject-#{label}")
    Dir.mkdir(store)
    Dir.mkdir(out)
    query = "CREATE TABLE default.p (id UInt8, j JSON(v #{declaration})) ENGINE=MergeTree ORDER BY id"
    _stdout, stderr, status = local(binary, store, query)
    write("#{out}/create.stdout", _stdout)
    write("#{out}/create.stderr", stderr)
    exact = "Code: 43. DB::Exception: #{cause}"
    assert(!status.success?, "#{label}: illegal JSON type was admitted")
    assert(stderr.include?(exact), "#{label}: rejection cause changed; expected #{exact.inspect}, got #{stderr.inspect}")
    File.write("#{out}/result.tsv", "rejected\t#{declaration}\t#{cause}\n")
  end

  def self.inventory_part(binary, store, root, table, label, extra)
    out = File.join(root, "results", label)
    part_path = local!(binary, store,
      "SELECT path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name LIMIT 1 FORMAT TSVRaw",
      "#{out}/part-path", extra: extra).strip
    assert(!part_path.empty? && File.directory?(part_path) && !File.symlink?(part_path), "#{label}: active part directory is unavailable")
    canonical_store = File.realpath(store)
    canonical_part = File.realpath(part_path)
    assert(canonical_part.start_with?(canonical_store + File::SEPARATOR), "#{label}: active part escaped isolated ClickHouse store")
    copied = File.join(out, "native-part")
    FileUtils.cp_r(canonical_part, copied, preserve: true)
    entries = Dir.children(copied).sort.map do |name|
      path = File.join(copied, name)
      assert(!File.symlink?(path) && File.file?(path), "#{label}: unexpected non-regular part entry #{name}")
      "#{Digest::SHA256.file(path).hexdigest}\t#{File.size(path)}\t#{name}\n"
    end.join
    File.write("#{out}/part-files.tsv", entries)
    %w[columns.txt columns_substreams.txt serialization.json checksums.txt].each do |name|
      source = File.join(copied, name)
      File.binwrite("#{out}/#{name}", File.binread(source)) if File.file?(source)
    end
  end

  def self.capture_bfloat_control(binary, root, extra)
    store = File.join(root, "stores", "bfloat16")
    out = File.join(root, "results", "bfloat16")
    Dir.mkdir(store)
    Dir.mkdir(out)
    ddl = "CREATE TABLE default.p (id UInt8, j JSON(v LowCardinality(BFloat16))) ENGINE=MergeTree ORDER BY id SETTINGS #{SETTINGS}"
    ddl_out, ddl_err, ddl_status = local(binary, store, ddl, extra: extra)
    write("#{out}/create.stdout", ddl_out)
    write("#{out}/create.stderr", ddl_err)
    unless ddl_status.success?
      assert(ddl_err.include?(BFLOAT_JSON_SCHEMA_ERROR),
        "BFloat16 JSON schema rejection changed: #{ddl_err.inspect}")
      File.write("#{out}/outcome.tsv", "ddl_rejected\t#{ddl_status.exitstatus}\n")
      File.write("#{out}/exact-error.txt", ddl_err)
      return
    end
    fail!("BFloat16 JSON declaration was unexpectedly admitted; the pinned discriminator changed")
  end

  def self.run
    fail!("refusing W146 native probe without root-owned W146_EXECUTE_AS_ROOT=YES") unless ENV["W146_EXECUTE_AS_ROOT"] == "YES"
    assert(File.file?(BIN) && File.executable?(BIN) && !File.symlink?(BIN), "pinned ClickHouse executable is unavailable or symlinked: #{BIN}")
    actual_sha = Digest::SHA256.file(BIN).hexdigest
    assert(actual_sha == EXPECTED_BINARY_SHA256, "runtime executable SHA mismatch: #{actual_sha}")

    root = choose_root
    validate_root(root)
    Dir.mkdir(File.join(root, "stores"))
    Dir.mkdir(File.join(root, "results"))
    identity_store = File.join(root, "stores", "identity")
    identity_out = File.join(root, "results", "identity")
    Dir.mkdir(identity_store)
    Dir.mkdir(identity_out)

    version = local!(BIN, identity_store, "SELECT version() FORMAT TSVRaw", "#{identity_out}/version").strip
    assert(version == EXPECTED_VERSION, "unexpected runtime version: #{version.inspect}")
    build_options = local!(BIN, identity_store,
      "SELECT concat(name, '=', value) FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw",
      "#{identity_out}/build-options").lines.map(&:strip)
    expected_options = ["GIT_HASH=#{EXPECTED_BUILD_HASH}", "VERSION_GITHASH=#{EXPECTED_BUILD_HASH}"]
    assert(build_options == expected_options, "runtime build identity mismatch: #{build_options.inspect}")
    File.write("#{root}/results/run.txt", [
      "probe_root=#{root}", "source_reference_checkout=#{SOURCE_ROOT}",
      "source_reference_revision=#{SOURCE_REVISION}", "runtime_binary=#{BIN}",
      "runtime_sha256=#{actual_sha}", "runtime_version=#{version}",
      *build_options, "claim_scope=fresh_JSON_typed_path_low_cardinality_declaration_and_stock_part_discovery"
    ].join("\n") + "\n")

    extra = ["--allow_suspicious_low_cardinality_types=1"]
    store = File.join(root, "stores", "main")
    out = File.join(root, "results", "main")
    Dir.mkdir(store)
    Dir.mkdir(out)
    File.write("#{out}/ddl.sql", MAIN_DDL + ";\n")
    ddl_out, ddl_err, ddl_status = local(BIN, store, MAIN_DDL, extra: extra)
    write("#{out}/create.stdout", ddl_out)
    write("#{out}/create.stderr", ddl_err)
    assert(ddl_status.success?, "main typed JSON LowCardinality DDL failed: #{ddl_err}")

    fixture = json_rows
    File.write("#{out}/fixture.jsonl", fixture)
    ins_out, ins_err, ins_status = local(BIN, store, "INSERT INTO default.p FORMAT JSONEachRow", stdin_data: fixture, extra: extra)
    write("#{out}/insert.stdout", ins_out)
    write("#{out}/insert.stderr", ins_err)
    assert(ins_status.success?, "main typed JSONEachRow insertion failed: #{ins_err}")

    type_query = "SELECT toTypeName(j.s), toTypeName(j.ns), toTypeName(j.n), toTypeName(j.f), toTypeName(j.arr), toTypeName(j.mp), toTypeName(j.t) FROM default.p ORDER BY id LIMIT 1 FORMAT TSVRaw"
    types = local!(BIN, store, type_query, "#{out}/canonical-types", extra: extra)
    expected_types = TYPES.join("\t") + "\n"
    write("#{out}/expected-types.tsv", expected_types)
    assert(types == expected_types, "typed JSON path canonical types differ: expected #{expected_types.inspect}, got #{types.inspect}")

    columns = local!(BIN, store,
      "SELECT name, type, position FROM system.columns WHERE database='default' AND table='p' ORDER BY position FORMAT TSVRaw",
      "#{out}/system-columns", extra: extra)
    column_rows = columns.lines(chomp: true).map { |line| line.split("\t", 3) }
    assert(column_rows.size == 2 && column_rows[0] == ["id", "UInt8", "1"] &&
      column_rows[1] == ["j", JSON_COLUMN_TYPE, "2"],
      "system.columns did not report the expected id/JSON column roster: #{columns.inspect}")

    full_query = "SELECT id, j.s, j.ns, j.n, j.f, j.arr, j.mp, j.t FROM default.p ORDER BY id FORMAT RowBinary"
    # Open3 returns UTF-8-tagged stdout even for RowBinary; compare the raw
    # bytes (the fixture includes non-ASCII String payloads).
    actual_binary = local!(BIN, store, full_query, "#{out}/full-rowbinary", extra: extra).b
    expected_binary = rowbinary(ROWS)
    File.binwrite("#{out}/full-rowbinary.actual.bin", actual_binary)
    File.binwrite("#{out}/full-rowbinary.expected.bin", expected_binary)
    File.write("#{out}/full-rowbinary.sha256", "actual=#{Digest::SHA256.hexdigest(actual_binary)}\nexpected=#{Digest::SHA256.hexdigest(expected_binary)}\n")
    assert(actual_binary == expected_binary, "full literal RowBinary mismatch: expected #{expected_binary.bytesize} bytes, got #{actual_binary.bytesize}")

    local!(BIN, store, "SHOW CREATE TABLE default.p FORMAT TSVRaw", "#{out}/show-create", extra: extra)
    part_metadata = local!(BIN, store,
      "SELECT name, rows, marks, part_type, bytes_on_disk FROM system.parts WHERE database='default' AND table='p' AND active ORDER BY name FORMAT TSVRaw",
      "#{out}/part-metadata", extra: extra)
    part_fields = part_metadata.lines(chomp: true).map { |line| line.split("\t", 5) }
    assert(part_fields.size == 1 && part_fields[0].size == 5, "expected one complete stock part-metadata row: #{part_metadata.inspect}")
    part_name, part_rows, part_marks, part_type, part_bytes = part_fields[0]
    # system.parts.marks includes the final adaptive-mark sentinel record;
    # the four real row granules are separately fixed by index_granularity=2.
    assert(part_rows == "7" && part_marks == "5" && part_type == "Wide" && part_bytes.to_i.positive?,
      "unexpected stock part rows/marks/type/size: #{part_fields[0].inspect}")
    active = local!(BIN, store,
      "SELECT count() FROM system.parts WHERE database='default' AND table='p' AND active FORMAT TSVRaw",
      "#{out}/active-count", extra: extra).strip
    assert(active == "1", "expected one stock part, got active count #{active.inspect}")
    check = local!(BIN, store, "CHECK TABLE default.p FORMAT TabSeparated", "#{out}/check-table", extra: extra)
    check_rows = check.lines(chomp: true)
    expected_check = "#{part_name}\t1\t\n"
    assert(check == expected_check, "CHECK TABLE output differed from the exact active-part witness: expected #{expected_check.inspect}, got #{check.inspect}")
    inventory_part(BIN, store, root, "p", "main", extra)

    require_expected_rejection(BIN, root, "nullable-lowcard", "Nullable(LowCardinality(String))",
      "Nested type LowCardinality(String) cannot be inside Nullable type")
    require_expected_rejection(BIN, root, "lowcard-decimal", "LowCardinality(Decimal(9, 2))",
      "DataTypeLowCardinality is supported only for numbers, strings, Date or DateTime, but got Decimal(9, 2).")
    capture_bfloat_control(BIN, root, extra)

    File.write("#{root}/results/summary.txt", <<~TEXT)
      main=PASS rows=#{ROWS.size} index_granularity=2 real_row_granules=4 system_parts_marks_including_terminal=5 observed_rows=#{part_rows} observed_marks=#{part_marks} part_type=#{part_type}
      main_paths=#{TYPES.join(" | ")}
      nullable_lowcard_control=exact_rejection
      decimal_lowcard_control=exact_rejection
      bfloat16_json_schema_ddl=exact JSON return-type schema rejection; see results/bfloat16/exact-error.txt
      part_copy=results/main/native-part; part_files=results/main/part-files.tsv
      scope=stock JSON typed-path schema/value/part discovery only; no library whole-part claim
    TEXT
    puts "PASS W146 native typed-JSON LowCardinality discriminator: #{root}"
  end
end

ObjectLowCardinalityW146.run
