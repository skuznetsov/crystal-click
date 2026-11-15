require "./spec_helper"
require "atomic"

PARALLEL_SCAN_WIDE_FIXTURE              = File.expand_path("../test/fixtures/public/wide_map_nullable_w53/part", __DIR__)
PARALLEL_SCAN_WIDE_NONPRIMITIVE_FIXTURE = File.expand_path("../test/fixtures/public/wide_variant_w56/compact/part", __DIR__)

private def parallel_scan_copy_fixture(source : String, root : String, part_name : String) : String
  target = File.join(root, part_name)
  FileUtils.cp_r(source, target)
  target
end

describe "CompressedStreamBudget parallel reservations" do
  {% unless flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
    it "does not admit concurrent reservations beyond one cumulative limit" do
      capacity = 8_000
      attempts_per_worker = 4_000
      worker_count = 8
      budget = CrystalClick::CompressedStreamBudget.new(
        CrystalClick::CompressedStreamLimits.new(max_file_bytes: capacity),
      )
      budget.enable_synchronization!
      successes = Atomic(Int32).new(0)
      failures = Atomic(Int32).new(0)

      threads = worker_count.times.map do
        Thread.new do
          attempts_per_worker.times do
            begin
              budget.reserve_file_bytes(1_i64)
              successes.add(1)
            rescue CrystalClick::CorruptPartError
              failures.add(1)
            end
          end
        end
      end
      threads.each(&.join)

      successes.get.should eq(capacity)
      failures.get.should eq(worker_count * attempts_per_worker - capacity)
      budget.file_byte_count.should eq(capacity.to_i64)
    end
  {% end %}
end

private def parallel_scan_write_compact_fixture(
  destination : String,
  keys : Array(UInt64),
  rows_per_mark : Int32 = 2,
) : String
  type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical("UInt64") ||
         raise("UInt64 type was not admitted")
  values = Array(CrystalClick::BinaryValue).new(keys.size)
  keys.each { |key| values << CrystalClick::BinaryValue.uint64(key) }
  granules = [] of Array(CrystalClick::BinaryValue)
  offset = 0
  while offset < values.size
    end_offset = offset + rows_per_mark < values.size ? offset + rows_per_mark : values.size
    granules << values[offset...end_offset]
    offset = end_offset
  end
  CrystalClick::CompactPartWriter.write_uint64_columns(
    destination,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    [CrystalClick::CompactPartColumn.binary_bulk("value", type, granules)],
    rows_per_mark: rows_per_mark,
    frame_bytes: 32,
    mark_format: CrystalClick::CompactMarkFormat::Mrk3,
  )
end

describe "Compact parallel reader transport budget" do
  it "charges reopened readers to their shared cumulative budget" do
    root = File.tempname("crystal-click-parallel-budget-reopen")
    Dir.mkdir(root)
    begin
      compact_path = parallel_scan_write_compact_fixture(
        File.join(root, "all_1_1_0"),
        [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64],
      )
      source = CrystalClick::CompactPartTable.open_selected_typed([compact_path], ["pk"])
      budget = source.parallel_scan_transport_budget!
      opened_bytes = budget.file_byte_count

      first_worker = CrystalClick::CompactPartTable.open_selected_typed_with_transport_budget(
        [compact_path], ["pk"], budget,
      )
      second_worker = CrystalClick::CompactPartTable.open_selected_typed_with_transport_budget(
        [compact_path], ["pk"], budget,
      )
      admitted_bytes = budget.file_byte_count
      admitted_bytes.should be > opened_bytes

      observed = [] of UInt64
      first_worker.scan_typed_mark_indices([0, 2], 1) do |batch|
        observed.concat(batch.values_for("pk", UInt64).to_a)
      end
      second_worker.scan_typed_mark_indices([1, 3], 1) do |batch|
        observed.concat(batch.values_for("pk", UInt64).to_a)
      end

      observed.sort.should eq([1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64])
      budget.file_byte_count.should be > admitted_bytes
    ensure
      FileUtils.rm_rf(root)
    end
  end
end

describe "TypedPartTable parallel typed scan" do
  it "partitions one Wide part by marks and propagates callback failures before reuse" do
    root = File.tempname("crystal-click-parallel-typed-wide")
    Dir.mkdir(root)
    begin
      wide_path = parallel_scan_copy_fixture(PARALLEL_SCAN_WIDE_FIXTURE, root, "all_1_1_0")
      table = CrystalClick::TypedPartTable.open_selected_typed([wide_path], ["pk"])
      table.part_mark_row_counts[0].size.should eq(4)

      expected = [] of UInt64
      table.scan_typed { |batch| expected.concat(batch.values_for("pk", UInt64).to_a) }
      caller_thread_id = Thread.current.object_id
      observed = [] of UInt64
      offsets = [] of UInt64
      observed_marks = [] of Int32
      callback_count = 0

      {% if flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
        expect_raises(CrystalClick::UnsupportedFormatError, /execution context/) do
          table.scan_typed_parallel(workers: 2, batch_rows: 1) { |_batch| }
        end
      {% else %}
        table.scan_typed_parallel(workers: 4, batch_rows: 1) do |batch|
          Thread.current.object_id.should eq(caller_thread_id)
          if callback_count == 0
            worker_names = [] of String
            Fiber::ExecutionContext.each do |context|
              if isolated = context.as?(Fiber::ExecutionContext::Isolated)
                if isolated.running? && isolated.name.starts_with?("crystal-click typed scan worker ")
                  worker_names << isolated.name
                end
              end
            end
            worker_names.size.should eq(4)
          end
          batch.part_index.should eq(0)
          observed_marks << batch.mark_index if observed_marks.last? != batch.mark_index
          batch.values_for("pk", UInt64).each_with_index do |value, row_index|
            observed << value
            offsets << batch.source_row_offset + row_index.to_u64
          end
          callback_count += 1
        end
        observed.should eq(expected)
        offsets.should eq((0_u64...expected.size.to_u64).to_a)
        observed_marks.should eq([0_i32, 1_i32, 2_i32, 3_i32])

        callback_error = IO::Error.new("parallel callback failure")
        raised_callback_error = expect_raises(IO::Error) do
          table.scan_typed_parallel(workers: 4, batch_rows: 1) do |_batch|
            raise callback_error
          end
        end
        raised_callback_error.object_id.should eq(callback_error.object_id)

        reused = [] of UInt64
        table.scan_typed_parallel(workers: 4, batch_rows: 1) do |batch|
          reused.concat(batch.values_for("pk", UInt64).to_a)
        end
        reused.should eq(expected)

        stopped_callbacks = 0
        table.scan_typed_parallel(workers: 4, batch_rows: 1) do |_batch|
          stopped_callbacks += 1
          break
        end
        stopped_callbacks.should eq(1)

        after_break = [] of UInt64
        table.scan_typed_parallel(workers: 4, batch_rows: 1) do |batch|
          after_break.concat(batch.values_for("pk", UInt64).to_a)
        end
        after_break.should eq(expected)
      {% end %}
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "propagates a Compact frame checksum failure and can reuse the table after repair" do
    root = File.tempname("crystal-click-parallel-typed-compact-error")
    Dir.mkdir(root)
    begin
      compact_path = parallel_scan_write_compact_fixture(
        File.join(root, "all_1_1_0"),
        [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64],
      )
      table = CrystalClick::TypedPartTable.open_selected_typed([compact_path], ["pk"])
      data_path = File.join(compact_path, "data.bin")
      {% if flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
        observed = [] of UInt64
        table.scan_typed_parallel(workers: 1, batch_rows: 1) do |batch|
          observed.concat(batch.values_for("pk", UInt64).to_a)
        end
        observed.should eq([1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64])
      {% else %}
        original_data = File.read(data_path).to_slice.dup
        corrupted_data = original_data.dup
        corrupted_data[corrupted_data.size - 1] ^= 1_u8

        callback_count = 0
        File.write(data_path, corrupted_data)
        begin
          source_error = expect_raises(CrystalClick::CorruptPartError) do
            table.scan_typed_parallel(workers: 2, batch_rows: 1) do |_batch|
              callback_count += 1
            end
          end
          source_error.message.not_nil!.should contain("checksum")
          callback_count.should eq(6)
        ensure
          File.write(data_path, original_data)
        end

        observed = [] of UInt64
        table.scan_typed_parallel(workers: 2, batch_rows: 1) do |batch|
          observed.concat(batch.values_for("pk", UInt64).to_a)
        end
        observed.should eq([1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64])
      {% end %}
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "falls back to serial order when there is only one nonempty mark" do
    root = File.tempname("crystal-click-parallel-typed-single-mark")
    Dir.mkdir(root)
    begin
      compact_path = parallel_scan_write_compact_fixture(
        File.join(root, "all_1_1_0"),
        [31_u64, 32_u64, 33_u64],
        rows_per_mark: 16,
      )
      table = CrystalClick::TypedPartTable.open_selected_typed([compact_path], ["pk"])
      table.part_mark_row_counts[0].size.should eq(1)
      observed = [] of UInt64
      {% if flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
        expect_raises(CrystalClick::UnsupportedFormatError, /execution context/) do
          table.scan_typed_parallel(workers: 4, batch_rows: 1) { |_batch| }
        end
        table.scan_typed_parallel(workers: 1, batch_rows: 1) do |batch|
          observed.concat(batch.values_for("pk", UInt64).to_a)
        end
      {% else %}
        table.scan_typed_parallel(workers: 4, batch_rows: 1) do |batch|
          observed.concat(batch.values_for("pk", UInt64).to_a)
        end
      {% end %}
      observed.should eq([31_u64, 32_u64, 33_u64])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "preserves caller part and row order across mixed Wide and Compact parts" do
    root = File.tempname("crystal-click-parallel-typed-mixed")
    Dir.mkdir(root)
    begin
      wide_path = parallel_scan_copy_fixture(PARALLEL_SCAN_WIDE_FIXTURE, root, "all_1_1_0")
      compact_path = parallel_scan_write_compact_fixture(
        File.join(root, "all_2_2_0"),
        [21_u64, 22_u64, 23_u64, 24_u64, 25_u64, 26_u64, 27_u64],
      )
      table = CrystalClick::TypedPartTable.open_selected_typed([wide_path, compact_path], ["pk"])
      table.part_mark_row_counts.size.should eq(2)

      expected = [] of UInt64
      table.scan_typed { |batch| expected.concat(batch.values_for("pk", UInt64).to_a) }
      {% if flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
        expect_raises(CrystalClick::UnsupportedFormatError, /execution context/) do
          table.scan_typed_parallel(workers: 3, batch_rows: 2) { |_batch| }
        end
      {% else %}
        observed = [] of UInt64
        source_offsets = [] of UInt64
        part_indices = [] of Int32
        table.scan_typed_parallel(workers: 3, batch_rows: 2) do |batch|
          batch.values_for("pk", UInt64).each_with_index do |value, row_index|
            observed << value
            source_offsets << batch.source_row_offset + row_index.to_u64
            part_indices << batch.part_index
          end
        end

        observed.should eq(expected)
        source_offsets.should eq((0_u64...expected.size.to_u64).to_a)
        part_indices.should eq(Array(Int32).new(7, 0_i32) + Array(Int32).new(7, 1_i32))
      {% end %}
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps one-worker serial semantics and validates the worker bound" do
    root = File.tempname("crystal-click-parallel-typed-serial")
    Dir.mkdir(root)
    begin
      compact_path = parallel_scan_copy_fixture(PARALLEL_SCAN_WIDE_NONPRIMITIVE_FIXTURE, root, "all_1_1_0")
      table = CrystalClick::TypedPartTable.open_selected_typed([compact_path], ["payload"])
      callbacks = 0
      table.scan_typed_parallel(workers: 1, batch_rows: 2) { |_batch| callbacks += 1 }
      callbacks.should be > 0

      expect_raises(CrystalClick::BoundsError) do
        CrystalClick::TypedPartTable.validate_parallel_workers!(0)
      end
      expect_raises(CrystalClick::BoundsError) do
        CrystalClick::TypedPartTable.validate_parallel_workers!(33)
      end

      {% if !flag?(:without_mt) && (!flag?(:preview_mt) || flag?(:execution_context)) %}
        expect_raises(CrystalClick::UnsupportedFormatError, /primitive numeric/) do
          table.scan_typed_parallel(workers: 2) { |_batch| }
        end
      {% end %}
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
