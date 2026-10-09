require "../src/crystal_click"
require "json"

module CheckRecursiveQBitDynamicW233
  extend self

  INPUT_FORMAT  = "recursive_qbit_dynamic_w233_helper_input_v1"
  OUTPUT_FORMAT = "recursive_qbit_dynamic_w233_helper_output_v1"
  COLUMN        = "v"
  KEY_NAME      = "id"
  ROW_COUNT     = 6_u64
  MARK_ROWS     = [2_u64, 2_u64, 2_u64]
  PROFILE_IDS   = ["root_dynamic", "carrier_dynamic", "shared_dynamic"]

  alias Fixture = NamedTuple(
    id: String,
    column: String,
    type: CrystalClick::BinaryDataType,
    structures: Hash(String, CrystalClick::DynamicStructure),
    rows: Array(Array(CrystalClick::BinaryValue)),
  )

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W233: #{message}") unless condition
  end

  private def qtype : CrystalClick::QBitType
    CrystalClick::QBitType.new("Int8", 9_u64)
  end

  private def raw_bytes(hex : String) : Bytes
    unless hex.bytesize.even? && hex.matches?(/\A(?:[0-9a-f]{2})*\z/)
      raise ArgumentError.new("W233 QBit literal is not lowercase even-width hex")
    end
    Bytes.new(hex.bytesize // 2) do |index|
      hex.byte_slice(index * 2, 2).to_u8(16)
    end
  end

  private def qvalue(type : CrystalClick::QBitType, hex : String) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(type, raw_bytes(hex)))
  end

  private def arm_index(variant : CrystalClick::BinaryDataType, arm : CrystalClick::BinaryDataType) : Int
    variant.child_count.times do |index|
      return index if variant.child_at(index) == arm
    end
    raise ArgumentError.new("W233 Variant arm is absent")
  end

  private def fixture(id : String) : Fixture
    q = qtype
    qbit = CrystalClick::BinaryDataType.qbit(q)
    string = CrystalClick::BinaryDataType.primitive("String")
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    array_qbit = CrystalClick::BinaryDataType.array(qbit)
    tuple_qbit = CrystalClick::BinaryDataType.tuple(
      [qbit, uint8] of CrystalClick::BinaryDataType,
      ["q", "n"] of String,
    )
    map_qbit = CrystalClick::BinaryDataType.map(string, qbit)
    variant = CrystalClick::BinaryDataType.variant([qbit, uint64] of CrystalClick::BinaryDataType)
    array_variant = CrystalClick::BinaryDataType.array(variant)
    qbit_arm = arm_index(variant, qbit)

    root_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 4)
    shared_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    carrier = CrystalClick::BinaryDataType.array(root_dynamic)

    roots = [
      CrystalClick::BinaryValue.array(array_qbit, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array_qbit, [qvalue(q, "010203040506070809")] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.tuple(tuple_qbit, [
        qvalue(q, "ff0001020408102040"), CrystalClick::BinaryValue.fixed(uint8, Bytes[7_u8]),
      ] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.map(map_qbit, [
        CrystalClick::BinaryValue.string("a"), qvalue(q, "090807060504030201"),
      ] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array_variant, [
        CrystalClick::BinaryValue.variant(variant, qbit_arm, qvalue(q, "020406080a0c0e1012")),
      ] of CrystalClick::BinaryValue),
      nil.as(CrystalClick::BinaryValue?),
    ] of CrystalClick::BinaryValue?

    root_rows = Array(CrystalClick::BinaryValue).new(6) do |index|
      child = roots[index]
      CrystalClick::BinaryValue.dynamic(root_dynamic, child)
    end
    shared_rows = Array(CrystalClick::BinaryValue).new(6) do |index|
      child = roots[index]
      CrystalClick::BinaryValue.dynamic(shared_dynamic, child)
    end
    carrier_rows = Array(CrystalClick::BinaryValue).new(6) do |index|
      element = CrystalClick::BinaryValue.dynamic(root_dynamic, roots[index])
      items = index == 0 ? [] of CrystalClick::BinaryValue : [element] of CrystalClick::BinaryValue
      CrystalClick::BinaryValue.array(carrier, items)
    end

    actual_types = [array_qbit, tuple_qbit, map_qbit, array_variant] of CrystalClick::BinaryDataType
    structures = {
      "root" => CrystalClick::DynamicStructure.new(actual_types),
    } of String => CrystalClick::DynamicStructure
    carrier_structures = {
      "root.elements" => CrystalClick::DynamicStructure.new(actual_types),
    } of String => CrystalClick::DynamicStructure
    shared_structures = {
      "root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    } of String => CrystalClick::DynamicStructure

    case id
    when "root_dynamic"
      {id: id, column: "root_d", type: root_dynamic, structures: structures,
       rows: [[root_rows[0], root_rows[1]], [root_rows[2], root_rows[3]], [root_rows[4], root_rows[5]]]}
    when "carrier_dynamic"
      {id: id, column: "carrier", type: carrier, structures: carrier_structures,
       rows: [[carrier_rows[0], carrier_rows[1]], [carrier_rows[2], carrier_rows[3]], [carrier_rows[4], carrier_rows[5]]]}
    when "shared_dynamic"
      {id: id, column: "shared_d", type: shared_dynamic, structures: shared_structures,
       rows: [[shared_rows[0], shared_rows[1]], [shared_rows[2], shared_rows[3]], [shared_rows[4], shared_rows[5]]]}
    else
      raise ArgumentError.new("W233 fixture id is outside the fixed profile roster")
    end
  end

  private def same_value?(left : CrystalClick::BinaryValue, right : CrystalClick::BinaryValue) : Bool
    left.type == right.type && CrystalClick::BinaryValueCodec.encode(left) == CrystalClick::BinaryValueCodec.encode(right)
  end

  private def compare_marks!(actual : Array(Array(CrystalClick::BinaryValue)), expected : Array(Array(CrystalClick::BinaryValue)), label : String) : Nil
    require!(actual.size == expected.size, "mark count differs for #{label}")
    actual.each_with_index do |rows, mark|
      expected_rows = expected[mark]
      require!(rows.size == expected_rows.size, "row count differs for #{label}/#{mark}")
      rows.each_with_index do |value, row|
        require!(same_value?(value, expected_rows[row]), "nominal type or literal differs for #{label}/#{mark}/#{row}")
      end
    end
  end

  private def encoded_hex(values : Array(CrystalClick::BinaryValue)) : Array(JSON::Any)
    values.map do |value|
      JSON::Any.new(CrystalClick::BinaryValueCodec.encode_value(value).hexstring.downcase)
    end
  end

  private def validate_part_path!(path : String, root : String, generated : Bool) : Nil
    full = File.expand_path(path)
    require!(full.starts_with?(root + File::SEPARATOR), "part escaped its fixed root")
    if generated
      require!(!File.exists?(full) && !File.symlink?(full), "generated part destination already exists")
      parent = File.dirname(full)
      require!(Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent,
        "generated part parent is absent or noncanonical")
    else
      require!(Dir.exists?(full) && !File.symlink?(full) && File.realpath(full) == full,
        "stock source part is absent or noncanonical")
    end
  end

  private def reader_record(part : String, fixed : Fixture, origin : String) : JSON::Any
    reader = CrystalClick::DynamicBulkColumnReader.open(part, fixed[:column], fixed[:type])
    plan = CrystalClick::BinaryDynamicBulkPlan.new(
      fixed[:type], fixed[:structures], CrystalClick::BinaryBulkProfile.single_stream,
    )
    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, fixed[:column])
    expected_names = physical.stream_names.values.sort!
    actual_names = reader.physical_stream_names.sort!
    require!(reader.schema_declaration == fixed[:type].name && reader.source_declaration == fixed[:type].name,
      "#{origin} declared/source type differs")
    require!(reader.row_count == ROW_COUNT && reader.mark_count == MARK_ROWS.size,
      "#{origin} row/mark census differs")
    require!(reader.mark_row_counts == MARK_ROWS, "#{origin} mark grid differs")
    require!(reader.ordinary_profile == CrystalClick::BinaryBulkProfile.single_stream,
      "#{origin} String profile differs")
    require!(actual_names == expected_names && actual_names.uniq == actual_names,
      "#{origin} exact physical role roster differs")

    full = reader.read_marks(0, reader.mark_count)
    compare_marks!(full, fixed[:rows], "#{origin} full")
    middle = reader.read_marks(1, 1)
    compare_marks!(middle, fixed[:rows][1, 1], "#{origin} middle")
    require!(reader.read_marks(1, 0).empty? && reader.read_marks(reader.mark_count, 0).empty?,
      "#{origin} zero-mark window is not empty")

    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_NAME, fixed[:column]])
    observed = Array(Array(CrystalClick::BinaryValue)).new(fixed[:rows].size) { [] of CrystalClick::BinaryValue }
    table.scan_typed_candidate_marks([[0, 1, 2]]) do |batch|
      mark = batch.mark_index
      require!(batch.part_index == 0 && mark >= 0 && mark < fixed[:rows].size,
        "#{origin} candidate mark identity escaped its grid")
      values = batch.dynamic_bulk_values_for(fixed[:column]).to_a
      observed[mark] = values
    end
    compare_marks!(observed, fixed[:rows], "#{origin} typed-table full")

    typed_middle = [] of CrystalClick::BinaryValue
    typed_middle_keys = [] of UInt64
    typed_middle_schedule = [] of Tuple(Int32, UInt64, UInt64, UInt64)
    table.scan_typed_window(2_u64, max_rows: 2) do |batch|
      require!(batch.part_index == 0 && batch.mark_index == 1,
        "#{origin} typed middle part/mark identity differs")
      typed_middle_keys.concat(batch.values_for(KEY_NAME, UInt64).to_a)
      typed_middle.concat(batch.dynamic_bulk_values_for(fixed[:column]).to_a)
      typed_middle_schedule << {batch.mark_index, batch.mark_row_offset, batch.part_row_offset, batch.source_row_offset}
    end
    compare_marks!([typed_middle], fixed[:rows][1, 1], "#{origin} typed middle")
    require!(typed_middle_keys == [3_u64, 4_u64] &&
             typed_middle_schedule == [{1, 0_u64, 2_u64, 2_u64}],
      "#{origin} typed middle window values/offsets differ")

    zero_callbacks = 0
    table.scan_typed_candidate_marks([[] of Int32]) { |_batch| zero_callbacks += 1 }
    eof_callbacks = 0
    table.scan_typed_window(table.total_row_count, 1) { |_batch| eof_callbacks += 1 }
    require!(zero_callbacks == 0 && eof_callbacks == 0, "#{origin} zero/EOF typed windows called back")

    JSON::Any.new({
      "schema_declaration"            => JSON::Any.new(reader.schema_declaration),
      "row_count"                     => JSON::Any.new(reader.row_count.to_i64),
      "mark_row_counts"               => JSON::Any.new(reader.mark_row_counts.map { |value| JSON::Any.new(value.to_i64) }),
      "dynamic_site_paths"            => JSON::Any.new(plan.site_paths.sort!.map { |value| JSON::Any.new(value) }),
      "physical_stream_names"         => JSON::Any.new(actual_names.map { |value| JSON::Any.new(value) }),
      "windows"                       => JSON::Any.new(["full", "middle", "zero_marks", "zero_candidates", "eof"].map { |value| JSON::Any.new(value) }),
      "full_rowbinary_hex"            => JSON::Any.new(encoded_hex(full.flatten)),
      "middle_rowbinary_hex"          => JSON::Any.new(encoded_hex(middle.flatten)),
      "typed_full_rowbinary_hex"      => JSON::Any.new(encoded_hex(observed.flatten)),
      "typed_middle_rowbinary_hex"    => JSON::Any.new(encoded_hex(typed_middle)),
      "exact_type_and_literal_checks" => JSON::Any.new(true),
    } of String => JSON::Any)
  end

  private def write_library_part!(path : String, fixed : Fixture) : Nil
    keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
    result = CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
      path, KEY_NAME, keys, fixed[:column], fixed[:type], fixed[:structures], fixed[:rows],
      rows_per_mark: 2,
      profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: 4096,
      metadata_version: 0_i64,
    )
    require!(result == path, "writer returned a different output path")
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 2
      raise ArgumentError.new("usage: check_recursive_qbit_dynamic_w233.cr INPUT.json OUTPUT_ROOT")
    end
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    unless Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root
      raise ArgumentError.new("W233 output root must be canonical and non-symlinked")
    end
    unless File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR)
      raise ArgumentError.new("W233 helper input must be a plain file below output root")
    end

    input = JSON.parse(File.read(input_path))
    require!(input.as_h.keys.sort == ["format", "profiles", "stock_root"] && input["format"].as_s == INPUT_FORMAT,
      "helper input format differs")
    stock_root = File.expand_path(input["stock_root"].as_s)
    require!(Dir.exists?(stock_root) && !File.symlink?(stock_root) && File.realpath(stock_root) == stock_root,
      "stock root is absent, symlinked, or noncanonical")
    profiles = input["profiles"].as_a
    require!(profiles.map { |item| item["id"].as_s } == PROFILE_IDS,
      "helper profile roster or order differs")

    results = profiles.map do |item|
      require!(item.as_h.keys.sort == ["id", "library_part", "source_part"], "helper profile keys differ")
      fixed = fixture(item["id"].as_s)
      source_part = item["source_part"].as_s
      library_part = item["library_part"].as_s
      validate_part_path!(source_part, stock_root, false)
      validate_part_path!(library_part, output_root, true)

      source = reader_record(source_part, fixed, "stock/#{fixed[:id]}")
      write_library_part!(library_part, fixed)
      library = reader_record(library_part, fixed, "library/#{fixed[:id]}")
      JSON::Any.new({
        "id"                => JSON::Any.new(fixed[:id]),
        "column"            => JSON::Any.new(fixed[:column]),
        "declared_type"     => JSON::Any.new(fixed[:type].name),
        "source_part_path"  => JSON::Any.new(File.expand_path(source_part)),
        "library_part_path" => JSON::Any.new(File.expand_path(library_part)),
        "source"            => source,
        "library"           => library,
      } of String => JSON::Any)
    end

    puts JSON::Any.new({
      "format"      => JSON::Any.new(OUTPUT_FORMAT),
      "profile_ids" => JSON::Any.new(PROFILE_IDS.map { |value| JSON::Any.new(value) }),
      "profiles"    => JSON::Any.new(results),
    } of String => JSON::Any).to_json
  rescue ex : Exception
    STDERR.puts "W233 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckRecursiveQBitDynamicW233.main(ARGV)
