require "./spec_helper"
require "file_utils"
require "./support/projection_publication_w256_fixture"

private def w287_id_projection(ids : Array(UInt64)) : CrystalClick::WidePartProjection
  keys = ProjectionPublicationW256Fixture::BY_SCORE_KEYS.dup
  values = ids.map { |id| CrystalClick::BinaryValue.uint64(id) }
  columns = [
    ProjectionPublicationW256Fixture.binary_column(
      "id",
      ProjectionPublicationW256Fixture.uint64_type,
      values,
      3,
    ),
  ] of CrystalClick::WidePartColumn
  CrystalClick::WidePartProjection.precomputed(
    ProjectionPublicationW256Fixture::PROJECTION_NAME,
    ProjectionPublicationW256Fixture::SCORE_NAME,
    keys.to_unsafe.to_slice(keys.size),
    columns,
    rows_per_mark: 3,
  )
end

private def w287_read_ids(parent : String) : Array(UInt64)
  table = CrystalClick::WidePartTable.open_selected_projection_typed(
    [parent],
    ProjectionPublicationW256Fixture::PROJECTION_NAME,
    [ProjectionPublicationW256Fixture::SCORE_NAME, ProjectionPublicationW256Fixture::KEY_NAME],
  )
  ids = [] of UInt64
  table.scan_typed do |batch|
    ids.concat(batch.values_for(ProjectionPublicationW256Fixture::KEY_NAME, UInt64))
  end
  ids
end

private def w287_offline_table(parts : Array(String)) : CrystalClick::OfflineTable
  part_names = ["all_1_1_0", "all_2_2_0"]
  candidates = [] of CrystalClick::OfflinePartCandidate
  parts.each_with_index do |path, index|
    name = part_names[index]
    info = CrystalClick::MergeTreePartInfo.parse(name).not_nil!
    candidates << CrystalClick::OfflinePartCandidate.new(name, path, info, 6_u64)
  end
  columns = [
    CrystalClick::OfflineColumn.new("id", "UInt64", false, true),
    CrystalClick::OfflineColumn.new("score", "UInt64"),
    CrystalClick::OfflineColumn.new("label", "String"),
    CrystalClick::OfflineColumn.new("items", "Array(UInt16)"),
  ] of CrystalClick::OfflineColumn
  projections = [
    CrystalClick::OfflineProjection.new(
      ProjectionPublicationW256Fixture::PROJECTION_NAME,
      "SELECT score, id ORDER BY score",
    ),
  ] of CrystalClick::OfflineProjection
  CrystalClick::OfflineTable.new(
    "events",
    "w287-projection-checksum-binding",
    "MergeTree",
    columns,
    candidates,
    primary_key_column: "id",
    projections: projections,
  )
end

private def w287_checksum_records(parent : String) : Array(CrystalClick::PartWriterInfrastructure::ChecksumRecord)
  records = [] of CrystalClick::PartWriterInfrastructure::ChecksumRecord
  CrystalClick::PartChecksums.open(parent).entries.each do |name, entry|
    records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(
      name,
      entry.physical_size,
      entry.file_hash,
      entry.compressed,
      entry.uncompressed_size,
      entry.uncompressed_hash,
    )
  end
  records
end

private def w287_write_checksums(
  parent : String,
  records : Array(CrystalClick::PartWriterInfrastructure::ChecksumRecord),
) : Nil
  CrystalClick::PartWriterInfrastructure::PartChecksumsWriter.write(parent, records)
end

private def w287_expect_selected_corruption(parent : String) : Nil
  callbacks = 0
  expect_raises(CrystalClick::CorruptPartError) do
    table = CrystalClick::WidePartTable.open_selected_projection_typed(
      [parent],
      ProjectionPublicationW256Fixture::PROJECTION_NAME,
      [ProjectionPublicationW256Fixture::SCORE_NAME, ProjectionPublicationW256Fixture::KEY_NAME],
    )
    table.scan_typed do |_batch|
      callbacks += 1
    end
  end
  callbacks.should eq(0)
end

private def w287_expect_selected_error(parent : String) : Nil
  callbacks = 0
  expect_raises(CrystalClick::Error) do
    table = CrystalClick::WidePartTable.open_selected_projection_typed(
      [parent],
      ProjectionPublicationW256Fixture::PROJECTION_NAME,
      [ProjectionPublicationW256Fixture::SCORE_NAME, ProjectionPublicationW256Fixture::KEY_NAME],
    )
    table.scan_typed do |_batch|
      callbacks += 1
    end
  end
  callbacks.should eq(0)
end

describe "W287 projection checksum binding on read" do
  it "keeps a valid binding readable through direct and full/window offline consumers" do
    root = File.tempname("crystal-click-w287-positive-")
    Dir.mkdir(root)
    begin
      part = File.join(root, "all_1_1_0")
      ids = ProjectionPublicationW256Fixture::BY_SCORE_IDS.dup
      projection = w287_id_projection(ids)
      ProjectionPublicationW256Fixture.write_parent(
        part,
        projections: [projection] of CrystalClick::WidePartProjection,
      )

      w287_read_ids(part).should eq(ids)

      offline = w287_offline_table([part])
      full = [] of UInt64
      offline.scan_projection_typed(
        ProjectionPublicationW256Fixture::PROJECTION_NAME,
        [ProjectionPublicationW256Fixture::SCORE_NAME, ProjectionPublicationW256Fixture::KEY_NAME],
      ) do |batch|
        full.concat(batch.values_for(ProjectionPublicationW256Fixture::KEY_NAME, UInt64))
      end
      full.should eq(ids)

      window = [] of UInt64
      offline.scan_projection_typed_window(
        ProjectionPublicationW256Fixture::PROJECTION_NAME,
        [ProjectionPublicationW256Fixture::SCORE_NAME, ProjectionPublicationW256Fixture::KEY_NAME],
        2_u64,
        2,
      ) do |batch|
        window.concat(batch.values_for(ProjectionPublicationW256Fixture::KEY_NAME, UInt64))
      end
      window.should eq(ids[2, 2])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects a same-size replacement child before exposing selected projection rows" do
    root = File.tempname("crystal-click-w287-replacement-")
    Dir.mkdir(root)
    begin
      original_root = File.join(root, "original")
      donor_root = File.join(root, "donor")
      Dir.mkdir(original_root)
      Dir.mkdir(donor_root)
      original = File.join(original_root, "all_1_1_0")
      donor = File.join(donor_root, "all_1_1_0")
      original_ids = ProjectionPublicationW256Fixture::BY_SCORE_IDS.dup
      donor_ids = original_ids.dup
      donor_ids[0] = 999_u64

      original_projection = w287_id_projection(original_ids)
      donor_projection = w287_id_projection(donor_ids)
      ProjectionPublicationW256Fixture.write_parent(
        original,
        projections: [original_projection] of CrystalClick::WidePartProjection,
      )
      ProjectionPublicationW256Fixture.write_parent(
        donor,
        projections: [donor_projection] of CrystalClick::WidePartProjection,
      )

      # Both complete children pass the normal typed reader before the attack.
      w287_read_ids(original).should eq(original_ids)
      w287_read_ids(donor).should eq(donor_ids)

      original_child = File.join(original, "by_score.proj")
      donor_child = File.join(donor, "by_score.proj")
      original_checksums = CrystalClick::PartChecksums.open(original_child)
      donor_checksums = CrystalClick::PartChecksums.open(donor_child)
      original_checksums.entries.keys.sort.should eq(donor_checksums.entries.keys.sort)
      original_checksums.entries.each do |name, entry|
        donor_entry = donor_checksums.entry(name).not_nil!
        entry.physical_size.should eq(donor_entry.physical_size)
        entry.compressed.should eq(donor_entry.compressed)
      end
      original_checksums.entries.any? do |name, entry|
        entry.file_hash != donor_checksums.entry(name).not_nil!.file_hash
      end.should be_true

      original_parent_summary = CrystalClick::PartChecksums.open(original).entry("by_score.proj").not_nil!
      donor_parent_summary = CrystalClick::PartChecksums.open(donor).entry("by_score.proj").not_nil!
      original_parent_summary.physical_size.should eq(donor_parent_summary.physical_size)
      original_parent_summary.file_hash.should_not eq(donor_parent_summary.file_hash)

      FileUtils.rm_rf(original_child)
      FileUtils.cp_r(donor_child, original)

      callbacks = 0
      expect_raises(
        CrystalClick::CorruptPartError,
        "selected projection child checksum does not match parent manifest",
      ) do
        table = CrystalClick::WidePartTable.open_selected_projection_typed(
          [original],
          ProjectionPublicationW256Fixture::PROJECTION_NAME,
          [ProjectionPublicationW256Fixture::SCORE_NAME, ProjectionPublicationW256Fixture::KEY_NAME],
        )
        table.scan_typed do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects missing, wrong-size, and compressed parent child summaries before callbacks" do
    ["missing", "wrong-size", "compressed"].each do |mutation|
      root = File.tempname("crystal-click-w287-parent-summary-")
      Dir.mkdir(root)
      begin
        part = File.join(root, "all_1_1_0")
        projection = w287_id_projection(ProjectionPublicationW256Fixture::BY_SCORE_IDS.dup)
        ProjectionPublicationW256Fixture.write_parent(
          part,
          projections: [projection] of CrystalClick::WidePartProjection,
        )
        summary = CrystalClick::PartChecksums.open(part).entry("by_score.proj").not_nil!
        records = w287_checksum_records(part)
        case mutation
        when "missing"
          records.reject! { |record| record.name == "by_score.proj" }
        when "wrong-size"
          records.map! do |record|
            if record.name == "by_score.proj"
              CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(
                record.name,
                record.physical_size + 1_u64,
                record.file_hash,
                false,
              )
            else
              record
            end
          end
        when "compressed"
          records.map! do |record|
            if record.name == "by_score.proj"
              CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(
                record.name,
                record.physical_size,
                record.file_hash,
                true,
                summary.physical_size,
                summary.file_hash,
              )
            else
              record
            end
          end
        end
        w287_write_checksums(part, records)
        w287_expect_selected_corruption(part)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "rejects symlinked and nonregular parent manifests plus a corrupt later child at EOF" do
    root = File.tempname("crystal-click-w287-parent-preflight-")
    Dir.mkdir(root)
    begin
      symlinked_root = File.join(root, "symlinked")
      Dir.mkdir(symlinked_root)
      symlinked = File.join(symlinked_root, "all_3_3_0")
      ProjectionPublicationW256Fixture.write_parent(
        symlinked,
        projections: [w287_id_projection(ProjectionPublicationW256Fixture::BY_SCORE_IDS.dup)] of CrystalClick::WidePartProjection,
      )
      manifest = File.join(symlinked, "checksums.txt")
      saved_manifest = File.join(root, "saved-checksums.txt")
      File.rename(manifest, saved_manifest)
      File.symlink(saved_manifest, manifest)
      w287_expect_selected_corruption(symlinked)
      FileUtils.rm_rf(manifest)
      Dir.mkdir(manifest)
      w287_expect_selected_error(symlinked)

      first = File.join(root, "all_1_1_0")
      late = File.join(root, "all_2_2_0")
      projection = w287_id_projection(ProjectionPublicationW256Fixture::BY_SCORE_IDS.dup)
      ProjectionPublicationW256Fixture.write_parent(first, projections: [projection] of CrystalClick::WidePartProjection)
      ProjectionPublicationW256Fixture.write_parent(late, projections: [projection] of CrystalClick::WidePartProjection)
      records = w287_checksum_records(late)
      records.reject! { |record| record.name == "by_score.proj" }
      w287_write_checksums(late, records)

      offline = w287_offline_table([first, late])
      full_callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        offline.scan_projection_typed(
          ProjectionPublicationW256Fixture::PROJECTION_NAME,
          [ProjectionPublicationW256Fixture::SCORE_NAME, ProjectionPublicationW256Fixture::KEY_NAME],
        ) do |_batch|
          full_callbacks += 1
        end
      end
      full_callbacks.should eq(0)

      eof_callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        offline.scan_projection_typed_window(
          ProjectionPublicationW256Fixture::PROJECTION_NAME,
          [ProjectionPublicationW256Fixture::SCORE_NAME, ProjectionPublicationW256Fixture::KEY_NAME],
          12_u64,
          1,
        ) do |_batch|
          eof_callbacks += 1
        end
      end
      eof_callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
