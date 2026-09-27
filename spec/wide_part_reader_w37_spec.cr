require "./spec_helper"

W37_INTEGER_FIXTURE = File.expand_path("../test/fixtures/public/wide_integer256/part", __DIR__)
W37_INTEGER_KEYS    = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64, 9_u64, 10_u64, 11_u64, 12_u64, 13_u64]

W37_INT256_WORDS = [
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0x0000000000000001_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x8000000000000000_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0x7fffffffffffffff_u64},
  {0xffffffffffffffd6_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0x000000000000002a_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0xc000000000000000_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x4000000000000000_u64},
  {0x55205cd751c67eeb_u64, 0xa31f165a9fea013a_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0xaadfa328ae398115_u64, 0x5ce0e9a56015fec5_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x8000000000000000_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0x7fffffffffffffff_u64},
]

W37_UINT256_WORDS = [
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0x0000000000000001_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x8000000000000000_u64},
  {0x0000000000000001_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x8000000000000000_u64},
  {0xfffffffffffffffe_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0x7fffffffffffffff_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x4000000000000000_u64},
  {0x0000000000000002_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x8000000000000000_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0x7fffffffffffffff_u64},
  {0xfffffffffffffffd_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0x000000000000002a_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
]

private def w37_int256_values : Array(CrystalClick::Int256Value)
  Array(CrystalClick::Int256Value).new(W37_INT256_WORDS.size) do |index|
    words = W37_INT256_WORDS[index]
    CrystalClick::Int256Value.from_words(words[0], words[1], words[2], words[3])
  end
end

private def w37_uint256_values : Array(CrystalClick::UInt256Value)
  Array(CrystalClick::UInt256Value).new(W37_UINT256_WORDS.size) do |index|
    words = W37_UINT256_WORDS[index]
    CrystalClick::UInt256Value.from_words(words[0], words[1], words[2], words[3])
  end
end

private def w37_words_payload(words : Array({UInt64, UInt64, UInt64, UInt64})) : Array(UInt8)
  bytes = [] of UInt8
  words.each do |row|
    {row[0], row[1], row[2], row[3]}.each do |word|
      8.times { |index| bytes << ((word >> (index * 8)) & 0xff_u64).to_u8 }
    end
  end
  bytes
end

private def w37_decode_stream(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w37_mark_entries(part : String, logical_name : String) : Array({UInt64, UInt64, UInt64})
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  bytes = File.read(path).to_slice
  raise "invalid W37 .mrk2 stream: #{logical_name}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array({UInt64, UInt64, UInt64}).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    values = {0_u64, 0_u64, 0_u64}
    3.times do |word|
      value = 0_u64
      8.times { |byte| value |= bytes[offset + word * 8 + byte].to_u64 << (byte * 8) }
      values = word == 0 ? {value, values[1], values[2]} : word == 1 ? {values[0], value, values[2]} : {values[0], values[1], value}
    end
    values
  end
end

private def w37_assert_stock_marks(logical_name : String, width : Int32) : Nil
  raw_offsets = [0_u64, 2_u64, 4_u64, 6_u64, 8_u64, 10_u64, 12_u64, 13_u64].map { |rows| rows * width.to_u64 }
  row_counts = [2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
  expected = Array({UInt64, UInt64, UInt64}).new(8) do |index|
    {0_u64, raw_offsets[index], row_counts[index]}
  end
  w37_mark_entries(W37_INTEGER_FIXTURE, logical_name).should eq(expected)
end

private def w37_frame_offsets(part : String, logical_name : String) : Array(UInt64)
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")).to_slice
  offsets = [0_u64]
  offset = 0_i64
  while offset < bytes.size.to_i64
    frame = CrystalClick::CompressedBlock.decode_frame(bytes, offset)
    raise "W37 writer frame did not advance" if frame.end_offset <= offset
    offset = frame.end_offset
    offsets << offset.to_u64
  end
  raise "W37 writer stream has trailing bytes" unless offset == bytes.size.to_i64
  offsets
end

private def w37_assert_writer_marks(part : String, logical_name : String) : Nil
  offsets = w37_frame_offsets(part, logical_name)
  offsets.size.should eq(8)
  row_counts = [2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
  expected = Array({UInt64, UInt64, UInt64}).new(8) do |index|
    {offsets[index], 0_u64, row_counts[index]}
  end
  w37_mark_entries(part, logical_name).should eq(expected)
end

private def w37_assert_writer_part(part : String, type_name : String, values_size : Int) : Nil
  File.read(File.join(part, "columns.txt")).should eq(
    "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
  )
  File.read(File.join(part, "columns_substreams.txt")).should eq(
    "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `payload`:\n\tpayload\n"
  )
  File.read(File.join(part, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
  File.read(File.join(part, "count.txt")).should eq(values_size.to_s)
  CrystalClick::WidePart.open_typed(part, "payload").mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
  w37_assert_writer_marks(part, "pk")
  w37_assert_writer_marks(part, "payload")
end

describe CrystalClick::WidePart do
  it "keeps raw signed and unsigned 256-bit values distinct and admits only bare scalars" do
    sizeof(CrystalClick::Int256Value).should eq(32)
    sizeof(CrystalClick::UInt256Value).should eq(32)

    signed = CrystalClick::Int256Value.from_words(0_u64, 0_u64, 0_u64, 0x8000000000000000_u64)
    unsigned = CrystalClick::UInt256Value.from_words(0_u64, 0_u64, 0_u64, 0x8000000000000000_u64)
    signed.low.should eq(0_u128)
    signed.high.should eq(0x80000000000000000000000000000000_u128)
    unsigned.low.should eq(0_u128)
    unsigned.high.should eq(0x80000000000000000000000000000000_u128)

    CrystalClick::WidePart.supports_typed_type?("Int256").should be_true
    CrystalClick::WidePart.supports_typed_type?("UInt256").should be_true
    CrystalClick::WidePart.supports_numeric_type?("Int256").should be_false
    CrystalClick::WidePart.supports_numeric_type?("UInt256").should be_false
    CrystalClick::WidePart.supports_typed_type?("Nullable(Int256)").should be_false
    CrystalClick::WidePart.supports_typed_type?("Nullable(UInt256)").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(Int256)").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(UInt256)").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(Nullable(Int256))").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(Nullable(UInt256))").should be_false
    CrystalClick::WidePart.supports_typed_type?("Nullable(Array(Int256))").should be_false
    CrystalClick::WidePart.supports_typed_type?("Nullable(Array(UInt256))").should be_false
    CrystalClick::WidePart.supports_typed_type?("Decimal(76, 0)").should be_true
    CrystalClick::WidePart.catalog_type("Int256").should eq("Int256")
    CrystalClick::WidePart.catalog_type("UInt256").should eq("UInt256")
    CrystalClick::WidePart.catalog_type("Nullable(Int256)").should be_nil
    CrystalClick::WidePart.catalog_type("Nullable(UInt256)").should be_nil
  end

  it "reads exact signed and unsigned values from a stock part without Decimal256 aliasing" do
    signed = CrystalClick::WidePart.open_typed(W37_INTEGER_FIXTURE, "i")
    unsigned = CrystalClick::WidePart.open_typed(W37_INTEGER_FIXTURE, "u")
    signed.column_type.should eq("Int256")
    unsigned.column_type.should eq("UInt256")
    signed.row_count.should eq(13_u64)
    unsigned.row_count.should eq(13_u64)
    signed.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
    unsigned.mark_row_counts.should eq(signed.mark_row_counts)

    signed.read_int256_raw_mark_range("i", 0, signed.mark_count).should eq(w37_int256_values)
    unsigned.read_uint256_raw_mark_range("u", 0, unsigned.mark_count).should eq(w37_uint256_values)
    signed.read_int256_raw_mark_range("i", 1, 4).should eq(w37_int256_values[2, 8])
    unsigned.read_uint256_raw_mark_range("u", 2, 2).should eq(w37_uint256_values[4, 4])
    w37_decode_stream(W37_INTEGER_FIXTURE, "i").should eq(w37_words_payload(W37_INT256_WORDS))
    w37_decode_stream(W37_INTEGER_FIXTURE, "u").should eq(w37_words_payload(W37_UINT256_WORDS))
    w37_assert_stock_marks("pk", 8)
    w37_assert_stock_marks("i", 32)
    w37_assert_stock_marks("u", 32)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      signed.read_uint256_raw_mark_range("i", 0, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      unsigned.read_int256_raw_mark_range("u", 0, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      signed.read_decimal256_raw_mark_range("i", 0, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      signed.read_numeric_mark_range("i", 0, 1, CrystalClick::Int256Value)
    end
  end
end

describe CrystalClick::WidePartTable do
  it "materializes distinct raw values in full batches and bounded row windows" do
    parent = File.tempname("crystal-click-w37-table-batch")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    begin
      FileUtils.cp_r(W37_INTEGER_FIXTURE, part)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "i", "u"])
      observed = [] of {UInt64, CrystalClick::Int256Value, CrystalClick::UInt256Value}
      table.scan_typed(batch_rows: 3) do |batch|
        keys = batch.values_for("pk", UInt64)
        signed = batch.int256_raw_for("i")
        unsigned = batch.uint256_raw_for("u")
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.uint256_raw_for("i") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.int256_raw_for("u") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.values_for("i", CrystalClick::Int256Value) }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.values_for("u", CrystalClick::UInt256Value) }
        keys.each_index { |index| observed << {keys[index], signed[index], unsigned[index]} }
      end
      observed.should eq(Array({UInt64, CrystalClick::Int256Value, CrystalClick::UInt256Value}).new(13) do |index|
        {W37_INTEGER_KEYS[index], w37_int256_values[index], w37_uint256_values[index]}
      end)

      window = [] of {UInt64, CrystalClick::Int256Value, CrystalClick::UInt256Value}
      table.scan_typed_window(3_u64, max_rows: 5) do |batch|
        keys = batch.values_for("pk", UInt64)
        signed = batch.int256_raw_for("i")
        unsigned = batch.uint256_raw_for("u")
        keys.each_index { |index| window << {keys[index], signed[index], unsigned[index]} }
      end
      expected_window = Array({UInt64, CrystalClick::Int256Value, CrystalClick::UInt256Value}).new(5) do |index|
        row = index + 3
        {W37_INTEGER_KEYS[row], w37_int256_values[row], w37_uint256_values[row]}
      end
      window.should eq(expected_window)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "fails before a selected table callback when a raw 256-bit stream is corrupt" do
    parent = File.tempname("crystal-click-w37-corruption")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    begin
      FileUtils.cp_r(W37_INTEGER_FIXTURE, part)
      path = File.join(part, "#{CrystalClick::StreamName.hash("i")}.bin")
      bytes = File.read(path).to_slice.dup
      # Preserve physical length while invalidating the first LZ4 frame sizes.
      bytes[17] = 0_u8
      bytes[18] = 0_u8
      bytes[19] = 0_u8
      bytes[20] = 0_u8
      File.write(path, bytes)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        corrupted = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "i"])
        corrupted.scan_typed_candidate_marks([[0]]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes exact raw Int256 and UInt256 columns with independent word-byte oracles" do
    parent = File.tempname("crystal-click-w37-integer-writers")
    Dir.mkdir(parent)
    signed_part = File.join(parent, "signed")
    unsigned_part = File.join(parent, "unsigned")
    signed_values = w37_int256_values
    unsigned_values = w37_uint256_values
    begin
      CrystalClick::WidePartWriter.write_uint64_int256_pair(
        signed_part, "pk", W37_INTEGER_KEYS.to_unsafe.to_slice(W37_INTEGER_KEYS.size), "payload",
        signed_values.to_unsafe.to_slice(signed_values.size), 2
      ).should eq(signed_part)
      CrystalClick::WidePartWriter.write_uint64_uint256_pair(
        unsigned_part, "pk", W37_INTEGER_KEYS.to_unsafe.to_slice(W37_INTEGER_KEYS.size), "payload",
        unsigned_values.to_unsafe.to_slice(unsigned_values.size), 2
      ).should eq(unsigned_part)

      w37_assert_writer_part(signed_part, "Int256", 13)
      w37_assert_writer_part(unsigned_part, "UInt256", 13)
      w37_decode_stream(signed_part, "payload").should eq(w37_words_payload(W37_INT256_WORDS))
      w37_decode_stream(unsigned_part, "payload").should eq(w37_words_payload(W37_UINT256_WORDS))
      CrystalClick::WidePart.open_typed(signed_part, "payload")
        .read_int256_raw_mark_range("payload", 0, 7).should eq(signed_values)
      CrystalClick::WidePart.open_typed(unsigned_part, "payload")
        .read_uint256_raw_mark_range("payload", 0, 7).should eq(unsigned_values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects inferred 256-bit writers and invalid explicit inputs without publishing" do
    parent = File.tempname("crystal-click-w37-writer-preflight")
    Dir.mkdir(parent)
    signed_values = w37_int256_values
    unsigned_values = w37_uint256_values
    begin
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          File.join(parent, "inferred-int256"), "pk", W37_INTEGER_KEYS.to_unsafe.to_slice(13), "payload",
          signed_values.to_unsafe.to_slice(13), 2
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          File.join(parent, "inferred-uint256"), "pk", W37_INTEGER_KEYS.to_unsafe.to_slice(13), "payload",
          unsigned_values.to_unsafe.to_slice(13), 2
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_int256_pair(
          File.join(parent, "mismatched"), "pk", W37_INTEGER_KEYS.to_unsafe.to_slice(13), "payload",
          signed_values.to_unsafe.to_slice(12), 2
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_uint256_pair(
          File.join(parent, "unsorted"), "pk", [2_u64, 1_u64].to_unsafe.to_slice(2), "payload",
          unsigned_values.to_unsafe.to_slice(2), 1
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::OfflineCatalog do
  it "materializes owned raw 256-bit values and a bounded catalog row window" do
    root = File.tempname("crystal-click-w37-offline-catalog")
    database_uuid = "44c74121-c031-4aa1-9a13-9a13de570037"
    table_uuid = "44c74121-c031-4aa1-9a13-9a13de570038"
    metadata_path = File.join(root, "metadata")
    database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
    table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
    part_path = File.join(table_path, "all_1_1_0")
    FileUtils.mkdir_p(metadata_path)
    FileUtils.mkdir_p(database_path)
    File.write(File.join(metadata_path, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
    File.write(File.join(database_path, "events.sql"), <<-DDL)
    ATTACH TABLE _ UUID '#{table_uuid}'
    (
        `pk` UInt64,
        `i` Int256,
        `u` UInt256
    )
    ENGINE = MergeTree
    ORDER BY pk
    DDL
    FileUtils.mkdir_p(table_path)
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W37_INTEGER_FIXTURE, part_path)

    begin
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"i", "Int256"},
        {"u", "UInt256"},
      ])

      signed_selection = table["i"]
      unsigned_selection = table["u"]
      signed_selection.values.map { |value| value.as(CrystalClick::Int256Value) }.should eq(w37_int256_values)
      unsigned_selection.values.map { |value| value.as(CrystalClick::UInt256Value) }.should eq(w37_uint256_values)
      expect_raises(CrystalClick::BoundsError) { signed_selection.values(max_rows: 12_u64) }

      owned_signed = signed_selection.values
      owned_unsigned = unsigned_selection.values
      owned_signed[0] = CrystalClick::Int256Value.from_words(0_u64, 0_u64, 0_u64, 0_u64)
      owned_unsigned[0] = CrystalClick::UInt256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX)
      signed_selection.values.map { |value| value.as(CrystalClick::Int256Value) }.should eq(w37_int256_values)
      unsigned_selection.values.map { |value| value.as(CrystalClick::UInt256Value) }.should eq(w37_uint256_values)

      window = [] of {UInt64, CrystalClick::Int256Value, CrystalClick::UInt256Value}
      table.scan_typed_window(["pk", "i", "u"], 3_u64, max_rows: 5) do |batch|
        keys = batch.values_for("pk", UInt64)
        signed = batch.int256_raw_for("i")
        unsigned = batch.uint256_raw_for("u")
        keys.each_index { |index| window << {keys[index], signed[index], unsigned[index]} }
      end
      expected = Array({UInt64, CrystalClick::Int256Value, CrystalClick::UInt256Value}).new(5) do |index|
        row = index + 3
        {W37_INTEGER_KEYS[row], w37_int256_values[row], w37_uint256_values[row]}
      end
      window.should eq(expected)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
