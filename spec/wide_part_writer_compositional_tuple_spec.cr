require "./spec_helper"

private def w94_tuple_u64_bytes(values : Array(UInt64)) : Array(UInt8)
  bytes = Bytes.new(values.size * 8)
  values.each_with_index do |value, index|
    8.times do |offset|
      bytes[index * 8 + offset] = ((value >> (offset * 8)) & 0xff_u64).to_u8
    end
  end
  bytes.to_a
end

private def w94_tuple_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w94_tuple_stream_bytes(part : String, stream : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  File.size(path).zero? ? [] of UInt8 : CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w94_tuple_marks(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "malformed W94 mark file for #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w94_tuple_read_u64(bytes, offset), w94_tuple_read_u64(bytes, offset + 8), w94_tuple_read_u64(bytes, offset + 16)}
  end
end

private def w94_tuple_column(name : String, values : Array(UInt64) | Array(String)) : CrystalClick::WideTupleLeafColumn
  CrystalClick::WideTupleLeafColumn.new(name, values)
end

private def w94_tuple_type(columns : Array(CrystalClick::WideTupleLeafColumn)) : String
  "Tuple(#{columns.map { |column| "#{column.name} #{column.type_name}" }.join(", ")})"
end

private def w94_tuple_physical_streams(columns : Array(CrystalClick::WideTupleLeafColumn)) : Array(String)
  streams = [] of String
  columns.each do |column|
    leaf = "payload%2E#{column.name}"
    if column.type_name == "String"
      streams << "#{leaf}.size"
    end
    streams << leaf
  end
  streams
end

private def w94_tuple_counting_factory(calls : Array(Int32)) : Proc(String, String)
  ->(parent : String) do
    calls << 1
    stage = File.tempname(".w94-compositional-stage-", nil, dir: parent)
    Dir.mkdir(stage)
    stage
  end
end

private def w94_tuple_counting_string_copy(calls : Array(Int32)) : Proc(CrystalClick::WideTupleLeafColumn, Array(String))
  ->(column : CrystalClick::WideTupleLeafColumn) do
    calls << 1
    column.string_values
  end
end

module CrystalClick
  module WidePartWriter
    def self.w94_test_write_uint64_tuple_pair_with_stage_factory(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      type_name : String,
      columns : Array(WideTupleLeafColumn),
      rows_per_mark : Int32,
      stage_factory : Proc(String, String),
      copy_string_values : Proc(WideTupleLeafColumn, Array(String)),
    ) : String
      write_uint64_tuple_pair_with_stage_factory(
        destination, key_name, keys, value_name, type_name, columns, rows_per_mark, stage_factory,
        copy_string_values
      )
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes named scalar-leaf Tuples in declared order with independent marks and exact streams" do
    profiles = [] of Tuple(String, Array(CrystalClick::WideTupleLeafColumn))
    profiles << {"one", [w94_tuple_column("only", [1_u64, 3_u64, UInt64::MAX, 7_u64, 9_u64])] of CrystalClick::WideTupleLeafColumn}
    profiles << {"two", [
      w94_tuple_column("text", ["", "a\0b", String.new(Bytes[0xff_u8, 0_u8]), "", "last"] of String),
      w94_tuple_column("number", [8_u64, 9_u64, 10_u64, 11_u64, 12_u64]),
    ] of CrystalClick::WideTupleLeafColumn}
    profiles << {"three", [
      w94_tuple_column("first", ["", "", "", "", ""] of String),
      w94_tuple_column("middle", ["a", "", "b\0c", "", ""] of String),
      w94_tuple_column("last", ["", "", "", "", ""] of String),
    ] of CrystalClick::WideTupleLeafColumn}
    profiles << {"nine", [
      w94_tuple_column("a", [0_u64, 1_u64, 2_u64, 3_u64, 4_u64]),
      w94_tuple_column("b", ["", "b", "", "d", ""] of String),
      w94_tuple_column("c", ["c", "", "", "", "e"] of String),
      w94_tuple_column("d", [5_u64, 6_u64, 7_u64, 8_u64, 9_u64]),
      w94_tuple_column("e", ["", "", "i", "", ""] of String),
      w94_tuple_column("f", [10_u64, 11_u64, 12_u64, 13_u64, 14_u64]),
      w94_tuple_column("g", ["g", "", "", "h", ""] of String),
      w94_tuple_column("h", [15_u64, 16_u64, 17_u64, 18_u64, 19_u64]),
      w94_tuple_column("i", ["", "", "", "", ""] of String),
    ] of CrystalClick::WideTupleLeafColumn}

    parent = File.tempname("crystal-click-wide-writer-compositional")
    Dir.mkdir(parent)
    keys = [0_u64, 2_u64, 4_u64, 6_u64, 9_u64]

    begin
      profiles.each do |suffix, columns|
        destination = File.join(parent, suffix)
        type_name = w94_tuple_type(columns)
        CrystalClick::WidePartWriter.write_uint64_tuple_pair(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns,
          rows_per_mark: 2
        ).should eq(destination)

        File.read(File.join(destination, "columns.txt")).should eq(
          "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
        )
        streams = w94_tuple_physical_streams(columns)
        expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n#{streams.size} substreams for column `payload`:\n"
        streams.each do |stream|
          expected_substreams += "\t#{stream}\n"
        end
        File.read(File.join(destination, "columns_substreams.txt")).should eq(expected_substreams)

        w94_tuple_stream_bytes(destination, "pk").should eq(w94_tuple_u64_bytes(keys))
        w94_tuple_marks(destination, "pk").map(&.[2]).should eq([2_u64, 2_u64, 1_u64, 0_u64])
        columns.each do |column|
          leaf = "payload%2E#{column.name}"
          if column.type_name == "UInt64"
            values = column.uint64_values
            w94_tuple_stream_bytes(destination, leaf).should eq(w94_tuple_u64_bytes(values))
          else
            values = column.string_values
            size_stream = "#{leaf}.size"
            w94_tuple_stream_bytes(destination, size_stream).should eq(
              w94_tuple_u64_bytes(values.map { |value| value.bytesize.to_u64 })
            )
            w94_tuple_stream_bytes(destination, leaf).should eq(values.map { |value| value.to_slice.to_a }.flatten)
            w94_tuple_marks(destination, size_stream).map(&.[2]).should eq([2_u64, 2_u64, 1_u64, 0_u64])
          end
          w94_tuple_marks(destination, leaf).map(&.[2]).should eq([2_u64, 2_u64, 1_u64, 0_u64])
        end

        empty_stream = "payload%2Elast"
        if suffix == "three"
          File.size(File.join(destination, "#{CrystalClick::StreamName.hash(empty_stream)}.bin")).should eq(0_i64)
          w94_tuple_marks(destination, empty_stream).map(&.[0]).should eq([0_u64, 0_u64, 0_u64, 0_u64])
        end

        primary = File.read(File.join(destination, "primary.idx")).to_slice
        Array(UInt64).new(primary.size // 8) { |index| w94_tuple_read_u64(primary, index * 8) }.should eq(
          [keys[0], keys[2], keys[4], keys.last]
        )
        File.read(File.join(destination, "count.txt")).should eq(keys.size.to_s)

        expected_checksums = ["count.txt", "primary.idx", "serialization.json"]
        (["pk"] + streams).each do |stream|
          base = CrystalClick::StreamName.hash(stream)
          expected_checksums << "#{base}.bin"
          expected_checksums << "#{base}.mrk2"
        end
        CrystalClick::PartChecksums.open(destination).entries.keys.sort.should eq(expected_checksums.sort)
      end
      Dir.children(parent).sort.should eq(["nine", "one", "three", "two"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "owns leaf inputs and returns copies from accessors" do
    numbers = [1_u64, 2_u64]
    numbers_column = w94_tuple_column("n", numbers)
    numbers[0] = 99_u64
    exposed_numbers = numbers_column.uint64_values
    exposed_numbers[1] = 88_u64
    numbers_column.uint64_values.should eq([1_u64, 2_u64])

    source = String.new(Bytes[0x41_u8, 0x42_u8])
    strings = [source]
    strings_column = w94_tuple_column("s", strings)
    strings[0] = "replaced"
    source.to_unsafe[0] = 0x5a_u8
    exposed_strings = strings_column.string_values
    exposed_strings[0] = "also replaced"
    strings_column.string_values.should eq(["AB"])
  end

  it "rejects malformed schemas, rows, keys and aggregate budget before allocating a stage" do
    parent = File.tempname("crystal-click-wide-writer-compositional-invalid")
    Dir.mkdir(parent)
    calls = [] of Int32
    factory = w94_tuple_counting_factory(calls)
    snapshot_calls = [] of Int32
    copy_string_values = w94_tuple_counting_string_copy(snapshot_calls)
    oversized = String.new(Bytes.new(CrystalClick::WidePart::MAX_ARRAY_MARK_BYTES + 1, 0_u8))
    invalid_cases = [] of Tuple(String, Array(CrystalClick::WideTupleLeafColumn), Array(UInt64), Int32)
    invalid_cases << {"Tuple()", [] of CrystalClick::WideTupleLeafColumn, [1_u64, 2_u64], 1}
    invalid_cases << {"Tuple(null String)", [w94_tuple_column("null", ["x", "y"] of String)], [1_u64, 2_u64], 1}
    invalid_cases << {"Tuple(a UInt64, a String)", [w94_tuple_column("a", [1_u64, 2_u64]), w94_tuple_column("a", ["x", "y"] of String)], [1_u64, 2_u64], 1}
    invalid_cases << {"Tuple(a UInt64, b String)", [w94_tuple_column("b", ["x", "y"] of String), w94_tuple_column("a", [1_u64, 2_u64])], [1_u64, 2_u64], 1}
    invalid_cases << {"Tuple(a String)", [w94_tuple_column("a", [1_u64, 2_u64])], [1_u64, 2_u64], 1}
    invalid_cases << {"Tuple(a UInt64, b String)", [w94_tuple_column("a", [1_u64, 2_u64]), w94_tuple_column("b", ["x"] of String)], [1_u64, 2_u64], 1}
    invalid_cases << {"Tuple(a UInt64, b Nullable(String))", [w94_tuple_column("a", [1_u64, 2_u64]), w94_tuple_column("b", ["x", "y"] of String)], [1_u64, 2_u64], 1}
    invalid_cases << {"Tuple(a UInt64)", [w94_tuple_column("a", [1_u64, 2_u64])], [2_u64, 1_u64], 1}
    invalid_cases << {"Tuple(a UInt64)", [w94_tuple_column("a", [1_u64, 2_u64])], [1_u64, 2_u64], 65_537}
    invalid_cases << {"Tuple(a String)", [w94_tuple_column("a", [oversized] of String)], [1_u64], 1}

    begin
      invalid_cases.each_with_index do |(type_name, columns, keys, rows_per_mark), index|
        destination = File.join(parent, "invalid-#{index}")
        expect_raises(ArgumentError) do
          CrystalClick::WidePartWriter.w94_test_write_uint64_tuple_pair_with_stage_factory(
            destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns,
            rows_per_mark, factory, copy_string_values
          )
        end
        calls.should be_empty
        snapshot_calls.should be_empty
        File.exists?(destination).should be_false
        Dir.children(parent).should be_empty
      end

      empty_keys_destination = File.join(parent, "empty-keys")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.w94_test_write_uint64_tuple_pair_with_stage_factory(
          empty_keys_destination, "pk", Slice(UInt64).new(0), "payload", "Tuple(a UInt64)",
          [w94_tuple_column("a", [] of UInt64)] of CrystalClick::WideTupleLeafColumn, 1, factory,
          copy_string_values
        )
      end
      calls.should be_empty
      snapshot_calls.should be_empty
      File.exists?(empty_keys_destination).should be_false

      aggregate_destination = File.join(parent, "aggregate-overflow")
      aggregate_payload = String.new(Bytes.new(32 * 1024 * 1024, 0_u8))
      aggregate_columns = [
        w94_tuple_column("left", [aggregate_payload] of String),
        w94_tuple_column("right", [aggregate_payload] of String),
      ] of CrystalClick::WideTupleLeafColumn
      aggregate_keys = [1_u64]
      expect_raises(ArgumentError, "Tuple materialization charge exceeds limit") do
        CrystalClick::WidePartWriter.w94_test_write_uint64_tuple_pair_with_stage_factory(
          aggregate_destination, "pk", aggregate_keys.to_unsafe.to_slice(aggregate_keys.size), "payload",
          w94_tuple_type(aggregate_columns), aggregate_columns, 1, factory, copy_string_values
        )
      end
      calls.should be_empty
      snapshot_calls.should be_empty
      File.exists?(aggregate_destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "uses the injected stage factory once for valid output and removes a stage after publish failure" do
    parent = File.tempname("crystal-click-wide-writer-compositional-stage")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    columns = [
      w94_tuple_column("n", [3_u64, 4_u64]),
      w94_tuple_column("left", ["x", ""] of String),
      w94_tuple_column("right", ["", "z"] of String),
    ] of CrystalClick::WideTupleLeafColumn
    type_name = w94_tuple_type(columns)
    calls = [] of Int32
    snapshot_calls = [] of Int32
    copy_string_values = w94_tuple_counting_string_copy(snapshot_calls)
    observed_snapshots_at_factory = [] of Int32
    factory = ->(stage_parent : String) do
      calls << 1
      observed_snapshots_at_factory << snapshot_calls.size
      stage = File.tempname(".w94-compositional-stage-", nil, dir: stage_parent)
      Dir.mkdir(stage)
      stage
    end
    destination = File.join(parent, "valid")

    begin
      CrystalClick::WidePartWriter.w94_test_write_uint64_tuple_pair_with_stage_factory(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, 1, factory,
        copy_string_values
      ).should eq(destination)
      calls.size.should eq(1)
      observed_snapshots_at_factory.should eq([2])
      snapshot_calls.size.should eq(2)
      Dir.children(parent).should eq(["valid"])

      failing_calls = [] of Int32
      collision = File.join(parent, "collision")
      collision_factory = ->(stage_parent : String) do
        failing_calls << 1
        observed_snapshots_at_factory << snapshot_calls.size
        stage = File.tempname(".w94-compositional-stage-", nil, dir: stage_parent)
        Dir.mkdir(stage)
        Dir.mkdir(collision)
        stage
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.w94_test_write_uint64_tuple_pair_with_stage_factory(
          collision, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, 1,
          collision_factory, copy_string_values
        )
      end
      failing_calls.size.should eq(1)
      observed_snapshots_at_factory.should eq([2, 4])
      snapshot_calls.size.should eq(4)
      Dir.children(parent).sort.should eq(["collision", "valid"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
