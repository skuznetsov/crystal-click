require "file_utils"
require "./spec_helper"

W50_TIME_FIXTURE = File.expand_path("../test/fixtures/public/wide_time_w50/part", __DIR__)

W50_KEYS                  = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W50_RANGE_INDEXES         = [1, 2, 3, 4, 5]
W50_TIME_SECONDS          = [-3723_i32, 0_i32, 1_i32, 59_i32, 60_i32, 52_225_i32, -1_i32]
W50_NULLABLE_TIME_SECONDS = [nil, -3723_i32.as(Int32?), 0_i32, 1_i32, nil, 3600_i32, -1_i32] of Int32?
W50_ARRAY_TIME_SECONDS    = [
  [] of Int32,
  [-1_i32, 0_i32, 1_i32],
  [52_225_i32],
  [] of Int32,
  [-2_i32, 59_i32],
  [3600_i32],
  [] of Int32,
] of Array(Int32)
W50_ARRAY_NULLABLE_TIME_SECONDS = [
  [] of Int32?,
  [nil, -1_i32.as(Int32?), 0_i32] of Int32?,
  [nil, nil] of Int32?,
  [] of Int32?,
  [59_i32.as(Int32?)],
  [nil, 1_i32.as(Int32?), nil] of Int32?,
  [] of Int32?,
] of Array(Int32?)

W50_TIME64_0_TICKS = [-1_i64, 0_i64, 1_i64, 59_i64, 3600_i64, 3600_i64, -3723_i64]
W50_TIME64_3_TICKS = [-1234_i64, 0_i64, 1234_i64, -1_i64, 59_123_i64, 3_600_999_i64, -3_723_456_i64]
W50_TIME64_9_TICKS = [
  -1_234_567_891_i64, 0_i64, 1_234_567_891_i64, -1_i64,
  59_123_456_789_i64, 3_600_999_999_999_i64, -3_723_456_789_123_i64,
]
W50_NULLABLE_TIME64_3_TICKS = [nil, -1234_i64.as(Int64?), 0_i64, 1234_i64, nil, 3_600_999_i64, -3_723_456_i64] of Int64?
W50_ARRAY_TIME64_3_TICKS    = [
  [] of Int64,
  [-1234_i64, 1_i64, 1234_i64],
  [59_123_i64],
  [] of Int64,
  [-1_i64, 0_i64],
  [1234_i64],
  [] of Int64,
] of Array(Int64)
W50_ARRAY_NULLABLE_TIME64_3_TICKS = [
  [] of Int64?,
  [nil, -1234_i64.as(Int64?), 1_i64] of Int64?,
  [nil, nil] of Int64?,
  [] of Int64?,
  [59_123_i64.as(Int64?)],
  [nil, 1234_i64.as(Int64?), nil] of Int64?,
  [] of Int64?,
] of Array(Int64?)

private def with_w50_selected_part(& : String ->)
  root = File.tempname("crystal-click-w50-selected-part")
  Dir.mkdir(root)
  begin
    selected = File.join(root, "all_1_1_0")
    FileUtils.cp_r(W50_TIME_FIXTURE, selected)
    yield selected
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w50_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def with_w50_catalog_root(& : String ->)
  root = File.tempname("crystal-click-w50-offline-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    File.write(
      File.join(root, "metadata", "lab.sql"),
      "ATTACH DATABASE _ UUID 'f462f136-3924-4f43-b278-28c181075a54'\nENGINE = Atomic\n"
    )
    database_path = w50_store_path(root, "f462f136-3924-4f43-b278-28c181075a54")
    table_path = w50_store_path(root, "a78f7c0e-b304-41f4-a947-4f51e22dc6f1")
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID 'a78f7c0e-b304-41f4-a947-4f51e22dc6f1'\n(\n" +
      "    `pk` UInt64,\n    `t` Time,\n    `nt` Nullable(Time),\n" +
      "    `a` Array(Time),\n    `an` Array(Nullable(Time)),\n" +
      "    `t64_0` Time64(0),\n    `t64_3` Time64(3),\n    `t64_9` Time64(9),\n" +
      "    `nt64_3` Nullable(Time64(3)),\n    `a64_3` Array(Time64(3)),\n" +
      "    `an64_3` Array(Nullable(Time64(3)))\n)\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W50_TIME_FIXTURE, File.join(table_path, "all_1_1_0"))
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::WidePart do
  it "admits W50 Time and Time64 compositions without changing existing type admission" do
    {
      "Time",
      "Nullable(Time)",
      "Array(Time)",
      "Array(Nullable(Time))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end

    (0..9).each do |scale|
      {
        "Time64(#{scale})",
        "Nullable(Time64(#{scale}))",
        "Array(Time64(#{scale}))",
        "Array(Nullable(Time64(#{scale})))",
      }.each do |type|
        CrystalClick::WidePart.supports_typed_type?(type).should be_true
      end
    end

    # These pre-existing types have independent readers. Time's Int32 physical
    # carrier must not replace the logical type gate.
    {
      "Int32",
      "Int64",
      "DateTime",
      "DateTime64(3)",
      "Nullable(Int32)",
      "Nullable(Int64)",
      "Nullable(DateTime)",
      "Nullable(DateTime64(3))",
      "Array(Int32)",
      "Array(Int64)",
      "Array(DateTime)",
      "Array(DateTime64(3))",
      "Array(Nullable(Int32))",
      "Array(Nullable(Int64))",
      "Array(Nullable(DateTime))",
      "Array(Nullable(DateTime64(3)))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end

    {
      "Time64",
      "Time64(-1)",
      "Time64(03)",
      "Time64(10)",
      "Time64(3, 'UTC')",
      "Nullable(Nullable(Time))",
      "Array(Array(Time))",
      "Array(Nullable(Nullable(Time)))",
      "Nullable(Array(Time))",
      "Nullable(Nullable(Time64(3)))",
      "Array(Array(Time64(3)))",
      "Array(Nullable(Nullable(Time64(3))))",
      "Nullable(Array(Time64(3)))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads the eight exact W50 shapes with signed values and precision-preserving ticks" do
    time = CrystalClick::WidePart.open_typed(W50_TIME_FIXTURE, "t")
    nullable_time = CrystalClick::WidePart.open_typed(W50_TIME_FIXTURE, "nt")
    array_time = CrystalClick::WidePart.open_typed(W50_TIME_FIXTURE, "a")
    array_nullable_time = CrystalClick::WidePart.open_typed(W50_TIME_FIXTURE, "an")
    time64_0 = CrystalClick::WidePart.open_typed(W50_TIME_FIXTURE, "t64_0")
    time64_3 = CrystalClick::WidePart.open_typed(W50_TIME_FIXTURE, "t64_3")
    time64_9 = CrystalClick::WidePart.open_typed(W50_TIME_FIXTURE, "t64_9")
    nullable_time64_3 = CrystalClick::WidePart.open_typed(W50_TIME_FIXTURE, "nt64_3")
    array_time64_3 = CrystalClick::WidePart.open_typed(W50_TIME_FIXTURE, "a64_3")
    array_nullable_time64_3 = CrystalClick::WidePart.open_typed(W50_TIME_FIXTURE, "an64_3")

    time.read_time_seconds_mark_range("t", 0, time.mark_count).should eq(W50_TIME_SECONDS)
    nullable_time.read_nullable_time_seconds_mark_range("nt", 0, nullable_time.mark_count).should eq(W50_NULLABLE_TIME_SECONDS)
    array_time.read_array_time_seconds_mark_range("a", 0, array_time.mark_count).should eq(W50_ARRAY_TIME_SECONDS)
    array_nullable_time.read_array_nullable_time_seconds_mark_range("an", 0, array_nullable_time.mark_count).should eq(W50_ARRAY_NULLABLE_TIME_SECONDS)
    time64_0.read_time64_ticks_mark_range("t64_0", 0, time64_0.mark_count).should eq(W50_TIME64_0_TICKS)
    time64_3.read_time64_ticks_mark_range("t64_3", 0, time64_3.mark_count).should eq(W50_TIME64_3_TICKS)
    time64_9.read_time64_ticks_mark_range("t64_9", 0, time64_9.mark_count).should eq(W50_TIME64_9_TICKS)
    nullable_time64_3.read_nullable_time64_ticks_mark_range("nt64_3", 0, nullable_time64_3.mark_count).should eq(W50_NULLABLE_TIME64_3_TICKS)
    array_time64_3.read_array_time64_ticks_mark_range("a64_3", 0, array_time64_3.mark_count).should eq(W50_ARRAY_TIME64_3_TICKS)
    array_nullable_time64_3.read_array_nullable_time64_ticks_mark_range("an64_3", 0, array_nullable_time64_3.mark_count).should eq(W50_ARRAY_NULLABLE_TIME64_3_TICKS)

    # Mark 1 covers keys 4 and 6; mark 2 covers keys 9 and 11.
    time.read_time_seconds_mark_range("t", 1, 2).should eq(W50_TIME_SECONDS[2, 4])
    array_nullable_time64_3.read_array_nullable_time64_ticks_mark_range("an64_3", 1, 2)
      .should eq(W50_ARRAY_NULLABLE_TIME64_3_TICKS[2, 4])
  end

  it "does not treat same-width Int32 or Int64 metadata as Time or Time64" do
    parent = File.tempname("crystal-click-w50-logical-type-gate")
    Dir.mkdir(parent)
    begin
      keys = [1_u64]
      seconds = [1_i32]
      ticks = [1_i64]
      array_ticks = [[1_i64]]
      nullable_array_ticks = [[1_i64.as(Int64?)]]

      parts = [
        {CrystalClick::WidePartWriter.write_uint64_time_pair(
          File.join(parent, "time"), "pk", keys.to_unsafe.to_slice(1), "payload", seconds.to_unsafe.to_slice(1), 1
        ), "`payload` Time", "`payload` Int32", "payload", 0},
        {CrystalClick::WidePartWriter.write_uint64_time64_pair(
          File.join(parent, "time64"), "pk", keys.to_unsafe.to_slice(1), "payload", ticks.to_unsafe.to_slice(1), 0, 1
        ), "`payload` Time64(0)", "`payload` Int64", "payload", 1},
        {CrystalClick::WidePartWriter.write_uint64_array_time64_pair(
          File.join(parent, "array-time64"), "pk", keys.to_unsafe.to_slice(1), "payload", array_ticks.to_unsafe.to_slice(1), 3, 1
        ), "`payload` Array(Time64(3))", "`payload` Array(DateTime64(3))", "payload", 2},
        {CrystalClick::WidePartWriter.write_uint64_array_nullable_time64_pair(
          File.join(parent, "array-nullable-time64"), "pk", keys.to_unsafe.to_slice(1), "payload", nullable_array_ticks.to_unsafe.to_slice(1), 3, 1
        ), "`payload` Array(Nullable(Time64(3)))", "`payload` Array(Nullable(DateTime64(3)))", "payload", 3},
      ]

      parts.each do |(mutated_part, canonical, carrier, column, accessor)|
        columns_path = File.join(mutated_part, "columns.txt")
        original = File.read(columns_path)
        mutated = original.sub(canonical, carrier)
        mutated.should_not eq(original)
        File.write(columns_path, mutated)
        reader = CrystalClick::WidePart.open_typed(mutated_part, column)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          case accessor
          when 0
            reader.read_time_seconds_mark_range(column, 0, 1)
          when 1
            reader.read_time64_ticks_mark_range(column, 0, 1)
          when 2
            reader.read_array_time64_ticks_mark_range(column, 0, 1)
          when 3
            reader.read_array_nullable_time64_ticks_mark_range(column, 0, 1)
          else
            raise "unhandled W50 accessor"
          end
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps the W50 empty-serializer admission exception bound to its exact schema" do
    with_w50_selected_part do |part|
      columns_path = File.join(part, "columns.txt")
      original = File.read(columns_path)
      mutated = original.sub("`t64_0` Time64(0)", "`t64_0` Int64")
      mutated.should_not eq(original)
      File.write(columns_path, mutated)

      # The mutation is in an unselected column. Rejection here must come from
      # the deliberate exact multi-column W50 layout guard, not a Time accessor.
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part, "a")
      end
    end
  end
end

describe CrystalClick::WidePartTable do
  it "dispatches all W50 shapes in two-row typed batches and preserves exact key filtering" do
    with_w50_selected_part do |part|
      columns = [
        "pk", "t", "nt", "a", "an", "t64_0", "t64_3", "t64_9", "nt64_3", "a64_3", "an64_3",
      ]
      table = CrystalClick::WidePartTable.open_selected_typed([part], columns)
      table.column_types.should eq([
        {"pk", "UInt64"},
        {"t", "Time"},
        {"nt", "Nullable(Time)"},
        {"a", "Array(Time)"},
        {"an", "Array(Nullable(Time))"},
        {"t64_0", "Time64(0)"},
        {"t64_3", "Time64(3)"},
        {"t64_9", "Time64(9)"},
        {"nt64_3", "Nullable(Time64(3))"},
        {"a64_3", "Array(Time64(3))"},
        {"an64_3", "Array(Nullable(Time64(3)))"},
      ])
      table.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64, 1_u64]])

      filtered_keys = [] of UInt64
      filtered_time = [] of Int32
      filtered_nullable_time = [] of Int32?
      filtered_array_time = [] of Array(Int32)
      filtered_array_nullable_time = [] of Array(Int32?)
      filtered_time64_0 = [] of Int64
      filtered_time64_3 = [] of Int64
      filtered_time64_9 = [] of Int64
      filtered_nullable_time64_3 = [] of Int64?
      filtered_array_time64_3 = [] of Array(Int64)
      filtered_array_nullable_time64_3 = [] of Array(Int64?)
      batch_rows = [] of Int32

      table.scan_typed(batch_rows: 2) do |batch|
        keys = batch.values_for("pk", UInt64)
        time = batch.time_seconds_for("t")
        nullable_time = batch.nullable_time_seconds_for("nt")
        array_time = batch.array_time_seconds_for("a")
        array_nullable_time = batch.array_nullable_time_seconds_for("an")
        time64_0 = batch.time64_ticks_for("t64_0")
        time64_3 = batch.time64_ticks_for("t64_3")
        time64_9 = batch.time64_ticks_for("t64_9")
        nullable_time64_3 = batch.nullable_time64_ticks_for("nt64_3")
        array_time64_3 = batch.array_time64_ticks_for("a64_3")
        array_nullable_time64_3 = batch.array_nullable_time64_ticks_for("an64_3")
        batch_rows << keys.size.to_i32

        keys.each_with_index do |key, index|
          next unless key >= 2_u64 && key < 12_u64
          filtered_keys << key
          filtered_time << time[index]
          filtered_nullable_time << nullable_time[index]
          filtered_array_time << array_time[index].dup
          filtered_array_nullable_time << array_nullable_time[index].dup
          filtered_time64_0 << time64_0[index]
          filtered_time64_3 << time64_3[index]
          filtered_time64_9 << time64_9[index]
          filtered_nullable_time64_3 << nullable_time64_3[index]
          filtered_array_time64_3 << array_time64_3[index].dup
          filtered_array_nullable_time64_3 << array_nullable_time64_3[index].dup
        end
      end

      batch_rows.should eq([2, 2, 2, 1])
      filtered_keys.should eq(W50_RANGE_INDEXES.map { |index| W50_KEYS[index] })
      filtered_time.should eq(W50_RANGE_INDEXES.map { |index| W50_TIME_SECONDS[index] })
      filtered_nullable_time.should eq(W50_RANGE_INDEXES.map { |index| W50_NULLABLE_TIME_SECONDS[index] })
      filtered_array_time.should eq(W50_RANGE_INDEXES.map { |index| W50_ARRAY_TIME_SECONDS[index] })
      filtered_array_nullable_time.should eq(W50_RANGE_INDEXES.map { |index| W50_ARRAY_NULLABLE_TIME_SECONDS[index] })
      filtered_time64_0.should eq(W50_RANGE_INDEXES.map { |index| W50_TIME64_0_TICKS[index] })
      filtered_time64_3.should eq(W50_RANGE_INDEXES.map { |index| W50_TIME64_3_TICKS[index] })
      filtered_time64_9.should eq(W50_RANGE_INDEXES.map { |index| W50_TIME64_9_TICKS[index] })
      filtered_nullable_time64_3.should eq(W50_RANGE_INDEXES.map { |index| W50_NULLABLE_TIME64_3_TICKS[index] })
      filtered_array_time64_3.should eq(W50_RANGE_INDEXES.map { |index| W50_ARRAY_TIME64_3_TICKS[index] })
      filtered_array_nullable_time64_3.should eq(W50_RANGE_INDEXES.map { |index| W50_ARRAY_NULLABLE_TIME64_3_TICKS[index] })
    end
  end

  it "routes Time and Time64 through offline typed batches and owned catalog values" do
    with_w50_catalog_root do |root|
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"t", "Time"},
        {"nt", "Nullable(Time)"},
        {"a", "Array(Time)"},
        {"an", "Array(Nullable(Time))"},
        {"t64_0", "Time64(0)"},
        {"t64_3", "Time64(3)"},
        {"t64_9", "Time64(9)"},
        {"nt64_3", "Nullable(Time64(3))"},
        {"a64_3", "Array(Time64(3))"},
        {"an64_3", "Array(Nullable(Time64(3)))"},
      ])

      selected_columns = [
        "pk", "t", "nt", "a", "an", "t64_0", "t64_3", "t64_9", "nt64_3", "a64_3", "an64_3",
      ]
      batch_rows = [] of Int32
      table.scan_typed(selected_columns, batch_rows: 2) do |batch|
        batch_rows << batch.values_for("pk", UInt64).size.to_i32
        batch.column_type_for("t").should eq("Time")
        batch.column_type_for("t64_0").should eq("Time64(0)")
        batch.column_type_for("t64_9").should eq("Time64(9)")
        batch.time_seconds_for("t").size.should eq(batch.values_for("pk", UInt64).size)
        batch.nullable_time_seconds_for("nt").size.should eq(batch.values_for("pk", UInt64).size)
        batch.array_time_seconds_for("a").size.should eq(batch.values_for("pk", UInt64).size)
        batch.array_nullable_time_seconds_for("an").size.should eq(batch.values_for("pk", UInt64).size)
        batch.time64_ticks_for("t64_0").size.should eq(batch.values_for("pk", UInt64).size)
        batch.time64_ticks_for("t64_3").size.should eq(batch.values_for("pk", UInt64).size)
        batch.time64_ticks_for("t64_9").size.should eq(batch.values_for("pk", UInt64).size)
        batch.nullable_time64_ticks_for("nt64_3").size.should eq(batch.values_for("pk", UInt64).size)
        batch.array_time64_ticks_for("a64_3").size.should eq(batch.values_for("pk", UInt64).size)
        batch.array_nullable_time64_ticks_for("an64_3").size.should eq(batch.values_for("pk", UInt64).size)
      end
      batch_rows.should eq([2, 2, 2, 1])

      table["t"].values.map { |value| value.as(Int32) }.should eq(W50_TIME_SECONDS)
      table["nt"].values.map { |value| value.as(Int32?) }.should eq(W50_NULLABLE_TIME_SECONDS)
      table["a"].values.map { |value| value.as(Array(Int32)) }.should eq(W50_ARRAY_TIME_SECONDS)
      table["an"].values.map { |value| value.as(Array(Int32?)) }.should eq(W50_ARRAY_NULLABLE_TIME_SECONDS)
      table["t64_0"].values.map { |value| value.as(Int64) }.should eq(W50_TIME64_0_TICKS)
      table["t64_3"].values.map { |value| value.as(Int64) }.should eq(W50_TIME64_3_TICKS)
      table["t64_9"].values.map { |value| value.as(Int64) }.should eq(W50_TIME64_9_TICKS)
      table["nt64_3"].values.map { |value| value.as(Int64?) }.should eq(W50_NULLABLE_TIME64_3_TICKS)
      table["a64_3"].values.map { |value| value.as(Array(Int64)) }.should eq(W50_ARRAY_TIME64_3_TICKS)
      table["an64_3"].values.map { |value| value.as(Array(Int64?)) }.should eq(W50_ARRAY_NULLABLE_TIME64_3_TICKS)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes exact Time and Time64 scalar, Nullable, and Array shapes across marks" do
    root = File.tempname("crystal-click-w50-writer")
    Dir.mkdir(root)
    begin
      keys = W50_KEYS.to_unsafe.to_slice(W50_KEYS.size)
      parts = [] of {String, String, Array(String), Int32}
      parts << {
        CrystalClick::WidePartWriter.write_uint64_time_pair(
          File.join(root, "time"), "pk", keys, "payload", W50_TIME_SECONDS.to_unsafe.to_slice(W50_TIME_SECONDS.size), 2
        ), "Time", ["payload"], 0,
      }
      parts << {
        CrystalClick::WidePartWriter.write_uint64_nullable_time_pair(
          File.join(root, "nullable-time"), "pk", keys, "payload", W50_NULLABLE_TIME_SECONDS.to_unsafe.to_slice(W50_NULLABLE_TIME_SECONDS.size), 2
        ), "Nullable(Time)", ["payload.null", "payload"], 1,
      }
      parts << {
        CrystalClick::WidePartWriter.write_uint64_array_time_pair(
          File.join(root, "array-time"), "pk", keys, "payload", W50_ARRAY_TIME_SECONDS.to_unsafe.to_slice(W50_ARRAY_TIME_SECONDS.size), 2
        ), "Array(Time)", ["payload.size0", "payload"], 2,
      }
      parts << {
        CrystalClick::WidePartWriter.write_uint64_array_nullable_time_pair(
          File.join(root, "array-nullable-time"), "pk", keys, "payload", W50_ARRAY_NULLABLE_TIME_SECONDS.to_unsafe.to_slice(W50_ARRAY_NULLABLE_TIME_SECONDS.size), 2
        ), "Array(Nullable(Time))", ["payload.size0", "payload.null", "payload"], 3,
      }
      parts << {
        CrystalClick::WidePartWriter.write_uint64_time64_pair(
          File.join(root, "time64-p0"), "pk", keys, "payload", W50_TIME64_0_TICKS.to_unsafe.to_slice(W50_TIME64_0_TICKS.size), 0, 2
        ), "Time64(0)", ["payload"], 4,
      }
      parts << {
        CrystalClick::WidePartWriter.write_uint64_time64_pair(
          File.join(root, "time64-p3"), "pk", keys, "payload", W50_TIME64_3_TICKS.to_unsafe.to_slice(W50_TIME64_3_TICKS.size), 3, 2
        ), "Time64(3)", ["payload"], 5,
      }
      parts << {
        CrystalClick::WidePartWriter.write_uint64_time64_pair(
          File.join(root, "time64-p9"), "pk", keys, "payload", W50_TIME64_9_TICKS.to_unsafe.to_slice(W50_TIME64_9_TICKS.size), 9, 2
        ), "Time64(9)", ["payload"], 6,
      }
      parts << {
        CrystalClick::WidePartWriter.write_uint64_nullable_time64_pair(
          File.join(root, "nullable-time64"), "pk", keys, "payload", W50_NULLABLE_TIME64_3_TICKS.to_unsafe.to_slice(W50_NULLABLE_TIME64_3_TICKS.size), 3, 2
        ), "Nullable(Time64(3))", ["payload.null", "payload"], 7,
      }
      parts << {
        CrystalClick::WidePartWriter.write_uint64_array_time64_pair(
          File.join(root, "array-time64"), "pk", keys, "payload", W50_ARRAY_TIME64_3_TICKS.to_unsafe.to_slice(W50_ARRAY_TIME64_3_TICKS.size), 3, 2
        ), "Array(Time64(3))", ["payload.size0", "payload"], 8,
      }
      parts << {
        CrystalClick::WidePartWriter.write_uint64_array_nullable_time64_pair(
          File.join(root, "array-nullable-time64"), "pk", keys, "payload", W50_ARRAY_NULLABLE_TIME64_3_TICKS.to_unsafe.to_slice(W50_ARRAY_NULLABLE_TIME64_3_TICKS.size), 3, 2
        ), "Array(Nullable(Time64(3)))", ["payload.size0", "payload.null", "payload"], 9,
      }

      parts.each do |(part, type, streams, accessor)|
        reader = CrystalClick::WidePart.open_typed(part, "payload")
        reader.column_type.should eq(type)
        reader.row_count.should eq(7_u64)
        reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
        File.read(File.join(part, "count.txt")).should eq("7")
        File.read(File.join(part, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
        File.read(File.join(part, "serialization.json")).should eq(
          "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}"
        )
        File.read(File.join(part, "columns_substreams.txt")).should eq(
          "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
          "#{streams.size} substreams for column `payload`:\n" + streams.map { |stream| "\t#{stream}\n" }.join
        )

        case accessor
        when 0
          reader.read_time_seconds_mark_range("payload", 0, reader.mark_count).should eq(W50_TIME_SECONDS)
          reader.read_time_seconds_mark_range("payload", 1, 2).should eq(W50_TIME_SECONDS[2, 4])
        when 1
          reader.read_nullable_time_seconds_mark_range("payload", 0, reader.mark_count).should eq(W50_NULLABLE_TIME_SECONDS)
          reader.read_nullable_time_seconds_mark_range("payload", 1, 2).should eq(W50_NULLABLE_TIME_SECONDS[2, 4])
        when 2
          reader.read_array_time_seconds_mark_range("payload", 0, reader.mark_count).should eq(W50_ARRAY_TIME_SECONDS)
          reader.read_array_time_seconds_mark_range("payload", 1, 2).should eq(W50_ARRAY_TIME_SECONDS[2, 4])
        when 3
          reader.read_array_nullable_time_seconds_mark_range("payload", 0, reader.mark_count).should eq(W50_ARRAY_NULLABLE_TIME_SECONDS)
          reader.read_array_nullable_time_seconds_mark_range("payload", 1, 2).should eq(W50_ARRAY_NULLABLE_TIME_SECONDS[2, 4])
        when 4
          reader.read_time64_ticks_mark_range("payload", 0, reader.mark_count).should eq(W50_TIME64_0_TICKS)
          reader.read_time64_ticks_mark_range("payload", 1, 2).should eq(W50_TIME64_0_TICKS[2, 4])
        when 5
          reader.read_time64_ticks_mark_range("payload", 0, reader.mark_count).should eq(W50_TIME64_3_TICKS)
          reader.read_time64_ticks_mark_range("payload", 1, 2).should eq(W50_TIME64_3_TICKS[2, 4])
        when 6
          reader.read_time64_ticks_mark_range("payload", 0, reader.mark_count).should eq(W50_TIME64_9_TICKS)
          reader.read_time64_ticks_mark_range("payload", 1, 2).should eq(W50_TIME64_9_TICKS[2, 4])
        when 7
          reader.read_nullable_time64_ticks_mark_range("payload", 0, reader.mark_count).should eq(W50_NULLABLE_TIME64_3_TICKS)
          reader.read_nullable_time64_ticks_mark_range("payload", 1, 2).should eq(W50_NULLABLE_TIME64_3_TICKS[2, 4])
        when 8
          reader.read_array_time64_ticks_mark_range("payload", 0, reader.mark_count).should eq(W50_ARRAY_TIME64_3_TICKS)
          reader.read_array_time64_ticks_mark_range("payload", 1, 2).should eq(W50_ARRAY_TIME64_3_TICKS[2, 4])
        when 9
          reader.read_array_nullable_time64_ticks_mark_range("payload", 0, reader.mark_count).should eq(W50_ARRAY_NULLABLE_TIME64_3_TICKS)
          reader.read_array_nullable_time64_ticks_mark_range("payload", 1, 2).should eq(W50_ARRAY_NULLABLE_TIME64_3_TICKS[2, 4])
        else
          raise "unhandled W50 writer shape"
        end
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects out-of-range Time64 scales before any typed values or output publication" do
    root = File.tempname("crystal-click-w50-writer-scale")
    Dir.mkdir(root)
    begin
      empty_keys = ([] of UInt64).to_unsafe.to_slice(0)
      empty_i64 = ([] of Int64).to_unsafe.to_slice(0)
      empty_nullable_i64 = ([] of Int64?).to_unsafe.to_slice(0)
      empty_array_i64 = ([] of Array(Int64)).to_unsafe.to_slice(0)
      empty_array_nullable_i64 = ([] of Array(Int64?)).to_unsafe.to_slice(0)

      [-1_i32, 10_i32].each do |scale|
        {"scalar", "nullable", "array", "array-nullable"}.each do |name|
          destination = File.join(root, "#{name}-#{scale}")
          expect_raises(ArgumentError) do
            case name
            when "scalar"
              CrystalClick::WidePartWriter.write_uint64_time64_pair(destination, "pk", empty_keys, "payload", empty_i64, scale, 1)
            when "nullable"
              CrystalClick::WidePartWriter.write_uint64_nullable_time64_pair(destination, "pk", empty_keys, "payload", empty_nullable_i64, scale, 1)
            when "array"
              CrystalClick::WidePartWriter.write_uint64_array_time64_pair(destination, "pk", empty_keys, "payload", empty_array_i64, scale, 1)
            when "array-nullable"
              CrystalClick::WidePartWriter.write_uint64_array_nullable_time64_pair(destination, "pk", empty_keys, "payload", empty_array_nullable_i64, scale, 1)
            end
          end
          File.exists?(destination).should be_false
        end
      end
      Dir.children(root).should be_empty
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
