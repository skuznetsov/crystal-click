require "../src/crystal_click"
require "digest/sha256"

unless ARGV.size == 1
  STDERR.puts "usage: compact_json_pushdown_probe <fixture-dir>"
  exit(2)
end

fixture = ARGV[0]
parts = Dir.children(fixture).sort.map { |name| File.join(fixture, name) }.select { |path| File.directory?(path) }
raise "fixture contains no Compact parts" if parts.empty?

table = CrystalClick::TypedPartTable.open_selected_typed(parts, ["id", "doc.tenant_id"])
raise "unexpected selected declarations" unless table.column_types == [{"id", "UInt64"}, {"doc.tenant_id", "UInt32"}]

payload = IO::Memory.new
table.scan_typed do |batch|
  ids = batch.values_for("id", UInt64)
  tenants = batch.values_for("doc.tenant_id", UInt32)
  raise "selected columns have different lengths" unless ids.size == tenants.size
  ids.each_with_index do |id, index|
    payload.write_bytes(id, IO::ByteFormat::LittleEndian)
    payload.write_bytes(tenants[index], IO::ByteFormat::LittleEndian)
  end
end

offset = 0
parts.each do |part|
  expected = File.read("#{part}.tenant.rowbinary").to_slice
  unless expected.size <= payload.size - offset && payload.to_slice[offset, expected.size] == expected
    raise "native RowBinary differs for #{File.basename(part)}"
  end
  offset += expected.size
end
raise "selected scan produced trailing rows" unless offset == payload.size
puts "rows=#{payload.size // 12} sha256=#{Digest::SHA256.hexdigest(payload.to_slice)}"
