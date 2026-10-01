require "./spec_helper"

module CrystalClick
  module WidePartWriter
    class ArrayTuplePartWriter
      def self.w107_test_preflight(
        destination : String,
        keys : Slice(UInt64),
        row_sizes : Slice(UInt64),
        columns : Array(WideTupleLeafColumn),
        infrastructure : TuplePartInfrastructure,
      ) : ArrayTuplePartWriteInput
        preflight(
          destination, "pk", keys, "payload", "Array(Tuple(v UInt8))",
          row_sizes, columns, 8192, infrastructure
        )
      end
    end

    class TupleLeafPhysicalValues
      def self.w107_test_matches?(
        expected : WideTupleLeafColumn::Buffer,
        actual : WideTupleLeafColumn::Buffer,
      ) : Bool
        matches?(expected, actual)
      end
    end

    def self.w107_test_infrastructure(
      stage_calls : Array(Int32),
      copy_calls : Array(Int32),
    ) : TuplePartInfrastructure
      build_tuple_part_infrastructure(
        ->(parent : String) do
          stage_calls << 1
          parent
        end,
        ->(column : WideTupleLeafColumn) do
          copy_calls << 1
          column.physical_values.as(Array(String))
        end
      )
    end

    def self.w107_test_preflight(
      destination : String,
      keys : Slice(UInt64),
      row_sizes : Slice(UInt64),
      columns : Array(WideTupleLeafColumn),
      infrastructure : TuplePartInfrastructure,
    ) : ArrayTuplePartWriteInput
      ArrayTuplePartWriter.w107_test_preflight(destination, keys, row_sizes, columns, infrastructure)
    end

    def self.w107_test_physical_matches?(
      expected : WideTupleLeafColumn::Buffer,
      actual : WideTupleLeafColumn::Buffer,
    ) : Bool
      TupleLeafPhysicalValues.w107_test_matches?(expected, actual)
    end
  end
end

describe "W107 Array(Tuple) writer" do
  it "writes an all-empty outer array without collapsing its rows" do
    parent = File.tempname("crystal-click-array-tuple-w107-empty")
    Dir.mkdir(parent)
    begin
      keys = [7_u64, 9_u64]
      row_sizes = [0_u64, 0_u64]
      column = CrystalClick::WideTupleLeafColumn.new("v", [] of UInt8)
      target = File.join(parent, "part")

      CrystalClick::WidePartWriter.write_uint64_array_tuple_part(
        target, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        "Array(Tuple(v UInt8))", row_sizes.to_unsafe.to_slice(row_sizes.size),
        [column], 1
      ).should eq(target)

      part = CrystalClick::WidePart.open_typed(target, "payload")
      decoded = part.read_array_tuple_mark_range("payload", 0, part.mark_count)
      decoded.row_count.should eq(2)
      decoded.element_count.should eq(0)
      decoded.row_sizes.should eq(row_sizes)
      decoded.tuple_data["v"].physical_values.should eq([] of UInt8)
      decoded.row(0).size.should eq(0)
      decoded.row(1).size.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects full-range sizes beyond the staged reader limits before stage or copy" do
    parent = File.tempname("crystal-click-array-tuple-w107-range-limits")
    Dir.mkdir(parent)
    File.write(File.join(parent, "keep"), "unchanged")
    before = Dir.children(parent).sort
    stage_calls = [] of Int32
    copy_calls = [] of Int32
    infrastructure = CrystalClick::WidePartWriter.w107_test_infrastructure(stage_calls, copy_calls)
    destination = File.join(parent, "part")
    empty_leaf = CrystalClick::WideTupleLeafColumn.new("v", [] of UInt8)

    begin
      row_limit = CrystalClick::WidePart::MAX_ARRAY_MARK_ROWS.to_i + 1
      keys = Array(UInt64).new(row_limit) { |index| index.to_u64 }
      row_sizes = Array(UInt64).new(row_limit, 0_u64)
      expect_raises(ArgumentError, "outer row count exceeds staged reader materialization limit") do
        CrystalClick::WidePartWriter.w107_test_preflight(
          destination, keys.to_unsafe.to_slice(keys.size), row_sizes.to_unsafe.to_slice(row_sizes.size),
          [empty_leaf], infrastructure
        )
      end

      element_limit = CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS.to_i + 1
      keys = [1_u64]
      row_sizes = [element_limit.to_u64]
      values = Array(UInt8).new(element_limit, 0_u8)
      column = CrystalClick::WideTupleLeafColumn.new("v", values)
      expect_raises(ArgumentError, "flattened Array(Tuple) elements exceed staged reader materialization limit") do
        CrystalClick::WidePartWriter.w107_test_preflight(
          destination, keys.to_unsafe.to_slice(keys.size), row_sizes.to_unsafe.to_slice(row_sizes.size),
          [column], infrastructure
        )
      end

      stage_calls.should be_empty
      copy_calls.should be_empty
      Dir.children(parent).sort.should eq(before)
      File.read(File.join(parent, "keep")).should eq("unchanged")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "compares numeric empty buffers by exact carrier identity" do
    expected = [] of UInt8
    same = [] of UInt8
    wrong_carrier = [] of Int8

    CrystalClick::WidePartWriter.w107_test_physical_matches?(expected, same).should be_true
    CrystalClick::WidePartWriter.w107_test_physical_matches?(expected, wrong_carrier).should be_false
  end

  it "compares Enum8 and Enum16 with their complete declared maps" do
    enum8 = CrystalClick::WideTupleEnumDefinition.new(
      :enum8,
      [{"minus", -7_i16}, {"plus", 4_i16}] of Tuple(String, Int16)
    )
    changed_enum8 = CrystalClick::WideTupleEnumDefinition.new(
      :enum8,
      [{"minus", -7_i16}, {"enabled", 4_i16}] of Tuple(String, Int16)
    )
    enum8_expected = [CrystalClick::Enum8Value.new(enum8, -7_i8)] of CrystalClick::Enum8Value
    enum8_same = [CrystalClick::Enum8Value.new(enum8, -7_i8)] of CrystalClick::Enum8Value
    enum8_changed = [CrystalClick::Enum8Value.new(changed_enum8, -7_i8)] of CrystalClick::Enum8Value
    CrystalClick::WidePartWriter.w107_test_physical_matches?(enum8_expected, enum8_same).should be_true
    CrystalClick::WidePartWriter.w107_test_physical_matches?(enum8_expected, enum8_changed).should be_false

    enum16 = CrystalClick::WideTupleEnumDefinition.new(
      :enum16,
      [{"minus", -300_i16}, {"plus", 1024_i16}] of Tuple(String, Int16)
    )
    changed_enum16 = CrystalClick::WideTupleEnumDefinition.new(
      :enum16,
      [{"minus", -300_i16}, {"enabled", 1024_i16}] of Tuple(String, Int16)
    )
    enum16_expected = [CrystalClick::Enum16Value.new(enum16, -300_i16)] of CrystalClick::Enum16Value
    enum16_same = [CrystalClick::Enum16Value.new(enum16, -300_i16)] of CrystalClick::Enum16Value
    enum16_changed = [CrystalClick::Enum16Value.new(changed_enum16, -300_i16)] of CrystalClick::Enum16Value
    CrystalClick::WidePartWriter.w107_test_physical_matches?(enum16_expected, enum16_same).should be_true
    CrystalClick::WidePartWriter.w107_test_physical_matches?(enum16_expected, enum16_changed).should be_false
  end

  it "compares Decimal raw coefficients only after exact precision and scale identity" do
    decimal32 = [CrystalClick::Decimal32Value.new(-123_i32, 9_i32, 2_i32)] of CrystalClick::Decimal32Value
    decimal32_same = [CrystalClick::Decimal32Value.new(-123_i32, 9_i32, 2_i32)] of CrystalClick::Decimal32Value
    decimal32_changed = [CrystalClick::Decimal32Value.new(-123_i32, 8_i32, 2_i32)] of CrystalClick::Decimal32Value
    CrystalClick::WidePartWriter.w107_test_physical_matches?(decimal32, decimal32_same).should be_true
    CrystalClick::WidePartWriter.w107_test_physical_matches?(decimal32, decimal32_changed).should be_false

    decimal64 = [CrystalClick::Decimal64Value.new(456_i64, 18_i32, 3_i32)] of CrystalClick::Decimal64Value
    decimal64_same = [CrystalClick::Decimal64Value.new(456_i64, 18_i32, 3_i32)] of CrystalClick::Decimal64Value
    decimal64_changed = [CrystalClick::Decimal64Value.new(456_i64, 18_i32, 2_i32)] of CrystalClick::Decimal64Value
    CrystalClick::WidePartWriter.w107_test_physical_matches?(decimal64, decimal64_same).should be_true
    CrystalClick::WidePartWriter.w107_test_physical_matches?(decimal64, decimal64_changed).should be_false

    decimal128 = [CrystalClick::Decimal128Value.new(789_i128, 38_i32, 4_i32)] of CrystalClick::Decimal128Value
    decimal128_same = [CrystalClick::Decimal128Value.new(789_i128, 38_i32, 4_i32)] of CrystalClick::Decimal128Value
    decimal128_changed = [CrystalClick::Decimal128Value.new(789_i128, 37_i32, 4_i32)] of CrystalClick::Decimal128Value
    CrystalClick::WidePartWriter.w107_test_physical_matches?(decimal128, decimal128_same).should be_true
    CrystalClick::WidePartWriter.w107_test_physical_matches?(decimal128, decimal128_changed).should be_false

    decimal256_raw = CrystalClick::Decimal256Value.from_int128(-987_i128)
    decimal256 = [CrystalClick::Decimal256TupleValue.new(decimal256_raw, 76_i32, 38_i32)] of CrystalClick::Decimal256TupleValue
    decimal256_same = [CrystalClick::Decimal256TupleValue.new(decimal256_raw, 76_i32, 38_i32)] of CrystalClick::Decimal256TupleValue
    decimal256_changed = [CrystalClick::Decimal256TupleValue.new(decimal256_raw, 76_i32, 37_i32)] of CrystalClick::Decimal256TupleValue
    CrystalClick::WidePartWriter.w107_test_physical_matches?(decimal256, decimal256_same).should be_true
    CrystalClick::WidePartWriter.w107_test_physical_matches?(decimal256, decimal256_changed).should be_false
  end
end
