# W147 generic paired Variant descriptor/value kernel exchange checker.
# This exercises logical RowBinary values only. It does not encode LowCardinality
# dictionary/index lanes, native Object parts, or a complete part writer.
require "../src/crystal_click"

module VariantValueW147
  extend self

  SOURCE_REVISION = "9007d227b64a3f8b667fc5258ceb2923f3cf477d"
  RUNTIME_SHA256  = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  RUNTIME_VERSION = "26.10.1.1201"
  BUILD_HASH      = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  ROOT_PATTERN    = %r{\A/private/tmp/crystal-click-w147-kernel\.[A-Za-z0-9_-]+\z}

  struct Profile
    getter name : String
    getter type : CrystalClick::BinaryDataType
    getter ids : Array(UInt8)
    getter values : Array(CrystalClick::BinaryValue)
    getter output_header : Bytes
    getter output_literals : Array(Bytes)

    def initialize(@name : String, @type : CrystalClick::BinaryDataType,
                   @ids : Array(UInt8), @values : Array(CrystalClick::BinaryValue),
                   @output_header : Bytes, @output_literals : Array(Bytes))
    end
  end

  def fail!(message : String) : NoReturn
    raise RuntimeError.new(message)
  end

  def assert(condition : Bool, message : String) : Nil
    fail!(message) unless condition
  end

  def bytes_from_hex(hex : String) : Bytes
    assert(hex.bytesize.even?, "authored W147 hex literal has odd length")
    source = hex.to_slice
    Bytes.new(source.size // 2) do |index|
      high = hex_nibble(source[index * 2])
      low = hex_nibble(source[index * 2 + 1])
      (high << 4) | low
    end
  end

  private def hex_nibble(byte : UInt8) : UInt8
    case byte
    when 48_u8..57_u8  then byte - 48_u8
    when 65_u8..70_u8  then byte - 55_u8
    when 97_u8..102_u8 then byte - 87_u8
    else                    fail!("authored W147 literal contains a non-hex byte")
    end
  end

  def bytes_equal!(label : String, actual : Bytes, expected : Bytes) : Nil
    assert(actual.size == expected.size, "#{label}: byte length #{actual.size} != #{expected.size}")
    actual.size.times do |index|
      assert(actual[index] == expected[index],
        "#{label}: byte mismatch at #{index}: #{actual[index].to_s(16)} != #{expected[index].to_s(16)}")
    end
  end

  def concatenate(parts : Array(Bytes)) : Bytes
    bytes = Bytes.new(parts.sum(&.size))
    offset = 0
    parts.each do |part|
      part.each_with_index { |byte, index| bytes[offset + index] = byte }
      offset += part.size
    end
    bytes
  end

  def var_uint(value : UInt64) : Bytes
    remaining = value
    result = [] of UInt8
    while remaining >= 0x80_u64
      result << ((remaining & 0x7f_u64).to_u8 | 0x80_u8)
      remaining >>= 7
    end
    result << remaining.to_u8
    Bytes.new(result.size) { |index| result[index] }
  end

  def rb_string(value : String) : Bytes
    concatenate([var_uint(value.bytesize.to_u64), Bytes.new(value.bytesize) { |index| value.to_slice[index] }])
  end

  def fixed(type : CrystalClick::BinaryDataType, bytes : Array(UInt8)) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(type, Bytes.new(bytes.size) { |index| bytes[index] })
  end

  def uint16(type : CrystalClick::BinaryDataType, value : UInt16) : CrystalClick::BinaryValue
    fixed(type, [(value & 0xff_u16).to_u8, (value >> 8).to_u8])
  end

  def uint32(type : CrystalClick::BinaryDataType, value : UInt32) : CrystalClick::BinaryValue
    fixed(type, Array(UInt8).new(4) { |index| ((value >> (index * 8)) & 0xff_u32).to_u8 })
  end

  def uint64(type : CrystalClick::BinaryDataType, value : UInt64) : CrystalClick::BinaryValue
    fixed(type, Array(UInt8).new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 })
  end

  def canonical_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("UInt64"),
      CrystalClick::BinaryDataType.primitive("String"),
    ] of CrystalClick::BinaryDataType, limits: CrystalClick::BinaryCodecLimits.default)
  end

  def nominal_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("UInt8"),
      CrystalClick::BinaryDataType.primitive("Bool"),
    ] of CrystalClick::BinaryDataType, limits: CrystalClick::BinaryCodecLimits.default)
  end

  def recursive_arm_types : Tuple(CrystalClick::BinaryDataType, CrystalClick::BinaryDataType, CrystalClick::BinaryDataType)
    uint16_type = CrystalClick::BinaryDataType.primitive("UInt16")
    string_type = CrystalClick::BinaryDataType.primitive("String")
    uint32_type = CrystalClick::BinaryDataType.primitive("UInt32")
    nullable_uint16 = CrystalClick::BinaryDataType.nullable(uint16_type)
    low_string = CrystalClick::BinaryDataType.low_cardinality(string_type)
    array_arm = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.array(uint16_type))
    map_arm = CrystalClick::BinaryDataType.map(string_type, nullable_uint16)
    tuple_arm = CrystalClick::BinaryDataType.tuple(
      [low_string, uint32_type] of CrystalClick::BinaryDataType,
      ["label", "score"] of String)
    {array_arm, map_arm, tuple_arm}
  end

  def recursive_variant_type : CrystalClick::BinaryDataType
    arms = recursive_arm_types
    CrystalClick::BinaryDataType.variant(
      [arms[2], arms[0], arms[1]] of CrystalClick::BinaryDataType,
      limits: CrystalClick::BinaryCodecLimits.default)
  end

  def recursive_type : CrystalClick::BinaryDataType
    variant = recursive_variant_type
    string_type = CrystalClick::BinaryDataType.primitive("String")
    uint32_type = CrystalClick::BinaryDataType.primitive("UInt32")
    low_string = CrystalClick::BinaryDataType.low_cardinality(string_type)
    record = CrystalClick::BinaryDataType.tuple(
      [low_string, uint32_type] of CrystalClick::BinaryDataType,
      ["label", "score"] of String)
    CrystalClick::BinaryDataType.tuple(
      [
        variant,
        CrystalClick::BinaryDataType.array(variant),
        CrystalClick::BinaryDataType.map(string_type, variant),
        record,
      ] of CrystalClick::BinaryDataType,
      ["selected", "items", "lookup", "record"] of String)
  end

  def make_recursive_value : CrystalClick::BinaryValue
    arms = recursive_arm_types
    variant_type = recursive_variant_type
    uint16_type = CrystalClick::BinaryDataType.primitive("UInt16")
    uint32_type = CrystalClick::BinaryDataType.primitive("UInt32")
    string_type = CrystalClick::BinaryDataType.primitive("String")
    nullable_uint16 = CrystalClick::BinaryDataType.nullable(uint16_type)
    low_string = CrystalClick::BinaryDataType.low_cardinality(string_type)
    nested_array_type = arms[0]
    uint16_array_type = nested_array_type.child_at(0)

    empty_nested_array = CrystalClick::BinaryValue.array(nested_array_type, [] of CrystalClick::BinaryValue)
    selected = CrystalClick::BinaryValue.variant(variant_type, 0, empty_nested_array)

    first_inner = CrystalClick::BinaryValue.array(uint16_array_type, [
      uint16(uint16_type, 1_u16), uint16(uint16_type, UInt16::MAX),
    ] of CrystalClick::BinaryValue)
    empty_inner = CrystalClick::BinaryValue.array(uint16_array_type, [] of CrystalClick::BinaryValue)
    full_nested_array = CrystalClick::BinaryValue.array(nested_array_type,
      [first_inner, empty_inner] of CrystalClick::BinaryValue)
    array_variant = CrystalClick::BinaryValue.variant(variant_type, 0, full_nested_array)
    null_variant = CrystalClick::BinaryValue.variant_null(variant_type)
    items_type = CrystalClick::BinaryDataType.array(variant_type)
    items = CrystalClick::BinaryValue.array(items_type,
      [array_variant, null_variant] of CrystalClick::BinaryValue)

    map_arm = arms[1]
    map_value = CrystalClick::BinaryValue.map(map_arm, [
      CrystalClick::BinaryValue.string("a"),
      CrystalClick::BinaryValue.nullable(nullable_uint16, uint16(uint16_type, 7_u16)),
      CrystalClick::BinaryValue.string("z"),
      CrystalClick::BinaryValue.nullable(nullable_uint16),
    ] of CrystalClick::BinaryValue)
    map_variant = CrystalClick::BinaryValue.variant(variant_type, 1, map_value)

    tuple_arm = arms[2]
    tuple_value = CrystalClick::BinaryValue.tuple(tuple_arm, [
      CrystalClick::BinaryValue.low_cardinality(low_string, CrystalClick::BinaryValue.string("λ")),
      uint32(uint32_type, UInt32::MAX),
    ] of CrystalClick::BinaryValue)
    tuple_variant = CrystalClick::BinaryValue.variant(variant_type, 2, tuple_value)
    lookup_type = CrystalClick::BinaryDataType.map(string_type, variant_type)
    lookup = CrystalClick::BinaryValue.map(lookup_type, [
      CrystalClick::BinaryValue.string("map"), map_variant,
      CrystalClick::BinaryValue.string("tuple"), tuple_variant,
    ] of CrystalClick::BinaryValue)

    outer_type = recursive_type
    record_type = outer_type.child_at(3)
    record = CrystalClick::BinaryValue.tuple(record_type, [
      CrystalClick::BinaryValue.low_cardinality(low_string, CrystalClick::BinaryValue.string("parent")),
      uint32(uint32_type, 7_u32),
    ] of CrystalClick::BinaryValue)
    CrystalClick::BinaryValue.tuple(outer_type, [selected, items, lookup, record] of CrystalClick::BinaryValue)
  end

  def expected_recursive_payload : Bytes
    # Independently authored RowBinary literal: empty selected Array arm,
    # nonempty nested Array arm plus Variant NULL, Map arm with nullable values,
    # named Tuple arm with LC(String), and parent named-Tuple LC(String).
    bytes_from_hex(
      "0000" +
      "020002020100ffff00ff" +
      "02036d617001020161000700017a01" +
      "057475706c650202cebbffffffff" +
      "06706172656e7407000000")
  end

  def profile_values : Array(Profile)
    string_type = CrystalClick::BinaryDataType.primitive("String")
    uint64_type = CrystalClick::BinaryDataType.primitive("UInt64")
    canonical = canonical_type
    canonical_values = [
      CrystalClick::BinaryValue.variant(canonical, 0, CrystalClick::BinaryValue.string("alpha")),
      CrystalClick::BinaryValue.variant(canonical, 1, uint64(uint64_type, 42_u64)),
      CrystalClick::BinaryValue.variant_null(canonical),
    ] of CrystalClick::BinaryValue
    canonical_literals = [
      bytes_from_hex("0005616c706861"),
      bytes_from_hex("012a00000000000000"),
      bytes_from_hex("ff"),
    ] of Bytes

    bool_type = CrystalClick::BinaryDataType.primitive("Bool")
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    nominal = nominal_type
    nominal_values = [
      CrystalClick::BinaryValue.variant(nominal, 0, CrystalClick::BinaryValue.bool(true)),
      CrystalClick::BinaryValue.variant(nominal, 1, fixed(uint8_type, [0xff_u8])),
      CrystalClick::BinaryValue.variant_null(nominal),
    ] of CrystalClick::BinaryValue
    nominal_literals = [
      bytes_from_hex("0001"),
      bytes_from_hex("01ff"),
      bytes_from_hex("ff"),
    ] of Bytes

    recursive = recursive_type
    recursive_value = make_recursive_value
    recursive_literals = [expected_recursive_payload] of Bytes

    [
      Profile.new("canonical", canonical, [1_u8, 2_u8, 3_u8], canonical_values,
        bytes_from_hex("0101762a021504"), canonical_literals),
      Profile.new("nominal", nominal, [1_u8, 2_u8, 3_u8], nominal_values,
        bytes_from_hex("0101762a022d01"), nominal_literals),
      Profile.new("recursive", recursive, [1_u8], [recursive_value] of CrystalClick::BinaryValue,
        bytes_from_hex("010176" +
                       "2004" +
                       "0873656c6563746564" + "2a031e1e02" + "27152302" + "2002056c6162656c2615" + "0573636f726503" +
                       "056974656d731e2a031e1e02271523022002056c6162656c26150573636f726503" +
                       "066c6f6f6b757027152a031e1e02271523022002056c6162656c26150573636f726503" +
                       "067265636f72642002056c6162656c26150573636f726503"), recursive_literals),
    ] of Profile
  end

  def mutant_value : CrystalClick::BinaryValue
    type = canonical_type
    uint64_type = CrystalClick::BinaryDataType.primitive("UInt64")
    CrystalClick::BinaryValue.variant(type, 1, uint64(uint64_type, 43_u64))
  end

  def compare_value!(label : String, actual : CrystalClick::BinaryValue,
                     expected : CrystalClick::BinaryValue, depth : Int = 0) : Nil
    assert(depth < 64, "#{label}: comparison depth exceeded")
    assert(actual.type == expected.type,
      "#{label}: type mismatch #{actual.type.name.inspect} != #{expected.type.name.inspect}")
    assert(actual.is_null? == expected.is_null?, "#{label}: NULL discriminator mismatch")
    if expected.is_null?
      if expected.type.tag == 0x2a_u8
        assert(actual.variant_index?.nil? && actual.variant_child?.nil?,
          "#{label}: NULL Variant unexpectedly has a selected lane")
        assert(expected.variant_index?.nil? && expected.variant_child?.nil?,
          "#{label}: expected NULL Variant fixture unexpectedly has a selected lane")
      end
      return
    end

    type = expected.type
    case type.tag
    when 0x2a_u8 # Variant
      assert(actual.variant_index? == expected.variant_index?, "#{label}: Variant tag mismatch")
      actual_child = actual.variant_child? || fail!("#{label}: non-NULL Variant has no child")
      expected_child = expected.variant_child? || fail!("#{label}: expected Variant has no child")
      compare_value!("#{label}.arm", actual_child, expected_child, depth + 1)
    when CrystalClick::BinaryDataType::TAG_ARRAY,
         CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
         CrystalClick::BinaryDataType::TAG_NAMED_TUPLE,
         CrystalClick::BinaryDataType::TAG_MAP
      assert(actual.element_count == expected.element_count, "#{label}: element count mismatch")
      actual.element_count.times do |index|
        compare_value!("#{label}[#{index}]", actual.element_at(index), expected.element_at(index), depth + 1)
      end
    when CrystalClick::BinaryDataType::TAG_NULLABLE,
         CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
      assert(actual.element_count == expected.element_count, "#{label}: wrapped child count mismatch")
      assert(actual.element_count == 1, "#{label}: non-NULL wrapper must have one child")
      compare_value!("#{label}.child", actual.child_at(0), expected.child_at(0), depth + 1)
    when CrystalClick::BinaryDataType::TAG_STRING
      assert(actual.as_string == expected.as_string, "#{label}: String leaf mismatch")
    when CrystalClick::BinaryDataType::TAG_BOOL
      assert(actual.as_bool == expected.as_bool, "#{label}: Bool leaf mismatch")
    else
      bytes_equal!("#{label}.leaf", actual.bytes, expected.bytes)
    end
  end

  def write_new(path : String, bytes : Bytes) : Nil
    assert(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite checker output: #{path}")
    File.open(path, "wb") { |file| file.write(bytes) }
  end

  def write_text_new(path : String, text : String) : Nil
    assert(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite checker output: #{path}")
    File.open(path, "w") { |file| file << text }
  end

  def read_bytes(path : String) : Bytes
    assert(File.file?(path) && !File.symlink?(path), "missing or symlinked W147 input: #{path}")
    size = File.size(path)
    assert(size <= 1_048_576, "W147 binary artifact exceeds 1 MiB: #{path}")
    File.open(path, "rb") do |file|
      bytes = Bytes.new(size.to_i)
      file.read_fully(bytes)
      bytes
    end
  end

  def validate_root(root : String) : Nil
    assert(ENV["W147_EXECUTE_AS_ROOT"]? == "YES", "checker execution requires root-owned W147_EXECUTE_AS_ROOT=YES")
    assert(File.directory?(root) && !File.symlink?(root), "W147 root must be an existing non-symlink directory")
    assert(File.expand_path(root) == root, "W147 root must be canonical")
    assert(ROOT_PATTERN.matches?(root), "W147 root must be a direct /private/tmp namespace child")
    assert(File.realpath(root) == root, "W147 root resolves outside its canonical path")
    assert(!File.symlink?(File.join(root, "inputs")), "W147 inputs directory must not be a symlink")
    assert(!File.symlink?(File.join(root, "results")), "W147 results directory must not be a symlink")
  end

  def input_header(type : CrystalClick::BinaryDataType) : Bytes
    id_type = CrystalClick::BinaryDataType.primitive("UInt8")
    concatenate([
      var_uint(2_u64), rb_string("id"), rb_string("v"),
      CrystalClick::BinaryDataTypeCodec.encode(id_type),
      CrystalClick::BinaryDataTypeCodec.encode(type),
    ] of Bytes)
  end

  def encode_profile(profile : Profile) : Bytes
    parts = [input_header(profile.type)] of Bytes
    profile.values.each_with_index do |value, index|
      payload = CrystalClick::BinaryValueCodec.encode_value(value)
      bytes_equal!("#{profile.name} typed-value literal row #{index + 1}", payload, profile.output_literals[index])
      parts << Bytes[profile.ids[index]]
      parts << payload
    end
    concatenate(parts)
  end

  def write_inputs(root : String) : Nil
    inputs = File.join(root, "inputs")
    assert(!File.exists?(inputs) && !File.symlink?(inputs), "refusing to reuse W147 input directory")
    Dir.mkdir(inputs, 0o700)
    profile_values.each do |profile|
      write_new(File.join(inputs, "library-#{profile.name}.bin"), encode_profile(profile))
    end
    canonical = profile_values[0]
    mutant_type = canonical_type
    mutant = mutant_value
    mutant_payload = CrystalClick::BinaryValueCodec.encode_value(mutant)
    bytes_equal!("mutant typed-value literal", mutant_payload, bytes_from_hex("012b00000000000000"))
    mutant_file = concatenate([
      input_header(mutant_type), Bytes[2_u8], mutant_payload,
    ] of Bytes)
    write_new(File.join(inputs, "library-mutant-canonical.bin"), mutant_file)
    assert(Dir.children(inputs).size == 4, "W147 checker generated an unexpected input-file count")
  end

  def slice(bytes : Bytes, offset : Int) : Bytes
    assert(offset >= 0 && offset <= bytes.size, "invalid W147 output-header boundary")
    Bytes.new(bytes.size - offset) { |index| bytes[offset + index] }
  end

  def decode_result!(root : String, profile : Profile, id : UInt8, path_prefix : String,
                     expected : CrystalClick::BinaryValue) : Nil
    path = File.join(root, "results", "#{path_prefix}-#{profile.name}-#{id}.bin")
    bytes = read_bytes(path)
    header = profile.output_header
    assert(bytes.size > header.size, "#{path}: output is shorter than header plus value")
    bytes_equal!("#{path} literal header", Bytes.new(header.size) { |index| bytes[index] }, header)
    assert(header.size > 3, "#{path}: one-column header omitted its descriptor")
    descriptor = Bytes.new(header.size - 3) { |index| bytes[index + 3] }
    parsed_type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
    assert(parsed_type == profile.type,
      "#{path}: stock binary descriptor #{parsed_type.name.inspect} != expected #{profile.type.name.inspect}")
    payload = slice(bytes, header.size)
    decoded = CrystalClick::BinaryValueCodec.decode_value(parsed_type, payload)
    compare_value!("#{path} typed value", decoded, expected)
    encoded = CrystalClick::BinaryValueCodec.encode_value(decoded)
    bytes_equal!("#{path} decode/encode stability", encoded, payload)
  end

  def verify_results(root : String) : Nil
    profiles = profile_values
    profiles.each do |profile|
      profile.values.each_with_index do |expected, index|
        id = profile.ids[index]
        decode_result!(root, profile, id, "stock", expected)
        decode_result!(root, profile, id, "library-stock", expected)
      end
    end
    canonical = profiles[0]
    mutant_expected = mutant_value
    mutant_id = 2_u8
    original = File.join(root, "results", "stock-canonical-2.bin")
    mutated = File.join(root, "results", "mutant-stock-canonical-2.bin")
    original_bytes = read_bytes(original)
    mutated_bytes = read_bytes(mutated)
    assert(mutated_bytes != original_bytes, "valid UInt64 mutant did not change stock output bytes")
    decode_result!(root, canonical, mutant_id, "mutant-stock", mutant_expected)
    original_mismatch_rejected = false
    begin
      compare_value!("valid wrong-value mutation", mutant_expected, canonical.values[1])
    rescue ex : RuntimeError
      original_mismatch_rejected = true
    end
    assert(original_mismatch_rejected,
      "independent typed-value comparator failed to reject UInt64 43 as original UInt64 42")
    mutant_child = mutant_expected.variant_child? || fail!("mutant must have a selected Variant child")
    original_child = canonical.values[1].variant_child? || fail!("original must have a selected Variant child")
    assert(mutant_child.as_uint64 == 43_u64 && original_child.as_uint64 == 42_u64,
      "valid mutant fixture must differ by UInt64 42 -> 43")

    expected_files = 15
    binaries = Dir.children(File.join(root, "results")).select(&.ends_with?(".bin"))
    assert(binaries.size == expected_files, "expected #{expected_files} W147 result binaries, found #{binaries.size}")
    summary = [
      "checker=PASS",
      "profiles=canonical Variant(String, UInt64); nominal Variant(Bool, UInt8); recursive Array/Map/named-Tuple Variant arms and parent contexts",
      "rows=7 stock plus 7 library-consumed plus 1 valid UInt64 mutant",
      "value_oracle=independent literal payloads and recursive typed comparison (type, null, Variant tag/child, container arity/elements, scalar leaves)",
      "wire_oracle=Ruby driver compares complete RowBinaryWithNamesAndTypes header+row bytes before this checker runs",
      "mutant=stock accepted UInt64 43; exact output differs from original UInt64 42",
      "harness_storage=MergeTree scratch tables persist across separate local invocations only",
      "scope=generic logical RowBinary descriptor/value kernel only; not LC dictionary lanes, Object-part producer, complete part writer, MV, or projection",
    ].join("\n") + "\n"
    write_text_new(File.join(root, "results", "checker-summary.txt"), summary)
    puts "PASS W147 generic Variant descriptor/value checker"
  end

  def run : Nil
    assert(ARGV.size == 2, "usage: check_variant_value_w147.cr (encode|verify) /private/tmp/crystal-click-w147-kernel.<suffix>")
    mode = ARGV[0]
    root = ARGV[1]
    validate_root(root)
    case mode
    when "encode"
      write_inputs(root)
      puts "PASS W147 encoded four literal-checked library input files"
    when "verify"
      verify_results(root)
    else
      fail!("unknown W147 checker mode: #{mode.inspect}")
    end
  end
end

VariantValueW147.run
