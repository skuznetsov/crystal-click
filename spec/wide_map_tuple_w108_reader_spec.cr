require "./spec_helper"
require "file_utils"

module CrystalClick::WidePartWriter
  # Keep metadata negatives focused on Map(Tuple) admission rather than the
  # independent file-checksum guard.
  def self.w108r_refresh_checksums(part : String) : Nil
    current = PartChecksums.open(part)
    records = [] of ChecksumRecord
    current.entries.each do |name, entry|
      bytes = File.read(File.join(part, name)).to_slice
      file_hash = CityHashV1.file_hash(bytes)
      if entry.compressed
        raw = CompressedBlock.decode_all(bytes)
        records << ChecksumRecord.new(
          name, bytes.size.to_u64, file_hash, true, raw.size.to_u64, CityHashV1.file_hash(raw)
        )
      else
        records << ChecksumRecord.new(name, bytes.size.to_u64, file_hash, false)
      end
    end
    write_checksums(part, records)
  end
end

private def w108r_value_columns : Array(CrystalClick::WideTupleLeafColumn)
  note_type = CrystalClick::WideTupleLeafType.parse("Nullable(String)").not_nil!
  note_map = CrystalClick::ScalarNullMap.new(Bytes[0_u8, 1_u8, 0_u8], 3_u64)
  note = CrystalClick::WideTupleLeafColumn.new("meta.note", note_type, ["alpha", "hidden\0bytes", "omega"] of String, note_map)
  id = CrystalClick::WideTupleLeafColumn.new("meta.id", [101_u64, 102_u64, 103_u64] of UInt64)
  date_type = CrystalClick::WideTupleLeafType.parse("DateTime64(3, 'America/New_York')").not_nil!
  date = CrystalClick::WideTupleLeafColumn.new(
    "at",
    date_type,
    [CrystalClick::DateTime64Value.new(1_234_567_i64, 3), CrystalClick::DateTime64Value.new(0_i64, 3), CrystalClick::DateTime64Value.new(Int64::MIN, 3)] of CrystalClick::DateTime64Value,
    nil
  )
  [note, id, date]
end

private def w108r_write_part(parent : String, label : String, row_sizes : Array(UInt64) = [0_u64, 2_u64, 0_u64, 1_u64, 0_u64]) : String
  container = File.join(parent, label)
  FileUtils.mkdir_p(container)
  destination = File.join(container, "all_1_1_0")
  entries = row_sizes.sum.to_i
  map_keys = if entries == 3
               CrystalClick::WideTupleLeafColumn.new("keys", ["dup", "dup", "\0key"] of String)
             else
               CrystalClick::WideTupleLeafColumn.new("keys", [] of String)
             end
  columns = if entries == 3
              w108r_value_columns
            else
              note_type = CrystalClick::WideTupleLeafType.parse("Nullable(String)").not_nil!
              note_map = CrystalClick::ScalarNullMap.new(Bytes.empty, 0_u64)
              [
                CrystalClick::WideTupleLeafColumn.new("meta.note", note_type, [] of String, note_map),
                CrystalClick::WideTupleLeafColumn.new("meta.id", [] of UInt64),
                CrystalClick::WideTupleLeafColumn.new(
                  "at",
                  CrystalClick::WideTupleLeafType.parse("DateTime64(3, 'America/New_York')").not_nil!,
                  [] of CrystalClick::DateTime64Value,
                  nil
                ),
              ] of CrystalClick::WideTupleLeafColumn
            end
  type_name = "Map(String, Tuple(meta Tuple(note Nullable(String), id UInt64), at DateTime64(3, 'America/New_York')))"
  primary_keys = Array(UInt64).new(row_sizes.size) { |index| (10 + index).to_u64 }
  CrystalClick::WidePartWriter.write_uint64_map_tuple_part(
    destination,
    "pk",
    primary_keys.to_unsafe.to_slice(primary_keys.size),
    "payload",
    type_name,
    row_sizes.to_unsafe.to_slice(row_sizes.size),
    map_keys,
    columns,
    2
  )
end

private def w108r_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w108r_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w108r_mutate_mark(part : String, stream_name : String, mark_index : Int32, byte_offset : Int32, delta : UInt64) : Nil
  mark_path = File.join(part, "#{CrystalClick::StreamName.hash(stream_name)}.mrk2")
  bytes = File.read(mark_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + byte_offset
  w108r_write_u64(bytes, offset, w108r_u64(bytes, offset) + delta)
  File.write(mark_path, bytes)
end

private def w108r_replace_metadata(part : String, name : String, before : String, after : String) : Nil
  path = File.join(part, name)
  original = File.read(path)
  raise "W108 metadata replacement anchor is missing" unless original.includes?(before)
  File.write(path, original.sub(before, after))
  CrystalClick::WidePartWriter.w108r_refresh_checksums(part) if name == "serialization.json"
end

private def w108r_replace_serialization(part : String, contents : String) : Nil
  File.write(File.join(part, "serialization.json"), contents)
  CrystalClick::WidePartWriter.w108r_refresh_checksums(part)
end

class CrystalClick::WidePartTable
  def self.w108_map_tuple_table_charge(reader : WidePart, column : String, mark_index : Int32, limit : UInt64) : UInt64
    MapTupleColumnAdapter.preflight_mark_charge(reader, column, mark_index, reader.mark_row_counts[mark_index].to_u64, limit)
  end
end

describe CrystalClick::WidePart do
  it "reads ordered duplicate-key rows, nested Nullable values, and exact nominal Tuple metadata" do
    parent = File.tempname("crystal-click-map-tuple-w108-reader-ragged")
    Dir.mkdir(parent)
    row_sizes = [0_u64, 2_u64, 0_u64, 1_u64, 0_u64]

    begin
      part_path = w108r_write_part(parent, "ragged", row_sizes)
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      data = reader.read_map_tuple_mark_range("payload", 0, reader.mark_count)

      data.type_name.should eq("Map(String, Tuple(meta Tuple(note Nullable(String), id UInt64), at DateTime64(3, 'America/New_York')))")
      data.row_count.should eq(5)
      data.entry_count.should eq(3)
      data.row_sizes.should eq(row_sizes)
      data.offsets.should eq([0_u64, 0_u64, 2_u64, 2_u64, 3_u64, 3_u64])
      data.row(0).size.should eq(0)
      data.row(1).size.should eq(2)
      data.row(2).size.should eq(0)
      data.row(3).size.should eq(1)
      data.row(4).size.should eq(0)

      duplicate_row = data.row(1)
      duplicate_row.type_name.should eq(data.type_name)
      duplicate_row.key_at(0).should eq("dup")
      duplicate_row.key_at(1).should eq("dup")
      duplicate_row.key_as(0, String).should eq("dup")
      duplicate_row[0][0].should eq("dup")
      duplicate_row[0][1].tuple("meta").value_as("id", UInt64).should eq(101_u64)
      duplicate_row.value_at(0).tuple("meta").value_as("id", UInt64).should eq(101_u64)
      duplicate_row.value_at(1).tuple("meta")["note"].should be_nil
      duplicate_row.value_at(1).value_as("at", CrystalClick::DateTime64Value).raw.should eq(0_i64)
      duplicate_row.string_bytesize.should eq(23_u64)
      data.row(3).key_at(0).should eq("\0key")
      data.row(3).value_at(0).tuple("meta")["note"].should eq("omega")

      note = data.tuple_data["meta.note"]
      note.type_name.should eq("Nullable(String)")
      note.physical_values.should eq(["alpha", "hidden\0bytes", "omega"])
      note.null_map.not_nil!.bytes.should eq([0_u8, 1_u8, 0_u8])
      data.tuple_data["at"].type_name.should eq("DateTime64(3, 'America/New_York')")
      data.tuple_data["at"].physical_values.should eq(w108r_value_columns.last.physical_values)

      observed = [] of {String, UInt64}
      duplicate_row.each do |key, value|
        observed << {key.as(String), value.tuple("meta").value_as("id", UInt64)}
        nil
      end
      observed.should eq([{"dup", 101_u64}, {"dup", 102_u64}])

      detached_sizes = data.row_sizes
      detached_sizes[1] = 99_u64
      data.row_sizes.should eq(row_sizes)
      detached_offsets = data.offsets
      detached_offsets[1] = 99_u64
      data.offsets.should eq([0_u64, 0_u64, 2_u64, 2_u64, 3_u64, 3_u64])
      exported_key = data.key_column
      exported_key.physical_values.as(Array(String))[0] = "changed"
      data.row(1).key_at(0).should eq("dup")

      selected = reader.read_map_tuple_mark_range("payload", 1, 1)
      selected.row_sizes.should eq([0_u64, 1_u64])
      selected.row(1).key_at(0).should eq("\0key")

      mark_indexes = [] of Int32
      mark_rows = [] of Int32
      reader.each_map_tuple_mark_range("payload", 0, reader.mark_count) do |mark_data, mark_index|
        mark_indexes << mark_index
        mark_rows << mark_data.row_count
        nil
      end
      mark_indexes.should eq([0_i32, 1_i32, 2_i32])
      mark_rows.should eq([2_i32, 2_i32, 1_i32])
      expect_raises(CrystalClick::BoundsError) { data.row(-1) }
      expect_raises(CrystalClick::BoundsError) { data.row(data.row_count) }
      expect_raises(CrystalClick::BoundsError) { duplicate_row.key_at(2) }
      expect_raises(CrystalClick::BoundsError) { reader.read_map_tuple_mark_range("payload", Int64::MAX, 1) }
      expect_raises(CrystalClick::BoundsError) { reader.read_map_tuple_mark_range("payload", 0, Int128::MAX) }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "supports all-empty Map rows and exact per-range budget boundaries" do
    parent = File.tempname("crystal-click-map-tuple-w108-reader-empty")
    Dir.mkdir(parent)
    sizes = [0_u64, 0_u64, 0_u64]

    begin
      part_path = w108r_write_part(parent, "empty", sizes)
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      limit = CrystalClick::WideTupleTypePlan::MAX_MATERIALIZED_BYTES
      exact_charge = reader.map_tuple_mark_range_materialization_charge("payload", 0, reader.mark_count, limit)
      data = reader.read_map_tuple_mark_range("payload", 0, reader.mark_count, exact_charge)
      data.row_sizes.should eq(sizes)
      data.entry_count.should eq(0)
      data.offsets.should eq([0_u64, 0_u64, 0_u64, 0_u64])
      data.key_column.physical_values.should eq([] of String)
      data.tuple_data["meta.note"].physical_values.should eq([] of String)
      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_map_tuple_mark_range("payload", 0, reader.mark_count, exact_charge - 1_u64)
      end
      data.row(0).each { |_key, _value| fail "empty Map row yielded an entry" }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects selected-wide child boundary corruption before the first lazy callback" do
    parent = File.tempname("crystal-click-map-tuple-w108-reader-boundary")
    Dir.mkdir(parent)

    begin
      [
        "payload%2Ekeys",
        "payload%2Evalues%2Emeta%2Enote",
      ].each_with_index do |stream_name, index|
        part_path = w108r_write_part(parent, "shifted-#{index}")
        w108r_mutate_mark(part_path, stream_name, 2, 8, 1_u64)
        callbacks = [] of Int32
        expect_raises(CrystalClick::CorruptPartError) do
          reader = CrystalClick::WidePart.open_typed(part_path, "payload")
          reader.each_map_tuple_mark_range("payload", 0, reader.mark_count) do |_data, mark_index|
            callbacks << mark_index
            nil
          end
        end
        callbacks.should be_empty
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects child mark-row misalignment across the selected range before callbacks" do
    parent = File.tempname("crystal-click-map-tuple-w108-reader-mark-rows")
    Dir.mkdir(parent)

    begin
      part_path = w108r_write_part(parent, "misaligned")
      w108r_mutate_mark(part_path, "payload%2Ekeys", 2, 16, 1_u64)
      callbacks = [] of Int32
      expect_raises(CrystalClick::CorruptPartError) do
        reader = CrystalClick::WidePart.open_typed(part_path, "payload")
        reader.each_map_tuple_mark_range("payload", 0, reader.mark_count) do |_data, mark_index|
          callbacks << mark_index
          nil
        end
      end
      callbacks.should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "admits qualified Map(Tuple) statistics and rejects unproven or corrupt metadata" do
    parent = File.tempname("crystal-click-map-tuple-w108-reader-serialization")
    Dir.mkdir(parent)

    begin
      missing = w108r_write_part(parent, "missing-serialization")
      File.delete(File.join(missing, "serialization.json"))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(missing, "payload")
      end

      malformed = w108r_write_part(parent, "malformed-serialization")
      w108r_replace_serialization(malformed, "{not-json")
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(malformed, "payload")
      end

      unknown_envelope = w108r_write_part(parent, "unknown-envelope-field")
      w108r_replace_metadata(
        unknown_envelope,
        "serialization.json",
        %("version":1}),
        %("version":1,"future_profile":true})
      )
      expect_raises(CrystalClick::UnsupportedFormatError, "unsupported Map serialization.json field") do
        CrystalClick::WidePart.open_typed(unknown_envelope, "payload")
      end

      unknown_pk_field = w108r_write_part(parent, "unknown-pk-field")
      w108r_replace_metadata(
        unknown_pk_field,
        "serialization.json",
        %("num_rows":5}),
        %("num_rows":5,"future_stat":0})
      )
      expect_raises(CrystalClick::UnsupportedFormatError, "unsupported Map key serializer fields") do
        CrystalClick::WidePart.open_typed(unknown_pk_field, "payload")
      end

      payload_serializer = w108r_write_part(parent, "payload-statistics")
      w108r_replace_metadata(
        payload_serializer,
        "serialization.json",
        %("columns":[{"kind":"Default","name":"pk","num_defaults":0,"num_rows":5}]),
        %("columns":[{"kind":"Default","name":"pk","num_defaults":0,"num_rows":5},{"kind":"Default","name":"payload","num_defaults":0,"num_rows":5}])
      )
      reader = CrystalClick::WidePart.open_typed(payload_serializer, "payload")
      data = reader.read_map_tuple_mark_range("payload", 0, reader.mark_count)
      data.row_count.should eq(5)
      data.row_sizes.should eq([0_u64, 2_u64, 0_u64, 1_u64, 0_u64])
      data.row(1).key_at(0).should eq("dup")
      data.row(1).key_at(1).should eq("dup")
      data.row(1).value_at(0).tuple("meta")["note"].should eq("alpha")
      data.row(1).value_at(1).tuple("meta")["note"].should be_nil
      data.row(3).key_at(0).should eq("\0key")
      data.row(3).value_at(0).tuple("meta")["note"].should eq("omega")

      wrong_rows = w108r_write_part(parent, "wrong-pk-row-count")
      w108r_replace_metadata(
        wrong_rows,
        "serialization.json",
        %("num_rows":5}),
        %("num_rows":4})
      )
      expect_raises(CrystalClick::CorruptPartError, "serializer default or row count does not match the part") do
        CrystalClick::WidePart.open_typed(wrong_rows, "payload")
      end

      wrong_defaults = w108r_write_part(parent, "wrong-pk-default-count")
      w108r_replace_metadata(
        wrong_defaults,
        "serialization.json",
        %("num_defaults":0),
        %("num_defaults":6)
      )
      expect_raises(CrystalClick::CorruptPartError, "serializer default or row count does not match the part") do
        CrystalClick::WidePart.open_typed(wrong_defaults, "payload")
      end

      negative_defaults = w108r_write_part(parent, "negative-pk-default-count")
      w108r_replace_metadata(
        negative_defaults,
        "serialization.json",
        %("num_defaults":0),
        %("num_defaults":-1)
      )
      expect_raises(CrystalClick::CorruptPartError, "serializer default or row count does not match the part") do
        CrystalClick::WidePart.open_typed(negative_defaults, "payload")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects non-BASIC Map modifiers and altered recursive physical inventories" do
    parent = File.tempname("crystal-click-map-tuple-w108-reader-profile")
    Dir.mkdir(parent)

    begin
      with_buckets = w108r_write_part(parent, "with-buckets")
      w108r_replace_metadata(
        with_buckets,
        "columns.txt",
        "Map(String, Tuple(meta Tuple(note Nullable(String), id UInt64), at DateTime64(3, 'America/New_York')))\n",
        "Map(String, Tuple(meta Tuple(note Nullable(String), id UInt64), at DateTime64(3, 'America/New_York'))) WITH_BUCKETS\n"
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(with_buckets, "payload")
      end

      map_serialization_version = w108r_write_part(parent, "map-serialization-version")
      w108r_replace_metadata(
        map_serialization_version,
        "serialization.json",
        %("types_serialization_versions":{"string":1}),
        %("types_serialization_versions":{"string":1,"map":2})
      )
      expect_raises(CrystalClick::UnsupportedFormatError, "only nested String serialization version 1 is supported for Map") do
        CrystalClick::WidePart.open_typed(map_serialization_version, "payload")
      end

      wrong_substreams = w108r_write_part(parent, "wrong-substream-inventory")
      w108r_replace_metadata(
        wrong_substreams,
        "columns_substreams.txt",
        "\tpayload%2Ekeys\n",
        "\tpayload%2Ekeys.extra\n"
      )
      expect_raises(CrystalClick::UnsupportedFormatError, "selected physical substreams do not match exact serialization shape") do
        CrystalClick::WidePart.open_typed(wrong_substreams, "payload")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
