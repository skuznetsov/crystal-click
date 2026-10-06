require "./spec_helper"

private def w197_u64s(values : Array(UInt64)) : Bytes
  Bytes.new(values.size * 8) do |index|
    value = values[index // 8]
    ((value >> ((index % 8) * 8)) & 0xff_u64).to_u8
  end
end

private def w197_event_bytes(stream : CrystalClick::ObjectSharedPathStreams, name : String) : Bytes
  events = stream.events
  index = events.index { |event| event.name == name } || raise("missing W197 event #{name.inspect}")
  start = events[index].relative_offset
  finish = if following = events[index + 1]?
             following.relative_offset
           else
             stream.data_size.to_u64
           end
  Bytes.new((finish - start).to_i) do |offset|
    stream.data_byte_at(start.to_i + offset)
  end
end

private def w197_nested_fixture
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  string = CrystalClick::BinaryDataType.primitive("String")
  nested = CrystalClick::BinaryDataType.nested(
    [uint8, string] of CrystalClick::BinaryDataType,
    ["a", "b"] of String
  )
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  structures = {"root" => CrystalClick::DynamicStructure.new([nested] of CrystalClick::BinaryDataType)}

  record = ->(number : UInt8, text : String) do
    CrystalClick::BinaryValue.tuple(nested.child_at(0), [
      CrystalClick::BinaryValue.fixed(uint8, Bytes[number]),
      CrystalClick::BinaryValue.string(text),
    ] of CrystalClick::BinaryValue)
  end

  populated = CrystalClick::BinaryValue.nested(nested, [record.call(7_u8, "one"), record.call(9_u8, "two")])
  empty = CrystalClick::BinaryValue.nested(nested, [] of CrystalClick::BinaryValue)
  rows = [
    CrystalClick::BinaryValue.dynamic(dynamic, populated),
    CrystalClick::BinaryValue.dynamic(dynamic, empty),
    CrystalClick::BinaryValue.dynamic(dynamic),
    CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("fallback")),
  ] of CrystalClick::BinaryValue

  {uint8: uint8, string: string, nested: nested, dynamic: dynamic, structures: structures, rows: rows}
end

describe CrystalClick::ObjectSharedPathCodec do
  it "composes a Nested actual through ordered fields for both String profiles" do
    fixture = w197_nested_fixture
    nested_prefix = ".Nested(a UInt8, b String)"

    [CrystalClick::BinaryBulkProfile.single_stream, CrystalClick::BinaryBulkProfile.with_size_stream].each do |profile|
      encoded = CrystalClick::ObjectSharedPathCodec.encode(
        fixture[:dynamic], fixture[:structures], fixture[:rows], profile: profile
      )

      expected_names = [
        ".dynamic_structure",
        ".variant_discr_prefix",
        ".variant_discr",
        "#{nested_prefix}.size0",
        "#{nested_prefix}%2Ea",
        "#{nested_prefix}%2Eb",
        ".SharedVariant",
      ] of String
      if profile.with_size_stream?
        expected_names.insert(5, "#{nested_prefix}%2Eb.size")
        expected_names.insert(7, ".SharedVariant.size")
      end

      encoded.events.map(&.name).should eq(expected_names)
      encoded.events.first.relative_offset.should eq(0_u64)
      offsets = encoded.events.map(&.relative_offset)
      offsets.should eq(offsets.sort)

      # Variant-selected actual rows are sparse: only the two Nested values
      # contribute to the Nested Array carrier; NULL and SharedVariant rows do
      # not. These literals independently pin the Array-of-Tuple composition.
      w197_event_bytes(encoded, "#{nested_prefix}.size0").should eq(w197_u64s([2_u64, 0_u64]))
      w197_event_bytes(encoded, "#{nested_prefix}%2Ea").should eq(Bytes[7_u8, 9_u8])
      if profile.with_size_stream?
        w197_event_bytes(encoded, "#{nested_prefix}%2Eb.size").should eq(w197_u64s([3_u64, 3_u64]))
        w197_event_bytes(encoded, "#{nested_prefix}%2Eb").should eq("onetwo".to_slice)
      else
        w197_event_bytes(encoded, "#{nested_prefix}%2Eb").should eq(Bytes[
          3_u8, 'o'.ord.to_u8, 'n'.ord.to_u8, 'e'.ord.to_u8,
          3_u8, 't'.ord.to_u8, 'w'.ord.to_u8, 'o'.ord.to_u8,
        ])
      end

      decoded = CrystalClick::ObjectSharedPathCodec.decode(
        encoded.data, encoded.events, fixture[:rows].size, fixture[:dynamic], profile: profile
      )
      decoded.size.should eq(4)
      decoded.each { |row| row.type.should eq(fixture[:dynamic]) }
      decoded[0].child_at(0).type.should eq(fixture[:nested])
      decoded[0].child_at(0).element_at(0).child_at(0).bytes.should eq(Bytes[7])
      decoded[0].child_at(0).element_at(0).child_at(1).as_string.should eq("one")
      decoded[0].child_at(0).element_at(1).child_at(0).bytes.should eq(Bytes[9])
      decoded[0].child_at(0).element_at(1).child_at(1).as_string.should eq("two")
      decoded[1].child_at(0).type.should eq(fixture[:nested])
      decoded[1].child_at(0).elements.should be_empty
      decoded[2].is_null?.should be_true
      decoded[3].child_at(0).as_string.should eq("fallback")
    end
  end

  it "keeps the Nested roster and ordered callbacks for zero rows" do
    fixture = w197_nested_fixture
    encoded = CrystalClick::ObjectSharedPathCodec.encode(
      fixture[:dynamic], fixture[:structures], [] of CrystalClick::BinaryValue,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream
    )

    encoded.events.map(&.name).should eq([
      ".dynamic_structure",
      ".variant_discr_prefix",
      ".variant_discr",
      ".Nested(a UInt8, b String).size0",
      ".Nested(a UInt8, b String)%2Ea",
      ".Nested(a UInt8, b String)%2Eb.size",
      ".Nested(a UInt8, b String)%2Eb",
      ".SharedVariant.size",
      ".SharedVariant",
    ])
    encoded.events.first.relative_offset.should eq(0_u64)
    encoded.data.size.should be > 0
    CrystalClick::ObjectSharedPathCodec.decode(
      encoded.data, encoded.events, 0, fixture[:dynamic],
      profile: CrystalClick::BinaryBulkProfile.with_size_stream
    ).should be_empty
  end

  it "charges repeated mark calls to the same caller budgets" do
    fixture = w197_nested_fixture
    profile = CrystalClick::BinaryBulkProfile.with_size_stream
    write_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.new(64, 100_000, 100_000, 1_000_000), true)
    read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.new(64, 100_000, 100_000, 1_000_000))

    first = CrystalClick::ObjectSharedPathCodec.encode_with_budget(
      fixture[:dynamic], fixture[:structures], fixture[:rows][0, 2], write_budget, profile
    )
    after_first_write = write_budget.wire_byte_count
    second = CrystalClick::ObjectSharedPathCodec.encode_with_budget(
      fixture[:dynamic], fixture[:structures], fixture[:rows][2, 2], write_budget, profile
    )
    write_budget.wire_byte_count.should be > after_first_write

    first_read = CrystalClick::ObjectSharedPathCodec.decode_with_budget(
      first.data, first.events, 2, fixture[:dynamic], read_budget, profile
    )
    after_first_read = read_budget.wire_byte_count
    second_read = CrystalClick::ObjectSharedPathCodec.decode_with_budget(
      second.data, second.events, 2, fixture[:dynamic], read_budget, profile
    )
    read_budget.wire_byte_count.should be > after_first_read
    first_read[0].child_at(0).type.should eq(fixture[:nested])
    first_read[1].child_at(0).elements.should be_empty
    second_read[0].is_null?.should be_true
    second_read[1].child_at(0).as_string.should eq("fallback")

    probe_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    CrystalClick::ObjectSharedPathCodec.encode_with_budget(
      fixture[:dynamic], fixture[:structures], fixture[:rows][0, 2], probe_budget, profile
    )
    exact_limits = CrystalClick::BinaryCodecLimits.new(
      64, 100_000, 100_000, probe_budget.wire_byte_count
    )
    bounded_budget = CrystalClick::BinaryCodecBudget.new(exact_limits, true)
    CrystalClick::ObjectSharedPathCodec.encode_with_budget(
      fixture[:dynamic], fixture[:structures], fixture[:rows][0, 2], bounded_budget, profile
    )
    spent_after_first = bounded_budget.wire_byte_count
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedPathCodec.encode_with_budget(
        fixture[:dynamic], fixture[:structures], fixture[:rows][2, 2], bounded_budget, profile
      )
    end
    bounded_budget.wire_byte_count.should eq(spent_after_first)
  end

  it "retains specialized Nested-child refusals" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    low_cardinality = CrystalClick::BinaryDataType.low_cardinality(string)
    variant = CrystalClick::BinaryDataType.variant([uint8, string] of CrystalClick::BinaryDataType)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)

    [low_cardinality, variant, dynamic].each do |child|
      nested = CrystalClick::BinaryDataType.nested([child] of CrystalClick::BinaryDataType, ["payload"] of String)
      path_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
      structure = CrystalClick::DynamicStructure.new([nested] of CrystalClick::BinaryDataType)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectSharedPathCodec.encode(
          path_dynamic,
          {"root" => structure},
          [] of CrystalClick::BinaryValue
        )
      end

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkCodec.encode(nested, [] of Array(CrystalClick::BinaryValue))
      end

      structure_streams = CrystalClick::BinaryDynamicStructureStreams.new({
        "root" => CrystalClick::DynamicStructureCodec.encode(structure),
      })
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDynamicBulkPlan.new(path_dynamic, {"root" => structure})
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
          path_dynamic,
          structure_streams,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
        )
      end
    end
  end

  it "rejects a wrong nominal Nested-to-Array(Tuple) event substitution" do
    fixture = w197_nested_fixture
    encoded = CrystalClick::ObjectSharedPathCodec.encode(
      fixture[:dynamic], fixture[:structures], fixture[:rows],
      profile: CrystalClick::BinaryBulkProfile.with_size_stream
    )
    nested_prefix = ".Nested(a UInt8, b String)"
    tuple_carrier = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.tuple(
        [fixture[:uint8], fixture[:string]] of CrystalClick::BinaryDataType,
        ["a", "b"] of String
      )
    )
    wrong_events = encoded.events
    size_index = wrong_events.index { |event| event.name == "#{nested_prefix}.size0" }.not_nil!
    wrong_events[size_index] = CrystalClick::ObjectSharedPathSubstreamEvent.new(
      ".#{tuple_carrier.name}.size0",
      wrong_events[size_index].relative_offset
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedPathCodec.decode(
        encoded.data, wrong_events, fixture[:rows].size, fixture[:dynamic],
        profile: CrystalClick::BinaryBulkProfile.with_size_stream
      )
    end
  end

  it "preflights the implicit Nested Tuple descriptor depth on both directions" do
    fixture = w197_nested_fixture
    depth_three = CrystalClick::BinaryCodecLimits.new(3, 100_000, 100_000, 1_000_000)
    depth_four = CrystalClick::BinaryCodecLimits.new(4, 100_000, 100_000, 1_000_000)

    # Array(UInt8) needs one fewer descriptor edge than Nested(UInt8), whose
    # implicit Tuple must be charged on both planning and decoding paths.
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    array = CrystalClick::BinaryDataType.array(uint8)
    array_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    array_structures = {"root" => CrystalClick::DynamicStructure.new([array] of CrystalClick::BinaryDataType)}
    array_value = CrystalClick::BinaryValue.array(array, [CrystalClick::BinaryValue.fixed(uint8, Bytes[7_u8])] of CrystalClick::BinaryValue)
    array_rows = [CrystalClick::BinaryValue.dynamic(array_dynamic, array_value)] of CrystalClick::BinaryValue
    array_encoded = CrystalClick::ObjectSharedPathCodec.encode(
      array_dynamic, array_structures, array_rows, limits: depth_three
    )
    CrystalClick::ObjectSharedPathCodec.decode(
      array_encoded.data, array_encoded.events, 1, array_dynamic, depth_three
    ).size.should eq(1)

    write_budget = CrystalClick::BinaryCodecBudget.new(depth_three, true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedPathCodec.encode_with_budget(
        fixture[:dynamic], fixture[:structures], fixture[:rows], write_budget,
        CrystalClick::BinaryBulkProfile.with_size_stream
      )
    end

    encoded = CrystalClick::ObjectSharedPathCodec.encode(
      fixture[:dynamic], fixture[:structures], fixture[:rows],
      limits: depth_four, profile: CrystalClick::BinaryBulkProfile.with_size_stream
    )
    read_budget = CrystalClick::BinaryCodecBudget.new(depth_three)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedPathCodec.decode_with_budget(
        encoded.data, encoded.events, fixture[:rows].size, fixture[:dynamic], read_budget,
        CrystalClick::BinaryBulkProfile.with_size_stream
      )
    end
    CrystalClick::ObjectSharedPathCodec.decode(
      encoded.data, encoded.events, fixture[:rows].size, fixture[:dynamic],
      depth_four, CrystalClick::BinaryBulkProfile.with_size_stream
    ).size.should eq(fixture[:rows].size)
  end

  it "refuses declared Nested(Dynamic) products in both structure-plan directions" do
    dynamic_field = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    declared_nested = CrystalClick::BinaryDataType.nested(
      [dynamic_field] of CrystalClick::BinaryDataType, ["payload"] of String
    )

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkPlan.new(declared_nested, {} of String => CrystalClick::DynamicStructure)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
        declared_nested,
        CrystalClick::BinaryDynamicStructureStreams.new({} of String => Bytes),
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      )
    end
  end

  it "binds the Nested size and named fields to literal physical stream names" do
    fixture = w197_nested_fixture
    prepared = CrystalClick::BinaryDynamicBulkPlan.new(
      fixture[:dynamic], fixture[:structures], CrystalClick::BinaryBulkProfile.with_size_stream
    )
    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "m")
    prefix = "m.Nested%28a%20UInt8%2C%20b%20String%29"
    physical.data_stream_names.should eq({
      "root.discriminators"                      => "m.variant_discr",
      "root.arm.0.sizes"                         => "#{prefix}.size0",
      "root.arm.0.elements.field.0.data"         => "#{prefix}%2Ea",
      "root.arm.0.elements.field.1.data"         => "#{prefix}%2Eb",
      "root.arm.0.elements.field.1.string_sizes" => "#{prefix}%2Eb.size",
      "root.arm.1.data"                          => "m.SharedVariant",
      "root.arm.1.string_sizes"                  => "m.SharedVariant.size",
    })
    physical.structure_stream_names.should eq({"root.dynamic_structure" => "m.dynamic_structure"})
  end
end
