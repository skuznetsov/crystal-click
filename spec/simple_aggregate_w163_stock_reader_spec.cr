require "./spec_helper"
require "file_utils"
require "./support/simple_aggregate_w163_types"

private def w163_assert(condition : Bool, message : String) : Nil
  raise message unless condition
end

private def w163_u64_bytes(values : Array(UInt64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    8.times { |index| bytes << ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w163_numeric_value_bytes(value : UInt8) : Array(UInt8)
  [value]
end

private def w163_numeric_value_bytes(value : UInt16) : Array(UInt8)
  bits = value.to_u64
  Array(UInt8).new(2) { |index| ((bits >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w163_numeric_value_bytes(value : UInt32) : Array(UInt8)
  bits = value.to_u64
  Array(UInt8).new(4) { |index| ((bits >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w163_numeric_value_bytes(value : UInt64) : Array(UInt8)
  Array(UInt8).new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w163_numeric_value_bytes(value : Int8) : Array(UInt8)
  [value.unsafe_as(UInt8)]
end

private def w163_numeric_value_bytes(value : Int16) : Array(UInt8)
  bits = value.unsafe_as(UInt16).to_u64
  Array(UInt8).new(2) { |index| ((bits >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w163_numeric_value_bytes(value : Int32) : Array(UInt8)
  bits = value.unsafe_as(UInt32).to_u64
  Array(UInt8).new(4) { |index| ((bits >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w163_numeric_value_bytes(value : Int64) : Array(UInt8)
  bits = value.unsafe_as(UInt64)
  Array(UInt8).new(8) { |index| ((bits >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w163_numeric_value_bytes(value : Float32) : Array(UInt8)
  bits = value.unsafe_as(UInt32).to_u64
  Array(UInt8).new(4) { |index| ((bits >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w163_numeric_value_bytes(value : Float64) : Array(UInt8)
  bits = value.unsafe_as(UInt64)
  Array(UInt8).new(8) { |index| ((bits >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w163_numeric_bytes(values : Array(T)) : Array(UInt8) forall T
  values.flat_map { |value| w163_numeric_value_bytes(value) }
end

private def w163_nullable_numeric_bytes(values : Array(T?)) : Array(UInt8) forall T
  bytes = [] of UInt8
  values.each do |value|
    if value.nil?
      bytes.concat(Array(UInt8).new(sizeof(T), 0_u8))
    else
      bytes.concat(w163_numeric_value_bytes(value.not_nil!))
    end
  end
  bytes
end

private def w163_same_value_bits(actual : T, expected : T) : Bool forall T
  actual == expected
end

private def w163_same_value_bits(actual : Float32, expected : Float32) : Bool
  actual.unsafe_as(UInt32) == expected.unsafe_as(UInt32)
end

private def w163_same_value_bits(actual : Float64, expected : Float64) : Bool
  actual.unsafe_as(UInt64) == expected.unsafe_as(UInt64)
end

private def w163_assert_values(actual : Array(T), expected : Array(T), label : String) : Nil forall T
  w163_assert(actual.size == expected.size, "#{label}: row count differs (#{actual.size} != #{expected.size})")
  actual.each_with_index do |value, index|
    w163_assert(w163_same_value_bits(value, expected[index]), "#{label}: value bits differ at row #{index}")
  end
end

private def w163_assert_nullable_values(actual : Array(T?), expected : Array(T?), label : String) : Nil forall T
  w163_assert(actual.size == expected.size, "#{label}: row count differs (#{actual.size} != #{expected.size})")
  actual.each_with_index do |value, index|
    wanted = expected[index]
    w163_assert(value.nil? == wanted.nil?, "#{label}: nullness differs at row #{index}")
    unless value.nil?
      w163_assert(w163_same_value_bits(value.not_nil!, wanted.not_nil!), "#{label}: value bits differ at row #{index}")
    end
  end
end

private def w163_stream_bytes(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w163_mark_rows(part : String, logical_name : String) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  bytes = File.read(path).to_slice
  w163_assert(bytes.size % CrystalClick::WidePart::MARK_SIZE == 0, "#{logical_name}: malformed mrk2 size")
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |mark|
    offset = mark * CrystalClick::WidePart::MARK_SIZE + 16
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end
end

private def w163_check_layout(
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
  w163_assert(File.read(File.join(part, "columns.txt")) ==
              "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{type}\n",
    "#{type}: exact columns metadata differs")

  value_streams = nullable ? ["v.null", "v"] : ["v"]
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "#{value_streams.size} substreams for column `v`:\n" + value_streams.map { |name| "\t#{name}\n" }.join
  w163_assert(File.read(File.join(part, "columns_substreams.txt")) == expected_substreams,
    "#{type}: exact substream metadata differs")
  w163_assert(File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)", "#{type}: LZ4 metadata differs")
  w163_assert(File.read(File.join(part, "serialization.json")) ==
              "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}",
    "#{type}: exact serialization metadata differs")
  w163_assert(File.read(File.join(part, "count.txt")) == row_count.to_s, "#{type}: row count metadata differs")
  w163_assert(File.read(File.join(part, "metadata_version.txt")) == "0", "#{type}: metadata version differs")

  w163_assert(w163_stream_bytes(part, "pk") == w163_u64_bytes(keys), "#{type}: UInt64 key bytes differ")
  value_bytes = w163_stream_bytes(part, "v")
  expected_value_bytes = nullable ? w163_nullable_numeric_bytes(nullable_values) : w163_numeric_bytes(values)
  w163_assert(value_bytes == expected_value_bytes, "#{type}: exact little-endian fixed-width child bytes differ")
  if nullable
    expected_null_map = nullable_values.map { |value| value.nil? ? 1_u8 : 0_u8 }
    w163_assert(w163_stream_bytes(part, "v.null") == expected_null_map, "#{type}: Nullable null-map bytes differ")
  end

  streams = nullable ? ["pk", "v.null", "v"] : ["pk", "v"]
  streams.each do |stream|
    w163_assert(w163_mark_rows(part, stream) == [2_u64, 2_u64, 2_u64, 0_u64], "#{type}: #{stream} mark grid differs")
  end
end

private def w163_check_stock_profile(
  stock_part : String,
  function_name : String,
  function_suffix : String,
  carrier_name : String,
  carrier_suffix : String,
  stock_values : Array(T),
) : Nil forall T
  nullable_values = W163SimpleAggregateTestSupport.nullable_values(stock_values)
  column_suffix = "#{function_suffix}_#{carrier_suffix}"
  scalar_column = "s_#{column_suffix}"
  nullable_column = "n_#{column_suffix}"
  scalar_type = "SimpleAggregateFunction(#{function_name}, #{carrier_name})"
  nullable_type = "Nullable(#{scalar_type})"

  scalar = CrystalClick::WidePart.open_typed(stock_part, scalar_column)
  scalar.column_type.should eq(scalar_type)
  scalar.row_count.should eq(6_u64)
  scalar.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
  w163_assert_values(scalar.read_simple_aggregate_numeric_mark_range(scalar_column, 0, scalar.mark_count, T), stock_values, "#{scalar_type} full stock read")
  w163_assert_values(scalar.read_simple_aggregate_numeric_mark_range(scalar_column, 1, 1, T), stock_values[2, 2], "#{scalar_type} middle stock read")
  w163_assert(w163_stream_bytes(stock_part, scalar_column) == w163_numeric_bytes(stock_values), "#{scalar_type}: stock child-stream bytes differ from independent little-endian literals")
  expect_raises(CrystalClick::BoundsError) do
    scalar.read_simple_aggregate_numeric_mark_range(scalar_column, 0, 0, T)
  end
  expect_raises(CrystalClick::UnsupportedFormatError) do
    scalar.read_numeric_mark_range(scalar_column, 0, scalar.mark_count, T)
  end

  nullable = CrystalClick::WidePart.open_typed(stock_part, nullable_column)
  nullable.column_type.should eq(nullable_type)
  nullable.row_count.should eq(6_u64)
  nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
  w163_assert_nullable_values(nullable.read_nullable_simple_aggregate_numeric_mark_range(nullable_column, 0, nullable.mark_count, T), nullable_values, "#{nullable_type} full stock read")
  w163_assert_nullable_values(nullable.read_nullable_simple_aggregate_numeric_mark_range(nullable_column, 1, 1, T), nullable_values[2, 2], "#{nullable_type} middle stock read")
  w163_assert(w163_stream_bytes(stock_part, nullable_column) == w163_nullable_numeric_bytes(nullable_values), "#{nullable_type}: stock child-stream bytes differ from independent little-endian literals")
  expect_raises(CrystalClick::BoundsError) do
    nullable.read_nullable_simple_aggregate_numeric_mark_range(nullable_column, 0, 0, T)
  end
  expect_raises(CrystalClick::UnsupportedFormatError) do
    nullable.read_nullable_numeric_mark_range(nullable_column, 0, nullable.mark_count, T)
  end

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
  observed_keys.should eq(W163_SIMPLE_AGGREGATE_KEYS)
  w163_assert_values(observed_scalar, stock_values, "#{scalar_type} table stock read")
  w163_assert_nullable_values(observed_nullable, nullable_values, "#{nullable_type} table stock read")
  observed_marks.should eq([0, 0, 1, 1, 2, 2])

  empty_callbacks = 0
  table.scan_typed_window(table.total_row_count, 1) { |_batch| empty_callbacks += 1; nil }
  empty_callbacks.should eq(0)
end

private def w163_write_library_profile(
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
  keys = W163_SIMPLE_AGGREGATE_KEYS
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

  w163_check_layout(scalar_part, function_name, carrier_name, false, values.size, keys, values, nullable_values)
  w163_check_layout(nullable_part, function_name, carrier_name, true, values.size, keys, values, nullable_values)

  scalar = CrystalClick::WidePart.open_typed(scalar_part, "v")
  scalar.column_type.should eq("SimpleAggregateFunction(#{function_name}, #{carrier_name})")
  w163_assert_values(scalar.read_simple_aggregate_numeric_mark_range("v", 0, scalar.mark_count, T), values, "#{base_type} full writer read")
  w163_assert_values(scalar.read_simple_aggregate_numeric_mark_range("v", 1, 1, T), values[2, 2], "#{base_type} middle writer read")

  nullable = CrystalClick::WidePart.open_typed(nullable_part, "v")
  nullable.column_type.should eq("Nullable(SimpleAggregateFunction(#{function_name}, #{carrier_name}))")
  w163_assert_nullable_values(nullable.read_nullable_simple_aggregate_numeric_mark_range("v", 0, nullable.mark_count, T), nullable_values, "Nullable(#{base_type}) full writer read")
  w163_assert_nullable_values(nullable.read_nullable_simple_aggregate_numeric_mark_range("v", 1, 1, T), nullable_values[2, 2], "Nullable(#{base_type}) middle writer read")

  table = CrystalClick::WidePartTable.open_selected_typed([scalar_part], ["pk", "v"])
  observed = [] of T
  table.scan_typed(batch_rows: 2) do |batch|
    observed.concat(batch.simple_aggregate_values_for("v", T).to_a)
  end
  w163_assert_values(observed, values, "#{base_type} table writer read")

  nullable_table = CrystalClick::WidePartTable.open_selected_typed([nullable_part], ["pk", "v"])
  observed_nullable = [] of T?
  nullable_table.scan_typed(batch_rows: 2) do |batch|
    observed_nullable.concat(batch.nullable_simple_aggregate_values_for("v", T).to_a)
  end
  w163_assert_nullable_values(observed_nullable, nullable_values, "Nullable(#{base_type}) table writer read")

  puts "PASS W163 library writer #{function_name}/#{carrier_name}: scalar and outer Nullable exact metadata and typed readback"
end

private def w163_write_carrier(
  part_root : String,
  carrier_name : String,
  carrier_suffix : String,
  values : Array(T),
) : Int32 forall T
  nullable_values = W163SimpleAggregateTestSupport.nullable_values(values)
  profiles = W163SimpleAggregateTestSupport.profiles_for(carrier_name)
  profiles.each do |function_name, function_suffix, function|
    w163_write_library_profile(
      part_root, function_name, function_suffix, function,
      carrier_name, carrier_suffix, values, nullable_values
    )
  end
  profiles.size
end

if stock_part = ENV["W163_SIMPLE_AGGREGATE_STOCK_WIDE_PART"]?
  describe "W163 literal stock/library SimpleAggregateFunction numeric oracle" do
    it "reads every stock-authored scalar and outer Nullable profile using typed numeric APIs" do
      profile_count = 0
      W163_SIMPLE_AGGREGATE_FUNCTIONS_BY_CARRIER.each_key do |carrier_name|
        profiles = W163SimpleAggregateTestSupport.profiles_for(carrier_name)
        profile_count += profiles.size
        case carrier_name
        when "UInt8"
          profiles.each { |name, suffix, _function| w163_check_stock_profile(stock_part, name, suffix, carrier_name, "u8", W163_STOCK_UINT8_VALUES) }
        when "UInt16"
          profiles.each { |name, suffix, _function| w163_check_stock_profile(stock_part, name, suffix, carrier_name, "u16", W163_STOCK_UINT16_VALUES) }
        when "UInt32"
          profiles.each { |name, suffix, _function| w163_check_stock_profile(stock_part, name, suffix, carrier_name, "u32", W163_STOCK_UINT32_VALUES) }
        when "UInt64"
          profiles.each { |name, suffix, _function| w163_check_stock_profile(stock_part, name, suffix, carrier_name, "u64", W163_STOCK_UINT64_VALUES) }
        when "Int8"
          profiles.each { |name, suffix, _function| w163_check_stock_profile(stock_part, name, suffix, carrier_name, "i8", W163_STOCK_INT8_VALUES) }
        when "Int16"
          profiles.each { |name, suffix, _function| w163_check_stock_profile(stock_part, name, suffix, carrier_name, "i16", W163_STOCK_INT16_VALUES) }
        when "Int32"
          profiles.each { |name, suffix, _function| w163_check_stock_profile(stock_part, name, suffix, carrier_name, "i32", W163_STOCK_INT32_VALUES) }
        when "Int64"
          profiles.each { |name, suffix, _function| w163_check_stock_profile(stock_part, name, suffix, carrier_name, "i64", W163_STOCK_INT64_VALUES) }
        when "Float32"
          profiles.each { |name, suffix, _function| w163_check_stock_profile(stock_part, name, suffix, carrier_name, "f32", W163_STOCK_FLOAT32_VALUES) }
        when "Float64"
          profiles.each { |name, suffix, _function| w163_check_stock_profile(stock_part, name, suffix, carrier_name, "f64", W163_STOCK_FLOAT64_VALUES) }
        else
          raise "W163 has no literal stock fixture for #{carrier_name}"
        end
      end
      profile_count.should eq(W163_SIMPLE_AGGREGATE_EXPECTED_SCALAR_PROFILES)
    end

    it "writes every library-authored whole-part profile using typed public writers" do
      part_root = ENV["W163_PART_ROOT"]? || raise "W163_PART_ROOT is required"
      Dir.mkdir(part_root) unless Dir.exists?(part_root)
      generated_profiles = 0
      generated_profiles += w163_write_carrier(part_root, "UInt8", "u8", W163_LIBRARY_UINT8_VALUES)
      generated_profiles += w163_write_carrier(part_root, "UInt16", "u16", W163_LIBRARY_UINT16_VALUES)
      generated_profiles += w163_write_carrier(part_root, "UInt32", "u32", W163_LIBRARY_UINT32_VALUES)
      generated_profiles += w163_write_carrier(part_root, "UInt64", "u64", W163_LIBRARY_UINT64_VALUES)
      generated_profiles += w163_write_carrier(part_root, "Int8", "i8", W163_LIBRARY_INT8_VALUES)
      generated_profiles += w163_write_carrier(part_root, "Int16", "i16", W163_LIBRARY_INT16_VALUES)
      generated_profiles += w163_write_carrier(part_root, "Int32", "i32", W163_LIBRARY_INT32_VALUES)
      generated_profiles += w163_write_carrier(part_root, "Int64", "i64", W163_LIBRARY_INT64_VALUES)
      generated_profiles += w163_write_carrier(part_root, "Float32", "f32", W163_LIBRARY_FLOAT32_VALUES)
      generated_profiles += w163_write_carrier(part_root, "Float64", "f64", W163_LIBRARY_FLOAT64_VALUES)
      generated_profiles.should eq(W163_SIMPLE_AGGREGATE_EXPECTED_SCALAR_PROFILES)

      mutant_parent = File.join(part_root, "scalar_min_u64_value_mutant")
      Dir.mkdir(mutant_parent)
      mutant_part = File.join(mutant_parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
        mutant_part, "pk", W163_SIMPLE_AGGREGATE_KEYS.to_unsafe.to_slice(W163_SIMPLE_AGGREGATE_KEYS.size), "v",
        W163_SIMPLE_AGGREGATE_VALUE_MUTANT_UINT64.to_unsafe.to_slice(W163_SIMPLE_AGGREGATE_VALUE_MUTANT_UINT64.size),
        CrystalClick::BinarySimpleAggregateType::Function::Min, rows_per_mark: 2
      )
      mutant = CrystalClick::WidePart.open_typed(mutant_part, "v")
      mutant.column_type.should eq("SimpleAggregateFunction(min, UInt64)")
      w163_assert_values(mutant.read_simple_aggregate_numeric_mark_range("v", 0, mutant.mark_count, UInt64), W163_SIMPLE_AGGREGATE_VALUE_MUTANT_UINT64, "min/UInt64 value mutant readback")
      puts "PASS W163 separate min/UInt64 raw-value mutant: only first literal payload differs"
    end
  end
end
