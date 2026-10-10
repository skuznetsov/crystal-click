require "../src/crystal_click"
require "../scripts/support/static_nested_handoff_w248_fixture"
require "digest/sha256"
require "json"

private def w248_relative_path(root : String, path : String) : String
  path[root.bytesize + 1, path.bytesize - root.bytesize - 1]
end

private def w248_write_strings(json : JSON::Builder, values : Array(String)) : Nil
  json.array { values.each { |value| json.string(value) } }
end

private def w248_read_u64_le(bytes : Bytes, offset : Int) : UInt64
  if offset < 0 || offset > bytes.size - 8
    raise CrystalClick::CorruptPartError.new("W248 Variant prefix is truncated")
  end
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w248_nested_site_marks(part : String, profile_name : String) : Array(NamedTuple(
  nominal_type: String,
  nominal_tag: UInt8,
  site_path: String,
  site_type: String,
  role: String,
  logical_stream: String,
  file: String,
  marks: Array(NamedTuple(compressed_offset: UInt64, decompressed_offset: UInt64, rows: UInt64)),
  first_mark_zero: Bool,
  first_populated_mark_advances: Bool,
))
  column = StaticNestedHandoffW248Fixture::RECURSIVE_COLUMN
  type = StaticNestedHandoffW248Fixture.types[column]
  plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, column, StaticNestedHandoffW248Fixture.profile(profile_name))
  expected_roles = [
    "root.elements.field.0.indexes",
    "root.elements.field.1.discriminators",
  ]
  roles = plan.stream_names.keys.select do |role|
    role.ends_with?(".indexes") || role.ends_with?(".discriminators")
  end.sort!
  unless roles == expected_roles
    raise CrystalClick::CorruptPartError.new("W248 recursive Nested LC/Variant role roster differs")
  end

  roles.map do |role|
    logical = plan.stream_name_for(role)
    file = "#{CrystalClick::StreamName.hash(logical)}.mrk2"
    path = File.join(part, file)
    unless File.file?(path) && !File.symlink?(path) && File.size(path) == 4_i64 * CrystalClick::WidePart::MARK_SIZE
      raise CrystalClick::InvalidPartError.new("W248 recursive Nested site marks are absent or malformed: #{file}")
    end
    bytes = File.read(path).to_slice
    marks = Array(NamedTuple(compressed_offset: UInt64, decompressed_offset: UInt64, rows: UInt64)).new(4)
    4.times do |index|
      offset = index * CrystalClick::WidePart::MARK_SIZE
      marks << {
        compressed_offset:   w248_read_u64_le(bytes, offset),
        decompressed_offset: w248_read_u64_le(bytes, offset + 8),
        rows:                w248_read_u64_le(bytes, offset + 16),
      }
    end
    unless marks.map(&.[:rows]) == [2_u64, 2_u64, 1_u64, 0_u64]
      raise CrystalClick::CorruptPartError.new("W248 recursive Nested site mark grid differs")
    end
    first_zero = marks[0][:compressed_offset] == marks[1][:compressed_offset] &&
                 marks[0][:decompressed_offset] == marks[1][:decompressed_offset]
    populated_advances = marks[1][:compressed_offset] != marks[2][:compressed_offset] ||
                         marks[1][:decompressed_offset] != marks[2][:decompressed_offset]
    expected_first_decompressed = role.ends_with?(".discriminators") ? 8_u64 : 0_u64
    unless marks[0][:compressed_offset] == 0_u64 &&
           marks[0][:decompressed_offset] == expected_first_decompressed && first_zero && populated_advances
      raise CrystalClick::CorruptPartError.new("W248 recursive Nested site does not prove empty-first-mark then populated data")
    end
    is_variant = role.ends_with?(".discriminators")
    {
      nominal_type:                  type.name,
      nominal_tag:                   type.tag,
      site_path:                     is_variant ? "recursive_nested.choice" : "recursive_nested.label",
      site_type:                     is_variant ? "Variant(String, UInt64)" : "LowCardinality(Nullable(String))",
      role:                          role,
      logical_stream:                logical,
      file:                          file,
      marks:                         marks,
      first_mark_zero:               first_zero,
      first_populated_mark_advances: populated_advances,
    }
  end
end

private def w248_variant_sites(type : CrystalClick::BinaryDataType, path : String) : Array(NamedTuple(
  path: String,
  type: String,
  tag: UInt8,
  arms: Array(String),
))
  if type.tag == CrystalClick::BinaryDataType::TAG_VARIANT
    return [{
      path: path,
      type: type.name,
      tag:  type.tag,
      arms: type.children.map(&.name),
    }]
  end

  sites = [] of NamedTuple(path: String, type: String, tag: UInt8, arms: Array(String))
  case type.tag
  when CrystalClick::BinaryDataType::TAG_ARRAY
    sites.concat(w248_variant_sites(type.child_at(0), "#{path}[]"))
  when CrystalClick::BinaryDataType::TAG_NESTED
    tuple = type.child_at(0)
    tuple.child_count.times do |index|
      sites.concat(w248_variant_sites(tuple.child_at(index), "#{path}.#{tuple.field_name_display_at(index)}"))
    end
  when CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
    type.child_count.times do |index|
      sites.concat(w248_variant_sites(type.child_at(index), "#{path}.#{type.field_name_display_at(index)}"))
    end
  when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE
    type.child_count.times do |index|
      sites.concat(w248_variant_sites(type.child_at(index), "#{path}.#{index}"))
    end
  when CrystalClick::BinaryDataType::TAG_NULLABLE, CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
    sites.concat(w248_variant_sites(type.child_at(0), path))
  when CrystalClick::BinaryDataType::TAG_MAP
    sites.concat(w248_variant_sites(type.child_at(0), "#{path}.key"))
    sites.concat(w248_variant_sites(type.child_at(1), "#{path}.value"))
  else
    type.children.each_with_index do |child, index|
      sites.concat(w248_variant_sites(child, "#{path}.#{index}"))
    end
  end
  sites
end

private def w248_read_column(
  part : String,
  name : String,
  type : CrystalClick::BinaryDataType,
  profile_name : String,
) : NamedTuple(
  nominal_type: String,
  nominal_tag: UInt8,
  profile: String,
  mark_row_counts: Array(UInt64),
  row_signatures: Array(String),
)
  reader = CrystalClick::BinaryBulkColumnReader.open(part, name, type)
  profile = reader.ordinary_profile.with_size_stream? ? "sized" : "single"
  expected_profile = profile_name == "sized" ? "sized" : "single"
  unless reader.schema_declaration == type.name && profile == expected_profile
    raise CrystalClick::CorruptPartError.new("W248 direct column declaration/profile differs for #{name}")
  end
  rows = reader.read_marks(0, reader.mark_count).flat_map { |mark| mark }
  {
    nominal_type:    type.name,
    nominal_tag:     type.tag,
    profile:         profile,
    mark_row_counts: reader.mark_row_counts,
    row_signatures:  rows.map { |value| StaticNestedHandoffW248Fixture.row_signature(value) },
  }
end

private def w248_table_signatures(part : String) : NamedTuple(
  keys: Array(UInt64),
  columns: Hash(String, Array(String)),
)
  selected = [StaticNestedHandoffW248Fixture::KEY_NAME] +
             StaticNestedHandoffW248Fixture.types.keys
  table = CrystalClick::WidePartTable.open_selected_typed([part], selected)
  keys = [] of UInt64
  signatures = Hash(String, Array(String)).new do |values, name|
    values[name] = [] of String
  end
  table.scan_typed do |batch|
    keys.concat(batch.values_for(StaticNestedHandoffW248Fixture::KEY_NAME))
    StaticNestedHandoffW248Fixture.types.each_key do |name|
      if StaticNestedHandoffW248Fixture::TARGET_COLUMNS.includes?(name)
        batch.binary_bulk_values_for(name).each do |value|
          signatures[name] << StaticNestedHandoffW248Fixture.row_signature(value)
        end
      else
        batch.strings_for(name).each do |value|
          signatures[name] << StaticNestedHandoffW248Fixture.row_signature(CrystalClick::BinaryValue.string(value))
        end
      end
    end
  end
  {keys: keys, columns: signatures}
end

private def w248_offline_signatures(part : String) : Hash(String, Array(String))
  columns = [CrystalClick::OfflineColumn.new(StaticNestedHandoffW248Fixture::KEY_NAME, "UInt64")] of CrystalClick::OfflineColumn
  StaticNestedHandoffW248Fixture.types.each do |name, type|
    columns << CrystalClick::OfflineColumn.new(name, type.name)
  end
  info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
  candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part, info, StaticNestedHandoffW248Fixture::KEYS.size.to_u64)
  table = CrystalClick::OfflineTable.new("events", "w248-static-nested", "MergeTree", columns,
    [candidate] of CrystalClick::OfflinePartCandidate)
  result = Hash(String, Array(String)).new
  StaticNestedHandoffW248Fixture.types.each_key do |name|
    values = table[name].values(max_rows: StaticNestedHandoffW248Fixture::KEYS.size.to_u64)
    result[name] = values.map do |value|
      if value.is_a?(String)
        StaticNestedHandoffW248Fixture.row_signature(CrystalClick::BinaryValue.string(value.as(String)))
      else
        StaticNestedHandoffW248Fixture.row_signature(value.as(CrystalClick::BinaryValue))
      end
    end
  end
  result
end

private def w248_file_inventory(part : String) : Array(NamedTuple(path: String, size: Int64, sha256: String))
  unless Dir.exists?(part) && !File.symlink?(part) && File.real_path(part) == part
    raise CrystalClick::InvalidPartError.new("W248 part path must be a canonical non-symlink directory")
  end
  files = [] of NamedTuple(path: String, size: Int64, sha256: String)
  total = 0_i64
  entries = Dir.children(part).sort!
  if entries.size > 4_096
    raise CrystalClick::InvalidPartError.new("W248 part inventory exceeds its entry bound")
  end
  entries.each do |entry|
    path = File.join(part, entry)
    if File.symlink?(path)
      raise CrystalClick::InvalidPartError.new("W248 part contains a symlink")
    elsif Dir.exists?(path)
      raise CrystalClick::InvalidPartError.new("W248 part must be a flat directory")
    elsif !File.file?(path)
      raise CrystalClick::InvalidPartError.new("W248 part contains a special filesystem entry")
    end
    relative = w248_relative_path(part, path)
    if relative.includes?(File::SEPARATOR)
      raise CrystalClick::InvalidPartError.new("W248 part has a nested file path")
    end
    size = File.size(path)
    total += size
    if files.size >= 4_096 || size > 16_i64 * 1024 * 1024 || total > 64_i64 * 1024 * 1024
      raise CrystalClick::InvalidPartError.new("W248 part inventory exceeds its bound")
    end
    files << {path: relative, size: size, sha256: Digest::SHA256.hexdigest(File.read(path).to_slice)}
  end
  files
end

private def w248_variant_prefixes(
  part : String,
  profile_name : String,
) : Array(NamedTuple(
  column: String,
  nominal_type: String,
  nominal_tag: UInt8,
  site_path: String,
  site_type: String,
  site_tag: UInt8,
  arms: Array(String),
  role: String,
  logical_stream: String,
  file: String,
  decoded_bytes: Int32,
  prefix_hex: String,
  mode_word: UInt64,
  mode: String,
))
  result = [] of NamedTuple(
    column: String, nominal_type: String, nominal_tag: UInt8, site_path: String, site_type: String,
    site_tag: UInt8, arms: Array(String), role: String, logical_stream: String, file: String,
    decoded_bytes: Int32, prefix_hex: String, mode_word: UInt64, mode: String,
  )
  StaticNestedHandoffW248Fixture::TARGET_COLUMNS.each do |name|
    type = StaticNestedHandoffW248Fixture.types[name]
    sites = w248_variant_sites(type, name)
    if sites.size != 1
      raise CrystalClick::CorruptPartError.new("W248 expected exactly one Variant site in #{name}")
    end
    plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, name, StaticNestedHandoffW248Fixture.profile(profile_name))
    roles = plan.stream_names.keys.select(&.ends_with?(".discriminators")).sort!
    if roles.size != 1
      raise CrystalClick::CorruptPartError.new("W248 Variant discriminator stream roster differs for #{name}")
    end
    role = roles.first
    logical = plan.stream_name_for(role)
    file = "#{CrystalClick::StreamName.hash(logical)}.bin"
    compressed_path = File.join(part, file)
    unless File.file?(compressed_path) && !File.symlink?(compressed_path)
      raise CrystalClick::InvalidPartError.new("W248 Variant discriminator stream is absent: #{file}")
    end
    decoded = CrystalClick::CompressedBlock.decode_all(
      File.read(compressed_path).to_slice,
      max_output_size: 1_048_576_i64,
    )
    prefix_size = CrystalClick::BinaryBulkPhysicalPrefixAdapter::PREFIX_BYTES
    mode_word = w248_read_u64_le(decoded, 0)
    mode = mode_word == CrystalClick::WideVariantTypePlanDescriptor::MODE_BASIC ? "BASIC" : "other"
    if mode != "BASIC" || decoded.size < prefix_size
      raise CrystalClick::CorruptPartError.new("W248 Variant site is not BASIC or lacks its physical prefix")
    end
    site = sites.first
    result << {
      column:         name,
      nominal_type:   type.name,
      nominal_tag:    type.tag,
      site_path:      site[:path],
      site_type:      site[:type],
      site_tag:       site[:tag],
      arms:           site[:arms],
      role:           role,
      logical_stream: logical,
      file:           file,
      decoded_bytes:  decoded.size,
      prefix_hex:     decoded[0, prefix_size].hexstring,
      mode_word:      mode_word,
      mode:           mode,
    }
  end
  result
end

private def w248_report(part : String, action : String, profile_name : String) : String
  types = StaticNestedHandoffW248Fixture.types
  direct = Hash(String, NamedTuple(
    nominal_type: String,
    nominal_tag: UInt8,
    profile: String,
    mark_row_counts: Array(UInt64),
    row_signatures: Array(String),
  )).new
  types.each do |name, type|
    direct[name] = w248_read_column(part, name, type, profile_name)
  end
  key_reader = CrystalClick::WidePart.open_typed(part, StaticNestedHandoffW248Fixture::KEY_NAME)
  keys = key_reader.read_numeric_mark_range(
    StaticNestedHandoffW248Fixture::KEY_NAME, 0, key_reader.mark_count, UInt64
  )
  if keys != StaticNestedHandoffW248Fixture::KEYS
    raise CrystalClick::CorruptPartError.new("W248 key column differs from literal fixture")
  end

  table = w248_table_signatures(part)
  offline = w248_offline_signatures(part)
  expected = types.each_key.to_h do |name|
    {name, StaticNestedHandoffW248Fixture.rows_for(name).map { |value| StaticNestedHandoffW248Fixture.row_signature(value) }}
  end
  direct_signatures = direct.transform_values(&.[:row_signatures])
  unless table[:keys] == keys && direct_signatures == expected && table[:columns] == expected && offline == expected
    raise CrystalClick::CorruptPartError.new("W248 direct/table/offline typed consumers disagree with literal fixture")
  end

  files = w248_file_inventory(part)
  mark_files = files.compact_map do |entry|
    next unless entry[:path].ends_with?(".mrk2") || entry[:path].ends_with?(".cmrk2")
    if entry[:size] % CrystalClick::WidePart::MARK_SIZE != 0
      raise CrystalClick::CorruptPartError.new("W248 physical mark file has a partial record")
    end
    {path: entry[:path], records: entry[:size] // CrystalClick::WidePart::MARK_SIZE}
  end
  if mark_files.empty? || mark_files.any? { |item| item[:records] != 4 }
    raise CrystalClick::CorruptPartError.new("W248 physical marks must contain three parent marks and one EOF sentinel")
  end
  physical_variants = w248_variant_prefixes(part, profile_name)
  nested_site_marks = w248_nested_site_marks(part, profile_name)

  JSON.build do |json|
    json.object do
      json.field "format", StaticNestedHandoffW248Fixture::FORMAT
      json.field "action", action
      json.field "part", File.basename(part)
      json.field "profile", profile_name
      json.field "frame_bytes", StaticNestedHandoffW248Fixture::FRAME_BYTES
      json.field "row_count", keys.size
      json.field "keys", keys
      json.field "parent_mark_row_counts", key_reader.mark_row_counts
      json.field "physical_mark_files" do
        json.array do
          mark_files.each do |entry|
            json.object do
              json.field "path", entry[:path]
              json.field "records", entry[:records]
            end
          end
        end
      end
      json.field "nominal_binary_columns" do
        json.object do
          types.each do |name, type|
            json.field name do
              json.object do
                json.field "type", type.name
                json.field "tag", type.tag
                json.field "variant_sites" do
                  json.array do
                    w248_variant_sites(type, name).each do |site|
                      json.object do
                        json.field "path", site[:path]
                        json.field "type", site[:type]
                        json.field "tag", site[:tag]
                        json.field "arms" { w248_write_strings(json, site[:arms]) }
                      end
                    end
                  end
                end
                item = direct[name]
                json.field "profile", item[:profile]
                json.field "mark_row_counts", item[:mark_row_counts]
                json.field "row_signatures", item[:row_signatures]
              end
            end
          end
        end
      end
      json.field "consumer_signatures" do
        json.object do
          json.field "direct_binary_bulk" do
            json.object do
              direct.each { |name, item| json.field name, item[:row_signatures] }
            end
          end
          json.field "public_typed_table" do
            json.object do
              json.field "keys", table[:keys]
              json.field "columns" do
                json.object { table[:columns].each { |name, signatures| json.field name, signatures } }
              end
            end
          end
          json.field "offline_table" do
            json.object { offline.each { |name, signatures| json.field name, signatures } }
          end
        end
      end
      json.field "variant_discriminator_prefixes" do
        json.array do
          physical_variants.each do |entry|
            json.object do
              json.field "column", entry[:column]
              json.field "nominal_type", entry[:nominal_type]
              json.field "nominal_tag", entry[:nominal_tag]
              json.field "site_path", entry[:site_path]
              json.field "site_type", entry[:site_type]
              json.field "site_tag", entry[:site_tag]
              json.field "arms", entry[:arms]
              json.field "role", entry[:role]
              json.field "logical_stream", entry[:logical_stream]
              json.field "file", entry[:file]
              json.field "decoded_bytes", entry[:decoded_bytes]
              json.field "prefix_hex", entry[:prefix_hex]
              json.field "mode_word", entry[:mode_word]
              json.field "mode", entry[:mode]
            end
          end
        end
      end
      json.field "recursive_nested_site_marks" do
        json.array do
          nested_site_marks.each do |entry|
            json.object do
              json.field "nominal_type", entry[:nominal_type]
              json.field "nominal_tag", entry[:nominal_tag]
              json.field "site_path", entry[:site_path]
              json.field "site_type", entry[:site_type]
              json.field "role", entry[:role]
              json.field "logical_stream", entry[:logical_stream]
              json.field "file", entry[:file]
              json.field "marks" do
                json.array do
                  entry[:marks].each do |mark|
                    json.array do
                      json.number mark[:compressed_offset]
                      json.number mark[:decompressed_offset]
                      json.number mark[:rows]
                    end
                  end
                end
              end
              json.field "first_mark_zero", entry[:first_mark_zero]
              json.field "first_populated_mark_advances", entry[:first_populated_mark_advances]
            end
          end
        end
      end
      json.field "files" do
        json.array do
          files.each do |entry|
            json.object do
              json.field "path", entry[:path]
              json.field "size", entry[:size]
              json.field "sha256", entry[:sha256]
            end
          end
        end
      end
    end
  end
end

unless ARGV.size == 3 && (ARGV[0] == "write" || ARGV[0] == "inspect")
  STDERR.puts "usage: check_static_nested_handoff_w248.cr write PART_PATH single|sized"
  STDERR.puts "   or: check_static_nested_handoff_w248.cr inspect PART_PATH single|sized"
  exit(2)
end

action = ARGV[0]
part = File.expand_path(ARGV[1])
profile_name = ARGV.last
unless profile_name == "single" || profile_name == "sized"
  STDERR.puts "W248 String profile must be single or sized"
  exit(2)
end

if action == "write"
  if File.exists?(part) || File.symlink?(part)
    raise CrystalClick::InvalidPartError.new("W248 output part already exists")
  end
  unless Dir.exists?(File.dirname(part))
    raise CrystalClick::InvalidPartError.new("W248 output parent directory does not exist")
  end
  StaticNestedHandoffW248Fixture.write_part(part, profile_name, StaticNestedHandoffW248Fixture::FRAME_BYTES)
else
  if !Dir.exists?(part) || File.symlink?(part)
    raise CrystalClick::InvalidPartError.new("W248 inspect path must be an existing non-symlink part directory")
  end
end

puts w248_report(part, action, profile_name)
