require "./spec_helper"

private def w104_slice(values : Array(T)) : Slice(T) forall T
  values.to_unsafe.to_slice(values.size)
end

private def w104_assert_schema(path : String, type_name : String) : Nil
  File.read(File.join(path, "columns.txt")).should eq(
    "columns format version: 1\n2 columns:\n`pk` UInt64\n`value` #{type_name}\n"
  )
  CrystalClick::WidePart.open_typed(path, "value").column_type.should eq(type_name)
end

private def w104_run_writer_case(
  parent : String,
  name : String,
  type_name : String,
  &write : String -> String
) : String
  destination = File.join(parent, name)
  result = yield destination
  result.should eq(destination)
  w104_assert_schema(destination, type_name)
  destination
end

private def w104_decoded_value_stream(path : String) : Array(UInt8)
  data_path = File.join(path, "#{CrystalClick::StreamName.hash("value")}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a
end

private def w104_u32_le(values : Array(UInt32)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    4.times { |index| bytes << ((value >> (index * 8)) & 0xff_u32).to_u8 }
  end
  bytes
end

private def w104_i64_le(values : Array(Int64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    bits = value.unsafe_as(UInt64)
    8.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w104_reject_before_stage(
  parent : String,
  name : String,
  &write : String -> String
) : Nil
  destination = File.join(parent, name)
  children_before = Dir.children(parent).sort
  expect_raises(ArgumentError) { yield destination }
  File.exists?(destination).should be_false
  File.symlink?(destination).should be_false
  Dir.children(parent).sort.should eq(children_before)
end

private def w104_expect_schema_mismatch(&validate : -> Nil) : Nil
  error = expect_raises(CrystalClick::CorruptPartError) { yield }
  message = error.message.not_nil!
  (message.includes?("type does not match") || message.includes?("column metadata differs")).should be_true
end

module CrystalClick
  module WidePartWriter
    # Test-only forwarding wrappers attack the production staged validators
    # with an alternate expected schema while retaining identical raw buffers.
    def self.w104_test_validate_scalar(
      stage : String,
      keys : Array(UInt64),
      values : Array(T),
      type_name : String,
      rows_per_mark : Int32,
    ) : Nil forall T
      validate_staged_typed_part(
        stage, "pk", "value", keys.to_unsafe.to_slice(keys.size),
        values.to_unsafe.to_slice(values.size), type_name, rows_per_mark
      )
    end

    def self.w104_test_validate_array(
      stage : String,
      keys : Array(UInt64),
      values : Array(Array(T)),
      leaf_type_name : String,
      rows_per_mark : Int32,
    ) : Nil forall T
      validate_staged_array_temporal_part(
        stage, "pk", "value", keys.to_unsafe.to_slice(keys.size),
        values.to_unsafe.to_slice(values.size), rows_per_mark, leaf_type_name
      )
    end

    def self.w104_test_validate_array_nullable(
      stage : String,
      keys : Array(UInt64),
      values : Array(Array(T?)),
      leaf_type_name : String,
      rows_per_mark : Int32,
    ) : Nil forall T
      validate_staged_array_nullable_temporal_part(
        stage, "pk", "value", keys.to_unsafe.to_slice(keys.size),
        values.to_unsafe.to_slice(values.size), rows_per_mark, leaf_type_name
      )
    end

    def self.w104_test_validate_array_array(
      stage : String,
      keys : Array(UInt64),
      values : Array(Array(Array(T))),
      leaf_type_name : String,
      rows_per_mark : Int32,
    ) : Nil forall T
      validate_staged_array_array_temporal_part(
        stage, "pk", "value", keys.to_unsafe.to_slice(keys.size),
        values.to_unsafe.to_slice(values.size), rows_per_mark, leaf_type_name
      )
    end

    def self.w104_test_validate_array_array_nullable(
      stage : String,
      keys : Array(UInt64),
      values : Array(Array(Array(T?))),
      leaf_type_name : String,
      rows_per_mark : Int32,
    ) : Nil forall T
      validate_staged_array_array_nullable_temporal_part(
        stage, "pk", "value", keys.to_unsafe.to_slice(keys.size),
        values.to_unsafe.to_slice(values.size), rows_per_mark, leaf_type_name
      )
    end

    class TuplePartWriter
      def self.w104_test_validate_staged_part(
        stage : String,
        input : TuplePartWriteInput,
        infrastructure : TuplePartInfrastructure,
      ) : Nil
        validate_staged_part(stage, input, infrastructure)
      end
    end

    def self.w104_test_validate_tuple_stage(
      stage : String,
      keys : Array(UInt64),
      type_name : String,
      leaf_buffers : Array(WideTupleLeafColumn::Buffer),
      rows_per_mark : Int32,
    ) : Nil
      type_plan = WideTupleTypePlan.for_type(type_name) || raise "invalid W104 Tuple test type"
      logical_streams = ["pk"] + type_plan.physical_streams("value")
      mark_count = checked_mark_count(keys.size, rows_per_mark)
      expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`value` #{type_name}\n"
      input = TuplePartWriteInput.new(
        File.join(File.dirname(stage), "not-published"),
        File.dirname(stage),
        "pk",
        keys.dup,
        "value",
        type_plan,
        leaf_buffers,
        Array(Array(UInt8)?).new(leaf_buffers.size, nil),
        logical_streams,
        Array(Int64).new(logical_streams.size, 0_i64),
        Array(UInt64).new(logical_streams.size, 0_u64),
        mark_count,
        rows_per_mark,
        TupleLeafMarkSchedule.row_aligned(keys.size, rows_per_mark),
        expected_columns,
        File.read(File.join(stage, "columns_substreams.txt")),
        File.read(File.join(stage, "serialization.json")),
      )
      infrastructure = build_tuple_part_infrastructure(
        ->(parent : String) { create_stage(parent) },
        ->(column : WideTupleLeafColumn) { column.string_values }
      )
      TuplePartWriter.w104_test_validate_staged_part(stage, input, infrastructure)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes timezone-qualified DateTime through each scalar and Array shape without changing raw seconds" do
    parent = File.tempname("crystal-click-writer-w104-datetime")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64]
    seconds = [0_u32, 0x12345678_u32, UInt32::MAX]
    nullable_seconds = [0_u32.as(UInt32?), nil, UInt32::MAX.as(UInt32?)]
    array_seconds = [[] of UInt32, [0_u32, UInt32::MAX], [0x12345678_u32]]
    array_nullable_seconds = [[] of UInt32?, [nil, 0_u32.as(UInt32?)], [UInt32::MAX.as(UInt32?), nil]]
    nested_seconds = [[] of Array(UInt32), [[0_u32, UInt32::MAX]], [[] of UInt32, [0x12345678_u32]]]
    nested_nullable_seconds = [
      [] of Array(UInt32?),
      [[nil, 0_u32.as(UInt32?)]],
      [[] of UInt32?, [UInt32::MAX.as(UInt32?), nil]],
    ]

    begin
      destination = w104_run_writer_case(parent, "scalar", "DateTime('UTC')") do |path|
        CrystalClick::WidePartWriter.write_uint64_datetime_pair(
          path, "pk", w104_slice(keys), "value", w104_slice(seconds),
          rows_per_mark: 2, time_zone: "UTC"
        )
      end
      CrystalClick::WidePart.open_typed(destination, "value").read_datetime_seconds_mark_range("value", 0, 2).should eq(seconds)

      destination = w104_run_writer_case(parent, "nullable", "Nullable(DateTime('UTC'))") do |path|
        CrystalClick::WidePartWriter.write_uint64_nullable_datetime_pair(
          path, "pk", w104_slice(keys), "value", w104_slice(nullable_seconds),
          rows_per_mark: 2, time_zone: "UTC"
        )
      end
      CrystalClick::WidePart.open_typed(destination, "value").read_nullable_datetime_seconds_mark_range("value", 0, 2).should eq(nullable_seconds)

      destination = w104_run_writer_case(parent, "array", "Array(DateTime('UTC'))") do |path|
        CrystalClick::WidePartWriter.write_uint64_array_datetime_pair(
          path, "pk", w104_slice(keys), "value", w104_slice(array_seconds),
          rows_per_mark: 2, time_zone: "UTC"
        )
      end
      CrystalClick::WidePart.open_typed(destination, "value").read_array_datetime_seconds_mark_range("value", 0, 2).should eq(array_seconds)

      destination = w104_run_writer_case(parent, "array-nullable", "Array(Nullable(DateTime('UTC')))") do |path|
        CrystalClick::WidePartWriter.write_uint64_array_nullable_datetime_pair(
          path, "pk", w104_slice(keys), "value", w104_slice(array_nullable_seconds),
          rows_per_mark: 2, time_zone: "UTC"
        )
      end
      CrystalClick::WidePart.open_typed(destination, "value").read_array_nullable_datetime_seconds_mark_range("value", 0, 2).should eq(array_nullable_seconds)

      destination = w104_run_writer_case(parent, "nested", "Array(Array(DateTime('UTC')))") do |path|
        CrystalClick::WidePartWriter.write_uint64_array_array_datetime_pair(
          path, "pk", w104_slice(keys), "value", w104_slice(nested_seconds),
          rows_per_mark: 2, time_zone: "UTC"
        )
      end
      CrystalClick::WidePart.open_typed(destination, "value").read_array_array_datetime_seconds_mark_range("value", 0, 2).should eq(nested_seconds)

      destination = w104_run_writer_case(parent, "nested-nullable", "Array(Array(Nullable(DateTime('UTC'))))") do |path|
        CrystalClick::WidePartWriter.write_uint64_array_array_nullable_datetime_pair(
          path, "pk", w104_slice(keys), "value", w104_slice(nested_nullable_seconds),
          rows_per_mark: 2, time_zone: "UTC"
        )
      end
      CrystalClick::WidePart.open_typed(destination, "value").read_array_array_nullable_datetime_seconds_mark_range("value", 0, 2).should eq(nested_nullable_seconds)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes timezone-qualified DateTime64 at every precision through all six shapes without rescaling ticks" do
    parent = File.tempname("crystal-click-writer-w104-datetime64")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64]
    ticks = [Int64::MIN, -1_i64, Int64::MAX]
    nullable_ticks = [nil.as(Int64?), Int64::MIN.as(Int64?), Int64::MAX.as(Int64?)]
    array_ticks = [[] of Int64, [Int64::MIN, Int64::MAX], [-1_i64]]
    array_nullable_ticks = [[] of Int64?, [nil, Int64::MIN.as(Int64?)], [Int64::MAX.as(Int64?), -1_i64.as(Int64?)]]
    nested_ticks = [[] of Array(Int64), [[Int64::MIN, Int64::MAX]], [[] of Int64, [-1_i64]]]
    nested_nullable_ticks = [
      [] of Array(Int64?),
      [[nil, Int64::MIN.as(Int64?)]],
      [[] of Int64?, [Int64::MAX.as(Int64?), -1_i64.as(Int64?)]],
    ]

    begin
      (0..9).each do |precision|
        type = "DateTime64(#{precision}, 'UTC')"
        scale = precision.to_i32

        destination = w104_run_writer_case(parent, "scalar-#{precision}", type) do |path|
          CrystalClick::WidePartWriter.write_uint64_datetime64_pair(
            path, "pk", w104_slice(keys), "value", w104_slice(ticks), scale,
            rows_per_mark: 2, time_zone: "UTC"
          )
        end
        w104_decoded_value_stream(destination).should eq(w104_i64_le(ticks))
        CrystalClick::WidePart.open_typed(destination, "value").read_datetime64_ticks_mark_range("value", 0, 2).should eq(ticks)

        destination = w104_run_writer_case(parent, "nullable-#{precision}", "Nullable(#{type})") do |path|
          CrystalClick::WidePartWriter.write_uint64_nullable_datetime64_pair(
            path, "pk", w104_slice(keys), "value", w104_slice(nullable_ticks), scale,
            rows_per_mark: 2, time_zone: "UTC"
          )
        end
        CrystalClick::WidePart.open_typed(destination, "value").read_nullable_datetime64_ticks_mark_range("value", 0, 2).should eq(nullable_ticks)

        destination = w104_run_writer_case(parent, "array-#{precision}", "Array(#{type})") do |path|
          CrystalClick::WidePartWriter.write_uint64_array_datetime64_pair(
            path, "pk", w104_slice(keys), "value", w104_slice(array_ticks), scale,
            rows_per_mark: 2, time_zone: "UTC"
          )
        end
        CrystalClick::WidePart.open_typed(destination, "value").read_array_datetime64_ticks_mark_range("value", 0, 2).should eq(array_ticks)

        destination = w104_run_writer_case(parent, "array-nullable-#{precision}", "Array(Nullable(#{type}))") do |path|
          CrystalClick::WidePartWriter.write_uint64_array_nullable_datetime64_pair(
            path, "pk", w104_slice(keys), "value", w104_slice(array_nullable_ticks), scale,
            rows_per_mark: 2, time_zone: "UTC"
          )
        end
        CrystalClick::WidePart.open_typed(destination, "value").read_array_nullable_datetime64_ticks_mark_range("value", 0, 2).should eq(array_nullable_ticks)

        destination = w104_run_writer_case(parent, "nested-#{precision}", "Array(Array(#{type}))") do |path|
          CrystalClick::WidePartWriter.write_uint64_array_array_datetime64_pair(
            path, "pk", w104_slice(keys), "value", w104_slice(nested_ticks), scale,
            rows_per_mark: 2, time_zone: "UTC"
          )
        end
        CrystalClick::WidePart.open_typed(destination, "value").read_array_array_datetime64_ticks_mark_range("value", 0, 2).should eq(nested_ticks)

        destination = w104_run_writer_case(parent, "nested-nullable-#{precision}", "Array(Array(Nullable(#{type})))") do |path|
          CrystalClick::WidePartWriter.write_uint64_array_array_nullable_datetime64_pair(
            path, "pk", w104_slice(keys), "value", w104_slice(nested_nullable_ticks), scale,
            rows_per_mark: 2, time_zone: "UTC"
          )
        end
        CrystalClick::WidePart.open_typed(destination, "value").read_array_array_nullable_datetime64_ticks_mark_range("value", 0, 2).should eq(nested_nullable_ticks)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps identical raw seconds and ticks when exact timezone schemas differ" do
    parent = File.tempname("crystal-click-writer-w104-schema-identity")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64]
    seconds = [0_u32, 1_u32, UInt32::MAX]
    ticks = [Int64::MIN, -1_i64, Int64::MAX]

    begin
      utc_seconds = w104_run_writer_case(parent, "datetime-utc", "DateTime('UTC')") do |path|
        CrystalClick::WidePartWriter.write_uint64_datetime_pair(path, "pk", w104_slice(keys), "value", w104_slice(seconds), rows_per_mark: 2, time_zone: "UTC")
      end
      etc_seconds = w104_run_writer_case(parent, "datetime-etc-utc", "DateTime('Etc/UTC')") do |path|
        CrystalClick::WidePartWriter.write_uint64_datetime_pair(path, "pk", w104_slice(keys), "value", w104_slice(seconds), rows_per_mark: 2, time_zone: "Etc/UTC")
      end
      w104_decoded_value_stream(utc_seconds).should eq(w104_u32_le(seconds))
      w104_decoded_value_stream(etc_seconds).should eq(w104_u32_le(seconds))
      w104_decoded_value_stream(utc_seconds).should eq(w104_decoded_value_stream(etc_seconds))
      File.read(File.join(utc_seconds, "columns.txt")).should_not eq(File.read(File.join(etc_seconds, "columns.txt")))

      utc_ticks = w104_run_writer_case(parent, "datetime64-utc", "DateTime64(3, 'UTC')") do |path|
        CrystalClick::WidePartWriter.write_uint64_datetime64_pair(path, "pk", w104_slice(keys), "value", w104_slice(ticks), 3, rows_per_mark: 2, time_zone: "UTC")
      end
      etc_ticks = w104_run_writer_case(parent, "datetime64-etc-utc", "DateTime64(3, 'Etc/UTC')") do |path|
        CrystalClick::WidePartWriter.write_uint64_datetime64_pair(path, "pk", w104_slice(keys), "value", w104_slice(ticks), 3, rows_per_mark: 2, time_zone: "Etc/UTC")
      end
      w104_decoded_value_stream(utc_ticks).should eq(w104_i64_le(ticks))
      w104_decoded_value_stream(etc_ticks).should eq(w104_i64_le(ticks))
      w104_decoded_value_stream(utc_ticks).should eq(w104_decoded_value_stream(etc_ticks))
      File.read(File.join(utc_ticks, "columns.txt")).should_not eq(File.read(File.join(etc_ticks, "columns.txt")))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects malformed, unknown, path-like, NUL, control, and noncanonical Fixed names before staging" do
    parent = File.tempname("crystal-click-writer-w104-bad-zones")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    seconds = [0_u32, UInt32::MAX]

    begin
      [
        "",
        "Definitely/Not_A_Zone",
        "'UTC'",
        "UTC\nInjected",
        "UTC\0suffix",
        "/etc/localtime",
        "/usr/share/zoneinfo/America/New_York",
        "zoneinfo/America/New_York",
        "../UTC",
        "America/../UTC",
        "America//New_York",
        "localtime",
        "posixrules",
        "right/UTC",
        "posix/UTC",
        ":America/New_York",
        "UTC0",
        "UTC+05:45:00",
        "Fixed/UTC+05:31:00",
        "Fixed/UTC+05:45:01",
        "Fixed/UTC+15:00:00",
      ].each_with_index do |zone, index|
        w104_reject_before_stage(parent, "bad-#{index}") do |path|
          CrystalClick::WidePartWriter.write_uint64_datetime_pair(
            path, "pk", w104_slice(keys), "value", w104_slice(seconds),
            rows_per_mark: 1, time_zone: zone
          )
        end
      end

      tuple_keys = [1_u64, 2_u64]
      tuple_values = [CrystalClick::DateTimeValue.new(0_u32), CrystalClick::DateTimeValue.new(UInt32::MAX)] of CrystalClick::DateTimeValue
      invalid_tuple_type = "Tuple(event DateTime('Definitely/Not_A_Zone'))"
      w104_reject_before_stage(parent, "bad-tuple") do |path|
        CrystalClick::WidePartWriter.write_uint64_tuple_pair(
          path, "pk", w104_slice(tuple_keys), "value", invalid_tuple_type,
          [CrystalClick::WideTupleLeafColumn.new("event", "DateTime('Definitely/Not_A_Zone')", tuple_values)] of CrystalClick::WideTupleLeafColumn,
          rows_per_mark: 1
        )
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects an unknown zone before staging from every timezone-keyword writer" do
    parent = File.tempname("crystal-click-writer-w104-unknown-all-writers")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    seconds = [0_u32, UInt32::MAX]
    nullable_seconds = [nil.as(UInt32?), UInt32::MAX.as(UInt32?)]
    arrays = [[] of UInt32, [UInt32::MAX]]
    nullable_arrays = [[] of UInt32?, [nil.as(UInt32?), UInt32::MAX.as(UInt32?)]]
    nested = [[] of Array(UInt32), [[UInt32::MAX]]]
    nested_nullable = [[] of Array(UInt32?), [[nil.as(UInt32?), UInt32::MAX.as(UInt32?)]]]
    ticks = [Int64::MIN, Int64::MAX]
    nullable_ticks = [nil.as(Int64?), Int64::MAX.as(Int64?)]
    tick_arrays = [[] of Int64, [Int64::MIN, Int64::MAX]]
    nullable_tick_arrays = [[] of Int64?, [nil.as(Int64?), Int64::MAX.as(Int64?)]]
    nested_ticks = [[] of Array(Int64), [[Int64::MIN, Int64::MAX]]]
    nested_nullable_ticks = [[] of Array(Int64?), [[nil.as(Int64?), Int64::MAX.as(Int64?)]]]
    writers = [] of Proc(String, String)
    bad_zone = "Definitely/Not_A_Zone"

    writers << ->(path : String) {
      CrystalClick::WidePartWriter.write_uint64_datetime_pair(path, "pk", w104_slice(keys), "value", w104_slice(seconds), rows_per_mark: 1, time_zone: bad_zone)
    }
    writers << ->(path : String) {
      CrystalClick::WidePartWriter.write_uint64_nullable_datetime_pair(path, "pk", w104_slice(keys), "value", w104_slice(nullable_seconds), rows_per_mark: 1, time_zone: bad_zone)
    }
    writers << ->(path : String) {
      CrystalClick::WidePartWriter.write_uint64_array_datetime_pair(path, "pk", w104_slice(keys), "value", w104_slice(arrays), rows_per_mark: 1, time_zone: bad_zone)
    }
    writers << ->(path : String) {
      CrystalClick::WidePartWriter.write_uint64_array_nullable_datetime_pair(path, "pk", w104_slice(keys), "value", w104_slice(nullable_arrays), rows_per_mark: 1, time_zone: bad_zone)
    }
    writers << ->(path : String) {
      CrystalClick::WidePartWriter.write_uint64_array_array_datetime_pair(path, "pk", w104_slice(keys), "value", w104_slice(nested), rows_per_mark: 1, time_zone: bad_zone)
    }
    writers << ->(path : String) {
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_datetime_pair(path, "pk", w104_slice(keys), "value", w104_slice(nested_nullable), rows_per_mark: 1, time_zone: bad_zone)
    }
    writers << ->(path : String) {
      CrystalClick::WidePartWriter.write_uint64_datetime64_pair(path, "pk", w104_slice(keys), "value", w104_slice(ticks), 3, rows_per_mark: 1, time_zone: bad_zone)
    }
    writers << ->(path : String) {
      CrystalClick::WidePartWriter.write_uint64_nullable_datetime64_pair(path, "pk", w104_slice(keys), "value", w104_slice(nullable_ticks), 3, rows_per_mark: 1, time_zone: bad_zone)
    }
    writers << ->(path : String) {
      CrystalClick::WidePartWriter.write_uint64_array_datetime64_pair(path, "pk", w104_slice(keys), "value", w104_slice(tick_arrays), 3, rows_per_mark: 1, time_zone: bad_zone)
    }
    writers << ->(path : String) {
      CrystalClick::WidePartWriter.write_uint64_array_nullable_datetime64_pair(path, "pk", w104_slice(keys), "value", w104_slice(nullable_tick_arrays), 3, rows_per_mark: 1, time_zone: bad_zone)
    }
    writers << ->(path : String) {
      CrystalClick::WidePartWriter.write_uint64_array_array_datetime64_pair(path, "pk", w104_slice(keys), "value", w104_slice(nested_ticks), 3, rows_per_mark: 1, time_zone: bad_zone)
    }
    writers << ->(path : String) {
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_datetime64_pair(path, "pk", w104_slice(keys), "value", w104_slice(nested_nullable_ticks), 3, rows_per_mark: 1, time_zone: bad_zone)
    }

    begin
      writers.each_with_index do |write, index|
        w104_reject_before_stage(parent, "bad-#{index}") { |path| write.call(path) }
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves all-null and empty leaf payloads for positive rows and rejects zero-row input" do
    parent = File.tempname("crystal-click-writer-w104-empty-null")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    all_null_seconds = [nil.as(UInt32?), nil.as(UInt32?)]
    empty_arrays = [[] of UInt32, [] of UInt32]
    all_null_arrays = [[] of UInt32?, [nil.as(UInt32?), nil.as(UInt32?)]]
    empty_nested_arrays = [[] of Array(UInt32), [[] of UInt32]]
    all_null_nested_arrays = [[] of Array(UInt32?), [[nil.as(UInt32?), nil.as(UInt32?)]]]
    all_null_ticks = [nil.as(Int64?), nil.as(Int64?)]
    empty_tick_arrays = [[] of Int64, [] of Int64]
    all_null_tick_arrays = [[] of Int64?, [nil.as(Int64?), nil.as(Int64?)]]

    begin
      destination = w104_run_writer_case(parent, "all-null-scalar", "Nullable(DateTime('UTC'))") do |path|
        CrystalClick::WidePartWriter.write_uint64_nullable_datetime_pair(
          path, "pk", w104_slice(keys), "value", w104_slice(all_null_seconds), rows_per_mark: 1, time_zone: "UTC"
        )
      end
      CrystalClick::WidePart.open_typed(destination, "value").read_nullable_datetime_seconds_mark_range("value", 0, 2).should eq(all_null_seconds)

      destination = w104_run_writer_case(parent, "empty-array", "Array(DateTime('UTC'))") do |path|
        CrystalClick::WidePartWriter.write_uint64_array_datetime_pair(
          path, "pk", w104_slice(keys), "value", w104_slice(empty_arrays), rows_per_mark: 1, time_zone: "UTC"
        )
      end
      CrystalClick::WidePart.open_typed(destination, "value").read_array_datetime_seconds_mark_range("value", 0, 2).should eq(empty_arrays)

      destination = w104_run_writer_case(parent, "all-null-array", "Array(Nullable(DateTime('UTC')))") do |path|
        CrystalClick::WidePartWriter.write_uint64_array_nullable_datetime_pair(
          path, "pk", w104_slice(keys), "value", w104_slice(all_null_arrays), rows_per_mark: 1, time_zone: "UTC"
        )
      end
      CrystalClick::WidePart.open_typed(destination, "value").read_array_nullable_datetime_seconds_mark_range("value", 0, 2).should eq(all_null_arrays)

      destination = w104_run_writer_case(parent, "empty-nested-array", "Array(Array(DateTime('UTC')))") do |path|
        CrystalClick::WidePartWriter.write_uint64_array_array_datetime_pair(
          path, "pk", w104_slice(keys), "value", w104_slice(empty_nested_arrays), rows_per_mark: 1, time_zone: "UTC"
        )
      end
      CrystalClick::WidePart.open_typed(destination, "value").read_array_array_datetime_seconds_mark_range("value", 0, 2).should eq(empty_nested_arrays)

      destination = w104_run_writer_case(parent, "all-null-nested-array", "Array(Array(Nullable(DateTime('UTC'))))") do |path|
        CrystalClick::WidePartWriter.write_uint64_array_array_nullable_datetime_pair(
          path, "pk", w104_slice(keys), "value", w104_slice(all_null_nested_arrays), rows_per_mark: 1, time_zone: "UTC"
        )
      end
      CrystalClick::WidePart.open_typed(destination, "value").read_array_array_nullable_datetime_seconds_mark_range("value", 0, 2).should eq(all_null_nested_arrays)

      destination = w104_run_writer_case(parent, "all-null-datetime64", "Nullable(DateTime64(9, 'UTC'))") do |path|
        CrystalClick::WidePartWriter.write_uint64_nullable_datetime64_pair(
          path, "pk", w104_slice(keys), "value", w104_slice(all_null_ticks), 9, rows_per_mark: 1, time_zone: "UTC"
        )
      end
      CrystalClick::WidePart.open_typed(destination, "value").read_nullable_datetime64_ticks_mark_range("value", 0, 2).should eq(all_null_ticks)

      destination = w104_run_writer_case(parent, "empty-datetime64-array", "Array(DateTime64(9, 'UTC'))") do |path|
        CrystalClick::WidePartWriter.write_uint64_array_datetime64_pair(
          path, "pk", w104_slice(keys), "value", w104_slice(empty_tick_arrays), 9, rows_per_mark: 1, time_zone: "UTC"
        )
      end
      CrystalClick::WidePart.open_typed(destination, "value").read_array_datetime64_ticks_mark_range("value", 0, 2).should eq(empty_tick_arrays)

      destination = w104_run_writer_case(parent, "all-null-datetime64-array", "Array(Nullable(DateTime64(9, 'UTC')))") do |path|
        CrystalClick::WidePartWriter.write_uint64_array_nullable_datetime64_pair(
          path, "pk", w104_slice(keys), "value", w104_slice(all_null_tick_arrays), 9, rows_per_mark: 1, time_zone: "UTC"
        )
      end
      CrystalClick::WidePart.open_typed(destination, "value").read_array_nullable_datetime64_ticks_mark_range("value", 0, 2).should eq(all_null_tick_arrays)

      zero_keys = [] of UInt64
      zero_values = [] of UInt32
      w104_reject_before_stage(parent, "zero-row") do |path|
        CrystalClick::WidePartWriter.write_uint64_datetime_pair(
          path, "pk", w104_slice(zero_keys), "value", w104_slice(zero_values), rows_per_mark: 1, time_zone: "UTC"
        )
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "uses exact zone-qualified temporal schemas for named-flat Tuple leaves while retaining raw values" do
    parent = File.tempname("crystal-click-writer-w104-tuple")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64]
    seconds = [0_u32, 1_u32, UInt32::MAX]
    ticks = [Int64::MIN, -1_i64, Int64::MAX]

    begin
      {"UTC", "Etc/UTC"}.each do |zone|
        leaf = "DateTime('#{zone}')"
        tuple_type = "Tuple(event #{leaf})"
        values = seconds.map { |value| CrystalClick::DateTimeValue.new(value) }
        destination = File.join(parent, "tuple-#{zone.gsub('/', '-')}")
        CrystalClick::WidePartWriter.write_uint64_tuple_pair(
          destination, "pk", w104_slice(keys), "value", tuple_type,
          [CrystalClick::WideTupleLeafColumn.new("event", leaf, values)] of CrystalClick::WideTupleLeafColumn,
          rows_per_mark: 2
        ).should eq(destination)
        w104_assert_schema(destination, tuple_type)
        decoded = CrystalClick::WidePart.open_typed(destination, "value").read_tuple_mark_range("value", 0, 2)
        decoded.fields.map(&.type_name).should eq([leaf])
        decoded.columns.first.values.should eq(values)
      end

      (0..9).each do |precision|
        leaf = "DateTime64(#{precision}, 'UTC')"
        tuple_type = "Tuple(event #{leaf})"
        values = ticks.map { |value| CrystalClick::DateTime64Value.new(value, precision) }
        destination = File.join(parent, "tuple-datetime64-#{precision}")
        CrystalClick::WidePartWriter.write_uint64_tuple_pair(
          destination, "pk", w104_slice(keys), "value", tuple_type,
          [CrystalClick::WideTupleLeafColumn.new("event", leaf, values)] of CrystalClick::WideTupleLeafColumn,
          rows_per_mark: 2
        ).should eq(destination)
        w104_assert_schema(destination, tuple_type)
        decoded = CrystalClick::WidePart.open_typed(destination, "value").read_tuple_mark_range("value", 0, 2)
        decoded.fields.map(&.type_name).should eq([leaf])
        decoded.columns.first.values.should eq(values)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "fails the real staged schema comparator for the same raw payload under a different expected zone" do
    parent = File.tempname("crystal-click-writer-w104-wrong-zone")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64]
    seconds = [0_u32, 1_u32, UInt32::MAX]
    nullable_seconds = [0_u32.as(UInt32?), nil, UInt32::MAX.as(UInt32?)]
    array_seconds = [[] of UInt32, [0_u32, UInt32::MAX], [1_u32]]
    array_nullable_seconds = [[] of UInt32?, [nil, 0_u32.as(UInt32?)], [UInt32::MAX.as(UInt32?)]]
    nested_seconds = [[] of Array(UInt32), [[0_u32, UInt32::MAX]], [[1_u32]]]
    nested_nullable_seconds = [
      [] of Array(UInt32?),
      [[nil, 0_u32.as(UInt32?)], [UInt32::MAX.as(UInt32?)]],
      [[1_u32.as(UInt32?)]],
    ]
    expected_zone_b = "Etc/UTC"

    begin
      scalar = File.join(parent, "scalar")
      CrystalClick::WidePartWriter.write_uint64_datetime_pair(scalar, "pk", w104_slice(keys), "value", w104_slice(seconds), rows_per_mark: 2, time_zone: "UTC")
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_scalar(scalar, keys, seconds, "DateTime('#{expected_zone_b}')", 2)
      end
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_scalar(scalar, keys, seconds, "DateTime", 2)
      end

      nullable = File.join(parent, "nullable")
      CrystalClick::WidePartWriter.write_uint64_nullable_datetime_pair(nullable, "pk", w104_slice(keys), "value", w104_slice(nullable_seconds), rows_per_mark: 2, time_zone: "UTC")
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_scalar(nullable, keys, nullable_seconds, "Nullable(DateTime('#{expected_zone_b}'))", 2)
      end
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_scalar(nullable, keys, nullable_seconds, "Nullable(DateTime)", 2)
      end

      array = File.join(parent, "array")
      CrystalClick::WidePartWriter.write_uint64_array_datetime_pair(array, "pk", w104_slice(keys), "value", w104_slice(array_seconds), rows_per_mark: 2, time_zone: "UTC")
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_array(array, keys, array_seconds, "DateTime('#{expected_zone_b}')", 2)
      end
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_array(array, keys, array_seconds, "DateTime", 2)
      end

      array_nullable = File.join(parent, "array-nullable")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_datetime_pair(array_nullable, "pk", w104_slice(keys), "value", w104_slice(array_nullable_seconds), rows_per_mark: 2, time_zone: "UTC")
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_array_nullable(array_nullable, keys, array_nullable_seconds, "DateTime('#{expected_zone_b}')", 2)
      end
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_array_nullable(array_nullable, keys, array_nullable_seconds, "DateTime", 2)
      end

      nested = File.join(parent, "nested")
      CrystalClick::WidePartWriter.write_uint64_array_array_datetime_pair(nested, "pk", w104_slice(keys), "value", w104_slice(nested_seconds), rows_per_mark: 2, time_zone: "UTC")
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_array_array(nested, keys, nested_seconds, "DateTime('#{expected_zone_b}')", 2)
      end
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_array_array(nested, keys, nested_seconds, "DateTime", 2)
      end

      nested_nullable = File.join(parent, "nested-nullable")
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_datetime_pair(nested_nullable, "pk", w104_slice(keys), "value", w104_slice(nested_nullable_seconds), rows_per_mark: 2, time_zone: "UTC")
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_array_array_nullable(nested_nullable, keys, nested_nullable_seconds, "DateTime('#{expected_zone_b}')", 2)
      end
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_array_array_nullable(nested_nullable, keys, nested_nullable_seconds, "DateTime", 2)
      end

      ticks = [Int64::MIN, -1_i64, Int64::MAX]
      nullable_ticks = [nil.as(Int64?), Int64::MIN.as(Int64?), Int64::MAX.as(Int64?)]
      array_ticks = [[] of Int64, [Int64::MIN, Int64::MAX], [-1_i64]]
      array_nullable_ticks = [[] of Int64?, [nil.as(Int64?), Int64::MIN.as(Int64?)], [Int64::MAX.as(Int64?)]]
      nested_ticks = [[] of Array(Int64), [[Int64::MIN, Int64::MAX]], [[-1_i64]]]
      nested_nullable_ticks = [
        [] of Array(Int64?),
        [[nil.as(Int64?), Int64::MIN.as(Int64?)]],
        [[Int64::MAX.as(Int64?)]],
      ]
      datetime64 = File.join(parent, "datetime64")
      CrystalClick::WidePartWriter.write_uint64_datetime64_pair(datetime64, "pk", w104_slice(keys), "value", w104_slice(ticks), 3, rows_per_mark: 2, time_zone: "UTC")
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_scalar(datetime64, keys, ticks, "DateTime64(3, '#{expected_zone_b}')", 2)
      end
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_scalar(datetime64, keys, ticks, "DateTime64(3)", 2)
      end

      datetime64_nullable = File.join(parent, "datetime64-nullable")
      CrystalClick::WidePartWriter.write_uint64_nullable_datetime64_pair(datetime64_nullable, "pk", w104_slice(keys), "value", w104_slice(nullable_ticks), 3, rows_per_mark: 2, time_zone: "UTC")
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_scalar(datetime64_nullable, keys, nullable_ticks, "Nullable(DateTime64(3, '#{expected_zone_b}'))", 2)
      end
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_scalar(datetime64_nullable, keys, nullable_ticks, "Nullable(DateTime64(3))", 2)
      end

      datetime64_array = File.join(parent, "datetime64-array")
      CrystalClick::WidePartWriter.write_uint64_array_datetime64_pair(datetime64_array, "pk", w104_slice(keys), "value", w104_slice(array_ticks), 3, rows_per_mark: 2, time_zone: "UTC")
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_array(datetime64_array, keys, array_ticks, "DateTime64(3, '#{expected_zone_b}')", 2)
      end
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_array(datetime64_array, keys, array_ticks, "DateTime64(3)", 2)
      end

      datetime64_array_nullable = File.join(parent, "datetime64-array-nullable")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_datetime64_pair(datetime64_array_nullable, "pk", w104_slice(keys), "value", w104_slice(array_nullable_ticks), 3, rows_per_mark: 2, time_zone: "UTC")
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_array_nullable(datetime64_array_nullable, keys, array_nullable_ticks, "DateTime64(3, '#{expected_zone_b}')", 2)
      end
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_array_nullable(datetime64_array_nullable, keys, array_nullable_ticks, "DateTime64(3)", 2)
      end

      datetime64_nested = File.join(parent, "datetime64-nested")
      CrystalClick::WidePartWriter.write_uint64_array_array_datetime64_pair(datetime64_nested, "pk", w104_slice(keys), "value", w104_slice(nested_ticks), 3, rows_per_mark: 2, time_zone: "UTC")
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_array_array(datetime64_nested, keys, nested_ticks, "DateTime64(3, '#{expected_zone_b}')", 2)
      end
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_array_array(datetime64_nested, keys, nested_ticks, "DateTime64(3)", 2)
      end

      datetime64_nested_nullable = File.join(parent, "datetime64-nested-nullable")
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_datetime64_pair(datetime64_nested_nullable, "pk", w104_slice(keys), "value", w104_slice(nested_nullable_ticks), 3, rows_per_mark: 2, time_zone: "UTC")
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_array_array_nullable(datetime64_nested_nullable, keys, nested_nullable_ticks, "DateTime64(3, '#{expected_zone_b}')", 2)
      end
      w104_expect_schema_mismatch do
        CrystalClick::WidePartWriter.w104_test_validate_array_array_nullable(datetime64_nested_nullable, keys, nested_nullable_ticks, "DateTime64(3)", 2)
      end

      tuple_values = seconds.map { |value| CrystalClick::DateTimeValue.new(value) }
      tuple_leaf_a = "DateTime('UTC')"
      tuple_a = "Tuple(event #{tuple_leaf_a})"
      tuple_path = File.join(parent, "tuple")
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        tuple_path, "pk", w104_slice(keys), "value", tuple_a,
        [CrystalClick::WideTupleLeafColumn.new("event", tuple_leaf_a, tuple_values)] of CrystalClick::WideTupleLeafColumn,
        rows_per_mark: 2
      )
      w104_tuple_leaf_buffers = [tuple_values] of CrystalClick::WideTupleLeafColumn::Buffer
      tuple_leaf_b = "DateTime('#{expected_zone_b}')"
      w104_tuple_type_b = "Tuple(event #{tuple_leaf_b})"
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w104_test_validate_tuple_stage(
          tuple_path, keys, w104_tuple_type_b, w104_tuple_leaf_buffers, 2
        )
      end
      error.message.not_nil!.should contain("staged Tuple columns metadata differs")
      bare_tuple_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w104_test_validate_tuple_stage(
          tuple_path, keys, "Tuple(event DateTime)", w104_tuple_leaf_buffers, 2
        )
      end
      bare_tuple_error.message.not_nil!.should contain("staged Tuple columns metadata differs")

      tuple_ticks = ticks.map { |value| CrystalClick::DateTime64Value.new(value, 3) }
      tuple_datetime64_leaf_a = "DateTime64(3, 'UTC')"
      tuple_datetime64_a = "Tuple(event #{tuple_datetime64_leaf_a})"
      tuple_datetime64_path = File.join(parent, "tuple-datetime64")
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        tuple_datetime64_path, "pk", w104_slice(keys), "value", tuple_datetime64_a,
        [CrystalClick::WideTupleLeafColumn.new("event", tuple_datetime64_leaf_a, tuple_ticks)] of CrystalClick::WideTupleLeafColumn,
        rows_per_mark: 2
      )
      tuple_datetime64_buffers = [tuple_ticks] of CrystalClick::WideTupleLeafColumn::Buffer
      tuple_datetime64_leaf_b = "DateTime64(3, '#{expected_zone_b}')"
      tuple_datetime64_type_b = "Tuple(event #{tuple_datetime64_leaf_b})"
      tuple_datetime64_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w104_test_validate_tuple_stage(
          tuple_datetime64_path, keys, tuple_datetime64_type_b, tuple_datetime64_buffers, 2
        )
      end
      tuple_datetime64_error.message.not_nil!.should contain("staged Tuple columns metadata differs")
      bare_tuple_datetime64_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w104_test_validate_tuple_stage(
          tuple_datetime64_path, keys, "Tuple(event DateTime64(3))", tuple_datetime64_buffers, 2
        )
      end
      bare_tuple_datetime64_error.message.not_nil!.should contain("staged Tuple columns metadata differs")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "accepts the canonical ClickHouse Fixed timezone spelling and keeps it exact" do
    parent = File.tempname("crystal-click-writer-w104-fixed")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    seconds = [0_u32, UInt32::MAX]

    begin
      destination = w104_run_writer_case(parent, "fixed", "DateTime('Fixed/UTC+05:45:00')") do |path|
        CrystalClick::WidePartWriter.write_uint64_datetime_pair(
          path, "pk", w104_slice(keys), "value", w104_slice(seconds),
          rows_per_mark: 1, time_zone: "Fixed/UTC+05:45:00"
        )
      end
      CrystalClick::WidePart.open_typed(destination, "value").read_datetime_seconds_mark_range("value", 0, 2).should eq(seconds)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
