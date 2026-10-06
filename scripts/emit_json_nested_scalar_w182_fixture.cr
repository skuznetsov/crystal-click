require "json"
require "../src/crystal_click"

module W182JSONNestedScalarFixtures
  extend self

  ORACLE_BINARY_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"

  struct Profile
    getter id : String
    getter type : CrystalClick::BinaryDataType
    getter type_name : String
    getter value : CrystalClick::BinaryValue
    getter descriptor_hex : String
    getter row_hex : String

    def initialize(
      @id : String,
      @type : CrystalClick::BinaryDataType,
      @type_name : String,
      @value : CrystalClick::BinaryValue,
      @descriptor_hex : String,
      @row_hex : String,
    )
    end
  end

  def require!(condition : Bool, message : String) : Nil
    raise message unless condition
  end

  def bytes_from_hex(hex : String) : Bytes
    unless hex.bytesize.even?
      raise ArgumentError.new("W182 hex literal has an odd byte count")
    end
    source = hex.to_slice
    Bytes.new(source.size // 2) do |index|
      (hex_nibble(source[index * 2]) << 4) | hex_nibble(source[index * 2 + 1])
    end
  end

  private def hex_nibble(byte : UInt8) : UInt8
    case byte
    when 0x30_u8..0x39_u8 then byte - 0x30_u8
    when 0x41_u8..0x46_u8 then byte - 0x41_u8 + 10_u8
    when 0x61_u8..0x66_u8 then byte - 0x61_u8 + 10_u8
    else
      raise ArgumentError.new("W182 hex literal contains a non-hex digit")
    end
  end

  private def fixed(type : CrystalClick::BinaryDataType, byte : UInt8) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(type, Bytes[byte])
  end

  private def inner_json_type(uint8 : CrystalClick::BinaryDataType) : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {"n" => uint8} of String => CrystalClick::BinaryDataType,
    )
  end

  private def json_value(
    type : CrystalClick::BinaryDataType,
    path : String,
    child : CrystalClick::BinaryValue,
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.json(
      type,
      CrystalClick::BinaryJsonRow.new(
        type,
        [{path, child}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )
  end

  private def inner_json_value(
    type : CrystalClick::BinaryDataType,
    uint8 : CrystalClick::BinaryDataType,
    byte : UInt8,
  ) : CrystalClick::BinaryValue
    json_value(type, "n", fixed(uint8, byte))
  end

  private def profile(
    id : String,
    type : CrystalClick::BinaryDataType,
    value : CrystalClick::BinaryValue,
    descriptor_hex : String,
    row_hex : String,
  ) : Profile
    Profile.new(id, type, type.name, value, descriptor_hex, row_hex)
  end

  def build_profiles : Array(Profile)
    string = CrystalClick::BinaryDataType.primitive("String")
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    inner = inner_json_type(uint8)
    json42 = inner_json_value(inner, uint8, 0x2a_u8)
    json7 = inner_json_value(inner, uint8, 0x07_u8)

    array_json = CrystalClick::BinaryDataType.array(inner)
    tuple_json_u8 = CrystalClick::BinaryDataType.tuple([inner, uint8] of CrystalClick::BinaryDataType)
    nested_json_u8 = CrystalClick::BinaryDataType.nested(
      [inner, uint8] of CrystalClick::BinaryDataType,
      ["j", "u"] of String,
    )
    nested_row_type = nested_json_u8.child_at(0)
    map_string_json = CrystalClick::BinaryDataType.map(string, inner)
    map_json_u8 = CrystalClick::BinaryDataType.map(inner, uint8)
    nullable_json = CrystalClick::BinaryDataType.nullable(inner)
    variant_json_u8 = CrystalClick::BinaryDataType.variant([inner, uint8] of CrystalClick::BinaryDataType)
    array_tuple_json_u8 = CrystalClick::BinaryDataType.array(tuple_json_u8)
    typed_json = CrystalClick::BinaryDataType.json(
      typed_paths: {"item" => inner} of String => CrystalClick::BinaryDataType,
    )
    typed_array_json_type = CrystalClick::BinaryDataType.array(inner)
    typed_array_json = CrystalClick::BinaryDataType.json(
      typed_paths: {"item" => typed_array_json_type} of String => CrystalClick::BinaryDataType,
    )
    runtime_json = CrystalClick::BinaryDataType.json
    dynamic_json = CrystalClick::BinaryDataType.dynamic(max_types: 0)

    nested_row = CrystalClick::BinaryValue.tuple(
      nested_row_type,
      [json42, fixed(uint8, 0x07_u8)] of CrystalClick::BinaryValue,
    )
    tuple_value = CrystalClick::BinaryValue.tuple(
      tuple_json_u8,
      [json42, fixed(uint8, 0x07_u8)] of CrystalClick::BinaryValue,
    )
    array_tuple_value = CrystalClick::BinaryValue.tuple(
      tuple_json_u8,
      [json42, fixed(uint8, 0x07_u8)] of CrystalClick::BinaryValue,
    )

    [
      profile(
        "array_json", array_json,
        CrystalClick::BinaryValue.array(array_json, [json42, json7] of CrystalClick::BinaryValue),
        "1e3000010101016e010000", "0201016e2a01016e07",
      ),
      profile(
        "tuple_json_u8", tuple_json_u8, tuple_value,
        "1f023000010101016e01000001", "01016e2a07",
      ),
      profile(
        "nested_json_u8", nested_json_u8,
        CrystalClick::BinaryValue.nested(nested_json_u8, [nested_row] of CrystalClick::BinaryValue),
        "2f02016a3000010101016e010000017501", "0101016e2a07",
      ),
      profile(
        "map_string_json", map_string_json,
        CrystalClick::BinaryValue.map(
          map_string_json,
          [CrystalClick::BinaryValue.string("k"), json7] of CrystalClick::BinaryValue,
        ),
        "27153000010101016e010000", "01016b01016e07",
      ),
      profile(
        "map_json_u8", map_json_u8,
        CrystalClick::BinaryValue.map(
          map_json_u8,
          [json42, fixed(uint8, 0x07_u8)] of CrystalClick::BinaryValue,
        ),
        "273000010101016e01000001", "0101016e2a07",
      ),
      profile(
        "nullable_json_present", nullable_json,
        CrystalClick::BinaryValue.nullable(nullable_json, json42),
        "233000010101016e010000", "0001016e2a",
      ),
      profile(
        "nullable_json_null", nullable_json,
        CrystalClick::BinaryValue.nullable(nullable_json),
        "233000010101016e010000", "01",
      ),
      profile(
        "variant_json_arm", variant_json_u8,
        CrystalClick::BinaryValue.variant(variant_json_u8, 0, json42),
        "2a023000010101016e01000001", "0001016e2a",
      ),
      profile(
        "variant_u8_arm", variant_json_u8,
        CrystalClick::BinaryValue.variant(variant_json_u8, 1, fixed(uint8, 0x07_u8)),
        "2a023000010101016e01000001", "0107",
      ),
      profile(
        "variant_null", variant_json_u8,
        CrystalClick::BinaryValue.variant_null(variant_json_u8),
        "2a023000010101016e01000001", "ff",
      ),
      profile(
        "array_tuple_json_u8", array_tuple_json_u8,
        CrystalClick::BinaryValue.array(array_tuple_json_u8, [array_tuple_value] of CrystalClick::BinaryValue),
        "1e1f023000010101016e01000001", "0101016e2a07",
      ),
      profile(
        "json_typed_child_json", typed_json,
        json_value(typed_json, "item", json42),
        "300080082001046974656d3000010101016e0100000000", "01046974656d01016e2a",
      ),
      profile(
        "json_typed_child_array_json", typed_array_json,
        json_value(
          typed_array_json,
          "item",
          CrystalClick::BinaryValue.array(typed_array_json_type, [json42, json7] of CrystalClick::BinaryValue),
        ),
        "300080082001046974656d1e3000010101016e0100000000", "01046974656d0201016e2a01016e07",
      ),
      profile(
        "json_runtime_child_json", runtime_json,
        json_value(runtime_json, "item", json42),
        "3000800820000000", "01046974656d3000010101016e01000001016e2a",
      ),
      profile(
        "dynamic_json", dynamic_json,
        CrystalClick::BinaryValue.dynamic(dynamic_json, json42),
        "2b00", "3000010101016e01000001016e2a",
      ),
    ] of Profile
  end

  def verify_inner_json!(value : CrystalClick::BinaryValue, expected_type : CrystalClick::BinaryDataType, byte : UInt8) : Nil
    require!(value.type == expected_type && value.type.name == expected_type.name,
      "nested JSON nominal descriptor differs")
    row = value.json_row
    require!(row.path_count == 1 && row.path_at(0) == "n", "nested JSON path accessor differs")
    scalar = row.value_at(0)
    require!(scalar.type.name == "UInt8" && scalar.bytes == Bytes[byte], "nested JSON typed value accessor differs")
  end

  private def verify_accessors!(profile : Profile, value : CrystalClick::BinaryValue) : Nil
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    inner = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {"n" => uint8} of String => CrystalClick::BinaryDataType,
    )
    case profile.id
    when "array_json"
      require!(value.element_count == 2, "Array(JSON) count differs")
      verify_inner_json!(value.element_at(0), inner, 0x2a_u8)
      verify_inner_json!(value.element_at(1), inner, 0x07_u8)
    when "tuple_json_u8"
      verify_inner_json!(value.child_at(0), inner, 0x2a_u8)
      require!(value.child_at(1).bytes == Bytes[0x07_u8], "Tuple(UInt8) field differs")
    when "nested_json_u8"
      require!(value.element_count == 1, "Nested(JSON, UInt8) row count differs")
      row = value.element_at(0)
      require!(row.type.field_name_at(0) == "j" && row.type.field_name_at(1) == "u",
        "Nested field-name accessors differ")
      verify_inner_json!(row.child_at(0), inner, 0x2a_u8)
      require!(row.child_at(1).bytes == Bytes[0x07_u8], "Nested UInt8 field differs")
    when "map_string_json"
      require!(value.element_count == 2, "Map(String, JSON) entry count differs")
      require!(value.element_at(0).as_string == "k", "Map(String, JSON) key accessor differs")
      verify_inner_json!(value.element_at(1), inner, 0x07_u8)
    when "map_json_u8"
      require!(value.element_count == 2, "Map(JSON, UInt8) entry count differs")
      verify_inner_json!(value.element_at(0), inner, 0x2a_u8)
      require!(value.element_at(1).bytes == Bytes[0x07_u8], "Map(JSON, UInt8) value accessor differs")
    when "nullable_json_present"
      verify_inner_json!(value.child_at(0), inner, 0x2a_u8)
    when "nullable_json_null"
      require!(value.is_null? && value.element_count == 0, "Nullable(JSON) NULL representation differs")
    when "variant_json_arm"
      require!(value.variant_index? == 0_u8, "Variant(JSON, UInt8) JSON discriminator differs")
      verify_inner_json!(value.variant_child?.not_nil!, inner, 0x2a_u8)
    when "variant_u8_arm"
      require!(value.variant_index? == 1_u8, "Variant(JSON, UInt8) UInt8 discriminator differs")
      require!(value.variant_child?.not_nil!.bytes == Bytes[0x07_u8], "Variant UInt8 arm differs")
    when "variant_null"
      require!(value.is_null? && value.variant_index?.nil? && value.variant_child?.nil?,
        "Variant NULL representation differs")
    when "array_tuple_json_u8"
      require!(value.element_count == 1, "Array(Tuple(JSON, UInt8)) count differs")
      tuple = value.element_at(0)
      verify_inner_json!(tuple.child_at(0), inner, 0x2a_u8)
      require!(tuple.child_at(1).bytes == Bytes[0x07_u8], "Array(Tuple(JSON, UInt8)) second field differs")
    when "json_typed_child_json", "json_runtime_child_json"
      row = value.json_row
      require!(row.path_count == 1 && row.path_at(0) == "item", "JSON child path accessor differs")
      verify_inner_json!(row.value_at(0), inner, 0x2a_u8)
    when "json_typed_child_array_json"
      row = value.json_row
      require!(row.path_count == 1 && row.path_at(0) == "item", "JSON typed Array path accessor differs")
      array = row.value_at(0)
      require!(array.element_count == 2, "JSON typed Array child count differs")
      verify_inner_json!(array.element_at(0), inner, 0x2a_u8)
      verify_inner_json!(array.element_at(1), inner, 0x07_u8)
    when "dynamic_json"
      require!(value.type.name == "Dynamic(max_types=0)" && value.element_count == 1,
        "Dynamic(JSON) nominal descriptor or selected child count differs")
      verify_inner_json!(value.child_at(0), inner, 0x2a_u8)
    else
      raise "unknown W182 profile #{profile.id}"
    end
  end

  def verify_profile!(profile : Profile, descriptor : Bytes, row : Bytes) : Nil
    expected_descriptor = bytes_from_hex(profile.descriptor_hex)
    expected_row = bytes_from_hex(profile.row_hex)
    require!(profile.type.name == profile.type_name, "#{profile.id}: constructed type name differs")
    require!(descriptor == expected_descriptor, "#{profile.id}: descriptor differs from independent literal")
    require!(row == expected_row, "#{profile.id}: row differs from independent literal")

    decoded_type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
    require!(decoded_type == profile.type && decoded_type.name == profile.type_name,
      "#{profile.id}: decoded nominal descriptor differs")
    require!(CrystalClick::BinaryDataTypeCodec.encode(profile.type) == expected_descriptor &&
             CrystalClick::BinaryDataTypeCodec.encode(decoded_type) == expected_descriptor,
      "#{profile.id}: descriptor does not re-encode byte-exactly")
    require!(CrystalClick::BinaryValueCodec.encode_value(profile.value) == expected_row,
      "#{profile.id}: constructed value does not match independent row literal")

    decoded_value = CrystalClick::BinaryValueCodec.decode_value(decoded_type, row)
    require!(decoded_value.type == profile.type && decoded_value.type.name == profile.type_name,
      "#{profile.id}: decoded value lost its nominal root descriptor")
    verify_accessors!(profile, decoded_value)
    require!(CrystalClick::BinaryValueCodec.encode_value(decoded_value) == expected_row,
      "#{profile.id}: decoded value does not re-encode byte-exactly")
  end

  private def fixture_root(path : String, require_empty : Bool) : String
    require!(!path.empty?, "fixture root path is required")
    expanded = File.expand_path(path)
    require!(!File.symlink?(expanded) && File.directory?(expanded), "fixture root must be an existing plain directory")
    root = File.realpath(expanded)
    tmp_root = File.realpath("/private/tmp")
    require!(root == expanded && File.dirname(root) == tmp_root, "fixture root must be a direct child of /private/tmp")
    require!(Dir.children(root).empty?, "fixture output root must be empty") if require_empty
    root
  end

  private def plain_file!(path : String, label : String) : Nil
    require!(File.file?(path) && !File.symlink?(path), "#{label} must be a plain file")
  end

  private def plain_directory!(path : String, label : String) : Nil
    require!(File.directory?(path) && !File.symlink?(path), "#{label} must be a plain directory")
  end

  private def read_bytes(path : String, label : String) : Bytes
    plain_file!(path, label)
    File.read(path).to_slice.dup
  end

  def emit_fixtures(path : String) : Nil
    root = fixture_root(path, true)
    profiles = build_profiles
    profiles.each do |profile|
      descriptor = CrystalClick::BinaryDataTypeCodec.encode(profile.type)
      row = CrystalClick::BinaryValueCodec.encode_value(profile.value)
      verify_profile!(profile, descriptor, row)
      directory = File.join(root, profile.id)
      Dir.mkdir(directory, 0o700)
      File.write(File.join(directory, "descriptor.bin"), descriptor)
      File.write(File.join(directory, "row.bin"), row)
    end
    puts "PASS W182 library fixtures: #{profiles.size} independent descriptors, accessors, and rows"
  end

  def verify_library(path : String) : Nil
    root = fixture_root(path, false)
    profiles = build_profiles
    require!(Dir.children(root).sort == profiles.map(&.id).sort, "library fixture roster differs")
    profiles.each do |profile|
      directory = File.join(root, profile.id)
      plain_directory!(directory, "#{profile.id} profile directory")
      require!(Dir.children(directory).sort == ["descriptor.bin", "row.bin"],
        "#{profile.id}: unexpected fixture files")
      descriptor = read_bytes(File.join(directory, "descriptor.bin"), "#{profile.id} descriptor")
      row = read_bytes(File.join(directory, "row.bin"), "#{profile.id} row")
      verify_profile!(profile, descriptor, row)
    end
    puts "PASS W182 library fixtures: #{profiles.size} exact descriptors, nominal accessors, and re-encodes"
  end

  private def verify_summary!(root : String, profiles : Array(Profile)) : Nil
    summary_path = File.join(root, "summary.json")
    plain_file!(summary_path, "native oracle summary")
    summary = JSON.parse(File.read(summary_path))
    require!(summary["status"].as_s == "all_profiles_match", "native oracle summary status differs")
    require!(summary["profile_count"].as_i == profiles.size && summary["profiles_ok"].as_i == profiles.size,
      "native oracle summary profile count differs")
    runtime = summary["runtime"]
    require!(runtime["sha256_before"].as_s == ORACLE_BINARY_SHA256 &&
             runtime["sha256_after"].as_s == ORACLE_BINARY_SHA256 &&
             runtime["before_pin_matches"].as_bool && runtime["after_pin_matches"].as_bool,
      "native oracle runtime identity is not pinned before and after profiles")
    require!(summary["library_fixtures_unchanged"].as_bool,
      "native oracle reports changed library fixtures")

    entries = summary["profiles"].as_a
    require!(entries.size == profiles.size, "native oracle profile summary roster differs")
    profiles.each_with_index do |profile, index|
      entry = entries[index]
      require!(entry["id"].as_s == profile.id && entry["type"].as_s == profile.type_name &&
               entry["expected_descriptor_hex"].as_s == profile.descriptor_hex &&
               entry["expected_row_hex"].as_s == profile.row_hex &&
               entry["stock_literal_exact"].as_bool && entry["library_binary_input_exact"].as_bool,
        "#{profile.id}: native oracle summary witness differs")
    end
  end

  def verify_stock(path : String) : Nil
    root = fixture_root(path, false)
    profiles = build_profiles
    verify_summary!(root, profiles)
    native_profiles = File.join(root, "profiles")
    plain_directory!(native_profiles, "native profile root")
    require!(Dir.children(native_profiles).sort == profiles.map(&.id).sort,
      "native profile directory roster differs")

    profiles.each do |profile|
      directory = File.join(native_profiles, profile.id)
      plain_directory!(directory, "#{profile.id} native profile directory")
      descriptor = read_bytes(File.join(directory, "descriptor.bin"), "#{profile.id} native descriptor")
      row = read_bytes(File.join(directory, "row.bin"), "#{profile.id} native row")
      verify_profile!(profile, descriptor, row)
    end
    puts "PASS W182 native stock fixtures: #{profiles.size} exact RowBinary descriptors, accessors, and rows"
  end
end

unless ARGV.size == 2
  raise "usage: crystal run scripts/emit_json_nested_scalar_w182_fixture.cr -- --emit-fixtures EMPTY_TMP_ROOT | --verify-library FIXTURE_ROOT | --verify-stock NATIVE_EVIDENCE_ROOT"
end

case ARGV[0]
when "--emit-fixtures"
  W182JSONNestedScalarFixtures.emit_fixtures(ARGV[1])
when "--verify-library"
  W182JSONNestedScalarFixtures.verify_library(ARGV[1])
when "--verify-stock"
  W182JSONNestedScalarFixtures.verify_stock(ARGV[1])
else
  raise "unknown W182 JSON nested scalar mode: #{ARGV[0]}"
end
