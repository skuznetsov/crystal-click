require "./spec_helper"

WIDE_SHARED_METADATA_FIXTURE = File.expand_path("../test/fixtures/public/wide_two_uint64/part", __DIR__)

module CrystalClick::WideParallelMetadataAdmissionProbe
  alias Event = {Symbol, String}

  class_property enabled = false
  class_property watched_parts = Set(String).new
  class_property events = [] of Event
  class_property lock = Thread::Mutex.new

  def self.begin_observing(paths : Array(String)) : Nil
    watched = paths.map { |path| File.expand_path(path) }.to_set
    lock.synchronize do
      self.watched_parts = watched
      self.events = [] of Event
      self.enabled = true
    end
  end

  def self.stop_observing : Nil
    lock.synchronize { self.enabled = false }
  end

  def self.record(kind : Symbol, path : String) : Nil
    expanded = File.expand_path(path)
    lock.synchronize do
      watched = watched_parts.includes?(expanded) || watched_parts.includes?(File.dirname(expanded))
      events << {kind, expanded} if enabled && watched
    end
    nil
  end

  def self.record_global(kind : Symbol) : Nil
    lock.synchronize { events << {kind, ""} if enabled }
    nil
  end

  def self.snapshot : Array(Event)
    lock.synchronize { events.dup }
  end
end

class CrystalClick::WidePart::PartMetadataTextParser
  def self.parse_columns(text : String) : Array({String, String})
    result = previous_def(text)
    WideParallelMetadataAdmissionProbe.record_global(:columns_parse)
    result
  end

  def self.parse_columns_substreams(
    text : String,
    columns : Array({String, String}),
    enforce_total_substream_limit : Bool = true,
  ) : Array({String, Array(String)})
    result = previous_def(text, columns, enforce_total_substream_limit)
    WideParallelMetadataAdmissionProbe.record_global(:shared_roster_parse)
    result
  end
end

class CrystalClick::WidePart
  private def parse_substreams(
    columns : Array({String, String}),
    selected_column : String,
    selected_type : String,
    source_column : String = selected_column,
    json_paths : Array({String, String}) = [] of {String, String},
  ) : Array(String)
    result = previous_def(columns, selected_column, selected_type, source_column, json_paths)
    WideParallelMetadataAdmissionProbe.record(:legacy_roster_parse, @path)
    result
  end

  private def parse_marks(
    file : String,
    data_size : Int64,
    compressed : Bool,
    element_width : Int32,
    allow_empty_string_eof : Bool,
    mark_row_width : Int32,
    max_records : Int? = nil,
    required_first_mark_decompressed_offset : UInt64? = 0_u64,
    alignment_width : Int32? = nil,
    canonical_bytes : Bytes? = nil,
  ) : {Array(Mark), Mark}
    result = previous_def(
      file,
      data_size,
      compressed,
      element_width,
      allow_empty_string_eof,
      mark_row_width,
      max_records,
      required_first_mark_decompressed_offset,
      alignment_width,
      canonical_bytes,
    )
    WideParallelMetadataAdmissionProbe.record(:mark_parse, file)
    result
  end
end

describe "Wide parallel metadata admission" do
  it "admits each selected stream once per part and shares the admitted Wide reader with workers" do
    root = File.tempname("crystal-click-wide-parallel-admission-")
    Dir.mkdir(root)
    begin
      part_paths = [
        File.join(root, "all_1_1_0"),
        File.join(root, "all_2_2_0"),
      ]
      FileUtils.cp_r(WIDE_SHARED_METADATA_FIXTURE, part_paths[0])
      keys = Array(UInt64).new(17_001) { |index| 50_000_u64 + index.to_u64 }
      values = Array(UInt64).new(17_001) { |index| 90_000_u64 + index.to_u64 }
      CrystalClick::WidePartWriter.write_uint64_pair(
        part_paths[1],
        "left",
        keys.to_unsafe.to_slice(keys.size),
        "right",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 8_192,
      )

      CrystalClick::WideParallelMetadataAdmissionProbe.begin_observing(part_paths)
      table = CrystalClick::TypedPartTable.open_selected_typed(part_paths, ["left", "right"])
      admission = CrystalClick::WideParallelMetadataAdmissionProbe.snapshot
      CrystalClick::WideParallelMetadataAdmissionProbe.stop_observing

      admission.count { |event| event[0] == :columns_parse }.should eq(part_paths.size)
      admission.count { |event| event[0] == :shared_roster_parse }.should eq(part_paths.size)
      part_paths.each do |path|
        events = admission.select { |event| event[1] == File.expand_path(path) }
        events.count { |event| event[0] == :legacy_roster_parse }.should eq(0)
        expected_mark_paths = Dir.glob(File.join(path, "*.mrk2")).map { |mark_path| File.expand_path(mark_path) }.to_set
        expected_mark_paths.size.should eq(2)
        mark_events = admission.select { |event| event[0] == :mark_parse && expected_mark_paths.includes?(event[1]) }
        mark_events.size.should eq(2)
        mark_events.map(&.[1]).to_set.should eq(expected_mark_paths)
      end

      baseline = [] of {Int32, String, Int32, UInt64, UInt64, Array(UInt64), Array(UInt64)}
      CrystalClick::WideParallelMetadataAdmissionProbe.begin_observing(part_paths)
      observed = [] of {Int32, String, Int32, UInt64, UInt64, Array(UInt64), Array(UInt64)}
      table.scan_typed_parallel(workers: 1, batch_rows: 1) do |batch|
        observed << {
          batch.part_index,
          batch.part_path,
          batch.mark_index,
          batch.part_row_offset,
          batch.source_row_offset,
          batch.values_for("left", UInt64).to_a,
          batch.values_for("right", UInt64).to_a,
        }
      end
      baseline = observed.dup
      scan_events = CrystalClick::WideParallelMetadataAdmissionProbe.snapshot
      CrystalClick::WideParallelMetadataAdmissionProbe.stop_observing
      scan_events.select { |event| event[0] == :legacy_roster_parse }.should be_empty
      scan_events.select { |event| event[0] == :shared_roster_parse }.should be_empty
      scan_events.select { |event| event[0] == :columns_parse }.should be_empty
      scan_events.select { |event| event[0] == :mark_parse }.should be_empty
      observed.size.should eq(2 * 17_001)
      observed.each_with_index do |row, index|
        part_index = index < 17_001 ? 0 : 1
        part_row = (index % 17_001).to_u64
        row[0].should eq(part_index.to_i32)
        row[1].should eq(part_paths[part_index])
        row[2].should eq((part_row // 8_192).to_i32)
        row[3].should eq(part_row)
        row[4].should eq(index.to_u64)
        if part_index == 0
          row[5].should eq([part_row])
          row[6].should eq([part_row * 3_u64 + 7_u64])
        else
          row[5].should eq([keys[part_row.to_i32]])
          row[6].should eq([values[part_row.to_i32]])
        end
      end

      {% if flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
        expect_raises(CrystalClick::UnsupportedFormatError, /execution context/) do
          table.scan_typed_parallel(workers: 4, batch_rows: 1) { |_batch| }
        end
      {% else %}
        CrystalClick::WideParallelMetadataAdmissionProbe.begin_observing(part_paths)
        observed = [] of {Int32, String, Int32, UInt64, UInt64, Array(UInt64), Array(UInt64)}
        table.scan_typed_parallel(workers: 4, batch_rows: 1) do |batch|
          observed << {
            batch.part_index,
            batch.part_path,
            batch.mark_index,
            batch.part_row_offset,
            batch.source_row_offset,
            batch.values_for("left", UInt64).to_a,
            batch.values_for("right", UInt64).to_a,
          }
        end
        scan_events = CrystalClick::WideParallelMetadataAdmissionProbe.snapshot
        CrystalClick::WideParallelMetadataAdmissionProbe.stop_observing
        scan_events.select { |event| event[0] == :legacy_roster_parse }.should be_empty
        scan_events.select { |event| event[0] == :shared_roster_parse }.should be_empty
        scan_events.select { |event| event[0] == :columns_parse }.should be_empty
        scan_events.select { |event| event[0] == :mark_parse }.should be_empty
        observed.should eq(baseline)
      {% end %}
    ensure
      CrystalClick::WideParallelMetadataAdmissionProbe.stop_observing
      FileUtils.rm_rf(root)
    end
  end

  it "rejects duplicate physical streams across shared roster columns" do
    root = File.tempname("crystal-click-wide-shared-roster-duplicate-")
    Dir.mkdir(root)
    part = File.join(root, "all_1_1_0")
    begin
      FileUtils.cp_r(WIDE_SHARED_METADATA_FIXTURE, part)
      roster_path = File.join(part, "columns_substreams.txt")
      roster = File.read(roster_path)
      roster.should contain("\tright\n")
      File.write(roster_path, roster.gsub("\tright\n", "\tleft\n"))
      expect_raises(CrystalClick::UnsupportedFormatError, /duplicate physical stream name/) do
        CrystalClick::WidePartTable.open_selected_typed([part], ["left", "right"])
      end
    ensure
      CrystalClick::WideParallelMetadataAdmissionProbe.stop_observing
      FileUtils.rm_rf(root)
    end
  end

  it "rejects a row count with two trailing line feeds" do
    root = File.tempname("crystal-click-wide-shared-count-terminator-")
    Dir.mkdir(root)
    part = File.join(root, "all_1_1_0")
    begin
      FileUtils.cp_r(WIDE_SHARED_METADATA_FIXTURE, part)
      count_path = File.join(part, "count.txt")
      File.write(count_path, File.read(count_path) + "\n\n")
      expect_raises(CrystalClick::UnsupportedFormatError, /invalid count in count.txt/) do
        CrystalClick::WidePartTable.open_selected_typed([part], ["left", "right"])
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects non-regular columns metadata before reading it" do
    root = File.tempname("crystal-click-wide-shared-columns-file-type-")
    Dir.mkdir(root)
    part = File.join(root, "all_1_1_0")
    begin
      FileUtils.cp_r(WIDE_SHARED_METADATA_FIXTURE, part)
      columns_path = File.join(part, "columns.txt")
      File.delete(columns_path)
      Dir.mkdir(columns_path)
      expect_raises(CrystalClick::CorruptPartError, /not a regular file/) do
        CrystalClick::WidePartTable.open_selected_typed([part], ["left", "right"])
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "shares admission for selected mixed primitive types and preserves their values" do
    root = File.tempname("crystal-click-wide-shared-mixed-primitive-")
    Dir.mkdir(root)
    part_path = File.join(root, "all_1_1_0")
    begin
      FileUtils.cp_r(File.expand_path("../test/fixtures/public/wide_numeric_mixed/part", __DIR__), part_path)
      selected = ["u8", "i16", "f32"]
      expected_mark_paths = selected.map do |column|
        File.expand_path(CrystalClick::WidePart.open_numeric(part_path, column).mark_path)
      end.to_set

      CrystalClick::WideParallelMetadataAdmissionProbe.begin_observing([part_path])
      table = CrystalClick::TypedPartTable.open_selected_typed([part_path], selected)
      admission = CrystalClick::WideParallelMetadataAdmissionProbe.snapshot
      CrystalClick::WideParallelMetadataAdmissionProbe.stop_observing

      admission.count { |event| event[0] == :columns_parse }.should eq(1)
      admission.count { |event| event[0] == :shared_roster_parse }.should eq(1)
      mark_events = admission.select { |event| event[0] == :mark_parse && expected_mark_paths.includes?(event[1]) }
      mark_events.size.should eq(selected.size)
      mark_events.map(&.[1]).to_set.should eq(expected_mark_paths)

      observed = [] of {Int32, UInt64, Array(UInt8), Array(Int16), Array(UInt32)}
      table.scan_typed_parallel(workers: 1, batch_rows: 3) do |batch|
        observed << {
          batch.part_index,
          batch.part_row_offset,
          batch.values_for("u8", UInt8).to_a,
          batch.values_for("i16", Int16).to_a,
          batch.values_for("f32", Float32).map(&.unsafe_as(UInt32)).to_a,
        }
      end
      observed.flat_map(&.[2]).should eq([0_u8, 127_u8, 255_u8, 1_u8])
      observed.flat_map(&.[3]).should eq([-32768_i16, -1_i16, 0_i16, 32767_i16])
      observed.flat_map(&.[4]).should eq([0_u32, 0x80000000_u32, 0x3fc00000_u32, 0xc0100000_u32])

      {% if flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
        expect_raises(CrystalClick::UnsupportedFormatError, /execution context/) do
          table.scan_typed_parallel(workers: 4) { |_batch| }
        end
      {% else %}
        parallel = [] of {Int32, UInt64, Array(UInt8), Array(Int16), Array(UInt32)}
        table.scan_typed_parallel(workers: 4, batch_rows: 3) do |batch|
          parallel << {
            batch.part_index,
            batch.part_row_offset,
            batch.values_for("u8", UInt8).to_a,
            batch.values_for("i16", Int16).to_a,
            batch.values_for("f32", Float32).map(&.unsafe_as(UInt32)).to_a,
          }
        end
        parallel.should eq(observed)
      {% end %}
    ensure
      CrystalClick::WideParallelMetadataAdmissionProbe.stop_observing
      FileUtils.rm_rf(root)
    end
  end
end
