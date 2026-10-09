require "./spec_helper"

private def w192_attack_record(rows : UInt64, paths = ["a"] of String) : CrystalClick::ObjectSharedChunkStructure
  CrystalClick::ObjectSharedChunkStructure.new(rows, paths, {0_u64, 0_u64}, {0_u64, 0_u64}, {0_u64, 0_u64})
end

private def w192_attack_sizes(*counts : UInt64) : Bytes
  Bytes.new(counts.size * 8) do |offset|
    ((counts[offset // 8] >> ((offset % 8) * 8)) & 0xff_u64).to_u8
  end
end

private def w192_attack_row(path : Bytes = "a".to_slice) : CrystalClick::ObjectSharedMapRow
  CrystalClick::ObjectSharedMapRow.new([
    CrystalClick::ObjectSharedMapEntry.new(path, CrystalClick::BinaryValue.string("v")),
  ])
end

describe "W192 root-authored Copy adversaries" do
  it "rejects full-width logical row counts before count-derived collections" do
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode(Bytes.empty, Bytes.empty, Bytes.empty, [w192_attack_record(UInt64::MAX)])
    end
  end

  it "cannot reinterpret cumulative offsets as normalized per-row sizes" do
    # Two actual entries fit [1,1], not the cumulative representation [1,2].
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode(
        w192_attack_sizes(1_u64, 2_u64), Bytes[0_u8, 0_u8],
        Bytes[3_u8, 0x15_u8, 1_u8, 0x76_u8, 3_u8, 0x15_u8, 1_u8, 0x76_u8],
        [w192_attack_record(2_u64)],
      )
    end
  end

  it "charges exactly the three Copy wire lanes and never resets across chunks" do
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 1000, max_elements: 1000, max_bytes: 13)
    records = [w192_attack_record(1_u64)]
    sizes = w192_attack_sizes(1_u64)
    indexes = Bytes[0_u8]
    values = Bytes[3_u8, 0x15_u8, 1_u8, 0x76_u8]

    read_budget = CrystalClick::BinaryCodecBudget.new(limits)
    rows = CrystalClick::ObjectSharedCopyCodec.decode_with_budget(sizes, indexes, values, records, read_budget)
    rows[0].entry_at(0).value.as_string.should eq("v")
    read_budget.wire_byte_count.should eq(13)
    expect_raises(CrystalClick::CorruptPartError, /byte limit/) do
      CrystalClick::ObjectSharedCopyCodec.decode_with_budget(sizes, indexes, values, records, read_budget)
    end

    write_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    encoded = CrystalClick::ObjectSharedCopyCodec.encode_with_budget([w192_attack_row], records, write_budget)
    encoded.values.should eq(values)
    write_budget.wire_byte_count.should eq(13)
    expect_raises(CrystalClick::UnsupportedFormatError, /byte limit/) do
      CrystalClick::ObjectSharedCopyCodec.encode_with_budget([w192_attack_row], records, write_budget)
    end
  end

  it "bounds repeated materialized path bytes even when the Copy body is tiny" do
    path = "p" * 512
    records = [w192_attack_record(2_u64, [path])]
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 1000, max_elements: 1024, max_bytes: 4096)
    expect_raises(CrystalClick::CorruptPartError, /element limit/) do
      CrystalClick::ObjectSharedCopyCodec.decode(
        w192_attack_sizes(1_u64, 1_u64), Bytes[0_u8, 0_u8],
        Bytes[3_u8, 0x15_u8, 1_u8, 0x76_u8, 3_u8, 0x15_u8, 1_u8, 0x76_u8], records, limits,
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError, /element limit/) do
      CrystalClick::ObjectSharedCopyCodec.encode([w192_attack_row(path.to_slice), w192_attack_row(path.to_slice)], records, limits)
    end
  end

  it "rejects a noncanonical outer String frame despite a valid inner value" do
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode(
        w192_attack_sizes(1_u64), Bytes[0_u8], Bytes[0x83_u8, 0_u8, 0x15_u8, 1_u8, 0x76_u8], [w192_attack_record(1_u64)],
      )
    end
  end

  it "distinguishes an unsupported actual type from a corrupt descriptor" do
    # JSON is admitted by W240. An aggregate state still belongs to a distinct
    # owner and must not enter Copy merely because scalar serde can read it.
    type = CrystalClick::BinaryDataType.aggregate_count
    value = CrystalClick::BinaryValue.aggregate_count_state(type, 0_u64)
    envelope = CrystalClick::BinaryValueCodec.encode(value)
    CrystalClick::BinaryValueCodec.decode(envelope).type.should eq(type)
    envelope.size.should be < 128
    values = Bytes.new(envelope.size + 1) { |index| index == 0 ? envelope.size.to_u8 : envelope[index - 1] }
    expect_raises(CrystalClick::UnsupportedFormatError, /AggregateFunction/) do
      CrystalClick::ObjectSharedCopyCodec.decode(w192_attack_sizes(1_u64), Bytes[0_u8], values, [w192_attack_record(1_u64)])
    end
    expect_raises(CrystalClick::CorruptPartError, /unknown or reserved/) do
      CrystalClick::ObjectSharedCopyCodec.decode(w192_attack_sizes(1_u64), Bytes[0_u8], Bytes[1_u8, 0xff_u8], [w192_attack_record(1_u64)])
    end
  end

  it "preserves exact wire limits when the outer String length needs a second byte" do
    {124, 125, 126, 127, 128}.each do |length|
      payload = "v" * length
      row = CrystalClick::ObjectSharedMapRow.new([
        CrystalClick::ObjectSharedMapEntry.new("a".to_slice, CrystalClick::BinaryValue.string(payload)),
      ])
      records = [w192_attack_record(1_u64)]
      streams = CrystalClick::ObjectSharedCopyCodec.encode([row], records)
      envelope_bytes = 1 + (length < 128 ? 1 : 2) + length
      prefix_bytes = envelope_bytes < 128 ? 1 : 2
      exact_bytes = 8 + 1 + prefix_bytes + envelope_bytes
      streams.values.size.should eq(prefix_bytes + envelope_bytes)
      streams.values[0].should eq((envelope_bytes < 128 ? envelope_bytes : (envelope_bytes & 0x7f) | 0x80).to_u8)
      streams.values[1].should eq(1_u8) if prefix_bytes == 2
      limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 1000, max_elements: 1000, max_bytes: exact_bytes)
      encoded = CrystalClick::ObjectSharedCopyCodec.encode([row], records, limits)
      encoded.values.should eq(streams.values)
      CrystalClick::ObjectSharedCopyCodec.decode(encoded.sizes, encoded.indexes, encoded.values, records, limits)[0].entry_at(0).value.as_string.should eq(payload)
      tight = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 1000, max_elements: 1000, max_bytes: exact_bytes - 1)
      expect_raises(CrystalClick::UnsupportedFormatError, /byte limit/) do
        CrystalClick::ObjectSharedCopyCodec.encode([row], records, tight)
      end
      expect_raises(CrystalClick::CorruptPartError, /byte limit/) do
        CrystalClick::ObjectSharedCopyCodec.decode(encoded.sizes, encoded.indexes, encoded.values, records, tight)
      end
    end
  end

  it "plans ADVANCED and CHUNKED Copy and bucket lanes without borrowing MAP roles" do
    expected_lanes = [
      "structure",
      "data",
      "paths_marks",
      "substreams",
      "substreams_marks",
      "paths_substreams_metadata",
    ]
    {2_u64, 3_u64}.each do |version|
      structure = CrystalClick::ObjectStructure.new([] of String, shared_data_version: version, bucket_count: 2_u64)
      CrystalClick::ObjectSharedBucketLayout.supported?(structure).should be_true
      CrystalClick::ObjectSharedBucketLayout.validate!(structure).should be_nil
      plan = CrystalClick::ObjectDocumentPlan.new(
        CrystalClick::ObjectDynamicStructureSet.new(
          structure,
          {} of String => CrystalClick::DynamicStructure,
        ),
        {} of String => CrystalClick::BinaryDataType,
      )
      physical = CrystalClick::ObjectDocumentPhysicalPlan.new("doc", plan)

      physical.advanced_copy_stream_name("sizes").should eq("doc.object_shared_data.copy.sizes")
      physical.advanced_copy_stream_name("indexes").should eq("doc.object_shared_data.copy.paths_indexes")
      physical.advanced_copy_stream_name("values").should eq("doc.object_shared_data.copy.values")
      physical.advanced_bucket_stream_name(0, "structure").should eq("doc.object_shared_data.0.structure")
      physical.advanced_bucket_stream_name(1, "paths_substreams_metadata").should eq("doc.object_shared_data.1.paths_substreams_metadata")

      expected_names = [
        "doc.object_shared_data.copy.sizes",
        "doc.object_shared_data.copy.paths_indexes",
        "doc.object_shared_data.copy.values",
      ]
      2.times do |bucket|
        expected_lanes.each { |lane| expected_names << "doc.object_shared_data.#{bucket}.#{lane}" }
      end
      physical.advanced_stream_names.should eq(expected_names.sort)
      physical.advanced_stream_name?("doc.object_shared_data.0.size0").should be_false
      physical.advanced_stream_name?("doc.object_shared_data.1.paths").should be_false
    end
  end
end
