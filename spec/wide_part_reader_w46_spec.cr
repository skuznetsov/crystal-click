require "./spec_helper"

W46_IPV4_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_ipv4_w46/part", __DIR__)
W46_KEYS         = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]

W46_IPV4_ZERO = CrystalClick::IPv4Value.from_octets(0_u8, 0_u8, 0_u8, 0_u8)
W46_IPV4_A    = CrystalClick::IPv4Value.from_octets(192_u8, 0_u8, 2_u8, 1_u8)
W46_IPV4_B    = CrystalClick::IPv4Value.from_octets(1_u8, 2_u8, 0_u8, 192_u8)
W46_IPV4_C    = CrystalClick::IPv4Value.from_octets(203_u8, 0_u8, 113_u8, 9_u8)
W46_IPV4_D    = CrystalClick::IPv4Value.from_octets(198_u8, 51_u8, 100_u8, 7_u8)

W46_IPV4_ROWS = [
  [] of CrystalClick::IPv4Value,
  [W46_IPV4_A, W46_IPV4_B, W46_IPV4_C],
  [W46_IPV4_ZERO],
  [] of CrystalClick::IPv4Value,
  [W46_IPV4_D],
  [W46_IPV4_A],
  [] of CrystalClick::IPv4Value,
] of Array(CrystalClick::IPv4Value)

W46_NULLABLE_IPV4_ROWS = [
  [] of CrystalClick::IPv4Value?,
  [nil, W46_IPV4_ZERO, W46_IPV4_A] of CrystalClick::IPv4Value?,
  [nil, nil] of CrystalClick::IPv4Value?,
  [] of CrystalClick::IPv4Value?,
  [W46_IPV4_C, nil] of CrystalClick::IPv4Value?,
  [W46_IPV4_A] of CrystalClick::IPv4Value?,
  [] of CrystalClick::IPv4Value?,
] of Array(CrystalClick::IPv4Value?)

private def w46_decode_stream(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  encoded = File.read(path).to_slice
  encoded.empty? ? [] of UInt8 : CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w46_size_stream(values : Array(Array(T))) : Array(UInt8) forall T
  bytes = [] of UInt8
  values.each do |row|
    value = row.size.to_u64
    8.times { |index| bytes << ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w46_ipv4_payload(values : Array(Array(CrystalClick::IPv4Value))) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |row|
    row.each do |value|
      network_order = value.network_order
      4.times { |index| bytes << ((network_order >> (index * 8)) & 0xff_u32).to_u8 }
    end
  end
  bytes
end

private def w46_nullable_ipv4_payload(values : Array(Array(CrystalClick::IPv4Value?))) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |row|
    row.each do |value|
      network_order = value.try(&.network_order) || 0_u32
      4.times { |index| bytes << ((network_order >> (index * 8)) & 0xff_u32).to_u8 }
    end
  end
  bytes
end

private def w46_null_map(values : Array(Array(CrystalClick::IPv4Value?))) : Array(UInt8)
  values.flat_map { |row| row.map { |value| value.nil? ? 1_u8 : 0_u8 } }
end

private def w46_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def with_w46_catalog_root(& : String ->)
  root = File.tempname("crystal-click-w46-offline-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    File.write(
      File.join(root, "metadata", "lab.sql"),
      "ATTACH DATABASE _ UUID 'f462f136-3924-4f43-b278-28c181075a54'\nENGINE = Atomic\n"
    )
    database_path = w46_store_path(root, "f462f136-3924-4f43-b278-28c181075a54")
    table_path = w46_store_path(root, "a78f7c0e-b304-41f4-a947-4f51e22dc6f1")
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID 'a78f7c0e-b304-41f4-a947-4f51e22dc6f1'\n(\n" +
      "    `pk` UInt64,\n    `plain` Array(IPv4),\n" +
      "    `maybe` Array(Nullable(IPv4))\n)\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W46_IPV4_FIXTURE, File.join(table_path, "all_1_1_0"))
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w46_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w46_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

# Rewrite one byte in a raw first LZ4 block while resealing its ClickHouse
# CityHash checksum and adjusting later mark compressed offsets. This allows
# a nonzero payload beneath a NULL bit without invalidating the frame itself.
private def w46_rewrite_first_frame_byte(path : String, stream : String, raw_offset : Int, value : UInt8) : Nil
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
  w46_write_u32(rewritten, header + 1, compressed_size.to_u32)
  w46_write_u32(rewritten, header + 5, raw.size.to_u32)
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
  w46_write_u64(rewritten, 0, hash[0])
  w46_write_u64(rewritten, 8, hash[1])

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
    mark_offset = 0_u64
    8.times { |byte| mark_offset |= compressed_offset[byte].to_u64 << (byte * 8) }
    if mark_offset >= old_frame_end.to_u64
      w46_write_u64(marks, offset, (mark_offset.to_i64 + delta).to_u64)
    end
  end
  File.write(marks_path, marks)
end

describe CrystalClick::WidePart do
  it "admits canonical IPv4 array spellings while rejecting nested and neighboring types" do
    # Keep the original behaviorally RED admission assertions intact.
    CrystalClick::WidePart.supports_typed_type?("Array(IPv4)").should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(Nullable(IPv4))").should be_true

    {
      "Array(IPv4 )", "Array( IPv4)", "Array(Nullable( IPv4))",
      "Array(Nullable(Nullable(IPv4)))", "Array(Array(IPv4))",
      "Nullable(Array(IPv4))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads the pinned stock fixture across marks and verifies exact IPv4 leaf bytes" do
    plain = CrystalClick::WidePart.open_typed(W46_IPV4_FIXTURE, "plain")
    plain.column_type.should eq("Array(IPv4)")
    plain.row_count.should eq(7_u64)
    plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    plain.read_array_ipv4s_mark_range("plain", 0, plain.mark_count).should eq(W46_IPV4_ROWS)
    plain.read_array_ipv4s_mark_range("plain", 1, 2).should eq(W46_IPV4_ROWS[2, 4])
    plain.read_array_ipv4s_mark_range("plain", 3, 1).should eq(W46_IPV4_ROWS[6, 1])
    w46_decode_stream(W46_IPV4_FIXTURE, "plain.size0").should eq(w46_size_stream(W46_IPV4_ROWS))
    w46_decode_stream(W46_IPV4_FIXTURE, "plain").should eq(w46_ipv4_payload(W46_IPV4_ROWS))

    nullable = CrystalClick::WidePart.open_typed(W46_IPV4_FIXTURE, "maybe")
    nullable.column_type.should eq("Array(Nullable(IPv4))")
    nullable.row_count.should eq(7_u64)
    nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    nullable.read_array_nullable_ipv4s_mark_range("maybe", 0, nullable.mark_count).should eq(W46_NULLABLE_IPV4_ROWS)
    nullable.read_array_nullable_ipv4s_mark_range("maybe", 1, 2).should eq(W46_NULLABLE_IPV4_ROWS[2, 4])
    w46_decode_stream(W46_IPV4_FIXTURE, "maybe.size0").should eq(w46_size_stream(W46_NULLABLE_IPV4_ROWS))
    w46_decode_stream(W46_IPV4_FIXTURE, "maybe.null").should eq(w46_null_map(W46_NULLABLE_IPV4_ROWS))
    w46_decode_stream(W46_IPV4_FIXTURE, "maybe").should eq(w46_nullable_ipv4_payload(W46_NULLABLE_IPV4_ROWS))

    W46_IPV4_ROWS[1].map(&.to_s).should eq(["192.0.2.1", "1.2.0.192", "203.0.113.9"])
    W46_NULLABLE_IPV4_ROWS[1].should eq([nil, W46_IPV4_ZERO, W46_IPV4_A])
    W46_NULLABLE_IPV4_ROWS[2].should eq([nil, nil])
    w46_decode_stream(W46_IPV4_FIXTURE, "maybe")[0, 8].should eq(Array.new(8, 0_u8))
  end

  it "decodes NULL independently of its nested IPv4 payload bytes" do
    parent = File.tempname("crystal-click-w46-null-payload")
    Dir.mkdir(parent)
    mutated = File.join(parent, "mutated")
    begin
      FileUtils.cp_r(W46_IPV4_FIXTURE, mutated)
      w46_rewrite_first_frame_byte(mutated, "maybe", 0, 0x7f_u8)
      values = CrystalClick::WidePart.open_typed(mutated, "maybe")
        .read_array_nullable_ipv4s_mark_range("maybe", 0, 1)
      values.should eq([[] of CrystalClick::IPv4Value?, [nil, W46_IPV4_ZERO, W46_IPV4_A]])
      w46_decode_stream(mutated, "maybe")[0].should eq(0x7f_u8)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects malformed physical declarations and cross-semantic accessors" do
    parent = File.tempname("crystal-click-w46-type-rejections")
    Dir.mkdir(parent)
    begin
      [
        {"Array(IPv4)", "Array(IPv4 )"},
        {"Array(Nullable(IPv4))", "Array(Nullable(Nullable(IPv4)))"},
      ].each_with_index do |(canonical, malformed), index|
        bad_part = File.join(parent, "bad-type-#{index}")
        FileUtils.cp_r(W46_IPV4_FIXTURE, bad_part)
        columns_path = File.join(bad_part, "columns.txt")
        original = File.read(columns_path)
        mutated = original.sub(canonical, malformed)
        mutated.should_not eq(original)
        File.write(columns_path, mutated)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_typed(bad_part, "plain")
        end
      end

      plain = CrystalClick::WidePart.open_typed(W46_IPV4_FIXTURE, "plain")
      nullable = CrystalClick::WidePart.open_typed(W46_IPV4_FIXTURE, "maybe")
      expect_raises(CrystalClick::UnsupportedFormatError) { plain.read_array_nullable_ipv4s_mark_range("plain", 0, 1) }
      expect_raises(CrystalClick::UnsupportedFormatError) { nullable.read_array_ipv4s_mark_range("maybe", 0, 1) }
      expect_raises(CrystalClick::UnsupportedFormatError) { plain.read_array_numeric_mark_range("plain", 0, 1, UInt32) }
      expect_raises(CrystalClick::BoundsError) { plain.read_array_ipv4s_mark_range("plain", 0, 0) }
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::WidePartTable do
  it "materializes exact IPv4 Array types in batches and later row windows" do
    parent = File.tempname("crystal-click-w46-array-ipv4-batch")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    begin
      FileUtils.cp_r(W46_IPV4_FIXTURE, part)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "plain"])
      observed = [] of Array(CrystalClick::IPv4Value)
      shapes = [] of {Int32, UInt64, Int32}
      table.scan_typed(batch_rows: 3) do |batch|
        batch.column_type_for("plain").should eq("Array(IPv4)")
        values = batch.array_ipv4s_for("plain")
        observed.concat(values.map(&.dup))
        shapes << {batch.mark_index, batch.part_row_offset, values.size.to_i32}
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_nullable_ipv4s_for("plain") }
      end
      observed.should eq(W46_IPV4_ROWS)
      shapes.should eq([
        {0_i32, 0_u64, 2_i32}, {1_i32, 2_u64, 2_i32},
        {2_i32, 4_u64, 2_i32}, {3_i32, 6_u64, 1_i32},
      ])

      later = [] of Array(CrystalClick::IPv4Value)
      table.scan_typed_window(4_u64, max_rows: 3) do |batch|
        later.concat(batch.array_ipv4s_for("plain").map(&.dup))
      end
      later.should eq(W46_IPV4_ROWS[4, 3])

      nullable_table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "maybe"])
      nullable = [] of Array(CrystalClick::IPv4Value?)
      nullable_table.scan_typed(batch_rows: 2) do |batch|
        batch.column_type_for("maybe").should eq("Array(Nullable(IPv4))")
        nullable.concat(batch.array_nullable_ipv4s_for("maybe").map(&.dup))
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_ipv4s_for("maybe") }
      end
      nullable.should eq(W46_NULLABLE_IPV4_ROWS)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps IPv4 Array accessors distinct from same-width UInt32 Array data" do
    parent = File.tempname("crystal-click-w46-array-ipv4-alias")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    keys = [1_u64, 2_u64]
    values = [[] of UInt32, [0_u32, UInt32::MAX]] of Array(UInt32)
    begin
      CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), rows_per_mark: 1
      )
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      checked = false
      table.scan_typed do |batch|
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_ipv4s_for("payload") }
        checked = true
      end
      checked.should be_true
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes IPv4 and Nullable(IPv4) Array values with BASIC nullable slots" do
    parent = File.tempname("crystal-click-w46-array-ipv4-writer")
    Dir.mkdir(parent)
    plain_part = File.join(parent, "plain")
    nullable_part = File.join(parent, "nullable")
    begin
      CrystalClick::WidePartWriter.write_uint64_array_ipv4_pair(
        plain_part, "pk", W46_KEYS.to_unsafe.to_slice(W46_KEYS.size), "payload",
        W46_IPV4_ROWS.to_unsafe.to_slice(W46_IPV4_ROWS.size), rows_per_mark: 2
      )
      plain = CrystalClick::WidePart.open_typed(plain_part, "payload")
      plain.column_type.should eq("Array(IPv4)")
      plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      plain.read_array_ipv4s_mark_range("payload", 0, plain.mark_count).should eq(W46_IPV4_ROWS)
      w46_decode_stream(plain_part, "payload.size0").should eq(w46_size_stream(W46_IPV4_ROWS))
      w46_decode_stream(plain_part, "payload").should eq(w46_ipv4_payload(W46_IPV4_ROWS))

      CrystalClick::WidePartWriter.write_uint64_array_nullable_ipv4_pair(
        nullable_part, "pk", W46_KEYS.to_unsafe.to_slice(W46_KEYS.size), "payload",
        W46_NULLABLE_IPV4_ROWS.to_unsafe.to_slice(W46_NULLABLE_IPV4_ROWS.size), rows_per_mark: 2
      )
      nullable = CrystalClick::WidePart.open_typed(nullable_part, "payload")
      nullable.column_type.should eq("Array(Nullable(IPv4))")
      nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      nullable.read_array_nullable_ipv4s_mark_range("payload", 0, nullable.mark_count).should eq(W46_NULLABLE_IPV4_ROWS)
      w46_decode_stream(nullable_part, "payload.null").should eq(w46_null_map(W46_NULLABLE_IPV4_ROWS))
      w46_decode_stream(nullable_part, "payload").should eq(w46_nullable_ipv4_payload(W46_NULLABLE_IPV4_ROWS))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes fully empty arrays and nonempty all-NULL controls" do
    parent = File.tempname("crystal-click-w46-array-ipv4-empty-writer")
    Dir.mkdir(parent)
    begin
      empty_plain = Array.new(W46_KEYS.size) { [] of CrystalClick::IPv4Value }
      empty_nullable = Array.new(W46_KEYS.size) { [] of CrystalClick::IPv4Value? }
      empty_plain_part = File.join(parent, "empty-plain")
      empty_nullable_part = File.join(parent, "empty-nullable")
      CrystalClick::WidePartWriter.write_uint64_array_ipv4_pair(
        empty_plain_part, "pk", W46_KEYS.to_unsafe.to_slice(W46_KEYS.size), "payload",
        empty_plain.to_unsafe.to_slice(empty_plain.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_nullable_ipv4_pair(
        empty_nullable_part, "pk", W46_KEYS.to_unsafe.to_slice(W46_KEYS.size), "payload",
        empty_nullable.to_unsafe.to_slice(empty_nullable.size), rows_per_mark: 2
      )
      w46_decode_stream(empty_plain_part, "payload.size0").should eq(w46_size_stream(empty_plain))
      w46_decode_stream(empty_nullable_part, "payload.size0").should eq(w46_size_stream(empty_nullable))
      w46_decode_stream(empty_nullable_part, "payload.null").should be_empty
      w46_decode_stream(empty_nullable_part, "payload").should be_empty

      all_null = Array.new(W46_KEYS.size) { [nil, nil] of CrystalClick::IPv4Value? }
      all_null_part = File.join(parent, "all-null")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_ipv4_pair(
        all_null_part, "pk", W46_KEYS.to_unsafe.to_slice(W46_KEYS.size), "payload",
        all_null.to_unsafe.to_slice(all_null.size), rows_per_mark: 2
      )
      all_null_reader = CrystalClick::WidePart.open_typed(all_null_part, "payload")
      all_null_reader.read_array_nullable_ipv4s_mark_range("payload", 0, all_null_reader.mark_count).should eq(all_null)
      w46_decode_stream(all_null_part, "payload.null").should eq(Array.new(W46_KEYS.size * 2, 1_u8))
      w46_decode_stream(all_null_part, "payload").should eq(Array.new(W46_KEYS.size * 2 * 4, 0_u8))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "does not publish IPv4 Array parts for invalid cardinality or mark sizing" do
    parent = File.tempname("crystal-click-w46-array-ipv4-preflight")
    Dir.mkdir(parent)
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_ipv4_pair(
          File.join(parent, "mismatch"), "pk", W46_KEYS.to_unsafe.to_slice(1), "payload",
          W46_IPV4_ROWS.to_unsafe.to_slice(W46_IPV4_ROWS.size), rows_per_mark: 2
        )
      end
      Dir.children(parent).should be_empty
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_nullable_ipv4_pair(
          File.join(parent, "zero-mark"), "pk", W46_KEYS.to_unsafe.to_slice(W46_KEYS.size), "payload",
          W46_NULLABLE_IPV4_ROWS.to_unsafe.to_slice(W46_NULLABLE_IPV4_ROWS.size), rows_per_mark: 0
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::OfflineCatalog do
  it "materializes IPv4 Array rows through the typed catalog with owned nested values" do
    with_w46_catalog_root do |root|
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"}, {"plain", "Array(IPv4)"}, {"maybe", "Array(Nullable(IPv4))"},
      ])

      plain = [] of Array(CrystalClick::IPv4Value)
      nullable = [] of Array(CrystalClick::IPv4Value?)
      table.scan_typed(["plain", "maybe"], batch_rows: 3) do |batch|
        batch.column_type_for("plain").should eq("Array(IPv4)")
        batch.column_type_for("maybe").should eq("Array(Nullable(IPv4))")
        plain.concat(batch.array_ipv4s_for("plain").map(&.dup))
        nullable.concat(batch.array_nullable_ipv4s_for("maybe").map(&.dup))
      end
      plain.should eq(W46_IPV4_ROWS)
      nullable.should eq(W46_NULLABLE_IPV4_ROWS)

      later = [] of Array(CrystalClick::IPv4Value?)
      table.scan_typed_window(["maybe"], 4_u64, max_rows: 3) do |batch|
        later.concat(batch.array_nullable_ipv4s_for("maybe").map(&.dup))
      end
      later.should eq(W46_NULLABLE_IPV4_ROWS[4, 3])

      owned = table["plain"].values.map { |value| value.as(Array(CrystalClick::IPv4Value)) }
      owned[1] << W46_IPV4_D
      table["plain"].values.map { |value| value.as(Array(CrystalClick::IPv4Value)) }.should eq(W46_IPV4_ROWS)
    end
  end
end
