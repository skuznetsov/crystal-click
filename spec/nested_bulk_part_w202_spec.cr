require "./spec_helper"
require "file_utils"

alias W202NestedTypes = NamedTuple(
  string: CrystalClick::BinaryDataType,
  uint64: CrystalClick::BinaryDataType,
  nullable_string: CrystalClick::BinaryDataType,
  low_cardinality: CrystalClick::BinaryDataType,
  variant: CrystalClick::BinaryDataType,
  nested: CrystalClick::BinaryDataType,
)

private def w202_nested_types : W202NestedTypes
  string = CrystalClick::BinaryDataType.primitive("String")
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  nullable_string = CrystalClick::BinaryDataType.nullable(string)
  low_cardinality = CrystalClick::BinaryDataType.low_cardinality(nullable_string)
  variant = CrystalClick::BinaryDataType.variant([string, uint64] of CrystalClick::BinaryDataType)
  nested = CrystalClick::BinaryDataType.nested(
    [low_cardinality, variant, string] of CrystalClick::BinaryDataType,
    ["label", "choice", "note"] of String,
  )
  {string: string, uint64: uint64, nullable_string: nullable_string, low_cardinality: low_cardinality, variant: variant, nested: nested}
end

private def w202_nested_record(
  types : W202NestedTypes,
  label : String?,
  variant_index : Int32?,
  variant_child : CrystalClick::BinaryValue?,
  note : String,
) : CrystalClick::BinaryValue
  label_value = if label
                  CrystalClick::BinaryValue.nullable(types[:nullable_string], CrystalClick::BinaryValue.string(label))
                else
                  CrystalClick::BinaryValue.nullable(types[:nullable_string])
                end
  choice = if index = variant_index
             CrystalClick::BinaryValue.variant(types[:variant], index, variant_child.not_nil!)
           else
             CrystalClick::BinaryValue.variant_null(types[:variant])
           end
  CrystalClick::BinaryValue.tuple(
    types[:nested].child_at(0),
    [
      CrystalClick::BinaryValue.low_cardinality(types[:low_cardinality], label_value),
      choice,
      CrystalClick::BinaryValue.string(note),
    ] of CrystalClick::BinaryValue,
  )
end

private def w202_nested_value(
  type : CrystalClick::BinaryDataType,
  records : Array(CrystalClick::BinaryValue),
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.nested(type, records)
end

private def w202_granules(types : W202NestedTypes = w202_nested_types) : Array(Array(CrystalClick::BinaryValue))
  string_arm = types[:variant].children.index(types[:string]).not_nil!.to_i
  uint64_arm = types[:variant].children.index(types[:uint64]).not_nil!.to_i
  empty_first = w202_nested_value(types[:nested], [] of CrystalClick::BinaryValue)
  ragged = w202_nested_value(types[:nested], [
    w202_nested_record(types, "red", string_arm, CrystalClick::BinaryValue.string("arm-red"), "first"),
    w202_nested_record(types, nil, uint64_arm, CrystalClick::BinaryValue.uint64(42_u64), "second"),
    w202_nested_record(types, "red", nil, nil, "third"),
  ] of CrystalClick::BinaryValue)
  empty_middle = w202_nested_value(types[:nested], [] of CrystalClick::BinaryValue)
  populated_final = w202_nested_value(types[:nested], [
    w202_nested_record(types, "blue", string_arm, CrystalClick::BinaryValue.string("arm-blue"), "later"),
    w202_nested_record(types, "red", uint64_arm, CrystalClick::BinaryValue.uint64(7_u64), "final"),
  ] of CrystalClick::BinaryValue)
  [
    [empty_first] of CrystalClick::BinaryValue,
    [ragged] of CrystalClick::BinaryValue,
    [empty_middle] of CrystalClick::BinaryValue,
    [populated_final] of CrystalClick::BinaryValue,
  ] of Array(CrystalClick::BinaryValue)
end

private def w202_write(
  destination : String,
  keys : Slice(UInt64),
  type : CrystalClick::BinaryDataType,
  granules : Array(Array(CrystalClick::BinaryValue)),
  profile : CrystalClick::BinaryBulkProfile = CrystalClick::BinaryBulkProfile.single_stream,
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
  transport_limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new,
) : String
  CrystalClick::WidePartWriter.write_uint64_nested_bulk_part(
    destination,
    "pk",
    keys,
    "payload",
    type,
    granules,
    rows_per_mark: 1,
    profile: profile,
    limits: limits,
    transport_limits: transport_limits,
  )
end

private def w202_u64s(values : Array(UInt64)) : Bytes
  bytes = Bytes.new(values.size * 8)
  values.each_with_index do |value, value_index|
    8.times do |byte_index|
      bytes[value_index * 8 + byte_index] = ((value >> (byte_index * 8)) & 0xff_u64).to_u8
    end
  end
  bytes
end

private def w202_concat_bytes(parts : Array(Bytes)) : Bytes
  bytes = [] of UInt8
  parts.each { |part| part.each { |byte| bytes << byte } }
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w202_should_have_no_stage(parent : String) : Nil
  Dir.children(parent).any?(&.starts_with?(".crystal-click-wide-writer-")).should be_false
end

private def w202_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w202_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w202_corrupt_frame_raw_byte(path : String, raw_offset : Int, value : UInt8) : Nil
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
  # The part writer emits literal-only LZ4 frames; preserve a valid frame while
  # changing one decoded byte in the target lane.
  literal_count.should eq(raw_size)
  frame[cursor + raw_offset] = value
  checksum = CrystalClick::CityHashV1.hash128(
    frame[CrystalClick::CompressedBlock::CHECKSUM_SIZE, compressed_size.to_i]
  )
  w202_write_u64(frame, 0, checksum[0])
  w202_write_u64(frame, 8, checksum[1])
  File.write(path, frame)
end

private def w202_part_snapshot(path : String) : Array(Tuple(String, String))
  Dir.children(path).sort.map do |name|
    {name, File.read(File.join(path, name))}
  end
end

private def w202_mutate_same_length_text(path : String, needle : String) : Nil
  text = File.read(path)
  offset = text.index(needle) || raise "W202 metadata does not contain the expected stream name"
  bytes = text.to_slice.dup
  bytes[offset] = bytes[offset] == 'x'.ord.to_u8 ? 'y'.ord.to_u8 : 'x'.ord.to_u8
  File.write(path, String.new(bytes))
end

private def w202_mark_path(part : String, physical : CrystalClick::BinaryBulkPhysicalPlan, role : String) : String
  File.join(part, physical.marks_file_for(role, true))
end

describe "W202 complete-part nominal Nested bulk composition" do
  it "round-trips empty-first, ragged, later-empty, and final Nested marks through the public part reader" do
    types = w202_nested_types
    granules = w202_granules(types)
    parent = File.tempname("crystal-click-w202-nested-part-")
    Dir.mkdir(parent)
    begin
      destination = File.join(parent, "part")
      w202_write(destination, Slice[3_u64, 8_u64, 13_u64, 21_u64], types[:nested], granules).should eq(destination)

      reader = CrystalClick::NestedBulkColumnReader.open(destination, "payload", types[:nested])
      reader.schema_declaration.should eq(types[:nested].name)
      reader.row_count.should eq(4_u64)
      reader.mark_count.should eq(4)
      reader.mark_row_counts.should eq([1_u64, 1_u64, 1_u64, 1_u64])
      reader.ordinary_profile.should eq(CrystalClick::BinaryBulkProfile.single_stream)

      full = reader.read_marks(0, 4)
      full.size.should eq(4)
      full[0][0].type.should eq(types[:nested])
      full[0][0].element_count.should eq(0)
      full[1][0].type.should eq(types[:nested])
      full[1][0].element_count.should eq(3)
      first = full[1][0].element_at(0)
      first.child_at(0).child_at(0).child_at(0).as_string.should eq("red")
      first.child_at(1).variant_child?.not_nil!.as_string.should eq("arm-red")
      first.child_at(2).as_string.should eq("first")
      second = full[1][0].element_at(1)
      second.child_at(0).child_at(0).is_null?.should be_true
      second.child_at(1).variant_child?.not_nil!.as_uint64.should eq(42_u64)
      third = full[1][0].element_at(2)
      third.child_at(0).child_at(0).child_at(0).as_string.should eq("red")
      third.child_at(1).variant_index?.should be_nil
      third.child_at(1).is_null?.should be_true
      full[2][0].element_count.should eq(0)
      final = full[3][0].element_at(0)
      final.child_at(0).child_at(0).child_at(0).as_string.should eq("blue")
      final.child_at(1).variant_child?.not_nil!.as_string.should eq("arm-blue")
      full[3][0].element_at(1).child_at(1).variant_child?.not_nil!.as_uint64.should eq(7_u64)

      reader.read_marks(0, 1)[0][0].element_count.should eq(0)
      reader.read_marks(2, 1)[0][0].element_count.should eq(0)
      reader.read_marks(3, 1)[0][0].element_count.should eq(2)
      reader.read_marks(4, 0).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps exact LC/Variant role rosters and independent String-size lanes in both profiles" do
    types = w202_nested_types
    granules = w202_granules(types)
    single_roles = [
      "root.elements.field.0.dictionary",
      "root.elements.field.0.indexes",
      "root.elements.field.1.arm.0.data",
      "root.elements.field.1.arm.1.data",
      "root.elements.field.1.discriminators",
      "root.elements.field.2.data",
      "root.sizes",
    ] of String
    size_roles = single_roles + [
      "root.elements.field.1.arm.0.string_sizes",
      "root.elements.field.2.string_sizes",
    ] of String
    size_roles.sort!

    parent = File.tempname("crystal-click-w202-nested-profiles-")
    Dir.mkdir(parent)
    begin
      [
        {CrystalClick::BinaryBulkProfile.single_stream, single_roles},
        {CrystalClick::BinaryBulkProfile.with_size_stream, size_roles},
      ].each_with_index do |entry, profile_index|
        profile, expected_roles = entry
        expected_roles = expected_roles.sort
        type_plan = CrystalClick::BinaryBulkTypePlan.new(types[:nested], profile)
        physical = CrystalClick::BinaryBulkPhysicalPlan.new(types[:nested], "payload", profile)
        encoded = CrystalClick::BinaryBulkCodec.encode(types[:nested], granules, profile: profile)
        type_plan.roles.should eq(expected_roles)
        type_plan.role_count.should eq(expected_roles.size.to_u64)
        type_plan.low_cardinality_site_count.should eq(1_u64)
        physical.stream_count.should eq(expected_roles.size)
        encoded.roles.should eq(expected_roles)
        expected_roles.each do |role|
          encoded.stream(role).offset_count.should eq(5)
        end

        # This literal size lane is authored from the four outer Nested rows,
        # independently of encoder/reader agreement.
        encoded.stream("root.sizes").bytes.should eq(w202_u64s([0_u64, 3_u64, 0_u64, 2_u64]))
        lc_dictionary_role = "root.elements.field.0.dictionary"
        lc_index_role = "root.elements.field.0.indexes"
        encoded.stream(lc_dictionary_role).bytes.should eq(w202_concat_bytes([
          w202_u64s([1_u64, 4_u64]),
          Bytes[0_u8, 0_u8, 3_u8, 'r'.ord.to_u8, 'e'.ord.to_u8, 'd'.ord.to_u8, 4_u8,
            'b'.ord.to_u8, 'l'.ord.to_u8, 'u'.ord.to_u8, 'e'.ord.to_u8],
        ] of Bytes))
        encoded.stream(lc_dictionary_role).offsets.should eq([8_u64, 8_u64, 8_u64, 8_u64, 27_u64])
        encoded.stream(lc_index_role).bytes.should eq(w202_concat_bytes([
          w202_u64s([0x500_u64, 3_u64]),
          Bytes[2_u8, 0_u8, 2_u8],
          w202_u64s([0x100_u64, 2_u64]),
          Bytes[3_u8, 2_u8],
        ] of Bytes))
        encoded.stream(lc_index_role).offsets.should eq([0_u64, 0_u64, 19_u64, 19_u64, 37_u64])
        direct = encoded.stream("root.elements.field.2.data")
        arm_string = encoded.stream("root.elements.field.1.arm.0.data")
        if profile.single_stream?
          direct.offsets.should eq([0_u64, 0_u64, 19_u64, 19_u64, 31_u64])
          arm_string.offsets.should eq([0_u64, 0_u64, 8_u64, 8_u64, 17_u64])
        else
          direct.offsets.should eq([0_u64, 0_u64, 16_u64, 16_u64, 26_u64])
          arm_string.offsets.should eq([0_u64, 0_u64, 7_u64, 7_u64, 15_u64])
          encoded.stream("root.elements.field.2.string_sizes").bytes.should eq(
            w202_u64s([5_u64, 6_u64, 5_u64, 5_u64, 5_u64])
          )
          encoded.stream("root.elements.field.2.string_sizes").offsets.should eq(
            [0_u64, 0_u64, 24_u64, 24_u64, 40_u64]
          )
          encoded.stream("root.elements.field.1.arm.0.string_sizes").bytes.should eq(
            w202_u64s([7_u64, 8_u64])
          )
          encoded.stream("root.elements.field.1.arm.0.string_sizes").offsets.should eq(
            [0_u64, 0_u64, 8_u64, 8_u64, 16_u64]
          )
        end

        destination = File.join(parent, "profile-#{profile_index}")
        w202_write(
          destination,
          Slice[3_u64, 8_u64, 13_u64, 21_u64],
          types[:nested],
          granules,
          profile: profile,
        )
        reader = CrystalClick::NestedBulkColumnReader.open(destination, "payload", types[:nested])
        reader.ordinary_profile.should eq(profile)
        reader.physical_stream_names.should eq(physical.stream_names.values.sort)
        reader.read_marks(0, 4)[1][0].element_count.should eq(3)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects Array(Tuple), root Dynamic/JSON, and Dynamic/JSON subtrees before publication" do
    types = w202_nested_types
    parent = File.tempname("crystal-click-w202-nested-refusals-")
    Dir.mkdir(parent)
    begin
      tuple = CrystalClick::BinaryDataType.tuple(
        [types[:low_cardinality], types[:variant], types[:string]] of CrystalClick::BinaryDataType,
        ["label", "choice", "note"] of String,
      )
      array = CrystalClick::BinaryDataType.array(tuple)
      array_row = CrystalClick::BinaryValue.tuple(tuple, [
        CrystalClick::BinaryValue.low_cardinality(
          types[:low_cardinality], CrystalClick::BinaryValue.nullable(types[:nullable_string])
        ),
        CrystalClick::BinaryValue.variant_null(types[:variant]),
        CrystalClick::BinaryValue.string("array-tuple"),
      ] of CrystalClick::BinaryValue)
      array_value = CrystalClick::BinaryValue.array(array, [array_row] of CrystalClick::BinaryValue)

      dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
      dynamic_value = CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(7_u64))
      json = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
      json_row = CrystalClick::BinaryJsonRow.new(json, [] of Tuple(String, CrystalClick::BinaryValue))
      json_value = CrystalClick::BinaryValue.json(json, json_row)

      rejected = [
        {"array-tuple", array, [[array_value]] of Array(CrystalClick::BinaryValue)},
        {"root-dynamic", dynamic, [[dynamic_value]] of Array(CrystalClick::BinaryValue)},
        {"root-json", json, [[json_value]] of Array(CrystalClick::BinaryValue)},
      ] of Tuple(String, CrystalClick::BinaryDataType, Array(Array(CrystalClick::BinaryValue)))
      rejected.each do |label, type, granules|
        destination = File.join(parent, label)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          w202_write(destination, Slice[1_u64], type, granules)
        end
        Dir.exists?(destination).should be_false
        w202_should_have_no_stage(parent)
      end

      dynamic_nested = CrystalClick::BinaryDataType.nested([dynamic] of CrystalClick::BinaryDataType, ["value"] of String)
      dynamic_nested_value = CrystalClick::BinaryValue.nested(dynamic_nested, [
        CrystalClick::BinaryValue.tuple(dynamic_nested.child_at(0), [dynamic_value] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue)
      json_nested = CrystalClick::BinaryDataType.nested([json] of CrystalClick::BinaryDataType, ["value"] of String)
      json_nested_value = CrystalClick::BinaryValue.nested(json_nested, [
        CrystalClick::BinaryValue.tuple(json_nested.child_at(0), [json_value] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue)
      [
        {"nested-dynamic", dynamic_nested, [[dynamic_nested_value]] of Array(CrystalClick::BinaryValue)},
        {"nested-json", json_nested, [[json_nested_value]] of Array(CrystalClick::BinaryValue)},
      ].each do |label, type, granules|
        destination = File.join(parent, label)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          w202_write(destination, Slice[1_u64], type, granules)
        end
        Dir.exists?(destination).should be_false
        w202_should_have_no_stage(parent)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects key-grid and nominal value mismatches before publishing a part" do
    types = w202_nested_types
    granules = w202_granules(types)
    parent = File.tempname("crystal-click-w202-nested-preflight-")
    Dir.mkdir(parent)
    begin
      short_keys = File.join(parent, "short-keys")
      expect_raises(ArgumentError) do
        w202_write(short_keys, Slice[3_u64, 8_u64, 13_u64], types[:nested], granules)
      end
      Dir.exists?(short_keys).should be_false
      w202_should_have_no_stage(parent)

      substituted = CrystalClick::BinaryDataType.nested(
        [types[:low_cardinality], types[:variant], types[:string]] of CrystalClick::BinaryDataType,
        ["label", "choice", "text"] of String,
      )
      substituted_record = CrystalClick::BinaryValue.tuple(substituted.child_at(0), [
        CrystalClick::BinaryValue.low_cardinality(
          types[:low_cardinality],
          CrystalClick::BinaryValue.nullable(types[:nullable_string], CrystalClick::BinaryValue.string("red")),
        ),
        CrystalClick::BinaryValue.variant(
          types[:variant],
          types[:variant].children.index(types[:string]).not_nil!.to_i,
          CrystalClick::BinaryValue.string("arm-red"),
        ),
        CrystalClick::BinaryValue.string("wrong-schema"),
      ] of CrystalClick::BinaryValue)
      bad_value = w202_nested_value(substituted, [substituted_record] of CrystalClick::BinaryValue)
      bad_grid = [[bad_value]] of Array(CrystalClick::BinaryValue)
      bad_schema = File.join(parent, "bad-schema")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w202_write(bad_schema, Slice[3_u64], types[:nested], bad_grid)
      end
      Dir.exists?(bad_schema).should be_false
      w202_should_have_no_stage(parent)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "does not replace an existing destination on a second publication attempt" do
    types = w202_nested_types
    granules = w202_granules(types)
    parent = File.tempname("crystal-click-w202-nested-existing-")
    Dir.mkdir(parent)
    begin
      destination = File.join(parent, "part")
      keys = Slice[3_u64, 8_u64, 13_u64, 21_u64]
      w202_write(destination, keys, types[:nested], granules)
      before = w202_part_snapshot(destination)
      expect_raises(ArgumentError) do
        w202_write(destination, keys, types[:nested], granules)
      end
      w202_part_snapshot(destination).should eq(before)
      w202_should_have_no_stage(parent)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "applies recursive codec limits and one aggregate transport budget across physical lanes" do
    types = w202_nested_types
    granules = w202_granules(types)
    parent = File.tempname("crystal-click-w202-nested-budgets-")
    Dir.mkdir(parent)
    begin
      tiny_destination = File.join(parent, "tiny-codec")
      tiny_codec = CrystalClick::BinaryCodecLimits.new(max_depth: 1, max_nodes: 1, max_elements: 1, max_bytes: 1)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w202_write(
          tiny_destination,
          Slice[3_u64, 8_u64, 13_u64, 21_u64],
          types[:nested],
          granules,
          limits: tiny_codec,
        )
      end
      Dir.exists?(tiny_destination).should be_false
      w202_should_have_no_stage(parent)

      name_budget_destination = File.join(parent, "name-budget")
      name_budget = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 100, max_elements: 100, max_bytes: 1)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w202_write(
          name_budget_destination,
          Slice[3_u64, 8_u64, 13_u64, 21_u64],
          types[:nested],
          granules,
          limits: name_budget,
        )
      end
      Dir.exists?(name_budget_destination).should be_false
      w202_should_have_no_stage(parent)

      baseline = File.join(parent, "baseline")
      w202_write(baseline, Slice[3_u64, 8_u64, 13_u64, 21_u64], types[:nested], granules)
      lane_sizes = Dir.children(baseline).select { |name| name.ends_with?(".bin") || name.ends_with?(".mrk2") }
        .map { |name| File.info(File.join(baseline, name)).size }
      largest_lane = lane_sizes.max
      total_lanes = lane_sizes.sum
      largest_lane.should be > 0
      total_lanes.should be > largest_lane

      aggregate_destination = File.join(parent, "aggregate-budget")
      transport_limit = CrystalClick::CompressedStreamLimits.new(max_file_bytes: largest_lane)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w202_write(
          aggregate_destination,
          Slice[3_u64, 8_u64, 13_u64, 21_u64],
          types[:nested],
          granules,
          transport_limits: transport_limit,
        )
      end
      Dir.exists?(aggregate_destination).should be_false
      w202_should_have_no_stage(parent)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects an off-window Nested-size corruption even for a zero-mark read" do
    types = w202_nested_types
    parent = File.tempname("crystal-click-w202-nested-size-corruption-")
    Dir.mkdir(parent)
    begin
      destination = File.join(parent, "part")
      w202_write(destination, Slice[3_u64, 8_u64, 13_u64, 21_u64], types[:nested], w202_granules(types))
      reader = CrystalClick::NestedBulkColumnReader.open(destination, "payload", types[:nested])
      physical = CrystalClick::BinaryBulkPhysicalPlan.new(
        types[:nested], "payload", CrystalClick::BinaryBulkProfile.single_stream
      )
      size_data = File.join(destination, physical.data_file_for("root.sizes", true))
      # The first mark is a real outer row whose Nested element count is zero.
      # Change that count to one without changing the compressed frame shape.
      w202_corrupt_frame_raw_byte(size_data, 0, 1_u8)

      expect_raises(CrystalClick::CorruptPartError) { reader.read_marks(1, 1) }
      expect_raises(CrystalClick::CorruptPartError) { reader.read_marks(4, 0) }
      expect_raises(ArgumentError) { reader.read_marks(-1, 0) }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects an off-window LC index mark-count mismatch on an end-zero read" do
    types = w202_nested_types
    parent = File.tempname("crystal-click-w202-nested-index-corruption-")
    Dir.mkdir(parent)
    begin
      count_destination = File.join(parent, "bad-count")
      w202_write(
        count_destination,
        Slice[3_u64, 8_u64, 13_u64, 21_u64],
        types[:nested],
        w202_granules(types),
      )
      count_data = File.join(
        count_destination,
        CrystalClick::BinaryBulkPhysicalPlan.new(
          types[:nested], "payload", CrystalClick::BinaryBulkProfile.single_stream
        ).data_file_for("root.elements.field.0.indexes", true),
      )
      # The first index record is for mark 1 (mark 0 is empty); its row-count
      # header must agree with the independent Nested size schedule's value 3.
      w202_corrupt_frame_raw_byte(count_data, 8, 2_u8)
      count_reader = CrystalClick::NestedBulkColumnReader.open(count_destination, "payload", types[:nested])
      expect_raises(CrystalClick::CorruptPartError) { count_reader.read_marks(4, 0) }

      destination = File.join(parent, "part")
      w202_write(destination, Slice[3_u64, 8_u64, 13_u64, 21_u64], types[:nested], w202_granules(types))
      physical = CrystalClick::BinaryBulkPhysicalPlan.new(
        types[:nested], "payload", CrystalClick::BinaryBulkProfile.single_stream
      )
      index_role = "root.elements.field.0.indexes"
      marks_path = w202_mark_path(destination, physical, index_role)
      marks = File.read(marks_path).to_slice.dup
      # Mark 1 contains three Nested elements. Shorten the following LC-index
      # boundary by one byte so it no longer matches the independent size lane.
      boundary_offset = CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE * 2 + 8
      boundary = w202_read_u64(marks, boundary_offset)
      boundary.should be > 0_u64
      w202_write_u64(marks, boundary_offset, boundary - 1_u64)
      File.write(marks_path, marks)

      expect_raises(CrystalClick::CorruptPartError) do
        reader = CrystalClick::NestedBulkColumnReader.open(destination, "payload", types[:nested])
        reader.read_marks(4, 0)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects non-BASIC Variant headers, nominal Array(Tuple) substitution, and a changed stream roster" do
    types = w202_nested_types
    granules = w202_granules(types)
    parent = File.tempname("crystal-click-w202-nested-metadata-guards-")
    Dir.mkdir(parent)
    begin
      discriminator_role = "root.elements.field.1.discriminators"
      physical = CrystalClick::BinaryBulkPhysicalPlan.new(
        types[:nested], "payload", CrystalClick::BinaryBulkProfile.single_stream
      )

      bad_header = File.join(parent, "bad-header")
      w202_write(bad_header, Slice[3_u64, 8_u64, 13_u64, 21_u64], types[:nested], granules)
      discriminator_data = File.join(bad_header, physical.data_file_for(discriminator_role, true))
      w202_corrupt_frame_raw_byte(discriminator_data, 0, 1_u8)
      expect_raises(CrystalClick::CorruptPartError) do
        reader = CrystalClick::NestedBulkColumnReader.open(bad_header, "payload", types[:nested])
        reader.read_marks(4, 0)
      end

      good_part = File.join(parent, "good-part")
      w202_write(good_part, Slice[3_u64, 8_u64, 13_u64, 21_u64], types[:nested], granules)
      array_tuple = CrystalClick::BinaryDataType.array(types[:nested].child_at(0))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::NestedBulkColumnReader.open(good_part, "payload", array_tuple)
      end

      renamed_nested = CrystalClick::BinaryDataType.nested(
        [types[:low_cardinality], types[:variant], types[:string]] of CrystalClick::BinaryDataType,
        ["label", "choice", "text"] of String,
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::NestedBulkColumnReader.open(good_part, "payload", renamed_nested)
      end

      bad_roster = File.join(parent, "bad-roster")
      w202_write(bad_roster, Slice[3_u64, 8_u64, 13_u64, 21_u64], types[:nested], granules)
      first_stream_name = physical.stream_names.values.first.not_nil!
      w202_mutate_same_length_text(File.join(bad_roster, "columns_substreams.txt"), first_stream_name)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::NestedBulkColumnReader.open(bad_roster, "payload", types[:nested])
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
