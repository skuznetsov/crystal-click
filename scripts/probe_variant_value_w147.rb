#!/usr/bin/env ruby
# W147 generic stock <-> library Variant descriptor/value kernel exchange.
# Root compiles the checker separately and owns serial execution under its
# resource guard. Scratch MergeTree tables persist across isolated `local`
# invocations; that is harness storage only, not a part-writer claim. This
# driver does not claim Object-part or complete-part support.

require "digest"
require "open3"
require "tmpdir"

module VariantValueW147
  BIN = ENV.fetch("CLICKHOUSE_BIN", "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped")
  EXPECTED_VERSION = "26.10.1.1201"
  EXPECTED_BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  EXPECTED_BINARY_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-9007d227"
  SOURCE_REVISION = "9007d227b64a3f8b667fc5258ceb2923f3cf477d"
  ROOT_PATTERN = %r{\A/private/tmp/crystal-click-w147-kernel\.[A-Za-z0-9_-]+\z}

  CANONICAL_TYPE = "Variant(String, UInt64)"
  NOMINAL_TYPE = "Variant(Bool, UInt8)"
  INNER_TUPLE_TYPE = "Tuple(label LowCardinality(String), score UInt32)"
  RECURSIVE_VARIANT_TYPE = "Variant(Array(Array(UInt16)), Map(String, Nullable(UInt16)), #{INNER_TUPLE_TYPE})"
  RECURSIVE_TYPE = "Tuple(selected #{RECURSIVE_VARIANT_TYPE}, items Array(#{RECURSIVE_VARIANT_TYPE}), lookup Map(String, #{RECURSIVE_VARIANT_TYPE}), record #{INNER_TUPLE_TYPE})"

  def self.fail!(message)
    raise RuntimeError, message
  end

  def self.assert(condition, message)
    fail!(message) unless condition
  end

  def self.write_new(path, bytes)
    fail!("refusing to overwrite W147 evidence: #{path}") if File.exist?(path) || File.symlink?(path)
    File.binwrite(path, bytes)
  end

  def self.write_text_new(path, text)
    write_new(path, text)
  end

  def self.var_uint(number)
    fail!("negative RowBinary VarUInt") if number.negative?
    output = +"".b
    remaining = number
    loop do
      byte = remaining & 0x7f
      remaining >>= 7
      if remaining.zero?
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

  def self.inner_tuple_descriptor
    "\x20".b + var_uint(2) + rb_string("label") + type_binary("LowCardinality(String)") +
      rb_string("score") + type_binary("UInt32")
  end

  def self.recursive_variant_descriptor
    "\x2a".b + var_uint(3) + type_binary("Array(Array(UInt16))") +
      type_binary("Map(String, Nullable(UInt16))") + inner_tuple_descriptor
  end

  # Independent descriptor bytes authored from ClickHouse's binary type tag
  # table; not read from the runtime or the Crystal codec.
  def self.type_binary(name)
    case name
    when "UInt8" then "\x01".b
    when "UInt16" then "\x02".b
    when "UInt32" then "\x03".b
    when "UInt64" then "\x04".b
    when "String" then "\x15".b
    when "Bool" then "\x2d".b
    when "Nullable(UInt16)" then "\x23\x02".b
    when "LowCardinality(String)" then "\x26\x15".b
    when "Array(Array(UInt16))" then "\x1e\x1e\x02".b
    when "Map(String, Nullable(UInt16))" then "\x27\x15\x23\x02".b
    when INNER_TUPLE_TYPE then inner_tuple_descriptor
    when CANONICAL_TYPE then "\x2a".b + var_uint(2) + type_binary("String") + type_binary("UInt64")
    when NOMINAL_TYPE then "\x2a".b + var_uint(2) + type_binary("Bool") + type_binary("UInt8")
    when RECURSIVE_VARIANT_TYPE then recursive_variant_descriptor
    when RECURSIVE_TYPE
      "\x20".b + var_uint(4) +
        rb_string("selected") + recursive_variant_descriptor +
        rb_string("items") + "\x1e".b + recursive_variant_descriptor +
        rb_string("lookup") + "\x27\x15".b + recursive_variant_descriptor +
        rb_string("record") + inner_tuple_descriptor
    else
      fail!("missing independently authored W147 descriptor for #{name.inspect}")
    end
  end

  def self.payloads(profile)
    case profile
    when "canonical"
      ["\x00".b + rb_string("alpha"), "\x01".b + [42].pack("Q<"), "\xff".b]
    when "nominal"
      ["\x00\x01".b, "\x01\xff".b, "\xff".b]
    when "recursive"
      nested_array = var_uint(2) + var_uint(2) + [1, 65_535].pack("v*") + var_uint(0)
      array_variant = "\x00".b + nested_array
      nullable_map_variant = "\x01".b + var_uint(2) +
        rb_string("a") + "\x00".b + [7].pack("v") +
        rb_string("z") + "\x01".b
      tuple_variant = "\x02".b + rb_string("λ") + [4_294_967_295].pack("V")
      selected_empty_array = "\x00\x00".b
      items = var_uint(2) + array_variant + "\xff".b
      lookup = var_uint(2) + rb_string("map") + nullable_map_variant +
        rb_string("tuple") + tuple_variant
      record = rb_string("parent") + [7].pack("V")
      [selected_empty_array + items + lookup + record]
    else
      fail!("unknown W147 profile #{profile.inspect}")
    end
  end

  def self.profile_type(profile)
    case profile
    when "canonical" then CANONICAL_TYPE
    when "nominal" then NOMINAL_TYPE
    when "recursive" then RECURSIVE_TYPE
    else fail!("unknown W147 profile #{profile.inspect}")
    end
  end

  def self.profile_ids(profile)
    profile == "recursive" ? [1] : [1, 2, 3]
  end

  def self.output_header(profile)
    var_uint(1) + rb_string("v") + type_binary(profile_type(profile))
  end

  def self.library_input(profile, values = payloads(profile))
    header = var_uint(2) + rb_string("id") + rb_string("v") +
      type_binary("UInt8") + type_binary(profile_type(profile))
    rows = profile_ids(profile).zip(values).map do |id, value|
      [id].pack("C") + value
    end.join.b
    header + rows
  end

  def self.expected_output(profile, id, payload)
    output_header(profile) + payload
  end

  def self.choose_root
    requested = ENV["W147_VARIANT_OUTPUT"]
    if requested && !requested.empty?
      assert(ROOT_PATTERN.match?(requested), "W147 output must be a direct /private/tmp namespace child")
      assert(File.expand_path(requested) == requested, "W147 output root must be canonical")
      assert(!File.symlink?(requested), "refusing symlink W147 output root")
      if File.exist?(requested)
        assert(File.directory?(requested), "W147 output path is not a directory")
        assert(Dir.children(requested).empty?, "refusing nonempty W147 output root")
      else
        Dir.mkdir(requested, 0o700)
      end
      requested
    else
      Dir.mktmpdir("crystal-click-w147-kernel.", "/private/tmp")
    end
  end

  def self.validate_root(root)
    assert(ROOT_PATTERN.match?(root), "W147 root escaped its direct /private/tmp namespace")
    assert(File.expand_path(root) == root, "W147 output root must be canonical")
    assert(!File.symlink?(root) && File.directory?(root), "W147 output root must be a non-symlink directory")
    assert(File.realpath(root) == root, "W147 output root resolves to a different path")
  end

  def self.local(binary, store, query, stdin_data: "", extra: [], sql_path:)
    write_new(sql_path, query + "\n")
    args = [
      "local", "--path", store,
      "--session_timezone=UTC", "--max_threads=1", "--allow_suspicious_variant_types=1",
      "--print_pretty_type_names=0",
      *extra, "--query", query,
    ]
    stdout, stderr, status = Open3.capture3({"TZ" => "UTC"}, binary, *args, stdin_data: stdin_data)
    assert(stdout.bytesize <= 1_048_576 && stderr.bytesize <= 1_048_576,
      "W147 ClickHouse capture exceeded 1 MiB")
    [stdout.b, stderr.b, status]
  end

  def self.local!(binary, store, query, prefix, stdin_data: "", extra: [])
    stdout, stderr, status = local(binary, store, query, stdin_data: stdin_data, extra: extra,
      sql_path: "#{prefix}.sql")
    write_new("#{prefix}.stdout", stdout)
    write_new("#{prefix}.stderr", stderr)
    assert(status.success?, "ClickHouse failed (#{status.exitstatus}) for #{query.inspect}: #{stderr.inspect}")
    stdout
  end

  def self.checker!(checker, mode, root, results)
    assert(File.file?(checker) && File.executable?(checker) && !File.symlink?(checker),
      "explicit W147 checker must be an executable regular file")
    assert(File.expand_path(checker) == checker, "W147 checker path must be absolute and canonical")
    stdout, stderr, status = Open3.capture3(checker, mode, root)
    assert(stdout.bytesize <= 65_536 && stderr.bytesize <= 65_536, "W147 checker capture exceeded bound")
    write_new("#{results}/checker-#{mode}.stdout", stdout.b)
    write_new("#{results}/checker-#{mode}.stderr", stderr.b)
    assert(status.success?, "W147 checker #{mode} failed (#{status.exitstatus}): #{stderr.inspect}")
    stdout
  end

  def self.verify_source_pin!(identity)
    assert(File.directory?(SOURCE_ROOT) && !File.symlink?(SOURCE_ROOT), "pinned ClickHouse source checkout is missing or symlinked")
    stdout, stderr, status = Open3.capture3("git", "-C", SOURCE_ROOT, "rev-parse", "HEAD")
    write_new("#{identity}/source-revision.stdout", stdout.b)
    write_new("#{identity}/source-revision.stderr", stderr.b)
    assert(status.success? && stdout.strip == SOURCE_REVISION,
      "source reference revision mismatch: #{stdout.inspect} #{stderr.inspect}")
  end

  def self.verify_runtime_pins!(binary, store, identity)
    assert(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary),
      "pinned ClickHouse executable is unavailable or symlinked: #{binary}")
    actual_sha = Digest::SHA256.file(binary).hexdigest
    assert(actual_sha == EXPECTED_BINARY_SHA256, "runtime SHA mismatch: #{actual_sha}")
    version = local!(binary, store, "SELECT version() FORMAT TSVRaw", "#{identity}/version").strip
    assert(version == EXPECTED_VERSION, "runtime version mismatch: #{version.inspect}")
    build_options = local!(binary, store,
      "SELECT concat(name, '=', value) FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw",
      "#{identity}/build-options").lines.map(&:strip)
    expected = ["GIT_HASH=#{EXPECTED_BUILD_HASH}", "VERSION_GITHASH=#{EXPECTED_BUILD_HASH}"]
    assert(build_options == expected, "runtime build hash mismatch: #{build_options.inspect}")
    [actual_sha, version, build_options]
  end

  def self.assert_literal(label, actual, expected)
    assert(actual == expected, "#{label}: full literal wire bytes differ (actual=#{actual.bytesize} bytes expected=#{expected.bytesize} bytes)")
  end

  def self.check_input_literals!(root)
    inputs = File.join(root, "inputs")
    {"canonical" => library_input("canonical"), "nominal" => library_input("nominal"),
     "recursive" => library_input("recursive")}.each do |profile, expected|
      path = File.join(inputs, "library-#{profile}.bin")
      assert(File.file?(path) && !File.symlink?(path), "missing library input for #{profile}")
      actual = File.binread(path)
      assert_literal("library #{profile} full input", actual, expected)
    end
    mutant_payload = "\x01".b + [43].pack("Q<")
    # The mutant profile is one row, so replace the ordinary three-row frame
    # with an independently authored header and id=2 row.
    mutant_expected = var_uint(2) + rb_string("id") + rb_string("v") + type_binary("UInt8") +
      type_binary(CANONICAL_TYPE) + "\x02".b + mutant_payload
    path = File.join(inputs, "library-mutant-canonical.bin")
    assert(File.file?(path) && !File.symlink?(path), "missing valid wrong-value input")
    assert_literal("valid mutant full input", File.binread(path), mutant_expected)
    original_row = var_uint(2) + rb_string("id") + rb_string("v") + type_binary("UInt8") +
      type_binary(CANONICAL_TYPE) + "\x02".b + payloads("canonical")[1]
    assert(mutant_expected != original_row, "valid mutant did not differ from literal UInt64 42 input")
    assert(Dir.children(inputs).count == 4, "unexpected W147 input artifact count")
  end

  def self.create_table(binary, store, name, type, results)
    query = "CREATE TABLE default.#{name} (id UInt8, v #{type}) ENGINE=MergeTree ORDER BY id"
    local!(binary, store, query, "#{results}/create-#{name}")
  end

  def self.stock_insert_sql(profile)
    table = "stock_#{profile}"
    case profile
    when "canonical"
      "INSERT INTO default.#{table} VALUES " \
        "(1, CAST('alpha', 'Variant(String, UInt64)')), " \
        "(2, CAST(toUInt64(42), 'Variant(String, UInt64)')), " \
        "(3, CAST(NULL, 'Variant(String, UInt64)'))"
    when "nominal"
      "INSERT INTO default.#{table} VALUES " \
        "(1, CAST(true, 'Variant(Bool, UInt8)')), " \
        "(2, CAST(toUInt8(255), 'Variant(Bool, UInt8)')), " \
        "(3, CAST(NULL, 'Variant(Bool, UInt8)'))"
    when "recursive"
      variant = RECURSIVE_VARIANT_TYPE
      selected = "CAST(CAST([], 'Array(Array(UInt16))'), '#{variant}')"
      full_array = "CAST(CAST([[toUInt16(1), toUInt16(65535)], []], 'Array(Array(UInt16))'), '#{variant}')"
      items = "CAST([#{full_array}, CAST(NULL, '#{variant}')], 'Array(#{variant})')"
      map_value = "CAST(map('a', CAST(toUInt16(7), 'Nullable(UInt16)'), 'z', CAST(NULL, 'Nullable(UInt16)')), '#{variant}')"
      tuple_value = "CAST(CAST(tuple(CAST('λ', 'LowCardinality(String)'), toUInt32(4294967295)), '#{INNER_TUPLE_TYPE}'), '#{variant}')"
      lookup = "CAST(map('map', #{map_value}, 'tuple', #{tuple_value}), 'Map(String, #{variant})')"
      record = "CAST(tuple(CAST('parent', 'LowCardinality(String)'), toUInt32(7)), '#{INNER_TUPLE_TYPE}')"
      whole = "CAST(tuple(#{selected}, #{items}, #{lookup}, #{record}), '#{RECURSIVE_TYPE}')"
      "INSERT INTO default.#{table} SELECT 1, #{whole}"
    else
      fail!("unknown W147 profile #{profile.inspect}")
    end
  end

  def self.type_witness(binary, store, table, profile, rows, results, source)
    type = profile_type(profile)
    count = local!(binary, store,
      "SELECT count(), any(toTypeName(v)) FROM default.#{table} FORMAT TSVRaw",
      "#{results}/#{source}-#{profile}-count-type")
    assert(count == "#{rows}\t#{type}\n",
      "#{table}: exact row-count/type witness mismatch: #{count.inspect}")
    if profile == "canonical"
      query = "SELECT id, variantType(v) FROM default.#{table} ORDER BY id FORMAT TSVRaw"
      expected = "1\tString\n2\tUInt64\n3\tNone\n"
    elsif profile == "nominal"
      query = "SELECT id, variantType(v) FROM default.#{table} ORDER BY id FORMAT TSVRaw"
      expected = "1\tBool\n2\tUInt8\n3\tNone\n"
    else
      query = "SELECT variantType(v.selected), variantType(v.items[1]), variantType(v.items[2]), variantType(v.lookup['map']), variantType(v.lookup['tuple']) FROM default.#{table} FORMAT TSVRaw"
      expected = [
        "Array(Array(UInt16))", "Array(Array(UInt16))", "None",
        "Map(String, Nullable(UInt16))", INNER_TUPLE_TYPE,
      ].join("\t") + "\n"
    end
    actual = local!(binary, store, query, "#{results}/#{source}-#{profile}-arm-witness")
    assert(actual == expected, "#{table}: exact literal arm witness mismatch: #{actual.inspect} != #{expected.inspect}")
  end

  def self.binary_select(binary, store, table, profile, id, prefix, expected_payload: nil)
    query = "SELECT v AS v FROM default.#{table} WHERE id=#{id} " \
      "SETTINGS output_format_binary_encode_types_in_binary_format=1, print_pretty_type_names=0 " \
      "FORMAT RowBinaryWithNamesAndTypes"
    output = local!(binary, store, query, prefix)
    write_new("#{prefix}.bin", output)
    literal = expected_payload || payloads(profile)[profile_ids(profile).index(id)]
    assert_literal("#{prefix} stock full output", output, expected_output(profile, id, literal))
    output
  end

  def self.capture_tree(root)
    count = 0
    total = 0
    visit = lambda do |path|
      Dir.children(path).each do |name|
        child = File.join(path, name)
        assert(!File.symlink?(child), "W147 evidence tree contains a symlink: #{child}")
        if File.directory?(child)
          visit.call(child)
        else
          assert(File.file?(child), "W147 evidence contains a non-regular file: #{child}")
          count += 1
          total += File.size(child)
        end
      end
    end
    visit.call(root)
    [count, total]
  end

  def self.finish_artifact_audit!(root)
    input_count, input_bytes = capture_tree(File.join(root, "inputs"))
    result_count, result_bytes = capture_tree(File.join(root, "results"))
    count = input_count + result_count
    bytes = input_bytes + result_bytes
    assert(count <= 180, "W147 evidence file count exceeded bound: #{count}")
    assert(bytes <= 4 * 1024 * 1024, "W147 evidence bytes exceeded bound: #{bytes}")
    input_bins = Dir.children(File.join(root, "inputs")).count { |name| name.end_with?(".bin") }
    result_bins = Dir.children(File.join(root, "results")).count { |name| name.end_with?(".bin") }
    assert(input_bins == 4 && result_bins == 15,
      "W147 bounded wire artifact inventory mismatch: inputs=#{input_bins} result=#{result_bins}")
    [count, bytes]
  end

  def self.run
    assert(ENV["W147_EXECUTE_AS_ROOT"] == "YES", "root-owned W147_EXECUTE_AS_ROOT=YES is required")
    checker = ENV["W147_VARIANT_CHECKER"]
    assert(checker && !checker.empty?, "set W147_VARIANT_CHECKER to the separately built checker executable")
    assert(File.file?(checker) && File.executable?(checker) && !File.symlink?(checker),
      "explicit W147 checker is missing, non-executable, or symlinked")
    root = choose_root
    validate_root(root)
    %w[stores results].each { |name| Dir.mkdir(File.join(root, name), 0o700) }
    identity = File.join(root, "results", "identity")
    Dir.mkdir(identity, 0o700)
    identity_store = File.join(root, "stores", "identity")
    Dir.mkdir(identity_store, 0o700)

    # Verify all source/runtime pins before launching the separately built
    # checker or any stock/library exchange action.
    verify_source_pin!(identity)
    runtime_sha, runtime_version, build_options = verify_runtime_pins!(BIN, identity_store, identity)
    write_text_new(File.join(root, "results", "identity.txt"), [
      "source_reference_checkout=#{SOURCE_ROOT}", "source_reference_revision=#{SOURCE_REVISION}",
      "runtime_binary=#{BIN}", "runtime_sha256=#{runtime_sha}",
      "runtime_version=#{runtime_version}", *build_options,
      "provenance=runtime and source reference are separately pinned; runtime is not asserted built from source",
      "harness_storage=MergeTree scratch tables persist across separate local invocations only",
      "scope=generic logical RowBinary Variant descriptor/value kernel exchange only",
    ].join("\n") + "\n")

    checker!(checker, "encode", root, File.join(root, "results"))
    check_input_literals!(root)

    binary = BIN
    store = File.join(root, "stores", "main")
    Dir.mkdir(store, 0o700)
    results = File.join(root, "results")
    profiles = %w[canonical nominal recursive]
    profiles.each do |profile|
      create_table(binary, store, "stock_#{profile}", profile_type(profile), results)
      local!(binary, store, stock_insert_sql(profile), "#{results}/insert-stock-#{profile}")
      create_table(binary, store, "library_#{profile}", profile_type(profile), results)
      input = File.binread(File.join(root, "inputs", "library-#{profile}.bin"))
      local!(binary, store, "INSERT INTO default.library_#{profile} FORMAT RowBinaryWithNamesAndTypes",
        "#{results}/insert-library-#{profile}", stdin_data: input,
        extra: ["--input_format_binary_decode_types_in_binary_format=1"])
    end

    profiles.each do |profile|
      expected_rows = profile_ids(profile).size
      type_witness(binary, store, "stock_#{profile}", profile, expected_rows, results, "stock")
      type_witness(binary, store, "library_#{profile}", profile, expected_rows, results, "library")
      profile_ids(profile).each do |id|
        binary_select(binary, store, "stock_#{profile}", profile, id,
          "#{results}/stock-#{profile}-#{id}")
        binary_select(binary, store, "library_#{profile}", profile, id,
          "#{results}/library-stock-#{profile}-#{id}")
      end
    end

    create_table(binary, store, "library_mutant_canonical", CANONICAL_TYPE, results)
    mutant_payload = "\x01".b + [43].pack("Q<")
    mutant_input = var_uint(2) + rb_string("id") + rb_string("v") + type_binary("UInt8") +
      type_binary(CANONICAL_TYPE) + "\x02".b + mutant_payload
    assert_literal("mutant input", File.binread(File.join(root, "inputs", "library-mutant-canonical.bin")), mutant_input)
    local!(binary, store, "INSERT INTO default.library_mutant_canonical FORMAT RowBinaryWithNamesAndTypes",
      "#{results}/insert-library-mutant-canonical", stdin_data: mutant_input,
      extra: ["--input_format_binary_decode_types_in_binary_format=1"])
    count_type = local!(binary, store,
      "SELECT count(), any(toTypeName(v)) FROM default.library_mutant_canonical FORMAT TSVRaw",
      "#{results}/library-mutant-count-type")
    assert(count_type == "1\t#{CANONICAL_TYPE}\n", "mutant table row-count/type mismatch: #{count_type.inspect}")
    mutant_output = binary_select(binary, store, "library_mutant_canonical", "canonical", 2,
      "#{results}/mutant-stock-canonical-2", expected_payload: mutant_payload)
    original_output = File.binread(File.join(results, "stock-canonical-2.bin"))
    assert(mutant_output != original_output, "valid UInt64 43 mutation unexpectedly matched stock UInt64 42 output")
    assert_literal("mutant output value", mutant_output, expected_output("canonical", 2, mutant_payload))

    checker!(checker, "verify", root, results)
    files, bytes = finish_artifact_audit!(root)
    pre_summary_files, pre_summary_bytes = finish_artifact_audit!(root)
    summary_lines = [
      "result=PASS",
      "source_reference_revision=#{SOURCE_REVISION}", "runtime_sha256=#{runtime_sha}",
      "profiles=canonical String/UInt64, nominal Bool/UInt8, recursive Array/Map/named-Tuple Variant arms",
      "stock_rows=7", "library_rows=7", "mutant_rows=1",
      "native_wire=literal complete RowBinaryWithNamesAndTypes header and row bytes compared for every stock and library output",
      "library_input=Crystal-encoded descriptors and row values; independently compared against literal complete input files before stock INSERT",
      "mutant=stock accepted UInt64 43 and emitted exact changed output; UInt64 42 original remains separately asserted",
      "harness_storage=MergeTree scratch tables persist across separate local invocations only",
      "scope=generic logical RowBinary Variant descriptor/value kernel only; LC physical dictionaries, Object parts, complete part writer, MV, projections, and performance excluded",
    ]
    final_files = pre_summary_files + 1
    final_bytes = pre_summary_bytes
    summary = ""
    loop do
      summary = (summary_lines + ["artifact_files=#{final_files}", "artifact_bytes=#{final_bytes}"]).join("\n") + "\n"
      next_bytes = pre_summary_bytes + summary.bytesize
      break if next_bytes == final_bytes
      final_bytes = next_bytes
    end
    write_text_new(File.join(results, "run.txt"), summary)
    files, bytes = finish_artifact_audit!(root)
    assert(files == final_files && bytes == final_bytes,
      "W147 final evidence inventory disagrees with run record")
    puts "PASS W147 generic stock <-> library Variant kernel exchange: #{root}"
  end
end

VariantValueW147.run
