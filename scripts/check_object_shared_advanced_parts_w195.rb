#!/usr/bin/env ruby
# Bounded paired qualification of W191 Object ADVANCED/CHUNKED stock parts and
# independently authored Crystal parts. This is finite fixture evidence, not
# general persisted Object-format admission.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative 'check_array_json_parts_w185'
require_relative 'probe_object_shared_advanced_w191'
require_relative 'reconcile_object_shared_advanced_w191'
require_relative 'reconcile_object_shared_path_w193'
require_relative 'reconcile_object_shared_physical_w194'

module CheckObjectSharedAdvancedPartsW195
  extend self

  W185 = CheckArrayJSONPartsW185
  W191 = ProbeObjectSharedAdvancedW191
  R191 = ReconcileObjectSharedAdvancedW191
  R193 = ReconcileObjectSharedPathW193
  R194 = ReconcileObjectSharedPhysicalW194
  ProbeBase = W185::Probe

  BINARY = W185::BINARY
  BINARY_SHA256 = W185::BINARY_SHA256
  VERSION = W185::VERSION
  BUILD = W185::BUILD
  MEMORY = W185::MEMORY
  TIMEOUT = W185::TIMEOUT
  GRACE = W185::GRACE
  OUTER_RUN_SAFE_LIMIT = W185::OUTER_RUN_SAFE_LIMIT
  ROOT_JSON = W191::RootType
  ARRAY_JSON = W191::ArrayType
  PROFILE_IDS = R191::PROFILE_ORDER
  MARK_ROWS = [2, 2, 2, 2, 0].freeze
  ROWS_PER_MARK = [2, 2, 2, 2].freeze
  FORMAT = 'object_shared_advanced_parts_w195_input_v1'.freeze
  HELPER_FORMAT = 'object_shared_advanced_parts_w195_helper_v1'.freeze

  class ProbeError < StandardError; end

  def require!(condition, message)
    raise ProbeError, message unless condition
  end

  def json_value(bytes, label)
    JSON.parse(bytes)
  rescue JSON::ParserError => error
    raise ProbeError, "#{label}: invalid JSON: #{error.message}"
  end

  def exact_profile_rows(profile_id)
    profile = W191::Profiles.find { |candidate| candidate.fetch(:id) == profile_id }
    raise ProbeError, "#{profile_id}: fixture profile is absent" unless profile
    profile.fetch(:rows)
  end

  def expected_authored_literal_rows(profile_id)
    profile = W191::Profiles.find { |candidate| candidate.fetch(:id) == profile_id }
    raise ProbeError, "#{profile_id}: fixture profile is absent" unless profile
    profile.fetch(:rows).each_with_index.map do |row, index|
      [index + 1, profile.fetch(:kind) == :array ? row.size.to_s : '-', row]
    end
  end

  def expected_path_rows(profile_id, kind, path)
    rows = exact_profile_rows(profile_id)
    if kind == 'array'
      rows.map { |documents| documents.map { |document| document[path] } }
    else
      rows.map { |document| document[path] }
    end
  end

  def expected_middle(rows)
    rows[2, 4]
  end

  def canonical_source_part_path(profile)
    part = profile.fetch('part')
    raw_path = part.fetch('part_path')
    require!(part.fetch('part_name') == 'all_1_1_0', 'W191 source part name differs')
    require!(raw_path.is_a?(String) && raw_path.start_with?(File::SEPARATOR),
      'W191 source part path must be absolute')
    normalized = File.expand_path(raw_path)
    require!(raw_path == normalized + File::SEPARATOR,
      'W191 source part path must be canonical with exactly one trailing separator')
    normalized
  rescue KeyError => error
    raise ProbeError, "W191 source part metadata is missing #{error.key.inspect}"
  end

  def normalize_reader_rows(record, profile_id, section)
    rows = record.fetch(section)
    require!(rows.is_a?(Array), "#{profile_id} helper #{section} must be an array")
    rows
  end

  class PartProbe < W185::Probe
    def initialize(binary, helper, evidence_root, capture_root, source_parts, library_parts)
      @capture_root = File.realpath(capture_root)
      @source_parts = source_parts.transform_values { |path| File.expand_path(path) }
      @library_parts = library_parts.transform_values { |path| File.expand_path(path) }
      @part_paths_configured = false
      super(binary, helper, evidence_root)
    end

    def configure_part_paths!(source_parts, library_parts)
      fail!('part allowlists were already configured') if @part_paths_configured
      expected_ids = PROFILE_IDS.sort
      fail!('source/library part allowlists must be complete and aligned') unless
        source_parts.keys.sort == expected_ids && library_parts.keys.sort == expected_ids

      normalized_sources = source_parts.transform_values { |path| File.expand_path(path) }
      normalized_libraries = library_parts.transform_values { |path| File.expand_path(path) }
      fail!('source part allowlist escaped authenticated capture root') unless
        normalized_sources.values.all? { |path| path.start_with?(@capture_root + File::SEPARATOR) }
      generated_root = File.join(@root, 'generated')
      fail!('library part allowlist escaped generated root') unless
        normalized_libraries.values.all? { |path| path.start_with?(generated_root + File::SEPARATOR) }

      @source_parts = normalized_sources
      @library_parts = normalized_libraries
      @part_paths_configured = true
      self
    end

    private

    def validate_part_path!(path)
      full = File.expand_path(path)
      unless @source_parts.value?(full) && File.directory?(full) && !File.symlink?(full) &&
             File.realpath(full) == full && full.start_with?(@capture_root + File::SEPARATOR)
        fail!("stock part is not one of the exact authenticated W191 paths: #{path}")
      end
      validate_plain_tree!(full)
      full
    end

    def validate_library_part_path!(path)
      full = File.expand_path(path)
      unless @library_parts.value?(full) && File.directory?(full) && !File.symlink?(full) &&
             File.realpath(full) == full
        fail!("library part escaped its exact W195 destination: #{path}")
      end
      validate_plain_tree!(full)
      full
    end
  end

  class Probe
    include CheckObjectSharedAdvancedPartsW195

    def initialize(binary, helper, evidence_root, capture_root)
      @binary = File.expand_path(binary)
      @helper = File.expand_path(helper)
      @root = File.expand_path(evidence_root)
      @capture_root = File.realpath(capture_root)
      @fatal_error = nil
      @invocations = []
      @sha_before = nil
      @sha_after = nil
      validate_empty_root!
      require!(File.file?(@helper) && File.executable?(@helper) && !File.symlink?(@helper),
        'prebuilt Crystal helper is missing, not executable, or symlinked')
      require!(File.file?(@binary) && File.executable?(@binary) && !File.symlink?(@binary),
        'pinned ClickHouse binary is missing, not executable, or symlinked')
      @base = PartProbe.new(@binary, @helper, @root, @capture_root, {}, {})
      @invocations = @base.instance_variable_get(:@invocations)
    end

    def run
      create_evidence_layout!
      @sha_before = binary_sha
      require!(@sha_before == BINARY_SHA256, 'ClickHouse executable SHA-256 differs from W185/W191 pin')

      manifest, manifest_json = R194.derive_manifest(@capture_root)
      @manifest_sha256 = Digest::SHA256.hexdigest(manifest_json)
      source_profiles = load_authenticated_w191_profiles!
      source_parts = source_profiles.to_h do |id, profile|
        [id, canonical_source_part_path(profile)]
      end
      library_parts = PROFILE_IDS.to_h do |id|
        [id, File.join(@root, 'generated', id, 'all_1_1_0')]
      end
      prepare_library_parents!(library_parts)
      @base.configure_part_paths!(source_parts, library_parts)

      initial = @base.send(:run_clickhouse, 'native_create_targets', initial_sql)
      assert_native!(initial, 'initial ClickHouse target creation')
      native_initial = parse_w195_native(initial[:stdout])
      assert_initial_native!(native_initial)

      source_inventories = {}
      library_inventories = {}
      PROFILE_IDS.each do |id|
        source_profile = source_profiles.fetch(id)
        source_part = source_parts.fetch(id)
        source_part_record = source_profile.fetch('part')
        stock_info = {name: source_part_record.fetch('part_name'), path: source_part,
                      part_type: source_part_record.fetch('part_type'),
                      rows: source_part_record.fetch('rows'), marks: source_part_record.fetch('marks')}
        inventory = @base.send(:inspect_part, "stock_#{id}", source_part, stock_info)
        source_inventories[id] = inventory
      end

      helper = run_helper(source_profiles, source_parts, library_parts)
      assert_helper!(helper, source_profiles, library_parts)

      PROFILE_IDS.each do |id|
        library_path = library_parts.fetch(id)
        info = {name: 'all_1_1_0', path: library_path, part_type: 'Wide', rows: '8', marks: '5'}
        inventory = @base.send(:inspect_part, "library_#{id}", library_path, info,
                               generated_library: true)
        library_inventories[id] = inventory
        assert_same_roster!(id, source_inventories.fetch(id), inventory, manifest, source_profiles)
      end

      source_paths = native_initial.fetch(:data_paths)
      PROFILE_IDS.each do |id|
        source_table, library_table = table_names(id)
        [source_table, library_table].each do |table|
          data_path = source_paths.fetch(table) { raise ProbeError, "missing native data path for #{table}" }
          @base.send(:validate_store_path!, data_path)
        end
        @base.send(:attach_part!, source_parts.fetch(id), source_paths.fetch(source_table))
        @base.send(:attach_part!, library_parts.fetch(id), source_paths.fetch(library_table))
      end

      attached = @base.send(:run_clickhouse, 'native_attach_check_read', attached_sql)
      assert_native!(attached, 'ATTACH/CHECK/readback')
      native_attached = parse_w195_native(attached[:stdout])
      assert_attached_native!(native_attached)

      @sha_after = binary_sha
      require!(@sha_after == BINARY_SHA256, 'ClickHouse executable SHA-256 changed during W195 run')
      write_summary(status: 'paired_advanced_full_part_observed', manifest: manifest,
                    source_profiles: source_profiles, source_inventories: source_inventories,
                    library_inventories: library_inventories, helper: helper,
                    initial: native_initial, attached: native_attached)
      puts "W195 status=paired_advanced_full_part_observed profiles=#{PROFILE_IDS.size} evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @sha_after = binary_sha rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W195 paired full-part probe failed: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise ProbeError, message
    end

    def validate_empty_root!
      expected_parent = File.realpath('/private/tmp')
      require!(File.directory?(@root) && !File.symlink?(@root) && File.realpath(@root) == @root &&
               File.dirname(@root) == expected_parent && Dir.children(@root).empty?,
        'evidence root must be a precreated, empty, canonical direct child of /private/tmp')
    end

    def create_evidence_layout!
      %w[invocations stores parts generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      Dir.mkdir(File.join(@root, 'generated', 'input'), 0o700)
    end

    def prepare_library_parents!(paths)
      paths.each do |id, part_path|
        parent = File.dirname(part_path)
        Dir.mkdir(parent, 0o700)
        expected_parent = File.join(@root, 'generated', id)
        require!(parent == expected_parent && !File.exist?(part_path) && !File.symlink?(part_path),
          "#{id}: library part destination is not fresh under generated root")
      end
    end

    def binary_sha
      Digest::SHA256.file(@binary).hexdigest
    end

    def load_authenticated_w191_profiles!
      _root, summary, = R193.load_capture!(@capture_root)
      profiles = summary.fetch('profiles').to_h { |profile| [profile.fetch('id'), profile] }
      require!(profiles.keys.sort == PROFILE_IDS.sort, 'authenticated W191 profile roster differs')
      PROFILE_IDS.to_h do |id|
        profile = profiles.fetch(id)
        literal = exact_profile_rows(id)
        expectation = R191::PROFILE_EXPECTATIONS.fetch(id)
        expected_kind = expectation.fetch(:kind)
        expected_mode = expectation.fetch(:mode)
        expected_buckets = expectation.fetch(:buckets)
        require!(profile.fetch('status') == 'stock_profile_observed' && profile.fetch('kind') == expected_kind &&
                 profile.fetch('requested_shared_version') == expected_mode &&
                 profile.fetch('expected_actual_bucket_count') == expected_buckets &&
                 profile.fetch('authored_literal_rows') == expected_authored_literal_rows(id),
          "#{id}: W191 authenticated stock literal/profile differs from independent expected fixture")
        part = profile.fetch('part')
        require!(literal.size == 8 && part.fetch('rows').to_s == '8' &&
                 part.fetch('marks').to_s == '5' && part.fetch('part_type') == 'Wide',
          "#{id}: stock part dimensions/type differ")
        canonical_source_part_path(profile)
        [id, profile]
      end
    rescue KeyError => error
      raise ProbeError, "W191 stock capture is missing #{error.key.inspect}"
    end

    def table_names(id)
      ["source_#{id}", "library_#{id}"]
    end

    def native_settings(id)
      profile = W191::Profiles.find { |candidate| candidate.fetch(:id) == id }
      require!(profile, "#{id}: no fixed W191 native settings profile")
      W191::Probe.allocate.send(:settings, profile)
    end

    def initial_sql
      statements = [
        "SELECT '__W195_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      PROFILE_IDS.each do |id|
        profile = R191::PROFILE_EXPECTATIONS.fetch(id)
        column = profile.fetch(:kind) == 'array' ? 'a' : 'j'
        type = column == 'a' ? ARRAY_JSON : ROOT_JSON
        source_table, library_table = table_names(id)
        settings = native_settings(id)
        [source_table, library_table].each do |table|
          statements << "CREATE TABLE default.#{table} (pk UInt64, #{column} #{type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};"
        end
      end
      names = PROFILE_IDS.flat_map { |id| table_names(id) }
      quoted = names.map { |name| sql_string(name) }.join(',')
      statements << "SELECT '__W195_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{quoted}) ORDER BY table, position FORMAT TSVRaw;"
      statements << "SELECT '__W195_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{quoted}) ORDER BY name FORMAT TSVRaw;"
      statements << "SELECT '__W195_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{quoted}) AND active ORDER BY table,name FORMAT TSVRaw;"
      statements.join("\n") + "\n"
    end

    def attached_sql
      statements = [
        "SELECT '__W195_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      PROFILE_IDS.each do |id|
        table_names(id).each do |table|
          statements << "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';"
          statements << "SELECT '__W195_CHECK_BEGIN__', '#{table}' FORMAT TSVRaw;"
          statements << "CHECK TABLE default.#{table} FORMAT TSV;"
          statements << "SELECT '__W195_CHECK_END__', '#{table}' FORMAT TSVRaw;"
        end
      end
      names = PROFILE_IDS.flat_map { |id| table_names(id) }
      quoted = names.map { |name| sql_string(name) }.join(',')
      statements << "SELECT '__W195_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{quoted}) ORDER BY table, position FORMAT TSVRaw;"
      PROFILE_IDS.each do |id|
        table_names(id).each do |table|
          column = R191::PROFILE_EXPECTATIONS.fetch(id).fetch(:kind) == 'array' ? 'a' : 'j'
          length = column == 'a' ? "toString(length(#{column}))" : "'-'"
          statements << "SELECT '__W195_ROW__', '#{table}', toString(pk), #{length}, hex(toJSONString(#{column})) FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
          statements << "SELECT '__W195_MIDDLE_ROW__', '#{table}', toString(pk), #{length}, hex(toJSONString(#{column})) FROM default.#{table} WHERE pk BETWEEN 3 AND 6 ORDER BY pk FORMAT TSVRaw;"
          statements << "SELECT '__W195_ZERO_BEGIN__', '#{table}' FORMAT TSVRaw;"
          statements << "SELECT '__W195_ZERO_ROW__', '#{table}', toString(pk), hex(toJSONString(#{column})) FROM default.#{table} WHERE pk >= 9 ORDER BY pk FORMAT TSVRaw;"
          statements << "SELECT '__W195_ZERO_END__', '#{table}' FORMAT TSVRaw;"
        end
      end
      PROFILE_IDS.select { |id| R191::PROFILE_EXPECTATIONS.fetch(id).fetch(:buckets) == 2 }.each do |id|
        table_names(id).each do |table|
          column = R191::PROFILE_EXPECTATIONS.fetch(id).fetch(:kind) == 'array' ? 'a' : 'j'
          %w[alpha aa beta].each do |path|
            projection = native_path_json_expression(column, path,
              R191::PROFILE_EXPECTATIONS.fetch(id).fetch(:kind))
            statements << "SELECT '__W195_PATH_ROW__', '#{table}', '#{path}', toString(pk), #{projection} FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
          end
        end
      end
      names = PROFILE_IDS.flat_map { |id| table_names(id) }
      quoted = names.map { |name| sql_string(name) }.join(',')
      statements << "SELECT '__W195_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{quoted}) AND active ORDER BY table,name FORMAT TSVRaw;"
      statements.join("\n") + "\n"
    end

    # Object path subcolumns backed by shared data are Dynamic columns. Extract
    # the String arm before JSON rendering: serializing the generic Dynamic
    # subcolumn can dispatch through its Nothing arm for missing values.
    # dynamicElement preserves Array offsets for Array(Dynamic), retaining
    # absent elements and empty parent arrays in this direct path read.
    def native_path_json_expression(column, path, kind)
      subcolumn = "#{column}.#{path}"
      value = "dynamicElement(#{subcolumn}, 'String')"
      serialized = "toJSONString(#{value})"
      serialized = "ifNull(#{serialized}, 'null')" unless kind.to_s == 'array'
      "hex(#{serialized})"
    end

    def sql_string(value)
      "'#{value.to_s.gsub('\\') { '\\\\' }.gsub("'") { "\\'" }}'"
    end

    def assert_native!(invocation, label)
      pin_lines = invocation.fetch(:stdout).force_encoding(Encoding::UTF_8).lines.map(&:chomp)
        .select { |line| line.start_with?("__W195_PIN__\t") }
      require!(pin_lines == ["__W195_PIN__\t#{VERSION}\t#{BUILD}"],
        "#{label}: runtime pin mismatch or duplicate pin marker")
      @base.send(:assert_native_invocation!, invocation)
      require!(invocation.fetch(:classification) == 'success', "#{label}: process classification not success")
    end

    def assert_initial_native!(native)
      expected_schemas = []
      PROFILE_IDS.each do |id|
        column = R191::PROFILE_EXPECTATIONS.fetch(id).fetch(:kind) == 'array' ? 'a' : 'j'
        type = column == 'a' ? ARRAY_JSON : ROOT_JSON
        table_names(id).each do |table|
          expected_schemas << [table, 'pk', 'UInt64']
          expected_schemas << [table, column, type]
        end
      end
      require!(native.fetch(:schemas).sort == expected_schemas.sort, 'native target schema roster differs')
      expected_paths = PROFILE_IDS.flat_map { |id| table_names(id) }.sort
      require!(native.fetch(:data_paths).keys.sort == expected_paths, 'native source/library data path roster differs')
      expected_paths.each do |table|
        path = native.fetch(:data_paths).fetch(table)
        require!(path.start_with?(File.join(@root, 'stores', 'native') + File::SEPARATOR),
          "#{table}: ClickHouse table path escaped task-local store")
      end
      require!(native.fetch(:parts).empty?, 'fresh W195 native store unexpectedly already contains parts')
    end

    def helper_input(source_profiles, source_parts, library_parts)
      profiles = PROFILE_IDS.map do |id|
        profile = R191::PROFILE_EXPECTATIONS.fetch(id)
        {
          'profile_id' => id,
          'kind' => profile.fetch(:kind),
          'shared_version' => profile.fetch(:mode) == 'advanced' ? 2 : 3,
          'bucket_count' => profile.fetch(:buckets),
          'empty' => id.start_with?('empty_'),
          'capture_root' => @capture_root,
          'source_part' => File.realpath(source_parts.fetch(id)),
          'library_part' => library_parts.fetch(id),
        }
      end
      {'format' => FORMAT, 'capture_root' => @capture_root, 'profiles' => profiles}
    end

    def run_helper(source_profiles, source_parts, library_parts)
      input_path = File.join(@root, 'generated', 'input', 'helper-input.json')
      input = JSON.pretty_generate(helper_input(source_profiles, source_parts, library_parts)) + "\n"
      @base.send(:write_new, input_path, input)
      output_root = File.join(@root, 'generated')
      argv = [@helper, input_path, output_root]
      result = @base.send(:execute_record, 'crystal_pair_helper', argv, ''.b,
                          'prebuilt Crystal helper', nil, nil)
      require!(result[:classification] == 'success' && result[:status]&.success? &&
               result[:status]&.termsig.nil?, 'Crystal helper failed; not a ClickHouse format decision')
      require!(result[:stderr].empty?, 'Crystal helper wrote diagnostics to stderr')
      lines = result[:stdout].lines.map(&:chomp).reject(&:empty?)
      require!(lines.size == 1, 'Crystal helper must emit exactly one JSON record')
      data = JSON.parse(lines.first)
      require!(data.fetch('format') == HELPER_FORMAT && data.fetch('profile_ids') == PROFILE_IDS,
        'Crystal helper output header/profile IDs differ')
      {data: data, invocation: result[:record], input_sha256: Digest::SHA256.hexdigest(input)}
    end

    def assert_helper!(helper, source_profiles, library_parts)
      profiles = helper.fetch(:data).fetch('profiles')
      require!(profiles.map { |profile| profile.fetch('profile_id') } == PROFILE_IDS,
        'Crystal helper output profile order differs')
      PROFILE_IDS.each_with_index do |id, index|
        profile = profiles.fetch(index)
        expected = R191::PROFILE_EXPECTATIONS.fetch(id)
        kind = expected.fetch(:kind).to_s
        declaration = kind == 'array' ? "Array(#{ROOT_JSON})" : ROOT_JSON
        require!(profile.fetch('kind') == kind && profile.fetch('shared_version') == (expected.fetch(:mode) == 'advanced' ? 2 : 3) &&
                 profile.fetch('bucket_count') == expected.fetch(:buckets) &&
                 profile.fetch('declaration') == declaration &&
                 File.expand_path(profile.fetch('library_part_path')) == library_parts.fetch(id),
          "#{id}: Crystal helper profile metadata differs")
        rows = exact_profile_rows(id)
        middle = expected_middle(rows)
        %w[source_direct library_direct].each do |key|
          record = profile.fetch(key)
          require!(record.fetch('source_declaration') == declaration && record.fetch('schema_declaration') == declaration &&
                   record.fetch('row_count') == 8 && record.fetch('mark_row_counts') == ROWS_PER_MARK &&
                   record.fetch('full_rows') == rows && record.fetch('middle_rows') == middle && record.fetch('zero_rows') == [],
            "#{id} #{key}: direct full/middle/zero values, schema, or parent grid differs")
          require!(record.fetch('physical_stream_names').is_a?(Array) &&
                   record.fetch('selected_checksum_names').is_a?(Array) &&
                   record.fetch('logical_read_bytes').is_a?(Integer) && record.fetch('logical_read_bytes') >= 0,
            "#{id} #{key}: direct reader evidence fields malformed")
        end
        %w[source_table library_table].each do |key|
          record = profile.fetch(key)
          require!(record.fetch('full_rows') == rows && record.fetch('middle_rows') == middle &&
                   record.fetch('zero_rows') == [], "#{id} #{key}: public table full/middle/zero values differ")
        end
        require!(profile.fetch('source_direct').fetch('physical_stream_names') ==
                 profile.fetch('library_direct').fetch('physical_stream_names'),
          "#{id}: source/library reader physical names differ")
        expected_json_names = profile.fetch('library_direct').fetch('physical_stream_names')
        require!(expected_json_names.all? { |name| name.start_with?(kind == 'array' ? 'a.' : 'j.') },
          "#{id}: direct reader roster contains a foreign column")
        # The stock source's authored root/Array row literals are separately
        # checked above against W191, not taken from this helper's readback.
        require!(source_profiles.fetch(id).fetch('authored_literal_rows') == expected_authored_literal_rows(id),
          "#{id}: source fixture changed during helper comparison")
      end
    rescue KeyError => error
      raise ProbeError, "Crystal helper output missing #{error.key.inspect}"
    end

    def assert_same_roster!(id, source, library, manifest, source_profiles)
      require!(source.fetch(:logical_substreams).sort == library.fetch(:logical_substreams).sort,
        "#{id}: source/library logical substream rosters differ")
      require!(source.fetch(:hashed_stream_files).sort == library.fetch(:hashed_stream_files).sort,
        "#{id}: source/library hashed physical filenames differ")
      [[:stock, source], [:library, library]].each do |label, inventory|
        require!(inventory.fetch(:mark_triples).keys.sort == inventory.fetch(:logical_substreams).sort,
          "#{id}: #{label} plain-mark roster differs from its logical streams")
        require!(inventory.fetch(:mark_triples).values.all? { |triples| triples.map { |triple| triple[2] } == MARK_ROWS },
          "#{id}: #{label} physical marks differ from the expected outer grid")
      end
      profile = manifest.fetch('profiles').find { |candidate| candidate.fetch('profile_id') == id }
      require!(profile, "#{id}: source lane manifest profile is absent")
      profile.fetch('buckets').each do |bucket|
        bucket.fetch('lanes').each do |lane|
          logical = lane.fetch('logical_stream')
          require!(source.fetch(:logical_substreams).include?(logical) && library.fetch(:logical_substreams).include?(logical),
            "#{id}: advanced lane #{logical} absent from source/library part")
        end
      end
      require!(source_profiles.fetch(id).fetch('part').fetch('physical_file_names').sort == source.fetch(:physical_file_names).sort,
        "#{id}: authenticated source physical file roster changed")
    end

    def expected_checks
      PROFILE_IDS.flat_map { |id| table_names(id) }.to_h { |table| [table, ["all_1_1_0\t1\t"]] }
    end

    def assert_attached_native!(native)
      require!(native.fetch(:checks) == expected_checks, 'stock CHECK TABLE rejected a source/library part')
      expected_schemas = []
      PROFILE_IDS.each do |id|
        column = R191::PROFILE_EXPECTATIONS.fetch(id).fetch(:kind) == 'array' ? 'a' : 'j'
        type = column == 'a' ? ARRAY_JSON : ROOT_JSON
        table_names(id).each do |table|
          expected_schemas << [table, 'pk', 'UInt64']
          expected_schemas << [table, column, type]
        end
      end
      require!(native.fetch(:schemas).sort == expected_schemas.sort, 'attached stock schema roster differs')
      PROFILE_IDS.each do |id|
        rows = exact_profile_rows(id)
        table_names(id).each do |table|
          assert_native_rows!(native.fetch(:rows), table, rows, "#{id} full")
          assert_native_rows!(native.fetch(:middle_rows), table, expected_middle(rows), "#{id} middle")
          require!(native.fetch(:zero_rows).none? { |row| row[0] == table }, "#{id}: zero-row window emitted data")
        end
      end
      assert_native_path_rows!(native)
      expected_parts = PROFILE_IDS.flat_map { |id| table_names(id).map { |table| [table, 'all_1_1_0', 'Wide', '8', '5'] } }.sort
      actual_parts = native.fetch(:parts).map { |table, part| [table, part.fetch(:name), part.fetch(:part_type), part.fetch(:rows), part.fetch(:marks)] }.sort
      require!(actual_parts == expected_parts, 'attached source/library active part roster differs')
    end

    def assert_native_rows!(actual, table, expected, label)
      rows = actual.select { |fields| fields[0] == table }
      decoded = rows.map do |fields|
        value = json_value([fields[3]].pack('H*'), "#{label} #{table} row #{fields[1]}")
        [fields[1].to_i, value]
      end
      expected_rows = expected.each_with_index.map { |value, index| [index + 1 + (label.end_with?('middle') ? 2 : 0), value] }
      require!(decoded == expected_rows, "#{label}: stock rows differ from independently authored literals")
      if table.end_with?('_v2') || table.end_with?('_v3')
        kind = table.include?('array_') ? 'array' : 'root'
        lengths = rows.map { |fields| fields[2] }
        if kind == 'array'
          require!(lengths == expected.map { |value| value.size.to_s }, "#{label}: outer Array lengths differ")
        end
      end
    end

    def assert_native_path_rows!(native)
      path_rows = native.fetch(:path_rows)
      PROFILE_IDS.select { |id| R191::PROFILE_EXPECTATIONS.fetch(id).fetch(:buckets) == 2 }.each do |id|
        kind = R191::PROFILE_EXPECTATIONS.fetch(id).fetch(:kind).to_s
        table_names(id).each do |table|
          %w[alpha aa beta].each do |path|
            selected = path_rows.select { |row| row[0] == table && row[1] == path }
            require!(selected.size == 8, "#{id} #{table}.#{path}: expected one direct path row per parent")
            require!(selected.map { |row| row[2].to_i } == (1..8).to_a,
              "#{id} #{table}.#{path}: direct path projection has duplicate/missing primary keys")
            values = selected.map { |row| json_value([row[3]].pack('H*'), "#{table}.#{path} pk#{row[2]}") }
            expected_values = expected_path_rows(id, kind, path)
            require!(values == expected_values,
              "#{id} #{table}.#{path}: per-parent direct path projection differs from authored literals")
            source_selected = path_rows.select { |row| row[0] == table_names(id).first && row[1] == path }
            library_selected = path_rows.select { |row| row[0] == table_names(id).last && row[1] == path }
            require!(source_selected.map { |row| row[3] } == library_selected.map { |row| row[3] },
              "#{id} #{table}.#{path}: source/library direct path bytes differ")
          end
        end
      end
    end

    def parse_w195_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fields = ->(tag) { lines.map { |line| line.split("\t", -1) if line.start_with?("#{tag}\t") }.compact }
      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W195_CHECK_BEGIN__\t")
          active = line.split("\t", -1)[1]
          raise ProbeError, 'duplicate or nested CHECK output markers' if checks.key?(active)
          checks[active] = []
        elsif line.start_with?("__W195_CHECK_END__\t")
          table = line.split("\t", -1)[1]
          raise ProbeError, 'unbalanced CHECK output markers' unless active == table
          active = nil
        elsif active
          checks.fetch(active) << line
        end
      end
      raise ProbeError, 'unterminated CHECK output marker' if active
      zero_rows = []
      zero_active = nil
      lines.each do |line|
        if line.start_with?("__W195_ZERO_BEGIN__\t")
          raise ProbeError, 'nested zero-window marker' if zero_active
          zero_active = line.split("\t", -1)[1]
        elsif line.start_with?("__W195_ZERO_ROW__\t")
          raise ProbeError, 'zero row outside explicit zero-window markers' unless zero_active
          zero_rows << line.split("\t", -1).drop(1)
        elsif line.start_with?("__W195_ZERO_END__\t")
          table = line.split("\t", -1)[1]
          raise ProbeError, 'unbalanced zero-window marker' unless zero_active == table
          zero_active = nil
        end
      end
      raise ProbeError, 'unterminated zero-window marker' if zero_active
      data_paths = fields.call('__W195_DATA_PATH__').to_h { |f| [f[1], f[2]] }
      parts = fields.call('__W195_PART__').to_h do |f|
        [f[1], {name: f[2], path: f[3], part_type: f[4], rows: f[5], marks: f[6]}]
      end
      {
        pin: lines.find { |line| line.start_with?("__W195_PIN__\t") },
        checks: checks,
        schemas: fields.call('__W195_SCHEMA__').map { |f| f.drop(1) },
        rows: fields.call('__W195_ROW__').map { |f| f.drop(1) },
        middle_rows: fields.call('__W195_MIDDLE_ROW__').map { |f| f.drop(1) },
        zero_rows: zero_rows,
        path_rows: fields.call('__W195_PATH_ROW__').map { |f| f.drop(1) },
        data_paths: data_paths,
        parts: parts,
      }
    end

    def write_summary(data)
      summary = {
        probe: 'W195 paired full-part Object ADVANCED/ADVANCED_CHUNKED qualification',
        status: data[:status], fatal_error: data[:fatal_error],
        runtime: {path: @binary, expected_sha256: BINARY_SHA256,
                  sha256_before: @sha_before, sha256_after: @sha_after,
                  version: VERSION, build: BUILD},
        helper: @helper,
        capture_root: @capture_root,
        manifest_sha256: @manifest_sha256,
        limits: {max_threads: 1, local_max_memory_usage_bytes: MEMORY,
                 required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE,
                 max_profiles: PROFILE_IDS.size, source_revision: R191::SOURCE_REVISION},
        claims: {stock_capture_authenticated_by: 'W191/W193/W194',
                 source_and_library_parts_attached_and_checked: !!data[:attached],
                 direct_dynamic_path_projection: !!data[:attached],
                 general_persisted_format_admission: false},
        invocations: @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      @base.send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      @base.send(:write_new, File.join(@root, 'summary.md'), [
        '# W195 paired full-part Object shared ADVANCED qualification', '',
        "Status: `#{summary[:status]}`", '',
        'This finite W191 corpus pairs eight stock-written Object JSON parts with independently authored Crystal parts under ADVANCED v2 and ADVANCED_CHUNKED v3. It checks direct readers and table batches, attaches both sources to the pinned runtime, runs CHECK TABLE, and compares whole-object plus direct JSON path reads.', '',
        'This is not blanket Object format admission. Native process failures and unsupported direct-path queries remain failures/indeterminate observations, never expected refusals.', '',
        "ClickHouse: #{VERSION} / #{BUILD} / SHA-256 `#{@sha_before}`", '',
        "Source capture: `#{@capture_root}`", '',
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end
  end

  def main
    options = {binary: BINARY, capture_root: '/private/tmp/crystal-click-w191-native-final.BxiDQd'}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/check_object_shared_advanced_parts_w195.rb --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP --crystal-probe PREBUILT_HELPER [--capture-root W191_CAPTURE] [--binary CLICKHOUSE]'
      parser.on('--binary PATH') { |value| options[:binary] = value }
      parser.on('--crystal-probe PATH') { |value| options[:crystal_probe] = value }
      parser.on('--capture-root PATH') { |value| options[:capture_root] = value }
      parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
      parser.on('--self-test') { options[:self_test] = true }
    end.parse!
    if options[:self_test]
      W191::Profiles.each do |profile|
        rows = profile.fetch(:rows)
        raise ProbeError, 'fixture profile must have eight outer rows' unless rows.size == 8
        expected = R191::PROFILE_EXPECTATIONS.fetch(profile.fetch(:id))
        raise ProbeError, 'fixture mode/kind disagreement' unless profile.fetch(:mode) == expected.fetch(:mode) && profile.fetch(:kind).to_s == expected.fetch(:kind)
      end
      raise ProbeError, 'root path oracle lost missing parent rows' unless
        expected_path_rows('root_advanced_v2', 'root', 'alpha') ==
          ['r-alpha-1', nil, nil, 'r-alpha-4', nil, 'r-alpha-6', nil, 'r-alpha-8']
      raise ProbeError, 'Array path oracle lost empty parents or missing per-document values' unless
        expected_path_rows('array_advanced_v2', 'array', 'alpha') ==
          [[], [], [], ['a-alpha-41'], [nil, nil], ['a-alpha-61'], [], []]
      native_row = ->(pk, value) do
        [pk.to_s, value.size.to_s, JSON.generate(value).unpack1('H*')]
      end
      row_probe = Probe.allocate
      W191::Profiles.select { |profile| profile.fetch(:kind) == :array }.each do |profile|
        array_id = profile.fetch(:id)
        array_table = "source_#{array_id}"
        array_rows = exact_profile_rows(array_id)
        full_native_rows = array_rows.each_with_index.map do |value, index|
          [array_table, *native_row.call(index + 1, value)]
        end
        row_probe.send(:assert_native_rows!, full_native_rows, array_table, array_rows, "self-test #{array_id} full")

        middle_rows = expected_middle(array_rows)
        middle_native_rows = middle_rows.each_with_index.map do |value, index|
          [array_table, *native_row.call(index + 3, value)]
        end
        row_probe.send(:assert_native_rows!, middle_native_rows, array_table, middle_rows, "self-test #{array_id} middle")

        [
          [full_native_rows, array_rows, "self-test #{array_id} full"],
          [middle_native_rows, middle_rows, "self-test #{array_id} middle"],
        ].each do |native_rows, expected, label|
          bad_length_rows = native_rows.map(&:dup)
          bad_length_rows[0][2] = (bad_length_rows[0][2].to_i + 1).to_s
          begin
            row_probe.send(:assert_native_rows!, bad_length_rows, array_table, expected, label)
            raise ProbeError, "#{array_id} #{label}: Array length mutation was accepted by native-row assertion"
          rescue ProbeError => error
            raise unless error.message.include?('outer Array lengths differ')
          end
        end
      end
      path_fixture = {'part' => {'part_name' => 'all_1_1_0',
        'part_path' => '/private/tmp/capture/all_1_1_0/'}}
      raise ProbeError, 'W191 trailing-separator path normalization differs' unless
        canonical_source_part_path(path_fixture) == '/private/tmp/capture/all_1_1_0'
      begin
        canonical_source_part_path('part' => {'part_name' => 'all_1_1_0',
          'part_path' => '/private/tmp/capture/../capture/all_1_1_0/'})
        raise ProbeError, 'noncanonical W191 source part path was accepted'
      rescue ProbeError => error
        raise unless error.message.include?('canonical with exactly one trailing separator')
      end
      initial = Probe.allocate.send(:initial_sql)
      raise ProbeError, 'initial SQL omits schema or empty-part observations' unless
        initial.include?("SELECT '__W195_SCHEMA__'") && initial.include?("SELECT '__W195_PART__'")
      attached = Probe.allocate.send(:attached_sql)
      raise ProbeError, 'direct path SQL does not select the String arm of root Dynamic values' unless
        attached.include?("hex(ifNull(toJSONString(dynamicElement(j.alpha, 'String')), 'null'))")
      raise ProbeError, 'direct Array path SQL does not select the String arm while preserving Array offsets' unless
        attached.include?("hex(toJSONString(dynamicElement(a.alpha, 'String')))")
      raise ProbeError, 'direct path SQL lost explicit JSON-null output' unless
        attached.include?("dynamicElement(j.alpha, 'String')") &&
          attached.include?("dynamicElement(a.alpha, 'String')")
      paths = PROFILE_IDS.to_h do |id|
        [id, File.join('/private/tmp/w195-source', id, 'all_1_1_0')]
      end
      libraries = PROFILE_IDS.to_h do |id|
        [id, File.join('/private/tmp/w195-evidence', 'generated', id, 'all_1_1_0')]
      end
      part_probe = PartProbe.allocate
      part_probe.instance_variable_set(:@capture_root, '/private/tmp/w195-source')
      part_probe.instance_variable_set(:@root, '/private/tmp/w195-evidence')
      part_probe.instance_variable_set(:@source_parts, {})
      part_probe.instance_variable_set(:@library_parts, {})
      part_probe.instance_variable_set(:@part_paths_configured, false)
      part_probe.configure_part_paths!(paths, libraries)
      raise ProbeError, 'part allowlists were not retained' unless
        part_probe.instance_variable_get(:@source_parts) == paths &&
          part_probe.instance_variable_get(:@library_parts) == libraries
      begin
        part_probe.configure_part_paths!(paths, libraries)
        raise ProbeError, 'part allowlist reconfiguration was accepted'
      rescue StandardError => error
        raise unless error.message.include?('part allowlists were already configured')
      end
      puts 'W195 self-test: 8 W191 literal profiles and mode/kind controls passed'
      exit 0
    end
    require!(options[:crystal_probe], 'prebuilt Crystal helper required')
    require!(options[:evidence_root], 'fresh evidence root required')
    exit(Probe.new(options[:binary], options[:crystal_probe], options[:evidence_root], options[:capture_root]).run ? 0 : 1)
  rescue StandardError => error
    warn "W195 runner error: #{error.class}: #{error.message}"
    exit 1
  end
end

CheckObjectSharedAdvancedPartsW195.main if $PROGRAM_NAME == __FILE__
