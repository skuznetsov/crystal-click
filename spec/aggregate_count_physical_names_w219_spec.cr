require "./spec_helper"
require "file_utils"

private def w219_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w219_write_var_uint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w219_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |index| io.write_byte(((hash[0] >> (index * 8)) & 0xff_u64).to_u8) }
  8.times { |index| io.write_byte(((hash[1] >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w219_encode_lz4_frame(raw : Bytes) : Bytes
  raise ArgumentError.new("W219 cannot encode an empty LZ4 block") if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  4.times { |index| frame[header + 1 + index] = ((compressed_size >> (index * 8)) & 0xff).to_u8 }
  4.times { |index| frame[header + 5 + index] = ((raw.size >> (index * 8)) & 0xff).to_u8 }

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
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  w219_write_u64(frame, 0, checksum[0])
  w219_write_u64(frame, 8, checksum[1])
  frame
end

private def w219_refresh_checksums(part : String, file_renames : Hash(String, String) = Hash(String, String).new) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  records = [] of Tuple(String, CrystalClick::PartChecksums::Entry, String)
  parsed.entries.each do |old_name, entry|
    records << {file_renames[old_name]? || old_name, entry, old_name}
  end
  records.sort_by! { |record| record[0] }
  raise "W219 checksum rename produced duplicate names" unless records.map { |record| record[0] }.uniq.size == records.size

  payload = IO::Memory.new
  w219_write_var_uint(payload, records.size.to_u64)
  records.each do |new_name, entry, _old_name|
    bytes = File.read(File.join(part, new_name)).to_slice
    w219_write_var_uint(payload, new_name.bytesize.to_u64)
    payload.write(new_name.to_slice)
    w219_write_var_uint(payload, bytes.size.to_u64)
    w219_write_hash(payload, CrystalClick::CityHashV1.file_hash(bytes))
    if entry.compressed
      raw = CrystalClick::CompressedBlock.decode_all(bytes)
      payload.write_byte(1_u8)
      w219_write_var_uint(payload, raw.size.to_u64)
      w219_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end

  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(w219_encode_lz4_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), output.to_slice)
end

private def w219_stock_serializer(key_name : String, row_count : Int32) : String
  String.build do |json|
    json << "{\"columns\":[{\"exact_num_defaults\":true,\"kind\":\"Default\",\"name\":\""
    json << key_name
    json << "\",\"num_defaults\":0,\"num_rows\":" << row_count << "}],"
    json << "\"propagate_types_serialization_versions_to_nested_types\":true,"
    json << "\"types_serialization_versions\":{\"string\":1},\"version\":1}"
  end
end

private def w219_rebind_to_stock_names!(part : String, key_name : String, count_name : String, row_count : Int32) : Nil
  key_old_base = CrystalClick::StreamName.hash("pk")
  count_old_base = CrystalClick::StreamName.hash("c")
  key_new_base = CrystalClick::StreamName.hash(CrystalClick::PhysicalStreamName.escape(key_name))
  count_new_base = CrystalClick::StreamName.hash(CrystalClick::PhysicalStreamName.escape(count_name))
  raise "W219 key and Count physical names collided" if key_new_base == count_new_base

  renames = Hash(String, String).new
  [{key_old_base, key_new_base}, {count_old_base, count_new_base}].each do |old_base, new_base|
    {".bin", ".mrk2"}.each do |extension|
      old_name = "#{old_base}#{extension}"
      new_name = "#{new_base}#{extension}"
      File.rename(File.join(part, old_name), File.join(part, new_name))
      renames[old_name] = new_name
    end
  end

  count_type = CrystalClick::BinaryDataType.aggregate_count.name
  File.write(
    File.join(part, "columns.txt"),
    "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{count_name}` #{count_type}\n",
  )
  File.write(
    File.join(part, "columns_substreams.txt"),
    "columns substreams version: 1\n2 columns:\n" +
    "1 substreams for column `#{key_name}`:\n\t#{CrystalClick::PhysicalStreamName.escape(key_name)}\n" +
    "1 substreams for column `#{count_name}`:\n\t#{CrystalClick::PhysicalStreamName.escape(count_name)}\n",
  )
  File.write(File.join(part, "serialization.json"), w219_stock_serializer(key_name, row_count))
  w219_refresh_checksums(part, renames)
end

private def w219_rename_stream_files!(part : String, physical_name : String, new_base : String) : Nil
  old_base = CrystalClick::StreamName.hash(physical_name)
  raise "W219 stream rename did not change its file base" if old_base == new_base
  renames = Hash(String, String).new
  {".bin", ".mrk2"}.each do |extension|
    old_name = "#{old_base}#{extension}"
    new_name = "#{new_base}#{extension}"
    File.rename(File.join(part, old_name), File.join(part, new_name))
    renames[old_name] = new_name
  end
  w219_refresh_checksums(part, renames)
end

private def w219_rewrite_substreams!(part : String, key_name : String, count_name : String, key_stream : String, count_stream : String) : Nil
  File.write(
    File.join(part, "columns_substreams.txt"),
    "columns substreams version: 1\n2 columns:\n" +
    "1 substreams for column `#{key_name}`:\n\t#{key_stream}\n" +
    "1 substreams for column `#{count_name}`:\n\t#{count_stream}\n",
  )
end

private def w219_count_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.aggregate_count
end

private def w219_write_parent(root : String) : String
  path = File.join(root, "all_1_1_0")
  keys = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64, 60_u64]
  CrystalClick::WidePartWriter.write_uint64_pair(
    path, "pk", keys.to_unsafe.to_slice(keys.size), "base", keys.to_unsafe.to_slice(keys.size), rows_per_mark: 2
  )
  path
end

private def w219_write_grouped_count_child(
  parent : String,
  projection_name : String,
  keys : Array(UInt64) = [0_u64, 1_u64, 2_u64],
  counts : Array(UInt64) = [2_u64, 2_u64, 2_u64],
  rows_per_mark : Int32 = 2,
  key_name : String = "intDiv(pk, 2)",
  count_name : String = "count()",
) : String
  raise ArgumentError.new("W219 grouped keys and counts differ") unless keys.size == counts.size
  path = File.join(parent, "#{projection_name}.proj")
  type = w219_count_type
  states = counts.map { |count| CrystalClick::BinaryValue.aggregate_count_state(type, count) }
  CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
    path,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "c",
    type,
    states.to_unsafe.to_slice(states.size),
    rows_per_mark: rows_per_mark,
  )
  w219_rebind_to_stock_names!(path, key_name, count_name, counts.size)
  path
end

private def w219_with_root(& : String ->) : Nil
  root = File.tempname("crystal-click-w219-count-names-")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def w219_rewrite_key_mark_rows!(part : String, key_name : String, rows : Array(UInt64)) : Nil
  base = CrystalClick::StreamName.hash(CrystalClick::PhysicalStreamName.escape(key_name))
  path = File.join(part, "#{base}.mrk2")
  bytes = File.read(path).to_slice.dup
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "W219 unexpected key mark file size" unless bytes.size == (rows.size + 1) * mark_size

  decompressed_offset = 0_u64
  rows.each_with_index do |mark_rows, mark_index|
    offset = mark_index * mark_size
    w219_write_u64(bytes, offset + 8, decompressed_offset)
    w219_write_u64(bytes, offset + 16, mark_rows)
    decompressed_offset += mark_rows * 8_u64
  end
  w219_write_u64(bytes, rows.size * mark_size + 8, decompressed_offset)
  w219_write_u64(bytes, rows.size * mark_size + 16, 0_u64)
  File.write(path, bytes)
  w219_refresh_checksums(part)
end

describe "W219 AggregateFunction(count) ClickHouse physical-name binding" do
  it "keeps ASCII identity and maps logical expression names to one canonical escaped stream" do
    plan = CrystalClick::WideAggregateCountStoragePlan.require(w219_count_type)
    plan.physical_streams("c").should eq(["c"])
    plan.stream_width("c", "c").should eq(1)
    plan.physical_streams("count()").should eq(["count%28%29"])
    plan.stream_width("count()", "count%28%29").should eq(1)

    expect_raises(CrystalClick::UnsupportedFormatError) { plan.stream_width("count()", "count()") }
    expect_raises(CrystalClick::UnsupportedFormatError) { plan.stream_width("count()", "count%2528%2529") }
  end

  it "uses bytewise escaping that distinguishes dots, percent escapes, and apparent collisions" do
    key_name = "intDiv(pk, 2)"
    escaped_key = CrystalClick::PhysicalStreamName.escape(key_name)
    escaped_key.should eq("intDiv%28pk%2C%202%29")
    CrystalClick::PhysicalStreamName.escape("count()").should eq("count%28%29")
    CrystalClick::PhysicalStreamName.escape("part.name").should eq("part%2Ename")
    CrystalClick::PhysicalStreamName.escape("part%2Ename").should eq("part%252Ename")
    CrystalClick::PhysicalStreamName.escape("part.name").should_not eq(
      CrystalClick::PhysicalStreamName.escape("part%2Ename")
    )
    CrystalClick::StreamName.hash(CrystalClick::PhysicalStreamName.escape("part.name")).should_not eq(
      CrystalClick::StreamName.hash(CrystalClick::PhysicalStreamName.escape("part%2Ename"))
    )

    plan = CrystalClick::WideAggregateCountStoragePlan.require(w219_count_type)
    plan.physical_streams("part.name").should eq(["part%2Ename"])
    plan.physical_streams("part%2Ename").should eq(["part%252Ename"])
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plan.stream_width(key_name, "intDiv%28pk%2c%202%29")
    end
  end

  it "reads a grouped stock-shaped child whose Count rows and marks differ from its parent" do
    w219_with_root do |root|
      parent = w219_write_parent(root)
      child = w219_write_grouped_count_child(parent, "by_count")
      count_name = "count()"
      key_name = "intDiv(pk, 2)"
      type = w219_count_type

      parent_reader = CrystalClick::WidePart.open_typed(parent, "base")
      parent_reader.row_count.should eq(6_u64)
      count_reader = CrystalClick::WidePart.open_typed(child, count_name)
      count_reader.column_type.should eq(type.name)
      count_reader.row_count.should eq(3_u64)
      count_reader.mark_row_counts.should eq([2_u64, 1_u64])
      count_reader.aggregate_count_key_column_name.should eq(key_name)
      count_reader.read_aggregate_count_mark_range(count_name, 0, count_reader.mark_count, expected_type: type).map(&.count_state).should eq([2_u64, 2_u64, 2_u64])

      key_reader = CrystalClick::WidePart.open_typed(child, key_name)
      key_reader.column_type.should eq("UInt64")
      key_reader.read_uint64_mark_range(key_name, 0, key_reader.mark_count).should eq([0_u64, 1_u64, 2_u64])

      table = CrystalClick::WidePartTable.open_selected_projection_typed([parent], "by_count", [count_name])
      table.columns.should eq([count_name])
      table.column_types.should eq([{count_name, type.name}])
      table.total_row_count.should eq(3_u64)
      table.part_mark_row_counts.should eq([[2_u64, 1_u64]])
      observed = [] of UInt64
      parent_paths = [] of String
      table.scan_typed do |batch|
        parent_paths << batch.part_path
        batch.column_names.should eq([count_name])
        batch.aggregate_count_states_for(count_name, type).each { |state| observed << state.count_state }
      end
      observed.should eq([2_u64, 2_u64, 2_u64])
      parent_paths.uniq.should eq([parent])
    end
  end

  it "reads a raw percent-bearing logical name from its canonical literal physical filename" do
    w219_with_root do |root|
      parent = w219_write_parent(root)
      logical_count_name = "count%28%29"
      child = w219_write_grouped_count_child(parent, "by_percent", count_name: logical_count_name)
      physical_name = CrystalClick::PhysicalStreamName.escape(logical_count_name)
      physical_name.should eq("count%2528%2529")
      w219_rename_stream_files!(child, physical_name, physical_name)

      reader = CrystalClick::WidePart.open_typed(child, logical_count_name)
      reader.read_aggregate_count_mark_range(
        logical_count_name, 0, reader.mark_count, expected_type: w219_count_type
      ).map(&.count_state).should eq([2_u64, 2_u64, 2_u64])
    end
  end

  it "does not fall back to literal or hashed raw-name files when escaped files are absent" do
    w219_with_root do |root|
      parent = w219_write_parent(root)
      logical_count_name = "count()"
      physical_name = CrystalClick::PhysicalStreamName.escape(logical_count_name)
      [logical_count_name, CrystalClick::StreamName.hash(logical_count_name)].each_with_index do |raw_base, index|
        child = w219_write_grouped_count_child(parent, "by_raw_decoy_#{index}")
        w219_rename_stream_files!(child, physical_name, raw_base)
        expect_raises(CrystalClick::InvalidPartError) do
          CrystalClick::WidePart.open_typed(child, logical_count_name)
        end
      end
    end
  end

  it "rejects raw and double-escaped Count roster names instead of accepting filename fallbacks" do
    w219_with_root do |root|
      parent = w219_write_parent(root)
      key_name = "intDiv(pk, 2)"
      count_name = "count()"
      canonical_key = CrystalClick::PhysicalStreamName.escape(key_name)
      canonical_count = CrystalClick::PhysicalStreamName.escape(count_name)
      [
        {"by_count_raw", count_name},
        {"by_count_double", CrystalClick::PhysicalStreamName.escape(canonical_count)},
        {"by_count_key_alias", canonical_key},
      ].each do |projection_name, invalid_count_stream|
        child = w219_write_grouped_count_child(parent, projection_name)
        w219_rewrite_substreams!(child, key_name, count_name, canonical_key, invalid_count_stream)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_typed(child, count_name)
        end
      end
    end
  end

  it "rejects raw, double-escaped, and noncanonical UInt64 sibling roster names" do
    w219_with_root do |root|
      parent = w219_write_parent(root)
      key_name = "intDiv(pk, 2)"
      count_name = "count()"
      canonical_key = CrystalClick::PhysicalStreamName.escape(key_name)
      canonical_count = CrystalClick::PhysicalStreamName.escape(count_name)
      [
        {"by_key_raw", key_name},
        {"by_key_double", CrystalClick::PhysicalStreamName.escape(canonical_key)},
        {"by_key_lowercase", canonical_key.sub("%2C", "%2c")},
      ].each do |projection_name, invalid_key_stream|
        child = w219_write_grouped_count_child(parent, projection_name)
        w219_rewrite_substreams!(child, key_name, count_name, invalid_key_stream, canonical_count)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_typed(child, key_name)
        end
      end
    end
  end

  it "preserves the exact hidden-sibling mark-axis guard for escaped expression names" do
    w219_with_root do |root|
      parent = w219_write_parent(root)
      child = w219_write_grouped_count_child(parent, "by_count_bad_axis")
      key_name = "intDiv(pk, 2)"
      w219_rewrite_key_mark_rows!(child, key_name, [1_u64, 2_u64])

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_projection_typed([parent], "by_count_bad_axis", ["count()"])
        table.scan_typed { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end

  it "retains the ordinary no-projection ASCII writer and scan path" do
    w219_with_root do |root|
      part = File.join(root, "all_1_1_0")
      keys = [1_u64, 2_u64, 3_u64]
      counts = [5_u64, 8_u64, 13_u64]
      type = w219_count_type
      states = counts.map { |count| CrystalClick::BinaryValue.aggregate_count_state(type, count) }
      CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
        part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "c",
        type,
        states.to_unsafe.to_slice(states.size),
        rows_per_mark: 2,
      )

      File.read(File.join(part, "columns_substreams.txt")).should contain("\tpk\n")
      File.read(File.join(part, "columns_substreams.txt")).should contain("\tc\n")
      File.file?(File.join(part, "#{CrystalClick::StreamName.hash("pk")}.bin")).should be_true
      File.file?(File.join(part, "#{CrystalClick::StreamName.hash("c")}.bin")).should be_true

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["c"])
      table.total_row_count.should eq(3_u64)
      table.part_mark_row_counts.should eq([[2_u64, 1_u64]])
      observed = [] of UInt64
      table.scan_typed do |batch|
        batch.aggregate_count_states_for("c", type).each { |state| observed << state.count_state }
      end
      observed.should eq(counts)
    end
  end
end
