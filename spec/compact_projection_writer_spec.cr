require "./spec_helper"
require "file_utils"

W289_WRITER_NAME      = "by_values"
W289_WRITER_PARENT_ID = [1_u64, 2_u64, 3_u64, 4_u64]
W289_WRITER_PARENT_V  = [40_u64, 30_u64, 20_u64, 10_u64]
W289_WRITER_CHILD_KEY = [10_u64, 20_u64, 30_u64]
W289_WRITER_BUCKET    = [7_u64, 11_u64, 19_u64]
W289_WRITER_COUNT     = [101_u64, 202_u64, 303_u64]
W289_WRITER_ROWS      = [
  {0_i32, 0_u64, 0_u64, [7_u64, 11_u64], [101_u64, 202_u64]},
  {1_i32, 0_u64, 2_u64, [19_u64], [303_u64]},
]

private def w289_writer_grouped_values(values : Array(UInt64), rows_per_mark : Int32) : Array(Array(CrystalClick::BinaryValue))
  marks = [] of Array(CrystalClick::BinaryValue)
  values.each_slice(rows_per_mark) do |slice|
    marks << slice.map { |value| CrystalClick::BinaryValue.uint64(value) }
  end
  marks
end

private def w289_writer_wide_column(name : String, values : Array(UInt64), rows_per_mark : Int32 = 2) : CrystalClick::WidePartColumn
  type = CrystalClick::BinaryDataType.primitive("UInt64")
  CrystalClick::WidePartColumn.binary_bulk(
    name,
    type,
    w289_writer_grouped_values(values, rows_per_mark),
  )
end

private def w289_writer_compact_column(name : String, values : Array(UInt64), rows_per_mark : Int32 = 2) : CrystalClick::CompactPartColumn
  type = CrystalClick::BinaryDataType.primitive("UInt64")
  CrystalClick::CompactPartColumn.binary_bulk(
    name,
    type,
    w289_writer_grouped_values(values, rows_per_mark),
  )
end

private def w289_writer_root(label : String) : String
  root = File.tempname("crystal-click-#{label}")
  FileUtils.mkdir_p(root)
  root
end

private def w289_writer_wide_projection(
  name : String,
  key_values : Array(UInt64),
  columns : Array(CrystalClick::WidePartColumn),
  rows_per_mark : Int32 = 2,
) : CrystalClick::WidePartProjection
  retained_keys = key_values.dup
  CrystalClick::WidePartProjection.precomputed(
    name,
    "order_key",
    retained_keys.to_unsafe.to_slice(retained_keys.size),
    columns,
    rows_per_mark: rows_per_mark,
  )
end

private def w289_writer_compact_projection(
  name : String,
  key_values : Array(UInt64),
  columns : Array(CrystalClick::CompactPartColumn),
  rows_per_mark : Int32 = 2,
  mark_format : CrystalClick::CompactMarkFormat = CrystalClick::CompactMarkFormat::Mrk3,
  profile : CrystalClick::BinaryBulkProfile = CrystalClick::BinaryBulkProfile.single_stream,
  frame_bytes : Int = 4096,
) : CrystalClick::CompactPartProjection
  retained_keys = key_values.dup
  CrystalClick::CompactPartProjection.precomputed(
    name,
    "order_key",
    retained_keys.to_unsafe.to_slice(retained_keys.size),
    columns,
    rows_per_mark: rows_per_mark,
    frame_bytes: frame_bytes,
    mark_format: mark_format,
    profile: profile,
  )
end

private def w289_writer_projection_columns_wide : Array(CrystalClick::WidePartColumn)
  [
    w289_writer_wide_column("bucket", W289_WRITER_BUCKET),
    w289_writer_wide_column("n", W289_WRITER_COUNT),
  ] of CrystalClick::WidePartColumn
end

private def w289_writer_projection_columns_compact : Array(CrystalClick::CompactPartColumn)
  [
    w289_writer_compact_column("bucket", W289_WRITER_BUCKET),
    w289_writer_compact_column("n", W289_WRITER_COUNT),
  ] of CrystalClick::CompactPartColumn
end

private def w289_writer_offline_table(parent_path : String, projection_names : Array(String)) : CrystalClick::OfflineTable
  part_name = "all_1_1_0"
  info = CrystalClick::MergeTreePartInfo.parse(part_name).not_nil!
  candidate = CrystalClick::OfflinePartCandidate.new(part_name, parent_path, info, W289_WRITER_PARENT_ID.size.to_u64)
  projections = projection_names.map do |name|
    CrystalClick::OfflineProjection.new(name, "SELECT bucket, n ORDER BY bucket")
  end
  CrystalClick::OfflineTable.new(
    "events",
    "w289-writer-projection",
    "MergeTree",
    [
      CrystalClick::OfflineColumn.new("id", "UInt64", false, true),
      CrystalClick::OfflineColumn.new("value", "UInt64"),
    ] of CrystalClick::OfflineColumn,
    [candidate] of CrystalClick::OfflinePartCandidate,
    primary_key_column: "id",
    projections: projections,
  )
end

private def w289_writer_scan(
  table : CrystalClick::OfflineTable,
  projection_name : String,
) : Array({Int32, UInt64, UInt64, Array(UInt64), Array(UInt64)})
  rows = [] of {Int32, UInt64, UInt64, Array(UInt64), Array(UInt64)}
  table.scan_projection_typed(
    projection_name,
    ["bucket", "n"],
    batch_rows: 2,
  ) do |batch|
    rows << {
      batch.mark_index,
      batch.mark_row_offset,
      batch.part_row_offset,
      batch.values_for("bucket", UInt64).to_a,
      batch.values_for("n", UInt64).to_a,
    }
  end
  rows
end

private def w289_writer_assert_summary(parent_path : String, projection_name : String) : Nil
  entry_name = "#{projection_name}.proj"
  parent_entry = CrystalClick::PartChecksums.open(parent_path).entry(entry_name)
  parent_entry.should_not be_nil
  child_checksums = CrystalClick::PartChecksums.open(File.join(parent_path, entry_name))
  summary = CrystalClick::ProjectionChecksumSummary.new(child_checksums)
  parent_entry = parent_entry.not_nil!
  parent_entry.compressed.should be_false
  parent_entry.uncompressed_size.should be_nil
  parent_entry.physical_size.should eq(summary.total_size_on_disk)
  parent_entry.file_hash.should eq(summary.total_checksum)
end

private def w289_writer_assert_independent_grid(
  table : CrystalClick::OfflineTable,
  parent_path : String,
  projection_name : String,
) : Nil
  # Parent rows use [2, 2], while the three-row child keeps its own [2, 1]
  # mark schedule, offsets, and parent-part identity.
  w289_writer_scan(table, projection_name).should eq(W289_WRITER_ROWS)
  w289_writer_assert_summary(parent_path, projection_name)

  window = [] of {String, Int32, UInt64, UInt64, Array(UInt64), Array(UInt64)}
  table.scan_projection_typed_window(
    projection_name,
    ["bucket", "n"],
    1_u64,
    1,
  ) do |batch|
    window << {
      batch.part_name,
      batch.mark_index,
      batch.mark_row_offset,
      batch.part_row_offset,
      batch.values_for("bucket", UInt64).to_a,
      batch.values_for("n", UInt64).to_a,
    }
  end
  window.should eq([{"all_1_1_0", 0_i32, 1_u64, 1_u64, [11_u64], [202_u64]}])
end

private def w289_writer_write_parent(
  parent_path : String,
  layout : Symbol,
  projections : Indexable(CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection) = [] of CrystalClick::WidePartProjection,
  mark_format : CrystalClick::CompactMarkFormat = CrystalClick::CompactMarkFormat::Mrk3,
) : String
  keys = W289_WRITER_PARENT_ID.dup
  case layout
  when :wide
    CrystalClick::WidePartWriter.write_uint64_columns(
      parent_path,
      "id",
      keys.to_unsafe.to_slice(keys.size),
      [w289_writer_wide_column("value", W289_WRITER_PARENT_V)] of CrystalClick::WidePartColumn,
      rows_per_mark: 2,
      projections: projections,
    )
  when :compact
    CrystalClick::CompactPartWriter.write_uint64_columns(
      parent_path,
      "id",
      keys.to_unsafe.to_slice(keys.size),
      [w289_writer_compact_column("value", W289_WRITER_PARENT_V)] of CrystalClick::CompactPartColumn,
      rows_per_mark: 2,
      mark_format: mark_format,
      projections: projections,
    )
  else
    raise ArgumentError.new("unknown W289 parent layout")
  end
end

describe "Wide and Compact integrated projection writers" do
  it "preserves ordinary Compact publication with no projection children" do
    root = w289_writer_root("compact-no-projections-control")
    parent_path = File.join(root, "all_1_1_0")
    begin
      keys = W289_WRITER_PARENT_ID.dup
      CrystalClick::CompactPartWriter.write_uint64_columns(
        parent_path,
        "id",
        keys.to_unsafe.to_slice(keys.size),
        [w289_writer_compact_column("value", W289_WRITER_PARENT_V)] of CrystalClick::CompactPartColumn,
        rows_per_mark: 2,
      ).should eq(parent_path)

      checksums = CrystalClick::PartChecksums.open(parent_path)
      checksums.entries.size.should eq(5)
      checksums.entries.keys.any?(&.ends_with?(".proj")).should be_false
      Dir.children(parent_path).any?(&.ends_with?(".proj")).should be_false
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "retains the existing Wide-parent/Wide-child owner path" do
    root = w289_writer_root("wide-wide-control")
    parent_path = File.join(root, "all_1_1_0")
    begin
      projection = w289_writer_wide_projection(
        W289_WRITER_NAME,
        W289_WRITER_CHILD_KEY,
        w289_writer_projection_columns_wide,
      )
      w289_writer_write_parent(parent_path, :wide, [projection])
      table = w289_writer_offline_table(parent_path, [W289_WRITER_NAME])
      w289_writer_assert_independent_grid(table, parent_path, W289_WRITER_NAME)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "publishes an MRK3 Compact child under a Wide parent with its exact sidecar roster" do
    root = w289_writer_root("wide-compact-mrk3")
    parent_path = File.join(root, "all_1_1_0")
    begin
      projection = w289_writer_compact_projection(
        W289_WRITER_NAME,
        W289_WRITER_CHILD_KEY,
        w289_writer_projection_columns_compact,
      )
      w289_writer_write_parent(parent_path, :wide, [projection])
      table = w289_writer_offline_table(parent_path, [W289_WRITER_NAME])
      w289_writer_assert_independent_grid(table, parent_path, W289_WRITER_NAME)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "publishes a Wide child under a Compact parent" do
    root = w289_writer_root("compact-wide")
    parent_path = File.join(root, "all_1_1_0")
    begin
      projection = w289_writer_wide_projection(
        W289_WRITER_NAME,
        W289_WRITER_CHILD_KEY,
        w289_writer_projection_columns_wide,
      )
      w289_writer_write_parent(parent_path, :compact, [projection])
      table = w289_writer_offline_table(parent_path, [W289_WRITER_NAME])
      w289_writer_assert_independent_grid(table, parent_path, W289_WRITER_NAME)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "publishes a Compact MRK3 child under a Compact parent" do
    root = w289_writer_root("compact-compact-mrk3")
    parent_path = File.join(root, "all_1_1_0")
    begin
      projection = w289_writer_compact_projection(
        W289_WRITER_NAME,
        W289_WRITER_CHILD_KEY,
        w289_writer_projection_columns_compact,
      )
      w289_writer_write_parent(parent_path, :compact, [projection])
      table = w289_writer_offline_table(parent_path, [W289_WRITER_NAME])
      w289_writer_assert_independent_grid(table, parent_path, W289_WRITER_NAME)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps mixed Compact MRK4 and Wide children in the caller's ordered roster" do
    root = w289_writer_root("compact-mixed-ordered")
    parent_path = File.join(root, "all_1_1_0")
    begin
      compact = w289_writer_compact_projection(
        "z_compact",
        W289_WRITER_CHILD_KEY,
        w289_writer_projection_columns_compact,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      )
      wide = w289_writer_wide_projection(
        "a_wide",
        W289_WRITER_CHILD_KEY,
        w289_writer_projection_columns_wide,
      )
      # Deliberately reverse lexical order; the single Indexable snapshot is
      # dispatched and published in the order supplied by the caller.
      projections = [compact, wide]
      w289_writer_write_parent(
        parent_path,
        :compact,
        projections,
        CrystalClick::CompactMarkFormat::Mrk4,
      )

      table = w289_writer_offline_table(parent_path, ["z_compact", "a_wide"])
      ["z_compact", "a_wide"].each do |projection_name|
        w289_writer_assert_independent_grid(table, parent_path, projection_name)
      end
      parent_names = CrystalClick::PartChecksums.open(parent_path).entries.keys
      parent_names.should contain("z_compact.proj")
      parent_names.should contain("a_wide.proj")
      Dir.children(parent_path).should contain("z_compact.proj")
      Dir.children(parent_path).should contain("a_wide.proj")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects the same projection name across Wide and Compact owners before staging" do
    root = w289_writer_root("duplicate-cross-layout-name")
    parent_path = File.join(root, "all_1_1_0")
    begin
      wide = w289_writer_wide_projection(
        "same_name",
        W289_WRITER_CHILD_KEY,
        w289_writer_projection_columns_wide,
      )
      compact = w289_writer_compact_projection(
        "same_name",
        W289_WRITER_CHILD_KEY,
        w289_writer_projection_columns_compact,
      )
      expect_raises(ArgumentError, "projection names must be unique") do
        w289_writer_write_parent(parent_path, :compact, [wide, compact])
      end
      File.exists?(parent_path).should be_false
      Dir.children(root).should be_empty
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "detaches Compact projection keys, column roster, and returned containers" do
    root = w289_writer_root("compact-owner-detachment")
    parent_path = File.join(root, "all_1_1_0")
    begin
      keys = W289_WRITER_CHILD_KEY.dup
      columns = w289_writer_projection_columns_compact
      projection = w289_writer_compact_projection("detached", keys, columns)
      keys[0] = 99_u64
      columns.clear
      detached_keys = projection.keys
      detached_columns = projection.columns
      detached_keys[0] = 88_u64
      detached_columns.clear

      w289_writer_write_parent(parent_path, :compact, [projection])
      table = w289_writer_offline_table(parent_path, ["detached"])
      w289_writer_assert_independent_grid(table, parent_path, "detached")

      child = CrystalClick::CompactPartTable.open_selected_projection_child_typed(
        parent_path,
        "detached",
        ["order_key"],
      )
      actual_keys = [] of UInt64
      child.scan_typed(batch_rows: 2) do |batch|
        actual_keys.concat(batch.values_for("order_key", UInt64).to_a)
      end
      actual_keys.should eq(W289_WRITER_CHILD_KEY)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end

describe "Compact parent projection readback rollback" do
  it "cleans the outer stage when a Compact child exhausts the budget shared with an earlier Wide child" do
    control_root = w289_writer_root("compact-child-budget-control")
    failed_root = w289_writer_root("compact-later-child-budget-failure")
    failed_path = File.join(failed_root, "all_1_1_0")
    begin
      parent_keys = [1_u64, 2_u64]
      parent_values = [101_u64, 102_u64]
      child_keys = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64, 60_u64]
      first_values = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
      second_values = [11_u64, 12_u64, 13_u64, 14_u64, 15_u64, 16_u64]
      first = w289_writer_wide_projection(
        "z_first",
        child_keys,
        [w289_writer_wide_column("first_value", first_values)] of CrystalClick::WidePartColumn,
      )
      second = w289_writer_compact_projection(
        "a_second",
        child_keys,
        [w289_writer_compact_column("second_value", second_values)] of CrystalClick::CompactPartColumn,
        frame_bytes: 8,
      )
      reader_limits = CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: 160)

      # Each child consumes 96 decoded bytes and the two-row parent needs 32.
      # Eight-byte frames keep readback aligned to UInt64 values. Either child
      # fits with the parent. Both exceed the limit during the second child.
      [first, second].each do |child|
        control_path = File.join(control_root, child.name)
        CrystalClick::CompactPartWriter.write_uint64_columns(
          control_path,
          "id",
          parent_keys.to_unsafe.to_slice(parent_keys.size),
          [w289_writer_compact_column("value", parent_values, 2)] of CrystalClick::CompactPartColumn,
          rows_per_mark: 2,
          frame_bytes: 8,
          reader_limits: reader_limits,
          projections: [child],
        ).should eq(control_path)
        Dir.exists?(File.join(control_path, "#{child.name}.proj")).should be_true
      end

      expect_raises(CrystalClick::CorruptPartError, "compressed stream decoded-byte limit exceeded") do
        CrystalClick::CompactPartWriter.write_uint64_columns(
          failed_path,
          "id",
          parent_keys.to_unsafe.to_slice(parent_keys.size),
          [w289_writer_compact_column("value", parent_values, 2)] of CrystalClick::CompactPartColumn,
          rows_per_mark: 2,
          frame_bytes: 8,
          reader_limits: reader_limits,
          projections: [first, second],
        )
      end

      File.exists?(failed_path).should be_false
      Dir.children(failed_root).should be_empty
    ensure
      FileUtils.rm_rf(control_root)
      FileUtils.rm_rf(failed_root)
    end
  end
end
