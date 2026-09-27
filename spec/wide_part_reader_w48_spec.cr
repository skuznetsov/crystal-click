require "./spec_helper"
require "file_utils"

W48_ENUM_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_enum_w48/part", __DIR__)
W48_KEYS         = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]

W48_ENUM8_TYPE                    = "Enum8('min' = -128, 'neg' = -7, 'zero' = 0, 'pos' = 7, 'max' = 127)"
W48_ENUM16_TYPE                   = "Enum16('min' = -32768, 'neg' = -300, 'zero' = 0, 'pos' = 300, 'max' = 32767)"
W48_ENUM8_NO_ZERO_TYPE            = "Enum8('pos' = 7, 'neg' = -7)"
W48_ENUM16_NO_ZERO_TYPE           = "Enum16('pos' = 300, 'neg' = -300)"
W48_ENUM8_NO_ZERO_CANONICAL_TYPE  = "Enum8('neg' = -7, 'pos' = 7)"
W48_ENUM16_NO_ZERO_CANONICAL_TYPE = "Enum16('neg' = -300, 'pos' = 300)"

W48_ENUM8_ROWS = [
  [] of Int8,
  [-128_i8, -7_i8, 0_i8, 7_i8, 127_i8],
  [0_i8],
  [] of Int8,
  [0_i8, -7_i8],
  [127_i8],
  [] of Int8,
] of Array(Int8)

W48_NULLABLE_ENUM8_ROWS = [
  [] of Int8?,
  [nil, 0_i8.as(Int8?), -128_i8.as(Int8?), 127_i8.as(Int8?), 7_i8.as(Int8?)] of Int8?,
  [nil, nil] of Int8?,
  [] of Int8?,
  [7_i8.as(Int8?), nil, 127_i8.as(Int8?)] of Int8?,
  [0_i8.as(Int8?), nil] of Int8?,
  [] of Int8?,
] of Array(Int8?)

W48_ENUM16_ROWS = [
  [] of Int16,
  [-32_768_i16, -300_i16, 0_i16, 300_i16, 32_767_i16],
  [0_i16],
  [] of Int16,
  [0_i16, -300_i16],
  [32_767_i16],
  [] of Int16,
] of Array(Int16)

W48_NULLABLE_ENUM16_ROWS = [
  [] of Int16?,
  [nil, 0_i16.as(Int16?), -32_768_i16.as(Int16?), 32_767_i16.as(Int16?), 300_i16.as(Int16?)] of Int16?,
  [nil, nil] of Int16?,
  [] of Int16?,
  [300_i16.as(Int16?), nil, 32_767_i16.as(Int16?)] of Int16?,
  [0_i16.as(Int16?), nil] of Int16?,
  [] of Int16?,
] of Array(Int16?)

# Literal signed little-endian leaves from the pinned stock fixture.
W48_ENUM8_LEAVES           = [0x80_u8, 0xf9_u8, 0x00_u8, 0x07_u8, 0x7f_u8, 0x00_u8, 0x00_u8, 0xf9_u8, 0x7f_u8]
W48_NULLABLE_ENUM8_LEAVES  = [0x80_u8, 0x00_u8, 0x80_u8, 0x7f_u8, 0x07_u8, 0x80_u8, 0x80_u8, 0x07_u8, 0x80_u8, 0x7f_u8, 0x00_u8, 0x80_u8]
W48_ENUM16_LEAVES          = [0x00_u8, 0x80_u8, 0xd4_u8, 0xfe_u8, 0x00_u8, 0x00_u8, 0x2c_u8, 0x01_u8, 0xff_u8, 0x7f_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0xd4_u8, 0xfe_u8, 0xff_u8, 0x7f_u8]
W48_NULLABLE_ENUM16_LEAVES = [0x00_u8, 0x80_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8, 0xff_u8, 0x7f_u8, 0x2c_u8, 0x01_u8, 0x00_u8, 0x80_u8, 0x00_u8, 0x80_u8, 0x2c_u8, 0x01_u8, 0x00_u8, 0x80_u8, 0xff_u8, 0x7f_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8]
W48_NULL_MAP               = [0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x01_u8, 0x01_u8, 0x00_u8, 0x01_u8, 0x00_u8, 0x00_u8, 0x01_u8]

private def w48_decode_stream(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  File.file?(path).should be_true
  encoded = File.read(path).to_slice
  encoded.empty? ? [] of UInt8 : CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w48_size_stream(rows : Array(Array(T))) : Array(UInt8) forall T
  bytes = [] of UInt8
  rows.each do |row|
    size = row.size.to_u64
    8.times { |index| bytes << ((size >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w48_null_map(rows : Array(Array(T?))) : Array(UInt8) forall T
  rows.flat_map { |row| row.map { |value| value.nil? ? 1_u8 : 0_u8 } }
end

private def w48_catalog_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def with_w48_catalog_root(& : String ->)
  root = File.tempname("crystal-click-w48-offline-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    File.write(
      File.join(root, "metadata", "lab.sql"),
      "ATTACH DATABASE _ UUID 'f462f136-3924-4f43-b278-28c181075a54'\nENGINE = Atomic\n"
    )
    database_path = w48_catalog_store_path(root, "f462f136-3924-4f43-b278-28c181075a54")
    table_path = w48_catalog_store_path(root, "a78f7c0e-b304-41f4-a947-4f51e22dc6f1")
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID 'a78f7c0e-b304-41f4-a947-4f51e22dc6f1'\n(\n" +
      "    `pk` UInt64,\n" +
      "    `plain8` Array(#{W48_ENUM8_TYPE}),\n" +
      "    `maybe8` Array(Nullable(#{W48_ENUM8_TYPE})),\n" +
      "    `plain16` Array(#{W48_ENUM16_TYPE}),\n" +
      "    `maybe16` Array(Nullable(#{W48_ENUM16_TYPE}))\n" +
      ")\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W48_ENUM_FIXTURE, File.join(table_path, "all_1_1_0"))
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w48_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w48_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

# Mutate one decompressed byte, rebuild the LZ4 literal frame and reseal its
# ClickHouse checksum. Later mark compressed offsets follow the rewritten frame.
private def w48_rewrite_first_frame_byte(path : String, stream : String, raw_offset : Int, value : UInt8) : Nil
  data_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(data_path).to_slice
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, 0_i64)
  raw = frame.output.dup
  raw[raw_offset] = value

  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  rewritten = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  rewritten[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w48_write_u32(rewritten, header + 1, compressed_size.to_u32)
  w48_write_u32(rewritten, header + 5, raw.size.to_u32)
  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  if raw.size < 15
    rewritten[cursor] = (raw.size << 4).to_u8
    cursor += 1
  else
    rewritten[cursor] = 0xf0_u8
    cursor += 1
    remaining = raw.size - 15
    while remaining >= 255
      rewritten[cursor] = 255_u8
      cursor += 1
      remaining -= 255
    end
    rewritten[cursor] = remaining.to_u8
    cursor += 1
  end
  raw.copy_to(rewritten.to_unsafe + cursor, raw.size)
  hash = CrystalClick::CityHashV1.hash128(rewritten[header, compressed_size])
  w48_write_u64(rewritten, 0, hash[0])
  w48_write_u64(rewritten, 8, hash[1])

  old_frame_end = frame.end_offset.to_i
  delta = rewritten.size - old_frame_end
  result = Bytes.new(encoded.size + delta)
  rewritten.copy_to(result.to_unsafe, rewritten.size)
  encoded[old_frame_end, encoded.size - old_frame_end].copy_to(result.to_unsafe + rewritten.size, encoded.size - old_frame_end)
  File.write(data_path, result)

  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  (0...marks.size).step(CrystalClick::WidePart::MARK_SIZE) do |offset|
    mark_offset = 0_u64
    8.times { |byte| mark_offset |= marks[offset + byte].to_u64 << (byte * 8) }
    if mark_offset >= old_frame_end.to_u64
      w48_write_u64(marks, offset, (mark_offset.to_i64 + delta).to_u64)
    end
  end
  File.write(marks_path, marks)
end

describe CrystalClick::WidePart do
  it "admits exact Enum8 and Enum16 Array declarations without widening aliases" do
    CrystalClick::WidePart.supports_typed_type?("Array(#{W48_ENUM8_TYPE})").should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(Nullable(#{W48_ENUM8_TYPE}))").should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(#{W48_ENUM16_TYPE})").should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(Nullable(#{W48_ENUM16_TYPE}))").should be_true

    {
      "Array(Enum8('x' = -129))", "Array(Enum8('x' = 1, 'x' = 2))",
      "Array(Enum8('x' = 1, 'y' = 1))", "Array(Enum8('x'=1))",
      "Array(Enum8( 'x' = 1))", "Array(Enum8('x' = 1,  'y' = 2))",
      "Array(Enum16('x' = 32768))", "Array(Nullable(Nullable(#{W48_ENUM8_TYPE})))",
      "Array(Array(#{W48_ENUM8_TYPE}))", "Nullable(Array(#{W48_ENUM8_TYPE}))",
      "Array(Enum('x' = 1))", "Array(ENUM8('x' = 1))",
      "Array(Nullable(Enum16('x' = 1))) ", "Array(Nullable(#{W48_ENUM16_TYPE}), UInt8)",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads the stock four-shape fixture with signed little-endian leaves and later marks" do
    plain8 = CrystalClick::WidePart.open_typed(W48_ENUM_FIXTURE, "plain8")
    plain8.column_type.should eq("Array(#{W48_ENUM8_TYPE})")
    plain8.row_count.should eq(7_u64)
    plain8.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    plain8.read_array_enum8_codes_mark_range("plain8", 0, plain8.mark_count).should eq(W48_ENUM8_ROWS)
    plain8.read_array_enum8_codes_mark_range("plain8", 1, 2).should eq(W48_ENUM8_ROWS[2, 4])
    plain8.read_array_enum8_codes_mark_range("plain8", 3, 1).should eq(W48_ENUM8_ROWS[6, 1])
    w48_decode_stream(W48_ENUM_FIXTURE, "plain8.size0").should eq(w48_size_stream(W48_ENUM8_ROWS))
    w48_decode_stream(W48_ENUM_FIXTURE, "plain8").should eq(W48_ENUM8_LEAVES)

    maybe8 = CrystalClick::WidePart.open_typed(W48_ENUM_FIXTURE, "maybe8")
    maybe8.column_type.should eq("Array(Nullable(#{W48_ENUM8_TYPE}))")
    maybe8.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    maybe8.read_array_nullable_enum8_codes_mark_range("maybe8", 0, maybe8.mark_count).should eq(W48_NULLABLE_ENUM8_ROWS)
    maybe8.read_array_nullable_enum8_codes_mark_range("maybe8", 1, 2).should eq(W48_NULLABLE_ENUM8_ROWS[2, 4])
    w48_decode_stream(W48_ENUM_FIXTURE, "maybe8.size0").should eq(w48_size_stream(W48_NULLABLE_ENUM8_ROWS))
    w48_decode_stream(W48_ENUM_FIXTURE, "maybe8.null").should eq(W48_NULL_MAP)
    w48_decode_stream(W48_ENUM_FIXTURE, "maybe8").should eq(W48_NULLABLE_ENUM8_LEAVES)

    plain16 = CrystalClick::WidePart.open_typed(W48_ENUM_FIXTURE, "plain16")
    plain16.column_type.should eq("Array(#{W48_ENUM16_TYPE})")
    plain16.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    plain16.read_array_enum16_codes_mark_range("plain16", 0, plain16.mark_count).should eq(W48_ENUM16_ROWS)
    plain16.read_array_enum16_codes_mark_range("plain16", 1, 2).should eq(W48_ENUM16_ROWS[2, 4])
    w48_decode_stream(W48_ENUM_FIXTURE, "plain16.size0").should eq(w48_size_stream(W48_ENUM16_ROWS))
    w48_decode_stream(W48_ENUM_FIXTURE, "plain16").should eq(W48_ENUM16_LEAVES)

    maybe16 = CrystalClick::WidePart.open_typed(W48_ENUM_FIXTURE, "maybe16")
    maybe16.column_type.should eq("Array(Nullable(#{W48_ENUM16_TYPE}))")
    maybe16.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    maybe16.read_array_nullable_enum16_codes_mark_range("maybe16", 0, maybe16.mark_count).should eq(W48_NULLABLE_ENUM16_ROWS)
    maybe16.read_array_nullable_enum16_codes_mark_range("maybe16", 1, 2).should eq(W48_NULLABLE_ENUM16_ROWS[2, 4])
    w48_decode_stream(W48_ENUM_FIXTURE, "maybe16.size0").should eq(w48_size_stream(W48_NULLABLE_ENUM16_ROWS))
    w48_decode_stream(W48_ENUM_FIXTURE, "maybe16.null").should eq(W48_NULL_MAP)
    w48_decode_stream(W48_ENUM_FIXTURE, "maybe16").should eq(W48_NULLABLE_ENUM16_LEAVES)
  end

  it "fails closed on undeclared visible codes and ignores a nonzero code beneath NULL" do
    parent = File.tempname("crystal-click-w48-enum-corruption")
    Dir.mkdir(parent)
    plain_part = File.join(parent, "plain")
    nullable_part = File.join(parent, "nullable")
    begin
      CrystalClick::WidePartWriter.write_uint64_array_enum8_pair(
        plain_part, "pk", W48_KEYS.to_unsafe.to_slice(W48_KEYS.size), "payload",
        W48_ENUM8_ROWS.to_unsafe.to_slice(W48_ENUM8_ROWS.size), W48_ENUM8_TYPE, rows_per_mark: 2
      )
      # Code 1 is in Int8's domain but absent from this Enum declaration.
      w48_rewrite_first_frame_byte(plain_part, "payload", 0, 1_u8)
      w48_decode_stream(plain_part, "payload")[0].should eq(1_u8)
      expect_raises(CrystalClick::CorruptPartError, "Enum8 code is not declared") do
        CrystalClick::WidePart.open_typed(plain_part, "payload").read_array_enum8_codes_mark_range("payload", 0, 2)
      end

      plain16_part = File.join(parent, "plain16")
      CrystalClick::WidePartWriter.write_uint64_array_enum16_pair(
        plain16_part, "pk", W48_KEYS.to_unsafe.to_slice(W48_KEYS.size), "payload",
        W48_ENUM16_ROWS.to_unsafe.to_slice(W48_ENUM16_ROWS.size), W48_ENUM16_TYPE, rows_per_mark: 2
      )
      # Replace the first stock-valid -32768 slot with undeclared signed code 1.
      w48_rewrite_first_frame_byte(plain16_part, "payload", 0, 1_u8)
      w48_rewrite_first_frame_byte(plain16_part, "payload", 1, 0_u8)
      w48_decode_stream(plain16_part, "payload")[0, 2].should eq([1_u8, 0_u8])
      expect_raises(CrystalClick::CorruptPartError, "Enum16 code is not declared") do
        CrystalClick::WidePart.open_typed(plain16_part, "payload").read_array_enum16_codes_mark_range("payload", 0, 2)
      end

      CrystalClick::WidePartWriter.write_uint64_array_nullable_enum8_pair(
        nullable_part, "pk", W48_KEYS.to_unsafe.to_slice(W48_KEYS.size), "payload",
        W48_NULLABLE_ENUM8_ROWS.to_unsafe.to_slice(W48_NULLABLE_ENUM8_ROWS.size), W48_ENUM8_TYPE, rows_per_mark: 2
      )
      # The first child is under NULL; the following declared zero is a slot-advance sentinel.
      w48_rewrite_first_frame_byte(nullable_part, "payload", 0, 42_u8)
      w48_decode_stream(nullable_part, "payload")[0].should eq(42_u8)
      reader = CrystalClick::WidePart.open_typed(nullable_part, "payload")
      observed = reader.read_array_nullable_enum8_codes_mark_range("payload", 0, reader.mark_count)
      observed.should eq(W48_NULLABLE_ENUM8_ROWS)
      observed[1].should eq([nil, 0_i8, -128_i8, 127_i8, 7_i8])

      nullable16_part = File.join(parent, "nullable16")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_enum16_pair(
        nullable16_part, "pk", W48_KEYS.to_unsafe.to_slice(W48_KEYS.size), "payload",
        W48_NULLABLE_ENUM16_ROWS.to_unsafe.to_slice(W48_NULLABLE_ENUM16_ROWS.size), W48_ENUM16_TYPE, rows_per_mark: 2
      )
      # Poison both bytes under NULL, then preserve and decode the following 0 code.
      w48_rewrite_first_frame_byte(nullable16_part, "payload", 0, 42_u8)
      w48_rewrite_first_frame_byte(nullable16_part, "payload", 1, 0_u8)
      w48_decode_stream(nullable16_part, "payload")[0, 2].should eq([42_u8, 0_u8])
      nullable16_reader = CrystalClick::WidePart.open_typed(nullable16_part, "payload")
      observed16 = nullable16_reader.read_array_nullable_enum16_codes_mark_range("payload", 0, nullable16_reader.mark_count)
      observed16.should eq(W48_NULLABLE_ENUM16_ROWS)
      observed16[1].should eq([nil, 0_i16, -32_768_i16, 32_767_i16, 300_i16])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps enum accessors distinct from numeric Arrays and opposite enum widths" do
    parent = File.tempname("crystal-click-w48-enum-type-guards")
    Dir.mkdir(parent)
    begin
      enum_part = File.join(parent, "enum", "all_1_1_0")
      Dir.mkdir(File.dirname(enum_part))
      CrystalClick::WidePartWriter.write_uint64_array_enum8_pair(
        enum_part, "pk", W48_KEYS.to_unsafe.to_slice(W48_KEYS.size), "payload",
        W48_ENUM8_ROWS.to_unsafe.to_slice(W48_ENUM8_ROWS.size), W48_ENUM8_TYPE, rows_per_mark: 2
      )
      enum_table = CrystalClick::WidePartTable.open_selected_typed([enum_part], ["pk", "payload"])
      enum_checked = false
      enum_table.scan_typed do |batch|
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_enum16_codes_for("payload") }
        enum_checked = true
      end
      enum_checked.should be_true

      numeric_rows = [[] of Int8, [-7_i8, 0_i8, 7_i8]] of Array(Int8)
      numeric_part = File.join(parent, "numeric", "all_2_2_0")
      Dir.mkdir(File.dirname(numeric_part))
      numeric_keys = [1_u64, 2_u64]
      CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
        numeric_part, "pk", numeric_keys.to_unsafe.to_slice(numeric_keys.size), "payload",
        numeric_rows.to_unsafe.to_slice(numeric_rows.size), rows_per_mark: 1
      )
      numeric_table = CrystalClick::WidePartTable.open_selected_typed([numeric_part], ["pk", "payload"])
      numeric_checked = false
      numeric_table.scan_typed do |batch|
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_enum8_codes_for("payload") }
        numeric_checked = true
      end
      numeric_checked.should be_true
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "uses the minimum numeric code for nullable Enum slots when zero is undeclared" do
    parent = File.tempname("crystal-click-w48-enum-default")
    Dir.mkdir(parent)
    begin
      keys = [1_u64, 2_u64, 4_u64]
      rows = [
        [] of Int8?,
        [nil, -7_i8.as(Int8?), 7_i8.as(Int8?)] of Int8?,
        [nil] of Int8?,
      ] of Array(Int8?)
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_enum8_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        rows.to_unsafe.to_slice(rows.size), W48_ENUM8_NO_ZERO_TYPE, rows_per_mark: 2
      )

      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.column_type.should eq("Array(Nullable(#{W48_ENUM8_NO_ZERO_CANONICAL_TYPE}))")
      File.read(File.join(part, "columns.txt")).includes?("`payload` Array(Nullable(#{W48_ENUM8_NO_ZERO_CANONICAL_TYPE}))").should be_true
      reader.read_array_nullable_enum8_codes_mark_range("payload", 0, reader.mark_count).should eq(rows)
      w48_decode_stream(part, "payload.null").should eq([1_u8, 0_u8, 0_u8, 1_u8])
      # Physical Enum default is the minimum numeric code (-7), not declaration order.
      w48_decode_stream(part, "payload").should eq([0xf9_u8, 0xf9_u8, 0x07_u8, 0xf9_u8])

      keys16 = [1_u64, 2_u64, 4_u64]
      rows16 = [
        [] of Int16?,
        [nil, -300_i16.as(Int16?), 300_i16.as(Int16?)] of Int16?,
        [nil] of Int16?,
      ] of Array(Int16?)
      part16 = File.join(parent, "all_2_2_0")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_enum16_pair(
        part16, "pk", keys16.to_unsafe.to_slice(keys16.size), "payload",
        rows16.to_unsafe.to_slice(rows16.size), W48_ENUM16_NO_ZERO_TYPE, rows_per_mark: 2
      )

      reader16 = CrystalClick::WidePart.open_typed(part16, "payload")
      reader16.column_type.should eq("Array(Nullable(#{W48_ENUM16_NO_ZERO_CANONICAL_TYPE}))")
      File.read(File.join(part16, "columns.txt")).includes?("`payload` Array(Nullable(#{W48_ENUM16_NO_ZERO_CANONICAL_TYPE}))").should be_true
      reader16.read_array_nullable_enum16_codes_mark_range("payload", 0, reader16.mark_count).should eq(rows16)
      w48_decode_stream(part16, "payload.null").should eq([1_u8, 0_u8, 0_u8, 1_u8])
      w48_decode_stream(part16, "payload").should eq([0xd4_u8, 0xfe_u8, 0xd4_u8, 0xfe_u8, 0x2c_u8, 0x01_u8, 0xd4_u8, 0xfe_u8])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes four enum Array shapes with exact code leaves, null maps, and marks" do
    parent = File.tempname("crystal-click-w48-enum-writer")
    Dir.mkdir(parent)
    begin
      plain8_part = File.join(parent, "plain8")
      CrystalClick::WidePartWriter.write_uint64_array_enum8_pair(
        plain8_part, "pk", W48_KEYS.to_unsafe.to_slice(W48_KEYS.size), "payload",
        W48_ENUM8_ROWS.to_unsafe.to_slice(W48_ENUM8_ROWS.size), W48_ENUM8_TYPE, rows_per_mark: 2
      )
      plain8 = CrystalClick::WidePart.open_typed(plain8_part, "payload")
      plain8.column_type.should eq("Array(#{W48_ENUM8_TYPE})")
      plain8.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      plain8.read_array_enum8_codes_mark_range("payload", 0, plain8.mark_count).should eq(W48_ENUM8_ROWS)
      w48_decode_stream(plain8_part, "payload.size0").should eq(w48_size_stream(W48_ENUM8_ROWS))
      w48_decode_stream(plain8_part, "payload").should eq(W48_ENUM8_LEAVES)

      maybe8_part = File.join(parent, "maybe8")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_enum8_pair(
        maybe8_part, "pk", W48_KEYS.to_unsafe.to_slice(W48_KEYS.size), "payload",
        W48_NULLABLE_ENUM8_ROWS.to_unsafe.to_slice(W48_NULLABLE_ENUM8_ROWS.size), W48_ENUM8_TYPE, rows_per_mark: 2
      )
      maybe8 = CrystalClick::WidePart.open_typed(maybe8_part, "payload")
      maybe8.column_type.should eq("Array(Nullable(#{W48_ENUM8_TYPE}))")
      maybe8.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      maybe8.read_array_nullable_enum8_codes_mark_range("payload", 0, maybe8.mark_count).should eq(W48_NULLABLE_ENUM8_ROWS)
      w48_decode_stream(maybe8_part, "payload.size0").should eq(w48_size_stream(W48_NULLABLE_ENUM8_ROWS))
      w48_decode_stream(maybe8_part, "payload.null").should eq(W48_NULL_MAP)
      w48_decode_stream(maybe8_part, "payload").should eq(W48_NULLABLE_ENUM8_LEAVES)

      plain16_part = File.join(parent, "plain16")
      CrystalClick::WidePartWriter.write_uint64_array_enum16_pair(
        plain16_part, "pk", W48_KEYS.to_unsafe.to_slice(W48_KEYS.size), "payload",
        W48_ENUM16_ROWS.to_unsafe.to_slice(W48_ENUM16_ROWS.size), W48_ENUM16_TYPE, rows_per_mark: 2
      )
      plain16 = CrystalClick::WidePart.open_typed(plain16_part, "payload")
      plain16.column_type.should eq("Array(#{W48_ENUM16_TYPE})")
      plain16.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      plain16.read_array_enum16_codes_mark_range("payload", 0, plain16.mark_count).should eq(W48_ENUM16_ROWS)
      w48_decode_stream(plain16_part, "payload.size0").should eq(w48_size_stream(W48_ENUM16_ROWS))
      w48_decode_stream(plain16_part, "payload").should eq(W48_ENUM16_LEAVES)

      maybe16_part = File.join(parent, "maybe16")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_enum16_pair(
        maybe16_part, "pk", W48_KEYS.to_unsafe.to_slice(W48_KEYS.size), "payload",
        W48_NULLABLE_ENUM16_ROWS.to_unsafe.to_slice(W48_NULLABLE_ENUM16_ROWS.size), W48_ENUM16_TYPE, rows_per_mark: 2
      )
      maybe16 = CrystalClick::WidePart.open_typed(maybe16_part, "payload")
      maybe16.column_type.should eq("Array(Nullable(#{W48_ENUM16_TYPE}))")
      maybe16.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      maybe16.read_array_nullable_enum16_codes_mark_range("payload", 0, maybe16.mark_count).should eq(W48_NULLABLE_ENUM16_ROWS)
      w48_decode_stream(maybe16_part, "payload.size0").should eq(w48_size_stream(W48_NULLABLE_ENUM16_ROWS))
      w48_decode_stream(maybe16_part, "payload.null").should eq(W48_NULL_MAP)
      w48_decode_stream(maybe16_part, "payload").should eq(W48_NULLABLE_ENUM16_LEAVES)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes all-empty arrays and nonempty all-NULL nullable arrays for both widths" do
    parent = File.tempname("crystal-click-w48-enum-controls")
    Dir.mkdir(parent)
    begin
      empty8 = Array.new(W48_KEYS.size) { [] of Int8 }
      empty8_part = File.join(parent, "empty8")
      CrystalClick::WidePartWriter.write_uint64_array_enum8_pair(
        empty8_part, "pk", W48_KEYS.to_unsafe.to_slice(W48_KEYS.size), "payload",
        empty8.to_unsafe.to_slice(empty8.size), W48_ENUM8_TYPE, rows_per_mark: 2
      )
      w48_decode_stream(empty8_part, "payload.size0").should eq(w48_size_stream(empty8))
      w48_decode_stream(empty8_part, "payload").should be_empty

      empty_nullable8 = Array.new(W48_KEYS.size) { [] of Int8? }
      empty_nullable8_part = File.join(parent, "empty-nullable8")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_enum8_pair(
        empty_nullable8_part, "pk", W48_KEYS.to_unsafe.to_slice(W48_KEYS.size), "payload",
        empty_nullable8.to_unsafe.to_slice(empty_nullable8.size), W48_ENUM8_TYPE, rows_per_mark: 2
      )
      w48_decode_stream(empty_nullable8_part, "payload.size0").should eq(w48_size_stream(empty_nullable8))
      w48_decode_stream(empty_nullable8_part, "payload.null").should be_empty
      w48_decode_stream(empty_nullable8_part, "payload").should be_empty

      empty16 = Array.new(W48_KEYS.size) { [] of Int16 }
      empty16_part = File.join(parent, "empty16")
      CrystalClick::WidePartWriter.write_uint64_array_enum16_pair(
        empty16_part, "pk", W48_KEYS.to_unsafe.to_slice(W48_KEYS.size), "payload",
        empty16.to_unsafe.to_slice(empty16.size), W48_ENUM16_TYPE, rows_per_mark: 2
      )
      w48_decode_stream(empty16_part, "payload.size0").should eq(w48_size_stream(empty16))
      w48_decode_stream(empty16_part, "payload").should be_empty

      empty_nullable16 = Array.new(W48_KEYS.size) { [] of Int16? }
      empty_nullable16_part = File.join(parent, "empty-nullable16")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_enum16_pair(
        empty_nullable16_part, "pk", W48_KEYS.to_unsafe.to_slice(W48_KEYS.size), "payload",
        empty_nullable16.to_unsafe.to_slice(empty_nullable16.size), W48_ENUM16_TYPE, rows_per_mark: 2
      )
      w48_decode_stream(empty_nullable16_part, "payload.size0").should eq(w48_size_stream(empty_nullable16))
      w48_decode_stream(empty_nullable16_part, "payload.null").should be_empty
      w48_decode_stream(empty_nullable16_part, "payload").should be_empty

      all_null8 = Array.new(W48_KEYS.size) { [nil, nil] of Int8? }
      all_null8_part = File.join(parent, "all-null8")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_enum8_pair(
        all_null8_part, "pk", W48_KEYS.to_unsafe.to_slice(W48_KEYS.size), "payload",
        all_null8.to_unsafe.to_slice(all_null8.size), W48_ENUM8_TYPE, rows_per_mark: 2
      )
      CrystalClick::WidePart.open_typed(all_null8_part, "payload").read_array_nullable_enum8_codes_mark_range("payload", 0, 4).should eq(all_null8)
      w48_decode_stream(all_null8_part, "payload.null").should eq(Array.new(W48_KEYS.size * 2, 1_u8))
      w48_decode_stream(all_null8_part, "payload").should eq(Array.new(W48_KEYS.size * 2, 0x80_u8))

      all_null16 = Array.new(W48_KEYS.size) { [nil, nil] of Int16? }
      all_null16_part = File.join(parent, "all-null16")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_enum16_pair(
        all_null16_part, "pk", W48_KEYS.to_unsafe.to_slice(W48_KEYS.size), "payload",
        all_null16.to_unsafe.to_slice(all_null16.size), W48_ENUM16_TYPE, rows_per_mark: 2
      )
      CrystalClick::WidePart.open_typed(all_null16_part, "payload").read_array_nullable_enum16_codes_mark_range("payload", 0, 4).should eq(all_null16)
      w48_decode_stream(all_null16_part, "payload.null").should eq(Array.new(W48_KEYS.size * 2, 1_u8))
      all_null16_defaults = Array.new(W48_KEYS.size * 2) { [0x00_u8, 0x80_u8] }.flatten
      w48_decode_stream(all_null16_part, "payload").should eq(all_null16_defaults)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects mismatched dimensions and undeclared codes before publishing" do
    parent = File.tempname("crystal-click-w48-enum-preflight")
    Dir.mkdir(parent)
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_enum8_pair(
          File.join(parent, "mismatch"), "pk", W48_KEYS.to_unsafe.to_slice(1), "payload",
          W48_ENUM8_ROWS.to_unsafe.to_slice(W48_ENUM8_ROWS.size), W48_ENUM8_TYPE, rows_per_mark: 2
        )
      end
      Dir.children(parent).should be_empty

      bad_rows = [[] of Int8, [1_i8]] of Array(Int8)
      bad_keys = [1_u64, 2_u64]
      expect_raises(ArgumentError, "Enum8 code is not declared") do
        CrystalClick::WidePartWriter.write_uint64_array_enum8_pair(
          File.join(parent, "undeclared"), "pk", bad_keys.to_unsafe.to_slice(bad_keys.size), "payload",
          bad_rows.to_unsafe.to_slice(bad_rows.size), W48_ENUM8_TYPE, rows_per_mark: 1
        )
      end
      Dir.children(parent).should be_empty

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_array_enum16_pair(
          File.join(parent, "bad-type"), "pk", W48_KEYS.to_unsafe.to_slice(W48_KEYS.size), "payload",
          W48_ENUM16_ROWS.to_unsafe.to_slice(W48_ENUM16_ROWS.size), "Enum16('bad'=1)", rows_per_mark: 2
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::OfflineCatalog do
  it "materializes the four Enum Array shapes with declaration identity and owned values" do
    with_w48_catalog_root do |root|
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"plain8", "Array(#{W48_ENUM8_TYPE})"},
        {"maybe8", "Array(Nullable(#{W48_ENUM8_TYPE}))"},
        {"plain16", "Array(#{W48_ENUM16_TYPE})"},
        {"maybe16", "Array(Nullable(#{W48_ENUM16_TYPE}))"},
      ])

      plain8 = [] of Array(Int8)
      maybe8 = [] of Array(Int8?)
      plain16 = [] of Array(Int16)
      maybe16 = [] of Array(Int16?)
      table.scan_typed(["plain8", "maybe8", "plain16", "maybe16"], batch_rows: 3) do |batch|
        batch.column_type_for("plain8").should eq("Array(#{W48_ENUM8_TYPE})")
        batch.column_type_for("maybe8").should eq("Array(Nullable(#{W48_ENUM8_TYPE}))")
        batch.column_type_for("plain16").should eq("Array(#{W48_ENUM16_TYPE})")
        batch.column_type_for("maybe16").should eq("Array(Nullable(#{W48_ENUM16_TYPE}))")
        plain8.concat(batch.array_enum8_codes_for("plain8").map(&.dup))
        maybe8.concat(batch.array_nullable_enum8_codes_for("maybe8").map(&.dup))
        plain16.concat(batch.array_enum16_codes_for("plain16").map(&.dup))
        maybe16.concat(batch.array_nullable_enum16_codes_for("maybe16").map(&.dup))
      end
      plain8.should eq(W48_ENUM8_ROWS)
      maybe8.should eq(W48_NULLABLE_ENUM8_ROWS)
      plain16.should eq(W48_ENUM16_ROWS)
      maybe16.should eq(W48_NULLABLE_ENUM16_ROWS)

      later = [] of Array(Int16?)
      table.scan_typed_window(["maybe16"], 4_u64, max_rows: 3) do |batch|
        later.concat(batch.array_nullable_enum16_codes_for("maybe16").map(&.dup))
      end
      later.should eq(W48_NULLABLE_ENUM16_ROWS[4, 3])

      owned = table["plain8"].values.map { |value| value.as(Array(Int8)) }
      owned[1] << 7_i8
      table["plain8"].values.map { |value| value.as(Array(Int8)) }.should eq(W48_ENUM8_ROWS)
    end
  end
end
