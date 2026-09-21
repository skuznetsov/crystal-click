require "./spec_helper"

PIPELINE_LZ4_FIXTURE   = File.expand_path("../test/fixtures/public/wide_u64_lz4/part", __DIR__)
PIPELINE_ZSTD_FIXTURE  = File.expand_path("../test/fixtures/public/wide_u64_zstd_cmrk2/part", __DIR__)
PIPELINE_DELTA_FIXTURE = File.expand_path("../test/fixtures/public/wide_u64_delta_zstd/part", __DIR__)
PIPELINE_ROWS          = 200_000_u64

def with_uint64_pipeline_root(&)
  root = File.tempname("crystal-click-uint64-pipeline-spec")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

def copy_uint64_pipeline_part(root : String, name : String, source : String = PIPELINE_LZ4_FIXTURE) : String
  path = File.join(root, name)
  FileUtils.cp_r(source, path)
  path
end

def pipeline_u32(bytes : Bytes, offset : Int) : UInt32
  bytes[offset].to_u32 |
    (bytes[offset + 1].to_u32 << 8) |
    (bytes[offset + 2].to_u32 << 16) |
    (bytes[offset + 3].to_u32 << 24)
end

def pipeline_frame_offsets(bytes : Bytes) : Array(Int32)
  offsets = Array(Int32).new
  offset = 0
  while offset < bytes.size
    raise "truncated test frame header" if bytes.size - offset < 25
    offsets << offset
    compressed_size = pipeline_u32(bytes, offset + 17).to_i
    offset += 16 + compressed_size
  end
  raise "trailing test frame bytes" unless offset == bytes.size
  offsets
end

describe "UInt64 execution pipeline" do
  it "aggregates all rows through the no-predicate overload" do
    with_uint64_pipeline_root do |root|
      copy_uint64_pipeline_part(root, "part_0_0_1_0")
      source = CrystalClick::WidePartSet.open(root, "value")

      [1, 73, 1_025].each do |scratch_size|
        result = source.aggregate_uint64(Slice(UInt64).new(scratch_size))

        result.count.should eq(PIPELINE_ROWS)
        result.sum.should eq(19_999_900_000_u64)
        result.min.should eq(0_u64)
        result.max.should eq(199_999_u64)
        result.empty?.should be_false
      end
    end
  end

  it "evaluates a scalar predicate once in deterministic source order" do
    with_uint64_pipeline_root do |root|
      copy_uint64_pipeline_part(root, "z-1_0_1_0", PIPELINE_LZ4_FIXTURE)
      copy_uint64_pipeline_part(root, "a-1_0_1_0_2", PIPELINE_DELTA_FIXTURE)
      source = CrystalClick::WidePartSet.open(root, "value")

      calls = 0_u64
      first_values = Array(UInt64).new
      boundary_values = Array(UInt64).new
      last_value = 0_u64
      result = source.aggregate_uint64(Slice(UInt64).new(73)) do |value|
        first_values << value if calls < 5_u64
        boundary_values << value if calls >= 4_093_u64 && calls <= 4_098_u64
        last_value = value
        calls += 1_u64
        true
      end

      calls.should eq(source.total_row_count)
      first_values.should eq([0_u64, 1_u64, 2_u64, 3_u64, 4_u64])
      boundary_values.should eq([4_093_u64, 4_094_u64, 4_095_u64, 0_u64, 1_u64, 2_u64])
      last_value.should eq(199_999_u64)
      result.count.should eq(204_096_u64)
      result.min.should eq(0_u64)
      result.max.should eq(UInt64::MAX)
    end
  end

  it "distinguishes selective, empty, and zero-only matches" do
    with_uint64_pipeline_root do |root|
      copy_uint64_pipeline_part(root, "part_0_0_1_0")
      source = CrystalClick::WidePartSet.open(root, "value")
      scratch = Slice(UInt64).new(257)

      evens = source.aggregate_uint64(scratch) { |value| value.even? }
      evens.count.should eq(100_000_u64)
      evens.sum.should eq(9_999_900_000_u64)
      evens.min.should eq(0_u64)
      evens.max.should eq(199_998_u64)

      none = source.aggregate_uint64(scratch) { |_| false }
      none.count.should eq(0_u64)
      none.sum.should eq(0_u64)
      none.min.should be_nil
      none.max.should be_nil
      none.empty?.should be_true

      zero = source.aggregate_uint64(scratch) { |value| value == 0_u64 }
      zero.count.should eq(1_u64)
      zero.sum.should eq(0_u64)
      zero.min.should eq(0_u64)
      zero.max.should eq(0_u64)
      zero.empty?.should be_false
    end
  end

  it "uses UInt64 modular sum for repeated maximum values" do
    with_uint64_pipeline_root do |root|
      copy_uint64_pipeline_part(root, "first_0_0_1_0", PIPELINE_DELTA_FIXTURE)
      source = CrystalClick::WidePartSet.open(root, "value")

      result = source.aggregate_uint64(Slice(UInt64).new(17)) do |value|
        value == UInt64::MAX
      end

      result.count.should eq(2_u64)
      result.sum.should eq(UInt64::MAX - 1_u64)
      result.min.should eq(UInt64::MAX)
      result.max.should eq(UInt64::MAX)
    end
  end

  it "rejects invalid scratch before invoking the predicate" do
    with_uint64_pipeline_root do |root|
      copy_uint64_pipeline_part(root, "part_0_0_1_0")
      source = CrystalClick::WidePartSet.open(root, "value")
      calls = 0

      expect_raises(CrystalClick::BoundsError) do
        source.aggregate_uint64(Slice(UInt64).empty) do |_value|
          calls += 1
          true
        end
      end
      expect_raises(CrystalClick::BoundsError) do
        source.aggregate_uint64(Slice(UInt64).new(4, read_only: true)) do |_value|
          calls += 1
          true
        end
      end
      calls.should eq(0)
    end
  end

  it "propagates predicate errors without returning a partial result" do
    with_uint64_pipeline_root do |root|
      copy_uint64_pipeline_part(root, "part_0_0_1_0")
      source = CrystalClick::WidePartSet.open(root, "value")
      callback_error = Exception.new("pipeline predicate failed")

      raised = expect_raises(Exception) do
        source.aggregate_uint64(Slice(UInt64).new(73)) do |_value|
          raise callback_error
        end
      end
      raised.should eq(callback_error)
    end
  end

  it "propagates a later decoder error rather than exposing partial aggregates" do
    with_uint64_pipeline_root do |root|
      part_path = copy_uint64_pipeline_part(root, "part_0_0_1_0", PIPELINE_ZSTD_FIXTURE)
      data_path = Dir.glob(File.join(part_path, "*.bin")).first.not_nil!
      bytes = writable_file_bytes(data_path)
      offsets = pipeline_frame_offsets(bytes)
      offsets.size.should be > 2
      bytes[offsets[2] + 16] = 0x81_u8
      File.open(data_path, "wb") { |io| io.write(bytes) }

      source = CrystalClick::WidePartSet.open(root, "value")
      calls = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        source.aggregate_uint64(Slice(UInt64).new(73)) do |_value|
          calls += 1
          true
        end
      end
      calls.should be > 0
    end
  end

  it "does not materialize selected rows or retain borrowed scan state" do
    implementation = File.read(File.expand_path("../src/crystal_click/uint64_execution_pipeline.cr", __DIR__))
    implementation.should_not contain("Array(UInt64)")
    implementation.should_not contain(".to_a")
    implementation.should_not contain("@batch")
    implementation.should_not contain("@values")
    implementation.should_not contain("predicate.call")
    implementation.should_not contain("Proc(")
  end
end
