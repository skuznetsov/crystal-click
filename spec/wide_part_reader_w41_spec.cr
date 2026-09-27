require "./spec_helper"

W41_UUID_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_uuid_w41/part", __DIR__)
W41_KEYS         = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]

W41_UUID_ZERO = CrystalClick::UUIDValue.new(0_u64, 0_u64)
W41_UUID_A    = CrystalClick::UUIDValue.new(0x0011223344556677_u64, 0x8899aabbccddeeff_u64)
W41_UUID_B    = CrystalClick::UUIDValue.new(0x61f0c4045cb311e7_u64, 0x907ba6006ad3dba0_u64)
W41_UUID_C    = CrystalClick::UUIDValue.new(0x0123456789abcdef_u64, 0xfedcba9876543210_u64)
W41_UUID_D    = CrystalClick::UUIDValue.new(0x1020304050607080_u64, 0x90a0b0c0d0e0f001_u64)
W41_UUID_MAX  = CrystalClick::UUIDValue.new(UInt64::MAX, UInt64::MAX)

W41_UUID_ROWS = [
  [] of CrystalClick::UUIDValue,
  [W41_UUID_A, W41_UUID_ZERO],
  [W41_UUID_MAX],
  [] of CrystalClick::UUIDValue,
  [W41_UUID_B],
  [W41_UUID_C, W41_UUID_D],
  [] of CrystalClick::UUIDValue,
] of Array(CrystalClick::UUIDValue)

W41_NULLABLE_UUID_ROWS = [
  [] of CrystalClick::UUIDValue?,
  [nil, W41_UUID_ZERO] of CrystalClick::UUIDValue?,
  [nil, nil] of CrystalClick::UUIDValue?,
  [] of CrystalClick::UUIDValue?,
  [W41_UUID_C] of CrystalClick::UUIDValue?,
  [nil, W41_UUID_B] of CrystalClick::UUIDValue?,
  [] of CrystalClick::UUIDValue?,
] of Array(CrystalClick::UUIDValue?)

private def w41_catalog_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def with_w41_catalog_root(& : String ->)
  root = File.tempname("crystal-click-w41-offline-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    File.write(
      File.join(root, "metadata", "lab.sql"),
      "ATTACH DATABASE _ UUID 'f4f3f59b-2f8a-49ea-9b5e-26c089e67101'\nENGINE = Atomic\n"
    )
    database_path = w41_catalog_store_path(root, "f4f3f59b-2f8a-49ea-9b5e-26c089e67101")
    table_path = w41_catalog_store_path(root, "ed7b8c71-4eeb-4b83-92b2-09f278680c12")
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID 'ed7b8c71-4eeb-4b83-92b2-09f278680c12'\n(\n    `pk` UInt64,\n    `plain` Array(UUID),\n    `maybe` Array(Nullable(UUID))\n)\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W41_UUID_FIXTURE, File.join(table_path, "all_1_1_0"))
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w41_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w41_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w41_rewrite_first_frame_byte(path : String, stream : String, raw_offset : Int, value : UInt8) : Nil
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
  w41_write_u32(rewritten, header + 1, compressed_size.to_u32)
  w41_write_u32(rewritten, header + 5, raw.size.to_u32)
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
  w41_write_u64(rewritten, 0, hash[0])
  w41_write_u64(rewritten, 8, hash[1])

  old_frame_end = frame.end_offset.to_i
  delta = rewritten.size - old_frame_end
  result = Bytes.new(encoded.size + delta)
  rewritten.copy_to(result.to_unsafe, rewritten.size)
  encoded[old_frame_end, encoded.size - old_frame_end].copy_to(result.to_unsafe + rewritten.size, encoded.size - old_frame_end)
  File.write(data_path, result)

  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  (0...marks.size).step(CrystalClick::WidePart::MARK_SIZE) do |offset|
    compressed_offset = marks[offset, 8].to_slice
    value = 0_u64
    8.times { |byte| value |= compressed_offset[byte].to_u64 << (byte * 8) }
    if value >= old_frame_end.to_u64
      w41_write_u64(marks, offset, (value.to_i64 + delta).to_u64)
    end
  end
  File.write(marks_path, marks)
end

describe CrystalClick::WidePart do
  it "admits only canonical UUID Array leaves and their BASIC Nullable form" do
    CrystalClick::WidePart.supports_typed_type?("Array(UUID)").should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(Nullable(UUID))").should be_true

    {
      "Array(UUID(1))", "Array(UUID )",
      "Array(Array(UUID))", "Array(Nullable(Nullable(UUID)))", "Nullable(Array(UUID))",
      "Array(Nullable(UUID), UUID)",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads stock UUID arrays by mark range and preserves UUID half order and NULL identity" do
    plain = CrystalClick::WidePart.open_typed(W41_UUID_FIXTURE, "plain")
    plain.column_type.should eq("Array(UUID)")
    plain.row_count.should eq(7_u64)
    plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    plain.read_array_uuids_mark_range("plain", 0, plain.mark_count).should eq(W41_UUID_ROWS)
    plain.read_array_uuids_mark_range("plain", 1, 2).should eq(W41_UUID_ROWS[2, 4])
    plain.read_array_uuids_mark_range("plain", 3, 1).should eq(W41_UUID_ROWS[6, 1])

    maybe = CrystalClick::WidePart.open_typed(W41_UUID_FIXTURE, "maybe")
    maybe.column_type.should eq("Array(Nullable(UUID))")
    maybe.row_count.should eq(7_u64)
    maybe.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    maybe.read_array_nullable_uuids_mark_range("maybe", 0, maybe.mark_count).should eq(W41_NULLABLE_UUID_ROWS)
    maybe.read_array_nullable_uuids_mark_range("maybe", 1, 2).should eq(W41_NULLABLE_UUID_ROWS[2, 4])

    W41_NULLABLE_UUID_ROWS[1].should eq([nil, W41_UUID_ZERO])
    W41_NULLABLE_UUID_ROWS[2].should eq([nil, nil])
  end

  it "rejects same-width numeric, IPv6, nullable, and scalar UUID accessor aliases" do
    plain = CrystalClick::WidePart.open_typed(W41_UUID_FIXTURE, "plain")
    maybe = CrystalClick::WidePart.open_typed(W41_UUID_FIXTURE, "maybe")
    expect_raises(CrystalClick::UnsupportedFormatError) { plain.read_array_numeric_mark_range("plain", 0, 1, UInt128) }
    expect_raises(CrystalClick::UnsupportedFormatError) { plain.read_array_nullable_uuids_mark_range("plain", 0, 1) }
    expect_raises(CrystalClick::UnsupportedFormatError) { maybe.read_array_uuids_mark_range("maybe", 0, 1) }
    expect_raises(CrystalClick::UnsupportedFormatError) { plain.read_uuids_mark_range("plain", 0, 1) }
    expect_raises(CrystalClick::UnsupportedFormatError) { plain.read_ipv6s_mark_range("plain", 0, 1) }
  end

  it "fails closed on a malformed child mark and a checksum-consistent non-boolean Nullable map" do
    parent = File.tempname("crystal-click-w41-malformed-array-uuid")
    Dir.mkdir(parent)
    bad_mark = File.join(parent, "bad-mark")
    bad_null = File.join(parent, "bad-null")
    begin
      FileUtils.cp_r(W41_UUID_FIXTURE, bad_mark)
      mark_path = File.join(bad_mark, "#{CrystalClick::StreamName.hash("maybe.null")}.mrk2")
      marks = writable_file_bytes(mark_path).dup
      w41_write_u64(marks, CrystalClick::WidePart::MARK_SIZE + 8, UInt64::MAX)
      File.write(mark_path, marks)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(bad_mark, "maybe").read_array_nullable_uuids_mark_range("maybe", 0, 2)
      end

      FileUtils.cp_r(W41_UUID_FIXTURE, bad_null)
      w41_rewrite_first_frame_byte(bad_null, "maybe.null", 0, 2_u8)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(bad_null, "maybe").read_array_nullable_uuids_mark_range("maybe", 0, 2)
      end

      table_root = File.join(parent, "table")
      table_part = File.join(table_root, "all_1_1_0")
      FileUtils.mkdir_p(table_root)
      FileUtils.cp_r(bad_null, table_part)
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.open_selected_typed([table_part], ["pk", "maybe"]).scan_typed do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::WidePartTable do
  it "materializes exact UUID array declarations in typed mark batches and later row windows" do
    parent = File.tempname("crystal-click-w41-array-uuid-batch")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    begin
      FileUtils.cp_r(W41_UUID_FIXTURE, part)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "plain"])
      observed = [] of Array(CrystalClick::UUIDValue)
      shapes = [] of {Int32, UInt64, Int32}
      table.scan_typed(batch_rows: 3) do |batch|
        batch.column_type_for("plain").should eq("Array(UUID)")
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.column_type_for("missing") }
        values = batch.array_uuids_for("plain")
        observed.concat(values.map(&.dup))
        shapes << {batch.mark_index, batch.part_row_offset, values.size.to_i32}
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_nullable_uuids_for("plain") }
      end
      observed.should eq(W41_UUID_ROWS)
      shapes.should eq([
        {0_i32, 0_u64, 2_i32}, {1_i32, 2_u64, 2_i32},
        {2_i32, 4_u64, 2_i32}, {3_i32, 6_u64, 1_i32},
      ])

      later = [] of Array(CrystalClick::UUIDValue)
      table.scan_typed_window(4_u64, max_rows: 3) do |batch|
        later.concat(batch.array_uuids_for("plain").map(&.dup))
      end
      later.should eq(W41_UUID_ROWS[4, 3])

      nullable_table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "maybe"])
      nullable = [] of Array(CrystalClick::UUIDValue?)
      nullable_table.scan_typed(batch_rows: 2) do |batch|
        batch.column_type_for("maybe").should eq("Array(Nullable(UUID))")
        nullable.concat(batch.array_nullable_uuids_for("maybe").map(&.dup))
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_uuids_for("maybe") }
      end
      nullable.should eq(W41_NULLABLE_UUID_ROWS)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects UUID array accessors on same-width UInt128 arrays" do
    parent = File.tempname("crystal-click-w41-array-uuid-alias")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    keys = [1_u64, 2_u64]
    values = [[] of UInt128, [0_u128, UInt128::MAX]] of Array(UInt128)
    begin
      CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), rows_per_mark: 1
      )
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      checked = false
      table.scan_typed do |batch|
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_uuids_for("payload") }
        checked = true
      end
      checked.should be_true
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes UUID and Nullable(UUID) arrays with exact UUID halves and no null payload in RowBinary" do
    parent = File.tempname("crystal-click-w41-array-uuid-writer")
    Dir.mkdir(parent)
    plain_part = File.join(parent, "plain")
    nullable_part = File.join(parent, "nullable")
    begin
      CrystalClick::WidePartWriter.write_uint64_array_uuid_pair(
        plain_part, "pk", W41_KEYS.to_unsafe.to_slice(W41_KEYS.size), "payload",
        W41_UUID_ROWS.to_unsafe.to_slice(W41_UUID_ROWS.size), rows_per_mark: 2
      )
      plain = CrystalClick::WidePart.open_typed(plain_part, "payload")
      plain.column_type.should eq("Array(UUID)")
      plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      plain.read_array_uuids_mark_range("payload", 0, plain.mark_count).should eq(W41_UUID_ROWS)
      plain.read_array_uuids_mark_range("payload", 1, 2).should eq(W41_UUID_ROWS[2, 4])

      CrystalClick::WidePartWriter.write_uint64_array_nullable_uuid_pair(
        nullable_part, "pk", W41_KEYS.to_unsafe.to_slice(W41_KEYS.size), "payload",
        W41_NULLABLE_UUID_ROWS.to_unsafe.to_slice(W41_NULLABLE_UUID_ROWS.size), rows_per_mark: 2
      )
      nullable = CrystalClick::WidePart.open_typed(nullable_part, "payload")
      nullable.column_type.should eq("Array(Nullable(UUID))")
      nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      nullable.read_array_nullable_uuids_mark_range("payload", 0, nullable.mark_count).should eq(W41_NULLABLE_UUID_ROWS)
      nullable.read_array_nullable_uuids_mark_range("payload", 1, 2).should eq(W41_NULLABLE_UUID_ROWS[2, 4])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "does not publish UUID array parts for invalid input cardinality or mark sizing" do
    parent = File.tempname("crystal-click-w41-array-uuid-preflight")
    Dir.mkdir(parent)
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_uuid_pair(
          File.join(parent, "mismatch"), "pk", W41_KEYS.to_unsafe.to_slice(1), "payload",
          W41_UUID_ROWS.to_unsafe.to_slice(W41_UUID_ROWS.size), rows_per_mark: 2
        )
      end
      Dir.children(parent).should be_empty
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_nullable_uuid_pair(
          File.join(parent, "zero-mark"), "pk", W41_KEYS.to_unsafe.to_slice(W41_KEYS.size), "payload",
          W41_NULLABLE_UUID_ROWS.to_unsafe.to_slice(W41_NULLABLE_UUID_ROWS.size), rows_per_mark: 0
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::OfflineCatalog do
  it "materializes UUID array rows with exact declarations and caller-owned nested values" do
    with_w41_catalog_root do |root|
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"}, {"plain", "Array(UUID)"}, {"maybe", "Array(Nullable(UUID))"},
      ])
      table["plain"].values.map { |value| value.as(Array(CrystalClick::UUIDValue)) }.should eq(W41_UUID_ROWS)
      table["maybe"].values.map { |value| value.as(Array(CrystalClick::UUIDValue?)) }.should eq(W41_NULLABLE_UUID_ROWS)

      owned = table["plain"].values.map { |value| value.as(Array(CrystalClick::UUIDValue)) }
      owned[1][0] = W41_UUID_MAX
      owned[1] << W41_UUID_B
      table["plain"].values.map { |value| value.as(Array(CrystalClick::UUIDValue)) }.should eq(W41_UUID_ROWS)
    end
  end
end
