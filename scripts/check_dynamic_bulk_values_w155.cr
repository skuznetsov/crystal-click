# W155 finite stock Wide-part qualifier for paired Dynamic bulk values.
# This binds selected physical lanes to normalized roles; it does not qualify
# complete-part writing, arbitrary physical layouts, or general storage reads.
require "../src/crystal_click"

class W155Mismatch < Exception
end

W155_ROWS_PER_MARK                      = [2_u64, 2_u64, 2_u64]
W155_MAX_FILE_BYTES                     = 8_i64 * 1024 * 1024
W155_OFFSETS_EMPTY                      = [0_u64, 0_u64, 0_u64, 0_u64]
W155_OFFSETS_TWO_BYTES_PER_MARK         = [0_u64, 2_u64, 4_u64, 6_u64]
W155_OFFSETS_TWO_UINT64_PER_MARK        = [0_u64, 16_u64, 32_u64, 48_u64]
W155_OFFSETS_ROOT_UINT64                = [0_u64, 8_u64, 16_u64, 32_u64]
W155_OFFSETS_NESTED_UINT64              = [0_u64, 8_u64, 32_u64, 40_u64]
W155_OFFSETS_NESTED_DISCRIMINATORS      = [0_u64, 1_u64, 4_u64, 5_u64]
W155_OFFSETS_TWO_SHORT_STRINGS_PER_MARK = [0_u64, 6_u64, 12_u64, 18_u64]
W155_OFFSETS_ONE_SHARED_SPILL           = [0_u64, 8_u64, 8_u64, 8_u64]

# Literal V3 structure stream bytes. SerializationDynamic.cpp writes the V3
# version, actual ordinary-type count/descriptors, then a true suffix-statistics
# flag, one row count per canonical Variant arm (SharedVariant first), and the
# shared-type statistics map (SerializationDynamic.cpp:251-295, 529-553).
# SerializationVariant.cpp:347-388 counts ordinary-arm rows; the suffix
# recounts shared serialized values at SerializationDynamic.cpp:617-639.
W155_ROOT_U64_STRUCTURE = Bytes[
  0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
  0x01_u8, 0x04_u8, 0x01_u8, 0x01_u8, 0x04_u8, 0x01_u8, 0x06_u8,
  0x53_u8, 0x74_u8, 0x72_u8, 0x69_u8, 0x6E_u8, 0x67_u8, 0x01_u8,
]
W155_TUPLE_LEFT_U64_STRUCTURE = Bytes[
  0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
  0x01_u8, 0x04_u8, 0x01_u8, 0x00_u8, 0x06_u8, 0x00_u8,
]
W155_TUPLE_RIGHT_STRING_STRUCTURE = Bytes[
  0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
  0x01_u8, 0x15_u8, 0x01_u8, 0x00_u8, 0x06_u8, 0x00_u8,
]
W155_NESTED_U64_STRUCTURE = Bytes[
  0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
  0x01_u8, 0x04_u8, 0x01_u8, 0x00_u8, 0x05_u8, 0x00_u8,
]
W155_UNUSED_EMPTY_STRUCTURE = Bytes[
  0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
  0x00_u8, 0x01_u8, 0x00_u8, 0x00_u8,
]

def w155_fail(message : String) : NoReturn
  raise W155Mismatch.new("W155 stock Dynamic bulk qualification: #{message}")
end

def w155_require(condition : Bool, message : String) : Nil
  w155_fail(message) unless condition
end

def w155_read_file(path : String, label : String) : Bytes
  w155_require(File.file?(path) && !File.symlink?(path), "#{label}: missing regular file or symlink")
  size = File.size(path)
  w155_require(size >= 0 && size <= W155_MAX_FILE_BYTES, "#{label}: file exceeds 8 MiB")
  File.open(path, "rb") do |file|
    bytes = Bytes.new(size.to_i32)
    file.read_fully(bytes) unless bytes.empty?
    bytes
  end
end

def w155_substream_names(part : String) : Array(String)
  path = File.join(part, "columns_substreams.txt")
  text = String.new(w155_read_file(path, "columns_substreams.txt"))
  text.lines.select(&.starts_with?("\t")).map(&.strip).reject(&.empty?).sort!
end

def w155_expected_substreams : Array(String)
  [
    "id",
    "root_dynamic.dynamic_structure",
    "root_dynamic.variant_discr",
    "root_dynamic.SharedVariant",
    "root_dynamic.UInt64",
    "pair%2Eleft.dynamic_structure",
    "pair%2Eleft.variant_discr",
    "pair%2Eleft.SharedVariant",
    "pair%2Eleft.UInt64",
    "pair%2Eright.dynamic_structure",
    "pair%2Eright.variant_discr",
    "pair%2Eright.SharedVariant",
    "pair%2Eright.String",
    "nested.dynamic_structure",
    "nested.size0",
    "nested.variant_discr",
    "nested.SharedVariant",
    "nested.UInt64",
    "unused_variant.variant_discr",
    "unused_variant.UInt8",
    "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.size0",
    "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.dynamic_structure",
    "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.variant_discr",
    "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.SharedVariant",
  ] of String
end

def w155_validate_part_files(part : String, substreams : Array(String)) : Nil
  expected = substreams.map { |name| CrystalClick::StreamName.hash(name) }.sort!
  actual_bins = Dir.children(part).select(&.ends_with?(".bin")).map { |name| name[0, name.size - 4] }.sort!
  actual_marks = Dir.children(part).select(&.ends_with?(".mrk2")).map { |name| name[0, name.size - 5] }.sort!
  w155_require(actual_bins == expected, "hashed .bin roster differs from exact stock substreams")
  w155_require(actual_marks == expected, "hashed .mrk2 roster differs from exact stock substreams")
  nil
end

struct W155StructureBinding
  getter site : String
  getter physical_name : String
  getter expected_types : Array(String)
  getter expected_canonical_names : Array(String)
  getter expected_literal : Bytes

  def initialize(@site : String, @physical_name : String, @expected_types : Array(String),
                 @expected_canonical_names : Array(String), @expected_literal : Bytes)
  end
end

struct W155LaneBinding
  getter role : String
  getter physical_name : String
  getter expected_offsets : Array(UInt64)
  getter basic_discriminator : Bool

  def initialize(@role : String, @physical_name : String, @expected_offsets : Array(UInt64),
                 @basic_discriminator : Bool = false)
  end
end

struct W155DynamicCase
  getter label : String
  getter type : CrystalClick::BinaryDataType
  getter structures : Array(W155StructureBinding)
  getter lanes : Array(W155LaneBinding)
  getter expected_roles : Array(String)
  getter values : Array(Array(CrystalClick::BinaryValue))

  def initialize(@label : String, @type : CrystalClick::BinaryDataType,
                 @structures : Array(W155StructureBinding), @lanes : Array(W155LaneBinding),
                 @expected_roles : Array(String), @values : Array(Array(CrystalClick::BinaryValue)))
  end
end

def w155_read_structure(part : String, physical_name : String) : Bytes
  path = File.join(part, "#{CrystalClick::StreamName.hash(physical_name)}.bin")
  compressed = w155_read_file(path, "#{physical_name} structure")
  CrystalClick::CompressedBlock.decode_all(compressed, max_output_size: W155_MAX_FILE_BYTES)
end

def w155_structure_streams(part : String, bindings : Array(W155StructureBinding)) : CrystalClick::BinaryDynamicStructureStreams
  streams = Hash(String, Bytes).new
  bindings.each do |binding|
    bytes = w155_read_structure(part, binding.physical_name)
    w155_require(bytes == binding.expected_literal,
      "#{binding.site}: stock structure bytes differ from the independent V3 literal: #{bytes.hexstring}")
    streams[binding.site] = bytes
  end
  CrystalClick::BinaryDynamicStructureStreams.new(streams)
end

def w155_compressed_budget : CrystalClick::CompressedStreamBudget
  limits = CrystalClick::CompressedStreamLimits.new(
    max_file_bytes: W155_MAX_FILE_BYTES,
    max_mark_bytes: 1024 * 1024,
    max_frame_compressed_bytes: W155_MAX_FILE_BYTES,
    max_frame_decompressed_bytes: W155_MAX_FILE_BYTES,
    max_records: 100_000,
    max_decoded_bytes: W155_MAX_FILE_BYTES,
    max_result_bytes: W155_MAX_FILE_BYTES,
  )
  CrystalClick::CompressedStreamBudget.new(limits)
end

def w155_read_lane(part : String, binding : W155LaneBinding) : CrystalClick::BinaryBulkStream
  logical_name = binding.physical_name
  data_path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  data_size = File.size(data_path)
  mark_size = File.size(marks_path)
  prefix = binding.basic_discriminator ? CrystalClick::BinaryBulkPhysicalPrefixAdapter::PREFIX_BYTES.to_i : 0
  window = CrystalClick::CompressedMarkReader.read(
    data_path,
    marks_path,
    data_size,
    mark_size,
    first_mark: 0,
    mark_count: 3,
    prefix_size: prefix,
    budget: w155_compressed_budget,
  )
  w155_require(window.rows_per_mark == W155_ROWS_PER_MARK,
    "#{binding.role}: physical mark rows differ from three independent two-row marks")
  w155_require(window.offsets.size == 4, "#{binding.role}: physical mark grid is not K+1 for K=3")
  if binding.basic_discriminator
    bytes, offsets, normalized_prefix = CrystalClick::BinaryBulkPhysicalPrefixAdapter.read_lane(
      binding.role, window.bytes, window.offsets, prefix
    )
    w155_require(normalized_prefix == 0, "#{binding.role}: normalized BASIC mode prefix remains present")
    w155_require(offsets == binding.expected_offsets,
      "#{binding.role}: normalized K+1 offsets differ: expected #{binding.expected_offsets.inspect}, got #{offsets.inspect}")
    CrystalClick::BinaryBulkStream.new(bytes, offsets)
  else
    w155_require(window.prefix_size == 0 && window.offsets.first == 0_u64,
      "#{binding.role}: unexpected physical prefix on ordinary lane")
    w155_require(window.offsets == binding.expected_offsets,
      "#{binding.role}: normalized K+1 offsets differ: expected #{binding.expected_offsets.inspect}, got #{window.offsets.inspect}")
    CrystalClick::BinaryBulkStream.new(window.bytes, window.offsets)
  end
end

def w155_data_streams(part : String, bindings : Array(W155LaneBinding)) : CrystalClick::BinaryBulkStreams
  lanes = Hash(String, CrystalClick::BinaryBulkStream).new
  bindings.each do |binding|
    w155_require(!lanes.has_key?(binding.role), "duplicate normalized role #{binding.role.inspect}")
    lanes[binding.role] = w155_read_lane(part, binding)
  end
  CrystalClick::BinaryBulkStreams.new(3, lanes)
end

def w155_u64(value : UInt64) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.uint64(value)
end

def w155_u8(value : UInt8) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[value])
end

def w155_granules(rows : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
  w155_require(rows.size == 6, "literal case must define exactly six rows")
  [rows[0, 2], rows[2, 2], rows[4, 2]] of Array(CrystalClick::BinaryValue)
end

def w155_compare_value(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue, label : String) : Nil
  w155_require(actual.type == expected.type, "#{label}: type differs: #{actual.type.name} vs #{expected.type.name}")
  w155_require(actual.is_null? == expected.is_null?, "#{label}: NULL state differs")
  return if expected.is_null?

  case actual.type.tag
  when CrystalClick::BinaryDataType::TAG_DYNAMIC
    w155_require(actual.child_count == expected.child_count, "#{label}: Dynamic child count differs")
    actual.child_count.times do |index|
      w155_compare_value(actual.child_at(index), expected.child_at(index), "#{label}.dynamic")
    end
  when CrystalClick::BinaryDataType::TAG_VARIANT
    w155_require(actual.variant_index? == expected.variant_index?, "#{label}: Variant canonical index differs")
    actual.child_count.times do |index|
      w155_compare_value(actual.child_at(index), expected.child_at(index), "#{label}.variant")
    end
  when CrystalClick::BinaryDataType::TAG_ARRAY,
       CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_NAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_MAP,
       CrystalClick::BinaryDataType::TAG_NULLABLE,
       CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
    w155_require(actual.child_count == expected.child_count, "#{label}: child count differs")
    actual.child_count.times do |index|
      w155_compare_value(actual.child_at(index), expected.child_at(index), "#{label}.child#{index}")
    end
  else
    w155_require(actual.bytes == expected.bytes, "#{label}: scalar bytes differ")
  end
  nil
end

def w155_compare_granules(actual : Array(Array(CrystalClick::BinaryValue)),
                          expected : Array(Array(CrystalClick::BinaryValue)), label : String) : Nil
  w155_require(actual.size == expected.size, "#{label}: mark count differs")
  actual.each_with_index do |mark, mark_index|
    w155_require(mark.size == expected[mark_index].size, "#{label}: row count differs in mark #{mark_index}")
    mark.each_with_index do |value, row_index|
      w155_compare_value(value, expected[mark_index][row_index], "#{label}.row#{mark_index * 2 + row_index + 1}")
    end
  end
  nil
end

def w155_expect_reencodes_exactly(original : CrystalClick::BinaryDynamicBulkStreams,
                                  encoded : CrystalClick::BinaryDynamicBulkStreams,
                                  label : String) : Nil
  w155_require(original.structures.site_paths == encoded.structures.site_paths,
    "#{label}: re-encoded Dynamic site paths differ")
  original.structures.site_paths.each do |site|
    w155_require(original.structures.structure_bytes_for(site) == encoded.structures.structure_bytes_for(site),
      "#{label} #{site}: structure bytes differ after paired round-trip")
  end
  expected_roles = original.data.roles
  w155_require(encoded.data.mark_count == 3 && encoded.data.roles == expected_roles,
    "#{label}: normalized role/mark roster differs after encode")
  expected_roles.each do |role|
    source = original.data.stream(role)
    result = encoded.data.stream(role)
    w155_require(source.bytes == result.bytes && source.offsets == result.offsets,
      "#{label} #{role}: normalized lane bytes or K+1 grid differ after paired round-trip")
  end
  nil
end

def w155_qualify_case(part : String, fixture : W155DynamicCase) : CrystalClick::BinaryDynamicBulkStreams
  structure_streams = w155_structure_streams(part, fixture.structures)
  plan = CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
    fixture.type,
    structure_streams,
    CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
    CrystalClick::BinaryBulkProfile.single_stream,
  )
  expected_sites = fixture.structures.map(&.site).sort!
  w155_require(plan.site_paths == expected_sites,
    "#{fixture.label}: occurrence site set differs: #{plan.site_paths.inspect}")
  fixture.structures.each do |binding|
    structure = plan.structure_for(binding.site)
    observed_types = structure.types.map(&.name)
    observed_canonical = structure.canonical_variant_names
    w155_require(observed_types == binding.expected_types,
      "#{fixture.label} #{binding.site}: actual ordinary roster differs from independent expectation: #{observed_types.inspect}")
    w155_require(observed_canonical == binding.expected_canonical_names,
      "#{fixture.label} #{binding.site}: canonical SharedVariant/ordinary IDs differ: #{observed_canonical.inspect}")
  end

  data = w155_data_streams(part, fixture.lanes)
  w155_require(plan.data_roles == fixture.expected_roles.sort!,
    "#{fixture.label}: planned normalized roles differ: #{plan.data_roles.inspect}")
  w155_require(data.roles == fixture.expected_roles.sort!,
    "#{fixture.label}: captured stock lanes differ from independent normalized role roster: #{data.roles.inspect}")
  paired = CrystalClick::BinaryDynamicBulkStreams.new(structure_streams, data)

  decoded = CrystalClick::BinaryDynamicBulkCodec.decode(
    fixture.type,
    paired,
    W155_ROWS_PER_MARK,
    profile: CrystalClick::BinaryBulkProfile.single_stream,
  )
  w155_compare_granules(decoded, fixture.values, fixture.label + " stock-to-library")

  structure_map = Hash(String, CrystalClick::DynamicStructure).new
  plan.site_paths.each { |site| structure_map[site] = plan.structure_for(site) }
  encoded = CrystalClick::BinaryDynamicBulkCodec.encode(
    fixture.type,
    structure_map,
    fixture.values,
    profile: CrystalClick::BinaryBulkProfile.single_stream,
  )
  w155_expect_reencodes_exactly(paired, encoded, fixture.label + " library-to-stock normalized")
  puts ["CASE", fixture.label, "sites=#{plan.site_paths.join(',')}", "roles=#{data.roles.join(',')}", "marks=3"].join("\t")
  paired
end

def w155_dynamic_cases : Array(W155DynamicCase)
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  dynamic_zero = CrystalClick::BinaryDataType.dynamic(max_types: 0)
  string = CrystalClick::BinaryDataType.primitive("String")
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")

  root_values = w155_granules(([
    CrystalClick::BinaryValue.dynamic(dynamic, w155_u64(42_u64)),
    CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("spill")),
    CrystalClick::BinaryValue.dynamic(dynamic),
    CrystalClick::BinaryValue.dynamic(dynamic, w155_u64(43_u64)),
    CrystalClick::BinaryValue.dynamic(dynamic, w155_u64(44_u64)),
    CrystalClick::BinaryValue.dynamic(dynamic, w155_u64(45_u64)),
  ] of CrystalClick::BinaryValue))
  root = W155DynamicCase.new(
    "root_dynamic",
    dynamic,
    ([W155StructureBinding.new("root", "root_dynamic.dynamic_structure", (["UInt64"] of String),
      (["SharedVariant", "UInt64"] of String), W155_ROOT_U64_STRUCTURE)] of W155StructureBinding),
    ([
      W155LaneBinding.new("root.discriminators", "root_dynamic.variant_discr", W155_OFFSETS_TWO_BYTES_PER_MARK, true),
      W155LaneBinding.new("root.arm.0.data", "root_dynamic.SharedVariant", W155_OFFSETS_ONE_SHARED_SPILL),
      W155LaneBinding.new("root.arm.1.data", "root_dynamic.UInt64", W155_OFFSETS_ROOT_UINT64),
    ] of W155LaneBinding),
    (["root.arm.0.data", "root.arm.1.data", "root.discriminators"] of String),
    root_values,
  )

  tuple_type = CrystalClick::BinaryDataType.tuple(
    ([dynamic, dynamic] of CrystalClick::BinaryDataType),
    (["left", "right"] of String),
  )
  tuple_values = w155_granules((0...6).map do |index|
    left = CrystalClick::BinaryValue.dynamic(dynamic, w155_u64((100 + index).to_u64))
    right = CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("r#{index}"))
    CrystalClick::BinaryValue.tuple(tuple_type, ([left, right] of CrystalClick::BinaryValue))
  end)
  tuple_case = W155DynamicCase.new(
    "tuple_equal_nominal_distinct_rosters",
    tuple_type,
    ([
      W155StructureBinding.new("root.field.0", "pair%2Eleft.dynamic_structure", (["UInt64"] of String),
        (["SharedVariant", "UInt64"] of String), W155_TUPLE_LEFT_U64_STRUCTURE),
      W155StructureBinding.new("root.field.1", "pair%2Eright.dynamic_structure", (["String"] of String),
        (["SharedVariant", "String"] of String), W155_TUPLE_RIGHT_STRING_STRUCTURE),
    ] of W155StructureBinding),
    ([
      W155LaneBinding.new("root.field.0.discriminators", "pair%2Eleft.variant_discr", W155_OFFSETS_TWO_BYTES_PER_MARK, true),
      W155LaneBinding.new("root.field.0.arm.0.data", "pair%2Eleft.SharedVariant", W155_OFFSETS_EMPTY),
      W155LaneBinding.new("root.field.0.arm.1.data", "pair%2Eleft.UInt64", W155_OFFSETS_TWO_UINT64_PER_MARK),
      W155LaneBinding.new("root.field.1.discriminators", "pair%2Eright.variant_discr", W155_OFFSETS_TWO_BYTES_PER_MARK, true),
      W155LaneBinding.new("root.field.1.arm.0.data", "pair%2Eright.SharedVariant", W155_OFFSETS_EMPTY),
      W155LaneBinding.new("root.field.1.arm.1.data", "pair%2Eright.String", W155_OFFSETS_TWO_SHORT_STRINGS_PER_MARK),
    ] of W155LaneBinding),
    ([
      "root.field.0.arm.0.data", "root.field.0.arm.1.data", "root.field.0.discriminators",
      "root.field.1.arm.0.data", "root.field.1.arm.1.data", "root.field.1.discriminators",
    ] of String),
    tuple_values,
  )

  array_type = CrystalClick::BinaryDataType.array(dynamic)
  nested_values = w155_granules(([
    CrystalClick::BinaryValue.array(array_type, ([CrystalClick::BinaryValue.dynamic(dynamic, w155_u64(10_u64))] of CrystalClick::BinaryValue)),
    CrystalClick::BinaryValue.array(array_type, ([] of CrystalClick::BinaryValue)),
    CrystalClick::BinaryValue.array(array_type, ([
      CrystalClick::BinaryValue.dynamic(dynamic, w155_u64(12_u64)),
      CrystalClick::BinaryValue.dynamic(dynamic, w155_u64(13_u64)),
    ] of CrystalClick::BinaryValue)),
    CrystalClick::BinaryValue.array(array_type, ([CrystalClick::BinaryValue.dynamic(dynamic, w155_u64(14_u64))] of CrystalClick::BinaryValue)),
    CrystalClick::BinaryValue.array(array_type, ([] of CrystalClick::BinaryValue)),
    CrystalClick::BinaryValue.array(array_type, ([CrystalClick::BinaryValue.dynamic(dynamic, w155_u64(15_u64))] of CrystalClick::BinaryValue)),
  ] of CrystalClick::BinaryValue))
  nested_case = W155DynamicCase.new(
    "array_dynamic_sparse_nested_values",
    array_type,
    ([W155StructureBinding.new("root.elements", "nested.dynamic_structure", (["UInt64"] of String),
      (["SharedVariant", "UInt64"] of String), W155_NESTED_U64_STRUCTURE)] of W155StructureBinding),
    ([
      W155LaneBinding.new("root.sizes", "nested.size0", W155_OFFSETS_TWO_UINT64_PER_MARK),
      W155LaneBinding.new("root.elements.discriminators", "nested.variant_discr", W155_OFFSETS_NESTED_DISCRIMINATORS, true),
      W155LaneBinding.new("root.elements.arm.0.data", "nested.SharedVariant", W155_OFFSETS_EMPTY),
      W155LaneBinding.new("root.elements.arm.1.data", "nested.UInt64", W155_OFFSETS_NESTED_UINT64),
    ] of W155LaneBinding),
    (["root.elements.arm.0.data", "root.elements.arm.1.data", "root.elements.discriminators", "root.sizes"] of String),
    nested_values,
  )

  empty_actual_array = CrystalClick::BinaryDataType.array(dynamic_zero)
  unused_variant_type = CrystalClick::BinaryDataType.variant(
    ([empty_actual_array, uint8] of CrystalClick::BinaryDataType),
  )
  w155_require(unused_variant_type.child_at(0).name == "Array(Dynamic(max_types=0))" &&
               unused_variant_type.child_at(1).name == "UInt8",
    "unused static Variant fixture did not normalize to its independently expected arm IDs")
  unused_values = w155_granules((20_u8..25_u8).map do |value|
    CrystalClick::BinaryValue.variant(unused_variant_type, 1, w155_u8(value))
  end)
  unused_case = W155DynamicCase.new(
    "unused_variant_dynamic_child",
    unused_variant_type,
    ([W155StructureBinding.new("root.arm.0.elements",
      "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.dynamic_structure",
      ([] of String), (["SharedVariant"] of String), W155_UNUSED_EMPTY_STRUCTURE)] of W155StructureBinding),
    ([
      W155LaneBinding.new("root.discriminators", "unused_variant.variant_discr", W155_OFFSETS_TWO_BYTES_PER_MARK, true),
      W155LaneBinding.new("root.arm.0.sizes", "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.size0", W155_OFFSETS_EMPTY),
      W155LaneBinding.new("root.arm.0.elements.discriminators",
        "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.variant_discr", W155_OFFSETS_EMPTY, true),
      W155LaneBinding.new("root.arm.0.elements.arm.0.data",
        "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.SharedVariant", W155_OFFSETS_EMPTY),
      W155LaneBinding.new("root.arm.1.data", "unused_variant.UInt8", W155_OFFSETS_TWO_BYTES_PER_MARK),
    ] of W155LaneBinding),
    ([
      "root.arm.0.elements.arm.0.data", "root.arm.0.elements.discriminators", "root.arm.0.sizes",
      "root.arm.1.data", "root.discriminators",
    ] of String),
    unused_values,
  )

  [root, tuple_case, nested_case, unused_case] of W155DynamicCase
end

def w155_mutate_root_u64(original : CrystalClick::BinaryDynamicBulkStreams,
                         type : CrystalClick::BinaryDataType,
                         expected : Array(Array(CrystalClick::BinaryValue))) : Nil
  role = "root.arm.1.data"
  w155_require(original.data.has_role?(role), "wrong-value control cannot find root UInt64 arm lane")
  mutated_lanes = Hash(String, CrystalClick::BinaryBulkStream).new
  original.data.roles.each do |name|
    stream = original.data.stream(name)
    if name == role
      bytes = stream.bytes
      w155_require(bytes.size >= 8 && bytes[0] == 42_u8, "wrong-value control did not find the literal initial UInt64 42")
      bytes[0] = 43_u8
      mutated_lanes[name] = CrystalClick::BinaryBulkStream.new(bytes, stream.offsets)
    else
      mutated_lanes[name] = stream
    end
  end
  mutated_data = CrystalClick::BinaryBulkStreams.new(3, mutated_lanes)
  mutated = CrystalClick::BinaryDynamicBulkStreams.new(original.structures, mutated_data)
  decoded = CrystalClick::BinaryDynamicBulkCodec.decode(
    type,
    mutated,
    W155_ROWS_PER_MARK,
    profile: CrystalClick::BinaryBulkProfile.single_stream,
  )
  mismatch_observed = false
  begin
    w155_compare_granules(decoded, expected, "wrong-u64-control")
  rescue ex : W155Mismatch
    mismatch_observed = true
  end
  w155_require(mismatch_observed, "valid 42-to-43 mutation decoded but escaped independent expected-value rejection")
  puts "NEGATIVE-CONTROL\tnormalized-stock-lane-42-to-43\tcrystal-decode=accepted\tindependent-literal-values=REJECTED"
  nil
end

def w155_qualify(part : String) : Nil
  w155_require(Dir.exists?(part) && !File.symlink?(part), "stock part directory is absent or a symlink")
  w155_require(File.realpath(part) == File.expand_path(part), "stock part path must be canonical")
  observed = w155_substream_names(part)
  expected = w155_expected_substreams.sort!
  w155_require(observed == expected,
    "exact stock substream roster differs: expected #{expected.inspect}, got #{observed.inspect}")
  w155_validate_part_files(part, expected)

  cases = w155_dynamic_cases
  root = w155_qualify_case(part, cases[0])
  cases[1..].each { |fixture| w155_qualify_case(part, fixture) }
  w155_mutate_root_u64(root, cases[0].type, cases[0].values)
  puts "W155 stock Dynamic bulk qualification PASS columns=4 rows=6 marks=3"
  nil
end

begin
  unless ARGV.size == 2 && ARGV[0] == "--qualify"
    w155_fail("usage: check_dynamic_bulk_values_w155.cr --qualify STOCK_PART_PATH")
  end
  w155_qualify(ARGV[1])
rescue ex : W155Mismatch
  STDERR.puts ex.message
  exit(1)
rescue ex : CrystalClick::Error
  STDERR.puts "W155 stock Dynamic bulk qualification: CrystalClick error: #{ex.message}"
  exit(1)
end
