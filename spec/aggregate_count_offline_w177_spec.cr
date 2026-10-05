require "./spec_helper"

private def w177_offline_count_catalog_table(
  root : String,
  part : String,
  columns : String,
  engine : String = "MergeTree",
  tail : String = "ORDER BY pk",
  with_parts : Bool = true,
) : CrystalClick::OfflineTable
  database_uuid = "b36dd646-a665-4a2b-a64a-79f3c1c52e1a"
  table_uuid = "3ac828c7-0995-4538-8d7c-3d848767f72a"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n#{columns}\n)\nENGINE = #{engine}\n#{tail}\n"
  )
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, "all_1_1_0")) if with_parts
  CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
end

private def with_w177_offline_count_table(
  stock_root : String,
  profile : String,
  columns : String,
  engine : String = "MergeTree",
  tail : String = "ORDER BY pk",
  with_parts : Bool = true,
  & : CrystalClick::OfflineTable ->
) : Nil
  root = File.tempname("crystal-click-w177-offline-count")
  FileUtils.mkdir_p(root)
  begin
    part = File.join(stock_root, "part-#{profile}")
    table = w177_offline_count_catalog_table(root, part, columns, engine, tail, with_parts)
    yield table
  ensure
    FileUtils.rm_rf(root)
  end
  nil
end

describe "W177 offline AggregateFunction(count) consumers" do
  if stock_root = ENV["W177_STOCK_ROOT"]?
    {
      {"none", "AggregateFunction(count)"},
      {"uint64", "AggregateFunction(count, UInt64)"},
      {"nullable", "AggregateFunction(count, Nullable(UInt64))"},
    }.each do |profile, type_name|
      it "preserves nominal #{type_name} states through scans, windows and values" do
        columns = "`pk` UInt64,\n`c` #{type_name}"
        with_w177_offline_count_table(stock_root, profile, columns) do |table|
          expected_type = CrystalClick::WideAggregateCountStoragePlan.for_type_name(type_name).not_nil!.data_type
          expected_counts = [0_u64, 127_u64, 128_u64, 16_384_u64, UInt64::MAX]

          scanned = [] of UInt64
          table.scan_typed(["c"], batch_rows: 2) do |batch|
            states = batch.aggregate_count_states_for("c", expected_type)
            states.each do |state|
              state.type.should eq(expected_type)
              scanned << state.count_state
            end
          end
          scanned.should eq(expected_counts)

          windowed = [] of UInt64
          table.scan_typed_window(["c"], 1_u64, 2) do |batch|
            states = batch.aggregate_count_states_for("c", expected_type)
            states.each { |state| windowed << state.count_state }
          end
          windowed.should eq([127_u64, 128_u64])

          values = table["c"].values.map { |value| value.as(CrystalClick::BinaryValue) }
          values.each { |value| value.type.should eq(expected_type) }
          values.map(&.count_state).should eq(expected_counts)
          expect_raises(CrystalClick::BoundsError) { table["c"].values(max_rows: 4_u64) }
        end
      end
    end

    it "admits Count as a whole-granule UInt64-key candidate payload" do
      columns = "`pk` UInt64,\n`c` AggregateFunction(count)"
      with_w177_offline_count_table(stock_root, "none", columns) do |table|
        count_type = CrystalClick::BinaryDataType.aggregate_count
        keys = [] of UInt64
        states = [] of UInt64
        table.scan_uint64_pk_candidates(["pk", "c"], lower_bound: 13_u64, upper_bound: 31_u64) do |batch|
          batch.values_for("pk").each { |key| keys << key }
          batch.aggregate_count_states_for("c", count_type).each { |state| states << state.count_state }
        end
        # The first two complete mark ranges are returned; exact residual
        # predicate filtering remains the caller's responsibility.
        keys.should eq([7_u64, 13_u64, 22_u64, 31_u64])
        states.should eq([0_u64, 127_u64, 128_u64, 16_384_u64])

        key_only = [] of UInt64
        table.scan_typed(["pk"]) { |batch| key_only.concat(batch.values_for("pk").to_a) }
        key_only.should eq([7_u64, 13_u64, 22_u64, 31_u64, 50_u64])
      end
    end

    it "binds Count-only selection to the DDL-named sibling before callbacks" do
      with_w177_offline_count_table(
        stock_root,
        "none",
        "`id` UInt64,\n`c` AggregateFunction(count)",
        tail: "ORDER BY id"
      ) do |table|
        callbacks = 0
        expect_raises(CrystalClick::UnsupportedFormatError) do
          table.scan_typed(["c"]) { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      end
    end

    it "rejects a DDL Count type that differs from every selected part" do
      with_w177_offline_count_table(
        stock_root,
        "none",
        "`pk` UInt64,\n`c` AggregateFunction(count, UInt64)"
      ) do |table|
        callbacks = 0
        expect_raises(CrystalClick::UnsupportedFormatError) do
          table.scan_typed(["c"]) { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      end
    end

    it "rejects Count schemas without the exact bare two-column MergeTree key pair" do
      invalid_declarations = [
        {"`pk` UInt64,\n`c` AggregateFunction(count),\n`extra` String", "MergeTree", "ORDER BY pk"},
        {"`pk` UInt64,\n`c` AggregateFunction(count) DEFAULT 0", "MergeTree", "ORDER BY pk"},
        {"`pk` UInt64,\n`c` AggregateFunction(count) ALIAS 0", "MergeTree", "ORDER BY pk"},
        {"`pk` UInt64,\n`c` AggregateFunction(count) MATERIALIZED 0", "MergeTree", "ORDER BY pk"},
        {"`pk` UInt64,\n`c` AggregateFunction(count) CODEC(LZ4)", "MergeTree", "ORDER BY pk"},
        {"`pk` UInt64 DEFAULT 0,\n`c` AggregateFunction(count)", "MergeTree", "ORDER BY pk"},
        {"`pk` String,\n`c` AggregateFunction(count)", "MergeTree", "ORDER BY pk"},
        {"`pk` UInt64,\n`c` AggregateFunction(count)", "ReplacingMergeTree", "ORDER BY pk"},
        {"`pk` UInt64,\n`c` AggregateFunction(count)", "MergeTree", "ORDER BY tuple()"},
        {"`pk` UInt64,\n`c` AggregateFunction(count)", "MergeTree", "PRIMARY KEY c\nORDER BY pk"},
      ]
      invalid_declarations.each_with_index do |(columns, engine, tail), index|
        [true, false].each do |with_parts|
          with_w177_offline_count_table(stock_root, "none", columns, engine, tail, with_parts) do |table|
            callbacks = 0
            expect_raises(CrystalClick::UnsupportedFormatError) do
              table.scan_typed(["c"]) { |_batch| callbacks += 1 }
            end
            expect_raises(CrystalClick::UnsupportedFormatError) do
              table.scan_typed_window(["c"], 0_u64, 1) { |_batch| callbacks += 1 }
            end
            expect_raises(CrystalClick::UnsupportedFormatError) { table["c"].values }
            expect_raises(CrystalClick::UnsupportedFormatError) do
              table.scan_uint64_pk_candidates(["pk", "c"], 7_u64, 31_u64) { |_batch| callbacks += 1 }
            end
            callbacks.should eq(0), "invalid Count DDL case #{index}, parts=#{with_parts} invoked a callback"
          end
        end
      end
    end

    it "admits an empty valid catalog without skipping invalid DDL guards" do
      with_w177_offline_count_table(
        stock_root, "none", "`pk` UInt64,\n`c` AggregateFunction(count)", with_parts: false
      ) do |table|
        callbacks = 0
        table.scan_typed(["c"]) { |_batch| callbacks += 1 }
        table.scan_typed_window(["c"], 0_u64, 1) { |_batch| callbacks += 1 }
        table.scan_uint64_pk_candidates(["pk", "c"], 7_u64, 31_u64) { |_batch| callbacks += 1 }
        table["c"].values.should be_empty
        callbacks.should eq(0)
      end
    end

    it "refuses physical Count projection payloads before offline callbacks" do
      columns = "`pk` UInt64,\n`c` AggregateFunction(count),\nPROJECTION p (SELECT pk, c ORDER BY pk)"
      with_w177_offline_count_table(stock_root, "none", columns) do |table|
        parent = table.part_candidates.first.path
        FileUtils.cp_r(File.join(stock_root, "part-none"), File.join(parent, "p.proj"))
        callbacks = 0
        expect_raises(CrystalClick::UnsupportedFormatError) do
          table.scan_projection_typed("p", ["c"]) { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      end
    end
  end
end
