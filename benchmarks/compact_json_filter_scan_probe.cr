# Matched mark-only and row-masked Compact Advanced JSON read probe. Build this
# with --release; the optional frame hook exists only in an isolated diagnostic
# source copy created by instrument_compact_json_probe.py --lz4-only.
require "json"
require "digest/sha256"
require "../src/crystal_click"
require "../scripts/support/compact_physical_context_w259_fixture"

module CrystalClick
  module CompactJSONScanProbeCounters
    @@mutex = Mutex.new
    @@lz4_frames = 0_u64
    @@lz4_payload_bytes = 0_u64
    @@lz4_output_bytes = 0_u64
    @@lz4_elapsed_ns = 0_u64

    def self.reset! : Nil
      @@mutex.synchronize do
        @@lz4_frames = 0_u64
        @@lz4_payload_bytes = 0_u64
        @@lz4_output_bytes = 0_u64
        @@lz4_elapsed_ns = 0_u64
      end
      nil
    end

    # Called by the isolated diagnostic hook after a complete decompression.
    def self.record_decompression!(method : UInt8, payload_size : Int64, output_size : Int64, elapsed_ns : UInt64) : Nil
      return nil unless method == CompressedBlock::METHOD_LZ4
      if payload_size < 0 || output_size < 0
        raise CorruptPartError.new("LZ4 diagnostic observed a negative byte count")
      end
      @@mutex.synchronize do
        @@lz4_frames += 1_u64
        @@lz4_payload_bytes += payload_size.to_u64
        @@lz4_output_bytes += output_size.to_u64
        @@lz4_elapsed_ns += elapsed_ns
      end
      nil
    end

    def self.snapshot : Hash(String, UInt64)
      @@mutex.synchronize do
        {
          "total_lz4_frames"        => @@lz4_frames,
          "total_lz4_payload_bytes" => @@lz4_payload_bytes,
          "total_lz4_output_bytes"  => @@lz4_output_bytes,
          "total_lz4_elapsed_ns"    => @@lz4_elapsed_ns,
        }
      end
    end
  end
end

module CompactJsonFilterScanProbe
  extend self

  ROWS_PER_MARK = 2048
  MARKS         = [0_i32, 1_i32, 2_i32, 3_i32]

  class CompletedMark
    getter mark : Int32
    getter batch : CrystalClick::CompactJsonColumnarBatch

    def initialize(@mark : Int32, @batch : CrystalClick::CompactJsonColumnarBatch)
    end
  end

  class SelectedMark
    getter mark : Int32
    getter batch : CrystalClick::CompactJsonColumnarBatch
    getter rows : Slice(Int32)
    getter packed : Bool

    # Eager predicate evaluation owns this array. Filtered-route slices are
    # backed by their receipt, which remains live until the sample is serialized.
    @rows_owner : Array(Int32)?

    def initialize(@mark : Int32, @batch : CrystalClick::CompactJsonColumnarBatch,
                   @rows : Slice(Int32), @rows_owner : Array(Int32)? = nil,
                   @packed : Bool = false)
    end
  end

  class ScanJob
    getter scan_id : Int32
    getter route : String
    getter plan : CrystalClick::CompactStaticJsonAdvancedPartPlan
    getter marks : Array(Int32)
    getter output_limit : UInt64
    getter part_row_offsets : Array(UInt64)
    getter filtered_plan : CrystalClick::CompactFilteredJsonPartPlan?

    def initialize(@scan_id : Int32, @route : String, @plan : CrystalClick::CompactStaticJsonAdvancedPartPlan,
                   @marks : Array(Int32), @output_limit : UInt64,
                   @part_row_offsets : Array(UInt64),
                   @filtered_plan : CrystalClick::CompactFilteredJsonPartPlan? = nil)
    end
  end

  class WorkerResult
    getter scan_id : Int32
    getter worker : Int32
    getter thread_id : UInt64
    getter completed : Array(CompletedMark)

    def initialize(@scan_id : Int32, @worker : Int32, @thread_id : UInt64,
                   @completed : Array(CompletedMark))
    end
  end

  private def predicate_matches?(predicate : String, value : UInt64) : Bool
    case predicate
    when "zero"    then false
    when "cluster" then value >= 2048_u64 && value < 4096_u64
    when "spread"  then value % 4_u64 == 0_u64
    when "all"     then true
    else                raise ArgumentError.new("unknown predicate #{predicate.inspect}")
    end
  end

  private def write_varuint(io : IO, original : UInt64) : Nil
    value = original
    while value >= 0x80_u64
      io.write_byte(((value & 0x7f_u64) | 0x80_u64).to_u8)
      value >>= 7
    end
    io.write_byte(value.to_u8)
  end

  private def uint32_value(value : CrystalClick::BinaryValue) : UInt32
    unless value.type.tag == CrystalClick::BinaryDataType::TAG_UINT32 && value.byte_size == 4
      raise CrystalClick::UnsupportedFormatError.new("probe expected UInt32 JSON leaf")
    end
    result = 0_u32
    4.times { |index| result |= value.byte_at(index).to_u32 << (index * 8) }
    result
  end

  private def write_binary_value(io : IO, value : CrystalClick::BinaryValue) : Nil
    return io << "null" if value.is_null?

    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_UINT32
      io << uint32_value(value).to_s
    when CrystalClick::BinaryDataType::TAG_UINT64
      io << value.as_uint64.to_s
    when CrystalClick::BinaryDataType::TAG_INT64
      io << value.as_int64.to_s
    when CrystalClick::BinaryDataType::TAG_STRING
      JSON::Any.new(value.as_string).to_json(io)
    when CrystalClick::BinaryDataType::TAG_BOOL
      io << (value.as_bool ? "true" : "false")
    when CrystalClick::BinaryDataType::TAG_NULLABLE
      write_binary_value(io, value.child_at(0))
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      write_binary_value(io, value.child_at(0))
    else
      raise CrystalClick::UnsupportedFormatError.new("probe cannot serialize JSON leaf #{value.type.name}")
    end
    nil
  end

  private def write_json_cell(io : IO, cell : CrystalClick::CompactJsonColumnarCell) : Nil
    if bytes = cell.borrowed_string_bytes?
      JSON.build(io) { |json| json.string { |escaped| escaped.write(bytes) } }
    else
      write_binary_value(io, cell.materialize)
    end
    nil
  end

  private def serialize_selected(selected : Array(SelectedMark)) : Bytes
    output = IO::Memory.new
    json = IO::Memory.new
    selected.sort_by!(&.mark)
    selected.each do |mark_result|
      batch = mark_result.batch
      ids = batch.uint64_column("id")
      mark_result.rows.each_with_index do |source_row, dense_row|
        row = mark_result.packed ? dense_row : source_row
        unless row >= 0 && row < batch.row_count
          raise CrystalClick::CorruptPartError.new("probe filtered row index is outside its decoded mark")
        end
        json.clear
        json << '{'
        emitted = false
        batch.column_count.times do |index|
          column = batch.column_at(index)
          if column.nullable_uint32_lane_active?
            values = column.nullable_uint32_values
            nulls = column.nullable_uint32_nulls
            unless values.size == batch.row_count && nulls.size == batch.row_count
              raise CrystalClick::CorruptPartError.new("probe Nullable(UInt32) lane row count differs")
            end
            json << ',' if emitted
            column.path.to_json(json)
            json << ':'
            case nulls[row]
            when 0_u8 then json << values[row].to_s
            when 1_u8 then json << "null"
            else           raise CrystalClick::CorruptPartError.new("probe Nullable(UInt32) null map is malformed")
            end
            emitted = true
          else
            column.with_cell_at(row) do |cell|
              json << ',' if emitted
              column.path.to_json(json)
              json << ':'
              write_json_cell(json, cell)
              emitted = true
            end
          end
        end
        json << '}'
        output.write_bytes(ids[row], IO::ByteFormat::LittleEndian)
        write_varuint(output, json.size.to_u64)
        output.write(json.to_slice)
      end
    end
    output.to_slice
  end

  private def verify_selected_source_offsets!(selected : Array(SelectedMark)) : String
    encoded = IO::Memory.new
    selected.sort_by!(&.mark)
    selected.each do |mark_result|
      batch = mark_result.batch
      ids = batch.uint64_column("id")
      mark_result.rows.each_with_index do |source_row, dense_row|
        unless source_row >= 0 && source_row < ROWS_PER_MARK
          raise CrystalClick::CorruptPartError.new("probe source row offset is outside its physical mark")
        end
        row = mark_result.packed ? dense_row : source_row
        unless row < ids.size && batch.part_row_offset <= UInt64::MAX - source_row.to_u64
          raise CrystalClick::CorruptPartError.new("probe selected output row cannot be mapped to its part offset")
        end
        expected_id = batch.part_row_offset + source_row.to_u64
        unless ids[row] == expected_id
          raise CrystalClick::CorruptPartError.new("probe packed output id differs from its original source offset")
        end
        encoded.write_bytes(mark_result.mark.to_u32, IO::ByteFormat::LittleEndian)
        encoded.write_bytes(expected_id, IO::ByteFormat::LittleEndian)
      end
    end
    Digest::SHA256.hexdigest(encoded.to_slice)
  end

  private def expected_source_rows(predicate_name : String, mark : Int32) : Array(Int32)
    start = mark.to_u64 * ROWS_PER_MARK.to_u64
    rows = [] of Int32
    ROWS_PER_MARK.times do |row|
      rows << row.to_i32 if predicate_matches?(predicate_name, start + row.to_u64)
    end
    rows
  end

  private def validate_probe_batches!(route : String, predicate_name : String,
                                      completed : Array(CompletedMark), selected : Array(SelectedMark)) : Nil
    expected_marks = [] of Int32
    expected_rows_by_mark = Hash(Int32, Array(Int32)).new
    MARKS.each do |mark|
      rows = expected_source_rows(predicate_name, mark)
      expected_rows_by_mark[mark] = rows
      expected_marks << mark if !rows.empty? || route == "eager"
    end
    actual_marks = completed.map(&.mark)
    unless actual_marks == expected_marks
      raise CrystalClick::CorruptPartError.new("probe JSON mark list differs from the predicate's source offsets")
    end

    selected_by_mark = Hash(Int32, SelectedMark).new
    selected.each { |entry| selected_by_mark[entry.mark] = entry }
    expected_selected_marks = MARKS.select { |mark| !expected_rows_by_mark[mark].empty? }
    unless selected.map(&.mark) == expected_selected_marks
      raise CrystalClick::CorruptPartError.new("probe selected marks differ from the predicate's source offsets")
    end

    completed.each do |entry|
      expected_rows = expected_rows_by_mark[entry.mark]
      expected_batch_rows = route == "masked" ? expected_rows.size : ROWS_PER_MARK
      unless entry.batch.row_count == expected_batch_rows
        raise CrystalClick::CorruptPartError.new("probe decoded row count differs from the route's mark mask")
      end
      if !expected_rows.empty?
        selected_entry = selected_by_mark[entry.mark]?
        unless selected_entry && selected_entry.rows.to_a == expected_rows && selected_entry.packed == (route == "masked")
          raise CrystalClick::CorruptPartError.new("probe selected source offsets differ from the predicate mask")
        end
      end
    end
    nil
  end

  private def mark_offsets(owner : CrystalClick::CompactPartTable) : Array(UInt64)
    offsets = [] of UInt64
    cursor = 0_u64
    owner.part_mark_row_counts[0].each do |rows|
      offsets << cursor
      if rows > UInt64::MAX - cursor
        raise CrystalClick::CorruptPartError.new("probe part mark offset overflows")
      end
      cursor += rows
    end
    offsets
  end

  private def assignments(marks : Array(Int32), workers : Int32) : Array(Array(Int32))
    result = Array(Array(Int32)).new(workers) { [] of Int32 }
    marks.each_with_index { |mark, index| result[index % workers] << mark }
    result
  end

  private def run_scan(
    owner : CrystalClick::CompactPartTable,
    jobs : Array(Channel(ScanJob)),
    results : Channel(WorkerResult),
    errors : Channel(Exception),
    scan_id : Int32,
    workers : Int32,
    route : String,
    predicate_name : String,
    filtered_oracle : Bytes,
    full_oracle_sha256 : String,
    filtered_oracle_sha256 : String,
    offsets : Array(UInt64),
    worker_thread_ids : Array(UInt64),
  ) : Hash(String, JSON::Any)
    filter_evaluations = 0_i64
    predicate : Proc(UInt64, Bool) = ->(value : UInt64) do
      filter_evaluations += 1_i64
      predicate_matches?(predicate_name, value)
    end

    {% if flag?(:compact_json_scan_diagnostic) %}
      CrystalClick::CompactJSONScanProbeCounters.reset!
    {% end %}
    gc_bytes_before = GC.stats.total_bytes
    gc_collections_before = GC.prof_stats.gc_no
    combined_started = Time.instant
    read_started = combined_started

    eager_plan = nil.as(CrystalClick::CompactStaticJsonAdvancedPartPlan?)
    filtered_plan = nil.as(CrystalClick::CompactFilteredJsonPartPlan?)
    json_plan = nil.as(CrystalClick::CompactStaticJsonAdvancedPartPlan?)
    marks = [] of Int32
    if route == "eager"
      plan = owner.prepare_shared_advanced_json_scan ||
             raise(CrystalClick::UnsupportedFormatError.new("probe requires an admitted Advanced JSON plan"))
      plan.prepare_columnar_output!
      eager_plan = plan
      json_plan = plan
      marks = MARKS.dup
    else
      filtered = owner.prepare_filtered_advanced_json_scan("id", predicate)
      filtered_plan = filtered
      marks = filtered.mark_indices
      json_plan = filtered.json_plan
      if plan = json_plan
        plan.prepare_columnar_output!
      else
        filtered.validate_source!
      end
    end
    active_workers = Math.min(workers, marks.size.to_i32)
    completed = [] of CompletedMark
    active_results = [] of WorkerResult
    if plan = json_plan
      unless active_workers > 0
        raise CrystalClick::CorruptPartError.new("eager JSON route unexpectedly selected no marks") if route == "eager"
      else
        assignments(marks, workers).each_with_index do |worker_marks, worker|
          next if worker_marks.empty?
          output_workspace_limit = CrystalClick::WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
          retained = if filtered = filtered_plan
                       filtered.retained_workspace_bytes
                     else
                       plan.retained_workspace_bytes
                     end
          if retained >= output_workspace_limit
            raise CrystalClick::BoundsError.new("probe plan leaves no workspace for output")
          end
          per_worker_limit = retained + (output_workspace_limit - retained) // active_workers.to_u64
          jobs[worker].send(ScanJob.new(scan_id, route, plan, worker_marks, per_worker_limit,
            offsets, filtered_plan))
        end
        received = 0
        while received < active_workers
          select
          when result = results.receive
            unless result.scan_id == scan_id
              raise CrystalClick::CorruptPartError.new("probe received a stale mark batch")
            end
            active_results << result
            completed.concat(result.completed)
            received += 1
          when exception = errors.receive
            raise exception
          end
        end
      end
    end
    expected_assignments = assignments(marks, workers)
    expected_worker_indices = [] of Int32
    expected_assignments.each_with_index do |worker_marks, index|
      expected_worker_indices << index.to_i32 unless worker_marks.empty?
    end
    actual_worker_indices = active_results.map(&.worker).sort
    unless actual_worker_indices == expected_worker_indices
      raise CrystalClick::CorruptPartError.new("probe active worker assignments differ from the ordered mark schedule")
    end
    active_results.each do |result|
      unless result.worker >= 0 && result.worker < worker_thread_ids.size &&
             result.thread_id == worker_thread_ids[result.worker]
        raise CrystalClick::CorruptPartError.new("probe worker execution context changed after its retained startup")
      end
      expected_marks = expected_assignments[result.worker]
      actual_marks = result.completed.map(&.mark)
      unless actual_marks == expected_marks
        raise CrystalClick::CorruptPartError.new("probe worker completed a different mark assignment")
      end
    end
    completed.sort_by!(&.mark)

    selected = [] of SelectedMark
    if route == "eager"
      plan = eager_plan || raise(CrystalClick::CorruptPartError.new("eager plan disappeared"))
      completed.each do |entry|
        # Source authentication immediately precedes delivery to the shared
        # post-JSON predicate loop, which is the eager counterpart of the
        # filter receipt's pre-JSON predicate loop.
        plan.validate_source!
        ids = entry.batch.uint64_column("id")
        matching = [] of Int32
        ids.each_with_index do |value, row|
          if predicate.call(value)
            matching << row.to_i32
          end
        end
        unless matching.empty?
          rows = Slice(Int32).new(matching.to_unsafe, matching.size, read_only: true)
          selected << SelectedMark.new(entry.mark, entry.batch, rows, matching)
        end
      end
    else
      filtered = filtered_plan || raise(CrystalClick::CorruptPartError.new("filtered route receipt disappeared"))
      completed.each do |entry|
        # Complete source authentication immediately precedes each selected
        # JSON mark's ordered delivery to the row collector.
        filtered.validate_source!
        rows = filtered.row_indices_for(entry.mark)
        selected << SelectedMark.new(entry.mark, entry.batch, rows, nil, route == "masked")
      end
    end

    if route == "eager" && filter_evaluations != 8192_i64
      raise CrystalClick::CorruptPartError.new("eager predicate did not visit every source row exactly once")
    elsif route != "eager" && filter_evaluations != 8192_i64
      raise CrystalClick::CorruptPartError.new("filtered predicate did not visit every source row exactly once")
    end
    json_mark_decode_invocations = completed.size.to_i32
    read_wall_ns = (Time.instant - read_started).total_nanoseconds.to_i64
    gc_bytes_after_read = GC.stats.total_bytes
    gc_collections_after_read = GC.prof_stats.gc_no

    serialization_started = Time.instant
    actual = serialize_selected(selected)
    serialization_ns = (Time.instant - serialization_started).total_nanoseconds.to_i64
    scan_and_serialize_ns = (Time.instant - combined_started).total_nanoseconds.to_i64

    validate_probe_batches!(route, predicate_name, completed, selected)
    selected_source_offsets_sha256 = verify_selected_source_offsets!(selected)
    unless actual == filtered_oracle
      raise CrystalClick::CorruptPartError.new("filtered RowBinary output differs from the independent oracle")
    end
    output_sha256 = Digest::SHA256.hexdigest(actual)
    expected_rows = case predicate_name
                    when "zero" then 0
                    when "all"  then 8192
                    else             2048
                    end
    actual_rows = selected.sum(0_i64) { |entry| entry.rows.size.to_i64 }
    unless actual_rows == expected_rows
      raise CrystalClick::CorruptPartError.new("filtered RowBinary row count differs from the independent oracle")
    end

    diagnostics = nil.as(Hash(String, UInt64)?)
    {% if flag?(:compact_json_scan_diagnostic) %}
      diagnostics = CrystalClick::CompactJSONScanProbeCounters.snapshot
    {% end %}
    diagnostics_json = JSON::Any.new(nil)
    if counters = diagnostics
      json_counters = Hash(String, JSON::Any).new
      counters.each { |name, value| json_counters[name] = JSON::Any.new(value.to_i64) }
      diagnostics_json = JSON::Any.new(json_counters)
    end
    worker_assignment_json = active_results.sort_by(&.worker).map do |result|
      JSON::Any.new({
        "worker"    => JSON::Any.new(result.worker),
        "thread_id" => JSON::Any.new(result.thread_id.to_i64),
        "marks"     => JSON::Any.new(result.completed.map { |entry| JSON::Any.new(entry.mark.to_i64) }),
      })
    end
    {
      "route"                      => JSON::Any.new(route),
      "predicate"                  => JSON::Any.new(predicate_name),
      "workers_requested"          => JSON::Any.new(workers),
      "workers_retained"           => JSON::Any.new(workers),
      "workers_active"             => JSON::Any.new(active_workers),
      "worker_thread_ids_retained" => JSON::Any.new(worker_thread_ids.map { |thread_id| JSON::Any.new(thread_id.to_i64) }),
      "worker_assignments"         => JSON::Any.new(worker_assignment_json),
      "json_mark_indices"          => JSON::Any.new(
        (route == "eager" ? MARKS : marks).map { |mark| JSON::Any.new(mark.to_i64) },
      ),
      "filter_evaluations"             => JSON::Any.new(filter_evaluations),
      "json_plan_present"              => JSON::Any.new(!json_plan.nil?),
      "json_mark_decode_invocations"   => JSON::Any.new(json_mark_decode_invocations),
      "json_mark_row_counts"           => JSON::Any.new(completed.map { |entry| JSON::Any.new(entry.batch.row_count) }),
      "selected_source_offset_count"   => JSON::Any.new(selected.sum(0_i64) { |entry| entry.rows.size.to_i64 }),
      "selected_source_offsets_sha256" => JSON::Any.new(selected_source_offsets_sha256),
      "source_offsets_verified"        => JSON::Any.new(true),
      "read_wall_ns"                   => JSON::Any.new(read_wall_ns),
      "serialization_ns"               => JSON::Any.new(serialization_ns),
      "scan_and_serialize_ns"          => JSON::Any.new(scan_and_serialize_ns),
      "rows"                           => JSON::Any.new(actual_rows),
      "rowbinary_bytes"                => JSON::Any.new(actual.size),
      "oracle_exact"                   => JSON::Any.new(true),
      "rowbinary_sha256"               => JSON::Any.new(output_sha256),
      "full_oracle_sha256"             => JSON::Any.new(full_oracle_sha256),
      "filtered_oracle_sha256"         => JSON::Any.new(filtered_oracle_sha256),
      "gc_read_allocated_bytes_delta"  => JSON::Any.new(gc_bytes_after_read - gc_bytes_before),
      "gc_read_collections"            => JSON::Any.new(gc_collections_after_read - gc_collections_before),
      "diagnostics"                    => diagnostics_json,
    }
  end

  private def write_u32_le(bytes : Bytes, offset : Int, value : UInt32) : Nil
    4.times { |index| bytes[offset + index] = ((value >> (8 * index)) & 0xff_u32).to_u8 }
  end

  private def write_u64_le(bytes : Bytes, offset : Int, value : UInt64) : Nil
    8.times { |index| bytes[offset + index] = ((value >> (8 * index)) & 0xff_u64).to_u8 }
  end

  private def read_u32_le(bytes : Bytes, offset : Int) : UInt32
    value = 0_u32
    4.times { |index| value |= bytes[offset + index].to_u32 << (8 * index) }
    value
  end

  private def find_subslice(haystack : Bytes, needle : Bytes) : Int32?
    return 0_i32 if needle.empty?
    return nil if needle.size > haystack.size
    limit = haystack.size - needle.size
    0.upto(limit) do |offset|
      matches = true
      needle.size.times do |index|
        if haystack[offset + index] != needle[index]
          matches = false
          break
        end
      end
      return offset.to_i32 if matches
    end
    nil
  end

  # Locate the compressed literal byte that supplies a decoded output byte.
  # LZ4 match copies inherit the source literal mapping, so changing one byte
  # preserves the original compressed frame size and every saved coordinate.
  private def lz4_payload_byte_for_output(payload : Bytes, output_size : Int32, target : Int32) : Int32
    unless target >= 0 && target < output_size
      raise CrystalClick::CorruptPartError.new("Copy/Data control target is outside its LZ4 frame")
    end
    sources = Array(Int32).new(output_size, -1_i32)
    input = 0
    output = 0
    while input < payload.size
      token = payload[input]
      input += 1
      literal_length = (token >> 4).to_i
      if literal_length == 15
        loop do
          raise CrystalClick::CorruptPartError.new("truncated LZ4 literal length in Copy/Data control") if input >= payload.size
          length_byte = payload[input]
          input += 1
          literal_length += length_byte.to_i
          break if length_byte < 255_u8
        end
      end
      if literal_length > payload.size - input || literal_length > output_size - output
        raise CrystalClick::CorruptPartError.new("LZ4 literal extent is invalid in Copy/Data control")
      end
      literal_length.times do |index|
        sources[output + index] = (input + index).to_i32
      end
      if target >= output && target < output + literal_length
        return (input + target - output).to_i32
      end
      input += literal_length
      output += literal_length
      break if input == payload.size

      if input > payload.size - 2
        raise CrystalClick::CorruptPartError.new("truncated LZ4 match offset in Copy/Data control")
      end
      distance = payload[input].to_i | (payload[input + 1].to_i << 8)
      input += 2
      if distance == 0 || distance > output
        raise CrystalClick::CorruptPartError.new("invalid LZ4 match distance in Copy/Data control")
      end
      match_length = (token & 0x0f).to_i
      if match_length == 15
        loop do
          raise CrystalClick::CorruptPartError.new("truncated LZ4 match length in Copy/Data control") if input >= payload.size
          length_byte = payload[input]
          input += 1
          match_length += length_byte.to_i
          break if length_byte < 255_u8
        end
      end
      match_length += 4
      if match_length > output_size - output
        raise CrystalClick::CorruptPartError.new("LZ4 match extent is invalid in Copy/Data control")
      end
      match_length.times do |index|
        sources[output + index] = sources[output + index - distance]
      end
      if target >= output && target < output + match_length
        source = sources[target]
        raise CrystalClick::CorruptPartError.new("LZ4 Copy/Data target has no literal source") if source < 0
        return source
      end
      output += match_length
    end
    raise CrystalClick::CorruptPartError.new("Copy/Data control could not map the target through LZ4")
  end

  private def mutate_copy_data!(part_path : String) : Nil
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    window = physical.read_window("doc", 1, 1).granules.first? ||
             raise CrystalClick::CorruptPartError.new("Copy/Data control selected mark is absent")
    copy = window.shards.find { |shard| shard.stream_name == "doc.object_shared_data.copy.values" } ||
           raise CrystalClick::CorruptPartError.new("Copy/Data control has no doc Copy values lane")
    # overflow_0 and overflow_1 are promoted Dynamic slots in this native
    # fixture. overflow_2 remains in the root Copy lane selected by the guard.
    needle = "spill-2-".to_slice
    prefix = find_subslice(copy.bytes, needle) ||
             raise CrystalClick::CorruptPartError.new("Copy/Data control Copy values do not contain the overflow string")
    suffix_index = prefix + needle.size
    if suffix_index > copy.bytes.size - 2 || copy.bytes[suffix_index] < '0'.ord.to_u8 || copy.bytes[suffix_index] > '9'.ord.to_u8 ||
       copy.bytes[suffix_index + 1] < '0'.ord.to_u8 || copy.bytes[suffix_index + 1] > '9'.ord.to_u8
      raise CrystalClick::CorruptPartError.new("Copy/Data control found an invalid overflow string suffix")
    end
    logical_offset = copy.logical_start + suffix_index.to_i64 + 1_i64

    data_path = File.join(part_path, "data.bin")
    data = File.read(data_path).to_slice.dup
    expected_replacement = 0_u8
    compressed_offset = 0_i64
    logical_base = 0_i64
    changed = false
    while compressed_offset < data.size
      frame = CrystalClick::CompressedBlock.decode_frame(data, compressed_offset)
      logical_limit = logical_base + frame.output.size.to_i64
      if logical_offset >= logical_base && logical_offset < logical_limit
        header = compressed_offset.to_i + CrystalClick::CompressedBlock::CHECKSUM_SIZE
        method = data[header]
        unless method == CrystalClick::CompressedBlock::METHOD_LZ4
          raise CrystalClick::UnsupportedFormatError.new("Copy/Data control requires an LZ4 frame")
        end
        compressed_size = read_u32_le(data, header + 1).to_i
        payload_start = compressed_offset.to_i + CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
        payload_size = compressed_size - CrystalClick::CompressedBlock::HEADER_SIZE
        payload = data[payload_start, payload_size]
        output_offset = (logical_offset - logical_base).to_i32
        payload_offset = lz4_payload_byte_for_output(payload, frame.output.size.to_i32, output_offset)
        original_byte = frame.output[output_offset]
        expected_replacement = original_byte == '9'.ord.to_u8 ? '8'.ord.to_u8 : original_byte + 1_u8
        data[payload_start + payload_offset] = expected_replacement
        checksum = CrystalClick::CityHashV1.hash128(
          data[compressed_offset.to_i + CrystalClick::CompressedBlock::CHECKSUM_SIZE, compressed_size],
        )
        write_u64_le(data, compressed_offset.to_i, checksum[0])
        write_u64_le(data, compressed_offset.to_i + 8, checksum[1])
        rewritten = CrystalClick::CompressedBlock.decode_frame(data, compressed_offset)
        unless rewritten.output[output_offset] == expected_replacement
          raise CrystalClick::CorruptPartError.new("Copy/Data control did not preserve valid LZ4 framing")
        end
        changed = true
        break
      end
      logical_base = logical_limit
      compressed_offset = frame.end_offset
    end
    raise CrystalClick::CorruptPartError.new("Copy/Data control target was outside data.bin") unless changed

    File.write(data_path, data)
    CompactPhysicalContextW259Fixture.refresh_checksums(part_path)
    reopened = CrystalClick::CompactPartPhysicalContext.open(part_path)
    verified = reopened.read_window("doc", 1, 1).granules.first? ||
               raise CrystalClick::CorruptPartError.new("Copy/Data control could not reopen selected mark")
    verified_copy = verified.shards.find { |shard| shard.stream_name == "doc.object_shared_data.copy.values" } ||
                    raise CrystalClick::CorruptPartError.new("Copy/Data control lost Copy values after reframe")
    unless verified_copy.bytes[suffix_index + 1] == expected_replacement
      raise CrystalClick::CorruptPartError.new("Copy/Data control failed to authenticate its rewritten Copy shard")
    end
    nil
  end

  private def run_copy_data_control(part_path : String, workers : Int32, route : String) : Nil
    unless workers == 1 || workers == 4
      raise ArgumentError.new("worker count must be 1 or 4")
    end
    unless route.in?("mark_only", "masked")
      raise ArgumentError.new("Copy/Data control route must be mark_only or masked")
    end
    mutate_copy_data!(part_path)
    table = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["id", "doc"])
    table.parallel_scan_transport_budget! if workers > 1
    callbacks = 0_i32
    error = nil.as(String?)
    begin
      predicate = ->(value : UInt64) { value >= 2048_u64 && value < 4096_u64 && value % 4_u64 == 0_u64 }
      if route == "masked"
        table.scan_compact_json_filtered_rows("id", predicate, workers: workers) do |_batch, _rows|
          callbacks += 1
        end
      else
        table.scan_compact_json_filtered("id", predicate, workers: workers) do |_batch, _rows|
          callbacks += 1
        end
      end
    rescue exception : CrystalClick::CorruptPartError
      error = exception.message
    end
    unless message = error
      raise CrystalClick::CorruptPartError.new("Copy/Data control scan did not reject the validly framed mismatch")
    end
    unless message == "Object shared Copy value disagrees with its per-path Dynamic row" && callbacks == 0
      raise CrystalClick::CorruptPartError.new("Copy/Data control observed an unexpected rejection: #{message}")
    end
    puts({"control" => "copy_data", "route" => route, "predicate" => "cluster_spread",
          "workers_requested" => workers, "rejected" => true,
          "callbacks" => callbacks, "error" => message}.to_json)
  end

  private def start_workers(owner : CrystalClick::CompactPartTable, workers : Int32) : Tuple(
    Array(Channel(ScanJob)), Channel(WorkerResult), Channel(Exception),
    Array(Fiber::ExecutionContext::Isolated), Array(UInt64),
  )
    jobs = Array(Channel(ScanJob)).new(workers) { Channel(ScanJob).new }
    results = Channel(WorkerResult).new(workers)
    errors = Channel(Exception).new(workers)
    ready = Channel(NamedTuple(worker: Int32, thread_id: UInt64)).new(workers)
    contexts = Array(Fiber::ExecutionContext::Isolated).new(workers)
    worker_thread_ids = Array(UInt64).new(workers, 0_u64)
    workers.times do |worker|
      worker_index = worker.to_i32
      contexts << Fiber::ExecutionContext::Isolated.new("compact-json-filter-worker-#{worker_index}") do
        ready.send({worker: worker_index, thread_id: Thread.current.object_id.to_u64})
        output_arenas = Hash(Tuple(String, Int32), CrystalClick::CompactJsonColumnarBatch).new
        loop do
          job = jobs[worker_index].receive?
          break unless job
          begin
            budget = job.plan.new_decode_budget
            job.plan.prepare_decode_budget!(budget)
            completed = [] of CompletedMark
            job.marks.each do |mark|
              arena_key = {job.route, mark}
              batch = output_arenas[arena_key]? || begin
                created = job.plan.new_columnar_output(job.output_limit)
                output_arenas[arena_key] = created
                created
              end
              batch.reset!
              part_row_offset = if filtered = job.filtered_plan
                                  filtered.part_row_offset_for(mark)
                                else
                                  job.part_row_offsets[mark]
                                end
              if job.route == "masked"
                filtered = job.filtered_plan ||
                           raise(CrystalClick::CorruptPartError.new("masked job lost its filter receipt"))
                matching_rows = filtered.row_indices_for(mark)
                owner.scan_compact_json_columnar_mark_into(
                  mark,
                  job.plan,
                  budget,
                  batch,
                  part_row_offset: part_row_offset,
                  matching_rows: matching_rows,
                )
              else
                owner.scan_compact_json_columnar_mark_into(
                  mark,
                  job.plan,
                  budget,
                  batch,
                  part_row_offset: part_row_offset,
                )
              end
              completed << CompletedMark.new(mark, batch)
            end
            results.send(WorkerResult.new(job.scan_id, worker_index, Thread.current.object_id.to_u64, completed))
          rescue exception
            errors.send(exception)
          end
        end
      end
    end
    workers.times do
      record = ready.receive
      worker_thread_ids[record[:worker]] = record[:thread_id]
    end
    {jobs, results, errors, contexts, worker_thread_ids}
  end

  private def read_binary(path : String) : Bytes
    File.read(path).to_slice
  end

  private def run_interactive(part_path : String, oracle_path : String, filtered_path : String,
                              workers : Int32, predicate_name : String) : Nil
    unless workers == 1 || workers == 4
      raise ArgumentError.new("worker count must be 1 or 4")
    end
    unless predicate_name.in?("zero", "cluster", "spread", "all")
      raise ArgumentError.new("predicate must be zero, cluster, spread, or all")
    end
    oracle = read_binary(oracle_path)
    filtered_oracle = read_binary(filtered_path)
    full_oracle_sha256 = Digest::SHA256.hexdigest(oracle)
    unless full_oracle_sha256 == "3495978197741a4e241a2201bd92030afbb7590588bccb2ab3da107b1059d62b"
      raise CrystalClick::CorruptPartError.new("full ordered RowBinary oracle differs from its pinned native export")
    end
    filtered_oracle_sha256 = Digest::SHA256.hexdigest(filtered_oracle)
    owner = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["id", "doc"])
    owner.parallel_scan_transport_budget! if workers > 1
    offsets = mark_offsets(owner)
    jobs, results, errors, contexts, worker_thread_ids = start_workers(owner, workers)
    begin
      puts "READY"
      STDOUT.flush
      scan_id = 0_i32
      while command = STDIN.gets
        normalized = command.strip
        break if normalized == "quit"
        parts = normalized.split
        unless parts.size == 2 && parts[0] == "scan" && parts[1].in?("eager", "lazy", "mark_only", "masked")
          raise ArgumentError.new("stdin command must be 'scan eager', 'scan mark_only', 'scan masked', or 'quit'")
        end
        route = parts[1] == "lazy" ? "mark_only" : parts[1]
        sample = run_scan(owner, jobs, results, errors, scan_id, workers, route, predicate_name,
          filtered_oracle, full_oracle_sha256, filtered_oracle_sha256, offsets, worker_thread_ids)
        puts sample.to_json
        STDOUT.flush
        scan_id += 1
      end
    ensure
      jobs.each(&.close)
      contexts.each(&.wait)
    end
    nil
  end

  def main : Nil
    if ARGV.first? == "--copy-data-control"
      unless ARGV.size == 4
        STDERR.puts "usage: compact_json_filter_scan_probe --copy-data-control <part-dir> <workers:1|4> <mark_only|masked>"
        exit(2)
      end
      run_copy_data_control(ARGV[1], ARGV[2].to_i32, ARGV[3])
      return nil
    end

    interactive = ARGV.last? == "--stdin"
    ARGV.pop if interactive
    unless interactive && ARGV.size == 5
      STDERR.puts "usage: compact_json_filter_scan_probe <part-dir> <full-rowbinary-oracle> <filtered-rowbinary-oracle> <workers:1|4> <predicate:zero|cluster|spread|all> --stdin"
      exit(2)
    end
    run_interactive(ARGV[0], ARGV[1], ARGV[2], ARGV[3].to_i32, ARGV[4])
  end
end

CompactJsonFilterScanProbe.main
