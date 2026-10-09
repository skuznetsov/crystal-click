require "./spec_helper"
require "file_utils"

private def w233_qbit_value(type : CrystalClick::QBitType, seed : UInt8) : CrystalClick::BinaryValue
  raw = Bytes.new(type.raw_row_bytes) { |index| (seed.to_i + index).to_u8 }
  CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(type, raw))
end

private def w233_encoded_values(values : Array(CrystalClick::BinaryValue)) : Array(Bytes)
  values.map { |value| CrystalClick::BinaryValueCodec.encode(value) }
end

private def w233_variant_arm_index(
  variant : CrystalClick::BinaryDataType,
  arm : CrystalClick::BinaryDataType,
) : Int
  variant.child_count.times do |index|
    return index if variant.child_at(index) == arm
  end
  raise ArgumentError.new("W233 Variant fixture arm is absent")
end

private def w233_write_dynamic_part(
  destination : String,
  type : CrystalClick::BinaryDataType,
  structures : Hash(String, CrystalClick::DynamicStructure),
  granules : Array(Array(CrystalClick::BinaryValue)),
  profile : CrystalClick::BinaryBulkProfile,
  rows_per_mark : Int32,
) : String
  row_count = granules.sum(0) { |granule| granule.size }
  keys = Slice(UInt64).new(row_count) { |index| (index + 1).to_u64 * 11_u64 }
  CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
    destination,
    "pk",
    keys,
    "payload",
    type,
    structures,
    granules,
    rows_per_mark: rows_per_mark,
    profile: profile,
    frame_bytes: 16,
  )
end

describe "W233 recursive Dynamic QBit persistence" do
  it "round-trips legal composite actuals in both BASIC Wide profiles through full and window readers" do
    qbit_type = CrystalClick::QBitType.new("Int8", 1_u64)
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    array_qbit = CrystalClick::BinaryDataType.array(qbit)
    map_qbit = CrystalClick::BinaryDataType.map(string, qbit)
    tuple_qbit = CrystalClick::BinaryDataType.tuple(
      [qbit, uint64] of CrystalClick::BinaryDataType,
      ["bits", "n"] of String,
    )
    nested_qbit = CrystalClick::BinaryDataType.nested(
      [qbit, uint64] of CrystalClick::BinaryDataType,
      ["bits", "n"] of String,
    )
    nullable_tuple = CrystalClick::BinaryDataType.nullable(tuple_qbit)
    array_nullable_tuple = CrystalClick::BinaryDataType.array(nullable_tuple)
    embedded_variant = CrystalClick::BinaryDataType.variant(
      [qbit, uint64] of CrystalClick::BinaryDataType,
    )
    array_embedded_variant = CrystalClick::BinaryDataType.array(embedded_variant)
    actual_types = [
      qbit,
      array_qbit,
      map_qbit,
      tuple_qbit,
      nested_qbit,
      array_nullable_tuple,
      array_embedded_variant,
      uint64,
    ] of CrystalClick::BinaryDataType
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: actual_types.size)
    structures = {
      "root" => CrystalClick::DynamicStructure.new(actual_types),
    }

    tuple_value = ->(seed : UInt8, n : UInt64) {
      CrystalClick::BinaryValue.tuple(
        tuple_qbit,
        [w233_qbit_value(qbit_type, seed), CrystalClick::BinaryValue.uint64(n)] of CrystalClick::BinaryValue,
      )
    }
    variant_qbit_index = w233_variant_arm_index(embedded_variant, qbit)
    variant_uint64_index = w233_variant_arm_index(embedded_variant, uint64)

    values = [
      CrystalClick::BinaryValue.dynamic(dynamic, w233_qbit_value(qbit_type, 0x10_u8)),
      CrystalClick::BinaryValue.dynamic(
        dynamic,
        CrystalClick::BinaryValue.array(
          array_qbit,
          [w233_qbit_value(qbit_type, 0x20_u8), w233_qbit_value(qbit_type, 0x21_u8)] of CrystalClick::BinaryValue,
        ),
      ),
      CrystalClick::BinaryValue.dynamic(
        dynamic,
        CrystalClick::BinaryValue.map(
          map_qbit,
          [
            CrystalClick::BinaryValue.string("map-a"), w233_qbit_value(qbit_type, 0x30_u8),
            CrystalClick::BinaryValue.string("map-b"), w233_qbit_value(qbit_type, 0x31_u8),
          ] of CrystalClick::BinaryValue,
        ),
      ),
      CrystalClick::BinaryValue.dynamic(dynamic, tuple_value.call(0x40_u8, 40_u64)),
      CrystalClick::BinaryValue.dynamic(
        dynamic,
        CrystalClick::BinaryValue.nested(
          nested_qbit,
          [tuple_value.call(0x50_u8, 50_u64)] of CrystalClick::BinaryValue,
        ),
      ),
      CrystalClick::BinaryValue.dynamic(
        dynamic,
        CrystalClick::BinaryValue.array(
          array_nullable_tuple,
          [
            CrystalClick::BinaryValue.nullable(nullable_tuple, tuple_value.call(0x60_u8, 60_u64)),
            CrystalClick::BinaryValue.nullable(nullable_tuple),
          ] of CrystalClick::BinaryValue,
        ),
      ),
      CrystalClick::BinaryValue.dynamic(
        dynamic,
        CrystalClick::BinaryValue.array(
          array_embedded_variant,
          [
            CrystalClick::BinaryValue.variant(
              embedded_variant,
              variant_qbit_index,
              w233_qbit_value(qbit_type, 0x70_u8),
            ),
            CrystalClick::BinaryValue.variant(
              embedded_variant,
              variant_uint64_index,
              CrystalClick::BinaryValue.uint64(71_u64),
            ),
          ] of CrystalClick::BinaryValue,
        ),
      ),
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(80_u64)),
      # This is an ordinary shared-overflow value, not a new per-product codec.
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("shared-overflow")),
    ] of CrystalClick::BinaryValue
    granules = [
      values[0, 3],
      values[3, 3],
      values[6, 3],
    ] of Array(CrystalClick::BinaryValue)

    [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ].each do |profile|
      parent = File.tempname("crystal-click-w233-dynamic-qbit-parts-")
      Dir.mkdir(parent)
      begin
        part = File.join(parent, "all_1_1_0")
        w233_write_dynamic_part(part, dynamic, structures, granules, profile, 3).should eq(part)

        reader = CrystalClick::DynamicBulkColumnReader.open(part, "payload", dynamic)
        direct = reader.read_marks(0, reader.mark_count).flatten
        direct.map(&.type).should eq(values.map(&.type))
        w233_encoded_values(direct).should eq(w233_encoded_values(values))
        selected = reader.read_marks(1, 1).flatten
        selected.map(&.type).should eq(values[3, 3].map(&.type))
        w233_encoded_values(selected).should eq(w233_encoded_values(values[3, 3]))
        reader.read_marks(reader.mark_count, 0).should be_empty

        typed = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
        full = [] of CrystalClick::BinaryValue
        typed.scan_typed(batch_rows: 2) do |batch|
          full.concat(batch.binary_bulk_values_for("payload").to_a)
        end
        full.map(&.type).should eq(values.map(&.type))
        w233_encoded_values(full).should eq(w233_encoded_values(values))

        window = [] of CrystalClick::BinaryValue
        typed.scan_typed_window(2_u64, 4) do |batch|
          window.concat(batch.binary_bulk_values_for("payload").to_a)
        end
        window.map(&.type).should eq(values[2, 4].map(&.type))
        w233_encoded_values(window).should eq(w233_encoded_values(values[2, 4]))
        empty_callbacks = 0
        typed.scan_typed_window(values.size.to_u64, 1) { |_batch| empty_callbacks += 1 }
        empty_callbacks.should eq(0)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "round-trips an empty and ragged outer Array(Dynamic) occurrence axis" do
    qbit_type = CrystalClick::QBitType.new("Int8", 1_u64)
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    array_qbit = CrystalClick::BinaryDataType.array(qbit)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 3)
    outer = CrystalClick::BinaryDataType.array(dynamic)
    structures = {
      "root.elements" => CrystalClick::DynamicStructure.new(
        [qbit, array_qbit, uint64] of CrystalClick::BinaryDataType,
      ),
    }
    values = [
      CrystalClick::BinaryValue.array(outer, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(
        outer,
        [
          CrystalClick::BinaryValue.dynamic(dynamic, w233_qbit_value(qbit_type, 0x11_u8)),
          CrystalClick::BinaryValue.dynamic(
            dynamic,
            CrystalClick::BinaryValue.array(
              array_qbit,
              [w233_qbit_value(qbit_type, 0x21_u8), w233_qbit_value(qbit_type, 0x22_u8)] of CrystalClick::BinaryValue,
            ),
          ),
          CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(23_u64)),
        ] of CrystalClick::BinaryValue,
      ),
      CrystalClick::BinaryValue.array(
        outer,
        [CrystalClick::BinaryValue.dynamic(dynamic, w233_qbit_value(qbit_type, 0x31_u8))] of CrystalClick::BinaryValue,
      ),
    ] of CrystalClick::BinaryValue
    rows = values.map { |value| [value] of CrystalClick::BinaryValue }

    parent = File.tempname("crystal-click-w233-array-dynamic-qbit-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      w233_write_dynamic_part(
        part,
        outer,
        structures,
        rows,
        CrystalClick::BinaryBulkProfile.single_stream,
        1,
      ).should eq(part)

      reader = CrystalClick::DynamicBulkColumnReader.open(part, "payload", outer)
      direct = reader.read_marks(0, reader.mark_count).flatten
      direct.map(&.type).should eq(values.map(&.type))
      w233_encoded_values(direct).should eq(w233_encoded_values(values))
      selected = reader.read_marks(1, 1).flatten
      selected.map(&.type).should eq([values[1].type])
      w233_encoded_values(selected).should eq(w233_encoded_values([values[1]]))
      typed = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      window = [] of CrystalClick::BinaryValue
      typed.scan_typed_window(1_u64, 2) do |batch|
        window.concat(batch.binary_bulk_values_for("payload").to_a)
      end
      window.map(&.type).should eq(values[1, 2].map(&.type))
      w233_encoded_values(window).should eq(w233_encoded_values(values[1, 2]))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "censuses a nested Dynamic roster beneath an actual Array(Dynamic) arm" do
    qbit_type = CrystalClick::QBitType.new("Int8", 1_u64)
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    inner_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    array_inner_dynamic = CrystalClick::BinaryDataType.array(inner_dynamic)
    outer_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    outer_structure = CrystalClick::DynamicStructure.new(
      [array_inner_dynamic, uint64] of CrystalClick::BinaryDataType,
    )
    outer_array_index = outer_structure.canonical_index_for(array_inner_dynamic)
    inner_site = "root.arm.#{outer_array_index}.elements"
    inner_structure = CrystalClick::DynamicStructure.new([qbit, uint64] of CrystalClick::BinaryDataType)
    inner_qbit_index = inner_structure.canonical_index_for(qbit)
    structures = {
      "root"     => outer_structure,
      inner_site => inner_structure,
    }
    inner_qbit = ->(seed : UInt8) {
      CrystalClick::BinaryValue.dynamic(inner_dynamic, w233_qbit_value(qbit_type, seed))
    }
    inner_number = ->(number : UInt64) {
      CrystalClick::BinaryValue.dynamic(inner_dynamic, CrystalClick::BinaryValue.uint64(number))
    }
    values = [
      CrystalClick::BinaryValue.dynamic(
        outer_dynamic,
        CrystalClick::BinaryValue.array(
          array_inner_dynamic,
          [inner_qbit.call(0x11_u8), inner_number.call(12_u64)] of CrystalClick::BinaryValue,
        ),
      ),
      CrystalClick::BinaryValue.dynamic(
        outer_dynamic,
        CrystalClick::BinaryValue.array(array_inner_dynamic, [] of CrystalClick::BinaryValue),
      ),
      CrystalClick::BinaryValue.dynamic(
        outer_dynamic,
        CrystalClick::BinaryValue.array(
          array_inner_dynamic,
          [inner_qbit.call(0x31_u8)] of CrystalClick::BinaryValue,
        ),
      ),
      CrystalClick::BinaryValue.dynamic(
        outer_dynamic,
        CrystalClick::BinaryValue.uint64(40_u64),
      ),
    ] of CrystalClick::BinaryValue
    rows = values.map { |value| [value] of CrystalClick::BinaryValue }

    parent = File.tempname("crystal-click-w233-nested-dynamic-qbit-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      w233_write_dynamic_part(
        part,
        outer_dynamic,
        structures,
        rows,
        CrystalClick::BinaryBulkProfile.single_stream,
        1,
      ).should eq(part)

      expected_site = "#{inner_site}.arm.#{inner_qbit_index}"
      plan = CrystalClick::BinaryDynamicBulkPlan.new(outer_dynamic, structures)
      plan.qbit_sites.map(&.path).should eq([expected_site])

      reader = CrystalClick::DynamicBulkColumnReader.open(part, "payload", outer_dynamic)
      direct = reader.read_marks(0, reader.mark_count).flatten
      direct.map(&.type).should eq(values.map(&.type))
      w233_encoded_values(direct).should eq(w233_encoded_values(values))
      selected = reader.read_marks(2, 1).flatten
      selected.map(&.type).should eq([values[2].type])
      w233_encoded_values(selected).should eq(w233_encoded_values([values[2]]))
      reader.read_marks(reader.mark_count, 0).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
