# W119 extends the hand-authored W117 scalar literals to the remaining fixed-
# width binary scalar repertoire. Stock writer output is checked against
# independent literals; locally produced bytes are then read and re-emitted
# under a declared schema, not a schema inferred from the binary header.
require "./check_binary_w117"

W119_VERSION         = "26.10.1.1201"
W119_BUILD_HASH      = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W119_SOURCE_REVISION = "0c68f01a75a913b1aa5e132b41a80642260c3009"

class W119Mismatch < Exception
end

struct W119Normalization
  getter name : String
  getter schema_name : String
  getter input_descriptor_hex : String
  getter payload_hex : String
  getter canonical_descriptor_hex : String

  def initialize(@name : String, @schema_name : String,
                 @input_descriptor_hex : String, @payload_hex : String,
                 @canonical_descriptor_hex : String)
  end
end

def w119_fail(message : String) : NoReturn
  raise W119Mismatch.new(message)
end

def w119_require(condition : Bool, message : String) : Nil
  w119_fail(message) unless condition
end

def w119_add(vectors : Array(W117Vector), name : String,
             type : CrystalClick::BinaryDataType, schema_name : String,
             descriptor_hex : String, payload_hex : String,
             sql_expression : String? = nil) : Nil
  value = CrystalClick::BinaryValue.fixed(type, w117_bytes(payload_hex))
  vectors << W117Vector.new(name, type, schema_name, descriptor_hex,
    payload_hex, sql_expression, value)
end

def w119_vectors : Array(W117Vector)
  vectors = [] of W117Vector

  w119_add(vectors, "date_epoch_plus_one", CrystalClick::BinaryDataType.primitive("Date"),
    "Date", "0f", "0100", "toDate('1970-01-02')")
  w119_add(vectors, "date32_epoch_minus_one", CrystalClick::BinaryDataType.primitive("Date32"),
    "Date32", "10", "ffffffff", "toDate32('1969-12-31')")

  w119_add(vectors, "datetime_implicit", CrystalClick::BinaryDataType.datetime,
    "DateTime", "11", "01000000", "toDateTime(1)")
  w119_add(vectors, "datetime_explicit_utc", CrystalClick::BinaryDataType.datetime("UTC"),
    "DateTime('UTC')", "1203555443", "01000000", "toDateTime(1, 'UTC')")
  w119_add(vectors, "datetime_explicit_new_york", CrystalClick::BinaryDataType.datetime("America/New_York"),
    "DateTime('America/New_York')", "1210416d65726963612f4e65775f596f726b", "01000000",
    "toDateTime(1, 'America/New_York')")

  w119_add(vectors, "datetime64_implicit_scale_0", CrystalClick::BinaryDataType.datetime64(0),
    "DateTime64(0)", "1300", "0200000000000000", "toDateTime64(2, 0)")
  w119_add(vectors, "datetime64_explicit_utc_scale_3", CrystalClick::BinaryDataType.datetime64(3, "UTC"),
    "DateTime64(3, 'UTC')", "140303555443", "e204000000000000",
    "toDateTime64(1.25, 3, 'UTC')")
  w119_add(vectors, "datetime64_explicit_new_york_scale_3", CrystalClick::BinaryDataType.datetime64(3, "America/New_York"),
    "DateTime64(3, 'America/New_York')", "140310416d65726963612f4e65775f596f726b", "e204000000000000",
    "toDateTime64(1.25, 3, 'America/New_York')")
  w119_add(vectors, "datetime64_implicit_scale_9", CrystalClick::BinaryDataType.datetime64(9),
    "DateTime64(9)", "1309", "002f685900000000", "toDateTime64(1.5, 9)")

  w119_add(vectors, "time_twelve_thirty_four", CrystalClick::BinaryDataType.primitive("Time"),
    "Time", "32", "f0b00000", "toTime('12:34:56')")
  w119_add(vectors, "time64_scale_0", CrystalClick::BinaryDataType.time64(0),
    "Time64(0)", "3400", "0100000000000000", "toTime64('00:00:01', 0)")
  w119_add(vectors, "time64_scale_3", CrystalClick::BinaryDataType.time64(3),
    "Time64(3)", "3403", "952cb30200000000", "toTime64('12:34:56.789', 3)")
  w119_add(vectors, "time64_scale_9_one_nanosecond", CrystalClick::BinaryDataType.time64(9),
    "Time64(9)", "3409", "0100000000000000", "toTime64('00:00:00.000000001', 9)")

  w119_add(vectors, "decimal32_negative_12_34", CrystalClick::BinaryDataType.decimal(32, 9, 2),
    "Decimal(9, 2)", "190902", "2efbffff", "toDecimal32('-12.34', 2)")
  w119_add(vectors, "decimal64_negative_12_34", CrystalClick::BinaryDataType.decimal(64, 18, 2),
    "Decimal(18, 2)", "1a1202", "2efbffffffffffff", "toDecimal64('-12.34', 2)")
  w119_add(vectors, "decimal128_negative_12_34", CrystalClick::BinaryDataType.decimal(128, 38, 2),
    "Decimal(38, 2)", "1b2602", "2efbffffffffffffffffffffffffffff", "toDecimal128('-12.34', 2)")
  w119_add(vectors, "decimal256_negative_12_34", CrystalClick::BinaryDataType.decimal(256, 76, 2),
    "Decimal(76, 2)", "1c4c02",
    "2efbffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "toDecimal256('-12.34', 2)")

  # SQL's Decimal(P,S) factory selects the narrowest storage family. This
  # direct binary case intentionally retains a wider tag and S>P; no stock SQL
  # schema route is used as evidence for this nominal width.
  w119_add(vectors, "decimal256_p1_s9_source_only", CrystalClick::BinaryDataType.decimal(256, 1, 9),
    "Decimal(1, 9)", "1c0109", "0100000000000000000000000000000000000000000000000000000000000000")

  w119_add(vectors, "uuid_asymmetric_halves", CrystalClick::BinaryDataType.primitive("UUID"),
    "UUID", "1d", "7766554433221100ffeeddccbbaa9988",
    "toUUID('00112233-4455-6677-8899-aabbccddeeff')")
  w119_add(vectors, "ipv4_one_two_three_four", CrystalClick::BinaryDataType.primitive("IPv4"),
    "IPv4", "28", "04030201", "toIPv4('1.2.3.4')")
  w119_add(vectors, "ipv6_asymmetric", CrystalClick::BinaryDataType.primitive("IPv6"),
    "IPv6", "29", "20010db8000000000000000000000001", "toIPv6('2001:db8::1')")

  enum8_type = CrystalClick::BinaryDataType.enum8([
    {"pos", 7_i16}, {"zero", 0_i16}, {"neg", -7_i16},
  ])
  w119_add(vectors, "enum8_scrambled_declaration", enum8_type,
    "Enum8('neg' = -7, 'zero' = 0, 'pos' = 7)",
    "1703036e6567f9047a65726f0003706f7307", "f9",
    "CAST(-7, 'Enum8(''pos'' = 7, ''zero'' = 0, ''neg'' = -7)')")

  enum16_type = CrystalClick::BinaryDataType.enum16([
    {"pos", 300_i16}, {"zero", 0_i16}, {"neg", -300_i16},
  ])
  w119_add(vectors, "enum16_scrambled_declaration", enum16_type,
    "Enum16('neg' = -300, 'zero' = 0, 'pos' = 300)",
    "1803036e6567d4fe047a65726f000003706f732c01", "d4fe",
    "CAST(-300, 'Enum16(''pos'' = 300, ''zero'' = 0, ''neg'' = -300)')")

  vectors
end

def w119_normalizations : Array(W119Normalization)
  [
    W119Normalization.new("datetime_empty_zone_to_implicit_local_only", "DateTime",
      "1200", "01000000", "11"),
    W119Normalization.new("datetime64_empty_zone_to_implicit_local_only", "DateTime64(3)",
      "140300", "e204000000000000", "1303"),
    W119Normalization.new("enum8_unsorted_table_to_code_order_local_only", "Enum8('neg' = -7, 'zero' = 0, 'pos' = 7)",
      "170303706f7307047a65726f00036e6567f9", "7f",
      "1703036e6567f9047a65726f0003706f7307"),
  ] of W119Normalization
end

def w119_assert_local_vectors(vectors : Array(W117Vector)) : Nil
  w119_require(vectors.size == 23, "W119 literal vector inventory differs: #{vectors.size}/23")
  w119_require(vectors.count(&.stock_eligible?) == 22,
    "W119 stock-eligible vector inventory differs: #{vectors.count(&.stock_eligible?)}/22")

  vectors.each do |vector|
    descriptor = w117_bytes(vector.descriptor_hex)
    payload = w117_bytes(vector.payload_hex)
    w119_require(vector.type.name == vector.schema_name,
      "#{vector.name}: constructed nominal type name differs from #{vector.schema_name}")
    w117_assert_bytes(CrystalClick::BinaryDataTypeCodec.encode(vector.type), descriptor,
      "#{vector.name} type encode")

    decoded_type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
    w119_require(decoded_type == vector.type,
      "#{vector.name}: descriptor decode lost nominal tag or parameters")
    w117_assert_bytes(CrystalClick::BinaryDataTypeCodec.encode(decoded_type), descriptor,
      "#{vector.name} type decode/encode")

    envelope = descriptor + payload
    w117_assert_bytes(CrystalClick::BinaryValueCodec.encode(vector.value), envelope,
      "#{vector.name} typed-value encode")
    decoded_envelope = CrystalClick::BinaryValueCodec.decode(envelope)
    w119_require(decoded_envelope.type == vector.type,
      "#{vector.name}: typed envelope decode lost nominal type identity")
    w117_assert_bytes(CrystalClick::BinaryValueCodec.encode(decoded_envelope), envelope,
      "#{vector.name} typed-value decode/encode")

    decoded_payload = CrystalClick::BinaryValueCodec.decode_value(vector.type, payload)
    w119_require(decoded_payload.type == vector.type,
      "#{vector.name}: known-type payload decode lost nominal type identity")
    w117_assert_bytes(CrystalClick::BinaryValueCodec.encode_value(decoded_payload), payload,
      "#{vector.name} known-type decode/encode")
  end

  decimal32_small = CrystalClick::BinaryDataType.decimal(32, 1, 9)
  decimal256_small = CrystalClick::BinaryDataType.decimal(256, 1, 9)
  w119_require(decimal32_small.name == decimal256_small.name,
    "small-precision decimal identity discriminator no longer has matching display names")
  w119_require(decimal32_small != decimal256_small,
    "Decimal wire width was lost from nominal identity when names match")
  w119_require(Set{decimal32_small, decimal256_small}.size == 2,
    "Decimal wire width was lost from hash/equality set identity")

  puts "PASS W119 hand-authored fixed-width scalar vectors: #{vectors.size} types/values"
end

def w119_assert_normalizations(normalizations : Array(W119Normalization)) : Nil
  normalizations.each do |item|
    input_descriptor = w117_bytes(item.input_descriptor_hex)
    payload = w117_bytes(item.payload_hex)
    canonical_descriptor = w117_bytes(item.canonical_descriptor_hex)

    decoded_type = CrystalClick::BinaryDataTypeCodec.decode(input_descriptor)
    w119_require(decoded_type.name == item.schema_name,
      "#{item.name}: noncanonical descriptor has wrong normalized name")
    w117_assert_bytes(CrystalClick::BinaryDataTypeCodec.encode(decoded_type), canonical_descriptor,
      "#{item.name} type canonicalization")

    decoded_value = CrystalClick::BinaryValueCodec.decode(input_descriptor + payload)
    expected_envelope = canonical_descriptor + payload
    w117_assert_bytes(CrystalClick::BinaryValueCodec.encode(decoded_value), expected_envelope,
      "#{item.name} typed-envelope canonicalization")
  end
  puts "PASS W119 local timezone and Enum descriptor canonicalization: #{normalizations.size} cases"
end

def w119_expect_corrupt(label : String, &block : ->) : Nil
  begin
    yield
  rescue error : CrystalClick::CorruptPartError
    puts "PASS W119 corruption control: #{label}"
    return
  rescue error
    w119_fail("#{label}: wrong rejection class #{error.class}")
  end
  w119_fail("corruption control accepted #{label}")
end

def w119_assert_corruption_controls(vectors : Array(W117Vector)) : Nil
  w119_expect_corrupt("DateTime64 scale 10") do
    CrystalClick::BinaryDataTypeCodec.decode(w117_bytes("130a"))
  end
  w119_expect_corrupt("Time64 scale 10") do
    CrystalClick::BinaryDataTypeCodec.decode(w117_bytes("340a"))
  end
  w119_expect_corrupt("truncated explicit DateTime zone") do
    CrystalClick::BinaryDataTypeCodec.decode(w117_bytes("12034d"))
  end
  w119_expect_corrupt("truncated explicit DateTime64 zone") do
    CrystalClick::BinaryDataTypeCodec.decode(w117_bytes("14030355"))
  end
  w119_expect_corrupt("Decimal32 precision zero") do
    CrystalClick::BinaryDataTypeCodec.decode(w117_bytes("190002"))
  end
  w119_expect_corrupt("Decimal32 scale above width maximum") do
    CrystalClick::BinaryDataTypeCodec.decode(w117_bytes("19090a"))
  end
  w119_expect_corrupt("empty Enum8 table") do
    CrystalClick::BinaryDataTypeCodec.decode(w117_bytes("1700"))
  end
  w119_expect_corrupt("duplicate Enum8 numeric code") do
    CrystalClick::BinaryDataTypeCodec.decode(w117_bytes("1702016100016200"))
  end
  w119_expect_corrupt("reserved Time tag 0x33") do
    CrystalClick::BinaryDataTypeCodec.decode(w117_bytes("33"))
  end
  w119_expect_corrupt("reserved Time64 tag 0x35") do
    CrystalClick::BinaryDataTypeCodec.decode(w117_bytes("35"))
  end
  w119_expect_corrupt("truncated UUID body") do
    CrystalClick::BinaryValueCodec.decode_value(CrystalClick::BinaryDataType.primitive("UUID"), w117_bytes("000000000000000000000000000000"))
  end
  w119_expect_corrupt("truncated IPv6 body") do
    CrystalClick::BinaryValueCodec.decode_value(CrystalClick::BinaryDataType.primitive("IPv6"), w117_bytes("20010db80000000000000000000000"))
  end

  enum8 = CrystalClick::BinaryDataType.enum8([{"neg", -7_i16}, {"zero", 0_i16}, {"pos", 7_i16}])
  unknown_code = CrystalClick::BinaryValueCodec.decode_value(enum8, w117_bytes("7f"))
  w117_assert_bytes(CrystalClick::BinaryValueCodec.encode_value(unknown_code), w117_bytes("7f"),
    "Enum8 undeclared raw numeric code")

  # A raw parameter change and a raw payload change must both trip the same
  # bytewise oracle at their exact absolute offsets in a one-column row.
  parameter_vector = vectors.find! { |vector| vector.name == "datetime64_explicit_new_york_scale_3" }
  payload_vector = vectors.find! { |vector| vector.name == "uuid_asymmetric_halves" }
  w119_assert_comparator_negative_control(parameter_vector, 4, "descriptor parameter")
  w119_assert_comparator_negative_control(payload_vector, 4, "scalar payload")
  puts "PASS W119 undeclared raw Enum code remains numeric-only"
end

def w119_assert_comparator_negative_control(vector : W117Vector, offset : Int32, label : String) : Nil
  expected = w117_bytes("010178#{vector.descriptor_hex}#{vector.payload_hex}")
  seeded = expected.dup
  seeded[offset] = seeded[offset] ^ 0x01_u8
  begin
    w117_assert_bytes(seeded, expected, "W119 seeded #{label} mutation")
  rescue error : W117Mismatch
    expected_prefix = "W117 W119 seeded #{label} mutation: byte mismatch at offset #{offset}"
    w119_require((error.message || "").starts_with?(expected_prefix),
      "#{label} comparator control failed at an unexpected offset or for another reason")
    puts "PASS W119 comparator negative control: detected #{label} byte at offset #{offset}"
    return
  end
  w119_fail("row comparator accepted seeded #{label} mutation")
end

def w119_sql_string_literal(value : String) : String
  String.build do |io|
    io << "'"
    value.each_char do |char|
      case char.ord
      when 92 then io << "\\\\"
      when 39 then io << "\\'"
      else         io << char
      end
    end
    io << "'"
  end
end

def w119_stock_read_branch(vector : W117Vector, row : Bytes) : String
  row_hex = w117_hex(row)
  vector_name_literal = w119_sql_string_literal(vector.name)
  structure_literal = w119_sql_string_literal("x #{vector.schema_name}")
  "SELECT #{vector_name_literal} AS vector, toTypeName(x) AS type_name, hex(formatRow('RowBinaryWithNamesAndTypes', x)) AS row_hex FROM format('RowBinaryWithNamesAndTypes', #{structure_literal}, unhex('#{row_hex}'))"
end

def w119_stock_read_query(vectors : Array(W117Vector), rows : Hash(String, Bytes)) : String
  branches = vectors.select(&.stock_eligible?).map do |vector|
    row = rows[vector.name]? || w119_fail("#{vector.name}: missing locally produced stock-reader row")
    w119_stock_read_branch(vector, row)
  end
  w119_require(!branches.empty?, "W119 has no stock-read vectors")
  # This is the schema-directed three-argument format route. It reads local
  # bytes under the declared structure; it does not infer a structure from the
  # binary header.
  "SELECT vector, type_name, row_hex FROM (#{branches.join(" UNION ALL ")}) ORDER BY vector SETTINGS input_format_binary_decode_types_in_binary_format=1, output_format_binary_encode_types_in_binary_format=1, print_pretty_type_names=0 FORMAT TSVRaw"
end

def w119_assert_stock_read_query_rendering(vectors : Array(W117Vector), rows : Hash(String, Bytes)) : Nil
  utc_vector = vectors.find! { |vector| vector.name == "datetime_explicit_utc" }
  enum_vector = vectors.find! { |vector| vector.name == "enum8_scrambled_declaration" }
  query = w119_stock_read_query(vectors, rows)

  utc_structure_literal = w119_sql_string_literal("x #{utc_vector.schema_name}")
  w119_require(utc_structure_literal == "'x DateTime(\\'UTC\\')'",
    "W119 SQL literal escaping changed for DateTime('UTC')")
  utc_branch = w119_stock_read_branch(utc_vector, rows[utc_vector.name])
  w119_require(query.includes?(utc_branch),
    "W119 stock-reader query omitted the escaped DateTime('UTC') declaration")

  enum_structure_literal = w119_sql_string_literal("x #{enum_vector.schema_name}")
  w119_require(enum_structure_literal == "'x Enum8(\\'neg\\' = -7, \\'zero\\' = 0, \\'pos\\' = 7)'",
    "W119 SQL literal escaping changed for Enum8 declaration")
  enum_branch = w119_stock_read_branch(enum_vector, rows[enum_vector.name])
  w119_require(query.includes?(enum_branch),
    "W119 stock-reader query omitted the escaped Enum8 declaration")

  # Exercise both escaping rules on a synthetic query-rendering-only name too;
  # this branch is never sent to ClickHouse.
  probe_name = "probe'\\vector"
  w119_require(w119_sql_string_literal(probe_name) == "'probe\\'\\\\vector'",
    "W119 SQL literal escaping changed for apostrophe/backslash")
  probe_vector = W117Vector.new(probe_name, utc_vector.type, utc_vector.schema_name,
    utc_vector.descriptor_hex, utc_vector.payload_hex, "rendering-only", utc_vector.value)
  probe_branch = w119_stock_read_branch(probe_vector, rows[utc_vector.name])
  w119_require(probe_branch.starts_with?("SELECT 'probe\\'\\\\vector' AS vector"),
    "W119 stock-reader branch did not escape the vector name")

  puts "PASS W119 schema-directed stock-reader query rendering: quoted UTC/Enum and escaped vector names"
end

def w119_qualify_runtime(binary : String, store : String) : Nil
  version = w117_run(binary, store, "SELECT version() FORMAT TSVRaw").strip
  w119_require(version == W119_VERSION, "pinned runtime version mismatch: #{version.inspect}")
  hashes = w117_run(binary, store,
    "SELECT value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  w119_require(!hashes.empty? && hashes.all? { |hash| hash == W119_BUILD_HASH },
    "pinned runtime build hash mismatch: #{hashes.inspect}")
  puts "PASS W119 runtime identity: ClickHouse #{version}, runtime build #{W119_BUILD_HASH}; source reference #{W119_SOURCE_REVISION} is separate"
end

def w119_main : Nil
  binary = ENV["CLICKHOUSE_BIN"]? || w119_fail("CLICKHOUSE_BIN is required")
  store_arg = ENV["W119_STORE"]? || w119_fail("W119_STORE is required")
  test_root_arg = ENV["W119_TEST_ROOT"]? || w119_fail("W119_TEST_ROOT is required")
  test_root, store = w117_validate_test_store(test_root_arg, store_arg)

  vectors = w119_vectors
  normalizations = w119_normalizations
  w119_assert_local_vectors(vectors)
  w119_assert_normalizations(normalizations)
  w119_assert_corruption_controls(vectors)

  stock_vectors = vectors.select(&.stock_eligible?)
  local_rows = {} of String => Bytes
  stock_vectors.each { |vector| local_rows[vector.name] = w117_local_row(vector) }
  w119_assert_stock_read_query_rendering(vectors, local_rows)

  w119_qualify_runtime(binary, store)
  stock_output = w117_run(binary, store, w117_stock_write_query(vectors))
  File.write(File.join(test_root, "stock-writer.tsvraw"), stock_output)
  w117_assert_stock_output(stock_output, vectors)

  stock_read_query = w119_stock_read_query(vectors, local_rows)
  reader_output = w117_run(binary, store, stock_read_query)
  File.write(File.join(test_root, "stock-reader.tsvraw"), reader_output)
  w117_assert_stock_reader(reader_output, vectors, local_rows)
  puts "PASS W119 independent stock writer literals and schema-directed stock read/re-emission"
  puts "NOTE W119 stock timezone cases cover UTC and America/New_York only; pinned-catalog freshness/alias completeness is not claimed"
  puts "NOTE W119 empty-zone/unsorted-Enum canonicalization, undeclared raw Enum numeric payloads, and Decimal256(P=1,S=9) are local/source-only; two-argument inference reparses Decimal(P,S) through the SQL factory and can erase nominal width"
end

w119_main
