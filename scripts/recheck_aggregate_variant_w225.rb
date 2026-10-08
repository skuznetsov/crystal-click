#!/usr/bin/env ruby
# Small stock-ClickHouse discriminator for W225. This probe has no dependency
# on the Crystal helper or production codec; all RowBinary expectations below
# are independent literals.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'

module RecheckAggregateVariantW225
  extend self

  R = RecheckAggregateRecursiveW224
  SOURCE_ROOT = R::SOURCE_ROOT
  SOURCE_REVISION = R::SOURCE_REVISION
  SOURCE_PREFIX = '/private/tmp/crystal-click-w225-physical.'.freeze
  EVIDENCE_PREFIX = '/private/tmp/crystal-click-w225-bulk.'.freeze
  VERSION = R::VERSION
  BUILD_HASH = R::BUILD_HASH
  RUNTIME_SHA256 = R::RUNTIME_SHA256
  VARIANT_TYPE = 'Variant(AggregateFunction(count), AggregateFunction(sum, UInt8), String)'.freeze
  VARIANT_TABLE = 'w225_variant_af_probe'.freeze
  JSON_TYPE = 'JSON(x AggregateFunction(count))'.freeze
  LC_REFUSAL = 'DataTypeLowCardinality is supported only for numbers, strings, Date or DateTime, but got AggregateFunction(sum, UInt8)'.freeze
  JSON_SERIALIZER_REFUSAL = "JSON serialization doesn't support the return type schema: AggregateFunction(count)".freeze
  EXPECTED_VARIANT_ROW_HEX = '0b0003160100010000000000002102026f6b2cff37010011000000000000'.freeze
  FORMAT_INPUT = 'aggregate_variant_w225_helper_v1'.freeze
  FORMAT_HELPER = 'aggregate_variant_w225_helper_output_v1'.freeze
  FORMAT_MATRIX = 'aggregate_variant_w225_stock_matrix_v1'.freeze
  FORMAT_SUMMARY = 'aggregate_variant_w225_summary_v1'.freeze
  PROFILE_IDS = %w[root_variant_single root_variant_with_size root_variant_null_unused_string
    root_variant_null_unused_sum array_variant variant_array_sum variant_tuple].freeze
  VARIANT_BASIC_SETTING = 'use_compact_variant_discriminators_serialization=0'.freeze
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze

  SOURCE_HASHES = {
    'src/AggregateFunctions/AggregateFunctionCount.h' => 'e30c050dcfb8805e1fd5d9525079cc0c7ca660d03b50ecf9c9cf38a303eb2f0a',
    'src/AggregateFunctions/AggregateFunctionSum.h' => '1ced4e3ee877780fd5b5c3547bd6bdd4f4e8c09559702e91838b15871bb9a94d',
    'src/Columns/ColumnVariant.h' => '97652d84f3fd540e500e5a260c5ffb520b9ae4ba92451a21506c2fbec350d38a',
    'src/DataTypes/DataTypeLowCardinality.cpp' => 'e75ef3196f929ed61313394fe8ba13c0a377446f73fac12f2b2425128d625c5c',
    'src/DataTypes/DataTypeObject.cpp' => '17aa66e87730ef2710d501ae08ed78b0e9ffa914f7a9d33541bb63983d3741b7',
    'src/DataTypes/DataTypeObject.h' => '92284b06203ac6ae2cc9bb44ad64f8da3cbd9f0244c7f2850c6a5acd0c65cc83',
    'src/DataTypes/DataTypeVariant.cpp' => '10cf25b1ad0c1fd00eec3637bca21756207122d45ef09f97518c5748d6ae300d',
    'src/DataTypes/Serializations/ISerialization.cpp' => '87ca6647aeb0dd4022e3437a155f923f817d4447c547eff9ec29ab6876d16dd2',
    'src/DataTypes/Serializations/SerializationAggregateFunction.cpp' => '1fa59453165a7cdb33811e8cf8eb55d7f7b18abd4d28281397470dd217dd4950',
    'src/DataTypes/Serializations/SerializationVariant.cpp' => '9e91cc5a2aa9498841aa7524193247d55a30c77682c65a0991c77a2968b9e022',
    'src/Formats/JSONExtractTree.cpp' => '0514c6077c73836ee344e1044365257cd87381e10d35e862d83fd578f2604afe',
    'src/Functions/defaultValueOfTypeName.cpp' => '194ee34afffcd05a3b1e914b39d71132d9407f00abea9d4ec484f1ae9cfbcc9b',
    'src/Storages/MergeTree/MergeTreeSettings.cpp' => 'b8bdea86a07f61481c747517b56035855fa9726217d5b7183f292a5432b9b515',
    'src/Common/escapeForFileName.cpp' => '70b87ba5ba42d0779927661ce8c4d7e26266ba46431132ad4ca3d39095bfbaec',
  }.freeze

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def write_new(path, bytes)
    File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
  rescue Errno::EEXIST
    fail!("refusing to overwrite W225 evidence: #{path}")
  end

  def write_json(path, object)
    write_new(path, JSON.pretty_generate(object) + "\n")
  end

  def validate_root(path, prefix, label)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full && Dir.children(full).empty?,
      "#{label} must be a fresh, empty, canonical directory")
    require_true(File.dirname(full) == File.realpath('/private/tmp') && full.start_with?(prefix),
      "#{label} must be a direct /private/tmp child with the fixed prefix")
    full
  end

  def pin_source!
    require_true(File.directory?(SOURCE_ROOT) && File.realpath(SOURCE_ROOT) == SOURCE_ROOT,
      'pinned ClickHouse source root is absent/noncanonical')
    files = SOURCE_HASHES.map do |relative, expected|
      path = File.join(SOURCE_ROOT, relative)
      require_true(File.file?(path) && !File.symlink?(path), "source anchor absent or symlinked: #{relative}")
      actual = Digest::SHA256.file(path).hexdigest
      { 'path' => relative, 'expected_sha256' => expected, 'actual_sha256' => actual, 'matches' => actual == expected }
    end
    require_true(files.all? { |item| item.fetch('matches') }, 'a W225 source anchor hash differs')
    {
      'source_reference' => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
      'runtime_built_from_this_source_not_asserted' => true,
      'file_hashes' => files,
      'laws' => [
        { 'path' => 'src/DataTypes/DataTypeVariant.cpp', 'lines' => '26-64', 'law' => 'Variant admits ordinary AggregateFunction alternatives and orders alternatives by complete type name.' },
        { 'path' => 'src/Columns/ColumnVariant.h', 'lines' => '62-68', 'law' => 'Variant discriminator is UInt8; 255 is the NULL discriminator.' },
        { 'path' => 'src/DataTypes/Serializations/SerializationVariant.cpp', 'lines' => '787-812', 'law' => 'RowBinary Variant writes a global discriminator then delegates to the selected child serializer; null uses the special discriminator.' },
        { 'path' => 'src/DataTypes/Serializations/ISerialization.cpp', 'lines' => '302-365', 'law' => 'Substream names encode array levels, string-size streams, escaped tuple fields, Variant discriminator lanes, and escaped Variant arm paths.' },
        { 'path' => 'src/Common/escapeForFileName.cpp', 'lines' => '8-30', 'law' => 'Filename escaping passes isWordCharASCII bytes and renders every other byte as uppercase %HH.' },
        { 'path' => 'src/Storages/MergeTree/MergeTreeSettings.cpp', 'lines' => '298', 'law' => 'MergeTree exposes use_compact_variant_discriminators_serialization; setting it to 0 selects BASIC discriminator serialization.' },
        { 'path' => 'src/DataTypes/Serializations/SerializationAggregateFunction.cpp', 'lines' => '58-67', 'law' => 'AggregateFunction RowBinary delegates state serialization/deserialization to the aggregate function.' },
        { 'path' => 'src/DataTypes/DataTypeLowCardinality.cpp', 'lines' => '27-40', 'law' => 'LowCardinality constructor refuses AggregateFunction because it does not opt in.' },
        { 'path' => 'src/DataTypes/DataTypeObject.cpp', 'lines' => '182-226,814-890', 'law' => 'JSON typed-path declarations are constructed independently; serialization later recursively obtains typed-path serializers and builds the JSON extraction tree.' },
        { 'path' => 'src/Functions/defaultValueOfTypeName.cpp', 'lines' => '39-64', 'law' => 'defaultValueOfTypeName constructs the declared DataType through DataTypeFactory and returns its default value.' },
        { 'path' => 'src/DataTypes/DataTypeObject.h', 'lines' => '51', 'law' => 'JSON DataTypeObject default is a default Object value; formatting that value is a separate serializer context.' },
        { 'path' => 'src/Formats/JSONExtractTree.cpp', 'lines' => '2656-2829', 'law' => 'JSON extraction tree dispatches supported types and rejects an unsupported typed-path type in its default case.' },
      ],
    }
  end

  def diagnostic_messages(record)
    (record.fetch('stdout') + record.fetch('stderr')).lines.each_with_object([]) do |line, messages|
      match = /\ACode: [0-9]+\. DB::Exception: (.*?)(?:\r?\n)?\z/.match(line)
      next unless match
      message = match[1].sub(/\s+\([A-Z_]+\)(?:\s+\(version [^)]+\))?\z/, '')
      messages << message.sub(/\.\z/, '')
    end
  end

  def expected_json_serializer_stderr
    wrapper = 'Code: 43. DB::Exception: '
    message = "#{JSON_SERIALIZER_REFUSAL}. (ILLEGAL_TYPE_OF_ARGUMENT) (version #{VERSION} (official build)). " \
              "(ILLEGAL_TYPE_OF_ARGUMENT) (version #{VERSION} (official build)). (ILLEGAL_TYPE_OF_ARGUMENT)\n"
    wrapper * 3 + message
  end

  def classify_json_serializer_observation(record)
    if record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
       !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error')
      return 'process_success'
    end
    exact_refusal = record.fetch('classification') == 'process_nonzero_or_signaled_exit' &&
      record.fetch('exitstatus') && record.fetch('exitstatus').positive? && !record.fetch('signaled') &&
      !record.fetch('timed_out') && !record.fetch('spawn_error') && record.fetch('stdout').empty? &&
      record.fetch('stderr') == expected_json_serializer_stderr
    exact_refusal ? 'expected_semantic_refusal' : classify_observation(record)
  end

  def checked_success!(record, label)
    require_true(record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
      !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error'),
      "#{label} failed as a process; a process failure is not a semantic refusal")
    record
  end

  def classify_observation(record, expected_diagnostic = nil)
    if record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
       !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error')
      return 'process_success'
    end
    messages = diagnostic_messages(record)
    if record.fetch('classification') == 'process_nonzero_or_signaled_exit' && record.fetch('exitstatus') &&
       record.fetch('exitstatus').positive? && !record.fetch('signaled') && !record.fetch('timed_out') &&
       !record.fetch('spawn_error') && !messages.empty?
      return expected_diagnostic && messages == [expected_diagnostic] ?
        'expected_semantic_refusal' : 'runtime_semantic_refusal_observed'
    end
    'process_failure_not_semantic_refusal'
  end

  def clean_record(record)
    record.reject { |key, _| %w[stdout stderr path].include?(key) }
  end

  # Finite, independently authored logical declarations. These ASTs exist
  # only in the Ruby oracle; neither Crystal parsing nor a production codec
  # constructs the expected RowBinary or Wide-lane bytes.
  def count_node
    { 'kind' => 'count', 'name' => 'AggregateFunction(count)' }
  end

  def sum_node
    { 'kind' => 'sum', 'name' => 'AggregateFunction(sum, UInt8)' }
  end

  def string_node
    { 'kind' => 'string', 'name' => 'String' }
  end

  def array_node(child)
    { 'kind' => 'array', 'children' => [child] }
  end

  def tuple_node(children)
    { 'kind' => 'tuple', 'children' => children }
  end

  def variant_node(children)
    sorted = children.sort_by { |child| type_name(child) }
    { 'kind' => 'variant', 'children' => sorted }
  end

  def type_name(node)
    case node.fetch('kind')
    when 'count', 'sum', 'string'
      node.fetch('name')
    when 'array'
      "Array(#{type_name(node.fetch('children').fetch(0))})"
    when 'tuple'
      "Tuple(#{node.fetch('children').map { |child| type_name(child) }.join(', ')})"
    when 'variant'
      "Variant(#{node.fetch('children').map { |child| type_name(child) }.join(', ')})"
    else
      fail!("unlisted W225 oracle type node: #{node.fetch('kind')}")
    end
  end

  # Independently map the finite type AST to the library part's physical
  # basenames. This is intentionally separate from expected_lanes: lane roles
  # describe value channels, while these names follow ClickHouse's escaped
  # substream-path grammar in ISerialization.cpp/escapeForFileName.cpp.
  def escaped_physical_component(raw)
    raw.bytes.map do |byte|
      word = (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
        (byte >= 97 && byte <= 122) || byte == 95
      word ? byte.chr : format('%%%02X', byte)
    end.join
  end

  def append_physical_names(node, prefix, profile, array_level, names)
    case node.fetch('kind')
    when 'count', 'sum'
      names << prefix
    when 'string'
      names << "#{prefix}.size" if profile == 'with_size_stream'
      names << prefix
    when 'array'
      names << "#{prefix}.size#{array_level}"
      append_physical_names(node.fetch('children').fetch(0), prefix, profile, array_level + 1, names)
    when 'tuple'
      node.fetch('children').each_with_index do |child, index|
        field_prefix = "#{prefix}%2E#{escaped_physical_component((index + 1).to_s)}"
        append_physical_names(child, field_prefix, profile, array_level, names)
      end
    when 'variant'
      names << "#{prefix}.variant_discr"
      node.fetch('children').each do |child|
        arm_prefix = "#{prefix}.#{escaped_physical_component(type_name(child))}"
        append_physical_names(child, arm_prefix, profile, array_level, names)
      end
    else
      fail!("unlisted W225 physical-name type node: #{node.fetch('kind')}")
    end
  end

  def expected_physical_stream_names(profile)
    names = []
    append_physical_names(profile.fetch('node'), 'v', profile.fetch('profile'), 0, names)
    names.sort
  end

  def root_variant_node
    variant_node([count_node, sum_node, string_node])
  end

  def metadata_variant(alternative, value)
    { 'alternative' => alternative, 'value' => value }
  end

  def profile_definitions
    count = count_node
    sum = sum_node
    string = string_node
    root = root_variant_node
    sum_array = array_node(sum_node)
    tuple = tuple_node([count_node, sum_node])
    root_rows = [
      metadata_variant(type_name(count), '128'),
      metadata_variant(type_name(sum), '256'), nil, nil,
      metadata_variant(type_name(string), 'tail'),
    ]
    unused_string_rows = [
      metadata_variant(type_name(count), '0'),
      metadata_variant(type_name(sum), '255'), nil, nil,
      metadata_variant(type_name(count), '18446744073709551615'),
    ]
    unused_sum_rows = [
      metadata_variant(type_name(count), '1'),
      metadata_variant(type_name(string), 'left'), nil, nil,
      metadata_variant(type_name(string), 'right'),
    ]
    array_variant_rows = [
      [metadata_variant(type_name(count), '127'), metadata_variant(type_name(sum), '256')],
      [metadata_variant(type_name(sum), '7')], [], [], [nil],
    ]
    variant_array_rows = [
      metadata_variant(type_name(sum_array), ['1', '7']),
      metadata_variant(type_name(string), 'xy'),
      metadata_variant(type_name(sum_array), []), nil,
      metadata_variant(type_name(string), 'z'),
    ]
    variant_tuple_rows = [
      metadata_variant(type_name(tuple), ['128', '7']),
      metadata_variant(type_name(string), 'mid'),
      metadata_variant(type_name(tuple), ['18446744073709551615', '256']),
      nil,
      metadata_variant(type_name(string), 'end'),
    ]
    [
      { 'id' => PROFILE_IDS.fetch(0), 'node' => root, 'profile' => 'single_stream', 'metadata' => root_rows },
      { 'id' => PROFILE_IDS.fetch(1), 'node' => root_variant_node, 'profile' => 'with_size_stream', 'metadata' => root_rows },
      { 'id' => PROFILE_IDS.fetch(2), 'node' => root_variant_node, 'profile' => 'single_stream', 'metadata' => unused_string_rows },
      { 'id' => PROFILE_IDS.fetch(3), 'node' => root_variant_node, 'profile' => 'single_stream', 'metadata' => unused_sum_rows },
      { 'id' => PROFILE_IDS.fetch(4), 'node' => array_node(root_variant_node), 'profile' => 'single_stream', 'metadata' => array_variant_rows },
      { 'id' => PROFILE_IDS.fetch(5), 'node' => variant_node([sum_array, string_node]), 'profile' => 'single_stream', 'metadata' => variant_array_rows },
      { 'id' => PROFILE_IDS.fetch(6), 'node' => variant_node([tuple, string_node]), 'profile' => 'single_stream', 'metadata' => variant_tuple_rows },
    ].map do |profile|
      profile['declared_type'] = type_name(profile.fetch('node'))
      profile['row_keys'] = R::ROW_KEYS.map(&:to_i)
      profile['mark_rows'] = R::MARK_ROWS.map(&:to_i)
      profile['values'] = profile.fetch('metadata').map { |value| tagged_value(profile.fetch('node'), value) }
      literal_rows = profile.fetch('metadata').each_with_index.map do |value, index|
        u64_bytes(R::ROW_KEYS.fetch(index)) + rowbinary_value(profile.fetch('node'), value)
      end
      # The tagged-value encoder consumes independently represented opaque
      # Sum-state hex rather than logical UInt64 metadata.
      tagged_rows = profile.fetch('values').each_with_index.map do |value, index|
        u64_bytes(R::ROW_KEYS.fetch(index)) + rowbinary_tagged(profile.fetch('node'), value)
      end
      require_true(literal_rows == tagged_rows, "#{profile.fetch('id')} literal and metadata RowBinary encoders disagree")
      profile['rowbinary'] = {
        'full_hex' => literal_rows.join.b.unpack1('H*'),
        'middle_hex' => literal_rows[2, 2].join.b.unpack1('H*'),
        'empty_hex' => ''.freeze,
      }
      profile['expected_lanes'] = expected_lanes(profile)
      profile
    end
  end

  def u64_bytes(value)
    number = value.is_a?(String) ? Integer(value, 10) : Integer(value)
    require_true(number >= 0 && number <= 18_446_744_073_709_551_615, 'W225 UInt64 literal is outside range')
    Array.new(8) { |index| (number >> (8 * index)) & 0xff }.pack('C*').b
  end

  def varuint_bytes(value)
    number = Integer(value)
    require_true(number >= 0 && number <= 18_446_744_073_709_551_615, 'W225 VarUInt literal is outside range')
    bytes = []
    while number >= 128
      bytes << ((number & 0x7f) | 0x80)
      number >>= 7
    end
    bytes << number
    bytes.pack('C*').b
  end

  def sum_state_hex(value)
    u64_bytes(value).unpack1('H*')
  end

  def tagged_value(node, value)
    case node.fetch('kind')
    when 'count'
      { 'kind' => 'count', 'value' => value }
    when 'sum'
      { 'kind' => 'aggregate_state', 'type' => type_name(node), 'bytes_hex' => sum_state_hex(value) }
    when 'string'
      { 'kind' => 'string', 'value' => value }
    when 'variant'
      return { 'kind' => 'variant_null' } if value.nil?
      child = node.fetch('children').find { |item| type_name(item) == value.fetch('alternative') }
      fail!("Variant alternative absent from W225 canonical type: #{value.fetch('alternative')}") unless child
      { 'kind' => 'variant', 'alternative' => type_name(child), 'value' => tagged_value(child, value.fetch('value')) }
    when 'array'
      { 'kind' => 'array', 'items' => value.map { |child| tagged_value(node.fetch('children').fetch(0), child) } }
    when 'tuple'
      { 'kind' => 'tuple', 'fields' => value.each_with_index.map { |child, index| tagged_value(node.fetch('children').fetch(index), child) } }
    else
      fail!("unlisted W225 tagged fixture type: #{node.fetch('kind')}")
    end
  end

  def rowbinary_value(node, value)
    case node.fetch('kind')
    when 'count'
      varuint_bytes(value)
    when 'sum'
      u64_bytes(value)
    when 'string'
      bytes = value.encode(Encoding::UTF_8).b
      varuint_bytes(bytes.bytesize) + bytes
    when 'variant'
      return "\xff".b if value.nil?
      index = node.fetch('children').index { |child| type_name(child) == value.fetch('alternative') }
      fail!("Variant RowBinary alternative absent: #{value.fetch('alternative')}") unless index
      [index].pack('C*').b + rowbinary_value(node.fetch('children').fetch(index), value.fetch('value'))
    when 'array'
      child = node.fetch('children').fetch(0)
      varuint_bytes(value.length) + value.map { |item| rowbinary_value(child, item) }.join.b
    when 'tuple'
      value.each_with_index.map { |item, index| rowbinary_value(node.fetch('children').fetch(index), item) }.join.b
    else
      fail!("unlisted W225 RowBinary type: #{node.fetch('kind')}")
    end
  end

  def rowbinary_tagged(node, value)
    case node.fetch('kind')
    when 'count'
      varuint_bytes(value.fetch('value'))
    when 'sum'
      [value.fetch('bytes_hex')].pack('H*').b
    when 'string'
      text = value.fetch('value').encode(Encoding::UTF_8).b
      varuint_bytes(text.bytesize) + text
    when 'variant'
      if value.fetch('kind') == 'variant_null'
        "\xff".b
      else
        index = node.fetch('children').index { |child| type_name(child) == value.fetch('alternative') }
        fail!("tagged Variant alternative absent: #{value.fetch('alternative')}") unless index
        [index].pack('C*').b + rowbinary_tagged(node.fetch('children').fetch(index), value.fetch('value'))
      end
    when 'array'
      items = value.fetch('items')
      varuint_bytes(items.length) + items.map { |item| rowbinary_tagged(node.fetch('children').fetch(0), item) }.join.b
    when 'tuple'
      value.fetch('fields').each_with_index.map { |item, index| rowbinary_tagged(node.fetch('children').fetch(index), item) }.join.b
    else
      fail!("unlisted W225 tagged RowBinary type: #{node.fetch('kind')}")
    end
  end

  def collect_roles(node, path, profile, roles)
    case node.fetch('kind')
    when 'count', 'sum'
      roles << "#{path}.data"
    when 'string'
      roles << "#{path}.data"
      roles << "#{path}.string_sizes" if profile == 'with_size_stream'
    when 'variant'
      roles << "#{path}.discriminators"
      node.fetch('children').each_with_index { |child, index| collect_roles(child, "#{path}.arm.#{index}", profile, roles) }
    when 'array'
      roles << "#{path}.sizes"
      collect_roles(node.fetch('children').fetch(0), "#{path}.elements", profile, roles)
    when 'tuple'
      node.fetch('children').each_with_index { |child, index| collect_roles(child, "#{path}.field.#{index}", profile, roles) }
    else
      fail!("unlisted W225 lane-role type: #{node.fetch('kind')}")
    end
  end

  def emit_bulk(node, value, path, profile, lanes)
    case node.fetch('kind')
    when 'count'
      lanes.fetch("#{path}.data") << varuint_bytes(value)
    when 'sum'
      lanes.fetch("#{path}.data") << u64_bytes(value)
    when 'string'
      raw = value.encode(Encoding::UTF_8).b
      if profile == 'with_size_stream'
        lanes.fetch("#{path}.string_sizes") << u64_bytes(raw.bytesize)
        lanes.fetch("#{path}.data") << raw
      else
        lanes.fetch("#{path}.data") << varuint_bytes(raw.bytesize) << raw
      end
    when 'variant'
      if value.nil?
        lanes.fetch("#{path}.discriminators") << "\xff".b
      else
        index = node.fetch('children').index { |child| type_name(child) == value.fetch('alternative') }
        fail!("bulk Variant alternative absent: #{value.fetch('alternative')}") unless index
        lanes.fetch("#{path}.discriminators") << [index].pack('C*').b
        emit_bulk(node.fetch('children').fetch(index), value.fetch('value'), "#{path}.arm.#{index}", profile, lanes)
      end
    when 'array'
      items = value
      lanes.fetch("#{path}.sizes") << u64_bytes(items.length)
      items.each { |item| emit_bulk(node.fetch('children').fetch(0), item, "#{path}.elements", profile, lanes) }
    when 'tuple'
      value.each_with_index do |item, index|
        emit_bulk(node.fetch('children').fetch(index), item, "#{path}.field.#{index}", profile, lanes)
      end
    else
      fail!("unlisted W225 bulk lane type: #{node.fetch('kind')}")
    end
  end

  def expected_lanes(profile)
    roles = []
    collect_roles(profile.fetch('node'), 'root', profile.fetch('profile'), roles)
    require_true(roles.uniq.length == roles.length, "#{profile.fetch('id')} has duplicate physical roles")
    buffers = roles.each_with_object({}) { |role, result| result[role] = +''.b }
    offsets = roles.each_with_object({}) { |role, result| result[role] = [0] }
    row_index = 0
    profile.fetch('mark_rows').each do |mark_rows|
      mark_rows.times do
        emit_bulk(profile.fetch('node'), profile.fetch('metadata').fetch(row_index), 'root', profile.fetch('profile'), buffers)
        row_index += 1
      end
      roles.each { |role| offsets.fetch(role) << buffers.fetch(role).bytesize }
    end
    require_true(row_index == profile.fetch('metadata').length, "#{profile.fetch('id')} lane mark schedule does not cover rows")
    roles.sort.map do |role|
      { 'role_path' => role, 'hex' => buffers.fetch(role).unpack1('H*'), 'mark_offsets' => offsets.fetch(role) }
    end
  end

  class Probe
    def initialize(options)
      @binary = R.validate_binary!(options.fetch(:clickhouse))
      @source_root = RecheckAggregateVariantW225.validate_root(options.fetch(:source_root), SOURCE_PREFIX, 'stock source root')
      @root = RecheckAggregateVariantW225.validate_root(options.fetch(:evidence_root), EVIDENCE_PREFIX, 'evidence root')
      @recorder = R::Recorder.new(@root, @binary)
      @observations = {}
      @runtime_pin = nil
      @source_pin = nil
      @fatal = nil
    end

    def run
      prepare_layout
      @source_pin = RecheckAggregateVariantW225.pin_source!
      capture_runtime_pin
      capture_variant_rowbinary
      capture_low_cardinality_refusal
      capture_json_constructor_and_serializer
      verify_process_roster
      write_summary('w225_stock_discriminator_observed')
      puts "W225 stock discriminator observed; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal ||= "#{error.class}: #{error.message}"
      write_summary('runner_failure_or_observations_differ') rescue nil
      warn "W225 stock probe failure (process failures are not semantic refusals): #{@fatal}"
      false
    end

    private

    def prepare_layout
      %w[invocations].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      %w[stores cases].each { |name| Dir.mkdir(File.join(@source_root, name), 0o700) }
      %w[variant low_cardinality json_constructor json_serializer pins].each do |name|
        Dir.mkdir(File.join(@source_root, 'stores', name), 0o700)
      end
      Dir.mkdir(File.join(@source_root, 'cases', 'probe'), 0o700)
    end

    def process(label, store, sql, input: nil)
      @recorder.run(label, store, sql, input: input)
    end

    def capture_runtime_pin
      store = File.join(@source_root, 'stores', 'pins')
      version = RecheckAggregateVariantW225.checked_success!(process('runtime-version-pin', store, 'SELECT version() FORMAT TSVRaw'), 'runtime version')
      RecheckAggregateVariantW225.require_true(version.fetch('stdout').strip == VERSION, 'runtime version differs from W225 pin')
      build = RecheckAggregateVariantW225.checked_success!(process('runtime-build-pin', store,
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"), 'runtime build hash')
      RecheckAggregateVariantW225.require_true(build.fetch('stdout').strip == "VERSION_GITHASH=#{BUILD_HASH}", 'runtime build hash differs from W225 pin')
      @runtime_pin = { 'version' => VERSION, 'build_hash' => BUILD_HASH,
        'sha256' => Digest::SHA256.file(@binary).hexdigest, 'runtime_source_correlation' => 'not_asserted' }
    end

    def capture_variant_rowbinary
      store = File.join(@source_root, 'stores', 'variant')
      table = "default.#{VARIANT_TABLE}"
      create_sql = "CREATE TABLE #{table} (pk UInt8, v #{VARIANT_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS use_compact_variant_discriminators_serialization=0"
      create = process('variant-af-create', store, create_sql)
      create_result = RecheckAggregateVariantW225.classify_observation(create)
      observation = { 'id' => 'variant_af_rowbinary', 'declared_type' => VARIANT_TYPE,
        'creation' => RecheckAggregateVariantW225.clean_record(create).merge('classification' => create_result),
        'creation_observed_diagnostics' => RecheckAggregateVariantW225.diagnostic_messages(create),
        'expected_rows_literal_hex' => EXPECTED_VARIANT_ROW_HEX,
        'source_anchor' => 'src/DataTypes/DataTypeVariant.cpp:26-64; src/DataTypes/Serializations/SerializationVariant.cpp:787-812; src/DataTypes/Serializations/SerializationAggregateFunction.cpp:58-67' }
      @observations['variant'] = observation
      unless create_result == 'process_success'
        return
      end

      input = [EXPECTED_VARIANT_ROW_HEX].pack('H*').b
      insert = process('variant-af-rowbinary-insert', store, "INSERT INTO #{table} FORMAT RowBinary", input: input)
      insert_result = RecheckAggregateVariantW225.classify_observation(insert)
      observation['insert'] = RecheckAggregateVariantW225.clean_record(insert).merge('classification' => insert_result)
      observation['insert_input_bytes'] = input.bytesize
      @observations['variant'] = observation
      unless insert_result == 'process_success'
        return
      end

      check = process('variant-af-check', store, "CHECK TABLE #{table} FORMAT TSVRaw")
      check_result = RecheckAggregateVariantW225.classify_observation(check)
      observation['check'] = RecheckAggregateVariantW225.clean_record(check).merge('classification' => check_result)
      observation['check_output'] = check.fetch('stdout')
      @observations['variant'] = observation
      if check_result == 'process_success'
        RecheckAggregateVariantW225.require_true(check.fetch('stdout') == "all_1_1_0\t1\t\n", 'Variant stock CHECK did not validate exactly one inserted part')
      else
        return
      end

      metadata = process('variant-af-metadata', store,
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{VARIANT_TABLE}' ORDER BY position FORMAT TSVRaw")
      metadata_result = RecheckAggregateVariantW225.classify_observation(metadata)
      observation['metadata'] = RecheckAggregateVariantW225.clean_record(metadata).merge('classification' => metadata_result)
      expected_schema = "pk\tUInt8\nv\t#{VARIANT_TYPE}\n"
      observation['metadata_output'] = metadata.fetch('stdout')
      @observations['variant'] = observation
      if metadata_result == 'process_success'
        RecheckAggregateVariantW225.require_true(metadata.fetch('stdout') == expected_schema, 'Variant stock exact declared-type metadata differs')
      else
        return
      end

      output = File.join(@source_root, 'cases', 'probe', 'variant-af-full.rowbinary')
      query = "SELECT pk, v FROM #{table} ORDER BY pk INTO OUTFILE '#{output}' FORMAT RowBinary"
      read = process('variant-af-rowbinary-read', store, query)
      read_result = RecheckAggregateVariantW225.classify_observation(read)
      observation['read'] = RecheckAggregateVariantW225.clean_record(read).merge('classification' => read_result)
      @observations['variant'] = observation
      if read_result == 'process_success' && File.file?(output) && !File.symlink?(output)
        actual = File.binread(output)
        observation['read_bytes'] = actual.bytesize
        observation['read_sha256'] = Digest::SHA256.hexdigest(actual)
        observation['read_matches_independent_literal'] = actual == input
        observation['read_actual_hex'] = actual.unpack1('H*')
        RecheckAggregateVariantW225.require_true(actual == input, 'stock Variant RowBinary read differs from independent literal bytes')
      else
        observation['read_matches_independent_literal'] = false
        RecheckAggregateVariantW225.require_true(read_result == 'process_success', 'stock Variant RowBinary read failed as a process')
        RecheckAggregateVariantW225.fail!('stock Variant RowBinary output file is missing or symlinked')
      end
      @observations['variant'] = observation
    end

    def capture_low_cardinality_refusal
      store = File.join(@source_root, 'stores', 'low_cardinality')
      sql = 'CREATE TABLE default.w225_low_cardinality_af_probe (v LowCardinality(AggregateFunction(sum, UInt8))) ENGINE=Memory'
      record = process('constructor-low-cardinality-aggregate-function', store, sql)
      classification = RecheckAggregateVariantW225.classify_observation(record, LC_REFUSAL)
      @observations['low_cardinality_af'] = {
        'declared_type' => 'LowCardinality(AggregateFunction(sum, UInt8))',
        'classification' => classification,
        'expected_source_diagnostic' => LC_REFUSAL,
        'observed_diagnostics' => RecheckAggregateVariantW225.diagnostic_messages(record),
        'source_anchor' => 'src/DataTypes/DataTypeLowCardinality.cpp:27-40',
        'process' => RecheckAggregateVariantW225.clean_record(record),
      }
      RecheckAggregateVariantW225.require_true(classification == 'expected_semantic_refusal',
        'LowCardinality(AF) did not produce the source-predicted semantic refusal; process failure is not refusal')
    end

    def capture_json_constructor_and_serializer
      constructor_store = File.join(@source_root, 'stores', 'json_constructor')
      constructor_sql = "SELECT toTypeName(defaultValueOfTypeName('#{JSON_TYPE}')) FORMAT TSVRaw"
      constructor = process('json-typed-af-type-constructor', constructor_store, constructor_sql)
      constructor_classification = RecheckAggregateVariantW225.classify_observation(constructor)
      constructor_output = constructor.fetch('stdout')
      constructor_expected_type = "#{JSON_TYPE}\n"
      @observations['json_typed_af_constructor'] = {
        'declared_type' => JSON_TYPE,
        'classification' => constructor_classification == 'process_success' ? 'type_constructor_accepted' : constructor_classification,
        'expected_output_if_accepted' => constructor_expected_type,
        'observed_output' => constructor_output,
        'observed_diagnostics' => RecheckAggregateVariantW225.diagnostic_messages(constructor),
        'source_anchor' => 'src/DataTypes/DataTypeObject.cpp:814-890; src/Functions/defaultValueOfTypeName.cpp:24-64 (type construction without output serialization)',
        'process' => RecheckAggregateVariantW225.clean_record(constructor),
      }
      if constructor_classification == 'process_success'
        RecheckAggregateVariantW225.require_true(constructor_output == constructor_expected_type,
          'JSON typed-AF constructor probe returned a different nominal type')
      end

      serializer_store = File.join(@source_root, 'stores', 'json_serializer')
      serializer_sql = "SELECT defaultValueOfTypeName('#{JSON_TYPE}') FORMAT JSONEachRow"
      serializer = process('json-typed-af-serializer-construction', serializer_store, serializer_sql)
      serializer_classification = RecheckAggregateVariantW225.classify_json_serializer_observation(serializer)
      @observations['json_typed_af_serializer'] = {
        'declared_type' => JSON_TYPE,
        'classification' => serializer_classification == 'expected_semantic_refusal' ?
          'source_predicted_serializer_semantic_refusal' : serializer_classification,
        'expected_source_diagnostic' => JSON_SERIALIZER_REFUSAL,
        'observed_diagnostics' => RecheckAggregateVariantW225.diagnostic_messages(serializer),
        'normalized_diagnostics' => serializer_classification == 'expected_semantic_refusal' ?
          [JSON_SERIALIZER_REFUSAL] : RecheckAggregateVariantW225.diagnostic_messages(serializer),
        'raw_stderr_matches_exact_expected_chain' =>
          serializer.fetch('stderr') == RecheckAggregateVariantW225.expected_json_serializer_stderr,
        'source_anchor' => 'src/DataTypes/DataTypeObject.cpp:182-226; src/Formats/JSONExtractTree.cpp:2656-2829',
        'process' => RecheckAggregateVariantW225.clean_record(serializer),
      }
      RecheckAggregateVariantW225.require_true(
        %w[process_success].include?(constructor_classification),
        'JSON typed-AF constructor probe failed as a process')
      RecheckAggregateVariantW225.require_true(serializer_classification == 'expected_semantic_refusal',
        'JSON typed-AF serializer did not produce the exact pinned semantic refusal chain')
    end

    def verify_process_roster
      expected = %w[runtime-version-pin runtime-build-pin variant-af-create constructor-low-cardinality-aggregate-function
        json-typed-af-type-constructor json-typed-af-serializer-construction]
      variant = @observations.fetch('variant')
      if variant.fetch('creation').fetch('classification') == 'process_success'
        expected << 'variant-af-rowbinary-insert' if variant['insert']
        expected << 'variant-af-check' if variant['insert'] && variant['insert'].fetch('classification') == 'process_success'
        expected << 'variant-af-metadata' if variant['check'] && variant['check'].fetch('classification') == 'process_success'
        expected << 'variant-af-rowbinary-read' if variant['metadata'] && variant['metadata'].fetch('classification') == 'process_success'
      end
      labels = @recorder.records.map { |item| item.fetch('label') }
      RecheckAggregateVariantW225.require_true(labels.uniq.length == labels.length && labels.sort == expected.sort,
        'exact W225 probe invocation roster differs')
      @recorder.records.each do |item|
        next if item.fetch('label') == 'constructor-low-cardinality-aggregate-function' ||
                item.fetch('label') == 'json-typed-af-type-constructor' ||
                item.fetch('label') == 'json-typed-af-serializer-construction'
        RecheckAggregateVariantW225.require_true(item.fetch('classification') == 'process_success',
          "stock Variant discriminator process failed: #{item.fetch('label')}")
      end
    end

    def write_summary(classification)
      return unless @root && File.directory?(@root) && !File.exist?(File.join(@root, 'summary.json'))
      records = @recorder ? @recorder.records : []
      summary = {
        'format' => 'aggregate_variant_w225_probe_summary_v1',
        'mode' => 'probe_only',
        'classification' => classification,
        'success' => classification == 'w225_stock_discriminator_observed',
        'error' => @fatal,
        'source_root' => @source_root,
        'evidence_root' => @root,
        'source_pin' => @source_pin,
        'runtime_pin' => @runtime_pin,
        'helper_sha256' => 'not_applicable_to_probe_only',
        'observations' => @observations,
        'processes' => records.map { |item| RecheckAggregateVariantW225.clean_record(item) },
        'process_status_counts' => {
          'success_exit0' => records.count { |item| item.fetch('classification') == 'process_success' },
          'nonzero_or_signaled' => records.count { |item| item.fetch('classification') == 'process_nonzero_or_signaled_exit' },
          'timeout' => records.count { |item| item.fetch('classification') == 'process_timeout' },
          'spawn_failure' => records.count { |item| item.fetch('classification') == 'spawn_failure' },
        },
      }
      RecheckAggregateVariantW225.write_json(File.join(@root, 'summary.json'), summary)
      RecheckAggregateVariantW225.write_json(File.join(@source_root, 'cases', 'probe', 'observations.json'), summary['observations']) if File.directory?(File.join(@source_root, 'cases', 'probe'))
      RecheckAggregateVariantW225.write_json(File.join(@source_root, 'source_pin.json'), @source_pin) if @source_pin
      RecheckAggregateVariantW225.write_json(File.join(@source_root, 'runtime_pin.json'), @runtime_pin) if @runtime_pin
    end
  end

  class PairedProbe
    def initialize(options)
      @binary = R.validate_binary!(options.fetch(:clickhouse))
      @expected_helper_sha256 = R.validate_sha256_pin!(options.fetch(:helper_sha256), 'expected helper SHA-256')
      @helper = R.validate_program!(options.fetch(:helper), 'prebuilt W225 Crystal helper')
      @helper_sha256_at_start = Digest::SHA256.file(@helper).hexdigest
      RecheckAggregateVariantW225.require_true(@helper_sha256_at_start == @expected_helper_sha256,
        "prebuilt W225 helper differs from externally supplied SHA-256: #{@helper_sha256_at_start}")
      @source_root = RecheckAggregateVariantW225.validate_root(options.fetch(:source_root), SOURCE_PREFIX, 'stock source root')
      @root = RecheckAggregateVariantW225.validate_root(options.fetch(:evidence_root), EVIDENCE_PREFIX, 'evidence root')
      @profiles = RecheckAggregateVariantW225.profile_definitions
      RecheckAggregateVariantW225.require_true(@profiles.map { |profile| profile.fetch('id') } == PROFILE_IDS,
        'W225 paired profile roster/order differs')
      @recorder = R::Recorder.new(@root, @binary)
      @source_pin = nil
      @runtime_pin = nil
      @source_matrix_sha256 = nil
      @helper_input_sha256 = nil
      @helper_sha256_before_execute = nil
      @helper_sha256_after_execute = nil
      @helper_process = nil
      @helper_profiles = []
      @attached_records = []
      @targets = {}
      @fatal = nil
    end

    def run
      prepare_layout
      @source_pin = RecheckAggregateVariantW225.pin_source!
      pin_runtime
      @profiles.each_with_index { |profile, index| capture_stock_profile(profile, index) }
      write_source_matrix
      invoke_helper
      create_native_targets
      @profiles.each_with_index { |profile, index| attach_one(profile, @helper_profiles.fetch(index), index) }
      verify_invocations
      write_summary('paired_variant_profiles_observed')
      puts "W225 paired Variant profiles=#{@profiles.length}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal ||= "#{error.class}: #{error.message}"
      write_summary('runner_failure_or_observations_differ') rescue nil
      warn "W225 paired probe failure (process failures are not semantic refusals): #{@fatal}"
      false
    end

    private

    def prepare_layout
      %w[invocations stores parts cases generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'generated', 'parts'), 0o700)
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      %w[invocations stores parts cases].each { |name| Dir.mkdir(File.join(@source_root, name), 0o700) }
      Dir.mkdir(File.join(@source_root, 'stores', 'profiles'), 0o700)
      Dir.mkdir(File.join(@source_root, 'stores', 'pins'), 0o700)
      Dir.mkdir(File.join(@source_root, 'cases', 'profiles'), 0o700)
    end

    def checked_success!(record, label)
      RecheckAggregateVariantW225.require_true(record.fetch('classification') == 'process_success' &&
        record.fetch('exitstatus') == 0 && !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error'),
        "#{label} failed as a process; this is not a semantic refusal")
      record
    end

    def process(label, store, sql = nil, input: nil, timeout: R::PROCESS_TIMEOUT_SECONDS, argv: nil)
      @recorder.run(label, store, sql, input: input, timeout: timeout, argv: argv)
    end

    def pin_runtime
      store = File.join(@source_root, 'stores', 'pins')
      version = checked_success!(process('runtime-version-pin', store, 'SELECT version() FORMAT TSVRaw'), 'runtime version pin')
      RecheckAggregateVariantW225.require_true(version.fetch('stdout').strip == VERSION, 'runtime version differs from W225 pin')
      build = checked_success!(process('runtime-build-pin', store,
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"), 'runtime build pin')
      RecheckAggregateVariantW225.require_true(build.fetch('stdout').strip == "VERSION_GITHASH=#{BUILD_HASH}",
        'runtime build hash differs from W225 pin')
      actual_sha = Digest::SHA256.file(@binary).hexdigest
      RecheckAggregateVariantW225.require_true(actual_sha == RUNTIME_SHA256, 'runtime executable SHA changed after validation')
      @runtime_pin = { 'version' => VERSION, 'build_hash' => BUILD_HASH, 'sha256' => actual_sha,
        'runtime_source_correlation' => 'not_asserted' }
      RecheckAggregateVariantW225.write_json(File.join(@source_root, 'runtime_pin.json'), @runtime_pin)
    end

    def table_name(profile)
      "w225_#{profile.fetch('id')}"
    end

    def create_sql(profile, table)
      mode = profile.fetch('profile')
      RecheckAggregateVariantW225.require_true(R::STRING_VERSIONS.key?(mode), "unlisted W225 String profile: #{mode}")
      settings = R::STOCK_SETTINGS + ["string_serialization_version='#{mode}'", VARIANT_BASIC_SETTING]
      "CREATE TABLE default.#{table} (pk UInt64, v #{profile.fetch('declared_type')}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings.join(', ')}"
    end

    def inventory(part)
      RecheckAggregateVariantW225.require_true(File.directory?(part) && !File.symlink?(part) && File.realpath(part) == part,
        "part missing, symlinked, or noncanonical: #{part}")
      entries = []
      Find.find(part) do |path|
        next if path == part
        RecheckAggregateVariantW225.require_true(!File.symlink?(path), "symlink in physical part: #{path}")
        next if File.directory?(path)
        RecheckAggregateVariantW225.require_true(File.file?(path), "non-file physical part entry: #{path}")
        entries << { 'path' => path[(part.length + 1)..-1], 'size' => File.size(path),
          'sha256' => Digest::SHA256.file(path).hexdigest }
      end
      entries.sort_by { |entry| entry.fetch('path') }
    end

    def strict_part_path!(raw, expected, label)
      accepted = raw == expected || raw == expected + File::SEPARATOR
      RecheckAggregateVariantW225.require_true(accepted,
        "#{label} path is not the exact canonical part path or that path plus one terminal separator: #{raw.inspect}")
      RecheckAggregateVariantW225.require_true(File.directory?(expected) && !File.symlink?(expected) && File.realpath(expected) == expected,
        "#{label} canonical part is missing, symlinked, or redirected")
      expected
    end

    def schema_output(profile)
      "pk\tUInt64\nv\t#{profile.fetch('declared_type')}\n"
    end

    def source_part_path(profile)
      File.join(@source_root, 'parts', profile.fetch('id'), 'all_1_1_0')
    end

    def source_case_path(profile, window)
      File.join(@source_root, 'cases', 'profiles', "#{profile.fetch('id')}-#{window}.rowbinary")
    end

    def rowbinary_indices(window)
      { 'full' => [0, 1, 2, 3, 4], 'middle' => [2, 3], 'empty' => [] }.fetch(window)
    end

    def expected_rowbinary(profile, window)
      full = [profile.fetch('rowbinary').fetch('full_hex')].pack('H*').b
      middle = [profile.fetch('rowbinary').fetch('middle_hex')].pack('H*').b
      empty = [profile.fetch('rowbinary').fetch('empty_hex')].pack('H*').b
      { 'full' => full, 'middle' => middle, 'empty' => empty }.fetch(window)
    end

    def run_rowbinary(label_prefix, table, store, path_for, profile)
      windows = {}
      %w[full middle empty].each do |window|
        output = path_for.call(window)
        RecheckAggregateVariantW225.require_true(!File.exist?(output) && !File.symlink?(output), "refusing to overwrite RowBinary output: #{output}")
        predicate = case window
                    when 'full' then ''
                    when 'middle' then ' WHERE pk BETWEEN 33 AND 44'
                    when 'empty' then ' WHERE pk=0'
                    end
        escaped = output.gsub("'", "\\'")
        sql = "SELECT pk, v FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{escaped}' FORMAT RowBinary"
        record = checked_success!(process("#{label_prefix}-#{profile.fetch('id')}-#{window}", store, sql), "#{label_prefix} #{window} RowBinary #{profile.fetch('id')}")
        actual = File.binread(output)
        expected = expected_rowbinary(profile, window)
        RecheckAggregateVariantW225.require_true(actual == expected,
          "#{label_prefix} #{window} RowBinary bytes differ from independent literal for #{profile.fetch('id')}")
        windows[window] = { 'path' => output, 'bytes' => actual.bytesize,
          'sha256' => Digest::SHA256.hexdigest(actual), 'literal_hex' => actual.unpack1('H*'),
          'matches_independent_literal' => true, 'process' => RecheckAggregateVariantW225.clean_record(record) }
      end
      windows
    end

    def capture_stock_profile(profile, index)
      id = profile.fetch('id')
      table = table_name(profile)
      store = File.join(@source_root, 'stores', 'profiles', id)
      Dir.mkdir(store, 0o700)
      # A separate metadata-vs-tagged RowBinary check was completed while the
      # pure Ruby manifest was built, before any ClickHouse process is started.
      literals = profile.fetch('rowbinary')
      RecheckAggregateVariantW225.write_json(File.join(@source_root, 'cases', 'profiles', "#{id}-literal-validation.json"), {
        'validation' => 'pure Ruby metadata encoder vs separately represented tagged-state literal encoder',
        'before_any_clickhouse_process_for_profile' => true, 'all_rows_match' => true,
        'rowbinary' => literals, 'expected_lanes' => profile.fetch('expected_lanes') })
      create = checked_success!(process("stock-create-#{id}", store, create_sql(profile, table)), "stock CREATE #{id}")
      input = [literals.fetch('full_hex')].pack('H*').b
      insert = checked_success!(process("stock-insert-#{id}", store,
        "INSERT INTO default.#{table} FORMAT RowBinary", input: input), "stock RowBinary INSERT #{id}")
      check = checked_success!(process("stock-check-#{id}", store,
        "CHECK TABLE default.#{table} FORMAT TSVRaw"), "stock CHECK #{id}")
      RecheckAggregateVariantW225.require_true(check.fetch('stdout') == "all_1_1_0\t1\t\n",
        "stock CHECK did not validate exactly one part for #{id}")
      windows = run_rowbinary('stock-rowbinary', table, store, ->(window) { source_case_path(profile, window) }, profile)

      metadata = checked_success!(process("stock-metadata-#{id}", store,
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"), "stock metadata #{id}")
      RecheckAggregateVariantW225.require_true(metadata.fetch('stdout') == schema_output(profile),
        "stock system.columns declaration differs nominally for #{id}: #{metadata.fetch('stdout').inspect}")
      type_record = checked_success!(process("stock-type-name-#{id}", store,
        "SELECT toTypeName(v) FROM default.#{table} LIMIT 1 FORMAT TSVRaw"), "stock toTypeName #{id}")
      RecheckAggregateVariantW225.require_true(type_record.fetch('stdout') == "#{profile.fetch('declared_type')}\n",
        "stock toTypeName differs from exact nominal declaration for #{id}")
      census = checked_success!(process("stock-part-#{id}", store,
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw"), "stock part census #{id}")
      rows = census.fetch('stdout').lines
      RecheckAggregateVariantW225.require_true(rows.length == 1 && rows[0].end_with?("\n"), "stock part census row count differs for #{id}")
      fields = rows[0].sub(/\n\z/, '').split("\t", -1)
      expected_part = source_part_path(profile)
      RecheckAggregateVariantW225.require_true(fields.length == 5 && fields[0] == 'all_1_1_0' && fields[1] == '5' &&
        fields[2] == '4' && fields[3] == 'Wide', "stock part identity/grid differs for #{id}: #{fields.inspect}")
      original_part = File.expand_path(fields[4])
      strict_part_path!(fields[4], original_part, "stock original #{id}")
      part_parent = File.dirname(expected_part)
      Dir.mkdir(part_parent, 0o700)
      FileUtils.cp_r(original_part, expected_part)
      source_inventory = inventory(expected_part)
      source_serialization = JSON.parse(File.binread(File.join(expected_part, 'serialization.json')))
      serialization_expected = { 'columns' => [],
        'propagate_types_serialization_versions_to_nested_types' => true,
        'types_serialization_versions' => { 'string' => R::STRING_VERSIONS.fetch(profile.fetch('profile')) },
        'version' => 1 }
      RecheckAggregateVariantW225.require_true(source_serialization == serialization_expected,
        "stock serialization.json differs for #{id}")
      RecheckAggregateVariantW225.require_true(File.binread(File.join(expected_part, 'metadata_version.txt')).strip == '0' &&
        File.binread(File.join(expected_part, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)',
        "stock part metadata/codec differs for #{id}")
      profile['source_part'] = expected_part
      profile['source_inventory'] = source_inventory
      profile['source_windows'] = windows
      profile['source_schema'] = metadata.fetch('stdout')
      profile['check_output'] = check.fetch('stdout')
      profile['serialization_json'] = source_serialization
      profile['processes'] = [create, insert, check, metadata, type_record, census].map { |item| RecheckAggregateVariantW225.clean_record(item) } +
        windows.values.map { |item| item.fetch('process') }
      RecheckAggregateVariantW225.write_json(File.join(@source_root, 'cases', 'profiles', "#{id}.json"), {
        'id' => id, 'classification' => 'stock_physical_observed', 'requested_type' => profile.fetch('declared_type'),
        'source_type' => profile.fetch('declared_type'), 'canonicalization' => 'exact_declared_type',
        'literal_rowbinary_hex' => [literals.fetch('full_hex')], 'expected_lanes' => profile.fetch('expected_lanes'),
        'schema' => metadata.fetch('stdout'), 'type_name' => type_record.fetch('stdout'),
        'check_output' => check.fetch('stdout'), 'source_inventory' => source_inventory,
        'serialization_json' => source_serialization, 'rowbinary_windows' => windows,
        'processes' => profile.fetch('processes') })
    rescue JSON::ParserError => error
      RecheckAggregateVariantW225.fail!("stock serialization metadata JSON invalid for #{id}: #{error.message}")
    end

    def write_source_matrix
      matrix = { 'format' => FORMAT_MATRIX, 'profile_count' => @profiles.length,
        'source_pin' => @source_pin, 'runtime_pin' => @runtime_pin,
        'row_keys' => R::ROW_KEYS.map(&:to_i), 'mark_rows' => R::MARK_ROWS.map(&:to_i),
        'string_versions' => R::STRING_VERSIONS,
        'variant_discriminator_mode' => 'BASIC',
        'variant_setting' => VARIANT_BASIC_SETTING,
        'profiles' => @profiles.map do |profile|
          profile.reject { |key, _| %w[node processes].include?(key) }
        end }
      path = File.join(@source_root, 'matrix.json')
      RecheckAggregateVariantW225.write_json(path, matrix)
      @source_matrix_sha256 = Digest::SHA256.file(path).hexdigest
    end

    def helper_destination(index, profile)
      parent = File.join(@root, 'generated', 'parts', format('%02d-%s', index, profile.fetch('id')))
      Dir.mkdir(parent, 0o700)
      File.join(parent, 'all_1_1_0')
    end

    def helper_input_profile(profile, index)
      { 'id' => profile.fetch('id'), 'declared_type' => profile.fetch('declared_type'),
        'expected_lanes' => profile.fetch('expected_lanes'), 'librarydest' => helper_destination(index, profile),
        'mark_rows' => profile.fetch('mark_rows'), 'metadata' => profile.fetch('metadata'),
        'profile' => profile.fetch('profile'), 'row_keys' => profile.fetch('row_keys'),
        'rowbinary' => profile.fetch('rowbinary'), 'stockpart' => profile.fetch('source_part'),
        'values' => profile.fetch('values') }
    end

    def validate_lane_records!(rows, profile, where)
      expected = profile.fetch('expected_lanes')
      RecheckAggregateVariantW225.require_true(rows.is_a?(Array) && rows.map { |row| row.fetch('role_path') } == expected.map { |row| row.fetch('role_path') },
        "#{where} role roster differs from independent literal for #{profile.fetch('id')}")
      rows.each_with_index do |row, index|
        literal = expected.fetch(index)
        RecheckAggregateVariantW225.require_true(row.fetch('hex') == literal.fetch('hex') &&
          row.fetch('mark_offsets') == literal.fetch('mark_offsets'), "#{where} bytes/mark offsets differ for #{literal.fetch('role_path')}")
      end
    end

    def validate_consumer_record!(consumer, profile, where)
      require_exact_nominal = consumer.fetch('exact_nominal_states') == true
      scan = consumer.fetch('wide_part_scan')
      offline_values = consumer.fetch('offline_values')
      offline_scan = consumer.fetch('offline_scan')
      RecheckAggregateVariantW225.require_true(require_exact_nominal &&
        scan.fetch('batch_schedule') == [[0, 0, 2], [1, 2, 2], [2, 4, 1]] &&
        scan.fetch('window_rows') == 3 && offline_values.fetch('rows') == 5 &&
        offline_values.fetch('detached_values') == true && offline_scan.fetch('rows') == 5 &&
        offline_scan.fetch('window_rows') == 3,
        "#{where} public consumer shape differs for #{profile.fetch('id')}")
    end

    def validate_helper_part!(part, path, profile, side)
      RecheckAggregateVariantW225.require_true(part.fetch('part_path') == path &&
        part.fetch('schema_declaration') == profile.fetch('declared_type') &&
        part.fetch('source_declaration') == profile.fetch('declared_type') &&
        part.fetch('profile') == profile.fetch('profile') && part.fetch('row_count') == 5 &&
        part.fetch('mark_rows') == profile.fetch('mark_rows') && part.fetch('exact_nominal_states') == true,
        "helper #{side} exact declaration/profile/grid differs for #{profile.fetch('id')}")
      expected_roles = profile.fetch('expected_lanes').map { |lane| lane.fetch('role_path') }
      RecheckAggregateVariantW225.require_true(part.fetch('physical_stream_names') ==
        RecheckAggregateVariantW225.expected_physical_stream_names(profile),
        "helper #{side} physical basename roster differs for #{profile.fetch('id')}")
      reads = part.fetch('mark_reads')
      RecheckAggregateVariantW225.require_true(reads == [
        { 'first_mark' => 0, 'mark_count' => 3, 'rows' => 5 },
        { 'first_mark' => 3, 'mark_count' => 0, 'rows' => 0 },
      ], "helper #{side} mark windows differ for #{profile.fetch('id')}")
      validate_lane_records!(part.fetch('physical_lanes').map do |lane|
        { 'role_path' => lane.fetch('role_path'), 'hex' => lane.fetch('hex'), 'mark_offsets' => lane.fetch('mark_offsets') }
      end, profile, "helper #{side} physical lanes")
      part.fetch('physical_lanes').each do |lane|
        data = File.expand_path(lane.fetch('data_path'))
        mrk = File.expand_path(lane.fetch('mrk2_path'))
        RecheckAggregateVariantW225.require_true(data.start_with?(path + File::SEPARATOR) &&
          mrk.start_with?(path + File::SEPARATOR) && File.file?(data) && File.file?(mrk) &&
          !File.symlink?(data) && !File.symlink?(mrk), "helper #{side} lane paths escaped/invalid for #{profile.fetch('id')}")
      end
    end

    def invoke_helper
      input = { 'format' => FORMAT_INPUT, 'capture_root' => @source_root,
        'profiles' => @profiles.each_with_index.map { |profile, index| helper_input_profile(profile, index) } }
      input_path = File.join(@root, 'generated', 'helper-input.json')
      RecheckAggregateVariantW225.write_json(input_path, input)
      @helper_input_sha256 = Digest::SHA256.file(input_path).hexdigest
      @helper_sha256_before_execute = Digest::SHA256.file(@helper).hexdigest
      RecheckAggregateVariantW225.require_true(@helper_sha256_before_execute == @expected_helper_sha256 &&
        @helper_sha256_before_execute == @helper_sha256_at_start, 'prebuilt helper changed before execution or differs from external pin')
      command = [@helper, input_path, File.join(@root, 'generated'), @source_root]
      record = process('generic-stock-read-library-write-read', @root, nil, timeout: R::HELPER_TIMEOUT_SECONDS, argv: command)
      @helper_sha256_after_execute = Digest::SHA256.file(@helper).hexdigest
      RecheckAggregateVariantW225.require_true(@helper_sha256_after_execute == @expected_helper_sha256 &&
        @helper_sha256_after_execute == @helper_sha256_before_execute, 'prebuilt helper changed during execution or differs from external pin')
      checked_success!(record, 'prebuilt W225 Crystal helper')
      parsed = JSON.parse(record.fetch('stdout'))
      RecheckAggregateVariantW225.require_true(parsed.fetch('format') == FORMAT_HELPER &&
        parsed.fetch('profile_count') == @profiles.length && parsed.fetch('mismatch_count') == 0 &&
        parsed.fetch('profiles').map { |row| row.fetch('id') } == PROFILE_IDS,
        'W225 Crystal helper top-level output roster/contract differs')
      @helper_profiles = parsed.fetch('profiles')
      @helper_process = RecheckAggregateVariantW225.clean_record(record)
      RecheckAggregateVariantW225.write_json(File.join(@root, 'generated', 'helper-output.json'), parsed)
      RecheckAggregateVariantW225.write_json(File.join(@root, 'generated', 'helper-process.json'), @helper_process)
      @helper_profiles.each_with_index do |item, index|
        profile = @profiles.fetch(index)
        id = profile.fetch('id')
        destination = File.join(@root, 'generated', 'parts', format('%02d-%s', index, id), 'all_1_1_0')
        RecheckAggregateVariantW225.require_true(item.fetch('classification') == 'generic_stock_read_library_write_read_observed' &&
          item.fetch('declared_type') == profile.fetch('declared_type') && item.fetch('profile') == profile.fetch('profile') &&
          item.fetch('stockpart') == profile.fetch('source_part') && item.fetch('librarydest') == destination &&
          item.fetch('metadata_values') == profile.fetch('metadata') && item.fetch('tagged_state_values') == profile.fetch('values') &&
          item.fetch('independent_lanes') == profile.fetch('expected_lanes') && item.fetch('exact_nominal_states') == true,
          "helper input/output binding differs for #{id}")
        expected_rb = profile.fetch('rowbinary').merge('matches_independent_literals' => true)
        RecheckAggregateVariantW225.require_true(item.fetch('rowbinary') == expected_rb,
          "helper independent RowBinary fixture differs for #{id}")
        validate_lane_records!(item.fetch('encoded_literal_lanes').map do |lane|
          { 'role_path' => lane.fetch('role_path'), 'hex' => lane.fetch('hex'), 'mark_offsets' => lane.fetch('mark_offsets') }
        end, profile, "helper encoded literal lanes")
        validate_helper_part!(item.fetch('stock'), profile.fetch('source_part'), profile, 'stock')
        validate_helper_part!(item.fetch('library'), destination, profile, 'library')
        validate_consumer_record!(item.fetch('stock_consumers'), profile, 'stock')
        validate_consumer_record!(item.fetch('library_consumers'), profile, 'library')
        generated_inventory = inventory(destination)
        stock_inventory = inventory(profile.fetch('source_part'))
        RecheckAggregateVariantW225.require_true(stock_inventory == profile.fetch('source_inventory'),
          "helper read modified or changed the stock part inventory for #{id}")
        item['generated_part_inventory'] = generated_inventory
        item['stock_part_inventory'] = stock_inventory
        RecheckAggregateVariantW225.write_json(File.join(@root, 'cases', "#{id}-helper.json"), {
          'id' => id, 'classification' => 'generic_stock_read_library_write_read_observed',
          'declared_type' => profile.fetch('declared_type'), 'profile' => profile.fetch('profile'),
          'stockpart' => profile.fetch('source_part'), 'librarydest' => destination,
          'stock_inventory' => stock_inventory, 'generated_part_inventory' => generated_inventory,
          'helper_output_profile' => item })
      end
      # The helper's raw JSON output is immutable evidence and deliberately
      # does not gain runner-computed inventory fields.
      parsed = JSON.parse(File.binread(File.join(@root, 'generated', 'helper-output.json')))
      parsed.fetch('profiles').each_with_index do |item, index|
        item['generated_part_inventory'] = @helper_profiles.fetch(index).fetch('generated_part_inventory')
        item['stock_part_inventory'] = @helper_profiles.fetch(index).fetch('stock_part_inventory')
      end
      @helper_profiles = parsed.fetch('profiles')
    rescue JSON::ParserError => error
      RecheckAggregateVariantW225.fail!("W225 helper stdout is not exactly one JSON value: #{error.message}")
    end

    def create_native_targets
      @profiles.each do |profile|
        id = profile.fetch('id')
        store = File.join(@root, 'stores', 'native', id)
        Dir.mkdir(store, 0o700)
        table = table_name(profile)
        checked_success!(process("native-create-#{id}", store, create_sql(profile, table)), "native CREATE #{id}")
        path_record = checked_success!(process("native-data-path-#{id}", store,
          "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw"), "native data path #{id}")
        data_path = File.expand_path(path_record.fetch('stdout').strip)
        RecheckAggregateVariantW225.require_true(data_path.start_with?(store + File::SEPARATOR) &&
          File.directory?(data_path) && !File.symlink?(data_path) && File.realpath(data_path) == data_path,
          "native table data path escaped or redirected its store for #{id}")
        detached = File.join(data_path, 'detached')
        RecheckAggregateVariantW225.require_true(File.directory?(detached) && !File.symlink?(detached) && File.realpath(detached) == detached,
          "native detached directory is invalid for #{id}")
        @targets[id] = { 'store' => store, 'table' => table, 'data_path' => data_path,
          'detached_path' => File.join(detached, 'all_1_1_0'), 'data_path_process' => RecheckAggregateVariantW225.clean_record(path_record) }
      end
    end

    def attach_one(profile, helper_profile, index)
      id = profile.fetch('id')
      target = @targets.fetch(id)
      generated = File.join(@root, 'generated', 'parts', format('%02d-%s', index, id), 'all_1_1_0')
      generated_inventory = inventory(generated)
      RecheckAggregateVariantW225.require_true(generated_inventory == helper_profile.fetch('generated_part_inventory'),
        "helper-generated inventory differs from its case carrier for #{id}")
      FileUtils.cp_r(generated, target.fetch('detached_path'))
      detached_inventory = inventory(target.fetch('detached_path'))
      RecheckAggregateVariantW225.require_true(detached_inventory == generated_inventory, "detached part copy differs for #{id}")
      attach = checked_success!(process("native-attach-#{id}", target.fetch('store'),
        "ALTER TABLE default.#{target.fetch('table')} ATTACH PART 'all_1_1_0'"), "native ATTACH #{id}")
      check = checked_success!(process("native-check-#{id}", target.fetch('store'),
        "CHECK TABLE default.#{target.fetch('table')} FORMAT TSVRaw"), "native CHECK #{id}")
      RecheckAggregateVariantW225.require_true(check.fetch('stdout') == "all_1_1_0\t1\t\n", "native CHECK result differs for #{id}")
      metadata = checked_success!(process("native-metadata-#{id}", target.fetch('store'),
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{target.fetch('table')}' ORDER BY position FORMAT TSVRaw"), "native metadata #{id}")
      RecheckAggregateVariantW225.require_true(metadata.fetch('stdout') == schema_output(profile),
        "native schema differs nominally for #{id}")
      census = checked_success!(process("native-part-#{id}", target.fetch('store'),
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{target.fetch('table')}' AND active ORDER BY name FORMAT TSVRaw"), "native part census #{id}")
      rows = census.fetch('stdout').lines
      RecheckAggregateVariantW225.require_true(rows.length == 1 && rows[0].end_with?("\n"), "native part census row count differs for #{id}")
      fields = rows[0].sub(/\n\z/, '').split("\t", -1)
      attached = File.join(target.fetch('data_path'), 'all_1_1_0')
      RecheckAggregateVariantW225.require_true(fields.length == 5 && fields[0] == 'all_1_1_0' && fields[1] == '5' &&
        fields[2] == '4' && fields[3] == 'Wide', "native attached part identity/grid differs for #{id}")
      strict_part_path!(fields[4], attached, "native attached #{id}")
      after_inventory = inventory(attached)
      before_map = generated_inventory.each_with_object({}) { |entry, map| map[entry.fetch('path')] = entry }
      after_map = after_inventory.each_with_object({}) { |entry, map| map[entry.fetch('path')] = entry }
      removed = before_map.keys - after_map.keys
      changed = before_map.keys.select { |path| after_map.key?(path) && before_map.fetch(path) != after_map.fetch(path) }
      added = after_map.keys - before_map.keys
      RecheckAggregateVariantW225.require_true(removed.empty? && changed.empty? && added == [INVALIDATED_FILE],
        "ATTACH physical file delta differs for #{id}")
      auxiliary = File.binread(File.join(attached, INVALIDATED_FILE)).split("\n", -1)
      RecheckAggregateVariantW225.require_true(auxiliary.pop == '' && auxiliary.sort == INVALIDATED_NAMES.sort,
        "ATTACH invalidated-system-columns list differs for #{id}")
      columns = File.binread(File.join(attached, 'columns.txt')).force_encoding(Encoding::UTF_8).scrub
      expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{profile.fetch('declared_type')}\n"
      RecheckAggregateVariantW225.require_true(columns == expected_columns, "attached columns.txt declaration differs for #{id}")
      serialization = JSON.parse(File.binread(File.join(attached, 'serialization.json')))
      expected_serialization = { 'columns' => [{ 'exact_num_defaults' => true, 'kind' => 'Default', 'name' => 'pk',
          'num_defaults' => 0, 'num_rows' => 5 }], 'propagate_types_serialization_versions_to_nested_types' => true,
        'types_serialization_versions' => { 'string' => R::STRING_VERSIONS.fetch(profile.fetch('profile')) }, 'version' => 1 }
      RecheckAggregateVariantW225.require_true(serialization == expected_serialization, "attached serialization metadata differs for #{id}")
      RecheckAggregateVariantW225.require_true(File.binread(File.join(attached, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)' &&
        File.binread(File.join(attached, 'metadata_version.txt')).strip == '0' && File.binread(File.join(attached, 'count.txt')).strip == '5',
        "attached part codec/count/metadata version differs for #{id}")
      type_record = checked_success!(process("native-type-name-#{id}", target.fetch('store'),
        "SELECT toTypeName(v) FROM default.#{target.fetch('table')} LIMIT 1 FORMAT TSVRaw"), "native toTypeName #{id}")
      RecheckAggregateVariantW225.require_true(type_record.fetch('stdout') == "#{profile.fetch('declared_type')}\n",
        "attached native toTypeName differs from exact nominal declaration for #{id}")
      windows = run_rowbinary('native-rowbinary', target.fetch('table'), target.fetch('store'),
        ->(window) { File.join(@root, 'cases', "#{id}-#{window}.rowbinary") }, profile)
      record = { 'id' => id, 'classification' => 'native_attached_and_check_observed',
        'declared_type' => profile.fetch('declared_type'), 'native_type' => profile.fetch('declared_type'),
        'canonicalization' => 'exact_declared_type', 'native_schema' => metadata.fetch('stdout').lines.map { |line| line.chomp },
        'stock_part_inventory' => profile.fetch('source_inventory'), 'generated_part_inventory' => generated_inventory,
        'detached_part_inventory' => detached_inventory,
        'attached_part_inventory' => after_inventory, 'removed_paths' => removed, 'changed_paths' => changed,
        'added_paths' => added, 'columns_txt' => columns, 'serialization_json' => serialization,
        'string_serialization_profile' => profile.fetch('profile'),
        'string_serialization_version_expected' => R::STRING_VERSIONS.fetch(profile.fetch('profile')),
        'string_serialization_version_observed' => serialization.fetch('types_serialization_versions').fetch('string'),
        'variant_discriminator_mode' => 'BASIC', 'metadata_version' => '0', 'codec' => 'CODEC(LZ4)',
        'rowbinary_windows' => windows, 'check_output' => check.fetch('stdout'),
        'processes' => [target.fetch('data_path_process'), RecheckAggregateVariantW225.clean_record(attach),
          RecheckAggregateVariantW225.clean_record(check), RecheckAggregateVariantW225.clean_record(metadata),
          RecheckAggregateVariantW225.clean_record(census), RecheckAggregateVariantW225.clean_record(type_record)] }
      @attached_records << record
      RecheckAggregateVariantW225.write_json(File.join(@root, 'cases', "#{id}-attached.json"), record)
    rescue JSON::ParserError => error
      RecheckAggregateVariantW225.fail!("attached serialization JSON invalid for #{id}: #{error.message}")
    end

    def expected_labels
      labels = %w[runtime-version-pin runtime-build-pin generic-stock-read-library-write-read]
      @profiles.each do |profile|
        id = profile.fetch('id')
        labels.concat(%W[stock-create-#{id} stock-insert-#{id} stock-check-#{id} stock-rowbinary-#{id}-full
          stock-rowbinary-#{id}-middle stock-rowbinary-#{id}-empty stock-metadata-#{id} stock-type-name-#{id} stock-part-#{id}])
        labels.concat(%W[native-create-#{id} native-data-path-#{id} native-attach-#{id} native-check-#{id}
          native-metadata-#{id} native-part-#{id} native-type-name-#{id} native-rowbinary-#{id}-full
          native-rowbinary-#{id}-middle native-rowbinary-#{id}-empty])
      end
      labels
    end

    def verify_invocations
      records = @recorder.records
      labels = records.map { |record| record.fetch('label') }
      RecheckAggregateVariantW225.require_true(labels.uniq.length == labels.length && labels.sort == expected_labels.sort,
        'exact W225 paired process invocation roster differs')
      records.each do |record|
        RecheckAggregateVariantW225.require_true(record.fetch('classification') == 'process_success' &&
          record.fetch('exitstatus') == 0 && !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error'),
          "recorded native/helper process was not successful: #{record.fetch('label')}")
      end
    end

    def write_summary(classification)
      return unless @root && File.directory?(@root) && !File.exist?(File.join(@root, 'summary.json'))
      records = @recorder ? @recorder.records : []
      statuses = records.map { |item| item.fetch('classification') }
      summary = { 'format' => FORMAT_SUMMARY, 'mode' => 'paired', 'classification' => classification,
        'success' => classification == 'paired_variant_profiles_observed', 'error' => @fatal,
        'evidence_root' => @root, 'source_root' => @source_root, 'source_matrix_sha256' => @source_matrix_sha256,
        'helper_sha256_expected' => @expected_helper_sha256, 'helper_sha256_observed_at_start' => @helper_sha256_at_start,
        'helper_sha256_observed_before_execute' => @helper_sha256_before_execute,
        'helper_sha256_observed_after_execute' => @helper_sha256_after_execute,
        'helper_input_sha256' => @helper_input_sha256, 'source_pin' => @source_pin, 'runtime_pin' => @runtime_pin,
        'counts' => { 'expected_profiles' => @profiles.length,
          'stock_observed' => @profiles.count { |item| item['source_inventory'] },
          'helper_observed' => @helper_profiles.length, 'native_attached_exact_nominal' => @attached_records.length,
          'processes' => records.length },
        'process_status_counts' => { 'success_exit0' => statuses.count { |status| status == 'process_success' },
          'nonzero_or_signaled' => statuses.count { |status| status == 'process_nonzero_or_signaled_exit' },
          'timeout' => statuses.count { |status| status == 'process_timeout' },
          'spawn_failure' => statuses.count { |status| status == 'spawn_failure' } } }
      RecheckAggregateVariantW225.write_json(File.join(@root, 'summary.json'), summary)
      RecheckAggregateVariantW225.write_json(File.join(@source_root, 'source_pin.json'), @source_pin) if @source_pin
    end
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/recheck_aggregate_variant_w225.rb --clickhouse BIN --helper HELPER --helper-sha256 HEX --source-root EMPTY_DIR --evidence-root EMPTY_DIR\n       ruby scripts/recheck_aggregate_variant_w225.rb --probe-only --clickhouse BIN --source-root EMPTY_DIR --evidence-root EMPTY_DIR'
      opts.on('--probe-only') { options[:probe_only] = true }
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-sha256 HEX') { |value| options[:helper_sha256] = value }
      opts.on('--source-root PATH') { |value| options[:source_root] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    end
    parser.parse!(argv)
    if options[:probe_only]
      require_true(argv.empty? && %i[clickhouse source_root evidence_root].all? { |key| options.key?(key) } &&
        !options.key?(:helper) && !options.key?(:helper_sha256), parser.to_s)
      Probe.new(options).run
    else
      require_true(argv.empty? && %i[clickhouse helper helper_sha256 source_root evidence_root].all? { |key| options.key?(key) }, parser.to_s)
      PairedProbe.new(options).run
    end
  rescue StandardError => error
    warn "W225 probe setup failure: #{error.class}: #{error.message}"
    false
  end
end

exit(RecheckAggregateVariantW225.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
