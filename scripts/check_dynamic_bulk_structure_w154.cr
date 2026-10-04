# W154 stock Wide-part Dynamic V3 structure/site qualification.
# The fixture values are stock-produced; this driver only qualifies complete
# per-occurrence metadata streams and does not read or write Dynamic values.
require "../src/crystal_click"

class W154Mismatch < Exception
end

struct W154SiteBinding
  getter site : String
  getter hashed_stream : String

  def initialize(@site : String, @hashed_stream : String)
  end
end

def w154_fail(message : String) : NoReturn
  raise W154Mismatch.new("W154 stock qualification: #{message}")
end

def w154_require(condition : Bool, message : String) : Nil
  w154_fail(message) unless condition
end

def w154_read_bytes(path : String, label : String) : Bytes
  w154_require(File.file?(path) && !File.symlink?(path), "#{label}: missing file or symlink")
  File.open(path, "rb") do |file|
    w154_require(file.size <= 16_i64 * 1024 * 1024, "#{label}: evidence stream exceeds 16 MiB")
    bytes = Bytes.new(file.size.to_i32)
    file.read_fully(bytes)
    bytes
  end
end

def w154_part_substreams(part : String) : Array(String)
  path = File.join(part, "columns_substreams.txt")
  text = File.read(path)
  text.lines.map(&.strip).select { |line| !line.empty? && !line.starts_with?("columns ") && !line.ends_with?(":") }
end

def w154_expected_structure_names : Array(String)
  [
    "root_dynamic.dynamic_structure",
    "root_dynamic.Array%28Dynamic%29.dynamic_structure",
    "array_dynamic.dynamic_structure",
    "pair%2Eleft.dynamic_structure",
    "pair%2Eright.dynamic_structure",
    "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.dynamic_structure",
    "empty_nested.dynamic_structure",
  ] of String
end

def w154_stream_bytes(part : String, hashed_stream : String) : Bytes
  compressed_path = File.join(part, "#{CrystalClick::StreamName.hash(hashed_stream)}.bin")
  compressed = w154_read_bytes(compressed_path, hashed_stream)
  raw = CrystalClick::CompressedBlock.decode_all(compressed, max_output_size: 16_i64 * 1024 * 1024)
  w154_require(!raw.empty?, "#{hashed_stream}: stock emitted no structure prefix bytes")
  raw
end

def w154_structure_streams(part : String, bindings : Array(W154SiteBinding)) : CrystalClick::BinaryDynamicStructureStreams
  values = Hash(String, Bytes).new
  bindings.each do |binding|
    values[binding.site] = w154_stream_bytes(part, binding.hashed_stream)
  end
  CrystalClick::BinaryDynamicStructureStreams.new(values)
end

def w154_limits : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.default
end

def w154_decode(type : CrystalClick::BinaryDataType, streams : CrystalClick::BinaryDynamicStructureStreams) : CrystalClick::BinaryDynamicBulkPlan
  CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
    type,
    streams,
    CrystalClick::BinaryCodecBudget.new(w154_limits),
  )
end

def w154_names(plan : CrystalClick::BinaryDynamicBulkPlan, site : String) : Array(String)
  plan.structure_for(site).types.map(&.name)
end

def w154_expect_structure(
  plan : CrystalClick::BinaryDynamicBulkPlan,
  site : String,
  type_names : Array(String),
  canonical_names : Array(String),
) : Nil
  structure = plan.structure_for(site)
  observed_types = structure.types.map(&.name)
  observed_canonical = structure.canonical_variant_names
  w154_require(observed_types == type_names,
    "#{site}: expected ordinary roster #{type_names.inspect}, got #{observed_types.inspect}")
  w154_require(observed_canonical == canonical_names,
    "#{site}: expected canonical names #{canonical_names.inspect}, got #{observed_canonical.inspect}")
end

def w154_check_roundtrip(
  plan : CrystalClick::BinaryDynamicBulkPlan,
  original : CrystalClick::BinaryDynamicStructureStreams,
) : Nil
  encoded = plan.encode_structure_streams(CrystalClick::BinaryCodecBudget.new(w154_limits, true))
  w154_require(encoded.site_paths == plan.site_paths, "paired structure encoder changed occurrence keys")
  plan.site_paths.each do |site|
    expected = original.structure_bytes_for(site)
    observed = encoded.structure_bytes_for(site)
    w154_require(observed == expected, "#{site}: stock structure bytes did not round-trip exactly")
  end
end

def w154_bindings_with_sites(
  part : String,
  entries : Array(Tuple(String, String)),
) : CrystalClick::BinaryDynamicStructureStreams
  values = Hash(String, Bytes).new
  entries.each do |entry|
    values[entry[0]] = w154_stream_bytes(part, entry[1])
  end
  CrystalClick::BinaryDynamicStructureStreams.new(values)
end

def w154_emit_plan(label : String, plan : CrystalClick::BinaryDynamicBulkPlan) : Nil
  puts ["PLAN", label, "sites", plan.site_paths.join(",")].join("\t")
  puts ["PLAN", label, "structures", plan.structure_roles.join(",")].join("\t")
  puts ["PLAN", label, "data_roles", plan.data_roles.join(",")].join("\t")
end

def w154_qualify(part : String) : Nil
  w154_require(Dir.exists?(part) && !File.symlink?(part), "stock part directory is absent or a symlink")
  w154_require(File.realpath(part) == File.expand_path(part), "stock part path must be canonical")

  actual_names = w154_part_substreams(part).select(&.ends_with?(".dynamic_structure")).sort
  expected_names = w154_expected_structure_names.sort
  w154_require(actual_names == expected_names,
    "exact stock Dynamic-structure substream set differs: expected #{expected_names.inspect}, got #{actual_names.inspect}")

  # One plan per actual stock column occurrence tree. Nested Dynamic sites
  # inside an actual Array arm are keyed by the logical plan path, not by type
  # identity. Empty/unused child sites remain present because their physical
  # structure streams are read and decoded here.
  root_type = CrystalClick::BinaryDataType.dynamic(max_types: 4)
  root_bindings = [
    W154SiteBinding.new("root", "root_dynamic.dynamic_structure"),
    W154SiteBinding.new("root.arm.0.elements",
      "root_dynamic.Array%28Dynamic%29.dynamic_structure"),
  ] of W154SiteBinding
  root_streams = w154_structure_streams(part, root_bindings)
  root_plan = w154_decode(root_type, root_streams)
  w154_require(root_plan.site_paths == ["root", "root.arm.0.elements"] of String,
    "root Dynamic occurrence paths differ: #{root_plan.site_paths.inspect}")
  w154_expect_structure(root_plan, "root",
    ["Array(Dynamic)", "String", "UInt64", "UInt8"] of String,
    ["Array(Dynamic)", "SharedVariant", "String", "UInt64", "UInt8"] of String)
  w154_expect_structure(root_plan, "root.arm.0.elements",
    ["String", "UInt8"] of String,
    ["SharedVariant", "String", "UInt8"] of String)
  w154_require(root_plan.structure_for("root").shared_index == 1,
    "root Dynamic synthetic SharedVariant did not retain its distinct canonical index")
  w154_require(root_plan.data_roles.includes?("root.arm.1.data") && root_plan.data_roles.includes?("root.arm.2.data"),
    "synthetic SharedVariant and ordinary String roles were not distinct")
  w154_check_roundtrip(root_plan, root_streams)
  w154_emit_plan("root_dynamic", root_plan)

  array_type = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.dynamic)
  array_bindings = [W154SiteBinding.new("root.elements", "array_dynamic.dynamic_structure")] of W154SiteBinding
  array_streams = w154_structure_streams(part, array_bindings)
  array_plan = w154_decode(array_type, array_streams)
  w154_require(array_plan.site_paths == ["root.elements"] of String,
    "declared Array(Dynamic) occurrence path differs: #{array_plan.site_paths.inspect}")
  w154_expect_structure(array_plan, "root.elements",
    ["String", "UInt16"] of String,
    ["SharedVariant", "String", "UInt16"] of String)
  w154_check_roundtrip(array_plan, array_streams)
  w154_emit_plan("array_dynamic", array_plan)

  uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
  tuple_type = CrystalClick::BinaryDataType.tuple(
    [CrystalClick::BinaryDataType.dynamic, CrystalClick::BinaryDataType.dynamic] of CrystalClick::BinaryDataType,
    ["left", "right"] of String,
  )
  tuple_bindings = [
    W154SiteBinding.new("root.field.0", "pair%2Eleft.dynamic_structure"),
    W154SiteBinding.new("root.field.1", "pair%2Eright.dynamic_structure"),
  ] of W154SiteBinding
  tuple_streams = w154_structure_streams(part, tuple_bindings)
  tuple_plan = w154_decode(tuple_type, tuple_streams)
  w154_require(tuple_plan.site_paths == ["root.field.0", "root.field.1"] of String,
    "Tuple occurrence paths differ: #{tuple_plan.site_paths.inspect}")
  w154_expect_structure(tuple_plan, "root.field.0", ["String", "UInt8"] of String,
    ["SharedVariant", "String", "UInt8"] of String)
  w154_expect_structure(tuple_plan, "root.field.1", ["UInt16", "UInt64"] of String,
    ["SharedVariant", "UInt16", "UInt64"] of String)
  w154_check_roundtrip(tuple_plan, tuple_streams)
  w154_emit_plan("tuple", tuple_plan)

  # Both blobs are individually valid stock V3 structures. Exchange them,
  # require decode to succeed, then have an independent literal site->roster
  # verifier reject the semantically wrong association. The wire itself has
  # no embedded occurrence path, so codec refusal is not expected here.
  swapped_tuple_streams = w154_bindings_with_sites(part, [
    {"root.field.0", "pair%2Eright.dynamic_structure"},
    {"root.field.1", "pair%2Eleft.dynamic_structure"},
  ] of Tuple(String, String))
  swapped_tuple_plan = w154_decode(tuple_type, swapped_tuple_streams)
  swapped_left = w154_names(swapped_tuple_plan, "root.field.0")
  swapped_right = w154_names(swapped_tuple_plan, "root.field.1")
  w154_require(swapped_left == ["UInt16", "UInt64"] of String && swapped_right == ["String", "UInt8"] of String,
    "stock-valid swapped-site control did not decode into the opposite rosters")
  w154_require(swapped_left != ["String", "UInt8"] of String && swapped_right != ["UInt16", "UInt64"] of String,
    "independent expected-site roster check accepted the swapped control")
  puts "NEGATIVE-CONTROL\tswapped-site-stock-valid\tdecode=accepted\tindependent-site-roster=REJECTED"

  dynamic_zero = CrystalClick::BinaryDataType.dynamic(max_types: 0)
  array_dynamic_zero = CrystalClick::BinaryDataType.array(dynamic_zero)
  variant_type = CrystalClick::BinaryDataType.variant([array_dynamic_zero, uint8_type] of CrystalClick::BinaryDataType)
  variant_bindings = [W154SiteBinding.new("root.arm.0.elements",
    "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.dynamic_structure")] of W154SiteBinding
  variant_streams = w154_structure_streams(part, variant_bindings)
  variant_plan = w154_decode(variant_type, variant_streams)
  w154_require(variant_plan.site_paths == ["root.arm.0.elements"] of String,
    "unused Variant arm occurrence path differs: #{variant_plan.site_paths.inspect}")
  w154_expect_structure(variant_plan, "root.arm.0.elements", [] of String,
    ["SharedVariant"] of String)
  w154_check_roundtrip(variant_plan, variant_streams)
  w154_emit_plan("unused_variant_arm", variant_plan)

  empty_array_type = CrystalClick::BinaryDataType.array(dynamic_zero)
  empty_bindings = [W154SiteBinding.new("root.elements", "empty_nested.dynamic_structure")] of W154SiteBinding
  empty_streams = w154_structure_streams(part, empty_bindings)
  empty_plan = w154_decode(empty_array_type, empty_streams)
  w154_require(empty_plan.site_paths == ["root.elements"] of String,
    "empty nested occurrence path differs: #{empty_plan.site_paths.inspect}")
  w154_expect_structure(empty_plan, "root.elements", [] of String, ["SharedVariant"] of String)
  w154_check_roundtrip(empty_plan, empty_streams)
  w154_emit_plan("empty_nested_array", empty_plan)

  puts "W154 stock DynamicStructure/site qualification PASS sites=7 empty_child_sites=2 swapped_site_control=REJECTED"
  nil
end

begin
  unless ARGV.size == 2 && ARGV[0] == "--qualify"
    w154_fail("usage: check_dynamic_bulk_structure_w154.cr --qualify STOCK_PART_PATH")
  end
  w154_qualify(ARGV[1])
rescue ex : W154Mismatch
  STDERR.puts ex.message
  exit(1)
rescue ex : CrystalClick::Error
  STDERR.puts "W154 stock qualification: CrystalClick error: #{ex.message}"
  exit(1)
end
