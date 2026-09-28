require "./spec_helper"

W56_FIXTURE_ROOT = File.expand_path("../test/fixtures/public/wide_variant_w56", __DIR__)
W56_COMPACT_PART = File.join(W56_FIXTURE_ROOT, "compact", "part")
W56_BASIC_PART   = File.join(W56_FIXTURE_ROOT, "basic", "part")
W56_KEYS         = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
W56_VALUES       = ["alpha", 42_u64, nil, nil, nil, nil, ""] of String | UInt64 | Nil
W56_TYPE         = "Variant(String, UInt64)"

private def w56_fixture(profile : String) : String
  case profile
  when "compact" then W56_COMPACT_PART
  when "basic"   then W56_BASIC_PART
  else                raise "unknown W56 fixture profile: #{profile}"
  end
end

private def w56_copy_fixture(profile : String = "compact") : String
  parent = File.tempname("crystal-click-w56-variant-part")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  FileUtils.cp_r(w56_fixture(profile), part)
  part
end

private def w56_remove_fixture(part : String) : Nil
  parent = File.dirname(part)
  unless File.basename(part) == "all_1_1_0" && File.basename(parent).includes?("crystal-click-w56-variant-part")
    raise "refusing to remove a path that is not a W56 temporary fixture"
  end
  FileUtils.rm_rf(parent)
end

private def w56_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def w56_with_offline_catalog_root(& : String ->)
  root = File.tempname("crystal-click-w56-variant-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    database_uuid = "98592fac-4170-49d0-b3b8-09a0b0d014ed"
    table_uuid = "1fe356c3-3ae8-47f3-aa65-76012bd35f34"
    database_path = w56_store_path(root, database_uuid)
    table_path = w56_store_path(root, table_uuid)
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    File.write(
      File.join(root, "metadata", "lab.sql"),
      "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n"
    )
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{W56_TYPE}\n)\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W56_COMPACT_PART, File.join(table_path, "all_1_1_0"))
    yield root
  ensure
    FileUtils.rm_rf(root) if root && Dir.exists?(root)
  end
end

private def w56_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w56_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w56_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w56_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |byte| io.write_byte(((hash[0] >> (byte * 8)) & 0xff_u64).to_u8) }
  8.times { |byte| io.write_byte(((hash[1] >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w56_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w56_lz4_literal_frame(bytes : Bytes) : Bytes
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
  w56_write_u32(frame, header + 1, compressed_size.to_u32)
  w56_write_u32(frame, header + 5, bytes.size.to_u32)
  payload.copy_to(frame[CrystalClick::CompressedBlock::FRAME_HEADER_SIZE, payload.size])
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  w56_write_u64(frame, 0, checksum[0])
  w56_write_u64(frame, 8, checksum[1])
  frame
end

private def w56_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w56_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w56_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w56_write_varuint(payload, file_bytes.size.to_u64)
    w56_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w56_write_varuint(payload, raw.size.to_u64)
      w56_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(w56_lz4_literal_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), output.to_slice)
end

private def w56_replace_variant_discriminator_bytes(path : String, raw : Bytes) : Nil
  stream_hash = CrystalClick::StreamName.hash("payload.variant_discr")
  data_path = File.join(path, "#{stream_hash}.bin")
  marks_path = File.join(path, "#{stream_hash}.mrk2")
  frame = w56_lz4_literal_frame(raw)
  File.write(data_path, frame)

  marks = File.read(marks_path).to_slice.dup
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "W56 writer mutation expects one mark and a sentinel" unless marks.size == 2 * mark_size
  # Keep one complete frame: ClickHouse's Variant reader positions after the
  # eight-byte mode prefix for its first discriminator granule.
  w56_write_u64(marks, 0, 0_u64)
  w56_write_u64(marks, 8, 8_u64)
  w56_write_u64(marks, mark_size, frame.size.to_u64)
  w56_write_u64(marks, mark_size + 8, 0_u64)
  File.write(marks_path, marks)
  w56_refresh_checksums(path)
end

private def w56_with_writer_part(& : String ->)
  parent = File.tempname("crystal-click-w56-variant-writer")
  Dir.mkdir(parent)
  path = File.join(parent, "all_1_1_0")
  begin
    CrystalClick::WidePartWriter.write_uint64_variant_string_uint64_pair(
      path,
      "pk",
      W56_KEYS.to_unsafe.to_slice(W56_KEYS.size),
      "payload",
      W56_VALUES.to_unsafe.to_slice(W56_VALUES.size),
      rows_per_mark: W56_VALUES.size
    )
    yield path
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w56_with_writer_values_part(values : Slice(CrystalClick::VariantStringUInt64Value), rows_per_mark : Int32, & : String ->)
  parent = File.tempname("crystal-click-w56-variant-writer-values")
  Dir.mkdir(parent)
  path = File.join(parent, "all_1_1_0")
  keys = Array(UInt64).new(values.size) { |index| (index + 1).to_u64 }
  begin
    CrystalClick::WidePartWriter.write_uint64_variant_string_uint64_pair(
      path,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      values,
      rows_per_mark: rows_per_mark
    )
    yield path
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w56_assert_scan_fails_before_callback(path : String, expected_error : String) : Nil
  callbacks = 0
  error = expect_raises(CrystalClick::CorruptPartError) do
    table = CrystalClick::WidePartTable.open_selected_typed([path], ["payload"])
    table.scan_typed(batch_rows: 3) { callbacks += 1 }
  end
  (error.message || "").should contain(expected_error)
  callbacks.should eq(0)
end

describe "W56 paired Variant(String, UInt64) reader" do
  it "admits exactly the paired Variant payload declaration" do
    CrystalClick::WidePart.supports_typed_type?(W56_TYPE).should be_true
    {
      "Variant(UInt64, String)",
      "Variant(String, UInt32)",
      "Variant(String, UInt64, UInt8)",
      "Variant(String, Nullable(UInt64))",
      "Variant(String, Nothing)",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads stock COMPACT and BASIC parts with exact mark and discriminator framing" do
    {"compact", "basic"}.each do |profile|
      fixture = w56_fixture(profile)
      columns = File.read(File.join(fixture, "columns.txt"))
      columns.should contain("`payload` #{W56_TYPE}")

      reader = CrystalClick::WidePart.open_typed(fixture, "payload")
      reader.column_type.should eq(W56_TYPE)
      reader.row_count.should eq(7_u64)
      reader.mark_row_counts.should eq([3_u64, 3_u64, 1_u64])
      reader.read_variant_string_uint64_mark_range("payload", 0, reader.mark_count)
        .should eq(W56_VALUES)
      reader.read_variant_string_uint64_mark_range("payload", 1, 2)
        .should eq(W56_VALUES[3, 4])
    end
  end

  it "rejects a discriminator first mark that includes the stream mode prefix" do
    path = w56_copy_fixture("compact")
    begin
      stream = CrystalClick::StreamName.hash("payload.variant_discr")
      marks_path = File.join(path, "#{stream}.mrk2")
      marks = File.read(marks_path).to_slice.dup
      w56_read_u64(marks, 0).should eq(0_u64)
      w56_read_u64(marks, 8).should eq(8_u64)

      w56_write_u64(marks, 8, 0_u64)
      File.write(marks_path, marks)
      w56_refresh_checksums(path)

      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(path, "payload")
      end
      (error.message || "").should contain("Variant discriminator first mark must start after eight-byte mode prefix")
    ensure
      w56_remove_fixture(path)
    end
  end

  it "keeps table batches and offline catalog materialization row-aligned" do
    {"compact", "basic"}.each do |profile|
      table_path = w56_copy_fixture(profile)
      begin
        table = CrystalClick::WidePartTable.open_selected_typed([table_path], ["payload"])
        observed = [] of String | UInt64 | Nil
        table.scan_typed(batch_rows: 2) do |batch|
          observed.concat(batch.variant_string_uint64_for("payload"))
        end
        observed.should eq(W56_VALUES)

        one_row_batches = [] of Int32
        one_row_values = [] of String | UInt64 | Nil
        table.scan_typed(batch_rows: 1) do |batch|
          rows = batch.variant_string_uint64_for("payload")
          one_row_batches << rows.size.to_i32
          one_row_values.concat(rows)
        end
        one_row_batches.should eq(Array.new(W56_VALUES.size, 1_i32))
        one_row_values.should eq(W56_VALUES)

        later_rows = [] of String | UInt64 | Nil
        table.scan_typed_window(3_u64, max_rows: 4) do |batch|
          later_rows.concat(batch.variant_string_uint64_for("payload"))
        end
        later_rows.should eq(W56_VALUES[3, 4])
      ensure
        w56_remove_fixture(table_path)
      end
    end

    w56_with_offline_catalog_root do |root|
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      values = table["payload"].values
      values.size.should eq(W56_VALUES.size)
      values.each_with_index { |value, index| value.should eq(W56_VALUES[index]) }
    end
  end

  it "rejects unsupported Variant declarations and reordered or missing streams" do
    with_variant_type = w56_copy_fixture
    begin
      columns_path = File.join(with_variant_type, "columns.txt")
      original = File.read(columns_path)
      changed = original.sub("Variant(String, UInt64)", "Variant(String, UInt32)")
      changed.should_not eq(original)
      File.write(columns_path, changed)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(with_variant_type, "payload")
      end
    ensure
      w56_remove_fixture(with_variant_type)
    end

    {"reordered", "missing"}.each do |mutation|
      path = w56_copy_fixture
      begin
        metadata_path = File.join(path, "columns_substreams.txt")
        original = File.read(metadata_path)
        changed = if mutation == "reordered"
                    original.sub(
                      "\tpayload.variant_discr\n\tpayload.String.size\n\tpayload.String\n\tpayload.UInt64\n",
                      "\tpayload.UInt64\n\tpayload.variant_discr\n\tpayload.String.size\n\tpayload.String\n"
                    )
                  else
                    original.sub(
                      "4 substreams for column `payload`:\n\tpayload.variant_discr\n\tpayload.String.size\n\tpayload.String\n\tpayload.UInt64\n",
                      "3 substreams for column `payload`:\n\tpayload.variant_discr\n\tpayload.String.size\n\tpayload.String\n"
                    )
                  end
        changed.should_not eq(original)
        File.write(metadata_path, changed)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_typed(path, "payload")
        end
      ensure
        w56_remove_fixture(path)
      end
    end
  end

  it "rejects invalid discriminator mode, tag, format, count, truncation, and child marks before callbacks" do
    expected_errors = {
      "mode"      => "Variant discriminator mode is unsupported",
      "tag"       => "Variant discriminator tag is unsupported",
      "format"    => "Variant COMPACT discriminator format is unsupported",
      "count"     => "Variant COMPACT mark row count does not match marks",
      "truncated" => "Variant COMPACT discriminator tags are truncated",
    }
    {"mode", "tag", "format", "count", "truncated"}.each do |mutation|
      w56_with_writer_part do |writer_path|
        discr_path = File.join(writer_path, "#{CrystalClick::StreamName.hash("payload.variant_discr")}.bin")
        raw = CrystalClick::CompressedBlock.decode_all(File.read(discr_path).to_slice).dup
        case mutation
        when "mode"
          raw[0] = 2_u8
        when "tag"
          raw[10] = 2_u8
        when "format"
          raw[9] = 2_u8
        when "count"
          raw[8] = 6_u8
        when "truncated"
          shorter = Bytes.new(raw.size - 1)
          raw[0, shorter.size].copy_to(shorter)
          raw = shorter
        else
          raise "unhandled W56 discriminator mutation"
        end
        w56_replace_variant_discriminator_bytes(writer_path, raw)
        w56_assert_scan_fails_before_callback(writer_path, expected_errors[mutation])
      end
    end

    w56_with_writer_values_part(W56_VALUES.to_unsafe.to_slice(W56_VALUES.size), 3) do |writer_path|
      stream = CrystalClick::StreamName.hash("payload.UInt64")
      marks_path = File.join(writer_path, "#{stream}.mrk2")
      marks = File.read(marks_path).to_slice.dup
      # Preserve the stream's total top-level row count while shifting one row
      # from its second mark to the first, isolating cross-child mark agreement.
      w56_write_u64(marks, 16, 4_u64)
      w56_write_u64(marks, CrystalClick::WidePart::MARK_SIZE + 16, 2_u64)
      File.write(marks_path, marks)
      w56_assert_scan_fails_before_callback(writer_path, "selected substreams have different mark row counts")
    end
  end

  it "writes a self-readable COMPACT part with the exact value domain" do
    w56_with_writer_part do |path|
      writer_part = CrystalClick::WidePart.open_typed(path, "payload")
      writer_part.column_type.should eq(W56_TYPE)
      writer_part.mark_row_counts.should eq([W56_VALUES.size.to_u64])
      writer_part.read_variant_string_uint64_mark_range("payload", 0, writer_part.mark_count)
        .should eq(W56_VALUES)
    end
  end

  it "writes and scans all-NULL and all-String discriminator marks" do
    all_null = Array(CrystalClick::VariantStringUInt64Value).new(W56_VALUES.size, nil)
    w56_with_writer_values_part(all_null.to_unsafe.to_slice(all_null.size), 3) do |path|
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.mark_row_counts.should eq([3_u64, 3_u64, 1_u64])
      reader.read_variant_string_uint64_mark_range("payload", 0, reader.mark_count)
        .should eq(all_null)
    end

    all_strings = Array(CrystalClick::VariantStringUInt64Value).new(W56_VALUES.size) { |index| "v#{index}" }
    w56_with_writer_values_part(all_strings.to_unsafe.to_slice(all_strings.size), 3) do |path|
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.mark_row_counts.should eq([3_u64, 3_u64, 1_u64])
      reader.read_variant_string_uint64_mark_range("payload", 0, reader.mark_count)
        .should eq(all_strings)
    end
  end
end
