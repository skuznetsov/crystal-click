#!/usr/bin/env ruby
# Independent stock ClickHouse oracle for the W152 nominal Dynamic descriptor.
# Ruby owns the literal wire expectations; the Crystal driver only emits types
# produced by the library's public factory and descriptor codec.
require "digest"
require "fileutils"
require "open3"
require "optparse"

VERSION = "26.10.1.1201"
BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-7f568d60"
SOURCE_REVISION = "7f568d607755c5dcebd48d8eacb17ad745d34c21"
SCRATCH_ROOT_PREFIX = "/private/tmp/crystal-click-w152-"
DEFAULT_BINARY = "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped"
DEFAULT_CRYSTAL = "/opt/homebrew/bin/crystal"

CAPS = (0..254).to_a.freeze
CAP_COLUMNS = CAPS.map { |cap| "d#{cap}" }.freeze
WRAPPER_NAMES = %w[w_array0 w_tuple1 w_map32 w_nullable_tuple254].freeze
ALL_COLUMNS = (CAP_COLUMNS + WRAPPER_NAMES).freeze
WRAPPER_TYPE_NAMES = [
  "Array(Dynamic(max_types=0))",
  "Tuple(x Dynamic(max_types=1))",
  "Map(String, Dynamic)",
  "Nullable(Tuple(x Dynamic(max_types=254)))",
].freeze

class W152Failure < StandardError; end

def w152_fail!(message)
  raise W152Failure, "W152 descriptor oracle: #{message}"
end

def w152_require(condition, message)
  w152_fail!(message) unless condition
end

def var_uint(value)
  value = Integer(value)
  w152_fail!("negative VarUInt") if value.negative?
  bytes = +"".b
  while value >= 0x80
    bytes << ((value & 0x7f) | 0x80)
    value >>= 7
  end
  bytes << value
end

def ch_string(value)
  bytes = value.to_s.b
  var_uint(bytes.bytesize) + bytes
end

def u8(value)
  [Integer(value)].pack("C")
end

class W152BinaryReader
  attr_reader :offset

  def initialize(bytes)
    @bytes = bytes.b
    @offset = 0
  end

  def read_byte
    w152_fail!("truncated binary header at byte #{@offset}") if @offset >= @bytes.bytesize
    byte = @bytes.getbyte(@offset)
    @offset += 1
    byte
  end

  def read_bytes(length)
    w152_fail!("negative binary length") if length.negative?
    finish = @offset + length
    w152_fail!("truncated binary header at byte #{@offset}") if finish > @bytes.bytesize
    value = @bytes.byteslice(@offset, length)
    @offset = finish
    value
  end

  def read_var_uint
    value = 0
    shift = 0
    10.times do
      byte = read_byte
      payload = byte & 0x7f
      w152_fail!("VarUInt overflow") if shift == 63 && payload > 1
      value |= payload << shift
      return value if (byte & 0x80).zero?
      shift += 7
    end
    w152_fail!("unterminated VarUInt")
  end

  def read_string
    read_bytes(read_var_uint)
  end

  # Decode only the bounded descriptor grammar present in this witness. The
  # independent byte oracle below still supplies the expected exact encodings.
  def read_type(depth = 1)
    w152_fail!("descriptor nesting exceeds witness bound") if depth > 16
    start = @offset
    tag = read_byte
    case tag
    when 0x2b # Dynamic: cap is exactly one byte, not VarUInt.
      read_byte
    when 0x15 # String key in the Map wrapper witness.
      nil
    when 0x1e, 0x23 # Array, Nullable
      read_type(depth + 1)
    when 0x27 # Map
      read_type(depth + 1)
      read_type(depth + 1)
    when 0x20, 0x1f # Named or unnamed Tuple
      count = read_var_uint
      w152_fail!("unreasonable Tuple arity in witness") if count > 16
      count.times do
        read_string if tag == 0x20
        read_type(depth + 1)
      end
    else
      w152_fail!(format("unexpected type descriptor tag 0x%02x", tag))
    end
    @bytes.byteslice(start, @offset - start)
  end
end

def parse_rowbinary_with_names_and_types(bytes)
  reader = W152BinaryReader.new(bytes)
  count = reader.read_var_uint
  w152_require(count == ALL_COLUMNS.size, "binary header column count differs: #{count}")
  names = Array.new(count) { reader.read_string }
  descriptors = Array.new(count) { reader.read_type }
  [names, descriptors, reader.offset, bytes.byteslice(reader.offset..).to_s.b]
end

def write_new_file(path, bytes)
  File.open(path, "wbx", 0o600) { |file| file.write(bytes) }
rescue Errno::EEXIST
  w152_fail!("refusing to overwrite #{path}")
end

def clickhouse_sql_string(value)
  escaped = value.gsub(/[\\']/) { |character| "\\#{character}" }
  "'#{escaped}'"
end

class W152StockQueries
  def initialize(binary, root)
    @binary = binary
    @root = root
    @query_dir = File.join(root, "results", "stock")
    Dir.mkdir(@query_dir, 0o700)
    @store_root = File.join(root, "stores")
    @sequence = 0
  end

  def call(label, sql)
    @sequence += 1
    safe_label = label.gsub(/[^A-Za-z0-9_.-]/, "_")
    base = File.join(@query_dir, format("%03d-%s", @sequence, safe_label))
    store = File.join(@store_root, format("%03d-%s", @sequence, safe_label))
    Dir.mkdir(store, 0o700)
    write_new_file(base + ".sql", sql + ";\n")

    args = [
      @binary, "local", "--path", store, "--session_timezone=UTC",
      "--print_pretty_type_names=0", "--max_threads=1",
      "--max_memory_usage=536870912",
    ]
    args.concat(["--query", sql])
    stdout, stderr, status = Open3.capture3({"TZ" => "UTC"}, *args)
    write_new_file(base + ".stdout", stdout.b)
    write_new_file(base + ".stderr", stderr.b)
    [base + ".sql", base + ".stdout", base + ".stderr"].each do |path|
      w152_require(File.size(path) <= 16 * 1024 * 1024, "evidence file exceeds 16 MiB: #{path}")
    end
    w152_fail!("stock query #{label} failed (#{status.exitstatus}): #{stderr}\nSQL=#{sql}") unless status.success?
    stdout.b
  end
end

def expected_cap_name(cap)
  cap == 32 ? "Dynamic" : "Dynamic(max_types=#{cap})"
end

def expected_descriptors
  cap_descriptors = CAPS.map { |cap| "\x2b".b + u8(cap) }
  wrapper_descriptors = [
    "\x1e\x2b\x00".b,
    "\x20\x01\x01x\x2b\x01".b,
    "\x27\x15\x2b\x20".b,
    "\x23\x20\x01\x01x\x2b\xfe".b,
  ]
  cap_descriptors + wrapper_descriptors
end

def expected_type_names
  CAPS.map { |cap| expected_cap_name(cap) } + WRAPPER_TYPE_NAMES
end

def stock_expressions
  caps = CAPS.map do |cap|
    "CAST(NULL, 'Dynamic(max_types=#{cap})') AS d#{cap}"
  end
  wrappers = [
    "CAST([], 'Array(Dynamic(max_types=0))') AS w_array0",
    "CAST(tuple(CAST(NULL, 'Dynamic(max_types=1)')), 'Tuple(x Dynamic(max_types=1))') AS w_tuple1",
    "map('x', CAST(NULL, 'Dynamic(max_types=32)')) AS w_map32",
    "CAST(tuple(CAST(NULL, 'Dynamic(max_types=254)')), 'Nullable(Tuple(x Dynamic(max_types=254)))') AS w_nullable_tuple254",
  ]
  caps + wrappers
end

def observe_types(queries, label, file_path)
  fields = ALL_COLUMNS.map { |name| "toTypeName(`#{name}`)" }.join(", ")
  sql = "SELECT #{fields} FROM file(#{clickhouse_sql_string(file_path)}, 'RowBinaryWithNamesAndTypes') " \
        "SETTINGS input_format_binary_decode_types_in_binary_format=1 FORMAT TSVRaw"
  output = queries.call(label, sql)
  values = output.chomp.split("\t", -1)
  w152_require(values.size == ALL_COLUMNS.size, "#{label}: inferred toTypeName count differs (#{values.size})")
  values
end

def parse_emitter_output(output)
  records = {}
  output.each_line do |line|
    fields = line.chomp.split("\t", -1)
    w152_require(fields.size == 3, "Crystal emitter row has wrong field count: #{line.inspect}")
    label, name, hex = fields
    w152_require(hex.match?(/\A(?:[0-9A-Fa-f]{2})+\z/), "invalid descriptor hex from Crystal emitter for #{label}")
    w152_require(!records.key?(label), "duplicate Crystal emitter label #{label}")
    records[label] = [name, [hex].pack("H*")]
  end

  expected_labels = CAPS.map { |cap| "cap:#{cap}" } + %w[
    wrapper:array0 wrapper:tuple1 wrapper:map32 wrapper:nullable_tuple254
  ]
  w152_require(records.keys == expected_labels, "Crystal emitter labels/order do not cover exact W152 roster")
  records
end

def make_library_header(records, body)
  names = ALL_COLUMNS
  descriptors = CAPS.map { |cap| records.fetch("cap:#{cap}")[1] } + %w[
    wrapper:array0 wrapper:tuple1 wrapper:map32 wrapper:nullable_tuple254
  ].map { |label| records.fetch(label)[1] }
  header = var_uint(names.size) + names.map { |name| ch_string(name) }.join.b + descriptors.join.b
  header + body
end

def verify_pins(binary, crystal, root, queries)
  w152_require(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary),
    "pinned ClickHouse executable is absent, non-executable, or a symlink")
  digest = Digest::SHA256.file(binary).hexdigest
  w152_require(digest == EXECUTABLE_SHA256, "runtime SHA-256 differs: #{digest}")
  w152_require(File.file?(crystal) && File.executable?(crystal), "Crystal compiler is absent or non-executable: #{crystal}")

  source = Open3.capture3("git", "-C", SOURCE_ROOT, "rev-parse", "HEAD")
  w152_require(source[2].success? && source[0].strip == SOURCE_REVISION,
    "pinned shallow source revision differs: #{source[0].strip.inspect} #{source[1]}")
  version = queries.call("version", "SELECT version() FORMAT TSVRaw").strip
  w152_require(version == VERSION, "runtime version differs: #{version.inspect}")
  build = queries.call("build-identity",
    "SELECT concat(name, '=', value) FROM system.build_options " \
    "WHERE name IN ('GIT_HASH','VERSION_GITHASH') ORDER BY name FORMAT TSVRaw")
  expected = "GIT_HASH=#{BUILD_HASH}\nVERSION_GITHASH=#{BUILD_HASH}\n"
  w152_require(build == expected, "runtime build identity differs: #{build.inspect}")

  write_new_file(File.join(root, "results", "pins.txt"), [
    "runtime_version=#{version}",
    "runtime_sha256=#{digest}",
    "runtime_build_hash=#{BUILD_HASH}",
    "source_reference=#{SOURCE_ROOT}@#{source[0].strip}",
    "source_is_not_asserted_to_build_runtime=true",
    "normal_factory_caps=0..254",
    "pinned_source_raw_decoder_directly_accepts_cap255_outside_factory_profile=true",
    "oracle_factory_profile_caps=0..254; cap255_not_run_as_factory_type",
  ].join("\n") + "\n")
end

def validate_scratch(path)
  w152_require(Dir.exist?(path) && !File.symlink?(path), "caller scratch directory is absent or a symlink")
  scratch = File.realpath(path)
  w152_require(File.expand_path(path) == scratch, "caller scratch path is not canonical")
  parent = File.dirname(scratch)
  w152_require(File.realpath(parent) == parent, "scratch parent is not canonical")
  w152_require(File.dirname(parent) == "/private/tmp" && File.basename(parent).start_with?("crystal-click-w152-"),
    "scratch must be a direct child of a /private/tmp/crystal-click-w152-* root")
  w152_require(File.dirname(scratch) == parent, "scratch must be a direct child of its W152 root")
  w152_require(Dir.children(scratch).empty?, "caller scratch directory must be empty")
  scratch
end

def run_driver(crystal, root)
  script = File.expand_path("check_dynamic_descriptor_w152.cr", __dir__)
  stdout, stderr, status = Open3.capture3(
    crystal, "run", "--single-module", "--threads", "1",
    "--link-flags=-fuse-ld=ld", "--error-trace", script
  )
  write_new_file(File.join(root, "results", "crystal-emitter.stdout"), stdout.b)
  write_new_file(File.join(root, "results", "crystal-emitter.stderr"), stderr.b)
  w152_fail!("library descriptor emitter failed (#{status.exitstatus}): #{stderr}") unless status.success?
  parse_emitter_output(stdout)
end

def main
  options = {
    binary: DEFAULT_BINARY,
    crystal: DEFAULT_CRYSTAL,
    scratch: nil,
  }
  OptionParser.new do |parser|
    parser.banner = "Usage: ruby scripts/check_dynamic_descriptor_w152.rb --scratch EMPTY_W152_SUBDIR [options]"
    parser.on("--binary PATH", "Pinned ClickHouse executable") { |value| options[:binary] = value }
    parser.on("--crystal PATH", "Crystal compiler (default: #{DEFAULT_CRYSTAL})") { |value| options[:crystal] = value }
    parser.on("--scratch PATH", "Caller-created empty direct child of a /private/tmp/crystal-click-w152-* root") { |value| options[:scratch] = value }
  end.parse!

  w152_require(options[:scratch], "--scratch is required; runner never creates or reuses a scratch directory")
  root = validate_scratch(options[:scratch])
  results = File.join(root, "results")
  stores = File.join(root, "stores")
  user_files = File.join(root, "user_files")
  [results, stores, user_files].each { |path| Dir.mkdir(path, 0o700) }

  queries = W152StockQueries.new(options[:binary], root)
  verify_pins(options[:binary], options[:crystal], root, queries)
  records = run_driver(options[:crystal], root)

  CAPS.each do |cap|
    name, descriptor = records.fetch("cap:#{cap}")
    literal = "\x2b".b + u8(cap)
    w152_require(name == expected_cap_name(cap), "library canonical name differs at cap #{cap}: #{name.inspect}")
    w152_require(descriptor == literal, "library descriptor differs from independent literal at cap #{cap}")
  end
  wrapper_labels = %w[wrapper:array0 wrapper:tuple1 wrapper:map32 wrapper:nullable_tuple254]
  wrapper_labels.zip(WRAPPER_TYPE_NAMES, expected_descriptors.drop(CAPS.size)).each do |label, name, literal|
    emitted_name, descriptor = records.fetch(label)
    w152_require(emitted_name == name, "library wrapper name differs for #{label}: #{emitted_name.inspect}")
    w152_require(descriptor == literal, "library wrapper descriptor differs from independent literal for #{label}")
  end

  stock_sql = "SELECT #{stock_expressions.join(', ')} SETTINGS " \
              "output_format_binary_encode_types_in_binary_format=1 FORMAT RowBinaryWithNamesAndTypes"
  stock_bytes = queries.call("stock-binary-header-and-null-row", stock_sql)
  write_new_file(File.join(user_files, "stock.rowbin"), stock_bytes)
  stock_names, stock_descriptors, header_end, stock_body = parse_rowbinary_with_names_and_types(stock_bytes)
  w152_require(stock_names == ALL_COLUMNS.map(&:b),
    "stock binary header column names/order differ")
  w152_require(stock_descriptors == expected_descriptors,
    "stock binary header descriptors differ from independent literals")
  w152_require(stock_body.bytesize >= CAPS.size && stock_body.byteslice(0, CAPS.size) == "\x00".b * CAPS.size,
    "stock Dynamic NULL witness is not one Nothing byte per Dynamic column")
  w152_require(header_end < stock_bytes.bytesize, "stock witness unexpectedly has no row payload")

  expected_names = expected_type_names
  stock_observed = observe_types(queries, "stock-header-inferred-types", File.join(user_files, "stock.rowbin"))
  w152_require(stock_observed == expected_names,
    "stock writer header was not read back as the exact inferred nominal types")

  library_bytes = make_library_header(records, stock_body)
  library_path = File.join(user_files, "library.rowbin")
  write_new_file(library_path, library_bytes)
  library_names, library_descriptors, library_header_end, library_body = parse_rowbinary_with_names_and_types(library_bytes)
  w152_require(library_names == ALL_COLUMNS.map(&:b),
    "library binary header names/order differ")
  w152_require(library_descriptors == expected_descriptors,
    "library binary header descriptors differ after independent parsing")
  w152_require(library_header_end < library_bytes.bytesize && library_body == stock_body,
    "library witness row payload differs from stock-serialized compatible null/wrapper row")
  library_observed = observe_types(queries, "library-header-inferred-types", library_path)
  w152_require(library_observed == expected_names,
    "stock input did not infer all 255 library Dynamic caps and legal wrapper nominal types")

  mutated_descriptors = CAPS.map { |cap| records.fetch("cap:#{cap}")[1] }
  mutated_descriptors[32] = records.fetch("cap:33")[1]
  mutated_descriptors.concat(wrapper_labels.map { |label| records.fetch(label)[1] })
  mutated_header = var_uint(ALL_COLUMNS.size) + ALL_COLUMNS.map { |name| ch_string(name) }.join.b + mutated_descriptors.join.b
  mutant_path = File.join(user_files, "library-valid-cap-mutant.rowbin")
  write_new_file(mutant_path, mutated_header + stock_body)
  mutant_observed = observe_types(queries, "valid-library-cap-mutant-inferred-types", mutant_path)
  mutant_expected = expected_names.dup
  mutant_expected[32] = expected_cap_name(33)
  w152_require(mutant_observed == mutant_expected,
    "valid cap-32-to-library-cap-33 header mutation was not observed as exactly one nominal type change")
  w152_require(mutant_observed[32] != expected_names[32], "valid changed-cap control failed to distinguish cap 32")

  write_new_file(File.join(results, "summary.txt"), <<~TEXT)
    PASS stock binary output header literal match for 255 factory-admitted Dynamic caps 0..254
    PASS stock input inferred toTypeName for stock and library headers: all caps plus Array/Tuple/Map/Nullable-Tuple wrappers
    PASS valid library header mutation cap 32 -> cap 33 changed exactly the stock-observed d32 nominal type
    PASS library driver called BinaryDataType.dynamic and BinaryDataTypeCodec.encode/decode for every cap and wrapper
    Dynamic NULL payload used as a typed one-byte Nothing witness; no Dynamic value or storage support is claimed
    Local nominal equality/hash check was local only; no upstream binary hash equivalence is claimed
    Pinned source distinguishes raw decoder cap 255 acceptance from factory caps 0..254; this oracle tests factory types only
    source_reference=#{SOURCE_ROOT}@#{SOURCE_REVISION}
    source_is_not_asserted_to_build_runtime=true
    runtime=#{VERSION} build=#{BUILD_HASH} sha256=#{EXECUTABLE_SHA256}
  TEXT
  puts "PASS W152 independent Dynamic descriptor oracle (255 caps, inferred stock types, valid changed-cap control)"
end

begin
  main
rescue W152Failure => error
  warn error.message
  exit 1
end
