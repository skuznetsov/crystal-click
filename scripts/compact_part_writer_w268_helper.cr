require "../src/crystal_click"
require "file_utils"
require "json"

module CompactPartWriterW268Helper
  extend self

  FORMAT          = "compact_part_writer_w268_helper_v1"
  ROW_COUNT       = 12_u64
  ROWS_PER_MARK   =  2_u64
  MARK_COUNT      =      6
  MAX_RAW_BYTES   = 64_i64 * 1024 * 1024
  MAX_FILE_BYTES  = MAX_RAW_BYTES + 1024_i64 * 1024
  MAX_FRAME_COUNT = 100_000
  KEY_NAME        = "pk"
  ROOT_NAME       = "root"
  CONTEXT_NAME    = "ctx"
  ROOT_TYPE       = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  CONTEXT_TYPE    = CrystalClick::BinaryDataType.tuple(
    [
      CrystalClick::BinaryDataType.primitive("String"),
      CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.dynamic(max_types: 1)),
    ],
    ["label", "items"],
  )
  WINDOWS = {
    "full"   => {0, 6},
    "middle" => {2, 2},
    "last"   => {5, 1},
    "empty"  => {6, 0},
  }
  EXPECTED_ROSTER = [
    {"pk", "pk"},
    {"root", "root.dynamic_structure"},
    {"root", "root.variant_discr_prefix"},
    {"root", "root.variant_discr"},
    {"root", "root.SharedVariant"},
    {"root", "root.UInt8"},
    {"ctx", "ctx%2Eitems.dynamic_structure"},
    {"ctx", "ctx%2Eitems.variant_discr_prefix"},
    {"ctx", "ctx%2Elabel"},
    {"ctx", "ctx%2Eitems.size0"},
    {"ctx", "ctx%2Eitems.variant_discr"},
    {"ctx", "ctx%2Eitems.SharedVariant"},
    {"ctx", "ctx%2Eitems.UInt16"},
  ]

  def run(args : Array(String)) : String
    action = args[0]? || raise ArgumentError.new("expected write-generated, audit, read, copy-mutant, or verify-checksum")
    result = case action
             when "write-generated"
               raise ArgumentError.new("usage: helper write-generated DESTINATION mrk3|mrk4 basic|compact") unless args.size == 4
               destination = validate_new_destination(args[1])
               mark_format = case args[2]
                             when "mrk3" then CrystalClick::CompactMarkFormat::Mrk3
                             when "mrk4" then CrystalClick::CompactMarkFormat::Mrk4
                             else             raise ArgumentError.new("mark format must be mrk3 or mrk4")
                             end
               variant_mode = case args[3]
                              when "basic"   then CrystalClick::CompactVariantDiscriminatorMode::Basic
                              when "compact" then CrystalClick::CompactVariantDiscriminatorMode::Compact
                              else                raise ArgumentError.new("Variant discriminator mode must be basic or compact")
                              end
               write_generated!(destination, mark_format, variant_mode)
             when "audit"
               raise ArgumentError.new("usage: helper audit PART") unless args.size == 2
               audit(validate_part(args[1]))
             when "read"
               raise ArgumentError.new("usage: helper read PART COLUMN FIRST_MARK MARK_COUNT") unless args.size == 5
               read_outcome(validate_part(args[1]), args[2], args[3].to_i, args[4].to_i)
             when "copy-mutant"
               raise ArgumentError.new("usage: helper copy-mutant resealed|unsealed SOURCE DESTINATION COLUMN MARK") unless args.size == 6
               mode = args[1]
               unless mode == "resealed" || mode == "unsealed"
                 raise ArgumentError.new("mutant mode must be resealed or unsealed")
               end
               source = validate_part(args[2])
               destination = validate_new_destination(args[3])
               column = args[4]
               mark = args[5].to_i
               FileUtils.cp_r(source, destination)
               mutation = mutate_structure_version!(destination, column, mark, mode == "resealed")
               json({
                 "format"                 => FORMAT,
                 "action"                 => action,
                 "status"                 => "ok",
                 "mode"                   => mode,
                 "source_path"            => source,
                 "mutant_path"            => destination,
                 "column"                 => column,
                 "stream"                 => mutation[:stream],
                 "mark"                   => mark,
                 "version_before"         => mutation[:version_before],
                 "version_after"          => mutation[:version_after],
                 "logical_offset"         => mutation[:logical_offset],
                 "raw_changed_offsets"    => mutation[:raw_changed_offsets],
                 "compressed_size_before" => mutation[:compressed_size_before],
                 "compressed_size_after"  => mutation[:compressed_size_after],
                 "raw_size"               => mutation[:raw_size],
                 "frame_count"            => mutation[:frame_count],
                 "checksums_resealed"     => mode == "resealed",
               })
             when "verify-checksum"
               raise ArgumentError.new("usage: helper verify-checksum PART FILE") unless args.size == 3
               verify_file_checksum(validate_part(args[1]), args[2])
             else
               raise ArgumentError.new("unknown helper action: #{action}")
             end
    JSON.build { |json| result.to_json(json) }
  end

  private def validate_part(path : String) : String
    expanded = File.expand_path(path)
    unless Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      raise CrystalClick::InvalidPartError.new("W268 part must be a canonical non-symlink directory")
    end
    expanded
  end

  private def validate_new_destination(path : String) : String
    expanded = File.expand_path(path)
    raise ArgumentError.new("W268 destination already exists or is symlinked") if File.exists?(expanded) || File.symlink?(expanded)
    parent = File.dirname(expanded)
    unless Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent
      raise ArgumentError.new("W268 destination parent must already be canonical and non-symlinked")
    end
    expanded
  end

  private def read_bytes(path : String) : Bytes
    expanded = File.expand_path(path)
    unless File.file?(expanded) && !File.symlink?(expanded)
      raise CrystalClick::CorruptPartError.new("W268 expected a regular non-symlink file")
    end
    size = File.size(expanded)
    if size < 0 || size > MAX_FILE_BYTES
      raise CrystalClick::CorruptPartError.new("W268 file exceeds its bounded read size")
    end
    File.read(expanded).to_slice.dup
  end

  private def decode_hex(value : String) : Bytes
    unless value.bytesize.even? && value.bytesize <= MAX_RAW_BYTES * 2
      raise CrystalClick::CorruptPartError.new("W268 hexadecimal byte string exceeds its bound")
    end
    bytes = Bytes.new(value.bytesize // 2)
    slice = value.to_slice
    bytes.size.times do |index|
      high = hex_nibble(slice[index * 2])
      low = hex_nibble(slice[index * 2 + 1])
      bytes[index] = ((high << 4) | low).to_u8
    end
    bytes
  end

  private def hex_nibble(byte : UInt8) : UInt8
    case byte
    when 48_u8..57_u8  then byte - 48_u8
    when 97_u8..102_u8 then byte - 87_u8
    else
      raise CrystalClick::CorruptPartError.new("W268 expected canonical lowercase hexadecimal")
    end
  end

  private def json(value : T) : JSON::Any forall T
    JSON.parse(value.to_json)
  end

  private def read_u64_le(bytes : Bytes, offset : Int) : UInt64
    if offset < 0 || offset > bytes.size - 8
      raise CrystalClick::CorruptPartError.new("W268 truncated UInt64 field")
    end
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end

  private def write_generated!(
    destination : String,
    mark_format : CrystalClick::CompactMarkFormat,
    variant_mode : CrystalClick::CompactVariantDiscriminatorMode,
  ) : JSON::Any
    CrystalClick::CompactPartWriter.write_uint64_columns(
      destination,
      KEY_NAME,
      Slice(UInt64).new(ROW_COUNT.to_i) { |index| index.to_u64 + 1_u64 },
      generated_columns,
      ROWS_PER_MARK.to_i,
      4096,
      mark_format: mark_format,
      variant_discriminator_mode: variant_mode,
    )
    json({
      "format"                     => FORMAT,
      "action"                     => "write-generated",
      "status"                     => "ok",
      "part_path"                  => destination,
      "row_count"                  => ROW_COUNT.to_i64,
      "mark_format"                => mark_format.mrk4? ? "mrk4" : "mrk3",
      "variant_discriminator_mode" => variant_mode.value.to_i64,
      "dynamic_context_sites"      => ["root", "root.field.1.elements"],
      "statistics_source"          => "independent literal twelve-row first input block; first-prefix statistics are frozen and not recomputed from later granules",
    })
  end

  private def generated_columns : Array(CrystalClick::CompactPartColumn)
    root_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    ctx_type = CrystalClick::BinaryDataType.tuple(
      [
        CrystalClick::BinaryDataType.primitive("String"),
        CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.dynamic(max_types: 1)),
      ] of CrystalClick::BinaryDataType,
      ["label", "items"] of String,
    )
    root_stats = CrystalClick::StructureStatistics.new(
      [5_u64, 5_u64] of UInt64,
      [
        CrystalClick::StructureStatistic.new("String", 3_u64),
        CrystalClick::StructureStatistic.new("UInt64", 2_u64),
      ] of CrystalClick::StructureStatistic,
    )
    nested_stats = CrystalClick::StructureStatistics.new(
      [6_u64, 7_u64] of UInt64,
      [
        CrystalClick::StructureStatistic.new("String", 4_u64),
        CrystalClick::StructureStatistic.new("UInt64", 2_u64),
      ] of CrystalClick::StructureStatistic,
    )
    root_structure = CrystalClick::DynamicStructure.new(
      [CrystalClick::BinaryDataType.primitive("UInt8")] of CrystalClick::BinaryDataType,
      root_stats,
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    nested_structure = CrystalClick::DynamicStructure.new(
      [CrystalClick::BinaryDataType.primitive("UInt16")] of CrystalClick::BinaryDataType,
      nested_stats,
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    root_sites = {"root" => root_structure} of String => CrystalClick::DynamicStructure
    nested_sites = {"root.field.1.elements" => nested_structure} of String => CrystalClick::DynamicStructure
    root_context = CrystalClick::CompactDynamicWriteContext.new(root_sites)
    nested_context = CrystalClick::CompactDynamicWriteContext.new(nested_sites)

    [
      CrystalClick::CompactPartColumn.dynamic_bulk("root", root_type, split_marks(generated_root_rows(root_type)), root_context),
      CrystalClick::CompactPartColumn.dynamic_bulk("ctx", ctx_type, split_marks(generated_ctx_rows(ctx_type)), nested_context),
    ] of CrystalClick::CompactPartColumn
  end

  private def generated_root_rows(dynamic : CrystalClick::BinaryDataType) : Array(CrystalClick::BinaryValue)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    [
      dynamic_value(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[11_u8])),
      dynamic_value(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[12_u8])),
      dynamic_value(dynamic, CrystalClick::BinaryValue.string("r3")),
      dynamic_value(dynamic, CrystalClick::BinaryValue.uint64(9001_u64)),
      dynamic_value(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[13_u8])),
      dynamic_value(dynamic, CrystalClick::BinaryValue.string("r6")),
      dynamic_value(dynamic, nil),
      dynamic_value(dynamic, nil),
      dynamic_value(dynamic, CrystalClick::BinaryValue.string("r9")),
      dynamic_value(dynamic, CrystalClick::BinaryValue.uint64(9002_u64)),
      dynamic_value(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[14_u8])),
      dynamic_value(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[15_u8])),
    ] of CrystalClick::BinaryValue
  end

  private def generated_ctx_rows(ctx_type : CrystalClick::BinaryDataType) : Array(CrystalClick::BinaryValue)
    string = CrystalClick::BinaryDataType.primitive("String")
    uint16 = CrystalClick::BinaryDataType.primitive("UInt16")
    uint16_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    items_type = CrystalClick::BinaryDataType.array(uint16_dynamic)
    nested = [
      [dynamic_value(uint16_dynamic, uint16_value(uint16, 101_u16))],
      [dynamic_value(uint16_dynamic, uint16_value(uint16, 102_u16))],
      [dynamic_value(uint16_dynamic, uint16_value(uint16, 103_u16)), dynamic_value(uint16_dynamic, CrystalClick::BinaryValue.string("n4"))],
      [dynamic_value(uint16_dynamic, CrystalClick::BinaryValue.uint64(19001_u64))],
      [dynamic_value(uint16_dynamic, CrystalClick::BinaryValue.string("n5"))],
      [dynamic_value(uint16_dynamic, uint16_value(uint16, 104_u16)), dynamic_value(uint16_dynamic, uint16_value(uint16, 105_u16))],
      [] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
      [dynamic_value(uint16_dynamic, CrystalClick::BinaryValue.uint64(19002_u64))],
      [dynamic_value(uint16_dynamic, CrystalClick::BinaryValue.string("n10")), dynamic_value(uint16_dynamic, uint16_value(uint16, 106_u16))],
      [dynamic_value(uint16_dynamic, uint16_value(uint16, 107_u16)), dynamic_value(uint16_dynamic, CrystalClick::BinaryValue.string("tail"))],
      [dynamic_value(uint16_dynamic, nil)],
    ] of Array(CrystalClick::BinaryValue)
    rows = Array(CrystalClick::BinaryValue).new(ROW_COUNT)
    nested.each_with_index do |values, index|
      label = "r#{(index + 1).to_s.rjust(2, '0')}"
      rows << CrystalClick::BinaryValue.tuple(
        ctx_type,
        [
          CrystalClick::BinaryValue.string(label),
          CrystalClick::BinaryValue.array(items_type, values),
        ] of CrystalClick::BinaryValue,
      )
    end
    rows
  end

  private def dynamic_value(
    type : CrystalClick::BinaryDataType,
    child : CrystalClick::BinaryValue?,
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.dynamic(type, child)
  end

  private def uint16_value(type : CrystalClick::BinaryDataType, value : UInt16) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(
      type,
      Bytes[(value & 0x00ff_u16).to_u8, (value >> 8).to_u8],
    )
  end

  private def split_marks(rows : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
    rows.each_slice(ROWS_PER_MARK.to_i).map(&.to_a).to_a
  end

  private def audit(part : String) : JSON::Any
    physical = CrystalClick::CompactPartPhysicalContext.open(part)
    unless physical.row_count == ROW_COUNT && physical.granule_count == MARK_COUNT
      raise CrystalClick::CorruptPartError.new("W268 part is not the bounded twelve-row, six-mark witness")
    end
    mark_rows = physical.mark_row_counts
    unless mark_rows == Array(UInt64).new(MARK_COUNT) { ROWS_PER_MARK }
      raise CrystalClick::CorruptPartError.new("W268 mark rows differ from the six two-row grid")
    end
    observed_roster = physical.physical_roster.map { |slot| {slot.column_name, slot.stream_name || ""} }
    expected_physical_roster = if physical.mode.mrk4?
                                 EXPECTED_ROSTER
                               else
                                 [{"pk", ""}, {"root", ""}, {"ctx", ""}]
                               end
    unless observed_roster == expected_physical_roster
      raise CrystalClick::CorruptPartError.new("W268 reader physical roster differs from the pinned source order")
    end

    data = read_bytes(File.join(part, "data.bin"))
    raw = CrystalClick::CompressedBlock.decode_all(data, max_output_size: MAX_RAW_BYTES)
    checksums = CrystalClick::PartChecksums.open(part)
    mark_name = physical.mode.mrk4? ? "data.mrk4" : "data.mrk3"
    checksums.validate_selected_entries(part, "data.bin", mark_name)
    mark_bytes = read_bytes(File.join(part, mark_name))
    mark_tape = audit_mark_tape(physical, mark_bytes, data.size.to_u64, raw.size.to_u64)
    callback_shards = read_callback_shards(physical)
    dynamic_structures, variant_prefixes = if physical.mode.mrk4?
                                             {structure_prefixes(callback_shards), variant_prefixes(callback_shards)}
                                           else
                                             discover_dynamic_prefixes(physical)
                                           end
    validate_prefix_profile!(dynamic_structures, variant_prefixes)
    windows = read_windows(part)

    json({
      "format"                  => FORMAT,
      "action"                  => "audit",
      "status"                  => "ok",
      "mark_format"             => physical.mode.mrk4? ? "mrk4" : "mrk3",
      "row_count"               => physical.row_count,
      "granule_count"           => physical.granule_count,
      "mark_rows"               => mark_rows,
      "physical_roster"         => observed_roster.map { |column, stream| {"column" => column, "stream" => stream} },
      "physical_mark_tape"      => mark_tape,
      "data_bin_bytes"          => data.size,
      "raw_data_hex"            => raw.hexstring,
      "callback_shards"         => callback_shards,
      "dynamic_structures"      => dynamic_structures,
      "variant_prefixes"        => variant_prefixes,
      "windows"                 => windows,
      "callback_audit_boundary" => physical.mode.mrk4? ? "all named callbacks are persisted as MRK4 slots and audited" : "MRK3 persists one whole-column coordinate per column; Dynamic prefixes are decoded from the whole-column tape, while callback names are not persisted",
      "checksum_claim"          => "selected checksum entries and source frame checksums were read; whole-file checksum hashes are reported only by verify-checksum",
    })
  end

  private def audit_mark_tape(
    physical : CrystalClick::CompactPartPhysicalContext,
    bytes : Bytes,
    compressed_size : UInt64,
    raw_size : UInt64,
  ) : JSON::Any
    slot_count = physical.physical_roster.size
    record_width = slot_count * 16 + 8
    record_count = MARK_COUNT + 1
    expected_size = record_width * record_count
    expected_slot_count = physical.mode.mrk4? ? 13 : 3
    unless slot_count == expected_slot_count && bytes.size == expected_size
      raise CrystalClick::CorruptPartError.new("W268 mark tape dimensions differ from its MRK3/MRK4 callback contract")
    end
    records = Array(JSON::Any).new(record_count)
    expected_rows = Array(UInt64).new(MARK_COUNT) { ROWS_PER_MARK } + [0_u64]
    record_count.times do |mark|
      start = mark * record_width
      pairs = Array(JSON::Any).new(slot_count)
      slot_count.times do |slot|
        offset = start + slot * 16
        compressed_offset = read_u64_le(bytes, offset)
        decompressed_offset = read_u64_le(bytes, offset + 8)
        logical_position = physical.logical_position({compressed_offset, decompressed_offset})
        if logical_position < 0 || logical_position.to_u64 > raw_size
          raise CrystalClick::CorruptPartError.new("W268 MRK4 pair resolves outside data.bin")
        end
        pairs << JSON::Any.new({
          "slot"                => JSON::Any.new(slot.to_i64),
          "compressed_offset"   => JSON::Any.new(compressed_offset.to_i64),
          "decompressed_offset" => JSON::Any.new(decompressed_offset.to_i64),
          "logical_position"    => JSON::Any.new(logical_position),
        })
      end
      row_count = read_u64_le(bytes, start + slot_count * 16)
      unless row_count == expected_rows[mark]
        raise CrystalClick::CorruptPartError.new("W268 MRK4 row-count trailer differs at mark #{mark}")
      end
      records << JSON::Any.new({
        "mark"      => JSON::Any.new(mark.to_i64),
        "row_count" => JSON::Any.new(row_count.to_i64),
        "pairs"     => JSON::Any.new(pairs),
      })
    end
    json({
      "file"            => physical.mode.mrk4? ? "data.mrk4" : "data.mrk3",
      "slot_count"      => slot_count,
      "record_width"    => record_width,
      "byte_size"       => bytes.size,
      "compressed_size" => compressed_size.to_i64,
      "raw_size"        => raw_size.to_i64,
      "records"         => records,
    })
  end

  private def read_callback_shards(
    physical : CrystalClick::CompactPartPhysicalContext,
  ) : Array(JSON::Any)
    names = [KEY_NAME, ROOT_NAME, CONTEXT_NAME]
    windows = Hash(String, CrystalClick::CompactPartPhysicalWindow).new
    names.each { |name| windows[name] = physical.read_window(name, 0, physical.granule_count) }
    result = [] of JSON::Any
    physical.granule_count.times do |mark|
      names.each do |column|
        windows[column].granules[mark].shards.each do |shard|
          result << JSON::Any.new({
            "column"        => JSON::Any.new(column),
            "mark"          => JSON::Any.new(mark.to_i64),
            "slot"          => JSON::Any.new(shard.slot_index.to_i64),
            "stream"        => JSON::Any.new(shard.stream_name || ""),
            "logical_start" => JSON::Any.new(shard.logical_start),
            "logical_end"   => JSON::Any.new(shard.logical_end),
            "byte_count"    => JSON::Any.new(shard.bytes.size.to_i64),
            "bytes_hex"     => JSON::Any.new(shard.bytes.hexstring),
          })
        end
      end
    end
    result
  end

  private def structure_prefixes(shards : Array(JSON::Any)) : Array(JSON::Any)
    result = [] of JSON::Any
    shards.each do |shard|
      object = shard.as_h
      stream = object["stream"].as_s
      next unless stream.ends_with?(".dynamic_structure")
      bytes = decode_hex(object["bytes_hex"].as_s)
      structure = CrystalClick::DynamicStructureCodec.decode(bytes)
      statistics = structure.statistics
      statistics_json = if value = statistics
                          json({
                            "counts" => value.counts.map(&.to_i64),
                            "shared" => value.shared.map do |entry|
                              {"name_hex" => entry.name.to_slice.hexstring, "count" => entry.count.to_i64}
                            end,
                          })
                        else
                          JSON::Any.new(nil)
                        end
      result << JSON::Any.new({
        "column"          => object["column"],
        "mark"            => object["mark"],
        "stream"          => object["stream"],
        "bytes_hex"       => object["bytes_hex"],
        "version"         => JSON::Any.new(structure.version.to_i64),
        "ordinary_types"  => JSON::Any.new(structure.types.map(&.name).map { |name| JSON::Any.new(name) }),
        "statistics_flag" => JSON::Any.new(statistics.nil? ? 0_i64 : 1_i64),
        "statistics"      => statistics_json,
      } of String => JSON::Any)
    end
    expected_streams = ["root.dynamic_structure", "ctx%2Eitems.dynamic_structure"]
    unless result.size == expected_streams.size * MARK_COUNT
      raise CrystalClick::CorruptPartError.new("W268 Dynamic structure callback census differs from two sites across six marks")
    end
    expected_streams.each do |stream|
      selected = result.select { |item| item.as_h["stream"].as_s == stream }
      unless selected.map { |item| item.as_h["mark"].as_i64 } == (0...MARK_COUNT).map(&.to_i64)
        raise CrystalClick::CorruptPartError.new("W268 Dynamic structure callback mark order differs")
      end
    end
    result
  end

  private def discover_dynamic_prefixes(
    physical : CrystalClick::CompactPartPhysicalContext,
  ) : Tuple(Array(JSON::Any), Array(JSON::Any))
    structures = [] of JSON::Any
    variants = [] of JSON::Any
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    profile = CrystalClick::BinaryBulkProfile.single_stream
    sites = {
      "root" => {ROOT_NAME, ROOT_TYPE, "root", "root.dynamic_structure", "root.variant_discr_prefix"},
      "ctx"  => {CONTEXT_NAME, CONTEXT_TYPE, "root.field.1.elements", "ctx%2Eitems.dynamic_structure", "ctx%2Eitems.variant_discr_prefix"},
    }

    sites.each_value do |column, type, path, structure_stream, variant_stream|
      traversal = CrystalClick::CompactDynamicBulkPrefixTraversal.new(type, profile, limits)
      window = physical.read_window(column, 0, MARK_COUNT)
      window.granules.each_with_index do |granule, mark|
        budget = CrystalClick::BinaryCodecBudget.new(limits)
        cursor = CrystalClick::CompactBinaryBulkGranuleCursor.new(physical.mode, granule.shards, nil)
        cursor.charge_complete_wire_input!(budget)
        observed, modes = traversal.discover(cursor, budget)
        structure = observed[path]?
        unless structure
          raise CrystalClick::CorruptPartError.new("W268 raw Dynamic prefix is missing its declared site")
        end
        statistics = structure.statistics
        statistics_json = if value = statistics
                            json({
                              "counts" => value.counts.map(&.to_i64),
                              "shared" => value.shared.map do |entry|
                                {"name_hex" => entry.name.to_slice.hexstring, "count" => entry.count.to_i64}
                              end,
                            })
                          else
                            JSON::Any.new(nil)
                          end
        structures << JSON::Any.new({
          "column"          => JSON::Any.new(column),
          "mark"            => JSON::Any.new(mark.to_i64),
          "stream"          => JSON::Any.new(structure_stream),
          "version"         => JSON::Any.new(structure.version.to_i64),
          "ordinary_types"  => JSON::Any.new(structure.types.map(&.name).map { |name| JSON::Any.new(name) }),
          "statistics_flag" => JSON::Any.new(statistics.nil? ? 0_i64 : 1_i64),
          "statistics"      => statistics_json,
        } of String => JSON::Any)

        mode = modes["#{path}.discriminators"]?
        unless mode
          raise CrystalClick::CorruptPartError.new("W268 raw Variant discriminator prefix is missing")
        end
        prefix_bytes = Bytes.new(8) { |index| (mode >> (index * 8)).to_u8 }
        variants << JSON::Any.new({
          "column"     => JSON::Any.new(column),
          "mark"       => JSON::Any.new(mark.to_i64),
          "stream"     => JSON::Any.new(variant_stream),
          "prefix_hex" => JSON::Any.new(prefix_bytes.hexstring),
          "mode"       => JSON::Any.new(mode.to_i64),
        })
      end
    end
    {structures, variants}
  end

  private def variant_prefixes(shards : Array(JSON::Any)) : Array(JSON::Any)
    result = [] of JSON::Any
    shards.each do |shard|
      object = shard.as_h
      stream = object["stream"].as_s
      next unless stream.ends_with?(".variant_discr_prefix")
      bytes = decode_hex(object["bytes_hex"].as_s)
      unless bytes.size == 8
        raise CrystalClick::CorruptPartError.new("W268 Variant discriminator prefix is not one LE UInt64")
      end
      result << JSON::Any.new({
        "column"     => object["column"],
        "mark"       => object["mark"],
        "stream"     => object["stream"],
        "prefix_hex" => object["bytes_hex"],
        "mode"       => JSON::Any.new(read_u64_le(bytes, 0).to_i64),
      })
    end
    unless result.size == 2 * MARK_COUNT
      raise CrystalClick::CorruptPartError.new("W268 Variant discriminator prefix census differs from two sites across six marks")
    end
    result
  end

  private def validate_prefix_profile!(structures : Array(JSON::Any), variants : Array(JSON::Any)) : Nil
    structures.each do |item|
      object = item.as_h
      unless object["version"].as_i64 == CrystalClick::DynamicStructure::VERSION_V3.to_i64
        raise CrystalClick::CorruptPartError.new("W268 stock Dynamic structure wire version is not V3 value 4")
      end
      stream = object["stream"].as_s
      mark = object["mark"].as_i64
      expected_type = stream == "root.dynamic_structure" ? "UInt8" : "UInt16"
      unless object["ordinary_types"].as_a.map(&.as_s) == [expected_type]
        raise CrystalClick::CorruptPartError.new("W268 stock Dynamic ordinary roster differs at #{stream}")
      end
      expected_flag = mark == 0 ? 1 : 0
      unless object["statistics_flag"].as_i64 == expected_flag
        raise CrystalClick::CorruptPartError.new("W268 stock Dynamic statistics prefix flag differs at #{stream} mark #{mark}")
      end
      statistics = object["statistics"]
      if mark == 0
        expected_counts = stream == "root.dynamic_structure" ? [5_i64, 5_i64] : [6_i64, 7_i64]
        expected_shared = if stream == "root.dynamic_structure"
                            {"String" => 3_i64, "UInt64" => 2_i64}
                          else
                            {"String" => 4_i64, "UInt64" => 2_i64}
                          end
        actual_stats = statistics.as_h
        actual_counts = actual_stats["counts"].as_a.map(&.as_i64)
        actual_shared = actual_stats["shared"].as_a.to_h do |entry|
          fields = entry.as_h
          name = decode_hex(fields["name_hex"].as_s)
          {String.new(name), fields["count"].as_i64}
        end
        unless actual_counts == expected_counts && actual_shared == expected_shared
          raise CrystalClick::CorruptPartError.new("W268 first Dynamic statistics differ from the literal type census at #{stream}")
        end
      elsif !statistics.raw.nil?
        raise CrystalClick::CorruptPartError.new("W268 later Dynamic prefix is not PREFIX_EMPTY at #{stream} mark #{mark}")
      end
    end
    variants.each do |item|
      object = item.as_h
      unless object["mode"].as_i64 == 0 || object["mode"].as_i64 == 1
        raise CrystalClick::CorruptPartError.new("W268 stock Variant mode is outside BASIC/COMPACT")
      end
    end
    nil
  end

  private def read_windows(part : String) : Hash(String, JSON::Any)
    readers = {
      KEY_NAME     => nil.as(CrystalClick::CompactBinaryBulkColumnReader?),
      ROOT_NAME    => nil.as(CrystalClick::CompactDynamicBulkColumnReader?),
      CONTEXT_NAME => nil.as(CrystalClick::CompactDynamicBulkColumnReader?),
    }
    readers[KEY_NAME] = CrystalClick::CompactBinaryBulkColumnReader.open(
      part, KEY_NAME, CrystalClick::BinaryDataType.primitive("UInt64")
    )
    readers[ROOT_NAME] = CrystalClick::CompactDynamicBulkColumnReader.open(part, ROOT_NAME, ROOT_TYPE)
    readers[CONTEXT_NAME] = CrystalClick::CompactDynamicBulkColumnReader.open(part, CONTEXT_NAME, CONTEXT_TYPE)
    output = Hash(String, JSON::Any).new
    WINDOWS.each do |name, window|
      columns = Hash(String, JSON::Any).new
      readers.each do |column, reader|
        selected = reader || raise CrystalClick::CorruptPartError.new("W268 reader was not opened")
        values = selected.read_marks(window[0], window[1])
        flat = values.flatten
        signatures = if column == KEY_NAME
                       flat.map { |value| JSON::Any.new(value.as_uint64.to_s) }
                     else
                       flat.map { |value| JSON::Any.new(signature(value)) }
                     end
        columns[column] = JSON::Any.new(signatures)
      end
      output[name] = JSON::Any.new(columns)
    end
    output
  end

  private def signature(value : CrystalClick::BinaryValue) : String
    type = value.type
    case type.tag
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      return "D:NULL" if value.is_null?
      child = value.element_at(0)
      "D:#{child.type.name}:#{signature(child)}"
    when CrystalClick::BinaryDataType::TAG_STRING
      "S:#{value.bytes.hexstring}"
    when CrystalClick::BinaryDataType::TAG_UINT8,
         CrystalClick::BinaryDataType::TAG_UINT16,
         CrystalClick::BinaryDataType::TAG_UINT32,
         CrystalClick::BinaryDataType::TAG_UINT64
      bytes = value.bytes
      number = 0_u64
      bytes.each_with_index { |byte, index| number |= byte.to_u64 << (index * 8) }
      "U#{bytes.size * 8}:#{number}"
    when CrystalClick::BinaryDataType::TAG_ARRAY
      "A:[#{value.elements.map { |item| signature(item) }.join(",")}]"
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      "T:(#{value.elements.map { |item| signature(item) }.join(",")})"
    else
      raise CrystalClick::UnsupportedFormatError.new("W268 signature renderer does not admit #{type.name}")
    end
  end

  private def read_outcome(part : String, column : String, first_mark : Int32, mark_count : Int32) : JSON::Any
    unless first_mark >= 0 && mark_count >= 0 && first_mark <= MARK_COUNT && mark_count <= MARK_COUNT - first_mark
      raise ArgumentError.new("W268 mark selection is outside the six-mark grid")
    end
    type = case column
           when KEY_NAME     then CrystalClick::BinaryDataType.primitive("UInt64")
           when ROOT_NAME    then ROOT_TYPE
           when CONTEXT_NAME then CONTEXT_TYPE
           else                   raise ArgumentError.new("W268 column is outside the witness")
           end
    reader = if type.contains_dynamic?
               CrystalClick::CompactDynamicBulkColumnReader.open(part, column, type)
             else
               CrystalClick::CompactBinaryBulkColumnReader.open(part, column, type)
             end
    values = reader.read_marks(first_mark, mark_count).flatten
    signatures = if column == KEY_NAME
                   values.map { |value| value.as_uint64.to_s }
                 else
                   values.map { |value| signature(value) }
                 end
    json({
      "format"     => FORMAT,
      "action"     => "read",
      "status"     => "accepted",
      "column"     => column,
      "first_mark" => first_mark,
      "mark_count" => mark_count,
      "row_count"  => values.size,
      "signatures" => signatures,
    })
  rescue error : CrystalClick::Error
    json({
      "format"        => FORMAT,
      "action"        => "read",
      "status"        => "rejected",
      "column"        => column,
      "first_mark"    => first_mark,
      "mark_count"    => mark_count,
      "error_class"   => error.class.name,
      "error_message" => error.message || "",
    })
  end

  private def verify_file_checksum(part : String, name : String) : JSON::Any
    checksums = CrystalClick::PartChecksums.open(part)
    entry = checksums.entry(name) || raise CrystalClick::CorruptPartError.new("W268 checksum entry is missing")
    bytes = read_bytes(File.join(part, name))
    actual_hash = CrystalClick::CityHashV1.file_hash(bytes)
    expected_hash = entry.file_hash
    status = actual_hash == expected_hash ? "accepted" : "rejected"
    json({
      "format"                 => FORMAT,
      "action"                 => "verify-checksum",
      "status"                 => status,
      "file"                   => name,
      "physical_size"          => bytes.size,
      "declared_physical_size" => entry.physical_size.to_i64,
      "file_hash_matches"      => actual_hash == expected_hash,
      "expected_file_hash"     => "#{expected_hash[0].to_s(16)}:#{expected_hash[1].to_s(16)}",
      "actual_file_hash"       => "#{actual_hash[0].to_s(16)}:#{actual_hash[1].to_s(16)}",
    })
  end

  private def mutate_structure_version!(
    part : String,
    column : String,
    mark : Int32,
    reseal : Bool,
  ) : NamedTuple(
    stream: String,
    version_before: UInt64,
    version_after: UInt64,
    logical_offset: Int32,
    raw_changed_offsets: Array(Int32),
    compressed_size_before: Int32,
    compressed_size_after: Int32,
    raw_size: Int32,
    frame_count: Int32,
  )
    unless column == CONTEXT_NAME && mark == 2
      raise ArgumentError.new("W268 version mutant is fixed to ctx mark 2")
    end
    physical = CrystalClick::CompactPartPhysicalContext.open(part)
    raise CrystalClick::UnsupportedFormatError.new("W268 version mutant requires MRK4") unless physical.mode.mrk4?
    window = physical.read_window(column, mark, 1)
    stream = "ctx%2Eitems.dynamic_structure"
    prefix = window.granules.first.shards.find { |shard| shard.stream_name == stream } ||
             raise CrystalClick::CorruptPartError.new("W268 nested Dynamic structure callback is absent")
    prefix_bytes = prefix.bytes
    version_before = read_u64_le(prefix_bytes, 0)
    unless version_before == CrystalClick::DynamicStructure::VERSION_V3
      raise CrystalClick::CorruptPartError.new("W268 poison source does not contain V3 wire value 4")
    end

    data_path = File.join(part, "data.bin")
    compressed = read_bytes(data_path)
    raw = CrystalClick::CompressedBlock.decode_all(compressed, max_output_size: MAX_RAW_BYTES)
    logical_offset = prefix.logical_start.to_i
    if logical_offset < 0 || logical_offset > raw.size - 8
      raise CrystalClick::CorruptPartError.new("W268 Dynamic structure prefix offset is outside raw data.bin")
    end
    original_raw = Bytes.new(raw.size) { |index| raw[index] }
    raw[logical_offset] = 3_u8
    version_after = read_u64_le(raw, logical_offset)
    unless version_after == 3_u64
      raise CrystalClick::CorruptPartError.new("W268 poison did not change V3 wire value 4 to flattened value 3")
    end

    rebuilt = IO::Memory.new(compressed.size)
    compressed_offset = 0_i64
    logical_start = 0_i64
    frame_count = 0_i32
    while compressed_offset < compressed.size.to_i64
      frame = CrystalClick::CompressedBlock.decode_frame(compressed, compressed_offset)
      frame_raw = raw[logical_start.to_i, frame.output.size]
      frame_bytes = CrystalClick::PartWriterInfrastructure::StreamEncoding.encode_lz4_frame(frame_raw)
      unless frame_bytes.size.to_i64 == frame.end_offset - compressed_offset
        raise CrystalClick::CorruptPartError.new("W268 resealed LZ4 frame size changed and would move persisted mark coordinates")
      end
      rebuilt.write(frame_bytes)
      logical_start += frame.output.size
      compressed_offset = frame.end_offset
      frame_count += 1
    end
    unless logical_start == raw.size && rebuilt.size == compressed.size
      raise CrystalClick::CorruptPartError.new("W268 resealed raw/physical data.bin size changed")
    end
    replacement = rebuilt.to_slice
    replacement_raw = CrystalClick::CompressedBlock.decode_all(replacement, max_output_size: MAX_RAW_BYTES)
    unless replacement_raw == raw
      raise CrystalClick::CorruptPartError.new("W268 recompressed data.bin differs from intended mutation")
    end
    changed_offsets = [] of Int32
    original_raw.each_with_index { |byte, index| changed_offsets << index.to_i32 if replacement_raw[index] != byte }
    unless changed_offsets == [logical_offset]
      raise CrystalClick::CorruptPartError.new("W268 poison changed bytes outside its one-byte structure version")
    end
    File.write(data_path, replacement)
    reseal_checksums!(part) if reseal
    {
      stream:                 stream,
      version_before:         version_before,
      version_after:          version_after,
      logical_offset:         logical_offset.to_i32,
      raw_changed_offsets:    changed_offsets,
      compressed_size_before: compressed.size.to_i32,
      compressed_size_after:  replacement.size.to_i32,
      raw_size:               raw.size.to_i32,
      frame_count:            frame_count,
    }
  end

  private def folded_hash(raw : Bytes) : {UInt64, UInt64}
    digest = CrystalClick::CityHashV1.file_hash(raw)
    bytes = Bytes.new(16, 0_u8)
    8.times do |index|
      bytes[index] = ((digest[0] >> (index * 8)) & 0xff).to_u8
      bytes[8 + index] = ((digest[1] >> (index * 8)) & 0xff).to_u8
    end
    CrystalClick::CityHashV1.hash128_with_seed(bytes, 0_u64, 0_u64)
  end

  private def reseal_checksums!(part : String) : Nil
    existing = CrystalClick::PartChecksums.open(part)
    records = [] of CrystalClick::PartWriterInfrastructure::ChecksumRecord
    existing.entries.each do |name, entry|
      bytes = read_bytes(File.join(part, name))
      file_hash = CrystalClick::CityHashV1.file_hash(bytes)
      if entry.compressed
        raw = CrystalClick::CompressedBlock.decode_all(bytes, max_output_size: MAX_RAW_BYTES)
        unless raw.size.to_u64 == entry.uncompressed_size
          raise CrystalClick::CorruptPartError.new("W268 resealed compressed stream raw size differs")
        end
        records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(
          name, bytes.size.to_u64, file_hash, true, raw.size.to_u64, folded_hash(raw)
        )
      else
        records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(name, bytes.size.to_u64, file_hash, false)
      end
    end
    CrystalClick::PartWriterInfrastructure::PartChecksumsWriter.write(part, records)
    nil
  end
end

begin
  puts CompactPartWriterW268Helper.run(ARGV)
rescue error
  STDERR.puts "W268 helper failed: #{error.class}: #{error.message}"
  exit 1
end
