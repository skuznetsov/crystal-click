require "./spec_helper"
require "file_utils"

W47_IPV6_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_ipv6_w47/part", __DIR__)
W47_KEYS         = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]

W47_IPV6_ZERO     = CrystalClick::IPv6Value.from_hextets(0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16)
W47_IPV6_LOOPBACK = CrystalClick::IPv6Value.from_hextets(0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 1_u16)
W47_IPV6_A        = CrystalClick::IPv6Value.from_hextets(0x2001_u16, 0x0db8_u16, 0x0001_u16, 0x0203_u16, 0x0405_u16, 0x0607_u16, 0x0809_u16, 0x0a0b_u16)
W47_IPV6_B        = CrystalClick::IPv6Value.from_hextets(0xf001_u16, 0xe203_u16, 0xd405_u16, 0xc607_u16, 0xb809_u16, 0xa00b_u16, 0x1d2e_u16, 0x3f40_u16)
W47_IPV6_C        = CrystalClick::IPv6Value.from_hextets(0x2001_u16, 0x0db8_u16, 0xffff_u16, 0xeeee_u16, 0xdddd_u16, 0xcccc_u16, 0xbbbb_u16, 0xaaaa_u16)

W47_IPV6_ZERO_BYTES     = [0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
W47_IPV6_LOOPBACK_BYTES = [0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x01_u8]
W47_IPV6_A_BYTES        = [0x20_u8, 0x01_u8, 0x0d_u8, 0xb8_u8, 0x00_u8, 0x01_u8, 0x02_u8, 0x03_u8, 0x04_u8, 0x05_u8, 0x06_u8, 0x07_u8, 0x08_u8, 0x09_u8, 0x0a_u8, 0x0b_u8]
W47_IPV6_B_BYTES        = [0xf0_u8, 0x01_u8, 0xe2_u8, 0x03_u8, 0xd4_u8, 0x05_u8, 0xc6_u8, 0x07_u8, 0xb8_u8, 0x09_u8, 0xa0_u8, 0x0b_u8, 0x1d_u8, 0x2e_u8, 0x3f_u8, 0x40_u8]
W47_IPV6_C_BYTES        = [0x20_u8, 0x01_u8, 0x0d_u8, 0xb8_u8, 0xff_u8, 0xff_u8, 0xee_u8, 0xee_u8, 0xdd_u8, 0xdd_u8, 0xcc_u8, 0xcc_u8, 0xbb_u8, 0xbb_u8, 0xaa_u8, 0xaa_u8]

W47_IPV6_ROWS = [
  [] of CrystalClick::IPv6Value,
  [W47_IPV6_A, W47_IPV6_B, W47_IPV6_LOOPBACK, W47_IPV6_ZERO],
  [W47_IPV6_C],
  [] of CrystalClick::IPv6Value,
  [W47_IPV6_LOOPBACK, W47_IPV6_B],
  [W47_IPV6_ZERO],
  [] of CrystalClick::IPv6Value,
] of Array(CrystalClick::IPv6Value)

W47_NULLABLE_IPV6_ROWS = [
  [] of CrystalClick::IPv6Value?,
  [nil, W47_IPV6_ZERO, W47_IPV6_A, W47_IPV6_LOOPBACK] of CrystalClick::IPv6Value?,
  [nil, nil] of CrystalClick::IPv6Value?,
  [] of CrystalClick::IPv6Value?,
  [W47_IPV6_ZERO, nil, W47_IPV6_A] of CrystalClick::IPv6Value?,
  [W47_IPV6_ZERO, nil] of CrystalClick::IPv6Value?,
  [] of CrystalClick::IPv6Value?,
] of Array(CrystalClick::IPv6Value?)

private def w47_decode_stream(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  File.file?(path).should be_true
  encoded = File.read(path).to_slice
  encoded.empty? ? [] of UInt8 : CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w47_size_stream(values : Array(Array(T))) : Array(UInt8) forall T
  bytes = [] of UInt8
  values.each do |row|
    value = row.size.to_u64
    8.times { |index| bytes << ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w47_ipv6_bytes(value : CrystalClick::IPv6Value) : Array(UInt8)
  if value == W47_IPV6_ZERO
    W47_IPV6_ZERO_BYTES
  elsif value == W47_IPV6_LOOPBACK
    W47_IPV6_LOOPBACK_BYTES
  elsif value == W47_IPV6_A
    W47_IPV6_A_BYTES
  elsif value == W47_IPV6_B
    W47_IPV6_B_BYTES
  elsif value == W47_IPV6_C
    W47_IPV6_C_BYTES
  else
    raise "unexpected IPv6 test value: #{value}"
  end
end

private def w47_ipv6_payload(values : Array(Array(CrystalClick::IPv6Value))) : Array(UInt8)
  values.flat_map { |row| row.flat_map { |value| w47_ipv6_bytes(value) } }
end

private def w47_nullable_ipv6_payload(values : Array(Array(CrystalClick::IPv6Value?))) : Array(UInt8)
  values.flat_map do |row|
    row.flat_map { |value| value ? w47_ipv6_bytes(value) : Array.new(16, 0_u8) }
  end
end

private def w47_null_map(values : Array(Array(CrystalClick::IPv6Value?))) : Array(UInt8)
  values.flat_map { |row| row.map { |value| value.nil? ? 1_u8 : 0_u8 } }
end

private def w47_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def with_w47_catalog_root(& : String ->)
  root = File.tempname("crystal-click-w47-offline-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    File.write(
      File.join(root, "metadata", "lab.sql"),
      "ATTACH DATABASE _ UUID 'f462f136-3924-4f43-b278-28c181075a54'\nENGINE = Atomic\n"
    )
    database_path = w47_store_path(root, "f462f136-3924-4f43-b278-28c181075a54")
    table_path = w47_store_path(root, "a78f7c0e-b304-41f4-a947-4f51e22dc6f1")
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID 'a78f7c0e-b304-41f4-a947-4f51e22dc6f1'\n(\n" +
      "    `pk` UInt64,\n    `plain` Array(IPv6),\n" +
      "    `maybe` Array(Nullable(IPv6))\n)\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W47_IPV6_FIXTURE, File.join(table_path, "all_1_1_0"))
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w47_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w47_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

# Change the NULL child's first octet while keeping its ClickHouse frame
# checksum valid. The following :: value is a sentinel for correct slot advance.
private def w47_poison_first_null_child(path : String, stream : String) : Nil
  data_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(data_path).to_slice
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, 0_i64)
  raw = frame.output.dup
  raw[0] = 0x5a_u8

  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  rewritten = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  rewritten[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w47_write_u32(rewritten, header + 1, compressed_size.to_u32)
  w47_write_u32(rewritten, header + 5, raw.size.to_u32)
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
  w47_write_u64(rewritten, 0, hash[0])
  w47_write_u64(rewritten, 8, hash[1])

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
      w47_write_u64(marks, offset, (mark_offset.to_i64 + delta).to_u64)
    end
  end
  File.write(marks_path, marks)
end

describe CrystalClick::WidePart do
  it "admits only canonical IPv6 Array spellings and BASIC Nullable form" do
    CrystalClick::WidePart.supports_typed_type?("Array(IPv6)").should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(Nullable(IPv6))").should be_true

    {
      "Array(IPv6 )", "Array( IPv6)", "Array(Nullable( IPv6))",
      "Array(Nullable(IPv6 ))", "Array(Nullable(Nullable(IPv6)))",
      "Array(Array(IPv6))", "Nullable(Array(IPv6))", "Array(INET6)",
      "Array(Nullable(INET6))", "Array(IPv6, UInt8)",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads the pinned stock fixture across marks with exact network-order IPv6 octets" do
    plain = CrystalClick::WidePart.open_typed(W47_IPV6_FIXTURE, "plain")
    plain.column_type.should eq("Array(IPv6)")
    plain.row_count.should eq(7_u64)
    plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    plain.read_array_ipv6s_mark_range("plain", 0, plain.mark_count).should eq(W47_IPV6_ROWS)
    plain.read_array_ipv6s_mark_range("plain", 1, 2).should eq(W47_IPV6_ROWS[2, 4])
    plain.read_array_ipv6s_mark_range("plain", 3, 1).should eq(W47_IPV6_ROWS[6, 1])
    w47_decode_stream(W47_IPV6_FIXTURE, "plain.size0").should eq(w47_size_stream(W47_IPV6_ROWS))
    w47_decode_stream(W47_IPV6_FIXTURE, "plain").should eq(w47_ipv6_payload(W47_IPV6_ROWS))

    nullable = CrystalClick::WidePart.open_typed(W47_IPV6_FIXTURE, "maybe")
    nullable.column_type.should eq("Array(Nullable(IPv6))")
    nullable.row_count.should eq(7_u64)
    nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    nullable.read_array_nullable_ipv6s_mark_range("maybe", 0, nullable.mark_count).should eq(W47_NULLABLE_IPV6_ROWS)
    nullable.read_array_nullable_ipv6s_mark_range("maybe", 1, 2).should eq(W47_NULLABLE_IPV6_ROWS[2, 4])
    w47_decode_stream(W47_IPV6_FIXTURE, "maybe.size0").should eq(w47_size_stream(W47_NULLABLE_IPV6_ROWS))
    w47_decode_stream(W47_IPV6_FIXTURE, "maybe.null").should eq(w47_null_map(W47_NULLABLE_IPV6_ROWS))
    w47_decode_stream(W47_IPV6_FIXTURE, "maybe").should eq(w47_nullable_ipv6_payload(W47_NULLABLE_IPV6_ROWS))
  end

  it "consumes a nonzero child slot beneath NULL without shifting the next IPv6 value" do
    parent = File.tempname("crystal-click-w47-null-child")
    Dir.mkdir(parent)
    poisoned = File.join(parent, "poisoned")
    begin
      FileUtils.cp_r(W47_IPV6_FIXTURE, poisoned)
      w47_poison_first_null_child(poisoned, "maybe")
      w47_decode_stream(poisoned, "maybe")[0].should eq(0x5a_u8)

      reader = CrystalClick::WidePart.open_typed(poisoned, "maybe")
      reader.read_array_nullable_ipv6s_mark_range("maybe", 0, reader.mark_count).should eq(W47_NULLABLE_IPV6_ROWS)
      # The poisoned NULL is followed by a real, non-NULL :: sentinel.
      reader.read_array_nullable_ipv6s_mark_range("maybe", 0, 1)[1].should eq([nil, W47_IPV6_ZERO, W47_IPV6_A, W47_IPV6_LOOPBACK])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps IPv6 Array accessors distinct from UUID and same-width UInt128 Arrays" do
    parent = File.tempname("crystal-click-w47-array-ipv6-alias")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    uint128_values = [[] of UInt128, [0x20010db8000102030405060708090a0b_u128, UInt128::MAX]] of Array(UInt128)
    uuid_values = [[] of CrystalClick::UUIDValue, [CrystalClick::UUIDValue.new(0x20010db800010203_u64, 0x0405060708090a0b_u64)]] of Array(CrystalClick::UUIDValue)
    fixed_string_values = [[] of String, ["0123456789abcdef"]] of Array(String)
    begin
      uint128_root = File.join(parent, "uint128")
      Dir.mkdir(uint128_root)
      uint128_part = File.join(uint128_root, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
        uint128_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        uint128_values.to_unsafe.to_slice(uint128_values.size), rows_per_mark: 1
      )
      uint128_table = CrystalClick::WidePartTable.open_selected_typed([uint128_part], ["pk", "payload"])
      uint128_checked = false
      uint128_table.scan_typed do |batch|
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_ipv6s_for("payload") }
        uint128_checked = true
      end
      uint128_checked.should be_true

      uuid_root = File.join(parent, "uuid")
      Dir.mkdir(uuid_root)
      uuid_part = File.join(uuid_root, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_array_uuid_pair(
        uuid_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        uuid_values.to_unsafe.to_slice(uuid_values.size), rows_per_mark: 1
      )
      uuid_table = CrystalClick::WidePartTable.open_selected_typed([uuid_part], ["pk", "payload"])
      uuid_checked = false
      uuid_table.scan_typed do |batch|
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_ipv6s_for("payload") }
        uuid_checked = true
      end
      uuid_checked.should be_true

      fixed_string_root = File.join(parent, "fixed-string")
      Dir.mkdir(fixed_string_root)
      fixed_string_part = File.join(fixed_string_root, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_array_fixed_string_pair(
        fixed_string_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        fixed_string_values.to_unsafe.to_slice(fixed_string_values.size), 16, rows_per_mark: 1
      )
      fixed_string_table = CrystalClick::WidePartTable.open_selected_typed([fixed_string_part], ["pk", "payload"])
      fixed_string_checked = false
      fixed_string_table.scan_typed do |batch|
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_ipv6s_for("payload") }
        fixed_string_checked = true
      end
      fixed_string_checked.should be_true
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes IPv6 and Nullable(IPv6) Arrays with exact network-order leaves" do
    parent = File.tempname("crystal-click-w47-array-ipv6-writer")
    Dir.mkdir(parent)
    plain_part = File.join(parent, "plain")
    nullable_part = File.join(parent, "nullable")
    begin
      CrystalClick::WidePartWriter.write_uint64_array_ipv6_pair(
        plain_part, "pk", W47_KEYS.to_unsafe.to_slice(W47_KEYS.size), "payload",
        W47_IPV6_ROWS.to_unsafe.to_slice(W47_IPV6_ROWS.size), rows_per_mark: 2
      )
      plain = CrystalClick::WidePart.open_typed(plain_part, "payload")
      plain.column_type.should eq("Array(IPv6)")
      plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      plain.read_array_ipv6s_mark_range("payload", 0, plain.mark_count).should eq(W47_IPV6_ROWS)
      w47_decode_stream(plain_part, "payload.size0").should eq(w47_size_stream(W47_IPV6_ROWS))
      w47_decode_stream(plain_part, "payload").should eq(w47_ipv6_payload(W47_IPV6_ROWS))

      CrystalClick::WidePartWriter.write_uint64_array_nullable_ipv6_pair(
        nullable_part, "pk", W47_KEYS.to_unsafe.to_slice(W47_KEYS.size), "payload",
        W47_NULLABLE_IPV6_ROWS.to_unsafe.to_slice(W47_NULLABLE_IPV6_ROWS.size), rows_per_mark: 2
      )
      nullable = CrystalClick::WidePart.open_typed(nullable_part, "payload")
      nullable.column_type.should eq("Array(Nullable(IPv6))")
      nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      nullable.read_array_nullable_ipv6s_mark_range("payload", 0, nullable.mark_count).should eq(W47_NULLABLE_IPV6_ROWS)
      w47_decode_stream(nullable_part, "payload.size0").should eq(w47_size_stream(W47_NULLABLE_IPV6_ROWS))
      w47_decode_stream(nullable_part, "payload.null").should eq(w47_null_map(W47_NULLABLE_IPV6_ROWS))
      w47_decode_stream(nullable_part, "payload").should eq(w47_nullable_ipv6_payload(W47_NULLABLE_IPV6_ROWS))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes all-empty arrays and nonempty all-NULL controls" do
    parent = File.tempname("crystal-click-w47-array-ipv6-empty-writer")
    Dir.mkdir(parent)
    begin
      empty_plain = Array.new(W47_KEYS.size) { [] of CrystalClick::IPv6Value }
      empty_nullable = Array.new(W47_KEYS.size) { [] of CrystalClick::IPv6Value? }
      empty_plain_part = File.join(parent, "empty-plain")
      empty_nullable_part = File.join(parent, "empty-nullable")
      CrystalClick::WidePartWriter.write_uint64_array_ipv6_pair(
        empty_plain_part, "pk", W47_KEYS.to_unsafe.to_slice(W47_KEYS.size), "payload",
        empty_plain.to_unsafe.to_slice(empty_plain.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_nullable_ipv6_pair(
        empty_nullable_part, "pk", W47_KEYS.to_unsafe.to_slice(W47_KEYS.size), "payload",
        empty_nullable.to_unsafe.to_slice(empty_nullable.size), rows_per_mark: 2
      )
      w47_decode_stream(empty_plain_part, "payload.size0").should eq(w47_size_stream(empty_plain))
      w47_decode_stream(empty_plain_part, "payload").should be_empty
      w47_decode_stream(empty_nullable_part, "payload.size0").should eq(w47_size_stream(empty_nullable))
      w47_decode_stream(empty_nullable_part, "payload.null").should be_empty
      w47_decode_stream(empty_nullable_part, "payload").should be_empty

      all_null = Array.new(W47_KEYS.size) { [nil, nil] of CrystalClick::IPv6Value? }
      all_null_part = File.join(parent, "all-null")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_ipv6_pair(
        all_null_part, "pk", W47_KEYS.to_unsafe.to_slice(W47_KEYS.size), "payload",
        all_null.to_unsafe.to_slice(all_null.size), rows_per_mark: 2
      )
      all_null_reader = CrystalClick::WidePart.open_typed(all_null_part, "payload")
      all_null_reader.read_array_nullable_ipv6s_mark_range("payload", 0, all_null_reader.mark_count).should eq(all_null)
      w47_decode_stream(all_null_part, "payload.null").should eq(Array.new(W47_KEYS.size * 2, 1_u8))
      w47_decode_stream(all_null_part, "payload").should eq(Array.new(W47_KEYS.size * 2 * 16, 0_u8))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects invalid Array dimensions before publishing an IPv6 part" do
    parent = File.tempname("crystal-click-w47-array-ipv6-preflight")
    Dir.mkdir(parent)
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_ipv6_pair(
          File.join(parent, "mismatch"), "pk", W47_KEYS.to_unsafe.to_slice(1), "payload",
          W47_IPV6_ROWS.to_unsafe.to_slice(W47_IPV6_ROWS.size), rows_per_mark: 2
        )
      end
      Dir.children(parent).should be_empty
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_nullable_ipv6_pair(
          File.join(parent, "zero-mark"), "pk", W47_KEYS.to_unsafe.to_slice(W47_KEYS.size), "payload",
          W47_NULLABLE_IPV6_ROWS.to_unsafe.to_slice(W47_NULLABLE_IPV6_ROWS.size), rows_per_mark: 0
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::OfflineCatalog do
  it "materializes IPv6 Array rows through the typed catalog with owned nested values" do
    with_w47_catalog_root do |root|
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"}, {"plain", "Array(IPv6)"}, {"maybe", "Array(Nullable(IPv6))"},
      ])

      plain = [] of Array(CrystalClick::IPv6Value)
      nullable = [] of Array(CrystalClick::IPv6Value?)
      table.scan_typed(["plain", "maybe"], batch_rows: 3) do |batch|
        batch.column_type_for("plain").should eq("Array(IPv6)")
        batch.column_type_for("maybe").should eq("Array(Nullable(IPv6))")
        plain.concat(batch.array_ipv6s_for("plain").map(&.dup))
        nullable.concat(batch.array_nullable_ipv6s_for("maybe").map(&.dup))
      end
      plain.should eq(W47_IPV6_ROWS)
      nullable.should eq(W47_NULLABLE_IPV6_ROWS)

      later = [] of Array(CrystalClick::IPv6Value?)
      table.scan_typed_window(["maybe"], 4_u64, max_rows: 3) do |batch|
        later.concat(batch.array_nullable_ipv6s_for("maybe").map(&.dup))
      end
      later.should eq(W47_NULLABLE_IPV6_ROWS[4, 3])

      owned = table["plain"].values.map { |value| value.as(Array(CrystalClick::IPv6Value)) }
      owned[1] << W47_IPV6_C
      table["plain"].values.map { |value| value.as(Array(CrystalClick::IPv6Value)) }.should eq(W47_IPV6_ROWS)
    end
  end
end
