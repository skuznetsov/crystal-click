#!/usr/bin/env python3
"""Compare direct readers against an existing parallel scan fixture manifest."""

import argparse
import array
import hashlib
import itertools
import json
import math
import os
import select
import shutil
import statistics
import struct
import subprocess
import sys
import tempfile
import time
from contextlib import ExitStack, contextmanager
from pathlib import Path

from parallel_scan_benchmark import fail, sha256_path, validate_fixture_source


class Runner:
    def __init__(self, process: subprocess.Popen, label: str, log_path: Path, timeout: float):
        self.process = process
        self.label = label
        self.log_path = log_path
        self.timeout = timeout
        self.buffer = bytearray()

    def line(self) -> bytes | None:
        deadline = time.monotonic() + self.timeout
        while b"\n" not in self.buffer:
            remaining = max(deadline - time.monotonic(), 0)
            if not select.select([self.process.stdout], [], [], remaining)[0]:
                fail(f"{self.label} timed out waiting for output")
            chunk = os.read(self.process.stdout.fileno(), 64 * 1024)
            if not chunk:
                if self.buffer:
                    fail(f"{self.label} emitted a partial protocol line")
                return None
            self.buffer.extend(chunk)
            if len(self.buffer) > 1024 * 1024:
                fail(f"{self.label} emitted an oversized protocol line")
        line, _, remaining = self.buffer.partition(b"\n")
        self.buffer = remaining
        return bytes(line)

    def check(self, condition: bool, message: str) -> None:
        if not condition:
            with self.log_path.open("rb") as log:
                log.seek(max(self.log_path.stat().st_size - 4096, 0))
                tail = log.read().decode(errors="replace").strip()
            fail(f"{self.label}: {message}" + (f"\n{tail}" if tail else ""))

    def scan(self, worker_marks: list[list[int]], mark_rows: int) -> tuple[int, int]:
        self.process.stdin.write(b"scan\n")
        response = self.line()
        self.check(response is not None, "exited before reporting the scan")
        sample = json.loads(response)
        self.check(sample["effective_workers"] == len(worker_marks), "unexpected worker count")
        self.check(sample["worker_marks"] == worker_marks, "observed worker marks differ from the schedule")
        rows = sum(len(marks) for marks in worker_marks) * mark_rows
        self.check(sample["rows"] == rows, "unexpected row count")
        self.check(sample["checksum_on_read"] is True, "data checksum verification is required")
        elapsed = sample["elapsed_ns"]
        preparation = sample["prepare_ns"]
        self.check(type(elapsed) is int and elapsed > 0, "invalid scan duration")
        self.check(type(preparation) is int and preparation >= 0, "invalid preparation duration")
        return elapsed, preparation

    def expect_corruption(self) -> None:
        self.process.stdin.write(b"scan\n")
        self.check(self.line() is None, "corrupt part completed a scan")
        status = self.process.wait(timeout=self.timeout)
        diagnostic = self.log_path.read_bytes().lower()
        self.check(status == 3 and b"checksum mismatch" in diagnostic,
                   "corrupt part did not report a data checksum mismatch")

    def quit(self) -> None:
        self.process.stdin.write(b"quit\n")
        self.check(self.line() is None, "unexpected output after quit")
        self.check(self.process.wait(timeout=self.timeout) == 0, "runner failed to exit")


@contextmanager
def open_runner(binary: Path, root: Path, part: Path, layout: str, marks: list[int],
                mark_rows: int, workers: int, oracle: Path, timeout: float):
    root.mkdir()
    log_path = root / "stderr.log"
    work_dir = root / "work"
    work_dir.mkdir()
    command = [str(binary), "--part", str(part), "--layout", layout,
               "--marks", ",".join(map(str, marks)), "--mark-rows", str(mark_rows),
               "--workers", str(workers), "--oracle", str(oracle), "--work-dir", str(work_dir)]
    environment = os.environ.copy()
    environment["TMPDIR"] = str(work_dir)
    with log_path.open("wb") as log, subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
        env=environment, cwd=work_dir, bufsize=0,
    ) as process:
        runner = Runner(process, root.name, log_path, timeout)
        try:
            runner.check(runner.line() == b"READY", "runner did not admit the part")
            yield runner
        finally:
            if process.poll() is None:
                process.kill()


def part_manifest_sha256(part: Path) -> str:
    files = []
    for path in sorted(part.rglob("*")):
        if path.is_symlink():
            fail(f"part contains a symbolic link: {path.name}")
        if path.is_file():
            files.append({"path": str(path.relative_to(part)), "bytes": path.stat().st_size,
                          "sha256": sha256_path(path)})
    listing = json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(listing).hexdigest()


def make_oracle(source_path: Path, oracle_path: Path, marks: list[int], mark_rows: int) -> None:
    keys, values = array.array("Q"), array.array("Q")
    mark_bytes = mark_rows * 16
    with source_path.open("rb") as source:
        for mark in marks:
            source.seek(mark * mark_bytes)
            rows = source.read(mark_bytes)
            if len(rows) != mark_bytes:
                fail("selected mark escapes the RowBinary fixture")
            for key, value in struct.iter_unpack("<QQ", rows):
                keys.append(key)
                values.append(value)
    if sys.byteorder == "big":
        keys.byteswap()
        values.byteswap()
    with oracle_path.open("wb") as oracle:
        keys.tofile(oracle)
        values.tofile(oracle)


def corrupt_first_frame(part: Path, scratch: Path) -> Path:
    if len(part.parents) < 4 or part.parents[2].name != "store":
        fail("expected a native store/<prefix>/<uuid>/<part> directory")
    copy = scratch / part.relative_to(part.parents[3])
    shutil.copytree(part, copy)
    streams = sorted(copy.glob("*.bin"))
    if not streams:
        fail("checksum control found no compressed data streams")
    with streams[0].open("r+b") as output:
        header = output.read(25)
        if len(header) != 25 or header[16] != 0x82:
            fail("checksum control requires an LZ4 stream at offset zero")
        output.seek(0)
        output.write(bytes([header[0] ^ 1]))
    return copy


def run_track(binaries: dict[str, Path], root: Path, part: Path, layout: str,
              marks: list[int], mark_rows: int, workers: int, oracle: Path,
              warmups: int, repeats: int, timeout: float) -> dict:
    root.mkdir()
    split = [marks[len(marks) * i // workers:len(marks) * (i + 1) // workers] for i in range(workers)]
    samples = {name: [] for name in binaries}
    preparations = {name: [] for name in binaries}
    warmup_orders = []
    orders = []
    with ExitStack() as stack:
        runners = {
            name: stack.enter_context(
                open_runner(binary, root / name, part, layout, marks,
                            mark_rows, workers, oracle, timeout)
            )
            for name, binary in binaries.items()
        }
        schedule = tuple(itertools.permutations(runners))
        for index in range(warmups + repeats):
            order = list(schedule[index % len(schedule)])
            if index >= warmups:
                orders.append(order)
            else:
                warmup_orders.append(order)
            for name in order:
                elapsed, preparation = runners[name].scan(split, mark_rows)
                if index >= warmups:
                    samples[name].append(elapsed)
                    preparations[name].append(preparation)
        for runner in runners.values():
            runner.quit()

    rows = len(marks) * mark_rows
    engines = {}
    for name, elapsed in samples.items():
        median = statistics.median(elapsed)
        preparation = preparations[name]
        preparation_and_scan_samples = [prep + scan for prep, scan in zip(preparation, elapsed)]
        engines[name] = {
            "samples_ns": elapsed,
            "p50_ns": median,
            "p95_ns": sorted(elapsed)[math.ceil(len(elapsed) * 0.95) - 1],
            "prepare_samples_ns": preparation,
            "prepare_p50_ns": statistics.median(preparation),
            "prepare_and_scan_samples_ns": preparation_and_scan_samples,
            "prepare_and_scan_p50_ns": statistics.median(preparation_and_scan_samples),
            "prepare_and_scan_p95_ns": sorted(preparation_and_scan_samples)[
                math.ceil(len(preparation_and_scan_samples) * 0.95) - 1
            ],
            "rows_per_second": rows * 1e9 / median,
            "decoded_gib_per_second": rows * 16 * 1e9 / (median * 2**30),
        }

    result = {
        "layout": layout, "workers": workers, "worker_marks": split,
        "rows": rows, "decoded_bytes": rows * 16, "orders": orders,
        "warmup_orders": warmup_orders,
        "checksum_on_read": True, "engines": engines,
    }
    paired = zip(samples["crystal"], samples["clickhouse"])
    result["paired_clickhouse_to_crystal_time_ratio_p50"] = statistics.median(
        clickhouse / crystal for crystal, clickhouse in paired
    )
    if "crystal_baseline" in samples:
        baseline_to_candidate = zip(samples["crystal"], samples["crystal_baseline"])
        clickhouse_to_baseline = zip(samples["crystal_baseline"], samples["clickhouse"])
        result["paired_crystal_baseline_to_crystal_time_ratio_p50"] = statistics.median(
            baseline / candidate for candidate, baseline in baseline_to_candidate
        )
        result["paired_clickhouse_to_crystal_baseline_time_ratio_p50"] = statistics.median(
            clickhouse / baseline for baseline, clickhouse in clickhouse_to_baseline
        )
    return result


def compare(args: argparse.Namespace) -> dict:
    manifest_path = args.manifest.resolve(strict=True)
    manifest = json.loads(manifest_path.read_bytes())
    fixture = manifest["fixture"]
    mark_rows = fixture["mark_rows"]
    if fixture["row_bytes"] != 16 or mark_rows <= 0 or fixture["rows"] % mark_rows:
        fail("expected a pair of UInt64 columns and uniform complete marks")
    mark_count = fixture["rows"] // mark_rows
    marks = args.marks if args.marks is not None else list(range(mark_count))
    if marks != sorted(set(marks)) or len(marks) < max(args.workers) or marks[0] < 0 or marks[-1] >= mark_count:
        fail("marks must be distinct, increasing, in range, and sufficient for each worker")
    source_path = manifest_path.parent / "fixture.rowbinary"
    validate_fixture_source(source_path, fixture)
    binaries = {"crystal": args.crystal_bin.resolve(strict=True)}
    if args.crystal_baseline_bin is not None:
        binaries["crystal_baseline"] = args.crystal_baseline_bin.resolve(strict=True)
    binaries["clickhouse"] = args.cpp_bin.resolve(strict=True)
    binary_hashes = {name: sha256_path(path) for name, path in binaries.items()}
    tracks = []
    part_hashes = {}
    with tempfile.TemporaryDirectory(prefix="read-rows-", dir=args.scratch.resolve(strict=True)) as directory:
        scratch = Path(directory)
        oracle = scratch / "oracle.bin"
        make_oracle(source_path, oracle, marks, mark_rows)
        oracle_hash = sha256_path(oracle)
        control_marks = list(range(max(args.workers)))
        control_oracle = scratch / "control-oracle.bin"
        make_oracle(source_path, control_oracle, control_marks, mark_rows)
        for layout in args.layout:
            entry = manifest["layouts"][layout]["part"]
            part = Path(entry["path"]).resolve(strict=True)
            expected = entry["file_manifest_sha256"]
            if entry["physical_mark_geometry"]["rows_per_positive_mark"] != [mark_rows] * mark_count:
                fail(f"{layout} mark geometry differs from the fixture")
            if part_manifest_sha256(part) != expected:
                fail(f"{layout} part files differ from the fixture manifest")
            for workers in args.workers:
                for name, binary in binaries.items():
                    control_root = scratch / f"{layout}-{workers}-{name}-checksum-control"
                    corrupt = corrupt_first_frame(part, control_root.with_name(control_root.name + "-part"))
                    with open_runner(binary, control_root, corrupt, layout, control_marks,
                                     mark_rows, workers, control_oracle, args.timeout) as runner:
                        runner.expect_corruption()
                track = run_track(binaries, scratch / f"{layout}-{workers}", part, layout, marks, mark_rows,
                                  workers, oracle, args.warmups, args.repeats, args.timeout)
                tracks.append(track)
            if part_manifest_sha256(part) != expected:
                fail(f"{layout} part files changed during the comparison")
            part_hashes[layout] = expected

    return {
        "marks": marks, "mark_rows": mark_rows, "warmups": args.warmups, "repeats": args.repeats,
        "arms": list(binaries),
        "binary_sha256": binary_hashes, "part_file_manifest_sha256": part_hashes,
        "fixture_manifest_sha256": sha256_path(manifest_path), "expected_columns_sha256": oracle_hash,
        "checksum_corruption_controls_passed": True, "tracks": tracks,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--crystal-bin", type=Path, required=True)
    parser.add_argument("--crystal-baseline-bin", type=Path,
                        help="optional prior Crystal runner for a balanced three-arm campaign")
    parser.add_argument("--cpp-bin", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--layout", choices=("wide", "compact"), action="append")
    parser.add_argument("--workers", type=int, choices=(1, 4), action="append")
    parser.add_argument("--marks", type=lambda value: list(map(int, value.split(","))))
    parser.add_argument("--warmups", type=int, default=4)
    parser.add_argument("--repeats", type=int, default=24)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.layout = list(dict.fromkeys(args.layout or ["wide", "compact"]))
    args.workers = list(dict.fromkeys(args.workers or [1, 4]))
    if args.warmups < 1 or args.repeats < 1 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("warmups, repeats, and timeout must be positive")
    args.output.write_text(json.dumps(compare(args), indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
