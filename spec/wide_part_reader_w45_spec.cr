require "./spec_helper"

W45_DECIMAL256_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_decimal256_w45/part", __DIR__)
W45_KEYS               = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]

private def w45_spec_coefficient(text : String) : CrystalClick::Decimal256Value
  negative = text.starts_with?('-')
  digits = negative ? text[1..] : text
  words = [0_u64, 0_u64, 0_u64, 0_u64]
  digits.each_char do |character|
    raise "not a coefficient: #{text}" unless character.ascii_number?
    carry = (character.ord - '0'.ord).to_u128
    4.times do |index|
      product = words[index].to_u128 * 10_u128 + carry
      words[index] = (product & UInt64::MAX.to_u128).to_u64
      carry = product >> 64
    end
    raise "coefficient overflow: #{text}" unless carry == 0
  end
  if negative
    carry = true
    4.times do |index|
      inverted = ~words[index]
      if carry && inverted == UInt64::MAX
        words[index] = 0_u64
      elsif carry
        words[index] = inverted + 1_u64
        carry = false
      else
        words[index] = inverted
      end
    end
  end
  CrystalClick::Decimal256Value.from_words(words[0], words[1], words[2], words[3])
end

W45_SPEC_DECIMAL_MAX     = w45_spec_coefficient("9" * 76)
W45_SPEC_NEG_DECIMAL_MAX = w45_spec_coefficient("-" + "9" * 76)
W45_SPEC_HIGH_WORD       = w45_spec_coefficient("1234567890123456789012345678901234567890123456789012345678901234567890123456")
W45_SPEC_NEG_HIGH_WORD   = w45_spec_coefficient("-1234567890123456789012345678901234567890123456789012345678901234567890123456")

W45_STOCK_PLAIN_ROWS = [
  [] of CrystalClick::Decimal256Value,
  [w45_spec_coefficient("-1234"), w45_spec_coefficient("0"), w45_spec_coefficient("9999")],
  [W45_SPEC_NEG_DECIMAL_MAX, w45_spec_coefficient("1")],
  [] of CrystalClick::Decimal256Value,
  [w45_spec_coefficient("-123")],
  [w45_spec_coefficient("1234"), w45_spec_coefficient("-1")],
  [] of CrystalClick::Decimal256Value,
] of Array(CrystalClick::Decimal256Value)

W45_STOCK_NULLABLE_ROWS = [
  [] of CrystalClick::Decimal256Value?,
  [nil, w45_spec_coefficient("0"), w45_spec_coefficient("-5")] of CrystalClick::Decimal256Value?,
  [nil, w45_spec_coefficient("123")] of CrystalClick::Decimal256Value?,
  [] of CrystalClick::Decimal256Value?,
  [nil, nil] of CrystalClick::Decimal256Value?,
  [w45_spec_coefficient("0"), nil] of CrystalClick::Decimal256Value?,
  [] of CrystalClick::Decimal256Value?,
] of Array(CrystalClick::Decimal256Value?)

private def w45_spec_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def with_w45_catalog_root(& : String ->)
  root = File.tempname("crystal-click-w45-offline-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    database_uuid = "754d2ea1-0a90-44d8-ae65-0b5a8a610045"
    table_uuid = "b2c09745-9c3a-4fd5-8a26-f31b0a8e45d1"
    File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
    database_path = w45_spec_store_path(root, database_uuid)
    table_path = w45_spec_store_path(root, table_uuid)
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n" +
      "    `pk` UInt64,\n    `plain` Array(Decimal256(2)),\n" +
      "    `maybe` Array(Nullable(Decimal256(2)))\n)\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W45_DECIMAL256_FIXTURE, File.join(table_path, "all_1_1_0"))
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w45_decode_stream(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  encoded = File.read(path).to_slice
  encoded.empty? ? [] of UInt8 : CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w45_size_stream(values : Array(Array(T))) : Array(UInt8) forall T
  bytes = [] of UInt8
  values.each do |row|
    size = row.size.to_u64
    8.times { |index| bytes << ((size >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w45_decimal_payload(values : Array(Array(CrystalClick::Decimal256Value))) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |row|
    row.each do |value|
      16.times { |index| bytes << ((value.low >> (index * 8)) & 0xff_u128).to_u8 }
      16.times { |index| bytes << ((value.high >> (index * 8)) & 0xff_u128).to_u8 }
    end
  end
  bytes
end

private def w45_nullable_payload(values : Array(Array(CrystalClick::Decimal256Value?))) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |row|
    row.each do |value|
      raw = value || CrystalClick::Decimal256Value.new(0_u128, 0_u128)
      16.times { |index| bytes << ((raw.low >> (index * 8)) & 0xff_u128).to_u8 }
      16.times { |index| bytes << ((raw.high >> (index * 8)) & 0xff_u128).to_u8 }
    end
  end
  bytes
end

private def w45_null_map(values : Array(Array(CrystalClick::Decimal256Value?))) : Array(UInt8)
  values.flat_map { |row| row.map { |value| value.nil? ? 1_u8 : 0_u8 } }
end

describe CrystalClick::WidePart do
  it "admits canonical Decimal256 Array metadata at scale zero" do
    CrystalClick::WidePart.supports_typed_type?("Array(Decimal(76, 0))").should be_true
  end

  it "admits only canonical Decimal256 Array storage scales and normalizes aliases only at the catalog boundary" do
    (0..76).each do |scale|
      CrystalClick::WidePart.supports_typed_type?("Array(Decimal(76, #{scale}))").should be_true
      CrystalClick::WidePart.supports_typed_type?("Array(Nullable(Decimal(76, #{scale})))").should be_true
    end
    CrystalClick::WidePart.array_decimal256_scale("Array(Decimal(76, 0))").should eq(0)
    CrystalClick::WidePart.array_decimal256_scale("Array(Decimal(76, 76))").should eq(76)
    CrystalClick::WidePart.array_nullable_decimal256_scale("Array(Nullable(Decimal(76, 0)))").should eq(0)
    CrystalClick::WidePart.array_nullable_decimal256_scale("Array(Nullable(Decimal(76, 76)))").should eq(76)
    CrystalClick::WidePart.catalog_type("Array(Decimal256(0))").should eq("Array(Decimal(76, 0))")
    CrystalClick::WidePart.catalog_type("Array(Nullable(Decimal256(76)))").should eq("Array(Nullable(Decimal(76, 76)))")

    {
      "Array(Decimal(76, 77))", "Array(Decimal(76, 076))", "Array(Decimal(076, 2))",
      "Array(Decimal(76,2))", "Array(Decimal(76, 2) )", "Array(Decimal256(2))",
      "Array(Nullable(Decimal(76, 77)))", "Array(Nullable(Decimal256(02)))",
      "Array(Nullable(Nullable(Decimal(76, 2))))",
      "Nullable(Array(Decimal(76, 2)))", "Array(Decimal(75, 2))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
    CrystalClick::WidePart.catalog_type("Array(Decimal256(02))").should_not eq("Array(Decimal(76, 2))")
    CrystalClick::WidePart.catalog_type("Array(Nullable(Decimal256(77)))").should_not eq("Array(Nullable(Decimal(76, 77)))")
  end

  it "reads stock Decimal256 Array streams exactly across marks and preserves NULL versus zero" do
    plain = CrystalClick::WidePart.open_typed(W45_DECIMAL256_FIXTURE, "plain")
    plain.column_type.should eq("Array(Decimal(76, 2))")
    plain.row_count.should eq(7_u64)
    plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    plain.read_array_decimal256_raw_mark_range("plain", 0, plain.mark_count).should eq(W45_STOCK_PLAIN_ROWS)
    plain.read_array_decimal256_raw_mark_range("plain", 1, 2).should eq(W45_STOCK_PLAIN_ROWS[2, 4])
    plain.read_array_decimal256_raw_mark_range("plain", 3, 1).should eq(W45_STOCK_PLAIN_ROWS[6, 1])

    maybe = CrystalClick::WidePart.open_typed(W45_DECIMAL256_FIXTURE, "maybe")
    maybe.column_type.should eq("Array(Nullable(Decimal(76, 2)))")
    maybe.row_count.should eq(7_u64)
    maybe.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    maybe.read_array_nullable_decimal256_raw_mark_range("maybe", 0, maybe.mark_count).should eq(W45_STOCK_NULLABLE_ROWS)
    maybe.read_array_nullable_decimal256_raw_mark_range("maybe", 1, 2).should eq(W45_STOCK_NULLABLE_ROWS[2, 4])

    w45_decode_stream(W45_DECIMAL256_FIXTURE, "plain.size0").should eq(w45_size_stream(W45_STOCK_PLAIN_ROWS))
    w45_decode_stream(W45_DECIMAL256_FIXTURE, "plain").should eq(w45_decimal_payload(W45_STOCK_PLAIN_ROWS))
    w45_decode_stream(W45_DECIMAL256_FIXTURE, "maybe.size0").should eq(w45_size_stream(W45_STOCK_NULLABLE_ROWS))
    w45_decode_stream(W45_DECIMAL256_FIXTURE, "maybe.null").should eq(w45_null_map(W45_STOCK_NULLABLE_ROWS))
    w45_decode_stream(W45_DECIMAL256_FIXTURE, "maybe").should eq(w45_nullable_payload(W45_STOCK_NULLABLE_ROWS))
    W45_STOCK_NULLABLE_ROWS[1].should eq([nil, w45_spec_coefficient("0"), w45_spec_coefficient("-5")])
    W45_STOCK_NULLABLE_ROWS[4].should eq([nil, nil])
    w45_nullable_payload([W45_STOCK_NULLABLE_ROWS[4]] of Array(CrystalClick::Decimal256Value?)).should eq(Array.new(64, 0_u8))
    w45_null_map([W45_STOCK_NULLABLE_ROWS[4]] of Array(CrystalClick::Decimal256Value?)).should eq([1_u8, 1_u8])
  end

  it "rejects aliases and malformed Decimal256 Array grammar in physical metadata" do
    parent = File.tempname("crystal-click-w45-decimal256-array-grammar")
    Dir.mkdir(parent)
    begin
      [
        {"Array(Decimal(76, 2))", "Array(Decimal(76, 02))"},
        {"Array(Decimal(76, 2))", "Array(Decimal256(2))"},
        {"Array(Decimal(76, 2))", "Array(Decimal(75, 2))"},
        {"Array(Nullable(Decimal(76, 2)))", "Array(Nullable(Decimal(76, 77)))"},
      ].each_with_index do |(canonical, malformed), index|
        bad_part = File.join(parent, "bad-grammar-#{index}")
        FileUtils.cp_r(W45_DECIMAL256_FIXTURE, bad_part)
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

  it "rejects opposite array shapes, wrong leaf types, and generic 256-bit integer accessors" do
    plain = CrystalClick::WidePart.open_typed(W45_DECIMAL256_FIXTURE, "plain")
    maybe = CrystalClick::WidePart.open_typed(W45_DECIMAL256_FIXTURE, "maybe")
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plain.read_array_nullable_decimal256_raw_mark_range("plain", 0, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      maybe.read_array_decimal256_raw_mark_range("maybe", 0, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plain.read_array_numeric_mark_range("plain", 0, 1, CrystalClick::Int256Value)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      maybe.read_array_nullable_numeric_mark_range("maybe", 0, 1, CrystalClick::Int256Value)
    end

    parent = File.tempname("crystal-click-w45-array-int256-negative")
    Dir.mkdir(parent)
    begin
      keys = [1_u64, 2_u64]
      rows = [
        [CrystalClick::Int256Value.from_words(1_u64, 0_u64, 0_u64, 0_u64)],
        [] of CrystalClick::Int256Value,
      ] of Array(CrystalClick::Int256Value)
      part = File.join(parent, "int256")
      CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        rows.to_unsafe.to_slice(rows.size), 1_i32
      )
      int256 = CrystalClick::WidePart.open_typed(part, "payload")
      int256.column_type.should eq("Array(Int256)")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        int256.read_array_decimal256_raw_mark_range("payload", 0, 1)
      end
      int256.read_array_numeric_mark_range("payload", 0, 1, CrystalClick::Int256Value).should eq(rows[0, 1])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "materializes arrays through catalog aliases, batches, windows, and caller-owned projections" do
    with_w45_catalog_root do |root|
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"plain", "Array(Decimal256(2))"},
        {"maybe", "Array(Nullable(Decimal256(2)))"},
      ])
      plain_rows = [] of Array(CrystalClick::Decimal256Value)
      nullable_rows = [] of Array(CrystalClick::Decimal256Value?)
      table.scan_typed(["plain", "maybe"], batch_rows: 3) do |batch|
        batch.column_type_for("plain").should eq("Array(Decimal(76, 2))")
        batch.column_type_for("maybe").should eq("Array(Nullable(Decimal(76, 2)))")
        plain_rows.concat(batch.array_decimal256_raw_for("plain").map(&.dup))
        nullable_rows.concat(batch.array_nullable_decimal256_raw_for("maybe").map(&.dup))
      end
      plain_rows.should eq(W45_STOCK_PLAIN_ROWS)
      nullable_rows.should eq(W45_STOCK_NULLABLE_ROWS)

      later_rows = [] of Array(CrystalClick::Decimal256Value?)
      table.scan_typed_window(["maybe"], 4_u64, max_rows: 3) do |batch|
        later_rows.concat(batch.array_nullable_decimal256_raw_for("maybe").map(&.dup))
      end
      later_rows.should eq(W45_STOCK_NULLABLE_ROWS[4, 3])
      table["plain"].values.map { |value| value.as(Array(CrystalClick::Decimal256Value)) }.should eq(W45_STOCK_PLAIN_ROWS)
      table["maybe"].values.map { |value| value.as(Array(CrystalClick::Decimal256Value?)) }.should eq(W45_STOCK_NULLABLE_ROWS)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes exact Decimal256 Array streams for every scale and preserves 32-byte nullable defaults" do
    parent = File.tempname("crystal-click-w45-decimal256-array-writer")
    Dir.mkdir(parent)
    begin
      plain_rows = [
        [W45_SPEC_NEG_DECIMAL_MAX, w45_spec_coefficient("-1"), w45_spec_coefficient("0"), w45_spec_coefficient("1"), W45_SPEC_DECIMAL_MAX],
        [] of CrystalClick::Decimal256Value,
        [W45_SPEC_HIGH_WORD, W45_SPEC_NEG_HIGH_WORD],
        [] of CrystalClick::Decimal256Value,
        [w45_spec_coefficient("-123")],
        [w45_spec_coefficient("0"), w45_spec_coefficient("1")],
        [] of CrystalClick::Decimal256Value,
      ] of Array(CrystalClick::Decimal256Value)
      nullable_rows = [
        [nil, W45_SPEC_NEG_DECIMAL_MAX, w45_spec_coefficient("0"), W45_SPEC_DECIMAL_MAX] of CrystalClick::Decimal256Value?,
        [nil, nil] of CrystalClick::Decimal256Value?,
        [nil, w45_spec_coefficient("-1"), w45_spec_coefficient("0")] of CrystalClick::Decimal256Value?,
        [] of CrystalClick::Decimal256Value?,
        [w45_spec_coefficient("-123"), nil] of CrystalClick::Decimal256Value?,
        [w45_spec_coefficient("0"), nil] of CrystalClick::Decimal256Value?,
        [] of CrystalClick::Decimal256Value?,
      ] of Array(CrystalClick::Decimal256Value?)

      (0..76).each do |scale|
        plain_part = File.join(parent, "plain-scale-#{scale}")
        CrystalClick::WidePartWriter.write_uint64_array_decimal256_pair(
          plain_part, "pk", W45_KEYS.to_unsafe.to_slice(W45_KEYS.size), "payload",
          plain_rows.to_unsafe.to_slice(plain_rows.size), scale.to_i32, 2_i32
        )
        plain = CrystalClick::WidePart.open_typed(plain_part, "payload")
        plain.column_type.should eq("Array(Decimal(76, #{scale}))")
        plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
        plain.read_array_decimal256_raw_mark_range("payload", 0, plain.mark_count).should eq(plain_rows)
        w45_decode_stream(plain_part, "payload.size0").should eq(w45_size_stream(plain_rows))
        w45_decode_stream(plain_part, "payload").should eq(w45_decimal_payload(plain_rows))

        nullable_part = File.join(parent, "nullable-scale-#{scale}")
        CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal256_pair(
          nullable_part, "pk", W45_KEYS.to_unsafe.to_slice(W45_KEYS.size), "payload",
          nullable_rows.to_unsafe.to_slice(nullable_rows.size), scale.to_i32, 2_i32
        )
        nullable = CrystalClick::WidePart.open_typed(nullable_part, "payload")
        nullable.column_type.should eq("Array(Nullable(Decimal(76, #{scale})))")
        nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
        nullable.read_array_nullable_decimal256_raw_mark_range("payload", 0, nullable.mark_count).should eq(nullable_rows)
        w45_decode_stream(nullable_part, "payload.size0").should eq(w45_size_stream(nullable_rows))
        w45_decode_stream(nullable_part, "payload.null").should eq(w45_null_map(nullable_rows))
        w45_decode_stream(nullable_part, "payload").should eq(w45_nullable_payload(nullable_rows))
      end

      raw_min = CrystalClick::Decimal256Value.from_words(0_u64, 0_u64, 0_u64, 0x8000000000000000_u64)
      raw_max = CrystalClick::Decimal256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, 0x7fffffffffffffff_u64)
      raw_rows = [[raw_min, raw_max], [] of CrystalClick::Decimal256Value] of Array(CrystalClick::Decimal256Value)
      raw_part = File.join(parent, "raw-extrema-scale-0")
      CrystalClick::WidePartWriter.write_uint64_array_decimal256_pair(
        raw_part, "pk", [1_u64, 2_u64].to_unsafe.to_slice(2), "payload",
        raw_rows.to_unsafe.to_slice(raw_rows.size), 0_i32, 1_i32
      )
      CrystalClick::WidePart.open_typed(raw_part, "payload")
        .read_array_decimal256_raw_mark_range("payload", 0, 2).should eq(raw_rows)

      all_empty_plain = Array.new(W45_KEYS.size) { [] of CrystalClick::Decimal256Value }
      empty_plain_path = File.join(parent, "all-empty-plain")
      CrystalClick::WidePartWriter.write_uint64_array_decimal256_pair(
        empty_plain_path, "pk", W45_KEYS.to_unsafe.to_slice(W45_KEYS.size), "payload",
        all_empty_plain.to_unsafe.to_slice(all_empty_plain.size), 0_i32, 2_i32
      )
      File.size(File.join(empty_plain_path, "#{CrystalClick::StreamName.hash("payload")}.bin")).should eq(0)

      all_empty_nullable = Array.new(W45_KEYS.size) { [] of CrystalClick::Decimal256Value? }
      empty_nullable_path = File.join(parent, "all-empty-nullable")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal256_pair(
        empty_nullable_path, "pk", W45_KEYS.to_unsafe.to_slice(W45_KEYS.size), "payload",
        all_empty_nullable.to_unsafe.to_slice(all_empty_nullable.size), 76_i32, 2_i32
      )
      File.size(File.join(empty_nullable_path, "#{CrystalClick::StreamName.hash("payload")}.bin")).should eq(0)
      File.size(File.join(empty_nullable_path, "#{CrystalClick::StreamName.hash("payload.null")}.bin")).should eq(0)

      all_null = Array.new(W45_KEYS.size) { [nil, nil] of CrystalClick::Decimal256Value? }
      all_null_part = File.join(parent, "all-null")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal256_pair(
        all_null_part, "pk", W45_KEYS.to_unsafe.to_slice(W45_KEYS.size), "payload",
        all_null.to_unsafe.to_slice(all_null.size), 76_i32, 2_i32
      )
      w45_decode_stream(all_null_part, "payload.null").should eq(Array.new(W45_KEYS.size * 2, 1_u8))
      w45_decode_stream(all_null_part, "payload").should eq(Array.new(W45_KEYS.size * 64, 0_u8))

      invalid_scale = File.join(parent, "invalid-scale")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_decimal256_pair(
          invalid_scale, "pk", W45_KEYS.to_unsafe.to_slice(W45_KEYS.size), "payload",
          plain_rows.to_unsafe.to_slice(plain_rows.size), 77_i32, 2_i32
        )
      end
      File.exists?(invalid_scale).should be_false

      invalid_nullable_scale = File.join(parent, "invalid-nullable-scale")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal256_pair(
          invalid_nullable_scale, "pk", W45_KEYS.to_unsafe.to_slice(W45_KEYS.size), "payload",
          nullable_rows.to_unsafe.to_slice(nullable_rows.size), -1_i32, 2_i32
        )
      end
      File.exists?(invalid_nullable_scale).should be_false

      before_mismatch = Dir.children(parent).sort
      mismatched_rows = plain_rows[0, plain_rows.size - 1]
      mismatch_path = File.join(parent, "mismatched-row-count")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_decimal256_pair(
          mismatch_path, "pk", W45_KEYS.to_unsafe.to_slice(W45_KEYS.size), "payload",
          mismatched_rows.to_unsafe.to_slice(mismatched_rows.size), 2_i32, 2_i32
        )
      end
      File.exists?(mismatch_path).should be_false
      Dir.children(parent).sort.should eq(before_mismatch)

      unsorted_path = File.join(parent, "unsorted-keys")
      unsorted_keys = [2_u64, 1_u64]
      two_rows = plain_rows[0, 2]
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_decimal256_pair(
          unsorted_path, "pk", unsorted_keys.to_unsafe.to_slice(unsorted_keys.size), "payload",
          two_rows.to_unsafe.to_slice(two_rows.size), 0_i32, 1_i32
        )
      end
      File.exists?(unsorted_path).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
