#!/usr/bin/env ruby
# Bounded W264 native interoperability probe. This script consumes a
# prebuilt Crystal helper and a pinned clickhouse-local binary; it does not
# build either executable. The Crystal-generated part and an independently
# INSERTed stock Compact part are both inspected, and every native stage is
# retained separately.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'probe_object_shared_json_interop_w241'

module ProbeCompactPartWriterW264
  W241 = ProbeObjectSharedJSONInteropW241
  FORMAT = 'compact_part_writer_w264_native_probe_v1'.freeze
  HELPER_FORMAT = 'compact_part_writer_w264_helper_v1'.freeze
  HELPER_SOURCE = File.expand_path('compact_part_writer_w264_helper.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('../spec/support/compact_part_writer_w264_fixture.cr', __dir__).freeze
  PART_NAME = 'all_1_1_0'.freeze
  FRAME_BYTES = 32
  ROWS_PER_MARK = 2
  ROW_COUNT = 8
  MARK_ROWS = [2, 2, 2, 2, 0].freeze
  MAX_PART_FILES = 128
  MAX_PART_BYTES = 64 * 1024 * 1024
  MAX_FRAMES = 100_000
  MAX_FRAME_BYTES = 64 * 1024
  SCHEMA = [
    ['pk', 'UInt64'], ['u', 'UInt64'], ['text', 'String'],
    ['maybe', 'Nullable(UInt64)'], ['gap', 'Array(Nullable(UInt64))'],
    ['arr', 'Array(Nullable(UInt64))'],
    ['pair', 'Tuple(String, Nullable(UInt64))'], ['lookup', 'Map(String, UInt64)'],
  ].map(&:freeze).freeze
  VALUE_COLUMNS = SCHEMA.drop(1).map(&:first).freeze
  TAG = {
    path: '__W264_PATH__', schema: '__W264_SCHEMA__', part: '__W264_PART__',
    rows: '__W264_ROWS__', empty: '__W264_EMPTY__',
    check_begin: '__W264_CHECK_BEGIN__', check_end: '__W264_CHECK_END__',
  }.freeze
  NEGATIVE_CASES = %w[stale fold mark].freeze

  # Independent literal oracle. These rows are intentionally not loaded from
  # the Crystal fixture or helper output. String bytes are represented as
  # Ruby strings, including a non-UTF8 payload and an 8 KiB value that forces
  # multiple LZ4 frames within at least one two-row granule.
  ROWS = [
    {pk: 101, u: 0, maybe: nil, text: ''.b, gap: [], arr: [], pair: ['a', 0], map: []},
    {pk: 102, u: 1, maybe: 0, text: 'alpha'.b, gap: [], arr: [nil], pair: ['b', nil], map: [['alpha', 1]]},
    {pk: 103, u: 18_446_744_073_709_551_615, maybe: 1, text: "utf8-λ".b,
     gap: [0, 7], arr: [0, nil, 5], pair: ['c', 3], map: []},
    {pk: 104, u: 42, maybe: nil, text: "contains\0nul".b, gap: [], arr: [], pair: ['', nil],
     map: [['zero', 0], ['max', 99]]},
    {pk: 105, u: 9_007_199_254_740_993, maybe: 50, text: ['00ff8041'].pack('H*'),
     gap: [nil, 9], arr: [50], pair: ['tuple-tail', 9], map: [['one', 7]]},
    {pk: 106, u: 7, maybe: 42, text: ('crystal-' * 1024).b,
     gap: [], arr: [nil, 0], pair: ["λ", 1], map: []},
    {pk: 107, u: 123_456_789, maybe: nil, text: 'tail'.b,
     gap: [42], arr: [42, 42, 42], pair: ["NUL\0key".b, 42], map: [['left', 4], ['right', 9]]},
    {pk: 108, u: 108, maybe: 7, text: 'last'.b, gap: [], arr: [1], pair: ['last', 0], map: [['last', 108]]},
  ].map(&:freeze).freeze

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, helper:, evidence_root:)
      @binary = validate_executable(binary, 'pinned ClickHouse')
      @helper = validate_executable(helper, 'prebuilt W264 helper')
      @root = validate_root(evidence_root)
      @repo = File.realpath(File.expand_path('..', __dir__))
      @source_paths = [__FILE__, HELPER_SOURCE, FIXTURE_SOURCE,
                       File.expand_path('probe_object_shared_json_interop_w241.rb', __dir__)].map do |path|
        File.realpath(path)
      end.uniq.sort
      @runner = W241::Probe.new(@binary, @helper, @root, FRAME_BYTES)
      @invocations = @runner.instance_variable_get(:@invocations)
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @tables = {}
      @case_stages = {}
    end

    def run
      prepare!
      write_generated_part!
      inspect_generated_part!
      run_native_reference!
      compare_native_reference!
      run_generated_positive!
      run_negative_controls!
      stable_sources!
      require_true(binary_sha == W241::BINARY_SHA256, 'pinned ClickHouse hash changed during the probe')
      summary = build_summary('observed')
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      puts "W264 status=stock_compact_reference_and_native_attach_observed; rows=#{ROW_COUNT}; marks=4+EOF; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      begin
        summary = build_summary('inconclusive')
        write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      rescue StandardError => summary_error
        warn "W264 detailed inconclusive summary failed: #{summary_error.class}: #{summary_error.message}"
        begin
          fallback = {
            format: FORMAT, status: 'inconclusive', fatal_error_class: error.class.name,
            summary_persistence_error_class: summary_error.class.name,
          }
          write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(fallback) + "\n")
        rescue StandardError => fallback_error
          warn "W264 minimal inconclusive summary failed: #{fallback_error.class}: #{fallback_error.message}"
        end
      end
      warn "W264 native interoperability probe inconclusive: #{@fatal_error}"
      false
    end

    private

    def require_true(value, message)
      raise Failure, "W264: #{message}" unless value
    end

    def validate_root(path)
      require_true(path && !path.empty?, 'evidence root is required')
      expanded = File.expand_path(path)
      require_true(File.dirname(expanded) == File.realpath('/private/tmp'),
                   'evidence root must be a direct child of /private/tmp')
      require_true(File.directory?(expanded) && !File.symlink?(expanded) &&
                   File.realpath(expanded) == expanded && Dir.children(expanded).empty?,
                   'evidence root must already exist, be canonical, and be empty')
      expanded
    rescue Errno::ENOENT
      raise Failure, 'evidence root must already exist'
    end

    def validate_executable(path, label)
      require_true(path && !path.empty?, "#{label} path is required")
      expanded = File.expand_path(path)
      require_true(File.file?(expanded) && File.executable?(expanded) && !File.symlink?(expanded),
                   "#{label} is absent, non-executable, or symlinked")
      expanded
    end

    def prepare!
      %w[invocations generated parts stores].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      %w[generated native_reference stale fold mark].each do |name|
        Dir.mkdir(File.join(@root, 'parts', name), 0o700)
      end
      %w[generated reference positive stale fold mark].each do |name|
        Dir.mkdir(File.join(@root, 'stores', 'native', name), 0o700)
      end
      @runtime_sha_before = binary_sha
      require_true(@runtime_sha_before == W241::BINARY_SHA256, 'pinned ClickHouse SHA-256 differs before capture')
      @source_sha_before = source_inventory
      @helper_sha_before = sha(@helper)
    end

    def binary_sha
      sha(@binary)
    end

    def sha(path)
      Digest::SHA256.file(path).hexdigest
    end

    def source_inventory
      @source_paths.to_h { |path| [path.delete_prefix(@repo + File::SEPARATOR), sha(path)] }
    end

    def stable_sources!
      require_true(source_inventory == @source_sha_before, 'probe/helper/fixture source changed during capture')
      require_true(sha(@helper) == @helper_sha_before, 'helper executable changed during capture')
      generated_after = tree_inventory(@generated_path)
      require_true(generated_after == @generated_physical.fetch(:files),
                   'generated Compact physical inventory changed after its initial audit')
      reference_after = tree_inventory(@reference_part_path)
      require_true(reference_after == @reference_physical.fetch(:files),
                   'native reference Compact physical inventory changed after its initial audit')
      @source_stability = {
        generated_initial_inventory_matches_final: true,
        native_reference_initial_inventory_matches_final: true,
      }
    end

    def write_new(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    def helper(label, *arguments)
      result = @runner.send(:run_process, label, [@helper] + arguments, ''.b, 'crystal-helper',
                            expected_sha: @helper_sha_before, binary_path: @helper)
      record = result.fetch(:record)
      require_true(!record[:timed_out] && record[:spawn_error].nil? && record[:stdout_read_error].nil? &&
                   record[:stderr_read_error].nil? && result[:status] && result[:status].termsig.nil?,
                   "#{label} helper did not complete as a bounded process")
      require_true(result[:classification] == 'success' && result[:status].success? && result[:stderr].empty?,
                   "#{label} helper returned an application error: #{record.inspect}")
      JSON.parse(result[:stdout].force_encoding(Encoding::UTF_8))
    rescue JSON::ParserError => error
      raise Failure, "#{label} helper output is not JSON: #{error.message}"
    end

    def check_helper_shape!(report, action, status = 'ok')
      require_true(report.is_a?(Hash) && report['format'] == HELPER_FORMAT &&
                   report['action'] == action && report['status'] == status,
                   "helper #{action} response differs")
    end

    def write_generated_part!
      @generated_path = File.join(@root, 'generated', PART_NAME)
      report = helper('helper_write', 'write', @generated_path)
      check_helper_shape!(report, 'write')
      @generated_report = report
      validate_helper_report!(report, 'Crystal-generated part')
    end

    def inspect_generated_part!
      @generated_audit = helper('helper_audit_generated', 'audit', @generated_path)
      check_helper_shape!(@generated_audit, 'audit')
      @generated_physical = inspect_physical!(@generated_path, 'Crystal-generated part')
      validate_audit!( @generated_audit, 'Crystal-generated part', require_valid_fold: true)
    end

    def create_sql(table)
      declarations = SCHEMA.map { |name, type| "`#{name}` #{type}" }.join(', ')
      settings = [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        # A single small insert is deliberately Compact, while its long row
        # still exceeds one native 4096-byte compression block.
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=104857600', 'min_level_for_wide_part=0',
        'compress_marks=0', 'compress_primary_key=0', 'write_marks_for_substreams_in_compact_parts=0',
        'min_compress_block_size=0',
        'max_compress_block_size=4096', 'ratio_of_defaults_for_sparse_serialization=1.0',
        "default_compression_codec='LZ4'", "serialization_info_version='with_types'",
        'propagate_types_serialization_versions_to_nested_types=true',
        "string_serialization_version='single_stream'", "nullable_serialization_version='basic'",
        "map_serialization_version='basic'",
        "map_serialization_version_for_zero_level_parts='basic'",
      ].join(', ')
      "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};\n"
    end

    def reference_insert_sql(table)
      rows = ROWS.map do |row|
        values = [
          row.fetch(:pk).to_s,
          "toUInt64(#{row.fetch(:u)})",
          sql_bytes(row.fetch(:text)),
          sql_nullable_u64(row.fetch(:maybe)),
          sql_array(row.fetch(:gap)),
          sql_array(row.fetch(:arr)),
          "tuple(#{sql_bytes(row.fetch(:pair)[0])}, #{sql_nullable_u64(row.fetch(:pair)[1])})",
          sql_map(row.fetch(:map)),
        ]
        "(#{values.join(', ')})"
      end
      "INSERT INTO default.#{table} VALUES\n#{rows.join(",\n")} ;\n"
    end

    def sql_bytes(value)
      "unhex('#{value.b.unpack1('H*')}')"
    end

    def sql_nullable_u64(value)
      value.nil? ? "CAST(NULL, 'Nullable(UInt64)')" : "toUInt64(#{value})"
    end

    def sql_array(values)
      return "CAST([], 'Array(Nullable(UInt64))')" if values.empty?
      "[#{values.map { |value| sql_nullable_u64(value) }.join(', ')}]"
    end

    def sql_map(entries)
      return "CAST([], 'Map(String, UInt64)')" if entries.empty?
      "map(#{entries.flat_map { |key, value| [sql_bytes(key.b), "toUInt64(#{value})"] }.join(', ')})"
    end

    def run_native_reference!
      create_reference!
    end

    def compare_native_reference!
      require_true(@reference_physical.fetch(:mark_rows) == MARK_ROWS, 'stock-native mark grid differs')
      require_true(@generated_physical.fetch(:mark_rows) == MARK_ROWS, 'Crystal writer mark grid differs')
      require_true(@generated_physical.fetch(:multi_frame_granules).any? &&
                   @reference_physical.fetch(:multi_frame_granules).any?,
                   'one or both writers did not produce a granule spanning multiple native LZ4 frames')
      require_true(@generated_audit.fetch('data_bin_raw_size') == @reference_audit.fetch('data_bin_raw_size'),
                   'decompressed Compact data.bin tape size differs from independent stock writer')
      require_true(@generated_audit.fetch('data_bin_raw_sha256') == @reference_audit.fetch('data_bin_raw_sha256'),
                   'decompressed Compact data.bin tape SHA differs from independent stock writer')
      require_true(@generated_audit.fetch('data_bin_saved_uncompressed_hash_words') ==
                   @reference_audit.fetch('data_bin_saved_uncompressed_hash_words'),
                   'saved Compact uncompressed-fold words differ from independent stock writer')
      require_true(@generated_audit.fetch('data_bin_saved_uncompressed_hash_words') ==
                   @generated_audit.fetch('data_bin_computed_uncompressed_hash_words'),
                   'Crystal writer data.bin checksum does not equal its computed upstream fold')
      require_true(@reference_audit.fetch('data_bin_saved_uncompressed_hash_words') ==
                   @reference_audit.fetch('data_bin_computed_uncompressed_hash_words'),
                   'native writer data.bin checksum does not equal its computed upstream fold')
      generated_signatures = @generated_report.fetch('columns').map { |column| [column.fetch('name'), column.fetch('signatures')] }
      native_signatures = @reference_report.fetch('columns').map { |column| [column.fetch('name'), column.fetch('signatures')] }
      require_true(generated_signatures == native_signatures,
                   'Crystal typed scan of the native-written part differs from Crystal writer control')
    end

    def run_generated_positive!
      create_target_table!('positive')
      attach_part!(@generated_path, store_path('positive'), @positive_data_path, 'positive')
      @positive_stages = observe_attached_part!('positive', @positive_table, store_path('positive'),
                                                require_values: true, selected_window: 'positive')
      require_true(@positive_stages[:attach_state] == 'attached' &&
                   @positive_stages[:check_state] == 'success' &&
                   @positive_stages[:check_pass] == true &&
                   @positive_stages.dig(:select, :state) == 'exact_values',
                   'native generated-part ATTACH/CHECK/value-read positive did not complete exactly')
    end

    def create_target_table!(case_name)
      table = table_name(case_name)
      @tables[case_name] = table
      store = store_path(case_name)
      result = native("native_#{case_name}_create", store,
                      create_sql(table) + schema_query(table, case_name) + path_query(table, case_name))
      assert_native_success!(result, "#{case_name} target table create")
      @case_stages[case_name] ||= {}
      @case_stages[case_name][:create] = result[:record]
      lines = native_lines(result[:stdout], "#{case_name} table path")
      observed_schema = tagged(lines, tag(:schema, case_name), 3).map { |row| row.drop(1) }
      require_true(observed_schema == SCHEMA, "#{case_name} target schema/type/order differs")
      paths = tagged(lines, tag(:path, case_name), 2)
      require_true(paths.size == 1 && paths.first[1] && !paths.first[1].empty?,
                   "#{case_name} table data path is not unique")
      data_path = validate_store_path!(paths.first[1])
      if case_name == 'positive'
        @positive_table = table
        @positive_data_path = data_path
      end
      data_path
    end

    def attach_part!(part, store, data_path, case_name)
      @runner.send(:attach_part!, part, data_path)
      source_files = tree_inventory(part)
      detached_files = tree_inventory(File.join(data_path, 'detached', PART_NAME))
      require_true(source_files == detached_files, "#{case_name} detached Compact copy differs from its immutable source")
      @case_stages[case_name] ||= {}
      @case_stages[case_name][:attach_copy_sha256] = source_files
      @case_stages[case_name][:detached_copy_sha256] = detached_files
    end

    def observe_attached_part!(case_name, table, store, require_values:, selected_window: nil)
      result = native("native_#{case_name}_attach", store, "ALTER TABLE default.#{table} ATTACH PART '#{PART_NAME}';\n")
      @case_stages[case_name] ||= {}
      @case_stages[case_name][:attach] = result[:record]
      state = process_state!(result, "#{case_name} ATTACH")
      if require_values
        require_true(state == 'success', 'native generated-part ATTACH was refused')
      end
      return {attach_state: state, check: 'not_run_attach_refusal', select: 'not_run_attach_refusal'} unless state == 'success'

      result = native("native_#{case_name}_active_part", store, part_query(table, case_name))
      @case_stages[case_name][:active_part] = result[:record]
      assert_native_success!(result, "#{case_name} active part query")
      lines = native_lines(result[:stdout], "#{case_name} active part query")
      parts = tagged(lines, tag(:part, case_name), 7)
      unless parts.size == 1 && parts.first.values_at(1, 2, 4, 5, 6) ==
             [table, PART_NAME, 'Compact', ROW_COUNT.to_s, '5']
        observed = {attach_state: 'command_succeeded_but_active_part_absent_or_different',
                    check: 'not_run_no_attached_part', select: 'not_run_no_attached_part', active_rows: parts}
        if require_values
          raise Failure, 'native generated-part ATTACH did not create exactly the expected active Compact part'
        end
        return observed
      end

      active_path = validate_store_path!(parts.first[3])
      active_inventory = tree_inventory(active_path)
      attached_copy_inventory = @case_stages[case_name][:attach_copy_sha256]
      @case_stages[case_name][:active_file_inventory_sha256] = active_inventory
      @case_stages[case_name][:post_attach_inventory_matches_detached_copy] =
        active_inventory == attached_copy_inventory
      @case_stages[case_name][:post_attach_inventory_added_files] =
        (active_inventory.keys - attached_copy_inventory.keys).sort
      @case_stages[case_name][:post_attach_inventory_removed_files] =
        (attached_copy_inventory.keys - active_inventory.keys).sort
      @case_stages[case_name][:post_attach_inventory_changed_files] =
        (active_inventory.keys & attached_copy_inventory.keys).select do |name|
          active_inventory[name] != attached_copy_inventory[name]
        end.sort
      payload_files = %w[data.bin data.mrk3]
      payload_matches = payload_files.all? do |name|
        active_inventory[name] && attached_copy_inventory[name] && active_inventory[name] == attached_copy_inventory[name]
      end
      @case_stages[case_name][:post_attach_payload_matches_detached_copy] = payload_matches
      if require_values
        require_true(payload_matches,
                     'native ATTACH changed generated data.bin or data.mrk3 payload bytes')
      end

      result = native("native_#{case_name}_check", store, check_sql(table, case_name))
      @case_stages[case_name][:check] = result[:record]
      check_state = process_state!(result, "#{case_name} CHECK")
      observed_check_rows = check_state == 'success' ? check_rows(result[:stdout], case_name) : nil
      check_pass = observed_check_rows == ["#{PART_NAME}\t1\t"]

      read = nil
      if check_pass || check_state != 'success'
        result = native("native_#{case_name}_select", store,
                        rows_query(table, case_name, 'full') + rows_query(table, case_name, 'middle') +
                        rows_query(table, case_name, 'last') + empty_query(table, case_name))
        @case_stages[case_name][:select] = result[:record]
        select_state = process_state!(result, "#{case_name} affected-row SELECT")
        if select_state == 'success'
          lines = native_lines(result[:stdout], "#{case_name} affected-row SELECT")
          full = parse_native_rows(tagged(lines, tag(:rows, case_name, 'full'), 10), "#{case_name} full SELECT")
          middle = parse_native_rows(tagged(lines, tag(:rows, case_name, 'middle'), 10), "#{case_name} middle SELECT")
          last = parse_native_rows(tagged(lines, tag(:rows, case_name, 'last'), 10), "#{case_name} last SELECT")
          empty = tagged(lines, tag(:empty, case_name), 2)
          read = {
            state: [full, middle, last] == [expected_native_rows, expected_native_rows[2, 4], expected_native_rows.last(1)] &&
                   empty == [[tag(:empty, case_name), '0']] ? 'exact_values' : 'value_mismatch',
            full_rows: full.size, middle_rows: middle.size, last_rows: last.size, empty_rows: empty,
          }
        else
          read = {state: 'server_refusal', process_classification: result[:classification],
                  exit: result[:status]&.exitstatus}
        end
      else
        read = {state: 'not_run_check_refusal'}
      end
      @case_stages[case_name][:check_pass] = check_pass
      @case_stages[case_name][:check_rows] = observed_check_rows
      @case_stages[case_name][:read_observation] = read
      if require_values
        require_true(check_state == 'success' && check_pass, 'native CHECK on generated Compact part did not pass')
        require_true(read && read[:state] == 'exact_values', 'native full/window/last/empty values differ')
      end
      {attach_state: 'attached', check_state: check_state, check_pass: check_pass, select: read}
    end

    def run_negative_controls!
      run_control('stale', 'stale-copy')
      run_control('fold', 'fold-copy')
      run_control('mark', 'mark-copy')
    end

    def run_control(case_name, action)
      mutant_path = File.join(@root, 'parts', case_name, PART_NAME)
      control = helper("helper_#{case_name}_copy", action, @generated_path, mutant_path)
      check_helper_shape!(control, action)
      baseline_files = normalize_files(@generated_audit.fetch('files'))
      mutant_files = normalize_files(control.fetch('files'))
      audit = helper("helper_audit_#{case_name}", 'audit', mutant_path)
      check_helper_shape!(audit, 'audit')
      validate_mutation_inventory!(case_name, baseline_files, mutant_files, @generated_audit, audit)
      @case_stages[case_name] ||= {}
      @case_stages[case_name][:source_files] = baseline_files
      @case_stages[case_name][:mutant_files] = mutant_files
      @case_stages[case_name][:audit] = audit
      if case_name == 'mark'
        public_result = helper("helper_mark_public_reader", 'inspect-outcome', mutant_path)
        check_helper_shape!(public_result, 'inspect-outcome', 'rejected')
        require_true(public_result['error_class'].to_s.include?('CorruptPartError'),
                     'resealed malformed mark was not rejected by the public Compact reader')
        @case_stages[case_name] ||= {}
        @case_stages[case_name][:public_reader] = {
          status: public_result.fetch('status'), error_class: public_result.fetch('error_class'),
          error_message: public_result.fetch('error_message'),
        }
      end

      store = store_path(case_name)
      data_path = create_target_table!(case_name)
      attach_part!(mutant_path, store, data_path, case_name)
      observed = observe_attached_part!(case_name, @tables.fetch(case_name), store, require_values: false)
      @case_stages[case_name][:native_observation] = observed
      if case_name == 'fold'
        require_true(observed[:attach_state] == 'attached' && observed[:check_pass] == true &&
                     observed[:select] && observed[:select][:state] == 'exact_values',
                     'native Compact checker/read unexpectedly noticed the checksum-fold-only mutation')
      else
        outcome = observed[:attach_state] != 'attached' || observed[:check_pass] == false ||
                  (observed[:select] && %w[server_refusal value_mismatch].include?(observed[:select][:state]))
        require_true(outcome, "native #{case_name} control reached exact values despite its intended corruption")
      end
    end

    def validate_mutation_inventory!(case_name, baseline_files, mutant_files, base_audit, mutant_audit)
      names = (baseline_files.keys | mutant_files.keys).sort
      require_true(names == baseline_files.keys.sort && names == mutant_files.keys.sort,
                   "#{case_name} mutation changed the part file roster")
      changed = names.select { |name| baseline_files[name] != mutant_files[name] }.sort
      checksums = 'checksums.txt'
      case case_name
      when 'stale'
        require_true(changed == ['data.bin'], 'stale control changed anything besides data.bin')
        require_true(base_audit.fetch('checksum_entries') == mutant_audit.fetch('checksum_entries'),
                     'stale control changed saved checksums instead of leaving them stale')
      when 'fold'
        require_true(changed == [checksums], 'fold-only control changed physical data or marks')
        before = checksum_entry(base_audit, 'data.bin')
        after = checksum_entry(mutant_audit, 'data.bin')
        expected_words = before.fetch('uncompressed_hash_words').dup
        expected_words[0] = (Integer(expected_words[0], 10) ^ 1).to_s
        require_true(after.fetch('uncompressed_hash_words') == expected_words,
                     'fold-only control did not flip exactly the low saved uncompressed-hash word')
        require_true(before.reject { |key, _| key == 'uncompressed_hash_words' } ==
                     after.reject { |key, _| key == 'uncompressed_hash_words' },
                     'fold-only control changed another data.bin checksum field')
        require_true(base_audit.fetch('data_bin_raw_sha256') == mutant_audit.fetch('data_bin_raw_sha256') &&
                     base_audit.fetch('data_bin_computed_uncompressed_hash_words') ==
                     mutant_audit.fetch('data_bin_computed_uncompressed_hash_words'),
                     'fold-only control changed decompressed data.bin bytes')
        require_true(mutant_audit.fetch('data_bin_saved_uncompressed_hash_words') == expected_words &&
                     mutant_audit.fetch('data_bin_saved_uncompressed_hash_words') !=
                     mutant_audit.fetch('data_bin_computed_uncompressed_hash_words'),
                     'fold-only control is not distinct from the actual computed fold')
      when 'mark'
        require_true(changed.sort == %w[checksums.txt data.mrk3],
                     'resealed mark control changed files outside data.mrk3 and checksums.txt')
        require_true(base_audit.fetch('data_bin_raw_sha256') == mutant_audit.fetch('data_bin_raw_sha256') &&
                     base_audit.fetch('data_bin_computed_uncompressed_hash_words') ==
                     mutant_audit.fetch('data_bin_computed_uncompressed_hash_words'),
                     'resealed mark control changed data.bin')
        before = checksum_entry(base_audit, 'data.mrk3')
        after = checksum_entry(mutant_audit, 'data.mrk3')
        require_true(before.fetch('physical_size') == after.fetch('physical_size') &&
                     before.fetch('compressed') == after.fetch('compressed') &&
                     before.fetch('uncompressed_size') == after.fetch('uncompressed_size') &&
                     before.fetch('file_hash_words') != after.fetch('file_hash_words'),
                     'resealed malformed-mark control did not update only the mark file checksum')
      else
        raise Failure, "unrostered mutation #{case_name}"
      end
    end

    def checksum_entry(audit, name)
      entries = audit.fetch('checksum_entries')
      entry = entries.find { |candidate| candidate.fetch('name') == name }
      require_true(entry.is_a?(Hash), "#{name} checksum entry is absent")
      entry
    end

    def validate_audit!(audit, label, require_valid_fold:)
      require_true(audit.fetch('format') == HELPER_FORMAT && audit.fetch('action') == 'audit' &&
                   audit.fetch('status') == 'ok', "#{label} raw audit header differs")
      data_entry = checksum_entry(audit, 'data.bin')
      require_true(data_entry.fetch('compressed') == true &&
                   data_entry.fetch('physical_size') == audit.fetch('data_bin_physical_size'),
                   "#{label} data.bin checksum record differs from physical data.bin")
      if require_valid_fold
        require_true(audit.fetch('data_bin_raw_decode_error').nil? &&
                     audit.fetch('data_bin_raw_size') == data_entry.fetch('uncompressed_size') &&
                     audit.fetch('data_bin_saved_uncompressed_hash_words') ==
                     audit.fetch('data_bin_computed_uncompressed_hash_words'),
                     "#{label} saved uncompressed fold does not match decoded data.bin")
      end
    end

    def validate_helper_report!(report, label)
      require_true(report.fetch('format') == HELPER_FORMAT && report.fetch('status') == 'ok',
                   "#{label} helper report header differs")
      require_true(report.fetch('mode') == 'mrk3' && report.fetch('row_count') == ROW_COUNT &&
                   report.fetch('real_marks') == 4 && report.fetch('keys') == ROWS.map { |row| row.fetch(:pk) },
                   "#{label} mode, key, row, or granule roster differs")
      columns = report.fetch('columns')
      require_true(columns.map { |entry| [entry.fetch('name'), entry.fetch('type')] } == SCHEMA.drop(1),
                   "#{label} column types/order differ from independent literal schema")
      require_true(columns.all? { |entry| entry.fetch('mark_rows') == MARK_ROWS.take(4) },
                   "#{label} value-column mark rows differ")
      expected_values = expected_signatures_from_report(@generated_report || report)
      observed_values = expected_signatures_from_report(report)
      require_true(observed_values == expected_values, "#{label} typed value signatures differ")
      require_true(report.fetch('physical_roster').map { |slot| slot.fetch('column') } == SCHEMA.map(&:first),
                   "#{label} physical column roster/order differs")
    end

    def expected_signatures_from_report(report)
      report.fetch('columns').map { |entry| [entry.fetch('name'), entry.fetch('type'), entry.fetch('signatures')] }
    end

    def inspect_physical!(path, label)
      files = tree_inventory(path)
      require_true(files.size <= MAX_PART_FILES, "#{label} part has too many files")
      require_true(files.values.sum { |entry| entry.fetch(:size) } <= MAX_PART_BYTES,
                   "#{label} part exceeds the physical byte bound")
      names = files.keys
      require_true(names.include?('data.bin') && names.include?('data.mrk3') && names.include?('checksums.txt') &&
                   names.include?('columns.txt') && names.include?('count.txt'),
                   "#{label} Compact physical files are incomplete")
      require_true(names.none? { |name| name.match?(/\.mrk2\z|\.mrk4\z|\.cmrk\z/) },
                   "#{label} is not a plain MRK3 part")
      require_true(names.grep(/\.bin\z/) == ['data.bin'], "#{label} contains per-column Wide binary files")
      expected_columns = "columns format version: 1\n#{SCHEMA.size} columns:\n" +
                         SCHEMA.map { |name, type| "`#{name}` #{type}\n" }.join
      require_true(File.binread(File.join(path, 'columns.txt')) == expected_columns,
                   "#{label} columns.txt differs from the literal schema")
      require_true(File.binread(File.join(path, 'count.txt')).strip == ROW_COUNT.to_s,
                   "#{label} count.txt differs from the literal row count")
      codec = File.join(path, 'default_compression_codec.txt')
      require_true(File.binread(codec).strip == 'CODEC(LZ4)', "#{label} default codec is not LZ4") if File.file?(codec)

      data = File.binread(File.join(path, 'data.bin'))
      frames = parse_frames!(data, label)
      marks = File.binread(File.join(path, 'data.mrk3'))
      width = SCHEMA.size * 16 + 8
      require_true(marks.bytesize == width * MARK_ROWS.size, "#{label} MRK3 record width/count differs")
      frame_by_offset = frames.to_h { |frame| [frame.fetch(:compressed_start), frame] }
      logical_positions = []
      mark_rows = []
      MARK_ROWS.each_with_index do |row_count, mark_index|
        record = marks.byteslice(mark_index * width, width)
        row_count_observed = record.byteslice(SCHEMA.size * 16, 8).unpack1('Q<')
        require_true(row_count_observed == row_count, "#{label} mark #{mark_index} row count differs")
        slots = SCHEMA.size.times.map do |slot_index|
          compressed_offset, decompressed_offset = record.byteslice(slot_index * 16, 16).unpack('Q<2')
          if mark_index == MARK_ROWS.size - 1
            require_true([compressed_offset, decompressed_offset] == [data.bytesize, 0],
                         "#{label} terminal slot #{slot_index} is not (data.bin EOF,0)")
          else
            frame = frame_by_offset[compressed_offset]
            require_true(frame && decompressed_offset <= frame.fetch(:decompressed_size),
                         "#{label} mark #{mark_index} slot #{slot_index} is outside an LZ4 frame")
          end
          [compressed_offset, decompressed_offset]
        end
        logical_positions << slots.map do |compressed_offset, decompressed_offset|
          if compressed_offset == data.bytesize
            frames.last.fetch(:logical_end)
          else
            frame = frame_by_offset.fetch(compressed_offset)
            frame.fetch(:logical_start) + decompressed_offset
          end
        end
        mark_rows << row_count_observed
      end
      require_true((1..4).all? { |mark_index| logical_positions[mark_index].first >= logical_positions[mark_index - 1].first },
                   "#{label} primary-key slot positions are not monotone")
      multi_frame = (0...4).map do |mark_index|
        start_at = logical_positions[mark_index].first
        finish_at = logical_positions[mark_index + 1].first
        covered = frames.select do |frame|
          frame.fetch(:logical_start) < finish_at && frame.fetch(:logical_end) > start_at
        end
        covered.size
      end
      {
        files: files, frame_count: frames.size, frames: frames, mark_rows: mark_rows,
        data_bin_bytes: data.bytesize, data_mrk3_bytes: marks.bytesize,
        frames_per_granule: multi_frame, multi_frame_granules: multi_frame.each_index.select { |index| multi_frame[index] > 1 },
      }
    end

    def parse_frames!(data, label)
      require_true(!data.empty?, "#{label} data.bin is empty")
      offset = 0
      logical = 0
      frames = []
      while offset < data.bytesize
        require_true(frames.size < MAX_FRAMES, "#{label} data.bin frame limit exceeded")
        require_true(data.bytesize - offset >= 25, "#{label} LZ4 header is truncated at #{offset}")
        method = data.getbyte(offset + 16)
        compressed_size = data.byteslice(offset + 17, 4).unpack1('V')
        raw_size = data.byteslice(offset + 21, 4).unpack1('V')
        require_true(method == 0x82, "#{label} frame #{offset} is not LZ4")
        require_true(compressed_size >= 9 && raw_size.positive? && raw_size <= MAX_FRAME_BYTES,
                     "#{label} frame at #{offset} has an invalid bounded size")
        finish = offset + 16 + compressed_size
        require_true(finish <= data.bytesize, "#{label} frame at #{offset} exceeds data.bin")
        frames << {compressed_start: offset, compressed_end: finish,
                   logical_start: logical, logical_end: logical + raw_size,
                   decompressed_size: raw_size, compressed_size: compressed_size}
        offset = finish
        logical += raw_size
      end
      require_true(offset == data.bytesize && frames.any?, "#{label} LZ4 frame walk did not end exactly at EOF")
      frames
    end

    def validate_store_path!(path)
      expanded = File.expand_path(path)
      native_root = File.join(@root, 'stores', 'native')
      require_true(expanded.start_with?(native_root + File::SEPARATOR), "native table path escaped isolated stores: #{path}")
      current = native_root
      expanded.delete_prefix(native_root + File::SEPARATOR).split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        next unless File.exist?(current) || File.symlink?(current)
        require_true(!File.lstat(current).symlink?, "native store path contains symlink #{current}")
      end
      expanded
    end

    def tree_inventory(path)
      require_true(File.directory?(path) && !File.symlink?(path), "part directory is missing or symlinked: #{path}")
      entries = {}
      total = 0
      Find.find(path) do |item|
        next if item == path
        stat = File.lstat(item)
        require_true(!stat.symlink? && (stat.directory? || stat.file?), "part has a symlink or special entry: #{item}")
        next if stat.directory?
        relative = item.delete_prefix(path + File::SEPARATOR)
        total += stat.size
        require_true(entries.size < MAX_PART_FILES && total <= MAX_PART_BYTES, 'part inventory exceeds its bound')
        entries[relative] = {size: stat.size, sha256: sha(item)}
      end
      entries
    end

    def normalize_files(entries)
      require_true(entries.is_a?(Array), 'helper file inventory is not an array')
      entries.to_h do |entry|
        name = entry.fetch('path')
        require_true(name.is_a?(String) && File.basename(name) == name && name.match?(/\A[a-zA-Z0-9_.-]+\z/),
                     'helper reported an unsafe part file name')
        [name, {size: entry.fetch('size'), sha256: entry.fetch('sha256')}]
      end
    end

    def native(label, store, sql)
      pinned_sql = [@runner.send(:pin_sql), sql].join("\n")
      @runner.send(:native, label, store, pinned_sql)
    end

    def assert_native_success!(result, label)
      @runner.send(:assert_native_success!, result, label)
      @runner.send(:assert_pin!, result.fetch(:stdout), label)
    end

    def process_state!(result, label)
      record = result.fetch(:record)
      require_true(!record[:timed_out] && record[:spawn_error].nil? && record[:stdout_read_error].nil? &&
                   record[:stderr_read_error].nil? && result[:status] && result[:status].termsig.nil?,
                   "#{label} did not complete as a bounded native process")
      state = result.fetch(:classification)
      require_true(%w[success server_exception].include?(state), "#{label} ended in infrastructure failure: #{record.inspect}")
      if state == 'success'
        @runner.send(:assert_native_success!, result, label)
        @runner.send(:assert_pin!, result.fetch(:stdout), label)
      end
      state
    end

    def native_lines(stdout, label)
      text = stdout.dup.force_encoding(Encoding::UTF_8)
      require_true(text.valid_encoding? && text.end_with?("\n"), "#{label} stdout is not UTF-8/newline terminated")
      lines = text.lines.map(&:chomp)
      pins = lines.select { |line| line.start_with?("__W241_PIN__\t") }
      require_true(pins == ["__W241_PIN__\t#{W241::VERSION}\t#{W241::BUILD}"], "#{label} runtime pin differs")
      lines
    end

    def tag(kind, case_name, window = nil)
      suffix = window ? "_#{window.upcase}" : ''
      "__W264_#{kind.to_s.upcase}_#{case_name.upcase}#{suffix}__"
    end

    def tagged(lines, expected_tag, width)
      lines.select { |line| line.start_with?(expected_tag + "\t") }.map do |line|
        fields = line.split("\t", -1)
        require_true(fields.size == width, "malformed #{expected_tag} TSV row")
        fields
      end
    end

    def table_name(case_name)
      "w264_#{@token}_#{case_name}"
    end

    def store_path(case_name)
      File.join(@root, 'stores', 'native', case_name)
    end

    def path_query(table, case_name)
      "SELECT '#{tag(:path, case_name)}', arrayElement(data_paths, 1) FROM system.tables " \
        "WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
    end

    def schema_query(table, case_name)
      "SELECT '#{tag(:schema, case_name)}', name, type FROM system.columns " \
        "WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n"
    end

    def part_query(table, case_name)
      "SELECT '#{tag(:part, case_name)}', table, name, path, part_type, toString(rows), toString(marks) " \
        "FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;\n"
    end

    def check_sql(table, case_name)
      "SELECT '#{tag(:check_begin, case_name)}' FORMAT TSVRaw;\n" \
        "CHECK TABLE default.#{table} FORMAT TSV;\n" \
        "SELECT '#{tag(:check_end, case_name)}' FORMAT TSVRaw;\n"
    end

    def check_rows(stdout, case_name)
      lines = native_lines(stdout, "#{case_name} CHECK")
      active = false
      rows = []
      lines.each do |line|
        if line == tag(:check_begin, case_name)
          require_true(!active, 'nested CHECK marker')
          active = true
        elsif line == tag(:check_end, case_name)
          require_true(active, 'CHECK end marker without begin')
          active = false
        elsif active
          rows << line
        end
      end
      require_true(!active, 'unterminated CHECK marker')
      rows
    end

    def rows_query(table, case_name, window)
      predicate = case window
                  when 'full' then ''
                  when 'middle' then ' WHERE pk BETWEEN 103 AND 106'
                  when 'last' then ' WHERE pk = 108'
                  else raise Failure, "unknown row window #{window}"
                  end
      expressions = [
        'toString(pk)', 'toString(u)', 'hex(text)',
        "if(isNull(maybe), 'NULL', toString(maybe))", 'hex(toJSONString(gap))',
        'hex(toJSONString(arr))',
        'hex(toJSONString(pair))', 'hex(toJSONString(mapKeys(lookup)))',
        'hex(toJSONString(mapValues(lookup)))',
      ]
      "SELECT '#{tag(:rows, case_name, window)}', #{expressions.join(', ')} FROM default.#{table}#{predicate} " \
        "ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def empty_query(table, case_name)
      "SELECT '#{tag(:empty, case_name)}', toString(count()) FROM default.#{table} WHERE pk > 108 " \
        "SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def parse_native_rows(rows, label)
      expected_width = 10
      rows.map do |fields|
        require_true(fields.size == expected_width, "#{label} row width differs")
        {
          pk: Integer(fields[1], 10), u: Integer(fields[2], 10),
          text_hex: fields[3].downcase,
          maybe: fields[4] == 'NULL' ? nil : Integer(fields[4], 10),
          gap: parse_json_hex(fields[5], "#{label} empty-child Array"),
          arr: parse_json_hex(fields[6], "#{label} Array"),
          pair: parse_json_hex(fields[7], "#{label} Tuple"),
          map_keys: parse_json_hex(fields[8], "#{label} Map keys"),
          map_values: parse_json_hex(fields[9], "#{label} Map values"),
        }
      end
    end

    def parse_json_hex(value, label)
      require_true(value.match?(/\A(?:[0-9a-fA-F]{2})*\z/), "#{label} is not even-length hex")
      JSON.parse([value].pack('H*').force_encoding(Encoding::UTF_8))
    rescue JSON::ParserError => error
      raise Failure, "#{label} is not JSON: #{error.message}"
    end

    def expected_native_rows
      ROWS.map do |row|
        {
          pk: row.fetch(:pk), u: row.fetch(:u), text_hex: row.fetch(:text).b.unpack1('H*'),
          maybe: row.fetch(:maybe), gap: row.fetch(:gap), arr: row.fetch(:arr), pair: row.fetch(:pair),
          map_keys: row.fetch(:map).map(&:first), map_values: row.fetch(:map).map(&:last),
        }
      end
    end

    def require_native_rows!(observed, label)
      require_true(observed == expected_native_rows, "#{label} rows differ from independently authored literals")
    end

    def create_reference!
      table = table_name('reference')
      store = store_path('reference')
      @reference_table = table
      write = native('native_reference_write', store, create_sql(table) + reference_insert_sql(table))
      assert_native_success!(write, 'native reference table create/insert')
      @reference_write = write[:record]
      check = native('native_reference_check', store, check_sql(table, 'reference'))
      check_state = process_state!(check, 'native reference CHECK')
      require_true(check_state == 'success', 'native reference CHECK ended in an application-level refusal')
      @reference_check_rows = check_rows(check[:stdout], 'reference')
      require_true(@reference_check_rows == ["#{PART_NAME}\t1\t"],
                   'native reference CHECK is not exactly CHECK=1')
      @reference_check = check[:record]

      observe = native('native_reference_observe', store,
                       schema_query(table, 'reference') + part_query(table, 'reference') +
                       rows_query(table, 'reference', 'full') + rows_query(table, 'reference', 'middle') +
                       rows_query(table, 'reference', 'last') + empty_query(table, 'reference'))
      assert_native_success!(observe, 'native reference schema/part/value read')
      @reference_observation = observe[:record]
      lines = native_lines(observe[:stdout], 'native reference observation')
      @reference_schema = tagged(lines, tag(:schema, 'reference'), 3).map { |row| row.drop(1) }
      require_true(@reference_schema == SCHEMA, 'native reference schema/type/order differs')
      parts = tagged(lines, tag(:part, 'reference'), 7)
      require_true(parts.size == 1 && parts.first.values_at(1, 2, 4, 5, 6) ==
                   [table, PART_NAME, 'Compact', ROW_COUNT.to_s, '5'],
                   'stock reference is not one Compact part with four real marks plus EOF')
      @reference_part_row = parts.first
      @reference_part_path = validate_store_path!(parts.first[3])
      @reference_rows = parse_native_rows(tagged(lines, tag(:rows, 'reference', 'full'), 10), 'native reference full')
      @reference_middle = parse_native_rows(tagged(lines, tag(:rows, 'reference', 'middle'), 10), 'native reference middle')
      @reference_last = parse_native_rows(tagged(lines, tag(:rows, 'reference', 'last'), 10), 'native reference last')
      @reference_empty = tagged(lines, tag(:empty, 'reference'), 2)
      require_native_rows!(@reference_rows, 'stock-native reference full read')
      require_true(@reference_middle == expected_native_rows[2, 4] && @reference_last == expected_native_rows.last(1) &&
                   @reference_empty == [[tag(:empty, 'reference'), '0']],
                   'native reference middle/last/empty selections differ')

      @reference_report = helper('helper_inspect_native_reference', 'inspect', @reference_part_path)
      check_helper_shape!(@reference_report, 'inspect')
      validate_helper_report!(@reference_report, 'native-written reference')
      @reference_audit = helper('helper_audit_native_reference', 'audit', @reference_part_path)
      check_helper_shape!(@reference_audit, 'audit')
      validate_audit!(@reference_audit, 'native-written reference', require_valid_fold: true)
      @reference_physical = inspect_physical!(@reference_part_path, 'native-written reference')
    end

    def build_summary(status)
      {
        format: FORMAT, status: status, fatal_error: @fatal_error,
        runtime: {path: @binary, sha256: W241::BINARY_SHA256, sha256_before: @runtime_sha_before,
                  sha256_after: (binary_sha rescue nil), version: W241::VERSION, build: W241::BUILD},
        source_sha256: @source_sha_before, helper_sha256: @helper_sha_before,
        source_stability: @source_stability,
        evidence_root: @root,
        writer_contract: {mode: 'plain MRK3', codec: 'single LZ4', rows_per_mark: ROWS_PER_MARK,
                          row_count: ROW_COUNT, mark_rows_with_terminal: MARK_ROWS,
                          physical_columns: SCHEMA, independent_literal_rows: expected_native_rows.map do |row|
                            row
                          end},
        generated: {
          path: @generated_path, report: @generated_report, audit: @generated_audit,
          physical: summarize_physical(@generated_physical), positive_stages: @positive_stages,
        },
        native_reference: {
          table: @reference_table, part_path: @reference_part_path, part_row: @reference_part_row,
          check_invocation: @reference_check, check_rows: @reference_check_rows,
          observe_invocation: @reference_observation,
          report: @reference_report, audit: @reference_audit,
          physical: summarize_physical(@reference_physical),
          row_domains: {full: @reference_rows&.size, middle: @reference_middle&.size,
                        last: @reference_last&.size, empty: @reference_empty},
          raw_tape_match: @generated_audit && @reference_audit &&
                          @generated_audit['data_bin_raw_sha256'] == @reference_audit['data_bin_raw_sha256'],
          fold_match: @generated_audit && @reference_audit &&
                      @generated_audit['data_bin_saved_uncompressed_hash_words'] ==
                      @reference_audit['data_bin_saved_uncompressed_hash_words'],
        },
        negative_controls: @case_stages, invocations: @invocations,
        interpretation: {
          native_check_fold: 'The pinned ClickHouse checker is known to disable uncompressed Compact data.bin fold verification; the fold-only control must attach, CHECK=1, and return unchanged values. It is a measured sensitivity gap, not a required refusal.',
          malformed_mark: 'Public Compact inspection must reject the checksummed MRK3 mutation. Native ATTACH, CHECK, and affected SELECT are retained as separate stages; CHECK alone is not treated as structural proof.',
          failure_policy: 'ATTACH refusal, CHECK result, and SELECT refusal/mismatch are distinct observations. Infrastructure failures do not qualify as corruption sensitivity.',
        },
      }
    end

    def summarize_physical(profile)
      return nil unless profile
      profile.reject { |key, _| key == :files || key == :frames }
    end
  end

  def self.main(argv)
    options = {binary: W241::BINARY}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/probe_compact_part_writer_w264.rb --helper PREBUILT_HELPER --evidence-root EMPTY_TMP_CHILD [--binary PINNED_CLICKHOUSE]'
      opts.on('--binary PATH', 'Pinned clickhouse-local executable') { |value| options[:binary] = value }
      opts.on('--helper PATH', 'Prebuilt W264 Crystal helper') { |value| options[:helper] = value }
      opts.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
    end
    parser.parse!(argv)
    raise OptionParser::MissingArgument, '--helper' unless options[:helper]
    raise OptionParser::MissingArgument, '--evidence-root' unless options[:evidence_root]
    exit(Probe.new(**options).run ? 0 : 1)
  rescue OptionParser::ParseError => error
    warn error.message
    warn parser
    exit 2
  end
end

ProbeCompactPartWriterW264.main(ARGV) if $PROGRAM_NAME == __FILE__
