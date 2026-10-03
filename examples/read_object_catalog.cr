require "../src/crystal_click"

module ReadObjectCatalogExample
  extend self

  MAX_ROWS         = 1_000_u64
  MAX_STRING_BYTES = 16_u64 * 1024 * 1024
  MAX_TUPLE_CELLS  = 100_000_u64

  def usage : NoReturn
    STDERR.puts "usage: crystal run examples/read_object_catalog.cr -- DATA_ROOT DATABASE TABLE COLUMN"
    exit 64
  end

  def print_value(value : CrystalClick::BinaryValue, label : String, indent : String = "  ") : Nil
    type = value.type
    prefix = "#{indent}#{label}: #{type.name}"
    if value.is_null?
      puts "#{prefix} NULL"
      return
    end

    case type.tag
    when CrystalClick::BinaryDataType::TAG_ARRAY,
         CrystalClick::BinaryDataType::TAG_MAP,
         CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
         CrystalClick::BinaryDataType::TAG_NAMED_TUPLE,
         CrystalClick::BinaryDataType::TAG_NULLABLE
      elements = value.elements
      if elements.empty?
        puts "#{prefix} (empty; no scalar payload bytes)"
      else
        puts "#{prefix}"
        elements.each_with_index do |element, index|
          print_value(element, "[#{index}]", indent + "  ")
        end
      end
    else
      bytes = value.bytes
      puts "#{prefix} bytes=#{bytes.size} hex=#{bytes.hexstring}"
    end
  end

  def run(args : Array(String)) : Nil
    usage unless args.size == 4

    database_name, table_name, column_name = args[1], args[2], args[3]
    selection = CrystalClick::OfflineCatalog.open(args[0])[database_name][table_name][column_name]
    # This eagerly owns the complete selected result, subject to explicit
    # aggregate limits. It reads only the existing local Atomic catalog.
    values = selection.values(
      max_rows: MAX_ROWS,
      max_string_bytes: MAX_STRING_BYTES,
      max_tuple_cells: MAX_TUPLE_CELLS,
    )

    puts "#{database_name}.#{table_name}.#{column_name}: #{values.size} eagerly owned values (limits rows=#{MAX_ROWS}, string_bytes=#{MAX_STRING_BYTES}, tuple_cells=#{MAX_TUPLE_CELLS})"
    values.each_with_index do |value, row_index|
      document = value.as?(CrystalClick::ObjectDocument) ||
                 raise ArgumentError.new("selected column returned a non-ObjectDocument value")
      puts "row=#{row_index}"
      document.paths.each do |path|
        print_value(document.value_for(path), path.inspect)
      end
    end
  rescue ex : Exception
    STDERR.puts "Object catalog read failed: #{ex.message}"
    exit 1
  end
end

ReadObjectCatalogExample.run(ARGV)
