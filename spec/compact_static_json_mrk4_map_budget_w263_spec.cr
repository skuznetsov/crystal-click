require "./support/compact_static_json_w263_adversary_fixture"

if ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]?
  describe "Compact MRK4 MAP root-JSON request budget (W263)" do
    it "admits EOF preparation and each mark separately but rejects their aggregate under a calibrated finite limit" do
      label = "obj_v2_dyn_v2_map_mrk4_s0_variant_basic"
      source = CompactStaticJsonW263AdversaryFixture.source_part(
        CompactStaticJsonW263AdversaryFixture.evidence_root,
        label,
      )
      part_path = source[:path]
      generous = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
      type = CompactJsonW263Fixture.json_type

      calibration_budget = CrystalClick::BinaryCodecBudget.new(generous)
      calibration_reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        part_path,
        "root",
        type,
        limits: generous,
        codec_budget: calibration_budget,
      )
      calibration_reader.mark_count.should eq(4)
      calibration_reader.mark_row_counts.should eq(CompactJsonW263Fixture::MARK_ROWS)

      open_nodes = calibration_budget.node_count
      open_elements = calibration_budget.element_count
      open_bytes = calibration_budget.wire_byte_count

      calibration_reader.read_marks(calibration_reader.mark_count, 0).should be_empty
      prepared_nodes = calibration_budget.node_count - open_nodes
      prepared_elements = calibration_budget.element_count - open_elements
      prepared_bytes = calibration_budget.wire_byte_count - open_bytes

      prepared = calibration_reader.prepared_context
      prepared.responds_to?(:streams_at).should be_false

      # Public prefix metadata is detached. Mutating a returned buffer must not
      # change the retained prepared metadata.
      object_prefix = prepared.object_prefix_bytes_at(0)
      object_prefix.size.should be > 0
      object_head = object_prefix[0]
      object_prefix[0] ^= 0xff_u8
      prepared.object_prefix_bytes_at(0)[0].should eq(object_head)

      note_name = "root.note.dynamic_structure"
      note_prefix = prepared.dynamic_prefix_bytes_at(0, note_name)
      note_prefix.size.should be > 0
      note_head = note_prefix[0]
      note_prefix[0] ^= 0xff_u8
      prepared.dynamic_prefix_bytes_at(0, note_name)[0].should eq(note_head)

      sample_name = "root.sample.dynamic_structure"
      sample_prefix = prepared.dynamic_prefix_bytes_at(0, sample_name)
      sample_prefix.size.should be > 0
      sample_head = sample_prefix[0]
      sample_prefix[0] ^= 0xff_u8
      prepared.dynamic_prefix_bytes_at(0, sample_name)[0].should eq(sample_head)

      mark_counts = [] of Tuple(Int64, Int64, Int64)
      calibration_reader.mark_count.times do |mark_index|
        mark_budget = CrystalClick::BinaryCodecBudget.new(generous)
        documents = prepared.decode_mark_with_budget(mark_index, mark_budget, calibration_reader.ordinary_profile)
        documents.size.to_u64.should eq(calibration_reader.mark_row_counts[mark_index])
        mark_counts << {mark_budget.node_count, mark_budget.element_count, mark_budget.wire_byte_count}
      end

      before_aggregate = {
        calibration_budget.node_count,
        calibration_budget.element_count,
        calibration_budget.wire_byte_count,
      }
      all_marks = calibration_reader.read_marks(0, calibration_reader.mark_count)
      all_marks.size.should eq(calibration_reader.mark_count)
      all_marks.each_with_index do |mark, index|
        mark.size.to_u64.should eq(calibration_reader.mark_row_counts[index])
      end
      aggregate_counts = {
        calibration_budget.node_count - before_aggregate[0],
        calibration_budget.element_count - before_aggregate[1],
        calibration_budget.wire_byte_count - before_aggregate[2],
      }

      per_mark_nodes = mark_counts.map(&.[0])
      per_mark_elements = mark_counts.map(&.[1])
      per_mark_bytes = mark_counts.map(&.[2])
      max_single_nodes = per_mark_nodes.max || 0_i64
      max_single_elements = per_mark_elements.max || 0_i64
      max_single_bytes = per_mark_bytes.max || 0_i64

      # The open-time type-name parse uses the caller-supplied budget, but the
      # ordinary reader's default request budget starts at read_marks. Therefore
      # the finite request cap is derived from preparation + the largest single
      # mark, while also remaining high enough for the separately bounded open.
      # Aggregate decoding need not exceed preparation itself: the discriminator
      # is that prep + all selected marks exceeds prep + the largest one mark.
      candidates = [
        {
          name:      "node",
          open:      open_nodes,
          prepared:  prepared_nodes,
          single:    max_single_nodes,
          aggregate: aggregate_counts[0],
          cap:       {open_nodes, prepared_nodes + max_single_nodes}.max,
          default:   generous.max_nodes,
        },
        {
          name:      "element",
          open:      open_elements,
          prepared:  prepared_elements,
          single:    max_single_elements,
          aggregate: aggregate_counts[1],
          cap:       {open_elements, prepared_elements + max_single_elements}.max,
          default:   generous.max_elements,
        },
        {
          name:      "byte",
          open:      open_bytes,
          prepared:  prepared_bytes,
          single:    max_single_bytes,
          aggregate: aggregate_counts[2],
          cap:       {open_bytes, prepared_bytes + max_single_bytes}.max,
          default:   generous.max_bytes,
        },
      ]
      discriminator = candidates.find do |candidate|
        candidate[:aggregate] > candidate[:single] &&
          candidate[:cap] < candidate[:prepared] + candidate[:aggregate] &&
          candidate[:cap] < candidate[:default]
      end
      unless discriminator
        raise "native MAP fixture has no finite aggregate budget discriminator: " \
              "nodes(open=#{open_nodes}, prep=#{prepared_nodes}, marks=#{per_mark_nodes}, aggregate=#{aggregate_counts[0]}), " \
              "elements(open=#{open_elements}, prep=#{prepared_elements}, marks=#{per_mark_elements}, aggregate=#{aggregate_counts[1]}), " \
              "bytes(open=#{open_bytes}, prep=#{prepared_bytes}, marks=#{per_mark_bytes}, aggregate=#{aggregate_counts[2]})"
      end

      finite_limits = case discriminator[:name]
                      when "node"
                        CrystalClick::BinaryCodecLimits.new(
                          max_depth: generous.max_depth,
                          max_nodes: discriminator[:cap],
                          max_elements: generous.max_elements,
                          max_bytes: generous.max_bytes,
                        )
                      when "element"
                        CrystalClick::BinaryCodecLimits.new(
                          max_depth: generous.max_depth,
                          max_nodes: generous.max_nodes,
                          max_elements: discriminator[:cap],
                          max_bytes: generous.max_bytes,
                        )
                      else
                        CrystalClick::BinaryCodecLimits.new(
                          max_depth: generous.max_depth,
                          max_nodes: generous.max_nodes,
                          max_elements: generous.max_elements,
                          max_bytes: discriminator[:cap],
                        )
                      end

      # A fresh default-budget reader can prepare all marks at EOF under this
      # finite limit, and every mark is individually readable with the same cap.
      preparation_control = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        part_path,
        "root",
        type,
        limits: finite_limits,
      )
      preparation_control.read_marks(preparation_control.mark_count, 0).should be_empty

      preparation_control.mark_count.times do |mark_index|
        single_mark_reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
          part_path,
          "root",
          type,
          limits: finite_limits,
        )
        selected = single_mark_reader.read_marks(mark_index, 1)
        selected.size.should eq(1)
        selected[0].size.to_u64.should eq(CompactJsonW263Fixture::MARK_ROWS[mark_index])
      end

      aggregate_reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        part_path,
        "root",
        type,
        limits: finite_limits,
      )
      expected_error = Regex.new("binary codec #{discriminator[:name]} limit exceeded")
      expect_raises(CrystalClick::CorruptPartError, expected_error) do
        aggregate_reader.read_marks(0, aggregate_reader.mark_count)
      end
    end
  end
end
