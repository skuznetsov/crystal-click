require "./spec_helper"

WORKSPACE_ZSTD_DATA  = File.expand_path("../test/fixtures/public/wide_u64_zstd_cmrk2/part/*.bin", __DIR__)
WORKSPACE_DELTA_DATA = File.expand_path("../test/fixtures/public/wide_u64_delta_zstd/part/*.bin", __DIR__)

def workspace_write_u32(bytes : Bytes, offset : Int, value : Int)
  4.times do |index|
    bytes[offset + index] = ((value >> (index * 8)) & 0xff).to_u8
  end
end

def workspace_lz4_payload(output : Bytes) : Bytes
  extension = output.size - 15
  payload = if output.size < 15
              Bytes.new(1 + output.size)
            else
              Bytes.new(2 + output.size)
            end
  payload[0] = output.size < 15 ? (output.size << 4).to_u8 : 0xf0_u8
  if output.size >= 15
    payload[1] = extension.to_u8
    output.copy_to(payload[2, output.size])
  else
    output.copy_to(payload[1, output.size])
  end
  payload
end

def workspace_lz4_frame(output : Bytes) : Bytes
  payload = workspace_lz4_payload(output)
  frame = Bytes.new(16 + 9 + payload.size, 0_u8)
  frame[16] = CrystalClick::CompressedBlock::METHOD_LZ4
  workspace_write_u32(frame, 17, 9 + payload.size)
  workspace_write_u32(frame, 21, output.size)
  payload.copy_to(frame[25, payload.size])
  frame
end

def workspace_concat(first : Bytes, second : Bytes) : Bytes
  combined = Bytes.new(first.size + second.size)
  first.copy_to(combined)
  second.copy_to(combined[first.size, second.size])
  combined
end

def workspace_first_frame(bytes : Bytes) : CrystalClick::CompressedBlock::Frame
  CrystalClick::CompressedBlock.decode_frame(bytes, 0_i64)
end

describe "reusable decompression workspace" do
  it "decodes LZ4 into one reused buffer and exposes borrowed lifetime" do
    first_bytes = Bytes[0x61_u8, 0x62_u8, 0x63_u8]
    second_bytes = Bytes[0x78_u8, 0x79_u8, 0x7a_u8]
    data = workspace_concat(workspace_lz4_frame(first_bytes), workspace_lz4_frame(second_bytes))
    workspace = CrystalClick::CompressedBlock::DecodeWorkspace.new

    first = CrystalClick::CompressedBlock.decode_frame_into(data, 0_i64, workspace)
    first.output.should eq(first_bytes)
    first_address = first.output.to_unsafe
    first_copy = first.output.dup

    second = CrystalClick::CompressedBlock.decode_frame_into(data, first.end_offset, workspace)
    second.output.should eq(second_bytes)
    second.output.to_unsafe.should eq(first_address)
    first.output.should eq(second_bytes)
    first_copy.should eq(first_bytes)

    owned_first = CrystalClick::CompressedBlock.decode_frame(data, 0_i64)
    owned_second = CrystalClick::CompressedBlock.decode_frame(data, owned_first.end_offset)
    owned_first.output.should eq(first_bytes)
    owned_second.output.should eq(second_bytes)
    owned_first.output.to_unsafe.should_not eq(owned_second.output.to_unsafe)
  end

  it "keeps the high-water allocation after growth" do
    small = Bytes[0x01_u8, 0x02_u8, 0x03_u8]
    large = Bytes.new(16) { |index| (index + 16).to_u8 }
    data = workspace_concat(workspace_lz4_frame(small), workspace_lz4_frame(large))
    data = workspace_concat(data, workspace_lz4_frame(small))
    workspace = CrystalClick::CompressedBlock::DecodeWorkspace.new

    first = CrystalClick::CompressedBlock.decode_frame_into(data, 0_i64, workspace)
    second = CrystalClick::CompressedBlock.decode_frame_into(data, first.end_offset, workspace)
    third = CrystalClick::CompressedBlock.decode_frame_into(data, second.end_offset, workspace)

    second.output.size.should eq(large.size)
    third.output.size.should eq(small.size)
    third.output.to_unsafe.should eq(second.output.to_unsafe)
    third.output.should eq(small)
  end

  it "decodes direct ZSTD and exact Multiple frames through the workspace" do
    zstd_data = File.read(Dir.glob(WORKSPACE_ZSTD_DATA).first.not_nil!).to_slice
    zstd_owned = workspace_first_frame(zstd_data)
    zstd_workspace = CrystalClick::CompressedBlock::DecodeWorkspace.new
    zstd_borrowed = CrystalClick::CompressedBlock.decode_frame_into(zstd_data, 0_i64, zstd_workspace)
    zstd_borrowed.output.should eq(zstd_owned.output)
    zstd_borrowed.output.to_unsafe.should_not eq(zstd_data.to_unsafe)
    zstd_address = zstd_borrowed.output.to_unsafe
    zstd_next = CrystalClick::CompressedBlock.decode_frame_into(zstd_data, zstd_borrowed.end_offset, zstd_workspace)
    zstd_next.output.to_unsafe.should eq(zstd_address)

    delta_data = File.read(Dir.glob(WORKSPACE_DELTA_DATA).first.not_nil!).to_slice
    delta_owned = workspace_first_frame(delta_data)
    delta_workspace = CrystalClick::CompressedBlock::DecodeWorkspace.new
    delta_borrowed = CrystalClick::CompressedBlock.decode_frame_into(delta_data, 0_i64, delta_workspace)
    delta_borrowed.output.should eq(delta_owned.output)
    delta_borrowed.output.size.should eq(4096)
    next_borrowed = CrystalClick::CompressedBlock.decode_frame_into(delta_data, delta_borrowed.end_offset, delta_workspace)
    next_borrowed.output.size.should eq(delta_borrowed.output.size)
    next_borrowed.output.to_unsafe.should eq(delta_borrowed.output.to_unsafe)
  end

  it "keeps destination-oriented codec primitives exact-sized" do
    input = Bytes[0x12_u8, 0x61_u8, 0x01_u8, 0x00_u8]
    destination = Bytes.new(7)
    decoded = CrystalClick::LZ4.decode_into(input, destination, 7)
    decoded.should eq(Bytes[0x61_u8, 0x61_u8, 0x61_u8, 0x61_u8, 0x61_u8, 0x61_u8, 0x61_u8])
    decoded.to_unsafe.should eq(destination.to_unsafe)

    expect_raises(CrystalClick::CorruptPartError, "LZ4 destination is too small") do
      CrystalClick::LZ4.decode_into(input, Bytes.new(6), 7)
    end
    expect_raises(CrystalClick::BoundsError, "LZ4 destination must be writable") do
      CrystalClick::LZ4.decode_into(input, Slice(UInt8).new(7, read_only: true), 7)
    end
    expect_raises(CrystalClick::BoundsError, "ZSTD destination must be writable") do
      CrystalClick::ZSTD.decode_into(Bytes[1_u8], Slice(UInt8).new(1, read_only: true), 1, 1_i64)
    end
  end
end
