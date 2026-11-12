require "./spec_helper"
require "file_utils"
require "./support/compact_recursive_dynamic_w284_fixture"

module CompactRecursiveDynamicW284ReaderAdversaryFixture
  extend self

  JSON_DECLARATION        = "JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)"
  DYNAMIC_FIRST_SCHEMA    = "Tuple(sample Dynamic(max_types=1), doc #{JSON_DECLARATION})"
  DYNAMIC_FIRST_SITE      = "root/tuple[0]"
  DYNAMIC_FIRST_JSON_SITE = "root/tuple[1]"
  COLUMN_NAME             = "trace"

  class SeededObserverAbort < Exception
  end

  def dynamic_context(
    actual_type : CrystalClick::BinaryDataType,
    population : UInt64 = 1_u64,
  ) : CrystalClick::CompactDynamicWriteContext
    probe = CrystalClick::DynamicStructure.new([actual_type] of CrystalClick::BinaryDataType)
    counts = Array(UInt64).new(probe.canonical_variant_count, 0_u64)
    counts[probe.canonical_index_for(actual_type)] = population
    structure = CrystalClick::DynamicStructure.new(
      [actual_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(counts, [] of CrystalClick::StructureStatistic),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    CrystalClick::CompactDynamicWriteContext.new(
      {"root" => structure} of String => CrystalClick::DynamicStructure,
    )
  end

  def json_context(path : String) : CrystalClick::CompactJsonWriteContext
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(JSON_DECLARATION)
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
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
    CrystalClick::CompactJsonWriteContext.new(
      {path => plan} of String => CrystalClick::ObjectDocumentPlan,
    )
  end

  def object_document(tag : UInt8) : CrystalClick::ObjectDocument
    CrystalClick::ObjectDocument.new(
      {"t" => CrystalClick::BinaryValue.fixed(
        CrystalClick::BinaryDataType.primitive("UInt8"),
        Bytes[tag],
      )} of String => CrystalClick::BinaryValue,
    )
  end

  def dynamic_first_column : CrystalClick::CompactPartColumn
    schema = CrystalClick::StorageColumnSchema.parse(DYNAMIC_FIRST_SCHEMA)
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    actual_type = CrystalClick::BinaryDataType.primitive("UInt64")
    dynamic = CrystalClick::BinaryValue.dynamic(
      dynamic_type,
      CrystalClick::BinaryValue.uint64(77_u64),
    )
    row = CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.bulk(dynamic),
      CrystalClick::StorageColumnValue.object_document(object_document(88_u8)),
    ] of CrystalClick::StorageColumnValue)
    CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      [[row] of CrystalClick::StorageColumnValue],
      json_context(DYNAMIC_FIRST_JSON_SITE),
      dynamic_contexts: {
        DYNAMIC_FIRST_SITE => dynamic_context(actual_type),
      } of String => CrystalClick::CompactDynamicWriteContext,
    )
  end

  def write_w257(part_path : String) : String
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
    )
  end

  def array_arm_column : CrystalClick::CompactPartColumn
    fixture = CompactRecursiveDynamicW284Fixture
    schema = fixture.schema
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    actual_type = CrystalClick::BinaryDataType.array(uint64)
    context = dynamic_context(actual_type)

    dynamic = ->(value : CrystalClick::BinaryValue?) {
      CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.dynamic(dynamic_type, value))
    }
    tuple = ->(tag : UInt8, sample : CrystalClick::StorageColumnValue) {
      CrystalClick::StorageColumnValue.tuple([
        CrystalClick::StorageColumnValue.object_document(object_document(tag)),
        sample,
      ] of CrystalClick::StorageColumnValue)
    }
    rows = [
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        tuple.call(14_u8, dynamic.call(nil)),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        tuple.call(
          15_u8,
          dynamic.call(CrystalClick::BinaryValue.array(
            actual_type,
            [CrystalClick::BinaryValue.uint64(77_u64)] of CrystalClick::BinaryValue,
          )),
        ),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        tuple.call(16_u8, dynamic.call(nil)),
      ] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue

    CrystalClick::CompactPartColumn.json(
      CompactRecursiveDynamicW284Fixture::COLUMN_NAME,
      schema,
      [rows[0, 2], rows[2, 2]],
      fixture.column.json_input.json_context,
      dynamic_contexts: {
        CompactRecursiveDynamicW284Fixture::DYNAMIC_SITE_PATH => context,
      } of String => CrystalClick::CompactDynamicWriteContext,
    )
  end
end

describe "W284 recursive Dynamic reader and parent-ledger adversaries" do
  it "rolls back a failed variable structure-prefix parse so the same parent callback can be retried" do
    fixture = CompactRecursiveDynamicW284ReaderAdversaryFixture
    parent = File.tempname("crystal-click-w284-prefix-retry-")
    part_path = File.join(parent, "all_1_1_0")
    Dir.mkdir(parent)
    begin
      dynamic_first = fixture.dynamic_first_column
      root_structure = dynamic_first.json_input.recursive_dynamic_context
        .site_context_for(CompactRecursiveDynamicW284ReaderAdversaryFixture::DYNAMIC_FIRST_SITE)
        .structure_at?("root").not_nil!
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        "pk",
        Slice[1_u64],
        [dynamic_first] of CrystalClick::CompactPartColumn,
        rows_per_mark: 1,
        frame_bytes: 32,
        mark_format: CrystalClick::CompactMarkFormat::Mrk3,
        variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Compact,
        profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      ).should eq(part_path)

      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      granule = physical.read_window(
        CompactRecursiveDynamicW284ReaderAdversaryFixture::COLUMN_NAME,
        0,
        1,
      ).granules[0]
      limits = CrystalClick::BinaryCodecLimits.default
      read_budget = CrystalClick::BinaryCodecBudget.new(limits, false)
      ledger = CrystalClick::CompactRecursiveJsonParentMarkLedger.new(
        physical,
        CompactRecursiveDynamicW284ReaderAdversaryFixture::COLUMN_NAME,
        granule,
        read_budget,
      )
      schema = CrystalClick::StorageColumnSchema.parse(
        CompactRecursiveDynamicW284ReaderAdversaryFixture::DYNAMIC_FIRST_SCHEMA,
      )
      schema_plan = CrystalClick::CompactRecursiveJsonSchemaPlan.new(
        schema,
        CompactRecursiveDynamicW284ReaderAdversaryFixture::COLUMN_NAME,
        limits,
        read_budget,
        CrystalClick::BinaryBulkProfile.with_size_stream,
      )
      site = schema_plan.dynamic_bulk_site(
        CompactRecursiveDynamicW284ReaderAdversaryFixture::DYNAMIC_FIRST_SITE,
      )
      resolver = CrystalClick::BinaryDynamicBulkSiteNameResolver.from_escaped_prefix(
        site.type,
        site.physical_prefix,
        site.initial_array_level,
        limits,
        CrystalClick::BinaryCodecBudget.new(limits, false),
        CrystalClick::PhysicalStreamPlanContext.new(limits),
        initial_descriptor_depth: site.descriptor_depth,
      )
      callback = resolver.structure_stream_name("root", Hash(String, CrystalClick::DynamicStructure).new)
      retained_before = ledger.retained_workspace_bytes
      probe_budget = CrystalClick::BinaryCodecBudget.new(limits, false)

      expect_raises(CrystalClick::CorruptPartError) do
        ledger.with_bulk_prefix_grammar_extent(callback) do |_borrowed|
          empty = CrystalClick::BinaryCodecContext.new(limits, Bytes.empty, false, probe_budget, false, false)
          CrystalClick::DynamicStructureCodec.read_with_statistics_offset(
            empty,
            site.descriptor_depth,
            site.descriptor_depth + 1,
            true,
          )
        end
      end
      ledger.retained_workspace_bytes.should eq(retained_before)
      ledger.complete?.should be_false

      captured = CrystalClick::CompactRecursiveJsonDynamicPrefixCursor.capture_structure!(
        site,
        ledger,
        limits,
        read_budget,
      )
      captured.type_count.should eq(root_structure.type_count)
      captured.type_at(0).should eq(root_structure.type_at(0))
      captured.statistics.should_not be_nil
      ledger.complete?.should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps an incomplete parent ledger uncompleted and does not publish a reader preparation on abort" do
    fixture = CompactRecursiveDynamicW284ReaderAdversaryFixture
    parent = File.tempname("crystal-click-w284-parent-abort-")
    part_path = File.join(parent, "all_1_1_0")
    Dir.mkdir(parent)
    begin
      fixture.write_w257(part_path).should eq(part_path)
      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      granule = physical.read_window(
        CompactRecursiveDynamicW284Fixture::COLUMN_NAME,
        0,
        1,
      ).granules[0]
      limits = CrystalClick::BinaryCodecLimits.default
      ledger = CrystalClick::CompactRecursiveJsonParentMarkLedger.new(
        physical,
        CompactRecursiveDynamicW284Fixture::COLUMN_NAME,
        granule,
        CrystalClick::BinaryCodecBudget.new(limits, false),
      )
      ledger.finish_prefixes!
      ledger.begin_mixed_body_schedule!(0)
      expect_raises(CrystalClick::CorruptPartError) do
        ledger.finish_mark!([] of String)
      end
      ledger.complete?.should be_false

      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactRecursiveDynamicW284Fixture::COLUMN_NAME,
        CompactRecursiveDynamicW284Fixture.schema,
      )
      retained_before = reader.retained_workspace_bytes
      observer_calls = 0
      observer = ->(_bytes : UInt64) do
        observer_calls += 1
        if observer_calls == 3
          raise CompactRecursiveDynamicW284ReaderAdversaryFixture::SeededObserverAbort.new(
            "abort after the first complete parent mark, before Dynamic decoding",
          )
        end
        nil
      end
      expect_raises(CompactRecursiveDynamicW284ReaderAdversaryFixture::SeededObserverAbort) do
        reader.read_marks(0, 1, observer)
      end
      observer_calls.should eq(3)
      reader.retained_workspace_bytes.should eq(retained_before)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "round-trips a Dynamic Array(UInt64) arm whose first mark has zero Q" do
    fixture = CompactRecursiveDynamicW284ReaderAdversaryFixture
    part_parent = File.tempname("crystal-click-w284-array-q-")
    part_path = File.join(part_parent, "all_1_1_0")
    Dir.mkdir(part_parent)
    begin
      column = fixture.array_arm_column
      expected = [
        CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
        CrystalClick::StorageColumnValue.array([
          CrystalClick::StorageColumnValue.tuple([
            CrystalClick::StorageColumnValue.object_document(fixture.object_document(14_u8)),
            CrystalClick::StorageColumnValue.bulk(
              CrystalClick::BinaryValue.dynamic(CrystalClick::BinaryDataType.dynamic(max_types: 1)),
            ),
          ] of CrystalClick::StorageColumnValue),
        ] of CrystalClick::StorageColumnValue),
        CrystalClick::StorageColumnValue.array([
          CrystalClick::StorageColumnValue.tuple([
            CrystalClick::StorageColumnValue.object_document(fixture.object_document(15_u8)),
            CrystalClick::StorageColumnValue.bulk(
              CrystalClick::BinaryValue.dynamic(
                CrystalClick::BinaryDataType.dynamic(max_types: 1),
                CrystalClick::BinaryValue.array(
                  CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt64")),
                  [CrystalClick::BinaryValue.uint64(77_u64)] of CrystalClick::BinaryValue,
                ),
              ),
            ),
          ] of CrystalClick::StorageColumnValue),
        ] of CrystalClick::StorageColumnValue),
        CrystalClick::StorageColumnValue.array([
          CrystalClick::StorageColumnValue.tuple([
            CrystalClick::StorageColumnValue.object_document(fixture.object_document(16_u8)),
            CrystalClick::StorageColumnValue.bulk(
              CrystalClick::BinaryValue.dynamic(CrystalClick::BinaryDataType.dynamic(max_types: 1)),
            ),
          ] of CrystalClick::StorageColumnValue),
        ] of CrystalClick::StorageColumnValue),
      ] of CrystalClick::StorageColumnValue

      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactRecursiveDynamicW284Fixture::KEY_NAME,
        CompactRecursiveDynamicW284Fixture.keys,
        [column] of CrystalClick::CompactPartColumn,
        rows_per_mark: CompactRecursiveDynamicW284Fixture::ROWS_PER_MARK,
        frame_bytes: CompactRecursiveDynamicW284Fixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
        variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Compact,
        profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      ).should eq(part_path)

      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactRecursiveDynamicW284Fixture::COLUMN_NAME,
        CompactRecursiveDynamicW284Fixture.schema,
      )
      decoded = reader.read_marks(0, CompactRecursiveDynamicW284Fixture::MARK_COUNT).flatten
      decoded.size.should eq(expected.size)
      decoded.each_with_index do |value, index|
        budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, false)
        CrystalClick::CompactPartValueComparison.storage!(value, expected[index], budget)
      end

      limits = CrystalClick::BinaryCodecLimits.default
      schema_plan = CrystalClick::CompactRecursiveJsonSchemaPlan.new(
        CompactRecursiveDynamicW284Fixture.schema,
        CompactRecursiveDynamicW284Fixture::COLUMN_NAME,
        limits,
        CrystalClick::BinaryCodecBudget.new(limits, false),
        CrystalClick::BinaryBulkProfile.with_size_stream,
      )
      site = schema_plan.dynamic_bulk_site(CompactRecursiveDynamicW284Fixture::DYNAMIC_SITE_PATH)
      actual_type = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt64"))
      probe = CrystalClick::DynamicStructure.new([actual_type] of CrystalClick::BinaryDataType)
      counts = Array(UInt64).new(probe.canonical_variant_count, 0_u64)
      counts[probe.canonical_index_for(actual_type)] = 1_u64
      structure = CrystalClick::DynamicStructure.new(
        [actual_type] of CrystalClick::BinaryDataType,
        CrystalClick::StructureStatistics.new(counts, [] of CrystalClick::StructureStatistic),
        version: CrystalClick::DynamicStructure::VERSION_V3,
      )
      capture_plan = CrystalClick::CompactRecursiveJsonDynamicBulkCapturePlan.new(
        site,
        structure,
        CrystalClick::BinaryBulkProfile.with_size_stream,
        limits,
        CrystalClick::BinaryCodecBudget.new(limits, false),
      )
      size_roles = [] of String
      capture_plan.each_data_role do |role|
        size_roles << role if role.ends_with?(".sizes")
      end
      size_roles.size.should eq(1)
      size_callback = capture_plan.callback_name_for(size_roles[0])

      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      granules = physical.read_window(
        CompactRecursiveDynamicW284Fixture::COLUMN_NAME,
        0,
        CompactRecursiveDynamicW284Fixture::MARK_COUNT,
      ).granules
      granules.map do |granule|
        matches = granule.shards.select { |shard| shard.stream_name == size_callback }
        matches.size.should eq(1)
        matches[0].bytes.size
      end.should eq([0, 8])
    ensure
      FileUtils.rm_rf(part_parent)
    end
  end
end
