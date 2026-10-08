require "./spec_helper"
require "file_utils"

private def w230_parts_try_array_type(child : CrystalClick::BinaryDataType) : CrystalClick::BinaryDataType?
  CrystalClick::BinaryDataType.array(child)
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w230_parts_qbit_value(type : CrystalClick::QBitType, seed : UInt8) : CrystalClick::BinaryValue
  raw = Bytes.new(type.raw_row_bytes) { |index| (seed.to_i + index).to_u8 }
  CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(type, raw))
end

private def w230_parts_array_value(
  type : CrystalClick::BinaryDataType,
  children : Array(CrystalClick::BinaryValue),
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.array(type, children)
end

private def w230_parts_array_rows(
  type : CrystalClick::BinaryDataType,
  qbit_type : CrystalClick::QBitType,
) : Array(Array(CrystalClick::BinaryValue))
  first = w230_parts_qbit_value(qbit_type, 0x10_u8)
  second = w230_parts_qbit_value(qbit_type, 0x40_u8)
  third = w230_parts_qbit_value(qbit_type, 0x80_u8)
  empty = w230_parts_array_value(type, [] of CrystalClick::BinaryValue)
  [
    [w230_parts_array_value(type, [first, second] of CrystalClick::BinaryValue), empty] of CrystalClick::BinaryValue,
    [empty, empty] of CrystalClick::BinaryValue,
    [w230_parts_array_value(type, [third] of CrystalClick::BinaryValue),
     w230_parts_array_value(type, [first, second] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
  ] of Array(CrystalClick::BinaryValue)
end

private def w230_parts_array_array_rows(
  outer_type : CrystalClick::BinaryDataType,
  inner_type : CrystalClick::BinaryDataType,
  qbit_type : CrystalClick::QBitType,
) : Array(Array(CrystalClick::BinaryValue))
  first = w230_parts_qbit_value(qbit_type, 0x10_u8)
  second = w230_parts_qbit_value(qbit_type, 0x40_u8)
  third = w230_parts_qbit_value(qbit_type, 0x80_u8)
  empty_inner = w230_parts_array_value(inner_type, [] of CrystalClick::BinaryValue)
  two = w230_parts_array_value(inner_type, [first, second] of CrystalClick::BinaryValue)
  one = w230_parts_array_value(inner_type, [third] of CrystalClick::BinaryValue)
  empty_outer = w230_parts_array_value(outer_type, [] of CrystalClick::BinaryValue)
  [
    [w230_parts_array_value(outer_type, [two, empty_inner] of CrystalClick::BinaryValue), empty_outer] of CrystalClick::BinaryValue,
    [w230_parts_array_value(outer_type, [empty_inner] of CrystalClick::BinaryValue), empty_outer] of CrystalClick::BinaryValue,
    [w230_parts_array_value(outer_type, [one, two] of CrystalClick::BinaryValue), empty_outer] of CrystalClick::BinaryValue,
  ] of Array(CrystalClick::BinaryValue)
end

private def w230_parts_candidate(path : String) : CrystalClick::OfflinePartCandidate
  info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
  CrystalClick::OfflinePartCandidate.new("all_1_1_0", path, info, 6_u64)
end

private def w230_parts_write_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w230_parts_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w230_parts_encode_lz4_frame(raw : Bytes) : Bytes
  raise ArgumentError.new("cannot encode an empty LZ4 block") if raw.empty?
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
  hash = CrystalClick::CityHashV1.hash128(
    frame[CrystalClick::CompressedBlock::CHECKSUM_SIZE, compressed_size]
  )
  w230_parts_write_u64_at(frame, 0, hash[0])
  w230_parts_write_u64_at(frame, 8, hash[1])
  frame
end

private def w230_parts_write_u64_at(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w230_parts_read_u64(bytes : Bytes, offset : Int) : UInt64
  raise ArgumentError.new("W230 mark coordinate is truncated") if offset < 0 || offset > bytes.size - 8
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w230_parts_rewrite_plane_with_unaligned_frame_marks!(
  part : String,
  physical : CrystalClick::BinaryBulkPhysicalPlan,
  role : String,
) : Nil
  data_path = File.join(part, physical.data_file_for(role, true))
  marks_path = File.join(part, physical.marks_file_for(role, true))
  original_data = File.read(data_path).to_slice
  raw = CrystalClick::CompressedBlock.decode_all(original_data)
  raw.size.should eq(15)

  # This plane has five QBit occurrences at three bytes each. Split its 15
  # raw bytes after byte zero so mark positions 6 and 15 become offsets 5
  # and 14 in the second literal LZ4 frame.
  first_frame = w230_parts_encode_lz4_frame(raw[0, 1])
  second_frame = w230_parts_encode_lz4_frame(raw[1, 14])
  replacement = Bytes.new(first_frame.size + second_frame.size)
  first_frame.copy_to(replacement[0, first_frame.size])
  second_frame.copy_to(replacement[first_frame.size, second_frame.size])
  File.write(data_path, replacement)

  marks = File.read(marks_path).to_slice.dup
  marks.size.should eq(4 * CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE)
  expected_rows = [2_u64, 2_u64, 2_u64, 0_u64]
  expected_rows.each_with_index do |rows, index|
    record_offset = index * CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE
    w230_parts_read_u64(marks, record_offset + 16).should eq(rows)
  end
  frame_two_offset = first_frame.size.to_u64
  coordinates = [
    {0_u64, 0_u64},
    {frame_two_offset, 5_u64},
    {frame_two_offset, 5_u64},
    {frame_two_offset, 14_u64},
  ]
  coordinates.each_with_index do |coordinate, index|
    record_offset = index * CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE
    w230_parts_write_u64_at(marks, record_offset, coordinate[0])
    w230_parts_write_u64_at(marks, record_offset + 8, coordinate[1])
    w230_parts_read_u64(marks, record_offset).should eq(coordinate[0])
    w230_parts_read_u64(marks, record_offset + 8).should eq(coordinate[1])
  end
  File.write(marks_path, marks)
  w230_parts_refresh_checksums(part)

  rewritten_marks = File.read(marks_path).to_slice
  coordinates.each_with_index do |coordinate, index|
    record_offset = index * CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE
    w230_parts_read_u64(rewritten_marks, record_offset).should eq(coordinate[0])
    w230_parts_read_u64(rewritten_marks, record_offset + 8).should eq(coordinate[1])
  end
  rewritten = File.read(data_path).to_slice
  CrystalClick::CompressedBlock.decode_all(rewritten).should eq(raw)
  first = CrystalClick::CompressedBlock.decode_frame(rewritten, 0_i64)
  first.output.should eq(raw[0, 1])
  first.end_offset.should eq(first_frame.size.to_i64)
  second = CrystalClick::CompressedBlock.decode_frame(rewritten, first.end_offset)
  second.output.should eq(raw[1, 14])
  second.end_offset.should eq(rewritten.size.to_i64)
  (5_u64 % 3_u64).should_not eq(0_u64)

  grid = CrystalClick::CompressedMarkReader.inspect(
    data_path,
    marks_path,
    File.size(data_path),
    File.size(marks_path),
  )
  grid.positions.should eq([0_i64, 6_i64, 6_i64, 15_i64])
  grid.rows_per_mark.should eq([2_u64, 2_u64, 2_u64])
end

private def w230_parts_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w230_parts_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w230_parts_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w230_parts_write_varuint(payload, file_bytes.size.to_u64)
    hash = CrystalClick::CityHashV1.file_hash(file_bytes)
    w230_parts_write_u64(payload, hash[0])
    w230_parts_write_u64(payload, hash[1])
    if entry.compressed
      raw = file_bytes.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w230_parts_write_varuint(payload, raw.size.to_u64)
      raw_hash = CrystalClick::CityHashV1.file_hash(raw)
      w230_parts_write_u64(payload, raw_hash[0])
      w230_parts_write_u64(payload, raw_hash[1])
    else
      payload.write_byte(0_u8)
    end
  end
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(w230_parts_encode_lz4_frame(payload.to_slice))
  end
end

private def w230_parts_corrupt_mark_byte!(
  part : String,
  data_name : String,
  marks_name : String,
  mark_index : Int,
  raw_offset : Int,
  value : UInt8,
) : Nil
  marks = File.read(File.join(part, marks_name)).to_slice
  mark_offset = mark_index * CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE
  compressed_offset = 0_u64
  decompressed_offset = 0_u64
  8.times do |index|
    compressed_offset |= marks[mark_offset + index].to_u64 << (index * 8)
    decompressed_offset |= marks[mark_offset + 8 + index].to_u64 << (index * 8)
  end

  data_path = File.join(part, data_name)
  data = File.read(data_path).to_slice.dup
  frame = CrystalClick::CompressedBlock.decode_frame(data, compressed_offset.to_i64)
  raw = frame.output.dup
  raw_offset.should be >= 0
  decompressed_offset.should be <= raw.size.to_u64
  remaining = raw.size.to_u64 - decompressed_offset
  raw_offset.to_u64.should be < remaining
  target_offset = decompressed_offset.to_i + raw_offset
  raw[target_offset].should_not eq(value)
  raw[target_offset] = value
  replacement = w230_parts_encode_lz4_frame(raw)
  replacement.size.should eq((frame.end_offset - compressed_offset.to_i64).to_i)
  replacement.copy_to(data[compressed_offset.to_i, replacement.size])
  File.write(data_path, data)
  w230_parts_refresh_checksums(part)
end

describe "W230 recursive QBit complete-part and typed consumers" do
  it "accepts non-plane-aligned frame-relative marks across ragged QBit children" do
    qbit_type = CrystalClick::QBitType.new("Int8", 17_u64)
    qbit_type.plane_width.should eq(3)
    qbit_descriptor = CrystalClick::BinaryDataType.qbit(qbit_type)
    array_candidate = w230_parts_try_array_type(qbit_descriptor)
    array_candidate.should_not be_nil
    writer = CrystalClick::WidePartWriter
    writer.responds_to?(:write_uint64_qbit_bulk_part).should be_true

    if array_type = array_candidate
      if writer.responds_to?(:write_uint64_qbit_bulk_part)
        granules = w230_parts_array_rows(array_type, qbit_type)
        expected = granules.flatten
        parent = File.tempname("crystal-click-w230-qbit-unaligned-frame-mark-")
        Dir.mkdir(parent)
        part = File.join(parent, "all_1_1_0")
        begin
          writer.write_uint64_qbit_bulk_part(
            part,
            "k",
            Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64, 66_u64],
            "v",
            array_type,
            granules,
            rows_per_mark: 2,
          )
          physical_plan = CrystalClick::BinaryBulkPhysicalPlan.new(
            array_type, "v", CrystalClick::BinaryBulkProfile.single_stream
          )
          role = "root.elements.qbit_plane.0"
          data_path = File.join(part, physical_plan.data_file_for(role, true))
          marks_path = File.join(part, physical_plan.marks_file_for(role, true))
          before = CrystalClick::CompressedMarkReader.inspect(
            data_path,
            marks_path,
            File.size(data_path),
            File.size(marks_path),
          )
          before.positions.should eq([0_i64, 6_i64, 6_i64, 15_i64])
          before.rows_per_mark.should eq([2_u64, 2_u64, 2_u64])

          w230_parts_rewrite_plane_with_unaligned_frame_marks!(part, physical_plan, role)
          mark_bytes = File.read(marks_path).to_slice
          persisted_rows = (0..3).map do |index|
            w230_parts_read_u64(mark_bytes, index * CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE + 16)
          end
          persisted_rows.should eq([2_u64, 2_u64, 2_u64, 0_u64])

          table = CrystalClick::WidePartTable.open_selected_typed([part], ["v"])
          table.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64]])
          full = [] of CrystalClick::BinaryValue
          table.scan_typed do |batch|
            full.concat(batch.binary_bulk_values_for("v").to_a)
          end
          full.should eq(expected)

          middle = [] of CrystalClick::BinaryValue
          table.scan_typed_window(1_u64, 4) do |batch|
            middle.concat(batch.binary_bulk_values_for("v").to_a)
          end
          middle.should eq(expected[1, 4])

          eof_callbacks = 0
          table.scan_typed_window(6_u64, 2) { |_batch| eof_callbacks += 1 }
          eof_callbacks.should eq(0)
        ensure
          FileUtils.rm_rf(parent)
        end
      end
    end
  end

  it "publishes and reads Array(Nullable(QBit)) through the static QBit bulk writer" do
    qbit_type = CrystalClick::QBitType.new("Int8", 9_u64)
    qbit_descriptor = CrystalClick::BinaryDataType.qbit(qbit_type)
    nullable_type = CrystalClick::BinaryDataType.nullable(qbit_descriptor)
    array_candidate = w230_parts_try_array_type(nullable_type)
    array_candidate.should_not be_nil
    writer = CrystalClick::WidePartWriter
    writer.responds_to?(:write_uint64_qbit_bulk_part).should be_true

    if array_type = array_candidate
      if writer.responds_to?(:write_uint64_qbit_bulk_part)
        nullable_values = [
          CrystalClick::BinaryValue.nullable(nullable_type, w230_parts_qbit_value(qbit_type, 0x10_u8)),
          CrystalClick::BinaryValue.nullable(nullable_type),
          CrystalClick::BinaryValue.nullable(nullable_type, w230_parts_qbit_value(qbit_type, 0x40_u8)),
        ] of CrystalClick::BinaryValue
        empty = w230_parts_array_value(array_type, [] of CrystalClick::BinaryValue)
        marks = [
          [w230_parts_array_value(array_type, nullable_values[0, 2]), empty] of CrystalClick::BinaryValue,
          [empty, empty] of CrystalClick::BinaryValue,
          [w230_parts_array_value(array_type, [nullable_values[2]] of CrystalClick::BinaryValue),
           w230_parts_array_value(array_type, [nullable_values[1], nullable_values[0]] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
        ] of Array(CrystalClick::BinaryValue)
        keys = [11_u64, 22_u64, 33_u64, 44_u64, 55_u64, 66_u64]
        scratch = File.tempname("crystal-click-w230-qbit-part-")
        Dir.mkdir(scratch)
        part_path = File.join(scratch, "all_1_1_0")
        begin
          writer.write_uint64_qbit_bulk_part(
            part_path,
            "k",
            keys.to_unsafe.to_slice(keys.size),
            "v",
            array_type,
            marks,
            rows_per_mark: 2,
          )

          CrystalClick::WidePart.supports_typed_type?(array_type.name).should be_true
          physical = CrystalClick::WidePartTable.open_selected_typed([part_path], ["v"])
          physical.column_types.should eq([{"v", array_type.name}])
          full = [] of CrystalClick::BinaryValue
          physical.scan_typed(batch_rows: 3) do |batch|
            full.concat(batch.binary_bulk_values_for("v").to_a)
          end
          full.should eq(marks.flatten)

          window = [] of CrystalClick::BinaryValue
          physical.scan_typed_window(1_u64, 4) do |batch|
            # Copy borrowed values before leaving their callback.
            window.concat(batch.binary_bulk_values_for("v").to_a)
          end
          window.should eq(marks.flatten[1, 4])
          eof_callbacks = 0
          physical.scan_typed_window(6_u64, 2) { |_batch| eof_callbacks += 1 }
          eof_callbacks.should eq(0)
          expect_raises(CrystalClick::BoundsError) do
            physical.scan_typed_window(7_u64, 1) { |_batch| }
          end

          offline = CrystalClick::OfflineTable.new(
            "events",
            "w230-recursive-qbit",
            "MergeTree",
            [
              CrystalClick::OfflineColumn.new("k", "UInt64"),
              CrystalClick::OfflineColumn.new("v", array_type.name),
            ] of CrystalClick::OfflineColumn,
            [w230_parts_candidate(part_path)] of CrystalClick::OfflinePartCandidate,
          )
          owned = offline["v"].values(max_rows: 6_u64).map(&.as(CrystalClick::BinaryValue))
          owned.should eq(marks.flatten)
          owned[0].element_at(1).is_null?.should be_true
          owned[4].element_at(0).is_null?.should be_false
          owned[5].element_at(0).is_null?.should be_true
          owned[5].element_at(1).is_null?.should be_false
        ensure
          FileUtils.rm_rf(scratch)
        end
      end
    end
  end

  it "preserves a wholly empty Array(QBit) plane as a zero-byte child stream" do
    qbit_type = CrystalClick::QBitType.new("Int8", 9_u64)
    qbit_descriptor = CrystalClick::BinaryDataType.qbit(qbit_type)
    array_candidate = w230_parts_try_array_type(qbit_descriptor)
    array_candidate.should_not be_nil
    writer = CrystalClick::WidePartWriter
    writer.responds_to?(:write_uint64_qbit_bulk_part).should be_true

    if array_type = array_candidate
      if writer.responds_to?(:write_uint64_qbit_bulk_part)
        empty = w230_parts_array_value(array_type, [] of CrystalClick::BinaryValue)
        marks = [
          [empty, empty] of CrystalClick::BinaryValue,
          [empty, empty] of CrystalClick::BinaryValue,
        ] of Array(CrystalClick::BinaryValue)
        parent = File.tempname("crystal-click-w230-qbit-empty-child-")
        Dir.mkdir(parent)
        part = File.join(parent, "all_1_1_0")
        begin
          writer.write_uint64_qbit_bulk_part(
            part,
            "k",
            Slice[11_u64, 22_u64, 33_u64, 44_u64],
            "v",
            array_type,
            marks,
            rows_per_mark: 2,
          )
          physical = CrystalClick::BinaryBulkPhysicalPlan.new(
            array_type, "v", CrystalClick::BinaryBulkProfile.single_stream
          )
          plane_data = File.join(part, physical.data_file_for("root.elements.qbit_plane.0", true))
          File.size(plane_data).should eq(0_i64)

          table = CrystalClick::WidePartTable.open_selected_typed([part], ["v"])
          read = [] of CrystalClick::BinaryValue
          table.scan_typed do |batch|
            read.concat(batch.binary_bulk_values_for("v").to_a)
          end
          read.should eq(marks.flatten)
          read.each { |value| value.element_count.should eq(0) }
        ensure
          FileUtils.rm_rf(parent)
        end
      end
    end
  end

  it "keeps two Array size axes distinct from the flattened QBit leaf schedule" do
    qbit_type = CrystalClick::QBitType.new("BFloat16", 9_u64)
    qbit_descriptor = CrystalClick::BinaryDataType.qbit(qbit_type)
    inner_candidate = w230_parts_try_array_type(qbit_descriptor)
    inner_candidate.should_not be_nil
    if inner_type = inner_candidate
      outer_candidate = w230_parts_try_array_type(inner_type)
      outer_candidate.should_not be_nil
      if outer_type = outer_candidate
        rows = w230_parts_array_array_rows(outer_type, inner_type, qbit_type)
        streams = CrystalClick::BinaryBulkCodec.encode(outer_type, rows)
        streams.roles.any? { |role| role.ends_with?("root.sizes") }.should be_true
        streams.roles.any? { |role| role.ends_with?("elements.sizes") }.should be_true
        streams.roles.any? { |role| role.ends_with?("qbit_plane.0") }.should be_true
        decoded = CrystalClick::BinaryBulkCodec.decode(outer_type, streams, [2_u64, 2_u64, 2_u64])
        decoded.should eq(rows)
        decoded[0][0].element_at(0).element_count.should eq(2)
        decoded[0][0].element_at(1).element_count.should eq(0)
        decoded[1][0].element_at(0).element_count.should eq(0)
        decoded[2][0].element_at(1).element_count.should eq(2)
      end
    end
  end

  it "rejects a checksummed late Array-size mismatch before first-window and EOF callbacks" do
    qbit_type = CrystalClick::QBitType.new("Int8", 9_u64)
    qbit_descriptor = CrystalClick::BinaryDataType.qbit(qbit_type)
    nullable_type = CrystalClick::BinaryDataType.nullable(qbit_descriptor)
    array_candidate = w230_parts_try_array_type(nullable_type)
    array_candidate.should_not be_nil
    writer = CrystalClick::WidePartWriter
    writer.responds_to?(:write_uint64_qbit_bulk_part).should be_true

    if array_type = array_candidate
      if writer.responds_to?(:write_uint64_qbit_bulk_part)
        present = CrystalClick::BinaryValue.nullable(
          nullable_type,
          w230_parts_qbit_value(qbit_type, 0x20_u8),
        )
        absent = CrystalClick::BinaryValue.nullable(nullable_type)
        rows = [
          [w230_parts_array_value(array_type, [present, absent] of CrystalClick::BinaryValue),
           w230_parts_array_value(array_type, [] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
          [w230_parts_array_value(array_type, [] of CrystalClick::BinaryValue),
           w230_parts_array_value(array_type, [] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
          [w230_parts_array_value(array_type, [present] of CrystalClick::BinaryValue),
           w230_parts_array_value(array_type, [absent, present] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
        ] of Array(CrystalClick::BinaryValue)
        parent = File.tempname("crystal-click-w230-qbit-late-shape-")
        Dir.mkdir(parent)
        part = File.join(parent, "all_1_1_0")
        begin
          writer.write_uint64_qbit_bulk_part(
            part,
            "k",
            Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64, 66_u64],
            "v",
            array_type,
            rows,
            rows_per_mark: 2,
          )
          physical = CrystalClick::BinaryBulkPhysicalPlan.new(
            array_type, "v", CrystalClick::BinaryBulkProfile.single_stream
          )
          # Keep the compressed frame and v4 part checksums internally valid,
          # but change row four's late outer Array size from one to two. The
          # resulting derived leaf schedule disagrees with its three QBit/null
          # plane rows; a read of mark zero must still reject the whole shape.
          size_data_name = physical.data_file_for("root.sizes", true)
          size_marks_name = physical.marks_file_for("root.sizes", true)
          size_path = File.join(part, size_data_name)
          sizes_before = CrystalClick::CompressedBlock.decode_all(File.read(size_path).to_slice)
          sizes_before.size.should eq(48)
          sizes_before_values = Array(UInt64).new(6) do |index|
            w230_parts_read_u64(sizes_before, index * 8)
          end
          sizes_before_values.should eq([2_u64, 0, 0, 0, 1, 2])
          sizes_before_values[4].should eq(1_u64)

          w230_parts_corrupt_mark_byte!(
            part,
            size_data_name,
            size_marks_name,
            2,
            0,
            2_u8,
          )

          sizes_after = CrystalClick::CompressedBlock.decode_all(File.read(size_path).to_slice)
          sizes_after.size.should eq(48)
          sizes_after_values = Array(UInt64).new(6) do |index|
            w230_parts_read_u64(sizes_after, index * 8)
          end
          sizes_after_values.should eq([2_u64, 0, 0, 0, 2, 2])
          sizes_after_values[4].should eq(2_u64)
          4.times do |index|
            sizes_after_values[index].should eq(sizes_before_values[index])
          end

          [
            {0_u64, 1},
            {6_u64, 1},
          ].each do |first_row, max_rows|
            callbacks = 0
            expect_raises(CrystalClick::CorruptPartError) do
              table = CrystalClick::WidePartTable.open_selected_typed([part], ["v"])
              table.scan_typed_window(first_row, max_rows) { |_batch| callbacks += 1 }
            end
            callbacks.should eq(0)
          end
        ensure
          FileUtils.rm_rf(parent)
        end
      end
    end
  end

  it "keeps legacy owners, admits static products, and refuses unrelated wrappers" do
    qbit = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Float32", 9_u64))
    CrystalClick::WidePart.supports_typed_type?(qbit.name).should be_true
    CrystalClick::WidePart.supports_typed_type?("Nullable(#{qbit.name})").should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(#{qbit.name})").should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(Array(#{qbit.name}))").should be_true
    CrystalClick::WidePart.supports_typed_type?("Tuple(#{qbit.name})").should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(Tuple(#{qbit.name}))").should be_true
    CrystalClick::WidePart.supports_typed_type?("Map(UInt8, #{qbit.name})").should be_true
    CrystalClick::WidePart.supports_typed_type?("Nested(embedding #{qbit.name})").should be_true
    CrystalClick::WidePart.supports_typed_type?("Nullable(Tuple(#{qbit.name}))").should be_true
    CrystalClick::WidePart.supports_typed_type?("Nullable(Array(#{qbit.name}))").should be_false

    dynamic = CrystalClick::BinaryDataType.dynamic
    array_candidate = w230_parts_try_array_type(qbit)
    if array_type = array_candidate
      value = w230_parts_array_value(array_type, [] of CrystalClick::BinaryValue)
      expect_raises(ArgumentError) do
        CrystalClick::BinaryValue.dynamic(dynamic, value)
      end
    end
  end
end
