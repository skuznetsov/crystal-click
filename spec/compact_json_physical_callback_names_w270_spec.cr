require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w269_fixture"

module CompactJsonPhysicalCallbackNamesW270Fixture
  extend self

  COLUMN_NAME   = "typed_dynamic_nullable_int64"
  ROWS_PER_MARK = 2
  ROW_COUNT     = 8
  MARK_COUNT    = 4

  def int64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("Int64")
  end

  def nullable_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.nullable(int64_type)
  end

  def array_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(nullable_type)
  end

  def dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 1,
      typed_paths: {"payload" => dynamic_type} of String => CrystalClick::BinaryDataType,
    )
  end

  def schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse("Array(#{json_type.name})")
  end

  def context : CrystalClick::CompactJsonWriteContext
    dynamic = CrystalClick::DynamicStructure.new(
      [array_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(
        [5_u64, 1_u64] of UInt64,
        [CrystalClick::StructureStatistic.new("String", 1_u64)] of CrystalClick::StructureStatistic,
      ),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    object = CrystalClick::ObjectStructure.new(
      [] of String,
      version: 4_u64,
      shared_data_version: 0_u64,
      bucket_count: 1_u64,
      statistics: CrystalClick::StructureStatistics.new(
        [] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      Hash(String, CrystalClick::DynamicStructure).new,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      {"payload" => dynamic_type} of String => CrystalClick::BinaryDataType,
      {"payload" => dynamic} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::CompactJsonWriteContext.new(
      {CompactPartWriterW269Fixture::ARRAY_SITE => plan} of String => CrystalClick::ObjectDocumentPlan,
    )
  end

  private def fixed_int64(value : Int64) : CrystalClick::BinaryValue
    bits = value.to_u64
    bytes = Bytes.new(sizeof(Int64)) do |index|
      ((bits >> (index * 8)) & 0xff_u64).to_u8
    end
    CrystalClick::BinaryValue.fixed(int64_type, bytes)
  end

  private def nullable(value : Int64?) : CrystalClick::BinaryValue
    if selected = value
      CrystalClick::BinaryValue.nullable(nullable_type, fixed_int64(selected))
    else
      CrystalClick::BinaryValue.nullable(nullable_type)
    end
  end

  private def array_actual(values : Array(Int64?)) : CrystalClick::BinaryValue
    children = values.map { |value| nullable(value) }
    CrystalClick::BinaryValue.array(array_type, children)
  end

  private def object_value(actual : CrystalClick::BinaryValue?) : CrystalClick::StorageColumnValue
    typed_value = CrystalClick::BinaryValue.dynamic(dynamic_type, actual)
    document = CrystalClick::ObjectDocument.new(
      {"payload" => typed_value} of String => CrystalClick::BinaryValue,
    )
    CrystalClick::StorageColumnValue.object_document(document)
  end

  private def outer_row(actuals : Array(CrystalClick::BinaryValue?)) : CrystalClick::StorageColumnValue
    objects = actuals.map { |actual| object_value(actual) }
    CrystalClick::StorageColumnValue.array(objects)
  end

  def rows : Array(CrystalClick::StorageColumnValue)
    [
      outer_row([array_actual([nil] of Int64?)] of CrystalClick::BinaryValue?),
      outer_row([array_actual([32_i64] of Int64?)] of CrystalClick::BinaryValue?),
      outer_row([] of CrystalClick::BinaryValue?),
      outer_row([] of CrystalClick::BinaryValue?),
      outer_row([nil] of CrystalClick::BinaryValue?),
      outer_row([
        array_actual([64_i64] of Int64?),
        CrystalClick::BinaryValue.string("late-shared"),
      ] of CrystalClick::BinaryValue?),
      outer_row([array_actual([nil, 96_i64] of Int64?)] of CrystalClick::BinaryValue?),
      outer_row([array_actual([] of Int64?)] of CrystalClick::BinaryValue?),
    ] of CrystalClick::StorageColumnValue
  end

  def column : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      CompactPartWriterW269Fixture.granules(rows),
      context,
    )
  end
end

describe "Compact JSON physical callback names" do
  it "keeps typed-Dynamic logical names distinct from MRK4 physical names and round-trips both mark formats" do
    column = CompactJsonPhysicalCallbackNamesW270Fixture.column
    input = column.json_input
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    plan = CrystalClick::CompactJsonCallbackPlan.new(
      input,
      limits,
      CrystalClick::BinaryCodecBudget.new(limits, true),
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    )
    binding = plan.site_binding(CompactPartWriterW269Fixture::ARRAY_SITE)
    target_pairs = binding.body_pairs.select do |_canonical, callback|
      callback.ends_with?(".Array(Nullable(Int64)).size1")
    end
    target_pairs.size.should eq(1)
    canonical_name, callback_name = target_pairs[0]
    canonical_name.ends_with?(".Array%28Nullable%28Int64%29%29.size1").should be_true
    callback_name.ends_with?(".Array(Nullable(Int64)).size1").should be_true
    canonical_name.should_not eq(callback_name)

    logical_names = plan.callback_names
    logical_names.includes?(callback_name).should be_true
    logical_names.includes?(canonical_name).should be_false

    canonical_by_callback = Hash(String, String).new
    (binding.prefix_pairs + binding.body_pairs).each do |canonical, callback|
      canonical_by_callback[callback] = canonical
    end
    expected_physical_names = logical_names.map do |name|
      canonical_by_callback[name]? || name
    end

    parent = File.tempname("crystal-click-w270-physical-callback-names-")
    mrk4_path = File.join(parent, "mrk4")
    mrk3_path = File.join(parent, "mrk3")
    reordered_path = File.join(parent, "mrk4-reordered")

    begin
      Dir.mkdir(parent)
      columns = [column] of CrystalClick::CompactPartColumn
      {
        {CrystalClick::CompactMarkFormat::Mrk4, mrk4_path},
        {CrystalClick::CompactMarkFormat::Mrk3, mrk3_path},
      }.each do |mark_format, part_path|
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW269Fixture::KEY_NAME,
          CompactPartWriterW269Fixture::KEYS,
          columns,
          rows_per_mark: CompactJsonPhysicalCallbackNamesW270Fixture::ROWS_PER_MARK,
          frame_bytes: CompactPartWriterW269Fixture::FRAME_BYTES,
          mark_format: mark_format,
          variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Compact,
        ).should eq(part_path)

        physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
        selected = physical.physical_roster.select do |slot|
          slot.column_name == CompactJsonPhysicalCallbackNamesW270Fixture::COLUMN_NAME
        end
        if mark_format.mrk4?
          selected.map do |slot|
            slot.stream_name || raise CrystalClick::CorruptPartError.new("MRK4 callback has no stream name")
          end.should eq(expected_physical_names)
        else
          selected.size.should eq(1)
          selected[0].stream_name.should be_nil
        end

        reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
          part_path,
          CompactJsonPhysicalCallbackNamesW270Fixture::COLUMN_NAME,
          CompactJsonPhysicalCallbackNamesW270Fixture.schema,
        )
        actual = reader.read_marks(0, CompactJsonPhysicalCallbackNamesW270Fixture::MARK_COUNT).flatten
        actual.size.should eq(CompactJsonPhysicalCallbackNamesW270Fixture.rows.size)
        actual.each_with_index do |value, index|
          budget = CrystalClick::BinaryCodecBudget.new(limits, false)
          CrystalClick::CompactPartValueComparison.storage!(
            value,
            CompactJsonPhysicalCallbackNamesW270Fixture.rows[index],
            budget,
          )
        end
        reader.read_marks(reader.mark_count, 0).should be_empty
      end

      # The sidecar's declared size is unchanged by permuting whole name lines;
      # the reader must still reject the now-unbound physical slot order.
      FileUtils.cp_r(mrk4_path, reordered_path)
      sidecar_path = File.join(reordered_path, "columns_substreams.txt")
      lines = File.read(sidecar_path).lines(chomp: false)
      first_line = lines.index { |line| line.chomp == "\t#{expected_physical_names[0]}" } || raise "first physical callback is absent"
      second_line = lines.index { |line| line.chomp == "\t#{expected_physical_names[1]}" } || raise "second physical callback is absent"
      lines[first_line], lines[second_line] = lines[second_line], lines[first_line]
      File.write(sidecar_path, lines.join)
      File.size(sidecar_path).should eq(File.size(File.join(mrk4_path, "columns_substreams.txt")))
      expect_raises(CrystalClick::CorruptPartError) do
        reordered_reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
          reordered_path,
          CompactJsonPhysicalCallbackNamesW270Fixture::COLUMN_NAME,
          CompactJsonPhysicalCallbackNamesW270Fixture.schema,
        )
        reordered_reader.read_marks(0, CompactJsonPhysicalCallbackNamesW270Fixture::MARK_COUNT)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects duplicate names in a physical MRK4 roster" do
    columns = [
      {CompactJsonPhysicalCallbackNamesW270Fixture::COLUMN_NAME, CompactJsonPhysicalCallbackNamesW270Fixture.json_type.name},
    ] of Tuple(String, String)
    duplicated = [
      {CompactJsonPhysicalCallbackNamesW270Fixture::COLUMN_NAME, ["same", "same"] of String},
    ] of Tuple(String, Array(String))

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactColumnsSubstreams.new(
        CrystalClick::CompactMarkFormat::Mrk4,
        columns,
        duplicated,
      )
    end
  end
end
