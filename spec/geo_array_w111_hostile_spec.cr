require "./spec_helper"

private def w111_hostile_u64_bytes(values : Array(UInt64)) : Bytes
  bytes = Bytes.new(values.size * 8, 0_u8)
  values.each_with_index do |value, row|
    8.times { |index| bytes[row * 8 + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w111_hostile_decode_u64(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w111_hostile_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w111_hostile_shift_later_mark_boundary(part : String, stream_name : String, mark_index : Int32) : Nil
  mark_path = File.join(part, "#{CrystalClick::StreamName.hash(stream_name)}.mrk2")
  marks = File.read(mark_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 8
  # The selected later mark starts a new frame. Moving its local start beyond
  # that frame's output keeps the .mrk2 record well-formed but makes the
  # selected range boundary impossible to satisfy.
  w111_hostile_write_u64(marks, offset, w111_hostile_decode_u64(marks, offset.to_i32) + 24_u64)
  File.write(mark_path, marks)
end

module CrystalClick::WidePartWriter
  # Keep the mutated mark file checksum-valid so this probe distinguishes the
  # selected-frame boundary guard from checksum validation.
  def self.w111_hostile_refresh_checksums_for_spec(stage : String, checksums : PartChecksums) : Nil
    records = [] of ChecksumRecord
    checksums.entries.each do |name, entry|
      encoded = File.read(File.join(stage, name)).to_slice
      if entry.compressed
        decoded = CompressedBlock.decode_all(
          encoded,
          PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
          PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES,
          PartChecksums::MAX_PAYLOAD_BYTES
        )
        records << ChecksumRecord.new(
          name, encoded.size.to_u64, CityHashV1.file_hash(encoded), true,
          decoded.size.to_u64, CityHashV1.file_hash(decoded)
        )
      else
        records << ChecksumRecord.new(name, encoded.size.to_u64, CityHashV1.file_hash(encoded), false)
      end
    end
    write_checksums(stage, records)
  end
end

class CrystalClick::WidePart
  class W111GeoHostileReaderHarness
    getter reader : GeoArrayReader
    getter size_decode_calls : Int32
    getter float_decode_calls : Int32
    getter reads : Array(Tuple(String, Int32))
    getter validations : Array(Tuple(String, Int32))

    @rows : Array(UInt64)
    @payloads : Hash(String, Array(Bytes))
    @bad_boundary : Tuple(String, Int32)?

    def initialize(@rows : Array(UInt64), @payloads : Hash(String, Array(Bytes)), @bad_boundary : Tuple(String, Int32)? = nil)
      @size_decode_calls = 0
      @float_decode_calls = 0
      @reads = [] of Tuple(String, Int32)
      @validations = [] of Tuple(String, Int32)
      @reader = GeoArrayReader.new(
        GeoArrayColumnType.for_type("Polygon").not_nil!,
        "shape",
        ->(_stream : String, first : Int32, count : Int32) {
          total = 0_u64
          count.times { |offset| total += @rows[first + offset] }
          total
        },
        ->(_stream : String, mark : Int32) { @rows[mark] },
        ->(stream : String, first : Int32, count : Int32, expected_bytes : Int32, _width : Int32, _outer_rows : UInt64) {
          raise CrystalClick::CorruptPartError.new("hostile fixture expects one-mark reads") unless count == 1
          @reads << {stream, first}
          bytes = @payloads[stream][first]
          raise CrystalClick::CorruptPartError.new("hostile fixture byte count differs") unless bytes.size == expected_bytes
          bytes
        },
        ->(stream : String, first : Int32, count : Int32, expected_bytes : Int32, _width : Int32, _outer_rows : UInt64) {
          raise CrystalClick::CorruptPartError.new("hostile fixture expects one-mark boundaries") unless count == 1
          @validations << {stream, first}
          raise CrystalClick::CorruptPartError.new("seeded selected size boundary defect") if @bad_boundary == {stream, first}
          bytes = @payloads[stream][first]
          raise CrystalClick::CorruptPartError.new("hostile fixture boundary differs") unless bytes.size == expected_bytes
          nil
        },
        ->(bytes : Bytes, offset : Int32) {
          @size_decode_calls += 1
          w111_hostile_decode_u64(bytes, offset)
        },
        ->(bytes : Bytes, offset : Int32) {
          @float_decode_calls += 1
          w111_hostile_decode_u64(bytes, offset).unsafe_as(Float64)
        }
      )
    end
  end
end

describe "W111 hostile Geo Array reader controls" do
  it "validates every selected boundary at a depth before reading or decoding any value at that depth" do
    payloads = {
      "shape.size0" => [w111_hostile_u64_bytes([1_u64]), w111_hostile_u64_bytes([1_u64])],
      "shape.size1" => [w111_hostile_u64_bytes([1_u64]), w111_hostile_u64_bytes([1_u64])],
      "shape%2E1"   => [w111_hostile_u64_bytes([10_u64]), w111_hostile_u64_bytes([20_u64])],
      "shape%2E2"   => [w111_hostile_u64_bytes([30_u64]), w111_hostile_u64_bytes([40_u64])],
    }
    harness = CrystalClick::WidePart::W111GeoHostileReaderHarness.new(
      [1_u64, 1_u64],
      payloads,
      {"shape.size1", 1}
    )

    expect_raises(CrystalClick::CorruptPartError, "seeded selected size boundary defect") do
      harness.reader.read(0, 2, CrystalClick::GeoArrayColumnType::MAX_MATERIALIZED_BYTES)
    end

    harness.size_decode_calls.should eq(2) # Only the already-preflighted size0 values.
    harness.reads.none? { |stream, _mark| stream == "shape.size1" || stream == "shape%2E1" || stream == "shape%2E2" }.should be_true
    harness.float_decode_calls.should eq(0)
    harness.validations.includes?({"shape.size1", 0}).should be_true
    harness.validations.includes?({"shape.size1", 1}).should be_true
  end

  it "rejects nested UInt64 total overflow and cardinality excess before allocating topology or reading deeper streams" do
    plan = CrystalClick::GeoArrayColumnType.for_type("LineString").not_nil!
    expect_raises(ArgumentError) do
      CrystalClick::WideGeoArrayTopology.validate!(plan, [[UInt64::MAX, 1_u64]])
    end

    # A reader-level size exceeds the admitted logical count even though its
    # physical frame is small; the deeper and coordinate lanes stay untouched.
    payloads = {
      "shape.size0" => [w111_hostile_u64_bytes([65_537_u64])],
      "shape.size1" => [Bytes.new(0)],
      "shape%2E1"   => [Bytes.new(0)],
      "shape%2E2"   => [Bytes.new(0)],
    }
    harness = CrystalClick::WidePart::W111GeoHostileReaderHarness.new([1_u64], payloads)
    expect_raises(CrystalClick::CorruptPartError) do
      harness.reader.read(0, 1, CrystalClick::GeoArrayColumnType::MAX_MATERIALIZED_BYTES)
    end
    harness.reads.none? { |stream, _mark| stream == "shape.size1" || stream == "shape%2E1" || stream == "shape%2E2" }.should be_true
    harness.float_decode_calls.should eq(0)
  end

  it "preflights later selected table marks before callbacks but leaves an earlier-only window readable" do
    parent = File.tempname("crystal-click-geo-array-w111-table-hostile")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    keys = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64]
    levels = [
      [1_u64, 1_u64, 1_u64, 1_u64, 1_u64],
      [1_u64, 1_u64, 1_u64, 1_u64, 1_u64],
      [1_u64, 1_u64, 1_u64, 1_u64, 1_u64],
    ]
    points = [
      CrystalClick::WidePointValue.new(1.0, 11.0),
      CrystalClick::WidePointValue.new(2.0, 12.0),
      CrystalClick::WidePointValue.new(3.0, 13.0),
      CrystalClick::WidePointValue.new(4.0, 14.0),
      CrystalClick::WidePointValue.new(5.0, 15.0),
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_geo_array_pair(
        part_path, "pk", keys.to_unsafe.to_slice(keys.size), "geo", "MultiPolygon",
        levels, points, rows_per_mark: 2
      )

      checksums = CrystalClick::PartChecksums.open(part_path)
      w111_hostile_shift_later_mark_boundary(part_path, "geo%2E2", 2)
      CrystalClick::WidePartWriter.w111_hostile_refresh_checksums_for_spec(part_path, checksums)

      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["pk", "geo"])

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError, "mark offset exceeds frame output") do
        table.scan_typed(batch_rows: 2) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)

      # The bad mark is later than this physical-row window, so it is not
      # selected and must not poison the earlier range. Mark 1 remains an
      # intact end boundary for mark 0; the defect starts only at mark 2.
      callbacks = 0
      table.scan_typed_window(0_u64, 2) { |_batch| callbacks += 1 }
      callbacks.should eq(1)

      # A window crossing into the bad mark selects it and must preflight it
      # before publishing even the valid first-mark batch.
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError, "mark offset exceeds frame output") do
        table.scan_typed_window(0_u64, 5) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
