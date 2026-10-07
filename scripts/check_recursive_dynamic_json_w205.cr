require "../src/crystal_click"
require "json"

module CheckRecursiveDynamicJSONW205
  extend self

  JSON_TYPE = "JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)"
  DYNAMIC_TYPE = "Dynamic(max_types=1)"
  CASE_ID = "whole_zero_q_array_tuple"
  PROFILE_IDS = ["single_stream", "with_size_stream"]
  COLUMN = "payload"
  KEY = "pk"
  ROWS_PER_MARK = 2
  ROW_COUNT = 8_u64
  MARK_ROWS = [2_u64, 2_u64, 2_u64, 2_u64]
  FORMAT_INPUT = "recursive_dynamic_json_w205_input_v1"
  FORMAT_OUTPUT = "recursive_dynamic_json_w205_helper_v1"
  SCHEMA_DECLARATION = "Array(Tuple(doc #{JSON_TYPE}, d #{DYNAMIC_TYPE}))"
  DYNAMIC_SITE_KEY = "root/array[0]/tuple[1]"

  alias Fixture = NamedTuple(
    schema: CrystalClick::StorageColumnSchema,
    granules: Array(Array(CrystalClick::StorageColumnValue)),
    object_plans: Hash(String, CrystalClick::ObjectDocumentPlan),
    dynamic_plans: Hash(String, CrystalClick::BinaryDynamicBulkPlan),
  )

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W205 helper: #{message}") unless condition
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"
      CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W205 profile is outside the fixed String profile roster")
    end
  end

  private def fixture(profile_name : String) : Fixture
    object_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(JSON_TYPE)
    schema = CrystalClick::StorageColumnSchema.parse(SCHEMA_DECLARATION)
    object_plan = CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new([] of String),
        {} of String => CrystalClick::DynamicStructure,
      ),
      object_schema.typed_paths,
    )
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    uint64_type = CrystalClick::BinaryDataType.primitive("UInt64")
    dynamic_plan = CrystalClick::BinaryDynamicBulkPlan.new(
      dynamic_type,
      {"root" => CrystalClick::DynamicStructure.new([uint64_type] of CrystalClick::BinaryDataType)},
      profile(profile_name),
    )
    empty_array = CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue)
    granules = Array(Array(CrystalClick::StorageColumnValue)).new(4) do
      [empty_array, empty_array] of CrystalClick::StorageColumnValue
    end
    {
      schema: schema,
      granules: granules,
      object_plans: {"root/array[0]/tuple[0]" => object_plan},
      dynamic_plans: {DYNAMIC_SITE_KEY => dynamic_plan},
    }
  end

  private def require_empty_array_rows!(schema : CrystalClick::StorageColumnSchema, marks : Array(Array(CrystalClick::StorageColumnValue)), expected_mark_rows : Array(UInt64), label : String) : Nil
    require!(schema.array?, "fixture root must remain Array")
    require!(marks.size == expected_mark_rows.size, "#{label} parent mark count differs")
    marks.each_with_index do |rows, mark|
      require!(rows.size.to_u64 == expected_mark_rows[mark], "#{label} P rows differ at mark #{mark}")
      rows.each_with_index do |value, row|
        require!(value.array?, "#{label} root value kind differs at #{mark}/#{row}")
        require!(value.array_values.empty?, "#{label} child occurrence Q is nonzero at #{mark}/#{row}")
      end
    end
  end

  private def marked_signatures(marks : Array(Array(CrystalClick::StorageColumnValue)), first_key : UInt64) : Array(Array(JSON::Any))
    next_key = first_key
    marks.map do |mark|
      mark.map do |value|
        require!(value.array_values.empty?, "signature renderer received a nonempty child array")
        signature = JSON::Any.new([JSON::Any.new(next_key.to_s), JSON::Any.new([] of JSON::Any)] of JSON::Any)
        next_key += 1_u64
        signature
      end
    end
  end

  private def table_signatures(table : CrystalClick::WidePartTable) : Array(JSON::Any)
    rows = [] of JSON::Any
    table.scan_typed(batch_rows: ROWS_PER_MARK) do |batch|
      keys = batch.values_for(KEY)
      values = batch.recursive_values_for(COLUMN)
      require!(keys.size == values.size, "table key/value batch widths differ")
      keys.size.times do |index|
        require!(values[index].array_values.empty?, "typed table callback returned a nonempty child array")
        rows << JSON::Any.new([JSON::Any.new(keys[index].to_s), JSON::Any.new([] of JSON::Any)] of JSON::Any)
      end
      nil
    end
    rows
  end

  private def observed_occurrences(mark : Array(CrystalClick::StorageColumnValue)) : NamedTuple(object: UInt64, dynamic: UInt64)
    object_count = 0_u64
    dynamic_count = 0_u64
    mark.each do |root_value|
      require!(root_value.array?, "occurrence counter received a non-Array root value")
      root_value.array_values.each do |tuple_value|
        require!(tuple_value.tuple? && tuple_value.child_count == 2, "occurrence counter received a malformed Tuple element")
        require!(tuple_value.child_at(0).object?, "occurrence counter received a non-JSON first Tuple element")
        require!(tuple_value.child_at(1).bulk?, "occurrence counter received a non-Dynamic second Tuple element")
        object_count += 1_u64
        dynamic_count += 1_u64
      end
    end
    {object: object_count, dynamic: dynamic_count}
  end

  private def reader_record(part : String, fixed : Fixture, label : String) : Hash(String, JSON::Any)
    reader = CrystalClick::RecursiveStorageColumnReader.open(part, COLUMN, fixed[:schema])
    full = reader.read_marks(0, reader.mark_count)
    first = reader.read_marks(0, 1)
    later = reader.read_marks(1, 1)
    middle = reader.read_marks(2, 1)
    final = reader.read_marks(3, 1)
    end_zero = reader.read_marks(reader.mark_count, 0)
    require_empty_array_rows!(fixed[:schema], full, MARK_ROWS, "#{label}/full")
    require_empty_array_rows!(fixed[:schema], first, [2_u64], "#{label}/first")
    require_empty_array_rows!(fixed[:schema], later, [2_u64], "#{label}/later")
    require_empty_array_rows!(fixed[:schema], middle, [2_u64], "#{label}/middle")
    require_empty_array_rows!(fixed[:schema], final, [2_u64], "#{label}/final")
    require!(end_zero.empty?, "#{label} end-zero mark selection is not empty")
    require!(reader.schema_declaration == SCHEMA_DECLARATION, "#{label} nominal declaration differs")
    require!(reader.source_declaration == SCHEMA_DECLARATION, "#{label} persisted declaration differs")
    require!(reader.row_count == ROW_COUNT && reader.mark_count == 4, "#{label} parent P grid differs")
    require!(reader.mark_row_counts == MARK_ROWS, "#{label} parent mark row counts differ")
    occurrence_grids = full.map { |mark| observed_occurrences(mark) }
    dynamic_site_path = "#{DYNAMIC_SITE_KEY}::root"
    dynamic_site_grids = occurrence_grids.map do |counts|
      {dynamic_site_path => counts[:dynamic]}
    end
    {
      "schema_declaration" => JSON::Any.new(reader.schema_declaration),
      "source_declaration" => JSON::Any.new(reader.source_declaration),
      "row_count" => JSON::Any.new(reader.row_count.to_i64),
      "mark_row_counts" => JSON::Any.new(reader.mark_row_counts.map { |count| JSON::Any.new(count.to_i64) }),
      "dynamic_site_keys" => JSON::Any.new([JSON::Any.new(DYNAMIC_SITE_KEY)]),
      "physical_stream_names" => JSON::Any.new(reader.physical_stream_names.map { |name| JSON::Any.new(name) }),
      "selected_checksum_names" => JSON::Any.new(reader.selected_checksum_names.map { |name| JSON::Any.new(name) }),
      "occurrence_counts_by_parent_mark" => JSON::Any.new(occurrence_grids.map do |grid|
        JSON::Any.new({"object" => JSON::Any.new(grid[:object].to_i64), "dynamic" => JSON::Any.new(grid[:dynamic].to_i64)} of String => JSON::Any)
      end),
      "dynamic_site_occurrences_by_parent_mark" => JSON::Any.new(dynamic_site_grids.map do |grid|
        JSON::Any.new(grid.to_h { |name, count| {name, JSON::Any.new(count.to_i64)} })
      end),
      "windows" => JSON::Any.new({
        "full" => JSON::Any.new(marked_signatures(full, 1_u64).map { |mark| JSON::Any.new(mark) }),
        "first" => JSON::Any.new(marked_signatures(first, 1_u64).map { |mark| JSON::Any.new(mark) }),
        "later" => JSON::Any.new(marked_signatures(later, 3_u64).map { |mark| JSON::Any.new(mark) }),
        "middle" => JSON::Any.new(marked_signatures(middle, 5_u64).map { |mark| JSON::Any.new(mark) }),
        "final" => JSON::Any.new(marked_signatures(final, 7_u64).map { |mark| JSON::Any.new(mark) }),
        "end_zero" => JSON::Any.new([] of JSON::Any),
      } of String => JSON::Any),
    } of String => JSON::Any
  end

  private def write_library_part(path : String, fixed : Fixture, profile_name : String) : Nil
    keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
    result = CrystalClick::WidePartWriter.write_uint64_recursive_pair(
      path,
      KEY,
      keys,
      COLUMN,
      fixed[:schema],
      fixed[:object_plans],
      fixed[:granules],
      rows_per_mark: ROWS_PER_MARK,
      mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      profile: profile(profile_name),
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: 4096,
      dynamic_plans: fixed[:dynamic_plans],
    )
    require!(result == path, "writer returned a different destination")
  end

  private def checked_part(path : String, root : String, absent : Bool) : String
    full = File.expand_path(path)
    root_full = File.realpath(root)
    require!(full.starts_with?(root_full + File::SEPARATOR), "part escaped its authenticated root")
    if absent
      require!(!File.exists?(full), "generated library part already exists")
    else
      require!(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full, "stock source part is absent or noncanonical")
    end
    full
  end

  private def process_profile(item : JSON::Any, output_root : String, capture_root : String) : JSON::Any
    profile_id = item["profile_id"].as_s
    raise ArgumentError.new("W205 profile is outside the fixed roster") unless PROFILE_IDS.includes?(profile_id)
    require!(item["case_id"].as_s == CASE_ID, "input case differs")
    require!(item["capture_root"].as_s == capture_root, "input capture root differs")
    source_part = checked_part(item["source_part"].as_s, capture_root, false)
    library_part = checked_part(item["library_part"].as_s, output_root, true)
    fixed = fixture(profile_id)
    write_library_part(library_part, fixed, profile_id)
    stock_reader = reader_record(source_part, fixed, "stock/#{profile_id}")
    library_reader = reader_record(library_part, fixed, "library/#{profile_id}")
    stock_table = CrystalClick::WidePartTable.open_selected_typed([source_part], [KEY, COLUMN])
    library_table = CrystalClick::WidePartTable.open_selected_typed([library_part], [KEY, COLUMN])
    expected_rows = (1_u64..ROW_COUNT).map do |key|
      JSON::Any.new([JSON::Any.new(key.to_s), JSON::Any.new([] of JSON::Any)] of JSON::Any)
    end
    stock_rows = table_signatures(stock_table)
    library_rows = table_signatures(library_table)
    require!(stock_rows == expected_rows, "stock typed-table rows differ from empty-array literals")
    require!(library_rows == expected_rows, "library typed-table rows differ from empty-array literals")
    JSON::Any.new({
      "case_id" => JSON::Any.new(CASE_ID),
      "profile_id" => JSON::Any.new(profile_id),
      "schema_declaration" => JSON::Any.new(fixed[:schema].declaration),
      "library_part_path" => JSON::Any.new(File.expand_path(library_part)),
      "stock_reader" => JSON::Any.new(stock_reader),
      "library_reader" => JSON::Any.new(library_reader),
      "stock_table_rows" => JSON::Any.new(stock_rows),
      "library_table_rows" => JSON::Any.new(library_rows),
      "library_prepared_actual_roster" => JSON::Any.new([JSON::Any.new("UInt64")]),
    } of String => JSON::Any)
  end

  private def run(args : Array(String)) : Nil
    raise ArgumentError.new("usage: check_recursive_dynamic_json_w205.cr INPUT.json OUTPUT_ROOT") unless args.size == 2
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    unless Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root
      raise ArgumentError.new("W205 output root must be canonical and non-symlinked")
    end
    unless File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR)
      raise ArgumentError.new("W205 helper input must be a plain file below output root")
    end
    input = JSON.parse(File.read(input_path))
    require!(input.as_h.keys.sort == ["capture_root", "cases", "format"] && input["format"].as_s == FORMAT_INPUT,
      "helper input format differs")
    capture_root = input["capture_root"].as_s
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "capture root is not canonical")
    cases = input["cases"].as_a
    require!(cases.size == PROFILE_IDS.size, "helper profile count differs")
    require!(cases.map { |item| item["profile_id"].as_s } == PROFILE_IDS, "helper profile order differs")
    cases.each do |item|
      require!(item.as_h.keys.sort == ["capture_root", "case_id", "library_part", "profile_id", "source_part"],
        "helper case input keys differ")
    end
    results = cases.map { |item| process_profile(item, output_root, capture_root) }
    puts JSON::Any.new({
      "format" => JSON::Any.new(FORMAT_OUTPUT),
      "case_id" => JSON::Any.new(CASE_ID),
      "profile_ids" => JSON::Any.new(PROFILE_IDS.map { |name| JSON::Any.new(name) }),
      "cases" => JSON::Any.new(results),
    }).to_json
  rescue ex : Exception
    STDERR.puts "W205 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckRecursiveDynamicJSONW205.main(ARGV)
