require "../src/crystal_click"
require "json"
require "set"

module CheckSimpleAggregateBulkW222
  extend self

  FORMAT_INPUT  = "simple_aggregate_bulk_w222_input_v1"
  FORMAT_OUTPUT = "simple_aggregate_bulk_w222_helper_v1"
  ROOT_PREFIX   = "/private/tmp/crystal-click-w222-physical."
  COLUMN        = "v"
  KEY_COLUMN    = "pk"
  KEYS          = Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64]
  MARK_ROWS     = [2_u64, 2_u64, 1_u64]

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W222 bulk: #{message}") unless condition
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"
      CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W222 String serialization profile is outside the exact two-profile roster")
    end
  end

  private def nibble(byte : UInt8) : UInt8
    if byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
      return (byte - '0'.ord.to_u8).to_u8
    end
    if byte >= 'a'.ord.to_u8 && byte <= 'f'.ord.to_u8
      return (byte - 'a'.ord.to_u8 + 10).to_u8
    end
    raise ArgumentError.new("W222 literal bytes are not lowercase hexadecimal")
  end

  private def decode_hex(hex : String) : Bytes
    unless hex.bytesize.even? && hex.matches?(/\A(?:[0-9a-f]{2})*\z/)
      raise ArgumentError.new("W222 literal bytes are not an even lowercase hexadecimal string")
    end
    Bytes.new(hex.bytesize // 2) do |index|
      high = nibble(hex.byte_at(index * 2))
      low = nibble(hex.byte_at(index * 2 + 1))
      ((high << 4) | low).to_u8
    end
  end

  private def encode_hex(bytes : Bytes) : String
    String.build do |io|
      bytes.each { |byte| io << byte.to_s(16).rjust(2, '0') }
    end
  end

  private def write_varuint(io : IO, value : UInt64) : Nil
    remaining = value
    while remaining >= 0x80_u64
      io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
      remaining >>= 7
    end
    io.write_byte(remaining.to_u8)
  end

  private def fixed_payload?(type : CrystalClick::BinaryDataType) : Bool
    !type.fixed_width.nil?
  end

  private def build_value(
    type : CrystalClick::BinaryDataType,
    raw : JSON::Any,
  ) : CrystalClick::BinaryValue
    case type.tag
    when CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE
      CrystalClick::BinaryValue.simple_aggregate(type, build_value(type.child_at(0), raw))
    when CrystalClick::BinaryDataType::TAG_NULLABLE
      if raw.raw.nil?
        CrystalClick::BinaryValue.nullable(type)
      else
        CrystalClick::BinaryValue.nullable(type, build_value(type.child_at(0), raw))
      end
    when CrystalClick::BinaryDataType::TAG_STRING
      payload = decode_hex(raw["raw_hex"].as_s)
      value = CrystalClick::BinaryValue.string(String.new(payload))
      require!(value.type == type, "String literal does not retain its exact nominal descriptor")
      value
    when CrystalClick::BinaryDataType::TAG_ARRAY
      values = raw.as_a.map { |item| build_value(type.child_at(0), item) }
      CrystalClick::BinaryValue.array(type, values)
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      fields = raw.as_a
      require!(fields.size == type.child_count, "Tuple literal arity differs from exact descriptor")
      values = fields.each_with_index.map { |item, index| build_value(type.child_at(index), item) }.to_a
      CrystalClick::BinaryValue.tuple(type, values)
    when CrystalClick::BinaryDataType::TAG_MAP
      entries = [] of CrystalClick::BinaryValue
      raw.as_a.each do |pair|
        fields = pair.as_a
        require!(fields.size == 2, "Map literal entry does not have exactly two fields")
        entries << build_value(type.child_at(0), fields[0])
        entries << build_value(type.child_at(1), fields[1])
      end
      CrystalClick::BinaryValue.map(type, entries)
    else
      unless fixed_payload?(type)
        raise ArgumentError.new("W222 value fixture does not admit descriptor #{type.name}")
      end
      CrystalClick::BinaryValue.fixed(type, decode_hex(raw["raw_hex"].as_s))
    end
  end

  # This independent RowBinary encoder only composes literal payloads and
  # container lengths. It does not call the production value or bulk codecs.
  private def encode_value_to(io : IO, value : CrystalClick::BinaryValue) : Nil
    type = value.type
    case type.tag
    when CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE
      require!(value.child_count == 1, "SAF RowBinary value does not have one storage child")
      encode_value_to(io, value.child_at(0))
    when CrystalClick::BinaryDataType::TAG_NULLABLE
      if value.is_null?
        require!(value.child_count == 0, "NULL Nullable unexpectedly has a child")
        io.write_byte(0x01_u8)
      else
        require!(value.child_count == 1, "non-NULL Nullable does not have one child")
        io.write_byte(0x00_u8)
        encode_value_to(io, value.child_at(0))
      end
    when CrystalClick::BinaryDataType::TAG_STRING
      payload = value.bytes
      write_varuint(io, payload.size.to_u64)
      io.write(payload)
    when CrystalClick::BinaryDataType::TAG_ARRAY
      write_varuint(io, value.child_count.to_u64)
      value.child_count.times { |index| encode_value_to(io, value.child_at(index)) }
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      value.child_count.times { |index| encode_value_to(io, value.child_at(index)) }
    when CrystalClick::BinaryDataType::TAG_MAP
      require!(value.child_count.even?, "Map literal has an incomplete key/value pair")
      write_varuint(io, (value.child_count // 2).to_u64)
      value.child_count.times { |index| encode_value_to(io, value.child_at(index)) }
    else
      unless fixed_payload?(type)
        raise ArgumentError.new("W222 RowBinary witness does not admit descriptor #{type.name}")
      end
      io.write(value.bytes)
    end
    nil
  end

  private def encode_value(value : CrystalClick::BinaryValue) : Bytes
    io = IO::Memory.new
    encode_value_to(io, value)
    source = io.to_slice
    Bytes.new(source.size) { |index| source[index] }
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

  private def compare_values!(
    actual : Array(CrystalClick::BinaryValue),
    expected : Array(CrystalClick::BinaryValue),
    label : String,
  ) : Nil
    require!(actual.size == expected.size, "row count differs for #{label}")
    actual.each_with_index do |value, index|
      require!(value.type == expected[index].type, "nominal descriptor differs for #{label}/#{index}")
      require!(same_value?(value, expected[index]), "owned recursive value differs for #{label}/#{index}")
    end
  end

  private def expected_marks(values : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
    require!(values.size == 5, "literal fixture must contain exactly five rows")
    [values[0, 2], values[2, 2], values[4, 1]]
  end

  private def read_expected_values(
    input : JSON::Any,
    type : CrystalClick::BinaryDataType,
  ) : Array(CrystalClick::BinaryValue)
    rows = input["rowbinary_values"].as_a
    require!(rows.size == KEYS.size, "manifest row count differs from fixed five-row roster")
    values = [] of CrystalClick::BinaryValue
    rows.each_with_index do |row, index|
      require!(row["key"].as_i64.to_u64 == KEYS[index], "manifest key order differs")
      value = build_value(type, row["value"])
      require!(value.type == type, "independent literal does not match exact nominal SAF type")
      expected_wire = row["value_rowbinary_hex"].as_s
      require!(encode_hex(encode_value(value)) == expected_wire,
        "independent recursive value does not reproduce Ruby literal RowBinary bytes at row #{index}")
      values << value
    end
    values
  end

  private def compare_marks!(
    actual : Array(Array(CrystalClick::BinaryValue)),
    expected : Array(Array(CrystalClick::BinaryValue)),
    label : String,
  ) : Nil
    require!(actual.size == expected.size, "mark count differs for #{label}")
    actual.each_with_index do |rows, mark|
      compare_values!(rows, expected[mark], "#{label}/mark#{mark}")
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
    require!(reader.ordinary_profile == expected_profile, "#{origin} exact ordinary profile differs")
    require!(reader.schema_declaration == type.name, "#{origin} canonical schema declaration differs")
    require!(reader.source_declaration == type.name, "#{origin} source declaration differs")

    physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, COLUMN, expected_profile)
    roles = CrystalClick::BinaryBulkTypePlan.new(type, expected_profile).roles
    names = reader.physical_stream_names.sort!
    physical_names = physical.stream_names
    require!(physical_names.keys.sort == roles && names == physical_names.values.sort,
      "#{origin} physical stream roster differs from static type plan")
    checksums = reader.selected_checksum_names.sort!
    require!(!checksums.empty? && checksums.uniq == checksums, "#{origin} checksum roster is empty or duplicated")

    compare_marks!(reader.read_marks(0, 3), grid, "#{origin}/full")
    compare_marks!(reader.read_marks(0, 1), [grid[0]], "#{origin}/first")
    compare_marks!(reader.read_marks(1, 1), [grid[1]], "#{origin}/middle")
    compare_marks!(reader.read_marks(2, 1), [grid[2]], "#{origin}/final-short")
    require!(reader.read_marks(0, 0).empty?, "#{origin} first zero-mark window is not empty")
    require!(reader.read_marks(3, 0).empty?, "#{origin} EOF zero-mark window is not empty")

    JSON::Any.new({
      "schema_declaration"      => JSON::Any.new(reader.schema_declaration),
      "source_declaration"      => JSON::Any.new(reader.source_declaration),
      "row_count"               => JSON::Any.new(reader.row_count.to_i64),
      "real_mark_count"         => JSON::Any.new(reader.mark_count),
      "real_mark_row_counts"    => JSON::Any.new(reader.mark_row_counts.map { |count| JSON::Any.new(count.to_i64) }),
      "ordinary_profile"        => JSON::Any.new(profile_name),
      "logical_stream_roles"    => JSON::Any.new(roles.map { |name| JSON::Any.new(name) }),
      "physical_stream_names"   => JSON::Any.new(names.map { |name| JSON::Any.new(name) }),
      "selected_checksum_names" => JSON::Any.new(checksums.map { |name| JSON::Any.new(name) }),
      "windows"                 => JSON::Any.new(["full", "first", "middle", "final_short", "first_zero", "eof_zero"].map { |name| JSON::Any.new(name) }),
    } of String => JSON::Any)
  end

  private def public_scan_record(
    part_path : String,
    type : CrystalClick::BinaryDataType,
    values : Array(CrystalClick::BinaryValue),
    origin : String,
  ) : JSON::Any
    table = CrystalClick::WidePartTable.open_selected_typed([part_path], [KEY_COLUMN, COLUMN])
    actual = [] of CrystalClick::BinaryValue
    batch_schedule = [] of Tuple(Int32, UInt64, Int32)
    table.scan_typed(batch_rows: 2) do |batch|
      row_count = 0
      batch.binary_bulk_values_for(COLUMN).each do |value|
        actual << value
        row_count += 1
      end
      batch_schedule << {batch.mark_index, batch.part_row_offset, row_count}
    end
    compare_values!(actual, values, "#{origin}/public-selected-typed-scan")
    expected_schedule = [{0_i32, 0_u64, 2_i32}, {1_i32, 2_u64, 2_i32}, {2_i32, 4_u64, 1_i32}]
    require!(batch_schedule == expected_schedule, "#{origin} public scan mark/offset schedule differs")
    JSON::Any.new({
      "api"                => JSON::Any.new("WidePartTable.open_selected_typed + scan_typed + binary_bulk_values_for"),
      "schema_declaration" => JSON::Any.new(type.name),
      "rows"               => JSON::Any.new(actual.size),
      "batch_rows"         => JSON::Any.new(2),
      "batch_schedule"     => JSON::Any.new(batch_schedule.map { |entry|
        JSON::Any.new([JSON::Any.new(entry[0]), JSON::Any.new(entry[1].to_i64), JSON::Any.new(entry[2])])
      }),
      "exact_recursive_values" => JSON::Any.new(true),
    } of String => JSON::Any)
  end

  private def require_part_path!(path : String, root : String, generated : Bool) : Nil
    full = File.expand_path(path)
    require!(full.starts_with?(root + File::SEPARATOR), "part escaped its authorized root")
    if generated
      parent = File.dirname(full)
      require!(Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent,
        "generated part parent is absent, symlinked, or noncanonical")
      require!(!File.exists?(full) && !File.symlink?(full), "library part already exists")
    else
      require!(Dir.exists?(full) && !File.symlink?(full) && File.realpath(full) == full,
        "stock copied part is absent, symlinked, or noncanonical")
    end
  end

  private def failed_record(input : JSON::Any, classification : String, error : Exception) : JSON::Any
    JSON::Any.new({
      "id"                => JSON::Any.new(input["id"].as_s),
      "declared_type"     => JSON::Any.new(input["declared_type"].as_s),
      "classification"    => JSON::Any.new(classification),
      "error_class"       => JSON::Any.new(error.class.to_s),
      "error"             => JSON::Any.new(error.message || ""),
      "source_part_path"  => JSON::Any.new(input["source_part"].as_s),
      "library_part_path" => JSON::Any.new(input["library_part"].as_s),
    } of String => JSON::Any)
  end

  private def process_case(
    input : JSON::Any,
    output_root : String,
    capture_root : String,
  ) : JSON::Any
    id = input["id"].as_s
    declared_type = input["declared_type"].as_s
    source_part = input["source_part"].as_s
    library_part = input["library_part"].as_s
    source_profile = input["source_profile"].as_s
    library_profile = input["library_profile"].as_s
    metadata_version_text = input["metadata_version"].as_s
    require!(id.matches?(/\A[A-Za-z0-9_.-]+\z/), "case id is not a safe fixed label")
    require!(metadata_version_text == "0" || metadata_version_text == "1", "metadata version is outside {0,1}")
    require_part_path!(source_part, capture_root, false)
    require_part_path!(library_part, output_root, true)

    type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(declared_type) ||
           raise ArgumentError.new("canonical SAF declaration is not admitted by the recursive name parser")
    require!(type.name == declared_type, "parsed descriptor does not preserve the exact canonical name")
    aggregate = if type.tag == CrystalClick::BinaryDataType::TAG_NULLABLE
                  type.child_at(0)
                else
                  type
                end
    require!(aggregate.tag == CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE,
      "declared type is not bare or outer-Nullable SimpleAggregateFunction")
    storage = aggregate.child_at(0)
    require!(storage.tag != CrystalClick::BinaryDataType::TAG_NULLABLE ||
             storage.child_at(0).tag != CrystalClick::BinaryDataType::TAG_NULLABLE,
      "double inner Nullable storage is outside the certified W222 roster")

    values = read_expected_values(input, type)
    marks = expected_marks(values)
    source = reader_record(source_part, type, values, source_profile, "stock")
    source_public = public_scan_record(source_part, type, values, "stock")

    output_profile = profile(library_profile)
    written_path = CrystalClick::WidePartWriter.write_uint64_simple_aggregate_bulk_part(
      library_part,
      KEY_COLUMN,
      KEYS,
      COLUMN,
      type,
      marks,
      rows_per_mark: 2,
      profile: output_profile,
      frame_bytes: 64,
      metadata_version: metadata_version_text.to_i64,
    )
    require!(written_path == library_part && Dir.exists?(library_part), "writer did not publish the requested part")
    library = reader_record(written_path, type, values, library_profile, "library")
    library_public = public_scan_record(written_path, type, values, "library")

    source_streams = source["physical_stream_names"].as_a.map(&.as_s)
    library_streams = library["physical_stream_names"].as_a.map(&.as_s)
    require!(source_streams == library_streams, "stock and library stream-name roster differs")
    source_checksums = source["selected_checksum_names"].as_a.map(&.as_s)
    library_checksums = library["selected_checksum_names"].as_a.map(&.as_s)
    require!(source_checksums == library_checksums, "stock and library selected checksum roster differs")

    JSON::Any.new({
      "id"                  => JSON::Any.new(id),
      "source_function"     => input["source_function"],
      "canonical_function"  => input["canonical_function"],
      "category"            => input["category"],
      "declared_type"       => JSON::Any.new(type.name),
      "storage_type"        => input["storage_type"],
      "source_profile"      => JSON::Any.new(source_profile),
      "library_profile"     => JSON::Any.new(library_profile),
      "metadata_version"    => JSON::Any.new(metadata_version_text.to_i64),
      "classification"      => JSON::Any.new("physical_observed"),
      "source_part_path"    => JSON::Any.new(File.expand_path(source_part)),
      "library_part_path"   => JSON::Any.new(File.expand_path(written_path)),
      "source"              => source,
      "source_public_scan"  => source_public,
      "library"             => library,
      "library_public_scan" => library_public,
    } of String => JSON::Any)
  rescue ex : Exception
    failed_record(input, "library_or_reader_mismatch", ex)
  end

  private def validate_input!(input : JSON::Any, output_root : String, capture_root : String) : Array(JSON::Any)
    require!(input.as_h.keys.sort == ["capture_root", "format", "profiles"] &&
             input["format"].as_s == FORMAT_INPUT, "helper input format differs")
    require!(input["capture_root"].as_s == capture_root, "capture root differs")
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "stock physical root is absent, symlinked, or noncanonical")
    require!(capture_root.starts_with?(ROOT_PREFIX) && File.dirname(capture_root) == "/private/tmp",
      "stock root is outside the fixed W222 physical prefix")
    profiles = input["profiles"].as_a
    require!(profiles.size == 39, "the exact frozen 39-profile W222 roster is required")
    seen = Set(String).new
    profiles.each do |item|
      required = %w[canonical_function category declared_type id library_part library_profile metadata_version
        rowbinary_values source_function source_part source_profile storage_spec storage_type]
      require!(item.as_h.keys.sort == required.sort, "helper profile keys differ from frozen W222 input")
      id = item["id"].as_s
      require!(!seen.includes?(id), "duplicate W222 profile id #{id}")
      seen << id
      require!(item["rowbinary_values"].as_a.size == 5, "profile lacks five literal rows")
      source_profile = item["source_profile"].as_s
      library_profile = item["library_profile"].as_s
      require!(source_profile == "single_stream" || source_profile == "with_size_stream",
        "source ordinary profile is outside the measured pair")
      require!(library_profile == "single_stream" || library_profile == "with_size_stream",
        "library ordinary profile is outside the measured pair")
      require!(File.expand_path(item["source_part"].as_s).starts_with?(capture_root + File::SEPARATOR),
        "stock part path is outside source root")
      require!(File.expand_path(item["library_part"].as_s).starts_with?(output_root + File::SEPARATOR),
        "library part path is outside generated root")
      require!(item["metadata_version"].as_s == "0" || item["metadata_version"].as_s == "1",
        "profile metadata version is outside the exact observed pair")
    end
    profiles
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 3
      raise ArgumentError.new("usage: check_simple_aggregate_bulk_w222.cr INPUT.json OUTPUT_ROOT CAPTURE_ROOT")
    end
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    capture_root = File.expand_path(args[2])
    unless Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root
      raise ArgumentError.new("W222 generated root must be canonical and non-symlinked")
    end
    unless File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR)
      raise ArgumentError.new("W222 helper input must be a plain file below generated root")
    end

    input = JSON.parse(File.read(input_path))
    profiles = validate_input!(input, output_root, capture_root)
    output_profiles = profiles.map { |item| process_case(item, output_root, capture_root) }
    successful = output_profiles.count { |item| item["classification"].as_s == "physical_observed" }
    output = JSON::Any.new({
      "format"            => JSON::Any.new(FORMAT_OUTPUT),
      "profile_count"     => JSON::Any.new(output_profiles.size),
      "physical_observed" => JSON::Any.new(successful),
      "mismatch_count"    => JSON::Any.new(output_profiles.size - successful),
      "profiles"          => JSON::Any.new(output_profiles),
    } of String => JSON::Any)
    puts output.to_json
    exit 1 unless successful == 39
  rescue ex : Exception
    STDERR.puts "W222 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckSimpleAggregateBulkW222.main(ARGV)
