require "./spec_helper"

private struct W178CountArgumentCase
  getter label : String
  getter argument : CrystalClick::BinaryDataType

  def initialize(@label : String, @argument : CrystalClick::BinaryDataType)
  end
end

private def w178_argument_cases : Array(W178CountArgumentCase)
  primitive = ->(name : String) { CrystalClick::BinaryDataType.primitive(name) }
  uint64 = primitive.call("UInt64")
  int8 = primitive.call("Int8")
  uint8 = primitive.call("UInt8")
  string = primitive.call("String")
  nullable_string = CrystalClick::BinaryDataType.nullable(string)
  decimal_9_2 = CrystalClick::BinaryDataType.decimal(32, 9, 2)
  datetime64_3_utc = CrystalClick::BinaryDataType.datetime64(3, "UTC")

  cases = [] of W178CountArgumentCase
  {
    "nothing", "bool", "uint8", "uint16", "uint32", "uint64", "uint128", "uint256",
    "int8", "int16", "int32", "int64", "int128", "int256", "bfloat16", "float32",
    "float64", "string", "uuid", "ipv4", "ipv6",
  }.each do |name|
    cases << W178CountArgumentCase.new(name, primitive.call(
      case name
      when "nothing"  then "Nothing"
      when "bool"     then "Bool"
      when "uint8"    then "UInt8"
      when "uint16"   then "UInt16"
      when "uint32"   then "UInt32"
      when "uint64"   then "UInt64"
      when "uint128"  then "UInt128"
      when "uint256"  then "UInt256"
      when "bfloat16" then "BFloat16"
      when "float32"  then "Float32"
      when "float64"  then "Float64"
      when "string"   then "String"
      when "uuid"     then "UUID"
      when "ipv4"     then "IPv4"
      when "ipv6"     then "IPv6"
      when "int8"     then "Int8"
      when "int16"    then "Int16"
      when "int32"    then "Int32"
      when "int64"    then "Int64"
      when "int128"   then "Int128"
      when "int256"   then "Int256"
      else
        raise "unknown W178 primitive label: #{name}"
      end
    ))
  end

  cases.concat([
    W178CountArgumentCase.new("fixed_string_1", CrystalClick::BinaryDataType.fixed_string(1)),
    W178CountArgumentCase.new("fixed_string_16", CrystalClick::BinaryDataType.fixed_string(16)),
    W178CountArgumentCase.new("enum8", CrystalClick::BinaryDataType.enum8([
      {"zero", 0_i16}, {"one", 1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)),
    W178CountArgumentCase.new("enum8_quoted", CrystalClick::BinaryDataType.enum8([
      {"comma, label", 1_i16}, {"it's\\safe", 2_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)),
    W178CountArgumentCase.new("enum16", CrystalClick::BinaryDataType.enum16([
      {"zero", 0_i16}, {"one", 1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)),
    W178CountArgumentCase.new("decimal32", CrystalClick::BinaryDataType.decimal(32, 9, 2)),
    W178CountArgumentCase.new("decimal64", CrystalClick::BinaryDataType.decimal(64, 18, 3)),
    W178CountArgumentCase.new("decimal128", CrystalClick::BinaryDataType.decimal(128, 38, 4)),
    W178CountArgumentCase.new("decimal256", CrystalClick::BinaryDataType.decimal(256, 76, 4)),
    W178CountArgumentCase.new("decimal_18_4", CrystalClick::BinaryDataType.decimal(64, 18, 4)),
    W178CountArgumentCase.new("date", primitive.call("Date")),
    W178CountArgumentCase.new("date32", primitive.call("Date32")),
    W178CountArgumentCase.new("datetime", CrystalClick::BinaryDataType.datetime),
    W178CountArgumentCase.new("datetime_utc", CrystalClick::BinaryDataType.datetime("UTC")),
    W178CountArgumentCase.new("datetime_new_york", CrystalClick::BinaryDataType.datetime("America/New_York")),
    W178CountArgumentCase.new("datetime64_0", CrystalClick::BinaryDataType.datetime64(0)),
    W178CountArgumentCase.new("datetime64_3", CrystalClick::BinaryDataType.datetime64(3)),
    W178CountArgumentCase.new("datetime64_9", CrystalClick::BinaryDataType.datetime64(9)),
    W178CountArgumentCase.new("datetime64_3_utc", datetime64_3_utc),
    W178CountArgumentCase.new("datetime64_3_new_york", CrystalClick::BinaryDataType.datetime64(3, "America/New_York")),
    W178CountArgumentCase.new("time", primitive.call("Time")),
    W178CountArgumentCase.new("time64_0", CrystalClick::BinaryDataType.time64(0)),
    W178CountArgumentCase.new("time64_3", CrystalClick::BinaryDataType.time64(3)),
    W178CountArgumentCase.new("time64_9", CrystalClick::BinaryDataType.time64(9)),
    W178CountArgumentCase.new("interval_nanosecond", CrystalClick::BinaryDataType.interval(
      CrystalClick::BinaryIntervalType::Kind::Nanosecond
    )),
    W178CountArgumentCase.new("nullable_uint8", CrystalClick::BinaryDataType.nullable(uint8)),
    W178CountArgumentCase.new("nullable_string", CrystalClick::BinaryDataType.nullable(string)),
    W178CountArgumentCase.new("nullable_decimal", CrystalClick::BinaryDataType.nullable(decimal_9_2)),
    W178CountArgumentCase.new("nullable_datetime64_utc", CrystalClick::BinaryDataType.nullable(datetime64_3_utc)),
    W178CountArgumentCase.new("array_uint8", CrystalClick::BinaryDataType.array(uint8)),
    W178CountArgumentCase.new("array_nullable_uint8", CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.nullable(uint8)
    )),
    W178CountArgumentCase.new("tuple_scalars", CrystalClick::BinaryDataType.tuple([
      uint8, string,
    ] of CrystalClick::BinaryDataType)),
    W178CountArgumentCase.new("tuple_quoted_fields", CrystalClick::BinaryDataType.tuple(
      [uint64, nullable_string] of CrystalClick::BinaryDataType,
      ["from", "a`b"]
    )),
    W178CountArgumentCase.new("map_string_uint64", CrystalClick::BinaryDataType.map(string, uint64)),
    W178CountArgumentCase.new("nested_named", CrystalClick::BinaryDataType.nested(
      [uint8, string] of CrystalClick::BinaryDataType,
      ["id", "payload"]
    )),
    W178CountArgumentCase.new("low_cardinality_string", CrystalClick::BinaryDataType.low_cardinality(string)),
    W178CountArgumentCase.new("low_cardinality_nullable_string", CrystalClick::BinaryDataType.low_cardinality(nullable_string)),
    W178CountArgumentCase.new("variant", CrystalClick::BinaryDataType.variant([
      uint8, string,
    ] of CrystalClick::BinaryDataType)),
    W178CountArgumentCase.new("dynamic", CrystalClick::BinaryDataType.dynamic),
    W178CountArgumentCase.new("dynamic_max_types_7", CrystalClick::BinaryDataType.dynamic(7)),
    W178CountArgumentCase.new("simple_aggregate_sum_uint64", CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Sum, uint64
    )),
    W178CountArgumentCase.new("simple_aggregate_any_string", CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Any, string
    )),
  ] of W178CountArgumentCase)

  cases
end

private def w178_validate_tmp_root(path : String, empty : Bool = false) : String
  raise "W178 root is a symlink" if File.symlink?(path)
  resolved = File.realpath(path)
  raise "W178 root must be a /private/tmp child" unless resolved.starts_with?("/private/tmp/")
  raise "W178 root is not a directory" unless Dir.exists?(resolved)
  raise "W178 output root must be empty" if empty && !Dir.children(resolved).empty?
  resolved
end

private def w178_literal_states : Array(UInt64)
  [0_u64, 127_u64, 128_u64, 16_384_u64, UInt64::MAX]
end

private def w178_literal_keys : Array(UInt64)
  [7_u64, 13_u64, 22_u64, 31_u64, 50_u64]
end

private def w178_assert_states(
  actual : Array(CrystalClick::BinaryValue),
  expected_type : CrystalClick::BinaryDataType,
  expected_states : Array(UInt64),
) : Nil
  actual.size.should eq(expected_states.size)
  actual.each_with_index do |value, index|
    value.type.should eq(expected_type)
    value.count_state.should eq(expected_states[index])
    expect_raises(ArgumentError) { value.as_uint64 }
    mutable_bytes = value.bytes
    mutable_bytes.fill(0_u8)
    value.count_state.should eq(expected_states[index])
  end
  nil
end

private def w178_offline_table(root : String, part : String, type_name : String) : CrystalClick::OfflineTable
  database_uuid = "b1780000-0000-4000-8000-000000000011"
  table_uuid = "b1780000-0000-4000-8000-000000000012"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(File.join(root, "metadata", "lab.sql"),
    "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n`pk` UInt64,\n`c` #{type_name}\n)\n" +
    "ENGINE = MergeTree\nPRIMARY KEY pk\nORDER BY pk\n")
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, "all_1_1_0"))
  CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
end

private def w178_assert_consumers(
  stock_root : String,
  label : String,
  argument : CrystalClick::BinaryDataType,
  explicit_part_path : String? = nil,
) : Nil
  type = CrystalClick::BinaryDataType.aggregate_count(argument)
  part = explicit_part_path || File.join(stock_root, "part-#{label}", "all_1_1_0")
  raise "W178 part is missing for #{label}" unless Dir.exists?(part) && !File.symlink?(part)

  keys = w178_literal_keys
  counts = w178_literal_states
  expected_values = counts.map { |count| CrystalClick::BinaryValue.aggregate_count_state(type, count) }
  reader = CrystalClick::WidePart.open_typed(part, column: "c")
  reader.column_type.should eq(type.name)
  reader.row_count.should eq(5_u64)
  reader.read_aggregate_count_mark_range("c", 0, reader.mark_count, expected_type: type).map(&.count_state).should eq(counts)

  physical = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "c"])
  full = [] of CrystalClick::BinaryValue
  full_keys = [] of UInt64
  physical.scan_typed(batch_rows: 2) do |batch|
    full.concat(batch.aggregate_count_states_for("c", type).to_a)
    full_keys.concat(batch.values_for("pk").to_a)
    nil
  end
  full_keys.should eq(keys)
  w178_assert_states(full, type, counts)

  window = [] of CrystalClick::BinaryValue
  physical.scan_typed_window(1_u64, 2) do |batch|
    window.concat(batch.aggregate_count_states_for("c", type).to_a)
    nil
  end
  w178_assert_states(window, type, [127_u64, 128_u64])

  root = File.tempname("crystal-click-w178-offline-count")
  Dir.mkdir(root)
  begin
    table = w178_offline_table(root, part, type.name)
    offline_full = [] of CrystalClick::BinaryValue
    offline_keys = [] of UInt64
    table.scan_typed(["pk", "c"], batch_rows: 2) do |batch|
      offline_keys.concat(batch.values_for("pk").to_a)
      offline_full.concat(batch.aggregate_count_states_for("c", type).to_a)
      nil
    end
    offline_keys.should eq(keys)
    w178_assert_states(offline_full, type, counts)

    offline_window = [] of CrystalClick::BinaryValue
    table.scan_typed_window(["pk", "c"], 1_u64, 2) do |batch|
      offline_window.concat(batch.aggregate_count_states_for("c", type).to_a)
      nil
    end
    w178_assert_states(offline_window, type, [127_u64, 128_u64])

    values = table["c"].values.map(&.as(CrystalClick::BinaryValue))
    w178_assert_states(values, type, counts)
    values.map(&.count_state).should eq(expected_values.map(&.count_state))

    empty_rows = 0
    table.scan_uint64_pk_candidates(["pk", "c"], lower_bound: 51_u64, upper_bound: 90_u64) do |batch|
      empty_rows += batch.values_for("pk").size
      nil
    end
    empty_rows.should eq(0)

    candidate_keys = [] of UInt64
    candidate_states = [] of CrystalClick::BinaryValue
    table.scan_uint64_pk_candidates(["pk", "c"], lower_bound: 13_u64, upper_bound: 31_u64) do |batch|
      candidate_keys.concat(batch.values_for("pk").to_a)
      candidate_states.concat(batch.aggregate_count_states_for("c", type).to_a)
      nil
    end
    candidate_keys.should eq([7_u64, 13_u64, 22_u64, 31_u64])
    w178_assert_states(candidate_states, type, [0_u64, 127_u64, 128_u64, 16_384_u64])
    w178_assert_states(values, type, counts)
  ensure
    FileUtils.rm_rf(root)
  end
  nil
end

private def w178_write_library_part(root : String, entry : W178CountArgumentCase) : String
  profile_root = File.join(root, "part-#{entry.label}")
  Dir.mkdir(profile_root)
  part = File.join(profile_root, "all_1_1_0")
  type = CrystalClick::BinaryDataType.aggregate_count(entry.argument)
  values = w178_literal_states.map { |count| CrystalClick::BinaryValue.aggregate_count_state(type, count) }
  keys = w178_literal_keys
  CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
    part,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "c",
    type,
    values.to_unsafe.to_slice(values.size),
    rows_per_mark: 2
  )
  part
end

private def w178_assert_metadata_and_value_codec(entry : W178CountArgumentCase) : CrystalClick::BinaryDataType
  argument = entry.argument
  type = CrystalClick::BinaryDataType.aggregate_count(argument)
  type.name.should eq("AggregateFunction(count, #{argument.name})")
  type.child_count.should eq(0)
  type.aggregate_count_argument_type.should eq(argument)
  type.aggregate_count_type.not_nil!.argument_type.should eq(argument)
  type.aggregate_count_type.not_nil!.type_name.should eq(type.name)

  parser = CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical(argument.name)
  parser.should eq(argument)
  same_name_different_decimal_width = if argument.name == "Decimal(18, 4)"
                                        CrystalClick::BinaryDataType.decimal(128, 18, 4)
                                      else
                                        nil
                                      end
  if alternate = same_name_different_decimal_width
    alternate.should_not eq(argument)
    alternate.name.should eq(argument.name)
  end

  type
end

describe "W178 broad AggregateFunction(count) argument consumers" do
  entries = w178_argument_cases
  entries.map(&.label).uniq.size.should eq(entries.size)
  entries.size.should eq(63)

  if library_root = ENV["W178_LIBRARY_PART_ROOT"]?
    w178_validate_tmp_root(library_root, empty: true)
    entries.each do |entry|
      it "writes and consumes canonical #{entry.argument.name} Count states" do
        type = w178_assert_metadata_and_value_codec(entry)
        state_literal = Bytes[0x80_u8, 0x01]
        encoded = CrystalClick::BinaryValueCodec.encode_value(
          CrystalClick::BinaryValue.aggregate_count_state(type, 128_u64)
        )
        encoded.should eq(state_literal)
        decoded = CrystalClick::BinaryValueCodec.decode_value(type, state_literal)
        decoded.type.should eq(type)
        decoded.count_state.should eq(128_u64)

        part = w178_write_library_part(library_root, entry)
        expected = w178_literal_states
        reader = CrystalClick::WidePart.open_typed(part, column: "c")
        reader.column_type.should eq(type.name)
        reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
        reader.read_aggregate_count_mark_range("c", 0, reader.mark_count, expected_type: type).map(&.count_state).should eq(expected)
        w178_assert_consumers(library_root, entry.label, entry.argument, part)
      end
    end
  end

  if stock_root = ENV["W178_STOCK_ROOT"]?
    w178_validate_tmp_root(stock_root)
    entries.each do |entry|
      it "reads stock-authored canonical #{entry.argument.name} Count states offline" do
        w178_assert_metadata_and_value_codec(entry)
        w178_assert_consumers(stock_root, entry.label, entry.argument)
      end
    end
  end
end
