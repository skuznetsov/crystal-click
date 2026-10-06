#!/usr/bin/env ruby
# Paired stock/library discriminator for named Tuple(JSON, JSON, UInt64)
# sites under one or two Array edges. Native execution remains bounded by the
# W180/W185 runner; this script never builds either executable.

require 'digest'
require 'json'
require 'optparse'
require_relative 'check_array_json_parts_w185'

module CheckRecursiveJSONArrayTuplePartsW187
  extend self

  Binary = CheckArrayJSONPartsW185::BINARY.freeze
  BinarySHA256 = CheckArrayJSONPartsW185::BINARY_SHA256.freeze
  Version = CheckArrayJSONPartsW185::VERSION.freeze
  Build = CheckArrayJSONPartsW185::BUILD.freeze
  Memory = CheckArrayJSONPartsW185::MEMORY
  Timeout = CheckArrayJSONPartsW185::TIMEOUT
  Grace = CheckArrayJSONPartsW185::GRACE
  OuterRunSafeLimit = CheckArrayJSONPartsW185::OUTER_RUN_SAFE_LIMIT
  # The recursive Object-site child seam currently admits BASIC Dynamic
  # discriminators only. Keep this override local to the W187 native witness;
  # W185/W186 retain their original stock-default settings.
  Settings = [
    CheckArrayJSONPartsW185::SETTINGS,
    'use_compact_variant_discriminators_serialization=0',
  ].join(', ').freeze

  JsonType = 'JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)'.freeze
  TupleType = "Tuple(l #{JsonType}, r #{JsonType}, n UInt64)".freeze
  OneType = "Array(#{TupleType})".freeze
  TwoType = "Array(Array(#{TupleType}))".freeze
  Key = 'pk'.freeze
  Column = 'a'.freeze

  def element(index)
    left = {'t' => index, 'a_left' => index + 10}
    right = {'t' => index + 20, 'b_right' => "right-#{index}"}
    if index == 1
      left['z_shared'] = 'left-shared'
      right['z_shared'] = 'right-shared'
    end
    {'l' => left, 'r' => right, 'n' => index * 100}
  end

  ElementLiterals = (1..4).to_h { |index| [index, element(index)] }.freeze
  OneValues = [[], [], [], [ElementLiterals.fetch(1)],
               [ElementLiterals.fetch(2), ElementLiterals.fetch(3)],
               [ElementLiterals.fetch(4)], [], []].freeze
  TwoValues = [[], [], [[]], [[ElementLiterals.fetch(1)]],
               [[], [ElementLiterals.fetch(2), ElementLiterals.fetch(3)]],
               [[ElementLiterals.fetch(4)]], [], []].freeze

  Profiles = {
    'one' => {source: 'source_one', target: 'library_one', type: OneType,
              array_depth: 1, values: OneValues},
    'two' => {source: 'source_two', target: 'library_two', type: TwoType,
              array_depth: 2, values: TwoValues},
  }.freeze

  class Probe
    def initialize(binary, crystal_probe, evidence_root)
      @base = CheckArrayJSONPartsW185::Probe.new(binary, crystal_probe, evidence_root)
      @root = File.expand_path(evidence_root)
      @binary = File.expand_path(binary)
      @crystal_probe = File.expand_path(crystal_probe)
      @invocations = []
      @fatal_error = nil
    end

    def run
      %w[invocations stores parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      Dir.mkdir(File.join(@root, 'parts', 'library_one'), 0o700)
      Dir.mkdir(File.join(@root, 'parts', 'library_two'), 0o700)
      @sha_before = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before probe') unless @sha_before == BinarySHA256

      initial = @base.send(:run_clickhouse, 'native_sources', initial_sql)
      @base.send(:assert_pin!, initial)
      @base.send(:assert_native_invocation!, initial)
      source = @base.send(:parse_native, initial[:stdout])
      source_parts = assert_initial_native!(source)
      stock_inventories = {}
      Profiles.each do |label, profile|
        part = source_parts.fetch(label)
        inventory = @base.send(:inspect_part, "stock_#{label}", part[:path], part)
        assert_source_roster!(inventory, profile)
        stock_inventories[label] = inventory
      end

      library_paths = {
        'one' => File.join(@root, 'parts', 'library_one', 'all_1_1_0'),
        'two' => File.join(@root, 'parts', 'library_two', 'all_1_1_0'),
      }
      crystal = run_helper(source_parts, library_paths)
      assert_helper!(crystal, library_paths)

      library_inventories = {}
      Profiles.each do |label, profile|
        inventory = inspect_library_part(label, library_paths.fetch(label), profile)
        assert_library_roster!(inventory, profile, crystal.fetch(:data).fetch('profiles').fetch(label))
        library_inventories[label] = inventory
      end

      Profiles.each do |label, profile|
        target_path = source.fetch(:data_paths).fetch(profile.fetch(:target))
        @base.send(:validate_store_path!, target_path)
        @base.send(:attach_part!, library_paths.fetch(label), target_path)
      end
      attached = @base.send(:run_clickhouse, 'native_attach_check', attached_sql)
      @base.send(:assert_pin!, attached)
      @base.send(:assert_native_invocation!, attached)
      attached_result = @base.send(:parse_native, attached[:stdout])
      assert_attached_native!(attached_result)

      @sha_after = binary_sha
      fail!('pinned ClickHouse executable SHA-256 changed during probe') unless @sha_after == BinarySHA256
      write_summary(
        status: 'paired_recursive_array_tuple_json_observed',
        source: source, stock_part_inventories: stock_inventories,
        helper: crystal.fetch(:data), helper_invocation: crystal.fetch(:invocation),
        library_part_inventories: library_inventories, attached: attached_result,
      )
      puts "W187 status=paired_recursive_array_tuple_json_observed; one/two-array parts stock-checked and attached; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @sha_after = binary_sha rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W187 recursive Array/Tuple JSON probe failed: #{@fatal_error}"
      false
    end

    private

    def initial_sql
      statements = [
        "SELECT '__W185_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        'SET output_format_json_named_tuples_as_objects=1;',
      ]
      Profiles.each do |label, profile|
        statements << "CREATE TABLE default.#{profile.fetch(:source)} (pk UInt64, a #{profile.fetch(:type)}) ENGINE=MergeTree ORDER BY pk SETTINGS #{Settings};"
        statements << "CREATE TABLE default.#{profile.fetch(:target)} (pk UInt64, a #{profile.fetch(:type)}) ENGINE=MergeTree ORDER BY pk SETTINGS #{Settings};"
        statements << insert_sql(profile)
      end
      Profiles.each_value do |profile|
        table = profile.fetch(:source)
        statements << "SELECT '__W185_CHECK_BEGIN__', '#{table}' FORMAT TSVRaw;"
        statements << "CHECK TABLE default.#{table} FORMAT TSV;"
        statements << "SELECT '__W185_CHECK_END__', '#{table}' FORMAT TSVRaw;"
        statements << row_sql(table)
        statements << middle_row_sql(table)
      end
      tables = Profiles.values.flat_map { |profile| [profile.fetch(:source), profile.fetch(:target)] }
      table_list = tables.map { |table| "'#{table}'" }.join(',')
      statements << "SELECT '__W185_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{table_list}) ORDER BY table,position FORMAT TSVRaw;"
      statements << "SELECT '__W185_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{table_list}) ORDER BY name FORMAT TSVRaw;"
      source_list = Profiles.values.map { |profile| "'#{profile.fetch(:source)}'" }.join(',')
      statements << "SELECT '__W185_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{source_list}) AND active ORDER BY table,name FORMAT TSVRaw;"
      statements.join("\n") + "\n"
    end

    def insert_sql(profile)
      declaration = profile.fetch(:type)
      depth = profile.fetch(:array_depth)
      values = profile.fetch(:values).each_with_index.map do |row_value, index|
        if depth == 1
          payload = sql_array(row_value.map { |tuple| tuple_sql(tuple) })
        else
          payload = sql_array(row_value.map do |inner|
            sql_array(inner.map { |tuple| tuple_sql(tuple) })
          end)
        end
        "(#{index + 1}, CAST(#{payload}, #{sql_string(declaration)}))"
      end.join(",\n")
      "INSERT INTO default.#{profile.fetch(:source)} VALUES #{values};"
    end

    def tuple_sql(tuple)
      left = "CAST(#{sql_string(JSON.generate(tuple.fetch('l')))}, #{sql_string(JsonType)})"
      right = "CAST(#{sql_string(JSON.generate(tuple.fetch('r')))}, #{sql_string(JsonType)})"
      "CAST((#{left}, #{right}, #{tuple.fetch('n')}), #{sql_string(TupleType)})"
    end

    def sql_array(values)
      "[#{values.join(', ')}]"
    end

    def row_sql(table)
      "SELECT '__W185_ROW__', '#{table}', toString(pk), hex(toJSONString(a)) FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
    end

    def middle_row_sql(table)
      "SELECT '__W185_MIDDLE_ROW__', '#{table}', toString(pk), hex(toJSONString(a)) FROM default.#{table} WHERE pk BETWEEN 3 AND 6 ORDER BY pk FORMAT TSVRaw;"
    end

    def attached_sql
      statements = [
        "SELECT '__W185_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        'SET output_format_json_named_tuples_as_objects=1;',
      ]
      Profiles.each_value do |profile|
        table = profile.fetch(:target)
        statements << "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';"
        statements << "SELECT '__W185_CHECK_BEGIN__', '#{table}' FORMAT TSVRaw;"
        statements << "CHECK TABLE default.#{table} FORMAT TSV;"
        statements << "SELECT '__W185_CHECK_END__', '#{table}' FORMAT TSVRaw;"
        statements << row_sql(table)
        statements << middle_row_sql(table)
      end
      targets = Profiles.values.map { |profile| "'#{profile.fetch(:target)}'" }.join(',')
      statements << "SELECT '__W185_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{targets}) ORDER BY table,position FORMAT TSVRaw;"
      statements << "SELECT '__W185_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{targets}) AND active ORDER BY table,name FORMAT TSVRaw;"
      statements.join("\n") + "\n"
    end

    def assert_initial_native!(native)
      expected_checks = Profiles.values.to_h do |profile|
        [profile.fetch(:source), ["all_1_1_0\t1\t"]]
      end
      fail!("stock source CHECK differs: #{native[:checks].inspect}") unless native[:checks] == expected_checks

      expected_schemas = []
      Profiles.each_value do |profile|
        expected_schemas << [profile.fetch(:source), 'pk', 'UInt64']
        expected_schemas << [profile.fetch(:source), Column, profile.fetch(:type)]
        expected_schemas << [profile.fetch(:target), 'pk', 'UInt64']
        expected_schemas << [profile.fetch(:target), Column, profile.fetch(:type)]
      end
      expected_schemas.sort_by! { |table, name, _type| [table, name == 'pk' ? 0 : 1] }
      fail!("stock schema differs: #{native[:schemas].inspect}") unless native[:schemas] == expected_schemas

      source_parts = {}
      Profiles.each do |label, profile|
        source = profile.fetch(:source)
        assert_native_rows!(native[:rows], source, profile, :full)
        assert_native_rows!(native[:middle_rows], source, profile, :middle)
        fail!("data path missing for #{profile.fetch(:target)}") unless native[:data_paths].key?(profile.fetch(:target))
        part = native[:parts][source] || fail!("stock source part missing for #{source}")
        unless part.values_at(:name, :part_type, :rows, :marks) == ['all_1_1_0', 'Wide', '8', '5']
          fail!("stock source layout differs for #{source}: #{part.inspect}")
        end
        source_parts[label] = part
      end
      source_parts
    end

    def assert_native_rows!(records, table, profile, scope)
      selected = records.select { |record| record[0] == table }
      decoded = selected.map do |fields|
        [table, fields[1], JSON.parse([fields[2]].pack('H*'))]
      rescue JSON::ParserError
        fail!("#{table} native output contained malformed JSON hex")
      end
      rows = expected_rows(profile)
      rows = rows.select { |row| (3..6).cover?(row[1].to_i) } if scope == :middle
      fail!("#{table} #{scope} rows differ from independent authored literals") unless decoded == rows
    end

    def expected_rows(profile)
      profile.fetch(:values).each_with_index.map do |value, index|
        [profile.fetch(:source), (index + 1).to_s, value]
      end
    end

    def assert_source_roster!(inventory, profile)
      expected = expected_streams(profile)
      actual = inventory.fetch(:logical_substreams).sort
      fail!("#{inventory[:label]} stock logical roster differs; missing=#{(expected - actual).inspect}; extra=#{(actual - expected).inspect}") unless actual == expected.sort
      assert_physical_rows!(inventory, expected - ['pk'], inventory[:label])
      shared_level = profile.fetch(:array_depth)
      fail!('stock Object shared MAP lane did not inherit the full Array nesting level') unless
        ["a%2El.object_shared_data.size#{shared_level}", "a%2Er.object_shared_data.size#{shared_level}"].all? { |name| actual.include?(name) }
    end

    def run_helper(source_parts, library_paths)
      library_paths.each do |label, path|
        fail!("library part destination already exists for #{label}") if File.exist?(path) || File.symlink?(path)
      end
      argv = [@crystal_probe,
              source_parts.fetch('one').fetch(:path), source_parts.fetch('two').fetch(:path),
              library_paths.fetch('one'), library_paths.fetch('two')]
      invocation = @base.send(:execute_record, 'crystal_helper', argv, ''.b,
                              'prebuilt Crystal helper', nil, nil)
      fail!('Crystal helper failed; this is not a ClickHouse format rejection') unless @base.send(:successful?, invocation)
      fail!('Crystal helper wrote diagnostics to stderr') unless invocation[:stderr].empty?
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('Crystal helper must emit exactly one JSON record') unless lines.size == 1
      {data: JSON.parse(lines.first), invocation: invocation[:record]}
    end

    def assert_helper!(crystal, library_paths)
      result = crystal.fetch(:data)
      fail!('Crystal helper did not report observed status') unless result.fetch('status') == 'observed'
      library_parts = result.fetch('library_parts')
      library_paths.each do |label, path|
        fail!("helper library destination differs for #{label}") unless File.expand_path(library_parts.fetch(label)) == path
      end
      Profiles.each do |label, profile|
        record = result.fetch('profiles').fetch(label)
        fail!("#{label} helper schema declaration differs") unless record.fetch('schema_declaration') == profile.fetch(:type)
        assert_reader!(record.fetch('stock_reader'), label, profile, 'stock')
        assert_reader!(record.fetch('library_reader'), label, profile, 'library')

        expected = expected_signatures(profile)
        fail!("#{label} stock table full rows differ") unless record.fetch('stock_table_rows') == expected
        fail!("#{label} stock table middle rows differ") unless record.fetch('stock_table_middle_rows') == expected_middle_signatures(profile)
        fail!("#{label} stock table zero read was not empty") unless record.fetch('stock_table_zero_rows') == []
        fail!("#{label} library table full rows differ") unless record.fetch('library_table_rows') == expected
        fail!("#{label} library table middle rows differ") unless record.fetch('library_table_middle_rows') == expected_middle_signatures(profile)
        fail!("#{label} library table zero read was not empty") unless record.fetch('library_table_zero_rows') == []
      end
    end

    def assert_reader!(record, label, profile, source)
      fail!("#{label} #{source} reader schema differs") unless record.fetch('schema_declaration') == profile.fetch(:type)
      fail!("#{label} #{source} reader row count differs") unless record.fetch('row_count') == 8
      fail!("#{label} #{source} reader mark count differs") unless record.fetch('mark_count') == 4
      fail!("#{label} #{source} physical parent grid differs") unless record.fetch('mark_row_counts') == [2, 2, 2, 2]
      fail!("#{label} #{source} full reader literals differ") unless record.fetch('full_rows') == expected_marked_signatures(profile)
      fail!("#{label} #{source} middle reader literals differ") unless record.fetch('middle_rows') == expected_middle_marked_signatures(profile)
      fail!("#{label} #{source} zero-selected-mark read was not empty") unless record.fetch('zero_rows') == []
      fail!("#{label} #{source} logical child occurrence counts differ") unless record.fetch('leaf_occurrence_counts') == [0, 1, 3, 0]

      expected_roster = expected_streams(profile) - ['pk']
      actual_roster = record.fetch('physical_stream_names')
      fail!("#{label} #{source} recursive reader physical roster differs") unless actual_roster.sort == expected_roster.sort
    end

    def expected_signatures(profile)
      profile.fetch(:values).each_with_index.map { |value, index| [(index + 1).to_s, value] }
    end

    def expected_middle_signatures(profile)
      expected_signatures(profile).select { |row| (3..6).cover?(row[0].to_i) }
    end

    def expected_marked_signatures(profile)
      expected_signatures(profile).each_slice(2).map { |mark| mark }
    end

    def expected_middle_marked_signatures(profile)
      expected_middle_signatures(profile).each_slice(2).map { |mark| mark }
    end

    def expected_streams(profile)
      level = profile.fetch(:array_depth)
      streams = %w[
        a%2El.object_structure
        a%2El.a_left.dynamic_structure
        a%2El.a_left.variant_discr
        a%2Er.object_structure
        a%2Er.b_right.dynamic_structure
        a%2Er.b_right.variant_discr
        a.size0
      ]
      streams << 'a.size1' if level == 2
      streams.concat(%w[
        a%2El.t
        a%2El.a_left.Int64
        a%2El.a_left.SharedVariant.size
        a%2El.a_left.SharedVariant
      ])
      streams.concat(["a%2El.object_shared_data.size#{level}",
                      'a%2El.object_shared_data%2Epaths',
                      'a%2El.object_shared_data%2Evalues'])
      streams.concat(%w[
        a%2Er.t
        a%2Er.b_right.SharedVariant.size
        a%2Er.b_right.SharedVariant
        a%2Er.b_right.String.size
        a%2Er.b_right.String
      ])
      streams.concat(["a%2Er.object_shared_data.size#{level}",
                      'a%2Er.object_shared_data%2Epaths',
                      'a%2Er.object_shared_data%2Evalues',
                      'a%2En', 'pk'])
      streams
    end

    def assert_library_roster!(inventory, profile, record)
      expected = expected_streams(profile)
      actual = inventory.fetch(:logical_substreams).sort
      fail!("library #{inventory[:label]} physical roster differs") unless actual == expected.sort
      assert_physical_rows!(inventory, expected - ['pk'], inventory[:label])
      helper_names = record.fetch('library_reader').fetch('physical_stream_names')
      fail!("library #{inventory[:label]} reader/part roster differs") unless helper_names.sort == (expected - ['pk']).sort
      fail!('array wrapper size lanes and Object shared size lane were conflated') if
        (profile.fetch(:array_depth) == 2 && actual.include?('a.size2'))
    end

    def inspect_library_part(label, path, profile)
      expected_path = File.join(@root, 'parts', "library_#{label}", 'all_1_1_0')
      fail!("library part escaped its exact destination: #{path}") unless File.expand_path(path) == expected_path
      fail!("library part is absent: #{path}") unless File.directory?(path)
      @base.send(:validate_plain_tree!, path)

      required_files = %w[
        columns.txt columns_substreams.txt count.txt checksums.txt primary.idx
        serialization.json default_compression_codec.txt metadata_version.txt
      ]
      required_files.each do |name|
        fail!("library #{label} part is missing #{name}") unless File.file?(File.join(path, name))
      end
      columns = File.read(File.join(path, 'columns.txt'))
      fail!("library #{label} exact column declaration differs") unless columns.include?("`a` #{profile.fetch(:type)}\n")
      fail!("library #{label} primary-key declaration differs") unless columns.include?("`pk` UInt64\n")
      fail!("library #{label} count.txt differs") unless File.read(File.join(path, 'count.txt')).strip == '8'
      fail!("library #{label} default codec differs") unless File.read(File.join(path, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)'
      fail!("library #{label} metadata version differs") unless File.read(File.join(path, 'metadata_version.txt')).strip == '0'
      serialization_text = File.binread(File.join(path, 'serialization.json')).force_encoding(Encoding::UTF_8)
      serialization = JSON.parse(serialization_text)
      fail!("library #{label} serialization version differs") unless serialization['version'] == 1
      fail!("library #{label} did not explicitly propagate nested serialization versions") unless
        serialization['propagate_types_serialization_versions_to_nested_types'] == true
      string_version = serialization.dig('types_serialization_versions', 'string')
      fail!("library #{label} ordinary string version is unsupported") unless [0, 1].include?(string_version)

      substreams = File.binread(File.join(path, 'columns_substreams.txt')).force_encoding(Encoding::UTF_8)
      logical = substreams.lines.map do |line|
        line.strip.sub(/\A\*\s*/, '') if line.start_with?("\t")
      end.compact
      fail!("library #{label} logical stream roster differs") unless logical.sort == expected_streams(profile).sort
      fail!("library #{label} has duplicate logical streams") unless logical.uniq.size == logical.size
      filenames = Dir.children(path).sort
      expected_stream_files = logical.flat_map do |name|
        stem = JsonArrayStorageW183.stream_hash(name)
        ["#{stem}.bin", "#{stem}.mrk2"]
      end.sort
      actual_stream_files = filenames.select { |name| name.end_with?('.bin', '.mrk2') }.sort
      fail!("library #{label} hashed lane files differ from its logical roster") unless actual_stream_files == expected_stream_files

      mark_triples = logical.to_h do |name|
        stem = JsonArrayStorageW183.stream_hash(name)
        raw = File.binread(File.join(path, "#{stem}.mrk2"))
        words = raw.unpack('Q<*')
        fail!("library #{label} #{name} has malformed plain marks") unless words.size == 15
        [name, words.each_slice(3).map(&:dup)]
      end
      inventory = {
        label: "library_#{label}", part_name: 'all_1_1_0', part_path: path,
        part_type: 'Wide', rows: '8', marks: 'unattached', count_text: '8',
        logical_substreams: logical, physical_file_names: filenames,
        mark_triples: mark_triples,
        stream_file_inventory: actual_stream_files.to_h do |filename|
          [filename, {size: File.size(File.join(path, filename)), sha256: Digest::SHA256.file(File.join(path, filename)).hexdigest}]
        end,
        serialization_json_sha256: Digest::SHA256.hexdigest(serialization_text),
        ordinary_string_serialization_version: string_version,
        plain_mrk2_only: true,
      }
      assert_physical_rows!(inventory, expected_streams(profile) - ['pk'], "library_#{label}")
      inventory
    end

    def assert_physical_rows!(inventory, stream_names, label)
      expected = [2, 2, 2, 2, 0]
      stream_names.each do |name|
        triples = inventory.fetch(:mark_triples)[name] || fail!("#{label} is missing marks for #{name}")
        fail!("#{label} #{name} physical parent mark grid differs") unless triples.map { |triple| triple[2] } == expected
      end
    end

    def assert_attached_native!(native)
      expected_checks = Profiles.values.to_h do |profile|
        [profile.fetch(:target), ["all_1_1_0\t1\t"]]
      end
      fail!("stock rejected or failed a library part CHECK: #{native[:checks].inspect}") unless native[:checks] == expected_checks
      expected_schemas = Profiles.values.flat_map do |profile|
        [[profile.fetch(:target), 'pk', 'UInt64'], [profile.fetch(:target), Column, profile.fetch(:type)]]
      end
      expected_schemas.sort_by! { |table, name, _type| [table, name == 'pk' ? 0 : 1] }
      fail!("attached library schemas differ: #{native[:schemas].inspect}") unless native[:schemas] == expected_schemas
      Profiles.each_value do |profile|
        table = profile.fetch(:target)
        assert_native_rows!(native[:rows], table, profile.merge(source: table), :full)
        assert_native_rows!(native[:middle_rows], table, profile.merge(source: table), :middle)
        part = native[:parts][table] || fail!("stock did not expose attached part for #{table}")
        fail!("attached #{table} part identity/layout differs") unless
          part.values_at(:name, :part_type, :rows, :marks) == ['all_1_1_0', 'Wide', '8', '5']
      end
    end

    def sql_string(value)
      "'#{value.to_s.gsub('\\') { '\\\\' }.gsub("'") { "\\'" }}'"
    end

    def binary_sha
      Digest::SHA256.file(@binary).hexdigest
    end

    def write_summary(data)
      summary = {
        probe: 'W187 paired persisted recursive Array/Tuple JSON stock/library qualification',
        status: data[:status], fatal_error: data[:fatal_error],
        runtime: {path: @binary, expected_sha256: BinarySHA256, sha256_before: @sha_before,
                  sha256_after: @sha_after, expected_version: Version, expected_build: Build},
        helper: @crystal_probe,
        limits: {max_threads: 1, local_max_memory_usage_bytes: Memory,
                 required_outer_run_safe_memory_limit_bytes: OuterRunSafeLimit,
                 timeout_seconds: Timeout, termination_grace_seconds: Grace,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        settings: Settings, evidence_root: @root,
      }.merge(data.reject { |key, _value| %i[status fatal_error].include?(key) })
      @base.send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      @base.send(:write_new, File.join(@root, 'summary.md'), [
        '# W187 paired persisted recursive Array/Tuple JSON qualification', '',
        "Status: `#{summary[:status]}`", '',
        'Two root profiles are compared: Array(Tuple(JSON, JSON, UInt64)) and Array(Array(Tuple(JSON, JSON, UInt64))). Each has eight parent rows and four two-row physical marks; leaf Tuple occurrence counts are independently expected as [0, 1, 3, 0]. The two equal nominal JSON sites use separate Int64/String Dynamic paths and nonempty shared MAP data.', '',
        'The helper directly reopens both stock parts and both library-written parts, and the public table path is checked for full, middle, and zero-selected reads. Stock then ATTACH/CHECKs both library parts and compares exact schemas and all authored full/middle literal rows. This is a finite two-profile discriminator, not blanket recursive admission.', '',
        "Runtime: #{Version} / #{Build} / SHA256 `#{BinarySHA256}`", '',
        'Native jobs are delegated to the bounded W185/W180 executor; a helper failure is never classified as a format rejection.', '',
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end

    def fail!(message)
      raise RuntimeError, "W187 recursive Array/Tuple JSON probe: #{message}"
    end
  end
end

def main
  options = {binary: CheckRecursiveJSONArrayTuplePartsW187::Binary}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/check_recursive_json_array_tuple_parts_w187.rb --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP --crystal-probe PREBUILT_HELPER [--binary CLICKHOUSE]'
    parser.on('--binary PATH') { |value| options[:binary] = value }
    parser.on('--crystal-probe PATH') { |value| options[:crystal_probe] = value }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
  end.parse!
  raise 'prebuilt Crystal helper is required via --crystal-probe' unless options[:crystal_probe]
  exit(CheckRecursiveJSONArrayTuplePartsW187::Probe.new(options[:binary], options[:crystal_probe], options[:evidence_root]).run ? 0 : 1)
rescue StandardError => error
  warn "W187 recursive Array/Tuple JSON runner error: #{error.class}: #{error.message}"
  exit 1
end

main if $PROGRAM_NAME == __FILE__
