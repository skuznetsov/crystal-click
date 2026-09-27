require "./spec_helper"

W42_DECIMAL32_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_decimal32_w42/part", __DIR__)
W42_KEYS              = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]

W42_PLAIN_ROWS = [
  [] of Int32,
  [-1234_i32, 0_i32, 9999_i32],
  [-999_999_999_i32, 1_i32],
  [] of Int32,
  [-123_i32],
  [1234_i32, -1_i32],
  [] of Int32,
] of Array(Int32)

W42_NULLABLE_ROWS = [
  [] of Int32?,
  [nil, 0_i32, -5_i32] of Int32?,
  [nil, 123_i32] of Int32?,
  [] of Int32?,
  [-100_i32, nil] of Int32?,
  [0_i32, nil] of Int32?,
  [] of Int32?,
] of Array(Int32?)

private def w42_decode_stream(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w42_size_stream(values : Array(Array(T))) : Array(UInt8) forall T
  bytes = [] of UInt8
  values.each do |row|
    value = row.size.to_u64
    8.times { |index| bytes << ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w42_numeric_payload(values : Array(Array(T))) : Array(UInt8) forall T
  bytes = [] of UInt8
  values.each do |row|
    row.each do |value|
      bits = value.unsafe_as(UInt32)
      4.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u32).to_u8 }
    end
  end
  bytes
end

private def w42_nullable_payload(values : Array(Array(Int32?))) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |row|
    row.each do |value|
      bits = (value || 0_i32).unsafe_as(UInt32)
      4.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u32).to_u8 }
    end
  end
  bytes
end

private def w42_null_map(values : Array(Array(Int32?))) : Array(UInt8)
  values.flat_map { |row| row.map { |value| value.nil? ? 1_u8 : 0_u8 } }
end

private def w42_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def with_w42_catalog_root(& : String ->)
  root = File.tempname("crystal-click-w42-offline-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    File.write(
      File.join(root, "metadata", "lab.sql"),
      "ATTACH DATABASE _ UUID 'f4f3f59b-2f8a-49ea-9b5e-26c089e67101'\nENGINE = Atomic\n"
    )
    database_path = w42_store_path(root, "f4f3f59b-2f8a-49ea-9b5e-26c089e67101")
    table_path = w42_store_path(root, "ed7b8c71-4eeb-4b83-92b2-09f278680c12")
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID 'ed7b8c71-4eeb-4b83-92b2-09f278680c12'\n(\n" +
      "    `pk` UInt64,\n    `plain` Array(Decimal32(2)),\n" +
      "    `maybe` Array(Nullable(Decimal32(2)))\n)\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W42_DECIMAL32_FIXTURE, File.join(table_path, "all_1_1_0"))
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::WidePart do
  it "admits only one-level Decimal32 arrays with exact canonical scale metadata" do
    {
      "Array(Decimal(9, 0))", "Array(Decimal(9, 2))", "Array(Decimal(9, 9))",
      "Array(Nullable(Decimal(9, 0)))", "Array(Nullable(Decimal(9, 2)))", "Array(Nullable(Decimal(9, 9)))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end

    {
      "Array(Decimal(9, 10))", "Array(Decimal(9, 2) )", "Array(Decimal32(2))",
      "Array(Nullable(Decimal(9, 10)))", "Array(Nullable(Nullable(Decimal(9, 2))))",
      "Array(Array(Decimal(9, 2)))", "Nullable(Array(Decimal(9, 2)))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads stock Decimal32 arrays by marks and keeps signed coefficients and NULL distinct" do
    plain = CrystalClick::WidePart.open_typed(W42_DECIMAL32_FIXTURE, "plain")
    plain.column_type.should eq("Array(Decimal(9, 2))")
    plain.row_count.should eq(7_u64)
    plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    plain.read_array_decimal32_raw_mark_range("plain", 0, plain.mark_count).should eq(W42_PLAIN_ROWS)
    plain.read_array_decimal32_raw_mark_range("plain", 1, 2).should eq(W42_PLAIN_ROWS[2, 4])
    plain.read_array_decimal32_raw_mark_range("plain", 3, 1).should eq(W42_PLAIN_ROWS[6, 1])

    maybe = CrystalClick::WidePart.open_typed(W42_DECIMAL32_FIXTURE, "maybe")
    maybe.column_type.should eq("Array(Nullable(Decimal(9, 2)))")
    maybe.row_count.should eq(7_u64)
    maybe.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    maybe.read_array_nullable_decimal32_raw_mark_range("maybe", 0, maybe.mark_count).should eq(W42_NULLABLE_ROWS)
    maybe.read_array_nullable_decimal32_raw_mark_range("maybe", 1, 2).should eq(W42_NULLABLE_ROWS[2, 4])

    w42_decode_stream(W42_DECIMAL32_FIXTURE, "plain.size0").should eq(w42_size_stream(W42_PLAIN_ROWS))
    w42_decode_stream(W42_DECIMAL32_FIXTURE, "plain").should eq(w42_numeric_payload(W42_PLAIN_ROWS))
    w42_decode_stream(W42_DECIMAL32_FIXTURE, "maybe.size0").should eq(w42_size_stream(W42_NULLABLE_ROWS))
    w42_decode_stream(W42_DECIMAL32_FIXTURE, "maybe.null").should eq(w42_null_map(W42_NULLABLE_ROWS))
    w42_decode_stream(W42_DECIMAL32_FIXTURE, "maybe").should eq(w42_nullable_payload(W42_NULLABLE_ROWS))
    W42_NULLABLE_ROWS[1].should eq([nil, 0_i32, -5_i32])
    W42_NULLABLE_ROWS[2].should eq([nil, 123_i32])
  end

  it "fails closed on numeric aliases, the opposite Nullable shape, and malformed Decimal metadata" do
    plain = CrystalClick::WidePart.open_typed(W42_DECIMAL32_FIXTURE, "plain")
    maybe = CrystalClick::WidePart.open_typed(W42_DECIMAL32_FIXTURE, "maybe")
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plain.read_array_numeric_mark_range("plain", 0, 1, Int32)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plain.read_array_nullable_decimal32_raw_mark_range("plain", 0, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      maybe.read_array_decimal32_raw_mark_range("maybe", 0, 1)
    end

    {
      "Array(Decimal(9, 10))", "Array(Decimal(09, 2))", "Array(Decimal(9, 02))",
      "Array(Decimal(9,2))", "Array(Decimal32(2))", "Array(Nullable(Decimal(9, 10)))",
      "Array(Nullable(Nullable(Decimal(9, 2))))", "Array(Array(Decimal(9, 2)))",
      "Nullable(Array(Decimal(9, 2)))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "rejects Decimal32 raw array readers for exact Int32 array declarations" do
    parent = File.tempname("crystal-click-w42-array-int32-negative")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    plain_rows = [[-7_i32, 0_i32], [] of Int32] of Array(Int32)
    nullable_rows = [[nil, 0_i32] of Int32?, [] of Int32?] of Array(Int32?)
    begin
      plain_part = File.join(parent, "plain-int32")
      CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
        plain_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        plain_rows.to_unsafe.to_slice(plain_rows.size), 1_i32
      )
      plain = CrystalClick::WidePart.open_typed(plain_part, "payload")
      plain.column_type.should eq("Array(Int32)")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        plain.read_array_decimal32_raw_mark_range("payload", 0, 1)
      end

      nullable_part = File.join(parent, "nullable-int32")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_numeric_pair(
        nullable_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        nullable_rows.to_unsafe.to_slice(nullable_rows.size), 1_i32
      )
      nullable = CrystalClick::WidePart.open_typed(nullable_part, "payload")
      nullable.column_type.should eq("Array(Nullable(Int32))")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        nullable.read_array_nullable_decimal32_raw_mark_range("payload", 0, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes and rereads raw Decimal32 arrays at scale boundaries without coefficient clamping" do
    parent = File.tempname("crystal-click-w42-decimal32-array-writer")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    plain_rows = [[Int32::MIN, 0_i32, Int32::MAX], [] of Int32] of Array(Int32)
    nullable_rows = [[nil, Int32::MIN, 0_i32, Int32::MAX] of Int32?, [] of Int32?] of Array(Int32?)
    begin
      {0, 9}.each do |scale|
        plain_part = File.join(parent, "plain-scale-#{scale}")
        CrystalClick::WidePartWriter.write_uint64_array_decimal32_pair(
          plain_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          plain_rows.to_unsafe.to_slice(plain_rows.size), scale, 1
        )
        plain = CrystalClick::WidePart.open_typed(plain_part, "payload")
        plain.column_type.should eq("Array(Decimal(9, #{scale}))")
        plain.read_array_decimal32_raw_mark_range("payload", 0, plain.mark_count).should eq(plain_rows)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          plain.read_array_numeric_mark_range("payload", 0, 1, Int32)
        end

        nullable_part = File.join(parent, "nullable-scale-#{scale}")
        CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal32_pair(
          nullable_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          nullable_rows.to_unsafe.to_slice(nullable_rows.size), scale, 1
        )
        nullable = CrystalClick::WidePart.open_typed(nullable_part, "payload")
        nullable.column_type.should eq("Array(Nullable(Decimal(9, #{scale})))")
        nullable.read_array_nullable_decimal32_raw_mark_range("payload", 0, nullable.mark_count).should eq(nullable_rows)
      end

      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_decimal32_pair(
          File.join(parent, "invalid-scale"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          plain_rows.to_unsafe.to_slice(plain_rows.size), 10, 1
        )
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "materializes stock alias metadata through the offline catalog using the canonical part type" do
    with_w42_catalog_root do |root|
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"plain", "Array(Decimal32(2))"},
        {"maybe", "Array(Nullable(Decimal32(2)))"},
      ])

      plain_rows = [] of Array(Int32)
      nullable_rows = [] of Array(Int32?)
      table.scan_typed(["plain", "maybe"], batch_rows: 3) do |batch|
        batch.column_type_for("plain").should eq("Array(Decimal(9, 2))")
        batch.column_type_for("maybe").should eq("Array(Nullable(Decimal(9, 2)))")
        plain_rows.concat(batch.array_decimal32_raw_for("plain").map(&.dup))
        nullable_rows.concat(batch.array_nullable_decimal32_raw_for("maybe").map(&.dup))
      end
      plain_rows.should eq(W42_PLAIN_ROWS)
      nullable_rows.should eq(W42_NULLABLE_ROWS)

      later_rows = [] of Array(Int32?)
      table.scan_typed_window(["maybe"], 4_u64, max_rows: 3) do |batch|
        later_rows.concat(batch.array_nullable_decimal32_raw_for("maybe").map(&.dup))
      end
      later_rows.should eq(W42_NULLABLE_ROWS[4, 3])
    end
  end
end
