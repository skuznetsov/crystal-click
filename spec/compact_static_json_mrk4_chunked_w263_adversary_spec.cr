require "./spec_helper"
require "../scripts/support/compact_json_w263_fixture"
require "./support/compact_static_json_w263_adversary_fixture"
require "./support/compact_static_json_mrk4_chunked_w263_fixture"

private def w263_chunked_adversary_document_signature(document : CrystalClick::ObjectDocument) : String
  entries = document.paths.sort.map do |path|
    "#{path}=#{CompactJsonW263Fixture.value_signature(document.value_for(path))}"
  end
  "#{CompactJsonW263Fixture.json_type.name}{#{entries.join(",")}}"
end

private def w263_chunked_adversary_expected_signatures : Array(String)
  type_name = CompactJsonW263Fixture.json_type.name
  [
    "#{type_name}{id=UInt8:1,label=String:\"json-1\",note=String:\"note-1\",sample=Int64:10,zz_overflow=String:\"overflow-1\"}",
    "#{type_name}{id=UInt8:2,label=String:\"json-2\",note=String:\"note-2\",sample=Float64:0x4004000000000000,zz_overflow=String:\"overflow-2\"}",
    "#{type_name}{id=UInt8:3,label=String:\"json-3\",note=String:\"note-3\",sample=Int64:30,zz_overflow=String:\"overflow-3\"}",
    "#{type_name}{id=UInt8:4,label=String:\"json-4\",note=String:\"note-4\",sample=Float64:0x4014000000000000,zz_overflow=String:\"overflow-4\"}",
    "#{type_name}{id=UInt8:5,label=String:\"json-5\",note=String:\"note-5\",sample=Int64:50,zz_overflow=String:\"overflow-5\"}",
    "#{type_name}{id=UInt8:6,label=String:\"json-6\",note=String:\"note-6\",sample=Float64:0x401e000000000000,zz_overflow=String:\"overflow-6\"}",
    "#{type_name}{id=UInt8:7,label=String:\"json-7\",note=String:\"note-7\",sample=Int64:70,zz_overflow=String:\"overflow-7\"}",
    "#{type_name}{id=UInt8:8,label=String:\"json-8\",note=String:\"note-8\",sample=Float64:0x4023000000000000,zz_overflow=String:\"overflow-8\"}",
  ]
end

if ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]?
  describe "Compact static root-JSON ADVANCED_CHUNKED adversaries (W263)" do
    it "rejects a malformed later chunk header during EOF-first preparation without publishing a holder" do
      source = CompactStaticJsonW263AdversaryFixture.source_part(
        CompactStaticJsonW263AdversaryFixture.evidence_root,
        CompactStaticJsonMrk4ChunkedW263Fixture::LABEL,
      )
      parent, copied_part = CompactStaticJsonW263AdversaryFixture.copy_part(source[:path])

      begin
        CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
        logical_offset, callback_size = CompactStaticJsonMrk4ChunkedW263Fixture.corrupt_late_structure_path_length!(copied_part)
        logical_offset.should eq(386_i64)
        callback_size.should eq(28)

        # Reopening physical data and marks succeeds after checksum refresh;
        # the contradiction is in the later selected logical chunk header.
        physical = CrystalClick::CompactPartPhysicalContext.open(copied_part)
        physical.row_count.should eq(8_u64)
        physical.mark_row_counts.should eq(CompactJsonW263Fixture::MARK_ROWS)
        physical.read_window("root", 0, physical.granule_count).granules.size.should eq(4)

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

    it "refuses a syntactically valid root callback reorder against the 30-event chunked roster" do
      source = CompactStaticJsonW263AdversaryFixture.source_part(
        CompactStaticJsonW263AdversaryFixture.evidence_root,
        CompactStaticJsonMrk4ChunkedW263Fixture::LABEL,
      )
      parent, copied_part = CompactStaticJsonW263AdversaryFixture.copy_part(source[:path])

      begin
        CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
        CompactStaticJsonMrk4ChunkedW263Fixture.assert_native_roster!(copied_part)
        CompactStaticJsonW263AdversaryFixture.swap_root_callbacks(copied_part)

        physical = CrystalClick::CompactPartPhysicalContext.open(copied_part)
        root_slots = physical.physical_roster.select { |slot| slot.column_name == "root" }
        root_slots.map do |slot|
          slot.stream_name || raise(CrystalClick::CorruptPartError.new("mrk4 root callback has no stream name"))
        end.should eq(CompactStaticJsonMrk4ChunkedW263Fixture::ROOT_EVENTS.map do |name|
          case name
          when "root.object_structure"
            "root.id"
          when "root.id"
            "root.object_structure"
          else
            name
          end
        end)

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

    it "prepares around a well-framed invalid shared tag and decodes only the selected later mark" do
      source = CompactStaticJsonW263AdversaryFixture.source_part(
        CompactStaticJsonW263AdversaryFixture.evidence_root,
        CompactStaticJsonMrk4ChunkedW263Fixture::LABEL,
      )
      parent, copied_part = CompactStaticJsonW263AdversaryFixture.copy_part(source[:path])

      begin
        CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
        logical_offset, callback_size = CompactStaticJsonMrk4ChunkedW263Fixture.corrupt_first_shared_value_tag!(copied_part)
        logical_offset.should eq(992_i64)
        callback_size.should eq(26)

        # The same logical intervals, marks and outer checksums reopen. The
        # invalid tag is nested inside a length-preserving shared-value frame.
        physical = CrystalClick::CompactPartPhysicalContext.open(copied_part)
        physical.row_count.should eq(8_u64)
        physical.mark_row_counts.should eq(CompactJsonW263Fixture::MARK_ROWS)
        values = physical.read_window("root", 0, 1).granules.first.shards.find do |shard|
          shard.stream_name == "root.object_shared_data.copy.values"
        end || raise "shared Copy values callback is absent"
        values.logical_start.should eq(logical_offset)
        values.logical_end.should eq(logical_offset + callback_size)
        values.byte_at(1).should eq(0xff_u8)

        reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
          copied_part,
          "root",
          CompactJsonW263Fixture.json_type,
        )
        reader.read_marks(reader.mark_count, 0).should be_empty

        expected = w263_chunked_adversary_expected_signatures
        later = reader.read_marks(3, 1)
        later.size.should eq(1)
        later[0].map { |document| w263_chunked_adversary_document_signature(document) }
          .should eq(expected[6, 2])

        expect_raises(CrystalClick::CorruptPartError) do
          reader.read_marks(0, 1)
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
