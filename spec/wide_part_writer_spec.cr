require "./spec_helper"

describe CrystalClick::WidePartWriter do
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
