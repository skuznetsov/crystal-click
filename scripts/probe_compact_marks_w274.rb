#!/usr/bin/env ruby
# Stock-first, four-cell Compact marks capture. This file never builds or starts
# Crystal. Root runs it serially under the repository's guarded runner.

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require_relative 'probe_object_shared_json_interop_w241'

module ProbeCompactMarksW274
  W241 = ProbeObjectSharedJSONInteropW241
  FORMAT = 'compact_marks_w274_capture_v1'.freeze
  SOURCE_ROOT = '/private/tmp/clickhouse-w254-upstream.AqeqyC'.freeze
  SOURCE_REVISION = 'ed30948f095ecb70679986d7d60e27ad770ae27a'.freeze
  SOURCE_FILES = [
    ['src/Storages/MergeTree/MergeTreeSettings.cpp', '99ec4877b2a7db63a05272cf918c6b312e674140f9ea2d221c4ef4542ffefe46'],
    ['src/Storages/MergeTree/MergeTreeIndexGranularityInfo.cpp', '78a430e4b026f53bb0f49da8edfd1b674009f0bad1c1c78488848cca5e765901'],
    ['src/Storages/MergeTree/MergeTreeDataPartWriterCompact.cpp', '0b551c2e4efe5638fc734f854e45d78beab342ce43fffd464b6196d1eeff2072'],
    ['src/Storages/MergeTree/MergeTreeWriterStream.cpp', '99333fae1e7e4c033c90956704ac20420008cc31bf692566642b11f86b664cbf'],
  ].map(&:freeze).freeze
  LOCAL_SOURCES = %w[
    scripts/probe_compact_marks_w274.rb
    scripts/compact_marks_w274_helper.cr
    scripts/probe_object_shared_json_interop_w241.rb
    scripts/check_array_json_parts_w185.rb
    scripts/probe_object_shared_json_w240.rb
    scripts/reconcile_object_shared_json_interop_w241.rb
    scripts/check_json_binary_kernel_w180.rb
    scripts/probe_json_array_storage_w183.rb
    src/crystal_click.cr
    src/crystal_click/compact_mark_file_adapter.cr
    src/crystal_click/compressed_mark_reader.cr
    src/crystal_click/compressed_block.cr
    src/crystal_click/compact_part_physical_context.cr
    src/crystal_click/compact_part_physical_window.cr
    src/crystal_click/compact_part_physical_granule.cr
    src/crystal_click/compact_part_physical_shard.cr
    src/crystal_click/compact_physical_slot.cr
    src/crystal_click/compact_binary_bulk_column_reader.cr
    src/crystal_click/compact_dynamic_bulk_column_reader.cr
    src/crystal_click/compact_static_json_bulk_column_reader.cr
    src/crystal_click/compact_recursive_json_column_reader.cr
    src/crystal_click/typed_binary_bulk_column_reader.cr
    src/crystal_click/typed_part_table.cr
    src/crystal_click/compact_part_table.cr
    src/crystal_click/typed_part_reader_entry.cr
    src/crystal_click/wide_part_table/wide_part_table_batch.cr
    src/crystal_click/binary_value_typed_batch_adapter.cr
    src/crystal_click/wide_part_table.cr
    src/crystal_click/binary_bulk_column_reader.cr
    src/crystal_click/offline_table/dynamic_bulk_values_materializer.cr
    src/crystal_click/offline_table/compact_json_values_materializer.cr
    src/crystal_click/compact_mark_index.cr
    src/crystal_click/part_checksums.cr
    src/crystal_click/part_stream_source.cr
    src/crystal_click/part_metadata_file_reader.cr
    src/crystal_click/compressed_stream_budget.cr
    src/crystal_click/compressed_stream_limits.cr
    src/crystal_click/compact_columns_substreams.cr
    src/crystal_click/compact_mark_format.cr
    src/crystal_click/binary_data_type.cr
    src/crystal_click/binary_value.cr
  ].freeze
  MARK_ROWS = [2, 2, 2].freeze
  ROWS = [
    {pk: 1, value: 9, label: 'alpha', tags: [1, -2]},
    {pk: 2, value: 0, label: '', tags: []},
    {pk: 3, value: 18_446_744_073_709_551_615, label: 'beta', tags: [0, 2_147_483_647]},
    {pk: 4, value: 42, label: 'mid row', tags: [-2_147_483_648]},
    {pk: 5, value: 7, label: 'tail', tags: [8, 9]},
    {pk: 6, value: 2, label: 'last', tags: []},
  ].map(&:freeze).freeze
  EXPECTED_UINT64_VALUES = {
    'pk' => %w[1 2 3 4 5 6].freeze,
    'value' => %w[9 0 18446744073709551615 42 7 2].freeze,
  }.freeze
  EXPECTED_TABLE_FULL_BATCHES = [
    {'mark_index' => 0, 'mark_row_offset' => 0, 'part_row_offset' => 0, 'source_row_offset' => 0,
     'row_count' => 2, 'pk' => %w[1 2], 'value' => %w[9 0]},
    {'mark_index' => 1, 'mark_row_offset' => 0, 'part_row_offset' => 2, 'source_row_offset' => 2,
     'row_count' => 2, 'pk' => %w[3 4], 'value' => %w[18446744073709551615 42]},
    {'mark_index' => 2, 'mark_row_offset' => 0, 'part_row_offset' => 4, 'source_row_offset' => 4,
     'row_count' => 2, 'pk' => %w[5 6], 'value' => %w[7 2]},
  ].map(&:freeze).freeze
  EXPECTED_TABLE_MIDDLE_BATCHES = [
    {'mark_index' => 1, 'mark_row_offset' => 1, 'part_row_offset' => 3, 'source_row_offset' => 3,
     'row_count' => 1, 'pk' => %w[4], 'value' => %w[42]},
    {'mark_index' => 2, 'mark_row_offset' => 0, 'part_row_offset' => 4, 'source_row_offset' => 4,
     'row_count' => 1, 'pk' => %w[5], 'value' => %w[7]},
  ].map(&:freeze).freeze
  NATIVE_EXPECTED_ROWS = [
    ['1', '9', '616C706861', '5B312C2D325D'],
    ['2', '0', '', '5B5D'],
    ['3', '18446744073709551615', '62657461', '5B302C323134373438333634375D'],
    ['4', '42', '6D696420726F77', '5B2D323134373438333634385D'],
    ['5', '7', '7461696C', '5B382C395D'],
    ['6', '2', '6C617374', '5B5D'],
  ].map(&:freeze).freeze
  CELLS = [
    {id: 'mrk3_plain', layout: 'mrk3', compressed: false, substreams: false},
    {id: 'mrk3_compressed', layout: 'mrk3', compressed: true, substreams: false},
    {id: 'mrk4_plain', layout: 'mrk4', compressed: false, substreams: true},
    {id: 'mrk4_compressed', layout: 'mrk4', compressed: true, substreams: true},
  ].map(&:freeze).freeze
  PART_FILE_LIMIT = 4096
  PART_BYTES_LIMIT = 64 * 1024 * 1024

  class Failure < StandardError; end

  class Probe
    def initialize(binary, helper, evidence_root, stock_only)
      @binary = File.expand_path(binary)
      @helper = helper && File.expand_path(helper)
      @stock_only = stock_only
      @root = validate_root(evidence_root)
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @invocations = []
      @fatal_error = nil
      @recorder = W241::Probe.allocate
      @recorder.instance_variable_set(:@root, @root)
      @recorder.instance_variable_set(:@binary, @binary)
      @recorder.instance_variable_set(:@invocations, @invocations)
    end

    def run
      prepare!
      native = run_native_matrix!
      cells = capture_native_parts!(native)
      helper = @stock_only ? nil : run_helper_matrix!(cells)
      verify_stable!
      summary = {
        format: FORMAT, status: @stock_only ? 'stock_native_matrix_observed' : 'stock_and_local_reader_observed',
        fatal_error: nil, evidence_root: @root,
        source_pin: source_pin_inventory,
        runtime: {path: @binary, sha256: W241::BINARY_SHA256, version: W241::VERSION, build: W241::BUILD,
                  sha256_before: @runtime_sha_before, sha256_after: sha(@binary)},
        settings: {compress_marks: [0, 1], marks_compression_codec: 'ZSTD(3)', marks_compress_block_size: 65_536,
                   write_marks_for_substreams_in_compact_parts: [0, 1], index_granularity: 2,
                   forced_part_type: 'Compact'},
        schema: [['pk', 'UInt64'], ['value', 'UInt64'], ['label', 'String'], ['tags', 'Array(Int32)']],
        rows: ROWS, mark_rows: MARK_ROWS, cells: cells, helper: helper,
        local_source_hashes_before: @local_source_hashes,
        local_source_hashes_after: local_source_hashes,
        native_invocation: native.fetch(:record), helper_invocations: @helper_invocations || [],
        helper_pin: @helper ? {path: @helper, sha256_before: @helper_sha, sha256_after: @helper_sha_after} : nil,
        limits: {native_max_threads: 1, native_max_memory_usage_bytes: W241::MEMORY,
                 outer_run_safe_memory_limit_bytes: W241::OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: W241::TIMEOUT, termination_grace_seconds: W241::GRACE},
        interpretation: {
          source_runtime_boundary: 'The upstream source pin and W241 recovered runtime pin are independent identities; no build provenance between them is asserted.',
          native_oracle: 'Each cell is written by pinned stock ClickHouse, CHECKed, and compared with an independently authored literal SELECT before any helper process runs.',
          marks: 'Plain .mrk3/.mrk4 bytes are captured directly from stock parts. A helper may decode .cmrk3/.cmrk4 through CompressedMarkReader.read_all and compare the canonical bytes; that reader verifies compressed-frame checksums, not ClickHouse CityHash metadata.',
          physical_reader: 'Local physical windows, Compact and neutral typed UInt64 readers, and the TypedPartTable facade are local-reader observations, not native results or an independent serializer oracle.',
          failure_policy: 'Any process, SQL, schema, part-layout, inventory, or helper mismatch is inconclusive; it is not evidence that ClickHouse rejects the format.',
        },
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      puts "W274 status=#{summary.fetch(:status)}; cells=#{cells.size}/#{CELLS.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      write_failure_summary rescue nil
      warn "W274 inconclusive: #{@fatal_error}"
      false
    end

    private

    def require_true(value, message)
      raise Failure, "W274: #{message}" unless value
    end

    def validate_root(path)
      require_true(path && !path.empty?, 'evidence root is required')
      expanded = File.expand_path(path)
      require_true(File.dirname(expanded) == File.realpath('/private/tmp'), 'evidence root must be a direct child of /private/tmp')
      require_true(!File.symlink?(expanded), 'evidence root is symlinked')
      require_true(File.directory?(expanded) && File.realpath(expanded) == expanded && Dir.children(expanded).empty?,
                   'evidence root must already exist, be canonical, and be empty')
      expanded
    rescue Errno::ENOENT
      raise Failure, 'evidence root must already exist'
    end

    def prepare!
      require_true(File.file?(@binary) && File.executable?(@binary) && !File.symlink?(@binary), 'ClickHouse binary is absent or symlinked')
      require_true(sha(@binary) == W241::BINARY_SHA256, 'ClickHouse binary differs from the W241 runtime pin')
      if !@stock_only
        require_true(@helper && File.file?(@helper) && File.executable?(@helper) && !File.symlink?(@helper), 'prebuilt helper is required and must not be symlinked')
        @helper_sha = sha(@helper)
      end
      @runtime_sha_before = sha(@binary)
      @local_source_hashes = local_source_hashes
      source_pin_inventory
      %w[invocations stores parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
    end

    def run_native_matrix!
      store = File.join(@root, 'stores', 'native')
      sql = ["SET output_format_json_quote_64bit_integers=0;",
             "SELECT '__W274_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;"]
      CELLS.each do |cell|
        table = table_name(cell.fetch(:id))
        sql << create_table_sql(table, cell)
        sql << insert_sql(table)
        sql << "SELECT '__W274_CHECK_BEGIN__', '#{cell.fetch(:id)}' FORMAT TSVRaw;"
        sql << "CHECK TABLE default.#{table} FORMAT TSV;"
        sql << "SELECT '__W274_CHECK_END__', '#{cell.fetch(:id)}' FORMAT TSVRaw;"
        sql << "SELECT '__W274_SCHEMA__', '#{cell.fetch(:id)}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;"
        sql << literal_select_sql(table, cell.fetch(:id))
      end
      table_names = CELLS.map { |cell| table_name(cell.fetch(:id)) }
      sql << "SELECT '__W274_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{table_names.map { |name| sql_quote(name) }.join(',')}) AND active ORDER BY table, name FORMAT TSVRaw;"
      invocation = @recorder.send(:native, 'stock_matrix', store, sql.join("\n") + "\n")
      require_true(invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?,
                   'stock matrix invocation did not exit successfully')
      require_true(invocation.fetch(:stderr).empty?, 'stock matrix wrote stderr')
      require_true(invocation.fetch(:record).fetch(:binary_sha_after) == W241::BINARY_SHA256, 'runtime changed during native matrix')
      invocation
    end

    def create_table_sql(table, cell)
      compressed = cell.fetch(:compressed) ? 1 : 0
      substreams = cell.fetch(:substreams) ? 1 : 0
      settings = [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=1073741824',
        'min_level_for_wide_part=0', 'compress_primary_key=0', 'marks_compress_block_size=65536', "compress_marks=#{compressed}",
      ]
      settings << "marks_compression_codec='ZSTD(3)'"
      settings << "write_marks_for_substreams_in_compact_parts=#{substreams}"
      settings << "default_compression_codec='LZ4'"
      "CREATE TABLE default.#{table} (pk UInt64, value UInt64, label String, tags Array(Int32)) " \
        "ENGINE=MergeTree ORDER BY pk SETTINGS #{settings.join(', ')};"
    end

    def insert_sql(table)
      values = ROWS.map do |row|
        "(#{row.fetch(:pk)}, #{row.fetch(:value)}, #{sql_quote(row.fetch(:label))}, [#{row.fetch(:tags).join(',')}])"
      end
      "INSERT INTO default.#{table} VALUES #{values.join(', ')};"
    end

    def literal_select_sql(table, id)
      "SELECT '__W274_ROW__', '#{id}', toString(pk), toString(value), hex(label), hex(toJSONString(tags)) " \
        "FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
    end

    def capture_native_parts!(invocation)
      lines = invocation.fetch(:stdout).dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      require_true(invocation.fetch(:stdout).dup.force_encoding(Encoding::UTF_8).valid_encoding?, 'native output is not UTF-8')
      pins = tagged_rows(lines, '__W274_PIN__')
      require_true(pins == [['__W274_PIN__', W241::VERSION, W241::BUILD]], 'native runtime version/build differs from W241 pin')
      checks = parse_checks(lines)
      schemas = tagged_rows(lines, '__W274_SCHEMA__')
      rows = tagged_rows(lines, '__W274_ROW__')
      parts = tagged_rows(lines, '__W274_PART__')
      require_true(checks == CELLS.map { |cell| [cell.fetch(:id), ["all_1_1_0\t1\t"]] }.to_h, 'one or more native CHECK TABLE results differ')
      result = {}
      CELLS.each do |cell|
        id = cell.fetch(:id)
        table = table_name(id)
        schema_rows = schemas.select { |entry| entry[1] == id }
        require_true(schema_rows.map { |entry| entry.drop(2) } == [['pk', 'UInt64'], ['value', 'UInt64'], ['label', 'String'], ['tags', 'Array(Int32)']], "#{id} stock schema differs")
        expected_rows = NATIVE_EXPECTED_ROWS.map do |row|
          ['__W274_ROW__', id] + row
        end
        observed_rows = rows.select { |entry| entry[1] == id }
        require_true(observed_rows == expected_rows, "#{id} stock literal SELECT differs")
        part_rows = parts.select { |entry| entry[1] == table }
        require_true(part_rows.size == 1 && part_rows[0].size == 7, "#{id} must have one active part")
        part = part_rows[0]
        require_true(part.values_at(2, 4, 5, 6) == ['all_1_1_0', 'Compact', '6', '4'], "#{id} part identity/type/grid differs")
        part_path = normalize_part_path(part[3])
        inventory = snapshot_part(part_path)
        marks = expected_mark_file(cell)
        marked = inventory.fetch(:files).keys.grep(/\Adata\.c?mrk[0-9]+\z/)
        require_true(marked == [marks], "#{id} mark filename differs or is ambiguous: #{marked.inspect}")
        require_true(inventory.fetch(:files).key?('data.bin') && inventory.fetch(:files).key?('checksums.txt'), "#{id} lacks data/checksum files")
        canonical = nil
        unless cell.fetch(:compressed)
          mark_path = File.join(part_path, marks)
          bytes = File.binread(mark_path)
          require_true(bytes.bytesize <= PART_BYTES_LIMIT, "#{id} plain marks exceed probe bound")
          canonical = {size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes), hex: bytes.unpack1('H*')}
        end
        result[id] = {
          id: id, table: table, layout: cell.fetch(:layout), compressed: cell.fetch(:compressed),
          substreams: cell.fetch(:substreams), part_path: part_path, part_type: part[4], rows: 6,
          mark_rows: MARK_ROWS, mark_file: marks, inventory: inventory, canonical_marks: canonical,
        }
      end
      result
    end

    def parse_checks(lines)
      active = nil
      checks = {}
      lines.each do |line|
        if line.start_with?("__W274_CHECK_BEGIN__\t")
          fields = line.split("\t", -1)
          require_true(fields.size == 2 && active.nil? && CELLS.any? { |cell| cell.fetch(:id) == fields[1] }, 'malformed/duplicate CHECK begin')
          active = fields[1]
          checks[active] = []
        elsif line.start_with?("__W274_CHECK_END__\t")
          fields = line.split("\t", -1)
          require_true(fields.size == 2 && active == fields[1], 'malformed CHECK end')
          active = nil
        elsif active
          checks.fetch(active) << line
        end
      end
      require_true(active.nil? && checks.keys.sort == CELLS.map { |cell| cell.fetch(:id) }.sort, 'CHECK output delimiters differ')
      checks
    end

    def run_helper_matrix!(cells)
      @helper_invocations = []
      results = {}
      CELLS.each do |cell|
        id = cell.fetch(:id)
        part = cells.fetch(id).fetch(:part_path)
        marks = run_helper("marks_#{id}", 'marks', part)
        physical = run_helper("physical_#{id}", 'physical', part)
        marks_report = parse_helper_report!(marks, "marks_#{id}")
        physical_report = parse_helper_report!(physical, "physical_#{id}")
        validate_helper_marks!(id, marks_report, cells.fetch(id))
        validate_helper_physical!(id, physical_report, cells.fetch(id))
        results[id] = {marks: marks_report, physical: physical_report}
      end
      %w[mrk3 mrk4].each do |layout|
        plain = CELLS.find { |cell| cell.fetch(:layout) == layout && !cell.fetch(:compressed) }
        compressed = CELLS.find { |cell| cell.fetch(:layout) == layout && cell.fetch(:compressed) }
        plain_id = plain.fetch(:id)
        compressed_id = compressed.fetch(:id)
        require_true(results.fetch(plain_id).fetch(:marks).fetch('canonical_marks_hex') ==
                     results.fetch(compressed_id).fetch(:marks).fetch('canonical_marks_hex'), "#{layout} compressed/plain canonical marks differ")
        require_true(normalized_physical_pair(results.fetch(plain_id).fetch(:physical)) ==
                     normalized_physical_pair(results.fetch(compressed_id).fetch(:physical)),
                     "#{layout} compressed/plain physical reader results differ")
      end
      @helper_sha_after = sha(@helper)
      require_true(@helper_sha_after == @helper_sha, 'helper binary changed during capture')
      results
    end

    # The per-cell validators bind the real sidecar and its selected checksum
    # names. Remove only those representation labels before comparing the
    # logically equivalent plain/compressed physical read results.
    def normalized_physical_pair(report)
      normalized = report.dup
      normalized.delete('marks_file')
      %w[compact_binary_uint64 neutral_typed_uint64].each do |key|
        reader = normalized.fetch(key).dup
        reader.delete('selected_checksum_names')
        normalized[key] = reader
      end
      normalized
    end

    def run_helper(label, action, part)
      invocation = @recorder.send(:run_process, label, [@helper, action, part], ''.b, 'crystal-helper',
                                  expected_sha: @helper_sha, binary_path: @helper)
      @helper_invocations << invocation.fetch(:record)
      require_true(invocation[:classification] == 'success' && invocation[:status]&.success? && invocation.fetch(:stderr).empty?,
                   "#{label} helper invocation failed")
      invocation.fetch(:stdout)
    end

    def validate_helper_marks!(id, report, cell)
      require_true(report.fetch('format') == 'compact_marks_w274_helper_v1' && report.fetch('action') == 'marks', "#{id} helper marks identity differs")
      require_true(report.fetch('marks_file') == cell.fetch(:mark_file) && report.fetch('layout') == cell.fetch(:layout), "#{id} helper marks filename/layout differs")
      hex = report.fetch('canonical_marks_hex')
      require_true(report.fetch('compressed') == cell.fetch(:compressed), "#{id} helper compressed declaration differs")
      require_true(hex.is_a?(String) && hex.match?(/\A(?:[0-9a-f]{2})*\z/), "#{id} helper canonical mark hex is malformed")
      require_true(report.fetch('canonical_marks_bytes') == hex.length / 2, "#{id} helper canonical mark byte count differs")
      require_true(report.fetch('canonical_marks_sha256') == Digest::SHA256.hexdigest([hex].pack('H*')), "#{id} helper marks digest is malformed")
      require_true(report.fetch('frame_authentication') == 'CompressedMarkReader.read_all' || !cell.fetch(:compressed), "#{id} compressed marks did not use the authenticated reader")
      if native = cell.fetch(:canonical_marks)
        require_true(report.fetch('canonical_marks_hex') == native.fetch(:hex), "#{id} helper plain marks differ from raw native bytes")
      end
    end

    def validate_helper_physical!(id, report, cell)
      require_true(report.fetch('format') == 'compact_marks_w274_helper_v1' && report.fetch('action') == 'physical', "#{id} helper physical identity differs")
      require_true(report.fetch('mode') == (cell.fetch(:layout) == 'mrk3' ? 'Mrk3' : 'Mrk4'), "#{id} local physical mode differs")
      require_true(report.fetch('row_count') == 6 && report.fetch('mark_row_counts') == MARK_ROWS, "#{id} local physical row grid differs")
      require_true(report.fetch('marks_file') == cell.fetch(:mark_file), "#{id} local physical mark filename differs")
      require_true(report.fetch('typed_uint64_encoding') == 'decimal-string', "#{id} local UInt64 encoding differs")
      require_true(report.fetch('typed_uint64') == EXPECTED_UINT64_VALUES, "#{id} local typed UInt64 values differ")
      require_true(report.fetch('reader_boundary') == 'local public Compact physical and BinaryBulk reader results; no native serializer claim', "#{id} helper reader boundary differs")
      require_true(report.fetch('physical_windows').is_a?(Hash) && report.fetch('physical_windows').keys.sort == %w[label pk tags value].sort, "#{id} local physical window roster differs")
      require_true(report.fetch('neutral_reader_boundary') == 'local public typed BinaryBulk and TypedPartTable facade results; not native serializer claims', "#{id} helper neutral reader boundary differs")

      expected_checksums = {
        'pk' => ['data.bin', cell.fetch(:mark_file)],
        'value' => ['data.bin', cell.fetch(:mark_file)],
      }
      compact_binary = report.fetch('compact_binary_uint64')
      require_true(compact_binary.fetch('values') == EXPECTED_UINT64_VALUES, "#{id} local Compact BinaryBulk values differ")
      require_true(compact_binary.fetch('selected_checksum_names') == expected_checksums, "#{id} Compact BinaryBulk checksum names differ")
      neutral_binary = report.fetch('neutral_typed_uint64')
      require_true(neutral_binary.fetch('values') == EXPECTED_UINT64_VALUES, "#{id} local neutral BinaryBulk values differ")
      require_true(neutral_binary.fetch('selected_checksum_names') == expected_checksums, "#{id} neutral BinaryBulk checksum names differ")

      expected_types = [['pk', 'UInt64'], ['value', 'UInt64']]
      expected_sources = [['pk', 'pk', 'UInt64'], ['value', 'value', 'UInt64']]
      table = report.fetch('neutral_typed_table')
      require_true(table.fetch('part_count') == 1 && table.fetch('total_row_count') == 6, "#{id} neutral table dimensions differ")
      require_true(table.fetch('part_mark_row_counts') == [MARK_ROWS], "#{id} neutral table mark grid differs")
      require_true(table.fetch('columns') == %w[pk value], "#{id} neutral table column order differs")
      require_true(table.fetch('column_types') == expected_types, "#{id} neutral table types differ")
      require_true(table.fetch('column_sources') == expected_sources, "#{id} neutral table sources differ")
      require_true(table.fetch('full_batches') == EXPECTED_TABLE_FULL_BATCHES, "#{id} neutral table full batches differ")
      require_true(table.fetch('middle_window') == {
        'start_row' => 3, 'max_rows' => 2, 'batches' => EXPECTED_TABLE_MIDDLE_BATCHES,
      }, "#{id} neutral table middle window differs")
      require_true(table.fetch('eof_window') == {
        'start_row' => 6, 'max_rows' => 1, 'batches' => [],
      }, "#{id} neutral table EOF window differs")
    end

    def verify_stable!
      require_true(sha(@binary) == W241::BINARY_SHA256, 'ClickHouse runtime changed during capture')
      require_true(local_source_hashes == @local_source_hashes, 'a pinned local probe/library source changed during capture')
      require_true(source_pin_inventory == @source_pin_inventory, 'pinned ClickHouse source changed during capture')
      require_true(@helper.nil? || sha(@helper) == @helper_sha, 'helper binary changed during capture')
    end

    def source_pin_inventory
      root = File.realpath(SOURCE_ROOT)
      require_true(root == SOURCE_ROOT && !File.symlink?(root), 'pinned ClickHouse source root is absent or noncanonical')
      revision, stderr, status = Open3.capture3('git', '-C', root, 'rev-parse', 'HEAD')
      require_true(status.success? && stderr.empty? && revision.strip == SOURCE_REVISION, 'ClickHouse source revision differs from the W274 source pin')
      files = SOURCE_FILES.map do |relative, expected|
        path = File.join(root, relative)
        observed = sha(path)
        require_true(observed == expected, "ClickHouse source file pin differs: #{relative}")
        {path: relative, sha256: observed}
      end
      snapshot = {root: root, revision: revision.strip, files: files}
      @source_pin_inventory ||= snapshot
      snapshot
    rescue Errno::ENOENT
      raise Failure, 'pinned ClickHouse source tree is absent'
    end

    def local_source_hashes
      root = File.expand_path('..', __dir__)
      paths = LOCAL_SOURCES.reject do |relative|
        @stock_only && (relative == 'scripts/compact_marks_w274_helper.cr' ||
                        relative == 'src/crystal_click/compact_mark_file_adapter.cr')
      end
      paths.map do |relative|
        path = File.join(root, relative)
        require_true(File.file?(path) && !File.symlink?(path), "local source pin is absent or symlinked: #{relative}")
        {path: relative, sha256: sha(path)}
      end
    end

    def table_name(id)
      "w274_#{@token}_#{id}"
    end

    def expected_mark_file(cell)
      prefix = cell.fetch(:compressed) ? 'data.c' : 'data.'
      "#{prefix}#{cell.fetch(:layout)}"
    end

    def normalize_part_path(path)
      require_true(path.is_a?(String) && path.start_with?(File::SEPARATOR) && !path.include?("\0"), 'native part path is not absolute')
      require_true(!path.end_with?(File::SEPARATOR * 2), 'native part path has repeated trailing separators')
      path = path[0...-1] if path.end_with?(File::SEPARATOR)
      expanded = File.expand_path(path)
      store = File.join(@root, 'stores', 'native')
      require_true(!path.empty? && expanded == path && expanded.start_with?(store + File::SEPARATOR), 'native part path escaped its isolated store or is not canonical')
      current = store
      expanded.delete_prefix(store + File::SEPARATOR).split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        require_true(!File.symlink?(current), "symlink in native part path: #{current}")
      end
      require_true(File.directory?(expanded) && File.realpath(expanded) == expanded, 'native part path is not a canonical directory')
      expanded
    end

    def snapshot_part(path)
      require_true(File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path, 'part directory is missing or noncanonical')
      names = Dir.children(path).sort
      require_true(names.size <= PART_FILE_LIMIT, 'part contains too many files')
      total = 0
      files = names.to_h do |name|
        full = File.join(path, name)
        require_true(!File.symlink?(full) && File.file?(full), "part entry is not a regular file: #{name}")
        size = File.size(full)
        require_true(size >= 0 && size <= PART_BYTES_LIMIT && total <= PART_BYTES_LIMIT - size, 'part file inventory exceeds byte bound')
        total += size
        [name, {size: size, sha256: sha(full)}]
      end
      {path: path, total_bytes: total, files: files}
    end

    def tagged_rows(lines, tag)
      lines.select { |line| line.start_with?("#{tag}\t") }.map { |line| line.split("\t", -1) }
    end

    def sql_quote(value)
      "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
    end

    def hex_upper(value)
      value.to_s.b.unpack1('H*').upcase
    end

    def parse_helper_report!(stdout, label)
      text = stdout.dup.force_encoding(Encoding::UTF_8)
      require_true(text.valid_encoding? && text.lines.size == 1 && text.end_with?("\n"), "#{label} helper output is not one JSON line")
      JSON.parse(text)
    rescue JSON::ParserError => error
      raise Failure, "W274 #{label} helper output is invalid JSON: #{error.message}"
    end

    def sha(path)
      Digest::SHA256.file(path).hexdigest
    end

    def safe_sha(path)
      sha(path)
    rescue StandardError
      nil
    end

    def write_new(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    def write_failure_summary
      return if File.exist?(File.join(@root, 'summary.json')) || !File.directory?(File.join(@root, 'invocations'))
      summary = {
        format: FORMAT, status: 'capture_incomplete_or_observations_differ', fatal_error: @fatal_error,
        evidence_root: @root,
        runtime: {path: @binary, expected_sha256: W241::BINARY_SHA256, sha256: safe_sha(@binary),
                  version: W241::VERSION, build: W241::BUILD},
        invocations: @invocations,
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
    end
  end
end

def main
  options = {binary: ProbeCompactMarksW274::W241::BINARY, stock_only: false}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_compact_marks_w274.rb --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP --stock-only [--clickhouse CLICKHOUSE] | --helper PREBUILT_HELPER [--clickhouse CLICKHOUSE]'
    parser.on('--clickhouse PATH') { |value| options[:binary] = value }
    parser.on('--helper PATH') { |value| options[:helper] = value }
    parser.on('--stock-only') { options[:stock_only] = true }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
  end.parse!
  raise 'evidence root is required via --evidence-root' unless options[:evidence_root]
  raise 'choose exactly one of --stock-only or --helper' unless options[:stock_only] ^ !options[:helper].nil?
  exit(ProbeCompactMarksW274::Probe.new(options[:binary], options[:helper], options[:evidence_root], options[:stock_only]).run ? 0 : 1)
end

main if $PROGRAM_NAME == __FILE__
