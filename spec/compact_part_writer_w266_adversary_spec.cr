require "./spec_helper"

module CompactPartWriterW266AdversaryFixture
  extend self

  KEY_NAME    = "pk"
  ROW_COUNT   =  6
  MARK_ROWS   =  2
  FRAME_BYTES = 32

  def string_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("String")
  end

  def scalar_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.low_cardinality(string_type)
  end

  def nullable_scalar_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.low_cardinality(
      CrystalClick::BinaryDataType.nullable(string_type),
    )
  end

  def nested_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.tuple(
      [
        scalar_type,
        CrystalClick::BinaryDataType.array(nullable_scalar_type),
      ] of CrystalClick::BinaryDataType,
      ["scalar", "items"],
    )
  end

  def nested_column : CrystalClick::CompactPartColumn
    type = nested_type
    scalar_rows = [
      "amber", "blue", "amber", "middle", "blue", "violet",
    ]
    raw = String.new(Bytes[0xff_u8, 0x80_u8, 0x41_u8])
    item_rows = [
      ["north", nil, ""] of String?,
      ["east", "north"] of String?,
      [] of String?,
      ["south", "middle"] of String?,
      ["west", raw] of String?,
      ["north", nil] of String?,
    ]

    rows = [] of CrystalClick::BinaryValue
    ROW_COUNT.times do |index|
      scalar = low_string(type.child_at(0), scalar_rows[index])
      items_type = type.child_at(1)
      item_values = item_rows[index].map do |value|
        low_nullable_string(items_type.child_at(0), value)
      end
      items = CrystalClick::BinaryValue.array(items_type, item_values)
      rows << CrystalClick::BinaryValue.tuple(type, [scalar, items] of CrystalClick::BinaryValue)
    end

    granules = rows.each_slice(MARK_ROWS).map(&.to_a).to_a
    CrystalClick::CompactPartColumn.binary_bulk("payload", type, granules)
  end

  def nested_keys : Slice(UInt64)
    Slice(UInt64).new(ROW_COUNT) { |index| 501_u64 + index.to_u64 }
  end

  def empty_array_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(nullable_scalar_type)
  end

  def empty_array_column : CrystalClick::CompactPartColumn
    type = empty_array_type
    rows = [] of CrystalClick::BinaryValue
    ROW_COUNT.times do
      rows << CrystalClick::BinaryValue.array(type, [] of CrystalClick::BinaryValue)
    end
    granules = rows.each_slice(MARK_ROWS).map(&.to_a).to_a
    CrystalClick::CompactPartColumn.binary_bulk("empty_items", type, granules)
  end

  def empty_array_keys : Slice(UInt64)
    Slice(UInt64).new(ROW_COUNT) { |index| 601_u64 + index.to_u64 }
  end

  def budget_column : CrystalClick::CompactPartColumn
    type = scalar_type
    rows_by_mark = [
      ["amber", "blue"] of String,
      ["amber", "middle"] of String,
      ["blue", "violet"] of String,
    ]
    granules = rows_by_mark.map do |rows|
      rows.map { |value| low_string(type, value) }
    end
    CrystalClick::CompactPartColumn.binary_bulk("root", type, granules)
  end

  def budget_keys : Slice(UInt64)
    Slice(UInt64).new(ROW_COUNT) { |index| 701_u64 + index.to_u64 }
  end

  private def low_string(type : CrystalClick::BinaryDataType, value : String) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.low_cardinality(type, CrystalClick::BinaryValue.string(value))
  end

  private def low_nullable_string(
    type : CrystalClick::BinaryDataType,
    value : String?,
  ) : CrystalClick::BinaryValue
    nullable_type = type.child_at(0)
    nullable = if value
                 CrystalClick::BinaryValue.nullable(nullable_type, CrystalClick::BinaryValue.string(value))
               else
                 CrystalClick::BinaryValue.nullable(nullable_type)
               end
    CrystalClick::BinaryValue.low_cardinality(type, nullable)
  end
end

private def w266a_read_u64_le(bytes : Bytes, offset : Int) : UInt64
  if offset < 0 || offset > bytes.size - 8
    raise "W266 adversary record is missing a UInt64 field"
  end
  value = 0_u64
  8.times do |index|
    value |= bytes[offset + index].to_u64 << (index * 8)
  end
  value
end

private def w266a_read_var_uint(bytes : Bytes, offset : Int32) : Tuple(UInt64, Int32)
  value = 0_u64
  shift = 0
  cursor = offset
  loop do
    raise "W266 adversary string length is truncated" if cursor >= bytes.size
    byte = bytes[cursor]
    cursor += 1
    if shift >= 64 || ((byte & 0x7f_u8).to_u64 > (UInt64::MAX >> shift))
      raise "W266 adversary string length overflows UInt64"
    end
    value |= (byte & 0x7f_u8).to_u64 << shift
    break if (byte & 0x80_u8) == 0_u8
    shift += 7
  end
  {value, cursor}
end

private def w266a_parse_additional_index(
  bytes : Bytes,
) : Tuple(UInt64, Array(String), UInt64, Array(UInt64))
  flags = w266a_read_u64_le(bytes, 0)
  raise "W266 adversary fixture requires one-byte LC IDs" unless (flags & 0x3_u64) == 0_u64
  key_count = w266a_read_u64_le(bytes, 8)
  raise "W266 adversary dictionary key count exceeds its index record" if key_count > bytes.size.to_u64

  cursor = 16
  keys = [] of String
  key_count.to_i.times do
    length, cursor = w266a_read_var_uint(bytes, cursor)
    if length > (bytes.size - cursor).to_u64
      raise "W266 adversary dictionary key is truncated"
    end
    keys << bytes[cursor, length.to_i].hexstring
    cursor += length.to_i
  end

  row_count = w266a_read_u64_le(bytes, cursor)
  cursor += 8
  if row_count > (bytes.size - cursor).to_u64
    raise "W266 adversary LC ID vector is truncated"
  end
  ids = Array(UInt64).new(row_count.to_i)
  row_count.to_i.times do
    ids << bytes[cursor].to_u64
    cursor += 1
  end
  raise "W266 adversary index record has trailing bytes" unless cursor == bytes.size
  {flags, keys, row_count, ids}
end

private def w266a_expect_site(
  mark : CrystalClick::CompactPartPhysicalGranule,
  prefix_name : String,
  dictionary_name : String,
  index_name : String,
  expected_keys : Array(String),
  expected_ids : Array(UInt64),
) : Nil
  prefix = mark.shards.find { |shard| shard.stream_name == prefix_name } ||
           raise "missing #{prefix_name} callback"
  dictionary = mark.shards.find { |shard| shard.stream_name == dictionary_name } ||
               raise "missing #{dictionary_name} callback"
  indexes = mark.shards.find { |shard| shard.stream_name == index_name } ||
            raise "missing #{index_name} callback"

  prefix.bytes.size.should eq(8)
  w266a_read_u64_le(prefix.bytes, 0).should eq(CrystalClick::BinaryLowCardinalityStorageStreams::VERSION)
  dictionary.bytes.should be_empty
  flags, keys, row_count, ids = w266a_parse_additional_index(indexes.bytes)
  flags.should eq(
    CrystalClick::BinaryLowCardinalityStorageStreams::ADDITIONAL_BIT |
    CrystalClick::BinaryLowCardinalityStorageStreams::UPDATE_BIT,
  )
  keys.should eq(expected_keys)
  row_count.should eq(expected_ids.size.to_u64)
  ids.should eq(expected_ids)
end

private def w266a_nullable_signature(value : CrystalClick::BinaryValue) : String
  return "N" if value.is_null?
  "S:#{value.child_at(0).as_string.to_slice.hexstring}"
end

private def w266a_nested_signature(value : CrystalClick::BinaryValue) : String
  scalar_hex = value.child_at(0).child_at(0).as_string.to_slice.hexstring
  items = value.child_at(1).elements.map do |item|
    w266a_nullable_signature(item.child_at(0))
  end
  "#{scalar_hex}|[#{items.join(",")}]"
end

private def w266a_table_window(
  table : CrystalClick::CompactPartTable,
  start_row : UInt64,
  max_rows : Int32,
) : Tuple(Int32, Array(UInt64), Array(String))
  callbacks = 0
  keys = [] of UInt64
  rows = [] of String
  table.scan_typed_window(start_row, max_rows) do |batch|
    callbacks += 1
    keys.concat(batch.values_for(CompactPartWriterW266AdversaryFixture::KEY_NAME))
    batch.binary_bulk_values_for("payload").each do |value|
      rows << w266a_nested_signature(value)
    end
  end
  {callbacks, keys, rows}
end

describe CrystalClick::CompactPartWriter do
  it "keeps two nested LC sites mark-local and supports authenticated row windows" do
    fixture = CompactPartWriterW266AdversaryFixture
    type = fixture.nested_type
    CrystalClick::WidePart.supports_generic_static_binary_bulk_type?(type.name).should be_true
    CrystalClick::BinaryValueTypedBatchAdapter.admitted?(type).should be_true

    parent = File.tempname("crystal-click-w266-nested-adversary-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW266AdversaryFixture::KEY_NAME,
        fixture.nested_keys,
        [fixture.nested_column] of CrystalClick::CompactPartColumn,
        rows_per_mark: CompactPartWriterW266AdversaryFixture::MARK_ROWS,
        frame_bytes: CompactPartWriterW266AdversaryFixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      )

      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      physical.row_count.should eq(6_u64)
      physical.granule_count.should eq(3_i32)
      physical.physical_roster.map do |slot|
        {slot.index, slot.column_name, slot.stream_name}
      end.should eq([
        {0_i32, "pk", "pk"},
        {1_i32, "payload", "payload%2Escalar.dict_prefix"},
        {2_i32, "payload", "payload%2Eitems.dict_prefix"},
        {3_i32, "payload", "payload%2Escalar.dict"},
        {4_i32, "payload", "payload%2Escalar"},
        {5_i32, "payload", "payload%2Eitems.size0"},
        {6_i32, "payload", "payload%2Eitems.dict"},
        {7_i32, "payload", "payload%2Eitems"},
      ] of Tuple(Int32, String, String?))

      marks = physical.read_window("payload", 0, 3).granules
      marks.size.should eq(3)
      scalar_expectations = [
        {["", "616d626572", "626c7565"], [1_u64, 2_u64]},
        {["", "616d626572", "6d6964646c65"], [1_u64, 2_u64]},
        {["", "626c7565", "76696f6c6574"], [1_u64, 2_u64]},
      ]
      item_expectations = [
        {["", "", "6e6f727468", "65617374"], [2_u64, 0_u64, 1_u64, 3_u64, 2_u64]},
        {["", "", "736f757468", "6d6964646c65"], [2_u64, 3_u64]},
        {["", "", "77657374", "ff8041", "6e6f727468"], [2_u64, 3_u64, 4_u64, 0_u64]},
      ]
      marks.each_with_index do |mark, index|
        w266a_expect_site(
          mark,
          "payload%2Escalar.dict_prefix",
          "payload%2Escalar.dict",
          "payload%2Escalar",
          scalar_expectations[index][0],
          scalar_expectations[index][1],
        )
        w266a_expect_site(
          mark,
          "payload%2Eitems.dict_prefix",
          "payload%2Eitems.dict",
          "payload%2Eitems",
          item_expectations[index][0],
          item_expectations[index][1],
        )
      end

      table = CrystalClick::CompactPartTable.open_selected_typed(
        [part_path],
        [CompactPartWriterW266AdversaryFixture::KEY_NAME, "payload"],
      )
      expected_keys = [501_u64, 502_u64, 503_u64, 504_u64, 505_u64, 506_u64]
      expected_rows = [
        "616d626572|[S:6e6f727468,N,S:]",
        "626c7565|[S:65617374,S:6e6f727468]",
        "616d626572|[]",
        "6d6964646c65|[S:736f757468,S:6d6964646c65]",
        "626c7565|[S:77657374,S:ff8041]",
        "76696f6c6574|[S:6e6f727468,N]",
      ]

      full = w266a_table_window(table, 0_u64, 6)
      full[0].should eq(3)
      full[1].should eq(expected_keys)
      full[2].should eq(expected_rows)

      middle = w266a_table_window(table, 2_u64, 2)
      middle.should eq({1, expected_keys[2, 2], expected_rows[2, 2]})
      cross_mark = w266a_table_window(table, 1_u64, 4)
      cross_mark[0].should eq(3)
      cross_mark[1].should eq(expected_keys[1, 4])
      cross_mark[2].should eq(expected_rows[1, 4])
      last = w266a_table_window(table, 4_u64, 2)
      last.should eq({1, expected_keys[4, 2], expected_rows[4, 2]})
      empty = w266a_table_window(table, 6_u64, 1)
      empty.should eq({0, [] of UInt64, [] of String})
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "persists every prefix while all nested LC child marks remain empty" do
    fixture = CompactPartWriterW266AdversaryFixture
    type = fixture.empty_array_type
    CrystalClick::WidePart.supports_generic_static_binary_bulk_type?(type.name).should be_true
    CrystalClick::BinaryValueTypedBatchAdapter.admitted?(type).should be_true

    parent = File.tempname("crystal-click-w266-empty-child-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW266AdversaryFixture::KEY_NAME,
        fixture.empty_array_keys,
        [fixture.empty_array_column] of CrystalClick::CompactPartColumn,
        rows_per_mark: CompactPartWriterW266AdversaryFixture::MARK_ROWS,
        frame_bytes: CompactPartWriterW266AdversaryFixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      )

      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      physical.physical_roster.map do |slot|
        {slot.index, slot.column_name, slot.stream_name}
      end.should eq([
        {0_i32, "pk", "pk"},
        {1_i32, "empty_items", "empty_items.dict_prefix"},
        {2_i32, "empty_items", "empty_items.size0"},
        {3_i32, "empty_items", "empty_items.dict"},
        {4_i32, "empty_items", "empty_items"},
      ] of Tuple(Int32, String, String?))

      marks = physical.read_window("empty_items", 0, 3).granules
      marks.size.should eq(3)
      marks.each do |mark|
        prefix = mark.shards.find { |shard| shard.stream_name == "empty_items.dict_prefix" } ||
                 raise "missing empty-child dictionary prefix"
        sizes = mark.shards.find { |shard| shard.stream_name == "empty_items.size0" } ||
                raise "missing empty-child array-size callback"
        dictionary = mark.shards.find { |shard| shard.stream_name == "empty_items.dict" } ||
                     raise "missing empty-child dictionary callback"
        indexes = mark.shards.find { |shard| shard.stream_name == "empty_items" } ||
                  raise "missing empty-child index callback"
        prefix.bytes.size.should eq(8)
        w266a_read_u64_le(prefix.bytes, 0).should eq(CrystalClick::BinaryLowCardinalityStorageStreams::VERSION)
        sizes.bytes.should eq(Bytes[
          0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
          0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
        ])
        dictionary.bytes.should be_empty
        indexes.bytes.should be_empty
      end

      reader = CrystalClick::CompactBinaryBulkColumnReader.open(part_path, "empty_items", type)
      reader.read_marks(0, 3).flatten.each do |row|
        row.elements.should be_empty
      end
      table = CrystalClick::CompactPartTable.open_selected_typed(
        [part_path],
        [CompactPartWriterW266AdversaryFixture::KEY_NAME, "empty_items"],
      )
      seen = 0
      table.scan_typed_window(2_u64, 2) do |batch|
        batch.binary_bulk_values_for("empty_items").each do |row|
          row.elements.should be_empty
          seen += 1
        end
      end
      seen.should eq(2)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "charges repeated version prefixes to the cumulative byte budget before publication" do
    fixture = CompactPartWriterW266AdversaryFixture
    budget_column = fixture.budget_column.static_input
    input = CrystalClick::CompactStaticColumnInput.new(
      "root",
      fixture.scalar_type,
      budget_column.granules,
    )

    exact_limits = CrystalClick::BinaryCodecLimits.new(64, 4_096, 1_000_000, 141)
    exact_plan = CrystalClick::CompactStaticCallbackPlan.new(input, exact_limits)
    exact_budget = CrystalClick::BinaryCodecBudget.new(exact_limits, true)
    encoded = CrystalClick::CompactEncodedColumn.encode(exact_plan, input.granules, exact_budget)
    exact_budget.wire_byte_count.should eq(141_i64)

    prefix_bytes = 0_u64
    body_bytes = 0_u64
    exact_plan.each_callback_event do |event|
      3.times do |mark|
        callback_bytes = encoded.callback_bytes(event, mark)
        if event.prefix?
          prefix_bytes += callback_bytes.size.to_u64
        else
          body_bytes += callback_bytes.size.to_u64
        end
      end
    end
    prefix_bytes.should eq(24_u64)
    body_bytes.should eq(117_u64)

    short_limits = CrystalClick::BinaryCodecLimits.new(64, 4_096, 1_000_000, 140)
    short_input = CrystalClick::CompactStaticColumnInput.new(
      "root",
      fixture.scalar_type,
      input.granules,
    )
    short_plan = CrystalClick::CompactStaticCallbackPlan.new(short_input, short_limits)
    short_budget = CrystalClick::BinaryCodecBudget.new(short_limits, true)
    expect_raises(CrystalClick::UnsupportedFormatError, /binary codec byte limit exceeded/) do
      CrystalClick::CompactEncodedColumn.encode(short_plan, short_input.granules, short_budget)
    end

    parent = File.tempname("crystal-click-w266-prefix-budget-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      # Exact MRK3 accounting for this fixture is 279 bytes of type-name and
      # metadata charges, 48 bytes for the UInt64 key tape, and 141 bytes for
      # the LC tape (24 version-prefix bytes plus 117 per-mark index bytes).
      # A 467-byte cap is one byte short; omitting all three prefixes would
      # leave the operation within the cap.
      limits = CrystalClick::BinaryCodecLimits.new(64, 4_096, 1_000_000, 467)
      expect_raises(CrystalClick::UnsupportedFormatError, /binary codec byte limit exceeded/) do
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW266AdversaryFixture::KEY_NAME,
          fixture.budget_keys,
          [fixture.budget_column] of CrystalClick::CompactPartColumn,
          rows_per_mark: CompactPartWriterW266AdversaryFixture::MARK_ROWS,
          frame_bytes: CompactPartWriterW266AdversaryFixture::FRAME_BYTES,
          limits: limits,
          mark_format: CrystalClick::CompactMarkFormat::Mrk3,
        )
      end
      File.exists?(part_path).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
