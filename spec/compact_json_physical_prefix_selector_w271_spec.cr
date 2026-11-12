require "./spec_helper"
require "../scripts/support/compact_physical_context_w259_fixture"
require "../src/crystal_click/compact_json_object_site_framer"
require "../src/crystal_click/compact_recursive_json_parent_mark_ledger"

private def w271_with_physical_selector_fixture(
  mode : CrystalClick::CompactMarkFormat,
  &block : CrystalClick::CompactPartPhysicalContext, CrystalClick::CompactPartPhysicalGranule ->
) : Nil
  root = File.tempname("crystal-click-w271-physical-prefix-selector")
  part = File.join(root, "part")
  Dir.mkdir_p(root)
  begin
    CompactPhysicalContextW259Fixture.build(part, mode)
    physical = CrystalClick::CompactPartPhysicalContext.open(part)
    granule = physical.read_window("alpha", 0, 1).granules.first
    block.call(physical, granule)
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w271_physical_selector_budget : CrystalClick::BinaryCodecBudget
  CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
end

describe "W271 Compact physical-prefix selector bridges" do
  it "selects root MRK4 grammar and fixed extents by canonical physical name only" do
    w271_with_physical_selector_fixture(CrystalClick::CompactMarkFormat::Mrk4) do |physical, granule|
      shards = granule.shards
      shards.size.should eq(2)
      (shards[0].stream_name || raise "W259 shared callback has no physical name").should eq("shared")
      (shards[1].stream_name || raise "W259 payload callback has no physical name").should eq("payload")
      shards[0].bytes.should eq(Bytes[0x61_u8, 0x30_u8])
      shards[1].bytes.should be_empty

      framer = CrystalClick::CompactJsonObjectSiteFramer.new(
        CrystalClick::CompactMarkFormat::Mrk4,
        shards,
        w271_physical_selector_budget,
        physical,
        "alpha:JSON/root.shared:occurrence-0",
      )

      # A raw name that matches the next physical event must not rescue a
      # different canonical name. The failed selection leaves it unconsumed.
      expect_raises(CrystalClick::CorruptPartError) do
        framer.with_physical_grammar_extent("raw.logical.shared", "shared") do |borrowed|
          {borrowed, borrowed.size}
        end
      end
      framer.position.should eq(0)

      # MRK4 grammar callbacks are exact extents: parser exceptions and short
      # extents must leave the same canonical event retryable.
      expect_raises(CrystalClick::CorruptPartError, /seeded parser failure/) do
        framer.with_physical_grammar_extent("shared", "raw.logical.shared") do |_borrowed|
          raise CrystalClick::CorruptPartError.new("seeded parser failure")
          {Bytes.empty, 0}
        end
      end
      framer.position.should eq(0)
      expect_raises(CrystalClick::CorruptPartError) do
        framer.with_physical_grammar_extent("shared", "raw.logical.shared") do |borrowed|
          {borrowed, borrowed.size - 1}
        end
      end
      framer.position.should eq(0)
      # Roster validation describes the physical schedule; finalization, not
      # roster presence, proves consumption. Rollback leaves no logical event.
      framer.validate_expected_events!(
        ["shared", "payload"],
        [] of String,
      )
      expect_raises(CrystalClick::CorruptPartError) { framer.finish! }

      value, shared = framer.with_physical_grammar_extent("shared", "raw.logical.shared") do |borrowed|
        {borrowed.size, borrowed.size}
      end
      value.should eq(2)
      shared.should eq(Bytes[0x61_u8, 0x30_u8])

      # The fixed callback is independently selected by physical name and
      # checked for exact size before either cursor or logical roster advances.
      expect_raises(CrystalClick::CorruptPartError) do
        framer.take_physical_exact("raw.logical.payload", "payload", 0)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        framer.take_physical_exact("payload", "raw.logical.payload", 1)
      end

      empty = framer.take_physical_exact("payload", "raw.logical.payload", 0)
      empty.should be_empty
      framer.validate_expected_events!(
        ["shared", "payload"],
        ["raw.logical.shared", "raw.logical.payload"],
      )
      framer.finish!
    end
  end

  it "clears only its recursive MRK4 reservation after parser failure and retains raw site names" do
    w271_with_physical_selector_fixture(CrystalClick::CompactMarkFormat::Mrk4) do |physical, granule|
      budget = w271_physical_selector_budget
      ledger = CrystalClick::CompactRecursiveJsonParentMarkLedger.new(
        physical,
        "alpha",
        granule,
        budget,
      )
      source = ledger.site_source("alpha:JSON/root.shared:occurrence-0")

      # Matching the next raw name does not select a missing physical event.
      expect_raises(CrystalClick::CorruptPartError) do
        source.with_physical_grammar_extent("missing.physical.shared", "shared") do |borrowed|
          {borrowed, borrowed.size}
        end
      end
      source.position.should eq(0)
      source.validate_expected_events!([] of String)

      # The ledger reserves a child event while the grammar callback runs.
      # Both parser exceptions and a partial extent must roll back this call's
      # reservation so the subsequent parse can retry the same source event.
      expect_raises(CrystalClick::CorruptPartError, /seeded parser failure/) do
        source.with_physical_grammar_extent("shared", "raw.logical.shared") do |_borrowed|
          raise CrystalClick::CorruptPartError.new("seeded parser failure")
          {Bytes.empty, 0}
        end
      end
      source.position.should eq(0)
      source.validate_expected_events!([] of String)
      expect_raises(CrystalClick::CorruptPartError) do
        source.with_physical_grammar_extent("shared", "raw.logical.shared") do |borrowed|
          {borrowed, borrowed.size - 1}
        end
      end
      source.position.should eq(0)
      source.validate_expected_events!([] of String)

      value, shared = source.with_physical_grammar_extent("shared", "raw.logical.shared") do |borrowed|
        {borrowed.size, borrowed.size}
      end
      value.should eq(2)
      shared.should eq(Bytes[0x61_u8, 0x30_u8])

      expect_raises(CrystalClick::CorruptPartError) do
        source.take_physical_exact("raw.logical.payload", "payload", 0)
      end
      source.position.should eq(2)
      expect_raises(CrystalClick::CorruptPartError) do
        source.take_physical_exact("payload", "raw.logical.payload", 1)
      end
      source.position.should eq(2)
      source.validate_expected_events!(["raw.logical.shared"])

      empty = source.take_physical_exact("payload", "raw.logical.payload", 0)
      empty.should be_empty
      source.position.should eq(2)
      source.validate_expected_events!(["raw.logical.shared", "raw.logical.payload"])

      source.begin_body_capture!
      ledger.finish_prefixes!
      ledger.begin_array_sizes!(0)
      ledger.finish_array_sizes!
      source.finish!
      expect_raises(CrystalClick::CorruptPartError) do
        ledger.finish_mark!(["raw.logical.shared", "raw.logical.payload"])
      end
      ledger.complete?.should be_false
      ledger.finish_mark!(["shared", "payload"])
      ledger.complete?.should be_true
    end
  end

  it "keeps MRK3 grammar and fixed extents positional while recording raw logical names" do
    w271_with_physical_selector_fixture(CrystalClick::CompactMarkFormat::Mrk3) do |_physical, granule|
      granule.shards.size.should eq(1)
      granule.shards.first.stream_name.should be_nil
      granule.shards.first.bytes.should eq("A0".to_slice)
      framer = CrystalClick::CompactJsonObjectSiteFramer.new(
        CrystalClick::CompactMarkFormat::Mrk3,
        granule.shards,
        w271_physical_selector_budget,
      )

      # The deliberately absent canonical name is not a selector in MRK3;
      # the parser's reported prefix is taken from the single positional tape.
      value, prefix = framer.with_physical_grammar_extent("not-a-physical-role", "raw.logical.prefix") do |tape|
        {tape[0], 1}
      end
      value.should eq('A'.ord.to_u8)
      prefix.should eq("A".to_slice)
      framer.position.should eq(1)

      tail = framer.take_physical_exact("also-not-a-physical-role", "raw.logical.tail", 1)
      tail.should eq("0".to_slice)
      framer.position.should eq(2)
      framer.validate_expected_events!(
        [] of String,
        ["raw.logical.prefix", "raw.logical.tail"],
      )
      framer.finish!
    end
  end
end
