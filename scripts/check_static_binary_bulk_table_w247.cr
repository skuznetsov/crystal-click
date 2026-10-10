require "../src/crystal_click"
require "../scripts/support/static_binary_bulk_table_w247_fixture"
require "digest/sha256"
require "file_utils"
require "json"

private def w247_relative_path(root : String, path : String) : String
  path[root.bytesize + 1, path.bytesize - root.bytesize - 1]
end

private def w247_write_string_array(json : JSON::Builder, values : Array(String)) : Nil
  json.array do
    values.each { |value| json.string(value) }
  end
end

private def w247_read_uint64_le(bytes : Bytes, offset : Int) : UInt64
  if offset < 0 || offset > bytes.size - 8
    raise CrystalClick::CorruptPartError.new("W247 physical profile field is truncated")
  end
  value = 0_u64
  8.times do |index|
    value |= bytes[offset + index].to_u64 << (index * 8)
  end
  value
end

private def w247_add_physical_profile(json : JSON::Builder, part : String) : Nil
  metadata_path = File.join(part, "serialization.json")
  metadata = File.file?(metadata_path) ? JSON.parse(File.read(metadata_path)) : nil
  string_version = metadata.try do |document|
    document["types_serialization_versions"]?.try do |versions|
      versions.as_h["string"]?.try(&.as_i)
    end
  end

  json.field "physical_profile" do
    json.object do
      codec_path = File.join(part, "default_compression_codec.txt")
      json.field "codec", File.file?(codec_path) ? File.read(codec_path).strip : nil
      json.field "serialization_json_present", !metadata.nil?
      json.field "serialization_version", metadata.try { |document| document["version"]?.try(&.as_i) }
      json.field "string_serialization_version", string_version
      json.field "propagate_types_serialization_versions_to_nested_types",
        metadata.try { |document| document["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) }
      json.field "columns_txt", File.file?(File.join(part, "columns.txt")) ? File.read(File.join(part, "columns.txt")) : nil
      json.field "columns_substreams_txt",
        File.file?(File.join(part, "columns_substreams.txt")) ? File.read(File.join(part, "columns_substreams.txt")) : nil
      json.field "physical_stream_files" do
        json.array do
          Dir.glob(File.join(part, "**", "*")).select { |path| File.file?(path) }.sort!.each do |path|
            basename = File.basename(path)
            next unless basename.ends_with?(".bin") || basename.ends_with?(".mrk2") || basename.ends_with?(".cmrk2")
            size = File.size(path)
            mark_records = if basename.ends_with?(".mrk2") && size % CrystalClick::WidePart::MARK_SIZE == 0
                             size // CrystalClick::WidePart::MARK_SIZE
                           end
            json.object do
              json.field "path", w247_relative_path(part, path)
              json.field "bytes", size
              json.field "plain_mark_records", mark_records
            end
          end
        end
      end
      json.field "variant_discriminators" do
        json.array do
          StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS.each do |column|
            type = StaticBinaryBulkTableW247Fixture.types[column]
            physical = CrystalClick::BinaryBulkPhysicalPlan.new(
              type,
              column,
              CrystalClick::BinaryBulkProfile.single_stream,
            )
            physical.stream_names.keys.sort.each do |role|
              next unless role.ends_with?(".discriminators")
              stream_name = physical.stream_name_for(role)
              path = File.join(part, "#{CrystalClick::StreamName.hash(stream_name)}.bin")
              compressed = File.read(path).to_slice
              decoded = CrystalClick::CompressedBlock.decode_all(
                compressed,
                max_output_size: 1_048_576_i64,
              )
              mode_word = w247_read_uint64_le(decoded, 0)
              prefix_size = CrystalClick::BinaryBulkPhysicalPrefixAdapter::PREFIX_BYTES
              prefix = decoded[0, prefix_size].hexstring
              json.object do
                json.field "column", column
                json.field "type", type.name
                json.field "role", role
                json.field "logical_stream", stream_name
                json.field "file", File.basename(path)
                json.field "decoded_bytes", decoded.size
                json.field "decoded_sha256", Digest::SHA256.hexdigest(decoded)
                json.field "decoded_prefix_hex", prefix
                json.field "mode_word", mode_word
                json.field "mode", mode_word == CrystalClick::WideVariantTypePlanDescriptor::MODE_BASIC ? "BASIC" : "non_basic"
              end
            end
          end
        end
      end
    end
  end
end

private def w247_read_binary_column(part : String, name : String) : NamedTuple(
  type: String,
  profile: String,
  marks: Array(UInt64),
  signatures: Array(String),
)
  type = StaticBinaryBulkTableW247Fixture.types[name]
  reader = CrystalClick::BinaryBulkColumnReader.open(part, name, type)
  rows = reader.read_marks(0, reader.mark_count).flat_map { |mark| mark }
  {
    type:       reader.schema_declaration,
    profile:    reader.ordinary_profile.with_size_stream? ? "sized" : "single",
    marks:      reader.mark_row_counts,
    signatures: rows.map { |value| StaticBinaryBulkTableW247Fixture.row_signature(value) },
  }
end

private def w247_add_typed_scan(json : JSON::Builder, part : String) : Nil
  json.field "public_typed_scan" do
    json.object do
      selected = [StaticBinaryBulkTableW247Fixture::KEY_NAME] +
                 StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS +
                 StaticBinaryBulkTableW247Fixture::STRING_COLUMNS
      table = CrystalClick::WidePartTable.open_selected_typed([part], selected)
      signatures = Hash(String, Array(String)).new do |values, name|
        values[name] = [] of String
      end
      keys = [] of UInt64
      table.scan_typed do |batch|
        keys.concat(batch.values_for(StaticBinaryBulkTableW247Fixture::KEY_NAME))
        StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS.each do |name|
          batch.binary_bulk_values_for(name).each do |value|
            signatures[name] << StaticBinaryBulkTableW247Fixture.row_signature(value)
          end
        end
      end
      window_signatures = Hash(String, Array(String)).new do |values, name|
        values[name] = [] of String
      end
      window_keys = [] of UInt64
      table.scan_typed_window(4_u64, 1) do |batch|
        window_keys.concat(batch.values_for(StaticBinaryBulkTableW247Fixture::KEY_NAME))
        StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS.each do |name|
          batch.binary_bulk_values_for(name).each do |value|
            window_signatures[name] << StaticBinaryBulkTableW247Fixture.row_signature(value)
          end
        end
      end
      json.field "status", "ok"
      json.field "row_count", keys.size
      json.field "keys", keys
      json.field "column_signatures" do
        json.object do
          StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS.each do |name|
            json.field name, signatures[name]
          end
        end
      end
      json.field "late_window" do
        json.object do
          json.field "keys", window_keys
          json.field "column_signatures" do
            json.object do
              StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS.each do |name|
                json.field name, window_signatures[name]
              end
            end
          end
        end
      end
    end
  end
end

private def w247_add_offline_values(json : JSON::Builder, part : String) : Nil
  json.field "offline_values" do
    json.object do
      columns = [CrystalClick::OfflineColumn.new("pk", "UInt64")] of CrystalClick::OfflineColumn
      StaticBinaryBulkTableW247Fixture.types.each do |name, type|
        columns << CrystalClick::OfflineColumn.new(name, type.name)
      end
      info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
      candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part, info, 5_u64)
      table = CrystalClick::OfflineTable.new(
        "events", "w247-static-bulk", "MergeTree", columns,
        [candidate] of CrystalClick::OfflinePartCandidate,
      )
      json.field "status", "ok"
      json.field "columns" do
        json.object do
          StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS.each do |name|
            values = table[name].values(max_rows: 5_u64).map(&.as(CrystalClick::BinaryValue))
            json.field name do
              w247_write_string_array(
                json,
                values.map { |value| StaticBinaryBulkTableW247Fixture.row_signature(value) },
              )
            end
          end
        end
      end
    end
  end
end

private def w247_add_projection_scan(json : JSON::Builder, part : String) : Nil
  json.field "projection_scan" do
    json.object do
      child = File.join(part, "by_shape.proj")
      if Dir.exists?(child) && !File.symlink?(child)
        table = CrystalClick::WidePartTable.open_selected_projection_typed(
          [part], "by_shape", [StaticBinaryBulkTableW247Fixture::VARIANT_COLUMN]
        )
        signatures = [] of String
        table.scan_typed do |batch|
          batch.binary_bulk_values_for(StaticBinaryBulkTableW247Fixture::VARIANT_COLUMN).each do |value|
            signatures << StaticBinaryBulkTableW247Fixture.row_signature(value)
          end
        end
        json.field "status", "ok"
        json.field "row_count", signatures.size
        json.field "row_signatures", signatures
      else
        json.field "status", "absent"
      end
    end
  end
end

private def w247_report(part : String, action : String) : String
  types = StaticBinaryBulkTableW247Fixture.types
  columns = Hash(String, NamedTuple(
    type: String,
    profile: String,
    marks: Array(UInt64),
    signatures: Array(String),
  )).new
  StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS.each do |name|
    columns[name] = w247_read_binary_column(part, name)
  end
  key_reader = CrystalClick::WidePart.open_typed(part, StaticBinaryBulkTableW247Fixture::KEY_NAME)
  keys = key_reader.read_numeric_mark_range(
    StaticBinaryBulkTableW247Fixture::KEY_NAME, 0, key_reader.mark_count, UInt64
  )
  strings = Hash(String, Array(String)).new
  StaticBinaryBulkTableW247Fixture::STRING_COLUMNS.each do |name|
    reader = CrystalClick::WidePart.open_typed(part, name)
    strings[name] = reader.read_string_mark_range(name, 0, reader.mark_count)
  end
  files = Dir.glob(File.join(part, "**", "*")).select { |path| File.file?(path) }.sort!

  JSON.build do |json|
    json.object do
      json.field "format", StaticBinaryBulkTableW247Fixture::FORMAT
      json.field "action", action
      json.field "part", File.basename(part)
      json.field "row_count", keys.size
      json.field "keys", keys
      json.field "mark_row_counts", key_reader.mark_row_counts
      json.field "declarations" do
        json.object do
          json.field StaticBinaryBulkTableW247Fixture::KEY_NAME, "UInt64"
          types.each { |name, type| json.field name, type.name }
        end
      end
      json.field "columns" do
        json.object do
          StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS.each do |name|
            item = columns[name]
            json.field name do
              json.object do
                json.field "type", item[:type]
                json.field "profile", item[:profile]
                json.field "mark_row_counts", item[:marks]
                json.field "row_signatures", item[:signatures]
                json.field "row_sha256" do
                  w247_write_string_array(
                    json,
                    item[:signatures].map { |signature| Digest::SHA256.hexdigest(signature) },
                  )
                end
              end
            end
          end
        end
      end
      json.field "strings" do
        json.object do
          strings.each { |name, values| json.field name, values }
        end
      end
      w247_add_typed_scan(json, part)
      w247_add_offline_values(json, part)
      w247_add_projection_scan(json, part)
      w247_add_physical_profile(json, part)
      json.field "files" do
        json.array do
          files.each do |path|
            json.object do
              json.field "path", w247_relative_path(part, path)
              json.field "size", File.size(path)
              json.field "sha256", Digest::SHA256.hexdigest(File.read(path).to_slice)
            end
          end
        end
      end
    end
  end
end

unless (ARGV.size == 3 && ARGV[0] == "write") ||
       (ARGV.size == 2 && ARGV[0] == "inspect")
  STDERR.puts "usage: check_static_binary_bulk_table_w247.cr write PART_PATH single|sized"
  STDERR.puts "   or: check_static_binary_bulk_table_w247.cr inspect PART_PATH"
  exit(2)
end

action = ARGV[0]
part = File.expand_path(ARGV[1])
if action == "write"
  unless ARGV.size == 3 && (ARGV[2] == "single" || ARGV[2] == "sized")
    STDERR.puts "write requires the single or sized ordinary String profile"
    exit(2)
  end
  if File.exists?(part) || File.symlink?(part)
    raise CrystalClick::InvalidPartError.new("W247 output part already exists")
  end
  unless Dir.exists?(File.dirname(part))
    raise CrystalClick::InvalidPartError.new("W247 output parent directory does not exist")
  end
  StaticBinaryBulkTableW247Fixture.write_part(part, ARGV[2])
else
  if ARGV.size != 2 || !Dir.exists?(part) || File.symlink?(part)
    raise CrystalClick::InvalidPartError.new("W247 inspect path must be an existing non-symlink part directory")
  end
end

puts w247_report(part, action)
