#!/usr/bin/env python3
"""Pair Compact JSON filter routes on one retained probe process."""

import argparse
import hashlib
import json
import math
import os
import shutil
import statistics
import struct
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path

from parallel_scan_benchmark import sha256_path
from read_rows_benchmark import Runner


PREDICATES = ("zero", "cluster", "spread", "all")
ROUTES_BY_COMPARISON = {
    "mark-vs-mask": ("mark_only", "masked"),
    "eager-vs-mark": ("eager", "mark_only"),
}
CONTROL_ROUTES = ("mark_only", "masked")
EXPECTED_ROWS = {"zero": 0, "cluster": 2048, "spread": 2048, "all": 8192}
EXPECTED_MARKS = {
    "zero": [],
    "cluster": [1],
    "spread": [0, 1, 2, 3],
    "all": [0, 1, 2, 3],
}
EXPECTED_JSON_MARK_ROWS = {
    "mark_only": {
        "zero": [], "cluster": [2048], "spread": [2048] * 4, "all": [2048] * 4,
    },
    "masked": {
        "zero": [], "cluster": [2048], "spread": [512] * 4, "all": [2048] * 4,
    },
    "eager": {
        "zero": [2048] * 4, "cluster": [2048] * 4, "spread": [2048] * 4, "all": [2048] * 4,
    },
}
EXPECTED_FILTERED_SHA256 = {
    "cluster": "6707d36d408449f887bbe8b5eac50716f6589ff4550214bee7f2d5f64486d4e2",
    "spread": "527ac21142b66b1a4c51095218c19eab1061fdc365e978f79f9354386aa74dbb",
}
EXPECTED_PART_FILE_SHA256 = {
    "data.bin": "d99ddd6d2144615388982b267b20f14e4f56e4689f26faea922c2ab3fb5c82d5",
    "data.mrk4": "b5c2c2f6072c7c8c727cc1e73f191a55c16e5cdf0b2a6e4acaf4f1edf07ca27b",
}
EXPECTED_FILTERED_LZ4_FRAMES = {"zero": 4, "cluster": 7, "spread": 16, "all": 16}


def fail(message: str) -> None:
    raise RuntimeError(message)


def part_hashes(part: Path) -> dict[str, str]:
    return {path.name: sha256_path(path) for path in sorted(part.iterdir()) if path.is_file()}


def read_varuint(data: bytes, pos: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while True:
        if pos >= len(data):
            fail("truncated full RowBinary String length")
        byte = data[pos]
        pos += 1
        payload = byte & 0x7F
        if shift == 63 and (payload > 1 or byte >= 0x80):
            fail("invalid full RowBinary VarUInt")
        value |= payload << shift
        if byte < 0x80:
            return value, pos
        shift += 7
        if shift > 63:
            fail("invalid full RowBinary VarUInt")


def parse_ordered_oracle(data: bytes) -> list[tuple[int, bytes]]:
    rows = []
    pos = 0
    previous = -1
    while pos < len(data):
        start = pos
        if pos > len(data) - 8:
            fail("truncated full RowBinary UInt64")
        row_id = int.from_bytes(data[pos:pos + 8], "little")
        pos += 8
        size, pos = read_varuint(data, pos)
        if size > len(data) - pos:
            fail("truncated full RowBinary JSON String")
        pos += size
        if row_id <= previous:
            fail("full ClickHouse RowBinary oracle is not strictly ordered by id")
        previous = row_id
        rows.append((row_id, data[start:pos]))
    return rows


def matches(predicate: str, row_id: int) -> bool:
    if predicate == "zero":
        return False
    if predicate == "cluster":
        return 2048 <= row_id < 4096
    if predicate == "spread":
        return row_id % 4 == 0
    if predicate == "all":
        return True
    raise ValueError(predicate)


def source_offsets_sha256(predicate: str) -> str:
    encoded = bytearray()
    for mark in EXPECTED_MARKS[predicate]:
        mark_start = mark * 2048
        for local_row in range(2048):
            row_id = mark_start + local_row
            if matches(predicate, row_id):
                encoded.extend(struct.pack("<IQ", mark, row_id))
    return hashlib.sha256(encoded).hexdigest()


def write_filtered_oracles(oracle: Path, root: Path) -> dict[str, dict]:
    data = oracle.read_bytes()
    rows = parse_ordered_oracle(data)
    if len(rows) != 8192 or rows[0][0] != 0 or rows[-1][0] != 8191:
        fail("full RowBinary oracle does not contain the expected id range")
    outputs = {}
    for predicate in PREDICATES:
        selected = [raw for row_id, raw in rows if matches(predicate, row_id)]
        if len(selected) != EXPECTED_ROWS[predicate]:
            fail(f"independent RowBinary filter oracle has wrong {predicate} count")
        payload = b"".join(selected)
        path = root / f"oracle-{predicate}.rowbinary"
        path.write_bytes(payload)
        digest = hashlib.sha256(payload).hexdigest()
        if predicate in EXPECTED_FILTERED_SHA256 and digest != EXPECTED_FILTERED_SHA256[predicate]:
            fail(f"{predicate} filter oracle SHA-256 differs from the independently pinned native export")
        outputs[predicate] = {"path": str(path), "rows": len(selected), "bytes": len(payload), "sha256": digest}
    return outputs


@contextmanager
def open_probe(binary: Path, root: Path, part: Path, oracle: Path, filtered_oracle: Path,
               workers: int, predicate: str):
    root.mkdir(parents=True)
    log_path = root / "stderr.log"
    command = [str(binary), str(part), str(oracle), str(filtered_oracle), str(workers), predicate, "--stdin"]
    with log_path.open("wb") as log, subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
        cwd=root, env={**os.environ, "TMPDIR": str(root)}, bufsize=0,
    ) as process:
        reader = Runner(process, f"{predicate}-w{workers}", log_path, 180)
        try:
            reader.check(reader.line() == b"READY", "probe did not admit the part")
            yield reader
        finally:
            if process.poll() is None:
                process.kill()


def sample_route(reader: Runner, route: str) -> dict:
    reader.process.stdin.write(f"scan {route}\n".encode())
    response = reader.line()
    reader.check(response is not None, f"{route} scan exited without a sample")
    try:
        return json.loads(response)
    except json.JSONDecodeError as error:
        fail(f"probe emitted invalid JSON: {error}")


def validate_sample(sample: dict, predicate: str, route: str, workers: int,
                    expected: dict, expected_full_sha256: str) -> None:
    if sample.get("route") != route or sample.get("predicate") != predicate:
        fail("probe sample route or predicate differs from the requested cell")
    if sample.get("workers_requested") != workers or sample.get("workers_retained") != workers:
        fail("probe did not retain the requested number of worker contexts")
    retained_threads = sample.get("worker_thread_ids_retained")
    if (not isinstance(retained_threads, list) or len(retained_threads) != workers or
            any(type(thread_id) is not int or thread_id <= 0 for thread_id in retained_threads) or
            len(set(retained_threads)) != workers):
        fail("probe did not retain distinct worker execution contexts")
    if sample.get("rows") != expected["rows"] or sample.get("rowbinary_bytes") != expected["bytes"]:
        fail("probe output row count or bytes differ from the independent filter oracle")
    if sample.get("oracle_exact") is not True or sample.get("rowbinary_sha256") != expected["sha256"]:
        fail("probe RowBinary output differs from the independently filtered ClickHouse oracle")
    expected_json_marks = [0, 1, 2, 3] if route == "eager" else EXPECTED_MARKS[predicate]
    if sample.get("json_mark_indices") != expected_json_marks:
        fail(f"{route} selected JSON marks differ from the expected schedule")
    if sample.get("json_mark_row_counts") != EXPECTED_JSON_MARK_ROWS[route][predicate]:
        fail(f"{route} decoded a different number of JSON rows in a selected mark")
    if sample.get("selected_source_offset_count") != expected["rows"]:
        fail("probe selected source-offset count differs from the filtered RowBinary oracle")
    if sample.get("source_offsets_verified") is not True:
        fail("probe did not verify dense output rows against their original part offsets")
    if sample.get("selected_source_offsets_sha256") != source_offsets_sha256(predicate):
        fail("probe source-offset sequence differs from the independently computed predicate mask")
    expected_active = min(workers, len(expected_json_marks))
    if sample.get("workers_active") != expected_active:
        fail("active JSON worker count differs from the mark schedule")
    expected_assignments = [[] for _ in range(workers)]
    for ordinal, mark in enumerate(expected_json_marks):
        expected_assignments[ordinal % workers].append(mark)
    expected_workers = [index for index, assigned in enumerate(expected_assignments) if assigned]
    actual_assignments = sample.get("worker_assignments")
    if not isinstance(actual_assignments, list):
        fail("probe did not report actual worker assignments")
    if [entry.get("worker") for entry in actual_assignments] != expected_workers:
        fail("probe completed a different set of worker assignments")
    for entry in actual_assignments:
        worker = entry.get("worker")
        if (entry.get("marks") != expected_assignments[worker] or
                entry.get("thread_id") != retained_threads[worker]):
            fail("probe worker thread or mark assignment changed")
    if sample.get("filter_evaluations") != 8192:
        fail("filter predicate was not evaluated once for every source id")
    if route in ("lazy", "mark_only", "masked") and predicate == "zero":
        if sample.get("json_plan_present") is not False or sample.get("json_mark_decode_invocations") != 0:
            fail("zero-match filtered route prepared or decoded a JSON mark")
    for field in ("read_wall_ns", "serialization_ns", "scan_and_serialize_ns"):
        if type(sample.get(field)) is not int or sample[field] <= 0:
            if field == "serialization_ns" and expected["rows"] == 0:
                continue
            fail(f"probe sample has invalid {field}")
    if sample["scan_and_serialize_ns"] < sample["read_wall_ns"] + sample.get("serialization_ns", 0):
        fail("combined interval is shorter than its read and serialization stages")
    if sample.get("full_oracle_sha256") != expected_full_sha256:
        fail("probe did not identify the full ClickHouse RowBinary oracle")


def validate_filter_stage_diagnostics(sample: dict, predicate: str, route: str, workers: int) -> dict:
    diagnostics = sample.get("filter_stage_diagnostics")
    if not isinstance(diagnostics, dict):
        fail("stage probe did not return filter-stage diagnostics")
    if diagnostics.get("elapsed_basis") != "per-thread elapsed; worker sums are not scan wall time":
        fail("stage probe did not identify the per-thread elapsed basis")
    stages = diagnostics.get("stages")
    worker_summary = diagnostics.get("workers")
    if not isinstance(stages, dict) or not isinstance(worker_summary, dict):
        fail("stage probe diagnostics are missing their stage or worker summaries")

    for stage_name, stage in stages.items():
        if not isinstance(stage_name, str) or not isinstance(stage, dict):
            fail("stage probe returned a malformed stage record")
        for field in ("calls", "rows", "bytes", "elapsed_ns", "coordinator_elapsed_ns"):
            value = stage.get(field)
            if type(value) is not int or value < 0:
                fail(f"stage {stage_name} has an invalid {field}")
        per_worker = stage.get("worker_elapsed_ns_by_id")
        if not isinstance(per_worker, dict):
            fail(f"stage {stage_name} is missing per-worker elapsed time")
        per_worker_total = 0
        for worker_key, elapsed in per_worker.items():
            if not isinstance(worker_key, str) or not worker_key.isdecimal():
                fail(f"stage {stage_name} has an invalid worker id")
            worker_index = int(worker_key)
            if worker_index >= workers or type(elapsed) is not int or elapsed < 0:
                fail(f"stage {stage_name} has an invalid worker elapsed value")
            per_worker_total += elapsed
        if stage["elapsed_ns"] != stage["coordinator_elapsed_ns"] + per_worker_total:
            fail(f"stage {stage_name} elapsed total disagrees with its context breakdown")
        metrics = stage.get("metrics", {})
        if not isinstance(metrics, dict):
            fail(f"stage {stage_name} has malformed dimensions")
        for field, value in metrics.items():
            if type(value) not in (int, float, str, bool) and value is not None:
                fail(f"stage {stage_name} has a malformed metric {field}")
            if type(value) in (int, float) and value < 0:
                fail(f"stage {stage_name} has a negative metric {field}")

    contributions = worker_summary.get("contributions")
    if not isinstance(contributions, list):
        fail("stage probe worker summary is missing contributions")
    named_union_by_worker: dict[int, int] = {}
    mark_decode_by_worker: dict[int, int] = {}
    for contribution in contributions:
        if not isinstance(contribution, dict):
            fail("stage probe returned a malformed worker contribution")
        worker = contribution.get("worker")
        named_elapsed = contribution.get("named_stage_union_elapsed_ns")
        mark_decode_elapsed = contribution.get("mark_decode_elapsed_ns")
        if (type(worker) is not int or not 0 <= worker < workers or
                type(named_elapsed) is not int or named_elapsed < 0 or
                type(mark_decode_elapsed) is not int or mark_decode_elapsed < 0):
            fail("stage probe returned an invalid worker contribution")
        if worker in named_union_by_worker:
            fail("stage probe repeated a worker contribution")
        named_union_by_worker[worker] = named_elapsed
        mark_decode_by_worker[worker] = mark_decode_elapsed
    if set(named_union_by_worker) != set(range(workers)):
        fail("stage probe worker contributions do not cover every requested worker")
    worker_mark_decode = stages.get("worker_mark_decode")
    mark_decode_stage_by_worker = {worker: 0 for worker in range(workers)}
    if worker_mark_decode is None:
        pass
    else:
        per_worker = worker_mark_decode.get("worker_elapsed_ns_by_id")
        if not isinstance(per_worker, dict):
            fail("worker_mark_decode is missing its per-worker timing map")
        for worker, elapsed in per_worker.items():
            if not str(worker).isdecimal() or int(worker) >= workers or type(elapsed) is not int or elapsed < 0:
                fail("worker_mark_decode has an invalid per-worker elapsed value")
            mark_decode_stage_by_worker[int(worker)] = elapsed
    if mark_decode_by_worker != mark_decode_stage_by_worker:
        fail("worker mark-decode contributions disagree with the measured stage span")

    summed_named = sum(named_union_by_worker.values())
    maximum_named = max(named_union_by_worker.values(), default=0)
    summed_mark_decode = sum(mark_decode_by_worker.values())
    maximum_mark_decode = max(mark_decode_by_worker.values(), default=0)
    slowest = worker_summary.get("slowest_mark_decode_worker")
    if (worker_summary.get("summed_named_stage_union_elapsed_ns") != summed_named or
            worker_summary.get("max_named_stage_union_elapsed_ns") != maximum_named or
            worker_summary.get("summed_mark_decode_elapsed_ns") != summed_mark_decode or
            worker_summary.get("max_mark_decode_elapsed_ns") != maximum_mark_decode):
        fail("stage probe worker sums or maxima disagree with its contributions")
    if maximum_mark_decode == 0:
        if slowest is not None:
            fail("stage probe reported a slowest mark-decode worker with no worker time")
    elif type(slowest) is not int or mark_decode_by_worker.get(slowest) != maximum_mark_decode:
        fail("stage probe slowest mark-decode worker disagrees with its maximum contribution")

    mask = stages.get("mask_construction")
    if not isinstance(mask, dict):
        fail("stage probe omitted mask construction")
    mask_metrics = {**mask.get("metrics", {}), **mask}
    if mask_metrics.get("examined_rows") != 8192 or \
            mask_metrics.get("kept_rows") != EXPECTED_ROWS[predicate] or \
            mask_metrics.get("marks") != len(EXPECTED_MARKS[predicate]):
        fail("stage probe mask-construction counts differ from the pinned predicate")
    if EXPECTED_ROWS[predicate] == 0:
        if any(stage.get("calls", 0) for name, stage in stages.items() if name != "mask_construction"):
            fail("zero-match stage probe performed JSON or Copy/Data work")
    else:
        if not isinstance(worker_mark_decode, dict) or worker_mark_decode["calls"] <= 0:
            fail("stage probe did not record worker mark-decode time")
        sparse_mask_route = predicate == "spread" and route == "masked"
        required = (("packed_row_map_build", "copy_dictionary_metadata", "copy_index_scan",
                     "copy_dictionary_materialization", "copy_row_map_fill", "copy_data_parse",
                     "copy_data_verify_and_append") if sparse_mask_route else
                    ("old_copy_row_decode_and_append", "old_data_parse", "old_data_verify"))
        for name in required:
            if not isinstance(stages.get(name), dict) or stages[name]["calls"] <= 0:
                fail(f"stage probe did not record required {name} work for {predicate}/{route}")
    return diagnostics


def percentiles(values: list[int]) -> dict[str, float | int]:
    ordered = sorted(values)
    return {"p50": statistics.median(ordered), "p95": ordered[math.ceil(len(ordered) * 0.95) - 1]}


def summarize_stage_samples(records: list[dict], workers: int) -> dict:
    diagnostics = [record["filter_stage_diagnostics"] for record in records]
    stage_names = sorted({name for item in diagnostics for name in item["stages"]})
    stages_summary = {}
    for name in stage_names:
        selected = [item["stages"].get(name, {}) for item in diagnostics]
        fields = {"calls", "rows", "bytes", "elapsed_ns", "coordinator_elapsed_ns",
                  "examined_rows", "kept_rows", "marks", "paths", "entries",
                  "row_map_push_elapsed_ns"}
        fields.update(
            field for stage in selected for field, value in stage.items()
            if type(value) in (int, float)
        )
        stats = {"present_sample_count": sum(bool(stage) for stage in selected)}
        for field in sorted(fields):
            values = [stage[field] for stage in selected if field in stage]
            if values:
                stats[field] = percentiles(values)
        metric_names = sorted({metric for stage in selected for metric in stage.get("metrics", {})})
        if metric_names:
            stats["metrics"] = {}
        for metric in metric_names:
            values = [stage["metrics"][metric] for stage in selected
                      if metric in stage.get("metrics", {})]
            numeric_values = [value for value in values if type(value) in (int, float)]
            metric_summary = {"sample_count": len(values)}
            if numeric_values:
                metric_summary["percentiles"] = percentiles(numeric_values)
            else:
                metric_summary["values"] = sorted({str(value) for value in values})
            stats["metrics"][metric] = metric_summary
        worker_stats = {}
        for worker in range(workers):
            values = [stage.get("worker_elapsed_ns_by_id", {}).get(str(worker), 0) for stage in selected]
            if any(values):
                worker_stats[str(worker)] = percentiles(values)
        if worker_stats:
            stats["worker_elapsed_ns_by_id"] = worker_stats
        stages_summary[name] = stats

    worker_fields = (
        "summed_named_stage_union_elapsed_ns", "max_named_stage_union_elapsed_ns",
        "summed_mark_decode_elapsed_ns", "max_mark_decode_elapsed_ns",
    )
    worker_stats = {field: percentiles([item["workers"][field] for item in diagnostics])
                    for field in worker_fields}
    worker_stats["named_union_sum_to_read_wall_ratio"] = percentiles([
        item["workers"]["summed_named_stage_union_elapsed_ns"] / record["read_wall_ns"]
        for item, record in zip(diagnostics, records)
    ])
    worker_stats["mark_decode_sum_to_read_wall_ratio"] = percentiles([
        item["workers"]["summed_mark_decode_elapsed_ns"] / record["read_wall_ns"]
        for item, record in zip(diagnostics, records)
    ])
    worker_stats["mark_decode_max_to_read_wall_ratio"] = percentiles([
        item["workers"]["max_mark_decode_elapsed_ns"] / record["read_wall_ns"]
        for item, record in zip(diagnostics, records)
    ])
    return {
        "sample_count": len(records),
        "read_wall_ns": percentiles([record["read_wall_ns"] for record in records]),
        "serialization_ns": percentiles([record["serialization_ns"] for record in records]),
        "scan_and_serialize_ns": percentiles([record["scan_and_serialize_ns"] for record in records]),
        "worker_elapsed_basis": diagnostics[0]["elapsed_basis"],
        "append_sampling": diagnostics[0].get("append_sampling"),
        "workers": worker_stats,
        "stages": stages_summary,
    }


def summarize_stage_overhead(stock_samples: list[dict], stage_samples: list[dict],
                             routes: tuple[str, ...]) -> list[dict]:
    summary = []
    for predicate in PREDICATES:
        for workers in (1, 4):
            for route in routes:
                stock_by_pair = {
                    (sample["block"], sample["pair"]): sample for sample in stock_samples
                    if sample["predicate"] == predicate and sample["workers_requested"] == workers and
                    sample["route"] == route
                }
                stage_by_pair = {
                    (sample["block"], sample["pair"]): sample for sample in stage_samples
                    if sample["predicate"] == predicate and sample["workers_requested"] == workers and
                    sample["route"] == route
                }
                paired = sorted(set(stock_by_pair) & set(stage_by_pair))
                if not paired:
                    fail(f"stage/stock overhead has no paired samples for {predicate}/w{workers}/{route}")
                read_deltas = [stage_by_pair[key]["read_wall_ns"] - stock_by_pair[key]["read_wall_ns"]
                               for key in paired]
                read_percent = [100 * delta / stock_by_pair[key]["read_wall_ns"]
                                for key, delta in zip(paired, read_deltas)]
                combined_deltas = [stage_by_pair[key]["scan_and_serialize_ns"] -
                                   stock_by_pair[key]["scan_and_serialize_ns"] for key in paired]
                stage_before = sum(stage_by_pair[key]["build_order"].index("stage") == 0 for key in paired)
                summary.append({
                    "predicate": predicate,
                    "workers_requested": workers,
                    "route": route,
                    "paired_count": len(paired),
                    "stage_before_stock_pairs": stage_before,
                    "stage_build_read_faster_pairs": sum(stage_by_pair[key]["read_wall_ns"] <
                                                         stock_by_pair[key]["read_wall_ns"] for key in paired),
                    "read_overhead_delta_ns": percentiles(read_deltas),
                    "read_overhead_percent": percentiles(read_percent),
                    "combined_overhead_delta_ns": percentiles(combined_deltas),
                })
    return summary


def validate_stage_order_balance(stage_samples: list[dict], routes: tuple[str, ...]) -> None:
    for predicate in PREDICATES:
        for workers in (1, 4):
            pair_records = {}
            for sample in stage_samples:
                if sample["predicate"] == predicate and sample["workers_requested"] == workers:
                    pair_records[(sample["block"], sample["pair"])] = sample
            order_counts: dict[tuple[tuple[str, ...], tuple[str, ...]], int] = {}
            for sample in pair_records.values():
                key = (tuple(sample["route_order"]), tuple(sample["build_order"]))
                order_counts[key] = order_counts.get(key, 0) + 1
            if len(order_counts) != 4 or max(order_counts.values()) - min(order_counts.values()) > 1:
                fail(f"stage/stock route and build order is not balanced for {predicate}/w{workers}")
            for route in routes:
                selected = [sample for sample in stage_samples if sample["predicate"] == predicate and
                            sample["workers_requested"] == workers and sample["route"] == route]
                build_counts = {order: sum(sample["build_order"] == list(order) for sample in selected)
                                for order in (("stock", "stage"), ("stage", "stock"))}
                if abs(build_counts[("stock", "stage")] - build_counts[("stage", "stock")]) > 1:
                    fail(f"stage/stock build order is not balanced for {predicate}/w{workers}/{route}")


def run_checksum_control(binary: Path, part: Path, oracle: Path, filtered_oracle: Path,
                         root: Path, workers: int, route: str) -> dict:
    root.mkdir(parents=True)
    trial_part = root / "0_1_1_0"
    shutil.copytree(part, trial_part)
    log_path = root / "stderr.log"
    command = [str(binary), str(trial_part), str(oracle), str(filtered_oracle), str(workers), "spread", "--stdin"]
    with log_path.open("wb") as log, subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
        cwd=root, env={**os.environ, "TMPDIR": str(root)}, bufsize=0,
    ) as process:
        runner = Runner(process, f"checksum-w{workers}", log_path, 180)
        runner.check(runner.line() == b"READY", "probe did not open the checksum-control part")
        data_path = trial_part / "data.bin"
        with data_path.open("r+b", buffering=0) as data:
            first = data.read(1)
            if len(first) != 1:
                fail("checksum control part has no frame checksum byte")
            data.seek(0)
            data.write(bytes([first[0] ^ 1]))
        process.stdin.write(f"scan {route}\n".encode())
        if runner.line() is not None:
            fail(f"{route} scan returned rows for a checksum-corrupted frame")
        status = process.wait(timeout=runner.timeout)
        diagnostic = log_path.read_bytes().lower()
        if status == 0 or b"checksum mismatch" not in diagnostic:
            fail(f"{route} scan did not reject the post-open checksum corruption")
    return {"workers": workers, "route": route, "predicate": "spread", "rejected": True,
            "diagnostic_sha256": hashlib.sha256(log_path.read_bytes()).hexdigest()}


def run_copy_data_control(binary: Path, part: Path, root: Path, workers: int, route: str) -> dict:
    root.mkdir(parents=True)
    trial_part = root / "0_1_1_0"
    shutil.copytree(part, trial_part)
    command = [str(binary), "--copy-data-control", str(trial_part), str(workers), route]
    result = subprocess.run(command, cwd=root, capture_output=True, timeout=180,
                           env={**os.environ, "TMPDIR": str(root)})
    if result.returncode != 0:
        fail("Copy/Data control did not complete its expected rejection: " + result.stderr[-4096:].decode(errors="replace"))
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        fail(f"Copy/Data control emitted invalid JSON: {error}")
    if (payload.get("rejected") is not True or payload.get("callbacks") != 0 or
            payload.get("workers_requested") != workers or payload.get("predicate") != "cluster_spread" or
            payload.get("error") != "Object shared Copy value disagrees with its per-path Dynamic row"):
        fail("Copy/Data control did not report a valid-checksum lane disagreement")
    if payload.get("route") != route or payload.get("callbacks") != 0:
        fail(f"{route} Copy/Data control did not reject before callback delivery")
    return {"workers": workers, **payload}


def run_diagnostic_matrix(binary: Path, part: Path, oracle: Path, expected: dict,
                          scratch: Path, full_oracle_sha256: str, routes: tuple[str, ...]) -> list[dict]:
    records = []
    for predicate in PREDICATES:
        for workers in (1, 4):
            root = scratch / f"diagnostic-{predicate}-w{workers}"
            with open_probe(binary, root, part, oracle, Path(expected[predicate]["path"]), workers, predicate) as reader:
                for route in routes:
                    sample = sample_route(reader, route)
                    validate_sample(sample, predicate, route, workers, expected[predicate], full_oracle_sha256)
                    counters = sample.get("diagnostics")
                    if not isinstance(counters, dict):
                        fail("diagnostic probe did not return actual compressed-frame counters")
                    total_lz4 = counters.get("total_lz4_frames")
                    expected_lz4 = 16 if route == "eager" else EXPECTED_FILTERED_LZ4_FRAMES[predicate]
                    if total_lz4 != expected_lz4:
                        fail(f"{route}/{predicate}/w{workers} decoded {total_lz4} LZ4 frames, expected {expected_lz4}")
                    if route != "eager" and predicate == "zero":
                        if (total_lz4 != 4 or sample.get("json_plan_present") is not False or
                                sample.get("json_mark_decode_invocations") != 0):
                            fail("zero-match filtered path decoded a JSON frame instead of only its four key frames")
                    for field in ("total_lz4_payload_bytes", "total_lz4_output_bytes", "total_lz4_elapsed_ns"):
                        if type(counters.get(field)) is not int or counters[field] < 0:
                            fail(f"{route}/{predicate}/w{workers} has an invalid {field} LZ4 counter")
                    if counters["total_lz4_output_bytes"] <= 0 or counters["total_lz4_elapsed_ns"] <= 0:
                        fail(f"{route}/{predicate}/w{workers} recorded no LZ4 output bytes or decode time")
                    records.append({"predicate": predicate, "workers_requested": workers, "route": route,
                                    "expected_lz4_frames": expected_lz4, **sample})
                reader.quit()
    return records


def run_stage_paired_matrix(stock_binary: Path, stage_binary: Path, part: Path, oracle: Path,
                            expected: dict, scratch: Path, full_oracle_sha256: str,
                            routes: tuple[str, ...], blocks: int, warmups: int,
                            repeats: int) -> tuple[list[dict], list[dict]]:
    original_part_hashes = part_hashes(part)
    stock_records = []
    stage_records = []
    for predicate in PREDICATES:
        for workers in (1, 4):
            for block in range(blocks):
                block_root = scratch / f"stage-paired-{predicate}-w{workers}-block{block:02d}"
                with open_probe(stock_binary, block_root / "stock", part, oracle,
                                Path(expected[predicate]["path"]), workers, predicate) as stock_reader:
                    with open_probe(stage_binary, block_root / "stage", part, oracle,
                                    Path(expected[predicate]["path"]), workers, predicate) as stage_reader:
                        for pair in range(warmups + repeats):
                            if pair < warmups:
                                order_ordinal = block * warmups + pair
                            else:
                                order_ordinal = block * repeats + pair - warmups
                            route_order = routes if order_ordinal % 2 == 0 else tuple(reversed(routes))
                            for route in route_order:
                                # Independent bits of the sequential measured-pair ordinal make
                                # route/build order balanced for every valid blocks/repeats shape.
                                build_order = (("stock", "stage") if (order_ordinal // 2) % 2 == 0
                                               else ("stage", "stock"))
                                for build in build_order:
                                    reader = stock_reader if build == "stock" else stage_reader
                                    sample = sample_route(reader, route)
                                    validate_sample(sample, predicate, route, workers,
                                                    expected[predicate], full_oracle_sha256)
                                    if build == "stage":
                                        validate_filter_stage_diagnostics(sample, predicate, route, workers)
                                    if pair < warmups:
                                        continue
                                    record = {
                                        "predicate": predicate,
                                        "workers_requested": workers,
                                        "route": route,
                                        "block": block,
                                        "pair": pair - warmups,
                                        "route_order": list(route_order),
                                        "build_order": list(build_order),
                                        **sample,
                                    }
                                    (stock_records if build == "stock" else stage_records).append(record)
                        stock_reader.quit()
                        stage_reader.quit()
            if part_hashes(part) != original_part_hashes:
                fail("stage diagnostic changed the measured part")
    return stock_records, stage_records


def benchmark(options: argparse.Namespace) -> dict:
    routes = ROUTES_BY_COMPARISON[options.comparison]
    if options.timing_only and options.diagnostic_probe:
        fail("--timing-only cannot be combined with --diagnostic-probe")
    if options.stage_probe and options.comparison != "mark-vs-mask":
        fail("--stage-probe is supported only with the mark-vs-mask comparison")
    if options.comparison == "mark-vs-mask" and not options.diagnostic_probe and not options.timing_only:
        fail("the mark-vs-mask campaign requires --diagnostic-probe or explicit --timing-only")
    part = options.part.resolve(strict=True)
    oracle = options.oracle.resolve(strict=True)
    binary = options.probe.resolve(strict=True)
    stage_binary = options.stage_probe.resolve(strict=True) if options.stage_probe else None
    if stage_binary and sha256_path(stage_binary) == sha256_path(binary):
        fail("--stage-probe must name a separate instrumented binary")
    source_archive = options.source_archive.resolve(strict=True) if options.source_archive else None
    stage_source_archive = options.stage_source_archive.resolve(strict=True) if options.stage_source_archive else None
    diagnostic_source_archive = (options.diagnostic_source_archive.resolve(strict=True)
                                 if options.diagnostic_source_archive else None)
    scratch = options.scratch.resolve(strict=True)
    original_part_hashes = part_hashes(part)
    if not {"data.bin", "data.mrk4", "checksums.txt", "columns.txt", "columns_substreams.txt"} <= original_part_hashes.keys():
        fail("expected the pinned Compact MRK4 SharedData overflow part")
    if any(original_part_hashes.get(name) != digest for name, digest in EXPECTED_PART_FILE_SHA256.items()):
        fail("overflow part data or MRK4 geometry differs from the independently pinned fixture")
    original_oracle_sha256 = sha256_path(oracle)
    if original_oracle_sha256 != "3495978197741a4e241a2201bd92030afbb7590588bccb2ab3da107b1059d62b":
        fail("full ordered RowBinary oracle does not match the pinned overflow part")

    expected = write_filtered_oracles(oracle, scratch)
    samples = []
    stage_samples = []
    diagnostics = []
    checksum_controls = []
    copy_data_controls = []
    stage_checksum_controls = []
    stage_copy_data_controls = []
    for workers in (1, 4):
        for route in CONTROL_ROUTES:
            checksum_controls.append(run_checksum_control(
                binary, part, oracle, Path(expected["spread"]["path"]),
                scratch / f"checksum-control-{route}-w{workers}", workers, route,
            ))
            copy_data_controls.append(run_copy_data_control(
                binary, part, scratch / f"copy-data-control-{route}-w{workers}", workers, route,
            ))
            if stage_binary:
                stage_checksum_controls.append(run_checksum_control(
                    stage_binary, part, oracle, Path(expected["spread"]["path"]),
                    scratch / f"stage-checksum-control-{route}-w{workers}", workers, route,
                ))
                stage_copy_data_controls.append(run_copy_data_control(
                    stage_binary, part, scratch / f"stage-copy-data-control-{route}-w{workers}", workers, route,
                ))

    if stage_binary:
        samples, stage_samples = run_stage_paired_matrix(
            binary, stage_binary, part, oracle, expected, scratch / "stage-paired-matrix",
            original_oracle_sha256, routes, options.blocks, options.warmups, options.repeats,
        )
        validate_stage_order_balance(stage_samples, routes)
    else:
        for predicate in PREDICATES:
            for workers in (1, 4):
                for block in range(options.blocks):
                    process_root = scratch / f"paired-{predicate}-w{workers}-block{block:02d}"
                    with open_probe(binary, process_root, part, oracle, Path(expected[predicate]["path"]), workers, predicate) as reader:
                        for pair in range(options.warmups + options.repeats):
                            order = routes if (block + pair) % 2 == 0 else tuple(reversed(routes))
                            for route in order:
                                sample = sample_route(reader, route)
                                validate_sample(sample, predicate, route, workers, expected[predicate], original_oracle_sha256)
                                if pair >= options.warmups:
                                    samples.append({
                                        "predicate": predicate,
                                        "workers_requested": workers,
                                        "route": route,
                                        "block": block,
                                        "pair": pair - options.warmups,
                                        "route_order": list(order),
                                        **sample,
                                    })
                        reader.quit()
                if part_hashes(part) != original_part_hashes:
                    fail("benchmark changed the measured part")

    if options.diagnostic_probe:
        diagnostic_binary = options.diagnostic_probe.resolve(strict=True)
        diagnostics = run_diagnostic_matrix(diagnostic_binary, part, oracle, expected,
                                            scratch / "frame-diagnostics", original_oracle_sha256, routes)

    summary = []
    for predicate in PREDICATES:
        for workers in (1, 4):
            route_samples = {}
            for route in routes:
                selected = [sample for sample in samples if sample["predicate"] == predicate and
                            sample["workers_requested"] == workers and sample["route"] == route]
                route_samples[route] = selected
                stats = {field: percentiles([sample[field] for sample in selected]) for field in (
                    "read_wall_ns", "serialization_ns", "scan_and_serialize_ns",
                    "gc_read_allocated_bytes_delta", "gc_read_collections",
                )}
                summary.append({"predicate": predicate, "workers_requested": workers,
                                "route": route, "sample_count": len(selected), **stats})
            left_route, right_route = routes
            left_by_pair = {(sample["block"], sample["pair"]): sample for sample in route_samples[left_route]}
            right_by_pair = {(sample["block"], sample["pair"]): sample for sample in route_samples[right_route]}
            paired = sorted(set(left_by_pair) & set(right_by_pair))
            summary.append({
                "predicate": predicate,
                "workers_requested": workers,
                "route": f"{left_route}_vs_{right_route}_paired",
                "paired_count": len(paired),
                "right_route_read_faster_pairs": sum(right_by_pair[key]["read_wall_ns"] < left_by_pair[key]["read_wall_ns"] for key in paired),
                "read_delta_ns": percentiles([right_by_pair[key]["read_wall_ns"] - left_by_pair[key]["read_wall_ns"] for key in paired]),
                "combined_delta_ns": percentiles([right_by_pair[key]["scan_and_serialize_ns"] - left_by_pair[key]["scan_and_serialize_ns"] for key in paired]),
            })

    hashes_after = part_hashes(part)
    if hashes_after != original_part_hashes:
        fail("measured part hashes changed during the campaign")
    report = {
        "format": "compact_json_filter_scan_benchmark_v2",
        "comparison": options.comparison,
        "timing_only": options.timing_only,
        "route_pair": list(routes),
        "control_routes": list(CONTROL_ROUTES),
        "part_hashes": original_part_hashes,
        "part_file_bytes": {path.name: path.stat().st_size for path in sorted(part.iterdir()) if path.is_file()},
        "part_hashes_unchanged": hashes_after == original_part_hashes,
        "part_path": str(part),
        "oracle_path": str(oracle),
        "scratch_path": str(scratch),
        "full_oracle_sha256": original_oracle_sha256,
        "probe_sha256": sha256_path(binary),
        "probe_path": str(binary),
        "source_archive_path": str(source_archive) if source_archive else None,
        "source_archive_sha256": sha256_path(source_archive) if source_archive else None,
        "stage_probe_sha256": sha256_path(stage_binary) if stage_binary else None,
        "stage_probe_path": str(stage_binary) if stage_binary else None,
        "stage_source_archive_path": str(stage_source_archive) if stage_source_archive else None,
        "stage_source_archive_sha256": sha256_path(stage_source_archive) if stage_source_archive else None,
        "predicates": expected,
        "blocks": options.blocks,
        "warmups_per_block": options.warmups,
        "repeats_per_block": options.repeats,
        "balanced_route_order": True,
        "diagnostic_probe_sha256": sha256_path(options.diagnostic_probe.resolve(strict=True)) if options.diagnostic_probe else None,
        "diagnostic_probe_path": str(options.diagnostic_probe.resolve(strict=True))
        if options.diagnostic_probe else None,
        "diagnostic_source_archive_path": str(diagnostic_source_archive) if diagnostic_source_archive else None,
        "diagnostic_source_archive_sha256": sha256_path(diagnostic_source_archive)
        if diagnostic_source_archive else None,
        "invocation": sys.argv,
        "frame_diagnostics": diagnostics,
        "checksum_controls": checksum_controls,
        "copy_data_controls": copy_data_controls,
        "stage_checksum_controls": stage_checksum_controls,
        "stage_copy_data_controls": stage_copy_data_controls,
        "rowbinary_checks_passed": True,
        "summary": summary,
        "samples": samples,
        "stage_samples": stage_samples,
        "stage_summary": [
            {"predicate": predicate, "workers_requested": workers, "route": route,
             **summarize_stage_samples(
                 [sample for sample in stage_samples if sample["predicate"] == predicate and
                  sample["workers_requested"] == workers and sample["route"] == route], workers,
             )}
            for predicate in PREDICATES for workers in (1, 4) for route in routes
        ] if stage_samples else [],
        "stage_overhead_vs_stock": summarize_stage_overhead(samples, stage_samples, routes) if stage_samples else [],
    }
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("part", "oracle", "probe", "scratch", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--diagnostic-probe", type=Path,
                        help="separate -Dcompact_json_scan_diagnostic build with the --lz4-only hook")
    parser.add_argument("--stage-probe", type=Path,
                        help="separate -Dcompact_json_filter_stage_diagnostic build with per-stage counters (mark-vs-mask only)")
    parser.add_argument("--source-archive", type=Path,
                        help="source archive used to build --probe, recorded with SHA-256")
    parser.add_argument("--stage-source-archive", type=Path,
                        help="source archive used to build --stage-probe, recorded with SHA-256")
    parser.add_argument("--diagnostic-source-archive", type=Path,
                        help="source archive used to build --diagnostic-probe, recorded with SHA-256")
    parser.add_argument("--timing-only", action="store_true",
                        help="allow mark-vs-mask without the separate LZ4 diagnostic build")
    parser.add_argument("--comparison", choices=tuple(ROUTES_BY_COMPARISON), default="eager-vs-mark",
                        help="paired routes: legacy eager versus mark-only (default), or mark-only versus masked")
    parser.add_argument("--blocks", type=int, default=8)
    parser.add_argument("--warmups", type=int, default=2)
    parser.add_argument("--repeats", type=int, default=6)
    args = parser.parse_args()
    if args.blocks < 1 or args.warmups < 0 or args.repeats < 1:
        parser.error("blocks and repeats must be positive, and warmups must be nonnegative")
    if args.blocks * args.repeats < 48:
        parser.error("use at least 48 timed pairs per predicate, worker count, and route")
    report = benchmark(args)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["summary"], indent=2))
