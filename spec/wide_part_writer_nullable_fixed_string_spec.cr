require "./spec_helper"

private def nullable_fixed_writer_mark_rows(path : String, stream : String) : Array(UInt64)
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(marks_path).to_slice
  (bytes.size % CrystalClick::WidePart::MARK_SIZE).should eq(0)
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    row_count = 0_u64
    8.times { |byte| row_count |= bytes[offset + byte].to_u64 << (byte * 8) }
    row_count
  end
end

private def expect_nullable_fixed_writer_preflight_rejection(
  parent : String,
  label : String,
  keys : Array(UInt64),
  values : Array(String?),
  width : Int32,
  rows_per_mark : Int32,
  expected_message : String? = nil,
) : Nil
  destination = File.join(parent, label)
  error = expect_raises(ArgumentError) do
    CrystalClick::WidePartWriter.write_uint64_nullable_fixed_string_pair(
      destination,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "value",
      values.to_unsafe.to_slice(values.size),
      width: width,
      rows_per_mark: rows_per_mark
    )
  end
  error.message.to_s.should contain(expected_message) if expected_message
  Dir.children(parent).should eq([] of String)
end

describe CrystalClick::WidePartWriter do
  it "writes BASIC Nullable(FixedString(3)) as a null map and fixed nested slots across marks" do
    parent = File.tempname("crystal-click-wide-writer-nullable-fixed")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 2_u64, 4_u64, 9_u64, 11_u64, 13_u64]
    values = [nil, "", "a", "a\0b", "xyz", String.new(Bytes[0xff_u8]), nil] of String?
    expected = [nil, "\0\0\0", "a\0\0", "a\0b", "xyz", String.new(Bytes[0xff_u8, 0_u8, 0_u8]), nil] of String?

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_fixed_string_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        values.to_unsafe.to_slice(values.size),
        width: 3,
        rows_per_mark: 2
      ).should eq(destination)

      key_part = CrystalClick::WidePart.open(destination, "pk")
      value_part = CrystalClick::WidePart.open_typed(destination, "value")
      key_part.read_uint64.should eq(keys)
      value_part.column_type.should eq("Nullable(FixedString(3))")
      value_part.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      value_part.read_nullable_fixed_string_mark_range("value", 0, value_part.mark_count).should eq(expected)
      value_part.read_nullable_fixed_string_mark_range("value", 1, 1).should eq(expected[2, 2])

      nullable_fixed_writer_mark_rows(destination, "value.null").should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
      nullable_fixed_writer_mark_rows(destination, "value").should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
      null_path = File.join(destination, "#{CrystalClick::StreamName.hash("value.null")}.bin")
      CrystalClick::CompressedBlock.decode_all(File.read(null_path).to_slice).to_a.should eq([1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8])
      nested_path = File.join(destination, "#{CrystalClick::StreamName.hash("value")}.bin")
      # Readback returns nil for NULL rows, so inspect the physical slots too.
      CrystalClick::CompressedBlock.decode_all(File.read(nested_path).to_slice).to_a.should eq([
        0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 97_u8, 0_u8, 0_u8,
        97_u8, 0_u8, 98_u8, 120_u8, 121_u8, 122_u8, 255_u8, 0_u8, 0_u8,
        0_u8, 0_u8, 0_u8,
      ])
      File.exists?(File.join(destination, "#{CrystalClick::StreamName.hash("value.size")}.bin")).should be_false
      File.exists?(File.join(destination, "#{CrystalClick::StreamName.hash("value.size")}.mrk2")).should be_false
      File.read(File.join(destination, "columns.txt")).should eq("columns format version: 1\n2 columns:\n`pk` UInt64\n`value` Nullable(FixedString(3))\n")
      File.read(File.join(destination, "columns_substreams.txt")).should eq("columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `value`:\n\tvalue.null\n\tvalue\n")

      serialization = JSON.parse(File.read(File.join(destination, "serialization.json")))
      serialization["types_serialization_versions"].as_h.should eq({"nullable" => JSON::Any.new(0_i64), "string" => JSON::Any.new(1_i64)})
      checksums = CrystalClick::PartChecksums.open(destination)
      checksums.entries.has_key?("serialization.json").should be_true
      checksums.entries.each_key { |name| checksums.validate_selected_entries(destination, name) }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes a zero-filled nested slot for every all-NULL row" do
    parent = File.tempname("crystal-click-wide-writer-nullable-fixed-all-null")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64]
    values = [nil, nil, nil] of String?

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_fixed_string_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        values.to_unsafe.to_slice(values.size),
        width: 3,
        rows_per_mark: 2
      )
      nested_path = File.join(destination, "#{CrystalClick::StreamName.hash("value")}.bin")
      CrystalClick::CompressedBlock.decode_all(File.read(nested_path).to_slice).to_a.should eq(Array(UInt8).new(9, 0_u8))
      value_part = CrystalClick::WidePart.open_typed(destination, "value")
      value_part.read_nullable_fixed_string_mark_range("value", 0, value_part.mark_count).should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "accepts the maximum declared width when each mark fits the frame limit" do
    parent = File.tempname("crystal-click-wide-writer-nullable-fixed-max-width")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64]
    values = [nil, "Z"] of String?
    width = CrystalClick::WidePart::MAX_FIXED_STRING_WIDTH.to_i32

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_fixed_string_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        values.to_unsafe.to_slice(values.size),
        width: width,
        rows_per_mark: 1
      )
      value_part = CrystalClick::WidePart.open_typed(destination, "value")
      value_part.column_type.should eq("Nullable(FixedString(#{width}))")
      observed = value_part.read_nullable_fixed_string_mark_range("value", 0, value_part.mark_count)
      observed[0].should be_nil
      observed[1].not_nil!.bytesize.should eq(width)
      observed[1].not_nil!.to_slice[0].should eq(90_u8)

      nested_path = File.join(destination, "#{CrystalClick::StreamName.hash("value")}.bin")
      nested = CrystalClick::CompressedBlock.decode_all(File.read(nested_path).to_slice)
      nested.size.should eq(width * 2)
      nested[0, width].all? { |byte| byte == 0_u8 }.should be_true
      nested[width].should eq(90_u8)
      nested[width + 1, width - 1].all? { |byte| byte == 0_u8 }.should be_true
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects invalid width, overwidth values, oversized marks, frames, and files before staging" do
    parent = File.tempname("crystal-click-wide-writer-nullable-fixed-invalid")
    Dir.mkdir(parent)
    keys = [1_u64]
    values = [nil] of String?

    begin
      expect_nullable_fixed_writer_preflight_rejection(parent, "zero-width", keys, values, 0, 1)
      expect_nullable_fixed_writer_preflight_rejection(parent, "large-width", keys, values, CrystalClick::WidePart::MAX_FIXED_STRING_WIDTH.to_i32 + 1, 1)
      expect_nullable_fixed_writer_preflight_rejection(parent, "overwidth", keys, ["abcd"] of String?, 3, 1)
      expect_nullable_fixed_writer_preflight_rejection(parent, "large-mark", keys, values, 3, 65_537)

      frame_rows = CrystalClick::WidePart::MAX_FRAME_DECOMPRESSED_BYTES // CrystalClick::WidePart::MAX_FIXED_STRING_WIDTH + 1
      frame_keys = Array(UInt64).new(frame_rows) { |index| index.to_u64 }
      frame_values = Array(String?).new(frame_rows, nil)
      expect_nullable_fixed_writer_preflight_rejection(parent, "large-frame", frame_keys, frame_values, CrystalClick::WidePart::MAX_FIXED_STRING_WIDTH.to_i32, frame_rows.to_i32, "granule exceeds decompressed frame limit")

      file_rows = 4096
      file_keys = Array(UInt64).new(file_rows) { |index| index.to_u64 }
      file_values = Array(String?).new(file_rows, nil)
      expect_nullable_fixed_writer_preflight_rejection(parent, "large-file", file_keys, file_values, CrystalClick::WidePart::MAX_FIXED_STRING_WIDTH.to_i32, 512, "Nullable FixedString nested stream exceeds reader limit")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "cleans its staging directory when exclusive publication fails" do
    parent = File.tempname("crystal-click-wide-writer-nullable-fixed-publish-failure")
    Dir.mkdir(parent)
    destination = File.join(parent, "x" * 256)
    values = [nil] of String?

    begin
      expect_raises(IO::Error) do
        CrystalClick::WidePartWriter.write_uint64_nullable_fixed_string_pair(
          destination,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "value",
          values.to_unsafe.to_slice(values.size),
          width: 3,
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
