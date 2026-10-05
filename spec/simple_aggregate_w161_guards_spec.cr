require "./spec_helper"
require "file_utils"
require "./support/simple_aggregate_w161_types"

module CrystalClick::WidePartWriter
  # Refresh the test part's checksum manifest after serializer-only mutations,
  # ensuring reader assertions reach metadata admission.
  def self.w161_guard_refresh_checksums(part : String) : Nil
    current = PartChecksums.open(part)
    records = [] of ChecksumRecord
    current.entries.each do |name, entry|
      bytes = File.read(File.join(part, name)).to_slice
      hash = CityHashV1.file_hash(bytes)
      if entry.compressed
        raw = CompressedBlock.decode_all(bytes)
        records << ChecksumRecord.new(name, bytes.size.to_u64, hash, true, raw.size.to_u64, CityHashV1.file_hash(raw))
      else
        records << ChecksumRecord.new(name, bytes.size.to_u64, hash, false)
      end
    end
    write_checksums(part, records)
  end
end

module CrystalClick
  module WidePartWriter
    # Spec-only bridge to the existing private staged metadata validator. This
    # tests nominal metadata validation, not publication or cleanup behavior.
    def self.w161_test_validate_staged_simple_aggregate(
      stage : String,
      keys : Slice(UInt64),
      values : Slice(UInt64),
      type_name : String,
      rows_per_mark : Int32,
    ) : Nil
      validate_staged_typed_part(stage, "pk", "v", keys, values, type_name, rows_per_mark)
    end
  end
end

private def with_w161_guard_parent(& : String ->)
  parent = File.tempname("crystal-click-simple-aggregate-w161-guards")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w161_guard_scalar_part(parent : String, name : String, rows_per_mark : Int32 = 2) : String
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  values = W161_SIMPLE_AGGREGATE_LIBRARY_VALUES
  table_root = File.join(parent, name)
  Dir.mkdir(table_root)
  part = File.join(table_root, "all_1_1_0")
  CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
    part,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "v",
    values.to_unsafe.to_slice(values.size),
    CrystalClick::BinarySimpleAggregateType::Function::Min,
    rows_per_mark: rows_per_mark
  )
  part
end

private def w161_guard_nullable_part(parent : String, name : String, rows_per_mark : Int32 = 2) : String
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  values = W161_SIMPLE_AGGREGATE_LIBRARY_NULLABLE_VALUES
  table_root = File.join(parent, name)
  Dir.mkdir(table_root)
  part = File.join(table_root, "all_1_1_0")
  CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_pair(
    part,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "v",
    values.to_unsafe.to_slice(values.size),
    CrystalClick::BinarySimpleAggregateType::Function::Min,
    rows_per_mark: rows_per_mark
  )
  part
end

private def w161_guard_replace_serializer_versions(part : String, version_fields : String) : Nil
  path = File.join(part, "serialization.json")
  original = File.read(path)
  updated = original.sub(
    %("types_serialization_versions":{"string":1}),
    %("types_serialization_versions":{#{version_fields}})
  )
  raise "W161 fixture did not have its canonical string serializer version" if updated == original
  File.write(path, updated)
  CrystalClick::WidePartWriter.w161_guard_refresh_checksums(part)
end

private def w161_guard_change_mark_rows(part : String, stream : String, mark_index : Int, rows : UInt64) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 16
  raise "W161 guard mark index is out of range" if offset > bytes.size - 8
  8.times { |byte| bytes[offset + byte] = ((rows >> (byte * 8)) & 0xff_u64).to_u8 }
  File.write(path, bytes)
end

describe "W161 SimpleAggregateFunction negative admission and publication guards" do
  it "rejects validly encoded nonzero parameters, bad arities, unknown functions and unsupported wrappers" do
    W161_SIMPLE_AGGREGATE_TYPES.each do |name, _suffix, _function|
      # Field::UInt64 is 0x01 followed by VarUInt(1); the malformed profile is
      # otherwise structurally complete, so rejection is semantic, not truncation.
      parameterized = W161SimpleAggregateTestSupport.descriptor(
        name,
        parameter_count: 1_u8,
        parameter_bytes: [0x01_u8, 0x01_u8]
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.decode(Bytes.new(parameterized.size) { |i| parameterized[i] })
      end

      zero_arguments = W161SimpleAggregateTestSupport.descriptor(
        name,
        arguments: [] of UInt8,
        argument_count: 0_u8
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.decode(Bytes.new(zero_arguments.size) { |i| zero_arguments[i] })
      end

      multiple_arguments = W161SimpleAggregateTestSupport.descriptor(
        name,
        arguments: [0x04_u8, 0x04_u8],
        argument_count: 2_u8
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.decode(Bytes.new(multiple_arguments.size) { |i| multiple_arguments[i] })
      end

      string_child = W161SimpleAggregateTestSupport.descriptor(name, arguments: [0x15_u8])
      if name == "any" || name == "anyLast" || name == "min" || name == "max"
        decoded_string = CrystalClick::BinaryDataTypeCodec.decode(
          Bytes.new(string_child.size) { |i| string_child[i] }
        )
        decoded_string.name.should eq("SimpleAggregateFunction(#{name}, String)")
        decoded_string.child_at(0).tag.should eq(CrystalClick::BinaryDataType::TAG_STRING)
      else
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::BinaryDataTypeCodec.decode(Bytes.new(string_child.size) { |i| string_child[i] })
        end
      end

      [
        [0x23_u8, 0x04_u8], # Nullable(UInt64), still a wrapped child
        [0x26_u8, 0x04_u8], # LowCardinality(UInt64), still a wrapped child
      ].each do |carrier|
        wrong_storage = W161SimpleAggregateTestSupport.descriptor(name, arguments: carrier)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::BinaryDataTypeCodec.decode(Bytes.new(wrong_storage.size) { |i| wrong_storage[i] })
        end
      end
    end

    ["avg", "Min", "SUM", "groupBitAnd "].each do |function_name|
      unsupported = W161SimpleAggregateTestSupport.descriptor(function_name)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.decode(Bytes.new(unsupported.size) { |i| unsupported[i] })
      end
    end
  end

  it "rejects every descriptor truncation, trailing bytes and one-short byte budgets" do
    W161_SIMPLE_AGGREGATE_TYPES.each do |name, _suffix, _function|
      descriptor = W161SimpleAggregateTestSupport.descriptor(name)
      (0...descriptor.size).each do |length|
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::BinaryDataTypeCodec.decode(Bytes.new(length) { |i| descriptor[i] })
        end
      end

      trailing = descriptor + [0x00_u8]
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(Bytes.new(trailing.size) { |i| trailing[i] })
      end

      limits = CrystalClick::BinaryCodecLimits.new(
        max_depth: 64,
        max_nodes: 4096,
        max_elements: 1_000_000,
        max_bytes: descriptor.size - 1
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(Bytes.new(descriptor.size) { |i| descriptor[i] }, limits)
      end
    end
  end

  it "charges wrapper descriptor, typed-value and bulk traversal at exact shared budgets" do
    type = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Min
    )
    descriptor = W161SimpleAggregateTestSupport.descriptor("min")
    value = CrystalClick::BinaryValue.simple_aggregate(
      type,
      CrystalClick::BinaryValue.uint64(0x8000_0000_0000_0000_u64)
    )

    exact_descriptor = CrystalClick::BinaryCodecLimits.new(
      max_depth: 2,
      max_nodes: 2,
      max_elements: 1,
      max_bytes: descriptor.size
    )
    CrystalClick::BinaryDataTypeCodec.decode(Bytes.new(descriptor.size) { |i| descriptor[i] }, exact_descriptor).should eq(type)
    CrystalClick::BinaryDataTypeCodec.encode(type, exact_descriptor).to_a.should eq(descriptor)
    [
      CrystalClick::BinaryCodecLimits.new(1, 2, 1, descriptor.size),
      CrystalClick::BinaryCodecLimits.new(2, 1, 1, descriptor.size),
      CrystalClick::BinaryCodecLimits.new(2, 2, 0, descriptor.size),
      CrystalClick::BinaryCodecLimits.new(2, 2, 1, descriptor.size - 1),
    ].each do |short|
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::BinaryDataTypeCodec.encode(type, short) }
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(Bytes.new(descriptor.size) { |i| descriptor[i] }, short)
      end
    end

    envelope = descriptor + W161SimpleAggregateTestSupport.u64_le(0x8000_0000_0000_0000_u64)
    exact_value = CrystalClick::BinaryCodecLimits.new(2, 4, 2, envelope.size)
    CrystalClick::BinaryValueCodec.encode(value, exact_value).to_a.should eq(envelope)
    CrystalClick::BinaryValueCodec.decode(Bytes.new(envelope.size) { |i| envelope[i] }, exact_value).type.should eq(type)
    [
      CrystalClick::BinaryCodecLimits.new(1, 4, 2, envelope.size),
      CrystalClick::BinaryCodecLimits.new(2, 3, 2, envelope.size),
      CrystalClick::BinaryCodecLimits.new(2, 4, 1, envelope.size),
      CrystalClick::BinaryCodecLimits.new(2, 4, 2, envelope.size - 1),
    ].each do |short|
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::BinaryValueCodec.encode(value, short) }
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode(Bytes.new(envelope.size) { |i| envelope[i] }, short)
      end
    end

    rows = [[value] of CrystalClick::BinaryValue]
    exact_bulk = CrystalClick::BinaryCodecLimits.new(2, 7, 5, 8)
    bulk = CrystalClick::BinaryBulkCodec.encode(type, rows, limits: exact_bulk)
    decoded_value = CrystalClick::BinaryBulkCodec.decode(type, bulk, [1_u64], limits: exact_bulk)[0][0]
    decoded_value.type.should eq(value.type)
    decoded_value.as_simple_aggregate.type.should eq(value.as_simple_aggregate.type)
    decoded_value.as_simple_aggregate.bytes.should eq(value.as_simple_aggregate.bytes)
    [
      CrystalClick::BinaryCodecLimits.new(1, 7, 5, 8),
      CrystalClick::BinaryCodecLimits.new(2, 6, 5, 8),
      CrystalClick::BinaryCodecLimits.new(2, 7, 4, 8),
      CrystalClick::BinaryCodecLimits.new(2, 7, 5, 7),
    ].each do |short|
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::BinaryBulkCodec.encode(type, rows, limits: short) }
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryBulkCodec.decode(type, bulk, [1_u64], limits: short)
      end
    end
  end

  it "admits eligible text storage while rejecting unsupported constructors, wrong children and wrappers" do
    function = CrystalClick::BinarySimpleAggregateType::Function::Min
    string_type = CrystalClick::BinaryDataType.primitive("String")
    string_minimum = CrystalClick::BinaryDataType.simple_aggregate(function, string_type)
    string_minimum.name.should eq("SimpleAggregateFunction(min, String)")
    string_minimum.child_at(0).should eq(string_type)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Sum,
        string_type
      )
    end

    minimum = CrystalClick::BinaryDataType.simple_aggregate(function)
    maximum = CrystalClick::BinaryDataType.simple_aggregate(CrystalClick::BinarySimpleAggregateType::Function::Max)
    child = CrystalClick::BinaryValue.uint64(9_u64)
    expect_raises(ArgumentError) do
      wrong_child = CrystalClick::BinaryValue.fixed(
        CrystalClick::BinaryDataType.primitive("UInt8"),
        Bytes[9_u8]
      )
      CrystalClick::BinaryValue.simple_aggregate(minimum, wrong_child)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.simple_aggregate(minimum, CrystalClick::BinaryValue.simple_aggregate(maximum, child))
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.low_cardinality(minimum)
    end

    expect_raises(ArgumentError) do
      CrystalClick::BinarySimpleAggregateType.new(
        CrystalClick::BinarySimpleAggregateType::Function.new(123)
      )
    end
  end

  it "returns no parsed type for noncanonical case, spacing, parameters and oversized names" do
    [
      "SimpleAggregateFunction(Min, UInt64)",
      "SimpleAggregateFunction(min,UInt64)",
      "SimpleAggregateFunction(min, UInt64, UInt64)",
      "SimpleAggregateFunction(min(1), UInt64)",
      "SimpleAggregateFunction(unknownFunctionNameTooLong, UInt64)",
    ].each do |name|
      CrystalClick::BinarySimpleAggregateType.parse(name).should be_nil
    end
    CrystalClick::SimpleAggregateColumnType.parse("Nullable(SimpleAggregateFunction(Min, UInt64))").should be_nil
  end

  it "preflights the longest canonical SQL name at exact and one-short budgets" do
    type = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::SumWithOverflow
    )
    name = "SimpleAggregateFunction(sumWithOverflow, UInt64)"
    measured = CrystalClick::BinaryTypeNameBudget.measure(
      type,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    )
    type.name.should eq(name)
    measured[0].should be >= name.bytesize.to_u64

    exact_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 2,
      max_nodes: 2,
      max_elements: 1,
      max_bytes: measured[1].to_i
    )
    exact_budget = CrystalClick::BinaryCodecBudget.new(exact_limits, true)
    CrystalClick::BinaryTypeNameBudget.materialize(type, exact_budget, measured).should eq(name)

    short_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 2,
      max_nodes: 2,
      max_elements: 1,
      max_bytes: measured[1].to_i - 1
    )
    short_budget = CrystalClick::BinaryCodecBudget.new(short_limits, true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryTypeNameBudget.materialize(type, short_budget, measured)
    end
  end

  it "keeps SimpleAggregateFunction out of Object declarations and declared Dynamic actual arms" do
    simple = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Min
    )
    expect_raises(ArgumentError, "typed JSON schema admits only supported Object recursive types") do
      CrystalClick::ObjectDocumentSchema.new({"v" => simple})
    end

    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    schema = CrystalClick::ObjectDocumentSchema.new({"v" => dynamic})
    empty = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure
    )
    expected = "invalid typed Object Dynamic actual roster: " +
               "typed Object Dynamic actual arm is outside the recursive declaration grammar"
    expect_raises(ArgumentError, expected) do
      CrystalClick::ObjectDocumentPlan.new(
        empty,
        schema.typed_paths,
        {"v" => CrystalClick::DynamicStructure.new([simple] of CrystalClick::BinaryDataType)}
      )
    end

    plan = CrystalClick::ObjectDocumentPlan.new(
      empty,
      schema.typed_paths,
      {"v" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}
    )
    selected = CrystalClick::BinaryValue.dynamic(
      dynamic,
      CrystalClick::BinaryValue.simple_aggregate(
        simple,
        CrystalClick::BinaryValue.uint64(7_u64)
      )
    )
    rows = [[CrystalClick::ObjectDocument.new({"v" => selected})] of CrystalClick::ObjectDocument]
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.encode(plan, rows, mode: 0_u64)
    end
  end

  it "rejects same-width staged min-to-max declaration substitution" do
    with_w161_guard_parent do |parent|
      source = w161_guard_scalar_part(parent, "source")
      stage = File.join(parent, "stage")
      FileUtils.cp_r(source, stage)

      expected_type = "SimpleAggregateFunction(min, UInt64)"
      wrong_type = "SimpleAggregateFunction(max, UInt64)"
      columns_path = File.join(stage, "columns.txt")
      original = File.read(columns_path)
      original.should contain("`v` #{expected_type}\n")
      File.write(columns_path, original.sub("`v` #{expected_type}\n", "`v` #{wrong_type}\n"))

      keys = W161_SIMPLE_AGGREGATE_KEYS
      values = W161_SIMPLE_AGGREGATE_LIBRARY_VALUES
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w161_test_validate_staged_simple_aggregate(
          stage,
          keys.to_unsafe.to_slice(keys.size),
          values.to_unsafe.to_slice(values.size),
          expected_type,
          2
        )
      end
    end
  end

  it "rejects a later unselected mark-grid corruption before an EOF window callback" do
    with_w161_guard_parent do |parent|
      part = w161_guard_scalar_part(parent, "grid", rows_per_mark: 2)
      # Six rows produce data marks [2, 2, 2] and a terminal zero-row mark.
      w161_guard_change_mark_rows(part, "v", 2, 3_u64)

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(part, "v")
      end

      callbacks = 0
      error = expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
        table.scan_typed_window(table.total_row_count, 1) { |_batch| callbacks += 1; nil }
      end
      error.message.should eq("row count does not match marks")
      callbacks.should eq(0)
    end
  end

  it "admits only basic Nullable SimpleAggregateFunction serializer version and forbids scalar nullable version entries" do
    with_w161_guard_parent do |parent|
      absent = w161_guard_nullable_part(parent, "nullable-absent")
      CrystalClick::WidePart.open_typed(absent, "v").column_type.should eq(
        "Nullable(SimpleAggregateFunction(min, UInt64))"
      )

      explicit_zero = w161_guard_nullable_part(parent, "nullable-zero")
      w161_guard_replace_serializer_versions(explicit_zero, %("nullable":0,"string":1))
      nullable_reader = CrystalClick::WidePart.open_typed(explicit_zero, "v")
      nullable_reader.read_nullable_simple_aggregate_uint64_mark_range("v", 0, nullable_reader.mark_count).should eq(
        W161_SIMPLE_AGGREGATE_LIBRARY_NULLABLE_VALUES
      )

      explicit_one = w161_guard_nullable_part(parent, "nullable-one")
      w161_guard_replace_serializer_versions(explicit_one, %("nullable":1,"string":1))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(explicit_one, "v")
      end

      scalar_nullable = w161_guard_scalar_part(parent, "scalar-nullable-version")
      w161_guard_replace_serializer_versions(scalar_nullable, %("nullable":0,"string":1))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(scalar_nullable, "v")
      end
    end
  end
end
