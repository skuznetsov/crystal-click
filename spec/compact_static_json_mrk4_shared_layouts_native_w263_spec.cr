require "./spec_helper"
require "../scripts/support/compact_json_w263_fixture"
require "./support/compact_static_json_w263_adversary_fixture"

private def w263_shared_layout_document_signature(document : CrystalClick::ObjectDocument) : String
  entries = document.paths.sort.map do |path|
    "#{path}=#{CompactJsonW263Fixture.value_signature(document.value_for(path))}"
  end
  "#{CompactJsonW263Fixture.json_type.name}{#{entries.join(",")}}"
end

private def w263_shared_layout_native_literals : Array(String)
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

private def w263_assert_shared_layout_prefixes(
  prepared : CrystalClick::CompactStaticJsonPreparedContext,
  expected_shared_version : UInt64,
) : Nil
  prepared.mark_count.should eq(4)
  limits = CrystalClick::BinaryCodecLimits.default
  prepared.mark_count.times do |index|
    prefix = prepared.object_prefix_bytes_at(index)
    context = CrystalClick::BinaryCodecContext.new(limits, prefix)
    structure, statistics_offset = CrystalClick::ObjectStructureCodec.read_with_statistics_offset(context)
    context.ensure_consumed

    structure.version.should eq(4_u64)
    structure.shared_data_version.should eq(expected_shared_version)
    structure.bucket_count.should eq(2_u64)
    statistics_offset.should eq(23)
    prepared.object_statistics_offset_at(index).should eq(statistics_offset)
  end
  nil
end

if ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]?
  describe "Compact static root-JSON native MRK4 shared layouts (W263)" do
    cases = [] of Tuple(String, UInt64)
    {
      {"obj_v3_dyn_v3_map_with_buckets", 1_u64},
      {"obj_v3_dyn_v3_advanced", 2_u64},
    }.each do |layout, shared_version|
      {0, 1}.each do |string_version|
        {"basic", "compact"}.each do |variant_mode|
          cases << {"#{layout}_mrk4_s#{string_version}_variant_#{variant_mode}", shared_version}
        end
      end
    end

    cases.size.should eq(8)
    expected_native = w263_shared_layout_native_literals
    expected_fixture = CompactJsonW263Fixture.root_values.map do |value|
      CompactJsonW263Fixture.value_signature(value)
    end

    cases.each do |label, expected_shared_version|
      it "prepares and reads #{label} against native and fixture literals" do
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

        # An empty selection at physical EOF still prepares every mark.
        # This observes logical workspace accounting, not RSS.
        reader.read_marks(reader.mark_count, 0, observe_workspace).should be_empty
        prepared = reader.prepared_context
        prepared.mark_count.should eq(4)
        w263_assert_shared_layout_prefixes(prepared, expected_shared_version)
        reader.retained_workspace_bytes.should be > 0_u64
        workspace_peak_estimate.should be >= reader.retained_workspace_bytes

        # A one-mark read and a range crossing two physical marks must preserve
        # the stock row order independently of a subsequent full-column read.
        selected = reader.read_marks(2, 1, observe_workspace)
        selected.size.should eq(1)
        selected[0].map { |document| w263_shared_layout_document_signature(document) }
          .should eq(expected_native[4, 2])

        crossmark = reader.read_marks(1, 2, observe_workspace)
        crossmark.flatten.map { |document| w263_shared_layout_document_signature(document) }
          .should eq(expected_native[2, 4])

        documents = reader.read_marks(0, reader.mark_count, observe_workspace).flatten
        actual = documents.map { |document| w263_shared_layout_document_signature(document) }
        actual.should eq(expected_native)
        actual.should eq(expected_fixture)

        # Check Float64 bit patterns directly; textual/JSON equality alone is
        # not a sufficient oracle for these profile combinations.
        expected_float_bits = [
          0x4004_0000_0000_0000_u64,
          0x4014_0000_0000_0000_u64,
          0x401e_0000_0000_0000_u64,
          0x4023_0000_0000_0000_u64,
        ]
        float_bits = [] of UInt64
        documents.each_with_index do |document, index|
          sample = document.value_for("sample")
          if index.odd?
            sample.type.name.should eq("Float64")
            float_bits << sample.as_float64_bits
          else
            sample.type.name.should eq("Int64")
          end
        end
        float_bits.should eq(expected_float_bits)
        workspace_peak_estimate.should be >= reader.retained_workspace_bytes
      end
    end
  end
end
