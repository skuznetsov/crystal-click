#!/usr/bin/env ruby
# Bounded stock/Crystal qualification for Object V3 shared MAP_WITH_BUCKETS.
# This runner never builds ClickHouse or the Crystal helper; it reuses W185's
# pinned process supervisor and immutable part inventory.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative 'check_array_json_parts_w185'
require_relative 'probe_json_array_storage_w183'

module CheckObjectSharedBucketsW190
  Binary = CheckArrayJSONPartsW185::BINARY.freeze
  BinarySHA256 = CheckArrayJSONPartsW185::BINARY_SHA256.freeze
  Version = CheckArrayJSONPartsW185::VERSION.freeze
  Build = CheckArrayJSONPartsW185::BUILD.freeze
  Memory = CheckArrayJSONPartsW185::MEMORY
  Timeout = CheckArrayJSONPartsW185::TIMEOUT
  Grace = CheckArrayJSONPartsW185::GRACE
  OuterRunSafeLimit = CheckArrayJSONPartsW185::OUTER_RUN_SAFE_LIMIT

  RootType = 'JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt8)'.freeze
  ArrayType = "Array(#{RootType})".freeze
  KeyHashes = {
    'alpha' => 14_240_850_104_022_911_259,
    'aa' => 566_436_307_820_060_636,
    'beta' => 16_749_335_384_779_311_267,
  }.freeze
  SharedKeys = %w[alpha aa beta].freeze
  RowCount = 8
  MarkRows = [2, 2, 2, 2, 0].freeze
  ArrayChildCounts = [0, 1, 3, 0].freeze
  Profiles = {
    'root2' => {source: 'source_root2', target: 'library_root2', column: 'j',
                type: RootType, kind: :root, buckets: 2, shared: true},
    'root32' => {source: 'source_root32', target: 'library_root32', column: 'j',
                 type: RootType, kind: :root, buckets: 32, shared: true},
    'array2' => {source: 'source_array2', target: 'library_array2', column: 'a',
                 type: ArrayType, kind: :array, buckets: 2, shared: true},
    'array32' => {source: 'source_array32', target: 'library_array32', column: 'a',
                  type: ArrayType, kind: :array, buckets: 32, shared: true},
    'empty1' => {source: 'source_empty1', target: 'library_empty1', column: 'j',
                 type: RootType, kind: :root, buckets: 32, expected_buckets: 1, shared: false},
  }.freeze

  def root_input(pk, include_shared: true, null_alpha: false, prefix: 'root')
    value = {'t' => pk}
    if include_shared
      value['alpha'] = null_alpha ? nil : "#{prefix}-alpha-#{pk}"
      value['aa'] = "#{prefix}-aa-#{pk}"
      value['beta'] = "#{prefix}-beta-#{pk}"
    end
    value
  end

  def array_document(index, null_alpha: false)
    {
      't' => index,
      'alpha' => null_alpha ? nil : "array-alpha-#{index}",
      'aa' => "array-aa-#{index}",
      'beta' => "array-beta-#{index}",
    }
  end

  # The read oracle is intentionally separate from INSERT literals: ClickHouse
  # omits untyped NULL paths when projecting JSON values back to rows.
  def expected_root(pk, include_shared: true, null_alpha: false, prefix: 'root')
    value = {'t' => pk}
    if include_shared
      value['alpha'] = "#{prefix}-alpha-#{pk}" unless null_alpha
      value['aa'] = "#{prefix}-aa-#{pk}"
      value['beta'] = "#{prefix}-beta-#{pk}"
    end
    value
  end

  def array_input_rows
    [
      [], [], [], [array_document(41)],
      [array_document(51), array_document(52, null_alpha: true)],
      [array_document(61)], [], [],
    ]
  end

  def root_input_rows(prefix: 'root')
    (1..RowCount).map do |pk|
      root_input(pk, null_alpha: pk == 6, prefix: prefix)
    end
  end

  def root_expected_rows(prefix: 'root')
    (1..RowCount).map do |pk|
      expected_root(pk, null_alpha: pk == 6, prefix: prefix)
    end
  end

  def profile_input_rows(profile)
    if profile.fetch(:kind) == :array
      array_input_rows
    elsif profile.fetch(:shared)
      root_input_rows
    else
      (1..RowCount).map { |pk| root_input(pk, include_shared: false) }
    end
  end

  def profile_expected_rows(profile)
    if profile.fetch(:kind) == :array
      array_input_rows.map do |documents|
        documents.map do |document|
          expected = document.dup
          expected.delete('alpha') if expected['alpha'].nil?
          expected
        end
      end
    elsif profile.fetch(:shared)
      root_expected_rows
    else
      (1..RowCount).map { |pk| expected_root(pk, include_shared: false) }
    end
  end

  class PartProbe < CheckArrayJSONPartsW185::Probe
    private

    def validate_library_part_path!(path)
      full = File.expand_path(path)
      base = File.join(@root, 'parts')
      parent = File.basename(File.dirname(full))
      fail!('library part escaped its exact task-local destination') unless
        File.dirname(full) == File.join(base, parent) &&
        %w[library_root2 library_root32 library_array2 library_array32 library_empty1].include?(parent) &&
        File.basename(full) == 'all_1_1_0'
      fail!('library part destination is absent, symlinked, or not canonical') unless
        File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full
      validate_plain_tree!(full)
      full
    end
  end

  class Probe
    include CheckObjectSharedBucketsW190

    def initialize(binary, crystal_probe, evidence_root)
      @base = PartProbe.new(binary, crystal_probe, evidence_root)
      @binary = File.expand_path(binary)
      @crystal_probe = File.expand_path(crystal_probe)
      @root = File.expand_path(evidence_root)
      @invocations = @base.instance_variable_get(:@invocations)
      @fatal_error = nil
    end

    def run
      %w[invocations stores parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      Profiles.each_value do |profile|
        Dir.mkdir(File.join(@root, 'parts', profile.fetch(:target)), 0o700)
      end
      @sha_before = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before probe') unless @sha_before == BinarySHA256

      initial = @base.send(:run_clickhouse, 'native_sources', initial_sql)
      @base.send(:assert_pin!, initial)
      @base.send(:assert_native_invocation!, initial)
      source = @base.send(:parse_native, initial[:stdout])
      hashes = parse_hash_vectors(initial[:stdout])
      assert_hash_vectors!(hashes)
      assert_initial_native!(source)

      source_inventories = {}
      Profiles.each do |label, profile|
        part = source.fetch(:parts).fetch(profile.fetch(:source))
        inventory = @base.send(:inspect_part, "stock_#{label}", part.fetch(:path), part)
        inventory[:bucket_layout] = inspect_bucket_layout!(inventory, profile, hashes)
        source_inventories[label] = inventory
      end

      library_paths = {}
      Profiles.each do |label, profile|
        parent = File.join(@root, 'parts', profile.fetch(:target))
        library_paths[label] = File.join(parent, 'all_1_1_0')
      end
      crystal = run_crystal_helper(source, library_paths)
      assert_crystal!(crystal, library_paths)

      library_inventories = {}
      Profiles.each do |label, profile|
        part = @base.send(:inspect_part, "library_#{label}", library_paths.fetch(label),
                          {name: 'all_1_1_0', path: library_paths.fetch(label),
                           part_type: 'Wide', rows: '8', marks: 'unattached'},
                          generated_library: true)
        part[:bucket_layout] = inspect_bucket_layout!(part, profile, hashes)
        library_inventories[label] = part
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
        status: 'paired_object_shared_map_with_buckets_observed',
        source: source, stock_part_inventories: source_inventories,
        hash_vectors: hashes, helper: crystal.fetch(:data),
        helper_invocation: crystal.fetch(:invocation),
        library_part_inventories: library_inventories, attached: attached_result,
      )
      puts "W190 status=paired_object_shared_map_with_buckets_observed; root/array 2/32 + empty one-bucket control checked; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @sha_after = binary_sha rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W190 shared-bucket probe failed: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise RuntimeError, message
    end

    def binary_sha
      Digest::SHA256.file(@binary).hexdigest
    end

    def shared_settings(bucket_count)
      base = CheckArrayJSONPartsW185::SETTINGS.split(', ').reject do |item|
        item.start_with?("object_shared_data_serialization_version_for_zero_level_parts=")
      end
      base.concat([
        "object_shared_data_serialization_version='map_with_buckets'",
        "object_shared_data_serialization_version_for_zero_level_parts='map_with_buckets'",
        "object_shared_data_buckets_for_wide_part=#{bucket_count}",
      ])
      base.join(', ')
    end

    def initial_sql
      statements = [
        "SELECT '__W185_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      Profiles.each do |_label, profile|
        [profile.fetch(:source), profile.fetch(:target)].each do |table|
          statements << "CREATE TABLE default.#{table} (pk UInt64, #{profile.fetch(:column)} #{profile.fetch(:type)}) ENGINE=MergeTree ORDER BY pk SETTINGS #{shared_settings(profile.fetch(:buckets))};"
        end
        statements << insert_sql(profile)
      end
      Profiles.each_value do |profile|
        table = profile.fetch(:source)
        statements << "SELECT '__W185_CHECK_BEGIN__', '#{table}' FORMAT TSVRaw;"
        statements << "CHECK TABLE default.#{table} FORMAT TSV;"
        statements << "SELECT '__W185_CHECK_END__', '#{table}' FORMAT TSVRaw;"
      end
      tables = Profiles.values.flat_map { |profile| [profile.fetch(:source), profile.fetch(:target)] }
      statements << "SELECT '__W185_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{tables.map { |name| sql_string(name) }.join(',')}) ORDER BY table, position FORMAT TSVRaw;"
      Profiles.each_value do |profile|
        statements << rows_sql(profile, '__W185_ROW__')
        statements << rows_sql(profile, '__W185_MIDDLE_ROW__', middle: true)
      end
      statements << "SELECT '__W185_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{Profiles.values.map { |profile| sql_string(profile.fetch(:target)) }.join(',')}) ORDER BY name FORMAT TSVRaw;"
      source_tables = Profiles.values.map { |profile| sql_string(profile.fetch(:source)) }.join(',')
      statements << "SELECT '__W185_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{source_tables}) AND active ORDER BY table,name FORMAT TSVRaw;"
      SharedKeys.each do |key|
        statements << "SELECT '__W190_HASH__', #{sql_string(key)}, toString(sipHash64(#{sql_string(key)})) FORMAT TSVRaw;"
      end
      statements.join("\n") + "\n"
    end

    def attached_sql
      statements = [
        "SELECT '__W185_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      Profiles.each_value do |profile|
        target = profile.fetch(:target)
        statements << "ALTER TABLE default.#{target} ATTACH PART 'all_1_1_0';"
        statements << "SELECT '__W185_CHECK_BEGIN__', '#{target}' FORMAT TSVRaw;"
        statements << "CHECK TABLE default.#{target} FORMAT TSV;"
        statements << "SELECT '__W185_CHECK_END__', '#{target}' FORMAT TSVRaw;"
      end
      targets = Profiles.values.map { |profile| sql_string(profile.fetch(:target)) }.join(',')
      statements << "SELECT '__W185_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{targets}) ORDER BY table, position FORMAT TSVRaw;"
      Profiles.each_value do |profile|
        statements << rows_sql(profile, '__W185_ROW__', target: true)
        statements << rows_sql(profile, '__W185_MIDDLE_ROW__', middle: true, target: true)
      end
      statements << "SELECT '__W185_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{targets}) AND active ORDER BY table,name FORMAT TSVRaw;"
      statements.join("\n") + "\n"
    end

    def insert_sql(profile)
      rows = profile_input_rows(profile).each_with_index.map do |value, index|
        pk = index + 1
        literal = if profile.fetch(:kind) == :array
                    values = value.map { |document| "CAST(#{sql_string(JSON.generate(document))}, #{sql_string(RootType)})" }
                    "CAST([#{values.join(',')}], #{sql_string(ArrayType)})"
                  else
                    "CAST(#{sql_string(JSON.generate(value))}, #{sql_string(RootType)})"
                  end
        "(#{pk}, #{literal})"
      end
      "INSERT INTO default.#{profile.fetch(:source)} VALUES #{rows.join(',')};"
    end

    def rows_sql(profile, tag, middle: false, target: false)
      table = target ? profile.fetch(:target) : profile.fetch(:source)
      column = profile.fetch(:column)
      length = profile.fetch(:kind) == :array ? "toString(length(#{column}))" : "'-'"
      where = middle ? ' WHERE pk BETWEEN 3 AND 6' : ''
      "SELECT '#{tag}', '#{table}', toString(pk), #{length}, hex(toJSONString(#{column})) FROM default.#{table}#{where} ORDER BY pk FORMAT TSVRaw;"
    end

    def sql_string(value)
      @base.send(:sql_string, value)
    end

    def parse_hash_vectors(stdout)
      result = {}
      stdout.force_encoding(Encoding::UTF_8).lines.each do |line|
        next unless line.start_with?("__W190_HASH__\t")
        _tag, key, value = line.chomp.split("\t", -1)
        fail!("malformed native SipHash vector row: #{line.inspect}") unless value && value.match?(/\A[0-9]+\z/)
        result[key] = Integer(value, 10)
      end
      result
    end

    def assert_hash_vectors!(observed)
      fail!("native SipHash path vectors differ: #{observed.inspect}") unless observed == KeyHashes
      expected = {
        'alpha' => {2 => 1, 32 => 27},
        'aa' => {2 => 0, 32 => 28},
        'beta' => {2 => 1, 32 => 3},
      }
      expected.each do |key, moduli|
        moduli.each do |count, bucket|
          fail!("#{key} SipHash bucket for count #{count} differs") unless observed.fetch(key) % count == bucket
        end
      end
    end

    def assert_initial_native!(native)
      expected_checks = Profiles.values.to_h do |profile|
        [profile.fetch(:source), ["all_1_1_0\t1\t"]]
      end
      fail!("stock CHECK differs: #{native[:checks].inspect}") unless native[:checks] == expected_checks

      expected_schemas = []
      Profiles.each_value do |profile|
        [profile.fetch(:source), profile.fetch(:target)].each do |table|
          expected_schemas << [table, 'pk', 'UInt64']
          expected_schemas << [table, profile.fetch(:column), profile.fetch(:type)]
        end
      end
      expected_schemas.sort_by! { |table, name, _type| [table, name == 'pk' ? 0 : 1] }
      fail!("stock schemas differ: #{native[:schemas].inspect}") unless native[:schemas] == expected_schemas

      Profiles.each do |_label, profile|
        assert_profile_rows!(native[:rows], profile, profile.fetch(:source))
        assert_profile_rows!(native[:middle_rows], profile, profile.fetch(:source), middle: true)
        part = native[:parts][profile.fetch(:source)] || fail!("missing stock part #{profile.fetch(:source)}")
        fail!("#{profile.fetch(:source)} part identity differs: #{part.inspect}") unless
          part.values_at(:name, :part_type, :rows, :marks) == ['all_1_1_0', 'Wide', '8', '5']
        fail!("target data path missing for #{profile.fetch(:target)}") unless native[:data_paths].key?(profile.fetch(:target))
      end
    end

    def assert_profile_rows!(records, profile, table, middle: false)
      selected = records.select { |row| row[0] == table }
      selected = selected.select { |row| (3..6).cover?(row[1].to_i) } if middle
      actual = selected.map do |row|
        decoded = JSON.parse([row[3]].pack('H*'))
        [row[0], row[1], row[2], decoded]
      rescue JSON::ParserError
        fail!("#{table} row #{row[1]} has invalid JSON hex")
      end
      expected_docs = profile_expected_rows(profile)
      indices = (middle ? (3..6) : (1..8)).to_a
      expected = indices.map do |pk|
        value = expected_docs[pk - 1]
        length = profile.fetch(:kind) == :array ? value.size.to_s : '-'
        [table, pk.to_s, length, value]
      end
      fail!("#{table} #{middle ? 'middle' : 'full'} literals differ") unless actual == expected
    end

    def assert_attached_native!(native)
      expected_checks = Profiles.values.to_h do |profile|
        [profile.fetch(:target), ["all_1_1_0\t1\t"]]
      end
      fail!("stock CHECK rejected a library part: #{native[:checks].inspect}") unless native[:checks] == expected_checks
      expected_schemas = []
      Profiles.each_value do |profile|
        expected_schemas << [profile.fetch(:target), 'pk', 'UInt64']
        expected_schemas << [profile.fetch(:target), profile.fetch(:column), profile.fetch(:type)]
      end
      expected_schemas.sort_by! { |table, name, _type| [table, name == 'pk' ? 0 : 1] }
      fail!("attached schemas differ: #{native[:schemas].inspect}") unless native[:schemas] == expected_schemas
      Profiles.each do |_label, profile|
        assert_profile_rows!(native[:rows], profile, profile.fetch(:target))
        assert_profile_rows!(native[:middle_rows], profile, profile.fetch(:target), middle: true)
        part = native[:parts][profile.fetch(:target)] || fail!("attached part missing: #{profile.fetch(:target)}")
        fail!("attached part identity differs for #{profile.fetch(:target)}") unless
          part.values_at(:name, :part_type, :rows, :marks) == ['all_1_1_0', 'Wide', '8', '5']
      end
    end

    def run_crystal_helper(source, library_paths)
      argv = [@crystal_probe]
      Profiles.each_value { |profile| argv << source.fetch(:parts).fetch(profile.fetch(:source)).fetch(:path) }
      Profiles.each { |label, _profile| argv << library_paths.fetch(label) }
      invocation = @base.send(:execute_record, 'crystal_helper', argv, ''.b,
                              'prebuilt Crystal helper', nil, nil)
      fail!('Crystal helper failed; this is not a ClickHouse format rejection') unless
        @base.send(:successful?, invocation)
      fail!('Crystal helper wrote diagnostics to stderr') unless invocation[:stderr].empty?
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('Crystal helper must emit exactly one JSON record') unless lines.size == 1
      {data: JSON.parse(lines.first), invocation: invocation[:record]}
    end

    def assert_crystal!(crystal, library_paths)
      result = crystal.fetch(:data)
      fail!('Crystal helper status differs') unless result.fetch('status') == 'observed'
      Profiles.each do |label, profile|
        record = result.fetch('profiles').fetch(label)
        fail!("#{label} helper schema differs") unless record.fetch('schema_declaration') == profile.fetch(:type)
        fail!("#{label} library path differs") unless File.expand_path(record.fetch('library_part_path')) == library_paths.fetch(label)
        expected = profile_expected_rows(profile)
        assert_reader_rows!(record.fetch('stock_reader'), expected, profile, "stock #{label}")
        assert_reader_rows!(record.fetch('library_reader'), expected, profile, "library #{label}")
        fail!("#{label} stock table full rows differ") unless record.fetch('stock_table_rows') == expected
        fail!("#{label} stock table middle rows differ") unless record.fetch('stock_table_middle_rows') == expected[2, 4]
        fail!("#{label} stock table zero window differs") unless record.fetch('stock_table_zero_rows') == []
        fail!("#{label} library table full rows differ") unless record.fetch('library_table_rows') == expected
        fail!("#{label} library table middle rows differ") unless record.fetch('library_table_middle_rows') == expected[2, 4]
        fail!("#{label} library table zero window differs") unless record.fetch('library_table_zero_rows') == []
      end
    end

    def assert_reader_rows!(record, expected, profile, label)
      fail!("#{label} physical mark grid differs") unless record.fetch('mark_row_counts') == MarkRows[0...-1]
      fail!("#{label} full rows differ") unless record.fetch('full_rows') == expected.each_slice(2).to_a
      fail!("#{label} middle rows differ") unless record.fetch('middle_rows') == expected[2, 4].each_slice(2).to_a
      fail!("#{label} zero-selected read differs") unless record.fetch('zero_rows') == []
      if profile.fetch(:kind) == :array
        fail!("#{label} logical child counts differ") unless record.fetch('child_occurrence_row_counts') == ArrayChildCounts
      end
      actual = record.fetch('physical_stream_names').sort
      expected_roster = expected_streams(profile).sort
      fail!("#{label} stream roster differs; missing=#{(expected_roster - actual).inspect}; extra=#{(actual - expected_roster).inspect}") unless actual == expected_roster
    end

    def expected_streams(profile)
      column = profile.fetch(:column)
      level = profile.fetch(:kind) == :array ? 1 : 0
      count = profile.fetch(:expected_buckets, profile.fetch(:buckets))
      names = ["#{column}.t", "#{column}.object_structure"]
      names << "#{column}.size0" if profile.fetch(:kind) == :array
      count.times do |bucket|
        prefix = "#{column}.object_shared_data.#{bucket}"
        names.concat(["#{prefix}.size#{level}", "#{prefix}%2Epaths", "#{prefix}%2Evalues"])
      end
      names
    end

    def inspect_bucket_layout!(inventory, profile, hashes)
      expected_count = profile.fetch(:expected_buckets, profile.fetch(:buckets))
      column = profile.fetch(:column)
      actual = inventory.fetch(:logical_substreams).sort
      expected = (expected_streams(profile) + ['pk']).sort
      fail!("#{inventory[:label]} exact hashed Object stream roster differs; missing=#{(expected - actual).inspect}; extra=#{(actual - expected).inspect}") unless actual == expected

      inventory.fetch(:mark_triples).each do |name, triples|
        next if name == 'pk'
        fail!("#{inventory[:label]} #{name} does not have all physical marks") unless triples.size == MarkRows.size
        fail!("#{inventory[:label]} #{name} mark-row coordinates differ") unless triples.map { |triple| triple[2] } == MarkRows
      end

      memberships = (profile.fetch(:shared) ? SharedKeys : []).to_h do |key|
        [key, {hash: hashes.fetch(key), bucket: hashes.fetch(key) % expected_count}]
      end
      buckets = {}
      expected_count.times do |bucket|
        prefix = "#{column}.object_shared_data.#{bucket}"
        roles = ["#{prefix}.size#{profile.fetch(:kind) == :array ? 1 : 0}",
                 "#{prefix}%2Epaths", "#{prefix}%2Evalues"]
        fail!("#{inventory[:label]} bucket #{bucket} lacks exact map lanes") unless roles.all? { |name| actual.include?(name) }
        role_marks = roles.to_h { |name| [name, inventory.fetch(:mark_triples).fetch(name)] }
        buckets[bucket.to_s] = {
          expected_keys: memberships.select { |_key, item| item.fetch(:bucket) == bucket }.keys.sort,
          logical_roles: roles,
          mark_triples_by_role: role_marks,
          stream_files: roles.flat_map do |name|
            stem = JsonArrayStorageW183.stream_hash(name)
            ["#{stem}.bin", "#{stem}.mrk2"]
          end.to_h do |filename|
            [filename, inventory.fetch(:stream_file_inventory).fetch(filename)]
          end,
        }
      end

      structure_name = "#{column}.object_structure"
      structure = decode_object_structure!(inventory, structure_name)
      fail!("#{inventory[:label]} Object structure is not Object V3") unless structure.fetch(:version) == 4
      fail!("#{inventory[:label]} shared-data structure version is not MAP_WITH_BUCKETS=1") unless structure.fetch(:shared_data_version) == 1
      fail!("#{inventory[:label]} decoded bucket count differs from #{expected_count}") unless structure.fetch(:bucket_count) == expected_count
      {
        configured_bucket_count: profile.fetch(:buckets), actual_structure_bucket_count: structure.fetch(:bucket_count),
        shared_data_version: structure.fetch(:shared_data_version), structure: structure,
        expected_hash_bucket_placement: memberships, buckets: buckets,
      }
    end

    def decode_object_structure!(inventory, logical_name)
      stem = JsonArrayStorageW183.stream_hash(logical_name)
      filename = "#{stem}.bin"
      path = File.join(inventory.fetch(:part_path), filename)
      compressed_size = File.size(path)
      limit = [JsonArrayStorageW183::COMPRESSED_INPUT_LIMIT, 65_536].min
      fail!("#{inventory[:label]} #{logical_name} compressed structure exceeds #{limit} bytes") if compressed_size > limit
      compressed = File.binread(path)
      fail!('structure input changed while capturing') unless compressed.bytesize == compressed_size
      frames = compressed_frame_spans!(compressed, logical_name)
      label = "#{inventory.fetch(:label)}_#{stem}_structure"
      @base.send(:write_new, File.join(@root, 'invocations', "#{label}.stdin.bin"), compressed)
      fail!('pinned ClickHouse executable SHA-256 mismatch before structure decode') unless binary_sha == BinarySHA256
      argv = [@binary, 'compressor', '--decompress', '--threads=1']
      invocation = @base.send(:execute_record, label, argv, compressed,
                              'clickhouse compressor --decompress', BinarySHA256, @binary)
      fail!("#{logical_name} compressor failed; this is not a format rejection") unless @base.send(:successful?, invocation)
      fail!("#{logical_name} compressor wrote diagnostics") unless invocation[:stderr].empty?
      decoded = invocation.fetch(:stdout)
      fail!("#{logical_name} decoded structure exceeds 1 MiB") if decoded.bytesize > 1024 * 1024
      fail!("#{logical_name} decoded length differs from independent LZ4 frame walk") unless decoded.bytesize == frames.fetch(:decoded_size)
      parsed = parse_structure_prefix!(decoded, logical_name)
      {
        logical_stream: logical_name, compressed_file: filename,
        compressed_bytes: compressed.bytesize, compressed_sha256: Digest::SHA256.hexdigest(compressed),
        frames: frames.fetch(:spans), decoded_bytes: decoded.bytesize,
        decoded_sha256: Digest::SHA256.hexdigest(decoded), raw_hex: decoded.unpack1('H*'),
        compressor_invocation: invocation.fetch(:record),
      }.merge(parsed)
    end

    def compressed_frame_spans!(compressed, label)
      offset = 0
      decoded_offset = 0
      spans = []
      while offset < compressed.bytesize
        fail!("#{label} compressed LZ4 header is truncated") if compressed.bytesize - offset < 25
        fail!("#{label} compressed block is not LZ4") unless compressed.getbyte(offset + 16) == 0x82
        block_size = compressed.byteslice(offset + 17, 4).unpack1('V')
        decoded_size = compressed.byteslice(offset + 21, 4).unpack1('V')
        fail!("#{label} compressed block size is invalid") if block_size < 9
        fail!("#{label} decoded block is zero or over bound") if decoded_size.zero? || decoded_size > 1024 * 1024 - decoded_offset
        ending = offset + 16 + block_size
        fail!("#{label} compressed block exceeds file") if ending > compressed.bytesize
        spans << {compressed_offset: offset, compressed_end_offset: ending,
                  decoded_offset: decoded_offset, decoded_size: decoded_size,
                  decoded_end_offset: decoded_offset + decoded_size}
        offset = ending
        decoded_offset += decoded_size
      end
      fail!("#{label} has no compressed frames") if spans.empty?
      {spans: spans, decoded_size: decoded_offset}
    end

    def parse_structure_prefix!(bytes, label)
      fail!("#{label} Object structure is shorter than fixed version prefix") if bytes.bytesize < 8
      version = bytes.byteslice(0, 8).unpack1('Q<')
      path_count, offset = read_varuint(bytes, 8, label)
      fail!("#{label} unexpected dynamic path count #{path_count}") unless path_count == 0
      shared_version, offset = read_varuint(bytes, offset, label)
      fail!("#{label} Object V3 structure prefix is truncated") if bytes.bytesize <= offset
      bucket_count = 1
      if shared_version != 0
        bucket_count, offset = read_varuint(bytes, offset, label)
      end
      fail!("#{label} structure statistics flag is truncated") if bytes.bytesize <= offset
      statistics_flag = bytes.getbyte(offset)
      fail!("#{label} structure statistics flag is invalid") unless [0, 1].include?(statistics_flag)
      offset += 1
      if statistics_flag == 0
        fail!("#{label} unexpected trailing bytes without statistics") unless offset == bytes.bytesize
      end
      {
        version: version, dynamic_path_count: path_count,
        shared_data_version: shared_version, bucket_count: bucket_count,
        statistics_flag: statistics_flag,
        statistics_suffix_bytes: bytes.byteslice(offset, bytes.bytesize - offset).to_s.bytesize,
      }
    end

    def read_varuint(bytes, offset, label)
      value = 0
      shift = 0
      start = offset
      loop do
        fail!("#{label} varuint is truncated") if offset >= bytes.bytesize || shift >= 64
        byte = bytes.getbyte(offset)
        offset += 1
        value |= (byte & 0x7f) << shift
        break if (byte & 0x80).zero?
        shift += 7
      end
      encoded = []
      remaining = value
      loop do
        byte = remaining & 0x7f
        remaining >>= 7
        encoded << (remaining.zero? ? byte : (byte | 0x80))
        break if remaining.zero?
      end
      fail!("#{label} varuint is noncanonical") unless bytes.byteslice(start, offset - start).bytes == encoded
      [value, offset]
    end

    def write_summary(data)
      summary = {
        probe: 'W190 paired Object MAP_WITH_BUCKETS stock/Crystal qualification',
        status: data[:status], fatal_error: data[:fatal_error],
        runtime: {path: @binary, expected_sha256: BinarySHA256,
                  sha256_before: @sha_before, sha256_after: @sha_after,
                  expected_version: Version, expected_build: Build},
        helper_path: @crystal_probe,
        limits: {max_threads: 1, local_max_memory_usage_bytes: Memory,
                 outer_run_safe_memory_limit_bytes: OuterRunSafeLimit,
                 timeout_seconds: Timeout, termination_grace_seconds: Grace,
                 decompressor_max_bytes: 65_536,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        settings: {base: CheckArrayJSONPartsW185::SETTINGS,
                   shared_serialization: 'map_with_buckets',
                   bucket_counts: Profiles.transform_values { |profile| profile.fetch(:buckets) }},
        expected_siphash64: KeyHashes, evidence_root: @root, invocations: @invocations,
      }.merge(data.reject { |key, _value| %i[status fatal_error].include?(key) })
      @base.send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      summary_lines = [
        '# W190 persisted Object MAP_WITH_BUCKETS qualification', '',
        "Status: `#{summary[:status]}`", '',
      ]
      if summary[:status] == 'paired_object_shared_map_with_buckets_observed'
        summary_lines << 'Five stock profiles and five library-written profiles were checked: root and Array(JSON) with two and 32 buckets, plus an empty-shared one-bucket control. The runner captured versioned ObjectStructure bytes, per-bucket hashed files and plain marks, native SipHash vectors, and stock ATTACH/CHECK/readback.'
      else
        summary_lines << 'Intended scope: five stock profiles and five library-written profiles covering root and Array(JSON) with two and 32 buckets, plus an empty-shared one-bucket control. A failure is inconclusive; inspect fatal_error and captured invocations before drawing a format conclusion.'
      end
      summary_lines.concat([
        '',
        'Bucket placement is the expected placement derived from the separately captured native SipHash vectors; this runner does not independently decode shared path lanes into key membership. A process failure is inconclusive, not a format rejection. This bounded profile does not qualify ADVANCED/CHUNKED shared layouts or every JSON schema product.', '',
      ])
      @base.send(:write_new, File.join(@root, 'summary.md'), summary_lines.join("\n"))
    end
  end

  def self.usage
    STDERR.puts 'usage: check_object_shared_buckets_w190.rb CRYSTAL_HELPER EVIDENCE_ROOT'
    exit 64
  end

  if $PROGRAM_NAME == __FILE__
    options = {binary: Binary}
    OptionParser.new do |parser|
      parser.on('--binary PATH') { |path| options[:binary] = path }
    end.parse!
    usage unless ARGV.size == 2
    ok = Probe.new(options[:binary], ARGV[0], ARGV[1]).run
    exit(ok ? 0 : 1)
  end
end
