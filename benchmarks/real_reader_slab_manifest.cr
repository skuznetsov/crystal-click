require "json"

# Parsing and validation for the private multi-column real-reader workload.
# This module deliberately exposes only the shape and checksum contract; the
# benchmark output never serializes fixture paths or column names.
module CrystalClickRealReaderSlabManifest
  VERSION                 = 2
  MAX_MANIFEST_BYTES      = 64_u64 * 1024_u64
  MAX_COLUMNS             =                          1024
  MAX_COLUMN_NAME_BYTES   =                           256
  MAX_EXPECTED_ROWS       =             1_000_000_000_u64
  MAX_SIGNED_BASH_INTEGER = 9_223_372_036_854_775_807_u64
  MAX_NESTING_DEPTH       =                            16
  THRESHOLD_BYTES         = 64_u64 * 1024_u64 * 1024_u64
  CHECKSUM_ALGORITHM      = "u64_mul_xor"
  CHECKSUM_INITIAL        =                  0_u64
  CHECKSUM_MULTIPLIER     = 0x94d049bb133111eb_u64
  CHECKSUM_ORDER          = "physical_part_order"

  struct ColumnSpec
    getter name : String
    getter expected_checksum : UInt64

    def initialize(@name : String, @expected_checksum : UInt64)
    end
  end

  struct Workload
    getter fixture : String
    getter expected_rows : UInt64
    getter columns : Array(ColumnSpec)
    getter decoded_bytes : UInt64

    def initialize(
      @fixture : String,
      @expected_rows : UInt64,
      @columns : Array(ColumnSpec),
    )
      @decoded_bytes = checked_decoded_bytes(@expected_rows, @columns.size)
    end

    def threshold_met? : Bool
      @decoded_bytes >= THRESHOLD_BYTES
    end

    def validate_controlled! : Nil
      raise ArgumentError.new("controlled workload is below the 64 MiB threshold") unless threshold_met?
    end

    private def checked_decoded_bytes(rows : UInt64, column_count : Int) : UInt64
      raise ArgumentError.new("expected_rows must be positive") if rows == 0_u64
      raise ArgumentError.new("expected_rows exceeds the controlled limit") if rows > MAX_EXPECTED_ROWS
      raise ArgumentError.new("columns must not be empty") if column_count <= 0
      raise ArgumentError.new("column count exceeds the controlled limit") if column_count > MAX_COLUMNS

      width = 8_u64
      count = column_count.to_u64
      raise ArgumentError.new("decoded byte count overflows UInt64") if rows > UInt64::MAX // width
      row_bytes = rows * width
      raise ArgumentError.new("decoded byte count overflows UInt64") if row_bytes > UInt64::MAX // count
      decoded_bytes = row_bytes * count
      raise ArgumentError.new("decoded byte count exceeds the controlled limit") if decoded_bytes > MAX_SIGNED_BASH_INTEGER
      decoded_bytes
    end
  end

  extend self

  # Parse a workload manifest file.  The caller may retain the returned
  # fixture path for local use, but it should not print or persist it.
  def parse(path : String) : Workload
    parse_file(path)
  end

  def parse_file(path : String) : Workload
    raise ArgumentError.new("workload manifest is missing") unless File.file?(path)
    raise ArgumentError.new("workload manifest is too large") if File.size(path) > MAX_MANIFEST_BYTES
    parse_json(File.read(path))
  rescue ex : JSON::ParseException
    raise ArgumentError.new("workload manifest is not valid JSON")
  rescue ex : File::Error
    raise ArgumentError.new("workload manifest cannot be read")
  end

  # Read exactly one caller-supplied manifest snapshot from stdin.  The
  # benchmark uses this path for every validation, warmup, and timed child so
  # no child can reopen or reinterpret the caller's manifest path.
  def parse_stdin : Workload
    text = String.build do |output|
      buffer = Bytes.new(4096)
      total = 0_u64
      loop do
        count = STDIN.read(buffer)
        break if count == 0
        total += count.to_u64
        raise ArgumentError.new("workload manifest is too large") if total > MAX_MANIFEST_BYTES
        output.write(buffer[0, count])
      end
    end
    parse_json(text)
  end

  def parse_json(text : String) : Workload
    raise ArgumentError.new("workload manifest is too large") if text.bytesize.to_u64 > MAX_MANIFEST_BYTES
    parser = JSON::PullParser.new(text)
    root = read_any(parser)
    raise ArgumentError.new("workload manifest has trailing data") unless parser.kind.eof?
    parse_root(root)
  rescue ex : JSON::ParseException
    raise ArgumentError.new("workload manifest is not valid JSON")
  end

  private def parse_root(root : JSON::Any) : Workload
    object = root.as_h
    reject_unknown_fields!(object, ["version", "fixture", "expected_rows", "columns", "checksum"])
    version = required(object, "version").as_i?
    raise ArgumentError.new("workload manifest version must be 2") unless version == VERSION

    fixture = required_string(object, "fixture")
    raise ArgumentError.new("fixture must be non-empty") if fixture.empty?
    raise ArgumentError.new("fixture must be absolute and non-root") unless fixture.starts_with?("/") && fixture != "/"

    expected_rows = required_u64(object, "expected_rows", positive: true)
    columns_value = required(object, "columns")
    columns_array = begin
      columns_value.as_a
    rescue ex : TypeCastError
      raise ArgumentError.new("columns must be an array")
    end
    raise ArgumentError.new("columns must not be empty") if columns_array.empty?
    raise ArgumentError.new("column count exceeds the controlled limit") if columns_array.size > MAX_COLUMNS

    columns = Array(ColumnSpec).new(columns_array.size)
    seen_names = [] of String
    columns_array.each do |column_value|
      column = begin
        column_value.as_h
      rescue ex : TypeCastError
        raise ArgumentError.new("each column must be an object")
      end
      reject_unknown_fields!(column, ["name", "expected_checksum"])
      name = required_string(column, "name")
      raise ArgumentError.new("column names must be non-empty") if name.empty?
      raise ArgumentError.new("column name exceeds the controlled limit") if name.bytesize > MAX_COLUMN_NAME_BYTES
      raise ArgumentError.new("column names must be unique") if seen_names.includes?(name)
      seen_names << name
      checksum = required_u64(column, "expected_checksum")
      columns << ColumnSpec.new(name, checksum)
    end

    checksum = begin
      required(object, "checksum").as_h
    rescue ex : TypeCastError
      raise ArgumentError.new("checksum metadata must be an object")
    end
    reject_unknown_fields!(checksum, ["algorithm", "initial", "multiplier", "order"])
    algorithm = required_string(checksum, "algorithm")
    initial = required_u64(checksum, "initial")
    multiplier = required_u64(checksum, "multiplier", allow_hex: true)
    order = required_string(checksum, "order")
    unless algorithm == CHECKSUM_ALGORITHM && initial == CHECKSUM_INITIAL &&
           multiplier == CHECKSUM_MULTIPLIER && order == CHECKSUM_ORDER
      raise ArgumentError.new("checksum metadata does not match u64_mul_xor")
    end

    Workload.new(fixture, expected_rows, columns)
  rescue ex : TypeCastError
    raise ArgumentError.new("workload manifest has invalid field types")
  end

  private def reject_unknown_fields!(object : Hash(String, JSON::Any), allowed : Array(String)) : Nil
    object.each_key do |key|
      raise ArgumentError.new("workload manifest has unknown fields") unless allowed.includes?(key)
    end
  end

  private def required(object : Hash(String, JSON::Any), key : String) : JSON::Any
    object[key]? || raise ArgumentError.new("workload manifest is missing #{key}")
  end

  private def required_string(object : Hash(String, JSON::Any), key : String) : String
    value = required(object, key)
    value.as_s
  rescue ex : TypeCastError
    raise ArgumentError.new("#{key} must be a string")
  end

  private def required_u64(
    object : Hash(String, JSON::Any),
    key : String,
    *,
    positive : Bool = false,
    allow_hex : Bool = false,
  ) : UInt64
    value = required(object, key)
    parsed = case raw = value.raw
             when Int64
               raise ArgumentError.new("#{key} must be non-negative") if raw < 0
               raw.to_u64
             when String
               parse_u64_string(raw, key, allow_hex)
             else
               raise ArgumentError.new("#{key} must be a non-negative integer")
             end
    raise ArgumentError.new("#{key} must be positive") if positive && parsed == 0_u64
    parsed
  end

  private def parse_u64_string(raw : String, key : String, allow_hex : Bool) : UInt64
    parsed = if allow_hex && raw.starts_with?("0x")
               raw.to_u64?(base: 16, whitespace: false, prefix: true)
             else
               raw.to_u64?(whitespace: false)
             end
    parsed || raise ArgumentError.new("#{key} must be a non-negative integer")
  end

  # JSON::Any stores integers as Int64.  Keep an out-of-range integer token as
  # a String so UInt64 checksums remain representable without weakening the
  # manifest's type checks.
  private def read_any(parser : JSON::PullParser, depth : Int = 0) : JSON::Any
    raise ArgumentError.new("workload manifest is too deeply nested") if depth > MAX_NESTING_DEPTH
    case parser.kind
    when .null?
      JSON::Any.new(parser.read_null)
    when .bool?
      JSON::Any.new(parser.read_bool)
    when .int?
      raw = parser.raw_value
      parser.read_raw
      if parsed = raw.to_i64?(whitespace: false)
        JSON::Any.new(parsed)
      else
        JSON::Any.new(raw)
      end
    when .float?
      JSON::Any.new(parser.read_float)
    when .string?
      JSON::Any.new(parser.read_string)
    when .begin_array?
      parser.read_begin_array
      values = [] of JSON::Any
      until parser.kind.end_array?
        values << read_any(parser, depth + 1)
      end
      parser.read_end_array
      JSON::Any.new(values)
    when .begin_object?
      parser.read_begin_object
      values = {} of String => JSON::Any
      until parser.kind.end_object?
        key = parser.read_object_key
        raise ArgumentError.new("workload manifest has duplicate object keys") if values.has_key?(key)
        values[key] = read_any(parser, depth + 1)
      end
      parser.read_end_object
      JSON::Any.new(values)
    else
      raise ArgumentError.new("workload manifest is empty")
    end
  end
end
