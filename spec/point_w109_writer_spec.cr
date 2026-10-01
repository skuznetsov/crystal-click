require "./spec_helper"

module CrystalClick::WidePartWriter
  # Hostile-test adapter: production exposes no stage or validation hook.
  def self.w109_test_write_with_hooks(
    destination : String,
    key_name : String,
    keys : Slice(UInt64),
    value_name : String,
    values : Slice(WidePointValue),
    rows_per_mark : Int32,
    stage_factory : Proc(String, String),
    before_validation_hook : Proc(String, Nil),
  ) : String
    write_point_pair_with_hooks(
      destination, key_name, keys, value_name, values, rows_per_mark,
      stage_factory, before_validation_hook
    )
  end

  def self.w109_stage_factory_for_spec(calls : Array(Int32)) : Proc(String, String)
    ->(parent : String) do
      calls << 1
      stage = File.tempname("crystal-click-point-w109-stage", nil, dir: parent)
      Dir.mkdir(stage)
      stage
    end
  end

  def self.w109_no_op_hook_for_spec : Proc(String, Nil)
    ->(_stage : String) { nil }
  end

  def self.w109_tamper_x_and_refresh_checksums_for_spec(
    logical_name : String,
  ) : Proc(String, Nil)
    ->(stage : String) do
      checksums = PartChecksums.open(stage)
      data_name = "#{StreamName.hash(logical_name)}.bin"
      data_path = File.join(stage, data_name)
      encoded_text = File.read(data_path)
      original = encoded_text.to_slice
      frame = CompressedBlock.decode_frame(
        original,
        0_i64,
        PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
        PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES
      )
      raw = frame.output.dup
      raw[0] ^= 1_u8
      replacement = StreamEncoding.encode_lz4_frame(raw)
      raise "W109 tamper replacement changed first-frame size" unless replacement.size.to_i64 == frame.end_offset
      rewritten = Bytes.new(original.size)
      replacement.copy_to(rewritten)
      remainder_size = original.size - frame.end_offset.to_i
      original[frame.end_offset.to_i, remainder_size].copy_to(rewritten[replacement.size, remainder_size])
      File.write(data_path, rewritten)

      w109_refresh_checksums_for_spec(stage, checksums)
      nil
    end
  end

  def self.w109_refresh_checksums_for_spec(stage : String, checksums : PartChecksums) : Nil
    records = [] of ChecksumRecord
    checksums.entries.each do |name, entry|
      file_text = File.read(File.join(stage, name))
      file_bytes = file_text.to_slice
      if entry.compressed
        uncompressed = CompressedBlock.decode_all(
          file_bytes,
          PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
          PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES,
          PartChecksums::MAX_PAYLOAD_BYTES
        )
        records << ChecksumRecord.new(
          name, file_bytes.size.to_u64, CityHashV1.file_hash(file_bytes), true,
          uncompressed.size.to_u64, CityHashV1.file_hash(uncompressed)
        )
      else
        records << ChecksumRecord.new(
          name, file_bytes.size.to_u64, CityHashV1.file_hash(file_bytes), false
        )
      end
    end
    write_checksums(stage, records)
    nil
  end

  def self.w109_replace_columns_with_tuple_for_spec : Proc(String, Nil)
    ->(stage : String) do
      path = File.join(stage, "columns.txt")
      File.write(path, File.read(path).sub(" Point\n", " Tuple(Float64, Float64)\n"))
      nil
    end
  end

  def self.w109_tamper_first_point_mark_and_refresh_for_spec(
    logical_name : String,
  ) : Proc(String, Nil)
    ->(stage : String) do
      path = File.join(stage, "#{StreamName.hash(logical_name)}.mrk2")
      checksums = PartChecksums.open(stage)
      marks = File.read(path).to_slice.dup
      # The third UInt64 in a .mrk2 entry is the physical rows in this mark.
      marks[16] = 1_u8
      File.write(path, marks)
      w109_refresh_checksums_for_spec(stage, checksums)
      nil
    end
  end

  def self.w109_tamper_serialization_and_refresh_for_spec : Proc(String, Nil)
    ->(stage : String) do
      path = File.join(stage, "serialization.json")
      checksums = PartChecksums.open(stage)
      File.write(path, File.read(path).sub("\"version\":1", "\"version\":2"))
      w109_refresh_checksums_for_spec(stage, checksums)
      nil
    end
  end

  def self.w109_replace_columns_with_symlink_for_spec(
    external_path : String,
  ) : Proc(String, Nil)
    ->(stage : String) do
      columns_path = File.join(stage, "columns.txt")
      File.write(external_path, File.read(columns_path))
      File.delete(columns_path)
      File.symlink(external_path, columns_path)
      nil
    end
  end
end

describe "W109 paired Point writer" do
  it "preserves the exact Point schema, raw bits, marks, association and statistics" do
    parent = File.tempname("crystal-click-point-w109-writer")
    Dir.mkdir(parent)
    destination = File.join(parent, "all_1_1_0")
    keys = [0_u64, 0_u64, 5_u64, 5_u64, 9_u64]
    values = [
      CrystalClick::WidePointValue.from_bits(0_u64, 0_u64),
      CrystalClick::WidePointValue.from_bits(0x8000_0000_0000_0000_u64, 0_u64),
      CrystalClick::WidePointValue.from_bits(0x7ff8_0000_0000_0042_u64, 0xfff0_0000_0000_0000_u64),
      CrystalClick::WidePointValue.from_bits(1_u64, 0x7ff0_0000_0000_0000_u64),
      CrystalClick::WidePointValue.new(3.25, 0.0),
    ]

    begin
      actual = CrystalClick::WidePartWriter.write_uint64_point_pair(
        destination,
        "z_key",
        keys.to_unsafe.to_slice(keys.size),
        "a_point",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      )
      actual.should eq(destination)

      point = CrystalClick::WidePart.open_typed(destination, "a_point")
      key = CrystalClick::WidePart.open_typed(destination, "z_key")
      point.column_type.should eq("Point")
      point.row_count.should eq(values.size.to_u64)
      point.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      key.column_type.should eq("UInt64")
      key.read_uint64_mark_range("z_key", 0, key.mark_count).should eq(keys)
      read_values = point.read_point_mark_range("a_point", 0, point.mark_count)
      read_values.size.should eq(values.size)
      read_values.zip(values) do |read, expected|
        read.same_bits?(expected).should be_true
      end

      checksums = CrystalClick::PartChecksums.open(destination)
      index = CrystalClick::PrimaryKeyIndex.open(destination, point.mark_count, checksums)
      index.keys.should eq([0_u64, 5_u64, 9_u64, 9_u64])

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`z_key` UInt64\n`a_point` Point\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n" +
        "1 substreams for column `z_key`:\n\tz_key\n" +
        "2 substreams for column `a_point`:\n\ta_point%2E1\n\ta_point%2E2\n"
      )
      File.read(File.join(destination, "serialization.json")).should eq(
        "{\"columns\":[" +
        "{\"kind\":\"Default\",\"name\":\"a_point\",\"num_defaults\":1,\"num_rows\":5,\"subcolumns\":[" +
        "{\"kind\":\"Default\",\"num_defaults\":1,\"num_rows\":5}," +
        "{\"kind\":\"Default\",\"num_defaults\":3,\"num_rows\":5}]}," +
        "{\"kind\":\"Default\",\"name\":\"z_key\",\"num_defaults\":2,\"num_rows\":5}]," +
        "\"propagate_types_serialization_versions_to_nested_types\":true," +
        "\"types_serialization_versions\":{\"string\":1},\"version\":1}"
      )

      stream_names = ["z_key", "a_point%2E1", "a_point%2E2"]
      expected_checksums = ["count.txt", "primary.idx", "serialization.json"] of String
      stream_names.each do |name|
        base = CrystalClick::StreamName.hash(name)
        expected_checksums << "#{base}.bin"
        expected_checksums << "#{base}.mrk2"
      end
      checksums.entries.keys.sort.should eq(expected_checksums.sort)
      expected_files = expected_checksums + [
        "checksums.txt", "columns.txt", "columns_substreams.txt",
        "default_compression_codec.txt", "metadata_version.txt",
      ]
      Dir.children(destination).sort.should eq(expected_files.sort)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects malformed input and a writer-only combined budget overrun before stage creation" do
    parent = File.tempname("crystal-click-point-w109-preflight")
    Dir.mkdir(parent)
    File.write(File.join(parent, "keep"), "unchanged")
    before = Dir.children(parent).sort
    destination = File.join(parent, "all_1_1_0")
    stage_calls = [] of Int32
    factory = CrystalClick::WidePartWriter.w109_stage_factory_for_spec(stage_calls)
    no_op = CrystalClick::WidePartWriter.w109_no_op_hook_for_spec
    values = [CrystalClick::WidePointValue.new(1.0, 2.0), CrystalClick::WidePointValue.new(3.0, 4.0)]

    begin
      expect_raises(ArgumentError, "primary keys must be nondecreasing") do
        CrystalClick::WidePartWriter.w109_test_write_with_hooks(
          destination, "pk", [2_u64, 1_u64].to_unsafe.to_slice(2), "point",
          values.to_unsafe.to_slice(2), 1, factory, no_op
        )
      end
      stage_calls.should be_empty
      File.exists?(destination).should be_false
      Dir.children(parent).sort.should eq(before)

      # 32 bytes/row for the Point reader alone fits; adding the writer's
      # retained 24-byte PK/X/Y snapshot makes this batch exceed the shared cap.
      row_count = 1_200_000
      large_keys = Array(UInt64).new(row_count) { |index| index.to_u64 }
      large_values = Array(CrystalClick::WidePointValue).new(row_count) do
        CrystalClick::WidePointValue.new(1.0, 2.0)
      end
      plan = CrystalClick::PointColumnType.for_type("Point").not_nil!
      plan.materialization_charge(row_count.to_u64).should be < CrystalClick::PointColumnType::MAX_MATERIALIZED_BYTES

      expect_raises(ArgumentError, "Point writer materialization charge exceeds 64 MiB") do
        CrystalClick::WidePartWriter.w109_test_write_with_hooks(
          destination, "pk", large_keys.to_unsafe.to_slice(row_count), "point",
          large_values.to_unsafe.to_slice(row_count), 8192, factory, no_op
        )
      end
      stage_calls.should be_empty
      File.exists?(destination).should be_false
      Dir.children(parent).sort.should eq(before)
      File.read(File.join(parent, "keep")).should eq("unchanged")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects empty, mismatched, invalid-name, invalid-mark and existing-destination inputs before staging" do
    parent = File.tempname("crystal-click-point-w109-preflight-guards")
    Dir.mkdir(parent)
    destination = File.join(parent, "all_1_1_0")
    stage_calls = [] of Int32
    factory = CrystalClick::WidePartWriter.w109_stage_factory_for_spec(stage_calls)
    no_op = CrystalClick::WidePartWriter.w109_no_op_hook_for_spec
    keys = [1_u64, 2_u64]
    values = [CrystalClick::WidePointValue.new(1.0, 2.0), CrystalClick::WidePointValue.new(3.0, 4.0)]
    before = Dir.children(parent).sort

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.w109_test_write_with_hooks(
          destination, "pk", ([] of UInt64).to_unsafe.to_slice(0), "point",
          ([] of CrystalClick::WidePointValue).to_unsafe.to_slice(0), 1, factory, no_op
        )
      end
      Dir.children(parent).sort.should eq(before)
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.w109_test_write_with_hooks(
          destination, "pk", keys.to_unsafe.to_slice(2), "point",
          values.to_unsafe.to_slice(1), 1, factory, no_op
        )
      end
      Dir.children(parent).sort.should eq(before)
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.w109_test_write_with_hooks(
          destination, "", keys.to_unsafe.to_slice(2), "point", values.to_unsafe.to_slice(2), 1, factory, no_op
        )
      end
      Dir.children(parent).sort.should eq(before)
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.w109_test_write_with_hooks(
          destination, "pk", keys.to_unsafe.to_slice(2), "", values.to_unsafe.to_slice(2), 1, factory, no_op
        )
      end
      Dir.children(parent).sort.should eq(before)
      {0, -1}.each do |rows_per_mark|
        expect_raises(ArgumentError) do
          CrystalClick::WidePartWriter.w109_test_write_with_hooks(
            destination, "pk", keys.to_unsafe.to_slice(2), "point",
            values.to_unsafe.to_slice(2), rows_per_mark, factory, no_op
          )
        end
        Dir.children(parent).sort.should eq(before)
      end

      Dir.mkdir(destination)
      File.write(File.join(destination, "keep"), "existing")
      existing_before = Dir.children(parent).sort
      expect_raises(ArgumentError, "destination must not already exist") do
        CrystalClick::WidePartWriter.w109_test_write_with_hooks(
          destination, "pk", keys.to_unsafe.to_slice(2), "point", values.to_unsafe.to_slice(2), 1, factory, no_op
        )
      end
      File.read(File.join(destination, "keep")).should eq("existing")
      Dir.children(parent).sort.should eq(existing_before)
      stage_calls.should be_empty
      existing_before.should eq(["all_1_1_0"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects refreshed-checksum coordinate tampering before exclusive publication" do
    parent = File.tempname("crystal-click-point-w109-stage-raw-attack")
    Dir.mkdir(parent)
    destination = File.join(parent, "all_1_1_0")
    keys = [1_u64, 2_u64]
    values = [
      CrystalClick::WidePointValue.from_bits(0x7ff8_0000_0000_0042_u64, 0x8000_0000_0000_0000_u64),
      CrystalClick::WidePointValue.new(1.25, -4.5),
    ]
    stage_calls = [] of Int32

    begin
      expect_raises(CrystalClick::CorruptPartError, "staged Point raw coordinate readback differs") do
        CrystalClick::WidePartWriter.w109_test_write_with_hooks(
          destination, "pk", keys.to_unsafe.to_slice(2), "point", values.to_unsafe.to_slice(2), 1,
          CrystalClick::WidePartWriter.w109_stage_factory_for_spec(stage_calls),
          CrystalClick::WidePartWriter.w109_tamper_x_and_refresh_checksums_for_spec("point%2E1")
        )
      end
      stage_calls.should eq([1])
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects Point-to-Tuple schema, mark and serialization metadata tampering before publication" do
    parent = File.tempname("crystal-click-point-w109-stage-schema-attacks")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64]
    values = [
      CrystalClick::WidePointValue.new(1.0, 2.0),
      CrystalClick::WidePointValue.new(3.0, 4.0),
      CrystalClick::WidePointValue.new(5.0, 6.0),
    ]
    attacks = [
      {"staged Point columns metadata differs".as(String?), CrystalClick::WidePartWriter.w109_replace_columns_with_tuple_for_spec},
      {nil, CrystalClick::WidePartWriter.w109_tamper_first_point_mark_and_refresh_for_spec("point%2E1")},
      {"staged Point serialization metadata differs".as(String?), CrystalClick::WidePartWriter.w109_tamper_serialization_and_refresh_for_spec},
    ]

    begin
      attacks.each_with_index do |(expected_error, hook), index|
        destination = File.join(parent, "all_#{index + 1}_#{index + 1}_0")
        stage_calls = [] of Int32
        error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.w109_test_write_with_hooks(
            destination, "pk", keys.to_unsafe.to_slice(3), "point", values.to_unsafe.to_slice(3), 2,
            CrystalClick::WidePartWriter.w109_stage_factory_for_spec(stage_calls), hook
          )
        end
        error.message.should eq(expected_error) if expected_error
        stage_calls.should eq([1])
        File.exists?(destination).should be_false
        Dir.children(parent).should be_empty
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a matching columns metadata symlink and cleans the unpublished stage" do
    parent = File.tempname("crystal-click-point-w109-stage-symlink")
    Dir.mkdir(parent)
    destination = File.join(parent, "all_1_1_0")
    external_columns = File.join(parent, "matching-columns.txt")
    before = Dir.children(parent).sort
    keys = [1_u64]
    values = [CrystalClick::WidePointValue.new(2.0, 3.0)]

    begin
      expect_raises(CrystalClick::CorruptPartError, "staged Point file must not be a symbolic link") do
        CrystalClick::WidePartWriter.w109_test_write_with_hooks(
          destination, "pk", keys.to_unsafe.to_slice(1), "point", values.to_unsafe.to_slice(1), 1,
          CrystalClick::WidePartWriter.w109_stage_factory_for_spec([] of Int32),
          CrystalClick::WidePartWriter.w109_replace_columns_with_symlink_for_spec(external_columns)
        )
      end
      File.exists?(destination).should be_false
      File.symlink?(external_columns).should be_false
    ensure
      FileUtils.rm_f(external_columns)
      FileUtils.rm_rf(destination)
      # The failed stage is removed, leaving only the directory contents that
      # existed before the attempt.
      Dir.children(parent).sort.should eq(before)
      FileUtils.rm_rf(parent)
    end
  end
end
