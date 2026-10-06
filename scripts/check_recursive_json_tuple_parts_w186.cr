require "../src/crystal_click"
require "json"

module CheckRecursiveJSONTuplePartsW186
  extend self

  JsonType  = "JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)"
  TupleType = "Tuple(l #{JsonType}, r #{JsonType}, n UInt64)"
  COLUMN    = "pair"
  KEY       = "pk"

  def usage : NoReturn
    STDERR.puts "usage: check_recursive_json_tuple_parts_w186 STOCK_TUPLE_JSON_PART LIBRARY_PART_DESTINATION"
    exit 64
  end

  private def object_plan(
    schema : CrystalClick::ObjectDocumentSchema,
    dynamic_path : String,
    dynamic_type : CrystalClick::BinaryDataType,
  ) : CrystalClick::ObjectDocumentPlan
    object = CrystalClick::ObjectStructure.new([dynamic_path] of String)
    dynamics = {
      dynamic_path => CrystalClick::DynamicStructure.new([dynamic_type] of CrystalClick::BinaryDataType),
    } of String => CrystalClick::DynamicStructure
    structures = CrystalClick::ObjectDynamicStructureSet.new(object, dynamics)
    CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
  end

  private def document(
    typed : UInt8,
    dynamic_path : String,
    dynamic_value : CrystalClick::BinaryValue,
    shared : String?,
  ) : CrystalClick::ObjectDocument
    values = {
      "t" => CrystalClick::BinaryValue.fixed(
        CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[typed]
      ),
      dynamic_path => dynamic_value,
    } of String => CrystalClick::BinaryValue
    if value = shared
      values["z_shared"] = CrystalClick::BinaryValue.string(value)
    end
    CrystalClick::ObjectDocument.new(values)
  end

  private def row_value(
    pk : UInt64,
    left_schema : CrystalClick::ObjectDocumentSchema,
    right_schema : CrystalClick::ObjectDocumentSchema,
  ) : CrystalClick::StorageColumnValue
    left_shared = pk == 1_u64 ? "left-shared" : nil
    right_shared = pk == 1_u64 ? "right-shared" : nil
    left = document(
      pk.to_u8,
      "a_left",
      CrystalClick::BinaryValue.int64((pk + 10_u64).to_i64),
      left_shared,
    )
    right = document(
      (pk + 20_u64).to_u8,
      "b_right",
      CrystalClick::BinaryValue.string("right-#{pk}"),
      right_shared,
    )

    # The arguments retain the site schemas as an explicit check that both
    # independently planned Object leaves have the same nominal declaration.
    unless left_schema.declaration == right_schema.declaration
      raise CrystalClick::UnsupportedFormatError.new("Tuple JSON site declarations differ")
    end
    CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.object_document(left),
      CrystalClick::StorageColumnValue.object_document(right),
      CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(pk * 100_u64)),
    ] of CrystalClick::StorageColumnValue)
  end

  private def granules(
    left_schema : CrystalClick::ObjectDocumentSchema,
    right_schema : CrystalClick::ObjectDocumentSchema,
  ) : Array(Array(CrystalClick::StorageColumnValue))
    rows = [] of CrystalClick::StorageColumnValue
    8.times do |index|
      rows << row_value((index + 1).to_u64, left_schema, right_schema)
    end
    marks = [] of Array(CrystalClick::StorageColumnValue)
    0.step(to: 6, by: 2) do |index|
      marks << [rows[index], rows[index + 1]] of CrystalClick::StorageColumnValue
    end
    marks
  end

  private def json_document(
    document : CrystalClick::ObjectDocument,
    dynamic_path : String,
    dynamic_kind : String,
  ) : JSON::Any
    fields = {} of String => JSON::Any
    fields["t"] = JSON::Any.new(document.value_for("t").bytes[0].to_i64)
    dynamic = document.value_for(dynamic_path)
    fields[dynamic_path] = case dynamic_kind
                           when "Int64"
                             JSON::Any.new(dynamic.as_int64)
                           when "String"
                             JSON::Any.new(dynamic.as_string)
                           else
                             raise CrystalClick::CorruptPartError.new("unexpected Dynamic leaf type")
                           end
    if document.has_path?("z_shared")
      fields["z_shared"] = JSON::Any.new(document.value_for("z_shared").as_string)
    end
    JSON::Any.new(fields)
  end

  private def row_signature(pk : UInt64, value : CrystalClick::StorageColumnValue) : JSON::Any
    tuple = value.tuple_values
    unless tuple.size == 3
      raise CrystalClick::CorruptPartError.new("Tuple JSON row has the wrong child count")
    end
    left = tuple[0].object_document
    right = tuple[1].object_document
    n = tuple[2].bulk_value.as_uint64
    JSON::Any.new([
      JSON::Any.new(pk.to_s),
      JSON::Any.new(n.to_s),
      json_document(left, "a_left", "Int64"),
      json_document(right, "b_right", "String"),
    ] of JSON::Any)
  end

  private def signatures(
    marks : Array(Array(CrystalClick::StorageColumnValue)),
    first_parent_row : UInt64,
  ) : Array(JSON::Any)
    result = [] of JSON::Any
    row_index = first_parent_row
    marks.each do |mark|
      mark.each do |value|
        result << row_signature(row_index + 1_u64, value)
        row_index += 1_u64
      end
    end
    result
  end

  private def reader_record(
    part : String,
    schema : CrystalClick::StorageColumnSchema,
  ) : Hash(String, JSON::Any)
    reader = CrystalClick::RecursiveStorageColumnReader.open(part, COLUMN, schema)
    full = reader.read_marks(0, reader.mark_count)
    middle = reader.read_marks(1, 2)
    {
      "schema_declaration"      => JSON::Any.new(reader.schema_declaration),
      "source_declaration"      => JSON::Any.new(reader.source_declaration),
      "row_count"               => JSON::Any.new(reader.row_count.to_i64),
      "mark_count"              => JSON::Any.new(reader.mark_count.to_i64),
      "mark_row_counts"         => JSON::Any.new(reader.mark_row_counts.map { |value| JSON::Any.new(value.to_i64) }),
      "physical_stream_names"   => JSON::Any.new(reader.physical_stream_names.map { |value| JSON::Any.new(value) }),
      "selected_checksum_names" => JSON::Any.new(reader.selected_checksum_names.map { |value| JSON::Any.new(value) }),
      "logical_read_bytes"      => JSON::Any.new(reader.logical_read_bytes.to_i64),
      "full_rows"               => JSON::Any.new(signatures(full, 0_u64)),
      "middle_rows"             => JSON::Any.new(signatures(middle, 2_u64)),
    } of String => JSON::Any
  end

  private def table_signatures(table : CrystalClick::WidePartTable) : Array(JSON::Any)
    rows = [] of JSON::Any
    table.scan_typed(batch_rows: 2) do |batch|
      keys = batch.values_for(KEY)
      values = batch.recursive_values_for(COLUMN)
      unless keys.size == values.size
        raise CrystalClick::CorruptPartError.new("primary-key and recursive Tuple batch widths differ")
      end
      keys.size.times { |index| rows << row_signature(keys[index], values[index]) }
      nil
    end
    rows
  end

  private def table_middle_signatures(table : CrystalClick::WidePartTable) : Array(JSON::Any)
    rows = [] of JSON::Any
    table.scan_typed_window(2_u64, max_rows: 4) do |batch|
      keys = batch.values_for(KEY)
      values = batch.recursive_values_for(COLUMN)
      unless keys.size == values.size
        raise CrystalClick::CorruptPartError.new("primary-key and recursive Tuple window widths differ")
      end
      keys.size.times { |index| rows << row_signature(keys[index], values[index]) }
      nil
    end
    rows
  end

  private def run(stock_part : String, library_part : String) : Nil
    tuple_schema = CrystalClick::StorageColumnSchema.parse(TupleType)
    unless tuple_schema.canonical_declaration == TupleType &&
           tuple_schema.json_site_keys == ["root/tuple[0]", "root/tuple[1]"]
      raise CrystalClick::UnsupportedFormatError.new("recursive Tuple JSON schema site identities differ")
    end

    left_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(JsonType)
    right_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(JsonType)
    object_plans = {
      "root/tuple[0]" => object_plan(left_schema, "a_left", CrystalClick::BinaryDataType.primitive("Int64")),
      "root/tuple[1]" => object_plan(right_schema, "b_right", CrystalClick::BinaryDataType.primitive("String")),
    } of String => CrystalClick::ObjectDocumentPlan
    marks = granules(left_schema, right_schema)
    keys = (1_u64..8_u64).to_a

    CrystalClick::WidePartWriter.write_uint64_recursive_pair(
      library_part,
      KEY,
      Slice(UInt64).new(keys.size) { |index| keys[index] },
      COLUMN,
      tuple_schema,
      object_plans,
      marks,
      rows_per_mark: 2,
      mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: 64,
    )

    stock_reader = reader_record(stock_part, tuple_schema)
    library_reader = reader_record(library_part, tuple_schema)
    stock_table = CrystalClick::WidePartTable.open_selected_typed([stock_part], [KEY, COLUMN])
    library_table = CrystalClick::WidePartTable.open_selected_typed([library_part], [KEY, COLUMN])

    record = {
      "status"                    => JSON::Any.new("observed"),
      "library_part_path"         => JSON::Any.new(File.expand_path(library_part)),
      "stock_reader"              => JSON::Any.new(stock_reader),
      "library_reader"            => JSON::Any.new(library_reader),
      "stock_table_rows"          => JSON::Any.new(table_signatures(stock_table)),
      "stock_table_middle_rows"   => JSON::Any.new(table_middle_signatures(stock_table)),
      "library_table_rows"        => JSON::Any.new(table_signatures(library_table)),
      "library_table_middle_rows" => JSON::Any.new(table_middle_signatures(library_table)),
    } of String => JSON::Any
    puts record.to_json
  end

  def main(args : Array(String)) : Nil
    usage unless args.size == 2
    run(args[0], args[1])
  rescue ex : Exception
    STDERR.puts "W186 paired Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end
end

CheckRecursiveJSONTuplePartsW186.main(ARGV)
