#!/usr/bin/env ruby
# W148 finite stock Wide part-lane discovery and library/native exchange.
# Stock and library artifacts are separate: the pinned ClickHouse runtime is
# not asserted to have been built from the pinned depth-one source checkout.
# This is a logical lane and Native-consumer falsifier, not a complete part
# writer, generic physical binder, Dynamic/Object reader, or MV/projection test.

require "digest"
require "json"
require "open3"
require "tmpdir"

module VariantBulkW148
  BIN = ENV.fetch("CLICKHOUSE_BIN", "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped")
  EXPECTED_VERSION = "26.10.1.1201"
  EXPECTED_BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  EXPECTED_BINARY_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-9007d227"
  SOURCE_REVISION = "9007d227b64a3f8b667fc5258ceb2923f3cf477d"
  ROOT_PATTERN = %r{\A/private/tmp/crystal-click-w148\.[A-Za-z0-9_-]+\z}
  MAX_CAPTURE = 1_048_576
  MAX_EVIDENCE_BYTES = 8 * 1024 * 1024
  MAX_EVIDENCE_FILES = 240
  MARKS = 3

  BASIC_TYPE = "Variant(String, UInt64)"
  ARRAY_TYPE = "Array(Variant(LowCardinality(String), UInt64))"
  DECLARED_BASIC_TYPE = "Variant(UInt64, String)"
  DECLARED_ARRAY_TYPE = "Array(Variant(UInt64, LowCardinality(String)))"

  def self.fail!(message)
    raise RuntimeError, message
  end

  def self.assert(condition, message)
    fail!(message) unless condition
  end

  def self.write_new(path, bytes)
    fail!("refusing to overwrite W148 evidence: #{path}") if File.exist?(path) || File.symlink?(path)
    File.binwrite(path, bytes)
  end

  def self.write_json_new(path, object)
    write_new(path, JSON.pretty_generate(object) + "\n")
  end

  def self.u64(value)
    [value].pack("Q<")
  end

  def self.var_uint(value)
    fail!("negative VarUInt literal") if value.negative?
    bytes = +"".b
    remaining = value
    loop do
      byte = remaining & 0x7f
      remaining >>= 7
      if remaining.zero?
        bytes << byte
        break
      end
      bytes << (byte | 0x80)
    end
    bytes
  end

  def self.rb_string(value)
    payload = value.encode(Encoding::UTF_8).b
    var_uint(payload.bytesize) + payload
  end

  def self.literal_rows(label)
    case label
    when "basic"
      [
        [{tag: 0, value: "alpha"}, {tag: 1, value: 42}],
        [{tag: 0, value: "omega"}, {tag: 255}],
        [{tag: 255}, {tag: 255}],
      ]
    when "array_lc"
      [
        [
          [{tag: 0, value: "red"}, {tag: 1, value: 42}],
          [{tag: 1, value: 7}],
        ],
        [
          [{tag: 0, value: "blue"}, {tag: 1, value: 9}, {tag: 0, value: "red"}],
          [{tag: 0, value: "green"}],
        ],
        [[], []],
      ]
    else
      fail!("unknown W148 literal fixture #{label.inspect}")
    end
  end

  def self.variant_row_binary(value)
    case value[:tag]
    when 0
      "\x00".b + rb_string(value.fetch(:value))
    when 1
      "\x01".b + u64(value.fetch(:value))
    when 255
      "\xff".b
    else
      fail!("unknown W148 literal Variant tag #{value[:tag].inspect}")
    end
  end

  def self.row_binary(label, value)
    if label == "basic"
      variant_row_binary(value)
    else
      values = value
      var_uint(values.size) + values.map { |item| variant_row_binary(item) }.join.b
    end
  end

  def self.expected_stock_tsv(label)
    type = label == "basic" ? BASIC_TYPE : ARRAY_TYPE
    rows = literal_rows(label).flatten(1)
    rows.each_with_index.map do |value, index|
      row_id = label == "basic" ? index + 1 : index + 1
      "#{row_id}\t#{type}\t#{row_binary(label, value).unpack1('H*').upcase}\n"
    end.join
  end

  def self.expected_native_tsv(label, values: literal_rows(label).flatten(1))
    type = label == "basic" ? BASIC_TYPE : ARRAY_TYPE
    type_hex = type.encode(Encoding::UTF_8).b.unpack1("H*").upcase
    values.map do |value|
      "#{type_hex}\t#{row_binary(label, value).unpack1('H*').upcase}\n"
    end.join
  end

  def self.basic_insert_sql
    t = DECLARED_BASIC_TYPE
    "INSERT INTO default.stock_basic VALUES " \
      "(1, CAST('alpha', '#{t}')), " \
      "(2, CAST(toUInt64(42), '#{t}')), " \
      "(3, CAST('omega', '#{t}')), " \
      "(4, CAST(NULL, '#{t}')), " \
      "(5, CAST(NULL, '#{t}')), " \
      "(6, CAST(NULL, '#{t}'))"
  end

  def self.array_insert_sql
    canonical_variant = "Variant(LowCardinality(String), UInt64)"
    array_type = "Array(#{canonical_variant})"
    lc = ->(value) { "CAST('#{value}', '#{canonical_variant}')" }
    uint = ->(value) { "CAST(toUInt64(#{value}), '#{canonical_variant}')" }
    array = ->(items) { "CAST([#{items.join(', ')}], '#{array_type}')" }
    empty = "CAST([], '#{array_type}')"
    values = [
      array.call([lc.call("red"), uint.call(42)]),
      array.call([uint.call(7)]),
      array.call([lc.call("blue"), uint.call(9), lc.call("red")]),
      array.call([lc.call("green")]),
      empty,
      empty,
    ]
    "INSERT INTO default.stock_array_lc VALUES " + values.each_with_index.map { |value, index| "(#{index + 1}, #{value})" }.join(", ")
  end

  def self.choose_root
    requested = ENV["W148_VARIANT_OUTPUT"]
    if requested && !requested.empty?
      assert(ROOT_PATTERN.match?(requested), "W148 output must be a direct /private/tmp namespace child")
      assert(File.expand_path(requested) == requested, "W148 output root must be canonical")
      assert(!File.symlink?(requested) && !File.exist?(requested), "refusing existing or symlink W148 output root")
      Dir.mkdir(requested, 0o700)
      requested
    else
      Dir.mktmpdir("crystal-click-w148.", "/private/tmp")
    end
  end

  def self.validate_root(root, require_fresh: false)
    assert(ROOT_PATTERN.match?(root), "W148 root escaped its direct /private/tmp namespace")
    assert(File.expand_path(root) == root, "W148 root must be canonical")
    assert(!File.symlink?(root) && File.directory?(root), "W148 root must be a non-symlink directory")
    assert(File.realpath(root) == root, "W148 root resolves to another path")
    if require_fresh
      assert(Dir.children(root).empty?, "refusing nonempty W148 output root")
    end
  end

  def self.local(binary, store, query, prefix, stdin_data: "", extra: [])
    write_new("#{prefix}.sql", query + "\n")
    args = [
      "local", "--path", store, "--session_timezone=UTC", "--max_threads=1",
      "--max_insert_threads=1", "--max_block_size=1000", "--max_query_size=1048576",
      "--max_memory_usage=536870912", "--allow_suspicious_variant_types=1",
      "--allow_suspicious_low_cardinality_types=1", "--print_pretty_type_names=0",
      *extra, "--query", query,
    ]
    stdout, stderr, status = Open3.capture3({"TZ" => "UTC"}, binary, *args, stdin_data: stdin_data)
    assert(stdout.bytesize <= MAX_CAPTURE && stderr.bytesize <= MAX_CAPTURE,
      "W148 ClickHouse output exceeded 1 MiB for #{query.inspect}")
    write_new("#{prefix}.stdout", stdout.b)
    write_new("#{prefix}.stderr", stderr.b)
    [stdout.b, stderr.b, status]
  end

  def self.local!(binary, store, query, prefix, stdin_data: "", extra: [])
    stdout, stderr, status = local(binary, store, query, prefix, stdin_data: stdin_data, extra: extra)
    assert(status.success?, "ClickHouse failed (#{status.exitstatus}) for #{query.inspect}: #{stderr.inspect}")
    stdout
  end

  def self.verify_source!(identity)
    assert(File.directory?(SOURCE_ROOT) && !File.symlink?(SOURCE_ROOT), "pinned ClickHouse source is missing or symlinked")
    stdout, stderr, status = Open3.capture3("git", "-C", SOURCE_ROOT, "rev-parse", "HEAD")
    write_new("#{identity}/source-revision.stdout", stdout.b)
    write_new("#{identity}/source-revision.stderr", stderr.b)
    assert(status.success? && stdout.strip == SOURCE_REVISION,
      "pinned ClickHouse source revision differs: #{stdout.inspect} #{stderr.inspect}")
  end

  def self.verify_runtime!(binary, identity)
    assert(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary), "pinned ClickHouse executable missing or symlinked")
    sha = Digest::SHA256.file(binary).hexdigest
    assert(sha == EXPECTED_BINARY_SHA256, "pinned runtime SHA differs: #{sha}")
    store = File.join(identity, "store")
    Dir.mkdir(store, 0o700)
    version = local!(binary, store, "SELECT version() FORMAT TSVRaw", File.join(identity, "version")).strip
    assert(version == EXPECTED_VERSION, "pinned runtime version differs: #{version.inspect}")
    options = local!(binary, store,
      "SELECT concat(name, '=', value) FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw",
      File.join(identity, "build-options")).lines.map(&:strip)
    expected = ["GIT_HASH=#{EXPECTED_BUILD_HASH}", "VERSION_GITHASH=#{EXPECTED_BUILD_HASH}"]
    assert(options == expected, "pinned build hash differs: #{options.inspect}")
    {sha256: sha, version: version, build_options: options}
  end

  def self.u64_at(bytes, offset, label)
    assert(offset >= 0 && offset + 8 <= bytes.bytesize, "#{label}: truncated UInt64")
    bytes.byteslice(offset, 8).unpack1("Q<")
  end

  def self.stream_hash(name)
    mask = (1 << 64) - 1
    v0, v1, v2, v3 = 0x736f6d6570736575, 0x646f72616e646f6d, 0x6c7967656e657261, 0x7465646279746573
    raw = name.encode(Encoding::UTF_8).b
    index = 0
    round = lambda do
      v0 = (v0 + v1) & mask; v1 = (((v1 << 13) | (v1 >> 51)) & mask) ^ v0; v0 = ((v0 << 32) | (v0 >> 32)) & mask
      v2 = (v2 + v3) & mask; v3 = (((v3 << 16) | (v3 >> 48)) & mask) ^ v2
      v0 = (v0 + v3) & mask; v3 = (((v3 << 21) | (v3 >> 43)) & mask) ^ v0
      v2 = (v2 + v1) & mask; v1 = (((v1 << 17) | (v1 >> 47)) & mask) ^ v2; v2 = ((v2 << 32) | (v2 >> 32)) & mask
    end
    while index + 8 <= raw.bytesize
      word = raw.byteslice(index, 8).unpack1("Q<")
      v3 ^= word; 2.times { round.call }; v0 ^= word
      index += 8
    end
    word = raw.bytesize << 56
    raw.byteslice(index, raw.bytesize - index).bytes.each_with_index { |byte, shift| word |= byte << (shift * 8) }
    v3 ^= word; 2.times { round.call }; v0 ^= word; v2 ^= 0xff
    4.times { round.call }
    format("%016x%016x", (v2 ^ v3), (v0 ^ v1))
  end

  def self.create_table(binary, store, name, declared_type, results)
    query = "CREATE TABLE default.#{name} (id UInt8, v #{declared_type}) ENGINE=MergeTree ORDER BY id SETTINGS " \
      "index_granularity=2, index_granularity_bytes=1048576, write_final_mark=1, min_rows_for_wide_part=0, " \
      "min_bytes_for_wide_part=0, compress_marks=0, default_compression_codec='LZ4', " \
      "string_serialization_version='with_size_stream', use_compact_variant_discriminators_serialization=0"
    local!(binary, store, query, File.join(results, "create-#{name}"))
  end

  def self.verify_table_witness!(binary, store, table, label, results)
    expected_type = label == "basic" ? BASIC_TYPE : ARRAY_TYPE
    count = local!(binary, store,
      "SELECT count(), any(toTypeName(v)) FROM default.#{table} FORMAT TSVRaw",
      File.join(results, "#{label}-count-type"))
    assert(count == "6\t#{expected_type}\n", "#{table} row-count/type mismatch: #{count.inspect}")
    if label == "basic"
      actual = local!(binary, store,
        "SELECT id, toTypeName(v), hex(formatRow('RowBinary', v)) FROM default.#{table} ORDER BY id FORMAT TSVRaw",
        File.join(results, "#{label}-value-witness"))
    else
      actual = local!(binary, store,
        "SELECT id, toTypeName(v), hex(formatRow('RowBinary', v)) FROM default.#{table} ORDER BY id FORMAT TSVRaw",
        File.join(results, "#{label}-value-witness"))
    end
    expected = expected_stock_tsv(label)
    assert(actual == expected, "#{table} independent type/RowBinary literal mismatch: #{actual.inspect} != #{expected.inspect}")
  end

  def self.sql_fixture!(binary, store, results)
    basic_table = "stock_basic"
    array_table = "stock_array_lc"
    create_table(binary, store, basic_table, DECLARED_BASIC_TYPE, results)
    local!(binary, store, basic_insert_sql, File.join(results, "insert-#{basic_table}"))
    create_table(binary, store, array_table, DECLARED_ARRAY_TYPE, results)
    local!(binary, store, array_insert_sql, File.join(results, "insert-#{array_table}"))
    verify_table_witness!(binary, store, basic_table, "basic", results)
    verify_table_witness!(binary, store, array_table, "array_lc", results)
    {"basic" => basic_table, "array_lc" => array_table}
  end

  def self.compressor_decode(binary, compressed, label)
    assert(compressed.bytesize <= MAX_EVIDENCE_BYTES, "#{label}: compressed lane exceeds 8 MiB")
    stdout, stderr, status = Open3.capture3(binary, "compressor", "--decompress", stdin_data: compressed)
    assert(stdout.bytesize <= MAX_EVIDENCE_BYTES && stderr.bytesize <= MAX_CAPTURE,
      "#{label}: decompressor output exceeded W148 bound")
    assert(status.success?, "pinned ClickHouse compressor failed for #{label}: #{stderr.inspect}")
    [stdout.b, stderr.b]
  end

  def self.compressed_frames(compressed, decompressed, label)
    frames = {}
    compressed_offset = 0
    decompressed_offset = 0
    while compressed_offset < compressed.bytesize
      assert(compressed_offset + 25 <= compressed.bytesize, "#{label}: compressed frame header truncated")
      compressed_size = compressed.byteslice(compressed_offset + 17, 4).unpack1("L<")
      frame_uncompressed_size = compressed.byteslice(compressed_offset + 21, 4).unpack1("L<")
      frame_size = 16 + compressed_size
      assert(compressed_size >= 9 && frame_size <= compressed.bytesize - compressed_offset,
        "#{label}: compressed frame size invalid")
      assert(frame_uncompressed_size > 0, "#{label}: empty compressed frame is outside this witness")
      frames[compressed_offset] = decompressed_offset
      compressed_offset += frame_size
      decompressed_offset += frame_uncompressed_size
    end
    assert(compressed_offset == compressed.bytesize, "#{label}: compressed frame coverage differs")
    assert(decompressed_offset == decompressed.bytesize,
      "#{label}: frame sizes #{decompressed_offset} differ from ClickHouse decompressor output #{decompressed.bytesize}")
    frames[compressed.bytesize] = decompressed.bytesize
    frames
  end

  def self.mark_records(raw, expected_count, label)
    assert(raw.bytesize.positive? && (raw.bytesize % 24).zero?, "#{label}: .mrk2 bytes are not UInt64 triples")
    records = raw.bytes.each_slice(24).map do |slice|
      slice.pack("C*").unpack("Q<3")
    end
    assert(records.size == expected_count, "#{label}: expected #{expected_count} mark records including terminal record, got #{records.size}")
    assert(records[0...-1].map { |record| record[2] } == [2, 2, 2],
      "#{label}: expected three observed parent-mark row counts [2, 2, 2], got #{records.map { |record| record[2] }.inspect}")
    assert(records.last[2] == 0, "#{label}: final .mrk2 record is not the rows=0 terminal record")
    records
  end

  def self.absolute_marks(records, frames, decompressed_size, label)
    offsets = records.map.with_index do |(compressed, relative, _rows), index|
      base = frames[compressed]
      assert(!base.nil?, "#{label} mark #{index}: compressed offset #{compressed} is not a frame boundary or EOF")
      absolute = base + relative
      assert(absolute <= decompressed_size, "#{label} mark #{index}: decompressed coordinate exceeds EOF")
      absolute
    end
    assert(offsets.each_cons(2).all? { |pair| pair[0] <= pair[1] }, "#{label}: mapped mark grid is not monotone")
    assert(offsets.last == decompressed_size, "#{label}: terminal mapped mark is not the actual uncompressed EOF")
    offsets
  end

  def self.part_path!(binary, store, table, prefix)
    paths = local!(binary, store,
      "SELECT path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw",
      prefix).lines.map(&:strip).reject(&:empty?)
    assert(paths.size == 1, "#{table}: expected one active Wide part, got #{paths.inspect}")
    path = paths.first
    assert(File.directory?(path) && !File.symlink?(path), "#{table}: active part path unavailable")
    canonical_store = File.realpath(store)
    canonical_part = File.realpath(path)
    assert(canonical_part.start_with?(canonical_store + File::SEPARATOR), "#{table}: stock part escaped isolated store")
    path
  end

  def self.bind_specs(label, substreams)
    if label == "basic"
      discr = "v.variant_discr"
      assert(substreams.include?(discr), "basic Variant discriminator substream is missing: #{substreams.inspect}")
      separate_prefix = substreams.include?("v.variant_discr_prefix")
      common = ["v.UInt64", discr]
      common << "v.variant_discr_prefix" if separate_prefix
      string_shapes = [
        ["v.String.size", "v.String"],
        ["v.String"],
      ]
      string_shape = string_shapes.find { |shape| shape.all? { |name| substreams.include?(name) } }
      assert(string_shape, "basic Variant String substream shape is outside the two authored profiles: #{substreams.inspect}")
      expected = (common + string_shape).sort
      assert(substreams.sort == expected, "basic physical substream inventory differs from finite witness: #{substreams.inspect}")
      lanes = [
        {role: "root.discriminators", substream: discr, normalize_variant_prefix: !separate_prefix},
        {role: "root.arm.0.data", substream: "v.String"},
        {role: "root.arm.1.data", substream: "v.UInt64"},
      ]
      lanes.insert(1, {role: "root.arm.0.string_sizes", substream: "v.String.size"}) if string_shape.include?("v.String.size")
      {lanes: lanes, profile: string_shape.size == 2 ? "with_size_stream" : "single_stream",
       prefix_substream: separate_prefix ? "v.variant_discr_prefix" : nil}
    else
      discr = "v.variant_discr"
      assert(substreams.include?(discr), "Array Variant discriminator substream is missing: #{substreams.inspect}")
      separate_prefix = substreams.include?("v.variant_discr_prefix")
      lc_name = "v.LowCardinality%28String%29"
      expected_names = ["v.size0", discr, "#{lc_name}.dict", lc_name, "v.UInt64"]
      expected_names << "v.variant_discr_prefix" if separate_prefix
      expected = expected_names.sort
      assert(substreams.sort == expected, "Array(Variant(LC(String), UInt64)) physical substream inventory differs: #{substreams.inspect}")
      {
        lanes: [
          {role: "root.sizes", substream: "v.size0"},
          {role: "root.elements.discriminators", substream: discr, normalize_variant_prefix: !separate_prefix},
          {role: "root.elements.arm.0.dictionary", substream: "#{lc_name}.dict"},
          {role: "root.elements.arm.0.indexes", substream: lc_name},
          {role: "root.elements.arm.1.data", substream: "v.UInt64"},
        ], profile: "with_size_stream", prefix_substream: separate_prefix ? "v.variant_discr_prefix" : nil,
      }
    end
  end

  def self.read_part_fixture!(binary, store, root, label, table)
    results = File.join(root, "results", "stock-#{label}")
    Dir.mkdir(results, 0o700)
    part = part_path!(binary, store, table, File.join(results, "part-path"))
    files = Dir.children(part).sort
    files.each do |name|
      path = File.join(part, name)
      assert(!File.symlink?(path) && File.file?(path), "#{label}: unexpected symlink/non-file in part")
    end
    substreams_path = File.join(part, "columns_substreams.txt")
    assert(File.file?(substreams_path) && !File.symlink?(substreams_path), "#{label}: columns_substreams.txt missing")
    substreams_raw = File.binread(substreams_path)
    write_new(File.join(results, "columns_substreams.txt"), substreams_raw)
    substreams = substreams_raw.lines.map(&:strip).select { |line| line.start_with?("v.") }
    table_columns = File.binread(File.join(part, "columns.txt"))
    write_new(File.join(results, "columns.txt"), table_columns)
    mapping = bind_specs(label, substreams)

    part_name = File.basename(part)
    check = local!(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated", File.join(results, "check-table"))
    assert(check == "#{part_name}\t1\t\n", "#{label}: CHECK TABLE terminal result differs: #{check.inspect}")
    part_counts = local!(binary, store,
      "SELECT rows, marks FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw",
      File.join(results, "part-counts"))
    # ClickHouse system.parts.marks includes the terminal EOF mark; the
    # logical lane grid and real granule count remain MARKS=3.
    assert(part_counts == "6\t#{MARKS + 1}\n", "#{label}: stock part rows/marks (including terminal mark) differ: #{part_counts.inspect}")

    manifest_lanes = []
    observed_parent_rows = nil
    combined_prefix_hex = nil
    mapping.fetch(:lanes).each_with_index do |lane, lane_index|
      substream = lane.fetch(:substream)
      stem = stream_hash(substream)
      bin_path = File.join(part, "#{stem}.bin")
      mark_path = File.join(part, "#{stem}.mrk2")
      assert(File.file?(bin_path) && !File.symlink?(bin_path), "#{label}: manually bound #{substream} .bin missing")
      assert(File.file?(mark_path) && !File.symlink?(mark_path), "#{label}: manually bound #{substream} .mrk2 missing")
      compressed = File.binread(bin_path)
      mark_bytes = File.binread(mark_path)
      bytes, decompress_stderr = compressor_decode(binary, compressed, "#{label} #{substream}")
      frames = compressed_frames(compressed, bytes, "#{label} #{substream}")
      records = mark_records(mark_bytes, MARKS + 1, "#{label} #{substream}")
      row_grid = records[0...-1].map { |record| record[2] }
      if observed_parent_rows
        assert(row_grid == observed_parent_rows,
          "#{label}: #{substream} .mrk2 parent row grid differs from other lanes: #{row_grid.inspect} != #{observed_parent_rows.inspect}")
      else
        observed_parent_rows = row_grid
      end
      raw_offsets = absolute_marks(records, frames, bytes.bytesize, "#{label} #{substream}")
      prefix_kind = "none"
      prefix_bytes = nil
      if lane[:normalize_variant_prefix]
        first_word = u64_at(bytes, 0, "#{label} #{substream} BASIC mode")
        assert(first_word == 0, "#{label}: combined Variant discriminator prefix is not BASIC mode 0")
        assert(raw_offsets.all? { |offset| offset >= 8 }, "#{label}: combined Variant prefix overlaps a mark")
        combined_prefix_hex = bytes.byteslice(0, 8).unpack1("H*")
        bytes = bytes.byteslice(8, bytes.bytesize - 8)
        offsets = raw_offsets.map { |offset| offset - 8 }
        prefix_kind = "combined-basic-u64-zero-removed-from-discriminator-lane"
      else
        offsets = raw_offsets
      end

      # Preserve compressed bytes, original marks and decompressed bytes, each
      # with distinct roles. This makes the extraction path auditable without
      # claiming compressed-checksum validation or complete part reproduction.
      write_new(File.join(results, "#{stem}.bin.compressed"), compressed)
      write_new(File.join(results, "#{stem}.mrk2"), mark_bytes)
      lane_dir = File.join(root, "inputs", label)
      lane_file = "lane-#{lane_index}.bin"
      write_new(File.join(lane_dir, lane_file), bytes)
      role_offsets = offsets
      lane_metadata = {
        "role" => lane.fetch(:role), "substream" => substream, "basename" => stem,
        "bytes_file" => lane_file, "bytes_sha256" => Digest::SHA256.hexdigest(bytes),
        "physical_compressed_sha256" => Digest::SHA256.hexdigest(compressed),
        "physical_marks_sha256" => Digest::SHA256.hexdigest(mark_bytes),
        "physical_marks" => records.map { |record| {"compressed_offset" => record[0], "decompressed_offset_within_frame" => record[1], "rows" => record[2]} },
        "physical_uncompressed_offsets" => raw_offsets,
        "normalized_offsets" => role_offsets, "variant_prefix_normalization" => prefix_kind,
        "combined_prefix_hex" => lane[:normalize_variant_prefix] ? combined_prefix_hex : nil,
        "frame_count" => frames.size - 1, "decompress_stderr" => decompress_stderr,
      }
      manifest_lanes << lane_metadata
    end

    if prefix = mapping[:prefix_substream]
      prefix_stem = stream_hash(prefix)
      prefix_bin = File.join(part, "#{prefix_stem}.bin")
      prefix_marks = File.join(part, "#{prefix_stem}.mrk2")
      assert(File.file?(prefix_bin) && File.file?(prefix_marks), "#{label}: separate Variant prefix files missing")
      raw_prefix = File.binread(prefix_bin)
      separate_prefix, stderr = compressor_decode(binary, raw_prefix, "#{label} #{prefix}")
      assert(separate_prefix.bytesize == 8 && u64_at(separate_prefix, 0, "#{label} separate prefix") == 0,
        "#{label}: separate Variant prefix is not exactly BASIC mode 0")
      prefix_mark_bytes = File.binread(prefix_marks)
      prefix_records = mark_records(prefix_mark_bytes, MARKS + 1, "#{label} #{prefix}")
      write_new(File.join(results, "variant-prefix.bin"), separate_prefix)
      write_new(File.join(results, "#{prefix_stem}.bin.compressed"), raw_prefix)
      write_new(File.join(results, "#{prefix_stem}.mrk2"), prefix_mark_bytes)
      prefix_bytes = separate_prefix.unpack1("H*")
      manifest_lanes << {"role" => "transport.variant_prefix", "substream" => prefix,
        "basename" => prefix_stem, "bytes_file" => nil, "bytes_sha256" => Digest::SHA256.hexdigest(separate_prefix),
        "physical_compressed_sha256" => Digest::SHA256.hexdigest(raw_prefix), "variant_prefix_normalization" => "separate-basic-u64-zero-captured-independently",
        "bytes_artifact" => "variant-prefix.bin",
        "physical_marks_sha256" => Digest::SHA256.hexdigest(prefix_mark_bytes),
        "physical_marks" => prefix_records.map { |record| {"compressed_offset" => record[0], "decompressed_offset_within_frame" => record[1], "rows" => record[2]} },
        "decompress_stderr" => stderr}
    end

    rows_per_mark = observed_parent_rows || fail!("#{label}: no physical lanes observed a parent row grid")
    profile = mapping.fetch(:profile)
    manifest = {
      "label" => label, "table" => table,
      "declared_type" => label == "basic" ? DECLARED_BASIC_TYPE : DECLARED_ARRAY_TYPE,
      "canonical_type" => label == "basic" ? BASIC_TYPE : ARRAY_TYPE,
      "rows_per_mark" => rows_per_mark, "mark_count" => MARKS,
      "logical_profile" => profile, "substreams" => substreams,
      "prefix_transport" => mapping[:prefix_substream] ? "separate" : (combined_prefix_hex ? "combined" : "not-observed"),
      "separate_variant_prefix_hex" => prefix_bytes,
      "combined_variant_prefix_hex" => combined_prefix_hex,
      "lane_count_including_transport" => manifest_lanes.size,
      "lanes" => manifest_lanes,
      "scope" => "finite stock Wide part decompressed lane and K+1 mark-grid witness; no complete part writer or generic binder claim",
    }
    write_json_new(File.join(root, "inputs", label, "manifest.json"), manifest)
    manifest
  end

  def self.new_discovery
    assert(ENV["W148_EXECUTE_AS_ROOT"] == "YES", "root-owned W148_EXECUTE_AS_ROOT=YES is required")
    root = choose_root
    validate_root(root, require_fresh: true)
    %w[stores results inputs].each { |name| Dir.mkdir(File.join(root, name), 0o700) }
    %w[basic array_lc].each { |name| Dir.mkdir(File.join(root, "inputs", name), 0o700) }
    identity = File.join(root, "results", "identity")
    Dir.mkdir(identity, 0o700)
    verify_source!(identity)
    runtime = verify_runtime!(BIN, identity)
    store = File.join(root, "stores", "main")
    Dir.mkdir(store, 0o700)
    results = File.join(root, "results")
    tables = sql_fixture!(BIN, store, results)
    basic = read_part_fixture!(BIN, store, root, "basic", tables.fetch("basic"))
    array_lc = read_part_fixture!(BIN, store, root, "array_lc", tables.fetch("array_lc"))
    write_new(File.join(results, "discovery.txt"), [
      "status=stock-discovery-complete",
      "source_reference_checkout=#{SOURCE_ROOT}", "source_reference_revision=#{SOURCE_REVISION}",
      "runtime_binary=#{BIN}", "runtime_sha256=#{runtime.fetch(:sha256)}",
      "runtime_version=#{runtime.fetch(:version)}", *runtime.fetch(:build_options),
      "provenance=source reference and runtime are pinned separately; runtime is not asserted built from this source",
      "profiles=Variant(String, UInt64) with independently detected String serialization profile; Array(Variant(LowCardinality(String), UInt64))",
      "stock_baseline=MergeTree scratch tables persist across local invocations; harness storage only",
      "prefix=actual emitted filenames determine separate versus combined BASIC UInt64 mode prefix; combined mode strips exactly 8 bytes and subtracts 8 from discriminator marks; separate mode captures/hash-pins prefix and leaves discriminator grid unchanged",
      "marks=three real Wide granules with 2 parent rows each; K+1 .mrk2 records including terminal rows=0 and mapped EOF",
      "native=not run in discovery mode",
      "scope=direct stock physical lane/grid discovery only; no complete part writer, generic binder, Object/Dynamic, MV/projection, or performance claim",
      "basic_substreams=#{basic.fetch('substreams').join(',')}",
      "array_lc_substreams=#{array_lc.fetch('substreams').join(',')}",
      "claim_boundary=ClickHouse local runtime is official binary build #{EXPECTED_BUILD_HASH}; it was not built from source checkout #{SOURCE_REVISION}",
    ].join("\n") + "\n")
    count, bytes = audit_tree(root)
    assert(count <= MAX_EVIDENCE_FILES && bytes <= MAX_EVIDENCE_BYTES,
      "W148 discovery evidence exceeded bounded tree: files=#{count}, bytes=#{bytes}")
    puts "PASS W148 stock Wide discovery: #{root} files=#{count} bytes=#{bytes}"
  end

  def self.audit_tree(root)
    count = 0
    bytes = 0
    walk = lambda do |path|
      Dir.children(path).each do |name|
        child = File.join(path, name)
        if File.symlink?(child)
          # Atomic databases create these aliases themselves. Do not follow
          # them or double-count the canonical store; all other evidence
          # symlinks, dangling aliases and targets outside that store fail.
          alias_match = child.match(%r{\A#{Regexp.escape(root)}/stores/(main|native-basic|native-array_lc|native-basic-mutant)/(?:metadata/default|data/default/(?:stock_basic|stock_array_lc))\z})
          assert(alias_match && File.directory?(child), "W148 evidence contains an unexpected symlink: #{child}")
          canonical_store = File.join(root, "stores", alias_match[1], "store") + File::SEPARATOR
          assert(File.realpath(child).start_with?(canonical_store), "W148 stock alias escapes its canonical store: #{child}")
          next
        end
        if File.directory?(child)
          walk.call(child)
        else
          assert(File.file?(child), "W148 evidence contains non-regular file: #{child}")
          count += 1
          bytes += File.size(child)
        end
      end
    end
    walk.call(root)
    [count, bytes]
  end

  def self.exchange_existing(root, checker)
    assert(ENV["W148_EXECUTE_AS_ROOT"] == "YES", "root-owned W148_EXECUTE_AS_ROOT=YES is required")
    validate_root(root)
    assert(File.file?(File.join(root, "results", "discovery.txt")), "W148 discovery evidence is required before exchange")
    assert(File.file?(checker) && File.executable?(checker) && !File.symlink?(checker), "explicit W148 checker must be executable and non-symlinked")
    assert(File.expand_path(checker) == checker, "W148 checker path must be absolute and canonical")
    results = File.join(root, "results")
    exchange_results = File.join(results, "exchange")
    Dir.mkdir(exchange_results, 0o700)
    identity = File.join(exchange_results, "identity")
    Dir.mkdir(identity, 0o700)
    verify_source!(identity)
    runtime = verify_runtime!(BIN, identity)
    checker_sha = Digest::SHA256.file(checker).hexdigest
    checker_stdout, checker_stderr, checker_status = Open3.capture3(checker, "exchange", root)
    assert(checker_stdout.bytesize <= 65_536 && checker_stderr.bytesize <= 65_536, "W148 checker output exceeded bound")
    write_new(File.join(exchange_results, "checker.stdout"), checker_stdout.b)
    write_new(File.join(exchange_results, "checker.stderr"), checker_stderr.b)
    assert(checker_status.success?, "W148 checker exchange failed (#{checker_status.exitstatus}): #{checker_stderr.inspect}")

    mutant_rows = literal_rows("basic").flatten(1).map do |value|
      value[:tag] == 1 && value[:value] == 42 ? {tag: 1, value: 43} : value
    end
    mutant_expected = expected_native_tsv("basic", values: mutant_rows)
    checker_literals = {
      "expected-library-basic.tsv" => expected_native_tsv("basic"),
      "expected-library-array_lc.tsv" => expected_native_tsv("array_lc"),
      "expected-library-basic-mutant.tsv" => mutant_expected,
    }
    checker_literals.each do |name, expected|
      path = File.join(exchange_results, name)
      assert(File.file?(path) && !File.symlink?(path), "W148 checker literal output is missing or symlinked: #{name}")
      assert(File.size(path) <= MAX_CAPTURE, "W148 checker literal output exceeds bound: #{name}")
      actual = File.binread(path)
      assert(actual == expected,
        "W148 checker expected TSV differs from independently authored Ruby literal #{name}: #{actual.inspect} != #{expected.inspect}")
    end

    native_specs = [
      ["basic", BASIC_TYPE, expected_native_tsv("basic")],
      ["array_lc", ARRAY_TYPE, expected_native_tsv("array_lc")],
    ]
    native_specs.each do |label, type, expected|
      native_path = File.join(root, "native-input", "library-#{label}.native")
      actual = consume_native!(BIN, root, exchange_results, label, type, native_path)
      assert(actual == expected, "#{label}: stock Native consumer differs from independent literal TSV: #{actual.inspect} != #{expected.inspect}")
    end

    assert(mutant_expected != expected_native_tsv("basic"), "valid wrong-value literal did not change the expected stock output")
    mutant_actual = consume_native!(BIN, root, exchange_results, "basic-mutant", BASIC_TYPE,
      File.join(root, "native-input", "library-basic-mutant.native"))
    assert(mutant_actual == mutant_expected,
      "valid wrong-value Native consumer output differs from independently authored mutant literal: #{mutant_actual.inspect} != #{mutant_expected.inspect}")
    assert(mutant_actual != expected_native_tsv("basic"), "stock Native consumer failed to expose the valid UInt64 42->43 mutation")

    write_new(File.join(exchange_results, "exchange.txt"), [
      "status=library-logical-lanes-to-stock-Native-consumer-pass",
      "source_reference_checkout=#{SOURCE_ROOT}", "source_reference_revision=#{SOURCE_REVISION}",
      "runtime_binary=#{BIN}", "runtime_sha256=#{runtime.fetch(:sha256)}", "runtime_version=#{runtime.fetch(:version)}",
      *runtime.fetch(:build_options), "checker_sha256=#{checker_sha}",
      "payloads=library-basic.native,library-array_lc.native; Native prefix and sparse body adapters use library-emitted normalized lanes",
      "control=valid UInt64 42->43 lane mutation is accepted by stock Native input, exact changed TSV matches the mutant literal and differs from original",
      "claim_scope=finite logical role/grid and Native consumer exchange; not complete part writer, generic physical binder, Object/Dynamic, MV/projection, or performance",
    ].join("\n") + "\n")
    count, bytes = audit_tree(root)
    assert(count <= MAX_EVIDENCE_FILES && bytes <= MAX_EVIDENCE_BYTES,
      "W148 exchange evidence exceeded bounded tree: files=#{count}, bytes=#{bytes}")
    puts "PASS W148 stock/library Native exchange: #{root} files=#{count} bytes=#{bytes}"
  end

  def self.consume_native!(binary, root, results, label, type, native_path)
    assert(File.file?(native_path) && !File.symlink?(native_path), "#{label}: checker Native payload is missing or symlinked")
    native = File.binread(native_path)
    assert(native.bytesize <= MAX_CAPTURE, "#{label}: Native input exceeds 1 MiB")
    store = File.join(root, "stores", "native-#{label}")
    assert(!File.exist?(store) && !File.symlink?(store), "#{label}: refusing an existing Native consumer store")
    Dir.mkdir(store, 0o700)
    query = "SELECT hex(toTypeName(x)), hex(formatRow('RowBinary', x)) FROM table FORMAT TSVRaw"
    write_new(File.join(results, "consumer-#{label}.sql"), query + "\n")
    args = [
      "local", "--path", store, "--session_timezone=UTC", "--max_threads=1",
      "--max_insert_threads=1", "--max_block_size=1000", "--max_query_size=1048576",
      "--max_memory_usage=536870912", "--allow_suspicious_variant_types=1",
      "--allow_suspicious_low_cardinality_types=1", "--print_pretty_type_names=0",
      "--input-format", "Native", "--structure", "x #{type}", "--query", query,
    ]
    argv_record = [binary, *args].map { |arg| arg.include?(" ") ? arg.inspect : arg }.join(" ") + "\n"
    write_new(File.join(results, "consumer-#{label}.argv.txt"), argv_record)
    stdout, stderr, status = Open3.capture3({"TZ" => "UTC"}, binary, *args, stdin_data: native)
    assert(stdout.bytesize <= MAX_CAPTURE && stderr.bytesize <= MAX_CAPTURE, "#{label}: stock Native output exceeded 1 MiB")
    write_new(File.join(results, "consumer-#{label}.stdout"), stdout.b)
    write_new(File.join(results, "consumer-#{label}.stderr"), stderr.b)
    assert(status.success?, "#{label}: stock Native consumer rejected library payload (#{status.exitstatus}): #{stderr.inspect}")
    stdout.b
  end

  def self.run
    mode = ARGV.shift
    case mode
    when "discovery"
      assert(ARGV.empty?, "usage: probe_variant_bulk_w148.rb discovery")
      new_discovery
    when "exchange"
      assert(ARGV.size == 2, "usage: probe_variant_bulk_w148.rb exchange /absolute/root /absolute/checker")
      exchange_existing(ARGV[0], ARGV[1])
    else
      fail!("usage: probe_variant_bulk_w148.rb discovery | exchange /absolute/root /absolute/checker")
    end
  end
end

VariantBulkW148.run
