module CrystalClick
  class TypedPartTable
    MAX_PARALLEL_SCAN_WORKERS = 32
    private alias ParallelScanPartSource = {String, Bool, CompressedStreamBudget?, CompactPartPhysicalContext?, CompactPartTable?, WidePartTable?}

    private struct ParallelScanMark
      getter part_index : Int32
      getter mark_index : Int32
      getter worker_index : Int32
      getter part_row_offset : UInt64
      getter row_count : UInt64

      def initialize(
        @part_index : Int32,
        @mark_index : Int32,
        @worker_index : Int32,
        @part_row_offset : UInt64,
        @row_count : UInt64,
      )
      end
    end

    # Shared worker-bound validation for TypedPartTable and OfflineTable
    # entrypoints. One to 32 workers bounds execution contexts and queues.
    def self.validate_parallel_workers!(workers : Int) : Nil
      if workers < 1 || workers > MAX_PARALLEL_SCAN_WORKERS
        raise BoundsError.new("parallel worker count is out of range")
      end
      nil
    end

    # Scan round-robin physical marks on isolated worker contexts. Each worker
    # opens one independent reader per touched part except admitted ordinary
    # Compact UInt64 and Wide primitive numeric tables, whose read-only bindings
    # and mark grids are shared.
    # Compact readers share the original part's synchronized cumulative
    # transport budget. For workers: 1, admitted ordinary Wide numeric parts
    # reuse one scan-scoped read-only image per part; other layouts use the
    # ordinary serial API. A request with at most one nonempty mark uses the
    # same serial path when execution contexts exist.
    # True parallel mode admits only direct, non-projection primitive numeric
    # selections.
    #
    # Callbacks run serially on the caller in selected part and row order. A
    # batch's slices borrow reader-owned storage and are valid only until its
    # callback returns. Worker count is limited to 32; each worker has at most
    # one queued batch, and all contexts are joined before return or re-raise.
    def scan_typed_parallel(
      workers : Int,
      batch_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS,
      & : WidePartTableBatch -> Nil
    ) : Nil
      self.class.validate_parallel_workers!(workers)
      validate_batch_rows(batch_rows)
      if workers == 1
        return scan_typed_with_shared_wide_mmaps(batch_rows) { |batch| yield batch }
      end

      {% if flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
        raise UnsupportedFormatError.new(
          "parallel typed scan requires execution contexts; use Crystal 1.21+ without -Dwithout_mt or build legacy preview_mt with -Dexecution_context",
        )
      {% else %}
        positive_mark_count = 0
        @part_mark_row_counts.each do |marks|
          marks.each { |rows| positive_mark_count += 1 if rows > 0_u64 }
        end
        if positive_mark_count == 0
          raise CorruptPartError.new("typed table has no nonempty marks")
        end

        effective_workers = workers < positive_mark_count ? workers : positive_mark_count
        if effective_workers <= 1
          return scan_typed_with_shared_wide_mmaps(batch_rows) { |batch| yield batch }
        end

        if @projection_selected
          raise UnsupportedFormatError.new("parallel typed scan does not admit projection selections")
        end
        unless direct_primitive_numeric_sources?
          raise UnsupportedFormatError.new("parallel typed scan admits only direct non-null primitive numeric columns")
        end

        # Preserve the serial facade's full pre-callback backend admission.
        preflight_backends!
        schedule, worker_marks = parallel_scan_plan(effective_workers, positive_mark_count)
        part_sources = Array(ParallelScanPartSource).new(@entries.size)
        part_starts = Array(UInt64).new(@entries.size)
        source_row_offset = 0_u64
        @entries.each do |entry|
          compact_reader = entry.reader.as?(CompactPartTable)
          transport_budget = compact_reader.try(&.parallel_scan_transport_budget!)
          scan_context = compact_reader.try(&.parallel_uint64_scan_context)
          admitted_reader = scan_context ? compact_reader : nil
          admitted_wide_reader = entry.reader.as?(WidePartTable).try(&.parallel_primitive_numeric_scan_context)
          part_sources << {String.new(entry.path.to_slice), !compact_reader.nil?, transport_budget, scan_context, admitted_reader, admitted_wide_reader}
          part_starts << source_row_offset
          source_row_offset = checked_add_rows(source_row_offset, entry.row_count)
        end
        raise CorruptPartError.new("source row count mismatch") unless source_row_offset == @total_row_count

        expected_scan_image_users = Array(Int32).new(@entries.size, 0_i32)
        worker_marks.each do |parts|
          parts.each_with_index do |marks, part_index|
            expected_scan_image_users[part_index] += 1 unless marks.empty?
          end
        end
        scan_image_registry = CompactUInt64ScanImageRegistry.new(
          part_sources.map { |source| source[3] },
          part_sources.map { |source| source[2] },
          expected_scan_image_users,
        )
        wide_scan_image_registry = WideScanImageRegistry.new(
          part_sources.map { |source| source[5] },
          expected_scan_image_users,
        )

        outputs = Array(Channel(WidePartTableBatch)).new(effective_workers) do
          Channel(WidePartTableBatch).new(1)
        end
        acknowledgements = Array(Channel(Nil)).new(effective_workers) do
          Channel(Nil).new
        end
        contexts = [] of Fiber::ExecutionContext::Isolated
        primary_error = nil.as(Exception?)

        begin
          effective_workers.times do |worker_index|
            contexts << start_parallel_worker(
              worker_index,
              worker_marks[worker_index],
              part_sources,
              scan_image_registry,
              wide_scan_image_registry,
              batch_rows,
              outputs[worker_index],
              acknowledgements[worker_index],
            )
          end

          schedule.each do |mark|
            rows_seen = 0_u64
            output = outputs[mark.worker_index]
            while rows_seen < mark.row_count
              batch = output.receive?
              unless batch
                contexts[mark.worker_index].wait
                raise CorruptPartError.new("parallel worker closed before completing a selected mark")
              end

              emitted_rows = batch.row_count || raise(CorruptPartError.new("parallel worker emitted a batch without a row count"))
              expected_rows = batch_rows.to_u64 < mark.row_count - rows_seen ? batch_rows.to_u64 : mark.row_count - rows_seen
              unless batch.part_index == 0 && batch.mark_index == mark.mark_index &&
                     batch.part_row_offset == mark.part_row_offset + rows_seen &&
                     batch.mark_row_offset == rows_seen && emitted_rows == expected_rows
                raise CorruptPartError.new("parallel worker emitted rows outside its assigned mark")
              end

              yield rebase_batch!(batch, mark.part_index, part_starts[mark.part_index])
              acknowledgements[mark.worker_index].send(nil)
              rows_seen = checked_add_rows(rows_seen, emitted_rows)
            end
          end

          # No further acknowledgements are needed: every expected row batch
          # has been consumed. Closing this handshake lets us detect a backend
          # over-emission without waiting on a worker parked for an
          # acknowledgement to an unexpected batch.
          acknowledgements.each(&.close)
          outputs.each do |output|
            raise CorruptPartError.new("parallel worker left an unconsumed batch") unless output.receive?.nil?
          end
          contexts.each(&.wait)
        rescue ex : Exception
          primary_error = ex
        ensure
          outputs.each(&.close)
          acknowledgements.each(&.close)
          contexts.each do |context|
            begin
              context.wait
            rescue ex : Exception
              primary_error ||= ex
            end
          end
          cleanup_error = nil.as(Error?)
          begin
            scan_image_registry.close_all
          rescue ex : Error
            cleanup_error ||= ex
          end
          begin
            wide_scan_image_registry.close_all
          rescue ex : Error
            cleanup_error ||= ex
          end
          if cleanup = cleanup_error
            if error = primary_error
              primary_error = MMapCleanupError.new(error, cleanup)
            else
              raise cleanup
            end
          end
        end

        if error = primary_error
          raise error
        end
        nil
      {% end %}
    end

    private def direct_primitive_numeric_sources? : Bool
      return false unless @column_types.size == @column_sources.size
      @column_types.each_with_index.all? do |typed_column, index|
        column, type = typed_column
        source = @column_sources[index]
        WidePart.supports_numeric_type?(type) &&
          source[0] == column && source[1] == column && source[2] == type
      end
    end

    private def with_wide_scan_image(
      reader : WidePartTable,
      & : WideScanImage -> Nil
    ) : Nil
      image = reader.open_parallel_scan_image
      primary_error = nil.as(Exception?)
      begin
        yield image
      rescue ex : Exception
        primary_error = ex
      ensure
        begin
          image.close
        rescue cleanup_error : Error
          if error = primary_error
            raise MMapCleanupError.new(error, cleanup_error)
          else
            raise cleanup_error
          end
        end
      end
      raise primary_error.not_nil! if primary_error
      nil
    end

    private def parallel_scan_plan(
      worker_count : Int,
      positive_mark_count : Int,
    ) : {Array(ParallelScanMark), Array(Array(Array(Int32)))}
      schedule = [] of ParallelScanMark
      worker_marks = Array(Array(Array(Int32))).new(worker_count) do
        Array(Array(Int32)).new(@entries.size) { [] of Int32 }
      end
      worker_index = 0
      @part_mark_row_counts.each_with_index do |marks, part_index|
        part_row_offset = 0_u64
        marks.each_with_index do |rows, mark_index|
          if rows > 0_u64
            raise CorruptPartError.new("parallel mark partition exceeds its worker count") if worker_index >= worker_count
            worker_marks[worker_index][part_index] << mark_index.to_i32
            schedule << ParallelScanMark.new(part_index.to_i32, mark_index.to_i32, worker_index.to_i32, part_row_offset, rows)
            worker_index += 1
            worker_index = 0 if worker_index == worker_count
          end
          part_row_offset = checked_add_rows(part_row_offset, rows)
        end
        raise CorruptPartError.new("part mark rows differ from the selected row count") unless part_row_offset == @entries[part_index].row_count
      end

      unless schedule.size == positive_mark_count && worker_marks.all? { |parts| parts.any? { |marks| !marks.empty? } }
        raise CorruptPartError.new("parallel mark partition did not cover every worker")
      end
      {schedule, worker_marks}
    end

    {% unless flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
      private def start_parallel_worker(
        worker_index : Int,
        part_marks : Array(Array(Int32)),
        part_sources : Array(ParallelScanPartSource),
        scan_image_registry : CompactUInt64ScanImageRegistry,
        wide_scan_image_registry : WideScanImageRegistry,
        batch_rows : Int,
        output : Channel(WidePartTableBatch),
        acknowledgement : Channel(Nil),
      ) : Fiber::ExecutionContext::Isolated
        name = "crystal-click typed scan worker #{worker_index}"
        Fiber::ExecutionContext::Isolated.new(name) do
          run_parallel_worker(part_marks, part_sources, scan_image_registry, wide_scan_image_registry, batch_rows, output, acknowledgement)
        end
      end

      private def run_parallel_worker(
        part_marks : Array(Array(Int32)),
        part_sources : Array(ParallelScanPartSource),
        scan_image_registry : CompactUInt64ScanImageRegistry,
        wide_scan_image_registry : WideScanImageRegistry,
        batch_rows : Int,
        output : Channel(WidePartTableBatch),
        acknowledgement : Channel(Nil),
      ) : Nil
        scan_workspace = nil.as(CompactUInt64ScanWorkspace?)
        part_marks.each_with_index do |marks, part_index|
          next if marks.empty?
          path, compact, transport_budget, scan_context, admitted_reader, admitted_wide_reader = part_sources[part_index]
          if compact
            reader = admitted_reader || begin
              budget = transport_budget || raise(CorruptPartError.new("parallel Compact part lost its transport budget"))
              CompactPartTable.open_selected_typed_with_transport_budget([path], @columns, budget, scan_context)
            end
            if reader.reusable_uint64_scan?
              scan_workspace ||= CompactUInt64ScanWorkspace.new
              if scan_context
                image = scan_image_registry.acquire(part_index)
                begin
                  reader.scan_typed_mark_indices_with_workspace(marks, batch_rows, scan_workspace, image) do |batch|
                    send_parallel_batch!(batch, output, acknowledgement)
                  end
                ensure
                  scan_image_registry.release(part_index)
                end
              else
                reader.scan_typed_mark_indices_with_workspace(marks, batch_rows, scan_workspace) do |batch|
                  send_parallel_batch!(batch, output, acknowledgement)
                end
              end
            else
              reader.scan_typed_mark_indices(marks, batch_rows) do |batch|
                send_parallel_batch!(batch, output, acknowledgement)
              end
            end
          else
            if reader = admitted_wide_reader
              image = wide_scan_image_registry.acquire(part_index)
              begin
                reader.scan_typed_mark_indices(marks, batch_rows, image) do |batch|
                  send_parallel_batch!(batch, output, acknowledgement)
                end
              ensure
                wide_scan_image_registry.release(part_index)
              end
            else
              reader = WidePartTable.open_selected_typed([path], @columns)
              reader.scan_typed_mark_indices(marks, batch_rows) do |batch|
                send_parallel_batch!(batch, output, acknowledgement)
              end
            end
          end
        end
      rescue ex : Channel::ClosedError
        # Closing the acknowledgement channel cancels any outstanding batch.
      ensure
        output.close
      end

      private def send_parallel_batch!(
        batch : WidePartTableBatch,
        output : Channel(WidePartTableBatch),
        acknowledgement : Channel(Nil),
      ) : Nil
        output.send(batch)
        acknowledgement.receive
        nil
      end
    {% end %}
  end
end
