#!/usr/bin/env python3
"""Compare direct readers and optionally profile their Wide scans."""

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


PROFILE_TRANSPORTS = {"crystal_profile": "mmap", "clickhouse_profile": "pread"}
PROFILE_STAGES = ("transport_ns", "io_lifecycle_ns", "checksum_ns", "lz4_ns",
                  "materialize_copy_ns", "output_copy_ns")
SHARED_MMAP_FIELDS = ("open_ns", "close_ns", "map_calls", "unmap_calls", "mapped_bytes")
RETAINED_MMAP_FIELDS = ("map_calls", "mapped_bytes")
PROCESS_TIMING_FIELDS = ("admission_ns", "mmap_prepare_ns")


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

    def scan(self, worker_marks: list[list[int]], mark_rows: int) -> dict:
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
        return sample

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


def observe_process_timing(runner: Runner, engine: str, sample: dict, field: str,
                           values: dict[str, int | None]) -> int | None:
    present = field in sample
    value = sample[field] if present else None
    if present:
        runner.check(type(value) is int and value >= 0, f"invalid one-time {field} duration")
    if engine in values:
        runner.check(values[engine] == value,
                     f"{field} presence or value changed within the runner process")
    else:
        values[engine] = value
    return value


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


def wide_lz4_geometry(part: Path, mark_count: int, mark_rows: int) -> tuple[list[int], int]:
    """Count frames and data bytes independently of either reader."""
    mark_files = sorted(part.glob("*.mrk2"))
    if len(mark_files) != 2:
        fail("profile requires two Wide MRK2 column streams")
    counts = [0] * mark_count
    mapped_bytes = 0
    for mark_file in mark_files:
        column = mark_file.stem
        mark_bytes = mark_file.read_bytes()
        data = mark_file.with_suffix(".bin").read_bytes()
        mapped_bytes += len(data)
        if len(mark_bytes) != (mark_count + 1) * 24:
            fail(f"{column}: profile requires a complete Wide MRK2 stream")
        marks = list(struct.iter_unpack("<QQQ", mark_bytes))
        if marks[-1] != (len(data), 0, 0) or marks[0][0] != 0:
            fail(f"{column}: profile requires a complete Wide MRK2 stream")
        for index, (offset, in_frame_offset, rows) in enumerate(marks[:-1]):
            end = marks[index + 1][0]
            if in_frame_offset or rows != mark_rows or not offset < end <= len(data):
                fail(f"{column}: profile requires positive frame-aligned marks")
            decoded = 0
            while offset < end:
                if end - offset < 25 or data[offset + 16] != 0x82:
                    fail(f"{column}: profile requires complete LZ4 frames")
                compressed_size, decoded_size = struct.unpack_from("<II", data, offset + 17)
                if compressed_size < 9 or decoded_size == 0:
                    fail(f"{column}: invalid LZ4 frame size")
                offset += 16 + compressed_size
                decoded += decoded_size
                counts[index] += 1
            if offset != end or decoded != mark_rows * 8:
                fail(f"{column}: frame range does not match mark extent")
    return counts, mapped_bytes


def validate_profile(runner: Runner, sample: dict, engine: str, expected_frames: list[int],
                     worker_marks: list[list[int]], mark_rows: int, expected_mapped_bytes: int,
                     require_retained_mmap: bool = False) -> dict:
    profile = sample.get("profile")
    runner.check(isinstance(profile, dict), "missing Wide stage profile")
    runner.check(profile.get("version") == 1, "unsupported Wide stage profile version")
    runner.check(profile.get("transport_kind") == PROFILE_TRANSPORTS[engine], "wrong transport profile")
    workers = profile.get("workers")
    runner.check(isinstance(workers, list) and len(workers) == len(worker_marks), "wrong profile worker count")
    crystal = engine == "crystal_profile"
    shared_mmap = profile.get("shared_mmap")
    retained_mmap = profile.get("retained_mmap")
    if require_retained_mmap and crystal:
        runner.check(isinstance(retained_mmap, dict), "missing retained Wide mmap profile")
    if retained_mmap is not None:
        runner.check(crystal and isinstance(retained_mmap, dict), "invalid retained Wide mmap profile")
        for field in RETAINED_MMAP_FIELDS:
            value = retained_mmap.get(field)
            runner.check(type(value) is int and value >= 0, f"invalid retained mmap field {field}")
        runner.check(retained_mmap["map_calls"] == 2,
                     "expected two retained mappings, one per selected column")
        runner.check(retained_mmap["mapped_bytes"] == expected_mapped_bytes,
                     "wrong retained mapped byte count")
        runner.check(isinstance(shared_mmap, dict),
                     "retained mmap profile must include zeroed shared_mmap counters")
    if shared_mmap is not None:
        runner.check(crystal and isinstance(shared_mmap, dict), "invalid scan-owned mmap profile")
        for field in SHARED_MMAP_FIELDS:
            value = shared_mmap.get(field)
            runner.check(type(value) is int and value >= 0, f"invalid shared mmap field {field}")
        if retained_mmap is not None:
            runner.check(all(shared_mmap[field] == 0 for field in SHARED_MMAP_FIELDS),
                         "retained mappings must not be counted as scan-owned shared mmap work")
        else:
            runner.check(shared_mmap["map_calls"] == shared_mmap["unmap_calls"] == 2,
                         "expected one mapping and unmapping per selected column")
            runner.check(shared_mmap["mapped_bytes"] == expected_mapped_bytes,
                         "wrong shared mapped byte count")
    stages = PROFILE_STAGES + (("frame_dispatch_ns",) if crystal else ())
    fields = ("start_ns", "end_ns", "checksum_calls", "lz4_calls", "transport_calls",
              "transport_bytes", "materialize_copy_bytes", "output_copy_bytes", *stages)
    if shared_mmap is not None:
        fields += ("mmap_calls", "munmap_calls")
    elif not crystal:
        fields += ("direct_decode_bytes", "direct_decode_calls")
    for index, (worker, frames, marks) in enumerate(zip(workers, expected_frames, worker_marks)):
        runner.check(isinstance(worker, dict) and worker.get("index") == index, "wrong profile worker index")
        for field in fields:
            value = worker.get(field)
            runner.check(type(value) is int and value >= 0, f"invalid profile field {field}")
        start, end = worker["start_ns"], worker["end_ns"]
        runner.check(start < end <= sample["elapsed_ns"], "invalid scan-relative worker interval")
        measured = sum(worker[field] for field in stages)
        runner.check(measured <= end - start, "measured stages exceed worker interval")
        if shared_mmap is None:
            runner.check(worker["transport_calls"] > 0 and worker["transport_bytes"] > 0,
                         "the transport probe did not observe a read")
        else:
            runner.check(worker["transport_calls"] == worker["transport_bytes"] ==
                         worker["mmap_calls"] == worker["munmap_calls"] == 0,
                         "worker mapped or unmapped data in a scan with scan-owned mappings")
        runner.check(worker["checksum_calls"] == worker["lz4_calls"] == frames,
                     "the checksum or LZ4 call count differs from the physical frame count")
        expected_bytes = len(marks) * mark_rows * 16
        materialized_bytes = worker["materialize_copy_bytes"] + worker.get("direct_decode_bytes", 0)
        runner.check(materialized_bytes == expected_bytes, "wrong typed output byte count")
        runner.check(worker["output_copy_bytes"] == expected_bytes, "wrong ordered output copy byte count")
    if shared_mmap is not None:
        outside_workers = sample["elapsed_ns"] - max(w["end_ns"] for w in workers) + min(w["start_ns"] for w in workers)
        runner.check(shared_mmap["open_ns"] + shared_mmap["close_ns"] <= outside_workers,
                     "shared mapping lifetime work exceeds the scan interval outside workers")
    for field in ("launch_ns", "join_ns"):
        value = profile.get(field, 0 if len(worker_marks) == 1 else None)
        runner.check(type(value) is int and 0 <= value <= sample["elapsed_ns"],
                     f"invalid profile field {field}")
    return profile


def summarize_profiles(profiles: list[dict], elapsed: list[int]) -> dict:
    first_worker = profiles[0]["workers"][0]
    stages = PROFILE_STAGES + (("frame_dispatch_ns",) if "frame_dispatch_ns" in first_worker else ())
    counters = ("checksum_calls", "lz4_calls", "materialize_copy_bytes", "output_copy_bytes",
                "transport_calls", "transport_bytes", "direct_decode_calls", "direct_decode_bytes")
    last_worker = {field: [] for field in (*stages, "body_ns", "other_ns")}
    worker_sums = {field: [] for field in last_worker}
    worker_sums.update({field: [] for field in counters if field in first_worker})
    orchestration = {field: [] for field in ("outside_workers_ns", "last_worker_start_delay_ns")}
    for field in ("launch_ns", "join_ns"):
        if field in profiles[0]:
            orchestration[field] = []
    for profile, scan_ns in zip(profiles, elapsed):
        workers = profile["workers"]
        last = max(workers, key=lambda worker: worker["end_ns"])
        first_start = min(worker["start_ns"] for worker in workers)
        # Scan wall time is the time outside this envelope, the last finisher's
        # delay relative to the first start, and the last finisher's body.
        orchestration["outside_workers_ns"].append(scan_ns - last["end_ns"] + first_start)
        orchestration["last_worker_start_delay_ns"].append(last["start_ns"] - first_start)
        for field in ("launch_ns", "join_ns"):
            if field in orchestration:
                orchestration[field].append(profile[field])
        for worker in workers:
            worker["body_ns"] = worker["end_ns"] - worker["start_ns"]
            worker["other_ns"] = worker["body_ns"] - sum(worker[field] for field in stages)
        for field in last_worker:
            last_worker[field].append(last[field])
        for field in worker_sums:
            worker_sums[field].append(sum(worker[field] for worker in workers))
    summary = {
        "transport_kind": profiles[0]["transport_kind"],
        "last_worker_p50": {field: statistics.median(values) for field, values in last_worker.items()},
        "worker_sums_p50": {field: statistics.median(values) for field, values in worker_sums.items()},
        "orchestration_p50_ns": {field: statistics.median(values) for field, values in orchestration.items()},
        "samples": profiles,
    }
    if profiles[0].get("shared_mmap") is not None:
        summary["shared_mmap_p50"] = {
            field: statistics.median(p["shared_mmap"][field] for p in profiles)
            for field in SHARED_MMAP_FIELDS
        }
    if profiles[0].get("retained_mmap") is not None:
        summary["retained_mmap_p50"] = {
            field: statistics.median(p["retained_mmap"][field] for p in profiles)
            for field in RETAINED_MMAP_FIELDS
        }
    return summary


def run_track(binaries: dict[str, Path], root: Path, part: Path, layout: str,
              marks: list[int], mark_rows: int, workers: int, oracle: Path,
              warmups: int, repeats: int, timeout: float,
              frame_geometry: tuple[list[int], int] | None = None,
              require_admission: bool = False,
              require_retained_mmap: bool = False) -> dict:
    root.mkdir()
    split = [marks[len(marks) * i // workers:len(marks) * (i + 1) // workers] for i in range(workers)]
    samples = {name: [] for name in binaries}
    preparations = {name: [] for name in binaries}
    process_timing_values = {field: {} for field in PROCESS_TIMING_FIELDS}
    process_timing_observations = {name: 0 for name in binaries}
    profiles = {name: [] for name in binaries if name in PROFILE_TRANSPORTS}
    expected_frames, expected_mapped_bytes = [], 0
    if frame_geometry is not None:
        frame_counts, expected_mapped_bytes = frame_geometry
        expected_frames = [sum(frame_counts[mark] for mark in selection) for selection in split]
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
                runner = runners[name]
                sample = runner.scan(split, mark_rows)
                timing_values = {
                    field: observe_process_timing(
                        runner, name, sample, field,
                        process_timing_values[field],
                    )
                    for field in PROCESS_TIMING_FIELDS
                }
                process_timing_observations[name] += 1
                if require_admission and name == "crystal":
                    runner.check(timing_values["admission_ns"] is not None,
                                 "Wide Crystal candidate omitted admission_ns")
                    runner.check(sample["prepare_ns"] == 0,
                                 "retained Wide Crystal candidate reported per-scan preparation")
                if require_admission and name == "crystal_baseline":
                    runner.check(timing_values["admission_ns"] is None,
                                 "per-scan Crystal baseline unexpectedly emitted admission_ns")
                    runner.check(sample["prepare_ns"] > 0,
                                 "per-scan Crystal baseline omitted per-scan preparation")
                if require_retained_mmap and name == "crystal":
                    runner.check(timing_values["admission_ns"] is not None,
                                 "retained Wide Crystal candidate omitted admission_ns")
                    runner.check(timing_values["mmap_prepare_ns"] is not None,
                                 "retained Wide Crystal candidate omitted mmap_prepare_ns")
                    runner.check(sample["prepare_ns"] == 0,
                                 "retained Wide Crystal candidate reported per-scan preparation")
                if require_retained_mmap and name == "crystal_baseline":
                    runner.check(timing_values["admission_ns"] is not None,
                                 "retained-metadata baseline omitted admission_ns")
                    runner.check(timing_values["mmap_prepare_ns"] is None,
                                 "retained-metadata baseline unexpectedly emitted mmap_prepare_ns")
                    runner.check(sample["prepare_ns"] == 0,
                                 "retained-metadata baseline reported per-scan preparation")
                profile = None
                if name in profiles:
                    profile = validate_profile(runner, sample, name, expected_frames, split, mark_rows,
                                               expected_mapped_bytes,
                                               require_retained_mmap=require_retained_mmap and
                                               name == "crystal_profile")
                    if require_retained_mmap and name == "crystal_profile":
                        runner.check(timing_values["admission_ns"] is not None and
                                     timing_values["mmap_prepare_ns"] is not None,
                                     "retained Wide Crystal profile omitted a process timing")
                        runner.check(sample["prepare_ns"] == 0,
                                     "retained Wide Crystal profile reported per-scan preparation")
                elif profiles:
                    runner.check("profile" not in sample, "control runner emitted a profile")
                if index >= warmups:
                    samples[name].append(sample["elapsed_ns"])
                    preparations[name].append(sample["prepare_ns"])
                    if profile is not None:
                        profiles[name].append(profile)
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
            "prepare_p95_ns": sorted(preparation)[math.ceil(len(preparation) * 0.95) - 1],
            "prepare_and_scan_samples_ns": preparation_and_scan_samples,
            "prepare_and_scan_p50_ns": statistics.median(preparation_and_scan_samples),
            "prepare_and_scan_p95_ns": sorted(preparation_and_scan_samples)[
                math.ceil(len(preparation_and_scan_samples) * 0.95) - 1
            ],
            "rows_per_second": rows * 1e9 / median,
            "decoded_gib_per_second": rows * 16 * 1e9 / (median * 2**30),
            "admission_ns": process_timing_values["admission_ns"][name],
            "admission_observations_verified": process_timing_observations[name],
            "mmap_prepare_ns": process_timing_values["mmap_prepare_ns"][name],
            "mmap_prepare_observations_verified": process_timing_observations[name],
        }
        if name in profiles:
            engines[name]["profile"] = summarize_profiles(profiles[name], elapsed)

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
    if profiles:
        result["expected_frames_per_worker"] = expected_frames
        result["paired_profile_to_control_time_ratio_p50"] = {
            name: statistics.median(profiled / plain for profiled, plain in zip(samples[name], samples[engine]))
            for engine, name in (("crystal", "crystal_profile"), ("clickhouse", "clickhouse_profile"))
        }
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
    if args.crystal_profile_bin is not None:
        binaries["crystal_profile"] = args.crystal_profile_bin.resolve(strict=True)
        binaries["clickhouse_profile"] = args.cpp_profile_bin.resolve(strict=True)
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
            frame_geometry = wide_lz4_geometry(part, mark_count, mark_rows) if args.crystal_profile_bin else None
            for workers in args.workers:
                for name, binary in binaries.items():
                    control_root = scratch / f"{layout}-{workers}-{name}-checksum-control"
                    corrupt = corrupt_first_frame(part, control_root.with_name(control_root.name + "-part"))
                    with open_runner(binary, control_root, corrupt, layout, control_marks,
                                     mark_rows, workers, control_oracle, args.timeout) as runner:
                        runner.expect_corruption()
                track = run_track(binaries, scratch / f"{layout}-{workers}", part, layout, marks, mark_rows,
                                  workers, oracle, args.warmups, args.repeats, args.timeout, frame_geometry,
                                  require_admission=args.require_admission,
                                  require_retained_mmap=args.require_retained_mmap)
                tracks.append(track)
            if part_manifest_sha256(part) != expected:
                fail(f"{layout} part files changed during the comparison")
            part_hashes[layout] = expected

    return {
        "marks": marks, "mark_rows": mark_rows, "warmups": args.warmups, "repeats": args.repeats,
        "arms": list(binaries),
        "binary_sha256": binary_hashes, "part_file_manifest_sha256": part_hashes,
        "fixture_manifest_sha256": sha256_path(manifest_path), "expected_columns_sha256": oracle_hash,
        "benchmark_driver_sha256": sha256_path(Path(__file__).resolve(strict=True)),
        "checksum_corruption_controls_passed": True,
        "require_admission": args.require_admission,
        "require_retained_mmap": args.require_retained_mmap,
        "tracks": tracks,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--crystal-bin", type=Path, required=True)
    parser.add_argument("--crystal-baseline-bin", type=Path,
                        help="optional prior Crystal runner for a balanced three-arm campaign")
    timing_contract = parser.add_mutually_exclusive_group()
    timing_contract.add_argument("--require-admission", action="store_true",
                                 help="require Wide candidate admission_ns and zero per-scan preparation; check the old per-scan-preparation baseline when present")
    timing_contract.add_argument("--require-retained-mmap", action="store_true",
                                 help="require retained Wide admission_ns and mmap_prepare_ns; check a retained-metadata baseline when present")
    parser.add_argument("--cpp-bin", type=Path, required=True)
    parser.add_argument("--crystal-profile-bin", type=Path, help="Wide runner built with -Dread_rows_profile")
    parser.add_argument("--cpp-profile-bin", type=Path, help="ClickHouse Wide runner with stage probes")
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--layout", choices=("wide", "compact"), action="append")
    parser.add_argument("--workers", type=int, choices=(1, 4), action="append")
    parser.add_argument("--marks", type=lambda value: list(map(int, value.split(","))))
    parser.add_argument("--warmups", type=int, default=4)
    parser.add_argument("--repeats", type=int, default=24)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    profiling = args.crystal_profile_bin is not None or args.cpp_profile_bin is not None
    args.layout = list(dict.fromkeys(args.layout or (["wide"] if profiling else ["wide", "compact"])))
    args.workers = list(dict.fromkeys(args.workers or [1, 4]))
    if args.require_admission and args.layout != ["wide"]:
        parser.error("--require-admission requires Wide-only layout")
    if args.require_retained_mmap and args.layout != ["wide"]:
        parser.error("--require-retained-mmap requires Wide-only layout")
    if profiling and (not args.crystal_profile_bin or not args.cpp_profile_bin or args.crystal_baseline_bin
                      or args.layout != ["wide"]):
        parser.error("profiling requires both profile binaries, Wide layout, and two uninstrumented controls")
    if args.warmups < 1 or args.repeats < 1 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("warmups, repeats, and timeout must be positive")
    args.output.write_text(json.dumps(compare(args), indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
