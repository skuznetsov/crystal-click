require "./spec_helper"

module CrystalClick::WideParallelScanMappingProbe
  alias Event = {String, UInt64}
  alias Snapshot = {Array(Event), Array(Event), Array(String)}

  class_property enabled = false
  class_property watched_paths = Set(String).new
  class_property opens = [] of Event
  class_property closes = [] of Event
  class_property active = {} of UInt64 => String
  class_property lock = Thread::Mutex.new

  def self.begin_observing(paths : Array(String)) : Nil
    lock.synchronize do
      self.watched_paths = paths.map { |path| File.expand_path(path) }.to_set
      self.opens = [] of Event
      self.closes = [] of Event
      self.active = {} of UInt64 => String
      self.enabled = true
    end
  end

  def self.stop_observing : Nil
    lock.synchronize { self.enabled = false }
  end

  def self.watching?(path : String) : Bool
    expanded = File.expand_path(path)
    lock.synchronize { enabled && watched_paths.includes?(expanded) }
  end

  def self.record_open(path : String, pointer : UInt64) : Nil
    expanded = File.expand_path(path)
    lock.synchronize do
      return nil unless enabled && watched_paths.includes?(expanded)
      raise "duplicate active mmap pointer in Wide scan probe" if active.has_key?(pointer)
      active[pointer] = expanded
      opens << {expanded, pointer}
    end
    nil
  end

  def self.tracks?(pointer : UInt64) : Bool
    lock.synchronize { active.has_key?(pointer) }
  end

  def self.record_close(pointer : UInt64) : Nil
    lock.synchronize do
      if path = active.delete(pointer)
        closes << {path, pointer}
      end
    end
    nil
  end

  def self.snapshot : Snapshot
    lock.synchronize { {opens.dup, closes.dup, active.values.dup} }
  end
end

module CrystalClick::MMapDataSource
  def self.open_mapped_file(path : String, expected_size : Int64, max_size : Int64) : MappedFile
    mapped_file = previous_def(path, expected_size, max_size)
    if WideParallelScanMappingProbe.watching?(path)
      WideParallelScanMappingProbe.record_open(path, mapped_file.bytes.to_unsafe.address.to_u64)
    end
    mapped_file
  end
end

class CrystalClick::MMapDataSource::MappedFile
  def close : Nil
    pointer = bytes.to_unsafe.address.to_u64
    tracked = WideParallelScanMappingProbe.tracks?(pointer)
    previous_def
    WideParallelScanMappingProbe.record_close(pointer) if tracked
    nil
  end
end

private def wide_mapping_copy_fixture(source : String, destination : String) : String
  FileUtils.cp_r(source, destination)
  destination
end

private def wide_mapping_data_paths(part_path : String) : Array(String)
  ["pk", "value"].map do |column|
    CrystalClick::WidePart.open_typed(part_path, column).parallel_numeric_scan_data_path
  end
end

private def wide_mapping_scan_rows(
  table : CrystalClick::TypedPartTable,
  workers : Int32,
) : Array({Int32, UInt64, UInt64, UInt64})
  rows = [] of {Int32, UInt64, UInt64, UInt64}
  table.scan_typed_parallel(workers: workers, batch_rows: 1) do |batch|
    keys = batch.values_for("pk", UInt64)
    values = batch.values_for("value", UInt64)
    keys.each_with_index do |key, index|
      rows << {batch.part_index, batch.source_row_offset + index.to_u64, key, values[index]}
    end
  end
  rows
end

private def wide_mapping_assert_one_per_path(paths : Array(String)) : Nil
  snapshot = CrystalClick::WideParallelScanMappingProbe.snapshot
  snapshot[0].map(&.[0]).sort.should eq(paths.map { |path| File.expand_path(path) }.sort)
  snapshot[1].map(&.[0]).sort.should eq(paths.map { |path| File.expand_path(path) }.sort)
  snapshot[2].should be_empty
  paths.each do |path|
    expanded = File.expand_path(path)
    snapshot[0].count { |event| event[0] == expanded }.should eq(1)
    snapshot[1].count { |event| event[0] == expanded }.should eq(1)
  end
end

describe "Wide parallel typed scan mapping" do
  fixture = File.expand_path("../test/fixtures/public/wide_u64_pk_cidx/part", __DIR__)

  it "maps each selected stream once for a one-worker scan and keeps each part lazy" do
    root = File.tempname("crystal-click-wide-scan-mapping-")
    Dir.mkdir(root)
    begin
      part_paths = [
        wide_mapping_copy_fixture(fixture, File.join(root, "all_1_1_0")),
        wide_mapping_copy_fixture(fixture, File.join(root, "all_2_2_0")),
      ]
      data_paths = part_paths.flat_map { |path| wide_mapping_data_paths(path) }
      table = CrystalClick::TypedPartTable.open_selected_typed(part_paths, ["pk", "value"])
      expected = [] of {Int32, UInt64, UInt64, UInt64}
      table.scan_typed do |batch|
        keys = batch.values_for("pk", UInt64)
        values = batch.values_for("value", UInt64)
        keys.each_with_index do |key, index|
          expected << {batch.part_index, batch.source_row_offset + index.to_u64, key, values[index]}
        end
      end

      CrystalClick::WideParallelScanMappingProbe.begin_observing(data_paths)
      first_callback = true
      observed = [] of {Int32, UInt64, UInt64, UInt64}
      table.scan_typed_parallel(workers: 1, batch_rows: 1) do |batch|
        if first_callback
          snapshot = CrystalClick::WideParallelScanMappingProbe.snapshot
          snapshot[0].map(&.[0]).sort.should eq(data_paths.first(2).map { |path| File.expand_path(path) }.sort)
          first_callback = false
        end
        keys = batch.values_for("pk", UInt64)
        values = batch.values_for("value", UInt64)
        keys.each_with_index do |key, index|
          observed << {batch.part_index, batch.source_row_offset + index.to_u64, key, values[index]}
        end
      end
      observed.should eq(expected)
      wide_mapping_assert_one_per_path(data_paths)
    ensure
      CrystalClick::WideParallelScanMappingProbe.stop_observing
      FileUtils.rm_rf(root)
    end
  end

  {% unless flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
    it "shares one read-only mapping per selected stream among workers" do
      root = File.tempname("crystal-click-wide-scan-mapping-workers-")
      Dir.mkdir(root)
      begin
        part_path = wide_mapping_copy_fixture(fixture, File.join(root, "all_1_1_0"))
        data_paths = wide_mapping_data_paths(part_path)
        table = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk", "value"])
        expected = wide_mapping_scan_rows(table, 1)

        CrystalClick::WideParallelScanMappingProbe.begin_observing(data_paths)
        wide_mapping_scan_rows(table, 4).should eq(expected)
        wide_mapping_assert_one_per_path(data_paths)
      ensure
        CrystalClick::WideParallelScanMappingProbe.stop_observing
        FileUtils.rm_rf(root)
      end
    end
  {% end %}

  it "releases the per-part image after callback cancellation and exceptions" do
    root = File.tempname("crystal-click-wide-scan-mapping-cancel-")
    Dir.mkdir(root)
    begin
      part_path = wide_mapping_copy_fixture(fixture, File.join(root, "all_1_1_0"))
      data_paths = wide_mapping_data_paths(part_path)
      table = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk", "value"])
      worker_counts = [1]
      {% if flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
      {% else %}
        worker_counts << 4
      {% end %}

      worker_counts.each do |workers|
        CrystalClick::WideParallelScanMappingProbe.begin_observing(data_paths)
        callbacks = 0
        table.scan_typed_parallel(workers: workers, batch_rows: 1) do |_batch|
          callbacks += 1
          break
        end
        callbacks.should eq(1)
        wide_mapping_assert_one_per_path(data_paths)

        CrystalClick::WideParallelScanMappingProbe.begin_observing(data_paths)
        callback_error = IO::Error.new("Wide scan callback failed")
        raised = expect_raises(IO::Error) do
          table.scan_typed_parallel(workers: workers, batch_rows: 1) do |_batch|
            raise callback_error
          end
        end
        raised.object_id.should eq(callback_error.object_id)
        wide_mapping_assert_one_per_path(data_paths)
        CrystalClick::WideParallelScanMappingProbe.stop_observing
      end
    ensure
      CrystalClick::WideParallelScanMappingProbe.stop_observing
      FileUtils.rm_rf(root)
    end
  end

  it "preserves the public and explicitly verified checksum policies" do
    root = File.tempname("crystal-click-wide-scan-mapping-checksum-")
    Dir.mkdir(root)
    begin
      part_path = wide_mapping_copy_fixture(fixture, File.join(root, "all_1_1_0"))
      data_paths = wide_mapping_data_paths(part_path)
      table = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk", "value"])
      data_path = data_paths[0]
      expected = [] of {Int32, UInt64, UInt64, UInt64}
      table.scan_typed do |batch|
        keys = batch.values_for("pk", UInt64)
        values = batch.values_for("value", UInt64)
        keys.each_with_index do |key, index|
          expected << {batch.part_index, batch.source_row_offset + index.to_u64, key, values[index]}
        end
      end
      original = writable_file_bytes(data_path)
      corrupted = original.dup
      corrupted[0] ^= 1_u8

      begin
        CrystalClick::WideParallelScanMappingProbe.begin_observing(data_paths)
        File.open(data_path, "wb") { |io| io.write(corrupted) }
        begin
          wide_mapping_scan_rows(table, 1).should eq(expected)
          wide_mapping_assert_one_per_path(data_paths)
        ensure
          CrystalClick::WideParallelScanMappingProbe.stop_observing
        end

        readers = CrystalClick::WidePart.open_primitive_numeric_columns(
          part_path,
          ["pk", "value"],
          verify_data_checksums: true,
        ).not_nil!
        mapped_paths = readers.map(&.parallel_numeric_scan_data_path)
        mapped_paths.sort.should eq(data_paths.sort)
        CrystalClick::WideParallelScanMappingProbe.begin_observing(data_paths)
        image = CrystalClick::WideScanImage.open(mapped_paths)
        begin
          scratch = Array(UInt64).new(4, 0_u64)
          error = expect_raises(CrystalClick::CorruptPartError) do
            readers[0].scan_uint64_mark_range_into(
              "pk",
              0,
              readers[0].mark_count,
              scratch.to_unsafe.to_slice(scratch.size),
              image,
            ) { |_values| }
          end
          error.message.not_nil!.should contain("checksum mismatch")
        ensure
          image.close
        end
        wide_mapping_assert_one_per_path(data_paths)
      ensure
        File.open(data_path, "wb") { |io| io.write(original) }
        CrystalClick::WideParallelScanMappingProbe.stop_observing
      end
    ensure
      CrystalClick::WideParallelScanMappingProbe.stop_observing
      FileUtils.rm_rf(root)
    end
  end

  it "closes a first mapping when a later selected stream cannot be opened" do
    root = File.tempname("crystal-click-wide-scan-mapping-partial-")
    Dir.mkdir(root)
    begin
      part_path = wide_mapping_copy_fixture(fixture, File.join(root, "all_1_1_0"))
      data_paths = wide_mapping_data_paths(part_path)
      table = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk", "value"])
      first_path, second_path = data_paths
      unavailable_path = "#{second_path}.unavailable"
      File.rename(second_path, unavailable_path)

      CrystalClick::WideParallelScanMappingProbe.begin_observing(data_paths)
      callback_count = 0
      begin
        expect_raises(File::NotFoundError) do
          table.scan_typed_parallel(workers: 1, batch_rows: 1) do |_batch|
            callback_count += 1
          end
        end
        callback_count.should eq(0)
        snapshot = CrystalClick::WideParallelScanMappingProbe.snapshot
        snapshot[0].map(&.[0]).should eq([File.expand_path(first_path)])
        snapshot[1].map(&.[0]).should eq([File.expand_path(first_path)])
        snapshot[2].should be_empty
      ensure
        File.rename(unavailable_path, second_path)
        CrystalClick::WideParallelScanMappingProbe.stop_observing
      end
    ensure
      CrystalClick::WideParallelScanMappingProbe.stop_observing
      FileUtils.rm_rf(root)
    end
  end
end
