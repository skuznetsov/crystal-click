require "./spec_helper"

def slab_vector_slice(values : Array(UInt64)) : Slice(UInt64)
  values.to_unsafe.to_slice(values.size)
end

def slab_vector_le_bytes(values : Array(UInt64)) : Bytes
  bytes = Bytes.new(values.size * 8)
  values.each_with_index do |value, index|
    8.times do |byte_index|
      bytes[index * 8 + byte_index] = ((value >> (byte_index * 8)) & 0xff_u64).to_u8
    end
  end
  bytes
end

def build_gc_slab_vector : CrystalClick::UInt64SlabVector
  source = Array(UInt64).new(65) { |index| (index.to_u64 &* 31_u64) ^ 0xa5a5_u64 }
  vector = CrystalClick::UInt64SlabVector.new(slab_shift: 4)
  vector.concat(slab_vector_slice(source))
  vector
end

def build_gc_byte_slab_vector : CrystalClick::UInt64SlabVector
  source = Array(UInt64).new(65) { |index| (index.to_u64 &* 31_u64) ^ 0xa5a5_u64 }
  vector = CrystalClick::UInt64SlabVector.new(slab_shift: 4)
  vector.concat_le_bytes(slab_vector_le_bytes(source))
  vector
end

describe "CrystalClick::UInt64SlabVector" do
  it "uses bounded defaults and validates its construction parameters" do
    vector = CrystalClick::UInt64SlabVector.new

    vector.slab_shift.should eq(12)
    vector.slab_size.should eq(1 << 12)
    vector.slab_mask.should eq(vector.slab_size - 1)
    vector.size.should eq(0)
    vector.capacity.should eq(0)
    vector.slab_count.should eq(0)
    vector.directory_capacity.should be >= 1024

    (4..20).each do |shift|
      configured = CrystalClick::UInt64SlabVector.new(slab_shift: shift, initial_directory_capacity: 1)
      configured.slab_shift.should eq(shift)
      configured.slab_size.should eq(1 << shift)
      configured.slab_mask.should eq((1 << shift) - 1)
      configured.directory_capacity.should be >= 1
    end

    [3, 21].each do |shift|
      expect_raises(ArgumentError) do
        CrystalClick::UInt64SlabVector.new(slab_shift: shift)
      end
    end

    [0, -1].each do |directory_capacity|
      expect_raises(ArgumentError) do
        CrystalClick::UInt64SlabVector.new(initial_directory_capacity: directory_capacity)
      end
    end
  end

  it "allocates slabs lazily and supports push and <<" do
    vector = CrystalClick::UInt64SlabVector.new(slab_shift: 4, initial_directory_capacity: 1)

    vector.size.should eq(0)
    vector.capacity.should eq(0)
    vector.slab_count.should eq(0)

    vector.push(11_u64)
    vector << 22_u64

    vector.size.should eq(2)
    vector.capacity.should eq(16)
    vector.slab_count.should eq(1)
    vector.to_a.should eq([11_u64, 22_u64])
  end

  it "keeps empty concat lazy and returns an independent owning array" do
    vector = CrystalClick::UInt64SlabVector.new(slab_shift: 4)

    vector.concat(Slice(UInt64).empty)
    vector.concat_le_bytes(Bytes.empty)

    vector.size.should eq(0)
    vector.capacity.should eq(0)
    vector.slab_count.should eq(0)
    vector.to_a.should eq([] of UInt64)

    values = [11_u64, 22_u64, 33_u64]
    vector.concat(slab_vector_slice(values))
    copy = vector.to_a
    copy[0] = UInt64::MAX

    vector.to_a.should eq(values)
    copy.should_not eq(vector.to_a)
  end

  it "rejects a negative-sized Slice before dereferencing it" do
    vector = CrystalClick::UInt64SlabVector.new(slab_shift: 4)
    malformed = Slice(UInt64).new(Pointer(UInt64).null, -1)

    expect_raises(ArgumentError) { vector.concat(malformed) }
  end

  it "concatenates a Slice and preserves order across slab boundaries" do
    values = Array(UInt64).new(34) { |index| (index.to_u64 &* 17_u64) ^ 0xfeed_u64 }
    vector = CrystalClick::UInt64SlabVector.new(slab_shift: 4)

    vector.concat(slab_vector_slice(values))

    vector.size.should eq(values.size)
    vector.slab_count.should eq(3)
    vector.capacity.should eq(48)
    vector[0].should eq(values[0])
    vector[15].should eq(values[15])
    vector[16].should eq(values[16])
    vector[31].should eq(values[31])
    vector[32].should eq(values[32])
    vector[33].should eq(values[33])
    vector.to_a.should eq(values)

    observed = [] of UInt64
    vector.each { |value| observed << value }
    observed.should eq(values)
  end

  it "concatenates owned little-endian bytes across slab boundaries" do
    values = Array(UInt64).new(34) { |index| (index.to_u64 &* 17_u64) ^ 0xfeed_u64 }
    aligned_bytes = slab_vector_le_bytes(values)
    storage = Bytes.new(aligned_bytes.size + 1)
    storage[1, aligned_bytes.size].copy_from(aligned_bytes)
    bytes = storage[1, aligned_bytes.size]
    vector = CrystalClick::UInt64SlabVector.new(slab_shift: 4)

    vector.concat_le_bytes(bytes)
    bytes.fill(0_u8)

    vector.to_a.should eq(values)
    vector.size.should eq(values.size)
    vector.slab_count.should eq(3)
  end

  it "rejects malformed byte alignment before mutating" do
    vector = CrystalClick::UInt64SlabVector.new(slab_shift: 4)
    vector << 11_u64
    before = vector.to_a
    before_size = vector.size
    before_capacity = vector.capacity
    before_slab_count = vector.slab_count

    expect_raises(ArgumentError) { vector.concat_le_bytes(Bytes.new(7)) }

    vector.to_a.should eq(before)
    vector.size.should eq(before_size)
    vector.capacity.should eq(before_capacity)
    vector.slab_count.should eq(before_slab_count)
  end

  it "uses an overlap-safe primitive for byte copies" do
    source = File.read(File.expand_path("../src/crystal_click/uint64_slab_vector.cr", __DIR__))
    slab_start = source.index("def concat_le_bytes").not_nil!
    slab_end = source.index("def []", slab_start).not_nil!
    byte_append = source[slab_start, slab_end - slab_start]

    byte_append.should contain("destination.move_from")
    byte_append.should_not contain("destination.copy_from")
  end

  it "checks indexes and yields non-empty read-only chunks including a partial tail" do
    values = (0_u64...34_u64).to_a
    vector = CrystalClick::UInt64SlabVector.new(slab_shift: 4)
    vector.concat(slab_vector_slice(values))

    expect_raises(CrystalClick::BoundsError) { vector[-1] }
    expect_raises(CrystalClick::BoundsError) { vector[vector.size] }

    chunks = [] of Array(UInt64)
    chunk_sizes = [] of Int32
    vector.each_chunk do |chunk|
      chunk.read_only?.should be_true
      chunk_sizes << chunk.size
      chunks << chunk.to_a
    end

    chunk_sizes.should eq([16, 16, 2])
    chunk_sizes.all? { |size| size > 0 }.should be_true
    chunks.flatten.should eq(values)
  end

  it "retains copied values after GC.collect" do
    expected = Array(UInt64).new(65) { |index| (index.to_u64 &* 31_u64) ^ 0xa5a5_u64 }
    vector = build_gc_slab_vector

    GC.collect

    vector.to_a.should eq(expected)
  end

  it "retains copied byte values after the source is gone and GC.collect" do
    expected = Array(UInt64).new(65) { |index| (index.to_u64 &* 31_u64) ^ 0xa5a5_u64 }
    vector = build_gc_byte_slab_vector

    GC.collect

    vector.to_a.should eq(expected)
  end

  it "grows beyond 1024 descriptors without losing exact sample values" do
    slab_size = 1 << 4
    value_count = 1025 * slab_size + 1
    values = Array(UInt64).new(value_count) { |index| index.to_u64 }
    vector = CrystalClick::UInt64SlabVector.new(slab_shift: 4)
    initial_directory_capacity = vector.directory_capacity

    initial_directory_capacity.should be >= 1024
    vector.concat(slab_vector_slice(values))

    vector.size.should eq(value_count)
    vector.slab_count.should eq(1026)
    vector.directory_capacity.should be > initial_directory_capacity
    [0, 15, 16, 16 * 1024, 16 * 1025, value_count - 1].each do |index|
      vector[index].should eq(values[index])
    end
    vector.to_a.should eq(values)
  end
end
