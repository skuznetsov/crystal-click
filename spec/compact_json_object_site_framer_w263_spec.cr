require "./spec_helper"
require "../src/crystal_click/compact_json_object_site_framer"

private def w263_site_framer_shards(
  callbacks : Array(Tuple(String, Bytes)),
) : Array(CrystalClick::CompactPartPhysicalShard)
  logical_offset = 0_i64
  callbacks.map_with_index do |callback, slot_index|
    name, bytes = callback
    start = logical_offset
    logical_offset += bytes.size.to_i64
    CrystalClick::CompactPartPhysicalShard.new(
      slot_index.to_i32,
      name,
      start,
      logical_offset,
      bytes,
    )
  end
end

private def w263_site_framer(
  callbacks : Array(Tuple(String, Bytes)),
) : CrystalClick::CompactJsonObjectSiteFramer
  budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
  CrystalClick::CompactJsonObjectSiteFramer.new(
    CrystalClick::CompactMarkFormat::Mrk4,
    w263_site_framer_shards(callbacks),
    budget,
  )
end

describe "W263 Compact JSON Object site framer transaction contract" do
  it "preserves a named callback after a parser exception so the exact parse can retry" do
    bytes = Bytes[0x10_u8, 0x20_u8, 0x30_u8]
    source = w263_site_framer([{"object_structure", bytes}])

    expect_raises(CrystalClick::CorruptPartError, /seeded parser failure/) do
      source.with_self_delimited("object_structure") do |borrowed|
        if borrowed[0] == 0x10_u8
          raise CrystalClick::CorruptPartError.new("seeded parser failure")
        end
        {false, borrowed.size}
      end
    end

    source.with_self_delimited("object_structure") do |borrowed|
      borrowed.should eq(bytes)
      {borrowed[0], borrowed.size}
    end.should eq(0x10_u8)
    source.finish!
  end

  it "rejects partial, negative and oversized parser extents without consuming the callback" do
    bytes = Bytes[0, 1, 2, 3, 4, 5, 6, 7]
    {7, -1, 9}.each do |reported_consumption|
      source = w263_site_framer([{"object_structure", bytes}])
      expect_raises(CrystalClick::CorruptPartError) do
        source.with_self_delimited("object_structure") do |_borrowed|
          {false, reported_consumption}
        end
      end

      source.with_self_delimited("object_structure") do |borrowed|
        borrowed.should eq(bytes)
        {true, borrowed.size}
      end.should be_true
      source.finish!
    end
  end

  it "leaves the eight-byte fixed callback retryable after seven- or nine-byte requests" do
    bytes = Bytes[0, 1, 2, 3, 4, 5, 6, 7]
    {7, 9}.each do |requested_extent|
      source = w263_site_framer([{"variant_discr_prefix", bytes}])

      expect_raises(CrystalClick::CorruptPartError) do
        source.take_exact("variant_discr_prefix", requested_extent)
      end

      source.take_exact("variant_discr_prefix", 8).should eq(bytes)
      source.finish!
    end
  end

  it "rejects fixed and fragment re-entry while keeping the outer reservation after rescue" do
    structure = Bytes[0x31_u8, 0x32_u8]
    body = Bytes[0x41_u8, 0x42_u8]
    source = w263_site_framer([{"structure", structure}, {"body", body}])

    source.with_self_delimited("structure") do |borrowed|
      expect_raises(CrystalClick::CorruptPartError, /re-entrant/) do
        source.take_exact("body", body.size)
      end
      expect_raises(CrystalClick::CorruptPartError, /re-entrant/) do
        source.take_inline_fragment("body")
      end
      # The rescued inner failures must not release the outer parser's cursor
      # reservation or consume the following named callback.
      expect_raises(CrystalClick::CorruptPartError, /re-entrant/) do
        source.take_exact("body", body.size)
      end
      {borrowed[0], borrowed.size}
    end.should eq(0x31_u8)

    source.take_exact("body", body.size).should eq(body)
    source.finish!
  end
end
