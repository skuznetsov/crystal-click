require "../src/crystal_click"
require "digest/sha256"
require "json"
require "file_utils"
require "option_parser"
require "./support/geometry_composition_w239_semantics"

module CheckGeometryCompositionW239
  extend self

  INPUT_FORMAT     = "geometry_composition_w239_stock_v1"
  OUTPUT_FORMAT    = "geometry_composition_w239_helper_v1"
  OUTPUT_PREFIX    = "/private/tmp/crystal-click-w239-generated."
  MAX_MATRIX_BYTES = 16 * 1024 * 1024
  KEY_COLUMN       = "pk"
  VALUE_COLUMN     = "payload"
  PROFILE_IDS      = %w[
    geometry array_geometry tuple_string_geometry map_string_geometry nested_geometry_point
    nullable_tuple_geometry variant_string_tuple_geometry
  ]
  TYPED_CONSUMER_IDS = %w[
    array_geometry tuple_string_geometry map_string_geometry nested_geometry_point
    nullable_tuple_geometry variant_string_tuple_geometry
  ]
  WRAPPER_KEYS       = [11_u64, 22_u64, 33_u64, 44_u64, 55_u64]
  GEOMETRY_KEYS      = [11_u64, 22_u64, 33_u64, 44_u64, 55_u64, 66_u64, 77_u64, 88_u64, 99_u64, 111_u64]
  WRAPPER_MARK_ROWS  = [2_u64, 2_u64, 1_u64]
  GEOMETRY_MARK_ROWS = [2_u64, 2_u64, 2_u64, 2_u64, 2_u64]
  GEO_ARMS           = %w[LineString MultiLineString MultiPolygon Point Polygon Ring MultiPoint]

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W239 Geometry helper: #{message}") unless condition
  end

  private def decode_hex(hex : String) : Bytes
    unless hex.bytesize.even? && hex.matches?(/\A(?:[0-9a-f]{2})*\z/)
      raise ArgumentError.new("W239 literal bytes must be even lowercase hexadecimal")
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
    raise ArgumentError.new("W239 literal bytes are not lowercase hexadecimal")
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

  private def shape_node(tag : UInt8, name : String, fields : Array(String), children : Array(JSON::Any)) : JSON::Any
    JSON::Any.new({
      "tag" => JSON::Any.new(tag.to_i64), "name" => JSON::Any.new(name),
      "field_names" => json_strings(fields), "children" => JSON::Any.new(children),
    } of String => JSON::Any)
  end

  private def type_shape_record(type : CrystalClick::BinaryDataType) : JSON::Any
    children = Array(JSON::Any).new(type.child_count) do |index|
      type_shape_record(type.child_at(index))
    end
    shape_node(type.tag, type.name, type.field_names, children)
  end

  private def primitive_shape(tag : UInt8, name : String) : JSON::Any
    shape_node(tag, name, [] of String, [] of JSON::Any)
  end

  private def custom_shape(name : String) : JSON::Any
    storage = case name
              when "Geometry"
                arms = GEO_ARMS.map { |arm| custom_shape(arm) }
                variant_name = "Variant(#{GEO_ARMS.join(", ")})"
                shape_node(CrystalClick::BinaryDataType::TAG_VARIANT, variant_name, [] of String, arms)
              when "Point"
                float = primitive_shape(CrystalClick::BinaryDataType::TAG_FLOAT64, "Float64")
                shape_node(CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
                  "Tuple(Float64, Float64)", [] of String, [float, float])
              when "LineString", "Ring", "MultiPoint"
                point = custom_shape("Point")
                shape_node(CrystalClick::BinaryDataType::TAG_ARRAY, "Array(Point)", [] of String, [point])
              when "MultiLineString"
                shape_node(CrystalClick::BinaryDataType::TAG_ARRAY, "Array(LineString)", [] of String,
                  [custom_shape("LineString")])
              when "Polygon"
                shape_node(CrystalClick::BinaryDataType::TAG_ARRAY, "Array(Ring)", [] of String,
                  [custom_shape("Ring")])
              when "MultiPolygon"
                shape_node(CrystalClick::BinaryDataType::TAG_ARRAY, "Array(Polygon)", [] of String,
                  [custom_shape("Polygon")])
              else
                raise ArgumentError.new("unlisted W239 Custom Geo storage shape #{name}")
              end
    shape_node(CrystalClick::BinaryDataType::TAG_CUSTOM, name, [] of String, [storage])
  end

  private def expected_type_shape(id : String) : JSON::Any
    geometry = custom_shape("Geometry")
    string = primitive_shape(CrystalClick::BinaryDataType::TAG_STRING, "String")
    case id
    when "geometry"
      geometry
    when "array_geometry"
      shape_node(CrystalClick::BinaryDataType::TAG_ARRAY, "Array(Geometry)", [] of String, [geometry])
    when "tuple_string_geometry"
      shape_node(CrystalClick::BinaryDataType::TAG_NAMED_TUPLE, "Tuple(label String, geom Geometry)",
        ["label", "geom"], [string, geometry])
    when "map_string_geometry"
      shape_node(CrystalClick::BinaryDataType::TAG_MAP, "Map(String, Geometry)", [] of String, [string, geometry])
    when "nested_geometry_point"
      point = custom_shape("Point")
      tuple = shape_node(CrystalClick::BinaryDataType::TAG_NAMED_TUPLE,
        "Tuple(geom Geometry, point Point)", ["geom", "point"], [geometry, point])
      shape_node(CrystalClick::BinaryDataType::TAG_NESTED,
        "Nested(geom Geometry, point Point)", [] of String, [tuple])
    when "nullable_tuple_geometry"
      tuple = shape_node(CrystalClick::BinaryDataType::TAG_NAMED_TUPLE, "Tuple(geom Geometry)",
        ["geom"], [geometry])
      shape_node(CrystalClick::BinaryDataType::TAG_NULLABLE, "Nullable(Tuple(geom Geometry))", [] of String, [tuple])
    when "variant_string_tuple_geometry"
      tuple = shape_node(CrystalClick::BinaryDataType::TAG_NAMED_TUPLE, "Tuple(geom Geometry)",
        ["geom"], [geometry])
      shape_node(CrystalClick::BinaryDataType::TAG_VARIANT,
        "Variant(String, Tuple(geom Geometry))", [] of String, [string, tuple])
    else
      raise ArgumentError.new("unlisted W239 type shape #{id}")
    end
  end

  private def verify_geometry_marker!(type : CrystalClick::BinaryDataType) : Nil
    if type.tag == CrystalClick::BinaryDataType::TAG_CUSTOM && type.custom_geo_type.try(&.name) == "Geometry"
      require!(type.child_count == 1 && type.child_at(0).geometry_storage_variant?,
        "Geometry lost its closed fixed-discriminator storage owner")
    end
    type.child_count.times { |index| verify_geometry_marker!(type.child_at(index)) }
  end

  private def profile_type!(profile : JSON::Any) : CrystalClick::BinaryDataType
    id = profile["id"].as_s
    declared = profile["requested_type"].as_s
    require!(PROFILE_IDS.includes?(id), "unlisted profile id #{id}")
    type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(declared) ||
           raise ArgumentError.new("#{id} declared type is not canonical")
    admitted = CrystalClick::BinaryCustomGeoBulkColumnDeclaration.parse(declared)
    require!(type.name == declared && admitted == type,
      "#{id} is outside exact static Geometry recursive admission")
    verify_geometry_marker!(type)
    actual_shape = type_shape_record(type)
    require!(actual_shape.to_json == expected_type_shape(id).to_json,
      "#{id} nominal recursive type tree differs: #{actual_shape.to_json}")
    require!(encode_hex(CrystalClick::BinaryDataTypeCodec.encode(type)) == profile["descriptor_hex"].as_s,
      "#{id} independent descriptor literal differs")
    type
  end

  private def expected_values(profile : JSON::Any, type : CrystalClick::BinaryDataType) : Array(CrystalClick::BinaryValue)
    id = profile["id"].as_s
    literals = profile["rowbinary_values_hex"].as_a
    semantic_values = CrystalClick::GeometryCompositionW239Semantics.values(id, type)
    require!(semantic_values.size == literals.size, "#{id} independent semantic fixture row count differs")
    literals.map_with_index do |item, index|
      literal = decode_hex(item.as_s)
      decoded = CrystalClick::BinaryValueCodec.decode_value(type, literal)
      require!(decoded.type == type, "#{id} scalar decoder lost nominal type identity")
      require!(CrystalClick::GeometryCompositionW239Semantics.same_value?(decoded, semantic_values[index]),
        "#{id} decoded RowBinary scalar differs from the independent semantic fixture at row #{index}")
      require!(CrystalClick::BinaryValueCodec.encode_value(decoded) == literal,
        "#{id} independent scalar literal is not preserved exactly")
      require!(CrystalClick::BinaryValueCodec.encode_value(semantic_values[index]) == literal,
        "#{id} independent semantic fixture does not match the literal bytes at row #{index}")
      semantic_values[index]
    end
    require!(semantic_values.size == expected_keys(id).size, "#{id} scalar literal row count differs")
    semantic_values
  end

  private def expected_keys(id : String) : Array(UInt64)
    id == "geometry" ? GEOMETRY_KEYS : WRAPPER_KEYS
  end

  private def expected_mark_rows(id : String) : Array(UInt64)
    id == "geometry" ? GEOMETRY_MARK_ROWS : WRAPPER_MARK_ROWS
  end

  private def value_hex(values : Array(CrystalClick::BinaryValue)) : Array(String)
    values.map { |value| encode_hex(CrystalClick::BinaryValueCodec.encode_value(value)) }
  end

  # Geometry's hidden fixed-order storage Variant has no stand-alone descriptor.
  # Compare the whole nominal-root wire value once, then compare every node's
  # type identity, tag/name/field roster, null state, selected Variant tag,
  # primitive payload, and ordered child structure without encoding hidden
  # children as roots.
  private def binary_value_tree_equal?(left : CrystalClick::BinaryValue, right : CrystalClick::BinaryValue) : Bool
    CrystalClick::GeometryCompositionW239Semantics.same_value?(left, right)
  end

  private def assert_values!(actual : Array(CrystalClick::BinaryValue), expected : Array(CrystalClick::BinaryValue), label : String) : Nil
    require!(actual.size == expected.size, "#{label} row count differs")
    actual.each_with_index do |value, index|
      require!(CrystalClick::BinaryValueCodec.encode_value(value) == CrystalClick::BinaryValueCodec.encode_value(expected[index]),
        "#{label} exact root bytes differ at row #{index}")
      require!(binary_value_tree_equal?(value, expected[index]), "#{label} recursive nominal value tree differs at row #{index}")
    end
  end

  private def direct_reader_record(part : String, type : CrystalClick::BinaryDataType,
                                   expected : Array(CrystalClick::BinaryValue), id : String, side : String) : JSON::Any
    marks = expected_mark_rows(id)
    reader = CrystalClick::BinaryBulkColumnReader.open(part, VALUE_COLUMN, type)
    require!(reader.schema_declaration == type.name && reader.source_declaration == type.name,
      "#{side}/#{id} persisted nominal type differs")
    require!(reader.row_count == expected.size.to_u64 && reader.mark_count == marks.size && reader.mark_row_counts == marks,
      "#{side}/#{id} row/mark schedule differs")
    full = reader.read_marks(0, marks.size).flatten
    middle_start = 1
    middle_count = id == "geometry" ? 2 : 1
    first_middle_row = marks[0, middle_start].sum(&.to_i).to_i
    middle_rows = marks[middle_start, middle_count].sum(&.to_i).to_i
    middle = reader.read_marks(middle_start, middle_count).flatten
    final_index = marks.size - 1
    final = reader.read_marks(final_index, 1).first
    eof = reader.read_marks(marks.size, 0)
    assert_values!(full, expected, "#{side}/#{id} full direct read")
    assert_values!(middle, expected[first_middle_row, middle_rows], "#{side}/#{id} middle direct read")
    assert_values!(final, expected[expected.size - marks.last.to_i, marks.last.to_i], "#{side}/#{id} final direct read")
    require!(eof.empty?, "#{side}/#{id} direct EOF is not empty")
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
      "final_values_hex"        => json_strings(value_hex(final)),
      "eof_empty"               => JSON::Any.new(eof.empty?),
    } of String => JSON::Any)
  end

  private def typed_consumer_record(part : String, type : CrystalClick::BinaryDataType,
                                    expected : Array(CrystalClick::BinaryValue), id : String, side : String) : JSON::Any
    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_COLUMN, VALUE_COLUMN])
    keys = [] of UInt64
    values = [] of CrystalClick::BinaryValue
    table.scan_typed(batch_rows: 2) do |batch|
      key_batch = batch.values_for(KEY_COLUMN)
      value_batch = batch.binary_bulk_values_for(VALUE_COLUMN)
      require!(key_batch.size == value_batch.size, "#{side}/#{id} typed batch columns are misaligned")
      key_batch.each_with_index do |key, index|
        require!(value_batch[index].type == type, "#{side}/#{id} typed consumer lost nominal root type")
        keys << key
        values << value_batch[index]
      end
    end
    require!(keys == expected_keys(id), "#{side}/#{id} typed full scan keys differ")
    assert_values!(values, expected, "#{side}/#{id} typed full scan")
    middle = [] of CrystalClick::BinaryValue
    table.scan_typed_window(1_u64, max_rows: 3) do |batch|
      middle.concat(batch.binary_bulk_values_for(VALUE_COLUMN))
    end
    assert_values!(middle, expected[1, 3], "#{side}/#{id} typed middle window")
    eof_callbacks = 0
    table.scan_typed_window(expected.size.to_u64, max_rows: 1) { |_batch| eof_callbacks += 1 }
    require!(eof_callbacks == 0, "#{side}/#{id} typed EOF emitted a callback")
    JSON::Any.new({
      "api" => JSON::Any.new("WidePartTable.open_selected_typed + scan_typed + scan_typed_window + binary_bulk_values_for"),
      "keys" => json_u64s(keys), "values_hex" => json_strings(value_hex(values)),
      "full_values_hex" => json_strings(value_hex(values)),
      "middle_window_values_hex" => json_strings(value_hex(middle)),
      "eof_callbacks" => JSON::Any.new(eof_callbacks),
    } of String => JSON::Any)
  end

  private def assert_point_bits!(actual : CrystalClick::WidePointValue,
                                 expected : CrystalClick::BinaryValue, label : String) : Nil
    require!(expected.type.tag == CrystalClick::BinaryDataType::TAG_CUSTOM && expected.type.name == "Point",
      "#{label} independent fixture node is not Point")
    tuple = expected.child_at(0)
    require!(tuple.type.tag == CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE && tuple.child_count == 2,
      "#{label} independent Point coordinate tuple differs")
    x_bits = tuple.child_at(0).as_float64_bits
    y_bits = tuple.child_at(1).as_float64_bits
    require!(actual.x_bits == x_bits && actual.y_bits == y_bits,
      "#{label} legacy Point coordinate bits differ from the independent fixture")
  end

  private def assert_geo_array_row!(actual : CrystalClick::WideGeoArrayRow,
                                    expected : CrystalClick::BinaryValue, label : String) : Nil
    require!(expected.type.tag == CrystalClick::BinaryDataType::TAG_ARRAY,
      "#{label} independent Geo Array node is not Array")
    expected_element_type = expected.type.child_at(0)
    expected_terminal = expected_element_type.tag == CrystalClick::BinaryDataType::TAG_CUSTOM &&
                        expected_element_type.name == "Point"
    require!(actual.terminal? == expected_terminal,
      "#{label} legacy Geo Array topology depth differs from the independent fixture")
    require!(actual.size == expected.child_count,
      "#{label} legacy Geo Array child count differs from the independent fixture")
    actual.size.times do |index|
      child = expected.child_at(index)
      if expected_terminal
        assert_point_bits!(actual.point_at(index), child, "#{label}/point[#{index}]")
      else
        require!(child.type.tag == CrystalClick::BinaryDataType::TAG_CUSTOM && child.child_count == 1,
          "#{label} independent nested Geo Array node is not a Custom alias")
        nested_array = child.child_at(0)
        assert_geo_array_row!(actual.array_at(index), nested_array, "#{label}/array[#{index}]")
      end
    end
  end

  private def legacy_geometry_record(part : String, expected : Array(CrystalClick::BinaryValue)) : JSON::Any
    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_COLUMN, VALUE_COLUMN])
    keys = [] of UInt64
    tags = [] of Int64
    table.scan_typed(batch_rows: 2) do |batch|
      key_batch = batch.values_for(KEY_COLUMN)
      rows = batch.geometry_rows_for(VALUE_COLUMN)
      require!(key_batch.size == rows.size, "bare Geometry typed consumer columns are misaligned")
      key_batch.each_with_index do |key, index|
        fixture = expected[keys.size]
        fixture_variant = fixture.child_at(0)
        fixture_tag = fixture_variant.variant_index? || 255_u8
        row = rows[index]
        require!(row.type_name == "Geometry", "bare Geometry legacy row lost nominal type")
        require!(row.tag == fixture_tag, "bare Geometry legacy tag differs from independent fixture")
        require!(row.null? == (fixture_tag == 255_u8), "bare Geometry legacy NULL state differs")
        if fixture_tag == 255_u8
          require!(fixture_variant.is_null? && fixture_variant.child_count == 0 && row.arm.nil?,
            "bare Geometry intrinsic NULL differs from independent fixture")
        else
          arm = row.arm || raise(CrystalClick::CorruptPartError.new("bare Geometry legacy arm is absent"))
          fixture_arm = fixture_variant.variant_child? || raise(CrystalClick::CorruptPartError.new("fixture Geometry arm value is absent"))
          fixture_enum_arm = CrystalClick::WideGeometryArm.for_tag(fixture_tag) ||
                             raise(CrystalClick::CorruptPartError.new("fixture Geometry tag is outside the fixed arm roster"))
          require!(arm == fixture_enum_arm,
            "bare Geometry legacy arm tag differs from independent fixture")
          require!(row.arm_type_name == GEO_ARMS[fixture_tag.to_i] && fixture_arm.type.name == row.arm_type_name,
            "bare Geometry legacy arm name differs from independent fixture")
          if fixture_arm.type.name == "Point"
            assert_point_bits!(row.point, fixture_arm, "bare Geometry row #{keys.size}/Point")
          else
            expected_array = fixture_arm.child_at(0)
            require!(row.geo_array.type_name == fixture_arm.type.name,
              "bare Geometry legacy Geo Array arm name differs from independent fixture")
            assert_geo_array_row!(row.geo_array, expected_array, "bare Geometry row #{keys.size}/#{fixture_arm.type.name}")
          end
        end
        keys << key
        tags << row.tag.to_i64
      end
    end
    require!(keys == GEOMETRY_KEYS, "bare Geometry legacy typed scan keys differ")
    JSON::Any.new({
      "api" => JSON::Any.new("WidePartTable.open_selected_typed + geometry_rows_for"),
      "keys" => json_u64s(keys), "tags" => json_ints(tags),
      "null_count" => JSON::Any.new(tags.count(255_i64)),
    } of String => JSON::Any)
  end

  private def process_profile(profile : JSON::Any, output_root : String, index : Int32) : JSON::Any
    id = profile["id"].as_s
    type = profile_type!(profile)
    expected = expected_values(profile, type)
    keys = expected_keys(id)
    marks = expected_mark_rows(id)
    require!(profile["keys"].as_a.map(&.as_i64) == keys.map(&.to_i64), "#{id} stock keys differ")
    require!(profile["row_count"].as_i == expected.size, "#{id} stock row count differs")
    stock_part = File.expand_path(profile["stock_part_path"].as_s)
    require!(Dir.exists?(stock_part) && !File.symlink?(stock_part) && File.realpath(stock_part) == stock_part,
      "#{id} stock part is absent or noncanonical")
    profile_root = File.join(output_root, "generated", id)
    Dir.mkdir(profile_root, 0o700)
    library_part = File.join(profile_root, "all_1_1_0")
    stock_reader = direct_reader_record(stock_part, type, expected, id, "stock")
    granules = [] of Array(CrystalClick::BinaryValue)
    offset = 0
    marks.each do |count|
      granules << expected[offset, count.to_i]
      offset += count.to_i
    end
    written = CrystalClick::WidePartWriter.write_uint64_custom_geo_bulk_part(
      library_part, KEY_COLUMN, keys.to_unsafe.to_slice(keys.size), VALUE_COLUMN,
      type, granules, rows_per_mark: 2, profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      frame_bytes: 4096
    )
    require!(written == library_part && Dir.exists?(written) && !File.symlink?(written),
      "#{id} writer did not publish at its exact destination")
    generated_reader = direct_reader_record(written, type, expected, id, "generated")
    stock_consumer = if TYPED_CONSUMER_IDS.includes?(id)
                       typed_consumer_record(stock_part, type, expected, id, "stock")
                     elsif id == "geometry"
                       legacy_geometry_record(stock_part, expected)
                     else
                       JSON::Any.new(nil)
                     end
    generated_consumer = if TYPED_CONSUMER_IDS.includes?(id)
                           typed_consumer_record(written, type, expected, id, "generated")
                         elsif id == "geometry"
                           legacy_geometry_record(written, expected)
                         else
                           JSON::Any.new(nil)
                         end
    JSON::Any.new({
      "id" => JSON::Any.new(id), "declared_type" => JSON::Any.new(type.name),
      "type_shape" => type_shape_record(type), "stock_part_path" => JSON::Any.new(stock_part),
      "library_part_path" => JSON::Any.new(written),
      "descriptor_hex" => JSON::Any.new(encode_hex(CrystalClick::BinaryDataTypeCodec.encode(type))),
      "values_hex" => json_strings(profile["rowbinary_values_hex"].as_a.map(&.as_s)),
      "row_keys" => json_u64s(keys), "mark_rows" => json_u64s(marks),
      "writer" => JSON::Any.new({
        "api" => JSON::Any.new("WidePartWriter.write_uint64_custom_geo_bulk_part"),
        "rows_per_mark" => JSON::Any.new(2), "profile" => JSON::Any.new("with_size_stream"),
        "frame_bytes" => JSON::Any.new(4096), "granule_row_counts" => json_ints(marks.map(&.to_i64)),
      } of String => JSON::Any),
      "stock_direct_reader" => stock_reader, "direct_reader" => generated_reader,
      "stock_typed_consumer" => stock_consumer, "typed_consumer" => generated_consumer,
    } of String => JSON::Any)
  end

  private def validate_fresh_root(path : String) : String
    full = File.expand_path(path)
    unless Dir.exists?(full) && !File.symlink?(full) && File.realpath(full) == full &&
           File.dirname(full) == File.realpath("/private/tmp") && full.starts_with?(OUTPUT_PREFIX)
      raise ArgumentError.new("W239 output root must be a canonical direct /private/tmp child with the fixed prefix")
    end
    raise ArgumentError.new("W239 output root must be empty") unless Dir.children(full).empty?
    full
  end

  def run(stock_matrix : String, output_root : String) : Nil
    matrix_path = File.expand_path(stock_matrix)
    raise ArgumentError.new("W239 stock matrix is not a regular file") unless File.file?(matrix_path) && !File.symlink?(matrix_path)
    raise ArgumentError.new("W239 stock matrix exceeds its byte bound") if File.size(matrix_path) > MAX_MATRIX_BYTES
    root = validate_fresh_root(output_root)
    matrix_bytes = File.read(matrix_path)
    matrix = JSON.parse(matrix_bytes)
    require!(matrix["format"].as_s == INPUT_FORMAT, "stock matrix format differs")
    profiles = matrix["profiles"].as_a
    require!(profiles.size == PROFILE_IDS.size && profiles.map { |profile| profile["id"].as_s } == PROFILE_IDS,
      "stock matrix exact profile roster/order differs")
    generated_root = File.join(root, "generated")
    Dir.mkdir(generated_root, 0o700)
    records = profiles.map_with_index { |profile, index| process_profile(profile, root, index) }
    puts JSON::Any.new({
      "format"        => JSON::Any.new(OUTPUT_FORMAT),
      "matrix_path"   => JSON::Any.new(matrix_path),
      "matrix_sha256" => JSON::Any.new(Digest::SHA256.hexdigest(matrix_bytes)),
      "output_root"   => JSON::Any.new(root),
      "profiles"      => JSON::Any.new(records),
    } of String => JSON::Any).to_json
  end
end

options = {} of Symbol => String
OptionParser.parse do |parser|
  parser.on("--stock-matrix PATH", "W239 stock-only Geometry matrix JSON") { |value| options[:stock_matrix] = value }
  parser.on("--output-root PATH", "Fresh canonical direct /private/tmp generated-parts directory") { |value| options[:output_root] = value }
end
unless options.size == 2 && options.has_key?(:stock_matrix) && options.has_key?(:output_root)
  raise ArgumentError.new("Usage: crystal build scripts/check_geometry_composition_w239.cr -o HELPER; run HELPER --stock-matrix PATH --output-root EMPTY_W239_GENERATED_ROOT")
end
CheckGeometryCompositionW239.run(options[:stock_matrix], options[:output_root])
