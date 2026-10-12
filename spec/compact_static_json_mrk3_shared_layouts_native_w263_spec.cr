require "./spec_helper"
require "../scripts/support/compact_json_w263_fixture"
require "./support/compact_static_json_mrk3_shared_layouts_w263_fixture"

private def w263_mrk3_shared_layout_document_signature(document : CrystalClick::ObjectDocument) : String
  entries = document.paths.sort.map do |path|
    "#{path}=#{CompactJsonW263Fixture.value_signature(document.value_for(path))}"
  end
  "#{CompactJsonW263Fixture.json_type.name}{#{entries.join(",")}}"
end

private def w263_mrk3_shared_layout_native_literals : Array(String)
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

private def w263_assert_mrk3_shared_layout_prefixes(
  prepared : CrystalClick::CompactStaticJsonPreparedContext,
  expected_shared_version : UInt64,
) : Nil
  prepared.mark_count.should eq(4)
  prepared.mark_count.times do |index|
    prefix = prepared.object_prefix_bytes_at(index)
    context = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryCodecLimits.default, prefix)
    structure, statistics_offset = CrystalClick::ObjectStructureCodec.read_with_statistics_offset(context)
    context.ensure_consumed

    structure.version.should eq(4_u64)
    structure.shared_data_version.should eq(expected_shared_version)
    structure.bucket_count.should eq(2_u64)
    structure.dynamic_paths.should eq(["note", "sample"])
    statistics_offset.should eq(23)
    prepared.object_statistics_offset_at(index).should eq(statistics_offset)
    prefix.size.should eq(index == 0 ? 40 : 24)
    prepared.mark_row_count_at(index).should eq(2_u64)

    if index == 0
      statistics = structure.statistics || raise CrystalClick::CorruptPartError.new("native MRK3 mark zero omitted Object statistics")
      statistics.counts.should eq([8_u64, 8_u64])
      statistics.shared.map { |entry| {entry.name, entry.count} }.should eq([{ "zz_overflow", 8_u64 }])
    else
      structure.statistics.should be_nil
    end
  end
  nil
end

if ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]?
  describe "Compact static root-JSON native MRK3 shared layouts (W263)" do
    cases = [] of Tuple(String, UInt64)
    CompactStaticJsonMrk3SharedLayoutsW263Fixture::TARGET_LAYOUTS.each do |layout, shared_version|
      {0, 1}.each do |string_version|
        {"basic", "compact"}.each do |variant_mode|
          cases << {"#{layout}_mrk3_s#{string_version}_variant_#{variant_mode}", shared_version}
        end
      end
    end

    cases.size.should eq(12)
    case_labels = cases.map(&.[0])
    case_labels.sort.should eq(CompactStaticJsonMrk3SharedLayoutsW263Fixture.target_labels.sort)
    case_labels.count(&.includes?("_s0_")).should eq(6)
    case_labels.count(&.includes?("_s1_")).should eq(6)
    case_labels.count(&.includes?("_variant_basic")).should eq(6)
    case_labels.count(&.includes?("_variant_compact")).should eq(6)
    expected_native = w263_mrk3_shared_layout_native_literals
    expected_fixture = CompactJsonW263Fixture.root_values.map do |value|
      CompactJsonW263Fixture.value_signature(value)
    end
    root = CompactStaticJsonMrk3SharedLayoutsW263Fixture.evidence_root

    cases.each do |label, expected_shared_version|
      it "prepares and reads #{label} against its native inventory and independent literals" do
        source = CompactStaticJsonMrk3SharedLayoutsW263Fixture.source_part(root, label)
        part_path = source[:path]

        physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
        physical.mode.should eq(CrystalClick::CompactMarkFormat::Mrk3)
        physical.row_count.should eq(8_u64)
        physical.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
        physical.read_window("root", 0, 4).granules.size.should eq(4)

        reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
          part_path,
          "root",
          CompactJsonW263Fixture.json_type,
        )
        expected_profile = label.includes?("_s1_") ?
          CrystalClick::BinaryBulkProfile.with_size_stream :
          CrystalClick::BinaryBulkProfile.single_stream
        reader.ordinary_profile.should eq(expected_profile)
        reader.row_count.should eq(8_u64)
        reader.mark_count.should eq(4)
        reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])

        workspace_peak_estimate = 0_u64
        observe_workspace = ->(bytes : UInt64) do
          workspace_peak_estimate = bytes if bytes > workspace_peak_estimate
          nil
        end

        # EOF-first preparation must cover the full native mark grid even when
        # the requested selection itself is empty.
        reader.read_marks(reader.mark_count, 0, observe_workspace).should be_empty
        prepared = reader.prepared_context
        prepared.mark_count.should eq(4)
        w263_assert_mrk3_shared_layout_prefixes(prepared, expected_shared_version)
        reader.retained_workspace_bytes.should be > 0_u64
        workspace_peak_estimate.should be >= reader.retained_workspace_bytes

        # A late single mark, a range crossing marks, and then the complete
        # column exercise all native row coordinates after the EOF-first pass.
        selected = reader.read_marks(2, 1, observe_workspace)
        selected.size.should eq(1)
        selected[0].map { |document| w263_mrk3_shared_layout_document_signature(document) }
          .should eq(expected_native[4, 2])

        crossmark = reader.read_marks(1, 2, observe_workspace)
        crossmark.flatten.map { |document| w263_mrk3_shared_layout_document_signature(document) }
          .should eq(expected_native[2, 4])

        documents = reader.read_marks(0, reader.mark_count, observe_workspace).flatten
        actual = documents.map { |document| w263_mrk3_shared_layout_document_signature(document) }
        actual.should eq(expected_native)
        actual.should eq(expected_fixture)

        # Preserve exact IEEE-754 payloads as a separate oracle from JSON/text
        # equality and from the independent row signatures above.
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
        CompactStaticJsonMrk3SharedLayoutsW263Fixture.assert_native_inventory!(source)
      end
    end
  end
end
