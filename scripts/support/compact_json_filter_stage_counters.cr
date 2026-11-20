module CrystalClick
  # Compile-gated counters for the isolated Compact JSON filter-stage probe.
  # Every hook records once per stage span; no shared counter lock is taken per
  # value. Worker elapsed sums are descriptive and are not scan wall time.
  module CompactJSONFilterStageCounters
    @@mutex = Mutex.new
    @@calls = Hash(String, UInt64).new(0_u64)
    @@elapsed_ns = Hash(String, UInt64).new(0_u64)
    @@rows = Hash(String, UInt64).new(0_u64)
    @@bytes = Hash(String, UInt64).new(0_u64)
    @@thread_elapsed_ns = Hash(Tuple(String, UInt64), UInt64).new(0_u64)
    @@metrics = Hash(Tuple(String, String), UInt64).new(0_u64)

    def self.reset! : Nil
      @@mutex.synchronize do
        @@calls.clear
        @@elapsed_ns.clear
        @@rows.clear
        @@bytes.clear
        @@thread_elapsed_ns.clear
        @@metrics.clear
      end
      nil
    end

    def self.record!(
      name : String,
      elapsed_ns : UInt64,
      rows : UInt64 = 0_u64,
      bytes : UInt64 = 0_u64,
      metrics : Hash(String, UInt64) = Hash(String, UInt64).new,
      calls : UInt64 = 1_u64,
    ) : Nil
      thread_id = Thread.current.object_id.to_u64
      @@mutex.synchronize do
        @@calls[name] += calls
        @@elapsed_ns[name] += elapsed_ns
        @@rows[name] += rows
        @@bytes[name] += bytes
        @@thread_elapsed_ns[{name, thread_id}] += elapsed_ns
        metrics.each { |key, value| @@metrics[{name, key}] += value }
      end
      nil
    end

    def self.snapshot(worker_thread_ids : Array(UInt64)) : Hash(String, JSON::Any)
      @@mutex.synchronize do
        stages = Hash(String, JSON::Any).new
        worker_stage_union = Array(UInt64).new(worker_thread_ids.size, 0_u64)
        worker_mark_decode = Array(UInt64).new(worker_thread_ids.size, 0_u64)
        nested_stages = ["copy_data_parse", "old_data_parse", "copy_batch_append_sampled", "worker_mark_decode"]

        @@calls.each_key do |name|
          worker_elapsed = Hash(String, JSON::Any).new
          coordinator_elapsed = 0_u64
          @@thread_elapsed_ns.each do |key, elapsed|
            next unless key[0] == name
            if index = worker_thread_ids.index(key[1])
              worker_elapsed[index.to_s] = JSON::Any.new(elapsed.to_i64)
              if name == "worker_mark_decode"
                worker_mark_decode[index] += elapsed
              elsif !nested_stages.includes?(name)
                worker_stage_union[index] += elapsed
              end
            else
              coordinator_elapsed += elapsed
            end
          end

          stage_metrics = Hash(String, JSON::Any).new
          @@metrics.each do |key, value|
            stage_metrics[key[1]] = JSON::Any.new(value.to_i64) if key[0] == name
          end
          stages[name] = JSON::Any.new({
            "calls"                   => JSON::Any.new(@@calls[name].to_i64),
            "rows"                    => JSON::Any.new(@@rows[name].to_i64),
            "bytes"                   => JSON::Any.new(@@bytes[name].to_i64),
            "elapsed_ns"              => JSON::Any.new(@@elapsed_ns[name].to_i64),
            "coordinator_elapsed_ns"  => JSON::Any.new(coordinator_elapsed.to_i64),
            "worker_elapsed_ns_by_id" => JSON::Any.new(worker_elapsed),
            "metrics"                 => JSON::Any.new(stage_metrics),
          })
        end

        append_estimate = @@metrics[{"copy_batch_append_sampled", "estimated_elapsed_ns"}]
        if stages["copy_data_verify_and_append"]?
          total = @@elapsed_ns["copy_data_verify_and_append"]
          parse = @@elapsed_ns["copy_data_parse"]
          deductions = parse + append_estimate
          exclusive = total > deductions ? total - deductions : 0_u64
          stages["copy_data_verify_and_append"].as_h["estimated_verify_excluding_parse_and_append_ns"] =
            JSON::Any.new(exclusive.to_i64)
        end
        if stages["old_copy_row_decode_and_append"]?
          total = @@elapsed_ns["old_copy_row_decode_and_append"]
          exclusive = total > append_estimate ? total - append_estimate : 0_u64
          stages["old_copy_row_decode_and_append"].as_h["estimated_decode_excluding_append_ns"] =
            JSON::Any.new(exclusive.to_i64)
        end
        if stages["old_data_verify"]?
          total = @@elapsed_ns["old_data_verify"]
          parse = @@elapsed_ns["old_data_parse"]
          exclusive = total > parse ? total - parse : 0_u64
          stages["old_data_verify"].as_h["estimated_verify_excluding_parse_ns"] =
            JSON::Any.new(exclusive.to_i64)
        end

        contributions = [] of JSON::Any
        summed_union = 0_u64
        max_union = 0_u64
        summed_mark_decode = 0_u64
        max_mark_decode = 0_u64
        slowest_mark_decode_worker = nil.as(Int32?)
        worker_thread_ids.size.times do |worker|
          union = worker_stage_union[worker]
          mark_decode = worker_mark_decode[worker]
          summed_union += union
          summed_mark_decode += mark_decode
          max_union = Math.max(max_union, union)
          if mark_decode > max_mark_decode
            max_mark_decode = mark_decode
            slowest_mark_decode_worker = worker.to_i32
          end
          contributions << JSON::Any.new({
            "worker"                       => JSON::Any.new(worker),
            "named_stage_union_elapsed_ns" => JSON::Any.new(union.to_i64),
            "mark_decode_elapsed_ns"       => JSON::Any.new(mark_decode.to_i64),
          })
        end
        workers = JSON::Any.new({
          "contributions"                       => JSON::Any.new(contributions),
          "summed_named_stage_union_elapsed_ns" => JSON::Any.new(summed_union.to_i64),
          "max_named_stage_union_elapsed_ns"    => JSON::Any.new(max_union.to_i64),
          "summed_mark_decode_elapsed_ns"       => JSON::Any.new(summed_mark_decode.to_i64),
          "max_mark_decode_elapsed_ns"          => JSON::Any.new(max_mark_decode.to_i64),
          "slowest_mark_decode_worker"          => slowest_mark_decode_worker ? JSON::Any.new(slowest_mark_decode_worker) : JSON::Any.new(nil),
        })
        {
          "elapsed_basis"   => JSON::Any.new("per-thread elapsed; worker sums are not scan wall time"),
          "append_sampling" => JSON::Any.new("one of every 32 append calls, phase rotated by mark; estimates scaled per method call"),
          "stages"          => JSON::Any.new(stages),
          "workers"         => workers,
        }
      end
    end
  end
end
