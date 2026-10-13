require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w275_fixture"

private def w275_assert_mark_checksums(
  part_path : String,
  mark_format : CrystalClick::CompactMarkFormat,
  compressed : Bool,
  canonical_marks : Bytes,
) : Nil
  name = CompactPartWriterW275Fixture.mark_name(mark_format, compressed)
  physical = CompactPartWriterW275Fixture.file_bytes(part_path, name)
  checksums = CrystalClick::PartChecksums.open(part_path)
  entry = checksums.entry(name).not_nil!

  entry.physical_size.should eq(physical.size.to_u64)
  entry.file_hash.should eq(CrystalClick::CityHashV1.file_hash(physical))
  if compressed
    entry.compressed.should be_true
    entry.uncompressed_size.should eq(canonical_marks.size.to_u64)
    entry.uncompressed_hash.should eq(CrystalClick::CityHashV1.file_hash(canonical_marks))

    decoded = CrystalClick::CompressedMarkReader.read_all(
      File.join(part_path, name),
      entry.physical_size.to_i64,
      CrystalClick::CompressedStreamBudget.read_default,
      entry.uncompressed_size.not_nil!.to_i64,
      entry.file_hash,
    )
    decoded.should eq(canonical_marks)
  else
    entry.compressed.should be_false
    entry.uncompressed_size.should be_nil
    entry.uncompressed_hash.should be_nil
    physical.should eq(canonical_marks)
  end
  nil
end

private def w275_assert_non_mark_files_equal(left : String, right : String) : Nil
  left_names = Dir.children(left).reject do |name|
    name == "checksums.txt" || name.starts_with?("data.mrk") || name.starts_with?("data.cmrk")
  end.sort
  right_names = Dir.children(right).reject do |name|
    name == "checksums.txt" || name.starts_with?("data.mrk") || name.starts_with?("data.cmrk")
  end.sort
  left_names.should eq(right_names)
  left_names.each do |name|
    File.read(File.join(left, name)).should eq(File.read(File.join(right, name)))
  end

  left_checksums = CrystalClick::PartChecksums.open(left)
  right_checksums = CrystalClick::PartChecksums.open(right)
  left_data = left_checksums.entry("data.bin").not_nil!
  right_data = right_checksums.entry("data.bin").not_nil!
  right_data.physical_size.should eq(left_data.physical_size)
  right_data.file_hash.should eq(left_data.file_hash)
  right_data.compressed.should eq(left_data.compressed)
  right_data.uncompressed_size.should eq(left_data.uncompressed_size)
  right_data.uncompressed_hash.should eq(left_data.uncompressed_hash)
  nil
end

describe "W275 Compact marks writer" do
  it "keeps the omitted option byte-identical to explicit false and preserves plain mark metadata" do
    parent = File.tempname("crystal-click-w275-plain-default-")
    omitted = File.join(parent, "omitted")
    explicit = File.join(parent, "explicit")
    begin
      Dir.mkdir(parent)
      fixture = CompactPartWriterW264Fixture
      CrystalClick::CompactPartWriter.write_uint64_columns(
        omitted,
        CompactPartWriterW264Fixture::KEY_NAME,
        fixture.keys,
        fixture.columns,
        rows_per_mark: CompactPartWriterW264Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW264Fixture::FRAME_BYTES,
      ).should eq(omitted)
      CompactPartWriterW275Fixture.static(
        explicit,
        CrystalClick::CompactMarkFormat::Mrk3,
        compress_marks: false,
      ).should eq(explicit)

      CompactPartWriterW275Fixture.file_snapshot(omitted).should eq(
        CompactPartWriterW275Fixture.file_snapshot(explicit),
      )
      Dir.children(omitted).any? { |name| name.starts_with?("data.cmrk") }.should be_false
      CompactPartWriterW275Fixture.file_snapshot(omitted).has_key?("data.mrk3").should be_true
      plain_marks = CompactPartWriterW275Fixture.file_bytes(omitted, "data.mrk3")
      w275_assert_mark_checksums(
        omitted,
        CrystalClick::CompactMarkFormat::Mrk3,
        false,
        plain_marks,
      )
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes interoperable compressed MRK3 and MRK4 sidecars without changing data or canonical marks" do
    fixture = CompactPartWriterW264Fixture
    [
      CrystalClick::CompactMarkFormat::Mrk3,
      CrystalClick::CompactMarkFormat::Mrk4,
    ].each do |mark_format|
      parent = File.tempname("crystal-click-w275-static-")
      plain = File.join(parent, "plain")
      compressed = File.join(parent, "compressed")
      begin
        Dir.mkdir(parent)
        CompactPartWriterW275Fixture.static(plain, mark_format).should eq(plain)
        CompactPartWriterW275Fixture.static(
          compressed,
          mark_format,
          compress_marks: true,
        ).should eq(compressed)

        plain_name = CompactPartWriterW275Fixture.mark_name(mark_format, false)
        compressed_name = CompactPartWriterW275Fixture.mark_name(mark_format, true)
        canonical_marks = CompactPartWriterW275Fixture.file_bytes(plain, plain_name)
        w275_assert_mark_checksums(plain, mark_format, false, canonical_marks)
        w275_assert_mark_checksums(compressed, mark_format, true, canonical_marks)
        CompactPartWriterW275Fixture.file_bytes(compressed, "data.bin").should eq(
          CompactPartWriterW275Fixture.file_bytes(plain, "data.bin"),
        )
        w275_assert_non_mark_files_equal(plain, compressed)

        plain_names = Dir.children(plain).select do |name|
          name.starts_with?("data.mrk") || name.starts_with?("data.cmrk")
        end.sort
        compressed_names = Dir.children(compressed).select do |name|
          name.starts_with?("data.mrk") || name.starts_with?("data.cmrk")
        end.sort
        plain_names.should eq([plain_name])
        compressed_names.should eq([compressed_name])

        physical = CrystalClick::CompactPartPhysicalContext.open(compressed)
        physical.mode.should eq(mark_format)
        physical.marks_name.should eq(compressed_name)
        physical.row_count.should eq(CompactPartWriterW264Fixture::ROW_COUNT.to_u64)
        physical.granule_count.should eq(CompactPartWriterW264Fixture::ROW_COUNT // CompactPartWriterW264Fixture::ROWS_PER_MARK)

        CompactPartWriterW264Fixture::COLUMN_NAMES.each do |column_name|
          reader = CrystalClick::CompactBinaryBulkColumnReader.open(
            compressed,
            column_name,
            fixture.types[column_name],
          )
          reader.read_marks(0, reader.mark_count).flatten.map do |value|
            fixture.row_signature(value)
          end.should eq(fixture.signatures_for(column_name))
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "routes compressed marks through the recursive Dynamic reader for both mark formats and discriminator modes" do
    fixture = CompactPartWriterW268Fixture
    [
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Compact},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Compact},
    ].each do |mark_format, discriminator_mode|
      parent = File.tempname("crystal-click-w275-dynamic-")
      part_path = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        CompactPartWriterW275Fixture.dynamic(
          part_path,
          mark_format,
          discriminator_mode,
          compress_marks: true,
        ).should eq(part_path)

        physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
        physical.mode.should eq(mark_format)
        physical.marks_name.should eq(CompactPartWriterW275Fixture.mark_name(mark_format, true))
        {
          CompactPartWriterW268Fixture::ROOT_COLUMN => fixture.root_type,
          CompactPartWriterW268Fixture::CTX_COLUMN  => fixture.ctx_type,
        }.each do |column_name, type|
          reader = CrystalClick::CompactDynamicBulkColumnReader.open(part_path, column_name, type)
          reader.mark_count.should eq(CompactPartWriterW268Fixture::MARK_COUNT)
          actual = fixture.signature(column_name, reader.read_marks(0, reader.mark_count).flatten)
          expected = if column_name == CompactPartWriterW268Fixture::ROOT_COLUMN
                       CompactPartWriterW268Fixture::ROOT_SIGNATURES
                     else
                       CompactPartWriterW268Fixture::CTX_SIGNATURES
                     end
          actual.should eq(expected)
          reader.read_marks(reader.mark_count, 0).should be_empty
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "keeps recursive JSON depth-two and depth-three consumers on compressed MRK3 and MRK4" do
    fixture = CompactPartWriterW273Fixture
    [
      {2, CrystalClick::CompactMarkFormat::Mrk3},
      {3, CrystalClick::CompactMarkFormat::Mrk4},
    ].each do |depth, mark_format|
      parent = File.tempname("crystal-click-w275-json-")
      part_path = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        CompactPartWriterW275Fixture.json(
          part_path,
          depth,
          mark_format,
          CrystalClick::CompactVariantDiscriminatorMode::Basic,
          compress_marks: true,
        ).should eq(part_path)

        physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
        physical.mode.should eq(mark_format)
        physical.marks_name.should eq(CompactPartWriterW275Fixture.mark_name(mark_format, true))

        expected = fixture.expected_literals(depth)
        recursive = CrystalClick::CompactRecursiveJsonColumnReader.open(
          part_path,
          CompactPartWriterW273Fixture::COLUMN_NAME,
          fixture.schema,
        )
        marks = recursive.read_marks(0, CompactPartWriterW273Fixture::MARK_COUNT)
        marks.size.should eq(CompactPartWriterW273Fixture::MARK_COUNT)
        marks.flatten.each_with_index do |row, index|
          fixture.literal_for(row, depth).should eq(expected[index])
        end
        marks.each_with_index do |mark_rows, mark_index|
          fixture.array_size_vectors_for_mark(mark_rows, depth).should eq(
            fixture.expected_mark_array_size_vectors(depth)[mark_index],
          )
        end
        recursive.read_marks(CompactPartWriterW273Fixture::MARK_COUNT, 0).should be_empty

        static_reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
          part_path,
          CompactPartWriterW273Fixture::COLUMN_NAME,
          fixture.declared_json_type,
        )
        static_rows = static_reader.read_marks(0, CompactPartWriterW273Fixture::MARK_COUNT).flatten.map do |document|
          CrystalClick::StorageColumnValue.object_document(document)
        end
        static_rows.size.should eq(expected.size)
        static_rows.each_with_index do |row, index|
          fixture.literal_for(row, depth).should eq(expected[index])
        end
        static_reader.read_marks(CompactPartWriterW273Fixture::MARK_COUNT, 0).should be_empty
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
