require "./spec_helper"

private def w230_try_array_type(child : CrystalClick::BinaryDataType) : CrystalClick::BinaryDataType?
  CrystalClick::BinaryDataType.array(child)
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w230_qbit_value(type : CrystalClick::QBitType, raw : Bytes) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(type, raw))
end

private def w230_array_value(
  type : CrystalClick::BinaryDataType,
  children : Array(CrystalClick::BinaryValue),
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.array(type, children)
end

describe "W230 static recursive QBit values" do
  it "parses canonical QBit leaves through the shared recursive declaration reader" do
    [
      "QBit(Int8, 3)",
      "QBit(BFloat16, 16, 8)",
      "QBit(Float64, 9)",
      "Array(Array(Nullable(QBit(Float32, 16, 8))))",
    ].each do |source|
      parsed = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(source)
      parsed.should_not be_nil
      parsed.not_nil!.name.should eq(source)
    end

    [
      "QBit(UInt8, 8)",
      "QBit(Float32, 0)",
      "QBit(Float32, 16, 3)",
      "QBit(Float32, 16, 16)",
      "QBit(Float32, 08)",
      "QBit(Float32,16)",
    ].each do |source|
      CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(source).should be_nil
    end

    narrow_metadata = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 2,
      max_elements: 16,
      max_bytes: 256,
    )
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(
      "Array(QBit(Int8, 3))",
      narrow_metadata,
    ).should be_nil
  end

  it "admits exact Array descriptors and RowBinary values without flattening the nominal tree" do
    qbit_type = CrystalClick::QBitType.new("Int8", 3_u64)
    qbit_descriptor = CrystalClick::BinaryDataType.qbit(qbit_type)
    candidate = w230_try_array_type(qbit_descriptor)
    candidate.should_not be_nil

    if array_type = candidate
      array_type.name.should eq("Array(QBit(Int8, 3))")
      CrystalClick::BinaryDataTypeCodec.encode(array_type).should eq(
        Bytes[0x1e_u8, 0x36_u8, 0x07_u8, 0x03_u8]
      )
      CrystalClick::BinaryDataTypeCodec.decode(
        Bytes[0x1e_u8, 0x36_u8, 0x07_u8, 0x03_u8]
      ).should eq(array_type)

      first = w230_qbit_value(qbit_type, Bytes[0xff_u8, 0x00_u8, 0x80_u8])
      second = w230_qbit_value(qbit_type, Bytes[0x00_u8, 0x7f_u8, 0x40_u8])
      multi = w230_array_value(array_type, [first, second] of CrystalClick::BinaryValue)
      rowbinary = Bytes[
        0x02_u8,
        0x03_u8, 0xff_u8, 0x00_u8, 0x80_u8,
        0x03_u8, 0x00_u8, 0x7f_u8, 0x40_u8,
      ]
      CrystalClick::BinaryValueCodec.encode_value(multi).should eq(rowbinary)
      CrystalClick::BinaryValueCodec.decode_value(array_type, rowbinary).should eq(multi)

      envelope = CrystalClick::BinaryValueCodec.encode(multi)
      CrystalClick::BinaryValueCodec.decode(envelope).should eq(multi)
      envelope[0, 4].should eq(CrystalClick::BinaryDataTypeCodec.encode(array_type))
    end
  end

  it "keeps empty, singleton, multi-element, and nested QBit values equal and hash-consistent" do
    qbit_type = CrystalClick::QBitType.new("Int8", 3_u64)
    qbit_descriptor = CrystalClick::BinaryDataType.qbit(qbit_type)
    array_candidate = w230_try_array_type(qbit_descriptor)
    array_candidate.should_not be_nil

    if array_type = array_candidate
      first = w230_qbit_value(qbit_type, Bytes[0xff_u8, 0x00_u8, 0x80_u8])
      second = w230_qbit_value(qbit_type, Bytes[0x00_u8, 0x7f_u8, 0x40_u8])
      empty = w230_array_value(array_type, [] of CrystalClick::BinaryValue)
      singleton = w230_array_value(array_type, [first] of CrystalClick::BinaryValue)
      multiple = w230_array_value(array_type, [first, second] of CrystalClick::BinaryValue)

      [empty, singleton, multiple].each do |value|
        restored = CrystalClick::BinaryValueCodec.decode(
          CrystalClick::BinaryValueCodec.encode(value)
        )
        restored.should eq(value)
        restored.hash.should eq(value.hash)
        {value => "owned"}[restored].should eq("owned")
      end
      multiple.should_not eq(singleton)

      inner_candidate = w230_try_array_type(array_type)
      inner_candidate.should_not be_nil
      if nested_type = inner_candidate
        empty_inner = w230_array_value(array_type, [] of CrystalClick::BinaryValue)
        one_inner = w230_array_value(array_type, [first] of CrystalClick::BinaryValue)
        nested_empty = w230_array_value(nested_type, [] of CrystalClick::BinaryValue)
        nested_with_empty = w230_array_value(nested_type, [empty_inner] of CrystalClick::BinaryValue)
        nested_multi = w230_array_value(
          nested_type,
          [one_inner, empty_inner, w230_array_value(array_type, [second] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
        )

        [nested_empty, nested_with_empty, nested_multi].each do |value|
          restored = CrystalClick::BinaryValueCodec.decode(
            CrystalClick::BinaryValueCodec.encode(value)
          )
          restored.should eq(value)
          restored.hash.should eq(value.hash)
        end
        nested_multi.element_at(0).element_at(0).qbit_value.raw_bytes.should eq(first.qbit_value.raw_bytes)
      end
    end
  end

  it "preserves Float32 negative-zero and distinct NaN payloads inside empty, singleton, and multi Arrays" do
    qbit_type = CrystalClick::QBitType.new("Float32", 3_u64)
    qbit_descriptor = CrystalClick::BinaryDataType.qbit(qbit_type)
    array_candidate = w230_try_array_type(qbit_descriptor)
    array_candidate.should_not be_nil

    if array_type = array_candidate
      negative_zero_and_nans = w230_qbit_value(
        qbit_type,
        Bytes[
          0x00_u8, 0x00, 0x00, 0x80,
          0x01, 0x00, 0xc0, 0x7f,
          0x02, 0x00, 0xc0, 0x7f,
        ],
      )
      distinct_nan_order = w230_qbit_value(
        qbit_type,
        Bytes[
          0x00_u8, 0x00, 0x00, 0x80,
          0x02, 0x00, 0xc0, 0x7f,
          0x01, 0x00, 0xc0, 0x7f,
        ],
      )
      empty = w230_array_value(array_type, [] of CrystalClick::BinaryValue)
      singleton = w230_array_value(array_type, [negative_zero_and_nans] of CrystalClick::BinaryValue)
      multiple = w230_array_value(
        array_type,
        [negative_zero_and_nans, distinct_nan_order] of CrystalClick::BinaryValue,
      )

      empty_wire = Bytes[0x00_u8]
      singleton_wire = Bytes[
        0x01_u8, 0x03,
        0x00, 0x00, 0x00, 0x80,
        0x01, 0x00, 0xc0, 0x7f,
        0x02, 0x00, 0xc0, 0x7f,
      ]
      multiple_wire = Bytes[
        0x02_u8, 0x03,
        0x00, 0x00, 0x00, 0x80,
        0x01, 0x00, 0xc0, 0x7f,
        0x02, 0x00, 0xc0, 0x7f,
        0x03,
        0x00, 0x00, 0x00, 0x80,
        0x02, 0x00, 0xc0, 0x7f,
        0x01, 0x00, 0xc0, 0x7f,
      ]
      [
        {empty, empty_wire},
        {singleton, singleton_wire},
        {multiple, multiple_wire},
      ].each do |value, expected_wire|
        encoded = CrystalClick::BinaryValueCodec.encode_value(value)
        encoded.should eq(expected_wire)
        restored = CrystalClick::BinaryValueCodec.decode_value(array_type, expected_wire)
        restored.should eq(value)
        restored.hash.should eq(value.hash)
        {value => "owned"}[restored].should eq("owned")
      end
      multiple.should_not eq(
        w230_array_value(array_type, [distinct_nan_order, negative_zero_and_nans] of CrystalClick::BinaryValue)
      )
      # The two payloads differ only in the low payload bit; neither numeric
      # conversion nor normalization may collapse them.
      negative_zero_and_nans.qbit_value.raw_bytes[3].should eq(0x80_u8)
      negative_zero_and_nans.qbit_value.raw_bytes[4, 4].should_not eq(
        negative_zero_and_nans.qbit_value.raw_bytes[8, 4]
      )
    end
  end

  it "bounds aggregate recursive role metadata independently from terminal QBit roles" do
    wide_qbit = CrystalClick::BinaryDataType.qbit(
      CrystalClick::QBitType.new("Int8", 524_288_u64)
    )
    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 4_096,
      max_elements: 1_000_000,
      max_bytes: 4_096,
    )
    deep_type = wide_qbit
    50.times do
      deep_type = CrystalClick::BinaryDataType.array(deep_type)
    end
    # The path is `root` plus fifty `.elements` edges. The eight Int8 QBit
    # plane suffixes fit by themselves; the ancestor Array size names do not.
    terminal_path_bytes = 4_i64 + 50_i64 * ".elements".bytesize
    terminal_plane_bytes = 0_i64
    8.times do |plane|
      terminal_plane_bytes += terminal_path_bytes + ".qbit_plane.".bytesize + plane.to_s.bytesize
    end
    terminal_plane_bytes.should be < limits.max_bytes

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkTypePlan.new(
        deep_type,
        CrystalClick::BinaryBulkProfile.single_stream,
        nil,
        limits,
        true,
      ).roles
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkTypePlan.new(
        deep_type,
        CrystalClick::BinaryBulkProfile.single_stream,
        nil,
        limits,
        false,
      ).roles
    end
  end

  it "refuses a plane scratch buffer larger than the byte budget even for an empty child" do
    wide_qbit = CrystalClick::BinaryDataType.qbit(
      CrystalClick::QBitType.new("Int8", 524_288_u64)
    )
    array_type = CrystalClick::BinaryDataType.array(wide_qbit)
    empty = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
    scratch_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 4_096,
      max_elements: 1_000_000,
      max_bytes: 256,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(
        array_type,
        [[empty] of CrystalClick::BinaryValue],
        scratch_limits,
      )
    end
  end

  it "enforces small recursive codec depth, role-count, and payload budgets" do
    small_qbit = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 3_u64))
    small_array = CrystalClick::BinaryDataType.array(small_qbit)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(
        small_array,
        CrystalClick::BinaryCodecLimits.new(max_depth: 1, max_nodes: 16, max_elements: 16, max_bytes: 64),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkTypePlan.new(
        small_array,
        CrystalClick::BinaryBulkProfile.single_stream,
        nil,
        CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 64, max_elements: 4, max_bytes: 256),
        true,
      )
    end
    small_value = w230_qbit_value(CrystalClick::QBitType.new("Int8", 3_u64), Bytes[1_u8, 2, 3])
    one = w230_array_value(small_array, [small_value] of CrystalClick::BinaryValue)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(
        one,
        CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 64, max_elements: 64, max_bytes: 4),
      )
    end
  end

  it "rejects missing, extra, and truncated recursive lanes" do
    qbit_type = CrystalClick::QBitType.new("Int8", 9_u64)
    qbit_descriptor = CrystalClick::BinaryDataType.qbit(qbit_type)
    array_type = w230_try_array_type(qbit_descriptor).not_nil!
    scalar = w230_qbit_value(qbit_type, Bytes.new(9) { |index| (index + 1).to_u8 })
    value = w230_array_value(array_type, [scalar] of CrystalClick::BinaryValue)
    streams = CrystalClick::BinaryBulkCodec.encode(array_type, [[value] of CrystalClick::BinaryValue])

    missing = Hash(String, CrystalClick::BinaryBulkStream).new
    streams.roles.each do |role|
      next if role.ends_with?(".qbit_plane.0")
      missing[role] = streams.stream(role)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(
        array_type,
        CrystalClick::BinaryBulkStreams.new(streams.mark_count, missing),
        [1_u64],
      )
    end

    extra = Hash(String, CrystalClick::BinaryBulkStream).new
    streams.roles.each { |role| extra[role] = streams.stream(role) }
    extra["root.unexpected"] = CrystalClick::BinaryBulkStream.new(Bytes.empty, [0_u64, 0_u64])
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(
        array_type,
        CrystalClick::BinaryBulkStreams.new(streams.mark_count, extra),
        [1_u64],
      )
    end

    truncated = Hash(String, CrystalClick::BinaryBulkStream).new
    streams.roles.each do |role|
      truncated[role] = if role.ends_with?(".qbit_plane.0")
                          CrystalClick::BinaryBulkStream.new(Bytes.empty, [0_u64, 2_u64])
                        else
                          streams.stream(role)
                        end
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(
        array_type,
        CrystalClick::BinaryBulkStreams.new(streams.mark_count, truncated),
        [1_u64],
      )
    end
  end

  it "preserves nullable leaf slots and recursive Array schedules in the bulk codec" do
    qbit_type = CrystalClick::QBitType.new("Int8", 9_u64)
    qbit_descriptor = CrystalClick::BinaryDataType.qbit(qbit_type)
    nullable_candidate = begin
      CrystalClick::BinaryDataType.nullable(qbit_descriptor)
    rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
      nil
    end
    nullable_candidate.should_not be_nil

    if nullable_type = nullable_candidate
      array_candidate = w230_try_array_type(nullable_type)
      array_candidate.should_not be_nil
      if array_type = array_candidate
        first = w230_qbit_value(qbit_type, Bytes.new(9) { |index| (index + 1).to_u8 })
        second = w230_qbit_value(qbit_type, Bytes.new(9) { |index| (index + 17).to_u8 })
        present_first = CrystalClick::BinaryValue.nullable(nullable_type, first)
        present_second = CrystalClick::BinaryValue.nullable(nullable_type, second)
        absent = CrystalClick::BinaryValue.nullable(nullable_type)
        empty = w230_array_value(array_type, [] of CrystalClick::BinaryValue)
        marks = [
          [w230_array_value(array_type, [present_first, absent] of CrystalClick::BinaryValue), empty] of CrystalClick::BinaryValue,
          [empty, empty] of CrystalClick::BinaryValue,
          [w230_array_value(array_type, [present_second] of CrystalClick::BinaryValue),
           w230_array_value(array_type, [absent, present_first] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
        ] of Array(CrystalClick::BinaryValue)

        streams = CrystalClick::BinaryBulkCodec.encode(array_type, marks)
        streams.mark_count.should eq(3)
        streams.roles.any? { |role| role.ends_with?(".sizes") }.should be_true
        streams.roles.any? { |role| role.ends_with?(".nulls") }.should be_true
        streams.roles.any? { |role| role.ends_with?(".qbit_plane.0") }.should be_true

        decoded = CrystalClick::BinaryBulkCodec.decode(array_type, streams, [2_u64, 2_u64, 2_u64])
        decoded.should eq(marks)
        decoded[0][0].element_at(1).is_null?.should be_true
        decoded[0][0].element_at(0).child_at(0).qbit_value.raw_bytes.should eq(first.qbit_value.raw_bytes)
        decoded[1].map(&.element_count).should eq([0, 0])
        decoded[2][1].element_at(0).is_null?.should be_true
        decoded[2][1].element_at(1).child_at(0).qbit_value.raw_bytes.should eq(first.qbit_value.raw_bytes)

        inner_candidate = w230_try_array_type(qbit_descriptor)
        inner_candidate.should_not be_nil
        if inner_type = inner_candidate
          outer_candidate = w230_try_array_type(inner_type)
          outer_candidate.should_not be_nil
          if outer_type = outer_candidate
            inner_two = w230_array_value(inner_type, [first, second] of CrystalClick::BinaryValue)
            inner_empty = w230_array_value(inner_type, [] of CrystalClick::BinaryValue)
            inner_one = w230_array_value(inner_type, [second] of CrystalClick::BinaryValue)
            nested_marks = [
              [w230_array_value(outer_type, [inner_two, inner_empty] of CrystalClick::BinaryValue),
               w230_array_value(outer_type, [] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
              [w230_array_value(outer_type, [inner_empty] of CrystalClick::BinaryValue),
               w230_array_value(outer_type, [] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
              [w230_array_value(outer_type, [inner_one, inner_two] of CrystalClick::BinaryValue),
               w230_array_value(outer_type, [] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
            ] of Array(CrystalClick::BinaryValue)
            nested_streams = CrystalClick::BinaryBulkCodec.encode(outer_type, nested_marks)
            nested_streams.mark_count.should eq(3)
            nested_decoded = CrystalClick::BinaryBulkCodec.decode(
              outer_type,
              nested_streams,
              [2_u64, 2_u64, 2_u64],
            )
            nested_decoded.should eq(nested_marks)
            nested_decoded[0][0].element_at(0).element_count.should eq(2)
            nested_decoded[0][0].element_at(1).element_count.should eq(0)
            nested_decoded[1][0].element_count.should eq(1)
            nested_decoded[1][0].element_at(0).element_count.should eq(0)
            nested_decoded[2][0].element_at(1).element_at(1).qbit_value.raw_bytes.should eq(second.qbit_value.raw_bytes)
          end
        end
      end
    end
  end

  it "rejects plane-lane disagreement and retains the closed non-Array composition boundaries" do
    qbit_type = CrystalClick::QBitType.new("Int8", 9_u64)
    qbit_descriptor = CrystalClick::BinaryDataType.qbit(qbit_type)
    array_candidate = w230_try_array_type(qbit_descriptor)
    array_candidate.should_not be_nil

    if array_type = array_candidate
      scalar = w230_qbit_value(qbit_type, Bytes.new(9) { |index| (index + 1).to_u8 })
      value = w230_array_value(array_type, [scalar] of CrystalClick::BinaryValue)
      streams = CrystalClick::BinaryBulkCodec.encode(array_type, [[value], [value]])
      changed = Hash(String, CrystalClick::BinaryBulkStream).new
      streams.roles.each do |role|
        lane = streams.stream(role)
        if role.ends_with?(".qbit_plane.0")
          offsets = lane.offsets
          # Keep the complete lane span intact while making the first mark
          # delta disagree with all other planes.
          offsets[1] = offsets[1] + 1_u64
          changed[role] = CrystalClick::BinaryBulkStream.new(lane.bytes, offsets)
        else
          changed[role] = lane
        end
      end
      malformed = CrystalClick::BinaryBulkStreams.new(streams.mark_count, changed)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryBulkCodec.decode(array_type, malformed, [1_u64, 1_u64])
      end
    end

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.tuple([qbit_descriptor] of CrystalClick::BinaryDataType)
    end
    # Nullable(Array(QBit)) remains rejected once Array(QBit) is admitted.
    if recursive_array = w230_try_array_type(qbit_descriptor)
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.nullable(recursive_array)
      end
    end
  end
end
