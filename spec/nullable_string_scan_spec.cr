require "./spec_helper"

NULLABLE_STRING_FIXTURE    = File.expand_path("../test/fixtures/public/wide_nullable_string/part", __DIR__)
NULLABLE_STRING_DB_UUID    = "2572b682-7c61-4e41-9cab-38904e46f22d"
NULLABLE_STRING_TABLE_UUID = "ae5e7f88-ae67-4623-8ca4-10044c0b4fea"
NULLABLE_STRING_ORACLE     = ["P", nil, "Q", "", "a\0b", "z", nil, "Q\0R"] of String?

def nullable_string_copy : String
  copy = File.tempname("crystal-click-nullable-string-part-spec")
  FileUtils.cp_r(NULLABLE_STRING_FIXTURE, copy)
  copy
end

def with_nullable_string_table(ddl_type : String = "Nullable(String)", &)
  root = File.tempname("crystal-click-nullable-string-catalog-spec")
  metadata_root = File.join(root, "metadata")
  database_path = File.join(root, "store", NULLABLE_STRING_DB_UUID[0, 3], NULLABLE_STRING_DB_UUID)
  table_path = File.join(root, "store", NULLABLE_STRING_TABLE_UUID[0, 3], NULLABLE_STRING_TABLE_UUID)
  FileUtils.mkdir_p(metadata_root)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  begin
    File.write(File.join(metadata_root, "lab.sql"), "ATTACH DATABASE _ UUID '#{NULLABLE_STRING_DB_UUID}'\nENGINE = Atomic\n")
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{NULLABLE_STRING_TABLE_UUID}'\n(\n    `seq` UInt64,\n    `payload` #{ddl_type}\n)\nENGINE = MergeTree\nORDER BY seq\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    part_path = File.join(table_path, "all_1_1_0")
    FileUtils.cp_r(NULLABLE_STRING_FIXTURE, part_path)
    yield root, part_path
  ensure
    FileUtils.rm_rf(root)
  end
end

def nullable_string_stream_path(part_path : String, stream_name : String, extension : String) : String
  File.join(part_path, "#{CrystalClick::StreamName.hash(stream_name)}.#{extension}")
end

def nullable_string_lz4_frame(raw : Bytes) : Bytes
  payload = IO::Memory.new
  if raw.size < 15
    payload.write_byte((raw.size << 4).to_u8)
  else
    payload.write_byte(0xf0_u8)
    remaining = raw.size - 15
    while remaining >= 255
      payload.write_byte(255_u8)
      remaining -= 255
    end
    payload.write_byte(remaining.to_u8)
  end
  payload.write(raw)
  compressed = payload.to_slice
  frame = Bytes.new(25 + compressed.size, 0_u8)
  frame[16] = 0x82_u8
  compressed_size = 9 + compressed.size
  4.times do |index|
    frame[17 + index] = ((compressed_size >> (index * 8)) & 0xff).to_u8
    frame[21 + index] = ((raw.size >> (index * 8)) & 0xff).to_u8
  end
  compressed.copy_to(frame.to_unsafe + 25, compressed.size)
  frame
end

def nullable_string_sizes(values : Array(UInt64)) : Bytes
  bytes = Bytes.new(values.size * 8, 0_u8)
  values.each_with_index do |value, index|
    8.times { |offset| bytes[index * 8 + offset] = ((value >> (offset * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

def write_nullable_string_stream(
  part_path : String,
  name : String,
  raw : Bytes,
  mark_offsets : Array(UInt64),
  rows_per_mark : Array(UInt64) = [2_u64, 2_u64, 2_u64, 2_u64],
) : Nil
  frame = nullable_string_lz4_frame(raw)
  File.write(nullable_string_stream_path(part_path, name, "bin"), frame)
  raise "invalid test mark shape" unless mark_offsets.size == rows_per_mark.size
  marks = Bytes.new((rows_per_mark.size + 1) * 24, 0_u8)
  (rows_per_mark.size + 1).times do |row|
    record = row == rows_per_mark.size ? [frame.size.to_u64, 0_u64, 0_u64] : [0_u64, mark_offsets[row], rows_per_mark[row]]
    record.each_with_index do |value, field|
      8.times { |byte| marks[row * 24 + field * 8 + byte] = (value >> (byte * 8)).to_u8 }
    end
  end
  File.write(nullable_string_stream_path(part_path, name, "mrk2"), marks)
end

def write_test_var_uint(io : IO, value : UInt64) : Nil
  while value >= 0x80_u64
    io.write_byte(((value & 0x7f_u64) | 0x80_u64).to_u8)
    value >>= 7
  end
  io.write_byte(value.to_u8)
end

def rewrite_nullable_string_checksums(part_path : String, cloned_streams : Array({String, String}) = [] of {String, String}, wrong_size : String? = nil) : Nil
  entries = CrystalClick::PartChecksums.open(part_path).entries.dup
  cloned_streams.each do |source_name, clone_name|
    entries[clone_name] = entries[source_name]? || raise "missing source checksum entry"
  end

  payload = IO::Memory.new
  write_test_var_uint(payload, entries.size.to_u64)
  entries.each do |name, entry|
    write_test_var_uint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    physical_size = File.size(File.join(part_path, name)).to_u64
    physical_size += 1_u64 if name == wrong_size
    write_test_var_uint(payload, physical_size)
    payload.write(Bytes.new(16, 0_u8))
    if entry.compressed
      payload.write_byte(1_u8)
      write_test_var_uint(payload, entry.uncompressed_size.not_nil!)
      payload.write(Bytes.new(16, 0_u8))
    else
      payload.write_byte(0_u8)
    end
  end
  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(nullable_string_lz4_frame(payload.to_slice))
  File.write(File.join(part_path, "checksums.txt"), output.to_slice)
end

describe "Nullable(String) Wide-part scans" do
  it "admits the exact top-level Nullable(String) type" do
    CrystalClick::WidePart.supports_typed_type?("Nullable(String)").should be_true
  end

  it "preserves the existing typed batch initializer overload" do
    batch = CrystalClick::WidePartTableBatch.new(
      0_i32,
      "all_1_1_0",
      "/tmp/all_1_1_0",
      0_i32,
      0_u64,
      0_u64,
      0_u64,
      ["payload"],
      ["Nullable(String)"],
      Hash(String, CrystalClick::WidePartNumericSlice).new,
      Hash(String, Slice(String)).new,
      Hash(String, CrystalClick::WidePartNullableSlice).new
    )
    error = expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_strings_for("payload") }
    (error.message || "").should contain("column was not materialized")
  end

  it "reads the ClickHouse null, size, and raw streams positionally across marks" do
    part = CrystalClick::WidePart.open_typed(NULLABLE_STRING_FIXTURE, "payload")
    part.column_type.should eq("Nullable(String)")
    part.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
    part.nullable_string_mark_range_raw_bytes("payload", 0, part.mark_count).should eq(9_u64)
    part.read_nullable_string_mark_range("payload", 0, part.mark_count).should eq(NULLABLE_STRING_ORACLE)
    part.read_nullable_string_mark_range("payload", 1, 2).should eq(["Q", "", "a\0b", "z"] of String?)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      part.read_string_mark_range("payload", 0, 1)
    end
  end

  it "consumes nested size and raw bytes for a NULL row before decoding the next row" do
    part_path = nullable_string_copy
    begin
      # Row 1 becomes present-empty and its original byte becomes the hidden
      # nested slot under row 2's NULL. Row 3 must still decode as Q.
      sizes = nullable_string_sizes([0_u64, 1_u64, 1_u64, 0_u64, 3_u64, 1_u64, 0_u64, 3_u64])
      write_nullable_string_stream(part_path, "payload.size", sizes, [0_u64, 16_u64, 32_u64, 48_u64])
      rewrite_nullable_string_checksums(part_path)
      CrystalClick::WidePart.open_typed(part_path, "payload").read_nullable_string_mark_range("payload", 0, 2).should eq(["", nil, "Q", ""] of String?)
    ensure
      FileUtils.rm_rf(part_path)
    end
  end

  it "rejects a Nullable(String) size stream with different per-mark row counts" do
    part_path = nullable_string_copy
    begin
      write_nullable_string_stream(
        part_path,
        "payload.size",
        nullable_string_sizes([1_u64, 0_u64, 1_u64, 0_u64, 3_u64, 1_u64, 0_u64, 3_u64]),
        [0_u64, 24_u64, 32_u64, 48_u64],
        [3_u64, 1_u64, 2_u64, 2_u64]
      )
      rewrite_nullable_string_checksums(part_path)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(part_path, "payload")
      end
    ensure
      FileUtils.rm_rf(part_path)
    end
  end

  it "bounds one Nullable(String) size range before reading its nested bytes" do
    part_path = nullable_string_copy
    begin
      sizes = nullable_string_sizes([64_u64 * 1024 * 1024 + 1, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
      write_nullable_string_stream(part_path, "payload.size", sizes, [0_u64, 16_u64, 32_u64, 48_u64])
      rewrite_nullable_string_checksums(part_path)
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(part_path, "payload").nullable_string_mark_range_raw_bytes("payload", 0, 1)
      end
      (error.message || "").should contain("String read range exceeds materialization limit")
    ensure
      FileUtils.rm_rf(part_path)
    end
  end

  it "scans mixed typed columns through OfflineCatalog and enforces exact accessors" do
    with_nullable_string_table do |root, _part_path|
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      observed = [] of {UInt64, String?}
      table.scan_typed(["seq", "payload"], batch_rows: 1) do |batch|
        observed << {batch.values_for("seq", UInt64)[0], batch.nullable_strings_for("payload")[0]}
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.strings_for("payload") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_strings_for("seq") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_values_for("payload", UInt64) }
      end
      observed.should eq((1_u64..8_u64).map { |seq| {seq, NULLABLE_STRING_ORACLE[seq.to_i - 1]} })
    end
  end

  it "rejects malformed null maps, nested lengths, serialization versions, and checksums" do
    with_fixture_copy = nullable_string_copy
    begin
      write_nullable_string_stream(with_fixture_copy, "payload.null", Bytes[2, 0, 1, 0, 0, 0, 1, 0], [0_u64, 2_u64, 4_u64, 6_u64])
      rewrite_nullable_string_checksums(with_fixture_copy)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(with_fixture_copy, "payload").read_nullable_string_mark_range("payload", 0, 1)
      end
    ensure
      FileUtils.rm_rf(with_fixture_copy)
    end

    with_fixture_copy = nullable_string_copy
    begin
      lengths = nullable_string_sizes([1_u64, 0_u64, 50_u64, 0_u64, 3_u64, 1_u64, 0_u64, 3_u64])
      write_nullable_string_stream(with_fixture_copy, "payload.size", lengths, [0_u64, 16_u64, 32_u64, 48_u64])
      rewrite_nullable_string_checksums(with_fixture_copy)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(with_fixture_copy, "payload").read_nullable_string_mark_range("payload", 0, 2)
      end
    ensure
      FileUtils.rm_rf(with_fixture_copy)
    end

    with_fixture_copy = nullable_string_copy
    begin
      serialization = File.read(File.join(with_fixture_copy, "serialization.json"))
      File.write(File.join(with_fixture_copy, "serialization.json"), serialization.sub("\"string\":1", "\"nullable\":1,\"string\":1"))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(with_fixture_copy, "payload")
      end
    ensure
      FileUtils.rm_rf(with_fixture_copy)
    end

    with_fixture_copy = nullable_string_copy
    begin
      serialization = File.read(File.join(with_fixture_copy, "serialization.json"))
      File.write(File.join(with_fixture_copy, "serialization.json"), serialization.sub("\"string\":1", "\"string\":0"))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(with_fixture_copy, "payload")
      end
    ensure
      FileUtils.rm_rf(with_fixture_copy)
    end

    checksum_root = File.tempname("crystal-click-nullable-string-checksum-spec")
    FileUtils.mkdir_p(checksum_root)
    with_fixture_copy = File.join(checksum_root, "all_1_1_0")
    FileUtils.cp_r(NULLABLE_STRING_FIXTURE, with_fixture_copy)
    begin
      size_path = nullable_string_stream_path(with_fixture_copy, "payload.size", "bin")
      rewrite_nullable_string_checksums(with_fixture_copy, wrong_size: File.basename(size_path))
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.open_selected_typed([with_fixture_copy], ["payload"])
      end
    ensure
      FileUtils.rm_rf(checksum_root)
    end
  end

  it "does not call back when a selected physical stream is missing or the DDL type differs" do
    with_nullable_string_table do |root, part_path|
      callbacks = 0
      FileUtils.rm(nullable_string_stream_path(part_path, "payload.size", "bin"))
      FileUtils.rm(nullable_string_stream_path(part_path, "payload.size", "mrk2"))
      expect_raises(CrystalClick::InvalidPartError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_typed(["payload"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end

    with_nullable_string_table("String") do |root, _part_path|
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_typed(["payload"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end

  it "includes Nullable(String) raw bytes in the shared 64 MiB mark cap" do
    root = File.tempname("crystal-click-nullable-string-cap-spec")
    FileUtils.mkdir_p(root)
    part_path = File.join(root, "all_1_1_0")
    FileUtils.cp_r(NULLABLE_STRING_FIXTURE, part_path)
    begin
      cloned_streams = [] of {String, String}
      ["payload.null", "payload.size", "payload"].each do |stream_name|
        ["bin", "mrk2"].each do |extension|
          source = nullable_string_stream_path(part_path, stream_name, extension)
          clone_name = stream_name.sub("payload", "payload_copy")
          target = nullable_string_stream_path(part_path, clone_name, extension)
          FileUtils.cp(source, target)
          cloned_streams << {File.basename(source), File.basename(target)}
        end
      end
      columns_path = File.join(part_path, "columns.txt")
      File.write(columns_path, File.read(columns_path).sub("2 columns:\n", "3 columns:\n").sub("`payload` Nullable(String)\n", "`payload` Nullable(String)\n`payload_copy` Nullable(String)\n"))
      substreams_path = File.join(part_path, "columns_substreams.txt")
      File.write(
        substreams_path,
        File.read(substreams_path).sub("2 columns:\n", "3 columns:\n").sub(
          "3 substreams for column `payload`:\n\tpayload.null\n\tpayload.size\n\tpayload\n",
          "3 substreams for column `payload`:\n\tpayload.null\n\tpayload.size\n\tpayload\n" +
          "3 substreams for column `payload_copy`:\n\tpayload_copy.null\n\tpayload_copy.size\n\tpayload_copy\n"
        )
      )
      inflated_sizes = nullable_string_sizes([40_u64 * 1024 * 1024, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
      ["payload.size", "payload_copy.size"].each do |stream_name|
        write_nullable_string_stream(part_path, stream_name, inflated_sizes, [0_u64, 16_u64, 32_u64, 48_u64])
      end
      rewrite_nullable_string_checksums(part_path, cloned_streams)

      callbacks = 0
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload", "payload_copy"])
      expect_raises(CrystalClick::CorruptPartError, /aggregate materialization limit/) do
        table.scan_typed(batch_rows: 1) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
