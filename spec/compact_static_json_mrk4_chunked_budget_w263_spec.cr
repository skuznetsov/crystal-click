require "./spec_helper"
require "../scripts/support/compact_json_w263_fixture"
require "./support/compact_static_json_w263_adversary_fixture"

private def w263_chunked_budget_snapshot(budget : CrystalClick::BinaryCodecBudget) : Tuple(Int64, Int64, Int64)
  {budget.node_count, budget.element_count, budget.wire_byte_count}
end

private def w263_chunked_budget_delta(
  before : Tuple(Int64, Int64, Int64),
  after : Tuple(Int64, Int64, Int64),
) : Tuple(Int64, Int64, Int64)
  {after[0] - before[0], after[1] - before[1], after[2] - before[2]}
end

if ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]?
  describe "Compact MRK4 ADVANCED_CHUNKED root-JSON request budget (W263)" do
    it "admits EOF and each selected mark separately but refuses their aggregate under one finite cap" do
      label = "obj_v3_dyn_v3_advanced_chunked_mrk4_s0_variant_basic"
      source = CompactStaticJsonW263AdversaryFixture.source_part(
        CompactStaticJsonW263AdversaryFixture.evidence_root,
        label,
      )
      part_path = source[:path]
      CompactJsonW263Fixture.assert_native_inventory!(part_path, source[:inventory])
      limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
      type = CompactJsonW263Fixture.json_type

      # Measure the complete request-local work separately from the type-name
      # parse performed by open. Repeated EOF requests independently check
      # that Advanced preparation is not silently reused across requests.
      preparation_budget = CrystalClick::BinaryCodecBudget.new(limits)
      preparation_reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        part_path,
        "root",
        type,
        limits: limits,
        codec_budget: preparation_budget,
      )
      preparation_reader.mark_count.should eq(4)
      preparation_reader.mark_row_counts.should eq(CompactJsonW263Fixture::MARK_ROWS)
      open_counts = w263_chunked_budget_snapshot(preparation_budget)

      before_first_prepare = w263_chunked_budget_snapshot(preparation_budget)
      preparation_reader.read_marks(preparation_reader.mark_count, 0).should be_empty
      prepare_once = w263_chunked_budget_delta(
        before_first_prepare,
        w263_chunked_budget_snapshot(preparation_budget),
      )
      before_second_prepare = w263_chunked_budget_snapshot(preparation_budget)
      preparation_reader.read_marks(preparation_reader.mark_count, 0).should be_empty
      prepare_again = w263_chunked_budget_delta(
        before_second_prepare,
        w263_chunked_budget_snapshot(preparation_budget),
      )
      prepare_once[0].should be > 0_i64
      prepare_again.should eq(prepare_once)
      preparation_reader.prepared_context.responds_to?(:streams_at).should be_false

      # Every calibration request gets an independent fresh reader and budget;
      # the selected request cost includes its own full preparation plus only
      # that one mark's value decode.
      selected_request_costs = Array(Tuple(Int64, Int64, Int64)).new(4)
      4.times do |mark_index|
        mark_budget = CrystalClick::BinaryCodecBudget.new(limits)
        mark_reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
          part_path,
          "root",
          type,
          limits: limits,
          codec_budget: mark_budget,
        )
        before_read = w263_chunked_budget_snapshot(mark_budget)
        selected = mark_reader.read_marks(mark_index, 1)
        selected.size.should eq(1)
        selected[0].size.to_u64.should eq(CompactJsonW263Fixture::MARK_ROWS[mark_index])
        selected_request_costs << w263_chunked_budget_delta(
          before_read,
          w263_chunked_budget_snapshot(mark_budget),
        )
      end

      aggregate_budget = CrystalClick::BinaryCodecBudget.new(limits)
      aggregate_reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        part_path,
        "root",
        type,
        limits: limits,
        codec_budget: aggregate_budget,
      )
      aggregate_before = w263_chunked_budget_snapshot(aggregate_budget)
      all_marks = aggregate_reader.read_marks(0, aggregate_reader.mark_count)
      all_marks.size.should eq(4)
      all_marks.each_with_index do |mark, index|
        mark.size.to_u64.should eq(CompactJsonW263Fixture::MARK_ROWS[index])
      end
      aggregate_cost = w263_chunked_budget_delta(
        aggregate_before,
        w263_chunked_budget_snapshot(aggregate_budget),
      )

      candidates = [
        {
          name:      "node",
          open:      open_counts[0],
          prepare:   prepare_once[0],
          singles:   selected_request_costs.map(&.[0]),
          aggregate: aggregate_cost[0],
          default:   limits.max_nodes,
        },
        {
          name:      "element",
          open:      open_counts[1],
          prepare:   prepare_once[1],
          singles:   selected_request_costs.map(&.[1]),
          aggregate: aggregate_cost[1],
          default:   limits.max_elements,
        },
        {
          name:      "byte",
          open:      open_counts[2],
          prepare:   prepare_once[2],
          singles:   selected_request_costs.map(&.[2]),
          aggregate: aggregate_cost[2],
          default:   limits.max_bytes,
        },
      ]
      discriminator = candidates.find do |candidate|
        required_single = candidate[:singles].max || 0_i64
        cap = {candidate[:open], candidate[:prepare], required_single}.max
        candidate[:aggregate] > cap && cap < candidate[:default]
      end
      unless discriminator
        raise "native ADVANCED_CHUNKED fixture has no measured aggregate budget discriminator: " \
              "nodes(open=#{open_counts[0]}, prep=#{prepare_once[0]}, singles=#{selected_request_costs.map(&.[0])}, aggregate=#{aggregate_cost[0]}), " \
              "elements(open=#{open_counts[1]}, prep=#{prepare_once[1]}, singles=#{selected_request_costs.map(&.[1])}, aggregate=#{aggregate_cost[1]}), " \
              "bytes(open=#{open_counts[2]}, prep=#{prepare_once[2]}, singles=#{selected_request_costs.map(&.[2])}, aggregate=#{aggregate_cost[2]})"
      end

      cap = {discriminator[:open], discriminator[:prepare], discriminator[:singles].max || 0_i64}.max
      finite_limits = case discriminator[:name]
                      when "node"
                        CrystalClick::BinaryCodecLimits.new(
                          max_depth: limits.max_depth,
                          max_nodes: cap,
                          max_elements: limits.max_elements,
                          max_bytes: limits.max_bytes,
                        )
                      when "element"
                        CrystalClick::BinaryCodecLimits.new(
                          max_depth: limits.max_depth,
                          max_nodes: limits.max_nodes,
                          max_elements: cap,
                          max_bytes: limits.max_bytes,
                        )
                      else
                        CrystalClick::BinaryCodecLimits.new(
                          max_depth: limits.max_depth,
                          max_nodes: limits.max_nodes,
                          max_elements: limits.max_elements,
                          max_bytes: cap,
                        )
                      end

      eof_control = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        part_path,
        "root",
        type,
        limits: finite_limits,
      )
      eof_control.read_marks(eof_control.mark_count, 0).should be_empty

      4.times do |mark_index|
        single_control = CrystalClick::CompactStaticJsonBulkColumnReader.open(
          part_path,
          "root",
          type,
          limits: finite_limits,
        )
        selected = single_control.read_marks(mark_index, 1)
        selected.size.should eq(1)
        selected[0].size.to_u64.should eq(CompactJsonW263Fixture::MARK_ROWS[mark_index])
      end

      aggregate_control = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        part_path,
        "root",
        type,
        limits: finite_limits,
      )
      expected_error = Regex.new("binary codec #{discriminator[:name]} limit exceeded")
      expect_raises(CrystalClick::CorruptPartError, expected_error) do
        aggregate_control.read_marks(0, aggregate_control.mark_count)
      end
    end
  end
end
