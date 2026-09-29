require "./w69_helpers"

describe CrystalClick::WidePart do
  it "retains the exact UInt64-key nullable UInt64 Array Map shape" do
    candidate = "Map(UInt64, Array(Nullable(UInt64)))"
    CrystalClick::WidePart.supports_typed_type?(candidate).should be_true
    CrystalClick::WidePart.supports_typed_type?("Map(String, Array(Nullable(UInt64)))").should be_true
    generic_w79 = "Map(UInt64, Array(Nullable(UInt32)))"
    CrystalClick::WidePart.supports_map_uint64_array_nullable_uint64_type?(generic_w79).should be_false
    CrystalClick::WidePart.map_uint64_array_nullable_numeric_value_type(generic_w79).should eq("UInt32")
    CrystalClick::WidePart.supports_typed_type?(generic_w79).should be_true

    {
      "Map(Int64, Array(Nullable(UInt64)))",
      "Map(UInt64, Array(Array(Nullable(UInt64))))",
      "Map(UInt64, Nullable(Array(Nullable(UInt64))))",
      "Map(UInt64, Array(Nullable(UInt64))) trailing",
      "Map(UInt64, Array(Nullable(UInt128)))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads W69 marks with exact row, entry, NULL-slot, and byte boundaries" do
    with_w69_part do |path|
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.column_type.should eq("Map(UInt64, Array(Nullable(UInt64)))")
      reader.row_count.should eq(7_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      reader.mark_count.should eq(4)
      reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 0, reader.mark_count)
        .should eq(W69_VALUES)

      W69_STREAMS.each do |stream|
        w69_mark_rows(path, stream).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
        # The local writer fixture uses one literal LZ4 frame per mark, so its
        # offsets are zero. The pinned stock ClickHouse probe uses shared
        # frames and is checked separately by the reader/oracle integration.
        w69_mark_decompressed_offsets(path, stream).should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
      end

      mark_rows = [2, 2, 2, 1]
      mark_raw_bytes = [34_u64, 42_u64, 60_u64, 17_u64]
      mark_charge_bytes = [130_u64, 178_u64, 196_u64, 65_u64]
      row_offset = 0
      mark_rows.each_with_index do |rows, mark_index|
        expected_rows = W69_VALUES[row_offset, rows]
        reader.read_map_uint64_array_nullable_uint64_mark_range("payload", mark_index, 1)
          .should eq(expected_rows)
        reader.map_uint64_array_nullable_uint64_mark_range_materialization_preflight("payload", mark_index, 1)
          .should eq({mark_raw_bytes[mark_index], mark_charge_bytes[mark_index]})
        row_offset += rows
      end
      reader.map_uint64_array_nullable_uint64_mark_range_raw_bytes("payload", 0, reader.mark_count)
        .should eq(153_u64)
      reader.map_uint64_array_nullable_uint64_mark_range_materialization_preflight("payload", 0, reader.mark_count)
        .should eq({153_u64, 569_u64})
      reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 2, 2)
        .should eq(W69_VALUES[4, 3])

      expect_raises(CrystalClick::BoundsError) do
        reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 0, 0)
      end
      expect_raises(CrystalClick::BoundsError) do
        reader.read_map_uint64_array_nullable_uint64_mark_range("payload", reader.mark_count, 1)
      end
    end
  end

  it "consumes the fixed UInt64 slot beneath NULL without shifting the following zero" do
    with_w69_part do |path|
      w69_rewrite_mark_frame(path, "payload%2Evalues", 0) do |raw, decompressed_offset|
        w69_write_u64(raw, decompressed_offset, UInt64::MAX)
      end
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 0, 1)
        .should eq(W69_VALUES[0, 2])
    end
  end

  it "rejects shifted boundaries in each W69 payload stream" do
    W69_STREAMS.each do |stream|
      with_w69_part do |path|
        w69_shift_mark(path, stream, 2)
        reader = CrystalClick::WidePart.open_typed(path, "payload")
        expect_raises(CrystalClick::CorruptPartError) do
          reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 2, 1)
        end
      end
    end
  end

  it "rejects inconsistent per-mark table-row counts in every W69 stream" do
    W69_STREAMS.each do |stream|
      with_w69_part do |path|
        w69_change_mark_rows(path, stream, 2, 3_u64)
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePart.open_typed(path, "payload")
        end
      end
    end
  end

  it "rejects an invalid NULL byte and nested-size disagreement before returning the mark" do
    with_w69_part do |path|
      w69_rewrite_mark_frame(path, "payload%2Evalues.null", 2) do |raw, decompressed_offset|
        raw[decompressed_offset] = 2_u8
      end
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      error = expect_raises(CrystalClick::CorruptPartError) do
        reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 2, 1)
      end
      error.to_s.should contain("null-map byte is not boolean")
    end

    with_w69_part do |path|
      w69_rewrite_mark_frame(path, "payload%2Evalues.size1", 0) do |raw, decompressed_offset|
        w69_write_u64(raw, decompressed_offset, 3_u64)
      end
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 0, 1)
      end
    end
  end

  it "keeps selected marks independent from malformed earlier nullable bytes" do
    with_w69_part do |path|
      w69_rewrite_mark_frame(path, "payload%2Evalues.null", 0) do |raw, decompressed_offset|
        raw[decompressed_offset] = 2_u8
      end
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 3, 1)
        .should eq(W69_VALUES[6, 1])
    end
  end
end
