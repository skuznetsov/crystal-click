require "./spec_helper"
require "file_utils"
require "./support/simple_aggregate_w170_types"

private def w170_assert_values(expected : Array(T), actual : Array(T)) : Nil forall T
  actual.should eq(expected)
end

private def w170_assert_nullable_values(expected : Array(T?), actual : Array(T?)) : Nil forall T
  actual.should eq(expected)
end

private def w170_other_function(function : CrystalClick::BinarySimpleAggregateType::Function) : CrystalClick::BinarySimpleAggregateType::Function
  function == CrystalClick::BinarySimpleAggregateType::Function::Max ? CrystalClick::BinarySimpleAggregateType::Function::Min : CrystalClick::BinarySimpleAggregateType::Function::Max
end

private def w170_part_root : String
  ENV.fetch("W170_PART_ROOT")
end

private def w170_stock_part : String
  ENV.fetch("W170_SIMPLE_AGGREGATE_STOCK_WIDE_PART")
end

private def w170_write_part(profile : W170TemporalProfile, values : Array(T), destination : String) : Nil forall T
  keys = W170_TEMPORAL_KEYS
  if profile.nullable
    nullable_values = W170SimpleAggregateTemporalTestSupport.nullable_values(values)
    CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_temporal_pair(
      destination, "pk", keys.to_unsafe.to_slice(keys.size), "v",
      nullable_values.to_unsafe.to_slice(nullable_values.size), profile.function,
      profile.storage_type_name, rows_per_mark: 2)
  else
    CrystalClick::WidePartWriter.write_uint64_simple_aggregate_temporal_pair(
      destination, "pk", keys.to_unsafe.to_slice(keys.size), "v",
      values.to_unsafe.to_slice(values.size), profile.function,
      profile.storage_type_name, rows_per_mark: 2)
  end
  nil
end

private def w170_wrong_storage_type(profile : W170TemporalProfile) : String?
  leaf = profile.leaf
  case leaf.family
  when "DateTime"
    leaf.timezone == "UTC" ? "DateTime('Europe/Berlin')" : "DateTime('UTC')"
  when "DateTime64"
    if zone = leaf.timezone
      scale = leaf.scale == 9 ? 8 : leaf.scale.not_nil! + 1
      "DateTime64(#{scale}, '#{zone}')"
    else
      scale = leaf.scale == 9 ? 8 : leaf.scale.not_nil! + 1
      "DateTime64(#{scale})"
    end
  when "Time64"
    scale = leaf.scale == 9 ? 8 : leaf.scale.not_nil! + 1
    "Time64(#{scale})"
  when "Time"
    "Date32"
  else
    nil
  end
end

private def w170_assert_reader_guards(reader : CrystalClick::WidePart, profile : W170TemporalProfile, type : T.class) : Nil forall T
  wrong_function = w170_other_function(profile.function)
  if profile.nullable
    expect_raises(CrystalClick::UnsupportedFormatError) do
      reader.read_nullable_simple_aggregate_temporal_raw_mark_range(
        "v", 0, reader.mark_count, wrong_function, profile.storage_type_name, type,
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      reader.read_simple_aggregate_temporal_raw_mark_range(
        "v", 0, reader.mark_count, profile.function, profile.storage_type_name, type,
      )
    end
  else
    expect_raises(CrystalClick::UnsupportedFormatError) do
      reader.read_simple_aggregate_temporal_raw_mark_range(
        "v", 0, reader.mark_count, wrong_function, profile.storage_type_name, type,
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      reader.read_nullable_simple_aggregate_temporal_raw_mark_range(
        "v", 0, reader.mark_count, profile.function, profile.storage_type_name, type,
      )
    end
  end

  if wrong_storage = w170_wrong_storage_type(profile)
    if profile.nullable
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_simple_aggregate_temporal_raw_mark_range(
          "v", 0, reader.mark_count, profile.function, wrong_storage, type,
        )
      end
    else
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_temporal_raw_mark_range(
          "v", 0, reader.mark_count, profile.function, wrong_storage, type,
        )
      end
    end
  end
  nil
end

private def w170_assert_library_part(profile : W170TemporalProfile, values : Array(T), part : String) : Nil forall T
  reader = CrystalClick::WidePart.open_typed(part, "v")
  reader.column_type.should eq(profile.type_name)
  if profile.nullable
    expected = W170SimpleAggregateTemporalTestSupport.nullable_values(values)
    actual = reader.read_nullable_simple_aggregate_temporal_raw_mark_range(
      "v", 0, reader.mark_count, profile.function, profile.storage_type_name, T,
    )
    w170_assert_nullable_values(expected, actual)
    middle = reader.read_nullable_simple_aggregate_temporal_raw_mark_range(
      "v", 1, 1, profile.function, profile.storage_type_name, T,
    )
    w170_assert_nullable_values(expected[2, 2], middle)
    expect_raises(CrystalClick::BoundsError) do
      reader.read_nullable_simple_aggregate_temporal_raw_mark_range(
        "v", reader.mark_count, 0, profile.function, profile.storage_type_name, T,
      )
    end
  else
    actual = reader.read_simple_aggregate_temporal_raw_mark_range(
      "v", 0, reader.mark_count, profile.function, profile.storage_type_name, T,
    )
    w170_assert_values(values, actual)
    middle = reader.read_simple_aggregate_temporal_raw_mark_range(
      "v", 1, 1, profile.function, profile.storage_type_name, T,
    )
    w170_assert_values(values[2, 2], middle)
    expect_raises(CrystalClick::BoundsError) do
      reader.read_simple_aggregate_temporal_raw_mark_range(
        "v", reader.mark_count, 0, profile.function, profile.storage_type_name, T,
      )
    end
  end
  w170_assert_reader_guards(reader, profile, T)
  nil
end

private def w170_write_and_read_library_part(profile : W170TemporalProfile) : Nil
  root = w170_part_root
  part = profile.part_path(root)
  Dir.mkdir(File.dirname(part))
  case profile.leaf.carrier_type_name
  when "UInt16"
    values = W170SimpleAggregateTemporalTestSupport.library_values(profile, UInt16)
    w170_write_part(profile, values, part)
    w170_assert_library_part(profile, values, part)
  when "Int32"
    values = W170SimpleAggregateTemporalTestSupport.library_values(profile, Int32)
    w170_write_part(profile, values, part)
    w170_assert_library_part(profile, values, part)
  when "UInt32"
    values = W170SimpleAggregateTemporalTestSupport.library_values(profile, UInt32)
    w170_write_part(profile, values, part)
    w170_assert_library_part(profile, values, part)
  when "Int64"
    values = W170SimpleAggregateTemporalTestSupport.library_values(profile, Int64)
    w170_write_part(profile, values, part)
    w170_assert_library_part(profile, values, part)
  else
    raise "unknown W170 temporal carrier"
  end
end

private def w170_check_native_batch_column(batch : CrystalClick::WidePartTableBatch, profile : W170TemporalProfile, start : Int32, count : Int32) : Nil
  case profile.leaf.carrier_type_name
  when "UInt16"
    w170_check_native_values(batch, profile, start, count, UInt16)
  when "Int32"
    w170_check_native_values(batch, profile, start, count, Int32)
  when "UInt32"
    w170_check_native_values(batch, profile, start, count, UInt32)
  when "Int64"
    w170_check_native_values(batch, profile, start, count, Int64)
  else
    raise "unknown W170 temporal carrier"
  end
end

private def w170_check_native_values(batch : CrystalClick::WidePartTableBatch, profile : W170TemporalProfile, start : Int32, count : Int32, type : T.class) : Nil forall T
  values = W170SimpleAggregateTemporalTestSupport.native_values(profile, T)
  if profile.nullable
    expected = W170SimpleAggregateTemporalTestSupport.nullable_values(values)[start, count]
    actual = batch.nullable_simple_aggregate_temporal_raw_values_for(
      profile.column_name, profile.function, profile.storage_type_name, T,
    )
    w170_assert_nullable_values(expected, actual.to_a)
  else
    expected = values[start, count]
    actual = batch.simple_aggregate_temporal_raw_values_for(
      profile.column_name, profile.function, profile.storage_type_name, T,
    )
    w170_assert_values(expected, actual.to_a)
  end
end

if ENV["W170_SIMPLE_AGGREGATE_STOCK_WIDE_PART"]?
  describe "W170 canonical temporal SimpleAggregateFunction Wide parts" do
    it "constructs every admitted identity profile and reads independently authored temporal codes" do
      leaves = W170SimpleAggregateTemporalTestSupport.temporal_leaves
      profiles = W170SimpleAggregateTemporalTestSupport.accepted_profiles
      leaves.size.should eq(36)
      profiles.size.should eq(288)
      profiles.each do |profile|
        descriptor = CrystalClick::BinaryDataType.simple_aggregate(profile.function, profile.leaf.build_type)
        aggregate_name = "SimpleAggregateFunction(#{profile.function_name}, #{profile.storage_type_name})"
        descriptor.name.should eq(aggregate_name)
        descriptor.tag.should eq(CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE)
        descriptor.simple_aggregate_type.not_nil!.storage_type_name.should eq(profile.storage_type_name)
        descriptor.child_count.should eq(1)
        descriptor.child_at(0).name.should eq(profile.storage_type_name)
        descriptor.child_at(0).temporal_type.should eq(profile.leaf.build_type.temporal_type)
        if profile.nullable
          CrystalClick::BinaryDataType.nullable(descriptor).name.should eq(profile.type_name)
        end

        binary_descriptor = CrystalClick::BinarySimpleAggregateType.parse(aggregate_name)
        binary_descriptor.should_not be_nil
        if parsed_descriptor = binary_descriptor
          parsed_descriptor.function.should eq(profile.function)
          parsed_descriptor.storage_type_name.should eq(profile.storage_type_name)
          parsed_descriptor.type_name.should eq(aggregate_name)
        end

        column = CrystalClick::SimpleAggregateColumnType.parse(profile.type_name)
        column.should_not be_nil
        if parsed = column
          parsed.function.should eq(profile.function)
          parsed.storage_type_name.should eq(profile.storage_type_name)
          parsed.nullable?.should eq(profile.nullable)
          parsed.type_name.should eq(profile.type_name)
          expect_raises(ArgumentError) { parsed.raw_width }
        end

        w170_write_and_read_library_part(profile)
      end

      rejected_functions = [
        CrystalClick::BinarySimpleAggregateType::Function::Sum,
        CrystalClick::BinarySimpleAggregateType::Function::SumWithOverflow,
        CrystalClick::BinarySimpleAggregateType::Function::GroupBitAnd,
        CrystalClick::BinarySimpleAggregateType::Function::GroupBitOr,
        CrystalClick::BinarySimpleAggregateType::Function::GroupBitXor,
      ]
      rejected_functions.each do |function|
        leaves.each do |leaf|
          expect_raises(ArgumentError) do
            CrystalClick::BinaryDataType.simple_aggregate(function, leaf.build_type)
          end
        end
      end
      ["Time('UTC')", "Time64(3, 'UTC')"].each do |leaf|
        CrystalClick::BinarySimpleAggregateType.parse("SimpleAggregateFunction(any, #{leaf})").should be_nil
        CrystalClick::SimpleAggregateColumnType.parse("SimpleAggregateFunction(any, #{leaf})").should be_nil
      end

      # A writer-produced value mutant is used by the independent stock oracle
      # to prove CHECK is not a substitute for unchanged literal equality.
      mutant_profile = profiles.find do |profile|
        profile.function_name == "any" && profile.leaf.storage_type_name == "DateTime64(3)" && !profile.nullable
      end.not_nil!
      mutant_values = W170SimpleAggregateTemporalTestSupport.library_values(mutant_profile, Int64).dup
      mutant_values[0] = 1_i64
      mutant_parent = File.join(w170_part_root, "mutants", "value_lsb")
      FileUtils.mkdir_p(mutant_parent)
      w170_write_part(mutant_profile, mutant_values, File.join(mutant_parent, "all_1_1_0"))
      puts "W170 construction matrix: leaves=36 accepted=288 rejected=0 native_columns=289 refusal_functions=5 refusal_cases=180 value_mutants=1"
    end

    it "reads the native-authored five-row Wide/LZ4 table through exact scalar, Nullable, and batch APIs" do
      stock_part = w170_stock_part
      reader = CrystalClick::WidePart.open_typed(stock_part, "pk")
      reader.column_type.should eq("UInt64")
      reader.read_uint64_mark_range("pk", 0, reader.mark_count).should eq(W170_TEMPORAL_KEYS)

      profiles = W170SimpleAggregateTemporalTestSupport.accepted_profiles
      # The selected-column limit includes pk; project the 289-column fixture
      # in bounded groups of temporal columns rather than widening the reader.
      profile_batch_size = CrystalClick::WidePartTable::MAX_COLUMNS - 1
      observed_rows = 0
      profiles.each_slice(profile_batch_size) do |profile_group|
        columns = ["pk"] + profile_group.map(&.column_name)
        table = CrystalClick::WidePartTable.open_selected_typed([stock_part], columns)
        expected_types = [{"pk", "UInt64"}] + profile_group.map { |profile| {profile.column_name, profile.type_name} }
        table.column_types.should eq(expected_types)
        table.scan_typed(batch_rows: 2) do |batch|
          start = batch.part_row_offset.to_i
          keys = batch.values_for("pk", UInt64).to_a
          keys.should eq(W170_TEMPORAL_KEYS[start, keys.size])
          profile_group.each do |profile|
            w170_check_native_batch_column(batch, profile, start, keys.size)
          end
          observed_rows += keys.size
        end
      end
      expected_profile_batches = (profiles.size + profile_batch_size - 1) // profile_batch_size
      observed_rows.should eq(W170_TEMPORAL_KEYS.size * expected_profile_batches)
    end
  end
end
