require "./wide_part_reader_w73_helpers"

describe CrystalClick::WidePart do
  it "admits only the three exact missing W73 non-null Map Array cells" do
    {
      "Map(UInt64, Array(UInt64))",
      "Map(String, Array(String))",
      "Map(UInt64, Array(String))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end

    {
      "Map(Int64, Array(UInt64))",
      "Map(UInt64, Array(Int64))",
      "Map(String, Array(Nullable(Int64)))",
      "Map(UInt64, Array(Nullable(Int64)))",
      "Map(UInt64, Array(Array(UInt64)))",
      "Map(UInt64, Nullable(Array(UInt64)))",
      "Map(UInt64, Array(String)) trailing",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads exact U64-key/U64-leaf Maps across marks with duplicate keys and empty Arrays" do
    with_w73_reader_u64_u64_part do |path|
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.column_type.should eq("Map(UInt64, Array(UInt64))")
      reader.row_count.should eq(W73_READER_KEYS.size.to_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_map_uint64_array_uint64_mark_range("payload", 0, reader.mark_count)
        .should eq(W73_READER_U64_U64_VALUES)
      reader.read_map_uint64_array_uint64_mark_range("payload", 1, 2)
        .should eq(W73_READER_U64_U64_VALUES[2, 3])
      reader.map_uint64_array_uint64_mark_range_raw_bytes("payload", 0, reader.mark_count)
        .should eq(8_u64 * 6 + 8_u64 * 8)
      reader.map_uint64_array_uint64_mark_range_materialization_preflight("payload", 0, reader.mark_count)[0]
        .should eq(8_u64 * 6 + 8_u64 * 8)
      reader.map_uint64_array_uint64_mark_range_materialization_preflight("payload", 0, reader.mark_count)[1]
        .should eq(392_u64)

      W73_READER_U64_U64_STREAMS.each do |stream|
        w71_mark_rows(path, stream).should eq([2_u64, 2_u64, 1_u64, 0_u64])
      end
    end
  end

  it "reads exact String-key/String-leaf Maps with binary Strings and a short final mark" do
    with_w73_reader_string_string_part do |path|
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.column_type.should eq("Map(String, Array(String))")
      reader.row_count.should eq(W73_READER_KEYS.size.to_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_map_string_array_string_mark_range("payload", 0, reader.mark_count)
        .should eq(W73_READER_STRING_STRING_VALUES)
      reader.read_map_string_array_string_mark_range("payload", 1, 2)
        .should eq(W73_READER_STRING_STRING_VALUES[2, 3])
      reader.read_map_string_array_string_mark_range("payload", 2, 1)
        .should eq(W73_READER_STRING_STRING_VALUES[4, 1])
      reader.map_string_array_string_mark_range_materialization_preflight("payload", 0, reader.mark_count)
        .should eq({217_u64, 665_u64})
      reader.map_string_array_string_mark_range_raw_bytes("payload", 0, reader.mark_count)
        .should eq(217_u64)
      W73_READER_STRING_STRING_STREAMS.each do |stream|
        w71_mark_rows(path, stream).should eq([2_u64, 2_u64, 1_u64, 0_u64])
      end

      expect_raises(CrystalClick::BoundsError) do
        reader.read_map_string_array_string_mark_range("payload", 0, 0)
      end
      expect_raises(CrystalClick::BoundsError) do
        reader.read_map_string_array_string_mark_range("payload", reader.mark_count, 1)
      end
    end
  end

  it "reads exact U64-key/String-leaf Maps without conflating row, entry, element, or byte counts" do
    with_w73_reader_u64_string_part do |path|
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.column_type.should eq("Map(UInt64, Array(String))")
      reader.row_count.should eq(W73_READER_KEYS.size.to_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_map_uint64_array_string_mark_range("payload", 0, reader.mark_count)
        .should eq(W73_READER_U64_STRING_VALUES)
      reader.read_map_uint64_array_string_mark_range("payload", 1, 2)
        .should eq(W73_READER_U64_STRING_VALUES[2, 3])
      reader.map_uint64_array_string_mark_range_materialization_preflight("payload", 0, reader.mark_count)
        .should eq({189_u64, 637_u64})
      reader.map_uint64_array_string_mark_range_raw_bytes("payload", 0, reader.mark_count)
        .should eq(189_u64)
      W73_READER_U64_STRING_STREAMS.each do |stream|
        w71_mark_rows(path, stream).should eq([2_u64, 2_u64, 1_u64, 0_u64])
      end
    end
  end

  it "rejects a shifted later mark independently on every W73 stream" do
    W73_READER_U64_U64_STREAMS.each do |stream|
      with_w73_reader_u64_u64_part do |path|
        w71_shift_mark(path, stream, 2)
        expect_raises(CrystalClick::CorruptPartError) do
          reader = CrystalClick::WidePart.open_typed(path, "payload")
          reader.read_map_uint64_array_uint64_mark_range("payload", 2, 1)
        end
      end
    end

    W73_READER_STRING_STRING_STREAMS.each do |stream|
      with_w73_reader_string_string_part do |path|
        w71_shift_mark(path, stream, 2)
        expect_raises(CrystalClick::CorruptPartError) do
          reader = CrystalClick::WidePart.open_typed(path, "payload")
          reader.read_map_string_array_string_mark_range("payload", 2, 1)
        end
      end
    end

    W73_READER_U64_STRING_STREAMS.each do |stream|
      with_w73_reader_u64_string_part do |path|
        w71_shift_mark(path, stream, 2)
        expect_raises(CrystalClick::CorruptPartError) do
          reader = CrystalClick::WidePart.open_typed(path, "payload")
          reader.read_map_uint64_array_string_mark_range("payload", 2, 1)
        end
      end
    end
  end

  it "rejects child mark row counts that drift by ordinal with unchanged aggregate" do
    with_w73_reader_u64_u64_part do |path|
      stream = "payload%2Evalues.size1"
      w71_change_mark_rows(path, stream, 0, 1_u64)
      w71_change_mark_rows(path, stream, 1, 3_u64)
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(path, "payload")
      end
      error.message.should eq("selected substreams have different mark row counts")
    end

    with_w73_reader_string_string_part do |path|
      stream = "payload%2Evalues.size1"
      w71_change_mark_rows(path, stream, 0, 1_u64)
      w71_change_mark_rows(path, stream, 1, 3_u64)
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(path, "payload")
      end
      error.message.should eq("selected substreams have different mark row counts")
    end

    with_w73_reader_u64_string_part do |path|
      stream = "payload%2Evalues.size1"
      w71_change_mark_rows(path, stream, 0, 1_u64)
      w71_change_mark_rows(path, stream, 1, 3_u64)
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(path, "payload")
      end
      error.message.should eq("selected substreams have different mark row counts")
    end
  end

  it "accepts positive-row empty leaf streams before later nonempty tails" do
    parent = File.tempname("crystal-click-w73-reader-empty-leaves")
    Dir.mkdir(parent)
    begin
      u64_part = File.join(parent, "u64")
      u64_keys = [1_u64, 2_u64, 3_u64]
      u64_values = [
        [{1_u64, [] of UInt64}] of Tuple(UInt64, Array(UInt64)),
        [{2_u64, [7_u64]}] of Tuple(UInt64, Array(UInt64)),
        [{3_u64, [UInt64::MAX]}] of Tuple(UInt64, Array(UInt64)),
      ] of Array(Tuple(UInt64, Array(UInt64)))
      CrystalClick::WidePartWriter.write_uint64_map_uint64_array_uint64_pair(
        u64_part, "pk", u64_keys.to_unsafe.to_slice(u64_keys.size), "payload",
        u64_values.to_unsafe.to_slice(u64_values.size), rows_per_mark: 1
      )
      u64_reader = CrystalClick::WidePart.open_typed(u64_part, "payload")
      u64_reader.read_map_uint64_array_uint64_mark_range("payload", 0, 3).should eq(u64_values)
      u64_reader.map_uint64_array_uint64_mark_range_materialization_preflight("payload", 0, 1)[0]
        .should eq(8_u64)
      u64_value_marks = File.read(File.join(u64_part, "#{CrystalClick::StreamName.hash("payload%2Evalues")}.mrk2")).to_slice
      w71_read_u64(u64_value_marks, 8).should eq(w71_read_u64(u64_value_marks, CrystalClick::WidePart::MARK_SIZE + 8))

      string_part = File.join(parent, "string")
      string_values = [
        [{1_u64, [] of String}] of Tuple(UInt64, Array(String)),
        [{2_u64, [""] of String}] of Tuple(UInt64, Array(String)),
        [{3_u64, ["tail"] of String}] of Tuple(UInt64, Array(String)),
      ] of Array(Tuple(UInt64, Array(String)))
      CrystalClick::WidePartWriter.write_uint64_map_uint64_array_string_pair(
        string_part, "pk", u64_keys.to_unsafe.to_slice(u64_keys.size), "payload",
        string_values.to_unsafe.to_slice(string_values.size), rows_per_mark: 1
      )
      string_reader = CrystalClick::WidePart.open_typed(string_part, "payload")
      string_reader.read_map_uint64_array_string_mark_range("payload", 0, 3).should eq(string_values)
      string_reader.map_uint64_array_string_mark_range_materialization_preflight("payload", 0, 1)[0]
        .should eq(16_u64)
      string_value_marks = File.read(File.join(string_part, "#{CrystalClick::StreamName.hash("payload%2Evalues")}.mrk2")).to_slice
      w71_read_u64(string_value_marks, 8).should eq(w71_read_u64(string_value_marks, CrystalClick::WidePart::MARK_SIZE + 8))
      string_reader.read_map_uint64_array_string_mark_range("payload", 2, 1).should eq(string_values[2, 1])

      all_empty_part = File.join(parent, "all_empty")
      all_empty_keys = [1_u64, 2_u64]
      all_empty_u64_maps = [
        [] of Tuple(UInt64, Array(UInt64)),
        [] of Tuple(UInt64, Array(UInt64)),
      ] of Array(Tuple(UInt64, Array(UInt64)))
      CrystalClick::WidePartWriter.write_uint64_map_uint64_array_uint64_pair(
        all_empty_part, "pk", all_empty_keys.to_unsafe.to_slice(all_empty_keys.size), "payload",
        all_empty_u64_maps.to_unsafe.to_slice(all_empty_u64_maps.size), rows_per_mark: 1
      )
      all_empty_u64_reader = CrystalClick::WidePart.open_typed(all_empty_part, "payload")
      all_empty_u64_reader.mark_row_counts.should eq([1_u64, 1_u64])
      all_empty_u64_reader.read_map_uint64_array_uint64_mark_range("payload", 0, 2).should eq(all_empty_u64_maps)
      all_empty_u64_reader.map_uint64_array_uint64_mark_range_materialization_preflight("payload", 0, 2)
        .should eq({0_u64, 16_u64})
      w73_reader_encoded_stream(all_empty_part, "payload%2Evalues").should be_empty

      all_empty_string_maps = [
        [] of Tuple(String, Array(String)),
        [] of Tuple(String, Array(String)),
      ] of Array(Tuple(String, Array(String)))
      CrystalClick::WidePartWriter.write_uint64_map_string_array_string_pair(
        File.join(parent, "all_empty_string"), "pk", all_empty_keys.to_unsafe.to_slice(all_empty_keys.size), "payload",
        all_empty_string_maps.to_unsafe.to_slice(all_empty_string_maps.size), rows_per_mark: 1
      )
      all_empty_string_part = File.join(parent, "all_empty_string")
      all_empty_string_reader = CrystalClick::WidePart.open_typed(all_empty_string_part, "payload")
      all_empty_string_reader.mark_row_counts.should eq([1_u64, 1_u64])
      all_empty_string_reader.read_map_string_array_string_mark_range("payload", 0, 2).should eq(all_empty_string_maps)
      all_empty_string_reader.map_string_array_string_mark_range_materialization_preflight("payload", 0, 2)
        .should eq({0_u64, 16_u64})
      w73_reader_encoded_stream(all_empty_string_part, "payload%2Evalues.size").should be_empty
      w73_reader_encoded_stream(all_empty_string_part, "payload%2Evalues").should be_empty

      all_empty_u64_string_maps = [
        [] of Tuple(UInt64, Array(String)),
        [] of Tuple(UInt64, Array(String)),
      ] of Array(Tuple(UInt64, Array(String)))
      all_empty_u64_string_part = File.join(parent, "all_empty_u64_string")
      CrystalClick::WidePartWriter.write_uint64_map_uint64_array_string_pair(
        all_empty_u64_string_part, "pk", all_empty_keys.to_unsafe.to_slice(all_empty_keys.size), "payload",
        all_empty_u64_string_maps.to_unsafe.to_slice(all_empty_u64_string_maps.size), rows_per_mark: 1
      )
      all_empty_u64_string_reader = CrystalClick::WidePart.open_typed(all_empty_u64_string_part, "payload")
      all_empty_u64_string_reader.mark_row_counts.should eq([1_u64, 1_u64])
      all_empty_u64_string_reader.read_map_uint64_array_string_mark_range("payload", 0, 2).should eq(all_empty_u64_string_maps)
      all_empty_u64_string_reader.map_uint64_array_string_mark_range_materialization_preflight("payload", 0, 2)
        .should eq({0_u64, 16_u64})
      w73_reader_encoded_stream(all_empty_u64_string_part, "payload%2Evalues.size").should be_empty
      w73_reader_encoded_stream(all_empty_u64_string_part, "payload%2Evalues").should be_empty

      empty_children_u64 = [
        [{1_u64, [] of UInt64}, {2_u64, [] of UInt64}] of Tuple(UInt64, Array(UInt64)),
        [{3_u64, [] of UInt64}] of Tuple(UInt64, Array(UInt64)),
      ] of Array(Tuple(UInt64, Array(UInt64)))
      empty_children_u64_part = File.join(parent, "empty_children_u64")
      CrystalClick::WidePartWriter.write_uint64_map_uint64_array_uint64_pair(
        empty_children_u64_part, "pk", all_empty_keys.to_unsafe.to_slice(all_empty_keys.size), "payload",
        empty_children_u64.to_unsafe.to_slice(empty_children_u64.size), rows_per_mark: 1
      )
      empty_children_u64_reader = CrystalClick::WidePart.open_typed(empty_children_u64_part, "payload")
      empty_children_u64_reader.read_map_uint64_array_uint64_mark_range("payload", 0, 2).should eq(empty_children_u64)
      empty_children_u64_reader.map_uint64_array_uint64_mark_range_materialization_preflight("payload", 0, 2)
        .should eq({24_u64, 160_u64})
      w73_reader_encoded_stream(empty_children_u64_part, "payload%2Evalues").should be_empty

      empty_children_string = [
        [{"a", [] of String}, {"a", [] of String}] of Tuple(String, Array(String)),
        [{"b", [] of String}] of Tuple(String, Array(String)),
      ] of Array(Tuple(String, Array(String)))
      empty_children_string_part = File.join(parent, "empty_children_string")
      CrystalClick::WidePartWriter.write_uint64_map_string_array_string_pair(
        empty_children_string_part, "pk", all_empty_keys.to_unsafe.to_slice(all_empty_keys.size), "payload",
        empty_children_string.to_unsafe.to_slice(empty_children_string.size), rows_per_mark: 1
      )
      empty_children_string_reader = CrystalClick::WidePart.open_typed(empty_children_string_part, "payload")
      empty_children_string_reader.read_map_string_array_string_mark_range("payload", 0, 2).should eq(empty_children_string)
      empty_children_string_reader.map_string_array_string_mark_range_materialization_preflight("payload", 0, 2)
        .should eq({51_u64, 187_u64})
      w73_reader_encoded_stream(empty_children_string_part, "payload%2Evalues.size").should be_empty
      w73_reader_encoded_stream(empty_children_string_part, "payload%2Evalues").should be_empty

      empty_children_u64_string = [
        [{1_u64, [] of String}, {2_u64, [] of String}] of Tuple(UInt64, Array(String)),
        [{3_u64, [] of String}] of Tuple(UInt64, Array(String)),
      ] of Array(Tuple(UInt64, Array(String)))
      empty_children_u64_string_part = File.join(parent, "empty_children_u64_string")
      CrystalClick::WidePartWriter.write_uint64_map_uint64_array_string_pair(
        empty_children_u64_string_part, "pk", all_empty_keys.to_unsafe.to_slice(all_empty_keys.size), "payload",
        empty_children_u64_string.to_unsafe.to_slice(empty_children_u64_string.size), rows_per_mark: 1
      )
      empty_children_u64_string_reader = CrystalClick::WidePart.open_typed(empty_children_u64_string_part, "payload")
      empty_children_u64_string_reader.read_map_uint64_array_string_mark_range("payload", 0, 2).should eq(empty_children_u64_string)
      empty_children_u64_string_reader.map_uint64_array_string_mark_range_materialization_preflight("payload", 0, 2)
        .should eq({48_u64, 184_u64})
      w73_reader_encoded_stream(empty_children_u64_string_part, "payload%2Evalues.size").should be_empty
      w73_reader_encoded_stream(empty_children_u64_string_part, "payload%2Evalues").should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
