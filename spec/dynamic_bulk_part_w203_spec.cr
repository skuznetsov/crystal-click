require "./spec_helper"
require "file_utils"

alias W203NestedTypes = NamedTuple(
  string: CrystalClick::BinaryDataType,
  uint64: CrystalClick::BinaryDataType,
  nullable_string: CrystalClick::BinaryDataType,
  low_cardinality: CrystalClick::BinaryDataType,
  variant: CrystalClick::BinaryDataType,
  dynamic: CrystalClick::BinaryDataType,
  nested: CrystalClick::BinaryDataType,
)

private def w203_nested_types : W203NestedTypes
  string = CrystalClick::BinaryDataType.primitive("String")
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  nullable_string = CrystalClick::BinaryDataType.nullable(string)
  low_cardinality = CrystalClick::BinaryDataType.low_cardinality(nullable_string)
  variant = CrystalClick::BinaryDataType.variant([string, uint64] of CrystalClick::BinaryDataType)
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  nested = CrystalClick::BinaryDataType.nested(
    [low_cardinality, variant, dynamic] of CrystalClick::BinaryDataType,
    ["label", "choice", "payload"] of String,
  )
  {
    string:          string,
    uint64:          uint64,
    nullable_string: nullable_string,
    low_cardinality: low_cardinality,
    variant:         variant,
    dynamic:         dynamic,
    nested:          nested,
  }
end

private def w203_lc_nullable_string(
  low_cardinality : CrystalClick::BinaryDataType,
  nullable : CrystalClick::BinaryDataType,
  value : String?,
) : CrystalClick::BinaryValue
  payload = if value
              CrystalClick::BinaryValue.nullable(nullable, CrystalClick::BinaryValue.string(value))
            else
              CrystalClick::BinaryValue.nullable(nullable)
            end
  CrystalClick::BinaryValue.low_cardinality(low_cardinality, payload)
end

private def w203_nested_record(
  types : W203NestedTypes,
  label : String?,
  variant_index : Int32?,
  variant_child : CrystalClick::BinaryValue?,
  payload : CrystalClick::BinaryValue,
) : CrystalClick::BinaryValue
  choice = if index = variant_index
             CrystalClick::BinaryValue.variant(types[:variant], index, variant_child.not_nil!)
           else
             CrystalClick::BinaryValue.variant_null(types[:variant])
           end
  CrystalClick::BinaryValue.tuple(
    types[:nested].child_at(0),
    [
      w203_lc_nullable_string(types[:low_cardinality], types[:nullable_string], label),
      choice,
      CrystalClick::BinaryValue.dynamic(types[:dynamic], payload),
    ] of CrystalClick::BinaryValue,
  )
end

private def w203_nested_granules(types : W203NestedTypes) : Array(Array(CrystalClick::BinaryValue))
  string_arm = types[:variant].children.index(types[:string]).not_nil!
  uint64_arm = types[:variant].children.index(types[:uint64]).not_nil!
  empty_first = CrystalClick::BinaryValue.nested(types[:nested], [] of CrystalClick::BinaryValue)
  ragged = CrystalClick::BinaryValue.nested(types[:nested], [
    w203_nested_record(types, "red", string_arm, CrystalClick::BinaryValue.string("arm-red"), CrystalClick::BinaryValue.uint64(7_u64)),
    w203_nested_record(types, nil, uint64_arm, CrystalClick::BinaryValue.uint64(42_u64), CrystalClick::BinaryValue.string("shared")),
    w203_nested_record(types, "red", nil, nil, CrystalClick::BinaryValue.uint64(9_u64)),
  ] of CrystalClick::BinaryValue)
  empty_later = CrystalClick::BinaryValue.nested(types[:nested], [] of CrystalClick::BinaryValue)
  final = CrystalClick::BinaryValue.nested(types[:nested], [
    w203_nested_record(types, "blue", string_arm, CrystalClick::BinaryValue.string("arm-blue"), CrystalClick::BinaryValue.string("final-shared")),
    w203_nested_record(types, "red", uint64_arm, CrystalClick::BinaryValue.uint64(8_u64), CrystalClick::BinaryValue.uint64(10_u64)),
  ] of CrystalClick::BinaryValue)
  [
    [empty_first] of CrystalClick::BinaryValue,
    [ragged] of CrystalClick::BinaryValue,
    [empty_later] of CrystalClick::BinaryValue,
    [final] of CrystalClick::BinaryValue,
  ] of Array(CrystalClick::BinaryValue)
end

private def w203_write(
  destination : String,
  keys : Slice(UInt64),
  type : CrystalClick::BinaryDataType,
  structures : Hash(String, CrystalClick::DynamicStructure),
  granules : Array(Array(CrystalClick::BinaryValue)),
  profile : CrystalClick::BinaryBulkProfile,
) : String
  CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
    destination,
    "pk",
    keys,
    "payload",
    type,
    structures,
    granules,
    rows_per_mark: 1,
    profile: profile,
  )
end

private def w203_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w203_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  {hash[0], hash[1]}.each do |word|
    8.times do |index|
      io.write_byte(((word >> (index * 8)) & 0xff_u64).to_u8)
    end
  end
end

private def w203_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
end

private def w203_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w203_encode_lz4_frame(raw : Bytes) : Bytes
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w203_write_u32(frame, header + 1, compressed_size.to_u32)
  w203_write_u32(frame, header + 5, raw.size.to_u32)

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
  w203_write_u64(frame, 0, checksum[0])
  w203_write_u64(frame, 8, checksum[1])
  frame
end

private def w203_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w203_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w203_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w203_write_varuint(payload, file_bytes.size.to_u64)
    w203_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = file_bytes.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w203_write_varuint(payload, raw.size.to_u64)
      w203_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(w203_encode_lz4_frame(payload.to_slice))
  end
end

private def w203_set_serialization_columns(part : String, entries : String) : Nil
  path = File.join(part, "serialization.json")
  info = JSON.parse(File.read(path)).as_h
  columns = info["columns"]?.try(&.as_a) || raise("W203 part has no serializer list")
  columns << JSON.parse(entries)
  File.write(path, info.to_json)
  w203_refresh_checksums(part)
end

private def w203_assert_resolved_structure_name(
  type : CrystalClick::BinaryDataType,
  site_path : String,
  structures : Hash(String, CrystalClick::DynamicStructure),
) : Nil
  limits = CrystalClick::BinaryCodecLimits.default
  plan = CrystalClick::BinaryDynamicBulkPlan.new(type, structures, limits: limits)
  physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(
    plan, "payload", limits, CrystalClick::PhysicalStreamPlanContext.new(limits)
  )
  resolver = CrystalClick::BinaryDynamicBulkSiteNameResolver.new(type, "payload", limits)
  resolver.structure_stream_name(site_path, structures).should eq(physical.structure_name_for(site_path))
end

describe "W203 complete-part recursive Dynamic bulk ownership" do
  it "admits only schema-matched bounded Tuple serializer subcolumns" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    string = CrystalClick::BinaryDataType.primitive("String")
    inner = CrystalClick::BinaryDataType.tuple([string] of CrystalClick::BinaryDataType, ["label"] of String)
    tuple = CrystalClick::BinaryDataType.tuple(
      [dynamic, inner] of CrystalClick::BinaryDataType,
      ["payload", "attributes"] of String,
    )
    limits = CrystalClick::BinaryCodecLimits.default
    nested_subcolumns = JSON.parse(
      "[{\"kind\":\"Default\",\"num_defaults\":1,\"num_rows\":3,\"exact_num_defaults\":true}," +
      "{\"kind\":\"Default\",\"num_defaults\":0,\"num_rows\":3,\"exact_num_defaults\":true,\"subcolumns\":[" +
      "{\"kind\":\"Default\",\"num_defaults\":2,\"num_rows\":3,\"exact_num_defaults\":true}]}]"
    ).as_a
    CrystalClick::DynamicTupleSerializationMetadataValidator.validate_subcolumns!(
      nested_subcolumns, tuple, 3_u64, limits
    )

    arity_mismatch = nested_subcolumns[0...1]
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicTupleSerializationMetadataValidator.validate_subcolumns!(
        arity_mismatch, tuple, 3_u64, limits
      )
    end

    row_mismatch = JSON.parse(
      "[{\"kind\":\"Default\",\"num_defaults\":1,\"num_rows\":2}," +
      "{\"kind\":\"Default\",\"num_defaults\":0,\"num_rows\":3,\"subcolumns\":[" +
      "{\"kind\":\"Default\",\"num_defaults\":2,\"num_rows\":3}]}]"
    ).as_a
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicTupleSerializationMetadataValidator.validate_subcolumns!(
        row_mismatch, tuple, 3_u64, limits
      )
    end

    unexpected_child = JSON.parse(
      "[{\"kind\":\"Default\",\"num_defaults\":1,\"num_rows\":3}," +
      "{\"kind\":\"Default\",\"num_defaults\":0,\"num_rows\":3,\"subcolumns\":[" +
      "{\"kind\":\"Default\",\"num_defaults\":2,\"num_rows\":3,\"subcolumns\":[]}]}]"
    ).as_a
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicTupleSerializationMetadataValidator.validate_subcolumns!(
        unexpected_child, tuple, 3_u64, limits
      )
    end

    missing_nested_children = JSON.parse(
      "[{\"kind\":\"Default\",\"num_defaults\":1,\"num_rows\":3}," +
      "{\"kind\":\"Default\",\"num_defaults\":0,\"num_rows\":3}]"
    ).as_a
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicTupleSerializationMetadataValidator.validate_subcolumns!(
        missing_nested_children, tuple, 3_u64, limits
      )
    end

    nested_arity_mismatch = JSON.parse(
      "[{\"kind\":\"Default\",\"num_defaults\":1,\"num_rows\":3}," +
      "{\"kind\":\"Default\",\"num_defaults\":0,\"num_rows\":3,\"subcolumns\":[]}]"
    ).as_a
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicTupleSerializationMetadataValidator.validate_subcolumns!(
        nested_arity_mismatch, tuple, 3_u64, limits
      )
    end

    wrong_nested_kind = JSON.parse(
      "[{\"kind\":\"Default\",\"num_defaults\":1,\"num_rows\":3}," +
      "{\"kind\":\"Default\",\"num_defaults\":0,\"num_rows\":3,\"subcolumns\":[" +
      "{\"kind\":\"Sparse\",\"num_defaults\":2,\"num_rows\":3}]}]"
    ).as_a
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicTupleSerializationMetadataValidator.validate_subcolumns!(
        wrong_nested_kind, tuple, 3_u64, limits
      )
    end

    wrong_nested_rows = JSON.parse(
      "[{\"kind\":\"Default\",\"num_defaults\":1,\"num_rows\":3}," +
      "{\"kind\":\"Default\",\"num_defaults\":0,\"num_rows\":3,\"subcolumns\":[" +
      "{\"kind\":\"Default\",\"num_defaults\":2,\"num_rows\":2}]}]"
    ).as_a
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicTupleSerializationMetadataValidator.validate_subcolumns!(
        wrong_nested_rows, tuple, 3_u64, limits
      )
    end

    shallow_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 2, max_nodes: 20, max_elements: 20, max_bytes: 4096
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicTupleSerializationMetadataValidator.validate_subcolumns!(
        nested_subcolumns, tuple, 3_u64, shallow_limits
      )
    end

    narrow_node_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 8, max_nodes: 3, max_elements: 20, max_bytes: 4096
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicTupleSerializationMetadataValidator.validate_subcolumns!(
        nested_subcolumns, tuple, 3_u64, narrow_node_limits
      )
    end

    array = CrystalClick::BinaryDataType.array(dynamic)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicTupleSerializationMetadataValidator.validate_subcolumns!(
        nested_subcolumns, array, 3_u64, limits
      )
    end
  end

  it "requires child metadata on a present selected Tuple serializer but accepts an omitted entry" do
    parent = File.tempname("crystal-click-w203-tuple-serializer-metadata-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "part")
      dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
      string = CrystalClick::BinaryDataType.primitive("String")
      tuple = CrystalClick::BinaryDataType.tuple(
        [dynamic, string] of CrystalClick::BinaryDataType,
        ["payload", "label"] of String,
      )
      uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
      structures = {
        "root.field.0" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType),
      }
      value = CrystalClick::BinaryValue.tuple(tuple, [
        CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(7_u64)),
        CrystalClick::BinaryValue.string("row"),
      ] of CrystalClick::BinaryValue)
      w203_write(
        part, Slice[2_u64], tuple, structures,
        [[value] of CrystalClick::BinaryValue], CrystalClick::BinaryBulkProfile.single_stream
      )

      # Our writer intentionally emits no serializer entry for this value.
      CrystalClick::DynamicBulkColumnReader.open(part, "payload", tuple).read_marks(0, 1).size.should eq(1)

      valid_metadata = File.join(parent, "with-subcolumns")
      FileUtils.cp_r(part, valid_metadata)
      w203_set_serialization_columns(
        valid_metadata,
        %({"kind":"Default","name":"payload","num_defaults":0,"num_rows":1,"subcolumns":[) +
        %({"kind":"Default","num_defaults":0,"num_rows":1,"exact_num_defaults":true},) +
        %({"kind":"Default","num_defaults":0,"num_rows":1,"exact_num_defaults":true}]})
      )
      CrystalClick::DynamicBulkColumnReader.open(valid_metadata, "payload", tuple).read_marks(0, 1).size.should eq(1)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectColumnPartMetadata.open(valid_metadata, "payload")
      end

      missing_metadata = File.join(parent, "missing-subcolumns")
      FileUtils.cp_r(part, missing_metadata)
      w203_set_serialization_columns(
        missing_metadata,
        %({"kind":"Default","name":"payload","num_defaults":0,"num_rows":1})
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::DynamicBulkColumnReader.open(missing_metadata, "payload", tuple)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "round-trips a root Dynamic site, SharedVariant, both profiles, and selected mark windows" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    structures = {"root" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)}
    granules = [
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(7_u64))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("shared"))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic)] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(11_u64))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ].each do |profile|
      parent = File.tempname("crystal-click-w203-dynamic-root-")
      Dir.mkdir(parent)
      begin
        destination = File.join(parent, "part")
        w203_write(destination, Slice[2_u64, 5_u64, 9_u64, 14_u64], dynamic, structures, granules, profile).should eq(destination)

        reader = CrystalClick::DynamicBulkColumnReader.open(destination, "payload", dynamic)
        reader.schema_declaration.should eq(dynamic.name)
        reader.row_count.should eq(4_u64)
        reader.mark_count.should eq(4)
        reader.ordinary_profile.should eq(profile)

        full = reader.read_marks(0, 4)
        full[0][0].type.should eq(dynamic)
        full[0][0].child_at(0).as_uint64.should eq(7_u64)
        full[1][0].child_at(0).as_string.should eq("shared")
        full[2][0].is_null?.should be_true
        full[3][0].child_at(0).as_uint64.should eq(11_u64)
        reader.read_marks(1, 1)[0][0].child_at(0).as_string.should eq("shared")
        reader.read_marks(3, 1)[0][0].child_at(0).as_uint64.should eq(11_u64)
        reader.read_marks(4, 0).should be_empty
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "rejects nominal mismatches, exact stream-roster drift, and invalid mark windows" do
    parent = File.tempname("crystal-click-w203-dynamic-reader-guards-")
    Dir.mkdir(parent)
    begin
      destination = File.join(parent, "part")
      dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
      uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
      structures = {"root" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)}
      granules = [
        [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(7_u64))] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)
      w203_write(destination, Slice[2_u64], dynamic, structures, granules, CrystalClick::BinaryBulkProfile.single_stream)
      reader = CrystalClick::DynamicBulkColumnReader.open(destination, "payload", dynamic)

      wider_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicBulkColumnReader.open(destination, "payload", wider_dynamic)
      end
      expect_raises(ArgumentError) { reader.read_marks(-1, 1) }
      expect_raises(ArgumentError) { reader.read_marks(0, reader.mark_count + 1) }
      expect_raises(ArgumentError) { reader.read_marks(reader.mark_count + 1, 0) }

      source = File.join(destination, "columns_substreams.txt")
      original = File.read(source)
      count = reader.physical_stream_names.size
      selected_header = "#{count} substreams for column `payload`:\n"
      original.includes?(selected_header).should be_true
      structure_name = reader.physical_stream_names.find(&.ends_with?(".dynamic_structure")).not_nil!
      structure_line = "\t#{structure_name}\n"
      original.includes?(structure_line).should be_true

      extra = File.join(parent, "extra")
      FileUtils.cp_r(destination, extra)
      extra_text = original.sub(selected_header, "#{count + 1} substreams for column `payload`:\n") +
                   "\tpayload.w203_extra\n"
      File.write(File.join(extra, "columns_substreams.txt"), extra_text)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicBulkColumnReader.open(extra, "payload", dynamic)
      end

      missing = File.join(parent, "missing")
      FileUtils.cp_r(destination, missing)
      missing_text = original.sub(selected_header, "#{count - 1} substreams for column `payload`:\n")
        .sub(structure_line, "")
      File.write(File.join(missing, "columns_substreams.txt"), missing_text)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicBulkColumnReader.open(missing, "payload", dynamic)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves nominal Nested identity and recursively composes LC, Variant, and Dynamic in both profiles" do
    types = w203_nested_types
    structures = {
      "root.elements.field.2" => CrystalClick::DynamicStructure.new([types[:uint64]] of CrystalClick::BinaryDataType),
    }
    granules = w203_nested_granules(types)

    [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ].each do |profile|
      parent = File.tempname("crystal-click-w203-nested-dynamic-")
      Dir.mkdir(parent)
      begin
        destination = File.join(parent, "part")
        w203_write(destination, Slice[3_u64, 8_u64, 13_u64, 21_u64], types[:nested], structures, granules, profile).should eq(destination)

        reader = CrystalClick::DynamicBulkColumnReader.open(destination, "payload", types[:nested])
        reader.schema_declaration.should eq(types[:nested].name)
        reader.row_count.should eq(4_u64)
        reader.mark_count.should eq(4)
        reader.ordinary_profile.should eq(profile)

        full = reader.read_marks(0, 4)
        full[0][0].type.should eq(types[:nested])
        full[0][0].element_count.should eq(0)
        full[1][0].element_count.should eq(3)
        first = full[1][0].element_at(0)
        first.child_at(0).child_at(0).child_at(0).as_string.should eq("red")
        first.child_at(1).variant_child?.not_nil!.as_string.should eq("arm-red")
        first.child_at(2).child_at(0).as_uint64.should eq(7_u64)
        second = full[1][0].element_at(1)
        second.child_at(0).child_at(0).is_null?.should be_true
        second.child_at(1).variant_child?.not_nil!.as_uint64.should eq(42_u64)
        second.child_at(2).child_at(0).as_string.should eq("shared")
        full[1][0].element_at(2).child_at(2).child_at(0).as_uint64.should eq(9_u64)
        full[2][0].element_count.should eq(0)
        full[3][0].element_count.should eq(2)
        full[3][0].element_at(0).child_at(2).child_at(0).as_string.should eq("final-shared")
        full[3][0].element_at(1).child_at(2).child_at(0).as_uint64.should eq(10_u64)

        reader.read_marks(0, 1)[0][0].element_count.should eq(0)
        reader.read_marks(1, 1)[0][0].element_count.should eq(3)
        reader.read_marks(3, 1)[0][0].element_count.should eq(2)
        reader.read_marks(4, 0).should be_empty
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "reuses recursive discovery for Array, Tuple, and an actual Dynamic arm that reveals another site" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    array_type = CrystalClick::BinaryDataType.array(dynamic)
    tuple_type = CrystalClick::BinaryDataType.tuple(
      [string, dynamic] of CrystalClick::BinaryDataType
    )
    actual_tuple_type = CrystalClick::BinaryDataType.tuple(
      [dynamic] of CrystalClick::BinaryDataType
    )

    [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ].each do |profile|
      parent = File.tempname("crystal-click-w203-dynamic-carriers-")
      Dir.mkdir(parent)
      begin
        array_destination = File.join(parent, "array")
        array_structures = {
          "root.elements" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType),
        }
        array_granules = [
          [CrystalClick::BinaryValue.array(array_type, [
            CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(7_u64)),
          ] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
          [CrystalClick::BinaryValue.array(array_type, [
            CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("shared")),
          ] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
        ] of Array(CrystalClick::BinaryValue)
        w203_write(
          array_destination, Slice[2_u64, 5_u64], array_type,
          array_structures, array_granules, profile
        )
        array_reader = CrystalClick::DynamicBulkColumnReader.open(
          array_destination, "payload", array_type
        )
        array_reader.read_marks(0, 2)[0][0].element_at(0).child_at(0).as_uint64.should eq(7_u64)
        array_reader.read_marks(1, 1)[0][0].element_at(0).child_at(0).as_string.should eq("shared")
        array_reader.read_marks(2, 0).should be_empty

        tuple_destination = File.join(parent, "tuple")
        tuple_structures = {
          "root.field.1" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType),
        }
        tuple_granules = [
          [CrystalClick::BinaryValue.tuple(tuple_type, [
            CrystalClick::BinaryValue.string("first"),
            CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(13_u64)),
          ] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
          [CrystalClick::BinaryValue.tuple(tuple_type, [
            CrystalClick::BinaryValue.string("last"),
            CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("tuple-shared")),
          ] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
        ] of Array(CrystalClick::BinaryValue)
        w203_write(
          tuple_destination, Slice[3_u64, 8_u64], tuple_type,
          tuple_structures, tuple_granules, profile
        )
        tuple_reader = CrystalClick::DynamicBulkColumnReader.open(
          tuple_destination, "payload", tuple_type
        )
        tuple_reader.read_marks(1, 1)[0][0].child_at(1).child_at(0).as_string.should eq("tuple-shared")

        outer_destination = File.join(parent, "outer")
        outer_structures = {
          "root" => CrystalClick::DynamicStructure.new([actual_tuple_type] of CrystalClick::BinaryDataType),
          # SharedVariant sorts before the actual Tuple arm in the outer site's
          # canonical roster; the nested Dynamic therefore lives under arm 1.
          "root.arm.1.field.0" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType),
        }
        outer_granules = [
          [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.tuple(actual_tuple_type, [
            CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(21_u64)),
          ] of CrystalClick::BinaryValue))] of CrystalClick::BinaryValue,
          [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.tuple(actual_tuple_type, [
            CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("inner-shared")),
          ] of CrystalClick::BinaryValue))] of CrystalClick::BinaryValue,
        ] of Array(CrystalClick::BinaryValue)
        w203_write(
          outer_destination, Slice[4_u64, 9_u64], dynamic,
          outer_structures, outer_granules, profile
        )
        outer_reader = CrystalClick::DynamicBulkColumnReader.open(
          outer_destination, "payload", dynamic
        )
        outer_reader.read_marks(0, 2)[1][0].child_at(0).child_at(0).child_at(0).as_string.should eq("inner-shared")
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "keeps reader-discovery names aligned with physical plans on legal recursive paths" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    actuals = {"root.field.0" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)}

    unnamed_tuple = CrystalClick::BinaryDataType.tuple(
      [dynamic, uint64] of CrystalClick::BinaryDataType
    )
    w203_assert_resolved_structure_name(unnamed_tuple, "root.field.0", actuals)

    named_tuple = CrystalClick::BinaryDataType.tuple(
      [uint64, dynamic] of CrystalClick::BinaryDataType,
      ["id", "payload"] of String,
    )
    named_actuals = {"root.field.1" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)}
    w203_assert_resolved_structure_name(named_tuple, "root.field.1", named_actuals)

    map = CrystalClick::BinaryDataType.map(string, dynamic)
    map_path = "root.elements.field.1"
    map_actuals = {map_path => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)}
    w203_assert_resolved_structure_name(map, map_path, map_actuals)

    dynamic_tuple = CrystalClick::BinaryDataType.tuple([dynamic] of CrystalClick::BinaryDataType)
    static_variant = CrystalClick::BinaryDataType.variant(
      [dynamic_tuple, uint64] of CrystalClick::BinaryDataType
    )
    dynamic_arm = static_variant.children.index(dynamic_tuple).not_nil!
    variant_path = "root.arm.#{dynamic_arm}.field.0"
    variant_actuals = {variant_path => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)}
    w203_assert_resolved_structure_name(static_variant, variant_path, variant_actuals)

    # The physical roster still traverses a legal SimpleAggregate sibling in
    # the same recursive carrier; a Dynamic site cannot be its storage child.
    aggregate = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Sum, uint64
    )
    tuple_with_aggregate = CrystalClick::BinaryDataType.tuple(
      [aggregate, dynamic] of CrystalClick::BinaryDataType
    )
    aggregate_sibling_actuals = {"root.field.1" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)}
    w203_assert_resolved_structure_name(tuple_with_aggregate, "root.field.1", aggregate_sibling_actuals)

    # SimpleAggregate is transparent in the resolver, but its binary
    # descriptor intentionally admits only scalar storage leaves, not Dynamic.
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Sum, dynamic
      )
    end
  end

  it "rejects a same-roster foreign physical plan and invalid operation budgets before codec work" do
    limits = CrystalClick::BinaryCodecLimits.default
    transport_limits = CrystalClick::CompressedStreamLimits.new
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    structures = {
      "root" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType),
    }
    first_plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
      dynamic, structures, CrystalClick::BinaryCodecBudget.new(limits, true)
    )
    second_plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
      dynamic, structures, CrystalClick::BinaryCodecBudget.new(limits, true)
    )
    first_physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(
      first_plan, "payload", limits, CrystalClick::PhysicalStreamPlanContext.new(limits)
    )
    foreign_physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(
      second_plan, "payload", limits, CrystalClick::PhysicalStreamPlanContext.new(limits)
    )
    first_physical.stream_names.should eq(foreign_physical.stream_names)
    granules = [
      [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(7_u64))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    rows = [1_u64]

    codec_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    transport_budget = CrystalClick::CompressedStreamBudget.new(transport_limits, true)
    expect_raises(ArgumentError) do
      CrystalClick::DynamicBulkColumnWriter.encode(
        first_plan, foreign_physical, granules, rows, 4096, limits,
        transport_limits, codec_budget, transport_budget
      )
    end
    codec_budget.node_count.should eq(0)
    codec_budget.element_count.should eq(0)
    codec_budget.wire_byte_count.should eq(0)
    transport_budget.file_byte_count.should eq(0)
    transport_budget.record_count.should eq(0)
    transport_budget.decoded_byte_count.should eq(0)
    transport_budget.result_byte_count.should eq(0)

    frame_codec_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    frame_transport_budget = CrystalClick::CompressedStreamBudget.new(transport_limits, true)
    expect_raises(ArgumentError) do
      CrystalClick::DynamicBulkColumnWriter.encode(
        first_plan, first_physical, granules, rows, 0, limits,
        transport_limits, frame_codec_budget, frame_transport_budget
      )
    end
    frame_codec_budget.node_count.should eq(0)
    frame_codec_budget.element_count.should eq(0)
    frame_codec_budget.wire_byte_count.should eq(0)
    frame_transport_budget.file_byte_count.should eq(0)
    frame_transport_budget.record_count.should eq(0)

    read_codec_budget = CrystalClick::BinaryCodecBudget.new(limits)
    direction_transport_budget = CrystalClick::CompressedStreamBudget.new(transport_limits, true)
    expect_raises(ArgumentError) do
      CrystalClick::DynamicBulkColumnWriter.encode(
        first_plan, first_physical, granules, rows, 4096, limits,
        transport_limits, read_codec_budget, direction_transport_budget
      )
    end
    read_codec_budget.node_count.should eq(0)
    read_codec_budget.element_count.should eq(0)
    read_codec_budget.wire_byte_count.should eq(0)

    read_transport_budget = CrystalClick::CompressedStreamBudget.new(transport_limits)
    direction_codec_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    expect_raises(ArgumentError) do
      CrystalClick::DynamicBulkColumnWriter.encode(
        first_plan, first_physical, granules, rows, 4096, limits,
        transport_limits, direction_codec_budget, read_transport_budget
      )
    end
    direction_codec_budget.node_count.should eq(0)
    direction_codec_budget.element_count.should eq(0)
    direction_codec_budget.wire_byte_count.should eq(0)
    read_transport_budget.file_byte_count.should eq(0)
    read_transport_budget.record_count.should eq(0)
    read_transport_budget.decoded_byte_count.should eq(0)
    read_transport_budget.result_byte_count.should eq(0)

    incompatible_limits = CrystalClick::CompressedStreamLimits.new(
      max_file_bytes: CrystalClick::CompressedStreamLimits::DEFAULT_MAX_FILE_BYTES - 1
    )
    incompatible_codec_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    incompatible_transport_budget = CrystalClick::CompressedStreamBudget.new(incompatible_limits, true)
    expect_raises(ArgumentError) do
      CrystalClick::DynamicBulkColumnWriter.encode(
        first_plan, first_physical, granules, rows, 4096, limits,
        transport_limits, incompatible_codec_budget, incompatible_transport_budget
      )
    end
    incompatible_codec_budget.node_count.should eq(0)
    incompatible_codec_budget.element_count.should eq(0)
    incompatible_codec_budget.wire_byte_count.should eq(0)
    incompatible_transport_budget.file_byte_count.should eq(0)
    incompatible_transport_budget.record_count.should eq(0)
    incompatible_transport_budget.decoded_byte_count.should eq(0)
    incompatible_transport_budget.result_byte_count.should eq(0)
  end

  it "leaves no published part or staging residue when Dynamic preflight rejects" do
    parent = File.tempname("crystal-click-w203-dynamic-rejected-")
    Dir.mkdir(parent)
    begin
      destination = File.join(parent, "part")
      dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
      structures = {} of String => CrystalClick::DynamicStructure
      granules = [
        [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(7_u64))] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)

      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
          destination, "pk", Slice[1_u64], "payload", dynamic, structures,
          granules, rows_per_mark: 1, frame_bytes: 0
        )
      end
      Dir.exists?(destination).should be_false
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
