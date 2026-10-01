require "json"
require "file_utils"
require "../src/crystal_click"

W104_VERSION            = "26.7.1.1315"
W104_KEYS               = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64, 15_u64, 18_u64]
W104_ALL_ROWS           = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32, 5_i32, 6_i32, 7_i32, 8_i32]
W104_SELECTED           = [2_i32, 3_i32, 4_i32, 5_i32, 6_i32, 7_i32]
W104_MARK_BOUNDARIES    = [0_i32, 2_i32, 4_i32, 6_i32, 8_i32, 9_i32]
W104_MARK_ROWS          = [2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
W104_SHAPES             = ["scalar", "nullable", "array", "array_nullable", "array_array", "array_array_nullable", "tuple"]
W104_PAIR_READER_SHAPES = ["array", "array_nullable", "array_array", "array_array_nullable", "tuple"]
W104_CORE_ZONES         = ["UTC", "America/New_York"]
W104_ALIAS_ZONES        = ["Etc/UTC", "US/Eastern"]
W104_FIXED_ZONES        = [
  "Fixed/UTC+00:00:00", "Fixed/UTC-00:00:00",
  "Fixed/UTC+00:15:00", "Fixed/UTC-00:15:00",
  "Fixed/UTC+01:00:00", "Fixed/UTC-01:00:00",
  "Fixed/UTC+05:45:00", "Fixed/UTC-05:45:00",
  "Fixed/UTC+13:45:00", "Fixed/UTC+14:00:00", "Fixed/UTC-14:00:00",
]
W104_MALFORMED_FIXED_ZONES = [
  "Fixed/UTC+00:75:00", "Fixed/UTC+01:14:60", "Fixed/UTC+14:15:00",
]

enum W104PartProfile
  Stock
  LibraryWriter
end

struct W104Temporal
  getter name : String
  getter family : String
  getter precision : Int32
  getter zone : String?
  getter schema_zone : String?

  def initialize(@name : String, @family : String, @precision : Int32, @zone : String?, @schema_zone : String? = nil)
  end

  def declaration : String
    base = if @family == "DateTime"
             "DateTime"
           else
             "DateTime64(#{@precision})"
           end
    if zone = (@schema_zone || @zone)
      if @family == "DateTime"
        "DateTime('#{zone}')"
      else
        "DateTime64(#{@precision}, '#{zone}')"
      end
    else
      base
    end
  end

  def width : Int32
    @family == "DateTime" ? 4 : 8
  end

  def raw_values : Array(Int64)
    if @family == "DateTime"
      [
        0_i64,
        1_i64,
        1_615_705_199_i64,
        1_615_705_200_i64,
        1_615_705_201_i64,
        1_636_264_799_i64,
        1_636_264_800_i64,
        1_636_264_801_i64,
        4_294_967_295_i64,
      ]
    else
      factor = 1_i64
      @precision.times { factor *= 10_i64 }
      [
        Int64::MIN,
        -1_i64,
        0_i64,
        1_615_705_200_i64 * factor + 1_i64,
        1_615_705_200_i64 * factor - 1_i64,
        1_615_705_200_i64 * factor,
        1_636_264_800_i64 * factor - 1_i64,
        1_636_264_800_i64 * factor,
        Int64::MAX,
      ]
    end
  end
end

struct W104Field
  getter name : String
  getter temporal : W104Temporal
  getter shape : String

  def initialize(@name : String, @temporal : W104Temporal, @shape : String)
  end

  def type_name : String
    leaf = @temporal.declaration
    case @shape
    when "scalar", "tuple"
      leaf
    when "nullable"
      "Nullable(#{leaf})"
    when "array"
      "Array(#{leaf})"
    when "array_nullable"
      "Array(Nullable(#{leaf}))"
    when "array_array"
      "Array(Array(#{leaf}))"
    when "array_array_nullable"
      "Array(Array(Nullable(#{leaf})))"
    else
      raise "unknown W104 shape #{@shape}"
    end
  end

  def column_type_name : String
    if @shape == "tuple"
      "Tuple(ts #{@temporal.declaration}, tag UInt8)"
    else
      type_name
    end
  end

  def substreams : Array(String)
    case @shape
    when "scalar"
      [@name]
    when "nullable"
      ["#{@name}.null", @name]
    when "array"
      ["#{@name}.size0", @name]
    when "array_nullable"
      ["#{@name}.size0", "#{@name}.null", @name]
    when "array_array"
      ["#{@name}.size0", "#{@name}.size1", @name]
    when "array_array_nullable"
      ["#{@name}.size0", "#{@name}.size1", "#{@name}.null", @name]
    when "tuple"
      ["#{@name}%2Ets", "#{@name}%2Etag"]
    else
      raise "unknown W104 shape #{@shape}"
    end
  end
end

struct W104Cell
  getter scalar : Int64?
  getter array : Array(Int64?)
  getter nested : Array(Array(Int64?))

  def initialize(@scalar : Int64?, @array : Array(Int64?), @nested : Array(Array(Int64?)))
  end
end

class W104ByteMismatchError < Exception
end

def w104_u64_le(value : UInt64, width : Int32 = 8) : String
  output = IO::Memory.new
  width.times do |index|
    output.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8)
  end
  output.to_s
end

def w104_i64_le(value : Int64, width : Int32) : String
  w104_u64_le(value.unsafe_as(UInt64), width)
end

def w104_raw_bytes(temporal : W104Temporal, raw : Int64) : String
  w104_i64_le(raw, temporal.width)
end

def w104_varuint(value : UInt64) : String
  output = IO::Memory.new
  remaining = value
  while remaining >= 0x80_u64
    output.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  output.write_byte(remaining.to_u8)
  output.to_s
end

def w104_nullable_rowbinary(temporal : W104Temporal, value : Int64?) : String
  output = IO::Memory.new
  if raw = value
    output.write_byte(0_u8)
    output << w104_raw_bytes(temporal, raw)
  else
    output.write_byte(1_u8)
  end
  output.to_s
end

def w104_cell(shape : String, temporal : W104Temporal, row : Int32) : W104Cell
  raw = temporal.raw_values[row]
  scalar = nil.as(Int64?)
  array = [] of Int64?
  nested = [] of Array(Int64?)

  case shape
  when "scalar"
    scalar = raw
  when "nullable"
    scalar = nil if row == 1 || row == 7
    scalar = 0_i64 if row == 2
    scalar = raw unless row == 1 || row == 2 || row == 7
  when "array"
    case row
    when 6
    when 0
      array << raw
    when 1
      array << temporal.raw_values[1]
    when 2
      array << 0_i64
      array << raw
    when 3, 5
      array << raw
    when 4
      array << temporal.raw_values[4]
      array << temporal.raw_values[5]
    when 7
      array << raw
      array << 0_i64
    else
      array << raw
    end
  when "array_nullable"
    case row
    when 5
    when 0
      array << raw
    when 1
      array << nil
    when 2
      array << 0_i64
    when 3
      array << nil
      array << raw
    when 4
      array << raw
    when 6
      array << raw
      array << nil
    when 7
      array << 0_i64
      array << raw
    else
      array << nil
      array << raw
    end
  when "array_array"
    case row
    when 5
    when 0
      nested << [raw] of Int64?
    when 1
      nested << ([] of Int64?)
    when 2
      nested << [raw] of Int64?
    when 3
      nested << ([] of Int64?)
      nested << [raw] of Int64?
    when 4
      nested << [0_i64, temporal.raw_values[4]] of Int64?
      nested << [temporal.raw_values[5]] of Int64?
    when 6
      nested << [raw] of Int64?
    when 7
      nested << [raw, 0_i64] of Int64?
      nested << ([] of Int64?)
    else
      nested << [raw, 0_i64] of Int64?
    end
  when "array_array_nullable"
    case row
    when 5
    when 0
      nested << [raw] of Int64?
    when 1
      nested << ([] of Int64?)
    when 2
      nested << [raw] of Int64?
    when 3
      nested << ([] of Int64?)
      nested << [raw] of Int64?
    when 4
      nested << [nil, temporal.raw_values[4]] of Int64?
      nested << [0_i64] of Int64?
    when 6
      nested << [raw, nil] of Int64?
    when 7
      nested << [0_i64, raw] of Int64?
      nested << ([] of Int64?)
    else
      nested << [nil, raw] of Int64?
    end
  when "tuple"
    scalar = raw
  else
    raise "unknown W104 shape #{shape}"
  end

  W104Cell.new(scalar, array, nested)
end

def w104_physical_fragments(field : W104Field) : Hash(String, Array(String))
  streams = Hash(String, Array(String)).new do |hash, name|
    hash[name] = [] of String
  end
  W104_ALL_ROWS.each do |row|
    cell = w104_cell(field.shape, field.temporal, row)
    fragments = Hash(String, String).new
    case field.shape
    when "scalar", "tuple"
      fragments[field.substreams[0]] = w104_raw_bytes(field.temporal, cell.scalar || 0_i64)
      if field.shape == "tuple"
        fragments[field.substreams[1]] = w104_u64_le((row + 1).to_u64, 1)
      end
    when "nullable"
      fragments["#{field.name}.null"] = cell.scalar.nil? ? "\x01" : "\x00"
      fragments[field.name] = w104_raw_bytes(field.temporal, cell.scalar || 0_i64)
    when "array", "array_nullable"
      # ClickHouse serializes one size per source row here. The typed reader
      # may turn these lengths into cumulative offsets, but the physical
      # size0 stream itself is not that cumulative representation.
      fragments["#{field.name}.size0"] = w104_u64_le(cell.array.size.to_u64)
      data = IO::Memory.new
      nulls = IO::Memory.new
      cell.array.each do |value|
        if field.shape == "array_nullable"
          nulls.write_byte(value.nil? ? 1_u8 : 0_u8)
        end
        data << w104_raw_bytes(field.temporal, value || 0_i64)
      end
      fragments[field.name] = data.to_s
      fragments["#{field.name}.null"] = nulls.to_s if field.shape == "array_nullable"
    when "array_array", "array_array_nullable"
      # Each row contributes its own outer length to size0; size1 similarly
      # stores each inner-array length, not a prefix sum across the part.
      fragments["#{field.name}.size0"] = w104_u64_le(cell.nested.size.to_u64)
      inner_offsets = IO::Memory.new
      data = IO::Memory.new
      nulls = IO::Memory.new
      cell.nested.each do |inner|
        inner_offsets << w104_u64_le(inner.size.to_u64)
        inner.each do |value|
          if field.shape == "array_array_nullable"
            nulls.write_byte(value.nil? ? 1_u8 : 0_u8)
          end
          data << w104_raw_bytes(field.temporal, value || 0_i64)
        end
      end
      fragments["#{field.name}.size1"] = inner_offsets.to_s
      fragments[field.name] = data.to_s
      fragments["#{field.name}.null"] = nulls.to_s if field.shape == "array_array_nullable"
    else
      raise "unsupported W104 physical shape #{field.shape}"
    end

    field.substreams.each do |stream|
      streams[stream] << (fragments[stream]? || "")
    end
  end

  streams
end

def w104_rowbinary_field(field : W104Field, row : Int32) : String
  cell = w104_cell(field.shape, field.temporal, row)
  case field.shape
  when "scalar"
    w104_raw_bytes(field.temporal, cell.scalar || 0_i64)
  when "nullable"
    w104_nullable_rowbinary(field.temporal, cell.scalar)
  when "array", "array_nullable"
    output = IO::Memory.new
    output << w104_varuint(cell.array.size.to_u64)
    cell.array.each do |value|
      if field.shape == "array_nullable"
        output << w104_nullable_rowbinary(field.temporal, value)
      else
        output << w104_raw_bytes(field.temporal, value || 0_i64)
      end
    end
    output.to_s
  when "array_array", "array_array_nullable"
    output = IO::Memory.new
    output << w104_varuint(cell.nested.size.to_u64)
    cell.nested.each do |inner|
      output << w104_varuint(inner.size.to_u64)
      inner.each do |value|
        if field.shape == "array_array_nullable"
          output << w104_nullable_rowbinary(field.temporal, value)
        else
          output << w104_raw_bytes(field.temporal, value || 0_i64)
        end
      end
    end
    output.to_s
  when "tuple"
    w104_raw_bytes(field.temporal, cell.scalar || 0_i64) + w104_u64_le((row + 1).to_u64, 1)
  else
    raise "unsupported W104 rowbinary shape #{field.shape}"
  end
end

def w104_expected_rowbinary(fields : Array(W104Field), rows : Array(Int32), include_keys : Bool = true) : String
  output = IO::Memory.new
  rows.each do |row|
    output << w104_u64_le(W104_KEYS[row]) if include_keys
    fields.each { |field| output << w104_rowbinary_field(field, row) }
  end
  output.to_s
end

def w104_zone_suffix(zone : String) : String
  zone.gsub("+", "plus").gsub("-", "minus").gsub(/[^A-Za-z0-9]+/, "_").downcase
end

def w104_all_fields(shape : String, zones : Array(String), schema_zones : Hash(Tuple(String, String), String)) : Array(W104Field)
  temporals = [] of W104Temporal
  zones.each do |zone|
    suffix = w104_zone_suffix(zone)
    schema_zone = schema_zones[{zone, "DateTime"}]?
    temporals << W104Temporal.new("dt_#{suffix}", "DateTime", 0, zone, schema_zone)
  end
  (0..9).each do |precision|
    zones.each do |zone|
      suffix = w104_zone_suffix(zone)
      schema_zone = schema_zones[{zone, "DateTime64"}]?
      temporals << W104Temporal.new("dt64_p#{precision}_#{suffix}", "DateTime64", precision, zone, schema_zone)
    end
  end
  temporals.map do |temporal|
    prefix = shape == "tuple" ? "tuple_" : "payload_"
    W104Field.new("#{prefix}#{temporal.name}", temporal, shape)
  end
end

def w104_legacy_fields(shape : String) : Array(W104Field)
  [
    W104Field.new("legacy_datetime", W104Temporal.new("legacy_datetime", "DateTime", 0, nil), shape),
    W104Field.new("legacy_datetime64_p3", W104Temporal.new("legacy_datetime64_p3", "DateTime64", 3, nil), shape),
  ]
end

def w104_clickhouse(binary : String, store : String, query : String, input : IO? = nil) : String
  output = IO::Memory.new
  error = IO::Memory.new
  result = if input
             Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  raise "ClickHouse query failed (#{result.exit_code}): #{error}\n#{query}" unless result.success?
  output.to_s
end

def w104_try_clickhouse(binary : String, store : String, query : String) : Tuple(Bool, String, String)
  output = IO::Memory.new
  error = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
  {result.success?, output.to_s, error.to_s}
end

def w104_create_table(binary : String, store : String, table : String, fields : Array(W104Field)) : Nil
  definitions = ["pk UInt64"] of String
  fields.each { |field| definitions << "#{field.name} #{field.column_type_name}" }
  settings = "index_granularity = 2, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, ratio_of_defaults_for_sparse_serialization = 0.9375, default_compression_codec = 'LZ4'"
  w104_clickhouse(
    binary,
    store,
    "CREATE TABLE default.#{table} (#{definitions.join(", ")}) ENGINE = MergeTree ORDER BY pk SETTINGS #{settings}"
  )
  nil
end

def w104_insert(binary : String, store : String, table : String, fields : Array(W104Field)) : Nil
  input = IO::Memory.new(w104_expected_rowbinary(fields, W104_ALL_ROWS).to_slice)
  w104_clickhouse(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  nil
end

def w104_part_path(binary : String, store : String, table : String) : String
  rows = w104_clickhouse(
    binary,
    store,
    "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw"
  ).lines.map(&.strip).reject(&.empty?)
  raise "#{table}: expected exactly one active part, got #{rows.inspect}" unless rows.size == 1
  columns = rows[0].split('\t')
  raise "#{table}: malformed part row #{rows[0].inspect}" unless columns.size == 3
  raise "#{table}: expected Wide part, got #{columns[1]}" unless columns[1] == "Wide"
  raise "#{table}: expected #{W104_KEYS.size} rows, got #{columns[2]}" unless columns[2] == W104_KEYS.size.to_s
  columns[0]
end

def w104_schema(binary : String, store : String, table : String, fields : Array(W104Field)) : Array(String)
  actual = w104_clickhouse(
    binary,
    store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
  ).lines.map(&.strip)
  expected_names = ["pk"] + fields.map(&.name)
  names = actual.map { |entry| entry.split(' ', 2)[0] }
  raise "#{table}: system.columns name/order mismatch: #{actual.inspect}" unless names == expected_names

  fields.each_with_index do |field, index|
    observed_type = actual[index + 1].split(' ', 2)[1]? || raise "#{table}: system.columns omitted type for #{field.name}"
    raise "#{table}: system.columns type for #{field.name} is #{observed_type.inspect}, expected exact stock declaration #{field.column_type_name.inspect}" unless observed_type == field.column_type_name
  end
  actual
end

def w104_expected_substreams(fields : Array(W104Field)) : String
  lines = [
    "columns substreams version: 1",
    "#{fields.size + 1} columns:",
    "1 substreams for column `pk`:",
    "\tpk",
  ]
  fields.each do |field|
    substreams = field.substreams
    lines << "#{substreams.size} substreams for column `#{field.name}`:"
    substreams.each { |stream| lines << "\t#{stream}" }
  end
  lines.join("\n") + "\n"
end

def w104_expected_columns(schema : Array(String)) : String
  lines = ["columns format version: 1", "#{schema.size} columns:"]
  schema.each do |entry|
    name, type = entry.split(' ', 2)
    lines << "`#{name}` #{type}"
  end
  lines.join("\n") + "\n"
end

def w104_read_mark_entries(part : String, stream : String) : Array({UInt64, UInt64, UInt64})
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{stream}: truncated .mrk2 record" unless bytes.size % mark_size == 0
  Array({UInt64, UInt64, UInt64}).new(bytes.size // mark_size) do |index|
    offset = index * mark_size
    fields = Array(UInt64).new(3) do |field|
      start = offset + field * 8
      8.times.reduce(0_u64) { |value, byte| value | (bytes[start + byte].to_u64 << (byte * 8)) }
    end
    {fields[0], fields[1], fields[2]}
  end
end

def w104_expected_marks(fragments : Array(String)) : Array({UInt64, UInt64, UInt64})
  W104_MARK_BOUNDARIES.each_with_index.map do |boundary, index|
    decompressed = fragments[0, boundary].sum(&.bytesize).to_u64
    {0_u64, decompressed, W104_MARK_ROWS[index]}
  end.to_a
end

def w104_literal_frame_size(raw_size : Int32) : UInt64
  raise "writer mark fixture has an empty frame" if raw_size <= 0

  # ClickHouse's compressed envelope is 16 checksum bytes plus a 9-byte
  # frame header. The writer emits an LZ4 literal-only sequence: one token,
  # the raw bytes, and (for lengths >= 15) the standard literal-length bytes.
  # This is independent size arithmetic; it does not call the production
  # encoder or inspect observed .mrk2 offsets.
  extension_bytes = raw_size < 15 ? 0 : ((raw_size - 15) // 255) + 1
  (25 + 1 + raw_size + extension_bytes).to_u64
end

def w104_expected_library_writer_marks(fragments : Array(String)) : Array({UInt64, UInt64, UInt64})
  raise "writer mark fixture row count differs" unless fragments.size == W104_ALL_ROWS.size

  marks = [] of {UInt64, UInt64, UInt64}
  compressed_offset = 0_u64
  (W104_MARK_ROWS.size - 1).times do |mark_index|
    first_row = W104_MARK_BOUNDARIES[mark_index]
    after_last_row = W104_MARK_BOUNDARIES[mark_index + 1]
    row_count = after_last_row - first_row
    raise "writer mark boundary/count mismatch at mark #{mark_index}" unless row_count.to_u64 == W104_MARK_ROWS[mark_index]

    raw_chunk = fragments[first_row, row_count].join
    marks << {compressed_offset, 0_u64, W104_MARK_ROWS[mark_index]}
    # Empty flattened Array/Nullable leaf chunks have a mark but no frame;
    # their following file offset therefore remains unchanged.
    compressed_offset += w104_literal_frame_size(raw_chunk.bytesize) unless raw_chunk.empty?
  end
  marks << {compressed_offset, 0_u64, 0_u64}
  marks
end

def w104_expected_physical(fields : Array(W104Field)) : Hash(String, Array(String))
  streams = Hash(String, Array(String)).new
  key_fragments = W104_KEYS.map { |key| w104_u64_le(key) }
  streams["pk"] = key_fragments
  fields.each do |field|
    w104_physical_fragments(field).each do |name, fragments|
      raise "duplicate expected physical stream #{name}" if streams.has_key?(name)
      streams[name] = fragments
    end
  end
  streams
end

def w104_temporal_stream(field : W104Field) : String
  field.shape == "tuple" ? field.substreams[0] : field.substreams.last
end

def w104_assert_equal_zone_bytes(fields : Array(W104Field), part : String, label : String, verbose : Bool = true) : Nil
  groups = Hash(String, Array(W104Field)).new do |hash, key|
    hash[key] = [] of W104Field
  end
  fields.each do |field|
    next unless field.temporal.zone
    key = "#{field.temporal.family}:#{field.temporal.precision}"
    groups[key] << field
  end

  compared_groups = 0
  groups.each do |profile, members|
    next if members.size < 2
    first = members[0]
    first_stream = w104_temporal_stream(first)
    first_bytes = CrystalClick::CompressedBlock.decode_all(
      File.read(File.join(part, "#{CrystalClick::StreamName.hash(first_stream)}.bin")).to_slice
    )
    members[1..].each do |member|
      stream = w104_temporal_stream(member)
      bytes = CrystalClick::CompressedBlock.decode_all(
        File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
      )
      w104_assert_bytes(String.new(bytes), String.new(first_bytes), "#{label} same #{profile} raw bytes across #{first.temporal.zone} and #{member.temporal.zone}")
    end
    compared_groups += 1
  end
  puts "PASS #{label}: zone-qualified columns retain identical raw epoch/tick streams" if verbose && compared_groups > 0
end

def w104_validate_serialization(part : String, fields : Array(W104Field), shape : String, label : String, profile : W104PartProfile = W104PartProfile::Stock, verbose : Bool = true) : Nil
  serialization_path = File.join(part, "serialization.json")
  if profile == W104PartProfile::LibraryWriter && shape == "scalar"
    raise "#{label}: scalar temporal writer unexpectedly emitted serialization.json" if File.exists?(serialization_path) || File.symlink?(serialization_path)
    checksums = CrystalClick::PartChecksums.open(part)
    raise "#{label}: scalar temporal writer checksums unexpectedly list serialization.json" unless checksums.entry("serialization.json").nil?
    puts "PASS #{label}: scalar temporal Default profile omits serialization.json and its checksum entry" if verbose
    return
  end

  raise "#{label}: serialization.json is missing" unless File.file?(serialization_path)
  if profile == W104PartProfile::LibraryWriter
    checksums = CrystalClick::PartChecksums.open(part)
    raise "#{label}: writer serialization.json checksum entry is missing" if checksums.entry("serialization.json").nil?
    checksums.validate_selected_entries(part, "serialization.json")
  end
  info = JSON.parse(File.read(serialization_path)).as_h
  if profile == W104PartProfile::LibraryWriter
    expected_keys = Set{"columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"}
    raise "#{label}: writer serialization.json fields differ: #{info.keys.to_set.inspect}" unless info.keys.to_set == expected_keys
  end
  raise "#{label}: serialization.json version differs" unless info["version"]?.try(&.as_i) == 1
  raise "#{label}: nested serialization flag differs" unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: type versions missing"
  raise "#{label}: type versions differ" unless versions == {"string" => JSON::Any.new(1_i64)}
  records = info["columns"]?.try(&.as_a) || raise "#{label}: serialization columns missing"

  case shape
  when "scalar"
    expected_names = (["pk"] + fields.map(&.name)).sort
    actual_names = records.map { |record| record.as_h["name"]?.try(&.as_s) || raise "#{label}: serializer name missing" }.sort
    raise "#{label}: scalar serializer names differ: #{actual_names.inspect}" unless actual_names == expected_names
    records.each do |record|
      entry = record.as_h
      name = entry["name"].as_s
      defaults = if name == "pk"
                   0
                 else
                   field = fields.find { |item| item.name == name }.not_nil!
                   field.temporal.raw_values.count(&.zero?)
                 end
      raise "#{label}: #{name} serializer kind differs" unless entry["kind"]?.try(&.as_s) == "Default"
      raise "#{label}: #{name} serializer row count differs" unless entry["num_rows"]?.try(&.as_i) == W104_KEYS.size.to_i64
      raise "#{label}: #{name} serializer default count differs" unless entry["num_defaults"]?.try(&.as_i) == defaults.to_i64
    end
  when "nullable"
    if profile == W104PartProfile::LibraryWriter
      raise "#{label}: Nullable writer metadata must use the exact empty-column serializer profile" unless records.empty?
    else
      names = records.map { |record| record.as_h["name"]?.try(&.as_s) || raise "#{label}: serializer name missing" }
      raise "#{label}: Nullable serialization statistics differ: #{names.inspect}" unless names == ["pk"]
      entry = records[0].as_h
      raise "#{label}: Nullable primary-key statistics differ" unless entry["kind"]?.try(&.as_s) == "Default" && entry["num_rows"]?.try(&.as_i) == W104_KEYS.size.to_i64 && entry["num_defaults"]?.try(&.as_i) == 0
    end
  when "array", "array_nullable", "array_array", "array_array_nullable"
    if profile == W104PartProfile::LibraryWriter
      raise "#{label}: Array writer metadata must use the exact empty-column serializer profile" unless records.empty?
    else
      expected_pk = JSON.parse(%({"kind":"Default","name":"pk","num_defaults":0,"num_rows":#{W104_KEYS.size}})).as_h
      actual_pk = records[0]?.try(&.as_h)
      unless records.size == 1 && actual_pk == expected_pk
        raise "#{label}: Array primary-key serialization statistics differ: #{records.map(&.to_json).inspect}"
      end
    end
  when "tuple"
    expected_names = (["pk"] + fields.map(&.name)).sort
    actual_names = records.map { |record| record.as_h["name"]?.try(&.as_s) || raise "#{label}: Tuple serializer name missing" }.sort
    raise "#{label}: Tuple serializer roots differ: #{actual_names.inspect}" unless actual_names == expected_names
    records.each do |record|
      root = record.as_h
      name = root["name"].as_s
      raise "#{label}: Tuple root serializer kind differs for #{name}" unless root["kind"]?.try(&.as_s) == "Default"
      raise "#{label}: Tuple root row count differs for #{name}" unless root["num_rows"]?.try(&.as_i) == W104_KEYS.size.to_i64
      defaults = name == "pk" ? 0_i64 : 0_i64
      raise "#{label}: Tuple root defaults differ for #{name}" unless root["num_defaults"]?.try(&.as_i) == defaults
      next if name == "pk"
      children = root["subcolumns"]?.try(&.as_a) || raise "#{label}: Tuple child statistics missing for #{name}"
      raise "#{label}: Tuple child count differs for #{name}" unless children.size == 2
      field = fields.find { |item| item.name == name }.not_nil!
      temporal_defaults = field.temporal.raw_values.count(&.zero?).to_i64
      [temporal_defaults, 0_i64].each_with_index do |count, index|
        child = children[index].as_h
        raise "#{label}: Tuple child row count differs for #{name}" unless child["num_rows"]?.try(&.as_i) == W104_KEYS.size.to_i64
        raise "#{label}: Tuple child default count differs for #{name} index #{index}" unless child["num_defaults"]?.try(&.as_i) == count
      end
    end
  else
    raise "unknown W104 serializer profile #{shape}"
  end
  puts "PASS #{label}: serialization.json version and shape-specific default statistics" if verbose
end

def w104_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  difference = 0
  while difference < limit && actual.to_slice[difference] == expected.to_slice[difference]
    difference += 1
  end
  observed = difference < actual.bytesize ? actual.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  wanted = difference < expected.bytesize ? expected.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  raise W104ByteMismatchError.new("#{label} differs: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first difference #{difference}: expected #{wanted}, got #{observed}")
end

def w104_seeded_wrong_expectation(actual : String, expected : String, label : String) : Nil
  w104_assert_bytes(actual, expected, "#{label} baseline")
  raise "#{label}: cannot seed an empty expectation" if expected.empty?
  damaged = String.build { |io| io << expected }
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 0x01_u8
  rejected = false
  begin
    w104_assert_bytes(actual, damaged, "#{label} seeded wrong expectation")
  rescue ex : W104ByteMismatchError
    rejected = true
  end
  raise "#{label}: byte comparator accepted a seeded one-byte defect" unless rejected
  puts "PASS #{label}: comparator rejects a seeded one-byte expected-byte defect"
end

def w104_assert_layout(
  fields : Array(W104Field),
  schema : Array(String),
  part : String,
  shape : String,
  label : String,
  verbose : Bool = true,
  mark_profile : W104PartProfile = W104PartProfile::Stock,
) : Nil
  expected_columns = w104_expected_columns(schema)
  actual_columns = File.read(File.join(part, "columns.txt"))
  raise "#{label}: columns.txt exact schema differs:\n#{actual_columns}" unless actual_columns == expected_columns
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  expected_substreams = w104_expected_substreams(fields)
  raise "#{label}: columns_substreams.txt differs:\n#{actual_substreams}" unless actual_substreams == expected_substreams
  raise "#{label}: LZ4 codec metadata differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  raise "#{label}: metadata version differs" unless File.read(File.join(part, "metadata_version.txt")) == "0"
  raise "#{label}: checksums.txt is missing" unless File.file?(File.join(part, "checksums.txt"))

  expected_physical = w104_expected_physical(fields)
  expected_bins = expected_physical.keys.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.bin" }.sort
  expected_marks = expected_physical.keys.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.mrk2" }.sort
  entries = Dir.children(part)
  actual_bins = entries.select(&.ends_with?(".bin")).sort
  actual_marks = entries.select(&.ends_with?(".mrk2")).sort
  raise "#{label}: complete .bin inventory differs" unless actual_bins == expected_bins
  raise "#{label}: complete .mrk2 inventory differs" unless actual_marks == expected_marks
  raise "#{label}: compressed marks are out of profile" unless entries.none?(&.ends_with?(".cmrk2"))
  raise "#{label}: legacy marks are out of profile" unless entries.none?(&.ends_with?(".mrk"))

  expected_physical.each do |stream, row_fragments|
    stream_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
    encoded = File.read(stream_path).to_slice
    decoded = CrystalClick::CompressedBlock.decode_all(encoded)
    expected = row_fragments.join
    w104_assert_bytes(String.new(decoded), expected, "#{label} #{stream} independent physical bytes")
    observed_marks = w104_read_mark_entries(part, stream)
    expected_marks_for_stream = case mark_profile
                                when W104PartProfile::Stock
                                  w104_expected_marks(row_fragments)
                                when W104PartProfile::LibraryWriter
                                  w104_expected_library_writer_marks(row_fragments)
                                else
                                  raise "unknown W104 mark profile #{mark_profile}"
                                end
    raise "#{label} #{stream} exact .mrk2 entries differ: observed #{observed_marks.inspect}; expected #{expected_marks_for_stream.inspect}" unless observed_marks == expected_marks_for_stream
  end

  w104_assert_equal_zone_bytes(fields, part, label, verbose)

  w104_validate_serialization(part, fields, shape, label, mark_profile, verbose)
  puts "PASS #{label}: exact schema/substreams, all decoded raw bytes, complete streams and exact mark tuples" if verbose
end

def w104_assert_rowbinary(binary : String, store : String, table : String, fields : Array(W104Field), label : String, verbose : Bool = true) : Nil
  selection = (["pk"] + fields.map(&.name)).join(", ")
  full = w104_clickhouse(binary, store, "SELECT #{selection} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  expected_full = w104_expected_rowbinary(fields, W104_ALL_ROWS)
  w104_assert_bytes(full, expected_full, "#{label} full stock RowBinary")
  selected = w104_clickhouse(binary, store, "SELECT #{selection} FROM default.#{table} WHERE pk >= 4 AND pk < 16 ORDER BY pk FORMAT RowBinary")
  expected_selected = w104_expected_rowbinary(fields, W104_SELECTED)
  w104_assert_bytes(selected, expected_selected, "#{label} selected stock RowBinary")
  puts "PASS #{label}: full and selected RowBinary independently match hand-built raw fixture bytes" if verbose
end

def w104_check_table(binary : String, store : String, table : String, part : String) : Nil
  actual = w104_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table} CHECK TABLE mismatch: #{actual.inspect}, expected #{expected.inspect}" unless actual == expected
end

def w104_qualify_stock(binary : String, store : String, table : String, fields : Array(W104Field), shape : String, label : String, verbose : Bool = true) : String
  w104_create_table(binary, store, table, fields)
  w104_insert(binary, store, table, fields)
  part = w104_part_path(binary, store, table)
  schema = w104_schema(binary, store, table, fields)
  w104_assert_layout(fields, schema, part, shape, "#{label} source", verbose)
  w104_check_table(binary, store, table, part)
  w104_assert_rowbinary(binary, store, table, fields, "#{label} source", verbose)
  puts "PASS #{label} source: stock schema, part bytes, marks, CHECK and RowBinary qualified" if verbose
  part
end

def w104_attach_part(
  binary : String,
  store : String,
  table : String,
  fields : Array(W104Field),
  part : String,
  verbose : Bool = true,
  mark_profile : W104PartProfile = W104PartProfile::Stock,
) : String
  w104_create_table(binary, store, table, fields)
  data_path = w104_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: no ClickHouse data path" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  part_name = File.basename(part.chomp("/"))
  FileUtils.cp_r(part, File.join(detached, part_name))
  w104_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART '#{part_name}'")
  attached = w104_part_path(binary, store, table)
  schema = w104_schema(binary, store, table, fields)
  w104_assert_layout(fields, schema, attached, fields[0].shape, "#{table} attached", verbose, mark_profile)
  w104_check_table(binary, store, table, attached)
  w104_assert_rowbinary(binary, store, table, fields, "#{table} attached", verbose)
  puts "PASS #{table}: stock-created part ATTACH into exact schema and CHECK TABLE" if verbose
  attached
end

def w104_qualify_reader_pair(binary : String, store : String, shape : String, field : W104Field) : String
  source_table = "w104_pair_source_#{shape}_#{field.name}"
  attached_table = "w104_pair_attached_#{shape}_#{field.name}"
  source_part = w104_qualify_stock(binary, store, source_table, [field], shape, "#{shape} pair #{field.name}", false)
  w104_attach_part(binary, store, attached_table, [field], source_part, false)
end

def w104_reader_expected_rows(first_mark : Int, mark_count : Int) : Array(Int32)
  raise "invalid W104 mark selection" if first_mark < 0 || mark_count < 0 || first_mark + mark_count > W104_MARK_BOUNDARIES.size - 1
  first_row = W104_MARK_BOUNDARIES[first_mark]
  row_after_last_mark = W104_MARK_BOUNDARIES[first_mark + mark_count]
  (first_row...row_after_last_mark).to_a
end

def w104_assert_typed_reader(part : String, field : W104Field, label : String) : Nil
  reader = CrystalClick::WidePart.open_typed(part, field.name)
  raise "#{label}: exact typed declaration changed: #{reader.column_type.inspect} != #{field.column_type_name.inspect}" unless reader.column_type == field.column_type_name
  [{0, W104_MARK_BOUNDARIES.size - 1, "full"}, {1, 2, "selected"}].each do |first_mark, mark_count, selection|
    rows = w104_reader_expected_rows(first_mark, mark_count)
    expected_cells = rows.map { |row| w104_cell(field.shape, field.temporal, row) }
    if field.shape == "tuple"
      data = reader.read_tuple_mark_range(field.name, first_mark, mark_count)
      raise "#{label} #{selection}: tuple declaration changed" unless data.type_name == field.column_type_name
      tuple_fields = data.fields
      raise "#{label} #{selection}: tuple field names/types changed" unless tuple_fields.map { |item| {item.name, item.type_name} } == [{"ts", field.temporal.declaration}, {"tag", "UInt8"}]
      raise "#{label} #{selection}: tuple row count changed" unless data.row_count == rows.size
      rows.each_with_index do |row, index|
        if field.temporal.family == "DateTime"
          expected = CrystalClick::DateTimeValue.new(expected_cells[index].scalar.not_nil!.to_u32)
          raise "#{label} #{selection}: tuple raw seconds changed at row #{row}" unless data.value_as("ts", index, CrystalClick::DateTimeValue) == expected
        else
          expected = CrystalClick::DateTime64Value.new(expected_cells[index].scalar.not_nil!, field.temporal.precision)
          raise "#{label} #{selection}: tuple raw ticks/precision changed at row #{row}" unless data.value_as("ts", index, CrystalClick::DateTime64Value) == expected
        end
        raise "#{label} #{selection}: tuple tag changed at row #{row}" unless data.value_as("tag", index, UInt8) == (row + 1).to_u8
      end
    elsif field.temporal.family == "DateTime"
      case field.shape
      when "scalar"
        actual = reader.read_datetime_seconds_mark_range(field.name, first_mark, mark_count)
        expected = expected_cells.map { |cell| cell.scalar.not_nil!.to_u32 }
      when "nullable"
        actual = reader.read_nullable_datetime_seconds_mark_range(field.name, first_mark, mark_count)
        expected = expected_cells.map { |cell| cell.scalar.try(&.to_u32) }
      when "array"
        actual = reader.read_array_datetime_seconds_mark_range(field.name, first_mark, mark_count)
        expected = expected_cells.map { |cell| cell.array.map { |value| value.not_nil!.to_u32 } }
      when "array_nullable"
        actual = reader.read_array_nullable_datetime_seconds_mark_range(field.name, first_mark, mark_count)
        expected = expected_cells.map { |cell| cell.array.map { |value| value.try(&.to_u32) } }
      when "array_array"
        actual = reader.read_array_array_datetime_seconds_mark_range(field.name, first_mark, mark_count)
        expected = expected_cells.map { |cell| cell.nested.map { |inner| inner.map { |value| value.not_nil!.to_u32 } } }
      when "array_array_nullable"
        actual = reader.read_array_array_nullable_datetime_seconds_mark_range(field.name, first_mark, mark_count)
        expected = expected_cells.map { |cell| cell.nested.map { |inner| inner.map { |value| value.try(&.to_u32) } } }
      else
        raise "unsupported typed DateTime reader shape #{field.shape}"
      end
      raise "#{label} #{selection}: raw epoch seconds changed" unless actual == expected
    else
      case field.shape
      when "scalar"
        actual = reader.read_datetime64_ticks_mark_range(field.name, first_mark, mark_count)
        expected = expected_cells.map { |cell| cell.scalar.not_nil! }
      when "nullable"
        actual = reader.read_nullable_datetime64_ticks_mark_range(field.name, first_mark, mark_count)
        expected = expected_cells.map(&.scalar)
      when "array"
        actual = reader.read_array_datetime64_ticks_mark_range(field.name, first_mark, mark_count)
        expected = expected_cells.map { |cell| cell.array.map(&.not_nil!) }
      when "array_nullable"
        actual = reader.read_array_nullable_datetime64_ticks_mark_range(field.name, first_mark, mark_count)
        expected = expected_cells.map(&.array)
      when "array_array"
        actual = reader.read_array_array_datetime64_ticks_mark_range(field.name, first_mark, mark_count)
        expected = expected_cells.map { |cell| cell.nested.map { |inner| inner.map(&.not_nil!) } }
      when "array_array_nullable"
        actual = reader.read_array_array_nullable_datetime64_ticks_mark_range(field.name, first_mark, mark_count)
        expected = expected_cells.map(&.nested)
      else
        raise "unsupported typed DateTime64 reader shape #{field.shape}"
      end
      raise "#{label} #{selection}: raw DateTime64 ticks changed" unless actual == expected
    end
  end
  nil
end

def w104_profile_slice(values : Array(T)) : Slice(T) forall T
  values.to_unsafe.to_slice(values.size)
end

def w104_library_write_profile(destination : String, field : W104Field) : String
  if field.shape == "tuple"
    tags = W104_ALL_ROWS.map { |row| (row + 1).to_u8 }
    if field.temporal.family == "DateTime"
      temporal_values = W104_ALL_ROWS.map { |row| CrystalClick::DateTimeValue.new(field.temporal.raw_values[row].to_u32) }
      columns = [
        CrystalClick::WideTupleLeafColumn.new("ts", field.temporal.declaration, temporal_values),
        CrystalClick::WideTupleLeafColumn.new("tag", tags),
      ] of CrystalClick::WideTupleLeafColumn
      return CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        destination, "pk", w104_profile_slice(W104_KEYS), field.name, field.column_type_name, columns, 2
      )
    else
      temporal_values = W104_ALL_ROWS.map { |row| CrystalClick::DateTime64Value.new(field.temporal.raw_values[row], field.temporal.precision) }
      columns = [
        CrystalClick::WideTupleLeafColumn.new("ts", field.temporal.declaration, temporal_values),
        CrystalClick::WideTupleLeafColumn.new("tag", tags),
      ] of CrystalClick::WideTupleLeafColumn
      return CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        destination, "pk", w104_profile_slice(W104_KEYS), field.name, field.column_type_name, columns, 2
      )
    end
  end

  time_zone = field.temporal.schema_zone || field.temporal.zone
  if field.temporal.family == "DateTime"
    case field.shape
    when "scalar"
      values = W104_ALL_ROWS.map { |row| w104_cell(field.shape, field.temporal, row).scalar.not_nil!.to_u32 }
      CrystalClick::WidePartWriter.write_uint64_datetime_pair(destination, "pk", w104_profile_slice(W104_KEYS), field.name, w104_profile_slice(values), 2, time_zone: time_zone)
    when "nullable"
      values = W104_ALL_ROWS.map { |row| w104_cell(field.shape, field.temporal, row).scalar.try(&.to_u32) }
      CrystalClick::WidePartWriter.write_uint64_nullable_datetime_pair(destination, "pk", w104_profile_slice(W104_KEYS), field.name, w104_profile_slice(values), 2, time_zone: time_zone)
    when "array"
      values = W104_ALL_ROWS.map { |row| w104_cell(field.shape, field.temporal, row).array.map { |value| value.not_nil!.to_u32 } }
      CrystalClick::WidePartWriter.write_uint64_array_datetime_pair(destination, "pk", w104_profile_slice(W104_KEYS), field.name, w104_profile_slice(values), 2, time_zone: time_zone)
    when "array_nullable"
      values = W104_ALL_ROWS.map { |row| w104_cell(field.shape, field.temporal, row).array.map { |value| value.try(&.to_u32) } }
      CrystalClick::WidePartWriter.write_uint64_array_nullable_datetime_pair(destination, "pk", w104_profile_slice(W104_KEYS), field.name, w104_profile_slice(values), 2, time_zone: time_zone)
    when "array_array"
      values = W104_ALL_ROWS.map { |row| w104_cell(field.shape, field.temporal, row).nested.map { |inner| inner.map { |value| value.not_nil!.to_u32 } } }
      CrystalClick::WidePartWriter.write_uint64_array_array_datetime_pair(destination, "pk", w104_profile_slice(W104_KEYS), field.name, w104_profile_slice(values), 2, time_zone: time_zone)
    when "array_array_nullable"
      values = W104_ALL_ROWS.map { |row| w104_cell(field.shape, field.temporal, row).nested.map { |inner| inner.map { |value| value.try(&.to_u32) } } }
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_datetime_pair(destination, "pk", w104_profile_slice(W104_KEYS), field.name, w104_profile_slice(values), 2, time_zone: time_zone)
    else
      raise "unsupported library DateTime writer shape #{field.shape}"
    end
  else
    precision = field.temporal.precision
    case field.shape
    when "scalar"
      values = W104_ALL_ROWS.map { |row| w104_cell(field.shape, field.temporal, row).scalar.not_nil! }
      CrystalClick::WidePartWriter.write_uint64_datetime64_pair(destination, "pk", w104_profile_slice(W104_KEYS), field.name, w104_profile_slice(values), precision, 2, time_zone: time_zone)
    when "nullable"
      values = W104_ALL_ROWS.map { |row| w104_cell(field.shape, field.temporal, row).scalar }
      CrystalClick::WidePartWriter.write_uint64_nullable_datetime64_pair(destination, "pk", w104_profile_slice(W104_KEYS), field.name, w104_profile_slice(values), precision, 2, time_zone: time_zone)
    when "array"
      values = W104_ALL_ROWS.map { |row| w104_cell(field.shape, field.temporal, row).array.map(&.not_nil!) }
      CrystalClick::WidePartWriter.write_uint64_array_datetime64_pair(destination, "pk", w104_profile_slice(W104_KEYS), field.name, w104_profile_slice(values), precision, 2, time_zone: time_zone)
    when "array_nullable"
      values = W104_ALL_ROWS.map { |row| w104_cell(field.shape, field.temporal, row).array }
      CrystalClick::WidePartWriter.write_uint64_array_nullable_datetime64_pair(destination, "pk", w104_profile_slice(W104_KEYS), field.name, w104_profile_slice(values), precision, 2, time_zone: time_zone)
    when "array_array"
      values = W104_ALL_ROWS.map { |row| w104_cell(field.shape, field.temporal, row).nested.map { |inner| inner.map(&.not_nil!) } }
      CrystalClick::WidePartWriter.write_uint64_array_array_datetime64_pair(destination, "pk", w104_profile_slice(W104_KEYS), field.name, w104_profile_slice(values), precision, 2, time_zone: time_zone)
    when "array_array_nullable"
      values = W104_ALL_ROWS.map { |row| w104_cell(field.shape, field.temporal, row).nested }
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_datetime64_pair(destination, "pk", w104_profile_slice(W104_KEYS), field.name, w104_profile_slice(values), precision, 2, time_zone: time_zone)
    else
      raise "unsupported library DateTime64 writer shape #{field.shape}"
    end
  end
end

def w104_writer_fixture_path(writer_root : String, field : W104Field) : String
  raise "invalid W104 writer profile name #{field.name.inspect}" unless field.name.matches?(/\A(?:payload|tuple)_[a-z0-9_]+\z/)
  profile_root = File.join(writer_root, field.shape, field.name)
  FileUtils.mkdir_p(profile_root)
  File.join(profile_root, "all_1_1_0")
end

def w104_drop_table(binary : String, store : String, table : String) : Nil
  raise "refusing to drop non-oracle table #{table.inspect}" unless table.starts_with?("w104_") && table.matches?(/\Aw104_[a-z0-9_]+\z/)
  raise "refusing to drop table outside fresh temporary oracle store" unless (store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")) && Dir.exists?(store)
  w104_clickhouse(binary, store, "DROP TABLE default.#{table} SYNC")
  nil
end

def w104_remove_fixture(path : String, oracle_root : String) : Nil
  root = File.expand_path(oracle_root)
  target = File.expand_path(path)
  raise "refusing to remove a fixture outside the fresh oracle root" unless target.starts_with?("#{root}/")
  raise "refusing to remove the oracle root itself" if target == root
  FileUtils.rm_rf(target) if Dir.exists?(target)
  nil
end

def w104_batch_type_inventory(batch : CrystalClick::WidePartTableBatch) : Array(Tuple(String, String))
  batch.column_names.map { |name| {name, batch.column_type_for(name)} }
end

def w104_assert_batch_temporal(batch : CrystalClick::WidePartTableBatch, field : W104Field, rows : Array(Int32), label : String) : Nil
  raise "#{label}: batch exact column type changed" unless batch.column_type_for(field.name) == field.column_type_name
  expected_cells = rows.map { |row| w104_cell(field.shape, field.temporal, row) }
  if field.shape == "tuple"
    actual_rows = batch.tuple_rows_for(field.name)
    raise "#{label}: Tuple row count changed" unless actual_rows.size == rows.size
    rows.each_with_index do |row, index|
      actual = actual_rows[index]
      expected_tuple_type = "Tuple(ts #{field.temporal.declaration}, tag UInt8)"
      raise "#{label}: Tuple row type changed" unless actual.type_name == expected_tuple_type
      actual_fields = actual.fields
      expected_fields = [{"ts", field.temporal.declaration}, {"tag", "UInt8"}]
      observed_fields = actual_fields.map { |tuple_field| {tuple_field.name, tuple_field.type_name} }
      raise "#{label}: Tuple row leaf metadata changed" unless observed_fields == expected_fields
      temporal_field = actual_fields.first
      temporal_type = temporal_field.datetime_type || raise "#{label}: Tuple temporal descriptor missing"
      raise "#{label}: Tuple temporal descriptor changed" unless temporal_type.type_name == field.temporal.declaration
      if field.temporal.family == "DateTime"
        expected = CrystalClick::DateTimeValue.new(expected_cells[index].scalar.not_nil!.to_u32)
        raise "#{label}: Tuple raw seconds changed" unless actual.value_as("ts", CrystalClick::DateTimeValue) == expected
      else
        expected = CrystalClick::DateTime64Value.new(expected_cells[index].scalar.not_nil!, field.temporal.precision)
        raise "#{label}: Tuple raw ticks/precision changed" unless actual.value_as("ts", CrystalClick::DateTime64Value) == expected
      end
      raise "#{label}: Tuple tag changed" unless actual.value_as("tag", UInt8) == (row + 1).to_u8
    end
  elsif field.temporal.family == "DateTime"
    case field.shape
    when "scalar"
      expected = expected_cells.map { |cell| cell.scalar.not_nil!.to_u32 }
      raise "#{label}: batch epoch seconds changed" unless batch.datetime_seconds_for(field.name).to_a == expected
    when "nullable"
      expected = expected_cells.map { |cell| cell.scalar.try(&.to_u32) }
      raise "#{label}: batch nullable epoch seconds changed" unless batch.nullable_datetime_seconds_for(field.name).to_a == expected
    when "array"
      expected = expected_cells.map { |cell| cell.array.map { |value| value.not_nil!.to_u32 } }
      raise "#{label}: batch Array epoch seconds changed" unless batch.array_datetime_seconds_for(field.name).to_a == expected
    when "array_nullable"
      expected = expected_cells.map { |cell| cell.array.map { |value| value.try(&.to_u32) } }
      raise "#{label}: batch Array nullable epoch seconds changed" unless batch.array_nullable_datetime_seconds_for(field.name).to_a == expected
    when "array_array"
      expected = expected_cells.map { |cell| cell.nested.map { |inner| inner.map { |value| value.not_nil!.to_u32 } } }
      raise "#{label}: batch nested epoch seconds changed" unless batch.array_array_datetime_seconds_for(field.name).to_a == expected
    when "array_array_nullable"
      expected = expected_cells.map { |cell| cell.nested.map { |inner| inner.map { |value| value.try(&.to_u32) } } }
      raise "#{label}: batch nested nullable epoch seconds changed" unless batch.array_array_nullable_datetime_seconds_for(field.name).to_a == expected
    else
      raise "unsupported W104 batch DateTime shape #{field.shape}"
    end
  else
    case field.shape
    when "scalar"
      expected = expected_cells.map { |cell| cell.scalar.not_nil! }
      raise "#{label}: batch DateTime64 ticks changed" unless batch.datetime64_ticks_for(field.name).to_a == expected
    when "nullable"
      expected = expected_cells.map(&.scalar)
      raise "#{label}: batch nullable DateTime64 ticks changed" unless batch.nullable_datetime64_ticks_for(field.name).to_a == expected
    when "array"
      expected = expected_cells.map { |cell| cell.array.map(&.not_nil!) }
      raise "#{label}: batch Array DateTime64 ticks changed" unless batch.array_datetime64_ticks_for(field.name).to_a == expected
    when "array_nullable"
      expected = expected_cells.map(&.array)
      raise "#{label}: batch Array nullable DateTime64 ticks changed" unless batch.array_nullable_datetime64_ticks_for(field.name).to_a == expected
    when "array_array"
      expected = expected_cells.map { |cell| cell.nested.map { |inner| inner.map(&.not_nil!) } }
      raise "#{label}: batch nested DateTime64 ticks changed" unless batch.array_array_datetime64_ticks_for(field.name).to_a == expected
    when "array_array_nullable"
      expected = expected_cells.map(&.nested)
      raise "#{label}: batch nested nullable DateTime64 ticks changed" unless batch.array_array_nullable_datetime64_ticks_for(field.name).to_a == expected
    else
      raise "unsupported W104 batch DateTime64 shape #{field.shape}"
    end
  end
  nil
end

def w104_catalog_fixture(root : String, part : String, field : W104Field) : Nil
  database_uuid = "10400000-0000-4000-8000-000000000011"
  table_uuid = "10400000-0000-4000-8000-000000000012"
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(File.join(database_path, "events.sql"), "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `#{field.name}` #{field.column_type_name}\n)\nENGINE = MergeTree\nORDER BY pk\n")
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, "all_1_1_0"))
  nil
end

def w104_assert_catalog_materialized_values(table : CrystalClick::OfflineTable, field : W104Field) : Nil
  column = table.columns.find { |entry| entry.name == field.name } || raise "#{field.shape} #{field.name}: catalog column missing"
  raise "#{field.shape} #{field.name}: catalog exact declaration changed" unless column.type == field.column_type_name
  values = table[field.name].values
  raise "#{field.shape} #{field.name}: catalog materialized row count changed" unless values.size == W104_ALL_ROWS.size
  cells = W104_ALL_ROWS.map { |row| w104_cell(field.shape, field.temporal, row) }

  if field.shape == "tuple"
    W104_ALL_ROWS.each_with_index do |row, index|
      actual = values[index].as(CrystalClick::WideTupleRow)
      expected_tuple_type = "Tuple(ts #{field.temporal.declaration}, tag UInt8)"
      raise "#{field.name}: catalog Tuple row type changed" unless actual.type_name == expected_tuple_type
      observed_fields = actual.fields.map { |tuple_field| {tuple_field.name, tuple_field.type_name} }
      expected_fields = [{"ts", field.temporal.declaration}, {"tag", "UInt8"}]
      raise "#{field.name}: catalog Tuple leaf metadata changed" unless observed_fields == expected_fields
      temporal_field = actual.fields.first
      temporal_type = temporal_field.datetime_type || raise "#{field.name}: catalog Tuple temporal descriptor missing"
      raise "#{field.name}: catalog Tuple temporal descriptor changed" unless temporal_type.type_name == field.temporal.declaration
      if field.temporal.family == "DateTime"
        expected = CrystalClick::DateTimeValue.new(cells[index].scalar.not_nil!.to_u32)
        raise "#{field.name}: catalog Tuple epoch seconds changed" unless actual.value_as("ts", CrystalClick::DateTimeValue) == expected
      else
        expected = CrystalClick::DateTime64Value.new(cells[index].scalar.not_nil!, field.temporal.precision)
        raise "#{field.name}: catalog Tuple ticks/precision changed" unless actual.value_as("ts", CrystalClick::DateTime64Value) == expected
      end
      raise "#{field.name}: catalog Tuple tag changed" unless actual.value_as("tag", UInt8) == (row + 1).to_u8
    end
    return nil
  end

  if field.temporal.family == "DateTime"
    case field.shape
    when "scalar"
      expected = cells.map { |cell| cell.scalar.not_nil!.to_u32 }
      raise "#{field.name}: catalog epoch seconds changed" unless values.map { |value| value.as(UInt32) } == expected
    when "nullable"
      expected = cells.map { |cell| cell.scalar.try(&.to_u32) }
      raise "#{field.name}: catalog nullable epoch seconds changed" unless values.map { |value| value.as(UInt32?) } == expected
    when "array"
      expected = cells.map { |cell| cell.array.map { |value| value.not_nil!.to_u32 } }
      raise "#{field.name}: catalog Array epoch seconds changed" unless values.map { |value| value.as(Array(UInt32)) } == expected
    when "array_nullable"
      expected = cells.map { |cell| cell.array.map { |value| value.try(&.to_u32) } }
      raise "#{field.name}: catalog Array nullable epoch seconds changed" unless values.map { |value| value.as(Array(UInt32?)) } == expected
    when "array_array"
      expected = cells.map { |cell| cell.nested.map { |inner| inner.map { |value| value.not_nil!.to_u32 } } }
      raise "#{field.name}: catalog nested epoch seconds changed" unless values.map { |value| value.as(Array(Array(UInt32))) } == expected
    when "array_array_nullable"
      expected = cells.map { |cell| cell.nested.map { |inner| inner.map { |value| value.try(&.to_u32) } } }
      raise "#{field.name}: catalog nested nullable epoch seconds changed" unless values.map { |value| value.as(Array(Array(UInt32?))) } == expected
    else
      raise "unsupported W104 catalog DateTime shape #{field.shape}"
    end
  else
    case field.shape
    when "scalar"
      expected = cells.map { |cell| cell.scalar.not_nil! }
      raise "#{field.name}: catalog DateTime64 ticks changed" unless values.map { |value| value.as(Int64) } == expected
    when "nullable"
      expected = cells.map(&.scalar)
      raise "#{field.name}: catalog nullable DateTime64 ticks changed" unless values.map { |value| value.as(Int64?) } == expected
    when "array"
      expected = cells.map { |cell| cell.array.map(&.not_nil!) }
      raise "#{field.name}: catalog Array DateTime64 ticks changed" unless values.map { |value| value.as(Array(Int64)) } == expected
    when "array_nullable"
      expected = cells.map(&.array)
      raise "#{field.name}: catalog Array nullable DateTime64 ticks changed" unless values.map { |value| value.as(Array(Int64?)) } == expected
    when "array_array"
      expected = cells.map { |cell| cell.nested.map { |inner| inner.map(&.not_nil!) } }
      raise "#{field.name}: catalog nested DateTime64 ticks changed" unless values.map { |value| value.as(Array(Array(Int64))) } == expected
    when "array_array_nullable"
      expected = cells.map(&.nested)
      raise "#{field.name}: catalog nested nullable DateTime64 ticks changed" unless values.map { |value| value.as(Array(Array(Int64?))) } == expected
    else
      raise "unsupported W104 catalog DateTime64 shape #{field.shape}"
    end
  end
  nil
end

def w104_assert_table_catalog_consumers(part : String, field : W104Field, oracle_root : String) : Nil
  exact_columns = [{"pk", "UInt64"}, {field.name, field.column_type_name}]
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", field.name])
  raise "#{field.shape} #{field.name}: table projection type inventory differs" unless table.column_types == exact_columns
  full = [] of Int32
  table.scan_typed do |batch|
    raise "#{field.shape} #{field.name}: table callback type inventory differs" unless w104_batch_type_inventory(batch) == exact_columns
    keys = batch.values_for("pk")
    rows = keys.map { |key| W104_KEYS.index(key).not_nil! }.to_a
    w104_assert_batch_temporal(batch, field, rows, "table full scan")
    full.concat(rows)
    nil
  end
  raise "#{field.shape} #{field.name}: table full scan row order differs" unless full == W104_ALL_ROWS

  selected = [] of Int32
  table.scan_typed_window(2_u64, 4) do |batch|
    raise "#{field.shape} #{field.name}: table window callback type inventory differs" unless w104_batch_type_inventory(batch) == exact_columns
    rows = batch.values_for("pk").map { |key| W104_KEYS.index(key).not_nil! }.to_a
    w104_assert_batch_temporal(batch, field, rows, "table row window")
    selected.concat(rows)
    nil
  end
  raise "#{field.shape} #{field.name}: table row-window bounds differ" unless selected == [2_i32, 3_i32, 4_i32, 5_i32]

  catalog_root = File.join(oracle_root, "catalog_#{field.shape}_#{field.name}")
  w104_catalog_fixture(catalog_root, part, field)
  offline = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
  w104_assert_catalog_materialized_values(offline, field)
  catalog_full = [] of Int32
  offline.scan_typed(["pk", field.name]) do |batch|
    raise "#{field.shape} #{field.name}: catalog full callback type inventory differs" unless w104_batch_type_inventory(batch) == exact_columns
    rows = batch.values_for("pk").map { |key| W104_KEYS.index(key).not_nil! }.to_a
    w104_assert_batch_temporal(batch, field, rows, "catalog full scan")
    catalog_full.concat(rows)
    nil
  end
  raise "#{field.shape} #{field.name}: catalog full scan row order differs" unless catalog_full == W104_ALL_ROWS

  catalog_selected = [] of Int32
  offline.scan_typed_window(["pk", field.name], 2_u64, 4) do |batch|
    raise "#{field.shape} #{field.name}: catalog window callback type inventory differs" unless w104_batch_type_inventory(batch) == exact_columns
    rows = batch.values_for("pk").map { |key| W104_KEYS.index(key).not_nil! }.to_a
    w104_assert_batch_temporal(batch, field, rows, "catalog row window")
    catalog_selected.concat(rows)
    nil
  end
  raise "#{field.shape} #{field.name}: catalog row-window bounds differ" unless catalog_selected == [2_i32, 3_i32, 4_i32, 5_i32]
  puts "PASS #{field.shape}: table and OfflineCatalog full/window consumers retain exact type and raw temporal values"
  nil
end

def w104_type_probe(binary : String, store : String, zone : String, family : String) : String?
  expression = if family == "DateTime"
                 "toDateTime(0, '#{zone}')"
               else
                 "toDateTime64(0, 9, '#{zone}')"
               end
  query = "SELECT toTypeName(#{expression}) FORMAT TSVRaw"
  success, output, error = w104_try_clickhouse(binary, store, query)
  if success
    observed = output.strip
    puts "OBSERVED pinned ClickHouse type admission: input=#{family}(#{zone}); output=#{observed}"
    observed
  else
    puts "OBSERVED pinned ClickHouse does not admit probe #{family} zone #{zone}: #{error.lines.first?.try(&.strip) || "query rejected"}"
    nil
  end
end

def w104_schema_zone_from_type(observed : String, family : String, zone : String) : String
  expected_prefix = family == "DateTime" ? "DateTime(" : "DateTime64(9, "
  raise "pinned type probe for #{family} '#{zone}' returned unexpected type #{observed.inspect}" unless observed.starts_with?(expected_prefix)
  match = observed.match(/\('([^']+)'\)/) || observed.match(/,\s*'([^']+)'\)/) || raise "pinned type probe did not preserve a named zone for #{family} '#{zone}': #{observed.inspect}"
  match[1]
end

def w104_extra_scalar_zones(binary : String, store : String, manifest : Array(String)) : Tuple(Array(String), Hash(Tuple(String, String), String))
  zones = [] of String
  schema_zones = Hash(Tuple(String, String), String).new
  W104_ALIAS_ZONES.each do |zone|
    raise "pinned time-zone manifest lacks required alias #{zone}" unless manifest.includes?(zone)
    dt = w104_type_probe(binary, store, zone, "DateTime")
    dt64 = w104_type_probe(binary, store, zone, "DateTime64")
    raise "pinned stock binary must admit required alias #{zone} for DateTime and DateTime64" unless dt && dt64
    zones << zone
    schema_zones[{zone, "DateTime"}] = w104_schema_zone_from_type(dt, "DateTime", zone)
    schema_zones[{zone, "DateTime64"}] = w104_schema_zone_from_type(dt64, "DateTime64", zone)
  end
  W104_FIXED_ZONES.each do |zone|
    dt = w104_type_probe(binary, store, zone, "DateTime")
    dt64 = w104_type_probe(binary, store, zone, "DateTime64")
    raise "pinned stock binary must admit required fixed zone #{zone} for DateTime and DateTime64" unless dt && dt64
    zones << zone
    schema_zones[{zone, "DateTime"}] = w104_schema_zone_from_type(dt, "DateTime", zone)
    schema_zones[{zone, "DateTime64"}] = w104_schema_zone_from_type(dt64, "DateTime64", zone)
  end
  {zones, schema_zones}
end

def w104_probe_malformed_fixed_zones(binary : String, store : String) : Nil
  W104_MALFORMED_FIXED_ZONES.each do |zone|
    {"DateTime", "DateTime64"}.each do |family|
      observed = w104_type_probe(binary, store, zone, family)
      if observed_type = observed
        puts "OBSERVED malformed fixed suffix #{family} #{zone}: admitted as #{observed_type}"
      else
        puts "OBSERVED malformed fixed suffix #{family} #{zone}: rejected by pinned storage binary"
      end
    end
  end
end

def w104_reader_positive_controls(
  fields_by_shape : Hash(String, Array(W104Field)),
  parts_by_shape : Hash(String, String),
  pair_control_parts_by_shape : Hash(String, Hash(String, String)),
) : Nil
  fields_by_shape.each do |shape, fields|
    control_fields = fields.select { |field| field.temporal.zone.nil? }
    control_fields.each do |field|
      part = if pair_parts = pair_control_parts_by_shape[shape]?
               pair_parts[field.name]? || raise "#{shape} #{field.name}: missing two-column bare control part"
             else
               parts_by_shape[shape]
             end
      reader = CrystalClick::WidePart.open_typed(part, field.name)
      raise "#{shape} #{field.name}: legacy column type mismatch" unless reader.column_type == field.column_type_name
    end
    raise "#{shape}: missing bare DateTime/DateTime64 legacy controls" unless control_fields.size == 2
    puts "PASS #{shape}: bare DateTime and DateTime64(3) typed-reader positive controls"
  end
end

def w104_reader_rejections(
  fields_by_shape : Hash(String, Array(W104Field)),
  parts_by_shape : Hash(String, Hash(String, String)),
) : Nil
  count = 0
  expected_count = 0
  fields_by_shape.each do |shape, fields|
    parts = parts_by_shape[shape]? || raise "#{shape}: missing qualified reader probe parts"
    raise "#{shape}: reader RED includes a bare control field" unless fields.all? { |field| !field.temporal.zone.nil? }
    raise "#{shape}: qualified field/part inventory differs" unless parts.size == fields.size && fields.all? { |field| parts.has_key?(field.name) }
    expected_count += fields.size
    shape_count = 0
    fields.each do |field|
      part = parts[field.name]
      begin
        CrystalClick::WidePart.open_typed(part, field.name)
      rescue ex : CrystalClick::UnsupportedFormatError
        count += 1
        shape_count += 1
      rescue ex
        raise "#{shape} #{field.name}: expected qualified-type UnsupportedFormatError after stock qualification, got #{ex.class}: #{ex.message}"
      else
        raise "#{shape} #{field.name}: current typed reader unexpectedly admitted #{field.column_type_name}"
      end
    end
    raise "#{shape}: typed reader rejected #{shape_count}/#{fields.size} qualified fields" unless shape_count == fields.size
  end
  raise "qualified reader RED covered #{count} fields, expected exactly #{expected_count}" unless count == expected_count
  puts "PASS existing reader RED: #{count} qualified type declarations rejected only after all stock source/ATTACH certificates"
end

def w104_dst_text_control(binary : String, store : String) : Nil
  query = "SELECT toString(toDateTime(1615705200, 'UTC')), toString(toDateTime(1615705200, 'America/New_York')), toString(toDateTime(1636264800, 'UTC')), toString(toDateTime(1636264800, 'America/New_York')) FORMAT TSVRaw"
  actual = w104_clickhouse(binary, store, query).strip
  expected = "2021-03-14 07:00:00\t2021-03-14 03:00:00\t2021-11-07 06:00:00\t2021-11-07 01:00:00"
  raise "UTC/NY opposite-frame DST text control differs: #{actual.inspect}" unless actual == expected
  puts "PASS UTC/NY opposite-frame control: same epoch seconds, distinct spring/fall local text"
end

def w104_validate_manifest(binary : String, store : String, manifest_path : String) : Array(String)
  expected = File.read(manifest_path).lines.map(&.strip).reject(&.empty?)
  actual = w104_clickhouse(binary, store, "SELECT time_zone FROM system.time_zones ORDER BY time_zone FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "stock timezone manifest mismatch: fixture=#{expected.size} names, binary=#{actual.size} names" unless actual == expected
  raise "stock timezone manifest is not unique" unless expected.uniq == expected
  raise "stock timezone manifest is not sorted" unless expected == expected.sort
  ["UTC", "America/New_York", "Etc/UTC", "US/Eastern"].each do |zone|
    raise "stock time-zone manifest lacks #{zone}" unless expected.includes?(zone)
  end
  puts "PASS pinned stock timezone manifest: #{actual.size} names; UTC, America/New_York and aliases present"
  actual
end

def w104_run_green_writer_smoke(
  binary : String,
  store : String,
  schema_zones : Hash(Tuple(String, String), String),
) : Nil
  oracle_root = File.dirname(store)
  writer_root = File.join(oracle_root, "writer_mark_smoke")
  FileUtils.mkdir_p(writer_root)

  profiles = w104_all_fields("scalar", ["UTC"], schema_zones).select do |field|
    field.temporal.family == "DateTime"
  end
  raise "writer mark smoke must select exactly one scalar UTC DateTime profile" unless profiles.size == 1
  field = profiles.first
  raise "writer mark smoke profile differs" unless field.name == "payload_dt_utc" && field.column_type_name == "DateTime('UTC')"

  path = w104_writer_fixture_path(writer_root, field)
  w104_library_write_profile(path, field)
  schema = ["pk UInt64", "#{field.name} #{field.column_type_name}"]
  w104_assert_layout(
    [field], schema, path, field.shape, "writer mark smoke source", false,
    W104PartProfile::LibraryWriter
  )

  attached_table = "w104_writer_mark_smoke"
  attached_part = w104_attach_part(
    binary,
    store,
    attached_table,
    [field],
    path,
    false,
    W104PartProfile::LibraryWriter
  )
  w104_assert_typed_reader(attached_part, field, "writer mark smoke attached reader")

  w104_drop_table(binary, store, attached_table)
  w104_remove_fixture(File.dirname(path), writer_root)
  puts "PASS W104 writer mark smoke: exactly one scalar UTC DateTime profile; ATTACH/CHECK/RowBinary/typed reader verified"
  nil
end

def w104_run_green_reader(binary : String, store : String, schema_zones : Hash(Tuple(String, String), String)) : Nil
  fields_by_shape = Hash(String, Array(W104Field)).new
  attached_parts_by_shape = Hash(String, String).new
  stock_zoned_count = 0

  # Preserve the exhaustive multi-column stock source/ATTACH qualification
  # before consuming any current typed-reader path.
  W104_SHAPES.each do |shape|
    zones = shape == "scalar" ? W104_CORE_ZONES + (W104_ALIAS_ZONES + W104_FIXED_ZONES) : W104_CORE_ZONES
    fields = w104_all_fields(shape, zones, schema_zones) + w104_legacy_fields(shape)
    source_table = "w104_source_#{shape}"
    source_part = w104_qualify_stock(binary, store, source_table, fields, shape, "#{shape} stock source", false)
    attached_table = "w104_attached_#{shape}"
    attached_part = w104_attach_part(binary, store, attached_table, fields, source_part, false)
    fields_by_shape[shape] = fields
    attached_parts_by_shape[shape] = attached_part
    stock_zoned_count += fields.count { |field| !field.temporal.zone.nil? }
    puts "PASS #{shape}: exact stock source + ATTACH matrix (#{fields.count { |field| !field.temporal.zone.nil? }} zoned declarations)"
  end
  raise "stock matrix covered #{stock_zoned_count} zoned declarations, expected 297" unless stock_zoned_count == 297
  w104_dst_text_control(binary, store)

  typed_read_count = 0
  {"scalar", "nullable"}.each do |shape|
    fields = fields_by_shape[shape]
    attached_part = attached_parts_by_shape[shape]
    fields.each do |field|
      w104_assert_typed_reader(attached_part, field, "stock #{shape} #{field.name}")
      typed_read_count += 1 if field.temporal.zone
    end
  end

  # The existing Array and named-flat Tuple admission is a real UInt64
  # key/value pair. Qualify and consume these stock profiles individually,
  # then remove only the two explicitly named W104 tables for that profile.
  W104_PAIR_READER_SHAPES.each do |shape|
    controls = w104_legacy_fields(shape)
    qualified = w104_all_fields(shape, W104_CORE_ZONES, schema_zones)
    (controls + qualified).each do |field|
      attached_part = w104_qualify_reader_pair(binary, store, shape, field)
      table_part = "w104_pair_attached_#{shape}_#{field.name}"
      w104_assert_typed_reader(attached_part, field, "stock paired #{shape} #{field.name}")
      typed_read_count += 1 if field.temporal.zone
      w104_drop_table(binary, store, "w104_pair_source_#{shape}_#{field.name}")
      w104_drop_table(binary, store, table_part)
    end
    puts "PASS #{shape}: #{qualified.size} zoned and #{controls.size} bare stock two-column reader profiles"
  end
  raise "typed-reader matrix covered #{typed_read_count} zoned declarations, expected 297" unless typed_read_count == 297

  # The scalar/Nullable matrix parts are the valid reader pair layouts for
  # those shapes. The five higher-rank shapes were independently consumed
  # from their exact paired stock profiles above.
  W104_SHAPES.each do |shape|
    w104_drop_table(binary, store, "w104_source_#{shape}")
    w104_drop_table(binary, store, "w104_attached_#{shape}")
  end
  puts "PASS W104 stock-reader GREEN: #{stock_zoned_count} stock declarations attached and #{typed_read_count} typed reads"
  nil
end

def w104_run_green_writer(binary : String, store : String, schema_zones : Hash(Tuple(String, String), String)) : Nil
  oracle_root = File.dirname(store)
  writer_root = File.join(oracle_root, "writer_parts")
  FileUtils.mkdir_p(writer_root)
  library_written_count = 0
  consumer_profiles = [] of String
  seeded_shapes = [] of String
  observed_raw = Hash(String, String).new
  writer_fields = W104_SHAPES.flat_map do |shape|
    zones = shape == "scalar" ? W104_CORE_ZONES + W104_ALIAS_ZONES + W104_FIXED_ZONES : W104_CORE_ZONES
    w104_all_fields(shape, zones, schema_zones)
  end
  raise "writer profile matrix has #{writer_fields.size} declarations, expected 297" unless writer_fields.size == 297

  writer_fields.each do |field|
    path = w104_writer_fixture_path(writer_root, field)
    w104_library_write_profile(path, field)
    schema = ["pk UInt64", "#{field.name} #{field.column_type_name}"]
    w104_assert_layout(
      [field], schema, path, field.shape, "library #{field.shape} #{field.name}", false,
      W104PartProfile::LibraryWriter
    )
    attached_table = "w104_writer_attached_#{field.shape}_#{field.name}"
    attached_part = w104_attach_part(binary, store, attached_table, [field], path, false, W104PartProfile::LibraryWriter)
    w104_assert_typed_reader(attached_part, field, "library attached #{field.shape} #{field.name}")

    stream = w104_temporal_stream(field)
    bytes = CrystalClick::CompressedBlock.decode_all(File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice)
    key = "#{field.shape}:#{field.temporal.family}:#{field.temporal.precision}"
    if previous = observed_raw[key]?
      w104_assert_bytes(String.new(bytes), previous, "library #{key} same raw bytes across time zones")
    else
      observed_raw[key] = String.new(bytes)
    end
    unless seeded_shapes.includes?(field.shape)
      expected_bytes = w104_physical_fragments(field)[stream].join
      w104_seeded_wrong_expectation(String.new(bytes), expected_bytes, "library #{field.shape} comparator")
      seeded_shapes << field.shape
    end

    consumer_family = field.temporal.family
    consumer_precision = consumer_family == "DateTime" || field.temporal.precision == 3
    consumer_key = "#{field.shape}:#{consumer_family}"
    if field.temporal.zone == "America/New_York" && consumer_precision && !consumer_profiles.includes?(consumer_key)
      w104_assert_table_catalog_consumers(attached_part, field, oracle_root)
      consumer_profiles << consumer_key
      catalog_root = File.join(oracle_root, "catalog_#{field.shape}_#{field.name}")
      w104_remove_fixture(catalog_root, oracle_root)
    end

    w104_drop_table(binary, store, attached_table)
    w104_remove_fixture(File.dirname(path), writer_root)
    library_written_count += 1
    if library_written_count % 25 == 0
      puts "PROGRESS W104 writer profiles: #{library_written_count}/#{writer_fields.size}"
    end
  end
  raise "library writer/stock-ATTACH/readback covered #{library_written_count} profiles, expected 297" unless library_written_count == 297
  expected_consumer_profiles = W104_SHAPES.flat_map do |shape|
    ["#{shape}:DateTime", "#{shape}:DateTime64"]
  end
  raise "table/catalog consumer profiles differ" unless consumer_profiles.size == 14 && consumer_profiles.sort == expected_consumer_profiles.sort
  raise "seeded byte comparator checks differ by shape" unless seeded_shapes.size == W104_SHAPES.size && seeded_shapes.sort == W104_SHAPES.sort
  puts "PASS library writer -> exact stock ATTACH/CHECK/full+selected RowBinary -> typed reader: #{library_written_count} profiles"
  puts "PASS W104 writer GREEN: #{library_written_count} writer profiles, #{consumer_profiles.size} table/catalog consumers, and #{seeded_shapes.size} seeded shape checks"
  nil
end

def w104_run_green(binary : String, store : String, schema_zones : Hash(Tuple(String, String), String)) : Nil
  w104_run_green_reader(binary, store, schema_zones)
  w104_run_green_writer(binary, store, schema_zones)
  puts "PASS bidirectional W104 Green: reader and writer phases completed"
  nil
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["W104_CLICKHOUSE_STORE"]? || raise "set W104_CLICKHOUSE_STORE to a fresh temporary ClickHouse store"
manifest_path = ENV["W104_ZONE_MANIFEST"]? || raise "set W104_ZONE_MANIFEST to the versioned stock name fixture"
version = ENV["W104_ORACLE_VERSION"]? || raise "set W104_ORACLE_VERSION from the checked ClickHouse executable"
raise "oracle requires ClickHouse #{W104_VERSION}, got #{version}" unless version.includes?(W104_VERSION)
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary ClickHouse store path: #{store}"
end
raise "ClickHouse store must be fresh and empty" unless Dir.exists?(store) && Dir.empty?(store)

arguments = ARGV
valid_arguments = arguments.size == 1 && (
  arguments[0] == "--red" ||
  arguments[0] == "--green" ||
  arguments[0] == "--green-reader" ||
  arguments[0] == "--green-writer" ||
  arguments[0] == "--green-writer-smoke"
)
raise "this instrument supports --red, --green, --green-reader, --green-writer, or --green-writer-smoke" unless valid_arguments

manifest = w104_validate_manifest(binary, store, manifest_path)
extra_zones, schema_zones = w104_extra_scalar_zones(binary, store, manifest)
w104_probe_malformed_fixed_zones(binary, store)

if arguments == ["--green"]
  w104_run_green(binary, store, schema_zones)
  puts "PASS W104 timezone-qualified temporal GREEN oracle"
  exit
end

if arguments == ["--green-reader"]
  w104_run_green_reader(binary, store, schema_zones)
  puts "PASS W104 timezone-qualified temporal reader phase"
  exit
end

if arguments == ["--green-writer"]
  w104_run_green_writer(binary, store, schema_zones)
  puts "PASS W104 timezone-qualified temporal writer phase"
  exit
end

if arguments == ["--green-writer-smoke"]
  w104_run_green_writer_smoke(binary, store, schema_zones)
  puts "PASS W104 writer-mark smoke mode (one profile; not exhaustive GREEN)"
  exit
end

fields_by_shape = Hash(String, Array(W104Field)).new
parts_by_shape = Hash(String, String).new
qualified_part_paths = Hash(String, String).new

W104_SHAPES.each do |shape|
  zones = shape == "scalar" ? W104_CORE_ZONES + extra_zones : W104_CORE_ZONES
  qualified = w104_all_fields(shape, zones, schema_zones)
  fields = qualified + w104_legacy_fields(shape)
  table = "w104_source_#{shape}"
  part = w104_qualify_stock(binary, store, table, fields, shape, "#{shape} qualified stock profile")
  fields_by_shape[shape] = fields
  qualified_part_paths[shape] = part
end

# Re-run all attached checks only after each stock source part is independently qualified.
W104_SHAPES.each do |shape|
  fields = fields_by_shape[shape]
  source_part = qualified_part_paths[shape]
  target = "w104_attached_#{shape}"
  attached_part = w104_attach_part(binary, store, target, fields, source_part)
  parts_by_shape[shape] = attached_part
end

w104_dst_text_control(binary, store)

# Array and named-flat Tuple reader admission is intentionally restricted to
# genuine UInt64-key/value pair metadata. Keep the multidimensional matrix
# above for exhaustive physical qualification, and independently certify
# reader-shaped two-column source + ATTACH parts before any typed-reader call.
pair_control_parts_by_shape = Hash(String, Hash(String, String)).new
reader_fields_by_shape = Hash(String, Array(W104Field)).new
reader_parts_by_shape = Hash(String, Hash(String, String)).new

W104_SHAPES.each do |shape|
  if W104_PAIR_READER_SHAPES.includes?(shape)
    controls = w104_legacy_fields(shape)
    qualified = w104_all_fields(shape, W104_CORE_ZONES, schema_zones)
    profile_parts = Hash(String, String).new
    (controls + qualified).each do |field|
      profile_parts[field.name] = w104_qualify_reader_pair(binary, store, shape, field)
    end
    control_parts = Hash(String, String).new
    controls.each { |field| control_parts[field.name] = profile_parts[field.name] }
    pair_control_parts_by_shape[shape] = control_parts
    reader_fields_by_shape[shape] = qualified
    qualified_parts = Hash(String, String).new
    qualified.each { |field| qualified_parts[field.name] = profile_parts[field.name] }
    reader_parts_by_shape[shape] = qualified_parts
    puts "PASS #{shape}: #{controls.size} bare controls and #{qualified.size} zoned pair profiles stock-qualified and attached"
  else
    qualified = fields_by_shape[shape].select { |field| !field.temporal.zone.nil? }
    reader_fields_by_shape[shape] = qualified
    qualified_parts = Hash(String, String).new
    qualified.each { |field| qualified_parts[field.name] = parts_by_shape[shape] }
    reader_parts_by_shape[shape] = qualified_parts
  end
end

w104_reader_positive_controls(fields_by_shape, parts_by_shape, pair_control_parts_by_shape)

# All bare positive controls above use valid reader layouts. No qualified-type
# reader probe is allowed below until pair-shaped columns have exact two-column
# source + ATTACH certificates as well as the full multi-column storage matrix.
fields_by_shape.each do |shape, fields|
  fields.each do |field|
    next if field.temporal.zone.nil?
    expected_stream = w104_temporal_stream(field)
    expected_fragments = w104_expected_physical([field])[expected_stream]
    part = qualified_part_paths[shape]
    actual = CrystalClick::CompressedBlock.decode_all(File.read(File.join(part, "#{CrystalClick::StreamName.hash(expected_stream)}.bin")).to_slice)
    expected = expected_fragments.join
    w104_seeded_wrong_expectation(String.new(actual), expected, "#{shape} #{field.name}")
    break
  end
end

w104_reader_rejections(reader_fields_by_shape, reader_parts_by_shape)
puts "PASS W104 qualified storage RED: seven-shape physical matrix; pair-shaped reader RED uses exact two-column stock parts for DateTime and DateTime64(0..9), UTC/NY"
