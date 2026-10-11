require "../src/crystal_click/object_shared_path_callback_source"
require "./spec_helper"

private def w263_preframed_source(
  bytes : Bytes,
  names_and_offsets : Array(Tuple(String, UInt64)),
) : CrystalClick::ObjectSharedPathTapeReader
  events = names_and_offsets.map do |name, offset|
    CrystalClick::ObjectSharedPathSubstreamEvent.new(name, offset)
  end
  CrystalClick::ObjectSharedPathTapeReader.new(
    bytes,
    events,
    CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
  )
end

describe "W263 preframed callback-source contract" do
  it "borrows only the named event and preserves exact and empty successors" do
    bytes = Bytes[0x31_u8, 0x32_u8, 0x33_u8, 1_u8, 2_u8, 3_u8, 4_u8, 5_u8, 6_u8, 7_u8, 8_u8]
    source = w263_preframed_source(
      bytes,
      [{"structure", 0_u64}, {"fixed", 3_u64}, {"empty", 11_u64}],
    )
    source.with_self_delimited("structure") do |borrowed|
      borrowed.should eq(bytes[0, 3])
      {borrowed[0].to_i32, borrowed.size}
    end.should eq(0x31)
    source.take_exact("fixed", 8).should eq(bytes[3, 8])
    source.take_exact("empty", 0).should be_empty
    source.finish!
  end

  it "rejects wrong names before parsing and does not commit a parser failure" do
    bytes = Bytes[0x11_u8, 0x22_u8, 0x33_u8]
    source = w263_preframed_source(bytes, [{"structure", 0_u64}])
    entered = false
    expect_raises(CrystalClick::CorruptPartError) do
      source.with_self_delimited("other") do |borrowed|
        entered = true
        {0_i32, borrowed.size}
      end
    end
    entered.should be_false
    expect_raises(CrystalClick::CorruptPartError, /seeded parser failure/) do
      source.with_self_delimited("structure") do |borrowed|
        if borrowed[0] == 0x11_u8
          raise CrystalClick::CorruptPartError.new("seeded parser failure")
        end
        {0_i32, borrowed.size}
      end
    end
    source.take_exact("structure", bytes.size).should eq(bytes)
    source.finish!
  end

  it "does not accept partial, negative or out-of-span parser consumption" do
    bytes = Bytes[0x10_u8, 0x20_u8, 0x30_u8]
    {-1_i32, 0_i32, 2_i32, 4_i32}.each do |consumed|
      source = w263_preframed_source(bytes, [{"structure", 0_u64}])
      expect_raises(CrystalClick::CorruptPartError) do
        source.with_self_delimited("structure") do |_borrowed|
          {7_i32, consumed}
        end
      end
      source.take_exact("structure", bytes.size).should eq(bytes)
      source.finish!
    end
  end

  it "rejects parser re-entry through legacy, fixed and parser reads before consuming the borrowed event" do
    {:legacy, :fixed, :parser}.each do |entry|
      bytes = Bytes[0x11_u8, 0x22_u8]
      source = w263_preframed_source(bytes, [{"structure", 0_u64}, {"body", 1_u64}])
      expect_raises(CrystalClick::CorruptPartError, /re-entrant/) do
        source.with_self_delimited("structure") do |borrowed|
          case entry
          when :legacy
            source.take("structure")
          when :fixed
            source.take_exact("structure", 1)
          when :parser
            source.with_self_delimited("structure") { |nested| {0_i32, nested.size} }
          end
          {0_i32, borrowed.size}
        end
      end
      source.take_exact("structure", 1).should eq(Bytes[0x11])
      source.take_exact("body", 1).should eq(Bytes[0x22])
      source.finish!
    end
  end

  it "keeps the outer reservation after rescued re-entry and commits only its duplicate-name event" do
    bytes = Bytes[0x11_u8, 0x22_u8]
    source = w263_preframed_source(bytes, [{"structure", 0_u64}, {"structure", 1_u64}])
    source.with_self_delimited("structure") do |borrowed|
      expect_raises(CrystalClick::CorruptPartError, /re-entrant/) do
        source.with_self_delimited("structure") { |nested| {0_i32, nested.size} }
      end
      expect_raises(CrystalClick::CorruptPartError, /re-entrant/) do
        source.take_exact("structure", 1)
      end
      {borrowed[0], borrowed.size}
    end.should eq(0x11_u8)
    source.take_exact("structure", 1).should eq(Bytes[0x22])
    source.finish!
  end

  it "rejects seven- and nine-byte fixed prefixes without consuming them" do
    {7, 9}.each do |size|
      bytes = Bytes.new(size, 0_u8)
      source = w263_preframed_source(bytes, [{"variant_discr_prefix", 0_u64}])
      expect_raises(CrystalClick::CorruptPartError) do
        source.take_exact("variant_discr_prefix", 8)
      end
      source.take_exact("variant_discr_prefix", size).should eq(bytes)
      source.finish!
    end
  end

  it "does not finish a source with an unconsumed empty callback" do
    bytes = Bytes[0x7f_u8]
    source = w263_preframed_source(bytes, [{"body", 0_u64}, {"empty_suffix", 1_u64}])
    source.take_exact("body", 1).should eq(bytes)
    expect_raises(CrystalClick::CorruptPartError) { source.finish! }
    source.take_exact("empty_suffix", 0).should be_empty
    source.finish!
  end

  it "parses complete Object statistics at the inherited depth without consuming the next callback" do
    # Independently authored Object V3: one path `x`, MAP shared data, a
    # present statistics flag, count 2 for `x`, and no shared statistics.
    bytes = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 1, 1, 120, 0, 1, 2, 0, 0x42]
    source = w263_preframed_source(bytes, [{"object_structure", 0_u64}, {"body", 15_u64}])
    limits = CrystalClick::BinaryCodecLimits.new(3, 32, 32, 1_024)
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    structure, statistics_offset = source.with_self_delimited("object_structure") do |borrowed|
      context = CrystalClick::BinaryCodecContext.new(limits, borrowed, false, budget)
      result = CrystalClick::ObjectStructureCodec.read_with_statistics_offset(context, 3_i32)
      {result, context.input_offset}
    end
    structure.dynamic_paths.should eq(["x"])
    structure.statistics.not_nil!.count_at(0).should eq(2_u64)
    statistics_offset.should eq(12_i32)
    source.take_exact("body", 1).should eq(Bytes[0x42])
    source.finish!
  end

  it "rejects a complete Object prefix beyond the inherited depth without advancing the callback" do
    bytes = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    source = w263_preframed_source(bytes, [{"object_structure", 0_u64}])
    limits = CrystalClick::BinaryCodecLimits.new(3, 32, 32, 1_024)
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    expect_raises(CrystalClick::CorruptPartError, /depth/) do
      source.with_self_delimited("object_structure") do |borrowed|
        context = CrystalClick::BinaryCodecContext.new(limits, borrowed, false, budget)
        result = CrystalClick::ObjectStructureCodec.read_with_statistics_offset(context, 4_i32)
        {result, context.input_offset}
      end
    end
    source.take_exact("object_structure", bytes.size).should eq(bytes)
    source.finish!
  end

  it "inherits complete statistics into an inferred Dynamic prefix at a static JSON site" do
    # Object V3 prefix followed by Dynamic V3 with an ordinary UInt8 arm,
    # present statistics [2, 0] (ordinary and implicit SharedVariant), and
    # a Compact discriminator prefix. These callbacks are independent literals.
    bytes = Bytes[
      4, 0, 0, 0, 0, 0, 0, 0, 1, 1, 120, 0, 1, 2, 0,
      4, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 2, 0, 0,
      1, 0, 0, 0, 0, 0, 0, 0,
    ]
    source = w263_preframed_source(
      bytes,
      [{"root.object_structure", 0_u64}, {"root.x.dynamic_structure", 15_u64}, {"root.x.variant_discr_prefix", 29_u64}],
    )
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    descriptor = CrystalClick::BinaryDataType.json(max_dynamic_paths: 1, max_dynamic_types: 1)
    nested_context = CrystalClick::ObjectSharedNestedSerializationContext.for_read(
      0_u64,
      CrystalClick::BinaryBulkProfile.single_stream,
    )
    prefix = CrystalClick::ObjectDocumentCallbackPrefixReader.read_static_json_prefix(
      source,
      descriptor,
      1_i32,
      "root",
      "root",
      0_u64,
      nested_context,
      budget,
    )
    prefix.statistics_context.should eq(CrystalClick::ObjectDocumentCallbackPrefix::StatisticsContext::Complete)
    prefix.structures.object.statistics.not_nil!.count_at(0).should eq(2_u64)
    dynamic = prefix.structures.dynamic_for("x")
    dynamic.statistics.not_nil!.count_at(0).should eq(2_u64)
    dynamic.statistics.not_nil!.count_at(1).should eq(0_u64)
    prefix.prefix_callback_count.should eq(3)
    source.finish!
  end
end
