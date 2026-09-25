require "./spec_helper"

alias EmbeddedW7CandidateBatch = NamedTuple(
  part_index: Int32,
  part_name: String,
  mark_index: Int32,
  mark_row_offset: UInt64,
  part_row_offset: UInt64,
  source_row_offset: UInt64,
  keys: Array(UInt64),
  values: Array(String),
)

def with_embedded_w7_table(&)
  parent = File.tempname("crystal-click-embedded-w7-spec")
  Dir.mkdir(parent)
  begin
    table = CrystalClick::EmbeddedMergeTreeTable.create(File.join(parent, "table"), "pk", "value")
    yield table, parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

def embedded_w7_candidate_batches(
  table : CrystalClick::EmbeddedMergeTreeTable,
  lower_bound : UInt64? = nil,
  upper_bound : UInt64? = nil,
  columns : Array(String) = ["pk", "value"],
) : Array(EmbeddedW7CandidateBatch)
  batches = [] of EmbeddedW7CandidateBatch
  table.scan_uint64_pk_candidates(columns, lower_bound, upper_bound) do |batch|
    keys = batch.values_for("pk", UInt64).to_a
    values = columns.includes?("value") ? batch.strings_for("value").to_a : [] of String
    keys.size.should eq(values.size) if columns.includes?("value")
    batches << {
      part_index:        batch.part_index,
      part_name:         batch.part_name,
      mark_index:        batch.mark_index,
      mark_row_offset:   batch.mark_row_offset,
      part_row_offset:   batch.part_row_offset,
      source_row_offset: batch.source_row_offset,
      keys:              keys,
      values:            values,
    }
  end
  batches
end

def embedded_w7_typed_rows(table : CrystalClick::EmbeddedMergeTreeTable) : Array({UInt64, String})
  rows = [] of {UInt64, String}
  table.scan_typed(["pk", "value"]) do |batch|
    keys = batch.values_for("pk", UInt64)
    values = batch.strings_for("value")
    keys.size.should eq(values.size)
    keys.size.times { |index| rows << {keys[index], values[index]} }
  end
  rows
end

def embedded_w7_residual_rows(rows : Array({UInt64, String}), lower_bound : UInt64?, upper_bound : UInt64?) : Array({UInt64, String})
  rows.select do |row|
    (!lower_bound || row[0] >= lower_bound.not_nil!) &&
      (!upper_bound || row[0] <= upper_bound.not_nil!)
  end
end

def embedded_w7_candidate_residual_rows(
  batches : Array(EmbeddedW7CandidateBatch),
  lower_bound : UInt64?,
  upper_bound : UInt64?,
) : Array({UInt64, String})
  rows = [] of {UInt64, String}
  batches.each do |batch|
    batch[:keys].each_with_index do |key, index|
      next if lower_bound && key < lower_bound.not_nil!
      next if upper_bound && key > upper_bound.not_nil!
      rows << {key, batch[:values][index]}
    end
  end
  rows
end

def embedded_w7_read_uint64_le(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times do |byte_index|
    value |= bytes[offset + byte_index].to_u64 << (byte_index * 8)
  end
  value
end

def embedded_w8_encode_uint64s(values : Array(UInt64)) : Bytes
  Bytes.new(values.size * 8) do |offset|
    value = values[offset // 8]
    ((value >> ((offset % 8) * 8)) & 0xff_u64).to_u8
  end
end

describe CrystalClick::EmbeddedMergeTreeTable do
  it "returns inclusive residual matches from complete candidate marks for one- and two-sided bounds" do
    with_embedded_w7_table do |table, _parent|
      keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 5_u64, 5_u64, 5_u64, 6_u64, 7_u64, 8_u64, 9_u64]
      values = keys.map_with_index do |key, index|
        case index
        when 3 then ""
        when 4 then "nul\0payload"
        when 5 then "é"
        else        "row-#{index}-#{key}"
        end
      end
      table.insert(keys.to_unsafe.to_slice(keys.size), values.to_unsafe.to_slice(values.size), rows_per_mark: 3)

      full_rows = embedded_w7_typed_rows(table)
      exact = embedded_w7_candidate_batches(table, 5_u64, 5_u64)
      exact.map(&.[:mark_index]).should eq([1, 2])
      exact.map(&.[:mark_row_offset]).should eq([0_u64, 0_u64])
      exact.map(&.[:part_row_offset]).should eq([3_u64, 6_u64])
      exact.map(&.[:source_row_offset]).should eq([3_u64, 6_u64])
      exact.map(&.[:keys]).should eq([[4_u64, 5_u64, 5_u64], [5_u64, 5_u64, 6_u64]])
      exact.map(&.[:values]).should eq([values[3, 3], values[6, 3]])
      embedded_w7_candidate_residual_rows(exact, 5_u64, 5_u64).should eq(embedded_w7_residual_rows(full_rows, 5_u64, 5_u64))

      lower_only = embedded_w7_candidate_batches(table, 5_u64)
      lower_only.map(&.[:mark_index]).should eq([1, 2, 3])
      lower_only.each { |batch| batch[:keys].size.should eq(3) }
      embedded_w7_candidate_residual_rows(lower_only, 5_u64, nil).should eq(embedded_w7_residual_rows(full_rows, 5_u64, nil))

      upper_only = embedded_w7_candidate_batches(table, nil, 5_u64)
      upper_only.map(&.[:mark_index]).should eq([0, 1, 2])
      upper_only.each { |batch| batch[:keys].size.should eq(3) }
      embedded_w7_candidate_residual_rows(upper_only, nil, 5_u64).should eq(embedded_w7_residual_rows(full_rows, nil, 5_u64))
    end
  end

  it "preserves active-part order and offsets before merge, after merge, and after reclamation" do
    with_embedded_w7_table do |table, parent|
      first = table.insert([1_u64, 3_u64, 4_u64, 7_u64].to_unsafe.to_slice(4), ["a1", "a3", "a4", "a7"].to_unsafe.to_slice(4), rows_per_mark: 2)
      second = table.insert([2_u64, 3_u64, 6_u64, 8_u64].to_unsafe.to_slice(4), ["b2", "b3", "b6", "b8"].to_unsafe.to_slice(4), rows_per_mark: 2)

      before_merge = embedded_w7_candidate_batches(table, 3_u64, 6_u64)
      before_rows = embedded_w7_typed_rows(table)
      embedded_w7_candidate_residual_rows(before_merge, 3_u64, 6_u64).should eq(embedded_w7_residual_rows(before_rows, 3_u64, 6_u64))
      before_merge.map(&.[:part_name]).should eq([first, first, second, second])
      before_merge.map(&.[:part_index]).should eq([0, 0, 1, 1])
      before_merge.map(&.[:part_row_offset]).should eq([0_u64, 2_u64, 0_u64, 2_u64])
      before_merge.map(&.[:source_row_offset]).should eq([0_u64, 2_u64, 4_u64, 6_u64])

      merged = table.merge_adjacent(first, second, rows_per_mark: 2)
      after_merge = embedded_w7_candidate_batches(table, 3_u64, 6_u64)
      merged_rows = embedded_w7_typed_rows(table)
      embedded_w7_candidate_residual_rows(after_merge, 3_u64, 6_u64).should eq(embedded_w7_residual_rows(merged_rows, 3_u64, 6_u64))
      after_merge.map(&.[:part_name]).uniq.should eq([merged])
      after_merge.map(&.[:source_row_offset]).should eq([0_u64, 2_u64, 4_u64])

      table.reclaim_obsolete!
      after_reclaim = embedded_w7_candidate_batches(table, 3_u64, 6_u64)
      embedded_w7_candidate_residual_rows(after_reclaim, 3_u64, 6_u64).should eq(embedded_w7_residual_rows(embedded_w7_typed_rows(table), 3_u64, 6_u64))
      after_reclaim.map(&.[:part_name]).uniq.should eq([merged])
      File.exists?(File.join(parent, "table", "parts", first)).should be_false
      File.exists?(File.join(parent, "table", "parts", second)).should be_false
    end
  end

  it "returns no callbacks when a bounded range has no candidate marks and supports key-only selection" do
    with_embedded_w7_table do |table, _parent|
      keys = [1_u64, 2_u64, 3_u64, 4_u64]
      values = ["a", "b", "c", "d"]
      table.insert(keys.to_unsafe.to_slice(4), values.to_unsafe.to_slice(4), rows_per_mark: 2)

      embedded_w7_candidate_batches(table, 100_u64).should be_empty
      embedded_w7_candidate_batches(table, nil, 0_u64).should be_empty

      key_only = embedded_w7_candidate_batches(table, 4_u64, 4_u64, ["pk"])
      key_only.map(&.[:keys]).should eq([[3_u64, 4_u64]])
      key_only.map(&.[:values]).should eq([[] of String])
    end
  end

  it "keeps original source offsets when all leading-part marks are pruned" do
    with_embedded_w7_table do |table, _parent|
      first = table.insert([1_u64, 2_u64, 3_u64, 4_u64].to_unsafe.to_slice(4), ["a1", "a2", "a3", "a4"].to_unsafe.to_slice(4), rows_per_mark: 2)
      second = table.insert([5_u64, 6_u64, 7_u64, 8_u64].to_unsafe.to_slice(4), ["b5", "b6", "b7", "b8"].to_unsafe.to_slice(4), rows_per_mark: 2)

      batches = embedded_w7_candidate_batches(table, 7_u64, 7_u64)
      batches.map(&.[:part_name]).uniq.should eq([second])
      batches.map(&.[:part_index]).should eq([1, 1])
      batches.map(&.[:mark_index]).should eq([0, 1])
      batches.map(&.[:part_row_offset]).should eq([0_u64, 2_u64])
      batches.map(&.[:source_row_offset]).should eq([4_u64, 6_u64])
      embedded_w7_candidate_residual_rows(batches, 7_u64, 7_u64).should eq(embedded_w7_residual_rows(embedded_w7_typed_rows(table), 7_u64, 7_u64))
      table.part_paths.map { |path| File.basename(path) }.should eq([first, second])
    end
  end

  it "handles inclusive zero and UInt64 maximum bounds at index sentinel edges" do
    with_embedded_w7_table do |table, _parent|
      keys = [0_u64, 1_u64, UInt64::MAX]
      values = ["zero", "one", "maximum"]
      table.insert(keys.to_unsafe.to_slice(3), values.to_unsafe.to_slice(3), rows_per_mark: 1)
      full_rows = embedded_w7_typed_rows(table)

      zero = embedded_w7_candidate_batches(table, 0_u64, 0_u64)
      zero.map(&.[:mark_index]).should eq([0])
      embedded_w7_candidate_residual_rows(zero, 0_u64, 0_u64).should eq(embedded_w7_residual_rows(full_rows, 0_u64, 0_u64))

      maximum = embedded_w7_candidate_batches(table, UInt64::MAX, UInt64::MAX)
      maximum.map(&.[:mark_index]).should eq([1, 2])
      embedded_w7_candidate_residual_rows(maximum, UInt64::MAX, UInt64::MAX).should eq([{UInt64::MAX, "maximum"}])

      through_maximum = embedded_w7_candidate_batches(table, nil, UInt64::MAX)
      through_maximum.map(&.[:mark_index]).should eq([0, 1, 2])
      embedded_w7_candidate_residual_rows(through_maximum, nil, UInt64::MAX).should eq(full_rows)
    end
  end

  it "validates bounds and selections before callbacks, including on an empty table" do
    with_embedded_w7_table do |table, _parent|
      callback_seen = false

      expect_raises(CrystalClick::BoundsError) do
        table.scan_uint64_pk_candidates(["pk", "value"]) { callback_seen = true }
      end
      expect_raises(CrystalClick::BoundsError) do
        table.scan_uint64_pk_candidates(["pk"], 9_u64, 8_u64) { callback_seen = true }
      end
      expect_raises(CrystalClick::BoundsError) do
        table.scan_uint64_pk_candidates([] of String, 1_u64) { callback_seen = true }
      end
      expect_raises(CrystalClick::BoundsError) do
        table.scan_uint64_pk_candidates(["pk", "pk"], 1_u64) { callback_seen = true }
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_uint64_pk_candidates(["pk", "missing"], 1_u64) { callback_seen = true }
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_uint64_pk_candidates(["value"], 1_u64) { callback_seen = true }
      end

      table.scan_uint64_pk_candidates(["pk", "value"], 1_u64) { callback_seen = true }
      callback_seen.should be_false
    end
  end

  it "fails a malformed later active primary index before exposing any candidate callback" do
    with_embedded_w7_table do |table, parent|
      table.insert([1_u64, 2_u64].to_unsafe.to_slice(2), ["a", "b"].to_unsafe.to_slice(2), rows_per_mark: 1)
      later = table.insert([3_u64, 4_u64].to_unsafe.to_slice(2), ["c", "d"].to_unsafe.to_slice(2), rows_per_mark: 1)
      index_path = File.join(parent, "table", "parts", later, "primary.idx")
      File.open(index_path, "a") { |file| file.write_byte(0_u8) }

      callback_seen = false
      # Only the earlier part has a candidate mark for this exact range. The
      # later active index must still be opened and rejected before emission.
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_uint64_pk_candidates(["pk", "value"], 1_u64, 1_u64) { callback_seen = true }
      end
      callback_seen.should be_false
    end
  end

  it "rejects a same-size monotone false primary index before exposing candidate callbacks" do
    with_embedded_w7_table do |table, parent|
      part = table.insert([1_u64, 2_u64, 3_u64, 4_u64].to_unsafe.to_slice(4), ["a", "b", "c", "d"].to_unsafe.to_slice(4), rows_per_mark: 2)
      index_path = File.join(parent, "table", "parts", part, "primary.idx")
      original_index_contents = File.read(index_path)
      original_index = original_index_contents.to_slice
      original_index.size.should eq(24)
      [0, 8, 16].map { |offset| embedded_w7_read_uint64_le(original_index, offset) }.should eq([1_u64, 3_u64, 4_u64])
      baseline = embedded_w7_candidate_batches(table, 1_u64, 1_u64)
      baseline.map(&.[:mark_index]).should eq([0])
      baseline.map(&.[:keys]).should eq([[1_u64, 2_u64]])

      false_index = embedded_w8_encode_uint64s([10_u64, 11_u64, 12_u64])
      false_index.size.should eq(original_index.size)
      File.write(index_path, false_index)
      part_path = File.dirname(index_path)
      checksums = CrystalClick::PartChecksums.open(part_path)
      CrystalClick::PrimaryKeyIndex.open(part_path, 2, checksums).keys.should eq([10_u64, 11_u64, 12_u64])

      callback_count = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_uint64_pk_candidates(["pk", "value"], 1_u64, 1_u64) { callback_count += 1 }
      end
      callback_count.should eq(0)
    end
  end

  it "rejects a same-size monotone false later index before an earlier candidate callback" do
    with_embedded_w7_table do |table, parent|
      first = table.insert([1_u64, 2_u64].to_unsafe.to_slice(2), ["a", "b"].to_unsafe.to_slice(2), rows_per_mark: 1)
      later = table.insert([3_u64, 4_u64].to_unsafe.to_slice(2), ["c", "d"].to_unsafe.to_slice(2), rows_per_mark: 1)
      index_path = File.join(parent, "table", "parts", later, "primary.idx")
      original_index_contents = File.read(index_path)
      original_index = original_index_contents.to_slice
      original_index.size.should eq(24)
      [0, 8, 16].map { |offset| embedded_w7_read_uint64_le(original_index, offset) }.should eq([3_u64, 4_u64, 4_u64])

      baseline = embedded_w7_candidate_batches(table, 1_u64, 1_u64)
      baseline.map(&.[:part_name]).should eq([first])
      baseline.map(&.[:keys]).should eq([[1_u64]])

      false_index = embedded_w8_encode_uint64s([100_u64, 101_u64, 102_u64])
      false_index.size.should eq(original_index.size)
      File.write(index_path, false_index)

      callback_count = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_uint64_pk_candidates(["pk", "value"], 1_u64, 1_u64) { callback_count += 1 }
      end
      callback_count.should eq(0)
    end
  end

  it "does not materialize a pruned String mark" do
    with_embedded_w7_table do |table, parent|
      table.insert([1_u64, 2_u64, 3_u64, 4_u64].to_unsafe.to_slice(4), ["bad-a", "bad-b", "good-c", "good-d"].to_unsafe.to_slice(4), rows_per_mark: 2)
      part_path = File.join(parent, "table", "parts", "all_1_1_0")
      value_base = CrystalClick::StreamName.hash("value")
      mark_path = File.join(part_path, "#{value_base}.mrk2")
      data_path = File.join(part_path, "#{value_base}.bin")
      mark_bytes = Bytes.new(File.size(mark_path).to_i)
      File.open(mark_path) { |file| file.read_fully(mark_bytes) }
      compressed_offset = embedded_w7_read_uint64_le(mark_bytes, 0).to_i
      data_bytes = Bytes.new(File.size(data_path).to_i)
      File.open(data_path) { |file| file.read_fully(data_bytes) }
      original_data_size = data_bytes.size
      compressed_offset.should eq(0)
      data_bytes[compressed_offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE] = 0xff_u8
      File.open(data_path, "wb") { |file| file.write(data_bytes) }
      File.size(data_path).should eq(original_data_size)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_typed(["pk", "value"]) { |_| }
      end

      selected = embedded_w7_candidate_batches(table, 4_u64, 4_u64)
      selected.map(&.[:mark_index]).should eq([1])
      selected.map(&.[:keys]).should eq([[3_u64, 4_u64]])
      selected.map(&.[:values]).should eq([["good-c", "good-d"]])
    end
  end

  it "exposes an oversized selected granule as one callback" do
    with_embedded_w7_table do |table, _parent|
      keys = Array(UInt64).new(4_097) { |index| index.to_u64 }
      values = Array(String).new(keys.size, "payload")
      table.insert(keys.to_unsafe.to_slice(keys.size), values.to_unsafe.to_slice(values.size), rows_per_mark: 4_097)

      selected = embedded_w7_candidate_batches(table, 1_u64, 1_u64)
      selected.size.should eq(1)
      selected.first[:mark_index].should eq(0)
      selected.first[:keys].size.should eq(4_097)
      selected.first[:values].size.should eq(4_097)
      embedded_w7_candidate_residual_rows(selected, 1_u64, 1_u64).should eq([{1_u64, "payload"}])
    end
  end
end

describe CrystalClick::WidePartTable do
  it "rejects malformed typed candidate schedules before callbacks" do
    with_embedded_w7_table do |table, parent|
      table.insert([1_u64, 2_u64, 3_u64, 4_u64].to_unsafe.to_slice(4), ["a", "b", "c", "d"].to_unsafe.to_slice(4), rows_per_mark: 2)
      reader = CrystalClick::WidePartTable.open_selected_typed([File.join(parent, "table", "parts", "all_1_1_0")], ["pk", "value"])

      callback_seen = false
      expect_raises(CrystalClick::BoundsError) do
        reader.scan_typed_candidate_marks([] of Array(Int32)) { callback_seen = true }
      end
      callback_seen.should be_false

      expect_raises(CrystalClick::BoundsError) do
        reader.scan_typed_candidate_marks([[1, 0]]) { callback_seen = true }
      end
      callback_seen.should be_false

      expect_raises(CrystalClick::BoundsError) do
        reader.scan_typed_candidate_marks([[2]]) { callback_seen = true }
      end
      callback_seen.should be_false
    end
  end
end
