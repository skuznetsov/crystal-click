require "../src/crystal_click"

# A deliberately small, fail-closed harness for the bounded UInt64 execution
# surface.  The runner supplies an independently derived aggregate for the
# public/generated 0..rows-1 fixture contract; this file never prints the
# fixture path or any fixture-specific identifier.
module CrystalClickUInt64ExecutionBenchmark
  COLUMN_NAME = "value"
  PART_NAME   = "part_0_0_1_0"

  MAX_SCRATCH_SIZE = 65_536
  MIN_SCRATCH_SIZE =      1

  VALID_TRACKS        = {"array", "borrowed", "pipeline"}
  VALID_CACHE_REGIMES = {"warm_shared", "natural_unknown"}

  class ParityError < Exception
  end

  struct ExpectedAggregate
    getter count : UInt64
    getter sum : UInt64
    getter min : UInt64?
    getter max : UInt64?

    def initialize(@count : UInt64, @sum : UInt64, @min : UInt64?, @max : UInt64?)
    end
  end

  struct Observation
    getter track : String
    getter cache_regime : String
    getter scratch_size : Int32
    getter count : UInt64
    getter sum : UInt64
    getter min : UInt64?
    getter max : UInt64?
    getter parity_ok : Bool
    getter elapsed_ns : Int64
    getter gc_total_bytes_delta : UInt64
    getter gc_collections_delta : UInt64
    getter gc_metrics_available : Bool
    getter retained_rows : UInt64
    getter container_state : String

    def initialize(
      @track : String,
      @cache_regime : String,
      @scratch_size : Int32,
      result : CrystalClick::UInt64AggregateResult,
      @elapsed_ns : Int64,
      @gc_total_bytes_delta : UInt64,
      @gc_collections_delta : UInt64,
      @retained_rows : UInt64,
      @container_state : String,
    )
      @count = result.count
      @sum = result.sum
      @min = result.min
      @max = result.max
      @parity_ok = true
      @gc_metrics_available = true
    end

    def to_json : String
      String.build do |output|
        output << %({"schema_version":1,"track":"#{@track}","cache_regime":"#{@cache_regime}",)
        output << %("scratch_size":#{@scratch_size},"count":#{@count},"sum":#{@sum},)
        output << %("min":)
        append_optional(output, @min)
        output << %(,"max":)
        append_optional(output, @max)
        output << %(,"parity_ok":true,"elapsed_ns":#{@elapsed_ns},)
        output << %("gc_total_bytes_delta":#{@gc_total_bytes_delta},"gc_collections_delta":#{@gc_collections_delta},)
        output << %("gc_metrics_available":true,"retained_rows":#{@retained_rows},)
        output << %("container_state":"#{@container_state}"})
      end
    end

    private def append_optional(output : String::Builder, value : UInt64?) : Nil
      if actual = value
        output << actual.to_s
      else
        output << "null"
      end
    end
  end

  extend self

  def observe(
    track : String,
    root : String,
    scratch_size : Int,
    cache_regime : String,
    expected : ExpectedAggregate,
  ) : Observation
    validate_track!(track)
    validate_cache_regime!(cache_regime)
    validate_scratch_size!(scratch_size)
    validate_expected!(expected)

    source = CrystalClick::WidePartSet.open(root, COLUMN_NAME)
    raise ParityError.new("source row count differs from expected") unless source.total_row_count == expected.count

    # Allocate the caller-owned scan buffer before the measured interval.  The
    # Array track carries the same declared scratch size but intentionally does
    # not use it; its measured operation is the owning read plus reduction.
    scratch = Slice(UInt64).new(scratch_size)
    part = CrystalClick::WidePart.open(File.join(root, PART_NAME), COLUMN_NAME)
    raise ParityError.new("part row count differs from expected") unless part.row_count == expected.count

    GC.collect
    before_bytes = GC.stats.total_bytes
    before_gc_no = GC.prof_stats.gc_no
    started = Time.instant

    result : CrystalClick::UInt64AggregateResult
    retained_rows = 0_u64
    container_state = ""

    case track
    when "array"
      values = part.read_uint64(COLUMN_NAME)
      result = reduce_array(values)
      retained_rows = values.size.to_u64
      container_state = "array_owned"
    when "borrowed"
      result = reduce_borrowed(source, scratch)
      container_state = "borrowed_scratch_only"
    when "pipeline"
      result = source.aggregate_uint64(scratch)
      container_state = "aggregate_result_only"
    else
      # validate_track! makes this unreachable, but keeping the assignment
      # explicit prevents a future track from accidentally returning partial
      # metrics.
      raise ArgumentError.new("unknown track")
    end

    elapsed_ns = (Time.instant - started).total_nanoseconds.to_i64
    raise RuntimeError.new("elapsed_ns must be positive") if elapsed_ns <= 0

    after_bytes = GC.stats.total_bytes
    after_gc_no = GC.prof_stats.gc_no
    gc_total_bytes_delta = after_bytes >= before_bytes ? after_bytes - before_bytes : 0_u64
    gc_collections_delta = after_gc_no >= before_gc_no ? after_gc_no - before_gc_no : 0_u64

    check_parity!(result, expected)

    Observation.new(
      track,
      cache_regime,
      scratch_size.to_i32,
      result,
      elapsed_ns,
      gc_total_bytes_delta,
      gc_collections_delta,
      retained_rows,
      container_state
    )
  end

  # Untimed preflight for the fixture contract. Aggregate parity alone cannot
  # distinguish a reordered payload with the same count/sum/min/max.
  def verify_sequence(root : String, expected_count : UInt64, scratch_size : Int) : UInt64
    validate_scratch_size!(scratch_size)
    raise ArgumentError.new("expected count must be positive") if expected_count == 0_u64

    source = CrystalClick::WidePartSet.open(root, COLUMN_NAME)
    raise ParityError.new("source row count differs from expected") unless source.total_row_count == expected_count

    scratch = Slice(UInt64).new(scratch_size)
    expected_value = 0_u64
    source.scan_into(scratch) do |batch|
      batch.values.each do |value|
        raise ParityError.new("fixture sequence verification failed") unless value == expected_value
        expected_value += 1_u64
      end
    end

    raise ParityError.new("fixture sequence length differs from expected") unless expected_value == expected_count
    expected_value
  end

  def main(args : Array(String)) : Nil
    raise ArgumentError.new("invalid benchmark argument count") unless args.size == 8

    track = args[0]
    root = args[1]
    scratch_size = parse_positive_int(args[2], "scratch_size")
    cache_regime = args[3]
    expected = ExpectedAggregate.new(
      parse_u64(args[4], "expected_count"),
      parse_u64(args[5], "expected_sum"),
      parse_u64(args[6], "expected_min"),
      parse_u64(args[7], "expected_max")
    )

    STDOUT.puts observe(track, root, scratch_size, cache_regime, expected).to_json
  end

  def verify_sequence_main(args : Array(String)) : Nil
    raise ArgumentError.new("invalid sequence verification argument count") unless args.size == 3

    root = args[0]
    expected_count = parse_u64(args[1], "expected_count")
    scratch_size = parse_positive_int(args[2], "scratch_size")
    STDOUT.puts verify_sequence(root, expected_count, scratch_size)
  end

  private def validate_track!(track : String) : Nil
    raise ArgumentError.new("unknown track") unless VALID_TRACKS.includes?(track)
  end

  private def validate_cache_regime!(cache_regime : String) : Nil
    raise ArgumentError.new("unsupported cache regime") unless VALID_CACHE_REGIMES.includes?(cache_regime)
  end

  private def validate_scratch_size!(scratch_size : Int) : Nil
    unless scratch_size >= MIN_SCRATCH_SIZE && scratch_size <= MAX_SCRATCH_SIZE
      raise ArgumentError.new("scratch size is outside the bounded range")
    end
  end

  private def validate_expected!(expected : ExpectedAggregate) : Nil
    raise ArgumentError.new("expected count must be positive") if expected.count == 0_u64
    if expected.min && expected.max
      raise ArgumentError.new("expected extrema are reversed") if expected.min.not_nil! > expected.max.not_nil!
    elsif expected.min || expected.max
      raise ArgumentError.new("expected extrema must be paired")
    end
  end

  private def parse_positive_int(raw : String, name : String) : Int
    parsed = raw.to_i64?(whitespace: false)
    if parsed.nil? || parsed.not_nil! <= 0 || parsed.not_nil! > Int32::MAX
      raise ArgumentError.new("#{name} must be a positive bounded integer")
    end
    parsed.not_nil!.to_i
  end

  private def parse_u64(raw : String, name : String) : UInt64
    parsed = raw.to_u64?(whitespace: false)
    raise ArgumentError.new("#{name} must be a UInt64") unless parsed
    parsed.not_nil!
  end

  private def reduce_array(values : Array(UInt64)) : CrystalClick::UInt64AggregateResult
    count = 0_u64
    sum = 0_u64
    minimum : UInt64? = nil
    maximum : UInt64? = nil
    values.each do |value|
      count += 1_u64
      sum = sum &+ value
      if minimum_value = minimum
        minimum = value if value < minimum_value
        maximum_value = maximum.not_nil!
        maximum = value if value > maximum_value
      else
        minimum = value
        maximum = value
      end
    end
    CrystalClick::UInt64AggregateResult.new(count, sum, minimum, maximum)
  end

  private def reduce_borrowed(
    source : CrystalClick::WidePartSet,
    scratch : Slice(UInt64),
  ) : CrystalClick::UInt64AggregateResult
    count = 0_u64
    sum = 0_u64
    minimum : UInt64? = nil
    maximum : UInt64? = nil
    source.scan_into(scratch) do |batch|
      batch.values.each do |value|
        count += 1_u64
        sum = sum &+ value
        if minimum_value = minimum
          minimum = value if value < minimum_value
          maximum_value = maximum.not_nil!
          maximum = value if value > maximum_value
        else
          minimum = value
          maximum = value
        end
      end
    end
    CrystalClick::UInt64AggregateResult.new(count, sum, minimum, maximum)
  end

  private def check_parity!(actual : CrystalClick::UInt64AggregateResult, expected : ExpectedAggregate) : Nil
    return if actual.count == expected.count &&
              actual.sum == expected.sum &&
              actual.min == expected.min &&
              actual.max == expected.max

    raise ParityError.new("aggregate parity failed")
  end
end

if {"--run", "--verify-sequence"}.includes?(ARGV[0]?)
  begin
    if ARGV[0] == "--run"
      CrystalClickUInt64ExecutionBenchmark.main(ARGV[1..])
    else
      CrystalClickUInt64ExecutionBenchmark.verify_sequence_main(ARGV[1..])
    end
  rescue Exception
    # Never echo the root, column, or implementation exception.  The runner
    # treats any non-zero child or malformed JSON as a failed observation.
    STDERR.puts "uint64_execution_pipeline: benchmark failed"
    exit 64
  end
end
