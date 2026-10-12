require "./spec_helper"
require "./support/compact_part_writer_w264_fixture"

# Count only mark-grid opens through the writer's owned staging directory.
# The probe remains dormant for the rest of the suite and delegates unchanged.
class CrystalClick::CompactMarkIndex
  class_property w264_grid_guard_probe_enabled = false
  class_property w264_grid_guard_probe_parent = ""
  class_property w264_grid_guard_probe_calls = 0

  def self.read(
    input : PartPhysicalInput,
    roster : CompactColumnsSubstreams,
    expected_row_count : UInt64,
    budget : CompressedStreamBudget,
  ) : CompactMarkIndex
    stage = File.dirname(input.data_path)
    if w264_grid_guard_probe_enabled &&
       File.dirname(stage) == w264_grid_guard_probe_parent &&
       File.basename(stage).starts_with?(".crystal-click-wide-writer-")
      self.w264_grid_guard_probe_calls += 1
    end
    previous_def
  end
end

class CrystalClick::CompactBinaryBulkColumnReader
  class_property w264_workspace_probe_enabled = false
  class_property w264_workspace_probe_parent = ""
  class_property w264_workspace_probe_column = ""
  class_property w264_workspace_probe_events = [] of Tuple(String, Int32, Int32, UInt64, Int64)

  def read_marks(
    first_mark : Int,
    mark_count : Int,
    workspace_observer : Proc(UInt64, Nil),
  ) : Array(Array(BinaryValue))
    stage = @part_path
    if self.class.w264_workspace_probe_enabled &&
       File.dirname(stage) == self.class.w264_workspace_probe_parent &&
       File.basename(stage).starts_with?(".crystal-click-wide-writer-") &&
       @column_name == self.class.w264_workspace_probe_column
      observed = ->(workspace : UInt64) do
        CrystalClick::CompactBinaryBulkColumnReader.w264_workspace_probe_events << {
          String.new(@column_name.to_slice),
          first_mark.to_i32,
          mark_count.to_i32,
          workspace,
          @transport_budget.not_nil!.result_byte_count,
        }
        workspace_observer.call(workspace)
      end
      previous_def(first_mark, mark_count, observed)
    else
      previous_def(first_mark, mark_count, workspace_observer)
    end
  end
end

class CrystalClick::CompactPartPhysicalContext
  class_property w264_window_probe_enabled = false
  class_property w264_window_probe_parent = ""
  class_property w264_window_probe_column = ""
  class_property w264_window_probe_calls = 0

  def read_window(
    column_name : String,
    first_mark : Int,
    mark_count : Int,
  ) : CompactPartPhysicalWindow
    stage = File.dirname(@data_input.data_path)
    if self.class.w264_window_probe_enabled &&
       File.dirname(stage) == self.class.w264_window_probe_parent &&
       File.basename(stage).starts_with?(".crystal-click-wide-writer-") &&
       column_name == self.class.w264_window_probe_column && first_mark == 0 && mark_count == 1
      self.class.w264_window_probe_calls += 1
    end
    previous_def(column_name, first_mark, mark_count)
  end
end

private def w264_typed_batch_for(
  type : CrystalClick::BinaryDataType,
  row_count : UInt64,
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

describe CrystalClick::CompactPartWriter do
  it "publishes independently literal static columns across four shared Compact marks and EOF" do
    fixture = CompactPartWriterW264Fixture
    root = File.tempname("crystal-click-w264-compact-writer-")
    part_path = File.join(root, "all_1_1_0")
    begin
      Dir.mkdir(root)
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        "pk",
        fixture.keys,
        fixture.columns,
        rows_per_mark: CompactPartWriterW264Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW264Fixture::FRAME_BYTES,
      )

      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      physical.mode.should eq(CrystalClick::CompactMarkFormat::Mrk3)
      physical.row_count.should eq(CompactPartWriterW264Fixture::ROW_COUNT.to_u64)
      physical.granule_count.should eq(4)
      physical.columns.should eq(
        [
          {"pk", "UInt64"},
          {"u", "UInt64"},
          {"text", "String"},
          {"maybe", "Nullable(UInt64)"},
          {"gap", "Array(Nullable(UInt64))"},
          {"arr", "Array(Nullable(UInt64))"},
          {"pair", "Tuple(String, Nullable(UInt64))"},
          {"lookup", "Map(String, UInt64)"},
        ] of Tuple(String, String),
      )
      physical.physical_roster.map(&.column_name).should eq(
        ["pk", "u", "text", "maybe", "gap", "arr", "pair", "lookup"],
      )

      CompactPartWriterW264Fixture::COLUMN_NAMES.each do |name|
        reader = CrystalClick::CompactBinaryBulkColumnReader.open(
          part_path,
          name,
          fixture.types[name],
        )
        reader.mark_count.should eq(4)
        reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
        full = reader.read_marks(0, reader.mark_count).flatten
        full.map { |value| fixture.row_signature(value) }.should eq(fixture.signatures_for(name))
        reader.read_marks(3, 1).flatten.map { |value| fixture.row_signature(value) }
          .should eq(fixture.signatures_for(name)[6, 2])
        reader.read_marks(4, 0).should be_empty
        expect_raises(ArgumentError, /Compact selected mark range is outside the physical grid/) do
          reader.read_marks(4, 1)
        end
      end

      selected = ["pk"] + CompactPartWriterW264Fixture::COLUMN_NAMES
      table = CrystalClick::CompactPartTable.open_selected_typed([part_path], selected)
      table.total_row_count.should eq(CompactPartWriterW264Fixture::ROW_COUNT.to_u64)
      table.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64, 2_u64]])
      table.column_types.should eq(
        [
          {"pk", "UInt64"},
          {"u", "UInt64"},
          {"text", "String"},
          {"maybe", "Nullable(UInt64)"},
          {"gap", "Array(Nullable(UInt64))"},
          {"arr", "Array(Nullable(UInt64))"},
          {"pair", "Tuple(String, Nullable(UInt64))"},
          {"lookup", "Map(String, UInt64)"},
        ] of Tuple(String, String),
      )

      full_keys = [] of UInt64
      full_values = Hash(String, Array(String)).new do |values, name|
        values[name] = [] of String
      end
      callbacks = 0
      table.scan_typed do |batch|
        callbacks += 1
        full_keys.concat(batch.values_for("pk"))
        CompactPartWriterW264Fixture::COLUMN_NAMES.each do |name|
          full_values[name].concat(fixture.batch_signatures(batch, name))
        end
      end
      callbacks.should eq(4)
      full_keys.should eq(CompactPartWriterW264Fixture::KEYS)
      CompactPartWriterW264Fixture::COLUMN_NAMES.each do |name|
        full_values[name].should eq(fixture.signatures_for(name))
      end

      window_keys = [] of UInt64
      window_values = Hash(String, Array(String)).new do |values, name|
        values[name] = [] of String
      end
      table.scan_typed_window(2_u64, 3) do |batch|
        window_keys.concat(batch.values_for("pk"))
        CompactPartWriterW264Fixture::COLUMN_NAMES.each do |name|
          window_values[name].concat(fixture.batch_signatures(batch, name))
        end
      end
      window_keys.should eq(CompactPartWriterW264Fixture::KEYS[2, 3])
      CompactPartWriterW264Fixture::COLUMN_NAMES.each do |name|
        window_values[name].should eq(fixture.signatures_for(name)[2, 3])
      end

      candidate_keys = [] of UInt64
      candidate_values = Hash(String, Array(String)).new do |values, name|
        values[name] = [] of String
      end
      table.scan_typed_candidate_marks([[1, 3]]) do |batch|
        candidate_keys.concat(batch.values_for("pk"))
        CompactPartWriterW264Fixture::COLUMN_NAMES.each do |name|
          candidate_values[name].concat(fixture.batch_signatures(batch, name))
        end
      end
      candidate_keys.should eq([103_u64, 104_u64, 107_u64, 108_u64])
      CompactPartWriterW264Fixture::COLUMN_NAMES.each do |name|
        expected = fixture.signatures_for(name)
        candidate_values[name].should eq(expected[2, 2] + expected[6, 2])
      end

      eof_callbacks = 0
      table.scan_typed_window(CompactPartWriterW264Fixture::ROW_COUNT.to_u64, 1) { |_batch| eof_callbacks += 1 }
      eof_callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps a short tail mark and rejects a Wide physical part as Compact" do
    root = File.tempname("crystal-click-w264-compact-tail-")
    compact_path = File.join(root, "compact", "all_1_1_0")
    wide_path = File.join(root, "wide", "all_1_1_0")
    begin
      Dir.mkdir(root)
      Dir.mkdir(File.join(root, "compact"))
      Dir.mkdir(File.join(root, "wide"))
      type = CrystalClick::BinaryDataType.primitive("UInt64")
      values = [11_u64, 22_u64, 33_u64, 44_u64, 55_u64].map do |value|
        CrystalClick::BinaryValue.uint64(value)
      end
      granules = [] of Array(CrystalClick::BinaryValue)
      values.each_slice(2) { |slice| granules << slice.to_a }
      keys = Slice(UInt64).new(5) { |index| (201 + index).to_u64 }

      CrystalClick::CompactPartWriter.write_uint64_columns(
        compact_path,
        "pk",
        keys,
        [CrystalClick::CompactPartColumn.binary_bulk("value", type, granules)],
        rows_per_mark: 2,
        frame_bytes: 32,
      )
      reader = CrystalClick::CompactBinaryBulkColumnReader.open(compact_path, "value", type)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_marks(2, 1).flatten.map(&.as_uint64).should eq([55_u64])
      reader.read_marks(3, 0).should be_empty

      CrystalClick::WidePartWriter.write_uint64_columns(
        wide_path,
        "pk",
        keys,
        [CrystalClick::WidePartColumn.binary_bulk("value", type, granules)],
        rows_per_mark: 2,
        frame_bytes: 32,
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(wide_path)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "preserves a zero-byte nested child lane before the next nonempty column" do
    root = File.tempname("crystal-click-w264-compact-empty-child-")
    part_path = File.join(root, "all_1_1_0")
    begin
      Dir.mkdir(root)
      array_type = CrystalClick::BinaryDataType.array(
        CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("UInt64")),
      )
      uint64_type = CrystalClick::BinaryDataType.primitive("UInt64")
      array_values = [
        [] of UInt64?,
        [] of UInt64?,
        [nil, 7_u64] of UInt64?,
        [] of UInt64?,
      ].map do |items|
        children = items.map do |value|
          if scalar = value
            CrystalClick::BinaryValue.nullable(array_type.child_at(0), CrystalClick::BinaryValue.uint64(scalar))
          else
            CrystalClick::BinaryValue.nullable(array_type.child_at(0))
          end
        end
        CrystalClick::BinaryValue.array(array_type, children)
      end
      following_values = [11_u64, 12_u64, 13_u64, 14_u64].map do |value|
        CrystalClick::BinaryValue.uint64(value)
      end
      keys = Slice(UInt64).new(4) { |index| (301 + index).to_u64 }

      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        "pk",
        keys,
        [
          CrystalClick::CompactPartColumn.binary_bulk("gap", array_type, [array_values[0, 2], array_values[2, 2]]),
          CrystalClick::CompactPartColumn.binary_bulk("after", uint64_type, [following_values[0, 2], following_values[2, 2]]),
        ],
        rows_per_mark: 2,
        frame_bytes: 32,
      )

      table = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["pk", "gap", "after"])
      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      physical.physical_roster.map(&.column_name).should eq(["pk", "gap", "after"])
      callbacks = 0
      gaps = [] of Array(UInt64?)
      following = [] of UInt64
      table.scan_typed do |batch|
        callbacks += 1
        gaps.concat(batch.array_nullable_uint64s_for("gap"))
        following.concat(batch.values_for("after"))
      end
      callbacks.should eq(2)
      gaps.should eq([[] of UInt64?, [] of UInt64?, [nil, 7_u64] of UInt64?, [] of UInt64?])
      following.should eq([11_u64, 12_u64, 13_u64, 14_u64])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "detaches the public static-input bridge from caller and bridge container mutation" do
    parent = File.tempname("crystal-click-w264-compact-input-alias-")
    begin
      Dir.mkdir(parent)
      target = File.join(parent, "all_1_1_0")
      type = CrystalClick::BinaryDataType.primitive("UInt64")
      first = [10_u64, 20_u64].map { |value| CrystalClick::BinaryValue.uint64(value) }
      second = [30_u64, 40_u64].map { |value| CrystalClick::BinaryValue.uint64(value) }
      caller_granules = [first, second]
      column = CrystalClick::CompactPartColumn.binary_bulk("value", type, caller_granules)

      # The public factory already detaches the original caller's row and
      # outer containers.
      first[0] = CrystalClick::BinaryValue.uint64(901_u64)
      caller_granules.pop
      initial_bridge = column.static_input
      initial_bridge.granules.size.should eq(2)
      initial_bridge.granules.map(&.size).should eq([2, 2])
      initial_bridge.granules.flatten.map(&.as_uint64).should eq([10_u64, 20_u64, 30_u64, 40_u64])

      # The low-level bridge is public, so its mutable containers must not
      # become a back door into the column's retained input snapshot.
      exposed = column.static_input.granules
      exposed[0][0] = CrystalClick::BinaryValue.uint64(902_u64)
      exposed.pop
      fresh_bridge = column.static_input
      row_entry_retained = fresh_bridge.granules[0][0].as_uint64 == 10_u64
      outer_grid_retained = fresh_bridge.granules.size == 2 && fresh_bridge.granules.map(&.size) == [2, 2]
      {row_entry_retained, outer_grid_retained}.should eq({true, true})

      CompactPartWriterW264GuardFixture.write(
        target,
        "pk",
        [1_u64, 2_u64, 3_u64, 4_u64],
        [column],
        rows_per_mark: 2,
      )
      reader = CrystalClick::CompactBinaryBulkColumnReader.open(target, "value", type)
      reader.mark_count.should eq(2)
      reader.mark_row_counts.should eq([2_u64, 2_u64])
      reader.read_marks(0, 2).flatten.map(&.as_uint64).should eq([10_u64, 20_u64, 30_u64, 40_u64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects duplicate declarations, invalid names, key and grid mismatches, and unordered keys before staging" do
    parent = File.tempname("crystal-click-w264-compact-input-guards-")
    begin
      Dir.mkdir(parent)
      keys = [1_u64, 2_u64]
      one_value = CompactPartWriterW264GuardFixture.uint64_column("value", [10_u64, 20_u64])

      expect_raises(ArgumentError) do
        CompactPartWriterW264GuardFixture.write(
          File.join(parent, "bad-key-name"), "bad-key", keys, [one_value]
        )
      end
      Dir.children(parent).should be_empty

      expect_raises(ArgumentError) do
        CompactPartWriterW264GuardFixture.write(
          File.join(parent, "key-collision"), "pk", keys,
          [CompactPartWriterW264GuardFixture.uint64_column("pk", [10_u64, 20_u64])],
        )
      end
      Dir.children(parent).should be_empty

      expect_raises(ArgumentError) do
        CompactPartWriterW264GuardFixture.write(
          File.join(parent, "duplicate-name"), "pk", keys,
          [
            CompactPartWriterW264GuardFixture.uint64_column("same", [10_u64, 20_u64]),
            CompactPartWriterW264GuardFixture.uint64_column("same", [30_u64, 40_u64]),
          ],
        )
      end
      Dir.children(parent).should be_empty

      expect_raises(ArgumentError) do
        CompactPartWriterW264GuardFixture.write(
          File.join(parent, "mismatched-grid"), "pk", keys,
          [CompactPartWriterW264GuardFixture.uint64_column("value", [10_u64, 20_u64, 30_u64])],
        )
      end
      Dir.children(parent).should be_empty

      expect_raises(ArgumentError) do
        CompactPartWriterW264GuardFixture.write(
          File.join(parent, "mismatched-rows"), "pk", keys,
          [CompactPartWriterW264GuardFixture.uint64_column("value", [10_u64])],
        )
      end
      Dir.children(parent).should be_empty

      expect_raises(ArgumentError) do
        CompactPartWriterW264GuardFixture.write(
          File.join(parent, "unsorted-key"), "pk", [2_u64, 1_u64], [one_value]
        )
      end
      Dir.children(parent).should be_empty

      expect_raises(ArgumentError) do
        CompactPartWriterW264GuardFixture.write(
          File.join(parent, "empty-key"), "pk", [] of UInt64, [one_value]
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "enforces the column-name boundary and refuses stateful Compact types" do
    parent = File.tempname("crystal-click-w264-compact-type-guards-")
    begin
      Dir.mkdir(parent)
      u64 = CrystalClick::BinaryDataType.primitive("UInt64")
      keys = [1_u64, 2_u64]
      max_name = "x" * CrystalClick::WidePartTable::MAX_COLUMN_NAME_BYTES
      boundary_path = File.join(parent, "name-boundary")
      boundary_column = CrystalClick::CompactPartColumn.binary_bulk(
        max_name,
        u64,
        [[CrystalClick::BinaryValue.uint64(11_u64), CrystalClick::BinaryValue.uint64(22_u64)]],
      )
      CompactPartWriterW264GuardFixture.write(boundary_path, "pk", keys, [boundary_column])
      physical = CrystalClick::CompactPartPhysicalContext.open(boundary_path)
      physical.columns.should contain({max_name, "UInt64"})
      reader = CrystalClick::CompactBinaryBulkColumnReader.open(boundary_path, max_name, u64)
      reader.read_marks(0, 1).flatten.map(&.as_uint64).should eq([11_u64, 22_u64])

      too_long_name = "x" * (CrystalClick::WidePartTable::MAX_COLUMN_NAME_BYTES + 1)
      too_long_path = File.join(parent, "name-too-long")
      too_long_column = CrystalClick::CompactPartColumn.binary_bulk(
        too_long_name,
        u64,
        [[CrystalClick::BinaryValue.uint64(11_u64), CrystalClick::BinaryValue.uint64(22_u64)]],
      )
      expect_raises(ArgumentError) do
        CompactPartWriterW264GuardFixture.write(too_long_path, "pk", keys, [too_long_column])
      end
      File.exists?(too_long_path).should be_false

      string = CrystalClick::BinaryDataType.primitive("String")
      low_cardinality = CrystalClick::BinaryDataType.low_cardinality(string)
      low_cardinality_values = ["a", "b"].map do |value|
        CrystalClick::BinaryValue.low_cardinality(low_cardinality, CrystalClick::BinaryValue.string(value))
      end
      variant = CrystalClick::BinaryDataType.variant([u64, string] of CrystalClick::BinaryDataType)
      variant_child = if variant.child_at(0).tag == CrystalClick::BinaryDataType::TAG_STRING
                        CrystalClick::BinaryValue.string("variant")
                      else
                        CrystalClick::BinaryValue.uint64(7_u64)
                      end
      variant_values = Array(CrystalClick::BinaryValue).new(2) do
        CrystalClick::BinaryValue.variant(variant, 0, variant_child)
      end
      dynamic = CrystalClick::BinaryDataType.dynamic(1)
      dynamic_values = [
        CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(1_u64)),
        CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(2_u64)),
      ]

      [
        {"lc", low_cardinality, low_cardinality_values},
        {"variant", variant, variant_values},
        {"dynamic", dynamic, dynamic_values},
      ].each do |name, type, values|
        target = File.join(parent, name)
        column = CrystalClick::CompactPartColumn.binary_bulk(name, type, [values])
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CompactPartWriterW264GuardFixture.write(target, "pk", keys, [column])
        end
        File.exists?(target).should be_false
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves exact Map(String, UInt64) carrier rows and rejects neighboring declarations" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    map_type = CrystalClick::BinaryDataType.map(string, uint64)
    binary_key = String.new(Bytes[0_u8, 255_u8, 128_u8, 65_u8])
    rows = [
      [] of Tuple(String, UInt64),
      [
        {"duplicate", 11_u64},
        {"duplicate", UInt64::MAX},
        {binary_key, 42_u64},
      ] of Tuple(String, UInt64),
      [{"tail", 0_u64}] of Tuple(String, UInt64),
    ]
    values = rows.map do |row|
      children = [] of CrystalClick::BinaryValue
      row.each do |key, value|
        children << CrystalClick::BinaryValue.string(key)
        children << CrystalClick::BinaryValue.uint64(value)
      end
      CrystalClick::BinaryValue.map(map_type, children)
    end
    value_slice = Slice.new(values.to_unsafe, values.size)
    batch = w264_typed_batch_for(map_type, rows.size.to_u64)

    CrystalClick::BinaryValueTypedBatchAdapter.admitted?(map_type).should be_true
    CrystalClick::BinaryValueTypedBatchAdapter.install(batch, "payload", map_type, value_slice, rows.size)
    carrier = batch.map_string_uint64s_for("payload")
    carrier.to_a.should eq(rows)
    carrier[0].should be_empty
    carrier[1].map { |entry| entry[0] }.should eq(["duplicate", "duplicate", binary_key])
    carrier[1][1][1].should eq(UInt64::MAX)
    carrier[1][2][0].to_slice.to_a.should eq(Bytes[0_u8, 255_u8, 128_u8, 65_u8].to_a)

    wrong_rows = w264_typed_batch_for(map_type, rows.size.to_u64)
    expect_raises(CrystalClick::CorruptPartError, /row count mismatch/) do
      CrystalClick::BinaryValueTypedBatchAdapter.install(
        wrong_rows,
        "payload",
        map_type,
        value_slice,
        (rows.size + 1).to_i32,
      )
    end
    expect_raises(CrystalClick::CorruptPartError, /row count mismatch/) do
      wrong_rows.install_compact_map_string_uint64_values("payload", carrier, (rows.size + 1).to_i32)
    end

    uint32 = CrystalClick::BinaryDataType.primitive("UInt32")
    neighboring_map = CrystalClick::BinaryDataType.map(string, uint32)
    CrystalClick::BinaryValueTypedBatchAdapter.admitted?(neighboring_map).should be_false
    CrystalClick::WidePart.supports_typed_type?(neighboring_map.name).should be_true
    wrong_declaration = w264_typed_batch_for(neighboring_map, rows.size.to_u64)
    expect_raises(CrystalClick::CorruptPartError, /descriptor differs/) do
      CrystalClick::BinaryValueTypedBatchAdapter.install(
        wrong_declaration,
        "payload",
        map_type,
        value_slice,
        rows.size,
      )
    end
    expect_raises(CrystalClick::CorruptPartError, /unsupported declaration/) do
      wrong_declaration.install_compact_map_string_uint64_values("payload", carrier, rows.size.to_i32)
    end
  end

  it "rejects stateless Array(UInt64) before Compact staging without an exact carrier" do
    parent = File.tempname("crystal-click-w264-compact-array-u64-guard-")
    begin
      Dir.mkdir(parent)
      uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
      array_type = CrystalClick::BinaryDataType.array(uint64)
      array_values = [
        CrystalClick::BinaryValue.array(array_type, [
          CrystalClick::BinaryValue.uint64(10_u64),
          CrystalClick::BinaryValue.uint64(20_u64),
        ] of CrystalClick::BinaryValue),
        CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue
      column = CrystalClick::CompactPartColumn.binary_bulk("array", array_type, [array_values])
      target = File.join(parent, "all_1_1_0")

      CrystalClick::BinaryValueTypedBatchAdapter.admitted?(array_type).should be_false
      expect_raises(CrystalClick::UnsupportedFormatError, /no established typed batch carrier/) do
        CompactPartWriterW264GuardFixture.write(target, "pk", [1_u64, 2_u64], [column])
      end
      File.exists?(target).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a codec cap and shared multi-column raw-tape cap before staging" do
    parent = File.tempname("crystal-click-w264-compact-budget-guards-")
    begin
      Dir.mkdir(parent)
      keys = [1_u64, 2_u64]
      long_string = "s" * 1_024
      string_type = CrystalClick::BinaryDataType.primitive("String")
      string_column = CrystalClick::CompactPartColumn.binary_bulk(
        "payload",
        string_type,
        [[CrystalClick::BinaryValue.string(long_string), CrystalClick::BinaryValue.string(long_string)]],
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CompactPartWriterW264GuardFixture.write(
          File.join(parent, "codec-limit"), "pk", keys, [string_column],
          limits: CrystalClick::BinaryCodecLimits.new(64, 4_096, 1_000, 512),
        )
      end
      Dir.children(parent).should be_empty

      # Each UInt64 stream has only 16 raw bytes, but the shared key + two
      # value-column tape is 48 bytes and therefore exceeds this 40-byte cap.
      first = CompactPartWriterW264GuardFixture.uint64_column("first", [10_u64, 20_u64])
      second = CompactPartWriterW264GuardFixture.uint64_column("second", [30_u64, 40_u64])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CompactPartWriterW264GuardFixture.write(
          File.join(parent, "shared-raw-limit"), "pk", keys, [first, second],
          transport_limits: CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: 40),
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "cleans its owned stage after staged readback exhausts the reader budget" do
    parent = File.tempname("crystal-click-w264-compact-readback-budget-")
    begin
      Dir.mkdir(parent)
      sentinel = File.join(parent, "keep.txt")
      File.write(sentinel, "unrelated")
      target = File.join(parent, "all_1_1_0")
      value = CompactPartWriterW264GuardFixture.uint64_column("value", [10_u64, 20_u64])

      expect_raises(CrystalClick::CorruptPartError) do
        CompactPartWriterW264GuardFixture.write(
          target,
          "pk",
          [1_u64, 2_u64],
          [value],
          reader_limits: CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: 0),
        )
      end

      File.read(sentinel).should eq("unrelated")
      File.exists?(target).should be_false
      Dir.children(parent).sort.should eq(["keep.txt"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "charges staged readback transient workspace on top of retained reader owners" do
    parent = File.tempname("crystal-click-w264-compact-observer-budget-")
    begin
      Dir.mkdir(parent)
      reference = File.join(parent, "reference")
      target = File.join(parent, "limited")
      column = CompactPartWriterW264GuardFixture.uint64_column("value", [10_u64, 20_u64])

      CrystalClick::CompactBinaryBulkColumnReader.w264_workspace_probe_events =
        [] of Tuple(String, Int32, Int32, UInt64, Int64)
      CrystalClick::CompactBinaryBulkColumnReader.w264_workspace_probe_parent = File.expand_path(parent)
      CrystalClick::CompactBinaryBulkColumnReader.w264_workspace_probe_column = "pk"
      CrystalClick::CompactPartPhysicalContext.w264_window_probe_parent = File.expand_path(parent)
      CrystalClick::CompactPartPhysicalContext.w264_window_probe_column = "pk"
      CrystalClick::CompactPartPhysicalContext.w264_window_probe_calls = 0
      CrystalClick::CompactBinaryBulkColumnReader.w264_workspace_probe_enabled = true
      CrystalClick::CompactPartPhysicalContext.w264_window_probe_enabled = true
      begin
        CompactPartWriterW264GuardFixture.write(reference, "pk", [1_u64, 2_u64], [column])
      ensure
        CrystalClick::CompactBinaryBulkColumnReader.w264_workspace_probe_enabled = false
        CrystalClick::CompactPartPhysicalContext.w264_window_probe_enabled = false
      end

      reference_events = CrystalClick::CompactBinaryBulkColumnReader.w264_workspace_probe_events
        .select { |event| event[0] == "pk" && event[1] == 0 && event[2] == 1 }
      reference_events.size.should be >= 2
      CrystalClick::CompactPartPhysicalContext.w264_window_probe_calls.should be > 0

      target_index = 1
      logical_event = reference_events[0]
      selected = reference_events[target_index]
      logical_required = logical_event[4] + logical_event[3].to_i64
      selected[3].should be > 0_u64
      full_required = selected[4] + selected[3].to_i64
      full_required.should be > selected[4]
      result_limit = selected[4] + (selected[3] // 2).to_i64
      result_limit.should be >= selected[4]
      logical_required.should be <= result_limit
      full_required.should be > result_limit
      selected[1].should eq(0)
      selected[2].should eq(1)

      CrystalClick::CompactBinaryBulkColumnReader.w264_workspace_probe_events =
        [] of Tuple(String, Int32, Int32, UInt64, Int64)
      CrystalClick::CompactPartPhysicalContext.w264_window_probe_calls = 0
      CrystalClick::CompactBinaryBulkColumnReader.w264_workspace_probe_enabled = true
      CrystalClick::CompactPartPhysicalContext.w264_window_probe_enabled = true
      begin
        expect_raises(CrystalClick::CorruptPartError, /result-byte limit exceeded/) do
          CompactPartWriterW264GuardFixture.write(
            target,
            "pk",
            [1_u64, 2_u64],
            [column],
            reader_limits: CrystalClick::CompressedStreamLimits.new(max_result_bytes: result_limit),
          )
        end
      ensure
        CrystalClick::CompactBinaryBulkColumnReader.w264_workspace_probe_enabled = false
        CrystalClick::CompactPartPhysicalContext.w264_window_probe_enabled = false
        CrystalClick::CompactBinaryBulkColumnReader.w264_workspace_probe_parent = ""
        CrystalClick::CompactPartPhysicalContext.w264_window_probe_parent = ""
      end

      limited_events = CrystalClick::CompactBinaryBulkColumnReader.w264_workspace_probe_events
        .select { |event| event[0] == "pk" && event[1] == 0 && event[2] == 1 }
      limited_events.size.should eq(target_index + 1)
      limited_events[0][3].should eq(reference_events[0][3])
      limited_events[1][3].should eq(reference_events[1][3])
      (limited_events[0][4] + limited_events[0][3].to_i64).should be <= result_limit
      (limited_events[1][4] + limited_events[1][3].to_i64).should be > result_limit
      CrystalClick::CompactPartPhysicalContext.w264_window_probe_calls.should eq(0)
      File.exists?(target).should be_false
      Dir.children(parent).sort.should eq(["reference"])
    ensure
      CrystalClick::CompactBinaryBulkColumnReader.w264_workspace_probe_enabled = false
      CrystalClick::CompactBinaryBulkColumnReader.w264_workspace_probe_parent = ""
      CrystalClick::CompactPartPhysicalContext.w264_window_probe_enabled = false
      CrystalClick::CompactPartPhysicalContext.w264_window_probe_parent = ""
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves an existing destination and a dangling destination symlink" do
    parent = File.tempname("crystal-click-w264-compact-destination-guards-")
    begin
      Dir.mkdir(parent)
      existing = File.join(parent, "existing")
      Dir.mkdir(existing)
      marker = File.join(existing, "keep.txt")
      File.write(marker, "existing bytes")
      dangling = File.join(parent, "dangling")
      File.symlink(File.join(parent, "missing-target"), dangling)
      column = CompactPartWriterW264GuardFixture.uint64_column("value", [10_u64, 20_u64])

      expect_raises(ArgumentError) do
        CompactPartWriterW264GuardFixture.write(existing, "pk", [1_u64, 2_u64], [column])
      end
      expect_raises(ArgumentError) do
        CompactPartWriterW264GuardFixture.write(dangling, "pk", [1_u64, 2_u64], [column])
      end

      File.read(marker).should eq("existing bytes")
      File.symlink?(dangling).should be_true
      Dir.children(parent).sort.should eq(["dangling", "existing"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "refuses a read result cap below the persisted mark grid before opening that grid" do
    parent = File.tempname("crystal-click-w264-compact-grid-result-cap-")
    begin
      Dir.mkdir(parent)
      row_count = 64
      keys = Array(UInt64).new(row_count) { |index| (index + 1).to_u64 }
      values = Array(UInt64).new(row_count) { |index| (10_000 + index).to_u64 }
      column = CompactPartWriterW264GuardFixture.uint64_column("value", values, 1)
      result_limit = 2_500

      # A separate unrestricted write proves this is a valid 64-mark,
      # multiframe Compact grid and calibrates the cap against its full
      # retained coordinate/row/frame index rather than a guessed byte count.
      reference = File.join(parent, "reference")
      CompactPartWriterW264GuardFixture.write(
        reference,
        "pk",
        keys,
        [column],
        rows_per_mark: 1,
        frame_bytes: 32,
      )
      physical = CrystalClick::CompactPartPhysicalContext.open(reference)
      physical.mode.should eq(CrystalClick::CompactMarkFormat::Mrk3)
      physical.row_count.should eq(row_count.to_u64)
      physical.granule_count.should eq(row_count)
      physical.retained_grid_workspace_bytes.should be > result_limit.to_u64
      File.size(File.join(reference, "data.mrk3")).should eq((row_count + 1).to_i64 * 40_i64)

      data_text = File.read(File.join(reference, "data.bin"))
      frame_index = CrystalClick::CompressedFrameIndex.new(
        data_text.to_slice,
        CrystalClick::CompressedStreamLimits.new,
        CrystalClick::CompressedStreamBudget.read_default,
      )
      frame_index.frames.size.should eq(row_count)
      frame_index.logical_size.should eq((row_count * 16).to_i64)

      metadata_names = [
        "columns.txt",
        "count.txt",
        "serialization.json",
        "default_compression_codec.txt",
        "metadata_version.txt",
        "checksums.txt",
      ]
      metadata_result_bytes = 0_i64
      metadata_names.each do |name|
        metadata_result_bytes += File.size(File.join(reference, name))
      end
      primary_index_result_bytes = (row_count + 1).to_i64 * sizeof(UInt64).to_i64 * 2_i64
      metadata_result_bytes.should be < 2_048_i64
      (metadata_result_bytes + primary_index_result_bytes).should be < result_limit.to_i64

      target = File.join(parent, "limited")
      reader_limits = CrystalClick::CompressedStreamLimits.new(max_result_bytes: result_limit)
      CrystalClick::CompactMarkIndex.w264_grid_guard_probe_calls = 0
      CrystalClick::CompactMarkIndex.w264_grid_guard_probe_parent = File.expand_path(parent)
      CrystalClick::CompactMarkIndex.w264_grid_guard_probe_enabled = true
      failure = nil.as(Exception?)
      begin
        CompactPartWriterW264GuardFixture.write(
          target,
          "pk",
          keys,
          [column],
          rows_per_mark: 1,
          frame_bytes: 32,
          reader_limits: reader_limits,
        )
      rescue ex : CrystalClick::CorruptPartError | CrystalClick::UnsupportedFormatError
        failure = ex
      ensure
        CrystalClick::CompactMarkIndex.w264_grid_guard_probe_enabled = false
        CrystalClick::CompactMarkIndex.w264_grid_guard_probe_parent = ""
      end

      CrystalClick::CompactMarkIndex.w264_grid_guard_probe_calls.should eq(0)
      failure.should be_a(CrystalClick::CorruptPartError)
      File.exists?(target).should be_false
      Dir.children(parent).sort.should eq(["reference"])
    ensure
      CrystalClick::CompactMarkIndex.w264_grid_guard_probe_enabled = false
      CrystalClick::CompactMarkIndex.w264_grid_guard_probe_parent = ""
      FileUtils.rm_rf(parent)
    end
  end
end
