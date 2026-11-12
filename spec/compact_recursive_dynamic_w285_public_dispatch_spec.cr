require "./spec_helper"
require "./support/compact_recursive_dynamic_w284_fixture"

W285_DATABASE_UUID         = "f2850000-7b7f-4e2f-9e44-dc13a87b8801"
W285_TABLE_UUID            = "f2850000-7b7f-4e2f-9e44-dc13a87b8802"
W285_GUARD_TABLE_UUID      = "f2850000-7b7f-4e2f-9e44-dc13a87b8803"
W285_OPAQUE_DYNAMIC_SCHEMA = "Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), samples Array(Dynamic(max_types=1)))"

private def w285_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

# Literal witness, independent of the W284 fixture's writer-side input rows.
# Each example invokes this helper afresh and compares the API result to it.
private def w285_expected_rows : Array(CrystalClick::StorageColumnValue)
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  tuple = ->(tag : UInt8, sample : CrystalClick::BinaryValue) do
    CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.object_document(
        CrystalClick::ObjectDocument.new(
          {"t" => CrystalClick::BinaryValue.fixed(
            CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[tag]
          )} of String => CrystalClick::BinaryValue,
        ),
      ),
      CrystalClick::StorageColumnValue.bulk(sample),
    ] of CrystalClick::StorageColumnValue)
  end

  [
    CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
    CrystalClick::StorageColumnValue.array([
      tuple.call(14_u8, CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(1040_u64))),
    ] of CrystalClick::StorageColumnValue),
    CrystalClick::StorageColumnValue.array([
      tuple.call(15_u8, CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("child!"))),
      tuple.call(16_u8, CrystalClick::BinaryValue.dynamic(dynamic)),
    ] of CrystalClick::StorageColumnValue),
    CrystalClick::StorageColumnValue.array([
      tuple.call(17_u8, CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(1060_u64))),
    ] of CrystalClick::StorageColumnValue),
  ] of CrystalClick::StorageColumnValue
end

private def w285_assert_rows(actual : Array(CrystalClick::StorageColumnValue)) : Nil
  expected = w285_expected_rows
  actual.size.should eq(expected.size)
  actual.each_with_index do |value, index|
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, false)
    CrystalClick::CompactPartValueComparison.storage!(value, expected[index], budget)
  end
  nil
end

private def w285_create_catalog_part(root : String) : String
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))

  database_store = w285_store_path(root, W285_DATABASE_UUID)
  FileUtils.mkdir_p(database_store)
  File.write(
    File.join(root, "metadata", "lab.sql"),
    "ATTACH DATABASE _ UUID '#{W285_DATABASE_UUID}'\nENGINE = Atomic\n"
  )

  table_store = w285_store_path(root, W285_TABLE_UUID)
  FileUtils.mkdir_p(table_store)
  File.write(
    File.join(database_store, "events.sql"),
    <<-DDL
    ATTACH TABLE _ UUID '#{W285_TABLE_UUID}'
    (
      `pk` UInt64,
      `trace` #{CompactRecursiveDynamicW284Fixture::SCHEMA_DECLARATION}
    )
    ENGINE = MergeTree
    ORDER BY pk
    DDL
  )
  File.write(File.join(table_store, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_store, "detached"))

  part_path = File.join(table_store, "all_1_1_0")
  fixture = CompactRecursiveDynamicW284Fixture
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactRecursiveDynamicW284Fixture::KEY_NAME,
    fixture.keys,
    [fixture.column] of CrystalClick::CompactPartColumn,
    rows_per_mark: CompactRecursiveDynamicW284Fixture::ROWS_PER_MARK,
    frame_bytes: CompactRecursiveDynamicW284Fixture::FRAME_BYTES,
    mark_format: CrystalClick::CompactMarkFormat::Mrk3,
    variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Compact,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
  ).should eq(part_path)
  part_path
end

private def w285_create_empty_guard_table(root : String) : Nil
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))

  database_store = w285_store_path(root, W285_DATABASE_UUID)
  FileUtils.mkdir_p(database_store)
  File.write(
    File.join(root, "metadata", "lab.sql"),
    "ATTACH DATABASE _ UUID '#{W285_DATABASE_UUID}'\nENGINE = Atomic\n"
  )

  table_store = w285_store_path(root, W285_GUARD_TABLE_UUID)
  FileUtils.mkdir_p(table_store)
  File.write(
    File.join(database_store, "opaque.sql"),
    <<-DDL
    ATTACH TABLE _ UUID '#{W285_GUARD_TABLE_UUID}'
    (
      `opaque` #{W285_OPAQUE_DYNAMIC_SCHEMA}
    )
    ENGINE = MergeTree
    ORDER BY tuple()
    DDL
  )
  File.write(File.join(table_store, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_store, "detached"))
  nil
end

describe "W285 W284 recursive Dynamic public dispatch probe" do
  it "keeps the direct recursive reader as a physical-byte control" do
    root = File.tempname("crystal-click-w285-direct-")
    FileUtils.mkdir_p(root)
    begin
      part_path = w285_create_catalog_part(root)
      fixture = CompactRecursiveDynamicW284Fixture
      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path, CompactRecursiveDynamicW284Fixture::COLUMN_NAME, fixture.schema
      )
      reader.row_count.should eq(w285_expected_rows.size.to_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64])
      w285_assert_rows(reader.read_marks(0, reader.mark_count).flatten)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "routes a scalar key and the exact W284 declaration through the public typed scan" do
    root = File.tempname("crystal-click-w285-typed-")
    FileUtils.mkdir_p(root)
    begin
      part_path = w285_create_catalog_part(root)
      expected_keys = [103_u64, 104_u64, 105_u64, 106_u64]

      typed = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk", "trace"])
      typed.column_types.should eq([
        {"pk", "UInt64"},
        {"trace", CompactRecursiveDynamicW284Fixture::SCHEMA_DECLARATION},
      ])
      typed.part_mark_row_counts.should eq([[2_u64, 2_u64]])
      scanned_keys = [] of UInt64
      scanned_rows = [] of CrystalClick::StorageColumnValue
      typed.scan_typed(batch_rows: CompactRecursiveDynamicW284Fixture::ROWS_PER_MARK) do |batch|
        batch.row_count.should eq(batch.recursive_values_for("trace").size.to_u64)
        batch.source_row_offset.should eq(scanned_rows.size.to_u64)
        batch.mark_row_offset.should eq(0_u64)
        keys = batch.values_for("pk")
        rows = batch.recursive_values_for("trace")
        keys.size.should eq(rows.size)
        scanned_keys.concat(keys)
        scanned_rows.concat(rows)
      end
      scanned_keys.should eq(expected_keys)
      w285_assert_rows(scanned_rows)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects a late-frame checksum error before publishing a partial typed window or values" do
    root = File.tempname("crystal-click-w285-late-frame-corruption-")
    FileUtils.mkdir_p(root)
    begin
      part_path = w285_create_catalog_part(root)
      data_path = File.join(part_path, "data.bin")
      original_data = File.read(data_path).to_slice.dup

      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      physical.granule_count.should eq(2)
      early_shard = physical.read_window("trace", 0, 1).granules.first.shards.first
      late_shard = physical.read_window("trace", 1, 1).granules.first.shards.first
      early_bytes = early_shard.bytes
      early_interval = {early_shard.logical_start, early_shard.logical_end}
      late_interval = {late_shard.logical_start, late_shard.logical_end}

      (early_interval[1] <= late_interval[0] || late_interval[1] <= early_interval[0]).should be_true

      frame_index = CrystalClick::CompressedFrameIndex.new(
        original_data,
        CrystalClick::CompressedStreamLimits.new,
        CrystalClick::CompressedStreamBudget.read_default,
      )
      late_frame = frame_index.frames.find do |frame|
        frame.logical_start >= late_interval[0] && frame.logical_end <= late_interval[1]
      end || raise(CrystalClick::CorruptPartError.new("W285 fixture has no complete frame inside the late mark"))
      (late_frame.logical_start >= late_interval[0]).should be_true
      (late_frame.logical_end <= late_interval[1]).should be_true
      (late_frame.logical_end <= early_interval[0] || late_frame.logical_start >= early_interval[1]).should be_true

      payload_byte = late_frame.compressed_offset.to_i + CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
      payload_byte.should be < original_data.size
      original_size = original_data.size
      original_data[payload_byte] = original_data[payload_byte] ^ 0x01_u8
      File.write(data_path, original_data)
      File.size(data_path).should eq(original_size.to_i64)

      after_corruption = CrystalClick::CompactPartPhysicalContext.open(part_path)
      after_early = after_corruption.read_window("trace", 0, 1).granules.first.shards.first
      after_early.bytes.should eq(early_bytes)

      typed = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk", "trace"])
      callbacks = 0
      typed_error = expect_raises(CrystalClick::CorruptPartError) do
        typed.scan_typed_window(0_u64, max_rows: 1) do |_batch|
          callbacks += 1
          nil
        end
      end
      typed_error.message.should eq("compressed frame checksum mismatch")
      callbacks.should eq(0)

      selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["trace"]
      values_error = expect_raises(CrystalClick::CorruptPartError) { selection.values }
      values_error.message.should eq("compressed frame checksum mismatch")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "routes exact-DDL OfflineCatalog values and enforces Dynamic-leaf budgets" do
    root = File.tempname("crystal-click-w285-values-")
    FileUtils.mkdir_p(root)
    begin
      fixture = CompactRecursiveDynamicW284Fixture
      w285_create_catalog_part(root)
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"trace", CompactRecursiveDynamicW284Fixture::SCHEMA_DECLARATION},
      ])
      selection = table["trace"]
      values = selection.values(
        max_rows: CompactRecursiveDynamicW284Fixture::ROW_COUNT.to_u64,
        max_string_bytes: 32_u64,
        max_tuple_cells: 64_u64,
      )
      w285_assert_rows(values.map(&.as(CrystalClick::StorageColumnValue)))

      # The six-byte "child!" String is only inside a Dynamic actual; the
      # structural Tuple has eight cells, while three non-NULL Dynamic wrappers
      # add three BinaryValue child cells. Thus 5 bytes and 10 cells are each
      # just-under guards that reach the retained Dynamic leaf accounting.
      string_error = expect_raises(CrystalClick::BoundsError) do
        selection.values(max_string_bytes: 5_u64)
      end
      string_error.message.should eq("Object String payload limit exceeded")
      tuple_error = expect_raises(CrystalClick::BoundsError) do
        selection.values(max_tuple_cells: 10_u64)
      end
      tuple_error.message.should eq("Object Tuple cell limit exceeded")
      row_error = expect_raises(CrystalClick::BoundsError) do
        selection.values(max_rows: 3_u64)
      end
      row_error.message.should eq("selected column materialization exceeds row limit")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps an opaque Dynamic-bearing JSON product outside .values admission on an empty table" do
    root = File.tempname("crystal-click-w285-opaque-guard-")
    FileUtils.mkdir_p(root)
    begin
      w285_create_empty_guard_table(root)
      declaration = W285_OPAQUE_DYNAMIC_SCHEMA
      schema = CrystalClick::StorageColumnSchema.parse(declaration)
      schema.declaration.should eq(declaration)
      CrystalClick::CompactRecursiveJsonColumnReader.admitted_schema?(schema).should be_false
      CrystalClick::CompactJsonColumnAdapter.schema_for_json_declaration(declaration).should be_nil

      selection = CrystalClick::OfflineCatalog.open(root)["lab"]["opaque"]["opaque"]
      error = expect_raises(CrystalClick::UnsupportedFormatError) { selection.values }
      error.message.should eq("selected table column type is unsupported")
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
