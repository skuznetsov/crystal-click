require "./spec_helper"
require "file_utils"
require "./support/simple_aggregate_w168_types"

private def w168_assert(condition : Bool, message : String) : Nil
  raise message unless condition
end

private def w168_u64_bytes(values : Array(UInt64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    8.times { |index| bytes << ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w168_string_size_bytes(values : Array(String)) : Array(UInt8)
  w168_u64_bytes(values.map { |value| value.bytesize.to_u64 })
end

private def w168_nullable_string_size_bytes(values : Array(String?)) : Array(UInt8)
  w168_u64_bytes(values.map { |value| value ? value.bytesize.to_u64 : 0_u64 })
end

private def w168_raw_strings(values : Array(String)) : Array(UInt8)
  bytes = [] of UInt8
  values.each { |value| bytes.concat(value.to_slice.to_a) }
  bytes
end

private def w168_raw_nullable_strings(values : Array(String?)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    bytes.concat(value.to_slice.to_a) if value
  end
  bytes
end

private def w168_fixed_value_bytes(value : String, width : Int32) : Array(UInt8)
  w168_assert(value.bytesize <= width, "FixedString fixture exceeds declared width #{width}")
  bytes = Array(UInt8).new(width, 0_u8)
  value.to_slice.copy_to(bytes.to_unsafe.to_slice(bytes.size)) unless value.empty?
  bytes
end

private def w168_padded_fixed_string(value : String, width : Int32) : String
  w168_assert(value.bytesize <= width, "FixedString fixture exceeds declared width #{width}")
  bytes = Bytes.new(width, 0_u8)
  value.to_slice.copy_to(bytes[0, value.bytesize]) unless value.empty?
  String.new(bytes)
end

private def w168_raw_fixed_strings(values : Array(String), width : Int32) : Array(UInt8)
  bytes = [] of UInt8
  values.each { |value| bytes.concat(w168_fixed_value_bytes(value, width)) }
  bytes
end

private def w168_raw_nullable_fixed_strings(values : Array(String?), width : Int32) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    if value
      bytes.concat(w168_fixed_value_bytes(value, width))
    else
      bytes.concat(Array(UInt8).new(width, 0_u8))
    end
  end
  bytes
end

private def w168_stream_bytes(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w168_mark_rows(part : String, logical_name : String) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  bytes = File.read(path).to_slice
  w168_assert(bytes.size % CrystalClick::WidePart::MARK_SIZE == 0, "#{logical_name}: malformed mrk2 size")
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |mark|
    offset = mark * CrystalClick::WidePart::MARK_SIZE + 16
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end
end

private def w168_assert_strings(actual : Array(String), expected : Array(String), label : String) : Nil
  w168_assert(actual.size == expected.size, "#{label}: row count differs (#{actual.size} != #{expected.size})")
  actual.each_with_index do |value, index|
    w168_assert(value.to_slice == expected[index].to_slice, "#{label}: raw string bytes differ at row #{index}")
  end
end

private def w168_assert_nullable_strings(actual : Array(String?), expected : Array(String?), label : String) : Nil
  w168_assert(actual.size == expected.size, "#{label}: row count differs (#{actual.size} != #{expected.size})")
  actual.each_with_index do |value, index|
    wanted = expected[index]
    w168_assert(value.nil? == wanted.nil?, "#{label}: NULL position differs at row #{index}")
    unless value.nil?
      w168_assert(value.to_slice == wanted.not_nil!.to_slice, "#{label}: raw nullable string bytes differ at row #{index}")
    end
  end
end

private def w168_carrier_suffix(carrier : String) : String
  case carrier
  when "String"           then "string"
  when "FixedString(1)"   then "fixed1"
  when "FixedString(3)"   then "fixed3"
  when "FixedString(130)" then "fixed130"
  else
    raise ArgumentError.new("unknown W168 carrier #{carrier}")
  end
end

private def w168_type(function_name : String, carrier_name : String, nullable : Bool) : String
  inner = "SimpleAggregateFunction(#{function_name}, #{carrier_name})"
  nullable ? "Nullable(#{inner})" : inner
end

private def w168_assert_layout(
  part : String,
  function_name : String,
  carrier_name : String,
  nullable : Bool,
  width : Int32?,
  keys : Array(UInt64),
  values : Array(String),
  nullable_values : Array(String?),
) : Nil
  declared_type = w168_type(function_name, carrier_name, nullable)
  File.read(File.join(part, "columns.txt")).should eq(
    "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{declared_type}\n"
  )

  value_streams = if nullable
                    width ? ["v.null", "v"] : ["v.null", "v.size", "v"]
                  else
                    width ? ["v"] : ["v.size", "v"]
                  end
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "#{value_streams.size} substreams for column `v`:\n" + value_streams.map { |name| "\t#{name}\n" }.join
  File.read(File.join(part, "columns_substreams.txt")).should eq(expected_substreams)
  File.read(File.join(part, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
  serialization_versions = nullable ? "\"nullable\":0,\"string\":1" : "\"string\":1"
  File.read(File.join(part, "serialization.json")).should eq(
    "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true," +
    "\"types_serialization_versions\":{#{serialization_versions}},\"version\":1}"
  )
  File.read(File.join(part, "count.txt")).should eq(keys.size.to_s)
  File.read(File.join(part, "metadata_version.txt")).should eq("0")
  w168_stream_bytes(part, "pk").should eq(w168_u64_bytes(keys))

  if width
    if nullable
      w168_stream_bytes(part, "v").should eq(w168_raw_nullable_fixed_strings(nullable_values, width))
      w168_stream_bytes(part, "v.null").should eq(nullable_values.map { |value| value.nil? ? 1_u8 : 0_u8 })
      streams = ["pk", "v.null", "v"]
    else
      w168_stream_bytes(part, "v").should eq(w168_raw_fixed_strings(values, width))
      streams = ["pk", "v"]
    end
  else
    if nullable
      w168_stream_bytes(part, "v.size").should eq(w168_nullable_string_size_bytes(nullable_values))
      w168_stream_bytes(part, "v").should eq(w168_raw_nullable_strings(nullable_values))
      w168_stream_bytes(part, "v.null").should eq(nullable_values.map { |value| value.nil? ? 1_u8 : 0_u8 })
      streams = ["pk", "v.null", "v.size", "v"]
    else
      w168_stream_bytes(part, "v.size").should eq(w168_string_size_bytes(values))
      w168_stream_bytes(part, "v").should eq(w168_raw_strings(values))
      streams = ["pk", "v.size", "v"]
    end
  end
  streams.each { |stream| w168_mark_rows(part, stream).should eq([2_u64, 2_u64, 2_u64, 0_u64]) }

  checksums = CrystalClick::PartChecksums.open(part)
  expected_checksums = ["count.txt", "primary.idx", "serialization.json"] of String
  streams.each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    expected_checksums << "#{base}.bin"
    expected_checksums << "#{base}.mrk2"
  end
  checksums.entries.keys.sort.should eq(expected_checksums.sort)
  expected_files = expected_checksums + [
    "checksums.txt", "columns.txt", "columns_substreams.txt",
    "default_compression_codec.txt", "metadata_version.txt",
  ]
  Dir.children(part).sort.should eq(expected_files.sort)
  checksums.entries.each_key do |name|
    checksums.validate_selected_entries(part, name).should eq(CrystalClick::ChecksumVerification::SizeChecked)
  end
end

private def w168_check_stock_profile(
  stock_part : String,
  function_name : String,
  function_suffix : String,
  carrier_name : String,
  values : Array(String),
) : Nil
  carrier_suffix = w168_carrier_suffix(carrier_name)
  width = W168SimpleAggregateTestSupport.width_for(carrier_name)
  nullable_values = W168SimpleAggregateTestSupport.nullable_values(values)
  suffix = "#{function_suffix}_#{carrier_suffix}"
  scalar_column = "s_#{suffix}"
  nullable_column = "n_#{suffix}"
  scalar_type = w168_type(function_name, carrier_name, false)
  nullable_type = w168_type(function_name, carrier_name, true)

  scalar = CrystalClick::WidePart.open_typed(stock_part, scalar_column)
  scalar.column_type.should eq(scalar_type)
  scalar.row_count.should eq(6_u64)
  scalar.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
  if width
    w168_assert_strings(scalar.read_simple_aggregate_fixed_string_mark_range(scalar_column, 0, scalar.mark_count), values,
      "#{scalar_type} full stock read")
    w168_assert_strings(scalar.read_simple_aggregate_fixed_string_mark_range(scalar_column, 1, 1), values[2, 2],
      "#{scalar_type} middle stock read")
    w168_stream_bytes(stock_part, scalar_column).should eq(w168_raw_fixed_strings(values, width))
  else
    w168_assert_strings(scalar.read_simple_aggregate_string_mark_range(scalar_column, 0, scalar.mark_count), values,
      "#{scalar_type} full stock read")
    w168_assert_strings(scalar.read_simple_aggregate_string_mark_range(scalar_column, 1, 1), values[2, 2],
      "#{scalar_type} middle stock read")
    w168_stream_bytes(stock_part, "#{scalar_column}.size").should eq(w168_string_size_bytes(values))
    w168_stream_bytes(stock_part, scalar_column).should eq(w168_raw_strings(values))
  end

  nullable = CrystalClick::WidePart.open_typed(stock_part, nullable_column)
  nullable.column_type.should eq(nullable_type)
  nullable.row_count.should eq(6_u64)
  nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
  if width
    w168_assert_nullable_strings(
      nullable.read_nullable_simple_aggregate_fixed_string_mark_range(nullable_column, 0, nullable.mark_count),
      nullable_values, "#{nullable_type} full stock read"
    )
    w168_assert_nullable_strings(
      nullable.read_nullable_simple_aggregate_fixed_string_mark_range(nullable_column, 1, 1),
      nullable_values[2, 2], "#{nullable_type} middle stock read"
    )
    w168_stream_bytes(stock_part, nullable_column).should eq(w168_raw_nullable_fixed_strings(nullable_values, width))
  else
    w168_assert_nullable_strings(
      nullable.read_nullable_simple_aggregate_string_mark_range(nullable_column, 0, nullable.mark_count),
      nullable_values, "#{nullable_type} full stock read"
    )
    w168_assert_nullable_strings(
      nullable.read_nullable_simple_aggregate_string_mark_range(nullable_column, 1, 1),
      nullable_values[2, 2], "#{nullable_type} middle stock read"
    )
    w168_stream_bytes(stock_part, "#{nullable_column}.size").should eq(w168_nullable_string_size_bytes(nullable_values))
    w168_stream_bytes(stock_part, nullable_column).should eq(w168_raw_nullable_strings(nullable_values))
  end
  w168_stream_bytes(stock_part, "#{nullable_column}.null").should eq(nullable_values.map { |value| value.nil? ? 1_u8 : 0_u8 })
  w168_stream_bytes(stock_part, "pk").should eq(w168_u64_bytes(W168_SIMPLE_AGGREGATE_KEYS))

  table = CrystalClick::WidePartTable.open_selected_typed([stock_part], ["pk", scalar_column, nullable_column])
  observed_keys = [] of UInt64
  observed_scalar = [] of String
  observed_nullable = [] of String?
  observed_marks = [] of Int32
  table.scan_typed(batch_rows: 2) do |batch|
    keys = batch.values_for("pk", UInt64)
    observed_keys.concat(keys.to_a)
    observed_marks.concat(Array(Int32).new(keys.size, batch.mark_index))
    if width
      observed_scalar.concat(batch.simple_aggregate_fixed_strings_for(scalar_column).to_a)
      observed_nullable.concat(batch.nullable_simple_aggregate_fixed_strings_for(nullable_column).to_a)
    else
      observed_scalar.concat(batch.simple_aggregate_strings_for(scalar_column).to_a)
      observed_nullable.concat(batch.nullable_simple_aggregate_strings_for(nullable_column).to_a)
    end
  end
  observed_keys.should eq(W168_SIMPLE_AGGREGATE_KEYS)
  w168_assert_strings(observed_scalar, values, "#{scalar_type} stock batch read")
  w168_assert_nullable_strings(observed_nullable, nullable_values, "#{nullable_type} stock batch read")
  observed_marks.should eq([0, 0, 1, 1, 2, 2])
  empty_callbacks = 0
  table.scan_typed_window(table.total_row_count, 1) { |_batch| empty_callbacks += 1 }
  empty_callbacks.should eq(0)
end

private def w168_check_library_profile(
  scalar_part : String,
  nullable_part : String,
  function_name : String,
  carrier_name : String,
  values : Array(String),
) : Nil
  width = W168SimpleAggregateTestSupport.width_for(carrier_name)
  nullable_values = W168SimpleAggregateTestSupport.nullable_values(values)
  read_values = width ? values.map { |value| w168_padded_fixed_string(value, width) } : values
  read_nullable_values = W168SimpleAggregateTestSupport.nullable_values(read_values)
  scalar_type = w168_type(function_name, carrier_name, false)
  nullable_type = w168_type(function_name, carrier_name, true)
  w168_assert_layout(scalar_part, function_name, carrier_name, false, width, W168_SIMPLE_AGGREGATE_KEYS, values, nullable_values)
  w168_assert_layout(nullable_part, function_name, carrier_name, true, width, W168_SIMPLE_AGGREGATE_KEYS, values, nullable_values)

  scalar = CrystalClick::WidePart.open_typed(scalar_part, "v")
  scalar.column_type.should eq(scalar_type)
  if width
    w168_assert_strings(scalar.read_simple_aggregate_fixed_string_mark_range("v", 0, scalar.mark_count), read_values,
      "#{scalar_type} full library read")
    w168_assert_strings(scalar.read_simple_aggregate_fixed_string_mark_range("v", 1, 1), read_values[2, 2],
      "#{scalar_type} middle library read")
  else
    w168_assert_strings(scalar.read_simple_aggregate_string_mark_range("v", 0, scalar.mark_count), read_values,
      "#{scalar_type} full library read")
    w168_assert_strings(scalar.read_simple_aggregate_string_mark_range("v", 1, 1), read_values[2, 2],
      "#{scalar_type} middle library read")
  end

  nullable = CrystalClick::WidePart.open_typed(nullable_part, "v")
  nullable.column_type.should eq(nullable_type)
  if width
    w168_assert_nullable_strings(
      nullable.read_nullable_simple_aggregate_fixed_string_mark_range("v", 0, nullable.mark_count), read_nullable_values,
      "#{nullable_type} full library read"
    )
    w168_assert_nullable_strings(
      nullable.read_nullable_simple_aggregate_fixed_string_mark_range("v", 1, 1), read_nullable_values[2, 2],
      "#{nullable_type} middle library read"
    )
  else
    w168_assert_nullable_strings(
      nullable.read_nullable_simple_aggregate_string_mark_range("v", 0, nullable.mark_count), read_nullable_values,
      "#{nullable_type} full library read"
    )
    w168_assert_nullable_strings(
      nullable.read_nullable_simple_aggregate_string_mark_range("v", 1, 1), read_nullable_values[2, 2],
      "#{nullable_type} middle library read"
    )
  end

  table = CrystalClick::WidePartTable.open_selected_typed([scalar_part], ["pk", "v"])
  observed_keys = [] of UInt64
  observed = [] of String
  table.scan_typed(batch_rows: 2) do |batch|
    observed_keys.concat(batch.values_for("pk", UInt64).to_a)
    if width
      observed.concat(batch.simple_aggregate_fixed_strings_for("v").to_a)
    else
      observed.concat(batch.simple_aggregate_strings_for("v").to_a)
    end
  end
  observed_keys.should eq(W168_SIMPLE_AGGREGATE_KEYS)
  w168_assert_strings(observed, read_values, "#{scalar_type} library batch read")

  nullable_table = CrystalClick::WidePartTable.open_selected_typed([nullable_part], ["pk", "v"])
  observed_nullable = [] of String?
  observed_nullable_keys = [] of UInt64
  nullable_table.scan_typed(batch_rows: 2) do |batch|
    observed_nullable_keys.concat(batch.values_for("pk", UInt64).to_a)
    if width
      observed_nullable.concat(batch.nullable_simple_aggregate_fixed_strings_for("v").to_a)
    else
      observed_nullable.concat(batch.nullable_simple_aggregate_strings_for("v").to_a)
    end
  end
  observed_nullable_keys.should eq(W168_SIMPLE_AGGREGATE_KEYS)
  w168_assert_nullable_strings(observed_nullable, read_nullable_values, "#{nullable_type} library batch read")
end

private def w168_write_library_pair(
  part_root : String,
  scalar_label : String,
  nullable_label : String,
  function_name : String,
  carrier_name : String,
  function : CrystalClick::BinarySimpleAggregateType::Function,
  values : Array(String),
) : {String, String}
  width = W168SimpleAggregateTestSupport.width_for(carrier_name)
  nullable_values = W168SimpleAggregateTestSupport.nullable_values(values)
  scalar_parent = File.join(part_root, scalar_label)
  nullable_parent = File.join(part_root, nullable_label)
  Dir.mkdir(scalar_parent)
  Dir.mkdir(nullable_parent)
  scalar_part = File.join(scalar_parent, "all_1_1_0")
  nullable_part = File.join(nullable_parent, "all_1_1_0")
  keys = W168_SIMPLE_AGGREGATE_KEYS

  if width
    CrystalClick::WidePartWriter.write_uint64_simple_aggregate_fixed_string_pair(
      scalar_part, "pk", keys.to_unsafe.to_slice(keys.size), "v",
      values.to_unsafe.to_slice(values.size), width, function, rows_per_mark: 2
    )
    CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_fixed_string_pair(
      nullable_part, "pk", keys.to_unsafe.to_slice(keys.size), "v",
      nullable_values.to_unsafe.to_slice(nullable_values.size), width, function, rows_per_mark: 2
    )
  else
    CrystalClick::WidePartWriter.write_uint64_simple_aggregate_string_pair(
      scalar_part, "pk", keys.to_unsafe.to_slice(keys.size), "v",
      values.to_unsafe.to_slice(values.size), function, rows_per_mark: 2
    )
    CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_string_pair(
      nullable_part, "pk", keys.to_unsafe.to_slice(keys.size), "v",
      nullable_values.to_unsafe.to_slice(nullable_values.size), function, rows_per_mark: 2
    )
  end

  w168_check_library_profile(scalar_part, nullable_part, function_name, carrier_name, values)
  {scalar_part, nullable_part}
end

if stock_part = ENV["W168_SIMPLE_AGGREGATE_STOCK_WIDE_PART"]?
  describe "W168 literal stock/library SimpleAggregateFunction text oracle" do
    it "reads all stock-authored scalar and outer Nullable profiles with exact physical bytes" do
      profile_count = 0
      W168_SIMPLE_AGGREGATE_CARRIERS.each do |carrier_name|
        values = W168SimpleAggregateTestSupport.values(carrier_name, native: true)
        W168SimpleAggregateTestSupport.profiles.each do |function_name, function_suffix, _function|
          profile_count += 1
          w168_check_stock_profile(stock_part, function_name, function_suffix, carrier_name, values)
        end
      end
      profile_count.should eq(W168_SIMPLE_AGGREGATE_EXPECTED_SCALAR_PROFILES)
    end

    it "writes independently authored complete scalar and outer Nullable profiles" do
      part_root = ENV["W168_PART_ROOT"]? || raise "W168_PART_ROOT is required"
      Dir.mkdir(part_root) unless Dir.exists?(part_root)
      generated = 0
      W168_SIMPLE_AGGREGATE_CARRIERS.each do |carrier_name|
        carrier_suffix = w168_carrier_suffix(carrier_name)
        values = W168SimpleAggregateTestSupport.values(carrier_name, native: false)
        W168SimpleAggregateTestSupport.profiles.each do |function_name, function_suffix, function|
          scalar_label = "scalar_#{function_suffix}_#{carrier_suffix}"
          nullable_label = "nullable_#{function_suffix}_#{carrier_suffix}"
          w168_write_library_pair(part_root, scalar_label, nullable_label, function_name, carrier_name, function, values)
          generated += 1
        end
      end
      generated.should eq(W168_SIMPLE_AGGREGATE_EXPECTED_SCALAR_PROFILES)

      changed_string_values = W168SimpleAggregateTestSupport.values("String", native: false).dup
      changed_string_values[0] = "M"
      mutant_scalar, _mutant_nullable = w168_write_library_pair(
        part_root, "scalar_min_string_value_mutant", "nullable_min_string_value_mutant",
        "min", "String", CrystalClick::BinarySimpleAggregateType::Function::Min, changed_string_values
      )
      w168_assert_layout(
        mutant_scalar, "min", "String", false, nil, W168_SIMPLE_AGGREGATE_KEYS,
        changed_string_values, W168SimpleAggregateTestSupport.nullable_values(changed_string_values)
      )

      fixed_values = W168SimpleAggregateTestSupport.values("FixedString(3)", native: false)
      shifted_nullable = W168SimpleAggregateTestSupport.nullable_values(fixed_values)
      shifted_nullable[3] = fixed_values[3]
      shifted_nullable[1] = nil
      shifted_scalar_parent = File.join(part_root, "scalar_min_fixed3_nullmap_mutant")
      shifted_nullable_parent = File.join(part_root, "nullable_min_fixed3_nullmap_mutant")
      Dir.mkdir(shifted_scalar_parent)
      Dir.mkdir(shifted_nullable_parent)
      shifted_scalar = File.join(shifted_scalar_parent, "all_1_1_0")
      shifted_nullable_part = File.join(shifted_nullable_parent, "all_1_1_0")
      width = W168SimpleAggregateTestSupport.width_for("FixedString(3)").not_nil!
      keys = W168_SIMPLE_AGGREGATE_KEYS
      CrystalClick::WidePartWriter.write_uint64_simple_aggregate_fixed_string_pair(
        shifted_scalar, "pk", keys.to_unsafe.to_slice(keys.size), "v",
        fixed_values.to_unsafe.to_slice(fixed_values.size), width,
        CrystalClick::BinarySimpleAggregateType::Function::Min, rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_fixed_string_pair(
        shifted_nullable_part, "pk", keys.to_unsafe.to_slice(keys.size), "v",
        shifted_nullable.to_unsafe.to_slice(shifted_nullable.size), width,
        CrystalClick::BinarySimpleAggregateType::Function::Min, rows_per_mark: 2
      )
      w168_assert_layout(shifted_scalar, "min", "FixedString(3)", false, width, keys, fixed_values,
        W168SimpleAggregateTestSupport.nullable_values(fixed_values))
      w168_assert_layout(shifted_nullable_part, "min", "FixedString(3)", true, width, keys, fixed_values, shifted_nullable)
      # The ordinary fixture remains independently readable; Ruby mutates only
      # its detached copy of the canonical part before the native CHECK oracle.
      _ = shifted_scalar
      puts "PASS W168 library writer: #{generated} exact profiles; changed-value and moved-null parts are separately literalized"
    end
  end
end
