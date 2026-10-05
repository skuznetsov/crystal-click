require "./spec_helper"

# Explicit opt-in stock oracle; normal focused library rosters exclude this
# spec. Root separately checks the executable SHA256 before/after execution.
private def w175_stock(query : String, input : Bytes = Bytes.empty, type_name : String? = nil) : Bytes
  binary = ENV.fetch("W175_CLICKHOUSE_BINARY")
  args = ["local", "--query", query, "--output_format_binary_encode_types_in_binary_format=1"]
  if type_name
    args.concat(["--structure", "c #{type_name}", "--input-format", "RowBinary"])
  end
  output = IO::Memory.new
  errors = IO::Memory.new
  status = Process.run(binary, args, input: IO::Memory.new(input), output: output, error: errors)
  status.success?.should be_true, errors.to_s
  output.to_slice.dup
end

private def w175_native_types : Array(CrystalClick::BinaryDataType)
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  [
    CrystalClick::BinaryDataType.aggregate_count,
    CrystalClick::BinaryDataType.aggregate_count(uint64),
    CrystalClick::BinaryDataType.aggregate_count(CrystalClick::BinaryDataType.nullable(uint64)),
  ]
end

if ENV["W175_CLICKHOUSE_BINARY"]?
  describe "W175 reciprocal stock Count state bytes" do
    it "decodes stock-created states with independent exact descriptors and count expectations" do
      pin = w175_stock("SELECT version(), (SELECT value FROM system.build_options WHERE name = 'VERSION_GITHASH') FORMAT TSV")
      String.new(pin).should eq("26.10.1.1201\td9bcb5ab007f0f6299f7f973f2642245bab3d028\n")
      cases = [
        {"SELECT countState() AS c FROM numbers(128) FORMAT RowBinaryWithNamesAndTypes", "010163250005636f756e7400008001", 128_u64},
        {"SELECT countState(number) AS c FROM numbers(127) FORMAT RowBinaryWithNamesAndTypes", "010163250005636f756e740001047f", 127_u64},
        {"SELECT countState(x) AS c FROM values('x Nullable(UInt64)', NULL, 7, NULL) FORMAT RowBinaryWithNamesAndTypes", "010163250005636f756e740001230401", 1_u64},
      ]
      cases.each_with_index do |(query, hex, count), index|
        bytes = w175_stock(query)
        bytes.hexstring.should eq(hex)
        # The exact one-column header is independently literal, not parsed by
        # the library's type codec to find where its own value codec starts.
        descriptor_size = [10, 11, 12][index]
        type = CrystalClick::BinaryDataTypeCodec.decode(bytes[3, descriptor_size])
        type.should eq(w175_native_types[index])
        state = CrystalClick::BinaryValueCodec.decode_value(type, bytes[3 + descriptor_size..])
        state.count_state.should eq(count)
        state.type.should eq(type)
      end
    end

    it "lets stock parse and finalize library-authored canonical states including UInt64::MAX" do
      counts = [0_u64, 1_u64, 127_u64, 128_u64, 16383_u64, 16384_u64, UInt64::MAX]
      # No production VarUInt helper is used to author the expected state lane.
      expected = Bytes[
        0x00_u8, 0x01, 0x7f, 0x80, 0x01, 0xff, 0x7f, 0x80, 0x80, 0x01,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01,
      ]
      w175_native_types.each do |type|
        lane = IO::Memory.new
        counts.each do |count|
          value = CrystalClick::BinaryValue.aggregate_count_state(type, count)
          lane.write(CrystalClick::BinaryValueCodec.encode_value(value))
        end
        lane.to_slice.should eq(expected)
        w175_stock("SELECT c FROM table FORMAT RowBinary", lane.to_slice, type.name).should eq(expected)
        final = w175_stock("SELECT finalizeAggregation(c) FROM table FORMAT TSV", lane.to_slice, type.name)
        String.new(final).should eq(counts.map(&.to_s).join("\n") + "\n")
      end
    end

    it "makes the stricter local minimal-VarUInt profile explicit" do
      type = CrystalClick::BinaryDataType.aggregate_count
      overlong_zero = Bytes[0x80_u8, 0x00]
      String.new(w175_stock("SELECT finalizeAggregation(c) FROM table FORMAT TSV", overlong_zero, type.name)).should eq("0\n")
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(type, overlong_zero)
      end
    end
  end
end
