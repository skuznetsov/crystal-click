require "../src/crystal_click"

module ScanUInt64PKRangeExample
  extend self

  def usage : NoReturn
    STDERR.puts "usage: crystal run examples/scan_uint64_pk_range.cr -- CLICKHOUSE_DATA_ROOT DATABASE TABLE KEY_COLUMN VALUE_COLUMN [--lower UINT64] [--upper UINT64]"
    STDERR.puts "at least one inclusive bound is required; omit either flag for an open-ended range"
    exit 64
  end

  def parse_bound(raw : String, option : String) : UInt64
    raw.to_u64?(whitespace: false) || raise ArgumentError.new("#{option} must be a UInt64")
  end

  def run(args : Array(String)) : Nil
    usage if args.size < 7

    root = args[0]
    database_name = args[1]
    table_name = args[2]
    key_column = args[3]
    value_column = args[4]
    lower_bound = nil.as(UInt64?)
    upper_bound = nil.as(UInt64?)

    index = 5
    while index < args.size
      option = args[index]
      usage if index + 1 >= args.size
      value = args[index + 1]

      case option
      when "--lower"
        raise ArgumentError.new("--lower may only be specified once") if lower_bound
        lower_bound = parse_bound(value, "--lower")
      when "--upper"
        raise ArgumentError.new("--upper may only be specified once") if upper_bound
        upper_bound = parse_bound(value, "--upper")
      else
        usage
      end
      index += 2
    end

    raise ArgumentError.new("at least one of --lower or --upper is required") unless lower_bound || upper_bound
    if lower_bound && upper_bound
      raise ArgumentError.new("--lower must not exceed --upper") if lower_bound.not_nil! > upper_bound.not_nil!
    end
    raise ArgumentError.new("key and value columns must be different") if key_column == value_column

    table = CrystalClick::OfflineCatalog.open(root).table(database_name, table_name)
    unless table.primary_key_column == key_column
      raise ArgumentError.new("KEY_COLUMN must be the table's supported ascending UInt64 ORDER BY column")
    end
    columns = [key_column, value_column]

    puts "#{key_column}\t#{value_column}"
    table.scan_uint64_pk_candidates(columns, lower_bound: lower_bound, upper_bound: upper_bound) do |batch|
      keys = batch.values_for(key_column)
      values = batch.values_for(value_column)
      keys.each_with_index do |key, row|
        if lower_bound
          next if key < lower_bound.not_nil!
        end
        if upper_bound
          next if key > upper_bound.not_nil!
        end

        puts "#{key}\t#{values[row]}"
      end
    end
  rescue ex : Exception
    STDERR.puts "primary-key range scan failed: #{ex.message}"
    exit 1
  end
end

ScanUInt64PKRangeExample.run(ARGV)
