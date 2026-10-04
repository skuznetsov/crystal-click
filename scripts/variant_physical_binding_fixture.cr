# W149 finite native Wide binding witness for declared ordinary Variant.
#
# This harness discovers stock physical stream names, BASIC discriminator
# prefix ownership, nested Array levels, empty-arm files and raw K+1 mark
# grids. It then exchanges only normalized role lanes into a copied stock
# envelope and asks ClickHouse to ATTACH/CHECK and return RowBinary values.
# The borrowed envelope is not an independently authored complete part.
require "file_utils"
require "digest/sha256"
require "set"
require "../src/crystal_click"

W149_SOURCE_REVISION = "9007d227b64a3f8b667fc5258ceb2923f3cf477d"
W149_RUNTIME_SHA256  = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W149_RUNTIME_VERSION = "ClickHouse local version 26.10.1.1201 (official build)."
W149_BUILD_HASH      = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W149_ROOT_PREFIX     = "/private/tmp/crystal-click-variant-physical-w149."
W149_MAX_FILE_BYTES  = 8_i64 * 1024 * 1024
W149_MAX_CAPTURE     = 1_048_576
W149_ROWS_PER_MARK   = [2_u64, 2_u64, 2_u64]

class W149Mismatch < Exception
end

struct W149CommandResult
  getter stdout : String
  getter stderr : String
  getter exit_code : Int32

  def initialize(@stdout : String, @stderr : String, @exit_code : Int32)
  end

  def success? : Bool
    @exit_code == 0
  end
end

struct W149Fixture
  getter shape : String
  getter cell_id : String
  getter profile_name : String
  getter profile : CrystalClick::BinaryBulkProfile
  getter declarations : String
  getter type_names : Hash(String, String)
  getter types : Hash(String, CrystalClick::BinaryDataType)
  getter values : Hash(String, Array(Array(CrystalClick::BinaryValue)))
  getter columns : Array(String)

  def initialize(@shape : String, @cell_id : String, @profile_name : String,
                 @profile : CrystalClick::BinaryBulkProfile,
                 @declarations : String, @type_names : Hash(String, String),
                 @types : Hash(String, CrystalClick::BinaryDataType),
                 @values : Hash(String, Array(Array(CrystalClick::BinaryValue))),
                 @columns : Array(String))
  end

  def rows_for(column : String) : Array(CrystalClick::BinaryValue)
    rows = [] of CrystalClick::BinaryValue
    @values[column].each { |mark| mark.each { |value| rows << value } }
    rows
  end

  def row_count : Int32
    6
  end
end

def w149_fail(message : String) : NoReturn
  raise W149Mismatch.new(message)
end

def w149_assert(condition : Bool, message : String) : Nil
  w149_fail(message) unless condition
end

def w149_write_new(path : String, bytes : Bytes) : Nil
  w149_assert(bytes.size.to_i64 <= W149_MAX_FILE_BYTES, "W149 output exceeds 8 MiB: #{path}")
  w149_assert(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite W149 artifact: #{path}")
  File.open(path, "wb") { |file| file.write(bytes) }
end

def w149_write_new_text(path : String, text : String) : Nil
  w149_write_new(path, text.to_slice)
end

def w149_read_bytes(path : String, label : String) : Bytes
  w149_assert(File.file?(path) && !File.symlink?(path), "#{label}: missing regular file or symlink")
  size = File.size(path)
  w149_assert(size >= 0 && size <= W149_MAX_FILE_BYTES, "#{label}: file exceeds 8 MiB")
  File.open(path, "rb") do |file|
    bytes = Bytes.new(size.to_i32)
    file.read_fully(bytes) unless bytes.empty?
    bytes
  end
end

def w149_sha256(bytes : Bytes) : String
  Digest::SHA256.hexdigest(bytes)
end

def w149_sha256_file(path : String) : String
  digest = Digest::SHA256.new
  File.open(path, "rb") do |file|
    buffer = Bytes.new(64 * 1024)
    loop do
      count = file.read(buffer)
      break if count == 0
      digest.update(buffer[0, count])
    end
  end
  digest.final.hexstring
end

def w149_u64(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (8 * index)) & 0xff_u64).to_u8 }
end

def w149_concat(parts : Array(Bytes)) : Bytes
  total = parts.sum(&.size)
  result = Bytes.new(total)
  cursor = 0
  parts.each do |part|
    part.copy_to(result[cursor, part.size]) unless part.empty?
    cursor += part.size
  end
  result
end

def w149_u64_at(bytes : Bytes, offset : Int, label : String) : UInt64
  w149_assert(offset >= 0 && offset <= bytes.size - 8, "#{label}: UInt64 is outside captured bytes")
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def w149_uint64(value : UInt64) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.uint64(value)
end

def w149_uint8(value : UInt8) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[value])
end

def w149_variant_index(type : CrystalClick::BinaryDataType, arm_name : String) : Int32
  type.child_count.times do |index|
    return index.to_i32 if type.child_at(index).name == arm_name
  end
  w149_fail("#{type.name}: canonical Variant arm #{arm_name.inspect} is absent")
end

def w149_arm(type : CrystalClick::BinaryDataType, arm_name : String,
             child : CrystalClick::BinaryValue) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.variant(type, w149_variant_index(type, arm_name), child)
end

def w149_null_variant(type : CrystalClick::BinaryDataType) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.variant_null(type)
end

def w149_array(type : CrystalClick::BinaryDataType,
               children : Array(CrystalClick::BinaryValue)) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.array(type, children)
end

def w149_group(values : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
  w149_assert(values.size == 6, "W149 fixture must contain exactly six rows")
  [values[0, 2], values[2, 2], values[4, 2]]
end

def w149_literal_fixture(shape : String, profile_name : String,
                         mutant : Bool = false) : W149Fixture
  profile = profile_name == "single_stream" ? CrystalClick::BinaryBulkProfile.single_stream : CrystalClick::BinaryBulkProfile.with_size_stream
  string = CrystalClick::BinaryDataType.primitive("String")
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  declarations = ""
  types = Hash(String, CrystalClick::BinaryDataType).new
  names = Hash(String, String).new
  values = Hash(String, Array(Array(CrystalClick::BinaryValue))).new
  columns = [] of String

  case shape
  when "root"
    variant = CrystalClick::BinaryDataType.variant([uint64, string])
    w149_assert(variant.name == "Variant(String, UInt64)", "root Variant roster is not canonical")
    string_value = ->(text : String) { w149_arm(variant, "String", CrystalClick::BinaryValue.string(text)) }
    numeric_value = ->(number : UInt64) { w149_arm(variant, "UInt64", w149_uint64(number)) }
    main = [string_value.call("alpha"), numeric_value.call(mutant ? 43_u64 : 42_u64),
            string_value.call("omega"), w149_null_variant(variant), w149_null_variant(variant), numeric_value.call(7_u64)]
    unused = ["u0", "u1", "u2", "u3", "u4"].map { |text| string_value.call(text) }
    unused << w149_null_variant(variant)
    declarations = "v Variant(UInt64, String), v_unused_ordinary Variant(UInt64, String)"
    types["v"] = variant
    types["v_unused_ordinary"] = variant
    names["v"] = "Variant(String, UInt64)"
    names["v_unused_ordinary"] = "Variant(String, UInt64)"
    values["v"] = w149_group(main)
    values["v_unused_ordinary"] = w149_group(unused)
    columns = ["v", "v_unused_ordinary"]
  when "array_lc"
    low_string = CrystalClick::BinaryDataType.low_cardinality(string)
    variant = CrystalClick::BinaryDataType.variant([uint64, low_string])
    array_type = CrystalClick::BinaryDataType.array(variant)
    w149_assert(variant.name == "Variant(LowCardinality(String), UInt64)", "LC Variant roster is not canonical")
    string_value = ->(text : String) do
      low_value = CrystalClick::BinaryValue.low_cardinality(low_string, CrystalClick::BinaryValue.string(text))
      w149_arm(variant, "LowCardinality(String)", low_value)
    end
    numeric_value = ->(number : UInt64) { w149_arm(variant, "UInt64", w149_uint64(number)) }
    row = ->(children : Array(CrystalClick::BinaryValue)) { w149_array(array_type, children) }
    main = [row.call([string_value.call("red"), numeric_value.call(42_u64)]),
            row.call([numeric_value.call(7_u64)]),
            row.call([string_value.call("blue"), numeric_value.call(9_u64), string_value.call("red")]),
            row.call([string_value.call("green")]), row.call([] of CrystalClick::BinaryValue),
            row.call([] of CrystalClick::BinaryValue)]
    unused = [row.call([numeric_value.call(5_u64)]), row.call([] of CrystalClick::BinaryValue),
              row.call([numeric_value.call(8_u64), numeric_value.call(9_u64)]),
              row.call([] of CrystalClick::BinaryValue), row.call([] of CrystalClick::BinaryValue),
              row.call([numeric_value.call(10_u64)])]
    declarations = "v Array(Variant(UInt64, LowCardinality(String))), " +
                   "v_unused_lc Array(Variant(UInt64, LowCardinality(String)))"
    types["v"] = array_type
    types["v_unused_lc"] = array_type
    names["v"] = "Array(Variant(LowCardinality(String), UInt64))"
    names["v_unused_lc"] = "Array(Variant(LowCardinality(String), UInt64))"
    values["v"] = w149_group(main)
    values["v_unused_lc"] = w149_group(unused)
    columns = ["v", "v_unused_lc"]
  when "array_nested"
    inner = CrystalClick::BinaryDataType.array(uint8)
    variant = CrystalClick::BinaryDataType.variant([uint64, inner])
    array_type = CrystalClick::BinaryDataType.array(variant)
    w149_assert(variant.name == "Variant(Array(UInt8), UInt64)", "nested Array Variant roster is not canonical")
    array_value = ->(numbers : Array(UInt8)) do
      children = numbers.map { |number| w149_uint8(number) }
      w149_arm(variant, "Array(UInt8)", CrystalClick::BinaryValue.array(inner, children))
    end
    numeric_value = ->(number : UInt64) { w149_arm(variant, "UInt64", w149_uint64(number)) }
    row = ->(children : Array(CrystalClick::BinaryValue)) { w149_array(array_type, children) }
    main = [row.call([array_value.call([1_u8, 2_u8]), numeric_value.call(42_u64)]),
            row.call([numeric_value.call(7_u64)]), row.call([array_value.call([3_u8])]),
            row.call([] of CrystalClick::BinaryValue), row.call([] of CrystalClick::BinaryValue),
            row.call([numeric_value.call(9_u64)])]
    declarations = "v Array(Variant(Array(UInt8), UInt64))"
    types["v"] = array_type
    names["v"] = "Array(Variant(Array(UInt8), UInt64))"
    values["v"] = w149_group(main)
    columns = ["v"]
  else
    w149_fail("unknown W149 fixture shape #{shape.inspect}")
  end

  W149Fixture.new(shape, "#{shape}_#{profile_name}", profile_name, profile,
    declarations, names, types, values, columns)
end

def w149_sql_quote(value : String) : String
  "'#{value.gsub("\\", "\\\\").gsub("'", "\\'")}'"
end

def w149_sql_literal(value : CrystalClick::BinaryValue) : String
  type = value.type
  if value.is_null?
    return "CAST(NULL AS #{type.name})"
  end
  case type.tag
  when CrystalClick::BinaryDataType::TAG_VARIANT
    child = value.variant_child? || w149_fail("non-NULL Variant has no child value")
    "CAST(#{w149_sql_literal(child)} AS #{type.name})"
  when CrystalClick::BinaryDataType::TAG_ARRAY
    elements = value.elements.map { |child| w149_sql_literal(child) }
    "CAST([#{elements.join(", ")}] AS #{type.name})"
  when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
    child = value.child_at(0)
    "CAST(#{w149_sql_literal(child)} AS #{type.name})"
  when CrystalClick::BinaryDataType::TAG_STRING
    w149_sql_quote(value.as_string)
  when CrystalClick::BinaryDataType::TAG_UINT64
    "toUInt64(#{value.as_uint64})"
  when CrystalClick::BinaryDataType::TAG_UINT8
    "toUInt8(#{value.bytes[0]})"
  else
    w149_fail("W149 SQL literal does not admit #{type.name}")
  end
end

def w149_rows_sql(table : String, fixture : W149Fixture) : String
  rows = [] of String
  6.times do |index|
    fields = ["toUInt64(#{index + 1})"]
    fixture.columns.each do |column|
      fields << w149_sql_literal(fixture.rows_for(column)[index])
    end
    rows << "(#{fields.join(", ")})"
  end
  "INSERT INTO default.#{table} (k, #{fixture.columns.join(", ")}) VALUES\n#{rows.join(",\n")}"
end

def w149_settings(profile_name : String) : String
  "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, " +
    "min_rows_for_wide_part=0, min_bytes_for_wide_part=0, min_level_for_wide_part=0, " +
    "escape_variant_subcolumn_filenames=1, " +
    "default_compression_codec='LZ4', compress_marks=0, write_final_mark=1, " +
    "min_compress_block_size=0, max_compress_block_size=4096, " +
    "serialization_info_version='with_types', string_serialization_version='#{profile_name}', " +
    "nullable_serialization_version='basic', propagate_types_serialization_versions_to_nested_types=1, " +
    "use_compact_variant_discriminators_serialization=0"
end

def w149_create_query(table : String, fixture : W149Fixture) : String
  "CREATE TABLE default.#{table} (k UInt64, #{fixture.declarations}) " +
    "ENGINE=MergeTree ORDER BY k SETTINGS #{w149_settings(fixture.profile_name)}"
end

def w149_case_root(root : String, cell : String, phase : String) : String
  path = File.join(root, "cases", cell, phase)
  FileUtils.mkdir_p(File.join(path, "queries"))
  path
end

def w149_run(binary : String, store : String, case_root : String,
             label : String, sql : String) : W149CommandResult
  w149_assert(File.directory?(store) && !File.symlink?(store), "#{label}: missing or symlinked ClickHouse store")
  queries = File.join(case_root, "queries")
  stem = label.gsub(/[^A-Za-z0-9_-]/, "-")
  sql_path = File.join(queries, "#{stem}.sql")
  stdout_path = File.join(queries, "#{stem}.stdout.bin")
  stderr_path = File.join(queries, "#{stem}.stderr.txt")
  status_path = File.join(queries, "#{stem}.status.txt")
  w149_write_new_text(sql_path, sql + "\n")
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store,
                                "--session_timezone=UTC", "--max_threads=1", "--max_insert_threads=1",
                                "--max_block_size=1000", "--max_memory_usage=536870912",
                                "--max_query_size=1048576", "--allow_suspicious_variant_types=1",
                                "--allow_suspicious_low_cardinality_types=1",
                                "--low_cardinality_max_dictionary_size=8192",
                                "--low_cardinality_use_single_dictionary_for_part=0",
                                "--print_pretty_type_names=0",
                                "--query", sql], output: stdout, error: stderr)
  w149_assert(stdout.size <= W149_MAX_CAPTURE && stderr.size <= W149_MAX_CAPTURE,
    "#{label}: stdout or stderr exceeded 1 MiB")
  w149_write_new(stdout_path, stdout.to_slice)
  w149_write_new_text(stderr_path, stderr.to_s)
  w149_write_new_text(status_path, "#{status.exit_code || -1}\n")
  W149CommandResult.new(stdout.to_s, stderr.to_s, status.exit_code || -1)
end

def w149_expect_success(binary : String, store : String, case_root : String,
                        label : String, sql : String) : W149CommandResult
  result = w149_run(binary, store, case_root, label, sql)
  w149_assert(result.success?, "ClickHouse #{label} failed (#{result.exit_code}): #{result.stderr}")
  result
end

def w149_new_store(root : String, name : String) : String
  path = File.join(root, "stores", name)
  w149_assert(!File.exists?(path) && !File.symlink?(path), "refusing to reuse W149 store #{path}")
  Dir.mkdir(path)
  path
end

def w149_find_part(store : String, label : String) : String
  candidates = Dir.glob(File.join(store, "**", "all_1_1_0"))
  w149_assert(candidates.size == 1, "#{label}: expected exactly one stock part, found #{candidates.size}")
  part = candidates.first
  w149_assert(File.directory?(part) && !File.symlink?(part), "#{label}: part is missing or symlinked")
  part
end

def w149_data_path(binary : String, store : String, case_root : String,
                   table : String, label : String) : String
  result = w149_expect_success(binary, store, case_root, "data-path-#{label}",
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw")
  path = result.stdout.strip
  canonical_store = File.expand_path(store)
  canonical_path = File.expand_path(path)
  w149_assert(path.starts_with?("/") && canonical_path.starts_with?(canonical_store.rstrip('/') + "/"),
    "#{label}: data path escaped the isolated store")
  current = ""
  canonical_path.split('/').each do |component|
    next if component.empty?
    current = current.empty? ? "/#{component}" : File.join(current, component)
    w149_assert(!File.symlink?(current), "#{label}: data path contains a symlink")
  end
  w149_assert(File.directory?(canonical_path), "#{label}: data path is not a directory")
  canonical_path
end

def w149_attach(binary : String, store : String, case_root : String,
                table : String, part : String, label : String) : Nil
  data_path = w149_data_path(binary, store, case_root, table, label)
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  destination = File.join(detached, "all_1_1_0")
  w149_assert(!File.exists?(destination) && !File.symlink?(destination), "refusing to overwrite detached W149 part")
  FileUtils.cp_r(part, destination)
  w149_assert(!File.symlink?(destination), "W149 detached part is a symlink")
  result = w149_expect_success(binary, store, case_root, "attach-#{label}",
    "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w149_assert(result.success?, "#{label}: ATTACH PART failed")
  nil
end

def w149_verify_check(binary : String, store : String, case_root : String,
                      table : String, label : String) : Nil
  result = w149_expect_success(binary, store, case_root, "check-#{label}",
    "CHECK TABLE default.#{table} FORMAT TSVRaw")
  accepted = ["1\t\n", "1\n", "all_1_1_0\t1\t\n"]
  w149_assert(accepted.includes?(result.stdout), "#{label}: CHECK TABLE did not report success: #{result.stdout.inspect}")
  nil
end

def w149_verify_table(binary : String, store : String, case_root : String,
                      table : String, fixture : W149Fixture, label : String) : Nil
  w149_verify_check(binary, store, case_root, table, label)
  result = w149_expect_success(binary, store, case_root, "types-#{label}",
    "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  expected = ["k\tUInt64"] of String
  fixture.columns.each { |column| expected << "#{column}\t#{fixture.type_names[column]}" }
  w149_assert(result.stdout.lines.map(&.chomp) == expected,
    "#{label}: canonical system.columns type roster differs: #{result.stdout.inspect}")
  w149_write_new_text(File.join(case_root, "types.expected.tsv"), expected.join("\n") + "\n")

  ddl_result = w149_expect_success(binary, store, case_root, "ddl-#{label}",
    "SELECT create_table_query FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw")
  normalized_ddl = ddl_result.stdout.gsub(" ", "").downcase
  w149_assert(normalized_ddl.includes?("use_compact_variant_discriminators_serialization=0"),
    "#{label}: persisted table DDL does not pin BASIC Variant discriminator serialization")
  w149_assert(normalized_ddl.includes?("escape_variant_subcolumn_filenames=1"),
    "#{label}: persisted table DDL does not pin escaped Variant subcolumn filenames")

  settings = w149_expect_success(binary, store, case_root, "low-cardinality-settings-#{label}",
    "SELECT name, value FROM system.settings " +
    "WHERE name IN ('low_cardinality_max_dictionary_size', 'low_cardinality_use_single_dictionary_for_part') " +
    "ORDER BY name FORMAT TSVRaw")
  expected_settings = "low_cardinality_max_dictionary_size\t8192\n" +
                      "low_cardinality_use_single_dictionary_for_part\t0\n"
  w149_assert(settings.stdout == expected_settings,
    "#{label}: effective LowCardinality session settings differ: #{settings.stdout.inspect}")
  w149_write_new_text(File.join(case_root, "effective-low-cardinality-settings.expected.tsv"), expected_settings)

  count = w149_expect_success(binary, store, case_root, "count-#{label}",
    "SELECT count(), min(k), max(k) FROM default.#{table} FORMAT TSVRaw")
  w149_assert(count.stdout == "6\t1\t6\n", "#{label}: row-count/key witness differs: #{count.stdout.inspect}")
  parts = w149_expect_success(binary, store, case_root, "parts-#{label}",
    "SELECT rows, marks FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw")
  # ClickHouse's system.parts.marks includes the terminal EOF record; this is
  # four records for three real two-row marks, unlike the logical codec's K=3.
  w149_assert(parts.stdout == "6\t4\n", "#{label}: system.parts row/terminal-mark witness differs: #{parts.stdout.inspect}")
  nil
end

def w149_plan(type : CrystalClick::BinaryDataType, column : String,
              profile : CrystalClick::BinaryBulkProfile) : CrystalClick::BinaryBulkPhysicalPlan
  CrystalClick::BinaryBulkPhysicalPlan.new(type, column, profile: profile)
end

def w149_stream_paths(part : String, logical : String) : Tuple(String, String)
  basename = CrystalClick::StreamName.hash(logical)
  {File.join(part, "#{basename}.bin"), File.join(part, "#{basename}.mrk2")}
end

def w149_parse_marks(bytes : Bytes, label : String) : Array(Tuple(UInt64, UInt64, UInt64))
  size = CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE
  w149_assert(!bytes.empty? && bytes.size % size == 0, "#{label}: .mrk2 is not whole 24-byte records")
  count = bytes.size // size
  w149_assert(count == 4, "#{label}: expected three real marks and terminal, got #{count}")
  records = [] of Tuple(UInt64, UInt64, UInt64)
  count.times do |index|
    offset = index * size
    records << {w149_u64_at(bytes, offset, label), w149_u64_at(bytes, offset + 8, label),
                w149_u64_at(bytes, offset + 16, label)}
  end
  [2_u64, 2_u64, 2_u64, 0_u64].each_with_index do |expected_rows, index|
    w149_assert(records[index][2] == expected_rows, "#{label}: .mrk2 row count #{index} differs")
  end
  records
end

def w149_limits : CrystalClick::CompressedStreamBudget
  limits = CrystalClick::CompressedStreamLimits.new(
    max_file_bytes: W149_MAX_FILE_BYTES,
    max_mark_bytes: 1024 * 1024,
    max_frame_compressed_bytes: W149_MAX_FILE_BYTES,
    max_frame_decompressed_bytes: W149_MAX_FILE_BYTES,
    max_records: 100_000,
    max_decoded_bytes: W149_MAX_FILE_BYTES,
    max_result_bytes: W149_MAX_FILE_BYTES,
  )
  CrystalClick::CompressedStreamBudget.new(limits)
end

def w149_role_is_variant_discriminator?(role : String) : Bool
  role.ends_with?(".discriminators")
end

def w149_role_is_lc_lane?(role : String) : Bool
  role.ends_with?(".dictionary") || role.ends_with?(".indexes")
end

def w149_normalize_stock(role : String, prefix : Int32, raw : Bytes,
                         offsets : Array(UInt64), label : String) : Tuple(Bytes, Array(UInt64), String)
  if w149_role_is_variant_discriminator?(role)
    w149_assert(prefix == 8, "#{label}: BASIC Variant discriminator role did not own its 8-byte mode prefix")
    w149_assert(raw.size >= 8 && w149_u64_at(raw, 0, label) == 0_u64,
      "#{label}: BASIC Variant discriminator prefix is not u64(0)")
    w149_assert(offsets.first == 8_u64, "#{label}: raw discriminator grid does not begin after its prefix")
    normalized_offsets = offsets.map do |offset|
      w149_assert(offset >= 8_u64, "#{label}: discriminator offset precedes its mode prefix")
      offset - 8_u64
    end
    {raw[8, raw.size - 8], normalized_offsets, "strip-u64-basic-mode-prefix"}
  elsif w149_role_is_lc_lane?(role) && role.ends_with?(".dictionary")
    w149_assert(prefix == 8, "#{label}: LowCardinality dictionary prefix ownership differs")
    w149_assert(raw.size >= 8 && w149_u64_at(raw, 0, label) == 1_u64,
      "#{label}: LowCardinality dictionary version prefix is not u64(1)")
    w149_assert(offsets.first == 8_u64, "#{label}: LC dictionary grid does not begin after its version prefix")
    {raw, offsets, "retain-lc-version-prefix-in-codec-lane"}
  else
    w149_assert(prefix == 0, "#{label}: unexpected physical prefix on ordinary lane #{role}")
    w149_assert(offsets.first == 0_u64, "#{label}: ordinary lane grid does not begin at zero")
    {raw, offsets, "none"}
  end
end

def w149_capture_streams(part : String, fixture : W149Fixture, column : String,
                         label : String, evidence_root : String,
                         lane_manifest : IO) : CrystalClick::BinaryBulkStreams
  type = fixture.types[column]
  plan = w149_plan(type, column, fixture.profile)
  streams = Hash(String, CrystalClick::BinaryBulkStream).new
  plan.stream_names.keys.sort.each do |role|
    logical = plan.stream_name_for(role)
    data_path, mark_path = w149_stream_paths(part, logical)
    raw_compressed = w149_read_bytes(data_path, "#{label} #{role} compressed stream")
    raw_mark_bytes = w149_read_bytes(mark_path, "#{label} #{role} mark grid")
    raw_records = w149_parse_marks(raw_mark_bytes, "#{label} #{role}")
    prefix = plan.prefix_size_for(role)
    grid = CrystalClick::CompressedMarkReader.inspect(data_path, mark_path,
      raw_compressed.size.to_i64, raw_mark_bytes.size.to_i64, prefix, w149_limits)
    w149_assert(grid.mark_count == 3 && grid.rows_per_mark == W149_ROWS_PER_MARK,
      "#{label} #{role}: inspected K=3/rows-per-mark schedule differs")
    w149_assert(grid.positions.size == 4 && grid.positions.last == grid.logical_size,
      "#{label} #{role}: inspected grid lacks its physical EOF coordinate")
    w149_assert(grid.logical_size <= W149_MAX_FILE_BYTES, "#{label} #{role}: decoded stream exceeds 8 MiB")
    decompressed = raw_compressed.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(raw_compressed, max_output_size: W149_MAX_FILE_BYTES)
    w149_assert(grid.logical_size == decompressed.size.to_i64,
      "#{label} #{role}: frame-walked EOF differs from decompressed bytes")
    raw_positions = grid.positions.map(&.to_u64)
    w149_assert(raw_positions.last == decompressed.size.to_u64, "#{label} #{role}: K+1 grid does not end at EOF")
    normalized_bytes, normalized_positions, normalization =
      w149_normalize_stock(role, prefix, decompressed, raw_positions, "#{label} #{role}")

    stem = "#{label.gsub('/', "-")}-#{CrystalClick::StreamName.hash(logical)}"
    w149_write_new(File.join(evidence_root, "#{stem}.compressed.bin"), raw_compressed)
    w149_write_new(File.join(evidence_root, "#{stem}.mrk2"), raw_mark_bytes)
    w149_write_new(File.join(evidence_root, "#{stem}.decompressed.bin"), decompressed)
    w149_write_new(File.join(evidence_root, "#{stem}.normalized.bin"), normalized_bytes)
    records_text = raw_records.map { |record| "#{record[0]}:#{record[1]}:#{record[2]}" }.join(",")
    lane_manifest << "#{label}\t#{column}\t#{role}\t#{logical}\t#{File.basename(data_path)}\t#{prefix}\t#{normalization}\t"
    lane_manifest << "#{raw_compressed.size}\t#{decompressed.size}\t#{normalized_bytes.size}\t"
    lane_manifest << "#{raw_positions.join(",")}\t#{normalized_positions.join(",")}\t"
    lane_manifest << "#{grid.rows_per_mark.join(",")}\t#{records_text}\t#{w149_sha256(raw_compressed)}\t#{w149_sha256(decompressed)}\n"
    streams[role] = CrystalClick::BinaryBulkStream.new(normalized_bytes, normalized_positions)
  end
  CrystalClick::BinaryBulkStreams.new(mark_count: 3, streams: streams)
end

def w149_capture_part(part : String, fixture : W149Fixture, label : String,
                      root : String, lane_manifest : IO) : Hash(String, CrystalClick::BinaryBulkStreams)
  w149_assert(File.directory?(part) && !File.symlink?(part), "#{label}: part is missing or symlinked")
  checksums = CrystalClick::PartChecksums.open(part)
  w149_assert(!checksums.entries.empty?, "#{label}: empty checksums roster")
  checksums.entries.each_key do |name|
    path = File.join(part, name)
    w149_assert(File.size(path) <= W149_MAX_FILE_BYTES, "#{label}: checksummed file exceeds 8 MiB")
    checksums.validate_selected_entries(part, name)
  end
  metadata_path = File.join(part, "columns_substreams.txt")
  metadata = w149_read_bytes(metadata_path, "#{label} columns_substreams.txt")
  names_in_metadata = String.new(metadata).lines.select(&.starts_with?("\t")).map(&.strip).to_set
  expected_names = Set(String).new
  fixture.types.each do |column, type|
    plan = w149_plan(type, column, fixture.profile)
    plan.stream_names.each_value do |logical|
      expected_names << logical
    end
  end
  key_type = CrystalClick::BinaryDataType.primitive("UInt64")
  key_plan = w149_plan(key_type, "k", fixture.profile)
  key_plan.stream_names.each_value { |logical| expected_names << logical }
  w149_assert(names_in_metadata == expected_names,
    "#{label}: columns_substreams roster differs: #{names_in_metadata.to_a.sort.inspect} != #{expected_names.to_a.sort.inspect}")

  expected_bases = expected_names.map { |logical| CrystalClick::StreamName.hash(logical) }.to_set
  actual_bases = Dir.children(part).select(&.ends_with?(".bin")).map { |name| name[0, name.bytesize - 4] }.to_set
  actual_mark_bases = Dir.children(part).select(&.ends_with?(".mrk2")).map { |name| name[0, name.bytesize - 5] }.to_set
  w149_assert(actual_bases == expected_bases, "#{label}: physical .bin hashed roster differs")
  w149_assert(actual_mark_bases == expected_bases, "#{label}: physical .mrk2 hashed roster differs")
  result = Hash(String, CrystalClick::BinaryBulkStreams).new
  fixture.types.keys.sort.each do |column|
    lane_root = File.join(root, "evidence", fixture.cell_id, label.gsub('/', "-"), column)
    FileUtils.mkdir_p(lane_root)
    result[column] = w149_capture_streams(part, fixture, column, "#{label}-#{column}", lane_root, lane_manifest)
  end
  # The key is not part of the bulk Variant exchange, but its stock filename
  # and mark files belong to the expected complete native stream roster.
  key_plan.stream_names.each do |role, logical|
    data_path, mark_path = w149_stream_paths(part, logical)
    raw_data = w149_read_bytes(data_path, "#{label} key data")
    raw_marks = w149_read_bytes(mark_path, "#{label} key marks")
    records = w149_parse_marks(raw_marks, "#{label} key")
    prefix = key_plan.prefix_size_for(role)
    grid = CrystalClick::CompressedMarkReader.inspect(data_path, mark_path, raw_data.size.to_i64,
      raw_marks.size.to_i64, prefix, w149_limits)
    w149_assert(grid.rows_per_mark == W149_ROWS_PER_MARK && grid.mark_count == 3,
      "#{label}: key lane mark schedule differs")
    decompressed = raw_data.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(raw_data, max_output_size: W149_MAX_FILE_BYTES)
    w149_assert(grid.logical_size == decompressed.size.to_i64,
      "#{label}: key lane frame-walked EOF differs from decompressed bytes")
    positions = grid.positions.map(&.to_u64)
    w149_assert(positions.size == 4 && positions.last == decompressed.size.to_u64,
      "#{label}: key lane K+1 grid differs from decompressed EOF")
    key_evidence_root = File.join(root, "evidence", fixture.cell_id, label.gsub('/', "-"), "k")
    FileUtils.mkdir_p(key_evidence_root)
    stem = "#{label.gsub('/', "-")}-#{CrystalClick::StreamName.hash(logical)}"
    w149_write_new(File.join(key_evidence_root, "#{stem}.compressed.bin"), raw_data)
    w149_write_new(File.join(key_evidence_root, "#{stem}.mrk2"), raw_marks)
    w149_write_new(File.join(key_evidence_root, "#{stem}.decompressed.bin"), decompressed)
    lane_manifest << "#{label}\tk\t#{role}\t#{logical}\t#{File.basename(data_path)}\t0\tnone\t"
    lane_manifest << "#{raw_data.size}\t#{decompressed.size}\t#{decompressed.size}\t"
    lane_manifest << "#{positions.join(",")}\t#{positions.join(",")}\t"
    lane_manifest << "#{grid.rows_per_mark.join(",")}\t#{records.map { |record| "#{record[0]}:#{record[1]}:#{record[2]}" }.join(",")}\t"
    lane_manifest << "#{w149_sha256(raw_data)}\t#{w149_sha256(decompressed)}\n"
  end
  result
end

def w149_values_equal(left : CrystalClick::BinaryValue,
                      right : CrystalClick::BinaryValue, label : String) : Nil
  w149_assert(left.type == right.type, "#{label}: nominal type differs")
  w149_assert(left.is_null? == right.is_null?, "#{label}: NULL identity differs")
  return if left.is_null?
  type = left.type
  case type.tag
  when CrystalClick::BinaryDataType::TAG_VARIANT
    left_index = left.variant_index?
    right_index = right.variant_index?
    w149_assert(left_index == right_index, "#{label}: Variant discriminator differs")
    left_child = left.variant_child?
    right_child = right.variant_child?
    w149_assert(left_child.nil? == right_child.nil?, "#{label}: Variant child presence differs")
    if left_child && right_child
      w149_values_equal(left_child, right_child, "#{label} child")
    end
  when CrystalClick::BinaryDataType::TAG_ARRAY,
       CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_NAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_MAP
    left_values = left.elements
    right_values = right.elements
    w149_assert(left_values.size == right_values.size, "#{label}: composite arity differs")
    left_values.each_with_index { |child, index| w149_values_equal(child, right_values[index], "#{label}[#{index}]") }
  when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY,
       CrystalClick::BinaryDataType::TAG_NULLABLE
    w149_values_equal(left.child_at(0), right.child_at(0), "#{label} wrapped value")
  else
    w149_assert(left.bytes == right.bytes, "#{label}: typed scalar payload differs")
  end
end

def w149_compare_stock_to_literals(fixture : W149Fixture,
                                   actual : Hash(String, CrystalClick::BinaryBulkStreams),
                                   label : String) : Nil
  fixture.types.each do |column, type|
    decoded = CrystalClick::BinaryBulkCodec.decode(type, actual[column], W149_ROWS_PER_MARK, profile: fixture.profile)
    expected = fixture.values[column]
    w149_assert(decoded.size == expected.size, "#{label} #{column}: decoded mark count differs")
    decoded.each_with_index do |mark, mark_index|
      w149_assert(mark.size == expected[mark_index].size, "#{label} #{column}: decoded row count differs")
      mark.each_with_index do |value, row_index|
        w149_values_equal(value, expected[mark_index][row_index], "#{label} #{column} row #{mark_index * 2 + row_index + 1}")
      end
    end
  end
  nil
end

def w149_compare_codec_to_stock(fixture : W149Fixture,
                                stock : Hash(String, CrystalClick::BinaryBulkStreams),
                                label : String, comparisons : IO) : Hash(String, CrystalClick::BinaryBulkStreams)
  emitted = Hash(String, CrystalClick::BinaryBulkStreams).new
  fixture.types.each do |column, type|
    actual = stock[column]
    logical = CrystalClick::BinaryBulkCodec.encode(type, fixture.values[column], profile: fixture.profile)
    w149_assert(actual.mark_count == logical.mark_count && actual.roles == logical.roles,
      "#{label} #{column}: normalized role/mark roster differs from BinaryBulkCodec")
    actual.roles.each do |role|
      stock_lane = actual.stream(role)
      codec_lane = logical.stream(role)
      exact = stock_lane.bytes == codec_lane.bytes && stock_lane.offsets == codec_lane.offsets
      if w149_role_is_lc_lane?(role)
        comparisons << "#{label}\t#{column}\t#{role}\t#{exact ? "exact" : "validated-by-native-values; LC dictionary/index byte order may differ"}\n"
      else
        comparisons << "#{label}\t#{column}\t#{role}\t#{exact ? "exact ordinary lane/grid" : "MISMATCH"}\n"
        w149_assert(exact, "#{label} #{column} #{role}: ordinary lane bytes or K+1 grid differ")
      end
    end
    emitted[column] = logical
  end
  emitted
end

def w149_prepend_prefix(role : String, prefix : Int32,
                        logical : CrystalClick::BinaryBulkStream, label : String) : Tuple(Bytes, Array(UInt64))
  if w149_role_is_variant_discriminator?(role)
    w149_assert(prefix == 8, "#{label}: expected plan-owned BASIC Variant prefix size 8")
    offsets = logical.offsets.map { |offset| offset + prefix.to_u64 }
    {w149_concat([w149_u64(0_u64), logical.bytes]), offsets}
  elsif role.ends_with?(".dictionary")
    w149_assert(prefix == 8, "#{label}: expected plan-owned LC dictionary prefix size 8")
    w149_assert(logical.bytes.size >= 8 && w149_u64_at(logical.bytes, 0, label) == 1_u64,
      "#{label}: codec LC dictionary lane lacks its own version prefix")
    {logical.bytes, logical.offsets}
  else
    w149_assert(prefix == 0, "#{label}: unexpected prefix size for ordinary lane")
    {logical.bytes, logical.offsets}
  end
end

def w149_replace_lanes(part : String, fixture : W149Fixture,
                       columns : Array(String),
                       emitted : Hash(String, CrystalClick::BinaryBulkStreams)) : Array(String)
  replaced = [] of String
  fixture.types.each do |column, type|
    next unless columns.includes?(column)
    plan = w149_plan(type, column, fixture.profile)
    plan.stream_names.keys.sort.each do |role|
      logical_name = plan.stream_name_for(role)
      stream = emitted[column].stream(role)
      prefix = plan.prefix_size_for(role)
      physical_bytes, physical_offsets = w149_prepend_prefix(role, prefix, stream, "#{fixture.cell_id} #{column} #{role}")
      files = CrystalClick::CompressedMarkWriter.encode(physical_bytes, physical_offsets,
        W149_ROWS_PER_MARK, prefix_size: prefix, frame_bytes: 4096)
      data_path, marks_path = w149_stream_paths(part, logical_name)
      w149_assert(File.file?(data_path) && !File.symlink?(data_path), "missing stock lane replacement target #{data_path}")
      w149_assert(File.file?(marks_path) && !File.symlink?(marks_path), "missing stock mark replacement target #{marks_path}")
      w149_assert(files.data.size.to_i64 <= W149_MAX_FILE_BYTES && files.marks.size.to_i64 <= W149_MAX_FILE_BYTES,
        "#{fixture.cell_id} #{role}: replacement output exceeds 8 MiB")
      File.open(data_path, "wb") { |file| file.write(files.data) }
      File.open(marks_path, "wb") { |file| file.write(files.marks) }
      replaced << File.basename(data_path) << File.basename(marks_path)
    end
  end
  replaced
end

module CrystalClick
  module WidePartWriter
    # W149-local checksum bridge patterned after the W145 oracle. This only
    # repairs the copied stock envelope after lane replacement.
    def self.w149_rebuild_checksums(stage : String) : Nil
      original = PartChecksums.open(stage)
      records = [] of ChecksumRecord
      original.entries.keys.sort.each do |name|
        path = File.join(stage, name)
        raise "W149 checksum input is missing or symlinked: #{path}" if File.symlink?(path) || !File.file?(path)
        physical_size = File.size(path)
        raise "W149 checksum input exceeds 8 MiB: #{path}" if physical_size > W149_MAX_FILE_BYTES
        physical = File.read(path).to_slice
        entry = original.entry(name) || raise "W149 checksum entry disappeared: #{name}"
        if entry.compressed
          # A wholly unused Variant arm is represented by a legitimate zero-byte
          # .bin lane plus its nonempty mark grid. Mirror the bounded capture path
          # for that exact empty representation; nonempty data still must decode
          # as a valid compressed stream.
          raw = if physical.empty?
                  unless name.ends_with?(".bin") && entry.uncompressed_size == 0_u64
                    raise "W149 empty compressed input is not a declared empty data lane: #{name}"
                  end
                  Bytes.empty
                else
                  CompressedBlock.decode_all(physical, max_output_size: W149_MAX_FILE_BYTES)
                end
          records << ChecksumRecord.new(name, physical.size.to_u64, CityHashV1.file_hash(physical), true,
            raw.size.to_u64, CityHashV1.file_hash(raw))
        else
          records << ChecksumRecord.new(name, physical.size.to_u64, CityHashV1.file_hash(physical), false)
        end
      end
      PartChecksumsWriter.write(stage, records)
      nil
    end
  end
end

def w149_rebuild_checksums(part : String) : Nil
  CrystalClick::WidePartWriter.w149_rebuild_checksums(part)
  checksums = CrystalClick::PartChecksums.open(part)
  checksums.entries.each_key do |name|
    checksums.validate_selected_entries(part, name)
  end
  nil
end

def w149_rowbinary_varuint(value : UInt64, io : IO) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64).to_u8 | 0x80_u8))
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w149_rowbinary_value(value : CrystalClick::BinaryValue, io : IO) : Nil
  type = value.type
  if type.tag == CrystalClick::BinaryDataType::TAG_VARIANT
    if value.is_null?
      w149_assert(value.variant_index?.nil? && value.variant_child?.nil?, "RowBinary Variant NULL must have neither tag nor child")
      io.write_byte(0xff_u8)
    else
      index = value.variant_index? || w149_fail("non-NULL RowBinary Variant lacks index")
      child = value.variant_child? || w149_fail("non-NULL RowBinary Variant lacks child")
      io.write_byte(index)
      w149_rowbinary_value(child, io)
    end
    return
  end
  case type.tag
  when CrystalClick::BinaryDataType::TAG_ARRAY
    elements = value.elements
    w149_rowbinary_varuint(elements.size.to_u64, io)
    elements.each { |child| w149_rowbinary_value(child, io) }
  when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
    w149_rowbinary_value(value.child_at(0), io)
  when CrystalClick::BinaryDataType::TAG_STRING
    bytes = value.bytes
    w149_rowbinary_varuint(bytes.size.to_u64, io)
    io.write(bytes)
  when CrystalClick::BinaryDataType::TAG_UINT64, CrystalClick::BinaryDataType::TAG_UINT8
    io.write(value.bytes)
  else
    w149_fail("W149 literal RowBinary encoder does not admit #{type.name}")
  end
end

def w149_expected_rowbinary(fixture : W149Fixture, first_row : Int = 0,
                            row_count : Int = 6) : Bytes
  io = IO::Memory.new
  fixture.row_count.times do |index|
    next if index < first_row || index >= first_row + row_count
    fixture.columns.each do |column|
      w149_rowbinary_value(fixture.rows_for(column)[index], io)
    end
  end
  io.to_slice.dup
end

def w149_rowbinary_query(table : String, fixture : W149Fixture,
                         middle : Bool = false) : String
  where = middle ? " WHERE k IN (2,3)" : ""
  "SELECT #{fixture.columns.join(", ")} FROM default.#{table}#{where} ORDER BY k FORMAT RowBinary"
end

def w149_check_rowbinary(binary : String, store : String, case_root : String,
                         table : String, fixture : W149Fixture, label : String) : Tuple(Bytes, Bytes)
  full = w149_expect_success(binary, store, case_root, "rowbinary-full-#{label}",
    w149_rowbinary_query(table, fixture))
  middle = w149_expect_success(binary, store, case_root, "rowbinary-middle-#{label}",
    w149_rowbinary_query(table, fixture, true))
  expected_full = w149_expected_rowbinary(fixture)
  expected_middle = w149_expected_rowbinary(fixture, 1, 2)
  full_bytes = full.stdout.to_slice.dup
  middle_bytes = middle.stdout.to_slice.dup
  w149_assert(full_bytes == expected_full, "#{label}: full RowBinary differs from literal typed values")
  w149_assert(middle_bytes == expected_middle, "#{label}: middle-window RowBinary differs from literal typed values")
  w149_write_new(File.join(case_root, "rowbinary-full.expected.bin"), expected_full)
  w149_write_new(File.join(case_root, "rowbinary-middle.expected.bin"), expected_middle)
  {full_bytes, middle_bytes}
end

def w149_create_and_insert(binary : String, store : String, case_root : String,
                           table : String, fixture : W149Fixture, label : String) : Nil
  w149_expect_success(binary, store, case_root, "create-#{label}", w149_create_query(table, fixture))
  w149_expect_success(binary, store, case_root, "insert-#{label}", w149_rows_sql(table, fixture))
  nil
end

def w149_copy_part(source : String, destination : String) : Nil
  w149_assert(File.directory?(source) && !File.symlink?(source), "W149 source envelope missing or symlinked")
  w149_assert(!File.exists?(destination) && !File.symlink?(destination), "refusing to overwrite W149 copied part")
  FileUtils.mkdir_p(File.dirname(destination))
  FileUtils.cp_r(source, destination)
end

def w149_unused_arm_controls(fixture : W149Fixture,
                             stock : Hash(String, CrystalClick::BinaryBulkStreams),
                             comparisons : IO) : Nil
  case fixture.shape
  when "root"
    type = fixture.types["v_unused_ordinary"]
    plan = w149_plan(type, "v_unused_ordinary", fixture.profile)
    role = plan.stream_names.keys.find { |candidate| candidate.ends_with?(".arm.1.data") } ||
           w149_fail("root fixture lacks canonical UInt64 arm 1 data role")
    lane = stock["v_unused_ordinary"].stream(role)
    w149_assert(lane.bytes.empty?, "root unused ordinary UInt64 arm unexpectedly contains bytes")
    w149_assert(lane.offsets == [0_u64, 0_u64, 0_u64, 0_u64],
      "root unused ordinary UInt64 arm does not preserve empty K+1 marks")
    comparisons << "#{fixture.cell_id}\tv_unused_ordinary\t#{role}\twholly-unused ordinary arm has zero bytes and repeated K+1 offsets\n"
  when "array_lc"
    type = fixture.types["v_unused_lc"]
    plan = w149_plan(type, "v_unused_lc", fixture.profile)
    dictionary_role = plan.stream_names.keys.find { |candidate| candidate.ends_with?(".arm.0.dictionary") } ||
                      w149_fail("array-LC fixture lacks canonical LC arm 0 dictionary role")
    indexes_role = plan.stream_names.keys.find { |candidate| candidate.ends_with?(".arm.0.indexes") } ||
                   w149_fail("array-LC fixture lacks canonical LC arm 0 index role")
    dictionary = stock["v_unused_lc"].stream(dictionary_role)
    indexes = stock["v_unused_lc"].stream(indexes_role)
    w149_assert(dictionary.bytes.size == 8 && w149_u64_at(dictionary.bytes, 0, dictionary_role) == 1_u64,
      "wholly unused LC arm must retain only its u64(1) dictionary version prefix")
    w149_assert(dictionary.offsets == [8_u64, 8_u64, 8_u64, 8_u64],
      "wholly unused LC dictionary marks do not repeat after its version prefix")
    w149_assert(indexes.bytes.empty? && indexes.offsets == [0_u64, 0_u64, 0_u64, 0_u64],
      "wholly unused LC index lane must be empty with repeated K+1 offsets")
    comparisons << "#{fixture.cell_id}\tv_unused_lc\t#{dictionary_role}\tunused LC arm retains only version prefix\n"
    comparisons << "#{fixture.cell_id}\tv_unused_lc\t#{indexes_role}\tunused LC index lane empty with repeated K+1 offsets\n"
  when "array_nested"
    type = fixture.types["v"]
    plan = w149_plan(type, "v", fixture.profile)
    names = plan.stream_names
    outer = names["root.sizes"]? || w149_fail("outer Array binding is missing its size stream")
    nested = names["root.elements.arm.0.sizes"]? || w149_fail("Variant Array arm binding is missing its size stream")
    w149_assert(outer.ends_with?(".size0"), "outer Array binding does not retain array level 0")
    w149_assert(nested.ends_with?(".size1"), "Variant Array arm binding does not inherit array level 1")
    comparisons << "#{fixture.cell_id}\troot.sizes\t#{outer}\touter array_size level 0\n"
    comparisons << "#{fixture.cell_id}\troot.elements.arm.0.sizes\t#{nested}\tarm array_size inherited level 1\n"
  end
  nil
end

def w149_verify_runtime(binary : String, root : String,
                        stock_store : String, case_root : String) : Nil
  w149_assert(File.file?(binary) && !File.symlink?(binary), "pinned ClickHouse runtime missing or symlinked")
  sha = w149_sha256_file(binary)
  w149_assert(sha == W149_RUNTIME_SHA256, "pinned ClickHouse runtime SHA256 differs: #{sha}")
  version_out = IO::Memory.new
  version_err = IO::Memory.new
  version_status = Process.run(binary, ["local", "--version"], output: version_out, error: version_err)
  w149_assert(version_status.success? && version_out.to_s.strip == W149_RUNTIME_VERSION,
    "ClickHouse version pin differs: #{version_out}")
  w149_write_new_text(File.join(root, "results", "runtime-identity.txt"),
    "version=#{version_out.to_s.strip}\nsha256=#{sha}\nsource_revision=#{W149_SOURCE_REVISION}\nsource_is_not_claimed_as_runtime_build=true\n")
  options = w149_expect_success(binary, stock_store, case_root, "runtime-build-options",
    "SELECT name, value FROM system.build_options WHERE name IN ('GIT_HASH','VERSION_GITHASH') ORDER BY name FORMAT TSVRaw")
  expected = "GIT_HASH\t#{W149_BUILD_HASH}\nVERSION_GITHASH\t#{W149_BUILD_HASH}\n"
  w149_assert(options.stdout == expected, "ClickHouse build hash pin differs: #{options.stdout.inspect}")
  w149_write_new_text(File.join(root, "results", "runtime-build-options.tsv"), options.stdout)
  nil
end

def w149_verify_source(root : String) : Nil
  source = ENV.fetch("CLICKHOUSE_SOURCE_ROOT")
  w149_assert(Dir.exists?(source) && !File.symlink?(source), "pinned ClickHouse source root missing or symlinked")
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run("git", ["-C", source, "rev-parse", "HEAD"], output: output, error: error)
  w149_assert(status.success? && output.to_s.strip == W149_SOURCE_REVISION,
    "ClickHouse source revision differs: #{error}")
  w149_write_new_text(File.join(root, "results", "source-identity.txt"),
    "source_root=#{source}\nrevision=#{output.to_s.strip}\nruntime_build_from_this_source=not_asserted\n")
  nil
end

def w149_validate_output_root(root : String) : Nil
  w149_assert(root.starts_with?(W149_ROOT_PREFIX), "W149 output root is outside fresh direct /private/tmp namespace")
  w149_assert(Dir.exists?(root) && !File.symlink?(root), "W149 output root must be a real directory")
  w149_assert(File.expand_path(root) == root, "W149 output root must be canonical")
  ["cases", "controls", "crystal-cache", "evidence", "parts", "results", "stores"].each do |name|
    path = File.join(root, name)
    w149_assert(Dir.exists?(path) && !File.symlink?(path), "W149 root child missing or symlinked: #{name}")
  end
  nil
end

def w149_run_all : Nil
  root = ENV.fetch("W149_CHECK_ROOT")
  binary = ENV.fetch("CLICKHOUSE_BIN")
  source_revision = ENV.fetch("CLICKHOUSE_SOURCE_REVISION")
  w149_assert(source_revision == W149_SOURCE_REVISION, "W149 source pin differs from shell preflight")
  w149_validate_output_root(root)
  w149_verify_source(root)

  cells = IO::Memory.new
  lane_manifest = IO::Memory.new
  comparisons = IO::Memory.new
  summary = IO::Memory.new
  lane_manifest << "cell_column\tcolumn\trole\tlogical_stream\tdata_file\tprefix_size\tnormalization\tcompressed_bytes\tdecompressed_bytes\tlogical_bytes\traw_Kplus1_positions\tnormalized_Kplus1_positions\trows_per_real_mark\traw_mrk2_compressed_decompressed_rows\tcompressed_sha256\tdecompressed_sha256\n"

  profiles = ["single_stream", "with_size_stream"]
  profiles.each do |profile_name|
    ["root", "array_lc", "array_nested"].each do |shape|
      fixture = w149_literal_fixture(shape, profile_name)
      stock_store = File.join(root, "stores", "stock_#{fixture.cell_id}")
      stock_case = w149_case_root(root, fixture.cell_id, "stock")
      w149_assert(!File.exists?(stock_store) && !File.symlink?(stock_store), "refusing to reuse W149 stock store")
      Dir.mkdir(stock_store)
      if shape == "root" && profile_name == "single_stream"
        w149_verify_runtime(binary, root, stock_store, stock_case)
      end
      # This fresh stock store is also the isolated runtime-identity query
      # surface for the first cell; the profile routine then creates its table.
      w149_profile_cell_with_store(binary, root, fixture, stock_store,
        lane_manifest, comparisons, summary)
      cells << "#{fixture.cell_id}\tstock_#{fixture.cell_id}\tw149_#{fixture.cell_id}\tlibrary_#{fixture.cell_id}\tw149_lib_#{fixture.cell_id}\n"
    end
  end

  w149_mutant_control(binary, root, lane_manifest, comparisons, summary)

  w149_write_new_text(File.join(root, "results", "cells.tsv"), cells.to_s)
  w149_write_new_text(File.join(root, "results", "lane-grid.tsv"), lane_manifest.to_s)
  w149_write_new_text(File.join(root, "results", "lane-comparisons.tsv"), comparisons.to_s)
  w149_write_new_text(File.join(root, "results", "summary.tsv"), summary.to_s)
  w149_write_new_text(File.join(root, "results", "summary.txt"),
    "PASS six finite stock Wide Variant fixtures across two String profiles plus valid wrong-value control\n" +
    "source=#{W149_SOURCE_REVISION}\nruntime_sha256=#{W149_RUNTIME_SHA256}\nruntime_build=#{W149_BUILD_HASH}\n" +
    "scope=stock Variant stream binding and library lanes consumed in borrowed stock envelopes; not complete-part writer\n" +
    "marks=3 real marks with rows 2,2,2; raw .mrk2 and system.parts include separate terminal record\n")
  puts "PASS W149 finite native Variant physical binding witnesses; root may now run independent Ruby literal recheck"
  nil
end

def w149_profile_cell_with_store(binary : String, root : String, fixture : W149Fixture,
                                 stock_store : String, lane_manifest : IO,
                                 comparisons : IO, summary : IO) : Nil
  stock_label = "stock/#{fixture.cell_id}"
  stock_root = w149_case_root(root, fixture.cell_id, "stock")
  stock_table = "w149_#{fixture.cell_id}"
  w149_create_and_insert(binary, stock_store, stock_root, stock_table, fixture, "stock-#{fixture.cell_id}")
  w149_verify_table(binary, stock_store, stock_root, stock_table, fixture, "stock-#{fixture.cell_id}")
  stock_part = w149_find_part(stock_store, "#{stock_label} native Wide part")
  stock_lanes = w149_capture_part(stock_part, fixture, stock_label, root, lane_manifest)
  w149_compare_stock_to_literals(fixture, stock_lanes, stock_label)
  emitted = w149_compare_codec_to_stock(fixture, stock_lanes, stock_label, comparisons)
  stock_full, stock_middle = w149_check_rowbinary(binary, stock_store, stock_root,
    stock_table, fixture, "stock-#{fixture.cell_id}")
  w149_unused_arm_controls(fixture, stock_lanes, comparisons)

  library_label = "library/#{fixture.cell_id}"
  library_root = w149_case_root(root, fixture.cell_id, "library")
  library_store = w149_new_store(root, "library_#{fixture.cell_id}")
  library_table = "w149_lib_#{fixture.cell_id}"
  w149_expect_success(binary, library_store, library_root, "create-library-#{fixture.cell_id}",
    w149_create_query(library_table, fixture))
  library_part = File.join(root, "parts", fixture.cell_id, "library", "all_1_1_0")
  w149_copy_part(stock_part, library_part)
  replaced = w149_replace_lanes(library_part, fixture, fixture.columns, emitted)
  w149_rebuild_checksums(library_part)
  library_lanes = w149_capture_part(library_part, fixture, library_label, root, lane_manifest)
  w149_compare_stock_to_literals(fixture, library_lanes, library_label)
  w149_attach(binary, library_store, library_root, library_table, library_part, "library-#{fixture.cell_id}")
  w149_verify_table(binary, library_store, library_root, library_table, fixture, "library-#{fixture.cell_id}")
  library_full, library_middle = w149_check_rowbinary(binary, library_store, library_root,
    library_table, fixture, "library-#{fixture.cell_id}")
  w149_assert(library_full == stock_full && library_middle == stock_middle,
    "#{fixture.cell_id}: stock and library RowBinary outputs differ")

  summary << "#{fixture.cell_id}\t#{stock_store}\tdefault.#{stock_table}\t#{library_store}\tdefault.#{library_table}\t"
  summary << "rows=6\treal_marks=3\tterminal_mark_in_system.parts=1\tprofile=#{fixture.profile_name}\t"
  summary << "replaced_lanes=#{replaced.size // 2}\tPASS\n"
  nil
end

def w149_mutant_control(binary : String, root : String,
                        lane_manifest : IO, comparisons : IO, summary : IO) : Nil
  original_fixture = w149_literal_fixture("root", "single_stream")
  mutant_fixture = w149_literal_fixture("root", "single_stream", mutant: true)
  stock_store = File.join(root, "stores", "stock_root_single_stream")
  stock_part = w149_find_part(stock_store, "valid wrong-value stock source")
  control_root = w149_case_root(root, "root_single_stream", "mutant")
  mutant_store = w149_new_store(root, "mutant_root_single_stream")
  mutant_table = "w149_mutant_root_single_stream"
  w149_expect_success(binary, mutant_store, control_root, "create-mutant-root-single-stream",
    w149_create_query(mutant_table, mutant_fixture))
  mutant_part = File.join(root, "controls", "mutant_root_single_stream", "all_1_1_0")
  w149_copy_part(stock_part, mutant_part)
  emitted = Hash(String, CrystalClick::BinaryBulkStreams).new
  emitted["v"] = CrystalClick::BinaryBulkCodec.encode(mutant_fixture.types["v"],
    mutant_fixture.values["v"], profile: mutant_fixture.profile)
  replaced = w149_replace_lanes(mutant_part, mutant_fixture, ["v"], emitted)
  w149_assert(replaced.size == 6, "valid wrong-value root Variant should replace its three physical roles and mark files")
  w149_rebuild_checksums(mutant_part)
  mutant_lanes = w149_capture_part(mutant_part, mutant_fixture, "mutant/root_single_stream", root, lane_manifest)
  w149_compare_stock_to_literals(mutant_fixture, mutant_lanes, "mutant/root_single_stream")
  w149_attach(binary, mutant_store, control_root, mutant_table, mutant_part, "mutant-root-single-stream")
  w149_verify_table(binary, mutant_store, control_root, mutant_table, mutant_fixture, "mutant-root-single-stream")
  actual_full, actual_middle = w149_check_rowbinary(binary, mutant_store, control_root,
    mutant_table, mutant_fixture, "mutant-root-single-stream")
  original_full = w149_expected_rowbinary(original_fixture)
  original_middle = w149_expected_rowbinary(original_fixture, 1, 2)
  w149_assert(actual_full != original_full && actual_middle != original_middle,
    "valid 42-to-43 mutant was not rejected by original full/middle literal comparators")
  w149_write_new_text(File.join(control_root, "valid-wrong-value.txt"),
    "ATTACH/CHECK passed; literal full and middle RowBinary comparators reject v[k=2] UInt64 42->43.\n")
  comparisons << "mutant-root-single-stream\tv\troot arm 1\tvalid native-consumed UInt64 42->43 rejected by full+middle literals\n"
  summary << "mutant_root_single_stream\t#{mutant_store}\tdefault.#{mutant_table}\t42->43\tATTACH/CHECK+literal-rejection\tPASS\n"
  nil
end

w149_run_all
