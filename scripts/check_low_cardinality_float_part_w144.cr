# W144 raw persisted LowCardinality(Float) dictionary witness.
#
# Each output starts from a retained, stock-checked Wide part with schema
# `k UInt64, x LowCardinality(Float*)`. Only x's dictionary/index data and mark
# files are replaced; checksums are rebuilt over the complete copied part.
# This tests raw part deserialization, not Native passthrough or a whole-part
# writer API.
require "file_utils"
require "digest/sha256"
require "../src/crystal_click"

W144_SOURCE_REVISION = "9007d227b64a3f8b667fc5258ceb2923f3cf477d"
W144_RUNTIME_SHA256  = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W144_RUNTIME_VERSION = "ClickHouse local version 26.10.1.1201 (official build)."
W144_ORDER_A         = [0, 1, 2, 3, 4, 5, 0, 2, 1, 3, 4, 5]
W144_ORDER_B         = [3, 5, 1, 4, 2, 0, 3, 1, 5, 2, 4, 0]
W144_REAL_MARK_ROWS  = [4_u64, 4_u64, 4_u64]

struct W144CommandResult
  getter stdout : String
  getter stderr : String
  getter exit_code : Int32

  def initialize(@stdout : String, @stderr : String, @exit_code : Int32)
  end

  def success? : Bool
    @exit_code == 0
  end
end

struct W144EncodedLanes
  getter dictionary_raw : Bytes
  getter indexes_raw : Bytes
  getter dictionary_offsets : Array(UInt64)
  getter indexes_offsets : Array(UInt64)
  getter dictionary_files : CrystalClick::CompressedMarkFiles
  getter indexes_files : CrystalClick::CompressedMarkFiles

  def initialize(
    @dictionary_raw : Bytes,
    @indexes_raw : Bytes,
    @dictionary_offsets : Array(UInt64),
    @indexes_offsets : Array(UInt64),
    @dictionary_files : CrystalClick::CompressedMarkFiles,
    @indexes_files : CrystalClick::CompressedMarkFiles,
  )
  end
end

module CrystalClick
  module WidePartWriter
    # The public library checksum reader intentionally does not expose raw
    # hashes. This script-only bridge uses its format owner and reconstructs
    # every record from the retained part bytes, adding no production API.
    def self.w144_rebuild_checksums(stage : String, raw_overrides : Hash(String, Bytes) = Hash(String, Bytes).new) : Nil
      original = PartChecksums.open(stage)
      records = [] of ChecksumRecord
      original.entries.keys.sort.each do |name|
        path = File.join(stage, name)
        raise "checksum input is missing or a symlink: #{path}" if File.symlink?(path) || !File.file?(path)
        physical = File.read(path).to_slice
        entry = original.entry(name) || raise "checksum entry disappeared: #{name}"
        if entry.compressed
          raw = raw_overrides[name]? || CompressedBlock.decode_all(physical)
          records << ChecksumRecord.new(
            name,
            physical.size.to_u64,
            CityHashV1.file_hash(physical),
            true,
            raw.size.to_u64,
            CityHashV1.file_hash(raw)
          )
        else
          records << ChecksumRecord.new(name, physical.size.to_u64, CityHashV1.file_hash(physical), false)
        end
      end
      PartChecksumsWriter.write(stage, records)
      nil
    end
  end
end

def w144_assert(condition : Bool, message : String) : Nil
  raise message unless condition
end

def w144_sha256_file(path : String) : String
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

def w144_assert_no_symlink_components(path : String) : Nil
  w144_assert(path.starts_with?("/"), "W144 path must be absolute: #{path}")
  current = ""
  path.split('/').each do |component|
    next if component.empty?
    current = current.empty? ? "/#{component}" : File.join(current, component)
    w144_assert(!File.symlink?(current), "W144 path component is a symlink: #{current}")
  end
  nil
end

def w144_write_new(path : String, bytes : Bytes) : Nil
  w144_assert(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite W144 artifact: #{path}")
  File.open(path, "wb") { |file| file.write(bytes) }
  nil
end

def w144_write_new_text(path : String, text : String) : Nil
  w144_assert(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite W144 artifact: #{path}")
  File.open(path, "w") { |file| file << text }
  nil
end

def w144_replace_regular_file(path : String, bytes : Bytes) : Nil
  w144_assert(File.file?(path) && !File.symlink?(path), "replacement target is missing or a symlink: #{path}")
  File.open(path, "wb") { |file| file.write(bytes) }
  nil
end

def w144_assert_no_symlinks(path : String) : Nil
  w144_assert(!File.symlink?(path), "W144 path must not be a symlink: #{path}")
  return unless File.directory?(path)
  Dir.children(path).each do |child|
    nested = File.join(path, child)
    w144_assert(!File.symlink?(nested), "W144 tree contains a symlink: #{nested}")
    w144_assert_no_symlinks(nested) if File.directory?(nested)
  end
  nil
end

def w144_tree_files(root : String) : Array(String)
  result = [] of String
  visit = uninitialized Proc(String, Nil)
  visit = ->(directory : String) do
    Dir.children(directory).sort.each do |child|
      path = File.join(directory, child)
      w144_assert(!File.symlink?(path), "W144 tree contains a symlink: #{path}")
      if File.directory?(path)
        visit.call(path)
      else
        result << path[root.bytesize + 1, path.bytesize - root.bytesize - 1]
      end
    end
    nil
  end
  visit.call(root)
  result.sort!
end

def w144_assert_same_non_lc_files(template : String, modified : String, replaced_names : Array(String)) : Nil
  template_files = w144_tree_files(template)
  modified_files = w144_tree_files(modified)
  w144_assert(template_files == modified_files, "part file set changed outside the four LC lanes and checksums")
  excluded = replaced_names + ["checksums.txt"]
  (template_files - excluded).each do |relative|
    left = File.read(File.join(template, relative))
    right = File.read(File.join(modified, relative))
    w144_assert(left == right, "stock template file changed unexpectedly: #{relative}")
  end
  nil
end

def w144_le_u64(bytes : Bytes, offset : Int, label : String) : UInt64
  w144_assert(offset >= 0 && offset <= bytes.size - 8, "#{label}: UInt64 outside byte lane")
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def w144_mark_rows(path : String, label : String) : Array(UInt64)
  w144_assert(File.file?(path) && !File.symlink?(path), "#{label}: missing mark file or symlink")
  bytes = File.read(path).to_slice
  record_size = CrystalClick::WidePart::MARK_SIZE
  w144_assert(bytes.size > 0 && bytes.size % record_size == 0, "#{label}: malformed mark records")
  Array(UInt64).new(bytes.size // record_size) do |index|
    w144_le_u64(bytes, index * record_size + 16, "#{label} mark #{index} rows")
  end
end

def w144_stream_path(part : String, logical_name : String, extension : String) : String
  File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.#{extension}")
end

def w144_validate_template(part : String, float_type : String, label : String) : Nil
  w144_assert_no_symlinks(part)
  w144_assert(File.directory?(part), "#{label}: retained stock template is missing")
  expected_columns = "columns format version: 1\n2 columns:\n`k` UInt64\n`x` LowCardinality(#{float_type})\n"
  w144_assert(File.read(File.join(part, "columns.txt")) == expected_columns, "#{label}: template column metadata differs")
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `k`:\n\tk\n2 substreams for column `x`:\n\tx.dict\n\tx\n"
  w144_assert(File.read(File.join(part, "columns_substreams.txt")) == expected_substreams, "#{label}: template substream metadata differs")
  w144_assert(File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)", "#{label}: template compression metadata differs")

  checksums = CrystalClick::PartChecksums.open(part)
  w144_assert(checksums.entries.size > 0, "#{label}: template checksums are empty")
  checksums.entries.each_key do |name|
    checksums.validate_selected_entries(part, name)
  end

  {"k", "x", "x.dict"}.each do |logical_name|
    rows = w144_mark_rows(w144_stream_path(part, logical_name, "mrk2"), "#{label} #{logical_name}")
    w144_assert(rows == [4_u64, 4_u64, 4_u64, 0_u64], "#{label}: #{logical_name} must have three four-row marks plus terminal")
  end
  {"k", "x", "x.dict"}.each do |logical_name|
    path = w144_stream_path(part, logical_name, "bin")
    w144_assert(File.file?(path) && !File.symlink?(path), "#{label}: missing #{logical_name} data file")
  end
  nil
end

def w144_vector_hex(float_type : String) : Array(String)
  case float_type
  when "Float32"
    ["00000000", "00000080", "0100c07f", "0200c0ff", "0000803f", "000000c0"]
  when "Float64"
    ["0000000000000000", "0000000000000080", "010000000000f87f", "020000000000f8ff", "000000000000f03f", "00000000000000c0"]
  when "BFloat16"
    ["0000", "0080", "c17f", "c2ff", "803f", "00c0"]
  else
    raise "unsupported W144 Float fixture type: #{float_type}"
  end
end

def w144_order(order_name : String) : Array(Int32)
  case order_name
  when "a" then W144_ORDER_A
  when "b" then W144_ORDER_B
  else          raise "unsupported W144 order: #{order_name}"
  end
end

def w144_hex_bytes(hex : String) : Bytes
  w144_assert(hex.bytesize > 0 && hex.bytesize.even?, "fixture hex must have a positive even number of digits")
  Bytes.new(hex.bytesize // 2) do |index|
    hex[index * 2, 2].to_u8(16)
  end
end

def w144_le_decimal(hex : String) : UInt64
  bytes = w144_hex_bytes(hex)
  value = 0_u64
  bytes.each_with_index { |byte, index| value |= byte.to_u64 << (index * 8) }
  value
end

def w144_mutated_hex(float_type : String) : String
  case float_type
  when "Float32"  then "0100803f"
  when "Float64"  then "010000000000f03f"
  when "BFloat16" then "813f"
  else                 raise "unsupported W144 seed type: #{float_type}"
  end
end

def w144_rows(float_type : String, order_name : String, mutate_first_key_four : Bool = false) : Array(String)
  vector = w144_vector_hex(float_type)
  order = w144_order(order_name)
  rows = order.map { |id| vector[id] }
  if mutate_first_key_four
    index = order.index(4) || raise "fixture order is missing key 4"
    rows[index] = w144_mutated_hex(float_type)
  end
  rows
end

def w144_binary_type(float_type : String) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.primitive(float_type)
end

def w144_lc_value(type : CrystalClick::BinaryDataType, lc_type : CrystalClick::BinaryDataType, hex : String) : CrystalClick::BinaryValue
  child = CrystalClick::BinaryValue.fixed(type, w144_hex_bytes(hex))
  CrystalClick::BinaryValue.low_cardinality(lc_type, child)
end

def w144_encode_lanes(float_type : String, order_name : String, mutate_first_key_four : Bool, evidence_dir : String) : W144EncodedLanes
  child_type = w144_binary_type(float_type)
  lc_type = CrystalClick::BinaryDataType.low_cardinality(child_type)
  rows = w144_rows(float_type, order_name, mutate_first_key_four)
  granules = [] of Array(CrystalClick::BinaryValue)
  rows.each_slice(4) do |slice|
    granule = [] of CrystalClick::BinaryValue
    slice.each { |hex| granule << w144_lc_value(child_type, lc_type, hex) }
    granules << granule
  end

  streams = CrystalClick::BinaryLowCardinalityStorageCodec.encode(lc_type, granules)
  w144_assert(streams.mark_count == 3, "#{float_type}/#{order_name}: W142 codec did not produce three real marks")
  w144_assert(streams.roles == ["root.dictionary", "root.indexes"], "#{float_type}/#{order_name}: W142 role set differs")
  dictionary = streams.stream("root.dictionary")
  indexes = streams.stream("root.indexes")
  dictionary_raw = dictionary.bytes
  indexes_raw = indexes.bytes
  dictionary_offsets = dictionary.offsets
  indexes_offsets = indexes.offsets
  w144_assert(dictionary_offsets.size == 4 && dictionary_offsets[0] == 8_u64 && dictionary_offsets[1] == 8_u64 && dictionary_offsets[2] == 8_u64,
    "#{float_type}/#{order_name}: dictionary grid is not update-at-prefix plus terminal")
  w144_assert(dictionary_offsets[3] == dictionary_raw.size.to_u64, "#{float_type}/#{order_name}: dictionary terminal is not EOF")
  w144_assert(indexes_offsets.size == 4 && indexes_offsets.first == 0_u64 && indexes_offsets.last == indexes_raw.size.to_u64,
    "#{float_type}/#{order_name}: index grid does not cover the complete lane")
  w144_assert(w144_le_u64(dictionary_raw, 0, "dictionary version") == 1_u64, "#{float_type}/#{order_name}: dictionary version differs")

  dictionary_files = CrystalClick::CompressedMarkWriter.encode(
    dictionary_raw,
    dictionary_offsets,
    W144_REAL_MARK_ROWS,
    prefix_size: 8
  )
  indexes_files = CrystalClick::CompressedMarkWriter.encode(
    indexes_raw,
    indexes_offsets,
    W144_REAL_MARK_ROWS
  )

  FileUtils.mkdir_p(evidence_dir)
  w144_write_new(File.join(evidence_dir, "dictionary.raw.bin"), dictionary_raw)
  w144_write_new(File.join(evidence_dir, "indexes.raw.bin"), indexes_raw)
  w144_write_new(File.join(evidence_dir, "dictionary.compressed.bin"), dictionary_files.data)
  w144_write_new(File.join(evidence_dir, "dictionary.compressed.mrk2"), dictionary_files.marks)
  w144_write_new(File.join(evidence_dir, "indexes.compressed.bin"), indexes_files.data)
  w144_write_new(File.join(evidence_dir, "indexes.compressed.mrk2"), indexes_files.marks)
  w144_write_new_text(
    File.join(evidence_dir, "grids.tsv"),
    "mark\trows\tdictionary_offset\tindex_offset\n" +
    "0\t4\t#{dictionary_offsets[0]}\t#{indexes_offsets[0]}\n" +
    "1\t4\t#{dictionary_offsets[1]}\t#{indexes_offsets[1]}\n" +
    "2\t4\t#{dictionary_offsets[2]}\t#{indexes_offsets[2]}\n" +
    "terminal\t0\t#{dictionary_offsets[3]}\t#{indexes_offsets[3]}\n"
  )
  W144EncodedLanes.new(dictionary_raw, indexes_raw, dictionary_offsets, indexes_offsets, dictionary_files, indexes_files)
end

def w144_write_part_lanes(part : String, lanes : W144EncodedLanes) : Array(String)
  replaced = [] of String
  {
    {"x.dict", lanes.dictionary_files},
    {"x", lanes.indexes_files},
  }.each do |logical_name, files|
    data_path = w144_stream_path(part, logical_name, "bin")
    marks_path = w144_stream_path(part, logical_name, "mrk2")
    w144_replace_regular_file(data_path, files.data)
    w144_replace_regular_file(marks_path, files.marks)
    replaced << File.basename(data_path)
    replaced << File.basename(marks_path)
  end
  replaced
end

def w144_part_with_values(template : String, destination : String, float_type : String, order_name : String, mutate : Bool, evidence_dir : String) : Array(String)
  w144_assert(!File.exists?(destination) && !File.symlink?(destination), "refusing to overwrite W144 part: #{destination}")
  FileUtils.mkdir_p(File.dirname(destination))
  FileUtils.cp_r(template, destination)
  w144_assert_no_symlinks(destination)
  lanes = w144_encode_lanes(float_type, order_name, mutate, evidence_dir)
  replaced = w144_write_part_lanes(destination, lanes)
  CrystalClick::WidePartWriter.w144_rebuild_checksums(destination)
  checksums = CrystalClick::PartChecksums.open(destination)
  checksums.entries.each_key do |name|
    checksums.validate_selected_entries(destination, name)
  end
  w144_assert_same_non_lc_files(template, destination, replaced)
  replaced
end

def w144_run_clickhouse(binary : String, store : String, case_root : String, label : String, query : String) : W144CommandResult
  query_dir = File.join(case_root, "queries")
  FileUtils.mkdir_p(query_dir)
  index = Dir.children(query_dir).count { |name| name.ends_with?(".sql") }
  stem = index.to_s.rjust(3, '0') + "-" + label
  sql_path = File.join(query_dir, "#{stem}.sql")
  stdout_path = File.join(query_dir, "#{stem}.stdout.txt")
  stderr_path = File.join(query_dir, "#{stem}.stderr.txt")
  status_path = File.join(query_dir, "#{stem}.status.txt")
  w144_write_new_text(sql_path, query + "\n")
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(binary, [
    "local",
    "--path", store,
    "--allow_suspicious_low_cardinality_types=1",
    "--query", query,
  ], output: stdout, error: stderr)
  w144_write_new_text(stdout_path, stdout.to_s)
  w144_write_new_text(stderr_path, stderr.to_s)
  code = status.exit_code || -1
  w144_write_new_text(status_path, "#{code}\n")
  W144CommandResult.new(stdout.to_s, stderr.to_s, code)
end

def w144_expect_query(binary : String, store : String, case_root : String, label : String, query : String, expected : String) : String
  result = w144_run_clickhouse(binary, store, case_root, label, query)
  w144_assert(result.success?, "ClickHouse query failed for #{label} (#{result.exit_code}): #{query}\n#{result.stderr}")
  actual = result.stdout.strip
  w144_assert(actual == expected, "ClickHouse #{label} output differs: expected #{expected.inspect}, got #{actual.inspect}")
  actual
end

def w144_create_table(binary : String, store : String, case_root : String, table : String, float_type : String) : Nil
  query = <<-SQL
  CREATE TABLE default.#{table}
  (
      `k` UInt64,
      `x` LowCardinality(#{float_type})
  )
  ENGINE = MergeTree
  ORDER BY k
  SETTINGS
      index_granularity = 4,
      index_granularity_bytes = 10485760,
      enable_mixed_granularity_parts = 1,
      min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0,
      default_compression_codec = 'LZ4',
      ratio_of_defaults_for_sparse_serialization = 1.0,
      compress_marks = 0,
      write_final_mark = 1,
      min_compress_block_size = 0,
      max_compress_block_size = 4096;
  SQL
  result = w144_run_clickhouse(binary, store, case_root, "create-#{table}", query)
  w144_assert(result.success?, "ClickHouse CREATE TABLE failed for #{table}: #{result.stderr}")
  nil
end

def w144_data_path(binary : String, store : String, case_root : String, table : String) : String
  query = "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw"
  result = w144_run_clickhouse(binary, store, case_root, "data-path-#{table}", query)
  w144_assert(result.success?, "ClickHouse table data path query failed for #{table}: #{result.stderr}")
  lines = result.stdout.lines.map(&.strip).reject(&.empty?)
  w144_assert(lines.size == 1, "#{table}: expected exactly one ClickHouse data path, got #{lines.size}")
  path = lines[0]
  w144_assert(path.starts_with?("/"), "#{table}: ClickHouse data path is not absolute: #{path}")
  canonical_store = File.expand_path(store)
  canonical_path = File.expand_path(path)
  w144_assert(path.rstrip('/') == canonical_path.rstrip('/'), "#{table}: ClickHouse data path is not canonical: #{path}")
  w144_assert(canonical_path.starts_with?(canonical_store.rstrip('/') + "/"), "#{table}: ClickHouse data path escapes its isolated store: #{path}")
  w144_assert_no_symlink_components(canonical_path)
  w144_assert(File.directory?(canonical_path), "#{table}: ClickHouse data path is not a directory: #{canonical_path}")
  canonical_path
end

def w144_attach_part(binary : String, store : String, case_root : String, table : String, part : String) : Nil
  data_path = w144_data_path(binary, store, case_root, table)
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  destination = File.join(detached, "all_1_1_0")
  w144_assert(!File.exists?(destination) && !File.symlink?(destination), "refusing to overwrite detached W144 part: #{destination}")
  FileUtils.cp_r(part, destination)
  w144_assert_no_symlinks(destination)
  query = "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'"
  result = w144_run_clickhouse(binary, store, case_root, "attach-#{table}", query)
  w144_assert(result.success?, "ClickHouse ATTACH PART failed for #{table}: #{result.stderr}")
  nil
end

def w144_verify_attached_table(binary : String, store : String, case_root : String, table : String, float_type : String) : Nil
  check = w144_expect_query(binary, store, case_root, "check-#{table}", "CHECK TABLE default.#{table} FORMAT TabSeparated", "all_1_1_0\t1")
  columns = "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
  w144_expect_query(binary, store, case_root, "columns-#{table}", columns, "k\tUInt64\nx\tLowCardinality(#{float_type})")
  w144_expect_query(binary, store, case_root, "rows-#{table}", "SELECT count(), min(k), max(k) FROM default.#{table} FORMAT TSVRaw", "12\t0\t11")
  nil
end

def w144_bit_function(float_type : String) : String
  case float_type
  when "Float32"  then "reinterpretAsUInt32"
  when "Float64"  then "reinterpretAsUInt64"
  when "BFloat16" then "reinterpretAsUInt16"
  else                 raise "unsupported W144 bit interpretation: #{float_type}"
  end
end

def w144_expected_bits(float_type : String, order_name : String, mutate : Bool, first_key : Int32, last_key : Int32) : String
  rows = w144_rows(float_type, order_name, mutate)
  Array(String).new(last_key - first_key + 1) do |key|
    raw = rows[key + first_key]
    "#{key + first_key}\t#{w144_le_decimal(raw)}"
  end.join("\n")
end

def w144_check_raw_queries(binary : String, store : String, case_root : String, table : String, float_type : String, order_name : String, mutate : Bool) : {String, String}
  bits = w144_bit_function(float_type)
  full_query = "SELECT k, #{bits}(x) FROM default.#{table} ORDER BY k FORMAT TabSeparatedRaw"
  middle_query = "SELECT k, #{bits}(x) FROM default.#{table} WHERE k BETWEEN 4 AND 7 ORDER BY k FORMAT TabSeparatedRaw"
  full_expected = w144_expected_bits(float_type, order_name, mutate, 0, 11)
  middle_expected = w144_expected_bits(float_type, order_name, mutate, 4, 7)
  full_actual = w144_expect_query(binary, store, case_root, "full-bits-#{table}", full_query, full_expected)
  middle_actual = w144_expect_query(binary, store, case_root, "middle-bits-#{table}", middle_query, middle_expected)
  {full_actual, middle_actual}
end

def w144_assert_seed_delta(float_type : String, order_name : String, base_rows : String, seeded_rows : String) : Nil
  base = base_rows.lines
  seeded = seeded_rows.lines
  w144_assert(base.size == 12 && seeded.size == 12, "#{float_type}/#{order_name}: seed sensitivity rows are incomplete")
  base_expected = w144_expected_bits(float_type, order_name, false, 0, 11).lines
  w144_assert(base == base_expected, "#{float_type}/#{order_name}: base control differs from the literal expectation")
  w144_assert(seeded != base_expected, "#{float_type}/#{order_name}: explicit seeded-vs-base comparator accepted the changed part")
  key_four_count = 0
  base.each_with_index do |line, index|
    if index == (w144_order(order_name).index(4) || -1)
      w144_assert(line != seeded[index], "#{float_type}/#{order_name}: valid-hash raw-bit seed did not change key 4 output")
      key_four_count += 1
    else
      w144_assert(line == seeded[index], "#{float_type}/#{order_name}: seed changed an unrelated key at row #{index}")
    end
  end
  w144_assert(key_four_count == 1, "#{float_type}/#{order_name}: seed did not select exactly one physical occurrence")
  nil
end

def w144_has_frame_checksum_diagnostic?(result : W144CommandResult) : Bool
  output = result.stdout + result.stderr
  output.includes?("CHECKSUM_DOESNT_MATCH") || output.includes?("Checksum doesn't match: corrupted data")
end

def w144_corrupt_frame_control(binary : String, store_root : String, case_root : String, raw_part : String, float_type : String, base_lanes : W144EncodedLanes) : Nil
  control_root = File.join(case_root, "frame-checksum-control")
  corrupt_part = File.join(control_root, "all_1_1_0")
  w144_assert(!File.exists?(control_root) && !File.symlink?(control_root), "refusing to overwrite frame-checksum control")
  FileUtils.mkdir_p(control_root)
  FileUtils.cp_r(raw_part, corrupt_part)
  w144_assert_no_symlinks(corrupt_part)

  index_path = w144_stream_path(corrupt_part, "x", "bin")
  original = File.read(index_path)
  w144_assert(original.bytesize > CrystalClick::CompressedBlock::CHECKSUM_SIZE, "frame control has no compressed payload")
  w144_assert(CrystalClick::CompressedBlock.decode_all(original.to_slice) == base_lanes.indexes_raw,
    "frame control source index lane differs from the W142 base payload")
  bytes = Bytes.new(original.bytesize) { |index| original.to_slice[index] }
  bytes[0] = bytes[0] ^ 1_u8
  w144_assert(bytes[CrystalClick::CompressedBlock::CHECKSUM_SIZE, bytes.size - CrystalClick::CompressedBlock::CHECKSUM_SIZE] ==
              original.to_slice[CrystalClick::CompressedBlock::CHECKSUM_SIZE, original.bytesize - CrystalClick::CompressedBlock::CHECKSUM_SIZE],
    "frame control changed compressed payload bytes in addition to the checksum")
  w144_replace_regular_file(index_path, bytes)
  index_file_name = File.basename(index_path)
  CrystalClick::WidePartWriter.w144_rebuild_checksums(corrupt_part, {index_file_name => base_lanes.indexes_raw})

  table = "w144_bad_frame_#{float_type.downcase}"
  store = File.join(store_root, "bad-frame")
  w144_create_table(binary, store, case_root, table, float_type)
  data_path = w144_data_path(binary, store, case_root, table)
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  destination = File.join(detached, "all_1_1_0")
  w144_assert(!File.exists?(destination) && !File.symlink?(destination), "refusing to overwrite detached frame-control part")
  FileUtils.cp_r(corrupt_part, destination)
  attach = w144_run_clickhouse(binary, store, case_root, "attach-bad-frame", "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  rejection_stage = ""
  if !attach.success?
    w144_assert(w144_has_frame_checksum_diagnostic?(attach),
      "frame-control ATTACH failed for an unrelated reason: #{attach.stderr}")
    rejection_stage = "ATTACH"
  else
    check = w144_run_clickhouse(binary, store, case_root, "check-bad-frame", "CHECK TABLE default.#{table} FORMAT TabSeparated")
    if w144_has_frame_checksum_diagnostic?(check)
      rejection_stage = "CHECK"
    else
      read = w144_run_clickhouse(binary, store, case_root, "read-bad-frame", "SELECT k, #{w144_bit_function(float_type)}(x) FROM default.#{table} ORDER BY k FORMAT TabSeparatedRaw")
      w144_assert(!read.success? && w144_has_frame_checksum_diagnostic?(read),
        "bad frame checksum was not rejected with the expected corruption diagnostic; CHECK=#{check.stdout.inspect} #{check.stderr.inspect}; READ=#{read.stdout.inspect} #{read.stderr.inspect}")
      rejection_stage = "READ"
    end
  end
  w144_write_new_text(File.join(control_root, "assertion.txt"), "bad index frame checksum with matching part-file hash was rejected at #{rejection_stage} with the expected checksum diagnostic\n")
  nil
end

def w144_process_case(binary : String, ingest_root : String, part_root : String, float_type : String, order_name : String, run_results : IO, combined_results : IO) : Nil
  label = "#{float_type.downcase}-order-#{order_name}"
  case_root = File.join(part_root, "cases", label)
  FileUtils.mkdir_p(case_root)
  template_source = File.join(ingest_root, "parts", label, "from-memory", "all_1_1_0")
  w144_validate_template(template_source, float_type, label)

  template = File.join(case_root, "template", "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(template))
  w144_assert(!File.exists?(template) && !File.symlink?(template), "refusing to overwrite retained template: #{template}")
  FileUtils.cp_r(template_source, template)
  w144_assert_no_symlinks(template)
  w144_validate_template(template, float_type, "retained #{label} template")

  store_root = File.join(case_root, "stores")
  template_table = "w144_template_#{label.gsub('-', '_')}"
  template_store = File.join(store_root, "template")
  w144_create_table(binary, template_store, case_root, template_table, float_type)
  w144_attach_part(binary, template_store, case_root, template_table, template)
  w144_verify_attached_table(binary, template_store, case_root, template_table, float_type)
  run_results << "#{label}\ttemplate\tCHECK TABLE, exact columns and 12 row keys\tPASS\n"

  raw_part = File.join(case_root, "persisted-raw", "all_1_1_0")
  base_evidence = File.join(case_root, "lanes", "base")
  replaced = w144_part_with_values(template, raw_part, float_type, order_name, false, base_evidence)
  w144_write_new_text(File.join(case_root, "replaced-files.tsv"), (replaced + ["checksums.txt"]).join("\n") + "\n")

  raw_table = "w144_raw_#{label.gsub('-', '_')}"
  raw_store = File.join(store_root, "raw")
  w144_create_table(binary, raw_store, case_root, raw_table, float_type)
  w144_attach_part(binary, raw_store, case_root, raw_table, raw_part)
  w144_verify_attached_table(binary, raw_store, case_root, raw_table, float_type)
  full_actual, middle_actual = w144_check_raw_queries(binary, raw_store, case_root, raw_table, float_type, order_name, false)
  combined_results << "#{label}\tbase-full\t#{full_actual.gsub('\n', ';')}\n"
  combined_results << "#{label}\tbase-middle\t#{middle_actual.gsub('\n', ';')}\n"
  run_results << "#{label}\tpersisted-raw\tATTACH, CHECK TABLE, exact full and k=4..7 raw bits\tPASS\n"

  seeded_part = File.join(case_root, "seeded-bit-change", "all_1_1_0")
  seeded_evidence = File.join(case_root, "lanes", "seeded-bit-change")
  w144_part_with_values(template, seeded_part, float_type, order_name, true, seeded_evidence)
  seeded_table = "w144_seed_#{label.gsub('-', '_')}"
  seeded_store = File.join(store_root, "seeded")
  w144_create_table(binary, seeded_store, case_root, seeded_table, float_type)
  w144_attach_part(binary, seeded_store, case_root, seeded_table, seeded_part)
  w144_verify_attached_table(binary, seeded_store, case_root, seeded_table, float_type)
  seed_full, seed_middle = w144_check_raw_queries(binary, seeded_store, case_root, seeded_table, float_type, order_name, true)
  w144_assert_seed_delta(float_type, order_name, full_actual, seed_full)
  combined_results << "#{label}\tseeded-full\t#{seed_full.gsub('\n', ';')}\n"
  combined_results << "#{label}\tseeded-middle\t#{seed_middle.gsub('\n', ';')}\n"
  run_results << "#{label}\tseeded-bit-change\tvalid rebuilt part hashes preserve changed raw bit at exactly one occurrence\tPASS\n"

  if label == "float32-order-a"
    lanes = w144_encode_lanes(float_type, order_name, false, File.join(case_root, "lanes", "frame-control-source"))
    w144_corrupt_frame_control(binary, store_root, case_root, raw_part, float_type, lanes)
    run_results << "#{label}\tframe-checksum-control\tcorrupt frame checksum with matching part hash is rejected\tPASS\n"
  end
  nil
end

ingest_root = ENV.fetch("W144_INGEST_ROOT")
part_root = ENV.fetch("W144_PART_ROOT")
binary = ENV.fetch("CLICKHOUSE_BIN")
w144_assert(ingest_root.starts_with?("/private/tmp/crystal-click-low-cardinality-float-w144."), "W144_INGEST_ROOT is outside the retained evidence namespace")
w144_assert(File.directory?(ingest_root) && !File.symlink?(ingest_root), "W144_INGEST_ROOT must be an existing real directory")
w144_assert(part_root.starts_with?("/private/tmp/crystal-click-low-cardinality-float-part-w144."), "W144_PART_ROOT is outside its isolated namespace")
w144_assert(!File.exists?(part_root) && !File.symlink?(part_root), "W144_PART_ROOT must be fresh; refusing overwrite")
w144_assert(File.file?(binary) && !File.symlink?(binary), "CLICKHOUSE_BIN is missing or a symlink")
w144_assert(ENV.fetch("CLICKHOUSE_SOURCE_REVISION", W144_SOURCE_REVISION) == W144_SOURCE_REVISION, "W144 source revision differs from the pinned source inventory")

Dir.mkdir(part_root)
w144_assert_no_symlinks(part_root)
results_dir = File.join(part_root, "results")
FileUtils.mkdir_p(results_dir)
run_path = File.join(results_dir, "run.txt")
run_results_path = File.join(results_dir, "assertions.tsv")
combined_results_path = File.join(results_dir, "raw-bits.tsv")
version_output = IO::Memory.new
version_error = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version_output, error: version_error)
w144_assert(version_status.success?, "cannot read pinned ClickHouse version: #{version_error}")
actual_version = version_output.to_s.strip
w144_assert(actual_version == W144_RUNTIME_VERSION, "W144 ClickHouse version differs from its pin: #{actual_version}")
runtime_sha256 = w144_sha256_file(binary)
w144_assert(runtime_sha256 == W144_RUNTIME_SHA256, "W144 ClickHouse executable SHA differs from its pin: #{runtime_sha256}")
w144_write_new_text(File.join(results_dir, "runtime-version.stdout.txt"), version_output.to_s)
w144_write_new_text(File.join(results_dir, "runtime-version.stderr.txt"), version_error.to_s)
w144_write_new_text(File.join(results_dir, "runtime-version.status.txt"), "#{version_status.exit_code || -1}\n")

build_store = File.join(part_root, "build-info-store")
FileUtils.mkdir_p(build_store)
build_options_query = "SELECT name, value FROM system.build_options ORDER BY name FORMAT TabSeparatedRaw"
build_options_result = w144_run_clickhouse(binary, build_store, results_dir, "build-options", build_options_query)
w144_assert(build_options_result.success?, "cannot read pinned ClickHouse build options: #{build_options_result.stderr}")
build_options = build_options_result.stdout
w144_assert(!build_options.strip.empty?, "ClickHouse build-options inventory is empty")
w144_write_new_text(File.join(results_dir, "build-options.tsv"), build_options)
build_identity_query = "SELECT version(), buildId() FORMAT TabSeparatedRaw"
build_identity_result = w144_run_clickhouse(binary, build_store, results_dir, "build-identity", build_identity_query)
w144_assert(build_identity_result.success?, "cannot record ClickHouse build identity: #{build_identity_result.stderr}")
build_identity = build_identity_result.stdout.strip
w144_assert(build_identity.lines.size == 1 && !build_identity.empty?, "ClickHouse build identity is not exactly one row")
w144_write_new_text(
  run_path,
  "source_revision\t#{W144_SOURCE_REVISION}\n" +
  "ingest_root\t#{ingest_root}\n" +
  "part_root\t#{part_root}\n" +
  "clickhouse_bin\t#{binary}\n" +
  "clickhouse_version\t#{actual_version}\n" +
  "clickhouse_executable_sha256\t#{runtime_sha256}\n" +
  "clickhouse_build_identity\t#{build_identity.gsub('\t', ' ')}\n" +
  "clickhouse_build_options_sha256\t#{Digest::SHA256.hexdigest(build_options)}\n" +
  "clickhouse_build_options_file\tresults/build-options.tsv\n" +
  "fixture\t12 rows; three 4-row marks; key UInt64 0..11; x LowCardinality(Float)\n" +
  "scope\tborrowed stock template; only x.dict/x data+marks and checksums rewritten\n" +
  "non_claim\tno library whole-part writer, Native passthrough, exhaustive type family, or performance claim\n"
)

File.open(run_results_path, "w") do |run_results|
  run_results << "case\tprobe\tassertion\tresult\n"
  File.open(combined_results_path, "w") do |combined_results|
    combined_results << "case\tprobe\tkey-bit-rows-semicolon-separated\n"
    {"Float32", "Float64", "BFloat16"}.each do |float_type|
      {"a", "b"}.each do |order_name|
        w144_process_case(binary, ingest_root, part_root, float_type, order_name, run_results, combined_results)
      end
    end
  end
end

puts "PASS W144 raw persisted LowCardinality(Float32/Float64/BFloat16) dictionary lanes: six ordered parts, stock template CHECKs, exact full/middle raw bits, seeded raw-bit sensitivity, and one frame-checksum control"
