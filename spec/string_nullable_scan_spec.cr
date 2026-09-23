require "./spec_helper"

STRING_NULLABLE_FIXTURE    = File.expand_path("../test/fixtures/public/wide_string_nullable/part", __DIR__)
STRING_NULLABLE_DB_UUID    = "b19d07fa-a32e-45d3-b9ea-bf1cf2b6b519"
STRING_NULLABLE_TABLE_UUID = "aca343cd-33bd-435c-a584-c596fb73a347"

def with_string_nullable_table(ddl_columns : String = string_nullable_columns, &)
  root = File.tempname("crystal-click-string-nullable-catalog-spec")
  metadata_root = File.join(root, "metadata")
  database_path = File.join(root, "store", STRING_NULLABLE_DB_UUID[0, 3], STRING_NULLABLE_DB_UUID)
  table_path = File.join(root, "store", STRING_NULLABLE_TABLE_UUID[0, 3], STRING_NULLABLE_TABLE_UUID)
  FileUtils.mkdir_p(metadata_root)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  begin
    File.write(File.join(metadata_root, "lab.sql"), "ATTACH DATABASE _ UUID '#{STRING_NULLABLE_DB_UUID}'\nENGINE = Atomic\n")
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{STRING_NULLABLE_TABLE_UUID}'\n(\n#{ddl_columns}\n)\nENGINE = MergeTree\nORDER BY tuple()\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(STRING_NULLABLE_FIXTURE, File.join(table_path, "all_1_1_0"))
    yield root, File.join(table_path, "all_1_1_0"), table_path
  ensure
    FileUtils.rm_rf(root)
  end
end

def string_nullable_columns : String
  "    `label` String,\n" +
    "    `maybe_u64` Nullable(UInt64),\n" +
    "    `maybe_i16` Nullable(Int16),\n" +
    "    `maybe_f32` Nullable(Float32)"
end

def string_nullable_stream_path(part_path : String, name : String, extension : String) : String
  File.join(part_path, "#{CrystalClick::StreamName.hash(name)}.#{extension}")
end

def literal_lz4_frame(raw : Bytes) : Bytes
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

def rewrite_lz4_stream(part_path : String, name : String, raw : Bytes)
  stream = string_nullable_stream_path(part_path, name, "bin")
  File.write(stream, literal_lz4_frame(raw))
end

def string_sizes(values : Array(UInt64)) : Bytes
  bytes = Bytes.new(values.size * 8, 0_u8)
  values.each_with_index do |value, index|
    8.times { |offset| bytes[index * 8 + offset] = ((value >> (offset * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

def test_write_var_uint(io : IO, value : UInt64) : Nil
  while value >= 0x80_u64
    io.write_byte(((value & 0x7f_u64) | 0x80_u64).to_u8)
    value >>= 7
  end
  io.write_byte(value.to_u8)
end

# Rebuild size-only checksum metadata for a deliberately synthetic corruption
# probe. Production never writes or trusts these opaque hash fields.
def rewrite_test_checksum_sizes(part_path : String, cloned_streams : Array({String, String})) : Nil
  entries = CrystalClick::PartChecksums.open(part_path).entries.dup
  cloned_streams.each do |source_name, new_name|
    source = entries[source_name]? || raise "missing source checksum entry"
    entries[new_name] = source
  end

  payload = IO::Memory.new
  test_write_var_uint(payload, entries.size.to_u64)
  entries.each do |name, entry|
    test_write_var_uint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    test_write_var_uint(payload, File.size(File.join(part_path, name)).to_u64)
    payload.write(Bytes.new(16, 0_u8))
    if entry.compressed
      payload.write_byte(1_u8)
      test_write_var_uint(payload, entry.uncompressed_size.not_nil!)
      payload.write(Bytes.new(16, 0_u8))
    else
      payload.write_byte(0_u8)
    end
  end

  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(literal_lz4_frame(payload.to_slice))
  File.write(File.join(part_path, "checksums.txt"), output.to_slice)
end

def rewrite_string_size_marks(part_path : String, frame_size : UInt64)
  marks = Bytes.new(4 * 24, 0_u8)
  records = [{0_u64, 0_u64, 2_u64}, {0_u64, 16_u64, 2_u64}, {0_u64, 32_u64, 1_u64}, {frame_size, 0_u64, 0_u64}]
  records.each_with_index do |record, row|
    [record[0], record[1], record[2]].each_with_index do |value, field|
      8.times { |byte| marks[row * 24 + field * 8 + byte] = (value >> (byte * 8)).to_u8 }
    end
  end
  File.write(string_nullable_stream_path(part_path, "label.size", "mrk2"), marks)
end

describe "String and Nullable primitive Wide-part scans" do
  it "reads exact String bytes and Nullable numeric values from ClickHouse streams" do
    string_part = CrystalClick::WidePart.open_typed(STRING_NULLABLE_FIXTURE, "label")
    string_part.column_type.should eq("String")
    string_part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
    string_part.read_string_mark_range("label", 0, string_part.mark_count).map(&.to_slice.to_a).should eq([
      [] of UInt8,
      "alpha".to_slice.to_a,
      Bytes[0x61, 0x00, 0x62].to_a,
      "tail".to_slice.to_a,
      [] of UInt8,
    ])

    nullable_part = CrystalClick::WidePart.open_typed(STRING_NULLABLE_FIXTURE, "maybe_u64")
    nullable_part.column_type.should eq("Nullable(UInt64)")
    nullable_part.mark_row_counts.should eq(string_part.mark_row_counts)
    nullable_part.read_nullable_numeric_mark_range("maybe_u64", 0, nullable_part.mark_count, UInt64).should eq([
      0_u64, nil, UInt64::MAX, 7_u64, nil,
    ])

    int16_part = CrystalClick::WidePart.open_typed(STRING_NULLABLE_FIXTURE, "maybe_i16")
    int16_part.column_type.should eq("Nullable(Int16)")
    int16_part.mark_row_counts.should eq(string_part.mark_row_counts)
    int16_part.read_nullable_numeric_mark_range("maybe_i16", 0, int16_part.mark_count, Int16).should eq([
      Int16::MIN, nil, Int16::MAX, -1_i16, nil,
    ])

    float_part = CrystalClick::WidePart.open_typed(STRING_NULLABLE_FIXTURE, "maybe_f32")
    float_part.column_type.should eq("Nullable(Float32)")
    float_part.mark_row_counts.should eq(string_part.mark_row_counts)
    float_values = float_part.read_nullable_numeric_mark_range("maybe_f32", 0, float_part.mark_count, Float32)
    float_values[0].not_nil!.unsafe_as(UInt32).should eq(0x80000000_u32)
    float_values[1].should be_nil
    float_values[2].should eq(1.5_f32)
    float_values[3].should eq(-2.25_f32)
    float_values[4].should be_nil
  end

  it "exposes typed row-aligned table callbacks and preserves part offsets" do
    with_string_nullable_table do |root, _part_path, _table_path|
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      rows = [] of {UInt64, String, UInt64?}
      offsets = [] of {Int32, UInt64, UInt64, Int32}
      table.scan_typed(["label", "maybe_u64", "maybe_i16", "maybe_f32"], batch_rows: 1) do |batch|
        labels = batch.strings_for("label")
        numbers = batch.nullable_values_for("maybe_u64", UInt64)
        signed = batch.nullable_values_for("maybe_i16", Int16)
        floats = batch.nullable_values_for("maybe_f32", Float32)
        labels.size.should eq(numbers.size)
        labels.size.should eq(signed.size)
        labels.size.should eq(floats.size)
        labels.each_with_index { |label, index| rows << {batch.source_row_offset, label, numbers[index]} }
        offsets << {batch.mark_index, batch.mark_row_offset, batch.part_row_offset, batch.part_index}
      end
      rows.should eq([
        {0_u64, "", 0_u64},
        {1_u64, "alpha", nil},
        {2_u64, "a\0b", UInt64::MAX},
        {3_u64, "tail", 7_u64},
        {4_u64, "", nil},
      ])
      offsets.should eq([
        {0_i32, 0_u64, 0_u64, 0_i32},
        {0_i32, 1_u64, 1_u64, 0_i32},
        {1_i32, 0_u64, 2_u64, 0_i32},
        {1_i32, 1_u64, 3_u64, 0_i32},
        {2_i32, 0_u64, 4_u64, 0_i32},
      ])
    end
  end

  it "rejects String single-stream and other physical serialization shapes" do
    with_fixture_copy = File.tempname("crystal-click-string-shape-spec")
    FileUtils.cp_r(STRING_NULLABLE_FIXTURE, with_fixture_copy)
    begin
      substreams_path = File.join(with_fixture_copy, "columns_substreams.txt")
      text = File.read(substreams_path)
      File.write(substreams_path, text.sub("2 substreams for column `label`:\n\tlabel.size\n\tlabel\n", "1 substreams for column `label`:\n\tlabel\n"))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(with_fixture_copy, "label")
      end
    ensure
      FileUtils.rm_rf(with_fixture_copy)
    end
  end

  it "rejects String sizes that overrun the raw stream and a truncated raw stream" do
    with_fixture_copy = File.tempname("crystal-click-string-corruption-spec")
    FileUtils.cp_r(STRING_NULLABLE_FIXTURE, with_fixture_copy)
    begin
      sizes = string_sizes([0_u64, 100_u64, 3_u64, 4_u64, 0_u64])
      rewrite_lz4_stream(with_fixture_copy, "label.size", sizes)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(with_fixture_copy, "label").read_string_mark_range("label", 0, 3)
      end
    ensure
      FileUtils.rm_rf(with_fixture_copy)
    end

    with_fixture_copy = File.tempname("crystal-click-string-size-spec")
    FileUtils.cp_r(STRING_NULLABLE_FIXTURE, with_fixture_copy)
    begin
      rewrite_lz4_stream(with_fixture_copy, "label", "alpha".to_slice)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(with_fixture_copy, "label").read_string_mark_range("label", 0, 3)
      end
    ensure
      FileUtils.rm_rf(with_fixture_copy)
    end
  end

  it "bounds one variable-width String mark before materializing its raw bytes" do
    with_fixture_copy = File.tempname("crystal-click-string-mark-limit-spec")
    FileUtils.cp_r(STRING_NULLABLE_FIXTURE, with_fixture_copy)
    begin
      sizes = string_sizes([64_u64 * 1024 * 1024 + 1, 0_u64, 0_u64, 0_u64, 0_u64])
      frame = literal_lz4_frame(sizes)
      File.write(string_nullable_stream_path(with_fixture_copy, "label.size", "bin"), frame)
      rewrite_string_size_marks(with_fixture_copy, frame.size.to_u64)
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(with_fixture_copy, "label").read_string_mark_range("label", 0, 1)
      end
      (error.message || "").should contain("String read range exceeds materialization limit")
    ensure
      FileUtils.rm_rf(with_fixture_copy)
    end
  end

  it "rejects invalid null-map bytes and inconsistent substream mark rows" do
    with_fixture_copy = File.tempname("crystal-click-null-map-spec")
    FileUtils.cp_r(STRING_NULLABLE_FIXTURE, with_fixture_copy)
    begin
      rewrite_lz4_stream(with_fixture_copy, "maybe_u64.null", Bytes[2, 1, 0, 0, 1])
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(with_fixture_copy, "maybe_u64").read_nullable_numeric_mark_range("maybe_u64", 0, 1, UInt64)
      end
      (error.message || "").should contain("Nullable null-map byte is not boolean")
    ensure
      FileUtils.rm_rf(with_fixture_copy)
    end

    with_fixture_copy = File.tempname("crystal-click-null-marks-spec")
    FileUtils.cp_r(STRING_NULLABLE_FIXTURE, with_fixture_copy)
    begin
      mark = string_nullable_stream_path(with_fixture_copy, "maybe_u64.null", "mrk2")
      bytes = writable_file_bytes(mark)
      bytes[16] = 1_u8
      bytes[40] = 3_u8
      File.open(mark, "wb") { |io| io.write(bytes) }
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open_typed(with_fixture_copy, "maybe_u64") }
    ensure
      FileUtils.rm_rf(with_fixture_copy)
    end
  end

  it "checks all selected stream checksums before callbacks and materializes each mark first" do
    with_string_nullable_table do |root, part_path, _table_path|
      regular = string_nullable_stream_path(part_path, "label", "bin")
      File.open(regular, "ab") { |io| io.write(Bytes[0]) }
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_typed(["label", "maybe_u64"]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    end

    with_string_nullable_table do |root, part_path, _table_path|
      numeric = string_nullable_stream_path(part_path, "maybe_u64", "bin")
      mutate_fixture_file(part_path, File.basename(numeric)) { |bytes| bytes[16] = 0xff_u8 }
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_typed(["label", "maybe_u64"]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    end
  end

  it "requires exact DDL types and rejects overlapping selected parts before callbacks" do
    with_string_nullable_table("    `label` FixedString(5),\n    `maybe_u64` Nullable(UInt64),\n    `maybe_i16` Nullable(Int16),\n    `maybe_f32` Nullable(Float32)") do |root, _part_path, _table_path|
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_typed(["label"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end

    with_string_nullable_table do |root, _part_path, table_path|
      FileUtils.cp_r(STRING_NULLABLE_FIXTURE, File.join(table_path, "all_1_2_0"))
      callbacks = 0
      expect_raises(CrystalClick::InvalidPartError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_typed(["label"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end

  it "preserves source, part, and mark offsets across two non-overlapping parts" do
    root = File.tempname("crystal-click-string-two-parts-spec")
    FileUtils.mkdir_p(root)
    begin
      first = File.join(root, "all_1_1_0")
      second = File.join(root, "all_2_2_0")
      FileUtils.cp_r(STRING_NULLABLE_FIXTURE, first)
      FileUtils.cp_r(STRING_NULLABLE_FIXTURE, second)

      table = CrystalClick::WidePartTable.open_selected_typed([first, second], ["label", "maybe_u64"])
      table.part_count.should eq(2)
      table.total_row_count.should eq(10_u64)
      observed = [] of {Int32, UInt64, UInt64, Int32, UInt64, String, UInt64?}
      table.scan_typed(batch_rows: 1) do |batch|
        label = batch.strings_for("label")[0]
        value = batch.nullable_values_for("maybe_u64", UInt64)[0]
        observed << {batch.part_index, batch.source_row_offset, batch.part_row_offset, batch.mark_index, batch.mark_row_offset, label, value}
      end
      observed.size.should eq(10)
      expected_labels = ["", "alpha", "a\0b", "tail", ""]
      expected_values = [0_u64, nil, UInt64::MAX, 7_u64, nil]
      observed.each_with_index do |row, index|
        in_part = index % 5
        row[0].should eq((index // 5).to_i32)
        row[1].should eq(index.to_u64)
        row[2].should eq(in_part.to_u64)
        row[3].should eq((in_part // 2).to_i32)
        row[4].should eq((in_part % 2).to_u64)
        row[5].should eq(expected_labels[in_part])
        row[6].should eq(expected_values[in_part])
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects two individually bounded String columns whose combined mark exceeds the table cap" do
    root = File.tempname("crystal-click-string-aggregate-cap-spec")
    FileUtils.mkdir_p(root)
    part_path = File.join(root, "all_1_1_0")
    FileUtils.cp_r(STRING_NULLABLE_FIXTURE, part_path)
    begin
      cloned_streams = [] of {String, String}
      ["label.size", "label"].each do |stream_name|
        ["bin", "mrk2"].each do |extension|
          source = string_nullable_stream_path(part_path, stream_name, extension)
          clone_name = stream_name.sub("label", "label_copy")
          target = string_nullable_stream_path(part_path, clone_name, extension)
          FileUtils.cp(source, target)
          cloned_streams << {File.basename(source), File.basename(target)}
        end
      end
      columns_path = File.join(part_path, "columns.txt")
      File.write(columns_path, File.read(columns_path).sub("4 columns:\n`label` String\n", "5 columns:\n`label` String\n`label_copy` String\n"))
      substreams_path = File.join(part_path, "columns_substreams.txt")
      File.write(
        substreams_path,
        File.read(substreams_path).sub(
          "4 columns:\n2 substreams for column `label`:\n\tlabel.size\n\tlabel\n",
          "5 columns:\n2 substreams for column `label`:\n\tlabel.size\n\tlabel\n2 substreams for column `label_copy`:\n\tlabel_copy.size\n\tlabel_copy\n"
        )
      )
      # Each selected first mark is 40 MiB, below the 64 MiB per-reader cap;
      # the combined 80 MiB must fail in the table preflight before callback.
      inflated = string_sizes([0_u64, 40_u64 * 1024 * 1024, 0_u64, 0_u64, 0_u64])
      rewrite_lz4_stream(part_path, "label.size", inflated)
      rewrite_lz4_stream(part_path, "label_copy.size", inflated)
      rewrite_test_checksum_sizes(part_path, cloned_streams)

      callbacks = 0
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["label", "label_copy"])
      expect_raises(CrystalClick::CorruptPartError, /aggregate materialization limit/) do
        table.scan_typed(batch_rows: 1) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
