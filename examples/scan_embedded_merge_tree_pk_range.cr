require "../src/crystal_click"

module ScanEmbeddedMergeTreePKRangeExample
  extend self

  def usage : NoReturn
    STDERR.puts "usage: crystal run examples/scan_embedded_merge_tree_pk_range.cr -- TABLE_ROOT [--lower UINT64] [--upper UINT64]"
    STDERR.puts "at least one inclusive bound is required"
    exit 64
  end

  def run(args : Array(String)) : Nil
    usage if args.size < 3 || args.size.even?

    root = args[0]
    lower_bound = nil.as(UInt64?)
    upper_bound = nil.as(UInt64?)
    index = 1
    while index < args.size
      option = args[index]
      value = args[index + 1].to_u64?(whitespace: false) || raise ArgumentError.new("#{option} must be a UInt64")
      case option
      when "--lower"
        raise ArgumentError.new("--lower specified twice") if lower_bound
        lower_bound = value
      when "--upper"
        raise ArgumentError.new("--upper specified twice") if upper_bound
        upper_bound = value
      else
        usage
      end
      index += 2
    end
    raise ArgumentError.new("at least one bound is required") unless lower_bound || upper_bound
    if lower_bound && upper_bound
      raise ArgumentError.new("--lower must not exceed --upper") if lower_bound.not_nil! > upper_bound.not_nil!
    end

    table = CrystalClick::EmbeddedMergeTreeTable.open(root)
    key_name = table.key_name
    value_name = table.value_name
    puts "#{key_name}\t#{value_name}"
    table.scan_uint64_pk_candidates([key_name, value_name], lower_bound: lower_bound, upper_bound: upper_bound) do |batch|
      keys = batch.values_for(key_name, UInt64)
      values = batch.strings_for(value_name)
      keys.each_with_index do |key, row|
        next if lower_bound && key < lower_bound.not_nil!
        next if upper_bound && key > upper_bound.not_nil!
        puts "#{key}\t#{values[row]}"
      end
    end
  rescue ex : Exception
    STDERR.puts "embedded primary-key range scan failed: #{ex.message}"
    exit 1
  end
end

ScanEmbeddedMergeTreePKRangeExample.run(ARGV)
