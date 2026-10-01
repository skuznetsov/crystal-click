require "./spec_helper"

private def pk_candidates_set_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def pk_candidates_read_var_uint(bytes : Bytes, cursor : Int32) : {UInt64, Int32}
  value = 0_u64
  index = 0
  loop do
    raise "truncated test checksum varUInt" if cursor >= bytes.size
    byte = bytes[cursor]
    cursor += 1
    payload = (byte & 0x7f).to_u64
    if index == 9
      raise "overflowing test checksum varUInt" if payload > 1 || (byte & 0x80) != 0
    end
    value |= payload << (index * 7)
    if (byte & 0x80) == 0
      raise "non-canonical test checksum varUInt" if index > 0 && value < (1_u64 << (index * 7))
      return {value, cursor}
    end
    index += 1
    raise "oversized test checksum varUInt" if index > 9
  end
end

private def pk_candidates_literal_lz4_frame(raw : Bytes) : Bytes
  raise "test checksum payload cannot be empty" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  4.times do |index|
    frame[header + 1 + index] = ((compressed_size >> (index * 8)) & 0xff).to_u8
    frame[header + 5 + index] = ((raw.size >> (index * 8)) & 0xff).to_u8
  end

  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  if raw.size < 15
    frame[cursor] = (raw.size << 4).to_u8
    cursor += 1
  else
    frame[cursor] = 0xf0_u8
    cursor += 1
    remaining = raw.size - 15
    while remaining >= 255
      frame[cursor] = 255_u8
      cursor += 1
      remaining -= 255
    end
    frame[cursor] = remaining.to_u8
    cursor += 1
  end
  raw.copy_to(frame[cursor, raw.size])
  hash = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  pk_candidates_set_u64(frame, 0, hash[0])
  pk_candidates_set_u64(frame, 8, hash[1])
  frame
end

private def pk_candidates_refresh_physical_hash(part_path : String, name : String, physical_bytes : Bytes) : Nil
  checksum_path = File.join(part_path, "checksums.txt")
  checksum_data = File.read(checksum_path)
  checksum_bytes = checksum_data.to_slice
  entries = CrystalClick::PartChecksums.parse(checksum_bytes)
  entry = entries.entry(name) || raise "missing test checksum entry for #{name}"
  raise "test hash rewrite must preserve physical size" unless entry.physical_size == physical_bytes.size.to_u64

  header_size = CrystalClick::PartChecksums::CHECKSUMS_HEADER.bytesize
  payload = CrystalClick::CompressedBlock.decode_all(
    checksum_bytes[header_size, checksum_bytes.size - header_size],
    CrystalClick::PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
    CrystalClick::PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES,
    CrystalClick::PartChecksums::MAX_PAYLOAD_BYTES
  ).dup
  count, cursor = pk_candidates_read_var_uint(payload, 0)
  found = false
  count.to_i.times do
    name_length, cursor = pk_candidates_read_var_uint(payload, cursor)
    raise "invalid test checksum entry name" if name_length > (payload.size - cursor).to_u64
    current_name = String.new(payload[cursor, name_length.to_i])
    cursor += name_length.to_i
    _, cursor = pk_candidates_read_var_uint(payload, cursor) # physical size
    raise "truncated test checksum physical hash" if cursor > payload.size - 16
    hash_offset = cursor
    cursor += 16
    flag = payload[cursor]? || raise "truncated test checksum entry"
    cursor += 1
    case flag
    when 0_u8
    when 1_u8
      _, cursor = pk_candidates_read_var_uint(payload, cursor) # uncompressed size
      raise "truncated test checksum uncompressed hash" if cursor > payload.size - 16
      cursor += 16
    else
      raise "invalid test checksum compression flag"
    end

    if current_name == name
      hash = CrystalClick::CityHashV1.file_hash(physical_bytes)
      pk_candidates_set_u64(payload, hash_offset, hash[0])
      pk_candidates_set_u64(payload, hash_offset + 8, hash[1])
      found = true
    end
  end
  raise "trailing test checksum payload" unless cursor == payload.size
  raise "test checksum entry was not found" unless found

  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(pk_candidates_literal_lz4_frame(payload))
  File.write(checksum_path, output.to_slice)
end

module OfflinePKCandidateSpecSupport
  DB_UUID    = "a1666606-4ca2-4afb-9900-000000000001"
  TABLE_UUID = "a1666606-4ca2-4afb-9900-000000000002"
  ORACLE     = File.expand_path("../test/fixtures/public/wide_u64_pk_candidates_oracle.tsv", __DIR__)
  LARGE_WIDE = File.expand_path("../test/fixtures/public/wide_two_uint64/part", __DIR__)

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

describe CrystalClick::WidePartTable do
  it "keeps scan_candidate_marks on one complete 8,192-row granule with original offsets" do
    root = File.tempname("crystal-click-pk-candidate-large-granule-spec")
    Dir.mkdir(root)
    begin
      part_path = File.join(root, "all_1_1_0")
      FileUtils.cp_r(OfflinePKCandidateSpecSupport::LARGE_WIDE, part_path)
      reader = CrystalClick::WidePartTable.open_selected([part_path], ["left", "right"])
      reader.part_mark_row_counts.should eq([[8192_u64, 8192_u64, 617_u64]])

      callbacks = 0
      reader.scan_candidate_marks([[1]]) do |batch|
        callbacks += 1
        left = batch.values_for("left")
        right = batch.values_for("right")
        left.size.should eq(8192)
        left.size.should be > CrystalClick::WidePartTable::DEFAULT_BATCH_ROWS
        right.size.should eq(left.size)
        batch.mark_index.should eq(1)
        batch.mark_row_offset.should eq(0_u64)
        batch.part_row_offset.should eq(8192_u64)
        batch.source_row_offset.should eq(8192_u64)
        left.first.should eq(8192_u64)
        left.last.should eq(16_383_u64)
        right.first.should eq(24_583_u64)
        right.last.should eq(49_156_u64)
      end
      callbacks.should eq(1)
    ensure
      FileUtils.rm_rf(root)
    end
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
        table.primary_key_column.should eq("pk")
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

  it "exhaustively matches small inclusive and one-sided bounds to the ClickHouse oracle" do
    cases = [] of {UInt64?, UInt64?}
    (0_u64..5_u64).each do |bound|
      cases << {bound, nil}
      cases << {nil, bound}
      (bound..5_u64).each do |upper|
        cases << {bound, upper}
      end
    end
    cases.size.should eq(33)
    oracle = OfflinePKCandidateSpecSupport.oracle_rows

    ["raw", "cidx"].each do |variant|
      OfflinePKCandidateSpecSupport.with_table(variant) do |table, _, _|
        cases.each do |lower, upper|
          filtered = [] of {UInt64, UInt64}
          table.scan_uint64_pk_candidates(
            ["pk", "value"],
            lower_bound: lower,
            upper_bound: upper
          ) do |batch|
            keys = batch.values_for("pk")
            values = batch.values_for("value")
            keys.each_with_index do |key, row|
              next if lower && key < lower
              next if upper && key > upper
              filtered << {key, values[row]}
            end
          end

          filtered.should eq(oracle.select { |key, _| (!lower || key >= lower) && (!upper || key <= upper) })
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
      table.primary_key_column.should be_nil
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
      pk_candidates_refresh_physical_hash(part_path, "primary.idx", malformed)
      expect_raises(CrystalClick::CorruptPartError, "primary index keys are not monotone") do
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
      checksum_path = File.join(part_path, "checksums.txt")
      original = writable_file_bytes(compressed_path)
      original_checksums = writable_file_bytes(checksum_path)
      bytes = original.dup
      bytes[16] = 0x81_u8
      File.write(compressed_path, bytes)
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError, "primary index file hash does not match checksums.txt") do
        table.scan_uint64_pk_candidates(["pk"], lower_bound: 0_u64) { |_| callbacks += 1 }
      end
      callbacks.should eq(0)

      pk_candidates_refresh_physical_hash(part_path, "primary.cidx", bytes)
      expect_raises(CrystalClick::UnsupportedFormatError, "unsupported ClickHouse compression method") do
        table.scan_uint64_pk_candidates(["pk"], lower_bound: 0_u64) { |_| callbacks += 1 }
      end
      callbacks.should eq(0)

      File.write(compressed_path, original)
      File.write(checksum_path, original_checksums)
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
