require "../src/crystal_click"
require "json"

module CheckObjectTypedDynamicCompactW189
  extend self

  JsonType    = "JSON(max_dynamic_types=1, max_dynamic_paths=0, array Array(Dynamic(max_types=1)), direct Dynamic(max_types=1))"
  TupleType   = "Tuple(l #{JsonType}, r #{JsonType}, n UInt64)"
  OneType     = "Array(#{TupleType})"
  TwoType     = "Array(Array(#{TupleType}))"
  Key         = "pk"
  Column      = "a"
  RowsPerMark = 2

  alias DataType = CrystalClick::BinaryDataType
  alias Value = CrystalClick::BinaryValue
  alias Document = CrystalClick::ObjectDocument
  alias StorageValue = CrystalClick::StorageColumnValue

  def usage : NoReturn
    STDERR.puts "usage: check_object_typed_dynamic_compact_w189 [--dynamic-mode basic|compact] STOCK_ONE STOCK_TWO LIBRARY_ONE LIBRARY_TWO"
    exit 64
  end

  private def object_plan(schema : CrystalClick::ObjectDocumentSchema, left : Bool) : CrystalClick::ObjectDocumentPlan
    ordinary = left ? DataType.primitive("Int64") : DataType.primitive("String")
    array_ordinary = left ? DataType.primitive("Int64") : DataType.primitive("Bool")
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    typed_dynamic_sites = {
      "direct" => {"root" => CrystalClick::DynamicStructure.new([ordinary] of DataType)},
      "array"  => {"root.elements" => CrystalClick::DynamicStructure.new([array_ordinary] of DataType)},
    }
    CrystalClick::ObjectDocumentPlan.new(
      structures,
      schema.typed_paths,
      typed_dynamic_sites: typed_dynamic_sites,
    )
  end

  private def dynamic_value(dynamic_type : DataType, index : Int32, left : Bool) : Value
    child = if index == 1
              nil
            elsif left
              case index
              when 2 then Value.int64(102_i64)
              when 3 then Value.string("left-spill-3")
              else        Value.int64(104_i64)
              end
            else
              case index
              when 2 then Value.string("right-2")
              when 3 then Value.int64(203_i64)
              else        Value.string("right-4")
              end
            end
    Value.dynamic(dynamic_type, child)
  end

  private def json_document(index : Int32, left : Bool) : Document
    dynamic_type = DataType.dynamic(1)
    array_dynamic_values = case index
                           when 1
                             [Value.dynamic(dynamic_type, nil)] of Value
                           when 3
                             if left
                               [
                                 Value.dynamic(dynamic_type, Value.int64(31_i64)),
                                 Value.dynamic(dynamic_type, Value.string("left-array-spill")),
                                 Value.dynamic(dynamic_type, Value.int64(33_i64)),
                               ] of Value
                             else
                               [
                                 Value.dynamic(dynamic_type, Value.bool(true)),
                                 Value.dynamic(dynamic_type, Value.string("right-array-spill")),
                                 Value.dynamic(dynamic_type, Value.bool(false)),
                               ] of Value
                             end
                           else
                             [] of Value
                           end
    fields = {
      "direct" => dynamic_value(dynamic_type, index, left),
      "array"  => Value.array(DataType.array(dynamic_type), array_dynamic_values),
    } of String => Value
    if index == 1
      fields["z_shared"] = Value.string(left ? "left-shared" : "right-shared")
    end
    Document.new(fields)
  end

  private def tuple_value(index : Int32) : StorageValue
    left = StorageValue.object_document(json_document(index, true))
    right = StorageValue.object_document(json_document(index, false))
    number = StorageValue.bulk(Value.uint64(index.to_u64 * 100_u64))
    StorageValue.tuple([left, right, number] of StorageValue)
  end

  private def one_row(pk : Int32) : StorageValue
    indexes = case pk
              when 4 then [1]
              when 5 then [2, 3]
              when 6 then [4]
              else        [] of Int32
              end
    StorageValue.array(indexes.map { |index| tuple_value(index) })
  end

  private def two_row(pk : Int32) : StorageValue
    groups = case pk
             when 3 then [[] of Int32]
             when 4 then [[1]]
             when 5 then [[] of Int32, [2, 3]]
             when 6 then [[4]]
             else        [] of Array(Int32)
             end
    StorageValue.array(groups.map { |group| StorageValue.array(group.map { |index| tuple_value(index) }) })
  end

  private def granules(one : Bool) : Array(Array(StorageValue))
    result = [] of Array(StorageValue)
    4.times do |mark|
      rows = [] of StorageValue
      2.times do |offset|
        pk = mark * RowsPerMark + offset + 1
        rows << (one ? one_row(pk) : two_row(pk))
      end
      result << rows
    end
    result
  end

  private def write_library_part(destination : String, declaration : String, one : Bool, mode : UInt64) : Nil
    schema = CrystalClick::StorageColumnSchema.parse(declaration)
    expected = one ? OneType : TwoType
    unless schema.canonical_declaration == expected
      raise CrystalClick::UnsupportedFormatError.new("typed Dynamic recursive schema declaration changed")
    end
    json_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(JsonType)
    plans = {
      "root/array[0]/tuple[0]" => object_plan(json_schema, true),
      "root/array[0]/tuple[1]" => object_plan(json_schema, false),
    } of String => CrystalClick::ObjectDocumentPlan
    unless one
      plans = {
        "root/array[0]/array[0]/tuple[0]" => object_plan(json_schema, true),
        "root/array[0]/array[0]/tuple[1]" => object_plan(json_schema, false),
      } of String => CrystalClick::ObjectDocumentPlan
    end
    keys = (1_u64..8_u64).to_a
    CrystalClick::WidePartWriter.write_uint64_recursive_pair(
      destination,
      Key,
      Slice(UInt64).new(keys.size) { |index| keys[index] },
      Column,
      schema,
      plans,
      granules(one),
      rows_per_mark: RowsPerMark,
      mode: mode,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: 64,
    )
  end

  private def type_schema(schema : CrystalClick::StorageColumnSchema) : JSON::Any
    if schema.tuple?
      fields = {} of String => JSON::Any
      schema.child_count.times { |index| fields[schema.field_name_at(index)] = type_schema(schema.child_at(index)) }
      JSON::Any.new(fields)
    elsif schema.array?
      JSON::Any.new([type_schema(schema.child_at(0))] of JSON::Any)
    elsif schema.object?
      JSON::Any.new(schema.object_schema.declaration)
    else
      JSON::Any.new(schema.bulk_type.name)
    end
  end

  private def json_scalar(value : Value, type : DataType) : JSON::Any
    if type.tag == DataType::TAG_DYNAMIC
      return JSON::Any.new(nil) if value.is_null?
      return json_scalar(value.child_at(0), value.child_at(0).type)
    end
    if type.tag == DataType::TAG_ARRAY
      return JSON::Any.new(value.elements.map { |child| json_scalar(child, type.child_at(0)) })
    end
    if value.is_null?
      return JSON::Any.new(nil)
    end
    case type.name
    when "String"
      JSON::Any.new(value.as_string)
    when "UInt8"
      JSON::Any.new(value.byte_at(0).to_i64)
    when "Bool"
      JSON::Any.new(value.as_bool)
    when "Int64"
      JSON::Any.new(value.as_int64)
    when "UInt64"
      JSON::Any.new(value.as_uint64.to_i64)
    else
      raise CrystalClick::CorruptPartError.new("unexpected W189 JSON value type #{type.name}")
    end
  end

  private def json_document(document : Document, schema : CrystalClick::ObjectDocumentSchema) : JSON::Any
    fields = {} of String => JSON::Any
    typed = schema.typed_paths
    document.paths.each do |path|
      value = document.value_for(path)
      type = typed[path]? || value.type
      fields[path] = json_scalar(value, type)
    end
    JSON::Any.new(fields)
  end

  private def render_value(schema : CrystalClick::StorageColumnSchema, value : StorageValue) : JSON::Any
    unless schema.kind == value.kind
      raise CrystalClick::CorruptPartError.new("W189 recursive value kind differs from schema")
    end
    if schema.array?
      JSON::Any.new(value.array_values.map { |child| render_value(schema.child_at(0), child) })
    elsif schema.tuple?
      fields = {} of String => JSON::Any
      schema.child_count.times do |index|
        fields[schema.field_name_at(index)] = render_value(schema.child_at(index), value.child_at(index))
      end
      JSON::Any.new(fields)
    elsif schema.object?
      json_document(value.object_document, schema.object_schema)
    elsif schema.bulk_type.name == "UInt64"
      JSON::Any.new(value.bulk_value.as_uint64.to_i64)
    else
      raise CrystalClick::CorruptPartError.new("unexpected W189 BinaryBulk type #{schema.bulk_type.name}")
    end
  end

  private def row_signature(key : UInt64, schema : CrystalClick::StorageColumnSchema, value : StorageValue) : JSON::Any
    JSON::Any.new([JSON::Any.new(key.to_s), render_value(schema, value)] of JSON::Any)
  end

  private def marked_signatures(marks : Array(Array(StorageValue)), schema : CrystalClick::StorageColumnSchema, first_key : UInt64) : Array(Array(JSON::Any))
    key = first_key
    marks.map do |mark|
      mark.map do |value|
        signature = row_signature(key, schema, value)
        key += 1_u64
        signature
      end
    end
  end

  private def table_signatures(table : CrystalClick::WidePartTable, schema : CrystalClick::StorageColumnSchema, first_mark : UInt64, max_rows : Int?) : Array(JSON::Any)
    result = [] of JSON::Any
    consume = ->(batch : CrystalClick::WidePartTableBatch) {
      keys = batch.values_for(Key)
      values = batch.recursive_values_for(Column)
      unless keys.size == values.size
        raise CrystalClick::CorruptPartError.new("W189 key/value widths differ")
      end
      keys.size.times { |index| result << row_signature(keys[index], schema, values[index]) }
      nil
    }
    if limit = max_rows
      table.scan_typed_window(first_mark, max_rows: limit, &consume)
    else
      table.scan_typed(batch_rows: RowsPerMark, &consume)
    end
    result
  end

  private def table_zero_signatures(table : CrystalClick::WidePartTable) : Array(JSON::Any)
    result = [] of JSON::Any
    table.scan_typed_window(8_u64, max_rows: 2) do |batch|
      result << JSON::Any.new(batch.values_for(Key).size.to_i64)
      nil
    end
    result
  end

  private def reader_record(part : String, schema : CrystalClick::StorageColumnSchema) : Hash(String, JSON::Any)
    reader = CrystalClick::RecursiveStorageColumnReader.open(part, Column, schema)
    full = reader.read_marks(0, reader.mark_count)
    middle = reader.read_marks(1, 2)
    zero = reader.read_marks(reader.mark_count, 0)
    {
      "schema_declaration"    => JSON::Any.new(reader.schema_declaration),
      "row_count"             => JSON::Any.new(reader.row_count.to_i64),
      "mark_count"            => JSON::Any.new(reader.mark_count.to_i64),
      "mark_row_counts"       => JSON::Any.new(reader.mark_row_counts.map { |count| JSON::Any.new(count.to_i64) }),
      "physical_stream_names" => JSON::Any.new(reader.physical_stream_names.map { |name| JSON::Any.new(name) }),
      "full_rows"             => JSON::Any.new(marked_signatures(full, schema, 1_u64).map { |mark| JSON::Any.new(mark) }),
      "middle_rows"           => JSON::Any.new(marked_signatures(middle, schema, 3_u64).map { |mark| JSON::Any.new(mark) }),
      "zero_rows"             => JSON::Any.new(marked_signatures(zero, schema, 9_u64).map { |mark| JSON::Any.new(mark) }),
    } of String => JSON::Any
  end

  private def profile_record(stock_part : String, library_part : String, declaration : String, one : Bool, mode : UInt64) : Hash(String, JSON::Any)
    write_library_part(library_part, declaration, one, mode)
    schema = CrystalClick::StorageColumnSchema.parse(declaration)
    stock_table = CrystalClick::WidePartTable.open_selected_typed([stock_part], [Key, Column])
    library_table = CrystalClick::WidePartTable.open_selected_typed([library_part], [Key, Column])
    {
      "schema_declaration"        => JSON::Any.new(schema.canonical_declaration),
      "schema_shape"              => type_schema(schema),
      "stock_reader"              => JSON::Any.new(reader_record(stock_part, schema)),
      "library_reader"            => JSON::Any.new(reader_record(library_part, schema)),
      "stock_table_rows"          => JSON::Any.new(table_signatures(stock_table, schema, 0_u64, nil)),
      "stock_table_middle_rows"   => JSON::Any.new(table_signatures(stock_table, schema, 2_u64, 4)),
      "stock_table_zero_rows"     => JSON::Any.new(table_zero_signatures(stock_table)),
      "library_table_rows"        => JSON::Any.new(table_signatures(library_table, schema, 0_u64, nil)),
      "library_table_middle_rows" => JSON::Any.new(table_signatures(library_table, schema, 2_u64, 4)),
      "library_table_zero_rows"   => JSON::Any.new(table_zero_signatures(library_table)),
    } of String => JSON::Any
  end

  private def run(stock_one : String, stock_two : String, library_one : String, library_two : String, mode : UInt64) : Nil
    one = profile_record(stock_one, library_one, OneType, true, mode)
    two = profile_record(stock_two, library_two, TwoType, false, mode)
    puts({
      "status"        => "observed",
      "library_parts" => {"one" => File.expand_path(library_one), "two" => File.expand_path(library_two)},
      "profiles"      => {"one" => one, "two" => two},
    }.to_json)
  end

  def main(args : Array(String)) : Nil
    dynamic_mode = "basic"
    positional = [] of String
    index = 0
    while index < args.size
      case args[index]
      when "--dynamic-mode"
        index += 1
        raise ArgumentError.new("--dynamic-mode requires basic or compact") if index >= args.size
        dynamic_mode = args[index]
      else
        raise ArgumentError.new("unknown helper option #{args[index]}") if args[index].starts_with?("--")
        positional << args[index]
      end
      index += 1
    end
    unless dynamic_mode == "basic" || dynamic_mode == "compact"
      raise ArgumentError.new("dynamic mode must be basic or compact")
    end
    usage unless positional.size == 4
    mode = dynamic_mode == "compact" ? CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE : CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE
    run(positional[0], positional[1], positional[2], positional[3], mode)
  rescue ex : Exception
    STDERR.puts "W189 typed Dynamic COMPACT helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end
end

CheckObjectTypedDynamicCompactW189.main(ARGV)
