require "./spec_helper"
require "file_utils"
require "./support/interval_w160_types"

module CrystalClick
  module WidePartWriter
    # Spec-only forwarding bridge to the existing private staged validator.
    # This tests nominal metadata validation, not writer publication/cleanup.
    def self.w160g_test_validate_staged_interval(
      stage : String,
      keys : Slice(UInt64),
      counts : Slice(Int64),
      type_name : String,
      rows_per_mark : Int32,
    ) : Nil
      validate_staged_typed_part(stage, "pk", "v", keys, counts, type_name, rows_per_mark)
    end
  end
end

private def with_w160g_parent(& : String ->)
  parent = File.tempname("crystal-click-interval-w160-guards")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w160g_write_scalar(
  parent : String,
  name : String,
  kind : CrystalClick::BinaryIntervalType::Kind = CrystalClick::BinaryIntervalType::Kind::Second,
  rows_per_mark : Int32 = 2,
) : String
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
  counts = [7_i64, -3_i64, 0_i64, 42_i64, 9_i64]
  table_root = File.join(parent, name)
  Dir.mkdir(table_root)
  part = File.join(table_root, "all_1_1_0")
  CrystalClick::WidePartWriter.write_uint64_interval_pair(
    part, "pk", keys.to_unsafe.to_slice(keys.size), "v", counts.to_unsafe.to_slice(counts.size), kind,
    rows_per_mark: rows_per_mark
  )
  part
end

private def w160g_write_nullable(
  parent : String,
  name : String,
  kind : CrystalClick::BinaryIntervalType::Kind = CrystalClick::BinaryIntervalType::Kind::Second,
) : String
  keys = [1_u64, 2_u64, 3_u64]
  counts = [nil.as(Int64?), -3_i64.as(Int64?), 0_i64.as(Int64?)]
  table_root = File.join(parent, name)
  Dir.mkdir(table_root)
  part = File.join(table_root, "all_1_1_0")
  CrystalClick::WidePartWriter.write_uint64_nullable_interval_pair(
    part, "pk", keys.to_unsafe.to_slice(keys.size), "v", counts.to_unsafe.to_slice(counts.size), kind,
    rows_per_mark: 2
  )
  part
end

private def w160g_change_mark_rows(part : String, stream : String, mark_index : Int, rows : UInt64) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 16
  raise "W160 guard mark index is out of range" if offset > bytes.size - 8
  8.times { |byte| bytes[offset + byte] = ((rows >> (byte * 8)) & 0xff_u64).to_u8 }
  File.write(path, bytes)
end

describe "W160 Interval admission and physical guards" do
  it "admits only exact canonical scalar and Nullable shapes within the name budget" do
    W160_INTERVAL_TYPES.each do |name, kind, _code|
      scalar = CrystalClick::IntervalColumnType.parse(name).not_nil!
      scalar.type_name.should eq(name)
      scalar.kind.should eq(kind)
      scalar.shape.should eq(CrystalClick::IntervalColumnType::Shape::Scalar)
      scalar.raw_width.should eq(8)
      CrystalClick::WidePart.supports_typed_type?(name).should be_true

      nullable_name = "Nullable(#{name})"
      nullable = CrystalClick::IntervalColumnType.parse(nullable_name).not_nil!
      nullable.type_name.should eq(nullable_name)
      nullable.kind.should eq(kind)
      nullable.nullable?.should be_true
      nullable.raw_width.should eq(8)
      CrystalClick::WidePart.supports_typed_type?(nullable_name).should be_true
    end

    max_name = "Nullable(IntervalMillisecond)"
    max_name.bytesize.should eq(CrystalClick::IntervalColumnType::MAX_TYPE_BYTES)
    CrystalClick::IntervalColumnType.parse(max_name).not_nil!.type_name.should eq(max_name)

    {
      "intervalSecond",
      "IntervalSecond ",
      "IntervalSecond(1)",
      "Nullable(IntervalSecond )",
      "Nullable (IntervalSecond)",
      "Nullable(Nullable(IntervalYear))",
      "Nullable(IntervalMillisecond) ",
    }.each do |candidate|
      CrystalClick::IntervalColumnType.parse(candidate).should be_nil
      CrystalClick::WidePart.supports_typed_type?(candidate).should be_false
    end
  end

  it "refuses primitive Int64 reader and table accessors for scalar and nullable Interval" do
    with_w160g_parent do |parent|
      scalar_path = w160g_write_scalar(parent, "scalar")
      nullable_path = w160g_write_nullable(parent, "nullable")
      scalar = CrystalClick::WidePart.open_typed(scalar_path, "v")
      nullable = CrystalClick::WidePart.open_typed(nullable_path, "v")

      expect_raises(CrystalClick::UnsupportedFormatError) do
        scalar.read_numeric_mark_range("v", 0, scalar.mark_count, Int64)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        nullable.read_nullable_numeric_mark_range("v", 0, nullable.mark_count, Int64)
      end

      scalar_table = CrystalClick::WidePartTable.open_selected_typed([scalar_path], ["pk", "v"])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        scalar_table.scan_typed { |batch| batch.values_for("v", Int64); nil }
      end
      nullable_table = CrystalClick::WidePartTable.open_selected_typed([nullable_path], ["pk", "v"])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        nullable_table.scan_typed { |batch| batch.nullable_values_for("v", Int64); nil }
      end
    end
  end

  it "rejects unsupported Interval serialization profiles before exposing the column" do
    with_w160g_parent do |parent|
      part = w160g_write_scalar(parent, "metadata")
      path = File.join(part, "serialization.json")
      canonical = File.read(path)
      profiles = [
        {canonical.sub("\"version\":1}", "\"version\":2}"), "only serialization.json version 1 is supported"},
        {canonical.sub("\"string\":1", "\"string\":2"), "only Interval serialization version 1 is supported"},
        {canonical.sub("\"columns\":[]", "\"columns\":[{}]"), "Interval per-column serialization is unsupported"},
        {canonical.sub("\"columns\":[]", "\"columns\":[],\"missing_columns\":[]"), "Interval missing-column serialization is unsupported"},
      ] of Tuple(String, String)

      begin
        profiles.each do |profile, expected_message|
          File.write(path, profile)
          error = expect_raises(CrystalClick::UnsupportedFormatError) do
            CrystalClick::WidePart.open_typed(part, "v")
          end
          error.message.should eq(expected_message)
        end

        File.delete(path)
        missing_error = expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_typed(part, "v")
        end
        missing_error.message.should eq("serialization.json is required for this type")
      ensure
        File.write(path, canonical)
      end
    end
  end

  it "rejects a later unselected mark-grid corruption before an EOF window can callback" do
    with_w160g_parent do |parent|
      part = w160g_write_scalar(parent, "grid", rows_per_mark: 2)
      # Five rows produce data-mark counts [2, 2, 1]; corrupt the final data mark.
      w160g_change_mark_rows(part, "v", 2, 2_u64)

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(part, "v")
      end

      callbacks = 0
      error = expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
        table.scan_typed_window(table.total_row_count, 1) { |_batch| callbacks += 1; nil }
      end
      error.message.should eq("row count does not match marks")
      callbacks.should eq(0)
    end
  end

  it "rejects same-width wrong-kind metadata in the existing staged validator" do
    with_w160g_parent do |parent|
      source = w160g_write_scalar(parent, "source", CrystalClick::BinaryIntervalType::Kind::Hour)
      stage = File.join(parent, "stage")
      FileUtils.cp_r(source, stage)

      expected_name = CrystalClick::IntervalColumnType.interval(CrystalClick::BinaryIntervalType::Kind::Hour).type_name
      wrong_name = CrystalClick::IntervalColumnType.interval(CrystalClick::BinaryIntervalType::Kind::Year).type_name
      expected_name.bytesize.should eq(wrong_name.bytesize)
      columns_path = File.join(stage, "columns.txt")
      original_columns = File.read(columns_path)
      original_columns.should contain("`v` #{expected_name}\n")
      File.write(columns_path, original_columns.sub("`v` #{expected_name}\n", "`v` #{wrong_name}\n"))

      keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
      counts = [7_i64, -3_i64, 0_i64, 42_i64, 9_i64]
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w160g_test_validate_staged_interval(
          stage, keys.to_unsafe.to_slice(keys.size), counts.to_unsafe.to_slice(counts.size), expected_name, 2
        )
      end
      error.message.should eq("staged typed Interval column metadata differs")
    end
  end
end
