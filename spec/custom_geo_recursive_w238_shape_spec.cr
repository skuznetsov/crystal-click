require "./spec_helper"
require "file_utils"

private def w238s_custom(name : String) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.custom(name)
end

private def w238s_point(x : UInt64, y : UInt64) : CrystalClick::BinaryValue
  type = w238s_custom("Point")
  body = CrystalClick::BinaryValue.tuple(
    type.child_at(0),
    [CrystalClick::BinaryValue.float64_bits(x), CrystalClick::BinaryValue.float64_bits(y)] of CrystalClick::BinaryValue,
  )
  CrystalClick::BinaryValue.custom(type, body)
end

private def w238s_geo(type : CrystalClick::BinaryDataType, seed : UInt64) : CrystalClick::BinaryValue
  unless type.tag == CrystalClick::BinaryDataType::TAG_CUSTOM
    raise ArgumentError.new("W238 fixture requires a nominal Custom Geo child")
  end

  body_type = type.child_at(0)
  body = case body_type.tag
         when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
           CrystalClick::BinaryValue.tuple(
             body_type,
             [
               CrystalClick::BinaryValue.float64_bits(seed),
               CrystalClick::BinaryValue.float64_bits(seed &+ 1_u64),
             ] of CrystalClick::BinaryValue,
           )
         when CrystalClick::BinaryDataType::TAG_ARRAY
           child_type = body_type.child_at(0)
           children = if seed % 3_u64 == 0_u64
                        [] of CrystalClick::BinaryValue
                      elsif seed % 3_u64 == 1_u64
                        [w238s_geo(child_type, seed &+ 1_u64)] of CrystalClick::BinaryValue
                      else
                        [
                          w238s_geo(child_type, seed &+ 1_u64),
                          w238s_geo(child_type, seed &+ 2_u64),
                        ] of CrystalClick::BinaryValue
                      end
           CrystalClick::BinaryValue.array(body_type, children)
         else
           raise ArgumentError.new("unexpected Custom Geo body type in W238 fixture")
         end
  CrystalClick::BinaryValue.custom(type, body)
end

private def w238s_variant(
  type : CrystalClick::BinaryDataType,
  arm : Int,
  value : CrystalClick::BinaryValue,
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.variant(type, arm, value)
end

private def w238s_nested_record(
  type : CrystalClick::BinaryDataType,
  point : CrystalClick::BinaryValue,
  polygon : CrystalClick::BinaryValue,
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.tuple(
    type.child_at(0),
    [point, polygon] of CrystalClick::BinaryValue,
  )
end

private def w238s_row(
  type : CrystalClick::BinaryDataType,
  array_type : CrystalClick::BinaryDataType,
  array_items : Array(CrystalClick::BinaryValue),
  map_type : CrystalClick::BinaryDataType,
  map_items : Array(CrystalClick::BinaryValue),
  nullable_type : CrystalClick::BinaryDataType,
  nullable_value : CrystalClick::BinaryValue?,
  text : String,
  nested_type : CrystalClick::BinaryDataType,
  nested_records : Array(CrystalClick::BinaryValue),
  multipolygon_array_type : CrystalClick::BinaryDataType,
  multipolygons : Array(CrystalClick::BinaryValue),
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.tuple(
    type,
    [
      CrystalClick::BinaryValue.array(array_type, array_items),
      CrystalClick::BinaryValue.map(map_type, map_items),
      CrystalClick::BinaryValue.nullable(nullable_type, nullable_value),
      CrystalClick::BinaryValue.string(text),
      CrystalClick::BinaryValue.nested(nested_type, nested_records),
      CrystalClick::BinaryValue.array(multipolygon_array_type, multipolygons),
    ] of CrystalClick::BinaryValue,
  )
end

private def w238s_assert_value(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue) : Nil
  actual.type.name.should eq(expected.type.name)
  actual.is_null?.should eq(expected.is_null?)
  if actual.type.tag == CrystalClick::BinaryDataType::TAG_VARIANT
    actual.variant_index?.should eq(expected.variant_index?)
  end
  actual.byte_size.should eq(expected.byte_size)
  actual.byte_size.times do |index|
    actual.byte_at(index).should eq(expected.byte_at(index))
  end
  actual.child_count.should eq(expected.child_count)
  actual.child_count.times do |index|
    w238s_assert_value(actual.child_at(index), expected.child_at(index))
  end
end

private def w238s_assert_rows(
  actual : Array(Array(CrystalClick::BinaryValue)),
  expected : Array(Array(CrystalClick::BinaryValue)),
) : Nil
  actual.size.should eq(expected.size)
  actual.each_with_index do |mark, mark_index|
    mark.size.should eq(expected[mark_index].size)
    mark.each_with_index do |value, row_index|
      w238s_assert_value(value, expected[mark_index][row_index])
    end
  end
end

private class W238ShapePart
  getter root : String
  getter part : String
  getter type : CrystalClick::BinaryDataType
  getter marks : Array(Array(CrystalClick::BinaryValue))

  def initialize
    @root = File.tempname("crystal-click-w238-shape-")
    Dir.mkdir(@root)
    @part = File.join(@root, "all_1_1_0")

    point = w238s_custom("Point")
    polygon = w238s_custom("Polygon")
    multipolygon = w238s_custom("MultiPolygon")
    string = CrystalClick::BinaryDataType.primitive("String")
    variant = CrystalClick::BinaryDataType.variant(
      [point, polygon] of CrystalClick::BinaryDataType,
    )
    array_type = CrystalClick::BinaryDataType.array(variant)
    map_type = CrystalClick::BinaryDataType.map(string, polygon)
    nullable_type = CrystalClick::BinaryDataType.nullable(point)
    nested_type = CrystalClick::BinaryDataType.nested(
      [point, polygon] of CrystalClick::BinaryDataType,
      ["coordinate", "shape"] of String,
    )
    multipolygon_array_type = CrystalClick::BinaryDataType.array(multipolygon)
    @type = CrystalClick::BinaryDataType.tuple(
      [
        array_type,
        map_type,
        nullable_type,
        string,
        nested_type,
        multipolygon_array_type,
      ] of CrystalClick::BinaryDataType,
    )

    point_a = w238s_point(0x3ff0_0000_0000_0000_u64, 0x4000_0000_0000_0000_u64)
    point_b = w238s_point(0x4008_0000_0000_0000_u64, 0x4010_0000_0000_0000_u64)
    polygon_a = w238s_geo(polygon, 31_u64)
    polygon_b = w238s_geo(polygon, 32_u64)
    multipolygon_a = w238s_geo(multipolygon, 41_u64)
    multipolygon_b = w238s_geo(multipolygon, 44_u64)
    point_arm = 0
    polygon_arm = 1

    row_1 = w238s_row(
      @type, array_type, [] of CrystalClick::BinaryValue,
      map_type, [] of CrystalClick::BinaryValue,
      nullable_type, nil, "plain",
      nested_type, [] of CrystalClick::BinaryValue,
      multipolygon_array_type, [] of CrystalClick::BinaryValue,
    )
    row_2 = w238s_row(
      @type, array_type,
      [w238s_variant(variant, point_arm, point_a)] of CrystalClick::BinaryValue,
      map_type,
      [CrystalClick::BinaryValue.string("left"), polygon_a] of CrystalClick::BinaryValue,
      nullable_type, point_b, "",
      nested_type,
      [w238s_nested_record(nested_type, point_a, polygon_a)] of CrystalClick::BinaryValue,
      multipolygon_array_type, [multipolygon_a] of CrystalClick::BinaryValue,
    )
    row_3 = w238s_row(
      @type, array_type,
      [
        w238s_variant(variant, point_arm, point_b),
        w238s_variant(variant, polygon_arm, polygon_b),
      ] of CrystalClick::BinaryValue,
      map_type,
      [
        CrystalClick::BinaryValue.string("first"), polygon_a,
        CrystalClick::BinaryValue.string("second"), polygon_b,
      ] of CrystalClick::BinaryValue,
      nullable_type, nil, "a\u0000b",
      nested_type,
      [
        w238s_nested_record(nested_type, point_a, polygon_b),
        w238s_nested_record(nested_type, point_b, polygon_a),
      ] of CrystalClick::BinaryValue,
      multipolygon_array_type, [multipolygon_a, multipolygon_b] of CrystalClick::BinaryValue,
    )
    row_4 = w238s_row(
      @type, array_type, [] of CrystalClick::BinaryValue,
      map_type, [] of CrystalClick::BinaryValue,
      nullable_type, point_a, "tail",
      nested_type, [] of CrystalClick::BinaryValue,
      multipolygon_array_type, [] of CrystalClick::BinaryValue,
    )
    row_5 = w238s_row(
      @type, array_type,
      [w238s_variant(variant, polygon_arm, polygon_a)] of CrystalClick::BinaryValue,
      map_type,
      [
        CrystalClick::BinaryValue.string("third"), polygon_b,
        CrystalClick::BinaryValue.string("fourth"), polygon_a,
      ] of CrystalClick::BinaryValue,
      nullable_type, point_b, "",
      nested_type,
      [w238s_nested_record(nested_type, point_b, polygon_b)] of CrystalClick::BinaryValue,
      multipolygon_array_type, [multipolygon_b] of CrystalClick::BinaryValue,
    )
    @marks = [
      [row_1, row_2] of CrystalClick::BinaryValue,
      [row_3, row_4] of CrystalClick::BinaryValue,
      [row_5] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    keys = [11_u64, 22_u64, 33_u64, 44_u64, 55_u64]
    begin
      CrystalClick::WidePartWriter.write_uint64_custom_geo_bulk_part(
        @part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "v",
        @type,
        @marks,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
        rows_per_mark: 2,
        frame_bytes: 4096,
      )
    rescue ex
      FileUtils.rm_rf(@root)
      raise ex
    end
  end

  def close : Nil
    FileUtils.rm_rf(@root) if Dir.exists?(@root)
  end
end

private def w238s_write_u32_at(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
end

private def w238s_write_u64_at(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w238s_write_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w238s_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w238s_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  w238s_write_u64(io, hash[0])
  w238s_write_u64(io, hash[1])
end

private def w238s_literal_lz4_frame(raw : Bytes) : Bytes
  raise ArgumentError.new("cannot encode an empty W238 LZ4 frame") if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w238s_write_u32_at(frame, header + 1, compressed_size.to_u32)
  w238s_write_u32_at(frame, header + 5, raw.size.to_u32)

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
  w238s_write_u64_at(frame, 0, checksum[0])
  w238s_write_u64_at(frame, 8, checksum[1])
  frame
end

private def w238s_refresh_checksums!(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w238s_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w238s_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w238s_write_varuint(payload, file_bytes.size.to_u64)
    w238s_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = file_bytes.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w238s_write_varuint(payload, raw.size.to_u64)
      w238s_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(w238s_literal_lz4_frame(payload.to_slice))
  end
end

private def w238s_corrupt_role_byte!(
  part : String,
  type : CrystalClick::BinaryDataType,
  role : String,
  offset : Int,
  expected : UInt8,
  replacement_byte : UInt8,
) : Nil
  physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, "v")
  data_path = File.join(part, physical.data_file_for(role, true))
  encoded = File.read(data_path).to_slice
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, 0_i64)
  frame.end_offset.should eq(encoded.size.to_i64)
  raw = frame.output.dup
  raw[offset].should eq(expected)
  raw[offset] = replacement_byte
  replacement = w238s_literal_lz4_frame(raw)
  replacement.size.should eq(encoded.size)
  File.write(data_path, replacement)
  w238s_refresh_checksums!(part)
end

private def w238s_assert_rejected_before_callback!(part : String, start_row : UInt64) : Nil
  callbacks = 0
  expect_raises(CrystalClick::CorruptPartError) do
    table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
    table.scan_typed_window(start_row, 1) { |_batch| callbacks += 1 }
  end
  callbacks.should eq(0)
end

private def w238s_check_late_corruption(
  label : String,
  role : String,
  offset : Int32,
  expected : UInt8,
  replacement_byte : UInt8,
) : Nil
  fixture = W238ShapePart.new
  begin
    corruption_dir = File.join(fixture.root, label)
    FileUtils.mkdir_p(corruption_dir)
    bad_part = File.join(corruption_dir, "all_1_1_0")
    FileUtils.cp_r(fixture.part, bad_part)
    w238s_corrupt_role_byte!(
      bad_part, fixture.type, role, offset, expected, replacement_byte
    )
    w238s_assert_rejected_before_callback!(bad_part, 0_u64)
    w238s_assert_rejected_before_callback!(bad_part, 5_u64)
  ensure
    fixture.close
  end
end

describe "W238 nominal Custom Geo recursive part shape validation" do
  it "publishes and reads variable recursive shapes on one parent grid with no nominal lanes" do
    fixture = W238ShapePart.new
    begin
      type = fixture.type
      rows = fixture.marks
      physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, "v")
      reader = CrystalClick::BinaryBulkColumnReader.open(fixture.part, "v", type)
      reader.schema_declaration.should eq(type.name)
      reader.source_declaration.should eq(type.name)
      reader.row_count.should eq(5_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.physical_stream_names.sort.should eq(physical.stream_names.values.sort)
      physical.stream_names.keys.sort.should eq(
        CrystalClick::BinaryBulkTypePlan.new(type, CrystalClick::BinaryBulkProfile.single_stream).roles
      )
      physical.stream_names.keys.each do |role|
        role.should_not contain("custom")
        role.should_not contain("geo")
      end

      w238s_assert_rows(reader.read_marks(0, reader.mark_count), rows)
      w238s_assert_rows(reader.read_marks(0, 1), [rows[0]] of Array(CrystalClick::BinaryValue))
      w238s_assert_rows(reader.read_marks(1, 1), [rows[1]] of Array(CrystalClick::BinaryValue))
      w238s_assert_rows(reader.read_marks(2, 1), [rows[2]] of Array(CrystalClick::BinaryValue))
      reader.read_marks(reader.mark_count, 0).should be_empty

      table = CrystalClick::WidePartTable.open_selected_typed([fixture.part], ["pk", "v"])
      table.column_types.should eq([{"pk", "UInt64"}, {"v", type.name}])
      observed = [] of CrystalClick::BinaryValue
      schedule = [] of Tuple(Int32, Int64, Int32)
      table.scan_typed(batch_rows: 2) do |batch|
        values = batch.binary_bulk_values_for("v")
        values.size.should eq(batch.values_for("pk").size)
        observed.concat(values.to_a)
        schedule << {batch.mark_index, batch.part_row_offset.to_i64, values.size}
      end
      expected_rows = rows.flatten
      observed.size.should eq(expected_rows.size)
      observed.each_with_index do |value, index|
        w238s_assert_value(value, expected_rows[index])
      end
      schedule.should eq([{0, 0_i64, 2}, {1, 2_i64, 2}, {2, 4_i64, 1}])

      window = [] of CrystalClick::BinaryValue
      table.scan_typed_window(1_u64, 3) do |batch|
        window.concat(batch.binary_bulk_values_for("v").to_a)
      end
      window.size.should eq(3)
      window.each_with_index { |value, index| w238s_assert_value(value, expected_rows[index + 1]) }
      eof_callbacks = 0
      table.scan_typed_window(5_u64, 1) { |_batch| eof_callbacks += 1 }
      eof_callbacks.should eq(0)
    ensure
      fixture.close
    end
  end

  it "rejects a checksum-valid late Array size defect before early or EOF callbacks" do
    w238s_check_late_corruption(
      "array-size", "root.field.0.sizes", 32, 0x01_u8, 0x02_u8
    )
  end

  it "rejects a checksum-valid late String-body defect before early or EOF callbacks" do
    w238s_check_late_corruption(
      "string-size", "root.field.3.data", 16, 0x00_u8, 0x01_u8
    )
  end

  it "rejects a checksum-valid late Variant discriminator defect before early or EOF callbacks" do
    w238s_check_late_corruption(
      "variant-discriminator",
      "root.field.0.elements.discriminators",
      11,
      0x01_u8,
      0x07_u8,
    )
  end

  it "preflights the exact cumulative result budget including each repeated Variant prefix" do
    fixture = W238ShapePart.new
    begin
      encoded = CrystalClick::BinaryBulkCodec.encode(
        fixture.type,
        fixture.marks,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
      )
      physical = CrystalClick::BinaryBulkPhysicalPlan.new(fixture.type, "v")
      mark_count = fixture.marks.size.to_u64
      per_mark_result_bytes = 0_u64
      initial_prefix_bytes = 0_u64
      encoded.roles.each do |role|
        prefix = physical.prefix_size_for(role)
        lane_bytes = encoded.stream(role).byte_size.to_u64
        per_mark_result_bytes += lane_bytes + prefix.to_u64 * mark_count
        if CrystalClick::BinaryBulkPhysicalPrefixAdapter.variant_discriminator_role?(role, prefix)
          initial_prefix_bytes += prefix.to_u64
        end
      end
      exact_result_bytes = per_mark_result_bytes + initial_prefix_bytes
      exact_result_bytes.should be > 1_u64
      exact_result_bytes.should be < Int32::MAX.to_u64

      expect_raises(CrystalClick::CorruptPartError, /result-byte limit/) do
        CrystalClick::BinaryBulkColumnReader.open(
          fixture.part,
          "v",
          fixture.type,
          transport_limits: CrystalClick::CompressedStreamLimits.new(
            max_result_bytes: exact_result_bytes.to_i - 1,
          ),
        )
      end

      reader = CrystalClick::BinaryBulkColumnReader.open(
        fixture.part,
        "v",
        fixture.type,
        transport_limits: CrystalClick::CompressedStreamLimits.new(
          max_result_bytes: exact_result_bytes.to_i,
        ),
      )
      reader.row_count.should eq(5_u64)
    ensure
      fixture.close
    end
  end
end
