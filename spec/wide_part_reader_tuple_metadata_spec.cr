require "./spec_helper"

W93_TUPLE_FIXTURE = File.expand_path("../test/fixtures/public/wide_tuple_uint64_string/part", __DIR__)
W93_TUPLE_VALUES  = [
  {0_u64, ""},
  {UInt64::MAX, "short"},
  {2_u64, String.new(Bytes[0x41_u8, 0x00_u8, 0x42_u8, 0xff_u8])},
  {3_u64, "a much longer payload crossing offsets"},
  {4_u64, ""},
] of Tuple(UInt64, String)

private def with_w93_tuple_part(& : String ->)
  root = File.tempname("crystal-click-w93-tuple-metadata")
  Dir.mkdir(root)
  part = File.join(root, "part")
  FileUtils.cp_r(W93_TUPLE_FIXTURE, part)

  begin
    yield part
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w93_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
end

private def w93_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w93_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w93_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |index| io.write_byte(((hash[0] >> (index * 8)) & 0xff_u64).to_u8) }
  8.times { |index| io.write_byte(((hash[1] >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w93_encode_lz4_frame(raw : Bytes) : Bytes
  raise "W93 checksum fixture cannot encode an empty LZ4 block" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w93_write_u32(frame, header + 1, compressed_size.to_u32)
  w93_write_u32(frame, header + 5, raw.size.to_u32)
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
  w93_write_u64(frame, 0, checksum[0])
  w93_write_u64(frame, 8, checksum[1])
  frame
end

private def w93_refresh_checksums(part : String) : Nil
  checksums = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = checksums.entries.keys.sort
  w93_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = checksums.entries[name]
    w93_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w93_write_varuint(payload, file_bytes.size.to_u64)
    w93_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = if file_bytes.empty?
              raise "W93 empty compressed checksum entry must declare zero raw bytes" unless entry.uncompressed_size == 0_u64
              file_bytes
            else
              CrystalClick::CompressedBlock.decode_all(file_bytes)
            end
      payload.write_byte(1_u8)
      w93_write_varuint(payload, raw.size.to_u64)
      w93_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(w93_encode_lz4_frame(payload.to_slice))
  end
end

private def w93_key_record(
  kind : String = "Default",
  name : String = "id",
  defaults : Int32 = 0,
  rows : Int32 = 5,
  extra : String = "",
) : String
  %({"kind":"#{kind}","name":"#{name}","num_defaults":#{defaults},"num_rows":#{rows}#{extra}})
end

private def w93_child_record(
  kind : String = "Default",
  defaults : Int32 = 1,
  rows : Int32 = 5,
  extra : String = "",
) : String
  %({"kind":"#{kind}","num_defaults":#{defaults},"num_rows":#{rows}#{extra}})
end

private def w93_payload_record(
  kind : String = "Default",
  name : String = "payload",
  defaults : Int32 = 1,
  rows : Int32 = 5,
  children : Array(String)? = nil,
  extra : String = "",
) : String
  child_records = children || [w93_child_record(defaults: 1), w93_child_record(defaults: 2)]
  %({"kind":"#{kind}","name":"#{name}","num_defaults":#{defaults},"num_rows":#{rows},"subcolumns":[#{child_records.join(",")}]#{extra}})
end

private def w93_serialization(
  records : Array(String)?,
  version : Int32 = 1,
  string_version : Int32 = 1,
  propagate : Bool = true,
  extra_root : String = "",
) : String
  columns = records.try { |items| %("columns":[#{items.join(",")}],) } || ""
  %({#{columns}"propagate_types_serialization_versions_to_nested_types":#{propagate},"types_serialization_versions":{"string":#{string_version}},"version":#{version}#{extra_root}})
end

private def w93_write_serialization(
  part : String,
  records : Array(String)?,
  version : Int32 = 1,
  string_version : Int32 = 1,
  propagate : Bool = true,
  extra_root : String = "",
) : Nil
  text = w93_serialization(records, version, string_version, propagate, extra_root)
  JSON.parse(text)
  File.write(File.join(part, "serialization.json"), text)
  w93_refresh_checksums(part)
end

private def w93_assert_tuple_reads(part : String) : Nil
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
  reader.read_tuple_uint64_string_mark_range("payload", 0, 3).should eq(W93_TUPLE_VALUES)
  reader.read_tuple_uint64_string_mark_range("payload", 0, 1).should eq(W93_TUPLE_VALUES[0, 2])
  reader.read_tuple_uint64_string_mark_range("payload", 1, 1).should eq(W93_TUPLE_VALUES[2, 2])
  reader.read_tuple_uint64_string_mark_range("payload", 2, 1).should eq(W93_TUPLE_VALUES[4, 1])
  reader.read_tuple_uint64_string_mark_range("payload", 1, 2).should eq(W93_TUPLE_VALUES[2, 3])
end

private def w93_expect_unsupported(part : String, message : String) : Nil
  expect_raises(CrystalClick::UnsupportedFormatError, message) do
    CrystalClick::WidePart.open_typed(part, "payload")
  end
end

private def w93_expect_unsupported_any(part : String) : Nil
  expect_raises(CrystalClick::UnsupportedFormatError) do
    CrystalClick::WidePart.open_typed(part, "payload")
  end
end

private def w93_expect_corrupt(part : String, message : String) : Nil
  expect_raises(CrystalClick::CorruptPartError, message) do
    CrystalClick::WidePart.open_typed(part, "payload")
  end
end

private def w93_expect_corrupt_any(part : String) : Nil
  expect_raises(CrystalClick::CorruptPartError) do
    CrystalClick::WidePart.open_typed(part, "payload")
  end
end

describe "W93 exact Tuple serialization metadata" do
  it "reads explicit Default serializers reordered by exact column name" do
    with_w93_tuple_part do |part|
      w93_write_serialization(part, [w93_payload_record, w93_key_record])
      w93_assert_tuple_reads(part)
    end
  end

  it "reads nondefault Tuple values with the exact AlwaysDefault columns-empty profile" do
    with_w93_tuple_part do |part|
      w93_write_serialization(part, [] of String)
      JSON.parse(File.read(File.join(part, "serialization.json"))).as_h["columns"].as_a.should be_empty
      w93_assert_tuple_reads(part)
    end
  end

  it "uses implicit Default metadata for an omitted selected Tuple record" do
    with_w93_tuple_part do |part|
      w93_write_serialization(part, [w93_key_record])
      w93_assert_tuple_reads(part)
    end
  end

  it "classifies partial, duplicate, and unmapped top-level records as corrupt" do
    with_w93_tuple_part do |part|
      partial_key = %({"kind":"Default","name":"id","num_rows":5})
      w93_write_serialization(part, [partial_key, w93_payload_record])
      w93_expect_corrupt_any(part)
    end

    with_w93_tuple_part do |part|
      w93_write_serialization(part, [w93_key_record, w93_key_record])
      w93_expect_corrupt_any(part)
    end

    with_w93_tuple_part do |part|
      unexpected = w93_key_record(name: "extra")
      w93_write_serialization(part, [w93_key_record, w93_payload_record, unexpected])
      w93_expect_corrupt_any(part)
    end

    with_w93_tuple_part do |part|
      unexpected_name = w93_key_record(name: "extra")
      w93_write_serialization(part, [w93_key_record, unexpected_name])
      w93_expect_corrupt_any(part)
    end
  end

  it "keeps serialization metadata without a columns field outside the admitted profile" do
    with_w93_tuple_part do |part|
      w93_write_serialization(part, nil)
      w93_expect_unsupported(part, "unsupported Tuple serialization.json fields")
    end
  end

  it "rejects Sparse records and root, version, propagation, or nested-String profile drift" do
    with_w93_tuple_part do |part|
      w93_write_serialization(part, [w93_key_record, w93_payload_record(kind: "Sparse")])
      w93_expect_unsupported(part, "only Default Tuple serializers are supported")
    end

    with_w93_tuple_part do |part|
      w93_write_serialization(part, [w93_key_record, w93_payload_record], extra_root: %(,"unexpected":true))
      w93_expect_unsupported(part, "unsupported Tuple serialization.json fields")
    end

    with_w93_tuple_part do |part|
      w93_write_serialization(part, [w93_key_record, w93_payload_record], version: 2)
      w93_expect_unsupported(part, "only serialization.json version 1 is supported")
    end

    with_w93_tuple_part do |part|
      w93_write_serialization(part, [w93_key_record, w93_payload_record], propagate: false)
      w93_expect_unsupported(part, "Tuple nested serialization versions are unsupported")
    end

    with_w93_tuple_part do |part|
      w93_write_serialization(part, [w93_key_record, w93_payload_record], string_version: 2)
      w93_expect_unsupported(part, "only nested String serialization version 1 is supported for Tuple")
    end
  end

  it "enforces root, version, propagation, and String gates for empty columns" do
    with_w93_tuple_part do |part|
      w93_write_serialization(part, [] of String, extra_root: %(,"unexpected":true))
      w93_expect_unsupported(part, "unsupported Tuple serialization.json fields")
    end

    with_w93_tuple_part do |part|
      w93_write_serialization(part, [] of String, version: 2)
      w93_expect_unsupported(part, "only serialization.json version 1 is supported")
    end

    with_w93_tuple_part do |part|
      w93_write_serialization(part, [] of String, propagate: false)
      w93_expect_unsupported(part, "Tuple nested serialization versions are unsupported")
    end

    with_w93_tuple_part do |part|
      w93_write_serialization(part, [] of String, string_version: 2)
      w93_expect_unsupported(part, "only nested String serialization version 1 is supported for Tuple")
    end
  end

  it "rejects invalid top-level and child row/default counts" do
    with_w93_tuple_part do |part|
      w93_write_serialization(part, [w93_key_record(rows: 4), w93_payload_record])
      w93_expect_corrupt_any(part)
    end

    with_w93_tuple_part do |part|
      w93_write_serialization(part, [w93_key_record, w93_payload_record(defaults: 6)])
      w93_expect_corrupt_any(part)
    end

    with_w93_tuple_part do |part|
      children = [w93_child_record(rows: 4), w93_child_record(defaults: 2)]
      w93_write_serialization(part, [w93_key_record, w93_payload_record(children: children)])
      w93_expect_corrupt(part, "Tuple child row count does not match part")
    end

    with_w93_tuple_part do |part|
      children = [w93_child_record(defaults: 6), w93_child_record(defaults: 2)]
      w93_write_serialization(part, [w93_key_record, w93_payload_record(children: children)])
      w93_expect_corrupt(part, "Tuple child default count is invalid")
    end
  end

  it "accepts optional exact_num_defaults Boolean flags on Tuple records" do
    with_w93_tuple_part do |part|
      key_with_flag = w93_key_record(extra: %(,"exact_num_defaults":true))
      first_child = w93_child_record(defaults: 1, extra: %(,"exact_num_defaults":true))
      second_child = w93_child_record(defaults: 2, extra: %(,"exact_num_defaults":false))
      payload_with_flag = w93_payload_record(
        children: [first_child, second_child],
        extra: %(,"exact_num_defaults":false),
      )
      w93_write_serialization(part, [key_with_flag, payload_with_flag])
      w93_assert_tuple_reads(part)
    end
  end

  it "classifies a non-Boolean exact_num_defaults flag as corrupt" do
    with_w93_tuple_part do |part|
      payload_with_invalid_flag = w93_payload_record(extra: %(,"exact_num_defaults":"true"))
      w93_write_serialization(part, [w93_key_record, payload_with_invalid_flag])
      w93_expect_corrupt_any(part)
    end
  end

  it "rejects wrong child counts, child serializer types, and extra child fields" do
    with_w93_tuple_part do |part|
      w93_write_serialization(part, [w93_key_record, w93_payload_record(children: [w93_child_record])])
      w93_expect_unsupported(part, "exactly two Tuple child serializers are required")
    end

    with_w93_tuple_part do |part|
      children = [w93_child_record(kind: "Sparse"), w93_child_record(defaults: 2)]
      w93_write_serialization(part, [w93_key_record, w93_payload_record(children: children)])
      w93_expect_unsupported(part, "only Default Tuple child serializers are supported")
    end

    with_w93_tuple_part do |part|
      child_with_extra = w93_child_record(extra: %(,"type":"UInt64"))
      children = [child_with_extra, w93_child_record(defaults: 2)]
      w93_write_serialization(part, [w93_key_record, w93_payload_record(children: children)])
      w93_expect_unsupported(part, "unsupported Tuple child serializer fields")
    end

    with_w93_tuple_part do |part|
      w93_write_serialization(part, [w93_key_record, w93_payload_record(extra: %(,"extra":true))])
      w93_expect_unsupported(part, "unsupported named Tuple serializer fields")
    end

    with_w93_tuple_part do |part|
      key_with_extra = w93_key_record(extra: %(,"unexpected":true))
      w93_write_serialization(part, [key_with_extra, w93_payload_record])
      w93_expect_unsupported(part, "unsupported Tuple key serializer fields")
    end
  end

  it "reads reversed Tuple children by name without widening the exact pair accessor" do
    with_w93_tuple_part do |part|
      columns_path = File.join(part, "columns.txt")
      columns = File.read(columns_path)
      reversed = columns.sub("Tuple(a UInt64, b String)", "Tuple(b String, a UInt64)")
      reversed.should_not eq(columns)
      File.write(columns_path, reversed)
      w93_refresh_checksums(part)

      reader = CrystalClick::WidePart.open_typed(part, "payload")
      data = reader.read_tuple_mark_range("payload", 0, 3)
      data.type_name.should eq("Tuple(b String, a UInt64)")
      rows = Array(Tuple(String, UInt64)).new(data.row_count) do |index|
        row = data.row(index)
        {row.value_as("b", String), row.value_as("a", UInt64)}
      end
      rows.should eq(W93_TUPLE_VALUES.map { |value| {value[1], value[0]} })

      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_tuple_uint64_string_mark_range("payload", 0, 3)
      end
    end
  end
end
