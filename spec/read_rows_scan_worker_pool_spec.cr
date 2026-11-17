require "./spec_helper"
require "../src/crystal_click/read_rows_profile"
require "../benchmarks/read_rows_scan_worker_state"
require "../benchmarks/read_rows_scan_worker_pool"

alias ReadRowsWorkerObservation = {Int32, UInt64, UInt64, UInt64, Int32, UInt64, Int32}

describe CrystalClickReadRowsScan::WorkerPool do
  it "keeps four isolated workers and both backing buffers across jobs" do
    {% unless flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
      pool = CrystalClickReadRowsScan::WorkerPool.new(4, 8)
      begin
        first_run = Channel(ReadRowsWorkerObservation).new(4)
        second_run = Channel(ReadRowsWorkerObservation).new(4)

        observe = ->(destination : Channel(ReadRowsWorkerObservation), requested_bytes : Int32) do
          ->(index : Int32, state : CrystalClickReadRowsScan::WorkerState) do
            decoded = state.decode_workspace.buffer_for(requested_bytes)
            destination.send({
              index,
              state.object_id.to_u64,
              Thread.current.object_id.to_u64,
              state.mark_scratch.to_unsafe.address.to_u64,
              state.mark_scratch.size,
              decoded.to_unsafe.address.to_u64,
              decoded.size,
            })
            nil
          end
        end

        pool.run(observe.call(first_run, 256_i32))
        GC.collect
        pool.run(observe.call(second_run, 64_i32))
        first = Array(ReadRowsWorkerObservation).new(4) { first_run.receive }.sort_by(&.[0])
        second = Array(ReadRowsWorkerObservation).new(4) { second_run.receive }.sort_by(&.[0])

        first.map(&.[0]).should eq([0, 1, 2, 3])
        second.map(&.[0]).should eq([0, 1, 2, 3])
        first.map(&.[1]).uniq.size.should eq(4)
        first.map(&.[2]).uniq.size.should eq(4)
        first.map(&.[3]).uniq.size.should eq(4)
        first.map(&.[5]).uniq.size.should eq(4)
        first.each do |before|
          after = second[before[0]]
          after[1].should eq(before[1])
          after[2].should eq(before[2])
          after[3].should eq(before[3])
          after[4].should eq(8)
          after[5].should eq(before[5])
          after[6].should eq(256)
        end

        {% if flag?(:read_rows_profile) %}
          pool.context_create_count.should eq(4)
          pool.context_join_count.should eq(0)
          pool.dispatch_count.should eq(2_u64)
          identities = pool.identities
          identities.size.should eq(4)
          identities.map(&.worker).uniq.size.should eq(4)
          identities.map(&.mark_scratch).uniq.size.should eq(4)
          identities.map(&.decode_workspace).uniq.size.should eq(4)
          identities.map(&.decode_buffer).uniq.size.should eq(4)
          identities.each do |identity|
            identity.mark_scratch_capacity.should eq(8_i64)
            identity.decode_buffer.should_not eq(0_u64)
            identity.decode_buffer_capacity.should eq(256_i64)
          end
        {% end %}
      ensure
        pool.close
      end

      {% if flag?(:read_rows_profile) %}
        pool.context_join_count.should eq(4)
      {% end %}
    {% end %}
  end

  it "drains dispatched work after a worker fails and accepts the next job" do
    {% unless flag?(:without_mt) || (flag?(:preview_mt) && !flag?(:execution_context)) %}
      pool = CrystalClickReadRowsScan::WorkerPool.new(4, 2)
      worker_one_started = Channel(Nil).new(1)
      worker_zero_failed = Channel(Nil).new(1)
      release_worker_one = Channel(Bool).new(1)
      worker_one_finished = Channel(Nil).new(1)
      run_result = Channel(Exception?).new(1)
      runner = nil.as(Fiber::ExecutionContext::Isolated?)
      returned_early = false
      early_error = nil.as(Exception?)

      job = ->(index : Int32, _state : CrystalClickReadRowsScan::WorkerState) do
        case index
        when 0
          worker_one_started.receive?
          worker_zero_failed.send(nil)
          raise Exception.new("injected worker failure")
        when 1
          worker_one_started.send(nil)
          release_worker_one.receive?
          worker_one_finished.send(nil)
        end
        nil
      end

      begin
        runner = Fiber::ExecutionContext::Isolated.new("read_rows_worker_pool_spec scan") do
          error = nil.as(Exception?)
          begin
            pool.run(job)
          rescue ex : Exception
            error = ex
          ensure
            run_result.send(error)
          end
        end

        worker_zero_failed.receive
        select
        when result = run_result.receive
          early_error = result
          returned_early = true
        when timeout(25.milliseconds)
        end

        release_worker_one.send(true)
        release_worker_one.close
        worker_one_finished.receive
        result_error = if returned_early
                         early_error
                       else
                         run_result.receive
                       end
        runner.not_nil!.wait

        returned_early.should be_false
        result_error.should_not be_nil
        result_error.not_nil!.message.should eq("injected worker failure")

        recovered = Channel(Int32).new(4)
        pool.run(->(index : Int32, _state : CrystalClickReadRowsScan::WorkerState) do
          recovered.send(index)
          nil
        end)
        recovered.close
        Array(Int32).new(4) { recovered.receive }.sort.should eq([0, 1, 2, 3])

        pool.close
        {% if flag?(:read_rows_profile) %}
          pool.dispatch_count.should eq(2_u64)
          pool.context_create_count.should eq(4)
          pool.context_join_count.should eq(4)
        {% end %}
      ensure
        worker_one_started.close
        release_worker_one.close
        if running = runner
          begin
            running.wait
          rescue
          end
        end
        pool.close
      end
    {% end %}
  end

  it "runs the one-worker path inline" do
    pool = CrystalClickReadRowsScan::WorkerPool.new(1, 4)
    caller_thread = Thread.current.object_id
    observed_thread = Channel(UInt64).new(1)
    job = ->(_index : Int32, _state : CrystalClickReadRowsScan::WorkerState) do
      observed_thread.send(Thread.current.object_id.to_u64)
      nil
    end

    pool.run(job)
    observed_thread.receive.should eq(caller_thread.to_u64)
    {% if flag?(:read_rows_profile) %}
      pool.context_create_count.should eq(0)
      pool.context_join_count.should eq(0)
      pool.dispatch_count.should eq(1_u64)
    {% end %}
    pool.close
    {% if flag?(:read_rows_profile) %}
      pool.context_join_count.should eq(0)
    {% end %}
  end
end
