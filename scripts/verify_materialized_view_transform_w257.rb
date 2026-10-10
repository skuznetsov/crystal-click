#!/usr/bin/env ruby
# Bounded W257 stock-source -> caller transform -> detached target witness.
# This invokes only supplied, prebuilt executables; it never builds either.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative 'probe_nested_bulk_part_w202'

module VerifyMaterializedViewTransformW257
  W202 = ProbeNestedBulkPartW202
  BINARY_DEFAULT = '/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped'.freeze
  BINARY_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  VERSION = '26.10.1.1201'.freeze
  BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  MEMORY = 536_870_912
  TIMEOUT = 10
  GRACE = 2

  DATABASE_UUID = 'f2570000-7b7f-4e2f-9e44-dc13a87b8801'.freeze
  SOURCE_UUID = 'f2570000-7b7f-4e2f-9e44-dc13a87b8802'.freeze
  TARGET_UUID = 'f2570000-7b7f-4e2f-9e44-dc13a87b8803'.freeze
  VIEW_UUID = 'f2570000-7b7f-4e2f-9e44-dc13a87b8804'.freeze
  SOURCE_PART = 'all_1_1_0'.freeze
  OUTPUT_PART = 'all_9_9_0'.freeze
  ATTACHED_PART = 'all_1_1_0'.freeze
  # Comparison ed30948f: MergeTreeData.cpp:9099 / IMergeTreeDataPart.cpp:1899.
  # The separately pinned runtime witness qualifies these exact ATTACH bytes.
  INVALIDATED_SYSTEM_COLUMNS_NAME = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_SYSTEM_COLUMNS_BYTES = "_block_offset\n_block_number\n".b.freeze
  INVALIDATED_SYSTEM_COLUMNS_SHA256 = '7409424ab45090c1261e622f7423393905102e7e8cba36a6db88eb513ce1e06c'.freeze
  CATALOG_FORMAT = 'materialized_view_transform_w257_helper_v1'.freeze

  DYNAMIC = 'Dynamic(max_types=1)'.freeze
  DOCUMENT = 'JSON(max_dynamic_types=1, max_dynamic_paths=1, label String, t UInt8)'.freeze
  TRACE = "Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), sample Dynamic(max_types=1)))".freeze
  COLUMNS = [
    ['pk', 'UInt64'], ['score', 'UInt64'], ['payload', DYNAMIC], ['doc', DOCUMENT], ['trace', TRACE],
  ].freeze
  SOURCE_SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0', 'min_bytes_for_wide_part=0',
    'compress_marks=0', 'compress_primary_key=0', 'min_compress_block_size=0', 'max_compress_block_size=4096',
    "default_compression_codec='LZ4'", "serialization_info_version='with_types'",
    'propagate_types_serialization_versions_to_nested_types=1',
    'use_compact_variant_discriminators_serialization=0', "dynamic_serialization_version='v3'",
    "object_serialization_version='v3'", "object_shared_data_serialization_version_for_zero_level_parts='map'",
    "map_serialization_version='basic'", "map_serialization_version_for_zero_level_parts='basic'",
    "string_serialization_version='with_size_stream'",
  ].join(', ').freeze
  TARGET_SETTINGS = 'index_granularity=2, min_rows_for_wide_part=0, min_bytes_for_wide_part=0'.freeze

  # These source rows are independent native SQL/RowBinary expectations; they
  # are not derived from the Crystal fixture's report.
  SOURCE_ROWS = [
    {pk: 1, score: 10, payload: ['NULL', ''], label: 'drop-1', tag: 1, trace: []},
    {pk: 2, score: 20, payload: ['String', 'drop'], label: 'drop-2', tag: 2,
     trace: [{tag: 2, type: 'String', value: 'drop-child'}]},
    {pk: 3, score: 30, payload: ['UInt64', '30'], label: "a\0b", tag: 3, trace: []},
    {pk: 4, score: 40, payload: ['String', 'spill'], label: '', tag: 4,
     trace: [{tag: 4, type: 'UInt64', value: '40'}]},
    {pk: 5, score: 50, payload: ['UInt64', '50'], label: 'café', tag: 5,
     trace: [{tag: 5, type: 'String', value: 'child'}, {tag: 6, type: 'NULL', value: ''}]},
    {pk: 6, score: 60, payload: ['NULL', ''], label: 'tail', tag: 6,
     trace: [{tag: 7, type: 'UInt64', value: '60'}]},
  ].freeze

  # Written independently rather than applying the callback to SOURCE_ROWS.
  EXPECTED_TARGET_ROWS = [
    {pk: 103, score: 1030, payload: ['UInt64', '1030'], label: "a\0b!", tag: 13, trace: []},
    {pk: 104, score: 1040, payload: ['String', 'spill!'], label: '!', tag: 14,
     trace: [{tag: 14, type: 'UInt64', value: '1040'}]},
    {pk: 105, score: 1050, payload: ['UInt64', '1050'], label: 'café!', tag: 15,
     trace: [{tag: 15, type: 'String', value: 'child!'}, {tag: 16, type: 'NULL', value: ''}]},
    {pk: 106, score: 1060, payload: ['NULL', ''], label: 'tail!', tag: 16,
     trace: [{tag: 17, type: 'UInt64', value: '1060'}]},
  ].freeze

  MAX_PART_FILES = 256
  MAX_PART_BYTES = 16 * 1024 * 1024
  MAX_ROWBINARY_STRING = 1_048_576
  MAX_ROWBINARY_ARRAY = 64

  def self.validate_rowbinary!(bytes, expected_rows)
    rows = decode_rowbinary(bytes, expected_rows.length)
    raise 'RowBinary rows differ from independent literal oracle' unless rows == expected_rows
    true
  end

  def self.decode_rowbinary(bytes, expected_count)
    fail 'RowBinary capture exceeds the bounded maximum' if bytes.bytesize > MAX_PART_BYTES
    offset = 0
    rows = []
    expected_count.times do
      pk, offset = take_u64(bytes, offset)
      score, offset = take_u64(bytes, offset)
      payload_type, offset = take_string(bytes, offset)
      payload_value, offset = take_string(bytes, offset)
      label, offset = take_string(bytes, offset)
      tag, offset = take_u8(bytes, offset)
      count, offset = take_varuint(bytes, offset)
      fail 'RowBinary recursive array exceeds 64 items' if count > MAX_ROWBINARY_ARRAY
      trace = []
      count.times do
        child_tag, offset = take_u8(bytes, offset)
        child_type, offset = take_string(bytes, offset)
        child_value, offset = take_string(bytes, offset)
        trace << {tag: child_tag, type: child_type, value: child_value}
      end
      rows << {pk: pk, score: score, payload: [payload_type, payload_value], label: label, tag: tag, trace: trace}
    end
    fail 'RowBinary capture has trailing bytes' unless offset == bytes.bytesize
    rows
  end

  def self.json_dynamic(pair)
    type, value = pair
    result = {'kind' => type.downcase}
    result['value'] = type == 'UInt64' ? Integer(value) : value unless type == 'NULL'
    result
  end

  def self.take_u8(bytes, offset)
    fail 'truncated RowBinary UInt8' if offset >= bytes.bytesize
    [bytes.getbyte(offset), offset + 1]
  end

  def self.take_u64(bytes, offset)
    fail 'truncated RowBinary UInt64' if offset + 8 > bytes.bytesize
    [bytes.byteslice(offset, 8).unpack1('Q<'), offset + 8]
  end

  def self.take_varuint(bytes, offset)
    value = 0
    shift = 0
    loop do
      fail 'truncated RowBinary VarUInt' if offset >= bytes.bytesize || shift > 63
      byte = bytes.getbyte(offset)
      payload = byte & 0x7f
      fail 'RowBinary VarUInt exceeds UInt64' if shift == 63 && payload > 1
      offset += 1
      value |= payload << shift
      break if (byte & 0x80).zero?
      fail 'RowBinary VarUInt exceeds UInt64' if shift == 63
      shift += 7
    end
    fail 'non-canonical RowBinary VarUInt' if shift > 0 && value < (1 << shift)
    [value, offset]
  end

  def self.take_string(bytes, offset)
    length, offset = take_varuint(bytes, offset)
    fail 'RowBinary String exceeds the bounded maximum' if length > MAX_ROWBINARY_STRING
    fail 'truncated RowBinary String' if offset + length > bytes.bytesize
    [bytes.byteslice(offset, length).force_encoding(Encoding::UTF_8), offset + length]
  end

  class Probe < W202::Probe
    def initialize(binary, helper, evidence_root, helper_mode)
      super(binary, helper, evidence_root)
      @helper_mode = helper_mode
      @source_rows = {}
      @native_paths = {}
      @source_part_path = nil
      @source_snapshot = nil
      @output_part_path = nil
      @output_snapshot = nil
      @helper_report = nil
      @helper_sha_before = nil
      @helper_sha_after = nil
      @binary_sha_before = nil
      @binary_sha_after = nil
      @fatal_error = nil
    end

    def run
      prepare_layout!
      @binary_sha_before = binary_sha
      fail!('ClickHouse executable is not the pinned runtime') unless @binary_sha_before == BINARY_SHA256
      @helper_sha_before = Digest::SHA256.file(@helper).hexdigest

      initial = run_clickhouse('native_sources', initial_sql)
      assert_native_invocation!(initial)
      native = parse_markers(initial[:stdout])
      assert_pin!(native)
      assert_initial!(native)
      source_binary = run_clickhouse('native_source_rowbinary', source_rowbinary_sql)
      assert_native_invocation!(source_binary)
      VerifyMaterializedViewTransformW257.validate_rowbinary!(source_binary[:stdout], SOURCE_ROWS)
      @source_rows = {count: SOURCE_ROWS.length, stdout_sha256: Digest::SHA256.hexdigest(source_binary[:stdout])}

      offline_catalog = prepare_offline_catalog!
      helper = run_transform_helper(offline_catalog)
      @helper_report = helper[:data]
      assert_helper_report!(@helper_report, offline_catalog)
      @output_part_path = @helper_report.fetch('destination')
      @output_snapshot = part_snapshot(@output_part_path)
      attach_output_part!

      attached = run_clickhouse('native_attach_check', attached_sql)
      assert_native_invocation!(attached)
      attached_native = parse_markers(attached[:stdout])
      assert_pin!(attached_native)
      assert_attached!(attached_native)
      target_binary = run_clickhouse('native_target_rowbinary', target_rowbinary_sql)
      assert_native_invocation!(target_binary)
      VerifyMaterializedViewTransformW257.validate_rowbinary!(target_binary[:stdout], EXPECTED_TARGET_ROWS)

      @binary_sha_after = binary_sha
      @helper_sha_after = Digest::SHA256.file(@helper).hexdigest
      fail!('ClickHouse executable SHA changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail!('prebuilt helper changed during probe') unless @helper_sha_after == @helper_sha_before
      fail!('source part changed during helper or ATTACH') unless part_snapshot(@source_part_path) == @source_snapshot
      fail!('generated output part changed during helper or ATTACH') unless part_snapshot(@output_part_path) == @output_snapshot

      write_summary(
        status: 'materialized_view_transform_w257_observed',
        source_native: native, attached_native: attached_native,
        helper_output: @helper_report, source_rows: @source_rows,
        target_rows: {count: EXPECTED_TARGET_ROWS.length, stdout_sha256: Digest::SHA256.hexdigest(target_binary[:stdout])},
        source_part: {path: @source_part_path, snapshot: @source_snapshot},
        generated_output_part: {path: @output_part_path, snapshot: @output_snapshot},
        native_data_paths: @native_paths,
        helper_invocation: helper[:record], source_rowbinary_invocation: source_binary[:record],
        target_rowbinary_invocation: target_binary[:record],
        initial_invocation: initial[:record], attached_invocation: attached[:record],
      )
      puts "W257 callback transform + native ATTACH/CHECK/RowBinary observed; mode=#{@helper_mode}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = binary_sha rescue nil
      @helper_sha_after = Digest::SHA256.file(@helper).hexdigest rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W257 probe failure (process failure is not native format evidence): #{@fatal_error}"
      false
    end

    private

    def initial_sql
      source_ddl = table_ddl('source', SOURCE_UUID, SOURCE_SETTINGS)
      target_ddl = table_ddl('target', TARGET_UUID, TARGET_SETTINGS)
      view_ddl = "CREATE MATERIALIZED VIEW lab.view UUID '#{VIEW_UUID}' TO lab.target (#{column_ddl}) AS SELECT pk, score, payload, doc, trace FROM lab.source WHERE pk >= 3;"
      [
        'SET flatten_nested=0;', 'SET allow_suspicious_low_cardinality_types=1;',
        "SELECT '__W257_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        "CREATE DATABASE lab UUID '#{DATABASE_UUID}' ENGINE=Atomic;", source_ddl, target_ddl,
        "INSERT INTO lab.source VALUES #{SOURCE_ROWS.map { |row| source_sql_row(row) }.join(', ')};",
        view_ddl,
        check_sql('source'),
        "SELECT '__W257_SCHEMA__', table, name, type FROM system.columns WHERE database='lab' AND table IN ('source','target') ORDER BY table,position FORMAT TSVRaw;",
        "SELECT '__W257_DATA_PATH__', name, arrayElement(data_paths,1) FROM system.tables WHERE database='lab' AND name IN ('source','target') ORDER BY name FORMAT TSVRaw;",
        parts_sql(['source', 'target']),
      ].join("\n") + "\n"
    end

    def attached_sql
      [
        'SET flatten_nested=0;', 'SET allow_suspicious_low_cardinality_types=1;',
        "SELECT '__W257_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        "ALTER TABLE lab.target ATTACH PART '#{OUTPUT_PART}';",
        check_sql('source'), check_sql('target'),
        "SELECT '__W257_SCHEMA__', table, name, type FROM system.columns WHERE database='lab' AND table IN ('source','target') ORDER BY table,position FORMAT TSVRaw;",
        "SELECT '__W257_DATA_PATH__', name, arrayElement(data_paths,1) FROM system.tables WHERE database='lab' AND name IN ('source','target') ORDER BY name FORMAT TSVRaw;",
        parts_sql(['source', 'target']),
      ].join("\n") + "\n"
    end

    def check_sql(table_name)
      [
        "SELECT '__W257_CHECK_BEGIN__', '#{table_name}' FORMAT TSVRaw;",
        "CHECK TABLE lab.#{table_name} FORMAT TSV;",
        "SELECT '__W257_CHECK_END__', '#{table_name}' FORMAT TSVRaw;",
      ].join("\n")
    end

    def parts_sql(names)
      list = names.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W257_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='lab' AND table IN (#{list}) AND active ORDER BY table,name FORMAT TSVRaw;"
    end

    def source_rowbinary_sql
      rowbinary_select('source')
    end

    def target_rowbinary_sql
      rowbinary_select('target')
    end

    def rowbinary_select(table_name)
      payload_type = "if(isNull(payload), 'NULL', dynamicType(payload))"
      payload_value = dynamic_value('payload')
      trace = "arrayMap(x -> tuple(toUInt8(x.1.t), if(isNull(x.2), 'NULL', dynamicType(x.2)), #{dynamic_value('x.2')}), trace)"
      "SELECT pk, score, #{payload_type}, #{payload_value}, doc.label, doc.t, #{trace} FROM lab.#{table_name} ORDER BY pk FORMAT RowBinary;"
    end

    def dynamic_value(expression)
      "ifNull(if(isNull(#{expression}), '', if(dynamicType(#{expression}) = 'UInt64', toString(dynamicElement(#{expression}, 'UInt64')), dynamicElement(#{expression}, 'String'))), '')"
    end

    def table_ddl(name, uuid, settings)
      "CREATE TABLE lab.#{name} UUID '#{uuid}' (#{column_ddl}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};"
    end

    def column_ddl
      COLUMNS.map { |name, type| "`#{name}` #{type}" }.join(', ')
    end

    def source_sql_row(row)
      "(#{row[:pk]}, #{row[:score]}, #{dynamic_sql(row[:payload])}, #{document_sql(row[:label], row[:tag])}, #{trace_sql(row[:trace])})"
    end

    def dynamic_sql(pair)
      kind, value = pair
      case kind
      when 'NULL' then "CAST(NULL, '#{DYNAMIC}')"
      when 'UInt64' then "CAST(toUInt64(#{Integer(value)}), '#{DYNAMIC}')"
      when 'String' then "CAST(#{sql_quote(value)}, '#{DYNAMIC}')"
      else fail!("unknown independent Dynamic literal #{kind.inspect}")
      end
    end

    def document_sql(label, tag)
      json = JSON.generate({'label' => label, 't' => tag})
      "CAST(#{sql_quote(json)}, '#{DOCUMENT}')"
    end

    def trace_sql(items)
      return "CAST([], '#{TRACE}')" if items.empty?
      tuples = items.map do |item|
        "(CAST(#{sql_quote(JSON.generate({'t' => item[:tag]}))}, '#{DOCUMENT.sub(', label String', '')}'), #{dynamic_sql([item[:type], item[:value]])})"
      end
      "CAST([#{tuples.join(', ')}], '#{TRACE}')"
    end

    def sql_quote(value)
      escaped = value.to_s.gsub(/[\\'\0]/) do |character|
        character == "\0" ? "\\0" : "\\#{character}"
      end
      "'#{escaped}'"
    end

    def parse_markers(stdout)
      lines = stdout.dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      known = %w[__W257_PIN__ __W257_SCHEMA__ __W257_DATA_PATH__ __W257_PART__ __W257_CHECK_BEGIN__ __W257_CHECK_END__]
      unknown = lines.select { |line| line.start_with?('__W257_') }.map { |line| line.split("\t", 2).first }.uniq - known
      fail!("unknown native marker tags: #{unknown.inspect}") unless unknown.empty?
      pin = lines.select { |line| line.start_with?("__W257_PIN__\t") }
      schemas = lines.select { |line| line.start_with?("__W257_SCHEMA__\t") }.map { |line| line.split("\t", -1).drop(1) }
      paths = lines.select { |line| line.start_with?("__W257_DATA_PATH__\t") }.map { |line| line.split("\t", -1) }
      parts = lines.select { |line| line.start_with?("__W257_PART__\t") }.map { |line| line.split("\t", -1) }
      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W257_CHECK_BEGIN__\t")
          fields = line.split("\t", -1)
          fail!('malformed, nested, or duplicate CHECK start') unless
            fields.size == 2 && active.nil? && !checks.has_key?(fields[1])
          active = fields[1]
          checks[active] = []
        elsif line.start_with?("__W257_CHECK_END__\t")
          fields = line.split("\t", -1)
          fail!('malformed or mismatched CHECK end') unless fields.size == 2 && active == fields[1]
          active = nil
        elsif active
          checks.fetch(active) << line
        end
      end
      fail!('unterminated CHECK capture') unless active.nil?
      fail!('runtime pin must occur once') unless pin.size == 1 && pin.first.split("\t", -1).size == 3
      fail!('duplicate native data path') unless paths.map { |fields| fields[1] }.uniq.size == paths.size
      fail!('duplicate native active part') unless parts.map { |fields| fields[1] }.uniq.size == parts.size
      {
        pin: pin.first,
        schemas: schemas,
        data_paths: paths.to_h { |fields| [fields.fetch(1), fields.fetch(2)] },
        parts: parts.to_h do |fields|
          fail!('native part marker width differs') unless fields.size == 7
          [fields.fetch(1), {name: fields.fetch(2), path: fields.fetch(3), type: fields.fetch(4), rows: fields.fetch(5), marks: fields.fetch(6)}]
        end,
        checks: checks,
      }
    end

    def assert_pin!(native)
      expected = "__W257_PIN__\t#{VERSION}\t#{BUILD}"
      fail!("runtime version/build differs: #{native[:pin].inspect}") unless native[:pin] == expected
    end

    def assert_initial!(native)
      fail!('initial CHECK roster differs') unless native[:checks] == {'source' => ["#{SOURCE_PART}\t1\t"]}
      fail!('initial schema differs') unless native[:schemas] == expected_schemas
      fail!('initial native paths do not cover source and empty target') unless native[:data_paths].keys.sort == %w[source target]
      @native_paths = native[:data_paths].dup
      @native_paths.each_value { |path| validate_store_path!(path) }
      fail!('initial active part roster differs') unless native[:parts].keys == ['source']
      part = native[:parts].fetch('source')
      fail!('stock source is not the expected six-row Wide part') unless
        part[:name] == SOURCE_PART && part[:type] == 'Wide' && part[:rows] == '6' && part[:marks] == '4'
      @source_part_path = validate_part_path!(part[:path])
      @source_snapshot = part_snapshot(@source_part_path)
    end

    def assert_attached!(native)
      fail!('final CHECK roster differs') unless native[:checks] == {
        'source' => ["#{SOURCE_PART}\t1\t"], 'target' => ["#{ATTACHED_PART}\t1\t"],
      }
      fail!('final schema differs') unless native[:schemas] == expected_schemas
      fail!('final paths differ from initial identities') unless native[:data_paths] == @native_paths
      fail!('final active source/target part roster differs') unless native[:parts].keys.sort == %w[source target]
      source = native[:parts].fetch('source')
      target = native[:parts].fetch('target')
      fail!('source part identity changed') unless source[:name] == SOURCE_PART && source[:type] == 'Wide' && source[:rows] == '6' && source[:marks] == '4'
      fail!('attached target part identity/grid differs') unless target[:name] == ATTACHED_PART && target[:type] == 'Wide' && target[:rows] == '4' && target[:marks] == '3'
      fail!('source part path changed') unless validate_part_path!(source[:path]) == @source_part_path
      attached_path = validate_part_path!(target[:path])
      assert_attached_part_snapshot!(attached_path)
    end

    def expected_schemas
      %w[source target].flat_map do |table|
        COLUMNS.map { |name, type| [table, name, type] }
      end
    end

    def prepare_offline_catalog!
      catalog = File.join(@root, 'generated', 'offline_catalog')
      database_dir = File.join(catalog, 'store', DATABASE_UUID[0, 3], DATABASE_UUID)
      source_dir = File.join(catalog, 'store', SOURCE_UUID[0, 3], SOURCE_UUID)
      target_dir = File.join(catalog, 'store', TARGET_UUID[0, 3], TARGET_UUID)
      store_dir = File.join(catalog, 'store')
      prefixes = [DATABASE_UUID, SOURCE_UUID, TARGET_UUID].map { |uuid| uuid[0, 3] }.uniq
      fail!('offline catalog UUID prefixes differ') unless prefixes == [DATABASE_UUID[0, 3]]
      Dir.mkdir(catalog, 0o700)
      Dir.mkdir(File.join(catalog, 'metadata'), 0o700)
      Dir.mkdir(store_dir, 0o700)
      prefixes.each { |prefix| Dir.mkdir(File.join(store_dir, prefix), 0o700) }
      [database_dir, source_dir, target_dir].each { |path| Dir.mkdir(path, 0o700) }
      File.write(File.join(catalog, 'metadata', 'lab.sql'), "ATTACH DATABASE _ UUID '#{DATABASE_UUID}'\nENGINE = Atomic\n", mode: 'wx', perm: 0o600)
      File.write(File.join(source_dir, 'format_version.txt'), "1\n", mode: 'wx', perm: 0o600)
      File.write(File.join(target_dir, 'format_version.txt'), "1\n", mode: 'wx', perm: 0o600)
      Dir.mkdir(File.join(target_dir, 'detached'), 0o700)
      table_tail_source = "ENGINE = MergeTree\nORDER BY pk\nSETTINGS #{SOURCE_SETTINGS}"
      table_tail_target = "ENGINE = MergeTree\nORDER BY pk\nSETTINGS #{TARGET_SETTINGS}"
      File.write(File.join(database_dir, 'source.sql'), attach_table_ddl(SOURCE_UUID, table_tail_source), mode: 'wx', perm: 0o600)
      File.write(File.join(database_dir, 'target.sql'), attach_table_ddl(TARGET_UUID, table_tail_target), mode: 'wx', perm: 0o600)
      view_ddl = <<~DDL
        ATTACH MATERIALIZED VIEW _ UUID '#{VIEW_UUID}' TO lab.target
        (
            #{column_ddl}
        )
        AS SELECT pk, score, payload, doc, trace FROM lab.source WHERE pk >= 3
      DDL
      File.write(File.join(database_dir, 'view.sql'), view_ddl, mode: 'wx', perm: 0o600)
      source_part = @source_part_path
      fail!('stock source part path does not name the expected part') unless File.basename(source_part) == SOURCE_PART
      destination = File.join(source_dir, SOURCE_PART)
      copy_plain_part!(source_part, destination)
      catalog
    end

    def attach_table_ddl(uuid, tail)
      <<~DDL
        ATTACH TABLE _ UUID '#{uuid}'
        (
            #{column_ddl}
        )
        #{tail}
      DDL
    end

    def copy_plain_part!(source, destination)
      fail!('refusing to copy absent, symlinked, or existing source part') unless File.directory?(source) && !File.symlink?(source) && !File.exist?(destination)
      FileUtils.cp_r(source, destination, preserve: true)
      part_snapshot(destination)
    end

    def run_transform_helper(catalog)
      argv = [@helper, catalog, SOURCE_PART, OUTPUT_PART]
      before = Digest::SHA256.file(@helper).hexdigest
      invocation = @executor.send(:execute_record, 'crystal_transform_helper', argv, ''.b,
                                  'prebuilt Crystal transform helper', nil, nil)
      fail!('prebuilt Crystal transform helper failed') unless successful?(invocation)
      fail!('transform helper emitted stderr') unless invocation[:stderr].empty?
      fail!('transform helper SHA changed during execution') unless Digest::SHA256.file(@helper).hexdigest == before
      lines = invocation[:stdout].lines.reject(&:empty?)
      fail!('helper must emit one JSON object') unless lines.size == 1
      {data: JSON.parse(lines.first), record: invocation[:record]}
    end

    def assert_helper_report!(report, catalog)
      expected_keys = %w[destination format output_mark_rows output_part_name output_row_count output_rows part_files source_part_name source_row_count source_selected_columns source_types]
      fail!('helper report key/format differs') unless report.keys.sort == expected_keys && report['format'] == CATALOG_FORMAT
      fail!('helper part identities differ') unless report['source_part_name'] == SOURCE_PART && report['output_part_name'] == OUTPUT_PART
      fail!('helper did not consume all source rows') unless report['source_row_count'] == 6
      fail!('helper source roster differs') unless report['source_selected_columns'] == COLUMNS.map(&:first)
      fail!('helper exact source declarations differ') unless report['source_types'] == COLUMNS.map { |name, type| {'name' => name, 'type' => type} }
      fail!('helper output row count/mark schedule differs') unless report['output_row_count'] == 4 && report['output_mark_rows'] == [2, 2]
      fail!('helper output values differ from independent transformed literals') unless report['output_rows'] == json_rows(EXPECTED_TARGET_ROWS)
      target_directory = File.join(catalog, 'store', TARGET_UUID[0, 3], TARGET_UUID, 'detached')
      expected_destination = File.join(target_directory, OUTPUT_PART)
      fail!('helper destination escaped the resolved detached target') unless File.expand_path(report['destination']) == expected_destination
      @output_part_path = expected_destination
      @output_snapshot = part_snapshot(@output_part_path)
      fail!('generated part already contains ATTACH invalidation metadata') if
        @output_snapshot.has_key?(INVALIDATED_SYSTEM_COLUMNS_NAME)
      fail!('helper top-level file roster is not the actual part roster') unless report['part_files'] == @output_snapshot.keys.sort
    end

    def assert_attached_part_snapshot!(attached_path)
      generated = @output_snapshot
      fail!('generated part already contains ATTACH invalidation metadata') if
        generated.has_key?(INVALIDATED_SYSTEM_COLUMNS_NAME)

      attached = part_snapshot(attached_path)
      expected_names = (generated.keys + [INVALIDATED_SYSTEM_COLUMNS_NAME]).sort
      fail!('ATTACH changed the generated part file roster') unless attached.keys.sort == expected_names
      generated.each do |name, snapshot|
        fail!("ATTACH changed generated part file: #{name}") unless attached[name] == snapshot
      end

      marker_snapshot = attached.fetch(INVALIDATED_SYSTEM_COLUMNS_NAME)
      expected_marker = {
        type: 'file', size: INVALIDATED_SYSTEM_COLUMNS_BYTES.bytesize,
        sha256: INVALIDATED_SYSTEM_COLUMNS_SHA256,
      }
      fail!('ATTACH invalidation metadata snapshot differs') unless marker_snapshot == expected_marker
      marker_bytes = File.binread(File.join(attached_path, INVALIDATED_SYSTEM_COLUMNS_NAME))
      fail!('ATTACH invalidation metadata bytes differ') unless marker_bytes == INVALIDATED_SYSTEM_COLUMNS_BYTES
    end

    def json_rows(rows)
      rows.map do |row|
        {
          'pk' => row[:pk], 'score' => row[:score],
          'payload' => VerifyMaterializedViewTransformW257.json_dynamic(row[:payload]),
          'doc' => {'label' => row[:label], 't' => row[:tag]},
          'trace' => row[:trace].map { |item| {'doc_t' => item[:tag], 'sample' => VerifyMaterializedViewTransformW257.json_dynamic([item[:type], item[:value]])} },
        }
      end
    end

    def attach_output_part!
      source = @output_part_path
      target_data = @native_paths.fetch('target')
      detached = File.join(target_data, 'detached')
      fail!('native target detached directory missing or unsafe') unless File.directory?(detached) && !File.symlink?(detached)
      destination = File.join(detached, OUTPUT_PART)
      fail!('native detached destination already exists') if File.exist?(destination) || File.symlink?(destination)
      copy_plain_part!(source, destination)
      @native_detached_part = destination
    end

    def validate_store_path!(path)
      root = File.join(@root, 'stores', 'native')
      full = File.expand_path(path)
      fail!('native data path escaped the bounded store') unless full.start_with?(root + File::SEPARATOR)
      current = root
      full.delete_prefix(root + File::SEPARATOR).split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        next unless File.exist?(current) || File.symlink?(current)
        fail!("symlink in native path: #{current}") if File.lstat(current).symlink?
        fail!("non-directory native path component: #{current}") unless File.directory?(current)
      end
      fail!('native data path is not canonical') unless File.realpath(full) == full
      full
    end

    def validate_part_path!(path)
      full = File.expand_path(path)
      store = File.join(@root, 'stores', 'native')
      fail!('native part path escaped the captured store') unless full.start_with?(store + File::SEPARATOR)
      fail!('native part is absent or symlinked') unless File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full
      part_snapshot(full)
      full
    end

    def part_snapshot(path)
      fail!('part root is absent or a symlink') unless File.directory?(path) && !File.symlink?(path)
      entries = Dir.children(path).sort
      fail!('part file count exceeds 256') if entries.size > MAX_PART_FILES
      snapshot = {}
      total = 0
      entries.each do |name|
        file = File.join(path, name)
        stat = File.lstat(file)
        fail!("part contains a symlink or non-file: #{name}") unless stat.file? && !stat.symlink?
        total += stat.size
        fail!('part byte count exceeds 16 MiB') if total > MAX_PART_BYTES
        snapshot[name] = {type: 'file', size: stat.size, sha256: Digest::SHA256.file(file).hexdigest}
      end
      snapshot
    end

    def write_summary(data)
      summary = {
        probe: 'W257 caller-run materialized-view transform native witness',
        status: data[:status], fatal_error: data[:fatal_error],
        helper_mode: @helper_mode,
        runtime: {path: @binary, expected_sha256: BINARY_SHA256, sha256_before: @binary_sha_before,
                  sha256_after: @binary_sha_after, version: VERSION, build: BUILD},
        helper: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        limits: {max_threads: 1, max_memory_usage_bytes: MEMORY, timeout_seconds: TIMEOUT,
                 termination_grace_seconds: GRACE, part_files: MAX_PART_FILES, part_bytes: MAX_PART_BYTES},
        evidence_root: @root, invocations: @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), [
        '# W257 caller-run materialized-view transform native witness', '',
        "Status: `#{summary[:status]}`", '',
        'Scope: one six-row stock source part, a caller-owned filtered/rekeyed transform across BinaryBulk, Dynamic, JSON Object, and recursive Array(Tuple(JSON, Dynamic)), then detached publication, native ATTACH/CHECK, and independent RowBinary comparison. The persisted MV SELECT is not claimed to be the Crystal callback or executed by the library.', '',
        "Runtime: #{VERSION} / #{BUILD} / SHA256 `#{BINARY_SHA256}`", '',
        "Helper mode: #{@helper_mode}", "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end

    def fail!(message)
      raise RuntimeError, "W257 transform witness: #{message}"
    end
  end

  def self.run(argv)
    options = {binary: BINARY_DEFAULT, helper: nil, evidence_root: nil, helper_mode: nil}
    parser = OptionParser.new do |opts|
      opts.banner = 'usage: verify_materialized_view_transform_w257.rb --helper-mode debug|release --crystal-helper PATH --evidence-root EMPTY_DIRECT_CHILD [--clickhouse PATH]'
      opts.on('--clickhouse PATH') { |value| options[:binary] = value }
      opts.on('--crystal-helper PATH') { |value| options[:helper] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
      opts.on('--helper-mode MODE') { |value| options[:helper_mode] = value }
    end
    parser.parse!(argv)
    raise OptionParser::MissingArgument, '--crystal-helper' unless options[:helper]
    raise OptionParser::MissingArgument, '--evidence-root' unless options[:evidence_root]
    raise OptionParser::MissingArgument, '--helper-mode debug|release' unless %w[debug release].include?(options[:helper_mode])
    raise OptionParser::InvalidArgument, 'unexpected positional arguments' unless argv.empty?
    probe = Probe.new(options[:binary], options[:helper], options[:evidence_root], options[:helper_mode])
    exit(probe.run ? 0 : 1)
  rescue OptionParser::ParseError, ArgumentError => error
    warn "W257 usage error: #{error.message}"
    warn parser
    exit(2)
  end
end

VerifyMaterializedViewTransformW257.run(ARGV) if $PROGRAM_NAME == __FILE__
