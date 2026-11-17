require "./spec_helper"

# Test-only observation of the real scan-scoped mmap and retained frame-index
# acquisitions. Probes remain disabled outside this spec's bounded windows.
module CrystalClick::CompactParallelScanMappingProbe
  alias Event = {String, UInt64}
  alias Snapshot = {Array(Event), Array(Event), Int32, Array(String), Array(String)}

  class_property enabled = false
  class_property watched_data_paths = Set(String).new
  class_property map_open_events = [] of Event
  class_property map_close_events = [] of Event
  class_property active_maps = {} of UInt64 => String
  class_property frame_index_builds = 0
  class_property columns_metadata_reads = [] of String
  class_property watched_part_paths = Set(String).new
  class_property lock = Thread::Mutex.new

  def self.begin_observing(paths : Array(String)) : Nil
    watched = Set(String).new
    paths.each { |path| watched << File.expand_path(path) }
    watched_parts = paths.map { |path| File.expand_path(File.dirname(path)) }.to_set
    lock.synchronize do
      self.watched_data_paths = watched
      self.watched_part_paths = watched_parts
      self.map_open_events = [] of Event
      self.map_close_events = [] of Event
      self.active_maps = {} of UInt64 => String
      self.frame_index_builds = 0
      self.columns_metadata_reads = [] of String
      self.enabled = true
    end
  end

  def self.stop_observing : Nil
    lock.synchronize { self.enabled = false }
  end

  def self.watching?(path : String) : Bool
    expanded = File.expand_path(path)
    lock.synchronize { enabled && watched_data_paths.includes?(expanded) }
  end

  def self.record_mapping_open(path : String, pointer : UInt64) : Nil
    expanded = File.expand_path(path)
    lock.synchronize do
      return nil unless enabled && watched_data_paths.includes?(expanded)
      raise "duplicate active mmap pointer in scan probe" if active_maps.has_key?(pointer)
      active_maps[pointer] = expanded
      map_open_events << {expanded, pointer}
    end
    nil
  end

  def self.record_mapping_close(pointer : UInt64) : Nil
    lock.synchronize do
      if path = active_maps.delete(pointer)
        map_close_events << {path, pointer}
      end
    end
    nil
  end

  def self.tracks_mapping?(pointer : UInt64) : Bool
    lock.synchronize { active_maps.has_key?(pointer) }
  end

  def self.record_frame_index_build : Nil
    lock.synchronize { self.frame_index_builds += 1 if enabled }
    nil
  end

  def self.record_columns_metadata_read(part_path : String) : Nil
    expanded = File.expand_path(part_path)
    lock.synchronize do
      if enabled && watched_part_paths.includes?(expanded)
        columns_metadata_reads << expanded
      end
    end
    nil
  end

  def self.snapshot : Snapshot
    lock.synchronize do
      {
        map_open_events.dup,
        map_close_events.dup,
        frame_index_builds,
        active_maps.values.dup,
        columns_metadata_reads.dup,
      }
    end
  end
end

class CrystalClick::PartMetadataFileReader
  def read(name : String, maximum_bytes : Int64 = MAX_METADATA_FILE_BYTES) : String
    text = previous_def(name, maximum_bytes)
    CompactParallelScanMappingProbe.record_columns_metadata_read(@part_path) if name == "columns.txt"
    text
  end
end

module CrystalClick::MMapDataSource
  def self.open_mapped_file(path : String, expected_size : Int64, max_size : Int64, shared : Bool = false) : MappedFile
    mapped_file = previous_def(path, expected_size, max_size, shared: shared)
    if CompactParallelScanMappingProbe.watching?(path)
      CompactParallelScanMappingProbe.record_mapping_open(
        path,
        mapped_file.bytes.to_unsafe.address.to_u64,
      )
    end
    mapped_file
  end
end

class CrystalClick::MMapDataSource::MappedFile
  def close : Nil
    pointer = bytes.to_unsafe.address.to_u64
    tracked = CompactParallelScanMappingProbe.tracks_mapping?(pointer)
    previous_def
    CompactParallelScanMappingProbe.record_mapping_close(pointer) if tracked
    nil
  end
end

class CrystalClick::CompressedFrameIndex
  def initialize(data : Bytes, limits : CompressedStreamLimits, budget : CompressedStreamBudget)
    previous_def(data, limits, budget)
    CompactParallelScanMappingProbe.record_frame_index_build
  end
end

private def compact_mapping_write_part(
  destination : String,
  keys : Array(UInt64),
  values : Array(UInt64),
  rows_per_mark : Int32 = 2,
) : String
  raise ArgumentError.new("test Compact key/value lengths differ") unless keys.size == values.size

  type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical("UInt64") ||
         raise("UInt64 type was not admitted")
  encoded_values = Array(CrystalClick::BinaryValue).new(values.size)
  values.each { |value| encoded_values << CrystalClick::BinaryValue.uint64(value) }
  granules = [] of Array(CrystalClick::BinaryValue)
  offset = 0
  while offset < encoded_values.size
    end_offset = offset + rows_per_mark < encoded_values.size ? offset + rows_per_mark : encoded_values.size
    granules << encoded_values[offset...end_offset]
    offset = end_offset
  end

  CrystalClick::CompactPartWriter.write_uint64_columns(
    destination,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    [CrystalClick::CompactPartColumn.binary_bulk("value", type, granules)],
    rows_per_mark: rows_per_mark,
    frame_bytes: 16,
    mark_format: CrystalClick::CompactMarkFormat::Mrk3,
  )
end

private def compact_mapping_scan_rows(
  table : CrystalClick::TypedPartTable,
  workers : Int32 = 1,
) : Array({Int32, UInt64, UInt64, UInt64})
  rows = [] of {Int32, UInt64, UInt64, UInt64}
  table.scan_typed_parallel(workers: workers, batch_rows: 1) do |batch|
    keys = batch.values_for("pk", UInt64)
    values = batch.values_for("value", UInt64)
    keys.each_with_index do |key, index|
      rows << {
        batch.part_index,
        batch.source_row_offset + index.to_u64,
        key,
        values[index],
      }
    end
  end
  rows
end

private def compact_mapping_assert_one_scan_owner(paths : Array(String)) : Nil
  snapshot = CrystalClick::CompactParallelScanMappingProbe.snapshot
  snapshot[0].map { |event| event[0] }.sort.should eq(paths.sort)
  snapshot[1].map { |event| event[0] }.sort.should eq(paths.sort)
  snapshot[2].should eq(0)
  snapshot[3].should be_empty
  paths.each do |path|
    snapshot[0].count { |event| event[0] == path }.should eq(1)
    snapshot[1].count { |event| event[0] == path }.should eq(1)
    snapshot[4].count { |part_path| part_path == File.dirname(path) }.should eq(0)
  end
end

private def compact_mapping_wait_for_path(path : String, timeout_ms : Int32 = 2_000) : Bool
  expected = File.expand_path(path)
  (timeout_ms // 10).times do
    return true if CrystalClick::CompactParallelScanMappingProbe.snapshot[0].any? { |event| event[0] == expected }
    sleep 10.milliseconds
  end
  false
end

private def compact_mapping_assert_worker_scans(
  table : CrystalClick::TypedPartTable,
  expected : Array({Int32, UInt64, UInt64, UInt64}),
  data_paths : Array(String),
  worker_counts : Array(Int32),
) : Nil
  worker_counts.each do |workers|
    CrystalClick::CompactParallelScanMappingProbe.begin_observing(data_paths)
    begin
      compact_mapping_scan_rows(table, workers).should eq(expected)
      table.checksum_verification.should eq(CrystalClick::ChecksumVerification::SizeChecked)
      compact_mapping_assert_one_scan_owner(data_paths)
    ensure
      CrystalClick::CompactParallelScanMappingProbe.stop_observing
    end
  end
  nil
end

private def compact_mapping_read_u32(bytes : Bytes, offset : Int) : UInt32
  bytes[offset].to_u32 |
    (bytes[offset + 1].to_u32 << 8) |
    (bytes[offset + 2].to_u32 << 16) |
    (bytes[offset + 3].to_u32 << 24)
end

private def compact_mapping_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times do |index|
    bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8
  end
  nil
end

private def compact_mapping_frame_offsets(bytes : Bytes) : Array(Int32)
  offsets = [] of Int32
  offset = 0
  while offset < bytes.size
    raise "truncated compressed test frame header" if bytes.size - offset < 25
    offsets << offset.to_i32
    offset += 16 + compact_mapping_read_u32(bytes, offset + 17).to_i
  end
  raise "trailing compressed test frame bytes" unless offset == bytes.size
  offsets
end

describe "Compact direct UInt64 scan mapping" do
  it "uses one scan mapping per part and reuses each admitted frame index at workers 1 and 4" do
    root = File.tempname("crystal-click-compact-scan-mapping-")
    Dir.mkdir(root)
    begin
      part_paths = [
        compact_mapping_write_part(
          File.join(root, "all_1_1_0"),
          Array(UInt64).new(16) { |index| index.to_u64 + 1_u64 },
          Array(UInt64).new(16) { |index| index.to_u64 + 101_u64 },
        ),
        compact_mapping_write_part(
          File.join(root, "all_2_2_0"),
          Array(UInt64).new(16) { |index| index.to_u64 + 1_001_u64 },
          Array(UInt64).new(16) { |index| index.to_u64 + 2_001_u64 },
        ),
      ]
      data_paths = part_paths.map { |path| File.join(path, "data.bin") }
      CrystalClick::CompactParallelScanMappingProbe.begin_observing(data_paths)
      table = CrystalClick::TypedPartTable.open_selected_typed(part_paths, ["pk", "value"])
      CrystalClick::CompactParallelScanMappingProbe.snapshot[2].should eq(part_paths.size)
      admitted_metadata_reads = CrystalClick::CompactParallelScanMappingProbe.snapshot[4]
      expected_metadata_paths = part_paths.flat_map do |path|
        Array.new(2, File.expand_path(path))
      end.sort
      admitted_metadata_reads.sort.should eq(expected_metadata_paths)
      CrystalClick::CompactParallelScanMappingProbe.stop_observing

      expected = compact_mapping_scan_rows(table, 1)
      expected.size.should eq(32)
      expected.select { |row| row[0] == 0_i32 }.size.should eq(16)
      expected.select { |row| row[0] == 1_i32 }.size.should eq(16)
      table.checksum_verification.should eq(CrystalClick::ChecksumVerification::SizeChecked)

      {% if flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
        compact_mapping_assert_worker_scans(table, expected, data_paths, [1])
      {% else %}
        compact_mapping_assert_worker_scans(table, expected, data_paths, [1, 4])
      {% end %}

      CrystalClick::CompactParallelScanMappingProbe.begin_observing(data_paths)
      table.scan_typed_candidate_marks([[] of Int32, [] of Int32]) { |_batch| fail "empty candidates emitted a batch" }
      table.scan_typed_window(table.total_row_count, 1) { |_batch| fail "EOF window emitted a batch" }
      empty_snapshot = CrystalClick::CompactParallelScanMappingProbe.snapshot
      empty_snapshot[0].should be_empty
      empty_snapshot[1].should be_empty
      empty_snapshot[2].should eq(0)
      empty_snapshot[3].should be_empty
      CrystalClick::CompactParallelScanMappingProbe.stop_observing

      CrystalClick::CompactParallelScanMappingProbe.begin_observing(data_paths)
      candidates = [] of {Int32, UInt64, UInt64, UInt64}
      table.scan_typed_candidate_marks([[3], [3]]) do |batch|
        keys = batch.values_for("pk", UInt64)
        values = batch.values_for("value", UInt64)
        keys.each_with_index do |key, index|
          candidates << {
            batch.part_index,
            batch.source_row_offset + index.to_u64,
            key,
            values[index],
          }
        end
      end
      expected_candidates = expected.select do |row|
        local_row = row[1] - row[0].to_u64 * 16_u64
        local_row // 2_u64 == 3_u64
      end
      candidates.should eq(expected_candidates)
      compact_mapping_assert_one_scan_owner(data_paths)
      CrystalClick::CompactParallelScanMappingProbe.stop_observing
    ensure
      CrystalClick::CompactParallelScanMappingProbe.stop_observing
      FileUtils.rm_rf(root)
    end
  end

  it "rejects a late mapped-header change before callbacks and closes the scan mapping" do
    root = File.tempname("crystal-click-compact-scan-header-")
    Dir.mkdir(root)
    begin
      part_path = compact_mapping_write_part(
        File.join(root, "all_1_1_0"),
        Array(UInt64).new(16) { |index| index.to_u64 + 1_u64 },
        Array(UInt64).new(16) { |index| index.to_u64 + 101_u64 },
      )
      data_path = File.join(part_path, "data.bin")
      table = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk", "value"])
      expected = compact_mapping_scan_rows(table, 1)
      original = writable_file_bytes(data_path)
      mutated = original.dup
      offsets = compact_mapping_frame_offsets(mutated)
      offsets.size.should be > 2
      late_frame = offsets.last.to_i
      old_decompressed_size = compact_mapping_read_u32(mutated, late_frame + 21)
      compact_mapping_write_u32(mutated, late_frame + 21, old_decompressed_size + 8_u32)

      CrystalClick::CompactParallelScanMappingProbe.begin_observing([data_path])
      callback_count = 0
      write_bytes(part_path, "data.bin", mutated)
      begin
        error = expect_raises(CrystalClick::CorruptPartError) do
          table.scan_typed_parallel(workers: 1, batch_rows: 1) do |_batch|
            callback_count += 1
          end
        end
        error.message.not_nil!.should contain("geometry changed")
        callback_count.should eq(0)
        compact_mapping_assert_one_scan_owner([data_path])
      ensure
        write_bytes(part_path, "data.bin", original)
        CrystalClick::CompactParallelScanMappingProbe.stop_observing
      end

      compact_mapping_scan_rows(table, 1).should eq(expected)
    ensure
      CrystalClick::CompactParallelScanMappingProbe.stop_observing
      FileUtils.rm_rf(root)
    end
  end

  {% unless flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
    it "closes the shared mapping after callback break and callback exception" do
      root = File.tempname("crystal-click-compact-scan-cancel-")
      Dir.mkdir(root)
      begin
        part_paths = [
          compact_mapping_write_part(
            File.join(root, "all_1_1_0"),
            [1_u64, 2_u64],
            [101_u64, 102_u64],
          ),
          compact_mapping_write_part(
            File.join(root, "all_2_2_0"),
            Array(UInt64).new(8) { |index| index.to_u64 + 1_001_u64 },
            Array(UInt64).new(8) { |index| index.to_u64 + 2_001_u64 },
          ),
        ]
        data_paths = part_paths.map { |path| File.join(path, "data.bin") }
        table = CrystalClick::TypedPartTable.open_selected_typed(part_paths, ["pk", "value"])
        expected = compact_mapping_scan_rows(table, 1)

        CrystalClick::CompactParallelScanMappingProbe.begin_observing(data_paths)
        break_callbacks = 0
        table.scan_typed_parallel(workers: 4, batch_rows: 1) do |batch|
          break_callbacks += 1
          batch.part_index.should eq(0)
          batch.source_row_offset.should eq(0_u64)
          compact_mapping_wait_for_path(data_paths[1]).should be_true
          break
        end
        break_callbacks.should eq(1)
        compact_mapping_assert_one_scan_owner(data_paths)
        CrystalClick::CompactParallelScanMappingProbe.stop_observing
        compact_scan_mapping_running_workers.should eq(0)

        CrystalClick::CompactParallelScanMappingProbe.begin_observing(data_paths)
        callback_error = IO::Error.new("Compact scan callback failed")
        raised = expect_raises(IO::Error) do
          table.scan_typed_parallel(workers: 4, batch_rows: 1) do |batch|
            batch.part_index.should eq(0)
            compact_mapping_wait_for_path(data_paths[1]).should be_true
            raise callback_error
          end
        end
        raised.object_id.should eq(callback_error.object_id)
        compact_mapping_assert_one_scan_owner(data_paths)
        CrystalClick::CompactParallelScanMappingProbe.stop_observing
        compact_scan_mapping_running_workers.should eq(0)

        compact_mapping_scan_rows(table, 4).should eq(expected)
      ensure
        CrystalClick::CompactParallelScanMappingProbe.stop_observing
        FileUtils.rm_rf(root)
      end
    end
  {% end %}
end

{% unless flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
  private def compact_scan_mapping_running_workers : Int32
    count = 0
    Fiber::ExecutionContext.each do |context|
      if isolated = context.as?(Fiber::ExecutionContext::Isolated)
        if isolated.running? && isolated.name.starts_with?("crystal-click typed scan worker ")
          count += 1
        end
      end
    end
    count
  end
{% end %}
