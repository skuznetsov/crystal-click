#!/usr/bin/env ruby
# Offline, bounded auditor for the immutable W284 stock-only capture.
# It does not invoke ClickHouse, Crystal, a compiler, or the public reader.

require 'digest'
require 'json'
require 'optparse'
require 'pathname'

module AuditCompactRecursiveDynamicW284Capture
  FORMAT = 'compact_recursive_dynamic_w284_capture_audit_v1'.freeze
  SUMMARY_FORMAT = 'compact_recursive_dynamic_w284_stock_v1'.freeze
  CAPTURE_ROOT = '/opt/mldata_ssd/cache/crystal-click-w284.9Nzwqc/stock-first'.freeze
  REPORT_ROOT = '/opt/mldata_ssd/cache/crystal-click-w284.9Nzwqc/reports'.freeze
  SUMMARY_DEFAULT = File.join(CAPTURE_ROOT, 'summary.json').freeze
  REPORT_DEFAULT = File.join(REPORT_ROOT, 'compact-recursive-dynamic-w284-capture-audit-v3.json').freeze
  SOURCE_REVISION = 'ed30948f095ecb70679986d7d60e27ad770ae27a'.freeze
  SOURCE_TREE = '2f5516e7e8316eba6f0b0886188c0fba5406a7fc'.freeze
  RUNTIME = {
    'sha256' => '5bb43958f4c0806cc363b84b9858e7206e56ac80263a24acc704271322e531ae',
    'bytes' => 919_123_095,
    'version' => '26.10.1.1201',
    'build' => 'd9bcb5ab007f0f6299f7f973f2642245bab3d028',
  }.freeze
  STOCK_RUNNER_PATH = 'scripts/verify_compact_recursive_dynamic_w284.rb'.freeze
  FROZEN_LOCAL_SOURCES = {
    STOCK_RUNNER_PATH => 'd8bb336239c172da97ca30b7519d77ab160ba5dcaea049ce4ec59249a465976b',
    'scripts/compact_recursive_dynamic_w284_helper.cr' => '886727d8cfde2e157a4f660101c4160d1c9414b86b58d0578833af3b6bd3b2d3',
    'scripts/support/compact_recursive_dynamic_w284_fixture.cr' => '6de7f30d4bf8079520a2a931638a480bc623e4f06d0aef66118daabcf4831ca9',
  }.freeze

  CASES = %w[
    basic_mrk3_s0 basic_mrk3_s1 basic_mrk4_s0 basic_mrk4_s1
    compact_mrk3_s0 compact_mrk3_s1 compact_mrk4_s0 compact_mrk4_s1
  ].freeze
  MARK_ROWS = [2, 2, 2, 2, 0].freeze
  SCHEMA = 'Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), sample Dynamic(max_types=1)))'.freeze
  MRK4_S0_TRACE_STREAMS = %w[
    trace%2Edoc.object_structure
    trace%2Esample.dynamic_structure
    trace%2Esample.variant_discr_prefix
    trace.size0
    trace%2Edoc.t
    trace%2Edoc.object_shared_data.size1
    trace%2Edoc.object_shared_data%2Epaths
    trace%2Edoc.object_shared_data%2Evalues
    trace%2Esample.variant_discr
    trace%2Esample.SharedVariant
    trace%2Esample.UInt64
  ].freeze
  MRK4_S1_TRACE_STREAMS = (MRK4_S0_TRACE_STREAMS[0, 9] + [
    'trace%2Esample.SharedVariant.size',
    'trace%2Esample.SharedVariant',
    'trace%2Esample.UInt64',
  ]).freeze

  SQL_ROWS = [
    '103|',
    '104|14:UInt64:U1040',
    '105|15:String:S6368696c6421;16:NULL:N',
    '106|17:UInt64:U1060',
    '107|',
    '108|',
    '109|18:NULL:N',
    '110|19:NULL:N',
  ].freeze
  Q_BY_MARK = {
    'dynamic_occurrences_by_mark' => [1, 3, 0, 2],
    'dynamic_nonnull_by_mark' => [1, 2, 0, 0],
    'dynamic_null_by_mark' => [0, 1, 0, 2],
    'shared_string_by_mark' => [0, 1, 0, 0],
    'uint64_by_mark' => [1, 1, 0, 0],
  }.freeze

  MAX_SUMMARY_BYTES = 2 * 1024 * 1024
  MAX_FILES_PER_PART = 32
  MAX_SUBSTREAMS_PER_COLUMN = 16
  MAX_PART_BYTES = 64 * 1024 * 1024
  MAX_SINGLE_FILE_BYTES = 64 * 1024 * 1024
  MAX_RAW_FRAME_BYTES = 4096
  MAX_RAW_FRAME_COUNT = 4096
  MAX_TOTAL_DECODED_BYTES = 64 * 1024 * 1024
  OUTPUT_PERMISSION = 0o600

  class AuditError < StandardError; end

  class Auditor
    def initialize(summary_path:, report_path:)
      @summary_path = File.expand_path(summary_path)
      @report_path = File.expand_path(report_path)
      @summary_root = File.dirname(@summary_path)
      @report_root = File.dirname(@report_path)
    end

    def run
      validate_paths!
      summary_bytes = read_bounded(@summary_path, MAX_SUMMARY_BYTES, 'summary.json')
      summary = JSON.parse(summary_bytes)
      validate_summary_header!(summary)
      source_inputs = validate_stock_input_provenance!(summary)
      cells = CASES.to_h do |case_id|
        [case_id, audit_cell!(summary.fetch('cells').fetch(case_id), case_id)]
      end
      negative_controls = run_negative_controls!(summary.fetch('cells'))
      summary_after = Digest::SHA256.file(@summary_path).hexdigest
      fail!('stock summary changed during audit') unless summary_after == Digest::SHA256.hexdigest(summary_bytes)

      result = {
        'format' => FORMAT,
        'status' => 'offline_dynamic_v3_prefix_audit_passed_for_eight_stock_cells',
        'summary' => {
          'path' => @summary_path,
          'bytes' => summary_bytes.bytesize,
          'sha256' => summary_after,
          'captured_status' => summary.fetch('status'),
        },
        'source_pin' => {
          'revision' => SOURCE_REVISION,
          'tree' => SOURCE_TREE,
          'runtime_provenance_asserted' => false,
          'anchors' => source_anchors,
        },
        'runtime_pin' => RUNTIME.merge('provenance' => 'separate from pinned source revision; summary-reported before/after identity only'),
        'frozen_local_inputs' => source_inputs,
        'bounds' => {
          'summary_max_bytes' => MAX_SUMMARY_BYTES,
          'max_files_per_part' => MAX_FILES_PER_PART,
          'max_part_bytes' => MAX_PART_BYTES,
          'max_single_file_bytes' => MAX_SINGLE_FILE_BYTES,
          'max_lz4_frame_decoded_bytes' => MAX_RAW_FRAME_BYTES,
          'max_lz4_frames' => MAX_RAW_FRAME_COUNT,
          'max_total_decoded_bytes' => MAX_TOTAL_DECODED_BYTES,
        },
        'cells' => cells,
        'negative_controls' => negative_controls,
        'claim_boundary' => {
          'proves' => 'Exact listed-file SHA/size inventory, bounded LZ4 frame/block decoding, MRK3/MRK4 mark geometry, and this fixture’s Dynamic V3/Object V3/mode-prefix bytes for eight immutable stock parts.',
          'does_not_prove' => [
            'ClickHouse CityHash128 frame/checksum validation; the stored 16-byte frame hash is not recomputed.',
            'Crystal reader behavior, generated-part interoperability, or public reader/writer compatibility.',
            'Raw actual-arm Q or body value decoding; per-mark Q values are independently embedded SQL-summary literals, not inferred from Dynamic prefix statistics.',
            'General Dynamic/JSON serialization grammar beyond this exact direct Dynamic leaf under Array/Tuple and the eight captured cells.',
          ],
          'whole_part_statistics' => 'First-mark Dynamic statistics [SharedVariant=1, UInt64=2] describe whole-part prefix statistics; they are not that mark’s Q. NULL remains distinct from SharedVariant.',
          'stock_only_scope' => 'The prior immutable stock capture performed seed and reopen invocations with SQL/CHECK queries; ATTACH was not executed. This auditor itself is offline Ruby only.',
        },
      }
      write_report!(JSON.pretty_generate(result) + "\n")
      puts "W284 audit status=#{result.fetch('status')} cells=#{cells.size} negative_controls=#{negative_controls.map { |control| control.fetch('id') }.join(',')} report=#{@report_path}"
      result
    rescue AuditError, JSON::ParserError, KeyError, Errno::ENOENT, Errno::EACCES => error
      warn "W284 offline capture audit failed: #{error.class}: #{error.message}"
      raise
    end

    # Public single-case reader for a future composed interop driver. Returns
    # only JSON-safe values and performs no report writes or native launches.
    def audit_case(case_id:)
      validate_capture_path!
      fail!("unknown W284 case #{case_id.inspect}") unless CASES.include?(case_id)
      summary_bytes = read_bounded(@summary_path, MAX_SUMMARY_BYTES, 'summary.json')
      summary_sha256 = Digest::SHA256.hexdigest(summary_bytes)
      summary = JSON.parse(summary_bytes)
      validate_summary_header!(summary)
      validate_stock_input_provenance!(summary)
      case_result = audit_cell!(summary.fetch('cells').fetch(case_id), case_id)
      fail!('stock summary changed during single-case audit') unless Digest::SHA256.file(@summary_path).hexdigest == summary_sha256
      JSON.parse(JSON.generate(case_result))
    rescue AuditError, JSON::ParserError, KeyError, Errno::ENOENT, Errno::EACCES => error
      warn "W284 single-case capture audit failed: #{error.class}: #{error.message}"
      raise
    end

    private

    def fail!(message)
      raise AuditError, "W284 capture audit: #{message}"
    end

    def validate_paths!
      validate_capture_path!
      fail!('report root must be the existing task reports directory') unless
        File.directory?(@report_root) && !File.symlink?(@report_root) && File.realpath(@report_root) == File.realpath(REPORT_ROOT)
      fail!('report path must be a direct child of the W284 reports directory') unless File.dirname(@report_path) == @report_root
      fail!('report path already exists; refusing overwrite') if File.exist?(@report_path) || File.symlink?(@report_path)
    end

    def validate_capture_path!
      fail!('summary path must be a regular non-symlink file') unless File.file?(@summary_path) && !File.symlink?(@summary_path)
      fail!('summary is not the pinned stock-first summary') unless File.basename(@summary_path) == 'summary.json'
      fail!('summary root is not the pinned W284 stock-first directory') unless
        File.directory?(@summary_root) && !File.symlink?(@summary_root) && File.realpath(@summary_root) == File.realpath(CAPTURE_ROOT)
    end

    def read_bounded(path, maximum, label)
      stat = File.lstat(path)
      fail!("#{label} is not a regular non-symlink file") unless stat.file? && !stat.symlink?
      fail!("#{label} exceeds #{maximum} bytes") if stat.size > maximum
      bytes = String.new(encoding: Encoding::BINARY)
      File.open(path, 'rb') do |file|
        while (chunk = file.read(64 * 1024))
          fail!("#{label} streamed read exceeded #{maximum} bytes") if bytes.bytesize > maximum - chunk.bytesize
          bytes << chunk
        end
      end
      fail!("#{label} size changed during read") unless bytes.bytesize == stat.size
      bytes
    end

    def validate_summary_header!(summary)
      fail!('unexpected stock summary format') unless summary.fetch('format') == SUMMARY_FORMAT
      fail!('stock capture is not the exact prefix-unparsed baseline') unless
        summary.fetch('status') == 'stock_sql_values_and_raw_part_inventory_exact_prefix_unparsed'
      source = summary.fetch('source_pin')
      fail!('pinned source revision differs') unless
        source.fetch('revision_expected') == SOURCE_REVISION &&
        source.fetch('revision_before') == SOURCE_REVISION && source.fetch('revision_after') == SOURCE_REVISION
      runtime = summary.fetch('runtime_pin')
      %w[sha256 bytes version build].each do |key|
        fail!("runtime #{key} differs from immutable capture pin") unless runtime.fetch(key) == RUNTIME.fetch(key)
      end
      fail!('runtime before/after identity differs') unless
        runtime.fetch('sha256_before') == RUNTIME.fetch('sha256') && runtime.fetch('sha256_after') == RUNTIME.fetch('sha256') &&
        runtime.fetch('bytes_before') == RUNTIME.fetch('bytes') && runtime.fetch('bytes_after') == RUNTIME.fetch('bytes')
      fail!('stock capture cell set differs from the eight-cell matrix') unless summary.fetch('cells').keys.sort == CASES.sort
    end

    def validate_stock_input_provenance!(summary)
      before = summary.fetch('local_source_sha256_before')
      after = summary.fetch('local_source_sha256_after')
      FROZEN_LOCAL_SOURCES.map do |relative_path, expected_sha|
        path = File.expand_path(relative_path, File.expand_path('..', __dir__))
        summary_path = before.keys.find { |candidate| File.expand_path(candidate) == path }
        fail!("summary lacks frozen source record for #{relative_path}") unless summary_path
        fail!("summary before/after source hash changed for #{relative_path}") unless before.fetch(summary_path) == expected_sha && after.fetch(summary_path) == expected_sha
        # Stock capture ran the Ruby runner. Its summary recorded the unused
        # Crystal helper and fixture hashes for provenance. Interop separately
        # pins the current helper and fixture used to build its executables.
        if relative_path == STOCK_RUNNER_PATH
          actual = Digest::SHA256.file(path).hexdigest
          fail!("frozen stock runner bytes changed for #{relative_path}") unless actual == expected_sha
        end
        {'path' => relative_path, 'sha256' => expected_sha}
      end
    end

    def audit_cell!(cell, case_id)
      mode = case_id.start_with?('basic_') ? 'basic' : 'compact'
      mark_format = case_id.include?('_mrk3_') ? 'mrk3' : 'mrk4'
      profile = case_id.end_with?('_s1') ? 's1' : 's0'
      part = cell.fetch('part')
      fail!("#{case_id} schema differs") unless cell.fetch('schema') == SCHEMA
      fail!("#{case_id} case metadata differs") unless
        cell.fetch('case_id') == case_id && cell.fetch('mode') == mode &&
        cell.fetch('mark_format') == mark_format && cell.fetch('string_profile') == profile
      fail!("#{case_id} part metadata differs") unless
        part.fetch('name') == 'all_1_1_0' && part.fetch('rows') == 8 &&
        part.fetch('system_marks') == 5 && part.fetch('part_type') == 'Compact'
      validate_part_path!(part.fetch('path'), case_id)
      validate_sql_oracle!(cell, case_id)

      part_path = File.realpath(part.fetch('path'))
      inventory = read_and_validate_inventory!(part.fetch('snapshot'), part_path, case_id)
      validate_columns_file!(inventory.fetch('columns.txt'), case_id)
      serialization = JSON.parse(inventory.fetch('serialization.json'))
      expected_string_version = profile == 's0' ? 0 : 1
      fail!("#{case_id} serialization profile differs") unless
        serialization == {
          'columns' => [],
          'propagate_types_serialization_versions_to_nested_types' => true,
          'types_serialization_versions' => {'string' => expected_string_version},
          'version' => 1,
        }
      fail!("#{case_id} count.txt differs") unless inventory.fetch('count.txt') == '8'

      substreams = if mark_format == 'mrk4'
                     parse_substreams!(inventory.fetch('columns_substreams.txt'), profile, case_id)
                   else
                     nil
                   end
      slots = mark_format == 'mrk4' ? mrk4_slots(substreams) : [
        {'column' => 'pk', 'stream_name' => nil, 'global_index' => 0},
        {'column' => 'trace', 'stream_name' => nil, 'global_index' => 1},
      ]
      marks_extension = "data.#{mark_format}"
      mark_bytes = inventory.fetch(marks_extension)
      marks = parse_marks!(mark_bytes, mark_format, slots.size, case_id)
      data_compressed = inventory.fetch('data.bin')
      decoded = decode_frames!(data_compressed, case_id)
      positions = marks.fetch('records').map do |record|
        coords = slots.map do |slot|
          word_index = slot.fetch('global_index') * 2
          raw_coordinate = [record.fetch(word_index), record.fetch(word_index + 1)]
          logical_position!(raw_coordinate, data_compressed.bytesize, decoded.fetch('frames'), decoded.fetch('bytes').bytesize, case_id)
        end
        fail!("#{case_id} global slot positions are not monotone within a mark") unless
          coords.each_cons(2).all? { |left, right| (left <=> right) <= 0 }
        coords
      end
      fail!("#{case_id} global slot positions retreat across marks") unless
        positions.each_cons(2).all? { |left, right| left.zip(right).all? { |before, after| before <= after } }
      validate_terminal_and_rows!(marks, positions, data_compressed.bytesize, decoded.fetch('bytes').bytesize, case_id)

      dynamic_index = mark_format == 'mrk4' ? slots.find { |slot| slot['stream_name'] == 'trace%2Esample.dynamic_structure' }.fetch('global_index') : 1
      mode_index = mark_format == 'mrk4' ? slots.find { |slot| slot['stream_name'] == 'trace%2Esample.variant_discr_prefix' }.fetch('global_index') : nil
      prefixes = 4.times.map do |mark_index|
        if mark_format == 'mrk4'
          start = positions.fetch(mark_index).fetch(dynamic_index)
          finish = positions.fetch(mark_index).fetch(dynamic_index + 1)
          shard = slice_exact!(decoded.fetch('bytes'), start, finish, "#{case_id} mark#{mark_index} DynamicStructure")
          dynamic = parse_dynamic_prefix!(shard, 0, "#{case_id} mark#{mark_index} DynamicStructure")
          fail!("#{case_id} mark#{mark_index} DynamicStructure shard has trailing bytes") unless dynamic.fetch('bytes_consumed') == shard.bytesize
          mode_start = positions.fetch(mark_index).fetch(mode_index)
          mode_finish = positions.fetch(mark_index).fetch(mode_index + 1)
          mode_bytes = slice_exact!(decoded.fetch('bytes'), mode_start, mode_finish, "#{case_id} mark#{mark_index} mode prefix")
          mode_value = parse_mode_prefix!(mode_bytes, mode, "#{case_id} mark#{mark_index}")
          object_start = positions.fetch(mark_index).fetch(slots.find { |slot| slot['stream_name'] == 'trace%2Edoc.object_structure' }.fetch('global_index'))
          object_finish = positions.fetch(mark_index).fetch(slots.find { |slot| slot['stream_name'] == 'trace%2Esample.dynamic_structure' }.fetch('global_index'))
          object = slice_exact!(decoded.fetch('bytes'), object_start, object_finish, "#{case_id} mark#{mark_index} ObjectStructure")
          object_prefix = parse_object_prefix!(object, "#{case_id} mark#{mark_index} ObjectStructure")
          fail!("#{case_id} mark#{mark_index} ObjectStructure extent differs") unless object_prefix.fetch('bytes_consumed') == object.bytesize
          { 'mark' => mark_index, 'dynamic' => dynamic, 'dynamic_interval' => [start, finish],
            'dynamic_bytes_hex' => shard.unpack1('H*'), 'object' => object_prefix,
            'object_interval' => [object_start, object_finish], 'mode_prefix_hex' => mode_bytes.unpack1('H*'),
            'mode' => mode_value, 'q_from_independent_summary' => Q_BY_MARK.fetch('dynamic_occurrences_by_mark').fetch(mark_index) }
        else
          trace_start = positions.fetch(mark_index).fetch(1)
          trace_finish = positions.fetch(mark_index + 1).fetch(0)
          parent = slice_exact!(decoded.fetch('bytes'), trace_start, trace_finish, "#{case_id} mark#{mark_index} MRK3 trace parent")
          object_prefix = parse_object_prefix!(parent, "#{case_id} mark#{mark_index} ObjectStructure")
          dynamic = parse_dynamic_prefix!(parent, object_prefix.fetch('bytes_consumed'), "#{case_id} mark#{mark_index} DynamicStructure")
          mode_start = object_prefix.fetch('bytes_consumed') + dynamic.fetch('bytes_consumed')
          mode_bytes = slice_exact!(parent, mode_start, mode_start + 8, "#{case_id} mark#{mark_index} mode prefix")
          mode_value = parse_mode_prefix!(mode_bytes, mode, "#{case_id} mark#{mark_index}")
          { 'mark' => mark_index, 'dynamic' => dynamic,
            'dynamic_interval_within_parent' => [trace_start + object_prefix.fetch('bytes_consumed'), trace_start + mode_start],
            'dynamic_bytes_hex' => parent.byteslice(object_prefix.fetch('bytes_consumed'), dynamic.fetch('bytes_consumed')).unpack1('H*'),
            'object' => object_prefix, 'trace_parent_interval' => [trace_start, trace_finish],
            'mode_prefix_hex' => mode_bytes.unpack1('H*'), 'mode' => mode_value,
            'extent_note' => 'MRK3 bounds the whole trace parent to the next global mark; Dynamic prefix is parsed by cursor, not treated as the whole parent.',
            'q_from_independent_summary' => Q_BY_MARK.fetch('dynamic_occurrences_by_mark').fetch(mark_index) }
        end
      end
      validate_prefix_schedule!(prefixes, case_id)

      {
        'mode' => mode,
        'mark_format' => mark_format,
        'string_profile' => profile,
        'part_path' => part_path,
        'part_inventory' => {
          'file_count' => inventory.fetch(:snapshot).fetch('file_count'),
          'total_bytes' => inventory.fetch(:snapshot).fetch('total_bytes'),
          'snapshot_sha256' => inventory.fetch(:snapshot).fetch('sha256'),
          'files' => inventory.fetch(:snapshot).fetch('files'),
        },
        'mark_geometry' => {
          'records' => marks.fetch('record_count'),
          'row_counts' => marks.fetch('row_counts'),
          'record_words' => marks.fetch('record_words'),
          'global_slot_count' => slots.size,
          'dynamic_structure_global_slot' => dynamic_index,
          'data_file_bytes' => data_compressed.bytesize,
          'data_file_sha256' => Digest::SHA256.hexdigest(data_compressed),
          'decoded_bytes' => decoded.fetch('bytes').bytesize,
          'decoded_sha256' => Digest::SHA256.hexdigest(decoded.fetch('bytes')),
          'frames' => decoded.fetch('frames'),
          'positions_by_mark' => positions,
        },
        'substream_roster' => substreams,
        'dynamic_prefixes' => prefixes,
        'q_scope' => 'Q values are checked from independent fixed SQL-summary literals; the prefix statistics are whole-part and are never used as mark Q.',
      }
    end

    def validate_part_path!(path, case_id)
      fail!("#{case_id} part path is not a regular directory") unless File.directory?(path) && !File.symlink?(path)
      actual = File.realpath(path)
      case_dir = File.realpath(File.join(@summary_root, 'cases', case_id))
      relative = Pathname.new(actual).relative_path_from(Pathname.new(case_dir)).to_s
      fail!("#{case_id} part path is outside its captured case directory") if relative.start_with?('..') || relative.start_with?(File::SEPARATOR)
      fail!("#{case_id} part name/path differs") unless File.basename(actual) == 'all_1_1_0'
      fail!("#{case_id} part directory nesting differs") unless relative.match?(%r{\Astore/store/[0-9a-f]{3}/[0-9a-f-]{36}/all_1_1_0\z})
    end

    def validate_sql_oracle!(cell, case_id)
      Q_BY_MARK.each do |key, expected|
        fail!("#{case_id} #{key} differs from independent SQL literal") unless cell.fetch(key) == expected
      end
      windows = cell.fetch('windows')
      expected_windows = {
        'full' => SQL_ROWS,
        'middle' => SQL_ROWS[2, 4],
        'last' => SQL_ROWS[6, 2],
        'eof' => [],
      }
      expected_windows.each do |name, rows|
        window = windows.fetch(name)
        fail!("#{case_id} #{name} observed rows differ from independent literal") unless window.fetch('signatures') == rows
        fail!("#{case_id} #{name} expected rows differ from independent literal") unless window.fetch('expected_signatures') == rows
        fail!("#{case_id} #{name} native_count differs") unless window.fetch('native_count') == rows.size
      end
      candidate = cell.fetch('structure_candidate')
      fail!("#{case_id} candidate roster/statistics differs") unless
        candidate.fetch('ordinary_roster') == ['UInt64'] &&
        candidate.fetch('canonical_variant_roster') == ['SharedVariant', 'UInt64'] &&
        candidate.fetch('full_statistics_counts_canonical_order') == [1, 2] &&
        candidate.fetch('shared_statistics') == [{'name' => 'String', 'count' => 1}]
      fail!("#{case_id} NULL/SharedVariant distinction differs") unless
        cell.fetch('null_vs_shared_variant') == 'NULL is distinct; NULL is not a SharedVariant arm'
    end

    def read_and_validate_inventory!(snapshot, part_path, case_id)
      entries = snapshot.fetch('files')
      fail!("#{case_id} inventory file count is outside bound") unless entries.size.between?(1, MAX_FILES_PER_PART)
      expected_names = entries.map { |entry| entry.fetch('relative_path') }
      fail!("#{case_id} inventory has duplicate paths") unless expected_names.uniq == expected_names
      fail!("#{case_id} inventory paths are not flat safe names") unless expected_names.all? { |name| name.match?(/\A[a-zA-Z0-9_.-]+\z/) && !name.start_with?('.') }
      actual_names = Dir.children(part_path).sort
      fail!("#{case_id} actual directory names differ from inventory") unless actual_names == expected_names.sort
      total = 0
      data = {}
      checked = entries.sort_by { |entry| entry.fetch('relative_path') }.map do |entry|
        name = entry.fetch('relative_path')
        path = File.join(part_path, name)
        stat = File.lstat(path)
        fail!("#{case_id} inventory entry #{name} is not a regular non-symlink file") unless stat.file? && !stat.symlink?
        fail!("#{case_id} inventory entry #{name} exceeds file bound") if stat.size > MAX_SINGLE_FILE_BYTES
        total += stat.size
        fail!("#{case_id} part exceeds total byte bound") if total > MAX_PART_BYTES
        bytes = read_bounded(path, MAX_SINGLE_FILE_BYTES, "#{case_id}/#{name}")
        sha = Digest::SHA256.hexdigest(bytes)
        fail!("#{case_id} inventory size differs for #{name}") unless bytes.bytesize == entry.fetch('bytes')
        fail!("#{case_id} inventory SHA-256 differs for #{name}") unless sha == entry.fetch('sha256')
        data[name] = bytes
        {'relative_path' => name, 'bytes' => bytes.bytesize, 'sha256' => sha}
      end
      fail!("#{case_id} part aggregate bytes differ") unless total == snapshot.fetch('total_bytes')
      aggregate = Digest::SHA256.hexdigest(checked.map do |entry|
        "#{entry.fetch('relative_path')}\0#{entry.fetch('bytes')}\0#{entry.fetch('sha256')}\n"
      end.join)
      fail!("#{case_id} part aggregate snapshot SHA differs") unless aggregate == snapshot.fetch('sha256')
      fail!("#{case_id} part file_count differs") unless checked.size == snapshot.fetch('file_count')
      data[:snapshot] = snapshot
      data
    end

    def validate_columns_file!(bytes, case_id)
      expected = "columns format version: 1\n2 columns:\n`pk` UInt64\n`trace` #{SCHEMA}\n"
      fail!("#{case_id} columns.txt differs from exact W257 schema") unless bytes == expected
    end

    def parse_substreams!(bytes, profile, case_id)
      lines = bytes.force_encoding(Encoding::UTF_8).lines(chomp: true)
      fail!("#{case_id} columns_substreams header differs") unless lines.shift == 'columns substreams version: 1' && lines.shift == '2 columns:'
      columns = []
      expected_trace = profile == 's0' ? MRK4_S0_TRACE_STREAMS : MRK4_S1_TRACE_STREAMS
      expected_counts = {'pk' => 1, 'trace' => expected_trace.size}
      2.times do |column_index|
        header = lines.shift
        match = /\A([0-9]+) substreams for column `([^`]+)`:\z/.match(header.to_s)
        fail!("#{case_id} malformed substream column header") unless match
        count = Integer(match[1], 10)
        name = match[2]
        expected_column = column_index.zero? ? 'pk' : 'trace'
        fail!("#{case_id} substream columns reordered") unless name == expected_column
        fail!("#{case_id} substream count is outside its bounded roster") unless count.between?(1, MAX_SUBSTREAMS_PER_COLUMN)
        fail!("#{case_id} substream count differs from the exact expected roster") unless count == expected_counts.fetch(name)
        streams = count.times.map do
          line = lines.shift
          fail!("#{case_id} malformed stream line") unless line && line.start_with?("\t")
          line.byteslice(1..)
        end
        fail!("#{case_id} duplicate substream names") unless streams.uniq == streams
        columns << {'column' => name, 'streams' => streams}
      end
      fail!("#{case_id} trailing columns_substreams records") unless lines.empty?
      fail!("#{case_id} exact W284 substream roster differs") unless
        columns == [{'column' => 'pk', 'streams' => ['pk']}, {'column' => 'trace', 'streams' => expected_trace}]
      {'columns' => columns, 'total_global_slots' => 1 + expected_trace.size}
    end

    def mrk4_slots(substreams)
      index = 0
      substreams.fetch('columns').flat_map do |column|
        column.fetch('streams').map do |stream|
          slot = {'column' => column.fetch('column'), 'stream_name' => stream, 'global_index' => index}
          index += 1
          slot
        end
      end
    end

    def parse_marks!(bytes, format, slots, case_id)
      words_per_record = format == 'mrk3' ? 5 : (2 * slots) + 1
      record_bytes = words_per_record * 8
      fail!("#{case_id} mark file has invalid length") unless bytes.bytesize.positive? && (bytes.bytesize % record_bytes).zero?
      records = bytes.unpack('Q<*').each_slice(words_per_record).map(&:dup)
      fail!("#{case_id} mark record count differs") unless records.size == 5
      rows = records.map(&:last)
      fail!("#{case_id} mark row geometry differs") unless rows == MARK_ROWS
      {'records' => records, 'record_count' => records.size, 'record_words' => words_per_record, 'row_counts' => rows,
       'bytes' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes)}
    end

    def decode_frames!(compressed, case_id)
      fail!("#{case_id} data.bin is empty") if compressed.empty?
      offset = 0
      decoded = String.new(encoding: Encoding::BINARY)
      frames = []
      while offset < compressed.bytesize
        fail!("#{case_id} frame count exceeds bound") if frames.size >= MAX_RAW_FRAME_COUNT
        remaining = compressed.bytesize - offset
        fail!("#{case_id} frame header truncated at #{offset}") if remaining < 25
        method = compressed.getbyte(offset + 16)
        fail!("#{case_id} unsupported compressed frame method 0x#{method.to_s(16)}") unless method == 0x82
        compressed_size = compressed.byteslice(offset + 17, 4).unpack1('V')
        decoded_size = compressed.byteslice(offset + 21, 4).unpack1('V')
        fail!("#{case_id} compressed frame payload size is invalid") if compressed_size < 9
        fail!("#{case_id} decoded frame size is outside bound") unless decoded_size.between?(1, MAX_RAW_FRAME_BYTES)
        fail!("#{case_id} aggregate decoded stream exceeds bound") if decoded_size > MAX_TOTAL_DECODED_BYTES - decoded.bytesize
        frame_end = offset + 16 + compressed_size
        fail!("#{case_id} frame extends beyond data.bin") if frame_end > compressed.bytesize
        payload_start = offset + 25
        payload_size = compressed_size - 9
        payload = compressed.byteslice(payload_start, payload_size)
        fail!("#{case_id} frame payload is truncated") unless payload && payload.bytesize == payload_size
        frame_output = decode_lz4_block!(payload, decoded_size, case_id)
        logical_start = decoded.bytesize
        decoded << frame_output
        frames << {
          'compressed_start' => offset,
          'compressed_end' => frame_end,
          'compressed_bytes' => frame_end - offset,
          'logical_start' => logical_start,
          'logical_end' => decoded.bytesize,
          'decoded_bytes' => decoded_size,
          'method' => method,
          'stored_16_byte_hash_recomputed' => false,
        }
        offset = frame_end
      end
      fail!("#{case_id} frame walk has trailing bytes") unless offset == compressed.bytesize
      {'bytes' => decoded, 'frames' => frames}
    end

    def decode_lz4_block!(input, expected_size, case_id)
      output = String.new(encoding: Encoding::BINARY)
      cursor = 0
      while cursor < input.bytesize
        token = input.getbyte(cursor)
        cursor += 1
        literal_length, cursor = lz4_length!(input, cursor, token >> 4, case_id)
        fail!("#{case_id} LZ4 literal overruns input") if literal_length > input.bytesize - cursor
        fail!("#{case_id} LZ4 literal overruns declared output") if literal_length > expected_size - output.bytesize
        output << input.byteslice(cursor, literal_length)
        cursor += literal_length
        break if cursor == input.bytesize
        fail!("#{case_id} LZ4 match offset is truncated") if input.bytesize - cursor < 2
        distance = input.getbyte(cursor) | (input.getbyte(cursor + 1) << 8)
        cursor += 2
        fail!("#{case_id} LZ4 match distance is invalid") if distance.zero? || distance > output.bytesize
        match_length, cursor = lz4_length!(input, cursor, token & 0x0f, case_id)
        match_length += 4
        fail!("#{case_id} LZ4 match overruns declared output") if match_length > expected_size - output.bytesize
        match_length.times { output << output.getbyte(output.bytesize - distance) }
      end
      fail!("#{case_id} LZ4 decoded length differs from frame header") unless output.bytesize == expected_size
      output
    end

    def lz4_length!(input, cursor, nibble, case_id)
      length = nibble
      return [length, cursor] unless length == 15
      loop do
        fail!("#{case_id} LZ4 extended length is truncated") if cursor >= input.bytesize
        byte = input.getbyte(cursor)
        cursor += 1
        length += byte
        fail!("#{case_id} LZ4 extended length exceeds frame bound") if length > MAX_RAW_FRAME_BYTES
        break if byte != 255
      end
      [length, cursor]
    end

    def logical_position!(coordinate, compressed_size, frames, decoded_size, case_id)
      compressed_offset, decompressed_offset = coordinate
      if compressed_offset == compressed_size
        fail!("#{case_id} terminal coordinate has nonzero decompressed offset") unless decompressed_offset.zero?
        return decoded_size
      end
      fail!("#{case_id} coordinate exceeds compressed data") if compressed_offset > compressed_size
      frame = frames.find { |candidate| candidate.fetch('compressed_start') == compressed_offset }
      fail!("#{case_id} compressed coordinate is not a frame start") unless frame
      fail!("#{case_id} decompressed coordinate exceeds frame") if decompressed_offset > frame.fetch('decoded_bytes')
      frame.fetch('logical_start') + decompressed_offset
    end

    def validate_terminal_and_rows!(marks, positions, compressed_size, decoded_size, case_id)
      fail!("#{case_id} final mark is not EOF for every global slot") unless positions.last.all? { |position| position == decoded_size }
      coordinates = marks.fetch('records').last[0...-1].each_slice(2).to_a
      fail!("#{case_id} terminal raw coordinates are not (data.bin bytes,0)") unless
        coordinates.all? { |coordinate| coordinate == [compressed_size, 0] }
    end

    def slice_exact!(bytes, start, finish, label)
      fail!("#{label} has invalid/reversed decoded interval") unless start && finish && start >= 0 && finish >= start && finish <= bytes.bytesize
      slice = bytes.byteslice(start, finish - start)
      fail!("#{label} decoded interval escaped data") unless slice && slice.bytesize == finish - start
      slice
    end

    def read_u64!(bytes, cursor, label)
      fail!("#{label} truncated UInt64 at byte #{cursor}") if cursor > bytes.bytesize - 8
      [bytes.byteslice(cursor, 8).unpack1('Q<'), cursor + 8]
    end

    def read_byte!(bytes, cursor, label)
      fail!("#{label} truncated byte at byte #{cursor}") if cursor >= bytes.bytesize
      [bytes.getbyte(cursor), cursor + 1]
    end

    def read_varuint!(bytes, cursor, label)
      result = 0
      shift = 0
      start = cursor
      loop do
        fail!("#{label} truncated VarUInt at byte #{cursor}") if cursor >= bytes.bytesize
        byte = bytes.getbyte(cursor)
        cursor += 1
        fail!("#{label} VarUInt overflows UInt64") if shift >= 64 || (shift == 63 && (byte & 0x7e) != 0)
        result |= (byte & 0x7f) << shift
        break if (byte & 0x80).zero?
        shift += 7
        fail!("#{label} VarUInt exceeds ten bytes") if cursor - start >= 10
      end
      fail!("#{label} VarUInt is non-canonical") if cursor - start > 1 && (bytes.getbyte(cursor - 1) & 0x7f).zero?
      [result, cursor]
    end

    def parse_object_prefix!(bytes, label)
      cursor = 0
      version, cursor = read_u64!(bytes, cursor, label)
      paths, cursor = read_varuint!(bytes, cursor, label)
      shared_data_version, cursor = read_varuint!(bytes, cursor, label)
      flag, cursor = read_byte!(bytes, cursor, label)
      fail!("#{label} Object V3 prefix header differs") unless version == 4 && paths.zero? && shared_data_version.zero? && [0, 1].include?(flag)
      shared_stats = nil
      if flag == 1
        shared_stats, cursor = read_varuint!(bytes, cursor, label)
        fail!("#{label} Object shared-data statistics differs") unless shared_stats.zero?
      end
      {
        'serialization_version' => version,
        'dynamic_path_count' => paths,
        'shared_data_serialization_version_observed' => shared_data_version,
        'statistics_flag' => flag,
        'shared_data_path_statistics_count' => shared_stats,
        'bytes_consumed' => cursor,
        'raw_prefix_hex' => bytes.byteslice(0, cursor).unpack1('H*'),
      }
    end

    def parse_dynamic_prefix!(bytes, offset, label)
      cursor = offset
      version, cursor = read_u64!(bytes, cursor, label)
      type_count, cursor = read_varuint!(bytes, cursor, label)
      fail!("#{label} Dynamic V3 version/type count differs") unless version == 4 && type_count == 1
      descriptors = type_count.times.map do
        descriptor, cursor = read_byte!(bytes, cursor, label)
        descriptor
      end
      fail!("#{label} Dynamic actual type descriptor differs from UInt64") unless descriptors == [0x04]
      statistics_flag, cursor = read_byte!(bytes, cursor, label)
      fail!("#{label} Dynamic statistics flag is not a boolean") unless [0, 1].include?(statistics_flag)
      variant_statistics = nil
      shared_statistics = nil
      if statistics_flag == 1
        variant_statistics = 2.times.map do
          count, cursor = read_varuint!(bytes, cursor, label)
          count
        end
        fail!("#{label} Dynamic whole-part variant statistics differ") unless variant_statistics == [1, 2]
        shared_count, cursor = read_varuint!(bytes, cursor, label)
        fail!("#{label} Dynamic shared statistics count differs") unless shared_count == 1
        name_length, cursor = read_varuint!(bytes, cursor, label)
        fail!("#{label} Dynamic shared type name length differs") unless name_length == 6 && name_length <= bytes.bytesize - cursor
        name = bytes.byteslice(cursor, name_length)
        cursor += name_length
        count, cursor = read_varuint!(bytes, cursor, label)
        fail!("#{label} Dynamic shared type statistics differ") unless name == 'String' && count == 1
        shared_statistics = [{'name' => name, 'count' => count}]
      end
      {
        'serialization' => 'Dynamic V3',
        'serialization_version' => version,
        'ordinary_type_count' => type_count,
        'ordinary_type_descriptor_hex' => descriptors.map { |value| '%02x' % value },
        'ordinary_roster' => ['UInt64'],
        'canonical_variant_roster' => ['SharedVariant', 'UInt64'],
        'statistics_flag' => statistics_flag,
        'variant_statistics_canonical_order' => variant_statistics && {'SharedVariant' => variant_statistics[0], 'UInt64' => variant_statistics[1]},
        'shared_statistics' => shared_statistics,
        'bytes_consumed' => cursor - offset,
        'raw_prefix_hex' => bytes.byteslice(offset, cursor - offset).unpack1('H*'),
      }
    end

    def parse_mode_prefix!(bytes, mode, label)
      fail!("#{label} Variant mode prefix length differs from eight bytes") unless bytes.bytesize == 8
      value = bytes.unpack1('Q<')
      expected = mode == 'basic' ? 0 : 1
      fail!("#{label} Variant discriminator mode differs") unless value == expected
      value
    end

    def validate_prefix_schedule!(prefixes, case_id)
      prefixes.each_with_index do |prefix, mark|
        dynamic = prefix.fetch('dynamic')
        expected_flag = mark.zero? ? 1 : 0
        fail!("#{case_id} Dynamic statistics PREFIX/PREFIX_EMPTY schedule differs at mark #{mark}") unless dynamic.fetch('statistics_flag') == expected_flag
        object_flag = prefix.fetch('object').fetch('statistics_flag')
        fail!("#{case_id} Object statistics PREFIX/PREFIX_EMPTY schedule differs at mark #{mark}") unless object_flag == expected_flag
      end
    end

    def run_negative_controls!(cells)
      coordinate_control = mrk4_coordinate_mutant!(cells.fetch('basic_mrk4_s0'))
      decoded_flag_controls = decoded_flag_mutants!(cells.fetch('basic_mrk4_s0'))
      [coordinate_control, *decoded_flag_controls]
    end

    def mrk4_coordinate_mutant!(cell)
      case_id = 'basic_mrk4_s0'
      part_path = File.realpath(cell.fetch('part').fetch('path'))
      snapshot = cell.fetch('part').fetch('snapshot')
      original = read_bounded(File.join(part_path, 'data.mrk4'), MAX_SINGLE_FILE_BYTES, 'negative-control data.mrk4')
      copy = original.dup
      width_words = (2 * (1 + MRK4_S0_TRACE_STREAMS.size)) + 1
      mark_index = 2
      dynamic_global_slot = 2 # pk=0, ObjectStructure=1, DynamicStructure=2 in captured roster.
      word_index = (mark_index * width_words) + (dynamic_global_slot * 2) + 1
      byte_offset = word_index * 8
      source_records = parse_marks!(original, 'mrk4', 1 + MRK4_S0_TRACE_STREAMS.size, 'coordinate-mutant-source').fetch('records')
      source_record = source_records.fetch(mark_index)
      before_coordinate = source_record.slice(dynamic_global_slot * 2, 2)
      fail!('coordinate mutant raw bytes differ from the parsed source coordinate') unless
        copy.byteslice(byte_offset - 8, 16).unpack('Q<2') == before_coordinate
      before_compressed, before_value = before_coordinate
      before_bytes = copy.byteslice(byte_offset, 8)
      copy[byte_offset, 8] = [before_value + 1].pack('Q<')
      fail!('coordinate mutant changed data.mrk4 length') unless copy.bytesize == original.bytesize
      mutated_records = parse_marks!(copy, 'mrk4', 1 + MRK4_S0_TRACE_STREAMS.size, 'coordinate-mutant').fetch('records')
      fail!('coordinate mutant changed mark row geometry') unless mutated_records.map(&:last) == MARK_ROWS
      fail!('coordinate mutant did not change exactly one raw byte') unless
        differing_offsets(original, copy) == [byte_offset]

      resealed = reseal_external_snapshot!(snapshot, 'data.mrk4', copy)
      verify_snapshot_override!(snapshot, resealed, part_path, 'data.mrk4', copy)
      caught = begin
        audit_cell_with_mark_override!(cell, case_id, copy)
        nil
      rescue AuditError => error
        error.message
      end
      fail!('MRK4 +1 coordinate mutant was accepted') unless caught
      {
        'id' => 'raw_mrk4_dynamic_coordinate_plus_one_with_test_manifest_reseal',
        'result' => 'rejected_as_required',
        'copy_scope' => 'in-memory duplicate of captured data.mrk4; immutable capture file was not changed',
        'case' => case_id,
        'mark_index' => mark_index,
        'dynamic_structure_global_slot' => dynamic_global_slot,
        'record_word_index' => word_index,
        'raw_file_byte_offset' => byte_offset,
        'coordinate_component' => 'decompressed_offset',
        'coordinate_before' => [before_compressed, before_value],
        'coordinate_after' => [before_compressed, before_value + 1],
        'changed_bytes' => [{'offset' => byte_offset, 'before_hex' => before_bytes.unpack1('H*'), 'after_hex' => copy.byteslice(byte_offset, 8).unpack1('H*')}],
        'file_length_unchanged' => original.bytesize == copy.bytesize,
        'row_geometry_unchanged' => mutated_records.map(&:last) == MARK_ROWS,
        'original_raw_sha256' => Digest::SHA256.hexdigest(original),
        'mutated_raw_sha256' => Digest::SHA256.hexdigest(copy),
        'test_only_external_manifest_resealed' => true,
        'original_inventory_sha256' => snapshot.fetch('sha256'),
        'resealed_inventory_sha256' => resealed.fetch('sha256'),
        'rejection' => caught,
        'cityhash_validation' => false,
      }
    end

    def reseal_external_snapshot!(snapshot, path, bytes)
      files = snapshot.fetch('files').map do |entry|
        if entry.fetch('relative_path') == path
          {'relative_path' => path, 'bytes' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes)}
        else
          entry.dup
        end
      end.sort_by { |entry| entry.fetch('relative_path') }
      aggregate = Digest::SHA256.hexdigest(files.map do |entry|
        "#{entry.fetch('relative_path')}\0#{entry.fetch('bytes')}\0#{entry.fetch('sha256')}\n"
      end.join)
      {'files' => files, 'total_bytes' => snapshot.fetch('total_bytes'), 'file_count' => snapshot.fetch('file_count'), 'sha256' => aggregate}
    end

    def verify_snapshot_override!(original_snapshot, resealed, part_path, override_name, override_bytes)
      expected = resealed.fetch('files')
      total = 0
      observed = expected.map do |entry|
        name = entry.fetch('relative_path')
        bytes = name == override_name ? override_bytes : read_bounded(File.join(part_path, name), MAX_SINGLE_FILE_BYTES, "manifest mutant #{name}")
        total += bytes.bytesize
        fail!('test-only manifest size mismatch') unless bytes.bytesize == entry.fetch('bytes')
        fail!('test-only manifest hash mismatch') unless Digest::SHA256.hexdigest(bytes) == entry.fetch('sha256')
        entry
      end
      fail!('test-only manifest total bytes differ') unless total == resealed.fetch('total_bytes')
      aggregate = Digest::SHA256.hexdigest(observed.map do |entry|
        "#{entry.fetch('relative_path')}\0#{entry.fetch('bytes')}\0#{entry.fetch('sha256')}\n"
      end.join)
      fail!('test-only external manifest reseal does not validate copied inventory') unless aggregate == resealed.fetch('sha256')
      fail!('test-only manifest unexpectedly equals original') if resealed.fetch('sha256') == original_snapshot.fetch('sha256')
    end

    def audit_cell_with_mark_override!(cell, case_id, mark_override)
      part_path = File.realpath(cell.fetch('part').fetch('path'))
      snapshot = cell.fetch('part').fetch('snapshot')
      inventory = read_and_validate_inventory_with_override!(snapshot, part_path, case_id, mark_override)
      # Re-run only the independent coordinate->prefix corridor under the test-only resealed inventory.
      data = decode_frames!(inventory.fetch('data.bin'), case_id)
      marks = parse_marks!(inventory.fetch('data.mrk4'), 'mrk4', 1 + MRK4_S0_TRACE_STREAMS.size, case_id)
      slots = mrk4_slots({'columns' => [{'column' => 'pk', 'streams' => ['pk']}, {'column' => 'trace', 'streams' => MRK4_S0_TRACE_STREAMS}]})
      positions = marks.fetch('records').map do |record|
        slots.map do |slot|
          i = slot.fetch('global_index') * 2
          logical_position!([record.fetch(i), record.fetch(i + 1)], inventory.fetch('data.bin').bytesize,
                            data.fetch('frames'), data.fetch('bytes').bytesize, case_id)
        end
      end
      4.times do |mark|
        dynamic_index = 2
        start = positions.fetch(mark).fetch(dynamic_index)
        finish = positions.fetch(mark).fetch(dynamic_index + 1)
        shard = slice_exact!(data.fetch('bytes'), start, finish, "#{case_id} mutant mark#{mark} DynamicStructure")
        dynamic = parse_dynamic_prefix!(shard, 0, "#{case_id} mutant mark#{mark} DynamicStructure")
        fail!('mutant DynamicStructure shard has trailing bytes') unless dynamic.fetch('bytes_consumed') == shard.bytesize
      end
    end

    def read_and_validate_inventory_with_override!(snapshot, part_path, case_id, mark_override)
      result = read_and_validate_inventory!(snapshot, part_path, case_id)
      result['data.mrk4'] = mark_override
      result
    end

    def decoded_flag_mutants!(cell)
      part_path = File.realpath(cell.fetch('part').fetch('path'))
      mark_bytes = read_bounded(File.join(part_path, 'data.mrk4'), MAX_SINGLE_FILE_BYTES, 'flag-mutant data.mrk4')
      records = parse_marks!(mark_bytes, 'mrk4', 1 + MRK4_S0_TRACE_STREAMS.size, 'flag-mutant').fetch('records')
      data = decode_frames!(read_bounded(File.join(part_path, 'data.bin'), MAX_SINGLE_FILE_BYTES, 'flag-mutant data.bin'), 'flag-mutant')
      slots = mrk4_slots({'columns' => [{'column' => 'pk', 'streams' => ['pk']}, {'column' => 'trace', 'streams' => MRK4_S0_TRACE_STREAMS}]})
      positions = records.map do |record|
        slots.map do |slot|
          i = slot.fetch('global_index') * 2
          logical_position!([record.fetch(i), record.fetch(i + 1)], File.size(File.join(part_path, 'data.bin')),
                            data.fetch('frames'), data.fetch('bytes').bytesize, 'flag-mutant')
        end
      end
      dyn_index = 2
      start0 = positions.fetch(0).fetch(dyn_index)
      end0 = positions.fetch(0).fetch(dyn_index + 1)
      later_start = positions.fetch(2).fetch(dyn_index)
      later_end = positions.fetch(2).fetch(dyn_index + 1)
      first = slice_exact!(data.fetch('bytes'), start0, end0, 'flag-control first prefix').dup
      later = slice_exact!(data.fetch('bytes'), later_start, later_end, 'flag-control later prefix').dup
      fail!('flag-control source first/later flags differ') unless first.getbyte(10) == 1 && later.getbyte(10) == 0

      first[10] = "\0".b
      first_rejection = rejection_for(first) { |raw| parse_exact_dynamic_shard!(raw, 'decoded first-flag 1-to-0') }
      fail!('decoded first flag 1-to-0 mutant was accepted') unless first_rejection
      later[10] = "\1".b
      later_rejection = rejection_for(later) { |raw| parse_exact_dynamic_shard!(raw, 'decoded later-flag 0-to-1') }
      fail!('decoded later flag 0-to-1 mutant was accepted') unless later_rejection
      invalid_boolean = slice_exact!(data.fetch('bytes'), start0, end0, 'flag-control invalid-boolean source').dup
      invalid_boolean[10] = "\3".b
      invalid_rejection = rejection_for(invalid_boolean) { |raw| parse_exact_dynamic_shard!(raw, 'decoded invalid-boolean flag') }
      fail!('decoded invalid boolean flag mutant was accepted') unless invalid_rejection

      [
        {
          'id' => 'decoded_first_prefix_statistics_flag_1_to_0',
          'result' => 'rejected_as_required',
          'input_layer' => 'decoded captured-prefix buffer only; no raw mark/data file changed',
          'raw_file_or_checksum_claim' => false,
          'changed_byte' => {'offset_within_prefix' => 10, 'before_hex' => '01', 'after_hex' => '00'},
          'rejection' => first_rejection,
          'interpretation' => 'The empty-prefix alternative is syntactically available, but it fails this exact first-mark full-prefix shard extent/policy.',
        },
        {
          'id' => 'decoded_later_prefix_statistics_flag_0_to_1',
          'result' => 'rejected_as_required',
          'input_layer' => 'decoded captured-prefix buffer only; no raw mark/data file changed',
          'raw_file_or_checksum_claim' => false,
          'changed_byte' => {'offset_within_prefix' => 10, 'before_hex' => '00', 'after_hex' => '01'},
          'rejection' => later_rejection,
          'interpretation' => 'The full-statistics grammar requires fields absent from this exact later-prefix shard.',
        },
        {
          'id' => 'decoded_dynamic_statistics_flag_invalid_boolean_1_to_3',
          'result' => 'rejected_as_required',
          'input_layer' => 'decoded captured-prefix buffer only; no raw mark/data file changed',
          'raw_file_or_checksum_claim' => false,
          'changed_byte' => {'offset_within_prefix' => 10, 'before_hex' => '01', 'after_hex' => '03'},
          'rejection' => invalid_rejection,
          'interpretation' => 'Closed Dynamic V3 prefix parser rejects a non-boolean statistics flag.',
        },
      ]
    end

    def parse_exact_dynamic_shard!(bytes, label)
      parsed = parse_dynamic_prefix!(bytes, 0, label)
      fail!("#{label} has trailing bytes") unless parsed.fetch('bytes_consumed') == bytes.bytesize
      parsed
    end

    def rejection_for(bytes)
      yield bytes
      nil
    rescue AuditError => error
      error.message
    end

    def differing_offsets(left, right)
      fail!('negative-control copy length differs') unless left.bytesize == right.bytesize
      left.bytes.each_index.select { |index| left.getbyte(index) != right.getbyte(index) }
    end

    def source_anchors
      {
        'compact_writer_first_and_later_prefix_policy' => 'Pinned source MergeTreeDataPartWriterCompact.cpp:190-205 selects PREFIX_EMPTY when !is_first_granule; :380-383 passes !data_written; :395-396 records the first granule. Source SHA-256 0b551c2e4efe5638fc734f854e45d78beab342ce43fffd464b6196d1eeff2072.',
        'dynamic_v3_prefix' => 'SerializationDynamic.cpp:197-205 writes selected UInt64LE structure version; :242-268 writes actual ordinary type count and encoded types; :270-314 writes full/empty V3 statistics flag and statistics.',
        'dynamic_canonical_variant_order' => 'ColumnDynamic.cpp:80-83 seeds SharedVariant as the sole arm; :1627-1633 places SharedVariant at index 0 before selected ordinary variants. SerializationDynamic.cpp:283-288 emits statistics in variant_info.variant_names order.',
        'variant_mode_prefix' => 'SerializationVariant.cpp:199-212 writes an eight-byte little-endian BASIC/COMPACT discriminator mode.',
        'object_v3_prefix' => 'SerializationObject.cpp:393-428 writes dynamic paths/shared-data serialization version; :432-477 writes full/empty prefix statistics.',
        'recursive_prefix_propagation' => 'SerializationArray.cpp:297-305 and SerializationTuple.cpp:794-805 forward state-prefix calls to nested serializers.',
        'source_runtime_relation' => 'The source Git revision and full runtime executable are separately pinned; this audit does not assert that the source produced the executable.',
      }
    end

    def write_report!(content)
      fail!('report path appeared during audit; refusing overwrite') if File.exist?(@report_path) || File.symlink?(@report_path)
      File.open(@report_path, File::WRONLY | File::CREAT | File::EXCL, OUTPUT_PERMISSION) do |file|
        file.write(content)
        file.flush
      end
    end
  end

  # Stable composition entry point for the future W284 interop driver. It
  # returns one independently audited capture cell as JSON-safe data and does
  # not write a report or launch a native process.
  def self.audit_case(summary_path:, case_id:)
    Auditor.new(summary_path: summary_path, report_path: REPORT_DEFAULT).audit_case(case_id: case_id)
  end
end

def main
  options = {
    summary_path: AuditCompactRecursiveDynamicW284Capture::SUMMARY_DEFAULT,
    report_path: AuditCompactRecursiveDynamicW284Capture::REPORT_DEFAULT,
  }
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/audit_compact_recursive_dynamic_w284_capture.rb [--summary SUMMARY_JSON] [--output REPORT_JSON]'
    parser.on('--summary PATH', 'Immutable stock capture summary JSON') { |value| options[:summary_path] = value }
    parser.on('--output PATH', 'New report path directly under W284/reports') { |value| options[:report_path] = value }
  end.parse!
  AuditCompactRecursiveDynamicW284Capture::Auditor.new(**options).run
rescue StandardError => error
  warn "W284 audit runner error: #{error.class}: #{error.message}"
  exit 1
end

main if $PROGRAM_NAME == __FILE__
