require "./spec_helper"

private def w19_reader_keys(size : Int) : Array(UInt64)
  Array(UInt64).new(size) { |index| index.to_u64 + 1_u64 }
end

private def w19_reader_catalog_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def w19_reader_create_catalog_table(
  root : String,
  database_uuid : String,
  table_name : String,
  table_uuid : String,
  column_type : String,
  part_path : String,
) : Nil
  database_path = w19_reader_catalog_path(root, database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "#{table_name}.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `payload` #{column_type}\n)\nENGINE = MergeTree\nORDER BY tuple()\n"
  )
  table_path = w19_reader_catalog_path(root, table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part_path, File.join(table_path, "all_1_1_0"))
end

private def w19_reader_with_catalog_root(&)
  root = File.tempname("crystal-click-w19-reader-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    database_uuid = "d19e7af8-f57c-42b8-bcb0-863f3de0ca61"
    FileUtils.mkdir_p(w19_reader_catalog_path(root, database_uuid))
    File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
    yield root, database_uuid
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::WidePart do
  it "admits only exact IPv6 and BASIC Nullable(IPv6) declarations" do
    ["IPv6", "Nullable(IPv6)"].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end

    [
      "Ipv6",
      "IPv6(16)",
      "Nullable(Nullable(IPv6))",
      "Nullable(IPv6, IPv6)",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "models IPv6 as a distinct 16-byte network-order value" do
    sizeof(CrystalClick::IPv6Value).should eq(16)

    zero = CrystalClick::IPv6Value.from_hextets(
      0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16
    )
    zero.high.should eq(0_u64)
    zero.low.should eq(0_u64)
    zero.to_s.should eq("::")

    loopback = CrystalClick::IPv6Value.from_hextets(
      0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 1_u16
    )
    loopback.to_s.should eq("::1")

    address = CrystalClick::IPv6Value.from_hextets(
      0x2001_u16, 0x0db8_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 1_u16
    )
    address.high.should eq(0x20010db800000000_u64)
    address.low.should eq(1_u64)
    address.to_s.should eq("2001:db8::1")

    tied_zero_runs = CrystalClick::IPv6Value.from_hextets(
      0x2001_u16, 0_u16, 0_u16, 1_u16, 0_u16, 0_u16, 1_u16, 1_u16
    )
    tied_zero_runs.to_s.should eq("2001::1:0:0:1:1")

    ipv4_compatible = CrystalClick::IPv6Value.from_hextets(
      0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0xc000_u16, 0x0201_u16
    )
    ipv4_compatible.to_s.should eq("::192.0.2.1")

    ipv4_compatible_loopback_range = CrystalClick::IPv6Value.from_hextets(
      0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 2_u16
    )
    ipv4_compatible_loopback_range.to_s.should eq("::2")

    ipv4_compatible_upper_hextet = CrystalClick::IPv6Value.from_hextets(
      0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0xffff_u16
    )
    ipv4_compatible_upper_hextet.to_s.should eq("::ffff")

    ipv4_compatible_first_dotted = CrystalClick::IPv6Value.from_hextets(
      0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 1_u16, 0_u16
    )
    ipv4_compatible_first_dotted.to_s.should eq("::0.1.0.0")

    ipv4_compatible_second_dotted = CrystalClick::IPv6Value.from_hextets(
      0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0x0100_u16, 0_u16
    )
    ipv4_compatible_second_dotted.to_s.should eq("::1.0.0.0")

    ipv4_mapped = CrystalClick::IPv6Value.from_hextets(
      0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0xffff_u16, 0xc000_u16, 0x0201_u16
    )
    ipv4_mapped.to_s.should eq("::ffff:192.0.2.1")

    mapped_zero = CrystalClick::IPv6Value.from_hextets(
      0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0xffff_u16, 0_u16, 0_u16
    )
    mapped_zero.to_s.should eq("::ffff:0.0.0.0")

    mapped_one = CrystalClick::IPv6Value.from_hextets(
      0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0xffff_u16, 0_u16, 1_u16
    )
    mapped_one.to_s.should eq("::ffff:0.0.0.1")

    not_mapped_prefix = CrystalClick::IPv6Value.from_hextets(
      0_u16, 0_u16, 0_u16, 0_u16, 0xffff_u16, 0_u16, 0xc000_u16, 0x0201_u16
    )
    not_mapped_prefix.to_s.should eq("::ffff:0:c000:201")
  end

  it "reads IPv6 through marks, batches, and selected offline catalog materialization" do
    parent = File.tempname("crystal-click-w19-reader-ipv6")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    keys = w19_reader_keys(5)
    values = [
      CrystalClick::IPv6Value.from_hextets(0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16),
      CrystalClick::IPv6Value.from_hextets(0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 1_u16),
      CrystalClick::IPv6Value.from_hextets(0x2001_u16, 0x0db8_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 1_u16),
      CrystalClick::IPv6Value.from_hextets(0x2001_u16, 0x0db8_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 2_u16),
      CrystalClick::IPv6Value.from_hextets(0xffff_u16, 0x1234_u16, 0x5678_u16, 0x9abc_u16, 0xdef0_u16, 0x1111_u16, 0x2222_u16, 0x3333_u16),
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_ipv6_pair(
        part_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), 2
      )
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      reader.column_type.should eq("IPv6")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_ipv6s_mark_range("payload", 0, 2).should eq(values[0, 4])
      reader.read_ipv6s_mark_range("payload", 2, 1).should eq([values[4]])
      expect_raises(CrystalClick::BoundsError) do
        reader.read_ipv6s_mark_range("payload", 0, 0)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_numeric_mark_range("payload", 0, 1, UInt128)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_uuids_mark_range("payload", 0, 1)
      end

      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
      observed = [] of CrystalClick::IPv6Value
      batches = [] of Int32
      table.scan_typed(batch_rows: 3) do |batch|
        observed.concat(batch.ipv6s_for("payload"))
        batches << batch.ipv6s_for("payload").size.to_i32
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.values_for("payload", UInt128)
        end
      end
      observed.should eq(values)
      batches.should eq([2_i32, 2_i32, 1_i32])

      w19_reader_with_catalog_root do |root, database_uuid|
        w19_reader_create_catalog_table(
          root, database_uuid, "bare", "d19e7af8-f57c-42b8-bcb0-863f3de0ca62", "IPv6", part_path
        )
        catalog = CrystalClick::OfflineCatalog.open(root)
        catalog.table("lab", "bare").materialize_selected_values("payload")
          .map(&.as(CrystalClick::IPv6Value)).should eq(values)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps Nullable(IPv6) NULL distinct from :: in readers, batches, and catalog" do
    parent = File.tempname("crystal-click-w19-reader-nullable-ipv6")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    keys = w19_reader_keys(5)
    zero = CrystalClick::IPv6Value.from_hextets(0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16)
    values = [
      nil.as(CrystalClick::IPv6Value?),
      zero.as(CrystalClick::IPv6Value?),
      CrystalClick::IPv6Value.from_hextets(0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 1_u16).as(CrystalClick::IPv6Value?),
      nil.as(CrystalClick::IPv6Value?),
      CrystalClick::IPv6Value.from_hextets(0x2001_u16, 0x0db8_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 1_u16).as(CrystalClick::IPv6Value?),
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_ipv6_pair(
        part_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), 2
      )
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      reader.column_type.should eq("Nullable(IPv6)")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_nullable_ipv6s_mark_range("payload", 0, reader.mark_count).should eq(values)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_numeric_mark_range("payload", 0, 1, UInt128)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_uuids_mark_range("payload", 0, 1)
      end

      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
      observed = [] of CrystalClick::IPv6Value?
      table.scan_typed(batch_rows: 3) do |batch|
        observed.concat(batch.nullable_ipv6s_for("payload"))
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.nullable_values_for("payload", UInt128)
        end
      end
      observed.should eq(values)
      observed[0].should be_nil
      observed[1].should eq(zero)
      observed[0].should_not eq(observed[1])

      w19_reader_with_catalog_root do |root, database_uuid|
        w19_reader_create_catalog_table(
          root, database_uuid, "nullable", "d19e7af8-f57c-42b8-bcb0-863f3de0ca63", "Nullable(IPv6)", part_path
        )
        catalog = CrystalClick::OfflineCatalog.open(root)
        catalog.table("lab", "nullable").materialize_selected_values("payload")
          .map(&.as(CrystalClick::IPv6Value?)).should eq(values)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects unsupported IPv6 serialization metadata and truncated IPv6 substreams" do
    parent = File.tempname("crystal-click-w19-reader-corruption")
    Dir.mkdir(parent)
    keys = [1_u64]
    bare_values = [CrystalClick::IPv6Value.from_hextets(0x2001_u16, 0x0db8_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 1_u16)]
    nullable_values = [nil.as(CrystalClick::IPv6Value?)]
    bare_path = File.join(parent, "bare")
    nullable_path = File.join(parent, "nullable")

    begin
      CrystalClick::WidePartWriter.write_uint64_ipv6_pair(
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
      File.write(serialization_path, serialization.sub(%("string":1), %("string":2)))
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
      File.write(columns_path, columns.sub("IPv6", "IPv6(16)"))
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

      CrystalClick::WidePartWriter.write_uint64_nullable_ipv6_pair(
        nullable_path, "pk", keys.to_unsafe.to_slice(1), "payload", nullable_values.to_unsafe.to_slice(1), 1
      )
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
