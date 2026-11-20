module CrystalClick
  class TypedPartTable
    # Filter the UInt64 selection before decoding the JSON in a single
    # regular Compact part. See CompactPartTable#scan_compact_json_filtered
    # for the borrowed callback and source verification contract.
    def scan_compact_json_filtered(
      filter_column : String,
      predicate : Proc(UInt64, Bool),
      workers : Int = 1,
      & : CompactJsonColumnarBatch, Slice(Int32) -> Nil
    ) : Nil
      compact_filtered_json_reader.scan_compact_json_filtered(filter_column, predicate, workers) { |batch, rows| yield batch, rows }
    end

    # Filter one regular Compact part and yield packed matching rows. See
    # CompactPartTable#scan_compact_json_filtered_rows for source offsets,
    # borrowing and verification.
    def scan_compact_json_filtered_rows(
      filter_column : String,
      predicate : Proc(UInt64, Bool),
      workers : Int = 1,
      & : CompactJsonColumnarBatch, Slice(Int32) -> Nil
    ) : Nil
      compact_filtered_json_reader.scan_compact_json_filtered_rows(filter_column, predicate, workers) { |batch, rows| yield batch, rows }
    end

    private def compact_filtered_json_reader : CompactPartTable
      unless @entries.size == 1 && !@projection_selected && (reader = @entries[0].reader.as?(CompactPartTable))
        raise UnsupportedFormatError.new("filtered JSON scan requires one regular Compact part")
      end
      reader
    end

    # Decode Compact Advanced root JSON into worker-owned sparse columns. Each
    # output arena is retained for its worker/part pair and is borrowed only
    # until the corresponding callback returns.
    def scan_compact_json_columnar(
      workers : Int = 1,
      batch_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS,
      workspace_limit : UInt64 = WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64,
      & : CompactJsonColumnarBatch -> Nil
    ) : Nil
      self.class.validate_parallel_workers!(workers)
      validate_batch_rows(batch_rows)
      if workspace_limit == 0_u64 || workspace_limit > WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise BoundsError.new("Compact JSON columnar workspace limit is out of range")
      end
      if @projection_selected || @entries.empty? || !@entries.all? do |entry|
           entry.reader.as?(CompactPartTable).try(&.shared_advanced_json_scan_candidate?)
         end
        raise UnsupportedFormatError.new("columnar JSON scan requires Compact Advanced root JSON parts")
      end

      # Full-part admission for every source precedes output delivery. Cache
      # the immutable union shape on the caller before publishing plans to
      # worker contexts.
      plans = preflight_backends!(retain_compact_json_plans: true) ||
              raise CorruptPartError.new("Compact JSON columnar preflight produced no plans")
      unless plans.size == @entries.size && plans.all? { |plan| !plan.nil? }
        raise UnsupportedFormatError.new("Compact JSON columnar scan requires an admitted Advanced plan for every part")
      end
      concrete_plans = plans.map { |plan| plan || raise(CorruptPartError.new("Compact JSON plan disappeared after preflight")) }
      concrete_plans.each(&.prepare_columnar_output!)

      positive_mark_count = 0
      @part_mark_row_counts.each do |marks|
        marks.each { |rows| positive_mark_count += 1 if rows > 0_u64 }
      end
      if positive_mark_count == 0
        raise CorruptPartError.new("Compact JSON columnar table has no nonempty marks")
      end
      effective_workers = Math.min(workers, positive_mark_count)
      schedule, worker_marks = parallel_scan_plan(effective_workers, positive_mark_count)

      part_starts = Array(UInt64).new(@entries.size)
      part_mark_starts = Array(Array(UInt64)).new(@entries.size)
      total_plan_bytes = 0_u64
      source_row_offset = 0_u64
      concrete_plans.each do |plan|
        total_plan_bytes = checked_columnar_add(total_plan_bytes, plan.retained_workspace_bytes)
      end
      @entries.each_with_index do |entry, part_index|
        part_starts << source_row_offset
        mark_starts = [] of UInt64
        part_offset = 0_u64
        @part_mark_row_counts[part_index].each do |rows|
          mark_starts << part_offset
          part_offset = checked_columnar_add(part_offset, rows)
        end
        unless part_offset == entry.row_count
          raise CorruptPartError.new("Compact JSON columnar mark rows differ from the selected part row count")
        end
        part_mark_starts << mark_starts
        source_row_offset = checked_add_rows(source_row_offset, entry.row_count)
      end
      unless source_row_offset == @total_row_count
        raise CorruptPartError.new("Compact JSON columnar source row count mismatch")
      end
      if total_plan_bytes >= workspace_limit
        raise CorruptPartError.new("Compact JSON columnar plans leave no workspace for retained outputs")
      end

      output_owners = 0
      worker_marks.each do |parts|
        parts.each_with_index { |marks, _part_index| output_owners += 1 unless marks.empty? }
      end
      unless output_owners > 0
        raise CorruptPartError.new("Compact JSON columnar schedule has no output owner")
      end
      output_limit = (workspace_limit - total_plan_bytes) // output_owners.to_u64

      outputs = Array(Array(CompactJsonColumnarBatch?)).new(effective_workers) do
        Array(CompactJsonColumnarBatch?).new(@entries.size, nil)
      end
      budgets = Array(Array(BinaryCodecBudget?)).new(effective_workers) do
        Array(BinaryCodecBudget?).new(@entries.size, nil)
      end
      worker_marks.each_with_index do |parts, worker_index|
        parts.each_with_index do |marks, part_index|
          next if marks.empty?
          plan = concrete_plans[part_index]
          budget = plan.new_decode_budget
          plan.prepare_decode_budget!(budget)
          plan_workspace = checked_columnar_add(plan.retained_workspace_bytes, output_limit)
          outputs[worker_index][part_index] = plan.new_columnar_output(plan_workspace)
          budgets[worker_index][part_index] = budget
        end
      end

      if effective_workers == 1
        schedule.each do |mark|
          reader = @entries[mark.part_index].reader.as(CompactPartTable)
          plan = concrete_plans[mark.part_index]
          budget = budgets[0][mark.part_index] || raise(CorruptPartError.new("Compact JSON worker lost its decode budget"))
          output = outputs[0][mark.part_index] || raise(CorruptPartError.new("Compact JSON worker lost its output arena"))
          reader.scan_compact_json_columnar_mark_into(
            mark.mark_index,
            plan,
            budget,
            output,
            mark.part_index,
            part_starts[mark.part_index],
            mark.part_row_offset,
          )
          emit_compact_json_columnar_mark!(output, plan, mark, part_starts[mark.part_index], batch_rows) { |batch| yield batch }
        end
        return nil
      end

      {% if flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
        raise UnsupportedFormatError.new(
          "parallel Compact JSON columnar scan requires execution contexts; use Crystal 1.21+ without -Dwithout_mt or build legacy preview_mt with -Dexecution_context",
        )
      {% else %}
        channels = Array(Channel(CompactJsonColumnarBatch)).new(effective_workers) do
          Channel(CompactJsonColumnarBatch).new(1)
        end
        acknowledgements = Array(Channel(Nil)).new(effective_workers) do
          Channel(Nil).new
        end
        contexts = [] of Fiber::ExecutionContext::Isolated
        primary_error = nil.as(Exception?)
        begin
          effective_workers.times do |worker_index|
            contexts << start_compact_json_columnar_worker(
              worker_index,
              worker_marks[worker_index],
              concrete_plans,
              outputs[worker_index],
              budgets[worker_index],
              part_starts,
              part_mark_starts,
              batch_rows,
              channels[worker_index],
              acknowledgements[worker_index],
            )
          end

          schedule.each do |mark|
            rows_seen = 0_u64
            plan = concrete_plans[mark.part_index]
            output = channels[mark.worker_index]
            while rows_seen < mark.row_count
              batch = output.receive?
              unless batch
                contexts[mark.worker_index].wait
                raise CorruptPartError.new("Compact JSON worker closed before completing its assigned mark")
              end
              emitted_rows = validate_compact_json_columnar_batch!(batch, mark, rows_seen, batch_rows,
                part_starts[mark.part_index])
              # Authenticate immediately before every callback, after any
              # earlier callback has returned, even when a worker queued data.
              plan.validate_source!
              yield batch
              acknowledgements[mark.worker_index].send(nil)
              rows_seen = checked_add_rows(rows_seen, emitted_rows)
            end
          end

          acknowledgements.each(&.close)
          channels.each do |channel|
            raise CorruptPartError.new("Compact JSON worker left an unconsumed batch") unless channel.receive?.nil?
          end
          contexts.each(&.wait)
        rescue ex : Exception
          primary_error = ex
        ensure
          channels.each(&.close)
          acknowledgements.each(&.close)
          contexts.each do |context|
            begin
              context.wait
            rescue ex : Exception
              primary_error ||= ex
            end
          end
        end
        raise primary_error.not_nil! if primary_error
        nil
      {% end %}
    end

    private def emit_compact_json_columnar_mark!(
      output : CompactJsonColumnarBatch,
      plan : CompactStaticJsonAdvancedPartPlan,
      mark : ParallelScanMark,
      part_start : UInt64,
      batch_rows : Int,
      & : CompactJsonColumnarBatch -> Nil
    ) : Nil
      rows_seen = 0_u64
      while rows_seen < mark.row_count
        rows_remaining = mark.row_count - rows_seen
        emitted = batch_rows.to_u64 < rows_remaining ? batch_rows.to_u64 : rows_remaining
        emitted_i = emitted.to_i
        mark_offset = rows_seen
        part_offset = checked_add_rows(mark.part_row_offset, rows_seen)
        source_offset = checked_add_rows(part_start, part_offset)
        output.set_window!(rows_seen.to_i, emitted_i, mark_offset, part_offset, source_offset)
        plan.validate_source!
        yield output
        rows_seen = checked_add_rows(rows_seen, emitted)
      end
      nil
    end

    private def validate_compact_json_columnar_batch!(
      batch : CompactJsonColumnarBatch,
      mark : ParallelScanMark,
      rows_seen : UInt64,
      batch_rows : Int,
      part_start : UInt64,
    ) : UInt64
      emitted = batch.row_count.to_u64
      rows_left = mark.row_count - rows_seen
      expected = batch_rows.to_u64 < rows_left ? batch_rows.to_u64 : rows_left
      expected_mark_offset = rows_seen
      expected_part_offset = checked_add_rows(mark.part_row_offset, rows_seen)
      expected_source_offset = checked_add_rows(part_start, expected_part_offset)
      unless batch.part_index == mark.part_index && batch.mark_index == mark.mark_index &&
             batch.mark_row_offset == expected_mark_offset &&
             batch.part_row_offset == expected_part_offset &&
             batch.source_row_offset == expected_source_offset && emitted == expected
        raise CorruptPartError.new("Compact JSON worker emitted rows outside its assigned mark")
      end
      emitted
    end

    private def checked_columnar_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("Compact JSON columnar workspace or row offset overflows")
      end
      left + right
    end

    {% unless flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
      private def start_compact_json_columnar_worker(
        worker_index : Int,
        part_marks : Array(Array(Int32)),
        plans : Array(CompactStaticJsonAdvancedPartPlan),
        outputs : Array(CompactJsonColumnarBatch?),
        budgets : Array(BinaryCodecBudget?),
        part_starts : Array(UInt64),
        part_mark_starts : Array(Array(UInt64)),
        batch_rows : Int,
        channel : Channel(CompactJsonColumnarBatch),
        acknowledgement : Channel(Nil),
      ) : Fiber::ExecutionContext::Isolated
        Fiber::ExecutionContext::Isolated.new("Compact JSON columnar scan worker #{worker_index}") do
          run_compact_json_columnar_worker(part_marks, plans, outputs, budgets, part_starts,
            part_mark_starts, batch_rows, channel, acknowledgement)
        end
      end

      private def run_compact_json_columnar_worker(
        part_marks : Array(Array(Int32)),
        plans : Array(CompactStaticJsonAdvancedPartPlan),
        outputs : Array(CompactJsonColumnarBatch?),
        budgets : Array(BinaryCodecBudget?),
        part_starts : Array(UInt64),
        part_mark_starts : Array(Array(UInt64)),
        batch_rows : Int,
        channel : Channel(CompactJsonColumnarBatch),
        acknowledgement : Channel(Nil),
      ) : Nil
        part_marks.each_with_index do |marks, part_index|
          next if marks.empty?
          reader = @entries[part_index].reader.as(CompactPartTable)
          plan = plans[part_index]
          output = outputs[part_index] || raise(CorruptPartError.new("Compact JSON worker lost its output arena"))
          budget = budgets[part_index] || raise(CorruptPartError.new("Compact JSON worker lost its decode budget"))
          marks.each do |mark_index|
            mark_start = part_mark_starts[part_index][mark_index]
            reader.scan_compact_json_columnar_mark_into(mark_index, plan, budget, output,
              part_index, part_starts[part_index], mark_start)
            row_count = output.row_count.to_u64
            rows_seen = 0_u64
            while rows_seen < row_count
              rows_remaining = row_count - rows_seen
              emitted = batch_rows.to_u64 < rows_remaining ? batch_rows.to_u64 : rows_remaining
              mark_offset = rows_seen
              part_offset = checked_add_rows(mark_start, rows_seen)
              source_offset = checked_add_rows(part_starts[part_index], part_offset)
              output.set_window!(rows_seen.to_i, emitted.to_i, mark_offset, part_offset, source_offset)
              channel.send(output)
              acknowledgement.receive
              rows_seen = checked_add_rows(rows_seen, emitted)
            end
          end
        end
      rescue ex : Channel::ClosedError
        # A canceled coordinator closes the acknowledgement channel after
        # stopping delivery; no output remains borrowed after its callback.
      ensure
        channel.close
      end
    {% end %}
  end
end
