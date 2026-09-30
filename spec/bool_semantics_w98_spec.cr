require "./spec_helper"
require "file_utils"

private alias W98UInt64BoolMap = Array(Tuple(UInt64, Bool))
private alias W98StringBoolMap = Array(Tuple(String, Bool))
private alias W98UInt64NullableBoolMap = Array(Tuple(UInt64, Bool?))
private alias W98StringNullableBoolMap = Array(Tuple(String, Bool?))

private def w98_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
end

private def w98_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w98_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w98_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |index| io.write_byte(((hash[0] >> (index * 8)) & 0xff_u64).to_u8) }
  8.times { |index| io.write_byte(((hash[1] >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w98_encode_literal_frame(raw : Bytes) : Bytes
  raise "W98 mutation cannot encode an empty LZ4 block" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w98_write_u32(frame, header + 1, compressed_size.to_u32)
  w98_write_u32(frame, header + 5, raw.size.to_u32)
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
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  w98_write_u64(frame, 0, checksum[0])
  w98_write_u64(frame, 8, checksum[1])
  frame
end

private def w98_refresh_checksums(part : String) : Nil
  checksums = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = checksums.entries.keys.sort
  w98_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = checksums.entries[name]
    w98_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w98_write_varuint(payload, file_bytes.size.to_u64)
    w98_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = file_bytes.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w98_write_varuint(payload, raw.size.to_u64)
      w98_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end

  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(w98_encode_literal_frame(payload.to_slice))
  end
end

# W98 parts use one mark per stream. Re-encode the selected stream and update
# its sentinel and checksums so the reader reaches the targeted value/role
# validation rather than rejecting a stale fixture checksum.
private def w98_replace_stream_byte(part : String, stream : String, offset : Int, value : UInt8) : Nil
  stream_hash = CrystalClick::StreamName.hash(stream)
  data_path = File.join(part, "#{stream_hash}.bin")
  raw = CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).dup
  raise "W98 mutation offset is outside #{stream}" if offset < 0 || offset >= raw.size
  raw[offset] = value

  frame = w98_encode_literal_frame(raw)
  File.write(data_path, frame)

  marks_path = File.join(part, "#{stream_hash}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "W98 expects one data mark and a sentinel" unless marks.size == 2 * mark_size
  w98_write_u64(marks, mark_size, frame.size.to_u64)
  File.write(marks_path, marks)
  w98_refresh_checksums(part)

  verification = CrystalClick::PartChecksums.open(part).validate_selected_entries(
    part,
    "#{stream_hash}.bin",
    "#{stream_hash}.mrk2"
  )
  unless verification == CrystalClick::ChecksumVerification::SizeChecked
    raise "W98 mutated stream entries were not size-validated"
  end
end

private def w98_keys : Array(UInt64)
  [1_u64]
end

private def w98_key_slice(keys : Array(UInt64)) : Slice(UInt64)
  keys.to_unsafe.to_slice(keys.size)
end

private def w98_with_parent(& : String ->)
  parent = File.tempname("crystal-click-w98-bool")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W98 shared Bool value semantics" do
  it "decodes every nonzero root Bool byte as true" do
    w98_with_parent do |parent|
      keys = w98_keys
      part = File.join(parent, "root-bool")
      values = [false]
      CrystalClick::WidePartWriter.write_uint64_bool_pair(
        part, "pk", w98_key_slice(keys), "flag", values.to_unsafe.to_slice(values.size), 1
      )
      w98_replace_stream_byte(part, "flag", 0, 2_u8)
      CrystalClick::WidePart.open_typed(part, "flag").read_bool_mark_range("flag", 0, 1).should eq([true])
    end
  end

  it "decodes nullable Bool values semantically but keeps the null map strict" do
    w98_with_parent do |parent|
      keys = w98_keys
      value_part = File.join(parent, "nullable-value")
      values = [false.as(Bool?)]
      CrystalClick::WidePartWriter.write_uint64_nullable_bool_pair(
        value_part, "pk", w98_key_slice(keys), "flag", values.to_unsafe.to_slice(values.size), 1
      )
      w98_replace_stream_byte(value_part, "flag", 0, 2_u8)
      CrystalClick::WidePart.open_typed(value_part, "flag").read_nullable_bool_mark_range("flag", 0, 1)
        .should eq([true.as(Bool?)])

      null_part = File.join(parent, "nullable-null-map")
      null_values = [nil.as(Bool?)]
      CrystalClick::WidePartWriter.write_uint64_nullable_bool_pair(
        null_part, "pk", w98_key_slice(keys), "flag", null_values.to_unsafe.to_slice(null_values.size), 1
      )
      w98_replace_stream_byte(null_part, "flag.null", 0, 2_u8)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(null_part, "flag").read_nullable_bool_mark_range("flag", 0, 1)
      end
    end
  end

  it "decodes Array(Bool) child bytes semantically" do
    w98_with_parent do |parent|
      keys = w98_keys
      part = File.join(parent, "array-bool")
      values = [[false]]
      CrystalClick::WidePartWriter.write_uint64_array_bool_pair(
        part, "pk", w98_key_slice(keys), "payload", values.to_unsafe.to_slice(values.size), 1
      )
      w98_replace_stream_byte(part, "payload", 0, 2_u8)
      CrystalClick::WidePart.open_typed(part, "payload").read_array_bool_mark_range("payload", 0, 1).should eq([[true]])
    end
  end

  it "decodes Array(Nullable(Bool)) values but keeps its null map strict" do
    w98_with_parent do |parent|
      keys = w98_keys
      value_part = File.join(parent, "array-nullable-value")
      values = [[false.as(Bool?)]]
      CrystalClick::WidePartWriter.write_uint64_array_nullable_bool_pair(
        value_part, "pk", w98_key_slice(keys), "payload", values.to_unsafe.to_slice(values.size), 1
      )
      w98_replace_stream_byte(value_part, "payload", 0, 2_u8)
      CrystalClick::WidePart.open_typed(value_part, "payload").read_array_nullable_bool_mark_range("payload", 0, 1)
        .should eq([[true.as(Bool?)]])

      null_part = File.join(parent, "array-null-map")
      null_values = [[nil.as(Bool?)]]
      CrystalClick::WidePartWriter.write_uint64_array_nullable_bool_pair(
        null_part, "pk", w98_key_slice(keys), "payload", null_values.to_unsafe.to_slice(null_values.size), 1
      )
      w98_replace_stream_byte(null_part, "payload.null", 0, 2_u8)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(null_part, "payload").read_array_nullable_bool_mark_range("payload", 0, 1)
      end
    end
  end

  it "decodes Array(Map(UInt64, Bool)) values semantically" do
    w98_with_parent do |parent|
      keys = w98_keys
      part = File.join(parent, "array-map-u64-bool")
      map = [{10_u64, false}] of Tuple(UInt64, Bool)
      row = [map] of W98UInt64BoolMap
      values = [row] of Array(W98UInt64BoolMap)
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_bool_pair(
        part, "pk", w98_key_slice(keys), "payload", values.to_unsafe.to_slice(values.size), 1
      )
      w98_replace_stream_byte(part, "payload%2Evalues", 0, 2_u8)
      CrystalClick::WidePart.open_typed(part, "payload").read_array_map_uint64_bool_mark_range("payload", 0, 1)
        .should eq([[[{10_u64, true}]]])
    end
  end

  it "decodes Array(Map(String, Bool)) values semantically" do
    w98_with_parent do |parent|
      keys = w98_keys
      part = File.join(parent, "array-map-string-bool")
      map = [{"k", false}] of Tuple(String, Bool)
      row = [map] of W98StringBoolMap
      values = [row] of Array(W98StringBoolMap)
      CrystalClick::WidePartWriter.write_uint64_array_map_string_bool_pair(
        part, "pk", w98_key_slice(keys), "payload", values.to_unsafe.to_slice(values.size), 1
      )
      w98_replace_stream_byte(part, "payload%2Evalues", 0, 2_u8)
      CrystalClick::WidePart.open_typed(part, "payload").read_array_map_string_bool_mark_range("payload", 0, 1)
        .should eq([[[{"k", true}]]])
    end
  end

  it "decodes Array(Map(UInt64, Nullable(Bool))) values but keeps value null maps strict" do
    w98_with_parent do |parent|
      keys = w98_keys
      value_part = File.join(parent, "array-map-u64-nullable-value")
      map = [{10_u64, false.as(Bool?)}] of Tuple(UInt64, Bool?)
      row = [map] of W98UInt64NullableBoolMap
      values = [row] of Array(W98UInt64NullableBoolMap)
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_nullable_bool_pair(
        value_part, "pk", w98_key_slice(keys), "payload", values.to_unsafe.to_slice(values.size), 1
      )
      w98_replace_stream_byte(value_part, "payload%2Evalues", 0, 2_u8)
      CrystalClick::WidePart.open_typed(value_part, "payload").read_array_map_uint64_nullable_bool_mark_range("payload", 0, 1)
        .should eq([[[{10_u64, true.as(Bool?)}]]])

      null_part = File.join(parent, "array-map-u64-null-map")
      null_map = [{10_u64, nil.as(Bool?)}] of Tuple(UInt64, Bool?)
      null_row = [null_map] of W98UInt64NullableBoolMap
      null_values = [null_row] of Array(W98UInt64NullableBoolMap)
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_nullable_bool_pair(
        null_part, "pk", w98_key_slice(keys), "payload", null_values.to_unsafe.to_slice(null_values.size), 1
      )
      w98_replace_stream_byte(null_part, "payload%2Evalues.null", 0, 2_u8)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(null_part, "payload").read_array_map_uint64_nullable_bool_mark_range("payload", 0, 1)
      end
    end
  end

  it "decodes Array(Map(String, Nullable(Bool))) values semantically" do
    w98_with_parent do |parent|
      keys = w98_keys
      part = File.join(parent, "array-map-string-nullable-bool")
      map = [{"k", false.as(Bool?)}] of Tuple(String, Bool?)
      row = [map] of W98StringNullableBoolMap
      values = [row] of Array(W98StringNullableBoolMap)
      CrystalClick::WidePartWriter.write_uint64_array_map_string_nullable_bool_pair(
        part, "pk", w98_key_slice(keys), "payload", values.to_unsafe.to_slice(values.size), 1
      )
      w98_replace_stream_byte(part, "payload%2Evalues", 0, 2_u8)
      CrystalClick::WidePart.open_typed(part, "payload").read_array_map_string_nullable_bool_mark_range("payload", 0, 1)
        .should eq([[[{"k", true.as(Bool?)}]]])
    end
  end

  it "decodes Variant Bool values semantically while keeping tags strict" do
    w98_with_parent do |parent|
      keys = w98_keys
      part = File.join(parent, "variant")
      values = [false] of CrystalClick::VariantBoolStringUInt64Value
      CrystalClick::WidePartWriter.write_uint64_variant_bool_string_uint64_pair(
        part, "pk", w98_key_slice(keys), "payload", values.to_unsafe.to_slice(values.size), 1
      )
      w98_replace_stream_byte(part, "payload.Bool", 0, 2_u8)
      CrystalClick::WidePart.open_typed(part, "payload").read_variant_bool_string_uint64_mark_range("payload", 0, 1)
        .should eq([true] of CrystalClick::VariantBoolStringUInt64Value)

      tag_part = File.join(parent, "variant-tag")
      CrystalClick::WidePartWriter.write_uint64_variant_bool_string_uint64_pair(
        tag_part, "pk", w98_key_slice(keys), "payload", values.to_unsafe.to_slice(values.size), 1
      )
      # The one-row discriminator uses a two-byte header followed by its tag.
      w98_replace_stream_byte(tag_part, "payload.variant_discr", 2, 3_u8)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(tag_part, "payload").read_variant_bool_string_uint64_mark_range("payload", 0, 1)
      end
    end
  end

  it "decodes named Tuple Bool values semantically" do
    w98_with_parent do |parent|
      keys = w98_keys
      part = File.join(parent, "tuple")
      columns = [CrystalClick::WideTupleLeafColumn.new("flag", [false])] of CrystalClick::WideTupleLeafColumn
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        part, "pk", w98_key_slice(keys), "payload", "Tuple(flag Bool)", columns, rows_per_mark: 1
      )
      w98_replace_stream_byte(part, "payload%2Eflag", 0, 2_u8)
      data = CrystalClick::WidePart.open_typed(part, "payload").read_tuple_mark_range("payload", 0, 1)
      data["flag"].values_as(Bool).should eq([true])
    end
  end
end
