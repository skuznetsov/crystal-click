require "./spec_helper"
require "../scripts/support/compact_json_w263_fixture"
require "./support/compact_static_json_w263_adversary_fixture"
require "./support/compact_static_json_mrk4_chunked_w263_fixture"

private def w263_advanced_prepared_document_signature(document : CrystalClick::ObjectDocument) : String
  entries = document.paths.sort.map do |path|
    "#{path}=#{CompactJsonW263Fixture.value_signature(document.value_for(path))}"
  end
  "#{CompactJsonW263Fixture.json_type.name}{#{entries.join(",")}}"
end

private def w263_advanced_prepared_source_capture(
  part_path : String,
  mark_index : Int32,
  shared_budget : CrystalClick::BinaryCodecBudget? = nil,
  complete_capture : Bool = true,
)
  type = CompactJsonW263Fixture.json_type
  limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
  budget = shared_budget || CrystalClick::BinaryCodecBudget.new(limits)
  physical = CompactStaticJsonMrk4ChunkedW263Fixture.assert_native_roster!(part_path)
  window = physical.read_window("root", mark_index, 1)
  granule = window.granules.first? || raise "selected native mark is absent"
  granule.mark.should eq(mark_index)

  site_identity = "root:mark=#{mark_index}"
  framer = CrystalClick::CompactJsonObjectSiteFramer.new(
    physical.mode,
    granule.shards,
    budget,
    physical,
    site_identity,
  )
  profile_reader = CrystalClick::CompactStaticJsonBulkColumnReader.open("#{part_path}", "root", type)
  profile = profile_reader.ordinary_profile
  manifest = CrystalClick::CompactStaticJsonSiteManifest.new("root", type)
  observed_dynamic_offsets = Hash(String, Int32).new
  observe_statistics = ->(name : String, offset : Int32) do
    observed_dynamic_offsets[name] = offset
    nil
  end
  prefix = CrystalClick::ObjectDocumentCallbackPrefixReader.read_static_json_prefix(
    framer,
    type,
    1_i32,
    manifest.physical_prefix,
    manifest.callback_prefix,
    0_u64,
    CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile),
    budget,
    true,
    observe_statistics,
  )
  physical_plan = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
    manifest.physical_prefix,
    prefix.plan,
    profile,
    CrystalClick::BinaryBulkProfile.single_stream,
    limits,
    prefix.array_level,
    typed_descriptor_root_depth: prefix.typed_descriptor_root_depth,
    inferred_actual_root_depth: prefix.inferred_actual_root_depth,
    root_dynamic_json_budget: budget,
  )
  prefix.bind_physical_plan!(physical_plan)
  schedule = CrystalClick::CompactJsonObjectRoleSchedule.build(prefix, physical_plan, profile, budget)
  schedule.advanced.should be_true

  prefix.start_body_capture!
  schedule.body_pairs.each do |canonical_name, callback_name|
    prefix.capture_body_callback_from!(canonical_name, callback_name, budget) do
      framer.take_inline_fragment_slice(canonical_name, callback_name)
    end
  end
  prefix.finish_body_capture!(schedule.body_pairs.size)
  framer.validate_expected_events!(schedule.event_names)
  framer.finish! if complete_capture

  statistics_offsets = Hash(String, Int32).new
  observed_dynamic_offsets.each { |name, offset| statistics_offsets[name] = offset }
  object_callback = CrystalClick::PhysicalStreamName.append_literal(manifest.callback_prefix, ".object_structure")
  statistics_offsets[object_callback] = prefix.object_structure_statistics_offset
  grid = CrystalClick::StorageOccurrenceGrid.new(
    [granule.row_count] of UInt64,
    [granule.row_count] of UInt64,
    budget,
  )

  {
    physical:           physical,
    budget:             budget,
    framer:             framer,
    prefix:             prefix,
    physical_plan:      physical_plan,
    schedule:           schedule,
    statistics_offsets: statistics_offsets,
    grid:               grid,
    profile:            profile,
    row_count:          granule.row_count,
  }
end

if ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]?
  describe "Compact static JSON ADVANCED prepared-mark source owner (W263)" do
    # Negative compilation witness for the source-bound constructor. Both
    # captures are independently authenticated and share one budget, but the
    # attempted owner mixes A's ordinary streams with B's prepared holder.
    {% if flag?(:w263_compact_advanced_mark_constructor_attack) %}
      it "rejects direct construction from cross-source components" do
        source = CompactStaticJsonW263AdversaryFixture.source_part(
          CompactStaticJsonW263AdversaryFixture.evidence_root,
          CompactStaticJsonMrk4ChunkedW263Fixture::LABEL,
        )
        part_path = source[:path]
        CompactJsonW263Fixture.assert_native_inventory!(part_path, source[:inventory])

        copy_parent, foreign_part = CompactStaticJsonW263AdversaryFixture.copy_part(part_path)
        begin
          CompactJsonW263Fixture.assert_native_inventory!(foreign_part, source[:inventory])
          original = w263_advanced_prepared_source_capture(part_path, 0)
          foreign = w263_advanced_prepared_source_capture(foreign_part, 0, original[:budget])

          ordinary_streams = CrystalClick::ObjectDocumentInlineBodyMaterializer.materialize(
            original[:prefix],
            original[:physical_plan],
            original[:grid],
            original[:budget],
            original[:schedule].body_bindings,
            original[:schedule].body_pairs,
            original[:statistics_offsets],
            defer_advanced_values: true,
          )
          foreign_shared = CrystalClick::ObjectSharedAdvancedInlineDecoder.prepare_inline(
            foreign[:prefix],
            foreign[:physical_plan],
            foreign[:grid],
            foreign[:budget],
            foreign[:schedule].body_bindings,
            foreign[:schedule].body_pairs,
          )

          # This should be rejected at compile time because only
          # prepare_from_source may construct this holder.
          CrystalClick::CompactStaticJsonAdvancedPreparedMark.new(
            original[:budget],
            original[:profile],
            original[:prefix].typed_schema_for(original[:budget]),
            original[:prefix].typed_descriptor_root_depth,
            original[:prefix].inferred_actual_root_depth,
            ordinary_streams,
            foreign_shared,
            original[:grid].logical_occurrences_at(0),
          )
        ensure
          FileUtils.rm_rf(copy_parent)
        end
      end
    {% end %}

    it "decodes only from its completed source capture and rejects budget or framer substitution" do
      source = CompactStaticJsonW263AdversaryFixture.source_part(
        CompactStaticJsonW263AdversaryFixture.evidence_root,
        CompactStaticJsonMrk4ChunkedW263Fixture::LABEL,
      )
      part_path = source[:path]
      CompactJsonW263Fixture.assert_native_inventory!(part_path, source[:inventory])

      copy_parent, foreign_part = CompactStaticJsonW263AdversaryFixture.copy_part(part_path)
      begin
        CompactJsonW263Fixture.assert_native_inventory!(foreign_part, source[:inventory])

        original = w263_advanced_prepared_source_capture(part_path, 0)
        # Keep the budget identical so a failed cross-source substitution can
        # only be attributed to source ownership, not request-budget identity.
        foreign = w263_advanced_prepared_source_capture(foreign_part, 0, original[:budget])
        original[:row_count].should eq(2_u64)
        foreign[:row_count].should eq(2_u64)
        original[:budget].same?(foreign[:budget]).should be_true
        original[:physical].same?(foreign[:physical]).should be_false

        owner = CrystalClick::CompactStaticJsonAdvancedPreparedMark.prepare_from_source(
          original[:prefix],
          original[:physical_plan],
          original[:grid],
          original[:budget],
          original[:schedule].body_bindings,
          original[:schedule].body_pairs,
          original[:statistics_offsets],
          original[:profile],
          original[:framer],
        )
        foreign_owner = CrystalClick::CompactStaticJsonAdvancedPreparedMark.prepare_from_source(
          foreign[:prefix],
          foreign[:physical_plan],
          foreign[:grid],
          foreign[:budget],
          foreign[:schedule].body_bindings,
          foreign[:schedule].body_pairs,
          foreign[:statistics_offsets],
          foreign[:profile],
          foreign[:framer],
        )
        owner.logical_row_count.should eq(2_u64)
        foreign_owner.logical_row_count.should eq(2_u64)
        owner.responds_to?(:streams_at).should be_false
        owner.responds_to?(:streams).should be_false
        owner.responds_to?(:holder).should be_false
        owner.responds_to?(:raw_artifact).should be_false
        owner.retained_workspace_bytes.should be > 0_u64

        expected = [
          "#{CompactJsonW263Fixture.json_type.name}{id=UInt8:1,label=String:\"json-1\",note=String:\"note-1\",sample=Int64:10,zz_overflow=String:\"overflow-1\"}",
          "#{CompactJsonW263Fixture.json_type.name}{id=UInt8:2,label=String:\"json-2\",note=String:\"note-2\",sample=Float64:0x4004000000000000,zz_overflow=String:\"overflow-2\"}",
        ]
        documents = owner.decode_with_budget(original[:budget])
        documents.map { |document| w263_advanced_prepared_document_signature(document) }.should eq(expected)

        # The accepted budget is the exact one that prepared this source mark.
        # A fresh equal-limits counter cannot silently decode the retained owner.
        fresh_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
        expect_raises(ArgumentError) { owner.decode_with_budget(fresh_budget) }

        # Returned documents are per-call values, not a public cached artifact.
        documents.clear
        owner.decode_with_budget(original[:budget])
          .map { |document| w263_advanced_prepared_document_signature(document) }
          .should eq(expected)

        # Both completed captures above were individually accepted. Mixing A's
        # parsed source with B's same-label, independently opened physical
        # source must fail before it can mint a prepared owner.
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::CompactStaticJsonAdvancedPreparedMark.prepare_from_source(
            original[:prefix],
            original[:physical_plan],
            original[:grid],
            original[:budget],
            original[:schedule].body_bindings,
            original[:schedule].body_pairs,
            original[:statistics_offsets],
            original[:profile],
            foreign[:framer],
          )
        end
      ensure
        FileUtils.rm_rf(copy_parent)
      end
    end

    it "rejects a fully consumed source capture that was not successfully finished" do
      source = CompactStaticJsonW263AdversaryFixture.source_part(
        CompactStaticJsonW263AdversaryFixture.evidence_root,
        CompactStaticJsonMrk4ChunkedW263Fixture::LABEL,
      )
      CompactJsonW263Fixture.assert_native_inventory!(source[:path], source[:inventory])
      capture = w263_advanced_prepared_source_capture(source[:path], 0, complete_capture: false)

      expect_raises(CrystalClick::UnsupportedFormatError) do
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
    end

    it "rejects a forged body owner kind before materializing a source capture" do
      source = CompactStaticJsonW263AdversaryFixture.source_part(
        CompactStaticJsonW263AdversaryFixture.evidence_root,
        CompactStaticJsonMrk4ChunkedW263Fixture::LABEL,
      )
      CompactJsonW263Fixture.assert_native_inventory!(source[:path], source[:inventory])
      capture = w263_advanced_prepared_source_capture(source[:path], 0)
      forged_bindings = capture[:schedule].body_bindings.dup
      first_binding = forged_bindings.first? || raise "native Advanced schedule has no body binding"
      forged_bindings[0] = {
        first_binding[0],
        :forged_kind,
        first_binding[2],
        first_binding[3],
      }

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactStaticJsonAdvancedPreparedMark.prepare_from_source(
          capture[:prefix],
          capture[:physical_plan],
          capture[:grid],
          capture[:budget],
          forged_bindings,
          capture[:schedule].body_pairs,
          capture[:statistics_offsets],
          capture[:profile],
          capture[:framer],
        )
      end

      retained_capture = w263_advanced_prepared_source_capture(source[:path], 0)
      retained_forged_bindings = retained_capture[:schedule].body_bindings.dup
      retained_first = retained_forged_bindings.first? || raise "native Advanced schedule has no body binding"
      retained_forged_bindings[0] = {
        retained_first[0],
        :forged_kind,
        retained_first[2],
        retained_first[3],
      }
      retained_capture[:prefix].bind_body_schedule!(
        retained_forged_bindings,
        retained_capture[:schedule].body_pairs,
      )

      # The prefix now retains a conflicting same-name/same-bytes binding.
      # Passing the actual parsed schedule must not silently replace it.
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactStaticJsonAdvancedPreparedMark.prepare_from_source(
          retained_capture[:prefix],
          retained_capture[:physical_plan],
          retained_capture[:grid],
          retained_capture[:budget],
          retained_capture[:schedule].body_bindings,
          retained_capture[:schedule].body_pairs,
          retained_capture[:statistics_offsets],
          retained_capture[:profile],
          retained_capture[:framer],
        )
      end
    end
  end
end
