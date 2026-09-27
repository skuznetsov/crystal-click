require "./spec_helper"

W43_DECIMAL64_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_decimal64_w43/part", __DIR__)
W43_KEYS              = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]

W43_PLAIN_ROWS = [
  [] of Int64,
  [-1234_i64, 0_i64, 9999_i64],
  [-999_999_999_999_999_999_i64, 1_i64],
  [] of Int64,
  [-123_i64],
  [1234_i64, -1_i64],
  [] of Int64,
] of Array(Int64)

W43_NULLABLE_ROWS = [
  [] of Int64?,
  [nil, 0_i64, -5_i64] of Int64?,
  [nil, 123_i64] of Int64?,
  [] of Int64?,
  [-100_i64, nil] of Int64?,
  [0_i64, nil] of Int64?,
  [] of Int64?,
] of Array(Int64?)

private def w43_decode_stream(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w43_size_stream(values : Array(Array(T))) : Array(UInt8) forall T
  bytes = [] of UInt8
  values.each do |row|
    value = row.size.to_u64
    8.times { |index| bytes << ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w43_int64_payload(values : Array(Array(Int64))) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |row|
    row.each do |value|
      bits = value.unsafe_as(UInt64)
      8.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u64).to_u8 }
    end
  end
  bytes
end

private def w43_nullable_payload(values : Array(Array(Int64?))) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |row|
    row.each do |value|
      bits = (value || 0_i64).unsafe_as(UInt64)
      8.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u64).to_u8 }
    end
  end
  bytes
end

private def w43_null_map(values : Array(Array(Int64?))) : Array(UInt8)
  values.flat_map { |row| row.map { |value| value.nil? ? 1_u8 : 0_u8 } }
end

private def w43_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def with_w43_catalog_root(& : String ->)
  root = File.tempname("crystal-click-w43-offline-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    File.write(
      File.join(root, "metadata", "lab.sql"),
      "ATTACH DATABASE _ UUID '29388d38-0402-43ba-a210-236f986ca7a3'\nENGINE = Atomic\n"
    )
    database_path = w43_store_path(root, "29388d38-0402-43ba-a210-236f986ca7a3")
    table_path = w43_store_path(root, "a0824656-e47a-42d7-8449-9441c3ba1f45")
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID 'a0824656-e47a-42d7-8449-9441c3ba1f45'\n(\n" +
      "    `pk` UInt64,\n    `plain` Array(Decimal64(2)),\n" +
      "    `maybe` Array(Nullable(Decimal64(2)))\n)\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W43_DECIMAL64_FIXTURE, File.join(table_path, "all_1_1_0"))
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::WidePart do
  it "admits only exact Decimal64 Array grammar at every supported scale" do
    (0..18).each do |scale|
      CrystalClick::WidePart.supports_typed_type?("Array(Decimal(18, #{scale}))").should be_true
      CrystalClick::WidePart.supports_typed_type?("Array(Nullable(Decimal(18, #{scale})))").should be_true
    end

    {
      "Array(Decimal(18, 19))", "Array(Decimal(18, 02))", "Array(Decimal(018, 2))",
      "Array(Decimal(18,2))", "Array(Decimal(18, 2) )", "Array(Decimal64(2))",
      "Array(Nullable(Decimal(18, 19)))", "Array(Nullable(Nullable(Decimal(18, 2))))",
      "Array(Array(Decimal(18, 2)))", "Nullable(Array(Decimal(18, 2)))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end

    CrystalClick::WidePart.array_decimal64_scale("Array(Decimal(18, 0))").should eq(0)
    CrystalClick::WidePart.array_decimal64_scale("Array(Decimal(18, 18))").should eq(18)
    CrystalClick::WidePart.array_nullable_decimal64_scale("Array(Nullable(Decimal(18, 9)))").should eq(9)
    CrystalClick::WidePart.catalog_type("Array(Decimal64(2))").should eq("Array(Decimal(18, 2))")
    CrystalClick::WidePart.catalog_type("Array(Nullable(Decimal64(18)))").should eq("Array(Nullable(Decimal(18, 18)))")
  end

  it "reads stock Decimal64 arrays by marks with exact Int64 coefficients and NULLs" do
    plain = CrystalClick::WidePart.open_typed(W43_DECIMAL64_FIXTURE, "plain")
    plain.column_type.should eq("Array(Decimal(18, 2))")
    plain.row_count.should eq(7_u64)
    plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    plain.read_array_decimal64_raw_mark_range("plain", 0, plain.mark_count).should eq(W43_PLAIN_ROWS)
    plain.read_array_decimal64_raw_mark_range("plain", 1, 2).should eq(W43_PLAIN_ROWS[2, 4])
    plain.read_array_decimal64_raw_mark_range("plain", 3, 1).should eq(W43_PLAIN_ROWS[6, 1])

    maybe = CrystalClick::WidePart.open_typed(W43_DECIMAL64_FIXTURE, "maybe")
    maybe.column_type.should eq("Array(Nullable(Decimal(18, 2)))")
    maybe.row_count.should eq(7_u64)
    maybe.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    maybe.read_array_nullable_decimal64_raw_mark_range("maybe", 0, maybe.mark_count).should eq(W43_NULLABLE_ROWS)
    maybe.read_array_nullable_decimal64_raw_mark_range("maybe", 1, 2).should eq(W43_NULLABLE_ROWS[2, 4])

    w43_decode_stream(W43_DECIMAL64_FIXTURE, "plain.size0").should eq(w43_size_stream(W43_PLAIN_ROWS))
    w43_decode_stream(W43_DECIMAL64_FIXTURE, "plain").should eq(w43_int64_payload(W43_PLAIN_ROWS))
    w43_decode_stream(W43_DECIMAL64_FIXTURE, "maybe.size0").should eq(w43_size_stream(W43_NULLABLE_ROWS))
    w43_decode_stream(W43_DECIMAL64_FIXTURE, "maybe.null").should eq(w43_null_map(W43_NULLABLE_ROWS))
    w43_decode_stream(W43_DECIMAL64_FIXTURE, "maybe").should eq(w43_nullable_payload(W43_NULLABLE_ROWS))
    W43_NULLABLE_ROWS[1].should eq([nil, 0_i64, -5_i64])
    W43_NULLABLE_ROWS[2].should eq([nil, 123_i64])
  end

  it "rejects noncanonical Decimal64 scale grammar in typed part metadata" do
    parent = File.tempname("crystal-click-w43-decimal64-array-grammar")
    Dir.mkdir(parent)
    begin
      [
        {"Array(Decimal(18, 2))", "Array(Decimal(18, 02))"},
        {"Array(Decimal(18, 2))", "Array(Decimal(18,2))"},
      ].each_with_index do |(canonical, malformed), index|
        bad_part = File.join(parent, "bad-grammar-#{index}")
        FileUtils.cp_r(W43_DECIMAL64_FIXTURE, bad_part)
        columns_path = File.join(bad_part, "columns.txt")
        original = File.read(columns_path)
        mutated = original.sub(canonical, malformed)
        mutated.should_not eq(original)
        File.write(columns_path, mutated)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_typed(bad_part, "plain")
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects the opposite shape and generic Int64 Array accessors" do
    plain = CrystalClick::WidePart.open_typed(W43_DECIMAL64_FIXTURE, "plain")
    maybe = CrystalClick::WidePart.open_typed(W43_DECIMAL64_FIXTURE, "maybe")
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plain.read_array_nullable_decimal64_raw_mark_range("plain", 0, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      maybe.read_array_decimal64_raw_mark_range("maybe", 0, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plain.read_array_numeric_mark_range("plain", 0, 1, Int64)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      maybe.read_array_nullable_numeric_mark_range("maybe", 0, 1, Int64)
    end

    parent = File.tempname("crystal-click-w43-array-int64-negative")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    plain_rows = [[Int64::MIN], [] of Int64] of Array(Int64)
    nullable_rows = [[nil, 0_i64] of Int64?, [] of Int64?] of Array(Int64?)
    begin
      plain_part = File.join(parent, "plain-int64")
      CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
        plain_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        plain_rows.to_unsafe.to_slice(plain_rows.size), 1_i32
      )
      plain_int64 = CrystalClick::WidePart.open_typed(plain_part, "payload")
      plain_int64.column_type.should eq("Array(Int64)")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        plain_int64.read_array_decimal64_raw_mark_range("payload", 0, 1)
      end

      nullable_part = File.join(parent, "nullable-int64")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_numeric_pair(
        nullable_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        nullable_rows.to_unsafe.to_slice(nullable_rows.size), 1_i32
      )
      nullable_int64 = CrystalClick::WidePart.open_typed(nullable_part, "payload")
      nullable_int64.column_type.should eq("Array(Nullable(Int64))")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        nullable_int64.read_array_nullable_decimal64_raw_mark_range("payload", 0, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes raw Decimal64 Array coefficients at all scales without clamping" do
    parent = File.tempname("crystal-click-w43-decimal64-array-writer")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 4_u64]
    plain_rows = [
      [Int64::MIN, 0_i64, Int64::MAX], [] of Int64, [-1_i64],
    ] of Array(Int64)
    nullable_rows = [
      [nil, Int64::MIN, 0_i64, Int64::MAX] of Int64?, [] of Int64?, [nil] of Int64?,
    ] of Array(Int64?)
    begin
      (0..18).each do |scale|
        plain_part = File.join(parent, "plain-scale-#{scale}")
        CrystalClick::WidePartWriter.write_uint64_array_decimal64_pair(
          plain_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          plain_rows.to_unsafe.to_slice(plain_rows.size), scale.to_i32, 1_i32
        )
        plain = CrystalClick::WidePart.open_typed(plain_part, "payload")
        plain.column_type.should eq("Array(Decimal(18, #{scale}))")
        plain.read_array_decimal64_raw_mark_range("payload", 0, plain.mark_count).should eq(plain_rows)

        nullable_part = File.join(parent, "nullable-scale-#{scale}")
        CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal64_pair(
          nullable_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          nullable_rows.to_unsafe.to_slice(nullable_rows.size), scale.to_i32, 1_i32
        )
        nullable = CrystalClick::WidePart.open_typed(nullable_part, "payload")
        nullable.column_type.should eq("Array(Nullable(Decimal(18, #{scale})))")
        nullable.read_array_nullable_decimal64_raw_mark_range("payload", 0, nullable.mark_count).should eq(nullable_rows)
      end

      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_decimal64_pair(
          File.join(parent, "invalid-scale"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          plain_rows.to_unsafe.to_slice(plain_rows.size), 19_i32, 1_i32
        )
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "materializes stock Decimal64 aliases in catalog scans and owned projections" do
    with_w43_catalog_root do |root|
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"plain", "Array(Decimal64(2))"},
        {"maybe", "Array(Nullable(Decimal64(2)))"},
      ])

      plain_rows = [] of Array(Int64)
      nullable_rows = [] of Array(Int64?)
      table.scan_typed(["plain", "maybe"], batch_rows: 3) do |batch|
        batch.column_type_for("plain").should eq("Array(Decimal(18, 2))")
        batch.column_type_for("maybe").should eq("Array(Nullable(Decimal(18, 2)))")
        plain_rows.concat(batch.array_decimal64_raw_for("plain").map(&.dup))
        nullable_rows.concat(batch.array_nullable_decimal64_raw_for("maybe").map(&.dup))
      end
      plain_rows.should eq(W43_PLAIN_ROWS)
      nullable_rows.should eq(W43_NULLABLE_ROWS)

      later_rows = [] of Array(Int64?)
      table.scan_typed_window(["maybe"], 4_u64, max_rows: 3) do |batch|
        later_rows.concat(batch.array_nullable_decimal64_raw_for("maybe").map(&.dup))
      end
      later_rows.should eq(W43_NULLABLE_ROWS[4, 3])

      projected_plain = table["plain"].values.map { |value| value.as(Array(Int64)) }
      projected_nullable = table["maybe"].values.map { |value| value.as(Array(Int64?)) }
      projected_plain.should eq(W43_PLAIN_ROWS)
      projected_nullable.should eq(W43_NULLABLE_ROWS)
      projected_plain[1][0] = 777_i64
      projected_nullable[1][1] = 888_i64
      table["plain"].values.map { |value| value.as(Array(Int64)) }.should eq(W43_PLAIN_ROWS)
      table["maybe"].values.map { |value| value.as(Array(Int64?)) }.should eq(W43_NULLABLE_ROWS)
    end
  end
end
