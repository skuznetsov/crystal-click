require "../src/crystal_click"

class W120StructureMismatch < Exception
end

# Independently authored Object/Dynamic metadata for the three literal W115
# input profiles. This helper intentionally does not inspect captured bytes or
# call a production decoder when building its expected models/vectors.
module W120StructureVectors
  PROFILES = {"dynamic_paths", "dynamic_shared_only", "typed_mixed"}

  def self.check_profile(profile : String) : Nil
    raise "unknown W120/W115 profile: #{profile.inspect}" unless PROFILES.includes?(profile)
  end

  def self.dynamic_paths(profile : String) : Array(String)
    check_profile(profile)
    case profile
    when "dynamic_paths"
      ["a", "arr", "dot.key", "flag", "nest.leaf", "s"]
    when "dynamic_shared_only"
      [] of String
    else
      ["s"]
    end
  end

  def self.expected_set(profile : String) : CrystalClick::ObjectDynamicStructureSet
    check_profile(profile)

    shared_only_counts = [
      {"a", 6_u64}, {"arr", 6_u64}, {"dot.key", 7_u64},
      {"flag", 5_u64}, {"nest.leaf", 5_u64}, {"s", 6_u64},
    ]
    typed_mixed_shared_counts = [
      {"arr", 6_u64}, {"dot.key", 7_u64}, {"flag", 5_u64}, {"nest.leaf", 5_u64},
    ]

    object_shared = case profile
                    when "dynamic_paths"
                      [] of Tuple(String, UInt64)
                    when "dynamic_shared_only"
                      shared_only_counts
                    else
                      typed_mixed_shared_counts
                    end
    object_counts = case profile
                    when "dynamic_paths"
                      [6_u64, 6_u64, 7_u64, 5_u64, 5_u64, 6_u64]
                    when "dynamic_shared_only"
                      [] of UInt64
                    else
                      [6_u64]
                    end

    object = CrystalClick::ObjectStructure.new(
      dynamic_paths(profile),
      version: 4_u64,
      shared_data_version: 0_u64,
      bucket_count: 1_u64,
      legacy_max_dynamic_paths: nil,
      statistics: statistics(object_counts, object_shared),
    )

    dynamics = case profile
               when "dynamic_paths"
                 int64 = CrystalClick::BinaryDataType.primitive("Int64")
                 bool = CrystalClick::BinaryDataType.primitive("Bool")
                 string = CrystalClick::BinaryDataType.primitive("String")
                 array_nullable_int64 = CrystalClick::BinaryDataType.array(
                   CrystalClick::BinaryDataType.nullable(int64)
                 )
                 {
                   # NULL discriminator 255 has no Dynamic variant count.
                   "a"         => dynamic([int64], [6_u64, 0_u64]),
                   "arr"       => dynamic([array_nullable_int64], [6_u64, 0_u64]),
                   "dot.key"   => dynamic([int64], [7_u64, 0_u64]),
                   "flag"      => dynamic([bool], [5_u64, 0_u64]),
                   "nest.leaf" => dynamic([string], [0_u64, 5_u64]),
                   "s"         => dynamic([bool, int64, string], [1_u64, 1_u64, 0_u64, 4_u64]),
                 } of String => CrystalClick::DynamicStructure
               when "dynamic_shared_only"
                 {} of String => CrystalClick::DynamicStructure
               else
                 string = CrystalClick::BinaryDataType.primitive("String")
                 {
                   "s" => dynamic([string], [2_u64, 4_u64], [{"Bool", 1_u64}, {"Int64", 1_u64}]),
                 } of String => CrystalClick::DynamicStructure
               end

    CrystalClick::ObjectDynamicStructureSet.new(object, dynamics)
  end

  # Source serialization escapes dots in physical logical-stream names. These
  # spellings are authored from the literal W115 path names, not from a part.
  def self.physical_path(path : String) : String
    case path
    when "dot.key"   then "dot%2Ekey"
    when "nest.leaf" then "nest%2Eleaf"
    else                  path
    end
  end

  def self.object_header(object : CrystalClick::ObjectStructure) : Bytes
    unless object.version == 4_u64 && object.shared_data_version == 0_u64 && object.bucket_count == 1_u64
      raise "W120 authored Object header only covers V3 MAP with one implicit bucket"
    end
    io = IO::Memory.new
    write_uint64_le(io, object.version)
    write_var_uint(io, object.dynamic_paths.size.to_u64)
    object.dynamic_paths.each { |path| write_string(io, path) }
    write_var_uint(io, object.shared_data_version)
    io.to_slice
  end

  def self.dynamic_header(dynamic : CrystalClick::DynamicStructure) : Bytes
    io = IO::Memory.new
    write_uint64_le(io, 4_u64) # Dynamic V3.
    write_var_uint(io, dynamic.types.size.to_u64)
    dynamic.types.each { |type| io.write(descriptor_bytes(type)) }
    io.to_slice
  end

  # Independent complete V3 Object bytes used for exact local vector checks
  # and for a valid unordered shared-statistics-map decoder control.
  def self.object_bytes(object : CrystalClick::ObjectStructure, reverse_shared : Bool = false) : Bytes
    io = IO::Memory.new
    io.write(object_header(object))
    if statistics = object.statistics
      io.write_byte(1_u8)
      statistics.counts.each { |count| write_var_uint(io, count) }
      entries = statistics.shared.sort_by(&.name)
      entries = entries.reverse if reverse_shared
      write_var_uint(io, entries.size.to_u64)
      entries.each do |entry|
        write_string(io, entry.name)
        write_var_uint(io, entry.count)
      end
    else
      io.write_byte(0_u8)
    end
    io.to_slice
  end

  # Independent complete Dynamic V3 bytes. Positional counts are authored in
  # canonical SQL-name order (including SharedVariant); the trailing map is
  # sorted only in canonical mode.
  def self.dynamic_bytes(dynamic : CrystalClick::DynamicStructure, reverse_shared : Bool = false) : Bytes
    io = IO::Memory.new
    io.write(dynamic_header(dynamic))
    if statistics = dynamic.statistics
      io.write_byte(1_u8)
      statistics.counts.each { |count| write_var_uint(io, count) }
      entries = statistics.shared.sort_by(&.name)
      entries = entries.reverse if reverse_shared
      write_var_uint(io, entries.size.to_u64)
      entries.each do |entry|
        write_string(io, entry.name)
        write_var_uint(io, entry.count)
      end
    else
      io.write_byte(0_u8)
    end
    io.to_slice
  end

  def self.streams(set : CrystalClick::ObjectDynamicStructureSet, reverse_object_shared : Bool = false, reverse_dynamic_shared_path : String? = nil) : CrystalClick::ObjectDynamicStructureStreams
    dynamic_streams = {} of String => Bytes
    set.dynamics.each do |path, dynamic|
      dynamic_streams[path] = dynamic_bytes(dynamic, reverse_shared: path == reverse_dynamic_shared_path)
    end
    CrystalClick::ObjectDynamicStructureStreams.new(
      object_bytes(set.object, reverse_object_shared),
      dynamic_streams,
    )
  end

  def self.assert_equal(expected : CrystalClick::ObjectDynamicStructureSet, actual : CrystalClick::ObjectDynamicStructureSet, label : String) : Nil
    left = expected.object
    right = actual.object
    unless left.version == right.version && left.shared_data_version == right.shared_data_version &&
           left.bucket_count == right.bucket_count && left.legacy_max_dynamic_paths == right.legacy_max_dynamic_paths
      mismatch(label, "Object header")
    end

    expected_object_map = object_counts_by_path(left)
    actual_object_map = object_counts_by_path(right)
    unless left.dynamic_paths.sort == right.dynamic_paths.sort && expected_object_map == actual_object_map
      mismatch(label, "Object roster/statistics")
    end
    unless shared_map(left.statistics) == shared_map(right.statistics)
      mismatch(label, "Object shared statistics")
    end
    unless left.statistics.nil? == right.statistics.nil?
      mismatch(label, "Object statistics presence")
    end

    unless expected.dynamics.keys.sort == actual.dynamics.keys.sort
      mismatch(label, "Dynamic path roster")
    end
    expected.dynamics.each do |path, expected_dynamic|
      actual_dynamic = actual.dynamics[path]? || mismatch(label, "missing Dynamic path #{path.inspect}")
      unless expected_dynamic.types == actual_dynamic.types
        mismatch(label, "Dynamic nominal type roster at #{path.inspect}")
      end
      expected_variant_names = canonical_variant_names(expected_dynamic)
      actual_variant_names = canonical_variant_names(actual_dynamic)
      unless expected_variant_names == actual_variant_names
        mismatch(label, "Dynamic canonical variant names at #{path.inspect}")
      end
      unless expected_dynamic.statistics.try(&.counts) == actual_dynamic.statistics.try(&.counts)
        mismatch(label, "Dynamic positional statistics at #{path.inspect}")
      end
      unless shared_map(expected_dynamic.statistics) == shared_map(actual_dynamic.statistics)
        mismatch(label, "Dynamic shared statistics at #{path.inspect}")
      end
      unless expected_dynamic.statistics.nil? == actual_dynamic.statistics.nil?
        mismatch(label, "Dynamic statistics presence at #{path.inspect}")
      end
    end
  end

  def self.same?(expected : CrystalClick::ObjectDynamicStructureSet, actual : CrystalClick::ObjectDynamicStructureSet) : Bool
    assert_equal(expected, actual, "metadata comparator")
    true
  rescue W120StructureMismatch
    false
  end

  private def self.statistics(counts : Array(UInt64), shared : Array(Tuple(String, UInt64))) : CrystalClick::StructureStatistics
    entries = shared.map { |(name, count)| CrystalClick::StructureStatistic.new(name, count) }
    CrystalClick::StructureStatistics.new(counts, entries)
  end

  private def self.dynamic(types : Array(CrystalClick::BinaryDataType), counts : Array(UInt64), shared : Array(Tuple(String, UInt64)) = [] of Tuple(String, UInt64)) : CrystalClick::DynamicStructure
    CrystalClick::DynamicStructure.new(types, statistics: statistics(counts, shared))
  end

  private def self.object_counts_by_path(object : CrystalClick::ObjectStructure) : Hash(String, UInt64)?
    if stats = object.statistics
      return nil unless stats.counts.size == object.dynamic_paths.size
      result = {} of String => UInt64
      object.dynamic_paths.each_with_index { |path, index| result[path] = stats.counts[index] }
      result
    else
      nil
    end
  end

  private def self.shared_map(statistics : CrystalClick::StructureStatistics?) : Hash(String, UInt64)?
    if stats = statistics
      result = {} of String => UInt64
      stats.shared.each do |entry|
        return nil if result.has_key?(entry.name)
        result[entry.name] = entry.count
      end
      result
    else
      nil
    end
  end

  private def self.canonical_variant_names(dynamic : CrystalClick::DynamicStructure) : Array(String)
    (dynamic.types.map(&.name) + ["SharedVariant"]).sort
  end

  private def self.descriptor_bytes(type : CrystalClick::BinaryDataType) : Bytes
    case type.name
    when "Bool"
      raise "Bool nominal tag differs from authored W120 vector" unless type == CrystalClick::BinaryDataType.primitive("Bool")
      Bytes[0x2d_u8]
    when "Int64"
      raise "Int64 nominal tag differs from authored W120 vector" unless type == CrystalClick::BinaryDataType.primitive("Int64")
      Bytes[0x0a_u8]
    when "String"
      raise "String nominal tag differs from authored W120 vector" unless type == CrystalClick::BinaryDataType.primitive("String")
      Bytes[0x15_u8]
    when "Array(Nullable(Int64))"
      expected = CrystalClick::BinaryDataType.array(
        CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("Int64"))
      )
      raise "Array(Nullable(Int64)) nominal descriptor differs from authored W120 vector" unless type == expected
      Bytes[0x1e_u8, 0x23_u8, 0x0a_u8]
    else
      raise "no independent W120 descriptor literal for #{type.name.inspect}"
    end
  end

  private def self.write_string(io : IO, value : String) : Nil
    bytes = value.to_slice
    write_var_uint(io, bytes.size.to_u64)
    io.write(bytes)
  end

  private def self.write_var_uint(io : IO, value : UInt64) : Nil
    remaining = value
    while remaining >= 0x80_u64
      io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
      remaining >>= 7
    end
    io.write_byte(remaining.to_u8)
  end

  private def self.write_uint64_le(io : IO, value : UInt64) : Nil
    8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
  end

  private def self.mismatch(label : String, detail : String) : NoReturn
    raise W120StructureMismatch.new("#{label}: #{detail} differs")
  end
end
