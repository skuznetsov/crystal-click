require "./spec_helper"
require "atomic"

PARALLEL_SCAN_WIDE_FIXTURE              = File.expand_path("../test/fixtures/public/wide_map_nullable_w53/part", __DIR__)
PARALLEL_SCAN_WIDE_NONPRIMITIVE_FIXTURE = File.expand_path("../test/fixtures/public/wide_variant_w56/compact/part", __DIR__)
PARALLEL_SCAN_WIDE_UINT64_PAIR_FIXTURE  = File.expand_path("../test/fixtures/public/wide_u64_pk_cidx/part", __DIR__)

private def parallel_scan_copy_fixture(source : String, root : String, part_name : String) : String
  target = File.join(root, part_name)
  FileUtils.cp_r(source, target)
  target
end

private def parallel_scan_wide_mark_compressed_offset(part_path : String, column : String, mark_index : Int) : Int
  reader = CrystalClick::WidePart.open_typed(part_path, column)
  bytes = File.read(reader.mark_path).to_slice
  offset = mark_index * 24
  value = 0_u64
  8.times do |index|
    value |= bytes[offset + index].to_u64 << (index * 8)
  end
  value.to_i
end

private def parallel_scan_corrupt_wide_frame_header(path : String, frame_offset : Int) : Bytes
  original = File.read(path).to_slice.dup
  corrupted = original.dup
  4.times { |index| corrupted[frame_offset + 17 + index] = 0_u8 }
  File.write(path, corrupted)
  original
end

private def parallel_scan_wide_uint64_worker_counts : Array(Int32)
  {% if flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
    [1]
  {% else %}
    [1, 4]
  {% end %}
end

private def parallel_scan_wide_uint64_pair_expected(
  table : CrystalClick::TypedPartTable,
) : {Array(UInt64), Array(UInt64)}
  keys = [] of UInt64
  values = [] of UInt64
  table.scan_typed do |batch|
    keys.concat(batch.values_for("pk", UInt64).to_a)
    values.concat(batch.values_for("value", UInt64).to_a)
  end
  {keys, values}
end

private def parallel_scan_assert_wide_uint64_batch_coordinates(batch : CrystalClick::WidePartTableBatch) : Nil
  batch.column_names.should eq(["pk", "value"])
  batch.column_type_for("pk").should eq("UInt64")
  batch.column_type_for("value").should eq("UInt64")
  batch.part_index.should eq(0)
  batch.part_row_offset.should eq(batch.source_row_offset)
  batch.mark_row_offset.should eq(batch.source_row_offset % 8_u64)
  batch.mark_index.should eq((batch.source_row_offset // 8_u64).to_i32)
  nil
end

private def parallel_scan_wide_uint64_nested_values(table : CrystalClick::TypedPartTable, workers : Int) : Array(UInt64)
  values = [] of UInt64
  table.scan_typed_parallel(workers: workers, batch_rows: 5) do |batch|
    values.concat(batch.values_for("value", UInt64).to_a)
  end
  values
end

private def parallel_scan_assert_wide_uint64_mutable_batch(
  keys : Slice(UInt64),
  values : Slice(UInt64),
  expected_key : UInt64,
  expected_value : UInt64,
) : Nil
  original_key = keys[0]
  original_value = values[0]
  keys[0] = UInt64::MAX
  values[0] = 0_u64
  keys[0].should eq(UInt64::MAX)
  values[0].should eq(0_u64)
  original_key.should eq(expected_key)
  original_value.should eq(expected_value)
  nil
end

private def parallel_scan_assert_wide_uint64_accessors(batch : CrystalClick::WidePartTableBatch, keys : Slice(UInt64)) : Nil
  batch.values_for("pk").to_unsafe.should eq(keys.to_unsafe)
  expect_raises(CrystalClick::UnsupportedFormatError, "typed accessor does not match selected column type") do
    batch.values_for("pk", Int64)
  end
  expect_raises(CrystalClick::UnsupportedFormatError, "column is not selected") do
    batch.values_for("absent")
  end
  nil
end

private def parallel_scan_assert_wide_uint64_order_and_lifetime(
  table : CrystalClick::TypedPartTable,
  workers : Int,
  expected_keys : Array(UInt64),
  expected_values : Array(UInt64),
) : Nil
  observed_keys = [] of UInt64
  observed_values = [] of UInt64
  callback_count = 0
  reentered = false
  first_batch = nil.as(CrystalClick::WidePartTableBatch?)
  table.scan_typed_parallel(workers: workers, batch_rows: 3) do |batch|
    first_batch ||= batch
    keys = batch.values_for("pk", UInt64)
    values = batch.values_for("value", UInt64)
    parallel_scan_assert_wide_uint64_batch_coordinates(batch)
    batch.row_count.should eq(keys.size.to_u64)
    values.size.should eq(keys.size)
    observed_keys.concat(keys.to_a)
    observed_values.concat(values.to_a)

    unless reentered
      parallel_scan_assert_wide_uint64_accessors(batch, keys)
      parallel_scan_wide_uint64_nested_values(table, workers).should eq(expected_values)
      GC.collect
      reentered = true
    end

    parallel_scan_assert_wide_uint64_mutable_batch(keys, values, expected_keys[0], expected_values[0]) if callback_count == 0
    callback_count += 1
  end
  observed_keys.should eq(expected_keys)
  observed_values.should eq(expected_values)
  callback_count.should be > 0
  reentered.should be_true
  first = first_batch.not_nil!
  parallel_scan_assert_wide_uint64_batch_coordinates(first)
  first.source_row_offset.should eq(0_u64)
  first.row_count.should eq(3_u64)
  nil
end

private def parallel_scan_assert_wide_uint64_callback_failure(
  table : CrystalClick::TypedPartTable,
  workers : Int,
) : Nil
  callback_error = IO::Error.new("Wide UInt64 callback failure")
  raised = expect_raises(IO::Error) do
    failed = false
    table.scan_typed_parallel(workers: workers, batch_rows: 3) do |_batch|
      unless failed
        failed = true
        raise callback_error
      end
    end
  end
  raised.object_id.should eq(callback_error.object_id)
  nil
end

private def parallel_scan_assert_wide_uint64_retry(
  table : CrystalClick::TypedPartTable,
  workers : Int,
  expected_keys : Array(UInt64),
  expected_values : Array(UInt64),
) : Nil
  retried = [] of {UInt64, UInt64}
  table.scan_typed_parallel(workers: workers, batch_rows: 3) do |batch|
    keys = batch.values_for("pk", UInt64)
    values = batch.values_for("value", UInt64)
    keys.each_with_index do |key, row_index|
      retried << {key, values[row_index]}
    end
  end
  retried.should eq(expected_keys.zip(expected_values))
  nil
end

private def parallel_scan_assert_wide_uint64_bad_boundary_frame(
  table : CrystalClick::TypedPartTable,
  wide_path : String,
  data_path : String,
  workers : Int,
  mark_index : Int,
  expected_callbacks : Int,
) : Nil
  original = parallel_scan_corrupt_wide_frame_header(
    data_path,
    parallel_scan_wide_mark_compressed_offset(wide_path, "value", mark_index),
  )
  begin
    callbacks = 0
    expect_raises(CrystalClick::CorruptPartError) do
      table.scan_typed_parallel(workers: workers, batch_rows: 1) do |_batch|
        callbacks += 1
      end
    end
    callbacks.should eq(expected_callbacks)
  ensure
    File.write(data_path, original)
  end
  nil
end

describe CrystalClick::WidePartTableBatch do
  it "keeps the selected slices when the input slice vector changes" do
    keys = [1_u64, 2_u64]
    replacement = [7_u64, 8_u64]
    slices = [keys.to_unsafe.to_slice(keys.size)]
    batch = CrystalClick::WidePartTableBatch.new(
      0_i32, "part", "part", 0_i32, 0_u64, 0_u64, 0_u64, ["pk"], slices, 2_u64,
    )
    slices[0] = replacement.to_unsafe.to_slice(replacement.size)

    batch.values_for("pk", UInt64).to_unsafe.should eq(keys.to_unsafe)
    batch.values_for("pk", UInt64).to_a.should eq([1_u64, 2_u64])
  end
end

describe CrystalClick::WideUInt64ScanWorkspacePool do
  it "leases an idle workspace exclusively and drops storage above the retained payload limit" do
    pool = CrystalClick::WideUInt64ScanWorkspacePool.new
    workspace = pool.try_acquire(0, 2).not_nil!
    workspace.prepare(8_192_u64)
    pool.try_acquire(0, 2).should be_nil
    pool.try_acquire(CrystalClick::WideUInt64ScanWorkspacePool::MAX_CACHED_WORKERS, 2).should be_nil
    pool.release(0, CrystalClick::WideUInt64ScanWorkspace.new(2))
    pool.try_acquire(0, 2).should be_nil
    pool.release(0, workspace)

    reused = pool.try_acquire(0, 2).not_nil!
    reused.same?(workspace).should be_true
    reused.decode_workspace.buffer_for(CrystalClick::WideUInt64ScanWorkspacePool::MAX_CACHED_PAYLOAD_BYTES_PER_WORKER)
    pool.release(0, reused)

    replacement = pool.try_acquire(0, 2).not_nil!
    replacement.same?(workspace).should be_false
    pool.release(0, replacement)
  end
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

  {% if IO::ByteFormat::SystemEndian == IO::ByteFormat::LittleEndian %}
  it "reuses each Compact worker's slab across marks and parts after callbacks return" do
    root = File.tempname("crystal-click-parallel-compact-slabs-")
    Dir.mkdir(root)
    begin
      part_rows = 16
      rows_per_mark = 2
      parts = [0, 1].map do |part_index|
        block = part_index + 1
        keys = Array(UInt64).new(part_rows) { |row| (part_index * part_rows + row + 1).to_u64 }
        parallel_scan_write_compact_fixture(File.join(root, "all_#{block}_#{block}_0"), keys,
          rows_per_mark: rows_per_mark)
      end
      {% if flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
        worker_counts = {1}
      {% else %}
        worker_counts = {1, 4}
      {% end %}

      worker_counts.each do |workers|
        table = CrystalClick::TypedPartTable.open_selected_typed(parts, ["pk", "value"])
        lane_bases = Hash(Int32, {UInt64, UInt64}).new
        observed = [] of UInt64
        table.scan_typed_parallel(workers: workers, batch_rows: 1) do |batch|
          keys = batch.values_for("pk", UInt64)
          values = batch.values_for("value", UInt64)
          expected = batch.source_row_offset + 1_u64
          row_byte_offset = (batch.source_row_offset % rows_per_mark) * sizeof(UInt64).to_u64
          worker = batch.mark_index % workers
          bases = {keys.to_unsafe.address.to_u64 - row_byte_offset,
                   values.to_unsafe.address.to_u64 - row_byte_offset}
          lane_bases.fetch(worker) { lane_bases[worker] = bases }.should eq(bases)
          if batch.source_row_offset == 0_u64
            # Give the other workers time to fill their slices while the
            # callback still holds both lanes of this mark.
            sleep 1.millisecond
          end
          keys.to_a.should eq([expected])
          values.to_a.should eq([expected])
          observed << keys[0]
        end
        observed.should eq((1_u64..(2 * part_rows).to_u64).to_a)
        lane_bases.size.should eq(workers)
        lane_bases.values.flat_map { |key, value| [key, value] }.uniq.size.should eq(2 * workers)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end
  {% end %}

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

  it "keeps two-column Wide UInt64 slices ordered, writable, reentrant, and callback-scoped" do
    root = File.tempname("crystal-click-parallel-typed-wide-u64-pair")
    Dir.mkdir(root)
    begin
      wide_path = parallel_scan_copy_fixture(PARALLEL_SCAN_WIDE_UINT64_PAIR_FIXTURE, root, "all_1_1_0")
      table = CrystalClick::TypedPartTable.open_selected_typed([wide_path], ["pk", "value"])
      expected_keys, expected_values = parallel_scan_wide_uint64_pair_expected(table)
      parallel_scan_wide_uint64_worker_counts.each do |workers|
        parallel_scan_assert_wide_uint64_order_and_lifetime(table, workers, expected_keys, expected_values)
        parallel_scan_assert_wide_uint64_callback_failure(table, workers)
        parallel_scan_assert_wide_uint64_retry(table, workers, expected_keys, expected_values)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects malformed adjacent and final Wide UInt64 frames before exposing their boundary mark" do
    root = File.tempname("crystal-click-parallel-typed-wide-u64-boundary")
    Dir.mkdir(root)
    begin
      keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
      values = keys.map { |key| key * 10_u64 }
      wide_path = CrystalClick::WidePartWriter.write_uint64_pair(
        File.join(root, "all_1_1_0"),
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2,
      )
      table = CrystalClick::TypedPartTable.open_selected_typed([wide_path], ["pk", "value"])

      data_path = CrystalClick::WidePart.open_typed(wide_path, "value").data_path
      parallel_scan_wide_uint64_worker_counts.each do |workers|
        parallel_scan_assert_wide_uint64_bad_boundary_frame(table, wide_path, data_path, workers, 1, 0)
        parallel_scan_assert_wide_uint64_bad_boundary_frame(table, wide_path, data_path, workers, 3, 4)
        parallel_scan_assert_wide_uint64_retry(table, workers, keys, values)
      end
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
