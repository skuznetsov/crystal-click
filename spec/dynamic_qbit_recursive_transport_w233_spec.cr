require "./spec_helper"
require "file_utils"

private struct W233WindowRead
  getter data_name : String
  getter first_mark : Int32
  getter mark_count : Int32

  def initialize(@data_name : String, first_mark : Int, mark_count : Int)
    @first_mark = first_mark.to_i32
    @mark_count = mark_count.to_i32
  end
end

private class W233CountingPartStreamSource < CrystalClick::PartStreamSource
  @window_reads : Array(W233WindowRead)

  def initialize(part_path : String)
    super(part_path)
    @window_reads = [] of W233WindowRead
  end

  def read_window(
    data_name : String,
    marks_name : String,
    first_mark : Int,
    mark_count : Int,
    prefix_size : Int = 0,
    budget : CrystalClick::CompressedStreamBudget = CrystalClick::CompressedStreamBudget.read_default,
  ) : CrystalClick::CompressedMarkWindow
    @window_reads << W233WindowRead.new(data_name, first_mark, mark_count)
    super
  end

  def window_reads : Array(W233WindowRead)
    @window_reads.dup
  end
end

private class W233DynamicPartFixture
  getter scratch : String
  getter part : String
  getter type : CrystalClick::BinaryDataType
  getter structures : Hash(String, CrystalClick::DynamicStructure)
  getter plan : CrystalClick::BinaryDynamicBulkPlan
  getter physical : CrystalClick::BinaryDynamicBulkPhysicalPlan

  def initialize(
    @type : CrystalClick::BinaryDataType,
    @structures : Hash(String, CrystalClick::DynamicStructure),
    rows : Array(Array(CrystalClick::BinaryValue)),
    rows_per_mark : Int32 = 1,
  )
    @plan = CrystalClick::BinaryDynamicBulkPlan.new(
      @type,
      @structures,
      CrystalClick::BinaryBulkProfile.single_stream,
    )
    @physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(@plan, "payload")
    @scratch = File.tempname("crystal-click-w233-dynamic-qbit-transport-")
    Dir.mkdir(@scratch)
    @part = File.join(@scratch, "all_1_1_0")
    keys = Slice(UInt64).new(rows.size) { |index| (index + 1).to_u64 }
    begin
      CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
        @part,
        "pk",
        keys,
        "payload",
        @type,
        @structures,
        rows,
        rows_per_mark: rows_per_mark,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
        frame_bytes: 32,
      )
    rescue ex
      FileUtils.rm_rf(@scratch)
      raise ex
    end
  end

  def close : Nil
    FileUtils.rm_rf(@scratch)
  end
end

private def w233_write_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w233_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w233_write_u64_at(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w233_read_u64(bytes : Bytes, offset : Int) : UInt64
  raise ArgumentError.new("W233 UInt64 field is truncated") if offset < 0 || offset > bytes.size - 8
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w233_encode_literal_lz4_frame(raw : Bytes) : Bytes
  raise ArgumentError.new("cannot encode an empty W233 LZ4 block") if raw.empty?
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
  w233_write_u64_at(frame, 0, checksum[0])
  w233_write_u64_at(frame, 8, checksum[1])
  frame
end

private def w233_refresh_part_checksums!(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w233_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w233_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w233_write_varuint(payload, file_bytes.size.to_u64)
    hash = CrystalClick::CityHashV1.file_hash(file_bytes)
    w233_write_u64(payload, hash[0])
    w233_write_u64(payload, hash[1])
    if entry.compressed
      raw = file_bytes.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w233_write_varuint(payload, raw.size.to_u64)
      raw_hash = CrystalClick::CityHashV1.file_hash(raw)
      w233_write_u64(payload, raw_hash[0])
      w233_write_u64(payload, raw_hash[1])
    else
      payload.write_byte(0_u8)
    end
  end
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(w233_encode_literal_lz4_frame(payload.to_slice))
  end
end

private def w233_bump_mark_start!(
  fixture : W233DynamicPartFixture,
  role : String,
  mark_index : Int,
) : Nil
  marks_name = fixture.physical.marks_file_for(role, true)
  marks = File.read(File.join(fixture.part, marks_name)).to_slice.dup
  record_offset = mark_index * CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE
  compressed_offset = w233_read_u64(marks, record_offset)
  decompressed_offset = w233_read_u64(marks, record_offset + 8)
  data_name = fixture.physical.data_file_for(role, true)
  data_path = File.join(fixture.part, data_name)
  data = File.read(data_path).to_slice
  frame = CrystalClick::CompressedBlock.decode_frame(data, compressed_offset.to_i64)
  unless decompressed_offset + 1_u64 < frame.output.size.to_u64
    raise ArgumentError.new("W233 late mark has no following byte in its compressed frame")
  end
  w233_write_u64_at(marks, record_offset + 8, decompressed_offset + 1_u64)
  File.write(File.join(fixture.part, marks_name), marks)
end

private def w233_rewrite_mark_byte!(
  fixture : W233DynamicPartFixture,
  role : String,
  mark_index : Int,
  expected : UInt8,
  replacement_byte : UInt8,
) : Nil
  marks_name = fixture.physical.marks_file_for(role, true)
  marks = File.read(File.join(fixture.part, marks_name)).to_slice
  record_offset = mark_index * CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE
  compressed_offset = w233_read_u64(marks, record_offset)
  decompressed_offset = w233_read_u64(marks, record_offset + 8)
  data_name = fixture.physical.data_file_for(role, true)
  data_path = File.join(fixture.part, data_name)
  data = File.read(data_path).to_slice.dup
  frame = CrystalClick::CompressedBlock.decode_frame(data, compressed_offset.to_i64)
  raw = frame.output.dup
  unless decompressed_offset < raw.size.to_u64
    raise ArgumentError.new("W233 mark byte is outside its compressed frame")
  end
  target = decompressed_offset.to_i
  raw[target].should eq(expected)
  raw[target] = replacement_byte
  replacement = w233_encode_literal_lz4_frame(raw)
  replacement.size.should eq((frame.end_offset - compressed_offset.to_i64).to_i)
  replacement.copy_to(data[compressed_offset.to_i, replacement.size])
  File.write(data_path, data)
end

private def w233_corrupt_direct_qbit_count!(fixture : W233DynamicPartFixture, mark_index : Int) : Nil
  fixture.plan.qbit_sites.size.should eq(1)
  fixture.plan.qbit_sites[0].plane_roles.each do |role|
    w233_bump_mark_start!(fixture, role, mark_index)
  end
  w233_refresh_part_checksums!(fixture.part)
end

private def w233_assert_readable_before_corruption!(part : String, total_rows : UInt64) : Nil
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
  early_callbacks = 0
  table.scan_typed_window(0_u64, 1) { |_batch| early_callbacks += 1 }
  early_callbacks.should eq(1)
  eof_callbacks = 0
  table.scan_typed_window(total_rows, 1) { |_batch| eof_callbacks += 1 }
  eof_callbacks.should eq(0)
end

private def w233_assert_rejected_before_callback!(
  part : String,
  first_row : UInt64,
  count : Int,
  message_fragment : String,
) : Nil
  callbacks = 0
  error = expect_raises(CrystalClick::CorruptPartError) do
    table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
    table.scan_typed_window(first_row, count) { |_batch| callbacks += 1 }
  end
  error.message.not_nil!.should contain(message_fragment)
  callbacks.should eq(0)
end

private def w233_transport_qbit_value(type : CrystalClick::QBitType, seed : UInt8) : CrystalClick::BinaryValue
  raw = Bytes.new(type.raw_row_bytes) { |index| (seed.to_i + index).to_u8 }
  CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(type, raw))
end

private def w233_transport_variant_arm_index(
  variant : CrystalClick::BinaryDataType,
  arm : CrystalClick::BinaryDataType,
) : Int
  variant.child_count.times do |index|
    return index if variant.child_at(index) == arm
  end
  raise ArgumentError.new("W233 transport Variant fixture arm is absent")
end

describe "W233 Dynamic QBit recursive transport schedule" do
  it "rejects late selector/plane occurrence drift before an early typed callback" do
    qbit_type = CrystalClick::QBitType.new("Int8", 1_u64)
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    structure = CrystalClick::DynamicStructure.new([qbit, uint64] of CrystalClick::BinaryDataType)
    structures = {"root" => structure}
    rows = [
      [CrystalClick::BinaryValue.dynamic(dynamic, w233_transport_qbit_value(qbit_type, 0x10_u8))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(11_u64))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, w233_transport_qbit_value(qbit_type, 0x20_u8))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, w233_transport_qbit_value(qbit_type, 0x30_u8))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    fixture = W233DynamicPartFixture.new(dynamic, structures, rows)
    begin
      w233_assert_readable_before_corruption!(fixture.part, rows.size.to_u64)
      # Each plane independently remains byte-aligned and agrees with every
      # other plane. Only the complete Dynamic selector census exposes that
      # mark 2's plane count no longer equals its selected direct-QBit count.
      w233_corrupt_direct_qbit_count!(fixture, 2)
      w233_assert_rejected_before_callback!(
        fixture.part, 0_u64, 1, "QBit plane mark differs from its occurrence schedule"
      )
    ensure
      fixture.close
    end
  end

  it "validates the same complete late selector/plane schedule for an empty EOF window" do
    qbit_type = CrystalClick::QBitType.new("Int8", 1_u64)
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    structures = {"root" => CrystalClick::DynamicStructure.new([qbit, uint64] of CrystalClick::BinaryDataType)}
    rows = [
      [CrystalClick::BinaryValue.dynamic(dynamic, w233_transport_qbit_value(qbit_type, 0x10_u8))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(11_u64))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, w233_transport_qbit_value(qbit_type, 0x20_u8))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, w233_transport_qbit_value(qbit_type, 0x30_u8))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    fixture = W233DynamicPartFixture.new(dynamic, structures, rows)
    begin
      w233_assert_readable_before_corruption!(fixture.part, rows.size.to_u64)
      w233_corrupt_direct_qbit_count!(fixture, 2)
      w233_assert_rejected_before_callback!(
        fixture.part, 4_u64, 1, "QBit plane mark differs from its occurrence schedule"
      )
    ensure
      fixture.close
    end
  end

  it "preflights late BASIC Dynamic discriminator deltas before a positive read" do
    qbit_type = CrystalClick::QBitType.new("Int8", 1_u64)
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    structures = {"root" => CrystalClick::DynamicStructure.new([qbit, uint64] of CrystalClick::BinaryDataType)}
    rows = [
      [CrystalClick::BinaryValue.dynamic(dynamic, w233_transport_qbit_value(qbit_type, 0x10_u8))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(11_u64))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, w233_transport_qbit_value(qbit_type, 0x20_u8))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, w233_transport_qbit_value(qbit_type, 0x30_u8))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    fixture = W233DynamicPartFixture.new(dynamic, structures, rows)
    begin
      w233_assert_readable_before_corruption!(fixture.part, rows.size.to_u64)
      role = "root.discriminators"
      w233_bump_mark_start!(fixture, role, 2)
      w233_refresh_part_checksums!(fixture.part)

      source = W233CountingPartStreamSource.new(fixture.part)
      limits = CrystalClick::BinaryCodecLimits.default
      transport_limits = CrystalClick::CompressedStreamLimits.new
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicBulkSiteReader.open(
          source,
          dynamic,
          CrystalClick::PhysicalStreamName.escape("payload"),
          0_u64,
          CrystalClick::BinaryBulkProfile.single_stream,
          limits,
          transport_limits,
          CrystalClick::BinaryCodecBudget.new(limits),
          CrystalClick::CompressedStreamBudget.new(transport_limits),
          expected_total_rows: rows.size.to_u64,
        )
      end
      error.message.not_nil!.should contain("Dynamic discriminator mark differs from its occurrence schedule")
      discriminator_file = fixture.physical.data_file_for(role, true)
      source.window_reads.select do |read|
        read.data_name == discriminator_file && read.mark_count > 0
      end.should be_empty
    ensure
      fixture.close
    end
  end

  it "rejects an invalid late embedded-Variant discriminator before early and EOF callbacks" do
    qbit_type = CrystalClick::QBitType.new("Int8", 1_u64)
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    variant = CrystalClick::BinaryDataType.variant([qbit, uint64] of CrystalClick::BinaryDataType)
    array_variant = CrystalClick::BinaryDataType.array(variant)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    structures = {"root" => CrystalClick::DynamicStructure.new([array_variant, uint64] of CrystalClick::BinaryDataType)}
    qbit_arm = w233_transport_variant_arm_index(variant, qbit)
    rows = [
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array_variant, [
        CrystalClick::BinaryValue.variant(variant, qbit_arm, w233_transport_qbit_value(qbit_type, 0x10_u8)),
      ] of CrystalClick::BinaryValue))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(11_u64))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array_variant, [
        CrystalClick::BinaryValue.variant(variant, qbit_arm, w233_transport_qbit_value(qbit_type, 0x20_u8)),
      ] of CrystalClick::BinaryValue))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array_variant, [
        CrystalClick::BinaryValue.variant(variant, qbit_arm, w233_transport_qbit_value(qbit_type, 0x30_u8)),
      ] of CrystalClick::BinaryValue))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    fixture = W233DynamicPartFixture.new(dynamic, structures, rows)
    begin
      w233_assert_readable_before_corruption!(fixture.part, rows.size.to_u64)
      structure = structures["root"]
      array_arm = structure.canonical_index_for(array_variant)
      role = "root.arm.#{array_arm}.elements.discriminators"
      w233_rewrite_mark_byte!(fixture, role, 2, qbit_arm.to_u8, 0xfe_u8)
      w233_refresh_part_checksums!(fixture.part)
      w233_assert_rejected_before_callback!(
        fixture.part, 0_u64, 1, "selector is outside its arm roster"
      )
      w233_assert_rejected_before_callback!(
        fixture.part, 4_u64, 1, "selector is outside its arm roster"
      )
    ensure
      fixture.close
    end
  end

  it "rejects a late valid embedded-Variant arm change when QBit planes disagree before early and EOF callbacks" do
    qbit_type = CrystalClick::QBitType.new("Int8", 1_u64)
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    variant = CrystalClick::BinaryDataType.variant([qbit, uint64] of CrystalClick::BinaryDataType)
    array_variant = CrystalClick::BinaryDataType.array(variant)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    structures = {"root" => CrystalClick::DynamicStructure.new([array_variant, uint64] of CrystalClick::BinaryDataType)}
    qbit_arm = w233_transport_variant_arm_index(variant, qbit)
    uint64_arm = w233_transport_variant_arm_index(variant, uint64)
    rows = [
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array_variant, [
        CrystalClick::BinaryValue.variant(variant, qbit_arm, w233_transport_qbit_value(qbit_type, 0x10_u8)),
      ] of CrystalClick::BinaryValue))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(11_u64))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array_variant, [
        CrystalClick::BinaryValue.variant(variant, qbit_arm, w233_transport_qbit_value(qbit_type, 0x20_u8)),
      ] of CrystalClick::BinaryValue))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array_variant, [
        CrystalClick::BinaryValue.variant(variant, qbit_arm, w233_transport_qbit_value(qbit_type, 0x30_u8)),
      ] of CrystalClick::BinaryValue))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    fixture = W233DynamicPartFixture.new(dynamic, structures, rows)
    begin
      w233_assert_readable_before_corruption!(fixture.part, rows.size.to_u64)
      structure = structures["root"]
      array_arm = structure.canonical_index_for(array_variant)
      role = "root.arm.#{array_arm}.elements.discriminators"
      # Keep the tag in-range: rejection must come from the QBit occurrence
      # count no longer matching the still-present late plane bytes.
      w233_rewrite_mark_byte!(fixture, role, 2, qbit_arm.to_u8, uint64_arm.to_u8)
      w233_refresh_part_checksums!(fixture.part)
      w233_assert_rejected_before_callback!(
        fixture.part, 0_u64, 1, "QBit plane mark differs from its occurrence schedule"
      )
      w233_assert_rejected_before_callback!(
        fixture.part, 4_u64, 1, "QBit plane mark differs from its occurrence schedule"
      )
    ensure
      fixture.close
    end
  end

  it "rejects a late valid Array size that disagrees with its QBit plane occurrence count" do
    qbit_type = CrystalClick::QBitType.new("Int8", 1_u64)
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    array_qbit = CrystalClick::BinaryDataType.array(qbit)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    structure = CrystalClick::DynamicStructure.new([array_qbit, uint64] of CrystalClick::BinaryDataType)
    structures = {"root" => structure}
    rows = [
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array_qbit, [w233_transport_qbit_value(qbit_type, 0x10_u8)] of CrystalClick::BinaryValue))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(11_u64))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array_qbit, [w233_transport_qbit_value(qbit_type, 0x20_u8)] of CrystalClick::BinaryValue))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array_qbit, [w233_transport_qbit_value(qbit_type, 0x30_u8)] of CrystalClick::BinaryValue))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    fixture = W233DynamicPartFixture.new(dynamic, structures, rows)
    begin
      w233_assert_readable_before_corruption!(fixture.part, rows.size.to_u64)
      array_arm = structure.canonical_index_for(array_qbit)
      # 2 is a valid Array size, but this mark has one QBit in each plane.
      # The full Dynamic/Array occurrence schedule must detect the late
      # disagreement before an unrelated early or empty-EOF callback.
      role = "root.arm.#{array_arm}.sizes"
      w233_rewrite_mark_byte!(fixture, role, 2, 1_u8, 2_u8)
      w233_refresh_part_checksums!(fixture.part)
      w233_assert_rejected_before_callback!(
        fixture.part, 0_u64, 1, "QBit plane mark differs from its occurrence schedule"
      )
      w233_assert_rejected_before_callback!(
        fixture.part, 4_u64, 1, "QBit plane mark differs from its occurrence schedule"
      )
    ensure
      fixture.close
    end
  end

  it "reads each complete Dynamic/Array shape lane once before selecting a value window" do
    qbit_type = CrystalClick::QBitType.new("Int8", 1_u64)
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    array_qbit = CrystalClick::BinaryDataType.array(qbit)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    structure = CrystalClick::DynamicStructure.new([array_qbit, uint64] of CrystalClick::BinaryDataType)
    structures = {"root" => structure}
    rows = [
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array_qbit, [w233_transport_qbit_value(qbit_type, 1_u8)] of CrystalClick::BinaryValue))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(2_u64))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array_qbit, [w233_transport_qbit_value(qbit_type, 3_u8)] of CrystalClick::BinaryValue))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array_qbit, [w233_transport_qbit_value(qbit_type, 4_u8)] of CrystalClick::BinaryValue))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    fixture = W233DynamicPartFixture.new(dynamic, structures, rows)
    begin
      source = W233CountingPartStreamSource.new(fixture.part)
      limits = CrystalClick::BinaryCodecLimits.default
      transport_limits = CrystalClick::CompressedStreamLimits.new
      CrystalClick::DynamicBulkSiteReader.open(
        source,
        dynamic,
        CrystalClick::PhysicalStreamName.escape("payload"),
        0_u64,
        CrystalClick::BinaryBulkProfile.single_stream,
        limits,
        transport_limits,
        CrystalClick::BinaryCodecBudget.new(limits),
        CrystalClick::CompressedStreamBudget.new(transport_limits),
        expected_total_rows: rows.size.to_u64,
      )
      expected_roles = [
        "root.discriminators",
        "root.arm.#{structure.canonical_index_for(array_qbit)}.sizes",
      ]
      expected_files = expected_roles.map { |role| fixture.physical.data_file_for(role, true) }.sort
      actual = source.window_reads.select do |read|
        read.mark_count > 0 && expected_files.includes?(read.data_name)
      end
      actual.map(&.data_name).sort.should eq(expected_files)
      actual.each do |read|
        read.first_mark.should eq(0)
        read.mark_count.should eq(rows.size)
      end
    ensure
      fixture.close
    end
  end

  it "censuses an inner Dynamic roster below an actual Array(Dynamic) arm" do
    qbit_type = CrystalClick::QBitType.new("Int8", 1_u64)
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    inner_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    array_inner_dynamic = CrystalClick::BinaryDataType.array(inner_dynamic)
    outer_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    outer_structure = CrystalClick::DynamicStructure.new(
      [array_inner_dynamic, uint64] of CrystalClick::BinaryDataType,
    )
    outer_array_index = outer_structure.canonical_index_for(array_inner_dynamic)
    inner_site = "root.arm.#{outer_array_index}.elements"
    inner_structure = CrystalClick::DynamicStructure.new([qbit, uint64] of CrystalClick::BinaryDataType)
    inner_qbit_index = inner_structure.canonical_index_for(qbit)
    structures = {
      "root"     => outer_structure,
      inner_site => inner_structure,
    }
    inner_qbit = ->(seed : UInt8) {
      CrystalClick::BinaryValue.dynamic(inner_dynamic, w233_transport_qbit_value(qbit_type, seed))
    }
    inner_number = ->(number : UInt64) {
      CrystalClick::BinaryValue.dynamic(inner_dynamic, CrystalClick::BinaryValue.uint64(number))
    }
    rows = [
      [CrystalClick::BinaryValue.dynamic(
        outer_dynamic,
        CrystalClick::BinaryValue.array(
          array_inner_dynamic,
          [inner_qbit.call(0x10_u8), inner_number.call(11_u64)] of CrystalClick::BinaryValue,
        ),
      )] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(
        outer_dynamic,
        CrystalClick::BinaryValue.array(array_inner_dynamic, [] of CrystalClick::BinaryValue),
      )] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(
        outer_dynamic,
        CrystalClick::BinaryValue.array(array_inner_dynamic, [inner_qbit.call(0x30_u8)] of CrystalClick::BinaryValue),
      )] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(outer_dynamic, CrystalClick::BinaryValue.uint64(40_u64))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    fixture = W233DynamicPartFixture.new(outer_dynamic, structures, rows)
    begin
      inner_qbit_path = "#{inner_site}.arm.#{inner_qbit_index}"
      fixture.plan.qbit_sites.map(&.path).should eq([inner_qbit_path])
      source = W233CountingPartStreamSource.new(fixture.part)
      limits = CrystalClick::BinaryCodecLimits.default
      transport_limits = CrystalClick::CompressedStreamLimits.new
      CrystalClick::DynamicBulkSiteReader.open(
        source,
        outer_dynamic,
        CrystalClick::PhysicalStreamName.escape("payload"),
        0_u64,
        CrystalClick::BinaryBulkProfile.single_stream,
        limits,
        transport_limits,
        CrystalClick::BinaryCodecBudget.new(limits),
        CrystalClick::CompressedStreamBudget.new(transport_limits),
        expected_total_rows: rows.size.to_u64,
      )
      expected_roles = [
        "root.discriminators",
        "root.arm.#{outer_array_index}.sizes",
        "#{inner_site}.discriminators",
      ]
      expected_files = expected_roles.map { |role| fixture.physical.data_file_for(role, true) }.sort
      actual = source.window_reads.select do |read|
        read.mark_count > 0 && expected_files.includes?(read.data_name)
      end
      actual.map(&.data_name).sort.should eq(expected_files)
      actual.each do |read|
        read.first_mark.should eq(0)
        read.mark_count.should eq(rows.size)
      end
    ensure
      fixture.close
    end
  end

  it "accepts the exact occurrence workspace and rejects one byte less before shape reads" do
    qbit_type = CrystalClick::QBitType.new("Int8", 1_u64)
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    array_qbit = CrystalClick::BinaryDataType.array(qbit)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    structure = CrystalClick::DynamicStructure.new([array_qbit, uint64] of CrystalClick::BinaryDataType)
    structures = {"root" => structure}
    rows = Array(Array(CrystalClick::BinaryValue)).new(128) do |index|
      value = if index % 2 == 0
                CrystalClick::BinaryValue.dynamic(
                  dynamic,
                  CrystalClick::BinaryValue.array(array_qbit, [w233_transport_qbit_value(qbit_type, index.to_u8)] of CrystalClick::BinaryValue),
                )
              else
                CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(index.to_u64))
              end
      [value] of CrystalClick::BinaryValue
    end
    fixture = W233DynamicPartFixture.new(dynamic, structures, rows)
    begin
      exact_source = W233CountingPartStreamSource.new(fixture.part)
      exact_limits = CrystalClick::BinaryCodecLimits.new(64, 4_096, 1_000_000, 5_120)
      transport_limits = CrystalClick::CompressedStreamLimits.new
      CrystalClick::DynamicBulkSiteReader.open(
        exact_source,
        dynamic,
        CrystalClick::PhysicalStreamName.escape("payload"),
        0_u64,
        CrystalClick::BinaryBulkProfile.single_stream,
        exact_limits,
        transport_limits,
        CrystalClick::BinaryCodecBudget.new(exact_limits),
        CrystalClick::CompressedStreamBudget.new(transport_limits),
        expected_total_rows: rows.size.to_u64,
      )
      expected_roles = ["root.discriminators", "root.arm.#{structure.canonical_index_for(array_qbit)}.sizes"]
      expected_files = expected_roles.map { |role| fixture.physical.data_file_for(role, true) }.sort
      exact_positive_reads = exact_source.window_reads.select do |read|
        read.mark_count > 0 && expected_files.includes?(read.data_name)
      end
      exact_positive_reads.map(&.data_name).sort.should eq(expected_files)

      short_source = W233CountingPartStreamSource.new(fixture.part)
      short_limits = CrystalClick::BinaryCodecLimits.new(64, 4_096, 1_000_000, 5_119)
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicBulkSiteReader.open(
          short_source,
          dynamic,
          CrystalClick::PhysicalStreamName.escape("payload"),
          0_u64,
          CrystalClick::BinaryBulkProfile.single_stream,
          short_limits,
          transport_limits,
          CrystalClick::BinaryCodecBudget.new(short_limits),
          CrystalClick::CompressedStreamBudget.new(transport_limits),
          expected_total_rows: rows.size.to_u64,
        )
      end
      error.message.not_nil!.should contain("workspace")
      error.message.not_nil!.should contain("occurrence")
      error.message.not_nil!.should contain("5120")
      short_source.window_reads.select { |read| read.mark_count > 0 }.should be_empty
    ensure
      fixture.close
    end
  end
end
