#!/usr/bin/env python3
"""Compare retained Compact JSON readers on identical parts and mark schedules."""

import argparse
import itertools
import json
import math
import os
import shutil
import statistics
import subprocess
import tempfile
from contextlib import ExitStack, contextmanager
from pathlib import Path

from compact_json_scan_fixture import ROWS_PER_MARK, ROWS_PER_PART
from parallel_scan_benchmark import sha256_path
from read_rows_benchmark import Runner


NATIVE_ALLOCATION_FIELDS = ("native_read_allocation_requests", "native_read_requested_bytes")


@contextmanager
def open_reader(label: str, command: list[str], root: Path):
    log_path = root / f"{label}.log"
    with log_path.open("wb") as log, subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
        cwd=root, env={**os.environ, "TMPDIR": str(root)}, bufsize=0,
    ) as process:
        reader = Runner(process, label, log_path, 120)
        try:
            reader.check(reader.line() == b"READY", "did not admit the part")
            yield reader
        finally:
            if process.poll() is None:
                process.kill()


def part_hashes(part: Path) -> dict[str, str]:
    return {file.name: sha256_path(file) for file in sorted(part.iterdir()) if file.is_file()}


def compare(options: argparse.Namespace) -> dict:
    part = options.part.resolve(strict=True)
    oracle = options.oracle.resolve(strict=True)
    crystal_bin = options.crystal_bin.resolve(strict=True)
    crystal_readers = {"crystal": (crystal_bin, options.crystal_backend)}
    if options.baseline_crystal_bin:
        crystal_readers["crystal_baseline"] = (
            options.baseline_crystal_bin.resolve(strict=True), options.baseline_crystal_backend,
        )
    cpp_bin = options.cpp_bin.resolve(strict=True)
    engines = [*crystal_readers, "clickhouse"]
    orders = list(itertools.permutations(engines))
    expected = oracle.read_bytes()
    oracle_hash = sha256_path(oracle)
    original_hashes = part_hashes(part)
    if not {"data.bin", "data.mrk4", "columns.txt", "serialization.json"} <= original_hashes.keys():
        raise ValueError("expected the plain MRK4 part from compact_json_scan_fixture.py")
    samples = []
    with tempfile.TemporaryDirectory(prefix="compact-json-read-rows-", dir=options.scratch) as directory:
        root = Path(directory).resolve()
        # ATTACH may detach an invalid part. Only give the native runner a
        # disposable copy, including for the checksum mutation controls.
        table_id = "1c622091-4108-4184-a53d-204b0b2cb229"
        table = root / "native" / "store" / table_id[:3] / table_id
        table.mkdir(parents=True)
        native_part = table / part.name
        shutil.copytree(part, native_part)
        if part_hashes(native_part) != original_hashes:
            raise RuntimeError("native part copy differs from the original")

        def reader(engine: str, workers: int, trial: Path, selection: Path):
            if engine in crystal_readers:
                binary, backend = crystal_readers[engine]
                return open_reader(engine, [str(binary), backend, str(selection), str(oracle),
                                            str(workers), "all", "retained", "0", "1", "--stdin"], trial)
            work = trial / "cpp-work"
            work.mkdir()
            command = [str(cpp_bin), "--schema", "json", "--part", str(selection),
                       "--layout", "compact", "--marks", "0,1,2,3", "--mark-rows",
                       str(ROWS_PER_MARK), "--workers", str(workers), "--oracle", str(oracle),
                       "--work-dir", str(work)]
            if options.native_read_allocations:
                command.extend(("--native-read-allocations", "1"))
            return open_reader(engine, command, trial)

        for engine in engines:
            trial = root / f"{engine}-checksum-control"
            trial.mkdir()
            # Use the same store layout for both gates, and restore before
            # any subsequent reader opens the file.
            with reader(engine, 1, trial, native_part) as process:
                with (native_part / "data.bin").open("r+b", buffering=0) as data:
                    original = data.read(1)
                    if len(original) != 1:
                        raise RuntimeError("missing first frame checksum byte")
                    data.seek(0)
                    data.write(bytes([original[0] ^ 1]))
                    try:
                        process.process.stdin.write(b"scan\n")
                        process.check(process.line() is None, "scan returned rows for a corrupted frame")
                        status = process.process.wait(timeout=process.timeout)
                        process.check(status != 0 and b"checksum mismatch" in process.log_path.read_bytes().lower(),
                                      "scan did not report a checksum mismatch")
                    finally:
                        data.seek(0)
                        data.write(original)

        for workers in (1, 4):
            expected_groups = [[0, 1, 2, 3]] if workers == 1 else [[0], [1], [2], [3]]
            for block in range(options.blocks):
                trial = root / f"w{workers}-block{block}"
                trial.mkdir()
                with ExitStack() as stack:
                    processes = {
                        engine: stack.enter_context(reader(
                            engine, workers, trial, part if engine in crystal_readers else native_part,
                        ))
                        for engine in engines
                    }
                    thread_ids = {}
                    for index in range(options.warmups + options.repeats):
                        order = orders[(block + index) % len(orders)]
                        for engine in order:
                            process = processes[engine]
                            process.process.stdin.write(b"scan\n")
                            response = process.line()
                            process.check(response is not None, "exited before reporting the scan")
                            sample = json.loads(response)
                            process.check(sample["rows"] == ROWS_PER_PART and sample["rowbinary_bytes"] == len(expected),
                                          "wrong RowBinary size or row count")
                            if engine in crystal_readers:
                                actual_threads = tuple(row["thread_id"] for row in sample["worker_rows"])
                                process.check(sample["workers_active"] == workers and
                                              [row["marks"] for row in sample["worker_rows"]] == expected_groups,
                                              "different Crystal mark schedule")
                                process.check(sample["oracle_exact"] is True and sample["rowbinary_sha256"] == oracle_hash,
                                              "Crystal RowBinary differs from the oracle")
                                if crystal_readers[engine][1] in ("shared", "columnar"):
                                    process.check(sample["shared_part_plan_ns"] > 0 and
                                                  sample["shared_part_plan_marks"] == ROWS_PER_PART // ROWS_PER_MARK,
                                                  "a complete shared part plan is required in the timed read")
                            else:
                                actual_threads = tuple(sample["worker_thread_ids"])
                                process.check(sample["effective_workers"] == workers and sample["worker_marks"] == expected_groups,
                                              "different ClickHouse mark schedule")
                                process.check(sample["checksum_on_read_policy"] == "enabled", "checksumming is required")
                                if options.native_read_allocations:
                                    process.check(all(type(sample.get(field)) is int and sample[field] >= 0
                                                      for field in NATIVE_ALLOCATION_FIELDS),
                                                  "native read allocation counters are unavailable")
                                if index == 0:
                                    process.check((trial / "cpp-work" / "rowbinary.bin").read_bytes() == expected,
                                                  "ClickHouse RowBinary differs from the oracle")
                            process.check(actual_threads == thread_ids.setdefault(process.label, actual_threads)
                                          and len(set(actual_threads)) == workers,
                                          "did not retain the expected worker threads")
                            if index >= options.warmups:
                                samples.append({"engine": process.label, "workers": workers, "block": block,
                                                "pair": index - options.warmups, **sample})
                    for process in processes.values():
                        process.quit()
        if part_hashes(native_part) != original_hashes or part_hashes(part) != original_hashes:
            raise RuntimeError("part files changed during the comparison")

    def percentiles(values: list[int]) -> dict:
        ordered = sorted(values)
        return {"p50": statistics.median(ordered), "p95": ordered[math.ceil(len(ordered) * 0.95) - 1]}

    summary = []
    for engine in engines:
        for workers in (1, 4):
            selected = [sample for sample in samples if sample["engine"] == engine and sample["workers"] == workers]
            first_in_block = [sample for sample in selected if sample["pair"] == 0]
            if engine in crystal_readers:
                stats = {field: percentiles([sample[field] for sample in selected]) for field in (
                    "read_wall_ns", "coordinator_serialization_ns", "scan_and_serialize_ns",
                    "gc_allocated_bytes_delta", "gc_collections",
                )}
                stats["prepare_wall_ns"] = percentiles([sample["prepare_wall_ns"] for sample in first_in_block])
                for field in ("gc_read_allocated_bytes_delta", "gc_read_collections", "output_reset_ns"):
                    if all(field in sample for sample in selected):
                        stats[field] = percentiles([sample[field] for sample in selected])
                if crystal_readers[engine][1] in ("shared", "columnar"):
                    stats["shared_part_plan_ns"] = percentiles([sample["shared_part_plan_ns"] for sample in selected])
            else:
                stats = {field: percentiles([sample[field] for sample in selected]) for field in (
                    "read_ns", "materialize_ns", "reset_ns",
                )}
                stats["read_and_materialize_ns"] = percentiles([sample["read_ns"] + sample["materialize_ns"] for sample in selected])
                for field in ("load_part_ns", "prepare_ns"):
                    stats[field] = percentiles([sample[field] for sample in first_in_block])
                if options.native_read_allocations:
                    for field in NATIVE_ALLOCATION_FIELDS:
                        stats[field] = percentiles([sample[field] for sample in selected])
            summary.append({"engine": engine, "workers": workers, "sample_count": len(selected), **stats})
    report = {"part_hashes": original_hashes, "oracle_sha256": oracle_hash,
              "crystal_binary_sha256": sha256_path(crystal_bin), "clickhouse_binary_sha256": sha256_path(cpp_bin),
              "crystal_backends": {engine: backend for engine, (_, backend) in crystal_readers.items()},
              "blocks": options.blocks, "warmups_per_block": options.warmups, "repeats_per_block": options.repeats,
              "native_read_allocations": options.native_read_allocations,
              "checksum_controls_passed": True, "summary": summary, "samples": samples}
    if options.baseline_crystal_bin:
        report["crystal_baseline_binary_sha256"] = sha256_path(crystal_readers["crystal_baseline"][0])
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("part", "oracle", "crystal-bin", "cpp-bin", "scratch", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--baseline-crystal-bin", type=Path)
    parser.add_argument("--crystal-backend", choices=("typed", "shared", "columnar"), default="typed")
    parser.add_argument("--baseline-crystal-backend", choices=("typed", "shared"), default="typed")
    parser.add_argument("--native-read-allocations", action="store_true",
                        help="sample macOS system allocator requests in a separate diagnostic run")
    parser.add_argument("--blocks", type=int, default=8)
    parser.add_argument("--warmups", type=int, default=2)
    parser.add_argument("--repeats", type=int, default=6)
    arguments = parser.parse_args()
    if arguments.blocks < 1 or arguments.warmups < 0 or arguments.repeats < 1:
        parser.error("blocks and repeats must be positive, and warmups must be nonnegative")
    report = compare(arguments)
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["summary"], indent=2))
