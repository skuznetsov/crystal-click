require "../src/crystal_click"
require "json"

module CheckObjectTypedDynamicJSONW215
  extend self

  FORMAT_INPUT  = "object_typed_dynamic_json_w215_input_v1"
  FORMAT_OUTPUT = "object_typed_dynamic_json_w215_helper_v1"
  DECLARATION   = "JSON(max_dynamic_types=0, max_dynamic_paths=0, p Dynamic(max_types=2))"
  WINDOWS       = [
    {"full", 0, 4},
    {"first", 0, 1},
    {"middle", 1, 2},
    {"final", 3, 1},
    {"eof", 4, 0},
  ]
  VALUES                = [7_u8, 8_u8, 17_u8, 18_u8, 19_u8, 20_u8, 21_u8, 22_u8, 23_u8]
  EXPECTED_ROWS_BY_MARK = [
    ["JSON(7)", "JSON(8)"],
    ["ARRAY[JSON(17)]", "ARRAY[JSON(18),JSON(19)]"],
    ["NULL", "JSON(20)"],
    ["ARRAY[JSON(21),JSON(22)]", "JSON(23)"],
  ]

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W215 helper: #{message}") unless condition
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"
      CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W215 String profile is outside the fixed roster")
    end
  end

  private def mode(name : String) : UInt64
    case name
    when "basic"
      CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE
    when "compact"
      CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE
    else
      raise ArgumentError.new("W215 discriminator mode is outside the fixed roster")
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

  private def rows : Array(Array(CrystalClick::ObjectDocument))
    json = typed_json
    array_json = CrystalClick::BinaryDataType.array(json)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    direct = ->(value : UInt8) { CrystalClick::BinaryValue.dynamic(dynamic, json_value(json, value)) }
    array = ->(values : Array(UInt8)) {
      elements = values.map { |value| json_value(json, value) }
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array_json, elements))
    }
    values = [
      direct.call(7_u8), direct.call(8_u8), array.call([17_u8] of UInt8),
      array.call([18_u8, 19_u8] of UInt8), CrystalClick::BinaryValue.dynamic(dynamic),
      direct.call(20_u8), array.call([21_u8, 22_u8] of UInt8), direct.call(23_u8),
    ] of CrystalClick::BinaryValue
    values.map { |value| CrystalClick::ObjectDocument.new({"p" => value}) }
      .each_slice(2).map(&.to_a).to_a
  end

  private def scalar(value : CrystalClick::BinaryValue, expected_type : CrystalClick::BinaryDataType) : String
    current = value
    while current.type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC && !current.is_null?
      current = current.child_at(0)
    end
    require!(current.type == expected_type,
      "JSON v scalar type differs: expected #{expected_type.name}, got #{current.type.name}")
    case current.type.tag
    when CrystalClick::BinaryDataType::TAG_UINT8
      current.byte_at(0).to_s
    when CrystalClick::BinaryDataType::TAG_INT64
      current.as_int64.to_s
    else
      raise CrystalClick::CorruptPartError.new("W215 JSON value has an unrostered scalar type")
    end
  end

  private def signature(value : CrystalClick::BinaryValue, expected_scalar_type : CrystalClick::BinaryDataType) : String
    return "NULL" if value.is_null?
    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      signature(value.child_at(0), expected_scalar_type)
    when CrystalClick::BinaryDataType::TAG_JSON
      row = value.json_row
      path = row.value_for("v").not_nil!
      "JSON(#{scalar(path, expected_scalar_type)})"
    when CrystalClick::BinaryDataType::TAG_ARRAY
      "ARRAY[#{value.elements.map { |item| signature(item, expected_scalar_type) }.join(",")}]"
    else
      raise CrystalClick::CorruptPartError.new("W215 value has an unrostered JSON wrapper")
    end
  end

  private def windows(
    part_path : String,
    schema : CrystalClick::ObjectDocumentSchema,
    profile_name : String,
    expected_scalar_type : CrystalClick::BinaryDataType,
  ) : Array(JSON::Any)
    WINDOWS.map do |window, first_mark, mark_count|
      marks = CrystalClick::ObjectDocumentFileReader.read(
        part_path, "payload", schema.typed_paths, first_mark, mark_count,
        profile(profile_name), CrystalClick::BinaryBulkProfile.single_stream, true,
      )
      rows_by_mark = marks.map do |documents|
        JSON::Any.new(documents.map { |document| JSON::Any.new(signature(document.value_for("p"), expected_scalar_type)) })
      end
      if window == "full"
        actual = marks.map do |documents|
          documents.map { |document| signature(document.value_for("p"), expected_scalar_type) }
        end
        require!(actual == EXPECTED_ROWS_BY_MARK, "literal JSON rows differ for #{expected_scalar_type.name} origin")
      end
      JSON::Any.new({
        "window"       => JSON::Any.new(window),
        "first_mark"   => JSON::Any.new(first_mark.to_i64),
        "mark_count"   => JSON::Any.new(mark_count.to_i64),
        "rows_by_mark" => JSON::Any.new(rows_by_mark),
      })
    end
  end

  private def side_observation(
    part_path : String,
    schema : CrystalClick::ObjectDocumentSchema,
    profile_name : String,
    origin : String,
  ) : JSON::Any
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      part_path, "payload", schema.typed_paths, profile(profile_name),
      CrystalClick::BinaryBulkProfile.single_stream, true,
    )
    structure = descriptor.plan.typed_dynamic_for("p")
    ordinary_types = Array(String).new
    structure.type_count.times { |index| ordinary_types << structure.type_at(index).name }
    actual_types = ordinary_types.sort
    expected_types = case origin
                     when "source"
                       ["Array(JSON)", "JSON"]
                     when "library"
                       [CrystalClick::BinaryDataType.array(typed_json).name, typed_json.name].sort
                     else
                       raise ArgumentError.new("W215 observation origin is outside the fixed roster")
                     end
    require!(actual_types == expected_types,
      "#{origin} Dynamic actual descriptors differ: expected #{expected_types}, got #{actual_types}")
    expected_scalar_type = CrystalClick::BinaryDataType.primitive(origin == "source" ? "Int64" : "UInt8")
    JSON::Any.new({
      "origin"                  => JSON::Any.new(origin),
      "schema_declaration"      => JSON::Any.new(schema.declaration),
      "row_count"               => JSON::Any.new(descriptor.row_count.to_i64),
      "mark_count"              => JSON::Any.new(descriptor.mark_count.to_i64),
      "mark_row_counts"         => JSON::Any.new(descriptor.mark_row_counts.map { |rows| JSON::Any.new(rows.to_i64) }),
      "dynamic_actual_types"    => JSON::Any.new(actual_types.map { |name| JSON::Any.new(name) }),
      "json_v_scalar_type"      => JSON::Any.new(expected_scalar_type.name),
      "physical_stream_names"   => JSON::Any.new(descriptor.physical_stream_names.map { |name| JSON::Any.new(name) }),
      "selected_checksum_names" => JSON::Any.new(descriptor.selected_checksum_names.map { |name| JSON::Any.new(name) }),
      "windows"                 => JSON::Any.new(windows(part_path, schema, profile_name, expected_scalar_type)),
    })
  end

  private def canonical_part!(path : String, root : String, label : String) : String
    full = File.expand_path(path)
    require!(full.starts_with?(root + File::SEPARATOR), "#{label} escaped the fixed capture root")
    require!(Dir.exists?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical")
    full
  end

  private def process_case(item : JSON::Any, capture_root : String, output_root : String) : JSON::Any
    expected_keys = ["capture_root", "cell_id", "library_part", "mode_id", "profile_id", "source_part"]
    require!(item.as_h.keys.sort == expected_keys, "case input keys differ")
    require!(item["capture_root"].as_s == capture_root, "capture root differs")
    profile_name = item["profile_id"].as_s
    profile_value = profile(profile_name)
    mode_name = item["mode_id"].as_s
    mode_value = mode(mode_name)
    source_part = canonical_part!(item["source_part"].as_s, capture_root, "stock source part")
    library_part = File.expand_path(item["library_part"].as_s)
    generated_root = File.join(output_root, "generated")
    require!(library_part.starts_with?(generated_root + File::SEPARATOR), "library part escaped generated root")
    require!(!Dir.exists?(library_part) && !File.symlink?(library_part), "library destination already exists")

    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION)
    require!(schema.declaration == DECLARATION, "Object JSON declaration differs")
    json = typed_json
    array_json = CrystalClick::BinaryDataType.array(json)
    dynamic_roster = CrystalClick::DynamicStructure.new([json, array_json] of CrystalClick::BinaryDataType)
    child = child_plan(json)
    leaves = [
      {CrystalClick::BinaryDynamicJsonLeafKey.new("root", dynamic_roster.canonical_index_for(json), [] of Int32), child},
      {CrystalClick::BinaryDynamicJsonLeafKey.new("root", dynamic_roster.canonical_index_for(array_json), [0_i32] of Int32), child},
    ] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      schema.typed_paths,
      {"p" => dynamic_roster} of String => CrystalClick::DynamicStructure,
      typed_dynamic_json_object_leaf_plans: {"p" => leaves} of String => Array(Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)),
    )
    keys = Slice(UInt64).new(8) { |index| (index + 1).to_u64 }
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      library_part, "pk", keys, "payload", schema, plan, rows,
      rows_per_mark: 2, mode: mode_value, profile: profile_value,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
    )
    require!(plan.typed_dynamic_for("p").type_count == 2, "library Dynamic roster does not contain both declared JSON actuals")

    JSON::Any.new({
      "cell_id"           => item["cell_id"],
      "profile_id"        => JSON::Any.new(profile_name),
      "mode_id"           => JSON::Any.new(mode_name),
      "library_part_path" => JSON::Any.new(library_part),
      "source"            => side_observation(source_part, schema, profile_name, "source"),
      "library"           => side_observation(library_part, schema, profile_name, "library"),
    })
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 2
      raise ArgumentError.new("usage: check_object_typed_dynamic_json_w215.cr INPUT.json OUTPUT_ROOT")
    end
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    require!(Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root,
      "output root must be canonical and non-symlinked")
    require!(File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR),
      "helper input must be a plain file under the output root")
    input = JSON.parse(File.read(input_path))
    require!(input.as_h.keys.sort == ["capture_root", "cells", "format"] && input["format"].as_s == FORMAT_INPUT,
      "helper input format differs")
    capture_root = input["capture_root"].as_s
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "capture root is not canonical")
    cells = input["cells"].as_a
    expected = ["single_stream/basic", "single_stream/compact", "with_size_stream/basic", "with_size_stream/compact"]
    observed = cells.map { |item| "#{item["profile_id"].as_s}/#{item["mode_id"].as_s}" }
    require!(observed == expected, "fixed profile/mode roster differs")
    results = cells.map { |item| process_case(item, capture_root, output_root) }
    puts JSON::Any.new({
      "format"                => JSON::Any.new(FORMAT_OUTPUT),
      "declaration"           => JSON::Any.new(DECLARATION),
      "library_actual_types"  => JSON::Any.new([typed_json.name, CrystalClick::BinaryDataType.array(typed_json).name].map { |name| JSON::Any.new(name) }),
      "ordinary_dynamic_cap"  => JSON::Any.new(2_i64),
      "literal_scalar_values" => JSON::Any.new(VALUES.map { |value| JSON::Any.new(value.to_i64) }),
      "windows"               => JSON::Any.new(WINDOWS.map { |window, first, count|
        JSON::Any.new({"window" => JSON::Any.new(window), "first_mark" => JSON::Any.new(first.to_i64), "mark_count" => JSON::Any.new(count.to_i64)})
      }),
      "cells" => JSON::Any.new(results),
    }).to_json
  rescue ex : Exception
    STDERR.puts "W215 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckObjectTypedDynamicJSONW215.main(ARGV)
