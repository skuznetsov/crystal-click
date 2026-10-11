require "./spec_helper"
require "./support/compact_static_json_mrk3_w263_fixture"

if ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]?
  describe "Compact static root-JSON MRK3 MAP boundary adversary (W263)" do
    it "rejects a checksum-valid Object/Dynamic boundary mutation during EOF-first preparation" do
      source = CompactStaticJsonMrk3W263Fixture.source_part
      CompactJsonW263Fixture.assert_native_inventory!(source[:path], source[:inventory])

      temporary_root, copied_part = CompactStaticJsonMrk3W263Fixture.copy_part(source[:path])
      begin
        CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
        changed_root_start, changed_root_bytes = CompactStaticJsonMrk3W263Fixture.corrupt_first_object_path_count!(copied_part)
        changed_root_start.should be >= 0_i64
        changed_root_bytes.should eq(220)

        # The helper has already reopened the private part with a fresh
        # CompactPartPhysicalContext and read the mutated MRK3 window. This
        # assertion is about rejected grammar, not outer checksum or frame
        # transport integrity.
        reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
          copied_part,
          "root",
          CompactJsonW263Fixture.json_type,
        )
        reader.row_count.should eq(8_u64)
        reader.mark_count.should eq(4)

        expect_raises(CrystalClick::CorruptPartError) do
          reader.read_marks(reader.mark_count, 0)
        end
        expect_raises(ArgumentError, /has not completed EOF-first preparation/) do
          reader.prepared_context
        end
      ensure
        FileUtils.rm_rf(temporary_root)
      end
    end

    it "rejects a checksum-valid MAP shared-size mutation during EOF-first preparation" do
      source = CompactStaticJsonMrk3W263Fixture.source_part
      CompactJsonW263Fixture.assert_native_inventory!(source[:path], source[:inventory])

      temporary_root, copied_part = CompactStaticJsonMrk3W263Fixture.copy_part(source[:path])
      begin
        CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
        changed_root_start, changed_root_bytes = CompactStaticJsonMrk3W263Fixture.corrupt_first_map_size_count!(copied_part)
        changed_root_start.should be >= 0_i64
        changed_root_bytes.should eq(220)

        # The fixture helper rereads the modified root window after rebuilding
        # every compressed frame, global mark pair and outer checksum.
        reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
          copied_part,
          "root",
          CompactJsonW263Fixture.json_type,
        )
        reader.row_count.should eq(8_u64)
        reader.mark_count.should eq(4)

        expect_raises(CrystalClick::CorruptPartError) do
          reader.read_marks(reader.mark_count, 0)
        end
        expect_raises(ArgumentError, /has not completed EOF-first preparation/) do
          reader.prepared_context
        end
      ensure
        FileUtils.rm_rf(temporary_root)
      end
    end
  end
end
