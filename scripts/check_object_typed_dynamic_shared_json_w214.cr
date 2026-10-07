require "../src/crystal_click"
require "json"

module CheckObjectTypedDynamicSharedJSONW214
  extend self

  FORMAT_INPUT  = "object_typed_dynamic_shared_json_w214_input_v1"
  FORMAT_OUTPUT = "object_typed_dynamic_shared_json_w214_helper_v1"
  DECLARATION   = "JSON(p Dynamic(max_types=0))"
  WINDOWS       = [
    {"full", 0, 4},
    {"first", 0, 1},
    {"middle", 1, 2},
    {"final", 3, 1},
    {"eof", 4, 0},
  ]

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W214 helper: #{message}") unless condition
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"
      CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W214 String profile is outside the fixed roster")
    end
  end

  private def mode(name : String) : UInt64
    case name
    when "basic"
      CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE
    when "compact"
      CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE
    else
      raise ArgumentError.new("W214 discriminator mode is outside the fixed roster")
    end
  end

  private def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json
  end

  private def dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 0)
  end

  private def json_value(type : CrystalClick::BinaryDataType, text : String) : CrystalClick::BinaryValue
    row = CrystalClick::BinaryJsonRow.new(
      type,
      [{"s", CrystalClick::BinaryValue.string(text)}] of Tuple(String, CrystalClick::BinaryValue),
    )
    CrystalClick::BinaryValue.json(type, row)
  end

  private def fixture : Array(Array(CrystalClick::ObjectDocument))
    json = json_type
    dynamic = dynamic_type
    array_json = CrystalClick::BinaryDataType.array(json)
    array_nullable_string = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("String")),
    )
    wrap_json = ->(text : String) { CrystalClick::BinaryValue.dynamic(dynamic, json_value(json, text)) }
    wrap_array = ->(texts : Array(String)) {
      elements = texts.map { |text| json_value(json, text) }
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array_json, elements))
    }
    wrap_empty_inferred_array = -> {
      CrystalClick::BinaryValue.dynamic(
        dynamic,
        CrystalClick::BinaryValue.array(array_nullable_string, [] of CrystalClick::BinaryValue),
      )
    }
    wrap_null = -> { CrystalClick::BinaryValue.dynamic(dynamic) }
    values = [
      wrap_json.call("one"),
      wrap_json.call("two"),
      wrap_empty_inferred_array.call,
      wrap_array.call(["four"] of String),
      wrap_array.call(["five", "six"] of String),
      wrap_null.call,
      wrap_null.call,
      wrap_json.call("eight"),
    ] of CrystalClick::BinaryValue
    documents = values.map do |value|
      CrystalClick::ObjectDocument.new({"p" => value})
    end
    documents.each_slice(2).map(&.to_a).to_a
  end

  private def json_signature(value : CrystalClick::BinaryValue) : String
    row = value.json_row
    require!(row.path_count == 1 && row.path_at(0) == "s", "fixture JSON path roster differs")
    "JSON(#{row.value_for("s").not_nil!.as_string})"
  end

  private def signature(value : CrystalClick::BinaryValue) : String
    require!(value.type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC, "typed field is not Dynamic")
    return "NULL" if value.is_null?
    child = value.child_at(0)
    case child.type.tag
    when CrystalClick::BinaryDataType::TAG_JSON
      json_signature(child)
    when CrystalClick::BinaryDataType::TAG_ARRAY
      element_type = child.type.child_at(0)
      if element_type.tag == CrystalClick::BinaryDataType::TAG_JSON
        items = child.elements.map { |item| json_signature(item) }
        "Array(JSON):[#{items.join(",")}]"
      elsif element_type.tag == CrystalClick::BinaryDataType::TAG_NULLABLE &&
            element_type.child_at(0).tag == CrystalClick::BinaryDataType::TAG_STRING
        require!(child.elements.empty?, "inferred empty array unexpectedly contains elements")
        "Array(Nullable(String)):[]"
      else
        raise CrystalClick::CorruptPartError.new("W214 fixture has an unrostered Array actual")
      end
    else
      raise CrystalClick::CorruptPartError.new("W214 fixture has an unrostered Dynamic actual")
    end
  end

  private def profile_windows(
    part_path : String,
    schema : CrystalClick::ObjectDocumentSchema,
    profile_name : String,
  ) : Array(JSON::Any)
    result = [] of JSON::Any
    WINDOWS.each do |window, first_mark, mark_count|
      marks = CrystalClick::ObjectDocumentFileReader.read(
        part_path, "payload", schema.typed_paths, first_mark, mark_count,
        profile(profile_name), CrystalClick::BinaryBulkProfile.single_stream, true,
      )
      rows = marks.map do |documents|
        JSON::Any.new(documents.map { |document| JSON::Any.new(signature(document.value_for("p"))) })
      end
      result << JSON::Any.new({
        "window"       => JSON::Any.new(window),
        "first_mark"   => JSON::Any.new(first_mark.to_i64),
        "mark_count"   => JSON::Any.new(mark_count.to_i64),
        "rows_by_mark" => JSON::Any.new(rows),
      })
    end
    result
  end

  private def side_observation(
    part_path : String,
    schema : CrystalClick::ObjectDocumentSchema,
    profile_name : String,
  ) : JSON::Any
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      part_path, "payload", schema.typed_paths, profile(profile_name),
      CrystalClick::BinaryBulkProfile.single_stream, true,
    )
    structure = descriptor.plan.typed_dynamic_for("p")
    ordinary_types = Array(String).new(structure.type_count)
    structure.type_count.times { |index| ordinary_types << structure.type_at(index).name }
    require!(ordinary_types.empty?, "max_types=0 typed Dynamic ordinary roster is not empty")
    JSON::Any.new({
      "schema_declaration"      => JSON::Any.new(schema.declaration),
      "row_count"               => JSON::Any.new(descriptor.row_count.to_i64),
      "mark_count"              => JSON::Any.new(descriptor.mark_count.to_i64),
      "mark_row_counts"         => JSON::Any.new(descriptor.mark_row_counts.map { |rows| JSON::Any.new(rows.to_i64) }),
      "ordinary_dynamic_types"  => JSON::Any.new(ordinary_types.map { |name| JSON::Any.new(name) }),
      "physical_stream_names"   => JSON::Any.new(descriptor.physical_stream_names.map { |name| JSON::Any.new(name) }),
      "selected_checksum_names" => JSON::Any.new(descriptor.selected_checksum_names.map { |name| JSON::Any.new(name) }),
      "windows"                 => JSON::Any.new(profile_windows(part_path, schema, profile_name)),
    })
  end

  private def canonical_part!(path : String, root : String, label : String) : String
    full = File.expand_path(path)
    require!(full.starts_with?(root + File::SEPARATOR), "#{label} escaped its fixed root")
    require!(Dir.exists?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical")
    full
  end

  private def process_case(item : JSON::Any, capture_root : String, output_root : String) : JSON::Any
    require!(item.as_h.keys.sort == ["capture_root", "cell_id", "library_part", "mode_id", "profile_id", "source_part"],
      "case input keys differ")
    require!(item["capture_root"].as_s == capture_root, "case capture root differs")
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
    require!(schema.declaration == DECLARATION, "typed Dynamic declaration canonicalization differs")
    require!(schema.typed_paths.keys == ["p"] && schema.typed_paths["p"].tag == CrystalClick::BinaryDataType::TAG_DYNAMIC,
      "declared typed path differs from JSON(p Dynamic(max_types=0))")
    dynamics = {"p" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths, dynamics)
    granules = fixture
    keys = Slice(UInt64).new(8) { |index| (index + 1).to_u64 }
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      library_part, "pk", keys, "payload", schema, plan, granules,
      rows_per_mark: 2, mode: mode_value, profile: profile_value,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
    )
    require!(plan.typed_dynamic_for("p").type_count == 0, "writer fixture populated ordinary Dynamic bindings")

    JSON::Any.new({
      "cell_id"           => item["cell_id"],
      "profile_id"        => JSON::Any.new(profile_name),
      "mode_id"           => JSON::Any.new(mode_name),
      "library_part_path" => JSON::Any.new(library_part),
      "source"            => side_observation(source_part, schema, profile_name),
      "library"           => side_observation(library_part, schema, profile_name),
    })
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 2
      raise ArgumentError.new("usage: check_object_typed_dynamic_shared_json_w214.cr INPUT.json OUTPUT_ROOT")
    end
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    require!(Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root,
      "output root must be canonical and non-symlinked")
    require!(File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR),
      "helper input must be a plain file below output root")
    input = JSON.parse(File.read(input_path))
    require!(input.as_h.keys.sort == ["capture_root", "cells", "format"] && input["format"].as_s == FORMAT_INPUT,
      "helper input format differs")
    capture_root = input["capture_root"].as_s
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "capture root is not canonical")
    expected = ["single_stream/basic", "single_stream/compact", "with_size_stream/basic", "with_size_stream/compact"]
    cells = input["cells"].as_a
    observed = cells.map { |item| "#{item["profile_id"].as_s}/#{item["mode_id"].as_s}" }
    require!(observed == expected, "fixed profile/mode cell roster differs")
    results = cells.map { |item| process_case(item, capture_root, output_root) }
    puts JSON::Any.new({
      "format"                => JSON::Any.new(FORMAT_OUTPUT),
      "declaration"           => JSON::Any.new(DECLARATION),
      "ordinary_roster_empty" => JSON::Any.new(true),
      "windows"               => JSON::Any.new(WINDOWS.map { |window, first, count|
        JSON::Any.new({
          "window"     => JSON::Any.new(window),
          "first_mark" => JSON::Any.new(first.to_i64),
          "mark_count" => JSON::Any.new(count.to_i64),
        })
      }),
      "cells" => JSON::Any.new(results),
    }).to_json
  rescue ex : Exception
    STDERR.puts "W214 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckObjectTypedDynamicSharedJSONW214.main(ARGV)
