require "./spec_helper"
require "file_utils"

# Probe the exact public readback method used by the staged writer validator.
# A test-only override changes only one selected mark, so failures exercise the
# writer's real validation and stage-cleanup path without adding a production
# failpoint or test hook.
class CrystalClick::WidePart
  class_property w176_count_probe_mode : Symbol? = nil
  class_property w176_count_probe_mark = -1
  class_property w176_count_probe_calls = [] of Tuple(String, Int32, Int32, Symbol)

  def self.w176_begin_count_probe(mode : Symbol, mark : Int32 = 1) : Nil
    self.w176_count_probe_calls = [] of Tuple(String, Int32, Int32, Symbol)
    self.w176_count_probe_mode = mode
    self.w176_count_probe_mark = mark
  end

  def self.w176_end_count_probe : Nil
    self.w176_count_probe_mode = nil
    self.w176_count_probe_mark = -1
  end

  def read_aggregate_count_mark_range(
    column : String,
    first_mark : Int,
    mark_count : Int,
    expected_type : CrystalClick::BinaryDataType,
  ) : Array(CrystalClick::BinaryValue)
    observed = previous_def
    if mode = CrystalClick::WidePart.w176_count_probe_mode
      if column == "c" && first_mark == CrystalClick::WidePart.w176_count_probe_mark
        raise "W176 Count probe requires a nonempty mark" if observed.empty?
        case mode
        when :changed_state
          observed[0] = CrystalClick::BinaryValue.aggregate_count_state(expected_type, observed[0].count_state + 1_u64)
        when :different_nominal
          other_type = CrystalClick::BinaryDataType.aggregate_count(
            CrystalClick::BinaryDataType.primitive("UInt64")
          )
          observed[0] = CrystalClick::BinaryValue.aggregate_count_state(other_type, observed[0].count_state)
        else
          raise "unknown W176 Count probe mode: #{mode}"
        end
        CrystalClick::WidePart.w176_count_probe_calls << {
          column,
          first_mark.to_i32,
          mark_count.to_i32,
          mode,
        }
      end
    end
    observed
  end
end

private def w176_writer_types : Array(CrystalClick::BinaryDataType)
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  [
    CrystalClick::BinaryDataType.aggregate_count,
    CrystalClick::BinaryDataType.aggregate_count(uint64),
    CrystalClick::BinaryDataType.aggregate_count(CrystalClick::BinaryDataType.nullable(uint64)),
  ]
end

private def w176_writer_states(type : CrystalClick::BinaryDataType, counts : Array(UInt64)) : Array(CrystalClick::BinaryValue)
  counts.map { |count| CrystalClick::BinaryValue.aggregate_count_state(type, count) }
end

private def w176_writer_expected_bytes(counts : Array(UInt64)) : Bytes
  bytes = [] of UInt8
  counts.each do |count|
    remaining = count
    loop do
      payload = (remaining & 0x7f_u64).to_u8
      remaining >>= 7
      bytes << (remaining == 0_u64 ? payload : payload | 0x80_u8)
      break if remaining == 0_u64
    end
  end
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def with_w176_writer_parent(&)
  parent = File.tempname("crystal-click-w176-count-writer")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w176_writer_part_path(root : String, label : String) : String
  File.join(root, label, "all_1_1_0")
end

private def write_w176_writer_native_part(
  destination : String,
  type : CrystalClick::BinaryDataType,
  counts : Array(UInt64),
) : Nil
  keys = [7_u64, 13_u64, 22_u64, 31_u64, 50_u64]
  values = w176_writer_states(type, counts)
  CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
    destination,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "c",
    type,
    values.to_unsafe.to_slice(values.size),
    rows_per_mark: 2
  )
end

describe "W176 AggregateFunction(count) Wide-part writer" do
  counts = [0_u64, 127_u64, 128_u64, 16_384_u64, UInt64::MAX]
  keys = [7_u64, 13_u64, 22_u64, 31_u64, 50_u64]

  w176_writer_types.each do |type|
    it "writes #{type.name} as one canonical VarUInt leaf" do
      with_w176_writer_parent do |parent|
        destination = File.join(parent, "part")
        values = w176_writer_states(type, counts)

        CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "c",
          type,
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 2
        ).should eq(destination)

        part = CrystalClick::WidePart.open_typed(destination, "c")
        part.column_type.should eq(type.name)
        part.row_count.should eq(5_u64)
        part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
        part.read_aggregate_count_mark_range("c", 0, part.mark_count, expected_type: type).map(&.count_state).should eq(counts)
        CrystalClick::WidePart.open(destination, "pk").read_uint64_mark_range("pk", 0, 3).should eq(keys)

        raw = CrystalClick::CompressedBlock.decode_all(
          File.read(File.join(destination, "#{CrystalClick::StreamName.hash("c")}.bin")).to_slice
        ).to_a
        raw.should eq(w176_writer_expected_bytes(counts).to_a)

        File.read(File.join(destination, "columns.txt")).should eq(
          "columns format version: 1\n2 columns:\n`pk` UInt64\n`c` #{type.name}\n"
        )
        File.read(File.join(destination, "columns_substreams.txt")).should eq(
          "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `c`:\n\tc\n"
        )
        File.read(File.join(destination, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
        File.read(File.join(destination, "metadata_version.txt")).should eq("0")
        File.read(File.join(destination, "serialization.json")).should eq(
          "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}"
        )
        expected = ["count.txt", "primary.idx", "serialization.json"]
        {"pk", "c"}.each do |stream|
          base = CrystalClick::StreamName.hash(stream)
          expected << "#{base}.bin"
          expected << "#{base}.mrk2"
        end
        checksums = CrystalClick::PartChecksums.open(destination)
        checksums.entries.keys.sort.should eq(expected.sort)
        checksums.entries.each_key { |name| checksums.validate_selected_entries(destination, name) }
      end
    end
  end

  it "refuses primitive, mismatched-nominal, row-mismatched, and invalid-granularity inputs" do
    with_w176_writer_parent do |parent|
      destination = File.join(parent, "part")
      type = w176_writer_types[0]
      wrong_nominal = w176_writer_states(w176_writer_types[1], counts)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "c",
          CrystalClick::BinaryDataType.primitive("UInt64"),
          w176_writer_states(CrystalClick::BinaryDataType.aggregate_count, counts).to_unsafe.to_slice(counts.size)
        )
      end

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "c",
          type,
          wrong_nominal.to_unsafe.to_slice(wrong_nominal.size)
        )
      end

      type_values = w176_writer_states(type, counts)
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size - 1),
          "c",
          type,
          type_values.to_unsafe.to_slice(type_values.size)
        )
      end

      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "c",
          type,
          type_values.to_unsafe.to_slice(type_values.size),
          rows_per_mark: 0
        )
      end

      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "c",
          type,
          type_values.to_unsafe.to_slice(type_values.size),
          rows_per_mark: CrystalClick::WidePartWriter::MAX_ROWS_PER_MARK + 1
        )
      end

      Dir.children(parent).should be_empty
    end
  end

  it "never replaces an existing target or leaves stage siblings after preflight refusal" do
    with_w176_writer_parent do |parent|
      destination = File.join(parent, "part")
      Dir.mkdir(destination)
      File.write(File.join(destination, "owner.txt"), "keep")
      type = w176_writer_types[0]
      values = w176_writer_states(type, counts)

      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "c",
          type,
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 2
        )
      end

      File.read(File.join(destination, "owner.txt")).should eq("keep")
      Dir.children(parent).should eq(["part"])
    end
  end

  {
    {:changed_state, "altered Count state"},
    {:different_nominal, "same-count readback with a different nominal descriptor"},
  }.each do |mode, description|
    it "rejects #{description} and cleans the staged part before publication" do
      with_w176_writer_parent do |parent|
        table = File.join(parent, "table")
        Dir.mkdir(table)
        destination = File.join(table, "all_1_1_0")
        type = w176_writer_types[0]
        values = w176_writer_states(type, counts)
        readback_calls = [] of Tuple(String, Int32, Int32, Symbol)

        CrystalClick::WidePart.w176_begin_count_probe(mode, mark: 1)
        begin
          expect_raises(CrystalClick::CorruptPartError) do
            CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
              destination,
              "pk",
              keys.to_unsafe.to_slice(keys.size),
              "c",
              type,
              values.to_unsafe.to_slice(values.size),
              rows_per_mark: 2
            )
          end
        ensure
          readback_calls = CrystalClick::WidePart.w176_count_probe_calls.dup
          CrystalClick::WidePart.w176_end_count_probe
        end

        readback_calls.should eq([{"c", 1, 1, mode}])
        File.exists?(destination).should be_false
        Dir.children(table).should be_empty
        Dir.children(parent).should eq(["table"])
      end
    end
  end

  if root = ENV["W176_PART_ROOT"]?
    it "retains three native parts plus a value-mutant negative control without overwriting" do
      Dir.exists?(root).should be_true
      File.symlink?(root).should be_false
      Dir.children(root).sort.should eq(["none", "nullable", "uint64", "value-mutant"])
      entries = {
        {"none", w176_writer_types[0], counts},
        {"uint64", w176_writer_types[1], counts},
        {"nullable", w176_writer_types[2], counts},
        {"value-mutant", w176_writer_types[0], [0_u64, 127_u64, 129_u64, 16_384_u64, UInt64::MAX]},
      }

      entries.each do |label, type, state_counts|
        destination = w176_writer_part_path(root, label)
        profile_parent = File.dirname(destination)
        Dir.exists?(profile_parent).should be_true
        File.symlink?(profile_parent).should be_false
        Dir.children(profile_parent).should be_empty
        File.exists?(destination).should be_false
        File.symlink?(destination).should be_false
        write_w176_writer_native_part(destination, type, state_counts)
      end
    end
  end
end
