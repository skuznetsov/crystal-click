require "digest/sha256"
require "json"
require "../src/crystal_click"

module W180JSONBinaryKernel
  PINNED_RUNTIME_SHA256     = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  PINNED_RUNTIME_VERSION    = "26.10.1.1201"
  PINNED_RUNTIME_BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  STOCK_SOURCE              = "pinned stock ClickHouse RowBinaryWithNamesAndTypes output"

  struct Profile
    getter id : String
    getter type : CrystalClick::BinaryDataType
    getter type_name : String
    getter descriptor : Bytes
    getter row : Bytes
    getter value : CrystalClick::BinaryValue

    def initialize(
      @id : String,
      @type : CrystalClick::BinaryDataType,
      @type_name : String,
      @descriptor : Bytes,
      @row : Bytes,
      @value : CrystalClick::BinaryValue,
    )
    end
  end

  def self.require!(condition : Bool, message : String) : Nil
    raise message unless condition
  end

  def self.json_value(
    type : CrystalClick::BinaryDataType,
    entries : Array(Tuple(String, CrystalClick::BinaryValue)),
  ) : CrystalClick::BinaryValue
    row = CrystalClick::BinaryJsonRow.new(type, entries)
    CrystalClick::BinaryValue.json(type, row)
  end

  # This finite roster has four empty cap-only rows, one runtime String path
  # at zero caps, and two typed-path values. It does not qualify a broader
  # dynamic-path or dynamic-type grammar.
  def self.build_profiles : Array(Profile)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")

    bare_type = CrystalClick::BinaryDataType.json
    caps_0_0_type = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    caps_1_1_type = CrystalClick::BinaryDataType.json(max_dynamic_paths: 1, max_dynamic_types: 1)
    caps_10000_254_type = CrystalClick::BinaryDataType.json(max_dynamic_paths: 10_000, max_dynamic_types: 254)

    n_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {"n" => uint8},
    )
    item_nullable_type = CrystalClick::BinaryDataType.nullable(uint8)
    item_array_type = CrystalClick::BinaryDataType.array(item_nullable_type)
    item_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {"item" => item_array_type},
    )

    empty_entries = [] of Tuple(String, CrystalClick::BinaryValue)
    n_value = CrystalClick::BinaryValue.fixed(uint8, Bytes[42_u8])
    n_entries = [{"n", n_value}] of Tuple(String, CrystalClick::BinaryValue)

    item_values = [
      CrystalClick::BinaryValue.nullable(item_nullable_type),
      CrystalClick::BinaryValue.nullable(
        item_nullable_type,
        CrystalClick::BinaryValue.fixed(uint8, Bytes[0_u8]),
      ),
      CrystalClick::BinaryValue.nullable(
        item_nullable_type,
        CrystalClick::BinaryValue.fixed(uint8, Bytes[255_u8]),
      ),
    ] of CrystalClick::BinaryValue
    item_array = CrystalClick::BinaryValue.array(item_array_type, item_values)
    item_entries = [{"item", item_array}] of Tuple(String, CrystalClick::BinaryValue)

    [
      Profile.new(
        "bare_json", bare_type, "JSON",
        Bytes[0x30_u8, 0x00_u8, 0x80_u8, 0x08_u8, 0x20_u8, 0x00_u8, 0x00_u8, 0x00_u8],
        Bytes[0x00_u8], json_value(bare_type, empty_entries),
      ),
      Profile.new(
        "caps_0_0", caps_0_0_type,
        "JSON(max_dynamic_types=0, max_dynamic_paths=0)",
        Bytes[0x30_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
        Bytes[0x00_u8], json_value(caps_0_0_type, empty_entries),
      ),
      Profile.new(
        "caps_0_0_runtime_string", caps_0_0_type,
        "JSON(max_dynamic_types=0, max_dynamic_paths=0)",
        Bytes[0x30_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
        Bytes[0x01_u8, 0x01_u8, 0x73_u8, 0x15_u8, 0x01_u8, 0x78_u8],
        json_value(
          caps_0_0_type,
          [{"s", CrystalClick::BinaryValue.string("x")}] of Tuple(String, CrystalClick::BinaryValue),
        ),
      ),
      Profile.new(
        "caps_1_1", caps_1_1_type,
        "JSON(max_dynamic_types=1, max_dynamic_paths=1)",
        Bytes[0x30_u8, 0x00_u8, 0x01_u8, 0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8],
        Bytes[0x00_u8], json_value(caps_1_1_type, empty_entries),
      ),
      Profile.new(
        "caps_10000_254", caps_10000_254_type,
        "JSON(max_dynamic_types=254, max_dynamic_paths=10000)",
        Bytes[0x30_u8, 0x00_u8, 0x90_u8, 0x4e_u8, 0xfe_u8, 0x00_u8, 0x00_u8, 0x00_u8],
        Bytes[0x00_u8], json_value(caps_10000_254_type, empty_entries),
      ),
      Profile.new(
        "typed_uint8_n", n_type,
        "JSON(max_dynamic_types=1, max_dynamic_paths=1, n UInt8)",
        Bytes[0x30_u8, 0x00_u8, 0x01_u8, 0x01_u8, 0x01_u8, 0x01_u8, 0x6e_u8, 0x01_u8, 0x00_u8, 0x00_u8],
        Bytes[0x01_u8, 0x01_u8, 0x6e_u8, 0x2a_u8], json_value(n_type, n_entries),
      ),
      Profile.new(
        "typed_nullable_uint8_array_item", item_type,
        "JSON(max_dynamic_types=1, max_dynamic_paths=1, item Array(Nullable(UInt8)))",
        Bytes[
          0x30_u8, 0x00_u8, 0x01_u8, 0x01_u8, 0x01_u8, 0x04_u8,
          0x69_u8, 0x74_u8, 0x65_u8, 0x6d_u8, 0x1e_u8, 0x23_u8,
          0x01_u8, 0x00_u8, 0x00_u8,
        ],
        # Nullable(UInt8) stores a null flag before every element, including 255.
        Bytes[
          0x01_u8, 0x04_u8, 0x69_u8, 0x74_u8, 0x65_u8, 0x6d_u8,
          0x03_u8, 0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0xff_u8,
        ],
        json_value(item_type, item_entries),
      ),
    ] of Profile
  end

  def self.verify_value!(profile : Profile, value : CrystalClick::BinaryValue) : Nil
    require!(value.type == profile.type, "#{profile.id}: decoded JSON value type differs")
    require!(value.type.name == profile.type_name, "#{profile.id}: canonical JSON type name differs")
    row = value.json_row || raise "#{profile.id}: decoded value has no JSON row"
    require!(row.type == profile.type, "#{profile.id}: decoded JSON row type differs")

    case profile.id
    when "bare_json", "caps_0_0", "caps_1_1", "caps_10000_254"
      require!(row.empty? && row.path_count == 0, "#{profile.id}: expected an empty JSON row")
    when "caps_0_0_runtime_string"
      require!(row.path_count == 1 && row.path_at(0) == "s", "zero-cap runtime String: JSON path differs")
      actual = row.value_for("s") || raise "zero-cap runtime String: value is missing"
      require!(actual.type.name == "String" && actual.as_string == "x",
        "zero-cap runtime String: decoded value differs")
    when "typed_uint8_n"
      require!(row.path_count == 1 && row.path_at(0) == "n", "typed_uint8_n: JSON path differs")
      actual = row.value_for("n") || raise "typed_uint8_n: declared value is missing"
      require!(actual.type.name == "UInt8" && actual.bytes == Bytes[42_u8], "typed_uint8_n: UInt8 value differs")
    when "typed_nullable_uint8_array_item"
      require!(row.path_count == 1 && row.path_at(0) == "item", "nullable array: JSON path differs")
      array = row.value_for("item") || raise "nullable array: declared value is missing"
      require!(array.type.name == "Array(Nullable(UInt8))" && array.element_count == 3,
        "nullable array: value type or element count differs")

      null_value = array.element_at(0)
      zero_value = array.element_at(1)
      max_value = array.element_at(2)
      require!(null_value.type.name == "Nullable(UInt8)" && null_value.is_null?, "nullable array: NULL element differs")
      require!(zero_value.type.name == "Nullable(UInt8)" && !zero_value.is_null? &&
               zero_value.element_at(0).bytes == Bytes[0_u8], "nullable array: zero element differs")
      require!(max_value.type.name == "Nullable(UInt8)" && !max_value.is_null? &&
               max_value.element_at(0).bytes == Bytes[255_u8], "nullable array: 255 element differs")
    else
      raise "unknown W180 profile #{profile.id}"
    end
  end

  def self.verify_profile_codecs!(profile : Profile, descriptor : Bytes, row_bytes : Bytes) : Nil
    require!(descriptor == profile.descriptor, "#{profile.id}: descriptor differs from independent literal")
    decoded_type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
    require!(decoded_type == profile.type, "#{profile.id}: decoded descriptor differs from declared type")
    require!(decoded_type.name == profile.type_name, "#{profile.id}: canonical type name differs")
    require!(CrystalClick::BinaryDataTypeCodec.encode(decoded_type) == profile.descriptor,
      "#{profile.id}: descriptor does not re-encode byte-exactly")

    require!(CrystalClick::BinaryDataTypeCodec.encode(profile.type) == profile.descriptor,
      "#{profile.id}: declared type descriptor differs from independent literal")
    require!(CrystalClick::BinaryValueCodec.encode_value(profile.value) == profile.row,
      "#{profile.id}: constructed structured row differs from independent literal")
    require!(row_bytes == profile.row, "#{profile.id}: structured row differs from independent literal")

    decoded_value = CrystalClick::BinaryValueCodec.decode_value(decoded_type, row_bytes)
    verify_value!(profile, decoded_value)
    require!(CrystalClick::BinaryValueCodec.encode_value(decoded_value) == profile.row,
      "#{profile.id}: decoded structured row does not re-encode byte-exactly")
  end

  def self.validate_emit_root(path : String) : String
    require!(!path.empty?, "--emit-fixtures requires an output root")
    expanded = File.expand_path(path)
    require!(!File.symlink?(expanded) && File.directory?(expanded), "fixture root must be an existing plain directory")
    root = File.realpath(expanded)
    tmp_root = File.realpath("/private/tmp")
    require!(root == expanded && File.dirname(root) == tmp_root, "fixture root must be an existing direct child of /private/tmp")
    require!(Dir.children(root).empty?, "fixture root must be empty")
    root
  end

  def self.validate_stock_root(path : String) : String
    require!(!path.empty?, "--verify-stock requires stock_to_library root")
    expanded = File.expand_path(path)
    require!(!File.symlink?(expanded) && File.directory?(expanded), "stock fixture root must be a plain directory")
    root = File.realpath(expanded)
    parent = File.dirname(root)
    tmp_root = File.realpath("/private/tmp")
    require!(root == expanded && File.basename(root) == "stock_to_library" &&
             File.realpath(parent) == parent && File.dirname(parent) == tmp_root,
      "stock fixture root must be ROOT/stock_to_library under a direct /private/tmp child")
    root
  end

  def self.write_bytes(path : String, bytes : Bytes) : Nil
    File.open(path, "wb") { |file| file.write(bytes) }
  end

  def self.read_bytes(path : String) : Bytes
    File.read(path).to_slice.dup
  end

  def self.write_manifest(root : String, profiles : Array(Profile)) : Nil
    manifest = JSON.build do |json|
      json.object do
        json.field "version", 1
        json.field "profiles" do
          json.array do
            profiles.each do |profile|
              json.object do
                json.field "id", profile.id
                json.field "type", profile.type_name
                json.field "descriptor", "#{profile.id}/descriptor.bin"
                json.field "row", "#{profile.id}/row.bin"
              end
            end
          end
        end
      end
    end
    File.write(File.join(root, "manifest.json"), manifest + "\n")
  end

  def self.emit_fixtures(path : String) : Nil
    root = validate_emit_root(path)
    profiles = build_profiles
    profiles.each do |profile|
      descriptor = CrystalClick::BinaryDataTypeCodec.encode(profile.type)
      row = CrystalClick::BinaryValueCodec.encode_value(profile.value)
      verify_profile_codecs!(profile, descriptor, row)
      directory = File.join(root, profile.id)
      Dir.mkdir(directory, 0o700)
      write_bytes(File.join(directory, "descriptor.bin"), descriptor)
      write_bytes(File.join(directory, "row.bin"), row)
    end
    write_manifest(root, profiles)
    puts "PASS W180 JSON library fixtures: #{profiles.size} fixed profiles"
  end

  def self.read_metadata(path : String, profile : Profile, descriptor : Bytes, row : Bytes) : Nil
    metadata = JSON.parse(File.read(path))
    require!(metadata["version"].as_i == 1, "#{profile.id}: stock metadata version differs")
    require!(metadata["profile_id"].as_s == profile.id, "#{profile.id}: stock metadata profile differs")
    require!(metadata["type"].as_s == profile.type_name, "#{profile.id}: stock metadata type differs")
    require!(metadata["source"].as_s == STOCK_SOURCE, "#{profile.id}: stock metadata source differs")
    require!(metadata["stock_wire_exact"].as_bool, "#{profile.id}: native stock wire comparison did not pass")
    require!(metadata["header_format"].as_s == "RowBinaryWithNamesAndTypes" &&
             metadata["row_format"].as_s == "structured RowBinary", "#{profile.id}: stock metadata format differs")

    runtime = metadata["runtime"]
    require!(runtime["sha256"].as_s == PINNED_RUNTIME_SHA256, "#{profile.id}: stock runtime hash differs")
    require!(runtime["version"].as_s == PINNED_RUNTIME_VERSION, "#{profile.id}: stock runtime version differs")
    require!(runtime["build_hash"].as_s == PINNED_RUNTIME_BUILD_HASH, "#{profile.id}: stock runtime build hash differs")

    settings = metadata["structured_json_settings"]
    require!(settings["input_format_binary_read_json_as_string"].as_i == 0 &&
             settings["output_format_binary_write_json_as_string"].as_i == 0,
      "#{profile.id}: stock structured JSON settings differ")

    header = rowbinary_header(descriptor)
    require!(metadata["header_hex"].as_s == hex(header), "#{profile.id}: stock metadata header differs")
    require!(metadata["header_sha256"].as_s == Digest::SHA256.hexdigest(header),
      "#{profile.id}: stock metadata header hash differs")
    require!(metadata["descriptor_bytes"].as_i == descriptor.size &&
             metadata["descriptor_sha256"].as_s == Digest::SHA256.hexdigest(descriptor),
      "#{profile.id}: stock metadata descriptor identity differs")
    require!(metadata["row_bytes"].as_i == row.size &&
             metadata["row_sha256"].as_s == Digest::SHA256.hexdigest(row),
      "#{profile.id}: stock metadata row identity differs")
    require!(metadata["rowbinary_sha256"].as_s == Digest::SHA256.hexdigest(join_bytes(header, row)),
      "#{profile.id}: stock metadata combined wire hash differs")
  end

  def self.rowbinary_header(descriptor : Bytes) : Bytes
    bytes = [] of UInt8
    bytes << 0x01_u8 # one column
    bytes << 0x07_u8 # payload name length
    "payload".to_slice.each { |byte| bytes << byte }
    descriptor.each { |byte| bytes << byte }
    Bytes.new(bytes.size) { |index| bytes[index] }
  end

  def self.join_bytes(left : Bytes, right : Bytes) : Bytes
    bytes = Bytes.new(left.size + right.size) do |index|
      index < left.size ? left[index] : right[index - left.size]
    end
    bytes
  end

  def self.hex(bytes : Bytes) : String
    bytes.hexstring.downcase
  end

  def self.verify_stock(path : String) : Nil
    root = validate_stock_root(path)
    profiles = build_profiles
    expected_roster = profiles.map(&.id).sort
    require!(Dir.children(root).sort == expected_roster, "stock fixture profile roster differs")

    profiles.each do |profile|
      directory = File.join(root, profile.id)
      require!(!File.symlink?(directory) && File.directory?(directory), "#{profile.id}: stock profile directory is missing or symlinked")
      require!(Dir.children(directory).sort == %w[descriptor.bin metadata.json row.bin],
        "#{profile.id}: unexpected stock fixture files")

      descriptor_path = File.join(directory, "descriptor.bin")
      row_path = File.join(directory, "row.bin")
      metadata_path = File.join(directory, "metadata.json")
      [descriptor_path, row_path, metadata_path].each do |file|
        require!(File.file?(file) && !File.symlink?(file), "#{profile.id}: stock fixture file is missing or symlinked")
      end

      descriptor = read_bytes(descriptor_path)
      row = read_bytes(row_path)
      read_metadata(metadata_path, profile, descriptor, row)
      verify_profile_codecs!(profile, descriptor, row)
    end

    puts "PASS W180 JSON stock fixtures: #{profiles.size} exact descriptors and structured rows"
  end
end

unless ARGV.size == 2
  raise "usage: crystal run scripts/check_json_binary_kernel_w180.cr -- --emit-fixtures EMPTY_TMP_ROOT | --verify-stock ROOT/stock_to_library"
end

case ARGV[0]
when "--emit-fixtures"
  W180JSONBinaryKernel.emit_fixtures(ARGV[1])
when "--verify-stock"
  W180JSONBinaryKernel.verify_stock(ARGV[1])
else
  raise "unknown W180 JSON kernel mode: #{ARGV[0]}"
end
