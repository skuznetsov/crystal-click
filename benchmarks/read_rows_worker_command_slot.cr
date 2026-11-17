module CrystalClickReadRowsScan
  alias WorkerJob = Proc(Int32, WorkerState, Nil)

  {% if flag?(:darwin) && !flag?(:gc_none) && compare_versions(Crystal::VERSION, "1.22.0") >= 0 %}
    # This one-producer/one-worker slot carries only the benchmark's synchronous
    # scan job. The isolated worker has no runnable fibers while waiting.
    private class WorkerCommandSlot
      # The arguments stay live on the stack above the GC_do_blocking boundary.
      # Its callback touches only the native condition, mutex and stack status.
      private struct BlockingWait
        property condition : Pointer(LibC::PthreadCondT)
        property mutex : Pointer(LibC::PthreadMutexT)
        property status : Int32

        def initialize(@condition, @mutex, @status)
        end
      end

      @mutex : Thread::Mutex
      @condition : Thread::ConditionVariable
      @job : WorkerJob?
      @closed : Bool

      def initialize
        @mutex = Thread::Mutex.new
        @condition = Thread::ConditionVariable.new
        @job = nil.as(WorkerJob?)
        @closed = false
      end

      def send(job : WorkerJob) : Nil
        @mutex.synchronize do
          raise ArgumentError.new("read_rows worker command slot is closed") if @closed
          raise ArgumentError.new("read_rows worker command slot is occupied") unless @job.nil?
          # Signal first so a signal error cannot leave undispatched work in
          # the slot. The receiver observes the job after this mutex unlocks.
          @condition.signal
          @job = job
        end
      end

      def receive? : WorkerJob?
        @mutex.synchronize do
          while @job.nil? && !@closed
            wait_locked
          end

          job = @job
          @job = nil
          job
        end
      end

      def close : Nil
        @mutex.synchronize do
          unless @closed
            # There is exactly one receiver for this slot.
            @condition.signal
            @closed = true
          end
        end
      end

      private def wait_locked : Nil
        record = BlockingWait.new(@condition.to_unsafe, @mutex.to_unsafe, 0_i32)
        LibGC.do_blocking(->(data : Void*) {
          wait = data.as(BlockingWait*)
          wait.value.status = LibC.pthread_cond_wait(wait.value.condition, wait.value.mutex)
          Pointer(Void).null
        }, pointerof(record).as(Void*))
        raise RuntimeError.from_os_error("pthread_cond_wait", Errno.new(record.status)) unless record.status == 0
      end
    end
  {% end %}
end
