require "./w70_helpers"

describe CrystalClick::WidePart do
  it "reads exact W70 ordered duplicate Maps and nullable nested Strings by mark" do
    with_w70_part do |path|
      reader = CrystalClick::WidePart.open_typed(path, "m")
      reader.column_type.should eq("Map(String, Array(Nullable(String)))")
      reader.row_count.should eq(7_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      reader.read_map_string_array_nullable_string_mark_range("m", 0, reader.mark_count)
        .should eq(W70_VALUES)

      expected_raw = [108_u64, 72_u64, 76_u64, 67_u64]
      expected_charge = [340_u64, 256_u64, 276_u64, 203_u64]
      row_offset = 0
      [2, 2, 2, 1].each_with_index do |rows, mark_index|
        reader.read_map_string_array_nullable_string_mark_range("m", mark_index, 1)
          .should eq(W70_VALUES[row_offset, rows])
        reader.map_string_array_nullable_string_mark_range_materialization_preflight("m", mark_index, 1)
          .should eq({expected_raw[mark_index], expected_charge[mark_index]})
        row_offset += rows
      end
      reader.map_string_array_nullable_string_mark_range_raw_bytes("m", 0, reader.mark_count)
        .should eq(323_u64)
      reader.map_string_array_nullable_string_mark_range_materialization_preflight("m", 0, reader.mark_count)
        .should eq({323_u64, 1075_u64})
      reader.read_map_string_array_nullable_string_mark_range("m", 2, 2)
        .should eq(W70_VALUES[4, 3])

      W70_STREAMS.each do |stream|
        w70_mark_rows(path, stream).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
        w70_mark_decompressed_offsets(path, stream).should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
      end

      expect_raises(CrystalClick::BoundsError) do
        reader.read_map_string_array_nullable_string_mark_range("m", 0, 0)
      end
      expect_raises(CrystalClick::BoundsError) do
        reader.read_map_string_array_nullable_string_mark_range("m", reader.mark_count, 1)
      end
    end
  end

  it "consumes hidden raw bytes under NULL without shifting the later variable String" do
    with_w70_part do |path|
      w70_rewrite_mark_frame(path, "m%2Evalues.size", 0) do |raw, offset|
        w70_write_u64(raw, offset, 1_u64)
        w70_write_u64(raw, offset + 16, 2_u64)
      end
      reader = CrystalClick::WidePart.open_typed(path, "m")
      values = W70_VALUES.dup
      values[0] = values[0].dup
      values[0][0] = {"dup", [nil, "", "\0b", "café"] of String?}
      reader.read_map_string_array_nullable_string_mark_range("m", 0, 1)
        .should eq(values[0, 2])
      # Physical preflight includes the one hidden byte, although it is not
      # retained as a visible String and therefore is not decoded byte charge.
      reader.map_string_array_nullable_string_mark_range_raw_bytes("m", 0, 1).should eq(108_u64)
    end
  end

  it "rejects shifted boundaries and inconsistent row marks in all seven streams" do
    W70_STREAMS.each do |stream|
      with_w70_part do |path|
        w70_shift_mark(path, stream, 2)
        expect_raises(CrystalClick::CorruptPartError) do
          reader = CrystalClick::WidePart.open_typed(path, "m")
          reader.read_map_string_array_nullable_string_mark_range("m", 2, 1)
        end
      end

      with_w70_part do |path|
        w70_change_mark_rows(path, stream, 2, 3_u64)
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePart.open_typed(path, "m")
        end
      end
    end
  end

  it "rejects malformed null and nested String-size slots, but isolates later marks" do
    with_w70_part do |path|
      w70_rewrite_mark_frame(path, "m%2Evalues.null", 2) do |raw, offset|
        raw[offset] = 2_u8
      end
      reader = CrystalClick::WidePart.open_typed(path, "m")
      error = expect_raises(CrystalClick::CorruptPartError) do
        reader.read_map_string_array_nullable_string_mark_range("m", 2, 1)
      end
      error.to_s.should contain("null-map byte is not boolean")
      reader.read_map_string_array_nullable_string_mark_range("m", 3, 1).should eq(W70_VALUES[6, 1])
    end

    with_w70_part do |path|
      w70_rewrite_mark_frame(path, "m%2Evalues.size1", 0) do |raw, offset|
        w70_write_u64(raw, offset, 5_u64)
      end
      reader = CrystalClick::WidePart.open_typed(path, "m")
      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_map_string_array_nullable_string_mark_range("m", 0, 1)
      end
    end
  end

  it "allows positive-row marks whose nested String child streams end empty" do
    parent = File.tempname("crystal-click-w70-reader-empty-eof")
    Dir.mkdir(parent)
    part = File.join(parent, "empty_eof")
    keys = [1_u64, 2_u64]
    values = [
      [{"", [] of String?}] of Tuple(String, Array(String?)),
      [] of Tuple(String, Array(String?)),
    ] of Array(Tuple(String, Array(String?)))
    begin
      CrystalClick::WidePartWriter.write_uint64_map_string_array_nullable_string_pair(
        part, "id", keys.to_unsafe.to_slice(keys.size), "m", values.to_unsafe.to_slice(values.size), rows_per_mark: 1
      )
      w70_ensure_terminal_mark(part, W70_STREAMS)
      reader = CrystalClick::WidePart.open_typed(part, "m")
      reader.mark_row_counts.should eq([1_u64, 1_u64])
      reader.read_map_string_array_nullable_string_mark_range("m", 0, 2).should eq(values)
      reader.map_string_array_nullable_string_mark_range_materialization_preflight("m", 1, 1)
        .should eq({0_u64, 8_u64})
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
