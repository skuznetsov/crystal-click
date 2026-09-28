require "./spec_helper"

private def writer_w61_fixture_values(long_value : String) : Array(Array(Array(String?)))
  values = [] of Array(Array(String?))
  values << [["alpha", nil, ""] of String?]
  values << [] of Array(String?)
  values << [[nil] of String?, [] of String?, [nil, nil] of String?]
  values << [[nil] of String?]
  values << [[] of String?, [] of String?]
  values << [] of Array(String?)
  values << [["a\0b", "é😃", long_value] of String?, [] of String?]
  values << [["", "β"] of String?]
  values << [["tail", nil] of String?]
  values
end

private def writer_w61_append_uint64(bytes : Array(UInt8), value : UInt64) : Nil
  8.times { |byte| bytes << ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def writer_w61_expected_streams(values : Array(Array(Array(String?)))) : {Array(UInt8), Array(UInt8), Array(UInt8), Array(UInt8), Array(UInt8)}
  size0 = [] of UInt8
  size1 = [] of UInt8
  nulls = [] of UInt8
  sizes = [] of UInt8
  raw = [] of UInt8
  values.each do |row|
    writer_w61_append_uint64(size0, row.size.to_u64)
    row.each do |inner|
      writer_w61_append_uint64(size1, inner.size.to_u64)
      inner.each do |value|
        if value.nil?
          nulls << 1_u8
          writer_w61_append_uint64(sizes, 0_u64)
        else
          string = value.not_nil!
          nulls << 0_u8
          writer_w61_append_uint64(sizes, string.bytesize.to_u64)
          string.to_slice.each { |byte| raw << byte }
        end
      end
    end
  end
  {size0, size1, nulls, sizes, raw}
end

private def writer_w61_stream(path : String, logical_stream : String) : Array(UInt8)
  data_path = File.join(path, "#{CrystalClick::StreamName.hash(logical_stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a
end

private def writer_w61_mark_field(path : String, logical_stream : String, field_offset : Int32) : Array(UInt64)
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(logical_stream)}.mrk2")
  bytes = File.read(marks_path).to_slice
  raise "invalid W61 writer mark file" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + field_offset
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

describe CrystalClick::WidePartWriter do
  it "writes the exact W61 nullable String Array streams and reads back each boundary" do
    parent = File.tempname("crystal-click-wide-writer-w61")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = (1_u64..9_u64).to_a
    values = writer_w61_fixture_values("z" * 5000)

    begin
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_string_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      ).should eq(destination)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Array(Array(Nullable(String)))\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n5 substreams for column `payload`:\n\tpayload.size0\n\tpayload.size1\n\tpayload.null\n\tpayload.size\n\tpayload\n"
      )
      JSON.parse(File.read(File.join(destination, "serialization.json"))).as_h.should eq({
        "columns"                                                => JSON::Any.new([] of JSON::Any),
        "propagate_types_serialization_versions_to_nested_types" => JSON::Any.new(true),
        "types_serialization_versions"                           => JSON::Any.new({"string" => JSON::Any.new(1_i64)} of String => JSON::Any),
        "version"                                                => JSON::Any.new(1_i64),
      })
      File.read(File.join(destination, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
      File.read(File.join(destination, "metadata_version.txt")).should eq("0")
      CrystalClick::PartChecksums.open(destination).entries.has_key?("serialization.json").should be_true

      expected = writer_w61_expected_streams(values)
      {"payload.size0", "payload.size1", "payload.null", "payload.size", "payload"}.zip(expected.to_a).each do |stream, bytes|
        writer_w61_stream(destination, stream).should eq(bytes)
        writer_w61_mark_field(destination, stream, 16).should eq([2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
      end

      {"payload.size0", "payload.size1", "payload.null", "payload.size", "payload"}.each do |stream|
        offsets = writer_w61_mark_field(destination, stream, 0)
        offsets[2].should eq(offsets[3]) if {"payload.null", "payload.size", "payload"}.includes?(stream)
      end
      writer_w61_mark_field(destination, "payload.size0", 0)[2].should_not eq(writer_w61_mark_field(destination, "payload.size0", 0)[3])
      writer_w61_mark_field(destination, "payload.size1", 0)[2].should_not eq(writer_w61_mark_field(destination, "payload.size1", 0)[3])

      reader = CrystalClick::WidePart.open_typed(destination, "payload")
      reader.column_type.should eq("Array(Array(Nullable(String)))")
      reader.row_count.should eq(9_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
      reader.read_array_array_nullable_string_mark_range("payload", 0, reader.mark_count).should eq(values)
      reader.read_array_array_nullable_string_mark_range("payload", 3, 2).should eq(values[6, 3])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects malformed rows before staging or publishing a part" do
    parent = File.tempname("crystal-click-wide-writer-w61-reject")
    Dir.mkdir(parent)
    keys = [2_u64, 1_u64]
    values = writer_w61_fixture_values("unused")[0, 2]

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_array_nullable_string_pair(
          File.join(parent, "part"),
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
