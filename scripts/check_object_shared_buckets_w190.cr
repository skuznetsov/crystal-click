require "../src/crystal_click"
require "json"

module CheckObjectSharedBucketsW190
  extend self

  alias Document = CrystalClick::ObjectDocument
  alias RootMarks = Array(Array(Document))
  alias ArrayMarks = Array(Array(Array(Document)))

  ROOT_TYPE = "JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt8)"
  ARRAY_TYPE = "Array(#{ROOT_TYPE})"
  KEY = "pk"
  ROOT_COLUMN = "j"
  ARRAY_COLUMN = "a"
  ROWS_PER_MARK = 2

  private def usage : NoReturn
    STDERR.puts "usage: check_object_shared_buckets_w190 STOCK_ROOT2 STOCK_ROOT32 STOCK_ARRAY2 STOCK_ARRAY32 STOCK_EMPTY1 LIBRARY_ROOT2 LIBRARY_ROOT32 LIBRARY_ARRAY2 LIBRARY_ARRAY32 LIBRARY_EMPTY1"
    exit 64
  end

  private def schema : CrystalClick::ObjectDocumentSchema
    CrystalClick::ObjectDocumentSchema.new(
      {"t" => CrystalClick::BinaryDataType.primitive("UInt8")},
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
    )
  end

  private def plan(inner : CrystalClick::ObjectDocumentSchema, bucket_count : UInt64) : CrystalClick::ObjectDocumentPlan
    object = CrystalClick::ObjectStructure.new(
      [] of String,
      4_u64,
      1_u64,
      bucket_count,
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::ObjectDocumentPlan.new(structures, inner.typed_paths)
  end

  private def document(t : UInt8, shared : Hash(String, String?)? = nil) : Document
    values = {"t" => CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[t]
    )} of String => CrystalClick::BinaryValue
    if shared
      shared.each do |path, value|
        values[path] = value.nil? ? CrystalClick::BinaryValue.null : CrystalClick::BinaryValue.string(value)
      end
    end
    Document.new(values)
  end

  private def root_document(pk : Int32, include_shared : Bool, prefix : String = "root") : Document
    return document(pk.to_u8) unless include_shared

    values = {
      "alpha" => pk == 6 ? nil : "#{prefix}-alpha-#{pk}",
      "aa"    => "#{prefix}-aa-#{pk}",
      "beta"  => "#{prefix}-beta-#{pk}",
    } of String => String?
    document(pk.to_u8, values)
  end

  private def root_granules(include_shared : Bool, prefix : String = "root") : RootMarks
    result = [] of Array(Document)
    4.times do |mark|
      rows = [] of Document
      2.times do |offset|
        pk = mark * ROWS_PER_MARK + offset + 1
        rows << root_document(pk, include_shared, prefix)
      end
      result << rows
    end
    result
  end

  private def array_rows : Array(Array(Document))
    [
      [] of Document,
      [] of Document,
      [] of Document,
      [document(41_u8, {"alpha" => "array-alpha-41", "aa" => "array-aa-41", "beta" => "array-beta-41"} of String => String?)] of Document,
      [
        document(51_u8, {"alpha" => "array-alpha-51", "aa" => "array-aa-51", "beta" => "array-beta-51"} of String => String?),
        document(52_u8, {"alpha" => nil, "aa" => "array-aa-52", "beta" => "array-beta-52"} of String => String?),
      ] of Document,
      [document(61_u8, {"alpha" => "array-alpha-61", "aa" => "array-aa-61", "beta" => "array-beta-61"} of String => String?)] of Document,
      [] of Document,
      [] of Document,
    ] of Array(Document)
  end

  private def array_granules : ArrayMarks
    rows = array_rows
    [
      [rows[0], rows[1]] of Array(Document),
      [rows[2], rows[3]] of Array(Document),
      [rows[4], rows[5]] of Array(Document),
      [rows[6], rows[7]] of Array(Document),
    ] of Array(Array(Document))
  end

  private def keys : Slice(UInt64)
    Slice(UInt64).new(8) { |index| (index + 1).to_u64 }
  end

  private def write_library_part(
    destination : String,
    column : String,
    inner : CrystalClick::ObjectDocumentSchema,
    buckets : UInt64,
    kind : String,
  ) : Nil
    if kind == "array"
      CrystalClick::WidePartWriter.write_uint64_array_object_pair(
        destination,
        KEY,
        keys,
        column,
        inner,
        plan(inner, buckets),
        array_granules,
        rows_per_mark: ROWS_PER_MARK,
        mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
        profile: CrystalClick::BinaryBulkProfile.with_size_stream,
        shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
        frame_bytes: 64,
      )
    else
      include_shared = kind != "empty"
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        destination,
        KEY,
        keys,
        column,
        inner,
        plan(inner, buckets),
        root_granules(include_shared),
        rows_per_mark: ROWS_PER_MARK,
        mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
        profile: CrystalClick::BinaryBulkProfile.with_size_stream,
        shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
        frame_bytes: 64,
      )
    end
    nil
  end

  private def render_document(document : Document) : JSON::Any
    fields = {} of String => JSON::Any
    document.paths.each do |path|
      value = document.value_for(path)
      fields[path] = if value.is_null?
                       JSON::Any.new(nil)
                     elsif path == "t"
                       JSON::Any.new(value.bytes[0].to_i64)
                     else
                       JSON::Any.new(value.as_string)
                     end
    end
    JSON::Any.new(fields)
  end

  private def render_documents(documents : Array(Document)) : Array(JSON::Any)
    documents.map { |item| render_document(item) }
  end

  private def root_reader_record(part : String, column : String, inner : CrystalClick::ObjectDocumentSchema) : Hash(String, JSON::Any)
    reader = CrystalClick::ObjectColumnReader.open(part, column, inner)
    mark_count = reader.mark_row_counts.size
    full = reader.read_marks(0, mark_count)
    middle = reader.read_marks(1, 2)
    zero = reader.read_marks(mark_count, 0)
    {
      "schema_declaration"      => JSON::Any.new(reader.schema_declaration),
      "source_declaration"      => JSON::Any.new(reader.source_declaration),
      "row_count"               => JSON::Any.new(reader.row_count.to_i64),
      "mark_count"              => JSON::Any.new(mark_count.to_i64),
      "mark_row_counts"         => JSON::Any.new(reader.mark_row_counts.map { |value| JSON::Any.new(value.to_i64) }),
      "physical_stream_names"   => JSON::Any.new(reader.physical_stream_names.map { |value| JSON::Any.new(value) }),
      "selected_checksum_names" => JSON::Any.new(reader.selected_checksum_names.map { |value| JSON::Any.new(value) }),
      "logical_read_bytes"      => JSON::Any.new(reader.logical_read_bytes.to_i64),
      "full_rows"               => JSON::Any.new(full.map { |mark| JSON::Any.new(render_documents(mark)) }),
      "middle_rows"             => JSON::Any.new(middle.map { |mark| JSON::Any.new(render_documents(mark)) }),
      "zero_rows"               => JSON::Any.new(zero.map { |mark| JSON::Any.new(render_documents(mark)) }),
    } of String => JSON::Any
  end

  private def array_reader_record(part : String, column : String, inner : CrystalClick::ObjectDocumentSchema) : Hash(String, JSON::Any)
    reader = CrystalClick::ArrayObjectColumnReader.open(part, column, inner)
    mark_count = reader.mark_row_counts.size
    full = reader.read_marks(0, mark_count)
    middle = reader.read_marks(1, 2)
    zero = reader.read_marks(mark_count, 0)
    {
      "schema_declaration"         => JSON::Any.new(reader.schema_declaration),
      "source_declaration"         => JSON::Any.new(reader.source_declaration),
      "row_count"                  => JSON::Any.new(reader.row_count.to_i64),
      "mark_count"                 => JSON::Any.new(mark_count.to_i64),
      "mark_row_counts"            => JSON::Any.new(reader.mark_row_counts.map { |value| JSON::Any.new(value.to_i64) }),
      "child_occurrence_row_counts" => JSON::Any.new(reader.child_occurrence_row_counts(0, mark_count).map { |value| JSON::Any.new(value.to_i64) }),
      "physical_stream_names"      => JSON::Any.new(reader.physical_stream_names.map { |value| JSON::Any.new(value) }),
      "selected_checksum_names"    => JSON::Any.new(reader.selected_checksum_names.map { |value| JSON::Any.new(value) }),
      "logical_read_bytes"         => JSON::Any.new(reader.logical_read_bytes.to_i64),
      "full_rows"                  => JSON::Any.new(full.map do |mark|
        JSON::Any.new(mark.map { |parent| JSON::Any.new(render_documents(parent)) })
      end),
      "middle_rows"                => JSON::Any.new(middle.map do |mark|
        JSON::Any.new(mark.map { |parent| JSON::Any.new(render_documents(parent)) })
      end),
      "zero_rows"                  => JSON::Any.new(zero.map do |mark|
        JSON::Any.new(mark.map { |parent| JSON::Any.new(render_documents(parent)) })
      end),
    } of String => JSON::Any
  end

  private def root_table_rows(part : String, column : String, start_row : UInt64? = nil, max_rows : Int = 4_096) : Array(JSON::Any)
    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY, column])
    rows = [] of JSON::Any
    if start_row
      table.scan_typed_window(start_row, max_rows: max_rows) do |batch|
        batch.object_documents_for(column).each { |item| rows << render_document(item) }
        nil
      end
    else
      table.scan_typed(batch_rows: 2) do |batch|
        batch.object_documents_for(column).each { |item| rows << render_document(item) }
        nil
      end
    end
    rows
  end

  private def array_table_rows(part : String, column : String, start_row : UInt64? = nil, max_rows : Int = 4_096) : Array(JSON::Any)
    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY, column])
    rows = [] of JSON::Any
    if start_row
      table.scan_typed_window(start_row, max_rows: max_rows) do |batch|
        batch.array_object_documents_for(column).each do |parent|
          rows << JSON::Any.new(render_documents(parent))
        end
        nil
      end
    else
      table.scan_typed(batch_rows: 2) do |batch|
        batch.array_object_documents_for(column).each do |parent|
          rows << JSON::Any.new(render_documents(parent))
        end
        nil
      end
    end
    rows
  end

  private def table_record(part : String, column : String, kind : String) : Hash(String, JSON::Any)
    full = kind == "array" ? array_table_rows(part, column) : root_table_rows(part, column)
    middle = kind == "array" ? array_table_rows(part, column, 2_u64, 4) : root_table_rows(part, column, 2_u64, 4)
    zero = kind == "array" ? array_table_rows(part, column, 8_u64, 2) : root_table_rows(part, column, 8_u64, 2)
    {
      "full_rows"   => JSON::Any.new(full),
      "middle_rows" => JSON::Any.new(middle),
      "zero_rows"   => JSON::Any.new(zero),
    } of String => JSON::Any
  end

  private def profile_record(
    stock_part : String,
    library_part : String,
    kind : String,
    column : String,
    buckets : UInt64,
  ) : Hash(String, JSON::Any)
    inner = schema
    write_library_part(library_part, column, inner, buckets, kind)
    stock_reader = kind == "array" ? array_reader_record(stock_part, column, inner) : root_reader_record(stock_part, column, inner)
    library_reader = kind == "array" ? array_reader_record(library_part, column, inner) : root_reader_record(library_part, column, inner)
    {
      "schema_declaration" => JSON::Any.new(kind == "array" ? ARRAY_TYPE : ROOT_TYPE),
      "library_part_path"  => JSON::Any.new(File.expand_path(library_part)),
      "stock_reader"       => JSON::Any.new(stock_reader),
      "library_reader"     => JSON::Any.new(library_reader),
      "stock_table_rows"   => JSON::Any.new(kind == "array" ? array_table_rows(stock_part, column) : root_table_rows(stock_part, column)),
      "stock_table_middle_rows" => JSON::Any.new(kind == "array" ? array_table_rows(stock_part, column, 2_u64, 4) : root_table_rows(stock_part, column, 2_u64, 4)),
      "stock_table_zero_rows" => JSON::Any.new(kind == "array" ? array_table_rows(stock_part, column, 8_u64, 2) : root_table_rows(stock_part, column, 8_u64, 2)),
      "library_table_rows" => JSON::Any.new(kind == "array" ? array_table_rows(library_part, column) : root_table_rows(library_part, column)),
      "library_table_middle_rows" => JSON::Any.new(kind == "array" ? array_table_rows(library_part, column, 2_u64, 4) : root_table_rows(library_part, column, 2_u64, 4)),
      "library_table_zero_rows" => JSON::Any.new(kind == "array" ? array_table_rows(library_part, column, 8_u64, 2) : root_table_rows(library_part, column, 8_u64, 2)),
    } of String => JSON::Any
  end

  private def run(args : Array(String)) : Nil
    usage unless args.size == 10
    inner = schema
    labels = {"root2", "root32", "array2", "array32", "empty1"}
    stocks = args[0, 5]
    libraries = args[5, 5]
    profiles = {} of String => JSON::Any
    labels.each_with_index do |label, index|
      kind = label.starts_with?("array") ? "array" : (label == "empty1" ? "empty" : "root")
      column = kind == "array" ? ARRAY_COLUMN : ROOT_COLUMN
      buckets = label == "root2" || label == "array2" ? 2_u64 : label == "empty1" ? 1_u64 : 32_u64
      profiles[label] = JSON::Any.new(profile_record(stocks[index], libraries[index], kind, column, buckets))
    end
    puts({
      "status" => "observed",
      "profiles" => JSON::Any.new(profiles),
    }.to_json)
  rescue ex : Exception
    STDERR.puts "W190 Crystal probe failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckObjectSharedBucketsW190.main(ARGV)
