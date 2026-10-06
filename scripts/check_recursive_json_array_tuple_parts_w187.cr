require "../src/crystal_click"
require "json"

module CheckRecursiveJSONArrayTuplePartsW187
  extend self

  JsonType  = "JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)"
  TupleType = "Tuple(l #{JsonType}, r #{JsonType}, n UInt64)"
  OneType   = "Array(#{TupleType})"
  TwoType   = "Array(Array(#{TupleType}))"
  CompactJsonType  = "JSON(max_dynamic_types=2, max_dynamic_paths=1, t UInt8)"
  CompactTupleType = "Tuple(l #{CompactJsonType}, r #{CompactJsonType}, n UInt64)"
  CompactOneType   = "Array(#{CompactTupleType})"
  CompactTwoType   = "Array(Array(#{CompactTupleType}))"

  COLUMN        = "a"
  KEY           = "pk"
  ROWS_PER_MARK = 2

  def usage : NoReturn
    STDERR.puts "usage: check_recursive_json_array_tuple_parts_w187 [--dynamic-mode basic|compact] [--stock-only] STOCK_ONE STOCK_TWO [LIBRARY_ONE LIBRARY_TWO]"
    exit 64
  end

  private def object_plan(
    schema : CrystalClick::ObjectDocumentSchema,
    dynamic_path : String,
    dynamic_types : Array(CrystalClick::BinaryDataType),
  ) : CrystalClick::ObjectDocumentPlan
    object = CrystalClick::ObjectStructure.new([dynamic_path] of String)
    dynamics = {
      dynamic_path => CrystalClick::DynamicStructure.new(dynamic_types),
    } of String => CrystalClick::DynamicStructure
    structures = CrystalClick::ObjectDynamicStructureSet.new(object, dynamics)
    CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
  end

  private def json_document(index : Int32, left : Bool, occurrence : Int32, compact : Bool) : CrystalClick::ObjectDocument
    typed = CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"),
      Bytes[index.to_u8]
    )
    values = {"t" => typed} of String => CrystalClick::BinaryValue
    if left
      values["a_left"] = if compact && occurrence == 3
                            CrystalClick::BinaryValue.null
                          elsif compact && occurrence == 4
                            CrystalClick::BinaryValue.string("left-#{occurrence}")
                          else
                            CrystalClick::BinaryValue.int64((occurrence + 10).to_i64)
                          end
      values["z_shared"] = CrystalClick::BinaryValue.string("left-shared") if occurrence == 1
    else
      values["b_right"] = if compact && occurrence == 3
                             CrystalClick::BinaryValue.null
                           elsif compact && occurrence == 4
                             CrystalClick::BinaryValue.int64((occurrence + 20).to_i64)
                           else
                             CrystalClick::BinaryValue.string("right-#{occurrence}")
                           end
      values["z_shared"] = CrystalClick::BinaryValue.string("right-shared") if occurrence == 1
    end
    CrystalClick::ObjectDocument.new(values)
  end

  private def tuple_value(index : Int32, compact : Bool) : CrystalClick::StorageColumnValue
    left = CrystalClick::StorageColumnValue.object_document(json_document(index, true, index, compact))
    right = CrystalClick::StorageColumnValue.object_document(json_document(index + 20, false, index, compact))
    number = CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(index.to_u64 * 100_u64))
    CrystalClick::StorageColumnValue.tuple([left, right, number] of CrystalClick::StorageColumnValue)
  end

  private def one_row(pk : Int32, compact : Bool) : CrystalClick::StorageColumnValue
    indexes = case pk
              when 4 then [1]
              when 5 then [2, 3]
              when 6 then [4]
              else        [] of Int32
              end
    children = indexes.map { |index| tuple_value(index, compact) }
    CrystalClick::StorageColumnValue.array(children)
  end

  private def two_row(pk : Int32, compact : Bool) : CrystalClick::StorageColumnValue
    groups = case pk
             when 3 then [[] of Int32]
             when 4 then [[1]]
             when 5 then [[] of Int32, [2, 3]]
             when 6 then [[4]]
             else        [] of Array(Int32)
             end
    outer = groups.map do |group|
      inner = group.map { |index| tuple_value(index, compact) }
      CrystalClick::StorageColumnValue.array(inner)
    end
    CrystalClick::StorageColumnValue.array(outer)
  end

  private def granules(one : Bool, compact : Bool) : Array(Array(CrystalClick::StorageColumnValue))
    result = [] of Array(CrystalClick::StorageColumnValue)
    4.times do |mark|
      rows = [] of CrystalClick::StorageColumnValue
      2.times do |offset|
        pk = mark * ROWS_PER_MARK + offset + 1
        rows << (one ? one_row(pk, compact) : two_row(pk, compact))
      end
      result << rows
    end
    result
  end

  private def site_key(array_depth : Int32, tuple_field : Int32) : String
    String.build do |io|
      io << "root"
      array_depth.times { io << "/array[0]" }
      io << "/tuple[" << tuple_field << ']'
    end
  end

  private def object_plans(
    schema : CrystalClick::ObjectDocumentSchema,
    array_depth : Int32,
    compact : Bool,
  ) : Hash(String, CrystalClick::ObjectDocumentPlan)
    left_types = [CrystalClick::BinaryDataType.primitive("Int64")] of CrystalClick::BinaryDataType
    right_types = [CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType
    if compact
      left_types << CrystalClick::BinaryDataType.primitive("String")
      right_types << CrystalClick::BinaryDataType.primitive("Int64")
    end
    {
      site_key(array_depth, 0) => object_plan(schema, "a_left", left_types),
      site_key(array_depth, 1) => object_plan(schema, "b_right", right_types),
    } of String => CrystalClick::ObjectDocumentPlan
  end

  private def write_library_part(
    destination : String,
    declaration : String,
    array_depth : Int32,
    compact : Bool,
  ) : Nil
    schema = CrystalClick::StorageColumnSchema.parse(declaration)
    expected_sites = [site_key(array_depth, 0), site_key(array_depth, 1)].sort!
    unless schema.canonical_declaration == declaration && schema.json_site_keys.sort! == expected_sites
      raise CrystalClick::UnsupportedFormatError.new("recursive Array/Tuple JSON site identities differ")
    end
    json_type = compact ? CompactJsonType : JsonType
    object_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(json_type)
    unless object_schema.declaration == json_type
      raise CrystalClick::UnsupportedFormatError.new("JSON leaf declaration changed during planning")
    end
    keys = (1_u64..8_u64).to_a
    CrystalClick::WidePartWriter.write_uint64_recursive_pair(
      destination,
      KEY,
      Slice(UInt64).new(keys.size) { |index| keys[index] },
      COLUMN,
      schema,
      object_plans(object_schema, array_depth, compact),
      granules(array_depth == 1, compact),
      rows_per_mark: ROWS_PER_MARK,
      mode: compact ? CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE : CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: 64,
    )
  end

  private def type_schema(schema : CrystalClick::StorageColumnSchema) : JSON::Any
    fields = {} of String => JSON::Any
    if schema.tuple?
      schema.child_count.times do |index|
        fields[schema.field_name_at(index)] = type_schema(schema.child_at(index))
      end
      JSON::Any.new(fields)
    elsif schema.array?
      JSON::Any.new([type_schema(schema.child_at(0))] of JSON::Any)
    elsif schema.object?
      JSON::Any.new(schema.object_schema.declaration)
    else
      JSON::Any.new(schema.bulk_type.name)
    end
  end

  private def json_value(document : CrystalClick::ObjectDocument, schema : CrystalClick::ObjectDocumentSchema) : JSON::Any
    fields = {} of String => JSON::Any
    typed = schema.typed_paths
    document.paths.each do |path|
      value = document.value_for(path)
      type_name = (typed[path]? || value.type).name
      fields[path] = if value.is_null?
                       JSON::Any.new(nil)
                     else
                       case type_name
                       when "String"
                         JSON::Any.new(value.as_string)
                       when "Int64"
                         JSON::Any.new(value.as_int64)
                       when "UInt8"
                         JSON::Any.new(value.bytes[0].to_i64)
                       else
                         raise CrystalClick::CorruptPartError.new("unexpected recursive JSON field type #{type_name}")
                       end
                     end
    end
    JSON::Any.new(fields)
  end

  private def render_value(schema : CrystalClick::StorageColumnSchema, value : CrystalClick::StorageColumnValue) : JSON::Any
    unless schema.kind == value.kind
      raise CrystalClick::CorruptPartError.new("recursive Array/Tuple value kind differs from its declaration")
    end
    if schema.array?
      children = value.array_values.map { |child| render_value(schema.child_at(0), child) }
      JSON::Any.new(children)
    elsif schema.tuple?
      fields = {} of String => JSON::Any
      schema.child_count.times do |index|
        fields[schema.field_name_at(index)] = render_value(schema.child_at(index), value.child_at(index))
      end
      JSON::Any.new(fields)
    elsif schema.object?
      json_value(value.object_document, schema.object_schema)
    else
      type_name = schema.bulk_type.name
      case type_name
      when "UInt64"
        JSON::Any.new(value.bulk_value.as_uint64.to_i64)
      else
        raise CrystalClick::CorruptPartError.new("unexpected recursive BinaryBulk type #{type_name}")
      end
    end
  end

  private def leaf_tuple_count(schema : CrystalClick::StorageColumnSchema, value : CrystalClick::StorageColumnValue) : UInt64
    if schema.array?
      count = 0_u64
      value.array_values.each do |child|
        child_count = leaf_tuple_count(schema.child_at(0), child)
        if child_count > UInt64::MAX - count
          raise CrystalClick::CorruptPartError.new("recursive Array leaf count overflows")
        end
        count += child_count
      end
      count
    elsif schema.tuple?
      1_u64
    else
      0_u64
    end
  end

  private def row_signature(
    key : UInt64,
    schema : CrystalClick::StorageColumnSchema,
    value : CrystalClick::StorageColumnValue,
  ) : JSON::Any
    JSON::Any.new([JSON::Any.new(key.to_s), render_value(schema, value)] of JSON::Any)
  end

  private def marked_signatures(
    marks : Array(Array(CrystalClick::StorageColumnValue)),
    schema : CrystalClick::StorageColumnSchema,
    first_key : UInt64,
  ) : Array(Array(JSON::Any))
    next_key = first_key
    marks.map do |mark|
      mark.map do |value|
        signature = row_signature(next_key, schema, value)
        next_key += 1_u64
        signature
      end
    end
  end

  private def table_signatures(table : CrystalClick::WidePartTable, schema : CrystalClick::StorageColumnSchema) : Array(JSON::Any)
    rows = [] of JSON::Any
    table.scan_typed(batch_rows: ROWS_PER_MARK) do |batch|
      keys = batch.values_for(KEY)
      values = batch.recursive_values_for(COLUMN)
      unless keys.size == values.size
        raise CrystalClick::CorruptPartError.new("primary-key and recursive Array/Tuple batch widths differ")
      end
      keys.size.times { |index| rows << row_signature(keys[index], schema, values[index]) }
      nil
    end
    rows
  end

  private def table_middle_signatures(table : CrystalClick::WidePartTable, schema : CrystalClick::StorageColumnSchema) : Array(JSON::Any)
    rows = [] of JSON::Any
    table.scan_typed_window(2_u64, max_rows: 4) do |batch|
      keys = batch.values_for(KEY)
      values = batch.recursive_values_for(COLUMN)
      unless keys.size == values.size
        raise CrystalClick::CorruptPartError.new("primary-key and recursive Array/Tuple window widths differ")
      end
      keys.size.times { |index| rows << row_signature(keys[index], schema, values[index]) }
      nil
    end
    rows
  end

  private def table_zero_signatures(table : CrystalClick::WidePartTable) : Array(JSON::Any)
    rows = [] of JSON::Any
    table.scan_typed_window(8_u64, max_rows: 2) do |batch|
      rows << JSON::Any.new(batch.values_for(KEY).size.to_i64)
      nil
    end
    rows
  end

  private def reader_record(
    part : String,
    schema : CrystalClick::StorageColumnSchema,
  ) : Hash(String, JSON::Any)
    reader = CrystalClick::RecursiveStorageColumnReader.open(part, COLUMN, schema)
    full = reader.read_marks(0, reader.mark_count)
    middle = reader.read_marks(1, 2)
    zero = reader.read_marks(reader.mark_count, 0)
    leaf_counts = full.map do |mark|
      total = 0_u64
      mark.each do |value|
        count = leaf_tuple_count(schema, value)
        if count > UInt64::MAX - total
          raise CrystalClick::CorruptPartError.new("recursive Array mark leaf count overflows")
        end
        total += count
      end
      JSON::Any.new(total.to_i64)
    end
    {
      "schema_declaration"      => JSON::Any.new(reader.schema_declaration),
      "source_declaration"      => JSON::Any.new(reader.source_declaration),
      "row_count"               => JSON::Any.new(reader.row_count.to_i64),
      "mark_count"              => JSON::Any.new(reader.mark_count.to_i64),
      "mark_row_counts"         => JSON::Any.new(reader.mark_row_counts.map { |count| JSON::Any.new(count.to_i64) }),
      "physical_stream_names"   => JSON::Any.new(reader.physical_stream_names.map { |name| JSON::Any.new(name) }),
      "selected_checksum_names" => JSON::Any.new(reader.selected_checksum_names.map { |name| JSON::Any.new(name) }),
      "logical_read_bytes"      => JSON::Any.new(reader.logical_read_bytes.to_i64),
      "full_rows"               => JSON::Any.new(marked_signatures(full, schema, 1_u64).map { |mark| JSON::Any.new(mark) }),
      "middle_rows"             => JSON::Any.new(marked_signatures(middle, schema, 3_u64).map { |mark| JSON::Any.new(mark) }),
      "zero_rows"               => JSON::Any.new(marked_signatures(zero, schema, 9_u64).map { |mark| JSON::Any.new(mark) }),
      "leaf_occurrence_counts"  => JSON::Any.new(leaf_counts),
    } of String => JSON::Any
  end

  private def profile_record(
    stock_part : String,
    library_part : String,
    declaration : String,
    array_depth : Int32,
    compact : Bool,
  ) : Hash(String, JSON::Any)
    write_library_part(library_part, declaration, array_depth, compact)
    schema = CrystalClick::StorageColumnSchema.parse(declaration)
    stock_table = CrystalClick::WidePartTable.open_selected_typed([stock_part], [KEY, COLUMN])
    library_table = CrystalClick::WidePartTable.open_selected_typed([library_part], [KEY, COLUMN])
    {
      "schema_declaration"        => JSON::Any.new(schema.declaration),
      "schema_shape"              => type_schema(schema),
      "stock_reader"              => JSON::Any.new(reader_record(stock_part, schema)),
      "library_reader"            => JSON::Any.new(reader_record(library_part, schema)),
      "stock_table_rows"          => JSON::Any.new(table_signatures(stock_table, schema)),
      "stock_table_middle_rows"   => JSON::Any.new(table_middle_signatures(stock_table, schema)),
      "stock_table_zero_rows"     => JSON::Any.new(table_zero_signatures(stock_table)),
      "library_table_rows"        => JSON::Any.new(table_signatures(library_table, schema)),
      "library_table_middle_rows" => JSON::Any.new(table_middle_signatures(library_table, schema)),
      "library_table_zero_rows"   => JSON::Any.new(table_zero_signatures(library_table)),
    } of String => JSON::Any
  end

  private def stock_refusal(part : String, declaration : String) : Hash(String, JSON::Any)
    schema = CrystalClick::StorageColumnSchema.parse(declaration)
    begin
      reader = CrystalClick::RecursiveStorageColumnReader.open(part, COLUMN, schema)
      reader.read_marks(0, reader.mark_count)
      {
        "status" => JSON::Any.new("reader_succeeded"),
        "error_class" => JSON::Any.new(""),
        "message" => JSON::Any.new(""),
      } of String => JSON::Any
    rescue ex : CrystalClick::UnsupportedFormatError
      {
        "status" => JSON::Any.new("unsupported"),
        "error_class" => JSON::Any.new(ex.class.to_s),
        "message" => JSON::Any.new(ex.message || ""),
      } of String => JSON::Any
    end
  end

  private def run_stock_only(stock_one : String, stock_two : String) : Nil
    one = stock_refusal(stock_one, CompactOneType)
    two = stock_refusal(stock_two, CompactTwoType)
    puts({
      "status" => "baseline_reader_refusal_observed",
      "profiles" => {"one" => one, "two" => two},
    }.to_json)
  end

  private def run(
    stock_one : String,
    stock_two : String,
    library_one : String,
    library_two : String,
    compact : Bool,
  ) : Nil
    if compact
      one = profile_record(stock_one, library_one, CompactOneType, 1, true)
      two = profile_record(stock_two, library_two, CompactTwoType, 2, true)
    else
      one = profile_record(stock_one, library_one, OneType, 1, false)
      two = profile_record(stock_two, library_two, TwoType, 2, false)
    end
    puts({
      "status"        => "observed",
      "library_parts" => {
        "one" => File.expand_path(library_one),
        "two" => File.expand_path(library_two),
      },
      "profiles" => {"one" => one, "two" => two},
    }.to_json)
  end

  def main(args : Array(String)) : Nil
    dynamic_mode = "basic"
    stock_only = false
    positional = [] of String
    index = 0
    while index < args.size
      case args[index]
      when "--dynamic-mode"
        index += 1
        raise ArgumentError.new("--dynamic-mode requires basic or compact") if index >= args.size
        dynamic_mode = args[index]
      when "--stock-only"
        stock_only = true
      else
        if args[index].starts_with?("--")
          raise ArgumentError.new("unknown helper option #{args[index]}")
        end
        positional << args[index]
      end
      index += 1
    end
    unless dynamic_mode == "basic" || dynamic_mode == "compact"
      raise ArgumentError.new("dynamic mode must be basic or compact")
    end
    if stock_only
      unless dynamic_mode == "compact" && positional.size == 2
        usage
      end
      run_stock_only(positional[0], positional[1])
    else
      usage unless positional.size == 4
      run(positional[0], positional[1], positional[2], positional[3], dynamic_mode == "compact")
    end
  rescue ex : Exception
    STDERR.puts "W187 recursive Array/Tuple JSON helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end
end

CheckRecursiveJSONArrayTuplePartsW187.main(ARGV)
