require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w275_fixture"
require "./support/compact_mark_file_adapter_w274_fixture"

private def w275_assert_no_side_effect(parent : String, target : String) : Nil
  File.exists?(target).should be_false
  Dir.children(parent).sort.should eq(["keep.txt"])
  File.read(File.join(parent, "keep.txt")).should eq("unrelated")
  nil
end

private def w275_attempt_static(
  target : String,
  mark_format : CrystalClick::CompactMarkFormat = CrystalClick::CompactMarkFormat::Mrk3,
  variant_discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode = CrystalClick::CompactVariantDiscriminatorMode::Compact,
  frame_bytes : Int = CompactPartWriterW264Fixture::FRAME_BYTES,
  transport_limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new,
  reader_limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new,
  compress_marks : Bool = true,
) : String
  fixture = CompactPartWriterW264Fixture
  CrystalClick::CompactPartWriter.write_uint64_columns(
    target,
    CompactPartWriterW264Fixture::KEY_NAME,
    fixture.keys,
    fixture.columns,
    rows_per_mark: CompactPartWriterW264Fixture::ROWS_PER_MARK,
    frame_bytes: frame_bytes,
    transport_limits: transport_limits,
    reader_limits: reader_limits,
    mark_format: mark_format,
    variant_discriminator_mode: variant_discriminator_mode,
    compress_marks: compress_marks,
  )
end

private def w275_canonical_mark_files(
  marks : Bytes,
  marks_hash : {UInt64, UInt64}? = nil,
) : CrystalClick::CompactStaticPartFiles
  data = Bytes[0x41_u8, 0x42_u8]
  CrystalClick::CompactStaticPartFiles.new(
    data,
    marks,
    data.size.to_u64,
    {0_u64, 0_u64},
    CrystalClick::CityHashV1.file_hash(data),
    marks_hash || CrystalClick::CityHashV1.file_hash(marks),
  )
end

private def w275_assert_budget_counts(
  budget : CrystalClick::CompressedStreamBudget,
  file_bytes : Int64,
  records : Int64,
  decoded_bytes : Int64,
  result_bytes : Int64,
) : Nil
  budget.file_byte_count.should eq(file_bytes)
  budget.record_count.should eq(records)
  budget.decoded_byte_count.should eq(decoded_bytes)
  budget.result_byte_count.should eq(result_bytes)
  nil
end

private def w275_assert_budget_unconsumed(budget : CrystalClick::CompressedStreamBudget) : Nil
  w275_assert_budget_counts(budget, 0_i64, 0_i64, 0_i64, 0_i64)
  nil
end

private def w275_rewrite_compressed_checksum(
  part_path : String,
  mark_format : CrystalClick::CompactMarkFormat,
  raw_marks : Bytes,
  fault : String,
) : Nil
  name = CompactPartWriterW275Fixture.mark_name(mark_format, true)
  case fault
  when "compressed flag"
    CompactMarkFileAdapterW274Fixture.refresh_checksums(
      part_path,
      name,
      raw_marks,
      false,
    )
  when "raw size"
    CompactMarkFileAdapterW274Fixture.refresh_checksums(
      part_path,
      name,
      raw_marks,
      true,
      raw_marks.size.to_u64 + 1_u64,
    )
  when "raw hash"
    raw_hash = CrystalClick::CityHashV1.file_hash(raw_marks)
    CompactMarkFileAdapterW274Fixture.refresh_checksums(
      part_path,
      name,
      raw_marks,
      true,
      nil,
      {raw_hash[0] ^ 1_u64, raw_hash[1]},
    )
  when "physical hash"
    physical_hash = CrystalClick::CityHashV1.file_hash(
      CompactPartWriterW275Fixture.file_bytes(part_path, name),
    )
    CompactMarkFileAdapterW274Fixture.refresh_checksums(
      part_path,
      name,
      raw_marks,
      true,
      nil,
      nil,
      {physical_hash[0] ^ 1_u64, physical_hash[1]},
    )
  else
    raise ArgumentError.new("unknown W275 checksum mutation")
  end
  nil
end

describe "W275 compressed Compact marks writer adversaries" do
  it "preflights complete compressed-mark output without consuming budgets" do
    raw = Bytes.new(17, 0x41_u8)
    frame_bytes = 8
    budget = CrystalClick::CompressedStreamBudget.write_default
    physical_size = CrystalClick::CompressedMarkWriter.preflight_all(
      raw.size.to_i64,
      frame_bytes,
      budget,
    )
    physical_size.should eq(
      CrystalClick::CompressedMarkWriter.encode_all(raw, frame_bytes: frame_bytes).size.to_i32,
    )
    w275_assert_budget_unconsumed(budget)

    [
      {"frame decompressed", CrystalClick::CompressedStreamLimits.new(max_frame_decompressed_bytes: 7)},
      {"frame compressed", CrystalClick::CompressedStreamLimits.new(max_frame_compressed_bytes: 0)},
      {"file", CrystalClick::CompressedStreamLimits.new(max_file_bytes: 1)},
      {"decoded", CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: 1)},
      {"record", CrystalClick::CompressedStreamLimits.new(max_records: 1)},
      {"result", CrystalClick::CompressedStreamLimits.new(max_result_bytes: 1)},
    ].each do |_dimension, limits|
      limited = CrystalClick::CompressedStreamBudget.new(limits, writing: true)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompressedMarkWriter.preflight_all(raw.size.to_i64, frame_bytes, limited)
      end
      w275_assert_budget_unconsumed(limited)
    end

    invalid_frame = CrystalClick::CompressedStreamBudget.write_default
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.preflight_all(raw.size.to_i64, 0, invalid_frame)
    end
    w275_assert_budget_unconsumed(invalid_frame)

    invalid_domain = CrystalClick::CompressedStreamBudget.write_default
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.preflight_all(0_i64, frame_bytes, invalid_domain)
    end
    w275_assert_budget_unconsumed(invalid_domain)
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.preflight_all(-1_i64, frame_bytes, invalid_domain)
    end
    w275_assert_budget_unconsumed(invalid_domain)

    wrong_direction = CrystalClick::CompressedStreamBudget.read_default
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.preflight_all(raw.size.to_i64, frame_bytes, wrong_direction)
    end
    w275_assert_budget_unconsumed(wrong_direction)

    oversized_input = CrystalClick::CompressedStreamBudget.write_default
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.preflight_all(Int32::MAX.to_i64 + 1_i64, 1, oversized_input)
    end
    w275_assert_budget_unconsumed(oversized_input)

    oversized_output = CrystalClick::CompressedStreamBudget.write_default
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.preflight_all(Int32::MAX.to_i64 // 2_i64, 1, oversized_output)
    end
    w275_assert_budget_unconsumed(oversized_output)
  end

  it "preflights against remaining charged capacity without changing prior charges" do
    raw_size = 17_i64
    frame_bytes = 8
    needed_file_bytes = CrystalClick::CompressedMarkWriter.preflight_all(
      raw_size,
      frame_bytes,
      CrystalClick::CompressedStreamBudget.write_default,
    ).to_i64
    needed_records = 1_i64 + (raw_size - 1_i64) // frame_bytes.to_i64

    prior_file_bytes = 7_i64
    prior_records = 2_i64
    prior_decoded_bytes = 5_i64
    prior_result_bytes = 11_i64
    exact_limits = CrystalClick::CompressedStreamLimits.new(
      max_file_bytes: prior_file_bytes + needed_file_bytes,
      max_records: prior_records + needed_records,
      max_decoded_bytes: prior_decoded_bytes + raw_size,
      max_result_bytes: prior_result_bytes + needed_file_bytes,
    )
    exact_budget = CrystalClick::CompressedStreamBudget.new(exact_limits, writing: true)
    exact_budget.reserve_file_bytes(prior_file_bytes)
    exact_budget.reserve_records(prior_records)
    exact_budget.reserve_decoded_bytes(prior_decoded_bytes)
    exact_budget.reserve_result_bytes(prior_result_bytes)
    CrystalClick::CompressedMarkWriter.preflight_all(raw_size, frame_bytes, exact_budget)
      .should eq(needed_file_bytes.to_i32)
    w275_assert_budget_counts(
      exact_budget,
      prior_file_bytes,
      prior_records,
      prior_decoded_bytes,
      prior_result_bytes,
    )

    one_short_limits = CrystalClick::CompressedStreamLimits.new(
      max_file_bytes: prior_file_bytes + needed_file_bytes,
      max_records: prior_records + needed_records - 1_i64,
      max_decoded_bytes: prior_decoded_bytes + raw_size,
      max_result_bytes: prior_result_bytes + needed_file_bytes,
    )
    one_short_budget = CrystalClick::CompressedStreamBudget.new(one_short_limits, writing: true)
    one_short_budget.reserve_file_bytes(prior_file_bytes)
    one_short_budget.reserve_records(prior_records)
    one_short_budget.reserve_decoded_bytes(prior_decoded_bytes)
    one_short_budget.reserve_result_bytes(prior_result_bytes)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.preflight_all(raw_size, frame_bytes, one_short_budget)
    end
    w275_assert_budget_counts(
      one_short_budget,
      prior_file_bytes,
      prior_records,
      prior_decoded_bytes,
      prior_result_bytes,
    )
  end

  it "uses an exact max_mark_bytes cap and rejects one byte below it before publication" do
    parent = File.tempname("crystal-click-w275-mark-cap-")
    exact_stage = File.join(parent, "exact-stage")
    begin
      Dir.mkdir(parent)
      mode = CrystalClick::CompactMarkFormat::Mrk3
      canonical_marks = Bytes.new(73, 0x5A_u8)
      files = w275_canonical_mark_files(canonical_marks)
      physical_size = CrystalClick::CompressedMarkWriter.preflight_all(
        canonical_marks.size.to_i64,
        CompactPartWriterW264Fixture::FRAME_BYTES,
        CrystalClick::CompressedStreamBudget.write_default,
      ).to_i64
      raw_size = canonical_marks.size.to_i64
      exact_cap = raw_size > physical_size ? raw_size : physical_size
      exact_cap.should be > 1

      exact_budget = CrystalClick::CompressedStreamBudget.new(
        CrystalClick::CompressedStreamLimits.new(max_mark_bytes: exact_cap),
        writing: true,
      )
      output = CrystalClick::CompactPhysicalMarkOutput.from_canonical_files(
        files,
        mode,
        true,
        CompactPartWriterW264Fixture::FRAME_BYTES,
        exact_budget,
      )
      output.name.should eq("data.cmrk3")
      output.checksum_record.compressed.should be_true
      output.checksum_record.physical_size.should eq(physical_size.to_u64)
      output.checksum_record.uncompressed_size.should eq(raw_size.to_u64)
      output.checksum_record.uncompressed_hash.should eq(CrystalClick::CityHashV1.file_hash(canonical_marks))
      Dir.mkdir(exact_stage)
      output.write_to(exact_stage)
      physical_marks = CompactPartWriterW275Fixture.file_bytes(exact_stage, "data.cmrk3")
      physical_marks.size.to_i64.should eq(physical_size)
      CrystalClick::CityHashV1.file_hash(physical_marks).should eq(output.checksum_record.file_hash)
      CrystalClick::CompressedMarkReader.read_all(
        File.join(exact_stage, "data.cmrk3"),
        physical_size,
        CrystalClick::CompressedStreamBudget.read_default,
        raw_size,
        output.checksum_record.file_hash,
      ).should eq(canonical_marks)

      tight_stage = File.join(parent, "tight-stage")
      Dir.mkdir(tight_stage)
      File.write(File.join(tight_stage, "keep.txt"), "unrelated")
      short_budget = CrystalClick::CompressedStreamBudget.new(
        CrystalClick::CompressedStreamLimits.new(max_mark_bytes: exact_cap - 1),
        writing: true,
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompactPhysicalMarkOutput.from_canonical_files(
          files,
          mode,
          true,
          CompactPartWriterW264Fixture::FRAME_BYTES,
          short_budget,
        )
      end
      Dir.children(tight_stage).sort.should eq(["keep.txt"])
      File.read(File.join(tight_stage, "keep.txt")).should eq("unrelated")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "authenticates the canonical marks hash and owns a detached sidecar payload" do
    canonical_source = Bytes.new(73, 0x5A_u8)
    expected_marks = canonical_source.dup
    source_hash = CrystalClick::CityHashV1.file_hash(expected_marks)
    forged_hash = {source_hash[0] ^ 1_u64, source_hash[1]}
    forged_files = w275_canonical_mark_files(canonical_source, forged_hash)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompactPhysicalMarkOutput.from_canonical_files(
        forged_files,
        CrystalClick::CompactMarkFormat::Mrk3,
        true,
        CompactPartWriterW264Fixture::FRAME_BYTES,
        CrystalClick::CompressedStreamBudget.write_default,
      )
    end

    parent = File.tempname("crystal-click-w275-owned-mark-payload-")
    stage = File.join(parent, "stage")
    begin
      Dir.mkdir(parent)
      owned_files = w275_canonical_mark_files(canonical_source)
      output = CrystalClick::CompactPhysicalMarkOutput.from_canonical_files(
        owned_files,
        CrystalClick::CompactMarkFormat::Mrk3,
        true,
        CompactPartWriterW264Fixture::FRAME_BYTES,
        CrystalClick::CompressedStreamBudget.write_default,
      )

      canonical_source[0] = 0_u8
      detached_snapshot = owned_files.marks
      detached_snapshot[1] = 0_u8
      Dir.mkdir(stage)
      output.write_to(stage)

      name = CompactPartWriterW275Fixture.mark_name(CrystalClick::CompactMarkFormat::Mrk3, true)
      physical_size = File.size(File.join(stage, name))
      decoded = CrystalClick::CompressedMarkReader.read_all(
        File.join(stage, name),
        physical_size,
        CrystalClick::CompressedStreamBudget.read_default,
        expected_marks.size.to_i64,
        output.checksum_record.file_hash,
      )
      decoded.should eq(expected_marks)
      output.checksum_record.uncompressed_hash.should eq(source_hash)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "charges exact compressed-owner file and result bytes and preflights aggregate result first" do
    canonical_marks = Bytes.new(73, 0x5A_u8)
    files = w275_canonical_mark_files(canonical_marks)
    raw_size = canonical_marks.size.to_i64
    frame_bytes = CompactPartWriterW264Fixture::FRAME_BYTES
    physical_size = CrystalClick::CompressedMarkWriter.preflight_all(
      raw_size,
      frame_bytes,
      CrystalClick::CompressedStreamBudget.write_default,
    ).to_i64
    frame_count = 1_i64 + (raw_size - 1_i64) // frame_bytes.to_i64
    aggregate_bytes = raw_size + physical_size
    max_mark_size = raw_size > physical_size ? raw_size : physical_size

    exact_budget = CrystalClick::CompressedStreamBudget.new(
      CrystalClick::CompressedStreamLimits.new(
        max_file_bytes: aggregate_bytes,
        max_mark_bytes: max_mark_size,
        max_records: frame_count,
        max_decoded_bytes: raw_size,
        max_result_bytes: aggregate_bytes,
      ),
      writing: true,
    )
    exact_budget.reserve_file_bytes(raw_size)
    CrystalClick::CompactPhysicalMarkOutput.from_canonical_files(
      files,
      CrystalClick::CompactMarkFormat::Mrk4,
      true,
      frame_bytes,
      exact_budget,
    ).name.should eq("data.cmrk4")
    w275_assert_budget_counts(
      exact_budget,
      aggregate_bytes,
      frame_count,
      raw_size,
      aggregate_bytes,
    )

    one_short_budget = CrystalClick::CompressedStreamBudget.new(
      CrystalClick::CompressedStreamLimits.new(
        max_mark_bytes: max_mark_size,
        max_records: frame_count,
        max_decoded_bytes: raw_size,
        max_result_bytes: aggregate_bytes - 1_i64,
      ),
      writing: true,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompactPhysicalMarkOutput.from_canonical_files(
        files,
        CrystalClick::CompactMarkFormat::Mrk4,
        true,
        frame_bytes,
        one_short_budget,
      )
    end
    w275_assert_budget_unconsumed(one_short_budget)
  end

  it "rejects tight file, decoded-byte, record, and result budgets without staging or publication" do
    limits_by_dimension = [
      {"file", CrystalClick::CompressedStreamLimits.new(max_file_bytes: 1)},
      {"decoded", CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: 1)},
      {"record", CrystalClick::CompressedStreamLimits.new(max_records: 1)},
      {"result", CrystalClick::CompressedStreamLimits.new(max_result_bytes: 1)},
    ] of Tuple(String, CrystalClick::CompressedStreamLimits)

    limits_by_dimension.each do |dimension, transport_limits|
      parent = File.tempname("crystal-click-w275-#{dimension}-budget-")
      target = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        File.write(File.join(parent, "keep.txt"), "unrelated")
        expect_raises(CrystalClick::UnsupportedFormatError) do
          w275_attempt_static(target, transport_limits: transport_limits)
        end
        w275_assert_no_side_effect(parent, target)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "cleans the unpublished stage when compressed-mark readback exhausts reader budget" do
    parent = File.tempname("crystal-click-w275-reader-budget-")
    target = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      File.write(File.join(parent, "keep.txt"), "unrelated")
      reader_limits = CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: 0)
      expect_raises(CrystalClick::CorruptPartError) do
        w275_attempt_static(target, reader_limits: reader_limits)
      end
      w275_assert_no_side_effect(parent, target)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects invalid mark format and frame size before creating a stage" do
    invalid_format_parent = File.tempname("crystal-click-w275-invalid-format-")
    invalid_mode_parent = File.tempname("crystal-click-w275-invalid-mode-")
    invalid_frame_parent = File.tempname("crystal-click-w275-invalid-frame-")
    invalid_format_target = File.join(invalid_format_parent, "all_1_1_0")
    invalid_mode_target = File.join(invalid_mode_parent, "all_1_1_0")
    invalid_frame_target = File.join(invalid_frame_parent, "all_1_1_0")
    begin
      Dir.mkdir(invalid_format_parent)
      File.write(File.join(invalid_format_parent, "keep.txt"), "unrelated")
      unknown_format = CrystalClick::CompactMarkFormat.new(9_u64)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w275_attempt_static(invalid_format_target, mark_format: unknown_format)
      end
      w275_assert_no_side_effect(invalid_format_parent, invalid_format_target)

      Dir.mkdir(invalid_mode_parent)
      File.write(File.join(invalid_mode_parent, "keep.txt"), "unrelated")
      unknown_mode = CrystalClick::CompactVariantDiscriminatorMode.new(9_u64)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w275_attempt_static(invalid_mode_target, variant_discriminator_mode: unknown_mode)
      end
      w275_assert_no_side_effect(invalid_mode_parent, invalid_mode_target)

      Dir.mkdir(invalid_frame_parent)
      File.write(File.join(invalid_frame_parent, "keep.txt"), "unrelated")
      expect_raises(ArgumentError, "Compact frame size must be a positive Int32 value") do
        w275_attempt_static(invalid_frame_target, frame_bytes: 0)
      end
      w275_assert_no_side_effect(invalid_frame_parent, invalid_frame_target)
    ensure
      FileUtils.rm_rf(invalid_format_parent)
      FileUtils.rm_rf(invalid_mode_parent)
      FileUtils.rm_rf(invalid_frame_parent)
    end
  end

  it "rejects compressed-mark checksum flag, raw size/hash, and physical hash inconsistencies" do
    mark_format = CrystalClick::CompactMarkFormat::Mrk3
    plain_parent = File.tempname("crystal-click-w275-checksum-source-")
    plain_path = File.join(plain_parent, "all_1_1_0")
    begin
      Dir.mkdir(plain_parent)
      CompactPartWriterW275Fixture.static(plain_path, mark_format).should eq(plain_path)
      raw_marks = CompactPartWriterW275Fixture.file_bytes(plain_path, "data.mrk3")

      ["compressed flag", "raw size", "raw hash", "physical hash"].each do |fault|
        parent = File.tempname("crystal-click-w275-#{fault.gsub(' ', '-')}-")
        part_path = File.join(parent, "all_1_1_0")
        begin
          Dir.mkdir(parent)
          CompactPartWriterW275Fixture.static(
            part_path,
            mark_format,
            compress_marks: true,
          ).should eq(part_path)
          w275_rewrite_compressed_checksum(part_path, mark_format, raw_marks, fault)
          expect_raises(CrystalClick::CorruptPartError) do
            CrystalClick::CompactPartPhysicalContext.open(part_path)
          end
        ensure
          FileUtils.rm_rf(parent)
        end
      end
    ensure
      FileUtils.rm_rf(plain_parent)
    end
  end
end
