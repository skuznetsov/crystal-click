#!/usr/bin/env ruby
# Bounded stock-only qualification of JSON-bearing values in shared Object
# paths. The whole-column read is kept distinct from advanced path-Data reads.

require 'digest'
require 'json'
require 'optparse'
require_relative 'check_array_json_parts_w185'

module ProbeObjectSharedJSONW240
  W185 = CheckArrayJSONPartsW185
  BINARY = W185::BINARY
  BINARY_SHA256 = W185::BINARY_SHA256
  VERSION = W185::VERSION
  BUILD = W185::BUILD
  MEMORY = W185::MEMORY
  TIMEOUT = W185::TIMEOUT
  GRACE = W185::GRACE
  OUTER_RUN_SAFE_LIMIT = W185::OUTER_RUN_SAFE_LIMIT

  TYPE = 'JSON(max_dynamic_paths=0)'.freeze
  VERSIONS = [
    {id: 'map', setting: 'map', enum: 0},
    {id: 'map_with_buckets', setting: 'map_with_buckets', enum: 1},
    {id: 'advanced', setting: 'advanced', enum: 2},
    {id: 'advanced_chunked', setting: 'advanced_chunked', enum: 3},
  ].map(&:freeze).freeze

  SETTINGS_BASE = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'compress_marks=0', 'compress_primary_key=0',
    'min_compress_block_size=0', 'max_compress_block_size=4096',
    'ratio_of_defaults_for_sparse_serialization=1', "default_compression_codec='LZ4'",
    "serialization_info_version='with_types'", "dynamic_serialization_version='v3'",
    "object_serialization_version='v3'", 'propagate_types_serialization_versions_to_nested_types=true',
    'object_shared_data_buckets_for_wide_part=2',
  ].freeze

  ROWS = [
    {pk: 1, doc: {'arr' => [{'v' => 1, 's' => 'one'}, {'v' => 2, 's' => 'two'}], 'mixed' => 1, 'label' => 'one'}},
    {pk: 2, doc: {'arr' => [{'v' => 3, 's' => 'three'}], 'mixed' => 'two', 'label' => 2}},
    {pk: 3, doc: {'arr' => [], 'mixed' => true, 'label' => 'three'}},
    {pk: 4, doc: {}},
    {pk: 5, doc: {'arr' => [{'v' => 5, 's' => 'five'}], 'mixed' => 2, 'label' => 5}},
    {pk: 6, doc: {'arr' => [], 'mixed' => 'six', 'label' => 'six'}},
    {pk: 7, doc: {'arr' => [{'v' => 7, 's' => 'seven'}], 'mixed' => false, 'label' => 7}},
    {pk: 8, doc: {'arr' => [{'v' => 8, 's' => 'eight'}], 'mixed' => 3, 'label' => 'last',
                  'late' => [{'v' => 80, 'late_only_child' => 'last-chunk-only'}]}},
  ].map(&:freeze).freeze

  # The small adapter reuses W185's pinned W180 executor, exact argv/stdin/
  # stdout/stderr recorder, and empty-direct-child evidence-root validation.
  # It deliberately never initializes or invokes a Crystal helper.
  class Recorder < W185::Probe
    def initialize(binary, evidence_root)
      @binary = send(:validate_executable, binary, 'ClickHouse')
      @root = send(:validate_root, evidence_root)
      @invocations = []
      @fatal_error = nil
    end
  end

  class Probe
    def initialize(binary, evidence_root)
      @recorder = Recorder.new(binary, evidence_root)
      @binary = @recorder.instance_variable_get(:@binary)
      @root = @recorder.instance_variable_get(:@root)
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @profiles = []
      @fatal_error = nil
      @part_inspector = W185::Probe.allocate
      @part_inspector.instance_variable_set(:@root, @root)
    end

    def run
      %w[invocations stores parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      @sha_before = @recorder.send(:binary_sha)
      fail!('pinned ClickHouse executable SHA-256 mismatch before probe') unless @sha_before == BINARY_SHA256

      VERSIONS.each { |profile| @profiles << run_profile(profile) }

      @sha_after = @recorder.send(:binary_sha)
      fail!('pinned ClickHouse executable SHA-256 changed during probe') unless @sha_after == BINARY_SHA256
      status = @profiles.all? { |profile| profile[:status] == 'stock_profile_observed' } ?
        'all_stock_profiles_observed' : 'capture_incomplete_or_observations_differ'
      write_evidence(status: status)
      puts "W240 status=#{status}; profiles=#{@profiles.count { |profile| profile[:status] == 'stock_profile_observed' }}/#{VERSIONS.size}; evidence=#{@root}"
      status == 'all_stock_profiles_observed'
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @sha_after = @recorder.send(:binary_sha) rescue nil
      write_evidence(status: 'runner_failure_or_observations_differ') rescue nil
      warn "W240 shared JSON probe failure: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise RuntimeError, "W240 shared JSON oracle: #{message}"
    end

    def table(profile)
      "w240_#{@token}_#{profile.fetch(:id)}"
    end

    def settings(profile)
      values = SETTINGS_BASE + [
        "object_shared_data_serialization_version='#{profile.fetch(:setting)}'",
        "object_shared_data_serialization_version_for_zero_level_parts='#{profile.fetch(:setting)}'",
      ]
      values << 'object_shared_data_target_chunk_rows=2' if profile.fetch(:setting) == 'advanced_chunked'
      values.join(', ')
    end

    def sql_string(value)
      "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
    end

    def write_sql(profile)
      name = table(profile)
      inserts = ROWS.map do |row|
        json = JSON.generate(row.fetch(:doc))
        "(#{row.fetch(:pk)}, CAST(#{sql_string(json)}, #{sql_string(TYPE)}))"
      end
      statements = [
        'SET output_format_json_quote_64bit_integers=0;',
        "SELECT '__W240_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        "CREATE TABLE default.#{name} (pk UInt8, doc #{TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(profile)};",
        "INSERT INTO default.#{name} VALUES #{inserts.join(",\n")};",
        "SELECT '__W240_CHECK_BEGIN__', '#{profile.fetch(:id)}' FORMAT TSVRaw;",
        "CHECK TABLE default.#{name} FORMAT TSV;",
        "SELECT '__W240_CHECK_END__', '#{profile.fetch(:id)}' FORMAT TSVRaw;",
        "SELECT '__W240_SCHEMA__', '#{profile.fetch(:id)}', name, type FROM system.columns WHERE database='default' AND table='#{name}' ORDER BY position FORMAT TSVRaw;",
        "SELECT '__W240_PART__', '#{profile.fetch(:id)}', name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{name}' AND active ORDER BY name FORMAT TSVRaw;",
      ]
      statements.join("\n") + "\n"
    end

    def direct_sql(profile)
      name = table(profile)
      id = profile.fetch(:id)
      [
        'SET output_format_json_quote_64bit_integers=0;',
        "SELECT '__W240_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        direct_query(name, id),
      ].join("\n") + "\n"
    end

    def full_sql(profile)
      name = table(profile)
      id = profile.fetch(:id)
      [
        'SET output_format_json_quote_64bit_integers=0;',
        "SELECT '__W240_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        full_query(name, id),
      ].join("\n") + "\n"
    end

    # This SELECT contains only direct paths: no full doc projection, whole-
    # object serializer, or path-roster function can satisfy these witnesses.
    def direct_query(name, id)
      "SELECT '__W240_DIRECT__', '#{id}', toString(pk), " \
        "toTypeName(doc.arr), if(isNull(doc.arr), 'NULL', dynamicType(doc.arr)), " \
        "if(isNull(doc.arr), '6E756C6C', hex(toJSONString(doc.arr))), " \
        "toTypeName(doc.mixed), if(isNull(doc.mixed), 'NULL', dynamicType(doc.mixed)), " \
        "if(isNull(doc.mixed), '6E756C6C', hex(toJSONString(doc.mixed))), " \
        "toTypeName(doc.late), if(isNull(doc.late), 'NULL', dynamicType(doc.late)), " \
        "if(isNull(doc.late), '6E756C6C', hex(toJSONString(doc.late))) " \
        "FROM default.#{name} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;"
    end

    def full_query(name, id)
      "SELECT '__W240_FULL__', '#{id}', toString(pk), " \
        "toTypeName(doc), hex(toJSONString(doc)), " \
        "hex(toJSONString(JSONDynamicPaths(doc))), hex(toJSONString(JSONSharedDataPaths(doc))) " \
        "FROM default.#{name} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;"
    end

    def run_profile(profile)
      id = profile.fetch(:id)
      stages = {}
      stages[:write] = run_stage(profile, 'write', write_sql(profile)) do |stdout|
        assert_write_observations!(stdout, profile)
      end
      if stages[:write][:status] == 'stage_observed'
        stages[:direct] = run_stage(profile, 'direct', direct_sql(profile)) do |stdout|
          assert_direct_observations!(stdout, profile)
        end
        stages[:full] = run_stage(profile, 'full', full_sql(profile)) do |stdout|
          assert_full_observations!(stdout, profile)
        end
      else
        stages[:direct] = skipped_stage('write/check stage did not establish a readable table')
        stages[:full] = skipped_stage('write/check stage did not establish a readable table')
      end

      joined = if stages[:direct][:status] == 'stage_observed' && stages[:full][:status] == 'stage_observed'
                 join_by_pk!(stages[:direct].fetch(:observations), stages[:full].fetch(:observations), id)
               end
      status = stages.values.all? { |stage| stage[:status] == 'stage_observed' } && joined ?
        'stock_profile_observed' : 'capture_incomplete_or_observations_differ'
      {id: id, enum_value: profile.fetch(:enum), status: status,
       stages: stages, joined_by_pk_after_independent_assertions: joined}
    rescue StandardError => error
      {id: id, enum_value: profile.fetch(:enum), status: 'runner_failure_inconclusive',
       error: "#{error.class}: #{error.message}"}
    end

    def run_stage(profile, stage, sql)
      id = profile.fetch(:id)
      label = "#{stage}_#{id}"
      invocation = @recorder.send(:run_clickhouse, label, sql)
      begin
        @recorder.send(:assert_native_invocation!, invocation)
      rescue StandardError => error
        return {status: 'process_or_sql_failure_inconclusive',
                error: "#{error.class}: #{error.message}", invocation: invocation[:record]}
      end
      begin
        assert_pin!(invocation[:stdout], id, stage)
        observations = yield(invocation[:stdout])
        {status: 'stage_observed', invocation: invocation[:record], observations: observations}
      rescue StandardError => error
        {status: 'execution_succeeded_but_observations_differ',
         error: "#{error.class}: #{error.message}", invocation: invocation[:record]}
      end
    rescue StandardError => error
      {status: 'runner_failure_inconclusive', error: "#{error.class}: #{error.message}"}
    end

    def skipped_stage(reason)
      {status: 'not_run_write_stage_failed', reason: reason}
    end

    def assert_pin!(stdout, id, stage)
      pins = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).select do |line|
        line.start_with?("__W240_PIN__\t")
      end
      expected = "__W240_PIN__\t#{VERSION}\t#{BUILD}"
      fail!("#{id}/#{stage} must emit exactly one runtime pin: #{pins.inspect}") unless pins == [expected]
    end

    def parse_write_observations(stdout, id)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      rows = ->(tag) { lines.select { |line| line.start_with?("#{tag}\t") }.map { |line| line.split("\t", -1) } }
      check_blocks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W240_CHECK_BEGIN__\t")
          fields = line.split("\t", -1)
          fail!("#{id} CHECK block malformed or nested") unless fields.size == 2 && active.nil?
          active = fields[1]
          check_blocks[active] = []
        elsif line.start_with?("__W240_CHECK_END__\t")
          fields = line.split("\t", -1)
          fail!("#{id} CHECK block end malformed") unless fields.size == 2 && active == fields[1]
          active = nil
        elsif active
          check_blocks.fetch(active) << line
        end
      end
      fail!("#{id} CHECK block was unterminated") unless active.nil?
      {
        check_blocks: check_blocks,
        schemas: rows.call('__W240_SCHEMA__'),
        parts: rows.call('__W240_PART__'),
      }
    end

    def tagged_rows(stdout, tag)
      stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).select do |line|
        line.start_with?("#{tag}\t")
      end.map { |line| line.split("\t", -1) }
    end

    def parse_hex_json(hex, label)
      JSON.parse([hex].pack('H*'))
    rescue JSON::ParserError, TypeError => error
      fail!("#{label} was not valid hex JSON: #{error.message}")
    end

    def array_json_type?(type)
      type == 'Array(JSON)' || /\AArray\(JSON\(.*\)\)\z/.match?(type)
    end

    def assert_write_observations!(stdout, profile)
      observed = parse_write_observations(stdout, profile.fetch(:id))
      id = profile.fetch(:id)
      schemas = observed.fetch(:schemas).map { |fields| fields.drop(2) }
      fail!("#{id} schema rows differ: #{schemas.inspect}") unless
        observed.fetch(:schemas).all? { |fields| fields[1] == id } && schemas.size == 2 &&
        schemas[0] == ['pk', 'UInt8'] && schemas[1][0] == 'doc' && schemas[1][1].include?('JSON')

      check = observed.fetch(:check_blocks)
      fail!("#{id} CHECK result differs: #{check.inspect}") unless check == {id => ["all_1_1_0\t1\t"]}
      part_rows = observed.fetch(:parts)
      fail!("#{id} must emit exactly one active part with a path") unless part_rows.size == 1
      part_fields = part_rows.fetch(0)
      fail!("#{id} part row has wrong width: #{part_fields.inspect}") unless part_fields.size == 7
      fail!("#{id} part row has wrong table id") unless part_fields[1] == id
      parts = [part_fields.drop(2)]
      fail!("#{id} part inventory differs: #{parts.inspect}") unless
        parts[0][0] == 'all_1_1_0' && parts[0][2] == 'Wide' && parts[0][3] == '8' && parts[0][4] == '5'
      native_part = {name: part_fields[2], path: part_fields[3], part_type: part_fields[4],
                     rows: part_fields[5], marks: part_fields[6]}
      inventory = @part_inspector.send(:inspect_part, "W240 #{id}", native_part.fetch(:path), native_part)
      physical_layout = assert_physical_roster!(inventory, profile)
      serialization_path = File.join(inventory.fetch(:part_path), 'serialization.json')
      inventory[:serialization_json] = JSON.parse(File.binread(serialization_path))
      {
        check: check, schemas: schemas, parts: parts,
        part_inventory: inventory, physical_layout: physical_layout,
      }
    end

    def assert_physical_roster!(inventory, profile)
      id = profile.fetch(:id)
      streams = inventory.fetch(:logical_substreams)
      prefix = 'doc.object_shared_data'
      shared_streams = streams.grep(/\A#{Regexp.escape(prefix)}(?:\.|%2E)/)
      data_streams = shared_streams.grep(/\A#{Regexp.escape(prefix)}\.\d+\.data\z/)
      copy_streams = shared_streams.grep(/\A#{Regexp.escape(prefix)}\.copy\./)
      bucket_ids = shared_streams.map do |name|
        match = /\A#{Regexp.escape(prefix)}\.(\d+)(?:\.|%2E)/.match(name)
        match && Integer(match[1], 10)
      end.compact.uniq.sort

      family = case profile.fetch(:enum)
               when 0
                 required = ["#{prefix}.size0", "#{prefix}%2Epaths", "#{prefix}%2Evalues"]
                 fail!("#{id} MAP physical roster lacks unbucketed shared lanes: #{shared_streams.inspect}") unless
                   (required - streams).empty? && bucket_ids.empty? && data_streams.empty? && copy_streams.empty?
                 'map'
               when 1
                 bucket_lanes = shared_streams.grep(/\A#{Regexp.escape(prefix)}\.\d+(?:\.size0|%2Epaths|%2Evalues)\z/)
                 unbucketed_lanes = ["#{prefix}.size0", "#{prefix}%2Epaths", "#{prefix}%2Evalues"]
                 fail!("#{id} MAP_WITH_BUCKETS physical roster lacks bucketed lanes: #{shared_streams.inspect}") unless
                   bucket_ids == [0, 1] && bucket_lanes.any? && (unbucketed_lanes & streams).empty? &&
                   data_streams.empty? && copy_streams.empty?
                 bucket_ids.each do |bucket|
                   roles = ["#{prefix}.#{bucket}.size0", "#{prefix}.#{bucket}%2Epaths",
                            "#{prefix}.#{bucket}%2Evalues"]
                   fail!("#{id} bucket #{bucket} lacks a MAP lane: #{roles.inspect}") unless (roles - streams).empty?
                 end
                 'map_with_buckets'
               when 2, 3
                 required_copy = %w[sizes paths_indexes values].map { |lane| "#{prefix}.copy.#{lane}" }
                 required_data = [0, 1].map { |bucket| "#{prefix}.#{bucket}.data" }
                 fail!("#{id} advanced physical roster lacks emitted Data and Copy lanes: #{shared_streams.inspect}") unless
                   streams.include?('doc.object_structure') && bucket_ids == [0, 1] &&
                   (required_data - streams).empty? &&
                   (required_copy - streams).empty?
                 "advanced_#{profile.fetch(:setting)}"
               else
                 fail!("#{id} has unknown shared version enum #{profile.fetch(:enum)}")
               end
      {family: family, shared_streams: shared_streams.sort, data_streams: data_streams.sort,
       copy_streams: copy_streams.sort, bucket_ids: bucket_ids}
    end

    def assert_direct_observations!(stdout, profile)
      id = profile.fetch(:id)
      rows = tagged_rows(stdout, '__W240_DIRECT__')
      fail!("#{id} direct path stage must emit eight rows") unless rows.size == ROWS.size
      by_pk = rows.to_h do |fields|
        fail!("#{id} direct row has wrong width: #{fields.inspect}") unless fields.size == 12
        fail!("#{id} direct row has wrong profile id") unless fields[1] == id
        [Integer(fields[2]), fields.drop(3)]
      end
      fail!("#{id} direct path primary keys differ") unless by_pk.keys.sort == ROWS.map { |row| row.fetch(:pk) }
      direct = {}
      ROWS.each do |row|
        pk = row.fetch(:pk)
        witness = by_pk.fetch(pk)
        arr_type, arr_runtime_type, arr_hex, mixed_type, mixed_runtime_type, mixed_hex,
          late_type, late_runtime_type, late_hex = witness
        expected_doc = row.fetch(:doc)
        arr_value = parse_hex_json(arr_hex, "#{id} row #{pk} direct arr")
        mixed_value = parse_hex_json(mixed_hex, "#{id} row #{pk} direct mixed")
        late_value = parse_hex_json(late_hex, "#{id} row #{pk} direct late")
        fail!("#{id} row #{pk} direct arr value differs") unless arr_value == expected_doc.fetch('arr', nil)
        fail!("#{id} row #{pk} direct mixed value differs") unless mixed_value == expected_doc.fetch('mixed', nil)
        fail!("#{id} row #{pk} direct late value differs") unless late_value == expected_doc.fetch('late', nil)
        fail!("#{id} row #{pk} direct path expression type witness is absent") if
          [arr_type, mixed_type, late_type].any?(&:empty?)
        if expected_doc.key?('arr') && !expected_doc.fetch('arr').empty?
          fail!("#{id} row #{pk} nonempty direct Array(JSON) runtime type differs: #{arr_runtime_type.inspect}") unless
            array_json_type?(arr_runtime_type)
        elsif expected_doc.key?('arr')
          # JSON path inference uses schema-inference settings (DataTypeObject.cpp,
          # "Type inference for paths"). With the default
          # input_format_json_infer_incomplete_types_as_strings, the documented
          # JSONEachRow empty-array example is Array(Nullable(String))
          # (FormatFactorySettings.h). Pin that observed JSON carrier exactly;
          # the logical value assertion above independently requires [].
          fail!("#{id} row #{pk} empty arr runtime type differs: #{arr_runtime_type.inspect}") unless
            arr_runtime_type == 'Array(Nullable(String))'
        else
          fail!("#{id} row #{pk} absent arr path was not reported NULL") unless arr_runtime_type == 'NULL'
        end
        if expected_doc.key?('mixed')
          fail!("#{id} row #{pk} direct mixed runtime type witness is absent") if mixed_runtime_type.empty? || mixed_runtime_type == 'NULL'
        else
          fail!("#{id} row #{pk} absent mixed path was not reported NULL") unless mixed_runtime_type == 'NULL'
        end
        if expected_doc.key?('late')
          fail!("#{id} row #{pk} late-only Array(JSON) runtime type differs: #{late_runtime_type.inspect}") unless
            array_json_type?(late_runtime_type)
        else
          fail!("#{id} row #{pk} late-only path leaked outside the last row") unless late_runtime_type == 'NULL'
        end
        direct[pk] = {
          arr: {expression_type: arr_type, runtime_type: arr_runtime_type, value: arr_value},
          mixed: {expression_type: mixed_type, runtime_type: mixed_runtime_type, value: mixed_value},
          late: {expression_type: late_type, runtime_type: late_runtime_type, value: late_value},
        }
      end
      {rows_by_pk: direct}
    end

    def assert_full_observations!(stdout, profile)
      id = profile.fetch(:id)
      rows = tagged_rows(stdout, '__W240_FULL__')
      fail!("#{id} full-object stage must emit eight rows") unless rows.size == ROWS.size
      by_pk = rows.to_h do |fields|
        fail!("#{id} full-object row has wrong width: #{fields.inspect}") unless fields.size == 7
        fail!("#{id} full-object row has wrong profile id") unless fields[1] == id
        [Integer(fields[2]), fields.drop(3)]
      end
      fail!("#{id} full-object primary keys differ") unless by_pk.keys.sort == ROWS.map { |row| row.fetch(:pk) }
      full = {}
      ROWS.each do |row|
        pk = row.fetch(:pk)
        doc_type, doc_hex, dynamic_paths_hex, shared_paths_hex = by_pk.fetch(pk)
        expected_doc = row.fetch(:doc)
        actual_doc = parse_hex_json(doc_hex, "#{id} row #{pk} full doc")
        fail!("#{id} row #{pk} whole-column/Copy value differs") unless actual_doc == expected_doc
        fail!("#{id} row #{pk} whole-object expression type is absent") unless doc_type.include?('JSON')
        dynamic_paths = parse_hex_json(dynamic_paths_hex, "#{id} row #{pk} dynamic paths")
        shared_paths = parse_hex_json(shared_paths_hex, "#{id} row #{pk} shared paths")
        fail!("#{id} row #{pk} unexpectedly has dynamic paths: #{dynamic_paths.inspect}") unless dynamic_paths == []
        fail!("#{id} row #{pk} shared path roster differs: #{shared_paths.inspect}") unless
          shared_paths.sort == expected_doc.keys.sort
        full[pk] = {expression_type: doc_type, value: actual_doc,
                    dynamic_paths: dynamic_paths, shared_paths: shared_paths}
      end
      {rows_by_pk: full}
    end

    def join_by_pk!(direct, full, id)
      direct_rows = direct.fetch(:rows_by_pk)
      full_rows = full.fetch(:rows_by_pk)
      fail!("#{id} separately asserted direct/full pk sets differ") unless direct_rows.keys.sort == full_rows.keys.sort
      direct_rows.keys.sort.to_h do |pk|
        [pk, {direct_path_stage: direct_rows.fetch(pk), full_object_stage: full_rows.fetch(pk)}]
      end
    end

    def write_evidence(status:)
      invocations = @recorder.instance_variable_get(:@invocations)
      summary = {
        probe: 'W240 stock-only JSON-bearing inline shared Object qualification',
        status: status, fatal_error: @fatal_error,
        runtime: {path: @binary, expected_sha256: BINARY_SHA256,
                  sha256_before: @sha_before, sha256_after: @sha_after,
                  expected_version: VERSION, expected_build: BUILD},
        limits: {max_threads: 1, local_max_memory_usage_bytes: MEMORY,
                 required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        type: TYPE, fixture: ROWS,
        versions: VERSIONS.map { |profile| profile.slice(:id, :setting, :enum) },
        interpretation: {
          invocation_boundaries: 'Per profile, write/check/pin runs once; after a successful write, direct-path and full-object SELECTs run in separate fresh clickhouse-local process restarts against the same isolated local store. Each invocation has its own argv, SQL, stdout, stderr, exit status, and runtime pin capture.',
          direct_path_reads: 'A SELECT containing only doc.arr, doc.mixed, and doc.late records expression type, Dynamic runtime type, and JSON value independently. It has no full doc projection or path-roster call. This qualifies direct root-path reads, not nested-child projections inside Array(JSON).',
          binding_vs_value: 'Direct-path expression-type and Dynamic runtime-type witnesses are retained separately from parsed logical JSON values; they are not normalized into one binding claim.',
          full_column_read: 'A different SELECT uses toJSONString(doc) and path rosters as the whole-Object reconstruction/Copy witness; results are joined with direct-path observations by pk only after both sets independently pass their assertions.',
          physical_layout: 'system.parts path is validated by the W185 plain-tree inspector, which retains columns_substreams.txt, serialization.json, and hashed stream inventory. The physical roster must distinguish MAP, MAP_WITH_BUCKETS, and advanced Data plus Copy lanes.',
          numeric_rendering: 'Every invocation pins output_format_json_quote_64bit_integers=0 so JSON integer witnesses compare as numeric literals.',
          failure_policy: 'A process/SQL failure is inconclusive and is not classified as an unsupported format or compatibility rejection.',
        },
        profiles: @profiles, invocations: invocations,
        evidence_root: @root,
      }
      @recorder.send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      @recorder.send(:write_new, File.join(@root, 'summary.md'), [
        '# W240 JSON-bearing inline shared Object qualification', '',
        "Status: `#{status}`", '',
        'The fixture contains non-empty and empty Array(JSON)-shaped paths, an all-pathless row, mixed scalar runtime types, and a `late` Array(JSON) path present only at pk 8 with a late-only child. The advanced_chunked layout targets two-row chunks.', '',
        'After a successful write stage, each profile uses two additional fresh clickhouse-local process restarts on the same isolated store: direct root-path projections only; then full-object plus path-roster projection. Direct path and full-object outputs are asserted independently and joined by pk only afterward.', '',
        'Expression type, Dynamic runtime type, and logical JSON value remain separate witnesses. The direct query does not project nested children inside Array(JSON), so no nested-child selective-read claim is made. The retained part path and plain-part inventory distinguish MAP, MAP_WITH_BUCKETS, and advanced Data/Copy layouts. Runtime/SQL failures are inconclusive, never unsupported-format proof.', '',
        "Runtime: #{VERSION} / #{BUILD} / SHA256 `#{@sha_before}`", '',
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end
  end
end

def main
  options = {binary: ProbeObjectSharedJSONW240::BINARY}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_object_shared_json_w240.rb --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP [--clickhouse CLICKHOUSE]'
    parser.on('--clickhouse PATH') { |value| options[:binary] = value }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
  end.parse!
  raise 'evidence root is required via --evidence-root' unless options[:evidence_root]
  exit(ProbeObjectSharedJSONW240::Probe.new(options[:binary], options[:evidence_root]).run ? 0 : 1)
end

main if $PROGRAM_NAME == __FILE__
