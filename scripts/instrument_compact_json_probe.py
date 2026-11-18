#!/usr/bin/env python3
"""Install single-worker diagnostics in a disposable CrystalClick source copy."""

import argparse
from pathlib import Path


def install(root: Path) -> None:
    sources: dict[Path, str] = {}

    def replace_once(filename: str, old: str, new: str) -> None:
        path = root / "src" / "crystal_click" / filename
        source = sources[path] if path in sources else path.read_text()
        count = source.count(old)
        if new in source:
            return
        if count != 1:
            raise RuntimeError(f"{path}: expected one hook site, found {count}")
        sources[path] = source.replace(old, new, 1)

    replace_once(
        "compact_static_json_bulk_column_reader.cr",
        "    ) : Array(CompactStaticJsonAdvancedPreparedMark)?\n      base_workspace = retained_workspace_bytes",
        "    ) : Array(CompactStaticJsonAdvancedPreparedMark)?\n"
        "      diagnostic_prepare_started = Time.instant\n      base_workspace = retained_workspace_bytes",
    )
    replace_once(
        "compact_static_json_bulk_column_reader.cr",
        "      is_advanced ? advanced_marks : nil\n    end",
        "      is_advanced ? advanced_marks : nil\n"
        "    ensure\n"
        "      if started = diagnostic_prepare_started\n"
        "        CrystalClick::CompactJSONScanProbeCounters.record_full_window_prepare!(\n"
        "          (Time.instant - started).total_nanoseconds.to_u64,\n"
        "        )\n"
        "      end\n    end",
    )
    window_guard = (
        "      if first_mark > Int32::MAX || mark_count > Int32::MAX\n"
        "        raise ArgumentError.new(\"Compact mark selection exceeds supported in-memory domain\")\n"
        "      end\n\n"
    )
    replace_once(
        "compact_part_physical_context.cr",
        window_guard + "      slot_count = @columns_substreams.slot_count_for(column_name)\n",
        window_guard +
        "      CrystalClick::CompactJSONScanProbeCounters.record_read_window!(first_mark, mark_count, @mark_index.mark_count)\n"
        "      slot_count = @columns_substreams.slot_count_for(column_name)\n",
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
        "compressed_mark_reader.cr",
        "      actual = CityHashV1.hash128(data[offset + CompressedBlock::CHECKSUM_SIZE, frame.compressed_size.to_i])\n",
        "      diagnostic_checksum_started = Time.instant\n"
        "      actual = CityHashV1.hash128(data[offset + CompressedBlock::CHECKSUM_SIZE, frame.compressed_size.to_i])\n"
        "      diagnostic_checksum_ns = (Time.instant - diagnostic_checksum_started).total_nanoseconds.to_u64\n",
    )
    replace_once(
        "compressed_mark_reader.cr",
        "        raise CorruptPartError.new(\"compressed frame checksum mismatch\")\n      end\n    end\n",
        "        raise CorruptPartError.new(\"compressed frame checksum mismatch\")\n      end\n"
        "      CrystalClick::CompactJSONScanProbeCounters.record_checked_frame!(\n"
        "        frame.compressed_offset, frame.compressed_size, diagnostic_checksum_ns,\n"
        "      )\n"
        "    end\n",
    )
    buffered_decode = "      output = case method\n               when METHOD_LZ4\n                 if exact_destination = destination\n"
    replace_once(
        "compressed_block.cr",
        buffered_decode,
        "      diagnostic_decode_started = Time.instant\n" + buffered_decode,
    )
    replace_once(
        "compressed_block.cr",
        "      raise CorruptPartError.new(\"compressed frame output size mismatch\") unless output.size.to_i64 == decompressed_size\n"
        "      Frame.new(frame_end, output)",
        "      raise CorruptPartError.new(\"compressed frame output size mismatch\") unless output.size.to_i64 == decompressed_size\n"
        "      CrystalClick::CompactJSONScanProbeCounters.record_decompression!(\n"
        "        method, payload_size, decompressed_size, (Time.instant - diagnostic_decode_started).total_nanoseconds.to_u64,\n"
        "      )\n"
        "      Frame.new(frame_end, output)",
    )
    for path, source in sources.items():
        path.write_text(source)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_copy", type=Path)
    install(parser.parse_args().source_copy)
