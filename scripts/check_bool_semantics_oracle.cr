require "json"
require "file_utils"
require "../src/crystal_click"

# W98 bidirectional oracle. The input is persisted by the pinned stock server
# from independently encoded RowBinary bytes. The library reads those bytes as
# Bool semantics, then writes a canonical 0/1 part from the values it decoded.
W98O_STOCK_VERSION             = "26.7.1.1315"
W98O_ROW_COUNT                 = 259
W98O_NULL_ROW                  = 258
W98O_STOCK_SERIALIZATION_JSON  = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
W98O_WRITER_SERIALIZATION_JSON = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
W98O_PROFILES                  = [
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
W98O_KEYS = Array(UInt64).new(W98O_ROW_COUNT) { |index| index.to_u64 + 1_u64 }

private def w98o_clickhouse(binary : String, store : String, query : String, input : Bytes? = nil) : {Bool, String, String}
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

private def w98o_run(binary : String, store : String, query : String) : String
  succeeded, output, error = w98o_clickhouse(binary, store, query)
  raise "ClickHouse query failed: #{error}\n#{query}" unless succeeded
  output
end

private def w98o_run_input(binary : String, store : String, query : String, bytes : Bytes) : Nil
  succeeded, _output, error = w98o_clickhouse(binary, store, query, bytes)
  raise "ClickHouse RowBinary INSERT failed: #{error}\n#{query}" unless succeeded
  nil
end

private def w98o_append_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w98o_u64_le_at(bytes : Array(UInt8), offset : Int32, label : String) : UInt64
  raise "#{label}: truncated UInt64" if offset < 0 || bytes.size - offset < 8
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w98o_read_varuint(bytes : Array(UInt8), offset : Int32, label : String) : {UInt64, Int32}
  raise "#{label}: invalid VarUInt offset" if offset < 0
  value = 0_u64
  cursor = offset
  10.times do |index|
    raise "#{label}: truncated VarUInt" if cursor >= bytes.size
    byte = bytes[cursor]
    payload = (byte & 0x7f_u8).to_u64
    raise "#{label}: VarUInt overflow" if index == 9 && payload > 1_u64
    value |= payload << (index * 7)
    cursor += 1
    unless byte & 0x80_u8 != 0
      raise "#{label}: noncanonical VarUInt" if index > 0 && payload == 0_u64
      return {value, cursor}
    end
  end
  raise "#{label}: VarUInt too long"
end

# Independent parser for ClickHouse's admitted COMPACT discriminator stream:
# 8-byte mode prefix, then each mark's row-count VarUInt and either row tags
# (format 0) or one uniform tag (format 1). This intentionally does not call
# the production Variant tag decoder.
private def w98o_variant_discriminator_tags(part : String, mark_rows : Array(UInt64)) : Array(UInt8)
  bytes = w98o_stream_bytes(part, "payload.variant_discr")
  raise "Variant physical discriminator: missing 8-byte mode prefix" if bytes.size < 8
  mode = w98o_u64_le_at(bytes, 0, "Variant physical discriminator mode")
  raise "Variant physical discriminator: expected COMPACT mode 1, got #{mode}" unless mode == 1_u64

  tags = [] of UInt8
  cursor = 8_i32
  mark_rows.each_with_index do |expected_rows, mark_index|
    encoded_rows, cursor = w98o_read_varuint(bytes, cursor, "Variant mark #{mark_index} row count")
    raise "Variant mark #{mark_index}: encoded row count #{encoded_rows} != #{expected_rows}" unless encoded_rows == expected_rows
    raise "Variant mark #{mark_index}: missing compact format" if cursor >= bytes.size
    format = bytes[cursor]
    cursor += 1
    case format
    when 0_u8
      raise "Variant mark #{mark_index}: row tags truncated" if expected_rows > (bytes.size - cursor).to_u64
      expected_rows.to_i.times do
        tags << bytes[cursor]
        cursor += 1
      end
    when 1_u8
      raise "Variant mark #{mark_index}: uniform tag truncated" if cursor >= bytes.size
      tag = bytes[cursor]
      cursor += 1
      expected_rows.to_i.times { tags << tag }
    else
      raise "Variant mark #{mark_index}: unsupported compact format #{format}"
    end
  end
  raise "Variant physical discriminator: trailing bytes after final mark" unless cursor == bytes.size
  tags
end

private def w98o_expected_mark_rows(profile : String) : Array(UInt64)
  profile == "variant_bool" ? Array.new(86, 3_u64) + [1_u64] : Array.new(129, 2_u64) + [1_u64]
end

private def w98o_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w98o_append_string(io : IO, value : String) : Nil
  w98o_append_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

private def w98o_append_nullable_bool(io : IO, value : Bool?) : Nil
  if value.nil?
    io.write_byte(1_u8)
  else
    io.write_byte(0_u8)
    io.write_byte(value.not_nil! ? 1_u8 : 0_u8)
  end
end

private def w98o_append_raw_nullable_bool(io : IO, value : UInt8?) : Nil
  if byte = value
    io.write_byte(0_u8)
    io.write_byte(byte)
  else
    io.write_byte(1_u8)
  end
end

private def w98o_code(index : Int32) : UInt8
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

private def w98o_append_map_key(io : IO, key : UInt64) : Nil
  w98o_append_u64(io, key)
end

private def w98o_append_map_key(io : IO, key : String) : Nil
  w98o_append_string(io, key)
end

private def w98o_append_array_map_bool(io : IO, row : Array(Array(Tuple(K, Bool)))) : Nil forall K
  w98o_append_varuint(io, row.size.to_u64)
  row.each do |map|
    w98o_append_varuint(io, map.size.to_u64)
    map.each do |key, value|
      w98o_append_map_key(io, key)
      io.write_byte(value ? 1_u8 : 0_u8)
    end
  end
end

private def w98o_append_array_map_nullable_bool(io : IO, row : Array(Array(Tuple(K, Bool?)))) : Nil forall K
  w98o_append_varuint(io, row.size.to_u64)
  row.each do |map|
    w98o_append_varuint(io, map.size.to_u64)
    map.each do |key, value|
      w98o_append_map_key(io, key)
      w98o_append_nullable_bool(io, value)
    end
  end
end

private def w98o_append_raw_array_map_bool(io : IO, row : Array(Array(Tuple(K, UInt8)))) : Nil forall K
  w98o_append_varuint(io, row.size.to_u64)
  row.each do |map|
    w98o_append_varuint(io, map.size.to_u64)
    map.each do |key, value|
      w98o_append_map_key(io, key)
      io.write_byte(value)
    end
  end
end

private def w98o_append_raw_array_map_nullable_bool(io : IO, row : Array(Array(Tuple(K, UInt8?)))) : Nil forall K
  w98o_append_varuint(io, row.size.to_u64)
  row.each do |map|
    w98o_append_varuint(io, map.size.to_u64)
    map.each do |key, value|
      w98o_append_map_key(io, key)
      w98o_append_raw_nullable_bool(io, value)
    end
  end
end

# This is the independent INSERT expectation. It preserves each raw Bool byte;
# it does not call the library's Bool decoder or writer.
private def w98o_append_raw_value(io : IO, profile : String, row : Int32) : Nil
  code = w98o_code(row)
  case profile
  when "root_bool"
    io.write_byte(code)
  when "nullable_bool"
    w98o_append_raw_nullable_bool(io, row == W98O_NULL_ROW ? nil : code)
  when "array_bool"
    w98o_append_varuint(io, 1_u64)
    io.write_byte(code)
  when "array_nullable_bool"
    if row == W98O_NULL_ROW
      w98o_append_varuint(io, 2_u64)
      w98o_append_raw_nullable_bool(io, 128_u8)
      w98o_append_raw_nullable_bool(io, nil)
    else
      w98o_append_varuint(io, 1_u64)
      w98o_append_raw_nullable_bool(io, code)
    end
  when "map_u64_bool"
    w98o_append_raw_array_map_bool(io, [[{7_u64, code}]])
  when "map_string_bool"
    w98o_append_raw_array_map_bool(io, [[{"k", code}]])
  when "map_u64_nullable_bool"
    entries = row == W98O_NULL_ROW ? [{7_u64, 128_u8}, {8_u64, nil}] of Tuple(UInt64, UInt8?) : [{7_u64, code}] of Tuple(UInt64, UInt8?)
    w98o_append_raw_array_map_nullable_bool(io, [entries])
  when "map_string_nullable_bool"
    entries = row == W98O_NULL_ROW ? [{"k", 128_u8}, {"z", nil}] of Tuple(String, UInt8?) : [{"k", code}] of Tuple(String, UInt8?)
    w98o_append_raw_array_map_nullable_bool(io, [entries])
  when "variant_bool"
    if row == W98O_NULL_ROW
      io.write_byte(255_u8)
    else
      io.write_byte(0_u8)
      io.write_byte(code)
    end
  else
    raise "unexpected W98 profile #{profile}"
  end
  nil
end

private def w98o_raw_rowbinary(profile : String, indexes : Array(Int32)) : Bytes
  output = IO::Memory.new
  indexes.each do |index|
    w98o_append_u64(output, W98O_KEYS[index])
    w98o_append_raw_value(output, profile, index)
  end
  output.to_slice.dup
end

private def w98o_input_rowbinary(profile : String) : Bytes
  w98o_raw_rowbinary(profile, Array.new(W98O_ROW_COUNT) { |index| index.to_i32 })
end

private def w98o_profile_values(profile : String, values : Array(CrystalClick::OfflineColumnValue)) : Bytes
  output = IO::Memory.new
  values.each do |value|
    case profile
    when "root_bool"
      output.write_byte(value.as(Bool) ? 1_u8 : 0_u8)
    when "nullable_bool"
      output_value = value.as?(Bool)
      w98o_append_nullable_bool(output, output_value)
    when "array_bool"
      items = value.as(Array(Bool))
      w98o_append_varuint(output, items.size.to_u64)
      items.each { |item| output.write_byte(item ? 1_u8 : 0_u8) }
    when "array_nullable_bool"
      items = value.as(Array(Bool?))
      w98o_append_varuint(output, items.size.to_u64)
      items.each { |item| w98o_append_nullable_bool(output, item) }
    when "map_u64_bool"
      w98o_append_array_map_bool(output, value.as(Array(Array(Tuple(UInt64, Bool)))))
    when "map_string_bool"
      w98o_append_array_map_bool(output, value.as(Array(Array(Tuple(String, Bool)))))
    when "map_u64_nullable_bool"
      w98o_append_array_map_nullable_bool(output, value.as(Array(Array(Tuple(UInt64, Bool?)))))
    when "map_string_nullable_bool"
      w98o_append_array_map_nullable_bool(output, value.as(Array(Array(Tuple(String, Bool?)))))
    when "variant_bool"
      case value
      when Bool
        output.write_byte(0_u8)
        output.write_byte(value ? 1_u8 : 0_u8)
      when String
        output.write_byte(1_u8)
        w98o_append_string(output, value)
      when UInt64
        output.write_byte(2_u8)
        w98o_append_u64(output, value)
      when Nil
        output.write_byte(255_u8)
      else
        raise "unexpected Variant value #{value.class}"
      end
    else
      raise "unexpected W98 profile #{profile}"
    end
  end
  output.to_slice.dup
end

private def w98o_rowbinary(profile : String, keys : Array(UInt64), values : Array(CrystalClick::OfflineColumnValue)) : Bytes
  raise "W98 keys/value count differs" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    w98o_append_u64(output, key)
    output.write(w98o_profile_values(profile, [values[index]] of CrystalClick::OfflineColumnValue))
  end
  output.to_slice.dup
end

private def w98o_as_offline(values : Array(T)) : Array(CrystalClick::OfflineColumnValue) forall T
  result = [] of CrystalClick::OfflineColumnValue
  values.each { |value| result << value }
  result
end

private def w98o_as_offline(values : Slice(T)) : Array(CrystalClick::OfflineColumnValue) forall T
  result = [] of CrystalClick::OfflineColumnValue
  values.each { |value| result << value }
  result
end

private def w98o_expected_values(profile : String) : Array(CrystalClick::OfflineColumnValue)
  values = [] of CrystalClick::OfflineColumnValue
  case profile
  when "root_bool"
    W98O_ROW_COUNT.times { |index| values << (w98o_code(index.to_i32) != 0_u8) }
  when "nullable_bool"
    W98O_ROW_COUNT.times do |index|
      values << (index == W98O_NULL_ROW ? nil : w98o_code(index.to_i32) != 0_u8)
    end
  when "array_bool"
    W98O_ROW_COUNT.times { |index| values << [w98o_code(index.to_i32) != 0_u8] }
  when "array_nullable_bool"
    W98O_ROW_COUNT.times do |index|
      values << (index == W98O_NULL_ROW ? [true, nil] of Bool? : [w98o_code(index.to_i32) != 0_u8] of Bool?)
    end
  when "map_u64_bool"
    W98O_ROW_COUNT.times do |index|
      values << [[{7_u64, w98o_code(index.to_i32) != 0_u8}]]
    end
  when "map_string_bool"
    W98O_ROW_COUNT.times do |index|
      values << [[{"k", w98o_code(index.to_i32) != 0_u8}]]
    end
  when "map_u64_nullable_bool"
    W98O_ROW_COUNT.times do |index|
      row = if index == W98O_NULL_ROW
              [[{7_u64, true}, {8_u64, nil}] of Tuple(UInt64, Bool?)]
            else
              [[{7_u64, w98o_code(index.to_i32) != 0_u8}] of Tuple(UInt64, Bool?)]
            end
      values << row
    end
  when "map_string_nullable_bool"
    W98O_ROW_COUNT.times do |index|
      row = if index == W98O_NULL_ROW
              [[{"k", true}, {"z", nil}] of Tuple(String, Bool?)]
            else
              [[{"k", w98o_code(index.to_i32) != 0_u8}] of Tuple(String, Bool?)]
            end
      values << row
    end
  when "variant_bool"
    W98O_ROW_COUNT.times do |index|
      values << (index == W98O_NULL_ROW ? nil : w98o_code(index.to_i32) != 0_u8)
    end
  else
    raise "unexpected W98 profile #{profile}"
  end
  values
end

private def w98o_read_all(reader : CrystalClick::WidePart, profile : String) : Array(CrystalClick::OfflineColumnValue)
  case profile
  when "root_bool"
    w98o_as_offline(reader.read_bool_mark_range("payload", 0, reader.mark_count))
  when "nullable_bool"
    w98o_as_offline(reader.read_nullable_bool_mark_range("payload", 0, reader.mark_count))
  when "array_bool"
    w98o_as_offline(reader.read_array_bool_mark_range("payload", 0, reader.mark_count))
  when "array_nullable_bool"
    w98o_as_offline(reader.read_array_nullable_bool_mark_range("payload", 0, reader.mark_count))
  when "map_u64_bool"
    w98o_as_offline(reader.read_array_map_uint64_bool_mark_range("payload", 0, reader.mark_count))
  when "map_string_bool"
    w98o_as_offline(reader.read_array_map_string_bool_mark_range("payload", 0, reader.mark_count))
  when "map_u64_nullable_bool"
    w98o_as_offline(reader.read_array_map_uint64_nullable_bool_mark_range("payload", 0, reader.mark_count))
  when "map_string_nullable_bool"
    w98o_as_offline(reader.read_array_map_string_nullable_bool_mark_range("payload", 0, reader.mark_count))
  when "variant_bool"
    w98o_as_offline(reader.read_variant_bool_string_uint64_mark_range("payload", 0, reader.mark_count))
  else
    raise "unexpected W98 profile #{profile}"
  end
end

private def w98o_read_range(reader : CrystalClick::WidePart, profile : String, first_mark : Int32, mark_count : Int32) : Array(CrystalClick::OfflineColumnValue)
  case profile
  when "root_bool"
    w98o_as_offline(reader.read_bool_mark_range("payload", first_mark, mark_count))
  when "nullable_bool"
    w98o_as_offline(reader.read_nullable_bool_mark_range("payload", first_mark, mark_count))
  when "array_bool"
    w98o_as_offline(reader.read_array_bool_mark_range("payload", first_mark, mark_count))
  when "array_nullable_bool"
    w98o_as_offline(reader.read_array_nullable_bool_mark_range("payload", first_mark, mark_count))
  when "map_u64_bool"
    w98o_as_offline(reader.read_array_map_uint64_bool_mark_range("payload", first_mark, mark_count))
  when "map_string_bool"
    w98o_as_offline(reader.read_array_map_string_bool_mark_range("payload", first_mark, mark_count))
  when "map_u64_nullable_bool"
    w98o_as_offline(reader.read_array_map_uint64_nullable_bool_mark_range("payload", first_mark, mark_count))
  when "map_string_nullable_bool"
    w98o_as_offline(reader.read_array_map_string_nullable_bool_mark_range("payload", first_mark, mark_count))
  when "variant_bool"
    w98o_as_offline(reader.read_variant_bool_string_uint64_mark_range("payload", first_mark, mark_count))
  else
    raise "unexpected W98 profile #{profile}"
  end
end

private def w98o_write_from_decoded(
  destination : String,
  profile : String,
  reader : CrystalClick::WidePart,
  keys : Array(UInt64),
  rows_per_mark : Int32,
) : Array(CrystalClick::OfflineColumnValue)
  key_slice = keys.to_unsafe.to_slice(keys.size)
  case profile
  when "root_bool"
    values = reader.read_bool_mark_range("payload", 0, reader.mark_count)
    CrystalClick::WidePartWriter.write_uint64_bool_pair(destination, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), rows_per_mark)
    w98o_as_offline(values)
  when "nullable_bool"
    values = reader.read_nullable_bool_mark_range("payload", 0, reader.mark_count)
    CrystalClick::WidePartWriter.write_uint64_nullable_bool_pair(destination, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), rows_per_mark)
    w98o_as_offline(values)
  when "array_bool"
    values = reader.read_array_bool_mark_range("payload", 0, reader.mark_count)
    CrystalClick::WidePartWriter.write_uint64_array_bool_pair(destination, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), rows_per_mark)
    w98o_as_offline(values)
  when "array_nullable_bool"
    values = reader.read_array_nullable_bool_mark_range("payload", 0, reader.mark_count)
    CrystalClick::WidePartWriter.write_uint64_array_nullable_bool_pair(destination, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), rows_per_mark)
    w98o_as_offline(values)
  when "map_u64_bool"
    values = reader.read_array_map_uint64_bool_mark_range("payload", 0, reader.mark_count)
    CrystalClick::WidePartWriter.write_uint64_array_map_uint64_bool_pair(destination, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), rows_per_mark)
    w98o_as_offline(values)
  when "map_string_bool"
    values = reader.read_array_map_string_bool_mark_range("payload", 0, reader.mark_count)
    CrystalClick::WidePartWriter.write_uint64_array_map_string_bool_pair(destination, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), rows_per_mark)
    w98o_as_offline(values)
  when "map_u64_nullable_bool"
    values = reader.read_array_map_uint64_nullable_bool_mark_range("payload", 0, reader.mark_count)
    CrystalClick::WidePartWriter.write_uint64_array_map_uint64_nullable_bool_pair(destination, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), rows_per_mark)
    w98o_as_offline(values)
  when "map_string_nullable_bool"
    values = reader.read_array_map_string_nullable_bool_mark_range("payload", 0, reader.mark_count)
    CrystalClick::WidePartWriter.write_uint64_array_map_string_nullable_bool_pair(destination, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), rows_per_mark)
    w98o_as_offline(values)
  when "variant_bool"
    values = reader.read_variant_bool_string_uint64_mark_range("payload", 0, reader.mark_count)
    CrystalClick::WidePartWriter.write_uint64_variant_bool_string_uint64_pair(destination, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), rows_per_mark)
    w98o_as_offline(values)
  else
    raise "unexpected W98 profile #{profile}"
  end
end

private def w98o_expected_physical_bool_bytes(profile : String) : Array(UInt8)
  case profile
  when "nullable_bool"
    Array.new(W98O_ROW_COUNT) { |index| index == W98O_NULL_ROW ? 0_u8 : w98o_code(index.to_i32) }
  when "variant_bool"
    Array.new(W98O_NULL_ROW) { |index| w98o_code(index.to_i32) }
  else
    result = [] of UInt8
    W98O_ROW_COUNT.times do |index|
      if (profile == "array_nullable_bool" || (profile.starts_with?("map_") && profile.ends_with?("nullable_bool"))) && index == W98O_NULL_ROW
        result << 128_u8 << 0_u8
      else
        result << w98o_code(index.to_i32)
      end
    end
    result
  end
end

private def w98o_expected_null_map(profile : String) : Array(UInt8)?
  case profile
  when "nullable_bool"
    Array.new(W98O_ROW_COUNT) { |index| index == W98O_NULL_ROW ? 1_u8 : 0_u8 }
  when "array_nullable_bool", "map_u64_nullable_bool", "map_string_nullable_bool"
    result = [] of UInt8
    W98O_ROW_COUNT.times do |index|
      if index == W98O_NULL_ROW
        result << 0_u8 << 1_u8
      else
        result << 0_u8
      end
    end
    result
  else
    nil
  end
end

private def w98o_bool_stream(profile : String, values : Array(CrystalClick::OfflineColumnValue)) : Array(UInt8)
  result = [] of UInt8
  values.each do |value|
    case profile
    when "root_bool"
      result << (value.as(Bool) ? 1_u8 : 0_u8)
    when "nullable_bool"
      nullable = value.as?(Bool)
      result << (nullable == true ? 1_u8 : 0_u8)
    when "array_bool"
      value.as(Array(Bool)).each { |item| result << (item ? 1_u8 : 0_u8) }
    when "array_nullable_bool"
      value.as(Array(Bool?)).each do |item|
        result << (item == true ? 1_u8 : 0_u8)
      end
    when "map_u64_bool"
      value.as(Array(Array(Tuple(UInt64, Bool)))).each do |map|
        map.each { |_key, item| result << (item ? 1_u8 : 0_u8) }
      end
    when "map_string_bool"
      value.as(Array(Array(Tuple(String, Bool)))).each do |map|
        map.each { |_key, item| result << (item ? 1_u8 : 0_u8) }
      end
    when "map_u64_nullable_bool"
      value.as(Array(Array(Tuple(UInt64, Bool?)))).each do |map|
        map.each { |_key, item| result << (item == true ? 1_u8 : 0_u8) }
      end
    when "map_string_nullable_bool"
      value.as(Array(Array(Tuple(String, Bool?)))).each do |map|
        map.each { |_key, item| result << (item == true ? 1_u8 : 0_u8) }
      end
    when "variant_bool"
      case value
      when Bool                then result << (value ? 1_u8 : 0_u8)
      when String, UInt64, Nil then nil
      else                          raise "unexpected Variant value #{value.class}"
      end
    else
      raise "unexpected W98 profile #{profile}"
    end
  end
  result
end

private def w98o_variant_tags(values : Array(CrystalClick::OfflineColumnValue)) : Array(UInt8)
  values.map do |value|
    case value
    when Bool   then 0_u8
    when String then 1_u8
    when UInt64 then 2_u8
    when Nil    then 255_u8
    else             raise "unexpected Variant value #{value.class}"
    end
  end
end

private def w98o_assert_bytes(actual : Bytes, expected : Bytes, label : String) : Nil
  return nil if actual == expected
  offset = 0
  limit = Math.min(actual.size, expected.size)
  while offset < limit && actual[offset] == expected[offset]
    offset += 1
  end
  actual_byte = offset < actual.size ? actual[offset].to_s(16).rjust(2, '0') : "<eof>"
  expected_byte = offset < expected.size ? expected[offset].to_s(16).rjust(2, '0') : "<eof>"
  raise "#{label}: byte mismatch at #{offset} (actual=#{actual_byte}, independent=#{expected_byte}; sizes #{actual.size}/#{expected.size})"
end

private def w98o_assert_byte_arrays(actual : Array(UInt8), expected : Array(UInt8), label : String) : Nil
  w98o_assert_bytes(actual.to_unsafe.to_slice(actual.size), expected.to_unsafe.to_slice(expected.size), label)
end

private def w98o_seeded_comparator_check(expected : Array(UInt8), label : String) : Nil
  raise "#{label}: no Bool bytes to seed" if expected.empty?
  seeded = expected.dup
  seeded[0] = seeded[0] == 0_u8 ? 1_u8 : 0_u8
  rejected = false
  begin
    w98o_assert_byte_arrays(expected, seeded, "#{label} seeded wrong-byte control")
  rescue ex : Exception
    rejected = true
  end
  raise "#{label}: byte comparator accepted a deliberately wrong Bool byte" unless rejected
end

private def w98o_stream_bytes(part : String, stream : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  return [] of UInt8 unless File.file?(path)
  encoded_file = File.read(path)
  encoded = encoded_file.to_slice
  encoded.empty? ? [] of UInt8 : CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w98o_table_name(profile : String, suffix : String) : String
  "w98_#{suffix}_#{profile}"
end

private def w98o_table_sql(table : String, type_name : String, granularity : Int32) : String
  <<-SQL
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
end

private def w98o_active_part(binary : String, store : String, table : String) : String
  paths = w98o_run(binary, store, "SELECT path FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{table}: expected exactly one active stock part, got #{paths.inspect}" unless paths.size == 1 && Dir.exists?(paths.first)
  paths.first
end

private def w98o_check_part(
  binary : String,
  store : String,
  table : String,
  part : String,
  type_name : String,
  expected_serialization : String,
  label : String,
) : Nil
  check = w98o_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected_part = File.basename(part.chomp("/"))
  raise "#{label}: stock CHECK TABLE failed: #{check.inspect}" unless check == "#{expected_part}\t1"

  expected_types = "pk\tUInt64\npayload\t#{type_name}\n"
  actual_types = w98o_run(binary, store, "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  raise "#{label}: stock declared column types differ:\n#{actual_types}" unless actual_types == expected_types

  serialization = File.read(File.join(part, "serialization.json")).strip
  raise "#{label}: serialization profile is outside the admitted W98 profile: #{serialization}" unless serialization == expected_serialization
  puts "stock #{label}: CHECK, exact schema, and W98 serializer metadata"
  nil
end

private def w98o_check_source_stock(binary : String, store : String, table : String, part : String, profile : String, type_name : String) : Nil
  w98o_check_part(binary, store, table, part, type_name, W98O_STOCK_SERIALIZATION_JSON, "source #{profile}")
  indexes = Array.new(W98O_ROW_COUNT) { |index| index.to_i32 }
  full = w98o_run(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary").to_slice
  w98o_assert_bytes(full, w98o_raw_rowbinary(profile, indexes), "source #{profile} raw RowBinary")

  range_indexes = [0_i32, 1_i32, 256_i32, 257_i32, 258_i32]
  keys = range_indexes.map { |index| W98O_KEYS[index] }
  selected = w98o_run(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk IN (#{keys.join(", ")}) ORDER BY pk FORMAT RowBinary").to_slice
  w98o_assert_bytes(selected, w98o_raw_rowbinary(profile, range_indexes), "source #{profile} selected raw RowBinary")

  value_stream = profile == "variant_bool" ? "payload.Bool" : (profile.starts_with?("map_") ? "payload%2Evalues" : "payload")
  raw_bool_bytes = w98o_expected_physical_bool_bytes(profile)
  observed_bool_bytes = w98o_stream_bytes(part, value_stream)
  w98o_assert_byte_arrays(observed_bool_bytes, raw_bool_bytes, "source #{profile} complete raw Bool physical stream")
  domain = (0_u8..255_u8).to_a
  raise "source #{profile}: fixture does not span all UInt8 Bool payload codes" unless domain.all? { |code| observed_bool_bytes.includes?(code) }
  if expected_null_map = w98o_expected_null_map(profile)
    null_stream = profile == "nullable_bool" || profile == "array_nullable_bool" ? "payload.null" : "payload%2Evalues.null"
    w98o_assert_byte_arrays(w98o_stream_bytes(part, null_stream), expected_null_map, "source #{profile} separate 0/1 NULL map")
    raise "source #{profile}: NULL map contains a noncanonical flag" unless w98o_stream_bytes(part, null_stream).all? { |value| value <= 1_u8 }
  end
  if profile == "variant_bool"
    expected_tags = Array.new(W98O_NULL_ROW, 0_u8) + [255_u8]
    parsed_tags = w98o_variant_discriminator_tags(part, w98o_expected_mark_rows(profile))
    w98o_assert_byte_arrays(parsed_tags, expected_tags, "source Variant discriminator tags separate from Bool bytes")
  end
  w98o_seeded_comparator_check(raw_bool_bytes, "source #{profile}")
  puts "source #{profile}: all 256 payload codes physically preserved; full and selected RowBinary are independent"
  nil
end

private def w98o_batch_values(batch : CrystalClick::WidePartTableBatch, profile : String) : Array(CrystalClick::OfflineColumnValue)
  case profile
  when "root_bool"
    w98o_as_offline(batch.bools_for("payload"))
  when "nullable_bool"
    w98o_as_offline(batch.nullable_bools_for("payload"))
  when "array_bool"
    w98o_as_offline(batch.array_bools_for("payload"))
  when "array_nullable_bool"
    w98o_as_offline(batch.array_nullable_bools_for("payload"))
  when "map_u64_bool"
    w98o_as_offline(batch.array_map_uint64_bools_for("payload"))
  when "map_string_bool"
    w98o_as_offline(batch.array_map_string_bools_for("payload"))
  when "map_u64_nullable_bool"
    w98o_as_offline(batch.array_map_uint64_nullable_bools_for("payload"))
  when "map_string_nullable_bool"
    w98o_as_offline(batch.array_map_string_nullable_bools_for("payload"))
  when "variant_bool"
    w98o_as_offline(batch.variant_bool_string_uint64_for("payload"))
  else
    raise "unexpected W98 profile #{profile}"
  end
end

private def w98o_batch_rowbinary(batch : CrystalClick::WidePartTableBatch, profile : String) : Bytes
  w98o_rowbinary(profile, batch.values_for("pk").to_a, w98o_batch_values(batch, profile))
end

private def w98o_check_table_consumers(
  part : String,
  profile : String,
  expected_values : Array(CrystalClick::OfflineColumnValue),
  label : String,
) : Nil
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])

  full = IO::Memory.new
  table.scan_typed do |batch|
    full.write(w98o_batch_rowbinary(batch, profile))
    nil
  end
  w98o_assert_bytes(full.to_slice, w98o_rowbinary(profile, W98O_KEYS, expected_values), "#{label}: typed full scan")

  window = IO::Memory.new
  table.scan_typed_window(100_u64, 5) do |batch|
    window.write(w98o_batch_rowbinary(batch, profile))
    nil
  end
  w98o_assert_bytes(
    window.to_slice,
    w98o_rowbinary(profile, W98O_KEYS[100, 5], expected_values[100, 5]),
    "#{label}: typed row window",
  )

  selected_indexes = profile == "variant_bool" ? [0, 1, 2, 255, 256, 257] : [0, 1, 256, 257]
  selected_keys = selected_indexes.map { |index| W98O_KEYS[index] }
  candidates = profile == "variant_bool" ? [[0_i32, 85_i32]] : [[0_i32, 128_i32]]
  selected = IO::Memory.new
  table.scan_typed_candidate_marks(candidates) do |batch|
    selected.write(w98o_batch_rowbinary(batch, profile))
    nil
  end
  selected_values = selected_indexes.map { |index| expected_values[index] }
  w98o_assert_bytes(
    selected.to_slice,
    w98o_rowbinary(profile, selected_keys, selected_values),
    "#{label}: sparse candidate marks",
  )
  puts "typed table #{label}: full, window, and sparse candidate scans preserve semantic values"
  nil
end

private def w98o_uuid(index : Int32) : String
  "b9800000-0000-4000-8000-#{index.to_s.rjust(12, '0')}"
end

private def w98o_check_catalog(
  root : String,
  table_name : String,
  type_name : String,
  profile : String,
  part : String,
  expected_values : Array(CrystalClick::OfflineColumnValue),
) : Nil
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  database_uuid = "a9800000-0000-4000-8000-000000000001"
  table_uuid = w98o_uuid(W98O_PROFILES.index { |entry| entry[0] == profile }.not_nil!.to_i32 + 1)
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_path, "#{table_name}.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{type_name}\n)\nENGINE = MergeTree\nORDER BY pk\n",
  )
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, "all_1_1_0"))

  catalog = CrystalClick::OfflineCatalog.open(root)
  values = catalog.table("lab", table_name)["payload"].values
  raise "catalog #{profile}: materialized values differ from independently expected semantic values" unless values == expected_values
  puts "offline catalog #{profile}: materialized semantic values"
  nil
end

private def w98o_attach_writer_part(binary : String, store : String, table : String, part : String, type_name : String, granularity : Int32) : String
  w98o_run(binary, store, w98o_table_sql(table, type_name, granularity))
  data_path = w98o_run(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse returned no data path" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w98o_run(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w98o_active_part(binary, store, table)
end

private def w98o_expected_source_indexes : Array(Int32)
  Array.new(W98O_ROW_COUNT) { |index| index.to_i32 }
end

private def w98o_check_roundtrip(
  binary : String,
  store : String,
  catalog_root : String,
  writer_root : String,
  source_part : String,
  profile : String,
  type_name : String,
) : Nil
  granularity = profile == "variant_bool" ? 3_i32 : 2_i32
  reader = CrystalClick::WidePart.open_typed(source_part, "payload")
  expected_marks = granularity == 3 ? Array.new(86, 3_u64) + [1_u64] : Array.new(129, 2_u64) + [1_u64]
  raise "source #{profile}: unexpected part mark schedule #{reader.mark_row_counts.inspect}" unless reader.mark_row_counts == expected_marks

  stock_values = w98o_read_all(reader, profile)
  expected_values = w98o_expected_values(profile)
  raise "source #{profile}: decoded semantic values differ from independently expected zero/nonzero/null values" unless stock_values == expected_values

  source_table = w98o_table_name(profile, "source")
  w98o_check_table_consumers(source_part, profile, expected_values, "stock source #{profile}")
  w98o_check_catalog(
    File.join(catalog_root, "source", profile),
    source_table,
    type_name,
    profile,
    source_part,
    expected_values,
  )

  tail_first_mark = granularity == 3 ? 85_i32 : 128_i32
  tail_values = w98o_read_range(reader, profile, tail_first_mark, 2_i32)
  tail_start = granularity == 3 ? 255 : 256
  raise "source #{profile}: selected tail range differs" unless tail_values == expected_values[tail_start, expected_values.size - tail_start]

  keys_reader = CrystalClick::WidePart.open_typed(source_part, "pk")
  keys = keys_reader.read_uint64_mark_range("pk", 0, keys_reader.mark_count)
  raise "source #{profile}: decoded keys differ" unless keys == W98O_KEYS

  destination = File.join(writer_root, "canonical_#{profile}")
  writer_values = w98o_write_from_decoded(destination, profile, reader, keys, granularity)
  raise "writer #{profile}: output source was not the actual stock-decoded values" unless writer_values == stock_values

  writer_table = w98o_table_name(profile, "writer")
  attached_part = w98o_attach_writer_part(binary, store, writer_table, destination, type_name, granularity)
  w98o_check_part(binary, store, writer_table, attached_part, type_name, W98O_WRITER_SERIALIZATION_JSON, "attached writer #{profile}")

  output_reader = CrystalClick::WidePart.open_typed(attached_part, "payload")
  raise "writer #{profile}: mark schedule differs" unless output_reader.mark_row_counts == expected_marks
  roundtrip_values = w98o_read_all(output_reader, profile)
  raise "writer #{profile}: direct readback changed semantic values" unless roundtrip_values == stock_values

  expected_canonical_bool = w98o_bool_stream(profile, stock_values)
  output_stream = profile == "variant_bool" ? "payload.Bool" : (profile.starts_with?("map_") ? "payload%2Evalues" : "payload")
  w98o_assert_byte_arrays(w98o_stream_bytes(attached_part, output_stream), expected_canonical_bool, "writer #{profile} canonical Bool stream")
  w98o_seeded_comparator_check(expected_canonical_bool, "writer #{profile}")
  if expected_null = w98o_expected_null_map(profile)
    null_stream = profile == "nullable_bool" || profile == "array_nullable_bool" ? "payload.null" : "payload%2Evalues.null"
    w98o_assert_byte_arrays(w98o_stream_bytes(attached_part, null_stream), expected_null, "writer #{profile} preserves separate NULL map")
  end
  if profile == "variant_bool"
    expected_tags = w98o_variant_tags(stock_values)
    parsed_tags = w98o_variant_discriminator_tags(attached_part, expected_marks)
    w98o_assert_byte_arrays(parsed_tags, expected_tags, "writer Variant tags remain distinct from Bool payload")
  end

  full_keys = W98O_KEYS
  expected_full = w98o_rowbinary(profile, full_keys, stock_values)
  stock_full = w98o_run(binary, store, "SELECT pk, payload FROM default.#{writer_table} ORDER BY pk FORMAT RowBinary").to_slice
  w98o_assert_bytes(stock_full, expected_full, "writer #{profile}: ATTACH/CHECK full canonical RowBinary")

  range_indexes = [0_i32, 1_i32, 256_i32, 257_i32, 258_i32]
  range_keys = range_indexes.map { |index| W98O_KEYS[index] }
  range_values = range_indexes.map { |index| stock_values[index] }
  stock_range = w98o_run(binary, store, "SELECT pk, payload FROM default.#{writer_table} WHERE pk IN (#{range_keys.join(", ")}) ORDER BY pk FORMAT RowBinary").to_slice
  w98o_assert_bytes(stock_range, w98o_rowbinary(profile, range_keys, range_values), "writer #{profile}: ATTACH/CHECK selected range RowBinary")

  w98o_check_table_consumers(attached_part, profile, stock_values, "writer #{profile}")
  catalog_for_profile = File.join(catalog_root, "writer", profile)
  w98o_check_catalog(catalog_for_profile, writer_table, type_name, profile, destination, stock_values)
  puts "PASS W98 #{profile}: stock bytes -> semantic Bool -> canonical writer -> stock/table/catalog"
  nil
end

private def w98o_create_source_table(binary : String, store : String, profile : String, type_name : String) : String
  table = w98o_table_name(profile, "source")
  granularity = profile == "variant_bool" ? 3_i32 : 2_i32
  w98o_run(binary, store, w98o_table_sql(table, type_name, granularity))
  w98o_run_input(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", w98o_input_rowbinary(profile))
  part = w98o_active_part(binary, store, table)
  w98o_check_source_stock(binary, store, table, part, profile, type_name)
  part
end

private def w98o_validate_root(binary : String, store : String, writer_root : String, catalog_root : String) : Nil
  [store, writer_root, catalog_root].each do |path|
    unless path.starts_with?("/private/tmp/") || path.starts_with?("/tmp/")
      raise "refusing non-temporary W98 path: #{path}"
    end
    if Dir.exists?(path)
      raise "W98 path must be empty: #{path}" unless Dir.empty?(path)
    else
      Dir.mkdir_p(path)
    end
  end

  version_output = IO::Memory.new
  version_status = Process.run(binary, ["local", "--version"], output: version_output)
  raise "could not read ClickHouse local version" unless version_status.success?
  expected = "ClickHouse local version #{W98O_STOCK_VERSION} (official build)."
  raise "W98 requires #{expected}, got #{version_output.to_s.strip}" unless version_output.to_s.strip == expected

  actual_version = w98o_run(binary, store, "SELECT version() FORMAT TSVRaw").strip
  raise "W98 store query reports ClickHouse #{actual_version}, expected #{W98O_STOCK_VERSION}" unless actual_version == W98O_STOCK_VERSION
  puts "Stock oracle: #{version_output.to_s.strip}"
  nil
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["BOOL_SEMANTICS_STORE"]? || raise "set BOOL_SEMANTICS_STORE to a fresh temporary ClickHouse store"
writer_root = ENV["BOOL_SEMANTICS_WRITER_ROOT"]? || raise "set BOOL_SEMANTICS_WRITER_ROOT to a fresh temporary writer directory"
catalog_root = ENV["BOOL_SEMANTICS_CATALOG_ROOT"]? || raise "set BOOL_SEMANTICS_CATALOG_ROOT to a fresh temporary catalog directory"

w98o_validate_root(binary, store, writer_root, catalog_root)
w98o_seeded_comparator_check([0_u8, 1_u8, 128_u8, 255_u8], "W98 independent byte comparator")

source_parts = Hash(String, String).new
W98O_PROFILES.each do |profile, type_name|
  source_parts[profile] = w98o_create_source_table(binary, store, profile, type_name)
end

W98O_PROFILES.each do |profile, type_name|
  w98o_check_roundtrip(binary, store, catalog_root, writer_root, source_parts[profile], profile, type_name)
end

puts "PASS W98 bidirectional Bool semantics oracle: stock raw 0x00..0xff payloads decode to Bool, writer emits canonical 0/1, and stock/table/catalog consumers agree across all nine exact profiles; NULL maps and Variant tags remain separate"
