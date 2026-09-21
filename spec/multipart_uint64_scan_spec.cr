require "./spec_helper"

MULTIPART_ZSTD_FIXTURE  = File.expand_path("../test/fixtures/public/wide_u64_zstd_cmrk2/part", __DIR__)
MULTIPART_DELTA_FIXTURE = File.expand_path("../test/fixtures/public/wide_u64_delta_zstd/part", __DIR__)
MULTIPART_MULTI_FIXTURE = File.expand_path("../test/fixtures/public/wide_multi_input_delta_zstd/part", __DIR__)

def with_multipart_root(&)
  root = File.tempname("crystal-click-multipart-spec")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

def copy_multipart_part(root : String, name : String, source : String = FIXTURE) : String
  path = File.join(root, name)
  FileUtils.cp_r(source, path)
  path
end

describe "multi-part UInt64 scanning" do
  it "parses bounded modern part names and same-partition inclusive overlap" do
    plain = CrystalClick::MergeTreePartInfo.parse("partition-a_-2_7_3").not_nil!
    plain.partition_id.should eq("partition-a")
    plain.min_block.should eq(-2_i64)
    plain.max_block.should eq(7_i64)
    plain.level.should eq(3_u32)
    plain.mutation.should eq(0_u32)
    plain.patch?.should be_false

    mutated = CrystalClick::MergeTreePartInfo.parse("partition-a_8_12_4_9").not_nil!
    mutated.mutation.should eq(9_u32)
    CrystalClick::MergeTreePartInfo.parse("partition-a_-2_7_3_0").not_nil!.mutation.should eq(0_u32)
    plain.overlaps?(mutated).should be_false
    plain.overlaps?(CrystalClick::MergeTreePartInfo.parse("partition-a_7_8_0").not_nil!).should be_true
    plain.overlaps?(CrystalClick::MergeTreePartInfo.parse("partition-b_-2_7_3").not_nil!).should be_false

    [
      "bad",
      "partition-a_0_1",
      "partition-a_0_1_x",
      "partition-a_1_0_0",
      "partition-a_0_1_4294967296",
      "partition-a_0_1_0_4294967296",
      "partition_a_0_1_0",
      "partition-a_0_1_0_extra_extra",
      "partition-a_9223372036854775808_1_0",
      "partition-a_-9223372036854775809_1_0",
    ].each do |name|
      CrystalClick::MergeTreePartInfo.parse(name).should be_nil
    end

    CrystalClick::MergeTreePartInfo.parse("patch-0123456789abcdef0123456789abcdef_0_1_0").not_nil!.patch?.should be_true

    legacy = CrystalClick::MergeTreePartInfo.parse("partition-a_0_1_4294967295").not_nil!
    legacy.level.should eq(CrystalClick::MergeTreePartInfo::MAX_LEVEL)
    legacy.name.should eq("partition-a_0_1_4294967295")
  end

  it "opens sorted cross-partition parts and emits exact provenance with size checks" do
    with_multipart_root do |root|
      copy_multipart_part(root, "z-1_0_1_0", FIXTURE)
      copy_multipart_part(root, "a-1_0_1_0_2", MULTIPART_ZSTD_FIXTURE)
      source = CrystalClick::WidePartSet.open(root, "value")

      source.part_count.should eq(2)
      source.total_row_count.should eq(400_000_u64)
      source.checksum_verification.should eq(CrystalClick::ChecksumVerification::SizeChecked)

      scratch = Slice(UInt64).new(257)
      batches = Array({String, String, Int32, UInt64, UInt64, UInt64, Int32}).new
      values = Array(UInt64).new
      current_part = -1_i32
      current_mark = -1_i32
      part_values = 0_u64
      mark_values = 0_u64
      mark_start = 0_u64
      source_values = 0_u64
      source.scan_into(scratch) do |batch|
        if batch.part_index != current_part
          if current_part >= 0
            part_values.should eq(200_000_u64)
            batch.part_index.should eq(current_part + 1)
            batch.part_row_offset.should eq(0_u64)
            batch.mark_index.should eq(0_i32)
          end
          current_part = batch.part_index
          current_mark = -1_i32
          part_values = 0_u64
        end
        if batch.mark_index != current_mark
          if current_mark >= 0
            batch.mark_index.should eq(current_mark + 1)
            expected_mark_rows = mark_start + mark_values < 200_000_u64 ? 1_024_u64 : 320_u64
            mark_values.should eq(expected_mark_rows)
          end
          current_mark = batch.mark_index
          mark_start = batch.part_row_offset
          mark_values = 0_u64
          batch.mark_row_offset.should eq(0_u64)
        end
        batch.mark_row_offset.should eq(mark_values)
        batch.part_row_offset.should eq(mark_start + mark_values)
        batch.source_row_offset.should eq(source_values)
        mark_values += batch.values.size.to_u64
        part_values += batch.values.size.to_u64
        source_values += batch.values.size.to_u64
        batches << {
          batch.part_name,
          batch.part_path,
          batch.part_index,
          batch.mark_row_offset,
          batch.part_row_offset,
          batch.source_row_offset,
          batch.values.size.to_i32,
        }
        batch.values.each { |value| values << value }
        batch.part_info.partition_id.should eq(batch.part_name.split('_')[0])
        batch.values.size.should be <= scratch.size
      end

      values.should eq((0_u64...200_000_u64).to_a + (0_u64...200_000_u64).to_a)
      expected_mark_rows = mark_start + mark_values < 200_000_u64 ? 1_024_u64 : 320_u64
      mark_values.should eq(expected_mark_rows)
      part_values.should eq(200_000_u64)
      source_values.should eq(400_000_u64)
      batches.first[0].should eq("a-1_0_1_0_2")
      batches.last[0].should eq("z-1_0_1_0")
      batches.each_cons(2) do |pair|
        left = pair[0]
        right = pair[1]
        right[5].should eq(left[5] + left[6])
      end
      batches.all? { |batch| batch[1].starts_with?(root) }.should be_true
    end
  end

  it "composes direct ZSTD, Delta/ZSTD, and multicolumn input fixtures" do
    {
      {MULTIPART_ZSTD_FIXTURE, "value"},
      {MULTIPART_DELTA_FIXTURE, "value"},
      {MULTIPART_MULTI_FIXTURE, "input"},
    }.each_with_index do |entry, index|
      source_path, column = entry
      with_multipart_root do |root|
        part_path = copy_multipart_part(root, "p-#{index}_0_0_0", source_path)
        expected = CrystalClick::WidePart.open(part_path, column).read_uint64
        source = CrystalClick::WidePartSet.open(root, column)
        actual = Array(UInt64).new
        source.scan_into(Slice(UInt64).new(73)) { |batch| actual.concat(batch.values.to_a) }
        actual.should eq(expected)
      end
    end
  end

  it "rejects same-partition inclusive overlap before any callback" do
    with_multipart_root do |root|
      copy_multipart_part(root, "same_0_1_0")
      copy_multipart_part(root, "same_1_2_0")
      callback_count = 0
      expect_raises(CrystalClick::InvalidPartError) do
        source = CrystalClick::WidePartSet.open(root, "value")
        source.scan_into(Slice(UInt64).new(17)) do |_batch|
          callback_count += 1
        end
      end
      callback_count.should eq(0)
    end
  end

  it "ignores unrelated entries but fails for a valid-name file and symlink" do
    with_multipart_root do |root|
      File.write(File.join(root, "README"), "ignored")
      Dir.mkdir(File.join(root, "tmp-build"))
      Dir.mkdir(File.join(root, "tmp_0_0_0"))
      copy_multipart_part(root, "p-1_0_0_0")
      source = CrystalClick::WidePartSet.open(root, "value")
      source.part_count.should eq(1)

      File.write(File.join(root, "p-2_0_0_0"), "not a part")
      expect_raises(CrystalClick::InvalidPartError) { CrystalClick::WidePartSet.open(root, "value") }
    end

    with_multipart_root do |root|
      target = copy_multipart_part(root, "p-1_0_0_0")
      File.symlink(target, File.join(root, "p-2_0_0_0"))
      expect_raises(CrystalClick::InvalidPartError) { CrystalClick::WidePartSet.open(root, "value") }
    end
  end

  it "fails closed for malformed part-like names, patch parts, symlink roots, and too many parts" do
    with_multipart_root do |root|
      File.write(File.join(root, "p-2_0_0_bad"), "not a part")
      expect_raises(CrystalClick::InvalidPartError) { CrystalClick::WidePartSet.open(root, "value") }
    end

    with_multipart_root do |root|
      Dir.mkdir(File.join(root, "patch-example_0_0_0"))
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePartSet.open(root, "value") }
    end

    with_multipart_root do |root|
      link = File.tempname("crystal-click-multipart-root-link")
      File.symlink(root, link)
      begin
        expect_raises(CrystalClick::InvalidPartError) { CrystalClick::WidePartSet.open(link, "value") }
      ensure
        File.delete(link)
      end
    end

    with_multipart_root do |root|
      (0..CrystalClick::WidePartSet::MAX_PARTS).each do |index|
        Dir.mkdir(File.join(root, "p-#{index}_#{index}_#{index}_0"))
      end
      expect_raises(CrystalClick::BoundsError) { CrystalClick::WidePartSet.open(root, "value") }
    end
  end

  it "opens all parts before the first callback and keeps scratch validation narrow" do
    with_multipart_root do |root|
      copy_multipart_part(root, "p-1_0_0_0")
      broken = copy_multipart_part(root, "p-2_1_1_0")
      File.write(File.join(broken, "count.txt"), "not-a-count\n")
      expect_raises(CrystalClick::Error) { CrystalClick::WidePartSet.open(root, "value") }
    end

    with_multipart_root do |root|
      copy_multipart_part(root, "p-1_0_0_0")
      source = CrystalClick::WidePartSet.open(root, "value")
      expect_raises(CrystalClick::BoundsError) { source.scan_into(Slice(UInt64).empty) { |_| } }
      expect_raises(CrystalClick::BoundsError) do
        source.scan_into(Slice(UInt64).new(4, read_only: true)) { |_| }
      end
    end
  end
end
