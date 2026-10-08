require "../src/crystal_click"
require "json"

module CheckSimpleAggregateBulkW221
  extend self

  FORMAT_INPUT  = "simple_aggregate_bulk_w221_input_v1"
  FORMAT_OUTPUT = "simple_aggregate_bulk_w221_helper_v1"
  ROOT_PREFIX   = "/private/tmp/crystal-click-w221-physical."
  COLUMN        = "v"
  KEYS          = Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64]
  MARK_ROWS     = [2_u64, 2_u64, 1_u64]
  HEX_DIGITS    = "0123456789abcdef"

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W221 bulk: #{message}") unless condition
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"
      CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W221 String profile is outside the exact two-profile roster")
    end
  end

  private def function(name : String) : CrystalClick::BinarySimpleAggregateType::Function
    case name
    when "any"
      CrystalClick::BinarySimpleAggregateType::Function::Any
    when "anyLast"
      CrystalClick::BinarySimpleAggregateType::Function::AnyLast
    when "min"
      CrystalClick::BinarySimpleAggregateType::Function::Min
    when "max"
      CrystalClick::BinarySimpleAggregateType::Function::Max
    when "sum"
      CrystalClick::BinarySimpleAggregateType::Function::Sum
    when "sumWithOverflow"
      CrystalClick::BinarySimpleAggregateType::Function::SumWithOverflow
    when "groupBitAnd"
      CrystalClick::BinarySimpleAggregateType::Function::GroupBitAnd
    when "groupBitOr"
      CrystalClick::BinarySimpleAggregateType::Function::GroupBitOr
    when "groupBitXor"
      CrystalClick::BinarySimpleAggregateType::Function::GroupBitXor
    when "any_respect_nulls"
      CrystalClick::BinarySimpleAggregateType::Function::AnyRespectNulls
    when "anyLast_respect_nulls"
      CrystalClick::BinarySimpleAggregateType::Function::AnyLastRespectNulls
    else
      raise ArgumentError.new("W221 function is outside the exact eleven-name roster")
    end
  end

  private def leaf_type(name : String) : CrystalClick::BinaryDataType
    if decimal = CrystalClick::DecimalType.parse(name)
      return CrystalClick::BinaryDataType.decimal(decimal.storage_width * 8, decimal.precision, decimal.scale)
    end

    if match = /\AFixedString\(([1-9][0-9]*)\)\z/.match(name)
      return CrystalClick::BinaryDataType.fixed_string(match[1].to_i)
    end

    case name
    when "Date"
      return CrystalClick::BinaryDataType.primitive("Date")
    when "Date32"
      return CrystalClick::BinaryDataType.primitive("Date32")
    when "Time"
      return CrystalClick::BinaryDataType.primitive("Time")
    end

    if match = /\ATime64\(([0-9])\)\z/.match(name)
      return CrystalClick::BinaryDataType.time64(match[1].to_i)
    end

    if match = /\ADateTime\('([^']+)'\)\z/.match(name)
      return CrystalClick::BinaryDataType.datetime(match[1])
    end

    if match = /\ADateTime64\(([0-9]), '([^']+)'\)\z/.match(name)
      return CrystalClick::BinaryDataType.datetime64(match[1].to_i, match[2])
    end

    CrystalClick::BinaryDataType.primitive(name)
  end

  private def type_for(input : JSON::Any) : CrystalClick::BinaryDataType
    leaf = leaf_type(input["leaf_type"].as_s)
    shape = input["shape"].as_s
    function = function(input["function"].as_s)

    case shape
    when "scalar"
      CrystalClick::BinaryDataType.simple_aggregate(function, leaf)
    when "inner_nullable"
      storage = CrystalClick::BinaryDataType.nullable(leaf)
      CrystalClick::BinaryDataType.simple_aggregate(function, storage)
    when "outer_nullable"
      aggregate = CrystalClick::BinaryDataType.simple_aggregate(function, leaf)
      CrystalClick::BinaryDataType.nullable(aggregate)
    else
      raise ArgumentError.new("W221 shape is outside the exact three-shape roster")
    end
  end

  private def nibble(byte : UInt8) : UInt8
    if byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
      return (byte - '0'.ord.to_u8).to_u8
    end
    if byte >= 'a'.ord.to_u8 && byte <= 'f'.ord.to_u8
      return (byte - 'a'.ord.to_u8 + 10).to_u8
    end
    raise ArgumentError.new("W221 raw leaf bytes are not lowercase hexadecimal")
  end

  private def decode_hex(hex : String) : Bytes
    unless hex.bytesize.even? && hex.matches?(/\A(?:[0-9a-f]{2})*\z/)
      raise ArgumentError.new("W221 raw leaf bytes are not an even lowercase hexadecimal string")
    end
    Bytes.new(hex.bytesize // 2) do |index|
      high = nibble(hex.byte_at(index * 2))
      low = nibble(hex.byte_at(index * 2 + 1))
      ((high << 4) | low).to_u8
    end
  end

  private def encode_hex(bytes : Bytes) : String
    String.build do |io|
      bytes.each do |byte|
        io << byte.to_s(16).rjust(2, '0')
      end
    end
  end

  private def string_value(type : CrystalClick::BinaryDataType, bytes : Bytes) : CrystalClick::BinaryValue
    offset = 0
    length = 0_u64
    shift = 0
    loop do
      require!(offset < bytes.size, "truncated String RowBinary length")
      byte = bytes[offset]
      offset += 1
      payload = (byte & 0x7f_u8).to_u64
      require!(shift < 64 && (shift != 63 || payload <= 1_u64), "String RowBinary length overflows UInt64")
      length |= payload << shift
      break if (byte & 0x80_u8) == 0_u8
      shift += 7
      require!(offset <= 10, "String RowBinary length exceeds VarUInt width")
    end
    require!(length == (bytes.size - offset).to_u64, "String RowBinary payload length differs")
    payload = Bytes.new(length.to_i) { |index| bytes[offset + index] }
    value = CrystalClick::BinaryValue.string(String.new(payload))
    require!(value.type == type, "String value does not retain the exact leaf descriptor")
    value
  end

  private def leaf_value(type : CrystalClick::BinaryDataType, hex : String) : CrystalClick::BinaryValue
    bytes = decode_hex(hex)
    if type.tag == CrystalClick::BinaryDataType::TAG_STRING
      return string_value(type, bytes)
    end
    CrystalClick::BinaryValue.fixed(type, bytes)
  end

  private def expected_wire(shape : String, is_null : Bool, raw_leaf : Bytes) : Bytes
    if shape == "scalar"
      require!(!is_null, "scalar SAF row unexpectedly carries NULL")
      return raw_leaf
    end
    if is_null
      require!(raw_leaf.empty?, "NULL SAF row unexpectedly carries raw leaf bytes")
      return Bytes[0x01_u8]
    end
    wire = Bytes.new(raw_leaf.size + 1)
    wire[0] = 0x00_u8
    raw_leaf.each_with_index { |byte, index| wire[index + 1] = byte }
    wire
  end

  private def values_for(
    input : JSON::Any,
    type : CrystalClick::BinaryDataType,
  ) : Array(CrystalClick::BinaryValue)
    leaf = leaf_type(input["leaf_type"].as_s)
    shape = input["shape"].as_s
    rows = input["rowbinary_values"].as_a
    require!(rows.size == KEYS.size, "manifest row count differs from the five fixed rows")

    aggregate_type = if type.tag == CrystalClick::BinaryDataType::TAG_NULLABLE
                       type.child_at(0)
                     else
                       type
                     end
    require!(aggregate_type.tag == CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE,
      "constructed SAF root is not the expected nominal aggregate")
    storage_type = aggregate_type.child_at(0)
    output = [] of CrystalClick::BinaryValue

    rows.each_with_index do |row, index|
      require!(row["key"].as_i64.to_u64 == KEYS[index], "manifest key order differs")
      is_null = row["is_null"].as_bool
      raw_hex = row["leaf_value_rowbinary_hex"].as_s
      raw = if is_null
              require!(raw_hex.empty?, "NULL row contains a leaf hex payload")
              Bytes.empty
            else
              require!(!raw_hex.empty?, "non-NULL row lacks its literal leaf hex payload")
              decode_hex(raw_hex)
            end
      wire = expected_wire(shape, is_null, raw)
      require!(encode_hex(wire) == row["value_rowbinary_hex"].as_s,
        "literal RowBinary bytes disagree with the independently composed null/leaf bytes at row #{index}")

      if is_null
        require!(shape != "scalar", "scalar SAF shape cannot carry NULL")
        value = if shape == "inner_nullable"
                  CrystalClick::BinaryValue.simple_aggregate(
                    aggregate_type,
                    CrystalClick::BinaryValue.nullable(storage_type),
                  )
                elsif shape == "outer_nullable"
                  CrystalClick::BinaryValue.nullable(type)
                else
                  raise ArgumentError.new("W221 NULL row has an invalid shape")
                end
        output << value
      else
        child = leaf_value(leaf, raw_hex)
        require!(child.type == leaf, "literal raw leaf child does not match its canonical descriptor")
        value = case shape
                when "scalar"
                  CrystalClick::BinaryValue.simple_aggregate(aggregate_type, child)
                when "inner_nullable"
                  nullable = CrystalClick::BinaryValue.nullable(storage_type, child)
                  CrystalClick::BinaryValue.simple_aggregate(aggregate_type, nullable)
                when "outer_nullable"
                  aggregate = CrystalClick::BinaryValue.simple_aggregate(aggregate_type, child)
                  CrystalClick::BinaryValue.nullable(type, aggregate)
                else
                  raise ArgumentError.new("W221 shape is outside the exact three-shape roster")
                end
        output << value
      end
    end

    output
  end

  private def expected_marks(values : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
    require!(values.size == 5, "W221 expected values must contain exactly five rows")
    [values[0, 2], values[2, 2], values[4, 1]]
  end

  private def same_value?(left : CrystalClick::BinaryValue, right : CrystalClick::BinaryValue) : Bool
    return false unless left.type == right.type && left.is_null? == right.is_null?
    if left.type.tag == CrystalClick::BinaryDataType::TAG_VARIANT
      return false unless left.variant_index? == right.variant_index?
    end

    return false unless left.byte_size == right.byte_size
    left.byte_size.times do |index|
      return false unless left.byte_at(index) == right.byte_at(index)
    end

    return false unless left.child_count == right.child_count
    left.child_count.times do |index|
      return false unless same_value?(left.child_at(index), right.child_at(index))
    end
    true
  end

  private def compare_marks!(
    actual : Array(Array(CrystalClick::BinaryValue)),
    expected : Array(Array(CrystalClick::BinaryValue)),
    label : String,
  ) : Nil
    require!(actual.size == expected.size, "mark count differs for #{label}")
    actual.each_with_index do |rows, mark|
      wanted_rows = expected[mark]
      require!(rows.size == wanted_rows.size, "row count differs for #{label}/mark #{mark}")
      rows.each_with_index do |value, row|
        wanted = wanted_rows[row]
        require!(value.type == wanted.type, "nominal type differs for #{label}/#{mark}/#{row}")
        require!(same_value?(value, wanted), "literal owned value differs for #{label}/#{mark}/#{row}")
      end
    end
  end

  private def reader_record(
    part_path : String,
    type : CrystalClick::BinaryDataType,
    values : Array(CrystalClick::BinaryValue),
    profile_name : String,
    origin : String,
  ) : JSON::Any
    reader = CrystalClick::BinaryBulkColumnReader.open(part_path, COLUMN, type)
    grid = expected_marks(values)
    expected_profile = profile(profile_name)
    require!(reader.row_count == 5_u64 && reader.mark_count == 3, "#{origin} row/real-mark census differs")
    require!(reader.mark_row_counts == MARK_ROWS, "#{origin} real mark grid is not [2, 2, 1]")
    require!(reader.ordinary_profile == expected_profile, "#{origin} String serialization profile differs")
    require!(reader.schema_declaration == type.name, "#{origin} canonical schema declaration differs")
    require!(reader.source_declaration == type.name, "#{origin} source declaration differs")

    physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, COLUMN, expected_profile)
    roles = CrystalClick::BinaryBulkTypePlan.new(type, expected_profile).roles
    names = reader.physical_stream_names.sort!
    physical_names = physical.stream_names
    require!(physical_names.keys.sort == roles && names == physical_names.values.sort,
      "#{origin} physical stream roster differs from the static type plan")
    checksums = reader.selected_checksum_names.sort!
    require!(!checksums.empty? && checksums.uniq == checksums, "#{origin} selected checksum roster is empty or duplicated")

    full = reader.read_marks(0, 3)
    compare_marks!(full, grid, "#{origin} full")
    first = reader.read_marks(0, 1)
    compare_marks!(first, [grid[0]], "#{origin} first mark")
    middle = reader.read_marks(1, 1)
    compare_marks!(middle, [grid[1]], "#{origin} middle mark")
    final = reader.read_marks(2, 1)
    compare_marks!(final, [grid[2]], "#{origin} final short mark")
    zero = reader.read_marks(3, 0)
    require!(zero.empty?, "#{origin} zero-end mark window is not empty")

    JSON::Any.new({
      "schema_declaration"    => JSON::Any.new(reader.schema_declaration),
      "source_declaration"    => JSON::Any.new(reader.source_declaration),
      "row_count"             => JSON::Any.new(reader.row_count.to_i64),
      "real_mark_count"       => JSON::Any.new(reader.mark_count),
      "real_mark_row_counts"  => JSON::Any.new(reader.mark_row_counts.map { |count| JSON::Any.new(count.to_i64) }),
      "ordinary_profile"      => JSON::Any.new(profile_name),
      "logical_stream_roles"  => JSON::Any.new(roles.map { |name| JSON::Any.new(name) }),
      "physical_stream_names" => JSON::Any.new(names.map { |name| JSON::Any.new(name) }),
      "selected_checksum_names" => JSON::Any.new(checksums.map { |name| JSON::Any.new(name) }),
      "windows"               => JSON::Any.new(["full", "first_mark", "middle_mark", "final_short_mark", "zero_end"].map { |name| JSON::Any.new(name) }),
    } of String => JSON::Any)
  end

  private def require_path!(path : String, root : String, generated : Bool) : Nil
    full = File.expand_path(path)
    if generated
      require!(full.starts_with?(root + File::SEPARATOR), "library part escaped the generated root")
      parent = File.dirname(full)
      require!(Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent,
        "library part parent is absent, symlinked, or noncanonical")
      require!(!File.exists?(full) && !File.symlink?(full), "library part destination already exists")
    else
      require!(full.starts_with?(root + File::SEPARATOR), "stock part escaped its capture root")
      require!(Dir.exists?(full) && !File.symlink?(full) && File.realpath(full) == full,
        "stock part is absent, symlinked, or noncanonical")
    end
  end

  private def failed_record(input : JSON::Any, classification : String, error : Exception) : JSON::Any
    JSON::Any.new({
      "id"             => JSON::Any.new(input["id"].as_s),
      "declared_type"  => JSON::Any.new(input["declared_type"].as_s),
      "classification" => JSON::Any.new(classification),
      "error_class"    => JSON::Any.new(error.class.to_s),
      "error"          => JSON::Any.new(error.message || ""),
      "library_part_path" => JSON::Any.new(input["library_part"].as_s),
    } of String => JSON::Any)
  end

  private def process_case(
    input : JSON::Any,
    output_root : String,
    capture_root : String,
  ) : JSON::Any
    id = input["id"].as_s
    function_name = input["function"].as_s
    leaf_name = input["leaf_type"].as_s
    shape = input["shape"].as_s
    mode = input["string_serialization_mode"].as_s
    source_mode = input["source_string_serialization_mode"].as_s
    declared_type = input["declared_type"].as_s
    source_part = input["source_part"].as_s
    library_part = input["library_part"].as_s
    metadata_version_text = input["metadata_version"].as_s

    require!(metadata_version_text == "0" || metadata_version_text == "1",
      "stock metadata version is outside the measured 0/1 roster")
    metadata_version = metadata_version_text.to_i64
    require_path!(source_part, capture_root, false)
    require_path!(library_part, output_root, true)
    require!(id.bytesize > 0 && id.matches?(/\A[A-Za-z0-9_.-]+\z/), "case id is not a safe fixed label")

    type = begin
      constructed = type_for(input)
      require!(constructed.name == declared_type, "canonical type name differs from stock declaration")
      constructed
    rescue ex : Exception
      return failed_record(input, "library_type_rejection", ex)
    end

    leaf = leaf_type(leaf_name)
    require!(leaf.name == leaf_name, "leaf descriptor is not canonical")
    begin
      values = values_for(input, type)
    rescue ex : Exception
      return failed_record(input, "probe_fixture_failure", ex)
    end
    marks = expected_marks(values)
    selected_profile = profile(mode)

    source = begin
      reader_record(source_part, type, values, source_mode, "stock")
    rescue ex : Exception
      return failed_record(input, "stock_reader_mismatch", ex)
    end

    written_path = begin
      actual = CrystalClick::WidePartWriter.write_uint64_simple_aggregate_bulk_part(
        library_part,
        "k",
        KEYS,
        COLUMN,
        type,
        marks,
        rows_per_mark: 2,
        profile: selected_profile,
        frame_bytes: 4096,
        metadata_version: metadata_version,
      )
      require!(actual == library_part && Dir.exists?(library_part), "writer did not publish the requested library part")
      actual
    rescue ex : Exception
      return failed_record(input, "library_writer_mismatch", ex)
    end

    library = begin
      reader_record(written_path, type, values, mode, "library")
    rescue ex : Exception
      return failed_record(input, "library_reader_mismatch", ex)
    end

    source_streams = source["physical_stream_names"].as_a.map(&.as_s)
    library_streams = library["physical_stream_names"].as_a.map(&.as_s)
    require!(source_streams == library_streams, "stock and library physical stream names differ")
    source_checksums = source["selected_checksum_names"].as_a.map(&.as_s)
    library_checksums = library["selected_checksum_names"].as_a.map(&.as_s)
    require!(source_checksums == library_checksums, "stock and library checksum roster names differ")

    JSON::Any.new({
      "id"               => JSON::Any.new(id),
      "function"         => JSON::Any.new(function_name),
      "leaf_type"        => JSON::Any.new(leaf_name),
      "shape"            => JSON::Any.new(shape),
      "string_serialization_mode" => JSON::Any.new(mode),
      "source_string_serialization_mode" => JSON::Any.new(source_mode),
      "ordinary_profile_evidence" => JSON::Any.new({
        "stock_source" => source["ordinary_profile"],
        "library_writer_reader" => library["ordinary_profile"],
        "profiles_differ" => JSON::Any.new(source_mode != mode),
      } of String => JSON::Any),
      "declared_type"    => JSON::Any.new(type.name),
      "metadata_version" => JSON::Any.new(metadata_version),
      "classification"   => JSON::Any.new("physical_observed"),
      "source_part_path" => JSON::Any.new(File.expand_path(source_part)),
      "library_part_path" => JSON::Any.new(File.expand_path(written_path)),
      "stock"            => source,
      "library"          => library,
    } of String => JSON::Any)
  rescue ex : Exception
    failed_record(input, "probe_fixture_failure", ex)
  end

  private def validate_input!(input : JSON::Any, output_root : String, capture_root : String) : Array(JSON::Any)
    require!(input.as_h.keys.sort == ["capture_root", "format", "profiles"] &&
      input["format"].as_s == FORMAT_INPUT, "helper input format differs")
    require!(input["capture_root"].as_s == capture_root, "helper capture root differs")
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "stock capture root is absent, symlinked, or noncanonical")
    require!(capture_root.starts_with?(ROOT_PREFIX) && File.dirname(capture_root) == "/private/tmp",
      "stock capture root is outside the fixed W221 physical prefix")

    profiles = input["profiles"].as_a
    require!(profiles.size == 186, "the exact 186-case W221 physical roster is required")
    ids = Set(String).new
    profiles.each do |item|
      required_keys = ["declared_type", "function", "id", "kind", "leaf_key", "leaf_type",
                       "library_part", "metadata_version", "rowbinary_values", "shape",
                       "source_part", "source_string_serialization_mode", "string_serialization_mode"]
      require!(item.as_h.keys.sort == required_keys.sort, "profile input keys differ")
      library_mode = item["string_serialization_mode"].as_s
      source_mode = item["source_string_serialization_mode"].as_s
      require!(library_mode == "single_stream" || library_mode == "with_size_stream",
        "library String serialization mode is outside the exact two-profile roster")
      require!(source_mode == "single_stream" || source_mode == "with_size_stream",
        "stock String serialization mode is outside the exact two-profile roster")
      if item["leaf_type"].as_s == "String"
        require!(source_mode == library_mode, "explicit stock/library String profiles differ")
      else
        require!(source_mode == "with_size_stream" && library_mode == "single_stream",
          "non-String stock/library profiles differ from the measured omitted-setting pair")
      end
      id = item["id"].as_s
      require!(!ids.includes?(id), "duplicate case id #{id}")
      ids << id
      require!(item["kind"].as_s == "matrix" || item["kind"].as_s == "control", "unknown profile kind")
      require!(File.expand_path(item["source_part"].as_s).starts_with?(capture_root + File::SEPARATOR),
        "stock part is outside capture root")
      require!(File.expand_path(item["library_part"].as_s).starts_with?(output_root + File::SEPARATOR),
        "library part is outside generated root")
      require!(item["rowbinary_values"].as_a.size == 5, "profile does not contain five independent literal rows")
    end
    profiles
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 3
      raise ArgumentError.new("usage: check_simple_aggregate_bulk_w221.cr INPUT.json OUTPUT_ROOT CAPTURE_ROOT")
    end
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    capture_root = File.expand_path(args[2])
    unless Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root
      raise ArgumentError.new("W221 generated output root must be canonical and non-symlinked")
    end
    unless File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR)
      raise ArgumentError.new("W221 helper input must be a plain file below generated output root")
    end

    input = JSON.parse(File.read(input_path))
    profiles = validate_input!(input, output_root, capture_root)
    output_profiles = profiles.map { |item| process_case(item, output_root, capture_root) }
    successful = output_profiles.count { |item| item["classification"].as_s == "physical_observed" }
    output = JSON::Any.new({
      "format"         => JSON::Any.new(FORMAT_OUTPUT),
      "profile_count"  => JSON::Any.new(output_profiles.size),
      "physical_observed" => JSON::Any.new(successful),
      "mismatch_count" => JSON::Any.new(output_profiles.size - successful),
      "profiles"       => JSON::Any.new(output_profiles),
    } of String => JSON::Any)
    puts output.to_json
    exit 1 unless successful == 186
  rescue ex : Exception
    STDERR.puts "W221 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckSimpleAggregateBulkW221.main(ARGV)
