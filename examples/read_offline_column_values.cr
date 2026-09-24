require "../src/crystal_click"

unless ARGV.size == 4
  STDERR.puts "usage: crystal run examples/read_offline_column_values.cr -- DATA_ROOT DATABASE TABLE COLUMN"
  exit 2
end

catalog = CrystalClick::OfflineCatalog.open(ARGV[0])
values = catalog[ARGV[1]][ARGV[2]][ARGV[3]].values

puts "#{ARGV[1]}.#{ARGV[2]}.#{ARGV[3]}: #{values.size} values"
values.first(5).each_with_index do |value, index|
  puts "#{index}: #{value.inspect}"
end
