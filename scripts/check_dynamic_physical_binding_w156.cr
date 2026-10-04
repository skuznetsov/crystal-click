# W156 finite stock Wide Dynamic physical binder qualifier.
# Scope: the pinned W155 single_stream/BASIC fixture only; this is not a
# general storage reader, full part writer, or qualification of other profiles.
require "../src/crystal_click"

class W156Mismatch < Exception
end

W156_MAX_FILE_BYTES       = 8_i64 * 1024 * 1024
W156_ROWS_PER_MARK        = [2_u64, 2_u64, 2_u64]
W156_OFFSETS_EMPTY        = [0_u64, 0_u64, 0_u64, 0_u64]
W156_OFFSETS_TWO_BYTES    = [0_u64, 2_u64, 4_u64, 6_u64]
W156_OFFSETS_TWO_U64      = [0_u64, 16_u64, 32_u64, 48_u64]
W156_OFFSETS_ROOT_U64     = [0_u64, 8_u64, 16_u64, 32_u64]
W156_OFFSETS_NESTED_U64   = [0_u64, 8_u64, 32_u64, 40_u64]
W156_OFFSETS_NESTED_DISCR = [0_u64, 1_u64, 4_u64, 5_u64]
W156_OFFSETS_TWO_STRINGS  = [0_u64, 6_u64, 12_u64, 18_u64]
W156_OFFSETS_SHARED_SPILL = [0_u64, 8_u64, 8_u64, 8_u64]

W156_ROOT_STRUCTURE = Bytes[
  0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
  0x01_u8, 0x04_u8, 0x01_u8, 0x01_u8, 0x04_u8, 0x01_u8, 0x06_u8,
  0x53_u8, 0x74_u8, 0x72_u8, 0x69_u8, 0x6E_u8, 0x67_u8, 0x01_u8,
]
W156_TUPLE_LEFT_STRUCTURE = Bytes[
  0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
  0x01_u8, 0x04_u8, 0x01_u8, 0x00_u8, 0x06_u8, 0x00_u8,
]
W156_TUPLE_RIGHT_STRUCTURE = Bytes[
  0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
  0x01_u8, 0x15_u8, 0x01_u8, 0x00_u8, 0x06_u8, 0x00_u8,
]
W156_NESTED_STRUCTURE = Bytes[
  0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
  0x01_u8, 0x04_u8, 0x01_u8, 0x00_u8, 0x05_u8, 0x00_u8,
]
W156_UNUSED_STRUCTURE = Bytes[
  0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
  0x00_u8, 0x01_u8, 0x00_u8, 0x00_u8,
]

def w156_fail(message : String) : NoReturn
  raise W156Mismatch.new("W156 physical binding: #{message}")
end

def w156_require(condition : Bool, message : String) : Nil
  w156_fail(message) unless condition
end

struct W156StructureBinding
  getter site : String
  getter role : String
  getter physical_name : String
  getter literal : Bytes
  getter expected_types : Array(String)
  getter expected_canonical : Array(String)

  def initialize(@site : String, @role : String, @physical_name : String,
                 @literal : Bytes, @expected_types : Array(String),
                 @expected_canonical : Array(String))
  end
end

struct W156LaneBinding
  getter role : String
  getter physical_name : String
  getter offsets : Array(UInt64)
  getter prefix_size : Int32

  def initialize(@role : String, @physical_name : String,
                 @offsets : Array(UInt64), @prefix_size : Int32 = 0)
  end
end

struct W156Case
  getter column : String
  getter type : CrystalClick::BinaryDataType
  getter structures : Array(W156StructureBinding)
  getter lanes : Array(W156LaneBinding)
  getter expected_rows : Array(Array(CrystalClick::BinaryValue))

  def initialize(@column : String, @type : CrystalClick::BinaryDataType,
                 @structures : Array(W156StructureBinding), @lanes : Array(W156LaneBinding),
                 @expected_rows : Array(Array(CrystalClick::BinaryValue)))
  end
end

struct W156ReadCase
  getter fixture : W156Case
  getter bulk_plan : CrystalClick::BinaryDynamicBulkPlan
  getter physical_plan : CrystalClick::BinaryDynamicBulkPhysicalPlan
  getter paired : CrystalClick::BinaryDynamicBulkStreams
  getter decoded : Array(Array(CrystalClick::BinaryValue))

  def initialize(@fixture : W156Case, @bulk_plan : CrystalClick::BinaryDynamicBulkPlan,
                 @physical_plan : CrystalClick::BinaryDynamicBulkPhysicalPlan,
                 @paired : CrystalClick::BinaryDynamicBulkStreams,
                 @decoded : Array(Array(CrystalClick::BinaryValue)))
  end
end

def w156_read_file(path : String, label : String) : Bytes
  w156_require(File.file?(path) && !File.symlink?(path), "#{label}: missing regular file or symlink")
  size = File.size(path)
  w156_require(size >= 0 && size <= W156_MAX_FILE_BYTES, "#{label}: file exceeds 8 MiB")
  text = File.read(path)
  Bytes.new(text.bytesize) { |index| text.to_slice[index] }
end

def w156_write_target_file(part : String, path : String, bytes : Bytes, label : String) : Nil
  canonical_part = File.realpath(part)
  expanded_path = File.expand_path(path)
  w156_require(expanded_path.starts_with?(canonical_part + File::SEPARATOR), "#{label}: output escaped copied part")
  w156_require(File.file?(expanded_path) && !File.symlink?(expanded_path), "#{label}: replacement target is not an existing regular file")
  w156_require(File.size(expanded_path) <= W156_MAX_FILE_BYTES, "#{label}: existing target exceeds 8 MiB")
  w156_require(bytes.size.to_i64 <= W156_MAX_FILE_BYTES, "#{label}: replacement exceeds 8 MiB")
  File.open(expanded_path, "wb") { |file| file.write(bytes) }
  nil
end

def w156_hashed_path(part : String, physical_name : String, extension : String) : String
  File.join(part, "#{CrystalClick::StreamName.hash(physical_name)}#{extension}")
end

def w156_substreams(part : String) : Array(String)
  bytes = w156_read_file(File.join(part, "columns_substreams.txt"), "columns_substreams.txt")
  String.new(bytes).lines.select(&.starts_with?("\t")).map(&.strip).reject(&.empty?).sort!
end

def w156_expected_substreams : Array(String)
  [
    "id",
    "root_dynamic.dynamic_structure", "root_dynamic.variant_discr", "root_dynamic.SharedVariant", "root_dynamic.UInt64",
    "pair%2Eleft.dynamic_structure", "pair%2Eleft.variant_discr", "pair%2Eleft.SharedVariant", "pair%2Eleft.UInt64",
    "pair%2Eright.dynamic_structure", "pair%2Eright.variant_discr", "pair%2Eright.SharedVariant", "pair%2Eright.String",
    "nested.dynamic_structure", "nested.size0", "nested.variant_discr", "nested.SharedVariant", "nested.UInt64",
    "unused_variant.variant_discr", "unused_variant.UInt8",
    "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.size0",
    "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.dynamic_structure",
    "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.variant_discr",
    "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.SharedVariant",
  ] of String
end

def w156_validate_part_roster(part : String) : Nil
  expected = w156_expected_substreams.sort!
  actual = w156_substreams(part)
  w156_require(actual == expected, "stock substream roster differs from independent W155 literal mapping")
  expected_files = expected.map { |name| CrystalClick::StreamName.hash(name) }.sort!
  bins = Dir.children(part).select(&.ends_with?(".bin")).map { |name| name[0, name.size - 4] }.sort!
  marks = Dir.children(part).select(&.ends_with?(".mrk2")).map { |name| name[0, name.size - 5] }.sort!
  w156_require(bins == expected_files, "hashed .bin roster differs from independent W155 literal mapping")
  w156_require(marks == expected_files, "hashed .mrk2 roster differs from independent W155 literal mapping")
  nil
end

def w156_rows(values : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
  w156_require(values.size == 6, "literal row oracle must contain exactly six rows")
  [values[0, 2], values[2, 2], values[4, 2]] of Array(CrystalClick::BinaryValue)
end

def w156_u8(value : UInt8) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[value])
end

def w156_compare_value(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue, label : String) : Nil
  w156_require(actual.type == expected.type, "#{label}: value type differs")
  w156_require(actual.is_null? == expected.is_null?, "#{label}: NULL state differs")
  return if expected.is_null?
  case actual.type.tag
  when CrystalClick::BinaryDataType::TAG_DYNAMIC
    w156_require(actual.child_count == expected.child_count, "#{label}: Dynamic child count differs")
    actual.child_count.times { |index| w156_compare_value(actual.child_at(index), expected.child_at(index), "#{label}.dynamic") }
  when CrystalClick::BinaryDataType::TAG_VARIANT
    w156_require(actual.variant_index? == expected.variant_index?, "#{label}: Variant canonical index differs")
    actual.child_count.times { |index| w156_compare_value(actual.child_at(index), expected.child_at(index), "#{label}.variant") }
  when CrystalClick::BinaryDataType::TAG_ARRAY,
       CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_NAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_MAP,
       CrystalClick::BinaryDataType::TAG_NULLABLE,
       CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
    w156_require(actual.child_count == expected.child_count, "#{label}: child count differs")
    actual.child_count.times { |index| w156_compare_value(actual.child_at(index), expected.child_at(index), "#{label}.child#{index}") }
  else
    w156_require(actual.bytes == expected.bytes, "#{label}: scalar bytes differ")
  end
  nil
end

def w156_compare_rows(actual : Array(Array(CrystalClick::BinaryValue)), expected : Array(Array(CrystalClick::BinaryValue)), label : String) : Nil
  w156_require(actual.size == 3 && expected.size == 3, "#{label}: expected three real marks")
  actual.each_with_index do |mark, mark_index|
    w156_require(mark.size == expected[mark_index].size, "#{label}: row count differs in mark #{mark_index}")
    mark.each_with_index { |value, row_index| w156_compare_value(value, expected[mark_index][row_index], "#{label}.row#{mark_index * 2 + row_index + 1}") }
  end
  nil
end

def w156_read_structure(part : String, physical_name : String) : Bytes
  compressed = w156_read_file(w156_hashed_path(part, physical_name, ".bin"), "#{physical_name} compressed structure")
  CrystalClick::CompressedBlock.decode_all(compressed, max_output_size: W156_MAX_FILE_BYTES)
end

def w156_compressed_budget : CrystalClick::CompressedStreamBudget
  limits = CrystalClick::CompressedStreamLimits.new(
    max_file_bytes: W156_MAX_FILE_BYTES,
    max_mark_bytes: 1024 * 1024,
    max_frame_compressed_bytes: W156_MAX_FILE_BYTES,
    max_frame_decompressed_bytes: W156_MAX_FILE_BYTES,
    max_records: 100_000,
    max_decoded_bytes: W156_MAX_FILE_BYTES,
    max_result_bytes: W156_MAX_FILE_BYTES,
  )
  CrystalClick::CompressedStreamBudget.new(limits)
end

def w156_read_lane(part : String, physical : CrystalClick::BinaryDynamicBulkPhysicalPlan,
                   binding : W156LaneBinding) : CrystalClick::BinaryBulkStream
  data_path = File.join(part, physical.data_file_for(binding.role, hashed: true))
  marks_path = File.join(part, physical.marks_file_for(binding.role, hashed: true))
  window = CrystalClick::CompressedMarkReader.read(
    data_path,
    marks_path,
    File.size(data_path),
    File.size(marks_path),
    first_mark: 0,
    mark_count: 3,
    prefix_size: binding.prefix_size,
    budget: w156_compressed_budget,
  )
  w156_require(window.rows_per_mark == W156_ROWS_PER_MARK, "#{binding.role}: expected 3 marks with two rows each")
  w156_require(window.offsets.size == 4, "#{binding.role}: expected K+1=4 physical offsets")
  if binding.prefix_size > 0
    bytes, offsets, normalized_prefix = CrystalClick::BinaryBulkPhysicalPrefixAdapter.read_lane(
      binding.role, window.bytes, window.offsets, binding.prefix_size
    )
    w156_require(normalized_prefix == 0, "#{binding.role}: BASIC prefix survived normalization")
    w156_require(offsets == binding.offsets, "#{binding.role}: normalized K+1 offsets differ from literal grid")
    CrystalClick::BinaryBulkStream.new(bytes, offsets)
  else
    w156_require(window.prefix_size == 0, "#{binding.role}: unexpected physical prefix")
    w156_require(window.offsets == binding.offsets, "#{binding.role}: K+1 offsets differ from literal grid")
    CrystalClick::BinaryBulkStream.new(window.bytes, window.offsets)
  end
end

def w156_check_physical_plan(physical : CrystalClick::BinaryDynamicBulkPhysicalPlan,
                             fixture : W156Case) : Nil
  expected_data = Hash(String, String).new
  fixture.lanes.each { |lane| expected_data[lane.role] = lane.physical_name }
  expected_structures = Hash(String, String).new
  fixture.structures.each { |structure| expected_structures[structure.role] = structure.physical_name }
  expected_combined = expected_data.dup
  expected_structures.each { |role, name| expected_combined[role] = name }

  w156_require(physical.data_stream_names == expected_data, "#{fixture.column}: data role-to-basename map differs from independent literals")
  w156_require(physical.structure_stream_names == expected_structures, "#{fixture.column}: structure role-to-basename map differs from independent literals")
  w156_require(physical.stream_names == expected_combined, "#{fixture.column}: combined physical role map differs from independent literals")
  fixture.structures.each do |structure|
    w156_require(physical.structure_name_for(structure.site) == structure.physical_name,
      "#{fixture.column} #{structure.site}: structure basename differs from independent literal")
  end
  fixture.lanes.each do |lane|
    w156_require(physical.prefix_size_for(lane.role) == lane.prefix_size,
      "#{fixture.column} #{lane.role}: role-owned prefix size differs")
    w156_require(physical.data_file_for(lane.role) == "#{lane.physical_name}.bin",
      "#{fixture.column} #{lane.role}: un-hashed data path differs")
    w156_require(physical.marks_file_for(lane.role) == "#{lane.physical_name}.mrk2",
      "#{fixture.column} #{lane.role}: un-hashed mark path differs")
    hash = CrystalClick::StreamName.hash(lane.physical_name)
    w156_require(physical.data_file_for(lane.role, hashed: true) == "#{hash}.bin",
      "#{fixture.column} #{lane.role}: hashed data path differs")
    w156_require(physical.marks_file_for(lane.role, hashed: true) == "#{hash}.mrk2",
      "#{fixture.column} #{lane.role}: hashed mark path differs")
  end
  nil
end

def w156_read_case(part : String, fixture : W156Case) : W156ReadCase
  # The literal bootstrap is intentionally separate from the new planner: it
  # proves the stock metadata is the expected roster before any mapped read.
  structures = Hash(String, Bytes).new
  fixture.structures.each do |binding|
    bytes = w156_read_structure(part, binding.physical_name)
    w156_require(bytes == binding.literal, "#{fixture.column} #{binding.site}: stock V3 structure differs from literal bytes")
    structures[binding.site] = bytes
  end
  structure_streams = CrystalClick::BinaryDynamicStructureStreams.new(structures)
  plan = CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
    fixture.type,
    structure_streams,
    CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
    CrystalClick::BinaryBulkProfile.single_stream,
  )
  expected_sites = fixture.structures.map(&.site).sort!
  w156_require(plan.site_paths == expected_sites, "#{fixture.column}: decoded site paths differ from independent literals")
  fixture.structures.each do |binding|
    structure = plan.structure_for(binding.site)
    w156_require(structure.types.map(&.name) == binding.expected_types,
      "#{fixture.column} #{binding.site}: ordinary roster differs from literal roster")
    w156_require(structure.canonical_variant_names == binding.expected_canonical,
      "#{fixture.column} #{binding.site}: canonical SharedVariant ordering differs from literal roster")
  end

  physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, fixture.column)
  w156_check_physical_plan(physical, fixture)
  # Exercise the validated escaped-prefix entry point as a second construction
  # of the tuple lane map; raw construction above remains the actual reader.
  if fixture.column == "pair"
    escaped = CrystalClick::PhysicalStreamName.escape(fixture.column)
    from_prefix = CrystalClick::BinaryDynamicBulkPhysicalPlan.from_escaped_prefix(plan, escaped)
    w156_require(from_prefix.stream_names == physical.stream_names,
      "escaped-prefix constructor changed the tuple physical role map")
  end

  mapped_structures = Hash(String, Bytes).new
  fixture.structures.each do |binding|
    name = physical.structure_name_for(binding.site)
    bytes = w156_read_structure(part, name)
    w156_require(name == binding.physical_name && bytes == binding.literal,
      "#{fixture.column} #{binding.site}: planner-mapped metadata read differs from literal")
    mapped_structures[binding.site] = bytes
  end
  lanes = Hash(String, CrystalClick::BinaryBulkStream).new
  fixture.lanes.each do |binding|
    w156_require(physical.data_stream_names[binding.role]? == binding.physical_name,
      "#{fixture.column} #{binding.role}: planner is missing literal data mapping")
    lanes[binding.role] = w156_read_lane(part, physical, binding)
  end
  data = CrystalClick::BinaryBulkStreams.new(3, lanes)
  w156_require(data.roles == fixture.lanes.map(&.role).sort!, "#{fixture.column}: planner-mapped lane role roster differs")
  paired = CrystalClick::BinaryDynamicBulkStreams.new(CrystalClick::BinaryDynamicStructureStreams.new(mapped_structures), data)
  decoded = CrystalClick::BinaryDynamicBulkCodec.decode(
    fixture.type, paired, W156_ROWS_PER_MARK, profile: plan.profile
  )
  w156_compare_rows(decoded, fixture.expected_rows, "#{fixture.column} stock-to-library literal rows")
  W156ReadCase.new(fixture, plan, physical, paired, decoded)
end

def w156_expect_round_trip(source : CrystalClick::BinaryDynamicBulkStreams,
                           encoded : CrystalClick::BinaryDynamicBulkStreams,
                           label : String) : Nil
  w156_require(source.structures.site_paths == encoded.structures.site_paths, "#{label}: structure site roster changed")
  source.structures.site_paths.each do |site|
    w156_require(source.structures.structure_bytes_for(site) == encoded.structures.structure_bytes_for(site),
      "#{label} #{site}: encoded structure differs")
  end
  w156_require(source.data.roles == encoded.data.roles && encoded.data.mark_count == 3,
    "#{label}: data role or mark roster changed")
  source.data.roles.each do |role|
    left = source.data.stream(role)
    right = encoded.data.stream(role)
    w156_require(left.bytes == right.bytes && left.offsets == right.offsets,
      "#{label} #{role}: normalized bytes or K+1 grid changed")
  end
  nil
end

def w156_expect_mutant(source : CrystalClick::BinaryDynamicBulkStreams,
                       encoded : CrystalClick::BinaryDynamicBulkStreams,
                       label : String) : Nil
  w156_require(source.structures.site_paths == encoded.structures.site_paths,
    "#{label}: Dynamic structure sites changed")
  source.structures.site_paths.each do |site|
    w156_require(source.structures.structure_bytes_for(site) == encoded.structures.structure_bytes_for(site),
      "#{label} #{site}: valid value mutation changed its type/statistics structure")
  end
  w156_require(source.data.roles == encoded.data.roles && encoded.data.mark_count == 3,
    "#{label}: data role or mark roster changed")
  source.data.roles.each do |role|
    before = source.data.stream(role)
    after = encoded.data.stream(role)
    w156_require(before.offsets == after.offsets, "#{label} #{role}: valid value mutation changed mark coordinates")
    if role == "root.arm.1.data"
      expected = before.bytes
      w156_require(expected.size == 32 && expected[0] == 42_u8,
        "#{label}: expected four UInt64 values beginning with 42")
      expected[0] = 43_u8
      w156_require(after.bytes == expected, "#{label}: mutant changed bytes beyond UInt64 42-to-43")
    else
      w156_require(before.bytes == after.bytes, "#{label} #{role}: valid value mutation changed unrelated lane bytes")
    end
  end
  nil
end

def w156_structure_statistics_offset(bytes : Bytes) : Int32
  context = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryCodecLimits.default, bytes)
  _structure, offset = CrystalClick::DynamicStructureCodec.read_with_statistics_offset(context)
  context.ensure_consumed
  offset
end

def w156_write_case(part : String, read : W156ReadCase,
                    values : Array(Array(CrystalClick::BinaryValue)), label : String,
                    mutant : Bool = false) : Nil
  structures = Hash(String, CrystalClick::DynamicStructure).new
  read.bulk_plan.site_paths.each { |site| structures[site] = read.bulk_plan.structure_for(site) }
  encoded = CrystalClick::BinaryDynamicBulkCodec.encode(
    read.fixture.type, structures, values, profile: read.bulk_plan.profile
  )
  if mutant
    w156_expect_mutant(read.paired, encoded, "#{label} exact single-value mutation")
  else
    w156_expect_round_trip(read.paired, encoded, "#{label} library-to-stock normalized")
  end

  read.fixture.structures.each do |binding|
    name = read.physical_plan.structure_name_for(binding.site)
    bytes = encoded.structures.structure_bytes_for(binding.site)
    w156_require(name == binding.physical_name && bytes == binding.literal,
      "#{label} #{binding.site}: mapped structure output differs from literal")
    files = CrystalClick::CompressedMarkWriter.encode_metadata(
      bytes, w156_structure_statistics_offset(bytes), W156_ROWS_PER_MARK,
      frame_bytes: 4096,
    )
    w156_write_target_file(part, w156_hashed_path(part, name, ".bin"), files.data,
      "#{label} #{binding.site} structure data")
    w156_write_target_file(part, w156_hashed_path(part, name, ".mrk2"), files.marks,
      "#{label} #{binding.site} structure marks")
  end

  read.fixture.lanes.each do |binding|
    logical = encoded.data.stream(binding.role)
    prefix = read.physical_plan.prefix_size_for(binding.role)
    w156_require(prefix == binding.prefix_size, "#{label} #{binding.role}: writer prefix differs from independent role mapping")
    physical_bytes, physical_offsets, physical_prefix = if prefix > 0
                                                          CrystalClick::BinaryBulkPhysicalPrefixAdapter.write_lane(binding.role, logical, prefix)
                                                        else
                                                          {logical.bytes, logical.offsets, 0_i32}
                                                        end
    w156_require(physical_prefix == binding.prefix_size,
      "#{label} #{binding.role}: prefix adapter returned a different physical prefix")
    files = CrystalClick::CompressedMarkWriter.encode(
      physical_bytes, physical_offsets, W156_ROWS_PER_MARK,
      prefix_size: physical_prefix, frame_bytes: 4096,
    )
    data_path = File.join(part, read.physical_plan.data_file_for(binding.role, hashed: true))
    marks_path = File.join(part, read.physical_plan.marks_file_for(binding.role, hashed: true))
    w156_write_target_file(part, data_path, files.data, "#{label} #{binding.role} data")
    w156_write_target_file(part, marks_path, files.marks, "#{label} #{binding.role} marks")
  end
  nil
end

def w156_compare_value_arrays(actual : Array(Array(CrystalClick::BinaryValue)),
                              expected : Array(Array(CrystalClick::BinaryValue)), label : String) : Nil
  w156_compare_rows(actual, expected, label)
end

def w156_mutate_root(read : W156ReadCase) : Array(Array(CrystalClick::BinaryValue))
  values = read.decoded.flatten
  w156_require(values.size == 6 && values[0].child_count == 1, "mutant did not locate six root Dynamic values")
  original = values[0].child_at(0)
  w156_require(original.type.name == "UInt64" && original.bytes == Bytes[42_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8],
    "mutant did not find literal root UInt64 42")
  values[0] = CrystalClick::BinaryValue.dynamic(read.fixture.type, CrystalClick::BinaryValue.uint64(43_u64))
  w156_rows(values)
end

module CrystalClick
  module WidePartWriter
    # W156-local borrowed-envelope checksum repair, including the narrow
    # legitimate empty compressed data-lane representation from W149.
    def self.w156_rebuild_checksums(part : String) : Nil
      original = PartChecksums.open(part)
      records = [] of ChecksumRecord
      original.entries.keys.sort.each do |name|
        path = File.join(part, name)
        raise "W156 checksum input is missing or symlinked: #{name}" if File.symlink?(path) || !File.file?(path)
        physical_size = File.size(path)
        raise "W156 checksum input exceeds 8 MiB: #{name}" if physical_size > 8_i64 * 1024 * 1024
        physical_text = File.read(path)
        physical = Bytes.new(physical_text.bytesize) { |index| physical_text.to_slice[index] }
        entry = original.entry(name) || raise "W156 checksum entry disappeared: #{name}"
        if entry.compressed
          raw = if physical.empty?
                  unless name.ends_with?(".bin") && entry.uncompressed_size == 0_u64
                    raise "W156 empty compressed input is not a declared empty .bin lane: #{name}"
                  end
                  Bytes.empty
                else
                  CompressedBlock.decode_all(physical, max_output_size: 8_i64 * 1024 * 1024)
                end
          records << ChecksumRecord.new(name, physical.size.to_u64, CityHashV1.file_hash(physical), true,
            raw.size.to_u64, CityHashV1.file_hash(raw))
        else
          records << ChecksumRecord.new(name, physical.size.to_u64, CityHashV1.file_hash(physical), false)
        end
      end
      PartChecksumsWriter.write(part, records)
      repaired = PartChecksums.open(part)
      unless repaired.entries.keys.sort == original.entries.keys.sort
        raise "W156 checksum repair changed the envelope roster"
      end
      repaired.entries.each_key { |name| repaired.validate_selected_entries(part, name) }
      nil
    end
  end
end

def w156_write_borrowed_parts(root : String, cases : Array(W156Case), stock : String,
                              library : String, mutant : String) : Nil
  reads = cases.map { |fixture| w156_read_case(stock, fixture) }
  reads.each { |read| w156_write_case(library, read, read.decoded, "library/#{read.fixture.column}") }
  root_case = reads.find { |read| read.fixture.column == "root_dynamic" } || w156_fail("root Dynamic case is missing")
  mutated = w156_mutate_root(root_case)
  w156_compare_value_arrays(mutated, w156_root_values(43_u64), "mutant literal values")
  w156_write_case(mutant, root_case, mutated, "mutant/root_dynamic", mutant: true)
  CrystalClick::WidePartWriter.w156_rebuild_checksums(library)
  CrystalClick::WidePartWriter.w156_rebuild_checksums(mutant)
  puts "WRITE\tlibrary\tplanner-mapped Dynamic structures and all data lanes\tchecksums-rebuilt"
  puts "WRITE\tmutant\troot UInt64 42-to-43 through planner\tchecksums-rebuilt"
  puts "MUTANT-LANE\troot.arm.1.data\tvalid UInt64 42-to-43; native CHECK/value oracle is Ruby runner"
  nil
end

def w156_u64(value : UInt64) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.uint64(value)
end

def w156_string(value : String) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.string(value)
end

def w156_root_values(first : UInt64 = 42_u64) : Array(Array(CrystalClick::BinaryValue))
  type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  w156_rows([
    CrystalClick::BinaryValue.dynamic(type, w156_u64(first)),
    CrystalClick::BinaryValue.dynamic(type, w156_string("spill")),
    CrystalClick::BinaryValue.dynamic(type),
    CrystalClick::BinaryValue.dynamic(type, w156_u64(43_u64)),
    CrystalClick::BinaryValue.dynamic(type, w156_u64(44_u64)),
    CrystalClick::BinaryValue.dynamic(type, w156_u64(45_u64)),
  ] of CrystalClick::BinaryValue)
end

def w156_cases : Array(W156Case)
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  dynamic_zero = CrystalClick::BinaryDataType.dynamic(max_types: 0)
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")

  root = W156Case.new(
    "root_dynamic", dynamic,
    ([W156StructureBinding.new("root", "root.dynamic_structure", "root_dynamic.dynamic_structure",
      W156_ROOT_STRUCTURE, ["UInt64"], ["SharedVariant", "UInt64"])] of W156StructureBinding),
    ([
      W156LaneBinding.new("root.discriminators", "root_dynamic.variant_discr", W156_OFFSETS_TWO_BYTES, 8),
      W156LaneBinding.new("root.arm.0.data", "root_dynamic.SharedVariant", W156_OFFSETS_SHARED_SPILL),
      W156LaneBinding.new("root.arm.1.data", "root_dynamic.UInt64", W156_OFFSETS_ROOT_U64),
    ] of W156LaneBinding),
    w156_root_values,
  )

  tuple_type = CrystalClick::BinaryDataType.tuple(
    ([dynamic, dynamic] of CrystalClick::BinaryDataType), ["left", "right"]
  )
  tuple_rows = (0...6).map do |index|
    left = CrystalClick::BinaryValue.dynamic(dynamic, w156_u64((100 + index).to_u64))
    right = CrystalClick::BinaryValue.dynamic(dynamic, w156_string("r#{index}"))
    CrystalClick::BinaryValue.tuple(tuple_type, [left, right])
  end
  tuple_case = W156Case.new(
    "pair", tuple_type,
    ([
      W156StructureBinding.new("root.field.0", "root.field.0.dynamic_structure", "pair%2Eleft.dynamic_structure",
        W156_TUPLE_LEFT_STRUCTURE, ["UInt64"], ["SharedVariant", "UInt64"]),
      W156StructureBinding.new("root.field.1", "root.field.1.dynamic_structure", "pair%2Eright.dynamic_structure",
        W156_TUPLE_RIGHT_STRUCTURE, ["String"], ["SharedVariant", "String"]),
    ] of W156StructureBinding),
    ([
      W156LaneBinding.new("root.field.0.discriminators", "pair%2Eleft.variant_discr", W156_OFFSETS_TWO_BYTES, 8),
      W156LaneBinding.new("root.field.0.arm.0.data", "pair%2Eleft.SharedVariant", W156_OFFSETS_EMPTY),
      W156LaneBinding.new("root.field.0.arm.1.data", "pair%2Eleft.UInt64", W156_OFFSETS_TWO_U64),
      W156LaneBinding.new("root.field.1.discriminators", "pair%2Eright.variant_discr", W156_OFFSETS_TWO_BYTES, 8),
      W156LaneBinding.new("root.field.1.arm.0.data", "pair%2Eright.SharedVariant", W156_OFFSETS_EMPTY),
      W156LaneBinding.new("root.field.1.arm.1.data", "pair%2Eright.String", W156_OFFSETS_TWO_STRINGS),
    ] of W156LaneBinding),
    w156_rows(tuple_rows),
  )

  array_type = CrystalClick::BinaryDataType.array(dynamic)
  nested_values = [
    CrystalClick::BinaryValue.array(array_type, [CrystalClick::BinaryValue.dynamic(dynamic, w156_u64(10_u64))]),
    CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue),
    CrystalClick::BinaryValue.array(array_type, [CrystalClick::BinaryValue.dynamic(dynamic, w156_u64(12_u64)),
                                                 CrystalClick::BinaryValue.dynamic(dynamic, w156_u64(13_u64))]),
    CrystalClick::BinaryValue.array(array_type, [CrystalClick::BinaryValue.dynamic(dynamic, w156_u64(14_u64))]),
    CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue),
    CrystalClick::BinaryValue.array(array_type, [CrystalClick::BinaryValue.dynamic(dynamic, w156_u64(15_u64))]),
  ] of CrystalClick::BinaryValue
  nested_case = W156Case.new(
    "nested", array_type,
    ([W156StructureBinding.new("root.elements", "root.elements.dynamic_structure", "nested.dynamic_structure",
      W156_NESTED_STRUCTURE, ["UInt64"], ["SharedVariant", "UInt64"])] of W156StructureBinding),
    ([
      W156LaneBinding.new("root.sizes", "nested.size0", W156_OFFSETS_TWO_U64),
      W156LaneBinding.new("root.elements.discriminators", "nested.variant_discr", W156_OFFSETS_NESTED_DISCR, 8),
      W156LaneBinding.new("root.elements.arm.0.data", "nested.SharedVariant", W156_OFFSETS_EMPTY),
      W156LaneBinding.new("root.elements.arm.1.data", "nested.UInt64", W156_OFFSETS_NESTED_U64),
    ] of W156LaneBinding),
    w156_rows(nested_values),
  )

  empty_dynamic_array = CrystalClick::BinaryDataType.array(dynamic_zero)
  unused_type = CrystalClick::BinaryDataType.variant([empty_dynamic_array, uint8])
  unused_values = (20_u8..25_u8).map do |value|
    CrystalClick::BinaryValue.variant(unused_type, 1, w156_u8(value))
  end
  unused_case = W156Case.new(
    "unused_variant", unused_type,
    ([W156StructureBinding.new("root.arm.0.elements", "root.arm.0.elements.dynamic_structure",
      "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.dynamic_structure",
      W156_UNUSED_STRUCTURE, [] of String, ["SharedVariant"])] of W156StructureBinding),
    ([
      W156LaneBinding.new("root.discriminators", "unused_variant.variant_discr", W156_OFFSETS_TWO_BYTES, 8),
      W156LaneBinding.new("root.arm.0.sizes", "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.size0", W156_OFFSETS_EMPTY),
      W156LaneBinding.new("root.arm.0.elements.discriminators",
        "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.variant_discr", W156_OFFSETS_EMPTY, 8),
      W156LaneBinding.new("root.arm.0.elements.arm.0.data",
        "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.SharedVariant", W156_OFFSETS_EMPTY),
      W156LaneBinding.new("root.arm.1.data", "unused_variant.UInt8", W156_OFFSETS_TWO_BYTES),
    ] of W156LaneBinding),
    w156_rows(unused_values),
  )
  [root, tuple_case, nested_case, unused_case] of W156Case
end

def w156_validate_inputs(root : String, stock : String, library : String, mutant : String) : Nil
  canonical_root = File.realpath(root)
  w156_require(File.expand_path(root) == canonical_root, "scratch root must be canonical")
  expected_stock_prefix = File.join(canonical_root, "stores", "w156_stock") + File::SEPARATOR
  expected_library = File.join(canonical_root, "parts", "library", "all_1_1_0")
  expected_mutant = File.join(canonical_root, "parts", "mutant", "all_1_1_0")
  w156_require(File.realpath(stock) == File.expand_path(stock) && File.expand_path(stock).starts_with?(expected_stock_prefix),
    "stock source must remain inside the isolated stock store")
  w156_require(File.realpath(library) == expected_library && File.realpath(mutant) == expected_mutant,
    "writes are limited to the two named copied fixture targets")
  [stock, library, mutant].each do |part|
    w156_require(Dir.exists?(part) && !File.symlink?(part), "part path is absent or symlinked: #{part}")
    w156_validate_part_roster(part)
  end
  nil
end

def w156_qualify(root : String, stock : String, library : String, mutant : String) : Nil
  w156_validate_inputs(root, stock, library, mutant)
  w156_write_borrowed_parts(root, w156_cases, stock, library, mutant)
  puts "W156 stock Dynamic physical binder qualification PASS columns=4 rows=6 marks=3 profile=single_stream"
  nil
end

begin
  unless ARGV.size == 5 && ARGV[0] == "--qualify"
    w156_fail("usage: check_dynamic_physical_binding_w156.cr --qualify SCRATCH_ROOT STOCK_PART LIBRARY_PART MUTANT_PART")
  end
  w156_qualify(ARGV[1], ARGV[2], ARGV[3], ARGV[4])
rescue ex : W156Mismatch
  STDERR.puts ex.message
  exit(1)
rescue ex : CrystalClick::Error
  STDERR.puts "W156 physical binding: CrystalClick error: #{ex.message}"
  exit(1)
rescue ex
  STDERR.puts "W156 physical binding: #{ex.message}"
  exit(1)
end
