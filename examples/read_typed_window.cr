require "../src/crystal_click"

unless ARGV.size == 7
  STDERR.puts "usage: crystal run examples/read_typed_window.cr -- DATA_ROOT DATABASE TABLE LEFT_UINT64 RIGHT_UINT64 START_ROW MAX_ROWS"
  exit 2
end

start_row = ARGV[5].to_u64?
max_rows = ARGV[6].to_i?
unless start_row && max_rows
  STDERR.puts "START_ROW and MAX_ROWS must be non-negative integers"
  exit 2
end

left_column = ARGV[3]
right_column = ARGV[4]
table = CrystalClick::OfflineCatalog.open(ARGV[0])[ARGV[1]][ARGV[2]]
table.scan_typed_window([left_column, right_column], start_row, max_rows) do |batch|
  left = batch.values_for(left_column)
  right = batch.values_for(right_column)
  left.each_with_index do |value, index|
    puts "row=#{batch.source_row_offset + index.to_u64} #{left_column}=#{value} #{right_column}=#{right[index]}"
  end
end
