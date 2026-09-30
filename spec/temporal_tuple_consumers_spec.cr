require "./spec_helper"
require "file_utils"

private struct W100TemporalConsumerField
  getter name : String
  getter type_name : String
  getter column : CrystalClick::WideTupleLeafColumn

  def initialize(@name : String, @type_name : String, column : CrystalClick::WideTupleLeafColumn)
    @column = column.owned_copy
    raise "consumer field type differs from its leaf" unless @column.type_name == @type_name
  end
end

private def w100t_temporal_specs : Array(Tuple(String, String))
  specs = [
    {"date", "Date"},
    {"date32", "Date32"},
    {"datetime", "DateTime"},
    {"time", "Time"},
  ] of Tuple(String, String)
  (0..9).each do |precision|
    specs << {"datetime64_p#{precision}", "DateTime64(#{precision})"}
    specs << {"time64_p#{precision}", "Time64(#{precision})"}
  end
  raise "consumer fixture must retain all 24 exact declarations" unless specs.size == 24
  specs
end

private def w100t_precision(type_name : String) : Int32
  match = type_name.match(/\((\d+)\)/) || raise "scaled temporal type has no precision"
  match[1].to_i32
end

private def w100t_raws(type_name : String) : Array(Int64)
  case type_name
  when "Date"
    [0_i64, 1_i64, 32_767_i64, 32_768_i64, 65_535_i64]
  when "Date32"
    [-25_567_i64, -1_i64, 0_i64, 1_i64, 24_854_i64]
  when "DateTime"
    [0_i64, 1_i64, 1_000_000_000_i64, 1_700_000_000_i64, 2_000_000_000_i64]
  when "Time"
    [-3_723_i64, 0_i64, 1_i64, 59_i64, 52_225_i64]
  when .starts_with?("DateTime64(")
    factor = 10_i64 ** w100t_precision(type_name)
    [-1_i64, 0_i64, factor, 1_700_000_000_i64 * factor, 2_000_000_000_i64 * factor]
  when .starts_with?("Time64(")
    factor = 10_i64 ** w100t_precision(type_name)
    half_tick = factor // 2_i64
    [
      -3_723_i64 * factor - half_tick,
      0_i64,
      factor,
      59_i64 * factor + half_tick,
      3_600_i64 * factor + factor - 1_i64,
    ]
  else
    raise "unexpected temporal consumer type #{type_name}"
  end
end

private def w100t_temporal_column(name : String, type_name : String, raws : Array(Int64)) : CrystalClick::WideTupleLeafColumn
  case type_name
  when "Date"
    CrystalClick::WideTupleLeafColumn.new(name, type_name, raws.map { |raw| CrystalClick::DateValue.new(raw.to_u16) })
  when "Date32"
    CrystalClick::WideTupleLeafColumn.new(name, type_name, raws.map { |raw| CrystalClick::Date32Value.new(raw.to_i32) })
  when "DateTime"
    CrystalClick::WideTupleLeafColumn.new(name, type_name, raws.map { |raw| CrystalClick::DateTimeValue.new(raw.to_u32) })
  when "Time"
    CrystalClick::WideTupleLeafColumn.new(name, type_name, raws.map { |raw| CrystalClick::TimeValue.new(raw.to_i32) })
  when .starts_with?("DateTime64(")
    precision = w100t_precision(type_name)
    CrystalClick::WideTupleLeafColumn.new(name, type_name, raws.map { |raw| CrystalClick::DateTime64Value.new(raw, precision) })
  when .starts_with?("Time64(")
    precision = w100t_precision(type_name)
    CrystalClick::WideTupleLeafColumn.new(name, type_name, raws.map { |raw| CrystalClick::Time64Value.new(raw, precision) })
  else
    raise "no nominal leaf constructor for #{type_name}"
  end
end

private def w100t_fields : Array(W100TemporalConsumerField)
  uuid = [
    CrystalClick::UUIDValue.new(0x0011_2233_4455_6677_u64, 0x8899_aabb_ccdd_eeff_u64),
    CrystalClick::UUIDValue.new(UInt64::MAX, 0_u64),
    CrystalClick::UUIDValue.new(0_u64, 0_u64),
    CrystalClick::UUIDValue.new(0x0123_4567_89ab_cdef_u64, 0xfedc_ba98_7654_3210_u64),
    CrystalClick::UUIDValue.new(0x7f00_ff01_fe02_fd03_u64, 0x04fc_05fb_06fa_07f9_u64),
  ]
  ipv4 = [
    CrystalClick::IPv4Value.from_octets(1_u8, 2_u8, 3_u8, 4_u8),
    CrystalClick::IPv4Value.from_octets(4_u8, 3_u8, 2_u8, 1_u8),
    CrystalClick::IPv4Value.from_octets(0_u8, 0_u8, 0_u8, 0_u8),
    CrystalClick::IPv4Value.from_octets(255_u8, 255_u8, 255_u8, 255_u8),
    CrystalClick::IPv4Value.from_octets(192_u8, 168_u8, 1_u8, 7_u8),
  ]

  fields = [] of W100TemporalConsumerField
  fields << W100TemporalConsumerField.new("event_p3_first", "DateTime64(3)", w100t_temporal_column("event_p3_first", "DateTime64(3)", w100t_raws("DateTime64(3)")))
  fields << W100TemporalConsumerField.new("count", "UInt64", CrystalClick::WideTupleLeafColumn.new("count", [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]))
  w100t_temporal_specs.reverse_each do |label, type_name|
    name = "t_#{label}"
    fields << W100TemporalConsumerField.new(name, type_name, w100t_temporal_column(name, type_name, w100t_raws(type_name)))
  end
  fields << W100TemporalConsumerField.new("flag", "Bool", CrystalClick::WideTupleLeafColumn.new("flag", [false, true, false, true, true]))
  fields << W100TemporalConsumerField.new("text", "String", CrystalClick::WideTupleLeafColumn.new("text", ["alpha", String.new(Bytes[0x62_u8, 0_u8, 0xff_u8]), "", "delta", "epsilon"] of String))
  fields << W100TemporalConsumerField.new("id", "UUID", CrystalClick::WideTupleLeafColumn.new("id", uuid))
  fields << W100TemporalConsumerField.new("address", "IPv4", CrystalClick::WideTupleLeafColumn.new("address", ipv4))
  fields << W100TemporalConsumerField.new("event_p3_repeat", "DateTime64(3)", w100t_temporal_column("event_p3_repeat", "DateTime64(3)", w100t_raws("DateTime64(3)")))
  fields << W100TemporalConsumerField.new("event_p9_repeat", "DateTime64(9)", w100t_temporal_column("event_p9_repeat", "DateTime64(9)", w100t_raws("DateTime64(9)")))
  fields << W100TemporalConsumerField.new("time_p9_repeat", "Time64(9)", w100t_temporal_column("time_p9_repeat", "Time64(9)", w100t_raws("Time64(9)")))
  raise "composed consumer fixture omitted an exact declaration" unless w100t_temporal_specs.all? { |_, type_name| fields.any? { |field| field.type_name == type_name } }
  fields
end

private def w100t_type_name(fields : Array(W100TemporalConsumerField)) : String
  "Tuple(#{fields.map { |field| "#{field.name} #{field.type_name}" }.join(", ")})"
end

private def w100t_assert_row(row : CrystalClick::WideTupleRow, fields : Array(W100TemporalConsumerField), source_index : Int32, label : String) : Nil
  row.type_name.should eq(w100t_type_name(fields))
  row.field_count.should eq(fields.size)
  fields.each do |field|
    case field.type_name
    when "Date"
      row.value_as(field.name, CrystalClick::DateValue).should eq(field.column.value_at(source_index, CrystalClick::DateValue))
    when "Date32"
      row.value_as(field.name, CrystalClick::Date32Value).should eq(field.column.value_at(source_index, CrystalClick::Date32Value))
    when "DateTime"
      row.value_as(field.name, CrystalClick::DateTimeValue).should eq(field.column.value_at(source_index, CrystalClick::DateTimeValue))
    when "Time"
      row.value_as(field.name, CrystalClick::TimeValue).should eq(field.column.value_at(source_index, CrystalClick::TimeValue))
    when .starts_with?("DateTime64(")
      value = row.value_as(field.name, CrystalClick::DateTime64Value)
      value.precision.to_i32.should eq(w100t_precision(field.type_name))
      value.should eq(field.column.value_at(source_index, CrystalClick::DateTime64Value))
    when .starts_with?("Time64(")
      value = row.value_as(field.name, CrystalClick::Time64Value)
      value.precision.to_i32.should eq(w100t_precision(field.type_name))
      value.should eq(field.column.value_at(source_index, CrystalClick::Time64Value))
    when "UInt64"
      row.value_as(field.name, UInt64).should eq(field.column.value_at(source_index, UInt64))
    when "Bool"
      row.value_as(field.name, Bool).should eq(field.column.value_at(source_index, Bool))
    when "String"
      row.value_as(field.name, String).should eq(field.column.value_at(source_index, String))
    when "UUID"
      row.value_as(field.name, CrystalClick::UUIDValue).should eq(field.column.value_at(source_index, CrystalClick::UUIDValue))
    when "IPv4"
      row.value_as(field.name, CrystalClick::IPv4Value).should eq(field.column.value_at(source_index, CrystalClick::IPv4Value))
    else
      raise "#{label}: unsupported field #{field.type_name}"
    end
  end
  nil
end

private def w100t_catalog_root(root : String, part : String, fields : Array(W100TemporalConsumerField)) : String
  database_uuid = "10000000-0000-4000-8000-000000000011"
  table_uuid = "10000000-0000-4000-8000-000000000012"
  metadata_path = File.join(root, "metadata")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata_path)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(metadata_path, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(File.join(database_path, "events.sql"), "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{w100t_type_name(fields)}\n)\nENGINE = MergeTree\nORDER BY pk\n")
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, "all_1_1_0"))
  table_path
end

describe "named-flat temporal Tuple consumers" do
  it "preserves all exact temporal declarations through reader, table, and catalog consumers" do
    fields = w100t_fields
    columns = fields.map(&.column)
    type_name = w100t_type_name(fields)
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    parent = File.tempname("crystal-click-w100-temporal-tuple-consumers")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, rows_per_mark: 2
      ).should eq(part)

      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      data = reader.read_tuple_mark_range("payload", 0, reader.mark_count)
      data.type_name.should eq(type_name)
      data.fields.map { |field| {field.name, field.type_name} }.should eq(fields.map { |field| {field.name, field.type_name} })
      5.times { |index| w100t_assert_row(data.row(index), fields, index.to_i32, "reader row #{index}") }

      # A physical mark window is independent of a SQL key predicate: marks
      # 1 and 2 contain source rows [3,4,5], while keys 2..4 are [2,3,4].
      selected = reader.read_tuple_mark_range("payload", 1, 2)
      selected.row_count.should eq(3)
      [2_i32, 3_i32, 4_i32].each_with_index do |source_index, local_index|
        w100t_assert_row(selected.row(local_index), fields, source_index, "reader selected mark rows")
      end

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      seen = [] of Int32
      table.scan_typed do |batch|
        batch.values_for("pk").each_with_index do |key, offset|
          source_index = (key - 1_u64).to_i32
          w100t_assert_row(batch.tuple_rows_for("payload")[offset], fields, source_index, "table full scan")
          seen << source_index
        end
        nil
      end
      seen.should eq([0_i32, 1_i32, 2_i32, 3_i32, 4_i32])

      window_seen = [] of Int32
      table.scan_typed_window(1_u64, 3) do |batch|
        batch.values_for("pk").each_with_index do |key, offset|
          source_index = (key - 1_u64).to_i32
          w100t_assert_row(batch.tuple_rows_for("payload")[offset], fields, source_index, "table window")
          window_seen << source_index
        end
        nil
      end
      window_seen.should eq([1_i32, 2_i32, 3_i32])

      candidate_seen = [] of Int32
      table.scan_typed_candidate_marks([[1_i32, 2_i32]]) do |batch|
        batch.values_for("pk").each_with_index do |key, offset|
          source_index = (key - 1_u64).to_i32
          w100t_assert_row(batch.tuple_rows_for("payload")[offset], fields, source_index, "table candidate marks")
          candidate_seen << source_index
        end
        nil
      end
      candidate_seen.should eq([2_i32, 3_i32, 4_i32])

      catalog_root = File.join(parent, "catalog")
      copied_table = w100t_catalog_root(catalog_root, part, fields)
      catalog = CrystalClick::OfflineCatalog.open(catalog_root)
      offline_table = catalog.table("lab", "events")
      resolved = offline_table.resolved_scan_parts
      resolved.size.should eq(1)
      File.realpath(resolved[0].path).should eq(File.realpath(File.join(copied_table, "all_1_1_0")))
      values = offline_table["payload"].values(max_tuple_cells: 10_000_u64)
      values.size.should eq(5)
      values.each_with_index do |value, index|
        w100t_assert_row(value.as(CrystalClick::WideTupleRow), fields, index.to_i32, "catalog materialized values")
      end

      catalog_seen = [] of Int32
      offline_table.scan_typed(["pk", "payload"]) do |batch|
        batch.values_for("pk").each_with_index do |key, offset|
          source_index = (key - 1_u64).to_i32
          w100t_assert_row(batch.tuple_rows_for("payload")[offset], fields, source_index, "catalog full scan")
          catalog_seen << source_index
        end
        nil
      end
      catalog_seen.should eq([0_i32, 1_i32, 2_i32, 3_i32, 4_i32])

      catalog_window = [] of Int32
      offline_table.scan_typed_window(["pk", "payload"], 1_u64, 3) do |batch|
        batch.values_for("pk").each_with_index do |key, offset|
          source_index = (key - 1_u64).to_i32
          w100t_assert_row(batch.tuple_rows_for("payload")[offset], fields, source_index, "catalog window")
          catalog_window << source_index
        end
        nil
      end
      catalog_window.should eq([1_i32, 2_i32, 3_i32])

      expect_raises(CrystalClick::UnsupportedFormatError) do
        data.value_as("t_date32", 0, CrystalClick::DateValue)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
