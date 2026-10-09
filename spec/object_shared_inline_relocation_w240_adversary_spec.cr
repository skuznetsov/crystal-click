require "spec"
require "../src/crystal_click/errors"
require "../src/crystal_click/binary_codec_limits"
require "../src/crystal_click/binary_codec_budget"
require "../src/crystal_click/object_shared_inline_callback_relocation"
require "../src/crystal_click/object_shared_advanced_inline_raw_layout"

private def w240ir_budget : CrystalClick::BinaryCodecBudget
  CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
end

private def w240ir_callbacks : Tuple(
  Array(Tuple(String, Bytes)),
  Array(Tuple(String, Bytes)),
)
  {
    [{".child.prefix", Bytes[1_u8]}] of Tuple(String, Bytes),
    [
      {".child.structure_suffix", Bytes.new(32, 0_u8)},
      {".child.data", Bytes[10_u8, 20_u8, 30_u8]},
    ] of Tuple(String, Bytes),
  }
end

private def w240ir_relocation(
  source_offset : UInt64 = 0_u64,
  target_offset : UInt64 = 0_u64,
  source_name : String = ".child.structure_suffix",
  target_name : String = ".child.data",
) : CrystalClick::ObjectSharedInlineCallbackRelocation
  CrystalClick::ObjectSharedInlineCallbackRelocation.new(
    source_name, source_offset, target_name, target_offset,
  )
end

describe "W240 adversary: explicit inline coordinate relocation ownership" do
  it "rejects empty callback identities and an overflowing sixteen-byte field" do
    expect_raises(ArgumentError) { w240ir_relocation(source_name: "") }
    expect_raises(ArgumentError) { w240ir_relocation(target_name: "") }
    expect_raises(ArgumentError) { w240ir_relocation(source_offset: UInt64::MAX - 15_u64) }
  end

  it "retains callback order and detaches caller and returned mutable payloads" do
    prefixes, bodies = w240ir_callbacks
    relocations = [w240ir_relocation] of CrystalClick::ObjectSharedInlineCallbackRelocation
    layout = CrystalClick::ObjectSharedAdvancedInlineRawLayout.new(prefixes, bodies, relocations, w240ir_budget)
    prefixes[0][1][0] = 99_u8
    bodies[1][1][0] = 99_u8
    relocations.clear

    layout.prefix_callbacks.map(&.[0]).should eq([".child.prefix"])
    layout.body_callbacks.map(&.[0]).should eq([".child.structure_suffix", ".child.data"])
    layout.prefix_callback_at(0)[1].should eq(Bytes[1_u8])
    layout.body_callback_at(1)[1].should eq(Bytes[10_u8, 20_u8, 30_u8])
    layout.relocation_count.should eq(1)

    returned = layout.body_callbacks
    returned[1][1][0] = 77_u8
    returned.clear
    layout.body_callback_count.should eq(2)
    layout.body_callback_at(1)[1].should eq(Bytes[10_u8, 20_u8, 30_u8])
    layout.relocation_at(0).target_callback.should eq(".child.data")
  end

  it "rejects a duplicate identity even when it crosses prefix and body schedules" do
    prefixes, bodies = w240ir_callbacks
    bodies << {".child.prefix", Bytes.empty}
    expect_raises(CrystalClick::UnsupportedFormatError, /duplicate callback/) do
      CrystalClick::ObjectSharedAdvancedInlineRawLayout.new(
        prefixes, bodies, [] of CrystalClick::ObjectSharedInlineCallbackRelocation, w240ir_budget,
      )
    end
  end

  it "requires both relocation callback identities to be present" do
    prefixes, bodies = w240ir_callbacks
    expect_raises(CrystalClick::UnsupportedFormatError, /source callback is absent/) do
      CrystalClick::ObjectSharedAdvancedInlineRawLayout.new(
        prefixes, bodies,
        [w240ir_relocation(source_name: ".other.suffix")] of CrystalClick::ObjectSharedInlineCallbackRelocation,
        w240ir_budget,
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError, /target callback is absent/) do
      CrystalClick::ObjectSharedAdvancedInlineRawLayout.new(
        prefixes, bodies,
        [w240ir_relocation(target_name: ".other.data")] of CrystalClick::ObjectSharedInlineCallbackRelocation,
        w240ir_budget,
      )
    end
  end

  it "admits the exact field and target terminals but rejects one byte beyond either" do
    prefixes, bodies = w240ir_callbacks
    terminal = w240ir_relocation(source_offset: 16_u64, target_offset: 3_u64)
    layout = CrystalClick::ObjectSharedAdvancedInlineRawLayout.new(
      prefixes, bodies, [terminal] of CrystalClick::ObjectSharedInlineCallbackRelocation, w240ir_budget,
    )
    layout.relocation_at(0).source_offset.should eq(16_u64)
    layout.relocation_at(0).target_offset.should eq(3_u64)

    expect_raises(CrystalClick::UnsupportedFormatError, /source field exceeds/) do
      CrystalClick::ObjectSharedAdvancedInlineRawLayout.new(
        prefixes, bodies,
        [w240ir_relocation(source_offset: 17_u64)] of CrystalClick::ObjectSharedInlineCallbackRelocation,
        w240ir_budget,
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError, /target exceeds/) do
      CrystalClick::ObjectSharedAdvancedInlineRawLayout.new(
        prefixes, bodies,
        [w240ir_relocation(target_offset: 4_u64)] of CrystalClick::ObjectSharedInlineCallbackRelocation,
        w240ir_budget,
      )
    end
  end

  it "rejects duplicate or partially overlapping coordinate fields" do
    prefixes, bodies = w240ir_callbacks
    [0_u64, 8_u64].each do |second_offset|
      expect_raises(CrystalClick::UnsupportedFormatError, /overlap|duplicate/) do
        CrystalClick::ObjectSharedAdvancedInlineRawLayout.new(
          prefixes, bodies,
          [w240ir_relocation, w240ir_relocation(source_offset: second_offset, target_offset: 1_u64)] of CrystalClick::ObjectSharedInlineCallbackRelocation,
          w240ir_budget,
        )
      end
    end
  end
end
