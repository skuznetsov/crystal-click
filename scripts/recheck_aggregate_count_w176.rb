# Root-only serial stock oracle. The caller owns the resource guard and must
# supply an existing, empty temporary evidence directory. No compilation,
# network access, existing part overwrite, or source-build claim is made here.
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'

class CountPartOracle
  BINARY = '/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped'
  SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'
  VERSION = "26.10.1.1201\td9bcb5ab007f0f6299f7f973f2642245bab3d028\n".b
  TYPES = {'none' => 'AggregateFunction(count)', 'uint64' => 'AggregateFunction(count, UInt64)',
           'nullable' => 'AggregateFunction(count, Nullable(UInt64))'}.freeze
  KEYS = [7, 13, 22, 31, 50].freeze
  # Independent literal oracle: never call the library's VarUInt encoder.
  STATES = %w[00 7f 8001 808001 ffffffffffffffffff01].map { |hex| [hex].pack('H*') }.freeze
  COUNTS = [0, 127, 128, 16384, 18446744073709551615].freeze

  def initialize(root, library_root = nil)
    @root = File.realpath(root)
    raise 'unsafe evidence directory' unless @root.start_with?('/private/tmp/') &&
      File.directory?(@root) && !File.symlink?(root) && Dir.children(@root).empty?
    @library = library_root && File.realpath(library_root)
    raise 'unsafe library directory' if @library && !@library.start_with?('/private/tmp/')
    @records = []
  end

  def rowbinary(rows, states = STATES)
    rows.map { |i| [KEYS.fetch(i)].pack('Q<') + states.fetch(i) }.join.b
  end

  def query(label, store, sql, input = ''.b)
    args = [BINARY, 'local', '--path', store, '--max_threads=1', '--max_insert_threads=1',
            '--max_memory_usage=1073741824', '--query', sql]
    out, err, status = Open3.capture3({'TZ' => 'UTC'}, *args, stdin_data: input)
    out = out.b
    record = {label: label, argv: args, exit: status.exitstatus, signal: status.termsig,
              input_sha256: Digest::SHA256.hexdigest(input), stdout_sha256: Digest::SHA256.hexdigest(out),
              stderr_sha256: Digest::SHA256.hexdigest(err.b)}
    write(label + '.stdout', out)
    write(label + '.stderr', err.b)
    write(label + '.json', JSON.pretty_generate(record))
    @records << record
    raise "#{label}: exit=#{status.exitstatus} signal=#{status.termsig}: #{err}" unless status.success? && status.termsig.nil?
    out
  end

  def write(name, bytes)
    File.open(File.join(@root, name), 'wx', 0o600) { |f| f.write(bytes) }
  end

  def ddl(type)
    "CREATE TABLE t (pk UInt64, c #{type}) ENGINE=MergeTree ORDER BY pk SETTINGS " \
      'index_granularity=2,index_granularity_bytes=10485760,enable_mixed_granularity_parts=1,' \
      'min_rows_for_wide_part=0,min_bytes_for_wide_part=0,ratio_of_defaults_for_sparse_serialization=0.9375,' \
      'compress_marks=0,compress_primary_key=0,min_compress_block_size=0,max_compress_block_size=4096,' \
      "default_compression_codec='LZ4'"
  end

  def check_values(prefix, store, type, states = STATES, counts = COUNTS)
    raise 'CHECK output differs' unless query(prefix + '-check', store, 'CHECK TABLE t FORMAT TSV') == "all_1_1_0\t1\t\n".b
    expected_schema = "pk\tUInt64\nc\t#{type}\n".b
    schema = query(prefix + '-schema', store, "SELECT name,type FROM system.columns WHERE database='default' AND table='t' ORDER BY position FORMAT TSVRaw")
    raise 'nominal schema differs' unless schema == expected_schema
    info = query(prefix + '-part-info', store, "SELECT name,part_type,rows,marks FROM system.parts WHERE database='default' AND table='t' AND active FORMAT TSV")
    raise 'part axes differ' unless info == "all_1_1_0\tWide\t5\t4\n".b
    {'full' => ['', [0, 1, 2, 3, 4]], 'middle' => [' WHERE pk>=22 AND pk<=31', [2, 3]],
     'empty' => [' WHERE pk=0', []]}.each do |window, (predicate, rows)|
      out = query(prefix + '-' + window, store, "SELECT pk,c FROM t#{predicate} ORDER BY pk FORMAT RowBinary")
      raise "#{prefix} #{window}: literal RowBinary mismatch" unless out == rowbinary(rows, states)
    end
    final = query(prefix + '-final', store, 'SELECT finalizeAggregation(c) FROM t ORDER BY pk FORMAT TSV')
    raise 'finalized counts differ' unless final == (counts.join("\n") + "\n").b
  end

  def copy_part(source, destination)
    raise 'destination exists' if File.exist?(destination) || File.symlink?(destination)
    Find.find(source) do |path|
      raise 'symlink or special part entry' if File.symlink?(path) || !(File.file?(path) || File.directory?(path))
    end
    FileUtils.cp_r(source, destination)
  end

  def attach(label, type, source, states = STATES, counts = COUNTS)
    raise 'unsafe library part' if File.symlink?(source) || !File.directory?(source) ||
      !File.realpath(source).start_with?(@library + '/')
    store = File.join(@root, 'library-store-' + label)
    Dir.mkdir(store, 0o700)
    query(label + '-create', store, ddl(type))
    path = query(label + '-table-path', store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='t' FORMAT TSVRaw").strip
    raise 'unsafe table path' unless File.realpath(path).start_with?(File.realpath(store) + '/')
    detached = File.join(path, 'detached')
    Dir.mkdir(detached, 0o700) unless File.directory?(detached)
    raise 'unsafe detached directory' if File.symlink?(detached) || !Dir.children(detached).empty?
    copy_part(source, File.join(detached, 'all_1_1_0'))
    query(label + '-attach', store, "ALTER TABLE t ATTACH PART 'all_1_1_0'")
    check_values(label, store, type, states, counts)
  end

  def run
    raise 'runtime hash differs' unless Digest::SHA256.file(BINARY).hexdigest == SHA256
    pin_store = File.join(@root, 'pin-store')
    Dir.mkdir(pin_store, 0o700)
    raise 'version/build differs' unless query('pin', pin_store, "SELECT version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSV") == VERSION
    TYPES.each do |label, type|
      store = File.join(@root, 'stock-' + label)
      Dir.mkdir(store, 0o700)
      query(label + '-create', store, ddl(type))
      query(label + '-insert', store, 'INSERT INTO t FORMAT RowBinary', rowbinary((0...5).to_a))
      check_values(label, store, type)
      info = query(label + '-part', store, "SELECT path,part_type,rows,marks FROM system.parts WHERE database='default' AND table='t' AND active FORMAT TSV")
      raise 'part path query is not exactly one four-field row' unless info.lines.length == 1 && info.strip.split("\t").length == 4
      path, kind, rows, marks = info.strip.split("\t")
      raise 'part profile differs' unless kind == 'Wide' && rows == '5' && marks == '4'
      raise 'unsafe stock part path' unless File.realpath(path).start_with?(File.realpath(store) + '/')
      copy_part(path, File.join(@root, 'part-' + label))
      attach('library-' + label, type, File.join(@library, label, 'all_1_1_0')) if @library
    end
    if @library
      mutant_states = STATES.dup
      mutant_states[2] = ['8101'].pack('H*')
      mutant_counts = COUNTS.dup
      mutant_counts[2] = 129
      attach('value-mutant', TYPES.fetch('none'), File.join(@library, 'value-mutant', 'all_1_1_0'), mutant_states, mutant_counts)
      raise 'invalid value-mutant oracle' if rowbinary((0...5).to_a, mutant_states) == rowbinary((0...5).to_a)
      puts 'CHECK-valid value mutant differs from the unchanged baseline literal oracle (128 -> 129)'
    end
    raise 'runtime changed' unless Digest::SHA256.file(BINARY).hexdigest == SHA256
    write('summary.json', JSON.pretty_generate({runtime_sha256: SHA256, records: @records}))
    puts "W176 Count whole-part oracle: #{@records.length} successful stock processes"
  end
end

abort 'usage: ruby recheck_aggregate_count_w176.rb EMPTY_TMP_EVIDENCE_DIR [LIBRARY_PART_ROOT]' unless (1..2).cover?(ARGV.length)
CountPartOracle.new(*ARGV).run
