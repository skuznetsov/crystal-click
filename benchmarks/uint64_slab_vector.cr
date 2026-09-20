# This benchmark isolates container ingestion from compressed reader and codec work.
# It supplies deterministic UInt64 values through four standalone release tracks;
# it is not a benchmark of a compressed reader, decompressor, or disk format.

require "../src/crystal_click"

module CrystalClickUInt64SlabVectorBenchmark
  extend self

  VALUE_MULTIPLIER    = 0x9e3779b97f4a7c15_u64
  VALUE_OFFSET        = 0xd1b54a32d192ed03_u64
  CHECKSUM_MULTIPLIER = 0x94d049bb133111eb_u64

  struct IngestResult
    getter checksum : UInt64
    getter consumed_rows : Int64

    def initialize(@checksum : UInt64, @consumed_rows : Int64)
    end
  end

  def value_for(index : UInt64) : UInt64
    (index &* VALUE_MULTIPLIER) ^ VALUE_OFFSET
  end

  def roll_checksum(checksum : UInt64, value : UInt64) : UInt64
    (checksum &* CHECKSUM_MULTIPLIER) ^ value
  end

  def checksum_slice(values : Slice(UInt64), checksum : UInt64) : UInt64
    offset = 0
    while offset < values.size
      checksum = roll_checksum(checksum, values[offset])
      offset += 1
    end
    checksum
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

  def ingest_array_direct(rows : Int, values : Array(UInt64)) : IngestResult
    checksum = 0_u64
    index = 0
    while index < rows
      value = value_for(index.to_u64)
      values << value
      checksum = roll_checksum(checksum, value)
      index += 1
    end
    IngestResult.new(checksum, values.size.to_i64)
  end

  def ingest_array_stream(rows : Int, scratch : Slice(UInt64), values : Array(UInt64)) : IngestResult
    checksum = 0_u64
    produced = 0
    while produced < rows
      chunk_size = rows - produced
      chunk_size = scratch.size if chunk_size > scratch.size
      chunk = scratch[0, chunk_size]

      offset = 0
      while offset < chunk_size
        chunk[offset] = value_for((produced + offset).to_u64)
        offset += 1
      end

      values.concat(chunk)
      checksum = checksum_slice(chunk, checksum)
      produced += chunk_size
    end
    IngestResult.new(checksum, produced.to_i64)
  end

  def ingest_slab_stream(rows : Int, scratch : Slice(UInt64), values : CrystalClick::UInt64SlabVector) : IngestResult
    checksum = 0_u64
    produced = 0
    while produced < rows
      chunk_size = rows - produced
      chunk_size = scratch.size if chunk_size > scratch.size
      chunk = scratch[0, chunk_size]

      offset = 0
      while offset < chunk_size
        chunk[offset] = value_for((produced + offset).to_u64)
        offset += 1
      end

      values.concat(chunk)
      checksum = checksum_slice(chunk, checksum)
      produced += chunk_size
    end
    IngestResult.new(checksum, produced.to_i64)
  end

  def ingest_slice_sink(rows : Int, scratch : Slice(UInt64)) : IngestResult
    checksum = 0_u64
    produced = 0
    while produced < rows
      chunk_size = rows - produced
      chunk_size = scratch.size if chunk_size > scratch.size
      chunk = scratch[0, chunk_size]

      offset = 0
      while offset < chunk_size
        chunk[offset] = value_for((produced + offset).to_u64)
        offset += 1
      end

      checksum = checksum_slice(chunk, checksum)
      produced += chunk_size
    end
    IngestResult.new(checksum, produced.to_i64)
  end

  def parse_int(raw : String, name : String, positive : Bool = true) : Int
    parsed = raw.to_i64?(whitespace: false)
    if parsed.nil? || (positive ? parsed <= 0 : parsed < 0)
      raise ArgumentError.new("#{name} must be #{positive ? "positive" : "non-negative"}: #{raw}")
    end
    parsed.to_i
  end

  def usage : NoReturn
    STDERR.puts "usage: uint64_slab_vector TRACK ROWS SLAB_SHIFT SCRATCH_SIZE"
    STDERR.puts "tracks: array_direct, array_stream, slab_stream, slice_sink"
    exit 64
  end

  def fail_if_bad!(track : String, rows : Int, result : IngestResult, retained_values : Int, checksum : UInt64)
    unless {"array_direct", "array_stream", "slab_stream", "slice_sink"}.includes?(track)
      raise ArgumentError.new("unknown track: #{track}")
    end
    raise RuntimeError.new("consumed row mismatch") unless result.consumed_rows == rows.to_i64
    expected_retained = track == "slice_sink" ? 0 : rows
    raise RuntimeError.new("retained row mismatch") unless retained_values == expected_retained
    raise RuntimeError.new("checksum mismatch") unless checksum == result.checksum
  end

  def run(args : Array(String)) : Nil
    usage unless args.size == 4

    track = args[0]
    rows = parse_int(args[1], "rows")
    slab_shift = parse_int(args[2], "slab_shift")
    unless slab_shift >= CrystalClick::UInt64SlabVector::MIN_SHIFT && slab_shift <= CrystalClick::UInt64SlabVector::MAX_SHIFT
      raise ArgumentError.new("slab_shift must be between 4 and 20: #{slab_shift}")
    end
    scratch_size = parse_int(args[3], "scratch_size")

    array : Array(UInt64)? = nil
    vector : CrystalClick::UInt64SlabVector? = nil
    scratch : Slice(UInt64)? = nil

    case track
    when "array_direct"
      array = Array(UInt64).new
    when "array_stream"
      array = Array(UInt64).new
      scratch = Slice(UInt64).new(scratch_size)
    when "slab_stream"
      vector = CrystalClick::UInt64SlabVector.new(slab_shift: slab_shift)
      scratch = Slice(UInt64).new(scratch_size)
    when "slice_sink"
      scratch = Slice(UInt64).new(scratch_size)
    else
      raise ArgumentError.new("unknown track: #{track}")
    end

    # Setup, scratch allocation, and the one-time GC cleanup are deliberately
    # outside the measured ingestion interval. The resulting container remains
    # live until its checksum is validated below.
    GC.collect
    before_bytes = GC.stats.total_bytes
    before_gc_no = GC.prof_stats.gc_no
    started = Time.instant

    result = case track
             when "array_direct"
               ingest_array_direct(rows, array.not_nil!)
             when "array_stream"
               ingest_array_stream(rows, scratch.not_nil!, array.not_nil!)
             when "slab_stream"
               ingest_slab_stream(rows, scratch.not_nil!, vector.not_nil!)
             when "slice_sink"
               ingest_slice_sink(rows, scratch.not_nil!)
             else
               raise ArgumentError.new("unknown track: #{track}")
             end

    elapsed_ns = (Time.instant - started).total_nanoseconds.to_i64
    after_bytes = GC.stats.total_bytes
    after_gc_no = GC.prof_stats.gc_no

    retained_values = case track
                      when "array_direct", "array_stream"
                        array.not_nil!.size
                      when "slab_stream"
                        vector.not_nil!.size
                      else
                        0
                      end

    # Validate that concat copied the producer's values into the retained
    # container. This pass is intentionally outside elapsed_ns.
    retained_checksum = case track
                        when "array_direct", "array_stream"
                          checksum_array(array.not_nil!)
                        when "slab_stream"
                          checksum_vector(vector.not_nil!)
                        else
                          result.checksum
                        end
    fail_if_bad!(track, rows, result, retained_values, retained_checksum)

    gc_total_bytes_delta = after_bytes >= before_bytes ? after_bytes - before_bytes : 0_u64
    gc_collections_delta = after_gc_no >= before_gc_no ? after_gc_no - before_gc_no : 0_u64

    json = String.build do |json|
      json << %({"track":"#{track}","rows":#{rows},"checksum":#{result.checksum},"elapsed_ns":#{elapsed_ns},)
      json << %("gc_total_bytes_delta":#{gc_total_bytes_delta},"gc_collections_delta":#{gc_collections_delta},)
      json << %("retained_values":#{retained_values},"slab_shift":#{slab_shift},"scratch_size":#{scratch_size})
      if track == "slab_stream"
        slab_vector = vector.not_nil!
        json << %(,"slab_count":#{slab_vector.slab_count},"capacity":#{slab_vector.capacity},"directory_capacity":#{slab_vector.directory_capacity})
      end
      json << "}"
    end
    STDOUT.puts json
  end
end

CrystalClickUInt64SlabVectorBenchmark.run(ARGV)
