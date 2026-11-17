require "json"
require "../src/crystal_click"
require "../src/crystal_click/read_rows_profile"
require "./read_rows_scan_worker_state"
require "./read_rows_scan_worker_pool"

# Direct native-part scan used by scripts/read_rows_benchmark.py. The process
# admits one immutable part and oracle, retaining Wide readers and mappings
# across requests while Compact keeps its existing fresh-reader scan path.
module CrystalClickReadRowsScan
  extend self

  struct Config
    getter part : String
    getter layout : String
    getter marks : Array(Int32)
    getter mark_rows : Int32
    getter workers : Int32
    getter oracle : String
    getter work_dir : String

    def initialize(
      @part : String,
      @layout : String,
      @marks : Array(Int32),
      @mark_rows : Int32,
      @workers : Int32,
      @oracle : String,
      @work_dir : String,
    )
    end
  end

  COLUMNS = ["pk", "value"]

  def run(args : Array(String)) : Nil
    ready = false
    retained_wide_image = nil.as(CrystalClick::WideScanImage?)
    retained_wide_workers = nil.as(WorkerPool?)
    retained_wide_worker_job = nil.as(WorkerJob?)
    primary_error = nil.as(Exception?)
    begin
      config = parse_config(args)
      validate_work_dir!(config.work_dir)
      validate_little_endian!
      admission_started = Time.instant
      retained_wide_readers = admit_part!(config)
      admission_ns = if retained_wide_readers
                       elapsed_ns(admission_started)
                     else
                       nil
                     end
      mmap_prepare_ns = nil.as(Int64?)
      if readers = retained_wide_readers
        mmap_prepare_started = Time.instant
        retained_wide_image = open_wide_scan_image(readers)
        mmap_prepare_ns = elapsed_ns(mmap_prepare_started)
      end
      oracle = read_oracle(config)
      row_count = selected_row_count(config)
      keys = Array(UInt64).new(row_count, 0_u64)
      values = Array(UInt64).new(row_count, 0_u64)
      worker_marks = partition_marks(config.marks, config.workers)
      worker_starts = Array(Int32).new(config.workers) do |index|
        (config.marks.size * index // config.workers).to_i32
      end
      worker_prepare_ns = nil.as(Int64?)
      if readers = retained_wide_readers
        image = retained_wide_image || raise(CrystalClick::CorruptPartError.new("Wide scan image was not retained"))
        worker_prepare_started = Time.instant
        retained_wide_workers = WorkerPool.new(config.workers, config.mark_rows)
        retained_wide_worker_job = new_wide_worker_job(
          config, readers, image, worker_marks, worker_starts, keys, values,
        )
        worker_prepare_ns = elapsed_ns(worker_prepare_started)
      end

      # Wide metadata, mappings, worker contexts, typed scratch and decoder
      # workspace objects are ready before READY. Decoder byte storage grows
      # lazily on each worker's first frame and remains available afterward.
      STDOUT.puts "READY"
      STDOUT.flush
      ready = true

      while line = STDIN.gets
        case line.chomp
        when "scan"
          scan_profile = new_scan_profile(config)
          if retained_wide_readers
            prepare_ns = 0_i64
            scan_started = Time.instant
            run_wide_scan(
              retained_wide_workers || raise(CrystalClick::CorruptPartError.new("Wide scan workers were not retained")),
              retained_wide_worker_job || raise(CrystalClick::CorruptPartError.new("Wide scan worker job was not retained")),
              scan_profile,
              scan_started,
            )
          else
            prepare_started = Time.instant
            prepared = prepare_scan(config)
            prepare_ns = elapsed_ns(prepare_started)
            table, budget, context = prepared.as({CrystalClick::CompactPartTable, CrystalClick::CompressedStreamBudget, CrystalClick::CompactPartPhysicalContext})
            scan_started = Time.instant
            run_compact_scan(
              config,
              table,
              budget,
              context,
              worker_marks,
              worker_starts,
              keys,
              values,
            )
          end
          scan_ns = elapsed_ns(scan_started)

          compare_output!(keys, values, oracle, row_count)
          emit_result(
            scan_ns,
            prepare_ns,
            row_count,
            config.workers,
            worker_marks,
            scan_profile,
            admission_ns,
            mmap_prepare_ns,
            retained_wide_image,
            worker_prepare_ns,
            retained_wide_workers,
          )
          STDOUT.flush
        when "quit"
          break
        else
          raise ArgumentError.new("expected scan or quit command")
        end
      end
    rescue ex
      primary_error = ex
    ensure
      if workers = retained_wide_workers
        retained_wide_workers = nil
        begin
          workers.close
        rescue cleanup_error : Exception
          primary_error = cleanup_failure(primary_error, cleanup_error, "worker shutdown")
        end
      end
      if image = retained_wide_image
        retained_wide_image = nil
        begin
          image.close
        rescue cleanup_error : Exception
          primary_error = cleanup_failure(primary_error, cleanup_error, "mmap cleanup")
        end
      end
    end
    if error = primary_error
      if ready
        if checksum_mismatch?(error) && !error.is_a?(CrystalClick::MMapCleanupError) && !error.is_a?(CleanupFailure)
          STDERR.puts "checksum mismatch"
        else
          STDERR.puts "read_rows_scan: #{error.message || error.class.name}"
        end
        exit(3)
      else
        STDERR.puts "read_rows_scan: #{error.message || error.class.name}"
        exit(64)
      end
    end
    nil
  end

  private def parse_config(args : Array(String)) : Config
    options = Hash(String, String).new
    index = 0
    while index < args.size
      flag = args[index]
      unless {"--part", "--layout", "--marks", "--mark-rows", "--workers", "--oracle", "--work-dir"}.includes?(flag)
        raise ArgumentError.new("unknown option #{flag}")
      end
      raise ArgumentError.new("missing value for #{flag}") if index + 1 >= args.size
      raise ArgumentError.new("duplicate option #{flag}") if options.has_key?(flag)
      options[flag] = args[index + 1]
      index += 2
    end

    required = ["--part", "--layout", "--marks", "--mark-rows", "--workers", "--oracle", "--work-dir"]
    missing = required.reject { |flag| options.has_key?(flag) }
    raise ArgumentError.new("missing options: #{missing.join(", ")}") unless missing.empty?

    layout = options["--layout"]
    raise ArgumentError.new("layout must be wide or compact") unless {"wide", "compact"}.includes?(layout)
    workers = parse_positive_i32(options["--workers"], "workers")
    raise ArgumentError.new("workers must be 1 or 4") unless workers == 1 || workers == 4
    mark_rows = parse_positive_i32(options["--mark-rows"], "mark rows")
    if mark_rows > CrystalClick::WidePartTable::MAX_MARK_ROWS
      raise ArgumentError.new("mark rows exceed the typed scan limit")
    end
    marks = parse_marks(options["--marks"])
    raise ArgumentError.new("selected marks must cover every worker") if marks.size < workers
    selected_rows = marks.size.to_u64 * mark_rows.to_u64
    if selected_rows > CrystalClick::WidePartTable::MAX_TOTAL_ROWS.to_u64 ||
       selected_rows > Int32::MAX.to_u64 // 16_u64
      raise ArgumentError.new("selected rows exceed the in-memory typed scan limit")
    end

    Config.new(
      required_value(options, "--part"),
      layout,
      marks,
      mark_rows,
      workers,
      required_value(options, "--oracle"),
      required_value(options, "--work-dir"),
    )
  end

  private def required_value(options : Hash(String, String), name : String) : String
    value = options[name]
    raise ArgumentError.new("#{name} cannot be empty") if value.empty?
    value
  end

  private def parse_positive_i32(raw : String, name : String) : Int32
    unless raw.matches?(/\A[0-9]+\z/)
      raise ArgumentError.new("#{name} must be a positive integer")
    end
    parsed = raw.to_i32?
    raise ArgumentError.new("#{name} must be a positive Int32") unless parsed && parsed > 0
    parsed
  end

  private def parse_marks(raw : String) : Array(Int32)
    raise ArgumentError.new("marks cannot be empty") if raw.empty?
    marks = [] of Int32
    previous = -1_i32
    raw.split(',').each do |part|
      unless part.matches?(/\A[0-9]+\z/)
        raise ArgumentError.new("marks must be comma-separated non-negative integers")
      end
      mark = part.to_i32?
      raise ArgumentError.new("mark index exceeds Int32") unless mark
      unless mark > previous
        raise ArgumentError.new("marks must be strictly increasing")
      end
      marks << mark
      previous = mark
    end
    marks
  end

  private def validate_work_dir!(path : String) : Nil
    info = File.info?(path, follow_symlinks: false) || raise ArgumentError.new("work directory does not exist")
    raise ArgumentError.new("work directory must not be a symbolic link") if File.symlink?(path)
    raise ArgumentError.new("work directory is not a directory") unless info.type.directory?
    raise ArgumentError.new("work directory must be empty") unless Dir.empty?(path)
    nil
  end

  private def validate_little_endian! : Nil
    {% unless IO::ByteFormat::SystemEndian == IO::ByteFormat::LittleEndian %}
      raise CrystalClick::UnsupportedFormatError.new("direct read_rows scan requires a little-endian host")
    {% end %}
    nil
  end

  private def read_oracle(config : Config) : String
    info = File.info?(config.oracle, follow_symlinks: false) || raise ArgumentError.new("oracle is missing")
    raise ArgumentError.new("oracle must not be a symbolic link") if File.symlink?(config.oracle)
    raise ArgumentError.new("oracle is not a regular file") unless info.type.file?
    expected_size = config.marks.size.to_u64 * config.mark_rows.to_u64 * 16_u64
    raise ArgumentError.new("oracle size differs from the selected rows") unless info.size.to_u64 == expected_size
    File.read(config.oracle)
  rescue ex : IO::Error
    raise ArgumentError.new(ex.message || "cannot read oracle")
  end

  private def admit_part!(config : Config) : {CrystalClick::WidePart, CrystalClick::WidePart}?
    prepared = prepare_scan(config)
    case config.layout
    when "wide"
      pair = prepared.as({CrystalClick::WidePart, CrystalClick::WidePart})
      validate_mark_grid!(
        pair[0].row_count,
        pair[0].mark_row_counts,
        pair[1].row_count,
        pair[1].mark_row_counts,
        config,
      )
      pair
    when "compact"
      table, _budget, _context = prepared.as({CrystalClick::CompactPartTable, CrystalClick::CompressedStreamBudget, CrystalClick::CompactPartPhysicalContext})
      mark_counts = table.part_mark_row_counts
      raise CrystalClick::CorruptPartError.new("Compact reader returned an invalid part mark roster") unless mark_counts.size == 1
      validate_compact_columns!(table)
      validate_mark_grid!(
        table.total_row_count,
        mark_counts[0],
        table.total_row_count,
        mark_counts[0],
        config,
      )
      nil
    else
      raise ArgumentError.new("unsupported layout")
    end
  end

  private def prepare_scan(config : Config) : {CrystalClick::WidePart, CrystalClick::WidePart} |
                                              {CrystalClick::CompactPartTable, CrystalClick::CompressedStreamBudget, CrystalClick::CompactPartPhysicalContext}
    case config.layout
    when "wide"
      readers = CrystalClick::WidePart.open_primitive_numeric_columns(
        config.part,
        COLUMNS,
        verify_data_checksums: true,
      ) || raise(CrystalClick::UnsupportedFormatError.new("Wide direct primitive numeric metadata sharing is unavailable"))
      raise CrystalClick::CorruptPartError.new("Wide reader returned an invalid selected column count") unless readers.size == 2
      key_reader, value_reader = readers
      validate_wide_columns!(key_reader, value_reader)
      {key_reader, value_reader}
    when "compact"
      table = CrystalClick::CompactPartTable.open_selected_typed([config.part], COLUMNS)
      validate_compact_columns!(table)
      budget = table.parallel_scan_transport_budget!
      context = table.parallel_uint64_scan_context ||
                raise(CrystalClick::UnsupportedFormatError.new("Compact direct UInt64 scan context is unavailable"))
      {table, budget, context}
    else
      raise ArgumentError.new("layout must be wide or compact")
    end
  end

  private def validate_wide_columns!(key_reader : CrystalClick::WidePart, value_reader : CrystalClick::WidePart) : Nil
    unless key_reader.column_type == "UInt64" && value_reader.column_type == "UInt64" &&
           key_reader.source_column_name == "pk" && value_reader.source_column_name == "value"
      raise CrystalClick::UnsupportedFormatError.new("Wide part must expose pk,value as exact UInt64 columns")
    end
    nil
  end

  private def validate_compact_columns!(table : CrystalClick::CompactPartTable) : Nil
    types = table.column_types
    unless types == [{"pk", "UInt64"}, {"value", "UInt64"}]
      raise CrystalClick::UnsupportedFormatError.new("Compact part must expose pk,value as exact UInt64 columns in order")
    end
    nil
  end

  private def validate_mark_grid!(
    key_rows : UInt64,
    key_marks : Array(UInt64),
    value_rows : UInt64,
    value_marks : Array(UInt64),
    config : Config,
  ) : Nil
    unless key_rows == value_rows && key_marks == value_marks &&
           key_rows == key_marks.sum && !key_marks.empty?
      raise CrystalClick::CorruptPartError.new("pk and value mark grids differ")
    end
    unless key_marks.all? { |rows| rows == config.mark_rows.to_u64 }
      raise CrystalClick::CorruptPartError.new("part does not have the requested uniform mark row count")
    end
    config.marks.each do |mark|
      raise CrystalClick::BoundsError.new("selected mark is outside the physical grid") if mark >= key_marks.size
    end
    expected_selected_rows = config.marks.size.to_u64 * config.mark_rows.to_u64
    if expected_selected_rows > CrystalClick::WidePartTable::MAX_TOTAL_ROWS.to_u64
      raise CrystalClick::BoundsError.new("selected rows exceed the typed scan limit")
    end
    nil
  end

  private def partition_marks(marks : Array(Int32), workers : Int32) : Array(Array(Int32))
    Array(Array(Int32)).new(workers) do |worker|
      first = marks.size * worker // workers
      finish = marks.size * (worker + 1) // workers
      marks[first, finish - first].dup
    end
  end

  private def new_wide_worker_job(
    config : Config,
    readers : {CrystalClick::WidePart, CrystalClick::WidePart},
    image : CrystalClick::WideScanImage,
    worker_marks : Array(Array(Int32)),
    worker_starts : Array(Int32),
    keys : Array(UInt64),
    values : Array(UInt64),
  ) : WorkerJob
    ->(worker_index : Int32, state : WorkerState) do
      mark_ids = worker_marks[worker_index]
      start_sequence = worker_starts[worker_index]
      scan_wide_column(
        readers[0],
        "pk",
        mark_ids,
        start_sequence,
        config.mark_rows,
        state.mark_scratch,
        state.decode_workspace,
        keys,
        image,
      )
      scan_wide_column(
        readers[1],
        "value",
        mark_ids,
        start_sequence,
        config.mark_rows,
        state.mark_scratch,
        state.decode_workspace,
        values,
        image,
      )
      nil
    end
  end

  private def run_wide_scan(
    workers : WorkerPool,
    job : WorkerJob,
    scan_profile : CrystalClick::ReadRowsProfile::Scan?,
    scan_started : Time::Instant,
  ) : Nil
    {% if flag?(:read_rows_profile) %}
      profiled_job = ->(worker_index : Int32, state : WorkerState) do
        if profile = scan_profile
          profile_worker = profile.workers[worker_index]
          profile_worker.mark_start(scan_started)
          CrystalClick::ReadRowsProfile.with_worker(profile_worker) do
            begin
              job.call(worker_index, state)
            ensure
              profile_worker.mark_end(scan_started)
            end
          end
        else
          job.call(worker_index, state)
        end
      end
      workers.run(profiled_job, scan_profile)
    {% else %}
      workers.run(job)
    {% end %}
    nil
  end

  private def open_wide_scan_image(readers : {CrystalClick::WidePart, CrystalClick::WidePart}) : CrystalClick::WideScanImage
    paths = readers.map(&.parallel_numeric_scan_data_path).to_a
    CrystalClick::WideScanImage.open(paths, shared: true)
  end

  private def scan_wide_column(
    reader : CrystalClick::WidePart,
    column : String,
    mark_ids : Array(Int32),
    start_sequence : Int32,
    mark_rows : Int32,
    scratch_values : Slice(UInt64),
    decode_workspace : CrystalClick::CompressedBlock::DecodeWorkspace,
    result : Array(UInt64),
    image : CrystalClick::WideScanImage,
  ) : Nil
    scratch = scratch_values.to_unsafe.to_slice(scratch_values.size)
    sequence_offset = 0
    while sequence_offset < mark_ids.size
      run_end = sequence_offset + 1
      while run_end < mark_ids.size && mark_ids[run_end] == mark_ids[run_end - 1] + 1
        run_end += 1
      end
      expected_marks = run_end - sequence_offset
      emitted_marks = 0
      reader.scan_uint64_mark_range_into(
        column,
        mark_ids[sequence_offset],
        expected_marks,
        scratch,
        image,
        decode_workspace,
      ) do |mark_values|
        unless mark_values.size == mark_rows
          raise CrystalClick::CorruptPartError.new("Wide #{column} scan returned a partial mark")
        end
        if emitted_marks >= expected_marks
          raise CrystalClick::CorruptPartError.new("Wide #{column} scan emitted an extra mark")
        end
        destination = (start_sequence + sequence_offset + emitted_marks) * mark_rows
        copy_values_once!(mark_values, result, destination)
        emitted_marks += 1
      end
      unless emitted_marks == expected_marks
        raise CrystalClick::CorruptPartError.new("Wide #{column} scan did not materialize every assigned mark")
      end
      sequence_offset = run_end
    end
    nil
  end

  private def run_compact_scan(
    config : Config,
    table : CrystalClick::CompactPartTable,
    budget : CrystalClick::CompressedStreamBudget,
    context : CrystalClick::CompactPartPhysicalContext,
    worker_marks : Array(Array(Int32)),
    worker_starts : Array(Int32),
    keys : Array(UInt64),
    values : Array(UInt64),
  ) : Nil
    CrystalClick::CompactUInt64ScanImage.with_context(context, budget) do |image|
      worker = ->(worker_index : Int32) do
        mark_ids = worker_marks[worker_index]
        start_sequence = worker_starts[worker_index]
        workspace = CrystalClick::CompactUInt64ScanWorkspace.new
        expected_local_mark = 0
        expected_mark_offset = 0_u64
        batch_rows = {config.mark_rows, CrystalClick::WidePartTable::MAX_BATCH_ROWS}.min
        table.scan_typed_mark_indices_with_workspace(mark_ids, batch_rows, workspace, image) do |batch|
          unless expected_local_mark < mark_ids.size &&
                 batch.part_index == 0 &&
                 batch.mark_index == mark_ids[expected_local_mark] &&
                 batch.mark_row_offset == expected_mark_offset &&
                 batch.part_row_offset == mark_ids[expected_local_mark].to_u64 * config.mark_rows.to_u64 + expected_mark_offset
            raise CrystalClick::CorruptPartError.new("Compact scan returned rows outside its assigned mark")
          end
          key_values = batch.values_for("pk")
          value_values = batch.values_for("value")
          row_count = batch.row_count || raise(CrystalClick::CorruptPartError.new("Compact scan returned a batch without row count"))
          expected_batch_rows = {config.mark_rows.to_u64 - expected_mark_offset, batch_rows.to_u64}.min
          unless row_count == expected_batch_rows && key_values.size == expected_batch_rows && value_values.size == expected_batch_rows
            raise CrystalClick::CorruptPartError.new("Compact scan returned an invalid selected mark batch")
          end
          destination = (start_sequence + expected_local_mark) * config.mark_rows + expected_mark_offset.to_i
          copy_values_once!(key_values, keys, destination)
          copy_values_once!(value_values, values, destination)
          expected_mark_offset += row_count
          if expected_mark_offset == config.mark_rows.to_u64
            expected_local_mark += 1
            expected_mark_offset = 0_u64
          end
        end
        unless expected_local_mark == mark_ids.size && expected_mark_offset == 0_u64
          raise CrystalClick::CorruptPartError.new("Compact scan did not materialize every assigned mark")
        end
        nil
      end
      run_workers(config.workers, worker)
    end
    nil
  end

  private def run_workers(
    worker_count : Int32,
    work : Proc(Int32, Nil),
  ) : Nil
    if worker_count == 1
      work.call(0_i32)
      return nil
    end

    {% if flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
      raise CrystalClick::UnsupportedFormatError.new("four-worker Compact read_rows requires isolated execution contexts")
    {% else %}
      errors = Array(Exception?).new(worker_count, nil)
      contexts = [] of Fiber::ExecutionContext::Isolated
      launch_error = nil.as(Exception?)
      begin
        worker_count.times do |worker_index|
          index = worker_index.to_i32
          contexts << Fiber::ExecutionContext::Isolated.new("read_rows_scan worker #{index}") do
            begin
              work.call(index)
            rescue ex : Exception
              errors[index] = ex
            end
          end
        end
      rescue ex : Exception
        launch_error = ex
      ensure
        contexts.each do |context|
          begin
            context.wait
          rescue ex : Exception
            launch_error ||= ex
          end
        end
      end
      raise launch_error if launch_error
      errors.each do |error|
        raise error if error
      end
      nil
    {% end %}
  end

  private def copy_values_once!(source : Slice(UInt64), destination : Array(UInt64), row_offset : Int32) : Nil
    unless row_offset >= 0 && source.size <= destination.size - row_offset
      raise CrystalClick::CorruptPartError.new("scan output copy exceeds its preallocated result array")
    end
    {% if flag?(:read_rows_profile) %}
      copy_started = Time.instant
    {% end %}
    source.copy_to(destination.to_unsafe + row_offset, source.size)
    {% if flag?(:read_rows_profile) %}
      copy_finished = Time.instant
      CrystalClick::ReadRowsProfile.current_worker?.try &.add_output_copy(
        CrystalClick::ReadRowsProfile.elapsed_ns_between(copy_started, copy_finished),
        (source.size * sizeof(UInt64)).to_u64,
      )
    {% end %}
    nil
  end

  private def compare_output!(keys : Array(UInt64), values : Array(UInt64), oracle : String, rows : Int32) : Nil
    key_bytes = Slice.new(keys.to_unsafe.as(UInt8*), rows * sizeof(UInt64))
    value_bytes = Slice.new(values.to_unsafe.as(UInt8*), rows * sizeof(UInt64))
    expected = oracle.to_slice
    unless key_bytes == expected[0, key_bytes.size] && value_bytes == expected[key_bytes.size, value_bytes.size]
      raise CrystalClick::CorruptPartError.new("read_rows oracle byte comparison failed")
    end
    nil
  end

  private def selected_row_count(config : Config) : Int32
    (config.marks.size.to_u64 * config.mark_rows.to_u64).to_i32
  end

  private def new_scan_profile(config : Config) : CrystalClick::ReadRowsProfile::Scan?
    {% if flag?(:read_rows_profile) %}
      config.layout == "wide" ? CrystalClick::ReadRowsProfile::Scan.new(config.workers) : nil
    {% else %}
      nil
    {% end %}
  end

  private def elapsed_ns(started : Time::Instant) : Int64
    elapsed = (Time.instant - started).total_nanoseconds.to_i64
    elapsed > 0 ? elapsed : 1_i64
  end

  private def emit_result(
    elapsed_ns : Int64,
    prepare_ns : Int64,
    rows : Int32,
    workers : Int32,
    worker_marks : Array(Array(Int32)),
    scan_profile : CrystalClick::ReadRowsProfile::Scan?,
    admission_ns : Int64?,
    mmap_prepare_ns : Int64?,
    retained_wide_image : CrystalClick::WideScanImage?,
    worker_prepare_ns : Int64?,
    retained_wide_workers : WorkerPool?,
  ) : Nil
    STDOUT.puts(JSON.build do |json|
      json.object do
        json.field "elapsed_ns", elapsed_ns
        json.field "prepare_ns", prepare_ns
        if admission = admission_ns
          json.field "admission_ns", admission
        end
        if mmap_prepare = mmap_prepare_ns
          json.field "mmap_prepare_ns", mmap_prepare
        end
        if worker_prepare = worker_prepare_ns
          json.field "worker_prepare_ns", worker_prepare
        end
        json.field "rows", rows
        json.field "effective_workers", workers
        json.field "worker_marks" do
          json.array do
            worker_marks.each do |marks|
              json.array do
                marks.each { |mark| json.number mark }
              end
            end
          end
        end
        json.field "checksum_on_read", true
        if profile = scan_profile
          json.field "profile" do
            json.object do
              json.field "version", 1
              json.field "transport_kind", "mmap"
              json.field "shared_mmap" do
                json.object do
                  json.field "open_ns", profile.shared_mmap.open_ns
                  json.field "close_ns", profile.shared_mmap.close_ns
                  json.field "map_calls", profile.shared_mmap.map_calls
                  json.field "unmap_calls", profile.shared_mmap.unmap_calls
                  json.field "mapped_bytes", profile.shared_mmap.mapped_bytes
                end
              end
              if image = retained_wide_image
                json.field "retained_mmap" do
                  json.object do
                    json.field "map_calls", image.mapping_count
                    json.field "mapped_bytes", image.mapped_bytes
                  end
                end
              end
              {% if flag?(:read_rows_profile) %}
                if worker_session = retained_wide_workers
                  json.field "worker_session" do
                    json.object do
                      json.field "worker_count", worker_session.worker_count
                      json.field "context_create_count", worker_session.context_create_count
                      json.field "context_join_count", worker_session.context_join_count
                      json.field "dispatch_count", worker_session.dispatch_count
                      json.field "decode_buffer_allocation", "lazy_on_first_decode"
                      json.field "workers" do
                        json.array do
                          worker_session.identities.each_with_index do |identity, index|
                            json.object do
                              json.field "index", index
                              json.field "worker_id", identity.worker
                              json.field "mark_scratch_id", identity.mark_scratch
                              json.field "mark_scratch_capacity", identity.mark_scratch_capacity
                              json.field "decode_workspace_id", identity.decode_workspace
                              json.field "decode_buffer_id", identity.decode_buffer
                              json.field "decode_buffer_capacity", identity.decode_buffer_capacity
                            end
                          end
                        end
                      end
                    end
                  end
                end
              {% end %}
              if workers == 4
                json.field "launch_ns", profile.launch_ns
                json.field "join_ns", profile.join_ns
                json.field "launch_calls", profile.launch_calls
                json.field "join_calls", profile.join_calls
              end
              json.field "workers" do
                json.array do
                  profile.workers.each do |worker|
                    json.object do
                      json.field "index", worker.index
                      json.field "start_ns", worker.start_ns
                      json.field "end_ns", worker.end_ns
                      json.field "transport_ns", worker.transport_ns
                      json.field "checksum_ns", worker.checksum_ns
                      json.field "lz4_ns", worker.lz4_ns
                      json.field "frame_dispatch_ns", worker.frame_dispatch_ns
                      json.field "materialize_copy_ns", worker.materialize_copy_ns
                      json.field "output_copy_ns", worker.output_copy_ns
                      json.field "checksum_calls", worker.checksum_calls
                      json.field "lz4_calls", worker.lz4_calls
                      json.field "materialize_copy_bytes", worker.materialize_copy_bytes
                      json.field "output_copy_bytes", worker.output_copy_bytes
                      json.field "transport_calls", worker.transport_calls
                      json.field "transport_bytes", worker.transport_bytes
                      json.field "mmap_calls", worker.mmap_calls
                      json.field "munmap_calls", worker.munmap_calls
                      json.field "io_lifecycle_ns", worker.io_lifecycle_ns
                      json.field "file_size_ns", worker.file_size_ns
                      json.field "file_open_ns", worker.file_open_ns
                      json.field "file_stat_ns", worker.file_stat_ns
                      json.field "file_close_ns", worker.file_close_ns
                      json.field "file_size_calls", worker.file_size_calls
                      json.field "file_open_calls", worker.file_open_calls
                      json.field "file_stat_calls", worker.file_stat_calls
                      json.field "file_close_calls", worker.file_close_calls
                    end
                  end
                end
              end
            end
          end
        end
      end
    end)
  end

  private def checksum_mismatch?(error : Exception) : Bool
    message = error.message || ""
    message.includes?("checksum mismatch") || message.includes?("checksum does not match")
  end

  private def cleanup_failure(primary_error : Exception?, cleanup_error : Exception, operation : String) : Exception
    if original = primary_error
      CleanupFailure.new(original, cleanup_error, operation)
    else
      cleanup_error
    end
  end

  private class CleanupFailure < Exception
    def initialize(primary : Exception, cleanup : Exception, operation : String)
      super("#{operation} failed after #{primary.message || primary.class.name}: #{cleanup.message || cleanup.class.name}")
    end
  end
end

CrystalClickReadRowsScan.run(ARGV)
