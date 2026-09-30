require "file_utils"
require "../src/crystal_click"

# W98 pre-production discriminator. This deliberately uses the existing public
# reader APIs and a pinned stock producer; it is not the final bidirectional
# oracle and does not change production code.
W98_STOCK_VERSION      = "26.7.1.1315"
W98_ROW_COUNT          = 259
W98_NULL_ROW           = 258
W98_TABLE_PREFIX       = "w98_bool_semantics"
W98_DOMAIN_CODES       = Array(UInt8).new(256) { |index| index.to_u8 }
W98_PHYSICAL_PREFIX    = [0_u8, 1_u8, 1_u8] + Array(UInt8).new(254) { |index| (index + 2).to_u8 }
W98_VARIANT_BOOL_BYTES = [0_u8, 1_u8, 1_u8] + Array(UInt8).new(254) { |index| (index + 2).to_u8 } + [0_u8]
W98_PROFILES           = [
  {"root_bool", "Bool"},
  {"nullable_bool", "Nullable(Bool)"},
  {"array_bool", "Array(Bool)"},
  {"array_nullable_bool", "Array(Nullable(Bool))"},
  {"map_u64_bool", "Array(Map(UInt64, Bool))"},
  {"map_string_bool", "Array(Map(String, Bool))"},
  {"map_u64_nullable_bool", "Array(Map(UInt64, Nullable(Bool)))"},
  {"map_string_nullable_bool", "Array(Map(String, Nullable(Bool)))"},
  {"variant_bool", "Variant(Bool, String, UInt64)"},
] of Tuple(String, String)

private def w98_clickhouse(binary : String, store : String, query : String, input : Bytes? = nil) : {Bool, String, String}
  output = IO::Memory.new
  error = IO::Memory.new
  status = if bytes = input
             source = IO::Memory.new
             source.write(bytes)
             source.rewind
             Process.run(binary, ["local", "--path", store, "--query", query], input: source, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  {status.success?, output.to_s, error.to_s}
end

private def w98_run(binary : String, store : String, query : String) : String
  succeeded, output, error = w98_clickhouse(binary, store, query)
  raise "W98 ClickHouse query failed: #{error}\n#{query}" unless succeeded
  output
end

private def w98_run_input(binary : String, store : String, query : String, bytes : Bytes) : Nil
  succeeded, _output, error = w98_clickhouse(binary, store, query, bytes)
  raise "W98 ClickHouse RowBinary INSERT failed: #{error}\n#{query}" unless succeeded
  nil
end

private def w98_append_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w98_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w98_append_string(io : IO, value : String) : Nil
  w98_append_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

private def w98_code(index : Int32) : UInt8
  case index
  when 0      then 0_u8
  when 1..2   then 1_u8
  when 3..256 then (index - 1).to_u8
  when 257    then 0_u8
  when 258    then 128_u8
  else
    raise "W98 row index outside fixture"
  end
end

private def w98_nullable_items(index : Int32) : Array(UInt8?)
  if index == W98_NULL_ROW
    [128_u8, nil] of UInt8?
  else
    [w98_code(index)] of UInt8?
  end
end

private def w98_append_nullable(io : IO, value : UInt8?) : Nil
  if code = value
    io.write_byte(0_u8)
    io.write_byte(code)
  else
    # RowBinary NullMap byte: this is deliberately not part of the Bool domain.
    io.write_byte(1_u8)
  end
end

private def w98_append_array_map_u64(io : IO, index : Int32, nullable : Bool) : Nil
  w98_append_varuint(io, 1_u64) # one Map in the outer Array
  entry_count = nullable && index == W98_NULL_ROW ? 2_u64 : 1_u64
  w98_append_varuint(io, entry_count)
  entry_count.to_i.times do |entry_index|
    w98_append_u64(io, 7_u64 + entry_index.to_u64)
    if nullable
      value = if index == W98_NULL_ROW && entry_index == 1
                nil
              else
                index == W98_NULL_ROW ? 128_u8 : w98_code(index)
              end
      w98_append_nullable(io, value)
    else
      io.write_byte(w98_code(index))
    end
  end
end

private def w98_append_array_map_string(io : IO, index : Int32, nullable : Bool) : Nil
  w98_append_varuint(io, 1_u64) # one Map in the outer Array
  entry_count = nullable && index == W98_NULL_ROW ? 2_u64 : 1_u64
  w98_append_varuint(io, entry_count)
  entry_count.to_i.times do |entry_index|
    w98_append_string(io, entry_index == 0 ? "k" : "z")
    if nullable
      value = if index == W98_NULL_ROW && entry_index == 1
                nil
              else
                index == W98_NULL_ROW ? 128_u8 : w98_code(index)
              end
      w98_append_nullable(io, value)
    else
      io.write_byte(w98_code(index))
    end
  end
end

private def w98_append_column(io : IO, name : String, index : Int32) : Nil
  code = w98_code(index)
  case name
  when "root_bool"
    io.write_byte(code)
  when "nullable_bool"
    w98_append_nullable(io, index == W98_NULL_ROW ? nil : code)
  when "array_bool"
    w98_append_varuint(io, 1_u64)
    io.write_byte(code)
  when "array_nullable_bool"
    values = w98_nullable_items(index)
    w98_append_varuint(io, values.size.to_u64)
    values.each { |value| w98_append_nullable(io, value) }
  when "map_u64_bool"
    w98_append_array_map_u64(io, index, false)
  when "map_string_bool"
    w98_append_array_map_string(io, index, false)
  when "map_u64_nullable_bool"
    w98_append_array_map_u64(io, index, true)
  when "map_string_nullable_bool"
    w98_append_array_map_string(io, index, true)
  when "variant_bool"
    if index == W98_NULL_ROW
      # Variant NULL tag; tags are independent of the Bool value-byte domain.
      io.write_byte(255_u8)
    else
      io.write_byte(0_u8) # Variant(Bool, String, UInt64) Bool-arm tag
      io.write_byte(code)
    end
  else
    raise "unexpected W98 column #{name}"
  end
  nil
end

private def w98_table_name(profile : String) : String
  "#{W98_TABLE_PREFIX}_#{profile}"
end

private def w98_input_rowbinary(profile : String) : Bytes
  output = IO::Memory.new
  W98_ROW_COUNT.times do |index|
    w98_append_u64(output, (index + 1).to_u64)
    w98_append_column(output, profile, index)
  end
  output.to_slice.dup
end

private def w98_expected_column(name : String) : Bytes
  output = IO::Memory.new
  W98_ROW_COUNT.times { |index| w98_append_column(output, name, index) }
  output.to_slice.dup
end

private def w98_assert_bytes(actual : Bytes, expected : Bytes, label : String) : Nil
  return nil if actual == expected
  offset = 0
  limit = Math.min(actual.size, expected.size)
  while offset < limit && actual[offset] == expected[offset]
    offset += 1
  end
  actual_byte = offset < actual.size ? actual[offset].to_s(16).rjust(2, '0') : "<eof>"
  expected_byte = offset < expected.size ? expected[offset].to_s(16).rjust(2, '0') : "<eof>"
  raise "#{label}: byte mismatch at #{offset} (stock=#{actual_byte}, independent=#{expected_byte}; sizes #{actual.size}/#{expected.size})"
end

private def w98_stream_bytes(part : String, stream : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(path).to_slice
  encoded.empty? ? [] of UInt8 : CrystalClick::CompressedBlock.decode_all(encoded).to_slice.to_a
end

private def w98_assert_prefix(part : String, stream : String, expected : Array(UInt8)) : Nil
  observed = w98_stream_bytes(part, stream)
  raise "#{stream}: physical Bool stream shorter than all-256 prefix" if observed.size < expected.size
  expected.each_with_index do |byte, index|
    raise "#{stream}: physical payload differs at byte #{index}: #{observed[index]} != #{byte}" unless observed[index] == byte
  end
  puts "physical #{stream}: exact prefix containing every UInt8 payload code (#{expected.size} bytes)"
end

private def w98_expected_null_map(nested_nullable_values : Bool) : Array(UInt8)
  entries = [] of UInt8
  W98_ROW_COUNT.times do |index|
    if nested_nullable_values && index == W98_NULL_ROW
      entries << 0_u8 << 1_u8
    else
      entries << (index == W98_NULL_ROW ? 1_u8 : 0_u8)
    end
  end
  entries
end

private def w98_mark_rows(profile : String) : Array(UInt64)
  if profile == "variant_bool"
    Array.new(86, 3_u64) + [1_u64]
  else
    Array.new(129, 2_u64) + [1_u64]
  end
end

private def w98_first_mark_values(profile : String) : Array(Bool)
  profile == "variant_bool" ? [false, true, true] : [false, true]
end

private def w98_first_mark_row_count(profile : String) : Int32
  profile == "variant_bool" ? 3 : 2
end

private def w98_nullable_map_stream(profile : String) : String?
  case profile
  when "nullable_bool", "array_nullable_bool"
    "payload.null"
  when "map_u64_nullable_bool", "map_string_nullable_bool"
    "payload%2Evalues.null"
  else
    nil
  end
end

private def w98_value_stream(profile : String) : String
  case profile
  when "map_u64_bool", "map_string_bool", "map_u64_nullable_bool", "map_string_nullable_bool"
    "payload%2Evalues"
  else
    "payload"
  end
end

private def w98_check_stock(binary : String, store : String, part : String, profile : String, type_name : String) : Nil
  table = w98_table_name(profile)
  check = w98_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected_part = File.basename(part.chomp("/"))
  raise "stock CHECK TABLE failed: #{check.inspect}" unless check == "#{expected_part}\t1"

  expected_types = "pk\tUInt64\npayload\t#{type_name}\n"
  actual_types = w98_run(binary, store, "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  raise "#{profile}: stock declared column types differ:\n#{actual_types}" unless actual_types == expected_types

  serialization = File.read(File.join(part, "serialization.json")).strip
  expected_serialization = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  raise "#{profile}: stock serialization profile is outside the admitted W15/W34/W57/W83 shape: #{serialization}" unless serialization == expected_serialization

  actual = w98_run(binary, store, "SELECT payload FROM default.#{table} ORDER BY pk FORMAT RowBinary").to_slice
  w98_assert_bytes(actual, w98_expected_column(profile), "stock #{profile} RowBinary")
  puts "stock #{profile}: exact UInt64/payload schema, CHECK, and independent RowBinary (#{actual.size} payload bytes)"

  if profile == "variant_bool"
    observed_variant = w98_stream_bytes(part, "payload.Bool")
    w98_assert_bytes(
      observed_variant.to_unsafe.to_slice(observed_variant.size),
      W98_VARIANT_BOOL_BYTES.to_unsafe.to_slice(W98_VARIANT_BOOL_BYTES.size),
      "Variant Bool child physical bytes",
    )
    puts "physical variant_bool: exact payload domain; NULL/tag excluded from Bool bytes"
  else
    w98_assert_prefix(part, w98_value_stream(profile), W98_PHYSICAL_PREFIX)
  end

  if null_stream = w98_nullable_map_stream(profile)
    nested = profile != "nullable_bool"
    expected_null_map = w98_expected_null_map(nested)
    observed = w98_stream_bytes(part, null_stream)
    w98_assert_bytes(observed.to_unsafe.to_slice(observed.size), expected_null_map.to_unsafe.to_slice(expected_null_map.size), "independent null-map #{profile}")
    raise "#{profile}: null-map contains values outside 0/1" unless observed.all? { |value| value <= 1_u8 }
    puts "null-map #{profile}: only 0/1; NULL witness remains separate from Bool payload bytes"
  end
  puts "PASS stock #{profile}: CHECK, exact profile, independent RowBinary and physical bytes"
  nil
end

private def w98_read_profile(reader : CrystalClick::WidePart, name : String, first_mark : Int32) : Nil
  column = "payload"
  case name
  when "root_bool"
    reader.read_bool_mark_range(column, first_mark, 1)
  when "nullable_bool"
    reader.read_nullable_bool_mark_range(column, first_mark, 1)
  when "array_bool"
    reader.read_array_bool_mark_range(column, first_mark, 1)
  when "array_nullable_bool"
    reader.read_array_nullable_bool_mark_range(column, first_mark, 1)
  when "map_u64_bool"
    reader.read_array_map_uint64_bool_mark_range(column, first_mark, 1)
  when "map_string_bool"
    reader.read_array_map_string_bool_mark_range(column, first_mark, 1)
  when "map_u64_nullable_bool"
    reader.read_array_map_uint64_nullable_bool_mark_range(column, first_mark, 1)
  when "map_string_nullable_bool"
    reader.read_array_map_string_nullable_bool_mark_range(column, first_mark, 1)
  when "variant_bool"
    reader.read_variant_bool_string_uint64_mark_range(column, first_mark, 1)
  else
    raise "unexpected W98 profile #{name}"
  end
  nil
end

private def w98_assert_canonical(reader : CrystalClick::WidePart, name : String) : Nil
  column = "payload"
  values = w98_first_mark_values(name)
  array_values = values.map { |value| [value] }
  case name
  when "root_bool"
    raise "root Bool canonical positive control differs" unless reader.read_bool_mark_range(column, 0, 1) == values
  when "nullable_bool"
    raise "Nullable(Bool) canonical positive control differs" unless reader.read_nullable_bool_mark_range(column, 0, 1) == values
  when "array_bool"
    raise "Array(Bool) canonical positive control differs" unless reader.read_array_bool_mark_range(column, 0, 1) == array_values
  when "array_nullable_bool"
    raise "Array(Nullable(Bool)) canonical positive control differs" unless reader.read_array_nullable_bool_mark_range(column, 0, 1) == array_values
  when "map_u64_bool"
    rows = reader.read_array_map_uint64_bool_mark_range(column, 0, 1)
    expected = values.map { |value| [[{7_u64, value}]] }
    raise "Array(Map(UInt64, Bool)) canonical positive control differs" unless rows == expected
  when "map_string_bool"
    rows = reader.read_array_map_string_bool_mark_range(column, 0, 1)
    expected = values.map { |value| [[{"k", value}]] }
    raise "Array(Map(String, Bool)) canonical positive control differs" unless rows == expected
  when "map_u64_nullable_bool"
    rows = reader.read_array_map_uint64_nullable_bool_mark_range(column, 0, 1)
    expected = values.map { |value| [[{7_u64, value}]] }
    raise "Array(Map(UInt64, Nullable(Bool))) canonical positive control differs" unless rows == expected
  when "map_string_nullable_bool"
    rows = reader.read_array_map_string_nullable_bool_mark_range(column, 0, 1)
    expected = values.map { |value| [[{"k", value}]] }
    raise "Array(Map(String, Nullable(Bool))) canonical positive control differs" unless rows == expected
  when "variant_bool"
    rows = reader.read_variant_bool_string_uint64_mark_range(column, 0, 1)
    observed = rows.map { |value| value.as(Bool) }
    raise "Variant(Bool, String, UInt64) canonical positive control differs" unless observed == values
  else
    raise "unexpected W98 profile #{name}"
  end
  nil
end

private def w98_assert_nonzero_semantics(reader : CrystalClick::WidePart, name : String) : Nil
  column = "payload"
  values = Array(Bool).new(w98_first_mark_row_count(name), true)
  array_values = values.map { [true] }
  case name
  when "root_bool"
    raise "root Bool nonzero codes did not become true" unless reader.read_bool_mark_range(column, 1, 1) == values
  when "nullable_bool"
    raise "Nullable(Bool) nonzero codes did not become true" unless reader.read_nullable_bool_mark_range(column, 1, 1) == values
  when "array_bool"
    raise "Array(Bool) nonzero codes did not become true" unless reader.read_array_bool_mark_range(column, 1, 1) == array_values
  when "array_nullable_bool"
    raise "Array(Nullable(Bool)) nonzero codes did not become true" unless reader.read_array_nullable_bool_mark_range(column, 1, 1) == array_values
  when "map_u64_bool"
    rows = reader.read_array_map_uint64_bool_mark_range(column, 1, 1)
    expected = values.map { [[{7_u64, true}]] }
    raise "Array(Map(UInt64, Bool)) nonzero codes did not become true" unless rows == expected
  when "map_string_bool"
    rows = reader.read_array_map_string_bool_mark_range(column, 1, 1)
    expected = values.map { [[{"k", true}]] }
    raise "Array(Map(String, Bool)) nonzero codes did not become true" unless rows == expected
  when "map_u64_nullable_bool"
    rows = reader.read_array_map_uint64_nullable_bool_mark_range(column, 1, 1)
    expected = values.map { [[{7_u64, true}]] }
    raise "Array(Map(UInt64, Nullable(Bool))) nonzero codes did not become true" unless rows == expected
  when "map_string_nullable_bool"
    rows = reader.read_array_map_string_nullable_bool_mark_range(column, 1, 1)
    expected = values.map { [[{"k", true}]] }
    raise "Array(Map(String, Nullable(Bool))) nonzero codes did not become true" unless rows == expected
  when "variant_bool"
    rows = reader.read_variant_bool_string_uint64_mark_range(column, 1, 1)
    raise "Variant Bool nonzero codes did not become true" unless rows.size == values.size && rows.all? { |value| value.as(Bool) }
  else
    raise "unexpected W98 profile #{name}"
  end
  nil
end

private def w98_expected_gap_message(name : String) : String
  case name
  when "root_bool", "nullable_bool"
    "Bool byte is not 0 or 1"
  when "array_bool"
    "Array(Bool) byte is not 0 or 1"
  when "array_nullable_bool"
    "Array(Nullable(Bool)) byte is not 0 or 1"
  when "map_u64_bool", "map_string_bool", "map_u64_nullable_bool", "map_string_nullable_bool"
    "Array(Map) Bool byte is not 0 or 1"
  when "variant_bool"
    "Variant Bool child code is unsupported"
  else
    raise "unexpected W98 profile #{name}"
  end
end

private def w98_probe_library(parts : Hash(String, String)) : Nil
  missing = [] of String
  W98_PROFILES.each do |name, _type|
    part = parts[name]
    reader = CrystalClick::WidePart.open_typed(part, "payload")
    expected_mark_rows = w98_mark_rows(name)
    unless reader.mark_row_counts == expected_mark_rows
      raise "#{name}: stock mark schedule differs: #{reader.mark_row_counts.inspect}"
    end
    w98_assert_canonical(reader, name)
    begin
      w98_assert_nonzero_semantics(reader, name)
      puts "library #{name}: accepted the noncanonical value mark semantically"
    rescue ex : CrystalClick::CorruptPartError
      expected = w98_expected_gap_message(name)
      message = ex.message || ""
      raise "#{name}: unexpected reader error: #{message}" unless message.includes?(expected)
      missing << name
      puts "RED library #{name}: canonical mark passed; nonzero mark rejects (#{message})"
    end
  end

  if missing.empty?
    puts "NO W98 RED: all nine existing readers accepted nonzero Bool payloads"
  else
    puts "EXPECTED W98 RED: #{missing.size}/9 readers still reject stored nonzero Bool payloads: #{missing.join(", ")}"
    exit 1
  end
  nil
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")

unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary CLICKHOUSE_STORE path: #{store}"
end
if Dir.exists?(store)
  raise "CLICKHOUSE_STORE must be empty before probe creation: #{store}" unless Dir.empty?(store)
else
  Dir.mkdir_p(store)
end

unless W98_VARIANT_BOOL_BYTES.uniq.sort == W98_DOMAIN_CODES
  raise "W98 Bool payload fixture does not cover every UInt8 code"
end

version = w98_run(binary, store, "SELECT 1") # initialize/check the selected local store first
raise "unexpected ClickHouse query response: #{version.inspect}" unless version == "1\n"
actual_version = w98_run(binary, store, "SELECT version() FORMAT TSVRaw").strip
raise "W98 requires ClickHouse #{W98_STOCK_VERSION}, got #{actual_version}" unless actual_version == W98_STOCK_VERSION

parts = Hash(String, String).new
W98_PROFILES.each do |profile, type_name|
  table = w98_table_name(profile)
  granularity = profile == "variant_bool" ? 3 : 2
  ddl = <<-SQL
    CREATE TABLE default.#{table}
    (
        `pk` UInt64,
        `payload` #{type_name}
    )
    ENGINE = MergeTree
    ORDER BY pk
    SETTINGS
        index_granularity = #{granularity},
        index_granularity_bytes = 10485760,
        enable_mixed_granularity_parts = 1,
        min_rows_for_wide_part = 0,
        min_bytes_for_wide_part = 0,
        compress_marks = 0,
        compress_primary_key = 0,
        min_compress_block_size = 0,
        max_compress_block_size = 4096,
        ratio_of_defaults_for_sparse_serialization = 1.0,
        write_final_mark = 1,
        default_compression_codec = 'LZ4',
        use_compact_variant_discriminators_serialization = 1
    SQL
  w98_run(binary, store, ddl)
  w98_run_input(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", w98_input_rowbinary(profile))

  paths = w98_run(binary, store, "SELECT path FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{profile}: expected one persisted stock part, got #{paths.inspect}" unless paths.size == 1 && Dir.exists?(paths.first)
  part = paths.first
  w98_check_stock(binary, store, part, profile, type_name)
  parts[profile] = part
end

w98_probe_library(parts)

puts "W98 stock probe complete; Bool payload domain was 0x00..0xff, while NULL and Variant tags were independently encoded."
