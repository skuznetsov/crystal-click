require "json"
require "file_utils"
require "../src/crystal_click"

# Source-derived, literal-input expectations for the W116 JSON physical
# comparison. This is an oracle helper, not a production JSON implementation.
class W116JsonPhysicalMismatch < Exception
end

module W116JsonPhysicalVectors
  PROFILES = {"dynamic_paths", "dynamic_shared_only", "typed_mixed"}

  BASE_FILES = [
    "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
    "default_compression_codec.txt", "metadata_version.txt", "primary.idx",
    "serialization.json", "statistics.packed",
  ]

  def self.expected_schema(profile : String) : String
    check_profile(profile)
    type = case profile
           when "dynamic_paths"
             "JSON(max_dynamic_types=8, max_dynamic_paths=16)"
           when "dynamic_shared_only"
             "JSON(max_dynamic_types=8, max_dynamic_paths=0)"
           else
             "JSON(max_dynamic_types=1, max_dynamic_paths=1, a UInt64)"
           end
    "pk UInt64\npayload #{type}\n"
  end

  def self.expected_columns_text(profile : String) : String
    check_profile(profile)
    type = case profile
           when "dynamic_paths"
             "JSON(max_dynamic_types=8, max_dynamic_paths=16)"
           when "dynamic_shared_only"
             "JSON(max_dynamic_types=8, max_dynamic_paths=0)"
           else
             "JSON(max_dynamic_types=1, max_dynamic_paths=1, a UInt64)"
           end
    "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type}\n"
  end

  def self.expected_options(profile : String) : Hash(String, String)
    check_profile(profile)
    case profile
    when "dynamic_paths"
      {"max_dynamic_paths" => "16", "max_dynamic_types" => "8"}
    when "dynamic_shared_only"
      {"max_dynamic_paths" => "0", "max_dynamic_types" => "8"}
    else
      {"max_dynamic_paths" => "1", "max_dynamic_types" => "1"}
    end
  end

  # Values are the nominal roster, not row occurrences. Order follows the
  # type roster in the source-generated substream descriptor.
  def self.expected_type_descriptors(profile : String) : Hash(String, Array(String))
    check_profile(profile)
    case profile
    when "dynamic_paths"
      {
        "payload.a"           => ["Int64"],
        "payload.arr"         => ["Array(Nullable(Int64))"],
        "payload.dot%2Ekey"   => ["Int64"],
        "payload.flag"        => ["Bool"],
        "payload.nest%2Eleaf" => ["String"],
        "payload.s"           => ["Bool", "Int64", "String"],
      }
    when "dynamic_shared_only"
      {} of String => Array(String)
    else
      {
        "payload.s" => ["String"],
      }
    end
  end

  def self.expected_shared_value_types(profile : String) : Hash(String, Array(String))
    check_profile(profile)
    case profile
    when "dynamic_paths"
      {} of String => Array(String)
    when "dynamic_shared_only"
      {
        "a"         => ["Int64"],
        "arr"       => ["Array(Nullable(Int64))", "Array(Nullable(String))"],
        "dot.key"   => ["Int64"],
        "flag"      => ["Bool"],
        "nest.leaf" => ["String"],
        "s"         => ["Bool", "Int64", "String"],
      }
    else
      {
        "arr"       => ["Array(Nullable(Int64))", "Array(Nullable(String))"],
        "dot.key"   => ["Int64"],
        "flag"      => ["Bool"],
        "nest.leaf" => ["String"],
      }
    end
  end

  def self.expected_stream_names(profile : String) : Array(String)
    check_profile(profile)
    case profile
    when "dynamic_paths"
      [
        "pk", "payload.object_structure",
        "payload.a.dynamic_structure", "payload.a.variant_discr",
        "payload.arr.dynamic_structure", "payload.arr.variant_discr",
        "payload.dot%2Ekey.dynamic_structure", "payload.dot%2Ekey.variant_discr",
        "payload.flag.dynamic_structure", "payload.flag.variant_discr",
        "payload.nest%2Eleaf.dynamic_structure", "payload.nest%2Eleaf.variant_discr",
        "payload.s.dynamic_structure", "payload.s.variant_discr",
        "payload.a.Int64", "payload.a.SharedVariant.size", "payload.a.SharedVariant",
        "payload.arr.Array%28Nullable%28Int64%29%29.size0",
        "payload.arr.Array%28Nullable%28Int64%29%29.null",
        "payload.arr.Array%28Nullable%28Int64%29%29",
        "payload.arr.SharedVariant.size", "payload.arr.SharedVariant",
        "payload.dot%2Ekey.Int64", "payload.dot%2Ekey.SharedVariant.size",
        "payload.dot%2Ekey.SharedVariant",
        "payload.flag.Bool", "payload.flag.SharedVariant.size", "payload.flag.SharedVariant",
        "payload.nest%2Eleaf.SharedVariant.size", "payload.nest%2Eleaf.SharedVariant",
        "payload.nest%2Eleaf.String.size", "payload.nest%2Eleaf.String",
        "payload.s.Bool", "payload.s.Int64", "payload.s.SharedVariant.size",
        "payload.s.SharedVariant", "payload.s.String.size", "payload.s.String",
        "payload.object_shared_data.size0", "payload.object_shared_data%2Epaths",
        "payload.object_shared_data%2Evalues",
      ]
    when "dynamic_shared_only"
      [
        "pk", "payload.object_structure", "payload.object_shared_data.size0",
        "payload.object_shared_data%2Epaths", "payload.object_shared_data%2Evalues",
      ]
    else
      [
        "pk", "payload.object_structure", "payload.s.dynamic_structure",
        "payload.s.variant_discr", "payload.a", "payload.s.SharedVariant.size",
        "payload.s.SharedVariant", "payload.s.String.size", "payload.s.String",
        "payload.object_shared_data.size0", "payload.object_shared_data%2Epaths",
        "payload.object_shared_data%2Evalues",
      ]
    end
  end

  def self.expected_files(profile : String, attached : Bool = false) : Array(String)
    streams = expected_stream_names(profile)
    files = BASE_FILES.dup
    streams.each do |name|
      hash = CrystalClick::StreamName.hash(name)
      files << "#{hash}.bin"
      files << "#{hash}.mrk2"
    end
    files << "invalidated_system_columns.txt" if attached
    files.sort
  end

  def self.expected_object_structure(profile : String) : Hash(String, UInt64)
    check_profile(profile)
    # V3 carries a path-frequency map whose ordering is not stable in source.
    # The exact counts are derived from the eight literal input rows.
    expected_shared_path_statistics(profile)
  end

  def self.expected_dynamic_path_statistics(profile : String) : Hash(String, UInt64)
    check_profile(profile)
    case profile
    when "dynamic_paths"
      {"a" => 6_u64, "arr" => 6_u64, "dot.key" => 7_u64, "flag" => 5_u64, "nest.leaf" => 5_u64, "s" => 6_u64}
    when "dynamic_shared_only"
      {} of String => UInt64
    else
      {"s" => 6_u64}
    end
  end

  def self.expected_shared_path_statistics(profile : String) : Hash(String, UInt64)
    check_profile(profile)
    case profile
    when "dynamic_paths"
      {} of String => UInt64
    when "dynamic_shared_only"
      {"a" => 6_u64, "arr" => 6_u64, "dot.key" => 7_u64, "flag" => 5_u64, "nest.leaf" => 5_u64, "s" => 6_u64}
    else
      {"arr" => 6_u64, "dot.key" => 7_u64, "flag" => 5_u64, "nest.leaf" => 5_u64}
    end
  end

  def self.assert_object_structure(profile : String, raw : Bytes) : Nil
    check_profile(profile)
    io = IO::Memory.new(raw)
    version = read_u64(io)
    dynamic_count = read_varuint(io)
    dynamic_paths = Array(String).new(dynamic_count.to_i) { read_string_binary(io) }
    shared_version = read_varuint(io)
    stats_present = io.read_byte
    unless version == 4_u64 && shared_version == 0_u64 && stats_present == 1_u8
      fail(profile, "object_structure differs")
    end

    expected_dynamic = expected_dynamic_path_statistics(profile)
    expected_shared = expected_shared_path_statistics(profile)
    expected_roster = expected_dynamic.keys.sort
    fail(profile, "object_structure differs") unless dynamic_paths == expected_roster

    dynamic_stats = {} of String => UInt64
    dynamic_paths.each do |path|
      dynamic_stats[path] = read_varuint(io)
    end
    shared_count = read_varuint(io)
    shared_stats = {} of String => UInt64
    shared_count.times do
      path = read_string_binary(io)
      fail(profile, "object_structure duplicate shared path statistic") if shared_stats.has_key?(path)
      shared_stats[path] = read_varuint(io)
    end
    fail(profile, "object_structure trailing bytes") unless io.pos == raw.size
    fail(profile, "object_structure differs") unless dynamic_stats == expected_dynamic && shared_stats == expected_shared
  rescue ex : W116JsonPhysicalMismatch
    raise ex
  rescue ex : Exception
    fail(profile, "object_structure differs")
  end

  private def self.primary_key_raw : Bytes
    io = IO::Memory.new
    (1_u64..8_u64).each { |value| write_u64(io, value) }
    io.to_slice
  end

  private def self.object_structure_raw(profile : String) : Bytes
    dynamic = expected_dynamic_path_statistics(profile)
    shared = expected_shared_path_statistics(profile)
    io = IO::Memory.new
    io.write(object_structure_prefix(profile))
    dynamic_paths = dynamic.keys.sort
    io.write_byte(1_u8) # Statistics present.
    dynamic_paths.each { |path| write_varuint(io, dynamic[path]) }
    shared_paths = shared.keys.sort
    write_varuint(io, shared_paths.size.to_u64)
    shared_paths.each do |path|
      write_string_binary(io, path)
      write_varuint(io, shared[path])
    end
    io.to_slice
  end

  private def self.object_structure_prefix(profile : String) : Bytes
    io = IO::Memory.new
    dynamic_paths = expected_dynamic_path_statistics(profile).keys.sort
    write_u64(io, 4_u64) # Object serialization V3.
    write_varuint(io, dynamic_paths.size.to_u64)
    dynamic_paths.each { |path| write_string_binary(io, path) }
    write_varuint(io, 0_u64) # SharedData MAP serialization version.
    io.to_slice
  end

  private def self.shared_rows(profile : String) : Array(Array(Tuple(String, String)))
    # Values are source-derived from the literal W115 rows. Nil/missing Object
    # paths are absent from the MAP carrier; values are binary Dynamic fields.
    rows = Array(Array(Tuple(String, String))).new(8) { [] of Tuple(String, String) }
    if profile == "dynamic_shared_only"
      shared_scalar_rows(rows)
    elsif profile == "typed_mixed"
      shared_typed_rows(rows)
    end
    rows.each do |row|
      row.sort_by!(&.[0])
    end
    rows
  end

  private def self.shared_sizes_raw(profile : String) : Bytes
    io = IO::Memory.new
    shared_rows(profile).each { |row| write_u64(io, row.size.to_u64) }
    io.to_slice
  end

  private def self.shared_paths_raw(profile : String) : Bytes
    io = IO::Memory.new
    shared_rows(profile).each do |row|
      row.each { |(path, _)| write_string_binary(io, path) }
    end
    io.to_slice
  end

  private def self.shared_values_raw(profile : String) : Bytes
    io = IO::Memory.new
    shared_rows(profile).each do |row|
      row.each { |(_, value)| write_string_binary(io, value) }
    end
    io.to_slice
  end

  private def self.shared_scalar_rows(rows : Array(Array(Tuple(String, String)))) : Nil
    add_shared(rows, 0, "a", dynamic_field(0x0a_u8, int64_bytes(10_i64)))
    add_shared(rows, 2, "a", dynamic_field(0x0a_u8, int64_bytes(3_i64)))
    add_shared(rows, 4, "a", dynamic_field(0x0a_u8, int64_bytes(5_i64)))
    add_shared(rows, 5, "a", dynamic_field(0x0a_u8, int64_bytes(6_i64)))
    add_shared(rows, 6, "a", dynamic_field(0x0a_u8, int64_bytes(7_i64)))
    add_shared(rows, 7, "a", dynamic_field(0x0a_u8, int64_bytes(8_i64)))

    add_shared(rows, 0, "arr", dynamic_array_field(0x0a_u8, [1_i64, 2_i64]))
    add_shared(rows, 1, "arr", dynamic_array_field(0x15_u8, [] of Int64))
    add_shared(rows, 2, "arr", dynamic_array_field(0x0a_u8, [3_i64]))
    add_shared(rows, 4, "arr", dynamic_array_field(0x0a_u8, [4_i64, 5_i64]))
    add_shared(rows, 6, "arr", dynamic_array_field(0x0a_u8, [6_i64]))
    add_shared(rows, 7, "arr", dynamic_array_field(0x0a_u8, [7_i64]))

    {101_i64, 102_i64, 103_i64, 105_i64, 106_i64, 107_i64, 108_i64}.each_with_index do |value, index|
      row = index < 3 ? index : index + 1
      add_shared(rows, row, "dot.key", dynamic_field(0x0a_u8, int64_bytes(value)))
    end
    [true, false, true, false, true].each_with_index do |value, index|
      row = [0, 1, 4, 5, 7][index]
      add_shared(rows, row, "flag", dynamic_field(0x2d_u8, Bytes[value ? 1_u8 : 0_u8]))
    end
    {0 => "one", 1 => "two", 4 => "five", 6 => "end", 7 => ""}.each do |row, value|
      add_shared(rows, row, "nest.leaf", dynamic_field(0x15_u8, string_binary(value)))
    end
    add_shared(rows, 0, "s", dynamic_field(0x15_u8, string_binary("alpha")))
    add_shared(rows, 1, "s", dynamic_field(0x15_u8, string_binary("")))
    add_shared(rows, 2, "s", dynamic_field(0x15_u8, string_binary("a\0b")))
    add_shared(rows, 4, "s", dynamic_field(0x0a_u8, int64_bytes(42_i64)))
    add_shared(rows, 6, "s", dynamic_field(0x15_u8, string_binary("last")))
    add_shared(rows, 7, "s", dynamic_field(0x2d_u8, Bytes[1_u8]))
  end

  private def self.shared_typed_rows(rows : Array(Array(Tuple(String, String)))) : Nil
    [0, 1, 2, 4, 6, 7].each_with_index do |row, index|
      values = [[1_i64, 2_i64], [] of Int64, [3_i64], [4_i64, 5_i64], [6_i64], [7_i64]][index]
      element = index == 1 ? 0x15_u8 : 0x0a_u8
      add_shared(rows, row, "arr", dynamic_array_field(element, values))
    end
    {0 => 101_i64, 1 => 102_i64, 2 => 103_i64, 4 => 105_i64, 5 => 106_i64, 6 => 107_i64, 7 => 108_i64}.each do |row, value|
      add_shared(rows, row, "dot.key", dynamic_field(0x0a_u8, int64_bytes(value)))
    end
    {0 => true, 1 => false, 4 => true, 5 => false, 7 => true}.each do |row, value|
      add_shared(rows, row, "flag", dynamic_field(0x2d_u8, Bytes[value ? 1_u8 : 0_u8]))
    end
    {0 => "one", 1 => "two", 4 => "five", 6 => "end", 7 => ""}.each do |row, value|
      add_shared(rows, row, "nest.leaf", dynamic_field(0x15_u8, string_binary(value)))
    end
  end

  private def self.add_shared(rows : Array(Array(Tuple(String, String))), row : Int32, path : String, value : Bytes) : Nil
    rows[row] << {path, String.new(value)}
  end

  private def self.array_value(element_type : UInt8, values : Array(Int64)) : Bytes
    io = IO::Memory.new
    write_varuint(io, values.size.to_u64)
    values.each do |value|
      io.write_byte(0_u8) # Nullable element is present.
      io.write(int64_bytes(value)) if element_type == 0x0a_u8
      io.write(string_binary(value.to_s)) if element_type == 0x15_u8
    end
    io.to_slice
  end

  private def self.dynamic_array_field(element_type : UInt8, values : Array(Int64)) : Bytes
    io = IO::Memory.new
    io.write(Bytes[0x1e_u8, 0x23_u8, element_type])
    io.write(array_value(element_type, values))
    io.to_slice
  end

  private def self.dynamic_field(type : UInt8, value : Bytes) : Bytes
    io = IO::Memory.new
    io.write_byte(type)
    io.write(value)
    io.to_slice
  end

  private def self.int64_bytes(value : Int64) : Bytes
    u64_bytes(value.to_u64)
  end

  private def self.u64_bytes(value : UInt64) : Bytes
    io = IO::Memory.new
    write_u64(io, value)
    io.to_slice
  end

  private def self.string_binary(value : String) : Bytes
    io = IO::Memory.new
    write_string_binary(io, value)
    io.to_slice
  end

  private def self.write_varuint(io : IO, value : UInt64) : Nil
    remaining = value
    while remaining >= 0x80_u64
      io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
      remaining >>= 7
    end
    io.write_byte(remaining.to_u8)
  end

  private def self.write_string_binary(io : IO, value : String) : Nil
    write_varuint(io, value.bytesize.to_u64)
    io.write(value.to_slice)
  end

  private def self.read_u64(io : IO) : UInt64
    value = 0_u64
    8.times do |index|
      byte = io.read_byte || raise IO::EOFError.new
      value |= byte.to_u64 << (index * 8)
    end
    value
  end

  private def self.read_varuint(io : IO) : UInt64
    value = 0_u64
    10.times do |index|
      byte = io.read_byte || raise IO::EOFError.new
      # UInt64 VarUInts have at most ten groups; the tenth may carry only bit
      # 63 and must terminate. Reject overflow before shifting the payload.
      raise IO::Error.new("invalid VarUInt") if index == 9 && byte > 1_u8
      payload = (byte & 0x7f_u8).to_u64
      # A zero terminal group after the first byte is a non-minimal encoding.
      raise IO::Error.new("invalid VarUInt") if index > 0 && byte < 0x80_u8 && payload == 0_u64
      value |= payload << (index * 7)
      return value if byte < 0x80_u8
    end
    raise IO::Error.new("invalid VarUInt")
  end

  private def self.read_string_binary(io : IO) : String
    size = read_varuint(io).to_i
    bytes = Bytes.new(size)
    io.read_fully(bytes)
    String.new(bytes)
  end

  private def self.modeled_payload_raw(profile : String, logical_stream : String) : Bytes
    if logical_stream.ends_with?(".dynamic_structure")
      return dynamic_structure_raw(profile, logical_stream)
    elsif logical_stream.ends_with?(".variant_discr")
      return variant_discriminator_raw(profile, logical_stream)
    end

    rows = leaf_rows(profile, logical_stream)
    io = IO::Memory.new
    rows.each { |row| row.each { |bytes| io.write(bytes) } }
    return io.to_slice
  end

  private def self.leaf_rows(profile : String, logical_stream : String) : Array(Array(Bytes))
    rows = Array(Array(Bytes)).new(8) { [] of Bytes }
    case logical_stream
    when "payload.a"
      return rows unless profile == "typed_mixed"
      {10_u64, 0_u64, 3_u64, 0_u64, 5_u64, 6_u64, 7_u64, 8_u64}.each_with_index do |value, row|
        rows[row] << u64_bytes(value)
      end
    when "payload.a.Int64"
      {0 => 10_i64, 2 => 3_i64, 4 => 5_i64, 5 => 6_i64, 6 => 7_i64, 7 => 8_i64}.each { |row, value| rows[row] << int64_bytes(value) }
    when "payload.dot%2Ekey.Int64"
      {0 => 101_i64, 1 => 102_i64, 2 => 103_i64, 4 => 105_i64, 5 => 106_i64, 6 => 107_i64, 7 => 108_i64}.each { |row, value| rows[row] << int64_bytes(value) }
    when "payload.flag.Bool"
      {0 => true, 1 => false, 4 => true, 5 => false, 7 => true}.each { |row, value| rows[row] << Bytes[value ? 1_u8 : 0_u8] }
    when "payload.s.Bool"
      return rows unless profile == "dynamic_paths"
      rows[7] << Bytes[1_u8]
    when "payload.s.Int64"
      return rows unless profile == "dynamic_paths"
      rows[4] << int64_bytes(42_i64)
    when "payload.nest%2Eleaf.String"
      {0 => "one", 1 => "two", 4 => "five", 6 => "end", 7 => ""}.each { |row, value| rows[row] << value.to_slice }
    when "payload.s.String"
      return rows unless profile == "dynamic_paths" || profile == "typed_mixed"
      {0 => "alpha", 1 => "", 2 => "a\0b", 6 => "last"}.each { |row, value| rows[row] << value.to_slice }
    when "payload.s.SharedVariant"
      return rows unless profile == "typed_mixed"
      rows[4] << dynamic_field(0x0a_u8, int64_bytes(42_i64))
      rows[7] << dynamic_field(0x2d_u8, Bytes[1_u8])
    when "payload.a.SharedVariant", "payload.arr.SharedVariant", "payload.dot%2Ekey.SharedVariant", "payload.flag.SharedVariant", "payload.nest%2Eleaf.SharedVariant"
      return rows
    else
      if logical_stream.ends_with?(".size")
        value_stream = logical_stream[0, logical_stream.size - 5]
        values = leaf_rows(profile, value_stream)
        values.each_with_index do |row_values, row|
          row_values.each { |value| rows[row] << u64_bytes(value.size.to_u64) }
        end
        return rows
      elsif logical_stream == "payload.arr.Array%28Nullable%28Int64%29%29.size0"
        {0 => 2_u64, 1 => 0_u64, 2 => 1_u64, 4 => 2_u64, 6 => 1_u64, 7 => 1_u64}.each { |row, size| rows[row] << u64_bytes(size) }
        return rows
      elsif logical_stream == "payload.arr.Array%28Nullable%28Int64%29%29.null"
        {0 => 2, 2 => 1, 4 => 2, 6 => 1, 7 => 1}.each { |row, count| count.times { rows[row] << Bytes[0_u8] } }
        return rows
      elsif logical_stream == "payload.arr.Array%28Nullable%28Int64%29%29"
        {0 => [1_i64, 2_i64], 2 => [3_i64], 4 => [4_i64, 5_i64], 6 => [6_i64], 7 => [7_i64]}.each do |row, values|
          values.each { |value| rows[row] << int64_bytes(value) }
        end
        return rows
      end
      return rows
    end

    if logical_stream.ends_with?(".size")
      value_stream = logical_stream[0, logical_stream.size - 5]
      values = leaf_rows(profile, value_stream)
      values.each_with_index do |row_values, row|
        row_values.each { |value| rows[row] << u64_bytes(value.size.to_u64) }
      end
    end
    rows
  end

  private def self.dynamic_structure_raw(profile : String, logical_stream : String) : Bytes
    header, shared_types = dynamic_structure_header(profile, logical_stream)
    io = IO::Memory.new
    io.write(header)
    shared_types.keys.sort.each do |name|
      write_string_binary(io, name)
      write_varuint(io, shared_types[name])
    end
    io.to_slice
  end

  private def self.dynamic_structure_header(profile : String, logical_stream : String) : Tuple(Bytes, Hash(String, UInt64))
    path = logical_stream["payload.".size, logical_stream.size - ".dynamic_structure".size - "payload.".size]
    tags = variant_tags(profile, path)
    type_names = if path == "s" && profile == "dynamic_paths"
                   ["Bool", "Int64", "String"]
                 elsif path == "s" && profile == "typed_mixed"
                   ["String"]
                 elsif path == "arr"
                   ["Array(Nullable(Int64))"]
                 elsif path == "flag"
                   ["Bool"]
                 elsif path == "nest%2Eleaf"
                   ["String"]
                 else
                   ["Int64"]
                 end
    shared_tag = shared_variant_tag(profile, path)
    shared_count = tags.count(&.==(shared_tag)).to_u64
    io = IO::Memory.new
    io.write(dynamic_structure_prefix(profile, logical_stream))
    io.write_byte(1_u8)

    variant_names = (type_names + ["SharedVariant"]).sort
    variant_names.each do |name|
      count = if name == "SharedVariant"
                shared_count
              else
                tag = variant_tag_for(profile, path, name)
                tags.count(&.==(tag)).to_u64
              end
      write_varuint(io, count)
    end

    shared_types = if profile == "typed_mixed" && path == "s"
                     {"Bool" => 1_u64, "Int64" => 1_u64}
                   else
                     {} of String => UInt64
                   end
    write_varuint(io, shared_types.size.to_u64)
    {io.to_slice, shared_types}
  end

  private def self.dynamic_structure_prefix(profile : String, logical_stream : String) : Bytes
    path = logical_stream["payload.".size, logical_stream.size - ".dynamic_structure".size - "payload.".size]
    type_names = if path == "s" && profile == "dynamic_paths"
                   ["Bool", "Int64", "String"]
                 elsif path == "s" && profile == "typed_mixed"
                   ["String"]
                 elsif path == "arr"
                   ["Array(Nullable(Int64))"]
                 elsif path == "flag"
                   ["Bool"]
                 elsif path == "nest%2Eleaf"
                   ["String"]
                 else
                   ["Int64"]
                 end
    io = IO::Memory.new
    write_u64(io, 4_u64)
    write_varuint(io, type_names.size.to_u64)
    type_names.each { |name| write_type_descriptor(io, name) }
    io.to_slice
  end

  private def self.assert_dynamic_structure(profile : String, logical_stream : String, raw : Bytes) : Nil
    header, expected_stats = dynamic_structure_header(profile, logical_stream)
    unless raw.size >= header.size && raw[0, header.size] == header
      fail(profile, "stream #{logical_stream} raw payload differs")
    end
    tail_size = raw.size - header.size
    io = IO::Memory.new(raw[header.size, tail_size])
    actual_stats = {} of String => UInt64
    expected_stats.size.times do
      name = read_string_binary(io)
      fail(profile, "stream #{logical_stream} raw payload differs") if actual_stats.has_key?(name)
      actual_stats[name] = read_varuint(io)
    end
    unless io.pos == tail_size && actual_stats == expected_stats
      fail(profile, "stream #{logical_stream} raw payload differs")
    end
  rescue ex : W116JsonPhysicalMismatch
    raise ex
  rescue ex : Exception
    fail(profile, "stream #{logical_stream} raw payload differs")
  end

  private def self.variant_tags(profile : String, path : String) : Array(UInt8)
    case {profile, path}
    when {"dynamic_paths", "a"}           then [0, 255, 0, 255, 0, 0, 0, 0].map(&.to_u8)
    when {"dynamic_paths", "arr"}         then [0, 0, 0, 255, 0, 255, 0, 0].map(&.to_u8)
    when {"dynamic_paths", "dot%2Ekey"}   then [0, 0, 0, 255, 0, 0, 0, 0].map(&.to_u8)
    when {"dynamic_paths", "flag"}        then [0, 0, 255, 255, 0, 0, 255, 0].map(&.to_u8)
    when {"dynamic_paths", "nest%2Eleaf"} then [1, 1, 255, 255, 1, 255, 1, 1].map(&.to_u8)
    when {"dynamic_paths", "s"}           then [3, 3, 3, 255, 1, 255, 3, 0].map(&.to_u8)
    when {"typed_mixed", "s"}             then [1, 1, 1, 255, 0, 255, 1, 0].map(&.to_u8)
    else
      fail(profile, "stream payload.#{path}.variant_discr has no tag model")
    end
  end

  private def self.shared_variant_tag(profile : String, path : String) : UInt8
    if profile == "dynamic_paths" && path == "s"
      2_u8
    elsif (profile == "typed_mixed" && path == "s") || path == "nest%2Eleaf"
      0_u8
    else
      1_u8
    end
  end

  private def self.variant_tag_for(profile : String, path : String, name : String) : UInt8
    return shared_variant_tag(profile, path) if name == "SharedVariant"
    if profile == "dynamic_paths" && path == "s"
      name == "Bool" ? 0_u8 : (name == "Int64" ? 1_u8 : 3_u8)
    elsif (profile == "typed_mixed" && path == "s") || path == "nest%2Eleaf"
      1_u8
    else
      0_u8
    end
  end

  private def self.write_type_descriptor(io : IO, name : String) : Nil
    case name
    when "Bool"   then io.write_byte(0x2d_u8)
    when "Int64"  then io.write_byte(0x0a_u8)
    when "String" then io.write_byte(0x15_u8)
    when "Array(Nullable(Int64))"
      io.write(Bytes[0x1e_u8, 0x23_u8, 0x0a_u8])
    else
      raise "unmodeled W116 DataType #{name}"
    end
  end

  private def self.variant_discriminator_raw(profile : String, logical_stream : String) : Bytes
    path = logical_stream["payload.".size, logical_stream.size - ".variant_discr".size - "payload.".size]
    tags = variant_tags(profile, path)
    io = IO::Memory.new
    write_u64(io, 1_u64) # COMPACT SerializationVariant mode.
    tags.each_slice(2) do |pair|
      write_varuint(io, pair.size.to_u64)
      if pair.size == 2 && pair[0] == pair[1]
        io.write_byte(1_u8)
        io.write_byte(pair[0])
      else
        io.write_byte(0_u8)
        pair.each { |tag| io.write_byte(tag) }
      end
    end
    io.to_slice
  end

  private def self.modeled_mark_offsets(profile : String, logical_stream : String, raw : Bytes) : Array(UInt64)
    return [0_u64, 16_u64, 32_u64, 48_u64, 64_u64] if logical_stream == "pk"
    if logical_stream.ends_with?(".variant_discr")
      offsets = [8_u64]
      tags = variant_tags(profile, logical_stream["payload.".size, logical_stream.size - ".variant_discr".size - "payload.".size])
      tags.each_slice(2) do |pair|
        size = 1 + (pair.size == 2 && pair[0] == pair[1] ? 2 : pair.size + 1)
        offsets << offsets.last + size.to_u64
      end
      return offsets
    end
    if logical_stream == "payload.object_structure"
      prefix_size = object_structure_prefix(profile).size.to_u64
      return [prefix_size, prefix_size, prefix_size, prefix_size, raw.size.to_u64]
    elsif logical_stream.ends_with?(".dynamic_structure")
      prefix_size = dynamic_structure_prefix(profile, logical_stream).size.to_u64
      return [prefix_size, prefix_size, prefix_size, prefix_size, raw.size.to_u64]
    end

    chunks = if logical_stream == "payload.object_shared_data.size0"
               shared_rows(profile).map { |row| [u64_bytes(row.size.to_u64)] }
             elsif logical_stream == "payload.object_shared_data%2Epaths"
               shared_rows(profile).map do |row|
                 row.map do |(path, _)|
                   io = IO::Memory.new
                   write_string_binary(io, path)
                   io.to_slice
                 end
               end
             elsif logical_stream == "payload.object_shared_data%2Evalues"
               shared_rows(profile).map do |row|
                 row.map do |(_, value)|
                   io = IO::Memory.new
                   write_string_binary(io, value)
                   io.to_slice
                 end
               end
             else
               leaf_rows(profile, logical_stream)
             end

    offsets = [0_u64]
    current = 0_u64
    4.times do |mark|
      2.times do |row_index|
        chunks[mark * 2 + row_index]?.try &.each do |bytes|
          current += bytes.size.to_u64
        end
      end
      offsets << current
    end
    offsets
  end

  def self.expected_raw_stream(profile : String, logical_stream : String) : Bytes
    check_profile(profile)
    unless expected_stream_names(profile).includes?(logical_stream)
      fail(profile, "stream #{logical_stream} has no expected vector")
    end
    case logical_stream
    when "pk"
      primary_key_raw
    when "payload.object_structure"
      object_structure_raw(profile)
    when "payload.object_shared_data.size0"
      shared_sizes_raw(profile)
    when "payload.object_shared_data%2Epaths"
      shared_paths_raw(profile)
    when "payload.object_shared_data%2Evalues"
      shared_values_raw(profile)
    else
      modeled_payload_raw(profile, logical_stream)
    end
  end

  # The tuple order is compressed offset, decompressed offset, outer rows.
  # The returned range contains only requested marks; the terminal sentinel
  # is included only when the requested range reaches mark index four.
  def self.expected_mark_grid(profile : String, logical_stream : String, first_mark : Int32 = 0, mark_count : Int32 = 5) : Array(Tuple(UInt64, UInt64, UInt64))
    check_profile(profile)
    unless expected_stream_names(profile).includes?(logical_stream)
      fail(profile, "stream #{logical_stream} has no expected mark grid")
    end
    raw = expected_raw_stream(profile, logical_stream)
    offsets = modeled_mark_offsets(profile, logical_stream, raw)
    raise IndexError.new("mark range out of bounds") if first_mark < 0 || mark_count < 0 || first_mark > offsets.size - mark_count
    rows = [2_u64, 2_u64, 2_u64, 2_u64, 0_u64]
    Array(Tuple(UInt64, UInt64, UInt64)).new(mark_count) do |index|
      mark = first_mark + index
      {0_u64, offsets[mark], rows[mark]}
    end
  end

  def self.expected_mark_rows(profile : String, logical_stream : String, first_mark : Int32 = 0, mark_count : Int32 = 5) : Array(UInt64)
    expected_mark_grid(profile, logical_stream, first_mark, mark_count).map(&.[2])
  end

  def self.assert_stream_raw(profile : String, logical_stream : String, actual : Bytes) : Nil
    expected = expected_raw_stream(profile, logical_stream)
    if logical_stream == "payload.object_structure"
      assert_object_structure(profile, actual)
    elsif logical_stream.ends_with?(".dynamic_structure")
      assert_dynamic_structure(profile, logical_stream, actual)
    else
      fail(profile, "stream #{logical_stream} raw payload differs") unless actual == expected
    end
  end

  def self.assert_mark_raw(profile : String, logical_stream : String, actual : Bytes) : Nil
    expected = expected_mark_bytes(profile, logical_stream)
    fail(profile, "stream #{logical_stream} mark grid differs") unless actual == expected
  end

  def self.assert_columns_text(profile : String, actual : String) : Nil
    fail(profile, "columns.txt schema differs") unless actual == expected_columns_text(profile)
  end

  def self.assert_part(profile : String, part_path : String, attached : Bool = false) : Nil
    check_profile(profile)
    raise W116JsonPhysicalMismatch.new("W116 JSON physical mismatch: unsafe part path") unless Dir.exists?(part_path) && !File.symlink?(part_path)
    assert_columns_text(profile, File.read(File.join(part_path, "columns.txt")))
    assert_stream_inventory(profile, part_path, attached)
    expected_stream_names(profile).each do |logical|
      hash = CrystalClick::StreamName.hash(logical)
      data = File.read(File.join(part_path, "#{hash}.bin")).to_slice
      raw = data.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(data)
      assert_stream_raw(profile, logical, raw)
      assert_mark_raw(profile, logical, File.read(File.join(part_path, "#{hash}.mrk2")).to_slice)
    end
    assert_serialization_metadata(profile, File.read(File.join(part_path, "serialization.json")))
  rescue ex : W116JsonPhysicalMismatch
    raise ex
  rescue ex : Exception
    raise W116JsonPhysicalMismatch.new("W116 JSON physical mismatch: #{profile} part is unreadable: #{ex.message}")
  end

  def self.fixture_path(profile : String, attached : Bool = false) : String
    check_profile(profile)
    root = ENV["W115_CAPTURE_ROOT"]? || fail(profile, "W115_CAPTURE_ROOT is required")
    log = File.join(root, "capture.log")
    raise W116JsonPhysicalMismatch.new("W116 JSON physical mismatch: capture log is missing") unless File.file?(log) && !File.symlink?(log)
    label = attached ? "#{profile} fresh ATTACH" : "#{profile} source"
    line = File.read_lines(log).find { |entry| entry.starts_with?("#{label} part=") } || fail(profile, "capture log has no #{label} part")
    path = line.split("part=", 2)[1]? || fail(profile, "capture log part path is malformed")
    real_root = File.realpath(root)
    real_path = File.realpath(path)
    store = File.realpath(File.join(root, "store"))
    unless real_path.starts_with?(store + "/") && !File.symlink?(path) && !File.symlink?(root)
      fail(profile, "capture part is outside the isolated store")
    end
    real_path
  end

  private def self.assert_stream_inventory(profile : String, part_path : String, attached : Bool) : Nil
    actual = Dir.children(part_path).sort
    expected = expected_files(profile, attached)
    fail(profile, "stream inventory differs") unless actual == expected
  end

  private def self.assert_serialization_metadata(profile : String, actual : String) : Nil
    parsed = JSON.parse(actual).as_h
    expected = JSON.parse(expected_serialization_json).as_h
    fail(profile, "serialization.json metadata differs") unless parsed == expected
  rescue ex : W116JsonPhysicalMismatch
    raise ex
  rescue ex : Exception
    fail(profile, "serialization.json metadata differs")
  end

  private def self.expected_serialization_json : String
    %({"columns":[{"kind":"Default","name":"pk","num_defaults":0,"num_rows":8,"exact_num_defaults":true}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  end

  private def self.expected_mark_bytes(profile : String, logical_stream : String) : Bytes
    check_profile(profile)
    grid = expected_mark_grid(profile, logical_stream)
    bytes = IO::Memory.new
    grid.each do |(compressed, decompressed, rows)|
      write_u64(bytes, compressed)
      write_u64(bytes, decompressed)
      write_u64(bytes, rows)
    end
    bytes.to_slice
  end

  private def self.write_u64(io : IO, value : UInt64) : Nil
    8.times { |shift| io.write_byte(((value >> (shift * 8)) & 0xff_u64).to_u8) }
  end

  private def self.check_profile(profile : String) : Nil
    raise W116JsonPhysicalMismatch.new("W116 JSON physical mismatch: unknown profile: #{profile}") unless PROFILES.includes?(profile)
  end

  private def self.fail(profile : String, message : String) : NoReturn
    raise W116JsonPhysicalMismatch.new("W116 JSON physical mismatch: #{profile} #{message}")
  end
end
