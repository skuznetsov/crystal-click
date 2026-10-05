require "./spec_helper"
require "./support/interval_w160_types"

private def w160_wide_i64_bytes(values : Array(Int64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    bits = value.unsafe_as(UInt64)
    8.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w160_wide_u64_bytes(values : Array(UInt64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    8.times { |index| bytes << ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w160_wide_stream_bytes(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w160_wide_mark_rows(part : String, logical_name : String) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  bytes = File.read(path).to_slice
  raise "invalid W160 mark file size" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |mark|
    offset = mark * CrystalClick::WidePart::MARK_SIZE + 16
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end
end

private def w160_wide_assert_table_batches(
  part : String,
  nullable : Bool,
  expected_counts : Array(Int64),
  expected_nullable_counts : Array(Int64?),
  expected_keys : Array(UInt64),
) : Nil
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
  observed_keys = [] of UInt64
  observed_counts = [] of Int64
  observed_nullable_counts = [] of Int64?
  observed_marks = [] of Int32

  table.scan_typed(batch_rows: 2) do |batch|
    keys = batch.values_for("pk", UInt64)
    observed_keys.concat(keys.to_a)
    observed_marks.concat(Array(Int32).new(keys.size, batch.mark_index))
    if nullable
      values = batch.nullable_interval_counts_for("v")
      values.size.should eq(keys.size)
      observed_nullable_counts.concat(values.to_a)
    else
      values = batch.interval_counts_for("v")
      values.size.should eq(keys.size)
      observed_counts.concat(values.to_a)
    end
  end

  observed_keys.should eq(expected_keys)
  observed_marks.should eq([0, 0, 1, 1, 2, 2])
  callbacks = 0
  table.scan_typed_window(table.total_row_count, 1) { |_batch| callbacks += 1 }
  callbacks.should eq(0)
  if nullable
    observed_nullable_counts.should eq(expected_nullable_counts)
  else
    observed_counts.should eq(expected_counts)
  end
end

private def w160_wide_assert_catalog_values(
  part : String,
  type_name : String,
  nullable : Bool,
  expected_counts : Array(Int64),
  expected_nullable_counts : Array(Int64?),
  code : UInt8,
) : Nil
  root = File.tempname("crystal-click-interval-w160-catalog")
  Dir.mkdir(root)
  token = code.to_s(16).rjust(12, '0')
  database_uuid = "00000000-0000-4000-8000-#{token}"
  table_uuid = "11111111-1111-4111-8111-#{token}"
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)

  begin
    FileUtils.mkdir_p(File.join(root, "metadata"))
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n" +
      "    `pk` UInt64,\n" +
      "    `v` #{nullable ? "Nullable(#{type_name})" : type_name}\n" +
      ")\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(part, File.join(table_path, "all_1_1_0"))

    actual = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["v"].values
    if nullable
      actual.map(&.as(Int64?)).should eq(expected_nullable_counts)
    else
      actual.map(&.as(Int64)).should eq(expected_counts)
    end
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w160_wide_assert_layout(
  part : String,
  type_name : String,
  nullable : Bool,
  keys : Array(UInt64),
  expected_values : Array(Int64),
  expected_nulls : Array(UInt8),
) : Nil
  File.read(File.join(part, "columns.txt")).should eq(
    "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{nullable ? "Nullable(#{type_name})" : type_name}\n"
  )
  value_streams = nullable ? ["v.null", "v"] : ["v"]
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "#{value_streams.size} substreams for column `v`:\n" + value_streams.map { |name| "\t#{name}\n" }.join
  File.read(File.join(part, "columns_substreams.txt")).should eq(expected_substreams)
  File.read(File.join(part, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
  serialization = File.join(part, "serialization.json")
  File.exists?(serialization).should be_true
  File.read(serialization).should eq(
    "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true," +
    "\"types_serialization_versions\":{\"string\":1},\"version\":1}"
  )

  expected_raw_values = w160_wide_i64_bytes(expected_values)
  if nullable
    expected_values.each_with_index do |value, index|
      if expected_nulls[index] == 1_u8
        8.times { |byte_index| expected_raw_values[index * 8 + byte_index] = 0_u8 }
      end
    end
    w160_wide_stream_bytes(part, "v.null").should eq(expected_nulls)
  end
  w160_wide_stream_bytes(part, "pk").should eq(w160_wide_u64_bytes(keys))
  w160_wide_stream_bytes(part, "v").should eq(expected_raw_values)

  mark_streams = nullable ? ["pk", "v.null", "v"] : ["pk", "v"]
  mark_streams.each do |stream|
    w160_wide_mark_rows(part, stream).should eq([2_u64, 2_u64, 2_u64, 0_u64])
  end
end

describe CrystalClick::WidePartWriter do
  it "writes and reads all eleven scalar and nullable raw Interval count types" do
    parent = File.tempname("crystal-click-interval-w160-wide")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64]
    counts = [Int64::MIN, -3_i64, 0_i64, 42_i64, -1_i64, Int64::MAX]
    nullable_counts = [Int64::MIN, -3_i64, 0_i64, nil, -1_i64, Int64::MAX] of Int64?
    null_map = [0_u8, 0_u8, 0_u8, 1_u8, 0_u8, 0_u8]
    key_slice = keys.to_unsafe.to_slice(keys.size)
    count_slice = counts.to_unsafe.to_slice(counts.size)
    nullable_slice = nullable_counts.to_unsafe.to_slice(nullable_counts.size)

    begin
      W160_INTERVAL_TYPES.each do |type_name, kind, _code|
        scalar_parent = File.join(parent, "scalar-#{type_name}")
        nullable_parent = File.join(parent, "nullable-#{type_name}")
        Dir.mkdir(scalar_parent)
        Dir.mkdir(nullable_parent)
        scalar_part = File.join(scalar_parent, "all_1_1_0")
        nullable_part = File.join(nullable_parent, "all_1_1_0")

        CrystalClick::WidePartWriter.write_uint64_interval_pair(
          scalar_part, "pk", key_slice, "v", count_slice, kind, rows_per_mark: 2
        ).should eq(scalar_part)
        CrystalClick::WidePartWriter.write_uint64_nullable_interval_pair(
          nullable_part, "pk", key_slice, "v", nullable_slice, kind, rows_per_mark: 2
        ).should eq(nullable_part)

        w160_wide_assert_layout(scalar_part, type_name, false, keys, counts, null_map)
        w160_wide_assert_layout(nullable_part, type_name, true, keys, counts, null_map)

        scalar = CrystalClick::WidePart.open_typed(scalar_part, "v")
        scalar.column_type.should eq(type_name)
        scalar.row_count.should eq(6_u64)
        scalar.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
        scalar.read_interval_counts_mark_range("v", 0, scalar.mark_count).should eq(counts)
        scalar.read_interval_counts_mark_range("v", 1, 1).should eq([0_i64, 42_i64])
        expect_raises(CrystalClick::BoundsError) do
          scalar.read_interval_counts_mark_range("v", 0, 0)
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          scalar.read_nullable_interval_counts_mark_range("v", 0, scalar.mark_count)
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          scalar.read_numeric_mark_range("v", 0, scalar.mark_count, Int64)
        end
        w160_wide_assert_table_batches(scalar_part, false, counts, nullable_counts, keys)
        w160_wide_assert_catalog_values(scalar_part, type_name, false, counts, nullable_counts, _code)

        nullable = CrystalClick::WidePart.open_typed(nullable_part, "v")
        nullable.column_type.should eq("Nullable(#{type_name})")
        nullable.row_count.should eq(6_u64)
        nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
        nullable.read_nullable_interval_counts_mark_range("v", 0, nullable.mark_count).should eq(nullable_counts)
        nullable.read_nullable_interval_counts_mark_range("v", 1, 1).should eq([0_i64, nil] of Int64?)
        expect_raises(CrystalClick::BoundsError) do
          nullable.read_nullable_interval_counts_mark_range("v", 0, 0)
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          nullable.read_interval_counts_mark_range("v", 0, nullable.mark_count)
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          nullable.read_numeric_mark_range("v", 0, nullable.mark_count, Int64)
        end
        w160_wide_assert_table_batches(nullable_part, true, counts, nullable_counts, keys)
        w160_wide_assert_catalog_values(nullable_part, type_name, true, counts, nullable_counts, _code)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a forged Interval kind before creating a destination or staged files" do
    parent = File.tempname("crystal-click-interval-w160-forged-kind")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64]
    counts = [Int64::MIN, Int64::MAX]
    forged = CrystalClick::BinaryIntervalType::Kind.new(0x0b_u8)

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_interval_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "v",
          counts.to_unsafe.to_slice(counts.size),
          forged,
          rows_per_mark: 1
        )
      end
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
