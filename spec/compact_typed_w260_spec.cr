require "./spec_helper"
require "../scripts/support/compact_typed_w260_fixture"
require "../scripts/support/compact_physical_context_w259_fixture"
require "../src/crystal_click/compact_binary_bulk_normalizer"

private class W260WorkspaceLimitReached < Exception
end

private def w260_expected_lookup_index_workspace_bytes(slot_counts : Array(Int32)) : UInt64
  bytes = instance_sizeof(Hash(String, Array(CrystalClick::CompactPhysicalSlot))).to_u64
  hash_entry_bytes = sizeof(Pointer(String)).to_u64 +
                     sizeof(Pointer(Array(CrystalClick::CompactPhysicalSlot))).to_u64 + 8_u64
  bytes += slot_counts.size.to_u64 * hash_entry_bytes
  slot_counts.each do |slot_count|
    bytes += instance_sizeof(Array(CrystalClick::CompactPhysicalSlot)).to_u64
    bytes += slot_count.to_u64 * sizeof(Pointer(CrystalClick::CompactPhysicalSlot)).to_u64
  end
  bytes
end

private def w260_profile_record(name : String, rows : Int32 = 2) : String
  "{\"kind\":\"Default\",\"name\":\"#{name}\",\"num_defaults\":0,\"num_rows\":#{rows}}"
end

private def w260_child_profile_record(rows : Int32 = 2) : String
  "{\"kind\":\"Default\",\"num_defaults\":0,\"num_rows\":#{rows}}"
end

private def w260_batch_for(
  type : CrystalClick::BinaryDataType,
  row_count : UInt64 = 1_u64,
) : CrystalClick::WidePartTableBatch
  CrystalClick::WidePartTableBatch.new(
    0_i32,
    "all_1_1_0",
    "",
    0_i32,
    0_u64,
    0_u64,
    0_u64,
    ["payload"],
    [type.name],
    [] of CrystalClick::WidePartNumericSlice,
    row_count: row_count,
  )
end

private alias W260NormalizerEvent = Tuple(String, Bytes)

private def w260_u64_bytes(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w260_join_bytes(parts : Array(Bytes)) : Bytes
  memory = IO::Memory.new
  parts.each { |part| memory.write(part) }
  memory.to_slice
end

private def w260_varuint_bytes(value : UInt64) : Bytes
  memory = IO::Memory.new
  remaining = value
  while remaining >= 0x80_u64
    memory.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  memory.write_byte(remaining.to_u8)
  memory.to_slice
end

private def w260_workspace_mrk4_bytes(
  positions : Array(Tuple(UInt64, UInt64)),
  slot_count : Int,
  rows : UInt64,
) : Bytes
  raise "W260 workspace fixture has an invalid position count" unless positions.size == slot_count + 1
  record_size = slot_count * 16 + 8
  marks = Bytes.new(record_size * 2, 0_u8)
  slot_count.times do |slot|
    offset = slot * 16
    CompactPhysicalContextW259Fixture.write_u64(marks, offset, positions[slot][0])
    CompactPhysicalContextW259Fixture.write_u64(marks, offset + 8, positions[slot][1])
  end
  CompactPhysicalContextW259Fixture.write_u64(marks, slot_count * 16, rows)
  eof_offset = record_size
  terminal = positions.last
  slot_count.times do |slot|
    offset = eof_offset + slot * 16
    CompactPhysicalContextW259Fixture.write_u64(marks, offset, terminal[0])
    CompactPhysicalContextW259Fixture.write_u64(marks, offset + 8, terminal[1])
  end
  CompactPhysicalContextW259Fixture.write_u64(marks, eof_offset + slot_count * 16, 0_u64)
  marks
end

private def w260_write_workspace_part(
  part_path : String,
  child_count : Int,
  include_baseline_column : Bool = false,
) : Nil
  FileUtils.mkdir_p(part_path)
  type = w260_parse_type("Array(Variant(String, UInt64))")
  profile = CrystalClick::BinaryBulkProfile.single_stream
  physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, "payload", profile)
  variant_role = "root.elements.discriminators"
  names = physical.stream_names
  callbacks = CrystalClick::CompactBinaryBulkNormalizer.new(type, "payload", profile)
    .expected_physical_callback_roster

  callback_bytes = Hash(String, Bytes).new
  callback_bytes[CrystalClick::PhysicalStreamName.append_literal(names[variant_role], "_prefix")] =
    w260_u64_bytes(CrystalClick::DynamicDiscriminatorBodyValidator::COMPACT_MODE)
  callback_bytes[names["root.sizes"]] = w260_u64_bytes(child_count.to_u64)
  if child_count == 0
    callback_bytes[names[variant_role]] = Bytes.new(0)
  else
    callback_bytes[names[variant_role]] = w260_join_bytes([
      w260_varuint_bytes(child_count.to_u64),
      Bytes[CrystalClick::DynamicDiscriminatorBodyValidator::COMPACT_UNIFORM_TAG, 0xff_u8],
    ] of Bytes)
  end
  # The uniform COMPACT Variant tag selects NULL, so the discriminator tape
  # stays O(1) and both child-arm tapes stay empty while recursive Q is large.
  callback_bytes[names["root.elements.arm.0.data"]] = Bytes.new(0)
  callback_bytes[names["root.elements.arm.1.data"]] = Bytes.new(0)

  column_specs = [{"payload", type.name, callbacks, callback_bytes}] of Tuple(String, String, Array(String), Hash(String, Bytes))
  if include_baseline_column
    baseline_type = w260_parse_type("UInt64")
    baseline_profile = CrystalClick::BinaryBulkProfile.single_stream
    baseline_physical = CrystalClick::BinaryBulkPhysicalPlan.new(baseline_type, "baseline", baseline_profile)
    baseline_callbacks = CrystalClick::CompactBinaryBulkNormalizer.new(
      baseline_type,
      "baseline",
      baseline_profile,
    ).expected_physical_callback_roster
    baseline_bytes = Hash(String, Bytes).new
    baseline_data_name = baseline_physical.stream_names["root.data"]
    baseline_bytes[baseline_data_name] = w260_u64_bytes(7_u64)
    column_specs << {"baseline", baseline_type.name, baseline_callbacks, baseline_bytes}
  end

  all_callbacks = [] of String
  shards = [] of Bytes
  column_specs.each do |column_name, _type_name, column_callbacks, bytes_by_name|
    column_callbacks.each do |name|
      all_callbacks << name
      shards << (bytes_by_name[name]? || raise("W260 workspace fixture lacks callback bytes for #{column_name}: #{name}"))
    end
  end
  raw = w260_join_bytes(shards)
  queries = [] of UInt64
  cursor = 0_u64
  shards.each do |shard|
    queries << cursor
    cursor += shard.size.to_u64
  end
  queries << cursor
  positioned = CrystalClick::CompressedMarkWriter.encode_with_positions(
    raw,
    [0_u64, raw.size.to_u64],
    [1_u64],
    queries,
  )

  columns_text = String.build do |io|
    io << "columns format version: 1\n" << column_specs.size << " columns:\n"
    column_specs.each do |column_name, type_name, _column_callbacks, _bytes_by_name|
      io << '`' << column_name << "` " << type_name << '\n'
    end
  end
  File.write(File.join(part_path, "columns.txt"), columns_text)
  File.write(File.join(part_path, "count.txt"), "1\n")
  File.write(File.join(part_path, "default_compression_codec.txt"), "CODEC(LZ4)")
  records = column_specs.map { |column_name, _type_name, _column_callbacks, _bytes_by_name| w260_profile_record(column_name, 1) }
  File.write(File.join(part_path, "serialization.json"), CompactTypedW260Fixture.profile_envelope(records))
  File.write(File.join(part_path, "columns_substreams.txt"), String.build do |io|
    io << "columns substreams version: 1\n" << column_specs.size << " columns:\n"
    column_specs.each do |column_name, _type_name, column_callbacks, _bytes_by_name|
      io << column_callbacks.size << " substreams for column `" << column_name << "`:\n"
      column_callbacks.each { |name| io << '\t' << name << '\n' }
    end
  end)
  File.write(File.join(part_path, "data.bin"), positioned.files.data)
  File.write(File.join(part_path, "data.mrk4"),
    w260_workspace_mrk4_bytes(positioned.positions, all_callbacks.size, 1_u64))
  CompactPhysicalContextW259Fixture.refresh_checksums(part_path)
end

private def w260_body_event(
  plan : CrystalClick::BinaryBulkPhysicalPlan,
  role : String,
  bytes : Bytes,
) : W260NormalizerEvent
  {plan.stream_name_for(role), bytes}
end

private def w260_prefix_event(
  plan : CrystalClick::BinaryBulkPhysicalPlan,
  role : String,
  bytes : Bytes,
) : W260NormalizerEvent
  {CrystalClick::PhysicalStreamName.append_literal(plan.stream_name_for(role), "_prefix"), bytes}
end

private def w260_normalize_window(
  type : CrystalClick::BinaryDataType,
  profile : CrystalClick::BinaryBulkProfile,
  mode : CrystalClick::CompactMarkFormat,
  events_by_mark : Array(Array(W260NormalizerEvent)),
  rows_per_mark : Array(UInt64),
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
  budget : CrystalClick::BinaryCodecBudget? = nil,
) : Tuple(CrystalClick::BinaryBulkStreams, Array(UInt64))
  raise ArgumentError.new("W260 synthetic event and row grids differ") unless events_by_mark.size == rows_per_mark.size

  row_offset = 0_u64
  granules = Array(CrystalClick::CompactPartPhysicalGranule).new(events_by_mark.size) do |mark|
    events = events_by_mark[mark]
    shards = Array(CrystalClick::CompactPartPhysicalShard).new(events.size) do |slot|
      name, bytes = events[slot]
      CrystalClick::CompactPartPhysicalShard.new(
        slot.to_i32,
        name,
        0_i64,
        bytes.size.to_i64,
        bytes,
      )
    end
    granule = CrystalClick::CompactPartPhysicalGranule.new(mark.to_i32, row_offset, rows_per_mark[mark], shards)
    row_offset += rows_per_mark[mark]
    granule
  end
  window = CrystalClick::CompactPartPhysicalWindow.new(mode, "payload", 0_i32, 0_u64, granules)
  normalizer = CrystalClick::CompactBinaryBulkNormalizer.new(type, "payload", profile, limits)
  operation_budget = budget || CrystalClick::BinaryCodecBudget.new(limits)
  normalizer.normalize(window, operation_budget)
end

private def w260_parse_type(name : String) : CrystalClick::BinaryDataType
  CrystalClick::StaticBinaryBulkColumnDeclaration.parse(name).not_nil!
end

private def w260_lc_index_frame : Bytes
  parts = [
    w260_u64_bytes(CrystalClick::BinaryLowCardinalityStorageStreams::ADDITIONAL_BIT |
                   CrystalClick::BinaryLowCardinalityStorageStreams::UPDATE_BIT),
    w260_u64_bytes(2_u64),
    w260_u64_bytes(42_u64),
    w260_u64_bytes(43_u64),
    w260_u64_bytes(2_u64),
    Bytes[0_u8, 1_u8],
  ] of Bytes
  w260_join_bytes(parts)
end

describe CrystalClick::CompactSerializationProfile do
  it "admits a nested Tuple Default profile without optional exact_num_defaults flags" do
    root = File.tempname("crystal-click-w260-tuple-profile-")
    begin
      child_tuple = "{\"kind\":\"Default\",\"num_defaults\":0,\"num_rows\":2," \
                    "\"subcolumns\":[#{w260_child_profile_record},#{w260_child_profile_record}] }"
      top_tuple = "{\"kind\":\"Default\",\"name\":\"payload\",\"num_defaults\":0,\"num_rows\":2," \
                  "\"subcolumns\":[#{child_tuple},#{w260_child_profile_record}] }"
      json = CompactTypedW260Fixture.profile_envelope([top_tuple])
      CompactTypedW260Fixture.write_profile_metadata(root, json)

      profile = CompactTypedW260Fixture.open_profile(
        root,
        "payload",
        "Tuple(left Tuple(x UInt64, y String), right String)",
        2_u64,
      )
      profile.ordinary_profile.should eq(CrystalClick::BinaryBulkProfile.single_stream)
      profile.propagated_nested_versions.should be_true

      CompactTypedW260Fixture.write_profile_metadata(
        root,
        CompactTypedW260Fixture.profile_envelope([] of String),
      )
      optional_columns = CompactTypedW260Fixture.open_profile(
        root,
        "payload",
        "Tuple(left Tuple(x UInt64, y String), right String)",
        2_u64,
      )
      optional_columns.ordinary_profile.single_stream?.should be_true
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "selects String v0 and v1 from explicit metadata, not payload guessing" do
    root_v0 = File.tempname("crystal-click-w260-string-v0-")
    root_v1 = File.tempname("crystal-click-w260-string-v1-")
    begin
      record = w260_profile_record("payload")
      CompactTypedW260Fixture.write_profile_metadata(
        root_v0,
        CompactTypedW260Fixture.profile_envelope([record], "{}"),
      )
      CompactTypedW260Fixture.write_profile_metadata(
        root_v1,
        CompactTypedW260Fixture.profile_envelope([record], "{\"string\":1}", false),
      )

      type_name = "String"
      v0 = CompactTypedW260Fixture.open_profile(root_v0, "payload", type_name, 2_u64)
      v1 = CompactTypedW260Fixture.open_profile(root_v1, "payload", type_name, 2_u64)
      v0.ordinary_profile.single_stream?.should be_true
      v1.ordinary_profile.with_size_stream?.should be_true
      v1.propagated_nested_versions.should be_false
    ensure
      FileUtils.rm_rf(root_v0)
      FileUtils.rm_rf(root_v1)
    end
  end

  it "retains borrowed metadata-file budget charges across profile opens" do
    root = File.tempname("crystal-click-w260-profile-budget-")
    begin
      record = w260_profile_record("payload")
      CompactTypedW260Fixture.write_profile_metadata(root, CompactTypedW260Fixture.profile_envelope([record]))
      maximum = File.size(File.join(root, "default_compression_codec.txt")) +
                File.size(File.join(root, "serialization.json"))
      limits = CrystalClick::CompressedStreamLimits.new(max_file_bytes: maximum)
      budget = CrystalClick::CompressedStreamBudget.new(limits)

      CompactTypedW260Fixture.open_profile(root, "payload", "String", 2_u64, budget)
      budget.file_byte_count.should eq(maximum)
      expect_raises(CrystalClick::CorruptPartError) do
        CompactTypedW260Fixture.open_profile(root, "payload", "String", 2_u64, budget)
      end
      budget.file_byte_count.should eq(maximum)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end

describe CrystalClick::CompactBinaryBulkNormalizer do
  it "does not reset a borrowed recursive wire-byte budget between normalizations" do
    type = w260_parse_type("UInt64")
    profile = CrystalClick::BinaryBulkProfile.single_stream
    physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, "payload", profile)
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 64, max_elements: 64, max_bytes: 128)
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    payload = w260_join_bytes(Array(Bytes).new(16) { |index| index == 0 ? w260_u64_bytes(99_u64) : Bytes.new(8) })
    events = [[w260_body_event(physical, "root.data", payload)]] of Array(W260NormalizerEvent)

    streams, rows = w260_normalize_window(
      type,
      profile,
      CrystalClick::CompactMarkFormat::Mrk4,
      events,
      [16_u64],
      limits,
      budget,
    )
    CrystalClick::BinaryBulkCodec.decode(type, streams, rows, profile: profile)[0][0].as_uint64.should eq(99_u64)
    budget.wire_byte_count.should eq(128_i64)

    expect_raises(CrystalClick::CorruptPartError) do
      w260_normalize_window(
        type,
        profile,
        CrystalClick::CompactMarkFormat::Mrk4,
        events,
        [16_u64],
        limits,
        budget,
      )
    end
    budget.wire_byte_count.should eq(128_i64)
  end

  it "retains v0 String VarUInt prefixes while splitting nested Array values into role lanes" do
    type = w260_parse_type("Array(String)")
    profile = CrystalClick::BinaryBulkProfile.single_stream
    physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, "payload", profile)
    events = [
      w260_body_event(physical, "root.sizes", w260_join_bytes([w260_u64_bytes(2_u64), w260_u64_bytes(0_u64)])),
      w260_body_event(physical, "root.elements.data", Bytes[1_u8, 'a'.ord.to_u8, 0_u8]),
    ] of W260NormalizerEvent

    streams, rows = w260_normalize_window(
      type,
      profile,
      CrystalClick::CompactMarkFormat::Mrk4,
      [events],
      [2_u64],
    )

    rows.should eq([2_u64])
    streams.stream("root.elements.data").bytes.should eq(Bytes[1_u8, 'a'.ord.to_u8, 0_u8])
    decoded = CrystalClick::BinaryBulkCodec.decode(type, streams, rows, profile: profile)
    decoded.size.should eq(1)
    decoded[0].size.should eq(2)
    decoded[0][0].elements.map(&.as_string).should eq(["a", ""])
    decoded[0][1].elements.should be_empty
  end

  it "rejects mrk4 reordering of equal-width Tuple String callbacks" do
    type = w260_parse_type("Tuple(a String, b String)")
    profile = CrystalClick::BinaryBulkProfile.single_stream
    physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, "payload", profile)
    first = w260_body_event(physical, "root.field.0.data", Bytes[2_u8, 'a'.ord.to_u8, 'a'.ord.to_u8])
    second = w260_body_event(physical, "root.field.1.data", Bytes[2_u8, 'b'.ord.to_u8, 'b'.ord.to_u8])

    streams, rows = w260_normalize_window(
      type,
      profile,
      CrystalClick::CompactMarkFormat::Mrk4,
      [[first, second]],
      [1_u64],
    )
    value = CrystalClick::BinaryBulkCodec.decode(type, streams, rows, profile: profile)[0][0]
    value.child_at(0).as_string.should eq("aa")
    value.child_at(1).as_string.should eq("bb")

    expect_raises(CrystalClick::CorruptPartError) do
      w260_normalize_window(
        type,
        profile,
        CrystalClick::CompactMarkFormat::Mrk4,
        [[second, first]],
        [1_u64],
      )
    end
  end

  it "requires the empty Variant-arm callback even when that arm has zero children" do
    type = w260_parse_type("Variant(String, UInt64)")
    profile = CrystalClick::BinaryBulkProfile.single_stream
    physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, "payload", profile)
    prefix = w260_prefix_event(
      physical,
      "root.discriminators",
      w260_u64_bytes(CrystalClick::DynamicDiscriminatorBodyValidator::BASIC_MODE),
    )
    discriminator = w260_body_event(physical, "root.discriminators", Bytes[0_u8])
    string_arm = w260_body_event(physical, "root.arm.0.data", Bytes[1_u8, 'x'.ord.to_u8])
    empty_uint64_arm = w260_body_event(physical, "root.arm.1.data", Bytes.new(0))
    events = [prefix, discriminator, string_arm, empty_uint64_arm] of W260NormalizerEvent

    streams, rows = w260_normalize_window(
      type,
      profile,
      CrystalClick::CompactMarkFormat::Mrk4,
      [events],
      [1_u64],
    )
    value = CrystalClick::BinaryBulkCodec.decode(type, streams, rows, profile: profile)[0][0]
    value.variant_index?.should eq(0_u8)
    value.variant_child?.not_nil!.as_string.should eq("x")

    expect_raises(CrystalClick::CorruptPartError) do
      w260_normalize_window(
        type,
        profile,
        CrystalClick::CompactMarkFormat::Mrk4,
        [[prefix, discriminator, string_arm]],
        [1_u64],
      )
    end
  end

  it "retains the LowCardinality v1 header and decodes a selected slice from the full mark grid" do
    type = w260_parse_type("LowCardinality(UInt64)")
    profile = CrystalClick::BinaryBulkProfile.single_stream
    physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, "payload", profile)
    prefix = w260_prefix_event(
      physical,
      "root.dictionary",
      w260_u64_bytes(CrystalClick::BinaryLowCardinalityStorageStreams::VERSION),
    )
    dictionary = w260_body_event(physical, "root.dictionary", Bytes.new(0))
    indexes = w260_body_event(physical, "root.indexes", w260_lc_index_frame)
    empty_indexes = w260_body_event(physical, "root.indexes", Bytes.new(0))

    streams, rows = w260_normalize_window(
      type,
      profile,
      CrystalClick::CompactMarkFormat::Mrk4,
      [[prefix, dictionary, indexes], [prefix, dictionary, empty_indexes]],
      [2_u64, 0_u64],
    )

    streams.mark_count.should eq(2)
    streams.stream("root.dictionary").bytes.should eq(w260_u64_bytes(CrystalClick::BinaryLowCardinalityStorageStreams::VERSION))
    streams.stream("root.dictionary").offsets.should eq([8_u64, 8_u64, 8_u64])
    full = CrystalClick::BinaryBulkCodec.decode(type, streams, rows, profile: profile)
    full[0].map { |value| value.child_at(0).as_uint64 }.should eq([42_u64, 43_u64])
    full[1].should be_empty

    selected = CrystalClick::BinaryBulkCodec.decode(
      type,
      streams,
      rows,
      first_mark: 1,
      mark_count: 1,
      profile: profile,
    )
    selected.should eq([[] of CrystalClick::BinaryValue])
  end

  it "bounds Q-sized Compact Variant NULL expansion before tag allocation" do
    root = File.tempname("crystal-click-w260-workspace-")
    empty_root = File.tempname("crystal-click-w260-workspace-empty-")
    child_count = 1024
    begin
      w260_write_workspace_part(root, child_count)
      type = w260_parse_type("Array(Variant(String, UInt64))")
      reader = CrystalClick::CompactBinaryBulkColumnReader.open(root, "payload", type)
      observed = [] of UInt64
      marks = reader.read_marks(0, 1, ->(workspace_bytes : UInt64) do
        observed << workspace_bytes
        nil
      end)

      observed.should_not be_empty
      observed.size.should be >= 2
      observed[0].should eq(reader.logical_read_bytes)
      marks.size.should eq(1)
      marks[0].size.should eq(1)
      value = marks[0][0]
      value.type.should eq(type)
      value.elements.size.should eq(child_count)
      value.elements.each do |variant|
        variant.variant_index?.should be_nil
        variant.variant_child?.should be_nil
        variant.is_null?.should be_true
      end
      reader.logical_read_bytes.should be < child_count.to_u64

      # An empty-array control measures the same fixed-role normalizer overhead
      # without recursive Variant occurrences. Match the discriminator adapter
      # preflight by its Q-dependent workspace delta, then choose a cap between
      # the empty and large controls before expanded tags can be allocated.
      w260_write_workspace_part(empty_root, 0)
      empty_reader = CrystalClick::CompactBinaryBulkColumnReader.open(empty_root, "payload", type)
      empty_observed = [] of UInt64
      empty_marks = empty_reader.read_marks(0, 1, ->(workspace_bytes : UInt64) do
        empty_observed << workspace_bytes
        nil
      end)
      empty_marks[0][0].elements.should be_empty
      empty_observed.size.should eq(observed.size)
      empty_observed[0].should eq(empty_reader.logical_read_bytes)

      discriminator_preflight_indices = [] of Int32
      (0...(observed.size - 1)).each do |index|
        previous = observed[index]
        current = observed[index + 1]
        if current >= previous && current - previous == child_count.to_u64 + 16_u64
          discriminator_preflight_indices << (index + 1).to_i32
        end
      end
      discriminator_preflight_indices.size.should eq(1)
      discriminator_preflight_index = discriminator_preflight_indices[0]
      discriminator_preflight = observed[discriminator_preflight_index]

      # The empty control has two legitimate +16 observations: the adapter's
      # Q=0 tag/offset preflight and the following two-arm Variant count array.
      # Align by source sequence with the unique Q+16 event above rather than
      # selecting an ambiguous delta or relying on a fixed observer ordinal.
      discriminator_preflight_index.should be > 0
      empty_preflight_index = discriminator_preflight_index
      empty_observed[empty_preflight_index].should be >= empty_observed[empty_preflight_index - 1]
      (empty_observed[empty_preflight_index] - empty_observed[empty_preflight_index - 1]).should eq(16_u64)

      physical_base = observed[1]
      empty_base = empty_observed[1]
      discriminator_preflight.should be >= physical_base
      empty_preflight = empty_observed[empty_preflight_index]
      empty_preflight.should be >= empty_base
      empty_preflight_relative = empty_preflight - empty_base
      large_preflight_relative = discriminator_preflight - physical_base
      large_preflight_relative.should be >= empty_preflight_relative
      (large_preflight_relative - empty_preflight_relative).should be >= child_count.to_u64
      max_workspace = physical_base + empty_preflight_relative + (child_count / 2).to_u64
      observed[0...discriminator_preflight_index].max.should be <= max_workspace
      discriminator_preflight.should be > max_workspace

      first_over_cap_index = -1_i32
      observed.each_with_index do |workspace_bytes, index|
        if workspace_bytes > max_workspace
          first_over_cap_index = index.to_i32
          break
        end
      end
      first_over_cap_index.should eq(discriminator_preflight_index)

      constrained = CrystalClick::CompactBinaryBulkColumnReader.open(root, "payload", type)
      constrained_observed = [] of UInt64
      expect_raises(W260WorkspaceLimitReached) do
        constrained.read_marks(0, 1, ->(workspace_bytes : UInt64) do
          constrained_observed << workspace_bytes
          raise W260WorkspaceLimitReached.new("Compact workspace cap exceeded") if workspace_bytes > max_workspace
          nil
        end)
      end
      constrained_observed.size.should eq(discriminator_preflight_index + 1)
      constrained_observed.last.should eq(discriminator_preflight)
    ensure
      FileUtils.rm_rf(root)
      FileUtils.rm_rf(empty_root)
    end
  end
end

describe CrystalClick::BinaryValueTypedBatchAdapter do
  it "materializes exact legacy Tuple carriers without widening generic accessors" do
    tuple_type = CrystalClick::StaticBinaryBulkColumnDeclaration.parse("Tuple(a UInt64, b String)").not_nil!
    tuple_value = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [CrystalClick::BinaryValue.uint64(55_u64), CrystalClick::BinaryValue.string("tuple-value")],
    )
    tuple_values = [tuple_value] of CrystalClick::BinaryValue
    tuple_batch = w260_batch_for(tuple_type)

    CrystalClick::BinaryValueTypedBatchAdapter.admitted?(tuple_type).should be_true
    CrystalClick::BinaryValueTypedBatchAdapter.install(
      tuple_batch,
      "payload",
      tuple_type,
      tuple_values.to_unsafe.to_slice(tuple_values.size),
      1_i32,
    )
    tuple_batch.tuples_for("payload").to_a.should eq([{55_u64, "tuple-value"}])
    expect_raises(CrystalClick::UnsupportedFormatError) do
      tuple_batch.binary_bulk_values_for("payload")
    end

    array_type = CrystalClick::BinaryDataType.array(tuple_type)
    array_value = CrystalClick::BinaryValue.array(array_type, [tuple_value] of CrystalClick::BinaryValue)
    array_values = [array_value] of CrystalClick::BinaryValue
    array_batch = w260_batch_for(array_type)

    CrystalClick::BinaryValueTypedBatchAdapter.admitted?(array_type).should be_true
    CrystalClick::BinaryValueTypedBatchAdapter.install(
      array_batch,
      "payload",
      array_type,
      array_values.to_unsafe.to_slice(array_values.size),
      1_i32,
    )
    array_batch.array_tuple_uint64_string_for("payload").to_a.should eq([[{55_u64, "tuple-value"}]])
    expect_raises(CrystalClick::UnsupportedFormatError) do
      array_batch.binary_bulk_values_for("payload")
    end
  end

  it "installs Compact Array(Nullable(UInt64)) into both existing typed carrier views" do
    array_type = CrystalClick::StaticBinaryBulkColumnDeclaration.parse("Array(Nullable(UInt64))").not_nil!
    nullable_type = array_type.child_at(0)
    array_values = [
      CrystalClick::BinaryValue.array(array_type, [
        CrystalClick::BinaryValue.nullable(nullable_type),
        CrystalClick::BinaryValue.nullable(nullable_type, CrystalClick::BinaryValue.uint64(17_u64)),
      ] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array_type, [
        CrystalClick::BinaryValue.nullable(nullable_type, CrystalClick::BinaryValue.uint64(23_u64)),
        CrystalClick::BinaryValue.nullable(nullable_type),
      ] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
    batch = w260_batch_for(array_type, 2_u64)

    CrystalClick::BinaryValueTypedBatchAdapter.admitted?(array_type).should be_true
    CrystalClick::BinaryValueTypedBatchAdapter.install(
      batch,
      "payload",
      array_type,
      array_values.to_unsafe.to_slice(array_values.size),
      2_i32,
    )

    legacy_values = batch.array_nullable_uint64s_for("payload")
    numeric_values = batch.array_nullable_numeric_values("payload", UInt64)
    legacy_values.size.should eq(2)
    legacy_values[0].should eq([nil, 17_u64] of UInt64?)
    legacy_values[1].should eq([23_u64, nil] of UInt64?)
    numeric_values[0].should eq(legacy_values[0])
    numeric_values[1].should eq(legacy_values[1])
    numeric_values.to_unsafe.should eq(legacy_values.to_unsafe)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      batch.binary_bulk_values_for("payload")
    end
  end

  it "keeps Compact nullable Array carrier declaration and row-count guards exact" do
    array_type = CrystalClick::StaticBinaryBulkColumnDeclaration.parse("Array(Nullable(UInt64))").not_nil!
    nullable_type = array_type.child_at(0)
    array_values = [
      CrystalClick::BinaryValue.array(array_type, [
        CrystalClick::BinaryValue.nullable(nullable_type),
      ] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
    binary_values = array_values.to_unsafe.to_slice(array_values.size)
    carrier_values = [[] of UInt64?] of Array(UInt64?)
    carrier_slice = carrier_values.to_unsafe.to_slice(carrier_values.size)
    short_batch = w260_batch_for(array_type)
    expect_raises(CrystalClick::CorruptPartError) do
      short_batch.install_compact_array_nullable_uint64_values(
        "payload",
        carrier_slice,
        2_i32,
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueTypedBatchAdapter.install(
        short_batch,
        "payload",
        array_type,
        binary_values,
        2_i32,
      )
    end

    neighboring_type = CrystalClick::StaticBinaryBulkColumnDeclaration.parse("Array(Nullable(UInt32))").not_nil!
    neighboring_batch = w260_batch_for(neighboring_type)
    expect_raises(CrystalClick::CorruptPartError) do
      neighboring_batch.install_compact_array_nullable_uint64_values(
        "payload",
        carrier_slice,
        1_i32,
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      neighboring_batch.array_nullable_uint64s_for("payload")
    end
  end
end

# Spec-only reopened helpers let the regression inject a conservative logical
# workspace estimate without widening the production reader/table API.
class CrystalClick::CompactColumnsSubstreams
  class_property w260_test_columns_calls = 0
  class_property w260_test_roster_calls = 0

  def columns : Array({String, String})
    CrystalClick::CompactColumnsSubstreams.w260_test_columns_calls += 1
    previous_def
  end

  def roster : Array(CompactPhysicalSlot)
    CrystalClick::CompactColumnsSubstreams.w260_test_roster_calls += 1
    previous_def
  end
end

describe CrystalClick::CompactColumnsSubstreams do
  it "counts the mrk3 lookup index for one and sixteen columns" do
    one = CrystalClick::CompactColumnsSubstreams.new(
      CrystalClick::CompactMarkFormat::Mrk3,
      [{"c0", "UInt64"}],
    )
    sixteen_columns = Array({String, String}).new(16) do |index|
      {"c#{index}", "UInt64"}
    end
    sixteen = CrystalClick::CompactColumnsSubstreams.new(
      CrystalClick::CompactMarkFormat::Mrk3,
      sixteen_columns,
    )

    one.retained_lookup_index_workspace_bytes.should eq(w260_expected_lookup_index_workspace_bytes([1_i32]))
    sixteen.retained_lookup_index_workspace_bytes.should eq(
      w260_expected_lookup_index_workspace_bytes(Array(Int32).new(16, 1_i32)),
    )
    sixteen.retained_lookup_index_workspace_bytes.should be > one.retained_lookup_index_workspace_bytes
  end

  it "counts mrk4 per-column callback arrays independent of slot interval lengths" do
    columns = [{"a", "Array(UInt64)"}, {"b", "String"}] of {String, String}
    streams = [
      {"a", ["root.sizes", "root.elements.data"]},
      {"b", ["root.data"]},
    ] of {String, Array(String)}
    roster = CrystalClick::CompactColumnsSubstreams.new(
      CrystalClick::CompactMarkFormat::Mrk4,
      columns,
      streams,
    )

    # This subtotal is roster-only: adjacent marks may give any slot an empty
    # interval, but its callback identity and per-column reference remain live.
    roster.retained_lookup_index_workspace_bytes.should eq(
      w260_expected_lookup_index_workspace_bytes([2_i32, 1_i32]),
    )
  end
end

class CrystalClick::CompactBinaryBulkColumnReader
  class_property w260_test_read_marks_calls = 0

  def retained_workspace_bytes : UInt64
    bytes = previous_def
    extra = @w260_test_workspace_extra_bytes || 0_u64
    if extra > UInt64::MAX - bytes
      raise CrystalClick::CorruptPartError.new("W260 injected workspace overflows")
    end
    bytes + extra
  end

  def read_marks(
    first_mark : Int,
    mark_count : Int,
    workspace_observer : Proc(UInt64, Nil),
  ) : Array(Array(BinaryValue))
    CrystalClick::CompactBinaryBulkColumnReader.w260_test_read_marks_calls += 1
    previous_def
  end

  def w260_test_inject_logical_read_bytes!(bytes : UInt64) : Nil
    @logical_read_bytes = bytes
  end

  def w260_test_inject_retained_workspace_extra!(bytes : UInt64) : Nil
    @w260_test_workspace_extra_bytes = bytes
  end
end

class CrystalClick::CompactPartTable
  def w260_test_inject_logical_read_bytes!(bytes : UInt64) : Nil
    @readers.each do |entry|
      entry[3].w260_test_inject_logical_read_bytes!(bytes)
    end
  end

  def w260_test_inject_reader_workspace_extra!(column : String, bytes : UInt64) : UInt64
    found = false
    estimate = 0_u64
    @readers.each do |entry|
      next unless entry[0] == column
      entry[3].w260_test_inject_retained_workspace_extra!(bytes)
      estimate = entry[3].retained_workspace_bytes
      found = true
    end
    raise "W260 selected test column was not found" unless found
    estimate
  end
end

describe CrystalClick::CompactBinaryBulkColumnReader do
  it "censuses retained context owners without cloning metadata snapshots" do
    root = File.tempname("crystal-click-w260-retained-context-census-")
    part_path = File.join(root, "all_1_1_0")
    begin
      w260_write_workspace_part(part_path, 0)
      type = w260_parse_type("Array(Variant(String, UInt64))")
      reader = CrystalClick::CompactBinaryBulkColumnReader.open(part_path, "payload", type)

      # Opening legitimately snapshots metadata. Reset afterward so this test
      # isolates temporary clones made by the retained-owner census itself.
      CrystalClick::CompactColumnsSubstreams.w260_test_columns_calls = 0
      CrystalClick::CompactColumnsSubstreams.w260_test_roster_calls = 0

      grid_workspace = reader.retained_grid_workspace_bytes
      total_workspace = reader.retained_workspace_bytes

      grid_workspace.should be > 0_u64
      total_workspace.should be >= grid_workspace
      CrystalClick::CompactColumnsSubstreams.w260_test_columns_calls.should eq(0)
      CrystalClick::CompactColumnsSubstreams.w260_test_roster_calls.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end

describe CrystalClick::CompactPartTable do
  it "propagates the shared logical workspace budget before exposing a typed batch" do
    root = File.tempname("crystal-click-w260-table-workspace-")
    part_path = File.join(root, "all_1_1_0")
    begin
      # This is a valid tiny part. Only its retained conservative byte estimate
      # is inflated below; no large String or physical payload is allocated.
      w260_write_workspace_part(part_path, 0)
      table = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["payload"])

      # Four-copy physical-window accounting makes this estimate exceed the
      # existing 64 MiB mark limit. This falsifies observer propagation only;
      # it does not model or assert a 64 MiB allocation/RSS boundary.
      injected_logical_bytes = 16_u64 * 1024_u64 * 1024_u64 + 1_u64
      table.w260_test_inject_logical_read_bytes!(injected_logical_bytes)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed(batch_rows: 1) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "preflights all selected reader owners before decoding the first column" do
    root = File.tempname("crystal-click-w260-aggregate-workspace-")
    part_path = File.join(root, "all_1_1_0")
    begin
      # Both selected readers are real independent Compact contexts opened from
      # this tiny two-column part. Each receives a synthetic conservative
      # workspace estimate; no large payload is allocated. Each estimate
      # remains admissible in isolation, while their live sum does not.
      w260_write_workspace_part(part_path, 0, include_baseline_column: true)
      table = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["payload", "baseline"])
      half_limit = CrystalClick::WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64 // 2_u64
      payload_workspace = table.w260_test_inject_reader_workspace_extra!("payload", half_limit)
      baseline_workspace = table.w260_test_inject_reader_workspace_extra!("baseline", half_limit)
      payload_workspace.should be < CrystalClick::WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
      baseline_workspace.should be < CrystalClick::WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
      (payload_workspace + baseline_workspace).should be > CrystalClick::WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64

      CrystalClick::CompactBinaryBulkColumnReader.w260_test_read_marks_calls = 0
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed(batch_rows: 1) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
      # Refusal before callback alone is insufficient: the old implementation
      # decoded `payload` before noticing the baseline owner of `baseline`.
      CrystalClick::CompactBinaryBulkColumnReader.w260_test_read_marks_calls.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "charges retained reader workspace once across a successful typed mark" do
    root = File.tempname("crystal-click-w260-workspace-once-")
    part_path = File.join(root, "all_1_1_0")
    begin
      w260_write_workspace_part(part_path, 0, include_baseline_column: true)
      table = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["payload", "baseline"])
      injected_workspace = 24_u64 * 1024_u64 * 1024_u64
      payload_workspace = table.w260_test_inject_reader_workspace_extra!("payload", injected_workspace)
      baseline_workspace = table.w260_test_inject_reader_workspace_extra!("baseline", injected_workspace)
      payload_workspace.should be < CrystalClick::WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
      baseline_workspace.should be < CrystalClick::WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
      (payload_workspace + baseline_workspace).should be < CrystalClick::WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64

      CrystalClick::CompactBinaryBulkColumnReader.w260_test_read_marks_calls = 0
      callbacks = 0
      table.scan_typed(batch_rows: 1) do |batch|
        callbacks += 1
        batch.row_count.not_nil!.should eq(1_u64)
        batch.values_for("baseline").to_a.should eq([7_u64])
        payload = batch.binary_bulk_values_for("payload")
        payload.size.should eq(1)
        payload[0].elements.should be_empty
      end
      callbacks.should eq(1)
      CrystalClick::CompactBinaryBulkColumnReader.w260_test_read_marks_calls.should eq(2)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
