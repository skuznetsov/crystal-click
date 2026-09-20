require "./spec_helper"

MULTI_COLUMN_FIXTURE = File.expand_path("../test/fixtures/public/wide_multi_input_delta_zstd/part", __DIR__)
MULTI_INPUT_HASH     = "40e9692b249087848c5984b3e27b0514"
MULTI_PREFIX_HASH    = "0d365cf0b11cc61870b4eb176160463f"
MULTI_SUFFIX_HASH    = "1e8c0ffecee24cc6ccbf743d5f16c33f"
MULTI_MARK_ROWS      =  256
MULTI_ROW_COUNT      = 4096

def multicolumn_input_values : Array(UInt64)
  values = Array(UInt64).new(MULTI_ROW_COUNT, 0_u64)
  MULTI_ROW_COUNT.times do |number|
    values[number] = case number
                     when 1
                       UInt64::MAX
                     when 2
                       0_u64
                     when 3
                       1_u64
                     when 2047
                       UInt64::MAX
                     when 2048
                       0_u64
                     else
                       number % 23 == 0 ? 42_u64 : ((number * 17) % 100_000).to_u64
                     end
  end
  values
end

def with_multicolumn_fixture_copy(&)
  path = File.tempname("crystal-click-multicolumn-spec")
  FileUtils.cp_r(MULTI_COLUMN_FIXTURE, path)
  begin
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end

def multicolumn_stream(path : String, hash : String, extension : String) : String
  File.join(path, "#{hash}.#{extension}")
end

def write_multicolumn_substreams(path : String, input_block : String, input_first = false)
  prefix_block = "2 substreams for column `prefix`:\n\tprefix.size\n\tprefix\n"
  suffix_block = "4 substreams for column `suffix`:\n\tsuffix.size0\n\tsuffix.null\n\tsuffix.size\n\tsuffix\n"
  blocks = input_first ? input_block + prefix_block + suffix_block : prefix_block + input_block + suffix_block
  File.write(
    File.join(path, "columns_substreams.txt"),
    "columns substreams version: 1\n3 columns:\n" + blocks
  )
end

describe "multi-column WidePart target selection" do
  it "reads the selected second UInt64 column in full" do
    part = CrystalClick::WidePart.open(MULTI_COLUMN_FIXTURE, "input")
    part.row_count.should eq(MULTI_ROW_COUNT.to_u64)
    part.mark_count.should eq(16)
    part.data_path.should end_with("#{MULTI_INPUT_HASH}.bin")
    part.read_uint64.should eq(multicolumn_input_values)
  end

  it "reads the selected target when only the exact stream name is present" do
    with_multicolumn_fixture_copy do |path|
      FileUtils.mv(multicolumn_stream(path, MULTI_INPUT_HASH, "bin"), File.join(path, "input.bin"))
      FileUtils.mv(multicolumn_stream(path, MULTI_INPUT_HASH, "cmrk2"), File.join(path, "input.cmrk2"))
      part = CrystalClick::WidePart.open(path, "input")
      part.data_path.should end_with("input.bin")
      part.read_uint64.should eq(multicolumn_input_values)
    end
  end

  it "rejects path-like selected physical stream names before probing nested files" do
    with_multicolumn_fixture_copy do |path|
      nested = File.join(path, "nested")
      Dir.mkdir(nested)
      FileUtils.cp(multicolumn_stream(path, MULTI_INPUT_HASH, "bin"), File.join(nested, "input.bin"))
      FileUtils.cp(multicolumn_stream(path, MULTI_INPUT_HASH, "cmrk2"), File.join(nested, "input.cmrk2"))
      columns_file = File.join(path, "columns.txt")
      File.write(columns_file, File.read(columns_file).sub("`input` UInt64", "`nested/input` UInt64"))
      substreams_file = File.join(path, "columns_substreams.txt")
      substreams = File.read(substreams_file)
      substreams = substreams.sub("column `input`", "column `nested/input`").sub("\tinput\n", "\tnested/input\n")
      File.write(substreams_file, substreams)

      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open(path, "nested/input")
      end
      error.message.not_nil!.should contain("filename component")
    end
  end

  it "rejects target stream symlinks before reading them" do
    with_multicolumn_fixture_copy do |path|
      data = multicolumn_stream(path, MULTI_INPUT_HASH, "bin")
      marks = multicolumn_stream(path, MULTI_INPUT_HASH, "cmrk2")
      real_data = File.join(path, "real-input.bin")
      real_marks = File.join(path, "real-input.cmrk2")
      FileUtils.mv(data, real_data)
      FileUtils.mv(marks, real_marks)
      File.symlink(real_data, data)
      File.symlink(real_marks, marks)

      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open(path, "input")
      end
      error.message.not_nil!.should contain("symbolic links")
    end
  end

  it "reads two bounded mark ranges from the selected target" do
    expected = multicolumn_input_values
    part = CrystalClick::WidePart.open(MULTI_COLUMN_FIXTURE, "input")
    part.read_uint64_mark_range("input", 0, 1).should eq(expected[0, MULTI_MARK_ROWS])
    part.read_uint64_mark_range("input", 7, 2).should eq(expected[7 * MULTI_MARK_ROWS, 2 * MULTI_MARK_ROWS])
  end

  it "requires an explicit column for a multi-column legacy open" do
    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WidePart.open(MULTI_COLUMN_FIXTURE)
    end
    error.message.not_nil!.should contain("column is required")
  end

  it "rejects non-canonical or oversized default codec metadata" do
    mutations = [
      ->(path : String) { File.write(File.join(path, "default_compression_codec.txt"), "CODEC(LZ4) ") },
      ->(path : String) { File.write(File.join(path, "default_compression_codec.txt"), "x" * 65) },
    ]
    mutations.each do |mutation|
      with_multicolumn_fixture_copy do |path|
        mutation.call(path)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open(path, "input")
        end
      end
    end
  end

  it "ignores corrupt or missing neighbors and an unsupported neighbor mark extension" do
    expected = multicolumn_input_values
    with_multicolumn_fixture_copy do |path|
      mutate_fixture_file(path, "#{MULTI_PREFIX_HASH}.bin") { |bytes| bytes[0] ^= 0xff_u8 }
      File.delete(multicolumn_stream(path, MULTI_PREFIX_HASH, "cmrk2"))
      File.delete(multicolumn_stream(path, MULTI_SUFFIX_HASH, "bin"))
      File.delete(multicolumn_stream(path, MULTI_SUFFIX_HASH, "cmrk2"))
      FileUtils.cp(
        multicolumn_stream(path, MULTI_PREFIX_HASH, "bin"),
        multicolumn_stream(path, MULTI_PREFIX_HASH, "mrk3")
      )

      CrystalClick::WidePart.open(path, "input").read_uint64.should eq(expected)
    end
  end

  it "decodes SQL-style escaped neighbor names consistently" do
    with_multicolumn_fixture_copy do |path|
      File.write(
        File.join(path, "columns.txt"),
        "columns format version: 1\n3 columns:\n`pre\\x41fix` String\n`input` UInt64\n`suf``\\Nfix` Array(Nullable(String))\n"
      )
      File.write(
        File.join(path, "columns_substreams.txt"),
        "columns substreams version: 1\n3 columns:\n2 substreams for column `pre\\x41fix`:\n\tprefix.size\n\tprefix\n1 substreams for column `input`:\n\tinput\n4 substreams for column `suf``\\Nfix`:\n\tsuffix.size0\n\tsuffix.null\n\tsuffix.size\n\tsuffix\n"
      )
      CrystalClick::WidePart.open(path, "input").read_uint64.should eq(multicolumn_input_values)
    end
  end

  it "accepts UTF-8 neighbor names consistently in both metadata files" do
    with_multicolumn_fixture_copy do |path|
      File.write(
        File.join(path, "columns.txt"),
        "columns format version: 1\n3 columns:\n`préfix` String\n`input` UInt64\n`suffix` Array(Nullable(String))\n"
      )
      File.write(
        File.join(path, "columns_substreams.txt"),
        "columns substreams version: 1\n3 columns:\n2 substreams for column `préfix`:\n\tprefix.size\n\tprefix\n1 substreams for column `input`:\n\tinput\n4 substreams for column `suffix`:\n\tsuffix.size0\n\tsuffix.null\n\tsuffix.size\n\tsuffix\n"
      )
      CrystalClick::WidePart.open(path, "input").read_uint64.should eq(multicolumn_input_values)
    end
  end

  it "rejects malformed, trailing, duplicate, and reordered metadata" do
    mutations = [
      ->(path : String) { File.write(File.join(path, "columns.txt"), "not columns metadata\n") },
      ->(path : String) { File.open(File.join(path, "columns.txt"), "ab") { |io| io.write(Bytes[0]) } },
      ->(path : String) {
        text = File.read(File.join(path, "columns.txt")).sub("3 columns:", "4 columns:")
        File.write(File.join(path, "columns.txt"), text)
      },
      ->(path : String) {
        text = File.read(File.join(path, "columns.txt"))
        File.write(File.join(path, "columns.txt"), String.new(text.to_slice[0, text.bytesize - 1]))
      },
      ->(path : String) {
        file = File.join(path, "columns_substreams.txt")
        File.write(file, File.read(file).sub(/\tsuffix\n\z/, ""))
      },
      ->(path : String) {
        File.write(File.join(path, "columns.txt"), "columns format version: 1\n3 columns:\n`prefix` String\n`input` UInt64\n`input` UInt64\n")
      },
      ->(path : String) {
        write_multicolumn_substreams(path, "1 substreams for column `input`:\n\tinput\n", true)
      },
      ->(path : String) {
        File.write(
          File.join(path, "columns.txt"),
          "columns format version: 1\n3 columns:\n`prefix\\xG0` String\n`input` UInt64\n`suffix` Array(Nullable(String))\n"
        )
      },
      ->(path : String) {
        File.write(
          File.join(path, "columns.txt"),
          "columns format version: 1\n3 columns:\n`prefix\\x4` String\n`input` UInt64\n`suffix` Array(Nullable(String))\n"
        )
      },
      ->(path : String) {
        File.write(
          File.join(path, "columns.txt"),
          "columns format version: 1\n3 columns:\n`prefix` String\n`in\\Nput` UInt64\n`input` UInt64\n"
        )
      },
    ]
    mutations.each do |mutation|
      with_multicolumn_fixture_copy do |path|
        mutation.call(path)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open(path, "input")
        end
      end
    end
  end

  it "rejects a wrong selected type or a target with multiple substreams" do
    mutations = [
      ->(path : String) {
        File.write(File.join(path, "columns.txt"), "columns format version: 1\n3 columns:\n`prefix` String\n`input` UInt32\n`suffix` Array(Nullable(String))\n")
      },
      ->(path : String) {
        write_multicolumn_substreams(path, "2 substreams for column `input`:\n\tinput\n\tinput.extra\n")
      },
    ]
    mutations.each do |mutation|
      with_multicolumn_fixture_copy do |path|
        mutation.call(path)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open(path, "input")
        end
      end
    end
  end

  it "rejects complete exact and hashed target pairs as ambiguous" do
    with_multicolumn_fixture_copy do |path|
      FileUtils.cp(multicolumn_stream(path, MULTI_INPUT_HASH, "bin"), File.join(path, "input.bin"))
      FileUtils.cp(multicolumn_stream(path, MULTI_INPUT_HASH, "cmrk2"), File.join(path, "input.cmrk2"))
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open(path, "input")
      end
      error.message.not_nil!.should contain("ambiguous")
    end
  end

  it "rejects a complete hashed pair plus a partial exact alternate" do
    with_multicolumn_fixture_copy do |path|
      FileUtils.cp(multicolumn_stream(path, MULTI_INPUT_HASH, "bin"), File.join(path, "input.bin"))
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open(path, "input")
      end
      error.message.not_nil!.should contain("pair")
    end
  end
end
