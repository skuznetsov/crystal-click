# Bounded read-only W157 check over the already-qualified W156 stock part.
# It verifies five literal Dynamic metadata streams only; it does not qualify
# other profiles/rosters, current-master runtime, or a general part reader.
require "../src/crystal_click"

class W157Mismatch < Exception
end

W157_MAX_FILE_BYTES = 8_i64 * 1024 * 1024
W157_ROWS_PER_MARK  = [2_u64, 2_u64, 2_u64]

def w157_fail(message : String) : NoReturn
  raise W157Mismatch.new("W157 statistics offsets: #{message}")
end

def w157_require(condition : Bool, message : String) : Nil
  w157_fail(message) unless condition
end

struct W157Binding
  getter site : String
  getter role : String
  getter physical_name : String
  getter hash : String
  getter literal : Bytes
  getter expected_types : Array(String)
  getter expected_canonical : Array(String)
  getter offset : Int32

  def initialize(@site : String, @role : String, @physical_name : String, @hash : String,
                 @literal : Bytes, @expected_types : Array(String),
                 @expected_canonical : Array(String), @offset : Int32)
  end
end

struct W157Fixture
  getter column : String
  getter type : CrystalClick::BinaryDataType
  getter bindings : Array(W157Binding)

  def initialize(@column : String, @type : CrystalClick::BinaryDataType,
                 @bindings : Array(W157Binding))
  end
end

def w157_fixtures : Array(W157Fixture)
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  dynamic_zero = CrystalClick::BinaryDataType.dynamic(max_types: 0)
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  root_bytes = Bytes[4_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
    1_u8, 4_u8, 1_u8, 1_u8, 4_u8, 1_u8, 6_u8,
    0x53_u8, 0x74_u8, 0x72_u8, 0x69_u8, 0x6e_u8, 0x67_u8, 1_u8]
  left_bytes = Bytes[4_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 4_u8, 1_u8, 0_u8, 6_u8, 0_u8]
  right_bytes = Bytes[4_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x15_u8, 1_u8, 0_u8, 6_u8, 0_u8]
  nested_bytes = Bytes[4_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 4_u8, 1_u8, 0_u8, 5_u8, 0_u8]
  unused_bytes = Bytes[4_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0_u8, 0_u8]

  root = W157Fixture.new("root_dynamic", dynamic, [W157Binding.new(
    "root", "root.dynamic_structure", "root_dynamic.dynamic_structure", "53f0a939aafa473e3c722dd18b57f5e5",
    root_bytes, ["UInt64"], ["SharedVariant", "UInt64"], 10_i32,
  )] of W157Binding)
  pair_type = CrystalClick::BinaryDataType.tuple([dynamic, dynamic] of CrystalClick::BinaryDataType, ["left", "right"])
  pair = W157Fixture.new("pair", pair_type, [
    W157Binding.new("root.field.0", "root.field.0.dynamic_structure", "pair%2Eleft.dynamic_structure",
      "23946f95295875b32870c944c99c88b6", left_bytes,
      ["UInt64"], ["SharedVariant", "UInt64"], 10_i32),
    W157Binding.new("root.field.1", "root.field.1.dynamic_structure", "pair%2Eright.dynamic_structure",
      "44a2175c82fda437131103e7720fa4f0", right_bytes,
      ["String"], ["SharedVariant", "String"], 10_i32),
  ] of W157Binding)
  nested = W157Fixture.new("nested", CrystalClick::BinaryDataType.array(dynamic), [W157Binding.new(
    "root.elements", "root.elements.dynamic_structure", "nested.dynamic_structure", "ec03d37526c92e901ac1a336a7a522eb",
    nested_bytes, ["UInt64"], ["SharedVariant", "UInt64"], 10_i32,
  )] of W157Binding)
  unused_type = CrystalClick::BinaryDataType.variant([
    CrystalClick::BinaryDataType.array(dynamic_zero), uint8,
  ] of CrystalClick::BinaryDataType)
  unused = W157Fixture.new("unused_variant", unused_type, [W157Binding.new(
    "root.arm.0.elements", "root.arm.0.elements.dynamic_structure",
    "unused_variant.Array%28Dynamic%28max_types%3D0%29%29.dynamic_structure",
    "4f5e4b88d392b8b021c8d10cf082d7b1", unused_bytes,
    [] of String, ["SharedVariant"], 9_i32,
  )] of W157Binding)
  [root, pair, nested, unused] of W157Fixture
end

def w157_read_file(path : String, label : String) : Bytes
  w157_require(File.file?(path) && !File.symlink?(path), "#{label}: missing regular file or symlink")
  size = File.size(path)
  w157_require(size >= 0 && size <= W157_MAX_FILE_BYTES, "#{label}: file exceeds 8 MiB")
  text = File.read(path)
  Bytes.new(text.bytesize) { |index| text.to_slice[index] }
end

def w157_check_part(part : String) : Nil
  canonical = File.realpath(part)
  w157_require(File.expand_path(part) == canonical && Dir.exists?(canonical) && !File.symlink?(canonical),
    "part must be an existing canonical directory")
  w157_fixtures.each do |fixture|
    literals = Hash(String, Bytes).new
    fixture.bindings.each do |binding|
      expected_bin = "#{binding.hash}.bin"
      raw = CrystalClick::CompressedBlock.decode_all(
        w157_read_file(File.join(canonical, expected_bin), "#{fixture.column} #{binding.site} metadata bin"),
        max_output_size: W157_MAX_FILE_BYTES,
      )
      w157_require(raw == binding.literal, "#{fixture.column} #{binding.site}: stock metadata differs from W156 literal bytes")
      literals[binding.site] = raw
      w157_require(binding.offset == (binding.expected_types.empty? ? 9_i32 : 10_i32),
        "#{fixture.column} #{binding.site}: literal prefix is outside the admitted 9/10 boundary set")
    end

    streams = CrystalClick::BinaryDynamicStructureStreams.new(literals)
    read_plan = CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
      fixture.type, streams, CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      CrystalClick::BinaryBulkProfile.single_stream,
    )
    expected_sites = fixture.bindings.map(&.site).sort!
    w157_require(read_plan.site_paths == expected_sites, "#{fixture.column}: decoded site roster differs from literal")
    expected_structure_map = Hash(String, String).new
    structures = Hash(String, CrystalClick::DynamicStructure).new
    fixture.bindings.each do |binding|
      structure = read_plan.structure_for(binding.site)
      w157_require(structure.types.map(&.name) == binding.expected_types,
        "#{fixture.column} #{binding.site}: ordinary roster differs from literal")
      w157_require(structure.canonical_variant_names == binding.expected_canonical,
        "#{fixture.column} #{binding.site}: canonical SharedVariant ordering differs from literal")
      w157_require(read_plan.statistics_offset_for(binding.site) == binding.offset,
        "#{fixture.column} #{binding.site}: read-plan offset differs from literal")
      expected_structure_map[binding.role] = binding.physical_name
      structures[binding.site] = structure
    end

    read_physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(read_plan, fixture.column)
    w157_require(read_physical.structure_stream_names == expected_structure_map,
      "#{fixture.column}: physical structure role map differs from independent literals")
    write_plan = CrystalClick::BinaryDynamicBulkPlan.new(
      fixture.type, structures, CrystalClick::BinaryBulkProfile.single_stream,
    )
    write_physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(write_plan, fixture.column)
    w157_require(write_physical.structure_stream_names == expected_structure_map,
      "#{fixture.column}: write-plan physical role map differs from independent literals")
    encoded = write_plan.encode_structure_streams(CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.default, true,
    ))

    fixture.bindings.each do |binding|
      w157_require(write_plan.statistics_offset_for(binding.site) == binding.offset,
        "#{fixture.column} #{binding.site}: write-plan offset differs from literal")
      w157_require(encoded.structure_bytes_for(binding.site) == binding.literal,
        "#{fixture.column} #{binding.site}: write-plan bytes differ from literal")
      w157_require(read_physical.structure_name_for(binding.site) == binding.physical_name,
        "#{fixture.column} #{binding.site}: read physical name differs from literal")
      w157_require(write_physical.structure_name_for(binding.site) == binding.physical_name,
        "#{fixture.column} #{binding.site}: write physical name differs from literal")
      w157_require(read_physical.data_file_for(binding.role, hashed: true) == "#{binding.hash}.bin" &&
                   read_physical.marks_file_for(binding.role, hashed: true) == "#{binding.hash}.mrk2",
        "#{fixture.column} #{binding.site}: hashed stock paths differ from literal basenames")

      data_path = File.join(canonical, "#{binding.hash}.bin")
      marks_path = File.join(canonical, "#{binding.hash}.mrk2")
      marks = w157_read_file(marks_path, "#{fixture.column} #{binding.site} metadata marks")
      grid = CrystalClick::CompressedMarkReader.inspect(
        data_path, marks_path, File.size(data_path), marks.size.to_i64, prefix_size: binding.offset)
      positions = grid.positions
      w157_require(grid.prefix_size == binding.offset && grid.logical_size == binding.literal.size.to_i64,
        "#{fixture.column} #{binding.site}: metadata mark grid has a different literal boundary or EOF")
      w157_require(positions.size == 4 && positions[0] == binding.offset.to_i64 &&
                   positions[1] == binding.offset.to_i64 && positions[2] == binding.offset.to_i64 &&
                   positions[3] == binding.literal.size.to_i64,
        "#{fixture.column} #{binding.site}: real marks must name statistics offset and terminal must name EOF")
      w157_require(grid.rows_per_mark == W157_ROWS_PER_MARK,
        "#{fixture.column} #{binding.site}: stock metadata mark row grid differs from W156 literal")
      puts "SITE\t#{fixture.column}\t#{binding.site}\toffset=#{binding.offset}\tEOF=#{grid.logical_size}"
    end
  end
  puts "W157 stock metadata-offset qualifier PASS structures=5 profile=single_stream input=read-only"
  nil
end

begin
  unless ARGV.size == 2 && ARGV[0] == "--part"
    w157_fail("usage: check_dynamic_statistics_offsets_w157.cr --part STOCK_PART")
  end
  w157_check_part(ARGV[1])
rescue ex : W157Mismatch
  STDERR.puts ex.message
  exit(1)
rescue ex : CrystalClick::Error
  STDERR.puts "W157 statistics offsets: CrystalClick error: #{ex.message}"
  exit(1)
rescue ex
  STDERR.puts "W157 statistics offsets: #{ex.message}"
  exit(1)
end
