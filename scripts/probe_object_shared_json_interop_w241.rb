#!/usr/bin/env ruby
# Bounded paired stock/Crystal interoperability capture for JSON-bearing
# inline shared Object values. Every native consumer is a fresh clickhouse-local
# process; direct-path and full-Object SQL are independently authored/captured.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative 'check_array_json_parts_w185'
require_relative 'probe_object_shared_json_w240'
require_relative 'reconcile_object_shared_json_interop_w241'

module ProbeObjectSharedJSONInteropW241
  W185 = CheckArrayJSONPartsW185
  W240 = ProbeObjectSharedJSONW240
  Auditor = ReconcileObjectSharedJSONInteropW241
  BINARY = W185::BINARY
  BINARY_SHA256 = W185::BINARY_SHA256
  VERSION = W185::VERSION
  BUILD = W185::BUILD
  MEMORY = W185::MEMORY
  TIMEOUT = W185::TIMEOUT
  GRACE = W185::GRACE
  OUTER_RUN_SAFE_LIMIT = W185::OUTER_RUN_SAFE_LIMIT
  MAX_PART_FILE_BYTES = 16 * 1024 * 1024
  MAX_RAW_STREAM_BYTES = 1024 * 1024
  DEFAULT_FRAME_BYTES = 32
  FRAME_BYTES_OPTIONS = [32, 64].freeze
  STOCK_TYPE = 'JSON(max_dynamic_paths=0)'.freeze
  SOURCE_W240_ROOT = Auditor::W240_ROOT
  SOURCE_W240_SHA256 = Auditor::W240_SUMMARY_SHA256
  FORMAT_INPUT = 'object_shared_json_interop_w241_input_v2'.freeze
  FORMAT_CAPTURE = 'object_shared_json_interop_w241_capture_v2'.freeze
  MARK_ROWS = [2, 2, 2, 2].freeze
  PHYSICAL_MARK_ROWS = [2, 2, 2, 2, 0].freeze
  SOURCE_INVENTORY_COMPARE_FIELDS = %w[
    physical_file_names logical_substreams columns_substreams_text serialization_json_sha256 checksums_sha256
    ordinary_string_serialization_version mark_triples
  ].freeze
  NEGATIVE_CONTROL_KINDS = %w[data_corrupt copy_truncated].freeze

  LAYOUTS = [
    {id: 'map', enum: 0, setting: 'map'},
    {id: 'map_with_buckets', enum: 1, setting: 'map_with_buckets'},
    {id: 'advanced', enum: 2, setting: 'advanced'},
    {id: 'advanced_chunked', enum: 3, setting: 'advanced_chunked'},
  ].map(&:freeze).freeze
  STRINGS = [
    {id: 's0', setting: 'single_stream', version: 0},
    {id: 's1', setting: 'with_size_stream', version: 1},
  ].map(&:freeze).freeze
  PROFILES = LAYOUTS.flat_map do |layout|
    STRINGS.map { |string| {id: "#{layout.fetch(:id)}_#{string.fetch(:id)}", layout: layout, string: string} }
  end.map(&:freeze).freeze
  PROFILE_IDS = PROFILES.map { |profile| profile.fetch(:id) }.freeze

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

  class SubstreamRosterError < StandardError; end
  class PartSchemaError < StandardError; end
  class SourceInventoryContractError < StandardError; end

  def self.inventory_field_value!(inventory, name)
    raise SourceInventoryContractError, 'inventory is not a Hash' unless inventory.is_a?(Hash)
    has_string = inventory.key?(name)
    has_symbol = inventory.key?(name.to_sym)
    unless has_string ^ has_symbol
      qualifier = has_string ? 'ambiguous' : 'missing'
      raise SourceInventoryContractError, "#{qualifier} inventory field #{name.inspect}"
    end
    has_string ? inventory.fetch(name) : inventory.fetch(name.to_sym)
  end

  def self.normalize_inventory_value(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, nested), result|
        normalized_key = key.to_s
        raise SourceInventoryContractError, "colliding normalized inventory key #{normalized_key.inspect}" if result.key?(normalized_key)
        result[normalized_key] = normalize_inventory_value(nested)
      end
    when Array
      value.map { |nested| normalize_inventory_value(nested) }
    else
      value
    end
  end

  def self.inventory_field_equal?(expected, observed, name)
    expected_value = normalize_inventory_value(inventory_field_value!(expected, name))
    observed_value = normalize_inventory_value(inventory_field_value!(observed, name))
    expected_value == observed_value
  end

  def self.source_stream_inventory_equal?(expected, observed)
    logical = inventory_field_value!(expected, 'logical_substreams')
    stream_inventory = inventory_field_value!(expected, 'stream_file_inventory')
    complete_inventory = inventory_field_value!(observed, 'complete_file_inventory')
    return false unless logical.is_a?(Array) && stream_inventory.is_a?(Hash) && complete_inventory.is_a?(Hash)

    expected_names = logical.flat_map do |stream|
      stem = Auditor.stream_hash(stream)
      ["#{stem}.bin", "#{stem}.mrk2"]
    end
    return false unless expected_names.uniq.size == expected_names.size && stream_inventory.keys.sort == expected_names.sort

    stream_inventory.all? do |name, expected_entry|
      actual_entry = inventory_field_value!(complete_inventory, name)
      normalized_expected = normalize_inventory_value(expected_entry)
      normalized_actual = normalize_inventory_value(actual_entry)
      normalized_expected.keys.sort == %w[sha256 size] && normalized_expected == normalized_actual
    end
  rescue KeyError, TypeError, SourceInventoryContractError
    false
  end

  # Exercise the exact source-inventory projection consumed below: the retained
  # W240/W185 producer may provide String or Symbol top-level keys, while the
  # coordinator projection is Symbol-keyed and mark_triples is nested.
  def self.calibrate_source_inventory_projection!
    marks = [[0, 0, 2], [8, 2, 2], [16, 4, 2], [24, 6, 2], [32, 8, 0]]
    logical = ['pk', 'doc.object_structure']
    stream_file_names = logical.flat_map do |stream|
      stem = Auditor.stream_hash(stream)
      ["#{stem}.bin", "#{stem}.mrk2"]
    end
    stream_inventory = stream_file_names.to_h do |name|
      [name, {size: 24, sha256: Digest::SHA256.hexdigest(name)}]
    end
    expected = {
      'physical_file_names' => (stream_file_names + %w[checksums.txt columns.txt columns_substreams.txt count.txt serialization.json]).sort,
      'logical_substreams' => logical,
      'columns_substreams_text' => "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `doc`:\n\tdoc.object_structure\n",
      'serialization_json_sha256' => 'a' * 64,
      'checksums_sha256' => 'b' * 64,
      'ordinary_string_serialization_version' => 1,
      'mark_triples' => {'pk' => marks, 'doc.object_structure' => marks},
      'stream_file_inventory' => stream_inventory,
    }
    observed = {
      physical_file_names: expected.fetch('physical_file_names').dup,
      logical_substreams: logical.dup,
      columns_substreams_text: expected.fetch('columns_substreams_text'),
      serialization_json_sha256: 'a' * 64,
      checksums_sha256: 'b' * 64,
      ordinary_string_serialization_version: 1,
      mark_triples: {pk: marks, :'doc.object_structure' => marks},
      complete_file_inventory: stream_inventory.merge('count.txt' => {size: 2, sha256: 'e' * 64}),
    }

    SOURCE_INVENTORY_COMPARE_FIELDS.each do |name|
      raise SourceInventoryContractError, "#{name} key projection did not compare equal" unless
        inventory_field_equal?(expected, observed, name)
      mutated = duplicate_inventory_value(observed)
      mutate_inventory_field!(mutated, name)
      raise SourceInventoryContractError, "#{name} value mutation was admitted" if
        inventory_field_equal?(expected, mutated, name)
    end

    raise SourceInventoryContractError, 'stream file digest projection did not compare equal' unless
      source_stream_inventory_equal?(expected, observed)
    changed_stream_digest = duplicate_inventory_value(expected)
    stream_name = stream_file_names.first
    changed_stream_digest.fetch('stream_file_inventory').fetch(stream_name)['sha256'] = 'f' * 64
    raise SourceInventoryContractError, 'stream file digest mutation was admitted' if
      source_stream_inventory_equal?(changed_stream_digest, observed)

    missing = duplicate_inventory_value(observed)
    missing.delete(:logical_substreams)
    reject_inventory_field_shape!(expected, missing, 'logical_substreams')
    ambiguous = duplicate_inventory_value(observed)
    ambiguous['logical_substreams'] = ambiguous.fetch(:logical_substreams)
    reject_inventory_field_shape!(expected, ambiguous, 'logical_substreams')
    ambiguous_marks = duplicate_inventory_value(observed)
    ambiguous_marks[:mark_triples]['pk'] = marks
    reject_inventory_field_shape!(expected, ambiguous_marks, 'mark_triples')
    true
  end

  def self.duplicate_inventory_value(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, nested), copy| copy[key] = duplicate_inventory_value(nested) }
    when Array
      value.map { |nested| duplicate_inventory_value(nested) }
    when String
      value.dup
    else
      value
    end
  end

  def self.mutate_inventory_field!(inventory, name)
    value = inventory_field_value!(inventory, name)
    case name
    when 'physical_file_names'
      value << 'unexpected.bin'
    when 'logical_substreams'
      value << 'doc.w241_unexpected'
    when 'columns_substreams_text'
      value.sub!('doc.object_structure', 'doc.unexpected')
    when 'serialization_json_sha256'
      value[0] = value[0] == 'a' ? 'c' : 'a'
    when 'checksums_sha256'
      value[0] = value[0] == 'b' ? 'd' : 'b'
    when 'ordinary_string_serialization_version'
      raise SourceInventoryContractError, 'unexpected fixture String version' unless value == 1
      key = inventory.key?(name) ? name : name.to_sym
      inventory[key] = 0
    when 'mark_triples'
      key = value.key?('pk') ? 'pk' : :pk
      value.fetch(key).first[2] += 1
    else
      raise SourceInventoryContractError, "unrostered source inventory field #{name.inspect}"
    end
  end

  def self.reject_inventory_field_shape!(expected, observed, name)
    inventory_field_equal?(expected, observed, name)
    raise SourceInventoryContractError, "invalid #{name} key shape was admitted"
  rescue SourceInventoryContractError => error
    raise if error.message == "invalid #{name} key shape was admitted"
    true
  end

  def self.canonical_schema_profile!(profile)
    schema_require!(profile.is_a?(Hash), 'profile is not an object')
    profile_id = profile.fetch(:id)
    canonical = PROFILES.find { |candidate| candidate.fetch(:id) == profile_id }
    schema_require!(!canonical.nil? && canonical == profile, 'unknown or altered schema profile')
    canonical
  rescue KeyError, TypeError => error
    raise PartSchemaError, "invalid schema profile: #{error.class}: #{error.message}"
  end

  def self.negative_observation_context!(profile, kind, token)
    canonical = canonical_schema_profile!(profile)
    schema_require!(canonical.fetch(:id) == 'advanced_chunked_s0',
                    'negative observation context requires advanced_chunked_s0 base profile')
    schema_require!(NEGATIVE_CONTROL_KINDS.include?(kind), 'unknown negative observation kind')
    schema_require!(token.is_a?(String) && /\A[0-9a-f]{8}\z/.match?(token),
                    'negative observation token is not canonical')
    id = "#{canonical.fetch(:id)}_negative_#{kind}"
    {profile_id: canonical.fetch(:id), kind: kind, id: id,
     table: "w241_#{token}_#{id}_target"}
  rescue KeyError, TypeError => error
    raise PartSchemaError, "invalid negative observation context: #{error.class}: #{error.message}"
  end

  def self.validate_negative_observation_context!(profile, context, token)
    schema_require!(context.is_a?(Hash), 'negative observation context is not an object')
    expected = negative_observation_context!(profile, context.fetch(:kind), token)
    schema_require!(context.keys.sort == expected.keys.sort && context == expected,
                    'negative observation context id/table differs from canonical derivation')
    expected
  rescue KeyError, TypeError => error
    raise PartSchemaError, "invalid negative observation context: #{error.class}: #{error.message}"
  end

  # Reopen a retained capture without starting ClickHouse. This calibration
  # authenticates the invocation artifacts, then checks positive base identities,
  # suffix-bound negative identities, nearby id/table rejection, and both
  # targeted negative effects through the same production parsers.
  def self.calibrate_retained_negative_observations!(capture_root)
    root = File.expand_path(capture_root)
    raise PartSchemaError, 'retained capture root is outside /private/tmp' unless
      File.dirname(root) == File.realpath('/private/tmp') && File.directory?(root) && File.realpath(root) == root
    probe = Probe.allocate
    probe.instance_variable_set(:@root, root)
    probe.instance_variable_set(:@token, Digest::SHA256.hexdigest(root)[0, 8])
    probe.send(:calibrate_retained_negative_observations!)
  rescue Errno::ENOENT => error
    raise PartSchemaError, "retained capture root is unavailable: #{error.message}"
  end

  def self.part_pk_type!(profile, role)
    canonical = canonical_schema_profile!(profile)
    case role
    when 'stock source'
      canonical.fetch(:string).fetch(:version) == 1 ? 'UInt8' : 'UInt64'
    when 'Crystal generated'
      'UInt64'
    when 'Crystal generated negative-control baseline', 'negative part'
      schema_require!(canonical.fetch(:id) == 'advanced_chunked_s0',
                      "role #{role.inspect} is only valid for advanced_chunked_s0")
      'UInt64'
    else
      raise PartSchemaError, "unknown part schema role: #{role.inspect}"
    end
  rescue KeyError, TypeError => error
    raise PartSchemaError, "invalid schema role/profile: #{error.class}: #{error.message}"
  end

  def self.part_columns_text(pk_type)
    "columns format version: 1\n2 columns:\n`pk` #{pk_type}\n`doc` #{STOCK_TYPE}\n"
  end

  def self.schema_require!(condition, message)
    raise PartSchemaError, message unless condition
  end

  def self.validate_part_columns!(text, profile, role)
    expected = part_columns_text(part_pk_type!(profile, role))
    schema_require!(text.is_a?(String) && text == expected,
                    "#{profile.fetch(:id)} #{role} exact columns schema differs")
    true
  end

  # Callable offline guard for the closed role/profile matrix. Each legitimate
  # schema is accepted exactly, while a nearby pk-type substitution is rejected.
  def self.calibrate_part_schema_contract!
    PROFILES.each do |profile|
      ['stock source', 'Crystal generated'].each do |role|
        pk_type = part_pk_type!(profile, role)
        validate_part_columns!(part_columns_text(pk_type), profile, role)
        wrong_type = pk_type == 'UInt8' ? 'UInt64' : 'UInt8'
        reject_part_schema_mutation!(part_columns_text(wrong_type), profile, role)
      end
    end

    baseline = PROFILES.find { |profile| profile.fetch(:id) == 'advanced_chunked_s0' }
    ['Crystal generated negative-control baseline', 'negative part'].each do |role|
      validate_part_columns!(part_columns_text('UInt64'), baseline, role)
      reject_part_schema_mutation!(part_columns_text('UInt8'), baseline, role)
    end
    reject_part_schema_role!(baseline, 'stock source typo')
    reject_part_schema_role!(PROFILES.find { |profile| profile.fetch(:id) == 'advanced_chunked_s1' },
                             'Crystal generated negative-control baseline')
    reject_part_schema_profile!({id: 'unknown'})
    true
  end

  def self.reject_part_schema_mutation!(text, profile, role)
    validate_part_columns!(text, profile, role)
    raise PartSchemaError, "#{role} pk-type mutation was admitted"
  rescue PartSchemaError => error
    raise if error.message == "#{role} pk-type mutation was admitted"
    true
  end

  def self.reject_part_schema_role!(profile, role)
    part_pk_type!(profile, role)
    raise PartSchemaError, "unknown schema role #{role.inspect} was admitted"
  rescue PartSchemaError => error
    raise if error.message == "unknown schema role #{role.inspect} was admitted"
    true
  end

  def self.reject_part_schema_profile!(profile)
    part_pk_type!(profile, 'Crystal generated')
    raise PartSchemaError, 'unknown schema profile was admitted'
  rescue PartSchemaError => error
    raise if error.message == 'unknown schema profile was admitted'
    true
  end

  def self.parse_substream_metadata!(text, profile)
    roster_require!(text.is_a?(String), 'columns_substreams is not text')
    lines = text.split("\n", -1)
    roster_require!(lines.pop == '', 'columns_substreams lacks its final newline')
    roster_require!(lines.shift == 'columns substreams version: 1', 'columns_substreams version differs')
    roster_require!(lines.shift == '2 columns:', 'columns_substreams column count differs')

    sections = []
    while !lines.empty?
      header = lines.shift
      match = /\A(0|[1-9][0-9]*) substreams for column `([a-z][a-z0-9_]*)`:\z/.match(header)
      roster_require!(!match.nil?, 'malformed column substream section')
      count = Integer(match[1], 10)
      roster_require!(count <= 64 && lines.size >= count, 'substream count exceeds bounded metadata')
      names = []
      count.times do
        line = lines.shift
        entry = /\A\t([A-Za-z0-9_.%]+)\z/.match(line)
        roster_require!(!entry.nil?, 'malformed logical substream name')
        names << entry[1]
      end
      sections << [match[2], names]
      roster_require!(sections.size <= 2, 'unexpected extra column section')
    end

    roster_require!(sections.map(&:first) == %w[pk doc], 'metadata column roles/order differ')
    table_streams = sections.flat_map(&:last)
    object_streams = sections.fetch(1).fetch(1)
    roster_require!(table_streams.uniq == table_streams, 'duplicate or aliased logical substream')
    roster_require!(sections.fetch(0).fetch(1) == ['pk'], 'pk must own exactly the pk stream')

    layout_id = profile.fetch(:layout).fetch(:id)
    expected_object_streams = Auditor::W240_LAYOUT_STREAMS.fetch(layout_id).reject { |name| name == 'pk' }
    roster_require!(object_streams.uniq == object_streams, 'duplicate Object logical substream')
    roster_require!(object_streams.sort == expected_object_streams.sort,
                    "Object substream roles/count differ for #{layout_id}")
    roster_require!(expected_object_streams.size == expected_object_streams.uniq.size,
                    'pinned Object roster itself contains duplicate roles')

    physical_stems = table_streams.map { |name| Auditor.stream_hash(name) }
    roster_require!(physical_stems.uniq == physical_stems, 'logical substreams alias a physical stream stem')
    {logical_substreams: table_streams, object_substreams: object_streams}
  rescue KeyError, ArgumentError, TypeError => error
    raise SubstreamRosterError, "invalid columns_substreams envelope: #{error.class}: #{error.message}"
  end

  # Run this against the actual part metadata before accepting its roster. The
  # mutations preserve section counts where relevant, so each failure exercises
  # a semantic role/uniqueness guard rather than only a malformed-text check.
  def self.calibrate_substream_metadata!(captured_text, profile)
    baseline = parse_substream_metadata!(captured_text, profile)
    reject_substream_mutation!('missing pk', captured_text.sub("1 substreams for column `pk`:\n\tpk\n",
                                                               "0 substreams for column `pk`:\n"), profile)

    doc_header = /^([0-9]+) substreams for column `doc`:$/
    match = doc_header.match(captured_text)
    roster_require!(!match.nil?, 'cannot calibrate absent doc section')
    next_count = Integer(match[1], 10) + 1
    extra_doc = captured_text.sub(match[0], "#{next_count} substreams for column `doc`:")
    extra_doc = "#{extra_doc}\tdoc.w241_unexpected\n"
    reject_substream_mutation!('extra doc stream', extra_doc, profile)

    duplicate_name = baseline.fetch(:object_substreams).first
    duplicate_line = "\t#{duplicate_name}\n"
    duplicate_doc = captured_text.sub(match[0], "#{next_count} substreams for column `doc`:")
    roster_require!(duplicate_doc.scan(Regexp.new(Regexp.escape(duplicate_line))).size == 1,
                    'cannot calibrate duplicate doc role')
    duplicate_doc = duplicate_doc.sub(duplicate_line, duplicate_line + duplicate_line)
    reject_substream_mutation!('duplicate doc role', duplicate_doc, profile)
    baseline
  end

  def self.reject_substream_mutation!(label, text, profile)
    parse_substream_metadata!(text, profile)
    raise SubstreamRosterError, "#{label} mutation was admitted"
  rescue SubstreamRosterError => error
    raise if error.message == "#{label} mutation was admitted"
    true
  end

  def self.roster_require!(condition, message)
    raise SubstreamRosterError, message unless condition
  end

  class Probe
    def initialize(binary, crystal_helper, evidence_root, frame_bytes = DEFAULT_FRAME_BYTES)
      fail!('frame_bytes must be exactly 32 or 64') unless FRAME_BYTES_OPTIONS.include?(frame_bytes)
      @binary = validate_executable(binary, 'ClickHouse')
      @helper = validate_executable(crystal_helper, 'Crystal helper')
      @root = validate_root(evidence_root)
      @frame_bytes = frame_bytes
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @invocations = []
      @profiles = []
      @fatal_error = nil
      @part_inspector = W185::Probe.allocate
      @part_inspector.instance_variable_set(:@root, @root)
    end

    def run
      ProbeObjectSharedJSONInteropW241.calibrate_part_schema_contract!
      ProbeObjectSharedJSONInteropW241.calibrate_source_inventory_projection!
      %w[invocations stores parts generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      @sha_before = binary_sha
      fail!('pinned ClickHouse SHA-256 differs before capture') unless @sha_before == BINARY_SHA256

      w240 = Auditor.authenticate_w240!(SOURCE_W240_ROOT, SOURCE_W240_SHA256)
      source_parts = {}
      PROFILES.each do |profile|
        id = profile.fetch(:id)
        if profile.fetch(:string).fetch(:id) == 's1'
          source = w240.fetch(:profiles).fetch(profile.fetch(:layout).fetch(:id))
          source_parts[id] = {
            path: source.fetch(:part_path), origin: 'authenticated W240 stock capture',
            w240_summary_sha256: w240.fetch(:summary_sha256),
            inventory: source.fetch(:part_inventory),
            physical_layout: source.fetch(:physical_layout),
            native_stages: source.fetch(:source_stage_records),
          }
          assert_source_w240_profile!(source, profile)
        else
          source_parts[id] = capture_stock_source!(profile)
        end
      end

      helper = run_crystal_helper!(source_parts)
      generated = authenticate_helper_parts!(helper, source_parts)
      PROFILES.each do |profile|
        @profiles << qualify_generated_profile!(profile, source_parts.fetch(profile.fetch(:id)),
                                                generated.fetch(profile.fetch(:id)))
      end
      negatives = qualify_negative_controls!(helper)

      @sha_after = binary_sha
      fail!('pinned ClickHouse SHA-256 changed during capture') unless @sha_after == BINARY_SHA256
      status = @profiles.size == PROFILES.size && @profiles.all? { |item| item.fetch(:status) == 'paired_stock_crystal_observed' } ?
        'paired_stock_crystal_observed' : 'capture_incomplete_or_observations_differ'
      summary = {
        format: FORMAT_CAPTURE, status: status, fatal_error: @fatal_error,
        requested_frame_bytes: @frame_bytes,
        runtime: {path: @binary, sha256: BINARY_SHA256, version: VERSION, build: BUILD,
                  sha256_before: @sha_before, sha256_after: @sha_after},
        limits: {native_max_threads: 1, native_max_memory_usage_bytes: MEMORY,
                 outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE},
        source_capture: {w240_root: SOURCE_W240_ROOT, w240_summary_sha256: w240.fetch(:summary_sha256),
                         s1_source_authentication: 'W240 summary and retained parts/invocations independently reopened'},
        fixture: ROWS, profile_ids: PROFILE_IDS,
        helper: helper.fetch(:record), helper_sha256_before: helper.fetch(:sha_before),
        helper_sha256_after: helper.fetch(:sha_after), helper_input: helper.fetch(:input),
        profiles: @profiles, negative_controls: negatives, invocations: @invocations,
        evidence_root: @root,
        interpretation: {
          source_to_crystal: 'The Crystal helper independently opens every authenticated stock part, performs a fresh selected-path reader stage and a separate full-Object reader stage, and compares exact logical rows and type witnesses.',
          crystal_to_stock: 'Each generated part is attached and CHECKed by stock ClickHouse, then direct-only and full/middle/last/empty-selection SELECTs run in separate fresh clickhouse-local invocations.',
          string_modes: 's0/s1 are established by actual serialization.json plus ordinary String physical bindings, not only by CREATE settings.',
          advanced_reads: 'Only ADVANCED/ADVANCED_CHUNKED path results are selected Data-path evidence. MAP and MAP_WITH_BUCKETS use bounded selected shared lanes and are not described as physically selective.',
          child_scope: 'The stock fixture has inferred Array(JSON) witnesses; only Crystal-generated child descriptors use explicit typed v UInt8 plus dynamic String child plans. No nested-child selective projection is claimed.',
          failure_policy: 'Any failed process, SQL stage, schema, physical inventory, direct/full assertion, or native CHECK is inconclusive for that profile, not unsupported-format proof.',
        },
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), render_summary(summary))
      puts "W241 status=#{status}; profiles=#{@profiles.count { |item| item.fetch(:status) == 'paired_stock_crystal_observed' }}/#{PROFILES.size}; evidence=#{@root}"
      status == 'paired_stock_crystal_observed'
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @sha_after = binary_sha rescue nil
      write_failure_summary rescue nil
      warn "W241 paired shared JSON probe failed inconclusively: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise RuntimeError, "W241: #{message}"
    end

    def validate_root(path)
      fail!('evidence root is required') unless path && !path.empty?
      expanded = File.expand_path(path)
      fail!('evidence root must be a direct child of /private/tmp') unless File.dirname(expanded) == File.realpath('/private/tmp')
      fail!('evidence root is symlinked') if File.symlink?(expanded)
      fail!('evidence root must already exist and be empty') unless File.directory?(expanded) && File.realpath(expanded) == expanded && Dir.children(expanded).empty?
      expanded
    rescue Errno::ENOENT
      fail!('evidence root must already exist')
    end

    def validate_executable(path, label)
      fail!("#{label} path is absent") unless path && !path.empty?
      expanded = File.expand_path(path)
      fail!("#{label} is absent, not executable, or symlinked") unless File.file?(expanded) && File.executable?(expanded) && !File.symlink?(expanded)
      expanded
    end

    def binary_sha
      Digest::SHA256.file(@binary).hexdigest
    end

    def helper_sha
      Digest::SHA256.file(@helper).hexdigest
    end

    def write_new(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    def run_process(label, argv, input, kind, expected_sha:, binary_path:, store: nil)
      base = File.join(@root, 'invocations', label)
      before = binary_path ? Digest::SHA256.file(binary_path).hexdigest : nil
      fail!("#{label} binary SHA differs before process") if expected_sha && before != expected_sha
      stdin_name = "#{label}.stdin.#{kind == 'clickhouse-local' ? 'sql' : 'bin'}"
      argv_name = "#{label}.argv.json"
      stdout_name = "#{label}.stdout"
      stderr_name = "#{label}.stderr"
      record_name = "#{label}.json"
      argv_bytes = JSON.pretty_generate(argv) + "\n"
      write_new(File.join(@root, 'invocations', stdin_name), input)
      write_new(File.join(@root, 'invocations', argv_name), argv_bytes)
      executor = JsonBinaryKernelW180Probe.allocate
      stdout, stderr, status, timed_out, spawn_error, stdin_error, stdout_error, stderr_error = executor.send(:execute, argv, input)
      after = binary_path ? Digest::SHA256.file(binary_path).hexdigest : nil
      classification = executor.send(:process_classification, status, timed_out, spawn_error,
                                     stdin_error, stdout_error, stderr_error, stderr)
      record = {
        label: label, process_kind: kind, argv: argv, argv_file: argv_name,
        argv_sha256: Digest::SHA256.hexdigest(argv_bytes), stdin_file: stdin_name,
        stdin_bytes: input.bytesize, stdin_sha256: Digest::SHA256.hexdigest(input),
        stdout_file: stdout_name, stdout_bytes: stdout.bytesize, stdout_sha256: Digest::SHA256.hexdigest(stdout),
        stderr_file: stderr_name, stderr_bytes: stderr.bytesize, stderr_sha256: Digest::SHA256.hexdigest(stderr),
        exit: status&.exitstatus, signal: status&.termsig, timed_out: timed_out,
        timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE,
        max_threads: %w[clickhouse-local clickhouse-compressor].include?(kind) ? 1 : nil,
        max_memory_usage_bytes: kind == 'clickhouse-local' ? MEMORY : nil,
        max_memory_usage_applicable: kind == 'clickhouse-local',
        required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
        binary_path: binary_path, expected_binary_sha256: expected_sha,
        binary_sha_before: before, binary_sha_after: after,
        spawn_error: spawn_error, stdin_write_error: stdin_error,
        stdout_read_error: stdout_error, stderr_read_error: stderr_error,
        process_classification: classification, store_path: store,
      }
      write_new(File.join(@root, 'invocations', stdout_name), stdout)
      write_new(File.join(@root, 'invocations', stderr_name), stderr)
      write_new(File.join(@root, 'invocations', record_name), JSON.pretty_generate(record) + "\n")
      @invocations << record
      {stdout: stdout, stderr: stderr, status: status, classification: classification, record: record}
    end

    def native(label, store, sql)
      argv = [@binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
              "--max_memory_usage=#{MEMORY}", '--multiquery']
      run_process(label, argv, sql.b, 'clickhouse-local', expected_sha: BINARY_SHA256,
                  binary_path: @binary, store: store)
    end

    def assert_native_success!(invocation, label)
      fail!("#{label} native invocation did not exit successfully: #{invocation[:record].inspect}") unless
        invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
      fail!("#{label} wrote stderr") unless invocation[:stderr].empty?
      fail!("#{label} binary identity changed") unless invocation[:record][:binary_sha_after] == BINARY_SHA256
    end

    def table_name(id, suffix)
      "w241_#{@token}_#{id}_#{suffix}"
    end

    def sql_string(value)
      "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
    end

    def settings(profile)
      layout = profile.fetch(:layout)
      string = profile.fetch(:string)
      values = W240::SETTINGS_BASE + [
        "object_shared_data_serialization_version='#{layout.fetch(:setting)}'",
        "object_shared_data_serialization_version_for_zero_level_parts='#{layout.fetch(:setting)}'",
        "string_serialization_version='#{string.fetch(:setting)}'",
      ]
      values << 'object_shared_data_target_chunk_rows=2' if layout.fetch(:enum) == 3
      values.join(', ')
    end

    def write_source_sql(profile, table)
      inserts = ROWS.map do |row|
        json = JSON.generate(row.fetch(:doc))
        "(#{row.fetch(:pk)}, CAST(#{sql_string(json)}, #{sql_string(STOCK_TYPE)}))"
      end
      [
        'SET output_format_json_quote_64bit_integers=0;',
        "SELECT '__W241_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        "CREATE TABLE default.#{table} (pk UInt64, doc #{STOCK_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(profile)};",
        "INSERT INTO default.#{table} VALUES #{inserts.join(",\n")};",
        "SELECT '__W241_CHECK_BEGIN__', '#{profile.fetch(:id)}' FORMAT TSVRaw;",
        "CHECK TABLE default.#{table} FORMAT TSV;",
        "SELECT '__W241_CHECK_END__', '#{profile.fetch(:id)}' FORMAT TSVRaw;",
        "SELECT '__W241_SCHEMA__', '#{profile.fetch(:id)}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;",
        "SELECT '__W241_PART__', '#{profile.fetch(:id)}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;",
      ].join("\n") + "\n"
    end

    def direct_query(table, id)
      "SELECT '__W241_DIRECT__', '#{id}', toString(pk), " \
        "toTypeName(doc.arr), if(isNull(doc.arr), 'NULL', dynamicType(doc.arr)), if(isNull(doc.arr), '6E756C6C', hex(toJSONString(doc.arr))), " \
        "toTypeName(doc.mixed), if(isNull(doc.mixed), 'NULL', dynamicType(doc.mixed)), if(isNull(doc.mixed), '6E756C6c', hex(toJSONString(doc.mixed))), " \
        "toTypeName(doc.late), if(isNull(doc.late), 'NULL', dynamicType(doc.late)), if(isNull(doc.late), '6E756C6c', hex(toJSONString(doc.late))) " \
        "FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;"
    end

    def full_select(table, tag, predicate = nil)
      where = predicate ? " WHERE #{predicate}" : ''
      "SELECT '#{tag}', '#{table}', toString(pk), toTypeName(doc), hex(toJSONString(doc)), " \
        "hex(toJSONString(JSONDynamicPaths(doc))), hex(toJSONString(JSONSharedDataPaths(doc))) " \
        "FROM default.#{table}#{where} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;"
    end

    def full_query(table)
      [full_select(table, '__W241_FULL__'), full_select(table, '__W241_MIDDLE__', 'pk BETWEEN 3 AND 6'),
       full_select(table, '__W241_LAST__', 'pk = 8'),
       "SELECT '__W241_ZERO_QUERY__', toString(count()), hex(toJSONString(groupArray(doc))) " \
         "FROM default.#{table} WHERE pk > 8 SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;"].join("\n")
    end

    def pin_sql
      "SET output_format_json_quote_64bit_integers=0;\n" \
        "SELECT '__W241_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;"
    end

    def capture_stock_source!(profile)
      id = profile.fetch(:id)
      table = table_name(id, 'source')
      store = File.join(@root, 'stores', 'native')
      label = "source_write_#{id}"
      invocation = native(label, store, write_source_sql(profile, table))
      assert_native_success!(invocation, label)
      assert_pin!(invocation[:stdout], label)
      observation = parse_write_stage!(invocation[:stdout], profile, table)
      observation[:path] = normalize_native_part_path!(observation.fetch(:path), store, id)
      part = W185::Probe.allocate
      part.instance_variable_set(:@root, @root)
      inventory = part.send(:inspect_part, "W241 stock #{id}", observation.fetch(:path), observation)
      direct = run_query_stage!("source_direct_#{id}", store, [pin_sql, direct_query(table, id)].join("\n"), profile, :direct)
      full = run_query_stage!("source_full_#{id}", store, [pin_sql, full_query(table)].join("\n"), profile, :full)
      {path: observation.fetch(:path), origin: 'fresh W241 stock capture', inventory: inventory,
       physical_layout: {status: 'deferred to authenticated helper/native stream decode'},
       native_stages: {write: invocation[:record], direct: direct, full: full}}
    end

    def parse_write_stage!(stdout, profile, table)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      id = profile.fetch(:id)
      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W241_CHECK_BEGIN__\t")
          fields = line.split("\t", -1)
          fail!("#{id} malformed CHECK begin") unless fields == ['__W241_CHECK_BEGIN__', id] && active.nil?
          active = id
          checks[id] = []
        elsif line.start_with?("__W241_CHECK_END__\t")
          fields = line.split("\t", -1)
          fail!("#{id} malformed CHECK end") unless fields == ['__W241_CHECK_END__', id] && active == id
          active = nil
        elsif active
          checks.fetch(active) << line
        end
      end
      fail!("#{id} native CHECK differs") unless active.nil? && checks == {id => ["all_1_1_0\t1\t"]}
      schemas = tagged_rows(stdout, '__W241_SCHEMA__')
      fail!("#{id} schema differs") unless schemas.map { |row| row.drop(2) } == [['pk', 'UInt64'], ['doc', STOCK_TYPE]]
      parts = tagged_rows(stdout, '__W241_PART__')
      fail!("#{id} must have one active Wide part") unless parts.size == 1 && parts[0].size == 8
      fields = parts[0]
      fail!("#{id} part identity differs") unless fields.values_at(1, 2, 3, 5, 6, 7) == [id, table, 'all_1_1_0', 'Wide', '8', '5']
      {path: fields[4], name: fields[3], part_type: fields[5], rows: fields[6], marks: fields[7]}
    end

    def normalize_native_part_path!(raw_path, store, id)
      fail!("#{id} native part path is not absolute") unless raw_path.is_a?(String) && raw_path.start_with?(File::SEPARATOR)
      fail!("#{id} native part path has repeated trailing separators") if raw_path.end_with?(File::SEPARATOR * 2)
      path = raw_path.end_with?(File::SEPARATOR) ? raw_path[0...-1] : raw_path
      fail!("#{id} native part path is not canonical text") if path.empty? || path.include?("\0") || File.expand_path(path) != path

      expected_store = File.join(@root, 'stores', 'native')
      fail!("#{id} native store identity differs") unless File.expand_path(store) == expected_store
      store_root = expected_store
      fail!("#{id} native store root is symlinked or noncanonical") unless
        File.directory?(store_root) && !File.symlink?(store_root) && File.realpath(store_root) == store_root
      prefix = store_root + File::SEPARATOR
      fail!("#{id} native part path escaped its isolated store: #{raw_path}") unless path.start_with?(prefix)
      relative = path.delete_prefix(prefix)
      components = relative.split(File::SEPARATOR, -1)
      fail!("#{id} native part path has an invalid part suffix") unless
        components.size >= 2 && components.last == 'all_1_1_0' && components.none? { |part| part.empty? || part == '.' || part == '..' }

      current = store_root
      components.each do |part|
        current = File.join(current, part)
        fail!("#{id} symlink in native part path: #{current}") if File.symlink?(current)
      end
      fail!("#{id} native part path is absent or not a directory") unless File.directory?(path)
      fail!("#{id} native part path is not realpath-canonical") unless File.realpath(path) == path
      path
    rescue Errno::ENOENT, Errno::EACCES, ArgumentError => error
      fail!("#{id} native part path validation failed: #{error.class}: #{error.message}")
    end

    def assert_source_w240_profile!(source, profile)
      layout = profile.fetch(:layout)
      physical = source.fetch(:physical_layout)
      expected = layout.fetch(:id)
      expected_streams = Auditor::W240_LAYOUT_STREAMS.fetch(expected)
      fail!("#{profile.fetch(:id)} W240 authenticated physical stream roster differs") unless
        physical.fetch(:logical_substreams).sort == expected_streams.sort
      inventory = source.fetch(:part_inventory)
      fail!("#{profile.fetch(:id)} W240 String serialization version is not s1") unless inventory.fetch('ordinary_string_serialization_version') == 1
      fail!("#{profile.fetch(:id)} W240 plain part inventory is not complete") unless inventory.fetch('plain_mrk2_only') == true
      true
    end

    def run_crystal_helper!(source_parts)
      output_root = File.join(@root, 'generated')
      fail!('generated helper root is absent, symlinked, or not canonical') unless
        File.directory?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root
      fail!('generated helper root is not empty before helper input creation') unless Dir.children(output_root).empty?
      input = {
        'format' => FORMAT_INPUT,
        'frame_bytes' => @frame_bytes,
        'capture_root' => File.realpath('/private/tmp'),
        'profiles' => PROFILES.map do |profile|
          {'id' => profile.fetch(:id), 'shared_version' => profile.fetch(:layout).fetch(:enum),
           'string_profile' => profile.fetch(:string).fetch(:id),
           'source_part' => source_parts.fetch(profile.fetch(:id)).fetch(:path)}
        end,
      }
      input_path = File.join(output_root, 'helper_input.json')
      bytes = JSON.pretty_generate(input) + "\n"
      write_new(input_path, bytes)
      before = helper_sha
      argv = [@helper, input_path, output_root]
      invocation = run_process('crystal_helper', argv, ''.b, 'crystal-helper', expected_sha: before,
                               binary_path: @helper)
      fail!('Crystal helper did not exit successfully') unless invocation[:classification] == 'success' && invocation[:status]&.success?
      fail!('Crystal helper wrote stderr') unless invocation[:stderr].empty?
      after = helper_sha
      fail!('Crystal helper binary changed during invocation') unless before == after
      lines = invocation[:stdout].force_encoding(Encoding::UTF_8).lines.map(&:chomp).reject(&:empty?)
      fail!('Crystal helper must emit exactly one JSON object') unless lines.size == 1
      result = JSON.parse(lines.first)
      fail!('Crystal helper result format differs') unless result['format'] == 'object_shared_json_interop_w241_helper_v2'
      fail!('Crystal helper frame_bytes witness differs') unless result['requested_frame_bytes'] == @frame_bytes
      fail!('Crystal helper input SHA differs') unless result['input_sha256'] == Digest::SHA256.hexdigest(bytes)
      fail!('Crystal helper profile order differs') unless result['profile_ids'] == PROFILE_IDS
      {data: result, input: input, input_sha256: Digest::SHA256.hexdigest(bytes),
       output_root: output_root, sha_before: before, sha_after: after, record: invocation[:record]}
    end

    def authenticate_helper_parts!(helper, source_parts)
      data = helper.fetch(:data)
      records = data.fetch('profiles')
      fail!('Crystal helper profile result count differs') unless records.size == PROFILES.size
      PROFILES.zip(records).to_h do |profile, record|
        id = profile.fetch(:id)
        fail!("#{id} Crystal helper result identity differs") unless record.fetch('id') == id
        fail!("#{id} generated writer frame-size request differs") unless
          record.fetch('writer').fetch('requested_frame_bytes') == @frame_bytes
        source = record.fetch('source_read')
        generated = record.fetch('generated_read')
        expected_rows = ROWS.map { |row| {'pk' => row.fetch(:pk), 'doc' => row.fetch(:doc)} }
        fail!("#{id} stock source full rows differ") unless source.fetch('full_rows') == expected_rows
        fail!("#{id} stock source direct values differ") unless
          direct_helper_values(source.fetch('direct_shared_path_rows'), profile) == expected_direct_values
        fail!("#{id} generated Crystal full rows differ") unless generated.fetch('full_rows') == expected_rows
        fail!("#{id} generated Crystal direct values differ") unless
          direct_helper_values(generated.fetch('direct_shared_path_rows'), profile) == expected_direct_values
        assert_nested_type_witnesses!(source, profile, 'stock source')
        assert_nested_type_witnesses!(generated, profile, 'Crystal generated')
        string_version = profile.fetch(:string).fetch(:version)
        [source, generated].each do |read|
          fail!("#{id} actual shared-data version differs") unless read.fetch('actual_shared_data_version') == profile.fetch(:layout).fetch(:enum)
          fail!("#{id} ordinary String version differs") unless read.fetch('ordinary_string_profile') == string_version
          fail!("#{id} String serialization metadata differs") unless read.dig('serialization_json', 'types_serialization_versions', 'string') == string_version
          fail!("#{id} mark grid differs") unless read.fetch('mark_row_counts') == MARK_ROWS
          fail!("#{id} empty array carrier differs") unless read.fetch('direct_shared_path_rows').fetch('arr').find { |row| row.fetch('pk') == 3 }.fetch('type') == 'Array(Nullable(String))'
          fail!("#{id} path-read semantics label differs") unless read.fetch('direct_shared_path_semantics') == (profile.fetch(:layout).fetch(:enum) < 2 ? 'bounded selected shared MAP lane; not physically selective' : 'selected shared Data path; whole-Object read was performed by a separate reader')
        end
        source_path = source_parts.fetch(id).fetch(:path)
        fail!("#{id} helper source path differs from the coordinator input") unless File.expand_path(source.fetch('part_path')) == source_path
        source_inventory = authenticate_helper_part!(source_path, source, profile, 'stock source')
        source_native_decodes = capture_native_stream_decodes!(id, 'source', source_path,
                                                                source.fetch('raw_shared_streams'))
        # Parse physical layout only after the pinned native decompressor has
        # independently bound helper raw bytes to each retained .bin stream.
        source_physical = audit_physical_part!(source_path, source_inventory.fetch(:object_substreams), profile,
                                               raw_streams: source.fetch('raw_shared_streams'))
        compare_source_inventory!(source_parts.fetch(id).fetch(:inventory), source_inventory, profile)
        generated_path = File.join(helper.fetch(:output_root), id, 'all_1_1_0')
        inventory = authenticate_helper_part!(generated_path, generated, profile, 'Crystal generated')
        generated_native_decodes = capture_native_stream_decodes!(id, 'generated', generated_path,
                                                                   generated.fetch('raw_shared_streams'))
        physical = audit_physical_part!(generated_path, inventory.fetch(:object_substreams), profile,
                                        raw_streams: generated.fetch('raw_shared_streams'))
        [id, {record: record, part_path: generated_path, inventory: inventory, physical_layout: physical,
              source_part_path: source_path, source_inventory: source_inventory, source_physical_layout: source_physical,
              source_native_stream_decodes: source_native_decodes,
              generated_native_stream_decodes: generated_native_decodes}]
      end
    end

    # Independently bind the helper's decoded raw witness to the actual plain
    # part .bin using the same pinned ClickHouse compressor captured in the
    # invocation ledger. The helper's decoder remains useful for layout
    # parsing, but is not its own corroboration.
    def capture_native_stream_decodes!(profile_id, role, part_path, raw_streams)
      fail!("#{profile_id} #{role} raw stream roster is malformed") unless raw_streams.is_a?(Hash) && !raw_streams.empty?
      frame_walker = Auditor::W190_PROBE.allocate
      raw_streams.keys.sort.map do |logical_name|
        entry = raw_streams.fetch(logical_name)
        expected_name = "#{Auditor.stream_hash(logical_name)}.bin"
        fail!("#{profile_id} #{role} raw stream filename differs for #{logical_name}") unless entry.fetch('physical_file') == expected_name
        path = File.join(part_path, expected_name)
        fail!("#{profile_id} #{role} stream is absent or symlinked: #{logical_name}") unless File.file?(path) && !File.symlink?(path)
        size = File.size(path)
        fail!("#{profile_id} #{role} compressed stream exceeds the bound: #{logical_name}") if size > MAX_PART_FILE_BYTES
        compressed = File.binread(path)
        fail!("#{profile_id} #{role} stream changed while reading: #{logical_name}") unless compressed.bytesize == size
        physical_sha = Digest::SHA256.hexdigest(compressed)
        fail!("#{profile_id} #{role} helper physical stream digest differs: #{logical_name}") unless physical_sha == entry.fetch('physical_sha256')
        frames = frame_walker.send(:compressed_frame_spans!, compressed, logical_name)
        fail!("#{profile_id} #{role} decoded stream exceeds the bound: #{logical_name}") if frames.fetch(:decoded_size) > MAX_RAW_STREAM_BYTES
        label = "decompress_#{role}_#{profile_id}_#{Auditor.stream_hash(logical_name)}"
        invocation = run_process(label, [@binary, 'compressor', '--decompress', '--threads=1'],
                                 compressed, 'clickhouse-compressor', expected_sha: BINARY_SHA256,
                                 binary_path: @binary)
        fail!("#{profile_id} #{role} compressor failed for #{logical_name}") unless
          invocation[:classification] == 'success' && invocation[:status]&.success? &&
          invocation[:status]&.termsig.nil? && invocation[:record][:max_threads] == 1 &&
          invocation[:stderr].empty?
        decoded = invocation.fetch(:stdout)
        fail!("#{profile_id} #{role} decompressed length differs for #{logical_name}") unless
          decoded.bytesize == frames.fetch(:decoded_size) && decoded.bytesize <= MAX_RAW_STREAM_BYTES
        helper_hex = entry.fetch('decoded_hex')
        fail!("#{profile_id} #{role} helper raw witness is malformed for #{logical_name}") unless
          helper_hex.match?(/\A(?:[0-9a-f]{2})*\z/i)
        fail!("#{profile_id} #{role} independently decompressed bytes differ from helper for #{logical_name}") unless
          decoded == [helper_hex].pack('H*') && Digest::SHA256.hexdigest(decoded) == entry.fetch('decoded_sha256')
        {profile_id: profile_id, role: role, stream: logical_name, physical_file: expected_name,
         physical_sha256: physical_sha, decoded_bytes: decoded.bytesize,
         decoded_sha256: Digest::SHA256.hexdigest(decoded), invocation_label: label}
      end
    end

    def assert_nested_type_witnesses!(read, profile, role)
      rows = read.fetch('nested_type_witnesses')
      fail!("#{profile.fetch(:id)} #{role} nested type witness row domain differs") unless
        rows.map { |row| row.fetch('pk') } == ROWS.map { |row| row.fetch(:pk) }
      arr = rows.find { |row| row.fetch('pk') == 1 }.fetch('paths').fetch('arr')
      late = rows.find { |row| row.fetch('pk') == 8 }.fetch('paths').fetch('late')
      [arr, late].each do |witness|
        fail!("#{profile.fetch(:id)} #{role} nested Array(JSON) descriptor is absent") unless
          witness.fetch('outer_type').start_with?('Array(JSON(') || witness.fetch('outer_type') == 'Array(JSON)'
        fail!("#{profile.fetch(:id)} #{role} nested JSON element descriptor is absent") unless
          witness.fetch('element_type').start_with?('JSON(') || witness.fetch('element_type') == 'JSON'
        children = witness.fetch('first_element_child_types')
        expected_children = witness.equal?(arr) ? %w[s v] : %w[late_only_child v]
        fail!("#{profile.fetch(:id)} #{role} nested JSON child type witnesses are incomplete") unless
          children.keys.sort == expected_children
        fail!("#{profile.fetch(:id)} #{role} nested v type witness is absent") if children.fetch('v').empty?
      end
      if role == 'Crystal generated'
        fail!("#{profile.fetch(:id)} generated nested v must be the prepared UInt8 type") unless arr.fetch('first_element_child_types').fetch('v') == 'UInt8' && late.fetch('first_element_child_types').fetch('v') == 'UInt8'
        fail!("#{profile.fetch(:id)} generated dynamic String child witness differs") unless
          arr.fetch('first_element_child_types').fetch('s') == 'String' && late.fetch('first_element_child_types').fetch('late_only_child') == 'String'
      end
      true
    end

    def compare_source_inventory!(expected, observed, profile)
      id = profile.fetch(:id)
      SOURCE_INVENTORY_COMPARE_FIELDS.each do |name|
        fail!("#{id} stock source #{name} differs from its captured inventory") unless
          ProbeObjectSharedJSONInteropW241.inventory_field_equal?(expected, observed, name)
      end
      fail!("#{id} stock source stream file roster/digests differ from its captured inventory") unless
        ProbeObjectSharedJSONInteropW241.source_stream_inventory_equal?(expected, observed)
      true
    end

    def direct_helper_values(rows_by_path, profile)
      {'arr' => rows_by_path.fetch('arr').map { |row| [row.fetch('pk'), row.fetch('value')] },
       'mixed' => rows_by_path.fetch('mixed').map { |row| [row.fetch('pk'), row.fetch('value')] },
       'late' => rows_by_path.fetch('late').map { |row| [row.fetch('pk'), row.fetch('value')] }}
    end

    def expected_direct_values
      {'arr' => ROWS.map { |row| [row.fetch(:pk), row.fetch(:doc).fetch('arr', nil)] },
       'mixed' => ROWS.map { |row| [row.fetch(:pk), row.fetch(:doc).fetch('mixed', nil)] },
       'late' => ROWS.map { |row| [row.fetch(:pk), row.fetch(:doc).fetch('late', nil)] }}
    end

    def authenticate_helper_part!(path, helper_read, profile, role)
      fail!("#{profile.fetch(:id)} #{role} part path is symlinked or absent") unless File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      tree = W185::Probe.allocate
      tree.instance_variable_set(:@root, @root)
      tree.send(:validate_plain_tree!, path)
      reported = helper_read.fetch('physical_file_inventory')
      names = reported.map { |item| item.fetch('name') }.sort
      actual_names = Dir.children(path).sort
      fail!("#{profile.fetch(:id)} #{role} complete file roster differs") unless names == actual_names
      files = {}
      reported.each do |item|
        name = item.fetch('name')
        fail!("#{profile.fetch(:id)} unsafe #{role} basename") unless File.basename(name) == name && name.match?(/\A[a-zA-Z0-9_.-]+\z/)
        file_path = File.join(path, name)
        bytes = File.binread(file_path)
        fail!("#{profile.fetch(:id)} #{role} file digest/size differs: #{name}") unless
          File.size(file_path) == item.fetch('size') && Digest::SHA256.hexdigest(bytes) == item.fetch('sha256')
        files[name] = {size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes)}
      end
      fail!("#{profile.fetch(:id)} generated count.txt differs") unless helper_read.fetch('count_text') == '8'
      serialization = JSON.parse(File.binread(File.join(path, 'serialization.json')))
      expected_string = profile.fetch(:string).fetch(:version)
      fail!("#{profile.fetch(:id)} generated serialization String version differs") unless
        serialization.dig('types_serialization_versions', 'string') == expected_string &&
        serialization['propagate_types_serialization_versions_to_nested_types'] == true
      fail!("#{profile.fetch(:id)} generated columns_substreams bytes differ") unless
        File.binread(File.join(path, 'columns_substreams.txt')) == helper_read.fetch('columns_substreams_text')
      fail!("#{profile.fetch(:id)} generated columns bytes differ") unless
        File.binread(File.join(path, 'columns.txt')) == helper_read.fetch('columns_text')
      ProbeObjectSharedJSONInteropW241.validate_part_columns!(
        helper_read.fetch('columns_text'), profile, role)
      fail!("#{profile.fetch(:id)} generated checksums digest differs") unless
        Digest::SHA256.file(File.join(path, 'checksums.txt')).hexdigest == helper_read.fetch('checksums_sha256')
      substreams = ProbeObjectSharedJSONInteropW241.calibrate_substream_metadata!(
        helper_read.fetch('columns_substreams_text'), profile)
      logical = substreams.fetch(:logical_substreams)
      object_substreams = substreams.fetch(:object_substreams)
      helper_stream_names = helper_read.fetch('physical_stream_names')
      fail!("#{profile.fetch(:id)} helper Object stream roster differs") unless
        helper_stream_names.is_a?(Array) && helper_stream_names == object_substreams.sort
      helper_marks = helper_read.fetch('mark_triples')
      fail!("#{profile.fetch(:id)} helper Object mark roster differs") unless
        helper_marks.is_a?(Hash) && helper_marks.keys.sort == object_substreams.sort
      raw_streams = helper_read.fetch('raw_shared_streams')
      fail!("#{profile.fetch(:id)} helper raw Object stream roster differs") unless
        raw_streams.is_a?(Hash) && raw_streams.keys.sort == object_substreams.sort

      expected_stream_files = logical.flat_map do |stream|
        stem = Auditor.stream_hash(stream)
        ["#{stem}.bin", "#{stem}.mrk2"]
      end.sort
      actual_stream_files = actual_names.select { |name| name.end_with?('.bin', '.mrk2') }.sort
      fail!("#{profile.fetch(:id)} physical stream files differ from the table-wide roster") unless
        actual_stream_files == expected_stream_files

      mark_triples = {'pk' => read_physical_mark_triples!(path, 'pk', profile.fetch(:id))}
      object_substreams.each do |stream|
        triples = read_physical_mark_triples!(path, stream, profile.fetch(:id))
        helper_triples = helper_marks.fetch(stream).map { |triple| triple.map(&:to_i) }
        fail!("#{profile.fetch(:id)} actual mark triples differ for #{stream}") unless triples == helper_triples
        mark_triples[stream] = triples
      end
      {path: path, physical_file_names: actual_names, complete_file_inventory: files,
       logical_substreams: logical, object_substreams: object_substreams,
       columns_substreams_text: helper_read.fetch('columns_substreams_text'),
       columns_text: helper_read.fetch('columns_text'), count_text: '8', serialization_json: serialization,
       serialization_json_sha256: Digest::SHA256.file(File.join(path, 'serialization.json')).hexdigest,
       checksums_sha256: Digest::SHA256.file(File.join(path, 'checksums.txt')).hexdigest,
       ordinary_string_serialization_version: expected_string, mark_triples: mark_triples,
       helper_raw_streams: helper_read.fetch('raw_shared_streams'), bytes: files.values.sum { |entry| entry.fetch(:size) }}
    end

    def read_physical_mark_triples!(path, stream, profile_id)
      mark_name = "#{Auditor.stream_hash(stream)}.mrk2"
      mark_path = File.join(path, mark_name)
      fail!("#{profile_id} mark file is absent or symlinked: #{stream}") unless
        File.file?(mark_path) && !File.symlink?(mark_path)
      size = File.size(mark_path)
      fail!("#{profile_id} mark file exceeds the byte bound: #{stream}") if size > MAX_PART_FILE_BYTES
      bytes = File.binread(mark_path)
      fail!("#{profile_id} mark file changed while reading: #{stream}") unless bytes.bytesize == size
      fail!("#{profile_id} malformed mark triples for #{stream}") unless (bytes.bytesize % 24).zero?
      triples = bytes.unpack('Q<*').each_slice(3).map(&:dup)
      fail!("#{profile_id} physical mark row schedule differs for #{stream}") unless
        triples.map { |triple| triple[2] } == PHYSICAL_MARK_ROWS
      triples
    end

    def audit_physical_part!(path, logical, profile, raw_streams: nil)
      id = profile.fetch(:id)
      layout = profile.fetch(:layout)
      prefix = 'doc.object_shared_data'
      shared = logical.grep(/\A#{Regexp.escape(prefix)}(?:\.|%2E)/)
      buckets = shared.map do |name|
        match = /\A#{Regexp.escape(prefix)}\.(\d+)(?:\.|%2E)/.match(name)
        match && Integer(match[1], 10)
      end.compact.uniq.sort
      mark_path = File.join(path, "#{Auditor.stream_hash('doc.object_structure')}.bin")
      raw_structure = decoded_stream(path, raw_streams, 'doc.object_structure', mark_path)
      header = Auditor.parse_object_header(raw_structure, "#{id} object_structure")
      fail!("#{id} wire shared version differs from requested profile") unless header.fetch(:shared_data_version) == layout.fetch(:enum)
      expected_bucket_count = layout.fetch(:enum) == 0 ? 1 : 2
      fail!("#{id} actual bucket count differs") unless header.fetch(:bucket_count) == expected_bucket_count
      physical = case layout.fetch(:enum)
                 when 0
                   required = ["#{prefix}.size0", "#{prefix}%2Epaths", "#{prefix}%2Evalues"]
                   fail!("#{id} MAP roster differs") unless (required - logical).empty? && buckets.empty? && shared.none? { |name| name.include?('.data') || name.include?('.copy.') }
                   {family: 'map', buckets: [], lanes: required}
                 when 1
                   fail!("#{id} MAP_WITH_BUCKETS does not emit exact buckets 0,1") unless buckets == [0, 1]
                   lanes = [0, 1].flat_map { |bucket| ["#{prefix}.#{bucket}.size0", "#{prefix}.#{bucket}%2Epaths", "#{prefix}.#{bucket}%2Evalues"] }
                   fail!("#{id} bucket lane roster differs") unless (lanes - logical).empty?
                   {family: 'map_with_buckets', buckets: buckets, lanes: lanes}
                 when 2, 3
                   data = [0, 1].map { |bucket| "#{prefix}.#{bucket}.data" }
                   copy = %w[sizes paths_indexes values].map { |lane| "#{prefix}.copy.#{lane}" }
                   fail!("#{id} advanced Data/Copy physical lanes absent") unless (data + copy).all? { |name| logical.include?(name) }
                   chunks = advanced_chunks(id, logical, path, raw_streams, buckets)
                   expected_copy_counts = ROWS.map { |row| row.fetch(:doc).size }
                   copy_sizes = decoded_stream(path, raw_streams, "#{prefix}.copy.sizes", nil).unpack('Q<*')
                   fail!("#{id} Copy per-row size lane differs") unless copy_sizes == expected_copy_counts
                   fail!("#{id} advanced bucket count differs") unless buckets == [0, 1]
                   {family: layout.fetch(:setting), buckets: buckets, data: data, copy: copy,
                    chunks: chunks, copy_sizes_per_row: copy_sizes}
                 else
                   fail!("#{id} unsupported actual version")
                 end
      {header: header, family: physical.fetch(:family), shared_streams: shared.sort,
       bucket_ids: buckets, physical: physical,
       mark_windows: PHYSICAL_MARK_ROWS.each_with_index.map { |rows, index| {mark: index, rows: rows} }}
    end

    def decoded_stream(path, raw_streams, logical_name, _structure_path)
      if raw_streams
        entry = raw_streams.fetch(logical_name) { fail!("missing raw shared stream #{logical_name}") }
        hex = entry.fetch('decoded_hex')
        fail!("malformed decoded stream hex #{logical_name}") unless hex.match?(/\A(?:[0-9a-f]{2})*\z/i)
        [hex].pack('H*')
      else
        file = File.join(path, "#{Auditor.stream_hash(logical_name)}.bin")
        bytes = File.binread(file)
        fail!("#{logical_name} compressed stream empty") if bytes.empty?
        # The helper reports decoded raw bytes; source s0 is stock and the
        # retained W240 inventory authenticates its compressed bytes. For s0,
        # use an isolated stock decompressor only if raw streams are absent.
        raise "#{logical_name} source raw bytes need helper decode"
      end
    end

    def advanced_chunks(id, logical, path, raw_streams, buckets)
      fail!("#{id} source advanced raw schedule is unavailable") unless raw_streams
      chunks_by_bucket = {}
      buckets.each do |bucket|
        base = "doc.object_shared_data.#{bucket}"
        combined = "#{base}.structure"
        prefix = "#{base}.structure_prefix"
        suffix = "#{base}.structure_suffix"
        records = if logical.include?(combined)
                    Auditor::W191.parse_combined_structure(decoded_stream(path, raw_streams, combined, nil), "#{id} #{combined}")
                  elsif logical.include?(prefix)
                    rows = Auditor::W191.parse_chunk_prefixes(decoded_stream(path, raw_streams, prefix, nil), "#{id} #{prefix}")
                    suffix_records = Auditor::W191.parse_suffix_stream(decoded_stream(path, raw_streams, suffix, nil), rows.size, "#{id} #{suffix}")
                    rows.each_with_index.map do |record, index|
                      record.merge(suffix_records.fetch(index))
                    end
                  else
                    fail!("#{id} bucket #{bucket} lacks structure schedule streams")
                  end
        fail!("#{id} bucket #{bucket} actual chunks do not cover eight logical JSON occurrences") unless records.sum { |record| record.fetch(:rows) } == 8
        chunks_by_bucket[bucket.to_s] = records.map { |record| {rows: record.fetch(:rows), paths: record.fetch(:paths)} }
      end
      schedules = chunks_by_bucket.values.map { |records| records.map { |record| record.fetch(:rows) } }
      fail!("#{id} actual advanced chunk row schedules differ by bucket") unless schedules.uniq.size == 1
      fail!("#{id} physical structure omits fixture path roster") unless chunks_by_bucket.values.flatten.flat_map { |chunk| chunk.fetch(:paths) }.uniq.sort == %w[arr label late mixed]
      {chunks_by_bucket: chunks_by_bucket, actual_chunk_count_per_bucket: schedules.first.size,
       observed_rows_per_chunk: schedules.first}
    end

    def qualify_generated_profile!(profile, source, generated)
      id = profile.fetch(:id)
      target = create_and_attach_generated!(profile, generated.fetch(:part_path))
      direct = run_query_stage!("generated_direct_#{id}", File.join(@root, 'stores', 'native'),
                                [pin_sql, direct_query(target.fetch(:table), id)].join("\n"), profile, :direct)
      full = run_query_stage!("generated_full_#{id}", File.join(@root, 'stores', 'native'),
                              [pin_sql, full_query(target.fetch(:table))].join("\n"), profile, :full)
      source_stages = source.fetch(:native_stages)
      source_observations = %w[direct full].all? do |stage|
        record = source_stages[stage] || source_stages[stage.to_sym]
        record && (record['status'] || record[:status]) == 'stage_observed'
      end
      successful = source_observations && target[:attach] &&
        direct.fetch(:status) == 'stage_observed' && full.fetch(:status) == 'stage_observed'
      source_part = source.slice(:path, :origin, :inventory, :native_stages)
      source_part[:physical_layout] = generated.fetch(:source_physical_layout)
      {id: id, status: successful ? 'paired_stock_crystal_observed' : 'capture_incomplete_or_observations_differ',
       shared_version: profile.fetch(:layout).fetch(:enum),
       string_profile: profile.fetch(:string).fetch(:id),
       source_stock_part: source_part,
       native_stream_decodes: {source: generated.fetch(:source_native_stream_decodes),
                               generated: generated.fetch(:generated_native_stream_decodes)},
       source_helper_inventory: generated.fetch(:source_inventory),
       source_helper_physical_layout: generated.fetch(:source_physical_layout),
       crystal_generated_part: {path: generated.fetch(:part_path), inventory: generated.fetch(:inventory),
                                physical_layout: generated.fetch(:physical_layout),
                                helper_writer: generated.fetch(:record).fetch('writer')},
       native_attach_check_schema: target.fetch(:attach),
       native_queries: {direct: direct, full_middle_last_zero: full}}
    rescue StandardError => error
      {id: id, status: 'capture_incomplete_or_observations_differ', error: "#{error.class}: #{error.message}",
       source_stock_part: source.slice(:path, :origin), crystal_generated_part: {path: generated[:part_path]}}
    end

    def create_and_attach_generated!(profile, part_path)
      id = profile.fetch(:id)
      table = table_name(id, 'target')
      store = File.join(@root, 'stores', 'native')
      create_sql = [pin_sql,
        "CREATE TABLE default.#{table} (pk UInt64, doc #{STOCK_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(profile)};",
        "SELECT '__W241_TARGET_PATH__', '#{id}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;"].join("\n") + "\n"
      create = native("target_create_#{id}", store, create_sql)
      assert_native_success!(create, "target create #{id}")
      assert_pin!(create[:stdout], "target create #{id}")
      path_rows = tagged_rows(create[:stdout], '__W241_TARGET_PATH__')
      fail!("#{id} target path query differs") unless path_rows.size == 1 && path_rows[0].size == 3 && path_rows[0][1] == id
      data_path = path_rows[0][2]
      validate_store_path!(data_path)
      attach_part!(part_path, data_path)
      attach_sql = [pin_sql,
        "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';",
        "SELECT '__W241_CHECK_BEGIN__', '#{id}' FORMAT TSVRaw;",
        "CHECK TABLE default.#{table} FORMAT TSV;",
        "SELECT '__W241_CHECK_END__', '#{id}' FORMAT TSVRaw;",
        "SELECT '__W241_SCHEMA__', '#{id}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;",
        "SELECT '__W241_PART__', '#{id}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;"].join("\n") + "\n"
      attached = native("target_attach_check_#{id}", store, attach_sql)
      assert_native_success!(attached, "target attach/CHECK #{id}")
      assert_pin!(attached[:stdout], "target attach/CHECK #{id}")
      verify_attached_output!(attached[:stdout], profile)
      {table: table, attach: {create: create[:record], attach_check: attached[:record], data_path: data_path}}
    end

    def validate_store_path!(path)
      expanded = File.expand_path(path)
      store = File.join(@root, 'stores', 'native')
      fail!("target path escaped isolated store: #{path}") unless expanded.start_with?(store + File::SEPARATOR)
      current = store
      expanded.delete_prefix(store + File::SEPARATOR).split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        next unless File.exist?(current) || File.symlink?(current)
        fail!("symlink in store path #{current}") if File.lstat(current).symlink?
      end
      expanded
    end

    def attach_part!(source, data_path)
      fail!('generated part is absent or symlinked') unless File.directory?(source) && !File.symlink?(source)
      detached = File.join(data_path, 'detached')
      FileUtils.mkdir_p(detached, mode: 0o700) unless File.directory?(detached)
      fail!('detached directory is symlinked') if File.symlink?(detached)
      destination = File.join(detached, 'all_1_1_0')
      fail!('refusing to overwrite detached part') if File.exist?(destination) || File.symlink?(destination)
      FileUtils.cp_r(source, destination, preserve: true)
      tree = W185::Probe.allocate
      tree.send(:validate_plain_tree!, destination)
    end

    def verify_attached_output!(stdout, profile)
      id = profile.fetch(:id)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W241_CHECK_BEGIN__\t")
          active = line.split("\t", -1)[1]
          fail!("#{id} CHECK begin differs") unless active == id
          checks[id] = []
        elsif line.start_with?("__W241_CHECK_END__\t")
          ending = line.split("\t", -1)[1]
          fail!("#{id} CHECK end differs") unless active == ending && ending == id
          active = nil
        elsif active
          checks.fetch(active) << line
        end
      end
      fail!("#{id} attached CHECK differs") unless active.nil? && checks == {id => ["all_1_1_0\t1\t"]}
      schemas = tagged_rows(stdout, '__W241_SCHEMA__')
      fail!("#{id} attached schema differs") unless schemas.map { |row| row.drop(2) } == [['pk', 'UInt64'], ['doc', STOCK_TYPE]]
      parts = tagged_rows(stdout, '__W241_PART__')
      fail!("#{id} attached part identity differs") unless parts.size == 1 && parts[0].values_at(1, 3, 5, 6, 7) == [id, 'all_1_1_0', 'Wide', '8', '5']
    end

    def run_query_stage!(label, store, sql, profile, stage)
      invocation = native(label, store, sql)
      assert_native_success!(invocation, label)
      assert_pin!(invocation[:stdout], label)
      observations = stage == :direct ? assert_direct!(invocation[:stdout], profile) : assert_full!(invocation[:stdout], profile, sql)
      {status: 'stage_observed', invocation: invocation[:record], observations: observations}
    rescue StandardError => error
      {status: 'process_or_observation_failure_inconclusive', error: "#{error.class}: #{error.message}",
       invocation: invocation && invocation[:record]}
    end

    def calibrate_retained_negative_observations!
      profile = PROFILES.find { |entry| entry.fetch(:id) == 'advanced_chunked_s0' }
      fail!('calibration base profile is absent') unless profile
      retained_binary_path!
      source_id = profile.fetch(:id)
      source_table = table_name(source_id, 'source')
      source_direct_sql = [pin_sql, direct_query(source_table, source_id)].join("\n")
      source_direct = retained_invocation!('source_direct_advanced_chunked_s0', source_direct_sql, :success)
      assert_pin!(source_direct.fetch(:stdout), 'retained positive direct')
      assert_direct!(source_direct.fetch(:stdout), profile)
      source_full_sql = [pin_sql, full_query(source_table)].join("\n")
      source_full = retained_invocation!('source_full_advanced_chunked_s0', source_full_sql, :success)
      assert_pin!(source_full.fetch(:stdout), 'retained positive full')
      assert_full!(source_full.fetch(:stdout), profile, source_full_sql)

      data_context = ProbeObjectSharedJSONInteropW241.negative_observation_context!(profile, 'data_corrupt', @token)
      data_direct_sql = [pin_sql, direct_query(data_context.fetch(:table), data_context.fetch(:id))].join("\n")
      data_direct_capture = retained_invocation!('negative_direct_data_corrupt', data_direct_sql, :success)
      assert_pin!(data_direct_capture.fetch(:stdout), 'retained data-corrupt direct')
      data_direct = {status: 'stage_observed',
                     observations: observe_direct!(data_direct_capture.fetch(:stdout), profile, data_context)}
      data_full_sql = [pin_sql, full_query(data_context.fetch(:table))].join("\n")
      data_full_capture = retained_invocation!('negative_full_data_corrupt', data_full_sql, :success)
      assert_pin!(data_full_capture.fetch(:stdout), 'retained data-corrupt full')
      data_full = {status: 'stage_observed',
                   observations: observe_full!(data_full_capture.fetch(:stdout), profile, data_context)}
      assert_negative_effect!('data_corrupt', negative_outcome('data_corrupt', data_direct, data_full))
      reject_nearby_negative_contexts!(profile, data_context, data_direct_capture.fetch(:stdout),
                                       data_full_capture.fetch(:stdout))

      copy_context = ProbeObjectSharedJSONInteropW241.negative_observation_context!(profile, 'copy_truncated', @token)
      copy_attach_capture = retained_invocation!('negative_attach_check_copy_truncated',
        negative_attach_check_sql(copy_context), :success)
      assert_pin!(copy_attach_capture.fetch(:stdout), 'retained Copy-truncation attach/CHECK')
      copy_attached_part_path = verify_negative_attach_output!(copy_attach_capture.fetch(:stdout), profile,
        copy_context)
      copy_direct_sql = [pin_sql, direct_query(copy_context.fetch(:table), copy_context.fetch(:id))].join("\n")
      copy_direct_capture = retained_invocation!('negative_direct_copy_truncated', copy_direct_sql, :success)
      assert_pin!(copy_direct_capture.fetch(:stdout), 'retained Copy-truncation direct')
      copy_direct = {status: 'stage_observed',
                     observations: observe_direct!(copy_direct_capture.fetch(:stdout), profile, copy_context)}
      copy_full_sql = [pin_sql, full_query(copy_context.fetch(:table))].join("\n")
      copy_full_capture = retained_invocation!('negative_full_copy_truncated', copy_full_sql, :server_exception)
      assert_pin!(copy_full_capture.fetch(:stdout), 'retained Copy-truncation full')
      fail!('Copy-truncation failure emitted full rows') unless tagged_rows(copy_full_capture.fetch(:stdout), '__W241_FULL__').empty?
      stderr = copy_full_capture.fetch(:stderr)
      fail!('Copy-truncation failure diagnostic differs') unless
        stderr.include?('Code: 33') && stderr.include?('Cannot read all data')
      calibrate_copy_full_failure_classifier!(copy_full_capture.fetch(:record), copy_full_capture.fetch(:stdout),
        stderr, profile, copy_context, copy_full_sql, copy_attached_part_path)
      copy_full = {status: 'process_failed_observed', stdout: copy_full_capture.fetch(:stdout),
                   stderr: stderr}
      assert_negative_effect!('copy_truncated', negative_outcome('copy_truncated', copy_direct, copy_full))
      reject_nearby_negative_contexts!(profile, copy_context, copy_direct_capture.fetch(:stdout), nil)
      true
    end

    def retained_binary_path!
      path = File.join(@root, 'invocations', 'source_direct_advanced_chunked_s0.json')
      fail!('retained source invocation record is absent or symlinked') unless
        File.file?(path) && !File.symlink?(path) && File.size(path) <= 256 * 1024
      record = JSON.parse(File.binread(path))
      binary = record.fetch('binary_path')
      fail!('retained runtime binary path is not canonical absolute') unless
        binary.is_a?(String) && binary.start_with?(File::SEPARATOR) && File.expand_path(binary) == binary
      @binary = binary
    rescue JSON::ParserError, KeyError, TypeError => error
      fail!("retained runtime binary identity is invalid: #{error.class}: #{error.message}")
    end

    def retained_invocation!(label, expected_sql, expected_outcome)
      directory = File.join(@root, 'invocations')
      fail!('retained invocations directory is absent or symlinked') unless
        File.directory?(directory) && !File.symlink?(directory) && File.realpath(directory) == directory
      record_name = "#{label}.json"
      record_bytes = retained_capture_file!(directory, record_name, 256 * 1024)
      record = JSON.parse(record_bytes)
      fail!("#{label} record label differs") unless record.fetch('label') == label
      argv_name = "#{label}.argv.json"
      stdin_name = "#{label}.stdin.sql"
      stdout_name = "#{label}.stdout"
      stderr_name = "#{label}.stderr"
      fail!("#{label} artifact basenames differ") unless
        [record.fetch('argv_file'), record.fetch('stdin_file'), record.fetch('stdout_file'), record.fetch('stderr_file')] ==
          [argv_name, stdin_name, stdout_name, stderr_name]
      argv_bytes = retained_capture_file!(directory, argv_name, 64 * 1024)
      stdin = retained_capture_file!(directory, stdin_name, 1024 * 1024)
      stdout = retained_capture_file!(directory, stdout_name, 4 * 1024 * 1024)
      stderr = retained_capture_file!(directory, stderr_name, 1024 * 1024)
      argv = record.fetch('argv')
      expected_argv = [@binary, 'local', '--path', File.join(@root, 'stores', 'native'),
                       '--session_timezone=UTC', '--max_threads=1', "--max_memory_usage=#{MEMORY}", '--multiquery']
      fail!("#{label} argv differs") unless argv == expected_argv && argv_bytes == JSON.pretty_generate(argv) + "\n"
      fail!("#{label} argv digest differs") unless record.fetch('argv_sha256') == Digest::SHA256.hexdigest(argv_bytes)
      fail!("#{label} SQL differs") unless stdin == expected_sql.b
      fail!("#{label} SQL byte/hash identity differs") unless
        record.fetch('stdin_bytes') == stdin.bytesize && record.fetch('stdin_sha256') == Digest::SHA256.hexdigest(stdin)
      {stdout: stdout, stderr: stderr}.each do |stream, bytes|
        fail!("#{label} #{stream} byte/hash identity differs") unless
          record.fetch("#{stream}_bytes") == bytes.bytesize && record.fetch("#{stream}_sha256") == Digest::SHA256.hexdigest(bytes)
      end
      fail!("#{label} is not a pinned bounded clickhouse-local invocation") unless
        record.fetch('process_kind') == 'clickhouse-local' && record.fetch('expected_binary_sha256') == BINARY_SHA256 &&
        record.fetch('binary_sha_before') == BINARY_SHA256 && record.fetch('binary_sha_after') == BINARY_SHA256 &&
        record.fetch('binary_path') == @binary && record.fetch('store_path') == File.join(@root, 'stores', 'native') &&
        record.fetch('max_threads') == 1 && record.fetch('max_memory_usage_bytes') == MEMORY &&
        record.fetch('max_memory_usage_applicable') == true &&
        record.fetch('required_outer_run_safe_memory_limit_bytes') == OUTER_RUN_SAFE_LIMIT &&
        record.fetch('timed_out') == false && record.fetch('signal').nil? && record.fetch('spawn_error').nil? &&
        record.fetch('stdin_write_error').nil? && record.fetch('stdout_read_error').nil? && record.fetch('stderr_read_error').nil?
      if expected_outcome == :success
        fail!("#{label} was not successful") unless record.fetch('process_classification') == 'success' && record.fetch('exit') == 0 && stderr.empty?
      else
        fail!("#{label} did not report the pinned truncation exception") unless
          expected_outcome == :server_exception && record.fetch('process_classification') == 'server_exception' &&
          record.fetch('exit') == 33 && stderr.include?('Code: 33') && stderr.include?('Cannot read all data')
      end
      {record: record, stdout: stdout, stderr: stderr}
    rescue JSON::ParserError, KeyError, TypeError => error
      fail!("#{label} retained invocation envelope is invalid: #{error.class}: #{error.message}")
    end

    def retained_capture_file!(directory, name, max_bytes)
      fail!('retained artifact name is unsafe') unless File.basename(name) == name && !name.include?('..')
      path = File.join(directory, name)
      fail!("retained artifact is absent, symlinked, or non-regular: #{name}") unless
        File.file?(path) && !File.symlink?(path) && File.size(path) <= max_bytes
      File.binread(path)
    end

    def assert_negative_effect!(kind, outcome)
      fail!("retained #{kind} outcome is not the targeted observed effect") unless
        outcome.fetch(:status) == 'negative_control_observed'
    end

    def reject_nearby_negative_contexts!(profile, context, direct_stdout, full_stdout)
      wrong_id = context.merge(id: "#{context.fetch(:id)}_nearby")
      expect_context_rejection!('nearby negative id') do
        observe_direct!(direct_stdout, profile, wrong_id)
      end
      wrong_table = context.merge(table: "#{context.fetch(:table)}_nearby")
      expect_context_rejection!('nearby negative table') do
        if full_stdout
          observe_full!(full_stdout, profile, wrong_table)
        else
          observe_direct!(direct_stdout, profile, wrong_table)
        end
      end
      true
    end

    def expect_context_rejection!(label)
      yield
      fail!("#{label} mutation was admitted")
    rescue ProbeObjectSharedJSONInteropW241::PartSchemaError
      true
    end

    def assert_pin!(stdout, label)
      pins = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).select { |line| line.start_with?("__W241_PIN__\t") }
      fail!("#{label} did not emit exactly one runtime pin") unless pins == ["__W241_PIN__\t#{VERSION}\t#{BUILD}"]
    end

    def tagged_rows(stdout, tag)
      stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).select { |line| line.start_with?("#{tag}\t") }
        .map { |line| line.split("\t", -1) }
    end

    def parse_hex_json(value, label)
      fail!("#{label} malformed hex JSON") unless value.match?(/\A(?:[0-9a-f]{2})*\z/i)
      JSON.parse([value].pack('H*'))
    rescue JSON::ParserError => error
      fail!("#{label} invalid JSON: #{error.message}")
    end

    def assert_direct!(stdout, profile)
      id = profile.fetch(:id)
      rows = tagged_rows(stdout, '__W241_DIRECT__')
      fail!("#{id} direct SELECT must emit eight rows") unless rows.size == ROWS.size
      actual = {}
      rows.each do |fields|
        fail!("#{id} direct row width/profile differs") unless fields.size == 12 && fields[1] == id
        pk = Integer(fields[2], 10)
        expected = ROWS.find { |row| row.fetch(:pk) == pk } || fail!("#{id} direct pk is unrostered")
        arr = parse_hex_json(fields[5], "#{id} direct arr pk #{pk}")
        mixed = parse_hex_json(fields[8], "#{id} direct mixed pk #{pk}")
        late = parse_hex_json(fields[11], "#{id} direct late pk #{pk}")
        doc = expected.fetch(:doc)
        fail!("#{id} direct JSON values differ at pk #{pk}") unless [arr, mixed, late] == [doc.fetch('arr', nil), doc.fetch('mixed', nil), doc.fetch('late', nil)]
        if doc.key?('arr') && doc.fetch('arr').empty?
          fail!("#{id} empty Array(JSON) carrier differs") unless fields[4] == 'Array(Nullable(String))'
        elsif doc.key?('arr')
          fail!("#{id} nonempty Array(JSON) type differs") unless array_json_type?(fields[4])
        else
          fail!("#{id} absent arr not NULL") unless fields[4] == 'NULL'
        end
        fail!("#{id} mixed runtime witness absent") unless doc.key?('mixed') ? (!fields[7].empty? && fields[7] != 'NULL') : fields[7] == 'NULL'
        fail!("#{id} late path type differs") unless doc.key?('late') ? array_json_type?(fields[10]) : fields[10] == 'NULL'
        actual[pk] = {arr_type: fields[4], arr_value: arr, mixed_type: fields[7], mixed_value: mixed,
                      late_type: fields[10], late_value: late}
      end
      fail!("#{id} direct pk set differs") unless actual.keys.sort == ROWS.map { |row| row.fetch(:pk) }
      {rows_by_pk: actual, selection_semantics: profile.fetch(:layout).fetch(:enum) < 2 ? 'bounded_selected_shared_lane' : 'selected_path_data'}
    end

    def assert_full!(stdout, profile, sql)
      id = profile.fetch(:id)
      full_rows = tagged_rows(stdout, '__W241_FULL__')
      middle_rows = tagged_rows(stdout, '__W241_MIDDLE__')
      last_rows = tagged_rows(stdout, '__W241_LAST__')
      zero_rows = tagged_rows(stdout, '__W241_ZERO_QUERY__')
      fail!("#{id} full/middle/last/zero row domains differ") unless
        full_rows.size == 8 && middle_rows.size == 4 && last_rows.size == 1 && zero_rows.size == 1
      zero_sql = sql.lines.find { |line| line.include?("'__W241_ZERO_QUERY__'") }
      full_table = full_rows.first.fetch(1)
      fail!("#{id} empty-selection SQL predicate differs") unless
        zero_sql && zero_sql.include?("FROM default.#{full_table} WHERE pk > 8 SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw")
      full = assert_full_rows!(full_rows, id, ROWS.map { |row| row.fetch(:pk) })
      middle = assert_full_rows!(middle_rows, id, [3, 4, 5, 6])
      last = assert_full_rows!(last_rows, id, [8])
      zero = zero_rows.first
      fail!("#{id} zero-query row width/count differs") unless zero.size == 3 && zero[1] == '0'
      group_array = parse_hex_json(zero[2], "#{id} empty-selection groupArray(doc)")
      fail!("#{id} empty-selection groupArray(doc) is not empty") unless group_array == []
      {full: full, middle: middle, last: last,
       zero_query: {count: 0, group_array: group_array,
                    interpretation: 'empty SQL selection; not evidence of terminal-mark traversal'}}
    end

    def assert_full_rows!(rows, id, expected_pks)
      actual = {}
      rows.each do |fields|
        fail!("#{id} full row width/profile differs") unless fields.size == 7
        table = fields[1]
        # Full tags carry the native table name to prevent one table's rows
        # from being substituted for another profile.
        fail!("#{id} full row table id differs") unless table == table_name(id, 'source') || table == table_name(id, 'target') || table.start_with?("w241_#{@token}_#{id}_negative")
        pk = Integer(fields[2], 10)
        expected = ROWS.find { |row| row.fetch(:pk) == pk } || fail!("#{id} full pk is unrostered")
        document = parse_hex_json(fields[4], "#{id} full doc pk #{pk}")
        dynamics = parse_hex_json(fields[5], "#{id} dynamic paths pk #{pk}")
        shared = parse_hex_json(fields[6], "#{id} shared paths pk #{pk}")
        fail!("#{id} full doc/path roster differs at pk #{pk}") unless document == expected.fetch(:doc) && dynamics == [] && shared.sort == expected.fetch(:doc).keys.sort
        fail!("#{id} full Object expression type is absent") unless fields[3].include?('JSON')
        actual[pk] = {type: fields[3], document: document, dynamic_paths: dynamics, shared_paths: shared}
      end
      fail!("#{id} full row pk domain differs") unless actual.keys.sort == expected_pks
      actual
    end

    def array_json_type?(type)
      type == 'Array(JSON)' || /\AArray\(JSON\(.*\)\)\z/.match?(type)
    end

    def validate_store_path!(path)
      expanded = File.expand_path(path)
      store = File.join(@root, 'stores', 'native')
      fail!("reported ClickHouse path escaped isolated store: #{path}") unless expanded.start_with?(store + File::SEPARATOR)
      expanded
    end

    def qualify_negative_controls!(helper)
      data = helper.fetch(:data).fetch('negative_controls')
      controls = []
      original = File.join(helper.fetch(:output_root), 'advanced_chunked_s0', 'all_1_1_0')
      original_read = helper.fetch(:data).fetch('profiles').find { |item| item.fetch('id') == 'advanced_chunked_s0' }.fetch('generated_read')
      original_inventory = authenticate_helper_part!(original, original_read,
        PROFILES.find { |entry| entry.fetch(:id) == 'advanced_chunked_s0' }, 'Crystal generated negative-control baseline')
      {
        'data_corrupt' => [data.fetch('data_corrupt_part'), data.fetch('data_corrupt_inventory')],
        'copy_truncated' => [data.fetch('copy_truncated_part'), data.fetch('copy_truncated_inventory')],
      }.each do |kind, part_path|
        part_path, negative_inventory = part_path
        profile = PROFILES.find { |entry| entry.fetch(:id) == 'advanced_chunked_s0' }
        context = ProbeObjectSharedJSONInteropW241.negative_observation_context!(profile, kind, @token)
        id = context.fetch(:id)
        negative_part = authenticate_negative_helper_part!(part_path, negative_inventory, kind, original_inventory)
        native_stream_decodes = capture_native_stream_decodes!("advanced_chunked_s0_negative_#{kind}",
          "negative_#{kind}", part_path, negative_part.fetch(:raw_shared_streams))
        table = context.fetch(:table)
        store = File.join(@root, 'stores', 'native')
        create = native("negative_create_#{kind}", store, [pin_sql,
          "CREATE TABLE default.#{table} (pk UInt64, doc #{STOCK_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(profile)};",
          "SELECT '__W241_TARGET_PATH__', '#{id}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;"].join("\n") + "\n")
        assert_native_success!(create, "negative create #{kind}")
        assert_pin!(create[:stdout], "negative create #{kind}")
        path_rows = tagged_rows(create[:stdout], '__W241_TARGET_PATH__')
        fail!("negative #{kind} target path identity differs") unless
          path_rows.size == 1 && path_rows[0].size == 3 && path_rows[0][1] == id
        target_path = validate_store_path!(path_rows[0][2])
        attach_part!(part_path, target_path)
        attach = native("negative_attach_check_#{kind}", store, negative_attach_check_sql(context))
        attach_status = attach[:classification] == 'success' && attach[:status]&.success?
        if attach_status
          assert_pin!(attach[:stdout], "negative attach #{kind}")
          attached_part_path = verify_negative_attach_output!(attach[:stdout], profile, context, target_path)
          direct = run_negative_query_stage!("negative_direct_#{kind}", store,
                                             [pin_sql, direct_query(table, id)].join("\n"), profile, :direct, context,
                                             attached_part_path: attached_part_path)
          full = run_negative_query_stage!("negative_full_#{kind}", store,
                                           [pin_sql, full_query(table)].join("\n"), profile, :full, context,
                                           attached_part_path: attached_part_path)
        else
          direct = {status: 'not_run_attach_or_CHECK_failure_inconclusive'}
          full = {status: 'not_run_attach_or_CHECK_failure_inconclusive'}
        end
        outcome = negative_outcome(kind, direct, full)
        controls << {kind: kind, status: outcome.fetch(:status), observed_effect: outcome.fetch(:effect),
                     part_path: part_path, part_inventory: negative_part,
                     native_stream_decodes: native_stream_decodes,
                     attach_invocation: attach[:record],
                     attach_process_classification: attach[:classification], direct: direct, full: full,
                     interpretation: outcome.fetch(:interpretation)}
      end
      controls
    end

    def authenticate_negative_helper_part!(path, reported, kind, original)
      fail!("#{kind} negative part is absent or symlinked") unless File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      tree = W185::Probe.allocate
      tree.instance_variable_set(:@root, @root)
      tree.send(:validate_plain_tree!, path)
      files = reported.fetch('physical_file_inventory')
      names = files.map { |item| item.fetch('name') }.sort
      fail!("#{kind} negative file roster differs") unless names == Dir.children(path).sort
      inventory = {}
      files.each do |entry|
        name = entry.fetch('name')
        fail!("#{kind} negative unsafe file name") unless File.basename(name) == name && name.match?(/\A[a-zA-Z0-9_.-]+\z/)
        bytes = File.binread(File.join(path, name))
        fail!("#{kind} negative file bytes differ: #{name}") unless
          bytes.bytesize == entry.fetch('size') && Digest::SHA256.hexdigest(bytes) == entry.fetch('sha256')
        inventory[name] = {size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes)}
      end
      profile = PROFILES.find { |candidate| candidate.fetch(:id) == 'advanced_chunked_s0' }
      fail!("#{kind} negative calibration profile is absent") unless profile
      negative_substreams_text = reported.fetch('columns_substreams_text')
      fail!("#{kind} negative columns_substreams bytes differ") unless
        File.binread(File.join(path, 'columns_substreams.txt')) == negative_substreams_text
      ProbeObjectSharedJSONInteropW241.validate_part_columns!(
        File.binread(File.join(path, 'columns.txt')), profile, 'negative part')
      substreams = ProbeObjectSharedJSONInteropW241.calibrate_substream_metadata!(
        negative_substreams_text, profile)
      logical = substreams.fetch(:logical_substreams)
      object_substreams = substreams.fetch(:object_substreams)
      fail!("#{kind} negative table-wide stream roster differs") unless
        logical == reported.fetch('physical_stream_names')
      expected_stream_files = logical.flat_map do |stream|
        stem = Auditor.stream_hash(stream)
        ["#{stem}.bin", "#{stem}.mrk2"]
      end.sort
      actual_stream_files = names.select { |name| name.end_with?('.bin', '.mrk2') }.sort
      fail!("#{kind} negative physical stream files differ from metadata") unless
        actual_stream_files == expected_stream_files
      read_physical_mark_triples!(path, 'pk', "#{kind} negative")
      raw = reported.fetch('raw_shared_streams')
      fail!("#{kind} negative raw Object roster differs") unless
        raw.is_a?(Hash) && raw.keys.sort == object_substreams.sort
      %w[doc.object_shared_data.0.data doc.object_shared_data.copy.values].each do |stream|
        entry = raw.fetch(stream)
        expected_physical = "#{Auditor.stream_hash(stream)}.bin"
        fail!("#{kind} negative raw stream file identity differs") unless entry.fetch('physical_file') == expected_physical
        physical = inventory.fetch(expected_physical)
        fail!("#{kind} negative raw stream file digest differs") unless physical.fetch(:sha256) == entry.fetch('physical_sha256')
      end
      data_name = "#{Auditor.stream_hash('doc.object_shared_data.0.data')}.bin"
      copy_name = "#{Auditor.stream_hash('doc.object_shared_data.copy.values')}.bin"
      if kind == 'data_corrupt'
        fail!('data corruption did not preserve ordinary Copy') unless inventory.fetch(copy_name) == original.fetch(:complete_file_inventory).fetch(copy_name)
        fail!('data corruption did not change ordinary Data') if inventory.fetch(data_name) == original.fetch(:complete_file_inventory).fetch(data_name)
      else
        fail!('Copy truncation changed ordinary Data') unless inventory.fetch(data_name) == original.fetch(:complete_file_inventory).fetch(data_name)
        fail!('Copy truncation did not change ordinary Copy') if inventory.fetch(copy_name) == original.fetch(:complete_file_inventory).fetch(copy_name)
      end
      {path: path, physical_file_names: names, complete_file_inventory: inventory,
       logical_substreams: logical, object_substreams: object_substreams, raw_shared_streams: raw,
       source_kind: reported.fetch('kind', kind)}
    end

    def run_negative_query_stage!(label, store, sql, profile, stage, context, attached_part_path: nil)
      context = ProbeObjectSharedJSONInteropW241.validate_negative_observation_context!(profile, context, @token)
      expected_query = stage == :direct ? direct_query(context.fetch(:table), context.fetch(:id)) :
        full_query(context.fetch(:table))
      fail!("#{context.fetch(:id)} negative query stage is unrostered") unless [:direct, :full].include?(stage)
      fail!("#{context.fetch(:id)} negative SQL identity differs") unless
        sql == [pin_sql, expected_query].join("\n")
      invocation = native(label, store, sql)
      if invocation[:classification] == 'success' && invocation[:status]&.success?
        assert_pin!(invocation[:stdout], label)
        observations = stage == :direct ? observe_direct!(invocation[:stdout], profile, context) :
          observe_full!(invocation[:stdout], profile, context)
        {status: 'stage_observed', invocation: invocation[:record], observations: observations}
      else
        status = if stage == :full && context.fetch(:kind) == 'copy_truncated' &&
                    copy_full_failure_observed?(invocation[:record], invocation[:stdout], invocation[:stderr],
                      profile, context, stage, sql, attached_part_path: attached_part_path)
                   'process_failed_observed'
                 else
                   'process_or_observation_failure_inconclusive'
                 end
        {status: status, invocation: invocation[:record], stdout: invocation[:stdout], stderr: invocation[:stderr]}
      end
    rescue StandardError => error
      {status: 'process_or_observation_failure_inconclusive', error: "#{error.class}: #{error.message}",
       invocation: invocation && invocation[:record]}
    end

    def negative_attach_check_sql(context)
      context = ProbeObjectSharedJSONInteropW241.validate_negative_observation_context!(
        PROFILES.find { |profile| profile.fetch(:id) == context.fetch(:profile_id) }, context, @token)
      id = context.fetch(:id)
      table = context.fetch(:table)
      [pin_sql,
       "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';",
       "SELECT '__W241_CHECK_BEGIN__', '#{id}' FORMAT TSVRaw;",
       "CHECK TABLE default.#{table} FORMAT TSV;",
       "SELECT '__W241_CHECK_END__', '#{id}' FORMAT TSVRaw;",
       "SELECT '__W241_SCHEMA__', '#{id}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;",
       "SELECT '__W241_PART__', '#{id}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;"].join("\n") + "\n"
    end

    def copy_full_failure_observed?(record, stdout, stderr, profile, context, stage, sql, attached_part_path:)
      context = ProbeObjectSharedJSONInteropW241.validate_negative_observation_context!(profile, context, @token)
      return false unless context.fetch(:kind) == 'copy_truncated' && stage == :full
      return false unless sql == [pin_sql, full_query(context.fetch(:table))].join("\n")
      return false unless attached_part_path.is_a?(String) && File.basename(attached_part_path) == 'all_1_1_0' &&
                          File.directory?(attached_part_path) && !File.symlink?(attached_part_path) &&
                          File.realpath(attached_part_path) == attached_part_path &&
                          validate_store_path!(attached_part_path) == attached_part_path

      fields = %w[
        process_kind process_classification exit signal timed_out spawn_error stdin_write_error
        stdout_read_error stderr_read_error binary_path expected_binary_sha256 binary_sha_before binary_sha_after
        store_path max_threads max_memory_usage_bytes max_memory_usage_applicable
        required_outer_run_safe_memory_limit_bytes timeout_seconds termination_grace_seconds argv
        stdin_bytes stdin_sha256 stdout_bytes stdout_sha256 stderr_bytes stderr_sha256
      ].each_with_object({}) do |name, result|
        found, value = exact_invocation_field(record, name)
        return false unless found
        result[name] = value
      end
      store = File.join(@root, 'stores', 'native')
      expected_argv = [@binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
                       "--max_memory_usage=#{MEMORY}", '--multiquery']
      return false unless fields['process_kind'] == 'clickhouse-local' &&
                          fields['process_classification'] == 'server_exception' && fields['exit'] == 33 &&
                          fields['signal'].nil? && fields['timed_out'] == false &&
                          %w[spawn_error stdin_write_error stdout_read_error stderr_read_error].all? { |key| fields[key].nil? } &&
                          fields['binary_path'] == @binary && fields['expected_binary_sha256'] == BINARY_SHA256 &&
                          fields['binary_sha_before'] == BINARY_SHA256 && fields['binary_sha_after'] == BINARY_SHA256 &&
                          fields['store_path'] == store && fields['max_threads'] == 1 &&
                          fields['max_memory_usage_bytes'] == MEMORY && fields['max_memory_usage_applicable'] == true &&
                          fields['required_outer_run_safe_memory_limit_bytes'] == OUTER_RUN_SAFE_LIMIT &&
                          fields['timeout_seconds'] == TIMEOUT && fields['termination_grace_seconds'] == GRACE &&
                          fields['argv'] == expected_argv &&
                          fields['stdin_bytes'] == sql.bytesize && fields['stdin_sha256'] == Digest::SHA256.hexdigest(sql.b) &&
                          fields['stdout_bytes'] == stdout.bytesize && fields['stdout_sha256'] == Digest::SHA256.hexdigest(stdout.b) &&
                          fields['stderr_bytes'] == stderr.bytesize && fields['stderr_sha256'] == Digest::SHA256.hexdigest(stderr.b)

      expected_pin = "__W241_PIN__\t#{VERSION}\t#{BUILD}"
      return false unless stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp) == [expected_pin]
      return false unless stderr.include?('Code: 33.') && stderr.include?('Cannot read all data') &&
                          stderr.include?('(CANNOT_READ_ALL_DATA)') && stderr.include?('(while reading column doc)') &&
                          stderr.include?("from part #{attached_part_path}#{File::SEPARATOR} in table default.#{context.fetch(:table)} (") &&
                          stderr.include?('from mark 3')
      true
    rescue StandardError
      false
    end

    def exact_invocation_field(record, name)
      return [false, nil] unless record.is_a?(Hash)
      symbol_key = name.to_sym
      has_symbol = record.key?(symbol_key)
      has_string = record.key?(name)
      return [false, nil] unless has_symbol ^ has_string
      [true, record.fetch(has_symbol ? symbol_key : name)]
    end

    def calibrate_copy_full_failure_classifier!(record, stdout, stderr, profile, context, sql, attached_part_path)
      require_copy_failure_classifier!(record, stdout, stderr, profile, context, :full, sql,
        attached_part_path, 'captured Copy read error')

      mutations = {
        timeout: {timed_out: true, process_classification: 'timeout'},
        spawn: {spawn_error: 'synthetic spawn failure', process_classification: 'spawn_error'},
        signal: {signal: 9},
        other_server_code: {exit: 32},
        stdin_io_error: {stdin_write_error: 'synthetic write failure'},
        stdout_io_error: {stdout_read_error: 'synthetic read failure'},
        stderr_io_error: {stderr_read_error: 'synthetic read failure'},
      }
      mutations.each do |label, changes|
        mutated = mutate_invocation_record(record, changes)
        reject_copy_failure_classifier!(mutated, stdout, stderr, profile, context, :full, sql,
          attached_part_path, label.to_s)
      end
      reject_copy_failure_classifier!(record, stdout, stderr, profile, context, :full,
        full_query(context.fetch(:table) + '_nearby'), attached_part_path, 'wrong table SQL')
      reject_copy_failure_classifier!(record, stdout, stderr, profile, context, :full, sql,
        "#{attached_part_path}_nearby", 'wrong attached part')
      pinless = stdout.lines.reject { |line| line.start_with?("__W241_PIN__\t") }.join
      reject_copy_failure_classifier!(record, pinless, stderr, profile, context, :full, sql,
        attached_part_path, 'missing runtime pin')
      direct_context = ProbeObjectSharedJSONInteropW241.negative_observation_context!(profile, 'data_corrupt', @token)
      reject_copy_failure_classifier!(record, stdout, stderr, profile, direct_context, :full,
        [pin_sql, full_query(direct_context.fetch(:table))].join("\n"), attached_part_path, 'wrong negative kind/table')
      reject_copy_failure_classifier!(record, stdout, stderr, profile, context, :direct, sql,
        attached_part_path, 'direct-stage failure')
      true
    end

    def require_copy_failure_classifier!(record, stdout, stderr, profile, context, stage, sql, attached_part_path, label)
      fail!("#{label} was not recognized as the scoped Copy failure") unless
        copy_full_failure_observed?(record, stdout, stderr, profile, context, stage, sql,
          attached_part_path: attached_part_path)
    end

    def reject_copy_failure_classifier!(record, stdout, stderr, profile, context, stage, sql, attached_part_path, label)
      fail!("#{label} mutation was accepted as the scoped Copy failure") if
        copy_full_failure_observed?(record, stdout, stderr, profile, context, stage, sql,
          attached_part_path: attached_part_path)
    end

    def mutate_invocation_record(record, changes)
      mutated = record.dup
      changes.each do |name, value|
        string_key = name.to_s
        symbol_key = name.to_sym
        has_string = mutated.key?(string_key)
        has_symbol = mutated.key?(symbol_key)
        fail!("cannot calibrate absent/ambiguous invocation field #{name}") unless has_string ^ has_symbol
        mutated[has_symbol ? symbol_key : string_key] = value
      end
      mutated
    end

    def verify_negative_attach_output!(stdout, profile, context, target_path = nil)
      context = ProbeObjectSharedJSONInteropW241.validate_negative_observation_context!(profile, context, @token)
      id = context.fetch(:id)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W241_CHECK_BEGIN__\t")
          fields = line.split("\t", -1)
          fail!("#{id} negative CHECK begin differs") unless fields == ['__W241_CHECK_BEGIN__', id] && active.nil?
          active = id
          checks[id] = []
        elsif line.start_with?("__W241_CHECK_END__\t")
          fields = line.split("\t", -1)
          fail!("#{id} negative CHECK end differs") unless fields == ['__W241_CHECK_END__', id] && active == id
          active = nil
        elsif active
          checks.fetch(active) << line
        end
      end
      fail!("#{id} negative native CHECK differs") unless active.nil? && checks == {id => ["all_1_1_0\t1\t"]}
      schemas = tagged_rows(stdout, '__W241_SCHEMA__')
      fail!("#{id} negative attached schema differs") unless schemas == [
        ['__W241_SCHEMA__', id, 'pk', 'UInt64'], ['__W241_SCHEMA__', id, 'doc', STOCK_TYPE],
      ]
      parts = tagged_rows(stdout, '__W241_PART__')
      fail!("#{id} negative attached part row differs") unless parts.size == 1 && parts[0].size == 8
      row = parts[0]
      fail!("#{id} negative attached part identity differs") unless
        row.values_at(1, 2, 3, 5, 6, 7) == [id, context.fetch(:table), 'all_1_1_0', 'Wide', '8', '5']
      part_path = validate_store_path!(row.fetch(4))
      fail!("#{id} negative attached part path is not the selected target part") unless
        File.basename(part_path) == 'all_1_1_0' && File.directory?(part_path) && !File.symlink?(part_path) &&
        (!target_path || part_path == File.join(target_path, 'all_1_1_0'))
      part_path
    end

    def negative_outcome(kind, direct, full)
      expected_docs = ROWS.each_with_object({}) { |row, result| result[row.fetch(:pk)] = row.fetch(:doc) }
      if kind == 'data_corrupt'
        return {status: 'inconclusive', effect: 'attach_or_direct_or_full_not_observed',
                interpretation: 'No conclusion: attach/CHECK or separate direct/full query did not complete.'} unless
          direct.fetch(:status) == 'stage_observed' && full.fetch(:status) == 'stage_observed'
        direct_rows = direct.fetch(:observations).fetch(:rows_by_pk)
        full_docs = full.fetch(:observations).fetch(:full_docs_by_pk)
        direct_expected_except_late = expected_docs.all? do |pk, doc|
          observed = direct_rows.fetch(pk)
          observed.fetch(:arr) == doc.fetch('arr', nil) && observed.fetch(:mixed) == doc.fetch('mixed', nil) &&
            (pk == 8 || observed.fetch(:late) == doc.fetch('late', nil))
        end
        late = direct_rows.fetch(8).fetch(:late)
        expected_late = [{'v' => 80, 'late_only_child' => 'last-chunk-onlz'}]
        full_copy_unchanged = full_docs == expected_docs
        observed = direct_expected_except_late && late == expected_late && full_copy_unchanged
        {status: observed ? 'negative_control_observed' : 'inconclusive',
         effect: observed ? 'advanced Data late-only payload changed; direct arr/mixed and full Copy stayed original' :
           'negative did not produce the targeted Data-only discriminator',
         interpretation: 'A scoped Data/Copy discriminator only: changed late Data at pk 8 with unchanged arr/mixed and full Object confirms Copy stayed independent for this fixture.'}
      else
        return {status: 'inconclusive', effect: 'attach_or_direct_not_observed',
                interpretation: 'No conclusion: attach/CHECK or direct-only query did not complete.'} unless
          direct.fetch(:status) == 'stage_observed'
        direct_rows = direct.fetch(:observations).fetch(:rows_by_pk)
        direct_unchanged = expected_docs.all? do |pk, doc|
          row = direct_rows.fetch(pk)
          row.fetch(:arr) == doc.fetch('arr', nil) && row.fetch(:mixed) == doc.fetch('mixed', nil) &&
            row.fetch(:late) == doc.fetch('late', nil)
        end
        full_bad = full.fetch(:status) == 'process_failed_observed'
        observed = direct_unchanged && full_bad
        {status: observed ? 'negative_control_observed' : 'inconclusive',
         effect: observed ? 'direct Data unchanged; full Copy was unreadable or differed' :
           'Copy truncation did not yield a direct-versus-full discriminator',
         interpretation: 'A scoped Copy-consumption discriminator: direct Data stays original while whole-Object Copy consumption must fail or differ.'}
      end
    end

    def observe_direct!(stdout, profile, context)
      context = ProbeObjectSharedJSONInteropW241.validate_negative_observation_context!(profile, context, @token)
      id = context.fetch(:id)
      rows = tagged_rows(stdout, '__W241_DIRECT__')
      fail!("#{id} negative direct row count differs") unless rows.size == ROWS.size
      observed = {}
      rows.each do |fields|
        fail!("#{id} negative direct row width differs") unless fields.size == 12 && fields[1] == id
        pk = Integer(fields[2], 10)
        observed[pk] = {
          arr: parse_hex_json(fields[5], "#{id} negative arr pk #{pk}"),
          mixed: parse_hex_json(fields[8], "#{id} negative mixed pk #{pk}"),
          late: parse_hex_json(fields[11], "#{id} negative late pk #{pk}"),
          arr_type: fields[4], mixed_type: fields[7], late_type: fields[10],
        }
      end
      fail!("#{id} negative direct pk domain differs") unless observed.keys.sort == ROWS.map { |row| row.fetch(:pk) }
      {rows_by_pk: observed}
    end

    def observe_full!(stdout, profile, context)
      context = ProbeObjectSharedJSONInteropW241.validate_negative_observation_context!(profile, context, @token)
      id = context.fetch(:id)
      rows = tagged_rows(stdout, '__W241_FULL__')
      return {full_rows: 0, query_error_output: stdout} if rows.empty?
      fail!("#{id} negative full row count differs") unless rows.size == ROWS.size
      observed = {}
      rows.each do |fields|
        fail!("#{id} negative full width differs") unless fields.size == 7 && fields[1] == context.fetch(:table)
        pk = Integer(fields[2], 10)
        observed[pk] = parse_hex_json(fields[4], "#{id} negative full pk #{pk}")
      end
      {full_docs_by_pk: observed}
    end

    def render_summary(summary)
      [
        '# W241 paired shared-JSON interoperability capture', '',
        "Status: `#{summary.fetch(:status)}`", '',
        'Eight profiles cover MAP, MAP_WITH_BUCKETS, ADVANCED, and ADVANCED_CHUNKED with ordinary String s0/s1. s1 sources are reused only after W240 source-authentication; s0 sources are created in this isolated local store.', '',
        'Crystal reads stock source parts with separate selected-path and full-Object readers. Crystal-generated parts are independently inventoried, attached and CHECKed by stock ClickHouse, then queried through separate fresh direct-only and full/middle/last/empty-selection processes.', '',
        'The native pk=8 query is labeled last-row, not EOF. A zero-row aggregate with pk>8 records count=0 and groupArray(doc)=[]; this is an empty SQL selection, not evidence that native decoding traversed the physical terminal mark.', '',
        'MAP direct reads are labeled bounded selected shared lanes, not physical selective Data reads. Advanced path stages query Data without Copy; full reads use Copy. The stock fixture carries inferred Array(JSON); only generated child descriptors claim explicit typed v UInt8 and dynamic String child plans.', '',
        'The Crystal read API exposes four real marks. The fifth zero-row .mrk2 tuple is a separately checked physical sentinel, not a selectable row mark. Bounded library reads cover middle, last, empty interior, and zero-count-at-end ranges; the EOF sentinel itself is not claimed as traversed by a row reader.', '',
        'All invocations retain argv, SQL or helper input, stdout, stderr, exit/signal/timeout status, and pinned binary identity. Failures remain inconclusive; negative controls are reported only from observed process/output evidence.', '',
        "Evidence root: `#{@root}`", '',
      ].join("\n")
    end

    def write_failure_summary
      return unless @root && File.directory?(@root)
      data = {format: FORMAT_CAPTURE, status: 'runner_failure_inconclusive', fatal_error: @fatal_error,
              requested_frame_bytes: @frame_bytes,
              runtime: {path: @binary, sha256: BINARY_SHA256, sha256_before: @sha_before, sha256_after: @sha_after},
              profiles: @profiles, invocations: @invocations, evidence_root: @root}
      path = File.join(@root, 'summary.json')
      return if File.exist?(path)
      write_new(path, JSON.pretty_generate(data) + "\n")
    end
  end
end

def main
  options = {binary: ProbeObjectSharedJSONInteropW241::BINARY,
             frame_bytes: ProbeObjectSharedJSONInteropW241::DEFAULT_FRAME_BYTES}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_object_shared_json_interop_w241.rb --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP --crystal-helper EXECUTABLE [--clickhouse CLICKHOUSE] [--frame-bytes 32|64]'
    parser.on('--clickhouse PATH') { |value| options[:binary] = value }
    parser.on('--crystal-helper PATH') { |value| options[:crystal_helper] = value }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    parser.on('--frame-bytes N', Integer) { |value| options[:frame_bytes] = value }
  end.parse!
  raise 'evidence root is required via --evidence-root' unless options[:evidence_root]
  raise 'prebuilt Crystal helper is required via --crystal-helper' unless options[:crystal_helper]
  unless ProbeObjectSharedJSONInteropW241::FRAME_BYTES_OPTIONS.include?(options[:frame_bytes])
    warn '--frame-bytes must be exactly 32 or 64'
    exit 64
  end
  exit(ProbeObjectSharedJSONInteropW241::Probe.new(options[:binary], options[:crystal_helper], options[:evidence_root], options[:frame_bytes]).run ? 0 : 1)
end

main if $PROGRAM_NAME == __FILE__
