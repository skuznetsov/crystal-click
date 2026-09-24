require "./spec_helper"

describe CrystalClick::WidePartWriter do
  it "writes a UInt64 key and Nullable(UInt64) payload pair with positional nulls" do
    parent = File.tempname("crystal-click-wide-writer-nullable")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 2_u64, 9_u64, UInt64::MAX, UInt64::MAX, UInt64::MAX]
    values = [nil, 0_u64.as(UInt64?), nil, UInt64::MAX.as(UInt64?), nil, 7_u64.as(UInt64?), nil]

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_uint64_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 3
      )

      key_part = CrystalClick::WidePart.open(destination, "pk")
      key_part.row_count.should eq(7_u64)
      key_part.mark_count.should eq(3)
      key_part.mark_row_counts.should eq([3_u64, 3_u64, 1_u64])
      key_part.read_uint64.should eq(keys)

      value_part = CrystalClick::WidePart.open_typed(destination, "value")
      value_part.column_type.should eq("Nullable(UInt64)")
      value_part.mark_row_counts.should eq([3_u64, 3_u64, 1_u64])
      value_part.read_nullable_numeric_mark_range("value", 0, 3, UInt64).should eq(values)
      value_part.read_nullable_numeric_mark_range("value", 1, 1, UInt64).should eq([
        UInt64::MAX.as(UInt64?), nil, 7_u64.as(UInt64?),
      ])

      null_stream = File.read(File.join(destination, "#{CrystalClick::StreamName.hash("value.null")}.bin")).to_slice
      CrystalClick::CompressedBlock.decode_all(null_stream).to_a.should eq([1_u8, 0_u8, 1_u8, 0_u8, 1_u8, 0_u8, 1_u8])
      nested_stream = File.read(File.join(destination, "#{CrystalClick::StreamName.hash("value")}.bin")).to_slice
      nested_bytes = CrystalClick::CompressedBlock.decode_all(nested_stream)
      nested_values = Array(UInt64).new(values.size)
      values.size.times do |index|
        nested_value = 0_u64
        8.times do |byte|
          nested_value |= (nested_bytes[index * 8 + byte].to_u64 << (byte * 8))
        end
        nested_values << nested_value
      end
      nested_values.should eq([0_u64, 0_u64, 0_u64, UInt64::MAX, 0_u64, 7_u64, 0_u64])

      serialization = JSON.parse(File.read(File.join(destination, "serialization.json"))).as_h
      serialization["version"].as_i.should eq(1)
      serialization["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true
      serialization["columns"].as_a.should be_empty
      serialization["types_serialization_versions"].as_h["string"].as_i.should eq(1)
      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`value` Nullable(UInt64)\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `value`:\n\tvalue.null\n\tvalue\n"
      )
      expected_checksum_names = ["count.txt", "primary.idx", "serialization.json"]
      {"pk", "value.null", "value"}.each do |stream|
        base = CrystalClick::StreamName.hash(stream)
        expected_checksum_names << "#{base}.bin"
        expected_checksum_names << "#{base}.mrk2"
      end
      CrystalClick::PartChecksums.open(destination).entries.keys.sort.should eq(expected_checksum_names.sort)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes an all-NULL Nullable(UInt64) payload as ordinary nested rows" do
    parent = File.tempname("crystal-click-wide-writer-nullable-all-null")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64]
    values = [nil, nil, nil] of UInt64?

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_uint64_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 3
      )

      part = CrystalClick::WidePart.open_typed(destination, "value")
      part.read_nullable_numeric_mark_range("value", 0, 1, UInt64).should eq(values)
      null_stream = File.read(File.join(destination, "#{CrystalClick::StreamName.hash("value.null")}.bin")).to_slice
      CrystalClick::CompressedBlock.decode_all(null_stream).to_a.should eq([1_u8, 1_u8, 1_u8])
      nested_stream = File.read(File.join(destination, "#{CrystalClick::StreamName.hash("value")}.bin")).to_slice
      CrystalClick::CompressedBlock.decode_all(nested_stream).to_a.should eq(Array(UInt8).new(24, 0_u8))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects invalid Nullable(UInt64) inputs before publishing a part" do
    invalid_cases = [
      {keys: [2_u64, 1_u64], values: [1_u64.as(UInt64?), nil], rows_per_mark: 1},
      {keys: [1_u64, 2_u64], values: [1_u64.as(UInt64?)], rows_per_mark: 1},
      {keys: [1_u64], values: [nil], rows_per_mark: 0},
      {keys: [1_u64], values: [nil], rows_per_mark: 65_537},
    ]

    invalid_cases.each do |input|
      parent = File.tempname("crystal-click-wide-writer-nullable-invalid")
      Dir.mkdir(parent)
      destination = File.join(parent, "part")
      begin
        expect_raises(ArgumentError) do
          CrystalClick::WidePartWriter.write_uint64_nullable_uint64_pair(
            destination,
            "pk",
            input[:keys].to_unsafe.to_slice(input[:keys].size),
            "value",
            input[:values].to_unsafe.to_slice(input[:values].size),
            rows_per_mark: input[:rows_per_mark]
          )
        end
        Dir.children(parent).should eq([] of String)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "cleans its staged Nullable part when exclusive publication fails" do
    parent = File.tempname("crystal-click-wide-writer-nullable-publish-failure")
    Dir.mkdir(parent)
    destination = File.join(parent, "x" * 256)
    values = [nil] of UInt64?

    begin
      expect_raises(IO::Error) do
        CrystalClick::WidePartWriter.write_uint64_nullable_uint64_pair(
          destination,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "value",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes two UInt64 columns with fixed multi-mark granules" do
    parent = File.tempname("crystal-click-wide-writer")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 2_u64, 9_u64, UInt64::MAX]
    values = [80_u64, 81_u64, 82_u64, 83_u64, 84_u64]

    begin
      CrystalClick::WidePartWriter.write_uint64_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      )

      part = CrystalClick::WidePart.open(destination, "pk")
      part.row_count.should eq(5_u64)
      part.mark_count.should eq(3)
      part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      part.read_uint64.should eq(keys)
      part.read_uint64_mark_range("pk", 1, 2).should eq([2_u64, 9_u64, UInt64::MAX])

      values_part = CrystalClick::WidePart.open(destination, "value")
      values_part.read_uint64.should eq(values)
      values_part.read_uint64_mark_range("value", 2, 1).should eq([84_u64])
      File.exists?(File.join(destination, "primary.idx")).should be_true
      File.exists?(File.join(destination, "checksums.txt")).should be_true
      expected_checksum_names = ["count.txt", "primary.idx"]
      {"pk", "value"}.each do |column|
        base = CrystalClick::StreamName.hash(column)
        expected_checksum_names << "#{base}.bin"
        expected_checksum_names << "#{base}.mrk2"
      end
      CrystalClick::PartChecksums.open(destination).entries.keys.sort.should eq(expected_checksum_names.sort)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects invalid inputs before publishing a part" do
    invalid_inputs = [
      {"pk", [2_u64, 1_u64], "value", [10_u64, 11_u64], 1},
      {"pk", [1_u64, 2_u64], "value", [10_u64], 1},
      {"../pk", [1_u64], "value", [10_u64], 1},
      {"pk", [1_u64], "pk", [10_u64], 1},
      {"pk", [1_u64], "value", [10_u64], 0},
      {"pk", [1_u64], "value", [10_u64], 65_537},
      {"pk", [] of UInt64, "value", [] of UInt64, 1},
    ]

    invalid_inputs.each do |input|
      parent = File.tempname("crystal-click-wide-writer-invalid")
      Dir.mkdir(parent)
      destination = File.join(parent, "part")
      begin
        expect_raises(ArgumentError) do
          CrystalClick::WidePartWriter.write_uint64_pair(
            destination,
            input[0],
            input[1].to_unsafe.to_slice(input[1].size),
            input[2],
            input[3].to_unsafe.to_slice(input[3].size),
            rows_per_mark: input[4]
          )
        end
        Dir.exists?(destination).should be_false
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "does not replace an existing destination" do
    parent = File.tempname("crystal-click-wide-writer-existing")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    Dir.mkdir(destination)
    marker = File.join(destination, "keep.txt")
    File.write(marker, "preserve")

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_pair(
          destination,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "value",
          [10_u64].to_unsafe.to_slice(1),
          rows_per_mark: 1
        )
      end
      File.read(marker).should eq("preserve")
      Dir.children(parent).should eq(["part"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a missing destination parent without creating it" do
    parent = File.tempname("crystal-click-wide-writer-missing-parent")
    Dir.mkdir(parent)
    missing_parent = File.join(parent, "missing")
    destination = File.join(missing_parent, "part")

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_pair(
          destination,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "value",
          [10_u64].to_unsafe.to_slice(1),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "cleans its staged part when exclusive publication fails after assembly" do
    parent = File.tempname("crystal-click-wide-writer-publish-failure")
    Dir.mkdir(parent)
    destination = File.join(parent, "x" * 256)

    begin
      expect_raises(IO::Error) do
        CrystalClick::WidePartWriter.write_uint64_pair(
          destination,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "value",
          [10_u64].to_unsafe.to_slice(1),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "publishes at most one complete part when writers race for a destination" do
    parent = File.tempname("crystal-click-wide-writer-race")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = Array(UInt64).new(10_000) { |index| index.to_u64 }
    first_values = Array(UInt64).new(10_000) { 10_u64 }
    second_values = Array(UInt64).new(10_000) { 20_u64 }
    start = Channel(Nil).new
    results = Channel(Bool).new

    begin
      {first_values, second_values}.each do |values|
        spawn do
          start.receive
          begin
            CrystalClick::WidePartWriter.write_uint64_pair(
              destination,
              "pk",
              keys.to_unsafe.to_slice(keys.size),
              "value",
              values.to_unsafe.to_slice(values.size),
              rows_per_mark: 1024
            )
            results.send(true)
          rescue ArgumentError
            results.send(false)
          end
        end
      end

      2.times { start.send(nil) }
      outcomes = [results.receive, results.receive]
      successes = outcomes.count { |success| success }
      successes.should eq(1)
      Dir.children(parent).should eq(["part"])
      part = CrystalClick::WidePart.open(destination, "value")
      actual = part.read_uint64
      (actual == first_values || actual == second_values).should be_true
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
