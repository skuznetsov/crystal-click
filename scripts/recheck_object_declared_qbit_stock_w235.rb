#!/usr/bin/env ruby
# Stock-only CREATE discriminator for statically declared QBit paths in
# JSON/Object, plus one ordinary-JSON persistence control. Never widens library
# admission or treats type-constructor acceptance as persistence evidence.

require 'digest'
require 'json'
require 'optparse'
require_relative 'recheck_object_qbit_recursive_stock_w234'

module RecheckObjectDeclaredQBitStockW235
  extend self

  Q = RecheckObjectQBitRecursiveStockW234
  R = Q::R
  SOURCE_ROOT = Q::SOURCE_ROOT.freeze
  SOURCE_REVISION = Q::SOURCE_REVISION.freeze
  CLICKHOUSE_BIN = Q::CLICKHOUSE_BIN
  CLICKHOUSE_SHA256 = Q::CLICKHOUSE_SHA256
  CLICKHOUSE_VERSION = Q::CLICKHOUSE_VERSION.freeze
  CLICKHOUSE_BUILD = Q::CLICKHOUSE_BUILD.freeze
  ROOT_PREFIX = 'crystal-click-w235-stock.'.freeze
  PROCESS_TIMEOUT_SECONDS = 90
  MAX_PROCESS_COUNT = 40
  CONTROL_TABLE = 'w235_json_positive_control'.freeze
  CONTROL_ID = 'positive_control'.freeze
  CONTROL_ROWS = [
    { 'q' => 7, 'xs' => [1, 2] },
    { 'xs' => [] },
    { 'q' => 255, 'xs' => [8] },
    { 'q' => 0, 'xs' => [3, 4, 5] },
    {},
    { 'q' => 42, 'xs' => [9, 0] },
  ].freeze
  ROW_KEYS = [1, 2, 3, 4, 5, 6].freeze
  MARK_ROWS = [2, 2, 2].freeze
  PART_MARKS = 4

  # Each candidate receives a separate stock store and one CREATE child. This
  # makes a refusal of one schema unable to mask evidence about another.
  QBIT_PROBES = [
    ['direct_int8', 'QBit(Int8, 9)', 'QBit(Int8, 9)'],
    ['direct_bfloat16', 'QBit(BFloat16, 9)', 'QBit(BFloat16, 9)'],
    ['direct_float32', 'QBit(Float32, 9)', 'QBit(Float32, 9)'],
    ['direct_float64', 'QBit(Float64, 9)', 'QBit(Float64, 9)'],
    ['custom_stride', 'QBit(Int8, 16, 8)', 'QBit(Int8, 16, 8)'],
    ['array', 'Array(QBit(Int8, 9))', 'QBit(Int8, 9)'],
    ['tuple', 'Tuple(q QBit(Int8, 9), n UInt8)', 'QBit(Int8, 9)'],
    ['map', 'Map(String, QBit(Int8, 9))', 'QBit(Int8, 9)'],
    ['nested', 'Nested(q QBit(Int8, 9), tag UInt8)', 'QBit(Int8, 9)'],
    ['nullable', 'Nullable(QBit(Int8, 9))', 'QBit(Int8, 9)'],
    ['variant_one_arm', 'Variant(QBit(Int8, 9))', 'QBit(Int8, 9)'],
    ['variant_qbit_string', 'Variant(QBit(Int8, 9), String)', 'QBit(Int8, 9)'],
    ['array_variant_qbit_string', 'Array(Variant(QBit(Int8, 9), String))', 'QBit(Int8, 9)'],
  ].map do |id, type, leaf|
    { 'id' => id.freeze, 'table' => "w235_json_qbit_#{id}".freeze,
      'type' => type.freeze, 'leaf' => leaf.freeze }.freeze
  end.freeze

  STOCK_SETTINGS = Q::STOCK_SETTINGS

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def validate_root(path)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full && Dir.children(full).empty?,
      'capture root must be a fresh, empty, canonical directory')
    require_true(File.dirname(full) == File.realpath('/private/tmp') && File.basename(full).start_with?(ROOT_PREFIX),
      "capture root must be a direct /private/tmp child named #{ROOT_PREFIX}*")
    full
  end

  def validate_binary(path)
    full = Q.validate_binary(path)
    require_true(full == CLICKHOUSE_BIN && Digest::SHA256.file(full).hexdigest == CLICKHOUSE_SHA256,
      'runtime differs from the W235 fixed path/SHA pin')
    full
  end

  def inventory_tree(root, allowed_stores: {})
    Q.inventory_tree(root, allowed_stores: allowed_stores)
  end

  # Refusal is evidence only for the exact synchronous native Code 43 emitted
  # by the JSON serializer for the expected QBit leaf. In particular, partial
  # text from a timeout, signal, spawn error, or a different exit is not a pass.
  def expected_qbit_refusal?(record, leaf)
    return false unless record.fetch('classification') == 'process_nonzero_or_signaled_exit'
    return false unless record.fetch('exitstatus') == 43
    return false unless record.fetch('signaled') == false && record.fetch('termsig').nil?
    return false unless record.fetch('timed_out') == false && record.fetch('spawn_error').nil?
    return false unless record.fetch('stdout').empty?

    expected = "Code: 43. DB::Exception: JSON serialization doesn't support the return type schema: #{leaf}. (ILLEGAL_TYPE_OF_ARGUMENT)".b
    stderr = record.fetch('stderr').b
    stderr == expected || stderr == expected + "\n".b
  end

  def varuint(value)
    require_true(value.is_a?(Integer) && value >= 0 && value <= 18_446_744_073_709_551_615,
      "invalid VarUInt literal: #{value.inspect}")
    bytes = []
    while value >= 0x80
      bytes << ((value & 0x7f) | 0x80)
      value >>= 7
    end
    (bytes << value).pack('C*').b
  end

  def uint64(value)
    require_true(value.is_a?(Integer) && value >= 0 && value <= 18_446_744_073_709_551_615,
      "invalid UInt64 literal: #{value.inspect}")
    Array.new(8) { |index| (value >> (index * 8)) & 0xff }.pack('C*').b
  end

  def string_bytes(value)
    bytes = value.encode(Encoding::UTF_8).b
    varuint(bytes.bytesize) + bytes
  end

  def json_type(type)
    "JSON(q #{type})"
  end

  def create_sql(table, typed_path_type)
    "CREATE TABLE default.#{table} (id UInt64, j #{json_type(typed_path_type)}) " \
      "ENGINE=MergeTree ORDER BY id SETTINGS #{STOCK_SETTINGS.join(', ')}"
  end

  def create_control_sql
    "CREATE TABLE default.#{CONTROL_TABLE} (id UInt64, j JSON(q UInt8, xs Array(UInt8))) " \
      "ENGINE=MergeTree ORDER BY id SETTINGS #{STOCK_SETTINGS.join(', ')}"
  end

  def schema_sql(table)
    "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
  end

  def check_sql(table)
    "CHECK TABLE default.#{table} FORMAT TSVRaw"
  end

  def part_sql(table)
    "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts " \
      "WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw"
  end

  def control_rowbinary_input
    CONTROL_ROWS.each_with_index.map do |row, index|
      entries = row.sort_by { |path, _value| path }
      object = varuint(entries.length)
      entries.each do |path, value|
        object << string_bytes(path)
        case path
        when 'q'
          require_true(value.is_a?(Integer) && value.between?(0, 255), 'control q literal is not UInt8')
          object << [value].pack('C').b
        when 'xs'
          require_true(value.is_a?(Array) && value.all? { |item| item.is_a?(Integer) && item.between?(0, 255) },
            'control xs literal is not Array(UInt8)')
          object << varuint(value.length) << value.pack('C*').b
        else
          fail!("unlisted positive-control typed path: #{path.inspect}")
        end
      end
      uint64(ROW_KEYS.fetch(index)) + object
    end.join.b
  end

  def control_expected_rows
    CONTROL_ROWS.each_with_index.map do |row, index|
      values = row.fetch('xs', [])
      uint64(ROW_KEYS.fetch(index)) + [row.fetch('q', 0)].pack('C').b + varuint(values.length) + values.pack('C*').b
    end
  end

  def control_window_sql(window)
    predicate = { 'full' => '', 'middle' => ' WHERE id BETWEEN 3 AND 4', 'zero' => ' WHERE id=0' }.fetch(window)
    "SELECT id, j.q, j.xs FROM default.#{CONTROL_TABLE}#{predicate} ORDER BY id " \
      'SETTINGS output_format_binary_write_json_as_string=0 FORMAT RowBinary'
  end

  class Probe
    def initialize(options)
      @binary = RecheckObjectDeclaredQBitStockW235.validate_binary(options.fetch(:clickhouse))
      @root = RecheckObjectDeclaredQBitStockW235.validate_root(options.fetch(:capture_root))
      @recorder = R::Recorder.new(@root, @binary)
      @stores = {}
      @probe_records = []
      @part_records = []
    end

    def run
      R.make_dir(File.join(@root, 'invocations'))
      R.make_dir(File.join(@root, 'literal_rowbinary'))
      R.make_dir(File.join(@root, 'stores'))
      profiles = QBIT_PROBES.map { |probe| [probe.fetch('id'), probe.fetch('table')] } + [[CONTROL_ID, CONTROL_TABLE]]
      profiles.each do |id, _table|
        store = File.join(@root, 'stores', id)
        R.make_dir(store)
        @stores[id] = store
      end

      pin_runtime(QBIT_PROBES.first.fetch('id'))
      QBIT_PROBES.each { |probe| run_qbit_create(probe) }
      run_control
      RecheckObjectDeclaredQBitStockW235.require_true(@recorder.records.length <= MAX_PROCESS_COUNT,
        'fixed W235 child-process cap exceeded')
      write_part_inventory
      write_witness
      write_capture_inventory(profiles)
      all_qbit_refusals = @probe_records.all? { |item| item.fetch('classification') == 'code43_qbit_schema_refusal' }
      puts JSON.generate(
        'status' => all_qbit_refusals ? 'all_qbit_create_refusals_observed' : 'stock_discriminator_inconclusive',
        'runtime_version' => CLICKHOUSE_VERSION, 'runtime_build' => CLICKHOUSE_BUILD,
        'invocations' => @recorder.records.length,
        'capture_root' => @root, 'qbit_create_outcomes' => @probe_records.map { |item| [item.fetch('id'), item.fetch('classification')] },
        'positive_control' => 'persisted_and_literal_rowbinary_matched',
      )
      all_qbit_refusals
    rescue StandardError => error
      warn "W235 stock discriminator stopped with raw captures preserved: #{error.class}: #{error.message}"
      false
    end

    private

    def invoke(label, store_id, sql, input: nil)
      RecheckObjectDeclaredQBitStockW235.require_true(@recorder.records.length < MAX_PROCESS_COUNT,
        'fixed W235 child-process cap exceeded')
      store = @stores.fetch(store_id)
      @recorder.run(label, store, sql, input: input, timeout: PROCESS_TIMEOUT_SECONDS,
        argv: Q::Q.clickhouse_argv(@binary, store, sql))
    end

    def process_success?(record)
      record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
        !record.fetch('signaled') && !record.fetch('timed_out') && record.fetch('spawn_error').nil?
    end

    def invoke_success!(label, store_id, sql, input: nil)
      record = invoke(label, store_id, sql, input: input)
      RecheckObjectDeclaredQBitStockW235.require_true(process_success?(record),
        "ClickHouse child #{label} did not exit successfully; raw capture at #{record.fetch('path')}")
      record
    end

    def pin_runtime(store_id)
      version = invoke_success!('runtime-version', store_id, 'SELECT version() FORMAT TSVRaw')
      RecheckObjectDeclaredQBitStockW235.require_true(version.fetch('stdout') == "#{CLICKHOUSE_VERSION}\n",
        'runtime version differs from the W235 pin')
      build = invoke_success!('runtime-build', store_id,
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw")
      RecheckObjectDeclaredQBitStockW235.require_true(build.fetch('stdout') == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}\n",
        'runtime build hash differs from the W235 pin')
      @runtime_pin = {
        'path' => @binary, 'sha256' => CLICKHOUSE_SHA256, 'version' => CLICKHOUSE_VERSION,
        'build_hash' => CLICKHOUSE_BUILD,
        'source_revision_is_separately_pinned_not_asserted_as_runtime_lineage' => true,
        'version_capture' => File.basename(version.fetch('path')),
        'build_capture' => File.basename(build.fetch('path')),
      }
    end

    def run_qbit_create(probe)
      result = invoke("#{probe.fetch('id')}-create", probe.fetch('id'),
        RecheckObjectDeclaredQBitStockW235.create_sql(probe.fetch('table'), probe.fetch('type')))
      expected_refusal = RecheckObjectDeclaredQBitStockW235.expected_qbit_refusal?(result, probe.fetch('leaf'))
      classification = if expected_refusal
                         'code43_qbit_schema_refusal'
                       elsif process_success?(result)
                         'unexpected_create_success_only'
                       else
                         'different_failure_inconclusive'
                       end
      record = {
        'id' => probe.fetch('id'), 'table' => probe.fetch('table'), 'declared_type' => probe.fetch('type'),
        'source_expected_nominal_type_name' => probe.fetch('type'),
        'expected_qbit_leaf_error_name' => probe.fetch('leaf'), 'classification' => classification,
        'create_exitstatus' => result.fetch('exitstatus'), 'timed_out' => result.fetch('timed_out'),
        'spawn_error' => result.fetch('spawn_error'), 'create_capture' => File.basename(result.fetch('path')),
        'stderr_sha256' => Digest::SHA256.hexdigest(result.fetch('stderr')),
        'diagnostic_lines' => result.fetch('stderr').force_encoding(Encoding::UTF_8).scrub.lines.select do |line|
          line.include?('Code: 43') || line.include?(probe.fetch('leaf'))
        end.map(&:chomp),
      }
      if process_success?(result)
        # A constructor success is not persistence evidence. Capture the stock
        # nominal schema for diagnosis but deliberately do not insert or claim a part.
        schema = invoke("#{probe.fetch('id')}-unexpected-schema", probe.fetch('id'),
          RecheckObjectDeclaredQBitStockW235.schema_sql(probe.fetch('table')))
        record['schema_capture'] = File.basename(schema.fetch('path'))
        record['schema_exitstatus'] = schema.fetch('exitstatus')
        record['schema_stdout'] = schema.fetch('stdout').force_encoding(Encoding::UTF_8).scrub
      end
      @probe_records << record
    end

    def run_control
      input = RecheckObjectDeclaredQBitStockW235.control_rowbinary_input
      literal_dir = File.join(@root, 'literal_rowbinary')
      input_name = 'positive-control-input.rowbin'
      R.write_new(File.join(literal_dir, input_name), input)

      create = invoke_success!('positive-control-create', CONTROL_ID,
        RecheckObjectDeclaredQBitStockW235.create_control_sql)
      insert = invoke_success!('positive-control-insert', CONTROL_ID,
        "INSERT INTO default.#{CONTROL_TABLE} SETTINGS input_format_binary_read_json_as_string=0 FORMAT RowBinary", input: input)
      check = invoke_success!('positive-control-check', CONTROL_ID,
        RecheckObjectDeclaredQBitStockW235.check_sql(CONTROL_TABLE))
      RecheckObjectDeclaredQBitStockW235.require_true(check.fetch('stdout') == "all_1_1_0\t1\t\n",
        "positive-control CHECK result differs; raw capture at #{check.fetch('path')}")
      schema = invoke_success!('positive-control-schema', CONTROL_ID,
        RecheckObjectDeclaredQBitStockW235.schema_sql(CONTROL_TABLE))
      expected_schema = "id\tUInt64\nj\tJSON(q UInt8, xs Array(UInt8))\n"
      RecheckObjectDeclaredQBitStockW235.require_true(schema.fetch('stdout') == expected_schema,
        "positive-control exact schema differs; raw capture at #{schema.fetch('path')}")

      part = invoke_success!('positive-control-part', CONTROL_ID,
        RecheckObjectDeclaredQBitStockW235.part_sql(CONTROL_TABLE))
      fields = part.fetch('stdout').force_encoding(Encoding::UTF_8).lines.map { |line| line.chomp.split("\t", -1) }
      RecheckObjectDeclaredQBitStockW235.require_true(fields.length == 1 && fields.first.length == 5 &&
        fields.first[0, 4] == ['all_1_1_0', '6', PART_MARKS.to_s, 'Wide'],
        "expected one six-row/four-mark Wide positive-control part; raw capture at #{part.fetch('path')}")
      part_path = File.expand_path(fields.first.fetch(4))
      store = @stores.fetch(CONTROL_ID)
      RecheckObjectDeclaredQBitStockW235.require_true(part_path.start_with?(store + File::SEPARATOR) &&
        File.directory?(part_path) && !File.symlink?(part_path) && File.realpath(part_path) == part_path,
        'positive-control part escaped its isolated store or is not canonical')

      literals = RecheckObjectDeclaredQBitStockW235.control_expected_rows
      literal_windows = { 'full' => literals.join.b, 'middle' => literals[2, 2].join.b, 'zero' => ''.b }
      windows = {}
      %w[full middle zero].each do |window|
        expected = literal_windows.fetch(window)
        expected_file = File.join(literal_dir, "positive-control-#{window}-expected.rowbin")
        R.write_new(expected_file, expected)
        output = invoke_success!("positive-control-rowbinary-#{window}", CONTROL_ID,
          RecheckObjectDeclaredQBitStockW235.control_window_sql(window))
        RecheckObjectDeclaredQBitStockW235.require_true(output.fetch('stdout') == expected,
          "positive-control #{window} RowBinary differs from independent literal; raw capture at #{output.fetch('path')}")
        windows[window] = {
          'bytes' => expected.bytesize, 'sha256' => Digest::SHA256.hexdigest(expected),
          'matches_independent_literal' => true, 'expected_literal' => File.basename(expected_file),
          'capture_invocation' => File.basename(output.fetch('path')),
        }
      end

      inventory = RecheckObjectDeclaredQBitStockW235.inventory_tree(part_path)
      @part_records << { 'id' => CONTROL_ID, 'part_path' => part_path, 'files' => inventory.fetch('files') }
      @control_record = {
        'table' => CONTROL_TABLE, 'declared_type' => 'JSON(q UInt8, xs Array(UInt8))',
        'rows' => ROW_KEYS, 'rows_per_mark' => MARK_ROWS, 'part_type' => 'Wide', 'part_marks' => PART_MARKS,
        'input_literal' => input_name, 'schema_capture' => File.basename(schema.fetch('path')),
        'check_capture' => File.basename(check.fetch('path')), 'check_stdout' => check.fetch('stdout'),
        'part_capture' => File.basename(part.fetch('path')), 'part_inventory_file_count' => inventory.fetch('files').length,
        'create_capture' => File.basename(create.fetch('path')), 'insert_capture' => File.basename(insert.fetch('path')),
        'rowbinary_windows' => windows,
      }
    end

    def write_part_inventory
      R.write_new(File.join(@root, 'part_inventories.json'),
        JSON.pretty_generate({ 'parts' => @part_records }) + "\n")
    end

    def write_witness
      witness = {
        'format' => 'object_declared_qbit_stock_w235_v2',
        'source_reference' => "#{SOURCE_ROOT}@#{SOURCE_REVISION}", 'runtime' => @runtime_pin,
        'qbit_create_probes' => @probe_records, 'positive_control' => @control_record,
        'settings' => STOCK_SETTINGS,
        'scope' => 'isolated stock CREATE attempts for direct QBit(Int8/BFloat16/Float32/Float64), custom stride, Array/Tuple/Map/Nested/Nullable and Variant forms; one ordinary JSON control persisted as a six-row/four-mark Wide part and checked against independent literal RowBinary output',
        'limitations' => [
          'A QBit CREATE refusal is not a paired Crystal reader/writer result and does not test any library path.',
          'The ordinary JSON positive control validates the stock harness and typed-path RowBinary grammar only.',
          'No QBit-containing declared path is admitted by this probe, even if a CREATE unexpectedly succeeds.',
          'Nested canonical naming is recorded verbatim if CREATE succeeds; source retains Nested(...) as its custom type name over Array(Tuple(...)), and this probe does not normalize that name or qualify a paired grammar.',
        ],
      }
      R.write_new(File.join(@root, 'witnesses.json'), JSON.pretty_generate(witness) + "\n")
    end

    def write_capture_inventory(profiles)
      allowed_stores = @stores.each_with_object({}) do |(id, path), result|
        result[File.realpath(path)] = profiles.find { |profile_id, _table| profile_id == id }.fetch(1)
      end
      inventory = RecheckObjectDeclaredQBitStockW235.inventory_tree(@root, allowed_stores: allowed_stores)
      R.write_new(File.join(@root, 'capture_inventory.json'), JSON.pretty_generate(inventory) + "\n")
    end
  end

  def main(argv)
    options = { clickhouse: CLICKHOUSE_BIN }
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/recheck_object_declared_qbit_stock_w235.rb --capture-root EMPTY_DIR [--clickhouse PINNED_BIN]'
      opts.on('--capture-root PATH') { |value| options[:capture_root] = value }
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && options.key?(:capture_root), parser.to_s)
    Probe.new(options).run
  rescue StandardError => error
    warn "W235 stock probe setup failed: #{error.class}: #{error.message}"
    false
  end
end

exit(RecheckObjectDeclaredQBitStockW235.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
