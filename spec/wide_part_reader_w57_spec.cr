require "./spec_helper"

W57_FIXTURE_ROOT = File.expand_path("../test/fixtures/public/wide_variant_w57", __DIR__)
W57_COMPACT_PART = File.join(W57_FIXTURE_ROOT, "compact", "part")
W57_BASIC_PART   = File.join(W57_FIXTURE_ROOT, "basic", "part")
W57_KEYS         = Array(UInt64).new(13) { |index| (index + 1).to_u64 }
W57_VALUES       = [true, "alpha", 42_u64, false, true, false, nil, nil, nil, "", UInt64::MAX, "omega", 99_u64] of Bool | String | UInt64 | Nil
W57_TYPE         = "Variant(Bool, String, UInt64)"

private def w57_fixture(profile : String) : String
  case profile
  when "compact" then W57_COMPACT_PART
  when "basic"   then W57_BASIC_PART
  else                raise "unknown W57 fixture profile: #{profile}"
  end
end

private def w57_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def w57_with_offline_catalog_root(& : String ->)
  root = File.tempname("crystal-click-w57-variant-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    database_uuid = "2385c4fb-85bd-4a88-ae4d-28e1033112d4"
    table_uuid = "dc7b19a3-6f22-46ec-9bb4-760aaf27f89d"
    database_path = w57_store_path(root, database_uuid)
    table_path = w57_store_path(root, table_uuid)
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    File.write(
      File.join(root, "metadata", "lab.sql"),
      "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n"
    )
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{W57_TYPE}\n)\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W57_COMPACT_PART, File.join(table_path, "all_1_1_0"))
    yield root
  ensure
    FileUtils.rm_rf(root) if root && Dir.exists?(root)
  end
end

private def w57_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w57_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w57_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w57_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |byte| io.write_byte(((hash[0] >> (byte * 8)) & 0xff_u64).to_u8) }
  8.times { |byte| io.write_byte(((hash[1] >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w57_lz4_literal_frame(bytes : Bytes) : Bytes
  compressed = IO::Memory.new
  literal_length = bytes.size
  if literal_length < 15
    compressed.write_byte((literal_length << 4).to_u8)
  else
    compressed.write_byte(0xf0_u8)
    remainder = literal_length - 15
    while remainder >= 255
      compressed.write_byte(255_u8)
      remainder -= 255
    end
    compressed.write_byte(remainder.to_u8)
  end
  compressed.write(bytes)
  payload = compressed.to_slice

  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload.size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload.size
  w57_write_u32(frame, header + 1, compressed_size.to_u32)
  w57_write_u32(frame, header + 5, bytes.size.to_u32)
  payload.copy_to(frame[CrystalClick::CompressedBlock::FRAME_HEADER_SIZE, payload.size])
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  w57_write_u64(frame, 0, checksum[0])
  w57_write_u64(frame, 8, checksum[1])
  frame
end

private def w57_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w57_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w57_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w57_write_varuint(payload, file_bytes.size.to_u64)
    w57_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = file_bytes.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w57_write_varuint(payload, raw.size.to_u64)
      w57_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(w57_lz4_literal_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), output.to_slice)
end

private def w57_replace_stream_bytes(part : String, logical_name : String, raw : Bytes) : Nil
  stream_hash = CrystalClick::StreamName.hash(logical_name)
  data_path = File.join(part, "#{stream_hash}.bin")
  marks_path = File.join(part, "#{stream_hash}.mrk2")
  frame = w57_lz4_literal_frame(raw)
  File.write(data_path, frame)

  marks = File.read(marks_path).to_slice.dup
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "W57 corruption probe expects one mark and a sentinel" unless marks.size == 2 * mark_size
  w57_write_u64(marks, mark_size, frame.size.to_u64)
  File.write(marks_path, marks)
  w57_refresh_checksums(part)
end

private def w57_replace_stream_mark_bytes(part : String, logical_name : String, mark_index : Int, & : Bytes ->)
  stream_hash = CrystalClick::StreamName.hash(logical_name)
  data_path = File.join(part, "#{stream_hash}.bin")
  marks_path = File.join(part, "#{stream_hash}.mrk2")
  data = File.read(data_path).to_slice
  output = IO::Memory.new
  frame_offsets = [] of UInt64
  offset = 0_i64
  frame_index = 0
  while offset < data.size.to_i64
    frame = CrystalClick::CompressedBlock.decode_frame(data, offset)
    frame_offsets << output.size.to_u64
    if frame_index == mark_index
      raw = frame.output.dup
      yield raw
      output.write(w57_lz4_literal_frame(raw))
    else
      output.write(data[offset.to_i, (frame.end_offset - offset).to_i])
    end
    offset = frame.end_offset
    frame_index += 1
  end
  raise "W57 corruption probe mark has no compressed frame" if mark_index < 0 || mark_index >= frame_offsets.size
  File.write(data_path, output.to_slice)

  marks = File.read(marks_path).to_slice.dup
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "W57 corruption probe expected one mark record per frame and an EOF sentinel" unless marks.size == (frame_offsets.size + 1) * mark_size
  frame_offsets.each_with_index do |compressed_offset, index|
    w57_write_u64(marks, index * mark_size, compressed_offset)
  end
  w57_write_u64(marks, frame_offsets.size * mark_size, output.size.to_u64)
  File.write(marks_path, marks)
  w57_refresh_checksums(part)
end

private def w57_with_writer_values_part(
  values : Array(CrystalClick::VariantBoolStringUInt64Value),
  rows_per_mark : Int32 = 0,
  & : String ->
)
  parent = File.tempname("crystal-click-w57-variant-writer")
  Dir.mkdir(parent)
  path = File.join(parent, "all_1_1_0")
  keys = Array(UInt64).new(values.size) { |index| (index + 1).to_u64 }
  begin
    CrystalClick::WidePartWriter.write_uint64_variant_bool_string_uint64_pair(
      path,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      values.to_unsafe.to_slice(values.size),
      rows_per_mark: rows_per_mark > 0 ? rows_per_mark : values.size
    )
    yield path
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w57_assert_scan_fails_before_callback(path : String, expected_error : String) : Nil
  callbacks = 0
  error = expect_raises(CrystalClick::CorruptPartError) do
    table = CrystalClick::WidePartTable.open_selected_typed([path], ["payload"])
    table.scan_typed(batch_rows: 3) { callbacks += 1 }
  end
  (error.message || "").should contain(expected_error)
  callbacks.should eq(0)
end

describe "W57 three-arm Variant admission" do
  it "admits the canonical Bool/String/UInt64 declaration without widening arbitrary Variant" do
    CrystalClick::WidePart.supports_typed_type?(W57_TYPE).should be_true
    {
      "Variant(UInt64, Bool, String)",
      "Variant(Bool, UInt64, String)",
      "Variant(Bool, String, UInt32)",
      "Variant(Bool, String, UInt64, UUID)",
      "Variant(Bool, Nullable(String), UInt64)",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "keeps descriptor arrays from mutating the canonical W57 plan" do
    descriptor = CrystalClick::WideVariantBoolStringUInt64TypePlan::DESCRIPTOR
    expected_streams = [
      "payload.variant_discr", "payload.Bool", "payload.String.size", "payload.String", "payload.UInt64",
    ]

    arms = descriptor.arms
    arms[0].child_streams.clear
    arms.clear
    child_streams = descriptor.child_streams("payload", "Bool")
    child_streams.clear

    descriptor.physical_streams("payload").should eq(expected_streams)
    descriptor.tag_for("Bool").should eq(0_u8)
  end

  it "reads exact stock BASIC and COMPACT parts across mixed, uniform, NULL, absent-arm, and short-tail granules" do
    {"compact", "basic"}.each do |profile|
      part = w57_fixture(profile)
      File.read(File.join(part, "columns.txt")).should contain("`payload` #{W57_TYPE}")
      File.read(File.join(part, "columns_substreams.txt")).should contain(
        "5 substreams for column `payload`:\n\tpayload.variant_discr\n\tpayload.Bool\n\tpayload.String.size\n\tpayload.String\n\tpayload.UInt64\n"
      )

      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.column_type.should eq(W57_TYPE)
      reader.row_count.should eq(13_u64)
      reader.mark_row_counts.should eq([3_u64, 3_u64, 3_u64, 3_u64, 1_u64])
      reader.read_variant_bool_string_uint64_mark_range("payload", 0, reader.mark_count)
        .should eq(W57_VALUES)
      reader.read_variant_bool_string_uint64_mark_range("payload", 0, 1)
        .should eq(W57_VALUES[0, 3])
      reader.read_variant_bool_string_uint64_mark_range("payload", 1, 1)
        .should eq(W57_VALUES[3, 3])
      reader.read_variant_bool_string_uint64_mark_range("payload", 2, 1)
        .should eq(W57_VALUES[6, 3])
      reader.read_variant_bool_string_uint64_mark_range("payload", 3, 1)
        .should eq(W57_VALUES[9, 3])
      reader.read_variant_bool_string_uint64_mark_range("payload", 4, 1)
        .should eq(W57_VALUES[12, 1])
    end
  end

  it "rejects invalid Bool child bytes and discriminator tags before callbacks" do
    cases = {
      "Bool child code"   => {"payload.Bool", [true, false, true] of CrystalClick::VariantBoolStringUInt64Value, 0, "Variant Bool child code is unsupported"},
      "discriminator tag" => {"payload.variant_discr", [true, "tag probe", 7_u64] of CrystalClick::VariantBoolStringUInt64Value, 10, "Variant discriminator tag is unsupported"},
    }

    cases.each do |label, (logical_name, values, offset, expected_error)|
      w57_with_writer_values_part(values) do |path|
        stream = CrystalClick::StreamName.hash(logical_name)
        data_path = File.join(path, "#{stream}.bin")
        raw = CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).dup
        if label == "Bool child code"
          raw[offset] = 2_u8
        else
          raw[offset].should eq(0_u8)
          raw[offset] = 3_u8
        end
        w57_replace_stream_bytes(path, logical_name, raw)
        w57_assert_scan_fails_before_callback(path, expected_error)
      end
    end
  end

  it "does not yield a later corrupt granule after a valid first-granule callback" do
    values = [true, "first granule", 11_u64, false, "second granule", 22_u64] of CrystalClick::VariantBoolStringUInt64Value
    w57_with_writer_values_part(values, rows_per_mark: 3) do |path|
      w57_replace_stream_mark_bytes(path, "payload.variant_discr", 1) do |second_mark|
        second_mark[0].should eq(3_u8) # row count
        second_mark[1].should eq(0_u8) # row-tag format
        second_mark[2].should eq(0_u8) # Bool tag in the first second-mark row
        second_mark[2] = 3_u8
      end

      callbacks = 0
      observed = [] of CrystalClick::VariantBoolStringUInt64Value
      error = expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([path], ["payload"])
        table.scan_typed(batch_rows: 3) do |batch|
          callbacks += 1
          observed.concat(batch.variant_bool_string_uint64_for("payload"))
        end
      end
      (error.message || "").should contain("Variant discriminator tag is unsupported")
      callbacks.should eq(1)
      observed.should eq(values[0, 3])
    end
  end

  it "keeps table batches and offline catalog values row-aligned" do
    {"compact", "basic"}.each do |profile|
      table_parent = File.tempname("crystal-click-w57-variant-part")
      Dir.mkdir(table_parent)
      table_path = File.join(table_parent, "all_1_1_0")
      FileUtils.cp_r(w57_fixture(profile), table_path)
      begin
        table = CrystalClick::WidePartTable.open_selected_typed([table_path], ["payload"])

        observed = [] of Bool | String | UInt64 | Nil
        table.scan_typed(batch_rows: 2) do |batch|
          observed.concat(batch.variant_bool_string_uint64_for("payload"))
        end
        observed.should eq(W57_VALUES)

        one_row_batches = [] of Int32
        one_row_values = [] of Bool | String | UInt64 | Nil
        table.scan_typed(batch_rows: 1) do |batch|
          rows = batch.variant_bool_string_uint64_for("payload")
          one_row_batches << rows.size.to_i32
          one_row_values.concat(rows)
        end
        one_row_batches.should eq(Array.new(W57_VALUES.size, 1_i32))
        one_row_values.should eq(W57_VALUES)

        later_rows = [] of Bool | String | UInt64 | Nil
        table.scan_typed_window(6_u64, max_rows: 7) do |batch|
          later_rows.concat(batch.variant_bool_string_uint64_for("payload"))
        end
        later_rows.should eq(W57_VALUES[6, 7])
      ensure
        FileUtils.rm_rf(table_parent)
      end
    end

    w57_with_offline_catalog_root do |root|
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      values = table["payload"].values
      values.size.should eq(W57_VALUES.size)
      values.each_with_index { |value, index| value.should eq(W57_VALUES[index]) }
    end
  end
end
