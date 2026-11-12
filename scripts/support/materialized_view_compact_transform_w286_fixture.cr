require "../../src/crystal_click"
require "json"

module MaterializedViewCompactTransformW286Fixture
  extend self

  FORMAT                     = "materialized_view_compact_transform_w286_helper_v1"
  TARGET_UUID                = "f2860000-7b7f-4e2f-9e44-dc13a87b8803"
  KEY_NAME                   = "pk"
  SOURCE_PART_NAME           = "all_1_1_0"
  ROWS_PER_MARK              =     2
  BATCH_ROWS                 =     2
  OUTPUT_ROW_COUNT           = 4_u64
  SOURCE_ROW_COUNT           = 6_u64
  DYNAMIC_DECLARATION        = "Dynamic(max_types=1)"
  DOCUMENT_DECLARATION       = "JSON(max_dynamic_types=1, max_dynamic_paths=1, label String, t UInt8)"
  TRACE_DECLARATION          = "Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), sample Dynamic(max_types=1)))"
  TRACE_DOCUMENT_DECLARATION = "JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)"

  SOURCE_TYPES = [
    {"pk", "UInt64"},
    {"score", "UInt64"},
    {"payload", DYNAMIC_DECLARATION},
    {"doc", DOCUMENT_DECLARATION},
    {"trace", TRACE_DECLARATION},
  ] of Tuple(String, String)

  SELECTED_COLUMNS        = SOURCE_TYPES.map(&.[0])
  TRACE_JSON_SITE_PATH    = "root/array[0]/tuple[0]"
  TRACE_DYNAMIC_SITE_PATH = "root/array[0]/tuple[1]"
  DYNAMIC_LOCAL_SITE_PATH = "root"

  alias DynamicPair = Tuple(Symbol, UInt64 | String | Nil)
  alias ExpectedTraceItem = Tuple(UInt8, DynamicPair)
  alias ExpectedRow = NamedTuple(
    pk: UInt64,
    score: UInt64,
    payload: DynamicPair,
    label: String,
    document_t: UInt8,
    trace: Array(ExpectedTraceItem),
  )

  def run(
    catalog_root : String,
    source_part_name : String,
    output_part_name : String,
    mark_name : String,
    profile_name : String,
    action : String,
  ) : JSON::Any
    unless source_part_name == SOURCE_PART_NAME
      raise ArgumentError.new("W286 source part name differs from the sealed native fixture")
    end
    unless {"mrk3", "mrk4"}.includes?(mark_name)
      raise ArgumentError.new("W286 mark format must be mrk3 or mrk4")
    end
    unless {"s0", "s1"}.includes?(profile_name)
      raise ArgumentError.new("W286 String profile must be s0 or s1")
    end
    unless {"publish", "refuse"}.includes?(action)
      raise ArgumentError.new("W286 action must be publish or refuse")
    end

    mark_format = compact_mark_format(mark_name)
    profile = string_profile(profile_name)
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)

    if action == "refuse"
      refusal_report(catalog, catalog_root, source_part_name, output_part_name, mark_format, profile_name)
    else
      publication_report(catalog, catalog_root, source_part_name, output_part_name, mark_format, mark_name, profile, profile_name)
    end
  end

  private def publication_report(
    catalog : CrystalClick::OfflineCatalog,
    catalog_root : String,
    source_part_name : String,
    output_part_name : String,
    mark_format : CrystalClick::CompactMarkFormat,
    mark_name : String,
    profile : CrystalClick::BinaryBulkProfile,
    profile_name : String,
  ) : JSON::Any
    observed_source_rows = 0_u64
    output_keys = [] of UInt64
    output_scores = [] of CrystalClick::BinaryValue
    output_payloads = [] of CrystalClick::BinaryValue
    output_documents = [] of CrystalClick::ObjectDocument
    output_traces = [] of CrystalClick::StorageColumnValue
    observed_source_types = nil.as(Array(Tuple(String, String))?)

    destination = catalog.transform_materialized_view_part(
      "lab", "view", source_part_name, SELECTED_COLUMNS, output_part_name,
      mark_format: mark_format,
      rows_per_mark: ROWS_PER_MARK,
      batch_rows: BATCH_ROWS,
      profile: profile,
    ) do |input|
      unless input.row_count == SOURCE_ROW_COUNT && input.column_names == SELECTED_COLUMNS
        raise CrystalClick::CorruptPartError.new("W286 source row count or selected roster differs")
      end
      types = input.column_types
      unless types == SOURCE_TYPES
        raise CrystalClick::CorruptPartError.new("W286 source declarations differ: #{types.inspect}")
      end
      observed_source_types = types

      dynamic = dynamic_type
      input.each_batch do |batch|
        keys = batch.values_for(KEY_NAME)
        scores = batch.values_for("score")
        payloads = batch.dynamic_bulk_values_for("payload")
        documents = batch.object_documents_for("doc")
        traces = batch.recursive_values_for("trace")
        unless keys.size == scores.size && keys.size == payloads.size &&
               keys.size == documents.size && keys.size == traces.size
          raise CrystalClick::CorruptPartError.new("W286 source batch columns are not row-aligned")
        end

        observed_source_rows += keys.size.to_u64
        keys.each_with_index do |key, index|
          next if key < 3_u64

          output_keys << key + 100_u64
          output_scores << CrystalClick::BinaryValue.uint64(scores[index] + 1000_u64)
          output_payloads << transform_dynamic(payloads[index], dynamic)
          output_documents << transform_document(documents[index])
          output_traces << transform_trace(traces[index], dynamic)
        end
      end

      unless observed_source_rows == SOURCE_ROW_COUNT &&
             output_keys == [103_u64, 104_u64, 105_u64, 106_u64]
        raise CrystalClick::CorruptPartError.new("W286 callback did not consume and filter the source literals")
      end

      CrystalClick::CompactPartTransformOutput.new(
        output_keys.to_unsafe.to_slice(output_keys.size),
        compact_columns(output_scores, output_payloads, output_documents, output_traces),
      )
    end

    table = CrystalClick::CompactPartTable.open_selected_typed([destination], SELECTED_COLUMNS)
    output_rows = collect_output_rows(table)
    expected = expected_rows
    expected_types = SOURCE_TYPES
    unless table.column_types == expected_types && table.total_row_count == OUTPUT_ROW_COUNT &&
           table.part_mark_row_counts == [[2_u64, 2_u64]] && output_rows == expected
      raise CrystalClick::CorruptPartError.new("W286 Compact output readback differs from independent transformed literals")
    end

    assert_profile!(destination, mark_format, profile, profile_name)
    files = flat_part_files(destination)
    mark_files = files.select { |name| name.ends_with?(".mrk3") || name.ends_with?(".mrk4") }
    unless !mark_files.empty? && mark_files.all? { |name| name.ends_with?(".#{mark_name}") }
      raise CrystalClick::CorruptPartError.new("W286 Compact mark file layout differs from #{mark_name}: #{mark_files.inspect}")
    end

    JSON::Any.new({
      "format"                  => JSON::Any.new(FORMAT),
      "action"                  => JSON::Any.new("publish"),
      "mark_format"             => JSON::Any.new(mark_name),
      "string_profile"          => JSON::Any.new(profile_name),
      "status"                  => JSON::Any.new("ok"),
      "part_type"               => JSON::Any.new("Compact"),
      "source_part_name"        => JSON::Any.new(source_part_name),
      "output_part_name"        => JSON::Any.new(output_part_name),
      "source_row_count"        => JSON::Any.new(observed_source_rows.to_i64),
      "source_types"            => json_types(observed_source_types || [] of Tuple(String, String)),
      "source_selected_columns" => JSON::Any.new(SELECTED_COLUMNS.map { |name| JSON::Any.new(name) }),
      "output_row_count"        => JSON::Any.new(output_rows.size.to_i64),
      "output_mark_rows"        => JSON::Any.new([2, 2].map { |rows| JSON::Any.new(rows) }),
      "output_rows"             => json_rows(output_rows),
      "destination"             => JSON::Any.new(destination),
      "part_files"              => JSON::Any.new(files.map { |name| JSON::Any.new(name) }),
      "mark_files"              => JSON::Any.new(mark_files.map { |name| JSON::Any.new(name) }),
    } of String => JSON::Any)
  end

  private def refusal_report(
    catalog : CrystalClick::OfflineCatalog,
    catalog_root : String,
    source_part_name : String,
    output_part_name : String,
    mark_format : CrystalClick::CompactMarkFormat,
    profile_name : String,
  ) : JSON::Any
    callback_calls = 0
    observed_source_rows = 0_u64
    destination = File.join(catalog_root, "store", TARGET_UUID[0, 3], TARGET_UUID, "detached", output_part_name)

    begin
      catalog.transform_materialized_view_part(
        "lab", "view", source_part_name, SELECTED_COLUMNS, output_part_name,
        mark_format: mark_format,
        rows_per_mark: ROWS_PER_MARK,
        batch_rows: BATCH_ROWS,
        profile: string_profile(profile_name),
      ) do |input|
        callback_calls += 1
        input.each_batch do |batch|
          observed_source_rows += batch.values_for(KEY_NAME).size.to_u64
        end
        bad_values = Array(CrystalClick::BinaryValue).new(4) do |index|
          CrystalClick::BinaryValue.string("refusal-#{index}")
        end
        bad_column = CrystalClick::CompactPartColumn.binary_bulk(
          "wrong", CrystalClick::BinaryDataType.primitive("String"), grouped_binary(bad_values),
        )
        CrystalClick::CompactPartTransformOutput.new(
          Slice[103_u64, 104_u64, 105_u64, 106_u64],
          [bad_column] of CrystalClick::CompactPartColumn,
        )
      end
      raise CrystalClick::CorruptPartError.new("W286 invalid output roster was unexpectedly admitted")
    rescue error : CrystalClick::UnsupportedFormatError
      unless error.message == "prepared Compact columns do not match the bound target schema"
        raise CrystalClick::CorruptPartError.new("W286 refusal error differs: #{error.message}")
      end
      unless callback_calls == 1 && observed_source_rows == SOURCE_ROW_COUNT
        raise CrystalClick::CorruptPartError.new("W286 refusal did not follow one complete callback scan")
      end
      if File.exists?(destination) || File.symlink?(destination)
        raise CrystalClick::CorruptPartError.new("W286 refusal left the requested destination behind")
      end

      JSON::Any.new({
        "format"             => JSON::Any.new(FORMAT),
        "action"             => JSON::Any.new("refuse"),
        "mark_format"        => JSON::Any.new(mark_format_name(mark_format)),
        "string_profile"     => JSON::Any.new(profile_name),
        "status"             => JSON::Any.new("rejected_after_complete_scan"),
        "error_class"        => JSON::Any.new(error.class.name),
        "error_message"      => JSON::Any.new(error.message),
        "source_row_count"   => JSON::Any.new(observed_source_rows.to_i64),
        "callback_calls"     => JSON::Any.new(callback_calls),
        "destination"        => JSON::Any.new(destination),
        "destination_absent" => JSON::Any.new(true),
      } of String => JSON::Any)
    end
  end

  private def compact_columns(
    scores : Array(CrystalClick::BinaryValue),
    payloads : Array(CrystalClick::BinaryValue),
    documents : Array(CrystalClick::ObjectDocument),
    traces : Array(CrystalClick::StorageColumnValue),
  ) : Array(CrystalClick::CompactPartColumn)
    document_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DOCUMENT_DECLARATION)
    document_column_schema = CrystalClick::StorageColumnSchema.object(document_schema, DOCUMENT_DECLARATION)
    document_context = CrystalClick::CompactJsonWriteContext.new(
      {"root" => object_plan(document_schema)} of String => CrystalClick::ObjectDocumentPlan,
    )
    trace_schema = CrystalClick::StorageColumnSchema.parse(TRACE_DECLARATION)
    trace_document_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(TRACE_DOCUMENT_DECLARATION)
    trace_context = CrystalClick::CompactJsonWriteContext.new(
      {TRACE_JSON_SITE_PATH => object_plan(trace_document_schema)} of String => CrystalClick::ObjectDocumentPlan,
    )
    dynamic_context = compact_dynamic_context
    trace_dynamic_contexts = {
      TRACE_DYNAMIC_SITE_PATH => dynamic_context,
    } of String => CrystalClick::CompactDynamicWriteContext

    [
      CrystalClick::CompactPartColumn.binary_bulk(
        "score", uint64_type, grouped_binary(scores),
      ),
      CrystalClick::CompactPartColumn.dynamic_bulk(
        "payload", dynamic_type, grouped_binary(payloads), dynamic_context,
      ),
      CrystalClick::CompactPartColumn.json(
        "doc", document_column_schema,
        grouped_storage(documents.map { |document| CrystalClick::StorageColumnValue.object_document(document) }),
        document_context,
      ),
      CrystalClick::CompactPartColumn.json(
        "trace", trace_schema, grouped_storage(traces), trace_context,
        dynamic_contexts: trace_dynamic_contexts,
      ),
    ] of CrystalClick::CompactPartColumn
  end

  private def assert_profile!(
    path : String,
    mark_format : CrystalClick::CompactMarkFormat,
    profile : CrystalClick::BinaryBulkProfile,
    profile_name : String,
  ) : Nil
    expected_marks = [[2_u64, 2_u64]]
    payload_reader = CrystalClick::CompactDynamicBulkColumnReader.open(path, "payload", dynamic_type)
    document_reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
      path, "doc", CrystalClick::StorageColumnSchema.object(
      CrystalClick::ObjectDocumentSchema.parse_declaration(DOCUMENT_DECLARATION), DOCUMENT_DECLARATION,
    ),
    )
    trace_reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
      path, "trace", CrystalClick::StorageColumnSchema.parse(TRACE_DECLARATION),
    )
    unless payload_reader.ordinary_profile == profile && document_reader.ordinary_profile == profile &&
           trace_reader.ordinary_profile == profile && payload_reader.mark_row_counts == expected_marks.first &&
           document_reader.mark_row_counts == expected_marks.first && trace_reader.mark_row_counts == expected_marks.first
      raise CrystalClick::CorruptPartError.new("W286 String profile or per-column mark grid differs from #{profile_name}")
    end

    expected_suffix = mark_format == CrystalClick::CompactMarkFormat::Mrk3 ? ".mrk3" : ".mrk4"
    files = flat_part_files(path)
    marks = files.select { |name| name.ends_with?(".mrk3") || name.ends_with?(".mrk4") }
    unless !marks.empty? && marks.all? { |name| name.ends_with?(expected_suffix) }
      raise CrystalClick::CorruptPartError.new("W286 requested mark format does not match part files")
    end
  end

  private def compact_mark_format(name : String) : CrystalClick::CompactMarkFormat
    case name
    when "mrk3" then CrystalClick::CompactMarkFormat::Mrk3
    when "mrk4" then CrystalClick::CompactMarkFormat::Mrk4
    else             raise ArgumentError.new("unsupported W286 mark format")
    end
  end

  private def mark_format_name(format : CrystalClick::CompactMarkFormat) : String
    format == CrystalClick::CompactMarkFormat::Mrk3 ? "mrk3" : "mrk4"
  end

  private def string_profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "s0" then CrystalClick::BinaryBulkProfile.single_stream
    when "s1" then CrystalClick::BinaryBulkProfile.with_size_stream
    else           raise ArgumentError.new("unsupported W286 String profile")
    end
  end

  private def transform_dynamic(
    value : CrystalClick::BinaryValue,
    type : CrystalClick::BinaryDataType,
  ) : CrystalClick::BinaryValue
    unless value.type == type
      raise CrystalClick::CorruptPartError.new("W286 source Dynamic descriptor differs")
    end
    return CrystalClick::BinaryValue.dynamic(type) if value.is_null?

    child = value.child_at(0)
    transformed = case child.type.name
                  when "UInt64"
                    CrystalClick::BinaryValue.uint64(child.as_uint64 + 1000_u64)
                  when "String"
                    CrystalClick::BinaryValue.string(child.as_string + "!")
                  else
                    raise CrystalClick::UnsupportedFormatError.new("W286 fixture encountered an unexpected Dynamic actual type")
                  end
    CrystalClick::BinaryValue.dynamic(type, transformed)
  end

  private def transform_document(document : CrystalClick::ObjectDocument) : CrystalClick::ObjectDocument
    label = document.value_for("label").as_string + "!"
    tag = document.value_for("t").byte_at(0)
    CrystalClick::ObjectDocument.new({
      "label" => CrystalClick::BinaryValue.string(label),
      "t"     => byte_value(tag + 10_u8),
    } of String => CrystalClick::BinaryValue)
  end

  private def transform_trace(
    value : CrystalClick::StorageColumnValue,
    type : CrystalClick::BinaryDataType,
  ) : CrystalClick::StorageColumnValue
    unless value.array?
      raise CrystalClick::CorruptPartError.new("W286 recursive source is not an Array")
    end
    children = value.array_values.map do |tuple|
      unless tuple.tuple? && tuple.child_count == 2
        raise CrystalClick::CorruptPartError.new("W286 recursive source row is not the declared Tuple")
      end
      source_document = tuple.child_at(0).object_document
      source_sample = tuple.child_at(1).bulk_value
      target_document = CrystalClick::ObjectDocument.new({
        "t" => byte_value(source_document.value_for("t").byte_at(0) + 10_u8),
      } of String => CrystalClick::BinaryValue)
      target_sample = transform_dynamic(source_sample, type)
      CrystalClick::StorageColumnValue.tuple([
        CrystalClick::StorageColumnValue.object_document(target_document),
        CrystalClick::StorageColumnValue.bulk(target_sample),
      ] of CrystalClick::StorageColumnValue)
    end
    CrystalClick::StorageColumnValue.array(children)
  end

  private def collect_output_rows(table : CrystalClick::CompactPartTable) : Array(ExpectedRow)
    rows = [] of ExpectedRow
    table.scan_typed(batch_rows: BATCH_ROWS) do |batch|
      keys = batch.values_for(KEY_NAME)
      scores = batch.values_for("score")
      payloads = batch.dynamic_bulk_values_for("payload")
      documents = batch.object_documents_for("doc")
      traces = batch.recursive_values_for("trace")
      keys.each_index do |index|
        document = documents[index]
        rows << {
          pk: keys[index], score: scores[index], payload: dynamic_pair(payloads[index]),
          label: document.value_for("label").as_string,
          document_t: document.value_for("t").byte_at(0),
          trace: trace_pairs(traces[index]),
        }
      end
      nil
    end
    rows
  end

  private def dynamic_pair(value : CrystalClick::BinaryValue) : DynamicPair
    return {:null, nil} if value.is_null?
    child = value.child_at(0)
    case child.type.name
    when "UInt64" then {:uint64, child.as_uint64}
    when "String" then {:string, child.as_string}
    else               raise CrystalClick::CorruptPartError.new("W286 readback has an unexpected Dynamic arm")
    end
  end

  private def trace_pairs(value : CrystalClick::StorageColumnValue) : Array(ExpectedTraceItem)
    value.array_values.map do |tuple|
      document = tuple.child_at(0).object_document
      sample = tuple.child_at(1).bulk_value
      {document.value_for("t").byte_at(0), dynamic_pair(sample)}
    end
  end

  private def expected_rows : Array(ExpectedRow)
    [
      {pk: 103_u64, score: 1030_u64, payload: {:uint64, 1030_u64}, label: "a\0b!", document_t: 13_u8,
       trace: [] of ExpectedTraceItem},
      {pk: 104_u64, score: 1040_u64, payload: {:string, "spill!"}, label: "!", document_t: 14_u8,
       trace: [{14_u8, {:uint64, 1040_u64}}] of ExpectedTraceItem},
      {pk: 105_u64, score: 1050_u64, payload: {:uint64, 1050_u64}, label: "café!", document_t: 15_u8,
       trace: [{15_u8, {:string, "child!"}}, {16_u8, {:null, nil}}] of ExpectedTraceItem},
      {pk: 106_u64, score: 1060_u64, payload: {:null, nil}, label: "tail!", document_t: 16_u8,
       trace: [{17_u8, {:uint64, 1060_u64}}] of ExpectedTraceItem},
    ] of ExpectedRow
  end

  private def json_rows(rows : Array(ExpectedRow)) : JSON::Any
    JSON::Any.new(rows.map do |row|
      JSON::Any.new({
        "pk"      => JSON::Any.new(row[:pk].to_i64),
        "score"   => JSON::Any.new(row[:score].to_i64),
        "payload" => json_dynamic(row[:payload]),
        "doc"     => JSON::Any.new({
          "label" => JSON::Any.new(row[:label]),
          "t"     => JSON::Any.new(row[:document_t].to_i),
        } of String => JSON::Any),
        "trace" => JSON::Any.new(row[:trace].map do |tag, sample|
          JSON::Any.new({
            "doc_t"  => JSON::Any.new(tag.to_i),
            "sample" => json_dynamic(sample),
          } of String => JSON::Any)
        end),
      } of String => JSON::Any)
    end)
  end

  private def json_dynamic(value : DynamicPair) : JSON::Any
    kind, scalar = value
    result = {"kind" => JSON::Any.new(kind.to_s)} of String => JSON::Any
    if item = scalar
      result["value"] = item.is_a?(UInt64) ? JSON::Any.new(item.to_i64) : JSON::Any.new(item.as(String))
    end
    JSON::Any.new(result)
  end

  private def json_types(types : Array(Tuple(String, String))) : JSON::Any
    JSON::Any.new(types.map do |name, declaration|
      JSON::Any.new({"name" => JSON::Any.new(name), "type" => JSON::Any.new(declaration)} of String => JSON::Any)
    end)
  end

  private def object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
    object = CrystalClick::ObjectStructure.new(
      [] of String,
      version: 4_u64,
      shared_data_version: 0_u64,
      bucket_count: 1_u64,
      statistics: CrystalClick::StructureStatistics.new(
        [] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
  end

  private def compact_dynamic_context : CrystalClick::CompactDynamicWriteContext
    statistics = CrystalClick::StructureStatistics.new(
      [1_u64, 2_u64],
      [CrystalClick::StructureStatistic.new("String", 1_u64)] of CrystalClick::StructureStatistic,
    )
    structure = CrystalClick::DynamicStructure.new(
      [uint64_type] of CrystalClick::BinaryDataType,
      statistics: statistics,
    )
    CrystalClick::CompactDynamicWriteContext.new(
      {DYNAMIC_LOCAL_SITE_PATH => structure} of String => CrystalClick::DynamicStructure,
    )
  end

  private def dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  private def uint64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt64")
  end

  private def byte_value(value : UInt8) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[value])
  end

  private def grouped_binary(values : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
    values.each_slice(ROWS_PER_MARK).map(&.to_a).to_a
  end

  private def grouped_storage(values : Array(CrystalClick::StorageColumnValue)) : Array(Array(CrystalClick::StorageColumnValue))
    values.each_slice(ROWS_PER_MARK).map(&.to_a).to_a
  end

  private def flat_part_files(path : String) : Array(String)
    raise CrystalClick::CorruptPartError.new("W286 output part is not a real directory") if File.symlink?(path) || !Dir.exists?(path)
    entries = Dir.children(path).sort!
    entries.each do |name|
      child = File.join(path, name)
      if File.symlink?(child) || Dir.exists?(child) || !File.file?(child)
        raise CrystalClick::CorruptPartError.new("W286 output part is not a flat regular-file tree")
      end
    end
    entries
  end
end
