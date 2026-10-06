require "./spec_helper"
require "file_utils"

private def w189_write_varuint(io : IO, value : UInt64) : Nil
  while value >= 0x80_u64
    io.write_byte(((value & 0x7f_u64) | 0x80_u64).to_u8)
    value >>= 7
  end
  io.write_byte(value.to_u8)
end

private def w189_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  hash.each do |word|
    8.times { |byte| io.write_byte(((word >> (byte * 8)) & 0xff_u64).to_u8) }
  end
end

# Mutations below own a complete temporary fixture. Refresh its manifest rather
# than bypassing the reader's file-presence/size checks. Block checksums remain
# independently verified; whole-file hashes are not authenticated by this API.
private def w189_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w189_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w189_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w189_write_varuint(payload, bytes.size.to_u64)
    w189_write_hash(payload, CrystalClick::CityHashV1.file_hash(bytes))
    payload.write_byte(entry.compressed ? 1_u8 : 0_u8)
    if entry.compressed
      raw = bytes.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(bytes)
      w189_write_varuint(payload, raw.size.to_u64)
      w189_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    end
  end
  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(CrystalClick::CompressedMarkWriter.encode_all(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), output.to_slice)
end

# Framing is not an occurrence-schedule certificate: a valid compact frame
# may still disagree with the enclosing Array sizes. This independent control
# deliberately normalizes such a frame before invoking the existing visitor.
describe "W189 compact framing versus enclosing typed-Dynamic schedule" do
  it "owns BASIC/COMPACT mode independently per physical lane, including zero-selection header validation" do
    dynamic = CrystalClick::BinaryDataType.dynamic(0)
    schema = CrystalClick::ObjectDocumentSchema.new({"left" => dynamic, "right" => dynamic})
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    empty_roster = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures, schema.typed_paths, {"left" => empty_roster, "right" => empty_roster},
    )
    document = CrystalClick::ObjectDocument.new({
      "left"  => CrystalClick::BinaryValue.dynamic(dynamic, nil),
      "right" => CrystalClick::BinaryValue.dynamic(dynamic, nil),
    })
    parent = File.tempname("crystal-click-w189-mixed-lane-modes-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        part, "pk", Slice[1_u64, 2_u64], "payload", schema, plan,
        [[document, document] of CrystalClick::ObjectDocument],
        rows_per_mark: 2, mode: 1_u64, frame_bytes: 64,
      )
      physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
      right = physical.typed_dynamic("right")
      role = "root.discriminators"
      bytes = Bytes[0, 0, 0, 0, 0, 0, 0, 0, 255, 255]
      # Rebuild the body, block checksums, marks and manifest, rather than
      # flipping the mode on an incompatible physical representation.
      basic = CrystalClick::CompressedMarkWriter.encode(
        bytes, [8_u64, 10_u64], [2_u64], prefix_size: 8, frame_bytes: 64)
      File.write(File.join(part, right.data_file_for(role, hashed: true)), basic.data)
      File.write(File.join(part, right.marks_file_for(role, hashed: true)), basic.marks)
      w189_refresh_checksums(part)
      rows = CrystalClick::ObjectDocumentFileReader.read(part, "payload", schema.typed_paths, hashed: true)
      rows.size.should eq(1)
      rows[0].size.should eq(2)
      rows[0].each do |value|
        value.value_for("left").is_null?.should be_true
        value.value_for("right").is_null?.should be_true
      end
      CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, first_mark: 1, mark_count: 0, hashed: true).should be_empty

      bytes[0] = 2_u8
      invalid = CrystalClick::CompressedMarkWriter.encode(
        bytes, [8_u64, 10_u64], [2_u64], prefix_size: 8, frame_bytes: 64)
      File.write(File.join(part, right.data_file_for(role, hashed: true)), invalid.data)
      w189_refresh_checksums(part)
      expect_raises(CrystalClick::CorruptPartError, "unknown typed Dynamic discriminator mode") do
        CrystalClick::ObjectDocumentFileReader.read(
          part, "payload", schema.typed_paths, first_mark: 1, mark_count: 0, hashed: true)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects an enormous valid uniform count under the borrowed byte budget before expansion" do
    role = "root.discriminators"
    # Int32::MAX logical NULL tags fit in a seven-byte positive body. The
    # count is within the supported domain, so the byte budget is the guard.
    physical = Bytes[1, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 7, 1, 255]
    limits = CrystalClick::BinaryCodecLimits.new(1, 8, 2, 17)
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_read([{role, 8, 2}], budget)
    expect_raises(CrystalClick::CorruptPartError, "binary codec byte limit exceeded") do
      CrystalClick::BinaryBulkDiscriminatorFramingAdapter.read_lane(
        role, physical, [8_u64, 15_u64], 8, budget,
      )
    end
    budget.wire_byte_count.should eq(8)
  end

  it "shares expansion accounting across two independently framed lanes" do
    physical = Bytes[1, 0, 0, 0, 0, 0, 0, 0, 3, 1, 255]
    [21, 22].each do |max_bytes|
      limits = CrystalClick::BinaryCodecLimits.new(1, 8, 4, max_bytes)
      budget = CrystalClick::BinaryCodecBudget.new(limits)
      CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_read(
        [{"left.discriminators", 8, 2}, {"right.discriminators", 8, 2}], budget,
      )
      left, _, _ = CrystalClick::BinaryBulkDiscriminatorFramingAdapter.read_lane(
        "left.discriminators", physical, [8_u64, 11_u64], 8, budget,
      )
      left.should eq(Bytes[255, 255, 255])
      if max_bytes == 21
        expect_raises(CrystalClick::CorruptPartError, "binary codec byte limit exceeded") do
          CrystalClick::BinaryBulkDiscriminatorFramingAdapter.read_lane(
            "right.discriminators", physical, [8_u64, 11_u64], 8, budget,
          )
        end
        budget.wire_byte_count.should eq(19)
      else
        right, _, _ = CrystalClick::BinaryBulkDiscriminatorFramingAdapter.read_lane(
          "right.discriminators", physical, [8_u64, 11_u64], 8, budget,
        )
        right.should eq(Bytes[255, 255, 255])
        budget.wire_byte_count.should eq(22)
      end
      budget.element_count.should eq(4)
    end
  end

  it "rejects a valid positive uniform frame with excess Array child tags" do
    dynamic = CrystalClick::BinaryDataType.dynamic(0)
    array = CrystalClick::BinaryDataType.array(dynamic)
    original = CrystalClick::BinaryDynamicBulkCodec.encode(
      array,
      {"root.elements" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
      [[CrystalClick::BinaryValue.array(array, [
        CrystalClick::BinaryValue.dynamic(dynamic, nil),
      ] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue],
    )
    role = "root.elements.discriminators"
    original.data.stream(role).byte_size.should eq(1)

    # UInt64 COMPACT mode, two uniform NULL occurrences. The frame itself is
    # valid, but the independent Array-size lane schedules only one child.
    physical = Bytes[1, 0, 0, 0, 0, 0, 0, 0, 2, 1, 255]
    offsets = [8_u64, 11_u64]
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_read(
      [{role, 8_i32, offsets.size}], budget,
    )
    bytes, normalized_offsets, prefix = CrystalClick::BinaryBulkDiscriminatorFramingAdapter.read_lane(
      role, physical, offsets, 8, budget,
    )
    bytes.should eq(Bytes[255, 255])
    normalized_offsets.should eq([0_u64, 2_u64])
    prefix.should eq(0)
    lanes = Hash(String, CrystalClick::BinaryBulkStream).new
    original.data.roles.each do |key|
      lanes[key] = key == role ? CrystalClick::BinaryBulkStream.new(bytes, normalized_offsets) : original.data.stream(key)
    end
    hostile = CrystalClick::BinaryDynamicBulkStreams.new(
      original.structures, CrystalClick::BinaryBulkStreams.new(1, lanes),
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(array, hostile, [1_u64])
    end
  end

  it "rejects a valid empty physical interval when Array sizes require a child" do
    dynamic = CrystalClick::BinaryDataType.dynamic(0)
    array = CrystalClick::BinaryDataType.array(dynamic)
    original = CrystalClick::BinaryDynamicBulkCodec.encode(
      array,
      {"root.elements" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
      [[CrystalClick::BinaryValue.array(array, [
        CrystalClick::BinaryValue.dynamic(dynamic, nil),
      ] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue],
    )
    role = "root.elements.discriminators"
    physical = Bytes[1, 0, 0, 0, 0, 0, 0, 0]
    offsets = [8_u64, 8_u64]
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_read(
      [{role, 8_i32, offsets.size}], budget,
    )
    bytes, normalized_offsets, _prefix = CrystalClick::BinaryBulkDiscriminatorFramingAdapter.read_lane(
      role, physical, offsets, 8, budget,
    )
    bytes.should be_empty
    lanes = Hash(String, CrystalClick::BinaryBulkStream).new
    original.data.roles.each do |key|
      lanes[key] = key == role ? CrystalClick::BinaryBulkStream.new(bytes, normalized_offsets) : original.data.stream(key)
    end
    hostile = CrystalClick::BinaryDynamicBulkStreams.new(
      original.structures, CrystalClick::BinaryBulkStreams.new(1, lanes),
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(array, hostile, [1_u64])
    end
  end
end
