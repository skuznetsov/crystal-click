require "../src/crystal_click"

# This benchmark compares the existing Array-owning WidePart read with the
# opt-in UInt64SlabVector-owning read.  It intentionally accepts the expected
# row count and checksum from the caller; no track is allowed to become the
# correctness authority for another track.
module CrystalClickRealReaderSlabBenchmark
  extend self

  CHECKSUM_MULTIPLIER = 0x94d049bb133111eb_u64

  def usage : NoReturn
    STDERR.puts "usage: real_reader_slab TRACK FIXTURE COLUMN SLAB_SHIFT EXPECTED_ROWS EXPECTED_CHECKSUM CACHE_REGIME"
    STDERR.puts "tracks: array, slab"
    STDERR.puts "cache regimes: warm_shared, natural_unknown"
    exit 64
  end

  def parse_int(raw : String, name : String, positive : Bool = true) : Int
    parsed = raw.to_i64?(whitespace: false)
    if parsed.nil? || (positive ? parsed <= 0 : parsed < 0)
      raise ArgumentError.new("#{name} must be #{positive ? "positive" : "non-negative"}: #{raw}")
    end
    parsed.to_i
  end

  def parse_u64(raw : String, name : String, positive : Bool = false) : UInt64
    parsed = raw.to_u64?(whitespace: false)
    if parsed.nil? || (positive && parsed == 0_u64)
      raise ArgumentError.new("#{name} must be #{positive ? "positive" : "a non-negative"} UInt64: #{raw}")
    end
    parsed
  end

  def roll_checksum(checksum : UInt64, value : UInt64) : UInt64
    (checksum &* CHECKSUM_MULTIPLIER) ^ value
  end

  def checksum_array(values : Array(UInt64)) : UInt64
    checksum = 0_u64
    offset = 0
    while offset < values.size
      checksum = roll_checksum(checksum, values[offset])
      offset += 1
    end
    checksum
  end

  def checksum_vector(values : CrystalClick::UInt64SlabVector) : UInt64
    checksum = 0_u64
    values.each do |value|
      checksum = roll_checksum(checksum, value)
    end
    checksum
  end

  def run(args : Array(String)) : Nil
    usage unless args.size == 7

    track = args[0]
    unless {"array", "slab"}.includes?(track)
      raise ArgumentError.new("unknown track: #{track}")
    end

    fixture = args[1]
    column = args[2]
    raise ArgumentError.new("fixture and column must be non-empty") if fixture.empty? || column.empty?

    slab_shift = parse_int(args[3], "slab_shift")
    unless slab_shift >= CrystalClick::UInt64SlabVector::MIN_SHIFT && slab_shift <= CrystalClick::UInt64SlabVector::MAX_SHIFT
      raise ArgumentError.new("slab_shift must be between 4 and 20: #{slab_shift}")
    end

    expected_rows = parse_u64(args[4], "expected_rows", positive: true)
    expected_checksum = parse_u64(args[5], "expected_checksum")
    cache_regime = args[6]
    unless {"warm_shared", "natural_unknown"}.includes?(cache_regime)
      raise ArgumentError.new("cache_regime must be warm_shared or natural_unknown")
    end

    # The timer includes part metadata/mark loading and the complete owning
    # read.  GC setup is outside the interval; the result remains live while
    # the post-timer checksum and retention checks run.
    GC.collect
    before_bytes = GC.stats.total_bytes
    before_gc_no = GC.prof_stats.gc_no
    started = Time.instant

    part = CrystalClick::WidePart.open(fixture, column)
    values_array : Array(UInt64)? = nil
    values_slab : CrystalClick::UInt64SlabVector? = nil
    case track
    when "array"
      values_array = part.read_uint64(column)
    when "slab"
      values_slab = part.read_uint64_slab(column, slab_shift)
    end

    elapsed_ns = (Time.instant - started).total_nanoseconds.to_i64
    after_bytes = GC.stats.total_bytes
    after_gc_no = GC.prof_stats.gc_no

    retained_values = case track
                      when "array"
                        values_array.not_nil!.size
                      else
                        values_slab.not_nil!.size
                      end
    actual_checksum = case track
                      when "array"
                        checksum_array(values_array.not_nil!)
                      else
                        checksum_vector(values_slab.not_nil!)
                      end

    actual_rows = retained_values.to_u64
    raise RuntimeError.new("part row mismatch") unless part.row_count == expected_rows
    raise RuntimeError.new("result row mismatch") unless actual_rows == expected_rows
    raise RuntimeError.new("checksum mismatch") unless actual_checksum == expected_checksum
    raise RuntimeError.new("elapsed_ns must be positive") if elapsed_ns <= 0

    gc_total_bytes_delta = after_bytes >= before_bytes ? after_bytes - before_bytes : 0_u64
    gc_collections_delta = after_gc_no >= before_gc_no ? after_gc_no - before_gc_no : 0_u64
    slab_count = 0
    capacity = 0
    directory_capacity = 0
    if track == "slab"
      vector = values_slab.not_nil!
      slab_count = vector.slab_count
      capacity = vector.capacity
      directory_capacity = vector.directory_capacity
    end

    json = String.build do |output|
      output << %({"track":"#{track}","cache_regime":"#{cache_regime}",)
      output << %("rows":#{actual_rows},"expected_rows":#{expected_rows},)
      output << %("checksum":#{actual_checksum},"expected_checksum":#{expected_checksum},)
      output << %("rows_ok":true,"checksum_ok":true,"elapsed_ns":#{elapsed_ns},)
      output << %("gc_total_bytes_delta":#{gc_total_bytes_delta},"gc_collections_delta":#{gc_collections_delta},)
      output << %("gc_metrics_available":true,"retained_values":#{retained_values},)
      output << %("fixture_rows":#{part.row_count},"mark_count":#{part.mark_count},)
      output << %("data_bytes":#{File.size(part.data_path)},"mark_bytes":#{File.size(part.mark_path)},)
      output << %("slab_shift":#{slab_shift},"slab_count":#{slab_count},"capacity":#{capacity},"directory_capacity":#{directory_capacity})
      output << "}"
    end
    STDOUT.puts json
  end
end

CrystalClickRealReaderSlabBenchmark.run(ARGV)
