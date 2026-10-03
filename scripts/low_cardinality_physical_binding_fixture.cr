# W145 ordinary-Wide LowCardinality physical binding oracle.
#
# Eight stock INSERT parts (four recursive types x two ordinary String
# profiles) are read independently, decoded by the frame-aware mark reader,
# and compared with the authored literal values. Stock lane bytes/grids are
# recorded separately from encoder output because dictionary choices may
# differ while remaining semantically equivalent. The codec output is then
# written into copies of the stock envelopes, checksums are rebuilt, and
# ClickHouse ATTACH/CHECK plus ordered RowBinary reads consume those copies.
# These are borrowed-envelope exchanges, not an independently owned part
# writer. Compact/dict_prefix and Map WITH_BUCKETS are deliberately excluded.
require "file_utils"
require "digest/sha256"
require "json"
require "set"
require "../src/crystal_click"

W145_SOURCE_REVISION = "9007d227b64a3f8b667fc5258ceb2923f3cf477d"
W145_RUNTIME_SHA256  = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W145_RUNTIME_VERSION = "ClickHouse local version 26.10.1.1201 (official build)."
W145_BUILD_HASH      = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W145_ROWS_PER_MARK   = [4_u64, 4_u64, 4_u64]
W145_ROWS            = 12
W145_MAX_FILE_BYTES  = 64_i64 * 1024 * 1024

class W145Mismatch < Exception
end

struct W145CommandResult
  getter stdout : String
  getter stderr : String
  getter exit_code : Int32

  def initialize(@stdout : String, @stderr : String, @exit_code : Int32)
  end

  def success? : Bool
    @exit_code == 0
  end
end

struct W145Case
  getter kind : String
  getter profile_name : String
  getter profile : CrystalClick::BinaryBulkProfile
  getter declarations : String
  getter type_names : Hash(String, String)
  getter types : Hash(String, CrystalClick::BinaryDataType)
  getter values : Hash(String, Array(Array(CrystalClick::BinaryValue)))
  getter insert_x : Array(String)
  getter insert_n : Array(String)
  getter select_columns : Array(String)
  getter formula : String

  def initialize(@kind : String, @profile_name : String,
                 @profile : CrystalClick::BinaryBulkProfile,
                 @declarations : String,
                 @type_names : Hash(String, String),
                 @types : Hash(String, CrystalClick::BinaryDataType),
                 @values : Hash(String, Array(Array(CrystalClick::BinaryValue))),
                 @insert_x : Array(String), @insert_n : Array(String),
                 @select_columns : Array(String), @formula : String)
  end
end

module CrystalClick
  module WidePartWriter
    # Script-local checksum bridge. Rebuilds every record after replacement;
    # the reader's selected-entry API intentionally proves sizes only.
    def self.w145_rebuild_checksums(stage : String, raw_overrides : Hash(String, Bytes) = Hash(String, Bytes).new) : Nil
      original = PartChecksums.open(stage)
      records = [] of ChecksumRecord
      original.entries.keys.sort.each do |name|
        path = File.join(stage, name)
        raise "W145 checksum input is missing or symlinked: #{path}" if File.symlink?(path) || !File.file?(path)
        physical_text = File.read(path)
        physical = physical_text.to_slice
        entry = original.entry(name) || raise "W145 checksum entry disappeared: #{name}"
        if entry.compressed
          raw = raw_overrides[name]? || CompressedBlock.decode_all(physical, max_output_size: W145_MAX_FILE_BYTES)
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

def w145_fail(message : String) : NoReturn
  raise W145Mismatch.new(message)
end

def w145_assert(condition : Bool, message : String) : Nil
  w145_fail(message) unless condition
end

def w145_write_new(path : String, bytes : Bytes) : Nil
  w145_assert(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite W145 artifact: #{path}")
  File.open(path, "wb") { |file| file.write(bytes) }
end

def w145_write_new_text(path : String, text : String) : Nil
  w145_assert(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite W145 artifact: #{path}")
  File.open(path, "w") { |file| file << text }
end

def w145_replace_file(path : String, bytes : Bytes) : Nil
  w145_assert(File.file?(path) && !File.symlink?(path), "W145 replacement target is missing or symlinked: #{path}")
  File.open(path, "wb") { |file| file.write(bytes) }
end

def w145_read_bytes(path : String, label : String) : Bytes
  w145_assert(File.file?(path) && !File.symlink?(path), "#{label}: missing file or symlink")
  size = File.size(path)
  w145_assert(size >= 0 && size <= W145_MAX_FILE_BYTES, "#{label}: file exceeds bounded witness size")
  File.read(path).to_slice.dup
end

def w145_sha256_file(path : String) : String
  digest = Digest::SHA256.new
  File.open(path, "rb") do |file|
    buffer = Bytes.new(1024 * 1024)
    loop do
      size = file.read(buffer)
      break if size == 0
      digest.update(buffer[0, size])
    end
  end
  digest.final.hexstring
end

def w145_profile(name : String) : CrystalClick::BinaryBulkProfile
  case name
  when "single_stream"    then CrystalClick::BinaryBulkProfile.single_stream
  when "with_size_stream" then CrystalClick::BinaryBulkProfile.with_size_stream
  else                         w145_fail("unknown W145 String profile #{name.inspect}")
  end
end

def w145_chunks(values : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
  w145_assert(values.size == W145_ROWS, "W145 literal column must contain exactly twelve rows")
  Array(Array(CrystalClick::BinaryValue)).new(3) do |mark|
    values[mark * 4, 4]
  end
end

def w145_lc_string(type : CrystalClick::BinaryDataType, nested : CrystalClick::BinaryDataType,
                   value : String?) : CrystalClick::BinaryValue
  nullable = if text = value
               CrystalClick::BinaryValue.nullable(nested, CrystalClick::BinaryValue.string(text))
             else
               CrystalClick::BinaryValue.nullable(nested)
             end
  CrystalClick::BinaryValue.low_cardinality(type, nullable)
end

def w145_lc_uint64(type : CrystalClick::BinaryDataType, nested : CrystalClick::BinaryDataType,
                   value : UInt64?) : CrystalClick::BinaryValue
  nullable = if number = value
               CrystalClick::BinaryValue.nullable(nested, CrystalClick::BinaryValue.uint64(number))
             else
               CrystalClick::BinaryValue.nullable(nested)
             end
  CrystalClick::BinaryValue.low_cardinality(type, nullable)
end

def w145_array_row(type : CrystalClick::BinaryDataType, low : CrystalClick::BinaryDataType,
                   items : Array(String)) : CrystalClick::BinaryValue
  values = items.map do |item|
    CrystalClick::BinaryValue.low_cardinality(low, CrystalClick::BinaryValue.string(item))
  end
  CrystalClick::BinaryValue.array(type, values)
end

def w145_tuple_row(type : CrystalClick::BinaryDataType, low : CrystalClick::BinaryDataType,
                   nullable : CrystalClick::BinaryDataType, number : UInt64?, text : String) : CrystalClick::BinaryValue
  first = w145_lc_uint64(low, nullable, number)
  CrystalClick::BinaryValue.tuple(type, [first, CrystalClick::BinaryValue.string(text)] of CrystalClick::BinaryValue)
end

def w145_map_row(type : CrystalClick::BinaryDataType, low : CrystalClick::BinaryDataType,
                 pairs : Array(Tuple(String, String))) : CrystalClick::BinaryValue
  flat = [] of CrystalClick::BinaryValue
  pairs.each do |pair|
    flat << CrystalClick::BinaryValue.string(pair[0])
    flat << CrystalClick::BinaryValue.low_cardinality(low, CrystalClick::BinaryValue.string(pair[1]))
  end
  CrystalClick::BinaryValue.map(type, flat)
end

def w145_case(kind : String, profile_name : String) : W145Case
  profile = w145_profile(profile_name)
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  string = CrystalClick::BinaryDataType.primitive("String")
  types = {
    "k"     => uint64,
    "plain" => string,
  } of String => CrystalClick::BinaryDataType
  type_names = {
    "k"     => "UInt64",
    "plain" => "String",
  } of String => String
  values = Hash(String, Array(Array(CrystalClick::BinaryValue))).new
  values["k"] = w145_chunks(Array(CrystalClick::BinaryValue).new(W145_ROWS) do |index|
    CrystalClick::BinaryValue.uint64(index.to_u64)
  end)
  plain_values = Array(CrystalClick::BinaryValue).new(W145_ROWS) do |index|
    CrystalClick::BinaryValue.string("plain-#{index.to_s.rjust(2, '0')}")
  end
  values["plain"] = w145_chunks(plain_values)

  insert_x = [] of String
  insert_n = [] of String
  declarations = ""
  formula = "k=0..11; plain=plain-00..plain-11"
  select_columns = ["k", "x", "plain"] of String

  case kind
  when "root"
    nullable = CrystalClick::BinaryDataType.nullable(string)
    lc_string = CrystalClick::BinaryDataType.low_cardinality(nullable)
    lc_uint = CrystalClick::BinaryDataType.low_cardinality(uint64)
    types["x"] = lc_string
    types["n"] = lc_uint
    type_names["x"] = "LowCardinality(Nullable(String))"
    type_names["n"] = "LowCardinality(UInt64)"
    root_texts = [nil, "alpha", "beta", nil, "alpha", "gamma", "beta", nil, "", "gamma", "alpha", nil] of String?
    n_values = [10_u64, 20_u64, 10_u64, 30_u64, 10_u64, 20_u64, 40_u64, 10_u64, 30_u64, 20_u64, 40_u64, 10_u64]
    values["x"] = w145_chunks(root_texts.map { |item| w145_lc_string(lc_string, nullable, item) })
    values["n"] = w145_chunks(n_values.map { |item| CrystalClick::BinaryValue.low_cardinality(lc_uint, CrystalClick::BinaryValue.uint64(item)) })
    insert_x = root_texts.map { |item| item ? "'#{item}'" : "NULL" }
    insert_n = n_values.map(&.to_s)
    declarations = "x LowCardinality(Nullable(String)), n LowCardinality(UInt64), plain String"
    formula += "; x=[NULL,alpha,beta,NULL,alpha,gamma,beta,NULL,empty,gamma,alpha,NULL]; n=[10,20,10,30,10,20,40,10,30,20,40,10]"
    select_columns = ["k", "x", "n", "plain"] of String
  when "array"
    low = CrystalClick::BinaryDataType.low_cardinality(string)
    array = CrystalClick::BinaryDataType.array(low)
    types["x"] = array
    type_names["x"] = "Array(LowCardinality(String))"
    rows = [
      [] of String, ["red", "blue"], ["red"], [] of String,
      ["blue", ""], [] of String, ["green", "blue", "red"], ["green"],
      [] of String, ["red"], ["snow"], ["blue", "green"],
    ] of Array(String)
    values["x"] = w145_chunks(rows.map { |items| w145_array_row(array, low, items) })
    insert_x = rows.map do |items|
      if items.empty?
        "CAST([], 'Array(LowCardinality(String))')"
      else
        "[#{items.map { |item| "'#{item}'" }.join(",")}]"
      end
    end
    declarations = "x Array(LowCardinality(String)), plain String"
    formula += "; x=[[],[red,blue],[red],[],[blue,empty],[],[green,blue,red],[green],[],[red],[snow],[blue,green]]; flattened LC counts/mark=[3,6,4]"
  when "tuple"
    nullable = CrystalClick::BinaryDataType.nullable(uint64)
    low = CrystalClick::BinaryDataType.low_cardinality(nullable)
    tuple = CrystalClick::BinaryDataType.tuple([low, string] of CrystalClick::BinaryDataType, ["a.b", "s"] of String)
    types["x"] = tuple
    type_names["x"] = "Tuple(`a.b` LowCardinality(Nullable(UInt64)), s String)"
    tuple_numbers = [nil, 1_u64, 2_u64, nil, 3_u64, 1_u64, 2_u64, nil, 0_u64, 3_u64, 1_u64, nil] of UInt64?
    tuple_texts = Array(String).new(W145_ROWS) { |index| "t#{index.to_s.rjust(2, '0')}" }
    values["x"] = w145_chunks(Array(CrystalClick::BinaryValue).new(W145_ROWS) do |index|
      w145_tuple_row(tuple, low, nullable, tuple_numbers[index], tuple_texts[index])
    end)
    insert_x = Array(String).new(tuple_numbers.size) do |index|
      number = tuple_numbers[index]
      "tuple(#{number ? number.to_s : "NULL"},'#{tuple_texts[index]}')"
    end
    declarations = "x Tuple(`a.b` LowCardinality(Nullable(UInt64)), s String), plain String"
    formula += "; x=[(NULL,t00),(1,t01),(2,t02),(NULL,t03),(3,t04),(1,t05),(2,t06),(NULL,t07),(0,t08),(3,t09),(1,t10),(NULL,t11)]"
  when "map"
    low = CrystalClick::BinaryDataType.low_cardinality(string)
    map = CrystalClick::BinaryDataType.map(string, low)
    types["x"] = map
    type_names["x"] = "Map(String, LowCardinality(String))"
    rows = [
      [{"a", "red"}, {"b", "blue"}], [] of Tuple(String, String), [{"a", "red"}],
      [{"a", "green"}, {"b", "blue"}], [{"b", "blue"}], [{"a", ""}],
      [{"a", "red"}, {"b", "snow"}], [{"a", "snow"}], [{"a", "green"}],
      [{"b", "blue"}, {"c", "green"}], [] of Tuple(String, String), [{"a", "red"}, {"c", "snow"}],
    ] of Array(Tuple(String, String))
    values["x"] = w145_chunks(rows.map { |pairs| w145_map_row(map, low, pairs) })
    insert_x = rows.map do |pairs|
      if pairs.empty?
        "CAST(map(), 'Map(String, LowCardinality(String))')"
      else
        arguments = pairs.flat_map { |pair| ["'#{pair[0]}'", "'#{pair[1]}'"] }
        "map(#{arguments.join(",")})"
      end
    end
    declarations = "x Map(String, LowCardinality(String)), plain String"
    formula += "; x=[{a:red,b:blue},{},{a:red},{a:green,b:blue},{b:blue},{a:empty},{a:red,b:snow},{a:snow},{a:green},{b:blue,c:green},{},{a:red,c:snow}] in insertion order; BASIC Map"
  else
    w145_fail("unknown W145 case kind #{kind.inspect}")
  end

  types["plain"] = string
  W145Case.new(kind, profile_name, profile, declarations, type_names, types, values,
    insert_x, insert_n, select_columns, formula)
end

def w145_settings(profile_name : String) : String
  "index_granularity=4, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, " +
    "min_rows_for_wide_part=0, min_bytes_for_wide_part=0, min_level_for_wide_part=0, " +
    "default_compression_codec='LZ4', ratio_of_defaults_for_sparse_serialization=1.0, " +
    "compress_marks=0, write_final_mark=1, min_compress_block_size=0, max_compress_block_size=4096, " +
    "serialization_info_version='with_types', string_serialization_version='#{profile_name}', " +
    "nullable_serialization_version='basic', map_serialization_version='basic', " +
    "map_serialization_version_for_zero_level_parts='basic', " +
    "propagate_types_serialization_versions_to_nested_types=1"
end

def w145_create_query(table : String, fixture : W145Case) : String
  "CREATE TABLE default.#{table} (k UInt64, #{fixture.declarations}) ENGINE=MergeTree ORDER BY k SETTINGS #{w145_settings(fixture.profile_name)}"
end

def w145_insert_query(table : String, fixture : W145Case) : String
  rows = [] of String
  W145_ROWS.times do |index|
    fields = [index.to_s, fixture.insert_x[index]]
    fields << fixture.insert_n[index] if fixture.kind == "root"
    fields << "'plain-#{index.to_s.rjust(2, '0')}'"
    rows << "(#{fields.join(",")})"
  end
  "INSERT INTO default.#{table} VALUES\n#{rows.join(",\n")}"
end

def w145_run(binary : String, store : String, case_root : String, label : String, query : String) : W145CommandResult
  queries = File.join(case_root, "queries")
  FileUtils.mkdir_p(queries)
  stem = label.gsub(/[^A-Za-z0-9_-]/, "-")
  sql_path = File.join(queries, "#{stem}.sql")
  stdout_path = File.join(queries, "#{stem}.stdout.bin")
  stderr_path = File.join(queries, "#{stem}.stderr.txt")
  status_path = File.join(queries, "#{stem}.status.txt")
  w145_write_new_text(sql_path, query + "\n")
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--allow_suspicious_low_cardinality_types=1", "--query", query],
    output: stdout, error: stderr)
  w145_write_new(stdout_path, stdout.to_slice)
  w145_write_new_text(stderr_path, stderr.to_s)
  w145_write_new_text(status_path, "#{status.exit_code || -1}\n")
  W145CommandResult.new(stdout.to_s, stderr.to_s, status.exit_code || -1)
end

def w145_expect_query(binary : String, store : String, case_root : String, label : String,
                      query : String, expected : String) : String
  result = w145_run(binary, store, case_root, label, query)
  w145_assert(result.success?, "ClickHouse #{label} failed (#{result.exit_code}): #{result.stderr}")
  actual = result.stdout.strip
  w145_assert(actual == expected, "ClickHouse #{label} differs: expected #{expected.inspect}, got #{actual.inspect}")
  actual
end

def w145_new_store(root : String, name : String) : String
  path = File.join(root, "stores", name)
  w145_assert(!File.exists?(path) && !File.symlink?(path), "refusing to reuse W145 store #{path}")
  Dir.mkdir(path)
  path
end

def w145_find_part(store : String, label : String) : String
  candidates = Dir.glob(File.join(store, "**", "all_1_1_0"))
  w145_assert(candidates.size == 1, "#{label}: expected one unpartitioned stock part, found #{candidates.size}")
  part = candidates.first
  w145_assert(File.directory?(part) && !File.symlink?(part), "#{label}: stock part is missing or symlinked")
  part
end

def w145_data_path(binary : String, store : String, case_root : String, table : String) : String
  result = w145_run(binary, store, case_root, "data-path-#{table}",
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw")
  w145_assert(result.success?, "#{table}: cannot get ClickHouse part path: #{result.stderr}")
  path = result.stdout.strip
  root = File.expand_path(store)
  canonical = File.expand_path(path)
  w145_assert(path.starts_with?("/") && canonical.starts_with?(root.rstrip('/') + "/"), "#{table}: data path escaped isolated store")
  current = ""
  canonical.split('/').each do |component|
    next if component.empty?
    current = current.empty? ? "/#{component}" : File.join(current, component)
    w145_assert(!File.symlink?(current), "#{table}: data path includes symlink #{current}")
  end
  w145_assert(File.directory?(canonical), "#{table}: part path is not a directory")
  canonical
end

def w145_stream_file(part : String, logical : String, extension : String) : String
  File.join(part, "#{CrystalClick::StreamName.hash(logical)}.#{extension}")
end

def w145_raw_mark_records(path : String, label : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = w145_read_bytes(path, label)
  w145_assert(bytes.size > 0 && bytes.size % CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE == 0,
    "#{label}: mark file is not whole adaptive records")
  count = bytes.size // CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE
  w145_assert(count == 4, "#{label}: expected 3 real marks plus terminal, got #{count}")
  records = [] of Tuple(UInt64, UInt64, UInt64)
  count.times do |index|
    start = index * CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE
    compressed = w145_le_u64(bytes, start)
    decompressed = w145_le_u64(bytes, start + 8)
    rows = w145_le_u64(bytes, start + 16)
    expected_rows = index == 3 ? 0_u64 : 4_u64
    w145_assert(rows == expected_rows, "#{label}: mark #{index} row count #{rows} != #{expected_rows}")
    records << {compressed, decompressed, rows}
  end
  records
end

def w145_le_u64(bytes : Bytes, offset : Int) : UInt64
  w145_assert(offset >= 0 && offset <= bytes.size - 8, "W145 UInt64 read outside bytes")
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def w145_hex(bytes : Bytes) : String
  String.build do |io|
    bytes.each { |byte| io << byte.to_s(16).rjust(2, '0') }
  end
end

def w145_mark_grid(part : String, logical : String, role : String, label : String) : Tuple(Bytes, Array(UInt64), Array(UInt64), Array(Tuple(UInt64, UInt64, UInt64)))
  data_path = w145_stream_file(part, logical, "bin")
  marks_path = w145_stream_file(part, logical, "mrk2")
  data_file = w145_read_bytes(data_path, "#{label} compressed data")
  mark_file = w145_read_bytes(marks_path, "#{label} raw mrk2")
  raw_marks = w145_raw_mark_records(marks_path, "#{label} raw mrk2")
  decompressed = CrystalClick::CompressedBlock.decode_all(data_file, max_output_size: W145_MAX_FILE_BYTES)
  prefix = role.ends_with?(".dictionary") ? 8 : 0
  limits = CrystalClick::CompressedStreamLimits.new(
    max_file_bytes: W145_MAX_FILE_BYTES,
    max_mark_bytes: 1024 * 1024,
    max_frame_compressed_bytes: 16 * 1024 * 1024,
    max_frame_decompressed_bytes: W145_MAX_FILE_BYTES,
    max_records: 100_000,
    max_decoded_bytes: W145_MAX_FILE_BYTES,
    max_result_bytes: W145_MAX_FILE_BYTES,
  )
  grid = CrystalClick::CompressedMarkReader.inspect(
    data_path, marks_path, data_file.size.to_i64, mark_file.size.to_i64, prefix,
    CrystalClick::CompressedStreamBudget.new(limits)
  )
  w145_assert(grid.mark_count == 3 && grid.rows_per_mark == W145_ROWS_PER_MARK, "#{label}: inspected outer mark schedule differs")
  w145_assert(grid.logical_size == decompressed.size.to_i64, "#{label}: frame-walked EOF differs from decoded lane size")
  positions = grid.positions.map(&.to_u64)
  w145_assert(positions.size == 4 && positions.last == decompressed.size.to_u64, "#{label}: logical grid does not end at decompressed EOF")
  w145_assert(positions.first == prefix.to_u64, "#{label}: logical prefix coordinate differs")
  {decompressed, positions, grid.rows_per_mark, raw_marks}
end

def w145_actual_streams(part : String, type : CrystalClick::BinaryDataType, column : String,
                        profile : CrystalClick::BinaryBulkProfile, fixture : W145Case,
                        lane_log : IO, label : String) : CrystalClick::BinaryBulkStreams
  plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, column, profile: profile)
  streams = Hash(String, CrystalClick::BinaryBulkStream).new
  plan.stream_names.each do |role, logical|
    data_name = "#{CrystalClick::StreamName.hash(logical)}.bin"
    mark_name = "#{CrystalClick::StreamName.hash(logical)}.mrk2"
    checksums = CrystalClick::PartChecksums.open(part)
    checksums.validate_selected_entries(part, data_name, mark_name)
    bytes, offsets, rows, raw_marks = w145_mark_grid(part, logical, role, "#{label} #{role}")
    streams[role] = CrystalClick::BinaryBulkStream.new(bytes, offsets)
    lane_log << "#{fixture.kind}\t#{fixture.profile_name}\t#{column}\t#{role}\t#{logical}\t#{offsets.join(",")}\t#{rows.join(",")}\t#{raw_marks.map { |mark| "#{mark[0]}:#{mark[1]}:#{mark[2]}" }.join(",")}\t#{w145_hex(bytes)}\n"
  end
  CrystalClick::BinaryBulkStreams.new(mark_count: 3, streams: streams)
end

def w145_validate_serialization(part : String, fixture : W145Case, label : String) : Nil
  codec_path = File.join(part, "default_compression_codec.txt")
  w145_assert(File.read(codec_path) == "CODEC(LZ4)", "#{label}: part is not the pinned LZ4 profile")
  info_path = File.join(part, "serialization.json")
  w145_assert(File.file?(info_path) && !File.symlink?(info_path), "#{label}: serialization.json is missing")
  info = JSON.parse(File.read(info_path))
  propagated = info["propagate_types_serialization_versions_to_nested_types"].as_bool
  w145_assert(propagated, "#{label}: nested serialization version propagation is not recorded true")
  versions = info["types_serialization_versions"].as_h
  string_version = versions["string"]?.try(&.as_i) || w145_fail("#{label}: serialization.json lacks String version")
  expected = fixture.profile_name == "single_stream" ? 0 : 1
  w145_assert(string_version == expected, "#{label}: persisted String serializer id #{string_version} != #{expected}")
  raw = File.read(info_path)
  w145_assert(!raw.includes?("dict_prefix"), "#{label}: specialized .dict_prefix metadata is outside this profile")
  nil
end

def w145_validate_part(part : String, fixture : W145Case, label : String) : Hash(String, CrystalClick::BinaryBulkStreams)
  w145_assert(File.directory?(part) && !File.symlink?(part), "#{label}: part is missing or symlinked")
  checksums = CrystalClick::PartChecksums.open(part)
  w145_assert(!checksums.entries.empty?, "#{label}: checksums are empty")
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }
  w145_validate_serialization(part, fixture, label)

  expected_names = Set(String).new
  result = Hash(String, CrystalClick::BinaryBulkStreams).new
  fixture.types.each do |column, type|
    plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, column, profile: fixture.profile)
    plan.stream_names.each_value { |logical| expected_names << logical }
    result[column] = w145_actual_streams(part, type, column, fixture.profile, fixture, IO::Memory.new, label)
  end
  metadata = File.read(File.join(part, "columns_substreams.txt"))
  w145_assert(!metadata.includes?("dict_prefix"), "#{label}: substream metadata contains specialized dict_prefix")
  actual_names = metadata.lines.select(&.starts_with?("\t")).map(&.strip).to_set
  w145_assert(actual_names == expected_names, "#{label}: actual substream roster differs: #{actual_names.to_a.sort.inspect} != #{expected_names.to_a.sort.inspect}")
  expected_bases = expected_names.map { |logical| CrystalClick::StreamName.hash(logical) }.to_set
  actual_bin_bases = Dir.children(part).select(&.ends_with?(".bin")).map { |name| name[0, name.bytesize - 4] }.to_set
  actual_mark_bases = Dir.children(part).select(&.ends_with?(".mrk2")).map { |name| name[0, name.bytesize - 5] }.to_set
  w145_assert(actual_bin_bases == expected_bases, "#{label}: physical .bin roster differs from planned hashed basenames")
  w145_assert(actual_mark_bases == expected_bases, "#{label}: physical .mrk2 roster differs from planned hashed basenames")
  result
end

def w145_compare_decoded_to_literals(type : CrystalClick::BinaryDataType,
                                     actual : CrystalClick::BinaryBulkStreams,
                                     fixture : W145Case, column : String, label : String) : Nil
  decoded = CrystalClick::BinaryBulkCodec.decode(type, actual, W145_ROWS_PER_MARK, profile: fixture.profile)
  expected = fixture.values[column]
  w145_assert(decoded.size == expected.size, "#{label} column #{column}: decoded mark count differs")
  decoded.each_with_index do |mark, mark_index|
    w145_assert(mark.size == expected[mark_index].size, "#{label} column #{column} mark #{mark_index}: decoded count differs")
    mark.each_with_index do |value, row_index|
      literal = expected[mark_index][row_index]
      w145_assert(value.type == literal.type && value.is_null? == literal.is_null?,
        "#{label} column #{column} mark #{mark_index} row #{row_index}: decoded nominal/null identity differs")
      w145_assert(w145_value_fingerprint(value) == w145_value_fingerprint(literal),
        "#{label} column #{column} mark #{mark_index} row #{row_index}: decoded value differs")
    end
  end
  nil
end

def w145_compare_codec_to_part(part : String, fixture : W145Case, lane_log : IO,
                               comparisons : IO, label : String,
                               require_encoder_match : Bool = false) : Hash(String, CrystalClick::BinaryBulkStreams)
  retained = Hash(String, CrystalClick::BinaryBulkStreams).new
  fixture.types.each do |column, type|
    actual = w145_actual_streams(part, type, column, fixture.profile, fixture, lane_log, label)
    authored = CrystalClick::BinaryBulkCodec.encode(type, fixture.values[column], profile: fixture.profile)
    w145_assert(actual.mark_count == authored.mark_count, "#{label} column #{column}: mark count differs")
    w145_assert(actual.roles == authored.roles, "#{label} column #{column}: role roster differs")
    actual.roles.each do |role|
      left = actual.stream(role)
      right = authored.stream(role)
      same = left.offsets == right.offsets && left.bytes == right.bytes
      comparisons << "#{fixture.kind}\t#{fixture.profile_name}\t#{label}\t#{column}\t#{role}\t#{same ? "exact" : "different-valid-dictionary-or-coordinate-choice"}\n"
      if require_encoder_match
        w145_assert(same, "#{label} column #{column} role #{role}: borrowed-library lane differs from its emitted raw bytes/offsets")
      end
    end
    w145_compare_decoded_to_literals(type, actual, fixture, column, label)
    retained[column] = authored
  end
  retained
end

def w145_value_fingerprint(value : CrystalClick::BinaryValue) : String
  type = value.type
  return "#{type.name}:NULL" if value.is_null?
  case type.tag
  when CrystalClick::BinaryDataType::TAG_ARRAY,
       CrystalClick::BinaryDataType::TAG_MAP,
       CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
    "#{type.name}:[#{value.elements.map { |child| w145_value_fingerprint(child) }.join("|")}]"
  when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY,
       CrystalClick::BinaryDataType::TAG_NULLABLE
    "#{type.name}<#{w145_value_fingerprint(value.child_at(0))}>"
  when CrystalClick::BinaryDataType::TAG_BOOL
    "Bool:#{value.as_bool}"
  when CrystalClick::BinaryDataType::TAG_STRING
    "String:#{w145_hex(value.bytes)}"
  else
    "#{type.name}:#{w145_hex(value.bytes)}"
  end
end

def w145_encode_column(type : CrystalClick::BinaryDataType, column : String, fixture : W145Case,
                       profile : CrystalClick::BinaryBulkProfile) : CrystalClick::BinaryBulkStreams
  CrystalClick::BinaryBulkCodec.encode(type, fixture.values[column], profile: profile)
end

def w145_replace_lanes(part : String, fixture : W145Case,
                       columns : Array(String),
                       overrides : Hash(String, CrystalClick::BinaryBulkStreams)? = nil) : Array(String)
  replaced = [] of String
  fixture.types.each do |column, type|
    next unless columns.includes?(column)
    plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, column, profile: fixture.profile)
    streams = overrides.try(&.[column]?) || w145_encode_column(type, column, fixture, fixture.profile)
    plan.stream_names.each do |role, logical|
      stream = streams.stream(role)
      prefix = role.ends_with?(".dictionary") ? 8 : 0
      files = CrystalClick::CompressedMarkWriter.encode(stream.bytes, stream.offsets, W145_ROWS_PER_MARK,
        prefix_size: prefix, frame_bytes: 4096)
      data_path = w145_stream_file(part, logical, "bin")
      marks_path = w145_stream_file(part, logical, "mrk2")
      w145_replace_file(data_path, files.data)
      w145_replace_file(marks_path, files.marks)
      replaced << File.basename(data_path) << File.basename(marks_path)
    end
  end
  replaced
end

def w145_rebuild_checksums(part : String, replaced : Array(String)) : Nil
  CrystalClick::WidePartWriter.w145_rebuild_checksums(part)
  checksums = CrystalClick::PartChecksums.open(part)
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }
  nil
end

def w145_attach(binary : String, store : String, case_root : String, table : String, part : String) : Nil
  data_path = w145_data_path(binary, store, case_root, table)
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  destination = File.join(detached, "all_1_1_0")
  w145_assert(!File.exists?(destination) && !File.symlink?(destination), "refusing to overwrite detached W145 part")
  FileUtils.cp_r(part, destination)
  w145_assert(!File.symlink?(destination), "W145 detached part is a symlink")
  result = w145_run(binary, store, case_root, "attach-#{table}", "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w145_assert(result.success?, "#{table}: ATTACH PART failed: #{result.stderr}")
  nil
end

def w145_verify_table(binary : String, store : String, case_root : String,
                      table : String, fixture : W145Case) : Nil
  check = w145_run(binary, store, case_root, "check-#{table}",
    "CHECK TABLE default.#{table} FORMAT TSVRaw")
  expected_check = "all_1_1_0\t1\t\n"
  w145_assert(check.success?, "ClickHouse check-#{table} failed (#{check.exit_code}): #{check.stderr}")
  w145_assert(check.stdout == expected_check,
    "ClickHouse check-#{table} differs: expected #{expected_check.inspect}, got #{check.stdout.inspect}")
  fixture.type_names.each do |column, expected_type|
    query = "SELECT type FROM system.columns WHERE database='default' AND table='#{table}' AND name='#{column}' FORMAT TSVRaw"
    actual = w145_expect_one_line(binary, store, case_root, "type-#{table}-#{column}", query)
    w145_assert(actual == expected_type,
      "#{table}.#{column}: persisted nominal type #{actual.inspect} != #{expected_type.inspect}")
  end
  w145_expect_query(binary, store, case_root, "count-#{table}",
    "SELECT count(), min(k), max(k) FROM default.#{table} FORMAT TSVRaw", "12\t0\t11")
  nil
end

def w145_expect_one_line(binary : String, store : String, case_root : String, label : String, query : String) : String
  result = w145_run(binary, store, case_root, label, query)
  w145_assert(result.success?, "ClickHouse #{label} failed: #{result.stderr}")
  lines = result.stdout.lines.map(&.strip).reject(&.empty?)
  w145_assert(lines.size == 1, "ClickHouse #{label} returned #{lines.size} rows instead of one")
  lines[0]
end

def w145_select_query(table : String, fixture : W145Case) : String
  "SELECT #{fixture.select_columns.join(", ")} FROM default.#{table} ORDER BY k FORMAT RowBinary"
end

def w145_build_hash(binary : String, output_root : String) : String
  store = File.join(output_root, "build-info-store")
  FileUtils.mkdir_p(store)
  result = w145_run(binary, store, output_root, "build-options", "SELECT name, value FROM system.build_options ORDER BY name FORMAT TabSeparatedRaw")
  w145_assert(result.success?, "cannot query pinned ClickHouse build options: #{result.stderr}")
  w145_write_new_text(File.join(output_root, "results", "build-options.tsv"), result.stdout)
  matches = result.stdout.lines.compact_map do |line|
    fields = line.split('\t')
    fields[1] if fields.size == 2 && fields[0] == "VERSION_GITHASH"
  end
  w145_assert(matches.size == 1 && matches[0] == W145_BUILD_HASH,
    "runtime VERSION_GITHASH differs from the independent executable/source pins: #{matches.inspect}")
  W145_BUILD_HASH
end

def w145_create_and_insert(binary : String, store : String, case_root : String,
                           table : String, fixture : W145Case) : Nil
  create = w145_create_query(table, fixture)
  result = w145_run(binary, store, case_root, "create-#{table}", create)
  w145_assert(result.success?, "#{table}: CREATE TABLE failed: #{result.stderr}")
  if fixture.kind == "map"
    actual_ddl = w145_expect_one_line(binary, store, case_root, "create-query-#{table}",
      "SELECT create_table_query FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw")
    w145_assert(actual_ddl.includes?("map_serialization_version = 'basic'") || actual_ddl.includes?("map_serialization_version='basic'"),
      "#{table}: persisted CREATE TABLE does not pin BASIC Map serialization")
    w145_assert(actual_ddl.includes?("map_serialization_version_for_zero_level_parts = 'basic'") || actual_ddl.includes?("map_serialization_version_for_zero_level_parts='basic'"),
      "#{table}: persisted CREATE TABLE does not pin zero-level BASIC Map serialization")
  end
  inserted = w145_run(binary, store, case_root, "insert-#{table}", w145_insert_query(table, fixture))
  w145_assert(inserted.success?, "#{table}: INSERT VALUES failed: #{inserted.stderr}")
  nil
end

def w145_create_empty(binary : String, store : String, case_root : String,
                      table : String, fixture : W145Case) : Nil
  result = w145_run(binary, store, case_root, "create-#{table}", w145_create_query(table, fixture))
  w145_assert(result.success?, "#{table}: empty exchange CREATE TABLE failed: #{result.stderr}")
end

def w145_validate_metadata(part : String, fixture : W145Case, label : String) : Nil
  expected_columns = fixture.types.keys.sort
  actual_columns = File.read(File.join(part, "columns.txt"))
  w145_assert(actual_columns.starts_with?("columns format version: 1\n#{expected_columns.size} columns:\n"),
    "#{label}: columns metadata header differs")
  w145_assert(!actual_columns.includes?("LowCardinality(Nullable(LowCardinality"), "#{label}: unexpected nested LC metadata")
  nil
end

def w145_copy_part(source : String, destination : String) : Nil
  w145_assert(!File.exists?(destination) && !File.symlink?(destination), "refusing to overwrite W145 exchange part")
  FileUtils.mkdir_p(File.dirname(destination))
  FileUtils.cp_r(source, destination)
  nil
end

def w145_case_root(root : String, kind : String, profile : String) : String
  path = File.join(root, "cases", kind, profile)
  FileUtils.mkdir_p(path)
  path
end

def w145_process_cell(binary : String, root : String, kind : String, profile_name : String,
                      cells : IO, details : IO, lane_log : IO, comparisons : IO, assertions : IO) : Nil
  fixture = w145_case(kind, profile_name)
  case_root = w145_case_root(root, kind, profile_name)
  stock_name = "stock_#{kind}_#{profile_name}"
  stock_store = w145_new_store(root, stock_name)
  stock_table = "w145_#{kind}_#{profile_name}"
  w145_create_and_insert(binary, stock_store, case_root, stock_table, fixture)
  stock_part = w145_find_part(stock_store, "#{kind}/#{profile_name} stock")
  w145_validate_metadata(stock_part, fixture, "#{kind}/#{profile_name} stock")
  w145_validate_part(stock_part, fixture, "#{kind}/#{profile_name} stock")
  retained = w145_compare_codec_to_part(stock_part, fixture, lane_log, comparisons,
    "#{kind}/#{profile_name} stock")
  w145_verify_table(binary, stock_store, case_root, stock_table, fixture)

  exchange_name = "library_#{kind}_#{profile_name}"
  exchange_store = w145_new_store(root, exchange_name)
  exchange_table = "w145_lib_#{kind}_#{profile_name}"
  w145_create_empty(binary, exchange_store, case_root, exchange_table, fixture)
  exchange_part = File.join(root, "parts", kind, profile_name, "all_1_1_0")
  w145_copy_part(stock_part, exchange_part)
  replaced = w145_replace_lanes(exchange_part, fixture, fixture.types.keys, retained)
  w145_rebuild_checksums(exchange_part, replaced)
  w145_validate_metadata(exchange_part, fixture, "#{kind}/#{profile_name} library")
  w145_validate_part(exchange_part, fixture, "#{kind}/#{profile_name} library")
  w145_compare_codec_to_part(exchange_part, fixture, lane_log, comparisons,
    "#{kind}/#{profile_name} library", true)
  w145_attach(binary, exchange_store, case_root, exchange_table, exchange_part)
  w145_verify_table(binary, exchange_store, case_root, exchange_table, fixture)

  stock_binary = w145_run(binary, stock_store, case_root, "rowbinary-stock-#{kind}-#{profile_name}", w145_select_query(stock_table, fixture))
  w145_assert(stock_binary.success?, "#{kind}/#{profile_name}: stock RowBinary query failed: #{stock_binary.stderr}")
  library_binary = w145_run(binary, exchange_store, case_root, "rowbinary-library-#{kind}-#{profile_name}", w145_select_query(exchange_table, fixture))
  w145_assert(library_binary.success?, "#{kind}/#{profile_name}: library-envelope RowBinary query failed: #{library_binary.stderr}")
  w145_assert(stock_binary.stdout.to_slice == library_binary.stdout.to_slice,
    "#{kind}/#{profile_name}: attached borrowed-envelope RowBinary bytes differ from stock INSERT output")
  w145_write_new(File.join(case_root, "stock.rows.bin"), stock_binary.stdout.to_slice)
  w145_write_new(File.join(case_root, "library.rows.bin"), library_binary.stdout.to_slice)

  # Persist a re-query manifest, not an expected-output authority. The parent
  # independently computes and checks RowBinary bytes from the authored rows.
  query = w145_select_query(stock_table, fixture)
  nominal = "SELECT name, type FROM system.columns WHERE database='default' AND table='#{stock_table}' ORDER BY position FORMAT TSVRaw"
  literal_insert = w145_insert_query(stock_table, fixture).gsub("\n", " ")
  cells << "stock\t#{kind}\t#{profile_name}\t#{stock_store}\tdefault.#{stock_table}\n"
  cells << "library\t#{kind}\t#{profile_name}\t#{exchange_store}\tdefault.#{exchange_table}\n"
  details << "stock\t#{kind}\t#{profile_name}\t#{stock_store}\tdefault.#{stock_table}\t#{w145_create_query(stock_table, fixture)}\t#{literal_insert}\t#{query}\t#{nominal}\t#{fixture.formula}\n"
  details << "library\t#{kind}\t#{profile_name}\t#{exchange_store}\tdefault.#{exchange_table}\t#{w145_create_query(exchange_table, fixture)}\t#{literal_insert}\t#{w145_select_query(exchange_table, fixture)}\tSELECT name, type FROM system.columns WHERE database='default' AND table='#{exchange_table}' ORDER BY position FORMAT TSVRaw\t#{fixture.formula}\n"
  assertions << "#{kind}\t#{profile_name}\tstock lanes decode to authored values; library lanes decode and are consumed by ATTACH/CHECK and RowBinary\tPASS\n"
  nil
end

def w145_seeded_wrong_value_control(binary : String, root : String, lane_log : IO, assertions : IO) : Nil
  fixture = w145_case("root", "with_size_stream")
  case_root = w145_case_root(root, "control", "valid-wrong-value")
  stock_store = File.join(root, "stores", "stock_root_with_size_stream")
  stock_table = "w145_root_with_size_stream"
  stock_part = w145_find_part(stock_store, "W145 seeded-control source")

  changed_values = fixture.values["n"].map(&.dup)
  changed_values[0][0] = CrystalClick::BinaryValue.low_cardinality(
    fixture.types["n"], CrystalClick::BinaryValue.uint64(999_u64)
  )
  changed_fixture = W145Case.new(fixture.kind, fixture.profile_name, fixture.profile, fixture.declarations,
    fixture.type_names, fixture.types, begin
    copied = fixture.values.dup
    copied["n"] = changed_values
    copied
  end, fixture.insert_x, fixture.insert_n, fixture.select_columns, fixture.formula)
  control_part = File.join(root, "controls", "valid-wrong-value", "all_1_1_0")
  w145_copy_part(stock_part, control_part)
  replacement = w145_encode_column(fixture.types["n"], "n", changed_fixture, fixture.profile)
  overrides = {"n" => replacement} of String => CrystalClick::BinaryBulkStreams
  replaced = w145_replace_lanes(control_part, changed_fixture, ["n"] of String, overrides)
  w145_rebuild_checksums(control_part, replaced)

  store = w145_new_store(root, "control_valid_wrong_value")
  table = "w145_control_valid_wrong"
  w145_create_empty(binary, store, case_root, table, fixture)
  w145_attach(binary, store, case_root, table, control_part)
  w145_verify_table(binary, store, case_root, table, fixture)
  good = w145_run(binary, stock_store, case_root, "seed-good-rowbinary", w145_select_query(stock_table, fixture))
  bad = w145_run(binary, store, case_root, "seed-bad-rowbinary", w145_select_query(table, fixture))
  w145_assert(good.success? && bad.success?, "valid wrong-value control failed to query")
  w145_assert(good.stdout.to_slice != bad.stdout.to_slice, "valid wrong-value control did not change the persisted logical output")
  begin
    w145_assert(good.stdout.to_slice == bad.stdout.to_slice, "seeded full RowBinary comparator accepted changed LC(UInt64) value at k=0")
  rescue error : W145Mismatch
    w145_write_new_text(File.join(root, "controls", "valid-wrong-value", "assertion.txt"),
      "ATTACH and CHECK passed; an independently full-row RowBinary comparator rejected changed LC(UInt64) n[0] at k=0.\n")
    assertions << "control\tvalid-wrong-value\tATTACH/CHECK passed; full RowBinary comparator rejected changed LC(UInt64) n[0]\tPASS\n"
    return
  end
  w145_fail("valid wrong-value output escaped the full RowBinary comparator")
end

def w145_verify_runtime(binary : String, root : String) : Nil
  version_out = IO::Memory.new
  version_err = IO::Memory.new
  status = Process.run(binary, ["local", "--version"], output: version_out, error: version_err)
  w145_assert(status.success?, "cannot query pinned ClickHouse runtime version: #{version_err}")
  version = version_out.to_s.strip
  w145_assert(version == W145_RUNTIME_VERSION, "ClickHouse runtime version differs: #{version.inspect}")
  sha = w145_sha256_file(binary)
  w145_assert(sha == W145_RUNTIME_SHA256, "ClickHouse runtime SHA differs: #{sha}")
  w145_write_new_text(File.join(root, "results", "runtime-version.txt"), "#{version}\nruntime_sha256=#{sha}\n")
  build = w145_build_hash(binary, root)
  w145_write_new_text(File.join(root, "results", "runtime-build-hash.txt"), "VERSION_GITHASH=#{build}\n")
  nil
end

root = ENV.fetch("W145_CHECK_ROOT")
binary = ENV.fetch("CLICKHOUSE_BIN")
source_root = ENV.fetch("CLICKHOUSE_SOURCE_ROOT")
source_revision = ENV.fetch("CLICKHOUSE_SOURCE_REVISION", W145_SOURCE_REVISION)
w145_assert(root.starts_with?("/private/tmp/crystal-click-low-cardinality-physical-w145."), "W145 output root is outside the fresh evidence namespace")
w145_assert(File.directory?(root) && !File.symlink?(root), "W145 output root must be a pre-created real directory")
w145_assert(File.file?(binary) && !File.symlink?(binary), "pinned ClickHouse binary is missing or symlinked")
w145_assert(File.directory?(source_root) && !File.symlink?(source_root), "pinned ClickHouse source root is missing or symlinked")
w145_assert(source_revision == W145_SOURCE_REVISION, "ClickHouse source revision pin differs")
root_children = Dir.children(root)
required_root_dirs = ["cases", "controls", "crystal-cache", "lanes", "parts", "results", "stores"] of String
unexpected_root_children = root_children - required_root_dirs - ["check.log"]
w145_assert(required_root_dirs.all? { |name| root_children.includes?(name) } && unexpected_root_children.empty?,
  "W145 output root has missing required directories or unexpected children: #{root_children.sort.inspect}")
if root_children.includes?("check.log")
  check_log = File.join(root, "check.log")
  w145_assert(File.file?(check_log) && !File.symlink?(check_log), "W145 check.log is not a regular file")
end
w145_verify_runtime(binary, root)

cells_path = File.join(root, "results", "cells.tsv")
details_path = File.join(root, "results", "cell-details.tsv")
lanes_path = File.join(root, "results", "lanes.tsv")
comparisons_path = File.join(root, "results", "lane-relations.tsv")
assertions_path = File.join(root, "results", "assertions.tsv")
File.open(cells_path, "w") do |cells|
  cells << "mode\tkind\tprofile\tstore\ttable\n"
  File.open(details_path, "w") do |details|
    details << "mode\tkind\tprofile\tstore\ttable\tddl\tinsert_sql\trowbinary_select\tnominal_type_select\tliteral_formula\n"
    File.open(lanes_path, "w") do |lane_log|
      lane_log << "kind\tprofile\tcolumn\trole\tlogical_stream\tlogical_offsets\trows_per_mark\traw_mrk2_c_d_rows\tdecompressed_hex\n"
      File.open(comparisons_path, "w") do |comparisons|
        comparisons << "kind\tprofile\tcell\tcolumn\trole\tlogical_lane_relation\n"
        File.open(assertions_path, "w") do |assertions|
          assertions << "kind\tprofile\tassertion\tresult\n"
          ["root", "array", "tuple", "map"].each do |kind|
            ["single_stream", "with_size_stream"].each do |profile_name|
              w145_process_cell(binary, root, kind, profile_name, cells, details,
                lane_log, comparisons, assertions)
            end
          end
          w145_seeded_wrong_value_control(binary, root, lane_log, assertions)
        end
      end
    end
  end
end

w145_write_new_text(File.join(root, "results", "run.txt"),
  "source_reference_revision=#{W145_SOURCE_REVISION}\n" +
  "runtime_version=#{W145_RUNTIME_VERSION}\n" +
  "runtime_sha256=#{W145_RUNTIME_SHA256}\n" +
  "runtime_build_hash=#{W145_BUILD_HASH}\n" +
  "cells=4 ordinary Wide schemas x 2 String serialization profiles; 12 rows; marks [4,4,4]\n" +
  "scope=stock lanes decode to literals; encoder byte/grid relation is reported, not required; codec lanes are consumed in a borrowed stock envelope; not an independent complete-part writer\n" +
  "profile=serialization_info_version with_types; propagate nested versions true; BASIC Map; nullable basic; LZ4; adaptive mrk2\n" +
  "excluded=Compact dict_prefix; Map WITH_BUCKETS; unqualified profile auto-detection\n")

puts "PASS W145 eight stock/library Wide cells: stock lanes decoded to literals, library lanes matched emitted bytes and decoded to literals, stock/encoder lane relation recorded, ATTACH/CHECK/RowBinary passed; LC(UInt64) wrong-value control rejected"
