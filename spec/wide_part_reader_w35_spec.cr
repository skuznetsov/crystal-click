require "./spec_helper"

W35_INTEGER_FIXTURE = File.expand_path("../test/fixtures/public/wide_integer128/part", __DIR__)
W35_INTEGER_KEYS    = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64, 17_u64, 19_u64, 21_u64, 25_u64, 31_u64, 40_u64]
W35_INT128_VALUES   = [
  Int128::MIN,
  -9_223_372_036_854_775_809_i128,
  -18_446_744_073_709_551_617_i128,
  -1_i128,
  0_i128,
  1_i128,
  18_446_744_073_709_551_615_i128,
  18_446_744_073_709_551_616_i128,
  -170_141_183_460_469_231_731_687_303_715_884_105_727_i128,
  170_141_183_460_469_231_731_687_303_715_884_105_726_i128,
  12_345_678_901_234_567_890_123_456_789_012_345_678_i128,
  -12_345_678_901_234_567_890_123_456_789_012_345_678_i128,
  Int128::MAX,
]
W35_UINT128_VALUES = [
  0_u128,
  1_u128,
  18_446_744_073_709_551_615_u128,
  18_446_744_073_709_551_616_u128,
  18_446_744_073_709_551_617_u128,
  170_141_183_460_469_231_731_687_303_715_884_105_727_u128,
  170_141_183_460_469_231_731_687_303_715_884_105_728_u128,
  UInt128::MAX,
  340_282_366_920_938_463_463_374_607_431_768_211_454_u128,
  12_345_678_901_234_567_890_123_456_789_012_345_678_u128,
  18_446_744_073_709_551_616_u128,
  295_147_905_179_352_825_856_u128,
  42_u128,
]

private def w35_int128_payload(values : Array(Int128)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    bits = value.unsafe_as(UInt128)
    16.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u128).to_u8 }
  end
  bytes
end

private def w35_uint128_payload(values : Array(UInt128)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    16.times { |index| bytes << ((value >> (index * 8)) & 0xff_u128).to_u8 }
  end
  bytes
end

private def w35_decode_stream(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w35_mark_entries(part : String, logical_name : String) : Array({UInt64, UInt64, UInt64})
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  bytes = File.read(path).to_slice
  raise "invalid W35 .mrk2 stream: #{logical_name}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
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

private def w35_frame_offsets(part : String, logical_name : String) : Array(UInt64)
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")).to_slice
  offsets = [0_u64]
  offset = 0_i64
  while offset < bytes.size.to_i64
    frame = CrystalClick::CompressedBlock.decode_frame(bytes, offset)
    raise "W35 writer frame did not advance" if frame.end_offset <= offset
    offset = frame.end_offset
    offsets << offset.to_u64
  end
  raise "W35 writer stream has trailing bytes" unless offset == bytes.size.to_i64
  offsets
end

private def w35_assert_writer_marks(part : String, logical_name : String) : Nil
  offsets = w35_frame_offsets(part, logical_name)
  offsets.size.should eq(8)
  # Crystal emits each mark at a new LZ4 frame boundary, so the in-frame
  # uncompressed offset is zero for every mark (unlike stock's single frame).
  raw_offsets = Array(UInt64).new(8, 0_u64)
  row_counts = [2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
  expected = Array({UInt64, UInt64, UInt64}).new(8) do |index|
    {offsets[index], raw_offsets[index], row_counts[index]}
  end
  w35_mark_entries(part, logical_name).should eq(expected)
end

private def w35_assert_stock_marks(logical_name : String, width : Int32) : Nil
  raw_offsets = [0_u64, 2_u64, 4_u64, 6_u64, 8_u64, 10_u64, 12_u64, 13_u64].map { |rows| rows * width.to_u64 }
  row_counts = [2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
  expected = Array({UInt64, UInt64, UInt64}).new(8) do |index|
    {0_u64, raw_offsets[index], row_counts[index]}
  end
  w35_mark_entries(W35_INTEGER_FIXTURE, logical_name).should eq(expected)
end

private def w35_assert_writer_part(part : String, type_name : String, values : Array(T), raw : Array(UInt8)) : Nil forall T
  File.read(File.join(part, "columns.txt")).should eq(
    "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
  )
  File.read(File.join(part, "columns_substreams.txt")).should eq(
    "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `payload`:\n\tpayload\n"
  )
  File.read(File.join(part, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
  File.read(File.join(part, "count.txt")).should eq(values.size.to_s)
  w35_decode_stream(part, "payload").should eq(raw)
  CrystalClick::WidePart.open_typed(part, "payload").mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
  w35_assert_writer_marks(part, "pk")
  w35_assert_writer_marks(part, "payload")
end

describe CrystalClick::WidePart do
  it "admits raw scalar Int128 and UInt128 while keeping arrays, nullables, and 256-bit scalars closed" do
    CrystalClick::WidePart.supports_typed_type?("Int128").should be_true
    CrystalClick::WidePart.supports_typed_type?("UInt128").should be_true
    CrystalClick::WidePart.supports_numeric_type?("Int128").should be_false
    CrystalClick::WidePart.supports_numeric_type?("UInt128").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(Int128)").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(UInt128)").should be_false
    CrystalClick::WidePart.supports_typed_type?("Nullable(Int128)").should be_false
    CrystalClick::WidePart.supports_typed_type?("Nullable(UInt128)").should be_false
    CrystalClick::WidePart.supports_typed_type?("Decimal(38, 0)").should be_true
    CrystalClick::WidePart.supports_typed_type?("Decimal(76, 0)").should be_true
    CrystalClick::WidePart.supports_typed_type?("Int256").should be_false
    CrystalClick::WidePart.supports_typed_type?("UInt256").should be_false
  end

  it "reads exact Int128 and UInt128 stock columns across marks without aliasing Decimal128" do
    signed = CrystalClick::WidePart.open_typed(W35_INTEGER_FIXTURE, "signed")
    unsigned = CrystalClick::WidePart.open_typed(W35_INTEGER_FIXTURE, "unsigned")
    signed.column_type.should eq("Int128")
    unsigned.column_type.should eq("UInt128")
    signed.row_count.should eq(13_u64)
    unsigned.row_count.should eq(13_u64)
    signed.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
    unsigned.mark_row_counts.should eq(signed.mark_row_counts)
    signed.read_int128_raw_mark_range("signed", 0, signed.mark_count).should eq(W35_INT128_VALUES)
    unsigned.read_uint128_raw_mark_range("unsigned", 0, unsigned.mark_count).should eq(W35_UINT128_VALUES)
    signed.read_int128_raw_mark_range("signed", 1, 4).should eq(W35_INT128_VALUES[2, 8])
    unsigned.read_uint128_raw_mark_range("unsigned", 2, 2).should eq(W35_UINT128_VALUES[4, 4])
    signed.read_int128_raw_mark_range("signed", 6, 1).should eq([Int128::MAX])
    unsigned.read_uint128_raw_mark_range("unsigned", 6, 1).should eq([42_u128])
    w35_decode_stream(W35_INTEGER_FIXTURE, "signed").should eq(w35_int128_payload(W35_INT128_VALUES))
    w35_decode_stream(W35_INTEGER_FIXTURE, "unsigned").should eq(w35_uint128_payload(W35_UINT128_VALUES))
    w35_assert_stock_marks("pk", 8)
    w35_assert_stock_marks("signed", 16)
    w35_assert_stock_marks("unsigned", 16)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      signed.read_numeric_mark_range("signed", 0, 1, Int128)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      signed.read_uint128_raw_mark_range("signed", 0, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      unsigned.read_int128_raw_mark_range("unsigned", 0, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      signed.read_decimal128_raw_mark_range("signed", 0, 1)
    end
  end

  it "rejects sparse serialization for a selected raw Int128 column" do
    parent = File.tempname("crystal-click-w35-sparse-serializer")
    Dir.mkdir(parent)
    part = File.join(parent, "part")
    begin
      FileUtils.cp_r(W35_INTEGER_FIXTURE, part)
      metadata_path = File.join(part, "serialization.json")
      original = File.read(metadata_path)
      changed = original.gsub(%("kind":"Default","name":"signed"), %("kind":"Sparse","name":"signed"))
      changed.bytesize.should eq(original.bytesize - 1)
      changed += " " # preserve the checksummed physical file length; JSON permits trailing whitespace
      JSON.parse(changed)
      File.write(metadata_path, changed)
      File.size(metadata_path).should eq(original.bytesize)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part, "signed")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "matches serialization records by unique exact column name" do
    parent = File.tempname("crystal-click-w35-serialization-name-map")
    Dir.mkdir(parent)
    reordered = File.join(parent, "reordered")
    duplicate = File.join(parent, "duplicate")
    missing = File.join(parent, "missing")
    begin
      {reordered, duplicate, missing}.each do |part|
        FileUtils.cp_r(W35_INTEGER_FIXTURE, part)
      end

      metadata_path = File.join(reordered, "serialization.json")
      original = File.read(metadata_path)
      left = %({"kind":"Default","name":"signed","num_defaults":1,"num_rows":13})
      right = %({"kind":"Default","name":"unsigned","num_defaults":1,"num_rows":13})
      raise "W35 serialization records not found" unless original.includes?(left) && original.includes?(right)
      swapped = original.sub(left, "__W35_RECORD_SWAP__").sub(right, left).sub("__W35_RECORD_SWAP__", right)
      JSON.parse(swapped)
      File.write(metadata_path, swapped)
      part = CrystalClick::WidePart.open_typed(reordered, "signed")
      part.read_int128_raw_mark_range("signed", 0, part.mark_count).should eq(W35_INT128_VALUES)
      part = CrystalClick::WidePart.open_typed(reordered, "unsigned")
      part.read_uint128_raw_mark_range("unsigned", 0, part.mark_count).should eq(W35_UINT128_VALUES)

      duplicate_path = File.join(duplicate, "serialization.json")
      duplicate_json = File.read(duplicate_path).sub(%("name":"unsigned"), %("name":"signed"))
      duplicate_json.bytesize.should eq(File.size(duplicate_path) - 2)
      duplicate_json += "  "
      JSON.parse(duplicate_json)
      File.write(duplicate_path, duplicate_json)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(duplicate, "signed")
      end

      missing_path = File.join(missing, "serialization.json")
      missing_json = File.read(missing_path)
      record = %({"kind":"Default","name":"unsigned","num_defaults":1,"num_rows":13})
      missing_json = missing_json.sub(%(,#{record}), "")
      missing_json.bytesize.should be < File.size(missing_path)
      missing_json += " " * (File.size(missing_path) - missing_json.bytesize)
      JSON.parse(missing_json)
      File.write(missing_path, missing_json)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(missing, "signed")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "materializes both raw scalar columns for full and row-window table batches" do
    parent = File.tempname("crystal-click-w35-table-batch")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    begin
      FileUtils.cp_r(W35_INTEGER_FIXTURE, part_path)
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["pk", "signed", "unsigned"])
      observed = [] of {UInt64, Int128, UInt128}
      table.scan_typed(batch_rows: 3) do |batch|
        keys = batch.values_for("pk", UInt64)
        signed = batch.int128_raw_for("signed")
        unsigned = batch.uint128_raw_for("unsigned")
        keys.each_index { |index| observed << {keys[index], signed[index], unsigned[index]} }
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.values_for("signed", Int128)
        end
      end
      observed.should eq(W35_INTEGER_KEYS.each_index.map { |index| {W35_INTEGER_KEYS[index], W35_INT128_VALUES[index], W35_UINT128_VALUES[index]} }.to_a)

      window = [] of {UInt64, Int128, UInt128}
      table.scan_typed_window(2_u64, max_rows: 7) do |batch|
        keys = batch.values_for("pk", UInt64)
        signed = batch.int128_raw_for("signed")
        unsigned = batch.uint128_raw_for("unsigned")
        keys.each_index { |index| window << {keys[index], signed[index], unsigned[index]} }
      end
      window.should eq(W35_INTEGER_KEYS[2, 7].each_index.map do |index|
        row = index + 2
        {W35_INTEGER_KEYS[row], W35_INT128_VALUES[row], W35_UINT128_VALUES[row]}
      end.to_a)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps raw Int128 access distinct from Decimal(38, S) in both directions" do
    parent = File.tempname("crystal-click-w35-decimal-boundary")
    Dir.mkdir(parent)
    decimal_part = File.join(parent, "decimal")
    values = [-7_i128, 8_i128]
    begin
      CrystalClick::WidePartWriter.write_uint64_decimal128_pair(
        decimal_part, "pk", [1_u64, 2_u64].to_unsafe.to_slice(2), "amount",
        values.to_unsafe.to_slice(values.size), 0, 1
      )
      decimal = CrystalClick::WidePart.open_typed(decimal_part, "amount")
      decimal.column_type.should eq("Decimal(38, 0)")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        decimal.read_int128_raw_mark_range("amount", 0, 1)
      end

      raw = CrystalClick::WidePart.open_typed(W35_INTEGER_FIXTURE, "signed")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        raw.read_decimal128_raw_mark_range("signed", 0, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects corrupt raw 128-bit data before a table callback" do
    parent = File.tempname("crystal-click-w35-corruption")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    begin
      CrystalClick::WidePartWriter.write_uint64_int128_pair(
        part, "pk", W35_INTEGER_KEYS.to_unsafe.to_slice(W35_INTEGER_KEYS.size), "payload",
        W35_INT128_VALUES.to_unsafe.to_slice(W35_INT128_VALUES.size), 2
      )
      path = File.join(part, "#{CrystalClick::StreamName.hash("payload")}.bin")
      bytes = File.read(path).to_slice.dup
      # The first 16 bytes are the frame checksum. Corrupt the frame's
      # compressed-size field while preserving physical length so decoding,
      # not size-only preflight, fails before the first callback.
      bytes[17] = 0_u8
      bytes[18] = 0_u8
      bytes[19] = 0_u8
      bytes[20] = 0_u8
      File.write(path, bytes)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
        table.scan_typed_candidate_marks([[0]]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes paired raw Int128 and UInt128 scalar parts with exact metadata, bytes, and marks" do
    parent = File.tempname("crystal-click-w35-integer-writers")
    Dir.mkdir(parent)
    keys = W35_INTEGER_KEYS
    signed_part = File.join(parent, "signed")
    unsigned_part = File.join(parent, "unsigned")
    begin
      CrystalClick::WidePartWriter.write_uint64_int128_pair(
        signed_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        W35_INT128_VALUES.to_unsafe.to_slice(W35_INT128_VALUES.size), 2
      ).should eq(signed_part)
      CrystalClick::WidePartWriter.write_uint64_uint128_pair(
        unsigned_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        W35_UINT128_VALUES.to_unsafe.to_slice(W35_UINT128_VALUES.size), 2
      ).should eq(unsigned_part)

      w35_assert_writer_part(signed_part, "Int128", W35_INT128_VALUES, w35_int128_payload(W35_INT128_VALUES))
      w35_assert_writer_part(unsigned_part, "UInt128", W35_UINT128_VALUES, w35_uint128_payload(W35_UINT128_VALUES))
      CrystalClick::WidePart.open_typed(signed_part, "payload")
        .read_int128_raw_mark_range("payload", 0, 7).should eq(W35_INT128_VALUES)
      CrystalClick::WidePart.open_typed(unsigned_part, "payload")
        .read_uint128_raw_mark_range("payload", 0, 7).should eq(W35_UINT128_VALUES)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects inferred 128-bit writers and bad inputs without publishing a part" do
    parent = File.tempname("crystal-click-w35-writer-preflight")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    signed = [-1_i128, 1_i128]
    unsigned = [0_u128, UInt128::MAX]
    begin
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          File.join(parent, "inferred-int128"), "pk", keys.to_unsafe.to_slice(2), "payload",
          signed.to_unsafe.to_slice(2), 1
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          File.join(parent, "inferred-uint128"), "pk", keys.to_unsafe.to_slice(2), "payload",
          unsigned.to_unsafe.to_slice(2), 1
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_int128_pair(
          File.join(parent, "mismatched"), "pk", keys.to_unsafe.to_slice(2), "payload",
          signed.to_unsafe.to_slice(1), 1
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_uint128_pair(
          File.join(parent, "unsorted"), "pk", [2_u64, 1_u64].to_unsafe.to_slice(2), "payload",
          unsigned.to_unsafe.to_slice(2), 1
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::OfflineCatalog do
  it "materializes owned exact Int128 and UInt128 values and scans a bounded row window" do
    root = File.tempname("crystal-click-w35-offline-catalog")
    database_uuid = "44c74121-c031-4aa1-9a13-9a13de570035"
    table_uuid = "44c74121-c031-4aa1-9a13-9a13de570036"
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
        `signed` Int128,
        `unsigned` UInt128
    )
    ENGINE = MergeTree
    ORDER BY pk
    DDL
    FileUtils.mkdir_p(table_path)
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W35_INTEGER_FIXTURE, part_path)

    begin
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"signed", "Int128"},
        {"unsigned", "UInt128"},
      ])

      signed_selection = table["signed"]
      unsigned_selection = table["unsigned"]
      signed_selection.values.map { |value| value.as(Int128) }.should eq(W35_INT128_VALUES)
      unsigned_selection.values.map { |value| value.as(UInt128) }.should eq(W35_UINT128_VALUES)
      expect_raises(CrystalClick::BoundsError) { signed_selection.values(max_rows: 12_u64) }

      owned_signed = signed_selection.values
      owned_unsigned = unsigned_selection.values
      owned_signed[0] = 0_i128
      owned_unsigned[0] = UInt128::MAX
      signed_selection.values.map { |value| value.as(Int128) }.should eq(W35_INT128_VALUES)
      unsigned_selection.values.map { |value| value.as(UInt128) }.should eq(W35_UINT128_VALUES)

      window = [] of {UInt64, Int128, UInt128}
      table.scan_typed_window(["pk", "signed", "unsigned"], 3_u64, max_rows: 5) do |batch|
        keys = batch.values_for("pk", UInt64)
        signed = batch.int128_raw_for("signed")
        unsigned = batch.uint128_raw_for("unsigned")
        keys.each_index { |index| window << {keys[index], signed[index], unsigned[index]} }
      end
      window.should eq(W35_INTEGER_KEYS[3, 5].each_index.map do |index|
        row = index + 3
        {W35_INTEGER_KEYS[row], W35_INT128_VALUES[row], W35_UINT128_VALUES[row]}
      end.to_a)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
