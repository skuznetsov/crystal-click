require "./spec_helper"

JSON_TYPED_PATH_FIXTURE    = File.expand_path("../test/fixtures/public/wide_json_typed_path/part", __DIR__)
JSON_TYPED_PATH_DB_UUID    = "38e7b26c-a420-4e8c-9369-74bb28e6a191"
JSON_TYPED_PATH_TABLE_UUID = "9afaa262-6c8f-49e4-b165-552356af5304"

def with_json_typed_path_table(ddl_columns : String = json_typed_path_columns, &)
  root = File.tempname("crystal-click-json-typed-path-catalog-spec")
  metadata_root = File.join(root, "metadata")
  database_path = File.join(root, "store", JSON_TYPED_PATH_DB_UUID[0, 3], JSON_TYPED_PATH_DB_UUID)
  table_path = File.join(root, "store", JSON_TYPED_PATH_TABLE_UUID[0, 3], JSON_TYPED_PATH_TABLE_UUID)
  FileUtils.mkdir_p(metadata_root)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  begin
    File.write(File.join(metadata_root, "lab.sql"), "ATTACH DATABASE _ UUID '#{JSON_TYPED_PATH_DB_UUID}'\nENGINE = Atomic\n")
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{JSON_TYPED_PATH_TABLE_UUID}'\n(\n#{ddl_columns}\n)\nENGINE = MergeTree\nORDER BY seq\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(JSON_TYPED_PATH_FIXTURE, File.join(table_path, "all_1_1_0"))
    yield root, File.join(table_path, "all_1_1_0"), table_path
  ensure
    FileUtils.rm_rf(root)
  end
end

def json_typed_path_columns : String
  "    `seq` UInt64,\n" +
    "    `j` JSON(a UInt64, b String)"
end

def json_typed_path_stream_path(part_path : String, name : String, extension : String) : String
  File.join(part_path, "#{CrystalClick::StreamName.hash(name)}.#{extension}")
end

def json_typed_path_literal_frame(raw : Bytes) : Bytes
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

def json_typed_path_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = (value >> (index * 8)).to_u8 }
end

describe "explicit JSON typed-path Wide-part scans" do
  it "projects declared UInt64 and String paths with independent stream marks" do
    with_json_typed_path_table do |root, part_path, _table_path|
      part = CrystalClick::WidePart.open_typed(part_path, "j.a")
      part.column_type.should eq("UInt64")
      part.mark_row_counts.should eq([2_u64, 1_u64])
      part.read_uint64_mark_range("j.a", 0, part.mark_count).should eq([10_u64, 0_u64, 30_u64])

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      observed = [] of {UInt64, UInt64, String, Int32, UInt64}
      table.scan_typed(["seq", "j.a", "j.b"], batch_rows: 1) do |batch|
        observed << {
          batch.values_for("seq", UInt64)[0],
          batch.values_for("j.a", UInt64)[0],
          batch.strings_for("j.b")[0],
          batch.mark_index,
          batch.mark_row_offset,
        }
      end
      observed.should eq([
        {0_u64, 10_u64, "x\0y", 0_i32, 0_u64},
        {1_u64, 0_u64, "", 0_i32, 1_u64},
        {2_u64, 30_u64, "", 1_i32, 0_u64},
      ])
      File.size(json_typed_path_stream_path(part_path, "j.b.size", "cmrk2")).should_not eq(
        File.size(json_typed_path_stream_path(part_path, "j.b", "cmrk2"))
      )
    end
  end

  it "rejects undeclared dynamic paths and JSON DDL/part type mismatches before callbacks" do
    with_json_typed_path_table do |root, _part_path, _table_path|
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_typed(["j.dynamic"]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    end

    with_json_typed_path_table("    `seq` UInt64,\n    `j` JSON(a String, b String)") do |root, _part_path, _table_path|
      callbacks = 0
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_typed(["j.a"]) do |_batch|
          callbacks += 1
        end
      end
      (error.message || "").should contain("table DDL and selected JSON schema differ")
      callbacks.should eq(0)
    end

    with_json_typed_path_table("    `seq` UInt64,\n    `j` JSON(a Array(UInt8), b String)") do |root, _part_path, _table_path|
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_typed(["j.a"]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    end
  end

  it "rejects ambiguity with a literal dotted column and validates selected stream checksum sizes before callbacks" do
    with_json_typed_path_table("    `seq` UInt64,\n    `j` JSON(a UInt64, b String),\n    `j.a` UInt64") do |root, _part_path, _table_path|
      callbacks = 0
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_typed(["j.a"]) do |_batch|
          callbacks += 1
        end
      end
      (error.message || "").should contain("ambiguous")
      callbacks.should eq(0)
    end

    with_json_typed_path_table do |root, part_path, _table_path|
      File.open(json_typed_path_stream_path(part_path, "j.b", "bin"), "ab") { |io| io.write(Bytes[0]) }
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_typed(["j.b"]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    end

    with_json_typed_path_table do |root, part_path, _table_path|
      File.delete(json_typed_path_stream_path(part_path, "j.b.size", "cmrk2"))
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_typed(["j.b"]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    end
  end

  it "gates the bounded Object V3 prefix without claiming full JSON validation" do
    with_json_typed_path_table do |root, part_path, _table_path|
      structure = json_typed_path_stream_path(part_path, "j.object_structure", "bin")
      raw = CrystalClick::CompressedBlock.decode_all(File.read(structure).to_slice).dup
      json_typed_path_write_u64(raw, 0, 3_u64)
      File.write(structure, json_typed_path_literal_frame(raw))

      callbacks = 0
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_typed(["j.a"]) do |_batch|
          callbacks += 1
        end
      end
      (error.message || "").should contain("Object structure version V3")
      callbacks.should eq(0)
    end
  end
end
