require "./spec_helper"

private def w118_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4_096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes
  )
end

private def w118_copy(source : Bytes) : Bytes
  Bytes.new(source.size) { |index| source[index] }
end

private def w118_concat(parts : Array(Bytes)) : Bytes
  total = 0
  parts.each { |part| total += part.size }
  output = Bytes.new(total)
  offset = 0
  parts.each do |part|
    part.size.times do |index|
      output[offset] = part[index]
      offset += 1
    end
  end
  output
end

private def w118_var_uint(value : UInt64) : Bytes
  output = [] of UInt8
  remaining = value
  loop do
    payload = (remaining & 0x7f_u64).to_u8
    remaining >>= 7
    output << (remaining == 0_u64 ? payload : payload | 0x80_u8)
    break if remaining == 0_u64
  end
  Bytes.new(output.size) { |index| output[index] }
end

private def w118_u64_le(value : UInt64) : Bytes
  Bytes[
    (value & 0xff_u64).to_u8,
    ((value >> 8) & 0xff_u64).to_u8,
    ((value >> 16) & 0xff_u64).to_u8,
    ((value >> 24) & 0xff_u64).to_u8,
    ((value >> 32) & 0xff_u64).to_u8,
    ((value >> 40) & 0xff_u64).to_u8,
    ((value >> 48) & 0xff_u64).to_u8,
    ((value >> 56) & 0xff_u64).to_u8,
  ]
end

private def w118_sizes(counts : Array(UInt64)) : Bytes
  parts = [] of Bytes
  counts.each { |count| parts << w118_u64_le(count) }
  w118_concat(parts)
end

private def w118_frame_lane(payloads : Array(Bytes)) : Bytes
  parts = [] of Bytes
  payloads.each do |payload|
    parts << w118_var_uint(payload.size.to_u64)
    parts << payload
  end
  w118_concat(parts)
end

private def w118_entry(path : Bytes, value : CrystalClick::BinaryValue) : CrystalClick::ObjectSharedMapEntry
  CrystalClick::ObjectSharedMapEntry.new(path: path, value: value)
end

private def w118_authored_rows : Array(CrystalClick::ObjectSharedMapRow)
  array_nullable_string = CrystalClick::BinaryDataType.array(
    CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("String"))
  )
  array_nullable_int64 = CrystalClick::BinaryDataType.array(
    CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("Int64"))
  )
  nullable_string = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("String"))

  empty_strings = CrystalClick::BinaryValue.array(array_nullable_string, [] of CrystalClick::BinaryValue)
  empty_ints = CrystalClick::BinaryValue.array(array_nullable_int64, [] of CrystalClick::BinaryValue)

  [
    CrystalClick::ObjectSharedMapRow.new([
      w118_entry(Bytes[0x61_u8, 0x00_u8, 0xff_u8], empty_strings),
      w118_entry(Bytes[0x62_u8], CrystalClick::BinaryValue.int64(42_i64)),
    ] of CrystalClick::ObjectSharedMapEntry),
    CrystalClick::ObjectSharedMapRow.new([] of CrystalClick::ObjectSharedMapEntry),
    CrystalClick::ObjectSharedMapRow.new([
      w118_entry(Bytes[0x65_u8, 0x6d_u8, 0x70_u8, 0x74_u8, 0x79_u8, 0x5f_u8, 0x69_u8, 0x36_u8, 0x34_u8], empty_ints),
      w118_entry(Bytes[0x66_u8, 0x6c_u8, 0x6f_u8, 0x61_u8, 0x74_u8], CrystalClick::BinaryValue.float64_bits(0x8000_0000_0000_0000_u64)),
      w118_entry(Bytes[0x6e_u8, 0x75_u8, 0x6c_u8, 0x6c_u8, 0x61_u8, 0x62_u8, 0x6c_u8, 0x65_u8, 0x5f_u8, 0x6e_u8, 0x75_u8, 0x6c_u8, 0x6c_u8], CrystalClick::BinaryValue.null(nullable_string)),
      w118_entry(Bytes[0x72_u8, 0x61_u8, 0x77_u8], CrystalClick::BinaryValue.string(String.new(Bytes[0xff_u8, 0x00_u8, 0x61_u8]))),
    ] of CrystalClick::ObjectSharedMapEntry),
    CrystalClick::ObjectSharedMapRow.new([
      w118_entry(Bytes[0x62_u8, 0x6f_u8, 0x6f_u8, 0x6c_u8], CrystalClick::BinaryValue.bool(true)),
      w118_entry(Bytes[0x6e_u8, 0x75_u8, 0x6c_u8, 0x6c_u8], CrystalClick::BinaryValue.null),
    ] of CrystalClick::ObjectSharedMapEntry),
  ] of CrystalClick::ObjectSharedMapRow
end

private def w118_authored_wire : Tuple(Bytes, Bytes, Bytes)
  sizes = w118_sizes([2_u64, 0_u64, 4_u64, 2_u64] of UInt64)
  paths = w118_frame_lane([
    Bytes[0x61_u8, 0x00_u8, 0xff_u8],
    Bytes[0x62_u8],
    Bytes[0x65_u8, 0x6d_u8, 0x70_u8, 0x74_u8, 0x79_u8, 0x5f_u8, 0x69_u8, 0x36_u8, 0x34_u8],
    Bytes[0x66_u8, 0x6c_u8, 0x6f_u8, 0x61_u8, 0x74_u8],
    Bytes[0x6e_u8, 0x75_u8, 0x6c_u8, 0x6c_u8, 0x61_u8, 0x62_u8, 0x6c_u8, 0x65_u8, 0x5f_u8, 0x6e_u8, 0x75_u8, 0x6c_u8, 0x6c_u8],
    Bytes[0x72_u8, 0x61_u8, 0x77_u8],
    Bytes[0x62_u8, 0x6f_u8, 0x6f_u8, 0x6c_u8],
    Bytes[0x6e_u8, 0x75_u8, 0x6c_u8, 0x6c_u8],
  ] of Bytes)
  values = w118_frame_lane([
    Bytes[0x1e_u8, 0x23_u8, 0x15_u8, 0x00_u8],
    Bytes[0x0a_u8, 0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
    Bytes[0x1e_u8, 0x23_u8, 0x0a_u8, 0x00_u8],
    Bytes[0x0e_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8],
    Bytes[0x23_u8, 0x15_u8, 0x01_u8],
    Bytes[0x15_u8, 0x03_u8, 0xff_u8, 0x00_u8, 0x61_u8],
    Bytes[0x2d_u8, 0x01_u8],
    Bytes[0x00_u8],
  ] of Bytes)
  {sizes, paths, values}
end

private def w118_budget_rows : Array(CrystalClick::ObjectSharedMapRow)
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  one = CrystalClick::BinaryValue.fixed(uint8, Bytes[0x01_u8])
  [
    CrystalClick::ObjectSharedMapRow.new([w118_entry(Bytes[0x61_u8], one)] of CrystalClick::ObjectSharedMapEntry),
    CrystalClick::ObjectSharedMapRow.new([w118_entry(Bytes[0x62_u8], one)] of CrystalClick::ObjectSharedMapEntry),
  ] of CrystalClick::ObjectSharedMapRow
end

private def w118_budget_wire : Tuple(Bytes, Bytes, Bytes)
  {
    w118_sizes([1_u64, 1_u64] of UInt64),
    w118_frame_lane([Bytes[0x61_u8], Bytes[0x62_u8]] of Bytes),
    w118_frame_lane([Bytes[0x01_u8, 0x01_u8], Bytes[0x01_u8, 0x01_u8]] of Bytes),
  }
end

describe "W118 Object shared MAP block codec" do
  it "decodes and re-encodes authored nonzero-origin local slices with nominal values and opaque paths" do
    wire = w118_authored_wire
    # These four size cells are the local selected slice for global pk3..6.
    # The codec receives local counts, not a cumulative/global mark axis.
    wire[0].should eq(Bytes[
      0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ])

    decoded = CrystalClick::ObjectSharedMapCodec.decode(wire[0], wire[1], wire[2], 4)
    decoded.size.should eq(4)
    decoded[0].entry_count.should eq(2)
    decoded[1].entry_count.should eq(0)
    decoded[2].entry_count.should eq(4)
    decoded[3].entry_count.should eq(2)

    opaque_path = Bytes[0x61_u8, 0x00_u8, 0xff_u8]
    decoded[0].entry_at(0).path.should eq(opaque_path)
    decoded[0].entry_at(0).path_byte_size.should eq(3)
    decoded[0].entry_at(0).path_byte_at(1).should eq(0x00_u8)
    decoded[0].entry_at(0).value.type.name.should eq("Array(Nullable(String))")
    decoded[0].entry_at(0).value.elements.should be_empty
    decoded[0].entry_at(1).value.type.name.should eq("Int64")
    decoded[0].entry_at(1).value.as_int64.should eq(42_i64)
    decoded[2].entry_at(0).value.type.name.should eq("Array(Nullable(Int64))")
    decoded[2].entry_at(0).value.elements.should be_empty
    decoded[2].entry_at(1).value.as_float64_bits.should eq(0x8000_0000_0000_0000_u64)
    decoded[2].entry_at(2).value.type.name.should eq("Nullable(String)")
    decoded[2].entry_at(2).value.is_null?.should be_true
    decoded[2].entry_at(3).value.as_string.to_slice.should eq(Bytes[0xff_u8, 0x00_u8, 0x61_u8])
    decoded[3].entry_at(0).value.as_bool.should be_true
    decoded[3].entry_at(1).value.type.name.should eq("Nothing")
    decoded[3].entry_at(1).value.is_null?.should be_true

    decoded[3].entry_at(1).path.should eq(Bytes[0x6e_u8, 0x75_u8, 0x6c_u8, 0x6c_u8])
    rows = w118_authored_rows
    encoded = CrystalClick::ObjectSharedMapCodec.encode(rows)
    encoded.sizes.should eq(wire[0])
    encoded.paths.should eq(wire[1])
    encoded.values.should eq(wire[2])

    again = CrystalClick::ObjectSharedMapCodec.decode(encoded.sizes, encoded.paths, encoded.values, rows.size)
    again[2].entry_at(2).value.is_null?.should be_true
    again[3].entry_at(1).value.is_null?.should be_true
    again[3].entry_at(1).value.type.name.should eq("Nothing")
  end

  it "preserves empty rows and entirely empty lanes" do
    empty_rows = [
      CrystalClick::ObjectSharedMapRow.new([] of CrystalClick::ObjectSharedMapEntry),
      CrystalClick::ObjectSharedMapRow.new([] of CrystalClick::ObjectSharedMapEntry),
    ] of CrystalClick::ObjectSharedMapRow
    streams = CrystalClick::ObjectSharedMapCodec.encode(empty_rows)
    streams.sizes.should eq(w118_sizes([0_u64, 0_u64] of UInt64))
    streams.paths.should be_empty
    streams.values.should be_empty
    decoded = CrystalClick::ObjectSharedMapCodec.decode(streams.sizes, streams.paths, streams.values, 2)
    decoded.size.should eq(2)
    decoded.each { |row| row.entry_count.should eq(0) }

    no_rows = CrystalClick::ObjectSharedMapCodec.encode([] of CrystalClick::ObjectSharedMapRow)
    no_rows.sizes.should be_empty
    no_rows.paths.should be_empty
    no_rows.values.should be_empty
    CrystalClick::ObjectSharedMapCodec.decode(Bytes.empty, Bytes.empty, Bytes.empty, 0).should be_empty

    one_empty_row = [CrystalClick::ObjectSharedMapRow.new([] of CrystalClick::ObjectSharedMapEntry)] of CrystalClick::ObjectSharedMapRow
    depth_zero = w118_limits(max_depth: 0, max_nodes: 1, max_elements: 1, max_bytes: 8)
    depth_zero_streams = CrystalClick::ObjectSharedMapCodec.encode(one_empty_row, depth_zero)
    depth_zero_streams.sizes.should eq(w118_sizes([0_u64] of UInt64))
    CrystalClick::ObjectSharedMapCodec.decode(
      depth_zero_streams.sizes,
      depth_zero_streams.paths,
      depth_zero_streams.values,
      1,
      depth_zero
    ).size.should eq(1)
  end

  it "applies max depth inside each envelope, not to outer rows or entries" do
    bool_value = CrystalClick::BinaryValue.bool(true)
    bool_rows = [
      CrystalClick::ObjectSharedMapRow.new([
        w118_entry(Bytes[0x62_u8], bool_value),
      ] of CrystalClick::ObjectSharedMapEntry),
    ] of CrystalClick::ObjectSharedMapRow
    bool_wire = {
      w118_sizes([1_u64] of UInt64),
      w118_frame_lane([Bytes[0x62_u8]] of Bytes),
      w118_frame_lane([Bytes[0x2d_u8, 0x01_u8]] of Bytes),
    }
    bool_depth_one = w118_limits(max_depth: 1, max_nodes: 4, max_elements: 2, max_bytes: 13)
    CrystalClick::ObjectSharedMapCodec.encode(bool_rows, bool_depth_one).values.should eq(bool_wire[2])
    CrystalClick::ObjectSharedMapCodec.decode(
      bool_wire[0], bool_wire[1], bool_wire[2], 1, bool_depth_one
    )[0].entry_at(0).value.as_bool.should be_true
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(
        bool_wire[0], bool_wire[1], bool_wire[2], 1,
        w118_limits(max_depth: 0, max_nodes: 4, max_elements: 2, max_bytes: 13)
      )
    end

    array_type = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt8"))
    empty_array = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
    array_rows = [
      CrystalClick::ObjectSharedMapRow.new([
        w118_entry(Bytes[0x61_u8], empty_array),
      ] of CrystalClick::ObjectSharedMapEntry),
    ] of CrystalClick::ObjectSharedMapRow
    array_wire = {
      w118_sizes([1_u64] of UInt64),
      w118_frame_lane([Bytes[0x61_u8]] of Bytes),
      w118_frame_lane([Bytes[0x1e_u8, 0x01_u8, 0x00_u8]] of Bytes),
    }
    array_depth_two = w118_limits(max_depth: 2, max_nodes: 5, max_elements: 3, max_bytes: 14)
    CrystalClick::ObjectSharedMapCodec.encode(array_rows, array_depth_two).values.should eq(array_wire[2])
    CrystalClick::ObjectSharedMapCodec.decode(
      array_wire[0], array_wire[1], array_wire[2], 1, array_depth_two
    )[0].entry_at(0).value.elements.should be_empty
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(
        array_wire[0], array_wire[1], array_wire[2], 1,
        w118_limits(max_depth: 1, max_nodes: 5, max_elements: 3, max_bytes: 14)
      )
    end
  end

  it "enforces raw-byte sorted unique row paths and copies entry, row, decoded, and stream storage" do
    value = CrystalClick::BinaryValue.uint64(9_u64)
    source_path = Bytes[0x61_u8, 0x00_u8, 0xff_u8]
    entry = w118_entry(source_path, value)
    source_path[0] = 0x7a_u8
    entry.path_byte_at(0).should eq(0x61_u8)
    exposed_path = entry.path
    exposed_path[0] = 0x78_u8
    entry.path_byte_at(0).should eq(0x61_u8)

    entries = [
      entry,
      w118_entry(Bytes[0xff_u8], value),
    ] of CrystalClick::ObjectSharedMapEntry
    row = CrystalClick::ObjectSharedMapRow.new(entries)
    entries.clear
    row.entry_count.should eq(2)
    exposed_entries = row.entries
    exposed_entries.clear
    row.entry_count.should eq(2)
    row.entry_at(0).path.should eq(Bytes[0x61_u8, 0x00_u8, 0xff_u8])

    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedMapRow.new([
        w118_entry(Bytes[0x62_u8], value),
        w118_entry(Bytes[0x61_u8], value),
      ] of CrystalClick::ObjectSharedMapEntry)
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedMapRow.new([
        w118_entry(Bytes[0x61_u8], value),
        w118_entry(Bytes[0x61_u8], value),
      ] of CrystalClick::ObjectSharedMapEntry)
    end

    authored = w118_authored_wire
    source_sizes = w118_copy(authored[0])
    source_paths = w118_copy(authored[1])
    source_values = w118_copy(authored[2])
    decoded = CrystalClick::ObjectSharedMapCodec.decode(source_sizes, source_paths, source_values, 4)
    source_sizes[0] = 0xff_u8
    source_paths[0] = 0xff_u8
    source_values[0] = 0xff_u8
    decoded[0].entry_at(0).path.should eq(Bytes[0x61_u8, 0x00_u8, 0xff_u8])
    decoded[0].entry_at(0).value.type.name.should eq("Array(Nullable(String))")
    decoded[0].entry_at(0).value.elements.should be_empty

    streams = CrystalClick::ObjectSharedMapCodec.encode(w118_authored_rows)
    saved_sizes = w118_copy(streams.sizes)
    saved_paths = w118_copy(streams.paths)
    saved_values = w118_copy(streams.values)
    streams.sizes[0] = 0xff_u8
    streams.paths[0] = 0xff_u8
    streams.values[0] = 0xff_u8
    streams.sizes.should eq(saved_sizes)
    streams.paths.should eq(saved_paths)
    streams.values.should eq(saved_values)
  end

  it "applies exact combined node, element, and wire-byte budgets across envelopes" do
    wire = w118_budget_wire
    rows = w118_budget_rows
    # Two rows + two entries + two type/scalar visits per UInt8 envelope = 8 nodes.
    # Row and entry edges contribute 4 elements; the physical lanes total 26 bytes.
    exact = w118_limits(max_nodes: 8, max_elements: 4, max_bytes: 26)
    decoded = CrystalClick::ObjectSharedMapCodec.decode(wire[0], wire[1], wire[2], 2, exact)
    decoded.size.should eq(2)
    encoded = CrystalClick::ObjectSharedMapCodec.encode(rows, exact)
    encoded.sizes.should eq(wire[0])
    encoded.paths.should eq(wire[1])
    encoded.values.should eq(wire[2])

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(wire[0], wire[1], wire[2], 2, w118_limits(max_nodes: 7, max_elements: 4, max_bytes: 26))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(wire[0], wire[1], wire[2], 2, w118_limits(max_nodes: 8, max_elements: 3, max_bytes: 26))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(wire[0], wire[1], wire[2], 2, w118_limits(max_nodes: 8, max_elements: 4, max_bytes: 25))
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedMapCodec.encode(rows, w118_limits(max_nodes: 7, max_elements: 4, max_bytes: 26))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedMapCodec.encode(rows, w118_limits(max_nodes: 8, max_elements: 3, max_bytes: 26))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedMapCodec.encode(rows, w118_limits(max_nodes: 8, max_elements: 4, max_bytes: 25))
    end
  end

  it "shares recursive node and element budgets across two nested envelopes" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
    array_type = CrystalClick::BinaryDataType.array(nullable_uint8)
    first_value = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.nullable(
        nullable_uint8,
        CrystalClick::BinaryValue.fixed(uint8, Bytes[0x07_u8])
      ),
    ] of CrystalClick::BinaryValue)
    second_value = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.nullable(
        nullable_uint8,
        CrystalClick::BinaryValue.fixed(uint8, Bytes[0x08_u8])
      ),
    ] of CrystalClick::BinaryValue)
    rows = [
      CrystalClick::ObjectSharedMapRow.new([
        w118_entry(Bytes[0x61_u8], first_value),
      ] of CrystalClick::ObjectSharedMapEntry),
      CrystalClick::ObjectSharedMapRow.new([
        w118_entry(Bytes[0x62_u8], second_value),
      ] of CrystalClick::ObjectSharedMapEntry),
    ] of CrystalClick::ObjectSharedMapRow
    wire = {
      w118_sizes([1_u64, 1_u64] of UInt64),
      w118_frame_lane([Bytes[0x61_u8], Bytes[0x62_u8]] of Bytes),
      w118_frame_lane([
        Bytes[0x1e_u8, 0x23_u8, 0x01_u8, 0x01_u8, 0x00_u8, 0x07_u8],
        Bytes[0x1e_u8, 0x23_u8, 0x01_u8, 0x01_u8, 0x00_u8, 0x08_u8],
      ] of Bytes),
    }
    # Outer nodes/edges are 4/4. Each envelope contributes 3 descriptor + 3
    # scalar nodes, and 2 descriptor + 2 container edges: exact totals 16/12.
    exact = w118_limits(max_depth: 3, max_nodes: 16, max_elements: 12, max_bytes: 34)
    decoded = CrystalClick::ObjectSharedMapCodec.decode(wire[0], wire[1], wire[2], 2, exact)
    decoded[0].entry_at(0).value.elements[0].child_at(0).bytes.should eq(Bytes[0x07_u8])
    decoded[1].entry_at(0).value.elements[0].child_at(0).bytes.should eq(Bytes[0x08_u8])
    encoded = CrystalClick::ObjectSharedMapCodec.encode(rows, exact)
    encoded.sizes.should eq(wire[0])
    encoded.paths.should eq(wire[1])
    encoded.values.should eq(wire[2])

    # The known outer lower bound is only 2 + 3*2 = 8 nodes and 2 + 2 = 4
    # edges, so both preflights pass. Only aggregate recursive accounting
    # distinguishes these exact-minus-one limits from per-envelope resets.
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(
        wire[0], wire[1], wire[2], 2,
        w118_limits(max_depth: 3, max_nodes: 15, max_elements: 12, max_bytes: 34)
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(
        wire[0], wire[1], wire[2], 2,
        w118_limits(max_depth: 3, max_nodes: 16, max_elements: 11, max_bytes: 34)
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedMapCodec.encode(
        rows,
        w118_limits(max_depth: 3, max_nodes: 15, max_elements: 12, max_bytes: 34)
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedMapCodec.encode(
        rows,
        w118_limits(max_depth: 3, max_nodes: 16, max_elements: 11, max_bytes: 34)
      )
    end
  end

  it "rejects every truncation, trailing bytes, count mismatch, and noncanonical framing in each lane" do
    sizes = w118_sizes([1_u64] of UInt64)
    paths = w118_frame_lane([Bytes[0x61_u8]] of Bytes)
    values = w118_frame_lane([Bytes[0x01_u8, 0x01_u8]] of Bytes)

    (0...sizes.size).each do |length|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectSharedMapCodec.decode(sizes[0, length], paths, values, 1)
      end
    end
    (0...paths.size).each do |length|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectSharedMapCodec.decode(sizes, paths[0, length], values, 1)
      end
    end
    (0...values.size).each do |length|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectSharedMapCodec.decode(sizes, paths, values[0, length], 1)
      end
    end

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(w118_concat([sizes, w118_u64_le(0_u64)] of Bytes), paths, values, 1)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(sizes, w118_concat([paths, Bytes[0x00_u8]] of Bytes), values, 1)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(sizes, paths, w118_concat([values, Bytes[0x00_u8]] of Bytes), 1)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(sizes, Bytes.empty, values, 1)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(sizes, paths, Bytes.empty, 1)
    end

    # The outer path/value String framing is canonical VarUInt. W117 then
    # applies the same strict profile inside a nested String value envelope.
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(sizes, Bytes[0x81_u8, 0x00_u8, 0x61_u8], values, 1)
    end
    noncanonical_string_envelope = w118_frame_lane([Bytes[0x15_u8, 0x81_u8, 0x00_u8, 0x61_u8]] of Bytes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(sizes, paths, noncanonical_string_envelope, 1)
    end
    trailing_envelope = w118_frame_lane([Bytes[0x01_u8, 0x01_u8, 0x00_u8]] of Bytes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(sizes, paths, trailing_envelope, 1)
    end
  end

  it "decodes only raw-byte ascending unique paths, including high-bit and prefix order" do
    sizes = w118_sizes([3_u64] of UInt64)
    paths = w118_frame_lane([
      Bytes[0x7f_u8],
      Bytes[0x80_u8],
      Bytes[0x80_u8, 0x00_u8],
    ] of Bytes)
    values = w118_frame_lane([
      Bytes[0x01_u8, 0x01_u8],
      Bytes[0x01_u8, 0x02_u8],
      Bytes[0x01_u8, 0x03_u8],
    ] of Bytes)
    decoded = CrystalClick::ObjectSharedMapCodec.decode(sizes, paths, values, 1)
    decoded[0].entry_at(0).path.should eq(Bytes[0x7f_u8])
    decoded[0].entry_at(1).path.should eq(Bytes[0x80_u8])
    decoded[0].entry_at(2).path.should eq(Bytes[0x80_u8, 0x00_u8])
    encoded = CrystalClick::ObjectSharedMapCodec.encode(decoded)
    encoded.paths.should eq(paths)

    duplicate_paths = w118_frame_lane([Bytes[0x61_u8], Bytes[0x61_u8]] of Bytes)
    duplicate_values = w118_frame_lane([Bytes[0x01_u8, 0x01_u8], Bytes[0x01_u8, 0x02_u8]] of Bytes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(
        w118_sizes([2_u64] of UInt64), duplicate_paths, duplicate_values, 1
      )
    end

    descending_paths = w118_frame_lane([Bytes[0x80_u8], Bytes[0x7f_u8]] of Bytes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(
        w118_sizes([2_u64] of UInt64), descending_paths, duplicate_values, 1
      )
    end
  end

  it "preserves root and typed Nullable NULL as distinct supported values and refuses unsupported envelopes" do
    sizes = w118_sizes([1_u64] of UInt64)
    paths = w118_frame_lane([Bytes[0x6e_u8]] of Bytes)
    root_null_values = w118_frame_lane([Bytes[0x00_u8]] of Bytes)
    root_null = CrystalClick::ObjectSharedMapCodec.decode(sizes, paths, root_null_values, 1)
    root_null[0].entry_at(0).value.type.name.should eq("Nothing")
    root_null[0].entry_at(0).value.is_null?.should be_true
    CrystalClick::ObjectSharedMapCodec.encode(root_null).values.should eq(root_null_values)

    typed_nullable_null_values = w118_frame_lane([Bytes[0x23_u8, 0x15_u8, 0x01_u8]] of Bytes)
    typed_nullable_null = CrystalClick::ObjectSharedMapCodec.decode(sizes, paths, typed_nullable_null_values, 1)
    typed_nullable_null[0].entry_at(0).value.type.name.should eq("Nullable(String)")
    typed_nullable_null[0].entry_at(0).value.is_null?.should be_true
    CrystalClick::ObjectSharedMapCodec.encode(typed_nullable_null).values.should eq(typed_nullable_null_values)

    # W119 admits Time64, so an absent scale is corruption rather than an
    # unsupported type. LowCardinality remains outside the envelope profile.
    truncated_time64_values = w118_frame_lane([Bytes[0x34_u8]] of Bytes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(sizes, paths, truncated_time64_values, 1)
    end
    unsupported_values = w118_frame_lane([Bytes[0x26_u8, 0x01_u8]] of Bytes)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedMapCodec.decode(sizes, paths, unsupported_values, 1)
    end
  end

  it "preflights row, node, element, and wire cardinalities before declared-count allocation" do
    huge_row_count = Int32::MAX.to_i
    wide_row_limits = w118_limits(
      max_nodes: huge_row_count,
      max_elements: huge_row_count,
      max_bytes: 0
    )
    GC.stats
    before_row_bytes = GC.stats.total_bytes
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(Bytes.empty, Bytes.empty, Bytes.empty, huge_row_count, wide_row_limits)
    end
    (GC.stats.total_bytes - before_row_bytes).should be < 2_u64 * 1024_u64 * 1024_u64

    huge_entries = 1_000_000_u64
    huge_sizes = w118_sizes([huge_entries] of UInt64)
    node_limited = w118_limits(max_nodes: 32, max_elements: 1_000_001, max_bytes: 8)
    GC.stats
    before_node_bytes = GC.stats.total_bytes
    node_error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(huge_sizes, Bytes.empty, Bytes.empty, 1, node_limited)
    end
    node_error.to_s.should contain("node")
    (GC.stats.total_bytes - before_node_bytes).should be < 2_u64 * 1024_u64 * 1024_u64

    # Raised logical limits allow the minimum row+3*entry nodes and row+entry
    # edges; the physical lanes still cannot contain the declared entries.
    # This defeats a node-budget-only preflight that reserves a million entries.
    wire_limited = w118_limits(
      max_nodes: 3_000_001,
      max_elements: 1_000_001,
      max_bytes: 8
    )
    GC.stats
    before_wire_bytes = GC.stats.total_bytes
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(huge_sizes, Bytes.empty, Bytes.empty, 1, wire_limited)
    end
    (GC.stats.total_bytes - before_wire_bytes).should be < 2_u64 * 1024_u64 * 1024_u64

    overflow_sizes = w118_sizes([UInt64::MAX] of UInt64)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(
        overflow_sizes,
        Bytes.empty,
        Bytes.empty,
        1,
        w118_limits(max_nodes: Int64::MAX, max_elements: Int64::MAX, max_bytes: 8)
      )
    end
  end
end
