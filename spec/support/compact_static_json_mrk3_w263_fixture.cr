require "json"
require "file_utils"
require "../../scripts/support/compact_json_w263_fixture"
require "../../scripts/support/compact_physical_context_w259_fixture"

module CompactStaticJsonMrk3W263Fixture
  extend self

  LABEL = "obj_v1_dyn_v1_map_mrk3_s0_variant_basic"

  def evidence_root : String
    root = ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]? ||
           raise "CRYSTAL_CLICK_W263_EVIDENCE_ROOT must name the independently checked W263 capture"
    File.realpath(root)
  end

  def source_part(root : String = evidence_root) : NamedTuple(path: String, inventory: Array(Tuple(String, Int64, String)))
    summary_path = File.join(root, "summary.json")
    raise "W263 capture summary is missing" unless File.file?(summary_path)
    summary = JSON.parse(File.read(summary_path))
    raise "unexpected W263 capture format" unless summary["format"].as_s == "compact_json_w263_probe_summary_v1"
    raise "W263 source capture is not the expected refusal baseline" unless summary["status"].as_s == "expected_json_unsupported"
    raise "W263 native capture did not complete successfully" unless summary["native_invocation"]["exit"].as_i == 0
    raise "W263 native capture did not classify as success" unless summary["native_invocation"]["process_classification"].as_s == "success"
    raise "W263 native runtime pin differs" unless summary["clickhouse"]["sha256"].as_s == CompactJsonW263Fixture::NATIVE_BINARY_SHA256
    raise "W263 capture does not contain the complete native matrix" unless summary["cells"].as_a.size == 48
    raise "W263 capture is missing the selected native label" unless summary["cells"].as_a.any? { |cell| cell.as_s == LABEL }

    record = summary["parts"][LABEL]
    raise "selected W263 part is not Compact" unless record["part_type"].as_s == "Compact"
    raise "selected W263 part is not the eight-row fixture" unless record["rows"].as_s == "8"
    raise "selected W263 part is not mrk3" unless record["mark_extension"].as_s == ".mrk3"
    raise "selected W263 part name differs from the capture summary" unless record["part_name"].as_s == File.basename(record["path"].as_s)

    part_path = File.realpath(record["path"].as_s)
    root_prefix = root.ends_with?(File::SEPARATOR) ? root : root + File::SEPARATOR
    raise "W263 part path escapes the explicitly supplied evidence root" unless part_path.starts_with?(root_prefix)
    %w[columns.txt count.txt checksums.txt data.bin data.mrk3].each do |name|
      raise "selected W263 native part is missing #{name}" unless File.file?(File.join(part_path, name))
    end

    manifest_path = File.join(root, "parts", "native_manifest.json")
    unless File.file?(manifest_path) && !File.symlink?(manifest_path) && File.realpath(manifest_path) == manifest_path
      raise "W263 native manifest is absent, linked or noncanonical"
    end
    raise "W263 native manifest exceeds its byte bound" if File.size(manifest_path) > 4 * 1024 * 1024
    manifest = JSON.parse(File.read(manifest_path))
    raise "W263 native manifest format differs" unless manifest["format"].as_s == CompactJsonW263Fixture::NATIVE_MANIFEST_FORMAT
    raise "W263 native manifest is not the expected baseline capture" unless manifest["mode"].as_s == "baseline"
    manifest_entry = manifest["parts"].as_a.find { |item| item["label"].as_s == LABEL } ||
                     raise "W263 native manifest lacks the selected MRK3 cell"
    raise "W263 summary/native manifest path differs" unless manifest_entry["path"].as_s == record["path"].as_s

    inventory = manifest_entry["file_inventory"].as_a.map do |item|
      {item["path"].as_s, item["bytes"].as_i64, item["sha256"].as_s}
    end
    CompactJsonW263Fixture.assert_native_inventory!(part_path, inventory)
    {path: part_path, inventory: inventory}
  end

  def copy_part(source_part : String) : Tuple(String, String)
    parent = File.tempname("crystal-click-w263-mrk3-adversary-")
    Dir.mkdir(parent, 0o700)
    copied_part = File.join(parent, File.basename(source_part))
    FileUtils.cp_r(source_part, copied_part)
    {parent, copied_part}
  end

  # Reframes the complete logical tape after increasing the first V1 Object
  # path count. Re-encoding the outer LZ4 stream and every global mrk3 pair
  # keeps transport checksums and source-coordinate authentication valid, so
  # the reader must reject the changed Object-to-Dynamic grammar boundary.
  def corrupt_first_object_path_count!(part_path : String) : Tuple(Int64, Int32)
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    raise "selected adversary source is not mrk3" unless physical.mode.mrk3?
    raise "selected adversary row grid differs" unless physical.mark_row_counts == [2_u64, 2_u64, 2_u64, 2_u64]

    compressed_data = File.read(File.join(part_path, "data.bin")).to_slice
    raw = CrystalClick::CompressedBlock.decode_all(compressed_data)
    root_window = physical.read_window("root", 0, 1).granules.first? ||
                  raise CrystalClick::CorruptPartError.new("MRK3 root first mark is missing")
    root_shard = root_window.shards.first? ||
                 raise CrystalClick::CorruptPartError.new("MRK3 root first shard is missing")
    root_start = root_shard.logical_start.to_i
    root_bytes = root_shard.bytes
    raise "V1 Object prefix does not contain its path-count field" if root_bytes.size <= 9
    raise "stock V1 Object version differs" unless raw[root_start, 8].all? { |byte| byte == 0_u8 }
    raise "stock V1 Object path-count is not the expected two" unless raw[root_start + 9] == 2_u8
    raw[root_start + 9] = 3_u8

    reframe_mrk3_tape!(part_path, physical, raw)

    reopened = CrystalClick::CompactPartPhysicalContext.open(part_path)
    raise "reframed adversary changed the MRK3 mode" unless reopened.mode.mrk3?
    raise "reframed adversary changed the source row grid" unless reopened.mark_row_counts == [2_u64, 2_u64, 2_u64, 2_u64]
    observed_root = reopened.read_window("root", 0, 1).granules.first?.try(&.shards.first?) ||
                    raise CrystalClick::CorruptPartError.new("reframed MRK3 root shard is missing")
    unless observed_root.logical_start == root_shard.logical_start && observed_root.bytes.size == root_bytes.size
      raise "reframed MRK3 root interval changed"
    end
    unless observed_root.byte_at(9) == 3_u8
      raise "reframed MRK3 Object path-count mutation did not survive the authenticated read"
    end

    {root_shard.logical_start, root_shard.bytes.size}
  end

  # Changes the first V1 MAP Array(String) sizes value from one to two without
  # changing tape length. Literal lane and following key checks pin the native
  # parser boundary before the shared transport-preserving reframe is applied.
  def corrupt_first_map_size_count!(part_path : String) : Tuple(Int64, Int32)
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    raise "selected adversary source is not mrk3" unless physical.mode.mrk3?
    raise "selected adversary row grid differs" unless physical.mark_row_counts == [2_u64, 2_u64, 2_u64, 2_u64]

    compressed_data = File.read(File.join(part_path, "data.bin")).to_slice
    raw = CrystalClick::CompressedBlock.decode_all(compressed_data)
    root_shard = physical.read_window("root", 0, 1).granules.first?.try(&.shards.first?) ||
                 raise CrystalClick::CorruptPartError.new("MRK3 root first shard is missing")
    root_start = root_shard.logical_start.to_i
    root_bytes = root_shard.bytes
    raise "stock root tape is too short for its first MAP sizes lane" if root_bytes.size < 182

    expected_sizes = Bytes[1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8]
    unless root_bytes[154, 16] == expected_sizes
      raise "stock root tape first MAP sizes lane differs from [1, 1] at offset 154"
    end
    expected_key_prefix = Bytes[11_u8, 0x7a_u8, 0x7a_u8, 0x5f_u8, 0x6f_u8, 0x76_u8,
      0x65_u8, 0x72_u8, 0x66_u8, 0x6c_u8, 0x6f_u8, 0x77_u8]
    unless root_bytes[170, 12] == expected_key_prefix
      raise "stock root tape first MAP key prefix differs at offset 170"
    end
    unless raw[root_start + 154, 16] == expected_sizes && raw[root_start + 170, 12] == expected_key_prefix
      raise "stock root tape logical coordinates differ from the authenticated root shard"
    end

    # The first little-endian UInt64 changes from 1 to 2 in-place; every other
    # byte and the MAP data lane boundary remain unchanged.
    raw[root_start + 154] = 2_u8
    reframe_mrk3_tape!(part_path, physical, raw)

    reopened = CrystalClick::CompactPartPhysicalContext.open(part_path)
    raise "reframed MAP adversary changed the MRK3 mode" unless reopened.mode.mrk3?
    raise "reframed MAP adversary changed the source row grid" unless reopened.mark_row_counts == [2_u64, 2_u64, 2_u64, 2_u64]
    observed_root = reopened.read_window("root", 0, 1).granules.first?.try(&.shards.first?) ||
                    raise CrystalClick::CorruptPartError.new("reframed MRK3 root shard is missing")
    unless observed_root.logical_start == root_shard.logical_start && observed_root.bytes.size == root_bytes.size
      raise "reframed MAP root interval changed"
    end
    unless observed_root.byte_at(154) == 2_u8 && observed_root.byte_at(162) == 1_u8 &&
           observed_root.bytes[170, 12] == expected_key_prefix
      raise "reframed MAP sizes mutation did not survive the authenticated read"
    end

    {root_shard.logical_start, root_shard.bytes.size}
  end

  private def reframe_mrk3_tape!(
    part_path : String,
    physical : CrystalClick::CompactPartPhysicalContext,
    raw : Bytes,
  ) : Nil
    slots = physical.physical_roster
    raise "MRK3 native root fixture has no physical slots" if slots.empty?
    slot_positions = slots.map do |slot|
      window = physical.read_window(slot.column_name, 0, physical.granule_count)
      raise "MRK3 source column has an incomplete mark window" unless window.granules.size == physical.granule_count
      window.granules.map do |granule|
        shard = granule.shards.first? || raise CrystalClick::CorruptPartError.new("MRK3 slot has no whole-column shard")
        shard.logical_start
      end
    end

    queries = [] of UInt64
    physical.granule_count.times do |mark_index|
      slots.each_with_index do |_slot, slot_index|
        queries << slot_positions[slot_index][mark_index].to_u64
      end
    end
    slots.size.times { queries << raw.size.to_u64 }

    remapped = CrystalClick::CompressedMarkWriter.plan_literal_positions(
      raw.size.to_i64,
      queries,
      frame_bytes: 4096,
    )
    new_data = CrystalClick::CompressedMarkWriter.encode_all(raw, frame_bytes: 4096)

    record_width = slots.size * 16 + 8
    record_count = physical.granule_count + 1
    new_marks = Bytes.new(record_width * record_count, 0_u8)
    mapping_index = 0
    record_count.times do |mark_index|
      slots.size.times do |slot_index|
        compressed_offset, decompressed_offset = remapped[mapping_index]
        write_u64_le(new_marks, mark_width_offset(mark_index, record_width, slot_index), compressed_offset)
        write_u64_le(new_marks, mark_width_offset(mark_index, record_width, slot_index) + 8, decompressed_offset)
        mapping_index += 1
      end
      row_count = mark_index == physical.granule_count ? 0_u64 : physical.mark_row_counts[mark_index]
      write_u64_le(new_marks, mark_index * record_width + slots.size * 16, row_count)
    end
    raise "MRK3 position mapping was not fully consumed" unless mapping_index == remapped.size

    File.write(File.join(part_path, "data.bin"), new_data)
    File.write(File.join(part_path, "data.mrk3"), new_marks)
    CompactPhysicalContextW259Fixture.refresh_checksums(part_path)
    nil
  end

  private def mark_width_offset(mark_index : Int, record_width : Int, slot_index : Int) : Int
    mark_index * record_width + slot_index * 16
  end

  private def write_u64_le(bytes : Bytes, offset : Int, value : UInt64) : Nil
    8.times do |index|
      bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
    end
  end
end
