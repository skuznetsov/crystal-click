require "./spec_helper"
require "file_utils"
require "./support/simple_aggregate_w164_types"

private def w164_assert(condition : Bool, message : String) : Nil
  raise message unless condition
end

private def w164_append_le(bytes : Array(UInt8), value : UInt128, width : Int32) : Nil
  width.times do |index|
    bytes << ((value >> (index * 8)) & 0xff_u128).to_u8
  end
end

private def w164_u64_bytes(values : Array(UInt64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each { |value| w164_append_le(bytes, value.to_u128, 8) }
  bytes
end

private def w164_numeric_value_bytes(value : UInt128) : Array(UInt8)
  bytes = [] of UInt8
  w164_append_le(bytes, value, 16)
  bytes
end

private def w164_numeric_value_bytes(value : Int128) : Array(UInt8)
  bytes = [] of UInt8
  w164_append_le(bytes, value.unsafe_as(UInt128), 16)
  bytes
end

private def w164_numeric_value_bytes(value : CrystalClick::UInt256Value) : Array(UInt8)
  bytes = [] of UInt8
  w164_append_le(bytes, value.low, 16)
  w164_append_le(bytes, value.high, 16)
  bytes
end

private def w164_numeric_value_bytes(value : CrystalClick::Int256Value) : Array(UInt8)
  bytes = [] of UInt8
  w164_append_le(bytes, value.low, 16)
  w164_append_le(bytes, value.high, 16)
  bytes
end

private def w164_numeric_value_bytes(value : CrystalClick::BFloat16Value) : Array(UInt8)
  bytes = [] of UInt8
  w164_append_le(bytes, value.bits.to_u128, 2)
  bytes
end

private def w164_numeric_bytes(values : Array(T)) : Array(UInt8) forall T
  values.flat_map { |value| w164_numeric_value_bytes(value) }
end

private def w164_nullable_numeric_bytes(values : Array(T?)) : Array(UInt8) forall T
  bytes = [] of UInt8
  values.each do |value|
    if value.nil?
      bytes.concat(Array(UInt8).new(sizeof(T), 0_u8))
    else
      bytes.concat(w164_numeric_value_bytes(value.not_nil!))
    end
  end
  bytes
end

private def w164_assert_values(actual : Array(T), expected : Array(T), label : String) : Nil forall T
  w164_assert(actual.size == expected.size, "#{label}: row count differs (#{actual.size} != #{expected.size})")
  actual.each_with_index do |value, index|
    w164_assert(w164_numeric_value_bytes(value) == w164_numeric_value_bytes(expected[index]),
      "#{label}: exact raw value differs at row #{index}")
  end
end

private def w164_assert_nullable_values(actual : Array(T?), expected : Array(T?), label : String) : Nil forall T
  w164_assert(actual.size == expected.size, "#{label}: row count differs (#{actual.size} != #{expected.size})")
  actual.each_with_index do |value, index|
    wanted = expected[index]
    w164_assert(value.nil? == wanted.nil?, "#{label}: nullness differs at row #{index}")
    unless value.nil?
      w164_assert(w164_numeric_value_bytes(value.not_nil!) == w164_numeric_value_bytes(wanted.not_nil!),
        "#{label}: exact raw value differs at row #{index}")
    end
  end
end

private def w164_stream_bytes(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w164_mark_rows(part : String, logical_name : String) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  bytes = File.read(path).to_slice
  w164_assert(bytes.size % CrystalClick::WidePart::MARK_SIZE == 0, "#{logical_name}: malformed mrk2 size")
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |mark|
    offset = mark * CrystalClick::WidePart::MARK_SIZE + 16
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end
end

private def w164_check_layout(
  part : String,
  function_name : String,
  carrier_name : String,
  nullable : Bool,
  row_count : Int32,
  keys : Array(UInt64),
  values : Array(T),
  nullable_values : Array(T?),
) : Nil forall T
  base_type = "SimpleAggregateFunction(#{function_name}, #{carrier_name})"
  type = nullable ? "Nullable(#{base_type})" : base_type
  w164_assert(File.read(File.join(part, "columns.txt")) ==
              "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{type}\n",
    "#{type}: exact columns metadata differs")

  value_streams = nullable ? ["v.null", "v"] : ["v"]
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "#{value_streams.size} substreams for column `v`:\n" + value_streams.map { |name| "\t#{name}\n" }.join
  w164_assert(File.read(File.join(part, "columns_substreams.txt")) == expected_substreams,
    "#{type}: exact substream metadata differs")
  w164_assert(File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)", "#{type}: LZ4 metadata differs")
  w164_assert(File.read(File.join(part, "serialization.json")) ==
              "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}",
    "#{type}: exact serialization metadata differs")
  w164_assert(File.read(File.join(part, "count.txt")) == row_count.to_s, "#{type}: row count metadata differs")
  w164_assert(File.read(File.join(part, "metadata_version.txt")) == "0", "#{type}: metadata version differs")
  w164_assert(w164_stream_bytes(part, "pk") == w164_u64_bytes(keys), "#{type}: UInt64 key bytes differ")

  expected_value_bytes = nullable ? w164_nullable_numeric_bytes(nullable_values) : w164_numeric_bytes(values)
  w164_assert(w164_stream_bytes(part, "v") == expected_value_bytes,
    "#{type}: exact little-endian fixed-width child bytes differ")
  if nullable
    expected_null_map = nullable_values.map { |value| value.nil? ? 1_u8 : 0_u8 }
    w164_assert(w164_stream_bytes(part, "v.null") == expected_null_map, "#{type}: Nullable null-map bytes differ")
  end

  streams = nullable ? ["pk", "v.null", "v"] : ["pk", "v"]
  streams.each do |stream|
    w164_assert(w164_mark_rows(part, stream) == [2_u64, 2_u64, 2_u64, 0_u64], "#{type}: #{stream} mark grid differs")
  end
end

private def w164_check_stock_profile(
  stock_part : String,
  function_name : String,
  function_suffix : String,
  carrier_name : String,
  carrier_suffix : String,
  stock_values : Array(T),
) : Nil forall T
  nullable_values = W164SimpleAggregateTestSupport.nullable_values(stock_values)
  suffix = "#{function_suffix}_#{carrier_suffix}"
  scalar_column = "s_#{suffix}"
  nullable_column = "n_#{suffix}"
  scalar_type = "SimpleAggregateFunction(#{function_name}, #{carrier_name})"
  nullable_type = "Nullable(#{scalar_type})"

  scalar = CrystalClick::WidePart.open_typed(stock_part, scalar_column)
  scalar.column_type.should eq(scalar_type)
  scalar.row_count.should eq(6_u64)
  scalar.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
  w164_assert_values(scalar.read_simple_aggregate_numeric_mark_range(scalar_column, 0, scalar.mark_count, T), stock_values,
    "#{scalar_type} full stock read")
  w164_assert_values(scalar.read_simple_aggregate_numeric_mark_range(scalar_column, 1, 1, T), stock_values[2, 2],
    "#{scalar_type} middle stock read")
  w164_assert(w164_stream_bytes(stock_part, scalar_column) == w164_numeric_bytes(stock_values),
    "#{scalar_type}: stock child stream differs from independent little-endian literals")
  w164_assert(w164_stream_bytes(stock_part, "pk") == w164_u64_bytes(W164_SIMPLE_AGGREGATE_KEYS),
    "#{scalar_type}: stock key stream differs from independent little-endian literals")

  nullable = CrystalClick::WidePart.open_typed(stock_part, nullable_column)
  nullable.column_type.should eq(nullable_type)
  nullable.row_count.should eq(6_u64)
  nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
  w164_assert_nullable_values(
    nullable.read_nullable_simple_aggregate_numeric_mark_range(nullable_column, 0, nullable.mark_count, T),
    nullable_values, "#{nullable_type} full stock read"
  )
  w164_assert_nullable_values(
    nullable.read_nullable_simple_aggregate_numeric_mark_range(nullable_column, 1, 1, T),
    nullable_values[2, 2], "#{nullable_type} middle stock read"
  )
  w164_assert(w164_stream_bytes(stock_part, nullable_column) == w164_nullable_numeric_bytes(nullable_values),
    "#{nullable_type}: stock child stream differs from independent little-endian literals")
  w164_assert(w164_stream_bytes(stock_part, "#{nullable_column}.null") ==
              nullable_values.map { |value| value.nil? ? 1_u8 : 0_u8 },
    "#{nullable_type}: stock null-map differs from literal NULL row")

  table = CrystalClick::WidePartTable.open_selected_typed([stock_part], ["pk", scalar_column, nullable_column])
  observed_keys = [] of UInt64
  observed_scalar = [] of T
  observed_nullable = [] of T?
  observed_marks = [] of Int32
  table.scan_typed(batch_rows: 2) do |batch|
    keys = batch.values_for("pk", UInt64)
    observed_keys.concat(keys.to_a)
    observed_scalar.concat(batch.simple_aggregate_values_for(scalar_column, T).to_a)
    observed_nullable.concat(batch.nullable_simple_aggregate_values_for(nullable_column, T).to_a)
    observed_marks.concat(Array(Int32).new(keys.size, batch.mark_index))
  end
  observed_keys.should eq(W164_SIMPLE_AGGREGATE_KEYS)
  w164_assert_values(observed_scalar, stock_values, "#{scalar_type} stock table read")
  w164_assert_nullable_values(observed_nullable, nullable_values, "#{nullable_type} stock table read")
  observed_marks.should eq([0, 0, 1, 1, 2, 2])

  empty_callbacks = 0
  table.scan_typed_window(table.total_row_count, 1) { |_batch| empty_callbacks += 1; nil }
  empty_callbacks.should eq(0)
end

private def w164_write_library_profile(
  part_root : String,
  function_name : String,
  function_suffix : String,
  function : CrystalClick::BinarySimpleAggregateType::Function,
  carrier_name : String,
  carrier_suffix : String,
  values : Array(T),
  nullable_values : Array(T?),
) : Nil forall T
  base_type = "SimpleAggregateFunction(#{function_name}, #{carrier_name})"
  keys = W164_SIMPLE_AGGREGATE_KEYS
  scalar_parent = File.join(part_root, "scalar_#{function_suffix}_#{carrier_suffix}")
  nullable_parent = File.join(part_root, "nullable_#{function_suffix}_#{carrier_suffix}")
  Dir.mkdir(scalar_parent)
  Dir.mkdir(nullable_parent)
  scalar_part = File.join(scalar_parent, "all_1_1_0")
  nullable_part = File.join(nullable_parent, "all_1_1_0")

  CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
    scalar_part, "pk", keys.to_unsafe.to_slice(keys.size), "v",
    values.to_unsafe.to_slice(values.size), function, rows_per_mark: 2
  )
  CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_pair(
    nullable_part, "pk", keys.to_unsafe.to_slice(keys.size), "v",
    nullable_values.to_unsafe.to_slice(nullable_values.size), function, rows_per_mark: 2
  )

  w164_check_layout(scalar_part, function_name, carrier_name, false, values.size, keys, values, nullable_values)
  w164_check_layout(nullable_part, function_name, carrier_name, true, values.size, keys, values, nullable_values)

  scalar = CrystalClick::WidePart.open_typed(scalar_part, "v")
  scalar.column_type.should eq(base_type)
  w164_assert_values(scalar.read_simple_aggregate_numeric_mark_range("v", 0, scalar.mark_count, T), values,
    "#{base_type} full library read")
  w164_assert_values(scalar.read_simple_aggregate_numeric_mark_range("v", 1, 1, T), values[2, 2],
    "#{base_type} middle library read")

  nullable = CrystalClick::WidePart.open_typed(nullable_part, "v")
  nullable.column_type.should eq("Nullable(#{base_type})")
  w164_assert_nullable_values(
    nullable.read_nullable_simple_aggregate_numeric_mark_range("v", 0, nullable.mark_count, T),
    nullable_values, "Nullable(#{base_type}) full library read"
  )
  w164_assert_nullable_values(
    nullable.read_nullable_simple_aggregate_numeric_mark_range("v", 1, 1, T),
    nullable_values[2, 2], "Nullable(#{base_type}) middle library read"
  )

  table = CrystalClick::WidePartTable.open_selected_typed([scalar_part], ["pk", "v"])
  observed = [] of T
  observed_keys = [] of UInt64
  table.scan_typed(batch_rows: 2) do |batch|
    observed_keys.concat(batch.values_for("pk", UInt64).to_a)
    observed.concat(batch.simple_aggregate_values_for("v", T).to_a)
  end
  observed_keys.should eq(keys)
  w164_assert_values(observed, values, "#{base_type} library table read")

  nullable_table = CrystalClick::WidePartTable.open_selected_typed([nullable_part], ["pk", "v"])
  observed_nullable = [] of T?
  observed_nullable_keys = [] of UInt64
  nullable_table.scan_typed(batch_rows: 2) do |batch|
    observed_nullable_keys.concat(batch.values_for("pk", UInt64).to_a)
    observed_nullable.concat(batch.nullable_simple_aggregate_values_for("v", T).to_a)
  end
  observed_nullable_keys.should eq(keys)
  w164_assert_nullable_values(observed_nullable, nullable_values, "Nullable(#{base_type}) library table read")
  puts "PASS W164 library writer #{function_name}/#{carrier_name}: scalar and outer Nullable raw bytes and typed reads"
end

private def w164_write_carrier(part_root : String, carrier_name : String, carrier_suffix : String, values : Array(T)) : Int32 forall T
  nullable_values = W164SimpleAggregateTestSupport.nullable_values(values)
  profiles = W164SimpleAggregateTestSupport.profiles_for(carrier_name)
  profiles.each do |function_name, function_suffix, function|
    w164_write_library_profile(part_root, function_name, function_suffix, function,
      carrier_name, carrier_suffix, values, nullable_values)
  end
  profiles.size
end

if stock_part = ENV["W164_SIMPLE_AGGREGATE_STOCK_WIDE_PART"]?
  describe "W164 literal stock/library SimpleAggregateFunction wide numeric oracle" do
    it "reads every stock-authored scalar and outer Nullable profile with exact raw bytes" do
      profile_count = 0
      W164_SIMPLE_AGGREGATE_FUNCTIONS_BY_CARRIER.each_key do |carrier_name|
        profiles = W164SimpleAggregateTestSupport.profiles_for(carrier_name)
        profile_count += profiles.size
        case carrier_name
        when "UInt128"
          profiles.each { |name, suffix, _function| w164_check_stock_profile(stock_part, name, suffix, carrier_name, "u128", W164_STOCK_UINT128_VALUES) }
        when "Int128"
          profiles.each { |name, suffix, _function| w164_check_stock_profile(stock_part, name, suffix, carrier_name, "i128", W164_STOCK_INT128_VALUES) }
        when "UInt256"
          profiles.each { |name, suffix, _function| w164_check_stock_profile(stock_part, name, suffix, carrier_name, "u256", W164_STOCK_UINT256_VALUES) }
        when "Int256"
          profiles.each { |name, suffix, _function| w164_check_stock_profile(stock_part, name, suffix, carrier_name, "i256", W164_STOCK_INT256_VALUES) }
        when "BFloat16"
          profiles.each { |name, suffix, _function| w164_check_stock_profile(stock_part, name, suffix, carrier_name, "bf16", W164_STOCK_BFLOAT16_VALUES) }
        else
          raise "No literal W164 stock fixture for #{carrier_name}"
        end
      end
      profile_count.should eq(W164_SIMPLE_AGGREGATE_EXPECTED_SCALAR_PROFILES)
    end

    it "writes all library-authored complete scalar and outer Nullable profiles" do
      part_root = ENV["W164_PART_ROOT"]? || raise "W164_PART_ROOT is required"
      Dir.mkdir(part_root) unless Dir.exists?(part_root)
      generated = 0
      generated += w164_write_carrier(part_root, "UInt128", "u128", W164_LIBRARY_UINT128_VALUES)
      generated += w164_write_carrier(part_root, "Int128", "i128", W164_LIBRARY_INT128_VALUES)
      generated += w164_write_carrier(part_root, "UInt256", "u256", W164_LIBRARY_UINT256_VALUES)
      generated += w164_write_carrier(part_root, "Int256", "i256", W164_LIBRARY_INT256_VALUES)
      generated += w164_write_carrier(part_root, "BFloat16", "bf16", W164_LIBRARY_BFLOAT16_VALUES)
      generated.should eq(W164_SIMPLE_AGGREGATE_EXPECTED_SCALAR_PROFILES)

      mutant_parent = File.join(part_root, "scalar_min_u128_value_mutant")
      Dir.mkdir(mutant_parent)
      mutant_part = File.join(mutant_parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
        mutant_part, "pk", W164_SIMPLE_AGGREGATE_KEYS.to_unsafe.to_slice(W164_SIMPLE_AGGREGATE_KEYS.size), "v",
        W164_SIMPLE_AGGREGATE_VALUE_MUTANT_UINT128.to_unsafe.to_slice(W164_SIMPLE_AGGREGATE_VALUE_MUTANT_UINT128.size),
        CrystalClick::BinarySimpleAggregateType::Function::Min, rows_per_mark: 2
      )
      mutant = CrystalClick::WidePart.open_typed(mutant_part, "v")
      mutant.column_type.should eq("SimpleAggregateFunction(min, UInt128)")
      w164_assert_values(mutant.read_simple_aggregate_numeric_mark_range("v", 0, mutant.mark_count, UInt128),
        W164_SIMPLE_AGGREGATE_VALUE_MUTANT_UINT128, "min/UInt128 changed-payload fixture")
      puts "PASS W164 separately authored min/UInt128 value mutant differs by one literal bit"
    end
  end
end
