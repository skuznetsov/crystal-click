require "./spec_helper"
require "file_utils"

private def w126_root_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 255_u64).to_u8) }
end

private def w126_root_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 128_u64
    io.write_byte(((remaining & 127_u64) | 128_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w126_root_string(io : IO, value : String) : Nil
  w126_root_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

private def w126_root_words(values : Array(UInt64)) : Bytes
  io = IO::Memory.new
  values.each { |value| w126_root_u64(io, value) }
  io.to_slice
end

# Independent small physical part, not a production writer round trip. Its
# arbitrary raw names do not occur in the W115-W125 fixture inventory.
private def w126_root_part(hashed : Bool = false, with_sizes : Bool = false, shared_with_sizes : Bool = false,
                           split_metadata : Bool = false, raw_column : String = "p/ayload%", raw_typed_path : String = "fixed.key", &)
  path = File.tempname("crystal-click-w126-root-part")
  Dir.mkdir(path)
  # Alternative names in the long-name tests contain only plain ASCII letters;
  # their literal component bytes therefore require no escaping.
  column = raw_column == "p/ayload%" ? "p%2Fayload%25" : raw_column
  dynamic = column + ".odd%2Epath%2F%25"
  typed = column + "." + (raw_typed_path == "fixed.key" ? "fixed%2Ekey" : raw_typed_path)
  physical = Hash(String, Bytes).new
  begin
    object = IO::Memory.new
    w126_root_u64(object, 4_u64)
    object.write_byte(1_u8)
    w126_root_string(object, "odd.path/%")
    object.write_byte(0_u8) # MAP
    object_prefix = object.size.to_u64
    object.write(Bytes[1, 3, 0]) # suffix flag, dynamic nonnull count, shared paths

    structure = IO::Memory.new
    w126_root_u64(structure, 4_u64)
    structure.write(Bytes[2, 4, 0x15]) # two ordinary descriptors: UInt64, String
    structure_prefix = structure.size.to_u64
    structure.write(Bytes[1, 0, 2, 1, 0]) # flag; SharedVariant/String/UInt64; shared stats

    # Logical offsets and raw bytes are literal source expectations. Nested
    # empty lanes keep the complete positive outer row grid.
    lanes = {
      column + ".object_structure"            => {object.to_slice, [object_prefix, object_prefix, object_prefix, object.size.to_u64]},
      dynamic + ".dynamic_structure"          => {structure.to_slice, [structure_prefix, structure_prefix, structure_prefix, structure.size.to_u64]},
      dynamic + ".variant_discr"              => {Bytes[0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 255, 1], [8_u64, 10_u64, 11_u64, 12_u64]},
      dynamic + ".String"                     => {Bytes[1, 0x61, 1, 0x7a], [0_u64, 2_u64, 2_u64, 4_u64]},
      dynamic + ".UInt64"                     => {w126_root_words([7_u64]), [0_u64, 8_u64, 8_u64, 8_u64]},
      dynamic + ".SharedVariant"              => {Bytes.empty, [0_u64, 0_u64, 0_u64, 0_u64]},
      column + ".object_shared_data.size0"    => {w126_root_words([0_u64, 0_u64, 0_u64, 0_u64]), [0_u64, 16_u64, 24_u64, 32_u64]},
      column + ".object_shared_data%2Epaths"  => {Bytes.empty, [0_u64, 0_u64, 0_u64, 0_u64]},
      column + ".object_shared_data%2Evalues" => {Bytes.empty, [0_u64, 0_u64, 0_u64, 0_u64]},
    }
    if with_sizes
      lanes[dynamic + ".String"] = {Bytes[0x61, 0x7a], [0_u64, 1_u64, 1_u64, 2_u64]}
      lanes[dynamic + ".String.size"] = {w126_root_words([1_u64, 1_u64]), [0_u64, 8_u64, 8_u64, 16_u64]}
      lanes[dynamic + ".SharedVariant.size"] = {Bytes.empty, [0_u64, 0_u64, 0_u64, 0_u64]}
    end
    if shared_with_sizes
      lanes[column + ".object_shared_data%2Epaths.size"] = {Bytes.empty, [0_u64, 0_u64, 0_u64, 0_u64]}
      lanes[column + ".object_shared_data%2Evalues.size"] = {Bytes.empty, [0_u64, 0_u64, 0_u64, 0_u64]}
    end
    rows = [2_u64, 1_u64, 1_u64]
    lanes.each do |logical, lane|
      raw, offsets = lane
      data = raw.empty? ? Bytes.empty : w126_root_frame(raw)
      records = Array(Tuple(UInt64, UInt64, UInt64)).new(4)
      if split_metadata && logical.ends_with?("_structure")
        first = w126_root_frame(raw[0, 8])
        second = w126_root_frame(raw[8, raw.size - 8])
        split = IO::Memory.new
        split.write(first)
        split.write(second)
        data = split.to_slice
        3.times { |index| records << {first.size.to_u64, offsets[index] - 8_u64, rows[index]} }
      else
        3.times { |index| records << {0_u64, offsets[index], rows[index]} }
      end
      records << {data.size.to_u64, 0_u64, 0_u64}
      basename = hashed ? CrystalClick::StreamName.hash(logical) : logical
      physical[basename + ".bin"] = data
      physical[basename + ".mrk2"] = w126_root_marks(records)
    end

    # Three independent frames make the selected-only checksum boundary real.
    first = w126_root_frame(w126_root_words([11_u64, 12_u64]))
    middle = w126_root_frame(w126_root_words([13_u64]))
    last = w126_root_frame(w126_root_words([14_u64]))
    typed_data = IO::Memory.new
    {first, middle, last}.each { |frame| typed_data.write(frame) }
    typed_base = hashed ? CrystalClick::StreamName.hash(typed) : typed
    physical[typed_base + ".bin"] = typed_data.to_slice
    physical[typed_base + ".mrk2"] = w126_root_marks([
      {0_u64, 0_u64, 2_u64}, {first.size.to_u64, 0_u64, 1_u64},
      {(first.size + middle.size).to_u64, 0_u64, 1_u64}, {typed_data.size.to_u64, 0_u64, 0_u64},
    ])

    # v4 compressed-v3 checksums. Hash fields are deliberately zero: this
    # reader promises size validation, not whole-file hash verification.
    checksums = IO::Memory.new
    w126_root_varuint(checksums, physical.size.to_u64)
    physical.each do |name, bytes|
      w126_root_string(checksums, name)
      w126_root_varuint(checksums, bytes.size.to_u64)
      checksums.write(Bytes.new(16, 0_u8))
      checksums.write_byte(0_u8)
      File.open(File.join(path, name), "wb") { |io| io.write(bytes) }
    end
    File.open(File.join(path, "checksums.txt"), "wb") do |io|
      io << "checksums format version: 4\n"
      io.write(w126_root_frame(checksums.to_slice))
    end
    yield path, column, dynamic, typed
  ensure
    FileUtils.rm_rf(path)
  end
end

private def w126_root_read(path : String, first_mark : Int = 0, mark_count : Int? = nil, hashed : Bool = false,
                           with_sizes : Bool = false, shared_with_sizes : Bool = false)
  CrystalClick::ObjectDocumentFileReader.read(path, "p/ayload%",
    {"fixed.key" => CrystalClick::BinaryDataType.primitive("UInt64")},
    first_mark: first_mark, mark_count: mark_count, hashed: hashed,
    profile: with_sizes ? CrystalClick::BinaryBulkProfile.with_size_stream : CrystalClick::BinaryBulkProfile.single_stream,
    shared_profile: shared_with_sizes ? CrystalClick::BinaryBulkProfile.with_size_stream : CrystalClick::BinaryBulkProfile.single_stream)
end

describe "W126 independent literal file reader" do
  it "discovers arbitrary Dynamic paths and alternatives, returning owned full and selected documents" do
    full = nil.as(Array(Array(CrystalClick::ObjectDocument))?)
    w126_root_part do |path, _column, _dynamic, _typed|
      full = w126_root_read(path)
      selected = w126_root_read(path, first_mark: 1, mark_count: 1)
      selected.size.should eq(1)
      selected[0].size.should eq(1)
      selected[0][0].value_for("fixed.key").as_uint64.should eq(13_u64)
      selected[0][0].has_path?("odd.path/%").should be_false
      w126_root_read(path, first_mark: 3, mark_count: 0).should be_empty
    end
    rows = full.not_nil!
    rows.map(&.size).should eq([2, 1, 1])
    rows[0][0].value_for("odd.path/%").as_string.should eq("a")
    rows[0][1].value_for("odd.path/%").as_uint64.should eq(7_u64)
    rows[2][0].value_for("odd.path/%").as_string.should eq("z")
    rows[2][0].value_for("fixed.key").as_uint64.should eq(14_u64)
  end

  it "resolves only the explicit hashed policy, never a fallback alias" do
    w126_root_part(hashed: true) do |path, _column, _dynamic, _typed|
      w126_root_read(path, hashed: true).map(&.size).should eq([2, 1, 1])
      expect_raises(CrystalClick::CorruptPartError) { w126_root_read(path) }
    end
    w126_root_part do |path, _column, _dynamic, _typed|
      expect_raises(CrystalClick::CorruptPartError) { w126_root_read(path, hashed: true) }
    end
  end

  it "keeps independent String profiles and complete multi-frame structure prefixes" do
    { {true, false}, {false, true}, {true, true} }.each do |profiles|
      w126_root_part(with_sizes: profiles[0], shared_with_sizes: profiles[1], split_metadata: true) do |path, _column, _dynamic, _typed|
        result = w126_root_read(path, first_mark: 2, mark_count: 1,
          with_sizes: profiles[0], shared_with_sizes: profiles[1])
        result[0][0].value_for("odd.path/%").as_string.should eq("z")
        w126_root_read(path, mark_count: 0, with_sizes: profiles[0], shared_with_sizes: profiles[1]).should be_empty
      end
    end
  end

  it "refuses an unselected arm row mismatch even for zero selection" do
    w126_root_part do |path, _column, dynamic, _typed|
      marks_path = File.join(path, dynamic + ".UInt64.mrk2")
      File.open(marks_path, "r+b") do |io|
        io.seek(16)
        w126_root_u64(io, 1_u64) # wrong first outer count, outside middle selection
      end
      expect_raises(CrystalClick::CorruptPartError) { w126_root_read(path, first_mark: 1, mark_count: 1) }
      expect_raises(CrystalClick::CorruptPartError) { w126_root_read(path, first_mark: 1, mark_count: 0) }
    end
  end

  it "refuses metadata at the after-flag coordinate and a later drifting metadata mark" do
    {0, 1}.each do |mark_index|
      w126_root_part do |path, column, _dynamic, _typed|
        marks_path = File.join(path, column + ".object_structure.mrk2")
        File.open(marks_path, "r+b") do |io|
          # Keep coordinates monotone so generic transport validation cannot
          # hide the metadata-specific prefix and later-mark guards.
          (mark_index...3).each do |index|
            io.seek(index * 24 + 8)
            w126_root_u64(io, 22_u64) # parser before-flag boundary is 21
          end
        end
        expect_raises(CrystalClick::CorruptPartError) { w126_root_read(path, mark_count: 0) }
      end
    end
  end

  it "does not authenticate unselected typed frames but rejects them when selected" do
    w126_root_part do |path, _column, _dynamic, typed|
      data_path = File.join(path, typed + ".bin")
      File.open(data_path, "r+b") do |io|
        byte = io.read_byte.not_nil!
        io.seek(0)
        io.write_byte(byte ^ 1_u8)
      end
      w126_root_read(path, first_mark: 1, mark_count: 1)[0][0].value_for("fixed.key").as_uint64.should eq(13_u64)
      expect_raises(CrystalClick::CorruptPartError) { w126_root_read(path) }
    end
  end

  it "refuses missing, size-changed and symlink lanes without partial results" do
    {:missing, :short, :symlink}.each do |mode|
      w126_root_part do |path, _column, dynamic, _typed|
        lane = File.join(path, dynamic + ".SharedVariant.bin")
        case mode
        when :missing
          File.delete(lane)
        when :short
          File.open(lane, "wb") { |io| io.write_byte(1_u8) }
        when :symlink
          File.delete(lane)
          File.symlink("checksums.txt", lane)
        end
        expect_raises(CrystalClick::CorruptPartError) { w126_root_read(path, mark_count: 0) }
      end
    end
  end

  it "guards invalid selections and consumptive codec/transport limits" do
    w126_root_part do |path, _column, _dynamic, _typed|
      expect_raises(ArgumentError) { w126_root_read(path, first_mark: -1) }
      expect_raises(ArgumentError) { w126_root_read(path, first_mark: 4) }
      expect_raises(ArgumentError) { w126_root_read(path, first_mark: 2, mark_count: 2) }
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentFileReader.read(path, "p/ayload%",
          {"fixed.key" => CrystalClick::BinaryDataType.primitive("UInt64")},
          mark_count: 0, limits: CrystalClick::BinaryCodecLimits.new(
          max_depth: 64, max_nodes: 0, max_elements: 1_000_000, max_bytes: 64 * 1024 * 1024))
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentFileReader.read(path, "p/ayload%",
          {"fixed.key" => CrystalClick::BinaryDataType.primitive("UInt64")},
          mark_count: 0, transport_limits: CrystalClick::CompressedStreamLimits.new(max_records: 2))
      end
    end
  end

  it "admits the complete source roster against logical limits before value lookup for zero selection" do
    path = File.tempname("crystal-click-w126-root-roster")
    Dir.mkdir(path)
    begin
      # No Dynamic or typed schema entries can consume this element budget.
      # Value files are intentionally absent: a late selected-only guard would
      # report missing lanes, not the required full-source roster exhaustion.
      raw = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
      data = w126_root_frame(raw)
      records = Array(Tuple(UInt64, UInt64, UInt64)).new(17)
      16.times { records << {0_u64, 10_u64, 1_u64} }
      records << {data.size.to_u64, 0_u64, 0_u64}
      marks = w126_root_marks(records)
      files = {"payload.object_structure.bin" => data, "payload.object_structure.mrk2" => marks}
      checksums = IO::Memory.new
      w126_root_varuint(checksums, files.size.to_u64)
      files.each do |name, bytes|
        w126_root_string(checksums, name)
        w126_root_varuint(checksums, bytes.size.to_u64)
        checksums.write(Bytes.new(16, 0_u8))
        checksums.write_byte(0_u8)
        File.open(File.join(path, name), "wb") { |io| io.write(bytes) }
      end
      File.open(File.join(path, "checksums.txt"), "wb") do |io|
        io << "checksums format version: 4\n"
        io.write(w126_root_frame(checksums.to_slice))
      end
      limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 4_096,
        max_elements: 15, max_bytes: 65_536)
      expect_raises(CrystalClick::CorruptPartError, /binary codec element limit exceeded/) do
        CrystalClick::ObjectDocumentFileReader.read(path, "payload", {} of String => CrystalClick::BinaryDataType,
          first_mark: 16, mark_count: 0, limits: limits)
      end
    ensure
      FileUtils.rm_rf(path)
    end
  end

  it "rejects oversized unhashed column and schema basenames before part lookup" do
    long_name = "." * 4_096
    expect_raises(CrystalClick::UnsupportedFormatError, /basename.*limit/i) do
      CrystalClick::ObjectDocumentFileReader.read("/not-read-part", long_name,
        {} of String => CrystalClick::BinaryDataType)
    end
    expect_raises(CrystalClick::UnsupportedFormatError, /basename.*limit/i) do
      CrystalClick::ObjectDocumentFileReader.read("/not-read-part", "payload",
        {long_name => CrystalClick::BinaryDataType.primitive("UInt64")})
    end
  end

  it "does not confuse bounded long logical names with short hashed basenames" do
    column = "c" * 4_096
    typed_path = "t" * 4_096
    w126_root_part(hashed: true, raw_column: column, raw_typed_path: typed_path) do |path, _column, _dynamic, _typed|
      result = CrystalClick::ObjectDocumentFileReader.read(path, column,
        {typed_path => CrystalClick::BinaryDataType.primitive("UInt64")},
        first_mark: 2, mark_count: 1, hashed: true)
      result[0][0].value_for(typed_path).as_uint64.should eq(14_u64)
      result[0][0].value_for("odd.path/%").as_string.should eq("z")
    end
  end
end

# Literal-only LZ4, independent of the production transport writer.
private def w126_root_frame(raw : Bytes) : Bytes
  raise "empty literal frame" if raw.empty?
  compressed = IO::Memory.new
  compressed.write_byte((Math.min(raw.size, 15) << 4).to_u8)
  if raw.size >= 15
    remaining = raw.size - 15
    while remaining >= 255
      compressed.write_byte(255_u8)
      remaining -= 255
    end
    compressed.write_byte(remaining.to_u8)
  end
  compressed.write(raw)
  payload = IO::Memory.new
  payload.write_byte(0x82_u8)
  payload.write_bytes((9 + compressed.size).to_u32, IO::ByteFormat::LittleEndian)
  payload.write_bytes(raw.size.to_u32, IO::ByteFormat::LittleEndian)
  payload.write(compressed.to_slice)
  hash = CrystalClick::CityHashV1.hash128(payload.to_slice)
  framed = IO::Memory.new
  w126_root_u64(framed, hash[0])
  w126_root_u64(framed, hash[1])
  framed.write(payload.to_slice)
  framed.to_slice
end

private def w126_root_marks(grid : Array(Tuple(UInt64, UInt64, UInt64))) : Bytes
  io = IO::Memory.new
  grid.each { |mark| mark.each { |word| w126_root_u64(io, word) } }
  io.to_slice
end

private def w126_root_files(data : Bytes, marks : Bytes, &)
  data_path = File.tempname("crystal-click-w126-root-data")
  marks_path = File.tempname("crystal-click-w126-root-marks")
  begin
    File.open(data_path, "wb") { |io| io.write(data) }
    File.open(marks_path, "wb") { |io| io.write(marks) }
    yield data_path, marks_path
  ensure
    File.delete(data_path) if File.exists?(data_path)
    File.delete(marks_path) if File.exists?(marks_path)
  end
end

describe "W126 independent physical domain inspection" do
  it "owns the complete row grid without decoding a corrupt payload checksum" do
    data = w126_root_frame(Bytes[1, 2, 3, 4])
    data[0] ^= 1_u8
    marks = w126_root_marks([{0_u64, 2_u64, 2_u64}, {0_u64, 3_u64, 1_u64}, {data.size.to_u64, 0_u64, 0_u64}])
    budget = CrystalClick::CompressedStreamBudget.read_default
    result = nil.as(CrystalClick::CompressedMarkGrid?)
    w126_root_files(data, marks) do |data_path, marks_path|
      result = CrystalClick::CompressedMarkReader.inspect(data_path, marks_path,
        expected_data_size: data.size.to_i64, expected_mark_size: marks.size.to_i64, budget: budget)
    end
    grid = result.not_nil!
    grid.mark_count.should eq(2)
    grid.prefix_size.should eq(2)
    grid.logical_size.should eq(4_i64)
    grid.positions.should eq([2_i64, 3_i64, 4_i64])
    grid.rows_per_mark.should eq([2_u64, 1_u64])
    budget.decoded_byte_count.should eq(0_i64)
    budget.result_byte_count.should eq(0_i64)
    grid.positions[0] = 99_i64
    grid.rows_per_mark[0] = 99_u64
    grid.position_at(0).should eq(2_i64)
    grid.row_count_at(0).should eq(2_u64)
  end

  it "refuses a wrong explicit prefix before selected acquisition" do
    data = w126_root_frame(Bytes[1, 2, 3])
    marks = w126_root_marks([{0_u64, 2_u64, 1_u64}, {data.size.to_u64, 0_u64, 0_u64}])
    w126_root_files(data, marks) do |data_path, marks_path|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.inspect(data_path, marks_path,
          expected_data_size: data.size.to_i64, expected_mark_size: marks.size.to_i64, prefix_size: 1)
      end
    end
  end

  it "normalizes a multi-frame metadata prefix and frame-boundary aliases" do
    first = w126_root_frame(Bytes[4, 0, 0, 0, 0, 0, 0, 0])
    second = w126_root_frame(Bytes[0, 0, 1, 0])
    data = IO::Memory.new
    data.write(first)
    data.write(second)
    # One real mark uses the second frame start, the next its interior.
    # Both point to the same logical metadata prefix at offset ten.
    marks = w126_root_marks([
      {first.size.to_u64, 2_u64, 1_u64},
      {first.size.to_u64, 2_u64, 1_u64},
      {data.size.to_u64, 0_u64, 0_u64},
    ])
    w126_root_files(data.to_slice, marks) do |data_path, marks_path|
      grid = CrystalClick::CompressedMarkReader.inspect(data_path, marks_path,
        expected_data_size: data.size.to_i64, expected_mark_size: marks.size.to_i64, prefix_size: 10)
      grid.prefix_size.should eq(10)
      grid.positions.should eq([10_i64, 10_i64, 12_i64])
    end
    alias_marks = w126_root_marks([
      {0_u64, 8_u64, 1_u64}, {first.size.to_u64, 0_u64, 1_u64},
      {data.size.to_u64, 0_u64, 0_u64},
    ])
    w126_root_files(data.to_slice, alias_marks) do |data_path, marks_path|
      grid = CrystalClick::CompressedMarkReader.inspect(data_path, marks_path,
        expected_data_size: data.size.to_i64, expected_mark_size: alias_marks.size.to_i64)
      grid.positions.should eq([8_i64, 8_i64, 12_i64])
    end
  end

  it "preserves physical outer rows for empty sparse lanes" do
    marks = w126_root_marks([{0_u64, 0_u64, 2_u64}, {0_u64, 0_u64, 3_u64}, {0_u64, 0_u64, 0_u64}])
    w126_root_files(Bytes.empty, marks) do |data_path, marks_path|
      grid = CrystalClick::CompressedMarkReader.inspect(data_path, marks_path,
        expected_data_size: 0_i64, expected_mark_size: marks.size.to_i64)
      grid.rows_per_mark.should eq([2_u64, 3_u64])
      grid.positions.should eq([0_i64, 0_i64, 0_i64])
    end
  end

  it "rejects malformed unselected rows and terminal EOF" do
    data = w126_root_frame(Bytes[1, 2, 3])
    [
      [{0_u64, 0_u64, 1_u64}, {0_u64, 1_u64, 0_u64}, {data.size.to_u64, 0_u64, 0_u64}],
      [{0_u64, 0_u64, 1_u64}, {0_u64, 1_u64, 1_u64}, {0_u64, 2_u64, 0_u64}],
    ].each do |records|
      marks = w126_root_marks(records)
      w126_root_files(data, marks) do |data_path, marks_path|
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::CompressedMarkReader.inspect(data_path, marks_path,
            expected_data_size: data.size.to_i64, expected_mark_size: marks.size.to_i64)
        end
      end
    end
  end

  it "reserves the complete grid before mapping when the record limit is short" do
    limits = CrystalClick::CompressedStreamLimits.new(max_records: 2)
    budget = CrystalClick::CompressedStreamBudget.new(limits)
    expect_raises(CrystalClick::CorruptPartError, /record.*limit/i) do
      CrystalClick::CompressedMarkReader.inspect("/not-read-data", "/not-read-marks",
        expected_data_size: 0_i64, expected_mark_size: 72_i64, budget: budget)
    end
    budget.record_count.should eq(0_i64)
  end
end

describe "W126 exact structure statistics boundary" do
  it "measures Object's suffix flag boundary relative to its parse start" do
    # V3, one path x, MAP, nonempty statistics: x=1 and zero shared entries.
    raw = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0x78, 0, 1, 1, 0]
    io = IO::Memory.new
    io.write(Bytes[9, 9])
    io.write(raw)
    context = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryCodecLimits.default, io.to_slice)
    context.read_byte
    context.read_byte
    object, offset = CrystalClick::ObjectStructureCodec.read_with_statistics_offset(context)
    offset.should eq(12)
    raw[offset].should eq(1_u8)
    object.dynamic_path_at(0).should eq("x")
    context.ensure_consumed
    CrystalClick::ObjectStructureCodec.decode(raw).dynamic_path_at(0).should eq("x")
  end

  it "measures Dynamic's suffix flag before statistics or an empty flag" do
    # V3, ordinary UInt64 descriptor, true flag, SharedVariant/UInt64 counts,
    # followed by zero shared-alternative statistics.
    raw = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 1, 4, 1, 0, 2, 0]
    context = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryCodecLimits.default, raw)
    dynamic, offset = CrystalClick::DynamicStructureCodec.read_with_statistics_offset(context)
    offset.should eq(10)
    dynamic.type_at(0).name.should eq("UInt64")
    context.ensure_consumed
    empty_stats = raw[0, 11].dup
    empty_stats[10] = 0_u8
    empty_context = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryCodecLimits.default, empty_stats)
    CrystalClick::DynamicStructureCodec.read_with_statistics_offset(empty_context)[1].should eq(10)
    empty_context.ensure_consumed
  end
end
