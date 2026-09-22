require "./spec_helper"
require "../benchmarks/uint64_execution_pipeline"

BENCHMARK_FIXTURE = File.expand_path("../test/fixtures/public/wide_u64_lz4/part", __DIR__)
BENCHMARK_ROWS    =        200_000_u64
BENCHMARK_SUM     = 19_999_900_000_u64

def with_benchmark_root(&)
  root = File.tempname("crystal-click-uint64-execution-benchmark-spec")
  Dir.mkdir(root)
  part = File.join(root, CrystalClickUInt64ExecutionBenchmark::PART_NAME)
  FileUtils.cp_r(BENCHMARK_FIXTURE, part)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe "UInt64 execution benchmark harness" do
  it "verifies every decoded value against its physical sequence position" do
    with_benchmark_root do |root|
      CrystalClickUInt64ExecutionBenchmark.verify_sequence(root, BENCHMARK_ROWS, 73).should eq(BENCHMARK_ROWS)
      expect_raises(CrystalClickUInt64ExecutionBenchmark::ParityError) do
        CrystalClickUInt64ExecutionBenchmark.verify_sequence(root, BENCHMARK_ROWS - 1_u64, 73)
      end
    end
  end

  it "keeps exact parity across owning, borrowed, and aggregate tracks" do
    expected = CrystalClickUInt64ExecutionBenchmark::ExpectedAggregate.new(
      BENCHMARK_ROWS,
      BENCHMARK_SUM,
      0_u64,
      BENCHMARK_ROWS - 1_u64
    )

    with_benchmark_root do |root|
      ["array", "borrowed", "pipeline"].each do |track|
        observation = CrystalClickUInt64ExecutionBenchmark.observe(
          track,
          root,
          73,
          "natural_unknown",
          expected
        )

        observation.track.should eq(track)
        observation.count.should eq(expected.count)
        observation.sum.should eq(expected.sum)
        observation.min.should eq(expected.min)
        observation.max.should eq(expected.max)
        observation.parity_ok.should be_true
        observation.elapsed_ns.should be > 0
        observation.gc_metrics_available.should be_true

        case track
        when "array"
          observation.retained_rows.should eq(BENCHMARK_ROWS)
          observation.container_state.should eq("array_owned")
        when "borrowed"
          observation.retained_rows.should eq(0_u64)
          observation.container_state.should eq("borrowed_scratch_only")
        when "pipeline"
          observation.retained_rows.should eq(0_u64)
          observation.container_state.should eq("aggregate_result_only")
        end
      end
    end
  end

  it "rejects unsupported tracks, cache labels, and unbounded scratch" do
    expected = CrystalClickUInt64ExecutionBenchmark::ExpectedAggregate.new(
      BENCHMARK_ROWS,
      BENCHMARK_SUM,
      0_u64,
      BENCHMARK_ROWS - 1_u64
    )

    with_benchmark_root do |root|
      expect_raises(ArgumentError) do
        CrystalClickUInt64ExecutionBenchmark.observe("unknown", root, 73, "natural_unknown", expected)
      end
      expect_raises(ArgumentError) do
        CrystalClickUInt64ExecutionBenchmark.observe("array", root, 73, "cold", expected)
      end
      expect_raises(ArgumentError) do
        CrystalClickUInt64ExecutionBenchmark.observe("array", root, 0, "natural_unknown", expected)
      end
      expect_raises(ArgumentError) do
        CrystalClickUInt64ExecutionBenchmark.observe(
          "pipeline",
          root,
          CrystalClickUInt64ExecutionBenchmark::MAX_SCRATCH_SIZE + 1,
          "natural_unknown",
          expected
        )
      end
    end
  end

  it "fails closed when independent expected values do not match" do
    expected = CrystalClickUInt64ExecutionBenchmark::ExpectedAggregate.new(
      BENCHMARK_ROWS,
      BENCHMARK_SUM + 1_u64,
      0_u64,
      BENCHMARK_ROWS - 1_u64
    )

    with_benchmark_root do |root|
      expect_raises(CrystalClickUInt64ExecutionBenchmark::ParityError) do
        CrystalClickUInt64ExecutionBenchmark.observe("pipeline", root, 73, "natural_unknown", expected)
      end
    end
  end
end
