require "./spec_helper"

private def w20_reader_keys(size : Int) : Array(UInt64)
  Array(UInt64).new(size) { |index| index.to_u64 + 1_u64 }
end

private def w20_reader_catalog_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def w20_reader_create_catalog_table(
  root : String,
  database_uuid : String,
  table_name : String,
  table_uuid : String,
  column_type : String,
  part_path : String,
) : Nil
  database_path = w20_reader_catalog_path(root, database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "#{table_name}.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `payload` #{column_type}\n)\nENGINE = MergeTree\nORDER BY tuple()\n"
  )
  table_path = w20_reader_catalog_path(root, table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part_path, File.join(table_path, "all_1_1_0"))
end

private def w20_reader_with_catalog_root(&)
  root = File.tempname("crystal-click-w20-reader-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  database_uuid = "d20e7af8-f57c-42b8-bcb0-863f3de0ca61"
  FileUtils.mkdir_p(w20_reader_catalog_path(root, database_uuid))
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  begin
    yield root, database_uuid
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::WidePart do
  it "admits only canonical Decimal256 storage metadata and normalizes the alias" do
    (0..76).each do |scale|
      CrystalClick::WidePart.supports_typed_type?("Decimal(76, #{scale})").should be_true
      CrystalClick::WidePart.supports_typed_type?("Nullable(Decimal(76, #{scale}))").should be_true
      CrystalClick::WidePart.catalog_type("Decimal256(#{scale})").should eq("Decimal(76, #{scale})")
      CrystalClick::WidePart.catalog_type("Nullable(Decimal256(#{scale}))").should eq("Nullable(Decimal(76, #{scale}))")
      CrystalClick::WidePart.supports_typed_type?("Decimal256(#{scale})").should be_false
    end

    [
      "Decimal(76, 077)",
      "Decimal(76, 77)",
      "Decimal(76, -1)",
      "Decimal(76, 1 )",
      "Decimal(76, 1, 2)",
      "Decimal(77, 1)",
      "Nullable(Nullable(Decimal(76, 1)))",
      "Decimal256(77)",
      "Decimal256(01)",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
      CrystalClick::WidePart.catalog_type(type).should be_nil
    end

    CrystalClick::WidePart.supports_numeric_type?("Int128").should be_false
    CrystalClick::WidePart.supports_numeric_type?("Decimal(76, 1)").should be_false
  end
end

describe CrystalClick::Decimal256Value do
  it "stores four little-endian words in a distinct 32-byte signed value" do
    sizeof(CrystalClick::Decimal256Value).should eq(32)

    value = CrystalClick::Decimal256Value.from_words(
      0x0123456789abcdef_u64,
      0x1020304050607080_u64,
      0x8877665544332211_u64,
      0x7011223344556677_u64
    )
    value.low.should eq(0x10203040506070800123456789abcdef_u128)
    value.high.should eq(0x70112233445566778877665544332211_u128)
    value.negative?.should be_false
    value.to_s.should eq("50689311482956506398573356080265120351533180832918210417090848791576336649711")

    negative = CrystalClick::Decimal256Value.from_words(
      0xfedcba9876543210_u64,
      0x0123456789abcdef_u64,
      0x8000000000000001_u64,
      0x923456789abcdef0_u64
    )
    negative.negative?.should be_true
    negative.to_s.should eq("-49661940495115612808324135110037433543035232938169251403308512873264016248304")
  end

  it "sign extends Int128 and renders both signed 256-bit endpoints" do
    CrystalClick::Decimal256Value.from_int128(0_i128).to_s.should eq("0")
    CrystalClick::Decimal256Value.from_int128(-1_i128).to_s.should eq("-1")
    CrystalClick::Decimal256Value.from_int128(Int128::MAX).to_s.should eq("170141183460469231731687303715884105727")
    CrystalClick::Decimal256Value.from_int128(Int128::MIN).to_s.should eq("-170141183460469231731687303715884105728")

    maximum = CrystalClick::Decimal256Value.from_words(
      UInt64::MAX, UInt64::MAX, UInt64::MAX, 0x7fffffffffffffff_u64
    )
    maximum.to_s.should eq("57896044618658097711785492504343953926634992332820282019728792003956564819967")

    minimum = CrystalClick::Decimal256Value.from_words(
      0_u64, 0_u64, 0_u64, 0x8000000000000000_u64
    )
    minimum.to_s.should eq("-57896044618658097711785492504343953926634992332820282019728792003956564819968")
  end
end

describe CrystalClick::WidePart do
  it "reads Decimal256 across marks and exposes a distinct typed batch value" do
    parent = File.tempname("crystal-click-w20-reader-decimal256")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    keys = w20_reader_keys(5)
    values = [
      CrystalClick::Decimal256Value.from_int128(-1_i128),
      CrystalClick::Decimal256Value.from_words(
        0x0123456789abcdef_u64, 0x1020304050607080_u64,
        0x8877665544332211_u64, 0x7011223344556677_u64
      ),
      CrystalClick::Decimal256Value.new(0_u128, 0_u128),
      CrystalClick::Decimal256Value.from_words(
        0xfedcba9876543210_u64, 0x0123456789abcdef_u64,
        0x8000000000000001_u64, 0x923456789abcdef0_u64
      ),
      CrystalClick::Decimal256Value.from_words(
        UInt64::MAX, UInt64::MAX, UInt64::MAX, 0x7fffffffffffffff_u64
      ),
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_decimal256_pair(
        part_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), 38, 2
      )
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      reader.column_type.should eq("Decimal(76, 38)")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_decimal256_raw_mark_range("payload", 0, 1).should eq(values[0, 2])
      reader.read_decimal256_raw_mark_range("payload", 1, 2).should eq(values[2, 3])
      expect_raises(CrystalClick::BoundsError) do
        reader.read_decimal256_raw_mark_range("payload", 0, 0)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_numeric_mark_range("payload", 0, 1, Int128)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_uuids_mark_range("payload", 0, 1)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_ipv4s_mark_range("payload", 0, 1)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_ipv6s_mark_range("payload", 0, 1)
      end

      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
      observed = [] of CrystalClick::Decimal256Value
      batch_offsets = [] of {Int32, UInt64, Int32}
      table.scan_typed(batch_rows: 3) do |batch|
        batch_values = batch.decimal256_raw_for("payload")
        observed.concat(batch_values)
        batch_offsets << {batch.mark_index, batch.part_row_offset, batch_values.size.to_i32}
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.values_for("payload", Int128)
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.uuids_for("payload")
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.ipv4s_for("payload")
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.ipv6s_for("payload")
        end
      end
      observed.should eq(values)
      batch_offsets.should eq([{0_i32, 0_u64, 2_i32}, {1_i32, 2_u64, 2_i32}, {2_i32, 4_u64, 1_i32}])

      w20_reader_with_catalog_root do |root, database_uuid|
        w20_reader_create_catalog_table(
          root, database_uuid, "bare", "d20e7af8-f57c-42b8-bcb0-863f3de0ca63", "Decimal256(38)", part_path
        )
        catalog_values = CrystalClick::OfflineCatalog.open(root)
          .table("lab", "bare")
          .materialize_selected_values("payload")
        catalog_values.map(&.as(CrystalClick::Decimal256Value)).should eq(values)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps Nullable Decimal256 NULL distinct from zero through reader, batch, and catalog" do
    parent = File.tempname("crystal-click-w20-reader-nullable-decimal256")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    keys = w20_reader_keys(5)
    zero = CrystalClick::Decimal256Value.new(0_u128, 0_u128)
    pattern = CrystalClick::Decimal256Value.from_words(
      0x0123456789abcdef_u64, 0x1020304050607080_u64,
      0x8877665544332211_u64, 0x7011223344556677_u64
    )
    values = [
      nil.as(CrystalClick::Decimal256Value?),
      zero.as(CrystalClick::Decimal256Value?),
      pattern.as(CrystalClick::Decimal256Value?),
      nil.as(CrystalClick::Decimal256Value?),
      CrystalClick::Decimal256Value.from_int128(-1_i128).as(CrystalClick::Decimal256Value?),
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal256_pair(
        part_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), 76, 2
      )
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      reader.column_type.should eq("Nullable(Decimal(76, 76))")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_nullable_decimal256_raw_mark_range("payload", 0, 3).should eq(values)
      reader.read_nullable_decimal256_raw_mark_range("payload", 0, 1).should eq(values[0, 2])

      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
      observed = [] of CrystalClick::Decimal256Value?
      table.scan_typed(batch_rows: 3) do |batch|
        observed.concat(batch.nullable_decimal256_raw_for("payload"))
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.nullable_values_for("payload", Int128)
        end
      end
      observed.should eq(values)
      observed[0].should be_nil
      observed[1].should eq(zero)
      observed[0].should_not eq(observed[1])

      w20_reader_with_catalog_root do |root, database_uuid|
        w20_reader_create_catalog_table(
          root, database_uuid, "nullable", "d20e7af8-f57c-42b8-bcb0-863f3de0ca62", "Nullable(Decimal256(76))", part_path
        )
        catalog_values = CrystalClick::OfflineCatalog.open(root)
          .table("lab", "nullable")
          .materialize_selected_values("payload")
        catalog_values.map(&.as(CrystalClick::Decimal256Value?)).should eq(values)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects noncanonical Decimal256 declarations, serializer metadata, and truncated data" do
    parent = File.tempname("crystal-click-w20-reader-corrupt")
    Dir.mkdir(parent)
    part_path = File.join(parent, "part")
    keys = w20_reader_keys(2)
    value = CrystalClick::Decimal256Value.from_int128(7_i128)
    values = [value, value]

    begin
      CrystalClick::WidePartWriter.write_uint64_decimal256_pair(
        part_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), 1, 2
      )
      columns_path = File.join(part_path, "columns.txt")
      columns = File.read(columns_path)
      File.write(columns_path, columns.sub("Decimal(76, 1)", "Decimal(76, 77)"))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part_path, "payload")
      end
      File.write(columns_path, columns)

      serialization_path = File.join(part_path, "serialization.json")
      serialization = File.read(serialization_path)
      File.write(serialization_path, serialization.sub(%("string":1), %("string":2)))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part_path, "payload")
      end
      File.write(serialization_path, serialization)

      data_path = File.join(part_path, "#{CrystalClick::StreamName.hash("payload")}.bin")
      data = File.read(data_path)
      File.write(data_path, data.byte_slice(0, data.bytesize - 1))
      expect_raises(CrystalClick::CorruptPartError) do
        reader = CrystalClick::WidePart.open_typed(part_path, "payload")
        reader.read_decimal256_raw_mark_range("payload", 0, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
