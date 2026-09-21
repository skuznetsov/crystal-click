require "./spec_helper"

REAL_READER_FIXTURE_GENERATOR = File.expand_path("../scripts/generate_real_reader_benchmark_fixture.sh", __DIR__)
REAL_READER_FIXTURE_ROWS      = 257

struct RealReaderFixtureCommand
  getter status : Process::Status
  getter stdout : String
  getter stderr : String

  def initialize(@status, @stdout, @stderr)
  end
end

def run_real_reader_fixture_generator(arguments : Array(String)) : RealReaderFixtureCommand
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run("/bin/bash", [REAL_READER_FIXTURE_GENERATOR] + arguments, output: stdout, error: stderr)
  RealReaderFixtureCommand.new(status, stdout.to_s, stderr.to_s)
end

def real_reader_fixture_checksum(rows : Int) : UInt64
  checksum = 0_u64
  multiplier = 0x94d049bb133111eb_u64
  rows.times do |number|
    checksum = (checksum &* multiplier) ^ number.to_u64
  end
  checksum
end

def real_reader_fixture_frame_method(path : String) : UInt8
  bytes = File.read(path).to_slice
  raise "fixture frame is truncated" if bytes.size < 25
  bytes[16]
end

describe "generate_real_reader_benchmark_fixture" do
  it "generates and checks each physical codec, and refuses mismatches" do
    temporary_root = File.tempname("crystal-click-real-reader-benchmark-spec")
    Dir.mkdir(temporary_root)

    begin
      {"lz4", "zstd", "delta-zstd"}.each do |codec|
        fixture = File.join(temporary_root, codec)
        generated = run_real_reader_fixture_generator(["--codec", codec, "--rows", REAL_READER_FIXTURE_ROWS.to_s, fixture])
        generated.status.success?.should be_true, generated.stderr

        checked = run_real_reader_fixture_generator(["--codec", codec, "--rows", REAL_READER_FIXTURE_ROWS.to_s, "--check", fixture])
        checked.status.success?.should be_true, checked.stderr
        checked.stdout.should contain("codec=#{codec}")
        checked.stdout.should contain("rows=#{REAL_READER_FIXTURE_ROWS}")
        checked.stdout.should contain("checksum=#{real_reader_fixture_checksum(REAL_READER_FIXTURE_ROWS)}")
        checked.stdout.should_not contain(fixture)
        checked.stderr.should_not contain(fixture)

        part = CrystalClick::WidePart.open(fixture)
        part.read_uint64("value").should eq((0...REAL_READER_FIXTURE_ROWS).map(&.to_u64))

        data_files = Dir.glob(File.join(fixture, "*.bin"))
        mark_files = Dir.glob(File.join(fixture, "*.cmrk2"))
        data_files.size.should eq(1)
        mark_files.size.should eq(1)
        Dir.glob(File.join(fixture, "*.mrk2")).should be_empty
        real_reader_fixture_frame_method(data_files.first).should eq(
          {"lz4" => 0x82_u8, "zstd" => 0x90_u8, "delta-zstd" => 0x91_u8}[codec]
        )
        real_reader_fixture_frame_method(mark_files.first).should eq(0x90_u8)
        File.read(File.join(fixture, ".crystal-click-real-reader-benchmark-fixture")).should contain("codec=#{codec}")

        if codec == "delta-zstd"
          marker = File.join(fixture, ".crystal-click-real-reader-benchmark-fixture")
          File.write(marker, "crystal-click-real-reader-benchmark-fixture-v1\n")
          legacy_checked = run_real_reader_fixture_generator(["--codec", codec, "--rows", REAL_READER_FIXTURE_ROWS.to_s, "--check", fixture])
          legacy_checked.status.success?.should be_true, legacy_checked.stderr
          legacy_checked.stdout.should_not contain(fixture)
          legacy_checked.stderr.should_not contain(fixture)
        end

        mismatch = codec == "lz4" ? "zstd" : "lz4"
        mismatched_check = run_real_reader_fixture_generator(["--codec", mismatch, "--rows", REAL_READER_FIXTURE_ROWS.to_s, "--check", fixture])
        mismatched_check.status.success?.should be_false
        mismatched_check.stdout.should_not contain(fixture)
        mismatched_check.stderr.should_not contain(fixture)
        File.directory?(fixture).should be_true
      end
    ensure
      FileUtils.rm_rf(temporary_root)
    end
  end

  it "rejects invalid codecs and never deletes an unrelated directory" do
    temporary_root = File.tempname("crystal-click-real-reader-benchmark-guards")
    Dir.mkdir(temporary_root)

    begin
      invalid_fixture = File.join(temporary_root, "invalid")
      invalid = run_real_reader_fixture_generator(["--codec", "plain", "--rows", "7", invalid_fixture])
      invalid.status.success?.should be_false
      File.exists?(invalid_fixture).should be_false

      {"0007", "100000001"}.each do |rows|
        invalid_rows_fixture = File.join(temporary_root, "invalid-rows-#{rows}")
        invalid_rows = run_real_reader_fixture_generator(["--codec", "lz4", "--rows", rows, invalid_rows_fixture])
        invalid_rows.status.success?.should be_false
        File.exists?(invalid_rows_fixture).should be_false
        invalid_rows.stdout.should_not contain(temporary_root)
        invalid_rows.stderr.should_not contain(temporary_root)
      end

      directory_target = File.join(temporary_root, "directory-target")
      Dir.mkdir(directory_target)
      directory_sentinel = File.join(directory_target, "keep.txt")
      File.write(directory_sentinel, "keep directory\n")
      directory_link = File.join(temporary_root, "directory-link")
      File.symlink(directory_target, directory_link)
      directory_symlink = run_real_reader_fixture_generator(["--codec", "lz4", "--rows", "7", "--force", directory_link])
      directory_symlink.status.success?.should be_false
      File.symlink?(directory_link).should be_true
      File.read(directory_sentinel).should eq("keep directory\n")
      directory_symlink.stdout.should_not contain(temporary_root)
      directory_symlink.stderr.should_not contain(temporary_root)

      marker_output = File.join(temporary_root, "marker-output")
      Dir.mkdir(marker_output)
      marker_target = File.join(temporary_root, "marker-target")
      File.write(marker_target, "crystal-click-real-reader-benchmark-fixture-v2\ncodec=lz4\n")
      marker = File.join(marker_output, ".crystal-click-real-reader-benchmark-fixture")
      File.symlink(marker_target, marker)
      marker_sentinel = File.join(marker_output, "keep.txt")
      File.write(marker_sentinel, "keep marker\n")
      marker_symlink = run_real_reader_fixture_generator(["--codec", "lz4", "--rows", "7", "--force", marker_output])
      marker_symlink.status.success?.should be_false
      File.symlink?(marker).should be_true
      File.read(marker_target).should eq("crystal-click-real-reader-benchmark-fixture-v2\ncodec=lz4\n")
      File.read(marker_sentinel).should eq("keep marker\n")
      marker_symlink.stdout.should_not contain(temporary_root)
      marker_symlink.stderr.should_not contain(temporary_root)

      unrelated = File.join(temporary_root, "unrelated")
      Dir.mkdir(unrelated)
      File.write(File.join(unrelated, ".crystal-click-real-reader-benchmark-fixture"), "different-owner\n")
      sentinel = File.join(unrelated, "keep.txt")
      File.write(sentinel, "keep\n")
      forced = run_real_reader_fixture_generator(["--codec", "lz4", "--rows", "7", "--force", unrelated])
      forced.status.success?.should be_false
      File.read(sentinel).should eq("keep\n")
      forced.stdout.should_not contain(unrelated)
      forced.stderr.should_not contain(unrelated)

      legacy = File.join(temporary_root, "legacy")
      Dir.mkdir(legacy)
      File.write(File.join(legacy, ".crystal-click-real-reader-benchmark-fixture"), "crystal-click-real-reader-benchmark-fixture-v1\n")
      legacy_sentinel = File.join(legacy, "keep.txt")
      File.write(legacy_sentinel, "keep legacy\n")
      legacy_forced = run_real_reader_fixture_generator(["--codec", "delta-zstd", "--rows", "7", "--force", legacy])
      legacy_forced.status.success?.should be_false
      File.read(legacy_sentinel).should eq("keep legacy\n")
      legacy_forced.stdout.should_not contain(legacy)
      legacy_forced.stderr.should_not contain(legacy)
    ensure
      FileUtils.rm_rf(temporary_root)
    end
  end

  it "replaces one owned v2 fixture with --force and refuses legacy v1" do
    temporary_root = File.tempname("crystal-click-real-reader-benchmark-force")
    Dir.mkdir(temporary_root)

    begin
      fixture = File.join(temporary_root, "owned")
      generated = run_real_reader_fixture_generator(["--codec", "lz4", "--rows", "7", fixture])
      generated.status.success?.should be_true, generated.stderr

      marker = File.join(fixture, ".crystal-click-real-reader-benchmark-fixture")
      File.read(marker).should eq("crystal-click-real-reader-benchmark-fixture-v2\ncodec=lz4\n")
      stale = File.join(fixture, "stale.txt")
      File.write(stale, "remove me\n")

      replaced = run_real_reader_fixture_generator(["--codec", "lz4", "--rows", "11", "--force", fixture])
      replaced.status.success?.should be_true, replaced.stderr
      File.exists?(stale).should be_false
      File.read(File.join(fixture, "count.txt")).should eq("11")
      File.read(marker).should eq("crystal-click-real-reader-benchmark-fixture-v2\ncodec=lz4\n")

      checked = run_real_reader_fixture_generator(["--codec", "lz4", "--rows", "11", "--check", fixture])
      checked.status.success?.should be_true, checked.stderr
      checked.stdout.should_not contain(temporary_root)
      checked.stderr.should_not contain(temporary_root)

      File.write(marker, "crystal-click-real-reader-benchmark-fixture-v1\n")
      legacy_sentinel = File.join(fixture, "keep-legacy.txt")
      File.write(legacy_sentinel, "keep legacy\n")
      legacy_forced = run_real_reader_fixture_generator(["--codec", "lz4", "--rows", "11", "--force", fixture])
      legacy_forced.status.success?.should be_false
      File.read(legacy_sentinel).should eq("keep legacy\n")
      File.read(marker).should eq("crystal-click-real-reader-benchmark-fixture-v1\n")
      legacy_forced.stdout.should_not contain(temporary_root)
      legacy_forced.stderr.should_not contain(temporary_root)
    ensure
      FileUtils.rm_rf(temporary_root)
    end
  end
end
