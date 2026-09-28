require "./w71_helpers"

describe CrystalClick::WidePart do
  it "admits only exact UInt64-key Array(Nullable(String)) Maps" do
    candidate = "Map(UInt64, Array(Nullable(String)))"
    CrystalClick::WidePart.supports_typed_type?(candidate).should be_true

    {
      "Map(UInt64, Array(String))",
      "Map(Int64, Array(Nullable(String)))",
      "Map(UInt64, Array(Array(Nullable(String))))",
      "Map(UInt64, Nullable(Array(Nullable(String))))",
      "Map(UInt64, Array(Nullable(String))) trailing",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads ordered duplicate UInt64 keys and nested nullable Strings at exact mark boundaries" do
    with_w71_part do |path|
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.column_type.should eq("Map(UInt64, Array(Nullable(String)))")
      reader.row_count.should eq(W71_KEYS.size.to_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      reader.read_map_uint64_array_nullable_string_mark_range("payload", 0, reader.mark_count)
        .should eq(W71_VALUES)
      reader.read_map_uint64_array_nullable_string_mark_range("payload", 2, 2)
        .should eq(W71_VALUES[4, 3])

      W71_STREAMS.each do |stream|
        w71_mark_rows(path, stream).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
      end

      expect_raises(CrystalClick::BoundsError) do
        reader.read_map_uint64_array_nullable_string_mark_range("payload", 0, 0)
      end
      expect_raises(CrystalClick::BoundsError) do
        reader.read_map_uint64_array_nullable_string_mark_range("payload", reader.mark_count, 1)
      end
    end
  end

  it "consumes physical bytes hidden under NULL and validates each independent mark axis" do
    with_w71_part do |path|
      w71_rewrite_mark_frame(path, "payload%2Evalues.size", 0) do |raw, offset|
        w71_write_u64(raw, offset, 1_u64)
        w71_write_u64(raw, offset + 16, 2_u64)
      end
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      expected = W71_VALUES.dup
      expected[0] = expected[0].dup
      expected[0][0] = {7_u64, [nil, "", "\0b"] of String?}
      reader.read_map_uint64_array_nullable_string_mark_range("payload", 0, 1)
        .should eq(expected[0, 2])
    end

    W71_STREAMS.each do |stream|
      with_w71_part do |path|
        w71_shift_mark(path, stream, 2)
        expect_raises(CrystalClick::CorruptPartError) do
          reader = CrystalClick::WidePart.open_typed(path, "payload")
          reader.read_map_uint64_array_nullable_string_mark_range("payload", 2, 1)
        end
      end

      with_w71_part do |path|
        w71_change_mark_rows(path, stream, 2, 3_u64)
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePart.open_typed(path, "payload")
        end
      end
    end
  end

  it "allows positive-row marks whose nested String byte stream is empty" do
    with_w71_part do |path|
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.read_map_uint64_array_nullable_string_mark_range("payload", 2, 1)
        .should eq(W71_VALUES[4, 2])
      reader.map_uint64_array_nullable_string_mark_range_materialization_preflight("payload", 2, 1)[0]
        .should eq(84_u64)

      marks = File.read(File.join(path, "#{CrystalClick::StreamName.hash("payload%2Evalues")}.mrk2")).to_slice
      start = w71_read_u64(marks, 2 * CrystalClick::WidePart::MARK_SIZE + 8)
      finish = w71_read_u64(marks, 3 * CrystalClick::WidePart::MARK_SIZE + 8)
      start.should eq(finish)
    end
  end
end
