require "./spec_helper"

module OfflinePKCandidateSpecSupport
  DB_UUID    = "a1666606-4ca2-4afb-9900-000000000001"
  TABLE_UUID = "a1666606-4ca2-4afb-9900-000000000002"
  ORACLE     = File.expand_path("../test/fixtures/public/wide_u64_pk_candidates_oracle.tsv", __DIR__)

  def self.with_table(
    index_variant : String = "raw",
    tail : String = "ORDER BY pk",
    column_definitions : String = "`pk` UInt64,\n    `value` UInt64",
    &block : CrystalClick::OfflineTable, String, String ->
  )
    root = File.tempname("crystal-click-pk-candidates-spec")
    Dir.mkdir(root)
    database_path = File.join(root, "store", DB_UUID[0, 3], DB_UUID)
    table_path = File.join(root, "store", TABLE_UUID[0, 3], TABLE_UUID)
    FileUtils.mkdir_p(File.join(root, "metadata"))
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{DB_UUID}'\nENGINE = Atomic\n")
    File.write(File.join(database_path, "events.sql"), <<-DDL)
      ATTACH TABLE _ UUID '#{TABLE_UUID}'
      (
          #{column_definitions}
      )
      ENGINE = MergeTree
      #{tail}
      DDL
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    fixture = File.expand_path("../test/fixtures/public/wide_u64_pk_#{index_variant}/part", __DIR__)
    part_path = File.join(table_path, "all_1_1_0")
    FileUtils.cp_r(fixture, part_path)

    yield CrystalClick::OfflineCatalog.open(root).table("lab", "events"), root, table_path
  ensure
    FileUtils.rm_rf(root) if root
  end

  def self.oracle_rows : Array({UInt64, UInt64})
    File.read_lines(ORACLE).map do |line|
      key, value = line.split('\t')
      {key.to_u64, value.to_u64}
    end
  end

  class CallbackError < Exception
  end

  def self.encode_uint64s(values : Array(UInt64)) : Bytes
    bytes = Bytes.new(values.size * 8, 0_u8)
    values.each_with_index do |value, row|
      8.times { |byte| bytes[row * 8 + byte] = (value >> (byte * 8)).to_u8 }
    end
    bytes
  end
end

describe CrystalClick::OfflineTable do
  it "matches the independent ClickHouse oracle using conservative raw and compressed candidates" do
    cases = [
      {0_u64, 0_u64, [0, 1]},
      {3_u64, nil, [3, 4]},
      {nil, 0_u64, [0, 1]},
      {1_u64, 1_u64, [1, 2]},
      {0_u64, 4_u64, [0, 1, 2, 3, 4]},
      {5_u64, 6_u64, [] of Int32},
    ] of {UInt64?, UInt64?, Array(Int32)}
    oracle = OfflinePKCandidateSpecSupport.oracle_rows

    ["raw", "cidx"].each do |variant|
      OfflinePKCandidateSpecSupport.with_table(variant) do |table, _, _|
        cases.each do |lower, upper, expected_marks|
          marks = [] of Int32
          part_offsets = [] of UInt64
          source_offsets = [] of UInt64
          mark_offsets = [] of UInt64
          candidate_row_count = 0
          filtered = [] of {UInt64, UInt64}

          table.scan_uint64_pk_candidates(
            ["pk", "value"],
            lower_bound: lower,
            upper_bound: upper
          ) do |batch|
            marks << batch.mark_index
            part_offsets << batch.part_row_offset
            source_offsets << batch.source_row_offset
            mark_offsets << batch.mark_row_offset
            keys = batch.values_for("pk")
            values = batch.values_for("value")
            # Candidate callbacks expose a whole physical granule, never a
            # legacy 4,096-row slice. The caller must retain this residual.
            candidate_row_count += keys.size
            keys.each_with_index do |key, row|
              next if lower && key < lower
              next if upper && key > upper
              filtered << {key, values[row]}
            end
          end

          marks.should eq(expected_marks)
          part_offsets.should eq(expected_marks.map { |mark| mark.to_u64 * 8_u64 })
          source_offsets.should eq(part_offsets)
          mark_offsets.should eq(Array(UInt64).new(expected_marks.size, 0_u64))
          filtered.should eq(oracle.select { |key, _| (!lower || key >= lower) && (!upper || key <= upper) })
          candidate_row_count.should eq(expected_marks.size * 8)
          if lower == 0_u64 && upper == 0_u64
            expected_marks.size.should be < 5 # full scan would read all five data marks
          end
        end
      end
    end
  end

  it "admits a partitioned table with ClickHouse's explicit same-column primary-key syntax" do
    [
      "PARTITION BY tuple() PRIMARY KEY pk ORDER BY pk SETTINGS index_granularity = 8",
      "PARTITION BY tuple() ORDER BY pk PRIMARY KEY pk SETTINGS index_granularity = 8",
    ].each do |tail|
      OfflinePKCandidateSpecSupport.with_table("raw", tail) do |table, _, _|
        marks = [] of Int32
        table.scan_uint64_pk_candidates(["pk"], lower_bound: 3_u64) { |batch| marks << batch.mark_index }
        marks.should eq([3, 4])
      end
    end
  end

  it "keeps generic scans available for tuple keys while refusing PK candidate inference" do
    OfflinePKCandidateSpecSupport.with_table("raw", "ORDER BY tuple()") do |table, _, _|
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_uint64_pk_candidates(["pk"], lower_bound: 0_u64) { |_| callbacks += 1 }
      end
      callbacks.should eq(0)

      rows = 0
      table.scan_uint64(["pk", "value"]) { |batch| rows += batch.values_for("pk").size }
      rows.should eq(40)
    end
  end

  it "fails closed on unsupported or unparsed key suffixes" do
    [
      "ORDER BY pk DESC",
      "ORDER BY (pk, value)",
      "ORDER BY tuple()",
      "PRIMARY KEY value ORDER BY pk",
      "ORDER BY pk ORDER BY pk",
      "ORDER BY pk JUNK",
      "ORDER BY pk SETTINGS index_granularity = 8192 JUNK",
      "ORDER BY pk TTL value + INTERVAL 1 DAY",
    ].each do |tail|
      OfflinePKCandidateSpecSupport.with_table("raw", tail) do |table, _, _|
        callbacks = 0
        expect_raises(CrystalClick::UnsupportedFormatError) do
          table.scan_uint64_pk_candidates(["pk"], lower_bound: 0_u64) { |_| callbacks += 1 }
        end
        callbacks.should eq(0)
      end
    end

    OfflinePKCandidateSpecSupport.with_table(
      "raw",
      "ORDER BY pk",
      "`pk` UInt64 ALIAS value,\n    `value` UInt64"
    ) do |table, _, _|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_uint64_pk_candidates(["pk"], lower_bound: 0_u64) { |_| }
      end
    end
  end

  it "validates arguments and requires the key among selected exact UInt64 columns" do
    OfflinePKCandidateSpecSupport.with_table do |table, _, _|
      expect_raises(CrystalClick::BoundsError) { table.scan_uint64_pk_candidates(["pk"]) { |_| } }
      expect_raises(CrystalClick::BoundsError) do
        table.scan_uint64_pk_candidates(["pk"], lower_bound: 2_u64, upper_bound: 1_u64) { |_| }
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_uint64_pk_candidates(["value"], lower_bound: 0_u64) { |_| }
      end
      expect_raises(CrystalClick::BoundsError) do
        table.scan_uint64_pk_candidates(["pk", "pk"], lower_bound: 0_u64) { |_| }
      end
    end
  end

  it "rejects selected columns whose table DDL type is not exactly UInt64" do
    OfflinePKCandidateSpecSupport.with_table(
      "raw",
      "ORDER BY pk",
      "`pk` UInt64,\n    `value` UInt32"
    ) do |table, _, _|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_uint64_pk_candidates(["pk", "value"], lower_bound: 0_u64) { |_| }
      end
    end
  end

  it "preflights monotonicity, checksummed size, symlinks, and ambiguous encodings before callbacks" do
    OfflinePKCandidateSpecSupport.with_table do |table, _, table_path|
      part_path = File.join(table_path, "all_1_1_0")
      index_path = File.join(part_path, "primary.idx")
      callbacks = 0

      malformed = OfflinePKCandidateSpecSupport.encode_uint64s([0_u64, 2_u64, 1_u64, 2_u64, 3_u64, 4_u64])
      File.write(index_path, malformed)
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_uint64_pk_candidates(["pk"], lower_bound: 0_u64) { |_| callbacks += 1 }
      end
      callbacks.should eq(0)

      File.write(index_path, OfflinePKCandidateSpecSupport.encode_uint64s([0_u64, 0_u64, 1_u64, 2_u64, 3_u64, 4_u64]))
      File.write(index_path, "short")
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_uint64_pk_candidates(["pk"], lower_bound: 0_u64) { |_| callbacks += 1 }
      end
      callbacks.should eq(0)

      File.delete(index_path)
      File.symlink("checksums.txt", index_path)
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_uint64_pk_candidates(["pk"], lower_bound: 0_u64) { |_| callbacks += 1 }
      end
      callbacks.should eq(0)
    end

    OfflinePKCandidateSpecSupport.with_table("cidx") do |table, _, table_path|
      part_path = File.join(table_path, "all_1_1_0")
      compressed_path = File.join(part_path, "primary.cidx")
      original = writable_file_bytes(compressed_path)
      bytes = original.dup
      bytes[16] = 0x81_u8
      File.write(compressed_path, bytes)
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_uint64_pk_candidates(["pk"], lower_bound: 0_u64) { |_| callbacks += 1 }
      end
      callbacks.should eq(0)

      File.write(compressed_path, original)
      FileUtils.cp(compressed_path, File.join(part_path, "primary.idx"))
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_uint64_pk_candidates(["pk"], lower_bound: 0_u64) { |_| callbacks += 1 }
      end
      callbacks.should eq(0)
    end

    OfflinePKCandidateSpecSupport.with_table do |table, _, table_path|
      File.delete(File.join(table_path, "all_1_1_0", "primary.idx"))
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_uint64_pk_candidates(["pk"], lower_bound: 0_u64) { |_| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end

  it "preserves part and source offsets when earlier marks are pruned across parts" do
    OfflinePKCandidateSpecSupport.with_table do |table, root, table_path|
      first_part = File.join(table_path, "all_1_1_0")
      FileUtils.cp_r(first_part, File.join(table_path, "all_2_2_0"))
      refreshed = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      part_indices = [] of Int32
      marks = [] of Int32
      source_offsets = [] of UInt64

      refreshed.scan_uint64_pk_candidates(["pk"], lower_bound: 3_u64) do |batch|
        part_indices << batch.part_index
        marks << batch.mark_index
        source_offsets << batch.source_row_offset
      end

      part_indices.should eq([0, 0, 1, 1])
      marks.should eq([3, 4, 3, 4])
      source_offsets.should eq([24_u64, 32_u64, 64_u64, 72_u64])
    end
  end

  it "propagates callback exceptions without wrapping them" do
    OfflinePKCandidateSpecSupport.with_table do |table, _, _|
      expect_raises(OfflinePKCandidateSpecSupport::CallbackError, "caller stop") do
        table.scan_uint64_pk_candidates(["pk"], lower_bound: 0_u64) do |_batch|
          raise OfflinePKCandidateSpecSupport::CallbackError.new("caller stop")
        end
      end
    end
  end

  it "preflights every part's index before exposing any part callback" do
    OfflinePKCandidateSpecSupport.with_table do |table, root, table_path|
      first_part = File.join(table_path, "all_1_1_0")
      second_part = File.join(table_path, "all_2_2_0")
      FileUtils.cp_r(first_part, second_part)
      bad_index = OfflinePKCandidateSpecSupport.encode_uint64s([0_u64, 2_u64, 1_u64, 2_u64, 3_u64, 4_u64])
      File.write(File.join(second_part, "primary.idx"), bad_index)
      refreshed = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      callbacks = 0

      expect_raises(CrystalClick::CorruptPartError) do
        refreshed.scan_uint64_pk_candidates(["pk"], lower_bound: 0_u64) { |_| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end
end
