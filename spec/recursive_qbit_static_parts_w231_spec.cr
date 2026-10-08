require "./spec_helper"
require "file_utils"

private def w231_try_type(&block : -> CrystalClick::BinaryDataType?) : CrystalClick::BinaryDataType?
  yield
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w231_try_array_type(child : CrystalClick::BinaryDataType) : CrystalClick::BinaryDataType?
  CrystalClick::BinaryDataType.array(child)
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w231_try_tuple_type(
  children : Array(CrystalClick::BinaryDataType),
  names : Array(String)? = nil,
) : CrystalClick::BinaryDataType?
  CrystalClick::BinaryDataType.tuple(children, names)
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w231_try_nested_type(
  children : Array(CrystalClick::BinaryDataType),
  names : Array(String),
) : CrystalClick::BinaryDataType?
  CrystalClick::BinaryDataType.nested(children, names)
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w231_try_map_type(
  key : CrystalClick::BinaryDataType,
  value : CrystalClick::BinaryDataType,
) : CrystalClick::BinaryDataType?
  CrystalClick::BinaryDataType.map(key, value)
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w231_try_nullable_type(child : CrystalClick::BinaryDataType) : CrystalClick::BinaryDataType?
  CrystalClick::BinaryDataType.nullable(child)
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w231_qbit_value(type : CrystalClick::QBitType, seed : UInt8) : CrystalClick::BinaryValue
  raw = Bytes.new(type.raw_row_bytes) { |index| (seed.to_i + index).to_u8 }
  CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(type, raw))
end

private def w231_qbit_array_value(
  array_type : CrystalClick::BinaryDataType,
  qbit_type : CrystalClick::QBitType,
  seeds : Array(UInt8),
) : CrystalClick::BinaryValue
  elements = [] of CrystalClick::BinaryValue
  seeds.each { |seed| elements << w231_qbit_value(qbit_type, seed) }
  CrystalClick::BinaryValue.array(array_type, elements)
end

private def w231_qbit_seeds(row : Int, count : Int, base : UInt8) : Array(UInt8)
  Array(UInt8).new(count) do |index|
    (base.to_i + row * 17 + index * 3).to_u8
  end
end

private def w231_try_write_part(
  part : String,
  type : CrystalClick::BinaryDataType,
  rows_by_mark : Array(Array(CrystalClick::BinaryValue)),
) : Bool
  CrystalClick::WidePartWriter.write_uint64_qbit_bulk_part(
    part,
    "k",
    Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64, 66_u64],
    "v",
    type,
    rows_by_mark,
    rows_per_mark: 2,
  )
  true
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  false
end

private def w231_part_candidate(path : String) : CrystalClick::OfflinePartCandidate
  info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
  CrystalClick::OfflinePartCandidate.new("all_1_1_0", path, info, 6_u64)
end

private def w231_assert_part_consumers!(
  type : CrystalClick::BinaryDataType,
  rows_by_mark : Array(Array(CrystalClick::BinaryValue)),
) : Nil
  expected = rows_by_mark.flatten
  scratch = File.tempname("crystal-click-w231-static-qbit-")
  Dir.mkdir(scratch)
  part = File.join(scratch, "all_1_1_0")
  begin
    write_ok = w231_try_write_part(part, type, rows_by_mark)
    write_ok.should be_true
    if write_ok
      typed = CrystalClick::WidePartTable.open_selected_typed([part], ["v"])
      typed.column_types.should eq([{"v", type.name}])
      typed.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64]])

      full = [] of CrystalClick::BinaryValue
      typed.scan_typed(batch_rows: 1) do |batch|
        full.concat(batch.binary_bulk_values_for("v").to_a)
      end
      full.should eq(expected)

      middle = [] of CrystalClick::BinaryValue
      typed.scan_typed_window(1_u64, 4) do |batch|
        # Copy borrowed values before the next callback.
        middle.concat(batch.binary_bulk_values_for("v").to_a)
      end
      middle.should eq(expected[1, 4])

      empty_callbacks = 0
      typed.scan_typed_window(6_u64, 1) { |_batch| empty_callbacks += 1 }
      empty_callbacks.should eq(0)

      offline = CrystalClick::OfflineTable.new(
        "events",
        "w231-static-qbit",
        "MergeTree",
        [
          CrystalClick::OfflineColumn.new("k", "UInt64"),
          CrystalClick::OfflineColumn.new("v", type.name),
        ] of CrystalClick::OfflineColumn,
        [w231_part_candidate(part)] of CrystalClick::OfflinePartCandidate,
      )
      owned = offline["v"].values(max_rows: 6_u64).map(&.as(CrystalClick::BinaryValue))
      owned.should eq(expected)
    end
  ensure
    FileUtils.rm_rf(scratch)
  end
end

private def w231_write_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w231_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w231_write_u64_at(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w231_read_u64(bytes : Bytes, offset : Int) : UInt64
  raise ArgumentError.new("W231 UInt64 field is truncated") if offset < 0 || offset > bytes.size - 8
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w231_encode_literal_lz4_frame(raw : Bytes) : Bytes
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
  w231_write_u64_at(frame, 0, hash[0])
  w231_write_u64_at(frame, 8, hash[1])
  frame
end

private def w231_refresh_part_checksums!(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w231_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w231_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w231_write_varuint(payload, file_bytes.size.to_u64)
    hash = CrystalClick::CityHashV1.file_hash(file_bytes)
    w231_write_u64(payload, hash[0])
    w231_write_u64(payload, hash[1])
    if entry.compressed
      raw = file_bytes.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w231_write_varuint(payload, raw.size.to_u64)
      raw_hash = CrystalClick::CityHashV1.file_hash(raw)
      w231_write_u64(payload, raw_hash[0])
      w231_write_u64(payload, raw_hash[1])
    else
      payload.write_byte(0_u8)
    end
  end
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(w231_encode_literal_lz4_frame(payload.to_slice))
  end
end

private def w231_corrupt_late_mark_byte!(
  part : String,
  data_name : String,
  marks_name : String,
  mark_index : Int,
  value : UInt8,
) : Nil
  marks = File.read(File.join(part, marks_name)).to_slice
  mark_offset = mark_index * CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE
  compressed_offset = w231_read_u64(marks, mark_offset)
  decompressed_offset = w231_read_u64(marks, mark_offset + 8)

  data_path = File.join(part, data_name)
  data = File.read(data_path).to_slice.dup
  frame = CrystalClick::CompressedBlock.decode_frame(data, compressed_offset.to_i64)
  raw = frame.output.dup
  decompressed_offset.should be <= raw.size.to_u64
  decompressed_offset.should be < raw.size.to_u64
  target = decompressed_offset.to_i
  raw[target].should_not eq(value)
  raw[target] = value
  replacement = w231_encode_literal_lz4_frame(raw)
  replacement.size.should eq((frame.end_offset - compressed_offset.to_i64).to_i)
  replacement.copy_to(data[compressed_offset.to_i, replacement.size])
  File.write(data_path, data)
  w231_refresh_part_checksums!(part)
end

private def w231_corrupt_late_mark_delta!(
  part : String,
  data_name : String,
  marks_name : String,
  mark_index : Int,
) : Nil
  marks_path = File.join(part, marks_name)
  checksums = CrystalClick::PartChecksums.open(part)
  marks_entry = checksums.entry(marks_name) || raise CrystalClick::CorruptPartError.new("W231 mark checksum entry is missing")
  marks_entry.compressed.should be_false

  before_source = CrystalClick::PartStreamSource.new(part)
  before_grid = before_source.inspect_grid(
    data_name,
    marks_name,
    0,
  )
  before_positions = before_grid.positions
  before_positions.should eq([0_i64, 2_i64, 4_i64, 6_i64])

  marks = File.read(marks_path).to_slice.dup
  record_offset = mark_index * CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE
  compressed_offset = w231_read_u64(marks, record_offset)
  old_decompressed_offset = w231_read_u64(marks, record_offset + 8)
  data = File.read(File.join(part, data_name)).to_slice
  frame = CrystalClick::CompressedBlock.decode_frame(data, compressed_offset.to_i64)
  old_decompressed_offset.should be < frame.output.size.to_u64
  new_decompressed_offset = old_decompressed_offset + 1_u64
  new_decompressed_offset.should be < frame.output.size.to_u64
  w231_write_u64_at(marks, record_offset + 8, new_decompressed_offset)
  File.write(marks_path, marks)
  w231_refresh_part_checksums!(part)

  after_source = CrystalClick::PartStreamSource.new(part)
  after_grid = after_source.inspect_grid(data_name, marks_name, 0)
  after_grid.positions.should eq([0_i64, 2_i64, 5_i64, 6_i64])
  after_grid.rows_per_mark.should eq([2_u64, 2_u64, 2_u64])
end

describe "W231 recursive static QBit complete-part consumers" do
  it "binds sibling Array planes independently from a direct no-Array QBit site" do
    direct_qbit = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("BFloat16", 9_u64))
    left_qbit = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 9_u64))
    right_qbit = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Float32", 9_u64))
    left_array = w231_try_array_type(left_qbit)
    right_array = w231_try_array_type(right_qbit)
    left_array.should_not be_nil
    right_array.should_not be_nil

    if left = left_array
      if right = right_array
        tuple_candidate = w231_try_tuple_type([direct_qbit, left, right] of CrystalClick::BinaryDataType)
        tuple_candidate.should_not be_nil
        if tuple_type = tuple_candidate
          rows = [] of CrystalClick::BinaryValue
          left_counts = [2, 0, 0, 1, 3, 0]
          right_counts = [0, 3, 1, 0, 0, 2]
          6.times do |row|
            rows << CrystalClick::BinaryValue.tuple(
              tuple_type,
              [
                w231_qbit_value(CrystalClick::QBitType.new("BFloat16", 9_u64), (0x10 + row).to_u8),
                w231_qbit_array_value(left, CrystalClick::QBitType.new("Int8", 9_u64), w231_qbit_seeds(row, left_counts[row], 0x30_u8)),
                w231_qbit_array_value(right, CrystalClick::QBitType.new("Float32", 9_u64), w231_qbit_seeds(row, right_counts[row], 0x70_u8)),
              ] of CrystalClick::BinaryValue,
            )
          end
          rows_by_mark = [rows[0, 2], rows[2, 2], rows[4, 2]] of Array(CrystalClick::BinaryValue)
          w231_assert_part_consumers!(tuple_type, rows_by_mark)
        end
      end
    end
  end

  it "preserves an Array(Tuple) shared occurrence axis with an independent nested Array axis" do
    qbit_type = CrystalClick::QBitType.new("Int8", 9_u64)
    child_qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    child_array = w231_try_array_type(child_qbit)
    child_array.should_not be_nil
    if array = child_array
      tuple_candidate = w231_try_tuple_type([child_qbit, array] of CrystalClick::BinaryDataType)
      tuple_candidate.should_not be_nil
      if record_type = tuple_candidate
        outer_candidate = w231_try_array_type(record_type)
        outer_candidate.should_not be_nil
        if outer = outer_candidate
          rows = [] of CrystalClick::BinaryValue
          outer_counts = [2, 0, 1, 3, 0, 1]
          6.times do |row|
            records = [] of CrystalClick::BinaryValue
            outer_counts[row].times do |record|
              records << CrystalClick::BinaryValue.tuple(
                record_type,
                [
                  w231_qbit_value(qbit_type, (0x10 + row * 5 + record).to_u8),
                  w231_qbit_array_value(array, qbit_type, w231_qbit_seeds(row + record, (row + record) % 3, 0x40_u8)),
                ] of CrystalClick::BinaryValue,
              )
            end
            rows << CrystalClick::BinaryValue.array(outer, records)
          end
          rows_by_mark = [rows[0, 2], rows[2, 2], rows[4, 2]] of Array(CrystalClick::BinaryValue)
          w231_assert_part_consumers!(outer, rows_by_mark)
        end
      end
    end
  end

  it "keeps Nested nominal while sharing its parent row axis across QBit fields" do
    qbit_type = CrystalClick::QBitType.new("BFloat16", 9_u64)
    direct_qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    array = w231_try_array_type(direct_qbit)
    array.should_not be_nil
    if array_type = array
      nested_candidate = w231_try_nested_type(
        [direct_qbit, array_type] of CrystalClick::BinaryDataType,
        ["plain", "children"] of String,
      )
      nested_candidate.should_not be_nil
      if nested_type = nested_candidate
        nested_type.tag.should eq(CrystalClick::BinaryDataType::TAG_NESTED)
        rows = [] of CrystalClick::BinaryValue
        record_type = nested_type.child_at(0)
        nested_counts = [2, 0, 1, 3, 0, 1]
        6.times do |row|
          records = [] of CrystalClick::BinaryValue
          nested_counts[row].times do |record|
            records << CrystalClick::BinaryValue.tuple(
              record_type,
              [
                w231_qbit_value(qbit_type, (0x20 + row * 7 + record).to_u8),
                w231_qbit_array_value(array_type, qbit_type, w231_qbit_seeds(row, (row + record) % 3, 0x50_u8)),
              ] of CrystalClick::BinaryValue,
            )
          end
          rows << CrystalClick::BinaryValue.nested(nested_type, records)
        end
        rows_by_mark = [rows[0, 2], rows[2, 2], rows[4, 2]] of Array(CrystalClick::BinaryValue)
        w231_assert_part_consumers!(nested_type, rows_by_mark)
      end
    end
  end

  it "derives Map value QBit occurrences from the Map entry axis" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    qbit_type = CrystalClick::QBitType.new("Float32", 9_u64)
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    map_candidate = w231_try_map_type(string_type, qbit)
    map_candidate.should_not be_nil
    if map_type = map_candidate
      rows = [] of CrystalClick::BinaryValue
      entry_counts = [2, 0, 3, 1, 0, 2]
      6.times do |row|
        flat = [] of CrystalClick::BinaryValue
        entry_counts[row].times do |entry|
          flat << CrystalClick::BinaryValue.string("k#{row}-#{entry}")
          flat << w231_qbit_value(qbit_type, (0x40 + row * 5 + entry).to_u8)
        end
        rows << CrystalClick::BinaryValue.map(map_type, flat)
      end
      rows_by_mark = [rows[0, 2], rows[2, 2], rows[4, 2]] of Array(CrystalClick::BinaryValue)
      w231_assert_part_consumers!(map_type, rows_by_mark)
    end
  end

  it "binds a QBit Map key separately from its ordinary value site" do
    qbit_type = CrystalClick::QBitType.new("Int8", 9_u64)
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    map_candidate = w231_try_map_type(qbit, uint64)
    map_candidate.should_not be_nil
    if map_type = map_candidate
      rows = [] of CrystalClick::BinaryValue
      entry_counts = [2, 0, 3, 1, 0, 2]
      6.times do |row|
        flat = [] of CrystalClick::BinaryValue
        entry_counts[row].times do |entry|
          flat << w231_qbit_value(qbit_type, (0x30 + row * 7 + entry).to_u8)
          flat << CrystalClick::BinaryValue.uint64((row * 100 + entry).to_u64)
        end
        rows << CrystalClick::BinaryValue.map(map_type, flat)
      end
      rows_by_mark = [rows[0, 2], rows[2, 2], rows[4, 2]] of Array(CrystalClick::BinaryValue)
      w231_assert_part_consumers!(map_type, rows_by_mark)
    end
  end

  it "retains Nullable(Tuple) hidden defaults in physical child occurrence counts" do
    array_qbit_type = CrystalClick::QBitType.new("Int8", 3_u64)
    direct_qbit_type = CrystalClick::QBitType.new("Int8", 3_u64)
    array_qbit = CrystalClick::BinaryDataType.qbit(array_qbit_type)
    direct_qbit = CrystalClick::BinaryDataType.qbit(direct_qbit_type)
    array_candidate = w231_try_array_type(array_qbit)
    array_candidate.should_not be_nil
    if array_type = array_candidate
      tuple_candidate = w231_try_tuple_type([array_type, direct_qbit] of CrystalClick::BinaryDataType)
      tuple_candidate.should_not be_nil
      if tuple_type = tuple_candidate
        nullable_candidate = w231_try_nullable_type(tuple_type)
        nullable_candidate.should_not be_nil
        if nullable_type = nullable_candidate
          rows = [] of CrystalClick::BinaryValue
          array_counts = [2, 0, 1, 0, 1, 0]
          null_rows = [false, true, false, true, false, false]
          6.times do |row|
            if null_rows[row]
              rows << CrystalClick::BinaryValue.nullable(nullable_type)
            else
              tuple_value = CrystalClick::BinaryValue.tuple(
                tuple_type,
                [
                  w231_qbit_array_value(array_type, array_qbit_type, w231_qbit_seeds(row, array_counts[row], 0x20_u8)),
                  w231_qbit_value(direct_qbit_type, (0x60 + row).to_u8),
                ] of CrystalClick::BinaryValue,
              )
              rows << CrystalClick::BinaryValue.nullable(nullable_type, tuple_value)
            end
          end
          rows_by_mark = [rows[0, 2], rows[2, 2], rows[4, 2]] of Array(CrystalClick::BinaryValue)
          streams = CrystalClick::BinaryBulkCodec.encode(nullable_type, rows_by_mark)
          streams.stream("root.nulls").bytes.size.should eq(6)
          sizes = streams.stream("root.nested.field.0.sizes").bytes
          sizes.size.should eq(48)
          Array(UInt64).new(6) { |index| w231_read_u64(sizes, index * 8) }.should eq([2_u64, 0, 1, 0, 1, 0])

          # A NULL outer Tuple still emits its direct QBit child's default row;
          # only the inner Array child axis collapses to an empty default.
          8.times do |plane|
            direct_plane = streams.stream("root.nested.field.1.qbit_plane.#{plane}").bytes
            direct_plane.size.should eq(6)
            [1, 3].each { |row| direct_plane[row].should eq(0_u8) }
          end
          w231_assert_part_consumers!(nullable_type, rows_by_mark)
        end
      end
    end
  end

  it "rejects a checksummed late mismatch in the second sibling before first-window and EOF callbacks" do
    left_qbit_type = CrystalClick::QBitType.new("Int8", 9_u64)
    right_qbit_type = CrystalClick::QBitType.new("Float32", 9_u64)
    left_qbit = CrystalClick::BinaryDataType.qbit(left_qbit_type)
    right_qbit = CrystalClick::BinaryDataType.qbit(right_qbit_type)
    left_array = w231_try_array_type(left_qbit)
    right_array = w231_try_array_type(right_qbit)
    left_array.should_not be_nil
    right_array.should_not be_nil

    if left = left_array
      if right = right_array
        tuple_candidate = w231_try_tuple_type([left, right] of CrystalClick::BinaryDataType)
        tuple_candidate.should_not be_nil
        if tuple_type = tuple_candidate
          left_counts = [1, 0, 0, 1, 0, 0]
          right_counts = [0, 1, 0, 1, 2, 0]
          rows = [] of CrystalClick::BinaryValue
          6.times do |row|
            rows << CrystalClick::BinaryValue.tuple(
              tuple_type,
              [
                w231_qbit_array_value(left, left_qbit_type, w231_qbit_seeds(row, left_counts[row], 0x10_u8)),
                w231_qbit_array_value(right, right_qbit_type, w231_qbit_seeds(row, right_counts[row], 0x50_u8)),
              ] of CrystalClick::BinaryValue,
            )
          end
          rows_by_mark = [rows[0, 2], rows[2, 2], rows[4, 2]] of Array(CrystalClick::BinaryValue)

          scratch = File.tempname("crystal-click-w231-qbit-late-site-")
          Dir.mkdir(scratch)
          part = File.join(scratch, "all_1_1_0")
          begin
            write_ok = w231_try_write_part(part, tuple_type, rows_by_mark)
            write_ok.should be_true
            if write_ok
              physical = CrystalClick::BinaryBulkPhysicalPlan.new(
                tuple_type,
                "v",
                CrystalClick::BinaryBulkProfile.single_stream,
              )
              size_role = "root.field.1.sizes"
              data_name = physical.data_file_for(size_role, true)
              marks_name = physical.marks_file_for(size_role, true)
              sizes_path = File.join(part, data_name)
              sizes_before = CrystalClick::CompressedBlock.decode_all(File.read(sizes_path).to_slice)
              Array(UInt64).new(6) { |index| w231_read_u64(sizes_before, index * 8) }.should eq([0_u64, 1, 0, 1, 2, 0])

              w231_corrupt_late_mark_byte!(part, data_name, marks_name, 2, 3_u8)
              sizes_after = CrystalClick::CompressedBlock.decode_all(File.read(sizes_path).to_slice)
              Array(UInt64).new(6) { |index| w231_read_u64(sizes_after, index * 8) }.should eq([0_u64, 1, 0, 1, 3, 0])

              [0_u64, 6_u64].each do |first_row|
                callbacks = 0
                expect_raises(CrystalClick::CorruptPartError) do
                  typed = CrystalClick::WidePartTable.open_selected_typed([part], ["v"])
                  typed.scan_typed_window(first_row, 1) { |_batch| callbacks += 1 }
                end
                callbacks.should eq(0)
              end
            end
          ensure
            FileUtils.rm_rf(scratch)
          end
        end
      end
    end
  end

  it "rejects a checksummed late Nullable ancestor-map shape mismatch before first-window and EOF callbacks" do
    qbit_type = CrystalClick::QBitType.new("Int8", 3_u64)
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    array_candidate = w231_try_array_type(qbit)
    array_candidate.should_not be_nil
    if array_type = array_candidate
      tuple_candidate = w231_try_tuple_type([array_type, qbit] of CrystalClick::BinaryDataType)
      tuple_candidate.should_not be_nil
      if tuple_type = tuple_candidate
        nullable_candidate = w231_try_nullable_type(tuple_type)
        nullable_candidate.should_not be_nil
        if nullable_type = nullable_candidate
          child_counts = [2, 0, 1, 0, 1, 0]
          null_rows = [false, true, false, true, false, false]
          rows = [] of CrystalClick::BinaryValue
          6.times do |row|
            if null_rows[row]
              rows << CrystalClick::BinaryValue.nullable(nullable_type)
            else
              tuple_value = CrystalClick::BinaryValue.tuple(
                tuple_type,
                [
                  w231_qbit_array_value(array_type, qbit_type, w231_qbit_seeds(row, child_counts[row], 0x20_u8)),
                  w231_qbit_value(qbit_type, (0x60 + row).to_u8),
                ] of CrystalClick::BinaryValue,
              )
              rows << CrystalClick::BinaryValue.nullable(nullable_type, tuple_value)
            end
          end
          rows_by_mark = [rows[0, 2], rows[2, 2], rows[4, 2]] of Array(CrystalClick::BinaryValue)

          scratch = File.tempname("crystal-click-w231-qbit-late-null-map-")
          Dir.mkdir(scratch)
          part = File.join(scratch, "all_1_1_0")
          begin
            write_ok = w231_try_write_part(part, nullable_type, rows_by_mark)
            write_ok.should be_true
            if write_ok
              physical = CrystalClick::BinaryBulkPhysicalPlan.new(
                nullable_type,
                "v",
                CrystalClick::BinaryBulkProfile.single_stream,
              )
              data_name = physical.data_file_for("root.nulls", true)
              marks_name = physical.marks_file_for("root.nulls", true)
              w231_corrupt_late_mark_delta!(part, data_name, marks_name, 2)

              [0_u64, 6_u64].each do |first_row|
                callbacks = 0
                expect_raises(CrystalClick::CorruptPartError) do
                  typed = CrystalClick::WidePartTable.open_selected_typed([part], ["v"])
                  typed.scan_typed_window(first_row, 1) { |_batch| callbacks += 1 }
                end
                callbacks.should eq(0)
              end
            end
          ensure
            FileUtils.rm_rf(scratch)
          end
        end
      end
    end
  end
end
