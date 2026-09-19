require "spec"
require "file_utils"
require "../src/crystal_click"

FIXTURE = File.expand_path("../test/fixtures/public/wide_u64_lz4/part", __DIR__)

def fixture_copy
  path = File.tempname("crystal-click-spec")
  FileUtils.cp_r(FIXTURE, path)
  path
end

def with_fixture_copy(&)
  path = fixture_copy
  begin
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end

def mutate_fixture_file(path : String, name : String, &)
  file = File.join(path, name)
  bytes = writable_file_bytes(file)
  yield bytes
  File.open(file, "wb") { |io| io.write(bytes) }
end

def writable_file_bytes(file : String) : Bytes
  bytes = Bytes.new(File.size(file).to_i)
  File.open(file) { |io| io.read_fully(bytes) }
  bytes
end

def write_bytes(path : String, name : String, bytes : Bytes)
  File.open(File.join(path, name), "wb") { |io| io.write(bytes) }
end
