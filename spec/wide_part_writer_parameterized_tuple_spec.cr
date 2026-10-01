require "./spec_helper"
require "json"

private def w101_writer_tuple_type(columns : Array(CrystalClick::WideTupleLeafColumn)) : String
  "Tuple(#{columns.map { |column| "#{column.name} #{column.type_name}" }.join(", ")})"
end

private def w101_writer_u64_bytes(values : Array(UInt64)) : Array(UInt8)
  bytes = Bytes.new(values.size * 8)
  values.each_with_index do |value, index|
    8.times do |offset|
      bytes[index * 8 + offset] = ((value >> (offset * 8)) & 0xff_u64).to_u8
    end
  end
  bytes.to_a
end

private def w101_writer_signed_le(value : Int128, width : Int32) : Array(UInt8)
  bits = value.unsafe_as(UInt128)
  Array(UInt8).new(width) do |index|
    ((bits >> (index * 8)) & 0xff_u128).to_u8
  end
end

private def w101_writer_u128_le(value : UInt128) : Array(UInt8)
  Array(UInt8).new(16) do |index|
    ((value >> (index * 8)) & 0xff_u128).to_u8
  end
end

private def w101_writer_decimal256_le(value : CrystalClick::Decimal256Value) : Array(UInt8)
  w101_writer_u128_le(value.low) + w101_writer_u128_le(value.high)
end

private def w101_writer_stream_bytes(part : String, stream : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w101_writer_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w101_writer_mark_rows(part : String, stream : String) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  raise "malformed W101 mark file for #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    w101_writer_read_u64(bytes, index * CrystalClick::WidePart::MARK_SIZE + 16)
  end
end

private def w101_writer_stage_factory(calls : Array(Int32), paths : Array(String)? = nil) : Proc(String, String)
  ->(parent : String) do
    calls << 1
    stage = File.tempname(".w101-parameterized-stage-", nil, dir: parent)
    Dir.mkdir(stage)
    if collected_paths = paths
      collected_paths << stage
    end
    stage
  end
end

private def w101_writer_string_copy(calls : Array(Int32)) : Proc(CrystalClick::WideTupleLeafColumn, Array(String))
  ->(column : CrystalClick::WideTupleLeafColumn) do
    calls << 1
    column.string_values
  end
end

module CrystalClick
  module WidePartWriter
    class TuplePartWriter
      def self.w101_test_validate_staged_part(
        stage : String,
        input : TuplePartWriteInput,
        infrastructure : TuplePartInfrastructure,
      ) : Nil
        validate_staged_part(stage, input, infrastructure)
      end
    end

    def self.w101_test_write_with_stage_factory(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      type_name : String,
      columns : Array(WideTupleLeafColumn),
      rows_per_mark : Int32,
      stage_factory : Proc(String, String),
      copy_string_values : Proc(WideTupleLeafColumn, Array(String)),
    ) : String
      write_uint64_tuple_pair_with_stage_factory(
        destination, key_name, keys, value_name, type_name, columns, rows_per_mark,
        stage_factory, copy_string_values
      )
    end

    # The W101 expected-input attacks intentionally hold the canonical type
    # plan and on-disk stage fixed while replacing only detached owned values.
    def self.w101_test_validate_tuple_stage(
      stage : String,
      key_name : String,
      keys : Array(UInt64),
      value_name : String,
      type_name : String,
      expected_leaf_buffers : Array(WideTupleLeafColumn::Buffer),
      rows_per_mark : Int32,
    ) : Nil
      type_plan = WideTupleTypePlan.for_type(type_name) || raise "invalid W101 Tuple test type"
      logical_streams = [key_name] + type_plan.physical_streams(value_name)
      mark_count = checked_mark_count(keys.size, rows_per_mark)
      input = TuplePartWriteInput.new(
        File.join(File.dirname(stage), "not-published"),
        File.dirname(stage),
        key_name,
        keys.dup,
        value_name,
        type_plan,
        expected_leaf_buffers,
        Array(Array(UInt8)?).new(expected_leaf_buffers.size, nil),
        logical_streams,
        Array(Int64).new(logical_streams.size, 0_i64),
        Array(UInt64).new(logical_streams.size, 0_u64),
        mark_count,
        rows_per_mark,
        File.read(File.join(stage, "columns.txt")),
        File.read(File.join(stage, "columns_substreams.txt")),
        File.read(File.join(stage, "serialization.json")),
      )
      infrastructure = build_tuple_part_infrastructure(
        ->(parent : String) { create_stage(parent) },
        ->(column : WideTupleLeafColumn) { column.string_values }
      )
      TuplePartWriter.w101_test_validate_staged_part(stage, input, infrastructure)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes FixedString, Enum and all Decimal widths with exact streams, marks and storage defaults" do
    enum8_definition = CrystalClick::WideTupleEnumDefinition.new(
      :enum8,
      [{"low", -2_i16}, {"zero", 0_i16}, {"high", 3_i16}] of Tuple(String, Int16)
    )
    enum16_definition = CrystalClick::WideTupleEnumDefinition.new(
      :enum16,
      [{"low", -300_i16}, {"zero", 0_i16}, {"high", 1024_i16}] of Tuple(String, Int16)
    )
    fixed_values = [
      CrystalClick::FixedStringValue.new(3_i32, ""),
      CrystalClick::FixedStringValue.new(3_i32, "A"),
      CrystalClick::FixedStringValue.from_raw(3_i32, Bytes[0x00_u8, 0xff_u8, 0x00_u8]),
      CrystalClick::FixedStringValue.new(3_i32, "z"),
      CrystalClick::FixedStringValue.from_raw(3_i32, Bytes[0x00_u8, 0x00_u8, 0x00_u8]),
    ] of CrystalClick::FixedStringValue
    enum8_values = [
      CrystalClick::Enum8Value.new(enum8_definition, 0_i8),
      CrystalClick::Enum8Value.new(enum8_definition, -2_i8),
      CrystalClick::Enum8Value.new(enum8_definition, 3_i8),
      CrystalClick::Enum8Value.new(enum8_definition, -2_i8),
      CrystalClick::Enum8Value.new(enum8_definition, -2_i8),
    ] of CrystalClick::Enum8Value
    enum16_values = [
      CrystalClick::Enum16Value.new(enum16_definition, 0_i16),
      CrystalClick::Enum16Value.new(enum16_definition, 1024_i16),
      CrystalClick::Enum16Value.new(enum16_definition, -300_i16),
      CrystalClick::Enum16Value.new(enum16_definition, 1024_i16),
      CrystalClick::Enum16Value.new(enum16_definition, 0_i16),
    ] of CrystalClick::Enum16Value
    decimal32_values = [0_i32, -1_i32, 256_i32, Int32::MIN, 0_i32].map do |raw|
      CrystalClick::Decimal32Value.new(raw, 9_i32, 2_i32)
    end
    decimal64_values = [0_i64, -2_i64, 123_i64, Int64::MIN, 4_i64].map do |raw|
      CrystalClick::Decimal64Value.new(raw, 18_i32, 3_i32)
    end
    decimal128_values = [0_i128, 1_i128, -2_i128, Int128::MIN, 5_i128].map do |raw|
      CrystalClick::Decimal128Value.new(raw, 38_i32, 4_i32)
    end
    decimal256_values = [0_i128, -1_i128, 123_i128, Int128::MIN, 0_i128].map do |raw|
      CrystalClick::Decimal256TupleValue.new(
        CrystalClick::Decimal256Value.from_int128(raw), 76_i32, 5_i32
      )
    end

    columns = [
      CrystalClick::WideTupleLeafColumn.new("fixed", CrystalClick::WideTupleFixedStringType.new(3_i32), fixed_values),
      CrystalClick::WideTupleLeafColumn.new("state8", CrystalClick::WideTupleEnumType.new(enum8_definition), enum8_values),
      CrystalClick::WideTupleLeafColumn.new("state16", CrystalClick::WideTupleEnumType.new(enum16_definition), enum16_values),
      CrystalClick::WideTupleLeafColumn.new("d32", CrystalClick::WideTupleDecimalType.new(9_i32, 2_i32), decimal32_values),
      CrystalClick::WideTupleLeafColumn.new("d64", CrystalClick::WideTupleDecimalType.new(18_i32, 3_i32), decimal64_values),
      CrystalClick::WideTupleLeafColumn.new("d128", CrystalClick::WideTupleDecimalType.new(38_i32, 4_i32), decimal128_values),
      CrystalClick::WideTupleLeafColumn.new("d256", CrystalClick::WideTupleDecimalType.new(76_i32, 5_i32), decimal256_values),
    ] of CrystalClick::WideTupleLeafColumn
    schema_names = ["fixed", "state8", "state16", "d32", "d64", "d128", "d256"]
    columns.map(&.name).should eq(schema_names)
    type_name = w101_writer_tuple_type(columns)
    plan = CrystalClick::WideTupleTypePlan.for_type(type_name).not_nil!
    keys = [1_u64, 3_u64, 5_u64, 8_u64, 9_u64]
    fixed_payload_bytes = (fixed_values.size * 3).to_u64
    leaf_owner_bytes = 0_u64
    columns.each do |column|
      name_bytes = column.leaf_type.base_type_name.bytesize.to_u64
      leaf_owner_bytes += instance_sizeof(CrystalClick::WideTupleLeafType).to_u64 +
                          instance_sizeof(String).to_u64 + name_bytes + 1_u64
    end
    descriptor_bytes = 0_u64
    columns.each do |column|
      descriptor_bytes += column.parameterized_type.not_nil!.logical_charge
    end
    # Independently account for the retained synthetic root and seven leaf
    # nodes, including each node's child-array header and each owned local
    # name. The flattened fields retain a separate one-segment path array and
    # String for each name; `WideTupleField#name` itself is derived on access.
    schema_node_header_bytes = instance_sizeof(CrystalClick::WideTupleSchemaNode).to_u64 +
                               instance_sizeof(Array(CrystalClick::WideTupleSchemaNode)).to_u64
    schema_tree_bytes = schema_node_header_bytes +
                        schema_names.size.to_u64 * sizeof(Pointer(CrystalClick::WideTupleSchemaNode)).to_u64
    path_metadata_bytes = 0_u64
    schema_names.each do |name|
      owned_name_bytes = instance_sizeof(String).to_u64 + name.bytesize.to_u64 + 1_u64
      schema_tree_bytes += schema_node_header_bytes + owned_name_bytes
      path_metadata_bytes += instance_sizeof(Array(String)).to_u64 +
                             sizeof(Pointer(String)).to_u64 + owned_name_bytes
    end
    row_charge = CrystalClick::WideTupleTypePlan::RESULT_ROW_ACCOUNTING_BYTES +
                 sizeof(CrystalClick::FixedStringValue).to_u64 +
                 sizeof(CrystalClick::Enum8Value).to_u64 +
                 sizeof(CrystalClick::Enum16Value).to_u64 +
                 sizeof(CrystalClick::Decimal32Value).to_u64 +
                 sizeof(CrystalClick::Decimal64Value).to_u64 +
                 sizeof(CrystalClick::Decimal128Value).to_u64 +
                 sizeof(CrystalClick::Decimal256TupleValue).to_u64
    expected_plan_charge = CrystalClick::WideTupleTypePlan::RESULT_CONTAINER_ACCOUNTING_BYTES +
                           columns.size.to_u64 * CrystalClick::WideTupleTypePlan::FIELD_CONTAINER_ACCOUNTING_BYTES +
                           keys.size.to_u64 * row_charge +
                           fixed_payload_bytes + leaf_owner_bytes + descriptor_bytes +
                           schema_tree_bytes + path_metadata_bytes
    plan.materialization_charge(keys.size.to_u64, fixed_payload_bytes).should eq(expected_plan_charge)
    parent = File.tempname("crystal-click-wide-writer-parameterized")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    stage_calls = [] of Int32
    string_copy_calls = [] of Int32

    begin
      CrystalClick::WidePartWriter.w101_test_write_with_stage_factory(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, 2,
        w101_writer_stage_factory(stage_calls), w101_writer_string_copy(string_copy_calls)
      ).should eq(destination)
      stage_calls.should eq([1])
      # Parameterized values stay nominal; they are never coerced through the
      # existing String-copy callback.
      string_copy_calls.should be_empty

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
      )
      streams = columns.map { |column| "payload%2E#{column.name}" }
      expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n#{streams.size} substreams for column `payload`:\n"
      streams.each { |stream| expected_substreams += "\t#{stream}\n" }
      File.read(File.join(destination, "columns_substreams.txt")).should eq(expected_substreams)

      expected_streams = [
        {"pk", w101_writer_u64_bytes(keys)},
        {"payload%2Efixed", fixed_values.flat_map { |value| value.raw_bytes.to_a }},
        {"payload%2Estate8", enum8_values.flat_map { |value| w101_writer_signed_le(value.code.to_i128, 1) }},
        {"payload%2Estate16", enum16_values.flat_map { |value| w101_writer_signed_le(value.code.to_i128, 2) }},
        {"payload%2Ed32", decimal32_values.flat_map { |value| w101_writer_signed_le(value.raw.to_i128, 4) }},
        {"payload%2Ed64", decimal64_values.flat_map { |value| w101_writer_signed_le(value.raw.to_i128, 8) }},
        {"payload%2Ed128", decimal128_values.flat_map { |value| w101_writer_signed_le(value.raw, 16) }},
        {"payload%2Ed256", decimal256_values.flat_map { |value| w101_writer_decimal256_le(value.raw) }},
      ] of Tuple(String, Array(UInt8))
      expected_streams.each do |stream, expected_bytes|
        w101_writer_stream_bytes(destination, stream).should eq(expected_bytes)
        w101_writer_mark_rows(destination, stream).should eq([2_u64, 2_u64, 1_u64, 0_u64])
      end

      expected_checksum_files = ["count.txt", "primary.idx", "serialization.json"] of String
      checksums = CrystalClick::PartChecksums.open(destination)
      expected_streams.each do |stream, expected_bytes|
        base = CrystalClick::StreamName.hash(stream)
        expected_checksum_files << "#{base}.bin"
        expected_checksum_files << "#{base}.mrk2"
        checksums.entry("#{base}.bin").not_nil!.uncompressed_size.should eq(expected_bytes.size.to_u64)
        # This validator is intentionally size-only; byte contents are checked
        # above by independent exact stream expectations.
        checksums.validate_selected_entries(destination, "#{base}.bin", "#{base}.mrk2")
      end
      checksums.entries.keys.sort.should eq(expected_checksum_files.sort)

      serialization = JSON.parse(File.read(File.join(destination, "serialization.json")))
      payload_record = serialization["columns"].as_a.find do |column|
        column["name"].as_s == "payload"
      end.not_nil!
      payload_record["num_defaults"].as_i.should eq(1)
      payload_record["subcolumns"].as_a.map { |column| column["num_defaults"].as_i }.should eq(
        [2, 1, 2, 2, 1, 1, 2]
      )
      # The SQL Enum default is the smallest declared code. Tuple storage
      # statistics instead count raw-zero codes: Enum8=1, Enum16=2 here.

      part = CrystalClick::WidePart.open_typed(destination, "payload")
      part.row_count.should eq(keys.size.to_u64)
      part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      decoded = part.read_tuple_mark_range("payload", 0, part.mark_count)
      decoded.fields.map(&.type_name).should eq(columns.map(&.type_name))
      decoded.fields.each_with_index do |field, index|
        field.parameterized_type.should eq(columns[index].parameterized_type)
        decoded.columns[index].parameterized_type.should eq(columns[index].parameterized_type)
        decoded.columns[index].values.should eq(columns[index].values)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects FixedString width, Enum map, and Decimal precision mismatches before staging" do
    parent = File.tempname("crystal-click-wide-writer-parameterized-preflight")
    Dir.mkdir(parent)
    stage_calls = [] of Int32
    copy_calls = [] of Int32
    factory = w101_writer_stage_factory(stage_calls)
    keys = [1_u64]

    expected_enum_definition = CrystalClick::WideTupleEnumDefinition.new(
      :enum8,
      [{"disabled", -1_i16}, {"active", 3_i16}] of Tuple(String, Int16)
    )
    changed_enum_definition = CrystalClick::WideTupleEnumDefinition.new(
      :enum8,
      [{"disabled", -1_i16}, {"enabled", 3_i16}] of Tuple(String, Int16)
    )

    invalid_cases = [
      {
        "Tuple(id FixedString(3))",
        [CrystalClick::WideTupleLeafColumn.new(
          "id", CrystalClick::WideTupleFixedStringType.new(4_i32),
          [CrystalClick::FixedStringValue.new(4_i32, "x")]
        )] of CrystalClick::WideTupleLeafColumn,
      },
      {
        "Tuple(state Enum8('disabled' = -1, 'active' = 3))",
        [CrystalClick::WideTupleLeafColumn.new(
          "state", CrystalClick::WideTupleEnumType.new(changed_enum_definition),
          [CrystalClick::Enum8Value.new(changed_enum_definition, 3_i8)]
        )] of CrystalClick::WideTupleLeafColumn,
      },
      {
        "Tuple(amount Decimal(20, 4))",
        [CrystalClick::WideTupleLeafColumn.new(
          "amount", CrystalClick::WideTupleDecimalType.new(21_i32, 4_i32),
          [CrystalClick::Decimal128Value.new(7_i128, 21_i32, 4_i32)]
        )] of CrystalClick::WideTupleLeafColumn,
      },
    ] of Tuple(String, Array(CrystalClick::WideTupleLeafColumn))

    begin
      invalid_cases.each_with_index do |(type_name, columns), index|
        destination = File.join(parent, "invalid-#{index}")
        expect_raises(ArgumentError) do
          CrystalClick::WidePartWriter.w101_test_write_with_stage_factory(
            destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, 1,
            factory, w101_writer_string_copy(copy_calls)
          )
        end
        File.exists?(destination).should be_false
        Dir.children(parent).should be_empty
      end

      # Empty-key rejection is its own earlier writer guard. It deliberately
      # does not claim that an empty leaf's retained descriptor was compared.
      empty_fixed = [
        CrystalClick::WideTupleLeafColumn.new(
          "id", CrystalClick::WideTupleFixedStringType.new(3_i32),
          [] of CrystalClick::FixedStringValue
        ),
      ] of CrystalClick::WideTupleLeafColumn
      expect_raises(ArgumentError, "columns must contain the same nonzero row count") do
        CrystalClick::WidePartWriter.w101_test_write_with_stage_factory(
          File.join(parent, "empty-keys"), "pk", Slice(UInt64).new(0), "payload",
          "Tuple(id FixedString(3))", empty_fixed, 1, factory, w101_writer_string_copy(copy_calls)
        )
      end

      stage_calls.should be_empty
      copy_calls.should be_empty
      Dir.children(parent).should be_empty
      # Keep the expected map live in the test to make the semantic distinction
      # explicit: same raw code is not enough if its Enum descriptor differs.
      expected_enum_definition.should_not eq(changed_enum_definition)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "charges parameterized owned wrappers and FixedString payload before staging" do
    parent = File.tempname("crystal-click-wide-writer-parameterized-budget")
    Dir.mkdir(parent)
    stage_calls = [] of Int32
    copy_calls = [] of Int32
    width = 32_768_i32
    rows = 1_025
    repeated_value = CrystalClick::FixedStringValue.new(width, "")
    repeated_values = Array(CrystalClick::FixedStringValue).new(rows, repeated_value)
    columns = [
      CrystalClick::WideTupleLeafColumn.new(
        "left", CrystalClick::WideTupleFixedStringType.new(width), repeated_values
      ),
      CrystalClick::WideTupleLeafColumn.new(
        "right", CrystalClick::WideTupleFixedStringType.new(width), repeated_values
      ),
    ] of CrystalClick::WideTupleLeafColumn
    type_name = w101_writer_tuple_type(columns)
    keys = Array(UInt64).new(rows) { |index| index.to_u64 + 1_u64 }
    destination = File.join(parent, "over-budget")
    payload_bytes = rows.to_u64 * width.to_u64 * 2_u64
    payload_bytes.should be > CrystalClick::WideTupleTypePlan::MAX_MATERIALIZED_BYTES

    begin
      expect_raises(ArgumentError, "Tuple materialization charge exceeds limit") do
        CrystalClick::WidePartWriter.w101_test_write_with_stage_factory(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, rows,
          w101_writer_stage_factory(stage_calls), w101_writer_string_copy(copy_calls)
        )
      end
      stage_calls.should be_empty
      copy_calls.should be_empty
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects same-code Enum-map and same-coefficient Decimal-precision expected-input attacks" do
    parent = File.tempname("crystal-click-wide-writer-parameterized-expected-mismatch")
    Dir.mkdir(parent)
    destination = File.join(parent, "canonical")
    keys = [1_u64, 2_u64, 4_u64]
    expected_enum_definition = CrystalClick::WideTupleEnumDefinition.new(
      :enum8,
      [{"disabled", -1_i16}, {"active", 3_i16}] of Tuple(String, Int16)
    )
    changed_enum_definition = CrystalClick::WideTupleEnumDefinition.new(
      :enum8,
      [{"disabled", -1_i16}, {"enabled", 3_i16}] of Tuple(String, Int16)
    )
    enum_values = [
      CrystalClick::Enum8Value.new(expected_enum_definition, 3_i8),
      CrystalClick::Enum8Value.new(expected_enum_definition, -1_i8),
      CrystalClick::Enum8Value.new(expected_enum_definition, 3_i8),
    ] of CrystalClick::Enum8Value
    decimal_values = [
      CrystalClick::Decimal128Value.new(123_i128, 20_i32, 4_i32),
      CrystalClick::Decimal128Value.new(0_i128, 20_i32, 4_i32),
      CrystalClick::Decimal128Value.new(-123_i128, 20_i32, 4_i32),
    ] of CrystalClick::Decimal128Value
    columns = [
      CrystalClick::WideTupleLeafColumn.new(
        "state", CrystalClick::WideTupleEnumType.new(expected_enum_definition), enum_values
      ),
      CrystalClick::WideTupleLeafColumn.new(
        "amount", CrystalClick::WideTupleDecimalType.new(20_i32, 4_i32), decimal_values
      ),
    ] of CrystalClick::WideTupleLeafColumn
    type_name = w101_writer_tuple_type(columns)
    stage_calls = [] of Int32
    copy_calls = [] of Int32

    begin
      CrystalClick::WidePartWriter.w101_test_write_with_stage_factory(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, 2,
        w101_writer_stage_factory(stage_calls), w101_writer_string_copy(copy_calls)
      ).should eq(destination)
      stage_calls.should eq([1])
      copy_calls.should be_empty

      original_buffers = [] of CrystalClick::WideTupleLeafColumn::Buffer
      columns.each { |column| original_buffers << column.physical_values }
      CrystalClick::WidePartWriter.w101_test_validate_tuple_stage(
        destination, "pk", keys, "payload", type_name, original_buffers, 2
      )

      forged_enum_values = enum_values.map do |value|
        CrystalClick::Enum8Value.new(changed_enum_definition, value.code)
      end
      changed_map_buffers = original_buffers.dup
      changed_map_buffers[0] = forged_enum_values
      # Same raw signed codes, different label/code map. The on-disk part is
      # unchanged and the plan still records the canonical original map.
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w101_test_validate_tuple_stage(
          destination, "pk", keys, "payload", type_name, changed_map_buffers, 2
        )
      end

      forged_decimal_values = decimal_values.map do |value|
        CrystalClick::Decimal128Value.new(value.raw, 21_i32, value.scale)
      end
      changed_precision_buffers = original_buffers.dup
      changed_precision_buffers[1] = forged_decimal_values
      # Same signed coefficients and scale, different exact P. SQL storage
      # family equality cannot authorize precision erasure in writer checks.
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w101_test_validate_tuple_stage(
          destination, "pk", keys, "payload", type_name, changed_precision_buffers, 2
        )
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "removes its staged parameterized part if exclusive publication fails" do
    parent = File.tempname("crystal-click-wide-writer-parameterized-publication")
    Dir.mkdir(parent)
    destination = File.join(parent, "collision")
    keys = [1_u64, 2_u64]
    columns = [
      CrystalClick::WideTupleLeafColumn.new(
        "id", CrystalClick::WideTupleFixedStringType.new(2_i32),
        [CrystalClick::FixedStringValue.new(2_i32, "a"), CrystalClick::FixedStringValue.new(2_i32, "b")]
      ),
      CrystalClick::WideTupleLeafColumn.new(
        "amount", CrystalClick::WideTupleDecimalType.new(9_i32, 0_i32),
        [CrystalClick::Decimal32Value.new(1_i32, 9_i32, 0_i32), CrystalClick::Decimal32Value.new(2_i32, 9_i32, 0_i32)]
      ),
    ] of CrystalClick::WideTupleLeafColumn
    type_name = w101_writer_tuple_type(columns)
    stage_calls = [] of Int32
    stages = [] of String
    factory = ->(stage_parent : String) do
      stage_calls << 1
      stage = File.tempname(".w101-publication-stage-", nil, dir: stage_parent)
      Dir.mkdir(stage)
      stages << stage
      Dir.mkdir(destination)
      stage
    end

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.w101_test_write_with_stage_factory(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, 1,
          factory, w101_writer_string_copy([] of Int32)
        )
      end
      stage_calls.should eq([1])
      stages.size.should eq(1)
      stages.each { |stage| Dir.exists?(stage).should be_false }
      Dir.children(parent).should eq(["collision"])
      Dir.children(destination).should be_empty
      File.exists?(File.join(destination, "checksums.txt")).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
