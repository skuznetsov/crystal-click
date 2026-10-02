require "spec"
require "../src/crystal_click"
require "../scripts/w116_json_physical_vectors"

private W116_SPEC_PROFILES = {
  "dynamic_paths",
  "dynamic_shared_only",
  "typed_mixed",
}

private W116_SPEC_DYNAMIC_PATHS_STREAMS = [
  "pk",
  "payload.object_structure",
  "payload.a.dynamic_structure",
  "payload.a.variant_discr",
  "payload.arr.dynamic_structure",
  "payload.arr.variant_discr",
  "payload.dot%2Ekey.dynamic_structure",
  "payload.dot%2Ekey.variant_discr",
  "payload.flag.dynamic_structure",
  "payload.flag.variant_discr",
  "payload.nest%2Eleaf.dynamic_structure",
  "payload.nest%2Eleaf.variant_discr",
  "payload.s.dynamic_structure",
  "payload.s.variant_discr",
  "payload.a.Int64",
  "payload.a.SharedVariant.size",
  "payload.a.SharedVariant",
  "payload.arr.Array%28Nullable%28Int64%29%29.size0",
  "payload.arr.Array%28Nullable%28Int64%29%29.null",
  "payload.arr.Array%28Nullable%28Int64%29%29",
  "payload.arr.SharedVariant.size",
  "payload.arr.SharedVariant",
  "payload.dot%2Ekey.Int64",
  "payload.dot%2Ekey.SharedVariant.size",
  "payload.dot%2Ekey.SharedVariant",
  "payload.flag.Bool",
  "payload.flag.SharedVariant.size",
  "payload.flag.SharedVariant",
  "payload.nest%2Eleaf.SharedVariant.size",
  "payload.nest%2Eleaf.SharedVariant",
  "payload.nest%2Eleaf.String.size",
  "payload.nest%2Eleaf.String",
  "payload.s.Bool",
  "payload.s.Int64",
  "payload.s.SharedVariant.size",
  "payload.s.SharedVariant",
  "payload.s.String.size",
  "payload.s.String",
  "payload.object_shared_data.size0",
  "payload.object_shared_data%2Epaths",
  "payload.object_shared_data%2Evalues",
]

private W116_SPEC_SHARED_ONLY_STREAMS = [
  "pk",
  "payload.object_structure",
  "payload.object_shared_data.size0",
  "payload.object_shared_data%2Epaths",
  "payload.object_shared_data%2Evalues",
]

private W116_SPEC_TYPED_MIXED_STREAMS = [
  "pk",
  "payload.object_structure",
  "payload.s.dynamic_structure",
  "payload.s.variant_discr",
  "payload.a",
  "payload.s.SharedVariant.size",
  "payload.s.SharedVariant",
  "payload.s.String.size",
  "payload.s.String",
  "payload.object_shared_data.size0",
  "payload.object_shared_data%2Epaths",
  "payload.object_shared_data%2Evalues",
]

private def w116_spec_expected_pk_raw : Bytes
  bytes = Bytes.new(64)
  8.times do |row|
    value = (row + 1).to_u64
    8.times do |byte_index|
      bytes[row * 8 + byte_index] = (value >> (byte_index * 8)).to_u8
    end
  end
  bytes
end

private def w116_spec_write_u64le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w116_spec_expected_pk_mark_raw : Bytes
  io = IO::Memory.new
  [
    {0_u64, 0_u64, 2_u64},
    {0_u64, 16_u64, 2_u64},
    {0_u64, 32_u64, 2_u64},
    {0_u64, 48_u64, 2_u64},
    {0_u64, 64_u64, 0_u64},
  ].each do |(compressed_offset, decompressed_offset, rows)|
    w116_spec_write_u64le(io, compressed_offset)
    w116_spec_write_u64le(io, decompressed_offset)
    w116_spec_write_u64le(io, rows)
  end
  io.to_slice
end

private def w116_spec_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w116_spec_write_string_binary(io : IO, value : String) : Nil
  bytes = value.to_slice
  w116_spec_write_varuint(io, bytes.size.to_u64)
  io.write(bytes)
end

private def w116_spec_object_structure(
  dynamic_stats : Array(Tuple(String, UInt64)),
  shared_stats : Array(Tuple(String, UInt64)),
) : Bytes
  io = IO::Memory.new
  # Object V3: version, sorted dynamic path roster, MAP shared-data profile,
  # stats-present flag, then dynamic and shared path-frequency statistics.
  w116_spec_write_u64le(io, 4_u64)
  w116_spec_write_varuint(io, dynamic_stats.size.to_u64)
  dynamic_stats.each { |(path, _)| w116_spec_write_string_binary(io, path) }
  w116_spec_write_varuint(io, 0_u64)
  io.write_byte(1_u8)
  dynamic_stats.each { |(_, count)| w116_spec_write_varuint(io, count) }
  w116_spec_write_varuint(io, shared_stats.size.to_u64)
  shared_stats.each do |(path, count)|
    w116_spec_write_string_binary(io, path)
    w116_spec_write_varuint(io, count)
  end
  io.to_slice
end

private def w116_spec_splice(raw : Bytes, offset : Int32, remove_count : Int32, replacement : Bytes) : Bytes
  io = IO::Memory.new
  io.write(raw[0, offset])
  io.write(replacement)
  tail_offset = offset + remove_count
  io.write(raw[tail_offset, raw.size - tail_offset])
  io.to_slice
end

private def w116_spec_typed_mixed_dynamic_shared_stats(entries : Array(Tuple(String, UInt64))) : Bytes
  io = IO::Memory.new
  # Independent Dynamic V3 header: version 4, one String descriptor (0x15),
  # stats present, SharedVariant count 2, String count 4, two shared types.
  io.write(Bytes[4_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x15_u8, 1_u8, 2_u8, 4_u8, 2_u8])
  entries.each do |(name, count)|
    w116_spec_write_string_binary(io, name)
    w116_spec_write_varuint(io, count)
  end
  io.to_slice
end

describe "W116 independent JSON physical vectors" do
  it "pins each independent profile schema and effective JSON options" do
    W116JsonPhysicalVectors.expected_schema("dynamic_paths").should eq(
      "pk UInt64\npayload JSON(max_dynamic_types=8, max_dynamic_paths=16)\n"
    )
    W116JsonPhysicalVectors.expected_schema("dynamic_shared_only").should eq(
      "pk UInt64\npayload JSON(max_dynamic_types=8, max_dynamic_paths=0)\n"
    )
    W116JsonPhysicalVectors.expected_schema("typed_mixed").should eq(
      "pk UInt64\npayload JSON(max_dynamic_types=1, max_dynamic_paths=1, a UInt64)\n"
    )

    W116JsonPhysicalVectors.expected_columns_text("dynamic_paths").should eq(
      "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` JSON(max_dynamic_types=8, max_dynamic_paths=16)\n"
    )
    W116JsonPhysicalVectors.expected_columns_text("dynamic_shared_only").should eq(
      "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` JSON(max_dynamic_types=8, max_dynamic_paths=0)\n"
    )
    W116JsonPhysicalVectors.expected_columns_text("typed_mixed").should eq(
      "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` JSON(max_dynamic_types=1, max_dynamic_paths=1, a UInt64)\n"
    )

    W116JsonPhysicalVectors.expected_options("dynamic_paths").should eq({
      "max_dynamic_paths" => "16",
      "max_dynamic_types" => "8",
    })
    W116JsonPhysicalVectors.expected_options("dynamic_shared_only").should eq({
      "max_dynamic_paths" => "0",
      "max_dynamic_types" => "8",
    })
    W116JsonPhysicalVectors.expected_options("typed_mixed").should eq({
      "max_dynamic_paths" => "1",
      "max_dynamic_types" => "1",
    })

    disk_schema = W116JsonPhysicalVectors.expected_columns_text("typed_mixed")
    W116JsonPhysicalVectors.assert_columns_text("typed_mixed", disk_schema)
    changed_schema = disk_schema.sub("UInt64", "UInt32")
    changed_schema.bytesize.should eq(disk_schema.bytesize)
    error = expect_raises(W116JsonPhysicalMismatch) do
      W116JsonPhysicalVectors.assert_columns_text("typed_mixed", changed_schema)
    end
    error.message.should eq("W116 JSON physical mismatch: typed_mixed columns.txt schema differs")
  end

  it "pins all three independently modeled inventories including escaped substream names" do
    W116JsonPhysicalVectors.expected_stream_names("dynamic_paths").should eq(W116_SPEC_DYNAMIC_PATHS_STREAMS)
    W116JsonPhysicalVectors.expected_stream_names("dynamic_shared_only").should eq(W116_SPEC_SHARED_ONLY_STREAMS)
    W116JsonPhysicalVectors.expected_stream_names("typed_mixed").should eq(W116_SPEC_TYPED_MIXED_STREAMS)
    W116JsonPhysicalVectors.expected_files("dynamic_paths").size.should eq(91)
    W116JsonPhysicalVectors.expected_files("dynamic_shared_only").size.should eq(19)
    W116JsonPhysicalVectors.expected_files("typed_mixed").size.should eq(33)
  end

  it "distinguishes nominal empty and populated shared Array element types" do
    W116JsonPhysicalVectors.expected_type_descriptors("dynamic_paths").should eq({
      "payload.a"           => ["Int64"],
      "payload.arr"         => ["Array(Nullable(Int64))"],
      "payload.dot%2Ekey"   => ["Int64"],
      "payload.flag"        => ["Bool"],
      "payload.nest%2Eleaf" => ["String"],
      "payload.s"           => ["Bool", "Int64", "String"],
    })
    W116JsonPhysicalVectors.expected_type_descriptors("dynamic_shared_only").should eq({} of String => Array(String))
    W116JsonPhysicalVectors.expected_type_descriptors("typed_mixed").should eq({
      "payload.s" => ["String"],
    })

    # The literal input has an empty array at key 2 and populated Int64 arrays
    # at keys 1, 3, 5, 7, and 8. Their inner Dynamic descriptors are distinct.
    W116JsonPhysicalVectors.expected_shared_value_types("dynamic_paths").should be_empty
    W116JsonPhysicalVectors.expected_shared_value_types("dynamic_shared_only").should eq({
      "a"         => ["Int64"],
      "arr"       => ["Array(Nullable(Int64))", "Array(Nullable(String))"],
      "dot.key"   => ["Int64"],
      "flag"      => ["Bool"],
      "nest.leaf" => ["String"],
      "s"         => ["Bool", "Int64", "String"],
    })
    W116JsonPhysicalVectors.expected_shared_value_types("typed_mixed").should eq({
      "arr"       => ["Array(Nullable(Int64))", "Array(Nullable(String))"],
      "dot.key"   => ["Int64"],
      "flag"      => ["Bool"],
      "nest.leaf" => ["String"],
    })
    W116JsonPhysicalVectors.expected_type_descriptors("dynamic_paths")["payload.arr"].should eq(
      ["Array(Nullable(Int64))"]
    )
  end

  it "treats shared-path statistics as an unordered map and rejects duplicate or trailing entries" do
    expected = W116JsonPhysicalVectors.expected_object_structure("dynamic_shared_only")
    expected.should eq({
      "a"         => 6_u64,
      "arr"       => 6_u64,
      "dot.key"   => 7_u64,
      "flag"      => 5_u64,
      "nest.leaf" => 5_u64,
      "s"         => 6_u64,
    })
    dynamic_stats = [] of Tuple(String, UInt64)
    shared_stats = [
      {"s", 6_u64},
      {"nest.leaf", 5_u64},
      {"flag", 5_u64},
      {"dot.key", 7_u64},
      {"arr", 6_u64},
      {"a", 6_u64},
    ]
    raw = w116_spec_object_structure(dynamic_stats, shared_stats)
    W116JsonPhysicalVectors.assert_object_structure("dynamic_shared_only", raw)
    W116JsonPhysicalVectors.assert_object_structure(
      "dynamic_shared_only",
      w116_spec_object_structure(dynamic_stats, shared_stats.reverse)
    )

    duplicate = w116_spec_object_structure(dynamic_stats, shared_stats + [shared_stats.first])
    duplicate_error = expect_raises(W116JsonPhysicalMismatch) do
      W116JsonPhysicalVectors.assert_object_structure("dynamic_shared_only", duplicate)
    end
    duplicate_error.message.should eq("W116 JSON physical mismatch: dynamic_shared_only object_structure duplicate shared path statistic")

    trailing = raw + Bytes[0_u8]
    trailing_error = expect_raises(W116JsonPhysicalMismatch) do
      W116JsonPhysicalVectors.assert_object_structure("dynamic_shared_only", trailing)
    end
    trailing_error.message.should eq("W116 JSON physical mismatch: dynamic_shared_only object_structure trailing bytes")
  end

  it "accepts stock structure bytes but rejects noncanonical and truncated VarUInts" do
    valid = W116JsonPhysicalVectors.expected_raw_stream("dynamic_shared_only", "payload.object_structure")
    W116JsonPhysicalVectors.assert_object_structure("dynamic_shared_only", valid)

    # The dynamic path count is zero in this profile. Replacing its canonical
    # one-byte zero with a two-byte zero leaves the rest of the valid structure
    # aligned for a permissive decoder, so this specifically detects overlong
    # VarUInt acceptance.
    nonminimal = w116_spec_splice(valid, 8, 1, Bytes[0x80_u8, 0_u8])
    nonminimal_error = expect_raises(W116JsonPhysicalMismatch) do
      W116JsonPhysicalVectors.assert_object_structure("dynamic_shared_only", nonminimal)
    end
    nonminimal_error.message.should eq("W116 JSON physical mismatch: dynamic_shared_only object_structure differs")

    truncated = Bytes.new(9)
    8.times { |index| truncated[index] = valid[index] }
    truncated[8] = 0x80_u8
    truncated_error = expect_raises(W116JsonPhysicalMismatch) do
      W116JsonPhysicalVectors.assert_object_structure("dynamic_shared_only", truncated)
    end
    truncated_error.message.should eq("W116 JSON physical mismatch: dynamic_shared_only object_structure differs")

    tenth_byte_high_bits = w116_spec_splice(valid, 8, 1,
      Bytes[0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x02_u8])
    high_bits_error = expect_raises(W116JsonPhysicalMismatch) do
      W116JsonPhysicalVectors.assert_object_structure("dynamic_shared_only", tenth_byte_high_bits)
    end
    high_bits_error.message.should eq("W116 JSON physical mismatch: dynamic_shared_only object_structure differs")

    tenth_byte_continuation = w116_spec_splice(valid, 8, 1,
      Bytes[0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8])
    continuation_error = expect_raises(W116JsonPhysicalMismatch) do
      W116JsonPhysicalVectors.assert_object_structure("dynamic_shared_only", tenth_byte_continuation)
    end
    continuation_error.message.should eq("W116 JSON physical mismatch: dynamic_shared_only object_structure differs")
  end

  it "compares typed Dynamic shared-type statistics as an unordered exact map" do
    logical = "payload.s.dynamic_structure"
    ordered = w116_spec_typed_mixed_dynamic_shared_stats([{"Bool", 1_u64}, {"Int64", 1_u64}])
    reversed = w116_spec_typed_mixed_dynamic_shared_stats([{"Int64", 1_u64}, {"Bool", 1_u64}])
    W116JsonPhysicalVectors.assert_stream_raw("typed_mixed", logical, ordered)
    W116JsonPhysicalVectors.assert_stream_raw("typed_mixed", logical, reversed)

    duplicate = w116_spec_typed_mixed_dynamic_shared_stats([{"Bool", 1_u64}, {"Bool", 1_u64}])
    duplicate_error = expect_raises(W116JsonPhysicalMismatch) do
      W116JsonPhysicalVectors.assert_stream_raw("typed_mixed", logical, duplicate)
    end
    duplicate_error.message.should eq("W116 JSON physical mismatch: typed_mixed stream payload.s.dynamic_structure raw payload differs")

    trailing = ordered + Bytes[0_u8]
    trailing_error = expect_raises(W116JsonPhysicalMismatch) do
      W116JsonPhysicalVectors.assert_stream_raw("typed_mixed", logical, trailing)
    end
    trailing_error.message.should eq("W116 JSON physical mismatch: typed_mixed stream payload.s.dynamic_structure raw payload differs")
  end

  it "keeps Object dynamic-path and shared-path cardinalities distinct" do
    W116JsonPhysicalVectors.expected_dynamic_path_statistics("dynamic_paths").should eq({
      "a"         => 6_u64,
      "arr"       => 6_u64,
      "dot.key"   => 7_u64,
      "flag"      => 5_u64,
      "nest.leaf" => 5_u64,
      "s"         => 6_u64,
    })
    W116JsonPhysicalVectors.expected_shared_path_statistics("dynamic_paths").should be_empty
    W116JsonPhysicalVectors.expected_dynamic_path_statistics("dynamic_shared_only").should be_empty
    W116JsonPhysicalVectors.expected_shared_path_statistics("dynamic_shared_only").should eq({
      "a"         => 6_u64,
      "arr"       => 6_u64,
      "dot.key"   => 7_u64,
      "flag"      => 5_u64,
      "nest.leaf" => 5_u64,
      "s"         => 6_u64,
    })
    W116JsonPhysicalVectors.expected_dynamic_path_statistics("typed_mixed").should eq({"s" => 6_u64})
    W116JsonPhysicalVectors.expected_shared_path_statistics("typed_mixed").should eq({
      "arr"       => 6_u64,
      "dot.key"   => 7_u64,
      "flag"      => 5_u64,
      "nest.leaf" => 5_u64,
    })
  end

  it "pins selected nonzero-origin mark rows and decompressed offsets" do
    W116JsonPhysicalVectors.expected_mark_rows("dynamic_paths", "payload.s.variant_discr").should eq([2_u64, 2_u64, 2_u64, 2_u64, 0_u64])
    W116JsonPhysicalVectors.expected_mark_rows("typed_mixed", "payload.s.variant_discr", first_mark: 1, mark_count: 2).should eq([2_u64, 2_u64])
    W116JsonPhysicalVectors.expected_mark_rows("typed_mixed", "payload.object_shared_data%2Evalues", first_mark: 1, mark_count: 2).should eq([2_u64, 2_u64])
    W116JsonPhysicalVectors.expected_mark_grid("typed_mixed", "payload.s.variant_discr", first_mark: 1, mark_count: 2).should eq([
      {0_u64, 11_u64, 2_u64},
      {0_u64, 15_u64, 2_u64},
    ])
  end

  it "places a singleton String after the implicit SharedVariant in global tag order" do
    W116JsonPhysicalVectors.expected_raw_stream("dynamic_paths", "payload.nest%2Eleaf.variant_discr").should eq(
      Bytes[1, 0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 2, 1, 255, 2, 0, 1, 255, 2, 1, 1]
    )
    W116JsonPhysicalVectors.expected_mark_grid("dynamic_paths", "payload.nest%2Eleaf.variant_discr").should eq(
      [{0_u64, 8_u64, 2_u64}, {0_u64, 11_u64, 2_u64}, {0_u64, 14_u64, 2_u64}, {0_u64, 18_u64, 2_u64}, {0_u64, 21_u64, 0_u64}]
    )
  end

  it "asserts primary-key payload bytes from the literal eight-row key sequence" do
    expected = w116_spec_expected_pk_raw
    W116JsonPhysicalVectors.expected_raw_stream("dynamic_paths", "pk").should eq(expected)
    W116JsonPhysicalVectors.assert_stream_raw("dynamic_paths", "pk", expected)

    changed = expected.dup
    changed[8] ^= 1_u8
    error = expect_raises(W116JsonPhysicalMismatch) do
      W116JsonPhysicalVectors.assert_stream_raw("dynamic_paths", "pk", changed)
    end
    error.message.should eq("W116 JSON physical mismatch: dynamic_paths stream pk raw payload differs")
  end

  it "checks literal primary-key marks and rejects a changed decompressed offset" do
    expected = w116_spec_expected_pk_mark_raw
    W116JsonPhysicalVectors.assert_mark_raw("dynamic_paths", "pk", expected)

    changed = expected.dup
    changed[8] ^= 1_u8
    error = expect_raises(W116JsonPhysicalMismatch) do
      W116JsonPhysicalVectors.assert_mark_raw("dynamic_paths", "pk", changed)
    end
    error.message.should eq("W116 JSON physical mismatch: dynamic_paths stream pk mark grid differs")
  end

  it "detects same-size discriminator and shared-value payload mutations" do
    discriminator = W116JsonPhysicalVectors.expected_raw_stream("typed_mixed", "payload.s.variant_discr")
    discriminator.size.should be > 8
    discriminator[0, 8].should eq(Bytes[1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8])
    W116JsonPhysicalVectors.assert_stream_raw("typed_mixed", "payload.s.variant_discr", discriminator)

    changed_discriminator = discriminator.dup
    changed_discriminator[8] ^= 1_u8
    discriminator_error = expect_raises(W116JsonPhysicalMismatch) do
      W116JsonPhysicalVectors.assert_stream_raw("typed_mixed", "payload.s.variant_discr", changed_discriminator)
    end
    discriminator_error.message.should eq("W116 JSON physical mismatch: typed_mixed stream payload.s.variant_discr raw payload differs")

    shared_values = W116JsonPhysicalVectors.expected_raw_stream("dynamic_shared_only", "payload.object_shared_data%2Evalues")
    W116JsonPhysicalVectors.assert_stream_raw("dynamic_shared_only", "payload.object_shared_data%2Evalues", shared_values)
    changed_shared_values = shared_values.dup
    changed_shared_values[0] ^= 1_u8
    shared_error = expect_raises(W116JsonPhysicalMismatch) do
      W116JsonPhysicalVectors.assert_stream_raw("dynamic_shared_only", "payload.object_shared_data%2Evalues", changed_shared_values)
    end
    shared_error.message.should eq("W116 JSON physical mismatch: dynamic_shared_only stream payload.object_shared_data%2Evalues raw payload differs")
  end

  it "rejects unknown profile labels without treating them as stock mismatches" do
    error = expect_raises(W116JsonPhysicalMismatch) do
      W116JsonPhysicalVectors.expected_stream_names("unknown")
    end
    error.message.should eq("W116 JSON physical mismatch: unknown profile: unknown")
  end
end
