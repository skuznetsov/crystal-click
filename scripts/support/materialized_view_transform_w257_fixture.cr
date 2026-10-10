require "../../src/crystal_click"
require "json"

module MaterializedViewTransformW257Fixture
  extend self

  FORMAT           = "materialized_view_transform_w257_helper_v1"
  KEY_NAME         = "pk"
  SOURCE_PART_NAME = "all_1_1_0"
  OUTPUT_PART_NAME = "all_9_9_0"
  ROWS_PER_MARK    =  2
  BATCH_ROWS       =  2
  FRAME_BYTES      = 32

  DYNAMIC_DECLARATION  = "Dynamic(max_types=1)"
  DOCUMENT_DECLARATION = "JSON(max_dynamic_types=1, max_dynamic_paths=1, label String, t UInt8)"
  TRACE_DECLARATION    = "Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), sample Dynamic(max_types=1)))"

  SOURCE_TYPES = [
    {"pk", "UInt64"},
    {"score", "UInt64"},
    {"payload", DYNAMIC_DECLARATION},
    {"doc", DOCUMENT_DECLARATION},
    {"trace", TRACE_DECLARATION},
  ] of Tuple(String, String)

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

  def run(catalog_root : String, source_part_name : String, output_part_name : String) : JSON::Any
    unless source_part_name == SOURCE_PART_NAME && output_part_name == OUTPUT_PART_NAME
      raise ArgumentError.new("W257 part names differ from the sealed fixture")
    end

    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    observed_source_rows = 0_u64
    output_keys = [] of UInt64
    output_scores = [] of CrystalClick::BinaryValue
    output_payloads = [] of CrystalClick::BinaryValue
    output_documents = [] of CrystalClick::ObjectDocument
    output_traces = [] of CrystalClick::StorageColumnValue
    observed_source_types = nil.as(Array(Tuple(String, String))?)

    destination = catalog.transform_materialized_view_part(
      "lab", "view", source_part_name, SOURCE_TYPES.map(&.[0]), output_part_name,
      rows_per_mark: ROWS_PER_MARK,
      batch_rows: BATCH_ROWS,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      frame_bytes: FRAME_BYTES,
    ) do |input|
      unless input.row_count == 6_u64 && input.column_names == SOURCE_TYPES.map(&.[0])
        raise CrystalClick::CorruptPartError.new("W257 transform source row count or roster differs")
      end
      types = input.column_types
      unless types == SOURCE_TYPES
        raise CrystalClick::CorruptPartError.new("W257 transform source declarations differ: #{types.inspect}")
      end
      observed_source_types = types

      input.each_batch do |batch|
        keys = batch.values_for(KEY_NAME)
        scores = batch.values_for("score")
        payloads = batch.dynamic_bulk_values_for("payload")
        documents = batch.object_documents_for("doc")
        traces = batch.recursive_values_for("trace")
        unless keys.size == scores.size && keys.size == payloads.size &&
               keys.size == documents.size && keys.size == traces.size
          raise CrystalClick::CorruptPartError.new("W257 transform batch columns are not row-aligned")
        end

        observed_source_rows += keys.size.to_u64
        keys.each_with_index do |key, index|
          next if key < 3_u64

          output_keys << key + 100_u64
          output_scores << CrystalClick::BinaryValue.uint64(scores[index] + 1000_u64)
          output_payloads << transform_dynamic(payloads[index], dynamic_type)
          output_documents << transform_document(documents[index])
          output_traces << transform_trace(traces[index], dynamic_type)
        end
      end

      unless observed_source_rows == 6_u64 && output_keys == [103_u64, 104_u64, 105_u64, 106_u64]
        raise CrystalClick::CorruptPartError.new("W257 transform did not consume/filter the literal source rows")
      end

      CrystalClick::WidePartTransformOutput.new(
        output_keys.to_unsafe.to_slice(output_keys.size),
        output_columns(output_scores, output_payloads, output_documents, output_traces),
      )
    end

    table = CrystalClick::WidePartTable.open_selected_typed(
      [destination], [KEY_NAME, "score", "payload", "doc", "trace"]
    )
    output_rows = collect_output_rows(table)
    expected = expected_rows
    unless table.column_types == SOURCE_TYPES && table.total_row_count == expected.size.to_u64 &&
           table.part_mark_row_counts == [[2_u64, 2_u64]] && output_rows == expected
      raise CrystalClick::CorruptPartError.new("W257 published output readback differs from transformed literals")
    end

    JSON::Any.new({
      "format"                  => JSON::Any.new(FORMAT),
      "source_part_name"        => JSON::Any.new(source_part_name),
      "output_part_name"        => JSON::Any.new(output_part_name),
      "source_row_count"        => JSON::Any.new(observed_source_rows.to_i64),
      "source_types"            => json_types(observed_source_types || [] of Tuple(String, String)),
      "source_selected_columns" => JSON::Any.new(SOURCE_TYPES.map { |name, _| JSON::Any.new(name) }),
      "output_row_count"        => JSON::Any.new(output_rows.size.to_i64),
      "output_mark_rows"        => JSON::Any.new([2, 2].map { |rows| JSON::Any.new(rows) }),
      "output_rows"             => json_rows(output_rows),
      "destination"             => JSON::Any.new(destination),
      "part_files"              => JSON::Any.new(flat_part_files(destination).map { |name| JSON::Any.new(name) }),
    } of String => JSON::Any)
  end

  def expected_rows : Array(ExpectedRow)
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

  private def output_columns(
    scores : Array(CrystalClick::BinaryValue),
    payloads : Array(CrystalClick::BinaryValue),
    documents : Array(CrystalClick::ObjectDocument),
    traces : Array(CrystalClick::StorageColumnValue),
  ) : Array(CrystalClick::WidePartColumn)
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DOCUMENT_DECLARATION)
    object_plan = empty_object_plan(schema)
    recursive_schema = CrystalClick::StorageColumnSchema.parse(TRACE_DECLARATION)
    recursive_document_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(
      "JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)"
    )
    recursive_object_plans = {
      "root/array[0]/tuple[0]" => empty_object_plan(recursive_document_schema),
    }
    recursive_dynamic_plans = {
      "root/array[0]/tuple[1]" => CrystalClick::BinaryDynamicBulkPlan.new(
        dynamic_type,
        {"root" => dynamic_structure},
        CrystalClick::BinaryBulkProfile.with_size_stream,
      ),
    }
    [
      CrystalClick::WidePartColumn.binary_bulk("score", uint64_type, grouped(scores)),
      CrystalClick::WidePartColumn.dynamic_bulk(
        "payload", dynamic_type, {"root" => dynamic_structure}, grouped(payloads),
      ),
      CrystalClick::WidePartColumn.object("doc", schema, object_plan, grouped(documents)),
      CrystalClick::WidePartColumn.recursive(
        "trace", recursive_schema, recursive_object_plans, grouped(traces), recursive_dynamic_plans,
      ),
    ] of CrystalClick::WidePartColumn
  end

  private def transform_dynamic(value : CrystalClick::BinaryValue, type : CrystalClick::BinaryDataType) : CrystalClick::BinaryValue
    unless value.type == type
      raise CrystalClick::CorruptPartError.new("W257 Dynamic input descriptor differs")
    end
    return CrystalClick::BinaryValue.dynamic(type) if value.is_null?

    child = value.child_at(0)
    transformed = case child.type.name
                  when "UInt64"
                    CrystalClick::BinaryValue.uint64(child.as_uint64 + 1000_u64)
                  when "String"
                    CrystalClick::BinaryValue.string(child.as_string + "!")
                  else
                    raise CrystalClick::UnsupportedFormatError.new("W257 fixture encountered an unexpected Dynamic actual type")
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

  private def transform_trace(value : CrystalClick::StorageColumnValue, type : CrystalClick::BinaryDataType) : CrystalClick::StorageColumnValue
    unless value.array?
      raise CrystalClick::CorruptPartError.new("W257 recursive input is not an Array")
    end
    children = value.array_values.map do |tuple|
      unless tuple.tuple? && tuple.child_count == 2
        raise CrystalClick::CorruptPartError.new("W257 recursive input row is not the declared Tuple")
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

  private def collect_output_rows(table : CrystalClick::WidePartTable) : Array(ExpectedRow)
    rows = [] of ExpectedRow
    table.scan_typed do |batch|
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
    when "UInt64"
      {:uint64, child.as_uint64}
    when "String"
      {:string, child.as_string}
    else
      raise CrystalClick::CorruptPartError.new("W257 readback has an unexpected Dynamic actual type")
    end
  end

  private def trace_pairs(value : CrystalClick::StorageColumnValue) : Array(ExpectedTraceItem)
    value.array_values.map do |tuple|
      document = tuple.child_at(0).object_document
      sample = tuple.child_at(1).bulk_value
      {document.value_for("t").byte_at(0), dynamic_pair(sample)}
    end
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

  private def flat_part_files(path : String) : Array(String)
    raise CrystalClick::CorruptPartError.new("W257 output part is not a real directory") if File.symlink?(path) || !Dir.exists?(path)
    entries = Dir.children(path).sort!
    entries.each do |name|
      child = File.join(path, name)
      if File.symlink?(child) || Dir.exists?(child) || !File.file?(child)
        raise CrystalClick::CorruptPartError.new("W257 output PART is not a flat regular-file tree")
      end
    end
    entries
  end

  private def empty_object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
    CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new([] of String),
        {} of String => CrystalClick::DynamicStructure,
      ),
      schema.typed_paths,
    )
  end

  private def dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  private def uint64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt64")
  end

  private def dynamic_structure : CrystalClick::DynamicStructure
    CrystalClick::DynamicStructure.new([uint64_type] of CrystalClick::BinaryDataType)
  end

  private def byte_value(value : UInt8) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[value])
  end

  private def grouped(values : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
    values.each_slice(ROWS_PER_MARK).map(&.to_a).to_a
  end

  private def grouped(values : Array(CrystalClick::ObjectDocument)) : Array(Array(CrystalClick::ObjectDocument))
    values.each_slice(ROWS_PER_MARK).map(&.to_a).to_a
  end

  private def grouped(values : Array(CrystalClick::StorageColumnValue)) : Array(Array(CrystalClick::StorageColumnValue))
    values.each_slice(ROWS_PER_MARK).map(&.to_a).to_a
  end
end
