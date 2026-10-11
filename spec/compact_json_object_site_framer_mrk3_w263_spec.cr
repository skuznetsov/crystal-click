require "./spec_helper"
require "../src/crystal_click/compact_json_object_site_framer"

private def w263_mrk3_site_framer(bytes : Bytes) : CrystalClick::CompactJsonObjectSiteFramer
  shard = CrystalClick::CompactPartPhysicalShard.new(
    0,
    nil,
    0_i64,
    bytes.size.to_i64,
    bytes,
  )
  budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
  CrystalClick::CompactJsonObjectSiteFramer.new(
    CrystalClick::CompactMarkFormat::Mrk3,
    [shard],
    budget,
  )
end

describe "W263 Compact JSON MRK3 grammar transaction" do
  it "retries after a parser exception and commits only the reported prefix" do
    tape = Bytes[0x10_u8, 0x20_u8, 0x30_u8, 0x40_u8]
    source = w263_mrk3_site_framer(tape)

    expect_raises(CrystalClick::CorruptPartError, /seeded parser failure/) do
      source.with_grammar_extent("object_structure") do |borrowed|
        if borrowed[0] == 0x10_u8
          raise CrystalClick::CorruptPartError.new("seeded parser failure")
        else
          {borrowed[0], 2_i32}
        end
      end
    end
    source.position.should eq(0)
    source.remaining.should eq(tape.size)

    value, prefix = source.with_grammar_extent("object_structure") do |borrowed|
      {borrowed[0], 2}
    end
    value.should eq(0x10_u8)
    prefix.should eq(tape[0, 2])
    source.position.should eq(2)
    source.remaining.should eq(2)

    tail, exact_tail = source.with_grammar_extent("root.id") do |borrowed|
      {borrowed[0], borrowed.size}
    end
    tail.should eq(0x30_u8)
    exact_tail.should eq(tape[2, 2])
    source.validate_expected_events!(["object_structure", "root.id"])
    source.finish!
  end

  it "rejects negative and overrun parser counts without changing position or logical schedule" do
    tape = Bytes[0x51_u8, 0x52_u8, 0x53_u8]
    {-1, 4}.each do |reported_count|
      source = w263_mrk3_site_framer(tape)
      expect_raises(CrystalClick::CorruptPartError) do
        source.with_grammar_extent("object_structure") do |_borrowed|
          {false, reported_count}
        end
      end
      source.position.should eq(0)
      source.remaining.should eq(tape.size)
      source.validate_expected_events!([] of String)

      _value, prefix = source.with_grammar_extent("object_structure") do |borrowed|
        {true, borrowed.size}
      end
      prefix.should eq(tape)
      source.validate_expected_events!(["object_structure"])
      source.finish!
    end
  end

  it "keeps zero-byte scheduled callbacks distinct from trailing tape" do
    tape = Bytes[0x61_u8]
    source = w263_mrk3_site_framer(tape)

    empty, empty_bytes = source.with_grammar_extent("empty_body") do |_borrowed|
      {nil, 0}
    end
    empty.should be_nil
    empty_bytes.should be_empty
    source.position.should eq(0)

    _value, body = source.with_grammar_extent("root.id") do |borrowed|
      {borrowed[0], borrowed.size}
    end
    body.should eq(tape)
    source.validate_expected_events!(["empty_body", "root.id"])
    source.finish!
  end

  it "rejects nested reads while the outer grammar parser remains reserved" do
    tape = Bytes[0x71_u8, 0x72_u8, 0x73_u8]
    source = w263_mrk3_site_framer(tape)

    value, prefix = source.with_grammar_extent("object_structure") do |borrowed|
      expect_raises(CrystalClick::CorruptPartError, /re-entrant/) do
        source.with_grammar_extent("root.id") { |nested| {nested[0], 1} }
      end
      expect_raises(CrystalClick::CorruptPartError, /re-entrant/) do
        source.take_exact("variant_discr_prefix", 1)
      end
      {borrowed[0], 2}
    end
    value.should eq(0x71_u8)
    prefix.should eq(tape[0, 2])

    _tail_value, tail = source.with_grammar_extent("root.id") do |borrowed|
      {borrowed[0], borrowed.size}
    end
    tail.should eq(Bytes[0x73_u8])
    source.validate_expected_events!(["object_structure", "root.id"])
    source.finish!
  end

  it "rejects exact-callback and whole-remainder APIs for an unlabelled MRK3 tape" do
    tape = Bytes[0x81_u8, 0x82_u8]
    source = w263_mrk3_site_framer(tape)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      source.with_self_delimited("object_structure") do |borrowed|
        {borrowed, borrowed.size}
      end
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      source.take_inline_fragment("object_structure")
    end
    source.position.should eq(0)
    source.remaining.should eq(tape.size)

    _value, exact_tape = source.with_grammar_extent("object_structure") do |borrowed|
      {borrowed, borrowed.size}
    end
    exact_tape.should eq(tape)
    source.finish!
  end

  it "rejects truncated fixed extents and leftover tape without consuming either" do
    tape = Bytes[0x91_u8, 0x92_u8, 0x93_u8]
    source = w263_mrk3_site_framer(tape)

    expect_raises(CrystalClick::CorruptPartError) do
      source.take_exact("variant_discr_prefix", 8)
    end
    source.position.should eq(0)

    _value, prefix = source.with_grammar_extent("object_structure") do |borrowed|
      {borrowed[0], 2}
    end
    prefix.should eq(tape[0, 2])
    expect_raises(CrystalClick::CorruptPartError) { source.finish! }
    source.position.should eq(2)

    _tail_value, tail = source.with_grammar_extent("root.id") do |borrowed|
      {borrowed[0], borrowed.size}
    end
    tail.should eq(Bytes[0x93_u8])
    source.finish!
  end
end
