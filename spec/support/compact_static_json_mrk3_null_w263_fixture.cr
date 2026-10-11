require "json"
require "file_utils"
require "../../scripts/support/compact_json_w263_fixture"
require "../../scripts/support/compact_physical_context_w259_fixture"

module CompactStaticJsonMrk3NullW263Fixture
  extend self

  MANIFEST_FORMAT  = "compact_json_mrk3_null_w263_native_manifest_v1"
  BASIC_LABEL      = "obj_v1_dyn_v1_map_mrk3_s0_variant_basic"
  COMPACT_LABEL    = "obj_v1_dyn_v1_map_mrk3_s0_variant_compact"
  BASIC_TABLE      = "w263n_mrk3_basic"
  COMPACT_TABLE    = "w263n_mrk3_compact"
  JSON_DECLARATION = "JSON(max_dynamic_types=1, max_dynamic_paths=2, id UInt8, label String)"

  ROWS = [
    {table: BASIC_TABLE, id: 1_i64, label: "r1", maybe: "alpha"},
    {table: BASIC_TABLE, id: 2_i64, label: "r2", maybe: nil},
    {table: BASIC_TABLE, id: 3_i64, label: "r3", maybe: nil},
    {table: BASIC_TABLE, id: 4_i64, label: "r4", maybe: nil},
    {table: COMPACT_TABLE, id: 1_i64, label: "r1", maybe: "alpha"},
    {table: COMPACT_TABLE, id: 2_i64, label: "r2", maybe: nil},
    {table: COMPACT_TABLE, id: 3_i64, label: "r3", maybe: nil},
    {table: COMPACT_TABLE, id: 4_i64, label: "r4", maybe: nil},
  ]

  def evidence_root : String
    root = ENV["CRYSTAL_CLICK_W263_NULL_EVIDENCE_ROOT"]? ||
           raise "CRYSTAL_CLICK_W263_NULL_EVIDENCE_ROOT must name the checked null capture"
    File.realpath(root)
  end

  def source_part(
    label : Symbol = :basic,
    root : String = evidence_root,
  ) : NamedTuple(path: String, inventory: Array(Tuple(String, Int64, String)), manifest: JSON::Any, part: JSON::Any)
    expected_table = case label
                     when :basic   then BASIC_TABLE
                     when :compact then COMPACT_TABLE
                     else
                       raise ArgumentError.new("unknown W263 null part label: #{label}")
                     end

    root = File.realpath(root)
    manifest_path = File.join(root, "native_manifest.json")
    unless File.file?(manifest_path) && !File.symlink?(manifest_path) && File.realpath(manifest_path) == manifest_path
      raise "W263 null native manifest is absent, linked or noncanonical"
    end
    raise "W263 null native manifest exceeds its byte bound" if File.size(manifest_path) > 4 * 1024 * 1024

    manifest = JSON.parse(File.read(manifest_path))
    raise "unexpected W263 null native manifest format" unless manifest["format"].as_s == MANIFEST_FORMAT
    raise "W263 null stock capture was not marked observed" unless manifest["status"].as_s == "stock_native_capture_observed"
    raise "W263 null native capture has the wrong row count" unless manifest["row_count"].as_i64 == 4
    unless manifest["mark_rows"].as_a.map(&.as_i64) == [2_i64, 2_i64]
      raise "W263 null native capture has the wrong mark grid"
    end
    runtime_pin = manifest["pins"]["runtime"]
    unless runtime_pin["expected_sha256"].as_s == CompactJsonW263Fixture::NATIVE_BINARY_SHA256 &&
           runtime_pin["observed_sha256_before"].as_s == CompactJsonW263Fixture::NATIVE_BINARY_SHA256 &&
           runtime_pin["observed_sha256_after"].as_s == CompactJsonW263Fixture::NATIVE_BINARY_SHA256 &&
           runtime_pin["version"].as_s == CompactJsonW263Fixture::NATIVE_VERSION &&
           runtime_pin["build"].as_s == CompactJsonW263Fixture::NATIVE_BUILD
      raise "W263 null native runtime pin differs"
    end
    invocation = manifest["native_invocation"]
    unless invocation["exit"].as_i64 == 0 && invocation["signal"].raw.nil? &&
           !invocation["timed_out"].as_bool && invocation["process_classification"].as_s == "success" &&
           invocation["stderr_bytes"].as_i64 == 0
      raise "W263 null native process did not finish successfully and quietly"
    end
    source_pin = manifest["pins"]["source"]
    unless source_pin["expected_revision"].as_s == CompactJsonW263Fixture::NATIVE_SOURCE_REVISION &&
           source_pin["observed_revision_before"].as_s == CompactJsonW263Fixture::NATIVE_SOURCE_REVISION &&
           source_pin["observed_revision_after"].as_s == CompactJsonW263Fixture::NATIVE_SOURCE_REVISION &&
           source_pin["tracked_worktree_clean_before"].as_bool && source_pin["tracked_worktree_clean_after"].as_bool
      raise "W263 null native source pin differs"
    end
    quiescence = manifest["part_quiescence"]
    unless quiescence["native_process_closed_before_inventory"].as_bool &&
           quiescence["post_close_inventory_equal"].as_bool
      raise "W263 null source part was not inventoried after writer close"
    end

    schema = manifest["schema"].as_a.map { |entry| entry.as_a.map(&.as_s) }
    expected_schema = [BASIC_TABLE, COMPACT_TABLE].flat_map do |table|
      [[table, "pk", "UInt64"], [table, "root", JSON_DECLARATION]]
    end
    raise "W263 null native schema differs" unless schema == expected_schema

    observed_rows = manifest["rows"].as_a
    raise "W263 null native row roster is not two copies of the four literals" unless observed_rows.size == ROWS.size
    ROWS.each do |expected|
      row = observed_rows.find do |candidate|
        candidate["table"].as_s == expected[:table] && candidate["id"].as_i64 == expected[:id]
      end || raise "W263 null native row is missing for #{expected[:table]} id=#{expected[:id]}"
      maybe_type = expected[:maybe].nil? ? "None" : "String"
      unless row["label"].as_s == expected[:label] && row["maybe_type"].as_s == maybe_type
        raise "W263 null native typed row differs for #{expected[:table]} id=#{expected[:id]}"
      end
      if value = expected[:maybe]
        unless row["maybe_value"].as_s == value && row["dynamic_paths"].as_a.map(&.as_s) == ["maybe"] &&
               row["root_json"]["maybe"].as_s == value
          raise "W263 null native non-NULL Dynamic path differs"
        end
      else
        unless row["maybe_value"].raw.nil? && row["dynamic_paths"].as_a.empty? && !row["root_json"].as_h.has_key?("maybe")
          raise "W263 null native NULL row did not omit its inferred path"
        end
      end
      unless row["shared_paths"].as_a.empty? && row["root_json"]["id"].as_i64 == expected[:id] &&
             row["root_json"]["label"].as_s == expected[:label]
        raise "W263 null native root JSON or shared-path observation differs"
      end
    end

    part = manifest["parts"][label.to_s]
    raise "W263 null source table differs from its selected label" unless part["table"].as_s == expected_table
    raise "W263 null manifest path is missing" if part["path"].as_s.empty?
    part_path = File.realpath(part["path"].as_s)
    root_prefix = root.ends_with?(File::SEPARATOR) ? root : root + File::SEPARATOR
    raise "W263 null source part escapes the evidence root" unless part_path.starts_with?(root_prefix)
    unless part["rows"].as_i64 == 4 && part["marks"].as_i64 == 3
      raise "W263 null source part has the wrong rows or mark count"
    end
    raise "W263 null source part is not PlainMRK3" unless part["data_format"].as_s == "PlainMRK3"
    raise "W263 null source part is not Compact" unless part["part_type"].as_s == "Compact"
    raise "W263 null source part name differs from its path" unless part["part_name"].as_s == File.basename(part_path)
    expected_mode = label == :basic ? "basic" : "compact"
    raise "W263 null source Variant mode differs" unless part["dynamic_variant_mode"].as_s == expected_mode

    inventory = part["file_inventory"].as_a.map do |item|
      {item["path"].as_s, item["bytes"].as_i64, item["sha256"].as_s}
    end
    post_close_inventory = part["post_close_file_inventory"].as_a.map do |item|
      {item["path"].as_s, item["bytes"].as_i64, item["sha256"].as_s}
    end
    unless inventory == post_close_inventory
      raise "W263 null source part changed after the native writer closed"
    end
    CompactJsonW263Fixture.assert_native_inventory!(part_path, inventory)

    serialization = part["serialization"]
    unless serialization["version"].as_i64 == 1 &&
           serialization["propagate_types_serialization_versions_to_nested_types"].as_bool &&
           serialization["types_serialization_versions"]["string"].as_i64 == 0
      raise "W263 null source serialization profile differs"
    end

    checks = manifest["checks"][label.to_s].as_a.map(&.as_s)
    unless checks == ["all_1_1_0\t1\t"]
      raise "W263 null native CHECK result differs"
    end

    {path: part_path, inventory: inventory, manifest: manifest, part: part}
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 2,
      max_dynamic_types: 1,
      typed_paths: {
        "id"    => CrystalClick::BinaryDataType.primitive("UInt8"),
        "label" => CrystalClick::BinaryDataType.primitive("String"),
      } of String => CrystalClick::BinaryDataType,
    )
  end

  # Captures only the authenticated mark and its complete Object/Dynamic
  # prefix. It deliberately does not invoke the body/MAP tape walker, so the
  # returned bytes can independently pin raw NULL tags and prefix offsets.
  def raw_mark_evidence(
    part_path : String,
    mark_index : Int32,
    expected_mark_count : Int32 = 2,
  ) : NamedTuple(
    raw: Bytes,
    logical_start: Int64,
    prefix_end: Int32,
    remaining: Int32,
    callbacks: Array(Tuple(String, Bytes)),
    dynamic_paths: Array(String),
    string_indexes: Array(Int32),
    discriminator_headers: Array(Tuple(String, Bytes)),
    object_statistics_offset: Int32,
    dynamic_statistics_offsets: Hash(String, Int32),
  )
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    expected_mark_rows = expected_two_row_mark_grid(expected_mark_count)
    unless physical.mode.mrk3? && physical.mark_row_counts == expected_mark_rows
      raise "W263 null source part is not the expected #{expected_mark_count}-mark MRK3 grid"
    end
    granule = physical.read_window("root", mark_index, 1).granules.first? ||
              raise CrystalClick::CorruptPartError.new("W263 null root mark is missing")
    shard = granule.shards.first? ||
            raise CrystalClick::CorruptPartError.new("W263 null root shard is missing")

    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
    framer = CrystalClick::CompactJsonObjectSiteFramer.new(physical.mode, granule.shards, budget)
    dynamic_statistics_offsets = Hash(String, Int32).new
    statistics_offset_observer = ->(name : String, offset : Int32) do
      dynamic_statistics_offsets[name] = offset
      nil
    end
    nested = CrystalClick::ObjectSharedNestedSerializationContext.for_read(
      0_u64,
      CrystalClick::BinaryBulkProfile.single_stream,
    )
    prefix = CrystalClick::ObjectDocumentCallbackPrefixReader.read_static_json_prefix(
      framer,
      json_type,
      1_i32,
      "root",
      "root",
      0_u64,
      nested,
      budget,
      true,
      statistics_offset_observer,
    )

    callbacks = Array(Tuple(String, Bytes)).new(prefix.prefix_callback_count)
    prefix.prefix_callback_count.times do |index|
      callbacks << prefix.prefix_callback_at(index, budget)
    end

    object = prefix.structures.object
    dynamic_paths = Array(String).new(object.dynamic_path_count)
    string_indexes = [] of Int32
    object.dynamic_path_count.times do |index|
      path = object.dynamic_path_at(index)
      dynamic_paths << path
      sites = prefix.root_dynamic_sites_for(path, budget)
      sites.each_value do |structure|
        string_indexes << structure.canonical_index_for(CrystalClick::BinaryDataType.primitive("String"))
      end
    end
    headers = callbacks.select do |name, bytes|
      name.ends_with?(".variant_discr_prefix") && bytes.size == 8
    end
    {
      raw:                        shard.bytes,
      logical_start:              shard.logical_start,
      prefix_end:                 framer.position,
      remaining:                  framer.remaining,
      callbacks:                  callbacks,
      dynamic_paths:              dynamic_paths,
      string_indexes:             string_indexes,
      discriminator_headers:      headers,
      object_statistics_offset:   prefix.object_structure_statistics_offset,
      dynamic_statistics_offsets: dynamic_statistics_offsets,
    }
  end

  # Walks one actual native MAP mark through the production grammar-only body
  # framer and reports only the body phase's logical budget delta and callback
  # byte extents. This lets a narrow all-NULL assertion distinguish charging
  # the two row tags from inventing Dynamic-arm occurrences for NULL rows.
  def body_capture_evidence(
    part_path : String,
    mark_index : Int32,
    expected_mark_count : Int32 = 2,
  ) : NamedTuple(
    body_nodes: Int64,
    body_elements: Int64,
    body_wire_bytes: Int64,
    bindings: Array(CrystalClick::ObjectDocumentInlineCallbackOrder::BodyLaneBinding),
    callbacks: Array(Tuple(String, String, Int32)),
  )
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    expected_mark_rows = expected_two_row_mark_grid(expected_mark_count)
    unless physical.mode.mrk3? && physical.mark_row_counts == expected_mark_rows
      raise "W263 null body source is not the expected #{expected_mark_count}-mark MRK3 grid"
    end
    granule = physical.read_window("root", mark_index, 1).granules.first? ||
              raise CrystalClick::CorruptPartError.new("W263 null body mark is missing")

    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    profile = CrystalClick::BinaryBulkProfile.single_stream
    framer = CrystalClick::CompactJsonObjectSiteFramer.new(physical.mode, granule.shards, budget)
    nested = CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile)
    prefix = CrystalClick::ObjectDocumentCallbackPrefixReader.read_static_json_prefix(
      framer,
      json_type,
      1_i32,
      "root",
      "root",
      0_u64,
      nested,
      budget,
      true,
    )
    physical_plan = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
      "root",
      prefix.plan,
      profile,
      CrystalClick::BinaryBulkProfile.single_stream,
      limits,
      prefix.array_level,
      typed_descriptor_root_depth: prefix.typed_descriptor_root_depth,
      inferred_actual_root_depth: prefix.inferred_actual_root_depth,
      root_dynamic_json_budget: budget,
    )
    prefix.bind_physical_plan!(physical_plan)
    schedule = CrystalClick::CompactJsonObjectRoleSchedule.build(prefix, physical_plan, profile, budget)
    prefix.start_body_capture!

    before_nodes = budget.node_count
    before_elements = budget.element_count
    before_wire = budget.wire_byte_count
    CrystalClick::CompactJsonObjectMapTapeFramer.capture_body!(
      prefix,
      physical_plan,
      schedule,
      framer,
      granule.row_count,
      profile,
      limits,
      budget,
    )
    prefix.finish_body_capture!(schedule.body_pairs.size)
    framer.validate_expected_events!(schedule.event_names)
    framer.finish!

    callbacks = Array(Tuple(String, String, Int32)).new(prefix.body_callback_slice_count)
    prefix.body_callback_slice_count.times do |index|
      slice = prefix.body_callback_slice_at(index)
      callbacks << {slice.canonical_name, slice.callback_name, slice.bytes.size}
    end
    {
      body_nodes:      budget.node_count - before_nodes,
      body_elements:   budget.element_count - before_elements,
      body_wire_bytes: budget.wire_byte_count - before_wire,
      bindings:        schedule.body_bindings,
      callbacks:       callbacks,
    }
  end

  # Mutates one byte in the authenticated whole-data domain, then recompresses
  # the complete tape and rewrites every mrk3 position pair. The reopened
  # physical context must read the same mark interval and observe the byte
  # before the caller asks the JSON reader to classify the semantic fault.
  def mutate_tape_byte!(
    part_path : String,
    mark_index : Int32,
    tape_offset : Int32,
    expected : UInt8,
    replacement : UInt8,
    expected_mark_count : Int32 = 2,
  ) : NamedTuple(logical_start: Int64, tape_size: Int32)
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    expected_mark_rows = expected_two_row_mark_grid(expected_mark_count)
    unless physical.mode.mrk3? && physical.mark_row_counts == expected_mark_rows
      raise "W263 null mutation source is not the expected #{expected_mark_count}-mark MRK3 grid"
    end
    granule = physical.read_window("root", mark_index, 1).granules.first? ||
              raise CrystalClick::CorruptPartError.new("W263 null mutation mark is missing")
    shard = granule.shards.first? || raise CrystalClick::CorruptPartError.new("W263 null mutation shard is missing")
    unless tape_offset >= 0 && tape_offset < shard.bytes.size && shard.byte_at(tape_offset) == expected
      raise "W263 null mutation byte did not match its authenticated raw mark"
    end

    compressed_data = File.read(File.join(part_path, "data.bin")).to_slice
    raw = CrystalClick::CompressedBlock.decode_all(compressed_data)
    logical_start = shard.logical_start
    unless raw[logical_start.to_i, shard.bytes.size] == shard.bytes
      raise "W263 null mutation raw bytes differ from their physical shard"
    end
    absolute_offset = logical_start.to_i + tape_offset
    raw[absolute_offset] = replacement
    reframe_mrk3_tape!(part_path, physical, raw)

    reopened = CrystalClick::CompactPartPhysicalContext.open(part_path)
    unless reopened.mode.mrk3? && reopened.mark_row_counts == expected_mark_rows
      raise "reframed W263 null mutation changed its physical mode or mark grid"
    end
    observed = reopened.read_window("root", mark_index, 1).granules.first?.try(&.shards.first?) ||
               raise CrystalClick::CorruptPartError.new("reframed W263 null mutation shard is missing")
    unless observed.logical_start == logical_start && observed.bytes.size == shard.bytes.size &&
           observed.byte_at(tape_offset) == replacement
      raise "reframed W263 null mutation did not survive the authenticated physical read"
    end
    {logical_start: logical_start, tape_size: shard.bytes.size}
  end

  def copy_part(source_part : String) : Tuple(String, String)
    parent = File.tempname("crystal-click-w263-null-adversary-")
    Dir.mkdir(parent, 0o700)
    copied_part = File.join(parent, File.basename(source_part))
    FileUtils.cp_r(source_part, copied_part)
    {parent, copied_part}
  end

  def render_raw_mark_evidence(
    part_path : String,
    mark_index : Int32,
    expected_mark_count : Int32 = 2,
  ) : String
    evidence = raw_mark_evidence(part_path, mark_index, expected_mark_count)
    String.build do |io|
      io << "mark=" << mark_index << " logical_start=" << evidence[:logical_start]
      io << " tape_size=" << evidence[:raw].size << " prefix_end=" << evidence[:prefix_end]
      io << " remaining=" << evidence[:remaining] << " raw_hex=" << evidence[:raw].hexstring
      io << "\ndynamic_paths=" << evidence[:dynamic_paths].inspect
      io << "\nstring_indexes=" << evidence[:string_indexes].inspect
      io << "\nobject_statistics_offset=" << evidence[:object_statistics_offset]
      io << "\ndynamic_statistics_offsets=" << evidence[:dynamic_statistics_offsets].inspect
      io << "\ncallbacks="
      evidence[:callbacks].each do |name, bytes|
        io << "\n  " << name << "=" << bytes.hexstring
      end
    end
  end

  private def reframe_mrk3_tape!(
    part_path : String,
    physical : CrystalClick::CompactPartPhysicalContext,
    raw : Bytes,
  ) : Nil
    slots = physical.physical_roster
    raise "W263 null native root fixture has no physical slots" if slots.empty?
    slot_positions = slots.map do |slot|
      window = physical.read_window(slot.column_name, 0, physical.granule_count)
      unless window.granules.size == physical.granule_count
        raise "W263 null source column has an incomplete mark window"
      end
      window.granules.map do |granule|
        shard = granule.shards.first? || raise CrystalClick::CorruptPartError.new("W263 null slot has no whole-column shard")
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
        offset = mark_index * record_width + slot_index * 16
        write_u64_le(new_marks, offset, compressed_offset)
        write_u64_le(new_marks, offset + 8, decompressed_offset)
        mapping_index += 1
      end
      row_count = mark_index == physical.granule_count ? 0_u64 : physical.mark_row_counts[mark_index]
      write_u64_le(new_marks, mark_index * record_width + slots.size * 16, row_count)
    end
    raise "W263 null MRK3 position mapping was not fully consumed" unless mapping_index == remapped.size

    File.write(File.join(part_path, "data.bin"), new_data)
    File.write(File.join(part_path, "data.mrk3"), new_marks)
    CompactPhysicalContextW259Fixture.refresh_checksums(part_path)
    nil
  end

  private def write_u64_le(bytes : Bytes, offset : Int, value : UInt64) : Nil
    8.times do |index|
      bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
    end
  end

  private def expected_two_row_mark_grid(expected_mark_count : Int32) : Array(UInt64)
    raise ArgumentError.new("W263 two-row mark count must be positive") unless expected_mark_count > 0
    Array(UInt64).new(expected_mark_count, 2_u64)
  end
end
