#!/usr/bin/env ruby
# Independent literal stock consumer for W149. No Crystal codec or fixture
# manifest supplies expected values; invoke serially through the root guard.
require "digest"
require "open3"

module VariantPhysicalLiteralRecheck
  BINARY = "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped"
  SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  BUILD = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  SOURCE = "/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-9007d227"
  REVISION = "9007d227b64a3f8b667fc5258ceb2923f3cf477d"
  MAX_CAPTURE = 1_048_576
  TYPES = {
    "root" => ["Variant(String, UInt64)", "Variant(String, UInt64)"],
    "array_lc" => ["Array(Variant(LowCardinality(String), UInt64))"] * 2,
    "array_nested" => ["Array(Variant(Array(UInt8), UInt64))"],
  }.freeze

  def self.assert(condition, message)
    raise message unless condition
  end

  def self.varuint(number)
    assert(number >= 0, "negative literal VarUInt")
    bytes = +"".b
    loop do
      byte = number & 0x7f
      number >>= 7
      bytes << (number.zero? ? byte : byte | 0x80)
      break if number.zero?
    end
    bytes
  end

  def self.variant(value)
    case value
    when nil then "\xff".b
    when String then "\x00".b + varuint(value.bytesize) + value.b
    when Array then "\x00".b + varuint(value.size) + value.pack("C*")
    when Integer then "\x01".b + [value].pack("Q<")
    else raise "unknown literal Variant value"
    end
  end

  def self.array(values)
    varuint(values.size) + values.map { |value| variant(value) }.join.b
  end

  def self.rows(shape, mutant: false)
    case shape
    when "root"
      main = ["alpha", mutant ? 43 : 42, "omega", nil, nil, 7]
      unused = ["u0", "u1", "u2", "u3", "u4", nil]
      main.zip(unused).map { |a, b| variant(a) + variant(b) }
    when "array_lc"
      main = [["red", 42], [7], ["blue", 9, "red"], ["green"], [], []]
      unused = [[5], [], [8, 9], [], [], [10]]
      main.zip(unused).map { |a, b| array(a) + array(b) }
    when "array_nested"
      [[[1, 2], 42], [7], [[3]], [], [], [9]].map { |a| array(a) }
    else raise "unknown literal shape"
    end
  end

  def self.query(store, sql, output, label)
    assert(File.directory?(store) && !File.symlink?(store), "missing or symlinked store: #{store}")
    prefix = File.join(output, label)
    assert(!File.exist?(prefix + ".sql"), "refusing to overwrite oracle evidence")
    File.write(prefix + ".sql", sql + "\n")
    stdout, stderr, status = Open3.capture3(
      {"TZ" => "UTC"}, BINARY, "local", "--path", store,
      "--session_timezone=UTC", "--max_threads=1", "--max_insert_threads=1",
      "--max_block_size=1000", "--max_memory_usage=536870912",
      "--max_query_size=1048576", "--allow_suspicious_variant_types=1",
      "--allow_suspicious_low_cardinality_types=1", "--print_pretty_type_names=0",
      "--low_cardinality_max_dictionary_size=8192",
      "--low_cardinality_use_single_dictionary_for_part=0",
      "--query", sql
    )
    assert(stdout.bytesize <= MAX_CAPTURE && stderr.bytesize <= MAX_CAPTURE, "oversized oracle capture")
    File.binwrite(prefix + ".stdout", stdout.b)
    File.binwrite(prefix + ".stderr", stderr.b)
    File.write(prefix + ".status", status.exitstatus.to_s + "\n")
    assert(status.success?, "stock query failed: #{label}: #{stderr.inspect}")
    stdout.b
  end

  def self.check_table(root, output, shape, cell, direction, table, mutant: false)
    store = File.join(root, "stores", "#{direction}_#{cell}")
    columns = shape == "root" ? ["v", "v_unused_ordinary"] :
      shape == "array_lc" ? ["v", "v_unused_lc"] : ["v"]
    label = "#{direction}_#{cell}"
    type_sql = "SELECT #{columns.map { |column| "toTypeName(#{column})" }.join(',')} FROM default.#{table} LIMIT 1 FORMAT TSVRaw"
    actual_types = query(store, type_sql, output, label + "_types")
    assert(actual_types == TYPES.fetch(shape).join("\t") + "\n", "nominal type mismatch: #{label}")
    literal = rows(shape, mutant: mutant)
    [["full", "", literal], ["middle", " WHERE k IN (2,3)", literal[1, 2]]].each do |window, predicate, selected|
      sql = "SELECT #{columns.join(',')} FROM default.#{table}#{predicate} ORDER BY k FORMAT RowBinary"
      actual = query(store, sql, output, label + "_" + window)
      expected = selected.join.b
      File.binwrite(File.join(output, label + "_" + window + ".expected"), expected)
      assert(actual == expected, "literal RowBinary mismatch: #{label} #{window}: #{actual.unpack1('H*')} != #{expected.unpack1('H*')}")
      if mutant
        original = (window == "full" ? rows(shape) : rows(shape)[1, 2]).join.b
        assert(actual != original, "valid wrong-value control failed to reject original literal: #{window}")
      end
    end
    check = query(store, "CHECK TABLE default.#{table} FORMAT TSVRaw", output, label + "_check")
    assert(["1\t\n", "1\n", "all_1_1_0\t1\t\n"].include?(check), "actual CHECK did not return success: #{label}: #{check.inspect}")
  end

  def self.run
    assert(ENV["W149_EXECUTE_AS_ROOT"] == "YES", "root-owned serial guard required")
    root = ARGV.fetch(0)
    assert(root.match?(%r{\A/private/tmp/crystal-click-variant-physical-w149\.[A-Za-z0-9_-]+\z}), "invalid W149 evidence root")
    assert(File.directory?(root) && !File.symlink?(root), "missing or symlinked evidence root")
    assert(File.file?(BINARY) && File.executable?(BINARY) && !File.symlink?(BINARY), "missing pinned runtime")
    assert(Digest::SHA256.file(BINARY).hexdigest == SHA256, "pinned runtime SHA mismatch")
    assert(File.directory?(SOURCE) && !File.symlink?(SOURCE), "missing pinned source")
    revision, error, status = Open3.capture3("git", "-C", SOURCE, "rev-parse", "HEAD")
    assert(status.success? && revision.strip == REVISION, "source revision mismatch: #{error}")
    output = File.join(root, "ruby-recheck")
    assert(!File.exist?(output) && !File.symlink?(output), "refusing to overwrite Ruby evidence")
    Dir.mkdir(output, 0o700)
    identity_store = File.join(root, "stores", "stock_root_single_stream")
    version = query(identity_store, "SELECT version() FORMAT TSVRaw", output, "identity_version")
    assert(version == "26.10.1.1201\n", "runtime version mismatch")
    build = query(identity_store, "SELECT concat(name,'=',value) FROM system.build_options WHERE name IN ('GIT_HASH','VERSION_GITHASH') ORDER BY name FORMAT TSVRaw", output, "identity_build")
    assert(build.lines.map(&:strip) == ["GIT_HASH=#{BUILD}", "VERSION_GITHASH=#{BUILD}"], "runtime build mismatch")
    TYPES.each_key do |shape|
      %w[single_stream with_size_stream].each do |profile|
        cell = "#{shape}_#{profile}"
        check_table(root, output, shape, cell, "stock", "w149_#{cell}")
        check_table(root, output, shape, cell, "library", "w149_lib_#{cell}")
      end
    end
    check_table(root, output, "root", "root_single_stream", "mutant", "w149_mutant_root_single_stream", mutant: true)
    File.write(File.join(output, "summary.txt"), "PASS 12 stock/library tables plus valid wrong-value table; exact nominal types, full/middle literal RowBinary and actual CHECK; 54 fresh queries\nsource=#{REVISION}\nruntime_build=#{BUILD}\nscope=borrowed envelopes, not an independent complete-part writer\n")
    puts "PASS independent Ruby W149 literal oracle: 12 tables + valid wrong-value control; 54 fresh stock queries"
  end
end

VariantPhysicalLiteralRecheck.run
