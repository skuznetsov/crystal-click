#!/usr/bin/env crystal

require "./support/multi_column_tuple_dynamic_w246_fixture"
require "json"

include CrystalClick

if ARGV.size != 4
  raise ArgumentError.new("usage: check_multi_column_tuple_dynamic_w246.cr PART_PATH single|sized basic|compact multi|legacy")
end

part_path = File.expand_path(ARGV[0])
string_profile_name = ARGV[1]
requested_mode_name = ARGV[2]
write_mode = ARGV[3]
string_profile = MultiColumnTupleDynamicW246Fixture.profile(string_profile_name)
requested_mode = MultiColumnTupleDynamicW246Fixture.operation_mode(requested_mode_name)

unless write_mode == "multi" || write_mode == "legacy"
  raise ArgumentError.new("W246 write mode must be multi or legacy")
end
if write_mode == "legacy" && requested_mode_name != "basic"
  raise ArgumentError.new("legacy Dynamic pair publisher has no requested COMPACT operation mode")
end
unless Dir.exists?(File.dirname(part_path))
  raise ArgumentError.new("W246 destination parent must already exist")
end
if File.exists?(part_path) || File.symlink?(part_path)
  raise ArgumentError.new("W246 helper destination already exists")
end

if write_mode == "multi"
  WidePartWriter.write_uint64_columns(
    part_path,
    MultiColumnTupleDynamicW246Fixture::KEY_NAME,
    MultiColumnTupleDynamicW246Fixture::KEYS.to_unsafe.to_slice(MultiColumnTupleDynamicW246Fixture::KEYS.size),
    MultiColumnTupleDynamicW246Fixture.multi_columns,
    rows_per_mark: MultiColumnTupleDynamicW246Fixture::ROWS_PER_MARK,
    profile: string_profile,
    shared_profile: BinaryBulkProfile.single_stream,
    mode: requested_mode,
    frame_bytes: MultiColumnTupleDynamicW246Fixture::FRAME_BYTES,
  )
else
  WidePartWriter.write_uint64_dynamic_bulk_part(
    part_path,
    MultiColumnTupleDynamicW246Fixture::KEY_NAME,
    MultiColumnTupleDynamicW246Fixture::KEYS.to_unsafe.to_slice(MultiColumnTupleDynamicW246Fixture::KEYS.size),
    MultiColumnTupleDynamicW246Fixture::NAMED_NAME,
    MultiColumnTupleDynamicW246Fixture.named_type,
    MultiColumnTupleDynamicW246Fixture.named_structures,
    MultiColumnTupleDynamicW246Fixture.named_granules,
    rows_per_mark: MultiColumnTupleDynamicW246Fixture::ROWS_PER_MARK,
    profile: string_profile,
    frame_bytes: MultiColumnTupleDynamicW246Fixture::FRAME_BYTES,
  )
end

manifest = MultiColumnTupleDynamicW246Fixture.manifest(
  part_path, string_profile_name, requested_mode_name, write_mode
)
puts JSON::Any.new(manifest).to_json
