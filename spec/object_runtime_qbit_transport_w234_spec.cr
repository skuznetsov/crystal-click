require "file_utils"
require "./spec_helper"

private def w234_write_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w234_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w234_write_u64_at(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w234_read_u64(bytes : Bytes, offset : Int) : UInt64
  raise ArgumentError.new("W234 UInt64 field is truncated") if offset < 0 || offset > bytes.size - 8
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private class W234CountingPartStreamSource < CrystalClick::PartStreamSource
  getter window_attempts : Array(Tuple(String, Int32, Int32, Int32))
  getter read_all_result_bytes : Int64
  getter window_result_bytes : Int64

  def initialize(part_path : String)
    super(part_path)
    @window_attempts = [] of Tuple(String, Int32, Int32, Int32)
    @read_all_result_bytes = 0_i64
    @window_result_bytes = 0_i64
  end

  def read_all(
    data_name : String,
    budget : CrystalClick::CompressedStreamBudget = CrystalClick::CompressedStreamBudget.read_default,
  ) : Bytes
    bytes = super(data_name, budget)
    @read_all_result_bytes += bytes.size.to_i64
    bytes
  end

  def read_window(
    data_name : String,
    marks_name : String,
    first_mark : Int,
    mark_count : Int,
    prefix_size : Int = 0,
    budget : CrystalClick::CompressedStreamBudget = CrystalClick::CompressedStreamBudget.read_default,
  ) : CrystalClick::CompressedMarkWindow
    @window_attempts << {data_name, first_mark.to_i32, mark_count.to_i32, prefix_size.to_i32}
    window = super(data_name, marks_name, first_mark, mark_count, prefix_size, budget)
    @window_result_bytes += window.bytes.size.to_i64
    window
  end

  def positive_window_data_names : Array(String)
    names = [] of String
    @window_attempts.each do |attempt|
      names << attempt[0] if attempt[2] > 0
    end
    names
  end

  def prefix_read_count(data_names : Array(String), prefix_size : Int) : Int
    @window_attempts.count do |attempt|
      data_names.includes?(attempt[0]) && attempt[2] == 0 && attempt[3] == prefix_size.to_i32
    end
  end
end

private def w234_encode_literal_lz4_frame(raw : Bytes) : Bytes
  raise ArgumentError.new("cannot encode an empty W234 LZ4 block") if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  4.times { |index| frame[header + 1 + index] = ((compressed_size >> (index * 8)) & 0xff).to_u8 }
  4.times { |index| frame[header + 5 + index] = ((raw.size >> (index * 8)) & 0xff).to_u8 }

  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  if raw.size < 15
    frame[cursor] = (raw.size << 4).to_u8
    cursor += 1
  else
    frame[cursor] = 0xf0_u8
    cursor += 1
    remaining = raw.size - 15
    while remaining >= 255
      frame[cursor] = 255_u8
      cursor += 1
      remaining -= 255
    end
    frame[cursor] = remaining.to_u8
    cursor += 1
  end
  raw.copy_to(frame[cursor, raw.size])
  checksum = CrystalClick::CityHashV1.hash128(
    frame[CrystalClick::CompressedBlock::CHECKSUM_SIZE, compressed_size]
  )
  w234_write_u64_at(frame, 0, checksum[0])
  w234_write_u64_at(frame, 8, checksum[1])
  frame
end

private def w234_refresh_part_checksums!(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w234_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w234_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w234_write_varuint(payload, file_bytes.size.to_u64)
    hash = CrystalClick::CityHashV1.file_hash(file_bytes)
    w234_write_u64(payload, hash[0])
    w234_write_u64(payload, hash[1])
    if entry.compressed
      raw = file_bytes.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w234_write_varuint(payload, raw.size.to_u64)
      raw_hash = CrystalClick::CityHashV1.file_hash(raw)
      w234_write_u64(payload, raw_hash[0])
      w234_write_u64(payload, raw_hash[1])
    else
      payload.write_byte(0_u8)
    end
  end
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(w234_encode_literal_lz4_frame(payload.to_slice))
  end
end

private def w234_rewrite_mark_byte!(
  part : String,
  physical : CrystalClick::BinaryBulkPhysicalPlan | CrystalClick::BinaryDynamicBulkPhysicalPlan,
  role : String,
  mark_index : Int,
  expected : UInt8,
  replacement_byte : UInt8,
) : Nil
  marks_name = physical.marks_file_for(role, true)
  marks = File.read(File.join(part, marks_name)).to_slice
  record_offset = mark_index * CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE
  compressed_offset = w234_read_u64(marks, record_offset)
  decompressed_offset = w234_read_u64(marks, record_offset + 8)
  data_name = physical.data_file_for(role, true)
  data_path = File.join(part, data_name)
  data = File.read(data_path).to_slice.dup
  frame = CrystalClick::CompressedBlock.decode_frame(data, compressed_offset.to_i64)
  raw = frame.output.dup
  unless decompressed_offset < raw.size.to_u64
    raise ArgumentError.new("W234 mark byte is outside its compressed frame")
  end
  target = decompressed_offset.to_i
  raw[target].should eq(expected)
  raw[target] = replacement_byte
  replacement = w234_encode_literal_lz4_frame(raw)
  replacement.size.should eq((frame.end_offset - compressed_offset.to_i64).to_i)
  replacement.copy_to(data[compressed_offset.to_i, replacement.size])
  File.write(data_path, data)
end

private def w234_qbit_value(type : CrystalClick::QBitType, seed : UInt8) : CrystalClick::BinaryValue
  raw = Bytes.new(type.raw_row_bytes) { |index| (seed.to_i + index).to_u8 }
  CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(type, raw))
end

private def w234_document(path : String, value : CrystalClick::BinaryValue) : CrystalClick::ObjectDocument
  fields = Hash(String, CrystalClick::BinaryValue).new
  fields[path] = value
  CrystalClick::ObjectDocument.new(fields)
end

private def w234_assert_array_row(
  document : CrystalClick::ObjectDocument,
  path : String,
  array_type : CrystalClick::BinaryDataType,
  qbit_type : CrystalClick::QBitType,
  raw : Bytes,
) : Nil
  value = document.value_for(path)
  value.type.should eq(array_type)
  value.elements.size.should eq(1)
  element = value.elements[0]
  element.type.should eq(CrystalClick::BinaryDataType.qbit(qbit_type))
  element.qbit_value.type.should eq(qbit_type)
  element.qbit_value.raw_bytes.should eq(raw)
end

private def w234_with_late_count_drift(&)
  path = "payload"
  qbit_type = CrystalClick::QBitType.new("Int8", 1_u64)
  qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
  array_qbit = CrystalClick::BinaryDataType.array(qbit)
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  roster = CrystalClick::DynamicStructure.new([array_qbit, uint64] of CrystalClick::BinaryDataType)
  schema = CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType)
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([path] of String),
    {path => roster} of String => CrystalClick::DynamicStructure,
  )
  plan = CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
  raws = [Bytes[0x10_u8], Bytes[0x20_u8], Bytes[0x30_u8]] of Bytes
  granules = raws.map do |raw|
    value = CrystalClick::BinaryValue.array(
      array_qbit,
      [w234_qbit_value(qbit_type, raw[0])] of CrystalClick::BinaryValue,
    )
    [w234_document(path, value)] of CrystalClick::ObjectDocument
  end
  keys = Slice[1_u64, 2_u64, 3_u64]
  profile = CrystalClick::BinaryBulkProfile.single_stream
  physical = CrystalClick::ObjectDocumentPhysicalPlan.new(path, plan, profile)
  arm_physical = physical.dynamic_arm(path, array_qbit.name)
  size_role = arm_physical.stream_names.keys.find(&.ends_with?(".sizes")).not_nil!

  parent = File.tempname("crystal-click-w234-object-runtime-qbit-")
  Dir.mkdir(parent)
  begin
    part = File.join(parent, "all_1_1_0")
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      part,
      "pk",
      keys,
      path,
      schema,
      plan,
      granules,
      rows_per_mark: 1,
      profile: profile,
      frame_bytes: 32,
    ).should eq(part)

    # Sensitivity control: establish that this same public reader consumes
    # all three untouched marks and the empty EOF range before seeding drift.
    reader = CrystalClick::ObjectColumnReader.open(part, path, schema)
    reader.row_count.should eq(3_u64)
    full = reader.read_marks(0, 3)
    full.size.should eq(3)
    full.each_with_index do |mark, index|
      mark.size.should eq(1)
      w234_assert_array_row(mark[0], path, array_qbit, qbit_type, raws[index])
    end
    reader.read_marks(3, 0).should be_empty

    # 2 is a valid Array element count. Its unchanged eight QBit plane lanes
    # still carry only one element for this late mark.
    w234_rewrite_mark_byte!(part, arm_physical, size_role, 2, 1_u8, 2_u8)
    w234_refresh_part_checksums!(part)
    yield part, path, schema
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w234_with_typed_late_count_drift(&)
  path = "payload"
  qbit_type = CrystalClick::QBitType.new("Int8", 1_u64)
  qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
  array_qbit = CrystalClick::BinaryDataType.array(qbit)
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 4)
  roster = CrystalClick::DynamicStructure.new([array_qbit, uint64] of CrystalClick::BinaryDataType)
  schema = CrystalClick::ObjectDocumentSchema.new({path => dynamic} of String => CrystalClick::BinaryDataType)
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  plan = CrystalClick::ObjectDocumentPlan.new(
    structures,
    schema.typed_paths,
    {path => roster} of String => CrystalClick::DynamicStructure,
  )
  raws = [Bytes[0x10_u8], Bytes[0x20_u8], Bytes[0x30_u8]] of Bytes
  granules = raws.map do |raw|
    actual = CrystalClick::BinaryValue.array(
      array_qbit,
      [w234_qbit_value(qbit_type, raw[0])] of CrystalClick::BinaryValue,
    )
    [w234_document(path, CrystalClick::BinaryValue.dynamic(dynamic, actual))] of CrystalClick::ObjectDocument
  end
  keys = Slice[1_u64, 2_u64, 3_u64]
  profile = CrystalClick::BinaryBulkProfile.single_stream
  physical = CrystalClick::ObjectDocumentPhysicalPlan.new(path, plan, profile)
  typed_physical = physical.typed_dynamic(path)
  size_role = typed_physical.stream_names.keys.find(&.ends_with?(".sizes")).not_nil!

  parent = File.tempname("crystal-click-w234-object-typed-qbit-count-drift-")
  Dir.mkdir(parent)
  begin
    part = File.join(parent, "all_1_1_0")
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      part,
      "pk",
      keys,
      path,
      schema,
      plan,
      granules,
      rows_per_mark: 1,
      profile: profile,
      frame_bytes: 32,
    ).should eq(part)

    # Positive controls prove normal typed-Dynamic payload and EOF reads work
    # before the checksum-valid late Array-size mutation.
    reader = CrystalClick::ObjectColumnReader.open(part, path, schema)
    reader.row_count.should eq(3_u64)
    full = reader.read_marks(0, 3)
    full.size.should eq(3)
    full.each_with_index do |mark, index|
      mark.size.should eq(1)
      dynamic_value = mark[0].value_for(path)
      dynamic_value.type.should eq(dynamic)
      actual = dynamic_value.child_at(0)
      actual.type.should eq(array_qbit)
      actual.element_count.should eq(1)
      actual.element_at(0).qbit_value.type.should eq(qbit_type)
      actual.element_at(0).qbit_value.raw_bytes.should eq(raws[index])
    end
    reader.read_marks(3, 0).should be_empty

    # 2 is a valid element count, but the late QBit plane marks still encode
    # one element. Complete census must reject before either callback range.
    w234_rewrite_mark_byte!(part, typed_physical, size_role, 2, 1_u8, 2_u8)
    w234_refresh_part_checksums!(part)
    yield part, path, schema
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w234_with_two_inferred_qbit_sites(max_elements : Int, &)
  left_path = "left_payload"
  right_path = "right_payload"
  qbit_type = CrystalClick::QBitType.new("Int8", 1_u64)
  qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
  array_qbit = CrystalClick::BinaryDataType.array(qbit)
  nested_array_qbit = CrystalClick::BinaryDataType.array(array_qbit)
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  roster = CrystalClick::DynamicStructure.new([nested_array_qbit, uint64] of CrystalClick::BinaryDataType)
  limits = CrystalClick::BinaryCodecLimits.new(
    max_depth: 64,
    max_nodes: 100_000,
    max_elements: max_elements,
    max_bytes: 1_048_576,
  )
  schema = CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType)
  reader_schema = CrystalClick::ObjectDocumentSchema.new(
    {} of String => CrystalClick::BinaryDataType,
    limits: limits,
  )
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([left_path, right_path] of String),
    {left_path => roster, right_path => roster} of String => CrystalClick::DynamicStructure,
  )
  plan = CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
  granules = Array(Array(CrystalClick::ObjectDocument)).new(2) do |_mark|
    Array(CrystalClick::ObjectDocument).new(1) do |_row|
      left_values = Array(CrystalClick::BinaryValue).new(256) do |_index|
        CrystalClick::BinaryValue.array(array_qbit, [] of CrystalClick::BinaryValue)
      end
      right_values = Array(CrystalClick::BinaryValue).new(256) do |_index|
        CrystalClick::BinaryValue.array(array_qbit, [] of CrystalClick::BinaryValue)
      end
      left = CrystalClick::BinaryValue.array(
        nested_array_qbit,
        left_values,
      )
      right = CrystalClick::BinaryValue.array(
        nested_array_qbit,
        right_values,
      )
      fields = Hash(String, CrystalClick::BinaryValue).new
      fields[left_path] = left
      fields[right_path] = right
      CrystalClick::ObjectDocument.new(fields)
    end
  end
  keys = Slice(UInt64).new(2) { |index| (index + 1).to_u64 }
  profile = CrystalClick::BinaryBulkProfile.single_stream
  parent = File.tempname("crystal-click-w234-object-qbit-shared-budget-")
  Dir.mkdir(parent)
  begin
    part = File.join(parent, "all_1_1_0")
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      part,
      "pk",
      keys,
      left_path,
      schema,
      plan,
      granules,
      rows_per_mark: 1,
      profile: profile,
      frame_bytes: 64,
    ).should eq(part)
    yield part, left_path, reader_schema
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w234_with_three_typed_dynamic_paths(&)
  left_path = "left_payload"
  right_path = "right_payload"
  plain_path = "plain_payload"
  qbit_type = CrystalClick::QBitType.new("Int8", 1_u64)
  qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
  array_qbit = CrystalClick::BinaryDataType.array(qbit)
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  string = CrystalClick::BinaryDataType.primitive("String")
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 4)
  qbit_roster = CrystalClick::DynamicStructure.new([array_qbit, uint64] of CrystalClick::BinaryDataType)
  plain_roster = CrystalClick::DynamicStructure.new([uint64, string] of CrystalClick::BinaryDataType)
  typed_paths = {
    left_path  => dynamic,
    right_path => dynamic,
    plain_path => dynamic,
  } of String => CrystalClick::BinaryDataType
  schema = CrystalClick::ObjectDocumentSchema.new(typed_paths)
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  typed_rosters = {
    left_path  => qbit_roster,
    right_path => qbit_roster,
    plain_path => plain_roster,
  } of String => CrystalClick::DynamicStructure
  plan = CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths, typed_rosters)
  granules = Array(Array(CrystalClick::ObjectDocument)).new(2) do |mark|
    left = CrystalClick::BinaryValue.dynamic(
      dynamic,
      CrystalClick::BinaryValue.array(
        array_qbit,
        [w234_qbit_value(qbit_type, (0x10_u8 + mark.to_u8))] of CrystalClick::BinaryValue,
      ),
    )
    right = CrystalClick::BinaryValue.dynamic(
      dynamic,
      CrystalClick::BinaryValue.array(
        array_qbit,
        [w234_qbit_value(qbit_type, (0x20_u8 + mark.to_u8))] of CrystalClick::BinaryValue,
      ),
    )
    plain = CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64((70 + mark).to_u64))
    fields = Hash(String, CrystalClick::BinaryValue).new
    fields[left_path] = left
    fields[right_path] = right
    fields[plain_path] = plain
    [CrystalClick::ObjectDocument.new(fields)] of CrystalClick::ObjectDocument
  end
  keys = Slice[1_u64, 2_u64]
  profile = CrystalClick::BinaryBulkProfile.single_stream
  parent = File.tempname("crystal-click-w234-typed-qbit-header-preflight-")
  Dir.mkdir(parent)
  begin
    part = File.join(parent, "all_1_1_0")
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      part,
      "pk",
      keys,
      "payload",
      schema,
      plan,
      granules,
      rows_per_mark: 1,
      mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
      profile: profile,
      frame_bytes: 32,
    ).should eq(part)
    yield part, schema, plan, dynamic, qbit_roster, [left_path, right_path] of String, [left_path, right_path, plain_path] of String
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w234_typed_qbit_shape_and_header_extents(
  part : String,
  plan : CrystalClick::ObjectDocumentPlan,
  dynamic : CrystalClick::BinaryDataType,
  qbit_roster : CrystalClick::DynamicStructure,
  qbit_paths : Array(String),
  typed_paths : Array(String),
) : Tuple(Int64, Int64, Array(String), Array(String))
  profile = CrystalClick::BinaryBulkProfile.single_stream
  physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan, profile)
  root_rosters = {"root" => qbit_roster} of String => CrystalClick::DynamicStructure
  dynamic_plan = CrystalClick::BinaryDynamicBulkPlan.new(dynamic, root_rosters)
  size_roles = dynamic_plan.data_roles.select(&.ends_with?(".sizes"))
  size_roles.size.should eq(1)
  # Census result reads cover only selector and size shape lanes. QBit plane
  # grids are inspected for extents, but their payload bytes remain unread
  # until a selected-value consumer runs.
  roles = ["root.discriminators", size_roles.first] of String

  shape_bytes = 0_i64
  shape_data_names = [] of String
  qbit_paths.each do |path|
    site_physical = physical.typed_dynamic(path)
    source = CrystalClick::PartStreamSource.new(part)
    roles.each do |role|
      data_name = site_physical.data_file_for(role, true)
      marks_name = site_physical.marks_file_for(role, true)
      grid = source.inspect_grid(data_name, marks_name)
      shape_bytes += grid.logical_size
      shape_data_names << data_name unless shape_data_names.includes?(data_name)
    end
  end

  header_bytes = 0_i64
  header_data_names = [] of String
  typed_paths.each do |path|
    site_physical = physical.typed_dynamic(path)
    header_role = "root.discriminators"
    header_bytes += site_physical.prefix_size_for(header_role).to_i64
    header_data_names << site_physical.data_file_for(header_role, true)
  end
  {shape_bytes, header_bytes, shape_data_names, header_data_names}
end

private def w234_inspect_typed_dynamic_site(
  source : CrystalClick::PartStreamSource,
  schema : CrystalClick::ObjectDocumentSchema,
  transport_budget : CrystalClick::CompressedStreamBudget,
) : CrystalClick::ObjectDocumentFileDescriptor
  limits = CrystalClick::ObjectDocumentCodec::DEFAULT_LIMITS
  CrystalClick::ObjectDocumentFileReader.inspect_at_site(
    source,
    "payload",
    schema.typed_paths,
    CrystalClick::BinaryCodecBudget.new(limits),
    CrystalClick::PhysicalStreamPlanContext.new(limits),
    transport_budget,
    hashed: true,
  )
end

private def w234_read_typed_dynamic_site(
  source : CrystalClick::PartStreamSource,
  schema : CrystalClick::ObjectDocumentSchema,
  transport_budget : CrystalClick::CompressedStreamBudget,
  first_mark : Int = 0,
  mark_count : Int? = nil,
) : Array(Array(CrystalClick::ObjectDocument))
  limits = CrystalClick::ObjectDocumentCodec::DEFAULT_LIMITS
  CrystalClick::ObjectDocumentFileReader.read_at_site(
    source,
    "payload",
    schema.typed_paths,
    CrystalClick::BinaryCodecBudget.new(limits),
    CrystalClick::PhysicalStreamPlanContext.new(limits),
    transport_budget,
    first_mark: first_mark,
    mark_count: mark_count,
    hashed: true,
  )
end

describe "W234 inferred Object Dynamic QBit occurrence census" do
  it "rejects late ordinary Array count drift before an early read" do
    w234_with_late_count_drift do |part, path, schema|
      error = expect_raises(CrystalClick::CorruptPartError) do
        reader = CrystalClick::ObjectColumnReader.open(part, path, schema)
        reader.read_marks(0, 1)
      end
      error.message.not_nil!.should contain("static QBit QBit plane mark differs from its size-derived occurrence schedule")
    end
  end

  it "rejects late ordinary Array count drift before an empty EOF read" do
    w234_with_late_count_drift do |part, path, schema|
      error = expect_raises(CrystalClick::CorruptPartError) do
        reader = CrystalClick::ObjectColumnReader.open(part, path, schema)
        reader.read_marks(3, 0)
      end
      error.message.not_nil!.should contain("static QBit QBit plane mark differs from its size-derived occurrence schedule")
    end
  end

  it "admits two inferred QBit sites at their shared exact 514-element per-mark limit" do
    w234_with_two_inferred_qbit_sites(514) do |part, path, schema|
      CrystalClick::ObjectColumnReader.open(part, path, schema).row_count.should eq(2_u64)
    end
  end

  it "rejects one element below the shared two-site per-mark occurrence total" do
    w234_with_two_inferred_qbit_sites(513) do |part, path, schema|
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectColumnReader.open(part, path, schema)
      end
      error.message.not_nil!.should eq("binary codec element limit exceeded")
    end
  end
end

describe "W234 typed Object Dynamic QBit occurrence census" do
  it "rejects late ordinary Array count drift before an early read" do
    w234_with_typed_late_count_drift do |part, path, schema|
      error = expect_raises(CrystalClick::CorruptPartError) do
        reader = CrystalClick::ObjectColumnReader.open(part, path, schema)
        reader.read_marks(0, 1)
      end
      error.message.not_nil!.should eq("Dynamic QBit QBit plane mark differs from its occurrence schedule")
    end
  end

  it "rejects late ordinary Array count drift before an empty EOF read" do
    w234_with_typed_late_count_drift do |part, path, schema|
      error = expect_raises(CrystalClick::CorruptPartError) do
        reader = CrystalClick::ObjectColumnReader.open(part, path, schema)
        reader.read_marks(3, 0)
      end
      error.message.not_nil!.should eq("Dynamic QBit QBit plane mark differs from its occurrence schedule")
    end
  end
end

describe "W234 typed Dynamic QBit result preflight" do
  it "preflights repeated headers for multiple QBit paths and a non-QBit Dynamic path" do
    w234_with_three_typed_dynamic_paths do |part, schema, plan, dynamic, qbit_roster, qbit_paths, typed_paths|
      shape_bytes, header_bytes, shape_data_names, header_data_names =
        w234_typed_qbit_shape_and_header_extents(part, plan, dynamic, qbit_roster, qbit_paths, typed_paths)
      # COMPACT Dynamic framing contributes 8 header bytes plus, per one-row
      # mark, one VarUInt count, one uniform-format byte, and one tag: 14
      # discriminator bytes per path. The Array size lane carries one UInt64
      # per row, hence 16 bytes per path across two marks.
      shape_bytes.should eq(60_i64)
      header_bytes.should eq(24_i64)

      # Public full and EOF controls establish that the untouched typed paths
      # decode correctly and that the empty range is still checked.
      full = w234_read_typed_dynamic_site(
        CrystalClick::PartStreamSource.new(part),
        schema,
        CrystalClick::CompressedStreamBudget.read_default,
      )
      full.size.should eq(2)
      full.each_with_index do |mark, index|
        mark.size.should eq(1)
        {qbit_paths[0], qbit_paths[1]}.each do |path|
          value = mark[0].value_for(path)
          value.type.should eq(dynamic)
          value.child_at(0).type.tag.should eq(CrystalClick::BinaryDataType::TAG_ARRAY)
          value.child_at(0).element_at(0).qbit_value.raw_bytes.should eq(Bytes[(0x10 + index).to_u8]) if path == qbit_paths[0]
          value.child_at(0).element_at(0).qbit_value.raw_bytes.should eq(Bytes[(0x20 + index).to_u8]) if path == qbit_paths[1]
        end
        plain = mark[0].value_for(typed_paths[2])
        plain.type.should eq(dynamic)
        plain.child_at(0).as_uint64.should eq((70 + index).to_u64)
      end
      eof = w234_read_typed_dynamic_site(
        CrystalClick::PartStreamSource.new(part),
        schema,
        CrystalClick::CompressedStreamBudget.read_default,
        first_mark: 2,
        mark_count: 0,
      )
      eof.should be_empty

      baseline_source = W234CountingPartStreamSource.new(part)
      baseline_budget = CrystalClick::CompressedStreamBudget.read_default
      descriptor = w234_inspect_typed_dynamic_site(baseline_source, schema, baseline_budget)
      descriptor.row_count.should eq(2_u64)
      expected_shape_and_headers = shape_bytes + header_bytes
      expected_shape_and_headers.should eq(84_i64)
      baseline_source.window_result_bytes.should eq(expected_shape_and_headers)
      baseline_budget.result_byte_count.should eq(
        baseline_source.read_all_result_bytes + expected_shape_and_headers
      )
      baseline_source.positive_window_data_names.sort.should eq(shape_data_names.sort)
      baseline_source.prefix_read_count(header_data_names, 8).should eq(3)

      exact_limit = baseline_source.read_all_result_bytes + expected_shape_and_headers
      exact_source = W234CountingPartStreamSource.new(part)
      exact_budget = CrystalClick::CompressedStreamBudget.new(
        CrystalClick::CompressedStreamLimits.new(max_result_bytes: exact_limit),
      )
      exact_descriptor = w234_inspect_typed_dynamic_site(exact_source, schema, exact_budget)
      exact_descriptor.row_count.should eq(2_u64)
      exact_budget.result_byte_count.should eq(exact_limit)
      exact_source.window_result_bytes.should eq(expected_shape_and_headers)
      exact_source.positive_window_data_names.sort.should eq(shape_data_names.sort)
      exact_source.prefix_read_count(header_data_names, 8).should eq(3)

      short_source = W234CountingPartStreamSource.new(part)
      short_budget = CrystalClick::CompressedStreamBudget.new(
        CrystalClick::CompressedStreamLimits.new(max_result_bytes: exact_limit - 1),
      )
      error = expect_raises(CrystalClick::CorruptPartError) do
        w234_inspect_typed_dynamic_site(short_source, schema, short_budget)
      end
      error.message.not_nil!.should contain("compressed stream result-byte limit exceeded")
      short_source.positive_window_data_names.any? do |name|
        shape_data_names.includes?(name)
      end.should be_false
      short_source.prefix_read_count(header_data_names, 8).should eq(0)
    end
  end
end
