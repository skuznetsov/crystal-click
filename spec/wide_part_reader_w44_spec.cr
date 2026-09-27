require "./spec_helper"

W44_DECIMAL128_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_decimal128_w44/part", __DIR__)
W44_KEYS               = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W44_DECIMAL_MAX        = ("9" * 38).to_i128

W44_STOCK_PLAIN_ROWS = [
  [] of Int128,
  [-1234_i128, 0_i128, 9999_i128],
  [-W44_DECIMAL_MAX, 1_i128],
  [] of Int128,
  [-123_i128],
  [1234_i128, -1_i128],
  [] of Int128,
] of Array(Int128)

W44_STOCK_NULLABLE_ROWS = [
  [] of Int128?,
  [nil, 0_i128, -5_i128] of Int128?,
  [nil, 123_i128] of Int128?,
  [] of Int128?,
  [-100_i128, nil] of Int128?,
  [0_i128, nil] of Int128?,
  [] of Int128?,
] of Array(Int128?)

W44_WRITER_PLAIN_ROWS = [
  [Int128::MIN, -1_i128, 0_i128, 1_i128, Int128::MAX],
  [] of Int128,
  [-W44_DECIMAL_MAX, W44_DECIMAL_MAX],
  [] of Int128,
  [-123_i128],
  [0_i128, 1_i128],
  [] of Int128,
] of Array(Int128)

W44_WRITER_NULLABLE_ROWS = [
  [nil, Int128::MIN, 0_i128, Int128::MAX] of Int128?,
  [nil, nil] of Int128?,
  [nil, -1_i128, 0_i128] of Int128?,
  [] of Int128?,
  [-W44_DECIMAL_MAX, nil] of Int128?,
  [0_i128, nil] of Int128?,
  [] of Int128?,
] of Array(Int128?)

private def w44_decode_stream(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  encoded = File.read(path).to_slice
  encoded.empty? ? [] of UInt8 : CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w44_size_stream(values : Array(Array(T))) : Array(UInt8) forall T
  bytes = [] of UInt8
  values.each do |row|
    size = row.size.to_u64
    8.times { |index| bytes << ((size >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w44_int128_payload(values : Array(Array(Int128))) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |row|
    row.each do |value|
      bits = value.unsafe_as(UInt128)
      16.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u128).to_u8 }
    end
  end
  bytes
end

private def w44_nullable_payload(values : Array(Array(Int128?))) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |row|
    row.each do |value|
      bits = (value || 0_i128).unsafe_as(UInt128)
      16.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u128).to_u8 }
    end
  end
  bytes
end

private def w44_null_map(values : Array(Array(Int128?))) : Array(UInt8)
  values.flat_map { |row| row.map { |value| value.nil? ? 1_u8 : 0_u8 } }
end

private def w44_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def with_w44_catalog_root(& : String ->)
  root = File.tempname("crystal-click-w44-offline-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    database_uuid = "c4f6281a-9e22-4be4-9c17-8c21e16e70d1"
    table_uuid = "0f1e2d3c-4b5a-6978-89ab-cdef01234567"
    File.write(
      File.join(root, "metadata", "lab.sql"),
      "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n"
    )
    database_path = w44_store_path(root, database_uuid)
    table_path = w44_store_path(root, table_uuid)
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n" +
      "    `pk` UInt64,\n    `plain` Array(Decimal128(2)),\n" +
      "    `maybe` Array(Nullable(Decimal128(2)))\n)\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W44_DECIMAL128_FIXTURE, File.join(table_path, "all_1_1_0"))
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::WidePart do
  it "admits only exact canonical Decimal128 Array types for scales zero through 38" do
    (0..38).each do |scale|
      CrystalClick::WidePart.supports_typed_type?("Array(Decimal(38, #{scale}))").should be_true
      CrystalClick::WidePart.supports_typed_type?("Array(Nullable(Decimal(38, #{scale})))").should be_true
    end

    {
      "Array(Decimal(38, 39))", "Array(Decimal(38, 02))", "Array(Decimal(038, 2))",
      "Array(Decimal(38,2))", "Array(Decimal(38, 2) )", "Array(Decimal128(2))",
      "Array(Nullable(Decimal(38, 39)))", "Array(Nullable(Decimal(38, 02)))",
      "Array(Nullable(Decimal128(2)))", "Array(Nullable(Nullable(Decimal(38, 2))))",
      "Array(Array(Decimal(38, 2)))", "Nullable(Array(Decimal(38, 2)))",
      "Array(Decimal(37, 2))", "Array(Decimal(76, 2))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end

    CrystalClick::WidePart.array_decimal128_scale("Array(Decimal(38, 0))").should eq(0)
    CrystalClick::WidePart.array_decimal128_scale("Array(Decimal(38, 38))").should eq(38)
    CrystalClick::WidePart.array_nullable_decimal128_scale("Array(Nullable(Decimal(38, 0)))").should eq(0)
    CrystalClick::WidePart.array_nullable_decimal128_scale("Array(Nullable(Decimal(38, 38)))").should eq(38)
    CrystalClick::WidePart.catalog_type("Array(Decimal128(0))").should eq("Array(Decimal(38, 0))")
    CrystalClick::WidePart.catalog_type("Array(Nullable(Decimal128(38)))").should eq("Array(Nullable(Decimal(38, 38)))")
    CrystalClick::WidePart.catalog_type("Array(Decimal128(02))").should_not eq("Array(Decimal(38, 2))")
    CrystalClick::WidePart.catalog_type("Array(Nullable(Decimal128(39)))").should_not eq("Array(Nullable(Decimal(38, 39)))")
  end

  it "reads stock paired Decimal128 arrays by outer marks and preserves raw Int128, NULL, and zero" do
    plain = CrystalClick::WidePart.open_typed(W44_DECIMAL128_FIXTURE, "plain")
    plain.column_type.should eq("Array(Decimal(38, 2))")
    plain.row_count.should eq(7_u64)
    plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    plain.read_array_decimal128_raw_mark_range("plain", 0, plain.mark_count).should eq(W44_STOCK_PLAIN_ROWS)
    plain.read_array_decimal128_raw_mark_range("plain", 1, 2).should eq(W44_STOCK_PLAIN_ROWS[2, 4])
    plain.read_array_decimal128_raw_mark_range("plain", 3, 1).should eq(W44_STOCK_PLAIN_ROWS[6, 1])

    maybe = CrystalClick::WidePart.open_typed(W44_DECIMAL128_FIXTURE, "maybe")
    maybe.column_type.should eq("Array(Nullable(Decimal(38, 2)))")
    maybe.row_count.should eq(7_u64)
    maybe.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    maybe.read_array_nullable_decimal128_raw_mark_range("maybe", 0, maybe.mark_count).should eq(W44_STOCK_NULLABLE_ROWS)
    maybe.read_array_nullable_decimal128_raw_mark_range("maybe", 1, 2).should eq(W44_STOCK_NULLABLE_ROWS[2, 4])

    w44_decode_stream(W44_DECIMAL128_FIXTURE, "plain.size0").should eq(w44_size_stream(W44_STOCK_PLAIN_ROWS))
    w44_decode_stream(W44_DECIMAL128_FIXTURE, "plain").should eq(w44_int128_payload(W44_STOCK_PLAIN_ROWS))
    w44_decode_stream(W44_DECIMAL128_FIXTURE, "maybe.size0").should eq(w44_size_stream(W44_STOCK_NULLABLE_ROWS))
    w44_decode_stream(W44_DECIMAL128_FIXTURE, "maybe.null").should eq(w44_null_map(W44_STOCK_NULLABLE_ROWS))
    w44_decode_stream(W44_DECIMAL128_FIXTURE, "maybe").should eq(w44_nullable_payload(W44_STOCK_NULLABLE_ROWS))
    W44_STOCK_NULLABLE_ROWS[1].should eq([nil, 0_i128, -5_i128])
    W44_STOCK_NULLABLE_ROWS[2].should eq([nil, 123_i128])
    W44_STOCK_PLAIN_ROWS[2].should eq([-W44_DECIMAL_MAX, 1_i128])
  end

  it "rejects aliases and malformed Decimal128 grammar in physical part metadata" do
    parent = File.tempname("crystal-click-w44-decimal128-array-grammar")
    Dir.mkdir(parent)
    begin
      [
        {"Array(Decimal(38, 2))", "Array(Decimal(38, 02))"},
        {"Array(Decimal(38, 2))", "Array(Decimal(38,2))"},
        {"Array(Decimal(38, 2))", "Array(Decimal128(2))"},
        {"Array(Nullable(Decimal(38, 2)))", "Array(Nullable(Decimal(38, 39)))"},
      ].each_with_index do |(canonical, malformed), index|
        bad_part = File.join(parent, "bad-grammar-#{index}")
        FileUtils.cp_r(W44_DECIMAL128_FIXTURE, bad_part)
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

  it "rejects the opposite shape and generic Int128 Array accessors" do
    plain = CrystalClick::WidePart.open_typed(W44_DECIMAL128_FIXTURE, "plain")
    maybe = CrystalClick::WidePart.open_typed(W44_DECIMAL128_FIXTURE, "maybe")
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plain.read_array_nullable_decimal128_raw_mark_range("plain", 0, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      maybe.read_array_decimal128_raw_mark_range("maybe", 0, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plain.read_array_numeric_mark_range("plain", 0, 1, Int128)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      maybe.read_array_nullable_numeric_mark_range("maybe", 0, 1, Int128)
    end

    parent = File.tempname("crystal-click-w44-array-int128-negative")
    Dir.mkdir(parent)
    begin
      keys = [1_u64, 2_u64]
      plain_rows = [[Int128::MIN, 0_i128], [] of Int128] of Array(Int128)
      nullable_rows = [[nil, 0_i128] of Int128?, [] of Int128?] of Array(Int128?)
      plain_part = File.join(parent, "plain-int128")
      CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
        plain_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        plain_rows.to_unsafe.to_slice(plain_rows.size), 1_i32
      )
      plain_int128 = CrystalClick::WidePart.open_typed(plain_part, "payload")
      plain_int128.column_type.should eq("Array(Int128)")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        plain_int128.read_array_decimal128_raw_mark_range("payload", 0, 1)
      end

      nullable_part = File.join(parent, "nullable-int128")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_numeric_pair(
        nullable_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        nullable_rows.to_unsafe.to_slice(nullable_rows.size), 1_i32
      )
      nullable_int128 = CrystalClick::WidePart.open_typed(nullable_part, "payload")
      nullable_int128.column_type.should eq("Array(Nullable(Int128))")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        nullable_int128.read_array_nullable_decimal128_raw_mark_range("payload", 0, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes exact raw Decimal128 Array payloads and nullable maps for every scale" do
    parent = File.tempname("crystal-click-w44-decimal128-array-writer")
    Dir.mkdir(parent)
    begin
      (0..38).each do |scale|
        plain_part = File.join(parent, "plain-scale-#{scale}")
        CrystalClick::WidePartWriter.write_uint64_array_decimal128_pair(
          plain_part, "pk", W44_KEYS.to_unsafe.to_slice(W44_KEYS.size), "payload",
          W44_WRITER_PLAIN_ROWS.to_unsafe.to_slice(W44_WRITER_PLAIN_ROWS.size), scale.to_i32, 2_i32
        )
        plain = CrystalClick::WidePart.open_typed(plain_part, "payload")
        plain.column_type.should eq("Array(Decimal(38, #{scale}))")
        plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
        plain.read_array_decimal128_raw_mark_range("payload", 0, plain.mark_count).should eq(W44_WRITER_PLAIN_ROWS)
        w44_decode_stream(plain_part, "payload.size0").should eq(w44_size_stream(W44_WRITER_PLAIN_ROWS))
        w44_decode_stream(plain_part, "payload").should eq(w44_int128_payload(W44_WRITER_PLAIN_ROWS))
        expect_raises(CrystalClick::UnsupportedFormatError) do
          plain.read_array_numeric_mark_range("payload", 0, 1, Int128)
        end

        nullable_part = File.join(parent, "nullable-scale-#{scale}")
        CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal128_pair(
          nullable_part, "pk", W44_KEYS.to_unsafe.to_slice(W44_KEYS.size), "payload",
          W44_WRITER_NULLABLE_ROWS.to_unsafe.to_slice(W44_WRITER_NULLABLE_ROWS.size), scale.to_i32, 2_i32
        )
        nullable = CrystalClick::WidePart.open_typed(nullable_part, "payload")
        nullable.column_type.should eq("Array(Nullable(Decimal(38, #{scale})))")
        nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
        nullable.read_array_nullable_decimal128_raw_mark_range("payload", 0, nullable.mark_count).should eq(W44_WRITER_NULLABLE_ROWS)
        w44_decode_stream(nullable_part, "payload.size0").should eq(w44_size_stream(W44_WRITER_NULLABLE_ROWS))
        w44_decode_stream(nullable_part, "payload.null").should eq(w44_null_map(W44_WRITER_NULLABLE_ROWS))
        w44_decode_stream(nullable_part, "payload").should eq(w44_nullable_payload(W44_WRITER_NULLABLE_ROWS))
        w44_nullable_payload([W44_WRITER_NULLABLE_ROWS[1]] of Array(Int128?)).should eq(Array.new(32, 0_u8))
        w44_null_map([W44_WRITER_NULLABLE_ROWS[1]] of Array(Int128?)).should eq([1_u8, 1_u8])
        expect_raises(CrystalClick::UnsupportedFormatError) do
          nullable.read_array_nullable_numeric_mark_range("payload", 0, 1, Int128)
        end
      end

      {"plain", "nullable"}.each do |shape|
        empty_part = File.join(parent, "empty-#{shape}")
        if shape == "plain"
          rows = Array.new(W44_KEYS.size) { [] of Int128 }
          CrystalClick::WidePartWriter.write_uint64_array_decimal128_pair(
            empty_part, "pk", W44_KEYS.to_unsafe.to_slice(W44_KEYS.size), "payload",
            rows.to_unsafe.to_slice(rows.size), 0_i32, 2_i32
          )
          File.size(File.join(empty_part, "#{CrystalClick::StreamName.hash("payload")}.bin")).should eq(0)
        else
          rows = Array.new(W44_KEYS.size) { [] of Int128? }
          CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal128_pair(
            empty_part, "pk", W44_KEYS.to_unsafe.to_slice(W44_KEYS.size), "payload",
            rows.to_unsafe.to_slice(rows.size), 38_i32, 2_i32
          )
          File.size(File.join(empty_part, "#{CrystalClick::StreamName.hash("payload")}.bin")).should eq(0)
          File.size(File.join(empty_part, "#{CrystalClick::StreamName.hash("payload.null")}.bin")).should eq(0)
        end
      end

      invalid_plain = File.join(parent, "invalid-plain-scale")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_decimal128_pair(
          invalid_plain, "pk", W44_KEYS.to_unsafe.to_slice(W44_KEYS.size), "payload",
          W44_WRITER_PLAIN_ROWS.to_unsafe.to_slice(W44_WRITER_PLAIN_ROWS.size), 39_i32, 2_i32
        )
      end
      File.exists?(invalid_plain).should be_false

      invalid_nullable = File.join(parent, "invalid-nullable-scale")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal128_pair(
          invalid_nullable, "pk", W44_KEYS.to_unsafe.to_slice(W44_KEYS.size), "payload",
          W44_WRITER_NULLABLE_ROWS.to_unsafe.to_slice(W44_WRITER_NULLABLE_ROWS.size), -1_i32, 2_i32
        )
      end
      File.exists?(invalid_nullable).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "materializes exact Decimal128 Array aliases in catalog batches and caller-owned projections" do
    with_w44_catalog_root do |root|
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"plain", "Array(Decimal128(2))"},
        {"maybe", "Array(Nullable(Decimal128(2)))"},
      ])

      plain_rows = [] of Array(Int128)
      nullable_rows = [] of Array(Int128?)
      table.scan_typed(["plain", "maybe"], batch_rows: 3) do |batch|
        batch.column_type_for("plain").should eq("Array(Decimal(38, 2))")
        batch.column_type_for("maybe").should eq("Array(Nullable(Decimal(38, 2)))")
        plain_rows.concat(batch.array_decimal128_raw_for("plain").map(&.dup))
        nullable_rows.concat(batch.array_nullable_decimal128_raw_for("maybe").map(&.dup))
      end
      plain_rows.should eq(W44_STOCK_PLAIN_ROWS)
      nullable_rows.should eq(W44_STOCK_NULLABLE_ROWS)

      later_rows = [] of Array(Int128?)
      table.scan_typed_window(["maybe"], 4_u64, max_rows: 3) do |batch|
        later_rows.concat(batch.array_nullable_decimal128_raw_for("maybe").map(&.dup))
      end
      later_rows.should eq(W44_STOCK_NULLABLE_ROWS[4, 3])

      projected_plain = table["plain"].values.map { |value| value.as(Array(Int128)) }
      projected_nullable = table["maybe"].values.map { |value| value.as(Array(Int128?)) }
      projected_plain.should eq(W44_STOCK_PLAIN_ROWS)
      projected_nullable.should eq(W44_STOCK_NULLABLE_ROWS)
      projected_plain[1][0] = 777_i128
      projected_nullable[1][1] = 888_i128
      table["plain"].values.map { |value| value.as(Array(Int128)) }.should eq(W44_STOCK_PLAIN_ROWS)
      table["maybe"].values.map { |value| value.as(Array(Int128?)) }.should eq(W44_STOCK_NULLABLE_ROWS)
    end
  end
end
