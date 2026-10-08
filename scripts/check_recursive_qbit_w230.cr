require "../src/crystal_click"
require "json"
require "file_utils"

module CheckRecursiveQBitW230
  extend self

  INPUT_FORMAT  = "recursive_qbit_w230_helper_input_v1"
  OUTPUT_FORMAT = "recursive_qbit_w230_helper_v1"
  PROFILE_TYPES = {
    "array_qbit_int8_9"                => "Array(QBit(Int8, 9))",
    "array_qbit_bfloat16_9"            => "Array(QBit(BFloat16, 9))",
    "array_qbit_float32_9"             => "Array(QBit(Float32, 9))",
    "array_qbit_float64_9"             => "Array(QBit(Float64, 9))",
    "array_qbit_bfloat16_16_stride8"   => "Array(QBit(BFloat16, 16, 8))",
    "array_nullable_qbit_bfloat16_16"  => "Array(Nullable(QBit(BFloat16, 16)))",
    "array_array_qbit_int8_3"          => "Array(Array(QBit(Int8, 3)))",
    "array_qbit_bfloat16_16_all_empty" => "Array(QBit(BFloat16, 16))",
  }
  ROW_KEYS                   = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  MARK_ROWS                  = [2_u64, 2_u64, 2_u64]
  MAX_INPUT_BYTES            = 16 * 1024 * 1024
  MAX_ARRAY_CHILDREN         =        64
  MAX_FIXTURE_ARRAY_ELEMENTS = 4_096_u64
  MAX_FIXTURE_QBIT_BYTES     = 1_u64 * 1024_u64 * 1024_u64
  MAX_LITERAL_ROW_BYTES      = 1 * 1024 * 1024
  FULL_SCAN_SCHEDULE         = [{0, 0_u64, 0_u64, 0_u64}, {1, 0_u64, 2_u64, 2_u64}, {2, 0_u64, 4_u64, 4_u64}]

  private class FixtureBudget
    @array_elements = 0_u64
    @qbit_bytes = 0_u64

    def charge_array!(count : Int32) : Nil
      raise CrystalClick::BoundsError.new("QBit fixture Array child count exceeds limit") if count > CheckRecursiveQBitW230::MAX_ARRAY_CHILDREN
      amount = count.to_u64
      if amount > CheckRecursiveQBitW230::MAX_FIXTURE_ARRAY_ELEMENTS - @array_elements
        raise CrystalClick::BoundsError.new("QBit fixture Array element budget exceeds limit")
      end
      @array_elements += amount
    end

    def charge_qbit!(count : Int32) : Nil
      amount = count.to_u64
      if amount > CheckRecursiveQBitW230::MAX_FIXTURE_QBIT_BYTES - @qbit_bytes
        raise CrystalClick::BoundsError.new("QBit fixture payload budget exceeds limit")
      end
      @qbit_bytes += amount
    end
  end

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W230 QBit helper: #{message}") unless condition
  end

  private def exact_keys!(hash : Hash(String, JSON::Any), keys : Array(String), label : String) : Nil
    require!(hash.keys.sort == keys.sort, "#{label} fields differ")
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
    Bytes.new(8) do |index|
      (value >> (index * 8)).to_u8
    end
  end

  private def rowbinary_row(key : UInt64, value : CrystalClick::BinaryValue) : Bytes
    key_bytes = uint64_le(key)
    value_bytes = CrystalClick::BinaryValueCodec.encode_value(value)
    Bytes.new(key_bytes.size + value_bytes.size) do |index|
      if index < key_bytes.size
        key_bytes[index]
      else
        value_bytes[index - key_bytes.size]
      end
    end
  end

  private def validate_raw_value!(
    type : CrystalClick::BinaryDataType,
    raw : JSON::Any,
    id : String,
    depth : Int32,
    budget : FixtureBudget,
  ) : Nil
    require!(depth <= 4, "#{id} fixture value exceeds recursive-depth limit")
    case type.tag
    when CrystalClick::BinaryDataType::TAG_ARRAY
      children = raw.as_a
      budget.charge_array!(children.size)
      children.each { |child| validate_raw_value!(type.child_at(0), child, id, depth + 1, budget) }
    when CrystalClick::BinaryDataType::TAG_NULLABLE
      validate_raw_value!(type.child_at(0), raw, id, depth + 1, budget) unless raw.raw.nil?
    when CrystalClick::BinaryDataType::TAG_QBIT
      qbit_type = type.qbit_type || raise CrystalClick::CorruptPartError.new("QBit fixture descriptor lost its element identity")
      hex = raw.as_s
      require!(hex.bytesize <= MAX_LITERAL_ROW_BYTES * 2, "#{id} QBit leaf exceeds the bounded fixture payload")
      bytes = decode_hex(hex)
      require!(bytes.size == qbit_type.raw_row_bytes, "#{id} QBit leaf byte count differs from its nominal descriptor")
      budget.charge_qbit!(bytes.size)
    else
      raise CrystalClick::UnsupportedFormatError.new("W230 fixture tree contains an unlisted non-Array QBit node: #{type.name}")
    end
    nil
  end

  private def value_from_json(type : CrystalClick::BinaryDataType, raw : JSON::Any) : CrystalClick::BinaryValue
    case type.tag
    when CrystalClick::BinaryDataType::TAG_ARRAY
      children = raw.as_a.map { |item| value_from_json(type.child_at(0), item) }
      CrystalClick::BinaryValue.array(type, children)
    when CrystalClick::BinaryDataType::TAG_NULLABLE
      raw.raw.nil? ? CrystalClick::BinaryValue.nullable(type) : CrystalClick::BinaryValue.nullable(type, value_from_json(type.child_at(0), raw))
    when CrystalClick::BinaryDataType::TAG_QBIT
      qbit_type = type.qbit_type || raise CrystalClick::CorruptPartError.new("QBit fixture descriptor lost its element identity")
      CrystalClick::BinaryValue.qbit(type, CrystalClick::QBitValue.new(qbit_type, decode_hex(raw.as_s)))
    else
      raise CrystalClick::UnsupportedFormatError.new("W230 fixture tree contains an unlisted non-Array QBit node: #{type.name}")
    end
  end

  private def value_to_json(value : CrystalClick::BinaryValue) : JSON::Any
    type = value.type
    case type.tag
    when CrystalClick::BinaryDataType::TAG_ARRAY
      JSON::Any.new(value.elements.map { |child| value_to_json(child) })
    when CrystalClick::BinaryDataType::TAG_NULLABLE
      value.is_null? ? JSON::Any.new(nil) : value_to_json(value.child_at(0))
    when CrystalClick::BinaryDataType::TAG_QBIT
      JSON::Any.new(encode_hex(value.qbit_value.raw_bytes))
    else
      raise CrystalClick::UnsupportedFormatError.new("W230 output tree contains an unlisted non-Array QBit node: #{type.name}")
    end
  end

  private def values_from_rows(type : CrystalClick::BinaryDataType, rows : Array(JSON::Any)) : Array(CrystalClick::BinaryValue)
    rows.map { |row| value_from_json(type, row) }
  end

  private def render_rows(values : Array(CrystalClick::BinaryValue)) : JSON::Any
    JSON::Any.new(values.map { |value| value_to_json(value) })
  end

  private def require_rowbinary_rows!(
    keys : Array(UInt64),
    values : Array(CrystalClick::BinaryValue),
    literal_hex : Array(String),
    id : String,
    context : String,
    expected_keys : Array(UInt64) = ROW_KEYS,
  ) : Nil
    require!(keys.size == expected_keys.size && values.size == expected_keys.size && literal_hex.size == expected_keys.size,
      "#{id} #{context} row vectors differ from their expected key roster")
    expected_keys.each_with_index do |expected_key, index|
      require!(keys[index] == expected_key, "#{id} #{context} key differs at row #{index}")
      actual = rowbinary_row(keys[index], values[index])
      expected = decode_hex(literal_hex[index])
      require!(actual == expected, "#{id} #{context} RowBinary differs from its per-row key/value literal at row #{index}")
    end
    nil
  end

  private def read_values(
    part_path : String,
    type : CrystalClick::BinaryDataType,
    literal_hex : Array(String),
    id : String,
    context : String,
  ) : Array(CrystalClick::BinaryValue)
    table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["id", "q"])
    require!(table.total_row_count == ROW_KEYS.size.to_u64, "part row count differs from the six-row fixture")
    values = [] of CrystalClick::BinaryValue
    keys = [] of UInt64
    schedule = [] of Tuple(Int32, UInt64, UInt64, UInt64)
    table.scan_typed(batch_rows: 2) do |batch|
      require!(batch.column_type_for("q") == type.name, "typed scan nominal descriptor differs")
      batch_keys = batch.values_for("id", UInt64).to_a
      values.concat(batch.binary_bulk_values_for("q").to_a)
      keys.concat(batch_keys)
      schedule << {batch.mark_index, batch.mark_row_offset, batch.part_row_offset, batch.source_row_offset}
    end
    require!(values.size == ROW_KEYS.size, "typed scan returned an unexpected row count")
    values.each do |value|
      require!(value.type == type, "typed scan returned a value with a different nominal descriptor")
    end
    require!(schedule == FULL_SCAN_SCHEDULE, "#{id} #{context} typed scan schedule differs from the fixed three-mark grid")
    require_rowbinary_rows!(keys, values, literal_hex, id, "#{context} full scan")
    values
  end

  private def check_typed_windows!(
    part_path : String,
    type : CrystalClick::BinaryDataType,
    expected_values : Array(CrystalClick::BinaryValue),
    literal_hex : Array(String),
    id : String,
    context : String,
  ) : Nil
    table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["id", "q"])
    middle_keys = [] of UInt64
    middle_values = [] of CrystalClick::BinaryValue
    middle_schedule = [] of Tuple(Int32, UInt64, UInt64, UInt64)
    table.scan_typed_window(2_u64, max_rows: 2) do |batch|
      require!(batch.column_type_for("q") == type.name, "#{id} #{context} middle window nominal descriptor differs")
      middle_keys.concat(batch.values_for("id", UInt64).to_a)
      middle_values.concat(batch.binary_bulk_values_for("q").to_a)
      middle_schedule << {batch.mark_index, batch.mark_row_offset, batch.part_row_offset, batch.source_row_offset}
    end
    require!(middle_keys == ROW_KEYS[2, 2], "#{id} #{context} middle window selected different keys")
    require!(middle_values == expected_values[2, 2], "#{id} #{context} middle window selected different values")
    require!(middle_schedule == [{1, 0_u64, 2_u64, 2_u64}], "#{id} #{context} middle window row/mark offsets differ")
    require_rowbinary_rows!(
      middle_keys,
      middle_values,
      literal_hex[2, 2],
      id,
      "#{context} middle window",
      ROW_KEYS[2, 2],
    )

    eof_callbacks = 0
    table.scan_typed_window(ROW_KEYS.size.to_u64, max_rows: 2) do |_batch|
      eof_callbacks += 1
    end
    require!(eof_callbacks == 0, "#{id} #{context} EOF window unexpectedly invoked a callback")
    nil
  end

  private def offline_store_path(root : String, uuid : String) : String
    File.join(root, "store", uuid[0, 3], uuid)
  end

  private def check_offline_values!(
    library_part_path : String,
    type : CrystalClick::BinaryDataType,
    expected_values : Array(CrystalClick::BinaryValue),
    literal_hex : Array(String),
    id : String,
  ) : Nil
    generated_root = File.dirname(File.dirname(File.dirname(library_part_path)))
    catalog_root = File.join(generated_root, "catalog-#{id}")
    require!(!File.exists?(catalog_root) && !File.symlink?(catalog_root), "#{id} quiescent catalog path is not fresh")
    Dir.mkdir(catalog_root)
    begin
      metadata_root = File.join(catalog_root, "metadata")
      FileUtils.mkdir_p(metadata_root)
      FileUtils.mkdir_p(File.join(catalog_root, "store"))

      database_uuid = "23000000-0000-4000-8000-000000000001"
      table_uuid = "23000000-0000-4000-8000-000000000002"
      File.write(File.join(metadata_root, "lab.sql"),
        "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")

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
      require!(!File.exists?(destination) && !File.symlink?(destination), "#{id} catalog part destination is not fresh")
      FileUtils.cp_r(library_part_path, destination)

      table = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
      require!(table.engine == "MergeTree" && table.columns.map { |column| {column.name, column.type} } == [
        {"id", "UInt64"}, {"q", type.name},
      ], "#{id} quiescent catalog metadata differs from the static fixture")
      offline_values = table["q"].values(max_rows: expected_values.size.to_u64)
      actual_values = offline_values.map(&.as(CrystalClick::BinaryValue))
      require!(actual_values == expected_values, "#{id} OfflineColumn.values differs from the independent fixture values")
      require_rowbinary_rows!(ROW_KEYS, actual_values, literal_hex, id, "OfflineColumn.values")
    ensure
      if File.directory?(catalog_root) && !File.symlink?(catalog_root) && File.realpath(catalog_root) == catalog_root
        FileUtils.rm_rf(catalog_root)
      end
    end
    nil
  end

  private def validate_rows!(rows : Array(JSON::Any), type : CrystalClick::BinaryDataType, id : String) : Array(CrystalClick::BinaryValue)
    require!(rows.size == ROW_KEYS.size, "#{id} must contain six parent rows")
    budget = FixtureBudget.new
    rows.each { |row| validate_raw_value!(type, row, id, 0, budget) }
    values = values_from_rows(type, rows)
    values.each_with_index do |value, index|
      require!(value.type == type, "#{id} row #{index} has a different nominal descriptor")
    end
    values
  end

  private def validate_input!(input : JSON::Any, input_path : String) : Array(JSON::Any)
    root = input.as_h
    exact_keys!(root, ["format", "capture_root", "generated_root", "profiles"], "input")
    require!(root["format"].as_s == INPUT_FORMAT, "input format is unsupported")

    capture = canonical_directory(root["capture_root"].as_s, "capture root")
    generated = canonical_directory(root["generated_root"].as_s, "generated root")
    require!(capture.starts_with?("/private/tmp/crystal-click-w230-stock."), "capture root is outside the fixed private-temp namespace")
    evidence_generated = File.dirname(File.dirname(generated))
    require!(File.basename(generated) == "parts" && File.basename(File.dirname(generated)) == "generated" &&
             File.dirname(evidence_generated) == "/private/tmp" &&
             File.basename(evidence_generated).starts_with?("crystal-click-w230-evidence."),
      "generated root is outside the fixed evidence namespace")
    require!(input_path == File.join(evidence_generated, "generated", "helper-input.json"), "input manifest is not in its fixed evidence location")

    profiles = root["profiles"].as_a
    require!(profiles.size == PROFILE_TYPES.size, "profile count differs from the fixed eight-case roster")
    seen = Set(String).new
    profiles.each do |profile|
      fields = profile.as_h
      exact_keys!(fields,
        ["id", "declared_type", "source_part_path", "library_part_path", "row_keys", "mark_rows", "rows", "literal_rowbinary_hex"],
        "profile")
      id = fields["id"].as_s
      declared_type = PROFILE_TYPES[id]? || raise CrystalClick::UnsupportedFormatError.new("profile id is outside the fixed W230 roster")
      require!(seen.add?(id), "duplicate profile id #{id}")
      require!(fields["declared_type"].as_s == declared_type, "#{id} declared type differs from the fixed roster")
      type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(declared_type) ||
             raise CrystalClick::CorruptPartError.new("#{id} declared type is not canonical")
      require!(type.qbit_array_chain?, "#{id} descriptor is not an admitted static QBit Array chain")

      source_path = File.join(capture, "parts", id, "all_1_1_0")
      library_path = File.join(generated, id, "all_1_1_0")
      require!(File.expand_path(fields["source_part_path"].as_s) == source_path, "#{id} source part path differs from its fixed slot")
      require!(File.expand_path(fields["library_part_path"].as_s) == library_path, "#{id} library part path differs from its fixed slot")
      canonical_part(source_path, "#{id} source part")
      library_parent = canonical_directory(File.join(generated, id), "#{id} library parent")
      require!(!File.exists?(library_path) && !File.symlink?(library_path), "#{id} library destination is not fresh")
      require!(library_parent == File.join(generated, id), "#{id} library parent changed while validating")

      row_keys = fields["row_keys"].as_a.map(&.as_i64)
      require!(row_keys == ROW_KEYS.map(&.to_i64), "#{id} row-key roster differs")
      mark_rows = fields["mark_rows"].as_a.map(&.as_i64)
      require!(mark_rows == MARK_ROWS.map(&.to_i64), "#{id} parent mark grid differs")
      rows = fields["rows"].as_a
      expected = validate_rows!(rows, type, id)
      literals = fields["literal_rowbinary_hex"].as_a
      require!(literals.size == ROW_KEYS.size, "#{id} literal RowBinary row count differs")
      literals.each_with_index do |literal, index|
        literal_hex = literal.as_s
        require!(literal_hex.bytesize <= MAX_LITERAL_ROW_BYTES * 2, "#{id} literal RowBinary row exceeds its byte limit")
        literal_bytes = decode_hex(literal_hex)
        actual_bytes = rowbinary_row(ROW_KEYS[index], expected[index])
        require!(literal_bytes == actual_bytes, "#{id} literal RowBinary row #{index} differs from its key and encoded fixture value")
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
    source_path = canonical_part(fields["source_part_path"].as_s, "#{id} source part")
    library_path = File.expand_path(fields["library_part_path"].as_s)
    expected_values = validate_rows!(fields["rows"].as_a, type, id)
    literal_hex = fields["literal_rowbinary_hex"].as_a.map(&.as_s)

    source_values = read_values(source_path, type, literal_hex, id, "source")
    require!(source_values == expected_values, "#{id} source typed scan differs from independent fixture rows")
    check_typed_windows!(source_path, type, expected_values, literal_hex, id, "source")
    source_rows = render_rows(source_values)

    row_keys = fields["row_keys"].as_a.map { |item| item.as_i64.to_u64 }
    mark_rows = fields["mark_rows"].as_a.map { |item| item.as_i64.to_u64 }
    granules = [] of Array(CrystalClick::BinaryValue)
    offset = 0
    mark_rows.each do |count|
      granules << expected_values[offset, count.to_i]
      offset += count.to_i
    end
    require!(offset == expected_values.size, "#{id} mark grid does not consume the fixture")
    written = CrystalClick::WidePartWriter.write_uint64_qbit_bulk_part(
      library_path,
      "id",
      row_keys.to_unsafe.to_slice(row_keys.size),
      "q",
      type,
      granules,
      rows_per_mark: 2,
    )
    require!(written == library_path && File.directory?(library_path) && !File.symlink?(library_path), "#{id} writer published an unexpected destination")

    library_values = read_values(library_path, type, literal_hex, id, "library")
    require!(library_values == expected_values, "#{id} library typed scan differs from independent fixture rows")
    check_typed_windows!(library_path, type, expected_values, literal_hex, id, "library")
    check_offline_values!(library_path, type, expected_values, literal_hex, id)
    JSON::Any.new({
      "id"                => JSON::Any.new(id),
      "declared_type"     => JSON::Any.new(type_name),
      "source_part_path"  => JSON::Any.new(source_path),
      "library_part_path" => JSON::Any.new(library_path),
      "row_keys"          => JSON::Any.new(row_keys.map { |value| JSON::Any.new(value.to_i64) }),
      "mark_rows"         => JSON::Any.new(mark_rows.map { |value| JSON::Any.new(value.to_i64) }),
      "source_rows"       => source_rows,
      "library_rows"      => render_rows(library_values),
    } of String => JSON::Any)
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 2 && args[0] == "--input"
      raise ArgumentError.new("usage: check_recursive_qbit_w230.cr --input FILE")
    end
    input_path = File.expand_path(args[1])
    info = File.info?(input_path, follow_symlinks: false) || raise CrystalClick::InvalidPartError.new("input manifest is missing")
    require!(info.file? && !info.type.symlink? && File.realpath(input_path) == input_path, "input manifest is not a canonical regular file")
    require!(info.size <= MAX_INPUT_BYTES, "input manifest exceeds its byte limit")
    input = JSON.parse(File.read(input_path))
    profiles = validate_input!(input, input_path)
    output_profiles = profiles.map { |profile| process_profile(profile) }
    puts JSON::Any.new({
      "format"        => JSON::Any.new(OUTPUT_FORMAT),
      "profile_count" => JSON::Any.new(output_profiles.size),
      "profiles"      => JSON::Any.new(output_profiles),
    } of String => JSON::Any).to_json
  rescue ex : Exception
    STDERR.puts "W230 QBit helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckRecursiveQBitW230.main(ARGV)
