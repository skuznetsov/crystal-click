require "../src/crystal_click"
require "json"
require "file_utils"

module CheckRecursiveQBitStaticW231
  extend self

  INPUT_FORMAT  = "recursive_qbit_static_w231_helper_input_v1"
  OUTPUT_FORMAT = "recursive_qbit_static_w231_helper_v1"
  PROFILE_TYPES = {
    "tuple_sibling_arrays"           => "Tuple(left Array(QBit(Int8, 9)), right Array(QBit(Float32, 9)))",
    "tuple_sibling_arrays_all_empty" => "Tuple(left Array(QBit(Int8, 9)), right Array(QBit(Float32, 9)))",
    "tuple_direct_nullable"          => "Tuple(direct QBit(BFloat16, 16), maybe Nullable(QBit(Int8, 3)))",
    "array_tuple_sites"              => "Array(Tuple(left QBit(Int8, 9), right QBit(Float32, 9)))",
    "nested_sites"                   => "Nested(direct QBit(Int8, 9), children Array(QBit(BFloat16, 16)))",
    "map_value_site"                 => "Map(String, QBit(Float32, 9))",
    "map_key_site"                   => "Map(QBit(Int8, 9), UInt64)",
    "nullable_tuple_hidden"          => "Nullable(Tuple(direct QBit(Int8, 9), children Array(QBit(BFloat16, 16))))",
  }
  ROW_KEYS           = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  MARK_ROWS          = [2_u64, 2_u64, 2_u64]
  FULL_SCAN_SCHEDULE = [
    {0, 0_u64, 0_u64, 0_u64},
    {1, 0_u64, 2_u64, 2_u64},
    {2, 0_u64, 4_u64, 4_u64},
  ]
  MAX_INPUT_BYTES        = 16 * 1024 * 1024
  MAX_COLLECTION_ITEMS   =        64
  MAX_FIXTURE_ITEMS      = 4_096_u64
  MAX_FIXTURE_QBIT_BYTES = 1_u64 * 1024_u64 * 1024_u64
  MAX_LITERAL_ROW_BYTES  = 1 * 1024 * 1024
  MAX_VALUE_NODES        = 65_536_u64
  MAX_VALUE_DEPTH        =         32

  private class FixtureBudget
    @items = 0_u64
    @qbit_bytes = 0_u64
    @nodes = 0_u64

    def visit!(depth : Int32) : Nil
      raise CrystalClick::BoundsError.new("QBit fixture value exceeds recursive-depth limit") if depth > CheckRecursiveQBitStaticW231::MAX_VALUE_DEPTH
      if @nodes >= CheckRecursiveQBitStaticW231::MAX_VALUE_NODES
        raise CrystalClick::BoundsError.new("QBit fixture node budget exceeds limit")
      end
      @nodes += 1_u64
    end

    def charge_collection!(count : Int32) : Nil
      if count > CheckRecursiveQBitStaticW231::MAX_COLLECTION_ITEMS
        raise CrystalClick::BoundsError.new("QBit fixture collection exceeds its local bound")
      end
      amount = count.to_u64
      if amount > CheckRecursiveQBitStaticW231::MAX_FIXTURE_ITEMS - @items
        raise CrystalClick::BoundsError.new("QBit fixture item budget exceeds limit")
      end
      @items += amount
    end

    def charge_qbit!(count : Int32) : Nil
      amount = count.to_u64
      if amount > CheckRecursiveQBitStaticW231::MAX_FIXTURE_QBIT_BYTES - @qbit_bytes
        raise CrystalClick::BoundsError.new("QBit fixture payload budget exceeds limit")
      end
      @qbit_bytes += amount
    end
  end

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W231 static QBit helper: #{message}") unless condition
  end

  private def exact_keys!(hash : Hash(String, JSON::Any), expected : Array(String), label : String) : Nil
    require!(hash.keys.sort == expected.sort, "#{label} fields differ")
  end

  private def canonical_directory(path : String, label : String) : String
    full = File.expand_path(path)
    info = File.info?(full, follow_symlinks: false) || raise CrystalClick::InvalidPartError.new("#{label} is missing")
    require!(info.directory? && !info.type.symlink? && File.realpath(full) == full, "#{label} is not a canonical directory")
    full
  end

  private def canonical_part(path : String, label : String) : String
    full = File.expand_path(path)
    info = File.info?(full, follow_symlinks: false) || raise CrystalClick::InvalidPartError.new("#{label} is missing")
    require!(info.directory? && !info.type.symlink? && File.realpath(full) == full, "#{label} is not a canonical part directory")
    full
  end

  private def nibble(byte : UInt8) : UInt8
    if byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
      return (byte - '0'.ord.to_u8).to_u8
    end
    if byte >= 'a'.ord.to_u8 && byte <= 'f'.ord.to_u8
      return (byte - 'a'.ord.to_u8 + 10).to_u8
    end
    raise ArgumentError.new("QBit fixture bytes must be lowercase hexadecimal")
  end

  private def decode_hex(hex : String) : Bytes
    unless hex.bytesize.even? && hex.matches?(/\A(?:[0-9a-f]{2})*\z/)
      raise ArgumentError.new("QBit fixture bytes must be even lowercase hexadecimal")
    end
    Bytes.new(hex.bytesize // 2) do |index|
      high = nibble(hex.byte_at(index * 2))
      low = nibble(hex.byte_at(index * 2 + 1))
      ((high << 4) | low).to_u8
    end
  end

  private def encode_hex(bytes : Bytes) : String
    String.build { |io| bytes.each { |byte| io << byte.to_s(16).rjust(2, '0') } }
  end

  private def uint64_le(value : UInt64) : Bytes
    Bytes.new(8) { |index| (value >> (index * 8)).to_u8 }
  end

  private def rowbinary_row(key : UInt64, value : CrystalClick::BinaryValue) : Bytes
    key_bytes = uint64_le(key)
    value_bytes = CrystalClick::BinaryValueCodec.encode_value(value)
    Bytes.new(key_bytes.size + value_bytes.size) do |index|
      index < key_bytes.size ? key_bytes[index] : value_bytes[index - key_bytes.size]
    end
  end

  private def require_rowbinary_rows!(
    keys : Array(UInt64),
    values : Array(CrystalClick::BinaryValue),
    literals : Array(String),
    id : String,
    context : String,
    expected_keys : Array(UInt64) = ROW_KEYS,
  ) : Nil
    require!(keys.size == expected_keys.size && values.size == expected_keys.size && literals.size == expected_keys.size,
      "#{id} #{context} row vectors differ from their expected key roster")
    expected_keys.each_with_index do |expected_key, index|
      require!(keys[index] == expected_key, "#{id} #{context} key differs at row #{index}")
      require!(rowbinary_row(keys[index], values[index]) == decode_hex(literals[index]),
        "#{id} #{context} RowBinary differs from its independent literal at row #{index}")
    end
    nil
  end

  private def visit_raw!(
    type : CrystalClick::BinaryDataType,
    raw : JSON::Any,
    budget : FixtureBudget,
    depth : Int32,
  ) : Nil
    budget.visit!(depth)
    case type.tag
    when CrystalClick::BinaryDataType::TAG_QBIT
      qbit_type = type.qbit_type || raise CrystalClick::CorruptPartError.new("QBit descriptor lost its nominal type")
      hex = raw.as_s
      require!(hex.bytesize <= MAX_LITERAL_ROW_BYTES * 2, "QBit leaf exceeds the bounded fixture payload")
      bytes = decode_hex(hex)
      require!(bytes.size == qbit_type.raw_row_bytes, "QBit leaf byte count differs from its nominal descriptor")
      budget.charge_qbit!(bytes.size)
    when CrystalClick::BinaryDataType::TAG_ARRAY
      children = raw.as_a
      budget.charge_collection!(children.size)
      children.each { |child| visit_raw!(type.child_at(0), child, budget, depth + 1) }
    when CrystalClick::BinaryDataType::TAG_NESTED
      children = raw.as_a
      budget.charge_collection!(children.size)
      tuple_type = type.child_at(0)
      children.each { |child| visit_raw!(tuple_type, child, budget, depth + 1) }
    when CrystalClick::BinaryDataType::TAG_NULLABLE
      visit_raw!(type.child_at(0), raw, budget, depth + 1) unless raw.raw.nil?
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      fields = raw.as_h
      names = type.field_names
      require!(fields.keys.sort == names.sort, "Tuple fixture fields differ from the nominal descriptor")
      type.child_count.times do |index|
        visit_raw!(type.child_at(index), fields[type.field_name_at(index)], budget, depth + 1)
      end
    when CrystalClick::BinaryDataType::TAG_MAP
      entries = raw.as_a
      budget.charge_collection!(entries.size)
      entries.each do |entry|
        pair = entry.as_a
        require!(pair.size == 2, "Map fixture entry is not a key/value pair")
        visit_raw!(type.child_at(0), pair[0], budget, depth + 1)
        visit_raw!(type.child_at(1), pair[1], budget, depth + 1)
      end
    when CrystalClick::BinaryDataType::TAG_STRING
      text = raw.as_s
      require!(text.bytesize <= MAX_LITERAL_ROW_BYTES, "String fixture value exceeds its byte limit")
    when CrystalClick::BinaryDataType::TAG_UINT64
      number = raw.as_i64
      require!(number >= 0, "UInt64 fixture value is negative")
    else
      raise CrystalClick::UnsupportedFormatError.new("W231 fixture contains an unlisted static node: #{type.name}")
    end
    nil
  end

  private def value_from_json(type : CrystalClick::BinaryDataType, raw : JSON::Any) : CrystalClick::BinaryValue
    case type.tag
    when CrystalClick::BinaryDataType::TAG_QBIT
      qbit_type = type.qbit_type || raise CrystalClick::CorruptPartError.new("QBit descriptor lost its nominal type")
      CrystalClick::BinaryValue.qbit(type, CrystalClick::QBitValue.new(qbit_type, decode_hex(raw.as_s)))
    when CrystalClick::BinaryDataType::TAG_ARRAY
      children = raw.as_a.map { |child| value_from_json(type.child_at(0), child) }
      CrystalClick::BinaryValue.array(type, children)
    when CrystalClick::BinaryDataType::TAG_NESTED
      tuple_type = type.child_at(0)
      children = raw.as_a.map { |child| value_from_json(tuple_type, child) }
      CrystalClick::BinaryValue.nested(type, children)
    when CrystalClick::BinaryDataType::TAG_NULLABLE
      raw.raw.nil? ? CrystalClick::BinaryValue.nullable(type) : CrystalClick::BinaryValue.nullable(type, value_from_json(type.child_at(0), raw))
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      fields = raw.as_h
      children = Array(CrystalClick::BinaryValue).new(type.child_count) do |index|
        value_from_json(type.child_at(index), fields[type.field_name_at(index)])
      end
      CrystalClick::BinaryValue.tuple(type, children)
    when CrystalClick::BinaryDataType::TAG_MAP
      values = [] of CrystalClick::BinaryValue
      raw.as_a.each do |entry|
        pair = entry.as_a
        values << value_from_json(type.child_at(0), pair[0])
        values << value_from_json(type.child_at(1), pair[1])
      end
      CrystalClick::BinaryValue.map(type, values)
    when CrystalClick::BinaryDataType::TAG_STRING
      CrystalClick::BinaryValue.string(raw.as_s)
    when CrystalClick::BinaryDataType::TAG_UINT64
      CrystalClick::BinaryValue.uint64(raw.as_i64.to_u64)
    else
      raise CrystalClick::UnsupportedFormatError.new("W231 fixture contains an unlisted static node: #{type.name}")
    end
  end

  private def value_to_json(value : CrystalClick::BinaryValue) : JSON::Any
    type = value.type
    case type.tag
    when CrystalClick::BinaryDataType::TAG_QBIT
      JSON::Any.new(encode_hex(value.qbit_value.raw_bytes))
    when CrystalClick::BinaryDataType::TAG_ARRAY, CrystalClick::BinaryDataType::TAG_NESTED
      JSON::Any.new(value.elements.map { |child| value_to_json(child) })
    when CrystalClick::BinaryDataType::TAG_NULLABLE
      value.is_null? ? JSON::Any.new(nil) : value_to_json(value.child_at(0))
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      fields = {} of String => JSON::Any
      type.child_count.times do |index|
        fields[type.field_name_at(index)] = value_to_json(value.child_at(index))
      end
      JSON::Any.new(fields)
    when CrystalClick::BinaryDataType::TAG_MAP
      flat = value.elements
      entries = Array(JSON::Any).new(flat.size // 2) do |index|
        JSON::Any.new([
          value_to_json(flat[index * 2]),
          value_to_json(flat[index * 2 + 1]),
        ] of JSON::Any)
      end
      JSON::Any.new(entries)
    when CrystalClick::BinaryDataType::TAG_STRING
      JSON::Any.new(value.as_string)
    when CrystalClick::BinaryDataType::TAG_UINT64
      number = value.as_uint64
      require!(number <= Int64::MAX.to_u64, "UInt64 output exceeds JSON's signed integer representation")
      JSON::Any.new(number.to_i64)
    else
      raise CrystalClick::UnsupportedFormatError.new("W231 output contains an unlisted static node: #{type.name}")
    end
  end

  private def validate_rows!(rows : Array(JSON::Any), type : CrystalClick::BinaryDataType, id : String) : Array(CrystalClick::BinaryValue)
    require!(rows.size == ROW_KEYS.size, "#{id} must contain exactly six parent rows")
    budget = FixtureBudget.new
    rows.each { |row| visit_raw!(type, row, budget, 0) }
    values = rows.map { |row| value_from_json(type, row) }
    values.each_with_index do |value, index|
      require!(value.type == type, "#{id} row #{index} lost its exact nominal descriptor")
    end
    values
  end

  private def render_rows(values : Array(CrystalClick::BinaryValue)) : JSON::Any
    JSON::Any.new(values.map { |value| value_to_json(value) })
  end

  private def offline_store_path(root : String, uuid : String) : String
    File.join(root, "store", uuid[0, 3], uuid)
  end

  private def check_offline_values!(
    library_part_path : String,
    type : CrystalClick::BinaryDataType,
    literals : Array(String),
    id : String,
  ) : Nil
    generated_root = File.dirname(File.dirname(File.dirname(library_part_path)))
    catalog_root = File.join(generated_root, "catalog-#{id}")
    require!(!File.exists?(catalog_root) && !File.symlink?(catalog_root), "#{id} synthetic catalog path is not fresh")
    Dir.mkdir(catalog_root)
    begin
      metadata_root = File.join(catalog_root, "metadata")
      FileUtils.mkdir_p(metadata_root)
      FileUtils.mkdir_p(File.join(catalog_root, "store"))

      database_uuid = "23100000-0000-4000-8000-#{(1 + PROFILE_TYPES.keys.index(id).not_nil!).to_s.rjust(12, '0')}"
      table_uuid = "23100000-0000-4000-8000-#{(101 + PROFILE_TYPES.keys.index(id).not_nil!).to_s.rjust(12, '0')}"
      File.write(File.join(metadata_root, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
      database_path = offline_store_path(catalog_root, database_uuid)
      FileUtils.mkdir_p(database_path)
      table_ddl = "ATTACH TABLE _ UUID '#{table_uuid}'\n" +
                  "(\n    `id` UInt64,\n    `q` #{type.name}\n)\n" +
                  "ENGINE = MergeTree\nORDER BY id\n"
      File.write(File.join(database_path, "events.sql"), table_ddl)

      table_path = offline_store_path(catalog_root, table_uuid)
      FileUtils.mkdir_p(table_path)
      File.write(File.join(table_path, "format_version.txt"), "1\n")
      Dir.mkdir(File.join(table_path, "detached"))
      destination = File.join(table_path, "all_1_1_0")
      require!(!File.exists?(destination) && !File.symlink?(destination), "#{id} synthetic catalog part path is not fresh")
      FileUtils.cp_r(library_part_path, destination)

      table = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
      require!(table.engine == "MergeTree" && table.columns.map { |column| {column.name, column.type} } == [
        {"id", "UInt64"}, {"q", type.name},
      ], "#{id} synthetic catalog metadata differs from the fixture")
      keys = table["id"].values(max_rows: ROW_KEYS.size.to_u64).map(&.as(UInt64))
      values = table["q"].values(max_rows: ROW_KEYS.size.to_u64).map(&.as(CrystalClick::BinaryValue))
      require!(keys == ROW_KEYS, "#{id} OfflineColumn.values key column differs from its fixed roster")
      require!(values.size == ROW_KEYS.size, "#{id} OfflineColumn.values row count differs")
      values.each { |value| require!(value.type == type, "#{id} OfflineColumn.values lost the nominal descriptor") }
      require_rowbinary_rows!(keys, values, literals, id, "OfflineColumn.values")
    ensure
      if File.directory?(catalog_root) && !File.symlink?(catalog_root) && File.realpath(catalog_root) == catalog_root
        FileUtils.rm_rf(catalog_root)
      end
    end
    nil
  end

  private def read_values(
    part_path : String,
    type : CrystalClick::BinaryDataType,
    literals : Array(String),
    id : String,
    context : String,
  ) : Array(CrystalClick::BinaryValue)
    table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["id", "q"])
    require!(table.total_row_count == ROW_KEYS.size.to_u64, "#{id} #{context} row count differs")
    require!(table.column_types == [{"id", "UInt64"}, {"q", type.name}], "#{id} #{context} exact column types differ")
    require!(table.part_mark_row_counts == [MARK_ROWS], "#{id} #{context} part mark grid differs")
    values = [] of CrystalClick::BinaryValue
    keys = [] of UInt64
    schedule = [] of Tuple(Int32, UInt64, UInt64, UInt64)
    table.scan_typed(batch_rows: 2) do |batch|
      require!(batch.column_type_for("q") == type.name, "#{id} #{context} typed window nominal type differs")
      keys.concat(batch.values_for("id", UInt64).to_a)
      values.concat(batch.binary_bulk_values_for("q").to_a)
      schedule << {batch.mark_index, batch.mark_row_offset, batch.part_row_offset, batch.source_row_offset}
    end
    require!(schedule == FULL_SCAN_SCHEDULE, "#{id} #{context} typed mark schedule differs")
    values.each { |value| require!(value.type == type, "#{id} #{context} typed value differs in nominal type") }
    require_rowbinary_rows!(keys, values, literals, id, "#{context} full scan")
    values
  end

  private def check_typed_windows!(
    part_path : String,
    type : CrystalClick::BinaryDataType,
    expected : Array(CrystalClick::BinaryValue),
    literals : Array(String),
    id : String,
    context : String,
  ) : Nil
    table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["id", "q"])
    keys = [] of UInt64
    values = [] of CrystalClick::BinaryValue
    schedule = [] of Tuple(Int32, UInt64, UInt64, UInt64)
    table.scan_typed_window(2_u64, max_rows: 2) do |batch|
      require!(batch.column_type_for("q") == type.name, "#{id} #{context} middle window nominal type differs")
      keys.concat(batch.values_for("id", UInt64).to_a)
      values.concat(batch.binary_bulk_values_for("q").to_a)
      schedule << {batch.mark_index, batch.mark_row_offset, batch.part_row_offset, batch.source_row_offset}
    end
    require!(keys == ROW_KEYS[2, 2], "#{id} #{context} middle window keys differ")
    require!(values == expected[2, 2], "#{id} #{context} middle window values differ")
    require!(schedule == [{1, 0_u64, 2_u64, 2_u64}], "#{id} #{context} middle window offsets differ")
    require_rowbinary_rows!(keys, values, literals[2, 2], id, "#{context} middle window", ROW_KEYS[2, 2])

    eof_keys = [] of UInt64
    eof_values = [] of CrystalClick::BinaryValue
    eof_callbacks = 0
    table.scan_typed_window(ROW_KEYS.size.to_u64, max_rows: 2) do |batch|
      eof_callbacks += 1
      eof_keys.concat(batch.values_for("id", UInt64).to_a)
      eof_values.concat(batch.binary_bulk_values_for("q").to_a)
    end
    require!(eof_callbacks == 0 && eof_keys.empty? && eof_values.empty?, "#{id} #{context} EOF window is not empty")
    require_rowbinary_rows!(eof_keys, eof_values, [] of String, id, "#{context} empty window", [] of UInt64)
    nil
  end

  private def validate_input!(input : JSON::Any, input_path : String) : Array(JSON::Any)
    root = input.as_h
    exact_keys!(root, ["format", "capture_root", "generated_root", "profiles"], "input")
    require!(root["format"].as_s == INPUT_FORMAT, "input format is unsupported")

    capture = canonical_directory(root["capture_root"].as_s, "stock capture root")
    generated = canonical_directory(root["generated_root"].as_s, "generated parts root")
    require!(capture.starts_with?("/private/tmp/crystal-click-w231-stock."), "stock capture root is outside the fixed private-temp namespace")
    evidence_root = File.dirname(File.dirname(generated))
    require!(File.basename(generated) == "parts" && File.basename(File.dirname(generated)) == "generated" &&
             File.dirname(evidence_root) == "/private/tmp" && File.basename(evidence_root).starts_with?("crystal-click-w231-evidence."),
      "generated root is outside the fixed evidence namespace")
    require!(input_path == File.join(evidence_root, "generated", "helper-input.json"), "input manifest is not in its fixed evidence location")

    profiles = root["profiles"].as_a
    require!(profiles.size == PROFILE_TYPES.size, "profile count differs from the fixed eight-case roster")
    seen = Set(String).new
    profiles.each do |profile|
      fields = profile.as_h
      exact_keys!(fields,
        ["id", "declared_type", "source_part_path", "library_part_path", "row_keys", "mark_rows", "rows", "literal_rowbinary_hex"],
        "profile")
      id = fields["id"].as_s
      type_name = PROFILE_TYPES[id]? || raise CrystalClick::UnsupportedFormatError.new("profile id is outside the fixed W231 roster")
      require!(seen.add?(id), "duplicate profile id #{id}")
      require!(fields["declared_type"].as_s == type_name, "#{id} declared type differs from the fixed roster")
      type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(type_name) ||
             raise CrystalClick::CorruptPartError.new("#{id} declared type is not canonical")
      require!(type.contains_qbit? && CrystalClick::BinaryDataType.admitted_qbit_static_composition?(type),
        "#{id} descriptor is outside the admitted static QBit composition")

      expected_source = File.join(capture, "parts", id, "all_1_1_0")
      expected_library = File.join(generated, id, "all_1_1_0")
      require!(File.expand_path(fields["source_part_path"].as_s) == expected_source, "#{id} source path differs from its fixed slot")
      require!(File.expand_path(fields["library_part_path"].as_s) == expected_library, "#{id} library path differs from its fixed slot")
      canonical_part(expected_source, "#{id} stock part")
      library_parent = canonical_directory(File.join(generated, id), "#{id} library parent")
      require!(library_parent == File.join(generated, id), "#{id} library parent changed while validating")
      require!(!File.exists?(expected_library) && !File.symlink?(expected_library), "#{id} library destination is not fresh")

      keys = fields["row_keys"].as_a.map(&.as_i64)
      require!(keys == ROW_KEYS.map(&.to_i64), "#{id} row-key roster differs")
      marks = fields["mark_rows"].as_a.map(&.as_i64)
      require!(marks == MARK_ROWS.map(&.to_i64), "#{id} mark-row roster differs")
      values = validate_rows!(fields["rows"].as_a, type, id)
      literals = fields["literal_rowbinary_hex"].as_a
      require!(literals.size == ROW_KEYS.size, "#{id} RowBinary literal row count differs")
      literals.each_with_index do |literal, index|
        text = literal.as_s
        require!(text.bytesize <= MAX_LITERAL_ROW_BYTES * 2, "#{id} RowBinary literal exceeds its byte bound")
        require!(decode_hex(text) == rowbinary_row(ROW_KEYS[index], values[index]),
          "#{id} RowBinary literal differs from the independently encoded key/value row #{index}")
      end
    end
    require!(seen.size == PROFILE_TYPES.size, "fixed profile roster is incomplete")
    profiles
  end

  private def process_profile(profile : JSON::Any) : JSON::Any
    fields = profile.as_h
    id = fields["id"].as_s
    type_name = fields["declared_type"].as_s
    type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(type_name).not_nil!
    source_path = canonical_part(fields["source_part_path"].as_s, "#{id} stock part")
    library_path = File.expand_path(fields["library_part_path"].as_s)
    expected = validate_rows!(fields["rows"].as_a, type, id)
    literals = fields["literal_rowbinary_hex"].as_a.map(&.as_s)

    source_values = read_values(source_path, type, literals, id, "stock")
    require!(source_values == expected, "#{id} stock typed values differ from the independent manifest")
    check_typed_windows!(source_path, type, expected, literals, id, "stock")

    row_keys = fields["row_keys"].as_a.map { |item| item.as_i64.to_u64 }
    mark_rows = fields["mark_rows"].as_a.map { |item| item.as_i64.to_u64 }
    granules = [] of Array(CrystalClick::BinaryValue)
    offset = 0
    mark_rows.each do |count|
      granules << expected[offset, count.to_i]
      offset += count.to_i
    end
    require!(offset == expected.size, "#{id} marks do not consume the six-row fixture")
    written = CrystalClick::WidePartWriter.write_uint64_qbit_bulk_part(
      library_path,
      "id",
      row_keys.to_unsafe.to_slice(row_keys.size),
      "q",
      type,
      granules,
      rows_per_mark: 2,
    )
    require!(written == library_path && File.directory?(library_path) && !File.symlink?(library_path),
      "#{id} writer published an unexpected destination")

    library_values = read_values(library_path, type, literals, id, "library")
    require!(library_values == expected, "#{id} library typed values differ from the independent manifest")
    check_typed_windows!(library_path, type, expected, literals, id, "library")
    check_offline_values!(library_path, type, literals, id)

    output_rows = {
      "id"                => JSON::Any.new(id),
      "declared_type"     => JSON::Any.new(type_name),
      "source_part_path"  => JSON::Any.new(source_path),
      "library_part_path" => JSON::Any.new(library_path),
      "row_keys"          => JSON::Any.new(row_keys.map { |value| JSON::Any.new(value.to_i64) }),
      "mark_rows"         => JSON::Any.new(mark_rows.map { |value| JSON::Any.new(value.to_i64) }),
      "source_rows"       => render_rows(source_values),
      "library_rows"      => render_rows(library_values),
    } of String => JSON::Any
    JSON::Any.new(output_rows)
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 2 && args[0] == "--input"
      raise ArgumentError.new("usage: check_recursive_qbit_static_w231.cr --input FILE")
    end
    input_path = File.expand_path(args[1])
    info = File.info?(input_path, follow_symlinks: false) || raise CrystalClick::InvalidPartError.new("input manifest is missing")
    require!(info.file? && !info.type.symlink? && File.realpath(input_path) == input_path, "input manifest is not a canonical regular file")
    require!(info.size <= MAX_INPUT_BYTES, "input manifest exceeds its byte limit")
    profiles = validate_input!(JSON.parse(File.read(input_path)), input_path)
    output_profiles = profiles.map { |profile| process_profile(profile) }
    puts JSON::Any.new({
      "format"        => JSON::Any.new(OUTPUT_FORMAT),
      "profile_count" => JSON::Any.new(output_profiles.size),
      "profiles"      => JSON::Any.new(output_profiles),
    } of String => JSON::Any).to_json
  rescue ex : Exception
    STDERR.puts "W231 static QBit helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckRecursiveQBitStaticW231.main(ARGV)
