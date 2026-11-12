require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w282_fixture"
require "./support/compact_part_writer_w281_fixture"
require "../scripts/support/compact_physical_context_w259_fixture"

private def w282_lc_roles_a : Array(String)
  [
    "root.elements.field.0.dictionary",
    "root.elements.field.1.dictionary",
  ] of String
end

private def w282_bulk_body_roles_a : Array(String)
  [
    "root.sizes",
    "root.elements.field.0.dictionary",
    "root.elements.field.0.indexes",
    "root.elements.field.1.dictionary",
    "root.elements.field.1.indexes",
  ] of String
end

private def w282_lc_roles_b : Array(String)
  [
    "root.field.0.elements.field.1.dictionary",
    "root.field.1.elements.dictionary",
    "root.field.2.elements.field.0.dictionary",
    "root.field.2.elements.field.1.dictionary",
  ] of String
end

private def w282_bulk_body_roles_b : Array(String)
  [
    "root.field.0.sizes",
    "root.field.0.elements.field.0.data",
    "root.field.0.elements.field.1.dictionary",
    "root.field.0.elements.field.1.indexes",
    "root.field.1.sizes",
    "root.field.1.elements.dictionary",
    "root.field.1.elements.indexes",
    "root.field.2.sizes",
    "root.field.2.elements.field.0.dictionary",
    "root.field.2.elements.field.0.indexes",
    "root.field.2.elements.field.1.dictionary",
    "root.field.2.elements.field.1.indexes",
  ] of String
end

private def w282_bulk_callbacks(site : CrystalClick::CompactRecursiveJsonBulkSite, roles : Array(String)) : Array(String)
  roles.map { |role| site.callback_name_for(role) }
end

private def w282_bulk_prefix_callbacks(site : CrystalClick::CompactRecursiveJsonBulkSite, roles : Array(String)) : Array(String)
  roles.map do |role|
    callback = site.callback_name_for(role)
    CrystalClick::PhysicalStreamName.append_literal(callback, "_prefix")
  end
end

private def w282_binding_callbacks(
  plan : CrystalClick::CompactJsonCallbackPlan,
  key : String,
  prefixes : Bool,
) : Array(String)
  binding = plan.site_binding(key)
  pairs = prefixes ? binding.prefix_pairs : binding.body_pairs
  pairs.map { |pair| pair[1] }
end

private def w282_le_u64(bytes : Bytes) : UInt64
  unless bytes.size == 8
    raise "W282 LowCardinality state prefix must contain exactly eight bytes"
  end
  value = 0_u64
  bytes.size.times do |index|
    value |= bytes[index].to_u64 << (index * 8)
  end
  value
end

private def w282_write_le_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times do |index|
    bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
  end
end

private def w282_mrk4_coordinate_after_edit(
  coordinate : Int64,
  deleted_at : Int32?,
  inserted_at : Int32?,
) : UInt64
  if deleted_at && coordinate >= deleted_at.to_i64
    (coordinate - 1_i64).to_u64
  elsif inserted_at && coordinate >= inserted_at.to_i64
    (coordinate + 1_i64).to_u64
  else
    coordinate.to_u64
  end
end

private def w282_lc_flags(width_code : UInt64) : UInt64
  CrystalClick::BinaryLowCardinalityStorageStreams::ADDITIONAL_BIT |
    CrystalClick::BinaryLowCardinalityStorageStreams::UPDATE_BIT |
    width_code
end

private def w282_budget_limits(max_nodes : Int64, max_elements : Int64) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: 0,
  )
end

private def w282_reseal_mrk4!(
  part_path : String,
  physical : CrystalClick::CompactPartPhysicalContext,
  raw : Bytes,
  deleted_at : Int32? = nil,
  inserted_at : Int32? = nil,
) : Nil
  slots = physical.physical_roster
  mark_rows = physical.mark_row_counts
  slot_grid = Array(Array(CrystalClick::CompactPartPhysicalShard?)).new(physical.granule_count) do
    Array(CrystalClick::CompactPartPhysicalShard?).new(slots.size, nil)
  end
  columns = [] of String
  slots.each do |slot|
    columns << slot.column_name unless columns.includes?(slot.column_name)
  end
  columns.each do |column_name|
    window = physical.read_window(column_name, 0, physical.granule_count)
    window.granules.each_with_index do |mark, mark_index|
      mark.shards.each do |shard|
        unless shard.slot_index >= 0 && shard.slot_index < slots.size &&
               slots[shard.slot_index].column_name == column_name
          raise "W282 reframe observed a shard outside the MRK4 slot roster"
        end
        raise "W282 reframe duplicated an MRK4 slot" if slot_grid[mark_index][shard.slot_index]
        slot_grid[mark_index][shard.slot_index] = shard
      end
    end
  end

  offsets = Array(UInt64).new(physical.granule_count + 1)
  queries = [] of UInt64
  physical.granule_count.times do |mark_index|
    mark_start = slot_grid[mark_index][0] || raise "W282 reframe missed the first slot for mark #{mark_index}"
    offsets << w282_mrk4_coordinate_after_edit(mark_start.logical_start, deleted_at, inserted_at)
    slots.size.times do |slot_index|
      shard = slot_grid[mark_index][slot_index] || raise "W282 reframe missed an MRK4 slot"
      queries << w282_mrk4_coordinate_after_edit(shard.logical_start, deleted_at, inserted_at)
    end
  end
  offsets << raw.size.to_u64
  slots.size.times { queries << raw.size.to_u64 }
  offsets.first.should eq(0_u64)

  positioned = CrystalClick::CompressedMarkWriter.encode_with_positions(
    raw,
    offsets,
    mark_rows,
    queries,
    frame_bytes: 4096,
  )
  positions = positioned.positions
  positions.size.should eq(queries.size)

  record_width = slots.size * 16 + 8
  marks = Bytes.new((physical.granule_count + 1) * record_width, 0_u8)
  physical.granule_count.times do |mark_index|
    slots.size.times do |slot_index|
      pair = positions[mark_index * slots.size + slot_index]
      w282_write_le_u64(marks, mark_index * record_width + slot_index * 16, pair[0])
      w282_write_le_u64(marks, mark_index * record_width + slot_index * 16 + 8, pair[1])
    end
    w282_write_le_u64(marks, mark_index * record_width + slots.size * 16, mark_rows[mark_index])
  end
  slots.size.times do |slot_index|
    pair = positions[physical.granule_count * slots.size + slot_index]
    w282_write_le_u64(marks, physical.granule_count * record_width + slot_index * 16, pair[0])
    w282_write_le_u64(marks, physical.granule_count * record_width + slot_index * 16 + 8, pair[1])
  end
  w282_write_le_u64(marks, physical.granule_count * record_width + slots.size * 16, 0_u64)
  File.write(File.join(part_path, "data.bin"), positioned.files.data)
  File.write(File.join(part_path, "data.mrk4"), marks)
  CompactPhysicalContextW259Fixture.refresh_checksums(part_path)
  nil
end

describe "W282 recursive LowCardinality Compact adversaries" do
  it "pins mixed JSON/Bulk prefix traversal and exact Bulk body callback order" do
    fixture = CompactPartWriterW282Fixture
    profile = CrystalClick::BinaryBulkProfile.single_stream
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    plan = CrystalClick::CompactJsonCallbackPlan.new(
      fixture.column.json_input(profile),
      limits,
      CrystalClick::BinaryCodecBudget.new(limits, true),
    )
    bulk_a = plan.schema_plan.bulk_site("root/tuple[1]")
    bulk_b = plan.schema_plan.bulk_site("root/tuple[3]")

    expected_names = [] of String
    expected_names.concat(w282_binding_callbacks(plan, "root/tuple[0]", true))
    expected_names.concat(w282_bulk_prefix_callbacks(bulk_a, w282_lc_roles_a))
    expected_names.concat(w282_binding_callbacks(plan, "root/tuple[2]", true))
    expected_names.concat(w282_bulk_prefix_callbacks(bulk_b, w282_lc_roles_b))
    expected_names.concat(w282_binding_callbacks(plan, "root/tuple[0]", false))
    expected_names.concat(w282_bulk_callbacks(bulk_a, w282_bulk_body_roles_a))
    expected_names.concat(w282_binding_callbacks(plan, "root/tuple[2]", false))
    expected_names.concat(w282_bulk_callbacks(bulk_b, w282_bulk_body_roles_b))

    plan.callback_names.should eq(expected_names)
    prefix_events = plan.callback_events.select(&.prefix?)
    prefix_events.map(&.role).should eq(w282_lc_roles_a + w282_lc_roles_b)
    prefix_events.map(&.name).should eq(
      w282_bulk_prefix_callbacks(bulk_a, w282_lc_roles_a) +
      w282_bulk_prefix_callbacks(bulk_b, w282_lc_roles_b),
    )
    prefix_events.each do |prefix|
      prefix.name.ends_with?(".dict_prefix").should be_true
      owner = [bulk_a, bulk_b].find do |site|
        site.prefix_role_index(prefix.role).try do |index|
          site.prefix_role_at(index).callback_name == prefix.name
        end || false
      end || raise "W282 prefix event has no physical Bulk owner"
      dictionary_callback = owner.callback_name_for(prefix.role)
      plan.callback_events.any? do |body|
        !body.prefix? && body.name == dictionary_callback
      end.should be_true
    end
  end

  it "emits a version prefix for every syntactic LC site at every parent mark, including Q=0" do
    fixture = CompactPartWriterW282Fixture
    profile = CrystalClick::BinaryBulkProfile.single_stream
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    plan = CrystalClick::CompactJsonCallbackPlan.new(
      fixture.column.json_input(profile),
      limits,
      CrystalClick::BinaryCodecBudget.new(limits, true),
    )
    encoded = CrystalClick::CompactJsonEncodedColumn.encode(
      plan,
      CrystalClick::BinaryCodecBudget.new(limits, true),
    )
    bulk_a = plan.schema_plan.bulk_site("root/tuple[1]")
    bulk_b = plan.schema_plan.bulk_site("root/tuple[3]")
    prefix_events = plan.callback_events.select(&.prefix?)
    prefix_events.size.should eq(6)

    prefix_events.each do |prefix|
      CompactPartWriterW282Fixture::MARK_COUNT.times do |mark|
        w282_le_u64(encoded.callback_bytes(prefix, mark)).should eq(1_u64)
      end
      owner = [bulk_a, bulk_b].find do |site|
        site.prefix_role_index(prefix.role).try do |index|
          site.prefix_role_at(index).callback_name == prefix.name
        end || false
      end || raise "W282 prefix event has no physical Bulk owner"
      dictionary_callback = owner.callback_name_for(prefix.role)
      dictionary_body = plan.callback_events.find do |body|
        !body.prefix? && body.name == dictionary_callback
      end || raise "W282 dictionary body callback is missing"
      CompactPartWriterW282Fixture::MARK_COUNT.times do |mark|
        encoded.callback_bytes(dictionary_body, mark).should be_empty
      end
    end

    empty_parent_marks = [0, 2]
    index_callbacks = w282_bulk_callbacks(
      bulk_a,
      w282_bulk_body_roles_a.select(&.ends_with?(".indexes")),
    ) + w282_bulk_callbacks(
      bulk_b,
      w282_bulk_body_roles_b.select(&.ends_with?(".indexes")),
    )
    index_events = plan.callback_events.select do |event|
      !event.prefix? && index_callbacks.includes?(event.name)
    end
    index_events.size.should eq(6)
    index_events.map(&.name).sort.should eq(index_callbacks.sort)
    empty_array_index_callback = bulk_b.callback_name_for("root.field.1.elements.indexes")
    index_events.each do |event|
      empty_parent_marks.each do |mark|
        encoded.callback_bytes(event, mark).should be_empty
      end
      if event.name == empty_array_index_callback
        CompactPartWriterW282Fixture::MARK_COUNT.times do |mark|
          encoded.callback_bytes(event, mark).should be_empty
        end
      else
        [1, 3].each do |mark|
          encoded.callback_bytes(event, mark).should_not be_empty
        end
      end
    end
  end

  it "rejects a resealed wrong-version LC prefix through the authenticated public reader path" do
    fixture = CompactPartWriterW282Fixture
    parent = File.tempname("crystal-click-w282-bad-lc-prefix-")
    part_path = File.join(parent, "all_1_1_0")
    Dir.mkdir(parent)
    begin
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW282Fixture::KEY_NAME,
        fixture.keys,
        [fixture.column] of CrystalClick::CompactPartColumn,
        rows_per_mark: CompactPartWriterW282Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW282Fixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
      ).should eq(part_path)

      limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
      plan = CrystalClick::CompactJsonCallbackPlan.new(
        fixture.column.json_input(CrystalClick::BinaryBulkProfile.single_stream),
        limits,
        CrystalClick::BinaryCodecBudget.new(limits, true),
      )
      site = plan.schema_plan.bulk_site("root/tuple[1]")
      role = w282_lc_roles_a.first
      callback = site.prefix_callback_name_for(role)
      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      granule = physical.read_window(CompactPartWriterW282Fixture::COLUMN_NAME, 0, 1).granules.first? ||
                raise "W282 wrong-version prefix fixture has no first parent mark"
      shard = granule.shards.find { |candidate| candidate.stream_name == callback } ||
              raise "W282 wrong-version dictionary prefix callback is absent"
      w282_le_u64(shard.bytes).should eq(1_u64)

      raw = CrystalClick::CompressedMarkReader.read_all(
        File.join(part_path, "data.bin"),
        File.size(File.join(part_path, "data.bin")).to_i64,
      )
      w282_write_le_u64(raw, shard.logical_start.to_i, 2_u64)
      w282_reseal_mrk4!(part_path, physical, raw)

      resealed = CrystalClick::CompactPartPhysicalContext.open(part_path)
      resealed.mode.mrk4?.should be_true
      resealed.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      mutated = resealed.read_window(CompactPartWriterW282Fixture::COLUMN_NAME, 0, 1).granules.first? ||
                raise "W282 resealed wrong-version prefix lost its first parent mark"
      mutated_shard = mutated.shards.find { |candidate| candidate.stream_name == callback } ||
                      raise "W282 resealed wrong-version prefix callback is absent"
      w282_le_u64(mutated_shard.bytes).should eq(2_u64)

      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW282Fixture::COLUMN_NAME,
        fixture.schema,
      )
      expect_raises(CrystalClick::UnsupportedFormatError, /state-prefix version/) do
        reader.read_marks(0, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a physically resealed seven-byte MRK4 LC prefix before body publication" do
    fixture = CompactPartWriterW282Fixture
    parent = File.tempname("crystal-click-w282-short-lc-prefix-")
    part_path = File.join(parent, "all_1_1_0")
    Dir.mkdir(parent)
    begin
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW282Fixture::KEY_NAME,
        fixture.keys,
        [fixture.column] of CrystalClick::CompactPartColumn,
        rows_per_mark: CompactPartWriterW282Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW282Fixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
      ).should eq(part_path)

      limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
      plan = CrystalClick::CompactJsonCallbackPlan.new(
        fixture.column.json_input(CrystalClick::BinaryBulkProfile.single_stream),
        limits,
        CrystalClick::BinaryCodecBudget.new(limits, true),
      )
      site = plan.schema_plan.bulk_site("root/tuple[1]")
      callback = site.prefix_callback_name_for(w282_lc_roles_a.first)
      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      granule = physical.read_window(CompactPartWriterW282Fixture::COLUMN_NAME, 0, 1).granules.first? ||
                raise "W282 short-prefix fixture has no first parent mark"
      shard = granule.shards.find { |candidate| candidate.stream_name == callback } ||
              raise "W282 short dictionary prefix callback is absent"
      shard.bytes.size.should eq(8)

      raw = CrystalClick::CompressedMarkReader.read_all(
        File.join(part_path, "data.bin"),
        File.size(File.join(part_path, "data.bin")).to_i64,
      )
      deleted_at = shard.logical_end.to_i - 1
      shortened = Bytes.new(raw.size - 1) do |index|
        raw[index >= deleted_at ? index + 1 : index]
      end
      w282_reseal_mrk4!(part_path, physical, shortened, deleted_at)

      resealed = CrystalClick::CompactPartPhysicalContext.open(part_path)
      resealed.mode.mrk4?.should be_true
      resealed.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      mutated = resealed.read_window(CompactPartWriterW282Fixture::COLUMN_NAME, 0, 1).granules.first? ||
                raise "W282 resealed short prefix lost its first parent mark"
      mutated_shard = mutated.shards.find { |candidate| candidate.stream_name == callback } ||
                      raise "W282 resealed short prefix callback is absent"
      mutated_shard.bytes.size.should eq(7)

      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW282Fixture::COLUMN_NAME,
        fixture.schema,
      )
      expect_raises(CrystalClick::CorruptPartError, /prefix is truncated/) do
        reader.read_marks(0, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a valid MRK4 LC prefix with one trailing byte before body publication" do
    fixture = CompactPartWriterW282Fixture
    parent = File.tempname("crystal-click-w282-trailing-lc-prefix-")
    part_path = File.join(parent, "all_1_1_0")
    Dir.mkdir(parent)
    begin
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW282Fixture::KEY_NAME,
        fixture.keys,
        [fixture.column] of CrystalClick::CompactPartColumn,
        rows_per_mark: CompactPartWriterW282Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW282Fixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
      ).should eq(part_path)

      limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
      plan = CrystalClick::CompactJsonCallbackPlan.new(
        fixture.column.json_input(CrystalClick::BinaryBulkProfile.single_stream),
        limits,
        CrystalClick::BinaryCodecBudget.new(limits, true),
      )
      site = plan.schema_plan.bulk_site("root/tuple[1]")
      callback = site.prefix_callback_name_for(w282_lc_roles_a.first)
      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      granule = physical.read_window(CompactPartWriterW282Fixture::COLUMN_NAME, 0, 1).granules.first? ||
                raise "W282 trailing-prefix fixture has no first parent mark"
      shard = granule.shards.find { |candidate| candidate.stream_name == callback } ||
              raise "W282 trailing dictionary prefix callback is absent"
      shard.bytes.size.should eq(8)
      w282_le_u64(shard.bytes).should eq(1_u64)

      raw = CrystalClick::CompressedMarkReader.read_all(
        File.join(part_path, "data.bin"),
        File.size(File.join(part_path, "data.bin")).to_i64,
      )
      inserted_at = shard.logical_end.to_i
      extended = Bytes.new(raw.size + 1) do |index|
        if index < inserted_at
          raw[index]
        elsif index == inserted_at
          0x7f_u8
        else
          raw[index - 1]
        end
      end
      w282_reseal_mrk4!(part_path, physical, extended, inserted_at: inserted_at)

      resealed = CrystalClick::CompactPartPhysicalContext.open(part_path)
      resealed.mode.mrk4?.should be_true
      mutated = resealed.read_window(CompactPartWriterW282Fixture::COLUMN_NAME, 0, 1).granules.first? ||
                raise "W282 resealed trailing prefix lost its first parent mark"
      mutated_shard = mutated.shards.find { |candidate| candidate.stream_name == callback } ||
                      raise "W282 resealed trailing prefix callback is absent"
      mutated_shard.bytes.size.should eq(9)
      w282_le_u64(mutated_shard.bytes[0, 8]).should eq(1_u64)

      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW282Fixture::COLUMN_NAME,
        fixture.schema,
      )
      expect_raises(CrystalClick::CorruptPartError, /did not consume its exact named callback/) do
        reader.read_marks(0, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "borrows a charged pending MRK4 callback view read-only without opening or copying it" do
    bytes = Bytes[1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8]
    shard = CrystalClick::CompactPartPhysicalShard.new(
      0,
      "lc.dict_prefix",
      0_i64,
      bytes.size.to_i64,
      bytes,
    )
    cursor = CrystalClick::CompactBinaryBulkGranuleCursor.new(
      CrystalClick::CompactMarkFormat::Mrk4,
      [shard],
      ["lc.dict_prefix"] of String,
    )

    expect_raises(ArgumentError, /prior complete-granule charge/) do
      cursor.pending_event_slice("lc.dict_prefix")
    end
    cursor.charge_complete_wire_input!(
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
    )
    expect_raises(CrystalClick::CorruptPartError, /pending callback differs/) do
      cursor.pending_event_slice("lc.other_prefix")
    end

    first = cursor.pending_event_slice("lc.dict_prefix")
    second = cursor.pending_event_slice("lc.dict_prefix")
    first.to_unsafe.should eq(second.to_unsafe)
    first.should eq(bytes)
    first.read_only?.should be_true
    second.read_only?.should be_true

    cursor.begin_event("lc.dict_prefix")
    expect_raises(CrystalClick::CorruptPartError, /cannot overlap an active callback/) do
      cursor.pending_event_slice("lc.dict_prefix")
    end
    cursor.read_exact(8).should eq(bytes)
    cursor.finish_event
    cursor.finish_granule
  end

  it "rejects writes through borrowed LC prefix parser input without advancing MRK3 or MRK4" do
    fixture = CompactPartWriterW282Fixture
    parent = File.tempname("crystal-click-w282-prefix-rollback-")
    part_path = File.join(parent, "all_1_1_0")
    Dir.mkdir(parent)
    begin
      limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
      plan = CrystalClick::CompactJsonCallbackPlan.new(
        fixture.column.json_input(CrystalClick::BinaryBulkProfile.single_stream),
        limits,
        CrystalClick::BinaryCodecBudget.new(limits, true),
      )
      site = plan.schema_plan.bulk_site("root/tuple[1]")
      callback = site.prefix_callback_name_for(w282_lc_roles_a.first)
      encoded = CrystalClick::CompactJsonEncodedColumn.encode(
        plan,
        CrystalClick::BinaryCodecBudget.new(limits, true),
      )
      preceding_json_prefixes = w282_binding_callbacks(plan, "root/tuple[0]", true)
      [CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactMarkFormat::Mrk4].each do |mark_format|
        FileUtils.rm_rf(part_path)
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW282Fixture::KEY_NAME,
          fixture.keys,
          [fixture.column] of CrystalClick::CompactPartColumn,
          rows_per_mark: CompactPartWriterW282Fixture::ROWS_PER_MARK,
          frame_bytes: CompactPartWriterW282Fixture::FRAME_BYTES,
          mark_format: mark_format,
          profile: CrystalClick::BinaryBulkProfile.single_stream,
        ).should eq(part_path)

        physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
        granule = physical.read_window(CompactPartWriterW282Fixture::COLUMN_NAME, 0, 1).granules.first? ||
                  raise "W282 prefix-rollback fixture has no first parent mark"
        ledger = CrystalClick::CompactRecursiveJsonParentMarkLedger.new(
          physical,
          CompactPartWriterW282Fixture::COLUMN_NAME,
          granule,
          CrystalClick::BinaryCodecBudget.new(limits),
        )
        json_source = ledger.site_source("root/tuple[0]")
        preceding_json_prefixes.each do |json_callback|
          event = plan.callback_events.find do |candidate|
            candidate.name == json_callback
          end || raise "W282 prefix-rollback fixture is missing a preceding JSON prefix event"
          byte_count = encoded.callback_bytes(event, 0).size
          ledger.capture_site_exact(json_source, json_callback, byte_count)
        end

        expect_raises(Exception, /read-only Slice/) do
          ledger.with_bulk_prefix_grammar_extent(callback) do |borrowed|
            borrowed.read_only?.should be_true
            borrowed[0] = 2_u8
            {0_u64, borrowed.size}
          end
        end
        parsed, capture = ledger.with_bulk_prefix_grammar_extent(callback) do |borrowed|
          borrowed.read_only?.should be_true
          prefix = borrowed[0, 8]
          prefix.read_only?.should be_true
          {w282_le_u64(prefix), 8}
        end
        parsed.should eq(1_u64)
        capture.bytes.size.should eq(8)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects writes through transactional MRK3 grammar input and parses it on retry" do
    tape = Bytes.new(28)
    w282_write_le_u64(tape, 0, w282_lc_flags(0_u64))
    w282_write_le_u64(tape, 8, 1_u64)
    tape[16] = 1_u8
    tape[17] = 'x'.ord.to_u8
    w282_write_le_u64(tape, 18, 2_u64)
    tape[26] = 0_u8
    tape[27] = 0_u8
    shard = CrystalClick::CompactPartPhysicalShard.new(0, nil, 0_i64, tape.size.to_i64, tape)
    cursor = CrystalClick::CompactBinaryBulkGranuleCursor.new(
      CrystalClick::CompactMarkFormat::Mrk3,
      [shard],
      nil,
    )

    expect_raises(Exception, /read-only Slice/) do
      cursor.with_transactional_borrowed_prefix do |borrowed|
        borrowed.read_only?.should be_true
        borrowed[0] = 2_u8
        {0_i32, 0_i32}
      end
    end
    cursor.position.should eq(0)

    consumed, captured = cursor.with_transactional_borrowed_prefix do |borrowed|
      parsed = CrystalClick::BinaryLowCardinalityAdditionalIndexGrammar.parse_extent(
        CrystalClick::BinaryDataType.primitive("String"),
        2_u64,
        borrowed,
        CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      )
      {parsed, parsed}
    end
    consumed.should eq(28)
    captured.size.should eq(28)
    cursor.position.should eq(28)
  end

  it "does not commit a truncated MRK3 index record over a following valid UInt64 lane" do
    # Width-code 3 makes two UInt64 IDs mandatory. Only one follows this
    # otherwise complete Q=2 record; that eight-byte suffix is a valid sibling
    # UInt64 lane but cannot complete the index grammar.
    tape = Bytes.new(40)
    w282_write_le_u64(tape, 0, w282_lc_flags(3_u64))
    w282_write_le_u64(tape, 8, 1_u64)
    w282_write_le_u64(tape, 16, 42_u64)
    w282_write_le_u64(tape, 24, 2_u64)
    w282_write_le_u64(tape, 32, 99_u64)
    shard = CrystalClick::CompactPartPhysicalShard.new(0, nil, 0_i64, tape.size.to_i64, tape)
    cursor = CrystalClick::CompactBinaryBulkGranuleCursor.new(
      CrystalClick::CompactMarkFormat::Mrk3,
      [shard],
      nil,
    )
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS

    expect_raises(CrystalClick::CorruptPartError) do
      cursor.with_transactional_borrowed_prefix do |bytes|
        consumed = CrystalClick::BinaryLowCardinalityAdditionalIndexGrammar.parse_extent(
          uint64,
          2_u64,
          bytes,
          limits,
        )
        {consumed, consumed}
      end
    end
    cursor.position.should eq(0)
    cursor.read_exact(8).should eq(tape[0, 8])
  end

  it "rejects MRK4 trailing bytes before committing a valid named index shard" do
    # A width-1, Q=2 LC(String) index record is valid through byte 28; the
    # final byte belongs to no part of that exact named callback.
    shard_bytes = Bytes.new(29)
    w282_write_le_u64(shard_bytes, 0, w282_lc_flags(0_u64))
    w282_write_le_u64(shard_bytes, 8, 1_u64)
    shard_bytes[16] = 1_u8
    shard_bytes[17] = 'x'.ord.to_u8
    w282_write_le_u64(shard_bytes, 18, 2_u64)
    shard_bytes[26] = 0_u8
    shard_bytes[27] = 0_u8
    shard_bytes[28] = 0x7f_u8
    shard = CrystalClick::CompactPartPhysicalShard.new(
      0,
      "lc.indexes",
      0_i64,
      shard_bytes.size.to_i64,
      shard_bytes,
    )
    cursor = CrystalClick::CompactBinaryBulkGranuleCursor.new(
      CrystalClick::CompactMarkFormat::Mrk4,
      [shard],
      ["lc.indexes"] of String,
    )
    cursor.begin_event("lc.indexes")
    string = CrystalClick::BinaryDataType.primitive("String")
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS

    expect_raises(CrystalClick::CorruptPartError) do
      cursor.with_transactional_borrowed_prefix do |bytes|
        consumed = CrystalClick::BinaryLowCardinalityAdditionalIndexGrammar.parse_extent(
          string,
          2_u64,
          bytes,
          limits,
        )
        {consumed, consumed}
      end
    end
    cursor.position.should eq(0)
  end

  it "rejects reserved, GLOBAL, and missing-UPDATE index flags transactionally" do
    string = CrystalClick::BinaryDataType.primitive("String")
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    invalid_flags = [
      w282_lc_flags(0_u64) | CrystalClick::BinaryLowCardinalityStorageStreams::GLOBAL_BIT,
      CrystalClick::BinaryLowCardinalityStorageStreams::ADDITIONAL_BIT,
      w282_lc_flags(0_u64) | (1_u64 << 16),
    ] of UInt64

    invalid_flags.each do |flags|
      tape = Bytes.new(8)
      w282_write_le_u64(tape, 0, flags)
      shard = CrystalClick::CompactPartPhysicalShard.new(0, nil, 0_i64, 8_i64, tape)
      cursor = CrystalClick::CompactBinaryBulkGranuleCursor.new(
        CrystalClick::CompactMarkFormat::Mrk3,
        [shard],
        nil,
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        cursor.with_transactional_borrowed_prefix do |bytes|
          consumed = CrystalClick::BinaryLowCardinalityAdditionalIndexGrammar.parse_extent(
            string,
            1_u64,
            bytes,
            limits,
          )
          {consumed, consumed}
        end
      end
      cursor.position.should eq(0)
    end
  end

  it "preflights recursive mark-open LC ownership atomically and keeps LC-free exact limits" do
    fixture = CompactPartWriterW282Fixture
    defaults = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    callback_plan = CrystalClick::CompactJsonCallbackPlan.new(
      fixture.column.json_input(CrystalClick::BinaryBulkProfile.single_stream),
      defaults,
      CrystalClick::BinaryCodecBudget.new(defaults, true),
    )
    lc_site = callback_plan.schema_plan.bulk_site("root/tuple[1]")
    lc_site.prefix_role_count.should be > 0
    required_nodes = 2_i64 + (lc_site.prefix_role_count > 0 ? 1_i64 : 0_i64)
    required_elements = lc_site.role_count.to_i64 + lc_site.prefix_role_count.to_i64

    exact_budget = CrystalClick::BinaryCodecBudget.new(
      w282_budget_limits(required_nodes, required_elements),
    )
    CrystalClick::CompactRecursiveJsonBulkMark.open(lc_site, exact_budget)
    exact_budget.node_count.should eq(required_nodes)
    exact_budget.element_count.should eq(required_elements)

    node_below = CrystalClick::BinaryCodecBudget.new(
      w282_budget_limits(required_nodes - 1_i64, required_elements),
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactRecursiveJsonBulkMark.open(lc_site, node_below)
    end
    node_below.node_count.should eq(0_i64)
    node_below.element_count.should eq(0_i64)
    node_below.wire_byte_count.should eq(0_i64)

    element_below = CrystalClick::BinaryCodecBudget.new(
      w282_budget_limits(required_nodes, required_elements - 1_i64),
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactRecursiveJsonBulkMark.open(lc_site, element_below)
    end
    element_below.node_count.should eq(0_i64)
    element_below.element_count.should eq(0_i64)
    element_below.wire_byte_count.should eq(0_i64)

    lc_free_type = CrystalClick::BinaryDataType.tuple(
      [
        CrystalClick::BinaryDataType.primitive("UInt16"),
        CrystalClick::BinaryDataType.primitive("String"),
      ] of CrystalClick::BinaryDataType,
    )
    profile = CrystalClick::BinaryBulkProfile.single_stream
    planning_budget = CrystalClick::BinaryCodecBudget.new(defaults)
    physical_plan = CrystalClick::BinaryBulkPhysicalPlan.new(
      lc_free_type,
      "legacy",
      profile,
      defaults,
    )
    lc_free_site = CrystalClick::CompactRecursiveJsonBulkSite.new(
      "root/tuple[1]",
      "root",
      1,
      0_u64,
      lc_free_type,
      physical_plan,
      defaults,
      planning_budget,
    )
    lc_free_site.prefix_role_count.should eq(0)
    lc_free_elements = lc_free_site.role_count.to_i64
    lc_free_exact = CrystalClick::BinaryCodecBudget.new(w282_budget_limits(2_i64, lc_free_elements))
    CrystalClick::CompactRecursiveJsonBulkMark.open(lc_free_site, lc_free_exact)
    lc_free_exact.node_count.should eq(2_i64)
    lc_free_exact.element_count.should eq(lc_free_elements)
  end

  it "preflights the extra eight LC prefix bytes while retaining LC-free exact limits" do
    roles = 2
    key_bytes = 10_u64
    base_elements = 8_u64 * roles.to_u64 + 2_u64 * key_bytes

    lc_exact = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(
        max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
        max_nodes: 13,
        max_elements: (base_elements + 8_u64).to_i,
        max_bytes: 0,
      ),
    )
    CrystalClick::CompactRecursiveJsonBulkMark.preflight_packaging!(roles, 8_u64, key_bytes, lc_exact)
    lc_exact.element_count.should eq((base_elements + 8_u64).to_i64)

    lc_one_below = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(
        max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
        max_nodes: 13,
        max_elements: (base_elements + 7_u64).to_i,
        max_bytes: 0,
      ),
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactRecursiveJsonBulkMark.preflight_packaging!(roles, 8_u64, key_bytes, lc_one_below)
    end
    lc_one_below.node_count.should eq(0_i64)
    lc_one_below.element_count.should eq(0_i64)

    lc_free_exact = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(
        max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
        max_nodes: 13,
        max_elements: base_elements.to_i,
        max_bytes: 0,
      ),
    )
    CrystalClick::CompactRecursiveJsonBulkMark.preflight_packaging!(roles, 0_u64, key_bytes, lc_free_exact)
    lc_free_exact.element_count.should eq(base_elements.to_i64)
  end
end
