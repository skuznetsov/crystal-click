module CrystalClick
  class CompactPartTable
    # Select marks using an ordinary UInt64 column before reading the selected
    # MRK4 Advanced JSON root. Visit matching marks in physical order on the
    # caller's fiber. Each callback receives the full decoded mark and sorted
    # mark-local offsets of matching rows. Both views are borrowed for the
    # duration of the callback.
    #
    # The scan authenticates the key frames used for filtering and checks the
    # JSON frames and Copy/Data for each selected mark. A compressed frame can
    # contain bytes from several columns or marks.
    def scan_compact_json_filtered(
      filter_column : String,
      predicate : Proc(UInt64, Bool),
      workers : Int = 1,
      & : CompactJsonColumnarBatch, Slice(Int32) -> Nil
    ) : Nil
      TypedPartTable.validate_parallel_workers!(workers)
      {% if flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
        if workers > 1
          raise UnsupportedFormatError.new(
            "parallel Compact JSON scan requires execution contexts; use Crystal 1.21+ without -Dwithout_mt or build legacy preview_mt with -Dexecution_context",
          )
        end
      {% end %}

      filtered = prepare_filtered_advanced_json_scan(filter_column, predicate)
      unless plan = filtered.json_plan
        filtered.validate_source!
        return
      end
      plan.prepare_columnar_output!
      marks = filtered.mark_indices
      effective_workers = Math.min(workers, marks.size)
      workspace_limit = filtered_json_workspace_limit
      retained_bytes = filtered.retained_workspace_bytes
      if retained_bytes >= workspace_limit
        raise BoundsError.new("filtered Compact JSON scan leaves no workspace for output")
      end
      output_limit = plan.retained_workspace_bytes + (workspace_limit - retained_bytes) // effective_workers.to_u64
      {% unless flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
        if effective_workers > 1
          return scan_filtered_json_parallel(filtered, plan, marks, effective_workers, output_limit) do |batch, rows|
            yield batch, rows
          end
        end
      {% end %}

      budget = plan.new_decode_budget
      plan.prepare_decode_budget!(budget)
      output = plan.new_columnar_output(output_limit)
      marks.each do |mark|
        scan_compact_json_columnar_mark_into(mark, plan, budget, output, part_row_offset: filtered.part_row_offset_for(mark))
        filtered.validate_source!
        yield output, filtered.row_indices_for(mark)
      end
      nil
    end

    # :nodoc:
    # Prepare an authenticated selection for callers that manage their own
    # reusable worker contexts and columnar outputs.
    def prepare_filtered_advanced_json_scan(
      filter_column : String,
      predicate : Proc(UInt64, Bool),
    ) : CompactFilteredJsonPartPlan
      unless shared_advanced_json_scan_candidate? && @readers.size == 1 && @readers[0][0] == filter_column
        raise UnsupportedFormatError.new("filtered Compact JSON scan requires one Advanced JSON root and the ordinary UInt64 filter column")
      end

      workspace_limit = filtered_json_workspace_limit
      observer = ->(bytes : UInt64) do
        if bytes > workspace_limit
          raise BoundsError.new("filtered Compact JSON scan exceeds its materialization limit")
        end
        nil
      end
      @json_readers[0].prepare_filtered_advanced_json_scan(observer, filter_column, predicate)
    end

    private def filtered_json_workspace_limit : UInt64
      limit = WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
      reader_bytes = @readers[0][3].retained_workspace_bytes
      if reader_bytes > limit
        raise BoundsError.new("filtered Compact JSON scan exceeds its materialization limit")
      end
      limit - reader_bytes
    end

    {% unless flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
      private def scan_filtered_json_parallel(
        filtered : CompactFilteredJsonPartPlan,
        plan : CompactStaticJsonAdvancedPartPlan,
        marks : Array(Int32),
        workers : Int,
        output_limit : UInt64,
        & : CompactJsonColumnarBatch, Slice(Int32) -> Nil
      ) : Nil
        outputs = Array(Channel(CompactJsonColumnarBatch)).new(workers) { Channel(CompactJsonColumnarBatch).new }
        acknowledgements = Array(Channel(Nil)).new(workers) { Channel(Nil).new }
        contexts = Array(Fiber::ExecutionContext::Isolated).new(workers)
        primary_error = nil.as(Exception?)
        begin
          workers.times do |worker|
            contexts << start_filtered_json_worker(filtered, plan, marks, workers, worker, output_limit,
              outputs[worker], acknowledgements[worker])
          end
          marks.each_with_index do |mark, index|
            worker = index % workers
            unless batch = outputs[worker].receive?
              contexts[worker].wait
              raise CorruptPartError.new("parallel Compact JSON worker closed before emitting a matching mark")
            end
            filtered.validate_source!
            yield batch, filtered.row_indices_for(mark)
            acknowledgements[worker].send(nil)
          end
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
        end
        if error = primary_error
          raise error
        end
        nil
      end

      private def start_filtered_json_worker(
        filtered : CompactFilteredJsonPartPlan,
        plan : CompactStaticJsonAdvancedPartPlan,
        marks : Array(Int32),
        workers : Int,
        worker : Int,
        output_limit : UInt64,
        output : Channel(CompactJsonColumnarBatch),
        acknowledgement : Channel(Nil),
      ) : Fiber::ExecutionContext::Isolated
        Fiber::ExecutionContext::Isolated.new("crystal-click filtered Compact JSON worker #{worker}") do
          budget = plan.new_decode_budget
          plan.prepare_decode_budget!(budget)
          batch = plan.new_columnar_output(output_limit)
          index = worker
          while index < marks.size
            mark = marks[index]
            scan_compact_json_columnar_mark_into(mark, plan, budget, batch, part_row_offset: filtered.part_row_offset_for(mark))
            output.send(batch)
            acknowledgement.receive
            index += workers
          end
        rescue Channel::ClosedError
          # The coordinator stopped delivery and released all borrowed batches.
        ensure
          output.close
        end
      end
    {% end %}
  end
end
