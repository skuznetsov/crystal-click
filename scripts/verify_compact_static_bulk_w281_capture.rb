#!/usr/bin/env ruby
# Read-only W281 capture auditor. It never starts ClickHouse, Crystal, or a build.

require 'digest'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require_relative 'probe_compact_static_bulk_w281_matrix'

module VerifyCompactStaticBulkW281
  M = ProbeCompactStaticBulkW281Matrix
  W = M::W280
  FORMAT = M::FORMAT
  STATUS = 'generated_native_interop_matrix_exact'.freeze
  PIN_SQL = "SELECT '__W280_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;\n".b.freeze
  PIN_LINE = "__W280_PIN__\t#{W::VERSION}\t#{W::BUILD}".freeze
  MARK_ROWS = [2, 2, 2, 2, 0].freeze
  PUBLIC_ROWS = [2, 2, 2, 2].freeze
  SIDECAR_PATH = 'invalidated_system_columns.txt'.freeze
  SIDECAR_BYTES = "_block_offset\n_block_number\n".b.freeze
  SIDECAR_ENTRY = {'path' => SIDECAR_PATH, 'size' => 28,
    'sha256' => '7409424ab45090c1261e622f7423393905102e7e8cba36a6db88eb513ce1e06c'}.freeze
  REC_KEYS = %w[label process_kind argv argv_file argv_sha256 stdin_file stdin_bytes stdin_sha256
    stdout_file stdout_bytes stdout_sha256 stderr_file stderr_bytes stderr_sha256 exit signal timed_out
    timeout_seconds termination_grace_seconds max_threads max_memory_usage_bytes max_memory_usage_applicable
    required_outer_run_safe_memory_limit_bytes binary_path expected_binary_sha256 binary_sha_before
    binary_sha_after spawn_error stdin_write_error stdout_read_error stderr_read_error process_classification
    store_path].sort.freeze
  MAX_FILE = 64 * 1024 * 1024

  class Error < StandardError; end

  class Auditor
    def initialize(root)
      @root = directory!(File.expand_path(root), 'evidence root')
      @summary = JSON.parse(read_file('summary.json', 16 * 1024 * 1024))
      @expected_raw = []
      @expected_snapshots = []
      @records = {}
    rescue JSON::ParserError => e
      raise Error, "summary.json is malformed: #{e.message}"
    end

    def run
      summary_contract!
      pins!
      topology!
      invocations!
      cases!
      sidecar_inventory!
      puts "W281 capture audit passed: status=#{STATUS}; cells=4; invocations=#{@records.size}; raw snapshots=#{@expected_snapshots.size}"
      true
    rescue StandardError => e
      warn "W281 capture audit failed: #{e.class}: #{e.message}"
      false
    end

    def self.self_test!
      a = allocate
      a.instance_variable_set(:@root, '/self-test')
      a.send(:exact_status!, {'format' => FORMAT, 'status' => STATUS})
      cases = ['exact-full-matrix-status-positive']
      case_id = a.send(:expected_ids).first
      prefixes = {
        stock: File.join('/self-test','stores',case_id) + File::SEPARATOR,
        generated: File.join('/self-test','parts',case_id) + File::SEPARATOR,
        attached: File.join('/self-test','stores',"target_#{case_id}") + File::SEPARATOR,
      }
      prefixes.each do |origin,prefix|
        id = origin == :stock ? case_id : "#{case_id}_#{origin}"
        raise Error, "#{origin} part prefix seed differs" unless a.send(:part_prefix,origin,id) == prefix
      end
      cases << 'stock-generated-attached-part-prefixes-positive'
      a.send(:reject!) { a.send(:part_prefix,:attached,case_id) }
      cases << 'attached-part-origin-requires-attached-case-id-negative'
      normalized = a.send(:inventory_relative_paths,'raw-records',['raw-records/a.bin','raw-records/nested/b'])
      raise Error, 'raw inventory prefix normalization seed differs' unless normalized == ['a.bin','nested/b']
      cases << 'raw-inventory-directory-prefix-normalization-positive'
      a.send(:reject!) { a.send(:inventory_relative_paths,'raw-records',['source-inventories/a.json']) }
      cases << 'wrong-inventory-directory-prefix-negative'
      a.send(:reject!) { a.send(:exact_status!, {'format' => FORMAT, 'status' => 'generated_admission_rejection_captured'}) }
      cases << 'captured-admission-red-status-negative'
      labels = a.send(:expected_labels)
      raise Error, 'positive topology seed rejected' unless labels.size == 73 && labels.first == 'stock_bulk_mrk3_s0_create'
      cases << '73-invocation-stock-first-topology-positive'
      a.send(:reject!) { a.send(:topology_labels!, labels.drop(1)) }
      cases << 'missing-invocation-negative'
      mark = a.send(:seed_mark_bytes, 2, MARK_ROWS)
      raise Error, 'positive mark seed rejected' unless a.send(:plain_marks!, mark, 2, MARK_ROWS) == MARK_ROWS
      cases << 'raw-four-granule-plus-eof-grid-positive'
      a.send(:reject!) { a.send(:plain_marks!, mark, 2, PUBLIC_ROWS) }
      cases << 'public-grid-cannot-substitute-for-raw-grid-negative'
      tokens = a.send(:native_tokens, 0)
      escaped_tokens = a.send(:native_json_tokens, 0)
      raise Error, 'native JSON slash-escape seed differs' unless escaped_tokens.include?('\\/') &&
        JSON.parse(escaped_tokens) == tokens
      cases << 'native-json-forward-slash-escape-positive'
      a.send(:reject!) { a.send(:need!, JSON.generate(tokens) == escaped_tokens, 'unescaped JSON slash matched native wire') }
      cases << 'unescaped-native-json-forward-slash-negative'
      good, attached = a.send(:seed_inventories)
      a.send(:attached_contract!, good, attached, SIDECAR_BYTES)
      cases << 'byte-preserving-attach-plus-exact-sidecar-positive'
      a.send(:reject!) { a.send(:attached_contract!, good, attached, 'wrong'.b) }
      cases << 'wrong-sidecar-bytes-negative'
      extra = Marshal.load(Marshal.dump(attached))
      extra['files'] << {'path' => 'unapproved', 'size' => 0, 'sha256' => Digest::SHA256.hexdigest('')}
      a.send(:reject!) { a.send(:attached_contract!, good, extra, SIDECAR_BYTES) }
      cases << 'unexpected-attach-file-negative'
      puts "W281 auditor Ruby-only self-test passed: cases=#{cases.size}; #{cases.join(',')}; no filesystem or subprocess access"
      true
    rescue StandardError => e
      warn "W281 auditor self-test failed: #{e.class}: #{e.message}"
      false
    end

    private

    def need!(ok, message); raise Error, message unless ok; end
    def reject!; yield; raise Error, 'negative seed unexpectedly passed'; rescue Error => e; raise if e.message == 'negative seed unexpectedly passed'; end
    def exact_status!(s)
      need!(s.is_a?(Hash) && s['format'] == FORMAT && s['status'] == STATUS,
        "requires exact full-matrix status #{STATUS}")
    end
    def directory!(path, label)
      st = File.lstat(path)
      need!(st.directory? && !st.symlink? && File.realpath(path) == path, "#{label} is symlinked or non-canonical")
      path
    rescue Errno::ENOENT; raise Error, "#{label} is absent"
    end
    def file!(path, label, max = MAX_FILE)
      st = File.lstat(path)
      need!(st.file? && !st.symlink? && File.realpath(path) == path && st.size <= max, "#{label} is absent, unsafe, or oversized")
      path
    rescue Errno::ENOENT; raise Error, "#{label} is absent"
    end
    def read_file(rel, max = MAX_FILE)
      safe_relative!(rel,'evidence path')
      path = File.join(@root, rel)
      directory!(File.dirname(path), "parent for #{rel}")
      File.binread(file!(path, rel, max))
    end
    def sha(bytes); Digest::SHA256.hexdigest(bytes); end
    def file_sha(path, label, max = MAX_FILE); Digest::SHA256.file(file!(path, label, max)).hexdigest; end
    def expected_ids; M::MARK_FORMATS.flat_map { |mark| M::PROFILES.map { |p| "#{M::CASE}_#{mark}_#{p}" } }; end
    def expected_labels
      ids = expected_ids
      labels = ids.flat_map { |id| %w[create insert schema_part native_check].map { |x| "#{id}_#{x}" } + %w[full middle last eof].map { |w| "#{id}_values_#{w}" } }
      labels << 'nothing_schema_guard'
      labels.concat(ids.map { |id| "#{id}_helper_stock" })
      ids.each { |id| labels.concat(["#{id}_helper_write", "#{id}_target_create", "#{id}_attach", "#{id}_attached_check", "#{id}_attached_schema_part"] + %w[full middle last eof].map { |w| "#{id}_attached_values_#{w}" }) }
      labels
    end
    def topology_labels!(labels)
      need!(labels == expected_labels, 'invocation topology is missing, reordered, duplicated, or not stock-first')
    end

    def summary_contract!
      exact_status!(@summary)
      need!(@summary['evidence_root'] == @root, 'summary root differs from audit root')
      ids = expected_ids
      need!(@summary['cases'].is_a?(Hash) && @summary['cases'].keys.sort == ids.sort, 'expected exactly MRK3/MRK4 × S0/S1 cells')
      tokens = ids.map do |id|
        match = /\Aw281m_([a-zA-Z0-9]+)_#{Regexp.escape(id)}\z/.match(@summary.fetch('cases').fetch(id).fetch('table'))
        need!(match, "#{id} table name is not rooted in the W281 token namespace")
        match[1]
      end
      need!(tokens.uniq.size == 1, 'stock tables do not share exactly one capture token')
      @table_token = tokens.first
      f = @summary.fetch('fixture')
      need!(f['schema'] == M::SCHEMAS.fetch(M::CASE) && f['literal_signatures'] == M.expected_signatures &&
        f['row_count'] == 8 && f['rows_per_mark'] == 2 && f['data_marks'] == 4 &&
        f['raw_mark_file_rows'] == MARK_ROWS && f['public_reader_mark_rows'] == PUBLIC_ROWS &&
        f['native_windows'] == M::WINDOWS && f['physical_windows'] == M::PHYSICAL_WINDOWS && f['typed_windows'] == M::TYPED_WINDOWS,
        'literal schema/signature/window/grid oracle differs')
      boundary = @summary['claim_boundary'].to_s
      need!(boundary.include?('Finite eight-row') && boundary.include?('does not establish all BinaryDataType tags') &&
        boundary.include?('only the exact pinned invalidated_system_columns.txt sidecar'), 'claim boundary is missing or widened')
      need!(!boundary.match?(/CityHash|all JSON frames|arbitrary type tree support/i), 'capture claim includes a deliberately excluded mechanism')
      @summary
    rescue KeyError => e; raise Error, "summary is incomplete: #{e.message}"
    end

    def pins!
      r = @summary.fetch('runtime_pin')
      need!(r.values_at('binary', 'expected_sha256', 'sha256_before', 'sha256_after', 'version', 'build') ==
        [W::BINARY, W::BINARY_SHA256, W::BINARY_SHA256, W::BINARY_SHA256, W::VERSION, W::BUILD], 'runtime pin metadata differs')
      need!(File.executable?(file!(W::BINARY, 'pinned native runtime', 1024 * 1024 * 1024)) && file_sha(W::BINARY, 'runtime', 1024 * 1024 * 1024) == W::BINARY_SHA256, 'actual runtime bytes differ')
      s = @summary.fetch('source_pin')
      need!(s.values_at('root', 'revision_expected', 'revision_before', 'revision_after') == [W::SOURCE_ROOT, W::SOURCE_REVISION, W::SOURCE_REVISION, W::SOURCE_REVISION], 'source revision pin differs')
      out, err, status = Open3.capture3('git', '-C', W::SOURCE_ROOT, 'rev-parse', 'HEAD')
      need!(status.success? && err.empty? && out.strip == W::SOURCE_REVISION, 'current source checkout revision differs')
      before = s.fetch('source_sha256_before'); after = s.fetch('source_sha256_after')
      actual = W::SOURCE_FILES.to_h { |rel| [rel, file_sha(File.join(W::SOURCE_ROOT, rel), "source #{rel}")] }
      need!(before == after && before == actual, 'source byte seals differ from current pinned source files')
      hp = @summary.fetch('helper_pin')
      need!(hp['source'] == M::HELPER_SOURCE && hp['sha256_before'] == hp['expected_sha256'] && hp['sha256_after'] == hp['expected_sha256'], 'helper source/hash pins differ')
      helper = file!(hp.fetch('path'), 'prebuilt helper', 1024 * 1024 * 1024)
      need!(File.executable?(helper) && file_sha(helper, 'helper', 1024 * 1024 * 1024) == hp['expected_sha256'], 'actual helper bytes differ')
      pins = @summary.fetch('matrix_source_pins'); bp = pins.fetch('sha256_before'); ap = pins.fetch('sha256_after')
      paths = [M::PROBE_SOURCE, M::HELPER_SOURCE, M::FIXTURE_SOURCE].map { |p| File.realpath(p) }.uniq.sort
      cur = paths.to_h { |p| [p, file_sha(p, "matrix source #{File.basename(p)}")] }
      need!(bp == ap && bp == cur, 'matrix/helper/fixture source byte seals differ from current files')
    rescue KeyError => e; raise Error, "pin record incomplete: #{e.message}"
    end

    def topology!
      roster = @summary.fetch('invocation_roster')
      need!(roster.is_a?(Array) && roster.all? { |e| e.is_a?(Hash) && e.keys.sort == %w[argv argv_file binary_path label process_kind record_file stderr_file stdin_file stdout_file store_path].sort }, 'invocation roster field set differs')
      labels = roster.map { |e| e.fetch('label') }
      topology_labels!(labels)
      @labels = labels
      refs = Hash.new(0)
      @stage_objects = Hash.new { |h, k| h[k] = [] }
      walk = lambda do |x|
        case x
        when Hash
          if @labels.include?(x['label'])
            label = x['label']
            if x.key?('classification') && x.key?('record_file')
              refs[label] += 1
              @stage_objects[label] << x
            end
          end
          x.each { |k,v| walk.call(v) unless k == 'invocation_roster' }
        when Array; x.each { |v| walk.call(v) }
        end
      end
      walk.call(@summary)
      @stage_refs = refs
      expected_refs = @labels.to_h { |label| [label, label.end_with?('_helper_write') ? 2 : 1] }
      need!(@stage_refs == expected_refs, 'summary does not contain exactly the expected per-stage references')
    end

    def expected_spec(label)
      helper = @summary.fetch('helper_pin')
      if label.end_with?('_helper_stock') || label.end_with?('_helper_write')
        action = label.end_with?('_helper_stock') ? 'read' : 'write'; id = label.delete_suffix(action == 'read' ? '_helper_stock' : '_helper_write')
        g = @summary.fetch('cases').fetch(id)
        part = action == 'read' ? g.dig('schema_part','part','path') : File.join(@root,'parts',id,W::PART_NAME)
        return ['crystal-helper', helper['path'], nil, [helper['path'],action,M::CASE,id.split('_')[-2],id.split('_')[-1],part], 'bin', ''.b]
      end
      if label == 'nothing_schema_guard'
        id = label; table = "w281m_#{@table_token}_#{id}"; store_id = id; sql = create_sql(table,M::GUARD_SCHEMA,'mrk3','s0')
        return native_spec(store_id, "#{PIN_SQL}#{sql}", table)
      end
      id = expected_ids.find { |candidate| label == candidate || label.start_with?(candidate + '_') }
      need!(id, "unknown invocation #{label}")
      e = @summary.fetch('cases').fetch(id); mark = id.split('_')[-2]; profile = id.split('_')[-1]
      target = @summary.dig('cases',id,'library_generated','native_target') || {}
      target_table = target['table']; store_id = label.include?('_attached_') || label.end_with?('_attach') || label.end_with?('_target_create') ? "target_#{id}" : id
      case label
      when "#{id}_create" then native_spec(store_id, "#{PIN_SQL}#{create_sql(e.fetch('table'),M::SCHEMAS.fetch(M::CASE),mark,profile)}", e.fetch('table'))
      when "#{id}_insert" then rowbinary_spec(id,e,store_id)
      when "#{id}_schema_part" then native_spec(store_id,"#{PIN_SQL}#{schema_sql(id,e.fetch('table'))}",e.fetch('table'))
      when "#{id}_native_check" then native_spec(store_id,"#{PIN_SQL}#{check_sql("#{id}_native",e.fetch('table'))}",e.fetch('table'))
      when "#{id}_helper_stock" then raise Error, 'unreachable'
      when "#{id}_target_create" then native_spec(store_id,"#{PIN_SQL}#{create_sql(target_table,M::SCHEMAS.fetch(M::CASE),mark,profile)}#{target_schema_sql(id,target_table)}",target_table)
      when "#{id}_attach" then native_spec(store_id,"#{PIN_SQL}ALTER TABLE default.#{target_table} ATTACH PART '#{W::PART_NAME}';\n",target_table)
      when "#{id}_attached_check" then native_spec(store_id,"#{PIN_SQL}#{check_sql("#{id}_attached",target_table)}",target_table)
      when "#{id}_attached_schema_part" then native_spec(store_id,"#{PIN_SQL}#{schema_sql("#{id}_attached",target_table)}",target_table)
      else
        if (m = /\A#{Regexp.escape(id)}(?:_attached)?_values_(full|middle|last|eof)\z/.match(label))
          attached = label.include?('_attached_values_'); query_id = attached ? "#{id}_attached" : id
          table = attached ? target_table : e.fetch('table'); native_spec(store_id,"#{PIN_SQL}#{values_sql(query_id,table,m[1])}",table)
        else raise Error, "unclassified invocation #{label}"
        end
      end
    end

    def native_spec(store_id, sql, table)
      store = File.join(@root,'stores',store_id)
      ['clickhouse-local',W::BINARY,store,[W::BINARY,'local','--path',store,'--session_timezone=UTC','--max_threads=1',"--max_memory_usage=#{W::MEMORY_LIMIT}",'--multiquery'], 'sql', sql.b]
    end
    def rowbinary_spec(id, entry, store_id)
      rows = (0...M::ROW_COUNT).map { |i| row_binary(i) }
      literal = entry.fetch('literal_input')
      need!(literal['row_count'] == 8 && literal['query'] == "INSERT INTO default.#{entry.fetch('table')} FORMAT RowBinary" && literal['rows'].size == 8, "#{id} literal rowbinary roster differs")
      literal['rows'].each_with_index do |r,i|
        need!(r['pk'] == i+1 && r['values'] == M.expected_signatures.fetch(i) && r['rowbinary_hex'] == rows[i].unpack1('H*'), "#{id} literal row #{i+1} differs from independent Ruby oracle")
      end
      bytes=rows.join.b
      need!(literal['stdin_file']=="#{id}_insert.stdin.bin" && literal['stdin_bytes']==bytes.bytesize && literal['stdin_sha256']==sha(bytes),"#{id} literal RowBinary byte summary differs")
      store = File.join(@root,'stores',store_id); q = "INSERT INTO default.#{entry.fetch('table')} FORMAT RowBinary"
      ['clickhouse-local',W::BINARY,store,[W::BINARY,'local','--path',store,'--session_timezone=UTC','--max_threads=1',"--max_memory_usage=#{W::MEMORY_LIMIT}",'--input_format_binary_read_json_as_string=0','--query',q],'bin',rows.join.b]
    end

    def invocations!
      @records = {}; sidecars = []
      @summary.fetch('invocation_roster').each do |ro|
        label = ro.fetch('label'); expected = expected_spec(label); kind,binary,store,argv,ext,stdin = expected
        record_path = File.join(@root,'invocations',"#{label}.json"); bytes = File.binread(file!(record_path,"#{label} record")); r = JSON.parse(bytes)
        rowbinary = kind == 'clickhouse-local' && label.end_with?('_insert')
        keys = (rowbinary ? REC_KEYS + ['stdin_encoding'] : REC_KEYS).sort
        need!(r.keys.sort == keys && bytes == JSON.pretty_generate(r)+"\n", "#{label} record schema/canonical JSON differs")
        need!(r.values_at('label','process_kind','binary_path','store_path','argv','stdin_file','argv_file','stdout_file','stderr_file','expected_binary_sha256','binary_sha_before','binary_sha_after') ==
          [label,kind,binary,store,argv,"#{label}.stdin.#{ext}","#{label}.argv.json","#{label}.stdout","#{label}.stderr",kind == 'crystal-helper' ? @summary.dig('helper_pin','expected_sha256') : W::BINARY_SHA256,kind == 'crystal-helper' ? @summary.dig('helper_pin','expected_sha256') : W::BINARY_SHA256,kind == 'crystal-helper' ? @summary.dig('helper_pin','expected_sha256') : W::BINARY_SHA256], "#{label} invocation identity/argv differs")
        need!(!rowbinary || r['stdin_encoding'] == 'rowbinary', "#{label} stdin encoding differs")
        io = File.join(@root,'invocations'); argv_bytes = JSON.pretty_generate(argv)+"\n"
        sidecars.concat(["#{label}.json",r['argv_file'],r['stdin_file'],r['stdout_file'],r['stderr_file']])
        need!(read_at(io,r['argv_file']) == argv_bytes && r['argv_sha256'] == sha(argv_bytes), "#{label} argv bytes/hash differ")
        got = read_at(io,r['stdin_file']); need!(got == stdin && r['stdin_bytes'] == got.bytesize && r['stdin_sha256'] == sha(got), "#{label} stdin bytes/hash differ")
        stdout = read_at(io,r['stdout_file']); stderr = read_at(io,r['stderr_file'])
        need!(r['stdout_bytes'] == stdout.bytesize && r['stdout_sha256'] == sha(stdout) && r['stderr_bytes'] == stderr.bytesize && r['stderr_sha256'] == sha(stderr), "#{label} stdout/stderr byte or hash record differs")
        resources!(label,r,kind,stdout,stderr)
        @records[label] = r
        roster_match!(ro,r)
      end
      need!(Dir.children(File.join(@root,'invocations')).sort == sidecars.sort, 'invocation sidecar directory has missing or extra files')
      need!(@stage_refs.keys.sort == @records.keys.sort, 'some raw invocation lacks an exact summary stage reference')
      validate_stage_references!
    rescue KeyError, JSON::ParserError => e; raise Error, "invocation evidence incomplete: #{e.message}"
    end
    def read_at(dir, name)
      safe_relative!(name, 'invocation sidecar path')
      path = File.join(dir, name); file!(path,name); File.binread(path)
    end
    def safe_relative!(name, label)
      need!(name.is_a?(String) && !name.empty? && !name.start_with?('/') &&
        name.split(/[\\\/]/,-1).none? { |p| ['', '.', '..'].include?(p) }, "#{label} is unsafe")
      name
    end
    def validate_stage_references!
      @stage_objects.each do |label, stages|
        r = @records.fetch(label)
        stages.each do |x|
          expected = {'label'=>label,'classification'=>r['process_classification'],'exit'=>r['exit'],'signal'=>r['signal'],
            'stdout_file'=>r['stdout_file'],'stdout_bytes'=>r['stdout_bytes'],'stdout_sha256'=>r['stdout_sha256'],
            'stderr_file'=>r['stderr_file'],'stderr_bytes'=>r['stderr_bytes'],'stderr_sha256'=>r['stderr_sha256'],
            'argv_file'=>r['argv_file'],'argv'=>r['argv'],'stdin_file'=>r['stdin_file'],'stdin_bytes'=>r['stdin_bytes'],
            'stdin_sha256'=>r['stdin_sha256'],'record_file'=>"#{label}.json"}
          need!(x == expected, "#{label} stage reference differs from its raw invocation")
        end
      end
    end
    def roster_match!(ro,r)
      %w[label process_kind binary_path store_path argv stdin_file argv_file stdout_file stderr_file record_file].each do |k|
        actual = k == 'record_file' ? "#{r['label']}.json" : r[k]; need!(ro[k] == actual, "roster #{r['label']}.#{k} differs")
      end
    end
    def resources!(label,r,kind,stdout,stderr)
      c = W::W241; helper = kind == 'crystal-helper'
      need!(r.values_at('timeout_seconds','termination_grace_seconds','required_outer_run_safe_memory_limit_bytes','max_threads','max_memory_usage_bytes','max_memory_usage_applicable') ==
        [c::TIMEOUT,c::GRACE,c::OUTER_RUN_SAFE_LIMIT,helper ? nil : 1,helper ? nil : c::MEMORY, !helper], "#{label} timeout/resource contract differs")
      good = r['timed_out']==false && r['signal'].nil? && %w[spawn_error stdin_write_error stdout_read_error stderr_read_error].all? { |k| r[k].nil? }
      if label == 'nothing_schema_guard'
        need!(good && r['exit'].is_a?(Integer) && r['exit'] != 0 && r['process_classification'] == 'server_exception' && stderr.include?('Code: 370') && stdout.start_with?(PIN_LINE+"\n"), 'Nothing guard is not the sole captured Code370 server rejection')
      else
        need!(good && r['exit'] == 0 && r['process_classification'] == 'success' && stderr.empty?, "#{label} did not complete cleanly or was timed out")
      end
    end

    def cases!
      ids = expected_ids
      ids.each do |id|
        e = @summary.fetch('cases').fetch(id); mark=id.split('_')[-2]; profile=id.split('_')[-1]
        token = /\Aw281m_([a-zA-Z0-9]+)_#{Regexp.escape(id)}\z/.match(e['table'])&.[](1)
        need!(token && (!@table_token || token == @table_token), "#{id} table identity/token differs"); @table_token=token
        need!(e.values_at('case_id','schema_kind','mark_format','string_profile','status') == [id,M::CASE,mark,profile,'exact_native_values'], "#{id} stock cell status/schema differs")
        need!(e['store'] == File.join(@root,'stores',id) && e['schema_parameters'] == {
          'object_serialization_version'=>'v3','object_shared_data_serialization_version'=>'map','map_layout_value'=>0,'object_shared_data_buckets_for_compact_part'=>1,
          'string_serialization_version'=>profile == 's1' ? 'with_size_stream' : 'single_stream','mark_compression'=>'plain','variant_discriminator_mode'=>'basic'}, "#{id} stock settings/store differ")
        stage!("#{id}_create",e['create']); stage!("#{id}_insert",e['insert']); stage!("#{id}_schema_part",e.dig('schema_part','invocation')); stage!("#{id}_native_check",e.dig('check','invocation'))
        sql_stdout!("#{id}_create", [PIN_LINE]); sql_stdout!("#{id}_insert", [])
        native_schema!(id,e.fetch('schema_part'),e.fetch('table'))
        check_stdout!("#{id}_native",e.fetch('check'))
        validate_windows!(id,e.fetch('table'),e.fetch('windows'),false)
        raw=e.dig('schema_part','part','raw_capture'); validate_part!(id,mark,e.dig('schema_part','part','path'),raw.fetch('inventory'),raw.fetch('snapshot'),raw.fetch('callback_roster'),raw.fetch('serialization_metadata'),raw.fetch('serialization_metadata_sha256'),raw.fetch('serialization_metadata_raw_file'),raw.fetch('mark_file'),raw.fetch('mark_bytes'),raw.fetch('mark_sha256'),:stock)
        read=e.fetch('library_stock_read'); need!(read['status']=='exact_public_recursive_and_typed_reads', "#{id} stock helper read not exact")
        helper_report!(id,mark,profile,read.fetch('report'),read.fetch('invocation'),'read',e.dig('schema_part','part','path'))
        g=e.fetch('library_generated'); need!(g['status']=='exact_generated_native_interop', "#{id} generated status not exact")
        need!(g.dig('helper_report','status')=='exact_public_recursive_and_typed_reads',"#{id} generated helper wrapper status differs")
        target=g.fetch('native_target'); tt="w281m_#{@table_token}_target_#{id}"; need!(target['state']=='ready' && target['table']==tt && target['store']==File.join(@root,'stores',"target_#{id}"), "#{id} target identity differs")
        stage!("#{id}_helper_stock",read.fetch('invocation')); helper_report!(id,mark,profile,g.dig('helper_report','report'),g.fetch('helper_invocation'),'write',File.join(@root,'parts',id,W::PART_NAME))
        stage!("#{id}_target_create",target.fetch('create')); target_create_stdout!(id,target)
        stage!("#{id}_attach",g.dig('attach','invocation')); sql_stdout!("#{id}_attach",[PIN_LINE])
        stage!("#{id}_attached_check",g.dig('check','invocation')); check_stdout!("#{id}_attached",g.fetch('check'))
        active=g.dig('active_part','part'); need!(active,'attached active part absent')
        stage!("#{id}_attached_schema_part",g.dig('active_part','invocation')); native_schema!("#{id}_attached",g.fetch('active_part'),tt)
        validate_windows!(id,tt,g.fetch('native_windows'),true)
        genpath=File.join(@root,'parts',id,W::PART_NAME); validate_part!("#{id}_generated",mark,g['part_path'],g['inventory'],g['part_snapshot'],g['callback_roster'],g.dig('serialization_metadata','parsed'),g.dig('serialization_metadata','raw_sha256'),"raw-records/#{id}_generated.serialization.json","data.#{mark}",nil,nil,:generated)
        ar=active.dig('raw_capture'); validate_part!("#{id}_attached",mark,active['path'],ar['inventory'],ar['snapshot'],ar['callback_roster'],ar['serialization_metadata'],ar['serialization_metadata_sha256'],ar['serialization_metadata_raw_file'],ar['mark_file'],ar['mark_bytes'],ar['mark_sha256'],:attached)
        attached_contract!(g.fetch('inventory'),ar.fetch('inventory'),File.binread(File.join(active['path'],SIDECAR_PATH)))
        need!(g.dig('attach','source_inventory') == g['inventory'] && g.dig('attach','detached_inventory') == g['inventory'], "#{id} detached part changed before ATTACH")
        need!(g['attached_inventory_contract']['state']=='generated_files_byte_preserved_with_exact_native_sidecar', "#{id} ATTACH summary contract differs")
      end
      guard=@summary.fetch('nothing_guard'); need!(guard.values_at('status','schema','expected_server_code','observed_server_code') == ['rejected_expected_code_370',M::GUARD_SCHEMA,370,370], 'Nothing guard is not the explicit stock Code370 control')
      stage!('nothing_schema_guard',guard.fetch('invocation'))
      sql_stdout!('nothing_schema_guard',[PIN_LINE])
    rescue KeyError, TypeError => e; raise Error, "cell evidence incomplete: #{e.message}"
    end

    def stage!(label,stage)
      need!(stage.is_a?(Hash) && @records.key?(label), "#{label} stage/raw record missing")
      r=@records.fetch(label)
      %w[label classification exit signal stdout_file stdout_bytes stdout_sha256 stderr_file stderr_bytes stderr_sha256 argv_file argv stdin_file stdin_bytes stdin_sha256 record_file].each do |k|
        v=k=='record_file' ? "#{label}.json" : (k=='classification' ? r['process_classification'] : r[k])
        need!(stage[k]==v,"#{label} stage field #{k} differs from raw record")
      end
    end
    def sql_stdout!(label,lines)
      out=read_at(File.join(@root,'invocations'),"#{label}.stdout")
      need!(out==((lines.empty? ? [] : lines).join("\n")+(lines.empty? ? '' : "\n")).b, "#{label} native stdout differs from reconstructed rows")
    end
    def tag(kind,id,window=nil); "__W280M_#{kind.upcase}_#{id.upcase}#{window ? "_#{window.upcase}" : ''}__"; end
    def schema_sql(id,table)
      "SELECT '#{tag('schema',id)}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
      "SELECT '#{tag('part',id)}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;\n" \
      "SELECT '#{tag('table_path',id)}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
    end
    def target_schema_sql(id,table)
      "SELECT '#{tag('target_schema',id)}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
      "SELECT '#{tag('target_path',id)}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
    end
    def check_sql(id,table)
      b=tag('check_begin',id); e=tag('check_end',id)
      "SELECT '#{b}' FORMAT TSVRaw;\nCHECK TABLE default.#{table} FORMAT TSV;\nSELECT '#{e}' FORMAT TSVRaw;\n"
    end
    def create_sql(table,schema,mark,profile)
      declarations=schema.map { |n,t| "`#{n}` #{t}" }.join(', ')
      settings=['index_granularity=2','index_granularity_bytes=10485760','enable_mixed_granularity_parts=1','min_rows_for_wide_part=1000000','min_bytes_for_wide_part=104857600','min_level_for_wide_part=0','compress_marks=0',"marks_compression_codec='LZ4'",'compress_primary_key=0','write_final_mark=1',"write_marks_for_substreams_in_compact_parts=#{mark=='mrk4' ? 1 : 0}",'min_compress_block_size=0','max_compress_block_size=4096','ratio_of_defaults_for_sparse_serialization=1.0',"default_compression_codec='LZ4'","serialization_info_version='with_types'",'propagate_types_serialization_versions_to_nested_types=true',"string_serialization_version='#{profile=='s1' ? 'with_size_stream' : 'single_stream'}'","object_serialization_version='v3'","object_shared_data_serialization_version='map'","object_shared_data_serialization_version_for_zero_level_parts='map'",'object_shared_data_buckets_for_compact_part=1','object_shared_data_target_chunk_rows=1',"dynamic_serialization_version='v3'",'use_compact_variant_discriminators_serialization=0','allow_suspicious_low_cardinality_types=1'].join(', ')
      "SET flatten_nested=0;\nSET allow_suspicious_low_cardinality_types=1;\nSET use_variant_as_common_type=1;\nCREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};\n"
    end
    def values_sql(id,table,window)
      t=tag('values',id,window); predicate=M::WINDOWS.fetch(window)
      return "SELECT '#{t}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n" if window=='eof'
      where=predicate ? " WHERE #{predicate}" : ''
      "SELECT '#{t}', toString(pk), lower(hex(toJSONString([#{projection_sql.join(', ')}]))) FROM default.#{table}#{where} ORDER BY pk SETTINGS output_format_json_named_tuples_as_objects=0 FORMAT TSVRaw;\n"
    end
    def projection_sql
      bulk="tupleElement(`#{M::COLUMN}`, 2)"; field=lambda { |n| i=M::STOCK_FIELDS.index { |f| f[0]==n } or raise Error,"unknown field #{n}"; "tupleElement(#{bulk}, #{i+1})" }
      raw=lambda { |x| "lower(hex(reinterpretAsFixedString(#{x})))" }; st=lambda { |x| "concat(toString(length(#{x})), ':', lower(hex(#{x})))" }; ns=lambda { |x| "if(isNull(#{x}), 'N', concat('V', #{st.call("ifNull(#{x}, '')")}))" }; pt=lambda { |x| "concat(#{raw.call("tupleElement(#{x}, 1)")}, '/', #{raw.call("tupleElement(#{x}, 2)")})" }
      p=M::FIXED_FIELDS.map { |n,_,_| "concat('#{n}:', #{raw.call(field.call(n))})" }
      p += ["'empty_tuple:Tuple()'", "concat('text:S', #{st.call(field.call('text'))})"]
      %w[text_runs empty_texts].each do |n|
        x=field.call(n); p << "concat('#{n}:A', toString(length(#{x})), '[', arrayStringConcat(arrayMap(item -> #{st.call('item')}, #{x}), ';'), ']')"
      end
      p << "concat('maybe_text:', #{ns.call(field.call('maybe_text'))})"
      x=field.call('maybe_u16'); p << "if(isNull(#{x}), 'maybe_u16:N', concat('maybe_u16:V', #{raw.call("assumeNotNull(#{x})")}))"
      x=field.call('array_pairs'); p << "concat('array_pairs:A', toString(length(#{x})), '[', arrayStringConcat(arrayMap(item -> concat(toString(tupleElement(item, 1)), '/', #{ns.call('tupleElement(item, 2)')}), #{x}), ';'), ']')"
      x=field.call('lookup'); p << "concat('lookup:A', toString(length(mapKeys(#{x}))), '[', arrayStringConcat(arrayMap((key, value) -> concat(#{st.call('key')}, '/', #{ns.call('value')}), mapKeys(#{x}), mapValues(#{x})), ';'), ']')"
      x=field.call('nested_labels'); p << "concat('nested_labels:A', toString(length(#{x})), '[', arrayStringConcat(arrayMap(item -> concat(#{st.call("tupleElement(item, 1)")}, '/', if(isNull(tupleElement(item, 2)), 'N', concat('V', toString(assumeNotNull(tupleElement(item, 2)))))), #{x}), ';'), ']')"
      x=field.call('plain_tuple'); p << "concat('plain_tuple:', #{raw.call("tupleElement(#{x}, 1)")}, '/', #{st.call("tupleElement(#{x}, 2)")})"
      x=field.call('point'); p << "concat('point:', #{pt.call(x)})"
      x=field.call('multipoint'); p << "concat('multipoint:A', toString(length(#{x})), '[', arrayStringConcat(arrayMap(item -> #{pt.call('item')}, #{x}), ';'), ']')"
      x=field.call('maybe_point'); p << "if(isNull(#{x}), 'maybe_point:N', concat('maybe_point:V', #{pt.call("assumeNotNull(#{x})")}))"
      p << "concat('sum_state:', toString(#{field.call('sum_state')}))"; p
    end

    def native_schema!(id,physical,table)
      schema=M::SCHEMAS.fetch(M::CASE).map { |n,t| [n,t.gsub(/\s+/,'')] }
      need!(physical['state']=='observed' && physical['schema']==schema && physical['expected_schema']==schema,"#{id} native schema differs")
      part=physical.fetch('part'); path=part.fetch('path'); row=part.fetch('row')
      directory!(path,"#{id} active part")
      table_path=physical.fetch('table_data_path'); table_dir=table_path.delete_suffix(File::SEPARATOR)
      directory!(table_dir,"#{id} table data path")
      need!(File.dirname(path)==table_dir && part_name(path)==W::PART_NAME,"#{id} active part path/name differs")
      tag_part=tag('part',id); expected_row=[tag_part,table,W::PART_NAME,path+File::SEPARATOR,'Compact',M::ROW_COUNT.to_s,'5']
      need!(physical['active_parts']==[expected_row] && row==expected_row,"#{id} active physical part row differs")
      schema_tag=tag('schema',id); path_tag=tag('table_path',id)
      lines=stdout_lines("#{id}_schema_part")
      got_schema=lines.drop(1).take(schema.size).map { |line| line.split("\t",-1) }
      need!(got_schema.size==schema.size && got_schema.each_with_index.all? { |r,i| r.size==3 && r[0]==schema_tag && r[1]==schema[i][0] && r[2].gsub(/\s+/,'')==schema[i][1] },"#{id} native schema stdout differs")
      expected_tail=[expected_row.join("\t"),[path_tag,table_path].join("\t")]
      need!(lines.size==1+schema.size+expected_tail.size && lines.drop(1+schema.size)==expected_tail,"#{id} schema/part/path stdout has extra or missing rows")
      need!(physical.dig('part','path')==path && File.dirname(path)==table_dir,"#{id} part is not directly under queried table path")
      true
    end
    def part_name(path); File.basename(path); end
    def native_target_lines(id,target)
      table=target.fetch('table'); path=target.fetch('data_path'); tag_name=tag('target_schema',id); tag_path=tag('target_path',id)
      lines=stdout_lines("#{id}_target_create")
      schema=M::SCHEMAS.fetch(M::CASE).map { |n,t| [n,t.gsub(/\s+/,'')] }
      got=lines.drop(1).take(schema.size).map { |line| line.split("\t",-1) }
      need!(got.size==schema.size && got.each_with_index.all? { |r,i| r.size==3 && r[0]==tag_name && r[1]==schema[i][0] && r[2].gsub(/\s+/,'')==schema[i][1] },"#{id} native target schema stdout differs")
      tail=lines.drop(1+schema.size)
      need!(tail.size==1,"#{id} target creation emitted unexpected rows")
      f=tail.first.split("\t",-1)
      need!(f.size==2 && f[0]==tag_path && f[1].delete_suffix(File::SEPARATOR)==path,"#{id} native target path stdout differs")
      directory!(path,"#{id} target data path")
      true
    end
    def target_create_stdout!(id,target)
      native_target_lines(id,target)
    end
    def check_stdout!(id,check)
      need!(check['state']=='healthy',"#{id} native CHECK is not healthy")
      begin_tag=tag('check_begin',id); end_tag=tag('check_end',id); row="#{W::PART_NAME}\t1\t"
      need!(check['rows']==[row],"#{id} native CHECK summary differs")
      need!(stdout_lines("#{id}_check")==[PIN_LINE,begin_tag,row,end_tag],"#{id} native CHECK stdout differs")
      true
    end
    def stdout_lines(label)
      bytes=read_at(File.join(@root,'invocations'),"#{label}.stdout"); text=bytes.dup.force_encoding(Encoding::UTF_8)
      need!(text.valid_encoding? && text.end_with?("\n"),"#{label} stdout is not newline-terminated UTF-8")
      lines=text.split("\n",-1); lines.pop; need!(lines.shift==PIN_LINE,"#{label} runtime pin output differs"); lines.unshift(PIN_LINE); lines
    end
    def helper_report!(id,mark,profile,report,invocation,action,part)
      need!(report.is_a?(Hash) && report.keys.sort==%w[action case data_mark_count format mark_format part_origin part_path public_reader_grid public_reader_mark_count public_reader_mark_rows recursive_windows row_count schema status string_profile typed_windows].sort,"#{id} helper report field set differs")
      origin=action=='read' ? 'stock' : 'generated'; expected_schema=M::SCHEMAS.fetch(M::CASE).last.last.gsub(/\s+/,'')
      need!(report.values_at('format','action','case','mark_format','string_profile','status','row_count','data_mark_count','part_origin','public_reader_grid','public_reader_mark_count','public_reader_mark_rows','part_path')==
        [M::HELPER_FORMAT,action,M::CASE,mark,profile,'ok',8,4,origin,'nonempty_data_marks',4,PUBLIC_ROWS,part] && report['schema'].gsub(/\s+/,'')==expected_schema,"#{id} helper report envelope differs")
      sig=M.expected_signatures; windows={'full'=>sig,'middle'=>sig.drop(2).take(4),'last'=>sig.drop(6).take(2),'eof'=>[]}
      rec=report.fetch('recursive_windows'); typed=report.fetch('typed_windows')
      need!(rec.keys.sort==M::WINDOWS.keys.sort && typed.keys.sort==M::WINDOWS.keys.sort,"#{id} helper window roster differs")
      windows.each do |w,expected|
        need!(rec.fetch(w)=={'signatures'=>expected,'first_mark'=>M::PHYSICAL_WINDOWS.fetch(w)[0],'mark_count'=>M::PHYSICAL_WINDOWS.fetch(w)[1]} &&
          typed.fetch(w)=={'signatures'=>expected,'start_row'=>M::TYPED_WINDOWS.fetch(w)[0],'row_count'=>expected.size},"#{id}/#{w} helper recursive/typed result differs")
      end
      label=action=='read' ? "#{id}_helper_stock" : "#{id}_helper_write"; bytes=read_at(File.join(@root,'invocations'),"#{label}.stdout")
      parsed=JSON.parse(bytes); need!(bytes.lines.size==1 && parsed==report,"#{label} stdout JSON differs from report")
      true
    rescue KeyError,TypeError,NoMethodError,JSON::ParserError=>e; raise Error,"#{id} helper report incomplete: #{e.message}"
    end
    def validate_windows!(id,table,windows,attached)
      query_id=attached ? "#{id}_attached" : id
      need!(windows.is_a?(Hash) && windows.keys.sort==M::WINDOWS.keys.sort,"#{query_id} native window roster differs")
      M::WINDOWS.each_key do |w|
        entry=windows.fetch(w); label="#{query_id}_values_#{w}"
        need!(entry['state']=='exact_values',"#{label} is not exact")
        expected_sql=PIN_SQL+values_sql(query_id,table,w).b
        stdin_file=@records.fetch(label).fetch('stdin_file')
        need!(read_at(File.join(@root,'invocations'),stdin_file)==expected_sql,"#{label} SQL differs from reconstructed query")
        rows=if w=='eof'
          [[tag('values',query_id,w),'0']]
        else
          indexes={'full'=>(0...8).to_a,'middle'=>(2...6).to_a,'last'=>(6...8).to_a}.fetch(w)
          indexes.map { |i| [tag('values',query_id,w),(i+1).to_s,native_json_tokens(i).unpack1('H*')] }
        end
        expected_stdout=([PIN_LINE]+rows.map { |r| r.join("\t") }).join("\n")+"\n"
        got=read_at(File.join(@root,'invocations'),"#{label}.stdout")
        need!(got==expected_stdout.b,"#{label} raw native output differs from literal Ruby projection")
        actual_rows=w=='eof' ? rows : rows.map { |r| {'pk'=>Integer(r[1],10),'fields'=>native_tokens(Integer(r[1],10)-1)} }
        summary_rows=w=='eof' ? rows : rows.map { |r| r }
        need!(entry['rows']==actual_rows && entry['expected_rows']==(w=='eof' ? rows : actual_rows),"#{label} summary rows differ from raw output/oracle")
        need!(w=='eof' || entry['raw_rows']==summary_rows,"#{label} summary raw rows differ")
      end
    rescue KeyError,TypeError,ArgumentError=>e; raise Error,"#{query_id} window evidence incomplete: #{e.message}"
    end
    def native_tokens(row)
      v=M.row_model(row); tok=M::FIXED_FIELDS.map { |n,_,_| "#{n}:#{v.fetch(n).unpack1('H*')}" }
      st=->(x){"#{x.bytesize}:#{x.unpack1('H*')}"}; ns=->(x){x.nil? ? 'N' : "V#{st.call(x)}"}; pt=->(x){"#{x[0].unpack1('H*')}/#{x[1].unpack1('H*')}"}
      tok += ['empty_tuple:Tuple()',"text:S#{st.call(v['text'])}","text_runs:A#{v['text_runs'].size}[#{v['text_runs'].map { |x| st.call(x) }.join(';')}]",'empty_texts:A0[]',"maybe_text:#{ns.call(v['maybe_text'])}","maybe_u16:#{v['maybe_u16'] ? "V#{v['maybe_u16'].unpack1('H*')}" : 'N'}"]
      tok << "array_pairs:A#{v['array_pairs'].size}[#{v['array_pairs'].map { |k,x| "#{k}/#{ns.call(x)}" }.join(';')}]"
      tok << "lookup:A#{v['lookup'].size}[#{v['lookup'].map { |k,x| "#{st.call(k)}/#{ns.call(x)}" }.join(';')}]"
      tok << "nested_labels:A#{v['nested_labels'].size}[#{v['nested_labels'].map { |k,x| "#{st.call(k)}/#{x.nil? ? 'N' : "V#{x.unpack1('C')}"}" }.join(';')}]"
      q=v['plain_tuple']; tok << "plain_tuple:#{q[0].unpack1('H*')}/#{st.call(q[1])}"
      tok << "point:#{pt.call(v['point'])}"; tok << "multipoint:A#{v['multipoint'].size}[#{v['multipoint'].map { |x| pt.call(x) }.join(';')}]"
      tok << "maybe_point:#{v['maybe_point'] ? "V#{pt.call(v['maybe_point'])}" : 'N'}"; tok << "sum_state:#{row+501}"; tok
    end
    # The finite native token corpus contains ASCII delimiters only. Match
    # ClickHouse toJSONString's forward-slash escaping without altering the
    # reconstructed semantic token projection above. Its fixture model is
    # shared with the matrix and is not an independent semantic oracle.
    def native_json_tokens(row)
      JSON.generate(native_tokens(row)).gsub('/') { '\\/' }
    end
    def row_binary(row)
      v=M.row_model(row); body=M::FIXED_FIELDS.map { |n,_,_| v.fetch(n) }
      string=->(x){varuint(x.bytesize)+x.b}; nullable=->(x){x.nil? ? "\x01".b : "\x00".b+string.call(x)}; nullable_fixed=->(x){x.nil? ? "\x01".b : "\x00".b+x.b}; arr=->(xs){varuint(xs.size)+xs.join.b}
      body += [''.b,string.call(v['text']),arr.call(v['text_runs'].map { |x| string.call(x) }),arr.call([]),nullable.call(v['maybe_text']),nullable_fixed.call(v['maybe_u16']),
        arr.call(v['array_pairs'].map { |k,x| [k].pack('S<').b+nullable.call(x) }),arr.call(v['lookup'].map { |k,x| string.call(k)+nullable.call(x) }),
        arr.call(v['nested_labels'].map { |k,x| string.call(k)+nullable_fixed.call(x) }),v['plain_tuple'][0]+string.call(v['plain_tuple'][1]),
        v['point'].join.b,arr.call(v['multipoint'].map(&:join)),nullable_fixed.call(v['maybe_point']&.join),v['sum_state']]
      [row+1].pack('Q<').b+varuint(1)+string.call('id')+[row+1].pack('Q<').b+body.join.b
    end
    def varuint(value)
      n=value; b=[]; loop { x=n&0x7f; n >>= 7; b << (n.zero? ? x : x|0x80); break if n.zero? }; b.pack('C*').b
    end
    def validate_part!(id,mark,path,inventory,snapshot,callback,parsed_metadata,metadata_sha,metadata_file,mark_file,mark_bytes,mark_sha,origin)
      directory!(path,"#{id} part")
      prefix=part_prefix(origin,id)
      need!(path.start_with?(prefix),"#{id} part escaped its source tree")
      inv=inventory!(inventory,id); need!(disk_inventory(path)==inv,"#{id} current part inventory differs")
      safe=id.gsub(/[^a-zA-Z0-9_.-]/,'_'); snap_name="source-inventories/#{safe}.json"
      need!(snapshot.is_a?(Hash) && snapshot['inventory']==inv && snapshot['raw_prefix']=="raw-records/#{id}." && snapshot['inventory_file']==snap_name,"#{id} snapshot references differ")
      snap_bytes=read_file(snap_name); snap=JSON.parse(snap_bytes)
      need!(snap['case_name']==id && snap['source_part_path']==path && snap['inventory']==inv && snap['callback_roster']==callback,"#{id} persisted snapshot differs from source bytes")
      @expected_snapshots << snap_name
      metadata_path=File.join(path,'serialization.json'); metadata_raw=File.binread(file!(metadata_path,"#{id} serialization metadata")); metadata=JSON.parse(metadata_raw)
      raw_name="raw-records/#{safe}.serialization.json"
      need!(parsed_metadata==metadata && metadata_sha==sha(metadata_raw) && metadata_file==raw_name,"#{id} serialization metadata summary differs")
      snapshot_meta=snap.fetch('serialization_metadata')
      need!(snapshot_meta['raw']==metadata_raw && snapshot_meta['raw_sha256']==sha(metadata_raw) && (snapshot_meta['parsed'].nil? || snapshot_meta['parsed']==metadata),"#{id} snapshot metadata differs from current bytes")
      inv.fetch('files').each do |item|
        rel=item.fetch('path'); safe_relative!(rel,"#{id} inventory path")
        actual=File.binread(file!(File.join(path,rel),"#{id}/#{rel}"))
        need!(actual.bytesize==item['size'] && sha(actual)==item['sha256'],"#{id}/#{rel} bytes differ from inventory")
        raw="raw-records/#{safe}.#{rel}"; need!(read_file(raw)==actual,"#{id}/#{rel} raw copy differs"); @expected_raw << raw
      end
      need!(mark_file=="data.#{mark}","#{id} raw mark filename differs")
      mark_raw=File.binread(file!(File.join(path,mark_file),"#{id} #{mark_file}")); mark_entry=inv.fetch('files').find { |f| f['path']==mark_file }
      need!(mark_entry && (!mark_bytes || mark_bytes==mark_raw.bytesize) && (!mark_sha || mark_sha==sha(mark_raw)) && mark_entry['size']==mark_raw.bytesize && mark_entry['sha256']==sha(mark_raw),"#{id} raw mark capture differs")
      validate_callback!(id,mark,path,inv,callback)
      slots=callback.fetch('roster').size; need!(plain_marks!(mark_raw,slots,MARK_ROWS)==MARK_ROWS,"#{id} plain mark grid differs")
      @expected_snapshots << "source-inventories/#{safe}.columns_substreams.txt" if mark=='mrk4'
      true
    rescue KeyError,JSON::ParserError=>e; raise Error,"#{id} part evidence incomplete: #{e.message}"
    end
    def inventory!(inv,label)
      need!(inv.is_a?(Hash) && inv.keys.sort==%w[files total_bytes] && inv['files'].is_a?(Array) && inv['total_bytes'].is_a?(Integer),"#{label} inventory malformed")
      files=inv['files']; paths=files.map do |f|
        need!(f.is_a?(Hash) && f.keys.sort==%w[path sha256 size] && f['size'].is_a?(Integer) && f['size']>=0 && f['sha256'].is_a?(String) && f['sha256'].match?(/\A[0-9a-f]{64}\z/),"#{label} inventory entry malformed")
        safe_relative!(f['path'],"#{label} inventory path"); f['path']
      end
      need!(paths==paths.uniq.sort && inv['total_bytes']==files.sum { |f| f['size'] },"#{label} inventory paths/total differ")
      inv
    end
    def disk_inventory(path)
      files=[]; total=0
      Find.find(path) do |entry|
        next if entry==path; st=File.lstat(entry); need!(!st.symlink?,"symlink in part tree")
        next if st.directory?; need!(st.file? && st.size<=64*1024*1024,"non-regular or oversized part file")
        files << {'path'=>entry.delete_prefix(path+File::SEPARATOR),'size'=>st.size,'sha256'=>file_sha(entry,'part file')}; total+=st.size
        need!(files.size<=256 && total<=128*1024*1024,"part inventory bound exceeded")
      end
      {'files'=>files.sort_by { |f| f['path'] },'total_bytes'=>total}
    end
    def validate_callback!(id,mark,path,inv,callback)
      cols=M::SCHEMAS.fetch(M::CASE).map(&:first)
      if mark=='mrk3'
        roster=cols.each_with_index.map { |col,i| [i,col,nil] }
        need!(callback=={'state'=>'mrk3_single_unlabelled_slot_per_column','sections'=>nil,'roster'=>roster,'text'=>nil,'sha256'=>nil} && inv['files'].none? { |f| f['path']=='columns_substreams.txt' },"#{id} MRK3 callback roster differs")
      else
        name='columns_substreams.txt'; bytes=File.binread(file!(File.join(path,name),"#{id} MRK4 roster")); entry=inv['files'].find { |f| f['path']==name }
        sections,roster=parse_mrk4(bytes,cols,id); text=bytes.dup.force_encoding(Encoding::UTF_8).to_s
        need!(entry && entry['sha256']==sha(bytes) && callback=={'state'=>'native_substream_callback_roster_observed','text'=>text,'sections'=>sections,'roster'=>roster,'sha256'=>sha(bytes)},"#{id} MRK4 callback roster differs")
        saved="source-inventories/#{id}.columns_substreams.txt"; need!(read_file(saved)==bytes,"#{id} MRK4 source roster sidecar differs")
      end
    end
    def parse_mrk4(bytes,columns,label)
      text=bytes.dup.force_encoding(Encoding::UTF_8); need!(text.valid_encoding?,"#{label} MRK4 roster invalid UTF-8")
      lines=text.split("\n",-1); need!(lines.pop=='' && lines.shift=='columns substreams version: 1',"#{label} MRK4 roster header differs")
      header=/\A(0|[1-9][0-9]*) columns:\z/.match(lines.shift.to_s); need!(header && Integer(header[1],10)==columns.size,"#{label} MRK4 column count differs")
      sections=[]
      until lines.empty?
        m=/\A(0|[1-9][0-9]*) substreams for column `([a-z][a-z0-9_]*)`:\z/.match(lines.shift.to_s); need!(m,"#{label} MRK4 section malformed")
        n=Integer(m[1],10); need!(n.between?(1,512) && lines.size>=n,"#{label} MRK4 slot count invalid")
        streams=n.times.map { s=/\A\t([A-Za-z0-9_.%]+)\z/.match(lines.shift.to_s); need!(s,"#{label} MRK4 stream malformed"); s[1] }
        need!(streams.uniq==streams,"#{label} MRK4 duplicate stream"); sections << [m[2],streams]
      end
      need!(sections.map(&:first)==columns,"#{label} MRK4 column order differs")
      flat=sections.flat_map { |col,streams| streams.map { |s| [col,s] } }
      [sections,flat.each_with_index.map { |(col,s),i| [i,col,s] }]
    end
    def plain_marks!(bytes,slots,expected)
      stride=slots*16+8; need!(slots.is_a?(Integer) && slots>0 && bytes.bytesize==stride*expected.size,'plain mark byte length differs')
      cursor=0; marks=expected.map do
        coords=slots.times.map { a=bytes.byteslice(cursor,16).unpack('Q<Q<'); cursor+=16; a }
        rows=bytes.byteslice(cursor,8).unpack1('Q<'); cursor+=8; [coords,rows]
      end
      need!(cursor==bytes.bytesize && marks.map(&:last)==expected,'raw mark row domains differ')
      slots.times do |slot|
        prev=nil; marks.each do |coords,_|
          cur=coords[slot]; need!(prev.nil? || cur[0]>prev[0] || (cur[0]==prev[0] && cur[1]>=prev[1]),'mark coordinates regress'); prev=cur
        end
      end
      marks.map(&:last)
    end
    def attached_contract!(generated,attached,sidecar)
      a=inventory!(generated,'generated'); b=inventory!(attached,'attached'); af=a['files'].to_h { |f| [f['path'],f] }; bf=b['files'].to_h { |f| [f['path'],f] }
      need!(af.keys.all? { |p| bf[p]==af[p] },'ATTACH changed or omitted generated file')
      extra=bf.keys-af.keys
      need!(extra==[SIDECAR_PATH] && bf[SIDECAR_PATH]==SIDECAR_ENTRY && sidecar==SIDECAR_BYTES && b['total_bytes']==a['total_bytes']+SIDECAR_BYTES.bytesize,'ATTACH inventory is not byte-preserving with only the exact sidecar')
      true
    end
    def sidecar_inventory!
      compare_directory!('raw-records',@expected_raw.uniq.sort)
      compare_directory!('source-inventories',@expected_snapshots.uniq.sort)
    end
    def part_prefix(origin,id)
      case_id = case origin
                when :stock
                  need!(expected_ids.include?(id), 'unknown stock part case id')
                  id
                when :generated
                  base=id.delete_suffix('_generated')
                  need!(id=="#{base}_generated" && expected_ids.include?(base), 'unknown generated part case id')
                  base
                when :attached
                  base=id.delete_suffix('_attached')
                  need!(id=="#{base}_attached" && expected_ids.include?(base), 'unknown attached part case id')
                  base
                else
                  raise Error, "unknown part origin #{origin.inspect}"
                end
      root = origin == :generated ? 'parts' : 'stores'
      store = origin == :attached ? "target_#{case_id}" : case_id
      File.join(@root,root,store)+File::SEPARATOR
    end
    def inventory_relative_paths(name,expected)
      prefix="#{name}/"
      expected.map do |path|
        need!(path.is_a?(String) && path.start_with?(prefix), "#{name} reference has a mismatched directory prefix")
        relative=path.delete_prefix(prefix)
        safe_relative!(relative,"#{name} reference")
      end
    end
    def compare_directory!(name,expected)
      base=File.join(@root,name); directory!(base,name); actual=[]
      Find.find(base) do |p|
        next if p==base; st=File.lstat(p); need!(!st.symlink?,"symlink in #{name}")
        next if st.directory?; need!(st.file?,"non-regular item in #{name}"); actual << p.delete_prefix(base+File::SEPARATOR)
      end
      need!(actual.sort==inventory_relative_paths(name,expected),"#{name} contains missing or unexpected raw evidence files")
    end
    def seed_mark_bytes(slots,rows)
      ''.b.tap { |b| rows.each_with_index { |n,m| slots.times { |s| b << [m,s].pack('Q<Q<') }; b << [n].pack('Q<') } }
    end
    def seed_inventories
      files=[{'path'=>'data.mrk3','size'=>8,'sha256'=>sha('mark')},{'path'=>'serialization.json','size'=>2,'sha256'=>sha('{}')}]
      generated={'files'=>files,'total_bytes'=>10}; attached_files=(files+[SIDECAR_ENTRY]).sort_by { |f| f['path'] }
      [generated,{'files'=>attached_files,'total_bytes'=>38}]
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |p|
    p.banner = 'Usage: ruby scripts/verify_compact_static_bulk_w281_capture.rb --evidence-root ROOT | --self-test'
    p.on('--evidence-root ROOT', 'Read-only W281 full-matrix capture root') { |v| options[:evidence_root] = v }
    p.on('--self-test', 'Run seeded Ruby-only positive and negative controls') { options[:self_test] = true }
  end
  begin
    parser.parse!
    if options[:self_test]
      raise OptionParser::ParseError, '--self-test cannot be combined with --evidence-root or positional arguments' if options[:evidence_root] || !ARGV.empty?
      exit(VerifyCompactStaticBulkW281::Auditor.self_test! ? 0 : 1)
    end
    unless options[:evidence_root] && ARGV.empty?
      warn parser.to_s
      exit 2
    end
    exit(VerifyCompactStaticBulkW281::Auditor.new(options[:evidence_root]).run ? 0 : 1)
  rescue OptionParser::ParseError => e
    warn "#{e.message}\n#{parser}"
    exit 2
  end
end
