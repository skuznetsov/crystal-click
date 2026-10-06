require "../src/crystal_click"
require "json"

module CheckArrayJSONPartsW185
  extend self

  alias Document = CrystalClick::ObjectDocument
  alias Marks = Array(Array(Array(Document)))

  def usage : NoReturn
    STDERR.puts "usage: check_array_json_parts_w185 STOCK_MIXED_PART STOCK_EMPTY_PART LIBRARY_PART_DEST"
    exit 64
  end

  def schema : CrystalClick::ObjectDocumentSchema
    CrystalClick::ObjectDocumentSchema.new(
      {"t" => CrystalClick::BinaryDataType.primitive("UInt8")},
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
    )
  end

  def plan(inner : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::ObjectDocumentPlan.new(structures, inner.typed_paths)
  end

  def doc(t : UInt8, shared : String) : Document
    Document.new({
      "t" => CrystalClick::BinaryValue.fixed(
        CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[t]),
      "shared" => CrystalClick::BinaryValue.string(shared),
    })
  end

  # Four two-row marks. The 0-child mark between populated marks and the
  # trailing 0-child mark distinguish child occurrences from parent rows.
  def mixed_granules : Marks
    [
      [[] of Document, [doc(7_u8, "red")] of Document],
      [[] of Document, [] of Document],
      [[doc(11_u8, "blue"), doc(13_u8, "green")] of Document, [] of Document],
      [[] of Document, [] of Document],
    ] of Array(Array(Document))
  end

  def signatures(rows : Marks) : Array(Array(Array(String)))
    rows.map do |mark|
      mark.map do |documents|
        documents.map do |document|
          "#{document.value_for("t").bytes[0]}:#{document.value_for("shared").as_string}"
        end
      end
    end
  end

  def table_signatures(part : String, column : String) : Array(Array(String))
    table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", column])
    rows = [] of Array(String)
    table.scan_typed(batch_rows: 2) do |batch|
      batch.array_object_documents_for(column).each do |documents|
        rows << documents.map do |document|
          "#{document.value_for("t").bytes[0]}:#{document.value_for("shared").as_string}"
        end
      end
      nil
    end
    rows
  end

  def reader_record(part : String, column : String, inner : CrystalClick::ObjectDocumentSchema) : Hash(String, JSON::Any)
    reader = CrystalClick::ArrayObjectColumnReader.open(part, column, inner)
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
      "full_rows"               => JSON.parse(signatures(full).to_json),
      "middle_rows"             => JSON.parse(signatures(middle).to_json),
      "table_rows"              => JSON.parse(table_signatures(part, column).to_json),
    }
  end

  def run(args : Array(String)) : Nil
    usage unless args.size == 3
    stock_mixed = args[0]
    stock_empty = args[1]
    library_part = args[2]
    inner = schema

    keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
    CrystalClick::WidePartWriter.write_uint64_array_object_pair(
      library_part, "pk", keys, "a", inner, plan(inner), mixed_granules,
      rows_per_mark: 2, mode: 0_u64, frame_bytes: 64,
    )

    library_record = reader_record(library_part, "a", inner)
    result = {
      "status"            => JSON::Any.new("observed"),
      "stock_mixed"       => JSON::Any.new(reader_record(stock_mixed, "a", inner)),
      "stock_empty"       => JSON::Any.new(reader_record(stock_empty, "a", inner)),
      "library_part"      => JSON::Any.new(library_record),
      "library_part_path" => JSON::Any.new(library_part),
    }
    puts result.to_json
  rescue ex : Exception
    STDERR.puts "W185 Crystal probe failed: #{ex.class}: #{ex.message}"
    exit 1
  end
end

CheckArrayJSONPartsW185.run(ARGV)
