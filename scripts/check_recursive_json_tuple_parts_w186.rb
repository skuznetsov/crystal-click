#!/usr/bin/env ruby
# W186 stock/library discriminator for two nominally equal JSON sites inside a
# named Tuple. The guarded W185 runner supplies the pinned binary, bounded
# executor, path checks, part inspector, and stderr classification.

require 'digest'
require 'json'
require 'optparse'
require_relative 'check_array_json_parts_w185'

module CheckRecursiveJSONTuplePartsW186
  extend self

  Binary = CheckArrayJSONPartsW185::BINARY
  BinarySHA256 = CheckArrayJSONPartsW185::BINARY_SHA256
  Version = CheckArrayJSONPartsW185::VERSION
  Build = CheckArrayJSONPartsW185::BUILD
  Memory = CheckArrayJSONPartsW185::MEMORY
  Timeout = CheckArrayJSONPartsW185::TIMEOUT
  Grace = CheckArrayJSONPartsW185::GRACE

  JsonType = 'JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)'.freeze
  TupleType = "Tuple(l #{JsonType}, r #{JsonType}, n UInt64)".freeze
  Table = 'tuple_source'.freeze
  LibraryTable = 'library_target'.freeze
  Settings = CheckArrayJSONPartsW185::SETTINGS

  # Independent source literals: each JSON site has one frequent, distinct
  # Dynamic path and one deliberately rarer shared-map path.
  Rows = (1..8).map do |pk|
    left = {t: pk, a_left: (pk + 10), z_shared: (pk == 1 ? 'left-shared' : nil)}
    right = {t: (pk + 20), b_right: "right-#{pk}", z_shared: (pk == 1 ? 'right-shared' : nil)}
    {pk: pk, n: (pk * 100), left: left, right: right}
  end.freeze

  class Probe
    def initialize(binary, crystal_probe, evidence_root, baseline: false)
      @base = CheckArrayJSONPartsW185::Probe.new(binary, crystal_probe, evidence_root)
      @root = File.expand_path(evidence_root)
      @binary = File.expand_path(binary)
      @crystal_probe = File.expand_path(crystal_probe)
      @baseline = baseline
    end

    def run
      %w[invocations stores parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)

      native = @base.send(:run_clickhouse, 'tuple_json_source', initial_sql)
      @base.send(:assert_pin!, native)
      @base.send(:assert_native_invocation!, native)
      observed = @base.send(:parse_native, native[:stdout])
      part = assert_stock_fixture!(observed)
      inventory = @base.send(:inspect_part, 'stock_tuple_json', part[:path], part)
      assert_site_rosters!(inventory)

      if @baseline
        helper = run_red_helper(part[:path])
        fail!('baseline helper did not observe an actual UnsupportedFormatError') unless
          helper.fetch('status') == 'unsupported' && helper.fetch('error_class').end_with?('UnsupportedFormatError')

        sha_after = Digest::SHA256.file(@binary).hexdigest
        fail!('pinned ClickHouse executable SHA-256 changed during probe') unless sha_after == BinarySHA256
        write_summary(
          status: 'stock_tuple_json_observed_and_existing_reader_rejected',
          runtime: {path: @binary, sha256_before: BinarySHA256, sha256_after: sha_after,
                    version: Version, build: Build},
          helper: helper, stock: observed, part_inventory: inventory,
        )
        puts "W186 status=stock_tuple_json_observed_and_existing_reader_rejected; part=#{part[:path]}; evidence=#{@root}"
        return true
      end

      library_part = File.join(@root, 'parts', 'library_1_1_0')
      crystal = run_paired_helper(part[:path], library_part)
      assert_paired_helper!(crystal, library_part)
      library_inventory = @base.send(:inspect_part, 'library_tuple_json', library_part,
                                     {name: 'all_1_1_0', path: library_part,
                                      part_type: 'Wide', rows: '8', marks: '5'},
                                     generated_library: true)
      assert_library_roster!(library_inventory, crystal)

      target_data_path = observed.fetch(:data_paths).fetch(LibraryTable)
      @base.send(:validate_store_path!, target_data_path)
      @base.send(:attach_part!, library_part, target_data_path)
      attached = @base.send(:run_clickhouse, 'tuple_json_attach_and_check', attached_sql)
      @base.send(:assert_pin!, attached)
      @base.send(:assert_native_invocation!, attached)
      attached_result = @base.send(:parse_native, attached[:stdout])
      assert_attached_native!(attached_result)

      sha_after = Digest::SHA256.file(@binary).hexdigest
      fail!('pinned ClickHouse executable SHA-256 changed during probe') unless sha_after == BinarySHA256
      write_summary(
        status: 'paired_tuple_json_observed',
        runtime: {path: @binary, sha256_before: BinarySHA256, sha256_after: sha_after,
                  version: Version, build: Build},
        stock: observed, stock_part_inventory: inventory,
        helper: crystal.fetch(:data), helper_invocation: crystal.fetch(:invocation),
        library_part_inventory: library_inventory, attached: attached_result,
      )
      puts "W186 status=paired_tuple_json_observed; stock/library=checked; evidence=#{@root}"
      true
    rescue StandardError => error
      @error = "#{error.class}: #{error.message}"
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @error) rescue nil
      warn "W186 tuple JSON stock probe failed: #{@error}"
      false
    end

    private

    def initial_sql
      statements = [
        "SELECT '__W185_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        "CREATE TABLE default.#{Table} (pk UInt64, pair #{TupleType}) ENGINE=MergeTree ORDER BY pk SETTINGS #{Settings};",
        "CREATE TABLE default.#{LibraryTable} (pk UInt64, pair #{TupleType}) ENGINE=MergeTree ORDER BY pk SETTINGS #{Settings};",
        insert_sql,
        "SELECT '__W185_CHECK_BEGIN__', '#{Table}' FORMAT TSVRaw;",
        "CHECK TABLE default.#{Table} FORMAT TSV;",
        "SELECT '__W185_CHECK_END__', '#{Table}' FORMAT TSVRaw;",
        "SELECT '__W185_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN ('#{Table}','#{LibraryTable}') ORDER BY table, position FORMAT TSVRaw;",
        row_sql,
        middle_row_sql,
        "SELECT '__W185_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN ('#{Table}','#{LibraryTable}') ORDER BY name FORMAT TSVRaw;",
        "SELECT '__W185_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{Table}' AND active ORDER BY table,name FORMAT TSVRaw;",
      ]
      statements.join("\n") + "\n"
    end

    def insert_sql
      values = Rows.map do |row|
        left = JSON.generate(row.fetch(:left).reject { |_key, value| value.nil? })
        right = JSON.generate(row.fetch(:right).reject { |_key, value| value.nil? })
        left_cast = "CAST(#{sql_string(left)}, #{sql_string(JsonType)})"
        right_cast = "CAST(#{sql_string(right)}, #{sql_string(JsonType)})"
        pair = "CAST((#{left_cast}, #{right_cast}, #{row.fetch(:n)}), #{sql_string(TupleType)})"
        "(#{row.fetch(:pk)}, #{pair})"
      end.join(",\n")
      "INSERT INTO default.#{Table} VALUES #{values};"
    end

    def row_sql(table = Table)
      "SELECT '__W185_ROW__', '#{table}', toString(pk), toString(pair.n), " \
        "hex(toJSONString(pair.l)), hex(toJSONString(pair.r)) FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
    end

    def middle_row_sql(table = Table)
      "SELECT '__W185_MIDDLE_ROW__', '#{table}', toString(pk), toString(pair.n), " \
        "hex(toJSONString(pair.l)), hex(toJSONString(pair.r)) FROM default.#{table} " \
        "WHERE pk BETWEEN 3 AND 6 ORDER BY pk FORMAT TSVRaw;"
    end

    def assert_stock_fixture!(native)
      expected_checks = {Table => ["all_1_1_0\t1\t"]}
      fail!("stock CHECK differs: #{native[:checks].inspect}") unless native[:checks] == expected_checks
      expected_schema = [[Table, 'pk', 'UInt64'], [Table, 'pair', TupleType],
                         [LibraryTable, 'pk', 'UInt64'], [LibraryTable, 'pair', TupleType]]
      expected_schema.sort_by! { |table, name, _type| [table, name == 'pk' ? 0 : 1] }
      fail!("stock schema differs: #{native[:schemas].inspect}") unless native[:schemas] == expected_schema
      assert_rows!(native[:rows], Table, '__full__')
      assert_rows!(native[:middle_rows], Table, '__middle__')
      fail!('stock or library-target table data path was not reported') unless
        [Table, LibraryTable].all? { |table| native[:data_paths].key?(table) }
      part = native[:parts][Table] || fail!('stock did not expose the Tuple(JSON,JSON,UInt64) part')
      fail!("unexpected stock part identity/layout: #{part.inspect}") unless
        part[:name] == 'all_1_1_0' && part[:part_type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
      part
    end

    def assert_rows!(rows, table, scope)
      selected = case scope
                 when '__full__'
                   rows.select { |row| row[0] == table }
                 when '__middle__'
                   rows.select { |row| row[0] == table }
                 end
      expected = scope == '__full__' ? Rows : Rows.select { |row| (3..6).cover?(row.fetch(:pk)) }
      decoded = selected.map do |fields|
        [fields[1], fields[2], decode_json_hex(fields[3]), decode_json_hex(fields[4])]
      end
      literal = expected.map do |row|
        [row.fetch(:pk).to_s, row.fetch(:n).to_s,
         JSON.parse(JSON.generate(row.fetch(:left).reject { |_key, value| value.nil? })),
         JSON.parse(JSON.generate(row.fetch(:right).reject { |_key, value| value.nil? }))]
      end
      fail!("#{table} #{scope} rows differ from independent literal oracle") unless decoded == literal
    end

    def decode_json_hex(value)
      JSON.parse([value].pack('H*'))
    rescue JSON::ParserError
      fail!('stock row output contained malformed JSON hex')
    end

    def assert_site_rosters!(inventory)
      streams = inventory.fetch(:logical_substreams).select { |name| name.start_with?('pair') }
      required = %w[
        pair%2El.object_structure
        pair%2El.t
        pair%2El.a_left.dynamic_structure
        pair%2El.a_left.variant_discr
        pair%2El.a_left.Int64
        pair%2El.a_left.SharedVariant.size
        pair%2El.a_left.SharedVariant
        pair%2El.object_shared_data.size0
        pair%2El.object_shared_data%2Epaths
        pair%2El.object_shared_data%2Evalues
        pair%2Er.object_structure
        pair%2Er.t
        pair%2Er.b_right.dynamic_structure
        pair%2Er.b_right.variant_discr
        pair%2Er.b_right.SharedVariant.size
        pair%2Er.b_right.SharedVariant
        pair%2Er.b_right.String.size
        pair%2Er.b_right.String
        pair%2Er.object_shared_data.size0
        pair%2Er.object_shared_data%2Epaths
        pair%2Er.object_shared_data%2Evalues
        pair%2En
      ]
      missing = required - streams
      extra = streams - required
      fail!("stock Tuple(JSON) physical site roster differs; missing=#{missing.inspect}; extra=#{extra.inspect}") unless
        missing.empty? && extra.empty?
      fail!('left and right sites unexpectedly share a Dynamic path') if
        streams.any? { |name| name.start_with?('pair%2El.b_right.') || name.start_with?('pair%2Er.a_left.') }
    end

    def run_red_helper(part_path)
      argv = [@crystal_probe, part_path]
      invocation = @base.send(:execute_record, 'tuple_json_red_helper', argv, ''.b,
                              'prebuilt Crystal helper', nil, nil)
      fail!('RED helper process failed; this is not a format rejection') unless @base.send(:successful?, invocation)
      fail!('RED helper wrote stderr') unless invocation[:stderr].empty?
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('RED helper must emit exactly one JSON record') unless lines.size == 1
      JSON.parse(lines.first)
    end

    def run_paired_helper(part_path, library_part)
      fail!('library part destination already exists') if File.exist?(library_part) || File.symlink?(library_part)
      argv = [@crystal_probe, part_path, library_part]
      invocation = @base.send(:execute_record, 'tuple_json_crystal_helper', argv, ''.b,
                              'prebuilt Crystal helper', nil, nil)
      fail!('paired Crystal helper failed; this is not a ClickHouse format rejection') unless @base.send(:successful?, invocation)
      fail!('paired Crystal helper wrote diagnostics to stderr') unless invocation[:stderr].empty?
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('paired Crystal helper must emit exactly one JSON record') unless lines.size == 1
      {data: JSON.parse(lines.first), invocation: invocation[:record]}
    end

    def assert_paired_helper!(crystal, library_part)
      result = crystal.fetch(:data)
      fail!('paired helper did not report observed status') unless result.fetch('status') == 'observed'
      fail!('paired helper library destination differs') unless
        File.expand_path(result.fetch('library_part_path')) == library_part
      %w[stock library].each do |label|
        record = result.fetch("#{label}_reader")
        fail!("#{label} reader returned wrong schema") unless record.fetch('schema_declaration') == TupleType
        fail!("#{label} reader returned wrong row count") unless record.fetch('row_count') == 8
        fail!("#{label} reader returned wrong mark count") unless record.fetch('mark_count') == 4
        fail!("#{label} reader parent mark grid differs") unless record.fetch('mark_row_counts') == [2, 2, 2, 2]
        fail!("#{label} direct full rows differ from independent literals") unless record.fetch('full_rows') == expected_rows(Rows)
        fail!("#{label} direct middle rows differ from independent literals") unless
          record.fetch('middle_rows') == expected_rows(Rows.select { |row| (3..6).cover?(row.fetch(:pk)) })
        table_rows = result.fetch("#{label}_table_rows")
        table_middle_rows = result.fetch("#{label}_table_middle_rows")
        fail!("#{label} public table rows differ from independent literals") unless table_rows == expected_rows(Rows)
        fail!("#{label} public table middle window differs from independent literals") unless
          table_middle_rows == expected_rows(Rows.select { |row| (3..6).cover?(row.fetch(:pk)) })
      end
    end

    def expected_rows(rows)
      rows.map do |row|
        [row.fetch(:pk).to_s, row.fetch(:n).to_s,
         JSON.parse(JSON.generate(row.fetch(:left).reject { |_key, value| value.nil? })),
         JSON.parse(JSON.generate(row.fetch(:right).reject { |_key, value| value.nil? }))]
      end
    end

    def assert_library_roster!(inventory, crystal)
      streams = inventory.fetch(:logical_substreams).select { |name| name.start_with?('pair') }
      expected = %w[
        pair%2El.object_structure pair%2El.t pair%2El.a_left.dynamic_structure
        pair%2El.a_left.variant_discr pair%2El.a_left.Int64
        pair%2El.a_left.SharedVariant.size pair%2El.a_left.SharedVariant
        pair%2El.object_shared_data.size0 pair%2El.object_shared_data%2Epaths
        pair%2El.object_shared_data%2Evalues pair%2Er.object_structure pair%2Er.t
        pair%2Er.b_right.dynamic_structure pair%2Er.b_right.variant_discr
        pair%2Er.b_right.SharedVariant.size pair%2Er.b_right.SharedVariant
        pair%2Er.b_right.String.size pair%2Er.b_right.String
        pair%2Er.object_shared_data.size0 pair%2Er.object_shared_data%2Epaths
        pair%2Er.object_shared_data%2Evalues pair%2En
      ]
      missing = expected - streams
      extra = streams - expected
      fail!("library physical roster differs; missing=#{missing.inspect}; extra=#{extra.inspect}") unless
        missing.empty? && extra.empty?
      helper_streams = crystal.fetch(:data).fetch('library_reader').fetch('physical_stream_names')
      fail!('library helper and published logical substream rosters differ') unless
        (streams - helper_streams).empty? && (helper_streams - streams).empty?
      %w[pair%2El.object_shared_data.size0 pair%2Er.object_shared_data.size0].each do |name|
        counts = inventory.fetch(:mark_triples).fetch(name).map { |triple| triple[2] }
        fail!("#{name} mark schedule differs") unless counts == [2, 2, 2, 2, 0]
      end
    end

    def attached_sql
      [
        "SELECT '__W185_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        "ALTER TABLE default.#{LibraryTable} ATTACH PART 'all_1_1_0';",
        "SELECT '__W185_CHECK_BEGIN__', '#{LibraryTable}' FORMAT TSVRaw;",
        "CHECK TABLE default.#{LibraryTable} FORMAT TSV;",
        "SELECT '__W185_CHECK_END__', '#{LibraryTable}' FORMAT TSVRaw;",
        "SELECT '__W185_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table='#{LibraryTable}' ORDER BY position FORMAT TSVRaw;",
        row_sql(LibraryTable),
        middle_row_sql(LibraryTable),
        "SELECT '__W185_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{LibraryTable}' AND active ORDER BY name FORMAT TSVRaw;",
      ].join("\n") + "\n"
    end

    def assert_attached_native!(native)
      expected_checks = {LibraryTable => ["all_1_1_0\t1\t"]}
      fail!("stock CHECK rejected the library-written part: #{native[:checks].inspect}") unless native[:checks] == expected_checks
      expected_schema = [[LibraryTable, 'pk', 'UInt64'], [LibraryTable, 'pair', TupleType]]
      fail!("attached library schema differs: #{native[:schemas].inspect}") unless native[:schemas] == expected_schema
      assert_rows!(native[:rows], LibraryTable, '__full__')
      assert_rows!(native[:middle_rows], LibraryTable, '__middle__')
      part = native[:parts][LibraryTable] || fail!('stock did not expose attached library part')
      fail!("attached library part identity/layout differs: #{part.inspect}") unless
        part[:name] == 'all_1_1_0' && part[:part_type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
    end

    def sql_string(value)
      "'#{value.to_s.gsub('\\') { '\\\\' }.gsub("'") { "\\'" }}'"
    end

    def write_summary(data)
      summary = {
        probe: 'W186 Tuple(JSON, JSON, UInt64) stock/library discriminator',
        status: data[:status], fatal_error: data[:fatal_error],
        runtime: data[:runtime] || {path: @binary, expected_sha256: BinarySHA256,
                                    expected_version: Version, expected_build: Build},
        helper: @crystal_probe,
        limits: {max_threads: 1, local_max_memory_usage_bytes: Memory,
                 timeout_seconds: Timeout, termination_grace_seconds: Grace,
                 executor: 'CheckArrayJSONPartsW185::Probe / JsonBinaryKernelW180Probe#execute'},
        evidence_root: @root,
      }.merge(data.reject { |key, _value| %i[status fatal_error runtime].include?(key) })
      @base.send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      @base.send(:write_new, File.join(@root, 'summary.md'), [
        '# W186 Tuple(JSON, JSON, UInt64) stock/library discriminator', '',
        "Status: `#{summary[:status]}`", '',
        'One native Wide part contains two equal nominal JSON element schemas with disjoint observed Dynamic paths and nonempty shared-MAP paths. Paired mode reads the stock part and writes a library part, then reopens both and requires stock ATTACH/CHECK plus independent full/middle literal equality. `--baseline` retains the earlier typed-reader RED discriminator.', '',
        "Runtime: #{Version} / #{Build} / SHA256 `#{BinarySHA256}`", '',
        'The runner delegates the native process to the W185 guarded runner and W180 bounded executor. A helper process failure is never interpreted as an expected format rejection.', '',
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end

    def fail!(message)
      raise RuntimeError, "W186 Tuple(JSON) stock probe: #{message}"
    end
  end
end

def main
  options = {binary: CheckRecursiveJSONTuplePartsW186::Binary}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/check_recursive_json_tuple_parts_w186.rb --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP --crystal-probe PREBUILT_HELPER [--baseline] [--binary CLICKHOUSE]'
    parser.on('--binary PATH') { |value| options[:binary] = value }
    parser.on('--crystal-probe PATH') { |value| options[:crystal_probe] = value }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    parser.on('--baseline', 'Use the retained pre-feature RED helper') { options[:baseline] = true }
  end.parse!
  raise 'prebuilt Crystal helper is required via --crystal-probe' unless options[:crystal_probe]
  exit(CheckRecursiveJSONTuplePartsW186::Probe.new(options[:binary], options[:crystal_probe], options[:evidence_root], baseline: options[:baseline]).run ? 0 : 1)
rescue StandardError => error
  warn "W186 tuple JSON runner error: #{error.class}: #{error.message}"
  exit 1
end

main if $PROGRAM_NAME == __FILE__
