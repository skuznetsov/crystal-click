require "./spec_helper"
require "file_utils"

private def w232_qbit_value(type : CrystalClick::QBitType, seed : UInt8) : CrystalClick::BinaryValue
  raw = Bytes.new(type.raw_row_bytes) { |index| (seed.to_i + index).to_u8 }
  CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(type, raw))
end

private def w232_variant_arm_index(
  variant : CrystalClick::BinaryDataType,
  arm : CrystalClick::BinaryDataType,
) : Int
  variant.child_count.times do |index|
    return index if variant.child_at(index) == arm
  end
  raise ArgumentError.new("W232 Variant fixture arm is absent")
end

private def w232_array_qbit_value(
  array_type : CrystalClick::BinaryDataType,
  qbit_type : CrystalClick::QBitType,
  count : Int,
  seed : UInt8,
) : CrystalClick::BinaryValue
  children = Array(CrystalClick::BinaryValue).new(count) do |index|
    w232_qbit_value(qbit_type, (seed.to_i + index * 7).to_u8)
  end
  CrystalClick::BinaryValue.array(array_type, children)
end

private def w232_map_qbit_value(
  map_type : CrystalClick::BinaryDataType,
  qbit_type : CrystalClick::QBitType,
  row : Int,
  count : Int,
) : CrystalClick::BinaryValue
  entries = [] of CrystalClick::BinaryValue
  count.times do |index|
    entries << CrystalClick::BinaryValue.string("root-#{row}-#{index}")
    entries << w232_qbit_value(qbit_type, (0x40 + row * 9 + index).to_u8)
  end
  CrystalClick::BinaryValue.map(map_type, entries)
end

private def w232_try_sparse_variant_part_type : Tuple(
  CrystalClick::BinaryDataType,
  CrystalClick::QBitType,
  CrystalClick::BinaryDataType,
  CrystalClick::BinaryDataType,
  CrystalClick::BinaryDataType,
  CrystalClick::BinaryDataType,
  CrystalClick::BinaryDataType,
)?
  qbit_type = CrystalClick::QBitType.new("Int8", 3_u64)
  qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
  string = CrystalClick::BinaryDataType.primitive("String")
  array_qbit = CrystalClick::BinaryDataType.array(qbit)
  map_qbit = CrystalClick::BinaryDataType.map(string, qbit)
  root_variant = CrystalClick::BinaryDataType.variant(
    [string, qbit, array_qbit, map_qbit] of CrystalClick::BinaryDataType,
  )
  wrapped_variant = CrystalClick::BinaryDataType.variant(
    [string, map_qbit] of CrystalClick::BinaryDataType,
  )
  array_wrapped_variant = CrystalClick::BinaryDataType.array(wrapped_variant)
  type = CrystalClick::BinaryDataType.tuple(
    [root_variant, array_wrapped_variant] of CrystalClick::BinaryDataType,
    ["root_choice", "nested_choices"] of String,
  )
  {type, qbit_type, qbit, string, array_qbit, map_qbit, wrapped_variant}
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w232_sparse_variant_rows(
  type : CrystalClick::BinaryDataType,
  qbit_type : CrystalClick::QBitType,
  qbit : CrystalClick::BinaryDataType,
  string : CrystalClick::BinaryDataType,
  array_qbit : CrystalClick::BinaryDataType,
  map_qbit : CrystalClick::BinaryDataType,
  wrapped_variant : CrystalClick::BinaryDataType,
) : Array(Array(CrystalClick::BinaryValue))
  root_variant = type.child_at(0)
  root_qbit_index = w232_variant_arm_index(root_variant, qbit)
  root_array_index = w232_variant_arm_index(root_variant, array_qbit)
  root_map_index = w232_variant_arm_index(root_variant, map_qbit)
  wrapped_string_index = w232_variant_arm_index(wrapped_variant, string)
  wrapped_map_index = w232_variant_arm_index(wrapped_variant, map_qbit)
  array_wrapped_variant = type.child_at(1)

  wrapped_counts = [1, 0, 2, 1, 3, 1]
  rows = Array(CrystalClick::BinaryValue).new(6) do |row|
    root = case row
           when 0
             CrystalClick::BinaryValue.variant(
               root_variant,
               w232_variant_arm_index(root_variant, string),
               CrystalClick::BinaryValue.string("plain-0"),
             )
           when 1
             CrystalClick::BinaryValue.variant(
               root_variant,
               root_qbit_index,
               w232_qbit_value(qbit_type, 0x10_u8),
             )
           when 2
             CrystalClick::BinaryValue.variant(
               root_variant,
               root_array_index,
               w232_array_qbit_value(array_qbit, qbit_type, 2, 0x20_u8),
             )
           when 3
             CrystalClick::BinaryValue.variant(
               root_variant,
               root_map_index,
               w232_map_qbit_value(map_qbit, qbit_type, row, 2),
             )
           when 4
             CrystalClick::BinaryValue.variant_null(root_variant)
           else
             CrystalClick::BinaryValue.variant(
               root_variant,
               root_qbit_index,
               w232_qbit_value(qbit_type, 0x30_u8),
             )
           end

    nested = [] of CrystalClick::BinaryValue
    wrapped_counts[row].times do |index|
      if (row + index).odd?
        nested << CrystalClick::BinaryValue.variant(
          wrapped_variant,
          wrapped_string_index,
          CrystalClick::BinaryValue.string("nested-#{row}-#{index}"),
        )
      else
        nested << CrystalClick::BinaryValue.variant(
          wrapped_variant,
          wrapped_map_index,
          w232_map_qbit_value(map_qbit, qbit_type, row + index, 1 + (index % 2)),
        )
      end
    end

    CrystalClick::BinaryValue.tuple(
      type,
      [root, CrystalClick::BinaryValue.array(array_wrapped_variant, nested)] of CrystalClick::BinaryValue,
    )
  end
  [[rows[0], rows[1]], [rows[2], rows[3]], [rows[4], rows[5]]] of Array(CrystalClick::BinaryValue)
end

private def w232_assert_sparse_variant_part_scans!(
  type : CrystalClick::BinaryDataType,
  rows_by_mark : Array(Array(CrystalClick::BinaryValue)),
) : Nil
  expected = rows_by_mark.flatten
  scratch = File.tempname("crystal-click-w232-qbit-variant-part-")
  Dir.mkdir(scratch)
  part = File.join(scratch, "all_1_1_0")
  begin
    write_ok = w232_try_write_sparse_variant_part(
      part,
      type,
      rows_by_mark,
    )
    write_ok.should be_true
    return unless write_ok

    typed = CrystalClick::WidePartTable.open_selected_typed([part], ["v"])
    typed.column_types.should eq([{"v", type.name}])
    typed.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64]])

    full = [] of CrystalClick::BinaryValue
    typed.scan_typed(batch_rows: 1) do |batch|
      full.concat(batch.binary_bulk_values_for("v").to_a)
    end
    full.should eq(expected)

    middle = [] of CrystalClick::BinaryValue
    typed.scan_typed_window(1_u64, 4) do |batch|
      middle.concat(batch.binary_bulk_values_for("v").to_a)
    end
    middle.should eq(expected[1, 4])

    zero_mark_callbacks = 0
    typed.scan_typed_candidate_marks([[] of Int32]) { |_batch| zero_mark_callbacks += 1 }
    zero_mark_callbacks.should eq(0)

    eof_callbacks = 0
    typed.scan_typed_window(expected.size.to_u64, 1) { |_batch| eof_callbacks += 1 }
    eof_callbacks.should eq(0)
  ensure
    FileUtils.rm_rf(scratch)
  end
end

private def w232_try_nested_variant_axis_types : Tuple(
  CrystalClick::BinaryDataType,
  CrystalClick::QBitType,
  CrystalClick::BinaryDataType,
  CrystalClick::BinaryDataType,
  CrystalClick::BinaryDataType,
)?
  qbit_type = CrystalClick::QBitType.new("Int8", 3_u64)
  qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  inner_variant = CrystalClick::BinaryDataType.variant(
    [qbit, uint64] of CrystalClick::BinaryDataType,
  )
  array_arm = CrystalClick::BinaryDataType.array(inner_variant)
  string = CrystalClick::BinaryDataType.primitive("String")
  outer_variant = CrystalClick::BinaryDataType.variant(
    [array_arm, string] of CrystalClick::BinaryDataType,
  )
  {outer_variant, qbit_type, qbit, inner_variant, array_arm}
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w232_nested_variant_axis_rows(
  types : Tuple(
    CrystalClick::BinaryDataType,
    CrystalClick::QBitType,
    CrystalClick::BinaryDataType,
    CrystalClick::BinaryDataType,
    CrystalClick::BinaryDataType,
  ),
) : Array(Array(CrystalClick::BinaryValue))
  outer_variant, qbit_type, qbit, inner_variant, array_arm = types
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  string = CrystalClick::BinaryDataType.primitive("String")
  array_index = w232_variant_arm_index(outer_variant, array_arm)
  string_index = w232_variant_arm_index(outer_variant, string)
  inner_qbit_index = w232_variant_arm_index(inner_variant, qbit)
  inner_uint64_index = w232_variant_arm_index(inner_variant, uint64)

  rows = Array(CrystalClick::BinaryValue).new(6) do |row|
    case row
    when 0
      CrystalClick::BinaryValue.variant_null(outer_variant)
    when 1
      empty = CrystalClick::BinaryValue.array(array_arm, [] of CrystalClick::BinaryValue)
      CrystalClick::BinaryValue.variant(outer_variant, array_index, empty)
    when 2
      children = [
        CrystalClick::BinaryValue.variant_null(inner_variant),
        CrystalClick::BinaryValue.variant(
          inner_variant,
          inner_qbit_index,
          w232_qbit_value(qbit_type, 0x71_u8),
        ),
      ] of CrystalClick::BinaryValue
      CrystalClick::BinaryValue.variant(
        outer_variant,
        array_index,
        CrystalClick::BinaryValue.array(array_arm, children),
      )
    when 3
      CrystalClick::BinaryValue.variant(
        outer_variant,
        string_index,
        CrystalClick::BinaryValue.string("late-unselected-3"),
      )
    when 4
      children = [
        CrystalClick::BinaryValue.variant(
          inner_variant,
          inner_uint64_index,
          CrystalClick::BinaryValue.uint64(404_u64),
        ),
        CrystalClick::BinaryValue.variant(
          inner_variant,
          inner_qbit_index,
          w232_qbit_value(qbit_type, 0x74_u8),
        ),
        CrystalClick::BinaryValue.variant_null(inner_variant),
      ] of CrystalClick::BinaryValue
      CrystalClick::BinaryValue.variant(
        outer_variant,
        array_index,
        CrystalClick::BinaryValue.array(array_arm, children),
      )
    else
      CrystalClick::BinaryValue.variant(
        outer_variant,
        string_index,
        CrystalClick::BinaryValue.string("late-unselected-5"),
      )
    end
  end
  [[rows[0], rows[1]], [rows[2], rows[3]], [rows[4], rows[5]]] of Array(CrystalClick::BinaryValue)
end

private def w232_try_nullable_variant_tuple_types : Tuple(
  CrystalClick::BinaryDataType,
  CrystalClick::BinaryDataType,
  CrystalClick::BinaryDataType,
  CrystalClick::QBitType,
  CrystalClick::BinaryDataType,
  CrystalClick::BinaryDataType,
  CrystalClick::BinaryDataType,
)?
  qbit_type = CrystalClick::QBitType.new("Int8", 3_u64)
  qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  variant = CrystalClick::BinaryDataType.variant([qbit, uint64] of CrystalClick::BinaryDataType)
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  tuple = CrystalClick::BinaryDataType.tuple(
    [variant, uint8] of CrystalClick::BinaryDataType,
    ["choice", "n"] of String,
  )
  nullable = CrystalClick::BinaryDataType.nullable(tuple)
  {nullable, tuple, variant, qbit_type, qbit, uint64, uint8}
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w232_nullable_variant_tuple_rows(
  types : Tuple(
    CrystalClick::BinaryDataType,
    CrystalClick::BinaryDataType,
    CrystalClick::BinaryDataType,
    CrystalClick::QBitType,
    CrystalClick::BinaryDataType,
    CrystalClick::BinaryDataType,
    CrystalClick::BinaryDataType,
  ),
) : Array(Array(CrystalClick::BinaryValue))
  nullable, tuple, variant, qbit_type, qbit, uint64, uint8 = types
  qbit_index = w232_variant_arm_index(variant, qbit)
  uint64_index = w232_variant_arm_index(variant, uint64)

  rows = Array(CrystalClick::BinaryValue).new(6) do |row|
    if row == 0
      CrystalClick::BinaryValue.nullable(nullable)
    else
      choice = case row
               when 1
                 CrystalClick::BinaryValue.variant_null(variant)
               when 2
                 CrystalClick::BinaryValue.variant(
                   variant,
                   qbit_index,
                   w232_qbit_value(qbit_type, 0x82_u8),
                 )
               else
                 CrystalClick::BinaryValue.variant(
                   variant,
                   uint64_index,
                   CrystalClick::BinaryValue.uint64((900 + row).to_u64),
                 )
               end
      nested = CrystalClick::BinaryValue.tuple(
        tuple,
        [choice, CrystalClick::BinaryValue.fixed(uint8, Bytes[row.to_u8])] of CrystalClick::BinaryValue,
      )
      CrystalClick::BinaryValue.nullable(nullable, nested)
    end
  end
  [[rows[0], rows[1]], [rows[2], rows[3]], [rows[4], rows[5]]] of Array(CrystalClick::BinaryValue)
end

private def w232_try_write_sparse_variant_part(
  part : String,
  type : CrystalClick::BinaryDataType,
  rows_by_mark : Array(Array(CrystalClick::BinaryValue)),
) : Bool
  CrystalClick::WidePartWriter.write_uint64_qbit_bulk_part(
    part,
    "k",
    Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64, 66_u64],
    "v",
    type,
    rows_by_mark,
    rows_per_mark: 2,
  )
  true
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  false
end

describe "W232 Variant-selected static QBit part consumers" do
  it "writes root and Array-wrapped sparse Variant QBit trees and serves full, middle, zero, and EOF scans" do
    types = w232_try_sparse_variant_part_type
    types.should_not be_nil
    if fixture_types = types
      type, qbit_type, qbit, string, array_qbit, map_qbit, wrapped_variant = fixture_types
      rows_by_mark = w232_sparse_variant_rows(
        type, qbit_type, qbit, string, array_qbit, map_qbit, wrapped_variant,
      )
      w232_assert_sparse_variant_part_scans!(type, rows_by_mark)
    end
  end

  it "tracks two sparse Variant axes separated by Array and validates NULL and late unselected arms" do
    types = w232_try_nested_variant_axis_types
    types.should_not be_nil
    if fixture_types = types
      outer_variant = fixture_types[0]
      rows_by_mark = w232_nested_variant_axis_rows(fixture_types)
      w232_assert_sparse_variant_part_scans!(outer_variant, rows_by_mark)
    end
  end

  it "reads a sparse Variant through an eligible Nullable(Tuple) ancestor with an unused late QBit arm" do
    types = w232_try_nullable_variant_tuple_types
    types.should_not be_nil
    if fixture_types = types
      nullable = fixture_types[0]
      rows_by_mark = w232_nullable_variant_tuple_rows(fixture_types)
      w232_assert_sparse_variant_part_scans!(nullable, rows_by_mark)
    end
  end
end
