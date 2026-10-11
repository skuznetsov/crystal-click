require "./spec_helper"
require "../scripts/support/compact_json_w263_fixture"
require "./support/compact_static_json_mrk3_null_w263_fixture"

private def w263_mrk3_null_document_signature(
  document : CrystalClick::ObjectDocument,
  type_name : String,
) : String
  entries = document.paths.sort.map do |path|
    "#{path}=#{CompactJsonW263Fixture.value_signature(document.value_for(path))}"
  end
  "#{type_name}{#{entries.join(",")}}"
end

if ENV["CRYSTAL_CLICK_W263_NULL_EVIDENCE_ROOT"]?
  describe "Compact static root-JSON native MRK3 NULL Dynamic reader (W263)" do
    it "prepares the complete two-mark grid at EOF and matches independent selected/full row literals" do
      source = CompactStaticJsonMrk3NullW263Fixture.source_part(:basic)
      CompactJsonW263Fixture.assert_native_inventory!(source[:path], source[:inventory])

      type = CompactStaticJsonMrk3NullW263Fixture.json_type
      reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(source[:path], "root", type)
      reader.row_count.should eq(4_u64)
      reader.mark_count.should eq(2)
      reader.mark_row_counts.should eq([2_u64, 2_u64])

      workspace_peak_estimate = 0_u64
      observe_workspace = ->(bytes : UInt64) do
        workspace_peak_estimate = bytes if bytes > workspace_peak_estimate
        nil
      end
      reader.read_marks(reader.mark_count, 0, observe_workspace).should be_empty
      prepared = reader.prepared_context
      prepared.mark_count.should eq(2)
      reader.retained_grid_workspace_bytes.should be > 0_u64
      workspace_peak_estimate.should be >= reader.retained_workspace_bytes

      mark0 = CompactStaticJsonMrk3NullW263Fixture.raw_mark_evidence(source[:path], 0)
      mark1 = CompactStaticJsonMrk3NullW263Fixture.raw_mark_evidence(source[:path], 1)
      mark0[:logical_start].should eq(16_i64)
      mark1[:logical_start].should eq(110_i64)
      mark0[:raw].size.should eq(78)
      mark1[:raw].size.should eq(72)
      mark0[:prefix_end].should eq(46)
      mark1[:prefix_end].should eq(46)
      mark0[:remaining].should eq(32)
      mark1[:remaining].should eq(26)
      mark0[:object_statistics_offset].should eq(16)
      mark1[:object_statistics_offset].should eq(16)
      mark0[:dynamic_statistics_offsets].should eq({"root.maybe.dynamic_structure" => 17})
      mark1[:dynamic_statistics_offsets].should eq({"root.maybe.dynamic_structure" => 17})
      mark0[:dynamic_paths].should eq(["maybe"])
      mark1[:dynamic_paths].should eq(["maybe"])
      mark0[:string_indexes].should eq([1])
      mark1[:string_indexes].should eq([1])
      mark0[:raw].hexstring.should eq(
        "00000000000000000101056d6179626501000100000000000000010106537472696e670001000000000000000000010202723102723201ff05616c70686100000000000000000000000000000000"
      )
      mark1[:raw].hexstring.should eq(
        "00000000000000000101056d6179626500000100000000000000010106537472696e6700000000000000000000000304027233027234ffff00000000000000000000000000000000"
      )

      expected_object_prefix = "00000000000000000101056d617962650100"
      expected_dynamic_prefix = "0100000000000000010106537472696e67000100"
      expected_null_object_prefix = "00000000000000000101056d617962650000"
      expected_null_dynamic_prefix = "0100000000000000010106537472696e67000000"
      mark0[:callbacks].map { |name, bytes| {name, bytes.hexstring} }.should eq([
        {"root.object_structure", expected_object_prefix},
        {"root.maybe.dynamic_structure", expected_dynamic_prefix},
        {"root.maybe.variant_discr_prefix", "0000000000000000"},
      ])
      mark1[:callbacks].map { |name, bytes| {name, bytes.hexstring} }.should eq([
        {"root.object_structure", expected_null_object_prefix},
        {"root.maybe.dynamic_structure", expected_null_dynamic_prefix},
        {"root.maybe.variant_discr_prefix", "0000000000000000"},
      ])

      mixed_body = CompactStaticJsonMrk3NullW263Fixture.body_capture_evidence(source[:path], 0)
      null_body = CompactStaticJsonMrk3NullW263Fixture.body_capture_evidence(source[:path], 1)
      # Dynamic mode lookup rereads all three prefix callbacks; each
      # prefix_callback_at lookup is charged before the body role walk.
      mixed_body[:body_nodes].should eq(mixed_body[:bindings].size.to_i64 + 12_i64)
      mixed_body[:body_elements].should eq(mixed_body[:bindings].size.to_i64 + 12_i64)
      null_body[:body_nodes].should eq(null_body[:bindings].size.to_i64 + 11_i64)
      null_body[:body_elements].should eq(null_body[:bindings].size.to_i64 + 11_i64)

      [mixed_body, null_body].each_with_index do |body, mark_index|
        body[:callbacks].size.should eq(body[:bindings].size)
        body[:callbacks].map(&.[0]).should eq(body[:bindings].map(&.[0]))

        # Canonical Dynamic arm 0 is the implicit SharedVariant String;
        # arm 1 is the ordinary String discovered in the native roster.
        expected_arm_extents = {
          "root.arm.0.data" => 0,
          "root.arm.1.data" => mark_index == 0 ? 6 : 0,
        }
        expected_arm_extents.each do |role, expected_extent|
          bindings = body[:bindings].select do |candidate|
            candidate[1] == :root_dynamic && candidate[2] == "maybe" && candidate[3] == role
          end
          bindings.size.should eq(1)
          binding = bindings.first
          callbacks = body[:callbacks].select { |callback| callback[0] == binding[0] }
          callbacks.size.should eq(1)
          callbacks.first[2].should eq(expected_extent)
        end

        # These are the serialized MAP size, path, and value callbacks even
        # when the path/value occurrence counts are zero.
        {
          "root.sizes"                 => 16,
          "root.elements.field.0.data" => 0,
          "root.elements.field.1.data" => 0,
        }.each do |role, expected_extent|
          bindings = body[:bindings].select do |candidate|
            candidate[1] == :shared && candidate[3] == role
          end
          bindings.size.should eq(1)
          binding = bindings.first
          callbacks = body[:callbacks].select { |callback| callback[0] == binding[0] }
          callbacks.size.should eq(1)
          callbacks.first[2].should eq(expected_extent)
        end
      end

      type_name = type.name
      expected = [
        "#{type_name}{id=UInt8:1,label=String:\"r1\",maybe=String:\"alpha\"}",
        "#{type_name}{id=UInt8:2,label=String:\"r2\"}",
        "#{type_name}{id=UInt8:3,label=String:\"r3\"}",
        "#{type_name}{id=UInt8:4,label=String:\"r4\"}",
      ]

      first = reader.read_marks(0, 1)
      first.size.should eq(1)
      first[0].map { |document| w263_mrk3_null_document_signature(document, type_name) }
        .should eq(expected[0, 2])

      all_null = reader.read_marks(1, 1)
      all_null.size.should eq(1)
      all_null[0].map { |document| w263_mrk3_null_document_signature(document, type_name) }
        .should eq(expected[2, 2])

      actual = [] of String
      reader.read_marks(0, reader.mark_count, observe_workspace).each do |mark|
        mark.each { |document| actual << w263_mrk3_null_document_signature(document, type_name) }
      end
      actual.should eq(expected)
      workspace_peak_estimate.should be >= reader.retained_workspace_bytes
    end
  end
end
