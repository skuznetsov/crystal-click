require "./spec_helper"

private def w18_reader_keys(size : Int) : Array(UInt64)
  Array(UInt64).new(size) { |index| index.to_u64 + 1_u64 }
end

private def w18_reader_catalog_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def w18_reader_create_catalog_table(
  root : String,
  database_uuid : String,
  table_name : String,
  table_uuid : String,
  column_type : String,
  part_path : String,
) : Nil
  database_path = w18_reader_catalog_path(root, database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "#{table_name}.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `payload` #{column_type}\n)\nENGINE = MergeTree\nORDER BY tuple()\n"
  )
  table_path = w18_reader_catalog_path(root, table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part_path, File.join(table_path, "all_1_1_0"))
end

private def w18_reader_with_catalog_root(&)
  root = File.tempname("crystal-click-w18-reader-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    database_uuid = "c18e7af8-f57c-42b8-bcb0-863f3de0ca51"
    FileUtils.mkdir_p(w18_reader_catalog_path(root, database_uuid))
    File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
    yield root, database_uuid
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::WidePart do
  it "admits only the exact IPv4 and BASIC Nullable(IPv4) declarations" do
    ["IPv4", "Nullable(IPv4)"].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end

    [
      "Ipv4",
      "IPv4(4)",
      "Nullable(Nullable(IPv4))",
      "Nullable(IPv4, IPv4)",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "stores network-order octets in a distinct four-byte IPv4 value" do
    sizeof(CrystalClick::IPv4Value).should eq(4)
    CrystalClick::IPv4Value.from_octets(1_u8, 2_u8, 3_u8, 4_u8).network_order
      .should eq(0x01020304_u32)
    CrystalClick::IPv4Value.from_octets(1_u8, 2_u8, 3_u8, 4_u8).to_s.should eq("1.2.3.4")
    CrystalClick::IPv4Value.from_octets(4_u8, 3_u8, 2_u8, 1_u8).to_s.should eq("4.3.2.1")
    CrystalClick::IPv4Value.from_octets(0_u8, 0_u8, 0_u8, 0_u8).to_s.should eq("0.0.0.0")
    CrystalClick::IPv4Value.from_octets(255_u8, 255_u8, 255_u8, 255_u8).to_s.should eq("255.255.255.255")
  end

  it "reads IPv4 across marks, table batches, and selected offline catalog materialization" do
    parent = File.tempname("crystal-click-w18-reader-ipv4")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    keys = w18_reader_keys(5)
    values = [
      CrystalClick::IPv4Value.from_octets(1_u8, 2_u8, 3_u8, 4_u8),
      CrystalClick::IPv4Value.from_octets(4_u8, 3_u8, 2_u8, 1_u8),
      CrystalClick::IPv4Value.from_octets(0_u8, 0_u8, 0_u8, 0_u8),
      CrystalClick::IPv4Value.from_octets(255_u8, 255_u8, 255_u8, 255_u8),
      CrystalClick::IPv4Value.from_octets(192_u8, 168_u8, 1_u8, 7_u8),
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_ipv4_pair(
        part_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), 2
      )
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      reader.column_type.should eq("IPv4")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_ipv4s_mark_range("payload", 0, 2).should eq(values[0, 4])
      reader.read_ipv4s_mark_range("payload", 2, 1).should eq([values[4]])
      expect_raises(CrystalClick::BoundsError) do
        reader.read_ipv4s_mark_range("payload", 0, 0)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_numeric_mark_range("payload", 0, 1, UInt32)
      end

      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
      observed = [] of CrystalClick::IPv4Value
      batches = [] of Int32
      table.scan_typed(batch_rows: 3) do |batch|
        observed.concat(batch.ipv4s_for("payload"))
        batches << batch.ipv4s_for("payload").size.to_i32
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.values_for("payload", UInt32)
        end
      end
      observed.should eq(values)
      batches.should eq([2_i32, 2_i32, 1_i32])

      w18_reader_with_catalog_root do |root, database_uuid|
        w18_reader_create_catalog_table(
          root, database_uuid, "bare", "c18e7af8-f57c-42b8-bcb0-863f3de0ca52", "IPv4", part_path
        )
        catalog = CrystalClick::OfflineCatalog.open(root)
        catalog.table("lab", "bare").materialize_selected_values("payload")
          .map(&.as(CrystalClick::IPv4Value)).should eq(values)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps Nullable(IPv4) NULL distinct from zero in the reader, batches, and catalog" do
    parent = File.tempname("crystal-click-w18-reader-nullable-ipv4")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    keys = w18_reader_keys(5)
    zero = CrystalClick::IPv4Value.from_octets(0_u8, 0_u8, 0_u8, 0_u8)
    asymmetric = CrystalClick::IPv4Value.from_octets(1_u8, 2_u8, 3_u8, 4_u8)
    values = [
      nil.as(CrystalClick::IPv4Value?),
      zero.as(CrystalClick::IPv4Value?),
      asymmetric.as(CrystalClick::IPv4Value?),
      nil.as(CrystalClick::IPv4Value?),
      CrystalClick::IPv4Value.from_octets(4_u8, 3_u8, 2_u8, 1_u8).as(CrystalClick::IPv4Value?),
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_ipv4_pair(
        part_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), 2
      )
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      reader.column_type.should eq("Nullable(IPv4)")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_nullable_ipv4s_mark_range("payload", 0, reader.mark_count).should eq(values)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_numeric_mark_range("payload", 0, 1, UInt32)
      end

      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
      observed = [] of CrystalClick::IPv4Value?
      table.scan_typed(batch_rows: 3) do |batch|
        observed.concat(batch.nullable_ipv4s_for("payload"))
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.nullable_values_for("payload", UInt32)
        end
      end
      observed.should eq(values)
      observed[0].should be_nil
      observed[1].should eq(zero)
      observed[0].should_not eq(observed[1])

      w18_reader_with_catalog_root do |root, database_uuid|
        w18_reader_create_catalog_table(
          root, database_uuid, "nullable", "c18e7af8-f57c-42b8-bcb0-863f3de0ca53", "Nullable(IPv4)", part_path
        )
        catalog = CrystalClick::OfflineCatalog.open(root)
        catalog.table("lab", "nullable").materialize_selected_values("payload")
          .map(&.as(CrystalClick::IPv4Value?)).should eq(values)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects unsupported IPv4 serialization metadata and truncated payload streams" do
    parent = File.tempname("crystal-click-w18-reader-corruption")
    Dir.mkdir(parent)
    keys = [1_u64]
    bare_values = [CrystalClick::IPv4Value.from_octets(1_u8, 2_u8, 3_u8, 4_u8)]
    nullable_values = [nil.as(CrystalClick::IPv4Value?)]
    bare_path = File.join(parent, "bare")
    nullable_path = File.join(parent, "nullable")

    begin
      CrystalClick::WidePartWriter.write_uint64_ipv4_pair(
        bare_path, "pk", keys.to_unsafe.to_slice(1), "payload", bare_values.to_unsafe.to_slice(1), 1
      )
      serialization_path = File.join(bare_path, "serialization.json")
      serialization = File.read(serialization_path)
      serialization.should contain(%("string":1))
      serialization.should contain(%("columns":[]))

      File.delete(serialization_path)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(bare_path, "payload")
      end
      File.write(serialization_path, serialization.sub(%("string":1), %("string":0)))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(bare_path, "payload")
      end
      File.write(serialization_path, serialization.sub(%("columns":[]), %("columns":[{"name":"payload"}])))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(bare_path, "payload")
      end
      File.write(serialization_path, serialization.sub(%("columns":[]), %("columns":[],"missing_columns":[])))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(bare_path, "payload")
      end
      File.write(serialization_path, "{")
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(bare_path, "payload")
      end
      File.write(serialization_path, serialization)

      columns_path = File.join(bare_path, "columns.txt")
      columns = File.read(columns_path)
      File.write(columns_path, columns.sub("IPv4", "IPv4(4)"))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(bare_path, "payload")
      end
      File.write(columns_path, columns)

      bare_data_path = File.join(bare_path, "#{CrystalClick::StreamName.hash("payload")}.bin")
      bare_data = File.read(bare_data_path)
      File.write(bare_data_path, bare_data.byte_slice(0, bare_data.bytesize - 1))
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(bare_path, "payload")
      end

      CrystalClick::WidePartWriter.write_uint64_nullable_ipv4_pair(
        nullable_path, "pk", keys.to_unsafe.to_slice(1), "payload", nullable_values.to_unsafe.to_slice(1), 1
      )
      nullable_serialization_path = File.join(nullable_path, "serialization.json")
      nullable_serialization = File.read(nullable_serialization_path)
      nullable_serialization.should contain(%("string":1))
      nullable_serialization.should contain(%("columns":[]))
      File.delete(nullable_serialization_path)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(nullable_path, "payload")
      end
      File.write(nullable_serialization_path, nullable_serialization)
      File.write(nullable_serialization_path, nullable_serialization.sub(%("string":1), %("nullable":0,"string":1)))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(nullable_path, "payload")
      end
      File.write(nullable_serialization_path, nullable_serialization.sub(%("string":1), %("string":2)))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(nullable_path, "payload")
      end
      File.write(nullable_serialization_path, nullable_serialization)

      null_data_path = File.join(nullable_path, "#{CrystalClick::StreamName.hash("payload.null")}.bin")
      null_data = File.read(null_data_path)
      File.write(null_data_path, null_data.byte_slice(0, null_data.bytesize - 1))
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(nullable_path, "payload")
      end
      File.write(null_data_path, null_data)

      nullable_data_path = File.join(nullable_path, "#{CrystalClick::StreamName.hash("payload")}.bin")
      nullable_data = File.read(nullable_data_path)
      File.write(nullable_data_path, nullable_data.byte_slice(0, nullable_data.bytesize - 1))
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(nullable_path, "payload")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
