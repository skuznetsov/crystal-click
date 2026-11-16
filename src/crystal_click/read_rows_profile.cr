module CrystalClick
  # Benchmark-only counters for the direct Wide read_rows runner. Call sites
  # are compiled out unless `-Dread_rows_profile` is enabled.
  module ReadRowsProfile
    class Worker
      getter index : Int32
      getter start_ns : Int64
      getter end_ns : Int64
      getter transport_ns : Int64
      getter checksum_ns : Int64
      getter lz4_ns : Int64
      getter frame_dispatch_ns : Int64
      getter materialize_copy_ns : Int64
      getter output_copy_ns : Int64
      getter checksum_calls : UInt64
      getter lz4_calls : UInt64
      getter materialize_copy_bytes : UInt64
      getter output_copy_bytes : UInt64
      getter transport_calls : UInt64
      getter transport_bytes : UInt64
      getter mmap_calls : UInt64
      getter munmap_calls : UInt64
      getter io_lifecycle_ns : Int64
      getter file_size_ns : Int64
      getter file_open_ns : Int64
      getter file_stat_ns : Int64
      getter file_close_ns : Int64
      getter file_size_calls : UInt64
      getter file_open_calls : UInt64
      getter file_stat_calls : UInt64
      getter file_close_calls : UInt64

      def initialize(@index : Int32)
        @start_ns = 0_i64
        @end_ns = 0_i64
        @transport_ns = 0_i64
        @checksum_ns = 0_i64
        @lz4_ns = 0_i64
        @frame_dispatch_ns = 0_i64
        @materialize_copy_ns = 0_i64
        @output_copy_ns = 0_i64
        @checksum_calls = 0_u64
        @lz4_calls = 0_u64
        @materialize_copy_bytes = 0_u64
        @output_copy_bytes = 0_u64
        @transport_calls = 0_u64
        @transport_bytes = 0_u64
        @mmap_calls = 0_u64
        @munmap_calls = 0_u64
        @io_lifecycle_ns = 0_i64
        @file_size_ns = 0_i64
        @file_open_ns = 0_i64
        @file_stat_ns = 0_i64
        @file_close_ns = 0_i64
        @file_size_calls = 0_u64
        @file_open_calls = 0_u64
        @file_stat_calls = 0_u64
        @file_close_calls = 0_u64
      end

      def mark_start(scan_started : Time::Instant) : Nil
        @start_ns = elapsed_since(scan_started)
      end

      def mark_end(scan_started : Time::Instant) : Nil
        @end_ns = elapsed_since(scan_started)
      end

      def add_mapping(ns : Int64, size : UInt64, successful : Bool) : Nil
        @transport_ns += ns
        @mmap_calls += 1_u64
        if successful
          @transport_calls += 1_u64
          @transport_bytes += size
        end
      end

      def add_unmapping(ns : Int64) : Nil
        @transport_ns += ns
        @munmap_calls += 1_u64
      end

      def add_checksum(ns : Int64) : Nil
        @checksum_ns += ns
        @checksum_calls += 1_u64
      end

      def add_lz4_call : Nil
        @lz4_calls += 1_u64
      end

      def add_lz4(ns : Int64) : Nil
        @lz4_ns += ns
      end

      def add_frame_dispatch(ns : Int64) : Nil
        @frame_dispatch_ns += ns
      end

      def add_materialize_copy(ns : Int64, bytes : UInt64) : Nil
        @materialize_copy_ns += ns
        @materialize_copy_bytes += bytes
      end

      def add_output_copy(ns : Int64, bytes : UInt64) : Nil
        @output_copy_ns += ns
        @output_copy_bytes += bytes
      end

      def add_file_size(ns : Int64) : Nil
        @file_size_ns += ns
        @io_lifecycle_ns += ns
        @file_size_calls += 1_u64
      end

      def add_file_open(ns : Int64) : Nil
        @file_open_ns += ns
        @io_lifecycle_ns += ns
        @file_open_calls += 1_u64
      end

      def add_file_stat(ns : Int64) : Nil
        @file_stat_ns += ns
        @io_lifecycle_ns += ns
        @file_stat_calls += 1_u64
      end

      def add_file_close(ns : Int64) : Nil
        @file_close_ns += ns
        @io_lifecycle_ns += ns
        @file_close_calls += 1_u64
      end

      private def elapsed_since(started : Time::Instant) : Int64
        elapsed = (Time.instant - started).total_nanoseconds.to_i64
        elapsed > 0 ? elapsed : 0_i64
      end
    end

    class Scan
      class SharedMMap
        getter open_ns : Int64
        getter close_ns : Int64
        getter map_calls : UInt64
        getter unmap_calls : UInt64
        getter mapped_bytes : UInt64

        def initialize
          @open_ns = 0_i64
          @close_ns = 0_i64
          @map_calls = 0_u64
          @unmap_calls = 0_u64
          @mapped_bytes = 0_u64
        end

        def record_open(ns : Int64, calls : UInt64, bytes : UInt64) : Nil
          @open_ns += ns
          @map_calls += calls
          @mapped_bytes += bytes
        end

        def record_close(ns : Int64, calls : UInt64) : Nil
          @close_ns += ns
          @unmap_calls += calls
        end
      end

      getter workers : Array(Worker)
      getter launch_ns : Int64
      getter join_ns : Int64
      getter launch_calls : UInt64
      getter join_calls : UInt64
      getter shared_mmap : SharedMMap

      def initialize(worker_count : Int32)
        @workers = Array(Worker).new(worker_count) { |index| Worker.new(index.to_i32) }
        @launch_ns = 0_i64
        @join_ns = 0_i64
        @launch_calls = 0_u64
        @join_calls = 0_u64
        @shared_mmap = SharedMMap.new
      end

      def record_launch(ns : Int64) : Nil
        @launch_ns += ns
        @launch_calls += 1_u64
      end

      def record_join(ns : Int64) : Nil
        @join_ns += ns
        @join_calls += 1_u64
      end
    end

    @[ThreadLocal]
    @@current_worker : Worker? = nil

    def self.current_worker? : Worker?
      @@current_worker
    end

    def self.with_worker(worker : Worker, & : -> T) : T forall T
      previous = @@current_worker
      @@current_worker = worker
      yield
    ensure
      @@current_worker = previous
    end

    def self.elapsed_ns_between(started : Time::Instant, finished : Time::Instant) : Int64
      elapsed = (finished - started).total_nanoseconds.to_i64
      elapsed > 0 ? elapsed : 0_i64
    end
  end
end
