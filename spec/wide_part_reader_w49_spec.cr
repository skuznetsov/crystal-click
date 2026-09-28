require "./spec_helper"
require "file_utils"

W49_BFLOAT16_FIXTURE = File.expand_path("../test/fixtures/public/wide_bfloat16_w49/part", __DIR__)
W49_KEYS             = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]

W49_SCALAR_BITS = [
  0x0000_u16, 0x8000_u16, 0x3f80_u16, 0x0001_u16, 0x7f7f_u16, 0x7fc1_u16, 0xffe2_u16,
]
W49_MAYBE_BITS = [
  nil, 0x8000_u16.as(UInt16?), 0x7fc2_u16.as(UInt16?), nil,
  0x8001_u16.as(UInt16?), nil, 0x7fc1_u16.as(UInt16?),
]
W49_ARRAY_BITS = [
  [] of UInt16,
  [0x8000_u16, 0x7fc1_u16, 0xffe2_u16],
  [0x0001_u16],
  [] of UInt16,
  [0x7f7f_u16, 0xff80_u16, 0x0080_u16],
  [0x7fe2_u16],
  [] of UInt16,
] of Array(UInt16)
W49_NULLABLE_ARRAY_BITS = [
  [] of UInt16?,
  [nil, 0x8000_u16.as(UInt16?), 0x7fc1_u16.as(UInt16?)] of UInt16?,
  [nil, nil] of UInt16?,
  [] of UInt16?,
  [0x7fe2_u16.as(UInt16?), nil, 0x3f80_u16.as(UInt16?)] of UInt16?,
  [nil, 0x8001_u16.as(UInt16?), nil] of UInt16?,
  [] of UInt16?,
] of Array(UInt16?)

W49_SCALAR_LEAVES = [
  0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8, 0x80_u8, 0x3f_u8, 0x01_u8, 0x00_u8,
  0x7f_u8, 0x7f_u8, 0xc1_u8, 0x7f_u8, 0xe2_u8, 0xff_u8,
]
W49_NULL_MAP     = [0x01_u8, 0x00_u8, 0x00_u8, 0x01_u8, 0x00_u8, 0x01_u8, 0x00_u8]
W49_MAYBE_LEAVES = [
  0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8, 0xc2_u8, 0x7f_u8, 0x00_u8, 0x00_u8,
  0x01_u8, 0x80_u8, 0x00_u8, 0x00_u8, 0xc1_u8, 0x7f_u8,
]
W49_ARRAY_LEAVES = [
  0x00_u8, 0x80_u8, 0xc1_u8, 0x7f_u8, 0xe2_u8, 0xff_u8, 0x01_u8, 0x00_u8,
  0x7f_u8, 0x7f_u8, 0x80_u8, 0xff_u8, 0x80_u8, 0x00_u8, 0xe2_u8, 0x7f_u8,
]
W49_ARRAY_NULL_MAP        = [0x01_u8, 0x00_u8, 0x00_u8, 0x01_u8, 0x01_u8, 0x00_u8, 0x01_u8, 0x00_u8, 0x01_u8, 0x00_u8, 0x01_u8]
W49_NULLABLE_ARRAY_LEAVES = [
  0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8, 0xc1_u8, 0x7f_u8,
  0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
  0xe2_u8, 0x7f_u8, 0x00_u8, 0x00_u8, 0x80_u8, 0x3f_u8,
  0x00_u8, 0x00_u8, 0x01_u8, 0x80_u8, 0x00_u8, 0x00_u8,
]

private def w49_decode_stream(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  File.file?(path).should be_true
  encoded = File.read(path).to_slice
  encoded.empty? ? [] of UInt8 : CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w49_bfloat16_bits(values : Array(CrystalClick::BFloat16Value)) : Array(UInt16)
  values.map(&.bits)
end

private def w49_nullable_bfloat16_bits(values : Array(CrystalClick::BFloat16Value?)) : Array(UInt16?)
  values.map { |value| value.try(&.bits) }
end

private def w49_array_bfloat16_bits(values : Array(Array(CrystalClick::BFloat16Value))) : Array(Array(UInt16))
  values.map { |row| w49_bfloat16_bits(row) }
end

private def w49_array_nullable_bfloat16_bits(values : Array(Array(CrystalClick::BFloat16Value?))) : Array(Array(UInt16?))
  values.map { |row| w49_nullable_bfloat16_bits(row) }
end

private def w49_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w49_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

# Replace bytes under a NULL bit, then rebuild the first literal-LZ4 frame and
# reseal its ClickHouse CityHash. Later mark offsets are adjusted if needed.
private def w49_reseal_first_frame_bytes(path : String, stream : String, raw_offset : Int, poison : Array(UInt8)) : Nil
  data_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(data_path).to_slice
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, 0_i64)
  raw = frame.output.dup
  raise "poison range exceeds first #{stream} frame" if raw_offset < 0 || raw_offset + poison.size > raw.size
  poison.each_with_index { |byte, index| raw[raw_offset + index] = byte }

  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  rewritten = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  rewritten[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w49_write_u32(rewritten, header + 1, compressed_size.to_u32)
  w49_write_u32(rewritten, header + 5, raw.size.to_u32)
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
  w49_write_u64(rewritten, 0, hash[0])
  w49_write_u64(rewritten, 8, hash[1])

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
      w49_write_u64(marks, offset, (mark_offset.to_i64 + delta).to_u64)
    end
  end
  File.write(marks_path, marks)
end

private def w49_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def with_w49_catalog_root(& : String ->)
  root = File.tempname("crystal-click-w49-offline-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    File.write(
      File.join(root, "metadata", "lab.sql"),
      "ATTACH DATABASE _ UUID 'f462f136-3924-4f43-b278-28c181075a54'\nENGINE = Atomic\n"
    )
    database_path = w49_store_path(root, "f462f136-3924-4f43-b278-28c181075a54")
    table_path = w49_store_path(root, "a78f7c0e-b304-41f4-a947-4f51e22dc6f1")
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID 'a78f7c0e-b304-41f4-a947-4f51e22dc6f1'\n(\n" +
      "    `pk` UInt64,\n    `scalar` BFloat16,\n" +
      "    `maybe` Nullable(BFloat16),\n    `plain` Array(BFloat16),\n" +
      "    `nullable_array` Array(Nullable(BFloat16))\n)\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W49_BFLOAT16_FIXTURE, File.join(table_path, "all_1_1_0"))
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def with_w49_selected_part(& : String ->)
  root = File.tempname("crystal-click-w49-selected-part")
  Dir.mkdir(root)
  begin
    selected = File.join(root, "all_1_1_0")
    FileUtils.cp_r(W49_BFLOAT16_FIXTURE, selected)
    yield selected
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::WidePart do
  it "retains the W49 BFloat16 reader shapes and rejects deeper nesting" do
    {
      "BFloat16",
      "Nullable(BFloat16)",
      "Array(BFloat16)",
      "Array(Nullable(BFloat16))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end

    # W49 is bit-preserving BFloat16, not a widening alias for another numeric
    # carrier. Existing UInt16 and Float32 declarations retain their own gates.
    CrystalClick::WidePart.supports_typed_type?("UInt16").should be_true
    CrystalClick::WidePart.supports_typed_type?("Float32").should be_true
    CrystalClick::WidePart.supports_typed_type?("BFLOAT16").should be_false
    CrystalClick::WidePart.supports_typed_type?("Nullable(Nullable(BFloat16))").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(Array(Array(BFloat16)))").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(Nullable(Nullable(BFloat16)))").should be_false
  end

  it "reads exact BFloat16 bits and nullable/Array forms from the stock part across marks" do
    scalar = CrystalClick::WidePart.open_typed(W49_BFLOAT16_FIXTURE, "scalar")
    scalar.column_type.should eq("BFloat16")
    scalar.row_count.should eq(7_u64)
    scalar.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    w49_bfloat16_bits(scalar.read_bfloat16_mark_range("scalar", 0, scalar.mark_count)).should eq(W49_SCALAR_BITS)
    w49_bfloat16_bits(scalar.read_bfloat16_mark_range("scalar", 1, 2)).should eq(W49_SCALAR_BITS[2, 4])
    w49_bfloat16_bits(scalar.read_bfloat16_mark_range("scalar", 3, 1)).should eq(W49_SCALAR_BITS[6, 1])
    w49_decode_stream(W49_BFLOAT16_FIXTURE, "scalar").should eq(W49_SCALAR_LEAVES)

    maybe = CrystalClick::WidePart.open_typed(W49_BFLOAT16_FIXTURE, "maybe")
    maybe.column_type.should eq("Nullable(BFloat16)")
    w49_nullable_bfloat16_bits(maybe.read_nullable_bfloat16_mark_range("maybe", 0, maybe.mark_count)).should eq(W49_MAYBE_BITS)
    w49_nullable_bfloat16_bits(maybe.read_nullable_bfloat16_mark_range("maybe", 1, 2)).should eq(W49_MAYBE_BITS[2, 4])
    w49_decode_stream(W49_BFLOAT16_FIXTURE, "maybe.null").should eq(W49_NULL_MAP)
    w49_decode_stream(W49_BFLOAT16_FIXTURE, "maybe").should eq(W49_MAYBE_LEAVES)

    plain = CrystalClick::WidePart.open_typed(W49_BFLOAT16_FIXTURE, "plain")
    plain.column_type.should eq("Array(BFloat16)")
    plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    w49_array_bfloat16_bits(plain.read_array_numeric_mark_range("plain", 0, plain.mark_count, CrystalClick::BFloat16Value)).should eq(W49_ARRAY_BITS)
    w49_array_bfloat16_bits(plain.read_array_numeric_mark_range("plain", 1, 2, CrystalClick::BFloat16Value)).should eq(W49_ARRAY_BITS[2, 4])
    w49_array_bfloat16_bits(plain.read_array_numeric_mark_range("plain", 3, 1, CrystalClick::BFloat16Value)).should eq(W49_ARRAY_BITS[6, 1])
    w49_decode_stream(W49_BFLOAT16_FIXTURE, "plain.size0").should eq(w49_sizes([0, 3, 1, 0, 3, 1, 0]))
    w49_decode_stream(W49_BFLOAT16_FIXTURE, "plain").should eq(W49_ARRAY_LEAVES)

    nullable_array = CrystalClick::WidePart.open_typed(W49_BFLOAT16_FIXTURE, "nullable_array")
    nullable_array.column_type.should eq("Array(Nullable(BFloat16))")
    nullable_array.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    w49_array_nullable_bfloat16_bits(nullable_array.read_array_nullable_numeric_mark_range("nullable_array", 0, nullable_array.mark_count, CrystalClick::BFloat16Value)).should eq(W49_NULLABLE_ARRAY_BITS)
    w49_array_nullable_bfloat16_bits(nullable_array.read_array_nullable_numeric_mark_range("nullable_array", 1, 2, CrystalClick::BFloat16Value)).should eq(W49_NULLABLE_ARRAY_BITS[2, 4])
    w49_array_nullable_bfloat16_bits(nullable_array.read_array_nullable_numeric_mark_range("nullable_array", 3, 1, CrystalClick::BFloat16Value)).should eq(W49_NULLABLE_ARRAY_BITS[6, 1])
    w49_decode_stream(W49_BFLOAT16_FIXTURE, "nullable_array.size0").should eq(w49_sizes([0, 3, 2, 0, 3, 3, 0]))
    w49_decode_stream(W49_BFLOAT16_FIXTURE, "nullable_array.null").should eq(W49_ARRAY_NULL_MAP)
    w49_decode_stream(W49_BFLOAT16_FIXTURE, "nullable_array").should eq(W49_NULLABLE_ARRAY_LEAVES)
  end

  it "does not reinterpret UInt16 or Float32 accessors as BFloat16" do
    scalar = CrystalClick::WidePart.open_typed(W49_BFLOAT16_FIXTURE, "scalar")
    expect_raises(CrystalClick::UnsupportedFormatError) do
      scalar.read_numeric_mark_range("scalar", 0, scalar.mark_count, UInt16)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      scalar.read_numeric_mark_range("scalar", 0, scalar.mark_count, Float32)
    end
  end

  it "exposes the four exact shapes through typed part batches without aliases" do
    with_w49_selected_part do |part|
      table = CrystalClick::WidePartTable.open_selected_typed(
        [part], ["pk", "scalar", "maybe", "plain", "nullable_array"]
      )
      table.column_types.should eq([
        {"pk", "UInt64"},
        {"scalar", "BFloat16"},
        {"maybe", "Nullable(BFloat16)"},
        {"plain", "Array(BFloat16)"},
        {"nullable_array", "Array(Nullable(BFloat16))"},
      ])
      table.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64, 1_u64]])

      scalar_bits = [] of UInt16
      maybe_bits = [] of UInt16?
      plain_bits = [] of Array(UInt16)
      nullable_array_bits = [] of Array(UInt16?)
      batch_count = 0
      table.scan_typed(batch_rows: 3) do |batch|
        batch_count += 1
        scalar_bits.concat(batch.bfloat16s_for("scalar").map(&.bits))
        maybe_bits.concat(batch.nullable_bfloat16s_for("maybe").map { |value| value.try(&.bits) })
        plain_bits.concat(batch.array_bfloat16s_for("plain").map { |row| row.map(&.bits) })
        nullable_array_bits.concat(batch.array_nullable_bfloat16s_for("nullable_array").map do |row|
          row.map { |value| value.try(&.bits) }
        end)

        expect_raises(CrystalClick::UnsupportedFormatError) { batch.values_for("scalar", UInt16) }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.values_for("scalar", Float32) }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_values_for("maybe", UInt16) }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_numeric_values("plain", UInt16) }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_nullable_numeric_values("nullable_array", Float32) }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.bfloat16s_for("maybe") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.bfloat16s_for("plain") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_bfloat16s_for("scalar") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_bfloat16s_for("nullable_array") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_nullable_bfloat16s_for("plain") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_numeric_values("scalar", CrystalClick::BFloat16Value) }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_nullable_numeric_values("maybe", CrystalClick::BFloat16Value) }
      end
      # Typed scan yields whole source marks; batch_rows is a ceiling and does
      # not merge the part's [2, 2, 2, 1] mark boundaries.
      batch_count.should eq(4)
      scalar_bits.should eq(W49_SCALAR_BITS)
      maybe_bits.should eq(W49_MAYBE_BITS)
      plain_bits.should eq(W49_ARRAY_BITS)
      nullable_array_bits.should eq(W49_NULLABLE_ARRAY_BITS)
    end
  end

  it "routes all four exact shapes through the typed offline catalog and row window" do
    with_w49_catalog_root do |root|
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"scalar", "BFloat16"},
        {"maybe", "Nullable(BFloat16)"},
        {"plain", "Array(BFloat16)"},
        {"nullable_array", "Array(Nullable(BFloat16))"},
      ])

      scalar_bits = [] of UInt16
      maybe_bits = [] of UInt16?
      plain_bits = [] of Array(UInt16)
      nullable_array_bits = [] of Array(UInt16?)
      table.scan_typed(["scalar", "maybe", "plain", "nullable_array"], batch_rows: 3) do |batch|
        batch.column_type_for("scalar").should eq("BFloat16")
        batch.column_type_for("maybe").should eq("Nullable(BFloat16)")
        batch.column_type_for("plain").should eq("Array(BFloat16)")
        batch.column_type_for("nullable_array").should eq("Array(Nullable(BFloat16))")
        scalar_bits.concat(batch.bfloat16s_for("scalar").map(&.bits))
        maybe_bits.concat(batch.nullable_bfloat16s_for("maybe").map { |value| value.try(&.bits) })
        plain_bits.concat(batch.array_numeric_values("plain", CrystalClick::BFloat16Value).map { |row| row.map(&.bits) })
        nullable_array_bits.concat(batch.array_nullable_numeric_values("nullable_array", CrystalClick::BFloat16Value).map do |row|
          row.map { |value| value.try(&.bits) }
        end)
      end
      scalar_bits.should eq(W49_SCALAR_BITS)
      maybe_bits.should eq(W49_MAYBE_BITS)
      plain_bits.should eq(W49_ARRAY_BITS)
      nullable_array_bits.should eq(W49_NULLABLE_ARRAY_BITS)

      later = [] of Array(UInt16?)
      table.scan_typed_window(["nullable_array"], 4_u64, max_rows: 3) do |batch|
        later.concat(batch.array_nullable_numeric_values("nullable_array", CrystalClick::BFloat16Value).map do |row|
          row.map { |value| value.try(&.bits) }
        end)
      end
      later.should eq(W49_NULLABLE_ARRAY_BITS[4, 3])
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes exact scalar and Array BFloat16 payloads including nullable leaf slots" do
    with_w49_selected_part do |fixture_part|
      keys = W49_KEYS.to_unsafe.to_slice(W49_KEYS.size)
      scalar_values = W49_SCALAR_BITS.map { |bits| CrystalClick::BFloat16Value.new(bits) }
      maybe_values = W49_MAYBE_BITS.map { |bits| bits.try { |value| CrystalClick::BFloat16Value.new(value) } }
      array_values = W49_ARRAY_BITS.map do |row|
        row.map { |bits| CrystalClick::BFloat16Value.new(bits) }
      end
      nullable_array_values = W49_NULLABLE_ARRAY_BITS.map do |row|
        row.map { |bits| bits.try { |value| CrystalClick::BFloat16Value.new(value) } }
      end

      root = File.tempname("crystal-click-w49-writer")
      Dir.mkdir(root)
      begin
        scalar_part = CrystalClick::WidePartWriter.write_uint64_bfloat16_pair(
          File.join(root, "scalar"), "pk", keys, "payload",
          scalar_values.to_unsafe.to_slice(scalar_values.size), 2
        )
        maybe_part = CrystalClick::WidePartWriter.write_uint64_nullable_bfloat16_pair(
          File.join(root, "maybe"), "pk", keys, "payload",
          maybe_values.to_unsafe.to_slice(maybe_values.size), 2
        )
        array_part = CrystalClick::WidePartWriter.write_uint64_array_bfloat16_pair(
          File.join(root, "array"), "pk", keys, "payload",
          array_values.to_unsafe.to_slice(array_values.size), 2
        )
        nullable_array_part = CrystalClick::WidePartWriter.write_uint64_array_nullable_bfloat16_pair(
          File.join(root, "nullable-array"), "pk", keys, "payload",
          nullable_array_values.to_unsafe.to_slice(nullable_array_values.size), 2
        )

        scalar_reader = CrystalClick::WidePart.open_typed(scalar_part, "payload")
        scalar_reader.column_type.should eq("BFloat16")
        w49_bfloat16_bits(scalar_reader.read_bfloat16_mark_range("payload", 0, scalar_reader.mark_count)).should eq(W49_SCALAR_BITS)
        w49_decode_stream(scalar_part, "payload").should eq(W49_SCALAR_LEAVES)

        maybe_reader = CrystalClick::WidePart.open_typed(maybe_part, "payload")
        maybe_reader.column_type.should eq("Nullable(BFloat16)")
        w49_nullable_bfloat16_bits(maybe_reader.read_nullable_bfloat16_mark_range("payload", 0, maybe_reader.mark_count)).should eq(W49_MAYBE_BITS)
        w49_decode_stream(maybe_part, "payload.null").should eq(W49_NULL_MAP)
        w49_decode_stream(maybe_part, "payload").should eq(W49_MAYBE_LEAVES)

        array_reader = CrystalClick::WidePart.open_typed(array_part, "payload")
        array_reader.column_type.should eq("Array(BFloat16)")
        w49_array_bfloat16_bits(array_reader.read_array_numeric_mark_range("payload", 0, array_reader.mark_count, CrystalClick::BFloat16Value)).should eq(W49_ARRAY_BITS)
        w49_decode_stream(array_part, "payload").should eq(W49_ARRAY_LEAVES)

        nullable_array_reader = CrystalClick::WidePart.open_typed(nullable_array_part, "payload")
        nullable_array_reader.column_type.should eq("Array(Nullable(BFloat16))")
        w49_array_nullable_bfloat16_bits(nullable_array_reader.read_array_nullable_numeric_mark_range("payload", 0, nullable_array_reader.mark_count, CrystalClick::BFloat16Value)).should eq(W49_NULLABLE_ARRAY_BITS)
        w49_decode_stream(nullable_array_part, "payload.null").should eq(W49_ARRAY_NULL_MAP)
        w49_decode_stream(nullable_array_part, "payload").should eq(W49_NULLABLE_ARRAY_LEAVES)

        {
          {scalar_part, "BFloat16"},
          {maybe_part, "Nullable(BFloat16)"},
          {array_part, "Array(BFloat16)"},
          {nullable_array_part, "Array(Nullable(BFloat16))"},
        }.each do |part, type|
          CrystalClick::WidePart.open_typed(part, "payload").column_type.should eq(type)
          CrystalClick::WidePart.open_typed(part, "payload").row_count.should eq(7_u64)
        end
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "ignores poisoned nested BFloat16 leaf bytes beneath scalar and Array NULLs" do
    root = File.tempname("crystal-click-w49-null-child")
    Dir.mkdir(root)
    begin
      keys = W49_KEYS.to_unsafe.to_slice(W49_KEYS.size)
      nullable_values = W49_MAYBE_BITS.map { |bits| bits.try { |value| CrystalClick::BFloat16Value.new(value) } }
      nullable_path = CrystalClick::WidePartWriter.write_uint64_nullable_bfloat16_pair(
        File.join(root, "nullable"), "pk", keys, "payload",
        nullable_values.to_unsafe.to_slice(nullable_values.size), 2
      )
      w49_reseal_first_frame_bytes(nullable_path, "payload", 0, [0x42_u8, 0xff_u8])
      w49_decode_stream(nullable_path, "payload")[0, 2].should eq([0x42_u8, 0xff_u8])
      CrystalClick::WidePart.open_typed(nullable_path, "payload")
        .read_nullable_bfloat16_mark_range("payload", 0, 4).should eq(nullable_values)

      nullable_array_values = W49_NULLABLE_ARRAY_BITS.map do |row|
        row.map { |bits| bits.try { |value| CrystalClick::BFloat16Value.new(value) } }
      end
      nullable_array_path = CrystalClick::WidePartWriter.write_uint64_array_nullable_bfloat16_pair(
        File.join(root, "nullable-array"), "pk", keys, "payload",
        nullable_array_values.to_unsafe.to_slice(nullable_array_values.size), 2
      )
      # Key 1 has an empty array, so the first child slot belongs to key 2's
      # leading NULL element. Leave the null map and array sizes untouched.
      w49_reseal_first_frame_bytes(nullable_array_path, "payload", 0, [0x42_u8, 0xff_u8])
      w49_decode_stream(nullable_array_path, "payload")[0, 2].should eq([0x42_u8, 0xff_u8])
      observed = CrystalClick::WidePart.open_typed(nullable_array_path, "payload")
        .read_array_nullable_numeric_mark_range("payload", 0, 4, CrystalClick::BFloat16Value)
      w49_array_nullable_bfloat16_bits(observed).should eq(W49_NULLABLE_ARRAY_BITS)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end

private def w49_sizes(counts : Array(Int32)) : Array(UInt8)
  counts.flat_map do |count|
    size = count.to_u64
    Array(UInt8).new(8) { |index| ((size >> (index * 8)) & 0xff_u64).to_u8 }
  end
end
