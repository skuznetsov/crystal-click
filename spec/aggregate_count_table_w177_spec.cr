require "./spec_helper"

private class W177CountTableGuardFixtures
  def self.with_pair(stock_root : String, label : String, & : String, Array(String) ->)
    root = File.tempname("crystal-click-w177-table-guards")
    Dir.mkdir(root)
    parts = ["all_1_1_0", "all_2_2_0"].map do |name|
      path = File.join(root, name)
      FileUtils.cp_r(File.join(stock_root, "part-#{label}"), path)
      path
    end
    yield root, parts
  ensure
    FileUtils.rm_rf(root) if root && Dir.exists?(root)
  end

  def self.write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
    8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
  end

  def self.write_varuint(io : IO, value : UInt64) : Nil
    remaining = value
    while remaining >= 0x80_u64
      io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
      remaining >>= 7
    end
    io.write_byte(remaining.to_u8)
  end

  def self.write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
    8.times { |byte| io.write_byte(((hash[0] >> (byte * 8)) & 0xff_u64).to_u8) }
    8.times { |byte| io.write_byte(((hash[1] >> (byte * 8)) & 0xff_u64).to_u8) }
  end

  def self.lz4_literal_frame(bytes : Bytes) : Bytes
    compressed = IO::Memory.new
    if bytes.size < 15
      compressed.write_byte((bytes.size << 4).to_u8)
    else
      compressed.write_byte(0xf0_u8)
      remainder = bytes.size - 15
      while remainder >= 255
        compressed.write_byte(255_u8)
        remainder -= 255
      end
      compressed.write_byte(remainder.to_u8)
    end
    compressed.write(bytes)
    payload = compressed.to_slice

    frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload.size, 0_u8)
    header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
    frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
    compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload.size
    4.times { |byte| frame[header + 1 + byte] = ((compressed_size >> (byte * 8)) & 0xff).to_u8 }
    4.times { |byte| frame[header + 5 + byte] = ((bytes.size >> (byte * 8)) & 0xff).to_u8 }
    payload.copy_to(frame[CrystalClick::CompressedBlock::FRAME_HEADER_SIZE, payload.size])
    checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
    write_u64(frame, 0, checksum[0])
    write_u64(frame, 8, checksum[1])
    frame
  end

  def self.refresh_checksums(part : String, renamed_prefix : {String, String}? = nil) : Nil
    parsed = CrystalClick::PartChecksums.open(part)
    entries = parsed.entries.keys.map do |old_name|
      new_name = old_name
      if prefix = renamed_prefix
        if old_name.starts_with?(prefix[0])
          new_name = prefix[1] + old_name[prefix[0].bytesize, old_name.bytesize - prefix[0].bytesize]
        end
      end
      {old_name, new_name}
    end.sort_by(&.[1])

    payload = IO::Memory.new
    write_varuint(payload, entries.size.to_u64)
    entries.each do |old_name, new_name|
      file_bytes = File.read(File.join(part, new_name)).to_slice
      entry = parsed.entries[old_name]
      write_varuint(payload, new_name.bytesize.to_u64)
      payload.write(new_name.to_slice)
      write_varuint(payload, file_bytes.size.to_u64)
      write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
      if entry.compressed
        raw = CrystalClick::CompressedBlock.decode_all(file_bytes)
        payload.write_byte(1_u8)
        write_varuint(payload, raw.size.to_u64)
        write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
      else
        payload.write_byte(0_u8)
      end
    end

    output = IO::Memory.new
    output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    output.write(lz4_literal_frame(payload.to_slice))
    File.write(File.join(part, "checksums.txt"), output.to_slice)
  end

  def self.redistribute_key_marks(part : String) : Nil
    marks_path = File.join(part, "#{CrystalClick::StreamName.hash("pk")}.mrk2")
    marks = File.read(marks_path).to_slice.dup
    mark_size = CrystalClick::WidePart::MARK_SIZE
    rows = [1_u64, 2_u64, 2_u64]
    offsets = [0_u64, 8_u64, 24_u64]
    rows.each_with_index do |mark_rows, index|
      write_u64(marks, index * mark_size + 8, offsets[index])
      write_u64(marks, index * mark_size + 16, mark_rows)
    end
    write_u64(marks, 3 * mark_size + 8, 40_u64)
    File.write(marks_path, marks)
    refresh_checksums(part)
  end

  def self.rename_key(part : String, from : String = "pk", to : String = "id") : Nil
    old_base = CrystalClick::StreamName.hash(from)
    new_base = CrystalClick::StreamName.hash(to)
    {"columns.txt", "columns_substreams.txt"}.each do |name|
      path = File.join(part, name)
      text = File.read(path)
      text = text.gsub("`#{from}`", "`#{to}`")
      text = text.gsub("\t#{from}\n", "\t#{to}\n")
      File.write(path, text)
    end
    serialization_path = File.join(part, "serialization.json")
    File.write(serialization_path, File.read(serialization_path).gsub("\"#{from}\"", "\"#{to}\""))

    {".bin", ".mrk2"}.each do |suffix|
      File.rename(File.join(part, "#{old_base}#{suffix}"), File.join(part, "#{new_base}#{suffix}"))
    end
    refresh_checksums(part, {old_base, new_base})
  end
end

describe "W177 Count table admission guards" do
  it "bounds its fixed accounting charge before materialization" do
    owner = CrystalClick::WideAggregateCountTableMaterializer
    owner.materialization_charge(0_u64).should eq(0_u64)
    owner.preflight(2_u64, 128_u64).should eq(128_u64)
    expect_raises(CrystalClick::CorruptPartError) { owner.preflight(2_u64, 127_u64) }
    expect_raises(CrystalClick::CorruptPartError) { owner.materialization_charge(UInt64::MAX) }
  end

  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  {
    CrystalClick::BinaryDataType.aggregate_count,
    CrystalClick::BinaryDataType.aggregate_count(uint64),
    CrystalClick::BinaryDataType.aggregate_count(CrystalClick::BinaryDataType.nullable(uint64)),
  }.each do |type|
    it "reads paired library #{type.name} parts with different mark grids" do
      root = File.tempname("crystal-click-w177-library-parts")
      Dir.mkdir(root)
      begin
        keys = [7_u64, 13_u64, 22_u64, 31_u64, 50_u64]
        counts = [0_u64, 127_u64, 128_u64, 16_384_u64, UInt64::MAX]
        values = counts.map { |count| CrystalClick::BinaryValue.aggregate_count_state(type, count) }
        parts = [1, 3].map_with_index do |rows_per_mark, index|
          destination = File.join(root, "all_#{index + 1}_#{index + 1}_0")
          CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
            destination, "pk", keys.to_unsafe.to_slice(keys.size), "c", type,
            values.to_unsafe.to_slice(values.size), rows_per_mark: rows_per_mark
          )
        end
        table = CrystalClick::WidePartTable.open_selected_typed(parts, ["c"])
        observed = [] of UInt64
        table.scan_typed(batch_rows: 2) do |batch|
          batch.column_names.should eq(["c"])
          batch.aggregate_count_states_for("c", type).each do |state|
            state.type.should eq(type)
            observed << state.count_state
          end
        end
        observed.should eq(counts * 2)
        window = [] of UInt64
        table.scan_typed_window(4_u64, 3) do |batch|
          batch.aggregate_count_states_for("c", type).each { |state| window << state.count_state }
        end
        window.should eq([UInt64::MAX, 0_u64, 127_u64])
        candidate = [] of UInt64
        table.scan_typed_candidate_marks([[4], [1]]) do |batch|
          batch.aggregate_count_states_for("c", type).each { |state| candidate << state.count_state }
        end
        candidate.should eq([UInt64::MAX, 16_384_u64, UInt64::MAX])
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  if stock_root = ENV["W177_STOCK_ROOT"]?
    it "does not expose the hidden sibling and enforces the exact nominal accessor descriptor" do
      W177CountTableGuardFixtures.with_pair(stock_root, "none") do |_root, parts|
        table = CrystalClick::WidePartTable.open_selected_typed([parts[0]], ["c"])
        callbacks = 0
        expect_raises(CrystalClick::UnsupportedFormatError) do
          table.scan_typed do |batch|
            callbacks += 1
            batch.column_names.should eq(["c"])
            batch.aggregate_count_states_for("c", CrystalClick::BinaryDataType.aggregate_count(CrystalClick::BinaryDataType.primitive("UInt64")))
          end
        end
        callbacks.should eq(1)
      end
    end

    it "rejects installer states with the wrong nominal descriptor or row count" do
      W177CountTableGuardFixtures.with_pair(stock_root, "none") do |_root, parts|
        table = CrystalClick::WidePartTable.open_selected_typed([parts[0]], ["c"])
        type = CrystalClick::BinaryDataType.aggregate_count
        wrong_type = CrystalClick::BinaryDataType.aggregate_count(CrystalClick::BinaryDataType.primitive("UInt64"))
        callbacks = 0
        table.scan_typed do |batch|
          callbacks += 1
          wrong_values = [CrystalClick::BinaryValue.aggregate_count_state(wrong_type, 17_u64)]
          expect_raises(CrystalClick::CorruptPartError) do
            batch.install_aggregate_count_states("c", wrong_values.to_unsafe.to_slice(wrong_values.size), 1)
          end

          short_values = [CrystalClick::BinaryValue.aggregate_count_state(type, 17_u64)]
          expect_raises(CrystalClick::CorruptPartError) do
            batch.install_aggregate_count_states("c", short_values.to_unsafe.to_slice(short_values.size), 2)
          end
        end
        callbacks.should eq(3)
      end
    end

    it "rejects different valid UInt64 sibling identities across parts before callbacks" do
      W177CountTableGuardFixtures.with_pair(stock_root, "none") do |_root, parts|
        W177CountTableGuardFixtures.rename_key(parts[1])
        # Prove the renamed sibling remains a valid standalone UInt64 lane;
        # rejection must come from the cross-part identity guard, not damage.
        CrystalClick::WidePart.open_typed(parts[1], "id").read_uint64_mark_range("id", 0, 3).should eq(
          [7_u64, 13_u64, 22_u64, 31_u64, 50_u64]
        )
        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          table = CrystalClick::WidePartTable.open_selected_typed(parts, ["c"])
          table.scan_typed { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      end
    end

    it "eagerly rejects hidden sibling mark-axis drift in a later Count-only part" do
      W177CountTableGuardFixtures.with_pair(stock_root, "none") do |_root, parts|
        W177CountTableGuardFixtures.redistribute_key_marks(parts[1])
        key = CrystalClick::WidePart.open_typed(parts[1], "pk")
        key.mark_row_counts.should eq([1_u64, 2_u64, 2_u64])
        key.read_uint64_mark_range("pk", 0, 3).should eq([7_u64, 13_u64, 22_u64, 31_u64, 50_u64])
        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          table = CrystalClick::WidePartTable.open_selected_typed(parts, ["c"])
          table.scan_typed { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      end
    end

    it "continues to refuse Count selected from an explicit projection" do
      W177CountTableGuardFixtures.with_pair(stock_root, "none") do |_root, parts|
        FileUtils.cp_r(File.join(stock_root, "part-none"), File.join(parts[0], "p.proj"))
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePartTable.open_selected_projection_typed([parts[0]], "p", ["c"])
        end
      end
    end
  end
end
