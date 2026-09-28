require "./w71_helpers"

describe CrystalClick::WidePartWriter do
  it "writes exact UInt64-key nested nullable String streams and preserves ordered duplicates" do
    with_w71_part do |path|
      File.read(File.join(path, "columns.txt")).should contain("`payload` Map(UInt64, Array(Nullable(String)))")
      File.read(File.join(path, "columns_substreams.txt")).should contain(
        "payload.size0\n\tpayload%2Ekeys\n\tpayload%2Evalues.size1\n" +
        "\tpayload%2Evalues.null\n\tpayload%2Evalues.size\n\tpayload%2Evalues\n"
      )

      w71_raw_u64_stream(path, "payload.size0").should eq([3_u64, 0_u64, 1_u64, 2_u64, 2_u64, 1_u64, 2_u64])
      w71_raw_u64_stream(path, "payload%2Ekeys").should eq([7_u64, 7_u64, 7_u64, 0_u64, UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX, 9_u64, 9_u64, 10_u64])
      w71_raw_u64_stream(path, "payload%2Evalues.size1").should eq([3_u64, 2_u64, 1_u64, 3_u64, 0_u64, 0_u64, 2_u64, 2_u64, 0_u64, 2_u64, 1_u64])
      w71_raw_stream(path, "payload%2Evalues.null").should eq([1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0_u8, 0_u8, 1_u8, 1_u8, 1_u8, 1_u8, 1_u8, 0_u8, 0_u8])
      w71_raw_u64_stream(path, "payload%2Evalues.size").should eq([0_u64, 0_u64, 3_u64, 5_u64, 3_u64, 10_u64, 0_u64, 3_u64, 4_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 10_u64, 5_u64])
      w71_raw_stream(path, "payload%2Evalues").should eq("a\0bcaféabcafter-nullabcwxyzafter-nulltail2".to_slice.to_a)

      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.read_map_uint64_array_nullable_string_mark_range("payload", 0, reader.mark_count)
        .should eq(W71_VALUES)
      checksums = CrystalClick::PartChecksums.open(path)
      checksums.entries.each_key { |name| checksums.validate_selected_entries(path, name) }
    end
  end

  it "accepts the W71 Default serializer when a primary key is zero" do
    parent = File.tempname("crystal-click-writer-w71-zero-key")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [0_u64, 1_u64]
    empty_row = [] of Tuple(UInt64, Array(String?))
    values = [empty_row, empty_row]
    begin
      CrystalClick::WidePartWriter.write_uint64_map_uint64_array_nullable_string_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), rows_per_mark: 1
      )

      File.read(File.join(destination, "serialization.json"))
        .should contain("\"num_defaults\":1,\"num_rows\":2")
      reader = CrystalClick::WidePart.open_typed(destination, "payload")
      reader.read_map_uint64_array_nullable_string_mark_range("payload", 0, reader.mark_count)
        .should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects leaf and entry overflow before staging or publication" do
    parent = File.tempname("crystal-click-writer-w71-overflow")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64]
    too_many_leaves = Array(String?).new((CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1_u64).to_i, nil)
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_array_nullable_string_pair(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          [[{7_u64, too_many_leaves}] of Tuple(UInt64, Array(String?))].to_unsafe.to_slice(1), rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
      File.exists?(destination).should be_false

      entry_destination = File.join(parent, "entry-part")
      empty_leaves = [] of String?
      too_many_entries = Array(Tuple(UInt64, Array(String?))).new(
        (CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1_u64).to_i
      ) { {7_u64, empty_leaves} }
      entry_values = [too_many_entries]
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_array_nullable_string_pair(
          entry_destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          entry_values.to_unsafe.to_slice(entry_values.size), rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
      File.exists?(entry_destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
