require "../src/crystal_click"
require "json"
require "./support/dynamic_owned_values_w220"

module CheckDynamicBulkPartW203
  extend self

  CASE_IDS      = ["root_dynamic", "array_dynamic", "tuple_dynamic", "nested_dynamic", "dynamic_tuple_dynamic"]
  PROFILE_IDS   = ["single_stream", "with_size_stream"]
  COLUMN        = "payload"
  KEY_NAME      = "pk"
  ROW_COUNT     = 8_u64
  MARK_ROWS     = [2_u64, 2_u64, 2_u64, 2_u64]
  FORMAT_INPUT  = "dynamic_bulk_part_w203_input_v1"
  FORMAT_OUTPUT = "dynamic_bulk_part_w203_helper_v1"

  alias Fixture = NamedTuple(
    type: CrystalClick::BinaryDataType,
    structures: Hash(String, CrystalClick::DynamicStructure),
    granules: Array(Array(CrystalClick::BinaryValue)),
    sites: Array(String),
  )

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W203: #{message}") unless condition
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"
      CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W203 String profile is outside the fixed two-profile roster")
    end
  end

  private def uint64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt64")
  end

  private def string_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("String")
  end

  private def dynamic_value(type : CrystalClick::BinaryDataType, child : CrystalClick::BinaryValue? = nil) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.dynamic(type, child)
  end

  private def u64(value : Int) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.uint64(value.to_u64)
  end

  private def structure(types : Array(CrystalClick::BinaryDataType)) : CrystalClick::DynamicStructure
    CrystalClick::DynamicStructure.new(types)
  end

  private def fixture(case_id : String) : Fixture
    string = string_type
    uint64 = uint64_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    u = ->(value : Int32) { dynamic_value(dynamic, u64(value)) }
    s = ->(value : String) { dynamic_value(dynamic, CrystalClick::BinaryValue.string(value)) }
    n = -> { dynamic_value(dynamic) }

    case case_id
    when "root_dynamic"
      granules = [
        [n.call, n.call] of CrystalClick::BinaryValue,
        [u.call(7), s.call("root-spill-a")] of CrystalClick::BinaryValue,
        [u.call(0), s.call("root-spill-b")] of CrystalClick::BinaryValue,
        [u.call(99), s.call("root-spill-c")] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)
      {type: dynamic, structures: {"root" => structure([uint64] of CrystalClick::BinaryDataType)},
       granules: granules, sites: ["root"] of String}
    when "array_dynamic"
      array = CrystalClick::BinaryDataType.array(dynamic)
      array_value = ->(items : Array(CrystalClick::BinaryValue)) { CrystalClick::BinaryValue.array(array, items) }
      granules = [
        [array_value.call([] of CrystalClick::BinaryValue), array_value.call([] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
        [array_value.call([u.call(7), s.call("array-spill-a")] of CrystalClick::BinaryValue),
         array_value.call([n.call] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
        [array_value.call([u.call(0), u.call(42), s.call("array-spill-b")] of CrystalClick::BinaryValue),
         array_value.call([] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
        [array_value.call([s.call("array-spill-c")] of CrystalClick::BinaryValue),
         array_value.call([u.call(99), n.call] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)
      {type: array, structures: {"root.elements" => structure([uint64] of CrystalClick::BinaryDataType)},
       granules: granules, sites: ["root.elements"] of String}
    when "tuple_dynamic"
      tuple = CrystalClick::BinaryDataType.tuple(
        [dynamic, string] of CrystalClick::BinaryDataType,
        ["d", "text"] of String,
      )
      pair = ->(value : CrystalClick::BinaryValue, text : String) {
        CrystalClick::BinaryValue.tuple(tuple, [value, CrystalClick::BinaryValue.string(text)] of CrystalClick::BinaryValue)
      }
      granules = [
        [pair.call(n.call, "first-null"), pair.call(n.call, "second-null")] of CrystalClick::BinaryValue,
        [pair.call(u.call(7), "ordinary"), pair.call(s.call("tuple-spill-a"), "shared")] of CrystalClick::BinaryValue,
        [pair.call(u.call(0), "zero"), pair.call(n.call, "null-again")] of CrystalClick::BinaryValue,
        [pair.call(s.call("tuple-spill-b"), "novel"), pair.call(u.call(99), "last")] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)
      {type: tuple, structures: {"root.field.0" => structure([uint64] of CrystalClick::BinaryDataType)},
       granules: granules, sites: ["root.field.0"] of String}
    when "nested_dynamic"
      nullable_string = CrystalClick::BinaryDataType.nullable(string)
      low_cardinality = CrystalClick::BinaryDataType.low_cardinality(nullable_string)
      variant = CrystalClick::BinaryDataType.variant([string, uint64] of CrystalClick::BinaryDataType)
      nested = CrystalClick::BinaryDataType.nested(
        [low_cardinality, variant, dynamic, string] of CrystalClick::BinaryDataType,
        ["label", "choice", "d", "text"] of String,
      )
      string_arm = variant.children.index(string).not_nil!
      uint64_arm = variant.children.index(uint64).not_nil!
      choice_string = ->(value : String) { CrystalClick::BinaryValue.variant(variant, string_arm, CrystalClick::BinaryValue.string(value)) }
      choice_uint64 = ->(value : Int32) { CrystalClick::BinaryValue.variant(variant, uint64_arm, u64(value)) }
      choice_null = -> { CrystalClick::BinaryValue.variant_null(variant) }
      record = ->(label : String?, choice : CrystalClick::BinaryValue, payload : CrystalClick::BinaryValue, text_value : String) {
        tuple_type = nested.child_at(0)
        low = tuple_type.child_at(0)
        nullable = low.child_at(0)
        label_value = if value = label
                        CrystalClick::BinaryValue.nullable(nullable, CrystalClick::BinaryValue.string(value))
                      else
                        CrystalClick::BinaryValue.nullable(nullable)
                      end
        CrystalClick::BinaryValue.tuple(
          tuple_type,
          [
            CrystalClick::BinaryValue.low_cardinality(low, label_value),
            choice,
            payload,
            CrystalClick::BinaryValue.string(text_value),
          ] of CrystalClick::BinaryValue,
        )
      }
      empty = -> { CrystalClick::BinaryValue.nested(nested, [] of CrystalClick::BinaryValue) }
      row = ->(items : Array(CrystalClick::BinaryValue)) { CrystalClick::BinaryValue.nested(nested, items) }
      granules = [
        [empty.call, empty.call] of CrystalClick::BinaryValue,
        [
          row.call([
            record.call(nil, choice_string.call("after-empty"), u.call(7), "a"),
            record.call("x", choice_uint64.call(701), s.call("nested-spill-a"), "num-first"),
            record.call("x", choice_null.call, u.call(9), "third"),
          ] of CrystalClick::BinaryValue),
          row.call([record.call("x", choice_string.call("repeat"), u.call(11), "repeat")] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue,
        [
          empty.call,
          row.call([
            record.call("", choice_uint64.call(0), u.call(0), "default-label"),
            record.call(nil, choice_uint64.call(42), s.call("nested-spill-b"), "null-label"),
          ] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue,
        [
          row.call([record.call("novel", choice_string.call("last"), s.call("nested-spill-c"), "final")] of CrystalClick::BinaryValue),
          row.call([
            record.call("x", choice_uint64.call(999), u.call(99), "final-num"),
            record.call("x", choice_null.call, n.call, "tail"),
            record.call("novel", choice_string.call("repeat"), u.call(10), "repeat"),
          ] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)
      {type: nested, structures: {"root.elements.field.2" => structure([uint64] of CrystalClick::BinaryDataType)},
       granules: granules, sites: ["root.elements.field.2"] of String}
    when "dynamic_tuple_dynamic"
      inner_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
      tuple = CrystalClick::BinaryDataType.tuple([inner_dynamic] of CrystalClick::BinaryDataType)
      outer_tuple = ->(child : CrystalClick::BinaryValue?) {
        nested_value = CrystalClick::BinaryValue.dynamic(inner_dynamic, child)
        actual = CrystalClick::BinaryValue.tuple(tuple, [nested_value] of CrystalClick::BinaryValue)
        CrystalClick::BinaryValue.dynamic(dynamic, actual)
      }
      outer_string = ->(value : String) { dynamic_value(dynamic, CrystalClick::BinaryValue.string(value)) }
      granules = [
        [dynamic_value(dynamic), dynamic_value(dynamic)] of CrystalClick::BinaryValue,
        [outer_tuple.call(u64(7)), outer_tuple.call(CrystalClick::BinaryValue.string("inner-spill-a"))] of CrystalClick::BinaryValue,
        [outer_string.call("outer-spill"), outer_tuple.call(nil)] of CrystalClick::BinaryValue,
        [outer_tuple.call(u64(99)), outer_tuple.call(CrystalClick::BinaryValue.string("inner-spill-b"))] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)
      {type: dynamic,
       structures: {
         "root"               => structure([tuple] of CrystalClick::BinaryDataType),
         "root.arm.1.field.0" => structure([uint64] of CrystalClick::BinaryDataType),
       }, granules: granules, sites: ["root", "root.arm.1.field.0"] of String}
    else
      raise ArgumentError.new("W203 fixture id is outside the exact carrier roster")
    end
  end

  private def same_value?(left : CrystalClick::BinaryValue, right : CrystalClick::BinaryValue) : Bool
    left.type == right.type && CrystalClick::BinaryValueCodec.encode(left) == CrystalClick::BinaryValueCodec.encode(right)
  end

  private def owned_signature(value : CrystalClick::BinaryValue) : String
    type = value.type
    return "#{type.name}=NULL" if value.is_null?

    case type.tag
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      "#{type.name}=#{owned_signature(value.child_at(0))}"
    when CrystalClick::BinaryDataType::TAG_ARRAY,
         CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
         CrystalClick::BinaryDataType::TAG_NAMED_TUPLE,
         CrystalClick::BinaryDataType::TAG_NESTED
      "#{type.name}=[#{value.elements.map { |child| owned_signature(child) }.join(",")}]"
    when CrystalClick::BinaryDataType::TAG_NULLABLE,
         CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
      "#{type.name}=#{owned_signature(value.child_at(0))}"
    when CrystalClick::BinaryDataType::TAG_VARIANT
      index = value.variant_index?.not_nil!
      "#{type.name}[#{index}:#{type.child_at(index).name}]=#{owned_signature(value.variant_child?.not_nil!)}"
    when CrystalClick::BinaryDataType::TAG_UINT64
      "#{type.name}=#{value.as_uint64}"
    when CrystalClick::BinaryDataType::TAG_STRING
      "#{type.name}=#{JSON::Any.new(value.as_string).to_json}"
    else
      raise CrystalClick::CorruptPartError.new("W203 owned witness encountered an unrostered value type")
    end
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
        require!(same_value?(value, wanted_rows[row]), "nominal type or independent literal differs for #{label}/#{mark}/#{row}")
      end
    end
  end

  private def validate_part_path!(path : String, root : String, generated : Bool) : Nil
    full = File.expand_path(path)
    require!(full.starts_with?(root + File::SEPARATOR), "part escaped its authenticated root")
    if generated
      require!(!File.exists?(full) && !File.symlink?(full), "generated part destination already exists")
      parent = File.dirname(full)
      require!(Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent,
        "generated part parent is absent, noncanonical, or symlinked")
    else
      require!(Dir.exists?(full) && !File.symlink?(full) && File.realpath(full) == full,
        "stock part is absent, noncanonical, or symlinked")
    end
  end

  private def reader_record(
    part : String,
    fixture : Fixture,
    case_id : String,
    profile_name : String,
    origin : String,
  ) : JSON::Any
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    transport_limits = CrystalClick::CompressedStreamLimits.new
    reader = CrystalClick::DynamicBulkColumnReader.open(part, COLUMN, fixture[:type], limits, transport_limits)
    expected_structures = fixture[:structures]
    # The stock Array(Dynamic) source inserts UInt64 before String but reports
    # String as its ordinary arm and UInt64 in SharedVariant. The library
    # writer intentionally uses the explicit UInt64 roster below; keep both
    # expectations independent and compare each reader against its own roster.
    if origin.starts_with?("stock/") && case_id == "array_dynamic"
      expected_structures = {
        "root.elements" => structure([string_type] of CrystalClick::BinaryDataType),
      }
    end
    plan = CrystalClick::BinaryDynamicBulkPlan.new(fixture[:type], expected_structures, profile(profile_name), limits)
    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, COLUMN, limits)
    expected_names = physical.stream_names.values.sort!
    actual_names = reader.physical_stream_names.sort!
    roles = (plan.data_roles + plan.structure_roles).sort!
    require!(plan.site_paths == fixture[:sites].sort!, "fixture Dynamic-site roster differs for #{origin}")
    require!(reader.schema_declaration == fixture[:type].name, "#{origin} schema declaration differs")
    require!(reader.row_count == ROW_COUNT && reader.mark_count == MARK_ROWS.size,
      "#{origin} row/mark census differs")
    require!(reader.mark_row_counts == MARK_ROWS, "#{origin} parent mark grid differs")
    require!(reader.ordinary_profile == profile(profile_name), "#{origin} String profile differs")
    require!(actual_names == expected_names && actual_names.uniq == actual_names,
      "#{origin} exact physical stream roster differs from the occurrence plan")

    low_level_by_mark = reader.read_marks(0, reader.mark_count)
    compare_marks!(low_level_by_mark, fixture[:granules], "#{origin} full")
    compare_marks!(reader.read_marks(0, 1), fixture[:granules][0, 1], "#{origin} first-empty mark")
    compare_marks!(reader.read_marks(1, 1), fixture[:granules][1, 1], "#{origin} later mark")
    compare_marks!(reader.read_marks(2, 1), fixture[:granules][2, 1], "#{origin} middle mark")
    compare_marks!(reader.read_marks(3, 1), fixture[:granules][3, 1], "#{origin} final mark")
    require!(reader.read_marks(4, 0).empty?, "#{origin} zero-end window is not empty")

    # Keep the stock-authored and library-written sides on the generic typed
    # table route as well as this direct physical-reader witness. These copied
    # slices are compared to the fixture literals after the callback ends.
    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_NAME, COLUMN])
    table_values = Array(Array(CrystalClick::BinaryValue)).new(fixture[:granules].size) do
      [] of CrystalClick::BinaryValue
    end
    candidate_marks = Array(Int32).new(fixture[:granules].size) { |mark| mark.to_i32 }
    table.scan_typed_candidate_marks([candidate_marks]) do |batch|
      mark = batch.mark_index
      require!(batch.part_index == 0 && mark >= 0 && mark < fixture[:granules].size,
        "#{origin} table batch identity is outside the selected part/mark grid")
      expected_offset = (mark * MARK_ROWS.first).to_u64
      require!(batch.mark_row_offset == 0_u64 && batch.part_row_offset == expected_offset &&
               batch.source_row_offset == expected_offset,
        "#{origin} table batch row offsets differ from parent P")
      require!(batch.values_for(KEY_NAME, UInt64).size == fixture[:granules][mark].size,
        "#{origin} table key and Dynamic row counts differ")
      table_values[mark] = batch.dynamic_bulk_values_for(COLUMN).to_a
    end
    compare_marks!(table_values, fixture[:granules], "#{origin} typed-table full candidate schedule")

    eof_callbacks = 0
    table.scan_typed_window(table.total_row_count, 1) { |_batch| eof_callbacks += 1 }
    require!(eof_callbacks == 0, "#{origin} typed-table EOF window exposed a callback")

    record = {
      "schema_declaration"    => JSON::Any.new(reader.schema_declaration),
      "row_count"             => JSON::Any.new(reader.row_count.to_i64),
      "mark_count"            => JSON::Any.new(reader.mark_count),
      "mark_row_counts"       => JSON::Any.new(reader.mark_row_counts.map { |count| JSON::Any.new(count.to_i64) }),
      "ordinary_profile"      => JSON::Any.new(profile_name),
      "dynamic_site_paths"    => JSON::Any.new(fixture[:sites].sort!.map { |name| JSON::Any.new(name) }),
      "logical_stream_roles"  => JSON::Any.new(roles.map { |name| JSON::Any.new(name) }),
      "physical_stream_names" => JSON::Any.new(actual_names.map { |name| JSON::Any.new(name) }),
      "windows"               => JSON::Any.new(["full", "first_empty_mark", "mark_1", "mark_2", "final_mark", "zero_end_window"].map { |name| JSON::Any.new(name) }),
    } of String => JSON::Any
    if origin.starts_with?("stock/")
      observation = CrystalClick::DynamicOwnedValuesW220.materialize(
        part,
        COLUMN,
        fixture[:type],
        ROW_COUNT,
        MARK_ROWS,
        fixture[:granules],
        low_level_by_mark,
      )
      record["owned_values"] = CrystalClick::DynamicOwnedValuesW220.to_json(observation) do |value|
        owned_signature(value)
      end
    end
    JSON::Any.new(record)
  end

  private def write_library_part!(
    path : String,
    fixture : Fixture,
    profile_name : String,
  ) : Nil
    result = CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
      path,
      KEY_NAME,
      Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64],
      COLUMN,
      fixture[:type],
      fixture[:structures],
      fixture[:granules],
      rows_per_mark: 2,
      profile: profile(profile_name),
      frame_bytes: 4096,
      metadata_version: 0_i64,
      limits: CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits: CrystalClick::CompressedStreamLimits.new,
    )
    require!(result == path, "writer returned a different destination")
  end

  private def process_case(input : JSON::Any, output_root : String, capture_root : String) : JSON::Any
    case_id = input["case_id"].as_s
    profile_name = input["profile_id"].as_s
    source_part = input["source_part"].as_s
    library_part = input["library_part"].as_s
    require!(CASE_IDS.includes?(case_id), "input case is outside the fixed carrier roster")
    require!(PROFILE_IDS.includes?(profile_name), "input profile is outside the fixed String roster")
    require!(input["capture_root"].as_s == capture_root, "case capture root differs from authenticated root")
    validate_part_path!(source_part, capture_root, false)
    validate_part_path!(library_part, output_root, true)

    fixed = fixture(case_id)
    write_library_part!(library_part, fixed, profile_name)
    source = reader_record(source_part, fixed, case_id, profile_name, "stock/#{case_id}/#{profile_name}")
    library = reader_record(library_part, fixed, case_id, profile_name, "library/#{case_id}/#{profile_name}")
    JSON::Any.new({
      "case_id"           => JSON::Any.new(case_id),
      "profile_id"        => JSON::Any.new(profile_name),
      "library_part_path" => JSON::Any.new(File.expand_path(library_part)),
      "source"            => source,
      "library"           => library,
    } of String => JSON::Any)
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 2
      raise ArgumentError.new("usage: check_dynamic_bulk_part_w203.cr INPUT.json OUTPUT_ROOT")
    end
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    unless Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root
      raise ArgumentError.new("W203 output root must be canonical and non-symlinked")
    end
    unless File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR)
      raise ArgumentError.new("W203 helper input must be a plain file below output root")
    end

    input = JSON.parse(File.read(input_path))
    expected_cases = CASE_IDS.flat_map { |case_id| PROFILE_IDS.map { |profile_id| "#{case_id}/#{profile_id}" } }
    require!(input.as_h.keys.sort == ["capture_root", "cases", "format"] && input["format"].as_s == FORMAT_INPUT,
      "helper input format differs")
    capture_root = input["capture_root"].as_s
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "capture root is not canonical")
    cases = input["cases"].as_a
    observed_cases = cases.map { |item| "#{item["case_id"].as_s}/#{item["profile_id"].as_s}" }
    require!(observed_cases == expected_cases, "case/profile roster or order differs")
    cases.each do |item|
      require!(item.as_h.keys.sort == ["capture_root", "case_id", "library_part", "profile_id", "source_part"],
        "case input keys differ")
    end

    results = cases.map { |item| process_case(item, output_root, capture_root) }
    puts JSON::Any.new({
      "format"      => JSON::Any.new(FORMAT_OUTPUT),
      "case_ids"    => JSON::Any.new(CASE_IDS.map { |name| JSON::Any.new(name) }),
      "profile_ids" => JSON::Any.new(PROFILE_IDS.map { |name| JSON::Any.new(name) }),
      "cases"       => JSON::Any.new(results),
    }).to_json
  rescue ex : Exception
    STDERR.puts "W203 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckDynamicBulkPartW203.main(ARGV)
