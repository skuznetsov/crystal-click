module CrystalClickReadRowsScan
  alias WorkerJob = Proc(Int32, WorkerState, Nil)

  # Owns one inline W1 worker or a stable set of isolated W4 workers for a
  # complete direct Wide reader session.
  class WorkerPool
    struct Startup
      getter identity : WorkerState::Identity?
      getter error : Exception?

      def initialize(@identity : WorkerState::Identity?, @error : Exception?)
      end
    end

    struct Completion
      getter identity : WorkerState::Identity?
      getter error : Exception?

      def initialize(@identity : WorkerState::Identity?, @error : Exception?)
      end
    end

    private class Runtime
      getter startup : Channel(Startup)
      getter commands : Channel(WorkerJob)
      getter completions : Channel(Completion)
      {% unless flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
        property context : Fiber::ExecutionContext::Isolated?
      {% end %}

      def initialize
        @startup = Channel(Startup).new(1)
        @commands = Channel(WorkerJob).new(1)
        @completions = Channel(Completion).new(1)
        {% unless flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
          @context = nil.as(Fiber::ExecutionContext::Isolated?)
        {% end %}
      end
    end

    getter worker_count : Int32
    getter context_create_count : Int32
    getter context_join_count : Int32
    getter dispatch_count : UInt64
    getter identities : Array(WorkerState::Identity)

    @inline_state : WorkerState?
    @runtimes : Array(Runtime)
    @closed : Bool
    @running : Bool

    def initialize(worker_count : Int32, mark_rows : Int32)
      @worker_count = worker_count
      @inline_state = nil.as(WorkerState?)
      @runtimes = [] of Runtime
      @identities = [] of WorkerState::Identity
      @context_create_count = 0_i32
      @context_join_count = 0_i32
      @dispatch_count = 0_u64
      @closed = false
      @running = false

      unless @worker_count == 1 || @worker_count == 4
        raise ArgumentError.new("read_rows worker count must be 1 or 4")
      end
      raise ArgumentError.new("mark rows must be positive") unless mark_rows > 0

      if @worker_count == 1
        state = WorkerState.new(mark_rows)
        @inline_state = state
        {% if flag?(:read_rows_profile) %}
          @identities << state.identity
        {% end %}
      else
        begin
          {% if flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
            raise CrystalClick::UnsupportedFormatError.new("four-worker read_rows requires isolated execution contexts")
          {% else %}
            @worker_count.times do |worker_index|
              start_worker(worker_index.to_i32, mark_rows)
            end
          {% end %}
        rescue ex : Exception
          begin
            close
          rescue cleanup_error : Exception
            raise WorkerPoolError.new(ex, cleanup_error)
          end
          raise ex
        end
      end
    end

    # Runs one job on every retained worker and drains every dispatched result
    # before returning or raising the first job error.
    def run(work : WorkerJob, scan_profile : CrystalClick::ReadRowsProfile::Scan? = nil) : Nil
      raise ArgumentError.new("read_rows worker session is closed") if @closed
      raise ArgumentError.new("read_rows worker session already has an active scan") if @running

      @running = true
      {% if flag?(:read_rows_profile) %}
        @dispatch_count += 1_u64
      {% end %}
      begin
        if state = @inline_state
          begin
            work.call(0_i32, state)
          ensure
            {% if flag?(:read_rows_profile) %}
              @identities[0] = state.identity
            {% end %}
          end
          return nil
        end

        dispatch_error = nil.as(Exception?)
        dispatched = 0
        {% if flag?(:read_rows_profile) %}
          dispatch_started = Time.instant if scan_profile
        {% end %}
        begin
          @runtimes.each do |runtime|
            begin
              runtime.commands.send(work)
              dispatched += 1
            rescue ex : Exception
              dispatch_error ||= ex
              break
            end
          end
        ensure
          {% if flag?(:read_rows_profile) %}
            if profile = scan_profile
              profile.record_launch(elapsed_ns(dispatch_started.not_nil!))
            end
          {% end %}
        end

        first_error = dispatch_error
        {% if flag?(:read_rows_profile) %}
          completion_started = Time.instant if scan_profile && dispatched > 0
        {% end %}
        dispatched.times do |index|
          begin
            completion = @runtimes[index].completions.receive?
            if completion
              {% if flag?(:read_rows_profile) %}
                @identities[index] = completion.identity || raise(WorkerContextExitError.new(index.to_i32))
              {% end %}
              first_error ||= completion.error
            else
              first_error ||= WorkerContextExitError.new(index.to_i32)
            end
          rescue ex : Exception
            first_error ||= ex
          end
        end
        {% if flag?(:read_rows_profile) %}
          if profile = scan_profile
            profile.record_join(elapsed_ns(completion_started.not_nil!)) if dispatched > 0
          end
        {% end %}

        raise first_error if first_error
        nil
      ensure
        @running = false
      end
    end

    # Closing command channels wakes every started worker, including workers
    # whose startup handshake failed. Every created context is joined before
    # the caller releases the shared read-only mappings.
    def close : Nil
      return nil if @closed
      @closed = true
      first_error = nil.as(Exception?)

      @runtimes.each do |runtime|
        begin
          runtime.commands.close
        rescue ex : Exception
          first_error ||= ex
        end
      end

      @runtimes.each do |runtime|
        {% unless flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
          context = runtime.context
          next unless context
          begin
            context.wait
          rescue ex : Exception
            first_error ||= ex
          ensure
            {% if flag?(:read_rows_profile) %}
              @context_join_count += 1_i32
            {% end %}
          end
        {% end %}
      end

      @inline_state = nil
      raise first_error if first_error
      nil
    end

    {% unless flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
    private def start_worker(index : Int32, mark_rows : Int32) : Nil
      runtime = Runtime.new
      @runtimes << runtime
      startup = runtime.startup
      commands = runtime.commands
      completions = runtime.completions

      context = Fiber::ExecutionContext::Isolated.new("read_rows_scan worker #{index}") do
        startup_sent = false
        begin
          state = WorkerState.new(mark_rows)
          {% if flag?(:read_rows_profile) %}
            startup.send(Startup.new(state.identity, nil))
          {% else %}
            startup.send(Startup.new(nil, nil))
          {% end %}
          startup_sent = true

          loop do
            job = commands.receive?
            break unless job

            error = nil.as(Exception?)
            begin
              job.call(index, state)
            rescue ex : Exception
              error = ex
            end
            {% if flag?(:read_rows_profile) %}
              completions.send(Completion.new(state.identity, error))
            {% else %}
              completions.send(Completion.new(nil, error))
            {% end %}
          end
        rescue ex : Exception
          unless startup_sent
            begin
              startup.send(Startup.new(nil, ex))
            rescue
            end
          end
          raise ex if startup_sent
        ensure
          startup.close
          completions.close
        end
      end
      runtime.context = context
      {% if flag?(:read_rows_profile) %}
        @context_create_count += 1_i32
      {% end %}

      startup_result = startup.receive?
      raise WorkerContextExitError.new(index) unless startup_result
      raise startup_result.error.not_nil! if startup_result.error
      {% if flag?(:read_rows_profile) %}
        @identities << (startup_result.identity || raise(WorkerContextExitError.new(index)))
      {% end %}
      nil
    end
    {% end %}

    private def elapsed_ns(started : Time::Instant) : Int64
      elapsed = (Time.instant - started).total_nanoseconds.to_i64
      elapsed > 0 ? elapsed : 1_i64
    end
  end

  private class WorkerContextExitError < Exception
    def initialize(index : Int32)
      super("read_rows worker #{index} exited before completing its lifecycle handshake")
    end
  end

  private class WorkerPoolError < Exception
    def initialize(primary : Exception, cleanup : Exception)
      super("Wide read_rows worker setup failed: #{primary.message || primary.class.name}; teardown failed: #{cleanup.message || cleanup.class.name}")
    end
  end
end
