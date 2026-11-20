#!/usr/bin/env python3
"""Install bounded diagnostics in a disposable CrystalClick source copy."""

import argparse
from pathlib import Path


def install(root: Path) -> None:
    sources: dict[Path, str] = {}

    def replace_once(filename: str, old: str, new: str) -> None:
        path = root / "src" / "crystal_click" / filename
        source = sources[path] if path in sources else path.read_text()
        if new.strip() in source:
            return
        count = source.count(old)
        if count != 1:
            raise RuntimeError(f"{path}: expected one hook site, found {count}")
        sources[path] = source.replace(old, new, 1)

    # Keep the complete plan wall in the probe, and time the bounded root mark
    # preparation as an explicitly nested subphase (with/without prior capture).
    replace_once(
        "compact_static_json_bulk_column_reader.cr",
        "    ) : Array(CompactStaticJsonAdvancedPreparedMark)?\n      base_workspace = retained_workspace_bytes",
        "    ) : Array(CompactStaticJsonAdvancedPreparedMark)?\n"
        "      diagnostic_prepare_started = Time.instant\n"
        "      base_workspace = retained_workspace_bytes",
    )
    replace_once(
        "compact_static_json_bulk_column_reader.cr",
        "      is_advanced ? advanced_marks : nil\n    end\n\n    private def retain_prefix_metadata(",
        "      is_advanced ? advanced_marks : nil\n"
        "    ensure\n"
        "      if started = diagnostic_prepare_started\n"
        "        CrystalClick::CompactJSONScanProbeCounters.record_full_window_prepare!(\n"
        "          (Time.instant - started).total_nanoseconds.to_u64, !window_capture.nil?,\n"
        "        )\n"
        "      end\n"
        "    end\n\n    private def retain_prefix_metadata(",
    )

    replace_once(
        "compact_static_json_advanced_part_plan.cr",
        "    def validate_source! : Nil\n",
        "    def validate_source! : Nil\n      diagnostic_recheck_started = Time.instant\n",
    )
    replace_once(
        "compact_static_json_advanced_part_plan.cr",
        "      nil\n    end\n\n    def retained_workspace_bytes : UInt64",
        "      CrystalClick::CompactJSONScanProbeCounters.record_source_recheck!(\n"
        "        @frames.size, (Time.instant - diagnostic_recheck_started).total_nanoseconds.to_u64,\n"
        "      )\n      nil\n    end\n\n    def retained_workspace_bytes : UInt64",
    )

    # Count authenticated source reads and time both frame hashing and block
    # decompression. Source recheck hashes are tagged so their nested time is
    # not mistaken for another additive plan phase.
    replace_once(
        "compressed_mark_reader.cr",
        "          actual = CityHashV1.hash128(data[header_offset, compressed_size.to_i])\n"
        "          expected = {read_u64(data, offset.to_i), read_u64(data, offset.to_i + 8)}\n",
        "          diagnostic_checksum_started = Time.instant\n"
        "          actual = CityHashV1.hash128(data[header_offset, compressed_size.to_i])\n"
        "          diagnostic_checksum_ns = (Time.instant - diagnostic_checksum_started).total_nanoseconds.to_u64\n"
        "          expected = {read_u64(data, offset.to_i), read_u64(data, offset.to_i + 8)}\n",
    )
    replace_once(
        "compressed_mark_reader.cr",
        "          unless actual == fingerprint.checksum\n"
        "            raise CorruptPartError.new(\"Compact source frame checksum changed after plan preparation\")\n"
        "          end\n",
        "          unless actual == fingerprint.checksum\n"
        "            raise CorruptPartError.new(\"Compact source frame checksum changed after plan preparation\")\n"
        "          end\n"
        "          CrystalClick::CompactJSONScanProbeCounters.record_checked_frame!(\n"
        "            compressed_size, diagnostic_checksum_ns, true,\n"
        "          )\n",
    )
    replace_once(
        "compressed_mark_reader.cr",
        "      actual = CityHashV1.hash128(data[offset + CompressedBlock::CHECKSUM_SIZE, frame.compressed_size.to_i])\n",
        "      diagnostic_checksum_started = Time.instant\n"
        "      actual = CityHashV1.hash128(data[offset + CompressedBlock::CHECKSUM_SIZE, frame.compressed_size.to_i])\n"
        "      diagnostic_checksum_ns = (Time.instant - diagnostic_checksum_started).total_nanoseconds.to_u64\n",
    )
    replace_once(
        "compressed_mark_reader.cr",
        "      unless actual[0] == expected_low && actual[1] == expected_high\n"
        "        raise CorruptPartError.new(\"compressed frame checksum mismatch\")\n"
        "      end\n"
        "      actual\n    end\n",
        "      unless actual[0] == expected_low && actual[1] == expected_high\n"
        "        raise CorruptPartError.new(\"compressed frame checksum mismatch\")\n"
        "      end\n"
        "      CrystalClick::CompactJSONScanProbeCounters.record_checked_frame!(\n"
        "        frame.compressed_size, diagnostic_checksum_ns, false,\n"
        "      )\n"
        "      actual\n    end\n",
    )
    replace_once(
        "compressed_mark_reader.cr",
        "        results = output\n      end\n      results.not_nil!\n    end\n\n"
        "    # Reads one logical interval directly into its exact writable destination.",
        "        results = output\n      end\n      result = results.not_nil!\n"
        "      CrystalClick::CompactJSONScanProbeCounters.record_source_read!(ranges)\n"
        "      result\n    end\n\n"
        "    # Reads one logical interval directly into its exact writable destination.",
    )
    replace_once(
        "compressed_block.cr",
        "      payload = data[header_offset + FRAME_HEADER_SIZE, payload_size.to_i]\n"
        "      output = case method\n               when METHOD_LZ4\n                 if exact_destination = destination\n",
        "      payload = data[header_offset + FRAME_HEADER_SIZE, payload_size.to_i]\n"
        "      diagnostic_decode_started = Time.instant\n"
        "      output = case method\n               when METHOD_LZ4\n                 if exact_destination = destination\n",
    )
    replace_once(
        "compressed_block.cr",
        "      raise CorruptPartError.new(\"compressed frame output size mismatch\") unless output.size.to_i64 == decompressed_size\n"
        "      Frame.new(frame_end, output)\n    end\n\n    def self.decode_all(",
        "      raise CorruptPartError.new(\"compressed frame output size mismatch\") unless output.size.to_i64 == decompressed_size\n"
        "      CrystalClick::CompactJSONScanProbeCounters.record_decompression!(\n"
        "        method, payload_size, decompressed_size,\n"
        "        (Time.instant - diagnostic_decode_started).total_nanoseconds.to_u64,\n"
        "      )\n"
        "      Frame.new(frame_end, output)\n    end\n\n    def self.decode_all(",
    )

    # This strict profile stores Copy and per-path Dynamic Data together.
    # Time their independent decoders and the row-by-row equality walk.
    replace_once(
        "object_shared_advanced_chunk_codec.cr",
        "      rows = ObjectSharedCopyCodec.decode_with_budget(\n"
        "        copy.sizes,\n"
        "        copy.indexes,\n"
        "        copy.values,\n"
        "        structures,\n"
        "        budget,\n"
        "      )\n",
        "      diagnostic_copy_snapshot_started = Time.instant\n"
        "      copy_sizes = copy.sizes\n"
        "      copy_indexes = copy.indexes\n"
        "      copy_values = copy.values\n"
        "      diagnostic_copy_bytes = (copy_sizes.size + copy_indexes.size + copy_values.size).to_u64\n"
        "      CrystalClick::CompactJSONScanProbeCounters.record_copy_snapshot!(\n"
        "        diagnostic_copy_bytes, (Time.instant - diagnostic_copy_snapshot_started).total_nanoseconds.to_u64,\n"
        "      )\n"
        "      diagnostic_copy_decode_started = Time.instant\n"
        "      rows = ObjectSharedCopyCodec.decode_with_budget(\n"
        "        copy_sizes,\n"
        "        copy_indexes,\n"
        "        copy_values,\n"
        "        structures,\n"
        "        budget,\n"
        "      )\n",
    )
    replace_once(
        "object_shared_advanced_chunk_codec.cr",
        "      unless rows.size.to_u64 == row_count\n"
        "        raise CorruptPartError.new(\"Object shared Copy row count disagrees with its per-path chunks\")\n"
        "      end\n\n      ordered_paths = order_physical_paths(",
        "      unless rows.size.to_u64 == row_count\n"
        "        raise CorruptPartError.new(\"Object shared Copy row count disagrees with its per-path chunks\")\n"
        "      end\n"
        "      CrystalClick::CompactJSONScanProbeCounters.record_copy_decode!(\n"
        "        row_count, diagnostic_copy_bytes,\n"
        "        (Time.instant - diagnostic_copy_decode_started).total_nanoseconds.to_u64,\n"
        "      )\n\n      ordered_paths = order_physical_paths(",
    )
    replace_once(
        "object_shared_advanced_chunk_codec.cr",
        "      decoded_rows = copy.decode_into_columns_with_budget(\n",
        "      diagnostic_copy_decode_started = Time.instant\n"
        "      decoded_rows = copy.decode_into_columns_with_budget(\n",
    )
    replace_once(
        "object_shared_advanced_chunk_codec.cr",
        "      unless decoded_rows == row_count\n"
        "        raise CorruptPartError.new(\"Object shared Copy row count disagrees with its per-path chunks\")\n"
        "      end\n\n      verify_path_values_in_columns(",
        "      unless decoded_rows == row_count\n"
        "        raise CorruptPartError.new(\"Object shared Copy row count disagrees with its per-path chunks\")\n"
        "      end\n"
        "      CrystalClick::CompactJSONScanProbeCounters.record_copy_decode!(\n"
        "        row_count, (copy.sizes_size + copy.indexes_size + copy.values_size).to_u64,\n"
        "        (Time.instant - diagnostic_copy_decode_started).total_nanoseconds.to_u64,\n"
        "      )\n\n      verify_path_values_in_columns(",
    )
    replace_once(
        "object_shared_advanced_chunk_codec.cr",
        "      paths.each do |path|\n"
        "        decoded = decode_path_for_copy_verification(path, rows.size, budget, profile, nested_context)\n"
        "        rows.each_with_index do |row, row_index|\n",
        "      paths.each do |path|\n"
        "        diagnostic_data_decode_started = Time.instant\n"
        "        decoded = decode_path_for_copy_verification(path, rows.size, budget, profile, nested_context)\n"
        "        CrystalClick::CompactJSONScanProbeCounters.record_path_data_decode!(\n"
        "          path.name, rows.size.to_u64, path.streams.data_size.to_u64,\n"
        "          (Time.instant - diagnostic_data_decode_started).total_nanoseconds.to_u64,\n"
        "        )\n"
        "        diagnostic_path_equality_started = Time.instant\n"
        "        rows.each_with_index do |row, row_index|\n",
    )
    replace_once(
        "object_shared_advanced_chunk_codec.cr",
        "          end\n        end\n      end\n      rows.each_with_index do |row, index|\n",
        "          end\n"
        "        end\n"
        "        CrystalClick::CompactJSONScanProbeCounters.record_path_equality!(\n"
        "          path.name, rows.size.to_u64,\n"
        "          (Time.instant - diagnostic_path_equality_started).total_nanoseconds.to_u64,\n"
        "        )\n"
        "      end\n      rows.each_with_index do |row, index|\n",
    )
    replace_once(
        "object_shared_advanced_chunk_codec.cr",
        "          decoded = decode_path_for_column_verification(path, row_count, budget, profile, nested_context)\n\n"
        "          row_index = 0\n",
        "          diagnostic_data_decode_started = Time.instant\n"
        "          decoded = decode_path_for_column_verification(path, row_count, budget, profile, nested_context)\n"
        "          CrystalClick::CompactJSONScanProbeCounters.record_path_data_decode!(\n"
        "            path.name, row_count.to_u64, path.streams.data_size.to_u64,\n"
        "            (Time.instant - diagnostic_data_decode_started).total_nanoseconds.to_u64,\n"
        "          )\n"
        "          diagnostic_path_equality_started = Time.instant\n\n"
        "          row_index = 0\n",
    )
    replace_once(
        "object_shared_advanced_chunk_codec.cr",
        "          while row_index < row_count\n"
        "            ensure_absent_path_value!(decoded.row_at(row_index))\n"
        "            row_index += 1\n"
        "          end\n"
        "          dictionary_index += 1\n",
        "          while row_index < row_count\n"
        "            ensure_absent_path_value!(decoded.row_at(row_index))\n"
        "            row_index += 1\n"
        "          end\n"
        "          CrystalClick::CompactJSONScanProbeCounters.record_path_equality!(\n"
        "            path.name, row_count.to_u64,\n"
        "            (Time.instant - diagnostic_path_equality_started).total_nanoseconds.to_u64,\n"
        "          )\n"
        "          dictionary_index += 1\n",
    )

    # Expose useful typed/dynamic materialization by path separately from the
    # conservative Copy/Data guard. These timers are intentionally nested in
    # the worker's decode wall.
    replace_once(
        "object_document_codec.cr",
        "      typed_rows = Hash(String, Array(Array(BinaryValue))).new\n"
        "      typed_schema.each do |path, type|\n",
        "      diagnostic_selected_rows = 0_u64\n"
        "      selected_count.times do |window_offset|\n"
        "        diagnostic_selected_rows += rows_per_mark[selected_first + window_offset]\n"
        "      end\n"
        "      typed_rows = Hash(String, Array(Array(BinaryValue))).new\n"
        "      typed_schema.each do |path, type|\n"
        "        diagnostic_typed_path_started = Time.instant\n",
    )
    replace_once(
        "object_document_codec.cr",
        "        else\n"
        "          typed_rows[path] = BinaryBulkCodec.decode_with_budget(\n"
        "            type,\n"
        "            streams.typed_for(path),\n"
        "            rows_per_mark,\n"
        "            budget,\n"
        "            first_mark: selected_first,\n"
        "            mark_count: selected_count,\n"
        "            profile: profile\n"
        "          )\n"
        "        end\n"
        "      end\n\n      dynamic_rows = Hash(String, Array(Array(BinaryValue))).new\n",
        "        else\n"
        "          typed_rows[path] = BinaryBulkCodec.decode_with_budget(\n"
        "            type,\n"
        "            streams.typed_for(path),\n"
        "            rows_per_mark,\n"
        "            budget,\n"
        "            first_mark: selected_first,\n"
        "            mark_count: selected_count,\n"
        "            profile: profile\n"
        "          )\n"
        "        end\n"
        "        CrystalClick::CompactJSONScanProbeCounters.record_typed_materialization!(\n"
        "          path, type.contains_dynamic?, diagnostic_selected_rows,\n"
        "          (Time.instant - diagnostic_typed_path_started).total_nanoseconds.to_u64,\n"
        "        )\n"
        "      end\n\n      dynamic_rows = Hash(String, Array(Array(BinaryValue))).new\n",
    )
    replace_once(
        "object_document_codec.cr",
        "      dynamic_rows = Hash(String, Array(Array(BinaryValue))).new\n"
        "      object.dynamic_path_count.times do |dynamic_index|\n"
        "        path = object.dynamic_path_at(dynamic_index)\n",
        "      dynamic_rows = Hash(String, Array(Array(BinaryValue))).new\n"
        "      object.dynamic_path_count.times do |dynamic_index|\n"
        "        path = object.dynamic_path_at(dynamic_index)\n"
        "        diagnostic_dynamic_path_started = Time.instant\n",
    )
    replace_once(
        "object_document_codec.cr",
        "        end\n      end\n\n      if target = columnar\n"
        "        append_ordinary_columns(target[:output], typed_rows, dynamic_rows, budget)",
        "        end\n"
        "        CrystalClick::CompactJSONScanProbeCounters.record_dynamic_materialization!(\n"
        "          path, diagnostic_selected_rows,\n"
        "          (Time.instant - diagnostic_dynamic_path_started).total_nanoseconds.to_u64,\n"
        "        )\n"
        "      end\n\n      if target = columnar\n"
        "        append_ordinary_columns(target[:output], typed_rows, dynamic_rows, budget)",
    )

    replace_once(
        "compact_static_json_advanced_part_plan.cr",
        "      paths = [] of String\n"
        "      fallback_types = Hash(String, BinaryDataType).new\n",
        "      diagnostic_columnar_shape_started = Time.instant\n"
        "      paths = [] of String\n"
        "      fallback_types = Hash(String, BinaryDataType).new\n",
    )
    replace_once(
        "compact_static_json_advanced_part_plan.cr",
        "      @columnar_paths = paths\n"
        "      @columnar_fallback_types = fallback_types\n"
        "      nil\n    end\n\n    # :nodoc:\n    def new_columnar_output(",
        "      @columnar_paths = paths\n"
        "      @columnar_fallback_types = fallback_types\n"
        "      CrystalClick::CompactJSONScanProbeCounters.record_columnar_shape!(\n"
        "        paths.size.to_u64, fallback_types.size.to_u64,\n"
        "        (Time.instant - diagnostic_columnar_shape_started).total_nanoseconds.to_u64,\n"
        "      )\n"
        "      nil\n    end\n\n    # :nodoc:\n    def new_columnar_output(",
    )

    for path, source in sources.items():
        path.write_text(source)


def install_lz4_only(root: Path) -> None:
    """Count completed frame decodes without installing the broader hooks."""
    path = root / "src" / "crystal_click" / "compressed_block.cr"
    source = path.read_text()
    if "diagnostic_decode_started" in source and "record_decompression!" in source:
        return

    old_start = (
        "      payload = data[header_offset + FRAME_HEADER_SIZE, payload_size.to_i]\n"
        "      output = case method\n"
        "               when METHOD_LZ4\n"
        "                 if exact_destination = destination\n"
    )
    new_start = (
        "      payload = data[header_offset + FRAME_HEADER_SIZE, payload_size.to_i]\n"
        "      diagnostic_decode_started = Time.instant\n"
        "      output = case method\n"
        "               when METHOD_LZ4\n"
        "                 if exact_destination = destination\n"
    )
    old_end = (
        '      raise CorruptPartError.new("compressed frame output size mismatch") unless output.size.to_i64 == decompressed_size\n'
        "      Frame.new(frame_end, output)\n"
    )
    new_end = (
        '      raise CorruptPartError.new("compressed frame output size mismatch") unless output.size.to_i64 == decompressed_size\n'
        "      CompactJSONScanProbeCounters.record_decompression!(\n"
        "        method, payload_size, decompressed_size,\n"
        "        (Time.instant - diagnostic_decode_started).total_nanoseconds.to_u64,\n"
        "      )\n"
        "      Frame.new(frame_end, output)\n"
    )
    if source.count(old_start) != 1 or source.count(old_end) != 1:
        raise RuntimeError(f"{path}: expected one exact frame decode hook site")

    # The legacy general-purpose probe asserts that its full diagnostics suite
    # was installed. A targeted central counter intentionally does not install
    # that suite, so suppress only that diagnostic-only assertion in the copy.
    probe = root / "benchmarks" / "compact_json_scan_probe.cr"
    probe_source = probe.read_text() if probe.exists() else None
    legacy_assertion = (
        "        {% if flag?(:compact_json_scan_diagnostic) %}\n"
        "          unless CrystalClick::CompactJSONScanProbeCounters.coordinator_value(:full_window_prepare_passes) > 0_u64\n"
        '            error("no root JSON preparation recorded; apply the diagnostic hooks to the isolated source copy")\n'
        "          end\n"
        "        {% end %}\n"
    )
    if probe_source and legacy_assertion in probe_source:
        probe_source = probe_source.replace(legacy_assertion, "", 1)

    path.write_text(source.replace(old_start, new_start, 1).replace(old_end, new_end, 1))
    if probe_source is not None:
        probe.write_text(probe_source)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_copy", type=Path)
    parser.add_argument("--lz4-only", action="store_true",
                        help="install only the central complete-frame decompression counter")
    arguments = parser.parse_args()
    if arguments.lz4_only:
        install_lz4_only(arguments.source_copy)
    else:
        install(arguments.source_copy)
