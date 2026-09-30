require "./spec_helper"

private def w102_signed_le(value : Int128, width : Int32) : Array(UInt8)
  bits = value.unsafe_as(UInt128)
  Array(UInt8).new(width) do |index|
    ((bits >> (index * 8)) & 0xff_u128).to_u8
  end
end

private def w102_decimal256_le(value : CrystalClick::Decimal256Value) : Array(UInt8)
  w102_signed_le(value.low.unsafe_as(Int128), 16) +
    w102_signed_le(value.high.unsafe_as(Int128), 16)
end

private def w102_stream_bytes(part : String, stream : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w102_assert_part(part : String, expected_type : String) : Nil
  File.read(File.join(part, "columns.txt")).should contain("`amount` #{expected_type}\n")
  reader = CrystalClick::WidePart.open_typed(part, "amount")
  reader.column_type.should eq(expected_type)
  reader.mark_row_counts.should eq([2_u64, 2_u64])
end

private def w102_reject_before_stage(parent : String, name : String, &write : String -> String) : Nil
  destination = File.join(parent, name)
  expect_raises(ArgumentError) { yield destination }
  File.exists?(destination).should be_false
  File.symlink?(destination).should be_false
end

private def w102_tamper_columns(part : String, old_type : String, new_type : String) : Nil
  path = File.join(part, "columns.txt")
  columns = File.read(path)
  columns.should contain("`amount` #{old_type}\n")
  File.write(path, columns.sub("`amount` #{old_type}\n", "`amount` #{new_type}\n"))
end

module CrystalClick
  module WidePartWriter
    # Test-only forwarding wrappers exercise the existing private staged
    # validators without adding a production bypass or publishing malformed
    # parts through a new API.
    def self.w102_test_validate_scalar(
      stage : String,
      keys : Array(UInt64),
      values : Array(Int32),
      type_name : String,
      rows_per_mark : Int32,
    ) : Nil
      validate_staged_typed_part(
        stage, "pk", "amount", keys.to_unsafe.to_slice(keys.size),
        values.to_unsafe.to_slice(values.size), type_name, rows_per_mark
      )
    end

    def self.w102_test_validate_array_decimal32(
      stage : String,
      keys : Array(UInt64),
      values : Array(Array(Int32)),
      scale : Int32,
      precision : Int32,
      rows_per_mark : Int32,
    ) : Nil
      validate_staged_array_decimal32_part(
        stage, "pk", "amount", keys.to_unsafe.to_slice(keys.size),
        values.to_unsafe.to_slice(values.size), rows_per_mark, scale, precision
      )
    end

    def self.w102_test_validate_array_nullable_decimal32(
      stage : String,
      keys : Array(UInt64),
      values : Array(Array(Int32?)),
      scale : Int32,
      precision : Int32,
      rows_per_mark : Int32,
    ) : Nil
      validate_staged_array_nullable_decimal32_part(
        stage, "pk", "amount", keys.to_unsafe.to_slice(keys.size),
        values.to_unsafe.to_slice(values.size), rows_per_mark, scale, precision
      )
    end

    def self.w102_test_validate_array_array_decimal32(
      stage : String,
      keys : Array(UInt64),
      values : Array(Array(Array(Int32))),
      scale : Int32,
      precision : Int32,
      rows_per_mark : Int32,
    ) : Nil
      validate_staged_array_array_decimal_part(
        stage, "pk", "amount", keys.to_unsafe.to_slice(keys.size),
        values.to_unsafe.to_slice(values.size), rows_per_mark, precision, scale, "Int32"
      )
    end

    def self.w102_test_validate_array_array_nullable_decimal32(
      stage : String,
      keys : Array(UInt64),
      values : Array(Array(Array(Int32?))),
      scale : Int32,
      precision : Int32,
      rows_per_mark : Int32,
    ) : Nil
      validate_staged_array_array_nullable_decimal_part(
        stage, "pk", "amount", keys.to_unsafe.to_slice(keys.size),
        values.to_unsafe.to_slice(values.size), rows_per_mark, precision, scale, "Int32"
      )
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes exact Decimal(P, S) through all 24 existing raw writer entry points" do
    parent = File.tempname("crystal-click-w102-decimal-matrix")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64, 4_u64]
    keys_slice = keys.to_unsafe.to_slice(keys.size)

    values32 = [-3_i32, 0_i32, 4_i32, 9_i32]
    values64 = [-3_i64, 0_i64, 4_i64, 9_i64]
    values128 = [-3_i128, 0_i128, 4_i128, 9_i128]
    values256 = values128.map { |value| CrystalClick::Decimal256Value.from_int128(value) }
    nullable32 = [nil.as(Int32?), 0_i32.as(Int32?), -3_i32.as(Int32?), 4_i32.as(Int32?)]
    nullable64 = [nil.as(Int64?), 0_i64.as(Int64?), -3_i64.as(Int64?), 4_i64.as(Int64?)]
    nullable128 = [nil.as(Int128?), 0_i128.as(Int128?), -3_i128.as(Int128?), 4_i128.as(Int128?)]
    nullable256 = [
      nil.as(CrystalClick::Decimal256Value?),
      CrystalClick::Decimal256Value.from_int128(0_i128).as(CrystalClick::Decimal256Value?),
      CrystalClick::Decimal256Value.from_int128(-3_i128).as(CrystalClick::Decimal256Value?),
      CrystalClick::Decimal256Value.from_int128(4_i128).as(CrystalClick::Decimal256Value?),
    ]

    array32 = [[] of Int32, [-3_i32], [0_i32, 4_i32], [9_i32]]
    array64 = [[] of Int64, [-3_i64], [0_i64, 4_i64], [9_i64]]
    array128 = [[] of Int128, [-3_i128], [0_i128, 4_i128], [9_i128]]
    array256 = [
      [] of CrystalClick::Decimal256Value,
      [CrystalClick::Decimal256Value.from_int128(-3_i128)],
      [CrystalClick::Decimal256Value.from_int128(0_i128), CrystalClick::Decimal256Value.from_int128(4_i128)],
      [CrystalClick::Decimal256Value.from_int128(9_i128)],
    ]
    array_nullable32 = [
      [nil.as(Int32?), 0_i32.as(Int32?)], [] of Int32?,
      [-3_i32.as(Int32?)], [4_i32.as(Int32?)],
    ]
    array_nullable64 = [
      [nil.as(Int64?), 0_i64.as(Int64?)], [] of Int64?,
      [-3_i64.as(Int64?)], [4_i64.as(Int64?)],
    ]
    array_nullable128 = [
      [nil.as(Int128?), 0_i128.as(Int128?)], [] of Int128?,
      [-3_i128.as(Int128?)], [4_i128.as(Int128?)],
    ]
    array_nullable256 = [
      [nil.as(CrystalClick::Decimal256Value?), CrystalClick::Decimal256Value.from_int128(0_i128).as(CrystalClick::Decimal256Value?)],
      [] of CrystalClick::Decimal256Value?,
      [CrystalClick::Decimal256Value.from_int128(-3_i128).as(CrystalClick::Decimal256Value?)],
      [CrystalClick::Decimal256Value.from_int128(4_i128).as(CrystalClick::Decimal256Value?)],
    ]
    nested32 = [
      [] of Array(Int32), [[] of Int32, [-3_i32]], [[0_i32]], [[4_i32, 9_i32]],
    ]
    nested64 = [
      [] of Array(Int64), [[] of Int64, [-3_i64]], [[0_i64]], [[4_i64, 9_i64]],
    ]
    nested128 = [
      [] of Array(Int128), [[] of Int128, [-3_i128]], [[0_i128]], [[4_i128, 9_i128]],
    ]
    nested256 = [
      [] of Array(CrystalClick::Decimal256Value),
      [[] of CrystalClick::Decimal256Value, [CrystalClick::Decimal256Value.from_int128(-3_i128)]],
      [[CrystalClick::Decimal256Value.from_int128(0_i128)]],
      [[CrystalClick::Decimal256Value.from_int128(4_i128), CrystalClick::Decimal256Value.from_int128(9_i128)]],
    ]
    nested_nullable32 = [
      [] of Array(Int32?), [[] of Int32?, [nil.as(Int32?), 0_i32.as(Int32?)]],
      [[-3_i32.as(Int32?)]], [[4_i32.as(Int32?), nil.as(Int32?)]],
    ]
    nested_nullable64 = [
      [] of Array(Int64?), [[] of Int64?, [nil.as(Int64?), 0_i64.as(Int64?)]],
      [[-3_i64.as(Int64?)]], [[4_i64.as(Int64?), nil.as(Int64?)]],
    ]
    nested_nullable128 = [
      [] of Array(Int128?), [[] of Int128?, [nil.as(Int128?), 0_i128.as(Int128?)]],
      [[-3_i128.as(Int128?)]], [[4_i128.as(Int128?), nil.as(Int128?)]],
    ]
    nested_nullable256 = [
      [] of Array(CrystalClick::Decimal256Value?),
      [[] of CrystalClick::Decimal256Value?, [nil.as(CrystalClick::Decimal256Value?), CrystalClick::Decimal256Value.from_int128(0_i128).as(CrystalClick::Decimal256Value?)]],
      [[CrystalClick::Decimal256Value.from_int128(-3_i128).as(CrystalClick::Decimal256Value?)]],
      [[CrystalClick::Decimal256Value.from_int128(4_i128).as(CrystalClick::Decimal256Value?), nil.as(CrystalClick::Decimal256Value?)]],
    ]

    begin
      # Scalar: P=1, 10, 19 and 39 exercise all coefficient bands.
      part = File.join(parent, "scalar32")
      CrystalClick::WidePartWriter.write_uint64_decimal32_pair(part, "pk", keys_slice, "amount", values32.to_unsafe.to_slice(4), 0, 2, precision: 1)
      w102_assert_part(part, "Decimal(1, 0)")
      w102_stream_bytes(part, "amount").should eq(values32.flat_map { |value| w102_signed_le(value.to_i128, 4) })

      part = File.join(parent, "scalar64")
      CrystalClick::WidePartWriter.write_uint64_decimal64_pair(part, "pk", keys_slice, "amount", values64.to_unsafe.to_slice(4), 1, rows_per_mark: 2, precision: 10)
      w102_assert_part(part, "Decimal(10, 1)")

      part = File.join(parent, "scalar128")
      CrystalClick::WidePartWriter.write_uint64_decimal128_pair(part, "pk", keys_slice, "amount", values128.to_unsafe.to_slice(4), 2, rows_per_mark: 2, precision: 19)
      w102_assert_part(part, "Decimal(19, 2)")

      part = File.join(parent, "scalar256")
      CrystalClick::WidePartWriter.write_uint64_decimal256_pair(part, "pk", keys_slice, "amount", values256.to_unsafe.to_slice(4), 3, rows_per_mark: 2, precision: 39)
      w102_assert_part(part, "Decimal(39, 3)")
      w102_stream_bytes(part, "amount").should eq(values256.flat_map { |value| w102_decimal256_le(value) })

      # Nullable scalar: exact metadata remains distinct even when S=P.
      part = File.join(parent, "nullable32")
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal32_pair(part, "pk", keys_slice, "amount", nullable32.to_unsafe.to_slice(4), 8, rows_per_mark: 2, precision: 8)
      w102_assert_part(part, "Nullable(Decimal(8, 8))")
      w102_stream_bytes(part, "amount.null").should eq([1_u8, 0_u8, 0_u8, 0_u8])
      w102_stream_bytes(part, "amount").should eq([0_i32, 0_i32, -3_i32, 4_i32].flat_map { |value| w102_signed_le(value.to_i128, 4) })

      part = File.join(parent, "nullable64")
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal64_pair(part, "pk", keys_slice, "amount", nullable64.to_unsafe.to_slice(4), 17, rows_per_mark: 2, precision: 17)
      w102_assert_part(part, "Nullable(Decimal(17, 17))")

      part = File.join(parent, "nullable128")
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal128_pair(part, "pk", keys_slice, "amount", nullable128.to_unsafe.to_slice(4), 37, rows_per_mark: 2, precision: 37)
      w102_assert_part(part, "Nullable(Decimal(37, 37))")

      part = File.join(parent, "nullable256")
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal256_pair(part, "pk", keys_slice, "amount", nullable256.to_unsafe.to_slice(4), 75, rows_per_mark: 2, precision: 75)
      w102_assert_part(part, "Nullable(Decimal(75, 75))")

      # One-level Array with empty rows and lower/upper carrier-band edges.
      part = File.join(parent, "array32")
      CrystalClick::WidePartWriter.write_uint64_array_decimal32_pair(part, "pk", keys_slice, "amount", array32.to_unsafe.to_slice(4), 1, rows_per_mark: 2, precision: 9)
      w102_assert_part(part, "Array(Decimal(9, 1))")

      part = File.join(parent, "array64")
      CrystalClick::WidePartWriter.write_uint64_array_decimal64_pair(part, "pk", keys_slice, "amount", array64.to_unsafe.to_slice(4), 2, rows_per_mark: 2, precision: 10)
      w102_assert_part(part, "Array(Decimal(10, 2))")

      part = File.join(parent, "array128")
      CrystalClick::WidePartWriter.write_uint64_array_decimal128_pair(part, "pk", keys_slice, "amount", array128.to_unsafe.to_slice(4), 3, rows_per_mark: 2, precision: 19)
      w102_assert_part(part, "Array(Decimal(19, 3))")

      part = File.join(parent, "array256")
      CrystalClick::WidePartWriter.write_uint64_array_decimal256_pair(part, "pk", keys_slice, "amount", array256.to_unsafe.to_slice(4), 4, rows_per_mark: 2, precision: 76)
      w102_assert_part(part, "Array(Decimal(76, 4))")

      # Array(Nullable(...)): NULL and zero are separate, with P below max.
      part = File.join(parent, "array_nullable32")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal32_pair(part, "pk", keys_slice, "amount", array_nullable32.to_unsafe.to_slice(4), 2, rows_per_mark: 2, precision: 7)
      w102_assert_part(part, "Array(Nullable(Decimal(7, 2)))")

      part = File.join(parent, "array_nullable64")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal64_pair(part, "pk", keys_slice, "amount", array_nullable64.to_unsafe.to_slice(4), 15, rows_per_mark: 2, precision: 16)
      w102_assert_part(part, "Array(Nullable(Decimal(16, 15)))")

      part = File.join(parent, "array_nullable128")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal128_pair(part, "pk", keys_slice, "amount", array_nullable128.to_unsafe.to_slice(4), 35, rows_per_mark: 2, precision: 36)
      w102_assert_part(part, "Array(Nullable(Decimal(36, 35)))")

      part = File.join(parent, "array_nullable256")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal256_pair(part, "pk", keys_slice, "amount", array_nullable256.to_unsafe.to_slice(4), 73, rows_per_mark: 2, precision: 74)
      w102_assert_part(part, "Array(Nullable(Decimal(74, 73)))")

      # Two-level Array: empty outer rows differ from an empty inner Array.
      part = File.join(parent, "nested32")
      CrystalClick::WidePartWriter.write_uint64_array_array_decimal32_pair(part, "pk", keys_slice, "amount", nested32.to_unsafe.to_slice(4), 0, rows_per_mark: 2, precision: 5)
      w102_assert_part(part, "Array(Array(Decimal(5, 0)))")

      part = File.join(parent, "nested64")
      CrystalClick::WidePartWriter.write_uint64_array_array_decimal64_pair(part, "pk", keys_slice, "amount", nested64.to_unsafe.to_slice(4), 7, rows_per_mark: 2, precision: 14)
      w102_assert_part(part, "Array(Array(Decimal(14, 7)))")

      part = File.join(parent, "nested128")
      CrystalClick::WidePartWriter.write_uint64_array_array_decimal128_pair(part, "pk", keys_slice, "amount", nested128.to_unsafe.to_slice(4), 1, rows_per_mark: 2, precision: 30)
      w102_assert_part(part, "Array(Array(Decimal(30, 1)))")

      part = File.join(parent, "nested256")
      CrystalClick::WidePartWriter.write_uint64_array_array_decimal256_pair(part, "pk", keys_slice, "amount", nested256.to_unsafe.to_slice(4), 2, rows_per_mark: 2, precision: 55)
      w102_assert_part(part, "Array(Array(Decimal(55, 2)))")

      # Two-level nullable leaves exercise both offsets and nullable placeholders.
      part = File.join(parent, "nested_nullable32")
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal32_pair(part, "pk", keys_slice, "amount", nested_nullable32.to_unsafe.to_slice(4), 6, rows_per_mark: 2, precision: 6)
      w102_assert_part(part, "Array(Array(Nullable(Decimal(6, 6))))")

      part = File.join(parent, "nested_nullable64")
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal64_pair(part, "pk", keys_slice, "amount", nested_nullable64.to_unsafe.to_slice(4), 1, rows_per_mark: 2, precision: 15)
      w102_assert_part(part, "Array(Array(Nullable(Decimal(15, 1))))")

      part = File.join(parent, "nested_nullable128")
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal128_pair(part, "pk", keys_slice, "amount", nested_nullable128.to_unsafe.to_slice(4), 31, rows_per_mark: 2, precision: 31)
      w102_assert_part(part, "Array(Array(Nullable(Decimal(31, 31))))")

      part = File.join(parent, "nested_nullable256")
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal256_pair(part, "pk", keys_slice, "amount", nested_nullable256.to_unsafe.to_slice(4), 55, rows_per_mark: 2, precision: 56)
      w102_assert_part(part, "Array(Array(Nullable(Decimal(56, 55))))")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "retains max-precision defaults and old positional rows_per_mark calls" do
    parent = File.tempname("crystal-click-w102-decimal-defaults")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64, 4_u64]
    values = [1_i32, 0_i32, -2_i32, 9_i32]
    destination = File.join(parent, "part")
    begin
      CrystalClick::WidePartWriter.write_uint64_decimal32_pair(
        destination, "pk", keys.to_unsafe.to_slice(4), "amount",
        values.to_unsafe.to_slice(4), 2, 2
      ).should eq(destination)
      w102_assert_part(destination, "Decimal(9, 2)")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects precision-band and scale violations before creating a stage for all 24 APIs" do
    parent = File.tempname("crystal-click-w102-decimal-invalid")
    Dir.mkdir(parent)
    keys = [1_u64]
    values32 = [1_i32]
    values64 = [1_i64]
    values128 = [1_i128]
    values256 = [CrystalClick::Decimal256Value.from_int128(1_i128)]
    nullable32 = [1_i32.as(Int32?)]
    nullable64 = [1_i64.as(Int64?)]
    nullable128 = [1_i128.as(Int128?)]
    nullable256 = [values256[0].as(CrystalClick::Decimal256Value?)]
    array32 = [[1_i32]]
    array64 = [[1_i64]]
    array128 = [[1_i128]]
    array256 = [[values256[0]]]
    array_nullable32 = [[1_i32.as(Int32?)]]
    array_nullable64 = [[1_i64.as(Int64?)]]
    array_nullable128 = [[1_i128.as(Int128?)]]
    array_nullable256 = [[values256[0].as(CrystalClick::Decimal256Value?)]]
    nested32 = [[[1_i32]]]
    nested64 = [[[1_i64]]]
    nested128 = [[[1_i128]]]
    nested256 = [[[values256[0]]]]
    nested_nullable32 = [[[1_i32.as(Int32?)]]]
    nested_nullable64 = [[[1_i64.as(Int64?)]]]
    nested_nullable128 = [[[1_i128.as(Int128?)]]]
    nested_nullable256 = [[[values256[0].as(CrystalClick::Decimal256Value?)]]]

    begin
      # P below each physical carrier's lower bound, once for every public shape.
      w102_reject_before_stage(parent, "bad_scalar32") do |destination|
        CrystalClick::WidePartWriter.write_uint64_decimal32_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", values32.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 0)
      end
      w102_reject_before_stage(parent, "bad_scalar64") do |destination|
        CrystalClick::WidePartWriter.write_uint64_decimal64_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", values64.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 9)
      end
      w102_reject_before_stage(parent, "bad_scalar128") do |destination|
        CrystalClick::WidePartWriter.write_uint64_decimal128_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", values128.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 18)
      end
      w102_reject_before_stage(parent, "bad_scalar256") do |destination|
        CrystalClick::WidePartWriter.write_uint64_decimal256_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", values256.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 38)
      end
      w102_reject_before_stage(parent, "bad_nullable32") do |destination|
        CrystalClick::WidePartWriter.write_uint64_nullable_decimal32_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", nullable32.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 0)
      end
      w102_reject_before_stage(parent, "bad_nullable64") do |destination|
        CrystalClick::WidePartWriter.write_uint64_nullable_decimal64_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", nullable64.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 9)
      end
      w102_reject_before_stage(parent, "bad_nullable128") do |destination|
        CrystalClick::WidePartWriter.write_uint64_nullable_decimal128_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", nullable128.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 18)
      end
      w102_reject_before_stage(parent, "bad_nullable256") do |destination|
        CrystalClick::WidePartWriter.write_uint64_nullable_decimal256_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", nullable256.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 38)
      end

      w102_reject_before_stage(parent, "bad_array32") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_decimal32_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", array32.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 0)
      end
      w102_reject_before_stage(parent, "bad_array64") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_decimal64_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", array64.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 9)
      end
      w102_reject_before_stage(parent, "bad_array128") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_decimal128_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", array128.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 18)
      end
      w102_reject_before_stage(parent, "bad_array256") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_decimal256_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", array256.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 38)
      end
      w102_reject_before_stage(parent, "bad_array_nullable32") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal32_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", array_nullable32.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 0)
      end
      w102_reject_before_stage(parent, "bad_array_nullable64") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal64_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", array_nullable64.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 9)
      end
      w102_reject_before_stage(parent, "bad_array_nullable128") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal128_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", array_nullable128.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 18)
      end
      w102_reject_before_stage(parent, "bad_array_nullable256") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal256_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", array_nullable256.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 38)
      end

      w102_reject_before_stage(parent, "bad_nested32") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_array_decimal32_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", nested32.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 0)
      end
      w102_reject_before_stage(parent, "bad_nested64") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_array_decimal64_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", nested64.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 9)
      end
      w102_reject_before_stage(parent, "bad_nested128") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_array_decimal128_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", nested128.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 18)
      end
      w102_reject_before_stage(parent, "bad_nested256") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_array_decimal256_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", nested256.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 38)
      end
      w102_reject_before_stage(parent, "bad_nested_nullable32") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal32_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", nested_nullable32.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 0)
      end
      w102_reject_before_stage(parent, "bad_nested_nullable64") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal64_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", nested_nullable64.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 9)
      end
      w102_reject_before_stage(parent, "bad_nested_nullable128") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal128_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", nested_nullable128.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 18)
      end
      w102_reject_before_stage(parent, "bad_nested_nullable256") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal256_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", nested_nullable256.to_unsafe.to_slice(1), 0, rows_per_mark: 1, precision: 38)
      end

      # S>P is invalid independently of a legal carrier width.
      w102_reject_before_stage(parent, "bad_scale_scalar") do |destination|
        CrystalClick::WidePartWriter.write_uint64_decimal32_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", values32.to_unsafe.to_slice(1), 2, rows_per_mark: 1, precision: 1)
      end
      w102_reject_before_stage(parent, "bad_scale_array") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal64_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", array_nullable64.to_unsafe.to_slice(1), 11, rows_per_mark: 1, precision: 10)
      end
      w102_reject_before_stage(parent, "bad_scale_nested") do |destination|
        CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal128_pair(destination, "pk", keys.to_unsafe.to_slice(1), "amount", nested_nullable128.to_unsafe.to_slice(1), 20, rows_per_mark: 1, precision: 19)
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "retains exact metadata for empty Arrays and all-NULL Decimal leaves" do
    parent = File.tempname("crystal-click-w102-decimal-empty")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64, 4_u64]
    keys_slice = keys.to_unsafe.to_slice(4)
    empty32 = [[] of Int32, [] of Int32, [] of Int32, [] of Int32]
    all_null32 = [
      [nil.as(Int32?)], [nil.as(Int32?)], [] of Int32?, [nil.as(Int32?)],
    ]
    empty_nested32 = [
      [] of Array(Int32), [[] of Int32], [] of Array(Int32), [[] of Int32],
    ]
    all_null_nested32 = [
      [] of Array(Int32?), [[] of Int32?, [nil.as(Int32?)]],
      [[nil.as(Int32?)]], [[] of Int32?],
    ]

    begin
      part = File.join(parent, "empty_array")
      CrystalClick::WidePartWriter.write_uint64_array_decimal32_pair(part, "pk", keys_slice, "amount", empty32.to_unsafe.to_slice(4), 3, rows_per_mark: 2, precision: 7)
      w102_assert_part(part, "Array(Decimal(7, 3))")

      part = File.join(parent, "all_null_array")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal32_pair(part, "pk", keys_slice, "amount", all_null32.to_unsafe.to_slice(4), 2, rows_per_mark: 2, precision: 6)
      w102_assert_part(part, "Array(Nullable(Decimal(6, 2)))")
      w102_stream_bytes(part, "amount.null").should eq([1_u8, 1_u8, 1_u8])
      w102_stream_bytes(part, "amount").should eq([0_i32, 0_i32, 0_i32].flat_map { |value| w102_signed_le(value.to_i128, 4) })

      part = File.join(parent, "empty_nested")
      CrystalClick::WidePartWriter.write_uint64_array_array_decimal32_pair(part, "pk", keys_slice, "amount", empty_nested32.to_unsafe.to_slice(4), 1, rows_per_mark: 2, precision: 8)
      w102_assert_part(part, "Array(Array(Decimal(8, 1)))")

      part = File.join(parent, "all_null_nested")
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal32_pair(part, "pk", keys_slice, "amount", all_null_nested32.to_unsafe.to_slice(4), 5, rows_per_mark: 2, precision: 5)
      w102_assert_part(part, "Array(Array(Nullable(Decimal(5, 5))))")
      w102_stream_bytes(part, "amount.null").should eq([1_u8, 1_u8])
      w102_stream_bytes(part, "amount").should eq(Array(UInt8).new(8, 0_u8))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects same-width precision and scale metadata tampering in staged readback validators" do
    parent = File.tempname("crystal-click-w102-decimal-stage-guard")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    values = [-3_i32, 4_i32]
    nullable_values = [nil.as(Int32?), 4_i32.as(Int32?)]
    array_values = [[-3_i32], [4_i32]]
    array_nullable_values = [[nil.as(Int32?)], [4_i32.as(Int32?)]]
    nested_values = [[[-3_i32]], [[4_i32]]]
    nested_nullable_values = [[[nil.as(Int32?)]], [[4_i32.as(Int32?)]]]
    rows_per_mark = 2
    begin
      # Scalar: both P and S changes remain in the same 4-byte carrier band.
      source = File.join(parent, "scalar_source")
      CrystalClick::WidePartWriter.write_uint64_decimal32_pair(source, "pk", keys.to_unsafe.to_slice(2), "amount", values.to_unsafe.to_slice(2), 2, rows_per_mark: 2, precision: 7)
      {"Decimal(8, 2)", "Decimal(7, 3)"}.each_with_index do |tampered_type, index|
        copy = File.join(parent, "scalar_tampered_#{index}")
        FileUtils.cp_r(source, copy)
        begin
          w102_tamper_columns(copy, "Decimal(7, 2)", tampered_type)
          expect_raises(CrystalClick::CorruptPartError) do
            CrystalClick::WidePartWriter.w102_test_validate_scalar(copy, keys, values, "Decimal(7, 2)", rows_per_mark)
          end
        ensure
          FileUtils.rm_rf(copy)
        end
      end

      # Both Array validators compare exact P, including Nullable leaves.
      source = File.join(parent, "array_source")
      CrystalClick::WidePartWriter.write_uint64_array_decimal32_pair(source, "pk", keys.to_unsafe.to_slice(2), "amount", array_values.to_unsafe.to_slice(2), 2, rows_per_mark: 2, precision: 7)
      copy = File.join(parent, "array_tampered")
      FileUtils.cp_r(source, copy)
      begin
        w102_tamper_columns(copy, "Array(Decimal(7, 2))", "Array(Decimal(8, 2))")
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.w102_test_validate_array_decimal32(copy, keys, array_values, 2, 7, rows_per_mark)
        end
      ensure
        FileUtils.rm_rf(copy)
      end

      source = File.join(parent, "array_nullable_source")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal32_pair(source, "pk", keys.to_unsafe.to_slice(2), "amount", array_nullable_values.to_unsafe.to_slice(2), 2, rows_per_mark: 2, precision: 7)
      copy = File.join(parent, "array_nullable_tampered")
      FileUtils.cp_r(source, copy)
      begin
        w102_tamper_columns(copy, "Array(Nullable(Decimal(7, 2)))", "Array(Nullable(Decimal(7, 3)))")
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.w102_test_validate_array_nullable_decimal32(copy, keys, array_nullable_values, 2, 7, rows_per_mark)
        end
      ensure
        FileUtils.rm_rf(copy)
      end

      # Nested validators already receive exact precision and scale.
      source = File.join(parent, "nested_source")
      CrystalClick::WidePartWriter.write_uint64_array_array_decimal32_pair(source, "pk", keys.to_unsafe.to_slice(2), "amount", nested_values.to_unsafe.to_slice(2), 2, rows_per_mark: 2, precision: 7)
      copy = File.join(parent, "nested_tampered")
      FileUtils.cp_r(source, copy)
      begin
        w102_tamper_columns(copy, "Array(Array(Decimal(7, 2)))", "Array(Array(Decimal(8, 2)))")
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.w102_test_validate_array_array_decimal32(copy, keys, nested_values, 2, 7, rows_per_mark)
        end
      ensure
        FileUtils.rm_rf(copy)
      end

      source = File.join(parent, "nested_nullable_source")
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal32_pair(source, "pk", keys.to_unsafe.to_slice(2), "amount", nested_nullable_values.to_unsafe.to_slice(2), 2, rows_per_mark: 2, precision: 7)
      copy = File.join(parent, "nested_nullable_tampered")
      FileUtils.cp_r(source, copy)
      begin
        w102_tamper_columns(copy, "Array(Array(Nullable(Decimal(7, 2))))", "Array(Array(Nullable(Decimal(7, 3))))")
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.w102_test_validate_array_array_nullable_decimal32(copy, keys, nested_nullable_values, 2, 7, rows_per_mark)
        end
      ensure
        FileUtils.rm_rf(copy)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
