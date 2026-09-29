require "./spec_helper"

private def w87_write_parent_part(path : String, key : UInt64) : String
  FileUtils.mkdir_p(File.dirname(path))
  keys = [key]
  values = [key]
  CrystalClick::WidePartWriter.write_uint64_pair(
    path,
    "id",
    keys.to_unsafe.to_slice(keys.size),
    "value",
    values.to_unsafe.to_slice(values.size),
    rows_per_mark: 1
  )
end

private def w87_write_projection_part(
  parent_part : String,
  keys : Array(UInt64),
  labels : Array(String),
  rows_per_mark : Int32 = 2,
) : String
  child = File.join(parent_part, "by_tag.proj")
  CrystalClick::WidePartWriter.write_uint64_string_pair(
    child,
    "tag",
    keys.to_unsafe.to_slice(keys.size),
    "label",
    labels.to_unsafe.to_slice(labels.size),
    rows_per_mark: rows_per_mark
  )
end

describe "W87 typed projection table reader" do
  it "reads child rows in parent-part order without equating child and parent counts" do
    root = File.tempname("crystal-click-w87-projection-table")
    Dir.mkdir(root)
    parent_a = File.join(root, "all_1_1_0")
    parent_b = File.join(root, "all_2_2_0")

    begin
      w87_write_parent_part(parent_a, 1_u64)
      w87_write_parent_part(parent_b, 2_u64)
      w87_write_projection_part(parent_a, [10_u64, 20_u64, 30_u64], ["a", "b", "c"])
      w87_write_projection_part(parent_b, [40_u64], ["d"])

      table = CrystalClick::WidePartTable.open_selected_projection_typed(
        [parent_a, parent_b],
        "by_tag",
        ["tag", "label"]
      )

      table.part_count.should eq(2)
      table.total_row_count.should eq(4_u64)
      table.part_mark_row_counts.should eq([[2_u64, 1_u64], [1_u64]])
      table.checksum_verification.should eq(CrystalClick::ChecksumVerification::SizeChecked)

      tags = [] of UInt64
      labels = [] of String
      part_paths = [] of String
      table.scan_typed(batch_rows: 2) do |batch|
        tags.concat(batch.values_for("tag").to_a)
        labels.concat(batch.strings_for("label").to_a)
        part_paths << batch.part_path unless part_paths.last? == batch.part_path
      end

      tags.should eq([10_u64, 20_u64, 30_u64, 40_u64])
      labels.should eq(["a", "b", "c", "d"])
      part_paths.should eq([parent_a, parent_b])

      expect_raises(CrystalClick::InvalidPartError) do
        CrystalClick::WidePartTable.open_selected_typed(
          [File.join(parent_a, "by_tag.proj")],
          ["tag"]
        )
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects a missing child before a scan can expose callbacks" do
    root = File.tempname("crystal-click-w87-projection-missing")
    Dir.mkdir(root)
    parent_a = File.join(root, "all_1_1_0")
    parent_b = File.join(root, "all_2_2_0")

    begin
      w87_write_parent_part(parent_a, 1_u64)
      w87_write_parent_part(parent_b, 2_u64)
      w87_write_projection_part(parent_a, [10_u64], ["a"])

      callbacks = 0
      expect_raises(CrystalClick::InvalidPartError) do
        table = CrystalClick::WidePartTable.open_selected_projection_typed(
          [parent_a, parent_b],
          "by_tag",
          ["tag"]
        )
        table.scan_typed { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects projection child symlinks and unsafe projection names" do
    root = File.tempname("crystal-click-w87-projection-paths")
    Dir.mkdir(root)
    parent_a = File.join(root, "all_1_1_0")
    parent_b = File.join(root, "all_2_2_0")

    begin
      w87_write_parent_part(parent_a, 1_u64)
      w87_write_parent_part(parent_b, 2_u64)
      child_a = w87_write_projection_part(parent_a, [10_u64], ["a"])
      File.symlink(child_a, File.join(parent_b, "by_tag.proj"))

      expect_raises(CrystalClick::InvalidPartError) do
        CrystalClick::WidePartTable.open_selected_projection_typed(
          [parent_a, parent_b],
          "by_tag",
          ["tag"]
        )
      end

      expect_raises(CrystalClick::InvalidPartError) do
        CrystalClick::WidePartTable.open_selected_projection_typed(
          [parent_a],
          "../outside",
          ["tag"]
        )
      end
      expect_raises(CrystalClick::InvalidPartError) do
        CrystalClick::WidePartTable.open_selected_projection_typed(
          [parent_a],
          "by_täg",
          ["tag"]
        )
      end
      File.exists?(File.join(root, "outside.proj")).should be_false
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "preserves the empty-selection bounds error" do
    expect_raises(CrystalClick::BoundsError) do
      CrystalClick::WidePartTable.open_selected_projection_typed(
        [] of String,
        "by_tag",
        ["tag"]
      )
    end
  end

  it "rejects overlapping parent identities and child schema drift" do
    root = File.tempname("crystal-click-w87-projection-validation")
    Dir.mkdir(root)
    parent_a = File.join(root, "all_1_2_0")
    parent_b = File.join(root, "all_2_3_0")

    begin
      w87_write_parent_part(parent_a, 1_u64)
      w87_write_parent_part(parent_b, 2_u64)
      w87_write_projection_part(parent_a, [10_u64], ["a"])
      w87_write_projection_part(parent_b, [20_u64], ["b"])

      ex = expect_raises(CrystalClick::InvalidPartError) do
        CrystalClick::WidePartTable.open_selected_projection_typed(
          [parent_a, parent_b],
          "by_tag",
          ["tag"]
        )
      end
      ex.message.not_nil!.should contain("selected parts overlap")

      distinct_b = File.join(root, "all_3_3_0")
      w87_write_parent_part(distinct_b, 3_u64)
      mismatched_child = File.join(distinct_b, "by_tag.proj")
      keys = [30_u64]
      values = [300_u64]
      CrystalClick::WidePartWriter.write_uint64_pair(
        mismatched_child,
        "tag",
        keys.to_unsafe.to_slice(keys.size),
        "label",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 1
      )

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.open_selected_projection_typed(
          [parent_a, distinct_b],
          "by_tag",
          ["tag", "label"]
        )
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "checks selected child stream sizes before constructing the table" do
    root = File.tempname("crystal-click-w87-projection-checksums")
    Dir.mkdir(root)
    parent = File.join(root, "all_1_1_0")

    begin
      w87_write_parent_part(parent, 1_u64)
      child = w87_write_projection_part(parent, [10_u64], ["a"])
      reader = CrystalClick::WidePart.open_typed(child, "label")
      selected_stream = reader.selected_checksum_names.first
      stream_path = File.join(child, selected_stream)
      File.write(stream_path, File.read(stream_path) + "x")

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.open_selected_projection_typed(
          [parent],
          "by_tag",
          ["label"]
        )
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
