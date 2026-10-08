require "../src/crystal_click"
require "json"
require "./support/dynamic_owned_values_w220"

module CheckDynamicJSONPhysicalW210
  extend self

  COLUMN        = "payload"
  KEY_NAME      = "pk"
  CASE_IDS      = ["root_dynamic", "array_dynamic"]
  PROFILE_IDS   = ["single_stream", "with_size_stream"]
  FORMAT_INPUT  = "dynamic_json_physical_w210_input_v1"
  FORMAT_OUTPUT = "dynamic_json_physical_w210_helper_v1"
  PARENT_ROWS   = [2_u64, 2_u64, 2_u64]
  CHILD_ROWS    = [2_u64, 2_u64, 2_u64, 0_u64]

  alias Fixture = NamedTuple(
    case_id: String,
    type: CrystalClick::BinaryDataType,
    structures: Hash(String, CrystalClick::DynamicStructure),
    granules: Array(Array(CrystalClick::BinaryValue)),
    plans: Array(Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)),
    sites: Array(String),
    json_used: CrystalClick::BinaryDataType,
    json_unused: CrystalClick::BinaryDataType,
  )

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W210 helper: #{message}") unless condition
  end

  private def with_phase(case_id : String, profile_name : String, phase : String, &block : -> T) : T forall T
    yield
  rescue ex : Exception
    raise "W210 helper case=#{case_id} profile=#{profile_name} phase=#{phase}: #{ex.class}: #{ex.message}"
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"
      CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W210 profile is outside the fixed roster")
    end
  end

  private def u8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  private def i64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("Int64")
  end

  private def json_type(max_dynamic_types : Int32) : CrystalClick::BinaryDataType
    uint8 = u8_type
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: max_dynamic_types,
      typed_paths: {
        "id"    => uint8,
        "maybe" => CrystalClick::BinaryDataType.nullable(uint8),
      } of String => CrystalClick::BinaryDataType,
    )
  end

  private def json_plan(type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["counter"] of String),
      {"counter" => CrystalClick::DynamicStructure.new([i64_type] of CrystalClick::BinaryDataType)},
    )
    CrystalClick::ObjectDocumentPlan.new(structures, type.json_type.not_nil!.typed_paths)
  end

  private def json_value(type : CrystalClick::BinaryDataType, id : UInt8, counter : Int64) : CrystalClick::BinaryValue
    uint8 = u8_type
    nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
    row = CrystalClick::BinaryJsonRow.new(
      type,
      [
        {"id", CrystalClick::BinaryValue.fixed(uint8, Bytes[id])},
        {"maybe", CrystalClick::BinaryValue.null(nullable_uint8)},
        {"counter", CrystalClick::BinaryValue.int64(counter)},
      ] of Tuple(String, CrystalClick::BinaryValue),
    )
    CrystalClick::BinaryValue.json(type, row)
  end

  private def dynamic(type : CrystalClick::BinaryDataType, child : CrystalClick::BinaryValue) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.dynamic(type, child)
  end

  private def fixture(case_id : String) : Fixture
    uint8 = u8_type
    dynamic = CrystalClick::BinaryDataType.dynamic(3)
    array = CrystalClick::BinaryDataType.array(dynamic)
    used = json_type(1)
    unused = json_type(2)
    structure = CrystalClick::DynamicStructure.new([used, unused, uint8] of CrystalClick::BinaryDataType)
    site = case case_id
           when "root_dynamic"  then "root"
           when "array_dynamic" then "root.elements"
           else                      raise ArgumentError.new("W210 case is outside the fixed roster")
           end
    plans = [
      {site, structure.canonical_index_for(used), json_plan(used)},
      {site, structure.canonical_index_for(unused), json_plan(unused)},
    ] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)
    uint = ->(value : UInt8) { dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[value])) }
    json = ->(id : UInt8, counter : Int64) { dynamic(dynamic, json_value(used, id, counter)) }

    if case_id == "root_dynamic"
      granules = [
        [uint.call(17_u8), uint.call(18_u8)] of CrystalClick::BinaryValue,
        [uint.call(19_u8), uint.call(20_u8)] of CrystalClick::BinaryValue,
        [json.call(41_u8, 401_i64), json.call(42_u8, 402_i64)] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)
      {case_id: case_id, type: dynamic, structures: {site => structure}, granules: granules,
       plans: plans, sites: [site] of String, json_used: used, json_unused: unused}
    else
      empty = CrystalClick::BinaryValue.array(array, [] of CrystalClick::BinaryValue)
      three = CrystalClick::BinaryValue.array(array, [uint.call(17_u8), uint.call(18_u8)] of CrystalClick::BinaryValue)
      one = CrystalClick::BinaryValue.array(array, [uint.call(19_u8)] of CrystalClick::BinaryValue)
      first_json = CrystalClick::BinaryValue.array(array, [json.call(41_u8, 401_i64)] of CrystalClick::BinaryValue)
      second_json = CrystalClick::BinaryValue.array(array, [json.call(42_u8, 402_i64)] of CrystalClick::BinaryValue)
      granules = [
        [empty, empty] of CrystalClick::BinaryValue,
        [three, one] of CrystalClick::BinaryValue,
        [first_json, second_json] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)
      {case_id: case_id, type: array, structures: {site => structure}, granules: granules,
       plans: plans, sites: [site] of String, json_used: used, json_unused: unused}
    end
  end

  private def actual_signature(value : CrystalClick::BinaryValue) : String
    require!(!value.is_null?, "unexpected NULL Dynamic value in the fixed fixture")
    actual = value.child_at(0)
    if actual.type.tag == CrystalClick::BinaryDataType::TAG_JSON
      row = actual.json_row
      require!(row.path_count == 3, "JSON actual path count differs")
      id = row.value_for("id").not_nil!.byte_at(0)
      maybe = row.value_for("maybe").not_nil!
      require!(maybe.is_null?, "typed Nullable(UInt8) JSON path differs")
      counter = row.value_for("counter").not_nil!
      require!(counter.type == i64_type, "dynamic Object path is not Int64")
      "json:#{id}:null:counter=#{counter.as_int64}"
    else
      require!(actual.type == u8_type, "ordinary Dynamic fixture arm is not UInt8")
      "u8:#{actual.byte_at(0)}"
    end
  end

  private def row_signature(value : CrystalClick::BinaryValue, case_id : String) : String
    if case_id == "array_dynamic"
      "[#{value.elements.map { |item| actual_signature(item) }.join(",")}]"
    else
      actual_signature(value)
    end
  end

  private def expected_rows(case_id : String) : Array(Array(String))
    if case_id == "root_dynamic"
      [
        ["u8:17", "u8:18"] of String,
        ["u8:19", "u8:20"] of String,
        ["json:41:null:counter=401", "json:42:null:counter=402"] of String,
      ] of Array(String)
    else
      [
        ["[]", "[]"] of String,
        ["[u8:17,u8:18]", "[u8:19]"] of String,
        ["[json:41:null:counter=401]", "[json:42:null:counter=402]"] of String,
      ] of Array(String)
    end
  end

  private def validate_path!(path : String, root : String, generated : Bool) : Nil
    full = File.expand_path(path)
    require!(full.starts_with?(root + File::SEPARATOR), "part path escaped its authenticated root")
    if generated
      require!(!File.exists?(full) && !File.symlink?(full), "generated destination already exists")
      parent = File.dirname(full)
      require!(Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent,
        "generated parent is absent, symlinked or noncanonical")
    else
      require!(Dir.exists?(full) && !File.symlink?(full) && File.realpath(full) == full,
        "stock source part is absent, symlinked or noncanonical")
    end
  end

  private def rows_by_mark(reader : CrystalClick::DynamicBulkColumnReader, case_id : String, origin : String) : Array(Array(String))
    marks = reader.read_marks(0, reader.mark_count)
    observed = marks.map do |mark|
      mark.map { |value| row_signature(value, case_id) }
    end
    require!(observed == expected_rows(case_id), "#{origin} values differ from independent row/mark literals")
    require!(reader.read_marks(reader.mark_count, 0).empty?, "#{origin} EOF-zero selection is not empty")
    observed
  end

  private def check_mark_file!(part : String, stream_name : String) : Nil
    path = File.join(part, "#{CrystalClick::StreamName.hash(stream_name)}.mrk2")
    mark_bytes = File.read(path)
    bytes = mark_bytes.to_slice
    unless bytes.size % CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE == 0
      raise CrystalClick::CorruptPartError.new("W210 Object child marks contain an incomplete record")
    end
    count = bytes.size // CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE
    rows = Array(UInt64).new(count) do |record|
      offset = record * CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE + 16
      value = 0_u64
      8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
      value
    end
    require!(rows == CHILD_ROWS, "Object child mark file does not use physical parent rows P")
  end

  private def reader_record(
    part : String,
    fixed : Fixture,
    profile_name : String,
    origin : String,
    validate_child_grid : Bool,
  ) : JSON::Any
    reader = CrystalClick::DynamicBulkColumnReader.open(
      part, COLUMN, fixed[:type], CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      CrystalClick::CompressedStreamLimits.new,
    )
    require!(reader.schema_declaration == fixed[:type].name, "#{origin} nominal schema differs")
    require!(reader.row_count == 6_u64 && reader.mark_count == 3, "#{origin} parent row/mark census differs")
    require!(reader.mark_row_counts == PARENT_ROWS, "#{origin} physical parent mark grid P differs")
    require!(reader.ordinary_profile == profile(profile_name), "#{origin} Dynamic profile differs")
    marks = rows_by_mark(reader, fixed[:case_id], origin)
    low_level_by_mark = reader.read_marks(0, reader.mark_count)
    require!(reader.read_marks(0, 1).map { |mark| mark.map { |v| row_signature(v, fixed[:case_id]) } } == marks[0, 1],
      "#{origin} first mark selection differs")
    require!(reader.read_marks(1, 1).map { |mark| mark.map { |v| row_signature(v, fixed[:case_id]) } } == marks[1, 1],
      "#{origin} middle mark selection differs")
    require!(reader.read_marks(2, 1).map { |mark| mark.map { |v| row_signature(v, fixed[:case_id]) } } == marks[2, 1],
      "#{origin} final mark selection differs")

    # Exercise the generic typed table route on both stock-authored and
    # library-written direct Dynamic(JSON) parts without changing this helper's
    # fixed JSON output roster.
    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_NAME, COLUMN])
    table_values = Array(Array(CrystalClick::BinaryValue)).new(fixed[:granules].size) do
      [] of CrystalClick::BinaryValue
    end
    candidate_marks = Array(Int32).new(fixed[:granules].size) { |mark| mark.to_i32 }
    table.scan_typed_candidate_marks([candidate_marks]) do |batch|
      mark = batch.mark_index
      require!(batch.part_index == 0 && mark >= 0 && mark < fixed[:granules].size,
        "#{origin} table batch identity is outside the selected part/mark grid")
      expected_offset = (mark * PARENT_ROWS.first).to_u64
      require!(batch.mark_row_offset == 0_u64 && batch.part_row_offset == expected_offset &&
               batch.source_row_offset == expected_offset,
        "#{origin} table candidate offsets differ from parent P")
      require!(batch.values_for(KEY_NAME, UInt64).size == fixed[:granules][mark].size,
        "#{origin} table key and Dynamic row counts differ")
      table_values[mark] = batch.dynamic_bulk_values_for(COLUMN).to_a
    end
    table_values.each_with_index do |rows, mark|
      wanted = fixed[:granules][mark]
      require!(rows.size == wanted.size, "#{origin} table candidate row count differs at mark #{mark}")
      rows.each_with_index do |value, row|
        require!(CrystalClick::BinaryValueCodec.encode(value) == CrystalClick::BinaryValueCodec.encode(wanted[row]),
          "#{origin} table candidate literal differs at #{mark}/#{row}")
      end
    end

    window_values = [] of CrystalClick::BinaryValue
    table.scan_typed_window(1_u64, 3) do |batch|
      mark = batch.mark_index
      mark_start = (mark * PARENT_ROWS.first).to_u64
      expected_mark_offset = if mark == 0
                               1_u64
                             else
                               0_u64
                             end
      expected_row_offset = mark_start + expected_mark_offset
      require!(batch.mark_row_offset == expected_mark_offset && batch.part_row_offset == expected_row_offset &&
               batch.source_row_offset == expected_row_offset,
        "#{origin} table middle-window offsets differ from parent P")
      window_values.concat(batch.dynamic_bulk_values_for(COLUMN).to_a)
    end
    expected_window = fixed[:granules].flatten[1, 3]
    require!(window_values.size == expected_window.size, "#{origin} table middle-window row count differs")
    window_values.each_with_index do |value, index|
      require!(CrystalClick::BinaryValueCodec.encode(value) == CrystalClick::BinaryValueCodec.encode(expected_window[index]),
        "#{origin} table middle-window literal differs at row #{index}")
    end

    eof_callbacks = 0
    table.scan_typed_window(table.total_row_count, 1) { |_batch| eof_callbacks += 1 }
    require!(eof_callbacks == 0, "#{origin} table EOF window exposed a callback")

    physical_names = reader.physical_stream_names.sort!
    require!(physical_names.uniq == physical_names && !physical_names.empty?, "#{origin} stream roster is empty or duplicated")
    checksum_names = reader.selected_checksum_names.sort!
    require!(checksum_names.uniq == checksum_names, "#{origin} checksum roster contains duplicates")
    checksums = CrystalClick::PartChecksums.open(part)
    checksum_names.each { |name| require!(checksums.entries.has_key?(name), "#{origin} checksum is absent: #{name}") }

    child_names = [] of String
    expected_child_types = [] of String
    if origin == "library"
      codec_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
      plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
        fixed[:type], fixed[:structures], codec_budget, profile(profile_name),
        json_object_plans: fixed[:plans],
      )
      physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, COLUMN, CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
      require!(reader.physical_stream_names.sort == physical.stream_names.values.sort,
        "library composite physical stream roster differs from the fixed bound child plan")
      physical.json_object_sites.each do |site|
        expected_child_types << site.binding.json_type.name
        site.physical_plan.stream_names.each do |name|
          child_names << name
          check_mark_file!(part, name) if validate_child_grid
          base = CrystalClick::StreamName.hash(name)
          {"#{base}.bin", "#{base}.mrk2"}.each do |file_name|
            require!(checksum_names.includes?(file_name), "library Object child file is absent from checksum roster")
          end
        end
      end
      require!(expected_child_types.sort == [fixed[:json_used].name, fixed[:json_unused].name].sort,
        "library bound JSON actual-arm roster differs")
    else
      # Native parts may omit the deliberately unused actual arm. Still record
      # each selected JSON Object lane and verify its .mrk2 uses P, not Q/R.
      escaped = CrystalClick::PhysicalStreamName.escape(fixed[:json_used].name)
      child_names = physical_names.select { |name| name.includes?(escaped) }
      child_names.each { |name| check_mark_file!(part, name) } if validate_child_grid
    end

    record = {
      "case_id"                   => JSON::Any.new(fixed[:case_id]),
      "profile_id"                => JSON::Any.new(profile_name),
      "schema_declaration"        => JSON::Any.new(reader.schema_declaration),
      "row_count"                 => JSON::Any.new(reader.row_count.to_i64),
      "mark_count"                => JSON::Any.new(reader.mark_count),
      "mark_row_counts"           => JSON::Any.new(reader.mark_row_counts.map { |count| JSON::Any.new(count.to_i64) }),
      "rows_by_mark"              => JSON::Any.new(marks.map { |mark| JSON::Any.new(mark.map { |row| JSON::Any.new(row) }) }),
      "physical_stream_names"     => JSON::Any.new(physical_names.map { |name| JSON::Any.new(name) }),
      "selected_checksum_names"   => JSON::Any.new(checksum_names.map { |name| JSON::Any.new(name) }),
      "object_child_stream_names" => JSON::Any.new(child_names.sort!.map { |name| JSON::Any.new(name) }),
      "bound_json_type_names"     => JSON::Any.new(expected_child_types.sort!.map { |name| JSON::Any.new(name) }),
      "windows"                   => JSON::Any.new(["full", "first_empty_or_first", "middle", "final", "eof_zero"].map { |name| JSON::Any.new(name) }),
    } of String => JSON::Any
    if origin == "source"
      observation = CrystalClick::DynamicOwnedValuesW220.materialize(
        part,
        COLUMN,
        fixed[:type],
        reader.row_count,
        reader.mark_row_counts,
        fixed[:granules],
        low_level_by_mark,
      )
      record["owned_values"] = CrystalClick::DynamicOwnedValuesW220.to_json(observation) do |value|
        row_signature(value, fixed[:case_id])
      end
    end
    JSON::Any.new(record)
  end

  private def write_library_part!(path : String, fixed : Fixture, profile_name : String) : Nil
    result = CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
      path,
      KEY_NAME,
      Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
      COLUMN,
      fixed[:type],
      fixed[:structures],
      fixed[:granules],
      rows_per_mark: 2,
      profile: profile(profile_name),
      frame_bytes: 4096,
      metadata_version: 0_i64,
      limits: CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits: CrystalClick::CompressedStreamLimits.new,
      json_object_plans: fixed[:plans],
    )
    require!(result == path, "writer returned a different part path")
  end

  private def process_case(item : JSON::Any, capture_root : String, output_root : String) : JSON::Any
    case_id = item["case_id"].as_s
    profile_name = item["profile_id"].as_s
    require!(CASE_IDS.includes?(case_id) && PROFILE_IDS.includes?(profile_name), "input case/profile is outside fixed roster")
    require!(item["capture_root"].as_s == capture_root, "case capture root differs")
    source_part = item["source_part"].as_s
    library_part = item["library_part"].as_s
    validate_path!(source_part, capture_root, false)
    validate_path!(library_part, output_root, true)

    fixed = fixture(case_id)
    with_phase(case_id, profile_name, "write") do
      write_library_part!(library_part, fixed, profile_name)
    end
    source = with_phase(case_id, profile_name, "source-read") do
      reader_record(source_part, fixed, profile_name, "source", false)
    end
    library = with_phase(case_id, profile_name, "library-read") do
      reader_record(library_part, fixed, profile_name, "library", true)
    end
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
      raise ArgumentError.new("usage: check_dynamic_json_physical_w210.cr INPUT.json OUTPUT_ROOT")
    end
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    unless Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root
      raise ArgumentError.new("W210 output root must be canonical and non-symlinked")
    end
    unless File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR)
      raise ArgumentError.new("W210 helper input must be a plain file below output root")
    end
    input = JSON.parse(File.read(input_path))
    require!(input.as_h.keys.sort == ["capture_root", "cases", "format"] && input["format"].as_s == FORMAT_INPUT,
      "helper input format differs")
    capture_root = input["capture_root"].as_s
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "capture root is not canonical")
    cases = input["cases"].as_a
    expected = CASE_IDS.flat_map { |case_id| PROFILE_IDS.map { |profile_name| "#{case_id}/#{profile_name}" } }
    observed = cases.map { |item| "#{item["case_id"].as_s}/#{item["profile_id"].as_s}" }
    require!(observed == expected, "case/profile order differs from the fixed roster")
    cases.each do |item|
      require!(item.as_h.keys.sort == ["capture_root", "case_id", "library_part", "profile_id", "source_part"],
        "case input keys differ")
    end
    results = cases.map { |item| process_case(item, capture_root, output_root) }
    puts JSON::Any.new({
      "format"                 => JSON::Any.new(FORMAT_OUTPUT),
      "case_ids"               => JSON::Any.new(CASE_IDS.map { |name| JSON::Any.new(name) }),
      "profile_ids"            => JSON::Any.new(PROFILE_IDS.map { |name| JSON::Any.new(name) }),
      "parent_mark_rows"       => JSON::Any.new(PARENT_ROWS.map { |rows| JSON::Any.new(rows.to_i64) }),
      "object_child_mark_rows" => JSON::Any.new(CHILD_ROWS.map { |rows| JSON::Any.new(rows.to_i64) }),
      "cases"                  => JSON::Any.new(results),
    }).to_json
  rescue ex : Exception
    STDERR.puts "W210 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckDynamicJSONPhysicalW210.main(ARGV)
