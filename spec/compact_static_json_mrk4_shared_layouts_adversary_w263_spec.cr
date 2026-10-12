require "./spec_helper"
require "../scripts/support/compact_json_w263_fixture"
require "../scripts/support/compact_physical_context_w259_fixture"
require "./support/compact_static_json_w263_adversary_fixture"
require "./support/compact_static_json_mrk4_chunked_w263_fixture"
require "./support/compact_static_json_mrk4_shared_layouts_adversary_w263_fixture"

if ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]?
  describe "Compact static root-JSON MRK4 shared-layout adversaries (W263)" do
    fixture = CompactStaticJsonMrk4SharedLayoutsAdversaryW263Fixture

    # A reordered roster remains syntactically valid, so this checks the
    # exact callback manifest boundary instead of malformed metadata parsing.
    [CompactStaticJsonMrk4SharedLayoutsAdversaryW263Fixture::MAP_WITH_BUCKETS,
     CompactStaticJsonMrk4SharedLayoutsAdversaryW263Fixture::ADVANCED].each do |layout|
      {0, 1}.each do |string_version|
        {"basic", "compact"}.each do |variant|
          label = fixture.label(layout, string_version, variant)
          it "rejects root Object/id callback reordering for #{label}" do
            source = fixture.source_part(label)
            parent, copied_part = fixture.copy_part(source[:path])
            begin
              CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
              before = CrystalClick::CompactPartPhysicalContext.open(copied_part)
              original_names = fixture.assert_native_profile!(before, layout, string_version)
              structure_index = original_names.index("root.object_structure") || raise "Object callback is absent"
              id_index = original_names.index("root.id") || raise "id callback is absent"
              structure_index.should_not eq(id_index)

              CompactStaticJsonW263AdversaryFixture.swap_root_callbacks(copied_part)
              after = CrystalClick::CompactPartPhysicalContext.open(copied_part)
              expected_names = original_names.dup
              expected_names[structure_index] = "root.id"
              expected_names[id_index] = "root.object_structure"
              after.mode.mrk4?.should be_true
              after.row_count.should eq(8_u64)
              after.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
              after_names = after.physical_roster.select { |slot| slot.column_name == "root" }.map do |slot|
                slot.stream_name || raise(CrystalClick::CorruptPartError.new("mutated root callback has no stream name"))
              end
              after_names.should eq(expected_names)

              # Reordering metadata changes callback names, not the persisted
              # physical intervals or bytes. Do not parse a shard after its
              # Object bytes have deliberately been relabeled as `id`.
              before_marks = before.read_window("root", 0, before.granule_count).granules
              after_marks = after.read_window("root", 0, after.granule_count).granules
              after_marks.size.should eq(before_marks.size)
              before_marks.each_with_index do |before_mark, mark_index|
                after_mark = after_marks[mark_index]
                after_mark.shards.size.should eq(before_mark.shards.size)
                before_mark.shards.each_with_index do |before_shard, slot_index|
                  after_shard = after_mark.shards[slot_index]
                  expected_name = if slot_index == structure_index
                                    "root.id"
                                  elsif slot_index == id_index
                                    "root.object_structure"
                                  else
                                    before_shard.stream_name
                                  end
                  after_shard.stream_name.should eq(expected_name)
                  after_shard.logical_start.should eq(before_shard.logical_start)
                  after_shard.logical_end.should eq(before_shard.logical_end)
                  after_shard.bytes.should eq(before_shard.bytes)
                end
              end

              reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
                copied_part,
                "root",
                CompactJsonW263Fixture.json_type,
              )
              expect_raises(CrystalClick::CorruptPartError) do
                reader.read_marks(reader.mark_count, 0).should be_empty
              end
              expect_raises(ArgumentError) { reader.prepared_context }
            ensure
              FileUtils.rm_rf(parent)
            end
          end
        end
      end
    end

    [CompactStaticJsonMrk4SharedLayoutsAdversaryW263Fixture::MAP_WITH_BUCKETS,
     CompactStaticJsonMrk4SharedLayoutsAdversaryW263Fixture::ADVANCED].each do |layout|
      label = fixture.label(layout)
      it "rejects a malformed late #{layout} structure during EOF-first preparation" do
        source = fixture.source_part(label)
        parent, copied_part = fixture.copy_part(source[:path])
        begin
          CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
          original = CrystalClick::CompactPartPhysicalContext.open(copied_part)
          fixture.assert_native_profile!(original, layout, 0)

          # Reframe the pristine source first: ADVANCED has persisted
          # whole-data shared pairs in addition to the outer mrk4 grid.
          raw = fixture.reframe_pristine!(copied_part, layout)
          physical = CrystalClick::CompactPartPhysicalContext.open(copied_part)
          if layout == CompactStaticJsonMrk4SharedLayoutsAdversaryW263Fixture::MAP_WITH_BUCKETS
            shard = fixture.assert_callback_bytes!(
              physical,
              3,
              "root.object_structure",
              "040000000000000002046e6f74650673616d706c65010200",
            )
            relative_offset = 9
            shard.bytes[relative_offset].should eq(4_u8)
          else
            shard = fixture.assert_callback_bytes!(
              physical,
              3,
              "root.object_shared_data.1.structure_prefix",
              "02010b7a7a5f6f766572666c6f77",
            )
            relative_offset = 2
            shard.bytes[relative_offset].should eq(11_u8)
          end

          # Keep the callback extent and all persisted frame coordinates
          # unchanged; only the late structure's path-size byte is invalid.
          raw[shard.logical_start.to_i + relative_offset] = 127_u8
          reopened = fixture.write_same_geometry_tape!(copied_part, raw)
          changed = fixture.root_granule(reopened, 3).shards.find do |candidate|
            candidate.stream_name == shard.stream_name
          end || raise "mutated late structure callback is absent"
          changed.logical_start.should eq(shard.logical_start)
          changed.logical_end.should eq(shard.logical_end)
          changed.byte_at(relative_offset).should eq(127_u8)

          reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
            copied_part,
            "root",
            CompactJsonW263Fixture.json_type,
          )
          expect_raises(CrystalClick::CorruptPartError) do
            reader.read_marks(reader.mark_count, 0).should be_empty
          end
          expect_raises(ArgumentError) { reader.prepared_context }
        ensure
          FileUtils.rm_rf(parent)
        end
      end

      it "defers a well-framed shared String tag failure until the selected #{layout} mark" do
        source = fixture.source_part(label)
        parent, copied_part = fixture.copy_part(source[:path])
        begin
          CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
          original = CrystalClick::CompactPartPhysicalContext.open(copied_part)
          fixture.assert_native_profile!(original, layout, 0)
          raw = fixture.reframe_pristine!(copied_part, layout)
          physical = CrystalClick::CompactPartPhysicalContext.open(copied_part)
          stream_name = fixture.copy_stream_for(layout)
          value_shard = fixture.assert_callback_bytes!(
            physical,
            3,
            stream_name,
            "0c150a6f766572666c6f772d370c150a6f766572666c6f772d38",
          )
          value_shard.byte_at(1).should eq(CrystalClick::BinaryDataType::TAG_STRING)
          raw[value_shard.logical_start.to_i + 1] = 0xff_u8

          reopened = fixture.write_same_geometry_tape!(copied_part, raw)
          poisoned = fixture.assert_callback_bytes!(reopened, 3, stream_name, "0cff0a6f766572666c6f772d370c150a6f766572666c6f772d38")
          poisoned.logical_start.should eq(value_shard.logical_start)
          poisoned.logical_end.should eq(value_shard.logical_end)

          reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
            copied_part,
            "root",
            CompactJsonW263Fixture.json_type,
          )
          reader.read_marks(reader.mark_count, 0).should be_empty
          reader.prepared_context.mark_count.should eq(4)

          clean_mark = reader.read_marks(2, 1).first
          clean_mark.map { |document| document.value_for("id").byte_at(0) }.should eq([5_u8, 6_u8])
          clean_mark.map { |document| document.value_for("zz_overflow").as_string }
            .should eq(["overflow-5", "overflow-6"])

          expect_raises(CrystalClick::CorruptPartError) do
            reader.read_marks(3, 1)
          end
        ensure
          FileUtils.rm_rf(parent)
        end
      end

      it "rejects a late Object header outside the bounded two-bucket #{layout} profile" do
        source = fixture.source_part(label)
        parent, copied_part = fixture.copy_part(source[:path])
        begin
          CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
          original = CrystalClick::CompactPartPhysicalContext.open(copied_part)
          fixture.assert_native_profile!(original, layout, 0)
          raw = fixture.reframe_pristine!(copied_part, layout)
          physical = CrystalClick::CompactPartPhysicalContext.open(copied_part)
          object = fixture.root_granule(physical, 3).shards.find do |candidate|
            candidate.stream_name == "root.object_structure"
          end || raise "late Object structure callback is absent"
          shared_version = layout == CompactStaticJsonMrk4SharedLayoutsAdversaryW263Fixture::MAP_WITH_BUCKETS ? 1_u64 : 2_u64
          offset = fixture.object_bucket_count_offset!(object.bytes, shared_version)
          offset.should eq(22)
          raw[object.logical_start.to_i + offset].should eq(2_u8)
          raw[object.logical_start.to_i + offset] = 1_u8

          reopened = fixture.write_same_geometry_tape!(copied_part, raw)
          changed = fixture.root_granule(reopened, 3).shards.find do |candidate|
            candidate.stream_name == "root.object_structure"
          end || raise "changed Object structure callback is absent"
          changed.byte_at(offset).should eq(1_u8)
          context = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryCodecLimits.default, changed.bytes)
          structure, _statistics_offset = CrystalClick::ObjectStructureCodec.read_with_statistics_offset(context)
          context.ensure_consumed
          structure.bucket_count.should eq(1_u64)

          reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
            copied_part,
            "root",
            CompactJsonW263Fixture.json_type,
          )
          expect_raises(CrystalClick::UnsupportedFormatError) do
            reader.read_marks(reader.mark_count, 0).should be_empty
          end
          expect_raises(ArgumentError) { reader.prepared_context }
        ensure
          FileUtils.rm_rf(parent)
        end
      end
    end
  end
end
