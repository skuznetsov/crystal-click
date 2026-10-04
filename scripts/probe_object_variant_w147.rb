#!/usr/bin/env ruby
# Native declared JSON/Object Variant and Dynamic reader/part falsifier.
# Root owns execution under its serial resource guard. This authoring turn must
# not run this file, ClickHouse, or Crystal. The pinned runtime is independent
# of the pinned source reference; it is not asserted to have been built from it.

require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

module ObjectVariantW147
  BIN = ENV.fetch("CLICKHOUSE_BIN", "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped")
  EXPECTED_VERSION = "26.10.1.1201"
  EXPECTED_BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  EXPECTED_BINARY_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-9007d227"
  SOURCE_REVISION = "9007d227b64a3f8b667fc5258ceb2923f3cf477d"

  VARIANT_TYPE = "Variant(Array(Array(UInt16)), Map(String, Nullable(UInt16)), String, Tuple(label LowCardinality(String), score UInt32), UInt64, UInt8)"
  DYNAMIC_TYPE = "Dynamic(max_types=2)"
  NOMINAL_TYPE = "Variant(Bool, UInt8)"
  BOX_TYPE = "Tuple(choice Variant(Bool, String), payload Dynamic(max_types=1))"
  JSON_COLUMN_TYPE = "JSON(box #{BOX_TYPE}, d #{DYNAMIC_TYPE}, nominal #{NOMINAL_TYPE}, v #{VARIANT_TYPE})"

  SETTINGS = [
    "index_granularity=2",
    "index_granularity_bytes=10485760",
    "enable_mixed_granularity_parts=1",
    "min_rows_for_wide_part=0",
    "min_bytes_for_wide_part=0",
    "compress_marks=0",
    "compress_primary_key=0",
    "min_compress_block_size=0",
    "max_compress_block_size=4096",
    "ratio_of_defaults_for_sparse_serialization=1",
    "default_compression_codec='LZ4'",
    "object_serialization_version='v3'",
    "object_shared_data_serialization_version_for_zero_level_parts='map'",
    "propagate_types_serialization_versions_to_nested_types=true",
    "map_serialization_version='basic'",
    "map_serialization_version_for_zero_level_parts='basic'"
  ].join(", ").freeze

  DDL = <<~SQL.gsub(/\s+/, " ").strip.freeze
    CREATE TABLE default.p (
      id UInt8,
      j JSON(
        v Variant(UInt8, UInt64, String, Tuple(label LowCardinality(String), score UInt32),
                  Array(Array(UInt16)), Map(String, Nullable(UInt16)), UInt8, Nothing),
        nominal Variant(UInt8, Bool, Nothing, UInt8),
        d Dynamic(max_types=2),
        box Tuple(choice Variant(String, Bool), payload Dynamic(max_types=1))
      )
    ) ENGINE=MergeTree ORDER BY id SETTINGS #{SETTINGS}
  SQL

  ROWS = [
    {"id" => 1, "v" => nil, "nominal" => nil, "d" => nil, "box" => [nil, nil]},
    {"id" => 2, "v" => 9_223_372_036_854_775_808, "nominal" => true, "d" => 9_223_372_036_854_775_808, "box" => [true, 12]},
    {"id" => 3, "v" => "variant-雪", "nominal" => false, "d" => "ordinary-λ", "box" => ["box-a", 13]},
    {"id" => 4, "v" => [[1, 65_535], [42]], "nominal" => true, "d" => 1.5, "box" => [false, 14]},
    {"id" => 5, "v" => ["tuple-雪", 4_294_967_295], "nominal" => false, "d" => [-1, 2], "box" => ["box-b", 15]},
    {"id" => 6, "v" => {"a" => 7, "z" => nil}, "nominal" => true, "d" => false, "box" => [true, 16]},
    {"id" => 7, "v" => 1, "nominal" => false, "d" => -99, "box" => ["box-c", 17]},
    {"id" => 8, "v" => 255, "nominal" => true, "d" => "ordinary-again", "box" => [false, 18]}
  ].freeze

  VARIANT_NAMES = [
    "None", "UInt64", "String", "Array(Array(UInt16))",
    "Tuple(label LowCardinality(String), score UInt32)",
    "Map(String, Nullable(UInt16))", "UInt8", "UInt8"
  ].freeze
  DYNAMIC_NAMES = ["None", "UInt64", "String", "Float64", "Array(Nullable(Int64))", "Bool", "Int64", "String"].freeze
  DYNAMIC_SHARED = ["false", "false", "false", "true", "true", "true", "true", "false"].freeze
  NOMINAL_NAMES = ["None", "Bool", "Bool", "Bool", "Bool", "Bool", "Bool", "Bool"].freeze
  BOX_VARIANT_NAMES = ["None", "Bool", "String", "Bool", "String", "Bool", "String", "Bool"].freeze
  BOX_DYNAMIC_NAMES = ["None", "Int64", "Int64", "Int64", "Int64", "Int64", "Int64", "Int64"].freeze

  def self.fail!(message)
    raise RuntimeError, message
  end

  def self.assert(condition, message)
    fail!(message) unless condition
  end

  def self.write(path, bytes)
    File.binwrite(path, bytes)
  end

  def self.local(binary, store, query, stdin_data: "", extra: [], sql_path: nil)
    File.write(sql_path, query + "\n") if sql_path
    arguments = [
      "local", "--path", store, "--session_timezone=UTC",
      "--enable_time_time64_type=1", "--print_pretty_type_names=0",
      "--allow_suspicious_variant_types=1",
      "--query", query
    ] + extra
    Open3.capture3({"TZ" => "UTC"}, binary, *arguments, stdin_data: stdin_data)
  end

  def self.local!(binary, store, query, out_path, stdin_data: "", extra: [])
    stdout, stderr, status = local(binary, store, query, stdin_data: stdin_data, extra: extra,
      sql_path: "#{out_path}.sql")
    write("#{out_path}.stdout", stdout)
    write("#{out_path}.stderr", stderr)
    fail!("ClickHouse command failed (#{status.exitstatus}): #{query}\n#{stderr}") unless status.success?
    stdout
  end

  def self.var_uint(number)
    raise ArgumentError, "negative RowBinary varint" if number.negative?
    output = +"".b
    loop do
      byte = number & 0x7f
      number >>= 7
      if number.zero?
        output << byte
        break
      end
      output << (byte | 0x80)
    end
    output
  end

  def self.rb_string(value)
    bytes = value.encode(Encoding::UTF_8).b
    var_uint(bytes.bytesize) + bytes
  end

  # The descriptor bytes below are independently authored from the source
  # BinaryTypeIndex table. They are not obtained from the runtime's own output.
  def self.type_binary(name)
    case name
    when "Nothing" then "\x00".b
    when "UInt8" then "\x01".b
    when "UInt16" then "\x02".b
    when "UInt32" then "\x03".b
    when "UInt64" then "\x04".b
    when "Int64" then "\x0a".b
    when "Float64" then "\x0e".b
    when "String" then "\x15".b
    when "Bool" then "\x2d".b
    when "Array(Array(UInt16))" then "\x1e\x1e\x02".b
    when "Array(Int64)" then "\x1e\x0a".b
    when "Array(Nullable(Int64))" then "\x1e\x23\x0a".b
    when "Map(String, Nullable(UInt16))" then "\x27\x15\x23\x02".b
    when "Tuple(label LowCardinality(String), score UInt32)"
      "\x20".b + var_uint(2) + rb_string("label") + "\x26\x15".b + rb_string("score") + "\x03".b
    when "Variant(Array(Array(UInt16)), Map(String, Nullable(UInt16)), String, Tuple(label LowCardinality(String), score UInt32), UInt64, UInt8)"
      "\x2a".b + var_uint(6) +
        type_binary("Array(Array(UInt16))") +
        type_binary("Map(String, Nullable(UInt16))") +
        type_binary("String") +
        type_binary("Tuple(label LowCardinality(String), score UInt32)") +
        type_binary("UInt64") + type_binary("UInt8")
    when "Variant(Bool, UInt8)"
      "\x2a".b + var_uint(2) + type_binary("Bool") + type_binary("UInt8")
    when "Variant(Bool, String)"
      "\x2a".b + var_uint(2) + type_binary("Bool") + type_binary("String")
    when "Dynamic(max_types=2)" then "\x2b\x02".b
    when "Dynamic(max_types=1)" then "\x2b\x01".b
    when "Tuple(choice Variant(Bool, String), payload Dynamic(max_types=1))"
      "\x20".b + var_uint(2) + rb_string("choice") + type_binary("Variant(Bool, String)") +
        rb_string("payload") + type_binary("Dynamic(max_types=1)")
    else
      fail!("no independent binary descriptor for #{name.inspect}")
    end
  end

  def self.nullable_uint16(value)
    value.nil? ? "\x01".b : "\x00".b + [value].pack("v")
  end

  def self.variant_value(row)
    value = row.fetch("v")
    case row.fetch("id")
    when 1 then "\xff".b
    when 2 then "\x04".b + [value].pack("Q<") # canonical discriminator: UInt64
    when 3 then "\x02".b + rb_string(value) # String
    when 4
      "\x00".b + var_uint(2) + var_uint(2) + [1, 65_535].pack("v*") + var_uint(1) + [42].pack("v")
    when 5 then "\x03".b + rb_string(value[0]) + [value[1]].pack("V")
    when 6
      entries = value.to_a
      "\x01".b + var_uint(entries.length) + entries.map { |key, item| rb_string(key) + nullable_uint16(item) }.join.b
    when 7 then "\x05\x01".b # UInt8 value in the canonical Variant arm order
    when 8 then "\x05\xff".b
    else fail!("missing Variant RowBinary value for id #{row.fetch('id')}")
    end
  end

  def self.dynamic_value(row)
    case row.fetch("id")
    when 1 then type_binary("Nothing")
    when 2 then type_binary("UInt64") + [row.fetch("d")].pack("Q<")
    when 3, 8 then type_binary("String") + rb_string(row.fetch("d"))
    when 4 then type_binary("Float64") + [row.fetch("d")].pack("E")
    when 5
      items = row.fetch("d")
      type_binary("Array(Nullable(Int64))") + var_uint(items.length) +
        items.map { |item| "\x00".b + [item].pack("q<") }.join.b
    when 6 then type_binary("Bool") + "\x00".b
    when 7 then type_binary("Int64") + [row.fetch("d")].pack("q<")
    else fail!("missing Dynamic RowBinary value for id #{row.fetch('id')}")
    end
  end

  def self.nominal_value(row)
    return "\xff".b if row.fetch("id") == 1
    "\x00".b + (row.fetch("nominal") ? "\x01".b : "\x00".b)
  end

  def self.box_value(row)
    choice, payload = row.fetch("box")
    choice_binary = if choice.nil?
      "\xff".b
    elsif choice == true || choice == false
      "\x00".b + (choice ? "\x01".b : "\x00".b)
    else
      "\x01".b + rb_string(choice)
    end
    payload_binary = payload.nil? ? type_binary("Nothing") : type_binary("Int64") + [payload].pack("q<")
    choice_binary + payload_binary
  end

  def self.rowbinary_with_binary_types
    header = var_uint(5) + %w[id v d nominal box].map { |name| rb_string(name) }.join.b
    header += type_binary("UInt8") + type_binary(VARIANT_TYPE) + type_binary(DYNAMIC_TYPE) +
      type_binary(NOMINAL_TYPE) + type_binary(BOX_TYPE)
    header + ROWS.map do |row|
      [row.fetch("id")].pack("C") + variant_value(row) + dynamic_value(row) +
        nominal_value(row) + box_value(row)
    end.join.b
  end

  def self.json_rows
    ROWS.map do |row|
      {
        "id" => row.fetch("id"),
        "j" => {
          "v" => row.fetch("v"), "nominal" => row.fetch("nominal"),
          "d" => row.fetch("d"), "box" => row.fetch("box")
        }
      }
    end.map { |row| JSON.generate(row) + "\n" }.join
  end

  def self.expected_type_witness
    rows = ROWS.each_with_index.map do |row, index|
      [row.fetch("id"), VARIANT_NAMES[index], DYNAMIC_NAMES[index], DYNAMIC_SHARED[index],
       NOMINAL_NAMES[index], BOX_VARIANT_NAMES[index], BOX_DYNAMIC_NAMES[index],
       VARIANT_TYPE, DYNAMIC_TYPE, NOMINAL_TYPE, BOX_TYPE].join("\t")
    end
    rows.join("\n") + "\n"
  end

  def self.choose_root
    requested = ENV["W147_PROBE_ROOT"]
    unless requested.nil? || requested.empty?
      match = %r{\A/private/tmp/crystal-click-w147\.([A-Za-z0-9_-]+)\z}.match(requested)
      fail!("W147 root must be a direct /private/tmp namespace child") unless match
      fail!("W147 root path must already be canonical") unless File.expand_path(requested) == requested
      fail!("refusing symlink W147 root: #{requested}") if File.symlink?(requested)
      if File.exist?(requested)
        fail!("refusing non-directory W147 root: #{requested}") unless File.directory?(requested)
        fail!("refusing nonempty W147 root: #{requested}") unless Dir.children(requested).empty?
      else
        Dir.mkdir(requested, 0o700)
      end
      return requested
    end
    Dir.mktmpdir("crystal-click-w147.", "/private/tmp")
  end

  def self.validate_root(root)
    fail!("W147 output root is not canonical") unless File.realpath(root) == root
    fail!("W147 output root must not be a symlink") if File.symlink?(root)
    fail!("W147 output root escaped its direct namespace") unless %r{\A/private/tmp/crystal-click-w147\.[A-Za-z0-9_-]+\z}.match?(root)
    fail!("W147 output root must be fresh") unless Dir.children(root).empty?
  end

  def self.require_expected_rejection(binary, root, label, declaration, cause)
    store = File.join(root, "stores", "reject-#{label}")
    out = File.join(root, "results", "reject-#{label}")
    Dir.mkdir(store)
    Dir.mkdir(out)
    query = "CREATE TABLE default.p (id UInt8, j JSON(v #{declaration})) ENGINE=MergeTree ORDER BY id"
    stdout, stderr, status = local(binary, store, query, sql_path: "#{out}/create.sql")
    write("#{out}/create.stdout", stdout)
    write("#{out}/create.stderr", stderr)
    exact = "Code: 36. DB::Exception: #{cause}"
    assert(!status.success?, "#{label}: source-inadmissible Variant arm was admitted")
    assert(stderr.include?(exact), "#{label}: constructor rejection cause changed; expected #{exact.inspect}, got #{stderr.inspect}")
    File.write("#{out}/expected-cause.txt", exact + "\n")
  end

  def self.inventory_part(binary, store, root, table, extra)
    out = File.join(root, "results", "main")
    part_path = local!(binary, store,
      "SELECT path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name LIMIT 1 FORMAT TSVRaw",
      "#{out}/part-path", extra: extra).strip
    assert(!part_path.empty? && File.directory?(part_path) && !File.symlink?(part_path), "active stock part directory is unavailable")
    canonical_store = File.realpath(store)
    canonical_part = File.realpath(part_path)
    assert(canonical_part.start_with?(canonical_store + File::SEPARATOR), "active part escaped the isolated local store")
    copied = File.join(out, "native-part")
    FileUtils.cp_r(canonical_part, copied, preserve: true)
    entries = Dir.children(copied).sort.map do |name|
      path = File.join(copied, name)
      assert(!File.symlink?(path) && File.file?(path), "unexpected non-regular part entry #{name}")
      "#{Digest::SHA256.file(path).hexdigest}\t#{File.size(path)}\t#{name}\n"
    end.join
    File.write("#{out}/part-files.tsv", entries)
    %w[columns.txt columns_substreams.txt serialization.json checksums.txt].each do |name|
      source = File.join(copied, name)
      File.binwrite("#{out}/#{name}", File.binread(source)) if File.file?(source)
    end
  end

  def self.run
    fail!("refusing W147 probe without root-owned W147_EXECUTE_AS_ROOT=YES") unless ENV["W147_EXECUTE_AS_ROOT"] == "YES"
    assert(File.file?(BIN) && File.executable?(BIN) && !File.symlink?(BIN), "pinned ClickHouse executable is unavailable or symlinked: #{BIN}")
    actual_sha = Digest::SHA256.file(BIN).hexdigest
    assert(actual_sha == EXPECTED_BINARY_SHA256, "runtime executable SHA mismatch: #{actual_sha}")
    assert(File.directory?(SOURCE_ROOT) && !File.symlink?(SOURCE_ROOT), "pinned source reference checkout is unavailable or symlinked")

    root = choose_root
    validate_root(root)
    Dir.mkdir(File.join(root, "stores"))
    Dir.mkdir(File.join(root, "results"))
    identity_store = File.join(root, "stores", "identity")
    identity_out = File.join(root, "results", "identity")
    Dir.mkdir(identity_store)
    Dir.mkdir(identity_out)

    version = local!(BIN, identity_store, "SELECT version() FORMAT TSVRaw", "#{identity_out}/version").strip
    assert(version == EXPECTED_VERSION, "unexpected runtime version: #{version.inspect}")
    build_options = local!(BIN, identity_store,
      "SELECT concat(name, '=', value) FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw",
      "#{identity_out}/build-options").lines.map(&:strip)
    assert(build_options == ["GIT_HASH=#{EXPECTED_BUILD_HASH}", "VERSION_GITHASH=#{EXPECTED_BUILD_HASH}"],
      "runtime build identity mismatch: #{build_options.inspect}")
    source_head_out, source_head_err, source_head_status = Open3.capture3("git", "-C", SOURCE_ROOT, "rev-parse", "HEAD")
    write("#{identity_out}/source-revision.stdout", source_head_out)
    write("#{identity_out}/source-revision.stderr", source_head_err)
    assert(source_head_status.success? && source_head_out.strip == SOURCE_REVISION,
      "source reference revision mismatch: #{source_head_out.inspect} #{source_head_err.inspect}")

    File.write("#{root}/results/run.txt", [
      "probe_root=#{root}", "source_reference_checkout=#{SOURCE_ROOT}",
      "source_reference_revision=#{SOURCE_REVISION}", "runtime_binary=#{BIN}",
      "runtime_sha256=#{actual_sha}", "runtime_version=#{version}", *build_options,
      "runtime_setting=allow_suspicious_variant_types=1 (source-default is false; direct UInt8/UInt64 Variant arms are suspicious)",
      "provenance=runtime binary and source reference are separately pinned; runtime is not asserted built from source",
      "claim_scope=declared JSON typed Variant and Dynamic reader values, RowBinary descriptors/values, stock wide part and exact CHECK TABLE"
    ].join("\n") + "\n")

    extra = []
    store = File.join(root, "stores", "main")
    out = File.join(root, "results", "main")
    Dir.mkdir(store)
    Dir.mkdir(out)
    File.write("#{out}/ddl.sql", DDL + ";\n")
    ddl_out, ddl_err, ddl_status = local(BIN, store, DDL, sql_path: "#{out}/create.sql")
    write("#{out}/create.stdout", ddl_out)
    write("#{out}/create.stderr", ddl_err)
    assert(ddl_status.success?, "declared Variant/Dynamic JSON DDL failed: #{ddl_err}")

    fixture = json_rows
    File.write("#{out}/fixture.jsonl", fixture)
    insert_query = "INSERT INTO default.p FORMAT JSONEachRow"
    ins_out, ins_err, ins_status = local(BIN, store, insert_query,
      stdin_data: fixture, sql_path: "#{out}/insert.sql")
    write("#{out}/insert.stdout", ins_out)
    write("#{out}/insert.stderr", ins_err)
    assert(ins_status.success?, "declared Variant/Dynamic JSONEachRow insertion failed: #{ins_err}")

    type_query = "SELECT id, variantType(j.v), dynamicType(j.d), isDynamicElementInSharedData(j.d), variantType(j.nominal), variantType(j.box.choice), dynamicType(j.box.payload), toTypeName(j.v), toTypeName(j.d), toTypeName(j.nominal), toTypeName(j.box) FROM default.p ORDER BY id FORMAT TSVRaw"
    types = local!(BIN, store, type_query, "#{out}/type-witness")
    expected_types = expected_type_witness
    File.write("#{out}/expected-type-witness.tsv", expected_types)
    assert(types == expected_types, "literal declared Variant/Dynamic type/value witness differed: expected #{expected_types.inspect}, got #{types.inspect}")

    columns = local!(BIN, store,
      "SELECT name, type, position FROM system.columns WHERE database='default' AND table='p' ORDER BY position FORMAT TSVRaw",
      "#{out}/system-columns")
    column_rows = columns.lines(chomp: true).map { |line| line.split("\t", 3) }
    assert(column_rows == [["id", "UInt8", "1"], ["j", JSON_COLUMN_TYPE, "2"]],
      "system.columns did not report the declared JSON typed paths: #{columns.inspect}")

    rowbinary_query = "SELECT id AS id, j.v AS v, j.d AS d, j.nominal AS nominal, j.box AS box FROM default.p ORDER BY id SETTINGS output_format_binary_encode_types_in_binary_format=1, print_pretty_type_names=0 FORMAT RowBinaryWithNamesAndTypes"
    actual_binary = local!(BIN, store, rowbinary_query, "#{out}/rowbinary-with-binary-types").b
    expected_binary = rowbinary_with_binary_types
    write("#{out}/rowbinary-with-binary-types.actual.bin", actual_binary)
    write("#{out}/rowbinary-with-binary-types.expected.bin", expected_binary)
    File.write("#{out}/rowbinary-with-binary-types.sha256",
      "actual=#{Digest::SHA256.hexdigest(actual_binary)}\nexpected=#{Digest::SHA256.hexdigest(expected_binary)}\n")
    File.write("#{out}/independent-descriptor-types.tsv", [
      "v\t#{VARIANT_TYPE}\t#{type_binary(VARIANT_TYPE).unpack1('H*')}",
      "d\t#{DYNAMIC_TYPE}\t#{type_binary(DYNAMIC_TYPE).unpack1('H*')}",
      "nominal\t#{NOMINAL_TYPE}\t#{type_binary(NOMINAL_TYPE).unpack1('H*')}",
      "box\t#{BOX_TYPE}\t#{type_binary(BOX_TYPE).unpack1('H*')}"
    ].join("\n") + "\n")
    assert(actual_binary == expected_binary,
      "literal RowBinaryWithNamesAndTypes mismatch: expected #{expected_binary.bytesize} bytes, got #{actual_binary.bytesize}")

    local!(BIN, store, "SHOW CREATE TABLE default.p FORMAT TSVRaw", "#{out}/show-create")
    part_metadata = local!(BIN, store,
      "SELECT name, rows, marks, part_type, bytes_on_disk FROM system.parts WHERE database='default' AND table='p' AND active ORDER BY name FORMAT TSVRaw",
      "#{out}/part-metadata")
    part_fields = part_metadata.lines(chomp: true).map { |line| line.split("\t", 5) }
    assert(part_fields.size == 1 && part_fields[0].size == 5, "expected one complete stock part metadata row: #{part_metadata.inspect}")
    part_name, part_rows, part_marks, part_type, part_bytes = part_fields[0]
    # Eight rows at granularity two make four real row granules. system.parts
    # reports the additional final terminal-mark record as marks=5.
    assert(part_rows == "8" && part_marks == "5" && part_type == "Wide" && part_bytes.to_i.positive?,
      "unexpected stock part rows/marks/type/size: #{part_fields[0].inspect}")
    active = local!(BIN, store,
      "SELECT count() FROM system.parts WHERE database='default' AND table='p' AND active FORMAT TSVRaw",
      "#{out}/active-count").strip
    assert(active == "1", "expected one stock active part, got #{active.inspect}")
    File.write("#{out}/mark-grid.tsv", "real_row_granules\t2,2,2,2\nterminal_mark_records\t1\nsystem_parts_marks\t5\nrows\t8\n")
    check = local!(BIN, store, "CHECK TABLE default.p FORMAT TabSeparated", "#{out}/check-table")
    check_rows = check.lines(chomp: true).map { |line| line.split("\t", -1) }
    assert(check_rows == [[part_name, "1", ""]],
      "CHECK TABLE must return exactly the actual part, success flag, and empty error field: #{check.inspect}")
    inventory_part(BIN, store, root, "p", extra)

    require_expected_rejection(BIN, root, "nullable-arm", "Variant(String, Nullable(UInt16))",
      "Nullable/LowCardinality(Nullable) types are not allowed inside Variant type")
    require_expected_rejection(BIN, root, "nested-variant-arm", "Variant(String, Variant(UInt8, UInt16))",
      "Nested Variant types are not allowed")
    require_expected_rejection(BIN, root, "dynamic-arm", "Variant(String, Dynamic)",
      "Dynamic type is not allowed inside Variant type")

    summary = <<~TEXT
      main=PASS rows=#{ROWS.size} index_granularity=2 real_row_granules=4x2 system_parts_marks_including_terminal=5 part_type=#{part_type}
      declared_variant=#{VARIANT_TYPE}
      declared_dynamic=#{DYNAMIC_TYPE}; expected_ordinary_types=UInt64,String; expected_shared_types=Float64,Array(Nullable(Int64)),Bool,Int64
      nested_typed_path=#{BOX_TYPE}; nominal_order_witness=#{NOMINAL_TYPE}; source-declared duplicate UInt8 and Nothing canonicalize away
      rowbinary=exact literal RowBinaryWithNamesAndTypes descriptor and row bytes; see independent-descriptor-types.tsv
      check_table=exact active part row with exactly three TSV fields; see results/main/check-table.stdout
      constructor_controls=nullable, nested Variant, and Dynamic arms rejected for source-backed causes
      table_setting=allow_suspicious_variant_types=1 is explicit because the declared Variant includes UInt8 and UInt64
      scope=declared JSON typed-path reader and native Object-part discovery only; no Crystal writer, MV, projection, or performance claim
    TEXT
    File.write("#{root}/results/summary.txt", summary)
    puts "PASS W147 declared JSON/Object Variant and Dynamic native falsifier: #{root}"
  end
end

ObjectVariantW147.run
