require "./spec_helper"
require "../scripts/support/compact_json_w263_fixture"
require "./support/compact_static_json_w263_adversary_fixture"

private def w263_mrk4_map_native_document_signature(document : CrystalClick::ObjectDocument) : String
  entries = document.paths.sort.map do |path|
    "#{path}=#{CompactJsonW263Fixture.value_signature(document.value_for(path))}"
  end
  "#{CompactJsonW263Fixture.json_type.name}{#{entries.join(",")}}"
end

private def w263_assert_mrk4_map_native_statistics(
  prepared : CrystalClick::CompactStaticJsonPreparedContext,
) : Nil
  expected_object_sizes = {37, 24}
  expected_note_sizes = {19, 19}
  expected_sample_sizes = {27, 18}

  prepared.mark_count.should eq(4)
  prepared.mark_count.times do |index|
    object_prefix = prepared.object_prefix_bytes_at(index)
    object_prefix.size.should eq(expected_object_sizes[index == 0 ? 0 : 1])
    object_offset = prepared.object_statistics_offset_at(index)
    object_offset.should eq(21)
    object_prefix[object_offset, object_prefix.size - object_offset].hexstring.should eq(
      index == 0 ? "0808010b7a7a5f6f766572666c6f7708" : "000000"
    )
    object_head = object_prefix[0]
    object_prefix[0] ^= 0xff_u8
    prepared.object_prefix_bytes_at(index)[0].should eq(object_head)

    note_name = "root.note.dynamic_structure"
    note_prefix = prepared.dynamic_prefix_bytes_at(index, note_name)
    note_prefix.size.should eq(expected_note_sizes[index == 0 ? 0 : 1])
    note_offset = prepared.dynamic_statistics_offset_at(index, note_name)
    note_offset.should eq(16)
    note_prefix[note_offset, note_prefix.size - note_offset].hexstring.should eq(
      index == 0 ? "000800" : "000000"
    )
    note_head = note_prefix[0]
    note_prefix[0] ^= 0xff_u8
    prepared.dynamic_prefix_bytes_at(index, note_name)[0].should eq(note_head)

    sample_name = "root.sample.dynamic_structure"
    sample_prefix = prepared.dynamic_prefix_bytes_at(index, sample_name)
    sample_prefix.size.should eq(expected_sample_sizes[index == 0 ? 0 : 1])
    sample_offset = prepared.dynamic_statistics_offset_at(index, sample_name)
    sample_offset.should eq(15)
    sample_prefix[sample_offset, sample_prefix.size - sample_offset].hexstring.should eq(
      index == 0 ? "04040107466c6f6174363404" : "000000"
    )
    sample_head = sample_prefix[0]
    sample_prefix[0] ^= 0xff_u8
    prepared.dynamic_prefix_bytes_at(index, sample_name)[0].should eq(sample_head)
  end
  nil
end

if ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]?
  describe "Compact static root-JSON native MRK4 MAP reader (W263)" do
    it "prepares all eight native rows at EOF and decodes the literal selected and complete windows" do
      label = "obj_v2_dyn_v2_map_mrk4_s0_variant_basic"
      source = CompactStaticJsonW263AdversaryFixture.source_part(
        CompactStaticJsonW263AdversaryFixture.evidence_root,
        label,
      )
      part_path = source[:path]
      CompactJsonW263Fixture.assert_native_inventory!(part_path, source[:inventory])

      reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        part_path,
        "root",
        CompactJsonW263Fixture.json_type,
      )
      reader.row_count.should eq(8_u64)
      reader.mark_count.should eq(4)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])

      workspace_peak_estimate = 0_u64
      observe_workspace = ->(bytes : UInt64) do
        workspace_peak_estimate = bytes if bytes > workspace_peak_estimate
        nil
      end

      # An empty selection at physical EOF still authenticates and prepares
      # every selected physical mark. These logical workspace figures are
      # conservative estimates, not allocator capacity or RSS measurements.
      reader.read_marks(reader.mark_count, 0, observe_workspace).should be_empty
      prepared = reader.prepared_context
      prepared.mark_count.should eq(4)
      w263_assert_mrk4_map_native_statistics(prepared)
      reader.retained_grid_workspace_bytes.should be > 0_u64
      workspace_peak_estimate.should be >= reader.retained_workspace_bytes

      type_name = CompactJsonW263Fixture.json_type.name
      expected = [
        "#{type_name}{id=UInt8:1,label=String:\"json-1\",note=String:\"note-1\",sample=Int64:10,zz_overflow=String:\"overflow-1\"}",
        "#{type_name}{id=UInt8:2,label=String:\"json-2\",note=String:\"note-2\",sample=Float64:0x4004000000000000,zz_overflow=String:\"overflow-2\"}",
        "#{type_name}{id=UInt8:3,label=String:\"json-3\",note=String:\"note-3\",sample=Int64:30,zz_overflow=String:\"overflow-3\"}",
        "#{type_name}{id=UInt8:4,label=String:\"json-4\",note=String:\"note-4\",sample=Float64:0x4014000000000000,zz_overflow=String:\"overflow-4\"}",
        "#{type_name}{id=UInt8:5,label=String:\"json-5\",note=String:\"note-5\",sample=Int64:50,zz_overflow=String:\"overflow-5\"}",
        "#{type_name}{id=UInt8:6,label=String:\"json-6\",note=String:\"note-6\",sample=Float64:0x401e000000000000,zz_overflow=String:\"overflow-6\"}",
        "#{type_name}{id=UInt8:7,label=String:\"json-7\",note=String:\"note-7\",sample=Int64:70,zz_overflow=String:\"overflow-7\"}",
        "#{type_name}{id=UInt8:8,label=String:\"json-8\",note=String:\"note-8\",sample=Float64:0x4023000000000000,zz_overflow=String:\"overflow-8\"}",
      ]

      selected = reader.read_marks(2, 1, observe_workspace)
      selected.size.should eq(1)
      selected[0].map { |document| w263_mrk4_map_native_document_signature(document) }
        .should eq(expected[4, 2])

      actual = [] of String
      reader.read_marks(0, reader.mark_count, observe_workspace).each do |mark|
        mark.each do |document|
          actual << w263_mrk4_map_native_document_signature(document)
        end
      end
      actual.should eq(expected)
      workspace_peak_estimate.should be >= reader.retained_workspace_bytes
    end
  end
end
