# W115 JSON stock capture. Physical bytes are observations, not a production
# qualification oracle; normalized documents have separate literal expectations.
require "file_utils"
require "../src/crystal_click"
require "./w115_json_semantic_vectors"

W115_VERSION           = "26.10.1.1201"
W115_BUILD_HASH        = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W115_EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W115_PROFILES          = [
  {"dynamic_paths", "JSON(max_dynamic_paths=16, max_dynamic_types=8)"},
  {"dynamic_shared_only", "JSON(max_dynamic_paths=0, max_dynamic_types=8)"},
  {"typed_mixed", "JSON(a UInt64, max_dynamic_paths=1, max_dynamic_types=1)"},
]
W115_SETTINGS = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version_for_zero_level_parts='map'"
W115_ROWS     = [
  %({"pk":1,"payload":{"a":10,"s":"alpha","flag":true,"arr":[1,2],"nest":{"leaf":"one"},"dot.key":101}}),
  %({"pk":2,"payload":{"a":null,"s":"","flag":false,"arr":[],"nest":{"leaf":"two"},"dot.key":102}}),
  %({"pk":3,"payload":{"a":3,"s":"a\\u0000b","flag":null,"arr":[3],"nest":{"leaf":null},"dot.key":103}}),
  %({"pk":4,"payload":{}}),
  %({"pk":5,"payload":{"a":5,"s":42,"flag":true,"arr":[4,5],"nest":{"leaf":"five"},"dot.key":105}}),
  %({"pk":6,"payload":{"a":6,"s":null,"flag":false,"arr":null,"nest":{},"dot.key":106}}),
  %({"pk":7,"payload":{"a":7,"s":"last","flag":null,"arr":[6],"nest":{"leaf":"end"},"dot.key":107}}),
  %({"pk":8,"payload":{"a":8,"s":true,"flag":true,"arr":[7],"nest":{"leaf":""},"dot.key":108}}),
]

class W115CaptureMismatch < Exception
end

def w115_fail(message : String) : NoReturn
  raise W115CaptureMismatch.new(message)
end

def w115_require(condition : Bool, message : String) : Nil
  w115_fail(message) unless condition
end

def w115_run(binary : String, store : String, query : String, input : IO? = nil) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = if input
             Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  raise "ClickHouse command failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w115_assert_check(actual : String, part_name : String, label : String) : Nil
  expected = "#{part_name}\t1\t\n"
  w115_fail("#{label}: CHECK record mismatch") unless actual == expected
end

def w115_check_comparator_controls(part_name : String) : Nil
  ["#{part_name}\t0\t\n", "wrong_part\t1\t\n"].each_with_index do |seed, index|
    begin
      w115_assert_check(seed, part_name, "seeded CHECK comparator control #{index}")
    rescue error : W115CaptureMismatch
      w115_require(error.message == "seeded CHECK comparator control #{index}: CHECK record mismatch", "CHECK control failed for an unexpected reason: #{error.message}")
      puts "capture comparator control rejected seeded CHECK row #{seed.inspect}"
      next
    end
    w115_fail("CHECK comparator accepted seeded bad row #{seed.inspect}")
  end
end

def w115_assert_same(actual : String, expected : String, label : String) : Nil
  w115_fail("#{label}: snapshot differs (#{actual.bytesize} vs #{expected.bytesize} bytes)") unless actual == expected
end

def w115_expect_snapshot_mismatch(actual : String, expected : String, label : String) : Nil
  begin
    w115_assert_same(actual, expected, label)
  rescue error : W115CaptureMismatch
    expected_message = "#{label}: snapshot differs (#{actual.bytesize} vs #{expected.bytesize} bytes)"
    w115_require(error.message == expected_message, "snapshot control failed for an unexpected reason: #{error.message}")
    puts "capture comparator control rejected changed #{label} snapshot"
    return
  end
  w115_fail("#{label}: corrupted snapshot was accepted")
end

def w115_require_store_child(path : String, store : String, label : String) : String
  real_path = File.realpath(path)
  real_store = File.realpath(store)
  w115_require(real_path.starts_with?(real_store + "/") && !File.symlink?(path), "#{label}: path is not a safe child of the isolated store")
  real_path
end

def w115_u64le(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def w115_capture_part(part : String, label : String) : Nil
  w115_require(Dir.exists?(part) && !File.symlink?(part), "#{label}: unsafe/missing part directory #{part}")
  files = Dir.children(part).sort
  puts "#{label} part=#{part}"
  puts "#{label} inventory name<TAB>size_bytes:"
  files.each do |name|
    path = File.join(part, name)
    puts "#{name}\t#{File.size(path)}" if File.file?(path)
  end
  {"columns.txt", "columns_substreams.txt", "serialization.json"}.each do |name|
    path = File.join(part, name)
    puts "#{label} #{name} observed:"
    if File.file?(path)
      contents = File.read(path)
      print contents
      puts unless contents.ends_with?('\n')
    else
      puts "<absent>"
    end
  end
  {"checksums.txt", "statistics.packed", "primary.idx"}.each do |name|
    path = File.join(part, name)
    if File.file?(path)
      bytes = File.read(path).to_slice
      puts "#{label} #{name} hex (#{bytes.size} bytes): #{bytes.hexstring}"
    end
  end
  nonempty_pk_marks = 0
  files.each do |name|
    path = File.join(part, name)
    next unless File.file?(path)
    bytes = File.read(path).to_slice
    if name.ends_with?(".bin")
      raw = bytes.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(bytes)
      puts "#{label} stream #{name} raw_hex (#{raw.size} bytes): #{raw.hexstring}"
    elsif name.ends_with?(".mrk2")
      w115_require(bytes.size % 24 == 0, "#{label}: malformed .mrk2 size for #{name}")
      rows = [] of String
      offset = 0
      while offset < bytes.size
        row = w115_u64le(bytes, offset + 16)
        rows << "{#{w115_u64le(bytes, offset)},#{w115_u64le(bytes, offset + 8)},#{row}}"
        nonempty_pk_marks += 1 if name == "#{CrystalClick::StreamName.hash("pk")}.mrk2" && row > 0
        offset += 24
      end
      puts "#{label} marks #{name}: #{rows.join(",")}"
    end
  end
  w115_require(nonempty_pk_marks >= 3, "#{label}: expected at least three nonempty primary-key mark rows, got #{nonempty_pk_marks}")
end

def w115_query_snapshots(binary : String, store : String, table : String, label : String) : Hash(String, String)
  outputs = {} of String => String
  {
    "documents_full"                 => "SELECT pk, toJSONString(payload) FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw",
    "documents_selected"             => "SELECT pk, toJSONString(payload) FROM default.#{table} WHERE pk >= 3 AND pk < 7 ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw",
    "path_types_full"                => "SELECT pk, JSONDynamicPathsWithTypes(payload), JSONSharedDataPathsWithTypes(payload), dynamicType(payload.s), isDynamicElementInSharedData(payload.s) FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT JSONEachRow",
    "path_types_selected"            => "SELECT pk, JSONDynamicPathsWithTypes(payload), JSONSharedDataPathsWithTypes(payload), dynamicType(payload.s), isDynamicElementInSharedData(payload.s) FROM default.#{table} WHERE pk >= 3 AND pk < 7 ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT JSONEachRow",
    "rowbinary_full"                 => "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary",
    "rowbinary_selected"             => "SELECT pk, payload FROM default.#{table} WHERE pk >= 3 AND pk < 7 ORDER BY pk FORMAT RowBinary",
    "rowbinary_json_string_full"     => "SELECT pk, payload FROM default.#{table} ORDER BY pk SETTINGS output_format_binary_write_json_as_string=1 FORMAT RowBinary",
    "rowbinary_json_string_selected" => "SELECT pk, payload FROM default.#{table} WHERE pk >= 3 AND pk < 7 ORDER BY pk SETTINGS output_format_binary_write_json_as_string=1 FORMAT RowBinary",
  }.each do |name, query|
    value = w115_run(binary, store, query)
    outputs[name] = value
    artifact_root = ENV["W115_CAPTURE_ROOT"]? || raise "W115_CAPTURE_ROOT is required"
    artifact_label = label.downcase.gsub(" ", "_")
    artifact_extension = name.starts_with?("rowbinary") ? "bin" : (name.starts_with?("path_types") ? "jsonl" : "tsv")
    File.write(File.join(artifact_root, "#{artifact_label}_#{name}.#{artifact_extension}"), value)
    if name.starts_with?("rowbinary")
      puts "#{label} #{name} bytes=#{value.bytesize} hex=#{value.to_slice.hexstring}"
    else
      puts "#{label} #{name} TSVRaw observed:\n#{value}"
    end
  end
  outputs
end

def w115_capture_profile(binary : String, store : String, name : String, json_type : String) : Nil
  source = "w115_#{name}_source"
  attached = "w115_#{name}_attached"
  settings = W115_SETTINGS
  w115_run(binary, store, "CREATE TABLE default.#{source} (pk UInt64, payload #{json_type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings}")
  input = IO::Memory.new((W115_ROWS.join("\n") + "\n").to_slice)
  w115_run(binary, store, "INSERT INTO default.#{source} FORMAT JSONEachRow", input)
  w115_run(binary, store, "CREATE TABLE default.#{attached} (pk UInt64, payload #{json_type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings}")

  schema = w115_run(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{source}' ORDER BY position FORMAT TSVRaw")
  w115_require(schema.lines.size == 2 && schema.lines[0] == "pk UInt64" && schema.lines[1].starts_with?("payload JSON"), "#{name}: unexpected two-column schema: #{schema.inspect}")
  puts "\n=== W115 CAPTURE OBSERVATION ONLY: #{name} ==="
  puts "requested_type=#{json_type}\nsettings=#{settings}\nschema TSVRaw:\n#{schema}"
  puts "SHOW CREATE observed:\n#{w115_run(binary, store, "SHOW CREATE TABLE default.#{source} FORMAT TSVRaw")}"

  part_lines = w115_run(binary, store, "SELECT name || '\t' || path || '\t' || part_type || '\t' || toString(rows) FROM system.parts WHERE database='default' AND table='#{source}' AND active FORMAT TSVRaw").lines
  w115_require(part_lines.size == 1, "#{name}: expected one active stock part, got #{part_lines.size}")
  fields = part_lines.first.split('\t')
  w115_require(fields.size == 4 && fields[2] == "Wide" && fields[3] == "8", "#{name}: unexpected stock part record: #{part_lines.first.inspect}")
  part_name, part_path = fields[0], fields[1]
  part_path = w115_require_store_child(part_path, store, "#{name} source part")
  check = w115_run(binary, store, "CHECK TABLE default.#{source} FORMAT TabSeparated")
  w115_assert_check(check, part_name, "#{name} source")
  w115_check_comparator_controls(part_name)
  puts "#{name} source CHECK exact observed: #{check.inspect}"
  w115_capture_part(part_path, "#{name} source")

  data_path = w115_run(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{attached}' FORMAT TSVRaw").strip
  data_path = w115_require_store_child(data_path, store, "#{name} attached data path")
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  destination = File.join(detached, part_name)
  w115_require(!File.exists?(destination) && !File.symlink?(detached), "#{name}: unsafe or occupied detached destination")
  FileUtils.cp_r(part_path, destination)
  w115_run(binary, store, "ALTER TABLE default.#{attached} ATTACH PART '#{part_name}'")
  attach_check = w115_run(binary, store, "CHECK TABLE default.#{attached} FORMAT TabSeparated")
  w115_assert_check(attach_check, part_name, "#{name} fresh ATTACH")
  puts "#{name} fresh ATTACH CHECK exact observed: #{attach_check.inspect}"
  attached_parts = w115_run(binary, store, "SELECT name || '\t' || path || '\t' || part_type || '\t' || toString(rows) FROM system.parts WHERE database='default' AND table='#{attached}' AND active FORMAT TSVRaw").lines
  w115_require(attached_parts.size == 1, "#{name}: fresh ATTACH did not yield exactly one active part")
  attached_fields = attached_parts.first.split('\t')
  w115_require(attached_fields.size == 4, "#{name}: malformed fresh ATTACH part record")
  w115_require(attached_fields[0] == part_name && attached_fields[2] == "Wide" && attached_fields[3] == "8", "#{name}: fresh ATTACH part identity/type/rows differs")
  attached_path = w115_require_store_child(attached_fields[1], store, "#{name} fresh ATTACH part")
  attached_schema = w115_run(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{attached}' ORDER BY position FORMAT TSVRaw")
  w115_require(attached_schema == schema, "#{name}: source/fresh ATTACH schema differs")
  w115_capture_part(attached_path, "#{name} fresh ATTACH")

  source_snapshots = w115_query_snapshots(binary, store, source, "#{name} source")
  attached_snapshots = w115_query_snapshots(binary, store, attached, "#{name} fresh ATTACH")
  w115_assert_semantic_documents(source_snapshots["documents_full"], name, false, "source")
  w115_assert_semantic_documents(source_snapshots["documents_selected"], name, true, "source")
  w115_assert_semantic_documents(attached_snapshots["documents_full"], name, false, "fresh ATTACH")
  w115_assert_semantic_documents(attached_snapshots["documents_selected"], name, true, "fresh ATTACH")
  puts "PASS #{name}: literal normalized full/selected documents, source and fresh ATTACH"
  source_snapshots.each do |snapshot, bytes|
    w115_assert_same(attached_snapshots[snapshot], bytes, "#{name} source/ATTACH #{snapshot}")
    changed = bytes.to_slice.dup
    unless changed.empty?
      changed[0] ^= 1_u8
      w115_expect_snapshot_mismatch(String.new(changed), bytes, "#{name} #{snapshot}")
    end
  end
end

def w115_capture : Nil
  binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
  root = ENV["W115_CAPTURE_ROOT"]? || raise "W115_CAPTURE_ROOT is required"
  store = ENV["W115_CAPTURE_STORE"]? || raise "W115_CAPTURE_STORE is required"
  root = File.realpath(root)
  w115_require(root.starts_with?("/private/tmp/crystal-click-json-w115.") && !File.symlink?(root), "unsafe W115 temporary root")
  expanded_store = File.expand_path(store)
  parent = File.realpath(File.dirname(expanded_store))
  store = File.join(parent, File.basename(expanded_store))
  w115_require(parent == root && store.starts_with?(root + "/") && !File.symlink?(store), "unsafe W115 store path")
  if Dir.exists?(store)
    w115_require(Dir.empty?(store), "W115 store must be fresh and empty")
  else
    Dir.mkdir(store)
  end

  hash_out = IO::Memory.new
  hash_err = IO::Memory.new
  hash_status = Process.run("shasum", ["-a", "256", binary], output: hash_out, error: hash_err)
  raise "could not inspect ClickHouse SHA-256: #{hash_err}" unless hash_status.success?
  actual_sha = hash_out.to_s.split(' ').first? || raise "malformed SHA-256 output"
  w115_require(actual_sha == W115_EXECUTABLE_SHA256, "wrong ClickHouse executable SHA: #{actual_sha}")
  version_out = IO::Memory.new
  version_err = IO::Memory.new
  version_status = Process.run(binary, ["local", "--version"], output: version_out, error: version_err)
  raise "could not query ClickHouse version: #{version_err}" unless version_status.success?
  expected_version = "ClickHouse local version #{W115_VERSION} (official build)."
  w115_require(version_out.to_s.strip == expected_version, "wrong ClickHouse version: #{version_out.to_s.strip}")
  build = w115_run(binary, store, "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
  w115_require(build == ["GIT_HASH=#{W115_BUILD_HASH}", "VERSION_GITHASH=#{W115_BUILD_HASH}"], "wrong ClickHouse build identity: #{build.inspect}")
  flag = w115_run(binary, store, "SELECT name || '=' || value FROM system.settings WHERE name='output_format_binary_write_json_as_string' FORMAT TSVRaw").strip
  w115_require(flag.starts_with?("output_format_binary_write_json_as_string="), "binary JSON-string output setting is unavailable")
  puts "W115 CAPTURE-ONLY: observations are not a correctness qualification or production RED"
  puts "runtime=#{expected_version}; build=#{W115_BUILD_HASH}; executable_sha256=#{actual_sha}; binary_json_string_setting=#{flag}"
  W115_ROWS.each_with_index do |row, index|
    w115_require(JSON.parse(row)["pk"].as_i == index + 1, "input literal key sequence differs")
  end
  File.write(File.join(root, "input.jsonl"), W115_ROWS.join("\n") + "\n")
  W115_PROFILES.each { |profile| w115_capture_profile(binary, store, profile[0], profile[1]) }
  puts "PASS W115 capture: three source/fresh-ATTACH profiles, six exact CHECK=1 records; physical snapshots remain observational"
end

w115_capture
