require "./spec_helper"
require "../scripts/support/compact_json_w263_fixture"
require "./support/compact_static_json_mrk3_null_w263_fixture"

private def w263_mrk3_null_expect_corrupt_mutation(
  mark_index : Int32,
  tape_offset : Int32,
  expected_byte : UInt8,
  replacement_byte : UInt8,
  expected_logical_start : Int64,
  expected_tape_size : Int32,
) : Nil
  source = CompactStaticJsonMrk3NullW263Fixture.source_part(:basic)
  CompactJsonW263Fixture.assert_native_inventory!(source[:path], source[:inventory])
  original = CompactStaticJsonMrk3NullW263Fixture.raw_mark_evidence(source[:path], mark_index)
  original[:logical_start].should eq(expected_logical_start)
  original[:raw].size.should eq(expected_tape_size)
  original[:raw][tape_offset].should eq(expected_byte)

  temporary_root, copied_part = CompactStaticJsonMrk3NullW263Fixture.copy_part(source[:path])
  begin
    CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
    changed = CompactStaticJsonMrk3NullW263Fixture.mutate_tape_byte!(
      copied_part,
      mark_index,
      tape_offset,
      expected_byte,
      replacement_byte,
    )
    changed[:logical_start].should eq(expected_logical_start)
    changed[:tape_size].should eq(expected_tape_size)

    reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
      copied_part,
      "root",
      CompactStaticJsonMrk3NullW263Fixture.json_type,
    )
    reader.row_count.should eq(4_u64)
    reader.mark_count.should eq(2)
    reader.mark_row_counts.should eq([2_u64, 2_u64])
    expect_raises(CrystalClick::CorruptPartError) do
      reader.read_marks(reader.mark_count, 0)
    end
    expect_raises(ArgumentError, /has not completed EOF-first preparation/) do
      reader.prepared_context
    end
  ensure
    FileUtils.rm_rf(temporary_root)
    CompactJsonW263Fixture.assert_native_inventory!(source[:path], source[:inventory])
  end
end

if ENV["CRYSTAL_CLICK_W263_NULL_EVIDENCE_ROOT"]?
  describe "Compact static root-JSON MRK3 NULL Dynamic adversaries (W263)" do
    it "rejects a checksum-valid non-NULL tag outside the authenticated Dynamic roster" do
      # Mark 0 has String index 1 followed by NULL 255. 254 is neither the
      # observed String index nor the reserved NULL sentinel.
      w263_mrk3_null_expect_corrupt_mutation(0, 54, 1_u8, 254_u8, 16_i64, 78)
    end

    it "rejects an unknown Variant mode after transport authentication" do
      source = CompactStaticJsonMrk3NullW263Fixture.source_part(:basic)
      CompactJsonW263Fixture.assert_native_inventory!(source[:path], source[:inventory])
      original = CompactStaticJsonMrk3NullW263Fixture.raw_mark_evidence(source[:path], 0)
      original[:discriminator_headers].map { |name, bytes| {name, bytes.hexstring} }.should eq([
        {"root.maybe.variant_discr_prefix", "0000000000000000"},
      ])

      temporary_root, copied_part = CompactStaticJsonMrk3NullW263Fixture.copy_part(source[:path])
      begin
        CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
        changed = CompactStaticJsonMrk3NullW263Fixture.mutate_tape_byte!(
          copied_part,
          0,
          38,
          0_u8,
          2_u8,
        )
        changed[:logical_start].should eq(16_i64)
        changed[:tape_size].should eq(78)

        reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
          copied_part,
          "root",
          CompactStaticJsonMrk3NullW263Fixture.json_type,
        )
        expect_raises(CrystalClick::CorruptPartError) do
          reader.read_marks(reader.mark_count, 0)
        end
        expect_raises(ArgumentError, /has not completed EOF-first preparation/) do
          reader.prepared_context
        end
      ensure
        FileUtils.rm_rf(temporary_root)
        CompactJsonW263Fixture.assert_native_inventory!(source[:path], source[:inventory])
      end
    end

    it "rejects a late all-NULL mark corruption before publishing prepared state" do
      # Both rows in mark 1 carry 255. The first mark remains valid, so this
      # specifically requires EOF-first validation of the later mark.
      w263_mrk3_null_expect_corrupt_mutation(1, 54, 255_u8, 254_u8, 110_i64, 72)
    end

    it "prepares and reads the genuine stock COMPACT Variant sibling" do
      source = CompactStaticJsonMrk3NullW263Fixture.source_part(:compact)
      CompactJsonW263Fixture.assert_native_inventory!(source[:path], source[:inventory])
      evidence = CompactStaticJsonMrk3NullW263Fixture.raw_mark_evidence(source[:path], 0)
      evidence[:discriminator_headers].map { |name, bytes| {name, bytes.hexstring} }.should eq([
        {"root.maybe.variant_discr_prefix", "0100000000000000"},
      ])

      reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        source[:path],
        "root",
        CompactStaticJsonMrk3NullW263Fixture.json_type,
      )
      reader.row_count.should eq(4_u64)
      reader.mark_count.should eq(2)
      reader.mark_row_counts.should eq([2_u64, 2_u64])
      reader.read_marks(reader.mark_count, 0).should be_empty
      reader.prepared_context.mark_count.should eq(2)

      type_name = CompactStaticJsonMrk3NullW263Fixture.json_type.name
      expected = [
        "#{type_name}{id=UInt8:1,label=String:\"r1\",maybe=String:\"alpha\"}",
        "#{type_name}{id=UInt8:2,label=String:\"r2\"}",
        "#{type_name}{id=UInt8:3,label=String:\"r3\"}",
        "#{type_name}{id=UInt8:4,label=String:\"r4\"}",
      ]
      actual = [] of String
      reader.read_marks(0, reader.mark_count).each do |mark|
        mark.each do |document|
          entries = document.paths.sort.map do |path|
            "#{path}=#{CompactJsonW263Fixture.value_signature(document.value_for(path))}"
          end
          actual << "#{type_name}{#{entries.join(",")}}"
        end
      end
      actual.should eq(expected)
    end
  end
end
