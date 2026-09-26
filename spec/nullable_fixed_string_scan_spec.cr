require "./spec_helper"

NFS_SCAN_FIXTURE    = File.expand_path("../test/fixtures/public/wide_nullable_string/part", __DIR__)
NFS_SCAN_DB_UUID    = "2572b682-7c61-4e41-9cab-38904e46f22d"
NFS_SCAN_TABLE_UUID = "ae5e7f88-ae67-4623-8ca4-10044c0b4fea"

private def nfs_stream_path(part_path : String, stream : String, extension : String) : String
  File.join(part_path, "#{CrystalClick::StreamName.hash(stream)}.#{extension}")
end

private def nfs_lz4_frame(raw : Bytes) : Bytes
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

private def nfs_write_stream(part_path : String, stream : String, raw : Bytes, bytes_per_row : Int32) : Nil
  frame = nfs_lz4_frame(raw)
  File.write(nfs_stream_path(part_path, stream, "bin"), frame)
  marks = Bytes.new(5 * 24, 0_u8)
  5.times do |index|
    compressed_offset = index == 4 ? frame.size.to_u64 : 0_u64
    decompressed_offset = index == 4 ? 0_u64 : (index * 2 * bytes_per_row).to_u64
    rows = index == 4 ? 0_u64 : 2_u64
    [compressed_offset, decompressed_offset, rows].each_with_index do |value, field|
      8.times do |byte|
        marks[index * 24 + field * 8 + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8
      end
    end
  end
  File.write(nfs_stream_path(part_path, stream, "mrk2"), marks)
end

private def nfs_write_var_uint(io : IO, value : UInt64) : Nil
  while value >= 0x80_u64
    io.write_byte(((value & 0x7f_u64) | 0x80_u64).to_u8)
    value >>= 7
  end
  io.write_byte(value.to_u8)
end

private def nfs_rewrite_checksums(part_path : String, cloned_streams : Array({String, String}) = [] of {String, String}) : Nil
  entries = CrystalClick::PartChecksums.open(part_path).entries.dup
  ["bin", "mrk2"].each do |extension|
    entries.delete(File.basename(nfs_stream_path(part_path, "payload.size", extension)))
  end
  cloned_streams.each do |source, target|
    entries[target] = entries[source]? || raise "missing source checksum entry"
  end
  payload = IO::Memory.new
  nfs_write_var_uint(payload, entries.size.to_u64)
  entries.each do |name, entry|
    nfs_write_var_uint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    nfs_write_var_uint(payload, File.size(File.join(part_path, name)).to_u64)
    payload.write(Bytes.new(16, 0_u8))
    if entry.compressed
      payload.write_byte(1_u8)
      nfs_write_var_uint(payload, entry.uncompressed_size.not_nil!)
      payload.write(Bytes.new(16, 0_u8))
    else
      payload.write_byte(0_u8)
    end
  end
  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(nfs_lz4_frame(payload.to_slice))
  File.write(File.join(part_path, "checksums.txt"), output.to_slice)
end

private def nfs_expected : Array(String?)
  [
    "A\0\0", nil, String.new(Bytes[0xff_u8, 0_u8, 0x61_u8]), "\0\0\0",
    "ab\0", String.new(Bytes[0x80_u8, 0_u8, 0xff_u8]), nil, "Q\0R",
  ] of String?
end

private def nfs_prepare_part(part_path : String) : Nil
  columns = File.join(part_path, "columns.txt")
  File.write(columns, File.read(columns).sub("`payload` Nullable(String)", "`payload` Nullable(FixedString(3))"))
  substreams = File.join(part_path, "columns_substreams.txt")
  File.write(substreams, File.read(substreams).sub("3 substreams for column `payload`:\n\tpayload.null\n\tpayload.size\n\tpayload\n", "2 substreams for column `payload`:\n\tpayload.null\n\tpayload\n"))
  ["bin", "mrk2"].each { |extension| File.delete(nfs_stream_path(part_path, "payload.size", extension)) }

  nfs_write_stream(part_path, "payload.null", Bytes[0, 1, 0, 0, 0, 0, 1, 0], 1)
  nested = Bytes[
    0x41, 0, 0, 0x78, 0x79, 0x7a, 0xff, 0, 0x61, 0, 0, 0,
    0x61, 0x62, 0, 0x80, 0, 0xff, 0x31, 0x32, 0x33, 0x51, 0, 0x52,
  ]
  nfs_write_stream(part_path, "payload", nested, 3)
  nfs_rewrite_checksums(part_path)
end

private def with_nfs_table(ddl_type : String = "Nullable(FixedString(3))", &)
  root = File.tempname("crystal-click-nfs-scan-spec")
  metadata = File.join(root, "metadata")
  database = File.join(root, "store", NFS_SCAN_DB_UUID[0, 3], NFS_SCAN_DB_UUID)
  table = File.join(root, "store", NFS_SCAN_TABLE_UUID[0, 3], NFS_SCAN_TABLE_UUID)
  FileUtils.mkdir_p(metadata)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  begin
    File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{NFS_SCAN_DB_UUID}'\nENGINE = Atomic\n")
    File.write(File.join(database, "events.sql"), "ATTACH TABLE _ UUID '#{NFS_SCAN_TABLE_UUID}'\n(\n    `seq` UInt64,\n    `payload` #{ddl_type}\n)\nENGINE = MergeTree\nORDER BY seq\n")
    File.write(File.join(table, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table, "detached"))
    part_path = File.join(table, "all_1_1_0")
    FileUtils.cp_r(NFS_SCAN_FIXTURE, part_path)
    nfs_prepare_part(part_path)
    yield root, part_path
  ensure
    FileUtils.rm_rf(root)
  end
end

private def nfs_set_first_mark_rows(part_path : String, rows : UInt64) : Nil
  ["payload.null", "payload"].each do |stream|
    path = nfs_stream_path(part_path, stream, "mrk2")
    marks = File.read(path).to_slice.dup
    8.times { |byte| marks[16 + byte] = ((rows >> (8 * byte)) & 0xff_u64).to_u8 }
    File.write(path, marks)
  end
  File.write(File.join(part_path, "count.txt"), "#{rows + 6_u64}\n")
end

private def nfs_set_wide_first_mark(part_path : String, width : Int32, rows : UInt64, streams : Array(String)) : Nil
  columns = File.join(part_path, "columns.txt")
  File.write(columns, File.read(columns).gsub("Nullable(FixedString(3))", "Nullable(FixedString(#{width}))"))
  streams.each do |stream|
    ["#{stream}.null", stream].each do |substream|
      path = nfs_stream_path(part_path, substream, "mrk2")
      marks = File.read(path).to_slice.dup
      8.times { |byte| marks[16 + byte] = ((rows >> (8 * byte)) & 0xff_u64).to_u8 }
      if substream == stream
        1.upto(3) do |mark|
          8.times { |byte| marks[mark * 24 + 8 + byte] = 0_u8 }
        end
      end
      File.write(path, marks)
    end
  end
  File.write(File.join(part_path, "count.txt"), "#{rows + 6_u64}\n")
end

describe "Nullable(FixedString(N)) Wide-part scans" do
  it "admits only the canonical bounded exact type" do
    CrystalClick::WidePart.nullable_fixed_string_width("Nullable(FixedString(1))").should eq(1)
    CrystalClick::WidePart.nullable_fixed_string_width("Nullable(FixedString(65536))").should eq(65_536)
    CrystalClick::WidePart.supports_typed_type?("Nullable(FixedString(3))").should be_true
    ["Nullable(FixedString(0))", "Nullable(FixedString(03))", "Nullable(FixedString(65537))",
     "Nullable(FixedString(3)) ", "Nullable( Nullable(FixedString(3)))", "Nullable(String)"].each do |type|
      CrystalClick::WidePart.nullable_fixed_string_width(type).should be_nil
    end
  end

  it "reads two BASIC streams and consumes the hidden N-byte slots across marks" do
    with_nfs_table do |_root, part_path|
      part = CrystalClick::WidePart.open_typed(part_path, "payload")
      part.column_type.should eq("Nullable(FixedString(3))")
      part.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      part.selected_checksum_names.size.should eq(4)
      part.nullable_fixed_string_mark_range_raw_bytes("payload", 0, 4).should eq(24_u64)
      part.read_nullable_fixed_string_mark_range("payload", 0, 4).should eq(nfs_expected)
      part.read_nullable_fixed_string_mark_range("payload", 1, 2).should eq(nfs_expected[2, 4])
      expect_raises(CrystalClick::UnsupportedFormatError) { part.read_nullable_string_mark_range("payload", 0, 1) }
      expect_raises(CrystalClick::UnsupportedFormatError) { part.read_fixed_string_mark_range("payload", 0, 1) }
    end
  end

  it "scans windows and catalog values with an exact nullable-fixed accessor" do
    with_nfs_table do |root, part_path|
      reader = CrystalClick::WidePartTable.open_selected_typed([part_path], ["seq", "payload"])
      observed = [] of String?
      reader.scan_typed_window(1_u64, 5) do |batch|
        observed.concat(batch.nullable_fixed_strings_for("payload").to_a)
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_strings_for("payload") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.fixed_strings_for("payload") }
      end
      observed.should eq(nfs_expected[1, 5])

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      table["payload"].values(max_string_bytes: 18_u64).should eq(nfs_expected)
      expect_raises(CrystalClick::BoundsError) { table["payload"].values(max_string_bytes: 17_u64) }
    end
  end

  it "rejects cross-part width disagreement before invoking callbacks" do
    with_nfs_table do |root, first_part|
      second = File.join(File.dirname(first_part), "all_2_2_0")
      FileUtils.cp_r(first_part, second)
      columns = File.join(second, "columns.txt")
      File.write(columns, File.read(columns).sub("Nullable(FixedString(3))", "Nullable(FixedString(1))"))
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_typed(["payload"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end

  it "rejects an added size stream and unsupported String or Nullable versions" do
    with_nfs_table do |_root, part_path|
      substreams = File.join(part_path, "columns_substreams.txt")
      original = File.read(substreams)
      File.write(substreams, original.sub("2 substreams for column `payload`:\n\tpayload.null\n\tpayload\n", "3 substreams for column `payload`:\n\tpayload.null\n\tpayload.size\n\tpayload\n"))
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open_typed(part_path, "payload") }
      File.write(substreams, original)

      metadata = File.join(part_path, "serialization.json")
      original = File.read(metadata)
      [{"string", 999_i64}, {"nullable", 1_i64}].each do |key, version|
        parsed = JSON.parse(original)
        parsed["types_serialization_versions"].as_h[key] = JSON::Any.new(version)
        File.write(metadata, parsed.to_json)
        expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open_typed(part_path, "payload") }
      end
    end
  end

  it "accepts omitted per-type versions as the ClickHouse version-zero defaults" do
    with_nfs_table do |_root, part_path|
      metadata = File.join(part_path, "serialization.json")
      parsed = JSON.parse(File.read(metadata))
      parsed["types_serialization_versions"].as_h.clear
      File.write(metadata, parsed.to_json)

      part = CrystalClick::WidePart.open_typed(part_path, "payload")
      part.read_nullable_fixed_string_mark_range("payload", 0, part.mark_count).should eq(nfs_expected)

      parsed.as_h.delete("types_serialization_versions")
      File.write(metadata, parsed.to_json)
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open_typed(part_path, "payload") }
    end
  end

  it "rejects a non-boolean null flag and over-limit direct value count" do
    with_nfs_table do |_root, part_path|
      nfs_write_stream(part_path, "payload.null", Bytes[2, 1, 0, 0, 0, 0, 1, 0], 1)
      nfs_rewrite_checksums(part_path)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(part_path, "payload").read_nullable_fixed_string_mark_range("payload", 0, 1)
      end
    end
    with_nfs_table do |_root, part_path|
      nfs_set_first_mark_rows(part_path, 65_537_u64)
      part = CrystalClick::WidePart.open_typed(part_path, "payload")
      expect_raises(CrystalClick::CorruptPartError) { part.read_nullable_fixed_string_mark_range("payload", 0, 1) }
    end
  end

  it "rejects more than 64 MiB of nested bytes before reading the null map" do
    with_nfs_table do |_root, part_path|
      nfs_set_wide_first_mark(part_path, 65_536, 1_024_u64, ["payload"])
      part = CrystalClick::WidePart.open_typed(part_path, "payload")
      expect_raises(CrystalClick::CorruptPartError) do
        part.read_nullable_fixed_string_mark_range("payload", 0, 2)
      end
    end
  end

  it "preflights the aggregate two-column mark bytes including hidden NULL slots" do
    with_nfs_table do |_root, part_path|
      clones = [] of {String, String}
      ["payload.null", "payload"].each do |source_stream|
        target_stream = source_stream.sub("payload", "payload_copy")
        ["bin", "mrk2"].each do |extension|
          source = nfs_stream_path(part_path, source_stream, extension)
          target = nfs_stream_path(part_path, target_stream, extension)
          FileUtils.cp(source, target)
          clones << {File.basename(source), File.basename(target)}
        end
      end
      columns = File.join(part_path, "columns.txt")
      File.write(columns, File.read(columns).sub("2 columns:\n", "3 columns:\n") + "`payload_copy` Nullable(FixedString(3))\n")
      substreams = File.join(part_path, "columns_substreams.txt")
      File.write(substreams, File.read(substreams).sub("2 columns:\n", "3 columns:\n") + "2 substreams for column `payload_copy`:\n\tpayload_copy.null\n\tpayload_copy\n")
      nfs_rewrite_checksums(part_path, clones)
      nfs_set_wide_first_mark(part_path, 65_536, 1_024_u64, ["payload", "payload_copy"])

      reader = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload", "payload_copy"])
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        reader.scan_typed { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end
end
