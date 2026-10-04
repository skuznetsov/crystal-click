require "./spec_helper"

private def w151pa_empty_structures : CrystalClick::ObjectDynamicStructureSet
  CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
end

private def w151pa_with_parent(&)
  parent = File.tempname("crystal-click-w151-variant-prefix-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w151pa_write_part(
  parent : String,
  type : CrystalClick::BinaryDataType,
  values : Array(Array(CrystalClick::BinaryValue)),
  basename : String,
  rows_per_mark : Int = 1,
) : Tuple(String, CrystalClick::ObjectDocumentSchema, CrystalClick::ObjectDocumentPlan)
  schema = CrystalClick::ObjectDocumentSchema.new({"v" => type})
  plan = CrystalClick::ObjectDocumentPlan.new(w151pa_empty_structures, schema.typed_paths)
  granules = Array(Array(CrystalClick::ObjectDocument)).new(values.size)
  keys = [] of UInt64
  next_key = 1_u64
  values.each do |mark|
    documents = [] of CrystalClick::ObjectDocument
    mark.each do |value|
      documents << CrystalClick::ObjectDocument.new({"v" => value})
      keys << next_key
      next_key += 1_u64
    end
    granules << documents
  end
  part = CrystalClick::WidePartWriter.write_uint64_object_pair(
    File.join(parent, basename),
    "pk",
    Slice(UInt64).new(keys.size) { |index| keys[index] },
    "payload",
    schema,
    plan,
    granules,
    rows_per_mark: rows_per_mark,
    frame_bytes: 4096,
  )
  {part, schema, plan}
end

private def w151pa_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times do |index|
    bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
  end
end

private def w151pa_write_u64_file(path : String, offset : Int, value : UInt64) : Nil
  bytes = Bytes.new(8)
  w151pa_write_u64(bytes, 0, value)
  File.open(path, "r+b") do |io|
    io.seek(offset)
    io.write(bytes)
  end
end

private def w151pa_corrupt_frame_raw_byte(path : String, raw_offset : Int, value : UInt8) : Nil
  frame = File.read(path).to_slice.dup
  CrystalClick::CompressedBlock::METHOD_LZ4.should eq(frame[16])
  compressed_size = frame[17].to_u32 |
                    (frame[18].to_u32 << 8) |
                    (frame[19].to_u32 << 16) |
                    (frame[20].to_u32 << 24)
  raw_size = frame[21].to_u32 |
             (frame[22].to_u32 << 8) |
             (frame[23].to_u32 << 16) |
             (frame[24].to_u32 << 24)
  raw_offset.should be < raw_size
  compressed_size.to_i.should eq(frame.size - CrystalClick::CompressedBlock::CHECKSUM_SIZE)

  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  token = frame[cursor]
  literal_count = (token >> 4).to_i
  cursor += 1
  if literal_count == 15
    loop do
      extension = frame[cursor]
      cursor += 1
      literal_count += extension.to_i
      break if extension < 255
    end
  end
  # The production part writer deliberately emits literal-only LZ4 frames.
  literal_count.should eq(raw_size)
  frame[cursor + raw_offset] = value

  checksum = CrystalClick::CityHashV1.hash128(frame[CrystalClick::CompressedBlock::CHECKSUM_SIZE, compressed_size.to_i])
  w151pa_write_u64(frame, 0, checksum[0])
  w151pa_write_u64(frame, 8, checksum[1])
  File.write(path, frame)
end

private def w151pa_mutate_lane(
  part : String,
  logical_name : String,
  raw_offset : Int,
  value : UInt8,
) : Nil
  data_name = CrystalClick::StreamName.hash(logical_name) + ".bin"
  w151pa_corrupt_frame_raw_byte(File.join(part, data_name), raw_offset, value)
end

private def w151pa_variant_with_lc_arm : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.variant([
    CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String")),
    CrystalClick::BinaryDataType.primitive("UInt64"),
  ] of CrystalClick::BinaryDataType)
end

private def w151pa_uint64_choice(type : CrystalClick::BinaryDataType, value : UInt64) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.uint64(value))
end

describe "W151 declared Variant physical prefix adversaries" do
  it "retains a BASIC header for an unused nested discriminator lane in a real Wide part" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    inner = CrystalClick::BinaryDataType.variant([string, uint64] of CrystalClick::BinaryDataType)
    array = CrystalClick::BinaryDataType.array(inner)
    outer = CrystalClick::BinaryDataType.variant([array, uint64] of CrystalClick::BinaryDataType)
    values = [[
      CrystalClick::BinaryValue.variant(outer, 1, CrystalClick::BinaryValue.uint64(17_u64)),
      CrystalClick::BinaryValue.variant(outer, 1, CrystalClick::BinaryValue.uint64(18_u64)),
    ]] of Array(CrystalClick::BinaryValue)

    w151pa_with_parent do |parent|
      part, schema, plan = w151pa_write_part(parent, outer, values, "unused_nested", rows_per_mark: 2)
      physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
      nested_discriminators = physical.typed("v").stream_name_for("root.arm.0.elements.discriminators")
      data_name = CrystalClick::StreamName.hash(nested_discriminators) + ".bin"
      marks_name = CrystalClick::StreamName.hash(nested_discriminators) + ".mrk2"
      source = CrystalClick::PartStreamSource.new(part)
      window = source.read_window(data_name, marks_name, 0, 1, 8)
      window.prefix_size.should eq(8)
      window.bytes.should eq(Bytes.new(8, 0_u8))
      window.offsets.should eq([8_u64, 8_u64])

      decoded = CrystalClick::ObjectDocumentFileReader.read(part, "payload", schema.typed_paths, hashed: true)
      decoded[0][0].value_for("v").variant_index?.should eq(1_u8)
      decoded[0][1].value_for("v").variant_child?.not_nil!.as_uint64.should eq(18_u64)
    end
  end

  it "rejects a non-BASIC COMPACT mode header in a physical typed discriminator" do
    type = w151pa_variant_with_lc_arm
    values = [
      [w151pa_uint64_choice(type, 10_u64)],
      [w151pa_uint64_choice(type, 20_u64)],
      [w151pa_uint64_choice(type, 30_u64)],
    ] of Array(CrystalClick::BinaryValue)

    w151pa_with_parent do |parent|
      part, schema, plan = w151pa_write_part(parent, type, values, "compact_header")
      physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
      discriminator = physical.typed("v").stream_name_for("root.discriminators")
      # BASIC Variant starts with UInt64(0). A nonzero mode word is not a
      # RowBinary discriminator and must not be accepted as a physical lane.
      w151pa_mutate_lane(part, discriminator, 0, 1_u8)

      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentFileReader.read(
          part, "payload", schema.typed_paths, first_mark: 1, mark_count: 1, hashed: true
        )
      end
      error.message.not_nil!.should contain("BASIC mode header")
    end
  end

  it "rejects an invalid discriminator in an unselected LC-bearing mark for middle and zero windows" do
    type = w151pa_variant_with_lc_arm
    values = [
      [w151pa_uint64_choice(type, 10_u64)],
      [w151pa_uint64_choice(type, 20_u64)],
      [w151pa_uint64_choice(type, 30_u64)],
    ] of Array(CrystalClick::BinaryValue)

    w151pa_with_parent do |parent|
      part, schema, plan = w151pa_write_part(parent, type, values, "invalid_unselected_tag")
      physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
      discriminator = physical.typed("v").stream_name_for("root.discriminators")
      # Corrupt mark 0, outside the selected middle and zero windows. Its tag
      # follows the physical eight-byte BASIC mode word.
      w151pa_mutate_lane(part, discriminator, 8, 2_u8)

      [
        {1, 1},
        {3, 0},
      ].each do |first_mark, mark_count|
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::ObjectDocumentFileReader.read(
            part,
            "payload",
            schema.typed_paths,
            first_mark: first_mark,
            mark_count: mark_count,
            hashed: true,
          )
        end
      end
    end
  end

  it "keeps plain non-LC Variant body reads selected-only while validating a selected tag" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    type = CrystalClick::BinaryDataType.variant([string, uint64] of CrystalClick::BinaryDataType)
    values = [
      [w151pa_uint64_choice(type, 10_u64)],
      [w151pa_uint64_choice(type, 20_u64)],
      [w151pa_uint64_choice(type, 30_u64)],
    ] of Array(CrystalClick::BinaryValue)

    w151pa_with_parent do |parent|
      part, schema, plan = w151pa_write_part(parent, type, values, "selected_only_body")
      physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
      discriminator = physical.typed("v").stream_name_for("root.discriminators")

      # Mark 0's row grid remains valid; only its discriminator body is bad.
      # Plain Variant does not require LC's full-state payload replay.
      w151pa_mutate_lane(part, discriminator, 8, 2_u8)

      middle = CrystalClick::ObjectDocumentFileReader.read(
        part,
        "payload",
        schema.typed_paths,
        first_mark: 1,
        mark_count: 1,
        hashed: true,
      )
      middle.size.should eq(1)
      middle[0][0].value_for("v").variant_child?.not_nil!.as_uint64.should eq(20_u64)

      CrystalClick::ObjectDocumentFileReader.read(
        part,
        "payload",
        schema.typed_paths,
        first_mark: 3,
        mark_count: 0,
        hashed: true,
      ).should be_empty

      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentFileReader.read(
          part,
          "payload",
          schema.typed_paths,
          first_mark: 0,
          mark_count: 1,
          hashed: true,
        )
      end
      error.message.should eq("Variant bulk discriminator is outside its arm roster")
    end
  end

  it "rejects an unselected non-LC Variant row-grid mismatch on middle and zero windows" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    type = CrystalClick::BinaryDataType.variant([string, uint64] of CrystalClick::BinaryDataType)
    values = [
      [w151pa_uint64_choice(type, 10_u64)],
      [w151pa_uint64_choice(type, 20_u64)],
      [w151pa_uint64_choice(type, 30_u64)],
    ] of Array(CrystalClick::BinaryValue)

    w151pa_with_parent do |parent|
      part, schema, plan = w151pa_write_part(parent, type, values, "invalid_unselected_grid")
      physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
      discriminator = physical.typed("v").stream_name_for("root.discriminators")
      marks = File.join(part, CrystalClick::StreamName.hash(discriminator) + ".mrk2")

      # Keep the mark record structurally valid but make its first mark's row
      # count disagree with the Object outer grid. This is all-grid metadata
      # validation, not a claim that plain non-LC Variant payloads are replayed.
      w151pa_write_u64_file(marks, 16, 2_u64)

      [
        {1, 1},
        {3, 0},
      ].each do |first_mark, mark_count|
        error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::ObjectDocumentFileReader.read(
            part,
            "payload",
            schema.typed_paths,
            first_mark: first_mark,
            mark_count: mark_count,
            hashed: true,
          )
        end
        error.message.should eq("physical lane row grid does not match the Object outer grid")
      end
    end
  end
end
