require "./spec_helper"

private def w105_nullable_tuple_column(
  name : String,
  base_type_name : String,
  physical_values : CrystalClick::WideTupleLeafColumn::Buffer,
  null_bytes : Array(UInt8),
) : CrystalClick::WideTupleLeafColumn
  leaf_type = CrystalClick::WideTupleLeafType.parse("Nullable(#{base_type_name})") ||
              raise "invalid W105 nullable leaf type: #{base_type_name}"
  null_map = CrystalClick::ScalarNullMap.new(
    null_bytes.to_unsafe.to_slice(null_bytes.size), physical_values.size.to_u64
  )
  CrystalClick::WideTupleLeafColumn.new(name, leaf_type, physical_values, null_map)
end

private def w105_nullable_tuple_stage_factory(calls : Array(Int32)) : Proc(String, String)
  ->(parent : String) do
    calls << 1
    stage = File.tempname(".w105-nullable-tuple-stage-", nil, dir: parent)
    Dir.mkdir(stage)
    stage
  end
end

private def w105_nullable_tuple_string_copy(calls : Array(Int32)) : Proc(CrystalClick::WideTupleLeafColumn, Array(String))
  ->(column : CrystalClick::WideTupleLeafColumn) do
    calls << 1
    if column.leaf_type.nullable?
      column.physical_values.as(Array(String))
    else
      column.string_values
    end
  end
end

private def w105_nullable_tuple_float32_bytes(values : Array(Float32)) : Array(UInt8)
  values.flat_map do |value|
    bits = value.unsafe_as(UInt32)
    Array(UInt8).new(4) { |index| ((bits >> (index * 8)) & 0xff_u32).to_u8 }
  end
end

private def w105_nullable_tuple_float64_bytes(values : Array(Float64)) : Array(UInt8)
  values.flat_map do |value|
    bits = value.unsafe_as(UInt64)
    Array(UInt8).new(8) { |index| ((bits >> (index * 8)) & 0xff_u64).to_u8 }
  end
end

private def w105_nullable_tuple_uint128_bytes(value : UInt128) : Array(UInt8)
  Array(UInt8).new(16) { |index| ((value >> (index * 8)) & 0xff_u128).to_u8 }
end

private def w105_nullable_tuple_int256_bytes(value : CrystalClick::Int256Value) : Array(UInt8)
  w105_nullable_tuple_uint128_bytes(value.low) + w105_nullable_tuple_uint128_bytes(value.high)
end

private def w105_nullable_tuple_stream_bytes(part : String, stream : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w105_nullable_tuple_mark_rows(part : String, stream : String) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  (bytes.size % CrystalClick::WidePart::MARK_SIZE).should eq(0)
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    row_count = 0_u64
    8.times { |byte| row_count |= bytes[offset + byte].to_u64 << (byte * 8) }
    row_count
  end
end

module CrystalClick
  module WidePartWriter
    class TuplePartWriter
      def self.w105_test_validate_staged_part(
        stage : String,
        input : TuplePartWriteInput,
        infrastructure : TuplePartInfrastructure,
      ) : Nil
        validate_staged_part(stage, input, infrastructure)
      end

      def self.w105_test_preflight(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type_name : String,
        columns : Array(WideTupleLeafColumn),
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
      ) : TuplePartWriteInput
        preflight(destination, key_name, keys, value_name, type_name, columns, rows_per_mark, infrastructure)
      end
    end

    def self.w105_test_write_with_stage_factory(
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

    def self.w105_test_validate_expected_input(
      stage : String,
      destination : String,
      key_name : String,
      keys : Array(UInt64),
      value_name : String,
      type_name : String,
      columns : Array(WideTupleLeafColumn),
      rows_per_mark : Int32,
    ) : Nil
      infrastructure = build_tuple_part_infrastructure(
        ->(parent : String) { create_stage(parent) },
        ->(column : WideTupleLeafColumn) do
          if column.leaf_type.nullable?
            column.physical_values.as(Array(String))
          else
            column.string_values
          end
        end
      )
      input = TuplePartWriter.w105_test_preflight(
        destination, key_name, keys.to_unsafe.to_slice(keys.size), value_name,
        type_name, columns, rows_per_mark, infrastructure
      )
      TuplePartWriter.w105_test_validate_staged_part(stage, input, infrastructure)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes Nullable leaves across the existing flat Tuple families with their raw slots and masks" do
    enum_type = "Enum8('minus' = -7, 'plus' = 4)"
    columns = [
      w105_nullable_tuple_column("count", "UInt64", [42_u64, 0_u64, 9_u64] of UInt64, [1_u8, 0_u8, 1_u8]),
      # Noncanonical Bool bytes remain raw; visible reads keep the established
      # nonzero-is-true interpretation.
      w105_nullable_tuple_column("flag", "Bool", [2_u8, 0_u8, 255_u8] of UInt8, [1_u8, 0_u8, 0_u8]),
      w105_nullable_tuple_column("title", "String", ["hidden", "", "z"] of String, [1_u8, 0_u8, 0_u8]),
      w105_nullable_tuple_column(
        "id", "UUID",
        [CrystalClick::UUIDValue.new(0x0102_u64, 0x0304_u64), CrystalClick::UUIDValue.new(0_u64, 0_u64), CrystalClick::UUIDValue.new(5_u64, 6_u64)] of CrystalClick::UUIDValue,
        [1_u8, 0_u8, 0_u8]
      ),
      w105_nullable_tuple_column(
        "stamp", "DateTime('UTC')",
        [CrystalClick::DateTimeValue.new(0x01020304_u32), CrystalClick::DateTimeValue.new(0_u32), CrystalClick::DateTimeValue.new(UInt32::MAX)] of CrystalClick::DateTimeValue,
        [1_u8, 0_u8, 0_u8]
      ),
      w105_nullable_tuple_column(
        "fixed", "FixedString(3)",
        [
          CrystalClick::FixedStringValue.from_raw(3, Bytes[0x41_u8, 0xff_u8, 0_u8]),
          CrystalClick::FixedStringValue.new(3, ""),
          CrystalClick::FixedStringValue.from_raw(3, Bytes[0x7a_u8, 0_u8, 0_u8]),
        ] of CrystalClick::FixedStringValue,
        [1_u8, 0_u8, 0_u8]
      ),
      # 127 is not declared, but is legal in a masked physical slot. Visible
      # Enum values still use the exact declared definition.
      w105_nullable_tuple_column("status", enum_type, [127_i8, -7_i8, 4_i8] of Int8, [1_u8, 0_u8, 0_u8]),
      w105_nullable_tuple_column("amount", "Decimal(9, 2)", [Int32::MIN, 0_i32, -456_i32] of Int32, [1_u8, 0_u8, 0_u8]),
    ] of CrystalClick::WideTupleLeafColumn
    type_name = "Tuple(#{columns.map { |column| "#{column.name} #{column.type_name}" }.join(", ")})"
    keys = [11_u64, 12_u64, 13_u64]
    parent = File.tempname("crystal-click-wide-writer-nullable-tuple-w105")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    stages = [] of Int32
    string_copies = [] of Int32

    begin
      CrystalClick::WidePartWriter.w105_test_write_with_stage_factory(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, 2,
        w105_nullable_tuple_stage_factory(stages), w105_nullable_tuple_string_copy(string_copies)
      ).should eq(destination)

      stages.should eq([1])
      string_copies.should eq([1])
      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n" +
        "1 substreams for column `pk`:\n\tpk\n" +
        "17 substreams for column `payload`:\n" +
        "\tpayload%2Ecount.null\n\tpayload%2Ecount\n" +
        "\tpayload%2Eflag.null\n\tpayload%2Eflag\n" +
        "\tpayload%2Etitle.null\n\tpayload%2Etitle.size\n\tpayload%2Etitle\n" +
        "\tpayload%2Eid.null\n\tpayload%2Eid\n" +
        "\tpayload%2Estamp.null\n\tpayload%2Estamp\n" +
        "\tpayload%2Efixed.null\n\tpayload%2Efixed\n" +
        "\tpayload%2Estatus.null\n\tpayload%2Estatus\n" +
        "\tpayload%2Eamount.null\n\tpayload%2Eamount\n"
      )

      w105_nullable_tuple_stream_bytes(destination, "payload%2Ecount.null").should eq([1_u8, 0_u8, 1_u8])
      w105_nullable_tuple_stream_bytes(destination, "payload%2Ecount").should eq([
        42_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
        0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
        9_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      ])
      w105_nullable_tuple_stream_bytes(destination, "payload%2Eflag").should eq([2_u8, 0_u8, 255_u8])
      w105_nullable_tuple_stream_bytes(destination, "payload%2Etitle.null").should eq([1_u8, 0_u8, 0_u8])
      w105_nullable_tuple_stream_bytes(destination, "payload%2Etitle.size").should eq([
        6_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
        0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
        1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      ])
      w105_nullable_tuple_stream_bytes(destination, "payload%2Etitle").should eq("hiddenz".to_slice.to_a)
      w105_nullable_tuple_stream_bytes(destination, "payload%2Estamp").should eq([
        4_u8, 3_u8, 2_u8, 1_u8, 0_u8, 0_u8, 0_u8, 0_u8,
        255_u8, 255_u8, 255_u8, 255_u8,
      ])
      w105_nullable_tuple_stream_bytes(destination, "payload%2Efixed").should eq([
        0x41_u8, 0xff_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0x7a_u8, 0_u8, 0_u8,
      ])
      w105_nullable_tuple_stream_bytes(destination, "payload%2Estatus").should eq([127_u8, 249_u8, 4_u8])
      w105_nullable_tuple_stream_bytes(destination, "payload%2Eamount").should eq([
        0_u8, 0_u8, 0_u8, 128_u8, 0_u8, 0_u8, 0_u8, 0_u8,
        0x38_u8, 0xfe_u8, 0xff_u8, 0xff_u8,
      ])
      w105_nullable_tuple_mark_rows(destination, "payload%2Ecount.null").should eq([2_u64, 1_u64, 0_u64])
      w105_nullable_tuple_mark_rows(destination, "payload%2Ecount").should eq([2_u64, 1_u64, 0_u64])

      serialization = JSON.parse(File.read(File.join(destination, "serialization.json")))
      payload = serialization["columns"].as_a.find do |record|
        record["name"].as_s == "payload"
      end.not_nil!
      payload["num_defaults"].as_i.should eq(1)
      payload["subcolumns"].as_a.map { |record| record["num_defaults"].as_i }.should eq([2, 1, 1, 1, 1, 1, 1, 1])

      part = CrystalClick::WidePart.open_typed(destination, "payload")
      decoded = part.read_tuple_mark_range("payload", 0, part.mark_count)
      decoded.fields.map(&.type_name).should eq(columns.map(&.type_name))
      decoded.row_count.should eq(keys.size)
      decoded.columns.each_with_index do |actual, index|
        actual.null_map.not_nil!.bytes.should eq(columns[index].null_map.not_nil!.bytes)
        actual.physical_values.should eq(columns[index].physical_values)
      end
      decoded.columns[0].value_at(0).should be_nil
      decoded.columns[0].value_at(1).should eq(0_u64)
      decoded.columns[0].value_at(2).should be_nil
      decoded.columns[0].physical_values.should eq([42_u64, 0_u64, 9_u64])
      decoded.columns[1].value_at(0).should be_nil
      decoded.columns[1].value_at(1).should eq(false)
      decoded.columns[1].value_at(2).should eq(true)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        decoded.columns[1].values_as(Bool)
      end
      decoded.columns[6].value_at(0).should be_nil
      decoded.columns[6].value_at(1).should eq(CrystalClick::Enum8Value.new(
        columns[6].leaf_type.parameterized_type.as(CrystalClick::WideTupleEnumType).definition, -7_i8
      ))

      # A reader-to-writer copy must preserve NULL-hidden payload, not rebuild
      # it from the Nil-filtered semantic values.
      copy_destination = File.join(parent, "copy")
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        copy_destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, decoded.columns, 2
      ).should eq(copy_destination)
      Dir.children(destination).sort.should eq(Dir.children(copy_destination).sort)
      Dir.children(destination).each do |name|
        File.read(File.join(copy_destination, name)).should eq(File.read(File.join(destination, name)))
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes all-NULL rows while retaining their explicit hidden physical slots" do
    parent = File.tempname("crystal-click-wide-writer-nullable-tuple-w105-all-null")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    enum_type = "Enum8('first' = -7, 'second' = 4)"
    columns = [
      w105_nullable_tuple_column("status", enum_type, [0_i8, -7_i8, 127_i8] of Int8, [1_u8, 1_u8, 1_u8]),
    ] of CrystalClick::WideTupleLeafColumn
    type_name = "Tuple(status #{columns[0].type_name})"
    keys = [1_u64, 2_u64, 3_u64]

    begin
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, 2
      ).should eq(destination)
      w105_nullable_tuple_stream_bytes(destination, "payload%2Estatus.null").should eq([1_u8, 1_u8, 1_u8])
      w105_nullable_tuple_stream_bytes(destination, "payload%2Estatus").should eq([0_u8, 249_u8, 127_u8])
      serialization = JSON.parse(File.read(File.join(destination, "serialization.json")))
      payload = serialization["columns"].as_a.find do |record|
        record["name"].as_s == "payload"
      end.not_nil!
      payload["num_defaults"].as_i.should eq(3)
      payload["subcolumns"].as_a.map { |record| record["num_defaults"].as_i }.should eq([3])
      decoded = CrystalClick::WidePart.open_typed(destination, "payload")
        .read_tuple_mark_range("payload", 0, 2)
      decoded.columns[0].value_at(0).should be_nil
      decoded.columns[0].value_at(1).should be_nil
      decoded.columns[0].value_at(2).should be_nil
      decoded.columns[0].physical_values.should eq([0_i8, -7_i8, 127_i8])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "combines bare storage defaults and Nullable masks for mixed Tuple defaults" do
    parent = File.tempname("crystal-click-wide-writer-nullable-tuple-w105-mixed-defaults")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    enum_type = "Enum8('minus' = -7, 'plus' = 4)"
    columns = [
      CrystalClick::WideTupleLeafColumn.new("count", [0_u64, 9_u64, 0_u64, 9_u64] of UInt64),
      CrystalClick::WideTupleLeafColumn.new("title", ["", "", "x", ""] of String),
      w105_nullable_tuple_column("status", enum_type, [-7_i8, -7_i8, -7_i8, 4_i8] of Int8, [1_u8, 0_u8, 1_u8, 0_u8]),
      w105_nullable_tuple_column("flag", "Bool", [0_u8, 0_u8, 2_u8, 0_u8] of UInt8, [1_u8, 0_u8, 0_u8, 1_u8]),
    ] of CrystalClick::WideTupleLeafColumn
    type_name = "Tuple(count UInt64, title String, status Nullable(#{enum_type}), flag Nullable(Bool))"
    keys = [1_u64, 2_u64, 3_u64, 4_u64]

    begin
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, 2
      ).should eq(destination)

      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n" +
        "1 substreams for column `pk`:\n\tpk\n" +
        "7 substreams for column `payload`:\n" +
        "\tpayload%2Ecount\n" +
        "\tpayload%2Etitle.size\n\tpayload%2Etitle\n" +
        "\tpayload%2Estatus.null\n\tpayload%2Estatus\n" +
        "\tpayload%2Eflag.null\n\tpayload%2Eflag\n"
      )
      w105_nullable_tuple_stream_bytes(destination, "payload%2Estatus.null").should eq([1_u8, 0_u8, 1_u8, 0_u8])
      w105_nullable_tuple_stream_bytes(destination, "payload%2Estatus").should eq([249_u8, 249_u8, 249_u8, 4_u8])
      w105_nullable_tuple_stream_bytes(destination, "payload%2Eflag.null").should eq([1_u8, 0_u8, 0_u8, 1_u8])
      w105_nullable_tuple_stream_bytes(destination, "payload%2Eflag").should eq([0_u8, 0_u8, 2_u8, 0_u8])

      serialization = JSON.parse(File.read(File.join(destination, "serialization.json")))
      payload = serialization["columns"].as_a.find do |record|
        record["name"].as_s == "payload"
      end.not_nil!
      payload["num_defaults"].as_i.should eq(1)
      payload["subcolumns"].as_a.map { |record| record["num_defaults"].as_i }.should eq([2, 3, 2, 2])

      part = CrystalClick::WidePart.open_typed(destination, "payload")
      decoded = part.read_tuple_mark_range("payload", 0, part.mark_count)
      decoded.columns[0].value_at(0).should eq(0_u64)
      decoded.columns[1].value_at(0).should eq("")
      decoded.columns[2].value_at(0).should be_nil
      decoded.columns[3].value_at(0).should be_nil
      decoded.columns[2].value_at(1).should eq(CrystalClick::Enum8Value.new(
        columns[2].leaf_type.parameterized_type.as(CrystalClick::WideTupleEnumType).definition, -7_i8
      ))
      decoded.columns[3].value_at(1).should eq(false)
      decoded.columns[2].value_at(2).should be_nil
      decoded.columns[3].value_at(2).should eq(true)
      decoded.columns[2].value_at(3).should eq(CrystalClick::Enum8Value.new(
        columns[2].leaf_type.parameterized_type.as(CrystalClick::WideTupleEnumType).definition, 4_i8
      ))
      decoded.columns[3].value_at(3).should be_nil

      copy_destination = File.join(parent, "copy")
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        copy_destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, decoded.columns, 2
      ).should eq(copy_destination)
      Dir.children(destination).sort.should eq(Dir.children(copy_destination).sort)
      Dir.children(destination).each do |name|
        File.read(File.join(copy_destination, name)).should eq(File.read(File.join(destination, name)))
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves Nullable Float32 and Float64 NaN payloads and signed-zero bits" do
    parent = File.tempname("crystal-click-wide-writer-nullable-tuple-w105-float-bits")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    fake_destination = File.join(parent, "expected-only")
    float32_values = [
      0x7fc0_1234_u32.unsafe_as(Float32), # masked NaN payload
      0x8000_0000_u32.unsafe_as(Float32), # visible -0
      0x8000_0000_u32.unsafe_as(Float32), # masked -0
      0x7fc1_abcd_u32.unsafe_as(Float32), # visible NaN payload
    ] of Float32
    float64_values = [
      0x8000_0000_0000_0000_u64.unsafe_as(Float64), # masked -0
      0x7ff8_0000_0001_2345_u64.unsafe_as(Float64), # visible NaN payload
      0x7ff8_ffff_1234_5678_u64.unsafe_as(Float64), # masked NaN payload
      0x8000_0000_0000_0000_u64.unsafe_as(Float64), # visible -0
    ] of Float64
    masks = [1_u8, 0_u8, 1_u8, 0_u8]
    columns = [
      w105_nullable_tuple_column("f32", "Float32", float32_values, masks),
      w105_nullable_tuple_column("f64", "Float64", float64_values, masks),
    ] of CrystalClick::WideTupleLeafColumn
    type_name = "Tuple(f32 Nullable(Float32), f64 Nullable(Float64))"
    keys = [1_u64, 2_u64, 3_u64, 4_u64]

    begin
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, 2
      ).should eq(destination)

      w105_nullable_tuple_stream_bytes(destination, "payload%2Ef32.null").should eq(masks)
      w105_nullable_tuple_stream_bytes(destination, "payload%2Ef32").should eq(
        w105_nullable_tuple_float32_bytes(float32_values)
      )
      w105_nullable_tuple_stream_bytes(destination, "payload%2Ef64.null").should eq(masks)
      w105_nullable_tuple_stream_bytes(destination, "payload%2Ef64").should eq(
        w105_nullable_tuple_float64_bytes(float64_values)
      )

      decoded = CrystalClick::WidePart.open_typed(destination, "payload")
        .read_tuple_mark_range("payload", 0, 2)
      decoded.columns[0].physical_values.as(Array(Float32)).map(&.unsafe_as(UInt32)).should eq(
        [0x7fc0_1234_u32, 0x8000_0000_u32, 0x8000_0000_u32, 0x7fc1_abcd_u32]
      )
      decoded.columns[1].physical_values.as(Array(Float64)).map(&.unsafe_as(UInt64)).should eq(
        [0x8000_0000_0000_0000_u64, 0x7ff8_0000_0001_2345_u64,
         0x7ff8_ffff_1234_5678_u64, 0x8000_0000_0000_0000_u64]
      )
      decoded.columns[0].value_at(0).should be_nil
      decoded.columns[0].value_at(1).as(Float32).unsafe_as(UInt32).should eq(0x8000_0000_u32)
      decoded.columns[0].value_at(2).should be_nil
      decoded.columns[0].value_at(3).as(Float32).unsafe_as(UInt32).should eq(0x7fc1_abcd_u32)
      decoded.columns[1].value_at(0).should be_nil
      decoded.columns[1].value_at(1).as(Float64).unsafe_as(UInt64).should eq(0x7ff8_0000_0001_2345_u64)
      decoded.columns[1].value_at(2).should be_nil
      decoded.columns[1].value_at(3).as(Float64).unsafe_as(UInt64).should eq(0x8000_0000_0000_0000_u64)

      # A different NaN payload under the same NULL mask must not pass the
      # staged physical comparator merely because NaN is not equal to itself.
      wrong_nan_values = float32_values.dup
      wrong_nan_values[0] = 0x7fc0_1235_u32.unsafe_as(Float32)
      wrong_nan_columns = [
        w105_nullable_tuple_column("f32", "Float32", wrong_nan_values, masks), columns[1],
      ] of CrystalClick::WideTupleLeafColumn
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w105_test_validate_expected_input(
          destination, fake_destination, "pk", keys, "payload", type_name, wrong_nan_columns, 2
        )
      end
      File.exists?(fake_destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves Nullable Decimal256 extrema in the raw Int256 carrier" do
    parent = File.tempname("crystal-click-wide-writer-nullable-tuple-w105-decimal256")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    fake_destination = File.join(parent, "expected-only")
    signed_min = CrystalClick::Int256Value.new(0_u128, 1_u128 << 127)
    signed_max = CrystalClick::Int256Value.new(UInt128::MAX, (1_u128 << 127) - 1_u128)
    negative_one = CrystalClick::Int256Value.new(UInt128::MAX, UInt128::MAX)
    zero = CrystalClick::Int256Value.new(0_u128, 0_u128)
    raw_values = [signed_min, signed_max, negative_one, zero] of CrystalClick::Int256Value
    masks = [1_u8, 0_u8, 1_u8, 0_u8]
    columns = [
      w105_nullable_tuple_column("amount", "Decimal(76, 0)", raw_values, masks),
    ] of CrystalClick::WideTupleLeafColumn
    type_name = "Tuple(amount Nullable(Decimal(76, 0)))"
    keys = [1_u64, 2_u64, 3_u64, 4_u64]

    begin
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, 2
      ).should eq(destination)

      w105_nullable_tuple_stream_bytes(destination, "payload%2Eamount.null").should eq(masks)
      w105_nullable_tuple_stream_bytes(destination, "payload%2Eamount").should eq(
        raw_values.flat_map { |value| w105_nullable_tuple_int256_bytes(value) }
      )
      decoded = CrystalClick::WidePart.open_typed(destination, "payload")
        .read_tuple_mark_range("payload", 0, 2)
      decoded.columns[0].physical_values.as(Array(CrystalClick::Int256Value)).map { |value| {value.low, value.high} }.should eq(
        raw_values.map { |value| {value.low, value.high} }
      )
      decoded.columns[0].value_at(0).should be_nil
      decoded.columns[0].value_at(1).should eq(CrystalClick::Decimal256TupleValue.new(
        CrystalClick::Decimal256Value.new(signed_max.low, signed_max.high), 76_i32, 0_i32
      ))
      decoded.columns[0].value_at(2).should be_nil
      decoded.columns[0].value_at(3).should eq(CrystalClick::Decimal256TupleValue.new(
        CrystalClick::Decimal256Value.new(0_u128, 0_u128), 76_i32, 0_i32
      ))

      wrong_raw_values = raw_values.dup
      wrong_raw_values[0] = zero
      wrong_columns = [
        w105_nullable_tuple_column("amount", "Decimal(76, 0)", wrong_raw_values, masks),
      ] of CrystalClick::WideTupleLeafColumn
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w105_test_validate_expected_input(
          destination, fake_destination, "pk", keys, "payload", type_name, wrong_columns, 2
        )
      end
      File.exists?(fake_destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects malformed masks, mismatched row counts, and unsupported timezone leaves before staging" do
    parent = File.tempname("crystal-click-wide-writer-nullable-tuple-w105-preflight")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    stage_calls = [] of Int32
    copy_calls = [] of Int32
    factory = w105_nullable_tuple_stage_factory(stage_calls)
    copy_strings = w105_nullable_tuple_string_copy(copy_calls)

    begin
      expect_raises(ArgumentError) do
        CrystalClick::ScalarNullMap.new(Bytes[0_u8, 2_u8], 2_u64)
      end
      expect_raises(ArgumentError) do
        CrystalClick::ScalarNullMap.new(Bytes[0_u8], 2_u64)
      end

      mismatch = [w105_nullable_tuple_column("value", "UInt64", [1_u64, 2_u64] of UInt64, [0_u8, 0_u8])] of CrystalClick::WideTupleLeafColumn
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.w105_test_write_with_stage_factory(
          File.join(parent, "row-mismatch"), "pk", [1_u64].to_unsafe.to_slice(1), "payload",
          "Tuple(value Nullable(UInt64))", mismatch, 1, factory, copy_strings
        )
      end

      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.w105_test_write_with_stage_factory(
          File.join(parent, "empty-rows"), "pk", ([] of UInt64).to_unsafe.to_slice(0), "payload",
          "Tuple(value Nullable(UInt64))", [] of CrystalClick::WideTupleLeafColumn, 1, factory, copy_strings
        )
      end

      wrong_name = [w105_nullable_tuple_column(
        "other", "UInt64", [1_u64, 2_u64] of UInt64, [0_u8, 0_u8]
      )] of CrystalClick::WideTupleLeafColumn
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.w105_test_write_with_stage_factory(
          File.join(parent, "wrong-name"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          "Tuple(value Nullable(UInt64))", wrong_name, 1, factory, copy_strings
        )
      end

      wrong_type = [w105_nullable_tuple_column(
        "value", "Int64", [1_i64, 2_i64] of Int64, [0_u8, 0_u8]
      )] of CrystalClick::WideTupleLeafColumn
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.w105_test_write_with_stage_factory(
          File.join(parent, "wrong-type"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          "Tuple(value Nullable(UInt64))", wrong_type, 1, factory, copy_strings
        )
      end

      timezone_column = [CrystalClick::WideTupleLeafColumn.new(
        "stamp",
        CrystalClick::DateTimeColumnType.datetime("UTC"),
        [CrystalClick::DateTimeValue.new(1_u32)] of CrystalClick::DateTimeValue
      )] of CrystalClick::WideTupleLeafColumn
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.w105_test_write_with_stage_factory(
          File.join(parent, "unknown-zone"), "pk", [1_u64].to_unsafe.to_slice(1), "payload",
          "Tuple(stamp Nullable(DateTime('W105/Not_A_Zone')))", timezone_column, 1, factory, copy_strings
        )
      end

      stage_calls.should be_empty
      copy_calls.should be_empty
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects hidden Nullable(String) payload over 64 MiB before copying or staging" do
    parent = File.tempname("crystal-click-wide-writer-nullable-tuple-w105-string-budget")
    Dir.mkdir(parent)
    destination = File.join(parent, "over-budget")
    stage_calls = [] of Int32
    copy_calls = [] of Int32
    payload_per_row = (CrystalClick::WideTupleTypePlan::MAX_MATERIALIZED_BYTES // 2_u64).to_i32 + 1_024
    payload_per_row.to_u64.should be < CrystalClick::WidePart::MAX_FRAME_DECOMPRESSED_BYTES.to_u64
    (payload_per_row.to_u64 * 2_u64).should be > CrystalClick::WideTupleTypePlan::MAX_MATERIALIZED_BYTES
    hidden = String.new(Bytes.new(payload_per_row, 0x61_u8))
    columns = [w105_nullable_tuple_column(
      "text", "String", [hidden, hidden] of String, [1_u8, 1_u8]
    )] of CrystalClick::WideTupleLeafColumn
    keys = [1_u64, 2_u64]

    begin
      expect_raises(ArgumentError, "Tuple materialization charge exceeds limit") do
        CrystalClick::WidePartWriter.w105_test_write_with_stage_factory(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          "Tuple(text Nullable(String))", columns, 1,
          w105_nullable_tuple_stage_factory(stage_calls), w105_nullable_tuple_string_copy(copy_calls)
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

  it "rejects a staged raw Enum mismatch hidden by the same NULL mask" do
    parent = File.tempname("crystal-click-wide-writer-nullable-tuple-w105-hidden-raw-attack")
    Dir.mkdir(parent)
    destination = File.join(parent, "canonical")
    fake_destination = File.join(parent, "expected-only")
    enum_type = "Enum8('first' = -7, 'second' = 4)"
    type_name = "Tuple(status Nullable(#{enum_type}))"
    keys = [1_u64, 2_u64]
    canonical = [
      w105_nullable_tuple_column("status", enum_type, [127_i8, 4_i8] of Int8, [1_u8, 0_u8]),
    ] of CrystalClick::WideTupleLeafColumn
    wrong_expected = [
      w105_nullable_tuple_column("status", enum_type, [126_i8, 4_i8] of Int8, [1_u8, 0_u8]),
    ] of CrystalClick::WideTupleLeafColumn

    begin
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, canonical, 1
      ).should eq(destination)

      # The nullable semantic rows are identical (NULL, declared value); only
      # the physically stored masked Enum code differs. The test routes the
      # altered expected snapshot through the real staged validator.
      wrong_expected[0].value_at(0).should be_nil
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w105_test_validate_expected_input(
          destination, fake_destination, "pk", keys, "payload", type_name, wrong_expected, 1
        )
      end
      File.exists?(fake_destination).should be_false
      w105_nullable_tuple_stream_bytes(destination, "payload%2Estatus").should eq([127_u8, 4_u8])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a staged Nullable mask mismatch even when the physical payload is identical" do
    parent = File.tempname("crystal-click-wide-writer-nullable-tuple-w105-mask-attack")
    Dir.mkdir(parent)
    destination = File.join(parent, "canonical")
    fake_destination = File.join(parent, "expected-only")
    type_name = "Tuple(value Nullable(UInt64))"
    keys = [1_u64, 2_u64]
    raw_values = [17_u64, 0_u64] of UInt64
    canonical = [
      w105_nullable_tuple_column("value", "UInt64", raw_values, [1_u8, 0_u8]),
    ] of CrystalClick::WideTupleLeafColumn
    wrong_mask = [
      w105_nullable_tuple_column("value", "UInt64", raw_values, [0_u8, 1_u8]),
    ] of CrystalClick::WideTupleLeafColumn

    begin
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, canonical, 1
      ).should eq(destination)
      wrong_mask[0].physical_values.should eq(canonical[0].physical_values)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w105_test_validate_expected_input(
          destination, fake_destination, "pk", keys, "payload", type_name, wrong_mask, 1
        )
      end
      File.exists?(fake_destination).should be_false
      w105_nullable_tuple_stream_bytes(destination, "payload%2Evalue.null").should eq([1_u8, 0_u8])
      w105_nullable_tuple_stream_bytes(destination, "payload%2Evalue").should eq([
        17_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
        0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      ])
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
