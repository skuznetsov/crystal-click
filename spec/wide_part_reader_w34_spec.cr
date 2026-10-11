require "./spec_helper"

W34_BOOL_FIXTURE       = File.expand_path("../test/fixtures/public/wide_array_bool/part", __DIR__)
W34_BOOL_KEYED_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_bool_keyed/part", __DIR__)
W34_BOOL_KEYS          = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64, 17_u64, 19_u64, 21_u64, 25_u64, 31_u64, 40_u64]

private def w34_bool_values : Array(Array(Bool))
  [
    [] of Bool,
    [false, true],
    [true],
    [] of Bool,
    [false],
    [true, false],
    [] of Bool,
    [true],
    [false, true],
    [] of Bool,
    [false],
    [true],
    [false, false],
  ] of Array(Bool)
end

private def w34_nullable_bool_values : Array(Array(Bool?))
  [
    [] of Bool?,
    [nil, false, true] of Bool?,
    [false, nil] of Bool?,
    [true] of Bool?,
    [] of Bool?,
    [nil, true] of Bool?,
    [false] of Bool?,
    [nil, false] of Bool?,
    [] of Bool?,
    [false, nil] of Bool?,
    [true] of Bool?,
    [nil] of Bool?,
    [true, nil] of Bool?,
  ] of Array(Bool?)
end

private def w34_decode_stream(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w34_size_stream(values : Array(Array(T))) : Array(UInt8) forall T
  bytes = [] of UInt8
  values.each do |row|
    value = row.size.to_u64
    8.times { |index| bytes << ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w34_bool_payload(values : Array(Array(Bool))) : Array(UInt8)
  bytes = [] of UInt8
  values.each { |row| row.each { |value| bytes << (value ? 1_u8 : 0_u8) } }
  bytes
end

private def w34_nullable_bool_payload(values : Array(Array(Bool?))) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |row|
    row.each { |value| bytes << (value ? (value ? 1_u8 : 0_u8) : 0_u8) }
  end
  bytes
end

private def w34_null_map(values : Array(Array(Bool?))) : Array(UInt8)
  bytes = [] of UInt8
  values.each { |row| row.each { |value| bytes << (value.nil? ? 1_u8 : 0_u8) } }
  bytes
end

private def w34_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w34_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w34_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w34_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w34_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |byte| io.write_byte(((hash[0] >> (byte * 8)) & 0xff_u64).to_u8) }
  8.times { |byte| io.write_byte(((hash[1] >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w34_encode_lz4_frame(raw : Bytes) : Bytes
  raise "W34 test cannot encode an empty LZ4 block" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w34_write_u32(frame, header + 1, compressed_size.to_u32)
  w34_write_u32(frame, header + 5, raw.size.to_u32)
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
  w34_write_u64(frame, 0, checksum[0])
  w34_write_u64(frame, 8, checksum[1])
  frame
end

private def w34_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w34_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w34_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w34_write_varuint(payload, file_bytes.size.to_u64)
    w34_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w34_write_varuint(payload, raw.size.to_u64)
      w34_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  frame = w34_encode_lz4_frame(payload.to_slice)
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(frame)
  end
end

private def w34_copy_fixture(parent : String, name : String) : String
  part = File.join(parent, name)
  FileUtils.cp_r(W34_BOOL_FIXTURE, part)
  part
end

private def w34_replace_raw_stream(part : String, stream : String, raw : Bytes) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  File.write(path, w34_encode_lz4_frame(raw))
end

private def w34_write_mark_offset(part : String, stream : String, record : Int, value : UInt64) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(path).to_slice.dup
  w34_write_u64(marks, record * CrystalClick::WidePart::MARK_SIZE + 8, value)
  File.write(path, marks)
  w34_refresh_checksums(part)
end

private def w34_catalog_root(&)
  root = File.tempname("crystal-click-w34-catalog")
  Dir.mkdir(root)
  database_uuid = "bc68cb85-75dd-4788-a811-ea395ad9bcde"
  table_uuid = "ebcf3c0a-bf7c-458a-a061-2a5db65e307a"
  database_store = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_store = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(database_store)
  FileUtils.mkdir_p(table_store)
  tick = 96.chr
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_store, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    #{tick}pk#{tick} UInt64,\n    #{tick}plain#{tick} Array(Bool),\n    #{tick}maybe#{tick} Array(Nullable(Bool))\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table_store, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_store, "detached"))
  FileUtils.cp_r(W34_BOOL_FIXTURE, File.join(table_store, "all_1_1_0"))
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::WidePart do
  it "admits only the canonical Bool array leaf types" do
    CrystalClick::WidePart.supports_typed_type?("Array(Bool)").should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(Nullable(Bool))").should be_true
    CrystalClick::WidePart.supports_array_bool_type?("Array(Bool)").should be_true
    CrystalClick::WidePart.supports_array_nullable_bool_type?("Array(Nullable(Bool))").should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(UInt8)").should be_true
    CrystalClick::WidePart.supports_array_bool_type?("Array(UInt8)").should be_false

    [
      "Array(Nullable(Nullable(Bool)))",
      "Array(Array(Bool))",
      "Array( Bool)",
      "Array(Nullable(Bool)) trailing",
      "Nullable(Array(Bool))",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads stock Array(Bool) by outer-row marks and preserves boolean payload bytes" do
    expected = w34_bool_values
    reader = CrystalClick::WidePart.open_typed(W34_BOOL_FIXTURE, "plain")
    reader.column_type.should eq("Array(Bool)")
    reader.row_count.should eq(13_u64)
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
    reader.read_array_bool_mark_range("plain", 0, reader.mark_count).should eq(expected)
    reader.read_array_bool_mark_range("plain", 1, 4).should eq(expected[2, 8])
    reader.read_array_bool_mark_range("plain", 6, 1).should eq(expected[12, 1])
    w34_decode_stream(W34_BOOL_FIXTURE, "plain.size0").should eq(w34_size_stream(expected))
    w34_decode_stream(W34_BOOL_FIXTURE, "plain").should eq(w34_bool_payload(expected))
    reader.array_bool_mark_range_raw_bytes("plain", 1, 2).should eq(4_u64)
  end

  it "reads stock Array(Nullable(Bool)) across later marks with NULL distinct from false" do
    expected = w34_nullable_bool_values
    reader = CrystalClick::WidePart.open_typed(W34_BOOL_FIXTURE, "maybe")
    reader.column_type.should eq("Array(Nullable(Bool))")
    reader.row_count.should eq(13_u64)
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
    reader.read_array_nullable_bool_mark_range("maybe", 0, reader.mark_count).should eq(expected)
    reader.read_array_nullable_bool_mark_range("maybe", 2, 2).should eq(expected[4, 4])
    reader.read_array_nullable_bool_mark_range("maybe", 6, 1).should eq(expected[12, 1])
    w34_decode_stream(W34_BOOL_FIXTURE, "maybe.size0").should eq(w34_size_stream(expected))
    w34_decode_stream(W34_BOOL_FIXTURE, "maybe.null").should eq(w34_null_map(expected))
    w34_decode_stream(W34_BOOL_FIXTURE, "maybe").should eq(w34_nullable_bool_payload(expected))
    reader.array_nullable_bool_mark_range_raw_bytes("maybe", 1, 2).should eq(10_u64)
  end

  it "admits the keyed stock serializer variant for Boolean arrays" do
    keyed_json = %({"columns":[{"kind":"Default","name":"pk","num_defaults":0,"num_rows":13}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
    File.read(File.join(W34_BOOL_KEYED_FIXTURE, "serialization.json")).should eq(keyed_json)
    CrystalClick::WidePart.open_typed(W34_BOOL_KEYED_FIXTURE, "plain")
      .read_array_bool_mark_range("plain", 0, 7).should eq(w34_bool_values)
    CrystalClick::WidePart.open_typed(W34_BOOL_KEYED_FIXTURE, "maybe")
      .read_array_nullable_bool_mark_range("maybe", 0, 7).should eq(w34_nullable_bool_values)

    parent = File.tempname("crystal-click-w34-invalid-key-serializer")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      FileUtils.cp_r(W34_BOOL_KEYED_FIXTURE, part)
      File.write(File.join(part, "serialization.json"), keyed_json.gsub(%("name":"pk"), %("name":"not_pk")))
      w34_refresh_checksums(part)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(part, "plain")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "decodes visible plain and non-NULL nullable Boolean child bytes 2 and 255 as true" do
    [2_u8, 255_u8].each do |noncanonical_byte|
      parent = File.tempname("crystal-click-w34-invalid-bool-byte")
      Dir.mkdir(parent)
      begin
        part = w34_copy_fixture(parent, "all_1_1_0")
        raw_path = File.join(part, "#{CrystalClick::StreamName.hash("plain")}.bin")
        raw = CrystalClick::CompressedBlock.decode_all(File.read(raw_path).to_slice).dup
        raw[0].should eq(0_u8)
        raw[0] = noncanonical_byte
        w34_replace_raw_stream(part, "plain", raw)
        w34_refresh_checksums(part)
        CrystalClick::CompressedBlock.decode_all(File.read(raw_path).to_slice).size.should eq(raw.size)

        plain_expected = w34_bool_values[0, 2].map(&.dup)
        plain_expected[1][0] = true
        w34_decode_stream(part, "plain")[0].should eq(noncanonical_byte)
        CrystalClick::WidePart.open_typed(part, "plain")
          .read_array_bool_mark_range("plain", 0, 1).should eq(plain_expected)

        nullable_part = w34_copy_fixture(parent, "nullable_#{noncanonical_byte}")
        nullable_raw_path = File.join(nullable_part, "#{CrystalClick::StreamName.hash("maybe")}.bin")
        nullable_raw = CrystalClick::CompressedBlock.decode_all(File.read(nullable_raw_path).to_slice).dup
        nullable_raw[1].should eq(0_u8) # first non-NULL leaf follows the leading NULL slot
        nullable_raw[1] = noncanonical_byte
        w34_replace_raw_stream(nullable_part, "maybe", nullable_raw)
        w34_refresh_checksums(nullable_part)
        nullable_expected = w34_nullable_bool_values[0, 2].map(&.dup)
        nullable_expected[1][1] = true
        w34_decode_stream(nullable_part, "maybe")[1].should eq(noncanonical_byte)
        CrystalClick::WidePart.open_typed(nullable_part, "maybe")
          .read_array_nullable_bool_mark_range("maybe", 0, 1).should eq(nullable_expected)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "rejects invalid nullable flags before exposing a table callback" do
    parent = File.tempname("crystal-click-w34-invalid-null-flag")
    Dir.mkdir(parent)
    begin
      part = w34_copy_fixture(parent, "all_1_1_0")
      raw_path = File.join(part, "#{CrystalClick::StreamName.hash("maybe.null")}.bin")
      raw = CrystalClick::CompressedBlock.decode_all(File.read(raw_path).to_slice).dup
      raw.size.should eq(17)
      raw[0].should eq(1_u8)
      raw[0] = 2_u8
      w34_replace_raw_stream(part, "maybe.null", raw)
      w34_refresh_checksums(part)

      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(part, "maybe")
          .read_array_nullable_bool_mark_range("maybe", 0, 1)
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

  it "rejects shifted nullable child marks even when aggregate stream totals are unchanged" do
    parent = File.tempname("crystal-click-w34-shifted-child-mark")
    Dir.mkdir(parent)
    begin
      part = w34_copy_fixture(parent, "all_1_1_0")
      mark_path = File.join(part, "#{CrystalClick::StreamName.hash("maybe.null")}.mrk2")
      before = File.read(mark_path).to_slice.dup
      w34_decode_stream(part, "maybe.null").size.should eq(17)
      w34_write_mark_offset(part, "maybe.null", 2, 7_u64)
      File.size(mark_path).should eq(before.size)
      w34_decode_stream(part, "maybe.null").size.should eq(17)
      File.read(mark_path).to_slice.size.should eq(before.size)

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

  it "ignores invalid nested bytes hidden under a valid nullable NULL flag" do
    parent = File.tempname("crystal-click-w34-hidden-null-bool")
    Dir.mkdir(parent)
    begin
      part = w34_copy_fixture(parent, "all_1_1_0")
      raw_path = File.join(part, "#{CrystalClick::StreamName.hash("maybe")}.bin")
      raw = CrystalClick::CompressedBlock.decode_all(File.read(raw_path).to_slice).dup
      raw[0].should eq(0_u8)
      raw[0] = 255_u8
      w34_replace_raw_stream(part, "maybe", raw)
      w34_refresh_checksums(part)

      CrystalClick::WidePart.open_typed(part, "maybe")
        .read_array_nullable_bool_mark_range("maybe", 0, 1).should eq(w34_nullable_bool_values[0, 2])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "materializes both arrays for full and row-window batches and caller-owned catalog values" do
    expected_plain = w34_bool_values
    expected_nullable = w34_nullable_bool_values
    expected_rows = W34_BOOL_KEYS.each_with_index.map do |key, index|
      {key, expected_plain[index], expected_nullable[index]}
    end.to_a

    table_root = File.tempname("crystal-click-w34-table")
    Dir.mkdir(table_root)
    part = File.join(table_root, "all_1_1_0")
    begin
      FileUtils.cp_r(W34_BOOL_FIXTURE, part)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "plain", "maybe"])
      observed = [] of {UInt64, Array(Bool), Array(Bool?)}
      table.scan_typed(batch_rows: 3) do |batch|
        keys = batch.values_for("pk", UInt64)
        plain = batch.array_bools_for("plain")
        nullable = batch.array_nullable_bools_for("maybe")
        keys.each_index { |index| observed << {keys[index], plain[index].dup, nullable[index].dup} }
      end
      observed.should eq(expected_rows)

      window_rows = [] of {UInt64, Array(Bool), Array(Bool?)}
      table.scan_typed_window(2_u64, max_rows: 7) do |batch|
        keys = batch.values_for("pk", UInt64)
        plain = batch.array_bools_for("plain")
        nullable = batch.array_nullable_bools_for("maybe")
        keys.each_index { |index| window_rows << {keys[index], plain[index].dup, nullable[index].dup} }
      end
      window_rows.should eq(expected_rows[2, 7])
    ensure
      FileUtils.rm_rf(table_root)
    end

    w34_catalog_root do |root|
      catalog_table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      plain_values = catalog_table["plain"].values.map { |value| value.as(Array(Bool)) }
      nullable_values = catalog_table["maybe"].values.map { |value| value.as(Array(Bool?)) }
      plain_values.should eq(expected_plain)
      nullable_values.should eq(expected_nullable)

      plain_values[1][0] = !plain_values[1][0]
      nullable_values[1][1] = !nullable_values[1][1].as(Bool)
      catalog_table["plain"].values.map { |value| value.as(Array(Bool)) }.should eq(expected_plain)
      catalog_table["maybe"].values.map { |value| value.as(Array(Bool?)) }.should eq(expected_nullable)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes Array(Bool) and Array(Nullable(Bool)) with exact child bytes" do
    parent = File.tempname("crystal-click-w34-bool-writers")
    Dir.mkdir(parent)
    keys = W34_BOOL_KEYS
    plain = w34_bool_values
    nullable = w34_nullable_bool_values
    plain_part = File.join(parent, "plain")
    nullable_part = File.join(parent, "nullable")
    begin
      CrystalClick::WidePartWriter.write_uint64_array_bool_pair(
        plain_part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        plain.to_unsafe.to_slice(plain.size),
        rows_per_mark: 2
      )
      plain_reader = CrystalClick::WidePart.open_typed(plain_part, "payload")
      plain_reader.column_type.should eq("Array(Bool)")
      plain_reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
      plain_reader.read_array_bool_mark_range("payload", 0, plain_reader.mark_count).should eq(plain)
      w34_decode_stream(plain_part, "payload.size0").should eq(w34_size_stream(plain))
      w34_decode_stream(plain_part, "payload").should eq(w34_bool_payload(plain))

      CrystalClick::WidePartWriter.write_uint64_array_nullable_bool_pair(
        nullable_part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        nullable.to_unsafe.to_slice(nullable.size),
        rows_per_mark: 2
      )
      nullable_reader = CrystalClick::WidePart.open_typed(nullable_part, "payload")
      nullable_reader.column_type.should eq("Array(Nullable(Bool))")
      nullable_reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
      nullable_reader.read_array_nullable_bool_mark_range("payload", 0, nullable_reader.mark_count).should eq(nullable)
      w34_decode_stream(nullable_part, "payload.size0").should eq(w34_size_stream(nullable))
      w34_decode_stream(nullable_part, "payload.null").should eq(w34_null_map(nullable))
      w34_decode_stream(nullable_part, "payload").should eq(w34_nullable_bool_payload(nullable))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects unsorted keys without publishing either Bool array destination" do
    parent = File.tempname("crystal-click-w34-rejected-bool-writer")
    Dir.mkdir(parent)
    before = Dir.children(parent).sort
    keys = [2_u64, 1_u64]
    plain = [[] of Bool, [] of Bool]
    nullable = [[] of Bool?, [] of Bool?]
    plain_destination = File.join(parent, "plain")
    nullable_destination = File.join(parent, "nullable")
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_bool_pair(
          plain_destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          plain.to_unsafe.to_slice(plain.size),
          rows_per_mark: 2
        )
      end
      File.exists?(plain_destination).should be_false
      Dir.children(parent).sort.should eq(before)

      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_nullable_bool_pair(
          nullable_destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          nullable.to_unsafe.to_slice(nullable.size),
          rows_per_mark: 2
        )
      end
      File.exists?(nullable_destination).should be_false
      Dir.children(parent).sort.should eq(before)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes 4097 all-empty Bool arrays with one row per mark and empty child streams" do
    parent = File.tempname("crystal-click-w34-empty-bool-writers")
    Dir.mkdir(parent)
    row_count = 4097
    keys = Array(UInt64).new(row_count) { |index| (index + 1).to_u64 }
    plain_values = Array(Array(Bool)).new(row_count) { [] of Bool }
    nullable_values = Array(Array(Bool?)).new(row_count) { [] of Bool? }
    plain_part = File.join(parent, "plain")
    nullable_part = File.join(parent, "nullable")
    expected_mark_rows = Array(UInt64).new(row_count, 1_u64)
    begin
      CrystalClick::WidePartWriter.write_uint64_array_bool_pair(
        plain_part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        plain_values.to_unsafe.to_slice(plain_values.size),
        rows_per_mark: 1
      )

      Dir.exists?(plain_part).should be_true
      plain_reader = CrystalClick::WidePart.open_typed(plain_part, "payload")
      plain_reader.row_count.should eq(row_count.to_u64)
      plain_reader.mark_count.should eq(row_count)
      plain_reader.mark_row_counts.should eq(expected_mark_rows)
      plain_reader.read_array_bool_mark_range("payload", 0, plain_reader.mark_count).should eq(plain_values)
      plain_reader.read_array_bool_mark_range("payload", row_count - 1, 1).should eq([[] of Bool])
      File.size(File.join(plain_part, "#{CrystalClick::StreamName.hash("payload")}.bin")).should eq(0)
      w34_decode_stream(plain_part, "payload.size0").should eq(Array(UInt8).new(row_count * 8, 0_u8))

      ["pk", "payload.size0", "payload"].each do |stream|
        marks = File.read(File.join(plain_part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
        marks.size.should eq((row_count + 1) * CrystalClick::WidePart::MARK_SIZE)
        row_count.times do |record|
          w34_read_u64(marks, record * CrystalClick::WidePart::MARK_SIZE + 16).should eq(1_u64)
        end
        sentinel_offset = row_count * CrystalClick::WidePart::MARK_SIZE
        w34_read_u64(marks, sentinel_offset + 16).should eq(0_u64)
        if stream == "payload"
          w34_read_u64(marks, sentinel_offset).should eq(0_u64)
          w34_read_u64(marks, sentinel_offset + 8).should eq(0_u64)
        end
      end

      CrystalClick::WidePartWriter.write_uint64_array_nullable_bool_pair(
        nullable_part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        nullable_values.to_unsafe.to_slice(nullable_values.size),
        rows_per_mark: 1
      )

      Dir.exists?(nullable_part).should be_true
      nullable_reader = CrystalClick::WidePart.open_typed(nullable_part, "payload")
      nullable_reader.row_count.should eq(row_count.to_u64)
      nullable_reader.mark_count.should eq(row_count)
      nullable_reader.mark_row_counts.should eq(expected_mark_rows)
      nullable_reader.read_array_nullable_bool_mark_range("payload", 0, nullable_reader.mark_count).should eq(nullable_values)
      nullable_reader.read_array_nullable_bool_mark_range("payload", row_count - 1, 1).should eq([[] of Bool?])
      File.size(File.join(nullable_part, "#{CrystalClick::StreamName.hash("payload.null")}.bin")).should eq(0)
      File.size(File.join(nullable_part, "#{CrystalClick::StreamName.hash("payload")}.bin")).should eq(0)
      w34_decode_stream(nullable_part, "payload.size0").should eq(Array(UInt8).new(row_count * 8, 0_u8))

      ["pk", "payload.size0", "payload.null", "payload"].each do |stream|
        marks = File.read(File.join(nullable_part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
        marks.size.should eq((row_count + 1) * CrystalClick::WidePart::MARK_SIZE)
        row_count.times do |record|
          w34_read_u64(marks, record * CrystalClick::WidePart::MARK_SIZE + 16).should eq(1_u64)
        end
        sentinel_offset = row_count * CrystalClick::WidePart::MARK_SIZE
        w34_read_u64(marks, sentinel_offset + 16).should eq(0_u64)
        if stream == "payload.null" || stream == "payload"
          w34_read_u64(marks, sentinel_offset).should eq(0_u64)
          w34_read_u64(marks, sentinel_offset + 8).should eq(0_u64)
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
