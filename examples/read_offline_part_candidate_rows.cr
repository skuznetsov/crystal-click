require "../src/crystal_click"

unless ARGV.size == 1
  STDERR.puts "usage: crystal run examples/read_offline_part_candidate_rows.cr -- DATA_ROOT"
  exit 2
end

catalog = CrystalClick::OfflineCatalog.open(ARGV[0])
rows = catalog["system"]["part_candidates"]["rows"].values

puts "Physical part candidates: #{rows.size}"
puts "This is offline count.txt data, not ClickHouse server Active state."
rows.each_with_index do |row_count, index|
  puts "#{index}: #{row_count} rows"
end
