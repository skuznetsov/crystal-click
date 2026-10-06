require "../src/crystal_click"

module ReadArrayJSONW185Example
  extend self

  def usage : NoReturn
    STDERR.puts "usage: crystal run examples/read_array_json_w185.cr -- WIDE_PART JSON_ARRAY_COLUMN"
    exit 64
  end

  def print_value(value : CrystalClick::BinaryValue) : Nil
    if value.is_null?
      puts "NULL (#{value.type.name})"
    elsif value.type.tag == CrystalClick::BinaryDataType::TAG_STRING
      puts "#{value.type.name}=#{value.as_string.inspect}"
    elsif value.type.tag == CrystalClick::BinaryDataType::TAG_UINT8
      puts "#{value.type.name}=#{value.bytes[0]}"
    else
      puts "#{value.type.name} hex=#{value.bytes.hexstring}"
    end
  end

  def run(args : Array(String)) : Nil
    usage unless args.size == 2
    part = args[0]
    column = args[1]
    schema = CrystalClick::ObjectDocumentSchema.new(
      {"t" => CrystalClick::BinaryDataType.primitive("UInt8")},
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
    )
    reader = CrystalClick::ArrayObjectColumnReader.open(part, column, schema)
    puts "#{column}: #{reader.schema_declaration}; rows=#{reader.row_count}; marks=#{reader.mark_count}"
    puts "outer rows per mark: #{reader.mark_row_counts}"

    table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", column])
    table.scan_typed do |batch|
      rows = batch.array_object_documents_for(column)
      keys = batch.values_for("pk")
      raise CrystalClick::CorruptPartError.new("key/Array(JSON) row count differs") unless keys.size == rows.size
      rows.each_with_index do |documents, index|
        puts "pk=#{keys[index]} child_documents=#{documents.size}"
        documents.each_with_index do |document, document_index|
          puts "  document[#{document_index}]"
          document.paths.each do |path|
            print "    #{path.inspect}: "
            print_value(document.value_for(path))
          end
        end
      end
      nil
    end
  rescue ex : Exception
    STDERR.puts "Array(JSON) read failed: #{ex.message}"
    exit 1
  end
end

ReadArrayJSONW185Example.run(ARGV)
