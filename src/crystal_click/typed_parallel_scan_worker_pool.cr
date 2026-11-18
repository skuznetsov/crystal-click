{% unless flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
  module CrystalClick
    # A bounded process-wide cohort for ordinary direct Wide UInt64 scans.
    # The cohort retains only its isolated contexts and reusable handshake
    # channels. Every command and output is drained before a lease is returned.
    # :nodoc:
    class TypedParallelScanWorkerPool
      MAX_WORKERS = 4

      alias WorkerIdentity = {UInt64, UInt64, UInt64, UInt64}

      class Job
        getter id : UInt64
        getter part_marks : Array(Array(Int32))
        getter readers : Array(WidePartTable?)
        getter image_registry : WideScanImageRegistry
        getter batch_rows : Int32
        getter column_count : Int32

        def initialize(
          @id : UInt64,
          @part_marks : Array(Array(Int32)),
          @readers : Array(WidePartTable?),
          @image_registry : WideScanImageRegistry,
          @batch_rows : Int32,
          @column_count : Int32,
        )
        end
      end

      struct Acknowledgement
        getter job_id : UInt64
        getter cancel : Bool

        def initialize(@job_id : UInt64, @cancel : Bool)
        end
      end

      struct Message
        getter job_id : UInt64
        getter batch : WidePartTableBatch?
        getter error : Exception?
        getter terminal : Bool

        def initialize(@job_id : UInt64, @batch : WidePartTableBatch?, @error : Exception?, @terminal : Bool)
        end

        def self.batch(job_id : UInt64, batch : WidePartTableBatch) : self
          new(job_id, batch, nil, false)
        end

        def self.terminal(job_id : UInt64, error : Exception?) : self
          new(job_id, nil, error, true)
        end
      end

      private class Worker
        getter commands : Channel(Job)
        getter output : Channel(Message)
        getter acknowledgements : Channel(Acknowledgement)
        getter ready : Channel(Exception?)
        property context : Fiber::ExecutionContext::Isolated?

        def initialize
          @commands = Channel(Job).new(1)
          @output = Channel(Message).new(1)
          @acknowledgements = Channel(Acknowledgement).new
          @ready = Channel(Exception?).new(1)
          @context = nil.as(Fiber::ExecutionContext::Isolated?)
        end

        def healthy? : Bool
          context = @context
          !!context && context.running? && !@commands.closed? && !@output.closed? && !@acknowledgements.closed?
        end
      end

      @@global : TypedParallelScanWorkerPool = new

      @workers : Array(Worker)
      @mutex : Thread::Mutex
      @leased : Bool
      @next_job_id : UInt64

      def self.global : TypedParallelScanWorkerPool
        @@global
      end

      def initialize
        @workers = [] of Worker
        @mutex = Thread::Mutex.new
        @leased = false
        @next_job_id = 0_u64
      end

      # Acquire a nonblocking exclusive lease. Context startup occurs after the
      # short reservation lock is released. A failed startup leaves any existing
      # healthy slots available and lets the caller use its scan-owned workers.
      def try_acquire(worker_count : Int) : Bool
        return false if worker_count < 2 || worker_count > MAX_WORKERS
        return false unless @mutex.try_lock

        already_leased = @leased
        @leased = true unless already_leased
        @mutex.unlock
        return false if already_leased

        begin
          ensure_workers(worker_count)
          true
        rescue
          release
          false
        end
      end

      def release : Nil
        @mutex.synchronize do
          @leased = false
        end
        nil
      end

      def next_job_id : UInt64
        @next_job_id += 1_u64
        @next_job_id
      end

      def worker_identity(worker_index : Int) : WorkerIdentity
        worker = @workers[worker_index]
        context = worker.context || raise(CorruptPartError.new("retained typed scan worker has no context"))
        {
          context.object_id.to_u64,
          worker.commands.object_id.to_u64,
          worker.output.object_id.to_u64,
          worker.acknowledgements.object_id.to_u64,
        }
      end

      def dispatch(worker_index : Int, job : Job) : Nil
        @workers[worker_index].commands.send(job)
        nil
      end

      def receive(worker_index : Int) : Message?
        @workers[worker_index].output.receive?
      end

      def acknowledge(worker_index : Int, job_id : UInt64, cancel : Bool) : Nil
        @workers[worker_index].acknowledgements.send(Acknowledgement.new(job_id, cancel))
        nil
      end

      # Retire a slot after observing a stale job tag or a closed output. Closing
      # every handshake wakes a worker whether it is parked, sending, or waiting
      # for acknowledgement; wait before the caller closes its scan mappings.
      def retire_worker(worker_index : Int) : Nil
        stop_worker(@workers[worker_index])
        nil
      end

      private def ensure_workers(worker_count : Int) : Nil
        original_count = @workers.size
        begin
          while @workers.size < worker_count
            @workers << start_worker(@workers.size)
          end

          @workers.each_with_index do |worker, index|
            next if worker.healthy?

            stop_worker(worker)
            @workers[index] = start_worker(index)
          end
        rescue ex : Exception
          while @workers.size > original_count
            stop_worker(@workers.pop)
          end
          raise ex
        end
        nil
      end

      private def start_worker(index : Int) : Worker
        worker = Worker.new
        commands = worker.commands
        output = worker.output
        ready = worker.ready

        context = Fiber::ExecutionContext::Isolated.new("crystal-click retained typed scan worker #{index}") do
          startup_sent = false
          begin
            ready.send(nil)
            startup_sent = true
            worker_loop(index, worker)
          rescue ex : Exception
            unless startup_sent
              begin
                ready.send(ex)
              rescue
              end
            else
              raise ex
            end
          ensure
            ready.close
            commands.close
            output.close
            worker.acknowledgements.close
          end
        end
        worker.context = context

        begin
          startup_error = ready.receive?
          raise startup_error.not_nil! if startup_error
          raise WorkerContextExitError.new(index) unless context.running?
          worker
        rescue ex : Exception
          stop_worker(worker)
          raise ex
        end
      end

      private def stop_worker(worker : Worker) : Nil
        begin
          worker.commands.close
        rescue
        end
        begin
          worker.output.close
        rescue
        end
        begin
          worker.acknowledgements.close
        rescue
        end
        if context = worker.context
          begin
            context.wait
          rescue
          ensure
            worker.context = nil
          end
        end
        nil
      end

      private def worker_loop(index : Int, worker : Worker) : Nil
        command = nil.as(Job?)
        loop do
          command = worker.commands.receive?
          break unless command
          execute_one_job(index, worker, command)
          # Do not leave a previous scan's readers, marks, or image registry in
          # the parked worker loop's stack while the next command is pending.
          command = nil
        end
        nil
      end

      private def execute_one_job(index : Int, worker : Worker, job : Job) : Nil
        primary_error = nil.as(Exception?)
        workspace = nil.as(WideUInt64ScanWorkspace?)

        begin
          workspace_pool = WideUInt64ScanWorkspacePool.global
          workspace = workspace_pool.try_acquire(index, job.column_count) || WideUInt64ScanWorkspace.new(job.column_count)

          job.part_marks.each_with_index do |marks, part_index|
            next if marks.empty?
            reader = job.readers[part_index] || raise(CorruptPartError.new("retained Wide scan lost an admitted reader"))
            image = job.image_registry.acquire(part_index)
            part_error = nil.as(Exception?)
            begin
              reader.scan_typed_uint64_mark_indices(marks, job.batch_rows, image, workspace) do |batch|
                worker.output.send(Message.batch(job.id, batch))
                acknowledgement = worker.acknowledgements.receive?
                unless acknowledgement
                  raise CorruptPartError.new("retained Wide scan acknowledgement channel closed")
                end
                unless acknowledgement.job_id == job.id
                  raise CorruptPartError.new("retained Wide scan received a stale acknowledgement")
                end
                raise RetainedScanCancelled.new if acknowledgement.cancel
              end
            rescue ex : Exception
              part_error = ex
            ensure
              begin
                job.image_registry.release(part_index)
              rescue cleanup_error : Error
                part_error = with_cleanup_error(part_error, cleanup_error)
              end
            end
            raise part_error.not_nil! if part_error
          end
        rescue ex : RetainedScanCancelled
          # The caller will consume the terminal message after cancelling this
          # worker's current batch.
        rescue ex : Exception
          primary_error = ex
        ensure
          if workspace
            begin
              WideUInt64ScanWorkspacePool.global.release(index, workspace)
            rescue cleanup_error : Error
              primary_error = with_cleanup_error(primary_error, cleanup_error)
            end
          end
        end

        begin
          worker.output.send(Message.terminal(job.id, primary_error))
        rescue ex : Channel::ClosedError
          # A worker that is being retired has no current caller to notify.
        end
        nil
      end

      private def with_cleanup_error(primary : Exception?, cleanup : Error) : Exception
        if error = primary
          MMapCleanupError.new(error, cleanup)
        else
          cleanup
        end
      end

      private class RetainedScanCancelled < Exception
      end

      private class WorkerContextExitError < Exception
        def initialize(index : Int)
          super("retained typed scan worker #{index} exited before completing its lifecycle handshake")
        end
      end
    end
  end
{% end %}
