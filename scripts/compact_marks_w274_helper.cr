require "../src/crystal_click"
require "digest/sha256"
require "json"

module CompactMarksW274Helper
  extend self

  FORMAT = "compact_marks_w274_helper_v1"
  MAX_RAW_BYTES = 64_i64 * 1024 * 1024
  UINT64_COLUMNS = ["pk", "value"]
  PHYSICAL_COLUMNS = ["pk", "value", "label", "tags"]

  def run(args : Array(String)) : String
    action = args[0]? || raise ArgumentError.new("expected marks or physical")
    unless args.size == 2
      raise ArgumentError.new("usage: helper marks|physical CANONICAL_PART")
    end

    part = validate_part(args[1])
    report = case action
             when "marks"
               read_marks(part)
             when "physical"
               read_physical(part)
             else
               raise ArgumentError.new("unknown W274 helper action: #{action}")
             end
    report.to_json
  end

  private def json(value : T) : JSON::Any forall T
    JSON.parse(value.to_json)
  end

  private def validate_part(path : String) : String
    expanded = File.expand_path(path)
    unless Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      raise CrystalClick::InvalidPartError.new("W274 part must be a canonical non-symlink directory")
    end
    expanded
  end

  private def marks_file(part : String, checksums : CrystalClick::PartChecksums) : Tuple(String, CrystalClick::PartChecksums::Entry)
    candidates = checksums.entries.keys.select do |name|
      name == "data.mrk3" || name == "data.mrk4" || name == "data.cmrk3" || name == "data.cmrk4"
    end
    unless candidates.size == 1
      raise CrystalClick::CorruptPartError.new("W274 part must declare exactly one supported Compact mark file")
    end
    name = candidates[0]
    entry = checksums.entry(name) || raise CrystalClick::CorruptPartError.new("W274 mark checksum entry disappeared")
    unless entry.physical_size <= MAX_RAW_BYTES.to_u64
      raise CrystalClick::CorruptPartError.new("W274 mark file exceeds the helper byte bound")
    end
    path = File.join(part, name)
    if File.symlink?(path) || !File.file?(path) || File.size(path).to_u64 != entry.physical_size
      raise CrystalClick::CorruptPartError.new("W274 mark file does not match its checksum size declaration")
    end
    {name, entry}
  end

  private def mark_layout(name : String) : String
    if name.ends_with?("mrk3")
      "mrk3"
    elsif name.ends_with?("mrk4")
      "mrk4"
    else
      raise CrystalClick::UnsupportedFormatError.new("W274 mark file has an unsupported layout")
    end
  end

  private def read_marks(part : String) : JSON::Any
    checksums = CrystalClick::PartChecksums.open(part)
    name, entry = marks_file(part, checksums)
    canonical = if entry.compressed
                  budget = CrystalClick::CompressedStreamBudget.new(
                    CrystalClick::CompressedStreamLimits.new(
                      max_file_bytes: MAX_RAW_BYTES.to_i,
                      max_mark_bytes: MAX_RAW_BYTES.to_i,
                      max_frame_compressed_bytes: MAX_RAW_BYTES.to_i,
                      max_frame_decompressed_bytes: MAX_RAW_BYTES.to_i,
                      max_records: 100_000,
                      max_decoded_bytes: MAX_RAW_BYTES.to_i,
                      max_result_bytes: MAX_RAW_BYTES.to_i,
                    )
                  )
                  CrystalClick::CompressedMarkReader.read_all(
                    File.join(part, name),
                    entry.physical_size.to_i64,
                    budget,
                  )
                else
                  if entry.uncompressed_size
                    raise CrystalClick::CorruptPartError.new("W274 plain mark file declares compressed metadata")
                  end
                  checksums.validate_selected_entries(part, name)
                  File.read(File.join(part, name)).to_slice.dup
                end
    if canonical.size.to_i64 > MAX_RAW_BYTES
      raise CrystalClick::CorruptPartError.new("W274 canonical marks exceed the helper byte bound")
    end
    json({
      "format" => FORMAT,
      "action" => "marks",
      "marks_file" => name,
      "layout" => mark_layout(name),
      "compressed" => entry.compressed,
      "canonical_marks_bytes" => canonical.size,
      "canonical_marks_hex" => canonical.hexstring.downcase,
      "canonical_marks_sha256" => Digest::SHA256.hexdigest(canonical),
      "frame_authentication" => entry.compressed ? "CompressedMarkReader.read_all" : "plain-file-size-checked",
      "integrity_boundary" => "compressed-frame checksums are authenticated for compressed marks; checksums.txt ClickHouse file hash metadata is not independently verified",
    })
  end

  private def read_physical(part : String) : JSON::Any
    limits = CrystalClick::CompressedStreamLimits.new(
      max_file_bytes: MAX_RAW_BYTES.to_i,
      max_mark_bytes: MAX_RAW_BYTES.to_i,
      max_frame_compressed_bytes: MAX_RAW_BYTES.to_i,
      max_frame_decompressed_bytes: MAX_RAW_BYTES.to_i,
      max_records: 100_000,
      max_decoded_bytes: MAX_RAW_BYTES.to_i,
      max_result_bytes: MAX_RAW_BYTES.to_i,
    )
    context = CrystalClick::CompactPartPhysicalContext.open(
      part,
      CrystalClick::CompressedStreamBudget.new(limits),
    )
    windows = {} of String => JSON::Any
    PHYSICAL_COLUMNS.each do |column|
      window = context.read_window(column, 0, context.granule_count)
      windows[column] = json(window.granules.map do |granule|
        {
          "mark" => granule.mark,
          "row_offset" => granule.row_offset,
          "row_count" => granule.row_count,
          "shards" => granule.shards.map do |shard|
            {
              "slot_index" => shard.slot_index,
              "stream_name" => shard.stream_name,
              "logical_start" => shard.logical_start,
              "logical_end" => shard.logical_end,
              "bytes_hex" => shard.bytes.hexstring.downcase,
            }
          end,
        }
      end)
    end

    compact_values = {} of String => JSON::Any
    compact_checksums = {} of String => JSON::Any
    neutral_values = {} of String => JSON::Any
    neutral_checksums = {} of String => JSON::Any
    UINT64_COLUMNS.each do |column|
      type = CrystalClick::BinaryDataType.primitive("UInt64")
      compact_reader = CrystalClick::CompactBinaryBulkColumnReader.open(
        part,
        column,
        type,
      )
      compact_column_values = compact_reader.read_marks(0, compact_reader.mark_count).flat_map do |mark|
        mark.map(&.as_uint64)
      end
      compact_values[column] = json(compact_column_values.map(&.to_s))
      compact_checksums[column] = json(compact_reader.selected_checksum_names)

      neutral_reader = CrystalClick::TypedBinaryBulkColumnReader.open(part, column, type)
      neutral_column_values = neutral_reader.read_marks(0, neutral_reader.mark_count).flat_map do |mark|
        mark.map(&.as_uint64)
      end
      neutral_values[column] = json(neutral_column_values.map(&.to_s))
      neutral_checksums[column] = json(neutral_reader.selected_checksum_names)
    end

    table = CrystalClick::TypedPartTable.open_selected_typed([part], UINT64_COLUMNS)
    table_full = [] of JSON::Any
    table.scan_typed do |batch|
      table_full << json(table_batch(batch))
    end
    table_middle = [] of JSON::Any
    table.scan_typed_window(3_u64, 2) do |batch|
      table_middle << json(table_batch(batch))
    end
    table_eof = [] of JSON::Any
    table.scan_typed_window(table.total_row_count, 1) do |batch|
      table_eof << json(table_batch(batch))
    end

    json({
      "format" => FORMAT,
      "action" => "physical",
      "marks_file" => context.marks_name,
      "mode" => context.mode.to_s,
      "row_count" => context.row_count,
      "granule_count" => context.granule_count,
      "mark_row_counts" => context.mark_row_counts,
      "columns" => context.columns,
      "physical_roster" => context.physical_roster.map do |slot|
        {"index" => slot.index, "column" => slot.column_name, "stream_name" => slot.stream_name}
      end,
      "physical_windows" => windows,
      # JSON::Any stores signed integers; decimal strings preserve UInt64::MAX.
      "typed_uint64" => compact_values,
      "typed_uint64_encoding" => "decimal-string",
      "compact_binary_uint64" => {
        "values" => compact_values,
        "selected_checksum_names" => compact_checksums,
      },
      "neutral_typed_uint64" => {
        "values" => neutral_values,
        "selected_checksum_names" => neutral_checksums,
      },
      "neutral_typed_table" => {
        "part_count" => table.part_count,
        "total_row_count" => table.total_row_count,
        "part_mark_row_counts" => table.part_mark_row_counts,
        "columns" => table.columns,
        "column_types" => table.column_types,
        "column_sources" => table.column_sources,
        "full_batches" => table_full,
        "middle_window" => {"start_row" => 3, "max_rows" => 2, "batches" => table_middle},
        "eof_window" => {"start_row" => table.total_row_count, "max_rows" => 1, "batches" => table_eof},
      },
      "reader_boundary" => "local public Compact physical and BinaryBulk reader results; no native serializer claim",
      "neutral_reader_boundary" => "local public typed BinaryBulk and TypedPartTable facade results; not native serializer claims",
    })
  end

  private def table_batch(batch : CrystalClick::WidePartTableBatch) : Hash(String, JSON::Any)
    rows = batch.row_count || raise CrystalClick::CorruptPartError.new("W274 typed table batch lacks a row count")
    {
      "mark_index" => json(batch.mark_index),
      "mark_row_offset" => json(batch.mark_row_offset),
      "part_row_offset" => json(batch.part_row_offset),
      "source_row_offset" => json(batch.source_row_offset),
      "row_count" => json(rows),
      "pk" => json(batch.values_for("pk", UInt64).to_a.map(&.to_s)),
      "value" => json(batch.values_for("value", UInt64).to_a.map(&.to_s)),
    }
  end
end

puts CompactMarksW274Helper.run(ARGV)
