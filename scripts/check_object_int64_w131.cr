# W131 declared Int64 Object interoperability oracle.
#
# Four fresh native INSERT profiles are read by the library and copied into an
# independent Atomic catalog. Four library-owned parts cover the full
# String-layout × Dynamic-discriminator matrix when attached to stock ClickHouse.
# Expected signed RowBinary bytes are authored directly from the five Int64
# fixtures; JSON number parsing is never used for expectations.
require "file_utils"
require "json"
require "../src/crystal_click"
require "./w122_bulk_vectors"

class W131Oracle
  class Mismatch < Exception
  end

  VERSION           = "26.10.1.1201"
  BUILD_HASH        = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  FRAME_BYTES       = 16
  DECLARATION       = "JSON(max_dynamic_types=1, max_dynamic_paths=1, i Int64, t String, u UInt64)"
  SETTINGS_BASE     = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, ratio_of_defaults_for_sparse_serialization=1, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version_for_zero_level_parts='map', propagate_types_serialization_versions_to_nested_types=true"
  KEYS              = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
  SIGNED            = [Int64::MIN, -1_i64, 0_i64, 1_i64, Int64::MAX]
  UNSIGNED          = [101_u64, 202_u64, 303_u64, 404_u64, 505_u64]
  TEXT              = ["zero", "a\0b", "λ雪", "é", "終"]
  DYNAMIC           = [11_i64, 22_i64, 33_i64, 44_i64, 55_i64]
  ROWS_PER_MARK     = [2_u64, 2_u64, 1_u64]
  PROFILES          = [
    {"single_stream", CrystalClick::BinaryBulkProfile.single_stream},
    {"with_size_stream", CrystalClick::BinaryBulkProfile.with_size_stream},
  ]
  MODES = [
    {"basic", CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE},
    {"compact", CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE},
  ]
  NATIVE_JSON_ROWS = [
    %({"pk":1,"payload":{"i":-9223372036854775808,"t":"zero","u":101,"d":11,"spill":"alpha"}}),
    %({"pk":2,"payload":{"i":-1,"t":"a\\u0000b","u":202,"d":22}}),
    %({"pk":3,"payload":{"i":0,"t":"λ雪","u":303,"d":33}}),
    %({"pk":4,"payload":{"i":1,"t":"é","u":404,"d":44}}),
    %({"pk":5,"payload":{"i":9223372036854775807,"t":"終","u":505,"d":55,"spill":"omega"}}),
  ]

  alias Part = NamedTuple(name: String, path: String, rows: UInt64)
  alias CapturedBatch = NamedTuple(
    part_index: Int32,
    part_name: String,
    part_path: String,
    mark_index: Int32,
    mark_row_offset: UInt64,
    part_row_offset: UInt64,
    source_row_offset: UInt64,
    keys: Array(UInt64),
    payload: Array(CrystalClick::ObjectDocument),
  )

  private def fail(message : String) : NoReturn
    raise Mismatch.new(message)
  end

  private def assert(condition : Bool, message : String) : Nil
    fail(message) unless condition
  end

  private def expect_mismatch(label : String, &)
    begin
      yield
    rescue error : Mismatch
      puts "PASS W131 seeded comparator failure: #{label}"
      return
    end
    fail("#{label}: seeded mismatch passed the oracle comparator")
  end

  private def run(binary : String, store : String, query : String, input : IO? = nil) : String
    output = IO::Memory.new
    error = IO::Memory.new
    arguments = ["local", "--path", store, "--query", query]
    status = if input
               Process.run(binary, arguments, input: input, output: output, error: error)
             else
               Process.run(binary, arguments, output: output, error: error)
             end
    raise "ClickHouse local query failed: #{error}\n#{query}" unless status.success?
    output.to_s
  end

  private def run_status(binary : String, arguments : Array(String)) : String
    output = IO::Memory.new
    error = IO::Memory.new
    status = Process.run(binary, arguments, output: output, error: error)
    raise "ClickHouse command failed: #{error}" unless status.success?
    output.to_s
  end

  private def verify_runtime(binary : String, store : String) : Nil
    version = run_status(binary, ["local", "--version"]).strip
    assert(version == "ClickHouse local version #{VERSION} (official build).",
      "unexpected ClickHouse version: #{version.inspect}")
    digest = run_status("shasum", ["-a", "256", binary]).split(' ').first? || ""
    assert(digest == EXECUTABLE_SHA256, "unexpected ClickHouse executable SHA-256")
    build = run(binary, store,
      "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
    assert(build == ["GIT_HASH=#{BUILD_HASH}", "VERSION_GITHASH=#{BUILD_HASH}"],
      "unexpected ClickHouse build identity")
  end

  private def store_child(path : String, store : String, label : String) : String
    real_store = File.realpath(store)
    real_path = File.realpath(path)
    unless real_path.starts_with?(real_store + "/") && !File.symlink?(path)
      fail("#{label}: path escapes isolated store or is a symlink")
    end
    relative = real_path[(real_store.size + 1)..]
    cursor = real_store
    relative.split('/').each do |component|
      cursor = File.join(cursor, component)
      fail("#{label}: symlink in store path") if File.symlink?(cursor)
    end
    real_path
  end

  private def assert_tree(path : String, label : String) : Nil
    assert(Dir.exists?(path) && !File.symlink?(path), "#{label}: unsafe/missing directory")
    Dir.children(path).each do |name|
      child = File.join(path, name)
      assert(!File.symlink?(child), "#{label}: symlink child #{name.inspect}")
      if Dir.exists?(child)
        assert_tree(child, "#{label}/#{name}")
      else
        assert(File.file?(child), "#{label}: non-file child #{name.inspect}")
      end
    end
  end

  private def table_name(label : String) : String
    "w131_#{label.gsub('-', "_")}"
  end

  private def typed_schema : Hash(String, CrystalClick::BinaryDataType)
    {
      "i" => CrystalClick::BinaryDataType.primitive("Int64"),
      "t" => CrystalClick::BinaryDataType.primitive("String"),
      "u" => CrystalClick::BinaryDataType.primitive("UInt64"),
    }
  end

  private def create_table(binary : String, store : String, table : String, profile_name : String, mode : UInt64, label : String) : Nil
    compact = mode == CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE ? 1 : 0
    settings = "#{SETTINGS_BASE}, use_compact_variant_discriminators_serialization=#{compact}, string_serialization_version='#{profile_name}'"
    run(binary, store,
      "CREATE TABLE default.#{table} (pk UInt64, payload #{DECLARATION}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings}")
    actual = run(binary, store,
      "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
    expected = "pk UInt64\npayload #{DECLARATION}\n"
    assert(actual == expected, "#{label}: live columns differ from the independently authored DDL: #{actual.inspect}")
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION)
    assert(schema.declaration == DECLARATION, "#{label}: canonical parser declaration differs from authored DDL")
    assert(schema.typed_paths == typed_schema, "#{label}: typed path roster differs from authored DDL")
  end

  private def table_data_path(binary : String, store : String, table : String, label : String) : String
    path = run(binary, store,
      "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
    store_child(path, store, "#{label} data path")
  end

  private def stock_part(binary : String, store : String, table : String, label : String) : Part
    rows = run(binary, store,
      "SELECT name, path, part_type, toString(rows) FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines
    assert(rows.size == 1, "#{label}: expected exactly one active part, got #{rows.size}")
    fields = rows.first.split('\t')
    assert(fields.size == 4 && fields[2] == "Wide" && fields[3] == KEYS.size.to_s,
      "#{label}: expected one five-row Wide part, got #{rows.first.inspect}")
    path = store_child(fields[1], store, "#{label} part")
    assert_tree(path, "#{label} part")
    assert(File.file?(File.join(path, "checksums.txt")), "#{label}: part lacks checksums.txt")
    {name: fields[0], path: path, rows: KEYS.size.to_u64}
  end

  private def document(index : Int32, signed : Int64? = nil) : CrystalClick::ObjectDocument
    fields = {} of String => CrystalClick::BinaryValue
    fields["i"] = CrystalClick::BinaryValue.int64(signed || SIGNED[index])
    fields["t"] = CrystalClick::BinaryValue.string(TEXT[index])
    fields["u"] = CrystalClick::BinaryValue.uint64(UNSIGNED[index])
    fields["d"] = CrystalClick::BinaryValue.int64(DYNAMIC[index])
    if index == 0
      fields["spill"] = CrystalClick::BinaryValue.string("alpha")
    elsif index == 4
      fields["spill"] = CrystalClick::BinaryValue.string("omega")
    end
    CrystalClick::ObjectDocument.new(fields)
  end

  private def expected_documents : Array(CrystalClick::ObjectDocument)
    Array(CrystalClick::ObjectDocument).new(KEYS.size) { |index| document(index.to_i32) }
  end

  private def granules(documents : Array(CrystalClick::ObjectDocument)) : Array(Array(CrystalClick::ObjectDocument))
    [documents[0, 2], documents[2, 2], documents[4, 1]]
  end

  private def plan : CrystalClick::ObjectDocumentPlan
    int64 = CrystalClick::BinaryDataType.primitive("Int64")
    object = CrystalClick::ObjectStructure.new(["d"] of String)
    dynamics = {"d" => CrystalClick::DynamicStructure.new([int64])} of String => CrystalClick::DynamicStructure
    CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(object, dynamics),
      typed_schema
    )
  end

  private def assert_documents(
    expected : Array(CrystalClick::ObjectDocument),
    actual : Array(CrystalClick::ObjectDocument),
    label : String,
  ) : Nil
    assert(expected.size == actual.size, "#{label}: document count differs")
    expected.each_with_index do |document, row|
      found = actual[row]
      assert(document.paths == found.paths, "#{label}: path roster differs at row #{row}")
      document.paths.each do |path|
        assert(W122BulkVectors.value_equal?(document.value_for(path), found.value_for(path)),
          "#{label}: value differs at row #{row}, path #{path.inspect}")
      end
    end
  end

  private def assert_granules(
    expected : Array(Array(CrystalClick::ObjectDocument)),
    actual : Array(Array(CrystalClick::ObjectDocument)),
    label : String,
  ) : Nil
    assert(expected.size == actual.size, "#{label}: mark count differs")
    expected.each_with_index do |rows, mark|
      assert_documents(rows, actual[mark], "#{label} mark #{mark}")
    end
  end

  private def assert_grid(actual : Array(UInt64), label : String) : Nil
    assert(actual == ROWS_PER_MARK, "#{label}: actual Object mark grid differs: #{actual.inspect}")
  end

  private def assert_default_serializers(serialization : JSON::Any, label : String) : Nil
    info = serialization.as_h
    serializer_columns = info["columns"]?.try(&.as_a) ||
                         raise Mismatch.new("#{label}: serializer columns are missing or malformed")
    # ClickHouse's SerializationInfoByName writer emits entries only for recorded
    # per-column info. getKindStack returns Default when an entry is absent, and
    # ObjectColumnReader likewise validates every present entry while permitting
    # an empty columns list. A present non-Default kind is still rejected.
    serializer_columns.each_with_index do |entry, index|
      kind = entry.as_h["kind"]?.try(&.as_s) ||
             raise Mismatch.new("#{label}: serializer kind is missing or malformed at entry #{index}")
      assert(kind == "Default", "#{label}: serializer kind is not Default at entry #{index}: #{kind.inspect}")
    end
  end

  private def write_u64_le(io : IO, value : UInt64) : Nil
    8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
  end

  private def expected_rowbinary(indices : Array(Int32), signed_values : Array(Int64) = SIGNED) : String
    String.build do |io|
      indices.each do |index|
        write_u64_le(io, KEYS[index])
        # This is independent RowBinary expectation generation: reinterpret
        # the authored Int64 bits and write the stock little-endian contract.
        write_u64_le(io, signed_values[index].unsafe_as(UInt64))
      end
    end
  end

  private def assert_rowbinary(
    actual : String,
    indices : Array(Int32),
    label : String,
    signed_values : Array(Int64) = SIGNED,
  ) : Nil
    expected = expected_rowbinary(indices, signed_values)
    assert(actual.to_slice == expected.to_slice,
      "#{label}: exact signed RowBinary bytes differ; expected #{expected.to_slice.hexstring}, got #{actual.to_slice.hexstring}")
  end

  private def check_output(binary : String, store : String, table : String) : String
    run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  end

  private def assert_check(actual : String, part_name : String, label : String) : Nil
    expected = "#{part_name}\t1\t\n"
    assert(actual == expected, "#{label}: CHECK TABLE row differs: #{actual.inspect}")
  end

  private def expected_sql_line(index : Int32) : String
    "#{KEYS[index]}\t#{UNSIGNED[index]}\t#{SIGNED[index]}\t#{TEXT[index].to_slice.hexstring.upcase}\t#{DYNAMIC[index]}\tInt64"
  end

  private def assert_sql_rows(actual : String, indices : Array(Int32), label : String) : Nil
    lines = actual.lines.map(&.chomp)
    expected = indices.map { |index| expected_sql_line(index) }
    assert(lines == expected,
      "#{label}: exact typed SQL rows differ; expected #{expected.inspect}, got #{lines.inspect}")
  end

  private def assert_stock_sql(
    binary : String,
    store : String,
    table : String,
    part_name : String,
    label : String,
  ) : {String, String}
    check = check_output(binary, store, table)
    assert_check(check, part_name, "#{label} CHECK TABLE")

    projection = "pk, payload.u, payload.i, hex(payload.t), payload.d, dynamicType(payload.d)"
    full_sql = run(binary, store,
      "SELECT #{projection} FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw")
    all_indices = [0, 1, 2, 3, 4]
    assert_sql_rows(full_sql, all_indices, "#{label} full SQL")
    selected_sql = run(binary, store,
      "SELECT #{projection} FROM default.#{table} WHERE pk >= 3 AND pk <= 4 ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw")
    selected_indices = [2, 3]
    assert_sql_rows(selected_sql, selected_indices, "#{label} PK 3..4 SQL")

    full_binary = run(binary, store,
      "SELECT pk, payload.i FROM default.#{table} ORDER BY pk FORMAT RowBinary")
    assert_rowbinary(full_binary, all_indices, "#{label} full RowBinary")
    selected_binary = run(binary, store,
      "SELECT pk, payload.i FROM default.#{table} WHERE pk >= 3 AND pk <= 4 ORDER BY pk FORMAT RowBinary")
    assert_rowbinary(selected_binary, selected_indices, "#{label} PK RowBinary")
    {check, full_binary}
  end

  private def read_u64_le(bytes : Bytes, offset : Int32) : UInt64
    assert(offset >= 0 && offset <= bytes.size - 8, "truncated Dynamic discriminator mode header")
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end

  private def assert_part_profile(
    part : Part,
    schema : CrystalClick::ObjectDocumentSchema,
    profile : CrystalClick::BinaryBulkProfile,
    mode : UInt64,
    label : String,
  ) : {Array(UInt64), Array(Int32)}
    codec = File.read(File.join(part[:path], "default_compression_codec.txt")).strip
    assert(codec == "CODEC(LZ4)", "#{label}: actual part codec differs from LZ4: #{codec.inspect}")
    assert(File.file?(File.join(part[:path], "primary.idx")) && !File.exists?(File.join(part[:path], "primary.cidx")),
      "#{label}: expected a plain primary.idx")
    basenames = Dir.children(part[:path])
    assert(basenames.any?(&.ends_with?(".mrk2")), "#{label}: no plain mark files found")
    assert(basenames.none?(&.ends_with?(".cmrk2")), "#{label}: compressed mark file found")

    serialization = JSON.parse(File.read(File.join(part[:path], "serialization.json")))
    assert_default_serializers(serialization, "#{label} actual part")

    reader = CrystalClick::ObjectColumnReader.open(part[:path], "payload", schema)
    assert(reader.row_count == KEYS.size.to_u64, "#{label}: Object reader row count differs")
    assert(reader.ordinary_profile == profile, "#{label}: actual ordinary String profile differs")
    assert(reader.source_declaration == DECLARATION, "#{label}: source DDL bytes differ from authored declaration")
    grid = reader.mark_row_counts
    assert_grid(grid, "#{label} ObjectColumnReader")

    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      part[:path],
      "payload",
      schema.typed_paths,
      reader.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream,
      true
    )
    object = descriptor.plan.structures.object
    assert(object.version == 4_u64 && object.shared_data_version == 0_u64 && object.bucket_count == 1_u64,
      "#{label}: actual Object structure is not V3 with one shared MAP bucket")
    assert(descriptor.plan.structures.dynamic_count == 1 && object.dynamic_paths == ["d"],
      "#{label}: actual Dynamic path roster differs")
    assert(descriptor.plan.typed_paths == typed_schema, "#{label}: actual typed schema plan differs")
    dynamics = descriptor.plan.structures.dynamics
    assert(dynamics["d"].types == [CrystalClick::BinaryDataType.primitive("Int64")],
      "#{label}: actual Dynamic arm differs from Int64")

    physical = CrystalClick::ObjectDocumentPhysicalPlan.new(
      "payload", descriptor.plan, reader.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream
    )
    discriminator_name = CrystalClick::StreamName.hash(physical.discriminator_stream("d")) + ".bin"
    discriminator_bytes = CrystalClick::PartStreamSource.new(part[:path]).read_all(discriminator_name)
    actual_mode = read_u64_le(discriminator_bytes, 0)
    assert(actual_mode == mode, "#{label}: actual Dynamic discriminator mode differs: #{actual_mode}")

    checksums = CrystalClick::PartChecksums.open(part[:path])
    primary = CrystalClick::PrimaryKeyIndex.open(part[:path], grid.size, checksums, verify_recorded_hash: true)
    assert(primary.keys == [1_u64, 3_u64, 5_u64, 5_u64],
      "#{label}: actual primary index keys/sentinel differ: #{primary.keys.inspect}")
    schedule = primary.candidate_marks(4_u64, 4_u64)
    assert(schedule == [1_i32], "#{label}: actual PK=4 candidate schedule differs: #{schedule.inspect}")
    {grid, schedule}
  end

  private def object_reader(part : Part, schema : CrystalClick::ObjectDocumentSchema, label : String) : Nil
    reader = CrystalClick::ObjectColumnReader.open(part[:path], "payload", schema)
    expected = granules(expected_documents)
    grid = reader.mark_row_counts
    assert_grid(grid, "#{label} ObjectColumnReader")
    assert_granules(expected, reader.read_marks(0, grid.size), "#{label} ObjectColumnReader full")
    assert_granules([expected[1]], reader.read_marks(1, 1), "#{label} ObjectColumnReader middle mark")
    assert_granules([] of Array(CrystalClick::ObjectDocument), reader.read_marks(grid.size, 0),
      "#{label} ObjectColumnReader zero marks")

    assert_granules(expected, CrystalClick::ObjectDocumentFileReader.read(
      part[:path], "payload", schema.typed_paths,
      first_mark: 0, mark_count: grid.size,
      profile: reader.ordinary_profile,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      hashed: true,
      limits: CrystalClick::BinaryCodecLimits.default,
      transport_limits: CrystalClick::CompressedStreamLimits.new
    ), "#{label} ObjectDocumentFileReader full")
    assert_granules([expected[1]], CrystalClick::ObjectDocumentFileReader.read(
      part[:path], "payload", schema.typed_paths,
      first_mark: 1, mark_count: 1,
      profile: reader.ordinary_profile,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      hashed: true,
      limits: CrystalClick::BinaryCodecLimits.default,
      transport_limits: CrystalClick::CompressedStreamLimits.new
    ), "#{label} ObjectDocumentFileReader middle mark")
    assert_granules([] of Array(CrystalClick::ObjectDocument), CrystalClick::ObjectDocumentFileReader.read(
      part[:path], "payload", schema.typed_paths,
      first_mark: grid.size, mark_count: 0,
      profile: reader.ordinary_profile,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      hashed: true,
      limits: CrystalClick::BinaryCodecLimits.default,
      transport_limits: CrystalClick::CompressedStreamLimits.new
    ), "#{label} ObjectDocumentFileReader zero marks")
  end

  private def catalog_root(root : String, label : String, table_number : Int32, part : Part) : {root: String, part_path: String}
    catalog = File.join(root, "catalog", label)
    assert(!File.exists?(catalog) && !File.symlink?(File.dirname(catalog)), "#{label}: catalog path occupied or unsafe")
    metadata = File.join(catalog, "metadata")
    FileUtils.mkdir_p(metadata)
    FileUtils.mkdir_p(File.join(catalog, "store"))

    database_uuid = "13100000-0000-4000-8000-000000000001"
    table_uuid = "13110000-0000-4000-8000-00000000000#{table_number}"
    File.write(File.join(metadata, "lab.sql"),
      "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
    database_dir = File.join(catalog, "store", database_uuid[0, 3], database_uuid)
    FileUtils.mkdir_p(database_dir)
    File.write(File.join(database_dir, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{DECLARATION}\n)\nENGINE = MergeTree\nORDER BY pk\n")

    table_dir = File.join(catalog, "store", table_uuid[0, 3], table_uuid)
    FileUtils.mkdir_p(table_dir)
    File.write(File.join(table_dir, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_dir, "detached"))
    destination = File.join(table_dir, part[:name])
    FileUtils.cp_r(part[:path], destination)
    assert_tree(destination, "#{label} copied catalog part")
    {root: catalog, part_path: File.realpath(destination)}
  end

  private def catalog_values(catalog_root : String, label : String) : Nil
    selection = CrystalClick::OfflineCatalog.open(catalog_root)["lab"]["events"]["payload"]
    values = selection.values.map(&.as(CrystalClick::ObjectDocument))
    assert_documents(expected_documents, values, "#{label} OfflineCatalog.values")
    owned_bytes = values[1].value_for("t").bytes
    owned_bytes[0] = 'X'.ord.to_u8
    assert(values[1].value_for("t").as_string == "a\0b",
      "#{label}: mutating a detached String byte snapshot changed the returned document")
    values.clear
    again = selection.values.map(&.as(CrystalClick::ObjectDocument))
    assert_documents(expected_documents, again, "#{label} owned re-materialization")
  end

  private def capture(batch : CrystalClick::WidePartTableBatch) : CapturedBatch
    {
      part_index:        batch.part_index,
      part_name:         batch.part_name,
      part_path:         batch.part_path,
      mark_index:        batch.mark_index,
      mark_row_offset:   batch.mark_row_offset,
      part_row_offset:   batch.part_row_offset,
      source_row_offset: batch.source_row_offset,
      keys:              batch.values_for("pk").to_a,
      payload:           batch.object_documents_for("payload").to_a,
    }
  end

  private def assert_batches(
    actual : Array(CapturedBatch),
    part_name : String,
    part_path : String,
    mark_indices : Array(Int32),
    mark_offsets : Array(UInt64),
    part_offsets : Array(UInt64),
    expected_keys : Array(Array(UInt64)),
    label : String,
  ) : Nil
    count = expected_keys.size
    assert(actual.size == count && mark_indices.size == count && mark_offsets.size == count && part_offsets.size == count,
      "#{label}: callback count differs")
    documents = expected_documents
    count.times do |index|
      batch = actual[index]
      assert(batch[:part_index] == 0_i32 && batch[:part_name] == part_name && batch[:part_path] == part_path,
        "#{label}: part provenance differs at callback #{index}")
      assert(batch[:mark_index] == mark_indices[index] && batch[:mark_row_offset] == mark_offsets[index],
        "#{label}: physical mark location differs at callback #{index}")
      assert(batch[:part_row_offset] == part_offsets[index] && batch[:source_row_offset] == part_offsets[index],
        "#{label}: table row offset differs at callback #{index}")
      assert(batch[:keys] == expected_keys[index], "#{label}: key rows differ at callback #{index}: #{batch[:keys].inspect}")
      expected = batch[:keys].map { |key| documents[key.to_i - 1] }
      assert_documents(expected, batch[:payload], "#{label} callback #{index}")
    end
  end

  private def assert_table_delivery(catalog_root : String, expected_part_path : String, part : Part, label : String) : Nil
    table = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
    resolved = table.resolved_scan_parts
    assert(resolved.map(&.name) == [part[:name]], "#{label}: table catalog part inventory differs")
    resolved_path = resolved[0].path
    assert(resolved_path == expected_part_path,
      "#{label}: catalog resolved part differs from the independently copied destination")

    full = [] of CapturedBatch
    table.scan_typed(["pk", "payload"], batch_rows: 2) do |batch|
      assert(batch.column_names == ["pk", "payload"], "#{label}: typed table changed caller column order")
      full << capture(batch)
      nil
    end
    assert_batches(full, part[:name], resolved_path,
      [0_i32, 1_i32, 2_i32], [0_u64, 0_u64, 0_u64], [0_u64, 2_u64, 4_u64],
      [[1_u64, 2_u64], [3_u64, 4_u64], [5_u64]], "#{label} full table scan")

    window = [] of CapturedBatch
    table.scan_typed_window(["pk", "payload"], 1_u64, max_rows: 3) do |batch|
      window << capture(batch)
      nil
    end
    assert_batches(window, part[:name], resolved_path,
      [0_i32, 1_i32], [1_u64, 0_u64], [1_u64, 2_u64],
      [[2_u64], [3_u64, 4_u64]], "#{label} physical window")

    candidates = [] of CapturedBatch
    table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 4_u64, upper_bound: 4_u64) do |batch|
      candidates << capture(batch)
      nil
    end
    candidate_schedule = candidates.map(&.[:mark_index])
    assert(candidate_schedule == [1_i32], "#{label}: table candidate callback schedule differs from inspected PK index")
    assert_batches(candidates, part[:name], resolved_path,
      [1_i32], [0_u64], [2_u64], [[3_u64, 4_u64]], "#{label} whole PK candidate granule")

    candidate_rows = candidates.sum(&.[:keys].size)
    assert(candidate_rows == 2, "#{label}: PK=4 candidate did not retain the complete physical granule")
    residual_keys = [] of UInt64
    residual_documents = [] of CrystalClick::ObjectDocument
    rejected_keys = [] of UInt64
    candidates.each do |batch|
      batch[:keys].each_with_index do |key, row|
        if key == 4_u64
          residual_keys << key
          residual_documents << batch[:payload][row]
        else
          rejected_keys << key
        end
      end
    end
    assert(residual_keys == [4_u64] && rejected_keys == [3_u64],
      "#{label}: exact PK residual did not separate kept row 4 from candidate row 3")
    assert_documents([expected_documents[3]], residual_documents, "#{label} exact PK residual")
  end

  private def assert_comparator_sensitivity(check : String, full_binary : String, part_name : String) : Nil
    expected = expected_documents
    wrong_documents = expected.dup
    wrong_documents[0] = document(0, -1_i64)
    expect_mismatch("wrong Object document") do
      assert_documents(expected, wrong_documents, "seeded wrong document")
    end

    wrong_serializer = JSON.parse(%({"columns":[{"name":"payload.i","kind":"Sparse"}]}))
    expect_mismatch("Sparse serializer kind") do
      assert_default_serializers(wrong_serializer, "seeded Sparse serializer")
    end

    expect_mismatch("wrong physical mark grid") do
      assert_grid([2_u64, 1_u64, 2_u64], "seeded wrong physical grid")
    end

    wrong_check = check.gsub("\t1\t", "\t0\t")
    assert(wrong_check != check, "CHECK comparator control did not mutate its positive row")
    expect_mismatch("wrong CHECK TABLE row") do
      assert_check(wrong_check, part_name, "seeded wrong CHECK")
    end

    wrong_signed = SIGNED.dup
    wrong_signed[0] = 0_i64
    expect_mismatch("signed RowBinary mismatch") do
      assert_rowbinary(full_binary, [0, 1, 2, 3, 4], "seeded wrong signed bytes", wrong_signed)
    end
  end

  private def native_case(
    binary : String,
    root : String,
    profile_name : String,
    profile : CrystalClick::BinaryBulkProfile,
    mode_name : String,
    mode : UInt64,
    case_number : Int32,
    check_negative_controls : Bool,
  ) : Nil
    label = "native_#{profile_name}_#{mode_name}"
    store = File.join(root, "stores", label)
    FileUtils.mkdir_p(store)
    table = table_name(label)
    create_table(binary, store, table, profile_name, mode, label)
    input = IO::Memory.new(NATIVE_JSON_ROWS.join("\n") + "\n")
    run(binary, store, "INSERT INTO default.#{table} FORMAT JSONEachRow", input)
    part = stock_part(binary, store, table, label)
    check, full_binary = assert_stock_sql(binary, store, table, part[:name], label)
    assert_comparator_sensitivity(check, full_binary, part[:name]) if check_negative_controls

    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION)
    assert_part_profile(part, schema, profile, mode, label)
    object_reader(part, schema, label)
    catalog = catalog_root(root, label, case_number, part)
    catalog_values(catalog[:root], label)
    assert_table_delivery(catalog[:root], catalog[:part_path], part, label)
    puts "PASS W131 native INSERT -> stock CHECK/full/PK SQL and exact RowBinary -> Object reader/catalog/table: #{label} part=#{part[:name]}"
  end

  private def library_case(
    binary : String,
    root : String,
    profile_name : String,
    profile : CrystalClick::BinaryBulkProfile,
    mode_name : String,
    mode : UInt64,
    table_number : Int32,
  ) : Nil
    label = "library_#{profile_name}_#{mode_name}"
    store = File.join(root, "stores", label)
    FileUtils.mkdir_p(store)
    table = table_name(label)
    create_table(binary, store, table, profile_name, mode, label)
    active = run(binary, store,
      "SELECT count() FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").strip
    assert(active == "0", "#{label}: target table is not empty before library part publication")
    data_path = table_data_path(binary, store, table, label)
    detached = File.join(data_path, "detached")
    FileUtils.mkdir_p(detached)
    detached = store_child(detached, store, "#{label} detached directory")
    part_name = "all_1_1_0"
    part_path = File.join(detached, part_name)
    assert(!File.exists?(part_path) && !File.symlink?(part_path), "#{label}: detached part path is occupied")
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      part_path,
      "pk",
      Slice(UInt64).new(KEYS.size) { |index| KEYS[index] },
      "payload",
      CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION),
      plan,
      granules(expected_documents),
      rows_per_mark: 2,
      mode: mode,
      profile: profile,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: FRAME_BYTES
    )
    part_path = store_child(part_path, store, "#{label} library-written part")
    run(binary, store, "ALTER TABLE default.#{table} ATTACH PART '#{part_name}'")
    part = stock_part(binary, store, table, label)
    assert(part[:name] == part_name, "#{label}: ATTACH changed the library part identity")
    assert_stock_sql(binary, store, table, part[:name], label)

    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION)
    assert_part_profile(part, schema, profile, mode, label)
    object_reader(part, schema, label)
    catalog = catalog_root(root, label, table_number, part)
    catalog_values(catalog[:root], label)
    assert_table_delivery(catalog[:root], catalog[:part_path], part, label)
    puts "PASS W131 library-owned matrix cell (String #{profile_name}, Dynamic #{mode_name}) -> stock ATTACH/CHECK/full/PK SQL and exact RowBinary -> reader/catalog/table: #{label}"
  end

  def check : Nil
    binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
    root = ENV["W131_TMP_ROOT"]? || raise "W131_TMP_ROOT is required"
    assert(!File.symlink?(root) && Dir.exists?(root), "W131 temporary root must be an existing non-symlink directory")
    root = File.realpath(root)
    assert(root.starts_with?("/private/tmp/crystal-click-object-int64-w131."), "unsafe W131 temporary root")
    assert(KEYS.size == 5 && SIGNED.size == 5 && NATIVE_JSON_ROWS.size == 5,
      "W131 independent five-row inventory changed")
    assert(SIGNED == [Int64::MIN, -1_i64, 0_i64, 1_i64, Int64::MAX],
      "W131 signed boundary fixture changed")
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION)
    assert(schema.declaration == DECLARATION && schema.typed_paths == typed_schema,
      "W131 nominal typed declaration differs from authored schema")

    bootstrap_store = File.join(root, "bootstrap")
    FileUtils.mkdir_p(bootstrap_store)
    run(binary, bootstrap_store, "SELECT 1")
    verify_runtime(binary, bootstrap_store)

    case_number = 1
    PROFILES.each do |profile_name, profile|
      MODES.each do |mode_name, mode|
        native_case(binary, root, profile_name, profile, mode_name, mode, case_number,
          check_negative_controls: case_number == 1)
        case_number += 1
      end
    end

    # Exercise every library-writer composition of ordinary String layout and
    # Dynamic discriminator mode, independently of the native INSERT matrix.
    library_table_number = 5
    PROFILES.each do |profile_name, profile|
      MODES.each do |mode_name, mode|
        library_case(binary, root, profile_name, profile, mode_name, mode, library_table_number)
        library_table_number += 1
      end
    end
    puts "PASS W131 scope: declared signed Int64 extremes paired with UInt64/String in one V3/MAP Object; native and library BASIC/COMPACT × String 0/1 full matrices; no wrapper, Float64, Compact part, projection, MV, or performance claim"
  end
end

W131Oracle.new.check
