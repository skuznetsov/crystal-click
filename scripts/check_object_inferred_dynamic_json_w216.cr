require "../src/crystal_click"
require "json"

module CheckObjectInferredDynamicJSONW216
  extend self

  FORMAT_INPUT  = "object_inferred_dynamic_json_w216_input_v1"
  FORMAT_OUTPUT = "object_inferred_dynamic_json_w216_helper_v1"
  DECLARATION   = "JSON(max_dynamic_types=4, max_dynamic_paths=16)"
  WINDOWS       = [
    {"full", 0, 4},
    {"first", 0, 1},
    {"middle", 1, 2},
    {"final", 3, 1},
    {"eof", 4, 0},
  ]
  EXPECTED_ROWS_BY_MARK = [
    ["JSON(7)", "ARRAY[JSON(8),JSON(9)]"],
    ["ABSENT", "JSON(0)"],
    ["ARRAY[]", "ABSENT"],
    ["JSON(20)", "ARRAY[JSON(21)]"],
  ]
  EXPECTED_LABELS_BY_MARK = [
    ["ordinary-first", "ABSENT"],
    ["sparse", "ABSENT"],
    ["ABSENT", "tail"],
    ["ABSENT", "ABSENT"],
  ]
  VALUES = [7_u8, 8_u8, 9_u8, 0_u8, 20_u8, 21_u8]

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W216 helper: #{message}") unless condition
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"
      CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W216 String profile is outside the fixed roster")
    end
  end

  private def mode(name : String) : UInt64
    case name
    when "basic"
      CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE
    when "compact"
      CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE
    else
      raise ArgumentError.new("W216 discriminator mode is outside the fixed roster")
    end
  end

  private def typed_json : CrystalClick::BinaryDataType
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"v" => uint8} of String => CrystalClick::BinaryDataType,
    )
  end

  private def json_value(type : CrystalClick::BinaryDataType, value : UInt8) : CrystalClick::BinaryValue
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    CrystalClick::BinaryValue.json(
      type,
      CrystalClick::BinaryJsonRow.new(
        type,
        [{"v", CrystalClick::BinaryValue.fixed(uint8, Bytes[value])}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )
  end

  private def child_plan(type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::ObjectDocumentPlan.new(structures, type.json_type.not_nil!.typed_paths)
  end

  private def make_plan : Tuple(CrystalClick::ObjectDocumentSchema, CrystalClick::ObjectDocumentPlan)
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION)
    json = typed_json
    array_json = CrystalClick::BinaryDataType.array(json)
    payload_roster = CrystalClick::DynamicStructure.new([json, array_json] of CrystalClick::BinaryDataType)
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["p", "label"] of String),
      {
        "p"     => payload_roster,
        "label" => CrystalClick::DynamicStructure.new([CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType),
      } of String => CrystalClick::DynamicStructure,
    )
    leaves = [
      {
        CrystalClick::BinaryDynamicJsonLeafKey.new(
          "root", payload_roster.canonical_index_for(json), [] of Int32,
        ),
        child_plan(json),
      },
      {
        CrystalClick::BinaryDynamicJsonLeafKey.new(
          "root", payload_roster.canonical_index_for(array_json), [0_i32] of Int32,
        ),
        child_plan(json),
      },
    ] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      schema.typed_paths,
      root_dynamic_json_object_leaf_plans: {"p" => leaves} of String => Array(Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)),
    )
    {schema, plan}
  end

  private def rows : Array(Array(CrystalClick::ObjectDocument))
    json = typed_json
    array_json = CrystalClick::BinaryDataType.array(json)
    direct = ->(value : UInt8) { json_value(json, value) }
    array = ->(values : Array(UInt8)) {
      CrystalClick::BinaryValue.array(array_json, values.map { |value| direct.call(value) })
    }
    document = ->(payload : CrystalClick::BinaryValue?, label : String?) {
      entries = {} of String => CrystalClick::BinaryValue
      entries["p"] = payload.not_nil! if payload
      entries["label"] = CrystalClick::BinaryValue.string(label.not_nil!) if label
      CrystalClick::ObjectDocument.new(entries)
    }
    [
      [document.call(direct.call(7_u8), "ordinary-first"), document.call(array.call([8_u8, 9_u8] of UInt8), nil)] of CrystalClick::ObjectDocument,
      [document.call(nil, "sparse"), document.call(direct.call(0_u8), nil)] of CrystalClick::ObjectDocument,
      [document.call(array.call([] of UInt8), nil), document.call(nil, "tail")] of CrystalClick::ObjectDocument,
      [document.call(direct.call(20_u8), nil), document.call(array.call([21_u8] of UInt8), nil)] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument)
  end

  private def value_signature(value : CrystalClick::BinaryValue) : String
    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_JSON
      scalar = value.json_row.value_for("v").not_nil!
      require!(scalar.type == CrystalClick::BinaryDataType.primitive("UInt8"), "JSON v leaf is not exact UInt8")
      "JSON(#{scalar.byte_at(0)})"
    when CrystalClick::BinaryDataType::TAG_ARRAY
      array_json = CrystalClick::BinaryDataType.array(typed_json)
      require!(value.type == array_json, "p actual is not the exact Array(JSON(v UInt8)) descriptor")
      "ARRAY[#{value.elements.map { |element| value_signature(element) }.join(",")}]"
    else
      raise CrystalClick::CorruptPartError.new("W216 p actual is outside the direct/Array JSON roster: #{value.type.name}")
    end
  end

  private def signature(document : CrystalClick::ObjectDocument, path : String) : String
    return "ABSENT" unless document.has_path?(path)
    value = document.value_for(path)
    return "ABSENT" if value.is_null?
    value_signature(value)
  end

  private def label(document : CrystalClick::ObjectDocument) : String
    return "ABSENT" unless document.has_path?("label")
    value = document.value_for("label")
    require!(value.type == CrystalClick::BinaryDataType.primitive("String"), "ordinary sibling is not String")
    value.as_string
  end

  private def inspect_side(
    part_path : String,
    schema : CrystalClick::ObjectDocumentSchema,
    profile_name : String,
    origin : String,
  ) : JSON::Any
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      part_path, "payload", schema.typed_paths, profile(profile_name),
      CrystalClick::BinaryBulkProfile.single_stream, true,
    )
    structure = descriptor.plan.structures.dynamic_for("p")
    actuals = Array(String).new(structure.type_count)
    structure.type_count.times { |index| actuals << structure.type_at(index).name }
    json = typed_json
    expected_actuals = [json.name, CrystalClick::BinaryDataType.array(json).name].sort
    require!(actuals.sort == expected_actuals, "#{origin} p actual descriptors differ: #{actuals.inspect}")
    require!(descriptor.row_count == 8_u64 && descriptor.mark_count == 4_u64, "#{origin} row/mark counts differ")
    require!(descriptor.mark_row_counts == [2_u64, 2_u64, 2_u64, 2_u64], "#{origin} P grid differs")
    require!(!descriptor.physical_stream_names.empty?, "#{origin} physical roster is empty")
    require!(descriptor.physical_stream_names.uniq == descriptor.physical_stream_names, "#{origin} physical roster has duplicates")
    require!(!descriptor.selected_checksum_names.empty?, "#{origin} checksum roster is empty")
    require!(descriptor.selected_checksum_names.uniq == descriptor.selected_checksum_names, "#{origin} checksum roster has duplicates")

    windows = WINDOWS.map do |window, first_mark, mark_count|
      marks = CrystalClick::ObjectDocumentFileReader.read(
        part_path, "payload", schema.typed_paths, first_mark, mark_count,
        profile(profile_name), CrystalClick::BinaryBulkProfile.single_stream, true,
      )
      actual_values = marks.map do |mark|
        mark.map { |document| {signature(document, "p"), label(document)} }
      end
      expected_slice = EXPECTED_ROWS_BY_MARK[first_mark, mark_count] || [] of Array(String)
      expected_label_slice = EXPECTED_LABELS_BY_MARK[first_mark, mark_count] || [] of Array(String)
      if mark_count == 0
        require!(actual_values.empty?, "#{origin} EOF returned rows")
      else
        expected_values = expected_slice.zip(expected_label_slice).map do |values, labels|
          values.zip(labels)
        end
        require!(actual_values == expected_values, "#{origin} literal #{window} rows differ")
      end
      JSON::Any.new({
        "window"       => JSON::Any.new(window),
        "first_mark"   => JSON::Any.new(first_mark.to_i64),
        "mark_count"   => JSON::Any.new(mark_count.to_i64),
        "rows_by_mark" => JSON::Any.new(actual_values.map { |mark| JSON::Any.new(mark.map { |pair| JSON::Any.new(pair.to_a.map { |value| JSON::Any.new(value) }) }) }),
      })
    end
    JSON::Any.new({
      "origin"                  => JSON::Any.new(origin),
      "schema_declaration"      => JSON::Any.new(schema.declaration),
      "row_count"               => JSON::Any.new(descriptor.row_count.to_i64),
      "mark_count"              => JSON::Any.new(descriptor.mark_count.to_i64),
      "mark_row_counts"         => JSON::Any.new(descriptor.mark_row_counts.map { |rows| JSON::Any.new(rows.to_i64) }),
      "dynamic_actual_types"    => JSON::Any.new(actuals.sort.map { |name| JSON::Any.new(name) }),
      "physical_stream_names"   => JSON::Any.new(descriptor.physical_stream_names.map { |name| JSON::Any.new(name) }),
      "selected_checksum_names" => JSON::Any.new(descriptor.selected_checksum_names.map { |name| JSON::Any.new(name) }),
      "windows"                 => JSON::Any.new(windows),
    })
  end

  private def process_case(item : JSON::Any, capture_root : String, output_root : String) : JSON::Any
    expected_keys = ["capture_root", "cell_id", "library_part", "mode_id", "profile_id", "source_part"]
    require!(item.as_h.keys.sort == expected_keys, "case input keys differ")
    require!(item["capture_root"].as_s == capture_root, "capture root differs")
    profile_name = item["profile_id"].as_s
    profile_value = profile(profile_name)
    mode_name = item["mode_id"].as_s
    mode_value = mode(mode_name)
    source_part = File.expand_path(item["source_part"].as_s)
    require!(source_part.starts_with?(capture_root + File::SEPARATOR) && Dir.exists?(source_part) && !File.symlink?(source_part), "source part escaped or absent")
    library_part = File.expand_path(item["library_part"].as_s)
    generated_root = File.join(output_root, "generated")
    require!(library_part.starts_with?(generated_root + File::SEPARATOR), "library part escaped generated root")
    require!(!Dir.exists?(library_part) && !File.symlink?(library_part), "library destination already exists")

    schema, plan = make_plan
    ids = Slice(UInt64).new(8) { |index| (index + 1).to_u64 }
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      library_part, "pk", ids, "payload", schema, plan, rows,
      rows_per_mark: 2, mode: mode_value, profile: profile_value,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream, frame_bytes: 64,
    )
    require!(plan.structures.dynamic_for("p").type_count == 2, "library root Dynamic roster is not direct/Array JSON")
    JSON::Any.new({
      "cell_id"           => item["cell_id"],
      "profile_id"        => JSON::Any.new(profile_name),
      "mode_id"           => JSON::Any.new(mode_name),
      "library_part_path" => JSON::Any.new(library_part),
      "source"            => inspect_side(source_part, schema, profile_name, "source"),
      "library"           => inspect_side(library_part, schema, profile_name, "library"),
    })
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 2
      raise ArgumentError.new("usage: check_object_inferred_dynamic_json_w216.cr INPUT.json OUTPUT_ROOT")
    end
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    require!(Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root, "output root must be canonical")
    require!(File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR), "helper input escaped output root")
    input = JSON.parse(File.read(input_path))
    require!(input.as_h.keys.sort == ["capture_root", "cells", "format"] && input["format"].as_s == FORMAT_INPUT, "helper input format differs")
    capture_root = input["capture_root"].as_s
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root, "capture root is not canonical")
    cells = input["cells"].as_a
    expected = ["single_stream/basic", "single_stream/compact", "with_size_stream/basic", "with_size_stream/compact"]
    observed = cells.map { |item| "#{item["profile_id"].as_s}/#{item["mode_id"].as_s}" }
    require!(observed == expected, "fixed profile/mode roster differs")
    results = cells.map { |item| process_case(item, capture_root, output_root) }
    json = typed_json
    puts JSON::Any.new({
      "format"         => JSON::Any.new(FORMAT_OUTPUT),
      "declaration"    => JSON::Any.new(DECLARATION),
      "actual_types"   => JSON::Any.new([json.name, CrystalClick::BinaryDataType.array(json).name].sort.map { |name| JSON::Any.new(name) }),
      "literal_values" => JSON::Any.new(VALUES.map { |value| JSON::Any.new(value.to_i64) }),
      "windows"        => JSON::Any.new(WINDOWS.map { |window, first, count|
        JSON::Any.new({"window" => JSON::Any.new(window), "first_mark" => JSON::Any.new(first.to_i64), "mark_count" => JSON::Any.new(count.to_i64)})
      }),
      "cells" => JSON::Any.new(results),
    }).to_json
  rescue ex : Exception
    STDERR.puts "W216 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckObjectInferredDynamicJSONW216.main(ARGV)
