require "json"
require "../src/crystal_click"

module JSONLegacyMapLayoutW254
  extend self

  KEYS   = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  FORMAT = "json_legacy_map_layout_w254_helper_v1"

  def schema : CrystalClick::ObjectDocumentSchema
    CrystalClick::ObjectDocumentSchema.new(
      {
        "tags"  => CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("String")),
        "title" => CrystalClick::BinaryDataType.primitive("String"),
      },
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
    )
  end

  private def document(
    title : String,
    tags : Array(String),
    counter : CrystalClick::BinaryValue,
    spill : String?,
  ) : CrystalClick::ObjectDocument
    string = CrystalClick::BinaryDataType.primitive("String")
    values = Hash(String, CrystalClick::BinaryValue).new
    values["title"] = CrystalClick::BinaryValue.string(title)
    values["tags"] = CrystalClick::BinaryValue.array(
      CrystalClick::BinaryDataType.array(string),
      tags.map { |value| CrystalClick::BinaryValue.string(value) },
    )
    # Object inferred Dynamic values are stored as their actual type.
    values["counter"] = counter
    values["spill"] = CrystalClick::BinaryValue.string(spill) if spill
    CrystalClick::ObjectDocument.new(values)
  end

  def documents : Array(CrystalClick::ObjectDocument)
    [
      document("title-1", [] of String, CrystalClick::BinaryValue.int64(1001_i64), "spill-1"),
      document("", ["tag-2", "common"], CrystalClick::BinaryValue.int64(1002_i64), nil),
      document("title-3", ["tag-3"], CrystalClick::BinaryValue.int64(1003_i64), "spill-3"),
      document("title-4", [] of String, CrystalClick::BinaryValue.int64(1004_i64), nil),
      document("title-5", ["tag-5", "common", "tag-5b"], CrystalClick::BinaryValue.string("counter-five"), "spill-5"),
      document("title-6", ["tag-6"], CrystalClick::BinaryValue.null, nil),
    ] of CrystalClick::ObjectDocument
  end

  def plan(version : UInt64) : CrystalClick::ObjectDocumentPlan
    int64 = CrystalClick::BinaryDataType.primitive("Int64")
    dynamic_counts = CrystalClick::StructureStatistics.new(
      [4_u64, 1_u64] of UInt64,
      [] of CrystalClick::StructureStatistic,
    )
    counter = CrystalClick::DynamicStructure.new(
      [int64] of CrystalClick::BinaryDataType,
      dynamic_counts,
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    object_stats = CrystalClick::StructureStatistics.new(
      [5_u64] of UInt64,
      [CrystalClick::StructureStatistic.new("spill", 3_u64)] of CrystalClick::StructureStatistic,
    )
    object = CrystalClick::ObjectStructure.new(
      ["counter"] of String,
      version: version,
      shared_data_version: 0_u64,
      bucket_count: 1_u64,
      legacy_max_dynamic_paths: version == 0_u64 ? 9_u64 : nil,
      statistics: object_stats,
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {"counter" => counter} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
  end

  def signature(document : CrystalClick::ObjectDocument) : String
    title = document.value_for("title").as_string
    tags_value = document.value_for("tags")
    tags = Array(String).new(tags_value.element_count) do |index|
      tags_value.element_at(index).as_string
    end
    # Object decoding omits inferred Dynamic Nothing, so this fixture does not distinguish it from absence.
    counter = if document.has_path?("counter")
                value = document.value_for("counter")
                if value.type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC
                  value = value.child_at(0)
                end
                case value.type.name
                when "Int64"   then "Int64:#{value.as_int64}"
                when "String"  then "String:#{value.as_string}"
                when "Nothing" then "NULL"
                else                raise CrystalClick::CorruptPartError.new("unexpected counter actual #{value.type.name}")
                end
              else
                "NULL"
              end
    spill = document.has_path?("spill") ? document.value_for("spill").as_string : "ABSENT"
    "#{title}|#{tags.join(",")}|#{counter}|#{spill}"
  end

  def expected_signatures : Array(String)
    [
      "title-1||Int64:1001|spill-1",
      "|tag-2,common|Int64:1002|ABSENT",
      "title-3|tag-3|Int64:1003|spill-3",
      "title-4||Int64:1004|ABSENT",
      "title-5|tag-5,common,tag-5b|String:counter-five|spill-5",
      "title-6|tag-6|NULL|ABSENT",
    ]
  end

  def flattened(marks : Array(Array(CrystalClick::ObjectDocument))) : Array(CrystalClick::ObjectDocument)
    rows = Array(CrystalClick::ObjectDocument).new
    marks.each { |mark| mark.each { |document| rows << document } }
    rows
  end

  def signatures(rows : Array(CrystalClick::ObjectDocument)) : Array(String)
    rows.map { |document| signature(document) }
  end

  def inspect_side(part : String, side : String, object_version : UInt64) : JSON::Any
    schema_value = schema
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      part,
      "payload",
      schema_value.typed_paths,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      hashed: true,
    )
    structure = descriptor.plan.structures.object
    raise CrystalClick::CorruptPartError.new("#{side} Object wire version differs") unless structure.version == object_version
    raise CrystalClick::CorruptPartError.new("#{side} Object MAP roster differs") unless structure.dynamic_paths == ["counter"]
    raise CrystalClick::CorruptPartError.new("#{side} Object positional statistics differ") unless structure.statistics.not_nil!.counts == [5_u64]
    shared = structure.statistics.not_nil!.shared
    raise CrystalClick::CorruptPartError.new("#{side} Object shared MAP statistics differ") unless shared.size == 1 && shared[0].name == "spill" && shared[0].count == 3_u64
    expected_legacy = object_version == 0_u64 ? 1_u64 : nil
    raise CrystalClick::CorruptPartError.new("#{side} canonical V1 legacy path count differs") unless structure.legacy_max_dynamic_paths == expected_legacy
    counter_structure = descriptor.plan.structures.dynamic_for("counter")
    raise CrystalClick::CorruptPartError.new("#{side} counter Dynamic version/roster differs") unless counter_structure.version == CrystalClick::DynamicStructure::VERSION_V3 && counter_structure.types.map(&.name) == ["Int64"]
    raise CrystalClick::CorruptPartError.new("#{side} counter Dynamic statistics differ") unless counter_structure.statistics.not_nil!.counts == [4_u64, 1_u64]

    direct_reader = CrystalClick::ObjectColumnReader.open(part, "payload", schema_value)
    direct_marks = direct_reader.mark_row_counts
    direct_rows = flattened(direct_reader.read_marks(0, direct_marks.size))
    direct_signatures = signatures(direct_rows)
    expected = expected_signatures
    raise CrystalClick::CorruptPartError.new("#{side} direct Object values differ: #{direct_signatures}") unless direct_signatures == expected

    table_signatures = Array(String).new
    table_keys = Array(UInt64).new
    table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
    table.scan_typed_candidate_marks([direct_marks.map_with_index { |_rows, index| index.to_i32 }]) do |batch|
      keys = batch.values_for("pk", UInt64)
      docs = batch.object_documents_for("payload")
      raise CrystalClick::CorruptPartError.new("#{side} public batch row counts differ") unless keys.size == docs.size
      keys.each_with_index do |key, index|
        table_keys << key
        table_signatures << signature(docs[index])
      end
    end
    raise CrystalClick::CorruptPartError.new("#{side} public table values differ") unless table_signatures == expected && table_keys == KEYS.to_a

    info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0") || raise CrystalClick::CorruptPartError.new("part name did not parse")
    candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part, info, 6_u64)
    offline = CrystalClick::OfflineTable.new(
      "w254",
      nil,
      "MergeTree",
      [CrystalClick::OfflineColumn.new("pk", "UInt64"), CrystalClick::OfflineColumn.new("payload", schema_value.declaration)],
      [candidate],
      "pk",
    )
    offline_values = offline["payload"].values
    offline_documents = offline_values.map do |value|
      value.as?(CrystalClick::ObjectDocument) || raise CrystalClick::CorruptPartError.new("#{side} offline value was not ObjectDocument")
    end
    offline_signatures = signatures(offline_documents)
    raise CrystalClick::CorruptPartError.new("#{side} OfflineColumn.values differ") unless offline_signatures == expected

    counter = descriptor.plan.structures.dynamic_for("counter")
    JSON::Any.new({
      "mark_row_counts"                 => JSON::Any.new(direct_marks.map { |rows| JSON::Any.new(rows.to_i64) }),
      "schema_declaration"              => JSON::Any.new(direct_reader.schema_declaration),
      "object_wire_version"             => JSON::Any.new(structure.version.to_i64),
      "object_legacy_max_dynamic_paths" => structure.legacy_max_dynamic_paths ? JSON::Any.new(structure.legacy_max_dynamic_paths.not_nil!.to_i64) : JSON::Any.new(nil),
      "object_dynamic_paths"            => JSON::Any.new(structure.dynamic_paths.map { |path| JSON::Any.new(path) }),
      "object_statistics_counts"        => JSON::Any.new(structure.statistics.not_nil!.counts.map { |count| JSON::Any.new(count.to_i64) }),
      "object_shared_statistics"        => JSON::Any.new(shared.map { |entry| JSON::Any.new({"name" => JSON::Any.new(entry.name), "count" => JSON::Any.new(entry.count.to_i64)}) }),
      "counter_dynamic_version"         => JSON::Any.new(counter.version.to_i64),
      "counter_ordinary_types"          => JSON::Any.new(counter.types.map { |type| JSON::Any.new(type.name) }),
      "counter_statistics_counts"       => JSON::Any.new(counter.statistics.not_nil!.counts.map { |count| JSON::Any.new(count.to_i64) }),
      "direct_rows"                     => JSON::Any.new(direct_signatures.map { |value| JSON::Any.new(value) }),
      "public_table_rows"               => JSON::Any.new(table_signatures.map { |value| JSON::Any.new(value) }),
      "public_table_keys"               => JSON::Any.new(table_keys.map { |value| JSON::Any.new(value.to_i64) }),
      "offline_values"                  => JSON::Any.new(offline_signatures.map { |value| JSON::Any.new(value) }),
      "physical_stream_names"           => JSON::Any.new(direct_reader.physical_stream_names.map { |value| JSON::Any.new(value) }),
      "selected_checksum_names"         => JSON::Any.new(direct_reader.selected_checksum_names.map { |value| JSON::Any.new(value) }),
    })
  end

  def main : Nil
    unless ARGV.size == 3
      STDERR.puts "usage: check_json_legacy_map_layout_w254.cr SOURCE_PART OUTPUT_PART v1|v2"
      exit 2
    end
    source = ARGV[0]
    output = ARGV[1]
    version = case ARGV[2]
              when "v1" then 0_u64
              when "v2" then 2_u64
              else           raise ArgumentError.new("Object version must be v1 or v2")
              end
    raise ArgumentError.new("source part is absent") unless Dir.exists?(source)
    raise ArgumentError.new("output part already exists") if File.exists?(output) || Dir.exists?(output)

    granules = documents.each_slice(2).map(&.to_a).to_a
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      output,
      "pk",
      KEYS,
      "payload",
      schema,
      plan(version),
      granules,
      rows_per_mark: 2,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: 4096,
    )
    source_report = inspect_side(source, "stock_source", version)
    library_report = inspect_side(output, "library_generated", version)
    JSON.build(STDOUT) do |json|
      json.object do
        json.field "format", FORMAT
        json.field "object_version", ARGV[2]
        json.field "source_part", File.expand_path(source)
        json.field "library_part", File.expand_path(output)
        json.field "expected_rows" do
          json.array { expected_signatures.each { |value| json.string(value) } }
        end
        json.field "source", source_report
        json.field "library", library_report
      end
    end
    puts
  end
end

JSONLegacyMapLayoutW254.main
