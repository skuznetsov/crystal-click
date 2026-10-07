require "../src/crystal_click"
require "json"

module CheckDynamicJSONMetadataW206
  extend self

  CASE_ID          = "direct_dynamic_json"
  COLUMN           = "d"
  JSON_TYPE        = "JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)"
  DYNAMIC_TYPE     = "Dynamic(max_types=1)"
  STRUCTURE_STREAM = "d.dynamic_structure"
  FORMAT_INPUT     = "dynamic_json_metadata_w206_input_v1"
  FORMAT_OUTPUT    = "dynamic_json_metadata_w206_helper_v1"
  # Independent stock V3 witness: UInt64LE(4), one JSON actual descriptor,
  # then JSON=8 / SharedVariant=0 statistics. This is not codec-generated.
  EXPECTED_METADATA_BYTES = Bytes[
    0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x01_u8,
    0x30_u8, 0x00_u8, 0x01_u8, 0x01_u8, 0x01_u8, 0x01_u8, 0x74_u8, 0x01_u8, 0x00_u8, 0x00_u8,
    0x01_u8, 0x08_u8, 0x00_u8, 0x00_u8,
  ]
  EXPECTED_STATISTICS_OFFSET = 19_i64
  EXPECTED_LOGICAL_SIZE      = 23_i64
  ROW_COUNT                  =  8_u64
  MARK_ROWS                  = [2_u64, 2_u64, 2_u64, 2_u64]

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W206 metadata helper: #{message}") unless condition
  end

  private def expected_json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      1,
      1,
      {"t" => CrystalClick::BinaryDataType.primitive("UInt8")} of String => CrystalClick::BinaryDataType,
    )
  end

  private def process(input : JSON::Any, capture_root : String) : JSON::Any
    require!(input.as_h.keys.sort == ["capture_root", "case_id", "format", "source_part"], "input fields differ")
    require!(input["case_id"].as_s == CASE_ID, "case identity differs")
    require!(input["format"].as_s == FORMAT_INPUT, "input format differs")
    require!(input["capture_root"].as_s == capture_root, "capture root differs")

    source_part = File.expand_path(input["source_part"].as_s)
    require!(source_part.starts_with?(capture_root + File::SEPARATOR), "stock part escaped its authenticated capture root")
    require!(Dir.exists?(source_part) && !File.symlink?(source_part) && File.realpath(source_part) == source_part,
      "stock part is absent or noncanonical")

    metadata = CrystalClick::ObjectColumnPartMetadata.open(source_part, COLUMN)
    require!(metadata.source_declaration == DYNAMIC_TYPE, "stock declaration differs from the direct Dynamic literal")
    require!(metadata.row_count == ROW_COUNT, "stock part row count differs")
    selected_streams = metadata.selected_stream_names.sort!
    require!(selected_streams.includes?(STRUCTURE_STREAM), "stock part omits the literal Dynamic structure stream")

    limits = CrystalClick::CompressedStreamLimits.new
    transport_budget = CrystalClick::CompressedStreamBudget.new(limits)
    source = CrystalClick::PartStreamSource.new(source_part)
    stream_stem = CrystalClick::StreamName.hash(STRUCTURE_STREAM)
    data_name = "#{stream_stem}.bin"
    marks_name = "#{stream_stem}.mrk2"
    grid = source.inspect_grid(data_name, marks_name, nil, transport_budget)
    require!(grid.mark_count == MARK_ROWS.size, "Dynamic structure mark count differs")
    require!(grid.rows_per_mark == MARK_ROWS, "Dynamic structure mark rows differ from the 8-row P grid")

    bytes = source.read_all(data_name, transport_budget)
    require!(bytes == EXPECTED_METADATA_BYTES, "stock Dynamic metadata bytes differ from the independent 23-byte V3 literal")
    structure = CrystalClick::DynamicStructureCodec.decode(bytes)
    expected = expected_json_type
    require!(structure.type_count == 1 && structure.type_at(0) == expected,
      "ordinary actual descriptor differs in tag, caps, typed-path roster, or type")
    expected_canonical = [JSON_TYPE, CrystalClick::DynamicStructure::SHARED_VARIANT_NAME]
    require!(structure.canonical_variant_names == expected_canonical, "canonical arm roster/order differs")
    require!(structure.canonical_index_for(expected) == 0, "JSON canonical arm index differs")
    require!(structure.shared_index == 1, "SharedVariant canonical index differs")

    statistics = structure.statistics || raise CrystalClick::CorruptPartError.new("W206 metadata helper: statistics are absent")
    require!(statistics.counts == [8_u64, 0_u64], "part statistics differ from JSON=8, SharedVariant=0")
    require!(statistics.shared_count == 0, "unexpected shared-type statistics were persisted")

    prefix = CrystalClick::DynamicStructureCodec.encode_prefix_without_statistics(structure)
    require!(prefix.size.to_i64 == EXPECTED_STATISTICS_OFFSET, "independent Dynamic statistics byte offset differs")
    require!(grid.prefix_size == prefix.size, "mark prefix does not end at the statistics suffix")
    require!(grid.logical_size == EXPECTED_LOGICAL_SIZE, "independent Dynamic metadata logical size differs")
    require!(grid.logical_size == bytes.size.to_i64, "marked structure logical EOF differs from the decoded stream")
    grid.mark_count.times do |mark|
      require!(grid.position_at(mark) == prefix.size.to_i64, "a real mark does not point at the statistics suffix")
    end
    require!(grid.position_at(grid.mark_count) == bytes.size.to_i64, "terminal mark does not point at structure EOF")

    reencoded = CrystalClick::DynamicStructureCodec.encode(structure)
    require!(reencoded == bytes, "full Dynamic metadata did not re-encode byte-for-byte")

    JSON::Any.new({
      "format"                  => JSON::Any.new(FORMAT_OUTPUT),
      "case_id"                 => JSON::Any.new(CASE_ID),
      "schema_declaration"      => JSON::Any.new(metadata.source_declaration),
      "row_count"               => JSON::Any.new(metadata.row_count.to_i64),
      "selected_stream_names"   => JSON::Any.new(selected_streams.map { |name| JSON::Any.new(name) }),
      "structure_stream_name"   => JSON::Any.new(STRUCTURE_STREAM),
      "mark_row_counts"         => JSON::Any.new(grid.rows_per_mark.map { |count| JSON::Any.new(count.to_i64) }),
      "actual_types"            => JSON::Any.new(structure.types.map { |type| JSON::Any.new(type.name) }),
      "canonical_variant_names" => JSON::Any.new(structure.canonical_variant_names.map { |name| JSON::Any.new(name) }),
      "canonical_indices"       => JSON::Any.new([
        JSON::Any.new(structure.canonical_index_for(expected).to_i64),
        JSON::Any.new(structure.shared_index.to_i64),
      ]),
      "statistics_counts"       => JSON::Any.new(statistics.counts.map { |count| JSON::Any.new(count.to_i64) }),
      "shared_statistics_count" => JSON::Any.new(statistics.shared_count.to_i64),
      "logical_size"            => JSON::Any.new(grid.logical_size),
      "statistics_offset"       => JSON::Any.new(grid.prefix_size.to_i64),
      "metadata_bytes_hex"      => JSON::Any.new(bytes.hexstring.downcase),
      "byte_exact_reencode"     => JSON::Any.new(true),
    } of String => JSON::Any)
  end

  private def run(args : Array(String)) : Nil
    raise ArgumentError.new("usage: check_dynamic_json_metadata_w206.cr INPUT.json OUTPUT_ROOT") unless args.size == 2
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    unless Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root
      raise ArgumentError.new("W206 output root must be canonical and non-symlinked")
    end
    unless File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR)
      raise ArgumentError.new("W206 helper input must be a plain file below output root")
    end

    capture_root = File.realpath(File.join(output_root, "..", "stores", "native"))
    input = JSON.parse(File.read(input_path))
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root), "capture root is not a plain directory")
    puts process(input, capture_root).to_json
  rescue ex : Exception
    STDERR.puts "W206 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckDynamicJSONMetadataW206.main(ARGV)
