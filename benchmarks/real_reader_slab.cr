require "../src/crystal_click"
require "./real_reader_slab_manifest"

# This benchmark compares the existing Array-owning WidePart read with the
# opt-in UInt64SlabVector-owning read. Legacy positional arguments remain
# supported for the public one-column smoke path. Manifest mode is the
# controlled, multi-column path and keeps every returned value container live
# until after the timer has stopped.
module CrystalClickRealReaderSlabBenchmark
  extend self

  CHECKSUM_MULTIPLIER = CrystalClickRealReaderSlabManifest::CHECKSUM_MULTIPLIER

  def usage : NoReturn
    STDERR.puts "usage: real_reader_slab TRACK FIXTURE COLUMN SLAB_SHIFT EXPECTED_ROWS EXPECTED_CHECKSUM CACHE_REGIME"
    STDERR.puts "   or: real_reader_slab TRACK --manifest-stdin SLAB_SHIFT CACHE_REGIME"
    STDERR.puts "   or: real_reader_slab validate --manifest-stdin"
    STDERR.puts "tracks: array, slab"
    STDERR.puts "cache regimes: warm_shared, natural_unknown"
    exit 64
  end

  def parse_int(raw : String, name : String, positive : Bool = true) : Int
    parsed = raw.to_i64?(whitespace: false)
    if parsed.nil? || (positive ? parsed <= 0 : parsed < 0)
      raise ArgumentError.new("#{name} must be #{positive ? "positive" : "non-negative"}")
    end
    parsed.to_i
  end

  def parse_u64(raw : String, name : String, positive : Bool = false) : UInt64
    parsed = raw.to_u64?(whitespace: false)
    if parsed.nil? || (positive && parsed == 0_u64)
      raise ArgumentError.new("#{name} must be #{positive ? "positive" : "a non-negative"} UInt64")
    end
    parsed
  end

  def validate_track!(track : String) : Nil
    raise ArgumentError.new("unknown track") unless {"array", "slab"}.includes?(track)
  end

  def validate_cache_regime!(cache_regime : String) : Nil
    unless {"warm_shared", "natural_unknown"}.includes?(cache_regime)
      raise ArgumentError.new("cache_regime must be warm_shared or natural_unknown")
    end
  end

  def validate_shift!(slab_shift : Int) : Nil
    unless slab_shift >= CrystalClick::UInt64SlabVector::MIN_SHIFT &&
           slab_shift <= CrystalClick::UInt64SlabVector::MAX_SHIFT
      raise ArgumentError.new("slab_shift must be between 4 and 20")
    end
  end

  def roll_checksum(checksum : UInt64, value : UInt64) : UInt64
    (checksum &* CHECKSUM_MULTIPLIER) ^ value
  end

  def checksum_array(values : Array(UInt64)) : UInt64
    checksum = CrystalClickRealReaderSlabManifest::CHECKSUM_INITIAL
    offset = 0
    while offset < values.size
      checksum = roll_checksum(checksum, values[offset])
      offset += 1
    end
    checksum
  end

  def checksum_vector(values : CrystalClick::UInt64SlabVector) : UInt64
    checksum = CrystalClickRealReaderSlabManifest::CHECKSUM_INITIAL
    values.each do |value|
      checksum = roll_checksum(checksum, value)
    end
    checksum
  end

  def run(args : Array(String)) : Nil
    case args.size
    when 2
      if args[0] == "validate" && args[1] == "--manifest-stdin"
        run_validate_manifest_stdin
      else
        usage
      end
    when 4
      if args[1] == "--manifest-stdin"
        run_manifest_stdin(args)
      else
        usage
      end
    when 7
      run_legacy(args)
    else
      usage
    end
  end

  private def run_validate_manifest_stdin : Nil
    workload = CrystalClickRealReaderSlabManifest.parse_stdin
    workload.validate_controlled!
    STDOUT.puts %({"schema_version":2,"column_count":#{workload.columns.size},"rows_per_column":#{workload.expected_rows},"decoded_bytes":#{workload.decoded_bytes},"threshold_bytes":#{CrystalClickRealReaderSlabManifest::THRESHOLD_BYTES},"threshold_met":true})
  end

  private def run_legacy(args : Array(String)) : Nil
    track = args[0]
    validate_track!(track)

    fixture = args[1]
    column = args[2]
    raise ArgumentError.new("fixture and column must be non-empty") if fixture.empty? || column.empty?

    slab_shift = parse_int(args[3], "slab_shift")
    validate_shift!(slab_shift)
    expected_rows = parse_u64(args[4], "expected_rows", positive: true)
    expected_checksum = parse_u64(args[5], "expected_checksum")
    cache_regime = args[6]
    validate_cache_regime!(cache_regime)

    columns = [CrystalClickRealReaderSlabManifest::ColumnSpec.new(column, expected_checksum)]
    workload = CrystalClickRealReaderSlabManifest::Workload.new(fixture, expected_rows, columns)
    run_workload(track, workload, slab_shift, cache_regime, expected_checksum)
  end

  private def run_manifest_stdin(args : Array(String)) : Nil
    track = args[0]
    validate_track!(track)
    workload = CrystalClickRealReaderSlabManifest.parse_stdin
    slab_shift = parse_int(args[2], "slab_shift")
    validate_shift!(slab_shift)
    cache_regime = args[3]
    validate_cache_regime!(cache_regime)
    # This check deliberately occurs before GC setup, opening any part, or
    # starting the timer. Public smoke uses the legacy path below the gate.
    workload.validate_controlled!
    run_workload(track, workload, slab_shift, cache_regime)
  end

  private def run_workload(
    track : String,
    workload : CrystalClickRealReaderSlabManifest::Workload,
    slab_shift : Int,
    cache_regime : String,
    legacy_expected_checksum : UInt64? = nil,
  ) : Nil
    # GC setup is outside the measured interval. All parts and all owning
    # result containers stay referenced until after the timer and validation.
    GC.collect
    before_bytes = GC.stats.total_bytes
    before_gc_no = GC.prof_stats.gc_no
    started = Time.instant

    parts = [] of CrystalClick::WidePart
    array_values = [] of Array(UInt64)
    slab_values = [] of CrystalClick::UInt64SlabVector
    workload.columns.each do |column|
      part = CrystalClick::WidePart.open(workload.fixture, column.name)
      parts << part
      if track == "array"
        array_values << part.read_uint64(column.name)
      else
        slab_values << part.read_uint64_slab(column.name, slab_shift)
      end
    end

    elapsed_ns = (Time.instant - started).total_nanoseconds.to_i64
    after_bytes = GC.stats.total_bytes
    after_gc_no = GC.prof_stats.gc_no
    raise RuntimeError.new("elapsed_ns must be positive") if elapsed_ns <= 0

    rows_ok = true
    checksums_ok = true
    retained_values_total = 0_u64
    actual_rows_by_column = [] of UInt64
    actual_checksums = [] of UInt64

    if track == "array"
      array_values.each do |values|
        actual_rows = values.size.to_u64
        actual_rows_by_column << actual_rows
        # Compute each returned column checksum once. The cached value is
        # compared below and reused by the legacy one-column output.
        actual_checksums << checksum_array(values)
        retained_values_total += actual_rows
      end
    else
      slab_values.each do |values|
        actual_rows = values.size.to_u64
        actual_rows_by_column << actual_rows
        # Compute each returned column checksum once. The cached value is
        # compared below and reused by the legacy one-column output.
        actual_checksums << checksum_vector(values)
        retained_values_total += actual_rows
      end
    end

    workload.columns.each_with_index do |column, index|
      rows_ok = false unless parts[index].row_count == workload.expected_rows && actual_rows_by_column[index] == workload.expected_rows
      checksums_ok = false unless actual_checksums[index] == column.expected_checksum
    end

    # Do not emit a result object until the retained results have passed every
    # row and checksum check. In manifest mode the outer rescue turns any
    # failure into a generic error, so a failed child cannot leave a
    # success-looking JSON artifact behind.
    raise RuntimeError.new("row validation failed") unless rows_ok
    raise RuntimeError.new("checksum validation failed") unless checksums_ok

    observed_rows = actual_rows_by_column[0]
    observed_fixture_rows = parts[0].row_count

    data_bytes = 0_u64
    mark_bytes = 0_u64
    mark_count = 0_u64
    parts.each do |part|
      data_bytes += File.size(part.data_path).to_u64
      mark_bytes += File.size(part.mark_path).to_u64
      mark_count += part.mark_count.to_u64
    end

    slab_count_total = 0_u64
    capacity_total = 0_u64
    directory_capacity_total = 0_u64
    if track == "slab"
      slab_values.each do |values|
        slab_count_total += values.slab_count.to_u64
        capacity_total += values.capacity.to_u64
        directory_capacity_total += values.directory_capacity.to_u64
      end
    end
    tail_unused_slots_total = capacity_total >= retained_values_total ? capacity_total - retained_values_total : 0_u64
    gc_total_bytes_delta = after_bytes >= before_bytes ? after_bytes - before_bytes : 0_u64
    gc_collections_delta = after_gc_no >= before_gc_no ? after_gc_no - before_gc_no : 0_u64

    json = String.build do |output|
      output << %({"schema_version":2,"track":"#{track}","cache_regime":"#{cache_regime}",)
      output << %("slab_shift":#{slab_shift},"column_count":#{workload.columns.size},)
      output << %("rows_per_column":#{observed_rows},"rows":#{observed_rows},)
      output << %("expected_rows":#{workload.expected_rows},"decoded_bytes":#{workload.decoded_bytes},)
      output << %("threshold_bytes":#{CrystalClickRealReaderSlabManifest::THRESHOLD_BYTES},"threshold_met":#{workload.threshold_met?},)
      output << %("rows_ok":#{rows_ok},"checksums_ok":#{checksums_ok},)
      output << %("elapsed_ns":#{elapsed_ns},"gc_total_bytes_delta":#{gc_total_bytes_delta},)
      output << %("gc_collections_delta":#{gc_collections_delta},"gc_metrics_available":true,)
      output << %("retained_values_total":#{retained_values_total},"retained_values":#{retained_values_total},)
      output << %("fixture_rows":#{observed_fixture_rows},"mark_count":#{mark_count},)
      output << %("data_bytes":#{data_bytes},"mark_bytes":#{mark_bytes},)
      output << %("slab_count_total":#{slab_count_total},"capacity_total":#{capacity_total},)
      output << %("directory_capacity_total":#{directory_capacity_total},"tail_unused_slots_total":#{tail_unused_slots_total},)
      # Keep the old one-column fields for scripts consuming the positional
      # interface. Manifest mode intentionally emits no per-column names or
      # expected checksums.
      if legacy_expected_checksum
        output << %("checksum":#{actual_checksums[0]},"expected_checksum":#{legacy_expected_checksum},"checksum_ok":#{checksums_ok},)
      end
      output << %("slab_count":#{slab_count_total},"capacity":#{capacity_total},"directory_capacity":#{directory_capacity_total})
      output << "}"
    end
    STDOUT.puts json
  end
end

begin
  CrystalClickRealReaderSlabBenchmark.run(ARGV)
rescue ex : Exception
  if ARGV.includes?("--manifest-stdin")
    # Keep private workload paths, column names, raw values, and implementation
    # exceptions out of every controlled-manifest error.
    STDERR.puts "real_reader_slab: manifest execution failed"
  else
    STDERR.puts "real_reader_slab: #{ex.message}"
  end
  exit 64
end
