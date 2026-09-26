require "./spec_helper"

private def w17_reader_keys(size : Int) : Array(UInt64)
  Array(UInt64).new(size) { |index| index.to_u64 + 1_u64 }
end

private def w17_reader_catalog_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def w17_reader_create_catalog_table(
  root : String,
  database_uuid : String,
  table_name : String,
  table_uuid : String,
  column_type : String,
  part_path : String,
) : Nil
  database_path = w17_reader_catalog_path(root, database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "#{table_name}.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `payload` #{column_type}\n)\nENGINE = MergeTree\nORDER BY tuple()\n"
  )
  table_path = w17_reader_catalog_path(root, table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part_path, File.join(table_path, "all_1_1_0"))
end

private def w17_reader_with_catalog_root(&)
  root = File.tempname("crystal-click-w17-reader-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    database_uuid = "c17e7af8-f57c-42b8-bcb0-863f3de0ca51"
    FileUtils.mkdir_p(w17_reader_catalog_path(root, database_uuid))
    File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
    yield root, database_uuid
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::WidePart do
  it "admits only the exact UUID and BASIC Nullable(UUID) declarations" do
    ["UUID", "Nullable(UUID)"].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end

    [
      "Uuid",
      "UUID(1)",
      "Nullable(Nullable(UUID))",
      "Nullable(UUID, UUID)",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "formats UUID halves as canonical lowercase hyphenated text" do
    CrystalClick::UUIDValue.new(0x0011223344556677_u64, 0x8899aabbccddeeff_u64).to_s
      .should eq("00112233-4455-6677-8899-aabbccddeeff")
    CrystalClick::UUIDValue.new(0x123456789abcdef0_u64, 0x0fedcba987654321_u64).to_s
      .should eq("12345678-9abc-def0-0fed-cba987654321")
  end

  it "requires the pinned String serialization metadata for bare and Nullable UUID" do
    parent = File.tempname("crystal-click-w17-reader-serialization")
    Dir.mkdir(parent)
    keys = w17_reader_keys(1)
    bare_values = [CrystalClick::UUIDValue.new(0x0011223344556677_u64, 0x8899aabbccddeeff_u64)]
    nullable_values = [nil.as(CrystalClick::UUIDValue?)]

    begin
      bare_part = File.join(parent, "bare")
      CrystalClick::WidePartWriter.write_uint64_uuid_pair(
        bare_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        bare_values.to_unsafe.to_slice(bare_values.size), 1
      )
      bare_metadata_path = File.join(bare_part, "serialization.json")
      bare_metadata = File.read(bare_metadata_path)
      bare_metadata.should contain(%("string":1))

      File.delete(bare_metadata_path)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(bare_part, "payload")
      end
      File.write(bare_metadata_path, bare_metadata.sub(%("string":1), %("string":0)))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(bare_part, "payload")
      end
      File.write(bare_metadata_path, bare_metadata.sub(%("columns":[]), %("columns":[{"name":"payload"}])))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(bare_part, "payload")
      end
      File.write(bare_metadata_path, bare_metadata.sub(%("columns":[]), %("columns":[],"missing_columns":[])))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(bare_part, "payload")
      end
      File.write(bare_metadata_path, "{")
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(bare_part, "payload")
      end

      nullable_part = File.join(parent, "nullable")
      CrystalClick::WidePartWriter.write_uint64_nullable_uuid_pair(
        nullable_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        nullable_values.to_unsafe.to_slice(nullable_values.size), 1
      )
      nullable_metadata_path = File.join(nullable_part, "serialization.json")
      nullable_metadata = File.read(nullable_metadata_path)
      nullable_metadata.should contain(%("string":1))

      File.delete(nullable_metadata_path)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(nullable_part, "payload")
      end
      File.write(nullable_metadata_path, nullable_metadata.sub(%("string":1), %("string":0)))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(nullable_part, "payload")
      end
      File.write(nullable_metadata_path, nullable_metadata.sub(%("string":1), %("nullable":0,"string":1)))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(nullable_part, "payload")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "reads UUID values across marks, batches, and the offline catalog without primitive aliases" do
    parent = File.tempname("crystal-click-w17-reader-uuid")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    keys = w17_reader_keys(5)
    values = [
      CrystalClick::UUIDValue.new(0_u64, 0_u64),
      CrystalClick::UUIDValue.new(0x61f0c4045cb311e7_u64, 0x907ba6006ad3dba0_u64),
      CrystalClick::UUIDValue.new(UInt64::MAX, UInt64::MAX),
      CrystalClick::UUIDValue.new(0x0123456789abcdef_u64, 0xfedcba9876543210_u64),
      CrystalClick::UUIDValue.new(0x1020304050607080_u64, 0x90a0b0c0d0e0f001_u64),
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_uuid_pair(
        part_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), 2
      )
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      reader.column_type.should eq("UUID")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_uuids_mark_range("payload", 0, 2).should eq(values[0, 4])
      reader.read_uuids_mark_range("payload", 2, 1).should eq([values[4]])
      expect_raises(CrystalClick::BoundsError) do
        reader.read_uuids_mark_range("payload", 0, 0)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_numeric_mark_range("payload", 0, 1, UInt64)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_numeric_mark_range("payload", 0, 1, UInt128)
      end

      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
      observed = [] of CrystalClick::UUIDValue
      batches = [] of Int32
      table.scan_typed(batch_rows: 3) do |batch|
        observed.concat(batch.uuids_for("payload"))
        batches << batch.uuids_for("payload").size.to_i32
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.values_for("payload", UInt64)
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.values_for("payload", UInt128)
        end
      end
      observed.should eq(values)
      batches.should eq([2_i32, 2_i32, 1_i32])

      w17_reader_with_catalog_root do |root, database_uuid|
        w17_reader_create_catalog_table(
          root, database_uuid, "bare", "c17e7af8-f57c-42b8-bcb0-863f3de0ca52", "UUID", part_path
        )
        catalog = CrystalClick::OfflineCatalog.open(root)
        catalog.table("lab", "bare").materialize_selected_values("payload")
          .map(&.as(CrystalClick::UUIDValue)).should eq(values)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps Nullable(UUID) NULL distinct from zero in reader, batch, and catalog values" do
    parent = File.tempname("crystal-click-w17-reader-nullable-uuid")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    keys = w17_reader_keys(5)
    zero = CrystalClick::UUIDValue.new(0_u64, 0_u64)
    asymmetric = CrystalClick::UUIDValue.new(0x61f0c4045cb311e7_u64, 0x907ba6006ad3dba0_u64)
    values = [
      nil.as(CrystalClick::UUIDValue?),
      zero.as(CrystalClick::UUIDValue?),
      asymmetric.as(CrystalClick::UUIDValue?),
      nil.as(CrystalClick::UUIDValue?),
      CrystalClick::UUIDValue.new(UInt64::MAX, UInt64::MAX).as(CrystalClick::UUIDValue?),
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_uuid_pair(
        part_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), 2
      )
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      reader.column_type.should eq("Nullable(UUID)")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_nullable_uuids_mark_range("payload", 0, reader.mark_count).should eq(values)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_numeric_mark_range("payload", 0, 1, UInt64)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_numeric_mark_range("payload", 0, 1, UInt128)
      end

      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
      observed = [] of CrystalClick::UUIDValue?
      table.scan_typed(batch_rows: 3) do |batch|
        observed.concat(batch.nullable_uuids_for("payload"))
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.nullable_values_for("payload", UInt64)
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.nullable_values_for("payload", UInt128)
        end
      end
      observed.should eq(values)
      observed[0].should be_nil
      observed[1].should eq(zero)
      observed[0].should_not eq(observed[1])

      w17_reader_with_catalog_root do |root, database_uuid|
        w17_reader_create_catalog_table(
          root, database_uuid, "nullable", "c17e7af8-f57c-42b8-bcb0-863f3de0ca53", "Nullable(UUID)", part_path
        )
        catalog = CrystalClick::OfflineCatalog.open(root)
        catalog.table("lab", "nullable").materialize_selected_values("payload")
          .map(&.as(CrystalClick::UUIDValue?)).should eq(values)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a truncated UUID payload and nullable null-map stream" do
    parent = File.tempname("crystal-click-w17-reader-truncated")
    Dir.mkdir(parent)
    values = [CrystalClick::UUIDValue.new(0x0011223344556677_u64, 0x8899aabbccddeeff_u64)]
    nullable = [nil.as(CrystalClick::UUIDValue?)]
    bare_path = File.join(parent, "bare")
    nullable_path = File.join(parent, "nullable")

    begin
      CrystalClick::WidePartWriter.write_uint64_uuid_pair(
        bare_path, "pk", [1_u64].to_unsafe.to_slice(1), "payload",
        values.to_unsafe.to_slice(values.size), 1
      )
      bare_data_path = File.join(bare_path, "#{CrystalClick::StreamName.hash("payload")}.bin")
      bare_data = File.read(bare_data_path)
      File.write(bare_data_path, bare_data.byte_slice(0, bare_data.bytesize - 1))
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(bare_path, "payload")
      end

      CrystalClick::WidePartWriter.write_uint64_nullable_uuid_pair(
        nullable_path, "pk", [1_u64].to_unsafe.to_slice(1), "payload",
        nullable.to_unsafe.to_slice(nullable.size), 1
      )
      null_data_path = File.join(nullable_path, "#{CrystalClick::StreamName.hash("payload.null")}.bin")
      null_data = File.read(null_data_path)
      File.write(null_data_path, null_data.byte_slice(0, null_data.bytesize - 1))
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(nullable_path, "payload")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "requires pinned UUID serialization metadata for both shapes" do
    parent = File.tempname("crystal-click-w17-reader-serialization")
    Dir.mkdir(parent)
    keys = [1_u64]
    value = CrystalClick::UUIDValue.new(0x0011223344556677_u64, 0x8899aabbccddeeff_u64)
    bare = [value]
    nullable = [value.as(CrystalClick::UUIDValue?)]
    bare_path = File.join(parent, "bare")
    nullable_path = File.join(parent, "nullable")

    begin
      CrystalClick::WidePartWriter.write_uint64_uuid_pair(
        bare_path, "pk", keys.to_unsafe.to_slice(1), "payload", bare.to_unsafe.to_slice(1), 1
      )
      File.delete(File.join(bare_path, "serialization.json"))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(bare_path, "payload")
      end

      CrystalClick::WidePartWriter.write_uint64_nullable_uuid_pair(
        nullable_path, "pk", keys.to_unsafe.to_slice(1), "payload", nullable.to_unsafe.to_slice(1), 1
      )
      serialization_path = File.join(nullable_path, "serialization.json")
      File.write(serialization_path, %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":2},"version":1}))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(nullable_path, "payload")
      end
      File.write(serialization_path, "{")
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(nullable_path, "payload")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
