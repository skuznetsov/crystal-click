#!/usr/bin/env ruby
# Paired stock-ClickHouse and Crystal generic recursive AggregateFunction
# qualification. This runner consumes a separately built Crystal helper; it
# never invokes a compiler or production codec to create expected bytes.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'

module RecheckAggregateRecursiveW224
  extend self

  VERSION = '26.10.1.1201'.freeze
  BUILD_HASH = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  RUNTIME_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  SOURCE_ROOT = '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  SOURCE_PREFIX = '/private/tmp/crystal-click-w224-physical.'.freeze
  EVIDENCE_PREFIX = '/private/tmp/crystal-click-w224-bulk.'.freeze
  FORMAT_SOURCE = 'aggregate_recursive_w224_stock_matrix_v1'.freeze
  FORMAT_INPUT = 'aggregate_recursive_w224_input_v1'.freeze
  FORMAT_HELPER = 'aggregate_recursive_w224_helper_v1'.freeze
  STRING_VERSIONS = { 'single_stream' => 0, 'with_size_stream' => 1 }.freeze
  PROCESS_TIMEOUT_SECONDS = 90
  HELPER_TIMEOUT_SECONDS = 600
  TERM_GRACE_SECONDS = 2
  MEMORY_LIMIT_BYTES = 1_073_741_824
  ROW_KEYS = [11, 22, 33, 44, 55].freeze
  MARK_ROWS = [2, 2, 1].freeze
  NESTED_ARRAY_TYPE = 'Array(Tuple(count AggregateFunction(count), total AggregateFunction(sum, UInt8)))'.freeze
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  STOCK_SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'min_level_for_wide_part=0',
    'compress_marks=0', 'compress_primary_key=0', 'min_compress_block_size=0',
    'max_compress_block_size=4096', 'ratio_of_defaults_for_sparse_serialization=1.0',
    "default_compression_codec='LZ4'", "nullable_serialization_version='basic'",
    "serialization_info_version='with_types'",
    'propagate_types_serialization_versions_to_nested_types=1',
    'allow_suspicious_low_cardinality_types=1', 'flatten_nested=0',
  ].freeze
  SUM_U64_HEX = {
    0 => '0000000000000000', 1 => '0100000000000000', 7 => '0700000000000000',
    17 => '1100000000000000', 255 => 'ff00000000000000',
    256 => '0001000000000000', 4352 => '0011000000000000',
  }.freeze
  SOURCE_SHA256 = {
    'src/AggregateFunctions/AggregateFunctionCount.h' => 'e30c050dcfb8805e1fd5d9525079cc0c7ca660d03b50ecf9c9cf38a303eb2f0a',
    'src/AggregateFunctions/AggregateFunctionSum.cpp' => 'db1bb5a1501bf31bad3f6b48b0942762062733241cd2ba33abb9a43e76d272a6',
    'src/AggregateFunctions/AggregateFunctionSum.h' => '1ced4e3ee877780fd5b5c3547bd6bdd4f4e8c09559702e91838b15871bb9a94d',
    'src/Core/Field.h' => '42fd21be18892643bcfae9962485b0605441fa39e8d56df2a6e13da5554ea0c4',
    'src/DataTypes/DataTypeAggregateFunction.cpp' => '81a26eab248379dd3f055fb716a4e7cb3a5f08a90239116f6df3af5b8c83b4ec',
    'src/DataTypes/DataTypeAggregateFunction.h' => 'f9969a90bcb0653b51643e50d853f1301c30d346311a6c93199a6207ec291334',
    'src/DataTypes/DataTypeArray.cpp' => 'a830a6d44d7bc6424be8053ae6505f3121b4c668a497aa5b1309fadc6bdb3a51',
    'src/DataTypes/DataTypeArray.h' => '660e6f37210922c200a7cbba5f25a0f01d579f79a51611768de72d1a3002be37',
    'src/DataTypes/DataTypeDynamic.h' => '25136ab2047032e8e86b382f3864f92144ee600b150d4e95cb8827a8dbfff2fd',
    'src/DataTypes/DataTypeLowCardinality.cpp' => 'e75ef3196f929ed61313394fe8ba13c0a377446f73fac12f2b2425128d625c5c',
    'src/DataTypes/DataTypeMap.cpp' => 'dfc839fd14ad6f0b726d65cdc266622cc62912cc48adfb60e61bdb0b49752c73',
    'src/DataTypes/DataTypeNested.cpp' => 'bb0cd02e0c94e0bd8520f6c8a83f64c7089fc47e5dc09f9d72e15f81367f16e4',
    'src/DataTypes/DataTypeNullable.cpp' => '68c4e432a0f555712906d796a4db1d950b32abac2d6c2eba4c1117ad39793e64',
    'src/DataTypes/DataTypeTuple.h' => '9ebb2d555efa56456e4d57d873dcdbf231e48c96fcf87fa41d067f8073e9953b',
    'src/DataTypes/IDataType.h' => '6e9befee2cf642d989912710a4857c5a122fb7ba337eafc6b923c10f8eb33d5c',
    'src/DataTypes/Serializations/SerializationAggregateFunction.cpp' => '1fa59453165a7cdb33811e8cf8eb55d7f7b18abd4d28281397470dd217dd4950',
    'src/DataTypes/Serializations/SerializationArray.cpp' => '825295e177ae7f406c1a1c155e0c9e17b4cc39f4747cb1f3fb327b54db043791',
    'src/DataTypes/Serializations/SerializationMap.cpp' => '191c35c896507f303b06b2527277148d748ba5b8c62ffbefbdab739b1a6a8056',
    'src/DataTypes/Serializations/SerializationNullable.cpp' => '7f8f0f97725f21d196beabae47fefcc3bcb32e250f4a1f9a87b37f73eae7c43f',
    'src/DataTypes/Serializations/SerializationTuple.cpp' => '12e38b357204e005fc4780bac7e2e358b0a14357e0e246137414166062a1a884',
  }.freeze

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def safe_label(value)
    value.gsub(/[^A-Za-z0-9_.-]/, '_')
  end

  def write_new(path, bytes)
    File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
  rescue Errno::EEXIST
    fail!("refusing to overwrite W224 evidence: #{path}")
  end

  def write_json(path, object)
    write_new(path, JSON.pretty_generate(object) + "\n")
  end

  def make_dir(path)
    Dir.mkdir(path, 0o700)
  rescue Errno::EEXIST
    fail!("refusing to reuse W224 directory: #{path}")
  end

  def u64(value)
    require_true(value.is_a?(Integer) && value >= 0 && value <= 18_446_744_073_709_551_615,
      "literal UInt64 outside range: #{value.inspect}")
    Array.new(8) { |index| (value >> (index * 8)) & 0xff }.pack('C*').b
  end

  def varuint(value)
    require_true(value.is_a?(Integer) && value >= 0 && value <= 18_446_744_073_709_551_615,
      "literal VarUInt outside range: #{value.inspect}")
    bytes = []
    while value >= 0x80
      bytes << ((value & 0x7f) | 0x80)
      value >>= 7
    end
    bytes << value
    bytes.pack('C*').b
  end

  def sum_state(value)
    hex = SUM_U64_HEX[value]
    fail!("sum(UInt8) state value lacks an independent fixed-width literal: #{value}") unless hex
    [hex].pack('H*').b
  end

  def count_spec(value)
    { 'kind' => 'count', 'value' => value.to_s }
  end

  def sum_spec(value)
    hex = SUM_U64_HEX[value]
    fail!("sum state missing literal for #{value}") unless hex
    { 'kind' => 'state', 'hex' => hex }
  end

  def tuple_spec(count, sum, label = nil)
    fields = [count_spec(count), sum_spec(sum)]
    fields << { 'kind' => 'string', 'value' => label } unless label.nil?
    { 'kind' => 'tuple', 'fields' => fields }
  end

  def fixture_profiles
    arrays = [[1, 7], [], [255], [0, 256, 17], []]
    profile_values = []
    profile_values << {
      'id' => 'array_sum_uint8', 'declared_type' => 'Array(AggregateFunction(sum, UInt8))',
      'profile' => 'single_stream',
      'metadata' => arrays,
      'values' => arrays.map { |items| { 'kind' => 'array', 'items' => items.map { |value| sum_spec(value) } } },
    }

    nested_array_metadata = [
      [[[0, 1], [127, 7]], []], [[[128, 255]]], [[], []], [[], []], [[[16_384, 256]]],
    ]
    nested_rows = [
      [[0, 1], [127, 7]], [[128, 255]], [], [], [[16_384, 256]],
    ]
    nested_values = nested_rows.each_with_index.map do |inner_rows, index|
      # The second mark deliberately has parent rows with nonempty outer
      # children but empty tuple domains at every inner-array site.
      children = if index == 0
                   [{ 'kind' => 'array', 'items' => inner_rows.map { |c, s| tuple_spec(c, s) } }, { 'kind' => 'array', 'items' => [] }]
                 elsif index == 1
                   [{ 'kind' => 'array', 'items' => inner_rows.map { |c, s| tuple_spec(c, s) } }]
                 elsif index == 2 || index == 3
                   [{ 'kind' => 'array', 'items' => [] }, { 'kind' => 'array', 'items' => [] }]
                 else
                   [{ 'kind' => 'array', 'items' => inner_rows.map { |c, s| tuple_spec(c, s) } }]
                 end
      { 'kind' => 'array', 'items' => children }
    end
    profile_values << {
      'id' => 'array_array_tuple_count_sum_empty_child_mark',
      'declared_type' => 'Array(Array(Tuple(AggregateFunction(count), AggregateFunction(sum, UInt8))))',
      'profile' => 'single_stream', 'metadata' => nested_array_metadata, 'values' => nested_values,
    }

    tuple_rows = [[0, 1, ''], [127, 7, 'red'], [128, 255, 'green'], [16_384, 256, 'a'], [5, 17, '']]
    tuple_type = 'Tuple(count AggregateFunction(count), total AggregateFunction(sum, UInt8), label String)'
    [
      ['tuple_count_sum_string_single', 'single_stream'],
      ['tuple_count_sum_string_with_size', 'with_size_stream'],
    ].each do |id, profile|
      profile_values << {
        'id' => id, 'declared_type' => tuple_type, 'profile' => profile,
        'metadata' => tuple_rows,
        'values' => tuple_rows.map { |count, sum, label| tuple_spec(count, sum, label) },
      }
    end

    map_count = [
      [[1, 0], [2, 127]], [], [[3, 128]], [[4, 16_384], [5, 5]], [[6, 0]],
    ]
    map_sum = [
      [[1, 1], [2, 7]], [], [[3, 255]], [[4, 256], [5, 17]], [[6, 0]],
    ]
    [
      ['map_uint8_count', 'Map(UInt8, AggregateFunction(count))', map_count, :count],
      ['map_uint8_sum_uint8', 'Map(UInt8, AggregateFunction(sum, UInt8))', map_sum, :sum],
    ].each do |id, type, rows, state_kind|
      profile_values << {
        'id' => id, 'declared_type' => type, 'profile' => 'single_stream',
        'metadata' => rows,
        'values' => rows.map do |entries|
          { 'kind' => 'map', 'entries' => entries.map do |key, state|
            { 'key' => { 'kind' => 'fixed_u8', 'value' => key },
              'value' => state_kind == :count ? count_spec(state) : sum_spec(state) }
          end }
        end,
      }
    end

    nullable_rows = [
      { 'kind' => 'nullable', 'null' => false, 'value' => tuple_spec(127, 1) },
      { 'kind' => 'nullable', 'null' => true },
      { 'kind' => 'nullable', 'null' => false, 'value' => tuple_spec(128, 255) },
      { 'kind' => 'nullable', 'null' => false, 'value' => tuple_spec(0, 0) },
      { 'kind' => 'nullable', 'null' => true },
    ]
    profile_values << {
      'id' => 'nullable_tuple_count_sum',
      'declared_type' => 'Nullable(Tuple(count AggregateFunction(count), total AggregateFunction(sum, UInt8)))',
      'profile' => 'single_stream',
      'metadata' => [[127, 1], nil, [128, 255], [0, 0], nil],
      'values' => nullable_rows,
    }

    nested = [
      [[0, 1], [127, 7]], [], [[128, 255]], [[16_384, 256], [5, 17], [0, 0]], [],
    ]
    nested_type = 'Nested(count AggregateFunction(count), total AggregateFunction(sum, UInt8))'
    profile_values << {
      'id' => 'nested_count_sum_flatten_nested_0', 'declared_type' => nested_type,
      'profile' => 'single_stream',
      'metadata' => nested,
      'values' => nested.map { |rows| { 'kind' => 'nested', 'rows' => rows.map { |count, sum| tuple_spec(count, sum) } } },
    }

    lc_rows = [[0, 'red'], [127, 'blue'], [128, 'red'], [16_384, ''], [5, 'green']]
    profile_values << {
      'id' => 'tuple_count_low_cardinality_string',
      'declared_type' => 'Tuple(count AggregateFunction(count), label LowCardinality(String))',
      'profile' => 'single_stream',
      'metadata' => lc_rows,
      'values' => lc_rows.map do |count, label|
        { 'kind' => 'tuple', 'fields' => [count_spec(count), { 'kind' => 'low_cardinality', 'value' => { 'kind' => 'string', 'value' => label } }] }
      end,
    }
    profile_values.each_with_index { |item, index| item['row_keys'] = ROW_KEYS; item['mark_rows'] = MARK_ROWS }
    profile_values.freeze
  end

  def append_lane(lanes, role, bytes)
    lanes[role] ||= +''.b
    lanes[role] << bytes.b
  end

  def string_bytes(text)
    raw = text.encode(Encoding::UTF_8).b
    raw
  end

  def string_lanes(lanes, path, text, profile)
    raw = string_bytes(text)
    if profile == 'with_size_stream'
      append_lane(lanes, "#{path}.string_sizes", u64(raw.bytesize))
      append_lane(lanes, "#{path}.data", raw)
    else
      append_lane(lanes, "#{path}.data", varuint(raw.bytesize) + raw)
    end
  end

  def emit_sum_array(lanes, value)
    items = value.fetch('items')
    append_lane(lanes, 'root.sizes', u64(items.length))
    items.each { |item| append_lane(lanes, 'root.elements.data', sum_state_from_spec(item)) }
  end

  def emit_nested_arrays(lanes, value)
    children = value.fetch('items')
    append_lane(lanes, 'root.sizes', u64(children.length))
    children.each do |child|
      tuples = child.fetch('items')
      append_lane(lanes, 'root.elements.sizes', u64(tuples.length))
      tuples.each do |tuple|
        append_lane(lanes, 'root.elements.elements.field.0.data', varuint(tuple.fetch('fields')[0].fetch('value').to_i))
        append_lane(lanes, 'root.elements.elements.field.1.data', sum_state_from_spec(tuple.fetch('fields')[1]))
      end
    end
  end

  def sum_state_from_spec(spec)
    [spec.fetch('hex')].pack('H*').b
  end

  def emit_tuple(lanes, value, profile)
    fields = value.fetch('fields')
    append_lane(lanes, 'root.field.0.data', varuint(fields[0].fetch('value').to_i))
    append_lane(lanes, 'root.field.1.data', sum_state_from_spec(fields[1]))
    string_lanes(lanes, 'root.field.2', fields[2].fetch('value'), profile)
  end

  def emit_map(lanes, value, state_kind)
    entries = value.fetch('entries')
    append_lane(lanes, 'root.sizes', u64(entries.length))
    entries.each do |entry|
      append_lane(lanes, 'root.elements.field.0.data', [entry.fetch('key').fetch('value')].pack('C*').b)
      state = entry.fetch('value')
      append_lane(lanes, 'root.elements.field.1.data', state_kind == :count ? varuint(state.fetch('value').to_i) : sum_state_from_spec(state))
    end
  end

  def emit_nullable_tuple(lanes, value)
    null = value.fetch('null')
    append_lane(lanes, 'root.nulls', null ? "\x01".b : "\x00".b)
    tuple = null ? tuple_spec(0, 0) : value.fetch('value')
    fields = tuple.fetch('fields')
    append_lane(lanes, 'root.nested.field.0.data', varuint(fields[0].fetch('value').to_i))
    append_lane(lanes, 'root.nested.field.1.data', sum_state_from_spec(fields[1]))
  end

  def emit_nested(lanes, value)
    rows = value.fetch('rows')
    append_lane(lanes, 'root.sizes', u64(rows.length))
    rows.each do |tuple|
      fields = tuple.fetch('fields')
      append_lane(lanes, 'root.elements.field.0.data', varuint(fields[0].fetch('value').to_i))
      append_lane(lanes, 'root.elements.field.1.data', sum_state_from_spec(fields[1]))
    end
  end

  def emit_array_tuple(lanes, value)
    rows = value.fetch('items')
    append_lane(lanes, 'root.sizes', u64(rows.length))
    rows.each do |tuple|
      fields = tuple.fetch('fields')
      append_lane(lanes, 'root.elements.field.0.data', varuint(fields[0].fetch('value').to_i))
      append_lane(lanes, 'root.elements.field.1.data', sum_state_from_spec(fields[1]))
    end
  end

  def lc_expected_streams(values, site_path)
    # Independent finite LC(String) part-global literal: default key first,
    # then distinct values in encounter order; IDs are one byte for this table.
    ids_by_mark = []
    dictionary = ['']
    values.each_slice(2) do |rows|
      ids = []
      rows.each do |row|
        text = row.fetch('fields')[1].fetch('value').fetch('value')
        if text.empty?
          ids << 0
        else
          dictionary << text unless dictionary.include?(text)
          ids << dictionary.index(text)
        end
      end
      ids_by_mark << ids
    end
    dictionary_bytes = u64(1) + u64(dictionary.length) + dictionary.map { |text| varuint(string_bytes(text).bytesize) + string_bytes(text) }.join.b
    index_bytes = +''.b
    index_offsets = [0]
    ids_by_mark.each_with_index do |ids, mark|
      unless ids.empty?
        # This finite profile has four keys, so the independently selected
        # UInt8 index representation has type code zero. ClickHouse's flags
        # reserve bits 8 and 10 for global-dictionary/update state.
        flags = 1 << 8
        flags |= (1 << 10) if mark == 0
        index_bytes << u64(flags) << u64(ids.length) << ids.pack('C*').b
      end
      index_offsets << index_bytes.bytesize
    end
    {
      "#{site_path}.dictionary" => { 'hex' => dictionary_bytes.unpack1('H*'), 'offsets' => [8, 8, 8, dictionary_bytes.bytesize] },
      "#{site_path}.indexes" => { 'hex' => index_bytes.unpack1('H*'), 'offsets' => index_offsets },
    }
  end

  def expected_lanes(profile)
    lanes = {}
    offsets = {}
    profile.fetch('values').each_with_index do |value, row|
      case profile.fetch('id')
      when 'array_sum_uint8' then emit_sum_array(lanes, value)
      when 'array_array_tuple_count_sum_empty_child_mark' then emit_nested_arrays(lanes, value)
      when 'tuple_count_sum_string_single', 'tuple_count_sum_string_with_size' then emit_tuple(lanes, value, profile.fetch('profile'))
      when 'map_uint8_count' then emit_map(lanes, value, :count)
      when 'map_uint8_sum_uint8' then emit_map(lanes, value, :sum)
      when 'nullable_tuple_count_sum' then emit_nullable_tuple(lanes, value)
      when 'nested_count_sum_flatten_nested_0'
        value.fetch('kind') == 'array' ? emit_array_tuple(lanes, value) : emit_nested(lanes, value)
      when 'tuple_count_low_cardinality_string'
        fields = value.fetch('fields')
        append_lane(lanes, 'root.field.0.data', varuint(fields[0].fetch('value').to_i))
      else fail!("unlisted expected-lane profile #{profile.fetch('id')}")
      end
      mark_end = row == ROW_KEYS.length - 1 || MARK_ROWS.each_with_index.any? do |rows, mark|
        ROW_KEYS.take(MARK_ROWS.take(mark + 1).sum).length == row + 1
      end
      next unless mark_end
      lanes.keys.each { |role| (offsets[role] ||= [0]) << lanes.fetch(role).bytesize }
    end
    if profile.fetch('id') == 'tuple_count_low_cardinality_string'
      lc_expected_streams(profile.fetch('values'), 'root.field.1').each do |role, record|
        lanes[role] = [record.fetch('hex')].pack('H*').b
        offsets[role] = record.fetch('offsets')
      end
    end
    lanes.keys.each { |role| offsets[role] ||= [0, lanes.fetch(role).bytesize] }
    lanes.sort.each_with_object({}) do |(role, bytes), result|
      role_offsets = offsets.fetch(role)
      # Three real marks plus the terminal coordinate are mandatory even for
      # roles introduced by an LC site after ordinary-lane traversal.
      require_true(role_offsets.length == 4, "#{profile.fetch('id')}/#{role} literal offset cardinality differs")
      result[role] = { 'hex' => bytes.unpack1('H*'), 'offsets' => role_offsets }
    end
  end

  def rowbinary_value(id, value)
    case id
    when 'array_sum_uint8'
      items = value.fetch('items')
      varuint(items.length) + items.map { |item| sum_state_from_spec(item) }.join.b
    when 'array_array_tuple_count_sum_empty_child_mark'
      items = value.fetch('items')
      varuint(items.length) + items.map do |child|
        tuples = child.fetch('items')
        varuint(tuples.length) + tuples.map { |tuple| rowbinary_value('tuple_count_sum', tuple) }.join.b
      end.join.b
    when 'tuple_count_sum'
      fields = value.fetch('fields')
      varuint(fields[0].fetch('value').to_i) + sum_state_from_spec(fields[1])
    when 'tuple_count_sum_string_single', 'tuple_count_sum_string_with_size'
      fields = value.fetch('fields')
      varuint(fields[0].fetch('value').to_i) + sum_state_from_spec(fields[1]) + rowbinary_string(fields[2].fetch('value'))
    when 'map_uint8_count', 'map_uint8_sum_uint8'
      entries = value.fetch('entries')
      varuint(entries.length) + entries.map do |entry|
        [entry.fetch('key').fetch('value')].pack('C*').b + rowbinary_state(entry.fetch('value'))
      end.join.b
    when 'nullable_tuple_count_sum'
      value.fetch('null') ? "\x01".b : "\x00".b + rowbinary_value('tuple_count_sum', value.fetch('value'))
    when 'nested_count_sum_flatten_nested_0'
      rows = value.fetch('rows')
      varuint(rows.length) + rows.map { |tuple| rowbinary_value('tuple_count_sum', tuple) }.join.b
    when 'tuple_count_low_cardinality_string'
      fields = value.fetch('fields')
      varuint(fields[0].fetch('value').to_i) + rowbinary_string(fields[1].fetch('value').fetch('value'))
    else fail!("unlisted rowbinary profile #{id}")
    end
  end

  def rowbinary_state(spec)
    return varuint(spec.fetch('value').to_i) if spec.fetch('kind') == 'count'
    sum_state_from_spec(spec)
  end

  def rowbinary_string(text)
    bytes = string_bytes(text)
    varuint(bytes.bytesize) + bytes
  end

  def expected_rowbinary(profile)
    profile.fetch('values').each_with_index.map do |value, index|
      [ROW_KEYS.fetch(index)].pack('Q<').b + rowbinary_value(profile.fetch('id'), value)
    end
  end

  # This second encoder consumes plain logical metadata, not BinaryValue specs
  # or the fixed state-byte table used by the lane oracle. It independently
  # builds RowBinary input so a malformed literal fixture fails before INSERT.
  def metadata_rowbinary_value(id, value)
    case id
    when 'array_sum_uint8'
      varuint(value.length) + value.map { |state| u64(state) }.join.b
    when 'array_array_tuple_count_sum_empty_child_mark'
      varuint(value.length) + value.map do |child|
        varuint(child.length) + child.map do |count, sum|
          varuint(count) + u64(sum)
        end.join.b
      end.join.b
    when 'tuple_count_sum_string_single', 'tuple_count_sum_string_with_size'
      count, sum, label = value
      varuint(count) + u64(sum) + rowbinary_string(label)
    when 'map_uint8_count'
      varuint(value.length) + value.map do |key, count|
        [key].pack('C*').b + varuint(count)
      end.join.b
    when 'map_uint8_sum_uint8'
      varuint(value.length) + value.map do |key, sum|
        [key].pack('C*').b + u64(sum)
      end.join.b
    when 'nullable_tuple_count_sum'
      value.nil? ? "\x01".b : "\x00".b + varuint(value[0]) + u64(value[1])
    when 'nested_count_sum_flatten_nested_0'
      varuint(value.length) + value.map do |count, sum|
        varuint(count) + u64(sum)
      end.join.b
    when 'tuple_count_low_cardinality_string'
      count, label = value
      varuint(count) + rowbinary_string(label)
    else
      fail!("unlisted metadata RowBinary profile #{id}")
    end
  end

  def metadata_rowbinary(profile)
    profile.fetch('metadata').each_with_index.map do |value, index|
      u64(ROW_KEYS.fetch(index)) + metadata_rowbinary_value(profile.fetch('id'), value)
    end
  end

  def validate_literal_rows!(profile)
    literal_rows = expected_rowbinary(profile)
    metadata_rows = metadata_rowbinary(profile)
    require_true(literal_rows.length == ROW_KEYS.length && metadata_rows.length == ROW_KEYS.length,
      "#{profile.fetch('id')} literal/metadata row count differs")
    literal_rows.each_with_index do |literal, index|
      require_true(literal == metadata_rows.fetch(index),
        "#{profile.fetch('id')} row #{index + 1} literal differs from independent logical metadata: literal=#{literal.unpack1('H*')}, metadata=#{metadata_rows.fetch(index).unpack1('H*')}")
    end
    {
      'validation' => 'pure Ruby spec encoder vs independent logical-metadata RowBinary encoder',
      'before_any_clickhouse_process_for_profile' => true,
      'all_rows_match' => true,
      'rows' => literal_rows.each_with_index.map do |literal, index|
        { 'row_number' => index + 1, 'row_key' => ROW_KEYS.fetch(index),
          'literal_hex' => literal.unpack1('H*'),
          'metadata_hex' => metadata_rows.fetch(index).unpack1('H*'),
          'matches' => true }
      end,
    }
  end

  def stock_process_labels(id)
    %W[stock-create-#{id} stock-insert-#{id} stock-check-#{id} stock-metadata-#{id}
       stock-type-name-#{id} stock-part-#{id} stock-rowbinary-#{id}-full
       stock-rowbinary-#{id}-middle stock-rowbinary-#{id}-empty]
  end

  def source_values_for(profile, source_type)
    return profile.fetch('values') if source_type == profile.fetch('declared_type')
    if profile.fetch('id') == 'nested_count_sum_flatten_nested_0' && source_type == NESTED_ARRAY_TYPE
      return profile.fetch('metadata').map do |rows|
        { 'kind' => 'array', 'items' => rows.map { |count, sum| tuple_spec(count, sum) } }
      end
    end
    fail!("observed stock source type is outside the expected canonicalization roster: #{profile.fetch('id')}=#{source_type}")
  end

  def pin_source!
    require_true(File.directory?(SOURCE_ROOT) && File.realpath(SOURCE_ROOT) == SOURCE_ROOT, 'pinned source root is absent/noncanonical')
    records = SOURCE_SHA256.map do |relative, expected|
      path = File.join(SOURCE_ROOT, relative)
      require_true(File.file?(path) && !File.symlink?(path), "source anchor absent or symlinked: #{relative}")
      actual = Digest::SHA256.file(path).hexdigest
      { 'path' => relative, 'expected_sha256' => expected, 'actual_sha256' => actual, 'matches' => actual == expected }
    end
    require_true(records.all? { |row| row.fetch('matches') }, 'a pinned ClickHouse source file hash differs')
    {
      'source_reference' => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
      'runtime_built_from_this_source_not_asserted' => true,
      'file_hashes' => records,
      'source_laws' => [
        { 'path' => 'src/DataTypes/DataTypeAggregateFunction.h', 'lines' => '51,84-89', 'law' => 'AggregateFunction cannot be directly Nullable; AggregateFunction has no type subtypes.' },
        { 'path' => 'src/DataTypes/DataTypeArray.cpp', 'lines' => '32-35,59-64', 'law' => 'Array accepts nested type and recursively obtains nested serialization.' },
        { 'path' => 'src/DataTypes/DataTypeTuple.h', 'lines' => '38', 'law' => 'Tuple can be directly inside Nullable.' },
        { 'path' => 'src/DataTypes/DataTypeMap.cpp', 'lines' => '88-92,152-155', 'law' => 'Map key predicate rejects Nullable and LowCardinality(Nullable); it contains no AggregateFunction-specific exclusion.' },
        { 'path' => 'src/DataTypes/DataTypeNested.cpp', 'lines' => '51-75', 'law' => 'Nested named fields are represented as array-of-tuples; physical declaration remains a runtime observation.' },
        { 'path' => 'src/DataTypes/DataTypeLowCardinality.cpp', 'lines' => '30-40', 'law' => 'LowCardinality requires inner type opt-in; AggregateFunction and Array do not opt in.' },
        { 'path' => 'src/DataTypes/Serializations/SerializationArray.cpp', 'lines' => '57-65', 'law' => 'RowBinary Array uses VarUInt count then recursive elements.' },
        { 'path' => 'src/DataTypes/Serializations/SerializationNullable.cpp', 'lines' => '184-204', 'law' => 'RowBinary Nullable emits a null byte; nested value only when non-null.' },
        { 'path' => 'src/DataTypes/Serializations/SerializationTuple.cpp', 'lines' => '56-64', 'law' => 'Tuple serializes siblings in declaration order without an outer prefix.' },
        { 'path' => 'src/DataTypes/Serializations/SerializationMap.cpp', 'lines' => '70-80', 'law' => 'RowBinary Map uses VarUInt pair count then key/value pairs.' },
        { 'path' => 'src/AggregateFunctions/AggregateFunctionCount.h', 'lines' => '114-132', 'law' => 'Count state is UInt64 VarUInt.' },
        { 'path' => 'src/AggregateFunctions/AggregateFunctionSum.h', 'lines' => '273-281', 'law' => 'sum(UInt8) state is fixed-width little-endian UInt64.' },
      ],
    }
  end

  def validate_binary!(path)
    full = File.expand_path(path)
    require_true(File.file?(full) && File.executable?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "ClickHouse executable invalid: #{full}")
    actual = Digest::SHA256.file(full).hexdigest
    require_true(actual == RUNTIME_SHA256, "ClickHouse SHA differs: #{actual}")
    full
  end

  def validate_program!(path, label)
    full = File.expand_path(path)
    require_true(File.file?(full) && File.executable?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is not a canonical executable regular file: #{full}")
    full
  end

  def validate_sha256_pin!(value, label)
    require_true(value.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value),
      "#{label} must be exactly 64 lowercase hexadecimal characters")
    value
  end

  def validate_root(path, prefix, label)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full && Dir.children(full).empty?,
      "#{label} must be a fresh, empty, canonical directory")
    require_true(File.dirname(full) == File.realpath('/private/tmp') && full.start_with?(prefix),
      "#{label} must be a direct /private/tmp child with the fixed prefix")
    full
  end

  def terminate_child(waiter)
    return unless waiter && waiter.alive?
    Process.kill('TERM', waiter.pid)
    waiter.join(TERM_GRACE_SECONDS) || Process.kill('KILL', waiter.pid)
  rescue Errno::ESRCH
    nil
  ensure
    waiter.join if waiter
  end

  class Recorder
    def initialize(root, binary)
      @root = root
      @binary = binary
      @sequence = 0
      @records = []
    end

    attr_reader :records

    def run(label, store, sql = nil, input: nil, timeout: PROCESS_TIMEOUT_SECONDS, argv: nil)
      @sequence += 1
      stem = format('%04d-%s', @sequence, RecheckAggregateRecursiveW224.safe_label(label))
      base = File.join(@root, 'invocations', stem)
      command = argv || [@binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
        '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{MEMORY_LIMIT_BYTES}",
        '--print_pretty_type_names=0',
        '--multiquery', '--query', sql]
      RecheckAggregateRecursiveW224.write_new(base + '.argv.json', JSON.pretty_generate({
        'label' => label, 'argv' => command, 'environment' => { 'TZ' => 'UTC' },
        'timeout_seconds' => timeout, 'stdin_bytes' => input && input.bytesize,
        'stdin_sha256' => input && Digest::SHA256.hexdigest(input.b),
      }) + "\n")
      RecheckAggregateRecursiveW224.write_new(base + '.sql', ((sql || '').end_with?("\n") ? (sql || '') : (sql || '') + "\n").b)
      RecheckAggregateRecursiveW224.write_new(base + '.stdin.bin', input.b) if input
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout_data = ''.b
      stderr_data = ''.b
      spawn_error = nil
      timed_out = false
      status = nil
      stdin = stdout = stderr = waiter = nil
      readers = []
      begin
        stdin, stdout, stderr, waiter = Open3.popen3({ 'TZ' => 'UTC' }, *command)
        [stdin, stdout, stderr].each(&:binmode)
        readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
        stdin.write(input.b) if input
        stdin.close
        unless waiter.join(timeout)
          timed_out = true
          RecheckAggregateRecursiveW224.terminate_child(waiter)
        end
        status = waiter.value
        stdout_data = readers[0].value
        stderr_data = readers[1].value
      rescue StandardError => error
        spawn_error = "#{error.class}: #{error.message}"
      ensure
        RecheckAggregateRecursiveW224.terminate_child(waiter) if waiter && waiter.alive?
        [stdin, stdout, stderr].compact.each { |pipe| pipe.close unless pipe.closed? rescue nil }
        readers.each(&:join)
      end
      classification = if spawn_error
                         'spawn_failure'
                       elsif timed_out
                         'process_timeout'
                       elsif status && status.success?
                         'process_success'
                       else
                         'process_nonzero_or_signaled_exit'
                       end
      record = {
        'label' => label, 'classification' => classification,
        'exitstatus' => status && status.exitstatus,
        'signaled' => status && status.signaled? || false,
        'termsig' => status && status.termsig, 'timed_out' => timed_out,
        'duration_ms' => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
        'spawn_error' => spawn_error, 'stdout_bytes' => stdout_data.bytesize,
        'stderr_bytes' => stderr_data.bytesize,
      }
      RecheckAggregateRecursiveW224.write_new(base + '.stdout', stdout_data)
      RecheckAggregateRecursiveW224.write_new(base + '.stderr', stderr_data)
      RecheckAggregateRecursiveW224.write_new(base + '.status.json', JSON.pretty_generate(record) + "\n")
      @records << record
      record.merge('stdout' => stdout_data, 'stderr' => stderr_data, 'path' => base)
    end
  end

  class Probe
    def initialize(options)
      @binary = RecheckAggregateRecursiveW224.validate_binary!(options.fetch(:clickhouse))
      @expected_helper_sha256 = RecheckAggregateRecursiveW224.validate_sha256_pin!(
        options.fetch(:helper_sha256), 'expected helper SHA-256')
      @helper = RecheckAggregateRecursiveW224.validate_program!(options.fetch(:helper), 'prebuilt Crystal helper')
      @helper_sha256_observed_at_start = Digest::SHA256.file(@helper).hexdigest
      RecheckAggregateRecursiveW224.require_true(@helper_sha256_observed_at_start == @expected_helper_sha256,
        "prebuilt Crystal helper SHA-256 differs from external pin: #{@helper_sha256_observed_at_start}")
      @source_root = RecheckAggregateRecursiveW224.validate_root(options.fetch(:source_root), SOURCE_PREFIX, 'stock source root')
      @root = RecheckAggregateRecursiveW224.validate_root(options.fetch(:evidence_root), EVIDENCE_PREFIX, 'evidence root')
      @profiles = RecheckAggregateRecursiveW224.fixture_profiles
      @invocations = []
      @records = []
      @helper_profiles = []
      @construction_records = []
      @fatal = nil
      @recorder = Recorder.new(@root, @binary)
    end

    def run
      prepare_layout
      @source_pin = RecheckAggregateRecursiveW224.pin_source!
      pin_runtime
      capture_stock_profiles
      capture_constructor_probes
      write_source_matrix
      invoke_helper
      create_native_targets
      attach_library_parts
      verify_invocations
      write_summary('paired_recursive_profiles_observed')
      puts "W224 paired recursive bulk profiles=#{@profiles.length}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal ||= "#{error.class}: #{error.message}"
      write_summary('runner_failure_or_observations_differ') rescue nil
      warn "W224 paired probe failure (process failures are not semantic refusals): #{@fatal}"
      false
    end

    private

    def prepare_layout
      %w[invocations stores parts cases generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      %w[invocations stores parts cases].each { |name| Dir.mkdir(File.join(@source_root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'generated', 'parts'), 0o700)
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      Dir.mkdir(File.join(@source_root, 'cases', 'profiles'), 0o700)
      Dir.mkdir(File.join(@source_root, 'cases', 'construction'), 0o700)
      Dir.mkdir(File.join(@source_root, 'stores', 'profiles'), 0o700)
      Dir.mkdir(File.join(@source_root, 'stores', 'construction'), 0o700)
    end

    def checked_success!(record, label)
      RecheckAggregateRecursiveW224.require_true(record.fetch('classification') == 'process_success',
        "#{label} failed as a process; this is not a semantic refusal")
      record
    end

    def diagnostic_messages(record)
      (record.fetch('stdout') + record.fetch('stderr')).lines.each_with_object([]) do |line, messages|
        match = /\ACode: [0-9]+\. DB::Exception: (.*?)(?:\r?\n)?\z/.match(line)
        next unless match
        message = match[1].sub(/\s+\([A-Z_]+\)(?:\s+\(version [^)]+\))?\z/, '')
        messages << message.sub(/\.\z/, '')
      end
    end

    def classify_expected_refusal!(record, expected)
      messages = diagnostic_messages(record)
      if record.fetch('classification') == 'process_nonzero_or_signaled_exit' &&
         record.fetch('exitstatus') && record.fetch('exitstatus').positive? &&
         !record.fetch('signaled') && !record.fetch('timed_out') &&
         !record.fetch('spawn_error') && messages == [expected]
        record['classification'] = 'expected_semantic_refusal'
      else
        record['classification'] = record.fetch('classification') == 'process_success' ?
          'unexpected_success_for_expected_refusal' : 'refusal_diagnostic_or_process_mismatch'
      end
      RecheckAggregateRecursiveW224.require_true(record.fetch('classification') == 'expected_semantic_refusal',
        "constructor probe did not produce the exact source-predicted refusal: #{record.fetch('label')}")
      record
    end

    def capture_constructor_probes
      cases = [
        {
          'id' => 'nullable_aggregate_function',
          'label' => 'constructor-nullable-aggregate-function',
          'sql' => 'CREATE TABLE default.w224_refused_nullable_af (v Nullable(AggregateFunction(sum, UInt8))) ENGINE=Memory',
          'expected' => 'Nested type AggregateFunction(sum, UInt8) cannot be inside Nullable type',
          'source_anchor' => 'src/DataTypes/DataTypeNullable.cpp:29-34',
        },
        {
          'id' => 'low_cardinality_aggregate_function',
          'label' => 'constructor-low-cardinality-aggregate-function',
          'sql' => 'CREATE TABLE default.w224_refused_low_cardinality_af (v LowCardinality(AggregateFunction(sum, UInt8))) ENGINE=Memory',
          'expected' => 'DataTypeLowCardinality is supported only for numbers, strings, Date or DateTime, but got AggregateFunction(sum, UInt8)',
          'source_anchor' => 'src/DataTypes/DataTypeLowCardinality.cpp:30-40; src/DataTypes/IDataType.h:373-374',
        },
      ]
      @construction_records = []
      cases.each do |item|
        store = File.join(@source_root, 'stores', 'construction', item.fetch('id'))
        Dir.mkdir(store, 0o700)
        process = @recorder.run(item.fetch('label'), store, item.fetch('sql'))
        classify_expected_refusal!(process, item.fetch('expected'))
        record = {
          'id' => item.fetch('id'), 'classification' => 'expected_semantic_refusal',
          'expected_diagnostic' => item.fetch('expected'), 'observed_diagnostics' => diagnostic_messages(process),
          'source_anchor' => item.fetch('source_anchor'),
          'process' => process.reject { |key, _| %w[stdout stderr path].include?(key) },
        }
        @construction_records << record
        RecheckAggregateRecursiveW224.write_json(
          File.join(@source_root, 'cases', 'construction', "#{item.fetch('id')}.json"), record)
      end

      item = {
        'id' => 'map_aggregate_function_key',
        'label' => 'constructor-map-aggregate-function-key',
        'sql' => 'CREATE TABLE default.w224_map_af_key (v Map(AggregateFunction(sum, UInt8), UInt8)) ENGINE=Memory',
      }
      store = File.join(@source_root, 'stores', 'construction', item.fetch('id'))
      Dir.mkdir(store, 0o700)
      process = @recorder.run(item.fetch('label'), store, item.fetch('sql'))
      if process.fetch('classification') == 'process_success'
        classification = 'source_constructor_acceptance_observed'
      elsif process.fetch('classification') == 'process_nonzero_or_signaled_exit' &&
            process.fetch('exitstatus') && process.fetch('exitstatus').positive? &&
            !process.fetch('signaled') && !process.fetch('timed_out') &&
            !process.fetch('spawn_error') && !diagnostic_messages(process).empty?
        classification = 'runtime_constructor_refusal_observed'
      else
        RecheckAggregateRecursiveW224.fail!('Map(AF key) constructor process failed without a classifiable ClickHouse result')
      end
      record = {
        'id' => item.fetch('id'), 'classification' => classification,
        'admission_policy' => 'candidate guard only; pinned DataTypeMap key validator rejects Nullable/LowCardinality(Nullable), not AggregateFunction by source predicate',
        'source_anchor' => 'src/DataTypes/DataTypeMap.cpp:88-92,152-154',
        'observed_diagnostics' => diagnostic_messages(process),
        'process' => process.reject { |key, _| %w[stdout stderr path].include?(key) },
      }
      @construction_records << record
      RecheckAggregateRecursiveW224.write_json(
        File.join(@source_root, 'cases', 'construction', "#{item.fetch('id')}.json"), record)
    end

    def pin_runtime
      store = File.join(@source_root, 'stores', 'pins')
      Dir.mkdir(store, 0o700)
      version = checked_success!(@recorder.run('runtime-version-pin', store, 'SELECT version() FORMAT TSVRaw'), 'runtime version')
      RecheckAggregateRecursiveW224.require_true(version.fetch('stdout').strip == VERSION, 'runtime version differs from pin')
      build = checked_success!(@recorder.run('runtime-build-pin', store,
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"), 'runtime build hash')
      RecheckAggregateRecursiveW224.require_true(build.fetch('stdout').strip == "VERSION_GITHASH=#{BUILD_HASH}", 'runtime build hash differs from pin')
      @runtime_pin = { 'version' => VERSION, 'build_hash' => BUILD_HASH,
        'sha256' => Digest::SHA256.file(@binary).hexdigest, 'runtime_source_correlation' => 'not_asserted' }
      RecheckAggregateRecursiveW224.write_json(File.join(@source_root, 'runtime_pin.json'), @runtime_pin)
    end

    def table_name(profile)
      "w224_#{RecheckAggregateRecursiveW224.safe_label(profile.fetch('id'))}"
    end

    def create_sql(profile, table)
      mode = profile.fetch('profile')
      RecheckAggregateRecursiveW224.require_true(STRING_VERSIONS.key?(mode), "unlisted String serialization profile: #{mode}")
      settings = STOCK_SETTINGS + ["string_serialization_version='#{mode}'"]
      "CREATE TABLE default.#{table} (pk UInt64, v #{profile.fetch('declared_type')}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings.join(', ')}"
    end

    def profile_store(profile)
      path = File.join(@source_root, 'stores', 'profiles', RecheckAggregateRecursiveW224.safe_label(profile.fetch('id')))
      Dir.mkdir(path, 0o700)
      path
    end

    def inventory(part)
      RecheckAggregateRecursiveW224.require_true(File.directory?(part) && !File.symlink?(part) && File.realpath(part) == part,
        "part missing, symlinked, or noncanonical: #{part}")
      entries = []
      Find.find(part) do |path|
        next if path == part
        RecheckAggregateRecursiveW224.require_true(!File.symlink?(path), "symlink in part: #{path}")
        next if File.directory?(path)
        RecheckAggregateRecursiveW224.require_true(File.file?(path), "non-file part entry: #{path}")
        entries << { 'path' => path[(part.length + 1)..-1], 'size' => File.size(path),
          'sha256' => Digest::SHA256.file(path).hexdigest }
      end
      entries.sort_by { |entry| entry.fetch('path') }
    end

    def query_path(profile, window)
      File.join(@source_root, 'cases', 'profiles', "#{RecheckAggregateRecursiveW224.safe_label(profile.fetch('id'))}-#{window}.rowbinary")
    end

    def expected_windows(profile)
      RecheckAggregateRecursiveW224.expected_rowbinary(profile)
    end

    def capture_stock_profile(profile, index)
      id = profile.fetch('id')
      table = table_name(profile)
      store = profile_store(profile)
      lanes = RecheckAggregateRecursiveW224.expected_lanes(profile)
      literal_validation = RecheckAggregateRecursiveW224.validate_literal_rows!(profile)
      literals = expected_windows(profile)
      RecheckAggregateRecursiveW224.require_true(literals.length == 5, "#{id} literal fixture row count differs")
      input = literals.join.b
      RecheckAggregateRecursiveW224.write_json(
        File.join(@source_root, 'cases', 'profiles', "#{id}-literal-validation.json"), literal_validation)
      ddl = checked_success!(@recorder.run("stock-create-#{id}", store, create_sql(profile, table)), "stock CREATE #{id}")
      insert = checked_success!(@recorder.run("stock-insert-#{id}", store,
        "INSERT INTO default.#{table} FORMAT RowBinary", input: input), "stock RowBinary INSERT #{id}")
      check = checked_success!(@recorder.run("stock-check-#{id}", store,
        "CHECK TABLE default.#{table} FORMAT TSVRaw"), "stock CHECK #{id}")
      RecheckAggregateRecursiveW224.require_true(check.fetch('stdout') == "all_1_1_0\t1\t\n",
        "stock CHECK result did not validate exactly one part for #{id}")

      files = %w[full middle empty].each_with_object({}) do |window, out|
        output = query_path(profile, window)
        RecheckAggregateRecursiveW224.require_true(!File.exist?(output) && !File.symlink?(output), "refusing to overwrite #{output}")
        predicate = case window
                    when 'full' then ''
                    when 'middle' then ' WHERE pk BETWEEN 22 AND 44'
                    when 'empty' then ' WHERE pk=0'
                    end
        sql = "SELECT pk, v FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{output.gsub("'", "\\'")}' FORMAT RowBinary"
        record = checked_success!(@recorder.run("stock-rowbinary-#{id}-#{window}", store, sql), "stock #{window} RowBinary #{id}")
        indices = window == 'full' ? [0, 1, 2, 3, 4] : (window == 'middle' ? [1, 2, 3] : [])
        expected = indices.map { |row| literals.fetch(row) }.join.b
        actual = File.binread(output)
        RecheckAggregateRecursiveW224.require_true(actual == expected, "stock #{window} RowBinary differs from independent literals for #{id}")
        out[window] = { 'path' => output, 'bytes' => actual.bytesize,
          'sha256' => Digest::SHA256.hexdigest(actual), 'matches_independent_literal' => true,
          'process' => record.reject { |key, _| %w[stdout stderr path].include?(key) } }
      end

      metadata = checked_success!(@recorder.run("stock-metadata-#{id}", store,
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"), "stock metadata #{id}")
      schema_rows = metadata.fetch('stdout').force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp)
      expected_schema = ["pk\tUInt64", "v\t#{profile.fetch('declared_type')}"]
      source_type = profile.fetch('declared_type')
      canonicalization = 'exact_declared_type'
      if id == 'nested_count_sum_flatten_nested_0' && schema_rows != expected_schema
        # Preserve stock's actual canonical declaration as evidence. It is not
        # treated as a qualified nominal Nested profile by this runner version.
        value_row = schema_rows.find { |line| line.start_with?("v\t") }
        source_type = value_row && value_row.split("\t", 2)[1]
        RecheckAggregateRecursiveW224.require_true(schema_rows.length == 2 && schema_rows.first == "pk\tUInt64" && source_type,
          "Nested source schema shape differs instead of canonicalizing the single v column: #{schema_rows.inspect}")
        RecheckAggregateRecursiveW224.require_true(source_type == RecheckAggregateRecursiveW224::NESTED_ARRAY_TYPE,
          "Nested source canonicalized outside the measured Array(Tuple) profile: #{source_type}")
        canonicalization = 'stock_declaration_differs_from_requested_nested'
      else
        RecheckAggregateRecursiveW224.require_true(schema_rows == expected_schema, "stock exact schema differs for #{id}: #{schema_rows.inspect}")
      end
      type_name = checked_success!(@recorder.run("stock-type-name-#{id}", store,
        "SELECT toTypeName(v) FROM default.#{table} LIMIT 1 FORMAT TSVRaw"), "stock type name #{id}")
      observed_type = type_name.fetch('stdout')
      RecheckAggregateRecursiveW224.require_true(observed_type == "#{source_type}\n",
        "stock type name output differs exactly from schema declaration for #{id}: #{observed_type.inspect}")
      observed_type = source_type
      path_record = checked_success!(@recorder.run("stock-part-#{id}", store,
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw"), "stock part census #{id}")
      parts = path_record.fetch('stdout').force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp)
      RecheckAggregateRecursiveW224.require_true(parts.length == 1, "stock part census differs for #{id}")
      fields = parts.first.split("\t", -1)
      RecheckAggregateRecursiveW224.require_true(fields.length == 5 && fields[0] == 'all_1_1_0' && fields[1] == '5' && fields[2] == '4' && fields[3] == 'Wide',
        "stock part identity/grid differs for #{id}: #{fields.inspect}")
      original = File.expand_path(fields[4])
      RecheckAggregateRecursiveW224.require_true(File.directory?(original) && !File.symlink?(original) && File.realpath(original) == original,
        "stock part path invalid for #{id}")
      part_parent = File.join(@source_root, 'parts', RecheckAggregateRecursiveW224.safe_label(id))
      Dir.mkdir(part_parent, 0o700)
      copied = File.join(part_parent, 'all_1_1_0')
      FileUtils.cp_r(original, copied)
      source_inventory = inventory(copied)
      serialization = JSON.parse(File.binread(File.join(copied, 'serialization.json')))
      require_serialization = { 'columns' => [], 'propagate_types_serialization_versions_to_nested_types' => true,
        'types_serialization_versions' => { 'string' => RecheckAggregateRecursiveW224::STRING_VERSIONS.fetch(profile.fetch('profile')) }, 'version' => 1 }
      RecheckAggregateRecursiveW224.require_true(serialization == require_serialization, "stock serialization metadata differs for #{id}")
      RecheckAggregateRecursiveW224.require_true(File.binread(File.join(copied, 'metadata_version.txt')).strip == '0', "stock metadata version differs for #{id}")
      RecheckAggregateRecursiveW224.require_true(File.binread(File.join(copied, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)', "stock codec differs for #{id}")
      physical = { 'source_part_path' => copied, 'original_part_path' => original,
        'inventory' => source_inventory, 'rows' => 5, 'marks_with_terminal' => 4,
        'real_mark_rows' => MARK_ROWS, 'native_part_name' => fields[0], 'part_type' => fields[3],
        'columns_schema' => schema_rows, 'requested_type' => profile.fetch('declared_type'),
        'source_type' => source_type, 'to_type_name' => observed_type,
        'canonicalization' => canonicalization, 'serialization_json' => serialization,
        'string_serialization_profile' => profile.fetch('profile'),
        'string_serialization_version_expected' => RecheckAggregateRecursiveW224::STRING_VERSIONS.fetch(profile.fetch('profile')),
        'string_serialization_version_observed' => serialization.fetch('types_serialization_versions').fetch('string'),
        'metadata_version' => '0', 'default_compression_codec' => 'CODEC(LZ4)',
        'rowbinary_windows' => files }
      profile['source_type'] = source_type
      profile['source_values'] = RecheckAggregateRecursiveW224.source_values_for(profile, source_type)
      profile['source_expected_lanes'] = RecheckAggregateRecursiveW224.expected_lanes(
        profile.merge('values' => profile.fetch('source_values')))
      profile['expected_lanes'] = lanes
      profile['physical'] = physical
      profile['classification'] = canonicalization == 'exact_declared_type' ? 'stock_physical_observed' : 'stock_canonicalization_observed_not_nominally_qualified'
      @records << { 'id' => id, 'classification' => profile.fetch('classification'),
        'requested_type' => profile.fetch('declared_type'), 'source_type' => source_type,
        'canonicalization' => canonicalization, 'physical' => physical }
      RecheckAggregateRecursiveW224.write_json(File.join(@source_root, 'cases', 'profiles', "#{id}.json"), {
        'id' => id, 'classification' => profile.fetch('classification'), 'literal_rowbinary_hex' => literals.map { |row| row.unpack1('H*') },
        'validated_before_insert' => literal_validation.fetch('all_rows_match'),
        'independent_literal_validation' => literal_validation,
        'expected_lanes' => lanes, 'source_expected_lanes' => profile.fetch('source_expected_lanes'),
        'schema' => schema_rows, 'check_output' => check.fetch('stdout'),
        'source_inventory' => source_inventory,
        'processes' => [ddl, insert, check, metadata, type_name, path_record] + files.values.map { |entry| entry.fetch('process') },
      })
      profile
    end

    def capture_stock_profiles
      @profiles.each_with_index { |profile, index| capture_stock_profile(profile, index) }
    end

    def write_source_matrix
      matrix = { 'format' => FORMAT_SOURCE, 'case_count' => @profiles.length,
        'source_observed_count' => @records.length,
        'stock_exact_nominal_count' => @records.count { |row| row.fetch('classification') == 'stock_physical_observed' },
        'nested_canonicalization_is_not_nominal_qualification' => true,
        'source_pin' => @source_pin, 'runtime_pin' => @runtime_pin,
        'construction_cases' => @construction_records,
        'row_keys' => ROW_KEYS, 'real_mark_rows' => MARK_ROWS,
        'profiles' => @profiles.map do |profile|
          profile.reject { |key, _| %w[values source_values expected_lanes source_expected_lanes].include?(key) }
        end }
      RecheckAggregateRecursiveW224.write_json(File.join(@source_root, 'matrix.json'), matrix)
      @source_matrix_sha = Digest::SHA256.file(File.join(@source_root, 'matrix.json')).hexdigest
    end

    def helper_input_profile(profile, index)
      part_parent = File.join(@root, 'generated', 'parts', format('%02d-%s', index, RecheckAggregateRecursiveW224.safe_label(profile.fetch('id'))))
      Dir.mkdir(part_parent, 0o700)
      { 'id' => profile.fetch('id'), 'declared_type' => profile.fetch('declared_type'),
        'source_type' => profile.fetch('source_type'), 'profile' => profile.fetch('profile'),
        'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS, 'values' => profile.fetch('values'),
        'source_values' => profile.fetch('source_values'), 'expected_lanes' => profile.fetch('expected_lanes'),
        'source_expected_lanes' => profile.fetch('source_expected_lanes'),
        'source_part' => profile.fetch('physical').fetch('source_part_path'),
        'library_part' => File.join(part_parent, 'all_1_1_0') }
    end

    def invoke_helper
      input = { 'format' => FORMAT_INPUT, 'capture_root' => @source_root,
        'profiles' => @profiles.each_with_index.map { |profile, index| helper_input_profile(profile, index) } }
      input_path = File.join(@root, 'generated', 'helper-input.json')
      RecheckAggregateRecursiveW224.write_json(input_path, input)
      @helper_input_sha = Digest::SHA256.file(input_path).hexdigest
      @helper_sha256_observed_before_execute = Digest::SHA256.file(@helper).hexdigest
      RecheckAggregateRecursiveW224.require_true(@helper_sha256_observed_before_execute == @expected_helper_sha256 &&
        @helper_sha256_observed_before_execute == @helper_sha256_observed_at_start,
        "prebuilt Crystal helper changed or differs from external SHA-256 pin before execute: #{@helper_sha256_observed_before_execute}")
      command = [@helper, input_path, File.join(@root, 'generated'), @source_root]
      record = @recorder.run('generic-stock-read-library-write-read', @root, timeout: HELPER_TIMEOUT_SECONDS, argv: command)
      @helper_sha256_observed_after_execute = Digest::SHA256.file(@helper).hexdigest
      RecheckAggregateRecursiveW224.require_true(@helper_sha256_observed_after_execute == @expected_helper_sha256 &&
        @helper_sha256_observed_after_execute == @helper_sha256_observed_before_execute,
        "prebuilt Crystal helper changed during execute or differs from external SHA-256 pin: #{@helper_sha256_observed_after_execute}")
      checked_success!(record, 'prebuilt Crystal helper')
      parsed = JSON.parse(record.fetch('stdout'))
      RecheckAggregateRecursiveW224.require_true(parsed.fetch('format') == FORMAT_HELPER && parsed.fetch('profile_count') == @profiles.length && parsed.fetch('mismatch_count') == 0,
        'Crystal helper output contract differs')
      RecheckAggregateRecursiveW224.require_true(parsed.fetch('profiles').map { |row| row.fetch('id') } == @profiles.map { |row| row.fetch('id') },
        'Crystal helper roster/order differs')
      @helper_profiles = parsed.fetch('profiles')
      @helper_process = record.reject { |key, _| %w[stdout stderr path].include?(key) }
      RecheckAggregateRecursiveW224.write_json(File.join(@root, 'generated', 'helper-output.json'), parsed)
      RecheckAggregateRecursiveW224.write_json(File.join(@root, 'generated', 'helper-process.json'), @helper_process)
      @helper_profiles.each_with_index do |item, index|
        profile = @profiles.fetch(index)
        RecheckAggregateRecursiveW224.require_true(item.fetch('classification') == 'generic_stock_read_library_write_read_observed' && item.fetch('declared_type') == profile.fetch('declared_type'),
          "helper did not observe exact library descriptor for #{profile.fetch('id')}")
        RecheckAggregateRecursiveW224.require_true(item.fetch('source_type') == profile.fetch('source_type'),
          "helper source type differs from the stock-observed declaration for #{profile.fetch('id')}")
        RecheckAggregateRecursiveW224.require_true(item.fetch('source').fetch('schema_declaration') == profile.fetch('source_type') &&
          item.fetch('source').fetch('source_declaration') == profile.fetch('source_type') &&
          item.fetch('library').fetch('schema_declaration') == profile.fetch('declared_type') &&
          item.fetch('library').fetch('source_declaration') == profile.fetch('declared_type'),
          "helper reader declaration differs for #{profile.fetch('id')}")
        part = File.expand_path(item.fetch('library_part_path'))
        allowed = File.join(@root, 'generated', 'parts') + File::SEPARATOR
        RecheckAggregateRecursiveW224.require_true(part.start_with?(allowed) && File.directory?(part) && !File.symlink?(part) && File.realpath(part) == part,
          "helper library part escaped generated root for #{profile.fetch('id')}")
        item['library_inventory'] = inventory(part)
        %w[source library].each do |side|
          reader = item.fetch(side)
          RecheckAggregateRecursiveW224.require_true(reader.fetch('row_count') == 5 && reader.fetch('mark_row_counts') == MARK_ROWS,
            "helper #{side} row/mark grid differs for #{profile.fetch('id')}")
        end
        @records << { 'id' => profile.fetch('id'), 'classification' => 'library_helper_observed',
          'declared_type' => profile.fetch('declared_type'), 'library_part_path' => part,
          'library_inventory' => item.fetch('library_inventory') }
      end
    rescue JSON::ParserError => error
      RecheckAggregateRecursiveW224.fail!("Crystal helper stdout is not one JSON value: #{error.message}")
    end

    def create_native_targets
      @targets = {}
      @profiles.each do |profile|
        id = profile.fetch('id')
        store = File.join(@root, 'stores', 'native', RecheckAggregateRecursiveW224.safe_label(id))
        Dir.mkdir(store, 0o700)
        table = table_name(profile)
        checked_success!(@recorder.run("native-create-#{id}", store, create_sql(profile, table)), "native target CREATE #{id}")
        path = checked_success!(@recorder.run("native-data-path-#{id}", store,
          "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw"), "native path #{id}")
        data_path = File.expand_path(path.fetch('stdout').strip)
        RecheckAggregateRecursiveW224.require_true(data_path.start_with?(store + File::SEPARATOR), "native data path escaped store for #{id}")
        detached = File.join(data_path, 'detached')
        RecheckAggregateRecursiveW224.require_true(File.directory?(detached) && !File.symlink?(detached) && File.realpath(detached) == detached,
          "native detached path invalid for #{id}")
        @targets[id] = { 'store' => store, 'table' => table, 'data_path' => data_path,
          'detached_path' => File.join(detached, 'all_1_1_0') }
      end
    end

    def verify_library_rowbinary(profile, target, window, indices)
      predicate = case window
                  when 'full' then ''
                  when 'middle' then ' WHERE pk BETWEEN 22 AND 44'
                  when 'empty' then ' WHERE pk=0'
                  end
      output = File.join(@root, 'cases', "#{profile.fetch('id')}-#{window}.rowbinary")
      sql = "SELECT pk, v FROM default.#{target.fetch('table')}#{predicate} ORDER BY pk INTO OUTFILE '#{output.gsub("'", "\\'")}' FORMAT RowBinary"
      process = checked_success!(@recorder.run("native-rowbinary-#{profile.fetch('id')}-#{window}", target.fetch('store'), sql), "native #{window} RowBinary")
      bytes = File.binread(output)
      expected = indices.map { |row| RecheckAggregateRecursiveW224.expected_rowbinary(profile).fetch(row) }.join.b
      RecheckAggregateRecursiveW224.require_true(bytes == expected, "native #{window} RowBinary differs for #{profile.fetch('id')}")
      { 'path' => output, 'bytes' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes),
        'matches_independent_literal' => true, 'process' => process.reject { |key, _| %w[stdout stderr path].include?(key) } }
    end

    def attach_one(profile, helper_profile)
      id = profile.fetch('id')
      target = @targets.fetch(id)
      generated = File.expand_path(helper_profile.fetch('library_part_path'))
      generated_inventory = inventory(generated)
      FileUtils.cp_r(generated, target.fetch('detached_path'))
      detached_inventory = inventory(target.fetch('detached_path'))
      RecheckAggregateRecursiveW224.require_true(detached_inventory == generated_inventory, "detached part copy differs for #{id}")
      attach = checked_success!(@recorder.run("native-attach-#{id}", target.fetch('store'),
        "ALTER TABLE default.#{target.fetch('table')} ATTACH PART 'all_1_1_0'"), "native ATTACH #{id}")
      check = checked_success!(@recorder.run("native-check-#{id}", target.fetch('store'),
        "CHECK TABLE default.#{target.fetch('table')} FORMAT TSVRaw"), "native CHECK #{id}")
      RecheckAggregateRecursiveW224.require_true(check.fetch('stdout') == "all_1_1_0\t1\t\n", "native CHECK result differs for #{id}")
      metadata = checked_success!(@recorder.run("native-metadata-#{id}", target.fetch('store'),
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{target.fetch('table')}' ORDER BY position FORMAT TSVRaw"), "native metadata #{id}")
      schema_rows = metadata.fetch('stdout').force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp)
      expected_schema = ["pk\tUInt64", "v\t#{profile.fetch('declared_type')}"]
      native_type = profile.fetch('declared_type')
      native_canonicalization = 'exact_declared_type'
      if schema_rows != expected_schema && id == 'nested_count_sum_flatten_nested_0'
        value_row = schema_rows.find { |line| line.start_with?("v\t") }
        native_type = value_row && value_row.split("\t", 2)[1]
        RecheckAggregateRecursiveW224.require_true(schema_rows.length == 2 && schema_rows.first == "pk\tUInt64" &&
          native_type == RecheckAggregateRecursiveW224::NESTED_ARRAY_TYPE,
          "native Nested target schema differs outside exact declaration or measured Array(Tuple) canonicalization: #{schema_rows.inspect}")
        native_canonicalization = 'native_declaration_differs_from_requested_nested'
      else
        RecheckAggregateRecursiveW224.require_true(schema_rows == expected_schema,
          "native exact schema differs for #{id}: #{schema_rows.inspect}")
      end
      part = checked_success!(@recorder.run("native-part-#{id}", target.fetch('store'),
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{target.fetch('table')}' AND active ORDER BY name FORMAT TSVRaw"), "native part census #{id}")
      part_rows = part.fetch('stdout').force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp)
      RecheckAggregateRecursiveW224.require_true(part_rows.length == 1, "native part count differs for #{id}")
      fields = part_rows.first.split("\t", -1)
      attached_part = File.join(target.fetch('data_path'), 'all_1_1_0')
      RecheckAggregateRecursiveW224.require_true(fields.length == 5 && fields[0] == 'all_1_1_0' && fields[1] == '5' && fields[2] == '4' && fields[3] == 'Wide' && File.expand_path(fields[4]) == attached_part,
        "native attached part identity/grid differs for #{id}")
      after = inventory(attached_part)
      before = generated_inventory.each_with_object({}) { |entry, map| map[entry.fetch('path')] = entry }
      after_map = after.each_with_object({}) { |entry, map| map[entry.fetch('path')] = entry }
      removed = before.keys - after_map.keys
      changed = before.keys.select { |path| after_map.key?(path) && before.fetch(path) != after_map.fetch(path) }
      added = after_map.keys - before.keys
      RecheckAggregateRecursiveW224.require_true(removed.empty? && changed.empty? && added == [INVALIDATED_FILE], "ATTACH file delta unexpected for #{id}")
      aux = File.binread(File.join(attached_part, INVALIDATED_FILE)).split("\n", -1)
      RecheckAggregateRecursiveW224.require_true(aux.pop == '' && aux.sort == INVALIDATED_NAMES.sort, "ATTACH auxiliary differs for #{id}")
      columns = File.binread(File.join(attached_part, 'columns.txt')).force_encoding(Encoding::UTF_8).scrub
      expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{profile.fetch('declared_type')}\n"
      RecheckAggregateRecursiveW224.require_true(columns == expected_columns, "library attached exact columns declaration differs for #{id}")
      serialization = JSON.parse(File.binread(File.join(attached_part, 'serialization.json')))
      expected_serialization = { 'columns' => [{ 'exact_num_defaults' => true, 'kind' => 'Default', 'name' => 'pk', 'num_defaults' => 0, 'num_rows' => 5 }],
        'propagate_types_serialization_versions_to_nested_types' => true,
        'types_serialization_versions' => { 'string' => RecheckAggregateRecursiveW224::STRING_VERSIONS.fetch(profile.fetch('profile')) }, 'version' => 1 }
      RecheckAggregateRecursiveW224.require_true(serialization == expected_serialization, "library serialization metadata differs for #{id}")
      RecheckAggregateRecursiveW224.require_true(File.binread(File.join(attached_part, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)' &&
        File.binread(File.join(attached_part, 'metadata_version.txt')).strip == '0' && File.binread(File.join(attached_part, 'count.txt')).strip == '5',
        "library physical metadata differs for #{id}")
      type = checked_success!(@recorder.run("native-type-name-#{id}", target.fetch('store'),
        "SELECT toTypeName(v) FROM default.#{target.fetch('table')} LIMIT 1 FORMAT TSVRaw"), "native type name #{id}")
      RecheckAggregateRecursiveW224.require_true(type.fetch('stdout') == "#{native_type}\n",
        "native type name/schema declaration differ for #{id}")
      windows = { 'full' => verify_library_rowbinary(profile, target, 'full', [0, 1, 2, 3, 4]),
        'middle' => verify_library_rowbinary(profile, target, 'middle', [1, 2, 3]),
        'empty' => verify_library_rowbinary(profile, target, 'empty', []) }
      classification = native_canonicalization == 'exact_declared_type' ?
        'native_attached_and_check_observed' : 'native_attached_with_canonicalization_observed_not_nominally_qualified'
      record = { 'id' => id, 'classification' => classification,
        'declared_type' => profile.fetch('declared_type'), 'native_type' => native_type,
        'canonicalization' => native_canonicalization, 'native_schema' => schema_rows,
        'generated_part_inventory' => generated_inventory,
        'attached_part_inventory' => after, 'removed_paths' => removed, 'changed_paths' => changed,
        'added_paths' => added, 'columns_txt' => columns, 'serialization_json' => serialization,
        'string_serialization_profile' => profile.fetch('profile'),
        'string_serialization_version_expected' => RecheckAggregateRecursiveW224::STRING_VERSIONS.fetch(profile.fetch('profile')),
        'string_serialization_version_observed' => serialization.fetch('types_serialization_versions').fetch('string'),
        'metadata_version' => '0', 'codec' => 'CODEC(LZ4)', 'rowbinary_windows' => windows,
        'check_output' => check.fetch('stdout'), 'processes' => [attach, check, metadata, part, type].map { |item| item.reject { |key, _| %w[stdout stderr path].include?(key) } } }
      @records << record
      RecheckAggregateRecursiveW224.write_json(File.join(@root, 'cases', "#{id}-attached.json"), record)
    rescue JSON::ParserError => error
      RecheckAggregateRecursiveW224.fail!("invalid attached metadata JSON for #{id}: #{error.message}")
    end

    def attach_library_parts
      @profiles.each_with_index { |profile, index| attach_one(profile, @helper_profiles.fetch(index)) }
    end

    def verify_invocations
      @invocations = @recorder.records
      expected = ['runtime-version-pin', 'runtime-build-pin', 'generic-stock-read-library-write-read',
        'constructor-nullable-aggregate-function', 'constructor-low-cardinality-aggregate-function',
        'constructor-map-aggregate-function-key']
      @profiles.each do |profile|
        id = profile.fetch('id')
        expected.concat(RecheckAggregateRecursiveW224.stock_process_labels(id))
        expected.concat(%W[native-create-#{id} native-data-path-#{id} native-attach-#{id} native-check-#{id}
          native-metadata-#{id} native-part-#{id} native-type-name-#{id} native-rowbinary-#{id}-full
          native-rowbinary-#{id}-middle native-rowbinary-#{id}-empty])
      end
      observed = @invocations.map { |item| item.fetch('label') }
      RecheckAggregateRecursiveW224.require_true(observed.uniq.length == observed.length && observed.sort == expected.sort,
        'exact process invocation label roster differs')

      @invocations.each do |item|
        label = item.fetch('label')
        case label
        when 'constructor-nullable-aggregate-function', 'constructor-low-cardinality-aggregate-function'
          RecheckAggregateRecursiveW224.require_true(item.fetch('classification') == 'process_nonzero_or_signaled_exit' &&
            item.fetch('exitstatus') && item.fetch('exitstatus').positive? && !item.fetch('signaled') &&
            !item.fetch('timed_out') && !item.fetch('spawn_error'),
            "expected constructor semantic refusal has the wrong raw process status: #{label}")
        when 'constructor-map-aggregate-function-key'
          map_result = @construction_records.find { |row| row.fetch('id') == 'map_aggregate_function_key' }
          RecheckAggregateRecursiveW224.require_true(map_result &&
            %w[source_constructor_acceptance_observed runtime_constructor_refusal_observed].include?(map_result.fetch('classification')),
            'Map(AF key) lacks an observed constructor result')
          if map_result.fetch('classification') == 'source_constructor_acceptance_observed'
            RecheckAggregateRecursiveW224.require_true(item.fetch('classification') == 'process_success',
              'Map(AF key) acceptance classification disagrees with raw process status')
          else
            RecheckAggregateRecursiveW224.require_true(item.fetch('classification') == 'process_nonzero_or_signaled_exit' &&
              item.fetch('exitstatus') && item.fetch('exitstatus').positive? && !item.fetch('signaled') &&
              !item.fetch('timed_out') && !item.fetch('spawn_error') &&
              !map_result.fetch('observed_diagnostics').empty?,
              'Map(AF key) runtime refusal lacks a diagnostic ClickHouse exit')
          end
        else
          RecheckAggregateRecursiveW224.require_true(item.fetch('classification') == 'process_success',
            "recorded command failed as a process: #{label}")
        end
      end
    end

    def write_summary(classification)
      return unless @root && File.directory?(@root) && !File.exist?(File.join(@root, 'summary.json'))
      records = @recorder.records
      RecheckAggregateRecursiveW224.write_json(File.join(@root, 'summary.json'), {
        'format' => 'aggregate_recursive_w224_summary_v1', 'classification' => classification,
        'success' => classification == 'paired_recursive_profiles_observed', 'error' => @fatal,
        'evidence_root' => @root, 'source_root' => @source_root,
        'source_matrix_sha256' => @source_matrix_sha,
        'helper_sha256_expected' => @expected_helper_sha256,
        'helper_sha256_observed_at_start' => @helper_sha256_observed_at_start,
        'helper_sha256_observed_before_execute' => @helper_sha256_observed_before_execute,
        'helper_sha256_observed_after_execute' => @helper_sha256_observed_after_execute,
        'helper_input_sha256' => @helper_input_sha, 'runtime_pin' => @runtime_pin,
        'counts' => { 'expected_profiles' => @profiles.length,
          'stock_observed' => @profiles.count { |item| item['classification'] == 'stock_physical_observed' },
          'stock_canonicalized_not_nominal' => @profiles.count { |item| item['classification'] == 'stock_canonicalization_observed_not_nominally_qualified' },
          'helper_observed' => @helper_profiles.length,
          'native_attached_exact_nominal' => @records.count { |item| item['classification'] == 'native_attached_and_check_observed' },
          'native_attached_canonicalized_not_nominal' => @records.count { |item| item['classification'] == 'native_attached_with_canonicalization_observed_not_nominally_qualified' },
          'construction_cases' => @construction_records.length,
          'processes' => records.length },
        'process_status_counts' => { 'success_exit0' => records.count { |item| item['classification'] == 'process_success' },
          'nonzero_or_signaled' => records.count { |item| item['classification'] == 'process_nonzero_or_signaled_exit' },
          'timeout' => records.count { |item| item['classification'] == 'process_timeout' },
          'spawn_failure' => records.count { |item| item['classification'] == 'spawn_failure' } },
        'constructor_observations' => @construction_records,
        'semantic_refusal_count' => @construction_records.count { |item| item.fetch('classification') == 'expected_semantic_refusal' },
        'map_af_key_observation' => @construction_records.find { |item| item.fetch('id') == 'map_aggregate_function_key' },
      })
    end
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/recheck_aggregate_recursive_w224.rb --clickhouse BIN --helper CRYSTAL_HELPER --helper-sha256 HEX --source-root EMPTY_DIR --evidence-root EMPTY_DIR'
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-sha256 HEX') { |value| options[:helper_sha256] = value }
      opts.on('--source-root PATH') { |value| options[:source_root] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && %i[clickhouse helper helper_sha256 source_root evidence_root].all? { |key| options.key?(key) }, parser.to_s)
    Probe.new(options).run
  rescue StandardError => error
    warn "W224 recursive runner setup failure: #{error.class}: #{error.message}"
    false
  end
end

exit(RecheckAggregateRecursiveW224.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
