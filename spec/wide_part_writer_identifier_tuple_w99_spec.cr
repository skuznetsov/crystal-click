require "./spec_helper"
require "file_utils"

private def w99_writer_tuple_u64_bytes(values : Array(UInt64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    8.times { |index| bytes << ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w99_writer_tuple_uuid_bytes(values : Array(CrystalClick::UUIDValue)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    {value.high, value.low}.each do |half|
      8.times { |index| bytes << ((half >> (index * 8)) & 0xff_u64).to_u8 }
    end
  end
  bytes
end

private def w99_writer_tuple_ipv4_bytes(values : Array(CrystalClick::IPv4Value)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    4.times { |index| bytes << ((value.network_order >> (index * 8)) & 0xff_u32).to_u8 }
  end
  bytes
end

private def w99_writer_tuple_ipv6_bytes(values : Array(CrystalClick::IPv6Value)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    {value.high, value.low}.each do |half|
      8.times { |index| bytes << ((half >> ((7 - index) * 8)) & 0xff_u64).to_u8 }
    end
  end
  bytes
end

private def w99_writer_tuple_stream_bytes(part : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w99_writer_tuple_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w99_writer_tuple_marks(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "malformed W99 mark file for #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {
      w99_writer_tuple_read_u64(bytes, offset),
      w99_writer_tuple_read_u64(bytes, offset + 8),
      w99_writer_tuple_read_u64(bytes, offset + 16),
    }
  end
end

private def w99_writer_tuple_type(columns : Array(CrystalClick::WideTupleLeafColumn)) : String
  "Tuple(#{columns.map { |column| "#{column.name} #{column.type_name}" }.join(", ")})"
end

private def w99_writer_tuple_streams(columns : Array(CrystalClick::WideTupleLeafColumn)) : Array(String)
  streams = [] of String
  columns.each do |column|
    leaf = "payload%2E#{column.name}"
    streams << "#{leaf}.size" if column.type_name == "String"
    streams << leaf
  end
  streams
end

private def w99_writer_tuple_counting_factory(calls : Array(Int32)) : Proc(String, String)
  ->(parent : String) do
    calls << 1
    stage = File.tempname(".w99-identifier-tuple-stage-", nil, dir: parent)
    Dir.mkdir(stage)
    stage
  end
end

private def w99_writer_tuple_counting_string_copy(
  calls : Array(Int32),
) : Proc(CrystalClick::WideTupleLeafColumn, Array(String))
  ->(column : CrystalClick::WideTupleLeafColumn) do
    calls << 1
    column.string_values
  end
end

private def w99_writer_tuple_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
end

private def w99_writer_tuple_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w99_writer_tuple_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w99_writer_tuple_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |index| io.write_byte(((hash[0] >> (index * 8)) & 0xff_u64).to_u8) }
  8.times { |index| io.write_byte(((hash[1] >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w99_writer_tuple_literal_frame(raw : Bytes) : Bytes
  raise "W99 mutation cannot encode an empty LZ4 block" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w99_writer_tuple_write_u32(frame, header + 1, compressed_size.to_u32)
  w99_writer_tuple_write_u32(frame, header + 5, raw.size.to_u32)
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
  w99_writer_tuple_write_u64(frame, 0, checksum[0])
  w99_writer_tuple_write_u64(frame, 8, checksum[1])
  frame
end

private def w99_writer_tuple_refresh_checksums(part : String) : Nil
  checksums = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = checksums.entries.keys.sort
  w99_writer_tuple_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = checksums.entries[name]
    w99_writer_tuple_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w99_writer_tuple_write_varuint(payload, file_bytes.size.to_u64)
    w99_writer_tuple_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = file_bytes.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w99_writer_tuple_write_varuint(payload, raw.size.to_u64)
      w99_writer_tuple_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end

  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(w99_writer_tuple_literal_frame(payload.to_slice))
  end
end

private def w99_writer_tuple_replace_stream_byte(part : String, stream : String, offset : Int, value : UInt8) : Nil
  stream_hash = CrystalClick::StreamName.hash(stream)
  data_path = File.join(part, "#{stream_hash}.bin")
  raw = CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).dup
  raise "W99 mutation offset is outside #{stream}" if offset < 0 || offset >= raw.size
  raw[offset] = value
  frame = w99_writer_tuple_literal_frame(raw)
  File.write(data_path, frame)

  marks_path = File.join(part, "#{stream_hash}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "W99 fixture expects one data mark and a sentinel" unless marks.size == 2 * mark_size
  w99_writer_tuple_write_u64(marks, mark_size, frame.size.to_u64)
  File.write(marks_path, marks)
  w99_writer_tuple_refresh_checksums(part)
end

module CrystalClick
  module WidePartWriter
    class TuplePartWriter
      def self.w99_test_validate_staged_part(
        stage : String,
        input : TuplePartWriteInput,
        infrastructure : TuplePartInfrastructure,
      ) : Nil
        validate_staged_part(stage, input, infrastructure)
      end
    end

    def self.w99_test_write_with_stage_factory(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      type_name : String,
      columns : Array(WideTupleLeafColumn),
      rows_per_mark : Int32,
      stage_factory : Proc(String, String),
      copy_string_values : Proc(WideTupleLeafColumn, Array(String)),
    ) : String
      write_uint64_tuple_pair_with_stage_factory(
        destination, key_name, keys, value_name, type_name, columns, rows_per_mark,
        stage_factory, copy_string_values
      )
    end

    def self.w99_test_validate_tuple_stage(
      stage : String,
      key_name : String,
      keys : Array(UInt64),
      value_name : String,
      type_name : String,
      columns : Array(WideTupleLeafColumn),
      rows_per_mark : Int32,
    ) : Nil
      type_plan = WideTupleTypePlan.for_type(type_name) || raise "invalid W99 Tuple test type"
      leaf_buffers = Array(TupleLeafBuffers).new(columns.size) { |index| columns[index].values }
      logical_streams = [key_name] + type_plan.physical_streams(value_name)
      mark_count = checked_mark_count(keys.size, rows_per_mark)
      input = TuplePartWriteInput.new(
        File.join(File.dirname(stage), "not-published"),
        File.dirname(stage),
        key_name,
        keys.dup,
        value_name,
        type_plan,
        leaf_buffers,
        logical_streams,
        Array(Int64).new(logical_streams.size, 0_i64),
        Array(UInt64).new(logical_streams.size, 0_u64),
        mark_count,
        rows_per_mark,
        File.read(File.join(stage, "columns.txt")),
        File.read(File.join(stage, "columns_substreams.txt")),
        File.read(File.join(stage, "serialization.json")),
      )
      infrastructure = build_tuple_part_infrastructure(
        ->(parent : String) { create_stage(parent) },
        ->(column : WideTupleLeafColumn) { column.string_values }
      )
      TuplePartWriter.w99_test_validate_staged_part(stage, input, infrastructure)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes reordered and repeated UUID/IP leaves with exact bytes, mark widths and default metadata" do
    v6_values = [
      CrystalClick::IPv6Value.new(0x20010db800010203_u64, 0x0405060708090a0b_u64),
      CrystalClick::IPv6Value.new(0_u64, 0_u64),
      CrystalClick::IPv6Value.new(0x20010db800010204_u64, 0x0c0d0e0f10111213_u64),
      CrystalClick::IPv6Value.new(0x20010db800010205_u64, 0x1415161718191a1b_u64),
      CrystalClick::IPv6Value.new(0x20010db800010206_u64, 0x1c1d1e1f20212223_u64),
    ]
    id_values = [
      CrystalClick::UUIDValue.new(0x0011223344556677_u64, 0x8899aabbccddeeff_u64),
      CrystalClick::UUIDValue.new(0_u64, 0_u64),
      CrystalClick::UUIDValue.new(0x123456789abcdef0_u64, 0x0fedcba987654321_u64),
      CrystalClick::UUIDValue.new(UInt64::MAX, UInt64::MAX),
      CrystalClick::UUIDValue.new(0x1020304050607080_u64, 0x90a0b0c0d0e0f001_u64),
    ]
    v4_values = [
      CrystalClick::IPv4Value.from_octets(192_u8, 0_u8, 2_u8, 1_u8),
      CrystalClick::IPv4Value.from_octets(198_u8, 51_u8, 100_u8, 7_u8),
      CrystalClick::IPv4Value.new(0_u32),
      CrystalClick::IPv4Value.from_octets(203_u8, 0_u8, 113_u8, 9_u8),
      CrystalClick::IPv4Value.from_octets(10_u8, 20_u8, 30_u8, 40_u8),
    ]
    text_values = ["", "a\0b", "three", "four", String.new(Bytes[0xff_u8, 0_u8])]
    id_again_values = [
      CrystalClick::UUIDValue.new(0x61f0c4045cb311e7_u64, 0x907ba6006ad3dba0_u64),
      CrystalClick::UUIDValue.new(0_u64, 0_u64),
      CrystalClick::UUIDValue.new(0x0123456789abcdef_u64, 0xfedcba9876543210_u64),
      CrystalClick::UUIDValue.new(0x1020304050607080_u64, 0x90a0b0c0d0e0f001_u64),
      CrystalClick::UUIDValue.new(UInt64::MAX, UInt64::MAX),
    ]
    count_values = [1_u16, 2_u16, 3_u16, 4_u16, 5_u16]
    flag_values = [false, true, false, false, true]
    v6_again_values = [
      CrystalClick::IPv6Value.new(0x20010db800010210_u64, 0x2425262728292a2b_u64),
      CrystalClick::IPv6Value.new(0_u64, 0_u64),
      CrystalClick::IPv6Value.new(0x20010db800010211_u64, 0x2c2d2e2f30313233_u64),
      CrystalClick::IPv6Value.new(0x20010db800010212_u64, 0x3435363738393a3b_u64),
      CrystalClick::IPv6Value.new(0x20010db800010213_u64, 0x3c3d3e3f40414243_u64),
    ]
    columns = [
      CrystalClick::WideTupleLeafColumn.new("v6", v6_values),
      CrystalClick::WideTupleLeafColumn.new("id", id_values),
      CrystalClick::WideTupleLeafColumn.new("v4", v4_values),
      CrystalClick::WideTupleLeafColumn.new("text", text_values),
      CrystalClick::WideTupleLeafColumn.new("id_again", id_again_values),
      CrystalClick::WideTupleLeafColumn.new("count", count_values),
      CrystalClick::WideTupleLeafColumn.new("flag", flag_values),
      CrystalClick::WideTupleLeafColumn.new("v6_again", v6_again_values),
    ] of CrystalClick::WideTupleLeafColumn
    type_name = "Tuple(v6 IPv6, id UUID, v4 IPv4, text String, id_again UUID, count UInt16, flag Bool, v6_again IPv6)"
    keys = [1_u64, 3_u64, 9_u64, 10_u64, 20_u64]
    streams = [
      "payload%2Ev6",
      "payload%2Eid",
      "payload%2Ev4",
      "payload%2Etext.size",
      "payload%2Etext",
      "payload%2Eid_again",
      "payload%2Ecount",
      "payload%2Eflag",
      "payload%2Ev6_again",
    ]
    expected_raw = {
      "payload%2Ev6"        => w99_writer_tuple_ipv6_bytes(v6_values),
      "payload%2Eid"        => w99_writer_tuple_uuid_bytes(id_values),
      "payload%2Ev4"        => w99_writer_tuple_ipv4_bytes(v4_values),
      "payload%2Etext.size" => w99_writer_tuple_u64_bytes(text_values.map { |value| value.bytesize.to_u64 }),
      "payload%2Etext"      => text_values.map { |value| value.to_slice.to_a }.flatten,
      "payload%2Eid_again"  => w99_writer_tuple_uuid_bytes(id_again_values),
      "payload%2Ecount"     => [1_u8, 0_u8, 2_u8, 0_u8, 3_u8, 0_u8, 4_u8, 0_u8, 5_u8, 0_u8],
      "payload%2Eflag"      => [0_u8, 1_u8, 0_u8, 0_u8, 1_u8],
      "payload%2Ev6_again"  => w99_writer_tuple_ipv6_bytes(v6_again_values),
    }
    parent = File.tempname("crystal-click-wide-writer-identifier-tuple-w99")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")

    begin
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns,
        rows_per_mark: 2
      ).should eq(destination)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n#{streams.size} substreams for column `payload`:\n#{streams.map { |stream| "\t#{stream}\n" }.join}"
      )

      w99_writer_tuple_stream_bytes(destination, "pk").should eq(w99_writer_tuple_u64_bytes(keys))
      (["pk"] + streams).each do |stream|
        expected_rows = [2_u64, 2_u64, 1_u64, 0_u64]
        w99_writer_tuple_marks(destination, stream).map(&.[2]).should eq(expected_rows)
        if raw = expected_raw[stream]?
          w99_writer_tuple_stream_bytes(destination, stream).should eq(raw)
          checksum = CrystalClick::PartChecksums.open(destination).entries["#{CrystalClick::StreamName.hash(stream)}.bin"]
          checksum.uncompressed_size.not_nil!.should eq(raw.size.to_u64)
        end
      end
      w99_writer_tuple_marks(destination, "pk").map(&.[2]).should eq([2_u64, 2_u64, 1_u64, 0_u64])

      serialization = JSON.parse(File.read(File.join(destination, "serialization.json"))).as_h
      payload = serialization["columns"].as_a.find do |record|
        record.as_h["name"]?.try(&.as_s) == "payload"
      end.not_nil!.as_h
      payload["kind"].as_s.should eq("Default")
      payload["num_defaults"].as_i.should eq(0)
      payload["num_rows"].as_i.should eq(5)
      payload["subcolumns"].as_a.map { |record| record.as_h["num_defaults"].as_i }.should eq([1_i64, 1_i64, 1_i64, 1_i64, 1_i64, 0_i64, 3_i64, 1_i64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "retains fixed-width UUID and address streams for all-default leaves" do
    keys = [1_u64, 2_u64, 3_u64]
    columns = [
      CrystalClick::WideTupleLeafColumn.new("id", Array.new(3, CrystalClick::UUIDValue.new(0_u64, 0_u64))),
      CrystalClick::WideTupleLeafColumn.new("v4", Array.new(3, CrystalClick::IPv4Value.new(0_u32))),
      CrystalClick::WideTupleLeafColumn.new("v6", Array.new(3, CrystalClick::IPv6Value.new(0_u64, 0_u64))),
    ] of CrystalClick::WideTupleLeafColumn
    type_name = "Tuple(id UUID, v4 IPv4, v6 IPv6)"
    parent = File.tempname("crystal-click-wide-writer-identifier-defaults-w99")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")

    begin
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns,
        rows_per_mark: 2
      )

      {"payload%2Eid" => 16, "payload%2Ev4" => 4, "payload%2Ev6" => 16}.each do |stream, width|
        w99_writer_tuple_stream_bytes(destination, stream).should eq(Array.new(keys.size * width, 0_u8))
        w99_writer_tuple_marks(destination, stream).map(&.[2]).should eq([2_u64, 1_u64, 0_u64])
        checksum = CrystalClick::PartChecksums.open(destination).entries["#{CrystalClick::StreamName.hash(stream)}.bin"]
        checksum.uncompressed_size.not_nil!.should eq((keys.size * width).to_u64)
      end
      serialization = JSON.parse(File.read(File.join(destination, "serialization.json"))).as_h
      payload = serialization["columns"].as_a.find do |record|
        record.as_h["name"]?.try(&.as_s) == "payload"
      end.not_nil!.as_h
      payload["num_defaults"].as_i.should eq(3)
      payload["subcolumns"].as_a.map { |record| record.as_h["num_defaults"].as_i }.should eq([3_i64, 3_i64, 3_i64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects same-width nominal substitutions, unsupported later leaves and row mismatch before staging" do
    parent = File.tempname("crystal-click-wide-writer-identifier-invalid-w99")
    Dir.mkdir(parent)
    factory_calls = [] of Int32
    copy_calls = [] of Int32
    factory = w99_writer_tuple_counting_factory(factory_calls)
    copy_strings = w99_writer_tuple_counting_string_copy(copy_calls)
    keys = [1_u64, 2_u64]

    begin
      cases = [
        {"Tuple(address IPv6)", [CrystalClick::WideTupleLeafColumn.new("address", [CrystalClick::UUIDValue.new(1_u64, 2_u64), CrystalClick::UUIDValue.new(3_u64, 4_u64)])] of CrystalClick::WideTupleLeafColumn, "Tuple leaf buffers do not match schema order"},
        {"Tuple(address UInt32)", [CrystalClick::WideTupleLeafColumn.new("address", [CrystalClick::IPv4Value.new(1_u32), CrystalClick::IPv4Value.new(2_u32)])] of CrystalClick::WideTupleLeafColumn, "Tuple leaf buffers do not match schema order"},
        {"Tuple(address IPv4)", [CrystalClick::WideTupleLeafColumn.new("address", [1_u32, 2_u32])] of CrystalClick::WideTupleLeafColumn, "Tuple leaf buffers do not match schema order"},
      ]
      cases.each_with_index do |(type_name, columns, message), index|
        expect_raises(ArgumentError, message) do
          CrystalClick::WidePartWriter.w99_test_write_with_stage_factory(
            File.join(parent, "nominal-#{index}"), "pk", keys.to_unsafe.to_slice(keys.size),
            "payload", type_name, columns, 1, factory, copy_strings
          )
        end
      end

      later_unsupported = [
        CrystalClick::WideTupleLeafColumn.new("id", [CrystalClick::UUIDValue.new(1_u64, 2_u64), CrystalClick::UUIDValue.new(3_u64, 4_u64)]),
        CrystalClick::WideTupleLeafColumn.new("day", [0_u64, 1_u64]),
      ] of CrystalClick::WideTupleLeafColumn
      expect_raises(ArgumentError, "unsupported compositional Tuple type") do
        CrystalClick::WidePartWriter.w99_test_write_with_stage_factory(
          File.join(parent, "later-unsupported"), "pk", keys.to_unsafe.to_slice(keys.size),
          "payload", "Tuple(id UUID, day Date)", later_unsupported, 1, factory, copy_strings
        )
      end

      wrong_rows = [
        CrystalClick::WideTupleLeafColumn.new("id", [CrystalClick::UUIDValue.new(1_u64, 2_u64)]),
      ] of CrystalClick::WideTupleLeafColumn
      expect_raises(ArgumentError, "Tuple leaf buffers must match key row count") do
        CrystalClick::WidePartWriter.w99_test_write_with_stage_factory(
          File.join(parent, "wrong-rows"), "pk", keys.to_unsafe.to_slice(keys.size),
          "payload", "Tuple(id UUID)", wrong_rows, 1, factory, copy_strings
        )
      end

      factory_calls.should be_empty
      copy_calls.should be_empty
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "charges fixed-width identifier leaves with the UInt64 keys before invoking the stage factory" do
    parent = File.tempname("crystal-click-wide-writer-identifier-budget-w99")
    Dir.mkdir(parent)
    factory_calls = [] of Int32
    copy_calls = [] of Int32
    factory = w99_writer_tuple_counting_factory(factory_calls)
    copy_strings = w99_writer_tuple_counting_string_copy(copy_calls)
    row_count = 2_097_152
    keys = Array(UInt64).new(row_count) { |index| index.to_u64 + 1_u64 }
    values = Array(CrystalClick::UUIDValue).new(row_count) { CrystalClick::UUIDValue.new(0_u64, 0_u64) }
    columns = [CrystalClick::WideTupleLeafColumn.new("id", values)] of CrystalClick::WideTupleLeafColumn
    destination = File.join(parent, "over-budget")

    begin
      expect_raises(ArgumentError, "Tuple materialization charge exceeds limit") do
        CrystalClick::WidePartWriter.w99_test_write_with_stage_factory(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", "Tuple(id UUID)",
          columns, 8192, factory, copy_strings
        )
      end
      factory_calls.should be_empty
      copy_calls.should be_empty
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects validly checksummed UUID, IPv4 and IPv6 payload mutations before publication" do
    keys = [1_u64, 2_u64]
    cases = [
      {"id", "UUID", "payload%2Eid", 0, 0x76_u8, [CrystalClick::WideTupleLeafColumn.new("id", [CrystalClick::UUIDValue.new(0x0011223344556677_u64, 0x8899aabbccddeeff_u64), CrystalClick::UUIDValue.new(0x123456789abcdef0_u64, 0x0fedcba987654321_u64)])] of CrystalClick::WideTupleLeafColumn},
      {"address", "IPv4", "payload%2Eaddress", 0, 0_u8, [CrystalClick::WideTupleLeafColumn.new("address", [CrystalClick::IPv4Value.from_octets(192_u8, 0_u8, 2_u8, 1_u8), CrystalClick::IPv4Value.from_octets(203_u8, 0_u8, 113_u8, 9_u8)])] of CrystalClick::WideTupleLeafColumn},
      {"address", "IPv6", "payload%2Eaddress", 0, 0x21_u8, [CrystalClick::WideTupleLeafColumn.new("address", [CrystalClick::IPv6Value.new(0x20010db800010203_u64, 0x0405060708090a0b_u64), CrystalClick::IPv6Value.new(0x20010db800010204_u64, 0x0c0d0e0f10111213_u64)])] of CrystalClick::WideTupleLeafColumn},
    ]

    cases.each_with_index do |(field_name, field_type, stream, offset, replacement, columns), index|
      parent = File.tempname("crystal-click-wide-writer-identifier-corrupt-w99")
      Dir.mkdir(parent)
      canonical = File.join(parent, "canonical")
      mutated = File.join(parent, "mutated-stage")
      type_name = "Tuple(#{field_name} #{field_type})"

      begin
        CrystalClick::WidePartWriter.write_uint64_tuple_pair(
          canonical, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns,
          rows_per_mark: 2
        )
        CrystalClick::WidePartWriter.w99_test_validate_tuple_stage(
          canonical, "pk", keys, "payload", type_name, columns, 2
        )

        FileUtils.cp_r(canonical, mutated)
        w99_writer_tuple_replace_stream_byte(mutated, stream, offset, replacement)

        mutated_part = CrystalClick::WidePart.open_typed(mutated, "payload")
        mutated_data = mutated_part.read_tuple_mark_range("payload", 0, 1)
        mutated_data.row_count.should eq(2)

        expect_raises(CrystalClick::CorruptPartError, "staged Tuple identifier leaf readback differs") do
          CrystalClick::WidePartWriter.w99_test_validate_tuple_stage(
            mutated, "pk", keys, "payload", type_name, columns, 2
          )
        end
        File.exists?(File.join(parent, "not-published")).should be_false
        Dir.children(parent).sort.should eq(["canonical", "mutated-stage"])
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
