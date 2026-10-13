require "./spec_helper"
require "./support/compact_mark_file_adapter_w274_fixture"
require "./support/compact_part_writer_w264_fixture"
require "./support/compact_part_writer_w268_fixture"
require "./support/compact_part_writer_w273_fixture"

private def w274i_write_static_compact_part(
  part_path : String,
  mode : CrystalClick::CompactMarkFormat,
) : Nil
  fixture = CompactPartWriterW264Fixture
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW264Fixture::KEY_NAME,
    fixture.keys,
    fixture.columns,
    rows_per_mark: CompactPartWriterW264Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW264Fixture::FRAME_BYTES,
    mark_format: mode,
  )
  CompactMarkFileAdapterW274Fixture.compress_marks!(part_path, mode)
  nil
end

private def w274i_write_dynamic_compact_part(
  part_path : String,
  mode : CrystalClick::CompactMarkFormat,
) : Nil
  fixture = CompactPartWriterW268Fixture
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW268Fixture::KEY_NAME,
    fixture.keys,
    fixture.columns,
    rows_per_mark: CompactPartWriterW268Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW268Fixture::FRAME_BYTES,
    mark_format: mode,
    variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Basic,
  )
  CompactMarkFileAdapterW274Fixture.compress_marks!(part_path, mode)
  nil
end

private def w274i_write_json_compact_part(
  part_path : String,
  mode : CrystalClick::CompactMarkFormat,
) : Nil
  fixture = CompactPartWriterW273Fixture
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW273Fixture::KEY_NAME,
    CompactPartWriterW273Fixture::KEYS,
    [fixture.column(2)] of CrystalClick::CompactPartColumn,
    rows_per_mark: CompactPartWriterW273Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW273Fixture::FRAME_BYTES,
    mark_format: mode,
    variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Basic,
  )
  CompactMarkFileAdapterW274Fixture.compress_marks!(part_path, mode)
  nil
end

private def w274i_with_dynamic_compressed_part(mode : CrystalClick::CompactMarkFormat, &) : Nil
  root = File.tempname("crystal-click-w274-integration-dynamic")
  part = File.join(root, "all_1_1_0")
  Dir.mkdir(root)
  begin
    w274i_write_dynamic_compact_part(part, mode)
    yield part
  ensure
    FileUtils.rm_rf(root)
  end
  nil
end

private def w274i_with_json_compressed_part(mode : CrystalClick::CompactMarkFormat, &) : Nil
  root = File.tempname("crystal-click-w274-integration-json")
  part = File.join(root, "all_1_1_0")
  Dir.mkdir(root)
  begin
    w274i_write_json_compact_part(part, mode)
    yield part
  ensure
    FileUtils.rm_rf(root)
  end
  nil
end

private def w274i_offline_candidate(
  part_path : String,
  rows : UInt64,
) : CrystalClick::OfflinePartCandidate
  info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
  CrystalClick::OfflinePartCandidate.new("all_1_1_0", part_path, info, rows)
end

private def w274i_dynamic_offline_table(part_path : String) : CrystalClick::OfflineTable
  fixture = CompactPartWriterW268Fixture
  CrystalClick::OfflineTable.new(
    "w274_dynamic_events",
    "w274-dynamic-values-fixture",
    "MergeTree",
    [
      CrystalClick::OfflineColumn.new(CompactPartWriterW268Fixture::KEY_NAME, "UInt64"),
      CrystalClick::OfflineColumn.new(CompactPartWriterW268Fixture::ROOT_COLUMN, fixture.root_type.name),
    ] of CrystalClick::OfflineColumn,
    [w274i_offline_candidate(part_path, CompactPartWriterW268Fixture::ROW_COUNT.to_u64)] of CrystalClick::OfflinePartCandidate,
  )
end

private def w274i_json_offline_table(part_path : String) : CrystalClick::OfflineTable
  fixture = CompactPartWriterW273Fixture
  CrystalClick::OfflineTable.new(
    "w274_json_events",
    "w274-json-values-fixture",
    "MergeTree",
    [
      CrystalClick::OfflineColumn.new(CompactPartWriterW273Fixture::KEY_NAME, "UInt64"),
      CrystalClick::OfflineColumn.new(
        CompactPartWriterW273Fixture::COLUMN_NAME,
        fixture.declared_json_type.name,
      ),
    ] of CrystalClick::OfflineColumn,
    [w274i_offline_candidate(part_path, CompactPartWriterW273Fixture::ROW_COUNT.to_u64)] of CrystalClick::OfflinePartCandidate,
  )
end

private def w274i_with_legacy_wide_mark_sidecar(sidecar_name : String, &) : Nil
  root = File.tempname("crystal-click-w274-wide-mark-name")
  part = File.join(root, "all_1_1_0")
  Dir.mkdir(root)
  Dir.mkdir(part)
  begin
    raw = Bytes[1_u8, 2_u8, 3_u8, 4_u8]
    if sidecar_name.starts_with?("data.cmrk")
      CompactMarkFileAdapterW274Fixture.write_compressed_sidecar!(
        part,
        sidecar_name,
        CompactMarkFileAdapterW274Fixture.compressed_frame(raw),
        raw,
      )
    else
      File.write(File.join(part, sidecar_name), raw)
      CompactMarkFileAdapterW274Fixture.refresh_checksums(part)
    end
    yield part, CrystalClick::PartChecksums.open(part)
  ensure
    FileUtils.rm_rf(root)
  end
  nil
end

private def w274i_with_static_compressed_part(mode : CrystalClick::CompactMarkFormat, &) : Nil
  root = File.tempname("crystal-click-w274-integration-static")
  part = File.join(root, "all_1_1_0")
  Dir.mkdir(root)
  begin
    w274i_write_static_compact_part(part, mode)
    yield part
  ensure
    FileUtils.rm_rf(root)
  end
  nil
end

private def w274i_u64_signatures(values : Array(CrystalClick::BinaryValue)) : Array(String)
  values.map { |value| CompactPartWriterW264Fixture.row_signature(value) }
end

private def w274i_batch_u64(batch : CrystalClick::WidePartTableBatch) : Array(UInt64)
  batch.values_for("u").to_a
end

private def w274i_capture_table_window(
  table : CrystalClick::TypedPartTable,
  first_row : UInt64,
  max_rows : Int,
) : Array(UInt64)
  rows = [] of UInt64
  table.scan_typed_window(first_row, max_rows) do |batch|
    rows.concat(w274i_batch_u64(batch))
  end
  rows
end

describe "W274 compressed Compact marks through neutral typed APIs" do
  {
    CrystalClick::CompactMarkFormat::Mrk3 => "data.cmrk3",
    CrystalClick::CompactMarkFormat::Mrk4 => "data.cmrk4",
  }.each do |mode, compressed_name|
    it "opens #{compressed_name} through the direct Compact reader with the actual checksum identity" do
      w274i_with_static_compressed_part(mode) do |part|
        fixture = CompactPartWriterW264Fixture
        expected = fixture.signatures_for("u")
        direct = CrystalClick::CompactBinaryBulkColumnReader.open(
          part,
          "u",
          fixture.types["u"],
        )
        direct.schema_declaration.should eq("UInt64")
        direct.source_declaration.should eq("UInt64")
        direct.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
        direct.selected_checksum_names.should eq(["data.bin", compressed_name])
        w274i_u64_signatures(direct.read_marks(0, 4).flatten).should eq(expected)
        w274i_u64_signatures(direct.read_marks(1, 2).flatten).should eq(expected[2, 4])
        direct.read_marks(4, 0).should be_empty

        direct_names = direct.selected_checksum_names
        direct_names[1] = "mutated"
        direct.selected_checksum_names.should eq(["data.bin", compressed_name])
      end
    end

    it "routes #{compressed_name} through the neutral typed column reader" do
      w274i_with_static_compressed_part(mode) do |part|
        fixture = CompactPartWriterW264Fixture
        expected = fixture.signatures_for("u")
        expected_values = fixture.values_for("u")
        neutral = CrystalClick::TypedBinaryBulkColumnReader.open(
          part,
          "u",
          fixture.types["u"],
        )
        neutral.schema_declaration.should eq("UInt64")
        neutral.source_declaration.should eq("UInt64")
        neutral.row_count.should eq(CompactPartWriterW264Fixture::ROW_COUNT.to_u64)
        neutral.mark_count.should eq(4_i32)
        neutral.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
        neutral.selected_checksum_names.should eq(["data.bin", compressed_name])
        w274i_u64_signatures(neutral.read_marks(0, 4).flatten).should eq(expected)
        w274i_u64_signatures(neutral.read_marks(1, 2).flatten).should eq(expected[2, 4])
        neutral.read_marks(4, 0).should be_empty

        neutral_names = neutral.selected_checksum_names
        neutral_names[1] = "mutated"
        neutral.selected_checksum_names.should eq(["data.bin", compressed_name])
      end
    end

    it "routes #{compressed_name} through the typed table for full, middle, and EOF scans" do
      w274i_with_static_compressed_part(mode) do |part|
        fixture = CompactPartWriterW264Fixture
        expected_values = fixture.values_for("u")
        table = CrystalClick::TypedPartTable.open_selected_typed([part], ["pk", "u"])
        table.columns.should eq(["pk", "u"])
        table.column_types.should eq([{"pk", "UInt64"}, {"u", "UInt64"}])
        table.column_sources.should eq([
          {"pk", "pk", "UInt64"},
          {"u", "u", "UInt64"},
        ])
        table.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64, 2_u64]])
        table.total_row_count.should eq(CompactPartWriterW264Fixture::ROW_COUNT.to_u64)

        table_columns = table.columns
        table_columns[1] = "mutated"
        table.columns.should eq(["pk", "u"])
        table_types = table.column_types
        table_types[1] = {"changed", "String"}
        table.column_types.should eq([{"pk", "UInt64"}, {"u", "UInt64"}])
        table_sources = table.column_sources
        table_sources[1] = {"changed", "changed", "String"}
        table.column_sources.should eq([
          {"pk", "pk", "UInt64"},
          {"u", "u", "UInt64"},
        ])
        table_marks = table.part_mark_row_counts
        table_marks[0][0] = 99_u64
        table.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64, 2_u64]])

        full = [] of UInt64
        table.scan_typed { |batch| full.concat(w274i_batch_u64(batch)) }
        full.should eq(expected_values.map(&.as_uint64))
        w274i_capture_table_window(table, 2_u64, 3).should eq(expected_values[2, 3].map(&.as_uint64))
        eof_callbacks = 0
        table.scan_typed_window(CompactPartWriterW264Fixture::ROW_COUNT.to_u64, 1) { |_batch| eof_callbacks += 1 }
        eof_callbacks.should eq(0)
      end
    end
  end

  it "routes mixed declared and filesystem mark layouts to strict Compact validation" do
    mode = CrystalClick::CompactMarkFormat::Mrk3
    w274i_with_static_compressed_part(mode) do |part|
      # A physical-only sidecar is a Compact candidate, not permission to
      # silently take the Wide fallback after the declared compressed mark.
      File.write(File.join(part, "data.mrk4"), Bytes[0_u8])
      direct_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactBinaryBulkColumnReader.open(
          part,
          "u",
          CompactPartWriterW264Fixture.types["u"],
        )
      end
      direct_error.message.should eq("Compact mark sidecar inventory differs from checksums.txt")

      neutral_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::TypedBinaryBulkColumnReader.open(
          part,
          "u",
          CompactPartWriterW264Fixture.types["u"],
        )
      end
      neutral_error.message.should eq("Compact mark sidecar inventory differs from checksums.txt")

      table_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::TypedPartTable.open_selected_typed([part], ["pk", "u"])
      end
      table_error.message.should eq("Compact mark sidecar inventory differs from checksums.txt")
    end
  end

  it "routes unknown physical Compact suffixes to strict validation instead of Wide fallback" do
    mode = CrystalClick::CompactMarkFormat::Mrk4
    w274i_with_static_compressed_part(mode) do |part|
      File.write(File.join(part, "data.cmrkBogus"), Bytes[0_u8])
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::TypedBinaryBulkColumnReader.open(
          part,
          "u",
          CompactPartWriterW264Fixture.types["u"],
        )
      end
      error.message.should eq("part contains an undeclared or unsupported Compact mark sidecar")

      table_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::TypedPartTable.open_selected_typed([part], ["pk", "u"])
      end
      table_error.message.should eq("part contains an undeclared or unsupported Compact mark sidecar")
    end
  end

  it "keeps a valid upstream Wide part on the Wide reader path" do
    with_fixture_copy do |part|
      type = CrystalClick::BinaryDataType.primitive("UInt64")
      reader = CrystalClick::TypedBinaryBulkColumnReader.open(part, "value", type)
      reader.schema_declaration.should eq("UInt64")
      reader.source_declaration.should eq("UInt64")
      reader.row_count.should eq(200_000_u64)
      reader.selected_checksum_names.any? { |name| name.ends_with?(".mrk2") }.should be_true
      reader.read_marks(0, 1).flatten.map(&.as_uint64).should eq((0_u64...1024_u64).to_a)
    end
  end
end

describe "W274 exact Compact mark routing and reader identity" do
  it "does not route exact Wide mark names when declared and physically present" do
    observations = [] of Tuple(String, Bool, Bool, Bool)
    ["data.mrk", "data.mrk2", "data.cmrk", "data.cmrk2"].each do |wide_name|
      w274i_with_legacy_wide_mark_sidecar(wide_name) do |part, checksums|
        observations << {
          wide_name,
          File.file?(File.join(part, wide_name)),
          !checksums.entry(wide_name).nil?,
          CrystalClick::CompactMarkFileAdapter.routing_candidate?(part, checksums),
        }
      end
    end
    observations.should eq([
      {"data.mrk", true, true, false},
      {"data.mrk2", true, true, false},
      {"data.cmrk", true, true, false},
      {"data.cmrk2", true, true, false},
    ])
  end

  it "routes a physical-only Compact sidecar to strict rejection, not Wide fallback" do
    [
      {CrystalClick::CompactMarkFormat::Mrk3, "data.cmrk3"},
      {CrystalClick::CompactMarkFormat::Mrk4, "data.cmrk4"},
    ].each do |mode, compressed_name|
      w274i_with_static_compressed_part(mode) do |part|
        # Use an admitted UInt64 carrier so the public reader reaches the
        # physical inventory guard rather than an unrelated type gate.
        File.delete(File.join(part, compressed_name))
        CompactMarkFileAdapterW274Fixture.refresh_checksums(part)
        File.write(File.join(part, compressed_name), Bytes[0_u8])

        checksums = CrystalClick::PartChecksums.open(part)
        checksums.entry(compressed_name).should be_nil
        CrystalClick::CompactMarkFileAdapter.routing_candidate?(part, checksums).should be_true

        reader_error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::TypedBinaryBulkColumnReader.open(
            part,
            "u",
            CrystalClick::BinaryDataType.primitive("UInt64"),
          )
        end
        reader_error.message.should eq("Compact mark sidecar inventory differs from checksums.txt")

        table_error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::TypedPartTable.open_selected_typed([part], ["u"])
        end
        table_error.message.should eq("Compact mark sidecar inventory differs from checksums.txt")
      end
    end
  end

  {
    CrystalClick::CompactMarkFormat::Mrk3 => "data.cmrk3",
    CrystalClick::CompactMarkFormat::Mrk4 => "data.cmrk4",
  }.each do |mode, compressed_name|
    it "preserves the actual #{compressed_name} identity in the Dynamic Compact reader" do
      w274i_with_dynamic_compressed_part(mode) do |part|
        fixture = CompactPartWriterW268Fixture
        reader = CrystalClick::CompactDynamicBulkColumnReader.open(
          part,
          CompactPartWriterW268Fixture::ROOT_COLUMN,
          fixture.root_type,
        )
        reader.selected_checksum_names.should eq(["data.bin", compressed_name])
        fixture.signature(
          CompactPartWriterW268Fixture::ROOT_COLUMN,
          reader.read_marks(0, CompactPartWriterW268Fixture::MARK_COUNT).flatten,
        ).should eq(CompactPartWriterW268Fixture::ROOT_SIGNATURES)
      end
    end

    it "routes #{compressed_name} through offline Dynamic values" do
      w274i_with_dynamic_compressed_part(mode) do |part|
        fixture = CompactPartWriterW268Fixture
        offline = w274i_dynamic_offline_table(part)
        offline_values = offline[CompactPartWriterW268Fixture::ROOT_COLUMN].values(
          max_rows: CompactPartWriterW268Fixture::ROW_COUNT.to_u64,
        ).map { |value| value.as(CrystalClick::BinaryValue) }
        fixture.signature(CompactPartWriterW268Fixture::ROOT_COLUMN, offline_values).should eq(
          CompactPartWriterW268Fixture::ROOT_SIGNATURES,
        )
      end
    end

    it "preserves the actual #{compressed_name} identity in recursive JSON" do
      w274i_with_json_compressed_part(mode) do |part|
        fixture = CompactPartWriterW273Fixture
        expected = fixture.expected_literals(2)

        context = CrystalClick::CompactPartPhysicalContext.open(part)
        context.marks_name.should eq(compressed_name)

        recursive = CrystalClick::CompactRecursiveJsonColumnReader.open(
          part,
          CompactPartWriterW273Fixture::COLUMN_NAME,
          fixture.schema,
        )
        recursive.selected_checksum_names.should eq(["data.bin", compressed_name])
        recursive_values = recursive.read_marks(0, CompactPartWriterW273Fixture::MARK_COUNT).flatten
        recursive_values.map { |value| fixture.literal_for(value, 2) }.should eq(expected)
      end
    end

    it "preserves the actual #{compressed_name} identity in static JSON" do
      w274i_with_json_compressed_part(mode) do |part|
        fixture = CompactPartWriterW273Fixture
        expected = fixture.expected_literals(2)
        static_root = CrystalClick::CompactStaticJsonBulkColumnReader.open(
          part,
          CompactPartWriterW273Fixture::COLUMN_NAME,
          fixture.declared_json_type,
        )
        static_root.selected_checksum_names.should eq(["data.bin", compressed_name])
        static_values = static_root.read_marks(0, CompactPartWriterW273Fixture::MARK_COUNT).flatten
        static_values.map do |document|
          fixture.literal_for(CrystalClick::StorageColumnValue.object_document(document), 2)
        end.should eq(expected)
      end
    end

    it "routes #{compressed_name} through offline JSON values" do
      w274i_with_json_compressed_part(mode) do |part|
        fixture = CompactPartWriterW273Fixture
        expected = fixture.expected_literals(2)
        offline = w274i_json_offline_table(part)
        offline_values = offline[CompactPartWriterW273Fixture::COLUMN_NAME].values(
          max_rows: CompactPartWriterW273Fixture::ROW_COUNT.to_u64,
        )
        offline_values.map do |value|
          fixture.literal_for(
            CrystalClick::StorageColumnValue.object_document(value.as(CrystalClick::ObjectDocument)),
            2,
          )
        end.should eq(expected)
      end
    end
  end
end
