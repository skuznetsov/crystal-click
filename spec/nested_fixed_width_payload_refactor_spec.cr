require "./spec_helper"

# Public-API characterization for the neutral reconstruction-loop extraction.
# These parts are emitted by the local writer and checked against literal rows;
# this is reader behavior coverage, not an independent ClickHouse-format proof.

private def nfw_temporal_rows(type : T.class) : Array(Array(Array(T))) forall T
  rows = [] of Array(Array(T))
  {% if T == UInt16 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[0_u16, UInt16::MAX] of T, [] of T, [7_u16] of T]
    rows << [[1_u16] of T]
    rows << [[3_u16, 4_u16] of T, [] of T]
  {% elsif T == Int32 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[Int32::MIN, Int32::MAX] of T, [] of T, [-7_i32] of T]
    rows << [[1_i32] of T]
    rows << [[3_i32, 4_i32] of T, [] of T]
  {% elsif T == UInt32 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[0_u32, UInt32::MAX] of T, [] of T, [7_u32] of T]
    rows << [[1_u32] of T]
    rows << [[3_u32, 4_u32] of T, [] of T]
  {% elsif T == Int64 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[Int64::MIN, Int64::MAX] of T, [] of T, [-7_i64] of T]
    rows << [[1_i64] of T]
    rows << [[3_i64, 4_i64] of T, [] of T]
  {% else %}
    {% raise "unsupported nested temporal carrier in characterization" %}
  {% end %}
  rows
end

private def nfw_nullable_temporal_rows(type : T.class) : Array(Array(Array(T?))) forall T
  rows = [] of Array(Array(T?))
  {% if T == UInt16 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, 7_u16, nil] of T?, [] of T?, [UInt16::MAX] of T?]
    rows << [[nil, 42_u16] of T?, [3_u16, nil] of T?]
    rows << [[1_u16] of T?]
  {% elsif T == Int32 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, 7_i32, nil] of T?, [] of T?, [Int32::MAX] of T?]
    rows << [[nil, 42_i32] of T?, [3_i32, nil] of T?]
    rows << [[-1_i32] of T?]
  {% elsif T == UInt32 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, 7_u32, nil] of T?, [] of T?, [UInt32::MAX] of T?]
    rows << [[nil, 42_u32] of T?, [3_u32, nil] of T?]
    rows << [[1_u32] of T?]
  {% elsif T == Int64 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, 7_i64, nil] of T?, [] of T?, [Int64::MAX] of T?]
    rows << [[nil, 42_i64] of T?, [3_i64, nil] of T?]
    rows << [[-1_i64] of T?]
  {% else %}
    {% raise "unsupported nested nullable temporal carrier in characterization" %}
  {% end %}
  rows
end

private def nfw_write_temporal(part : String, rows : Array(Array(Array(T)))) : Nil forall T
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
  {% if T == UInt16 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_date_pair(part, "pk", keys.to_unsafe.to_slice(5), "payload", rows.to_unsafe.to_slice(5), rows_per_mark: 2)
  {% elsif T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_date32_pair(part, "pk", keys.to_unsafe.to_slice(5), "payload", rows.to_unsafe.to_slice(5), rows_per_mark: 2)
  {% elsif T == UInt32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_datetime_pair(part, "pk", keys.to_unsafe.to_slice(5), "payload", rows.to_unsafe.to_slice(5), rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_datetime64_pair(part, "pk", keys.to_unsafe.to_slice(5), "payload", rows.to_unsafe.to_slice(5), 3, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported nested temporal carrier in characterization" %}
  {% end %}
  nil
end

private def nfw_write_nullable_temporal(part : String, rows : Array(Array(Array(T?)))) : Nil forall T
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
  {% if T == UInt16 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_date_pair(part, "pk", keys.to_unsafe.to_slice(5), "payload", rows.to_unsafe.to_slice(5), rows_per_mark: 2)
  {% elsif T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_date32_pair(part, "pk", keys.to_unsafe.to_slice(5), "payload", rows.to_unsafe.to_slice(5), rows_per_mark: 2)
  {% elsif T == UInt32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_datetime_pair(part, "pk", keys.to_unsafe.to_slice(5), "payload", rows.to_unsafe.to_slice(5), rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_datetime64_pair(part, "pk", keys.to_unsafe.to_slice(5), "payload", rows.to_unsafe.to_slice(5), 3, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported nested temporal carrier in characterization" %}
  {% end %}
  nil
end

private def nfw_read_temporal(reader : CrystalClick::WidePart, type : T.class, first_mark : Int, mark_count : Int) : Array(Array(Array(T))) forall T
  {% if T == UInt16 %}
    reader.read_array_array_date_codes_mark_range("payload", first_mark, mark_count)
  {% elsif T == Int32 %}
    reader.read_array_array_date32_codes_mark_range("payload", first_mark, mark_count)
  {% elsif T == UInt32 %}
    reader.read_array_array_datetime_seconds_mark_range("payload", first_mark, mark_count)
  {% elsif T == Int64 %}
    reader.read_array_array_datetime64_ticks_mark_range("payload", first_mark, mark_count)
  {% else %}
    {% raise "unsupported nested temporal carrier in characterization" %}
  {% end %}
end

private def nfw_read_nullable_temporal(reader : CrystalClick::WidePart, type : T.class, first_mark : Int, mark_count : Int) : Array(Array(Array(T?))) forall T
  {% if T == UInt16 %}
    reader.read_array_array_nullable_date_codes_mark_range("payload", first_mark, mark_count)
  {% elsif T == Int32 %}
    reader.read_array_array_nullable_date32_codes_mark_range("payload", first_mark, mark_count)
  {% elsif T == UInt32 %}
    reader.read_array_array_nullable_datetime_seconds_mark_range("payload", first_mark, mark_count)
  {% elsif T == Int64 %}
    reader.read_array_array_nullable_datetime64_ticks_mark_range("payload", first_mark, mark_count)
  {% else %}
    {% raise "unsupported nested temporal carrier in characterization" %}
  {% end %}
end

private def nfw_check_temporal(type : T.class, label : String) : Nil forall T
  parent = File.tempname("crystal-click-nfw-temporal-#{label}")
  Dir.mkdir(parent)
  plain_path = File.join(parent, "plain")
  nullable_path = File.join(parent, "nullable")
  plain_rows = nfw_temporal_rows(T)
  nullable_rows = nfw_nullable_temporal_rows(T)
  begin
    nfw_write_temporal(plain_path, plain_rows)
    nfw_write_nullable_temporal(nullable_path, nullable_rows)
    plain = CrystalClick::WidePart.open_typed(plain_path, "payload")
    nullable = CrystalClick::WidePart.open_typed(nullable_path, "payload")
    plain.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
    nullable.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
    nfw_read_temporal(plain, T, 0, plain.mark_count).should eq(plain_rows)
    nfw_read_nullable_temporal(nullable, T, 0, nullable.mark_count).should eq(nullable_rows)
    nfw_read_temporal(plain, T, 1, 1).should eq(plain_rows[2, 2])
    nfw_read_nullable_temporal(nullable, T, 1, 1).should eq(nullable_rows[2, 2])
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def nfw_decimal(value : Int128) : CrystalClick::Decimal256Value
  CrystalClick::Decimal256Value.from_int128(value)
end

private def nfw_decimal_rows(type : T.class) : Array(Array(Array(T))) forall T
  rows = [] of Array(Array(T))
  {% if T == Int32 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[-17_i32, 42_i32] of T, [] of T, [7_i32] of T]
    rows << [[1_i32] of T]
    rows << [[3_i32, 4_i32] of T, [] of T]
  {% elsif T == Int64 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[-17_i64, 42_i64] of T, [] of T, [7_i64] of T]
    rows << [[1_i64] of T]
    rows << [[3_i64, 4_i64] of T, [] of T]
  {% elsif T == Int128 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[-17_i128, 42_i128] of T, [] of T, [7_i128] of T]
    rows << [[1_i128] of T]
    rows << [[3_i128, 4_i128] of T, [] of T]
  {% elsif T == CrystalClick::Decimal256Value %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[nfw_decimal(-17_i128), nfw_decimal(42_i128)] of T, [] of T, [nfw_decimal(7_i128)] of T]
    rows << [[nfw_decimal(1_i128)] of T]
    rows << [[nfw_decimal(3_i128), nfw_decimal(4_i128)] of T, [] of T]
  {% else %}
    {% raise "unsupported nested Decimal carrier in characterization" %}
  {% end %}
  rows
end

private def nfw_nullable_decimal_rows(type : T.class) : Array(Array(Array(T?))) forall T
  rows = [] of Array(Array(T?))
  {% if T == Int32 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, 7_i32, nil] of T?, [] of T?, [42_i32] of T?]
    rows << [[nil, 17_i32] of T?, [3_i32, nil] of T?]
    rows << [[-1_i32] of T?]
  {% elsif T == Int64 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, 7_i64, nil] of T?, [] of T?, [42_i64] of T?]
    rows << [[nil, 17_i64] of T?, [3_i64, nil] of T?]
    rows << [[-1_i64] of T?]
  {% elsif T == Int128 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, 7_i128, nil] of T?, [] of T?, [42_i128] of T?]
    rows << [[nil, 17_i128] of T?, [3_i128, nil] of T?]
    rows << [[-1_i128] of T?]
  {% elsif T == CrystalClick::Decimal256Value %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, nfw_decimal(7_i128), nil] of T?, [] of T?, [nfw_decimal(42_i128)] of T?]
    rows << [[nil, nfw_decimal(17_i128)] of T?, [nfw_decimal(3_i128), nil] of T?]
    rows << [[nfw_decimal(-1_i128)] of T?]
  {% else %}
    {% raise "unsupported nullable nested Decimal carrier in characterization" %}
  {% end %}
  rows
end

private def nfw_write_decimal(part : String, rows : Array(Array(Array(T)))) : Nil forall T
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
  {% if T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_decimal32_pair(part, "pk", keys.to_unsafe.to_slice(5), "payload", rows.to_unsafe.to_slice(5), 2, rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_decimal64_pair(part, "pk", keys.to_unsafe.to_slice(5), "payload", rows.to_unsafe.to_slice(5), 2, rows_per_mark: 2)
  {% elsif T == Int128 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_decimal128_pair(part, "pk", keys.to_unsafe.to_slice(5), "payload", rows.to_unsafe.to_slice(5), 2, rows_per_mark: 2)
  {% elsif T == CrystalClick::Decimal256Value %}
    CrystalClick::WidePartWriter.write_uint64_array_array_decimal256_pair(part, "pk", keys.to_unsafe.to_slice(5), "payload", rows.to_unsafe.to_slice(5), 2, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported nested Decimal carrier in characterization" %}
  {% end %}
  nil
end

private def nfw_write_nullable_decimal(part : String, rows : Array(Array(Array(T?)))) : Nil forall T
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
  {% if T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal32_pair(part, "pk", keys.to_unsafe.to_slice(5), "payload", rows.to_unsafe.to_slice(5), 2, rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal64_pair(part, "pk", keys.to_unsafe.to_slice(5), "payload", rows.to_unsafe.to_slice(5), 2, rows_per_mark: 2)
  {% elsif T == Int128 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal128_pair(part, "pk", keys.to_unsafe.to_slice(5), "payload", rows.to_unsafe.to_slice(5), 2, rows_per_mark: 2)
  {% elsif T == CrystalClick::Decimal256Value %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal256_pair(part, "pk", keys.to_unsafe.to_slice(5), "payload", rows.to_unsafe.to_slice(5), 2, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported nullable nested Decimal carrier in characterization" %}
  {% end %}
  nil
end

private def nfw_read_decimal(reader : CrystalClick::WidePart, type : T.class, first_mark : Int, mark_count : Int) : Array(Array(Array(T))) forall T
  {% if T == Int32 %}
    reader.read_array_array_decimal32_mark_range("payload", first_mark, mark_count)
  {% elsif T == Int64 %}
    reader.read_array_array_decimal64_mark_range("payload", first_mark, mark_count)
  {% elsif T == Int128 %}
    reader.read_array_array_decimal128_mark_range("payload", first_mark, mark_count)
  {% elsif T == CrystalClick::Decimal256Value %}
    reader.read_array_array_decimal256_mark_range("payload", first_mark, mark_count)
  {% else %}
    {% raise "unsupported nested Decimal carrier in characterization" %}
  {% end %}
end

private def nfw_read_nullable_decimal(reader : CrystalClick::WidePart, type : T.class, first_mark : Int, mark_count : Int) : Array(Array(Array(T?))) forall T
  {% if T == Int32 %}
    reader.read_array_array_nullable_decimal32_mark_range("payload", first_mark, mark_count)
  {% elsif T == Int64 %}
    reader.read_array_array_nullable_decimal64_mark_range("payload", first_mark, mark_count)
  {% elsif T == Int128 %}
    reader.read_array_array_nullable_decimal128_mark_range("payload", first_mark, mark_count)
  {% elsif T == CrystalClick::Decimal256Value %}
    reader.read_array_array_nullable_decimal256_mark_range("payload", first_mark, mark_count)
  {% else %}
    {% raise "unsupported nullable nested Decimal carrier in characterization" %}
  {% end %}
end

private def nfw_check_decimal(type : T.class, label : String) : Nil forall T
  parent = File.tempname("crystal-click-nfw-decimal-#{label}")
  Dir.mkdir(parent)
  plain_path = File.join(parent, "plain")
  nullable_path = File.join(parent, "nullable")
  plain_rows = nfw_decimal_rows(T)
  nullable_rows = nfw_nullable_decimal_rows(T)
  begin
    nfw_write_decimal(plain_path, plain_rows)
    nfw_write_nullable_decimal(nullable_path, nullable_rows)
    plain = CrystalClick::WidePart.open_typed(plain_path, "payload")
    nullable = CrystalClick::WidePart.open_typed(nullable_path, "payload")
    plain.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
    nullable.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
    nfw_read_decimal(plain, T, 0, plain.mark_count).should eq(plain_rows)
    nfw_read_nullable_decimal(nullable, T, 0, nullable.mark_count).should eq(nullable_rows)
    nfw_read_decimal(plain, T, 1, 1).should eq(plain_rows[2, 2])
    nfw_read_nullable_decimal(nullable, T, 1, 1).should eq(nullable_rows[2, 2])
  ensure
    FileUtils.rm_rf(parent)
  end
end

private class NfwDecoderDispatchWidePart < CrystalClick::WidePart
  @@numeric_offsets = [] of Int32
  @@decimal_offsets = [] of Int32

  def self.reset_offsets : Nil
    @@numeric_offsets.clear
    @@decimal_offsets.clear
  end

  def self.numeric_offsets : Array(Int32)
    @@numeric_offsets.dup
  end

  def self.decimal_offsets : Array(Int32)
    @@decimal_offsets.dup
  end

  def self.open_tracking_typed(path : String, column : String) : NfwDecoderDispatchWidePart
    new(path, column, :typed)
  end

  private def decode_array_numeric_value(bytes : Bytes, offset : Int, type : T.class) : T forall T
    @@numeric_offsets << offset.to_i32
    super(bytes, offset, type)
  end

  private def decode_array_decimal_value(bytes : Bytes, offset : Int, type : T.class) : T forall T
    @@decimal_offsets << offset.to_i32
    super(bytes, offset, type)
  end
end

private def nfw_read_u32(bytes : Bytes, offset : Int) : UInt32
  value = 0_u32
  4.times { |byte| value |= bytes[offset + byte].to_u32 << (byte * 8) }
  value
end

private def nfw_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def nfw_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def nfw_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def nfw_literal_frame(raw : Bytes) : Bytes
  token_and_literals = IO::Memory.new
  if raw.size < 15
    token_and_literals.write_byte((raw.size << 4).to_u8)
  else
    token_and_literals.write_byte(0xf0_u8)
    remaining = raw.size - 15
    while remaining >= 255
      token_and_literals.write_byte(255_u8)
      remaining -= 255
    end
    token_and_literals.write_byte(remaining.to_u8)
  end
  token_and_literals.write(raw)
  payload = token_and_literals.to_slice
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload.size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload.size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  nfw_write_u32(frame, header + 1, compressed_size.to_u32)
  nfw_write_u32(frame, header + 5, raw.size.to_u32)
  payload.copy_to(frame[CrystalClick::CompressedBlock::FRAME_HEADER_SIZE, payload.size])
  hash = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  nfw_write_u64(frame, 0, hash[0])
  nfw_write_u64(frame, 8, hash[1])
  frame
end

private def nfw_rewrite_mark_byte(part : String, stream : String, mark_index : Int, value : UInt8) : Nil
  stem = CrystalClick::StreamName.hash(stream)
  marks_path = File.join(part, "#{stem}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  mark_offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  compressed_offset = nfw_read_u64(marks, mark_offset).to_i
  decompressed_offset = nfw_read_u64(marks, mark_offset + 8).to_i
  data_path = File.join(part, "#{stem}.bin")
  encoded = File.read(data_path).to_slice.dup
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, compressed_offset.to_i64)
  raw = frame.output.dup
  raise "NFW selected mark byte is outside its frame" if decompressed_offset < 0 || decompressed_offset >= raw.size
  raw[decompressed_offset] = value
  replacement = nfw_literal_frame(raw)
  old_end = frame.end_offset.to_i
  delta = replacement.size - (old_end - compressed_offset)
  rewritten = Bytes.new(encoded.size + delta)
  encoded[0, compressed_offset].copy_to(rewritten.to_unsafe, compressed_offset)
  replacement.copy_to(rewritten.to_unsafe + compressed_offset, replacement.size)
  encoded[old_end, encoded.size - old_end].copy_to(rewritten.to_unsafe + compressed_offset + replacement.size, encoded.size - old_end)
  File.write(data_path, rewritten)
  (0...marks.size).step(CrystalClick::WidePart::MARK_SIZE) do |offset|
    prior = nfw_read_u64(marks, offset)
    if prior >= old_end.to_u64
      adjusted = delta >= 0 ? prior + delta.to_u64 : prior - (-delta).to_u64
      nfw_write_u64(marks, offset, adjusted)
    end
  end
  File.write(marks_path, marks)
end

private def nfw_shift_mark_decompressed_offset(part : String, stream : String, mark_index : Int, amount : UInt64 = 1_u64) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 8
  nfw_write_u64(marks, offset, nfw_read_u64(marks, offset) + amount)
  File.write(path, marks)
end

describe "nested fixed-width payload refactor characterization" do
  it "preserves public temporal reads, selected marks, empty nested rows, and fixed-width carriers" do
    nfw_check_temporal(UInt16, "date-u16")
    nfw_check_temporal(Int32, "date32-i32")
    nfw_check_temporal(UInt32, "datetime-u32")
    nfw_check_temporal(Int64, "datetime64-i64")
  end

  it "preserves public Decimal reads for all coefficient widths, nullable leaves, and empty nested rows" do
    nfw_check_decimal(Int32, "decimal32-i32")
    nfw_check_decimal(Int64, "decimal64-i64")
    nfw_check_decimal(Int128, "decimal128-i128")
    nfw_check_decimal(CrystalClick::Decimal256Value, "decimal256")
  end

  it "continues to dispatch inherited private decoders and advances past NULL slots without decoding them" do
    parent = File.tempname("crystal-click-nfw-dispatch")
    Dir.mkdir(parent)
    temporal_path = File.join(parent, "temporal")
    decimal_path = File.join(parent, "decimal")
    temporal_rows = nfw_nullable_temporal_rows(UInt16)
    decimal_rows = nfw_nullable_decimal_rows(Int32)
    begin
      nfw_write_nullable_temporal(temporal_path, temporal_rows)
      nfw_write_nullable_decimal(decimal_path, decimal_rows)
      temporal = NfwDecoderDispatchWidePart.open_tracking_typed(temporal_path, "payload")
      decimal = NfwDecoderDispatchWidePart.open_tracking_typed(decimal_path, "payload")

      nfw_write_temporal(temporal_path + "-plain", nfw_temporal_rows(UInt16))
      nfw_write_decimal(decimal_path + "-plain", nfw_decimal_rows(Int32))
      temporal_plain = NfwDecoderDispatchWidePart.open_tracking_typed(temporal_path + "-plain", "payload")
      decimal_plain = NfwDecoderDispatchWidePart.open_tracking_typed(decimal_path + "-plain", "payload")

      NfwDecoderDispatchWidePart.reset_offsets
      temporal_plain.read_array_array_date_codes_mark_range("payload", 1, 1).should eq([
        [[0_u16, UInt16::MAX], [] of UInt16, [7_u16]],
        [[1_u16]],
      ])
      NfwDecoderDispatchWidePart.numeric_offsets.should eq([0_i32, 2_i32, 4_i32, 6_i32])

      NfwDecoderDispatchWidePart.reset_offsets
      decimal_plain.read_array_array_decimal32_mark_range("payload", 1, 1).should eq([
        [[-17_i32, 42_i32], [] of Int32, [7_i32]],
        [[1_i32]],
      ])
      NfwDecoderDispatchWidePart.decimal_offsets.should eq([0_i32, 4_i32, 8_i32, 12_i32])

      NfwDecoderDispatchWidePart.reset_offsets
      temporal.read_array_array_nullable_date_codes_mark_range("payload", 1, 1).should eq(temporal_rows[2, 2])
      NfwDecoderDispatchWidePart.numeric_offsets.should eq([2_i32, 6_i32, 10_i32, 12_i32])

      NfwDecoderDispatchWidePart.reset_offsets
      decimal.read_array_array_nullable_decimal32_mark_range("payload", 1, 1).should eq(decimal_rows[2, 2])
      NfwDecoderDispatchWidePart.decimal_offsets.should eq([4_i32, 12_i32, 20_i32, 24_i32])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves public type/column refusals, zero and unknown range errors, and nullable preflight checks" do
    parent = File.tempname("crystal-click-nfw-errors")
    Dir.mkdir(parent)
    plain_path = File.join(parent, "plain")
    nullable_path = File.join(parent, "nullable")
    bad_null_path = File.join(parent, "bad-null")
    aligned_mark_path = File.join(parent, "aligned-mark")
    bad_mark_path = File.join(parent, "bad-mark")
    plain_rows = nfw_temporal_rows(UInt16)
    nullable_rows = nfw_nullable_temporal_rows(UInt16)
    begin
      nfw_write_temporal(plain_path, plain_rows)
      nfw_write_nullable_temporal(nullable_path, nullable_rows)
      plain = CrystalClick::WidePart.open_typed(plain_path, "payload")
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        plain.read_array_array_date32_codes_mark_range("payload", 0, 1)
      end
      error.message.not_nil!.should eq("typed nested temporal Array accessor does not match selected semantic column type")
      missing = expect_raises(CrystalClick::UnsupportedFormatError) do
        plain.read_array_array_date_codes_mark_range("other", 0, 1)
      end
      missing.message.not_nil!.should eq("column is not present")
      empty = expect_raises(CrystalClick::BoundsError) do
        plain.read_array_array_date_codes_mark_range("payload", 1, 0)
      end
      empty.message.not_nil!.should eq("empty mark range")
      unknown = expect_raises(CrystalClick::BoundsError) do
        plain.read_array_array_date_codes_mark_range("payload", plain.mark_count, 1)
      end
      unknown.message.not_nil!.should eq("mark range exceeds data marks")

      FileUtils.cp_r(nullable_path, bad_null_path)
      nfw_rewrite_mark_byte(bad_null_path, "payload.null", 1, 2_u8)
      # Add a width-aligned value-mark error as well. Null-map validation
      # should still win before value-stream preflight or decoder callbacks.
      nfw_shift_mark_decompressed_offset(bad_null_path, "payload", 1, 2_u64)
      malformed_null = NfwDecoderDispatchWidePart.open_tracking_typed(bad_null_path, "payload")
      NfwDecoderDispatchWidePart.reset_offsets
      boolean = expect_raises(CrystalClick::CorruptPartError) do
        malformed_null.read_array_array_nullable_date_codes_mark_range("payload", 1, 1)
      end
      boolean.message.not_nil!.should eq("Array(Array(Nullable(temporal))) null-map byte is not boolean")
      NfwDecoderDispatchWidePart.numeric_offsets.should eq([] of Int32)
      NfwDecoderDispatchWidePart.decimal_offsets.should eq([] of Int32)

      # Control: the aligned value-mark fault alone passes opening but is
      # rejected during selected-range preflight, before either decoder runs.
      FileUtils.cp_r(nullable_path, aligned_mark_path)
      nfw_shift_mark_decompressed_offset(aligned_mark_path, "payload", 1, 2_u64)
      aligned_mark_reader = NfwDecoderDispatchWidePart.open_tracking_typed(aligned_mark_path, "payload")
      NfwDecoderDispatchWidePart.reset_offsets
      expect_raises(CrystalClick::CorruptPartError) do
        aligned_mark_reader.read_array_array_nullable_date_codes_mark_range("payload", 1, 1)
      end
      NfwDecoderDispatchWidePart.numeric_offsets.should eq([] of Int32)
      NfwDecoderDispatchWidePart.decimal_offsets.should eq([] of Int32)

      FileUtils.cp_r(nullable_path, bad_mark_path)
      nfw_shift_mark_decompressed_offset(bad_mark_path, "payload", 1)
      # Date's fixed-width mark alignment is rejected while opening this
      # malformed part, before a selected-range read can begin.
      malformed_mark = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(bad_mark_path, "payload")
      end
      malformed_mark.message.not_nil!.should eq("mark decompressed offset is not column-type-aligned")

      # A well-formed decimal part with a different coefficient band must fail
      # at the public facade before entering the shared reconstruction loop.
      decimal64_path = File.join(parent, "decimal64")
      nfw_write_decimal(decimal64_path, nfw_decimal_rows(Int64))
      decimal64 = CrystalClick::WidePart.open_typed(decimal64_path, "payload")
      wrong_decimal = expect_raises(CrystalClick::UnsupportedFormatError) do
        decimal64.read_array_array_decimal32_mark_range("payload", 0, 1)
      end
      wrong_decimal.message.not_nil!.should eq("Decimal32 nested Array accessor requires Array(Array(Decimal(P, S))) with P in 1..9")
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
