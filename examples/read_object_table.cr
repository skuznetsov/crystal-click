require "../src/crystal_click"

module ReadObjectTableExample
  extend self

  def usage : NoReturn
    STDERR.puts "usage: crystal run examples/read_object_table.cr -- DATA_ROOT DATABASE TABLE UINT64_KEY_COLUMN JSON_COLUMN START_ROW WINDOW_ROWS LOWER_KEY UPPER_KEY"
    exit 64
  end

  def print_value(value : CrystalClick::BinaryValue, indent : String) : Nil
    if value.is_null?
      puts "#{indent}NULL (#{value.type.name})"
      return
    end

    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_ARRAY,
         CrystalClick::BinaryDataType::TAG_MAP,
         CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
         CrystalClick::BinaryDataType::TAG_NAMED_TUPLE,
         CrystalClick::BinaryDataType::TAG_NULLABLE
      puts "#{indent}#{value.type.name}"
      value.elements.each_with_index do |element, index|
        print_value(element, "#{indent}  [#{index}]")
      end
    else
      # Display raw bytes, not a guessed encoding or a lossy string conversion.
      puts "#{indent}#{value.type.name} hex=#{value.bytes.hexstring}"
    end
  end

  def print_batch(batch : CrystalClick::WidePartTableBatch, key_column : String, object_column : String, lower_key : UInt64? = nil, upper_key : UInt64? = nil) : Nil
    keys = batch.values_for(key_column)
    documents = batch.object_documents_for(object_column)
    raise CrystalClick::CorruptPartError.new("key/Object row count differs in table batch") unless keys.size == documents.size

    keys.each_with_index do |key, index|
      row = batch.source_row_offset + index.to_u64
      residual = if lower = lower_key
                   upper = upper_key || raise ArgumentError.new("candidate residual requires both bounds")
                   key >= lower && key <= upper ? "keep" : "reject"
                 else
                   "not-applicable"
                 end
      puts "part=#{batch.part_name} mark=#{batch.mark_index} row=#{row} #{key_column}=#{key} exact_residual=#{residual}"
      documents[index].paths.each do |path|
        puts "  #{object_column}.#{path.inspect}"
        print_value(documents[index].value_for(path), "    ")
      end
    end
  end

  def run(args : Array(String)) : Nil
    usage unless args.size == 9

    start_row = args[5].to_u64? || raise ArgumentError.new("START_ROW must be a non-negative integer")
    window_rows = args[6].to_i? || raise ArgumentError.new("WINDOW_ROWS must be an integer")
    lower_key = args[7].to_u64? || raise ArgumentError.new("LOWER_KEY must be a non-negative UInt64")
    upper_key = args[8].to_u64? || raise ArgumentError.new("UPPER_KEY must be a non-negative UInt64")
    raise ArgumentError.new("WINDOW_ROWS must be positive") if window_rows <= 0
    raise ArgumentError.new("LOWER_KEY exceeds UPPER_KEY") if lower_key > upper_key

    key_column = args[3]
    object_column = args[4]
    raise ArgumentError.new("key and Object columns must differ") if key_column == object_column
    columns = [key_column, object_column]
    table = CrystalClick::OfflineCatalog.open(args[0])[args[1]][args[2]]

    puts "Physical row window start=#{start_row} count=#{window_rows} (callback-scoped slices; document handles are owned)"
    table.scan_typed_window(columns, start_row, window_rows) do |batch|
      print_batch(batch, key_column, object_column)
      nil
    end

    puts "\nWhole PK candidate granules for inclusive range #{lower_key}..#{upper_key}; exact_residual marks rows to keep"
    table.scan_uint64_pk_candidates(columns, lower_bound: lower_key, upper_bound: upper_key) do |batch|
      print_batch(batch, key_column, object_column, lower_key, upper_key)
      nil
    end
  rescue ex : Exception
    STDERR.puts "Object table read failed: #{ex.message}"
    exit 1
  end
end

ReadObjectTableExample.run(ARGV)
