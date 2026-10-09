require "./spec_helper"
require "./support/geometry_recursive_w239_fixture"

module CrystalClick::WidePartWriter
  def self.w239_mutate_last_u64_role_and_refresh_for_spec(
    part : String,
    type : BinaryDataType,
    role : String,
    expected : UInt64,
    replacement_value : UInt64,
  ) : Nil
    physical = BinaryBulkPhysicalPlan.new(type, "v")
    data_path = File.join(part, physical.data_file_for(role, true))
    encoded = File.read(data_path).to_slice
    frame = CompressedBlock.decode_frame(encoded, 0_i64)
    raise "W239 mutation expected one compressed frame" unless frame.end_offset == encoded.size.to_i64
    raw = frame.output.dup
    raise "W239 mutation selected a short size lane" if raw.size < 8
    observed = 0_u64
    8.times { |index| observed |= raw[raw.size - 8 + index].to_u64 << (index * 8) }
    raise "W239 mutation did not find the independent expected trailing size" unless observed == expected
    8.times do |index|
      raw[raw.size - 8 + index] = ((replacement_value >> (index * 8)) & 0xff_u64).to_u8
    end
    File.write(data_path, StreamEncoding.encode_lz4_frame(raw))

    checksums = PartChecksums.open(part)
    records = [] of ChecksumRecord
    checksums.entries.each do |name, entry|
      bytes = File.read(File.join(part, name)).to_slice
      if entry.compressed
        decoded = bytes.empty? ? Bytes.empty : CompressedBlock.decode_all(
          bytes,
          PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
          PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES,
          PartChecksums::MAX_PAYLOAD_BYTES,
        )
        records << ChecksumRecord.new(
          name, bytes.size.to_u64, CityHashV1.file_hash(bytes), true,
          decoded.size.to_u64, CityHashV1.file_hash(decoded),
        )
      else
        records << ChecksumRecord.new(name, bytes.size.to_u64, CityHashV1.file_hash(bytes), false)
      end
    end
    write_checksums(part, records)
    nil
  end
end

describe "W239 Geometry recursive physical bulk parts" do
  it "uses the existing 25 physical roles on the complete three-mark outer grid" do
    fixture = W239GeometryFixture.new
    begin
      part = fixture.write_bare
      File.read(File.join(part, "columns.txt")).should contain("`v` Geometry")
      type = fixture.geometry_type
      physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, "v")
      plan = CrystalClick::BinaryBulkTypePlan.new(type, CrystalClick::BinaryBulkProfile.with_size_stream)
      physical.stream_names.keys.sort.should eq(plan.roles)
      physical.stream_names.size.should eq(25)

      ordered_metadata_streams = File.read(File.join(part, "columns_substreams.txt")).split('\n')
        .select(&.starts_with?("\t")).map { |line| line.byte_slice(1, line.bytesize - 1) }
      expected_metadata_streams = ["pk"] of String
      expected_metadata_streams.concat(
        CrystalClick::GeometryColumnType.for_type("Geometry").not_nil!.physical_streams("v").map(&.[0])
      )
      ordered_metadata_streams.should eq(expected_metadata_streams)

      reader = CrystalClick::BinaryBulkColumnReader.open(part, "v", type)
      reader.schema_declaration.should eq("Geometry")
      reader.source_declaration.should eq("Geometry")
      reader.row_count.should eq(11_u64)
      reader.mark_count.should eq(3)
      reader.mark_row_counts.should eq([4_u64, 4_u64, 3_u64])
      reader.physical_stream_names.sort.should eq(physical.stream_names.values.sort)
      w239g_assert_marks(reader.read_marks(0, 3), fixture.geometry_marks)
      w239g_assert_marks(reader.read_marks(1, 1), [fixture.geometry_marks[1]] of Array(CrystalClick::BinaryValue))
      w239g_assert_marks(reader.read_marks(2, 1), [fixture.geometry_marks[2]] of Array(CrystalClick::BinaryValue))
      reader.read_marks(3, 0).should eq([] of Array(CrystalClick::BinaryValue))
    ensure
      fixture.close
    end
  end

  it "rejects a checksum-valid late sparse-axis size defect before an early or EOF callback" do
    fixture = W239GeometryFixture.new
    begin
      part = fixture.write_composed
      role = "root.field.0.elements.arm.0.sizes"
      plan = CrystalClick::BinaryBulkPhysicalPlan.new(fixture.composed_type, "v")
      plan.stream_names.has_key?(role).should be_true

      corruption_dir = File.join(fixture.root, "late-size-corruption")
      FileUtils.mkdir_p(corruption_dir)
      bad_part = File.join(corruption_dir, "all_1_1_0")
      FileUtils.cp_r(part, bad_part)
      CrystalClick::WidePartWriter.w239_mutate_last_u64_role_and_refresh_for_spec(
        bad_part, fixture.composed_type, role, 0_u64, 1_u64,
      )

      [0_u64, 11_u64].each do |start_row|
        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          table = CrystalClick::WidePartTable.open_selected_typed([bad_part], ["pk", "v"])
          table.scan_typed_window(start_row, 1) { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      end
    ensure
      fixture.close
    end
  end
end
