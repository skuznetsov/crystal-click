require "./spec_helper"
require "../scripts/support/compact_json_w263_fixture"
require "./support/compact_static_json_mrk3_compact_w263_fixture"

private def w263_mrk3_compact_document_signature(
  document : CrystalClick::ObjectDocument,
  type_name : String,
) : String
  entries = document.paths.sort.map do |path|
    "#{path}=#{CompactJsonW263Fixture.value_signature(document.value_for(path))}"
  end
  "#{type_name}{#{entries.join(",")}}"
end

if ENV["CRYSTAL_CLICK_W263_COMPACT_EVIDENCE_ROOT"]?
  describe "Compact static root-JSON native MRK3 COMPACT Dynamic reader (W263)" do
    it "prepares the complete three-mark grid before returning selected and full row values" do
      basic = CompactStaticJsonMrk3CompactW263Fixture.source_part(:basic)
      CompactJsonW263Fixture.assert_native_inventory!(basic[:path], basic[:inventory])
      basic_reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        basic[:path],
        "root",
        CompactStaticJsonMrk3CompactW263Fixture.json_type,
      )
      basic_reader.read_marks(basic_reader.mark_count, 0).should be_empty
      basic_reader.prepared_context.mark_count.should eq(3)

      # The capability target is the genuine stock COMPACT sibling, not a
      # header-only mutation of the BASIC part.
      source = CompactStaticJsonMrk3CompactW263Fixture.source_part(:compact)
      CompactJsonW263Fixture.assert_native_inventory!(source[:path], source[:inventory])

      type = CompactStaticJsonMrk3CompactW263Fixture.json_type
      expected_raw = [
        "00000000000000000101056d6179626503000100000000000000010106537472696e6700030001000000000000000102027231027232020001ff05616c70686100000000000000000000000000000000",
        "00000000000000000101056d6179626500000100000000000000010106537472696e67000000010000000000000003040272330272340201ff00000000000000000000000000000000",
        "00000000000000000101056d6179626500000100000000000000010106537472696e670000000100000000000000050602723502723602010104626574610567616d6d6100000000000000000000000000000000",
      ]
      expected_logical_starts = [16_i64, 112_i64, 201_i64]
      expected_prefix_callbacks = [
        [
          {"root.object_structure", "00000000000000000101056d617962650300"},
          {"root.maybe.dynamic_structure", "0100000000000000010106537472696e67000300"},
          {"root.maybe.variant_discr_prefix", "0100000000000000"},
        ],
        [
          {"root.object_structure", "00000000000000000101056d617962650000"},
          {"root.maybe.dynamic_structure", "0100000000000000010106537472696e67000000"},
          {"root.maybe.variant_discr_prefix", "0100000000000000"},
        ],
        [
          {"root.object_structure", "00000000000000000101056d617962650000"},
          {"root.maybe.dynamic_structure", "0100000000000000010106537472696e67000000"},
          {"root.maybe.variant_discr_prefix", "0100000000000000"},
        ],
      ]
      # The body framer also budgets its typed-Dynamic grammar registry as one
      # state node/edge when this fixture has no typed-Dynamic owners.
      expected_body_nodes = [21_i64, 20_i64, 22_i64]
      expected_body_elements = [21_i64, 20_i64, 22_i64]
      expected_body_extents = [
        [2, 6, 4, 0, 6, 16, 0, 0],
        [2, 6, 3, 0, 0, 16, 0, 0],
        [2, 6, 3, 0, 11, 16, 0, 0],
      ]

      [0, 1, 2].each do |mark_index|
        evidence = CompactStaticJsonMrk3CompactW263Fixture.raw_mark_evidence(source[:path], mark_index)
        evidence[:logical_start].should eq(expected_logical_starts[mark_index])
        evidence[:raw].size.should eq([80, 73, 84][mark_index])
        evidence[:raw].hexstring.should eq(expected_raw[mark_index])
        evidence[:prefix_end].should eq(46)
        evidence[:remaining].should eq([34, 27, 38][mark_index])
        evidence[:object_statistics_offset].should eq(16)
        evidence[:dynamic_statistics_offsets].values.should eq([17])
        evidence[:dynamic_paths].should eq(["maybe"])
        evidence[:string_indexes].should eq([1])
        evidence[:discriminator_headers].map { |name, bytes| {name, bytes.hexstring} }.should eq([
          {"root.maybe.variant_discr_prefix", "0100000000000000"},
        ])
        evidence[:callbacks].map { |name, bytes| {name, bytes.hexstring} }
          .should eq(expected_prefix_callbacks[mark_index])

        body = CompactStaticJsonMrk3CompactW263Fixture.body_capture_evidence(source[:path], mark_index)
        body[:body_nodes].should eq(expected_body_nodes[mark_index])
        body[:body_elements].should eq(expected_body_elements[mark_index])
        body[:bindings].size.should eq(8)
        body[:callbacks].size.should eq(body[:bindings].size)
        body[:callbacks].map { |callback| callback[0] }
          .should eq(body[:bindings].map { |binding| binding[0] })
        body[:callbacks].map { |callback| callback[2] }.should eq(expected_body_extents[mark_index])
        body[:bindings].map { |binding| {binding[1], binding[2], binding[3]} }.should eq([
          {:typed, "id", "root.data"},
          {:typed, "label", "root.data"},
          {:root_dynamic, "maybe", "root.discriminators"},
          {:root_dynamic, "maybe", "root.arm.0.data"},
          {:root_dynamic, "maybe", "root.arm.1.data"},
          {:shared, "0", "root.sizes"},
          {:shared, "0", "root.elements.field.0.data"},
          {:shared, "0", "root.elements.field.1.data"},
        ])

        dynamic_bindings = body[:bindings].each_with_index.to_a.select do |binding, _index|
          binding[1] == :root_dynamic
        end
        dynamic_bindings.map { |binding, _index| binding[3] }
          .should eq(["root.discriminators", "root.arm.0.data", "root.arm.1.data"])
        dynamic_arm_extents = dynamic_bindings.select { |binding, _index| binding[3].starts_with?("root.arm.") }
          .map { |binding, index| {binding[3], body[:callbacks][index][2]} }
        dynamic_arm_extents.should eq([
          {"root.arm.0.data", 0},
          {"root.arm.1.data", expected_body_extents[mark_index][4]},
        ])

        shared_bindings = body[:bindings].each_with_index.to_a.select do |binding, _index|
          binding[1] == :shared
        end
        shared_bindings.map { |binding, _index| binding[3] }.should eq([
          "root.sizes",
          "root.elements.field.0.data",
          "root.elements.field.1.data",
        ])
        shared_bindings.map { |_binding, index| body[:callbacks][index][2] }
          .should eq([16, 0, 0])
      end

      reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(source[:path], "root", type)
      reader.row_count.should eq(6_u64)
      reader.mark_count.should eq(3)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])

      type_name = type.name
      expected = [
        "#{type_name}{id=UInt8:1,label=String:\"r1\",maybe=String:\"alpha\"}",
        "#{type_name}{id=UInt8:2,label=String:\"r2\"}",
        "#{type_name}{id=UInt8:3,label=String:\"r3\"}",
        "#{type_name}{id=UInt8:4,label=String:\"r4\"}",
        "#{type_name}{id=UInt8:5,label=String:\"r5\",maybe=String:\"beta\"}",
        "#{type_name}{id=UInt8:6,label=String:\"r6\",maybe=String:\"gamma\"}",
      ]

      reader.read_marks(reader.mark_count, 0).should be_empty
      prepared = reader.prepared_context
      prepared.mark_count.should eq(3)

      [0, 1, 2].each do |mark_index|
        mark = reader.read_marks(mark_index, 1)
        mark.size.should eq(1)
        mark[0].map { |document| w263_mrk3_compact_document_signature(document, type_name) }
          .should eq(expected[mark_index * 2, 2])
      end

      cross_mark = reader.read_marks(1, 2)
      cross_mark.map { |mark| mark.map { |document| w263_mrk3_compact_document_signature(document, type_name) } }
        .flatten.should eq(expected[2, 4])

      actual = [] of String
      reader.read_marks(0, reader.mark_count).each do |mark|
        mark.each { |document| actual << w263_mrk3_compact_document_signature(document, type_name) }
      end
      actual.should eq(expected)
    end
  end
end
