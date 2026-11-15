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

private def w260_read_u64_le(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w260_write_u64_part(
  part_path : String,
  mark_format : CrystalClick::CompactMarkFormat,
  values : Array(UInt64),
  rows_per_mark : Int32 = 2,
  frame_bytes : Int32 = 11,
) : String
  raise ArgumentError.new("W260 UInt64 fixture needs at least one row") if values.empty?
  raise ArgumentError.new("W260 UInt64 fixture rows_per_mark must be positive") unless rows_per_mark > 0

  type = w260_parse_type("UInt64")
  granules = [] of Array(CrystalClick::BinaryValue)
  offset = 0
  while offset < values.size
    end_offset = Math.min(offset + rows_per_mark, values.size)
    granules << values[offset...end_offset].map { |value| CrystalClick::BinaryValue.uint64(value) }
    offset = end_offset
  end
  column = CrystalClick::CompactPartColumn.binary_bulk("payload", type, granules)
  keys = Array(UInt64).new(values.size) { |index| index.to_u64 + 1_u64 }
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    [column],
    rows_per_mark: rows_per_mark,
    frame_bytes: frame_bytes,
    mark_format: mark_format,
  )
end

private def w260_mark_file_name(mark_format : CrystalClick::CompactMarkFormat) : String
  mark_format.mrk3? ? "data.mrk3" : "data.mrk4"
end

private def w260_physical_slot_index(
  part_path : String,
  mark_format : CrystalClick::CompactMarkFormat,
  column_name : String,
) : Tuple(Int32, Int32)
  columns = CrystalClick::WidePart.parse_columns_metadata(File.read(File.join(part_path, "columns.txt")))
  substreams = if mark_format.mrk4?
                 CrystalClick::WidePart.parse_columns_substreams_metadata(
                   File.read(File.join(part_path, "columns_substreams.txt")),
                   columns,
                 )
               end
  roster = CrystalClick::CompactColumnsSubstreams.new(mark_format, columns, substreams)
  slot_index = -1_i32
  roster.roster.each_with_index do |slot, index|
    if slot.column_name == column_name
      slot_index = index.to_i32
      break
    end
  end
  raise "W260 selected physical slot is missing" if slot_index < 0
  {slot_index, roster.slot_count}
end

private def w260_flip_marked_frame_checksum!(
  part_path : String,
  mark_format : CrystalClick::CompactMarkFormat,
  column_name : String,
  mark_index : Int32,
) : Nil
  mark_name = w260_mark_file_name(mark_format)
  marks = File.read(File.join(part_path, mark_name)).to_slice
  slot_index, slot_count = w260_physical_slot_index(part_path, mark_format, column_name)
  record_width = slot_count * 16 + 8
  compressed_offset = w260_read_u64_le(marks, mark_index * record_width + slot_index * 16).to_i

  data_path = File.join(part_path, "data.bin")
  data = File.read(data_path).to_slice.dup
  unless compressed_offset >= 0 && compressed_offset <= data.size - CrystalClick::CompressedBlock::CHECKSUM_SIZE
    raise "W260 selected mark does not start at a compressed frame"
  end
  data[compressed_offset] ^= 1_u8
  File.write(data_path, data)
  CompactPhysicalContextW259Fixture.refresh_checksums(part_path)
end

private def w260_shorten_marked_uint64_span!(
  part_path : String,
  mark_format : CrystalClick::CompactMarkFormat,
  column_name : String,
) : Nil
  mark_name = w260_mark_file_name(mark_format)
  marks = File.read(File.join(part_path, mark_name)).to_slice.dup
  slot_index, slot_count = w260_physical_slot_index(part_path, mark_format, column_name)
  raise "W260 UInt64 fixture has an invalid physical roster" unless slot_count > slot_index
  decompressed_offset_field = slot_index * 16 + 8
  decompressed_offset = w260_read_u64_le(marks, decompressed_offset_field)
  # The helper writer uses 11-byte frames. Moving the first payload callback
  # one byte into its frame keeps the mark grid monotone while making its
  # fixed-width span 15 bytes instead of 16.
  raise "W260 span mutation would cross a frame" unless decompressed_offset < 10_u64
  CompactPhysicalContextW259Fixture.write_u64(
    marks,
    decompressed_offset_field,
    decompressed_offset + 1_u64,
  )
  File.write(File.join(part_path, mark_name), marks)
  CompactPhysicalContextW259Fixture.refresh_checksums(part_path)
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
      # without recursive Variant occurrences. Align the corresponding
      # discriminator expansion preflight by observation sequence, then choose
      # a cap between Q=0 and Q-sized preallocation before tags can be allocated.
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
      physical_base = observed[1]
      empty_base = empty_observed[1]

      discriminator_preflight_indices = [] of Int32
      (2...observed.size).each do |index|
        observed[index].should be >= physical_base
        empty_observed[index].should be >= empty_base
        large_relative = observed[index] - physical_base
        empty_relative = empty_observed[index] - empty_base
        if large_relative >= empty_relative && large_relative - empty_relative == child_count.to_u64
          discriminator_preflight_indices << index.to_i32
        end
      end
      discriminator_preflight_indices.size.should eq(1)
      discriminator_preflight_index = discriminator_preflight_indices[0]
      discriminator_preflight = observed[discriminator_preflight_index]

      # The matching empty-control event is the same source-sequence phase:
      # Compact Variant preflight charges only its Q-byte normalized tag lane.
      # The subsequent two-arm count-array observer has fixed +16 bytes, while
      # later lane ownership includes the expanded tag bytes and has a larger
      # delta. This exact Q differential therefore identifies pre-allocation.
      discriminator_preflight_index.should be > 0
      empty_preflight_index = discriminator_preflight_index

      discriminator_preflight.should be >= physical_base
      empty_preflight = empty_observed[empty_preflight_index]
      empty_preflight.should be >= empty_base
      empty_preflight_relative = empty_preflight - empty_base
      large_preflight_relative = discriminator_preflight - physical_base
      large_preflight_relative.should be >= empty_preflight_relative
      (large_preflight_relative - empty_preflight_relative).should eq(child_count.to_u64)
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
  def retained_workspace_bytes : UInt64
    bytes = previous_def
    extra = @w260_test_workspace_extra_bytes || 0_u64
    if extra > UInt64::MAX - bytes
      raise CrystalClick::CorruptPartError.new("W260 injected workspace overflows")
    end
    bytes + extra
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
      reader = entry[3].as?(CrystalClick::CompactBinaryBulkColumnReader) ||
               raise("W260 logical read-byte injection expects a static BinaryBulk reader")
      reader.w260_test_inject_logical_read_bytes!(bytes)
    end
  end

  def w260_test_inject_reader_workspace_extra!(column : String, bytes : UInt64) : UInt64
    found = false
    estimate = 0_u64
    @readers.each do |entry|
      next unless entry[0] == column
      reader = entry[3].as?(CrystalClick::CompactBinaryBulkColumnReader) ||
               raise("W260 retained-workspace injection expects a static BinaryBulk reader")
      reader.w260_test_inject_retained_workspace_extra!(bytes)
      estimate = reader.retained_workspace_bytes
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
      Dir.mkdir(root)
      # Both selected UInt64 readers are independent Compact contexts. The
      # first selected frame has a valid manifest but a bad compressed-frame
      # checksum, so an eager read would fail with a checksum error before the
      # aggregate workspace refusal. No large payload is allocated.
      w260_write_u64_part(
        part_path,
        CrystalClick::CompactMarkFormat::Mrk4,
        [7_u64, 8_u64, 9_u64, 10_u64] of UInt64,
        rows_per_mark: 2,
        frame_bytes: 16,
      )
      w260_flip_marked_frame_checksum!(part_path, CrystalClick::CompactMarkFormat::Mrk4, "payload", 0)
      table = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["payload", "pk"])
      half_limit = CrystalClick::WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64 // 2_u64
      payload_workspace = table.w260_test_inject_reader_workspace_extra!("payload", half_limit)
      pk_workspace = table.w260_test_inject_reader_workspace_extra!("pk", half_limit)
      payload_workspace.should be < CrystalClick::WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
      pk_workspace.should be < CrystalClick::WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
      (payload_workspace + pk_workspace).should be > CrystalClick::WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError, /selected mark exceeds aggregate materialization limit/) do
        table.scan_typed(batch_rows: 1) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
      # The checksum is corrupt in the first selected mark, but aggregate
      # workspace preflight rejects before attempting to authenticate it.
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

      callbacks = 0
      table.scan_typed(batch_rows: 1) do |batch|
        callbacks += 1
        batch.row_count.not_nil!.should eq(1_u64)
        batch.values_for("baseline").to_a.should eq([7_u64])
        batch.values_for("baseline", UInt64).to_a.should eq([7_u64])
        payload = batch.binary_bulk_values_for("payload")
        payload.size.should eq(1)
        payload[0].elements.should be_empty
      end
      callbacks.should eq(1)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end

describe "Compact borrowed UInt64 typed scans" do
  values = [
    0_u64,
    (1_u64 << 63) - 1_u64,
    1_u64 << 63,
    9_007_199_254_740_993_u64,
    1_u64,
    UInt64::MAX - 1_u64,
    UInt64::MAX,
    42_u64,
  ] of UInt64
  keys = (1_u64..8_u64).to_a
  modes = [CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactMarkFormat::Mrk4]

  modes.each do |mark_format|
    it "preserves exact UInt64 values through #{mark_format} full, window, selected-mark, and parallel scans" do
      root = File.tempname("crystal-click-w260-borrowed-uint64-")
      part_path = File.join(root, "all_1_1_0")
      Dir.mkdir(root)
      begin
        w260_write_u64_part(part_path, mark_format, values, rows_per_mark: 2, frame_bytes: 11)
        compact = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["payload", "pk"])
        compact.columns.should eq(["payload", "pk"])
        compact.column_types.should eq([{"payload", "UInt64"}, {"pk", "UInt64"}])
        compact.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64, 2_u64]])

        full_values = [] of UInt64
        full_keys = [] of UInt64
        full_offsets = [] of UInt64
        full_marks = [] of Int32
        last_payload_addresses = Hash(Int32, UInt64).new
        last_key_addresses = Hash(Int32, UInt64).new
        compact.scan_typed(batch_rows: 1) do |batch|
          batch.column_names.should eq(["payload", "pk"])
          batch.row_count.not_nil!.should eq(1_u64)
          payload = batch.values_for("payload")
          payload.should eq(batch.values_for("payload", UInt64))
          payload_address = payload.to_unsafe.address.to_u64
          key_values = batch.values_for("pk", UInt64)
          key_address = key_values.to_unsafe.address.to_u64
          if previous_address = last_payload_addresses[batch.mark_index]?
            payload_address.should eq(previous_address + sizeof(UInt64).to_u64)
          end
          if previous_address = last_key_addresses[batch.mark_index]?
            key_address.should eq(previous_address + sizeof(UInt64).to_u64)
          end
          last_payload_addresses[batch.mark_index] = payload_address
          last_key_addresses[batch.mark_index] = key_address
          key_values.each_with_index do |value, index|
            full_keys << value
            full_offsets << batch.source_row_offset + index.to_u64
          end
          full_values.concat(payload.to_a)
          full_marks << batch.mark_index if full_marks.last? != batch.mark_index
        end
        full_values.should eq(values)
        full_keys.should eq(keys)
        full_offsets.should eq((0_u64...8_u64).to_a)
        full_marks.should eq([0_i32, 1_i32, 2_i32, 3_i32])
        # The two one-row sub-batches within each mark are adjacent views of
        # the same borrowed UInt64 slices, not separately materialized arrays.

        window_values = [] of UInt64
        window_keys = [] of UInt64
        window_offsets = [] of UInt64
        compact.scan_typed_window(1_u64, 5) do |batch|
          window_values.concat(batch.values_for("payload", UInt64).to_a)
          window_keys.concat(batch.values_for("pk").to_a)
          window_offsets.concat(batch.values_for("payload").size.times.map { |index| batch.source_row_offset + index.to_u64 })
        end
        window_values.should eq(values[1, 5])
        window_keys.should eq(keys[1, 5])
        window_offsets.should eq([1_u64, 2_u64, 3_u64, 4_u64, 5_u64])

        selected_values = [] of UInt64
        selected_keys = [] of UInt64
        selected_marks = [] of Int32
        compact.scan_typed_mark_indices([1_i32, 3_i32], 1) do |batch|
          selected_values.concat(batch.values_for("payload", UInt64).to_a)
          selected_keys.concat(batch.values_for("pk", UInt64).to_a)
          selected_marks << batch.mark_index if selected_marks.last? != batch.mark_index
        end
        selected_values.should eq([values[2], values[3], values[6], values[7]])
        selected_keys.should eq([keys[2], keys[3], keys[6], keys[7]])
        selected_marks.should eq([1_i32, 3_i32])

        typed = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["payload", "pk"])
        parallel_values = [] of UInt64
        parallel_keys = [] of UInt64
        parallel_offsets = [] of UInt64
        parallel_marks = [] of Int32
        {% if flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
          expect_raises(CrystalClick::UnsupportedFormatError, /execution context/) do
            typed.scan_typed_parallel(workers: 4, batch_rows: 1) { |_batch| }
          end
        {% else %}
          caller_thread_id = Thread.current.object_id
          callback_count = 0
          typed.scan_typed_parallel(workers: 4, batch_rows: 1) do |batch|
            Thread.current.object_id.should eq(caller_thread_id)
            if callback_count == 0
              GC.collect
              worker_names = [] of String
              Fiber::ExecutionContext.each do |context|
                if isolated = context.as?(Fiber::ExecutionContext::Isolated)
                  if isolated.running? && isolated.name.starts_with?("crystal-click typed scan worker ")
                    worker_names << isolated.name
                  end
                end
              end
              worker_names.size.should eq(4)
            end
            batch.column_names.should eq(["payload", "pk"])
            parallel_values.concat(batch.values_for("payload", UInt64).to_a)
            parallel_keys.concat(batch.values_for("pk").to_a)
            parallel_offsets.concat(batch.values_for("payload").size.times.map { |index| batch.source_row_offset + index.to_u64 })
            parallel_marks << batch.mark_index if parallel_marks.last? != batch.mark_index
            callback_count += 1
          end
          parallel_values.should eq(values)
          parallel_keys.should eq(keys)
          parallel_offsets.should eq((0_u64...8_u64).to_a)
          parallel_marks.should eq([0_i32, 1_i32, 2_i32, 3_i32])
        {% end %}
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  modes.each do |mark_format|
    it "rejects a wrong-width span and checksum corruption before publishing the affected #{mark_format} mark" do
      root = File.tempname("crystal-click-w260-uint64-integrity-")
      Dir.mkdir(root)
      begin
        width_part = File.join(root, "width", "all_1_1_0")
        FileUtils.mkdir_p(File.dirname(width_part))
        w260_write_u64_part(width_part, mark_format, values, rows_per_mark: 2, frame_bytes: 11)
        w260_shorten_marked_uint64_span!(width_part, mark_format, "payload")
        width_table = CrystalClick::CompactPartTable.open_selected_typed([width_part], ["payload"])
        width_callbacks = 0
        expect_raises(CrystalClick::CorruptPartError, /Compact UInt64 mark span differs from its exact row width/) do
          width_table.scan_typed(batch_rows: 1) { |_batch| width_callbacks += 1 }
        end
        width_callbacks.should eq(0)

        later_part = File.join(root, "later", "all_1_1_0")
        FileUtils.mkdir_p(File.dirname(later_part))
        w260_write_u64_part(later_part, mark_format, values, rows_per_mark: 2, frame_bytes: 16)
        w260_flip_marked_frame_checksum!(later_part, mark_format, "payload", 1)
        later_table = CrystalClick::CompactPartTable.open_selected_typed([later_part], ["payload"])
        published_before_error = [] of UInt64
        later_callbacks = 0
        expect_raises(CrystalClick::CorruptPartError, /checksum/) do
          later_table.scan_typed(batch_rows: 1) do |batch|
            published_before_error.concat(batch.values_for("payload", UInt64).to_a)
            later_callbacks += 1
          end
        end
        published_before_error.should eq(values[0, 2])
        later_callbacks.should eq(2)

        unselected_part = File.join(root, "unselected", "all_1_1_0")
        FileUtils.mkdir_p(File.dirname(unselected_part))
        w260_write_u64_part(unselected_part, mark_format, values, rows_per_mark: 2, frame_bytes: 16)
        w260_flip_marked_frame_checksum!(unselected_part, mark_format, "pk", 0)
        unselected_table = CrystalClick::CompactPartTable.open_selected_typed([unselected_part], ["payload"])
        unselected_values = [] of UInt64
        unselected_table.scan_typed(batch_rows: 1) do |batch|
          unselected_values.concat(batch.values_for("payload").to_a)
        end
        unselected_values.should eq(values)

        # The selected payload is valid and read first, but the selected key
        # hits the corrupted frame. No mixed-column mark may be published.
        mixed_table = CrystalClick::CompactPartTable.open_selected_typed(
          [unselected_part],
          ["payload", "pk"],
        )
        mixed_callbacks = 0
        expect_raises(CrystalClick::CorruptPartError, /checksum/) do
          mixed_table.scan_typed(batch_rows: 1) do |_batch|
            mixed_callbacks += 1
          end
        end
        mixed_callbacks.should eq(0)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end
end
