# frozen_string_literal: true

# Independent byte/value reconciliation for the bounded W196 paired Object
# LowCardinality helper. This validates only its four retained String-profile
# witnesses; it is not a general ClickHouse part decoder.

class ObjectSharedLowCardinalityPairedReconcilerW196
  class CheckError < StandardError; end

  INPUT_FORMAT = 'object_shared_low_cardinality_w196_parts_input_v1'.freeze
  OUTPUT_FORMAT = 'object_shared_low_cardinality_w196_parts_helper_v1'.freeze
  PROFILE_IDS = %w[v2_string0 v2_string1 v3_string0 v3_string1].freeze
  MAX_PROFILES = 4
  MAX_RECORDS = 128
  MAX_DATA_BYTES = 1 * 1024 * 1024
  MAX_COUNTER = 64 * 1024 * 1024

  PATH_TYPES = {
    'p' => 'LowCardinality(String)',
    'a' => 'Array(LowCardinality(UInt8))',
  }.freeze
  PATH_BUCKETS = {'p' => 0, 'a' => 1}.freeze
  EVENT_NAMES = {
    'p' => [
      '.dynamic_structure', '.variant_discr_prefix',
      '.LowCardinality(String).dict_prefix', '.variant_discr',
      '.LowCardinality(String).dict', '.LowCardinality(String)',
      '.SharedVariant.size', '.SharedVariant',
    ].freeze,
    'a' => [
      '.dynamic_structure', '.variant_discr_prefix',
      '.Array(LowCardinality(UInt8)).dict_prefix', '.variant_discr',
      '.Array(LowCardinality(UInt8)).size0',
      '.Array(LowCardinality(UInt8)).dict',
      '.Array(LowCardinality(UInt8))', '.SharedVariant.size', '.SharedVariant',
    ].freeze,
  }.freeze
  TYPE_BYTES = {
    'p' => [0x26, 0x15].pack('C*').b.freeze,
    'a' => [0x1e, 0x26, 0x01].pack('C*').b.freeze,
  }.freeze
  ROWS = [
    {'p' => 'red', 'a' => [7, 9]},
    {},
    {'p' => '', 'a' => []},
    {'p' => 'blue', 'a' => [0, 255]},
    {},
    {'p' => 'red', 'a' => [9]},
    {'p' => 'blue', 'a' => []},
    {'p' => '', 'a' => [7, 0]},
  ].freeze
  MARK_ROWS = [2, 2, 2, 2].freeze

  class Cursor
    attr_reader :offset

    def initialize(bytes, label)
      @bytes = bytes
      @label = label
      @offset = 0
    end

    def remaining
      @bytes.bytesize - @offset
    end

    def u8
      fail!('truncated UInt8') if remaining < 1
      value = @bytes.getbyte(@offset)
      @offset += 1
      value
    end

    def u64
      fail!('truncated UInt64') if remaining < 8
      value = @bytes.byteslice(@offset, 8).unpack1('Q<')
      @offset += 8
      value
    end

    def varuint
      start = @offset
      value = 0
      shift = 0
      loop do
        fail!('truncated or overflowing VarUInt') if remaining < 1 || shift >= 64
        byte = u8
        fail!('overflowing VarUInt') if shift == 63 && (byte & 0x7e) != 0
        value |= (byte & 0x7f) << shift
        break if (byte & 0x80).zero?
        shift += 7
      end
      encoded_length = 1
      rest = value
      while rest >= 0x80
        rest >>= 7
        encoded_length += 1
      end
      fail!('noncanonical VarUInt') unless @offset - start == encoded_length
      value
    end

    def bytes(count)
      fail!('invalid or truncated byte extent') unless count.is_a?(Integer) && count >= 0 && count <= remaining
      value = @bytes.byteslice(@offset, count).to_s.b
      @offset += count
      value
    end

    def string
      size = varuint
      fail!('string extent exceeds the bounded lane') if size > MAX_DATA_BYTES
      value = bytes(size).force_encoding(Encoding::UTF_8)
      fail!('dictionary string is invalid UTF-8') unless value.valid_encoding?
      value
    end

    def finish!
      fail!("#{remaining} trailing byte(s)") unless remaining.zero?
      true
    end

    private

    def fail!(message)
      raise CheckError, "#{@label}: #{message}"
    end
  end

  def self.reconcile!(helper_input_hash, helper_output_hash)
    new(helper_input_hash, helper_output_hash).reconcile!
  end

  # Focused byte-level controls prove this reconciler rejects wrong LC
  # policies/IDs and profile-specific callback rosters rather than merely
  # accepting its own shape checks.
  def self.self_test!
    checker = new({}, {})
    leaves = ['red']
    # The actual String key is encoded as VarUInt length + bytes.
    source_index = [0x600, 2].pack('Q<2') + "\x00\x03red".b + [1, 1].pack('Q<C')
    checker.validate_lc_lanes!('', source_index, leaves, 'string', :source, 'self-test stock')
    checker.validate_lc_lanes!('', source_index, leaves, 'string', :library, 'self-test library additional-only')

    # The fixture keeps its reserved default first, but nondefault key order
    # need not match stock when the IDs still resolve to the authored leaves.
    alternate_uint8_index = [0x600, 3].pack('Q<2') + [0, 9, 7].pack('C*') + [2, 2, 1].pack('Q<C*')
    checker.validate_lc_lanes!('', alternate_uint8_index, [7, 9], 'uint8', :library,
                                'self-test library reordered dictionary')

    expect_rejection!('library global dictionary policy') do
      library_dict = [2].pack('Q<') + "\x00\x03red".b
      library_index = [0x500, 1].pack('Q<2') + "\x01".b
      checker.validate_lc_lanes!(library_dict, library_index, leaves, 'string', :library,
                                 'self-test forged library global dictionary')
    end
    expect_rejection!('dictionary that resolves to the wrong literal') do
      wrong_value_index = [0x600, 1].pack('Q<2') + "\x04blue".b + [1, 0].pack('Q<C')
      checker.validate_lc_lanes!('', wrong_value_index, leaves, 'string', :library,
                                 'self-test forged library value')
    end
    expect_rejection!('unreferenced key substituted for reserved default') do
      substituted_default_index = [0x600, 2].pack('Q<2') + "\x01x\x03red".b + [1, 1].pack('Q<C')
      checker.validate_lc_lanes!('', substituted_default_index, leaves, 'string', :library,
                                 'self-test substituted library default')
    end

    %w[p a].each do |path|
      string0_events = checker.event_names(path, 0)
      string1_events = checker.event_names(path, 1)
      checker.validate_events!(named_events(string0_events), path, 0, 0, "self-test #{path} String0")
      checker.validate_events!(named_events(string1_events), path, 1, 0, "self-test #{path} String1")

      string0_spans = checker.event_spans(
        named_events(string0_events), ''.b, path, 0, "self-test #{path} String0"
      )
      string1_spans = checker.event_spans(
        named_events(string1_events), ''.b, path, 1, "self-test #{path} String1"
      )
      raise CheckError, 'self-test String0 unexpectedly requires SharedVariant.size' if string0_spans.key?('.SharedVariant.size')
      raise CheckError, 'self-test String1 omitted SharedVariant.size span' unless string1_spans.key?('.SharedVariant.size')

      expect_rejection!('String1 callback roster missing SharedVariant.size') do
        checker.validate_events!(named_events(string1_events - ['.SharedVariant.size']), path, 1, 0,
                                 "self-test #{path} forged String1")
      end
      expect_rejection!('String0 callback roster added SharedVariant.size') do
        forged = string0_events + ['.SharedVariant.size']
        checker.validate_events!(named_events(forged), path, 0, 0, "self-test #{path} forged String0")
      end
    end
    true
  end

  def self.named_events(names)
    names.map { |name| {'name' => name, 'offset' => 0} }
  end
  private_class_method :named_events

  def self.expect_rejection!(label)
    yield
  rescue CheckError
    true
  else
    raise CheckError, "self-test accepted #{label}"
  end
  private_class_method :expect_rejection!

  def initialize(input, output)
    @input = input
    @output = output
  end

  def reconcile!
    exact_keys!(@input, %w[capture_root format profiles], 'input')
    require!(@input['format'] == INPUT_FORMAT, 'input format differs')
    capture_root = absolute_path!(@input['capture_root'], 'input capture_root')
    input_profiles = @input['profiles']
    require!(input_profiles.is_a?(Array) && input_profiles.length == MAX_PROFILES,
             'input profile array is not the fixed four-profile roster')
    require!(input_profiles.map { |profile| profile.is_a?(Hash) ? profile['id'] : nil } == PROFILE_IDS,
             'input profile IDs/order differ from the fixed roster')

    exact_keys!(@output, %w[format profiles], 'output')
    require!(@output['format'] == OUTPUT_FORMAT, 'helper output format differs')
    output_profiles = @output['profiles']
    require!(output_profiles.is_a?(Array) && output_profiles.length == MAX_PROFILES,
             'helper profile array is not the fixed four-profile roster')
    require!(output_profiles.map { |profile| profile.is_a?(Hash) ? profile['id'] : nil } == PROFILE_IDS,
             'helper profile IDs/order differ from the fixed roster')

    profile_summaries = PROFILE_IDS.each_with_index.map do |id, index|
      validate_profile!(input_profiles.fetch(index), output_profiles.fetch(index), id, capture_root)
    end
    {
      'status' => 'reconciled',
      'scope' => 'four retained W196 profiles; actual LowCardinality(String) and Array(LowCardinality(UInt8)) paths; String profiles 0/1',
      'profiles' => profile_summaries,
      'limitations' => [
        'The reconciler proves only the fixed eight-row, two-bucket v2/v3 witnesses and does not qualify other actual types or arbitrary LowCardinality dictionary schedules.',
        'Chunk schedules are checked from decoded bucket records, including pathless chunks; this is not evidence of a broader physical-format admission boundary.',
      ],
    }
  end

  def validate_profile!(input, output, expected_id, capture_root)
    exact_keys!(input, %w[id library_part shared_version source_part string_version], "input #{expected_id}")
    expected_shared = expected_id.start_with?('v2_') ? 2 : 3
    expected_string = expected_id.end_with?('string0') ? 0 : 1
    require!(input['id'] == expected_id && input['shared_version'] == expected_shared &&
             input['string_version'] == expected_string, "#{expected_id}: input selectors differ")
    source_part = absolute_path!(input['source_part'], "#{expected_id} input source_part")
    library_part = absolute_path!(input['library_part'], "#{expected_id} input library_part")
    require!(source_part.start_with?(capture_root + File::SEPARATOR), "#{expected_id}: source part escapes capture root")

    exact_keys!(output, %w[bucket_count id library library_generation library_part mark_row_counts row_count shared_version source source_part string_version], expected_id)
    require!(output['id'] == expected_id && output['shared_version'] == expected_shared &&
             output['string_version'] == expected_string, "#{expected_id}: output selectors differ")
    require!(output['bucket_count'] == 2 && output['row_count'] == 8 && output['mark_row_counts'] == MARK_ROWS,
             "#{expected_id}: part physical profile differs")
    require!(output['source_part'] == source_part && output['library_part'] == library_part,
             "#{expected_id}: helper output is not bound to its input part paths")

    validate_observation!(output['source'], expected_id, expected_string, :source)
    validate_observation!(output['library'], expected_id, expected_string, :library)
    validate_generation!(output['library_generation'], expected_id)

    {
      'id' => expected_id,
      'shared_version' => expected_shared,
      'string_version' => expected_string,
      'path_records' => output['source']['paths'].length,
      'source_library_values_match' => true,
      'schedule_chunks_per_parent' => expected_shared == 2 ? 1 : 2,
    }
  end

  def validate_observation!(observation, profile_id, string_version, origin)
    label = "#{profile_id} #{origin}"
    exact_keys!(observation, %w[chunk_schedule paths reader table], label)
    expected_schedule = expected_chunk_schedule(profile_id)
    require!(observation['chunk_schedule'] == expected_schedule,
             "#{label}: decoded chunk schedule/path membership differs from the literal witness")

    expected_full = ROWS
    expected_middle = ROWS.slice(2, 4)
    [
      ['reader', observation['reader']],
      ['table', observation['table']],
    ].each do |consumer, windows|
      exact_keys!(windows, %w[full_rows middle_rows zero_rows], "#{label} #{consumer}")
      require!(windows['full_rows'] == expected_full, "#{label} #{consumer}: full rows differ from authored literals")
      require!(windows['middle_rows'] == expected_middle, "#{label} #{consumer}: middle rows differ from authored literals")
      require!(windows['zero_rows'] == [], "#{label} #{consumer}: zero-row read is not empty")
    end

    expected_records = expected_path_records(profile_id)
    records = observation['paths']
    require!(records.is_a?(Array) && records.length <= MAX_RECORDS, "#{label}: path record list is missing or unbounded")
    require!(records.length == expected_records.length, "#{label}: path record count differs from literal schedule")
    records.each_with_index do |record, index|
      validate_path_record!(record, expected_records.fetch(index), profile_id, string_version, origin, index)
    end
    true
  end

  def expected_chunk_schedule(profile_id)
    version = profile_id.start_with?('v2_') ? 2 : 3
    schedule = []
    2.times do |bucket|
      4.times do |parent|
        chunks = version == 2 ? [[parent * 2, 2]] : [[parent * 2, 1], [parent * 2 + 1, 1]]
        chunks.each_with_index do |(start_row, row_count), chunk_index|
          paths = %w[p a].select do |path|
            PATH_BUCKETS.fetch(path) == bucket &&
              ROWS.slice(start_row, row_count).any? { |row| row.key?(path) }
          end
          schedule << {
            'bucket_index' => bucket,
            'parent_index' => parent,
            'parent_row_count' => 2,
            'chunk_index' => chunk_index,
            'row_count' => row_count,
            'path_names' => paths,
          }
        end
      end
    end
    schedule
  end

  def expected_path_records(profile_id)
    version = profile_id.start_with?('v2_') ? 2 : 3
    records = []
    2.times do |bucket|
      4.times do |parent|
        chunks = version == 2 ? [[parent * 2, 2]] : [[parent * 2, 1], [parent * 2 + 1, 1]]
        chunks.each_with_index do |(start_row, row_count), chunk_index|
          %w[p a].each do |path|
            next unless PATH_BUCKETS.fetch(path) == bucket
            values = ROWS.slice(start_row, row_count).map { |row| row[path] }
            next unless values.any? { |value| !value.nil? }
            records << {
              'bucket_index' => bucket,
              'parent_index' => parent,
              'chunk_index' => chunk_index,
              'row_count' => row_count,
              'name' => path,
              'dynamic_types' => [PATH_TYPES.fetch(path)],
              'values' => values.map do |value|
                value.nil? ? nil : {'type' => PATH_TYPES.fetch(path), 'value' => value}
              end,
              'logical_rows' => values,
            }
          end
        end
      end
    end
    records
  end

  def validate_path_record!(record, expected, profile_id, string_version, origin, record_index)
    label = "#{profile_id} #{origin} path[#{record_index}] #{expected.fetch('name')}"
    exact_keys!(record, %w[bucket_index chunk_index data_hex dynamic_types events name parent_index row_count values], label)
    %w[bucket_index parent_index chunk_index row_count name dynamic_types values].each do |key|
      require!(record[key] == expected.fetch(key), "#{label}: #{key} differs from the independent witness")
    end
    data = decode_hex!(record['data_hex'], label)
    path = expected.fetch('name')
    events = validate_events!(record['events'], path, string_version, data.bytesize, label)
    spans = event_spans(events, data, path, string_version, label)
    validate_dynamic_prefix!(spans.fetch('.dynamic_structure'), path, label)
    require_u64!(spans.fetch('.variant_discr_prefix'), 1, "#{label} Variant COMPACT prefix")
    require_u64!(spans.fetch(event_names(path, string_version)[2]), 1, "#{label} LowCardinality key version")
    validate_discriminators!(spans.fetch('.variant_discr'), expected.fetch('logical_rows'), label)

    if expected.fetch('name') == 'a'
      validate_array_sizes!(spans.fetch('.Array(LowCardinality(UInt8)).size0'), expected.fetch('logical_rows'), label)
      dictionary = spans.fetch('.Array(LowCardinality(UInt8)).dict')
      indexes = spans.fetch('.Array(LowCardinality(UInt8))')
      leaves = expected.fetch('logical_rows').compact.flatten
      validate_lc_lanes!(dictionary, indexes, leaves, 'uint8', origin, label)
    else
      dictionary = spans.fetch('.LowCardinality(String).dict')
      indexes = spans.fetch('.LowCardinality(String)')
      leaves = expected.fetch('logical_rows').compact
      validate_lc_lanes!(dictionary, indexes, leaves, 'string', origin, label)
    end

    spill_lanes = event_names(path, string_version).include?('.SharedVariant.size') ?
      %w[.SharedVariant.size .SharedVariant] : ['.SharedVariant']
    require!(spill_lanes.all? { |name| spans.fetch(name).empty? },
             "#{label}: ordinary LowCardinality arm leaked into present shared spill bytes")
    true
  end

  def validate_events!(events, path, string_version, data_size, label)
    expected = event_names(path, string_version)
    require!(events.is_a?(Array) && events.length == expected.length, "#{label}: callback event count differs")
    events.each_with_index do |event, index|
      exact_keys!(event, %w[name offset], "#{label} event[#{index}]")
      require!(event['name'] == expected[index], "#{label}: callback name/order differs at event #{index}")
      offset = event['offset']
      require!(offset.is_a?(Integer) && offset >= 0 && offset <= data_size, "#{label}: callback offset is outside Data")
    end
    offsets = events.map { |event| event.fetch('offset') }
    require!(offsets.each_cons(2).all? { |left, right| left <= right }, "#{label}: callback offsets move backward")
    require!(offsets.first == 0 && offsets.last == data_size, "#{label}: callback tape does not cover complete Data")
    events
  end

  def event_spans(events, data, path, string_version, label)
    expected = event_names(path, string_version)
    require!(events.is_a?(Array) && events.map { |event| event['name'] } == expected,
             "#{label}: profile-specific callback roster differs while slicing Data")
    events.each_with_index.to_h do |event, index|
      start = event.fetch('offset')
      finish = index + 1 < events.length ? events[index + 1].fetch('offset') : data.bytesize
      [event.fetch('name'), data.byteslice(start, finish - start).to_s.b]
    end
  end

  def validate_dynamic_prefix!(bytes, path, label)
    cursor = Cursor.new(bytes, "#{label} Dynamic V3 prefix")
    require!(cursor.u64 == 4, "#{label}: Dynamic version is not V3")
    require!(cursor.varuint == 1, "#{label}: actual roster count is not one")
    expected_type_bytes = TYPE_BYTES.fetch(path)
    require!(cursor.bytes(cursor.remaining) == expected_type_bytes,
             "#{label}: actual roster type bytes differ from the expected LowCardinality arm")
    true
  end

  def validate_discriminators!(bytes, values, label)
    cursor = Cursor.new(bytes, "#{label} Dynamic discriminator")
    require!(cursor.varuint == values.length, "#{label}: discriminator row count differs")
    format = cursor.u8
    expected = values.map { |value| value.nil? ? 0xff : 0 }
    if expected.uniq.length == 1
      require!(format == 1, "#{label}: homogeneous Dynamic arm is not COMPACT")
      require!(cursor.bytes(cursor.remaining).bytes == [expected.first], "#{label}: compact arm discriminator differs")
    else
      require!(format == 0, "#{label}: mixed Dynamic/null rows are not PLAIN")
      require!(cursor.bytes(cursor.remaining).bytes == expected, "#{label}: per-row discriminators differ")
    end
    true
  end

  def validate_array_sizes!(bytes, values, label)
    expected = values.compact.map(&:length)
    require!(bytes.bytesize == expected.length * 8, "#{label}: Array size lane extent differs from actual rows")
    actual = bytes.unpack('Q<*')
    require!(actual == expected, "#{label}: Array size values differ from the authored LC leaves")
    true
  end

  def validate_lc_lanes!(dictionary_bytes, index_bytes, leaves, scalar, origin, label)
    dictionary_label = "#{label} LC dictionary"
    if leaves.empty?
      require!(dictionary_bytes.empty? && index_bytes.empty?, "#{label}: empty LC occurrence emitted dictionary/index body bytes")
      return {'flags' => nil, 'dictionary' => [], 'indexes' => []}
    end

    expected_keys = [scalar == 'string' ? '' : 0]
    leaves.each do |value|
      validate_leaf!(value, scalar, label)
      expected_keys << value unless expected_keys.include?(value)
    end

    require!(%i[source library].include?(origin), "#{label}: LC origin is outside the fixed source/library roster")
    policy_label = origin == :source ? 'stock' : 'library'
    require!(dictionary_bytes.empty?, "#{label}: #{policy_label} additional-only encoding put bytes in the .dict lane")
    cursor = Cursor.new(index_bytes, "#{label} #{policy_label} LC indexes/additional keys")
    flags = cursor.u64
    require!(flags == 0x600, "#{label}: #{policy_label} LC flags are not UInt8/additional/update (0x600)")
    key_count = bounded_count!(cursor.u64, leaves.length + 1, dictionary_label)
    dictionary = read_dictionary_keys(cursor, key_count, scalar, dictionary_label)
    index_count = bounded_count!(cursor.u64, leaves.length, "#{label} #{policy_label} LC index count")
    ids = read_ids(cursor, index_count, dictionary.length, label)
    cursor.finish!

    require!(dictionary.first == expected_keys.first, "#{label}: LowCardinality dictionary omitted its reserved default at index zero")
    require!(dictionary.uniq.length == dictionary.length, "#{label}: LowCardinality dictionary contains duplicate keys")
    require!(dictionary.sort_by(&:to_s) == expected_keys.uniq.sort_by(&:to_s),
             "#{label}: dictionary keys differ from the authored leaves plus the reserved default")
    decoded = ids.map { |id| dictionary.fetch(id) }
    require!(decoded == leaves, "#{label}: LC indexes resolve to values different from the authored leaves")
    {'flags' => flags, 'dictionary' => dictionary, 'indexes' => ids}
  rescue IndexError => error
    raise CheckError, "#{label}: LC index references absent key (#{error.message})"
  end

  def read_dictionary_keys(cursor, count, scalar, label)
    require!(count.positive? && count <= 1_000_000, "#{label}: dictionary key count is outside bounds")
    Array.new(count) do
      if scalar == 'string'
        cursor.string
      else
        cursor.u8
      end
    end
  end

  def read_ids(cursor, count, dictionary_size, label)
    require!(count == 0 || dictionary_size.positive?, "#{label}: nonempty index vector has no dictionary")
    Array.new(count) do
      id = cursor.u8 # Witness cardinality keeps the LC index width at UInt8.
      require!(id < dictionary_size, "#{label}: UInt8 dictionary index is out of range")
      id
    end
  end

  def validate_leaf!(value, scalar, label)
    if scalar == 'string'
      require!(value.is_a?(String), "#{label}: String LC leaf is not a String")
    else
      require!(value.is_a?(Integer) && value.between?(0, 255), "#{label}: UInt8 LC leaf is outside range")
    end
  end

  def validate_generation!(generation, profile_id)
    label = "#{profile_id} library_generation"
    exact_keys!(generation, %w[codec_work transport_work], label)
    exact_keys!(generation['codec_work'], %w[elements nodes wire_bytes], "#{label} codec_work")
    exact_keys!(generation['transport_work'], %w[decoded_bytes file_bytes records result_bytes], "#{label} transport_work")
    generation['codec_work'].each do |name, value|
      bounded_counter!(value, "#{label} codec_work.#{name}", MAX_COUNTER)
    end
    generation['transport_work'].each do |name, value|
      bounded_counter!(value, "#{label} transport_work.#{name}", MAX_COUNTER)
    end
    require!(generation['codec_work'].values.all?(&:positive?), "#{label}: codec generation work is empty")
    require!(generation['transport_work'].values.all?(&:positive?), "#{label}: transport generation work is empty")
    true
  end

  def bounded_count!(value, maximum, label)
    require!(value.is_a?(Integer) && value >= 0 && value <= maximum, "#{label}: count exceeds witness bound")
    value
  end

  def bounded_counter!(value, label, maximum)
    require!(value.is_a?(Integer) && value.positive? && value <= maximum, "#{label}: work counter is nonpositive or outside its bound")
    value
  end

  def decode_hex!(hex, label)
    require!(hex.is_a?(String) && hex.bytesize.even? && hex.bytesize / 2 <= MAX_DATA_BYTES &&
             hex.match?(/\A[0-9a-f]+\z/), "#{label}: Data hex is malformed or unbounded")
    [hex].pack('H*').b
  end

  def require_u64!(bytes, expected, label)
    require!(bytes.bytesize == 8 && bytes.unpack1('Q<') == expected, "#{label}: eight-byte value differs")
    true
  end

  def event_names(path, string_version)
    names = EVENT_NAMES.fetch(path) { raise CheckError, "unknown witness path #{path.inspect}" }
    case string_version
    when 0
      names.reject { |name| name == '.SharedVariant.size' }
    when 1
      names
    else
      raise CheckError, "unsupported String profile #{string_version.inspect}"
    end
  end

  def absolute_path!(value, label)
    require!(value.is_a?(String) && !value.empty? && value.start_with?(File::SEPARATOR), "#{label} is not an absolute path")
    expanded = File.expand_path(value)
    require!(expanded == value, "#{label} is not canonical")
    value
  end

  def exact_keys!(value, keys, label)
    require!(value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) } && value.keys.sort == keys.sort,
             "#{label}: object fields differ from the exact schema")
  end

  def require!(condition, message)
    raise CheckError, message unless condition
  end
end
