require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w268_fixture"

private def w268a_attempt_write(
  part_path : String,
  columns : Array(CrystalClick::CompactPartColumn),
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
  transport_limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new,
  mark_format : CrystalClick::CompactMarkFormat = CrystalClick::CompactMarkFormat::Mrk4,
  mode : CrystalClick::CompactVariantDiscriminatorMode = CrystalClick::CompactVariantDiscriminatorMode::Compact,
  keys : Slice(UInt64) = CompactPartWriterW268Fixture.keys,
) : String
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW268Fixture::KEY_NAME,
    keys,
    columns,
    rows_per_mark: CompactPartWriterW268Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW268Fixture::FRAME_BYTES,
    limits: limits,
    transport_limits: transport_limits,
    mark_format: mark_format,
    variant_discriminator_mode: mode,
  )
end

private def w268a_no_publication(parent : String, part_path : String) : Nil
  File.exists?(part_path).should be_false
  Dir.children(parent).should be_empty
end

private def w268a_u16(type : CrystalClick::BinaryDataType, value : UInt16) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.fixed(
    type,
    Bytes[(value & 0x00ff_u16).to_u8, (value >> 8).to_u8],
  )
end

private def w268a_le_u64(bytes : Bytes) : UInt64
  unless bytes.size == 8
    raise "W268 nested Variant discriminator prefix must be eight bytes"
  end
  value = 0_u64
  bytes.size.times do |index|
    value |= bytes[index].to_u64 << (index * 8)
  end
  value
end

private def w268a_structure(
  ordinary : CrystalClick::BinaryDataType,
  version : UInt64 = CrystalClick::DynamicStructure::VERSION_V3,
  counts : Array(UInt64) = [0_u64, 2_u64],
  shared : Array(CrystalClick::StructureStatistic) = [] of CrystalClick::StructureStatistic,
) : CrystalClick::DynamicStructure
  statistics = CrystalClick::StructureStatistics.new(counts, shared)
  CrystalClick::DynamicStructure.new([ordinary] of CrystalClick::BinaryDataType, statistics, version: version)
end

private def w268a_structure_prefix(
  window : CrystalClick::CompactPartPhysicalWindow,
  mark_index : Int,
) : CrystalClick::DynamicStructure
  mark = window.granules[mark_index]
  prefixes = mark.shards.select do |shard|
    shard.stream_name.try(&.ends_with?(".dynamic_structure")) == true
  end
  prefixes.size.should eq(1)
  CrystalClick::DynamicStructureCodec.decode(prefixes[0].bytes)
end

describe "W268 Compact Dynamic writer adversaries" do
  it "keeps the old unbound Dynamic input as a strict refusal" do
    fixture = CompactPartWriterW268Fixture
    parent = File.tempname("crystal-click-w268-unbound-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      unbound = CrystalClick::CompactPartColumn.binary_bulk(
        CompactPartWriterW268Fixture::ROOT_COLUMN,
        fixture.root_type,
        fixture.root_granules,
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w268a_attempt_write(part_path, [unbound] of CrystalClick::CompactPartColumn)
      end
      w268a_no_publication(parent, part_path)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects Compact-inadmissible aggregate descriptors in a frozen actual roster" do
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    actual_types = [
      CrystalClick::BinaryDataType.aggregate_count,
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Sum,
        CrystalClick::BinaryDataType.primitive("UInt64"),
      ),
    ] of CrystalClick::BinaryDataType

    actual_types.each do |actual_type|
      # Construct statistics in canonical arm order: a two-row first sample
      # uses the actual ordinary arm twice and SharedVariant zero times.
      names = CrystalClick::DynamicStructure.new(
        [actual_type] of CrystalClick::BinaryDataType,
        version: CrystalClick::DynamicStructure::VERSION_V3,
      ).canonical_variant_names
      counts = names.map do |name|
        name == CrystalClick::DynamicStructure::SHARED_VARIANT_NAME ? 0_u64 : 2_u64
      end
      structure = CrystalClick::DynamicStructure.new(
        [actual_type] of CrystalClick::BinaryDataType,
        CrystalClick::StructureStatistics.new(counts, [] of CrystalClick::StructureStatistic),
        version: CrystalClick::DynamicStructure::VERSION_V3,
      )
      structure.statistics.not_nil!.counts.should eq(counts)

      context = CrystalClick::CompactDynamicWriteContext.new(
        {CompactPartWriterW268Fixture::ROOT_SITE => structure} of String => CrystalClick::DynamicStructure,
      )
      context.site_structures[CompactPartWriterW268Fixture::ROOT_SITE].should eq(structure)

      actual_values = if actual_type.tag == CrystalClick::BinaryDataType::TAG_AGGREGATE_FUNCTION
                        [
                          CrystalClick::BinaryValue.aggregate_count_state(actual_type, 1_u64),
                          CrystalClick::BinaryValue.aggregate_count_state(actual_type, 2_u64),
                        ] of CrystalClick::BinaryValue
                      else
                        [
                          CrystalClick::BinaryValue.simple_aggregate(actual_type, CrystalClick::BinaryValue.uint64(1_u64)),
                          CrystalClick::BinaryValue.simple_aggregate(actual_type, CrystalClick::BinaryValue.uint64(2_u64)),
                        ] of CrystalClick::BinaryValue
                      end
      actual_rows = actual_values.map do |value|
        CrystalClick::BinaryValue.dynamic(dynamic_type, value)
      end
      input = CrystalClick::CompactDynamicColumnInput.new(
        "payload",
        dynamic_type,
        [actual_rows] of Array(CrystalClick::BinaryValue),
        context,
      )
      limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
      budget = CrystalClick::BinaryCodecBudget.new(limits, true)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompactDynamicCallbackPlan.new(input, limits, budget)
      end
    end
  end

  it "rejects missing, extra, or wrong-path site bindings before creating a stage" do
    fixture = CompactPartWriterW268Fixture
    expect_raises(ArgumentError) do
      CrystalClick::CompactDynamicWriteContext.new({} of String => CrystalClick::DynamicStructure)
    end
    uint8 = fixture.uint8_type
    uint16 = fixture.uint16_type
    root_dynamic = fixture.root_type
    nested_dynamic = fixture.nested_dynamic_type
    items_type = CrystalClick::BinaryDataType.array(nested_dynamic)
    two_site_type = CrystalClick::BinaryDataType.tuple(
      [root_dynamic, items_type] of CrystalClick::BinaryDataType,
      ["root", "items"] of String,
    )
    two_site_rows = [] of CrystalClick::BinaryValue
    CompactPartWriterW268Fixture::ROW_COUNT.times do |index|
      two_site_rows << CrystalClick::BinaryValue.tuple(
        two_site_type,
        [
          CrystalClick::BinaryValue.dynamic(root_dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[index.to_u8])),
          CrystalClick::BinaryValue.array(
            items_type,
            [CrystalClick::BinaryValue.dynamic(nested_dynamic, w268a_u16(uint16, index.to_u16))] of CrystalClick::BinaryValue,
          ),
        ] of CrystalClick::BinaryValue,
      )
    end
    two_site_granules = two_site_rows.each_slice(CompactPartWriterW268Fixture::ROWS_PER_MARK).map(&.to_a).to_a

    missing_site = {
      "root.field.0" => w268a_structure(uint8),
    } of String => CrystalClick::DynamicStructure
    wrong_path = {
      "root.not-a-site" => w268a_structure(uint8),
    } of String => CrystalClick::DynamicStructure
    extra_site = {
      CompactPartWriterW268Fixture::ROOT_SITE => w268a_structure(uint8),
      "root.extra"                            => w268a_structure(uint16),
    } of String => CrystalClick::DynamicStructure

    cases = [] of Tuple(CrystalClick::BinaryDataType, Array(Array(CrystalClick::BinaryValue)), Hash(String, CrystalClick::DynamicStructure))
    cases << {two_site_type, two_site_granules, missing_site}
    cases << {root_dynamic, fixture.root_granules, wrong_path}
    cases << {root_dynamic, fixture.root_granules, extra_site}

    cases.each_with_index do |(type, granules, sites), case_index|
      parent = File.tempname("crystal-click-w268-site-#{case_index}-")
      part_path = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        column = CrystalClick::CompactPartColumn.dynamic_bulk(
          "payload",
          type,
          granules,
          CrystalClick::CompactDynamicWriteContext.new(sites),
        )
        expect_raises(ArgumentError) do
          w268a_attempt_write(part_path, [column] of CrystalClick::CompactPartColumn)
        end
        w268a_no_publication(parent, part_path)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "requires full first-prefix statistics for V1, V2, and V3, including V3" do
    fixture = CompactPartWriterW268Fixture
    [
      CrystalClick::DynamicStructure::VERSION_V1,
      CrystalClick::DynamicStructure::VERSION_V2,
      CrystalClick::DynamicStructure::VERSION_V3,
    ].each do |version|
      structure = CrystalClick::DynamicStructure.new(
        [fixture.uint8_type] of CrystalClick::BinaryDataType,
        version: version,
      )
      sites = {CompactPartWriterW268Fixture::ROOT_SITE => structure} of String => CrystalClick::DynamicStructure
      expect_raises(ArgumentError) do
        CrystalClick::CompactDynamicWriteContext.new(sites)
      end
    end
  end

  it "snapshots caller context and granule containers before later caller mutation" do
    fixture = CompactPartWriterW268Fixture
    parent = File.tempname("crystal-click-w268-detached-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      sites = {
        CompactPartWriterW268Fixture::ROOT_SITE => w268a_structure(fixture.uint8_type),
      } of String => CrystalClick::DynamicStructure
      context = CrystalClick::CompactDynamicWriteContext.new(sites)
      granules = fixture.root_granules
      column = CrystalClick::CompactPartColumn.dynamic_bulk(
        CompactPartWriterW268Fixture::ROOT_COLUMN,
        fixture.root_type,
        granules,
        context,
      )

      sites.clear
      granules.clear
      w268a_attempt_write(part_path, [column] of CrystalClick::CompactPartColumn)

      reader = CrystalClick::CompactDynamicBulkColumnReader.open(part_path, CompactPartWriterW268Fixture::ROOT_COLUMN, fixture.root_type)
      fixture.signature(CompactPartWriterW268Fixture::ROOT_COLUMN, reader.read_marks(0, CompactPartWriterW268Fixture::MARK_COUNT).flatten).should eq(CompactPartWriterW268Fixture::ROOT_SIGNATURES)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "allows valid per-site roster swaps through SharedVariant without conflating the sites" do
    fixture = CompactPartWriterW268Fixture
    parent = File.tempname("crystal-click-w268-swapped-rosters-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      root_swapped = w268a_structure(
        fixture.uint16_type,
        CrystalClick::DynamicStructure::VERSION_V3,
        [2_u64, 0_u64],
        [CrystalClick::StructureStatistic.new("UInt8", 2_u64)] of CrystalClick::StructureStatistic,
      )
      nested_swapped = w268a_structure(
        fixture.uint8_type,
        CrystalClick::DynamicStructure::VERSION_V3,
        [2_u64, 0_u64],
        [CrystalClick::StructureStatistic.new("UInt16", 2_u64)] of CrystalClick::StructureStatistic,
      )
      root_context = CrystalClick::CompactDynamicWriteContext.new(
        {CompactPartWriterW268Fixture::ROOT_SITE => root_swapped} of String => CrystalClick::DynamicStructure,
      )
      nested_context = CrystalClick::CompactDynamicWriteContext.new(
        {CompactPartWriterW268Fixture::NESTED_SITE => nested_swapped} of String => CrystalClick::DynamicStructure,
      )
      columns = [
        CrystalClick::CompactPartColumn.dynamic_bulk(
          CompactPartWriterW268Fixture::ROOT_COLUMN,
          fixture.root_type,
          fixture.root_granules,
          root_context,
        ),
        CrystalClick::CompactPartColumn.dynamic_bulk(
          CompactPartWriterW268Fixture::CTX_COLUMN,
          fixture.ctx_type,
          fixture.ctx_granules,
          nested_context,
        ),
      ] of CrystalClick::CompactPartColumn

      w268a_attempt_write(part_path, columns)
      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      {
        {CompactPartWriterW268Fixture::ROOT_COLUMN, "UInt16", "UInt8"},
        {CompactPartWriterW268Fixture::CTX_COLUMN, "UInt8", "UInt16"},
      }.each do |column_name, roster_name, shared_name|
        first = w268a_structure_prefix(physical.read_window(column_name, 0, 1), 0)
        first.type_at(0).name.should eq(roster_name)
        statistics = first.statistics.not_nil!
        statistics.counts.should eq([2_u64, 0_u64])
        statistics.shared.map { |entry| {entry.name, entry.count} }.to_h.should eq({shared_name => 2_u64})
      end
      [
        {CompactPartWriterW268Fixture::ROOT_COLUMN, fixture.root_type, CompactPartWriterW268Fixture::ROOT_SIGNATURES},
        {CompactPartWriterW268Fixture::CTX_COLUMN, fixture.ctx_type, CompactPartWriterW268Fixture::CTX_SIGNATURES},
      ].each do |column_name, type, expected|
        reader = CrystalClick::CompactDynamicBulkColumnReader.open(part_path, column_name, type)
        fixture.signature(column_name, reader.read_marks(0, CompactPartWriterW268Fixture::MARK_COUNT).flatten).should eq(expected)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "binds the discriminator mode and exact context provenance into the mixed write plan" do
    fixture = CompactPartWriterW268Fixture
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    input = fixture.columns.first.dynamic_input
    budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    plan = CrystalClick::CompactPartWritePlan.new(
      [input] of CrystalClick::CompactPartWriteInput,
      limits,
      budget,
      CrystalClick::CompactMarkFormat::Mrk4,
      CrystalClick::CompactVariantDiscriminatorMode::Basic,
    )

    plan.mark_format.should eq(CrystalClick::CompactMarkFormat::Mrk4)
    plan.variant_discriminator_mode.should eq(CrystalClick::CompactVariantDiscriminatorMode::Basic)
    plan.same_input?(input, 0).should be_true
    dynamic_plan = plan.column_plans[0].as(CrystalClick::CompactDynamicCallbackPlan)
    dynamic_plan.variant_discriminator_mode.should eq(CrystalClick::CompactVariantDiscriminatorMode::Basic)

    changed_structure = fixture.structure(
      fixture.uint8_type,
      CrystalClick::DynamicStructure::VERSION_V2,
      2_u64,
    )
    changed_context = CrystalClick::CompactDynamicWriteContext.new(
      {CompactPartWriterW268Fixture::ROOT_SITE => changed_structure} of String => CrystalClick::DynamicStructure,
    )
    changed_input = CrystalClick::CompactDynamicColumnInput.new(
      input.name,
      input.type,
      input.granules,
      changed_context,
    )
    plan.same_input?(changed_input, 0).should be_false
  end

  it "rejects an unknown discriminator mode before creating a stage" do
    fixture = CompactPartWriterW268Fixture
    parent = File.tempname("crystal-click-w268-unknown-mode-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      unknown_mode = CrystalClick::CompactVariantDiscriminatorMode.new(9_u64)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w268a_attempt_write(
          part_path,
          fixture.columns,
          mode: unknown_mode,
        )
      end
      w268a_no_publication(parent, part_path)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "refuses a shared write-budget exhaustion without publishing a partial part" do
    fixture = CompactPartWriterW268Fixture
    parent = File.tempname("crystal-click-w268-budget-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      tiny_cumulative_budget = CrystalClick::BinaryCodecLimits.new(
        max_depth: 64,
        max_nodes: 1_000_000,
        max_elements: CompactPartWriterW268Fixture::ROW_COUNT,
        max_bytes: 1_000_000,
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w268a_attempt_write(part_path, fixture.columns, limits: tiny_cumulative_budget)
      end
      w268a_no_publication(parent, part_path)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps nested Variant and LowCardinality callbacks for an empty Dynamic arm mark" do
    fixture = CompactPartWriterW268Fixture
    string_type = fixture.string_type
    uint16_type = fixture.uint16_type
    low_type = CrystalClick::BinaryDataType.low_cardinality(string_type)
    variant_type = CrystalClick::BinaryDataType.variant([low_type, uint16_type] of CrystalClick::BinaryDataType)
    array_type = CrystalClick::BinaryDataType.array(variant_type)
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    variant_low_index = variant_type.child_count.times.find do |index|
      variant_type.child_at(index) == low_type
    end.not_nil!
    variant_uint16_index = variant_type.child_count.times.find do |index|
      variant_type.child_at(index) == uint16_type
    end.not_nil!

    low_value = ->(text : String) {
      CrystalClick::BinaryValue.variant(
        variant_type,
        variant_low_index,
        CrystalClick::BinaryValue.low_cardinality(low_type, CrystalClick::BinaryValue.string(text)),
      )
    }
    uint16_value = ->(number : UInt16) {
      CrystalClick::BinaryValue.variant(variant_type, variant_uint16_index, w268a_u16(uint16_type, number))
    }
    dynamic_array = ->(items : Array(CrystalClick::BinaryValue)) {
      CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.array(array_type, items))
    }
    rows = [
      dynamic_array.call([low_value.call("alpha"), uint16_value.call(7_u16)] of CrystalClick::BinaryValue),
      dynamic_array.call([uint16_value.call(8_u16)] of CrystalClick::BinaryValue),
      dynamic_array.call([uint16_value.call(9_u16)] of CrystalClick::BinaryValue),
      dynamic_array.call([uint16_value.call(10_u16)] of CrystalClick::BinaryValue),
      dynamic_array.call([] of CrystalClick::BinaryValue),
      dynamic_array.call([] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue

    canonical_names = [CrystalClick::DynamicStructure::SHARED_VARIANT_NAME, array_type.name].sort
    counts = canonical_names.map { |name| name == CrystalClick::DynamicStructure::SHARED_VARIANT_NAME ? 0_u64 : 2_u64 }
    nested_structure = CrystalClick::DynamicStructure.new(
      [array_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(counts, [] of CrystalClick::StructureStatistic),
      version: CrystalClick::DynamicStructure::VERSION_V2,
    )
    context = CrystalClick::CompactDynamicWriteContext.new(
      {CompactPartWriterW268Fixture::ROOT_SITE => nested_structure} of String => CrystalClick::DynamicStructure,
    )
    column = CrystalClick::CompactPartColumn.dynamic_bulk(
      "payload",
      dynamic_type,
      [rows[0, 2], rows[2, 2], rows[4, 2]],
      context,
    )
    nested_keys = Slice(UInt64).new(rows.size) { |index| (index + 1).to_u64 }

    [
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Compact},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Compact},
    ].each do |mark_format, mode|
      parent = File.tempname("crystal-click-w268-nested-#{mark_format}-#{mode}-")
      part_path = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        w268a_attempt_write(
          part_path,
          [column] of CrystalClick::CompactPartColumn,
          mark_format: mark_format,
          mode: mode,
          keys: nested_keys,
        )
        reader = CrystalClick::CompactDynamicBulkColumnReader.open(part_path, "payload", dynamic_type)
        reader.mark_count.should eq(3)
        decoded = reader.read_marks(0, 3).flatten
        decoded.size.should eq(6)
        decoded.map do |value|
          value.child_at(0).elements.map do |variant|
            child = variant.variant_child?.not_nil!
            if child.type.tag == CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
              "LC:#{String.new(child.child_at(0).bytes)}"
            else
              decoded_number = child.byte_at(0).to_u16 | (child.byte_at(1).to_u16 << 8)
              "UInt16:#{decoded_number}"
            end
          end.join(",")
        end.should eq(["LC:alpha,UInt16:7", "UInt16:8", "UInt16:9", "UInt16:10", "", ""] of String)

        if mark_format == CrystalClick::CompactMarkFormat::Mrk4
          physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
          window = physical.read_window("payload", 0, 3)
          window.granules.size.should eq(3)
          window.granules.each_with_index do |mark, mark_index|
            prefixes = mark.shards.select do |shard|
              shard.stream_name.try(&.ends_with?(".variant_discr_prefix")) == true
            end
            prefixes.size.should eq(2)
            prefixes.count { |prefix| prefix.stream_name == "payload.variant_discr_prefix" }.should eq(1)
            prefixes.count { |prefix| prefix.stream_name != "payload.variant_discr_prefix" }.should eq(1)
            prefixes.each do |prefix|
              w268a_le_u64(prefix.bytes).should eq(mode.wire_value)
            end

            dictionary_prefixes = mark.shards.select do |shard|
              shard.stream_name.try(&.ends_with?(".dict_prefix")) == true
            end
            dictionary_prefixes.size.should eq(1)
            w268a_le_u64(dictionary_prefixes[0].bytes).should eq(CrystalClick::BinaryLowCardinalityStorageStreams::VERSION)

            dictionary_prefix_name = dictionary_prefixes[0].stream_name.not_nil!
            dictionary_prefix_name.ends_with?(".dict_prefix").should be_true
            dictionary_index_name = dictionary_prefix_name.byte_slice(
              0,
              dictionary_prefix_name.bytesize - ".dict_prefix".bytesize,
            ).not_nil!
            dictionary_body = mark.shards.find do |shard|
              shard.stream_name == "#{dictionary_index_name}.dict"
            end || raise "W268 nested LowCardinality dictionary callback is absent"
            dictionary_body.bytes.should be_empty
            dictionary_indexes = mark.shards.find do |shard|
              shard.stream_name == dictionary_index_name
            end || raise "W268 nested LowCardinality indexes callback is absent"
            if mark_index == 0
              dictionary_indexes.bytes.should_not be_empty
            else
              dictionary_indexes.bytes.should be_empty
            end
          end

          window.granules.each_with_index do |mark, mark_index|
            discriminator_bodies = mark.shards.select do |shard|
              shard.stream_name.try(&.ends_with?(".variant_discr")) == true
            end
            discriminator_bodies.size.should eq(2)
            root_dynamic_body = discriminator_bodies.find do |shard|
              shard.stream_name == "payload.variant_discr"
            end || raise "W268 root Dynamic discriminator callback is absent"
            nested_variant_body = discriminator_bodies.find do |shard|
              shard.stream_name != "payload.variant_discr"
            end || raise "W268 nested Variant discriminator callback is absent"
            root_dynamic_body.bytes.should_not be_empty
            if mark_index == 2
              nested_variant_body.bytes.should be_empty
            else
              nested_variant_body.bytes.should_not be_empty
            end
          end
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
