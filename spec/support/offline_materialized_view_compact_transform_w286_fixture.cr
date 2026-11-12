module CompactMaterializedViewTransformW286Fixture
  DATABASE_UUID = "f2860000-7b7f-4e2f-9e44-dc13a87b8801"
  SOURCE_UUID   = "f2860000-7b7f-4e2f-9e44-dc13a87b8802"
  TARGET_UUID   = "f2860000-7b7f-4e2f-9e44-dc13a87b8803"
  VIEW_UUID     = "f2860000-7b7f-4e2f-9e44-dc13a87b8804"

  def self.catalog(
    root : String,
    target_tail : String = "ORDER BY id SETTINGS index_granularity = 2, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0",
    compact_source : Bool = false,
    target_value_declaration : String = "String",
  ) : Tuple(CrystalClick::OfflineCatalog, String, String)
    FileUtils.mkdir_p(File.join(root, "metadata"))
    FileUtils.mkdir_p(File.join(root, "store"))
    File.write(
      File.join(root, "metadata", "lab.sql"),
      "ATTACH DATABASE _ UUID '#{DATABASE_UUID}'\nENGINE = Atomic\n"
    )
    database_path = store_path(root, DATABASE_UUID)
    FileUtils.mkdir_p(database_path)

    source_path = write_table(
      root,
      database_path,
      "source",
      SOURCE_UUID,
      "`k` UInt64, `v` String",
      "ORDER BY k SETTINGS index_granularity = 2",
    )
    target_path = write_table(
      root,
      database_path,
      "target",
      TARGET_UUID,
      "`id` UInt64, `value` #{target_value_declaration}, `label` String",
      target_tail,
    )
    File.write(
      File.join(database_path, "view.sql"),
      <<-DDL
      ATTACH MATERIALIZED VIEW _ UUID '#{VIEW_UUID}' TO lab.target
      (
        `id` UInt64,
        `value` #{target_value_declaration},
        `label` String
      )
      AS SELECT k, v, v FROM lab.source WHERE k > 1
      DDL
    )
    source_part = File.join(source_path, "all_1_1_0")
    if compact_source
      value_column = CrystalClick::CompactPartColumn.binary_bulk(
        "v",
        CrystalClick::BinaryDataType.primitive("String"),
        [
          [
            CrystalClick::BinaryValue.string("one"),
            CrystalClick::BinaryValue.string("two"),
          ] of CrystalClick::BinaryValue,
          [
            CrystalClick::BinaryValue.string("three"),
            CrystalClick::BinaryValue.string("four"),
          ] of CrystalClick::BinaryValue,
        ],
      )
      CrystalClick::CompactPartWriter.write_uint64_columns(
        source_part,
        "k",
        Slice[1_u64, 2_u64, 3_u64, 4_u64],
        [value_column] of CrystalClick::CompactPartColumn,
        rows_per_mark: 2,
        mark_format: CrystalClick::CompactMarkFormat::Mrk3,
      )
    else
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        source_part,
        "k",
        Slice[1_u64, 2_u64, 3_u64, 4_u64],
        "v",
        ["one", "two", "three", "four"].to_unsafe.to_slice(4),
      )
    end
    {CrystalClick::OfflineCatalog.open(root), database_path, target_path}
  end

  private def self.store_path(root : String, uuid : String) : String
    File.join(root, "store", uuid[0, 3], uuid)
  end

  private def self.write_table(
    root : String,
    database_path : String,
    name : String,
    uuid : String,
    columns : String,
    tail : String,
  ) : String
    File.write(
      File.join(database_path, "#{name}.sql"),
      "ATTACH TABLE _ UUID '#{uuid}'\n(\n  #{columns}\n)\nENGINE = MergeTree\n#{tail}\n"
    )
    path = store_path(root, uuid)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(path, "detached"))
    path
  end
end
