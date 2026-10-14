require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w281_fixture"

private def w281_profile_cases : Array(Tuple(String, CrystalClick::CompactMarkFormat, CrystalClick::BinaryBulkProfile))
  [
    {"mrk3_s0", CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::BinaryBulkProfile.single_stream},
    {"mrk3_s1", CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::BinaryBulkProfile.with_size_stream},
    {"mrk4_s0", CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::BinaryBulkProfile.single_stream},
    {"mrk4_s1", CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::BinaryBulkProfile.with_size_stream},
  ] of Tuple(String, CrystalClick::CompactMarkFormat, CrystalClick::BinaryBulkProfile)
end

private def w281_write_and_read_fixture(stock : Bool) : Nil
  fixture = CompactPartWriterW281Fixture
  scope = stock ? "stock" : "local"
  column_name = if stock
                  CompactPartWriterW281Fixture::STOCK_COLUMN_NAME
                else
                  CompactPartWriterW281Fixture::COLUMN_NAME
                end
  schema = stock ? fixture.stock_schema : fixture.schema
  column = stock ? fixture.stock_column : fixture.column
  expected = stock ? fixture.expected_stock_signatures : fixture.expected_signatures

  w281_profile_cases.each do |case_name, mark_format, profile|
    parent = File.tempname("crystal-click-w281-#{scope}-#{case_name}-")
    part_path = File.join(parent, "all_1_1_0")
    Dir.mkdir(parent)
    begin
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW281Fixture::KEY_NAME,
        fixture.keys,
        [column] of CrystalClick::CompactPartColumn,
        rows_per_mark: CompactPartWriterW281Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW281Fixture::FRAME_BYTES,
        mark_format: mark_format,
        profile: profile,
      ).should eq(part_path)

      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(part_path, column_name, schema)
      reader.ordinary_profile.should eq(profile)
      reader.mark_count.should eq(CompactPartWriterW281Fixture::MARK_COUNT)
      reader.row_count.should eq(CompactPartWriterW281Fixture::ROW_COUNT.to_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])

      fixture.signatures_from(reader.read_marks(0, reader.mark_count)).should eq(expected)
      fixture.signatures_from(reader.read_marks(0, 1)).should eq(expected[0, 2])
      fixture.signatures_from(reader.read_marks(1, 2)).should eq(expected[2, 4])
      fixture.signatures_from(reader.read_marks(3, 1)).should eq(expected[6, 2])
      reader.read_marks(reader.mark_count, 0).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
  nil
end

private def w281_guard_schema(type : CrystalClick::BinaryDataType) : CrystalClick::StorageColumnSchema
  source = "JSON(id UInt64)"
  json_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(source)
  json_node = CrystalClick::StorageColumnSchema.object(json_schema, source)
  bulk_node = CrystalClick::StorageColumnSchema.bulk(type, type.name)
  CrystalClick::StorageColumnSchema.tuple(
    "Tuple(#{source}, #{type.name})",
    false,
    [] of String,
    [] of String,
    [json_node, bulk_node] of CrystalClick::StorageColumnSchema,
  )
end

describe "W281 generic recursive Compact JSON Bulk entry" do
  it "exposes all fixed-width families and the stock-candidate recursive fixture as one JSON-free Bulk" do
    fixture = CompactPartWriterW281Fixture
    fixture.fixed_leaf_types.each do |_name, type|
      type.fixed_width.should_not be_nil
    end

    fixture.schema.child_at(1).bulk?.should be_true
    fixture.schema.child_at(1).bulk_type.should eq(fixture.bulk_type)
    fixture.rows.each do |row|
      row.child_at(1).bulk?.should be_true
      row.child_at(1).bulk_value.type.should eq(fixture.bulk_type)
    end

    fixture.stock_schema.child_at(1).bulk?.should be_true
    fixture.stock_schema.child_at(1).bulk_type.should eq(fixture.stock_bulk_type)
    fixture.stock_rows.each do |row|
      row.child_at(1).bulk?.should be_true
      row.child_at(1).bulk_value.type.should eq(fixture.stock_bulk_type)
    end
  end

  it "admits broad static leaves and prefix-free recursive wrappers inside the generic JSON Bulk island" do
    fixture = CompactPartWriterW281Fixture
    CrystalClick::CompactRecursiveJsonColumnReader.admitted_schema?(fixture.schema).should be_true
    CrystalClick::CompactRecursiveJsonColumnReader.admitted_schema?(fixture.stock_schema).should be_true
  end

  it "keeps bare Nothing local-only while retaining the stock-compatible sentinels and wrappers" do
    fixture = CompactPartWriterW281Fixture
    local_names = fixture.bulk_fields.map { |entry| entry[0] }
    stock_names = fixture.stock_bulk_fields.map { |entry| entry[0] }

    local_names.includes?("nothing").should be_true
    stock_names.includes?("nothing").should be_false
    ["interval_day", "empty_tuple", "sum_state"].each do |name|
      stock_names.includes?(name).should be_true
    end

    nothing = CrystalClick::BinaryDataType.primitive("Nothing")
    CrystalClick::CompactRecursiveJsonBulkSite.admitted_type?(
      nothing,
      2,
      CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
    ).should be_true
  end

  it "round-trips local static Bulk literals under MRK3/MRK4 and String0/String1" do
    w281_write_and_read_fixture(false)
  end

  it "round-trips stock-candidate static Bulk literals under MRK3/MRK4 and String0/String1" do
    w281_write_and_read_fixture(true)
  end

  it "keeps other stateful, JSON-bearing, Geometry, QBit, and AggregateFunction Bulk types outside the slice" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    low_cardinality = CrystalClick::BinaryDataType.low_cardinality(uint8)
    CrystalClick::CompactRecursiveJsonBulkSite.admitted_type?(
      low_cardinality,
      2,
      CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
    ).should be_true
    CrystalClick::CompactRecursiveJsonColumnReader.admitted_schema?(w281_guard_schema(low_cardinality)).should be_true

    guarded = [
      {"Variant", CrystalClick::BinaryDataType.variant([uint8, string] of CrystalClick::BinaryDataType)},
      {"Dynamic", CrystalClick::BinaryDataType.dynamic},
      {"Geometry", CrystalClick::BinaryDataType.custom("Geometry")},
      {"QBit", CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 8_u64))},
      {"AggregateFunction", CrystalClick::BinaryDataType.aggregate_function("sum", CrystalClick::BinaryDataType.primitive("UInt64"))},
    ] of Tuple(String, CrystalClick::BinaryDataType)

    guarded.each do |_label, type|
      CrystalClick::CompactRecursiveJsonBulkSite.admitted_type?(
        type,
        2,
        CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      ).should be_false
      CrystalClick::CompactRecursiveJsonColumnReader.admitted_schema?(w281_guard_schema(type)).should be_false
    end

    json_array = CrystalClick::BinaryDataType.array(CompactPartWriterW281Fixture.json_type)
    json_array.contains_json?.should be_true
    expect_raises(ArgumentError) do
      CrystalClick::StorageColumnSchema.bulk(json_array, json_array.name)
    end
  end

  it "preserves the inherited descriptor-depth limit through the JSON root and Bulk wrapper" do
    nested = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt8")),
    )
    schema = w281_guard_schema(nested)
    enough_depth = CrystalClick::BinaryCodecLimits.new(4, 4096, 1_000_000, 64 * 1024 * 1024)
    one_short = CrystalClick::BinaryCodecLimits.new(3, 4096, 1_000_000, 64 * 1024 * 1024)

    CrystalClick::CompactRecursiveJsonColumnReader.admitted_schema?(schema, enough_depth).should be_true
    CrystalClick::CompactRecursiveJsonColumnReader.admitted_schema?(schema, one_short).should be_false
  end
end
