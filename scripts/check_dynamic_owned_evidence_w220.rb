#!/usr/bin/env ruby
# Read-only, independent audit of the source-owned Dynamic .values observations
# emitted by the W203/W210/W212/W213 stock witnesses. This file deliberately
# does not require or execute any probe runner.

require 'digest'
require 'find'
require 'json'
require 'optparse'

module CheckDynamicOwnedEvidenceW220
  BINARY_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  VERSION = '26.10.1.1201'.freeze
  BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  PROFILES = %w[single_stream with_size_stream].freeze
  EMPTY_SHA256 = Digest::SHA256.hexdigest(''.b).freeze
  OWNED_KEYS = %w[mark_row_counts nominal_type_names_by_mark row_count schema_declaration values_by_mark].freeze

  W203_CASES = %w[root_dynamic array_dynamic tuple_dynamic nested_dynamic dynamic_tuple_dynamic].freeze
  W210_CASES = %w[root_dynamic array_dynamic].freeze
  W212_CASES = %w[root_array_json root_named_tuple_json root_deep_nullable_json root_map_json root_array_variant_json array_dynamic_array_json].freeze
  W213_CASES = %w[root_json root_array_json root_tuple_json array_dynamic_array_json].freeze

  W203_TYPES = {
    'root_dynamic' => 'Dynamic(max_types=1)',
    'array_dynamic' => 'Array(Dynamic(max_types=1))',
    'tuple_dynamic' => 'Tuple(d Dynamic(max_types=1), text String)',
    'nested_dynamic' => 'Nested(label LowCardinality(Nullable(String)), choice Variant(String, UInt64), d Dynamic(max_types=1), text String)',
    'dynamic_tuple_dynamic' => 'Dynamic(max_types=1)',
  }.freeze
  W210_TYPES = {
    'root_dynamic' => 'Dynamic(max_types=3)',
    'array_dynamic' => 'Array(Dynamic(max_types=3))',
  }.freeze
  W212_TYPES = {
    'root_array_json' => 'Dynamic(max_types=4)',
    'root_named_tuple_json' => 'Dynamic(max_types=4)',
    'root_deep_nullable_json' => 'Dynamic(max_types=4)',
    'root_map_json' => 'Dynamic(max_types=4)',
    'root_array_variant_json' => 'Dynamic(max_types=4)',
    'array_dynamic_array_json' => 'Array(Dynamic(max_types=4))',
  }.freeze
  W213_TYPES = {
    'root_json' => 'Dynamic(max_types=0)',
    'root_array_json' => 'Dynamic(max_types=0)',
    'root_tuple_json' => 'Dynamic(max_types=0)',
    'array_dynamic_array_json' => 'Array(Dynamic(max_types=0))',
  }.freeze

  # These are the Ruby-literal stock rows, authored here rather than imported
  # from a witness or generated from helper output. W203's signature renderer
  # below preserves the nominal wrapper and each actual value/type.
  W203_FIXTURES = {
    'root_dynamic' => [nil, nil, 7, 'root-spill-a', 0, 'root-spill-b', 99, 'root-spill-c'],
    'array_dynamic' => [[], [], [7, 'array-spill-a'], [nil], [0, 42, 'array-spill-b'], [], ['array-spill-c'], [99, nil]],
    'tuple_dynamic' => [
      [nil, 'first-null'], [nil, 'second-null'], [7, 'ordinary'], ['tuple-spill-a', 'shared'],
      [0, 'zero'], [nil, 'null-again'], ['tuple-spill-b', 'novel'], [99, 'last'],
    ],
    'nested_dynamic' => [
      [], [],
      [[nil, [:string, 'after-empty'], 7, 'a'], ['x', [:uint64, 701], 'nested-spill-a', 'num-first'], ['x', [:null, nil], 9, 'third']],
      [['x', [:string, 'repeat'], 11, 'repeat']],
      [],
      [['', [:uint64, 0], 0, 'default-label'], [nil, [:uint64, 42], 'nested-spill-b', 'null-label']],
      [['novel', [:string, 'last'], 'nested-spill-c', 'final']],
      [['x', [:uint64, 999], 99, 'final-num'], ['x', [:null, nil], nil, 'tail'], ['novel', [:string, 'repeat'], 10, 'repeat']],
    ],
    'dynamic_tuple_dynamic' => [nil, nil, [:tuple, 7], [:tuple, 'inner-spill-a'], 'outer-spill', [:tuple, nil], [:tuple, 99], [:tuple, 'inner-spill-b']],
  }.freeze

  W210_ROWS = {
    'root_dynamic' => [
      ['u8:17', 'u8:18'], ['u8:19', 'u8:20'],
      ['json:41:null:counter=401', 'json:42:null:counter=402'],
    ],
    'array_dynamic' => [
      ['[]', '[]'], ['[u8:17,u8:18]', '[u8:19]'],
      ['[json:41:null:counter=401]', '[json:42:null:counter=402]'],
    ],
  }.freeze

  W212_ROWS = {
    'root_array_json' => [['D[U8:11]', 'D[U8:12]'], ['D[[]]', 'D[[J(31,311),J(32,321)]]'], ['D[[J(33,331),J(34,341),J(35,351)]]', 'D[[]]']],
    'root_named_tuple_json' => [['D[U8:13]', 'D[U8:14]'], ['D[(left=J(41,411),right=J(42,421))]', 'D[(left=J(43,431),right=J(44,441))]'], ['D[(left=J(0,1),right=J(45,451))]', 'D[(left=J(46,461),right=J(47,471))]']],
    'root_deep_nullable_json' => [['D[U8:15]', 'D[U8:16]'], ['D[[]]', 'D[[(nil,null),(present,J(61,611))]]'], ['D[[(default,J(62,621)),(null-default,null)]]', 'D[[]]']],
    'root_map_json' => [['D[U8:17]', 'D[U8:18]'], ['D[{}]', 'D[{alpha=J(71,711),beta=J(72,721)}]'], ['D[{omega=J(73,731)}]', 'D[{}]']],
    'root_array_variant_json' => [['D[U8:19]', 'D[U8:20]'], ['D[[]]', 'D[[V0=J(81,811),V1=U8:82,Vnull]]'], ['D[[V0=J(83,831),V0=J(84,841)]]', 'D[[]]']],
    'array_dynamic_array_json' => [['[]', '[]'], ['[D[[]],D[U8:91],D[[J(101,1011)]]]', '[]'], ['[D[[J(111,1111),J(112,1121)]],D[U8:92],D[[J(113,1131)]],D[[J(114,1141)]],D[U8:93]]', '[]']],
  }.freeze

  W213_ROWS = {
    'root_json' => [['null', 'null'], ['D[J(31,311)]', 'D[J(32,321)]'], ['D[J(33,331)]', 'D[J(34,341)]'], ['D[J(35,351)]', 'D[J(36,361)]']],
    'root_array_json' => [['null', 'null'], ['D[[]]', 'D[[J(41,411)]]'], ['D[[J(42,421),J(43,431)]]', 'D[[J(44,441)]]'], ['D[[J(45,451)]]', 'D[[J(46,461),J(47,471)]]']],
    'root_tuple_json' => [['null', 'null'], ['D[(J(51,511),J(52,521))]', 'D[(J(53,531),J(54,541))]'], ['D[(J(55,551),J(56,561))]', 'D[(J(57,571),J(58,581))]'], ['D[(J(59,591),J(60,601))]', 'D[(J(61,611),J(62,621))]']],
    'array_dynamic_array_json' => [
      ['[D[[]]]', '[D[[]]]'],
      ['[null,D[[J(81,811)]]]', '[D[[J(82,821),J(83,831)]]]'],
      ['[D[[]],D[[J(84,841)]]]', '[D[[J(85,851),J(86,861)]]]'],
      ['[D[[J(86,861)]],D[[]],D[[J(87,871)]]]', '[D[[J(88,881)]],D[[J(89,891)]]]'],
    ],
  }.freeze

  SPECS = {
    'w203' => {
      cases: W203_CASES, format: 'dynamic_bulk_part_w203_helper_v1',
      status: 'paired_recursive_dynamic_bulk_part_observed', row_count: 8, mark_rows: [2, 2, 2, 2],
      output_rows: :w203, low_level_rows: false,
    },
    'w210' => {
      cases: W210_CASES, format: 'dynamic_json_physical_w210_helper_v1',
      status: 'paired_dynamic_json_physical_composition_observed', row_count: 6, mark_rows: [2, 2, 2],
      output_rows: W210_ROWS, low_level_rows: true,
    },
    'w212' => {
      cases: W212_CASES, format: 'dynamic_json_recursive_w212_helper_v1',
      status: 'paired_recursive_dynamic_json_native_witness_observed', row_count: 6, mark_rows: [2, 2, 2],
      output_rows: W212_ROWS, low_level_rows: true,
    },
    'w213' => {
      cases: W213_CASES, format: 'dynamic_shared_json_w213_helper_v1',
      status: 'paired_shared_variant_inline_json_native_witness_observed', row_count: 8, mark_rows: [2, 2, 2, 2],
      output_rows: W213_ROWS, low_level_rows: true,
    },
  }.freeze

  class AuditFailure < StandardError; end

  def self.require!(condition, message)
    raise AuditFailure, message unless condition
  end

  def self.case_profiles(kind)
    SPECS.fetch(kind).fetch(:cases).flat_map { |case_id| PROFILES.map { |profile| [case_id, profile] } }
  end

  def self.schema_for(kind, case_id)
    {'w203' => W203_TYPES, 'w210' => W210_TYPES, 'w212' => W212_TYPES, 'w213' => W213_TYPES}.fetch(kind).fetch(case_id)
  end

  def self.w203_dynamic_signature(value)
    type = 'Dynamic(max_types=1)'
    return "#{type}=NULL" if value.nil?
    child = if value.is_a?(Integer)
              "UInt64=#{value}"
            elsif value.is_a?(String)
              "String=#{JSON.generate(value)}"
            else
              raise AuditFailure, "unexpected W203 fixture value #{value.inspect}"
            end
    "#{type}=#{child}"
  end

  def self.w203_nested_record_signature(record)
    label, choice, payload, text = record
    label_sig = if label.nil?
                  'LowCardinality(Nullable(String))=Nullable(String)=NULL'
                else
                  "LowCardinality(Nullable(String))=Nullable(String)=String=#{JSON.generate(label)}"
                end
    choice_sig = case choice.fetch(0)
                 when :string then "Variant(String, UInt64)[0:String]=String=#{JSON.generate(choice.fetch(1))}"
                 when :uint64 then "Variant(String, UInt64)[1:UInt64]=UInt64=#{choice.fetch(1)}"
                 when :null then 'Variant(String, UInt64)=NULL'
                 else raise AuditFailure, "unexpected W203 Variant fixture #{choice.inspect}"
                 end
    tuple = 'Tuple(label LowCardinality(Nullable(String)), choice Variant(String, UInt64), d Dynamic(max_types=1), text String)'
    fields = [label_sig, choice_sig, w203_dynamic_signature(payload), "String=#{JSON.generate(text)}"]
    "#{tuple}=[#{fields.join(',')}]"
  end

  def self.w203_signature(case_id, value)
    dynamic = 'Dynamic(max_types=1)'
    case case_id
    when 'root_dynamic'
      w203_dynamic_signature(value)
    when 'array_dynamic'
      "Array(#{dynamic})=[#{value.map { |item| w203_dynamic_signature(item) }.join(',')}]"
    when 'tuple_dynamic'
      "Tuple(d #{dynamic}, text String)=[#{w203_dynamic_signature(value.fetch(0))},String=#{JSON.generate(value.fetch(1))}]"
    when 'nested_dynamic'
      "Nested(label LowCardinality(Nullable(String)), choice Variant(String, UInt64), d Dynamic(max_types=1), text String)=[#{value.map { |record| w203_nested_record_signature(record) }.join(',')}]"
    when 'dynamic_tuple_dynamic'
      if value.nil?
        "#{dynamic}=NULL"
      elsif value.is_a?(Array) && value.first == :tuple
        "#{dynamic}=Tuple(Dynamic(max_types=1))=[#{w203_dynamic_signature(value.fetch(1))}]"
      else
        w203_dynamic_signature(value)
      end
    else
      raise AuditFailure, "unrostered W203 case #{case_id.inspect}"
    end
  end

  def self.expected_rows(kind, case_id)
    if kind == 'w203'
      W203_FIXTURES.fetch(case_id).map { |value| w203_signature(case_id, value) }.each_slice(2).map(&:to_a)
    else
      SPECS.fetch(kind).fetch(:output_rows).fetch(case_id)
    end
  end

  def self.validate_helper_observations!(kind, helper)
    spec = SPECS.fetch(kind)
    require!(helper.is_a?(Hash), "#{kind}: helper output is not an object")
    require!(helper['format'] == spec.fetch(:format), "#{kind}: helper format differs")
    require!(helper['case_ids'] == spec.fetch(:cases), "#{kind}: carrier census differs")
    require!(helper['profile_ids'] == PROFILES, "#{kind}: profile census differs")
    items = helper['cases']
    require!(items.is_a?(Array), "#{kind}: helper cases are absent")
    pairs = items.map do |item|
      require!(item.is_a?(Hash), "#{kind}: malformed helper case")
      [item['case_id'], item['profile_id']]
    end
    require!(pairs == case_profiles(kind), "#{kind}: case/profile census or order differs")

    items.each do |item|
      case_id = item.fetch('case_id')
      profile = item.fetch('profile_id')
      side = item['source']
      require!(side.is_a?(Hash), "#{kind} #{case_id}/#{profile}: stock-source helper side is absent")
      # W203/W213 record pair identity on the enclosing case, whose exact
      # census is checked above. W210/W212 repeat it on each side.
      if %w[w210 w212].include?(kind)
        require!(side['case_id'] == case_id && side['profile_id'] == profile,
                 "#{kind} #{case_id}/#{profile}: source case identity differs")
      end
      declaration = schema_for(kind, case_id)
      mark_rows = spec.fetch(:mark_rows)
      expected = expected_rows(kind, case_id)
      require!(side['schema_declaration'] == declaration,
               "#{kind} #{case_id}/#{profile}: source nominal declaration differs")
      require!(side['row_count'] == spec.fetch(:row_count) && side['mark_count'] == mark_rows.size &&
               side['mark_row_counts'] == mark_rows,
               "#{kind} #{case_id}/#{profile}: source row/mark grid differs")

      owned = side['owned_values']
      require!(owned.is_a?(Hash), "#{kind} #{case_id}/#{profile}: owned_values is missing")
      require!(owned.keys.sort == OWNED_KEYS,
               "#{kind} #{case_id}/#{profile}: owned_values field set differs")
      require!(owned['schema_declaration'] == declaration && owned['row_count'] == spec.fetch(:row_count) &&
               owned['mark_row_counts'] == mark_rows,
               "#{kind} #{case_id}/#{profile}: owned_values nominal schema or row/mark grid differs")
      expected_types = Array.new(mark_rows.size) { Array.new(mark_rows.fetch(0), declaration) }
      require!(owned['nominal_type_names_by_mark'] == expected_types,
               "#{kind} #{case_id}/#{profile}: owned_values actual nominal descriptors differ")
      require!(owned['values_by_mark'] == expected,
               "#{kind} #{case_id}/#{profile}: owned_values differ from independent stock fixture literals")
      if spec.fetch(:low_level_rows)
        require!(side['rows_by_mark'] == expected,
                 "#{kind} #{case_id}/#{profile}: low-level source read differs from independent stock fixture literals")
      end
    end
    true
  rescue KeyError => error
    raise AuditFailure, "#{kind}: malformed helper observation: #{error.message}"
  end

  def self.summary_expected_check_coords(kind, phase)
    selected_origins = case [kind, phase]
                       when ['w203', 'source'] then %w[source]
                       when ['w203', 'attached'], ['w210', 'attached'], ['w212', 'attached'] then %w[source library]
                       when ['w210', 'source'], ['w212', 'source'], ['w213', 'source'] then %w[source]
                       when ['w213', 'attached'] then %w[library]
                       else raise AuditFailure, "unsupported CHECK phase #{kind}/#{phase}"
                       end
    case_profiles(kind).flat_map do |case_id, profile|
      selected_origins.map do |origin|
        table = "#{origin}_#{case_id}_#{profile}"
        kind == 'w203' ? [table, case_id, profile] : [table, profile]
      end
    end.sort
  end

  def self.validate_summary_checks!(kind, phase, native)
    checks = native.is_a?(Hash) && native['checks']
    require!(checks.is_a?(Hash), "#{kind}: retained #{phase} CHECK results are absent")
    expected = summary_expected_check_coords(kind, phase)
    require!(checks.size == expected.size, "#{kind}: retained #{phase} CHECK roster size differs")
    seen = []
    checks.each do |key, rows|
      text = key.to_s
      coord = expected.find { |parts| parts.all? { |part| text.include?(part) } }
      require!(coord, "#{kind}: retained #{phase} CHECK has an unexpected identity")
      require!(!seen.include?(coord), "#{kind}: retained #{phase} CHECK identity is duplicated")
      require!(rows == ["all_1_1_0\t1\t"], "#{kind}: retained #{phase} CHECK result differs")
      seen << coord
    end
    require!(seen.sort == expected, "#{kind}: retained #{phase} CHECK identities differ")
  end

  def self.raw_check_blocks(stdout, kind)
    prefix = kind == 'w203' ? '__W203_CHECK_' : '__W202_CHECK_'
    begin_tag = "#{prefix}BEGIN__"
    end_tag = "#{prefix}END__"
    active = nil
    blocks = {}
    stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).each do |line|
      if line.start_with?("#{begin_tag}\t")
        fields = line.split("\t", -1)
        expected_width = kind == 'w203' ? 4 : 3
        require!(fields.size == expected_width && active.nil?, "#{kind}: malformed or nested raw CHECK boundary")
        active = fields.drop(1)
        require!(!blocks.key?(active), "#{kind}: duplicate raw CHECK block")
        blocks[active] = []
      elsif line.start_with?("#{end_tag}\t")
        fields = line.split("\t", -1)
        require!(fields.size == (kind == 'w203' ? 4 : 3) && active == fields.drop(1),
                 "#{kind}: malformed raw CHECK end boundary")
        active = nil
      elsif active
        blocks.fetch(active) << line
      end
    end
    require!(active.nil?, "#{kind}: unterminated raw CHECK block")
    blocks
  end

  def self.validate_raw_checks!(kind, phase, stdout)
    expected = summary_expected_check_coords(kind, phase)
    actual = raw_check_blocks(stdout.dup, kind)
    require!(actual.keys.sort == expected, "#{kind}: raw #{phase} CHECK identity census differs")
    actual.each_value do |rows|
      require!(rows == ["all_1_1_0\t1\t"], "#{kind}: raw #{phase} library/source CHECK result differs")
    end
  end

  def self.validate_runtime!(kind, summary)
    runtime = summary['runtime']
    require!(runtime.is_a?(Hash), "#{kind}: runtime identity is absent")
    case kind
    when 'w203', 'w210', 'w213'
      require!(runtime['expected_sha256'] == BINARY_SHA256 && runtime['sha256_before'] == BINARY_SHA256 &&
               runtime['sha256_after'] == BINARY_SHA256 && runtime['expected_version'] == VERSION,
               "#{kind}: stock binary hash/version pin differs")
      expected_build_key = kind == 'w213' ? 'expected_build' : 'expected_version_git_hash'
      require!(runtime[expected_build_key] == BUILD, "#{kind}: stock build pin differs")
    when 'w212'
      require!(runtime['sha256'] == BINARY_SHA256 && summary['binary_sha256_before'] == BINARY_SHA256 &&
               summary['binary_sha256_after'] == BINARY_SHA256 && runtime['version'] == VERSION &&
               runtime['build'] == BUILD && runtime['source_revision'] == SOURCE_REVISION,
               'w212: stock binary/version/build/source pin differs')
    end
    if kind == 'w213'
      require!(summary['source_reference'] == SOURCE_REVISION, 'w213: source revision pin differs')
    elsif kind == 'w212'
      # The source revision is pinned independently from the runtime binary.
      require!(runtime['source_revision'] == SOURCE_REVISION, 'w212: source revision pin differs')
    end
  end

  def self.safe_regular_file!(path, label)
    stat = File.lstat(path)
    require!(stat.file? && !stat.symlink?, "#{label}: not a regular non-symlink file")
    path
  rescue Errno::ENOENT
    raise AuditFailure, "#{label}: file is absent"
  end

  def self.read_json_file!(path, label)
    safe_regular_file!(path, label)
    JSON.parse(File.binread(path))
  rescue JSON::ParserError => error
    raise AuditFailure, "#{label}: invalid JSON (#{error.message})"
  end

  def self.audit_invocation_record!(root, record, kind, expected_stdout, process_kind)
    require!(record.is_a?(Hash), "#{kind}: #{expected_stdout} invocation record is absent")
    require!(record['stdout_file'] == expected_stdout && record['stderr_file'] == expected_stdout.sub(/\.stdout\z/, '.stderr'),
             "#{kind}: invocation filename/role differs for #{expected_stdout}")
    require!(record['process_kind'] == process_kind && record['process_classification'] == 'success' &&
             record['exit'] == 0 && record['signal'].nil? && record['timed_out'] == false,
             "#{kind}: invocation did not record a clean #{process_kind} exit")
    require!(record['stderr_bytes'] == 0 && record['stderr_sha256'] == EMPTY_SHA256,
             "#{kind}: invocation stderr is not empty")
    require!(record['stdout_bytes'].is_a?(Integer) && record['stdout_sha256'].to_s.match?(/\A[0-9a-f]{64}\z/),
             "#{kind}: invocation stdout census is malformed")
    invocations = File.join(root, 'invocations')
    stdout_path = File.join(invocations, expected_stdout)
    stderr_path = File.join(invocations, record.fetch('stderr_file'))
    safe_regular_file!(stdout_path, "#{kind} #{expected_stdout}")
    safe_regular_file!(stderr_path, "#{kind} #{record.fetch('stderr_file')}")
    stdout = File.binread(stdout_path)
    stderr = File.binread(stderr_path)
    require!(stdout.bytesize == record['stdout_bytes'] && Digest::SHA256.hexdigest(stdout) == record['stdout_sha256'],
             "#{kind}: raw stdout differs from its recorded byte/hash census")
    require!(stderr.empty? && stderr.bytesize == record['stderr_bytes'] && Digest::SHA256.hexdigest(stderr) == record['stderr_sha256'],
             "#{kind}: raw stderr differs from its recorded byte/hash census")
    if process_kind == 'clickhouse local'
      require!(record['expected_binary_sha256'] == BINARY_SHA256 && record['binary_sha_before'] == BINARY_SHA256 &&
               record['binary_sha_after'] == BINARY_SHA256,
               "#{kind}: per-invocation ClickHouse binary hashes differ")
    else
      helper_sha = record['expected_binary_sha256']
      require!(helper_sha.to_s.match?(/\A[0-9a-f]{64}\z/) && record['binary_sha_after'] == helper_sha,
               "#{kind}: prebuilt helper hash record is malformed or changed")
    end
    [record, stdout]
  rescue KeyError => error
    raise AuditFailure, "#{kind}: malformed invocation record: #{error.message}"
  end

  def self.invocation_by_stdout!(summary, name, kind)
    records = summary['invocations']
    require!(records.is_a?(Array), "#{kind}: invocation inventory is absent")
    matches = records.select { |record| record.is_a?(Hash) && record['stdout_file'] == name }
    require!(matches.size == 1, "#{kind}: expected exactly one #{name} invocation")
    matches.first
  end

  # The caller supplies an independently measured artifact pin from the
  # observed build, rather than trusting a helper's self-reported identity.
  def self.validate_helper_pin!(record, expected_sha256, kind)
    require!(expected_sha256.to_s.match?(/\A[0-9a-f]{64}\z/) &&
             record['expected_binary_sha256'] == expected_sha256 && record['binary_sha_after'] == expected_sha256,
             "#{kind}: invoked helper differs from the externally supplied build-artifact pin")
  end

  def self.validate_native_pin!(stdout, kind)
    tag = kind == 'w203' ? '__W203_PIN__' : '__W202_PIN__'
    matches = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).select { |line| line.start_with?("#{tag}\t") }
    expected = "#{tag}\t#{VERSION}\t#{BUILD}"
    require!(matches == [expected], "#{kind}: raw stock stdout version/build pin differs")
  end

  def self.snapshot_tree!(path)
    expanded = File.expand_path(path)
    root_stat = File.lstat(expanded)
    require!(root_stat.directory? && !root_stat.symlink? && File.realpath(expanded) == expanded,
             "source part is not a canonical non-symlink directory: #{expanded}")
    snapshot = {}
    Find.find(expanded).sort.each do |entry|
      next if entry == expanded
      relative = entry.delete_prefix(expanded + File::SEPARATOR)
      stat = File.lstat(entry)
      require!(!stat.symlink?, "source part contains a symlink: #{entry}")
      if stat.directory?
        snapshot[relative] = {'type' => 'directory'}
      elsif stat.file?
        snapshot[relative] = {
          'type' => 'file', 'size' => stat.size, 'sha256' => Digest::SHA256.file(entry).hexdigest,
        }
      else
        raise AuditFailure, "source part contains a non-file entry: #{entry}"
      end
    end
    snapshot
  rescue Errno::ENOENT
    raise AuditFailure, "source part is absent: #{path}"
  end

  def self.parse_manifest!(path)
    manifest_path = File.join(path, 'columns_substreams.txt')
    safe_regular_file!(manifest_path, 'columns_substreams.txt')
    bytes = File.binread(manifest_path)
    require!(bytes.bytesize <= 1_048_576, 'columns_substreams.txt exceeds the runner bound')
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    require!(text.valid_encoding?, 'columns_substreams.txt is not UTF-8')
    lines = text.lines.map(&:chomp)
    require!(lines.shift == 'columns substreams version: 1', 'columns_substreams version differs')
    count_match = /\A([1-9][0-9]*) columns:\z/.match(lines.shift.to_s)
    require!(count_match, 'columns_substreams column count is malformed')
    columns = {}
    until lines.empty?
      header = lines.shift
      match = /\A([1-9][0-9]*) substreams for column `([^`]+)`:\z/.match(header.to_s)
      require!(match, 'columns_substreams block header is malformed')
      count = Integer(match[1], 10)
      name = match[2]
      require!(!columns.key?(name) && lines.size >= count, 'columns_substreams block is duplicate or truncated')
      values = lines.shift(count).map do |line|
        substream = /\A\t([^\t\r\n]+)\z/.match(line)
        require!(substream, 'columns_substreams entry is malformed')
        substream[1]
      end
      require!(values.uniq == values, 'columns_substreams substream name is duplicated')
      columns[name] = values
    end
    require!(columns.size == Integer(count_match[1], 10) && columns.keys.sort == %w[payload pk] && columns['pk'] == ['pk'],
             'columns_substreams column/primary-key census differs')
    [bytes, columns]
  rescue ArgumentError => error
    raise AuditFailure, "columns_substreams count is invalid: #{error.message}"
  end

  def self.parse_mark_rows!(path, filename)
    bytes = File.binread(File.join(path, filename))
    require!((bytes.bytesize % 24).zero?, "#{filename}: partial .mrk2 record")
    bytes.bytes.each_slice(24).map { |record| record[16, 8].pack('C*').unpack1('Q<') }
  end

  def self.roster_entry(summary, kind, case_id, profile, origin)
    map = kind == 'w203' ? summary['independent_part_rosters'] : summary['part_rosters']
    require!(map.is_a?(Hash), "#{kind}: raw part roster evidence is absent")
    expected = [case_id, profile, origin]
    matches = map.each_with_object([]) do |(key, value), selected|
      components = if key.include?('/')
                     key.split('/')
                   elsif key.start_with?('[')
                     begin
                       JSON.parse(key)
                     rescue JSON::ParserError
                       nil
                     end
                   end
      selected << value if components == expected
    end
    require!(matches.size == 1, "#{kind} #{case_id}/#{profile}/#{origin}: raw part-roster entry is missing or duplicated")
    matches.first
  end

  def self.validate_roster_and_files!(kind, summary, case_id, profile, source_side, path)
    bytes, columns = parse_manifest!(path)
    payload_names = columns.fetch('payload').sort
    require!(source_side['physical_stream_names'].is_a?(Array) && source_side['physical_stream_names'] == payload_names,
             "#{kind} #{case_id}/#{profile}: raw manifest and helper physical-stream census differ")
    roster = roster_entry(summary, kind, case_id, profile, 'source')
    if roster['manifest']
      require!(roster['manifest'].b == bytes, "#{kind} #{case_id}/#{profile}: raw manifest differs from exposed literal manifest")
    end
    if roster['payload_substreams']
      require!(roster['payload_substreams'].sort == payload_names, "#{kind} #{case_id}/#{profile}: runner payload roster differs from raw manifest")
    end

    entries = Dir.children(path).sort
    streams = entries.select { |name| name.end_with?('.bin') || name.end_with?('.mrk2') }
    require!(streams.all? { |name| /\A[0-9a-f]{32}\.(?:bin|mrk2)\z/.match?(name) },
             "#{kind} #{case_id}/#{profile}: noncanonical raw stream filename")
    binary_stems = streams.select { |name| name.end_with?('.bin') }.map { |name| name.delete_suffix('.bin') }.sort
    mark_stems = streams.select { |name| name.end_with?('.mrk2') }.map { |name| name.delete_suffix('.mrk2') }.sort
    require!(binary_stems == mark_stems && binary_stems.uniq == binary_stems,
             "#{kind} #{case_id}/#{profile}: raw .bin/.mrk2 stem census differs")

    if roster['hashed_stream_stems']
      require!(roster['hashed_stream_stems'].sort == binary_stems,
               "#{kind} #{case_id}/#{profile}: exposed hashed-stream census differs")
      require!(binary_stems.size == payload_names.size + 1,
               "#{kind} #{case_id}/#{profile}: raw stream count is not payload plus pk")
    end
    if roster['checksum_file_names']
      checksum_names = roster['checksum_file_names']
      require!(checksum_names.is_a?(Array) && checksum_names.all? { |name| name.is_a?(String) && File.basename(name) == name } &&
               checksum_names.uniq == checksum_names && checksum_names.all? { |name| entries.include?(name) },
               "#{kind} #{case_id}/#{profile}: exposed checksum filename inventory is invalid")
      checksum_streams = checksum_names.select { |name| name.end_with?('.bin') || name.end_with?('.mrk2') }
      require!(checksum_streams.sort == streams.sort && checksum_names.sort == source_side['checksum_file_names'].sort,
               "#{kind} #{case_id}/#{profile}: exposed checksum stream census or helper inventory differs")
    end

    actual_marks = streams.grep(/\.mrk2\z/).sort.to_h do |filename|
      [filename, parse_mark_rows!(path, filename)]
    end
    expected_mark_rows = case kind
                         when 'w210', 'w212' then [2, 2, 2, 0]
                         when 'w213' then [2, 2, 2, 2, 0]
                         else nil
                         end
    if expected_mark_rows
      require!(actual_marks.values.all? { |rows| rows == expected_mark_rows },
               "#{kind} #{case_id}/#{profile}: raw mark third-word rows differ")
    end
    compare_exposed_mark_rows!(kind, roster, actual_marks, case_id, profile)

    snapshot = snapshot_tree!(path)
    raw_snapshot_scope = if kind == 'w210'
                           'recomputed_only_runner_did_not_expose_snapshot'
                         else
                           source_snapshots = summary['source_part_snapshots']
                           require!(source_snapshots.is_a?(Hash), "#{kind}: source-part hash snapshot is absent")
                           table = "source_#{case_id}_#{profile}"
                           recorded = source_snapshots[table]
                           require!(recorded.is_a?(Hash) && recorded == snapshot,
                                    "#{kind} #{case_id}/#{profile}: raw source file census/hash differs from runner snapshot")
                           'compared_with_runner_snapshot'
                         end
    {
      'table' => "source_#{case_id}_#{profile}",
      'file_count' => snapshot.size,
      'manifest_sha256' => Digest::SHA256.hexdigest(bytes),
      'raw_file_hashes_compared' => raw_snapshot_scope == 'compared_with_runner_snapshot',
      'raw_hash_scope' => raw_snapshot_scope,
    }
  rescue KeyError => error
    raise AuditFailure, "#{kind} #{case_id}/#{profile}: malformed raw roster: #{error.message}"
  end

  def self.compare_exposed_mark_rows!(kind, roster, actual_marks, case_id, profile)
    if roster['mark_row_words']
      expected = roster['mark_row_words']
      require!(expected.is_a?(Hash) && expected == actual_marks,
               "#{kind} #{case_id}/#{profile}: .mrk2 third words differ from exposed runner roster")
    elsif roster['mark_row_words_by_file']
      expected = roster['mark_row_words_by_file'].to_h do |entry|
        [entry.fetch('file'), entry.fetch('third_words')]
      end
      require!(expected == actual_marks, "#{kind} #{case_id}/#{profile}: .mrk2 third words differ from exposed runner roster")
    end
  rescue KeyError => error
    raise AuditFailure, "#{kind} #{case_id}/#{profile}: malformed mark roster: #{error.message}"
  end

  def self.audit_input_and_source_parts!(kind, summary, root)
    evidence = summary['helper_input']
    require!(evidence.is_a?(Hash), "#{kind}: helper-input evidence is absent")
    input_path = File.expand_path(evidence.fetch('path'))
    require!(input_path == File.join(root, 'generated', 'helper-input.json') &&
             File.realpath(input_path) == input_path,
             "#{kind}: helper-input path differs from the canonical generated input")
    input_bytes = File.binread(safe_regular_file!(input_path, "#{kind} helper-input"))
    require!(input_bytes.bytesize == evidence['bytes'] && Digest::SHA256.hexdigest(input_bytes) == evidence['sha256'],
             "#{kind}: helper-input bytes/hash differ")
    input = JSON.parse(input_bytes)
    require!(input['format'] == "#{kind == 'w203' ? 'dynamic_bulk_part_w203' : kind == 'w210' ? 'dynamic_json_physical_w210' : kind == 'w212' ? 'dynamic_json_recursive_w212' : 'dynamic_shared_json_w213'}_input_v1",
             "#{kind}: helper-input format differs")
    native_root = File.realpath(File.join(root, 'stores', 'native'))
    require!(input['capture_root'] == native_root, "#{kind}: helper-input native store root differs")
    entries = input['cases']
    pairs = entries.is_a?(Array) ? entries.map { |entry| [entry['case_id'], entry['profile_id']] } : nil
    require!(pairs == case_profiles(kind), "#{kind}: helper-input case/profile census differs")

    helper = summary['helper']
    helper_cases = helper.fetch('cases')
    source_parts = {}
    entries.zip(helper_cases).each do |input_case, helper_case|
      case_id = input_case.fetch('case_id')
      profile = input_case.fetch('profile_id')
      table = "source_#{case_id}_#{profile}"
      source_path = File.expand_path(input_case.fetch('source_part'))
      require!(source_path.start_with?(native_root + File::SEPARATOR) && File.realpath(source_path) == source_path,
               "#{kind} #{case_id}/#{profile}: source-part path escaped or is noncanonical")
      require!(input_case['capture_root'] == native_root, "#{kind} #{case_id}/#{profile}: source capture root differs")
      expected_library_path = File.join(root, 'generated', case_id, profile, 'all_1_1_0')
      require!(File.expand_path(input_case['library_part']) == expected_library_path,
               "#{kind} #{case_id}/#{profile}: library output path differs")
      source_parts[table] = source_path
      native_part = summary.fetch('source').fetch('parts').fetch(table)
      require!(native_part['path'] == source_path + File::SEPARATOR &&
               native_part['name'] == 'all_1_1_0' && native_part['type'] == 'Wide',
               "#{kind} #{case_id}/#{profile}: native source part identity/path differs")
      expected_rows = SPECS.fetch(kind).fetch(:row_count).to_s
      expected_marks = (SPECS.fetch(kind).fetch(:mark_rows).size + 1).to_s
      require!(native_part['rows'] == expected_rows && native_part['marks'] == expected_marks,
               "#{kind} #{case_id}/#{profile}: native source part row/mark census differs")
      validate_roster_and_files!(kind, summary, case_id, profile, helper_case.fetch('source'), source_path)
    end
    source_parts
  rescue KeyError => error
    raise AuditFailure, "#{kind}: malformed helper-input/source evidence: #{error.message}"
  rescue JSON::ParserError => error
    raise AuditFailure, "#{kind}: invalid helper-input JSON (#{error.message})"
  end

  def self.audit(root_path, kind, expected_helper_sha256)
    root = File.realpath(File.expand_path(root_path))
    summary = read_json_file!(File.join(root, 'summary.json'), "#{kind} summary")
    require!(summary['evidence_root'] && File.expand_path(summary['evidence_root']) == root,
             "#{kind}: summary evidence-root identity differs")
    require!(summary['status'] == SPECS.fetch(kind).fetch(:status) && summary['fatal_error'].nil?,
             "#{kind}: runner did not record the exact successful status")
    require!(summary['cases'] == SPECS.fetch(kind).fetch(:cases) && summary['profiles'] == PROFILES,
             "#{kind}: summary carrier/profile census differs")
    validate_runtime!(kind, summary)

    invocations = summary['invocations']
    require!(invocations.is_a?(Array) && invocations.size == 3,
             "#{kind}: invocation count differs from native/helper/native sequence")
    first_record = invocation_by_stdout!(summary, 'native_sources.stdout', kind)
    helper_record = invocation_by_stdout!(summary, 'crystal_helper.stdout', kind)
    attached_record = invocation_by_stdout!(summary, 'attach_and_check.stdout', kind)
    _first_record, first_stdout = audit_invocation_record!(root, first_record, kind, 'native_sources.stdout', 'clickhouse local')
    _helper_record, helper_stdout = audit_invocation_record!(root, helper_record, kind, 'crystal_helper.stdout', 'prebuilt Crystal helper')
    validate_helper_pin!(helper_record, expected_helper_sha256, kind)
    _attached_record, attached_stdout = audit_invocation_record!(root, attached_record, kind, 'attach_and_check.stdout', 'clickhouse local')
    validate_native_pin!(first_stdout, kind)
    validate_native_pin!(attached_stdout, kind)
    validate_raw_checks!(kind, 'source', first_stdout)
    validate_raw_checks!(kind, 'attached', attached_stdout)
    validate_summary_checks!(kind, 'source', summary.fetch('source'))
    validate_summary_checks!(kind, 'attached', summary.fetch('attached'))

    helper_lines = helper_stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).reject(&:empty?)
    require!(helper_lines.size == 1, "#{kind}: helper stdout does not contain exactly one JSON record")
    raw_helper = JSON.parse(helper_lines.fetch(0))
    require!(raw_helper == summary['helper'], "#{kind}: raw helper stdout differs from retained helper observation")
    validate_helper_observations!(kind, raw_helper)
    source_parts = audit_input_and_source_parts!(kind, summary, root)

    {
      'witness' => kind.upcase,
      'result' => 'PASS',
      'carrier_count' => SPECS.fetch(kind).fetch(:cases).size,
      'profile_count' => PROFILES.size,
      'source_part_count' => source_parts.size,
      'owned_values_checked' => source_parts.size,
      'stock_binary_sha256' => BINARY_SHA256,
      'stock_version' => VERSION,
      'stock_build' => BUILD,
      'source_file_audit' => source_parts.keys.sort.map do |table|
        case_id, profile = table.delete_prefix('source_').split(/_(?=single_stream\z|with_size_stream\z)/, 2)
        validate_roster_and_files!(kind, summary, case_id, profile, raw_helper.fetch('cases').find { |item| item['case_id'] == case_id && item['profile_id'] == profile }.fetch('source'), source_parts.fetch(table))
      end,
    }
  rescue Errno::ENOENT, Errno::EACCES => error
    raise AuditFailure, "#{kind}: evidence root is incomplete or unreadable (#{error.message})"
  rescue JSON::ParserError => error
    raise AuditFailure, "#{kind}: invalid evidence JSON (#{error.message})"
  end

  def self.helper_fixture(kind)
    spec = SPECS.fetch(kind)
    {
      'format' => spec.fetch(:format), 'case_ids' => spec.fetch(:cases), 'profile_ids' => PROFILES,
      'cases' => case_profiles(kind).map do |case_id, profile|
        declaration = schema_for(kind, case_id)
        values = expected_rows(kind, case_id)
        owned = {
          'schema_declaration' => declaration,
          'row_count' => spec.fetch(:row_count),
          'mark_row_counts' => spec.fetch(:mark_rows),
          'nominal_type_names_by_mark' => Array.new(spec.fetch(:mark_rows).size) do
            Array.new(spec.fetch(:mark_rows).fetch(0), declaration)
          end,
          'values_by_mark' => values,
        }
        source = {
          'schema_declaration' => declaration, 'row_count' => spec.fetch(:row_count),
          'mark_count' => spec.fetch(:mark_rows).size, 'mark_row_counts' => spec.fetch(:mark_rows),
          'owned_values' => owned,
        }
        if %w[w210 w212].include?(kind)
          source['case_id'] = case_id
          source['profile_id'] = profile
        end
        source['rows_by_mark'] = values if spec.fetch(:low_level_rows)
        {'case_id' => case_id, 'profile_id' => profile, 'source' => source}
      end,
    }
  end

  def self.expect_rejected!(label)
    yield
    raise AuditFailure, "self-test accepted mutation: #{label}"
  rescue AuditFailure => error
    raise if error.message.start_with?('self-test accepted mutation:')
    true
  end

  def self.self_test!
    pin = '1' * 64
    clean_record = {'expected_binary_sha256' => pin, 'binary_sha_after' => pin}
    validate_helper_pin!(clean_record, pin, 'self-test')
    substituted = {'expected_binary_sha256' => '2' * 64, 'binary_sha_after' => '2' * 64}
    expect_rejected!('self-consistent substituted helper') { validate_helper_pin!(substituted, pin, 'self-test') }
    %w[w203 w210 w212 w213].each do |kind|
      clean = helper_fixture(kind)
      validate_helper_observations!(kind, clean)

      mutated_identity = Marshal.load(Marshal.dump(clean))
      mutated_identity.fetch('cases').first['case_id'] = 'unrostered'
      expect_rejected!("#{kind} enclosing case identity") { validate_helper_observations!(kind, mutated_identity) }

      if %w[w210 w212].include?(kind)
        mutated_side_identity = Marshal.load(Marshal.dump(clean))
        mutated_side_identity.fetch('cases').first.fetch('source')['case_id'] = 'unrostered'
        expect_rejected!("#{kind} source case identity") { validate_helper_observations!(kind, mutated_side_identity) }
      end

      mutated_value = Marshal.load(Marshal.dump(clean))
      mutated_value.fetch('cases').first.fetch('source').fetch('owned_values').fetch('values_by_mark').first[0] = 'mutated actual value'
      expect_rejected!("#{kind} owned actual value") { validate_helper_observations!(kind, mutated_value) }

      mutated_type = Marshal.load(Marshal.dump(clean))
      mutated_type.fetch('cases').first.fetch('source').fetch('owned_values').fetch('nominal_type_names_by_mark').first[0] = 'String'
      expect_rejected!("#{kind} nominal descriptor") { validate_helper_observations!(kind, mutated_type) }

      mutated_grid = Marshal.load(Marshal.dump(clean))
      mutated_grid.fetch('cases').first.fetch('source').fetch('owned_values')['mark_row_counts'] = [1, 3] + SPECS.fetch(kind).fetch(:mark_rows).drop(2)
      expect_rejected!("#{kind} row/mark grid") { validate_helper_observations!(kind, mutated_grid) }

      mutated_case = Marshal.load(Marshal.dump(clean))
      mutated_case.fetch('cases').pop
      expect_rejected!("#{kind} missing case") { validate_helper_observations!(kind, mutated_case) }

      missing_owned = Marshal.load(Marshal.dump(clean))
      missing_owned.fetch('cases').first.fetch('source').delete('owned_values')
      expect_rejected!("#{kind} missing owned_values") { validate_helper_observations!(kind, missing_owned) }
    end
    true
  end

  def self.run_cli(argv)
    options = {}
    helper_pins = {}
    self_test = false
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/check_dynamic_owned_evidence_w220.rb --w203 ROOT --helper-sha256 w203=BUILD_ARTIFACT_SHA256 [other witness roots/pins] | --self-test'
      %w[w203 w210 w212 w213].each do |kind|
        parser.on("--#{kind} ROOT", "Read-only audit of #{kind.upcase} evidence root") { |value| options[kind] = value }
      end
      parser.on('--helper-sha256 KIND=SHA256', 'Independently measured compiled helper pin; one for each root') do |value|
        match = /\A(w203|w210|w212|w213)=([0-9a-f]{64})\z/.match(value)
        require!(match && !helper_pins.key?(match[1]), 'malformed or duplicate helper artifact pin')
        helper_pins[match[1]] = match[2]
      end
      parser.on('--self-test', 'Run clean and mutated in-memory owned_values fixtures') { self_test = true }
    end.parse!(argv)
    if self_test
      require!(options.empty? && helper_pins.empty? && argv.empty?, '--self-test cannot be combined with evidence roots, pins or extra arguments')
      self_test!
      puts 'W220 owned-evidence auditor self-test passed (four clean witness shapes; payload/type/grid/census/owned-field/pair-identity and substituted-helper mutations).'
      return 0
    end
    require!(!options.empty? && argv.empty?, 'provide one or more witness roots; see --help')
    require!(helper_pins.keys.sort == options.keys.sort, 'provide exactly one external helper artifact pin for every witness root')
    results = options.sort.map { |kind, root| audit(root, kind, helper_pins.fetch(kind)) }
    results.each { |result| puts JSON.pretty_generate(result) }
    puts 'Supported scope: reported owned-value signatures, exact carrier/profile census, stock version/build pins, retained/raw CHECK blocks, source manifests, and runner-exposed source-part snapshots/mark rosters. Exact recursive encoded-value equality is asserted inside the pinned helper, not independently decoded by this audit. W212/W213 JSON signatures omit maybe and nested descriptor details. W210 raw file hashes are recomputed and reported but have no runner snapshot baseline to compare.'
    0
  rescue AuditFailure, OptionParser::ParseError => error
    warn "W220 evidence audit failed: #{error.message}"
    1
  end
end

if $PROGRAM_NAME == __FILE__
  exit(CheckDynamicOwnedEvidenceW220.run_cli(ARGV))
end
