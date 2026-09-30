require "./spec_helper"

private def w97_tuple_stream_bytes(part : String, stream : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(path).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w97_tuple_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w97_tuple_marks(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "malformed W97 mark file for #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {
      w97_tuple_read_u64(bytes, offset),
      w97_tuple_read_u64(bytes, offset + 8),
      w97_tuple_read_u64(bytes, offset + 16),
    }
  end
end

private def w97_tuple_u64_bytes(values : Array(UInt64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    8.times { |index| bytes << ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w97_tuple_counting_factory(calls : Array(Int32)) : Proc(String, String)
  ->(parent : String) do
    calls << 1
    stage = File.tempname(".w97-bool-tuple-stage-", nil, dir: parent)
    Dir.mkdir(stage)
    stage
  end
end

module CrystalClick
  module WidePartWriter
    def self.w97_test_write_uint64_tuple_pair_with_stage_factory(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      type_name : String,
      columns : Array(WideTupleLeafColumn),
      rows_per_mark : Int32,
      stage_factory : Proc(String, String),
    ) : String
      write_uint64_tuple_pair_with_stage_factory(
        destination, key_name, keys, value_name, type_name, columns, rows_per_mark,
        stage_factory, ->(column : WideTupleLeafColumn) { column.string_values }
      )
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes a Bool leaf as canonical 0/1 bytes with independent marks and false defaults" do
    keys = [0_u64, 2_u64, 3_u64, 9_u64, 11_u64]
    values = [false, true, false, false, true]
    columns = [CrystalClick::WideTupleLeafColumn.new("flag", values)] of CrystalClick::WideTupleLeafColumn
    type_name = "Tuple(flag Bool)"
    parent = File.tempname("crystal-click-wide-writer-bool-tuple-w97")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")

    begin
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns,
        rows_per_mark: 2
      ).should eq(destination)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `payload`:\n\tpayload%2Eflag\n"
      )

      raw = [0_u8, 1_u8, 0_u8, 0_u8, 1_u8]
      w97_tuple_stream_bytes(destination, "payload%2Eflag").should eq(raw)
      w97_tuple_marks(destination, "pk").map(&.[2]).should eq([2_u64, 2_u64, 1_u64, 0_u64])
      w97_tuple_marks(destination, "payload%2Eflag").map(&.[2]).should eq([2_u64, 2_u64, 1_u64, 0_u64])
      entry = CrystalClick::PartChecksums.open(destination).entries[
        "#{CrystalClick::StreamName.hash("payload%2Eflag")}.bin",
      ]
      entry.uncompressed_size.not_nil!.should eq(5_u64)

      serialization = JSON.parse(File.read(File.join(destination, "serialization.json"))).as_h
      payload = serialization["columns"].as_a.find do |record|
        record.as_h["name"]?.try(&.as_s) == "payload"
      end.not_nil!.as_h
      payload["num_defaults"].as_i.should eq(3)
      payload["subcolumns"].as_a.map { |record| record.as_h["num_defaults"].as_i }.should eq([3_i64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps Bool distinct from UInt8 in a mixed Bool, numeric and String Tuple" do
    keys = [0_u64, 4_u64, 9_u64]
    bool_values = [false, true, false]
    numeric_values = [0_u16, 4_u16, 0_u16]
    string_values = ["", "x\0", "end"]
    columns = [
      CrystalClick::WideTupleLeafColumn.new("flag", bool_values),
      CrystalClick::WideTupleLeafColumn.new("code", numeric_values),
      CrystalClick::WideTupleLeafColumn.new("text", string_values),
    ] of CrystalClick::WideTupleLeafColumn
    type_name = "Tuple(flag Bool, code UInt16, text String)"
    parent = File.tempname("crystal-click-wide-writer-bool-mixed-tuple-w97")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")

    begin
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns,
        rows_per_mark: 2
      ).should eq(destination)

      streams = [
        "payload%2Eflag",
        "payload%2Ecode",
        "payload%2Etext.size",
        "payload%2Etext",
      ]
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n4 substreams for column `payload`:\n#{streams.map { |stream| "\t#{stream}\n" }.join}"
      )

      expected_raw = {
        "payload%2Eflag"      => [0_u8, 1_u8, 0_u8],
        "payload%2Ecode"      => [0_u8, 0_u8, 4_u8, 0_u8, 0_u8, 0_u8],
        "payload%2Etext.size" => w97_tuple_u64_bytes([0_u64, 2_u64, 3_u64]),
        "payload%2Etext"      => [0x78_u8, 0_u8, 0x65_u8, 0x6e_u8, 0x64_u8],
      }
      streams.each do |stream|
        raw = expected_raw[stream]
        w97_tuple_stream_bytes(destination, stream).should eq(raw)
        w97_tuple_marks(destination, stream).map(&.[2]).should eq([2_u64, 1_u64, 0_u64])
        entry = CrystalClick::PartChecksums.open(destination).entries[
          "#{CrystalClick::StreamName.hash(stream)}.bin",
        ]
        entry.uncompressed_size.not_nil!.should eq(raw.size.to_u64)
      end
      expected_raw["payload%2Eflag"].size.should eq(keys.size)
      expected_raw["payload%2Ecode"].size.should eq(keys.size * 2)
      expected_raw["payload%2Etext.size"].size.should eq(keys.size * 8)

      serialization = JSON.parse(File.read(File.join(destination, "serialization.json"))).as_h
      payload = serialization["columns"].as_a.find do |record|
        record.as_h["name"]?.try(&.as_s) == "payload"
      end.not_nil!.as_h
      payload["num_defaults"].as_i.should eq(1)
      payload["subcolumns"].as_a.map { |record| record.as_h["num_defaults"].as_i }.should eq([2_i64, 2_i64, 1_i64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects Bool/UInt8 nominal mismatches and an unsupported later field before staging" do
    parent = File.tempname("crystal-click-wide-writer-bool-invalid-w97")
    Dir.mkdir(parent)
    factory_calls = [] of Int32
    factory = w97_tuple_counting_factory(factory_calls)
    keys = [1_u64, 2_u64]

    begin
      bool_as_uint8 = [CrystalClick::WideTupleLeafColumn.new("flag", [false, true])] of CrystalClick::WideTupleLeafColumn
      expect_raises(ArgumentError, "Tuple leaf buffers do not match schema order") do
        CrystalClick::WidePartWriter.w97_test_write_uint64_tuple_pair_with_stage_factory(
          File.join(parent, "bool-as-u8"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          "Tuple(flag UInt8)", bool_as_uint8, 1, factory
        )
      end

      u8_as_bool = [CrystalClick::WideTupleLeafColumn.new("flag", [0_u8, 1_u8])] of CrystalClick::WideTupleLeafColumn
      expect_raises(ArgumentError, "Tuple leaf buffers do not match schema order") do
        CrystalClick::WidePartWriter.w97_test_write_uint64_tuple_pair_with_stage_factory(
          File.join(parent, "u8-as-bool"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          "Tuple(flag Bool)", u8_as_bool, 1, factory
        )
      end

      nullable_date_is_unsupported = [
        CrystalClick::WideTupleLeafColumn.new("first", [1_u8, 2_u8]),
        CrystalClick::WideTupleLeafColumn.new("day", [0_u64, 0_u64]),
      ] of CrystalClick::WideTupleLeafColumn
      expect_raises(ArgumentError, "unsupported compositional Tuple type") do
        CrystalClick::WidePartWriter.w97_test_write_uint64_tuple_pair_with_stage_factory(
          File.join(parent, "nullable-date"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          "Tuple(first UInt8, day Nullable(Date))", nullable_date_is_unsupported, 1, factory
        )
      end

      factory_calls.should be_empty
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects the Bool Tuple logical budget before invoking the stage factory" do
    parent = File.tempname("crystal-click-wide-writer-bool-budget-w97")
    Dir.mkdir(parent)
    factory_calls = [] of Int32
    factory = w97_tuple_counting_factory(factory_calls)
    destination = File.join(parent, "over-budget")

    begin
      row_count = 4_000_000
      keys = Array(UInt64).new(row_count) { |index| index.to_u64 }
      values = Array(Bool).new(row_count, false)
      columns = [CrystalClick::WideTupleLeafColumn.new("flag", values)] of CrystalClick::WideTupleLeafColumn
      expect_raises(ArgumentError, "Tuple materialization charge exceeds limit") do
        CrystalClick::WidePartWriter.w97_test_write_uint64_tuple_pair_with_stage_factory(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", "Tuple(flag Bool)",
          columns, 65_536, factory
        )
      end
      factory_calls.should be_empty
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
