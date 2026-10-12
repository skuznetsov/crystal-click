require "./spec_helper"
require "../scripts/support/compact_json_w263_fixture"
require "./support/compact_static_json_mrk3_shared_layouts_w263_fixture"
require "./support/compact_static_json_mrk3_shared_layouts_adversary_w263_fixture"

private def w263_mrk3_shared_adversary_document_signature(
  document : CrystalClick::ObjectDocument,
) : String
  entries = document.paths.sort.map do |path|
    "#{path}=#{CompactJsonW263Fixture.value_signature(document.value_for(path))}"
  end
  "#{CompactJsonW263Fixture.json_type.name}{#{entries.join(",")}}"
end

private def w263_mrk3_shared_adversary_native_literals : Array(String)
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

private def w263_mrk3_shared_adversary_publish_prepared_owner(capture)
  CrystalClick::CompactStaticJsonAdvancedPreparedMark.prepare_from_source(
    capture[:prefix],
    capture[:physical_plan],
    capture[:grid],
    capture[:budget],
    capture[:schedule].body_bindings,
    capture[:schedule].body_pairs,
    capture[:statistics_offsets],
    capture[:profile],
    capture[:framer],
  )
end

private def w263_mrk3_shared_adversary_assert_pristine_full_root!(
  part_path : String,
  inventory : Array(Tuple(String, Int64, String)),
) : Nil
  physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
  physical.mode.should eq(CrystalClick::CompactMarkFormat::Mrk3)
  physical.row_count.should eq(8_u64)
  physical.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])

  reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
    part_path,
    "root",
    CompactJsonW263Fixture.json_type,
  )
  reader.ordinary_profile.should eq(CrystalClick::BinaryBulkProfile.single_stream)
  reader.row_count.should eq(8_u64)
  reader.mark_count.should eq(4)
  reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])

  reader.read_marks(reader.mark_count, 0).should be_empty
  reader.prepared_context.mark_count.should eq(4)
  native_literals = w263_mrk3_shared_adversary_native_literals
  selected = reader.read_marks(2, 1).flatten
  selected.map { |document| w263_mrk3_shared_adversary_document_signature(document) }
    .should eq(native_literals[4, 2])
  crossmark = reader.read_marks(1, 2).flatten
  crossmark.map { |document| w263_mrk3_shared_adversary_document_signature(document) }
    .should eq(native_literals[2, 4])
  documents = reader.read_marks(0, reader.mark_count).flatten
  actual = documents.map { |document| w263_mrk3_shared_adversary_document_signature(document) }
  actual.should eq(native_literals)
  actual.should eq(CompactJsonW263Fixture.root_values.map { |value| CompactJsonW263Fixture.value_signature(value) })

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
  CompactJsonW263Fixture.assert_native_inventory!(part_path, inventory)
  nil
end

if ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]?
  describe "Compact static root-JSON MRK3 shared-layout adversaries (W263)" do
    cases = CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture::ROOT_LABELS
    cases.size.should eq(3)
    cases.each do |label, shared_version|
      it "rejects a late legal Object shared-version transition in #{label}" do
        source = CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture.source_part(label)
        temporary_root, copied_part = CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture.copy_part(source[:path])
        begin
          CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
          w263_mrk3_shared_adversary_assert_pristine_full_root!(copied_part, source[:inventory])
          replacement = shared_version == 1_u64 ? 2_u64 : 1_u64
          CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture.poison_late_object_version!(
            copied_part,
            shared_version,
            replacement,
          )

          reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
            copied_part,
            "root",
            CompactJsonW263Fixture.json_type,
          )
          expect_raises(CrystalClick::CorruptPartError) do
            reader.read_marks(reader.mark_count, 0)
          end
          expect_raises(ArgumentError, /has not completed EOF-first preparation/) do
            reader.prepared_context
          end
        ensure
          FileUtils.rm_rf(temporary_root)
          CompactStaticJsonMrk3SharedLayoutsW263Fixture.assert_native_inventory!(source)
        end
      end

      it "fails closed on a transport-valid one-bucket schedule outside the sealed MRK3 scope in #{label}" do
        source = CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture.source_part(label)
        temporary_root, copied_part = CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture.copy_part(source[:path])
        begin
          CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
          w263_mrk3_shared_adversary_assert_pristine_full_root!(copied_part, source[:inventory])
          CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture.poison_bucket_count_to_one!(
            copied_part,
            shared_version,
          )

          reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
            copied_part,
            "root",
            CompactJsonW263Fixture.json_type,
          )
          # The one-bucket Object prefix is legal metadata, but root MRK3
          # schedules are sealed to two buckets for shared versions 1–3.
          # This refusal occurs before body framing; it is not evidence that
          # the unchanged body was validated against the contradictory roster.
          expect_raises(CrystalClick::UnsupportedFormatError, /sealed bucket counts/) do
            reader.read_marks(reader.mark_count, 0)
          end
          expect_raises(ArgumentError, /has not completed EOF-first preparation/) do
            reader.prepared_context
          end
        ensure
          FileUtils.rm_rf(temporary_root)
          CompactStaticJsonMrk3SharedLayoutsW263Fixture.assert_native_inventory!(source)
        end
      end

      it "defers both poisoned final-mark String envelopes until mark decode in #{label}" do
        source = CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture.source_part(label)
        temporary_root, copied_part = CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture.copy_part(source[:path])
        begin
          CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
          w263_mrk3_shared_adversary_assert_pristine_full_root!(copied_part, source[:inventory])
          CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture.poison_late_string_envelope!(
            copied_part,
            shared_version,
          )

          physical = CrystalClick::CompactPartPhysicalContext.open(copied_part)
          physical.mode.should eq(CrystalClick::CompactMarkFormat::Mrk3)
          physical.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
          physical.read_window("root", 3, 1).granules.size.should eq(1)
          reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
            copied_part,
            "root",
            CompactJsonW263Fixture.json_type,
          )
          reader.read_marks(reader.mark_count, 0).should be_empty
          reader.prepared_context.mark_count.should eq(4)

          clean = reader.read_marks(2, 1).flatten
          clean.map { |document| w263_mrk3_shared_adversary_document_signature(document) }
            .should eq(w263_mrk3_shared_adversary_native_literals[4, 2])
          clean[1].value_for("sample").as_float64_bits.should eq(0x401e_0000_0000_0000_u64)

          expect_raises(CrystalClick::CorruptPartError) do
            reader.read_marks(3, 1)
          end
          reader.prepared_context.mark_count.should eq(4)
        ensure
          FileUtils.rm_rf(temporary_root)
          CompactStaticJsonMrk3SharedLayoutsW263Fixture.assert_native_inventory!(source)
        end
      end
    end

    provenance_label = CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture::ROOT_LABELS[2][0]
    provenance_source = CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture.source_part(provenance_label)
    it "publishes a prepared owner only from the authenticated selected root mark using its exact budget" do
      CompactJsonW263Fixture.assert_native_inventory!(provenance_source[:path], provenance_source[:inventory])
      capture = CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture.prepared_root_capture(provenance_source[:path])
      capture[:physical].mode.should eq(CrystalClick::CompactMarkFormat::Mrk3)
      capture[:schedule].advanced.should be_true
      owner = w263_mrk3_shared_adversary_publish_prepared_owner(capture)
      owner.logical_row_count.should eq(2_u64)

      equal_limits_but_foreign_operation = CrystalClick::BinaryCodecBudget.new(
        CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      )
      expect_raises(ArgumentError, /exact capture budget operation/) do
        capture[:framer].validate_prepared_source!(
          capture[:prefix],
          capture[:physical_plan],
          capture[:schedule].body_bindings,
          capture[:schedule].body_pairs,
          equal_limits_but_foreign_operation,
        )
      end
      CompactStaticJsonMrk3SharedLayoutsW263Fixture.assert_native_inventory!(provenance_source)
    end

    it "rejects authenticated mark-zero bytes labeled as another in-grid mark before callback checks" do
      CompactJsonW263Fixture.assert_native_inventory!(provenance_source[:path], provenance_source[:inventory])
      capture = CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture.prepared_root_capture(
        provenance_source[:path],
        0,
        "root:mark=1",
      )
      expect_raises(
        CrystalClick::CorruptPartError,
        /Compact MRK3 prepared site is not bound to its selected root mark slot/,
      ) do
        w263_mrk3_shared_adversary_publish_prepared_owner(capture)
      end
      CompactStaticJsonMrk3SharedLayoutsW263Fixture.assert_native_inventory!(provenance_source)
    end

    it "rejects authenticated bytes from the docs slot when published as the root mark" do
      CompactJsonW263Fixture.assert_native_inventory!(provenance_source[:path], provenance_source[:inventory])
      capture = CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture.prepared_root_capture(provenance_source[:path])
      docs_framer = CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture.diagnostic_column_framer(
        capture[:physical],
        "docs",
        0,
        "root:mark=0",
        capture[:budget],
      )
      wrong_column_capture = {
        physical:           capture[:physical],
        granule:            capture[:granule],
        budget:             capture[:budget],
        framer:             docs_framer,
        prefix:             capture[:prefix],
        physical_plan:      capture[:physical_plan],
        schedule:           capture[:schedule],
        statistics_offsets: capture[:statistics_offsets],
        grid:               capture[:grid],
        profile:            capture[:profile],
      }
      expect_raises(
        CrystalClick::CorruptPartError,
        /Compact MRK3 prepared site is not bound to its selected root mark slot/,
      ) do
        w263_mrk3_shared_adversary_publish_prepared_owner(wrong_column_capture)
      end
      CompactStaticJsonMrk3SharedLayoutsW263Fixture.assert_native_inventory!(provenance_source)
    end

    it "rejects a canonical out-of-grid mark label before callback checks" do
      CompactJsonW263Fixture.assert_native_inventory!(provenance_source[:path], provenance_source[:inventory])
      capture = CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture.prepared_root_capture(
        provenance_source[:path],
        0,
        "root:mark=4",
      )
      expect_raises(
        CrystalClick::CorruptPartError,
        /Compact MRK3 prepared site is not bound to its selected root mark slot/,
      ) do
        w263_mrk3_shared_adversary_publish_prepared_owner(capture)
      end
      CompactStaticJsonMrk3SharedLayoutsW263Fixture.assert_native_inventory!(provenance_source)
    end

    it "keeps unauthenticated diagnostics uncharged for positional provenance and unable to publish" do
      CompactJsonW263Fixture.assert_native_inventory!(provenance_source[:path], provenance_source[:inventory])
      authenticated = CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture.prepared_root_capture(provenance_source[:path])
      diagnostic = CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture.prepared_root_capture(
        provenance_source[:path],
        authenticated: false,
      )
      events = authenticated[:schedule].event_names.size.to_i64
      (authenticated[:budget].node_count - diagnostic[:budget].node_count).should eq(events)
      (authenticated[:budget].element_count - diagnostic[:budget].element_count).should eq(events)
      authenticated[:prefix].body_callback_slice_count.should eq(diagnostic[:prefix].body_callback_slice_count)
      authenticated_slice_bytes = 0_i64
      diagnostic_slice_bytes = 0_i64
      authenticated[:prefix].body_callback_slice_count.times do |index|
        authenticated_slice_bytes += authenticated[:prefix].body_callback_slice_at(index).byte_size.to_i64
        diagnostic_slice_bytes += diagnostic[:prefix].body_callback_slice_at(index).byte_size.to_i64
      end
      authenticated_slice_bytes.should eq(diagnostic_slice_bytes)
      (authenticated[:budget].wire_byte_count - diagnostic[:budget].wire_byte_count)
        .should eq(authenticated_slice_bytes)

      expect_raises(CrystalClick::CorruptPartError, /no authenticated coordinate context/) do
        w263_mrk3_shared_adversary_publish_prepared_owner(diagnostic)
      end
      CompactStaticJsonMrk3SharedLayoutsW263Fixture.assert_native_inventory!(provenance_source)
    end

    it "leaves MRK3 cursor and positional counters untouched when either roster preflight fails" do
      physical = CrystalClick::CompactPartPhysicalContext.open(provenance_source[:path])
      physical.mode.should eq(CrystalClick::CompactMarkFormat::Mrk3)
      granule = physical.read_window("root", 0, 1).granules.first? ||
                raise CrystalClick::CorruptPartError.new("native MRK3 root mark is missing")

      {
        {0, 1, /binary codec node limit exceeded/},
        {1, 0, /binary codec element limit exceeded/},
      }.each do |max_nodes, max_elements, diagnostic|
        limits = CrystalClick::BinaryCodecLimits.new(
          max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
          max_nodes: max_nodes,
          max_elements: max_elements,
          max_bytes: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_BYTES,
        )
        budget = CrystalClick::BinaryCodecBudget.new(limits)
        framer = CrystalClick::CompactJsonObjectSiteFramer.new(
          physical.mode,
          granule.shards,
          budget,
          physical,
          "root:mark=0",
        )
        expect_raises(CrystalClick::CorruptPartError, diagnostic) do
          framer.with_grammar_extent("preflight_probe") { |_remaining| {nil, 0} }
        end
        framer.position.should eq(0)
        framer.remaining.should eq(granule.shards[0].bytes.size)
        framer.validate_expected_events!([] of String)
        budget.node_count.should eq(0_i64)
        budget.element_count.should eq(0_i64)
      end
      CompactStaticJsonMrk3SharedLayoutsW263Fixture.assert_native_inventory!(provenance_source)
    end
  end
end
