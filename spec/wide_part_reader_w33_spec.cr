require "./spec_helper"

W33_FIXED_STRING_FIXTURE       = File.expand_path("../test/fixtures/public/wide_array_fixed_string/part", __DIR__)
W33_FIXED_STRING_KEYED_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_fixed_string_keyed/part", __DIR__)
W33_FIXED_STRING_KEYS          = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64, 17_u64, 19_u64, 21_u64, 25_u64, 31_u64, 40_u64]

private def w33_fixed(a : UInt8, b : UInt8 = 0_u8, c : UInt8 = 0_u8, d : UInt8 = 0_u8) : String
  String.new(Bytes[a, b, c, d])
end

private def w33_plain_values : Array(Array(String))
  [
    [] of String,
    [w33_fixed(0_u8), w33_fixed(0x61_u8, 0_u8, 0x62_u8, 0xff_u8)],
    [w33_fixed(0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8), w33_fixed(0x78_u8, 0xff_u8, 0_u8, 0xff_u8)],
    [] of String,
    [w33_fixed(0xc3_u8, 0xa9_u8)],
    [w33_fixed(0_u8)],
    [] of String,
    [w33_fixed(0x61_u8), w33_fixed(0x62_u8), w33_fixed(0x63_u8)],
    [] of String,
    [w33_fixed(0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8)],
    [w33_fixed(0xc3_u8, 0xa9_u8)],
    [] of String,
    [w33_fixed(0_u8)],
  ] of Array(String)
end

private def w33_nullable_values : Array(Array(String?))
  [
    [] of String?,
    [nil, w33_fixed(0_u8), w33_fixed(0x71_u8, 0xff_u8)],
    [nil] of String?,
    [w33_fixed(0_u8), nil] of String?,
    [] of String?,
    [w33_fixed(0xff_u8)] of String?,
    [nil, w33_fixed(0_u8)] of String?,
    [w33_fixed(0_u8)] of String?,
    [w33_fixed(0_u8), nil, w33_fixed(0x61_u8, 0_u8, 0x62_u8, 0xff_u8)] of String?,
    [] of String?,
    [nil] of String?,
    [] of String?,
    [nil, w33_fixed(0xff_u8)] of String?,
  ] of Array(String?)
end

private def w33_decode_stream(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w33_size_stream(values : Array(Array(T))) : Array(UInt8) forall T
  bytes = [] of UInt8
  values.each do |row|
    value = row.size.to_u64
    8.times { |index| bytes << ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w33_fixed_payload(values : Array(Array(String))) : Array(UInt8)
  values.flat_map { |row| row.flat_map { |value| value.to_slice.to_a } }
end

private def w33_nullable_payload(values : Array(Array(String?))) : Array(UInt8)
  zero = w33_fixed(0_u8)
  values.flat_map do |row|
    row.flat_map { |value| (value || zero).to_slice.to_a }
  end
end

private def w33_null_map(values : Array(Array(String?))) : Array(UInt8)
  values.flat_map { |row| row.map { |value| value.nil? ? 1_u8 : 0_u8 } }
end

private def w33_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w33_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w33_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w33_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |byte| io.write_byte(((hash[0] >> (byte * 8)) & 0xff_u64).to_u8) }
  8.times { |byte| io.write_byte(((hash[1] >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w33_encode_lz4_frame(raw : Bytes) : Bytes
  raise "W33 test cannot encode an empty LZ4 block" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w33_write_u32(frame, header + 1, compressed_size.to_u32)
  w33_write_u32(frame, header + 5, raw.size.to_u32)
  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  if raw.size < 15
    frame[cursor] = (raw.size << 4).to_u8
    cursor += 1
  else
    frame[cursor] = 0xf0_u8
    cursor += 1
    remaining = raw.size - 15
    while remaining >= 255
      frame[cursor] = 255_u8
      cursor += 1
      remaining -= 255
    end
    frame[cursor] = remaining.to_u8
    cursor += 1
  end
  raw.copy_to(frame[cursor, raw.size])
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  w33_write_u64(frame, 0, checksum[0])
  w33_write_u64(frame, 8, checksum[1])
  frame
end

private def w33_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w33_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w33_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w33_write_varuint(payload, file_bytes.size.to_u64)
    w33_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w33_write_varuint(payload, raw.size.to_u64)
      w33_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  frame = w33_encode_lz4_frame(payload.to_slice)
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(frame)
  end
end

private def w33_copy_fixture(parent : String, name : String) : String
  part = File.join(parent, name)
  FileUtils.cp_r(W33_FIXED_STRING_FIXTURE, part)
  part
end

private def w33_replace_raw_stream(part : String, stream : String, raw : Bytes) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  File.write(path, w33_encode_lz4_frame(raw))
end

private def w33_write_mark_offset(part : String, stream : String, record : Int, value : UInt64) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(path).to_slice.dup
  w33_write_u64(marks, record * CrystalClick::WidePart::MARK_SIZE + 8, value)
  File.write(path, marks)
  w33_refresh_checksums(part)
end

private def w33_catalog_root(&)
  root = File.tempname("crystal-click-w33-catalog")
  Dir.mkdir(root)
  database_uuid = "ba07c5bd-b042-4b09-8aab-0f1abc1153c4"
  table_uuid = "f446fcb2-a303-4c5b-817f-515156c093d2"
  database_store = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_store = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(database_store)
  FileUtils.mkdir_p(table_store)
  tick = 96.chr
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_store, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    #{tick}pk#{tick} UInt64,\n    #{tick}plain#{tick} Array(FixedString(4)),\n    #{tick}maybe#{tick} Array(Nullable(FixedString(4)))\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table_store, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_store, "detached"))
  FileUtils.cp_r(W33_FIXED_STRING_FIXTURE, File.join(table_store, "all_1_1_0"))
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::WidePart do
  it "admits the exact fixed-width String array type spellings" do
    CrystalClick::WidePart.supports_typed_type?("Array(FixedString(4))").should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(Nullable(FixedString(4)))").should be_true
    CrystalClick::WidePart.array_fixed_string_width("Array(FixedString(4))").should eq(4)
    CrystalClick::WidePart.array_nullable_fixed_string_width("Array(Nullable(FixedString(4)))").should eq(4)

    [
      "Array(FixedString(0))",
      "Array(FixedString(04))",
      "Array(Nullable(FixedString(0)))",
      "Array( Nullable(FixedString(4)))",
      "Array(Nullable(FixedString(4))) trailing",
      "Nullable(Array(FixedString(4)))",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads stock Array(FixedString(4)) by outer-row marks without changing binary bytes" do
    expected = w33_plain_values
    reader = CrystalClick::WidePart.open_typed(W33_FIXED_STRING_FIXTURE, "plain")
    reader.column_type.should eq("Array(FixedString(4))")
    reader.row_count.should eq(13_u64)
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
    reader.read_array_fixed_string_mark_range("plain", 0, reader.mark_count).should eq(expected)
    reader.read_array_fixed_string_mark_range("plain", 4, 2).should eq(expected[8, 4])
    reader.read_array_fixed_string_mark_range("plain", 6, 1).should eq(expected[12, 1])
    w33_decode_stream(W33_FIXED_STRING_FIXTURE, "plain.size0").should eq(w33_size_stream(expected))
    w33_decode_stream(W33_FIXED_STRING_FIXTURE, "plain").should eq(w33_fixed_payload(expected))
  end

  it "reads stock Array(Nullable(FixedString(4))) with NULL distinct from zero-filled values" do
    expected = w33_nullable_values
    reader = CrystalClick::WidePart.open_typed(W33_FIXED_STRING_FIXTURE, "maybe")
    reader.column_type.should eq("Array(Nullable(FixedString(4)))")
    reader.row_count.should eq(13_u64)
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
    reader.read_array_nullable_fixed_string_mark_range("maybe", 0, reader.mark_count).should eq(expected)
    reader.read_array_nullable_fixed_string_mark_range("maybe", 2, 2).should eq(expected[4, 4])
    reader.read_array_nullable_fixed_string_mark_range("maybe", 6, 1).should eq(expected[12, 1])
    w33_decode_stream(W33_FIXED_STRING_FIXTURE, "maybe.size0").should eq(w33_size_stream(expected))
    w33_decode_stream(W33_FIXED_STRING_FIXTURE, "maybe.null").should eq(w33_null_map(expected))
    w33_decode_stream(W33_FIXED_STRING_FIXTURE, "maybe").should eq(w33_nullable_payload(expected))
  end

  it "accepts the stock keyed serializer variant only for the exact paired schema" do
    keyed_json = %({"columns":[{"kind":"Default","name":"pk","num_defaults":0,"num_rows":13}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
    File.read(File.join(W33_FIXED_STRING_KEYED_FIXTURE, "serialization.json")).should eq(keyed_json)
    CrystalClick::WidePart.open_typed(W33_FIXED_STRING_KEYED_FIXTURE, "plain")
      .read_array_fixed_string_mark_range("plain", 0, 7).should eq(w33_plain_values)
    CrystalClick::WidePart.open_typed(W33_FIXED_STRING_KEYED_FIXTURE, "maybe")
      .read_array_nullable_fixed_string_mark_range("maybe", 0, 7).should eq(w33_nullable_values)

    parent = File.tempname("crystal-click-w33-invalid-key-serializer")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      FileUtils.cp_r(W33_FIXED_STRING_KEYED_FIXTURE, part)
      File.write(File.join(part, "serialization.json"), keyed_json.gsub(%("name":"pk"), %("name":"not_pk")))
      w33_refresh_checksums(part)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part, "plain")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a checksum-preserving invalid nullable flag before exposing a table callback" do
    parent = File.tempname("crystal-click-w33-invalid-null-flag")
    Dir.mkdir(parent)
    begin
      part = w33_copy_fixture(parent, "all_1_1_0")
      raw_path = File.join(part, "#{CrystalClick::StreamName.hash("maybe.null")}.bin")
      raw_before = CrystalClick::CompressedBlock.decode_all(File.read(raw_path).to_slice)
      raw_before.size.should eq(16)
      raw_before[0].should eq(1_u8)
      raw_before[0] = 2_u8
      w33_replace_raw_stream(part, "maybe.null", raw_before)
      w33_refresh_checksums(part)
      CrystalClick::CompressedBlock.decode_all(File.read(raw_path).to_slice).size.should eq(raw_before.size)

      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(part, "maybe")
          .read_array_nullable_fixed_string_mark_range("maybe", 0, 1)
      end
      (error.message || "").should contain("null-map")

      callbacks = 0
      table_error = expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "maybe"])
        table.scan_typed_candidate_marks([[0]]) { |_batch| callbacks += 1 }
      end
      (table_error.message || "").should contain("null-map")
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects checksum-preserving shifted child marks with unchanged aggregate stream totals" do
    parent = File.tempname("crystal-click-w33-shifted-child-mark")
    Dir.mkdir(parent)
    begin
      part = w33_copy_fixture(parent, "all_1_1_0")
      mark_path = File.join(part, "#{CrystalClick::StreamName.hash("maybe.null")}.mrk2")
      marks_before = File.read(mark_path).to_slice.dup
      shifted_record = 2
      original_nulls = w33_decode_stream(part, "maybe.null")
      original_nulls.size.should eq(16)
      original_marks_size = File.size(mark_path)

      # The third child mark begins at byte 6. Shift it to byte 7 while leaving
      # every stream aggregate unchanged and updating the part checksums.
      w33_write_mark_offset(part, "maybe.null", shifted_record, 7_u64)
      File.size(mark_path).should eq(original_marks_size)
      w33_decode_stream(part, "maybe.null").should eq(original_nulls)
      shifted_marks = File.read(mark_path).to_slice
      shifted_marks.size.should eq(marks_before.size)
      offset_at_record = 0_u64
      8.times do |byte|
        offset_at_record |= shifted_marks[shifted_record * CrystalClick::WidePart::MARK_SIZE + 8 + byte].to_u64 << (byte * 8)
      end
      offset_at_record.should eq(7_u64)

      callbacks = 0
      error = expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "maybe"])
        table.scan_typed_candidate_marks([[2]]) { |_batch| callbacks += 1 }
      end
      (error.message || "").should contain("mark")
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "ignores nonzero nested bytes hidden beneath a valid nullable NULL flag" do
    parent = File.tempname("crystal-click-w33-hidden-null-payload")
    Dir.mkdir(parent)
    begin
      part = w33_copy_fixture(parent, "all_1_1_0")
      raw_path = File.join(part, "#{CrystalClick::StreamName.hash("maybe")}.bin")
      raw = CrystalClick::CompressedBlock.decode_all(File.read(raw_path).to_slice).dup
      raw[0] = 0x91_u8
      raw[1] = 0x82_u8
      raw[2] = 0x73_u8
      raw[3] = 0x64_u8
      w33_replace_raw_stream(part, "maybe", raw)
      w33_refresh_checksums(part)

      reader = CrystalClick::WidePart.open_typed(part, "maybe")
      reader.read_array_nullable_fixed_string_mark_range("maybe", 0, 1).should eq(w33_nullable_values[0, 2])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "exposes both arrays through typed full and key-window batches and caller-owned catalog values" do
    expected_plain = w33_plain_values
    expected_nullable = w33_nullable_values
    expected_rows = W33_FIXED_STRING_KEYS.each_with_index.map do |key, index|
      {key, expected_plain[index], expected_nullable[index]}
    end.to_a

    table_root = File.tempname("crystal-click-w33-table")
    Dir.mkdir(table_root)
    part = File.join(table_root, "all_1_1_0")
    begin
      FileUtils.cp_r(W33_FIXED_STRING_FIXTURE, part)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "plain", "maybe"])

      observed = [] of {UInt64, Array(String), Array(String?)}
      table.scan_typed(batch_rows: 3) do |batch|
        keys = batch.values_for("pk", UInt64)
        plain = batch.array_fixed_strings_for("plain")
        nullable = batch.array_nullable_fixed_strings_for("maybe")
        keys.each_index { |index| observed << {keys[index], plain[index].dup, nullable[index].dup} }
      end
      observed.should eq(expected_rows)

      window_rows = [] of {UInt64, Array(String), Array(String?)}
      table.scan_typed_window(2_u64, max_rows: 7) do |batch|
        keys = batch.values_for("pk", UInt64)
        plain = batch.array_fixed_strings_for("plain")
        nullable = batch.array_nullable_fixed_strings_for("maybe")
        keys.each_index { |index| window_rows << {keys[index], plain[index].dup, nullable[index].dup} }
      end
      window_rows.should eq(expected_rows[2, 7])
    ensure
      FileUtils.rm_rf(table_root)
    end

    w33_catalog_root do |root|
      catalog_table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      plain_column = catalog_table["plain"]
      nullable_column = catalog_table["maybe"]
      plain_values = plain_column.values.map { |value| value.as(Array(String)) }
      nullable_values = nullable_column.values.map { |value| value.as(Array(String?)) }
      plain_values.should eq(expected_plain)
      nullable_values.should eq(expected_nullable)

      plain_values[1][0] = w33_fixed(0x7a_u8)
      nullable_values[1][0] = w33_fixed(0x79_u8)
      plain_column.values.map { |value| value.as(Array(String)) }.should eq(expected_plain)
      nullable_column.values.map { |value| value.as(Array(String?)) }.should eq(expected_nullable)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes Array(FixedString(4)) with the requested row marks and exact binary payload" do
    parent = File.tempname("crystal-click-w33-fixed-string-writer")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = W33_FIXED_STRING_KEYS
    values = w33_plain_values
    begin
      CrystalClick::WidePartWriter.write_uint64_array_fixed_string_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        width: 4,
        rows_per_mark: 2
      )

      reader = CrystalClick::WidePart.open_typed(destination, "payload")
      reader.column_type.should eq("Array(FixedString(4))")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
      reader.read_array_fixed_string_mark_range("payload", 0, reader.mark_count).should eq(values)
      w33_decode_stream(destination, "payload.size0").should eq(w33_size_stream(values))
      w33_decode_stream(destination, "payload").should eq(w33_fixed_payload(values))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes Array(Nullable(FixedString(4))) preserving NULL and nested fixed bytes" do
    parent = File.tempname("crystal-click-w33-nullable-fixed-string-writer")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = W33_FIXED_STRING_KEYS
    values = w33_nullable_values
    begin
      CrystalClick::WidePartWriter.write_uint64_array_nullable_fixed_string_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        width: 4,
        rows_per_mark: 2
      )

      reader = CrystalClick::WidePart.open_typed(destination, "payload")
      reader.column_type.should eq("Array(Nullable(FixedString(4)))")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
      reader.read_array_nullable_fixed_string_mark_range("payload", 0, reader.mark_count).should eq(values)
      w33_decode_stream(destination, "payload.size0").should eq(w33_size_stream(values))
      w33_decode_stream(destination, "payload.null").should eq(w33_null_map(values))
      w33_decode_stream(destination, "payload").should eq(w33_nullable_payload(values))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects over-width FixedString values without publishing or leaving staging artifacts" do
    parent = File.tempname("crystal-click-w33-rejected-fixed-string-writer")
    Dir.mkdir(parent)
    parent_before = Dir.children(parent).sort
    keys = [1_u64]
    too_wide = String.new(Bytes[0x61_u8, 0x62_u8, 0x63_u8, 0x64_u8, 0x65_u8])
    plain_values = [[too_wide]] of Array(String)
    nullable_values = [[too_wide.as(String?)]] of Array(String?)
    plain_destination = File.join(parent, "plain")
    nullable_destination = File.join(parent, "nullable")
    begin
      plain_error = expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_fixed_string_pair(
          plain_destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          plain_values.to_unsafe.to_slice(plain_values.size),
          width: 4
        )
      end
      (plain_error.message || "").should contain("FixedString value exceeds declared byte width")
      File.exists?(plain_destination).should be_false
      Dir.children(parent).sort.should eq(parent_before)

      nullable_error = expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_nullable_fixed_string_pair(
          nullable_destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          nullable_values.to_unsafe.to_slice(nullable_values.size),
          width: 4
        )
      end
      (nullable_error.message || "").should contain("FixedString value exceeds declared byte width")
      File.exists?(nullable_destination).should be_false
      Dir.children(parent).sort.should eq(parent_before)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "allows 4097 all-empty wide fixed-string rows in one mark with empty child streams" do
    parent = File.tempname("crystal-click-w33-empty-fixed-string-writers")
    Dir.mkdir(parent)
    row_count = 4097
    width = 16_384
    keys = Array(UInt64).new(row_count) { |index| (index + 100).to_u64 }
    plain_values = Array(Array(String)).new(row_count) { [] of String }
    nullable_values = Array(Array(String?)).new(row_count) { [] of String? }
    plain_part = File.join(parent, "plain")
    nullable_part = File.join(parent, "nullable")
    begin
      CrystalClick::WidePartWriter.write_uint64_array_fixed_string_pair(
        plain_part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        plain_values.to_unsafe.to_slice(plain_values.size),
        width: width,
        rows_per_mark: row_count
      )

      plain_reader = CrystalClick::WidePart.open_typed(plain_part, "payload")
      plain_reader.read_array_fixed_string_mark_range("payload", 0, plain_reader.mark_count).should eq(plain_values)
      plain_reader.mark_row_counts.should eq([row_count.to_u64])
      w33_decode_stream(plain_part, "payload.size0").should eq(w33_size_stream(plain_values))
      File.size(File.join(plain_part, "#{CrystalClick::StreamName.hash("payload")}.bin")).should eq(0)

      CrystalClick::WidePartWriter.write_uint64_array_nullable_fixed_string_pair(
        nullable_part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        nullable_values.to_unsafe.to_slice(nullable_values.size),
        width: width,
        rows_per_mark: row_count
      )

      nullable_reader = CrystalClick::WidePart.open_typed(nullable_part, "payload")
      nullable_reader.read_array_nullable_fixed_string_mark_range("payload", 0, nullable_reader.mark_count).should eq(nullable_values)
      nullable_reader.mark_row_counts.should eq([row_count.to_u64])
      w33_decode_stream(nullable_part, "payload.size0").should eq(w33_size_stream(nullable_values))
      File.size(File.join(nullable_part, "#{CrystalClick::StreamName.hash("payload.null")}.bin")).should eq(0)
      File.size(File.join(nullable_part, "#{CrystalClick::StreamName.hash("payload")}.bin")).should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
