module CrystalClick
  # One bounded process-wide cohort avoids retaining a table, mapped part,
  # or native worker. A busy slot always falls back to scan-local storage.
  # :nodoc:
  class WideUInt64ScanWorkspacePool
    MAX_CACHED_WORKERS                  = 4
    MAX_CACHED_PAYLOAD_BYTES_PER_WORKER = 512 * 1024

    @@global : WideUInt64ScanWorkspacePool = new

    @workspaces : Array(WideUInt64ScanWorkspace?)
    @leased : Array(Bool)
    @mutex : Thread::Mutex

    def self.global : WideUInt64ScanWorkspacePool
      @@global
    end

    def initialize
      @workspaces = Array(WideUInt64ScanWorkspace?).new(MAX_CACHED_WORKERS, nil)
      @leased = Array(Bool).new(MAX_CACHED_WORKERS, false)
      @mutex = Thread::Mutex.new
    end

    # Return a cached workspace only when its worker slot is idle. This lock is
    # held only while reading or changing the slot; callers never wait for a
    # workspace held by a nested or concurrent scan.
    def try_acquire(worker_index : Int, column_count : Int) : WideUInt64ScanWorkspace?
      return nil if worker_index < 0 || worker_index >= MAX_CACHED_WORKERS

      @mutex.synchronize do
        if @leased[worker_index]
          nil
        else
          workspace = @workspaces[worker_index]
          if workspace.nil? || workspace.column_count != column_count
            workspace = WideUInt64ScanWorkspace.new(column_count)
            @workspaces[worker_index] = workspace
          end
          @leased[worker_index] = true
          workspace
        end
      end
    end

    # Called only after the worker has stopped using the workspace. A decoded
    # frame larger than the per-slot cap is dropped instead of kept.
    def release(worker_index : Int, workspace : WideUInt64ScanWorkspace) : Nil
      return nil if worker_index < 0 || worker_index >= MAX_CACHED_WORKERS

      @mutex.synchronize do
        if @leased[worker_index] && (cached = @workspaces[worker_index]) && cached.same?(workspace)
          if workspace.retained_payload_bytes > MAX_CACHED_PAYLOAD_BYTES_PER_WORKER.to_u64
            @workspaces[worker_index] = nil
          end
          @leased[worker_index] = false
        end
      end
      nil
    end
  end
end
