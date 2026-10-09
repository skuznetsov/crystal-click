require "../src/crystal_click"
require "digest/sha256"
require "json"
require "file_utils"
require "option_parser"

module CheckCustomGeoRecursiveW238
  extend self

  FORMAT_INPUT     = "custom_geo_recursive_w238_stock_v1"
  FORMAT_OUTPUT    = "custom_geo_recursive_w238_helper_v1"
  OUTPUT_PREFIX    = "/private/tmp/crystal-click-w238-generated."
  MAX_MATRIX_BYTES = 16 * 1024 * 1024
  KEY_COLUMN       = "pk"
  VALUE_COLUMN     = "payload"
  ROW_KEYS         = [11_u64, 22_u64, 33_u64, 44_u64, 55_u64]
  MARK_ROWS        = [2_u64, 2_u64, 1_u64]
  PROFILE_IDS      = %w[
    point multi_point line_string ring multi_line_string polygon multi_polygon
    nullable_point array_point tuple_string_point map_string_point nested_point_line
    variant_point_string
  ]
  TYPED_CONSUMER_IDS = %w[
    nullable_point array_point tuple_string_point map_string_point nested_point_line
    variant_point_string
  ]

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W238 Custom Geo helper: #{message}") unless condition
  end

  private def decode_hex(hex : String) : Bytes
    unless hex.bytesize.even? && hex.matches?(/\A(?:[0-9a-f]{2})*\z/)
      raise ArgumentError.new("W238 literal bytes must be even lowercase hexadecimal")
    end
    Bytes.new(hex.bytesize // 2) do |index|
      ((nibble(hex.byte_at(index * 2)) << 4) | nibble(hex.byte_at(index * 2 + 1))).to_u8
    end
  end

  private def nibble(byte : UInt8) : UInt8
    if byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
      return (byte - '0'.ord.to_u8).to_u8
    end
    if byte >= 'a'.ord.to_u8 && byte <= 'f'.ord.to_u8
      return (byte - 'a'.ord.to_u8 + 10).to_u8
    end
    raise ArgumentError.new("W238 literal bytes are not lowercase hexadecimal")
  end

  private def encode_hex(bytes : Bytes) : String
    String.build { |io| bytes.each { |byte| io << byte.to_s(16).rjust(2, '0') } }
  end

  private def json_strings(values : Array(String)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private def json_ints(values : Array(Int64)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private def json_u64s(values : Array(UInt64)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value.to_i64) })
  end

  private def type_shape_record(type : CrystalClick::BinaryDataType) : JSON::Any
    children = Array(JSON::Any).new(type.child_count) do |index|
      type_shape_record(type.child_at(index))
    end
    JSON::Any.new({
      "tag"         => JSON::Any.new(type.tag.to_i64),
      "name"        => JSON::Any.new(type.name),
      "field_names" => json_strings(type.field_names),
      "children"    => JSON::Any.new(children),
    } of String => JSON::Any)
  end

  private def custom_shape(name : String) : JSON::Any
    shape_node(CrystalClick::BinaryDataType::TAG_CUSTOM, name, [] of String, [geo_storage_shape(name)])
  end

  private def geo_storage_shape(name : String) : JSON::Any
    case name
    when "Point"
      float = shape_node(CrystalClick::BinaryDataType::TAG_FLOAT64, "Float64", [] of String, [] of JSON::Any)
      shape_node(CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, "Tuple(Float64, Float64)",
        [] of String, [float, float])
    when "MultiPoint", "LineString", "Ring"
      shape_node(CrystalClick::BinaryDataType::TAG_ARRAY, "Array(Point)", [] of String, [custom_shape("Point")])
    when "MultiLineString"
      shape_node(CrystalClick::BinaryDataType::TAG_ARRAY, "Array(LineString)", [] of String,
        [custom_shape("LineString")])
    when "Polygon"
      shape_node(CrystalClick::BinaryDataType::TAG_ARRAY, "Array(Ring)", [] of String, [custom_shape("Ring")])
    when "MultiPolygon"
      shape_node(CrystalClick::BinaryDataType::TAG_ARRAY, "Array(Polygon)", [] of String,
        [custom_shape("Polygon")])
    else
      raise ArgumentError.new("unlisted W238 Custom Geo storage shape #{name}")
    end
  end

  private def shape_node(
    tag : UInt8,
    name : String,
    field_names : Array(String),
    children : Array(JSON::Any),
  ) : JSON::Any
    JSON::Any.new({
      "tag"         => JSON::Any.new(tag.to_i64),
      "name"        => JSON::Any.new(name),
      "field_names" => json_strings(field_names),
      "children"    => JSON::Any.new(children),
    } of String => JSON::Any)
  end

  private def expected_type_shape(id : String) : JSON::Any
    point = custom_shape("Point")
    string = shape_node(CrystalClick::BinaryDataType::TAG_STRING, "String", [] of String, [] of JSON::Any)
    case id
    when "point", "multi_point", "line_string", "ring", "multi_line_string", "polygon", "multi_polygon"
      names = {
        "point" => "Point", "multi_point" => "MultiPoint", "line_string" => "LineString",
        "ring" => "Ring", "multi_line_string" => "MultiLineString", "polygon" => "Polygon",
        "multi_polygon" => "MultiPolygon",
      }
      custom_shape(names[id])
    when "nullable_point"
      shape_node(CrystalClick::BinaryDataType::TAG_NULLABLE, "Nullable(Point)", [] of String, [point])
    when "array_point"
      shape_node(CrystalClick::BinaryDataType::TAG_ARRAY, "Array(Point)", [] of String, [point])
    when "tuple_string_point"
      shape_node(CrystalClick::BinaryDataType::TAG_NAMED_TUPLE, "Tuple(label String, point Point)",
        ["label", "point"], [string, point])
    when "map_string_point"
      shape_node(CrystalClick::BinaryDataType::TAG_MAP, "Map(String, Point)", [] of String, [string, point])
    when "nested_point_line"
      tuple = shape_node(CrystalClick::BinaryDataType::TAG_NAMED_TUPLE,
        "Tuple(point Point, line LineString)", ["point", "line"], [point, custom_shape("LineString")])
      shape_node(CrystalClick::BinaryDataType::TAG_NESTED,
        "Nested(point Point, line LineString)", [] of String, [tuple])
    when "variant_point_string"
      shape_node(CrystalClick::BinaryDataType::TAG_VARIANT, "Variant(Point, String)", [] of String, [point, string])
    else
      raise ArgumentError.new("unlisted W238 nominal type shape #{id}")
    end
  end

  private def profile_type!(profile : JSON::Any) : CrystalClick::BinaryDataType
    id = profile["id"].as_s
    declared = profile["declared_type"].as_s
    type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(declared) ||
           raise ArgumentError.new("#{id} declared type is not canonical")
    admitted = CrystalClick::BinaryCustomGeoBulkColumnDeclaration.parse(declared)
    require!(PROFILE_IDS.includes?(id), "unlisted profile id #{id}")
    require!(type.name == declared && admitted == type, "#{id} is outside exact static Custom Geo declaration admission")
    actual_shape = type_shape_record(type)
    require!(actual_shape.to_json == expected_type_shape(id).to_json,
      "#{id} nominal recursive type tree differs: #{actual_shape.to_json}")
    descriptor = CrystalClick::BinaryDataTypeCodec.encode(type)
    require!(encode_hex(descriptor) == profile["descriptor_hex"].as_s, "#{id} independent descriptor differs")
    type
  end

  private def expected_values(profile : JSON::Any, type : CrystalClick::BinaryDataType) : Array(CrystalClick::BinaryValue)
    values = profile["values_hex"].as_a.map do |item|
      literal = decode_hex(item.as_s)
      value = CrystalClick::BinaryValueCodec.decode_value(type, literal)
      require!(value.type == type, "#{profile["id"].as_s} scalar decoder lost nominal type identity")
      require!(CrystalClick::BinaryValueCodec.encode_value(value) == literal,
        "#{profile["id"].as_s} scalar literal is not preserved exactly")
      value
    end
    require!(values.size == ROW_KEYS.size, "#{profile["id"].as_s} must contain five values")
    values
  end

  private def value_hex(values : Array(CrystalClick::BinaryValue)) : Array(String)
    values.map { |value| encode_hex(CrystalClick::BinaryValueCodec.encode_value(value)) }
  end

  private def assert_values!(actual : Array(CrystalClick::BinaryValue), expected : Array(CrystalClick::BinaryValue), label : String) : Nil
    require!(actual.size == expected.size, "#{label} row count differs")
    actual.each_with_index do |value, index|
      require!(binary_value_tree_equal?(value, expected[index]),
        "#{label} recursive value tree differs at row #{index}")
    end
  end

  # Compare each value node's nominal descriptor, null state, exact encoded
  # bytes, and ordered children. Variant's selected arm is queried only when
  # the descriptor itself is Variant; BinaryValue guards that accessor.
  private def binary_value_tree_equal?(left : CrystalClick::BinaryValue, right : CrystalClick::BinaryValue) : Bool
    return false unless left.type == right.type
    return false unless CrystalClick::BinaryDataTypeCodec.encode(left.type) == CrystalClick::BinaryDataTypeCodec.encode(right.type)
    return false unless left.is_null? == right.is_null?
    if left.type.tag == CrystalClick::BinaryDataType::TAG_VARIANT
      return false unless left.variant_index? == right.variant_index?
    end
    return false unless CrystalClick::BinaryValueCodec.encode_value(left) == CrystalClick::BinaryValueCodec.encode_value(right)
    return false unless left.child_count == right.child_count

    index = 0
    while index < left.child_count
      return false unless binary_value_tree_equal?(left.child_at(index), right.child_at(index))
      index += 1
    end
    true
  end

  private def direct_reader_record(
    part : String,
    type : CrystalClick::BinaryDataType,
    expected : Array(CrystalClick::BinaryValue),
    label : String,
  ) : JSON::Any
    reader = CrystalClick::BinaryBulkColumnReader.open(part, VALUE_COLUMN, type)
    require!(reader.schema_declaration == type.name && reader.source_declaration == type.name,
      "#{label} persisted nominal type differs")
    require!(reader.row_count == ROW_KEYS.size.to_u64 && reader.mark_count == MARK_ROWS.size,
      "#{label} row/mark counts differ")
    require!(reader.mark_row_counts == MARK_ROWS, "#{label} mark row schedule differs")

    full = reader.read_marks(0, 3).flatten
    middle = reader.read_marks(1, 1).first
    final_short = reader.read_marks(2, 1).first
    eof = reader.read_marks(3, 0)
    assert_values!(full, expected, "#{label} full marks")
    assert_values!(middle, expected[2, 2], "#{label} middle mark")
    assert_values!(final_short, expected[4, 1], "#{label} final short mark")
    require!(eof.empty?, "#{label} zero-mark EOF is not empty")

    JSON::Any.new({
      "schema_declaration"      => JSON::Any.new(reader.schema_declaration),
      "source_declaration"      => JSON::Any.new(reader.source_declaration),
      "row_count"               => JSON::Any.new(reader.row_count.to_i64),
      "mark_rows"               => json_u64s(reader.mark_row_counts),
      "mark_count"              => JSON::Any.new(reader.mark_count),
      "selected_checksum_names" => json_strings(reader.selected_checksum_names),
      "physical_stream_names"   => json_strings(reader.physical_stream_names),
      "full_values_hex"         => json_strings(value_hex(full)),
      "middle_values_hex"       => json_strings(value_hex(middle)),
      "final_short_values_hex"  => json_strings(value_hex(final_short)),
      "eof_empty"               => JSON::Any.new(eof.empty?),
    } of String => JSON::Any)
  end

  private def offline_table_for(
    part : String,
    output_root : String,
    type_name : String,
    id : String,
    side : String,
  ) : CrystalClick::OfflineTable
    token = PROFILE_IDS.index(id).not_nil!.to_s(16).rjust(12, '0')
    database_uuid = "23800000-0000-4000-8000-#{token}"
    table_uuid = "23810000-0000-4000-8000-#{token}"
    catalog = File.join(output_root, "offline-catalogs", "#{id}-#{side}")
    raise ArgumentError.new("#{id}/#{side} offline catalog already exists") if File.exists?(catalog) || File.symlink?(catalog)
    metadata = File.join(catalog, "metadata")
    database_store = File.join(catalog, "store", database_uuid[0, 3], database_uuid)
    table_store = File.join(catalog, "store", table_uuid[0, 3], table_uuid)
    [metadata, database_store, table_store].each { |path| FileUtils.mkdir_p(path) }
    File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
    File.write(File.join(database_store, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{type_name}\n)\nENGINE = MergeTree\nPRIMARY KEY pk\nORDER BY pk\n")
    File.write(File.join(table_store, "format_version.txt"), "1\n")
    FileUtils.mkdir_p(File.join(table_store, "detached"))
    FileUtils.cp_r(part, File.join(table_store, "all_1_1_0"))
    CrystalClick::OfflineCatalog.open(catalog)["lab"]["events"]
  end

  private def offline_values_record(
    part : String,
    output_root : String,
    type : CrystalClick::BinaryDataType,
    expected : Array(CrystalClick::BinaryValue),
    id : String,
    side : String,
  ) : JSON::Any
    label = "#{id}/#{side}"
    table = offline_table_for(part, output_root, type.name, id, side)
    owned_values = [] of CrystalClick::BinaryValue
    table[VALUE_COLUMN].values.each do |value|
      owned_values << value.as(CrystalClick::BinaryValue)
    end
    assert_values!(owned_values, expected, "#{id}/#{side} OfflineColumnSelection.values")

    all_values = [] of CrystalClick::BinaryValue
    all_keys = [] of UInt64
    table.scan_typed([KEY_COLUMN, VALUE_COLUMN], batch_rows: 2) do |batch|
      keys = batch.values_for(KEY_COLUMN)
      batch_values = batch.binary_bulk_values_for(VALUE_COLUMN)
      require!(keys.size == batch_values.size, "#{label} typed batch column lengths differ")
      keys.each_with_index do |key, index|
        require!(batch_values[index].type == type, "#{label} typed batch lost nominal type identity")
        all_keys << key
        all_values << batch_values[index]
      end
    end
    require!(all_keys == ROW_KEYS, "#{label} typed scan keys differ")
    assert_values!(all_values, expected, "#{label} typed full scan")

    middle_values = [] of CrystalClick::BinaryValue
    table.scan_typed_window([KEY_COLUMN, VALUE_COLUMN], 1_u64, max_rows: 3) do |batch|
      middle_values.concat(batch.binary_bulk_values_for(VALUE_COLUMN))
    end
    assert_values!(middle_values, expected[1, 3], "#{label} typed middle window")

    eof_callbacks = 0
    table.scan_typed_window([KEY_COLUMN, VALUE_COLUMN], 5_u64, max_rows: 1) { |_batch| eof_callbacks += 1 }
    require!(eof_callbacks == 0, "#{label} typed EOF emitted a callback")

    JSON::Any.new({
      "api"                      => JSON::Any.new("OfflineColumnSelection.values + OfflineTable.scan_typed + scan_typed_window"),
      "keys"                     => json_u64s(all_keys),
      "values_hex"               => json_strings(value_hex(owned_values)),
      "full_values_hex"          => json_strings(value_hex(all_values)),
      "middle_window_values_hex" => json_strings(value_hex(middle_values)),
      "eof_callbacks"            => JSON::Any.new(eof_callbacks),
    } of String => JSON::Any)
  end

  private def process_profile(profile : JSON::Any, generated_root : String, index : Int32) : JSON::Any
    id = profile["id"].as_s
    type = profile_type!(profile)
    expected = expected_values(profile, type)
    stock_part = File.expand_path(profile["stock_part_path"].as_s)
    require!(Dir.exists?(stock_part) && !File.symlink?(stock_part) && File.real_path(stock_part) == stock_part,
      "#{id} stock part is absent or noncanonical")

    profile_root = File.join(generated_root, "generated", id)
    Dir.mkdir(profile_root, 0o700)
    library_part = File.join(profile_root, "all_1_1_0")
    stock_reader = direct_reader_record(stock_part, type, expected, "stock/#{id}")
    granules = [expected[0, 2], expected[2, 2], expected[4, 1]]
    written = CrystalClick::WidePartWriter.write_uint64_custom_geo_bulk_part(
      library_part, KEY_COLUMN, ROW_KEYS.to_unsafe.to_slice(ROW_KEYS.size), VALUE_COLUMN,
      type, granules, rows_per_mark: 2, profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      frame_bytes: 4096
    )
    require!(written == library_part && Dir.exists?(written) && !File.symlink?(written),
      "#{id} writer did not publish at its exact destination")
    generated_reader = direct_reader_record(written, type, expected, "generated/#{id}")

    stock_consumers = if TYPED_CONSUMER_IDS.includes?(id)
                        offline_values_record(stock_part, generated_root, type, expected, id, "stock")
                      else
                        JSON::Any.new(nil)
                      end
    library_consumers = if TYPED_CONSUMER_IDS.includes?(id)
                          offline_values_record(written, generated_root, type, expected, id, "library")
                        else
                          JSON::Any.new(nil)
                        end

    JSON::Any.new({
      "id"                => JSON::Any.new(id),
      "declared_type"     => JSON::Any.new(type.name),
      "type_shape"        => type_shape_record(type),
      "stock_part_path"   => JSON::Any.new(stock_part),
      "library_part_path" => JSON::Any.new(written),
      "descriptor_hex"    => JSON::Any.new(encode_hex(CrystalClick::BinaryDataTypeCodec.encode(type))),
      "values_hex"        => json_strings(profile["values_hex"].as_a.map(&.as_s)),
      "writer"            => JSON::Any.new({
        "api"                => JSON::Any.new("WidePartWriter.write_uint64_custom_geo_bulk_part"),
        "rows_per_mark"      => JSON::Any.new(2),
        "profile"            => JSON::Any.new("with_size_stream"),
        "granule_row_counts" => json_ints([2_i64, 2_i64, 1_i64]),
      } of String => JSON::Any),
      "stock_direct_reader"  => stock_reader,
      "direct_reader"        => generated_reader,
      "stock_typed_consumer" => stock_consumers,
      "typed_consumer"       => library_consumers,
    } of String => JSON::Any)
  end

  private def validate_fresh_root(path : String) : String
    full = File.expand_path(path)
    unless Dir.exists?(full) && !File.symlink?(full) && File.real_path(full) == full &&
           File.dirname(full) == File.real_path("/private/tmp") && full.starts_with?(OUTPUT_PREFIX)
      raise ArgumentError.new("W238 output root must be a fresh canonical direct child of /private/tmp with its fixed prefix")
    end
    raise ArgumentError.new("W238 output root must be empty") unless Dir.children(full).empty?
    full
  end

  def run(stock_matrix : String, output_root : String) : Nil
    matrix_path = File.expand_path(stock_matrix)
    raise ArgumentError.new("W238 stock matrix is not a regular file") unless File.file?(matrix_path) && !File.symlink?(matrix_path)
    raise ArgumentError.new("W238 stock matrix exceeds its byte bound") if File.size(matrix_path) > MAX_MATRIX_BYTES
    root = validate_fresh_root(output_root)
    matrix = JSON.parse(File.read(matrix_path))
    require!(matrix["format"].as_s == FORMAT_INPUT, "stock matrix format differs")
    require!(matrix["row_keys"].as_a.map(&.as_i64) == ROW_KEYS.map(&.to_i64), "stock matrix row keys differ")
    require!(matrix["mark_rows"].as_a.map(&.as_i64) == MARK_ROWS.map(&.to_i64), "stock matrix mark schedule differs")
    profiles = matrix["profiles"].as_a
    require!(profiles.size == PROFILE_IDS.size, "stock matrix profile count differs")
    require!(profiles.map { |profile| profile["id"].as_s } == PROFILE_IDS, "stock matrix profile order or identity differs")

    generated_root = File.join(root, "generated")
    Dir.mkdir(generated_root, 0o700)
    records = profiles.map_with_index do |profile, index|
      process_profile(profile, root, index)
    end
    output = JSON::Any.new({
      "format"        => JSON::Any.new(FORMAT_OUTPUT),
      "matrix_path"   => JSON::Any.new(matrix_path),
      "matrix_sha256" => JSON::Any.new(Digest::SHA256.hexdigest(File.read(matrix_path))),
      "output_root"   => JSON::Any.new(root),
      "row_keys"      => json_u64s(ROW_KEYS),
      "mark_rows"     => json_u64s(MARK_ROWS),
      "profiles"      => JSON::Any.new(records),
    } of String => JSON::Any)
    puts output.to_json
  end
end

options = {} of Symbol => String
OptionParser.parse do |parser|
  parser.on("--stock-matrix PATH", "Stock-only W238 matrix JSON") { |value| options[:stock_matrix] = value }
  parser.on("--output-root PATH", "Fresh canonical W238 generated-parts directory") { |value| options[:output_root] = value }
end
unless options.size == 2 && options.has_key?(:stock_matrix) && options.has_key?(:output_root)
  raise ArgumentError.new("Usage: crystal run scripts/check_custom_geo_recursive_w238.cr -- --stock-matrix PATH --output-root FRESH_ROOT")
end
CheckCustomGeoRecursiveW238.run(options[:stock_matrix], options[:output_root])
