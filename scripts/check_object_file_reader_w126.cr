# W126 stock oracle: the file reader receives only an attached part path,
# raw column, typed schema, and explicit profiles/limits. W123 documents remain
# the independent semantic expectation; no fixture roster assembles reader IO.
require "json"
require "../src/crystal_click"
require "./w115_json_semantic_vectors"
require "./w123_object_vectors"

W126_VERSION           = "26.10.1.1201"
W126_BUILD_HASH        = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W126_EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"

class W126Mismatch < Exception
end

def w126_fail(message : String) : NoReturn
  raise W126Mismatch.new(message)
end

def w126_require(condition : Bool, message : String) : Nil
  w126_fail(message) unless condition
end

def w126_run(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
  raise "ClickHouse local query failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w126_run_status(binary : String, arguments : Array(String)) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, arguments, output: output, error: error)
  raise "ClickHouse command failed: #{error}" unless status.success?
  output.to_s
end

def w126_verify_runtime(binary : String, store : String) : Nil
  version = w126_run_status(binary, ["local", "--version"]).strip
  w126_require(version == "ClickHouse local version #{W126_VERSION} (official build).",
    "unexpected ClickHouse version: #{version.inspect}")
  digest = w126_run_status("shasum", ["-a", "256", binary]).split(' ').first? || ""
  w126_require(digest == W126_EXECUTABLE_SHA256, "unexpected ClickHouse executable SHA-256")
  build = w126_run(binary, store,
    "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
  w126_require(build == ["GIT_HASH=#{W126_BUILD_HASH}", "VERSION_GITHASH=#{W126_BUILD_HASH}"],
    "unexpected ClickHouse build identity")
end

def w126_store_child(path : String, store : String, label : String) : String
  real_store = File.realpath(store)
  real_path = File.realpath(path)
  unless real_path.starts_with?(real_store + "/") && !File.symlink?(path)
    w126_fail("#{label}: path escapes isolated store or is a symlink")
  end
  relative = real_path[(real_store.size + 1)..]
  cursor = real_store
  relative.split('/').each do |component|
    cursor = File.join(cursor, component)
    w126_fail("#{label}: symlink in store path") if File.symlink?(cursor)
  end
  real_path
end

def w126_part(binary : String, store : String, table : String, label : String) : Tuple(String, String)
  rows = w126_run(binary, store,
    "SELECT name, path, part_type, toString(rows) FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines
  w126_require(rows.size == 1, "#{label}: expected one active part, got #{rows.size}")
  fields = rows.first.split('\t')
  w126_require(fields.size == 4 && fields[2] == "Wide" && fields[3] == "8",
    "#{label}: expected one Wide eight-row part")
  part = w126_store_child(fields[1], store, "#{label} part")
  w126_require(File.file?(File.join(part, "checksums.txt")) && !File.symlink?(File.join(part, "checksums.txt")),
    "#{label}: attached part has no safe checksums.txt")
  {fields[0], part}
end

def w126_assert_check(actual : String, part_name : String, label : String) : Nil
  expected = "#{part_name}\t1\t\n"
  w126_fail("#{label}: CHECK output mismatch: #{actual.inspect}") unless actual == expected
end

def w126_assert_documents(
  expected : Array(CrystalClick::ObjectDocument),
  actual : Array(CrystalClick::ObjectDocument),
  label : String,
) : Nil
  w126_require(expected.size == actual.size, "#{label}: document count differs")
  expected.each_with_index do |document, row_index|
    actual_document = actual[row_index]
    paths = document.paths
    w126_fail("#{label}: flattened path identities differ at row #{row_index}") unless paths == actual_document.paths
    paths.each do |path|
      expected_value = document.value_for(path)
      actual_value = actual_document.value_for(path)
      unless W122BulkVectors.value_equal?(expected_value, actual_value)
        w126_fail("#{label}: nominal value differs at row #{row_index}, path #{path.inspect}")
      end
    end
  end
end

def w126_assert_granules(
  expected : Array(Array(CrystalClick::ObjectDocument)),
  actual : Array(Array(CrystalClick::ObjectDocument)),
  label : String,
) : Nil
  w126_require(expected.size == actual.size, "#{label}: granule count differs")
  expected.each_with_index do |granule, index|
    w126_assert_documents(granule, actual[index], "#{label} granule #{index}")
  end
end

def w126_typed_schema(profile : String) : Hash(String, CrystalClick::BinaryDataType)
  if profile == "typed_mixed"
    {"a" => CrystalClick::BinaryDataType.primitive("UInt64")}
  else
    {} of String => CrystalClick::BinaryDataType
  end
end

def w126_read(
  part : String,
  profile : String,
  first_mark : Int32,
  mark_count : Int32,
) : Array(Array(CrystalClick::ObjectDocument))
  CrystalClick::ObjectDocumentFileReader.read(
    part,
    "payload",
    w126_typed_schema(profile),
    first_mark: first_mark,
    mark_count: mark_count,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
    hashed: true,
    limits: CrystalClick::BinaryCodecLimits.default,
    transport_limits: CrystalClick::CompressedStreamLimits.new
  )
end

def w126_stock_queries(binary : String, store : String, table : String, profile : String, label : String) : Nil
  check = w126_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  part_name, _part = w126_part(binary, store, table, label)
  w126_assert_check(check, part_name, "#{label} CHECK TABLE")

  full_query = "SELECT pk, toJSONString(payload) FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
  selected_query = "SELECT pk, toJSONString(payload) FROM default.#{table} WHERE pk >= 3 AND pk <= 6 ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
  w115_assert_semantic_documents(w126_run(binary, store, full_query), profile, false, "#{label} stock full")
  w115_assert_semantic_documents(w126_run(binary, store, selected_query), profile, true, "#{label} stock pk3..6")
end

def w126_expect_comparator_controls : Nil
  wrong_document = [CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)]
  expected_document = CrystalClick::ObjectDocument.new({"x" => CrystalClick::BinaryValue.uint64(1_u64)})
  begin
    w126_assert_documents([wrong_document.first], [expected_document], "W126 wrong-document control")
  rescue error : W126Mismatch
    w126_require(error.message.to_s.starts_with?("W126 wrong-document control: flattened path identities differ"),
      "W126 wrong-document control failed for an unrelated reason")
  else
    w126_fail("W126 wrong document was accepted")
  end

  seed = [[expected_document], [expected_document], [expected_document], [expected_document]]
  regrouped = [[expected_document, expected_document], [expected_document, expected_document]]
  begin
    w126_assert_granules(seed, regrouped, "W126 wrong-grid control")
  rescue error : W126Mismatch
    w126_require(error.message.to_s.starts_with?("W126 wrong-grid control: granule count differs"),
      "W126 wrong-grid control failed for an unrelated reason")
  else
    w126_fail("W126 wrong granule grid was accepted")
  end

  begin
    w126_assert_check("w126_control_part\t0\t\n", "w126_control_part", "W126 CHECK=0 control")
  rescue error : W126Mismatch
    w126_require(error.message.to_s.starts_with?("W126 CHECK=0 control: CHECK output mismatch"),
      "W126 CHECK=0 control failed for an unrelated reason")
  else
    w126_fail("W126 CHECK=0 was accepted")
  end
  puts "PASS W126 wrong-document, wrong-grid and CHECK=0 comparator controls"
end

def w126_case(binary : String, root : String, profile : String, mode : String) : Nil
  table = "w125_#{profile}_#{mode}"
  store = File.join(root, "stores", "#{profile}_#{mode}")
  w126_require(Dir.exists?(store) && !File.symlink?(store), "missing or unsafe retained W125 store #{profile}/#{mode}")
  store = File.realpath(store)
  part_name, part = w126_part(binary, store, table, "W126 #{profile}/#{mode}")

  expected = W123ObjectVectors.documents(profile)
  full = w126_read(part, profile, 0, 4)
  w126_assert_granules(expected, full, "W126 #{profile}/#{mode} reader full")
  selected = w126_read(part, profile, 1, 2)
  w126_assert_granules(expected[1, 2], selected, "W126 #{profile}/#{mode} reader marks 1..2")
  empty = [] of Array(CrystalClick::ObjectDocument)
  zero = w126_read(part, profile, 4, 0)
  w126_assert_granules(empty, zero, "W126 #{profile}/#{mode} reader zero window")

  w126_stock_queries(binary, store, table, profile, "W126 #{profile}/#{mode}")
  puts "PASS W126 production file reader + stock CHECK=1/full/pk3..6: #{profile}/#{mode} part=#{part_name}"
end

def w126_check : Nil
  binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
  capture_root = ENV["W126_W115_CAPTURE_ROOT"]? || raise "W126_W115_CAPTURE_ROOT is required"
  root = ENV["W126_W125_OUTPUT_ROOT"]? || raise "W126_W125_OUTPUT_ROOT is required"
  w126_require(!File.symlink?(capture_root) && !File.symlink?(root), "W126 input roots must not be symlinks")
  capture_root = File.realpath(capture_root)
  root = File.realpath(root)
  w126_require(capture_root.starts_with?("/private/tmp/crystal-click-json-w115."), "unsafe W115 capture root")
  w126_require(root.starts_with?("/private/tmp/crystal-click-json-w125."), "unsafe W125 output root")
  source_store = File.join(capture_root, "store")
  w126_require(Dir.exists?(source_store) && !File.symlink?(source_store), "W115 capture has no safe source store")
  {"capture.log", "input.jsonl"}.each do |name|
    path = File.join(capture_root, name)
    w126_require(File.file?(path) && !File.symlink?(path), "W115 capture is missing safe #{name}")
  end
  w126_require(W123ObjectVectors::PROFILES.to_a.sort == ["dynamic_paths", "typed_mixed"].sort,
    "W126 independent W123 profile inventory changed")
  w126_require(W115_SEMANTIC_PAYLOADS.size == 8, "W126 independent W115 row inventory changed")

  first_store = File.join(root, "stores", "dynamic_paths_basic")
  w126_require(Dir.exists?(first_store) && !File.symlink?(first_store), "retained W125 stock stores are unavailable")
  w126_verify_runtime(binary, first_store)
  w126_expect_comparator_controls
  {"dynamic_paths", "typed_mixed"}.each do |profile|
    {"basic", "compact"}.each do |mode|
      w126_case(binary, root, profile, mode)
    end
  end
  puts "PASS W126 scope: retained W125 stock parts, normalized Object V3/MAP profiles only; no fresh sidecars or publication claim"
end

w126_check
