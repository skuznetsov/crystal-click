#!/usr/bin/env python3
"""Install disposable Boehm pause and mark-window telemetry in a source copy."""

import argparse
from pathlib import Path


FFI = '''# GCBOEHM_TRACE_V1
lib CompactJSONGCProbe
  fun install = gcprobe_install
  fun register_current_thread = gcprobe_register_current_thread(slot : UInt32)
  fun signpost_begin = gcprobe_signpost_begin(phase : UInt32, run_id : UInt64, worker_slot : UInt32, mark_index : UInt32) : UInt64
  fun signpost_end = gcprobe_signpost_end(phase : UInt32, signpost_id : UInt64, run_id : UInt64, worker_slot : UInt32, mark_index : UInt32)
  fun dump_events = gcprobe_dump_events
end

'''


def instrument(root: Path) -> Path:
    root = root.resolve(strict=True)
    repository = Path(__file__).resolve().parents[1]
    if root == repository:
        raise RuntimeError("refusing to instrument the repository in place; pass an isolated source copy")

    path = root / "benchmarks" / "compact_json_filter_scan_probe.cr"
    if not path.is_file() or not (root / "src" / "crystal_click").is_dir():
        raise RuntimeError("--root must contain benchmarks/compact_json_filter_scan_probe.cr and src/crystal_click")
    source = path.read_text()
    if "GCBOEHM_TRACE_V1" in source:
        return path

    def replace_once(old: str, new: str) -> None:
        nonlocal source
        count = source.count(old)
        if count != 1:
            raise RuntimeError(f"{path}: expected one hook site, found {count}: {old[:100]!r}")
        source = source.replace(old, new, 1)

    replace_once('require "json"\n', 'require "json"\n\n' + FFI)
    replace_once(
        '    offsets = mark_offsets(owner)\n'
        '    jobs, results, errors, contexts, worker_thread_ids = start_workers(owner, workers)\n',
        '    offsets = mark_offsets(owner)\n'
        '    CompactJSONGCProbe.install\n'
        '    CompactJSONGCProbe.register_current_thread(UInt32::MAX)\n'
        '    jobs, results, errors, contexts, worker_thread_ids = start_workers(owner, workers)\n',
    )
    replace_once(
        '      contexts << Fiber::ExecutionContext::Isolated.new("compact-json-filter-worker-#{worker_index}") do\n'
        '        ready.send({worker: worker_index, thread_id: Thread.current.object_id.to_u64})\n',
        '      contexts << Fiber::ExecutionContext::Isolated.new("compact-json-filter-worker-#{worker_index}") do\n'
        '        CompactJSONGCProbe.register_current_thread(worker_index.to_u32)\n'
        '        ready.send({worker: worker_index, thread_id: Thread.current.object_id.to_u64})\n',
    )
    replace_once(
        '    combined_started = Time.instant\n'
        '    read_started = combined_started\n',
        '    combined_started = Time.instant\n'
        '    read_started = combined_started\n'
        '    read_signpost = CompactJSONGCProbe.signpost_begin(1_u32, scan_id.to_u64, UInt32::MAX, UInt32::MAX)\n',
    )
    replace_once(
        '    read_wall_ns = (Time.instant - read_started).total_nanoseconds.to_i64\n'
        '    gc_bytes_after_read = GC.stats.total_bytes\n',
        '    read_wall_ns = (Time.instant - read_started).total_nanoseconds.to_i64\n'
        '    CompactJSONGCProbe.signpost_end(1_u32, read_signpost, scan_id.to_u64, UInt32::MAX, UInt32::MAX)\n'
        '    gc_bytes_after_read = GC.stats.total_bytes\n',
    )

    for matching_rows in (True, False):
        if matching_rows:
            old = (
                '                owner.scan_compact_json_columnar_mark_into(\n'
                '                  mark,\n'
                '                  job.plan,\n'
                '                  budget,\n'
                '                  batch,\n'
                '                  part_row_offset: part_row_offset,\n'
                '                  matching_rows: matching_rows,\n'
                '                )\n'
            )
            call = "\n".join("  " + line for line in old.rstrip().splitlines())
        else:
            old = (
                '                owner.scan_compact_json_columnar_mark_into(\n'
                '                  mark,\n'
                '                  job.plan,\n'
                '                  budget,\n'
                '                  batch,\n'
                '                  part_row_offset: part_row_offset,\n'
                '                )\n'
            )
            call = "\n".join("  " + line for line in old.rstrip().splitlines())

        prefix = (
            '                mark_signpost = CompactJSONGCProbe.signpost_begin(2_u32, job.scan_id.to_u64, '
            'worker_index.to_u32, mark.to_u32)\n'
            '                begin\n'
        )
        suffix = (
            '\n                ensure\n'
            '                  CompactJSONGCProbe.signpost_end(2_u32, mark_signpost, job.scan_id.to_u64, '
            'worker_index.to_u32, mark.to_u32)\n'
            '                end\n'
        )
        replace_once(old, prefix + call + suffix)

    replace_once(
        'CompactJsonFilterScanProbe.main\n',
        'begin\n'
        '  CompactJsonFilterScanProbe.main\n'
        'ensure\n'
        '  CompactJSONGCProbe.dump_events\n'
        'end\n',
    )
    path.write_text(source)
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True, help="isolated source copy root")
    options = parser.parse_args()
    print(instrument(options.root))


if __name__ == "__main__":
    main()
