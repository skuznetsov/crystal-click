# One-part Compact Advanced JSON probe. Build with `--release` for wall-time
# measurements. Define `-Dcompact_json_scan_diagnostic` in an isolated source
# copy modified by instrument_compact_json_probe.py to collect counters separately.
require "set"

module CrystalClick
  module CompactJSONScanProbeCounters
    @@full_window_prepare_passes = 0_u64
    @@full_window_prepare_ns = 0_u64
    @@read_window_calls = 0_u64
    @@full_grid_window_reads = 0_u64
    @@source_read_calls = 0_u64
    @@source_range_count = 0_u64
    @@source_nonempty_ranges = 0_u64
    @@source_logical_bytes = 0_u64
    @@checksum_check_calls = 0_u64
    @@unique_checked_frames = Set(Int64).new
    @@checksum_bytes_hashed = 0_u64
    @@checksum_ns = 0_u64
    @@source_recheck_calls = 0_u64
    @@source_recheck_ns = 0_u64
    @@source_rechecked_frames = 0_u64
    @@decompression_calls = 0_u64
    @@decompression_payload_bytes = 0_u64
    @@decompressed_bytes = 0_u64
    @@decompression_ns = 0_u64
    @@decompression_methods = Hash(String, UInt64).new(0_u64)

    def self.reset! : Nil
      @@full_window_prepare_passes = 0_u64
      @@full_window_prepare_ns = 0_u64
      @@read_window_calls = 0_u64
      @@full_grid_window_reads = 0_u64
      @@source_read_calls = 0_u64
      @@source_range_count = 0_u64
      @@source_nonempty_ranges = 0_u64
      @@source_logical_bytes = 0_u64
      @@checksum_check_calls = 0_u64
      @@unique_checked_frames.clear
      @@checksum_bytes_hashed = 0_u64
      @@checksum_ns = 0_u64
      @@source_recheck_calls = 0_u64
      @@source_recheck_ns = 0_u64
      @@source_rechecked_frames = 0_u64
      @@decompression_calls = 0_u64
      @@decompression_payload_bytes = 0_u64
      @@decompressed_bytes = 0_u64
      @@decompression_ns = 0_u64
      @@decompression_methods.clear
    end

    def self.record_full_window_prepare!(elapsed_ns : UInt64) : Nil
      @@full_window_prepare_passes += 1_u64
      @@full_window_prepare_ns += elapsed_ns
    end

    def self.record_read_window!(first_mark : Int, mark_count : Int, total_marks : Int) : Nil
      @@read_window_calls += 1_u64
      @@full_grid_window_reads += 1_u64 if first_mark == 0 && mark_count == total_marks
    end

    def self.record_source_read!(ranges : Array({Int64, Int64})) : Nil
      @@source_read_calls += 1_u64
      @@source_range_count += ranges.size.to_u64
      ranges.each do |start, finish|
        next if finish == start
        @@source_nonempty_ranges += 1_u64
        @@source_logical_bytes += (finish - start).to_u64
      end
    end

    def self.record_checked_frame!(offset : Int64, compressed_size : Int64, elapsed_ns : UInt64) : Nil
      @@checksum_check_calls += 1_u64
      @@unique_checked_frames.add(offset)
      @@checksum_bytes_hashed += compressed_size.to_u64
      @@checksum_ns += elapsed_ns
    end

    def self.record_source_recheck!(frame_count : Int, elapsed_ns : UInt64) : Nil
      @@source_recheck_calls += 1_u64
      @@source_recheck_ns += elapsed_ns
      @@source_rechecked_frames += frame_count.to_u64
    end

    def self.record_decompression!(method : UInt8, payload_size : Int64, output_size : Int64, elapsed_ns : UInt64) : Nil
      @@decompression_calls += 1_u64
      @@decompression_payload_bytes += payload_size.to_u64
      @@decompressed_bytes += output_size.to_u64
      @@decompression_ns += elapsed_ns
      name = case method
             when 0x82_u8 then "LZ4"
             when 0x90_u8 then "ZSTD"
             when 0x91_u8 then "MULTIPLE"
             else              "0x#{method.to_s(16)}"
             end
      @@decompression_methods[name] = @@decompression_methods[name] + 1_u64
    end

    def self.snapshot
      {
        full_window_prepare_passes:  @@full_window_prepare_passes,
        full_window_prepare_ns:      @@full_window_prepare_ns,
        read_window_calls:           @@read_window_calls,
        full_grid_window_reads:      @@full_grid_window_reads,
        source_read_calls:           @@source_read_calls,
        source_range_count:          @@source_range_count,
        source_nonempty_ranges:      @@source_nonempty_ranges,
        source_logical_bytes:        @@source_logical_bytes,
        checksum_check_calls:        @@checksum_check_calls,
        unique_checked_frames:       @@unique_checked_frames.size.to_u64,
        checksum_bytes_hashed:       @@checksum_bytes_hashed,
        checksum_ns:                 @@checksum_ns,
        source_recheck_calls:        @@source_recheck_calls,
        source_recheck_ns:           @@source_recheck_ns,
        source_rechecked_frames:     @@source_rechecked_frames,
        decompression_calls:         @@decompression_calls,
        decompression_payload_bytes: @@decompression_payload_bytes,
        decompressed_bytes:          @@decompressed_bytes,
        decompression_ns:            @@decompression_ns,
        decompression_methods:       @@decompression_methods.dup,
      }
    end
  end
end

require "../src/crystal_click"
require "digest/sha256"
require "json"

module CompactJSONScanProbe
  struct Job
    getter run_id : Int32
    getter marks : Array(Int32)
    getter shared_plan : CrystalClick::CompactStaticJsonAdvancedPartPlan?

    def initialize(@run_id : Int32, @marks : Array(Int32), @shared_plan : CrystalClick::CompactStaticJsonAdvancedPartPlan?)
    end
  end

  # Callback batches borrow their carrier slices, so the detached track keeps
  # copied ids and the owned ObjectDocument references instead of retaining the
  # callback wrapper beyond its lifetime.
  struct DetachedMarkBatch
    getter mark : Int32
    getter ids : Array(UInt64)
    getter documents : Array(CrystalClick::ObjectDocument)

    def initialize(@mark : Int32, @ids : Array(UInt64), @documents : Array(CrystalClick::ObjectDocument))
    end
  end

  struct WorkerResult
    getter run_id : Int32
    getter worker : Int32
    getter marks : Array(Int32)
    getter rows : Int32
    getter first_id : UInt64?
    getter last_id : UInt64?
    getter payload : Bytes?
    getter retained_mark_batches : Array(DetachedMarkBatch)?
    getter thread_id : UInt64
    getter worker_scan_ns : Int64
    getter serialization_ns : Int64

    def initialize(
      @run_id : Int32,
      @worker : Int32,
      @marks : Array(Int32),
      @rows : Int32,
      @first_id : UInt64?,
      @last_id : UInt64?,
      @payload : Bytes?,
      @retained_mark_batches : Array(DetachedMarkBatch)?,
      @thread_id : UInt64,
      @worker_scan_ns : Int64,
      @serialization_ns : Int64,
    )
    end
  end

  ROWS_PER_MARK = 2048
  MARK_INDICES  = [0, 1, 2, 3]

  def self.error(message : String) : NoReturn
    STDERR.puts message
    exit(2)
  end

  def self.uint32_value(value : CrystalClick::BinaryValue) : UInt32
    unless value.type.tag == CrystalClick::BinaryDataType::TAG_UINT32 && value.byte_size == 4
      raise CrystalClick::UnsupportedFormatError.new("probe expected UInt32 JSON leaf")
    end
    result = 0_u32
    4.times { |index| result |= value.byte_at(index).to_u32 << (index * 8) }
    result
  end

  def self.write_json_value(io : IO, value : CrystalClick::BinaryValue) : Nil
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
      write_json_value(io, value.child_at(0))
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      write_json_value(io, value.child_at(0))
    else
      raise CrystalClick::UnsupportedFormatError.new("probe cannot serialize JSON leaf #{value.type.name}")
    end
    nil
  end

  def self.document_json(document : CrystalClick::ObjectDocument) : String
    io = IO::Memory.new
    io << '{'
    document.path_count.times do |index|
      io << ',' if index > 0
      path = document.path_at(index)
      JSON::Any.new(path).to_json(io)
      io << ':'
      write_json_value(io, document.value_for(path))
    end
    io << '}'
    io.to_s
  end

  def self.write_varuint(io : IO, value : UInt64) : Nil
    remaining = value
    while remaining >= 0x80_u64
      io.write_byte((remaining & 0x7f_u64).to_u8 | 0x80_u8)
      remaining >>= 7
    end
    io.write_byte(remaining.to_u8)
  end

  def self.write_json_rowbinary(io : IO, id : UInt64, document : CrystalClick::ObjectDocument) : Nil
    io.write_bytes(id, IO::ByteFormat::LittleEndian)
    json = document_json(document)
    write_varuint(io, json.bytesize.to_u64)
    io << json
  end

  def self.open_table(backend : String, part_path : String) : CrystalClick::CompactPartTable | CrystalClick::TypedPartTable
    case backend
    when "compact", "shared"
      CrystalClick::CompactPartTable.open_selected_typed([part_path], ["id", "doc"])
    when "typed"
      CrystalClick::TypedPartTable.open_selected_typed([part_path], ["id", "doc"])
    else
      error("backend must be compact, typed, or shared")
    end
  end

  def self.scan_marks(
    table : CrystalClick::CompactPartTable | CrystalClick::TypedPartTable,
    job : Job,
    & : CrystalClick::WidePartTableBatch -> Nil
  ) : Nil
    if plan = job.shared_plan
      table.as(CrystalClick::CompactPartTable).scan_shared_advanced_json_mark_indices(job.marks, ROWS_PER_MARK, plan, guard_delivery: false) do |batch|
        yield batch
      end
    else
      table.scan_typed_candidate_marks([job.marks]) { |batch| yield batch }
    end
    nil
  end

  def self.scan_payload(table : CrystalClick::CompactPartTable | CrystalClick::TypedPartTable, job : Job) : NamedTuple(
    rows: Int32,
    first_id: UInt64?,
    last_id: UInt64?,
    payload: Bytes,
    worker_scan_ns: Int64,
    serialization_ns: Int64,
  )
    io = IO::Memory.new
    rows = 0
    first_id = nil.as(UInt64?)
    last_id = nil.as(UInt64?)
    serialization_ns = 0_i64
    worker_started = Time.instant
    scan_marks(table, job) do |batch|
      serialization_started = Time.instant
      ids = batch.values_for("id", UInt64)
      documents = batch.object_documents_for("doc")
      raise CrystalClick::CorruptPartError.new("probe id/doc row counts differ") unless ids.size == documents.size
      ids.size.times do |index|
        id = ids[index]
        first_id ||= id
        last_id = id
        write_json_rowbinary(io, id, documents[index])
        rows += 1
      end
      serialization_ns += (Time.instant - serialization_started).total_nanoseconds.to_i64
    end
    elapsed_ns = (Time.instant - worker_started).total_nanoseconds.to_i64
    {rows: rows, first_id: first_id, last_id: last_id, payload: io.to_slice, worker_scan_ns: elapsed_ns - serialization_ns, serialization_ns: serialization_ns}
  end

  def self.scan_retained(table : CrystalClick::CompactPartTable | CrystalClick::TypedPartTable, job : Job) : NamedTuple(
    rows: Int32,
    first_id: UInt64?,
    last_id: UInt64?,
    retained_mark_batches: Array(DetachedMarkBatch),
    worker_scan_ns: Int64,
  )
    retained = [] of DetachedMarkBatch
    rows = 0
    first_id = nil.as(UInt64?)
    last_id = nil.as(UInt64?)
    worker_started = Time.instant
    scan_marks(table, job) do |batch|
      ids = batch.values_for("id", UInt64).to_a
      documents = batch.object_documents_for("doc").to_a
      raise CrystalClick::CorruptPartError.new("probe id/doc row counts differ") unless ids.size == documents.size
      ids.each do |id|
        first_id ||= id
        last_id = id
      end
      rows += ids.size
      retained << DetachedMarkBatch.new(batch.mark_index, ids, documents)
    end
    worker_scan_ns = (Time.instant - worker_started).total_nanoseconds.to_i64
    {rows: rows, first_id: first_id, last_id: last_id, retained_mark_batches: retained, worker_scan_ns: worker_scan_ns}
  end

  def self.serialize_retained(batches : Array(DetachedMarkBatch)) : Tuple(Bytes, Int32)
    io = IO::Memory.new
    rows = 0
    batches.each do |batch|
      raise CrystalClick::CorruptPartError.new("retained id/doc row counts differ") unless batch.ids.size == batch.documents.size
      batch.ids.each_with_index do |id, index|
        write_json_rowbinary(io, id, batch.documents[index])
        rows += 1
      end
    end
    {io.to_slice, rows}
  end

  def self.varuint(bytes : Bytes, pos : Int32) : Tuple(UInt64, Int32)
    value = 0_u64
    shift = 0
    loop do
      raise CrystalClick::CorruptPartError.new("truncated probe RowBinary String length") if pos >= bytes.size
      byte = bytes[pos]
      pos += 1
      payload = byte & 0x7f
      if shift == 63 && (payload > 1 || byte >= 0x80)
        raise CrystalClick::CorruptPartError.new("invalid probe RowBinary VarUInt")
      end
      value |= payload.to_u64 << shift
      return {value, pos} if byte < 0x80
      shift += 7
      raise CrystalClick::CorruptPartError.new("invalid probe RowBinary VarUInt") if shift > 63
    end
  end

  def self.prefix_bytes(bytes : Bytes, row_count : Int32) : Int32
    pos = 0
    row_count.times do
      raise CrystalClick::CorruptPartError.new("truncated probe RowBinary UInt64") if pos > bytes.size - 8
      pos += 8
      size, pos = varuint(bytes, pos)
      raise CrystalClick::CorruptPartError.new("truncated probe RowBinary JSON String") if size > (bytes.size - pos).to_u64
      pos += size.to_i
    end
    pos
  end

  def self.marks_for(mode : String) : Array(Int32)
    case mode
    when "none"  then [] of Int32
    when "first" then [0]
    when "all"   then MARK_INDICES.dup
    else
      error("mark mode must be none, first, or all; got #{mode.inspect}")
    end
  end

  def self.assignments(marks : Array(Int32), workers : Int32) : Array(Array(Int32)?)
    result = Array(Array(Int32)?).new(workers, nil)
    if marks.empty?
      result[0] = [] of Int32
    elsif workers == 1
      result[0] = marks.dup
    else
      marks.each_with_index do |mark, index|
        result[index % workers] = [mark]
      end
    end
    result
  end

  def self.run(backend : String, part_path : String, oracle_path : String, workers : Int32, mode : String, track : String, warmups : Int32, repeats : Int32, interactive : Bool) : Nil
    unless workers == 1 || workers == 4
      error("worker count must be 1 or 4")
    end
    error("backend must be compact, typed, or shared") unless backend.in?("compact", "typed", "shared")
    error("track must be callback or retained") unless track == "callback" || track == "retained"
    error("warmups and repeats must be nonnegative and repeats positive") if warmups < 0 || repeats <= 0
    error("use 0 warmups when the caller sends scan commands") if interactive && warmups != 0
    {% if flag?(:compact_json_scan_diagnostic) %}
      error("the diagnostic probe requires one worker") unless workers == 1
    {% end %}
    marks = marks_for(mode)
    assignments = assignments(marks, workers)
    oracle = File.read(oracle_path).to_slice
    expected_rows = marks.size * ROWS_PER_MARK
    expected_size = prefix_bytes(oracle, expected_rows)
    expected = oracle[0, expected_size]

    jobs = Array(Channel(Job)).new(workers) { Channel(Job).new }
    results = Channel(WorkerResult).new(workers)
    errors = Channel(Exception).new(workers)
    ready = Channel(NamedTuple(worker: Int32, open_ns: Int64, thread_id: UInt64)).new(workers)
    contexts = Array(Fiber::ExecutionContext::Isolated).new(workers)
    begin
      prepare_started = Time.instant
      shared_table = if backend == "shared"
                       owner = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["id", "doc"])
                       owner.parallel_scan_transport_budget! if workers > 1
                       owner
                     end
      workers.times do |worker|
        worker_index = worker
        contexts << Fiber::ExecutionContext::Isolated.new("compact-json-worker-#{worker_index}") do
          begin
            open_started = Time.instant
            table = shared_table || open_table(backend, part_path)
            open_ns = (Time.instant - open_started).total_nanoseconds.to_i64
            ready.send({worker: worker_index, open_ns: open_ns, thread_id: Thread.current.object_id.to_u64})
            loop do
              job = jobs[worker_index].receive?
              break unless job
              if track == "callback"
                outcome = scan_payload(table, job)
                results.send(WorkerResult.new(
                  job.run_id,
                  worker_index,
                  job.marks,
                  outcome[:rows],
                  outcome[:first_id],
                  outcome[:last_id],
                  outcome[:payload],
                  nil,
                  Thread.current.object_id.to_u64,
                  outcome[:worker_scan_ns],
                  outcome[:serialization_ns],
                ))
              else
                outcome = scan_retained(table, job)
                results.send(WorkerResult.new(
                  job.run_id,
                  worker_index,
                  job.marks,
                  outcome[:rows],
                  outcome[:first_id],
                  outcome[:last_id],
                  nil,
                  outcome[:retained_mark_batches],
                  Thread.current.object_id.to_u64,
                  outcome[:worker_scan_ns],
                  0_i64,
                ))
              end
            end
          rescue exception
            errors.send(exception)
          end
        end
      end

      ready_records = Array(NamedTuple(worker: Int32, open_ns: Int64, thread_id: UInt64)).new(workers)
      workers.times do
        select
        when record = ready.receive
          ready_records << record
        when exception = errors.receive
          raise exception
        end
      end
      prepare_wall_ns = (Time.instant - prepare_started).total_nanoseconds.to_i64
      ready_records.sort_by!(&.[:worker])

      if interactive
        puts "READY"
        STDOUT.flush
      end
      run_index = 0
      loop do
        if interactive
          command = STDIN.gets
          break if command.nil? || command == "quit"
          error("stdin command must be scan or quit") unless command == "scan"
        else
          break if run_index >= warmups + repeats
        end
        run_id = run_index
        run_index += 1
        {% if flag?(:compact_json_scan_diagnostic) %}
          CrystalClick::CompactJSONScanProbeCounters.reset!
        {% end %}
        gc_total_bytes_before = GC.stats.total_bytes
        gc_collections_before = GC.prof_stats.gc_no
        started = Time.instant
        shared_plan = shared_table.try do |owner|
          owner.prepare_shared_advanced_json_scan ||
            raise(CrystalClick::UnsupportedFormatError.new("probe requires an admitted Advanced JSON part plan"))
        end
        shared_plan_ns = (Time.instant - started).total_nanoseconds.to_i64 if shared_plan
        active_count = 0
        assignments.each_with_index do |worker_marks, worker|
          if selected = worker_marks
            jobs[worker].send(Job.new(run_id, selected, shared_plan))
            active_count += 1
          end
        end
        completed = Array(WorkerResult).new(active_count)
        while completed.size < active_count
          select
          when result = results.receive
            completed << result
          when exception = errors.receive
            raise exception
          end
        end
        # The coordinator owns the release of retained rows, as in the public
        # parallel scan. This probe has exactly one batch per selected mark.
        if plan = shared_plan
          marks.each { plan.validate_source! }
        end
        read_wall_ns = (Time.instant - started).total_nanoseconds.to_i64
        completed.sort_by! do |result|
          result.marks.first? || Int32::MAX
        end
        total_rows = 0
        coordinator_serialization_ns = 0_i64
        actual = if track == "callback"
                   merged = IO::Memory.new
                   completed.each do |result|
                     merged.write(result.payload || raise(CrystalClick::CorruptPartError.new("callback worker result lost its payload")))
                     total_rows += result.rows
                   end
                   merged.to_slice
                 else
                   retained = [] of DetachedMarkBatch
                   completed.each do |result|
                     retained.concat(result.retained_mark_batches || [] of DetachedMarkBatch)
                   end
                   retained.sort_by!(&.mark)
                   serialization_started = Time.instant
                   payload, total_rows = serialize_retained(retained)
                   coordinator_serialization_ns = (Time.instant - serialization_started).total_nanoseconds.to_i64
                   payload
                 end
        elapsed_ns = (Time.instant - started).total_nanoseconds.to_i64
        gc_collections_after = GC.prof_stats.gc_no
        gc_total_bytes_after = GC.stats.total_bytes
        unless actual == expected
          raise CrystalClick::CorruptPartError.new("RowBinary output differs from ClickHouse oracle (got #{actual.size}, expected #{expected.size})")
        end
        {% if flag?(:compact_json_scan_diagnostic) %}
          unless CrystalClick::CompactJSONScanProbeCounters.snapshot[:full_window_prepare_passes] > 0
            error("no root JSON preparation recorded; apply the diagnostic hooks to the isolated source copy")
          end
        {% end %}
        next if run_id < warmups

        worker_rows = completed.map do |result|
          {
            worker:           result.worker,
            marks:            result.marks,
            rows:             result.rows,
            first_id:         result.first_id,
            last_id:          result.last_id,
            thread_id:        result.thread_id,
            worker_scan_ns:   result.worker_scan_ns,
            serialization_ns: result.serialization_ns,
          }
        end
        worker_scan_ns_sum = completed.sum(&.worker_scan_ns)
        worker_serialization_ns_sum = completed.sum(&.serialization_ns)
        puts({
          mode:                         mode,
          track:                        track,
          run:                          run_id - warmups,
          part:                         part_path,
          workers_requested:            workers,
          backend:                      backend,
          workers_active:               active_count,
          worker_opens:                 ready_records,
          prepare_wall_ns:              prepare_wall_ns,
          shared_part_plan_ns:          shared_plan_ns,
          shared_part_plan_marks:       shared_plan.try(&.prepared_mark_count),
          selected_marks:               marks,
          worker_rows:                  worker_rows,
          rows:                         total_rows,
          read_wall_ns:                 track == "retained" ? read_wall_ns : nil,
          coordinator_serialization_ns: coordinator_serialization_ns,
          scan_and_serialize_ns:        elapsed_ns,
          gc_total_bytes_before:        gc_total_bytes_before,
          gc_total_bytes_after:         gc_total_bytes_after,
          gc_allocated_bytes_delta:     gc_total_bytes_after - gc_total_bytes_before,
          gc_collections:               gc_collections_after - gc_collections_before,
          worker_scan_ns_sum:           worker_scan_ns_sum,
          worker_serialization_ns_sum:  worker_serialization_ns_sum,
          rowbinary_bytes:              actual.size,
          rowbinary_sha256:             Digest::SHA256.hexdigest(actual),
          oracle_exact:                 true,
          diagnostics:                  {% if flag?(:compact_json_scan_diagnostic) %}CrystalClick::CompactJSONScanProbeCounters.snapshot{% else %}nil{% end %},
        }.to_json)
        STDOUT.flush if interactive
      end
    ensure
      jobs.each(&.close)
      contexts.each(&.wait)
    end
  end
end

interactive = ARGV.last? == "--stdin"
ARGV.pop if interactive
unless ARGV.size == 8
  STDERR.puts "usage: compact_json_scan_probe <backend:compact|typed|shared> <part-dir> <full-part-rowbinary-oracle> <workers:1|4> <mode:none|first|all> <track:callback|retained> <warmups> <repeats> [--stdin]"
  exit(2)
end

CompactJSONScanProbe.run(
  ARGV[0],
  ARGV[1],
  ARGV[2],
  ARGV[3].to_i,
  ARGV[4],
  ARGV[5],
  ARGV[6].to_i,
  ARGV[7].to_i,
  interactive,
)
