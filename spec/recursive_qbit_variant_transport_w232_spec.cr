require "./spec_helper"
require "file_utils"

private struct W232WindowRead
  getter data_name : String
  getter first_mark : Int32
  getter mark_count : Int32
  getter budget : CrystalClick::CompressedStreamBudget

  def initialize(
    @data_name : String,
    first_mark : Int,
    mark_count : Int,
    @budget : CrystalClick::CompressedStreamBudget,
  )
    @first_mark = first_mark.to_i32
    @mark_count = mark_count.to_i32
  end
end

private class W232CountingPartStreamSource < CrystalClick::PartStreamSource
  @window_reads : Array(W232WindowRead)

  def initialize(part_path : String)
    super(part_path)
    @window_reads = [] of W232WindowRead
  end

  def read_window(
    data_name : String,
    marks_name : String,
    first_mark : Int,
    mark_count : Int,
    prefix_size : Int = 0,
    budget : CrystalClick::CompressedStreamBudget = CrystalClick::CompressedStreamBudget.read_default,
  ) : CrystalClick::CompressedMarkWindow
    @window_reads << W232WindowRead.new(data_name, first_mark, mark_count, budget)
    super
  end

  def window_reads : Array(W232WindowRead)
    @window_reads.dup
  end
end

private def w232_variant_transport_qbit_value(type : CrystalClick::QBitType, seed : UInt8) : CrystalClick::BinaryValue
  raw = Bytes.new(type.raw_row_bytes) { |index| (seed.to_i + index).to_u8 }
  CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(type, raw))
end

private def w232_variant_transport_arm_index(
  variant : CrystalClick::BinaryDataType,
  arm : CrystalClick::BinaryDataType,
) : Int
  variant.child_count.times do |index|
    return index if variant.child_at(index) == arm
  end
  raise ArgumentError.new("W232 Variant transport arm is absent")
end

private def w232_try_variant_transport_types : Tuple(
  CrystalClick::BinaryDataType,
  CrystalClick::QBitType,
  CrystalClick::BinaryDataType,
  CrystalClick::BinaryDataType,
  CrystalClick::BinaryDataType,
  CrystalClick::BinaryDataType,
)?
  qbit_type = CrystalClick::QBitType.new("Int8", 3_u64)
  qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
  string = CrystalClick::BinaryDataType.primitive("String")
  array_qbit = CrystalClick::BinaryDataType.array(qbit)
  map_qbit = CrystalClick::BinaryDataType.map(string, qbit)
  variant = CrystalClick::BinaryDataType.variant(
    [string, qbit, array_qbit, map_qbit] of CrystalClick::BinaryDataType,
  )
  root = CrystalClick::BinaryDataType.array(variant)
  {root, qbit_type, qbit, string, array_qbit, map_qbit}
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w232_variant_transport_rows(
  types : Tuple(
    CrystalClick::BinaryDataType,
    CrystalClick::QBitType,
    CrystalClick::BinaryDataType,
    CrystalClick::BinaryDataType,
    CrystalClick::BinaryDataType,
    CrystalClick::BinaryDataType,
  ),
  last_mark_mode : String = "both",
) : Array(Array(CrystalClick::BinaryValue))
  root, qbit_type, qbit, string, array_qbit, map_qbit = types
  variant = root.child_at(0)
  qbit_index = w232_variant_transport_arm_index(variant, qbit)
  string_index = w232_variant_transport_arm_index(variant, string)
  array_index = w232_variant_transport_arm_index(variant, array_qbit)
  map_index = w232_variant_transport_arm_index(variant, map_qbit)

  rows = Array(CrystalClick::BinaryValue).new(6) do |row|
    selected = case row
               when 0, 4
                 if row == 4 && last_mark_mode == "both" || row == 4 && last_mark_mode == "map"
                   entries = [
                     CrystalClick::BinaryValue.string("map-#{row}"),
                     w232_variant_transport_qbit_value(qbit_type, 0x50_u8),
                   ] of CrystalClick::BinaryValue
                   CrystalClick::BinaryValue.variant(
                     variant,
                     map_index,
                     CrystalClick::BinaryValue.map(map_qbit, entries),
                   )
                 else
                   CrystalClick::BinaryValue.variant(
                     variant,
                     string_index,
                     CrystalClick::BinaryValue.string("plain-#{row}"),
                   )
                 end
               when 1
                 CrystalClick::BinaryValue.variant(
                   variant,
                   qbit_index,
                   w232_variant_transport_qbit_value(qbit_type, 0x10_u8),
                 )
               when 2
                 CrystalClick::BinaryValue.variant(
                   variant,
                   array_index,
                   CrystalClick::BinaryValue.array(
                     array_qbit,
                     [w232_variant_transport_qbit_value(qbit_type, 0x20_u8), w232_variant_transport_qbit_value(qbit_type, 0x21_u8)] of CrystalClick::BinaryValue,
                   ),
                 )
               when 3
                 entries = [
                   CrystalClick::BinaryValue.string("map-#{row}"),
                   w232_variant_transport_qbit_value(qbit_type, 0x30_u8),
                   CrystalClick::BinaryValue.string("map-#{row}-tail"),
                   w232_variant_transport_qbit_value(qbit_type, 0x31_u8),
                 ] of CrystalClick::BinaryValue
                 CrystalClick::BinaryValue.variant(
                   variant,
                   map_index,
                   CrystalClick::BinaryValue.map(map_qbit, entries),
                 )
               else
                 if last_mark_mode == "map"
                   CrystalClick::BinaryValue.variant(
                     variant,
                     string_index,
                     CrystalClick::BinaryValue.string("plain-#{row}"),
                   )
                 else
                   CrystalClick::BinaryValue.variant(
                     variant,
                     array_index,
                     CrystalClick::BinaryValue.array(
                       array_qbit,
                       [w232_variant_transport_qbit_value(qbit_type, 0x60_u8), w232_variant_transport_qbit_value(qbit_type, 0x61_u8)] of CrystalClick::BinaryValue,
                     ),
                   )
                 end
               end
    CrystalClick::BinaryValue.array(root, [selected] of CrystalClick::BinaryValue)
  end
  [[rows[0], rows[1]], [rows[2], rows[3]], [rows[4], rows[5]]] of Array(CrystalClick::BinaryValue)
end

private class W232VariantTransportFixture
  getter scratch : String
  getter part : String
  getter fixture_types : Tuple(
    CrystalClick::BinaryDataType,
    CrystalClick::QBitType,
    CrystalClick::BinaryDataType,
    CrystalClick::BinaryDataType,
    CrystalClick::BinaryDataType,
    CrystalClick::BinaryDataType,
  )
  getter physical : CrystalClick::BinaryBulkPhysicalPlan
  getter sites : Array(CrystalClick::BinaryQBitRecursiveAdmission::StaticSite)
  getter source : W232CountingPartStreamSource
  getter grids : Hash(String, CrystalClick::CompressedMarkGrid)
  getter parent_rows : Array(UInt64)

  def initialize(
    @scratch : String,
    @part : String,
    @fixture_types : Tuple(
      CrystalClick::BinaryDataType,
      CrystalClick::QBitType,
      CrystalClick::BinaryDataType,
      CrystalClick::BinaryDataType,
      CrystalClick::BinaryDataType,
      CrystalClick::BinaryDataType,
    ),
    @physical : CrystalClick::BinaryBulkPhysicalPlan,
    @sites : Array(CrystalClick::BinaryQBitRecursiveAdmission::StaticSite),
    @source : W232CountingPartStreamSource,
    @grids : Hash(String, CrystalClick::CompressedMarkGrid),
    @parent_rows : Array(UInt64),
  )
  end

  def root_type : CrystalClick::BinaryDataType
    @fixture_types[0]
  end

  def validate!(
    codec_limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryCodecLimits.default,
    transport_budget : CrystalClick::CompressedStreamBudget = CrystalClick::CompressedStreamBudget.new,
  ) : Nil
    CrystalClick::BinaryQBitStaticOccurrenceSchedule.validate!(
      root_type,
      @sites,
      @physical,
      @source,
      @grids,
      @parent_rows,
      codec_limits,
      transport_budget,
    )
  end

  def cleanup : Nil
    FileUtils.rm_rf(@scratch)
  end
end

private def w232_try_variant_transport_fixture(
  last_mark_mode : String = "both",
) : W232VariantTransportFixture?
  types = w232_try_variant_transport_types
  return nil unless types
  scratch = File.tempname("crystal-click-w232-qbit-variant-transport-")
  begin
    Dir.mkdir(scratch)
    part = File.join(scratch, "all_1_1_0")
    root_type = types[0]
    rows_by_mark = w232_variant_transport_rows(types, last_mark_mode)
    CrystalClick::WidePartWriter.write_uint64_qbit_bulk_part(
      part,
      "k",
      Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64, 66_u64],
      "v",
      root_type,
      rows_by_mark,
      rows_per_mark: 2,
    )

    physical = CrystalClick::BinaryBulkPhysicalPlan.new(
      root_type,
      "v",
      CrystalClick::BinaryBulkProfile.single_stream,
    )
    sites = CrystalClick::BinaryBulkTypePlan.new(
      root_type,
      CrystalClick::BinaryBulkProfile.single_stream,
    ).qbit_static_sites
    source = W232CountingPartStreamSource.new(part)
    grids = Hash(String, CrystalClick::CompressedMarkGrid).new
    physical.stream_names.each do |role, _name|
      grids[role] = source.inspect_grid(
        physical.data_file_for(role, true),
        physical.marks_file_for(role, true),
        physical.prefix_size_for(role),
      )
    end
    parent_rows = grids.values.first?.try(&.rows_per_mark) ||
                  raise CrystalClick::CorruptPartError.new("W232 fixture has no physical mark grid")
    parent_rows.should eq([2_u64, 2_u64, 2_u64])
    W232VariantTransportFixture.new(scratch, part, types, physical, sites, source, grids, parent_rows)
  rescue ex
    FileUtils.rm_rf(scratch)
    raise ex
  end
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w232_variant_transport_fixture_or_red(
  last_mark_mode : String = "both",
) : W232VariantTransportFixture
  fixture = w232_try_variant_transport_fixture(last_mark_mode)
  fixture.should_not be_nil
  fixture.not_nil!
end

private def w232_write_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w232_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w232_write_u64_at(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w232_read_u64(bytes : Bytes, offset : Int) : UInt64
  raise ArgumentError.new("W232 UInt64 field is truncated") if offset < 0 || offset > bytes.size - 8
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w232_encode_literal_lz4_frame(raw : Bytes) : Bytes
  raise ArgumentError.new("cannot encode an empty LZ4 block") if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  4.times { |index| frame[header + 1 + index] = ((compressed_size >> (index * 8)) & 0xff).to_u8 }
  4.times { |index| frame[header + 5 + index] = ((raw.size >> (index * 8)) & 0xff).to_u8 }

  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  if raw.size < 15
    frame[cursor] = (raw.size << 4).to_u8
    cursor += 1
  else
    frame[cursor] = 0xf0_u8
    cursor += 1
    remaining = raw.size - 15
    while remaining >= 255
      frame[cursor] = 255_u8
      cursor += 1
      remaining -= 255
    end
    frame[cursor] = remaining.to_u8
    cursor += 1
  end
  raw.copy_to(frame[cursor, raw.size])
  hash = CrystalClick::CityHashV1.hash128(
    frame[CrystalClick::CompressedBlock::CHECKSUM_SIZE, compressed_size],
  )
  w232_write_u64_at(frame, 0, hash[0])
  w232_write_u64_at(frame, 8, hash[1])
  frame
end

private def w232_refresh_part_checksums!(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w232_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w232_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w232_write_varuint(payload, file_bytes.size.to_u64)
    hash = CrystalClick::CityHashV1.file_hash(file_bytes)
    w232_write_u64(payload, hash[0])
    w232_write_u64(payload, hash[1])
    if entry.compressed
      raw = file_bytes.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w232_write_varuint(payload, raw.size.to_u64)
      raw_hash = CrystalClick::CityHashV1.file_hash(raw)
      w232_write_u64(payload, raw_hash[0])
      w232_write_u64(payload, raw_hash[1])
    else
      payload.write_byte(0_u8)
    end
  end
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(w232_encode_literal_lz4_frame(payload.to_slice))
  end
end

private def w232_corrupt_late_discriminator!(fixture : W232VariantTransportFixture, role : String) : Nil
  data_name = fixture.physical.data_file_for(role, true)
  marks_name = fixture.physical.marks_file_for(role, true)
  marks = File.read(File.join(fixture.part, marks_name)).to_slice
  mark_index = 2
  record_offset = mark_index * CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE
  compressed_offset = w232_read_u64(marks, record_offset)
  decompressed_offset = w232_read_u64(marks, record_offset + 8)

  data_path = File.join(fixture.part, data_name)
  data = File.read(data_path).to_slice.dup
  frame = CrystalClick::CompressedBlock.decode_frame(data, compressed_offset.to_i64)
  raw = frame.output.dup
  decompressed_offset.should be < raw.size.to_u64
  target = decompressed_offset.to_i
  raw[target].should_not eq(0xfe_u8)
  raw[target] = 0xfe_u8
  replacement = w232_encode_literal_lz4_frame(raw)
  replacement.size.should eq((frame.end_offset - compressed_offset.to_i64).to_i)
  replacement.copy_to(data[compressed_offset.to_i, replacement.size])
  File.write(data_path, data)
  w232_refresh_part_checksums!(fixture.part)
end

private def w232_corrupt_late_mark_start!(
  fixture : W232VariantTransportFixture,
  role : String,
) : Nil
  data_name = fixture.physical.data_file_for(role, true)
  marks_name = fixture.physical.marks_file_for(role, true)
  before = fixture.grids[role]
  marks_path = File.join(fixture.part, marks_name)
  marks = File.read(marks_path).to_slice.dup
  mark_index = 2
  record_offset = mark_index * CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE
  compressed_offset = w232_read_u64(marks, record_offset)
  old_decompressed_offset = w232_read_u64(marks, record_offset + 8)
  data = File.read(File.join(fixture.part, data_name)).to_slice
  frame = CrystalClick::CompressedBlock.decode_frame(data, compressed_offset.to_i64)
  old_decompressed_offset.should be < frame.output.size.to_u64
  new_decompressed_offset = old_decompressed_offset + 1_u64
  new_decompressed_offset.should be < frame.output.size.to_u64
  w232_write_u64_at(marks, record_offset + 8, new_decompressed_offset)
  File.write(marks_path, marks)
  w232_refresh_part_checksums!(fixture.part)

  after_source = CrystalClick::PartStreamSource.new(fixture.part)
  after = after_source.inspect_grid(
    data_name,
    marks_name,
    fixture.physical.prefix_size_for(role),
  )
  after.mark_count.should eq(before.mark_count)
  after.position_at(mark_index).should eq(before.position_at(mark_index) + 1_i64)
  after.rows_per_mark.should eq(before.rows_per_mark)
end

private def w232_open_corrupt_before_callback!(
  fixture : W232VariantTransportFixture,
  first_row : UInt64,
  row_count : Int,
) : Nil
  callbacks = 0
  expect_raises(CrystalClick::CorruptPartError) do
    table = CrystalClick::WidePartTable.open_selected_typed([fixture.part], ["v"])
    table.scan_typed_window(first_row, row_count) { |_batch| callbacks += 1 }
  end
  callbacks.should eq(0)
end

describe "W232 Variant-selected static QBit transport schedule" do
  it "reads each complete relevant discriminator and shared shape role once on the same transport budget" do
    fixture = w232_variant_transport_fixture_or_red
    begin
      types = fixture.fixture_types
      variant = types[0].child_at(0)
      array_arm = w232_variant_transport_arm_index(variant, types[4])
      map_arm = w232_variant_transport_arm_index(variant, types[5])
      shape_roles = [
        "root.sizes",
        "root.elements.discriminators",
        "root.elements.arm.#{array_arm}.sizes",
        "root.elements.arm.#{map_arm}.sizes",
      ]
      expected_files = shape_roles.map { |role| fixture.physical.data_file_for(role, true) }.sort
      budget = CrystalClick::CompressedStreamBudget.new

      fixture.validate!(transport_budget: budget)

      reads = fixture.source.window_reads
      reads.size.should eq(shape_roles.size)
      reads.map(&.data_name).sort.should eq(expected_files)
      reads.each do |read|
        read.first_mark.should eq(0)
        read.mark_count.should eq(fixture.parent_rows.size)
        read.budget.same?(budget).should be_true
      end
      expected_result_bytes = shape_roles.sum(0_i64) do |role|
        fixture.grids[role].logical_size
      end
      budget.result_byte_count.should eq(expected_result_bytes)
    ensure
      fixture.cleanup
    end
  end

  it "charges sparse-arm occurrence vectors before allocating or reading any shape lane" do
    fixture = w232_variant_transport_fixture_or_red
    begin
      # W231's three retained size vectors plus its two per-mark accumulators
      # fit exactly: (3 + 2) * 3 marks * 8 bytes = 120. The three sparse
      # QBit-bearing Variant-arm axes must also be included in the preflight.
      limits = CrystalClick::BinaryCodecLimits.new(
        max_depth: 64,
        max_nodes: 4_096,
        max_elements: 1_000_000,
        max_bytes: 120,
      )
      error = expect_raises(CrystalClick::CorruptPartError) do
        fixture.validate!(codec_limits: limits)
      end
      error.message.not_nil!.should contain("workspace")
      fixture.source.window_reads.should be_empty
    ensure
      fixture.cleanup
    end
  end

  it "rejects an invalid discriminator in a late unselected mark before an early callback" do
    fixture = w232_variant_transport_fixture_or_red("invalid")
    begin
      role = "root.elements.discriminators"
      fixture.physical.stream_names.has_key?(role).should be_true
      # The first row in the final mark is the non-QBit String arm. The scan
      # window below selects only row zero, so this tag is both late and off-window.
      w232_corrupt_late_discriminator!(fixture, role)
      w232_open_corrupt_before_callback!(fixture, 0_u64, 1)
    ensure
      fixture.cleanup
    end
  end

  it "rejects a late sparse QBit plane mark delta before an EOF callback" do
    fixture = w232_variant_transport_fixture_or_red("array")
    begin
      variant = fixture.root_type.child_at(0)
      array_arm = w232_variant_transport_arm_index(variant, fixture.fixture_types[4])
      array_site_path = "root.elements.arm.#{array_arm}.elements"
      array_site = fixture.sites.find { |site| site.path == array_site_path } ||
                   raise CrystalClick::CorruptPartError.new("W232 Array-arm QBit site is missing")
      plane_role = array_site.plane_roles.first
      w232_corrupt_late_mark_start!(fixture, plane_role)
      w232_open_corrupt_before_callback!(fixture, 6_u64, 1)
    ensure
      fixture.cleanup
    end
  end

  it "rejects a bad late Array-arm size delta before an early callback" do
    fixture = w232_variant_transport_fixture_or_red("array")
    begin
      variant = fixture.root_type.child_at(0)
      array_arm = w232_variant_transport_arm_index(variant, fixture.fixture_types[4])
      role = "root.elements.arm.#{array_arm}.sizes"
      w232_corrupt_late_mark_start!(fixture, role)
      w232_open_corrupt_before_callback!(fixture, 0_u64, 1)
    ensure
      fixture.cleanup
    end
  end

  it "rejects a bad late Map-arm size delta before an EOF callback" do
    fixture = w232_variant_transport_fixture_or_red("map")
    begin
      variant = fixture.root_type.child_at(0)
      map_arm = w232_variant_transport_arm_index(variant, fixture.fixture_types[5])
      role = "root.elements.arm.#{map_arm}.sizes"
      w232_corrupt_late_mark_start!(fixture, role)
      w232_open_corrupt_before_callback!(fixture, 6_u64, 1)
    ensure
      fixture.cleanup
    end
  end
end
