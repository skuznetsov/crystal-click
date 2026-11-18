{% unless flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
  module CrystalClick
    class TypedPartTable
      private def run_retained_parallel_workers(
        pool : TypedParallelScanWorkerPool,
        worker_count : Int,
        schedule : Array(ParallelScanMark),
        worker_marks : Array(Array(Array(Int32))),
        readers : Array(WidePartTable?),
        image_registry : WideScanImageRegistry,
        part_starts : Array(UInt64),
        batch_rows : Int,
        & : WidePartTableBatch -> Nil
      ) : Nil
        job_id = pool.next_job_id
        terminal_received = Array(Bool).new(worker_count, false)
        dispatched = 0
        pending_worker = nil.as(Int32?)
        primary_error = nil.as(Exception?)

        begin
          worker_count.times do |worker_index|
            job = TypedParallelScanWorkerPool::Job.new(
              job_id,
              worker_marks[worker_index],
              readers,
              image_registry,
              batch_rows.to_i32,
              @columns.size.to_i32,
            )
            pool.dispatch(worker_index, job)
            dispatched += 1
          end

          schedule.each do |mark|
            rows_seen = 0_u64
            output = pool.receive(mark.worker_index)
            while rows_seen < mark.row_count
              message = output || begin
                pool.retire_worker(mark.worker_index)
                terminal_received[mark.worker_index] = true
                raise CorruptPartError.new("retained parallel worker closed before completing a selected mark")
              end
              if message.terminal
                terminal_received[mark.worker_index] = true
                unless message.job_id == job_id
                  pool.retire_worker(mark.worker_index)
                  raise CorruptPartError.new("retained parallel worker returned a terminal for another job")
                end
                raise message.error.not_nil! if message.error
                raise CorruptPartError.new("retained parallel worker completed before its selected mark")
              end

              pending_worker = mark.worker_index
              unless message.job_id == job_id
                pending_worker = nil
                pool.retire_worker(mark.worker_index)
                terminal_received[mark.worker_index] = true
                raise CorruptPartError.new("retained parallel worker returned a batch for another job")
              end
              batch = message.batch || raise(CorruptPartError.new("retained parallel worker emitted an empty message"))
              emitted_rows = validate_parallel_scan_batch!(batch, mark, rows_seen, batch_rows)

              yield rebase_batch!(batch, mark.part_index, part_starts[mark.part_index])
              pool.acknowledge(mark.worker_index, job_id, false)
              pending_worker = nil
              rows_seen = checked_add_rows(rows_seen, emitted_rows)
              output = pool.receive(mark.worker_index) if rows_seen < mark.row_count
            end
          end

          worker_count.times do |worker_index|
            next if terminal_received[worker_index]
            message = pool.receive(worker_index)
            unless message
              pool.retire_worker(worker_index)
              terminal_received[worker_index] = true
              raise CorruptPartError.new("retained parallel worker exited before its job terminal")
            end
            unless message.job_id == job_id
              terminal_received[worker_index] = true
              pool.retire_worker(worker_index)
              raise CorruptPartError.new("retained parallel worker returned a message for another job")
            end
            unless message.terminal
              pending_worker = worker_index.to_i32
              raise CorruptPartError.new("retained parallel worker left an unconsumed batch")
            end
            terminal_received[worker_index] = true
            raise message.error.not_nil! if message.error
          end
        rescue ex : Exception
          primary_error = ex
        ensure
          if dispatched > 0 && terminal_received.any? { |received| !received }
            cancellation_error = cancel_retained_parallel_workers(
              pool,
              job_id,
              dispatched,
              terminal_received,
              pending_worker,
            )
            primary_error ||= cancellation_error
          end
        end

        raise primary_error.not_nil! if primary_error
        nil
      end

      private def cancel_retained_parallel_workers(
        pool : TypedParallelScanWorkerPool,
        job_id : UInt64,
        dispatched : Int,
        terminal_received : Array(Bool),
        pending_worker : Int32?,
      ) : Exception?
        first_error = nil.as(Exception?)
        if worker_index = pending_worker
          begin
            pool.acknowledge(worker_index, job_id, true)
          rescue ex : Exception
            first_error ||= ex
          end
        end

        dispatched.times do |worker_index|
          next if terminal_received[worker_index]
          loop do
            message = pool.receive(worker_index)
            unless message
              pool.retire_worker(worker_index)
              terminal_received[worker_index] = true
              first_error ||= CorruptPartError.new("retained parallel worker exited without its job terminal")
              break
            end
            unless message.terminal
              unless message.job_id == job_id
                terminal_received[worker_index] = true
                pool.retire_worker(worker_index)
                first_error ||= CorruptPartError.new("retained parallel worker returned a batch for another job during cancellation")
                break
              end
              begin
                pool.acknowledge(worker_index, message.job_id, true)
              rescue ex : Exception
                first_error ||= ex
              end
              next
            end

            terminal_received[worker_index] = true
            unless message.job_id == job_id
              pool.retire_worker(worker_index)
              first_error ||= CorruptPartError.new("retained parallel worker returned a terminal for another job")
            end
            first_error ||= message.error
            break
          end
        end
        first_error
      end
    end
  end
{% end %}
