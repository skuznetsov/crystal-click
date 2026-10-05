#!/usr/bin/env ruby
# Reproducible stock-only W171 Nested source-law observation.
#
# This command captures ClickHouse-created Nested(flatten_nested=0/1) and
# Array(Tuple(...)) control parts. It does not certify crystal-click support.
# Every invocation uses a fresh retained directory under --workdir.
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "tmpdir"
require "time"

EXPECTED_VERSION = "ClickHouse local version 26.10.1.1201 (official build)."
EXPECTED_BINARY_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
NESTED_TYPE = "Nested(a UInt64, b String, c Nullable(Int32))"
ARRAY_TUPLE_TYPE = "Array(Tuple(a UInt64, b String, c Nullable(Int32)))"

def exclusive_write(path, bytes)
  File.open(path, "wbx", 0o600) { |file| file.write(bytes) }
end

def parse_options
  options = {
    clickhouse: ENV.fetch("CLICKHOUSE_BIN", "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped"),
    workdir: ENV["W171_WORKDIR"],
    source_root: ENV["W171_SOURCE_ROOT"],
    source_label: ENV["W171_SOURCE_LABEL"]
  }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby scripts/probe_nested_storage_w171_source.rb --workdir DIR [options]"
    opts.on("--clickhouse PATH", "Pinned ClickHouse local executable") { |value| options[:clickhouse] = value }
    opts.on("--workdir DIR", "Existing scratch parent; a fresh child is retained") { |value| options[:workdir] = value }
    opts.on("--source-root DIR", "Optional ClickHouse source checkout recorded in the manifest") { |value| options[:source_root] = value }
    opts.on("--source-label REV", "Optional source revision label recorded in the manifest") { |value| options[:source_label] = value }
  end
  parser.parse!
  raise "unexpected arguments: #{ARGV.inspect}" unless ARGV.empty?
  raise "--workdir (or W171_WORKDIR) is required" if options[:workdir].nil? || options[:workdir].empty?
  options[:workdir] = File.realpath(options[:workdir])
  options
end

class W171SourceCapture
  attr_reader :root, :records

  def initialize(root)
    @root = root
    @commands = File.join(root, "commands")
    FileUtils.mkdir_p(@commands, mode: 0o700)
    @records = []
  end

  def run(label, argv, sql = nil)
    index = records.length + 1
    base = format("%03d-%s", index, label.gsub(/[^A-Za-z0-9_.-]/, "_"))
    sql_path = sql.nil? ? nil : File.join(@commands, "#{base}.sql")
    stdout_path = File.join(@commands, "#{base}.stdout")
    stderr_path = File.join(@commands, "#{base}.stderr")
    exclusive_write(sql_path, sql) unless sql.nil?

    stdout = "".b
    stderr = "".b
    begin
      stdout, stderr, status = Open3.capture3({ "TZ" => "UTC" }, *argv, binmode: true)
      status_record = {
        "exitstatus" => status.exitstatus,
        "termsig" => status.termsig,
        "success" => status.success?
      }
    rescue StandardError => error
      status_record = {
        "success" => false,
        "spawn_error_class" => error.class.name,
        "spawn_error" => error.message
      }
    end

    exclusive_write(stdout_path, stdout)
    exclusive_write(stderr_path, stderr)
    record = {
      "label" => label,
      "argv" => argv,
      "sql" => sql,
      "status" => status_record,
      "files" => { "sql" => sql_path, "stdout" => stdout_path, "stderr" => stderr_path },
      "sha256" => {
        "argv_json" => Digest::SHA256.hexdigest(JSON.generate(argv)),
        "sql" => sql.nil? ? nil : Digest::SHA256.hexdigest(sql),
        "stdout" => Digest::SHA256.hexdigest(stdout),
        "stderr" => Digest::SHA256.hexdigest(stderr)
      }
    }
    records << record
    [record, stdout, stderr]
  end
end

class W171SourceProfile
  attr_reader :label, :setting, :table, :store, :observations

  def initialize(capture, run_root, binary, label, setting, table, type,
                 insert_columns, insert_rows, output_projection)
    @capture = capture
    @run_root = run_root
    @binary = binary
    @label = label
    @setting = setting
    @table = table
    @type = type
    @insert_columns = insert_columns
    @insert_rows = insert_rows
    @output_projection = output_projection
    @store = File.join(run_root, "stores", label)
    FileUtils.mkdir_p(store, mode: 0o700)
    @schema = "(pk UInt64, nested #{@type})"
    @observations = []
  end

  def query(name, sql_body)
    sql = "SET flatten_nested = #{setting};\n#{sql_body.rstrip}\n"
    argv = [@binary, "local", "--path", store, "--multiquery", "--max_threads=1", "--query", sql]
    @capture.run("#{label}-#{name}", argv, sql)
  end

  def run
    ddl_settings = "index_granularity = 2, index_granularity_bytes = 10485760, " \
      "enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, " \
      "min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 0.9375, " \
      "compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, " \
      "max_compress_block_size = 4096, default_compression_codec = 'LZ4'"
    query("create", "CREATE TABLE default.#{table} #{@schema} ENGINE = MergeTree ORDER BY pk SETTINGS #{ddl_settings};")

    keys = [7, 13, 22, 31, 50]
    values = @insert_rows.each_with_index.map do |row, index|
      "(#{keys.fetch(index)}, #{row})"
    end.join(",\n")
    query("insert", "INSERT INTO default.#{table} (pk, #{@insert_columns}) VALUES\n#{values};")
    query("describe", "DESCRIBE TABLE default.#{table} FORMAT TSVRaw;")
    query("system-columns", "SELECT position, name, type FROM system.columns WHERE database = 'default' AND table = '#{table}' ORDER BY position FORMAT TSVRaw;")
    parts_record, parts_stdout, = query("system-parts", "SELECT path, part_type, rows, marks FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw;")

    part_path = nil
    if parts_record.dig("status", "success") == true
      line = parts_stdout.lines.find { |entry| !entry.strip.empty? }
      unless line.nil?
        fields = line.rstrip.split("\t", -1)
        if fields.length == 4
          candidate = File.expand_path(fields[0], store)
          store_root = File.expand_path(store)
          if candidate.start_with?(store_root + File::SEPARATOR) && Dir.exist?(candidate)
            part_path = candidate
          end
        end
      end
    end

    profile_record = {
      "label" => label,
      "setting_flatten_nested" => setting,
      "table" => table,
      "declared_type" => @type,
      "part_path" => part_path
    }

    unless part_path.nil?
      names = ["columns.txt", "columns_substreams.txt", "serialization.json", "default_compression_codec.txt", "metadata_version.txt"]
      metadata = {}
      names.each do |name|
        path = File.join(part_path, name)
        next unless File.file?(path) && !File.symlink?(path)
        contents = File.binread(path)
        metadata[name] = {
          "path" => path,
          "contents" => contents.dup.force_encoding(Encoding::UTF_8),
          "size" => contents.bytesize,
          "sha256" => Digest::SHA256.hexdigest(contents)
        }
      end

      roster = Dir.children(part_path).sort.map do |name|
        path = File.join(part_path, name)
        stat = File.lstat(path)
        kind = if stat.symlink?
                 "symlink"
               elsif stat.directory?
                 "directory"
               elsif stat.file?
                 "file"
               else
                 "other"
               end
        row = { "name" => name, "kind" => kind, "size" => stat.size }
        row["sha256"] = Digest::SHA256.hexdigest(File.binread(path)) if kind == "file"
        row
      end
      profile_record["part_metadata"] = metadata
      profile_record["part_roster"] = roster
    end

    selections = {
      "full" => "",
      "middle" => " WHERE pk IN (22, 31)",
      "empty_nested_row" => " WHERE pk = 13",
      "no_rows" => " WHERE pk = 999"
    }
    selections.each do |selection_name, predicate|
      ["RowBinaryWithNamesAndTypes", "RowBinary"].each do |format_name|
        query_name = "select-#{selection_name}-#{format_name.downcase}"
        query(query_name, "SELECT pk, #{@output_projection} FROM default.#{table}#{predicate} ORDER BY pk FORMAT #{format_name};")
      end
    end
    @observations << profile_record
  end
end

options = parse_options
binary = File.expand_path(options[:clickhouse])
raise "refusing symlinked ClickHouse binary" if File.symlink?(binary)
raise "pinned ClickHouse binary missing or not executable" unless File.file?(binary) && File.executable?(binary)
binary_before = Digest::SHA256.file(binary).hexdigest
raise "ClickHouse binary SHA-256 differs before probe: #{binary_before}" unless binary_before == EXPECTED_BINARY_SHA256

run_root = Dir.mktmpdir("nested-source-law-", options[:workdir])
capture = W171SourceCapture.new(run_root)
version_record, version_stdout, = capture.run("runtime-version", [binary, "local", "--version"])
version = version_stdout.strip

array_tuple_rows = [
  "[(11, 'r0-A', NULL), (103, 'r0-B', -17)]",
  "[]",
  "[(211, 'mid-x', 31)]",
  "[(307, 'r3-A', 0), (310, 'r3-B', 32), (311, 'r3-C', NULL)]",
  "[(409, 'last-A', -41), (419, 'last-B', 41)]"
]
flattened_rows = [
  "[11, 103], ['r0-A', 'r0-B'], [NULL, -17]",
  "[], [], []",
  "[211], ['mid-x'], [31]",
  "[307, 310, 311], ['r3-A', 'r3-B', 'r3-C'], [0, 32, NULL]",
  "[409, 419], ['last-A', 'last-B'], [-41, 41]"
]

profiles = [
  W171SourceProfile.new(capture, run_root, binary, "nested-flat1", 1, "w171_nested_flat1",
    NESTED_TYPE, "nested.a, nested.b, nested.c", flattened_rows, "nested.a, nested.b, nested.c"),
  W171SourceProfile.new(capture, run_root, binary, "nested-flat0", 0, "w171_nested_flat0",
    NESTED_TYPE, "nested", array_tuple_rows, "nested"),
  W171SourceProfile.new(capture, run_root, binary, "array-tuple-flat0", 0, "w171_array_tuple",
    ARRAY_TUPLE_TYPE, "nested", array_tuple_rows, "nested")
]
profiles.each(&:run)

binary_after = Digest::SHA256.file(binary).hexdigest
manifest = {
  "probe" => "W171 stock Nested source-law inventory",
  "interpretation" => "stock observations only; no library support or physical shape is asserted",
  "created_at_utc" => Time.now.utc.iso8601(6),
  "clickhouse_binary" => binary,
  "clickhouse_binary_sha256_before" => binary_before,
  "clickhouse_binary_sha256_after" => binary_after,
  "expected_clickhouse_version" => EXPECTED_VERSION,
  "observed_clickhouse_version" => version,
  "version_command_status" => version_record.fetch("status"),
  "source_root" => options[:source_root],
  "source_label" => options[:source_label],
  "run_root" => run_root,
  "fixture_keys" => [7, 13, 22, 31, 50],
  "fixture_child_counts" => [2, 0, 1, 3, 2],
  "expected_mark_row_counts" => [2, 2, 1],
  "commands" => capture.records,
  "profiles" => profiles.flat_map(&:observations)
}
exclusive_write(File.join(run_root, "manifest.json"), JSON.pretty_generate(manifest) + "\n")

failed = capture.records.count { |record| record.dig("status", "success") != true }
puts "W171 stock source observations retained at #{run_root}"
puts "commands=#{capture.records.length} command_failures=#{failed} binary_sha256=#{binary_after}"
raise "ClickHouse binary SHA-256 changed during probe: #{binary_after}" unless binary_after == EXPECTED_BINARY_SHA256
raise "ClickHouse version differs: #{version.inspect}" unless version == EXPECTED_VERSION
raise "stock source command(s) failed; see retained manifest" unless failed.zero?
raise "a stock profile did not produce its expected part" unless manifest.fetch("profiles").all? { |profile| profile["part_path"] }
