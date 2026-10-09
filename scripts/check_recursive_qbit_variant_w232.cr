require "../src/crystal_click"
require "json"

module CheckRecursiveQBitVariantW232
  extend self

  INPUT_FORMAT    = "recursive_qbit_variant_w232_helper_input_v1"
  OUTPUT_FORMAT   = "recursive_qbit_variant_w232_helper_output_v1"
  SOURCE_PREFIX   = "crystal-click-w232-stock."
  EVIDENCE_PREFIX = "crystal-click-w232-evidence."
  PROFILE_TYPES   = {
    "root_variant"            => "Variant(QBit(Int8, 9), UInt64)",
    "array_variant"           => "Array(Variant(QBit(Int8, 9), UInt64))",
    "variant_array_tuple_map" => "Variant(Array(QBit(Int8, 9)), Map(String, QBit(Int8, 9)), Tuple(q QBit(Int8, 9), n UInt8))",
  }
  ROW_KEYS      = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  MARK_ROWS     = [2_u64, 2_u64, 2_u64]
  FULL_SCHEDULE = [
    {0, 0_u64, 0_u64, 0_u64},
    {1, 0_u64, 2_u64, 2_u64},
    {2, 0_u64, 4_u64, 4_u64},
  ]
  MAX_INPUT_BYTES = 64 * 1024
  MAX_ROW_BYTES   = 64 * 1024
  MAX_ITEMS       = 128
  MAX_QBIT_BYTES  = 16 * 1024
  MAX_DEPTH       = 24

  private class FixtureBudget
    @items = 0
    @qbit_bytes = 0
    @nodes = 0

    def visit!(depth : Int32) : Nil
      raise CrystalClick::BoundsError.new("W232 fixture exceeds recursive depth bound") if depth > CheckRecursiveQBitVariantW232::MAX_DEPTH
      raise CrystalClick::BoundsError.new("W232 fixture exceeds node bound") if (@nodes += 1) > 4096
    end

    def collection!(count : Int32) : Nil
      raise CrystalClick::BoundsError.new("W232 fixture collection exceeds item bound") if count < 0 || count > CheckRecursiveQBitVariantW232::MAX_ITEMS
      raise CrystalClick::BoundsError.new("W232 fixture exceeds aggregate item bound") if (@items += count) > CheckRecursiveQBitVariantW232::MAX_ITEMS
    end

    def qbit!(count : Int32) : Nil
      raise CrystalClick::BoundsError.new("W232 fixture exceeds QBit byte bound") if count < 0 || (@qbit_bytes += count) > CheckRecursiveQBitVariantW232::MAX_QBIT_BYTES
    end
  end

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W232 Variant/QBit helper: #{message}") unless condition
  end

  private def exact_keys!(hash : Hash(String, JSON::Any), expected : Array(String), label : String) : Nil
    require!(hash.keys.sort == expected.sort, "#{label} fields differ")
  end

  private def canonical_dir(path : String, label : String) : String
    full = File.expand_path(path)
    info = File.info?(full, follow_symlinks: false) || raise CrystalClick::InvalidPartError.new("#{label} is missing")
    require!(info.directory? && !info.type.symlink? && File.realpath(full) == full, "#{label} is not a canonical directory")
    full
  end

  private def fixed_capture_root(path : String, prefix : String, label : String) : String
    full = canonical_dir(path, label)
    basename = File.basename(full)
    require!(File.dirname(full) == File.realpath("/private/tmp") && basename.starts_with?(prefix) && basename.size > prefix.size,
      "#{label} is not a direct /private/tmp child with a fresh W232 prefix")
    full
  end

  private def canonical_part(path : String, label : String) : String
    full = File.expand_path(path)
    info = File.info?(full, follow_symlinks: false) || raise CrystalClick::InvalidPartError.new("#{label} is missing")
    require!(info.directory? && !info.type.symlink? && File.realpath(full) == full, "#{label} is not a canonical part")
    full
  end

  private def nibble(byte : UInt8) : UInt8
    if byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
      return (byte - '0'.ord.to_u8).to_u8
    end
    if byte >= 'a'.ord.to_u8 && byte <= 'f'.ord.to_u8
      return (byte - 'a'.ord.to_u8 + 10).to_u8
    end
    raise ArgumentError.new("W232 fixture hex must be lowercase")
  end

  private def decode_hex(hex : String) : Bytes
    unless hex.bytesize.even? && hex.matches?(/\A(?:[0-9a-f]{2})*\z/)
      raise ArgumentError.new("W232 fixture hex must be even lowercase hexadecimal")
    end
    Bytes.new(hex.bytesize // 2) do |index|
      ((nibble(hex.byte_at(index * 2)) << 4) | nibble(hex.byte_at(index * 2 + 1))).to_u8
    end
  end

  private def encode_hex(bytes : Bytes) : String
    String.build { |io| bytes.each { |byte| io << byte.to_s(16).rjust(2, '0') } }
  end

  private def uint64_le(value : UInt64) : Bytes
    Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end

  private def rowbinary_row(key : UInt64, value : CrystalClick::BinaryValue) : Bytes
    key_bytes = uint64_le(key)
    value_bytes = CrystalClick::BinaryValueCodec.encode_value(value)
    Bytes.new(key_bytes.size + value_bytes.size) do |index|
      index < key_bytes.size ? key_bytes[index] : value_bytes[index - key_bytes.size]
    end
  end

  private def require_literals!(keys : Array(UInt64), values : Array(CrystalClick::BinaryValue), literals : Array(String), id : String, label : String) : Nil
    require!(keys.size == ROW_KEYS.size && values.size == ROW_KEYS.size && literals.size == ROW_KEYS.size,
      "#{id} #{label} row roster differs")
    ROW_KEYS.each_with_index do |key, index|
      require!(keys[index] == key, "#{id} #{label} key differs at row #{index}")
      require!(rowbinary_row(key, values[index]) == decode_hex(literals[index]),
        "#{id} #{label} RowBinary differs from independent literal at row #{index}")
    end
    nil
  end

  private def variant_index(type : CrystalClick::BinaryDataType, alternative : String) : Int32
    type.children.index { |child| child.name == alternative } ||
      raise CrystalClick::CorruptPartError.new("W232 selected Variant alternative is absent: #{alternative}")
  end

  private def value_from_json(type : CrystalClick::BinaryDataType, raw : JSON::Any, budget : FixtureBudget, depth : Int32 = 0) : CrystalClick::BinaryValue
    budget.visit!(depth)
    case type.tag
    when CrystalClick::BinaryDataType::TAG_QBIT
      fields = raw.as_h
      exact_keys!(fields, ["hex", "kind"], "QBit value")
      require!(fields["kind"].as_s == "qbit", "QBit fixture kind differs")
      qbit_type = type.qbit_type || raise CrystalClick::CorruptPartError.new("QBit descriptor lost its nominal type")
      bytes = decode_hex(fields["hex"].as_s)
      require!(bytes.size == qbit_type.raw_row_bytes && bytes.size <= MAX_ROW_BYTES, "QBit fixture width differs")
      budget.qbit!(bytes.size)
      CrystalClick::BinaryValue.qbit(type, CrystalClick::QBitValue.new(qbit_type, bytes))
    when CrystalClick::BinaryDataType::TAG_VARIANT
      fields = raw.as_h
      kind = fields["kind"].as_s
      if kind == "variant_null"
        exact_keys!(fields, ["kind"], "Variant NULL")
        CrystalClick::BinaryValue.variant_null(type)
      elsif kind == "variant"
        exact_keys!(fields, ["alternative", "kind", "value"], "Variant value")
        alternative = fields["alternative"].as_s
        index = variant_index(type, alternative)
        child = value_from_json(type.child_at(index), fields["value"], budget, depth + 1)
        CrystalClick::BinaryValue.variant(type, index, child)
      else
        raise CrystalClick::CorruptPartError.new("unlisted W232 Variant fixture kind")
      end
    when CrystalClick::BinaryDataType::TAG_ARRAY
      fields = raw.as_h
      exact_keys!(fields, ["items", "kind"], "Array")
      require!(fields["kind"].as_s == "array", "Array fixture kind differs")
      items = fields["items"].as_a
      budget.collection!(items.size)
      children = items.map { |item| value_from_json(type.child_at(0), item, budget, depth + 1) }
      CrystalClick::BinaryValue.array(type, children)
    when CrystalClick::BinaryDataType::TAG_MAP
      fields = raw.as_h
      exact_keys!(fields, ["entries", "kind"], "Map")
      require!(fields["kind"].as_s == "map", "Map fixture kind differs")
      key_type = type.child_at(0)
      value_type = type.child_at(1)
      require!(key_type.tag == CrystalClick::BinaryDataType::TAG_STRING, "W232 Map fixture key type is not String")
      entries = fields["entries"].as_a
      budget.collection!(entries.size)
      flat = [] of CrystalClick::BinaryValue
      entries.each do |entry|
        pair = entry.as_a
        require!(pair.size == 2, "Map fixture entry is not a pair")
        key = pair[0].as_s
        require!(key.bytesize <= MAX_ROW_BYTES, "Map String key exceeds byte bound")
        flat << CrystalClick::BinaryValue.string(key)
        flat << value_from_json(value_type, pair[1], budget, depth + 1)
      end
      CrystalClick::BinaryValue.map(type, flat)
    when CrystalClick::BinaryDataType::TAG_NAMED_TUPLE, CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE
      fields = raw.as_h
      exact_keys!(fields, ["fields", "kind"], "Tuple")
      require!(fields["kind"].as_s == "tuple", "Tuple fixture kind differs")
      values = fields["fields"].as_a
      require!(values.size == type.child_count, "Tuple field count differs")
      budget.collection!(values.size)
      children = values.each_with_index.map { |value, index| value_from_json(type.child_at(index), value, budget, depth + 1) }.to_a
      CrystalClick::BinaryValue.tuple(type, children)
    when CrystalClick::BinaryDataType::TAG_STRING
      fields = raw.as_h
      exact_keys!(fields, ["kind", "value"], "String")
      require!(fields["kind"].as_s == "string", "String fixture kind differs")
      text = fields["value"].as_s
      require!(text.bytesize <= MAX_ROW_BYTES, "String fixture exceeds byte bound")
      CrystalClick::BinaryValue.string(text)
    when CrystalClick::BinaryDataType::TAG_UINT8, CrystalClick::BinaryDataType::TAG_UINT64
      fields = raw.as_h
      exact_keys!(fields, ["kind", "value"], "unsigned integer")
      expected_kind = type.tag == CrystalClick::BinaryDataType::TAG_UINT8 ? "uint8" : "uint64"
      require!(fields["kind"].as_s == expected_kind, "unsigned integer fixture kind differs")
      number = fields["value"].as_i64
      width = type.fixed_width.not_nil!.to_i
      maximum = type.tag == CrystalClick::BinaryDataType::TAG_UINT8 ? 255_i64 : Int64::MAX
      require!(number >= 0 && number <= maximum, "unsigned integer fixture is out of range")
      bytes = Bytes.new(width) { |index| ((number.to_u64 >> (index * 8)) & 0xff_u64).to_u8 }
      CrystalClick::BinaryValue.fixed(type, bytes)
    else
      raise CrystalClick::UnsupportedFormatError.new("W232 fixture contains an unlisted type: #{type.name}")
    end
  end

  private def parse_rows(rows : Array(JSON::Any), type : CrystalClick::BinaryDataType, id : String) : Array(CrystalClick::BinaryValue)
    require!(rows.size == ROW_KEYS.size, "#{id} must contain six rows")
    budget = FixtureBudget.new
    values = rows.map { |row| value_from_json(type, row, budget) }
    values.each_with_index { |value, index| require!(value.type == type, "#{id} row #{index} lost its exact descriptor") }
    values
  end

  private def collect_scan(table : CrystalClick::WidePartTable, type : CrystalClick::BinaryDataType, id : String, label : String) : Tuple(Array(UInt64), Array(CrystalClick::BinaryValue), Array(Tuple(Int32, UInt64, UInt64, UInt64)))
    keys = [] of UInt64
    values = [] of CrystalClick::BinaryValue
    schedule = [] of Tuple(Int32, UInt64, UInt64, UInt64)
    table.scan_typed(batch_rows: 2) do |batch|
      require!(batch.column_type_for("v") == type.name, "#{id} #{label} callback nominal type differs")
      keys.concat(batch.values_for("id", UInt64).to_a)
      values.concat(batch.binary_bulk_values_for("v").to_a)
      schedule << {batch.mark_index, batch.mark_row_offset, batch.part_row_offset, batch.source_row_offset}
    end
    require!(schedule == FULL_SCHEDULE, "#{id} #{label} full scan schedule differs")
    values.each { |value| require!(value.type == type, "#{id} #{label} full scan descriptor differs") }
    {keys, values, schedule}
  end

  private def schedule_json(schedule : Array(Tuple(Int32, UInt64, UInt64, UInt64))) : JSON::Any
    JSON::Any.new(schedule.map do |entry|
      JSON::Any.new([JSON::Any.new(entry[0].to_i64), JSON::Any.new(entry[1].to_i64),
                     JSON::Any.new(entry[2].to_i64), JSON::Any.new(entry[3].to_i64)])
    end)
  end

  private def scan_windows!(part : String, type : CrystalClick::BinaryDataType, expected : Array(CrystalClick::BinaryValue), literals : Array(String), full_keys : Array(UInt64), full_values : Array(CrystalClick::BinaryValue), full_schedule : Array(Tuple(Int32, UInt64, UInt64, UInt64)), id : String, label : String) : JSON::Any
    table = CrystalClick::WidePartTable.open_selected_typed([part], ["id", "v"])
    keys = [] of UInt64
    middle = [] of CrystalClick::BinaryValue
    middle_schedule = [] of Tuple(Int32, UInt64, UInt64, UInt64)
    table.scan_typed_window(2_u64, max_rows: 2) do |batch|
      require!(batch.column_type_for("v") == type.name, "#{id} #{label} middle type differs")
      keys.concat(batch.values_for("id", UInt64).to_a)
      middle.concat(batch.binary_bulk_values_for("v").to_a)
      middle_schedule << {batch.mark_index, batch.mark_row_offset, batch.part_row_offset, batch.source_row_offset}
    end
    require!(keys == ROW_KEYS[2, 2] && middle == expected[2, 2], "#{id} #{label} middle typed window differs")
    require!(middle_schedule == [{1, 0_u64, 2_u64, 2_u64}], "#{id} #{label} middle typed offsets differ")
    require!(middle.each_with_index.all? { |value, index| rowbinary_row(keys[index], value) == decode_hex(literals[index + 2]) },
      "#{id} #{label} middle typed RowBinary differs")

    zero_callbacks = 0
    table.scan_typed_candidate_marks([[] of Int32]) { |_batch| zero_callbacks += 1 }
    require!(zero_callbacks == 0, "#{id} #{label} zero-mark typed scan emitted callbacks")

    eof_callbacks = 0
    eof_keys = [] of UInt64
    eof_values = [] of CrystalClick::BinaryValue
    table.scan_typed_window(ROW_KEYS.size.to_u64, max_rows: 2) do |batch|
      eof_callbacks += 1
      eof_keys.concat(batch.values_for("id", UInt64).to_a)
      eof_values.concat(batch.binary_bulk_values_for("v").to_a)
    end
    require!(eof_callbacks == 0 && eof_keys.empty? && eof_values.empty?, "#{id} #{label} EOF window is not empty")
    full_rowbinary_hex = [] of JSON::Any
    full_keys.each_with_index do |key, index|
      full_rowbinary_hex << JSON::Any.new(encode_hex(rowbinary_row(key, full_values[index])))
    end
    middle_rowbinary_hex = [] of JSON::Any
    keys.each_with_index do |key, index|
      middle_rowbinary_hex << JSON::Any.new(encode_hex(rowbinary_row(key, middle[index])))
    end
    JSON::Any.new({
      "full_rows"                     => JSON::Any.new(expected.size.to_i64),
      "middle_rows"                   => JSON::Any.new(middle.size.to_i64),
      "full_schedule"                 => schedule_json(full_schedule),
      "middle_schedule"               => schedule_json(middle_schedule),
      "full_rowbinary_hex"            => JSON::Any.new(full_rowbinary_hex),
      "middle_rowbinary_hex"          => JSON::Any.new(middle_rowbinary_hex),
      "zero_mark_callbacks"           => JSON::Any.new(zero_callbacks),
      "eof_callbacks"                 => JSON::Any.new(eof_callbacks),
      "exact_type_and_literal_checks" => JSON::Any.new(true),
    } of String => JSON::Any)
  end

  private def read_values(part : String, type : CrystalClick::BinaryDataType, expected : Array(CrystalClick::BinaryValue), literals : Array(String), id : String, label : String) : JSON::Any
    table = CrystalClick::WidePartTable.open_selected_typed([part], ["id", "v"])
    require!(table.total_row_count == ROW_KEYS.size.to_u64, "#{id} #{label} row count differs")
    require!(table.column_types == [{"id", "UInt64"}, {"v", type.name}], "#{id} #{label} exact column types differ")
    require!(table.part_mark_row_counts == [MARK_ROWS], "#{id} #{label} parent mark grid differs")
    keys, actual, schedule = collect_scan(table, type, id, label)
    require!(keys == ROW_KEYS && actual == expected, "#{id} #{label} typed full values differ from fixture")
    require_literals!(keys, actual, literals, id, label)
    scan_windows!(part, type, expected, literals, keys, actual, schedule, id, label)
  end

  private def input_profiles(input : JSON::Any, input_path : String) : Tuple(String, String, Array(JSON::Any))
    root = input.as_h
    exact_keys!(root, ["capture_root", "format", "generated_root", "profiles"], "input")
    require!(root["format"].as_s == INPUT_FORMAT, "input format differs")
    capture = fixed_capture_root(root["capture_root"].as_s, SOURCE_PREFIX, "stock root")
    generated = canonical_dir(root["generated_root"].as_s, "generated root")
    evidence = File.dirname(File.dirname(generated))
    fixed_capture_root(evidence, EVIDENCE_PREFIX, "evidence root")
    require!(generated == File.join(evidence, "generated", "parts"), "generated root is not its exact fixed child")
    require!(input_path == File.join(evidence, "generated", "helper-input.json"), "input manifest is not in its fixed path")
    profiles = root["profiles"].as_a
    require!(profiles.size == PROFILE_TYPES.size, "input profile roster differs")
    seen = Set(String).new
    profiles.each do |profile|
      fields = profile.as_h
      exact_keys!(fields, ["declared_type", "id", "library_part_path", "literal_rowbinary_hex", "mark_rows", "row_keys", "rows", "source_part_path"], "profile")
      id = fields["id"].as_s
      type_name = PROFILE_TYPES[id]? || raise CrystalClick::UnsupportedFormatError.new("profile id outside fixed roster")
      require!(seen.add?(id), "duplicate profile id")
      require!(fields["declared_type"].as_s == type_name, "#{id} declared type differs")
      type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(type_name) ||
             raise CrystalClick::CorruptPartError.new("#{id} type is not canonical")
      require!(type.contains_qbit?, "#{id} fixed roster lost QBit")
      source_path = File.join(capture, "parts", id, "all_1_1_0")
      library_path = File.join(generated, id, "all_1_1_0")
      require!(File.expand_path(fields["source_part_path"].as_s) == source_path, "#{id} source part path differs")
      require!(File.expand_path(fields["library_part_path"].as_s) == library_path, "#{id} library path differs")
      canonical_part(source_path, "#{id} source part")
      parent = canonical_dir(File.dirname(library_path), "#{id} library parent")
      require!(parent == File.dirname(library_path) && !File.exists?(library_path) && !File.symlink?(library_path),
        "#{id} library destination is not fresh")
      keys = fields["row_keys"].as_a.map(&.as_i64)
      marks = fields["mark_rows"].as_a.map(&.as_i64)
      require!(keys == ROW_KEYS.map(&.to_i64) && marks == MARK_ROWS.map(&.to_i64), "#{id} key/mark roster differs")
      expected = parse_rows(fields["rows"].as_a, type, id)
      literals = fields["literal_rowbinary_hex"].as_a.map(&.as_s)
      require!(literals.size == ROW_KEYS.size, "#{id} literal count differs")
      require_literals!(ROW_KEYS, expected, literals, id, "input")
    end
    require!(seen.size == PROFILE_TYPES.size, "fixed profile roster is incomplete")
    {capture, generated, profiles}
  end

  private def process_profile(profile : JSON::Any) : JSON::Any
    fields = profile.as_h
    id = fields["id"].as_s
    type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(fields["declared_type"].as_s).not_nil!
    source = canonical_part(fields["source_part_path"].as_s, "#{id} source")
    library = File.expand_path(fields["library_part_path"].as_s)
    expected = parse_rows(fields["rows"].as_a, type, id)
    literals = fields["literal_rowbinary_hex"].as_a.map(&.as_s)
    source_read = read_values(source, type, expected, literals, id, "stock")

    keys = fields["row_keys"].as_a.map { |item| item.as_i64.to_u64 }
    granules = [expected[0, 2], expected[2, 2], expected[4, 2]]
    written = CrystalClick::WidePartWriter.write_uint64_qbit_bulk_part(
      library, "id", keys.to_unsafe.to_slice(keys.size), "v", type, granules, rows_per_mark: 2
    )
    require!(written == library && File.directory?(library) && !File.symlink?(library), "#{id} writer returned an unexpected path")
    library_read = read_values(library, type, expected, literals, id, "library")

    JSON::Any.new({
      "id"                                      => JSON::Any.new(id),
      "declared_type"                           => JSON::Any.new(type.name),
      "source_part_path"                        => JSON::Any.new(source),
      "library_part_path"                       => JSON::Any.new(library),
      "row_keys"                                => JSON::Any.new(keys.map { |key| JSON::Any.new(key.to_i64) }),
      "mark_rows"                               => JSON::Any.new(MARK_ROWS.map { |count| JSON::Any.new(count.to_i64) }),
      "source_scan"                             => source_read,
      "library_scan"                            => library_read,
      "source_rows_match_independent_literals"  => JSON::Any.new(true),
      "library_rows_match_independent_literals" => JSON::Any.new(true),
    } of String => JSON::Any)
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 2 && args[0] == "--input"
      raise ArgumentError.new("usage: check_recursive_qbit_variant_w232.cr --input FILE")
    end
    input_path = File.expand_path(args[1])
    info = File.info?(input_path, follow_symlinks: false) || raise CrystalClick::InvalidPartError.new("input is missing")
    require!(info.file? && !info.type.symlink? && File.realpath(input_path) == input_path, "input is not a canonical regular file")
    require!(info.size <= MAX_INPUT_BYTES, "input exceeds byte cap")
    _capture, _generated, profiles = input_profiles(JSON.parse(File.read(input_path)), input_path)
    output = profiles.map { |profile| process_profile(profile) }
    puts JSON::Any.new({
      "format"        => JSON::Any.new(OUTPUT_FORMAT),
      "profile_count" => JSON::Any.new(output.size),
      "profiles"      => JSON::Any.new(output),
    } of String => JSON::Any).to_json
  rescue ex : Exception
    STDERR.puts "W232 Variant/QBit helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckRecursiveQBitVariantW232.main(ARGV)
