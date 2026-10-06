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
    type = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    json_row = CrystalClick::BinaryJsonRow.new(type, [] of Tuple(String, CrystalClick::BinaryValue))
    envelope = CrystalClick::BinaryValueCodec.encode(CrystalClick::BinaryValue.json(type, json_row))
    CrystalClick::BinaryValueCodec.decode(envelope).type.should eq(type)
    envelope.size.should be < 128
    values = Bytes.new(envelope.size + 1) { |index| index == 0 ? envelope.size.to_u8 : envelope[index - 1] }
    expect_raises(CrystalClick::UnsupportedFormatError, /JSON is not admitted/) do
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

  it "does not admit persisted advanced documents on the strength of Copy support" do
    {2_u64, 3_u64}.each do |version|
      structure = CrystalClick::ObjectStructure.new([] of String, shared_data_version: version, bucket_count: 1_u64)
      CrystalClick::ObjectSharedBucketLayout.supported?(structure).should be_false
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectSharedBucketLayout.validate!(structure) }
    end
  end
end
