#!/usr/bin/env crystal

require "./support/schema_wide_part_w245_fixture"
require "json"

include CrystalClick

if ARGV.size != 3
  raise ArgumentError.new("usage: check_schema_wide_part_w245.cr PART_PATH single|sized basic|compact")
end

part_path = File.expand_path(ARGV[0])
string_profile_name = ARGV[1]
dynamic_mode_name = ARGV[2]
string_profile = SchemaWidePartW245Fixture.profile(string_profile_name)
dynamic_mode = SchemaWidePartW245Fixture.mode(dynamic_mode_name)
columns = SchemaWidePartW245Fixture.columns(string_profile, dynamic_mode)
keys = SchemaWidePartW245Fixture::KEYS

if File.exists?(part_path)
  raise ArgumentError.new("W245 helper destination already exists")
end

WidePartWriter.write_uint64_columns(
  part_path,
  SchemaWidePartW245Fixture::KEY_NAME,
  keys.to_unsafe.to_slice(keys.size),
  columns,
  rows_per_mark: SchemaWidePartW245Fixture::ROWS_PER_MARK,
  profile: string_profile,
  shared_profile: BinaryBulkProfile.single_stream,
  mode: dynamic_mode,
  frame_bytes: SchemaWidePartW245Fixture::FRAME_BYTES,
)

manifest = {
  "format"     => JSON::Any.new(SchemaWidePartW245Fixture::FORMAT),
  "part_path"  => JSON::Any.new(part_path),
  "key_column" => JSON::Any.new({
    "name" => JSON::Any.new(SchemaWidePartW245Fixture::KEY_NAME),
    "type" => JSON::Any.new("UInt64"),
  } of String => JSON::Any),
  "columns" => JSON::Any.new(
    SchemaWidePartW245Fixture.column_roster.map do |column|
      JSON::Any.new({
        "name" => JSON::Any.new(column["name"]),
        "type" => JSON::Any.new(column["type"]),
      } of String => JSON::Any)
    end
  ),
  "keys"            => JSON::Any.new(keys.map { |key| JSON::Any.new(key.to_i64) }),
  "mark_row_counts" => JSON::Any.new(SchemaWidePartW245Fixture::MARK_ROW_COUNTS.map { |rows| JSON::Any.new(rows.to_i64) }),
  "string_profile"  => JSON::Any.new(string_profile_name),
  "dynamic_mode"    => JSON::Any.new(dynamic_mode_name),
  "rows"            => JSON::Any.new(SchemaWidePartW245Fixture.expected_rows),
  "files"           => JSON::Any.new(
    SchemaWidePartW245Fixture.file_inventory(part_path).map { |file| JSON::Any.new(file) }
  ),
} of String => JSON::Any

puts manifest.to_json
