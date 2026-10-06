#!/usr/bin/env ruby
# Bounded structural policy for the first table-facade extraction.
# This checks ownership, not runtime compatibility. --baseline additionally
# proves that the eight extracted bodies and the scan facade are unchanged.
require "open3"

root = File.expand_path("..", __dir__)
owners = {
  "WidePartNumericMapSliceBase" => "wide_part_numeric_map_slice_base",
  "WidePartNumericMapSlice" => "wide_part_numeric_map_slice",
  "WidePartNumericMapRowsBase" => "wide_part_numeric_map_rows_base",
  "WidePartNumericMapRows" => "wide_part_numeric_map_rows",
  "WidePartNumericMapArrayRows" => "wide_part_numeric_map_array_rows",
  "WidePartNullableNumericMapArrayRows" => "wide_part_nullable_numeric_map_array_rows",
  "WidePartNullableNumericMapRows" => "wide_part_nullable_numeric_map_rows",
  "WidePartTableBatch" => "wide_part_table_batch",
}.transform_values { |name| "src/crystal_click/wide_part_table/#{name}.cr" }

abort "usage: #{$PROGRAM_NAME} [--baseline REV]" unless ARGV.empty? || (ARGV.size == 2 && ARGV[0] == "--baseline")
declaration = /^  (?:abstract )?(?:class|struct) (\w+)/
errors = []
sources = Dir.glob(File.join(root, "src", "**", "*.cr")).to_h do |path|
  [path.delete_prefix(root + "/"), File.read(path)]
end

owners.each do |name, path|
  source = sources[path]
  if !source
    errors << "missing owner file: #{path}"
    next
  end
  errors << "expected exactly one owner #{name} in #{path}" unless source.scan(declaration).flatten == [name]
  homes = sources.select { |_file, text| text.scan(declaration).flatten.include?(name) }.keys
  errors << "duplicate or displaced owner #{name}: #{homes.join(', ')}" unless homes == [path]
end

facade = "src/crystal_click/wide_part_table.cr"
errors << "scan facade still owns other top-level classes" unless sources.fetch(facade).scan(declaration).flatten == ["WidePartTable"]
aliases = "src/crystal_click/wide_part_table/wide_part_table_type_aliases.cr"
errors << "missing alias-only owner" unless sources[aliases] && sources[aliases].scan(declaration).empty?
loader = sources.fetch("src/crystal_click.cr")
load_paths = [aliases, *owners.values, facade].map { |path| path.delete_prefix("src/").delete_suffix(".cr") }
positions = load_paths.map { |path| loader.index(%(require "./#{path}"\n)) }
errors << "missing or out-of-order umbrella requires" unless positions.all? && positions.each_cons(2).all? { |a, b| a < b }

if ARGV[0] == "--baseline"
  before, stderr, status = Open3.capture3("git", "-C", root, "show", "#{ARGV[1]}:#{facade}")
  abort "cannot read baseline: #{stderr}" unless status.success?
  [*owners, ["WidePartTable", facade]].each do |name, path|
    pattern = /^  (?:abstract )?(?:class|struct) #{Regexp.escape(name)}\b.*?^  end\n/m
    old_body = before[pattern]
    new_body = sources[path] && sources[path][pattern]
    errors << "class body changed or absent: #{name}" unless old_body && old_body == new_body
  end
  old_aliases = before.split("\n  abstract class WidePartNumericMapSliceBase", 2).first
  new_aliases = sources[aliases]&.sub(/\nend\n\z/, "")
  errors << "type aliases changed or absent" unless old_aliases == new_aliases
end

abort errors.join("\n") unless errors.empty?
puts "Table ownership: 8 extracted owners, alias-only file and single-owner facade passed#{ARGV.empty? ? '' : '; 9 baseline bodies and aliases unchanged'}"
