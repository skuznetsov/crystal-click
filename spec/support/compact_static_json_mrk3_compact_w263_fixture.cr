require "json"
require "../../scripts/support/compact_json_w263_fixture"
require "./compact_static_json_mrk3_null_w263_fixture"

module CompactStaticJsonMrk3CompactW263Fixture
  extend self

  MANIFEST_FORMAT = "compact_json_mrk3_null_frame_witness_w263_native_manifest_v1"
  BASIC_TABLE     = CompactStaticJsonMrk3NullW263Fixture::BASIC_TABLE
  COMPACT_TABLE   = CompactStaticJsonMrk3NullW263Fixture::COMPACT_TABLE
  TABLES          = [BASIC_TABLE, COMPACT_TABLE]
  FRAME_ROWS      = [
    {id: 1_i64, label: "r1", maybe: "alpha"},
    {id: 2_i64, label: "r2", maybe: nil},
    {id: 3_i64, label: "r3", maybe: nil},
    {id: 4_i64, label: "r4", maybe: nil},
    {id: 5_i64, label: "r5", maybe: "beta"},
    {id: 6_i64, label: "r6", maybe: "gamma"},
  ]

  def evidence_root : String
    root = ENV["CRYSTAL_CLICK_W263_COMPACT_EVIDENCE_ROOT"]? ||
           raise "CRYSTAL_CLICK_W263_COMPACT_EVIDENCE_ROOT must name the checked frame-witness capture"
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
                       raise ArgumentError.new("unknown W263 Compact frame-witness part label: #{label}")
                     end

    root = File.realpath(root)
    manifest_path = File.join(root, "native_manifest.json")
    unless File.file?(manifest_path) && !File.symlink?(manifest_path) && File.realpath(manifest_path) == manifest_path
      raise "W263 Compact frame-witness manifest is absent, linked or noncanonical"
    end
    raise "W263 Compact frame-witness manifest exceeds its byte bound" if File.size(manifest_path) > 4 * 1024 * 1024

    manifest = JSON.parse(File.read(manifest_path))
    raise "unexpected W263 Compact frame-witness manifest format" unless manifest["format"].as_s == MANIFEST_FORMAT
    raise "W263 Compact frame-witness capture was not marked observed" unless manifest["status"].as_s == "stock_native_capture_observed"
    raise "W263 Compact frame-witness capture has the wrong row count" unless manifest["row_count"].as_i64 == 6
    unless manifest["mark_rows"].as_a.map(&.as_i64) == [2_i64, 2_i64, 2_i64]
      raise "W263 Compact frame-witness capture has the wrong mark grid"
    end

    runtime_pin = manifest["pins"]["runtime"]
    unless runtime_pin["expected_sha256"].as_s == CompactJsonW263Fixture::NATIVE_BINARY_SHA256 &&
           runtime_pin["observed_sha256_before"].as_s == CompactJsonW263Fixture::NATIVE_BINARY_SHA256 &&
           runtime_pin["observed_sha256_after"].as_s == CompactJsonW263Fixture::NATIVE_BINARY_SHA256 &&
           runtime_pin["version"].as_s == CompactJsonW263Fixture::NATIVE_VERSION &&
           runtime_pin["build"].as_s == CompactJsonW263Fixture::NATIVE_BUILD
      raise "W263 Compact frame-witness runtime pin differs"
    end
    invocation = manifest["native_invocation"]
    unless invocation["exit"].as_i64 == 0 && invocation["signal"].raw.nil? &&
           !invocation["timed_out"].as_bool && invocation["process_classification"].as_s == "success" &&
           invocation["stderr_bytes"].as_i64 == 0
      raise "W263 Compact frame-witness process did not finish successfully and quietly"
    end
    source_pin = manifest["pins"]["source"]
    unless source_pin["expected_revision"].as_s == CompactJsonW263Fixture::NATIVE_SOURCE_REVISION &&
           source_pin["observed_revision_before"].as_s == CompactJsonW263Fixture::NATIVE_SOURCE_REVISION &&
           source_pin["observed_revision_after"].as_s == CompactJsonW263Fixture::NATIVE_SOURCE_REVISION &&
           source_pin["tracked_worktree_clean_before"].as_bool && source_pin["tracked_worktree_clean_after"].as_bool
      raise "W263 Compact frame-witness source pin differs"
    end
    quiescence = manifest["part_quiescence"]
    unless quiescence["native_process_closed_before_inventory"].as_bool &&
           quiescence["post_close_inventory_equal"].as_bool
      raise "W263 Compact source part was not inventoried after writer close"
    end

    schema = manifest["schema"].as_a.map { |entry| entry.as_a.map(&.as_s) }
    expected_schema = TABLES.flat_map do |table|
      [[table, "pk", "UInt64"], [table, "root", CompactStaticJsonMrk3NullW263Fixture::JSON_DECLARATION]]
    end
    raise "W263 Compact frame-witness schema differs" unless schema == expected_schema

    expected_patterns = [
      [{type: "String", value: "alpha"}, {type: "None", value: nil}],
      [{type: "None", value: nil}, {type: "None", value: nil}],
      [{type: "String", value: "beta"}, {type: "String", value: "gamma"}],
    ]
    witness = manifest["frame_witness"]
    unless witness["version"].as_i64 == 1 && witness["option"].as_s == "--frame-witness"
      raise "W263 Compact frame-witness metadata version differs"
    end
    pattern_rows = witness["mark_patterns"].as_a
    raise "W263 Compact frame-witness pattern roster differs" unless pattern_rows.size == expected_patterns.size
    expected_patterns.each_with_index do |expected_mark, mark_index|
      observed_mark = pattern_rows[mark_index]
      raise "W263 Compact frame-witness mark index differs" unless observed_mark["mark"].as_i64 == mark_index
      observed_rows = observed_mark["rows"].as_a
      raise "W263 Compact frame-witness mark row count differs" unless observed_rows.size == expected_mark.size
      expected_mark.each_with_index do |expected, row_index|
        observed = observed_rows[row_index]
        unless observed["dynamic_type"].as_s == expected[:type]
          raise "W263 Compact frame-witness Dynamic type differs at mark #{mark_index} row #{row_index}"
        end
        if value = expected[:value]
          unless observed["value"].as_s == value
            raise "W263 Compact frame-witness value differs at mark #{mark_index} row #{row_index}"
          end
        elsif !observed["value"].raw.nil?
          raise "W263 Compact frame-witness NULL row acquired a value"
        end
      end
    end

    observed_rows = manifest["rows"].as_a
    raise "W263 Compact frame-witness native row roster differs" unless observed_rows.size == TABLES.size * FRAME_ROWS.size
    TABLES.each do |table|
      FRAME_ROWS.each do |expected|
        row = observed_rows.find do |candidate|
          candidate["table"].as_s == table && candidate["id"].as_i64 == expected[:id]
        end || raise "W263 Compact frame-witness row is missing for #{table} id=#{expected[:id]}"
        expected_type = expected[:maybe].nil? ? "None" : "String"
        unless row["label"].as_s == expected[:label] && row["maybe_type"].as_s == expected_type
          raise "W263 Compact frame-witness typed row differs for #{table} id=#{expected[:id]}"
        end
        if value = expected[:maybe]
          unless row["maybe_value"].as_s == value && row["maybe_json"].as_s == value &&
                 row["dynamic_paths"].as_a.map(&.as_s) == ["maybe"] && row["root_json"]["maybe"].as_s == value
            raise "W263 Compact frame-witness non-NULL Dynamic row differs for #{table} id=#{expected[:id]}"
          end
        else
          unless row["maybe_value"].raw.nil? && row["maybe_json"].raw.nil? && row["dynamic_paths"].as_a.empty? &&
                 !row["root_json"].as_h.has_key?("maybe")
            raise "W263 Compact frame-witness NULL row differs for #{table} id=#{expected[:id]}"
          end
        end
        unless row["shared_paths"].as_a.empty? && row["root_json"]["id"].as_i64 == expected[:id] &&
               row["root_json"]["label"].as_s == expected[:label]
          raise "W263 Compact frame-witness root JSON/shared paths differ for #{table} id=#{expected[:id]}"
        end
      end
    end

    part = manifest["parts"][label.to_s]
    raise "W263 Compact source table differs from its selected label" unless part["table"].as_s == expected_table
    raise "W263 Compact manifest path is missing" if part["path"].as_s.empty?
    part_path = File.realpath(part["path"].as_s)
    root_prefix = root.ends_with?(File::SEPARATOR) ? root : root + File::SEPARATOR
    raise "W263 Compact source part escapes the evidence root" unless part_path.starts_with?(root_prefix)
    unless part["rows"].as_i64 == 6 && part["marks"].as_i64 == 4
      raise "W263 Compact source part has the wrong rows or mark count"
    end
    raise "W263 Compact source part is not PlainMRK3" unless part["data_format"].as_s == "PlainMRK3"
    raise "W263 Compact source part is not Compact" unless part["part_type"].as_s == "Compact"
    raise "W263 Compact source part name differs from its path" unless part["part_name"].as_s == File.basename(part_path)
    raise "W263 Compact source Variant mode differs" unless part["dynamic_variant_mode"].as_s == label.to_s

    inventory = part["file_inventory"].as_a.map do |item|
      {item["path"].as_s, item["bytes"].as_i64, item["sha256"].as_s}
    end
    post_close_inventory = part["post_close_file_inventory"].as_a.map do |item|
      {item["path"].as_s, item["bytes"].as_i64, item["sha256"].as_s}
    end
    unless inventory == post_close_inventory
      raise "W263 Compact source part changed after the native writer closed"
    end
    CompactJsonW263Fixture.assert_native_inventory!(part_path, inventory)

    serialization = part["serialization"]
    unless serialization["version"].as_i64 == 1 &&
           serialization["propagate_types_serialization_versions_to_nested_types"].as_bool &&
           serialization["types_serialization_versions"]["string"].as_i64 == 0
      raise "W263 Compact source serialization profile differs"
    end
    unless manifest["checks"][label.to_s].as_a.map(&.as_s) == ["all_1_1_0\t1\t"]
      raise "W263 Compact native CHECK result differs"
    end

    {path: part_path, inventory: inventory, manifest: manifest, part: part}
  end

  def json_type : CrystalClick::BinaryDataType
    CompactStaticJsonMrk3NullW263Fixture.json_type
  end

  def raw_mark_evidence(part_path : String, mark_index : Int32)
    CompactStaticJsonMrk3NullW263Fixture.raw_mark_evidence(
      part_path,
      mark_index,
      expected_mark_count: 3,
    )
  end

  def body_capture_evidence(part_path : String, mark_index : Int32)
    CompactStaticJsonMrk3NullW263Fixture.body_capture_evidence(
      part_path,
      mark_index,
      expected_mark_count: 3,
    )
  end

  def copy_part(source_part : String) : Tuple(String, String)
    CompactStaticJsonMrk3NullW263Fixture.copy_part(source_part)
  end

  def mutate_tape_byte!(
    part_path : String,
    mark_index : Int32,
    tape_offset : Int32,
    expected : UInt8,
    replacement : UInt8,
  ) : NamedTuple(logical_start: Int64, tape_size: Int32)
    CompactStaticJsonMrk3NullW263Fixture.mutate_tape_byte!(
      part_path,
      mark_index,
      tape_offset,
      expected,
      replacement,
      expected_mark_count: 3,
    )
  end
end
