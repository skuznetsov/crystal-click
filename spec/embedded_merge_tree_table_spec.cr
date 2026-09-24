require "./spec_helper"

# The spec binary doubles as a tiny child writer so the locking example below
# exercises separate OS processes, not only stale Crystal objects.
if reader_root = ENV["CRYSTAL_CLICK_W4_READER_ROOT"]?
  ready_path = ENV["CRYSTAL_CLICK_W4_READER_READY"]? || raise "missing reader ready path"
  done_path = ENV["CRYSTAL_CLICK_W4_READER_DONE"]? || raise "missing reader done path"
  File.write(ready_path, "ready")
  begin
    CrystalClick::EmbeddedMergeTreeTable.open(reader_root).part_paths
    File.write(done_path, "done")
    Process.exit(0)
  rescue ex
    STDERR.puts ex.message || ex.class.name
    Process.exit(2)
  end
elsif worker_root = ENV["CRYSTAL_CLICK_W4_WORKER_ROOT"]?
  ready_path = ENV["CRYSTAL_CLICK_W4_WORKER_READY"]? || raise "missing worker ready path"
  go_path = ENV["CRYSTAL_CLICK_W4_WORKER_GO"]? || raise "missing worker go path"
  File.write(ready_path, "ready")
  until File.exists?(go_path)
    sleep 5.milliseconds
  end
  begin
    table = CrystalClick::EmbeddedMergeTreeTable.open(worker_root)
    table.insert([9_u64].to_unsafe.to_slice(1), ["worker"].to_unsafe.to_slice(1), rows_per_mark: 1)
    Process.exit(0)
  rescue ex
    STDERR.puts ex.message || ex.class.name
    Process.exit(2)
  end
end

def with_embedded_table_parent(&)
  parent = File.tempname("crystal-click-embedded-table-spec")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

def embedded_table_rows(table : CrystalClick::EmbeddedMergeTreeTable, key_name : String, value_name : String) : Array({UInt64, String})
  rows = [] of {UInt64, String}
  table.scan_typed([key_name, value_name], batch_rows: 2) do |batch|
    keys = batch.values_for(key_name, UInt64)
    values = batch.strings_for(value_name)
    keys.size.should eq(values.size)
    keys.size.times { |index| rows << {keys[index], values[index]} }
  end
  rows
end

def embedded_part_bytes(path : String) : Hash(String, String)
  Dir.children(path).to_h do |name|
    {name, File.read(File.join(path, name))}
  end
end

def write_embedded_physical_part(root : String, name : String, keys : Array(UInt64), values : Array(String), rows_per_mark : Int32 = 2) : String
  path = File.join(root, "parts", name)
  CrystalClick::WidePartWriter.write_uint64_string_pair(
    path,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "value",
    values.to_unsafe.to_slice(values.size),
    rows_per_mark
  )
end

def mark_embedded_part_committed(root : String, name : String) : Nil
  Dir.mkdir(File.join(root, "committed", name))
end

describe CrystalClick::EmbeddedMergeTreeTable do
  it "rejects an existing root without modifying its contents or leaking a stage" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      Dir.mkdir(root)
      sentinel = File.join(root, "keep.txt")
      File.write(sentinel, "do not replace")

      expect_raises(ArgumentError) do
        CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      end

      File.read(sentinel).should eq("do not replace")
      Dir.children(parent).sort.should eq(["table"])
    end
  end

  it "creates, inserts, scans typed rows, and reopens its immutable manifest" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      keys = [1_u64, 2_u64, 2_u64, UInt64::MAX]
      values = ["", "a\0b", "é", "last"]

      table.insert(keys.to_unsafe.to_slice(keys.size), values.to_unsafe.to_slice(values.size), rows_per_mark: 2).should eq("all_1_1_0")
      table.part_paths.should eq([File.join(root, "parts", "all_1_1_0")])
      table.orphan_part_names.should eq([] of String)
      embedded_table_rows(table, "pk", "value").should eq(keys.zip(values))

      reopened = CrystalClick::EmbeddedMergeTreeTable.open(root)
      reopened.key_name.should eq("pk")
      reopened.value_name.should eq("value")
      embedded_table_rows(reopened, "pk", "value").should eq(keys.zip(values))
      File.read(File.join(root, "manifest.json")).should contain("\"format_version\":1")
    end
  end

  it "keeps a physically published unmarked part invisible and allocates beyond its id" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      orphan_path = File.join(root, "parts", "all_4_4_0")
      CrystalClick::WidePartWriter.write_uint64_string_pair(
        orphan_path,
        "pk",
        [10_u64, 11_u64].to_unsafe.to_slice(2),
        "value",
        ["orphan-a", "orphan-b"].to_unsafe.to_slice(2),
        rows_per_mark: 1
      )

      table.orphan_part_names.should eq(["all_4_4_0"])
      table.part_paths.should eq([] of String)
      table.insert([20_u64].to_unsafe.to_slice(1), ["committed"].to_unsafe.to_slice(1), rows_per_mark: 1).should eq("all_5_5_0")
      embedded_table_rows(table, "pk", "value").should eq([{20_u64, "committed"}])
    end
  end

  it "refuses to publish when the inventory entry cap is already full" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      parts = File.join(root, "parts")
      entry_limit = CrystalClick::WidePartTable::MAX_PARTS * 2
      entry_limit.times do |index|
        Dir.mkdir(File.join(parts, ".crystal-click-wide-writer-#{index}"))
      end

      expect_raises(CrystalClick::BoundsError) do
        table.insert([1_u64].to_unsafe.to_slice(1), ["v"].to_unsafe.to_slice(1), rows_per_mark: 1)
      end
      Dir.children(parts).size.should eq(entry_limit)
      Dir.children(File.join(root, "committed")).should be_empty
    end
  end

  it "fails closed when a commit marker has no corresponding part" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      Dir.mkdir(File.join(root, "committed", "all_1_1_0"))

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::EmbeddedMergeTreeTable.open(root)
      end
    end
  end

  it "rejects malformed physical part names and nonempty or symbolic commit markers" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      Dir.mkdir(File.join(root, "parts", "all_01_01_0"))
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::EmbeddedMergeTreeTable.open(root)
      end
    end

    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      Dir.mkdir(File.join(root, "parts", "all_-1_-1_0"))
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::EmbeddedMergeTreeTable.open(root)
      end
    end

    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      target = File.join(parent, "outside")
      Dir.mkdir(target)
      File.symlink(target, File.join(root, "committed", "all_1_1_0"))
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::EmbeddedMergeTreeTable.open(root)
      end
    end

    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      marker = File.join(root, "committed", "all_1_1_0")
      Dir.mkdir(marker)
      File.write(File.join(marker, "unexpected"), "x")
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::EmbeddedMergeTreeTable.open(root)
      end
    end
  end

  it "validates an exact table and part schema rather than only selected columns" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      manifest_path = File.join(root, "manifest.json")
      manifest = JSON.parse(File.read(manifest_path)).as_h
      manifest["unexpected"] = JSON::Any.new(true)
      File.write(manifest_path, manifest.to_json)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::EmbeddedMergeTreeTable.open(root)
      end
    end

    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      table.insert([1_u64].to_unsafe.to_slice(1), ["v"].to_unsafe.to_slice(1), rows_per_mark: 1)
      part = File.join(root, "parts", "all_1_1_0")
      File.write(File.join(part, "columns.txt"), "columns format version: 1\n3 columns:\n`pk` UInt64\n`value` String\n`extra` UInt64\n")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::EmbeddedMergeTreeTable.open(root)
      end
    end

    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      table.insert([1_u64].to_unsafe.to_slice(1), ["v"].to_unsafe.to_slice(1), rows_per_mark: 1)
      part = File.join(root, "parts", "all_1_1_0")
      columns_path = File.join(part, "columns.txt")
      external_columns = File.join(parent, "columns.txt")
      File.write(external_columns, File.read(columns_path))
      File.delete(columns_path)
      File.symlink(external_columns, columns_path)

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::EmbeddedMergeTreeTable.open(root)
      end
    end

    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      table.insert([1_u64].to_unsafe.to_slice(1), ["v"].to_unsafe.to_slice(1), rows_per_mark: 1)
      columns_path = File.join(root, "parts", "all_1_1_0", "columns.txt")
      File.write(columns_path, "x" * 4_097)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::EmbeddedMergeTreeTable.open(root)
      end
    end
  end

  it "validates requested columns and batch bounds even when there are no committed parts" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      seen = false
      table.scan_typed(["pk", "value"], batch_rows: 2) { seen = true }
      seen.should be_false
      expect_raises(CrystalClick::UnsupportedFormatError) { table.scan_typed(["other"]) { |_| } }
      expect_raises(CrystalClick::BoundsError) { table.scan_typed(["pk"], batch_rows: 0) { |_| } }
    end
  end

  it "rejects unsorted keys and preserves all earlier committed rows" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      table.insert([1_u64].to_unsafe.to_slice(1), ["first"].to_unsafe.to_slice(1), rows_per_mark: 1)

      expect_raises(ArgumentError) do
        table.insert([3_u64, 2_u64].to_unsafe.to_slice(2), ["x", "y"].to_unsafe.to_slice(2), rows_per_mark: 1)
      end
      table.part_paths.map { |path| File.basename(path) }.should eq(["all_1_1_0"])
      embedded_table_rows(table, "pk", "value").should eq([{1_u64, "first"}])
    end
  end

  it "stably merges adjacent parts and leaves both immutable sources untouched" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      left_name = table.insert(
        [1_u64, 2_u64, 2_u64, 5_u64].to_unsafe.to_slice(4),
        ["left-1", "", "left\0two", "left-5"].to_unsafe.to_slice(4),
        rows_per_mark: 2
      )
      right_name = table.insert(
        [1_u64, 2_u64, 3_u64, 5_u64].to_unsafe.to_slice(4),
        ["right-1", "right-2", "é", "right-5"].to_unsafe.to_slice(4),
        rows_per_mark: 2
      )
      left_path = File.join(root, "parts", left_name)
      right_path = File.join(root, "parts", right_name)
      left_before = embedded_part_bytes(left_path)
      right_before = embedded_part_bytes(right_path)

      merged_name = table.merge_adjacent(left_name, right_name, rows_per_mark: 3)

      merged_name.should eq("all_1_2_1")
      table.part_paths.map { |path| File.basename(path) }.should eq([merged_name])
      embedded_table_rows(table, "pk", "value").should eq([
        {1_u64, "left-1"},
        {1_u64, "right-1"},
        {2_u64, ""},
        {2_u64, "left\0two"},
        {2_u64, "right-2"},
        {3_u64, "é"},
        {5_u64, "left-5"},
        {5_u64, "right-5"},
      ])
      embedded_part_bytes(left_path).should eq(left_before)
      embedded_part_bytes(right_path).should eq(right_before)
      Dir.children(File.join(root, "committed")).sort.should eq(["all_1_1_0", "all_1_2_1", "all_2_2_0"])

      reopened = CrystalClick::EmbeddedMergeTreeTable.open(root)
      reopened.part_paths.map { |path| File.basename(path) }.should eq([merged_name])
      embedded_table_rows(reopened, "pk", "value").should eq([
        {1_u64, "left-1"},
        {1_u64, "right-1"},
        {2_u64, ""},
        {2_u64, "left\0two"},
        {2_u64, "right-2"},
        {3_u64, "é"},
        {5_u64, "left-5"},
        {5_u64, "right-5"},
      ])
    end
  end

  it "selects only maximal marked intervals through nested merges and retains history" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      first = table.insert([1_u64, 5_u64].to_unsafe.to_slice(2), ["a1", "a5"].to_unsafe.to_slice(2), rows_per_mark: 1)
      second = table.insert([2_u64, 4_u64].to_unsafe.to_slice(2), ["b2", "b4"].to_unsafe.to_slice(2), rows_per_mark: 1)
      third = table.insert([3_u64, 6_u64].to_unsafe.to_slice(2), ["c3", "c6"].to_unsafe.to_slice(2), rows_per_mark: 1)

      first_merge = table.merge_adjacent(first, second, rows_per_mark: 2)
      table.part_paths.map { |path| File.basename(path) }.should eq([first_merge, third])
      final_merge = table.merge_adjacent(first_merge, third, rows_per_mark: 2)

      final_merge.should eq("all_1_3_2")
      reopened = CrystalClick::EmbeddedMergeTreeTable.open(root)
      reopened.part_paths.map { |path| File.basename(path) }.should eq([final_merge])
      embedded_table_rows(reopened, "pk", "value").should eq([
        {1_u64, "a1"},
        {2_u64, "b2"},
        {3_u64, "c3"},
        {4_u64, "b4"},
        {5_u64, "a5"},
        {6_u64, "c6"},
      ])
      Dir.children(File.join(root, "committed")).size.should eq(5)
      Dir.children(File.join(root, "committed")).sort.should eq([
        "all_1_1_0",
        "all_1_2_1",
        "all_1_3_2",
        "all_2_2_0",
        "all_3_3_0",
      ])
    end
  end

  it "rejects reversed, stale, non-neighboring, and path-like merge inputs without publication" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      first = table.insert([1_u64].to_unsafe.to_slice(1), ["a"].to_unsafe.to_slice(1), rows_per_mark: 1)
      second = table.insert([2_u64].to_unsafe.to_slice(1), ["b"].to_unsafe.to_slice(1), rows_per_mark: 1)
      third = table.insert([3_u64].to_unsafe.to_slice(1), ["c"].to_unsafe.to_slice(1), rows_per_mark: 1)
      original_parts = Dir.children(File.join(root, "parts")).sort
      original_markers = Dir.children(File.join(root, "committed")).sort

      expect_raises(ArgumentError) { table.merge_adjacent(second, first, rows_per_mark: 1) }
      expect_raises(ArgumentError) { table.merge_adjacent(first, third, rows_per_mark: 1) }
      expect_raises(ArgumentError) { table.merge_adjacent(first, first, rows_per_mark: 1) }
      expect_raises(ArgumentError) { table.merge_adjacent("../outside", second, rows_per_mark: 1) }
      expect_raises(ArgumentError) { table.merge_adjacent(first, second, rows_per_mark: 0) }
      Dir.children(File.join(root, "parts")).sort.should eq(original_parts)
      Dir.children(File.join(root, "committed")).sort.should eq(original_markers)

      merged = table.merge_adjacent(first, second, rows_per_mark: 1)
      expect_raises(ArgumentError) { table.merge_adjacent(first, second, rows_per_mark: 1) }
      Dir.children(File.join(root, "parts")).sort.should eq((original_parts + [merged]).sort)
      Dir.children(File.join(root, "committed")).sort.should eq((original_markers + [merged]).sort)
      table.part_paths.map { |path| File.basename(path) }.should eq([merged, third])
    end
  end

  it "ignores an overlapping merge orphan and retries its range at a higher level" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      left = table.insert([10_u64].to_unsafe.to_slice(1), ["ten"].to_unsafe.to_slice(1), rows_per_mark: 1)
      right = table.insert([20_u64].to_unsafe.to_slice(1), ["twenty"].to_unsafe.to_slice(1), rows_per_mark: 1)
      orphan_name = "all_1_2_1"
      orphan_path = write_embedded_physical_part(root, orphan_name, [10_u64, 20_u64], ["orphan-ten", "orphan-twenty"] of String)

      table.orphan_part_names.should eq([orphan_name])
      reopened_before_marker = CrystalClick::EmbeddedMergeTreeTable.open(root)
      reopened_before_marker.part_paths.map { |path| File.basename(path) }.should eq([left, right])
      embedded_table_rows(reopened_before_marker, "pk", "value").should eq([{10_u64, "ten"}, {20_u64, "twenty"}])
      orphan_before = embedded_part_bytes(orphan_path)

      merged = reopened_before_marker.merge_adjacent(left, right, rows_per_mark: 1)

      merged.should eq("all_1_2_2")
      embedded_part_bytes(orphan_path).should eq(orphan_before)
      table.orphan_part_names.should eq([orphan_name])
      reopened_after_marker = CrystalClick::EmbeddedMergeTreeTable.open(root)
      reopened_after_marker.part_paths.map { |path| File.basename(path) }.should eq([merged])
      embedded_table_rows(reopened_after_marker, "pk", "value").should eq([{10_u64, "ten"}, {20_u64, "twenty"}])
    end
  end

  it "rejects merge level exhaustion before publishing a part" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      left = table.insert([1_u64].to_unsafe.to_slice(1), ["one"].to_unsafe.to_slice(1), rows_per_mark: 1)
      right = table.insert([2_u64].to_unsafe.to_slice(1), ["two"].to_unsafe.to_slice(1), rows_per_mark: 1)
      max_level_orphan = "all_1_2_#{CrystalClick::MergeTreePartInfo::MAX_LEVEL}"
      write_embedded_physical_part(root, max_level_orphan, [1_u64, 2_u64], ["orphan-one", "orphan-two"] of String)
      expected_parts = Dir.children(File.join(root, "parts")).sort
      expected_markers = Dir.children(File.join(root, "committed")).sort

      expect_raises(CrystalClick::BoundsError) { table.merge_adjacent(left, right, rows_per_mark: 1) }
      Dir.children(File.join(root, "parts")).sort.should eq(expected_parts)
      Dir.children(File.join(root, "committed")).sort.should eq(expected_markers)
      table.part_paths.map { |path| File.basename(path) }.should eq([left, right])
    end
  end

  it "rejects partial and equal-range marked overlap" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "partial")
      CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      [
        {"all_1_2_1", [1_u64, 2_u64], ["a", "b"]},
        {"all_2_3_1", [2_u64, 3_u64], ["b", "c"]},
      ].each do |name, keys, values|
        write_embedded_physical_part(root, name, keys, values, 1)
        mark_embedded_part_committed(root, name)
      end
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::EmbeddedMergeTreeTable.open(root) }
    end

    with_embedded_table_parent do |parent|
      root = File.join(parent, "equal")
      CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      ["all_1_2_1", "all_1_2_2"].each_with_index do |name, index|
        write_embedded_physical_part(root, name, [1_u64, 2_u64], ["v#{index}-1", "v#{index}-2"], 1)
        mark_embedded_part_committed(root, name)
      end
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::EmbeddedMergeTreeTable.open(root) }
    end
  end

  it "rejects row and aggregate String payload overflow before publishing" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "row-limit")
      table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      row_count = 50_001
      keys = Array(UInt64).new(row_count) { |index| index.to_u64 }
      values = Array(String).new(row_count) { "" }
      first = table.insert(keys.to_unsafe.to_slice(row_count), values.to_unsafe.to_slice(row_count), rows_per_mark: row_count)
      second = table.insert(keys.to_unsafe.to_slice(row_count), values.to_unsafe.to_slice(row_count), rows_per_mark: row_count)

      expect_raises(CrystalClick::BoundsError) { table.merge_adjacent(first, second, rows_per_mark: 65_536) }
      Dir.children(File.join(root, "parts")).sort.should eq([first, second].sort)
      Dir.children(File.join(root, "committed")).sort.should eq([first, second].sort)
    end

    with_embedded_table_parent do |parent|
      root = File.join(parent, "payload-limit")
      table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      payload = "p" * (CrystalClick::EmbeddedMergeTreeTable::MAX_MERGE_PAYLOAD_BYTES // 2 + 1).to_i
      first = table.insert([1_u64].to_unsafe.to_slice(1), [payload].to_unsafe.to_slice(1), rows_per_mark: 1)
      second = table.insert([2_u64].to_unsafe.to_slice(1), [payload].to_unsafe.to_slice(1), rows_per_mark: 1)

      expect_raises(CrystalClick::BoundsError) { table.merge_adjacent(first, second, rows_per_mark: 1) }
      Dir.children(File.join(root, "parts")).sort.should eq([first, second].sort)
      Dir.children(File.join(root, "committed")).sort.should eq([first, second].sort)
    end
  end

  it "preflights the physical-entry cap before a merge can make the root unopenable" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      first = table.insert([1_u64].to_unsafe.to_slice(1), ["a"].to_unsafe.to_slice(1), rows_per_mark: 1)
      second = table.insert([2_u64].to_unsafe.to_slice(1), ["b"].to_unsafe.to_slice(1), rows_per_mark: 1)
      stage_count = CrystalClick::EmbeddedMergeTreeTable::MAX_PHYSICAL_ENTRIES - 2
      stage_count.times do |index|
        Dir.mkdir(File.join(root, "parts", ".crystal-click-wide-writer-cap-#{index}"))
      end
      expected_parts = Dir.children(File.join(root, "parts")).sort
      expected_markers = Dir.children(File.join(root, "committed")).sort

      expect_raises(CrystalClick::BoundsError) { table.merge_adjacent(first, second, rows_per_mark: 1) }
      Dir.children(File.join(root, "parts")).sort.should eq(expected_parts)
      Dir.children(File.join(root, "committed")).sort.should eq(expected_markers)
    end
  end

  it "checks the raw primary index structure for every committed part" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      table.insert([1_u64, 2_u64].to_unsafe.to_slice(2), ["a", "b"].to_unsafe.to_slice(2), rows_per_mark: 1)
      index_path = File.join(root, "parts", "all_1_1_0", "primary.idx")
      File.open(index_path, "a") { |file| file.write_byte(0_u8) }

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::EmbeddedMergeTreeTable.open(root)
      end
    end
  end

  it "uses the advisory lock across concurrent writer processes" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      go_path = File.join(parent, "go")
      worker_paths = [File.join(parent, "ready-1"), File.join(parent, "ready-2")]
      executable = Process.executable_path || raise "spec executable path unavailable"
      children = [] of Process
      waited = [false, false]
      begin
        worker_paths.each do |ready_path|
          children << Process.new(
            executable,
            env: {
              "CRYSTAL_CLICK_W4_WORKER_ROOT"  => root,
              "CRYSTAL_CLICK_W4_WORKER_READY" => ready_path,
              "CRYSTAL_CLICK_W4_WORKER_GO"    => go_path,
            },
            output: Process::Redirect::Pipe,
            error: Process::Redirect::Pipe
          )
        end

        deadline = Time.instant + 10.seconds
        until worker_paths.all? { |path| File.exists?(path) }
          raise "writer workers did not reach the barrier" if Time.instant > deadline
          sleep 5.milliseconds
        end
        File.write(go_path, "go")
        children.each_with_index do |child, index|
          status = child.wait
          waited[index] = true
          status.success?.should be_true
        end

        names = Dir.children(File.join(root, "committed")).sort
        names.should eq(["all_1_1_0", "all_2_2_0"])
        embedded_table_rows(CrystalClick::EmbeddedMergeTreeTable.open(root), "pk", "value").size.should eq(2)
      ensure
        children.each_with_index do |child, index|
          unless waited[index]
            child.terminate unless child.terminated?
            begin
              child.wait
            rescue Channel::ClosedError
            end
          end
        end
      end
    end
  end

  it "holds a shared advisory lock across reader inventory" do
    with_embedded_table_parent do |parent|
      root = File.join(parent, "table")
      CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
      lock_file = File.open(File.join(root, "writer.lock"), "r+")
      lock_result = LibC.flock(lock_file.fd.to_i, LibC::FlockOp::EX)
      lock_result.should eq(0)

      ready_path = File.join(parent, "reader-ready")
      done_path = File.join(parent, "reader-done")
      executable = Process.executable_path || raise "spec executable path unavailable"
      reader = Process.new(
        executable,
        env: {
          "CRYSTAL_CLICK_W4_READER_ROOT"  => root,
          "CRYSTAL_CLICK_W4_READER_READY" => ready_path,
          "CRYSTAL_CLICK_W4_READER_DONE"  => done_path,
        },
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe
      )
      waited = false
      locked = true
      begin
        deadline = Time.instant + 10.seconds
        until File.exists?(ready_path)
          raise "reader did not reach the pre-inventory barrier" if reader.terminated? || Time.instant > deadline
          sleep 5.milliseconds
        end

        sleep 100.milliseconds
        File.exists?(done_path).should be_false
      ensure
        if locked
          unlock_result = LibC.flock(lock_file.fd.to_i, LibC::FlockOp::UN)
          locked = false
          raise IO::Error.from_errno("test reader lock release failed") unless unlock_result == 0
        end

        unless waited
          deadline = Time.instant + 2.seconds
          until reader.terminated? || Time.instant > deadline
            sleep 5.milliseconds
          end
          reader.terminate unless reader.terminated?
          reader.wait
          waited = true
        end
      end

      File.exists?(done_path).should be_true
    end
  end
end
