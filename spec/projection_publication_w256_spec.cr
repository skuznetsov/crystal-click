require "./spec_helper"
require "file_utils"
require "./support/projection_publication_w256_fixture"

private def w256_offline_table(
  part : String,
  projections : Array(CrystalClick::OfflineProjection),
) : CrystalClick::OfflineTable
  columns = [
    CrystalClick::OfflineColumn.new("id", "UInt64", false, true),
    CrystalClick::OfflineColumn.new("score", "UInt64"),
    CrystalClick::OfflineColumn.new("label", "String"),
    CrystalClick::OfflineColumn.new("items", "Array(UInt16)"),
  ] of CrystalClick::OfflineColumn
  info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
  candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part, info, 6_u64)
  CrystalClick::OfflineTable.new(
    "events",
    "w256-projection-publication",
    "MergeTree",
    columns,
    [candidate] of CrystalClick::OfflinePartCandidate,
    primary_key_column: "id",
    projections: projections,
  )
end

module CrystalClick::WidePartWriter
  # Keep serializer-metadata adversaries focused on semantic admission rather
  # than the reader's size-only checksum precheck.
  def self.w256_refresh_checksums(part : String) : Nil
    current = PartChecksums.open(part)
    records = [] of ChecksumRecord
    current.entries.each do |name, entry|
      bytes = File.read(File.join(part, name)).to_slice
      file_hash = CityHashV1.file_hash(bytes)
      if entry.compressed
        raw = bytes.empty? ? Bytes.empty : CompressedBlock.decode_all(bytes)
        records << ChecksumRecord.new(
          name,
          bytes.size.to_u64,
          file_hash,
          true,
          raw.size.to_u64,
          CityHashV1.file_hash(raw),
        )
      else
        records << ChecksumRecord.new(name, bytes.size.to_u64, file_hash, false)
      end
    end
    PartChecksumsWriter.write(part, records)
    nil
  end

  # Exercise the writer's pure child-target preflight with synthetic path
  # strings. No filesystem call is made, so the reader-cap boundary remains
  # testable even when the host OS has a shorter path limit.
  def self.w256_prepare_projection_at_target(parent_target : String, projection : WidePartProjection) : Nil
    context = WidePartOperationContext.new(
      2,
      BinaryBulkProfile.single_stream,
      BinaryBulkProfile.single_stream,
      ObjectDocumentCodec::DEFAULT_MODE,
      4096,
      0_i64,
      BinaryBulkCodec::DEFAULT_LIMITS,
      CompressedStreamLimits.new,
    )
    WidePartPreparedProjection.prepare(parent_target, projection, context)
    nil
  end
end

private def w256_replace_serialization(part : String, serialization : JSON::Any) : Nil
  File.write(File.join(part, "serialization.json"), serialization.to_json)
  CrystalClick::WidePartWriter.w256_refresh_checksums(part)
end

private def w256_replace_substreams(part : String, substreams : String) : Nil
  File.write(File.join(part, "columns_substreams.txt"), substreams)
  CrystalClick::WidePartWriter.w256_refresh_checksums(part)
end

private def w256_assert_array_values(part : String) : Nil
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["id", "items"])
  items = [] of Array(UInt16)
  table.scan_typed do |batch|
    items.concat(batch.array_numeric_values("items", UInt16))
  end
  items.should eq(ProjectionPublicationW256Fixture::ITEMS)
end

private def w256_expect_substreams_rejected(part : String, root : String, duplicate : Bool = false) : Nil
  callback_count = 0
  if duplicate
    expect_raises(CrystalClick::UnsupportedFormatError, "duplicate physical stream name") do
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["id", "items"])
      table.scan_typed do |_batch|
        callback_count += 1
      end
    end
  else
    expect_raises(
      CrystalClick::UnsupportedFormatError,
      "selected physical substreams do not match exact serialization shape"
    ) do
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["id", "items"])
      table.scan_typed do |_batch|
        callback_count += 1
      end
    end
  end
  callback_count.should eq(0)
  Dir.children(root).sort.should eq([File.basename(part)])
end

private def w256_expect_array_metadata_rejected(part : String, root : String) : Nil
  callback_count = 0
  expect_raises(CrystalClick::UnsupportedFormatError) do
    table = CrystalClick::WidePartTable.open_selected_typed([part], ["id", "items"])
    table.scan_typed do |batch|
      callback_count += 1
      batch.array_numeric_values("items", UInt16)
    end
  end
  callback_count.should eq(0)
  Dir.children(root).sort.should eq([File.basename(part)])
end

private def w256_projection_declarations : Array(CrystalClick::OfflineProjection)
  [
    CrystalClick::OfflineProjection.new(
      ProjectionPublicationW256Fixture::PROJECTION_NAME,
      "SELECT score, id, label, items ORDER BY score",
    ),
    CrystalClick::OfflineProjection.new(
      ProjectionPublicationW256Fixture::BUCKET_PROJECTION,
      "SELECT id % 3 AS bucket, arraySort(groupArray(toUInt16(id))) AS members GROUP BY bucket ORDER BY bucket",
    ),
  ] of CrystalClick::OfflineProjection
end

private def w256_static_u64_column(name : String, values : Array(UInt64)) : CrystalClick::WidePartColumn
  grouped = [] of Array(CrystalClick::BinaryValue)
  values.each_slice(2) do |mark|
    grouped << mark.map { |value| CrystalClick::BinaryValue.uint64(value) }
  end
  CrystalClick::WidePartColumn.binary_bulk(
    name,
    CrystalClick::BinaryDataType.primitive("UInt64"),
    grouped,
  )
end

private def w256_synthetic_parent_target(entry_name : String, final_child_path_bytes : Int32) : String
  parent_bytes = final_child_path_bytes - entry_name.bytesize - 1
  raise ArgumentError.new("synthetic child target size is too small") if parent_bytes <= 0
  String.new(Bytes.new(parent_bytes) do |index|
    index == 0 ? '/'.ord.to_u8 : 'p'.ord.to_u8
  end)
end

private def w256_small_projection(
  name : String,
  key_name : String,
  keys : Array(UInt64),
  value_name : String,
  values : Array(UInt64),
) : CrystalClick::WidePartProjection
  retained_keys = keys.dup
  CrystalClick::WidePartProjection.precomputed(
    name,
    key_name,
    retained_keys.to_unsafe.to_slice(retained_keys.size),
    [w256_static_u64_column(value_name, values)] of CrystalClick::WidePartColumn,
    rows_per_mark: 2,
  )
end

describe "W256 caller-owned Wide projection publication" do
  it "publishes checksummed children and reads independent child grids through direct and offline consumers" do
    ["single", "sized"].each do |profile_name|
      root = File.tempname("crystal-click-projection-publication-w256-")
      Dir.mkdir(root)
      begin
        part = File.join(root, "all_1_1_0")
        projections = [
          ProjectionPublicationW256Fixture.by_score_projection,
          ProjectionPublicationW256Fixture.by_bucket_projection,
        ] of CrystalClick::WidePartProjection
        ProjectionPublicationW256Fixture.write_parent(part, profile_name, projections).should eq(part)

        checksums = CrystalClick::PartChecksums.open(part)
        ["by_score.proj", "by_bucket.proj"].each do |entry_name|
          child_path = File.join(part, entry_name)
          Dir.exists?(child_path).should be_true
          child_checksums = CrystalClick::PartChecksums.open(child_path)
          summary = checksums.entry(entry_name).not_nil!
          child_physical_bytes = 0_u64
          child_checksums.entries.each_value { |entry| child_physical_bytes += entry.physical_size }
          summary.physical_size.should eq(child_physical_bytes)
        end
        bucket_child = File.join(part, "by_bucket.proj")
        Dir.exists?(bucket_child).should be_true
        checksums.entry("by_bucket.proj").should_not be_nil

        parent_expected = ProjectionPublicationW256Fixture.parent_rows
        parent_table = CrystalClick::WidePartTable.open_selected_typed(
          [part],
          ["id", "score", "label", "items"],
        )
        parent_table.column_types.should eq([
          {"id", "UInt64"},
          {"score", "UInt64"},
          {"label", "String"},
          {"items", "Array(UInt16)"},
        ])
        parent_table.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64]])
        parent_table.total_row_count.should eq(6_u64)

        parent_ids = [] of UInt64
        parent_scores = [] of UInt64
        parent_labels = [] of String
        parent_items = [] of Array(UInt16)
        parent_table.scan_typed do |batch|
          parent_ids.concat(batch.values_for("id", UInt64))
          parent_scores.concat(batch.values_for("score", UInt64))
          parent_labels.concat(batch.strings_for("label"))
          parent_items.concat(batch.array_numeric_values("items", UInt16))
        end
        parent_ids.should eq(parent_expected[:ids])
        parent_scores.should eq(ProjectionPublicationW256Fixture::SCORES)
        parent_labels.should eq(ProjectionPublicationW256Fixture::LABELS)
        parent_items.should eq(ProjectionPublicationW256Fixture::ITEMS)

        score_expected = ProjectionPublicationW256Fixture.by_score_rows
        score_table = CrystalClick::WidePartTable.open_selected_projection_typed(
          [part],
          ProjectionPublicationW256Fixture::PROJECTION_NAME,
          ["score", "id", "label", "items"],
        )
        score_table.column_types.should eq([
          {"score", "UInt64"},
          {"id", "UInt64"},
          {"label", "String"},
          {"items", "Array(UInt16)"},
        ])
        score_table.part_mark_row_counts.should eq([[3_u64, 3_u64]])
        score_table.total_row_count.should eq(6_u64)

        score_keys = [] of UInt64
        score_ids = [] of UInt64
        score_labels = [] of String
        score_items = [] of Array(UInt16)
        score_table.scan_typed do |batch|
          score_keys.concat(batch.values_for("score", UInt64))
          score_ids.concat(batch.values_for("id", UInt64))
          score_labels.concat(batch.strings_for("label"))
          score_items.concat(batch.array_numeric_values("items", UInt16))
        end
        score_keys.should eq(score_expected[:keys])
        score_ids.should eq(ProjectionPublicationW256Fixture::BY_SCORE_IDS)
        score_labels.should eq(ProjectionPublicationW256Fixture::BY_SCORE_LABELS)
        score_items.should eq(ProjectionPublicationW256Fixture::BY_SCORE_ITEMS)

        bucket_table = CrystalClick::WidePartTable.open_selected_projection_typed(
          [part],
          ProjectionPublicationW256Fixture::BUCKET_PROJECTION,
          ["bucket", "members"],
        )
        bucket_table.column_types.should eq([
          {"bucket", "UInt64"},
          {"members", "Array(UInt16)"},
        ])
        bucket_table.part_mark_row_counts.should eq([[2_u64, 1_u64]])
        bucket_table.total_row_count.should eq(3_u64)
        bucket_keys = [] of UInt64
        bucket_members = [] of Array(UInt16)
        bucket_table.scan_typed do |batch|
          bucket_keys.concat(batch.values_for("bucket", UInt64))
          bucket_members.concat(batch.array_numeric_values("members", UInt16))
        end
        bucket_keys.should eq(ProjectionPublicationW256Fixture::BUCKET_KEYS)
        bucket_members.should eq(ProjectionPublicationW256Fixture::BUCKET_MEMBERS)

        offline = w256_offline_table(part, w256_projection_declarations)
        offline_scores = [] of UInt64
        offline_ids = [] of UInt64
        offline_labels = [] of String
        offline_items = [] of Array(UInt16)
        offline.scan_projection_typed(
          ProjectionPublicationW256Fixture::PROJECTION_NAME,
          ["score", "id", "label", "items"],
        ) do |batch|
          offline_scores.concat(batch.values_for("score", UInt64))
          offline_ids.concat(batch.values_for("id", UInt64))
          offline_labels.concat(batch.strings_for("label"))
          offline_items.concat(batch.array_numeric_values("items", UInt16))
        end
        offline_scores.should eq(score_expected[:keys])
        offline_ids.should eq(ProjectionPublicationW256Fixture::BY_SCORE_IDS)
        offline_labels.should eq(ProjectionPublicationW256Fixture::BY_SCORE_LABELS)
        offline_items.should eq(ProjectionPublicationW256Fixture::BY_SCORE_ITEMS)

        window_ids = [] of UInt64
        window_offsets = [] of UInt64
        window_marks = [] of Int32
        window_mark_offsets = [] of UInt64
        window_batch_sizes = [] of Int32
        offline.scan_projection_typed_window(
          ProjectionPublicationW256Fixture::PROJECTION_NAME,
          ["score", "id", "label", "items"],
          2_u64,
          2,
        ) do |batch|
          window_offsets << batch.source_row_offset
          window_marks << batch.mark_index
          window_mark_offsets << batch.mark_row_offset
          batch_ids = batch.values_for("id", UInt64)
          window_batch_sizes << batch_ids.size.to_i32
          window_ids.concat(batch_ids)
        end
        window_offsets.should eq([2_u64, 3_u64])
        window_marks.should eq([0, 1])
        window_mark_offsets.should eq([2_u64, 0_u64])
        window_batch_sizes.should eq([1, 1])
        window_ids.should eq(ProjectionPublicationW256Fixture::BY_SCORE_IDS[2, 2])

        bucket_offline = [] of Array(UInt16)
        offline.scan_projection_typed(
          ProjectionPublicationW256Fixture::BUCKET_PROJECTION,
          ["bucket", "members"],
        ) do |batch|
          bucket_offline.concat(batch.array_numeric_values("members", UInt16))
        end
        bucket_offline.should eq(ProjectionPublicationW256Fixture::BUCKET_MEMBERS)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "preserves the default no-projection write and detaches projection factory inputs" do
    root = File.tempname("crystal-click-projection-publication-w256-owner-")
    Dir.mkdir(root)
    begin
      baseline = File.join(root, "baseline")
      ProjectionPublicationW256Fixture.write_parent(baseline).should eq(baseline)
      Dir.exists?(File.join(baseline, "by_score.proj")).should be_false
      CrystalClick::PartChecksums.open(baseline).entry("by_score.proj").should be_nil

      retained_keys = ProjectionPublicationW256Fixture::BY_SCORE_KEYS.dup
      retained_columns = ProjectionPublicationW256Fixture.by_score_columns
      projection = CrystalClick::WidePartProjection.precomputed(
        ProjectionPublicationW256Fixture::PROJECTION_NAME,
        ProjectionPublicationW256Fixture::SCORE_NAME,
        retained_keys.to_unsafe.to_slice(retained_keys.size),
        retained_columns,
        rows_per_mark: 3,
      )
      retained_keys[0] = 999_u64
      retained_columns.clear

      returned_keys = projection.keys
      returned_keys[0] = 888_u64
      returned_columns = projection.columns
      returned_columns.clear
      returned_name = projection.name
      expect_raises(Exception) { returned_name.to_slice[0] = 'X'.ord.to_u8 }
      returned_key_name = projection.key_name
      expect_raises(Exception) { returned_key_name.to_slice[0] = 'X'.ord.to_u8 }
      projection.name.should eq(ProjectionPublicationW256Fixture::PROJECTION_NAME)
      projection.key_name.should eq(ProjectionPublicationW256Fixture::SCORE_NAME)
      projection.keys.should eq(ProjectionPublicationW256Fixture::BY_SCORE_KEYS)
      projection.columns.size.should eq(3)

      part = File.join(root, "all_1_1_0")
      ProjectionPublicationW256Fixture.write_parent(part, "single", [projection] of CrystalClick::WidePartProjection)
      child = CrystalClick::WidePartTable.open_selected_projection_typed(
        [part], ProjectionPublicationW256Fixture::PROJECTION_NAME, ["score", "id"]
      )
      keys = [] of UInt64
      ids = [] of UInt64
      child.scan_typed do |batch|
        keys.concat(batch.values_for("score", UInt64))
        ids.concat(batch.values_for("id", UInt64))
      end
      keys.should eq(ProjectionPublicationW256Fixture::BY_SCORE_KEYS)
      ids.should eq(ProjectionPublicationW256Fixture::BY_SCORE_IDS)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects invalid child rosters and leaves no destination or staging tree" do
    root = File.tempname("crystal-click-projection-publication-w256-invalid-")
    Dir.mkdir(root)
    begin
      keys = ProjectionPublicationW256Fixture::BY_SCORE_KEYS.dup
      columns = ProjectionPublicationW256Fixture.by_score_columns
      projection_name_limit = CrystalClick::WidePartTable::MAX_PART_NAME_BYTES - ".proj".bytesize
      max_projection_name = String.new(Bytes.new(projection_name_limit) { |_index| 'p'.ord.to_u8 })
      max_key_name = String.new(Bytes.new(CrystalClick::WidePartWriter::MAX_COLUMN_NAME_BYTES) { |_index| 'k'.ord.to_u8 })
      bounded_name = CrystalClick::WidePartProjection.precomputed(
        max_projection_name,
        max_key_name,
        keys.to_unsafe.to_slice(keys.size),
        columns,
        rows_per_mark: 3,
      )
      bounded_name.name.should eq(max_projection_name)
      bounded_name.key_name.should eq(max_key_name)

      invalid_projection_names = [
        "",
        ".",
        "..",
        "../escape",
        "nested.name",
        "nested/name",
        "has\\slash",
        String.new(Bytes[0x78_u8, 0x00_u8]),
        "café",
        String.new(Bytes.new(projection_name_limit + 1) { |_index| 'p'.ord.to_u8 }),
      ]
      invalid_projection_names.each do |name|
        expect_raises(ArgumentError) do
          CrystalClick::WidePartProjection.precomputed(
            name,
            "score",
            keys.to_unsafe.to_slice(keys.size),
            columns,
            rows_per_mark: 3,
          )
        end
      end

      invalid_key_names = [
        "",
        ".",
        "..",
        "key/name",
        String.new(Bytes[0x6b_u8, 0x00_u8]),
        "clée",
        String.new(Bytes.new(CrystalClick::WidePartWriter::MAX_COLUMN_NAME_BYTES + 1) { |_index| 'k'.ord.to_u8 }),
      ]
      invalid_key_names.each do |key_name|
        expect_raises(ArgumentError) do
          CrystalClick::WidePartProjection.precomputed(
            "safe_projection",
            key_name,
            keys.to_unsafe.to_slice(keys.size),
            columns,
            rows_per_mark: 3,
          )
        end
      end
      Dir.children(root).should be_empty

      invalid_name = expect_raises(ArgumentError) do
        CrystalClick::WidePartProjection.precomputed(
          "../escape",
          "score",
          keys.to_unsafe.to_slice(keys.size),
          ProjectionPublicationW256Fixture.by_score_columns,
          rows_per_mark: 3,
        )
      end
      invalid_name.message.not_nil!.should contain("projection")

      duplicate_destination = File.join(root, "duplicate")
      projection = ProjectionPublicationW256Fixture.by_score_projection
      duplicate = expect_raises(ArgumentError) do
        ProjectionPublicationW256Fixture.write_parent(
          duplicate_destination,
          "single",
          [projection, projection] of CrystalClick::WidePartProjection,
        )
      end
      duplicate.message.not_nil!.should contain("projection")
      File.exists?(duplicate_destination).should be_false
      Dir.children(root).should be_empty

      too_many_destination = File.join(root, "too_many")
      same_projection = ProjectionPublicationW256Fixture.by_score_projection
      too_many = Array(CrystalClick::WidePartProjection).new(
        CrystalClick::WidePartWriter::MAX_PROJECTIONS + 1,
        same_projection,
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        ProjectionPublicationW256Fixture.write_parent(
          too_many_destination,
          "single",
          too_many,
        )
      end
      File.exists?(too_many_destination).should be_false
      Dir.children(root).should be_empty

      bad_rows = ProjectionPublicationW256Fixture::BY_SCORE_IDS[0, 5].map do |value|
        CrystalClick::BinaryValue.uint64(value)
      end
      bad_column = ProjectionPublicationW256Fixture.binary_column(
        "id",
        ProjectionPublicationW256Fixture.uint64_type,
        bad_rows,
        3,
      )
      bad_keys = ProjectionPublicationW256Fixture::BY_SCORE_KEYS.dup
      malformed_projection = CrystalClick::WidePartProjection.precomputed(
        "bad_rows",
        "score",
        bad_keys.to_unsafe.to_slice(bad_keys.size),
        [bad_column] of CrystalClick::WidePartColumn,
        rows_per_mark: 3,
      )
      malformed_destination = File.join(root, "bad_rows")
      expect_raises(ArgumentError) do
        ProjectionPublicationW256Fixture.write_parent(
          malformed_destination,
          "single",
          [malformed_projection] of CrystalClick::WidePartProjection,
        )
      end
      File.exists?(malformed_destination).should be_false
      Dir.children(root).should be_empty

      unsorted_keys = ProjectionPublicationW256Fixture::BY_SCORE_KEYS.dup
      first_key = unsorted_keys[0]
      unsorted_keys[0] = unsorted_keys[1]
      unsorted_keys[1] = first_key
      unsorted_projection = CrystalClick::WidePartProjection.precomputed(
        "bad_key_order",
        "score",
        unsorted_keys.to_unsafe.to_slice(unsorted_keys.size),
        ProjectionPublicationW256Fixture.by_score_columns,
        rows_per_mark: 3,
      )
      unsorted_destination = File.join(root, "bad_key_order")
      expect_raises(ArgumentError) do
        ProjectionPublicationW256Fixture.write_parent(
          unsorted_destination,
          "single",
          [unsorted_projection] of CrystalClick::WidePartProjection,
        )
      end
      File.exists?(unsorted_destination).should be_false
      Dir.children(root).should be_empty

      wrong_grid_projection = CrystalClick::WidePartProjection.precomputed(
        "bad_grid",
        "score",
        ProjectionPublicationW256Fixture::BY_SCORE_KEYS.to_unsafe.to_slice(6),
        ProjectionPublicationW256Fixture.by_score_columns(2),
        rows_per_mark: 3,
      )
      wrong_grid_destination = File.join(root, "bad_grid")
      expect_raises(ArgumentError) do
        ProjectionPublicationW256Fixture.write_parent(
          wrong_grid_destination,
          "single",
          [wrong_grid_projection] of CrystalClick::WidePartProjection,
        )
      end
      File.exists?(wrong_grid_destination).should be_false
      Dir.children(root).should be_empty

      conflict = File.join(root, "existing")
      Dir.mkdir(conflict)
      sentinel = File.join(conflict, "preserve.txt")
      File.write(sentinel, "caller-owned")
      expect_raises(ArgumentError) do
        ProjectionPublicationW256Fixture.write_parent(conflict)
      end
      File.read(sentinel).should eq("caller-owned")
      Dir.children(root).sort.should eq(["existing"])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects a symlink destination without modifying its caller-owned directory" do
    root = File.tempname("crystal-click-projection-publication-w256-symlink-")
    Dir.mkdir(root)
    begin
      caller_directory = File.join(root, "caller-owned")
      Dir.mkdir(caller_directory)
      sentinel = File.join(caller_directory, "preserve.txt")
      File.write(sentinel, "caller-owned")
      destination = File.join(root, "linked-destination")
      File.symlink(caller_directory, destination)

      expect_raises(ArgumentError) do
        ProjectionPublicationW256Fixture.write_parent(destination)
      end
      File.symlink?(destination).should be_true
      File.read(sentinel).should eq("caller-owned")
      Dir.children(caller_directory).should eq(["preserve.txt"])
      Dir.children(root).sort.should eq(["caller-owned", "linked-destination"])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "preflights the eventual child path at the reader's exact path-byte boundary" do
    projection = ProjectionPublicationW256Fixture.by_score_projection
    entry_name = "#{projection.name}.proj"
    path_limit = CrystalClick::WidePartTable::MAX_PART_PATH_BYTES

    exact_limit_parent = w256_synthetic_parent_target(entry_name, path_limit)
    CrystalClick::WidePartWriter.w256_prepare_projection_at_target(
      exact_limit_parent, projection
    ).should be_nil

    over_limit_parent = w256_synthetic_parent_target(entry_name, path_limit + 1)
    error = expect_raises(ArgumentError, "projection child path exceeds reader limit") do
      CrystalClick::WidePartWriter.w256_prepare_projection_at_target(
        over_limit_parent, projection
      )
    end
    error.message.not_nil!.should eq("projection child path exceeds reader limit")
  end

  it "shares staged read budgets across the parent and every child, cleaning failed publication" do
    root = File.tempname("crystal-click-projection-publication-w256-budget-")
    Dir.mkdir(root)
    begin
      keys = ProjectionPublicationW256Fixture::IDS.dup
      parent_column = w256_static_u64_column("score", ProjectionPublicationW256Fixture::SCORES)
      # One six-row key/value part accounts for 96 raw decoded bytes; parent
      # plus one child needs 192, and parent plus two children needs 288.
      read_budget_160 = CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: 160)

      parent_only = File.join(root, "parent_only")
      CrystalClick::WidePartWriter.write_uint64_columns(
        parent_only,
        "id",
        keys.to_unsafe.to_slice(keys.size),
        [parent_column] of CrystalClick::WidePartColumn,
        rows_per_mark: 2,
        transport_limits: read_budget_160,
      ).should eq(parent_only)

      by_score = w256_small_projection(
        "by_score",
        "score",
        ProjectionPublicationW256Fixture::BY_SCORE_KEYS,
        "id",
        ProjectionPublicationW256Fixture::BY_SCORE_IDS,
      )
      failed_child = File.join(root, "one_child_over_budget")
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.write_uint64_columns(
          failed_child,
          "id",
          keys.to_unsafe.to_slice(keys.size),
          [parent_column] of CrystalClick::WidePartColumn,
          rows_per_mark: 2,
          transport_limits: read_budget_160,
          projections: [by_score] of CrystalClick::WidePartProjection,
        )
      end
      File.exists?(failed_child).should be_false
      Dir.children(root).sort.should eq(["parent_only"])

      read_budget_240 = CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: 240)
      one_child = File.join(root, "one_child_within_budget")
      CrystalClick::WidePartWriter.write_uint64_columns(
        one_child,
        "id",
        keys.to_unsafe.to_slice(keys.size),
        [parent_column] of CrystalClick::WidePartColumn,
        rows_per_mark: 2,
        transport_limits: read_budget_240,
        projections: [by_score] of CrystalClick::WidePartProjection,
      ).should eq(one_child)

      by_id = w256_small_projection(
        "by_id",
        "id",
        ProjectionPublicationW256Fixture::IDS,
        "score_copy",
        ProjectionPublicationW256Fixture::SCORES,
      )
      failed_children = File.join(root, "two_children_over_budget")
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.write_uint64_columns(
          failed_children,
          "id",
          keys.to_unsafe.to_slice(keys.size),
          [parent_column] of CrystalClick::WidePartColumn,
          rows_per_mark: 2,
          transport_limits: read_budget_240,
          projections: [by_score, by_id] of CrystalClick::WidePartProjection,
        )
      end
      File.exists?(failed_children).should be_false
      Dir.children(root).sort.should eq(["one_child_within_budget", "parent_only"])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "shares the write codec node budget across parent and child planning before staging" do
    root = File.tempname("crystal-click-projection-publication-w256-write-budget-")
    Dir.mkdir(root)
    begin
      keys = [1_u64]
      parent_column = w256_static_u64_column("score", [9_u64])
      # For one UInt64 column and one mark, the prepared type-name walk costs
      # one node; encoding costs one type-tree visit, two offsets plus one
      # root mark record, and one value visit: six nodes total. Preparing a
      # child charges its type name to the same write budget before parent
      # encoding, so the parent reaches node seven and fails before staging.
      write_limits = CrystalClick::BinaryCodecLimits.new(
        max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
        max_nodes: 6,
        max_elements: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_ELEMENTS,
        max_bytes: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_BYTES,
      )

      parent_only = File.join(root, "parent_only")
      CrystalClick::WidePartWriter.write_uint64_columns(
        parent_only,
        "id",
        keys.to_unsafe.to_slice(keys.size),
        [parent_column] of CrystalClick::WidePartColumn,
        rows_per_mark: 1,
        limits: write_limits,
      ).should eq(parent_only)

      child = w256_small_projection(
        "by_score", "score", [9_u64], "copy", [1_u64]
      )
      parent_with_child = File.join(root, "parent_with_child")
      error = expect_raises(
        CrystalClick::UnsupportedFormatError,
        "binary codec node limit exceeded"
      ) do
        CrystalClick::WidePartWriter.write_uint64_columns(
          parent_with_child,
          "id",
          keys.to_unsafe.to_slice(keys.size),
          [parent_column] of CrystalClick::WidePartColumn,
          rows_per_mark: 1,
          limits: write_limits,
          projections: [child] of CrystalClick::WidePartProjection,
        )
      end
      error.message.not_nil!.should eq("binary codec node limit exceeded")
      File.exists?(parent_with_child).should be_false
      Dir.children(root).sort.should eq(["parent_only"])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects unknown String versions, disabled propagation, and Sparse array stats before callbacks" do
    ["single", "sized"].each do |profile_name|
      root = File.tempname("crystal-click-projection-publication-w256-array-metadata-")
      Dir.mkdir(root)
      begin
        part = File.join(root, "all_1_1_0")
        ProjectionPublicationW256Fixture.write_parent(part, profile_name)
        original_text = File.read(File.join(part, "serialization.json"))
        original_files = Dir.children(part).sort

        unknown_string_version = JSON.parse(original_text)
        unknown_string_version["types_serialization_versions"].as_h["string"] = JSON::Any.new(2_i64)
        w256_replace_serialization(part, unknown_string_version)
        w256_expect_array_metadata_rejected(part, root)
        Dir.children(part).sort.should eq(original_files)

        disabled_propagation = JSON.parse(original_text)
        disabled_propagation.as_h["propagate_types_serialization_versions_to_nested_types"] = JSON::Any.new(false)
        w256_replace_serialization(part, disabled_propagation)
        w256_expect_array_metadata_rejected(part, root)
        Dir.children(part).sort.should eq(original_files)

        sparse_statistics = JSON.parse(original_text)
        sparse_statistics.as_h["columns"] = JSON::Any.new([
          JSON::Any.new({
            "kind"         => JSON::Any.new("Sparse"),
            "name"         => JSON::Any.new("id"),
            "num_defaults" => JSON::Any.new(0_i64),
            "num_rows"     => JSON::Any.new(6_i64),
          } of String => JSON::Any),
        ] of JSON::Any)
        w256_replace_serialization(part, sparse_statistics)
        w256_expect_array_metadata_rejected(part, root)
        Dir.children(part).sort.should eq(original_files)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "accepts canonical numeric-array substream order and rejects malformed rosters before callbacks" do
    normal_items_block = "2 substreams for column `items`:\n\titems\n\titems.size0\n"
    canonical_items_block = "2 substreams for column `items`:\n\titems.size0\n\titems\n"
    duplicate_items_block = "2 substreams for column `items`:\n\titems\n\titems\n"
    omitted_size_block = "1 substreams for column `items`:\n\titems\n"
    extra_stream_block = "3 substreams for column `items`:\n\titems\n\titems.size0\n\titems.unexpected\n"

    ["single", "sized"].each do |profile_name|
      root = File.tempname("crystal-click-projection-publication-w256-array-roster-")
      Dir.mkdir(root)
      begin
        part = File.join(root, "all_1_1_0")
        ProjectionPublicationW256Fixture.write_parent(part, profile_name)
        original = File.read(File.join(part, "columns_substreams.txt"))
        original.should contain(normal_items_block)

        canonical = original.sub(normal_items_block, canonical_items_block)
        w256_replace_substreams(part, canonical)
        w256_assert_array_values(part)

        duplicate = original.sub(normal_items_block, duplicate_items_block)
        w256_replace_substreams(part, duplicate)
        w256_expect_substreams_rejected(part, root, true)

        omitted_size = original.sub(normal_items_block, omitted_size_block)
        w256_replace_substreams(part, omitted_size)
        w256_expect_substreams_rejected(part, root)

        extra_stream = original.sub(normal_items_block, extra_stream_block)
        w256_replace_substreams(part, extra_stream)
        w256_expect_substreams_rejected(part, root)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end
end
