require "./spec_helper"

NULLABLE_TEMPORAL_DATABASE_UUID = "f060cdf1-5a96-4ad9-8f4a-6b211046c4c2"
NULLABLE_TEMPORAL_TABLE_UUID    = "26c59d53-7b75-4d77-af51-5662356d8c61"

private def nullable_temporal_stream_path(part_path : String, stream : String, extension : String) : String
  File.join(part_path, "#{CrystalClick::StreamName.hash(stream)}.#{extension}")
end

private def nullable_temporal_write_part(
  destination : String,
  semantic_type : String,
  physical_type : String,
  values : Array(T),
  rows_per_mark : Int32 = 2,
) : String forall T
  keys = Slice(UInt64).new(values.size) { |index| index.to_u64 }
  CrystalClick::WidePartWriter.write_uint64_typed_pair(
    destination,
    "pk",
    keys,
    "codes",
    values.to_unsafe.to_slice(values.size),
    rows_per_mark
  )

  columns_path = File.join(destination, "columns.txt")
  metadata = File.read(columns_path)
  primitive_declaration = "`codes` Nullable(#{physical_type})"
  raise "generated part did not contain expected nullable primitive declaration" unless metadata.includes?(primitive_declaration)
  File.write(columns_path, metadata.sub(primitive_declaration, "`codes` #{semantic_type}"))
  destination
end

private def nullable_temporal_create_catalog_table(root : String, semantic_type : String, physical_type : String, values : Array(T)) : CrystalClick::OfflineTable forall T
  metadata_path = File.join(root, "metadata")
  store_path = File.join(root, "store")
  Dir.mkdir(metadata_path)
  Dir.mkdir(store_path)

  database_path = File.join(store_path, NULLABLE_TEMPORAL_DATABASE_UUID[0, 3], NULLABLE_TEMPORAL_DATABASE_UUID)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(metadata_path, "lab.sql"),
    "ATTACH DATABASE _ UUID '#{NULLABLE_TEMPORAL_DATABASE_UUID}'\nENGINE = Atomic\n"
  )

  table_path = File.join(database_path, "events.sql")
  File.write(
    table_path,
    "ATTACH TABLE _ UUID '#{NULLABLE_TEMPORAL_TABLE_UUID}'\n" +
    "(\n    `pk` UInt64,\n    `codes` #{semantic_type}\n)\n" +
    "ENGINE = MergeTree\nORDER BY `pk`\n"
  )

  physical_table_path = File.join(store_path, NULLABLE_TEMPORAL_TABLE_UUID[0, 3], NULLABLE_TEMPORAL_TABLE_UUID)
  FileUtils.mkdir_p(physical_table_path)
  File.write(File.join(physical_table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(physical_table_path, "detached"))
  nullable_temporal_write_part(File.join(physical_table_path, "all_1_1_0"), semantic_type, physical_type, values)

  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end

private def with_nullable_temporal_catalog(semantic_type : String, physical_type : String, values : Array(T), &) forall T
  root = File.tempname("crystal-click-nullable-temporal-catalog-spec")
  Dir.mkdir(root)
  begin
    yield nullable_temporal_create_catalog_table(root, semantic_type, physical_type, values)
  ensure
    FileUtils.rm_rf(root)
  end
end

private def nullable_temporal_lz4_frame(raw : Bytes) : Bytes
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

private def nullable_temporal_read_u64(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def nullable_temporal_write_u64(bytes : Bytes, offset : Int32, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def nullable_temporal_replace_first_frame(part_path : String, stream : String, raw : Bytes) : Nil
  marks_path = nullable_temporal_stream_path(part_path, stream, "mrk2")
  marks = File.read(marks_path).to_slice
  frame_end = nullable_temporal_read_u64(marks, CrystalClick::WidePart::MARK_SIZE)
  frame = nullable_temporal_lz4_frame(raw)
  raise "replacement frame size differs from first mark range" unless frame.size.to_u64 == frame_end

  data_path = nullable_temporal_stream_path(part_path, stream, "bin")
  data = File.read(data_path).to_slice.dup
  frame.copy_to(data)
  File.write(data_path, data)
end

private def nullable_temporal_shorten_first_frame_mark(part_path : String, stream : String) : Nil
  marks_path = nullable_temporal_stream_path(part_path, stream, "mrk2")
  marks = File.read(marks_path).to_slice.dup
  frame_end = nullable_temporal_read_u64(marks, CrystalClick::WidePart::MARK_SIZE)
  raise "first frame is too small for truncation probe" if frame_end <= 1
  nullable_temporal_write_u64(marks, CrystalClick::WidePart::MARK_SIZE, frame_end - 1)
  File.write(marks_path, marks)
end

describe CrystalClick::WidePart do
  it "admits only exact Nullable raw temporal types" do
    [
      "Nullable(Date)",
      "Nullable(Date32)",
      "Nullable(DateTime)",
      "Nullable(DateTime64(0))",
      "Nullable(DateTime64(3))",
      "Nullable(DateTime64(9))",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end

    [
      "Nullable(DateTime64(03))",
      "Nullable(DateTime64(10))",
      "Nullable(DateTime64(-1))",
      "Nullable(DateTime64(3) )",
      "Nullable(Nullable(Date))",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
    CrystalClick::WidePart.supports_typed_type?("Nullable(DateTime64(3, 'UTC'))").should be_true
    CrystalClick::WidePart.supports_typed_type?("Nullable(DateTime('UTC'))").should be_true

    ["Nullable(Date)", "Nullable(Date32)", "Nullable(DateTime)", "Nullable(DateTime64(3))"].each do |type|
      CrystalClick::WidePart.supports_nullable_numeric_type?(type).should be_false
    end

    [0, 3, 9].each do |precision|
      CrystalClick::WidePart.nullable_datetime64_scale("Nullable(DateTime64(#{precision}))").should eq(precision)
    end
    [
      "Nullable(DateTime64(03))",
      "Nullable(DateTime64(10))",
      "Nullable(DateTime64(-1))",
      "Nullable(DateTime64(3) )",
      "Nullable(Nullable(DateTime64(3)))",
      "DateTime64(3)",
    ].each do |type|
      CrystalClick::WidePart.nullable_datetime64_scale(type).should be_nil
    end
    CrystalClick::WidePart.nullable_datetime64_scale("Nullable(DateTime64(3, 'UTC'))").should eq(3)
  end

  it "reads Nullable(Date) raw optional day codes and rejects primitive aliases" do
    with_nullable_temporal_catalog("Nullable(Date)", "UInt16", [nil, 0_u16, UInt16::MAX, 1_u16, nil] of UInt16?) do |table|
      part_path = table.part_candidates.first.path
      part = CrystalClick::WidePart.open_typed(part_path, "codes")
      part.column_type.should eq("Nullable(Date)")
      part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      part.read_nullable_date_codes_mark_range("codes", 0, 3).should eq([nil, 0_u16, UInt16::MAX, 1_u16, nil])
      part.read_nullable_date_codes_mark_range("codes", 1, 2).should eq([UInt16::MAX, 1_u16, nil])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        part.read_nullable_numeric_mark_range("codes", 0, 1, UInt16)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        part.read_date_codes_mark_range("codes", 0, 1)
      end
    end
  end

  it "reads Nullable(Date32) with both Int32 extrema and preserves NULL versus zero" do
    with_nullable_temporal_catalog("Nullable(Date32)", "Int32", [Int32::MIN, nil, 0_i32, Int32::MAX, nil] of Int32?) do |table|
      part = CrystalClick::WidePart.open_typed(table.part_candidates.first.path, "codes")
      part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      part.read_nullable_date32_codes_mark_range("codes", 0, 3).should eq([Int32::MIN, nil, 0_i32, Int32::MAX, nil])
      part.read_nullable_date32_codes_mark_range("codes", 1, 2).should eq([0_i32, Int32::MAX, nil])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        part.read_nullable_numeric_mark_range("codes", 0, 1, Int32)
      end
    end
  end

  it "reads Nullable(DateTime) raw optional UInt32 seconds without conversion" do
    with_nullable_temporal_catalog("Nullable(DateTime)", "UInt32", [nil, 0_u32, UInt32::MAX, 2_000_000_000_u32, nil] of UInt32?) do |table|
      part = CrystalClick::WidePart.open_typed(table.part_candidates.first.path, "codes")
      part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      part.read_nullable_datetime_seconds_mark_range("codes", 0, 3).should eq([nil, 0_u32, UInt32::MAX, 2_000_000_000_u32, nil])
      part.read_nullable_datetime_seconds_mark_range("codes", 1, 2).should eq([UInt32::MAX, 2_000_000_000_u32, nil])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        part.read_nullable_numeric_mark_range("codes", 0, 1, UInt32)
      end
    end
  end

  it "reads Nullable(DateTime64(p)) ticks while retaining each exact precision" do
    values = [nil, Int64::MIN, 0_i64, 1_i64, Int64::MAX] of Int64?
    [0, 3, 9].each do |precision|
      type = "Nullable(DateTime64(#{precision}))"
      with_nullable_temporal_catalog(type, "Int64", values) do |table|
        part = CrystalClick::WidePart.open_typed(table.part_candidates.first.path, "codes")
        part.column_type.should eq(type)
        part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
        part.read_nullable_datetime64_ticks_mark_range("codes", 0, 3).should eq(values)
        part.read_nullable_datetime64_ticks_mark_range("codes", 1, 2).should eq([0_i64, 1_i64, Int64::MAX])
        expect_raises(CrystalClick::UnsupportedFormatError) do
          part.read_nullable_numeric_mark_range("codes", 0, 1, Int64)
        end
      end
    end
  end
end

describe CrystalClick::WidePartTable do
  it "scans nullable temporal slices through semantic accessors and refuses numeric scans" do
    with_nullable_temporal_catalog("Nullable(Date)", "UInt16", [nil, 0_u16, UInt16::MAX, 1_u16, nil] of UInt16?) do |table|
      part_path = table.part_candidates.first.path
      reader = CrystalClick::WidePartTable.open_selected_typed([part_path], ["codes"])
      reader.column_types.should eq([{"codes", "Nullable(Date)"}])
      observed = [] of UInt16?
      reader.scan_typed(batch_rows: 1) do |batch|
        observed.concat(batch.nullable_date_codes_for("codes").to_a)
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_values_for("codes", UInt16) }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.date_codes_for("codes") }
      end
      observed.should eq([nil, 0_u16, UInt16::MAX, 1_u16, nil])

      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.scan_numeric { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end

    with_nullable_temporal_catalog("Nullable(Date32)", "Int32", [Int32::MIN, nil, 0_i32, Int32::MAX, nil] of Int32?) do |table|
      reader = CrystalClick::WidePartTable.open_selected_typed([table.part_candidates.first.path], ["codes"])
      observed = [] of Int32?
      reader.scan_typed(batch_rows: 2) do |batch|
        observed.concat(batch.nullable_date32_codes_for("codes").to_a)
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_values_for("codes", Int32) }
      end
      observed.should eq([Int32::MIN, nil, 0_i32, Int32::MAX, nil])
    end

    with_nullable_temporal_catalog("Nullable(DateTime)", "UInt32", [nil, 0_u32, UInt32::MAX, 1_u32, nil] of UInt32?) do |table|
      reader = CrystalClick::WidePartTable.open_selected_typed([table.part_candidates.first.path], ["codes"])
      observed = [] of UInt32?
      reader.scan_typed(batch_rows: 2) do |batch|
        observed.concat(batch.nullable_datetime_seconds_for("codes").to_a)
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_values_for("codes", UInt32) }
      end
      observed.should eq([nil, 0_u32, UInt32::MAX, 1_u32, nil])
    end

    with_nullable_temporal_catalog("Nullable(DateTime64(3))", "Int64", [nil, Int64::MIN, 0_i64, 1_i64, Int64::MAX] of Int64?) do |table|
      reader = CrystalClick::WidePartTable.open_selected_typed([table.part_candidates.first.path], ["codes"])
      observed = [] of Int64?
      reader.scan_typed(batch_rows: 2) do |batch|
        observed.concat(batch.nullable_datetime64_ticks_for("codes").to_a)
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_values_for("codes", Int64) }
      end
      observed.should eq([nil, Int64::MIN, 0_i64, 1_i64, Int64::MAX])
    end
  end
end

describe CrystalClick::OfflineCatalog do
  it "materializes nullable temporal raw codes as optional primitive values" do
    with_nullable_temporal_catalog("Nullable(Date)", "UInt16", [nil, 0_u16, UInt16::MAX, 1_u16, nil] of UInt16?) do |table|
      table.columns.find { |column| column.name == "codes" }.not_nil!.type.should eq("Nullable(Date)")
      observed = table.materialize_selected_values("codes")
      observed.map { |value| value.nil? ? nil : value.as(UInt16) }.should eq([nil, 0_u16, UInt16::MAX, 1_u16, nil])
    end

    with_nullable_temporal_catalog("Nullable(Date32)", "Int32", [Int32::MIN, nil, 0_i32, Int32::MAX, nil] of Int32?) do |table|
      table.columns.find { |column| column.name == "codes" }.not_nil!.type.should eq("Nullable(Date32)")
      observed = table.materialize_selected_values("codes")
      observed.map { |value| value.nil? ? nil : value.as(Int32) }.should eq([Int32::MIN, nil, 0_i32, Int32::MAX, nil])
    end

    with_nullable_temporal_catalog("Nullable(DateTime)", "UInt32", [nil, 0_u32, UInt32::MAX, 1_u32, nil] of UInt32?) do |table|
      table.columns.find { |column| column.name == "codes" }.not_nil!.type.should eq("Nullable(DateTime)")
      observed = table.materialize_selected_values("codes")
      observed.map { |value| value.nil? ? nil : value.as(UInt32) }.should eq([nil, 0_u32, UInt32::MAX, 1_u32, nil])
    end

    with_nullable_temporal_catalog("Nullable(DateTime64(9))", "Int64", [nil, Int64::MIN, 0_i64, 1_i64, Int64::MAX] of Int64?) do |table|
      table.columns.find { |column| column.name == "codes" }.not_nil!.type.should eq("Nullable(DateTime64(9))")
      observed = table.materialize_selected_values("codes")
      observed.map { |value| value.nil? ? nil : value.as(Int64) }.should eq([nil, Int64::MIN, 0_i64, 1_i64, Int64::MAX])
    end
  end
end

describe "Nullable temporal corruption checks" do
  it "rejects missing or unsupported temporal serialization versions" do
    [
      {"missing", nil},
      {"zero", JSON::Any.new(0_i64)},
      {"future", JSON::Any.new(999_i64)},
      {"malformed", JSON::Any.new("nonsense")},
    ].each do |_label, string_version|
      with_nullable_temporal_catalog("Nullable(Date)", "UInt16", [nil, 0_u16, 1_u16] of UInt16?) do |table|
        part_path = table.part_candidates.first.path
        serialization_path = File.join(part_path, "serialization.json")
        serialization = JSON.parse(File.read(serialization_path)).as_h
        versions = serialization["types_serialization_versions"].as_h
        if string_version
          versions["string"] = string_version
        else
          versions.delete("string")
        end
        File.write(serialization_path, serialization.to_json)

        expect_raises(CrystalClick::Error) do
          CrystalClick::WidePart.open_typed(part_path, "codes")
        end
      end
    end
  end

  it "rejects non-boolean null-map bytes and a truncated nested-value mark" do
    with_nullable_temporal_catalog("Nullable(Date)", "UInt16", [nil, 0_u16, UInt16::MAX, 1_u16, nil] of UInt16?) do |table|
      part_path = table.part_candidates.first.path
      nullable_temporal_replace_first_frame(part_path, "codes.null", Bytes[2_u8, 0_u8])
      part = CrystalClick::WidePart.open_typed(part_path, "codes")
      error = expect_raises(CrystalClick::CorruptPartError) do
        part.read_nullable_date_codes_mark_range("codes", 0, 1)
      end
      (error.message || "").should contain("Nullable null-map byte is not boolean")
    end

    with_nullable_temporal_catalog("Nullable(Date)", "UInt16", [nil, 0_u16, UInt16::MAX, 1_u16, nil] of UInt16?) do |table|
      part_path = table.part_candidates.first.path
      nullable_temporal_shorten_first_frame_mark(part_path, "codes")
      part = CrystalClick::WidePart.open_typed(part_path, "codes")
      expect_raises(CrystalClick::CorruptPartError) do
        part.read_nullable_date_codes_mark_range("codes", 0, 1)
      end
    end
  end
end
