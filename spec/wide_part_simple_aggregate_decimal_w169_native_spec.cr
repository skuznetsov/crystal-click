require "./spec_helper"
require "file_utils"
require "./support/simple_aggregate_w169_types"

private def w169_assert_signed_values(expected : Array(T), actual : Array(T)) : Nil forall T
  {% if T == CrystalClick::Decimal256Value %}
    actual.map { |value| {value.low, value.high} }.should eq(expected.map { |value| {value.low, value.high} })
  {% else %}
    actual.should eq(expected)
  {% end %}
end

private def w169_assert_nullable_signed_values(expected : Array(T?), actual : Array(T?)) : Nil forall T
  {% if T == CrystalClick::Decimal256Value %}
    actual.map { |value| value.try { |entry| {entry.low, entry.high} } }
      .should eq(expected.map { |value| value.try { |entry| {entry.low, entry.high} } })
  {% else %}
    actual.should eq(expected)
  {% end %}
end

private def w169_other_function(function : CrystalClick::BinarySimpleAggregateType::Function) : CrystalClick::BinarySimpleAggregateType::Function
  if function == CrystalClick::BinarySimpleAggregateType::Function::Max
    CrystalClick::BinarySimpleAggregateType::Function::Min
  else
    CrystalClick::BinarySimpleAggregateType::Function::Max
  end
end

private def w169_assert_reader_guards(reader : CrystalClick::WidePart, profile : W169DecimalProfile) : Nil
  wrong_scale = profile.scale == 0 ? 1 : profile.scale - 1
  wrong_function = w169_other_function(profile.function)
  case profile.width_bits
  when 32
    if profile.nullable
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_simple_aggregate_decimal32_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, wrong_scale)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_simple_aggregate_decimal32_raw_mark_range("v", 0, reader.mark_count, wrong_function, profile.precision, profile.scale)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_decimal32_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, profile.scale)
      end
    else
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_decimal32_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, wrong_scale)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_decimal32_raw_mark_range("v", 0, reader.mark_count, wrong_function, profile.precision, profile.scale)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_simple_aggregate_decimal32_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, profile.scale)
      end
    end
  when 64
    if profile.nullable
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_simple_aggregate_decimal64_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, wrong_scale)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_simple_aggregate_decimal64_raw_mark_range("v", 0, reader.mark_count, wrong_function, profile.precision, profile.scale)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_decimal64_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, profile.scale)
      end
    else
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_decimal64_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, wrong_scale)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_decimal64_raw_mark_range("v", 0, reader.mark_count, wrong_function, profile.precision, profile.scale)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_simple_aggregate_decimal64_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, profile.scale)
      end
    end
  when 128
    if profile.nullable
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_simple_aggregate_decimal128_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, wrong_scale)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_simple_aggregate_decimal128_raw_mark_range("v", 0, reader.mark_count, wrong_function, profile.precision, profile.scale)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_decimal128_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, profile.scale)
      end
    else
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_decimal128_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, wrong_scale)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_decimal128_raw_mark_range("v", 0, reader.mark_count, wrong_function, profile.precision, profile.scale)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_simple_aggregate_decimal128_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, profile.scale)
      end
    end
  when 256
    if profile.nullable
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_simple_aggregate_decimal256_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, wrong_scale)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_simple_aggregate_decimal256_raw_mark_range("v", 0, reader.mark_count, wrong_function, profile.precision, profile.scale)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_decimal256_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, profile.scale)
      end
    else
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_decimal256_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, wrong_scale)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_decimal256_raw_mark_range("v", 0, reader.mark_count, wrong_function, profile.precision, profile.scale)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_simple_aggregate_decimal256_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, profile.scale)
      end
    end
  else
    raise "unsupported W169 width"
  end
end

private def w169_keys : Array(UInt64)
  W169_SIMPLE_AGGREGATE_KEYS
end

private def w169_part_root : String
  ENV.fetch("W169_PART_ROOT")
end

private def w169_write32(profile : W169DecimalProfile, values : Array(Int32), destination : String) : Nil
  keys = w169_keys
  if profile.nullable
    nullable_values = W169SimpleAggregateTestSupport.nullable_values(values)
    CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_decimal32_pair(
      destination, "pk", keys.to_unsafe.to_slice(keys.size), "v",
      nullable_values.to_unsafe.to_slice(nullable_values.size), profile.function, profile.scale,
      rows_per_mark: 2, precision: profile.precision,
    )
  else
    CrystalClick::WidePartWriter.write_uint64_simple_aggregate_decimal32_pair(
      destination, "pk", keys.to_unsafe.to_slice(keys.size), "v",
      values.to_unsafe.to_slice(values.size), profile.function, profile.scale,
      rows_per_mark: 2, precision: profile.precision,
    )
  end
  nil
end

private def w169_write64(profile : W169DecimalProfile, values : Array(Int64), destination : String) : Nil
  keys = w169_keys
  if profile.nullable
    nullable_values = W169SimpleAggregateTestSupport.nullable_values(values)
    CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_decimal64_pair(
      destination, "pk", keys.to_unsafe.to_slice(keys.size), "v",
      nullable_values.to_unsafe.to_slice(nullable_values.size), profile.function, profile.scale,
      rows_per_mark: 2, precision: profile.precision,
    )
  else
    CrystalClick::WidePartWriter.write_uint64_simple_aggregate_decimal64_pair(
      destination, "pk", keys.to_unsafe.to_slice(keys.size), "v",
      values.to_unsafe.to_slice(values.size), profile.function, profile.scale,
      rows_per_mark: 2, precision: profile.precision,
    )
  end
  nil
end

private def w169_write128(profile : W169DecimalProfile, values : Array(Int128), destination : String) : Nil
  keys = w169_keys
  if profile.nullable
    nullable_values = W169SimpleAggregateTestSupport.nullable_values(values)
    CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_decimal128_pair(
      destination, "pk", keys.to_unsafe.to_slice(keys.size), "v",
      nullable_values.to_unsafe.to_slice(nullable_values.size), profile.function, profile.scale,
      rows_per_mark: 2, precision: profile.precision,
    )
  else
    CrystalClick::WidePartWriter.write_uint64_simple_aggregate_decimal128_pair(
      destination, "pk", keys.to_unsafe.to_slice(keys.size), "v",
      values.to_unsafe.to_slice(values.size), profile.function, profile.scale,
      rows_per_mark: 2, precision: profile.precision,
    )
  end
  nil
end

private def w169_write256(profile : W169DecimalProfile, values : Array(CrystalClick::Decimal256Value), destination : String) : Nil
  keys = w169_keys
  if profile.nullable
    nullable_values = W169SimpleAggregateTestSupport.nullable_values(values)
    CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_decimal256_pair(
      destination, "pk", keys.to_unsafe.to_slice(keys.size), "v",
      nullable_values.to_unsafe.to_slice(nullable_values.size), profile.function, profile.scale,
      rows_per_mark: 2, precision: profile.precision,
    )
  else
    CrystalClick::WidePartWriter.write_uint64_simple_aggregate_decimal256_pair(
      destination, "pk", keys.to_unsafe.to_slice(keys.size), "v",
      values.to_unsafe.to_slice(values.size), profile.function, profile.scale,
      rows_per_mark: 2, precision: profile.precision,
    )
  end
  nil
end

private def w169_assert_library_reader(profile : W169DecimalProfile, values : Array(Int32), part : String) : Nil
  reader = CrystalClick::WidePart.open_typed(part, "v")
  reader.column_type.should eq(profile.type_name)
  if profile.nullable
    expected = W169SimpleAggregateTestSupport.nullable_values(values)
    actual = reader.read_nullable_simple_aggregate_decimal32_raw_mark_range(
      "v", 0, reader.mark_count, profile.function, profile.precision, profile.scale,
    )
    w169_assert_nullable_signed_values(expected, actual)
    w169_assert_nullable_signed_values(expected[2, 2], reader.read_nullable_simple_aggregate_decimal32_raw_mark_range(
      "v", 1, 1, profile.function, profile.precision, profile.scale,
    ))
    expect_raises(CrystalClick::UnsupportedFormatError) do
      reader.read_simple_aggregate_decimal32_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, profile.scale)
    end
  else
    w169_assert_signed_values(values, reader.read_simple_aggregate_decimal32_raw_mark_range(
      "v", 0, reader.mark_count, profile.function, profile.precision, profile.scale,
    ))
    w169_assert_signed_values(values[2, 2], reader.read_simple_aggregate_decimal32_raw_mark_range(
      "v", 1, 1, profile.function, profile.precision, profile.scale,
    ))
    expect_raises(CrystalClick::UnsupportedFormatError) do
      reader.read_nullable_simple_aggregate_decimal32_raw_mark_range("v", 0, reader.mark_count, profile.function, profile.precision, profile.scale)
    end
  end
  w169_assert_reader_guards(reader, profile)
  nil
end

private def w169_write_rejected_case(profile : W169DecimalProfile, root : String) : Nil
  parent = File.join(root, "rejected", profile.part_label)
  FileUtils.mkdir_p(parent)
  destination = File.join(parent, "all_1_1_0")
  case profile.width_bits
  when 32
    w169_write32(profile, W169SimpleAggregateTestSupport.library_values32, destination)
  when 64
    w169_write64(profile, W169SimpleAggregateTestSupport.library_values64, destination)
  when 128
    w169_write128(profile, W169SimpleAggregateTestSupport.library_values128, destination)
  when 256
    w169_write256(profile, W169SimpleAggregateTestSupport.library_values256, destination)
  else
    raise "unsupported W169 width"
  end
end

private def w169_check_native_batch(batch : CrystalClick::WidePartTableBatch, profiles : Array(W169DecimalProfile)) : Nil
  start = batch.part_row_offset.to_i
  keys = batch.values_for("pk", UInt64).to_a
  keys.should eq(W169_SIMPLE_AGGREGATE_KEYS[start, keys.size])
  profiles.each do |profile|
    column = profile.column_name
    case profile.width_bits
    when 32
      values = W169SimpleAggregateTestSupport.native_values32
      if profile.nullable
        expected = W169SimpleAggregateTestSupport.nullable_values(values)[start, keys.size]
        actual = batch.nullable_simple_aggregate_decimal32_raw_for(column, profile.function, profile.precision, profile.scale)
        w169_assert_nullable_signed_values(expected, actual.to_a)
      else
        expected = values[start, keys.size]
        actual = batch.simple_aggregate_decimal32_raw_for(column, profile.function, profile.precision, profile.scale)
        w169_assert_signed_values(expected, actual.to_a)
      end
    when 64
      values = W169SimpleAggregateTestSupport.native_values64
      if profile.nullable
        expected = W169SimpleAggregateTestSupport.nullable_values(values)[start, keys.size]
        actual = batch.nullable_simple_aggregate_decimal64_raw_for(column, profile.function, profile.precision, profile.scale)
        w169_assert_nullable_signed_values(expected, actual.to_a)
      else
        expected = values[start, keys.size]
        actual = batch.simple_aggregate_decimal64_raw_for(column, profile.function, profile.precision, profile.scale)
        w169_assert_signed_values(expected, actual.to_a)
      end
    when 128
      values = W169SimpleAggregateTestSupport.native_values128
      if profile.nullable
        expected = W169SimpleAggregateTestSupport.nullable_values(values)[start, keys.size]
        actual = batch.nullable_simple_aggregate_decimal128_raw_for(column, profile.function, profile.precision, profile.scale)
        w169_assert_nullable_signed_values(expected, actual.to_a)
      else
        expected = values[start, keys.size]
        actual = batch.simple_aggregate_decimal128_raw_for(column, profile.function, profile.precision, profile.scale)
        w169_assert_signed_values(expected, actual.to_a)
      end
    when 256
      values = W169SimpleAggregateTestSupport.native_values256
      if profile.nullable
        expected = W169SimpleAggregateTestSupport.nullable_values(values)[start, keys.size]
        actual = batch.nullable_simple_aggregate_decimal256_raw_for(column, profile.function, profile.precision, profile.scale)
        w169_assert_nullable_signed_values(expected, actual.to_a)
      else
        expected = values[start, keys.size]
        actual = batch.simple_aggregate_decimal256_raw_for(column, profile.function, profile.precision, profile.scale)
        w169_assert_signed_values(expected, actual.to_a)
      end
    else
      raise "unsupported W169 width"
    end
  end
end

if ENV["W169_SIMPLE_AGGREGATE_STOCK_WIDE_PART"]?
  describe "W169 canonical Decimal SimpleAggregateFunction Wide parts" do
    it "writes every source-eligible scalar/Nullable profile through public APIs and reads exact raw coefficients" do
      all_cases = W169SimpleAggregateTestSupport.candidate_cases
      accepted = W169SimpleAggregateTestSupport.accepted_profiles
      rejected = W169SimpleAggregateTestSupport.rejected_profiles
      all_cases.size.should eq(414)
      accepted.size.should eq(254)
      rejected.size.should eq(160)
      puts "W169 construction matrix: cases=#{all_cases.size} accepted=#{accepted.size} rejected=#{rejected.size} native_columns=#{accepted.size + 1}"

      part_root = w169_part_root
      FileUtils.mkdir_p(part_root)
      accepted.each do |profile|
        part = profile.part_path(part_root)
        Dir.mkdir(File.dirname(part))
        case profile.width_bits
        when 32
          values = W169SimpleAggregateTestSupport.library_values32
          w169_write32(profile, values, part)
          w169_assert_library_reader(profile, values, part)
        when 64
          values = W169SimpleAggregateTestSupport.library_values64
          w169_write64(profile, values, part)
          reader = CrystalClick::WidePart.open_typed(part, "v")
          reader.column_type.should eq(profile.type_name)
          if profile.nullable
            expected = W169SimpleAggregateTestSupport.nullable_values(values)
            w169_assert_nullable_signed_values(expected, reader.read_nullable_simple_aggregate_decimal64_raw_mark_range(
              "v", 0, reader.mark_count, profile.function, profile.precision, profile.scale,
            ))
            w169_assert_nullable_signed_values(expected[2, 2], reader.read_nullable_simple_aggregate_decimal64_raw_mark_range(
              "v", 1, 1, profile.function, profile.precision, profile.scale,
            ))
          else
            w169_assert_signed_values(values, reader.read_simple_aggregate_decimal64_raw_mark_range(
              "v", 0, reader.mark_count, profile.function, profile.precision, profile.scale,
            ))
            w169_assert_signed_values(values[2, 2], reader.read_simple_aggregate_decimal64_raw_mark_range(
              "v", 1, 1, profile.function, profile.precision, profile.scale,
            ))
          end
          w169_assert_reader_guards(reader, profile)
        when 128
          values = W169SimpleAggregateTestSupport.library_values128
          w169_write128(profile, values, part)
          reader = CrystalClick::WidePart.open_typed(part, "v")
          reader.column_type.should eq(profile.type_name)
          if profile.nullable
            expected = W169SimpleAggregateTestSupport.nullable_values(values)
            w169_assert_nullable_signed_values(expected, reader.read_nullable_simple_aggregate_decimal128_raw_mark_range(
              "v", 0, reader.mark_count, profile.function, profile.precision, profile.scale,
            ))
            w169_assert_nullable_signed_values(expected[2, 2], reader.read_nullable_simple_aggregate_decimal128_raw_mark_range(
              "v", 1, 1, profile.function, profile.precision, profile.scale,
            ))
          else
            w169_assert_signed_values(values, reader.read_simple_aggregate_decimal128_raw_mark_range(
              "v", 0, reader.mark_count, profile.function, profile.precision, profile.scale,
            ))
            w169_assert_signed_values(values[2, 2], reader.read_simple_aggregate_decimal128_raw_mark_range(
              "v", 1, 1, profile.function, profile.precision, profile.scale,
            ))
          end
          w169_assert_reader_guards(reader, profile)
        when 256
          values = W169SimpleAggregateTestSupport.library_values256
          w169_write256(profile, values, part)
          reader = CrystalClick::WidePart.open_typed(part, "v")
          reader.column_type.should eq(profile.type_name)
          if profile.nullable
            expected = W169SimpleAggregateTestSupport.nullable_values(values)
            w169_assert_nullable_signed_values(expected, reader.read_nullable_simple_aggregate_decimal256_raw_mark_range(
              "v", 0, reader.mark_count, profile.function, profile.precision, profile.scale,
            ))
            w169_assert_nullable_signed_values(expected[2, 2], reader.read_nullable_simple_aggregate_decimal256_raw_mark_range(
              "v", 1, 1, profile.function, profile.precision, profile.scale,
            ))
          else
            w169_assert_signed_values(values, reader.read_simple_aggregate_decimal256_raw_mark_range(
              "v", 0, reader.mark_count, profile.function, profile.precision, profile.scale,
            ))
            w169_assert_signed_values(values[2, 2], reader.read_simple_aggregate_decimal256_raw_mark_range(
              "v", 1, 1, profile.function, profile.precision, profile.scale,
            ))
          end
          w169_assert_reader_guards(reader, profile)
        else
          raise "unsupported W169 width"
        end
      end

      rejected.each do |profile|
        expect_raises(ArgumentError) do
          w169_write_rejected_case(profile, part_root)
        end
        Dir.children(File.join(part_root, "rejected", profile.part_label)).should be_empty
      end

      # A same-type writer-produced coefficient mutant supports an independent
      # stock CHECK/oracle rejection in the Ruby harness; canonical fixtures
      # remain unchanged and still begin with raw coefficient zero.
      value_profile = accepted.find do |profile|
        profile.function_name == "any" && profile.precision == 19 && profile.scale == 0 && !profile.nullable
      end.not_nil!
      mutant_values = W169SimpleAggregateTestSupport.library_values128.dup
      mutant_values[0] = 1_i128
      mutant_parent = File.join(part_root, "mutants", "coefficient_lsb")
      FileUtils.mkdir_p(mutant_parent)
      w169_write128(value_profile, mutant_values, File.join(mutant_parent, "all_1_1_0"))
    end

    it "reads the native-authored Wide/LZ4 table through exact scalar, Nullable, and batch APIs" do
      stock_part = ENV.fetch("W169_SIMPLE_AGGREGATE_STOCK_WIDE_PART")
      reader = CrystalClick::WidePart.open_typed(stock_part, "pk")
      reader.column_type.should eq("UInt64")
      reader.read_uint64_mark_range("pk", 0, reader.mark_count).should eq(W169_SIMPLE_AGGREGATE_KEYS)

      profiles = W169SimpleAggregateTestSupport.accepted_profiles
      observed_rows = 0
      profiles.each_slice(15) do |profile_group|
        columns = ["pk"] + profile_group.map(&.column_name)
        table = CrystalClick::WidePartTable.open_selected_typed([stock_part], columns)
        expected_types = [{"pk", "UInt64"}] + profile_group.map { |profile| {profile.column_name, profile.type_name} }
        table.column_types.should eq(expected_types)
        table.scan_typed(batch_rows: 2) do |batch|
          w169_check_native_batch(batch, profile_group)
          observed_rows += batch.values_for("pk", UInt64).size
        end
      end
      observed_rows.should eq(W169_SIMPLE_AGGREGATE_KEYS.size * ((profiles.size + 14) // 15))
    end
  end
end
