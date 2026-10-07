require "../src/crystal_click"
require "json"

module CheckNestedBulkPartW202
  extend self

  PROFILE_IDS        = ["single_stream", "with_size_stream"]
  EXPECTED_MARK_ROWS = [2_u64, 2_u64, 2_u64, 2_u64]
  COLUMN             = "payload"
  FORMAT_INPUT       = "nested_bulk_part_w202_input_v1"
  FORMAT_OUTPUT      = "nested_bulk_part_w202_helper_v1"

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W202: #{message}") unless condition
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"
      CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W202 String profile is outside the fixed two-profile roster")
    end
  end

  private def nested_type : CrystalClick::BinaryDataType
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    nullable_string = CrystalClick::BinaryDataType.nullable(string)
    low_cardinality = CrystalClick::BinaryDataType.low_cardinality(nullable_string)
    variant = CrystalClick::BinaryDataType.variant([uint64, string] of CrystalClick::BinaryDataType)
    CrystalClick::BinaryDataType.nested(
      [low_cardinality, variant, string] of CrystalClick::BinaryDataType,
      ["label", "choice", "text"] of String,
    )
  end

  private def string_choice(variant : CrystalClick::BinaryDataType, value : String) : CrystalClick::BinaryValue
    string = CrystalClick::BinaryDataType.primitive("String")
    index = variant.children.index(string).not_nil!
    CrystalClick::BinaryValue.variant(variant, index, CrystalClick::BinaryValue.string(value))
  end

  private def uint64_choice(variant : CrystalClick::BinaryDataType, value : UInt64) : CrystalClick::BinaryValue
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    index = variant.children.index(uint64).not_nil!
    CrystalClick::BinaryValue.variant(variant, index, CrystalClick::BinaryValue.uint64(value))
  end

  private def nested_record(
    type : CrystalClick::BinaryDataType,
    label : String?,
    choice : CrystalClick::BinaryValue,
    text : String,
  ) : CrystalClick::BinaryValue
    tuple = type.child_at(0)
    low = tuple.child_at(0)
    nullable = low.child_at(0)
    label_value = if raw = label
                    CrystalClick::BinaryValue.nullable(nullable, CrystalClick::BinaryValue.string(raw))
                  else
                    CrystalClick::BinaryValue.nullable(nullable)
                  end
    CrystalClick::BinaryValue.tuple(
      tuple,
      [
        CrystalClick::BinaryValue.low_cardinality(low, label_value),
        choice,
        CrystalClick::BinaryValue.string(text),
      ] of CrystalClick::BinaryValue,
    )
  end

  # Eight independently-authored rows, grouped into the fixed four-mark grid.
  # The first mark is empty; later marks include ragged Nested lengths, NULL,
  # default/empty and repeated LowCardinality values, both Variant arms, and
  # Variant NULLs. Direct String values distinguish both serialization modes.
  private def fixture(type : CrystalClick::BinaryDataType) : Array(Array(CrystalClick::BinaryValue))
    variant = type.child_at(0).child_at(1)
    empty = -> { CrystalClick::BinaryValue.nested(type, [] of CrystalClick::BinaryValue) }
    nested = ->(items : Array(CrystalClick::BinaryValue)) { CrystalClick::BinaryValue.nested(type, items) }
    [
      [empty.call, empty.call] of CrystalClick::BinaryValue,
      [
        nested.call([
          nested_record(type, nil, string_choice(variant, "after-empty"), "after-empty"),
          nested_record(type, "x", uint64_choice(variant, 701_u64), "num-first"),
        ] of CrystalClick::BinaryValue),
        nested.call([
          nested_record(type, "x", string_choice(variant, "repeat"), "repeat"),
          nested_record(type, "", CrystalClick::BinaryValue.variant_null(variant), ""),
        ] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue,
      [
        nested.call([
          nested_record(type, "", uint64_choice(variant, 0_u64), "default-label"),
          nested_record(type, nil, uint64_choice(variant, 42_u64), "null-label"),
        ] of CrystalClick::BinaryValue),
        empty.call,
      ] of CrystalClick::BinaryValue,
      [
        nested.call([
          nested_record(type, "novel", string_choice(variant, "last"), "final"),
          nested_record(type, "x", uint64_choice(variant, 999_u64), "final-num"),
        ] of CrystalClick::BinaryValue),
        nested.call([
          nested_record(type, "x", CrystalClick::BinaryValue.variant_null(variant), "tail"),
          nested_record(type, "novel", string_choice(variant, "repeat"), "repeat"),
        ] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
  end

  private def same_value?(left : CrystalClick::BinaryValue, right : CrystalClick::BinaryValue) : Bool
    CrystalClick::BinaryValueCodec.encode(left) == CrystalClick::BinaryValueCodec.encode(right)
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
        require!(value.type == wanted_rows[row].type, "nominal Nested identity differs for #{label}/#{mark}/#{row}")
        require!(same_value?(value, wanted_rows[row]), "literal Nested value differs for #{label}/#{mark}/#{row}")
      end
    end
  end

  private def validate_part_path!(path : String, root : String, generated : Bool) : Nil
    full = File.expand_path(path)
    if generated
      require!(full.starts_with?(root + File::SEPARATOR), "generated part escaped helper output root")
      require!(!File.exists?(full) && !File.symlink?(full), "generated part destination already exists")
      parent = File.dirname(full)
      require!(Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent,
        "generated part parent is absent, noncanonical, or symlinked")
    else
      require!(full.starts_with?(root + File::SEPARATOR), "stock part escaped native capture root")
      require!(Dir.exists?(full) && !File.symlink?(full) && File.realpath(full) == full,
        "stock part is absent, noncanonical, or symlinked")
    end
  end

  private def reader_record(
    part : String,
    type : CrystalClick::BinaryDataType,
    expected : Array(Array(CrystalClick::BinaryValue)),
    profile_name : String,
    origin : String,
  ) : JSON::Any
    reader = CrystalClick::NestedBulkColumnReader.open(part, COLUMN, type)
    rows = expected.sum(&.size)
    expected_profile = profile(profile_name)
    require!(reader.row_count == rows.to_u64 && reader.mark_count == EXPECTED_MARK_ROWS.size,
      "#{origin} row/mark census differs")
    require!(reader.mark_row_counts == EXPECTED_MARK_ROWS, "#{origin} mark grid differs")
    require!(reader.ordinary_profile == expected_profile, "#{origin} String profile differs")
    require!(reader.schema_declaration == type.name, "#{origin} canonical schema differs")

    physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, COLUMN, expected_profile)
    roles = CrystalClick::BinaryBulkTypePlan.new(type, expected_profile).roles
    actual_names = reader.physical_stream_names.sort!
    physical_names = physical.stream_names
    require!(physical_names.keys.sort == roles && actual_names == physical_names.values.sort,
      "#{origin} physical substream roster differs from the admitted plan")

    full = reader.read_marks(0, reader.mark_count)
    compare_marks!(full, expected, "#{origin} full")
    first_empty = reader.read_marks(0, 1)
    compare_marks!(first_empty, expected[0, 1], "#{origin} first empty mark")
    later = reader.read_marks(1, 1)
    compare_marks!(later, expected[1, 1], "#{origin} later populated mark")
    final = reader.read_marks(3, 1)
    compare_marks!(final, expected[3, 1], "#{origin} final populated mark")
    zero = reader.read_marks(4, 0)
    require!(zero.empty?, "#{origin} zero-end window is not empty")

    JSON::Any.new({
      "schema_declaration"    => JSON::Any.new(reader.schema_declaration),
      "row_count"             => JSON::Any.new(reader.row_count.to_i64),
      "mark_count"            => JSON::Any.new(reader.mark_count),
      "mark_row_counts"       => JSON::Any.new(reader.mark_row_counts.map { |count| JSON::Any.new(count.to_i64) }),
      "ordinary_profile"      => JSON::Any.new(profile_name),
      "logical_stream_roles"  => JSON::Any.new(roles.map { |name| JSON::Any.new(name) }),
      "physical_stream_names" => JSON::Any.new(actual_names.map { |name| JSON::Any.new(name) }),
      "windows"               => JSON::Any.new(["full", "first_empty_mark", "later_populated_mark", "final_populated_mark", "zero_end_window"].map { |name| JSON::Any.new(name) }),
    } of String => JSON::Any)
  end

  private def write_library_part!(path : String, type : CrystalClick::BinaryDataType,
                                  expected : Array(Array(CrystalClick::BinaryValue)),
                                  profile_name : String) : Nil
    CrystalClick::WidePartWriter.write_uint64_nested_bulk_part(
      path,
      "pk",
      Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64],
      COLUMN,
      type,
      expected,
      rows_per_mark: 2,
      profile: profile(profile_name),
    )
  end

  private def process_profile(input : JSON::Any, output_root : String, capture_root : String) : JSON::Any
    profile_name = input["profile_id"].as_s
    source_part = input["source_part"].as_s
    library_part = input["library_part"].as_s
    require!(PROFILE_IDS.includes?(profile_name), "profile is outside the exact two-profile roster")
    require!(input["capture_root"].as_s == capture_root, "profile capture root differs from authenticated root")
    validate_part_path!(source_part, capture_root, false)
    validate_part_path!(library_part, output_root, true)

    type = nested_type
    expected = fixture(type)
    write_library_part!(library_part, type, expected, profile_name)
    source = reader_record(source_part, type, expected, profile_name, "stock")
    library = reader_record(library_part, type, expected, profile_name, "library")
    JSON::Any.new({
      "profile_id"        => JSON::Any.new(profile_name),
      "library_part_path" => JSON::Any.new(File.expand_path(library_part)),
      "source"            => source,
      "library"           => library,
    } of String => JSON::Any)
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 2
      raise ArgumentError.new("usage: check_nested_bulk_part_w202.cr INPUT.json OUTPUT_ROOT")
    end
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    unless Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root
      raise ArgumentError.new("W202 output root must be canonical and non-symlinked")
    end
    unless File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR)
      raise ArgumentError.new("W202 helper input must be a plain file below output root")
    end

    input = JSON.parse(File.read(input_path))
    require!(input.as_h.keys.sort == ["capture_root", "format", "profiles"] && input["format"].as_s == FORMAT_INPUT,
      "helper input format differs")
    capture_root = input["capture_root"].as_s
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "capture root is not canonical")
    profiles = input["profiles"].as_a
    require!(profiles.map { |item| item["profile_id"].as_s } == PROFILE_IDS,
      "profile roster/order differs")
    profiles.each do |item|
      require!(item.as_h.keys.sort == ["capture_root", "library_part", "profile_id", "source_part"],
        "profile input keys differ")
    end

    output_profiles = profiles.map { |item| process_profile(item, output_root, capture_root) }
    puts JSON::Any.new({
      "format"      => JSON::Any.new(FORMAT_OUTPUT),
      "profile_ids" => JSON::Any.new(PROFILE_IDS.map { |name| JSON::Any.new(name) }),
      "profiles"    => JSON::Any.new(output_profiles),
    }).to_json
  rescue ex : Exception
    STDERR.puts "W202 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckNestedBulkPartW202.main(ARGV)
