require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w281_fixture"
require "../scripts/support/compact_physical_context_w259_fixture"

private def w281a_static_bulk_declarations : Array(Tuple(String, String))
  [
    {"BFloat16", "BFloat16"},
    {"Nothing", "Nothing"},
    {"IntervalDay", "IntervalDay"},
    {"Point", "Point"},
    {"MultiPoint", "MultiPoint"},
    {"Nullable(Point)", "Nullable(Point)"},
    {"Nested(label String, maybe_code Nullable(UInt8))", "Nested(label String, maybe_code Nullable(UInt8))"},
    {"SimpleAggregateFunction(sum, UInt64)", "SimpleAggregateFunction(sum, UInt64)"},
    {"Map(UInt8, String)", "Map(UInt8, String)"},
  ] of Tuple(String, String)
end

private def w281a_json_guard_declarations : Array(String)
  [
    "Map(UInt8, String)",
    "BFloat16",
    "Nothing",
    "IntervalDay",
    "Point",
    "SimpleAggregateFunction(sum, UInt64)",
  ] of String
end

private def w281a_json_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
    typed_paths: {"id" => CrystalClick::BinaryDataType.primitive("UInt64")} of String => CrystalClick::BinaryDataType,
  )
end

private def w281a_object_plan(json_type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
  object = CrystalClick::ObjectStructure.new(
    [] of String,
    version: 4_u64,
    shared_data_version: 0_u64,
    bucket_count: 1_u64,
    statistics: CrystalClick::StructureStatistics.new(
      [] of UInt64,
      [] of CrystalClick::StructureStatistic,
    ),
  )
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    object,
    Hash(String, CrystalClick::DynamicStructure).new,
  )
  CrystalClick::ObjectDocumentPlan.new(structures, json_type.json_type.not_nil!.typed_paths)
end

private def w281a_small_string_rows : Array(CrystalClick::StorageColumnValue)
  [1_u64, 2_u64].map_with_index do |id, index|
    text = index == 0 ? "a" : "b"
    CrystalClick::StorageColumnValue.tuple(
      [
        CrystalClick::StorageColumnValue.object_document(
          CrystalClick::ObjectDocument.new(
            {"id" => CrystalClick::BinaryValue.uint64(id)} of String => CrystalClick::BinaryValue,
          ),
        ),
        CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.string(text)),
      ] of CrystalClick::StorageColumnValue,
    )
  end.to_a
end

private def w281a_small_string_schema : CrystalClick::StorageColumnSchema
  CrystalClick::StorageColumnSchema.parse("Tuple(JSON(id UInt64), String)")
end

private def w281a_small_string_column : CrystalClick::CompactPartColumn
  json_type = w281a_json_type
  CrystalClick::CompactPartColumn.json(
    "payload",
    w281a_small_string_schema,
    [w281a_small_string_rows] of Array(CrystalClick::StorageColumnValue),
    CrystalClick::CompactJsonWriteContext.new(
      {"root/tuple[0]" => w281a_object_plan(json_type)} of String => CrystalClick::ObjectDocumentPlan,
    ),
  )
end

private def w281a_write_small_string_part(
  part_path : String,
  profile : CrystalClick::BinaryBulkProfile,
) : String
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    "pk",
    Slice[1_u64, 2_u64],
    [w281a_small_string_column] of CrystalClick::CompactPartColumn,
    rows_per_mark: 2,
    frame_bytes: 4096,
    mark_format: CrystalClick::CompactMarkFormat::Mrk4,
    profile: profile,
  )
end

private def w281a_with_prefix_free_bulk_mark(
  mark_format : CrystalClick::CompactMarkFormat,
  &block : CrystalClick::CompactPartPhysicalContext, CrystalClick::CompactPartPhysicalGranule, CrystalClick::BinaryBulkPhysicalPlan -> Nil
) : Nil
  uint16 = CrystalClick::BinaryDataType.primitive("UInt16")
  string = CrystalClick::BinaryDataType.primitive("String")
  type = CrystalClick::BinaryDataType.tuple([uint16, string] of CrystalClick::BinaryDataType)
  rows = [
    CrystalClick::BinaryValue.tuple(
      type,
      [
        CrystalClick::BinaryValue.fixed(uint16, Bytes[0x34_u8, 0x12_u8]),
        CrystalClick::BinaryValue.string("abc"),
      ] of CrystalClick::BinaryValue,
    ),
    CrystalClick::BinaryValue.tuple(
      type,
      [
        CrystalClick::BinaryValue.fixed(uint16, Bytes[0x78_u8, 0x56_u8]),
        CrystalClick::BinaryValue.string("de"),
      ] of CrystalClick::BinaryValue,
    ),
  ] of CrystalClick::BinaryValue
  column = CrystalClick::CompactPartColumn.binary_bulk(
    "payload",
    type,
    [rows] of Array(CrystalClick::BinaryValue),
  )
  profile = CrystalClick::BinaryBulkProfile.single_stream
  plan = CrystalClick::BinaryBulkPhysicalPlan.new(
    type,
    "payload",
    profile,
    CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
  )
  parent = File.tempname("crystal-click-w281-ledger-transaction-")
  part_path = File.join(parent, "all_1_1_0")
  Dir.mkdir(parent)
  begin
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part_path,
      "pk",
      Slice[1_u64, 2_u64],
      [column] of CrystalClick::CompactPartColumn,
      rows_per_mark: 2,
      frame_bytes: 4096,
      mark_format: mark_format,
      profile: profile,
    )
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    granule = physical.read_window("payload", 0, 1).granules.first? ||
              raise(CrystalClick::CorruptPartError.new("W281 ledger fixture has no parent mark"))
    yield physical, granule, plan
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w281a_write_local_fixture_part(part_path : String) : Nil
  fixture = CompactPartWriterW281Fixture
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW281Fixture::KEY_NAME,
    fixture.keys,
    [fixture.column] of CrystalClick::CompactPartColumn,
    rows_per_mark: CompactPartWriterW281Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW281Fixture::FRAME_BYTES,
    mark_format: CrystalClick::CompactMarkFormat::Mrk4,
    profile: CrystalClick::BinaryBulkProfile.single_stream,
  )
  nil
end

private def w281a_literal_strings(
  marks : Array(Array(CrystalClick::StorageColumnValue)),
) : Array(String)
  marks.flatten.map do |value|
    id = value.child_at(0).object_document.value_for("id").as_uint64
    text = value.child_at(1).bulk_value.as_string
    "#{id}:#{text}"
  end
end

private def w281a_le64(values : Array(UInt64)) : Bytes
  Bytes.new(values.size * 8) do |index|
    value = values[index // 8]
    ((value >> ((index % 8) * 8)) & 0xff_u64).to_u8
  end
end

private def w281a_write_u64_le(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times do |index|
    bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
  end
end

private def w281a_reseal_mrk4!(
  part_path : String,
  physical : CrystalClick::CompactPartPhysicalContext,
  raw : Bytes,
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
          raise "W281 reframe observed a shard outside the MRK4 slot roster"
        end
        raise "W281 reframe duplicated an MRK4 slot" if slot_grid[mark_index][shard.slot_index]
        slot_grid[mark_index][shard.slot_index] = shard
      end
    end
  end

  offsets = Array(UInt64).new(physical.granule_count + 1)
  queries = [] of UInt64
  physical.granule_count.times do |mark_index|
    mark_start = slot_grid[mark_index][0] || raise "W281 reframe missed the first slot for mark #{mark_index}"
    offsets << mark_start.logical_start.to_u64
    slots.size.times do |slot_index|
      shard = slot_grid[mark_index][slot_index] || raise "W281 reframe missed an MRK4 slot"
      queries << shard.logical_start.to_u64
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
      w281a_write_u64_le(marks, mark_index * record_width + slot_index * 16, pair[0])
      w281a_write_u64_le(marks, mark_index * record_width + slot_index * 16 + 8, pair[1])
    end
    w281a_write_u64_le(
      marks,
      mark_index * record_width + slots.size * 16,
      mark_rows[mark_index],
    )
  end
  slots.size.times do |slot_index|
    pair = positions[physical.granule_count * slots.size + slot_index]
    w281a_write_u64_le(marks, physical.granule_count * record_width + slot_index * 16, pair[0])
    w281a_write_u64_le(marks, physical.granule_count * record_width + slot_index * 16 + 8, pair[1])
  end
  w281a_write_u64_le(marks, physical.granule_count * record_width + slots.size * 16, 0_u64)

  File.write(File.join(part_path, "data.bin"), positioned.files.data)
  File.write(File.join(part_path, "data.mrk4"), marks)
  CompactPhysicalContextW259Fixture.refresh_checksums(part_path)
  nil
end

private def w281a_assert_small_string_corruption(
  profile : CrystalClick::BinaryBulkProfile,
  string1 : Bool,
  mutation : Symbol,
) : Nil
  parent = File.tempname(string1 ? "crystal-click-w281-s1-" : "crystal-click-w281-s0-")
  part_path = File.join(parent, "all_1_1_0")
  Dir.mkdir(parent)
  begin
    w281a_write_small_string_part(part_path, profile).should eq(part_path)
    schema = w281a_small_string_schema
    reader = CrystalClick::CompactRecursiveJsonColumnReader.open(part_path, "payload", schema)
    reader.ordinary_profile.should eq(profile)
    w281a_literal_strings(reader.read_marks(0, 1)).should eq(["1:a", "2:b"])

    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    physical.mode.should eq(CrystalClick::CompactMarkFormat::Mrk4)
    plan = CrystalClick::CompactJsonCallbackPlan.new(
      w281a_small_string_column.json_input(profile),
      CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
    )
    bulk = plan.schema_plan.bulk_site("root/tuple[1]")
    role = string1 ? "root.string_sizes" : "root.data"
    callback = bulk.callback_name_for(role)
    granule = physical.read_window("payload", 0, 1).granules.first? ||
              raise(CrystalClick::CorruptPartError.new("W281 String fixture has no parent mark"))
    shard = granule.shards.find { |candidate| candidate.stream_name == callback } ||
            raise(CrystalClick::CorruptPartError.new("W281 String callback is absent from MRK4"))

    raw = CrystalClick::CompressedMarkReader.read_all(
      File.join(part_path, "data.bin"),
      File.size(File.join(part_path, "data.bin")).to_i64,
    )
    start = shard.logical_start.to_i
    if string1
      shard.bytes.should eq(w281a_le64([1_u64, 1_u64]))
      case mutation
      when :oversum
        w281a_write_u64_le(raw, start + 8, 2_u64)
      when :undersum
        w281a_write_u64_le(raw, start, 0_u64)
        w281a_write_u64_le(raw, start + 8, 0_u64)
      else
        raise ArgumentError.new("unknown W281 String1 corruption")
      end
    else
      shard.bytes.should eq(Bytes[1_u8, 'a'.ord.to_u8, 1_u8, 'b'.ord.to_u8])
      case mutation
      when :noncanonical
        # Same-length overlong zero: callback boundaries stay fixed while the
        # String0 parser must reject a noncanonical VarUInt.
        raw[start] = 0x80_u8
        raw[start + 1] = 0x00_u8
      when :trailing_data
        # The second canonical zero-length string leaves its original payload
        # byte behind, so the callback grammar consumes one byte less than its
        # exact MRK4 extent.
        raw[start + 2] = 0x00_u8
      else
        raise ArgumentError.new("unknown W281 String0 corruption")
      end
    end
    w281a_reseal_mrk4!(part_path, physical, raw)

    resealed = CrystalClick::CompactPartPhysicalContext.open(part_path)
    resealed.mode.should eq(CrystalClick::CompactMarkFormat::Mrk4)
    resealed.mark_row_counts.should eq([2_u64])
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactRecursiveJsonColumnReader.open(part_path, "payload", schema).read_marks(0, 1)
    end
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w281a_string_array(
  array_type : CrystalClick::BinaryDataType,
  values : Array(String),
) : CrystalClick::BinaryValue
  items = values.map { |value| CrystalClick::BinaryValue.string(value) }.to_a
  CrystalClick::BinaryValue.array(array_type, items)
end

private def w281a_string_pair_row(
  tuple_type : CrystalClick::BinaryDataType,
  first : Array(String),
  second : Array(String),
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.tuple(
    tuple_type,
    [
      w281a_string_array(tuple_type.child_at(0), first),
      w281a_string_array(tuple_type.child_at(1), second),
    ] of CrystalClick::BinaryValue,
  )
end

private def w281a_capture_bulk_mark(
  physical : CrystalClick::CompactPartPhysicalContext,
  granule : CrystalClick::CompactPartPhysicalGranule,
  plan : CrystalClick::CompactRecursiveJsonBulkSite,
  column_name : String,
  reverse_first : Bool = false,
  omit_last : Bool = false,
) : CrystalClick::CompactRecursiveJsonParentMarkLedger
  callbacks = [] of String
  callback_sizes = Hash(String, Int32).new
  granule.shards.each do |shard|
    callback = shard.stream_name || raise(CrystalClick::CorruptPartError.new("W281 Bulk callback is unnamed"))
    callbacks << callback
    callback_sizes[callback] = shard.bytes.size
  end

  ledger = CrystalClick::CompactRecursiveJsonParentMarkLedger.new(
    physical,
    column_name,
    granule,
    CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
  )
  ledger.finish_prefixes!
  ledger.begin_mixed_body_schedule!(plan.size_lane_count)

  if reverse_first
    second = callbacks[1]
    expect_raises(CrystalClick::CorruptPartError) do
      ledger.capture_bulk_body(second, callback_sizes[second])
    end
  end

  events = omit_last ? callbacks[0...callbacks.size - 1] : callbacks
  callback_by_name = Hash(String, CrystalClick::CompactRecursiveJsonBulkSite::Role).new
  plan.each_role do |role|
    callback_by_name[plan.callback_name_for(role.name)] = role
  end
  events.each do |callback|
    role = callback_by_name[callback] || raise(CrystalClick::CorruptPartError.new("W281 callback is outside the frozen Bulk schedule"))
    if role.size_lane
      ledger.capture_mixed_array_size_lane(callback, callback_sizes[callback])
    else
      ledger.capture_bulk_body(callback, callback_sizes[callback])
    end
  end
  if omit_last
    expect_raises(CrystalClick::CorruptPartError) do
      ledger.finish_mark!(callbacks)
    end
  else
    ledger.finish_mark!(callbacks)
  end
  ledger
end

describe "W281 static JSON Bulk adversary controls" do
  it "parses the literal broad leaf and wrapper roster as one JSON-free Bulk" do
    declarations = w281a_static_bulk_declarations
    observed = declarations.map do |declaration, _expected|
      begin
        schema = CrystalClick::StorageColumnSchema.parse("Tuple(JSON(id UInt64), #{declaration})")
        child = schema.child_at(1)
        if schema.tuple? && schema.child_count == 2 && schema.child_at(0).object? &&
           child.bulk? && !child.bulk_type.contains_json?
          "#{declaration}=#{child.bulk_type.name}"
        else
          "#{declaration}=not-one-json-free-bulk"
        end
      rescue ex : CrystalClick::UnsupportedFormatError
        "#{declaration}=unsupported"
      end
    end
    expected = declarations.map { |declaration, canonical| "#{declaration}=#{canonical}" }
    observed.should eq(expected)
  end

  it "keeps opaque static Bulk widening isolated from default ObjectJson admission" do
    w281a_json_guard_declarations.each do |declaration|
      bytes = declaration.to_slice
      CrystalClick::ObjectRecursiveDeclaration.preflight_slice(bytes, 0, bytes.size).should be_nil
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(value #{declaration})")
      end
    end
  end

  it "keeps the DynamicBulk Map key profile separate from ObjectJson's String-only Map" do
    declaration = "Map(UInt8, String)"
    bytes = declaration.to_slice
    preflight = CrystalClick::ObjectRecursiveDeclaration.preflight_slice(
      bytes,
      0,
      bytes.size,
      profile: CrystalClick::ObjectRecursiveDeclaration::AdmissionProfile::DynamicBulk,
    )
    preflight.should_not be_nil
    CrystalClick::ObjectRecursiveDeclaration.preflight_slice(bytes, 0, bytes.size).should be_nil
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(value #{declaration})")
    end
  end

  it "rejects a resealed noncanonical String0 VarUInt after a literal positive control" do
    w281a_assert_small_string_corruption(CrystalClick::BinaryBulkProfile.single_stream, false, :noncanonical)
  end

  it "rejects a resealed String1 size mismatch after a literal positive control" do
    w281a_assert_small_string_corruption(CrystalClick::BinaryBulkProfile.with_size_stream, true, :oversum)
  end

  it "rejects canonical String0 trailing payload after consuming fewer bytes than the callback" do
    w281a_assert_small_string_corruption(CrystalClick::BinaryBulkProfile.single_stream, false, :trailing_data)
  end

  it "rejects a resealed String1 undersum that leaves trailing data in its body callback" do
    w281a_assert_small_string_corruption(CrystalClick::BinaryBulkProfile.with_size_stream, true, :undersum)
  end

  it "rolls back a failed MRK3 Bulk grammar callback after a fixed lane and retries the same suffix" do
    w281a_with_prefix_free_bulk_mark(CrystalClick::CompactMarkFormat::Mrk3) do |physical, granule, plan|
      physical.mode.mrk3?.should be_true
      fixed_callback = plan.stream_name_for("root.field.0.data")
      string_callback = plan.stream_name_for("root.field.1.data")
      expected_fixed = Bytes[0x34_u8, 0x12_u8, 0x78_u8, 0x56_u8]
      expected_suffix = Bytes[0x03_u8, 'a'.ord.to_u8, 'b'.ord.to_u8, 'c'.ord.to_u8, 0x02_u8, 'd'.ord.to_u8, 'e'.ord.to_u8]
      events = [fixed_callback, string_callback] of String

      ledger = CrystalClick::CompactRecursiveJsonParentMarkLedger.new(
        physical,
        "payload",
        granule,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
      )
      ledger.finish_prefixes!
      ledger.begin_mixed_body_schedule!(0)
      fixed = ledger.capture_bulk_body(fixed_callback, expected_fixed.size)
      fixed.should eq(expected_fixed)
      ledger.complete?.should be_false

      expect_raises(CrystalClick::CorruptPartError, /seeded W281 MRK3 parser failure/) do
        ledger.with_bulk_body_grammar_extent(string_callback) do |borrowed|
          borrowed.should eq(expected_suffix)
          raise CrystalClick::CorruptPartError.new("seeded W281 MRK3 parser failure")
          {Bytes.empty, 0}
        end
      end
      ledger.complete?.should be_false

      parsed, capture = ledger.with_bulk_body_grammar_extent(string_callback) do |borrowed|
        borrowed.should eq(expected_suffix)
        {borrowed.dup, borrowed.size}
      end
      parsed.should eq(expected_suffix)
      capture.bytes.should eq(expected_suffix)
      ledger.complete?.should be_false
      ledger.finish_mark!(events)
      ledger.complete?.should be_true
    end
  end

  it "rolls back an under-consumed MRK4 Bulk callback and completes only after exact retry" do
    w281a_with_prefix_free_bulk_mark(CrystalClick::CompactMarkFormat::Mrk4) do |physical, granule, plan|
      physical.mode.mrk4?.should be_true
      fixed_callback = plan.stream_name_for("root.field.0.data")
      string_callback = plan.stream_name_for("root.field.1.data")
      expected_fixed = Bytes[0x34_u8, 0x12_u8, 0x78_u8, 0x56_u8]
      expected_suffix = Bytes[0x03_u8, 'a'.ord.to_u8, 'b'.ord.to_u8, 'c'.ord.to_u8, 0x02_u8, 'd'.ord.to_u8, 'e'.ord.to_u8]
      events = [fixed_callback, string_callback] of String

      ledger = CrystalClick::CompactRecursiveJsonParentMarkLedger.new(
        physical,
        "payload",
        granule,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
      )
      ledger.finish_prefixes!
      ledger.begin_mixed_body_schedule!(0)
      fixed = ledger.capture_bulk_body(fixed_callback, expected_fixed.size)
      fixed.should eq(expected_fixed)
      ledger.complete?.should be_false

      expect_raises(CrystalClick::CorruptPartError) do
        ledger.with_bulk_body_grammar_extent(string_callback) do |borrowed|
          borrowed.should eq(expected_suffix)
          {borrowed.size, borrowed.size - 1}
        end
      end
      ledger.complete?.should be_false

      parsed, capture = ledger.with_bulk_body_grammar_extent(string_callback) do |borrowed|
        borrowed.should eq(expected_suffix)
        {borrowed.dup, borrowed.size}
      end
      parsed.should eq(expected_suffix)
      capture.bytes.should eq(expected_suffix)
      ledger.complete?.should be_false
      ledger.finish_mark!(events)
      ledger.complete?.should be_true
    end
  end

  it "pins literal Nothing and empty-Tuple sentinels and rejects either malformed lane" do
    fixture = CompactPartWriterW281Fixture
    profile = CrystalClick::BinaryBulkProfile.single_stream
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    callback_plan = CrystalClick::CompactJsonCallbackPlan.new(
      fixture.column.json_input(profile),
      limits,
      CrystalClick::BinaryCodecBudget.new(limits, true),
    )
    bulk = callback_plan.schema_plan.bulk_site("root/tuple[1]")
    nothing_index = fixture.bulk_fields.index { |field| field[0] == "nothing" } ||
                    raise "W281 fixture has no Nothing field"
    empty_tuple_index = fixture.bulk_fields.index { |field| field[0] == "empty_tuple" } ||
                        raise "W281 fixture has no empty Tuple field"
    callbacks = [
      {"Nothing", bulk.callback_name_for("root.field.#{nothing_index}.data")},
      {"empty Tuple", bulk.callback_name_for("root.field.#{empty_tuple_index}.data")},
    ] of Tuple(String, String)

    positive_parent = File.tempname("crystal-click-w281-sentinels-positive-")
    positive_path = File.join(positive_parent, "all_1_1_0")
    Dir.mkdir(positive_parent)
    begin
      w281a_write_local_fixture_part(positive_path)
      physical = CrystalClick::CompactPartPhysicalContext.open(positive_path)
      granule = physical.read_window(CompactPartWriterW281Fixture::COLUMN_NAME, 0, 1).granules.first? ||
                raise(CrystalClick::CorruptPartError.new("W281 sentinel fixture has no first mark"))
      callbacks.each do |label, callback|
        shard = granule.shards.find { |candidate| candidate.stream_name == callback } ||
                raise(CrystalClick::CorruptPartError.new("W281 #{label} sentinel callback is absent"))
        shard.bytes.should eq(Bytes[0x30_u8, 0x30_u8])
      end

      physical.granule_count.should eq(4)
      physical.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      raw = CrystalClick::CompressedMarkReader.read_all(
        File.join(positive_path, "data.bin"),
        File.size(File.join(positive_path, "data.bin")).to_i64,
      )
      w281a_reseal_mrk4!(positive_path, physical, raw)

      resealed = CrystalClick::CompactPartPhysicalContext.open(positive_path)
      resealed.mode.should eq(CrystalClick::CompactMarkFormat::Mrk4)
      resealed.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        positive_path,
        CompactPartWriterW281Fixture::COLUMN_NAME,
        fixture.schema,
      )
      fixture.signatures_from(reader.read_marks(0, 4)).should eq(fixture.expected_signatures)
    ensure
      FileUtils.rm_rf(positive_parent)
    end

    callbacks.each do |label, callback|
      parent = File.tempname("crystal-click-w281-sentinel-negative-")
      part_path = File.join(parent, "all_1_1_0")
      Dir.mkdir(parent)
      begin
        w281a_write_local_fixture_part(part_path)
        physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
        granule = physical.read_window(CompactPartWriterW281Fixture::COLUMN_NAME, 0, 1).granules.first? ||
                  raise(CrystalClick::CorruptPartError.new("W281 sentinel fixture has no first mark"))
        shard = granule.shards.find { |candidate| candidate.stream_name == callback } ||
                raise(CrystalClick::CorruptPartError.new("W281 #{label} sentinel callback is absent"))
        raw = CrystalClick::CompressedMarkReader.read_all(
          File.join(part_path, "data.bin"),
          File.size(File.join(part_path, "data.bin")).to_i64,
        )
        raw[shard.logical_start.to_i] = 0x00_u8
        w281a_reseal_mrk4!(part_path, physical, raw)

        # The mutant must remain a physically valid four-granule MRK4 part.
        # A reframe/grid failure must not masquerade as sentinel validation.
        resealed = CrystalClick::CompactPartPhysicalContext.open(part_path)
        resealed.mode.should eq(CrystalClick::CompactMarkFormat::Mrk4)
        resealed.granule_count.should eq(4)
        resealed.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
        mutated_granule = resealed.read_window(CompactPartWriterW281Fixture::COLUMN_NAME, 0, 1).granules.first? ||
                          raise "W281 resealed mutant has no first mark"
        mutated_shard = mutated_granule.shards.find { |candidate| candidate.stream_name == callback } ||
                        raise "W281 resealed mutant has no #{label} callback"
        mutated_shard.bytes.should eq(Bytes[0x00_u8, 0x30_u8])

        reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
          part_path,
          CompactPartWriterW281Fixture::COLUMN_NAME,
          fixture.schema,
        )
        expect_raises(
          CrystalClick::CorruptPartError,
          "#{label} bulk placeholder is not canonical ASCII zero",
        ) do
          reader.read_marks(0, 1)
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "preserves String1 zero-child callbacks and seals their exact mixed-ledger order" do
    string = CrystalClick::BinaryDataType.primitive("String")
    array = CrystalClick::BinaryDataType.array(string)
    type = CrystalClick::BinaryDataType.tuple([array, array] of CrystalClick::BinaryDataType)
    profile = CrystalClick::BinaryBulkProfile.with_size_stream
    column = CrystalClick::CompactPartColumn.binary_bulk(
      "payload",
      type,
      [
        [
          w281a_string_pair_row(type, [] of String, [] of String),
          w281a_string_pair_row(type, [] of String, [] of String),
        ] of CrystalClick::BinaryValue,
        [
          w281a_string_pair_row(type, ["2"] of String, [] of String),
          w281a_string_pair_row(type, ["3"] of String, [] of String),
        ] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue),
    )
    parent = File.tempname("crystal-click-w281-zero-ledger-")
    part_path = File.join(parent, "all_1_1_0")
    Dir.mkdir(parent)
    begin
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        "pk",
        Slice[1_u64, 2_u64, 3_u64, 4_u64],
        [column] of CrystalClick::CompactPartColumn,
        rows_per_mark: 2,
        frame_bytes: 4096,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
        profile: profile,
      )

      limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
      physical_plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, "payload", profile, limits)
      plan = CrystalClick::CompactRecursiveJsonBulkSite.new(
        "root/tuple[1]",
        "payload",
        2,
        0_u64,
        type,
        physical_plan,
        limits,
        CrystalClick::BinaryCodecBudget.new(limits, true),
      )
      role_names = [] of String
      plan.each_role { |role| role_names << role.name }
      role_names.should eq([
        "root.field.0.sizes",
        "root.field.0.elements.string_sizes",
        "root.field.0.elements.data",
        "root.field.1.sizes",
        "root.field.1.elements.string_sizes",
        "root.field.1.elements.data",
      ] of String)
      plan.size_lane_count.should eq(2)

      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      physical.mode.mrk4?.should be_true
      physical.mark_row_counts.should eq([2_u64, 2_u64])

      first = physical.read_window("payload", 0, 1).granules.first? ||
              raise(CrystalClick::CorruptPartError.new("W281 first String1 mark is absent"))
      first_names = first.shards.map { |shard| shard.stream_name || "" }
      first_names.should eq(role_names.map { |role| plan.callback_name_for(role) })
      first.shards.map(&.bytes).should eq([
        w281a_le64([0_u64, 0_u64]),
        Bytes.empty,
        Bytes.empty,
        w281a_le64([0_u64, 0_u64]),
        Bytes.empty,
        Bytes.empty,
      ] of Bytes)
      first_ledger = w281a_capture_bulk_mark(physical, first, plan, "payload", reverse_first: true)
      first_ledger.complete?.should be_true

      second = physical.read_window("payload", 1, 1).granules.first? ||
               raise(CrystalClick::CorruptPartError.new("W281 populated String1 mark is absent"))
      second.shards.map(&.bytes).should eq([
        w281a_le64([1_u64, 1_u64]),
        w281a_le64([1_u64, 1_u64]),
        Bytes[0x32_u8, 0x33_u8],
        w281a_le64([0_u64, 0_u64]),
        Bytes.empty,
        Bytes.empty,
      ] of Bytes)
      missing_ledger = w281a_capture_bulk_mark(physical, second, plan, "payload", omit_last: true)
      missing_ledger.complete?.should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
