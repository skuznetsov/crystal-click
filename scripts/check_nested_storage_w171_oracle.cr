require "digest/sha256"
require "file_utils"
require "json"
require "option_parser"
require "../src/crystal_click"

W171_ORACLE_VERSION          = "ClickHouse local version 26.10.1.1201 (official build)."
W171_ORACLE_BINARY_SHA256    = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W171_ORACLE_SOURCE_ROOT      = "/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1"
W171_ORACLE_SOURCE_REVISION  = "e9b645ed83ad3c07b64f09fbd014e8f770d8691b"
W171_ORACLE_TYPE             = "Nested(a UInt64, b String, c Nullable(Int32))"
W171_ORACLE_ARRAY_TUPLE_TYPE = "Array(Tuple(a UInt64, b String, c Nullable(Int32)))"
W171_ORACLE_KEYS             = [7_u64, 13_u64, 22_u64, 31_u64, 50_u64]
W171_ORACLE_SIZES            = [2_u64, 0_u64, 1_u64, 3_u64, 2_u64]
W171_ORACLE_STARTS           = [0, 2, 2, 3, 6]
W171_ORACLE_MARK_ROWS        = [2_u64, 2_u64, 1_u64, 0_u64]
W171_ORACLE_STREAMS          = [
  "pk", "nested.size0", "nested%2Ea", "nested%2Eb.size", "nested%2Eb",
  "nested%2Ec.null", "nested%2Ec",
]
W171_ORACLE_A          = [11_u64, 103_u64, 211_u64, 307_u64, 310_u64, 311_u64, 409_u64, 419_u64]
W171_ORACLE_B          = ["r0-A", "r0-B", "mid-x", "r3-A", "r3-B", "r3-C", "last-A", "last-B"]
W171_ORACLE_C          = [nil, -17_i32, 31_i32, 0_i32, 32_i32, nil, -41_i32, 41_i32] of Int32?
W171_ORACLE_C_PHYSICAL = [777_i32, -17_i32, 31_i32, 0_i32, 32_i32, -999_i32, -41_i32, 41_i32]
W171_ORACLE_C_STOCK    = [0_i32, -17_i32, 31_i32, 0_i32, 32_i32, 0_i32, -41_i32, 41_i32]
W171_ORACLE_SELECTIONS = {
  "full"             => {"", [0, 1, 2, 3, 4]},
  "middle"           => {" WHERE pk IN (22, 31)", [2, 3]},
  "empty_nested_row" => {" WHERE pk = 13", [1]},
  "no_rows"          => {" WHERE pk = 999", [] of Int32},
}

private def w171o_require(condition : Bool, message : String) : Nil
  raise "W171 Nested oracle: #{message}" unless condition
end

private def w171o_sha256(bytes : Bytes) : String
  Digest::SHA256.hexdigest(bytes)
end

private def w171o_sha256_file(path : String) : String
  w171o_sha256(File.read(path).to_slice)
end

private def w171o_write_u64(io : IO, value : UInt64) : Nil
  io.write_bytes(value, IO::ByteFormat::LittleEndian)
end

private def w171o_write_i32(io : IO, value : Int32) : Nil
  io.write_bytes(value, IO::ByteFormat::LittleEndian)
end

private def w171o_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w171o_write_string(io : IO, value : String) : Nil
  w171o_write_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

private def w171o_rowbinary(
  indexes : Array(Int32),
  type_name : String,
  with_names_and_types : Bool,
  a_values : Array(UInt64) = W171_ORACLE_A,
) : Bytes
  io = IO::Memory.new
  if with_names_and_types
    w171o_write_varuint(io, 2_u64)
    w171o_write_string(io, "pk")
    w171o_write_string(io, "nested")
    w171o_write_string(io, "UInt64")
    w171o_write_string(io, type_name)
  end
  indexes.each do |row_index|
    index = row_index.to_i
    w171o_write_u64(io, W171_ORACLE_KEYS[index])
    count = W171_ORACLE_SIZES[index].to_i
    w171o_write_varuint(io, count.to_u64)
    count.times do |element_index|
      leaf_index = W171_ORACLE_STARTS[index] + element_index
      w171o_write_u64(io, a_values[leaf_index])
      w171o_write_string(io, W171_ORACLE_B[leaf_index])
      if value = W171_ORACLE_C[leaf_index]
        io.write_byte(0_u8)
        w171o_write_i32(io, value)
      else
        io.write_byte(1_u8)
      end
    end
  end
  io.to_slice.dup
end

private def w171o_expected_raw(a_values : Array(UInt64), c_values : Array(Int32)) : Hash(String, Bytes)
  key_bytes = IO::Memory.new
  W171_ORACLE_KEYS.each { |value| w171o_write_u64(key_bytes, value) }
  outer_sizes = IO::Memory.new
  W171_ORACLE_SIZES.each { |value| w171o_write_u64(outer_sizes, value) }
  a_bytes = IO::Memory.new
  a_values.each { |value| w171o_write_u64(a_bytes, value) }
  b_sizes = IO::Memory.new
  b_bytes = IO::Memory.new
  W171_ORACLE_B.each do |value|
    w171o_write_u64(b_sizes, value.bytesize.to_u64)
    b_bytes.write(value.to_slice)
  end
  c_nulls = IO::Memory.new
  W171_ORACLE_C.each { |value| c_nulls.write_byte(value.nil? ? 1_u8 : 0_u8) }
  c_bytes = IO::Memory.new
  c_values.each { |value| w171o_write_i32(c_bytes, value) }
  {
    "pk"              => key_bytes.to_slice.dup,
    "nested.size0"    => outer_sizes.to_slice.dup,
    "nested%2Ea"      => a_bytes.to_slice.dup,
    "nested%2Eb.size" => b_sizes.to_slice.dup,
    "nested%2Eb"      => b_bytes.to_slice.dup,
    "nested%2Ec.null" => c_nulls.to_slice.dup,
    "nested%2Ec"      => c_bytes.to_slice.dup,
  }
end

private def w171o_stream_bytes(part : String, stream : String) : Bytes
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(path).to_slice
  encoded.empty? ? Bytes.new(0) : CrystalClick::CompressedBlock.decode_all(encoded)
end

private def w171o_u64_at(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w171o_mark_records(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  w171o_require(bytes.size == W171_ORACLE_MARK_ROWS.size * CrystalClick::WidePart::MARK_SIZE,
    "#{File.basename(part)} #{stream} mark file length differs")
  Array(Tuple(UInt64, UInt64, UInt64)).new(W171_ORACLE_MARK_ROWS.size) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w171o_u64_at(bytes, offset), w171o_u64_at(bytes, offset + 8), w171o_u64_at(bytes, offset + 16)}
  end
end

private def w171o_mark_raw_offsets : Hash(String, Array(UInt64))
  {
    "pk"              => [0_u64, 16_u64, 32_u64, 40_u64],
    "nested.size0"    => [0_u64, 16_u64, 32_u64, 40_u64],
    "nested%2Ea"      => [0_u64, 16_u64, 48_u64, 64_u64],
    "nested%2Eb.size" => [0_u64, 16_u64, 48_u64, 64_u64],
    "nested%2Eb"      => [0_u64, 8_u64, 25_u64, 37_u64],
    "nested%2Ec.null" => [0_u64, 2_u64, 6_u64, 8_u64],
    "nested%2Ec"      => [0_u64, 8_u64, 24_u64, 32_u64],
  }
end

private def w171o_assert_marks(part : String, raw : Hash(String, Bytes), stock : Bool) : Nil
  raw_offsets = w171o_mark_raw_offsets
  W171_ORACLE_STREAMS.each do |stream|
    records = w171o_mark_records(part, stream)
    w171o_require(records.map(&.[2]) == W171_ORACLE_MARK_ROWS,
      "#{File.basename(part)} #{stream} outer/child mark row axis differs: #{records.inspect}")
    if stock
      expected_offsets = raw_offsets[stream]
      w171o_require(records.map(&.[1]) == expected_offsets,
        "#{File.basename(part)} #{stream} decompressed mark axis differs: #{records.inspect}")
      w171o_require(records.all? { |record| record[0] == 0_u64 },
        "#{File.basename(part)} #{stream} stock marks no longer share one compressed block")
    else
      compressed_offsets = records.map(&.[0])
      w171o_require(compressed_offsets.first == 0_u64 && compressed_offsets.last ==
                                                         File.size(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_u64,
        "#{File.basename(part)} #{stream} writer compressed mark endpoints differ")
      w171o_require(compressed_offsets.each_cons(2).all? { |pair| pair[1] >= pair[0] },
        "#{File.basename(part)} #{stream} writer compressed offsets regress")
      w171o_require(records.all? { |record| record[1] == 0_u64 },
        "#{File.basename(part)} #{stream} writer marks should address independent compressed frames")
    end
  end
end

private def w171o_expected_file_names(stock : Bool) : Array(String)
  names = [
    "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
    "default_compression_codec.txt", "metadata_version.txt",
    "primary.idx", "serialization.json",
  ] of String
  names << "statistics.packed" if stock
  W171_ORACLE_STREAMS.each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    names << "#{base}.bin" << "#{base}.mrk2"
  end
  names.sort
end

private def w171o_assert_part(
  part : String,
  type_name : String,
  raw : Hash(String, Bytes),
  stock : Bool,
) : Nil
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`nested` #{type_name}\n"
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "6 substreams for column `nested`:\n" +
                        W171_ORACLE_STREAMS[1..].map { |stream| "\t#{stream}\n" }.join
  w171o_require(File.read(File.join(part, "columns.txt")) == expected_columns,
    "#{File.basename(part)} exact columns metadata differs")
  w171o_require(File.read(File.join(part, "columns_substreams.txt")) == expected_substreams,
    "#{File.basename(part)} exact substream names/order differs")
  expected_serialization = if stock
                             %({"columns":[{"kind":"Default","name":"pk","num_defaults":0,"num_rows":5,"exact_num_defaults":true}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
                           else
                             %({"columns":[{"kind":"Default","name":"pk","num_defaults":0,"num_rows":5,"exact_num_defaults":true}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
                           end
  w171o_require(File.read(File.join(part, "serialization.json")) == expected_serialization,
    "#{File.basename(part)} serialization metadata differs")
  w171o_require(File.read(File.join(part, "count.txt")) == "5", "#{File.basename(part)} count differs")
  w171o_require(File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)",
    "#{File.basename(part)} compression codec differs")
  w171o_require(File.read(File.join(part, "metadata_version.txt")) == "0",
    "#{File.basename(part)} metadata version differs")

  expected_names = w171o_expected_file_names(stock)
  actual_names = Dir.children(part).sort
  w171o_require(actual_names == expected_names,
    "#{File.basename(part)} exact file roster differs (missing=#{(expected_names - actual_names).inspect}, extra=#{(actual_names - expected_names).inspect})")
  actual_names.each do |name|
    path = File.join(part, name)
    w171o_require(!File.symlink?(path) && File.file?(path), "#{File.basename(part)} roster entry is not a regular file: #{name}")
  end

  checksums = CrystalClick::PartChecksums.open(part)
  W171_ORACLE_STREAMS.each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    {"#{base}.bin", "#{base}.mrk2"}.each do |name|
      w171o_require(checksums.entry(name) != nil, "#{File.basename(part)} checksum entry is missing: #{name}")
    end
  end
  {"count.txt", "primary.idx", "serialization.json"}.each do |name|
    w171o_require(checksums.entry(name) != nil, "#{File.basename(part)} checksum entry is missing: #{name}")
  end
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }

  raw.each do |stream, expected|
    observed = w171o_stream_bytes(part, stream)
    w171o_require(observed == expected,
      "#{File.basename(part)} #{stream} literal bytes differ (expected #{expected.size}, observed #{observed.size})")
  end
  w171o_assert_marks(part, raw, stock)
end

private def w171o_assert_public_reader(part : String) : Nil
  reader = CrystalClick::WidePart.open_typed(part, "nested")
  data = reader.read_nested_mark_range("nested", 0, reader.mark_count)
  w171o_require(data.type_name == W171_ORACLE_TYPE, "public Nested reader lost the exact nominal type")
  w171o_require(data.row_count == 5 && data.element_count == 8, "public Nested reader row/element counts differ")
  w171o_require(data.row_sizes == W171_ORACLE_SIZES, "public Nested reader outer offsets differ")
  w171o_require(data.offsets == [0_u64, 2_u64, 2_u64, 3_u64, 6_u64, 8_u64],
    "public Nested reader prefix offsets differ")
  cursor = 0
  data.row_sizes.each_with_index do |size, row_index|
    row = data.row(row_index)
    w171o_require(row.size == size.to_i32, "public Nested reader row #{row_index} size differs")
    size.to_i.times do |element_index|
      element = row[element_index]
      flat_index = cursor + element_index
      w171o_require(element.value_as("a", UInt64) == W171_ORACLE_A[flat_index],
        "public Nested reader UInt64 leaf differs at #{flat_index}")
      w171o_require(element.value_as("b", String) == W171_ORACLE_B[flat_index],
        "public Nested reader String leaf differs at #{flat_index}")
      if value = W171_ORACLE_C[flat_index]
        w171o_require(element.value_as("c", Int32) == value, "public Nested reader nullable Int32 differs at #{flat_index}")
      else
        w171o_require(element["c"].nil?, "public Nested reader NULL differs at #{flat_index}")
      end
    end
    cursor += size.to_i
  end
  middle = reader.read_nested_mark_range("nested", 1, 1)
  w171o_require(middle.row_sizes == [1_u64, 3_u64] &&
                middle.row(1)[2].value_as("a", UInt64) == 311_u64,
    "public Nested reader middle mark differs")
  nil
end

private def w171o_profile(profiles : Array(JSON::Any), label : String) : JSON::Any
  profiles.find { |profile| profile["label"].as_s == label } || raise "source profile missing: #{label}"
end

private def w171o_assert_source_profile_roster(profile : JSON::Any, run_root : String) : String
  part = profile["part_path"].as_s
  expanded_run = File.expand_path(run_root)
  expanded_part = File.expand_path(part)
  w171o_require(expanded_part.starts_with?(expanded_run + File::SEPARATOR),
    "source profile part escaped its captured run root")
  w171o_require(Dir.exists?(part) && !File.symlink?(part), "source profile part is missing or symlinked")
  expected_roster = profile["part_roster"].as_a
  actual_names = Dir.children(part).sort
  captured_names = expected_roster.map { |entry| entry["name"].as_s }.sort
  w171o_require(actual_names == captured_names, "source profile part roster changed since capture")
  expected_roster.each do |entry|
    name = entry["name"].as_s
    path = File.join(part, name)
    w171o_require(entry["kind"].as_s == "file" && !File.symlink?(path) && File.file?(path),
      "source profile roster entry is not a regular file: #{name}")
    w171o_require(File.size(path).to_i64 == entry["size"].as_i64, "source profile file size changed: #{name}")
    w171o_require(w171o_sha256_file(path) == entry["sha256"].as_s, "source profile file hash changed: #{name}")
  end
  part
end

private def w171o_validate_source_manifest(path : String) : Tuple(String, String, String, String)
  w171o_require(File.file?(path) && !File.symlink?(path), "source manifest is missing or symlinked")
  manifest = JSON.parse(File.read(path))
  w171o_require(manifest["clickhouse_binary_sha256_before"].as_s == W171_ORACLE_BINARY_SHA256 &&
                manifest["clickhouse_binary_sha256_after"].as_s == W171_ORACLE_BINARY_SHA256,
    "source manifest is not pinned to the expected 26.10 runtime SHA")
  w171o_require(manifest["observed_clickhouse_version"].as_s == W171_ORACLE_VERSION &&
                manifest["expected_clickhouse_version"].as_s == W171_ORACLE_VERSION,
    "source manifest version differs")
  w171o_require(manifest["source_root"].as_s == W171_ORACLE_SOURCE_ROOT &&
                manifest["source_label"].as_s == W171_ORACLE_SOURCE_REVISION,
    "source manifest source checkout/revision differs")
  run_root = manifest["run_root"].as_s
  commands = manifest["commands"].as_a
  w171o_require(commands.size == 40, "source runner command count differs")
  commands.each do |command|
    label = command["label"].as_s
    status = command["status"]
    w171o_require(status["success"].as_bool && status["exitstatus"].as_i == 0,
      "captured stock command failed: #{label}")
    argv = command["argv"]
    w171o_require(argv.as_a.first.as_s == manifest["clickhouse_binary"].as_s,
      "captured stock command executable differs: #{label}")
    files = command["files"]
    hashes = command["sha256"]
    {"stdout", "stderr"}.each do |kind|
      file = files[kind].as_s
      w171o_require(File.expand_path(file).starts_with?(File.expand_path(run_root) + File::SEPARATOR),
        "captured stock command output escaped its run root: #{label} #{kind}")
      w171o_require(File.file?(file) && !File.symlink?(file), "captured stock command output is missing: #{label} #{kind}")
      w171o_require(w171o_sha256_file(file) == hashes[kind].as_s, "captured stock command output hash changed: #{label} #{kind}")
    end
    sql_path = files["sql"]
    unless sql_path.raw.nil?
      sql_file = sql_path.as_s
      w171o_require(File.expand_path(sql_file).starts_with?(File.expand_path(run_root) + File::SEPARATOR),
        "captured stock SQL escaped its run root: #{label}")
      sql = command["sql"].as_s
      w171o_require(File.file?(sql_file) && !File.symlink?(sql_file) && File.read(sql_file) == sql,
        "captured stock SQL differs: #{label}")
      w171o_require(w171o_sha256(sql.to_slice) == hashes["sql"].as_s, "captured stock SQL hash changed: #{label}")
    else
      w171o_require(command["sql"].raw.nil? && hashes["sql"].raw.nil?, "captured non-SQL command has SQL metadata")
    end
  end

  profiles = manifest["profiles"].as_a
  labels = profiles.map { |profile| profile["label"].as_s }.sort
  w171o_require(labels == ["array-tuple-flat0", "nested-flat0", "nested-flat1"], "stock source profile set differs")
  nested_flat0 = w171o_profile(profiles, "nested-flat0")
  nested_flat1 = w171o_profile(profiles, "nested-flat1")
  array_control = w171o_profile(profiles, "array-tuple-flat0")
  w171o_require(nested_flat0["setting_flatten_nested"].as_i == 0 && nested_flat1["setting_flatten_nested"].as_i == 1,
    "stock Nested flatten_nested settings differ")
  w171o_require(nested_flat0["declared_type"].as_s == W171_ORACLE_TYPE &&
                nested_flat1["declared_type"].as_s == W171_ORACLE_TYPE &&
                array_control["declared_type"].as_s == W171_ORACLE_ARRAY_TUPLE_TYPE,
    "stock source declarations differ")
  nested_path = w171o_assert_source_profile_roster(nested_flat0, run_root)
  w171o_assert_source_profile_roster(nested_flat1, run_root)
  tuple_path = w171o_assert_source_profile_roster(array_control, run_root)

  stock_raw = w171o_expected_raw(W171_ORACLE_A, W171_ORACLE_C_STOCK)
  w171o_assert_part(nested_path, W171_ORACLE_TYPE, stock_raw, true)
  w171o_assert_public_reader(nested_path)
  tuple_raw = w171o_expected_raw(W171_ORACLE_A, W171_ORACLE_C_STOCK)
  w171o_assert_part(tuple_path, W171_ORACLE_ARRAY_TUPLE_TYPE, tuple_raw, true)
  W171_ORACLE_STREAMS.each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    {".bin", ".mrk2"}.each do |suffix|
      w171o_require(File.read(File.join(nested_path, base + suffix)) == File.read(File.join(tuple_path, base + suffix)),
        "Nested and Array(Tuple) source bytes differ for #{stream}#{suffix}")
    end
  end
  flat1_size_stream = CrystalClick::StreamName.hash("nested.size0")
  w171o_require(
    File.read(File.join(nested_path, "#{flat1_size_stream}.bin")) == File.read(File.join(w171o_assert_source_profile_roster(nested_flat1, run_root), "#{flat1_size_stream}.bin")),
    "flatten_nested=1 sibling offset buffer is not shared with Nested.size0"
  )

  commands.each do |command|
    label = command["label"].as_s
    next unless {"nested-flat0", "array-tuple-flat0"}.any? { |prefix| label.starts_with?("#{prefix}-select-") }
    profile_label = label.starts_with?("nested-flat0-") ? "nested-flat0" : "array-tuple-flat0"
    selection_and_format = label.lchop("#{profile_label}-select-")
    selected_name, format_name = selection_and_format.split("-rowbinary", 2)
    selection = W171_ORACLE_SELECTIONS[selected_name]? || raise "unknown source selection #{label}"
    with_header = format_name == "withnamesandtypes"
    w171o_require(with_header || format_name == "", "unknown source format #{label}")
    type = profile_label == "nested-flat0" ? W171_ORACLE_TYPE : W171_ORACLE_ARRAY_TUPLE_TYPE
    expected = w171o_rowbinary(selection[1], type, with_header)
    output_path = command["files"]["stdout"].as_s
    w171o_require(File.read(output_path).to_slice == expected, "captured stock RowBinary differs from literal: #{label}")
  end
  {manifest["clickhouse_binary"].as_s, nested_path, run_root, path}
end

private class W171OracleCapture
  getter root : String
  getter binary : String
  getter command_record_paths = [] of String

  def initialize(@root : String, @binary : String)
    @command_dir = File.join(root, "commands")
    Dir.mkdir(@command_dir)
  end

  def run(label : String, argv : Array(String), sql : String? = nil) : Bytes
    index = command_record_paths.size + 1
    safe_label = label.gsub(/[^A-Za-z0-9_.-]/, "_")
    base = File.join(@command_dir, "#{index.to_s.rjust(3, '0')}-#{safe_label}")
    sql_path = sql ? base + ".sql" : nil
    stdout_path = base + ".stdout"
    stderr_path = base + ".stderr"
    File.write(sql_path.not_nil!, sql.not_nil!) if sql
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(argv[0], argv[1..], output: stdout, error: stderr)
    stdout_bytes = stdout.to_slice.dup
    stderr_bytes = stderr.to_slice.dup
    File.open(stdout_path, "wb") { |file| file.write(stdout_bytes) }
    File.open(stderr_path, "wb") { |file| file.write(stderr_bytes) }
    record_path = base + ".json"
    File.write(record_path, JSON.build do |json|
      json.object do
        json.field "label", label
        json.field "argv", argv
        json.field "sql", sql
        json.field "status" do
          json.object do
            json.field "exit_code", status.exit_code
            json.field "success", status.success?
          end
        end
        json.field "files" do
          json.object do
            json.field "sql", sql_path
            json.field "stdout", stdout_path
            json.field "stderr", stderr_path
          end
        end
        json.field "sha256" do
          json.object do
            json.field "sql", sql ? w171o_sha256(sql.to_slice) : nil
            json.field "stdout", w171o_sha256(stdout_bytes)
            json.field "stderr", w171o_sha256(stderr_bytes)
          end
        end
      end
    end)
    command_record_paths << record_path
    unless status.success?
      raise "native ClickHouse command #{label} failed (#{status.exit_code}): #{String.new(stderr_bytes)}"
    end
    stdout_bytes
  end

  def sql(label : String, store : String, statement : String) : Bytes
    query = "SET flatten_nested = 0;\n#{statement}"
    argv = [binary, "local", "--path", store, "--multiquery", "--max_threads=1", "--query", query] of String
    run(label, argv, query)
  end

  def write_manifest(source_manifest : String, source_nested_part : String, writer_part : String,
                     mutant_part : String, binary_sha_before : String, binary_sha_after : String) : Nil
    File.write(File.join(root, "manifest.json"), JSON.build do |json|
      json.object do
        json.field "oracle", "W171 stock and independently authored Nested complete-part oracle"
        json.field "clickhouse_binary", binary
        json.field "clickhouse_binary_sha256_before", binary_sha_before
        json.field "clickhouse_binary_sha256_after", binary_sha_after
        json.field "expected_clickhouse_version", W171_ORACLE_VERSION
        json.field "source_manifest", source_manifest
        json.field "source_nested_part", source_nested_part
        json.field "independent_writer_part", writer_part
        json.field "same_shape_value_mutant_part", mutant_part
        json.field "command_record_paths", command_record_paths
      end
    end)
  end
end

private def w171o_parse_options : Tuple(String, String, String)
  clickhouse = ENV["CLICKHOUSE_BIN"]? || "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped"
  source_manifest = ENV["W171_SOURCE_MANIFEST"]? || ""
  workdir = ENV["W171_ORACLE_WORKDIR"]? || ""
  parser = OptionParser.new do |options|
    options.banner = "Usage: crystal scripts/check_nested_storage_w171_oracle.cr -- --clickhouse PATH --source-manifest PATH --workdir DIR"
    options.on("--clickhouse PATH", "Pinned ClickHouse local executable") { |value| clickhouse = value }
    options.on("--source-manifest PATH", "Retained source-law capture manifest") { |value| source_manifest = value }
    options.on("--workdir DIR", "Existing scratch parent; a fresh child is retained") { |value| workdir = value }
  end
  parser.parse
  w171o_require(ARGV.empty?, "unexpected arguments: #{ARGV.inspect}")
  w171o_require(!source_manifest.empty?, "--source-manifest is required")
  w171o_require(!workdir.empty?, "--workdir is required")
  {File.realpath(clickhouse), File.realpath(source_manifest), File.realpath(workdir)}
end

private def w171o_create_table(capture : W171OracleCapture, store : String, table : String) : Nil
  sql = <<-SQL
  CREATE TABLE default.#{table}
  (
      `pk` UInt64,
      `nested` #{W171_ORACLE_TYPE}
  ) ENGINE = MergeTree ORDER BY pk
  SETTINGS index_granularity = 2, index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 0.9375,
    compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0,
    max_compress_block_size = 4096, default_compression_codec = 'LZ4';
  SQL
  capture.sql("create-#{table}", store, sql)
end

private def w171o_attach_part(
  capture : W171OracleCapture,
  store : String,
  table : String,
  part : String,
  a_values : Array(UInt64) = W171_ORACLE_A,
) : Nil
  path_bytes = capture.sql("data-path-#{table}", store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw")
  data_path = String.new(path_bytes).strip
  w171o_require(!data_path.empty? && !data_path.includes?('\n'), "#{table} stock data path is invalid")
  w171o_require(File.expand_path(data_path).starts_with?(File.expand_path(store) + File::SEPARATOR) &&
                Dir.exists?(data_path) && !File.symlink?(data_path),
    "#{table} stock data path escaped the isolated native store")
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  destination = File.join(detached, "all_1_1_0")
  w171o_require(!Dir.exists?(destination) && !File.symlink?(destination), "refusing to overwrite detached part")
  FileUtils.cp_r(part, destination)
  capture.sql("attach-#{table}", store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  checked = String.new(capture.sql("check-#{table}", store, "CHECK TABLE default.#{table} FORMAT TabSeparated")).strip
  w171o_require(checked == "all_1_1_0\t1", "#{table} ATTACH/CHECK rejected complete part: #{checked.inspect}")
  columns = String.new(capture.sql("columns-#{table}", store,
    "SELECT name || ' ' || type FROM system.columns WHERE database = 'default' AND table = '#{table}' ORDER BY position FORMAT TSVRaw"))
  expected_columns = "pk UInt64\nnested #{W171_ORACLE_TYPE}\n"
  w171o_require(columns == expected_columns, "#{table} post-ATTACH nominal columns metadata differs: #{columns.inspect}")
  W171_ORACLE_SELECTIONS.each do |selection_name, selection|
    [false, true].each do |with_header|
      format_name = with_header ? "RowBinaryWithNamesAndTypes" : "RowBinary"
      sql = "SELECT pk, nested FROM default.#{table}#{selection[0]} ORDER BY pk FORMAT #{format_name}"
      actual = capture.sql("select-#{table}-#{selection_name}-#{format_name.downcase}", store, sql)
      expected = w171o_rowbinary(selection[1], W171_ORACLE_TYPE, with_header, a_values)
      w171o_require(actual == expected,
        "#{table} #{selection_name} #{format_name} differs from independent literal (actual #{actual.size}, expected #{expected.size})")
    end
  end
  nil
end

private def w171o_write_library_part(parent : String, label : String, a_values : Array(UInt64)) : String
  destination = File.join(parent, label)
  columns = [
    CrystalClick::WideTupleLeafColumn.new("a", a_values),
    CrystalClick::WideTupleLeafColumn.new("b", W171_ORACLE_B),
    CrystalClick::WideTupleLeafColumn.new(
      "c",
      CrystalClick::WideTupleLeafType.parse("Nullable(Int32)").not_nil!,
      W171_ORACLE_C_PHYSICAL,
      CrystalClick::ScalarNullMap.new(Bytes[1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0_u8, 0_u8], 8_u64)
    ),
  ] of CrystalClick::WideTupleLeafColumn
  CrystalClick::WidePartWriter.write_uint64_nested_part(
    destination,
    "pk",
    W171_ORACLE_KEYS.to_unsafe.to_slice(W171_ORACLE_KEYS.size),
    "nested",
    W171_ORACLE_TYPE,
    W171_ORACLE_SIZES.to_unsafe.to_slice(W171_ORACLE_SIZES.size),
    columns,
    2
  )
end

private def w171o_assert_query_mutant(capture : W171OracleCapture, store : String, table : String) : Nil
  query = "SELECT pk, nested FROM default.#{table} ORDER BY pk FORMAT RowBinaryWithNamesAndTypes"
  actual = capture.sql("select-#{table}-full-rowbinarywithnamesandtypes", store, query)
  expected_mutant = w171o_rowbinary([0, 1, 2, 3, 4], W171_ORACLE_TYPE, true, [12_u64, 103_u64, 211_u64, 307_u64, 310_u64, 311_u64, 409_u64, 419_u64])
  expected_base = w171o_rowbinary([0, 1, 2, 3, 4], W171_ORACLE_TYPE, true)
  w171o_require(actual == expected_mutant, "stock-accepted same-shape value mutant differs from its independent mutant literal")
  w171o_require(actual != expected_base, "same-shape semantic mutant escaped the unchanged independent literal oracle")
end

private def w171o_run : Nil
  clickhouse, source_manifest, workdir = w171o_parse_options
  w171o_require(File.file?(clickhouse) && File::Info.executable?(clickhouse) && !File.symlink?(clickhouse),
    "ClickHouse binary is missing, non-executable, or symlinked")
  w171o_require(Dir.exists?(workdir) && !File.symlink?(workdir), "workdir is missing or symlinked")
  w171o_require(File.realpath(workdir) == File.expand_path(workdir), "workdir is not canonical")
  binary_sha_before = w171o_sha256_file(clickhouse)
  w171o_require(binary_sha_before == W171_ORACLE_BINARY_SHA256, "ClickHouse binary SHA differs before native oracle")
  binary, source_nested_part, _source_run, source_manifest = w171o_validate_source_manifest(source_manifest)
  w171o_require(File.realpath(binary) == clickhouse, "source manifest binary path differs from requested executable")

  run_root = File.join(workdir, "nested-storage-w171-oracle-#{Time.utc.to_unix}-#{Process.pid}")
  Dir.mkdir(run_root)
  capture = W171OracleCapture.new(run_root, clickhouse)
  begin
    version = String.new(capture.run("runtime-version", [clickhouse, "local", "--version"])).strip
    w171o_require(version == W171_ORACLE_VERSION, "native runtime version differs: #{version.inspect}")
    store = File.join(run_root, "native-store")
    FileUtils.mkdir_p(store)
    parts = File.join(run_root, "library-parts")
    Dir.mkdir(parts)

    writer_part = w171o_write_library_part(parts, "nested-base", W171_ORACLE_A)
    writer_raw = w171o_expected_raw(W171_ORACLE_A, W171_ORACLE_C_PHYSICAL)
    w171o_assert_part(writer_part, W171_ORACLE_TYPE, writer_raw, false)
    w171o_assert_public_reader(writer_part)
    mutant_a = W171_ORACLE_A.dup
    mutant_a[0] = 12_u64
    mutant_part = w171o_write_library_part(parts, "nested-value-mutant", mutant_a)
    mutant_raw = w171o_expected_raw(mutant_a, W171_ORACLE_C_PHYSICAL)
    w171o_assert_part(mutant_part, W171_ORACLE_TYPE, mutant_raw, false)

    {
      {"w171_stock_nested", source_nested_part, W171_ORACLE_A},
      {"w171_library_nested", writer_part, W171_ORACLE_A},
      {"w171_library_value_mutant", mutant_part, mutant_a},
    }.each do |table, part, a_values|
      w171o_create_table(capture, store, table)
      w171o_attach_part(capture, store, table, part, a_values)
    end
    w171o_assert_query_mutant(capture, store, "w171_library_value_mutant")

    binary_sha_after = w171o_sha256_file(clickhouse)
    w171o_require(binary_sha_after == W171_ORACLE_BINARY_SHA256, "ClickHouse binary SHA changed during native oracle")
    capture.write_manifest(source_manifest, source_nested_part, writer_part, mutant_part, binary_sha_before, binary_sha_after)
    puts "PASS W171 Nested stock/library complete-part oracle: ATTACH/CHECK, exact part profile, literal RowBinary, value-mutant sensitivity"
    puts "W171 oracle evidence retained at #{run_root}"
    puts "commands=#{capture.command_record_paths.size} binary_sha256=#{binary_sha_after}"
  rescue ex
    binary_sha_after = w171o_sha256_file(clickhouse)
    capture.write_manifest(source_manifest, source_nested_part, File.join(run_root, "library-parts/nested-base"),
      File.join(run_root, "library-parts/nested-value-mutant"), binary_sha_before, binary_sha_after)
    raise ex
  end
end

w171o_run
