#!/usr/bin/env ruby
# W276 stock-first native compatibility probe for propagated String1 in
# ordinary static Compact columns. Native SQL literals are deliberately
# independent of the Crystal helper and local spec fixture.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require_relative 'probe_compact_part_writer_w273'

module ProbeCompactStringWriterW276
  W273 = ProbeCompactPartWriterW273
  W271 = W273::W271
  W241 = W271::W241

  FORMAT = 'compact_string_writer_w276_native_probe_v1'.freeze
  HELPER_FORMAT = 'compact_string_writer_w276_helper_v1'.freeze
  PART_NAME = 'all_1_1_0'.freeze
  BINARY = W271::BINARY
  BINARY_SHA256 = W271::BINARY_SHA256
  VERSION = W271::VERSION
  BUILD = W271::BUILD
  SOURCE_ROOT = W271::SOURCE_ROOT
  SOURCE_REVISION = W271::SOURCE_REVISION
  SOURCE_FILES = (W271::SOURCE_FILES + %w[
    src/Columns/ColumnString.h
    src/DataTypes/DataTypeString.cpp
    src/DataTypes/DataTypeLowCardinality.cpp
    src/DataTypes/Serializations/SerializationString.cpp
    src/DataTypes/Serializations/SerializationLowCardinality.cpp
    src/DataTypes/Serializations/ISerialization.cpp
    src/DataTypes/Serializations/SerializationArray.cpp
    src/DataTypes/Serializations/SerializationTuple.cpp
    src/DataTypes/Serializations/SerializationNamed.cpp
    src/DataTypes/Serializations/SerializationNullable.cpp
    src/DataTypes/DataTypeTuple.cpp
  ]).uniq.freeze

  HELPER_SOURCE = File.expand_path('compact_string_writer_w276_helper.cr', __dir__).freeze
  PROBE_SOURCE = File.expand_path(__FILE__).freeze
  W241_SOURCE = File.expand_path('probe_object_shared_json_interop_w241.rb', __dir__).freeze
  W271_SOURCE = File.expand_path('probe_compact_part_writer_w271.rb', __dir__).freeze
  W273_SOURCE = File.expand_path('probe_compact_part_writer_w273.rb', __dir__).freeze
  W264_SOURCE = File.expand_path('probe_compact_part_writer_w264.rb', __dir__).freeze
  W264_FIXTURE_SOURCE = File.expand_path('../spec/support/compact_part_writer_w264_fixture.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('../spec/support/compact_part_writer_w276_fixture.cr', __dir__).freeze

  ROWS_PER_MARK = 2
  ROW_COUNT = 8
  DATA_MARK_COUNT = 4
  PHYSICAL_MARK_ROWS_WITH_EOF = [2, 2, 2, 2, 0].freeze
  WRITER_MARK_ROWS = [2, 2, 2, 2].freeze
  MAX_PART_FILES = 160
  MAX_PART_BYTES = 64 * 1024 * 1024
  MAX_RAW_FILE_BYTES = 16 * 1024 * 1024
  MAX_REPORT_BYTES = 4 * 1024 * 1024
  MARK_FORMATS = %w[mrk3 mrk4].freeze
  MARK_COMPRESSION = %w[plain compressed].freeze
  WINDOWS = {
    'full' => nil,
    'middle' => 'pk BETWEEN 103 AND 106',
    'eof' => 'pk > 108',
  }.freeze
  PHYSICAL_WINDOWS = {
    'full' => [0, 4].freeze,
    'middle' => [1, 2].freeze,
    'eof' => [4, 0].freeze,
  }.freeze
  SCHEMA = [
    ['pk', 'UInt64'], ['u', 'UInt64'], ['text', 'String'],
    ['maybe', 'Nullable(UInt64)'], ['gap', 'Array(Nullable(UInt64))'],
    ['arr', 'Array(Nullable(UInt64))'], ['pair', 'Tuple(String,Nullable(UInt64))'],
    ['lookup', 'Map(String,UInt64)'], ['string_array', 'Tuple(items Array(Nullable(String)))'],
    ['lc_text', 'LowCardinality(String)'], ['variant_text', 'Variant(String,UInt64)'],
  ].map(&:freeze).freeze
  VALUE_COLUMNS = SCHEMA.drop(1).map(&:first).freeze

  # Independent stock/native oracle. The added String containers intentionally
  # include empty values, NUL, invalid UTF-8 bytes, repeated LC dictionary
  # values, NULL, and a mark with zero String-array child occurrences.
  ROWS = [
    {pk: 101, u: 0, maybe: nil, text: ''.b, gap: [], arr: [], pair: ['a'.b, 0], map: [],
     string_array: [], lc_text: ''.b, variant: [:string, ''.b]},
    {pk: 102, u: 1, maybe: 0, text: 'alpha'.b, gap: [], arr: [nil], pair: ['b'.b, nil], map: [['alpha'.b, 1]],
     string_array: [''.b], lc_text: ''.b, variant: [:uint64, 0]},
    {pk: 103, u: 18_446_744_073_709_551_615, maybe: 1, text: "utf8-λ".b, gap: [0, 7], arr: [0, nil, 5],
     pair: ['c'.b, 3], map: [], string_array: [nil, "nullable\0tail".b],
     lc_text: ['00ff8041'].pack('H*'), variant: [:string, ['00ff8041'].pack('H*')]},
    {pk: 104, u: 42, maybe: nil, text: "contains\0nul".b, gap: [], arr: [], pair: [''.b, nil],
     map: [['zero'.b, 0], ['max'.b, 99]], string_array: [], lc_text: "lc\0nul".b, variant: nil},
    {pk: 105, u: 9_007_199_254_740_993, maybe: 50, text: ['00ff8041'].pack('H*'), gap: [nil, 9], arr: [50],
     pair: ['tuple-tail'.b, 9], map: [['one'.b, 7]], string_array: [], lc_text: 'repeat'.b,
     variant: [:uint64, 42]},
    {pk: 106, u: 7, maybe: 42, text: ('crystal-' * 1024).b, gap: [], arr: [nil, 0],
     pair: ["λ".b, 1], map: [], string_array: [], lc_text: 'repeat'.b,
     variant: [:string, ('long:' + ('x' * 256)).b]},
    {pk: 107, u: 123_456_789, maybe: nil, text: 'tail'.b, gap: [42], arr: [42, 42, 42],
     pair: ["NUL\0key".b, 42], map: [['left'.b, 4], ['right'.b, 9]],
     string_array: [('long:' + ('x' * 256)).b], lc_text: ''.b, variant: nil},
    {pk: 108, u: 108, maybe: 7, text: 'last'.b, gap: [], arr: [1],
     pair: ['last'.b, 0], map: [['last'.b, 108]], string_array: [['00ff8041'].pack('H*')],
     lc_text: 'tail'.b, variant: [:string, "variant\0tail".b]},
  ].map(&:freeze).freeze

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, source_root:, evidence_root:, stock_only: true, full_matrix: false,
                   helper: nil, helper_sha256: nil)
      @binary = validate_executable(binary, 'pinned ClickHouse runtime')
      @source_root = File.expand_path(source_root)
      fail!('source root differs from the separately pinned upstream checkout') unless @source_root == SOURCE_ROOT
      @stock_only = stock_only
      @full_matrix = full_matrix
      fail!('select exactly one of --stock-only or --full-matrix') unless @stock_only != @full_matrix
      @helper = nil
      @helper_expected_sha = nil
      if @full_matrix
        @helper = validate_executable(helper, 'prebuilt W276 helper')
        @helper_expected_sha = helper_sha256
        fail!('--helper-sha256 must be a lowercase SHA-256') unless @helper_expected_sha&.match?(/\A[0-9a-f]{64}\z/)
      end
      @root = validate_root(evidence_root)
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @invocations = []
      @expected_processes = {}
      @runner = W241::Probe.allocate
      @runner.instance_variable_set(:@binary, @binary)
      @runner.instance_variable_set(:@root, @root)
      @runner.instance_variable_set(:@invocations, @invocations)
      @stock = {}
      @generated = {}
      validate_literals!
    end

    def run
      prepare!
      cells = MARK_FORMATS.product(MARK_COMPRESSION)
      cells.each { |mark, compression| @stock["#{mark}_#{compression}"] = capture_stock!(mark, compression) }
      unless @stock_only
        # Native independent parts and their exact value oracle are complete
        # before the first Crystal helper process is allowed to run.
        @stock.each { |id, entry| capture_stock_local_reads!("stock_#{id}", entry) }
        cells.each { |mark, compression| @generated["#{mark}_#{compression}"] = capture_generated!(mark, compression) }
      end
      validate_process_evidence!
      validate_pins!
      summary = build_summary
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), render_summary(summary))
      puts "W276 status=#{summary.fetch(:status)}; stock=#{@stock.size}; generated=#{@generated.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W276 probe inconclusive: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise Failure, "W276: #{message}"
    end

    def validate_root(path)
      fail!('evidence root is required') unless path && !path.empty?
      expanded = File.expand_path(path)
      fail!('evidence root must be a direct child of /private/tmp') unless File.dirname(expanded) == File.realpath('/private/tmp')
      fail!('evidence root must be canonical, non-symlinked, and empty') unless
        !File.symlink?(expanded) && File.directory?(expanded) && File.realpath(expanded) == expanded && Dir.children(expanded).empty?
      expanded
    rescue Errno::ENOENT
      fail!('evidence root and /private/tmp must already exist')
    end

    def validate_executable(path, label)
      fail!("#{label} path is absent") unless path && !path.empty?
      expanded = File.expand_path(path)
      fail!("#{label} is absent, non-executable, or symlinked") unless
        File.file?(expanded) && File.executable?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      expanded
    end

    def prepare!
      %w[invocations stores source-inventories raw-records parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      @binary_sha_before = sha(@binary)
      fail!('ClickHouse executable differs from pinned runtime SHA-256') unless @binary_sha_before == BINARY_SHA256
      revision, stderr, status = Open3.capture3('git', '-C', @source_root, 'rev-parse', 'HEAD')
      fail!("pinned upstream source revision check failed: #{stderr.strip}") unless status.success? && revision.strip == SOURCE_REVISION
      @upstream_hashes = SOURCE_FILES.to_h do |relative|
        path = File.join(@source_root, relative)
        fail!("pinned upstream source is missing or symlinked: #{relative}") unless File.file?(path) && !File.symlink?(path)
        [relative, sha(path)]
      end
      @source_guard = source_guard!
      @probe_sources = [PROBE_SOURCE, HELPER_SOURCE, W241_SOURCE, W271_SOURCE, W273_SOURCE, W264_SOURCE,
                        W264_FIXTURE_SOURCE, FIXTURE_SOURCE].map { |path| File.realpath(path) }.uniq.sort
      @probe_hashes_before = @probe_sources.to_h { |path| [path, sha(path)] }
      if @full_matrix
        @helper_sha_before = sha(@helper)
        fail!('prebuilt W276 helper SHA differs from CLI pin') unless @helper_sha_before == @helper_expected_sha
      end
    end

    def validate_literals!
      fail!('literal oracle must contain eight ordered rows and four two-row data marks') unless
        ROWS.size == ROW_COUNT && ROWS.each_slice(ROWS_PER_MARK).to_a.size == DATA_MARK_COUNT &&
        ROWS.map { |row| row.fetch(:pk) } == (101..108).to_a
      fail!('W276 fixture types/column order differ from the fixed native oracle') unless
        SCHEMA.map(&:first) == ['pk'] + VALUE_COLUMNS && VALUE_COLUMNS == %w[u text maybe gap arr pair lookup string_array lc_text variant_text]
      fail!('the zero-child String-array mark witness changed') unless ROWS[4..5].all? { |row| row.fetch(:string_array).empty? }
      true
    end

    def source_guard!
      read = lambda do |relative|
        path = File.join(@source_root, relative)
        File.binread(path).force_encoding(Encoding::UTF_8)
      end
      column_string = read.call('src/Columns/ColumnString.h')
      data_type_string = read.call('src/DataTypes/DataTypeString.cpp')
      low_cardinality = read.call('src/DataTypes/Serializations/SerializationLowCardinality.cpp')
      string_serialization = read.call('src/DataTypes/Serializations/SerializationString.cpp')
      generic_serialization = read.call('src/DataTypes/Serializations/ISerialization.cpp')
      array_serialization = read.call('src/DataTypes/Serializations/SerializationArray.cpp')
      tuple_serialization = read.call('src/DataTypes/Serializations/SerializationTuple.cpp')
      named_serialization = read.call('src/DataTypes/Serializations/SerializationNamed.cpp')
      nullable_serialization = read.call('src/DataTypes/Serializations/SerializationNullable.cpp')
      tuple_type = read.call('src/DataTypes/DataTypeTuple.cpp')
      string_with_size = string_serialization.split('void SerializationString::enumerateStreamsWithSize(', 2)[1].to_s
      string_size_push = string_with_size.index('settings.path.push_back(Substream::StringSizes);')
      string_size_callback = string_size_push && string_with_size.index('callback(settings.path);', string_size_push)
      string_regular_path = string_size_callback && string_with_size.index('settings.path.back() = Substream::Regular;', string_size_callback)
      string_data_callback = string_regular_path && string_with_size.index('callback(settings.path);', string_regular_path)
      array_sizes_push = array_serialization.index('settings.path.push_back(Substream::ArraySizes);')
      array_sizes_callback = array_sizes_push && array_serialization.index('callback(settings.path);', array_sizes_push)
      array_elements_path = array_sizes_callback && array_serialization.index('settings.path.back() = Substream::ArrayElements;', array_sizes_callback)
      array_nested_enumeration = array_elements_path && array_serialization.index('nested->enumerateStreams(settings, callback, next_data);', array_elements_path)
      nullable_map_push = nullable_serialization.index('settings.path.push_back(hide_null_map_subcolumn ? Substream::NullMapHidden : Substream::NullMap);')
      nullable_map_callback = nullable_map_push && nullable_serialization.index('callback(settings.path);', nullable_map_push)
      nullable_elements_path = nullable_map_callback && nullable_serialization.index('settings.path.push_back(Substream::NullableElements);', nullable_map_callback)
      nullable_nested_enumeration = nullable_elements_path && nullable_serialization.index('nested->enumerateStreams(settings, callback, next_data);', nullable_elements_path)
      named_enumeration_push = named_serialization.index('addToPath(settings.path);')
      named_nested_enumeration = named_enumeration_push && named_serialization.index('nested_serialization->enumerateStreams(settings, callback, data);', named_enumeration_push)
      named_enumeration_pop = named_nested_enumeration && named_serialization.index('settings.path.pop_back();', named_nested_enumeration)
      facts = {
        column_string_allows_embedded_nul_and_is_not_terminated: column_string.include?('strings are not zero-terminated and could contain zero bytes'),
        column_string_insert_copies_exact_length: column_string.include?('const size_t new_size = old_size + length;') &&
          column_string.include?('memcpy(chars.data() + old_size, pos, length);') && column_string.include?('offsets.push_back(new_size);'),
        datatype_string_uses_selected_string_serialization_version: data_type_string.include?('SerializationString::create(settings.string_serialization_version)'),
        string1_serializes_per_row_sizes_and_exact_data_extent: string_serialization.include?('serializeStringSizes(column, *size_stream, offset, limit);') &&
          string_serialization.include?('size_t bytes = end - begin;') && string_serialization.include?('stream->write(reinterpret_cast<const char *>(&column_string.getChars()[begin]), bytes);'),
        string1_enumerates_size_before_regular_data: string_size_push && string_size_callback && string_regular_path && string_data_callback,
        low_cardinality_dictionary_uses_default_string_serialization: low_cardinality.include?('nested_serialization(dictionary_type_->getDefaultSerialization())') &&
          low_cardinality.include?('dict_inner_serialization(removeNullable(dictionary_type_)->getDefaultSerialization())'),
        tuple_element_separator_is_escaped_for_compatibility: generic_serialization.include?('For compatibility reasons, we use %2E (escaped dot) instead of dot.') &&
          generic_serialization.include?('if (it->type == Substream::TupleElement && escape_for_file_name)') &&
          generic_serialization.include?('stream_name += escapeForFileName(substream_name);'),
        unnamed_tuple_fields_use_one_based_named_elements: tuple_type.include?('String elem_name = has_explicit_names ? names[i] : toString(i + 1);') &&
          tuple_type.include?('SerializationNamed::create(serialization, elem_name, SubstreamType::TupleElement)') &&
          named_serialization.include?('path.push_back(substream_type);') &&
          named_serialization.include?('path.back().name_of_substream = name;') &&
          named_enumeration_push && named_nested_enumeration && named_enumeration_pop &&
          tuple_serialization.include?('elems[i]->enumerateStreams(settings, callback, next_data);'),
        tuple_array_sizes_are_emitted_before_nested_array_elements: array_sizes_push && array_sizes_callback &&
          array_elements_path && array_nested_enumeration,
        array_size_path_suffix_is_appended_after_escaped_tuple_element: generic_serialization.include?("else if (it->type == Substream::ArraySizes)\n            stream_name += \".size\" + toString(array_level);") &&
          generic_serialization.include?('if (it->type == Substream::TupleElement && escape_for_file_name)'),
        nullable_map_precedes_nested_element_streams: nullable_map_push && nullable_map_callback &&
          nullable_elements_path && nullable_nested_enumeration,
      }
      fail!("pinned source compatibility guard failed: #{facts.inspect}") unless facts.values.all?
      facts.merge(
        low_cardinality_scope: 'LowCardinality dictionary and inner serializer use their type default; this does not assert a String1 dictionary stream',
        string_extent_scope: 'String data bytes use actual logical lengths including zero for empty and embedded NUL bytes; no implicit trailing NUL is part of the String value',
      )
    end

    def validate_pins!
      @binary_sha_after = sha(@binary)
      @probe_hashes_after = @probe_sources.to_h { |path| [path, sha(path)] }
      fail!('ClickHouse runtime changed during capture') unless @binary_sha_after == BINARY_SHA256
      fail!('probe, helper source, or fixture changed during capture') unless @probe_hashes_after == @probe_hashes_before
      if @full_matrix
        @helper_sha_after = sha(@helper)
        fail!('prebuilt W276 helper changed during capture') unless @helper_sha_after == @helper_sha_before
      end
    end

    def sha(path)
      Digest::SHA256.file(path).hexdigest
    end

    def write_new(path, bytes)
      fail!('evidence record exceeds the fixed report bound') if bytes.bytesize > MAX_REPORT_BYTES
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    def store_path(name)
      fail!('unsafe store name') unless name.match?(/\A[a-z0-9_.-]+\z/)
      path = File.join(@root, 'stores', name)
      Dir.mkdir(path, 0o700) unless Dir.exist?(path)
      fail!("store path is symlinked or noncanonical: #{path}") if File.symlink?(path) || File.realpath(path) != path
      path
    end

    def native(label, store, sql)
      pinned_sql = [@runner.send(:pin_sql), sql].join("\n")
      argv = [@binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
              "--max_memory_usage=#{W241::MEMORY}", '--multiquery']
      register_expected!(label, argv, pinned_sql.b, 'clickhouse-local', @binary, BINARY_SHA256, store)
      result = @runner.send(:native, label, store, pinned_sql)
      record = result.fetch(:record)
      fail!("#{label} timed out or had process infrastructure failure") unless
        !record[:timed_out] && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
        record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && result[:status] && result[:status].termsig.nil?
      fail!("#{label} native process was not successful: #{record.inspect}") unless
        result[:classification] == 'success' && result[:status].success?
      @runner.send(:assert_native_success!, result, label)
      @runner.send(:assert_pin!, result[:stdout], label)
      result
    end

    def helper(label, *arguments)
      argv = [@helper] + arguments
      register_expected!(label, argv, ''.b, 'crystal-helper', @helper, @helper_sha_before, nil)
      result = @runner.send(:run_process, label, argv, ''.b, 'crystal-helper',
                            expected_sha: @helper_sha_before, binary_path: @helper)
      record = result.fetch(:record)
      fail!("#{label} helper did not complete as a bounded process") unless
        !record[:timed_out] && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
        record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && result[:status] && result[:status].termsig.nil?
      fail!("#{label} helper failed: #{record.inspect}") unless
        result[:classification] == 'success' && result[:status].success? && result[:stderr].empty?
      JSON.parse(result[:stdout].dup.force_encoding(Encoding::UTF_8))
    rescue JSON::ParserError => error
      fail!("#{label} helper stdout is not JSON: #{error.message}")
    end

    def register_expected!(label, argv, input, kind, binary_path, expected_sha, store)
      fail!("duplicate or unsafe process label #{label.inspect}") unless label.match?(/\A[a-z0-9_.-]+\z/) && !@expected_processes.key?(label)
      @expected_processes[label] = {
        argv: argv, stdin: input, process_kind: kind, binary_path: binary_path,
        expected_sha256: expected_sha, store_path: store,
      }
    end

    def validate_process_evidence!
      fail!('process invocation roster differs from registered commands') unless @invocations.map { |item| item.fetch(:label) }.sort == @expected_processes.keys.sort
      expected_files = []
      @invocations.each do |record|
        label = record.fetch(:label)
        expected = @expected_processes.fetch(label)
        base = File.join(@root, 'invocations')
        argv_bytes = JSON.pretty_generate(expected.fetch(:argv)) + "\n"
        stdin_name = "#{label}.stdin.#{expected.fetch(:process_kind) == 'clickhouse-local' ? 'sql' : 'bin'}"
        argv_name = "#{label}.argv.json"
        stdout_name = "#{label}.stdout"
        stderr_name = "#{label}.stderr"
        record_name = "#{label}.json"
        expected_files.concat([stdin_name, argv_name, stdout_name, stderr_name, record_name])
        fail!("#{label} argv identity differs") unless record.fetch(:argv) == expected.fetch(:argv) &&
          File.binread(File.join(base, argv_name)) == argv_bytes && record.fetch(:argv_sha256) == Digest::SHA256.hexdigest(argv_bytes)
        stdin = File.binread(File.join(base, stdin_name))
        fail!("#{label} stdin identity differs") unless stdin == expected.fetch(:stdin) &&
          record.fetch(:stdin_bytes) == stdin.bytesize && record.fetch(:stdin_sha256) == Digest::SHA256.hexdigest(stdin)
        stdout = File.binread(File.join(base, stdout_name))
        stderr = File.binread(File.join(base, stderr_name))
        fail!("#{label} stdout/stderr sidecar identity differs") unless
          record.fetch(:stdout_bytes) == stdout.bytesize && record.fetch(:stdout_sha256) == Digest::SHA256.hexdigest(stdout) &&
          record.fetch(:stderr_bytes) == stderr.bytesize && record.fetch(:stderr_sha256) == Digest::SHA256.hexdigest(stderr)
        fail!("#{label} process status or binary identity differs") unless
          record.fetch(:process_kind) == expected.fetch(:process_kind) && record.fetch(:binary_path) == expected.fetch(:binary_path) &&
          record.fetch(:expected_binary_sha256) == expected.fetch(:expected_sha256) &&
          record.fetch(:binary_sha_before) == expected.fetch(:expected_sha256) &&
          record.fetch(:binary_sha_after) == expected.fetch(:expected_sha256) && record.fetch(:exit) == 0 &&
          record.fetch(:signal).nil? && !record.fetch(:timed_out) && record.fetch(:spawn_error).nil? &&
          record.fetch(:stdin_write_error).nil? && record.fetch(:stdout_read_error).nil? && record.fetch(:stderr_read_error).nil? &&
          record.fetch(:process_classification) == 'success' && stderr.empty?
        saved_record = JSON.parse(File.binread(File.join(base, record_name)))
        fail!("#{label} persisted process record differs") unless saved_record == JSON.parse(JSON.generate(record))
      end
      fail!('invocation sidecar directory has unexpected files') unless Dir.children(File.join(@root, 'invocations')).sort == expected_files.sort
      true
    end

    def native_lines(result, label)
      text = result.fetch(:stdout).dup.force_encoding(Encoding::UTF_8)
      fail!("#{label} stdout is not newline-terminated UTF-8") unless text.valid_encoding? && text.end_with?("\n")
      lines = text.lines.map(&:chomp)
      pins = lines.select { |line| line.start_with?("__W241_PIN__\t") }
      fail!("#{label} runtime version/build pin differs") unless pins == ["__W241_PIN__\t#{VERSION}\t#{BUILD}"]
      lines
    end

    def tagged(lines, tag, width, label)
      rows = lines.select { |line| line.start_with?(tag + "\t") }.map do |line|
        fields = line.split("\t", -1)
        fail!("#{label} malformed tagged TSV row") unless fields.size == width
        fields
      end
      rows
    end

    def marker(kind, id, window = nil)
      suffix = window ? "_#{window.upcase}" : ''
      "__W276_#{kind.to_s.upcase}_#{id.upcase}#{suffix}__"
    end

    def normalize_type(value)
      value.gsub(/\s+/, '')
    end

    def settings(mark_format, compression, profile: 'with_size_stream')
      substream_marks = mark_format == 'mrk4' ? 1 : 0
      compress_marks = compression == 'compressed' ? 1 : 0
      [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=104857600', 'min_level_for_wide_part=0',
        "compress_marks=#{compress_marks}", "marks_compression_codec='LZ4'", 'compress_primary_key=0',
        "write_marks_for_substreams_in_compact_parts=#{substream_marks}", 'min_compress_block_size=0',
        'max_compress_block_size=4096', 'ratio_of_defaults_for_sparse_serialization=1.0',
        "default_compression_codec='LZ4'", "serialization_info_version='with_types'",
        'propagate_types_serialization_versions_to_nested_types=true', "string_serialization_version='#{profile}'",
        "nullable_serialization_version='basic'", "map_serialization_version='basic'",
        "map_serialization_version_for_zero_level_parts='basic'", 'allow_suspicious_low_cardinality_types=1',
      ].join(', ')
    end

    def table_name(id)
      "w276_#{@token}_#{id}"
    end

    def create_sql(table, mark_format, compression, profile: 'with_size_stream')
      declarations = SCHEMA.map { |name, type| "`#{name}` #{type}" }.join(', ')
      "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(mark_format, compression, profile: profile)};\n"
    end

    def sql_bytes(value)
      "unhex('#{value.b.unpack1('H*')}')"
    end

    def sql_nullable_u64(value)
      value.nil? ? "CAST(NULL, 'Nullable(UInt64)')" : "toUInt64(#{value})"
    end

    def sql_u64_array(values)
      return "CAST([], 'Array(Nullable(UInt64))')" if values.empty?
      "[#{values.map { |value| sql_nullable_u64(value) }.join(', ')}]"
    end

    def sql_string_array(values)
      return "CAST([], 'Array(Nullable(String))')" if values.empty?
      children = values.map do |value|
        value.nil? ? "CAST(NULL, 'Nullable(String)')" : sql_bytes(value)
      end
      "CAST([#{children.join(', ')}], 'Array(Nullable(String))')"
    end

    def sql_map(values)
      return "CAST([], 'Map(String, UInt64)')" if values.empty?
      "map(#{values.flat_map { |key, number| [sql_bytes(key), "toUInt64(#{number})"] }.join(', ')})"
    end

    def sql_variant(value)
      cast = case value
             when nil then "CAST(NULL, 'Variant(String, UInt64)')"
             when Array
               arm, payload = value
               source = arm == :string ? sql_bytes(payload) : "toUInt64(#{payload})"
               "CAST(#{source}, 'Variant(String, UInt64)')"
             else raise Failure, 'W276: variant oracle has an unsupported arm'
             end
      cast
    end

    def insert_sql(table)
      values = ROWS.map do |row|
        tuple = "tuple(#{sql_bytes(row.fetch(:pair)[0])}, #{sql_nullable_u64(row.fetch(:pair)[1])})"
        ["toUInt64(#{row.fetch(:pk)})", "toUInt64(#{row.fetch(:u)})", sql_bytes(row.fetch(:text)),
         sql_nullable_u64(row.fetch(:maybe)), sql_u64_array(row.fetch(:gap)), sql_u64_array(row.fetch(:arr)),
         tuple, sql_map(row.fetch(:map)), "tuple(#{sql_string_array(row.fetch(:string_array))})",
         "CAST(#{sql_bytes(row.fetch(:lc_text))}, 'LowCardinality(String)')", sql_variant(row.fetch(:variant))]
      end
      "INSERT INTO default.#{table} VALUES\n#{values.map { |row| "(#{row.join(', ')})" }.join(",\n")};\n"
    end

    def capture_stock!(mark_format, compression)
      id = "stock_#{mark_format}_#{compression}"
      table = table_name(id)
      store = store_path(id)
      create = native("#{id}_create_insert", store,
                      create_sql(table, mark_format, compression) + insert_sql(table))
      stage = inspect_native_part!(id, table, store, mark_format, compression)
      check = check!(id, table, store)
      values = native_values!(id, table, store)
      fail!("#{id} native independent literal oracle differs") unless values.fetch(:state) == 'exact_values'
      stage.merge(create_insert: create.fetch(:record), check: check, native_values: values)
    end

    def inspect_native_part!(id, table, store, mark_format, compression)
      schema_tag = marker('schema', id)
      part_tag = marker('part', id)
      table_path_tag = marker('table_path', id)
      sql = "SELECT '#{schema_tag}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT '#{part_tag}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts " \
        "WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;\n" \
        "SELECT '#{table_path_tag}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
      result = native("#{id}_schema_part", store, sql)
      lines = native_lines(result, "#{id} schema/part")
      schema = tagged(lines, schema_tag, 3, id).map { |row| [row[1], normalize_type(row[2])] }
      expected_schema = SCHEMA.map { |name, type| [name, normalize_type(type)] }
      fail!("#{id} native schema/type/order differs: #{schema.inspect}") unless schema == expected_schema
      part_rows = tagged(lines, part_tag, 7, id)
      expected_marks = PHYSICAL_MARK_ROWS_WITH_EOF.size.to_s # Four data marks plus the native EOF mark.
      fail!("#{id} is not one Compact part with the expected row/mark count") unless part_rows.size == 1 &&
        part_rows.first.values_at(1, 2, 4, 5, 6) == [table, PART_NAME, 'Compact', ROW_COUNT.to_s, expected_marks]
      table_paths = tagged(lines, table_path_tag, 2, id)
      fail!("#{id} table data path is not unique") unless table_paths.size == 1 && !table_paths.first[1].empty?
      table_path = safe_native_path(table_paths.first[1], store, "#{id} table")
      path = safe_native_path(part_rows.first.fetch(3), store, "#{id} part")
      fail!("#{id} native part path is not directly inside its table data path") unless File.dirname(path) == table_path
      selected_mark = mark_filename(mark_format, compression)
      fail!("#{id} expected mark file missing or wrong") unless File.file?(File.join(path, selected_mark))
      fail!("#{id} has an unexpected alternate mark file") if %w[data.mrk3 data.mrk4 data.cmrk3 data.cmrk4].any? { |name| name != selected_mark && File.exist?(File.join(path, name)) }
      inventory = tree_inventory(path)
      roster = native_callback_roster!(id, path, mark_format)
      assert_stock_callback_profile!(id, mark_format, roster)
      metadata = serialization_metadata!(id, path, expected_profile: 'with_size_stream')
      snapshot = save_part_snapshot!(id, path, inventory, roster, metadata)
      fail!("#{id} stock part changed during capture") unless tree_inventory(path) == inventory
      {
        origin: 'independent literal SQL INSERT into a fresh pinned ClickHouse table',
        table: table, store: store, table_data_path: table_path, path: path, schema: schema, part_row: part_rows.first,
        mark_format: mark_format, compression: compression, mark_file: selected_mark,
        part_inventory: inventory, callback_roster: roster, serialization_metadata: metadata,
        evidence_snapshot: snapshot, schema_part_invocation: result.fetch(:record),
      }
    end

    def mark_filename(mark_format, compression)
      prefix = compression == 'compressed' ? 'data.cmrk' : 'data.mrk'
      "#{prefix}#{mark_format.delete_prefix('mrk')}"
    end

    def native_callback_roster!(id, part, mark_format)
      if mark_format == 'mrk3'
        roster = SCHEMA.each_with_index.map { |(column, _), index| [index, column, nil] }
        return {state: 'mrk3_single_unlabelled_slot_per_column', sections: nil, roster: roster, sha256: nil}
      end
      path = File.join(part, 'columns_substreams.txt')
      fail!("#{id} MRK4 callback roster missing or symlinked") unless File.file?(path) && !File.symlink?(path) && File.size(path) <= MAX_RAW_FILE_BYTES
      text = File.binread(path).force_encoding(Encoding::UTF_8)
      lines = text.split("\n", -1)
      fail!("#{id} callback roster is not newline-terminated UTF-8") unless text.valid_encoding? && lines.pop == ''
      fail!("#{id} callback roster version differs") unless lines.shift == 'columns substreams version: 1'
      header = /\A(0|[1-9][0-9]*) columns:\z/.match(lines.shift.to_s)
      fail!("#{id} callback roster column count differs") unless header && header[1].to_i == SCHEMA.size
      sections = []
      until lines.empty?
        match = /\A(0|[1-9][0-9]*) substreams for column `([a-z][a-z0-9_]*)`:\z/.match(lines.shift.to_s)
        fail!("#{id} malformed callback section") unless match
        count = Integer(match[1], 10)
        fail!("#{id} callback count exceeds bound") unless count <= 512 && lines.size >= count
        streams = count.times.map do
          entry = /\A\t([A-Za-z0-9_.%]+)\z/.match(lines.shift.to_s)
          fail!("#{id} malformed physical callback name") unless entry
          entry[1]
        end
        fail!("#{id} duplicate callback in one column") unless streams.uniq == streams
        sections << [match[2], streams]
      end
      fail!("#{id} callback columns differ from literal schema order") unless sections.map(&:first) == SCHEMA.map(&:first)
      fail!("#{id} callback roster includes an empty serializer") unless sections.all? { |_, streams| !streams.empty? }
      flattened = sections.flat_map { |column, streams| streams.map { |stream| [column, stream] } }
      {
        state: 'native_substream_callback_roster_observed', text: text,
        sections: sections,
        roster: flattened.each_with_index.map { |(column, stream), index| [index, column, stream] },
        sha256: Digest::SHA256.hexdigest(text),
        lc_dictionary_string_size_callbacks: sections.find { |column, _| column == 'lc_text' }&.last&.grep(/string_sizes/)&.size || 0,
      }
    end

    def assert_stock_callback_profile!(id, mark_format, roster)
      if mark_format == 'mrk3'
        expected = SCHEMA.each_with_index.map { |(column, _), index| [index, column, nil] }
        fail!("#{id} MRK3 native roster is not one whole-column slot per declaration") unless roster.fetch(:roster) == expected
        return true
      end

      sections = roster.fetch(:sections).to_h
      fail!("#{id} String1 root callbacks differ") unless sections.fetch('text') == %w[text.size text]
      fail!("#{id} escaped named-Tuple/String-array callbacks differ") unless
        sections.fetch('string_array') == [
          'string_array%2Eitems.size0', 'string_array%2Eitems.null', 'string_array%2Eitems.size', 'string_array%2Eitems',
        ]
      fail!("#{id} pair Tuple first String1 callbacks differ") unless
        sections.fetch('pair').first(2) == %w[pair%2E1.size pair%2E1]
      fail!("#{id} LowCardinality String0 dictionary callbacks differ") unless
        sections.fetch('lc_text') == %w[lc_text.dict_prefix lc_text.dict lc_text] &&
        sections.fetch('lc_text').none? { |stream| stream.include?('.size') || stream.include?('string_sizes') }
      variant = sections.fetch('variant_text')
      fail!("#{id} Variant String1 arm callbacks differ") unless
        variant.include?('variant_text.String.size') && variant.include?('variant_text.String')
      true
    end

    def serialization_metadata!(id, part, expected_profile:)
      path = File.join(part, 'serialization.json')
      fail!("#{id} serialization metadata missing, symlinked, or oversized") unless
        File.file?(path) && !File.symlink?(path) && File.size(path) <= MAX_RAW_FILE_BYTES
      raw = File.binread(path)
      metadata = JSON.parse(raw)
      versions = metadata.fetch('types_serialization_versions')
      expected_string_version = expected_profile == 'with_size_stream' ? 1 : 0
      fail!("#{id} serialization.json is not profile String#{expected_string_version} with propagation") unless
        metadata.fetch('version') == 1 && versions.fetch('string') == expected_string_version &&
        metadata.fetch('propagate_types_serialization_versions_to_nested_types') == true
      {
        raw: raw, raw_sha256: Digest::SHA256.hexdigest(raw),
        version: metadata.fetch('version'), types_serialization_versions: versions,
        string_version: versions.fetch('string'),
        propagate_types_serialization_versions_to_nested_types: metadata.fetch('propagate_types_serialization_versions_to_nested_types'),
        serializer_records: metadata.fetch('columns'),
        low_cardinality_record: metadata.fetch('columns').find { |entry| entry['name'] == 'lc_text' },
      }
    rescue JSON::ParserError, KeyError => error
      fail!("#{id} serialization.json is malformed: #{error.message}")
    end

    def safe_native_path(raw, store, label)
      fail!("#{label} native path is not absolute") unless raw.is_a?(String) && raw.start_with?(File::SEPARATOR)
      path = raw.end_with?(File::SEPARATOR) ? raw[0...-1] : raw
      root = File.realpath(store)
      fail!("#{label} path escaped its isolated store") unless path.start_with?(root + File::SEPARATOR)
      fail!("#{label} path is not canonical") unless
        File.expand_path(path) == path && File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      path
    rescue Errno::ENOENT, Errno::EACCES => error
      fail!("#{label} native path validation failed: #{error.class}: #{error.message}")
    end

    def tree_inventory(path)
      files = []
      total = 0
      Find.find(path) do |entry|
        next if entry == path
        stat = File.lstat(entry)
        fail!("symlink in part tree: #{entry}") if stat.symlink?
        next if stat.directory?
        fail!("non-regular part file: #{entry}") unless stat.file?
        fail!('part file-count bound exceeded') if files.size >= MAX_PART_FILES
        total += stat.size
        fail!('part byte bound exceeded') if total > MAX_PART_BYTES
        files << {path: entry.delete_prefix(path + File::SEPARATOR), size: stat.size, sha256: sha(entry)}
      end
      {files: files.sort_by { |item| item.fetch(:path) }, total_bytes: total}
    end

    def save_part_snapshot!(id, path, inventory, roster, metadata)
      safe = id.gsub(/[^a-zA-Z0-9_.-]/, '_')
      write_new(File.join(@root, 'source-inventories', "#{safe}.json"), JSON.pretty_generate(
        case_name: id, source_part_path: path, inventory: inventory,
        callback_roster: roster, serialization_metadata: metadata,
      ) + "\n")
      write_new(File.join(@root, 'source-inventories', "#{safe}.columns_substreams.txt"), roster.fetch(:text)) if roster[:text]
      inventory.fetch(:files).each do |entry|
        name = entry.fetch(:path)
        fail!("unsafe nested raw file path #{name.inspect}") unless name.match?(/\A[a-zA-Z0-9_.-]+\z/)
        source = File.join(path, name)
        fail!("#{id} raw sidecar exceeds capture limit: #{name}") if File.size(source) > MAX_RAW_FILE_BYTES
        write_new(File.join(@root, 'raw-records', "#{safe}.#{name}"), File.binread(source))
      end
      {inventory_file: "source-inventories/#{safe}.json", callback_roster_file: roster[:text] ? "source-inventories/#{safe}.columns_substreams.txt" : nil,
       raw_prefix: "raw-records/#{safe}.", inventory: inventory}
    end

    def check!(id, table, store)
      begin_tag = marker('check_begin', id)
      end_tag = marker('check_end', id)
      sql = "SELECT '#{begin_tag}' FORMAT TSVRaw;\nCHECK TABLE default.#{table} FORMAT TSV;\nSELECT '#{end_tag}' FORMAT TSVRaw;\n"
      result = native("#{id}_check", store, sql)
      lines = native_lines(result, "#{id} CHECK")
      start = lines.index(begin_tag)
      ending = lines.index(end_tag)
      body = start && ending && ending > start ? lines[(start + 1)...ending] : nil
      fail!("#{id} CHECK did not report exactly one healthy Compact part: #{body.inspect}") unless body == ["#{PART_NAME}\t1\t"]
      {state: 'healthy', rows: body, invocation: result.fetch(:record)}
    end

    def expected_native_rows(window)
      selected = case window
                 when 'full' then ROWS
                 when 'middle' then ROWS[2, 4]
                 when 'eof' then []
                 else fail!("unknown native window #{window}")
                 end
      selected.map do |row|
        [row.fetch(:pk).to_s, row.fetch(:u).to_s, row.fetch(:text).unpack1('H*'),
         row.fetch(:maybe).nil? ? 'NULL' : row.fetch(:maybe).to_s,
         row.fetch(:gap), row.fetch(:arr), row.fetch(:pair)[0].unpack1('H*'),
         row.fetch(:pair)[1].nil? ? 'NULL' : row.fetch(:pair)[1].to_s,
         row.fetch(:map).map { |key, _| key.force_encoding(Encoding::UTF_8) }, row.fetch(:map).map { |_, value| value },
         row.fetch(:string_array).map { |value| value.nil? ? 'N' : "V#{value.unpack1('H*')}" },
         row.fetch(:lc_text).unpack1('H*'), variant_type(row), variant_string_hex(row), variant_uint64(row)]
      end
    end

    def variant_type(row)
      value = row.fetch(:variant)
      value.nil? ? 'None' : (value[0] == :string ? 'String' : 'UInt64')
    end

    def variant_string_hex(row)
      value = row.fetch(:variant)
      value && value[0] == :string ? value[1].unpack1('H*') : '-'
    end

    def variant_uint64(row)
      value = row.fetch(:variant)
      value && value[0] == :uint64 ? value[1].to_s : '-'
    end

    def decode_hex_json(value, label)
      fail!("#{label} is not an even-length hex sequence") unless value.match?(/\A(?:[0-9a-fA-F]{2})*\z/)
      JSON.parse([value].pack('H*'))
    rescue JSON::ParserError => error
      fail!("#{label} contains malformed JSON: #{error.message}")
    end

    def decode_string_array_tokens(value, label)
      tokens = decode_hex_json(value, label)
      fail!("#{label} is not a JSON array") unless tokens.is_a?(Array)
      tokens.each_with_index.map do |token, index|
        fail!("#{label}[#{index}] is not a token string") unless token.is_a?(String)
        if token == 'N'
          'N'
        elsif token.match?(/\AV(?:[0-9a-fA-F]{2})*\z/)
          "V#{token[1..].downcase}"
        else
          fail!("#{label}[#{index}] is not a valid N or V-even-hex token")
        end
      end
    end

    def parse_native_value_row(fields, label)
      fail!("#{label} row has the wrong width") unless fields.size == 16
      [fields[1], fields[2], fields[3].downcase, fields[4],
       decode_hex_json(fields[5], "#{label}/gap"), decode_hex_json(fields[6], "#{label}/arr"),
       fields[7].downcase, fields[8], decode_hex_json(fields[9], "#{label}/map keys"),
       decode_hex_json(fields[10], "#{label}/map values"), decode_string_array_tokens(fields[11], "#{label}/String array"),
       fields[12].downcase, fields[13], fields[14].downcase, fields[15]]
    end

    def values_sql(table, id, window)
      tag = marker('values', id, window)
      if window == 'eof'
        return "SELECT '#{tag}', toString(count()) FROM default.#{table} WHERE #{WINDOWS.fetch(window)} FORMAT TSVRaw;\n"
      end
      predicate = WINDOWS.fetch(window)
      where = predicate ? " WHERE #{predicate}" : ''
      string_array = "hex(toJSONString(arrayMap(w276_s -> if(isNull(w276_s), 'N', concat('V', hex(w276_s))), tupleElement(string_array, 1))))"
      variant_kind = 'variantType(variant_text)'
      fields = [
        "'#{tag}'", 'toString(pk)', 'toString(u)', 'hex(text)',
        "if(isNull(maybe), 'NULL', toString(maybe))", 'hex(toJSONString(gap))', 'hex(toJSONString(arr))',
        'hex(tupleElement(pair, 1))', "if(isNull(tupleElement(pair, 2)), 'NULL', toString(tupleElement(pair, 2)))",
        'hex(toJSONString(mapKeys(lookup)))', 'hex(toJSONString(mapValues(lookup)))', string_array, 'hex(lc_text)',
        variant_kind,
        "if(#{variant_kind} = 'String', hex(variantElement(variant_text, 'String')), '-')",
        "if(#{variant_kind} = 'UInt64', toString(variantElement(variant_text, 'UInt64')), '-')",
      ]
      "SELECT #{fields.join(', ')} FROM default.#{table}#{where} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def native_values!(id, table, store)
      sql = WINDOWS.keys.map { |window| values_sql(table, id, window) }.join
      result = native("#{id}_values", store, sql)
      lines = native_lines(result, "#{id} full/middle/EOF values")
      observations = {}
      WINDOWS.each_key do |window|
        tag = marker('values', id, window)
        if window == 'eof'
          rows = tagged(lines, tag, 2, "#{id}/#{window}")
          expected = [[tag, '0']]
          fail!("#{id} EOF query differs: #{rows.inspect}") unless rows == expected
          observations[window] = {state: 'exact_values', rows: [], count: 0, raw_rows: rows}
        else
          rows = tagged(lines, tag, 16, "#{id}/#{window}")
          actual = rows.map { |fields| parse_native_value_row(fields, "#{id}/#{window}") }
          expected = expected_native_rows(window)
          fail!("#{id} #{window} native raw/type signature differs") unless actual == expected
          observations[window] = {state: 'exact_values', rows: actual, raw_rows: rows}
        end
      end
      {state: 'exact_values', windows: observations, invocation: result.fetch(:record)}
    end

    def capture_stock_local_reads!(id, stock)
      report = helper("#{id}_helper_audit", 'audit', stock.fetch(:path))
      validate_helper_report!(report, id, 'audit', 0, DATA_MARK_COUNT, stock)
      middle = helper("#{id}_helper_middle", 'read', stock.fetch(:path), '1', '2')
      validate_helper_report!(middle, id, 'read', 1, 2, stock)
      eof = helper("#{id}_helper_eof", 'read', stock.fetch(:path), '4', '0')
      validate_helper_report!(eof, id, 'read', 4, 0, stock)
      stock[:local_reader] = {audit: report, middle: middle, eof: eof,
                              claim: 'Crystal typed reader observations are compared to the independent Ruby/native literal oracle'}
      stock
    end

    def validate_helper_report!(report, id, action, first_mark, count, stock, candidate_mark: nil)
      fail!("#{id} helper report format/action/status differs") unless report.fetch('format') == HELPER_FORMAT &&
        report.fetch('action') == action && report.fetch('status') == 'ok'
      fail!("#{id} helper physical window differs") unless report.fetch('first_mark') == first_mark && report.fetch('selected_mark_count') == count
      fail!("#{id} helper row/mark metadata differs") unless report.fetch('row_count') == ROW_COUNT &&
        report.fetch('data_mark_count') == DATA_MARK_COUNT && report.fetch('mark_row_counts') == WRITER_MARK_ROWS
      fail!("#{id} helper profile metadata is not propagated String1") unless
        report.dig('serialization_metadata', 'version') == 1 && report.dig('serialization_metadata', 'string_version') == 1 &&
        report.dig('serialization_metadata', 'propagate_types_serialization_versions_to_nested_types') == true
      expected_keys = ROWS[(first_mark * ROWS_PER_MARK), count * ROWS_PER_MARK].map { |row| row.fetch(:pk) }
      fail!("#{id} helper typed key values differ") unless report.fetch('keys') == expected_keys
      columns = report.fetch('columns')
      fail!("#{id} helper returned an incomplete or reordered typed column roster") unless columns.map { |column| column.fetch('name') } == VALUE_COLUMNS
      columns.each do |column|
        name = column.fetch('name')
        fail!("#{id}/#{name} helper declaration differs") unless normalize_type(column.fetch('type')) == normalize_type(SCHEMA.find { |entry| entry.first == name }.last)
        expected_signatures = expected_helper_signatures(name).drop(first_mark * ROWS_PER_MARK).take(count * ROWS_PER_MARK)
        fail!("#{id}/#{name} typed raw signature differs from the independent fixture oracle") unless column.fetch('signatures') == expected_signatures
        fail!("#{id}/#{name} does not report all four data marks excluding EOF") unless column.fetch('marks') == WRITER_MARK_ROWS
      end
      roster = normalize_helper_roster(report.fetch('physical_roster'))
      if candidate_mark == 'mrk4'
        fail!("#{id} generated callback roster differs from the matching native MRK4 table") unless roster == stock.fetch(:callback_roster).fetch(:roster)
      elsif candidate_mark == 'mrk3'
        fail!("#{id} generated MRK3 roster is not one unlabelled slot per declared column") unless
          roster == SCHEMA.each_with_index.map { |(name, _), index| [index, name, nil] }
      elsif stock.fetch(:mark_format) == 'mrk4'
        fail!("#{id} stock local callback roster differs from captured native MRK4") unless roster == stock.fetch(:callback_roster).fetch(:roster)
      else
        fail!("#{id} stock local MRK3 roster is not one unlabelled slot per declared column") unless
          roster == SCHEMA.each_with_index.map { |(name, _), index| [index, name, nil] }
      end
      if stock && candidate_mark.nil?
        observed = report.fetch('files').map { |file| [file.fetch('path'), file.fetch('size'), file.fetch('sha256')] }.sort
        expected = stock.fetch(:part_inventory).fetch(:files).map { |file| [file.fetch(:path), file.fetch(:size), file.fetch(:sha256)] }.sort
        fail!("#{id} helper part inventory differs from captured bytes") unless observed == expected
      end
      report
    end

    def normalize_helper_roster(roster)
      fail!('helper physical roster is malformed') unless roster.is_a?(Array)
      roster.each_with_index.map do |slot, index|
        fail!('helper physical roster indices are not contiguous') unless slot.fetch('index') == index
        [slot.fetch('index'), slot.fetch('column'), slot['stream']]
      end
    end

    def capture_generated!(mark_format, compression)
      id = "generated_#{mark_format}_#{compression}"
      part = File.join(@root, 'parts', id, PART_NAME)
      Dir.mkdir(File.dirname(part), 0o700)
      report = helper("#{id}_writer", 'write', part, mark_format, compression == 'plain' ? 'compressed0' : 'compressed1', 'profile1')
      check_helper_write!(report, id, part, mark_format, compression)
      inventory = tree_inventory(part)
      helper_files = report.fetch('files').map { |file| [file.fetch('path'), file.fetch('size'), file.fetch('sha256')] }.sort
      fail!("#{id} writer/helper inventory differs from filesystem") unless helper_files == inventory.fetch(:files).map { |file| [file.fetch(:path), file.fetch(:size), file.fetch(:sha256)] }.sort
      native_roster = @stock.fetch("#{mark_format}_#{compression}").fetch(:callback_roster)
      write_snapshot = save_part_snapshot!(id, part, inventory, native_roster, report.fetch('serialization_metadata'))
      full = report
      validate_helper_report!(full, id, 'write', 0, DATA_MARK_COUNT, {callback_roster: native_roster, part_inventory: inventory}, candidate_mark: mark_format)
      middle = helper("#{id}_helper_middle", 'read', part, '1', '2')
      validate_helper_report!(middle, id, 'read', 1, 2, {callback_roster: native_roster}, candidate_mark: mark_format)
      eof = helper("#{id}_helper_eof", 'read', part, '4', '0')
      validate_helper_report!(eof, id, 'read', 4, 0, {callback_roster: native_roster}, candidate_mark: mark_format)

      target = create_target!(id, mark_format, compression)
      attached = attach_candidate!(id, part, inventory, target)
      check = check!("#{id}_attached", target.fetch(:table), target.fetch(:store))
      active = inspect_attached_part!(id, target.fetch(:table), target.fetch(:store), mark_format, compression, inventory)
      values = native_values!("#{id}_attached", target.fetch(:table), target.fetch(:store))
      fail!("#{id} attached native exact values differ") unless values.fetch(:state) == 'exact_values'
      fail!("#{id} source candidate changed during attach/check/read") unless tree_inventory(part) == inventory
      {
        origin: 'Crystal-generated Compact part read by Crystal, copied to detached, then ATTACH/CHECK/native literal windows',
        path: part, mark_format: mark_format, compression: compression,
        helper_write: full, helper_middle: middle, helper_eof: eof,
        part_inventory: inventory, evidence_snapshot: write_snapshot,
        native_target: target, attach: attached, native_check: check,
        active_part: active, native_values: values,
      }
    end

    def check_helper_write!(report, id, part, mark_format, compression)
      fail!("#{id} write helper report differs") unless report.fetch('format') == HELPER_FORMAT &&
        report.fetch('action') == 'write' && report.fetch('status') == 'ok' && report.fetch('part_path') == part &&
        report.fetch('requested_mark_format') == mark_format && report.fetch('mark_format') == mark_format &&
        report.fetch('requested_compress_marks') == (compression == 'compressed') && report.fetch('requested_profile') == 'profile1'
    end

    def create_target!(id, mark_format, compression)
      table = table_name("target_#{id}")
      store = store_path("target_#{id}")
      path_tag = marker('data_path', id)
      schema_tag = marker('schema', id)
      sql = create_sql(table, mark_format, compression) +
        "SELECT '#{schema_tag}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT '#{path_tag}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
      result = native("#{id}_target_create", store, sql)
      lines = native_lines(result, "#{id} target creation")
      schema = tagged(lines, schema_tag, 3, id).map { |row| [row[1], normalize_type(row[2])] }
      fail!("#{id} target schema differs") unless schema == SCHEMA.map { |name, type| [name, normalize_type(type)] }
      paths = tagged(lines, path_tag, 2, id)
      fail!("#{id} target path is not unique") unless paths.size == 1 && !paths.first[1].empty?
      data_path = File.expand_path(paths.first[1])
      fail!("#{id} target data path escaped the isolated store") unless data_path.start_with?(File.realpath(store) + File::SEPARATOR)
      fail!("#{id} target data path is not a canonical non-symlink directory") unless
        File.directory?(data_path) && !File.symlink?(data_path) && File.realpath(data_path) == data_path
      {table: table, store: store, data_path: data_path, create: result.fetch(:record)}
    end

    def attach_candidate!(id, part, inventory, target)
      @runner.send(:attach_part!, part, target.fetch(:data_path))
      detached = File.join(target.fetch(:data_path), 'detached', PART_NAME)
      detached_inventory = tree_inventory(detached)
      fail!("#{id} detached copy differs from immutable candidate") unless detached_inventory == inventory
      result = native("#{id}_attach", target.fetch(:store), "ALTER TABLE default.#{target.fetch(:table)} ATTACH PART '#{PART_NAME}';\n")
      {state: 'attached', invocation: result.fetch(:record), source_inventory: inventory, detached_inventory: detached_inventory}
    end

    def inspect_attached_part!(id, table, store, mark_format, compression, source_inventory)
      schema_tag = marker('active_schema', id)
      part_tag = marker('active_part', id)
      table_path_tag = marker('active_table_path', id)
      sql = "SELECT '#{schema_tag}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT '#{part_tag}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;\n" \
        "SELECT '#{table_path_tag}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
      result = native("#{id}_active_part", store, sql)
      lines = native_lines(result, "#{id} attached part")
      schema = tagged(lines, schema_tag, 3, id).map { |row| [row[1], normalize_type(row[2])] }
      fail!("#{id} attached active schema differs") unless schema == SCHEMA.map { |name, type| [name, normalize_type(type)] }
      parts = tagged(lines, part_tag, 7, id)
      fail!("#{id} attached candidate is not one Compact eight-row part") unless parts.size == 1 &&
        parts.first.values_at(1, 2, 4, 5) == [table, PART_NAME, 'Compact', ROW_COUNT.to_s] &&
        parts.first[6] == PHYSICAL_MARK_ROWS_WITH_EOF.size.to_s
      table_paths = tagged(lines, table_path_tag, 2, id)
      fail!("#{id} attached table data path is not unique") unless table_paths.size == 1 && !table_paths.first[1].empty?
      table_path = safe_native_path(table_paths.first[1], store, "#{id} table")
      path = safe_native_path(parts.first.fetch(3), store, "#{id} part")
      fail!("#{id} attached part path is not directly inside its table data path") unless File.dirname(path) == table_path
      attached = attached_inventory!(id, path, source_inventory)
      {part_row: parts.first, table_data_path: table_path, path: path, schema: schema, inventory: attached.fetch(:inventory),
       native_owned_sidecar: attached.fetch(:native_owned_sidecar), invocation: result.fetch(:record)}
    end

    def attached_inventory!(id, active_path, source_inventory)
      active_inventory = tree_inventory(active_path)
      source = source_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      active = active_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      fail!("#{id} ATTACH changed or removed candidate files") unless source.all? { |name, entry| active[name] == entry }
      extras = active.keys - source.keys
      fail!("#{id} ATTACH added unexpected sidecars: #{extras.inspect}") unless extras == ['invalidated_system_columns.txt']
      sidecar_path = File.join(active_path, 'invalidated_system_columns.txt')
      sidecar_bytes = File.binread(sidecar_path)
      sidecar_text = sidecar_bytes.dup.force_encoding(Encoding::UTF_8)
      fail!("#{id} ATTACH native sidecar contents differ") unless
        sidecar_text.valid_encoding? && sidecar_text.split("\n", -1) == ["_block_offset", "_block_number", '']
      {
        inventory: active_inventory,
        native_owned_sidecar: {
          path: 'invalidated_system_columns.txt', contents: sidecar_text,
          size: sidecar_bytes.bytesize, sha256: Digest::SHA256.hexdigest(sidecar_bytes),
        },
      }
    end

    def normalize_signature(type, payload_hex: '', children: [], null: false)
      body = children.empty? && !null ? payload_hex.downcase : ''
      encoded_children = children.map { |child| "#{child.bytesize}:#{child};" }.join
      "#{type.bytesize}:#{type}:#{null ? 'N' : 'V'}:#{body.bytesize}:#{body}:#{children.size}[#{encoded_children}]"
    end

    def sig_string(value)
      normalize_signature('String', payload_hex: value.b.unpack1('H*'))
    end

    def sig_u64(value)
      normalize_signature('UInt64', payload_hex: [value].pack('Q<').unpack1('H*'))
    end

    def sig_nullable_u64(value)
      return normalize_signature('Nullable(UInt64)', null: true) if value.nil?
      normalize_signature('Nullable(UInt64)', children: [sig_u64(value)])
    end

    def sig_nullable_string(value)
      return normalize_signature('Nullable(String)', null: true) if value.nil?
      normalize_signature('Nullable(String)', children: [sig_string(value)])
    end

    def expected_helper_signatures(name)
      ROWS.map do |row|
        case name
        when 'u' then sig_u64(row.fetch(:u))
        when 'text' then sig_string(row.fetch(:text))
        when 'maybe' then sig_nullable_u64(row.fetch(:maybe))
        when 'gap', 'arr'
          items = row.fetch(name.to_sym)
          type = 'Array(Nullable(UInt64))'
          normalize_signature(type, children: items.map { |value| sig_nullable_u64(value) })
        when 'pair'
          type = 'Tuple(String, Nullable(UInt64))'
          normalize_signature(type, children: [sig_string(row.fetch(:pair)[0]), sig_nullable_u64(row.fetch(:pair)[1])])
        when 'lookup'
          children = row.fetch(:map).flat_map { |key, value| [sig_string(key), sig_u64(value)] }
          normalize_signature('Map(String, UInt64)', children: children)
        when 'string_array'
          array = normalize_signature('Array(Nullable(String))', children: row.fetch(:string_array).map { |value| sig_nullable_string(value) })
          normalize_signature('Tuple(items Array(Nullable(String)))', children: [array])
        when 'lc_text'
          normalize_signature('LowCardinality(String)', children: [sig_string(row.fetch(:lc_text))])
        when 'variant_text'
          value = row.fetch(:variant)
          if value.nil?
            normalize_signature('Variant(String, UInt64)', null: true)
          else
            child = value[0] == :string ? sig_string(value[1]) : sig_u64(value[1])
            normalize_signature('Variant(String, UInt64)', children: [child])
          end
        else fail!("unknown W276 signature column #{name}")
        end
      end
    end

    def build_summary
      status = @stock_only ? 'stock_native_four_cell_exact' : 'stock_first_native_and_generated_string1_matrix_exact'
      {
        format: FORMAT, status: status, execution_order: 'four independent stock/native controls, optional Crystal stock reads, then optional generated writes and native ATTACH/CHECK/windows',
        runtime_pin: {
          binary: @binary, expected_sha256: BINARY_SHA256,
          sha256_before: @binary_sha_before, sha256_after: @binary_sha_after,
          version: VERSION, build: BUILD,
          distinction: 'runtime executable SHA/version/build are pinned independently from the ClickHouse source checkout revision and source-file hashes',
        },
        source_pin: {root: @source_root, revision: SOURCE_REVISION, sha256: @upstream_hashes, guards: @source_guard},
        helper_pin: @full_matrix ? {path: @helper, sha256: @helper_sha_after} : nil,
        probe_sources: @probe_hashes_after,
        fixture: {
          schema: SCHEMA, value_columns: VALUE_COLUMNS, row_count: ROW_COUNT,
          rows_per_mark: ROWS_PER_MARK, data_marks: DATA_MARK_COUNT,
          stock_native_mark_rows_with_eof: PHYSICAL_MARK_ROWS_WITH_EOF,
          generated_mark_rows: WRITER_MARK_ROWS,
          generated_mark_rows_with_eof: PHYSICAL_MARK_ROWS_WITH_EOF,
          native_literal_rows: expected_native_rows('full'),
          native_literal_window_rows: {full: ROW_COUNT, middle: 4, eof: 0},
          native_value_encoding: 'String bytes are hex; Nullable values use NULL; String-array values encode child NULL as N and present values as V plus exact hex; Variant reports arm, String hex, and UInt64 decimal',
        },
        matrix: {mark_formats: MARK_FORMATS, mark_compression: MARK_COMPRESSION, string_profile: 'String1/with_size_stream', propagation: true, windows: WINDOWS.keys},
        stock: @stock,
        generated: @generated,
        invocations: @invocations,
        evidence_root: @root,
        claim_boundary: 'Finite eight-row/four-data-mark native literal witness only: stock String1 metadata, CHECK, exact full/middle/EOF native values and captured callback rosters are reported for MRK3/MRK4 with plain/compressed marks. Full mode additionally checks local typed stock reads and generated-part local reads, inventory-preserving detach/copy, native ATTACH/CHECK, and exact native windows. This does not qualify unsupported root Array(Nullable(String)), all static types, Dynamic/JSON inputs, arbitrary settings/layouts, or performance.',
      }
    end

    def render_summary(summary)
      lines = [
        '# W276 Compact String1 native compatibility probe', '',
        "Status: `#{summary.fetch(:status)}`",
        "Runtime: `#{VERSION}` build `#{BUILD}` SHA-256 `#{BINARY_SHA256}`.",
        "Source: `#{SOURCE_REVISION}` at `#{SOURCE_ROOT}` (independently pinned from the runtime executable).",
        'Eight literal rows form four two-row data marks. Stock and generated Compact parts report five physical marks: four data marks plus the zero-row EOF mark; local reader windows select only the four data marks.',
        'The native oracle encodes String bytes as hex and checks exact typed signatures, not merely successful SELECTs.',
      ]
      @stock.each do |id, entry|
        roster = entry.fetch(:callback_roster)
        windows = entry.fetch(:native_values).fetch(:windows)
        lines << "- Stock #{entry.fetch(:mark_format).upcase}/#{entry.fetch(:compression)}: Compact, CHECK healthy, String serialization version #{entry.fetch(:serialization_metadata).fetch(:string_version)}, callbacks #{roster.fetch(:roster).size} slots (#{roster.fetch(:state)}); full/middle/EOF `#{windows.values.map { |window| window.fetch(:state) }.join('/')}`."
      end
      unless @stock_only
        @stock.each do |id, entry|
          local = entry.fetch(:local_reader)
          lines << "- Crystal read stock #{id}: full audit, middle marks 1–2, and zero-row EOF exact against literal signatures."
        end
        @generated.each do |id, entry|
          active = entry.fetch(:active_part)
          lines << "- Generated #{entry.fetch(:mark_format).upcase}/#{entry.fetch(:compression)}: local full/middle/EOF reads, detached inventory identity, native ATTACH/CHECK, and exact native full/middle/EOF values; active part `#{active.fetch(:part_row)[4]}`."
        end
      end
      lines.concat(['', summary.fetch(:claim_boundary), ''])
      lines.join("\n")
    end

    def persist_inconclusive(error)
      return unless @root && File.directory?(File.join(@root, 'invocations'))
      report = {
        format: FORMAT, status: 'inconclusive', fatal_error: @fatal_error,
        error_class: error.class.name,
        runtime_pin: {binary: @binary, expected_sha256: BINARY_SHA256, observed_sha256: (sha(@binary) rescue nil)},
        source_pin: {root: @source_root, expected_revision: SOURCE_REVISION},
        helper_pin: @full_matrix ? {path: @helper, expected_sha256: @helper_expected_sha, observed_sha256: (sha(@helper) rescue nil)} : nil,
        invocations: @invocations, evidence_root: @root,
        claim_boundary: 'An SQL/type admission failure, local read rejection, CHECK failure, native value mismatch, or process identity mismatch is inconclusive and is never converted into a String1 compatibility conclusion.',
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(report) + "\n") unless File.exist?(File.join(@root, 'summary.json'))
    rescue StandardError
      nil
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {
    binary: ProbeCompactStringWriterW276::BINARY,
    source_root: ProbeCompactStringWriterW276::SOURCE_ROOT,
    evidence_root: nil,
    stock_only: false,
    full_matrix: false,
    helper: nil,
    helper_sha256: nil,
  }
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_compact_string_writer_w276.rb (--stock-only | --full-matrix --helper PREBUILT --helper-sha256 SHA256) --evidence-root EMPTY_DIR [--binary PINNED_CLICKHOUSE] [--source-root PINNED_UPSTREAM]'
    parser.on('--stock-only', 'Run all four stock MRK3/MRK4 × plain/compressed String1 native literal controls; never starts Crystal') { options[:stock_only] = true }
    parser.on('--full-matrix', 'Run four stock controls first, then local exact reads and four generated/native ATTACH/CHECK/window controls') { options[:full_matrix] = true }
    parser.on('--helper PATH', 'Prebuilt W276 Crystal helper; required only with --full-matrix') { |value| options[:helper] = value }
    parser.on('--helper-sha256 SHA256', 'Exact lowercase SHA-256 of the prebuilt helper') { |value| options[:helper_sha256] = value }
    parser.on('--evidence-root EMPTY_DIR', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
    parser.on('--binary PATH', 'Pinned ClickHouse runtime executable, distinct from source checkout') { |value| options[:binary] = value }
    parser.on('--source-root PATH', 'Separately pinned upstream ClickHouse source checkout') { |value| options[:source_root] = value }
  end.parse!

  unless options[:stock_only] != options[:full_matrix] && options[:evidence_root]
    warn 'W276: select exactly one of --stock-only or --full-matrix and provide --evidence-root'
    exit 2
  end
  if options[:stock_only] && (options[:helper] || options[:helper_sha256])
    warn 'W276: --helper and --helper-sha256 are valid only with --full-matrix'
    exit 2
  end
  if options[:full_matrix] && (!options[:helper] || !options[:helper_sha256])
    warn 'W276: --full-matrix requires --helper and --helper-sha256'
    exit 2
  end
  success = ProbeCompactStringWriterW276::Probe.new(**options).run
  exit(success ? 0 : 1)
end
