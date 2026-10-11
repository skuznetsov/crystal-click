require "../spec_helper"
require "json"
require "../../scripts/support/compact_json_w263_fixture"
require "../../scripts/support/compact_physical_context_w259_fixture"

module CompactStaticJsonW263AdversaryFixture
  extend self

  def evidence_root : String
    root = ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]? ||
           raise "CRYSTAL_CLICK_W263_EVIDENCE_ROOT must name the independently checked W263 capture"
    File.realpath(root)
  end

  def source_part(
    root : String,
    label : String,
  ) : NamedTuple(path: String, inventory: Array(Tuple(String, Int64, String)))
    summary_path = File.join(root, "summary.json")
    raise "W263 capture summary is missing" unless File.file?(summary_path)

    summary = JSON.parse(File.read(summary_path))
    raise "unexpected W263 capture format" unless summary["format"].as_s == "compact_json_w263_probe_summary_v1"
    raise "W263 adversary requires the expected native refusal baseline" unless summary["status"].as_s == "expected_json_unsupported"
    raise "W263 native capture did not complete successfully" unless summary["native_invocation"]["exit"].as_i == 0
    raise "W263 native capture did not classify as success" unless summary["native_invocation"]["process_classification"].as_s == "success"
    raise "W263 native runtime pin differs" unless summary["clickhouse"]["sha256"].as_s == CompactJsonW263Fixture::NATIVE_BINARY_SHA256
    raise "W263 capture does not contain the complete native matrix" unless summary["cells"].as_a.size == 48
    raise "W263 capture is missing the selected native label" unless summary["cells"].as_a.any? { |cell| cell.as_s == label }

    record = summary["parts"][label]
    raise "selected W263 part is not Compact" unless record["part_type"].as_s == "Compact"
    raise "selected W263 part is not the eight-row fixture" unless record["rows"].as_s == "8"
    raise "selected W263 part is not mrk4" unless record["mark_extension"].as_s == ".mrk4"
    raise "selected W263 part name differs from the capture summary" unless record["part_name"].as_s == File.basename(record["path"].as_s)

    part_path = File.realpath(record["path"].as_s)
    root_prefix = root.ends_with?(File::SEPARATOR) ? root : root + File::SEPARATOR
    raise "W263 part path escapes the explicitly supplied evidence root" unless part_path.starts_with?(root_prefix)
    %w[columns.txt columns_substreams.txt count.txt checksums.txt data.bin data.mrk4].each do |name|
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
    manifest_entry = manifest["parts"].as_a.find { |item| item["label"].as_s == label } ||
                     raise "W263 native manifest lacks the selected adversary cell"
    raise "W263 summary/native manifest path differs" unless manifest_entry["path"].as_s == record["path"].as_s

    inventory = manifest_entry["file_inventory"].as_a.map do |item|
      {item["path"].as_s, item["bytes"].as_i64, item["sha256"].as_s}
    end
    CompactJsonW263Fixture.assert_native_inventory!(part_path, inventory)
    {path: part_path, inventory: inventory}
  end

  def copy_part(source_part : String) : Tuple(String, String)
    parent = File.tempname("crystal-click-w263-static-adversary-")
    Dir.mkdir(parent, 0o700)
    copied_part = File.join(parent, File.basename(source_part))
    FileUtils.cp_r(source_part, copied_part)
    {parent, copied_part}
  end

  def overlap?(frame : CrystalClick::CompressedFrameDescriptor, span : Tuple(Int64, Int64)) : Bool
    frame.logical_start < span[1] && span[0] < frame.logical_end
  end

  def selected_later_frame(part_path : String) : Int32
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    physical.granule_count.should eq(4)
    physical.mark_row_counts.should eq(CompactJsonW263Fixture::MARK_ROWS)

    marks = physical.read_window("root", 0, physical.granule_count).granules
    marks.size.should eq(physical.granule_count)
    first_spans = [] of Tuple(Int64, Int64)
    marks.first.shards.each do |shard|
      first_spans << {shard.logical_start, shard.logical_end}
    end
    later_spans = [] of Tuple(Int64, Int64)
    marks.each_with_index do |mark, mark_index|
      next if mark_index == 0
      mark.shards.each do |shard|
        later_spans << {shard.logical_start, shard.logical_end}
      end
    end

    data_text = File.read(File.join(part_path, "data.bin"))
    data = data_text.to_slice
    frame_index = CrystalClick::CompressedFrameIndex.new(
      data,
      CrystalClick::CompressedStreamLimits.new,
      CrystalClick::CompressedStreamBudget.read_default,
    )
    candidates = [] of Int32
    frame_index.frames.each_with_index do |frame, index|
      next if index == 0
      next unless later_spans.any? { |span| overlap?(frame, span) }
      next if first_spans.any? { |span| overlap?(frame, span) }
      candidates << index.to_i32
    end
    candidates.last? || raise("W263 mrk4 capture has no frame confined to a later root callback interval")
  end

  def swap_root_callbacks(part_path : String) : Nil
    metadata_path = File.join(part_path, "columns_substreams.txt")
    lines = File.read(metadata_path).split("\n")
    structure_index = lines.index("\troot.object_structure") || raise "root.object_structure callback is missing"
    id_index = lines.index("\troot.id") || raise "root.id callback is missing"
    structure_index.should_not eq(id_index)
    structure_line = lines[structure_index]
    lines[structure_index] = lines[id_index]
    lines[id_index] = structure_line
    # split retains the final empty field. Joining already preserves the
    # original terminator; appending another newline would corrupt otherwise
    # valid metadata and mask the intended callback-order discriminator.
    File.write(metadata_path, lines.join("\n"))
    CompactPhysicalContextW259Fixture.refresh_checksums(part_path)
  end
end
