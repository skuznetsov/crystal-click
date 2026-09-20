require "./spec_helper"

MMAP_TEST_MAX_BYTES = 256_i64 * 1024 * 1024

{% if flag?(:unix) %}
  module CrystalClick::MMapDataSource
    class RecordingMMapBackend
      getter map_sizes = [] of UInt64
      getter map_offsets = [] of Int64
      getter map_was_open = [] of Bool
      getter unmap_sizes = [] of UInt64
      getter unmap_was_open = [] of Bool

      def initialize(@storage : Bytes, @unmap_result : Int32 = 0, @map_result : Pointer(Void)? = nil)
      end

      def map(file : File, size : UInt64, offset : Int64) : Pointer(Void)
        @map_sizes << size
        @map_offsets << offset
        @map_was_open << !file.closed?
        @map_result || @storage.to_unsafe.as(Pointer(Void))
      end

      def unmap(file : File, pointer : Pointer(Void), size : UInt64) : Int32
        @unmap_sizes << size
        @unmap_was_open << !file.closed?
        @unmap_result
      end
    end

    def self.with_file_using_backend_for_spec(path : String, expected_size : Int64, max_size : Int64, backend, & : Bytes ->) : Nil
      with_file_using_backend(path, expected_size, max_size, backend) do |mapped|
        yield mapped
      end
    end
  end
{% end %}

def with_mmap_file(bytes : Bytes, &)
  path = File.tempname("crystal-click-mmap-spec")
  File.open(path, "wb") { |io| io.write(bytes) }
  begin
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end

describe CrystalClick::MMapDataSource do
  it "maps once at offset zero and unmaps before closing the descriptor" do
    bytes = Bytes[1, 2, 3, 4]
    backend = CrystalClick::MMapDataSource::RecordingMMapBackend.new(bytes)

    with_mmap_file(bytes) do |path|
      CrystalClick::MMapDataSource.with_file_using_backend_for_spec(path, bytes.size.to_i64, MMAP_TEST_MAX_BYTES, backend) do |mapped|
        mapped.to_a.should eq(bytes.to_a)
      end
    end

    backend.map_sizes.should eq([bytes.size.to_u64])
    backend.map_offsets.should eq([0_i64])
    backend.map_was_open.should eq([true])
    backend.unmap_sizes.should eq([bytes.size.to_u64])
    backend.unmap_was_open.should eq([true])
  end

  it "exposes an exact read-only view and releases it after the callback" do
    bytes = Bytes.new(8192) { |index| (index % 251).to_u8 }

    with_mmap_file(bytes) do |path|
      observed = {0_u8, 0, false}
      CrystalClick::MMapDataSource.with_file(path, bytes.size.to_i64, MMAP_TEST_MAX_BYTES) do |mapped|
        observed = {mapped[1234], mapped.size, mapped.read_only?}
      end

      observed.should eq({bytes[1234], bytes.size, true})
    end
  end

  it "rejects empty, changed, and oversized files before mapping" do
    with_mmap_file(Bytes.new(0)) do |path|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::MMapDataSource.with_file(path, 0_i64, MMAP_TEST_MAX_BYTES) { |_| }
      end
    end

    with_mmap_file(Bytes[1, 2, 3]) do |path|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::MMapDataSource.with_file(path, 2_i64, MMAP_TEST_MAX_BYTES) { |_| }
      end
    end

    with_mmap_file(Bytes[1, 2, 3]) do |path|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::MMapDataSource.with_file(path, 3_i64, 2_i64) { |_| }
      end
    end
  end

  it "unmaps before propagating a callback exception" do
    bytes = Bytes[1, 2, 3]
    backend = CrystalClick::MMapDataSource::RecordingMMapBackend.new(bytes)

    with_mmap_file(Bytes[1, 2, 3]) do |path|
      expect_raises(CrystalClick::CorruptPartError, "decoder failure") do
        CrystalClick::MMapDataSource.with_file_using_backend_for_spec(path, 3_i64, MMAP_TEST_MAX_BYTES, backend) do |_mapped|
          raise CrystalClick::CorruptPartError.new("decoder failure")
        end
      end
    end

    backend.map_sizes.should eq([bytes.size.to_u64])
    backend.map_offsets.should eq([0_i64])
    backend.map_was_open.should eq([true])
    backend.unmap_sizes.should eq([bytes.size.to_u64])
    backend.unmap_was_open.should eq([true])
  end

  it "retains callback and cleanup failures in a typed error" do
    bytes = Bytes[1, 2, 3]
    backend = CrystalClick::MMapDataSource::RecordingMMapBackend.new(bytes, -1)
    callback_error = CrystalClick::CorruptPartError.new("decoder failure")

    cleanup_error = with_mmap_file(bytes) do |path|
      expect_raises(CrystalClick::MMapCleanupError) do
        CrystalClick::MMapDataSource.with_file_using_backend_for_spec(path, bytes.size.to_i64, MMAP_TEST_MAX_BYTES, backend) do |_mapped|
          raise callback_error
        end
      end
    end

    cleanup_error.callback_error.should be(callback_error)
    cleanup_error.cleanup_error.should be_a(CrystalClick::CorruptPartError)
    cleanup_error.cleanup_error.message.should eq("cannot unmap data file")
    backend.unmap_sizes.should eq([bytes.size.to_u64])
    backend.unmap_was_open.should eq([true])
  end

  it "surfaces a standalone unmap failure" do
    bytes = Bytes[1, 2, 3]
    backend = CrystalClick::MMapDataSource::RecordingMMapBackend.new(bytes, -1)

    with_mmap_file(bytes) do |path|
      expect_raises(CrystalClick::CorruptPartError, "cannot unmap data file") do
        CrystalClick::MMapDataSource.with_file_using_backend_for_spec(path, bytes.size.to_i64, MMAP_TEST_MAX_BYTES, backend) { |_| }
      end
    end
  end

  it "rejects a non-regular opened descriptor before mapping" do
    path = File.tempname("crystal-click-mmap-directory")
    Dir.mkdir(path)
    backend = CrystalClick::MMapDataSource::RecordingMMapBackend.new(Bytes[1])
    begin
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::MMapDataSource.with_file_using_backend_for_spec(path, File.info(path).size, MMAP_TEST_MAX_BYTES, backend) { |_| }
      end

      error.message.should eq("data file is not a regular file")
      backend.map_sizes.should be_empty
    ensure
      FileUtils.rm_rf(path)
    end
  end

  it "propagates a callback IO::Error unchanged" do
    bytes = Bytes[1, 2, 3]
    backend = CrystalClick::MMapDataSource::RecordingMMapBackend.new(bytes)
    callback_error = IO::Error.new("callback failure")

    raised = with_mmap_file(bytes) do |path|
      expect_raises(IO::Error, "callback failure") do
        CrystalClick::MMapDataSource.with_file_using_backend_for_spec(path, bytes.size.to_i64, MMAP_TEST_MAX_BYTES, backend) do |_mapped|
          raise callback_error
        end
      end
    end

    raised.should be(callback_error)
    backend.map_sizes.should eq([bytes.size.to_u64])
    backend.map_offsets.should eq([0_i64])
    backend.unmap_sizes.should eq([bytes.size.to_u64])
    backend.unmap_was_open.should eq([true])
  end

  it "normalizes a backend mapping failure" do
    bytes = Bytes[1, 2, 3]
    backend = CrystalClick::MMapDataSource::RecordingMMapBackend.new(bytes, 0, LibC::MAP_FAILED)

    with_mmap_file(bytes) do |path|
      expect_raises(CrystalClick::CorruptPartError, "cannot map data file") do
        CrystalClick::MMapDataSource.with_file_using_backend_for_spec(path, bytes.size.to_i64, MMAP_TEST_MAX_BYTES, backend) { |_| }
      end
    end

    backend.map_sizes.should eq([bytes.size.to_u64])
    backend.map_offsets.should eq([0_i64])
    backend.unmap_sizes.should be_empty
  end

  it "guards the WidePart data route and native mapping flags" do
    wide_part = File.read(File.expand_path("../src/crystal_click/wide_part.cr", __DIR__))
    mmap_source = File.read(File.expand_path("../src/crystal_click/mmap_data_source.cr", __DIR__))

    wide_part.should_not contain("File.read(@data_path)")
    wide_part.should contain("MMapDataSource.with_file")
    mmap_source.should contain("LibC::PROT_READ")
    mmap_source.should contain("LibC::MAP_PRIVATE")
    mmap_source.should contain("private struct NativeBackend")
    mmap_source.should contain("private def self.with_file_using_backend")
    mmap_source.should contain("info.file?")
    mmap_source.should contain("MMapCleanupError")
    mmap_source.should_not contain("LibC::PROT_WRITE")
    mmap_source.should_not contain("LibC::MAP_SHARED")
  end
end
