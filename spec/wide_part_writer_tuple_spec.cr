require "./spec_helper"
require "json"

private def expected_tuple_writer_u64_bytes(values : Array(UInt64)) : Array(UInt8)
  bytes = Bytes.new(values.size * 8)
  values.each_with_index do |value, index|
    8.times do |offset|
      bytes[index * 8 + offset] = (value >> (offset * 8)).to_u8
    end
  end
  bytes.to_a
end

describe CrystalClick::WidePartWriter do
  it "writes a named UInt64/String Tuple with independent leaf marks" do
    parent = File.tempname("crystal-click-wide-writer-tuple")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [0_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
    values = [
      {0_u64, ""},
      {8_u64, "a\0b"},
      {9_u64, String.new(Bytes[0xff_u8, 0_u8])},
      {10_u64, "é"},
      {11_u64, ""},
      {12_u64, "last"},
      {13_u64, "z"},
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_tuple_string_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values,
        rows_per_mark: 2
      )

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Tuple(a UInt64, b String)\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n3 substreams for column `payload`:\n\tpayload%2Ea\n\tpayload%2Eb.size\n\tpayload%2Eb\n"
      )

      versions = JSON.parse(File.read(File.join(destination, "serialization.json")))
      versions["types_serialization_versions"]["string"].as_i.should eq(1)
      columns = versions["columns"].as_a
      columns.size.should eq(2)
      columns[0]["kind"].as_s.should eq("Default")
      columns[0]["name"].as_s.should eq("pk")
      columns[0]["num_rows"].as_i.should eq(7)
      columns[0]["num_defaults"].as_i.should eq(1)
      columns[1]["kind"].as_s.should eq("Default")
      columns[1]["name"].as_s.should eq("payload")
      columns[1]["num_rows"].as_i.should eq(7)
      columns[1]["num_defaults"].as_i.should eq(1)
      subcolumns = columns[1]["subcolumns"].as_a
      subcolumns.size.should eq(2)
      subcolumns[0]["num_rows"].as_i.should eq(7)
      subcolumns[0]["num_defaults"].as_i.should eq(1)
      subcolumns[1]["num_rows"].as_i.should eq(7)
      subcolumns[1]["num_defaults"].as_i.should eq(2)

      key_stream = CrystalClick::StreamName.hash("pk")
      a_stream = CrystalClick::StreamName.hash("payload%2Ea")
      b_size_stream = CrystalClick::StreamName.hash("payload%2Eb.size")
      b_stream = CrystalClick::StreamName.hash("payload%2Eb")
      [key_stream, a_stream, b_size_stream, b_stream].uniq.size.should eq(4)

      decoded = {} of String => Array(UInt8)
      {"pk" => key_stream, "payload%2Ea" => a_stream, "payload%2Eb.size" => b_size_stream, "payload%2Eb" => b_stream}.each do |logical_name, stream_name|
        data_path = File.join(destination, "#{stream_name}.bin")
        mark_path = File.join(destination, "#{stream_name}.mrk2")
        File.exists?(data_path).should be_true
        File.exists?(mark_path).should be_true
        File.size(mark_path).should eq(5 * CrystalClick::WidePart::MARK_SIZE)
        decoded[logical_name] = CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a
      end

      decoded["pk"].should eq(expected_tuple_writer_u64_bytes(keys))
      decoded["payload%2Ea"].should eq(expected_tuple_writer_u64_bytes(values.map(&.[0])))
      decoded["payload%2Eb.size"].should eq(expected_tuple_writer_u64_bytes(values.map { |value| value[1].bytesize.to_u64 }))
      decoded["payload%2Eb"].should eq(values.map { |value| value[1].to_slice.to_a }.flatten)
      File.exists?(File.join(destination, "#{CrystalClick::StreamName.hash("payload")}.bin")).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects unsorted keys and invalid names without publishing a part" do
    parent = File.tempname("crystal-click-wide-writer-tuple-invalid")
    Dir.mkdir(parent)
    values = [{1_u64, "x"}, {2_u64, "y"}]

    begin
      unsorted_destination = File.join(parent, "unsorted")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_tuple_string_pair(
          unsorted_destination,
          "pk",
          [2_u64, 1_u64].to_unsafe.to_slice(2),
          "payload",
          values,
          rows_per_mark: 1
        )
      end
      File.exists?(unsorted_destination).should be_false

      invalid_name_destination = File.join(parent, "invalid-name")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_tuple_string_pair(
          invalid_name_destination,
          "pk",
          [1_u64, 2_u64].to_unsafe.to_slice(2),
          "payload.value",
          values,
          rows_per_mark: 1
        )
      end
      File.exists?(invalid_name_destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
