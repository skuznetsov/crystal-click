require "./support/compact_static_json_w263_adversary_fixture"

if ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]?
  describe "Compact MRK4 MAP root-JSON staging adversaries" do
    it "rejects a later corrupted selected frame on an EOF-first read while an earlier root mark stays readable" do
      label = "obj_v2_dyn_v2_map_mrk4_s0_variant_basic"
      source = CompactStaticJsonW263AdversaryFixture.source_part(
        CompactStaticJsonW263AdversaryFixture.evidence_root,
        label,
      )
      source_part = source[:path]
      corrupt_frame = CompactStaticJsonW263AdversaryFixture.selected_later_frame(source_part)
      parent, copied_part = CompactStaticJsonW263AdversaryFixture.copy_part(source_part)

      begin
        CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
        CompactPhysicalContextW259Fixture.corrupt_frame_payload(copied_part, corrupt_frame)

        # The helper refreshes checksums.txt after mutation. The earlier mark
        # remains a positive control while the later selected frame is corrupt.
        physical = CrystalClick::CompactPartPhysicalContext.open(copied_part)
        earlier = physical.read_window("root", 0, 1).granules
        earlier.size.should eq(1)
        earlier[0].row_count.should eq(CompactJsonW263Fixture::MARK_ROWS[0])

        reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
          copied_part,
          "root",
          CompactJsonW263Fixture.json_type,
        )
        reader.mark_count.should eq(4)
        observe_workspace = ->(_bytes : UInt64) { nil }
        expect_raises(CrystalClick::CorruptPartError, /compressed frame checksum mismatch/) do
          reader.read_marks(reader.mark_count, 0, observe_workspace)
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end

    it "refuses a valid root callback reorder using the exact sixteen-slot MAP roster before returning values" do
      label = "obj_v2_dyn_v2_map_mrk4_s0_variant_basic"
      source = CompactStaticJsonW263AdversaryFixture.source_part(
        CompactStaticJsonW263AdversaryFixture.evidence_root,
        label,
      )
      source_part = source[:path]

      original = CrystalClick::CompactPartPhysicalContext.open(source_part)
      original.mark_row_counts.should eq(CompactJsonW263Fixture::MARK_ROWS)
      original_root_streams = original.physical_roster
        .select { |slot| slot.column_name == "root" }
        .map do |slot|
          slot.stream_name || raise(CrystalClick::CorruptPartError.new("mrk4 root callback has no stream name"))
        end
      original_root_streams.size.should eq(16)
      original_root_streams[0].should eq("root.object_structure")
      original_root_streams[5].should eq("root.id")
      original_root_streams[13, 3].should eq([
        "root.object_shared_data.size0",
        "root.object_shared_data%2Epaths",
        "root.object_shared_data%2Evalues",
      ])

      parent, copied_part = CompactStaticJsonW263AdversaryFixture.copy_part(source_part)
      begin
        CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
        CompactStaticJsonW263AdversaryFixture.swap_root_callbacks(copied_part)

        # The metadata remains a complete physical roster; only its serialized
        # order disagrees with the selected Object callback traversal.
        physical = CrystalClick::CompactPartPhysicalContext.open(copied_part)
        physical.mark_row_counts.should eq(CompactJsonW263Fixture::MARK_ROWS)
        root_streams = physical.physical_roster
          .select { |slot| slot.column_name == "root" }
          .map do |slot|
            slot.stream_name || raise(CrystalClick::CorruptPartError.new("mrk4 root callback has no stream name"))
          end
        root_streams.size.should eq(16)
        root_streams[0].should eq("root.id")
        root_streams[5].should eq("root.object_structure")
        root_streams[13, 3].should eq(original_root_streams[13, 3])

        values_returned = false
        observe_workspace = ->(_bytes : UInt64) { nil }
        expect_raises(CrystalClick::CorruptPartError) do
          reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
            copied_part,
            "root",
            CompactJsonW263Fixture.json_type,
          )
          reader.mark_count.should eq(4)
          reader.read_marks(reader.mark_count, 0, observe_workspace)
          values = reader.read_marks(0, reader.mark_count, observe_workspace)
          values_returned = values.any? { |mark| !mark.empty? }
        end
        values_returned.should be_false
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
