# W141 independent literal/stock oracle for the direct binary type-row
# certificates retained by probe_object_low_cardinality_w141.sh. The expected
# descriptors and per-row bytes below are authored literals; neither the
# workspace writer nor ClickHouse output generates the expected values.
require "file_utils"
require "./check_binary_w117"

W141_SOURCE_REVISION = "9007d227b64a3f8b667fc5258ceb2923f3cf477d"
W141_CLICKHOUSE_VERSION = "ClickHouse local version 26.10.1.1201 (official build)."
W141_RUNTIME_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W141_BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"

class W141BinaryMismatch < Exception
end

struct W141BinaryCase
  getter label : String
  getter schema : String
  getter descriptor_hex : String
  getter mutation_descriptor_hex : String
  getter payload_hexes : Array(String)
  getter values : Array(CrystalClick::BinaryValue)
  getter display_type_name_hex : String?

  def initialize(@label : String, @schema : String, @descriptor_hex : String,
                 @mutation_descriptor_hex : String, @payload_hexes : Array(String),
                 @values : Array(CrystalClick::BinaryValue), @display_type_name_hex : String? = nil)
  end
end

def w141_fail(message : String) : NoReturn
  raise W141BinaryMismatch.new(message)
end

def w141_assert(condition : Bool, message : String) : Nil
  w141_fail(message) unless condition
end

def w141_low_string_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
end

def w141_low_string(type : CrystalClick::BinaryDataType, value : String) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.low_cardinality(type, CrystalClick::BinaryValue.string(value))
end

def w141_fixed(type_name : String, hex : String) : CrystalClick::BinaryValue
  type = CrystalClick::BinaryDataType.primitive(type_name)
  CrystalClick::BinaryValue.fixed(type, w117_bytes(hex))
end

def w141_cases : Array(W141BinaryCase)
  cases = [] of W141BinaryCase

  string_type = CrystalClick::BinaryDataType.primitive("String")
  low_string_type = CrystalClick::BinaryDataType.low_cardinality(string_type)
  cases << W141BinaryCase.new(
    "lc-string", "LowCardinality(String)", "2615", "15", ["03e99baa"],
    [w141_low_string(low_string_type, "雪")],
  )

  nullable_string_type = CrystalClick::BinaryDataType.nullable(string_type)
  low_nullable_string_type = CrystalClick::BinaryDataType.low_cardinality(nullable_string_type)
  cases << W141BinaryCase.new(
    "lc-nullable-string", "LowCardinality(Nullable(String))", "262315", "2315",
    ["01", "0005cebbe99baa"],
    [
      CrystalClick::BinaryValue.low_cardinality(
        low_nullable_string_type,
        CrystalClick::BinaryValue.nullable(nullable_string_type),
      ),
      CrystalClick::BinaryValue.low_cardinality(
        low_nullable_string_type,
        CrystalClick::BinaryValue.nullable(nullable_string_type, CrystalClick::BinaryValue.string("λ雪")),
      ),
    ],
  )

  int64_type = CrystalClick::BinaryDataType.primitive("Int64")
  low_int64_type = CrystalClick::BinaryDataType.low_cardinality(int64_type)
  cases << W141BinaryCase.new(
    "lc-int64", "LowCardinality(Int64)", "260a", "0a", ["1032547698badcfe"],
    [CrystalClick::BinaryValue.low_cardinality(low_int64_type, CrystalClick::BinaryValue.fixed(int64_type, w117_bytes("1032547698badcfe")))],
  )

  date_type = CrystalClick::BinaryDataType.primitive("Date")
  low_date_type = CrystalClick::BinaryDataType.low_cardinality(date_type)
  cases << W141BinaryCase.new(
    "lc-date", "LowCardinality(Date)", "260f", "0f", ["784e"],
    [CrystalClick::BinaryValue.low_cardinality(low_date_type, CrystalClick::BinaryValue.fixed(date_type, w117_bytes("784e")))],
  )

  ipv4_type = CrystalClick::BinaryDataType.primitive("IPv4")
  low_ipv4_type = CrystalClick::BinaryDataType.low_cardinality(ipv4_type)
  cases << W141BinaryCase.new(
    "lc-ipv4", "LowCardinality(IPv4)", "2628", "28", ["010200c0"],
    [CrystalClick::BinaryValue.low_cardinality(low_ipv4_type, CrystalClick::BinaryValue.fixed(ipv4_type, w117_bytes("010200c0")))],
  )

  fixed_string_type = CrystalClick::BinaryDataType.fixed_string(3)
  low_fixed_string_type = CrystalClick::BinaryDataType.low_cardinality(fixed_string_type)
  cases << W141BinaryCase.new(
    "lc-fixed-string", "LowCardinality(FixedString(3))", "261603", "1603", ["636174"],
    [CrystalClick::BinaryValue.low_cardinality(low_fixed_string_type, CrystalClick::BinaryValue.fixed(fixed_string_type, w117_bytes("636174")))],
  )

  array_type = CrystalClick::BinaryDataType.array(low_string_type)
  array_value = CrystalClick::BinaryValue.array(array_type, [
    w141_low_string(low_string_type, "red"),
    w141_low_string(low_string_type, "雪"),
  ])
  cases << W141BinaryCase.new(
    "array-lc-string", "Array(LowCardinality(String))", "1e2615", "1e15", ["020372656403e99baa"],
    [array_value],
  )

  map_type = CrystalClick::BinaryDataType.map(string_type, low_string_type)
  map_value = CrystalClick::BinaryValue.map(map_type, [
    CrystalClick::BinaryValue.string("a"), w141_low_string(low_string_type, "red"),
    CrystalClick::BinaryValue.string("b"), w141_low_string(low_string_type, "雪"),
  ])
  cases << W141BinaryCase.new(
    "map-lc-string", "Map(String, LowCardinality(String))", "27152615", "271515",
    ["02016103726564016203e99baa"], [map_value],
  )

  uint32_type = CrystalClick::BinaryDataType.primitive("UInt32")
  tuple_type = CrystalClick::BinaryDataType.tuple(
    [low_string_type, uint32_type] of CrystalClick::BinaryDataType,
    ["s", "n"],
  )
  tuple_value = CrystalClick::BinaryValue.tuple(tuple_type, [
    w141_low_string(low_string_type, "雪"),
    CrystalClick::BinaryValue.fixed(uint32_type, w117_bytes("ffffffff")),
  ])
  cases << W141BinaryCase.new(
    "tuple-lc-string", "Tuple(s LowCardinality(String), n UInt32)", "200201732615016e03", "2002017315016e03",
    ["03e99baaffffffff"], [tuple_value],
    # Native toTypeName spelling includes newlines and indentation for named Tuple types.
    "5475706C65280A2020202073204C6F7743617264696E616C69747928537472696E67292C0A202020206E2055496E74333229",
  )

  cases
end

def w141_literal_row(vector : W141BinaryCase) : Bytes
  w117_bytes("010178#{vector.descriptor_hex}#{vector.payload_hexes.join}")
end

def w141_mutated_row(vector : W141BinaryCase) : Bytes
  w117_bytes("010178#{vector.mutation_descriptor_hex}#{vector.payload_hexes.join}")
end

def w141_read_bytes(path : String, label : String) : Bytes
  w141_assert(File.file?(path) && !File.symlink?(path), "#{label}: missing file or symlink")
  File.open(path, "rb") do |file|
    bytes = Bytes.new(file.size.to_i32)
    file.read_fully(bytes)
    bytes
  end
end

def w141_assert_value(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue, label : String) : Nil
  w141_assert(actual.type.name == expected.type.name, "#{label}: decoded type #{actual.type.name.inspect} != literal #{expected.type.name.inspect}")
  w141_assert(actual.type.tag == expected.type.tag, "#{label}: decoded tag differs from literal")
  w141_assert(actual.is_null? == expected.is_null?, "#{label}: NULL state differs from literal")
  w141_assert(actual.child_count == expected.child_count, "#{label}: child count differs from literal")

  if actual.child_count > 0
    actual.child_count.times do |index|
      w141_assert_value(actual.child_at(index), expected.child_at(index), "#{label}[#{index}]")
    end
  elsif !actual.is_null?
    w117_assert_bytes(actual.bytes, expected.bytes, "#{label} scalar bytes")
  end
end

def w141_check_native_certificate(probe_root : String, vector : W141BinaryCase) : Bytes
  path = File.join(probe_root, "results", vector.label, "binary-type-row.bin")
  actual = w141_read_bytes(path, "#{vector.label} direct native row")
  expected = w141_literal_row(vector)
  w117_assert_bytes(actual, expected, "#{vector.label} direct ClickHouse row vs independent literal")

  header = w117_bytes("010178")
  w117_assert_bytes(actual[0, header.size], header, "#{vector.label} native name header")
  descriptor = w117_bytes(vector.descriptor_hex)
  start = header.size
  w117_assert_bytes(actual[start, descriptor.size], descriptor, "#{vector.label} native type descriptor")
  type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
  w141_assert(type.name == vector.schema, "#{vector.label}: library decoded descriptor as #{type.name.inspect}")
  w117_assert_bytes(CrystalClick::BinaryDataTypeCodec.encode(type), descriptor, "#{vector.label} library descriptor round trip")

  cursor = start + descriptor.size
  vector.payload_hexes.each_with_index do |payload_hex, index|
    payload = w117_bytes(payload_hex)
    raw_payload = actual[cursor, payload.size]
    decoded = CrystalClick::BinaryValueCodec.decode_value(type, raw_payload)
    w141_assert_value(decoded, vector.values[index], "#{vector.label} native row #{index}")
    cursor += payload.size
  end
  w141_assert(cursor == actual.size, "#{vector.label}: unexpected trailing bytes after independent row boundaries")
  puts "PASS W141 direct native file decoded against literal: #{vector.label}"
  actual
end

def w141_check_library_writer(vector : W141BinaryCase, output_root : String) : String
  first_value = vector.values.first? || w141_fail("#{vector.label}: library-owned values are empty")
  type = first_value.type
  descriptor = CrystalClick::BinaryDataTypeCodec.encode(type)
  w117_assert_bytes(descriptor, w117_bytes(vector.descriptor_hex), "#{vector.label} library type writer vs literal")

  bodies = [] of String
  vector.values.each_with_index do |value, index|
    value_descriptor = CrystalClick::BinaryDataTypeCodec.encode(value.type)
    w117_assert_bytes(value_descriptor, descriptor, "#{vector.label} library-owned value #{index} type vs factory-owned row type")
    body = CrystalClick::BinaryValueCodec.encode_value(value)
    w117_assert_bytes(body, w117_bytes(vector.payload_hexes[index]), "#{vector.label} library value writer vs literal row #{index}")
    bodies << w117_hex(body)
  end
  encoded_row = w117_bytes("010178#{w117_hex(descriptor)}#{bodies.join}")
  w117_assert_bytes(encoded_row, w141_literal_row(vector), "#{vector.label} full library row vs independent literal")

  path = File.join(output_root, "library-writer", "#{vector.label}.rowbinary-with-names-and-types.bin")
  File.open(path, "wb") { |file| file.write(encoded_row) }
  path
end

def w141_expected_type_name_bytes(vector : W141BinaryCase) : Bytes
  if display_hex = vector.display_type_name_hex
    return w117_bytes(display_hex)
  end

  vector.schema.to_slice
end

def w141_run_reader(binary : String, store : String, schema : String, input_path : String) : Tuple(Bool, String, String)
  args = [
    "local", "--path", store,
    "--input-format", "RowBinaryWithNamesAndTypes",
    "--structure", "x #{schema}",
    "--allow_suspicious_low_cardinality_types=1",
    "--input_format_skip_unknown_fields=0",
    "--input_format_with_names_use_header=1",
    "--input_format_binary_decode_types_in_binary_format=1",
    "--input_format_with_types_use_header=1",
    # Hex keeps multiline native type names (notably named Tuple) on one TSV row.
    "--query", "SELECT hex(toTypeName(x)), hex(formatRow('RowBinary', x)) FROM table FORMAT TSVRaw",
  ]
  output = IO::Memory.new
  error = IO::Memory.new
  status = File.open(input_path, "rb") do |input|
    Process.run(binary, args, input: input, output: output, error: error)
  end
  {status.success?, output.to_s, error.to_s}
end

def w141_assert_reader_rows(output : String, vector : W141BinaryCase, label : String) : Nil
  rows = output.lines.map(&.strip).reject(&.empty?)
  w141_assert(rows.size == vector.payload_hexes.size, "#{label}: stock reader row count #{rows.size} != #{vector.payload_hexes.size}")
  expected_type_name = w141_expected_type_name_bytes(vector)
  vector.payload_hexes.each_with_index do |payload, index|
    fields = rows[index].split('\t')
    w141_assert(fields.size == 2, "#{label}: malformed stock reader row #{rows[index].inspect}")
    actual_type_name = w117_bytes(fields[0])
    w117_assert_bytes(actual_type_name, expected_type_name, "#{label}: native toTypeName bytes")
    w141_assert(fields[1].downcase == payload.downcase, "#{label}: stock row payload differs from independent literal")
  end
end

def w141_store(output_root : String, label : String) : String
  path = File.join(output_root, "stores", label)
  Dir.mkdir(path)
  path
end

def w141_check_stock_consumer(binary : String, output_root : String, vector : W141BinaryCase, input_path : String) : Nil
  store = w141_store(output_root, "reader-#{vector.label}")
  ok, output, error = w141_run_reader(binary, store, vector.schema, input_path)
  w141_assert(ok, "#{vector.label}: pinned ClickHouse rejected library-owned binary row: #{error.strip}")
  w141_assert_reader_rows(output, vector, "#{vector.label} library bytes -> stock input")
  puts "PASS W141 stock input of library bytes with binary type/name header checks: #{vector.label}"
end

def w141_check_header_mutations(binary : String, output_root : String, vector : W141BinaryCase, mutated_row : Bytes) : Nil
  path = File.join(output_root, "library-writer", "#{vector.label}.mutated-type-header.bin")
  File.open(path, "wb") { |file| file.write(mutated_row) }
  store = w141_store(output_root, "reject-type-header-#{vector.label}")
  ok, output, error = w141_run_reader(binary, store, vector.schema, path)
  w141_assert(!ok, "#{vector.label}: stock input accepted a header with LC removed under the nominal LC schema; output=#{output.inspect}")
  w141_assert(error.includes?("Type of 'x' must be"), "#{vector.label}: type-header negative control did not fail at the source type-header check: #{error.strip}")
  puts "PASS W141 stock type-header negative control (LC tag removed): #{vector.label}"
end

def w141_check_name_mutation(binary : String, output_root : String, vector : W141BinaryCase, literal_row : Bytes) : Nil
  return unless vector.label == "lc-string"

  mutated = literal_row.dup
  mutated[2] = 'y'.ord.to_u8
  path = File.join(output_root, "library-writer", "lc-string.mutated-column-name.bin")
  File.open(path, "wb") { |file| file.write(mutated) }
  store = w141_store(output_root, "reject-column-name")
  ok, output, error = w141_run_reader(binary, store, vector.schema, path)
  w141_assert(!ok, "stock input accepted column-name y under explicit x schema; output=#{output.inspect}")
  w141_assert(error.includes?("Unknown field found in format header:"), "column-name negative control failed without the source format-header diagnostic: #{error.strip}")
  puts "PASS W141 stock column-name header negative control"
end

def w141_check_runtime(binary : String, store : String) : Nil
  version_output = IO::Memory.new
  version_status = Process.run(binary, ["local", "--version"], output: version_output, error: Process::Redirect::Close)
  w141_assert(version_status.success?, "pinned ClickHouse version command failed")
  w141_assert(version_output.to_s.strip == W141_CLICKHOUSE_VERSION, "pinned ClickHouse version mismatch")

  hash_output = IO::Memory.new
  hash_status = Process.run("shasum", ["-a", "256", binary], output: hash_output, error: Process::Redirect::Close)
  w141_assert(hash_status.success? && hash_output.to_s.split(' ').first? == W141_RUNTIME_SHA256, "pinned ClickHouse executable SHA-256 mismatch")

  identity_query = "SELECT concat(name, '=', value) FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw"
  identity = w117_run(binary, store, identity_query).lines.map(&.strip).reject(&.empty?)
  expected = ["GIT_HASH=#{W141_BUILD_HASH}", "VERSION_GITHASH=#{W141_BUILD_HASH}"]
  w141_assert(identity == expected, "pinned ClickHouse build identity mismatch: #{identity.inspect}")
  puts "PASS W141 runtime identity: source=#{W141_SOURCE_REVISION} ClickHouse=#{W141_CLICKHOUSE_VERSION} sha256=#{W141_RUNTIME_SHA256} build=#{W141_BUILD_HASH}"
end

def w141_validate_roots : Tuple(String, String)
  probe_root_arg = ENV["W141_PROBE_ROOT"]? || w141_fail("W141_PROBE_ROOT is required")
  output_root_arg = ENV["W141_CHECK_ROOT"]? || w141_fail("W141_CHECK_ROOT is required")
  w141_assert(File.directory?(probe_root_arg) && !File.symlink?(probe_root_arg), "W141_PROBE_ROOT must be an existing non-symlink directory")
  probe_root = File.realpath(probe_root_arg)
  w141_assert(probe_root.starts_with?("/private/tmp/crystal-click-object-low-cardinality-w141."), "W141 probe evidence root is outside its pinned prefix")
  w141_assert(File.directory?(output_root_arg) && !File.symlink?(output_root_arg), "W141_CHECK_ROOT must be an existing non-symlink directory")
  output_root = File.realpath(output_root_arg)
  w141_assert(output_root == File.join(probe_root, "binary-oracle"), "W141_CHECK_ROOT must be the new binary-oracle child of the retained probe root")
  w141_assert(Dir.empty?(File.join(output_root, "library-writer")), "W141 library-writer output directory must be fresh and empty")
  w141_assert(Dir.empty?(File.join(output_root, "stores")), "W141 stock input stores directory must be fresh and empty")

  run_record_path = File.join(probe_root, "results", "run.txt")
  record = File.read(run_record_path)
  w141_assert(record.lines.any? { |line| line.strip == "source_reference_revision=#{W141_SOURCE_REVISION}" }, "W141 source reference revision differs from retained native evidence")
  w141_assert(record.lines.any? { |line| line.strip == "runtime_sha256=#{W141_RUNTIME_SHA256}" }, "W141 runtime SHA differs from retained native evidence")
  w141_assert(record.lines.any? { |line| line.strip == "runtime_version=#{W141_CLICKHOUSE_VERSION}" }, "W141 runtime version differs from retained native evidence")
  {probe_root, output_root}
end

def w141_main : Nil
  probe_root, output_root = w141_validate_roots
  binary = ENV["CLICKHOUSE_BIN"]? || w141_fail("CLICKHOUSE_BIN is required")
  store = w141_store(output_root, "identity")
  w141_check_runtime(binary, store)

  cases = w141_cases
  cases.each do |vector|
    native_row = w141_check_native_certificate(probe_root, vector)
    library_path = w141_check_library_writer(vector, output_root)
    library_row = w141_read_bytes(library_path, "#{vector.label} library-owned row")
    w117_assert_bytes(library_row, native_row, "#{vector.label} library writer vs retained direct native bytes")
    w141_check_stock_consumer(binary, output_root, vector, library_path)
    w141_check_header_mutations(binary, output_root, vector, w141_mutated_row(vector))
    w141_check_name_mutation(binary, output_root, vector, w141_literal_row(vector))
  end
  puts "PASS W141 bounded bidirectional logical-row oracle: #{cases.size} direct native certificates, #{cases.size} library-owned stock-input vectors, descriptor/name negative controls"
end

w141_main
