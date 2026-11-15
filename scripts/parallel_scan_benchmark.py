#!/usr/bin/env python3
"""Prepare and measure the bounded typed-part scan benchmark.

All timing uses one persistent HTTP connection per consumer. The monotonic
interval starts immediately before sending the fixed SQL request and ends after
the complete fixed RowBinary response has been read; exact bytes are checked
immediately after the timer stops.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import http.client
import json
import os
import platform
import re
import signal
import statistics
import struct
import subprocess
import time
from pathlib import Path
from typing import NoReturn
from urllib.parse import quote


DEFAULT_ROWS = 131_072
MARK_ROWS = 8192
FRAME_ROWS = 8192
FRAME_BYTES = FRAME_ROWS * 16
MASK64 = (1 << 64) - 1
EXPORT_SQL = "SELECT pk, value FROM bench.fixture ORDER BY pk FORMAT RowBinary"
AGGREGATE_PREFIX = (
    "SELECT count(), sum(pk), sum(value), sum(bitXor(pk, value)), "
    "min(value), max(value) FROM bench.fixture"
)
CACHE_SETTINGS = (
    "use_query_cache=0, use_query_condition_cache=0, use_uncompressed_cache=0, "
    "optimize_trivial_count_query=0"
)
READ_SCHEDULING_SETTINGS = (
    "optimize_read_in_order=0, query_plan_read_in_order=0, "
    "merge_tree_min_rows_for_concurrent_read=0, "
    "merge_tree_min_bytes_for_concurrent_read=0, "
    "merge_tree_min_read_task_size=4"
)


def fail(message: str) -> NoReturn:
    raise RuntimeError(message)


def request(port: int, path: str, body: bytes | str, timeout: int = 120) -> bytes:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        conn.request("POST", path, body=body)
        response = conn.getresponse()
        payload = response.read()
        if response.status != 200:
            fail(f"HTTP {port}{path} returned {response.status}: {payload[:400]!r}")
        return payload
    finally:
        conn.close()


def query(port: int, sql: str, timeout: int = 120) -> bytes:
    return request(port, "/", sql, timeout)


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def server_config(base: Path, http_port: int, tcp_port: int, interserver_port: int) -> str:
    def xml_dir(path: Path) -> str:
        return html.escape(str(path) + "/", quote=False)

    def xml_file(path: Path) -> str:
        return html.escape(str(path), quote=False)

    return f"""<?xml version='1.0'?>
<clickhouse>
  <logger><level>warning</level><console>true</console><log>{xml_file(base / 'server.log')}</log><errorlog>{xml_file(base / 'error.log')}</errorlog></logger>
  <path>{xml_dir(base / 'store')}</path>
  <tmp_path>{xml_dir(base / 'tmp')}</tmp_path>
  <user_files_path>{xml_dir(base / 'user_files')}</user_files_path>
  <format_schema_path>{xml_dir(base / 'format_schemas')}</format_schema_path>
  <access_control_path>{xml_dir(base / 'access')}</access_control_path>
  <listen_host>127.0.0.1</listen_host>
  <http_port>{http_port}</http_port>
  <tcp_port>{tcp_port}</tcp_port>
  <interserver_http_port>{interserver_port}</interserver_http_port>
  <profiles><default><max_threads>4</max_threads><log_queries>0</log_queries><log_query_threads>0</log_query_threads></default></profiles>
  <users><default><password/><networks><ip>127.0.0.1</ip></networks><profile>default</profile><quota>default</quota></default></users>
  <quotas><default><interval><duration>3600</duration><queries>0</queries><errors>0</errors><result_rows>0</result_rows><read_rows>0</read_rows><execution_time>0</execution_time></interval></default></quotas>
  <query_log><database>system</database><table>query_log</table><flush_interval_milliseconds>1000</flush_interval_milliseconds></query_log>
  <query_thread_log><database>system</database><table>query_thread_log</table><flush_interval_milliseconds>1000</flush_interval_milliseconds></query_thread_log>
</clickhouse>
"""


def native_start(args: argparse.Namespace) -> dict:
    root = Path(args.root)
    binary = Path(args.clickhouse_bin).resolve()
    if not binary.is_file():
        fail(f"pinned ClickHouse binary not found: {binary}")
    reported = subprocess.run([str(binary), "--version"], check=True, capture_output=True, text=True).stdout.strip()
    version_match = re.search(r"\b(\d+\.\d+\.\d+\.\d+)\b", reported)
    version = version_match.group(1) if version_match else reported
    if version != args.expected_version:
        fail(f"ClickHouse binary version {reported!r}, expected {args.expected_version}")
    binary_sha256 = sha256_path(binary)
    if args.expected_sha256 and binary_sha256 != args.expected_sha256:
        fail(f"ClickHouse binary SHA256 {binary_sha256}, expected {args.expected_sha256}")
    root.mkdir(parents=True, exist_ok=False)

    services = []
    started = []
    try:
        for layout, port in (("wide", args.wide_port), ("compact", args.compact_port)):
            probe = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
            try:
                probe.connect()
            except OSError:
                pass
            else:
                fail(f"loopback port {port} is already occupied")
            finally:
                probe.close()

            base = root / layout
            for name in ("store", "tmp", "user_files", "format_schemas", "access"):
                (base / name).mkdir(parents=True, exist_ok=True)
            config_path = base / "config.xml"
            config_path.write_text(server_config(base, port, port + 1, port + 2))
            log_path = base / "launcher.log"
            log = log_path.open("ab")
            environment = os.environ.copy()
            environment["TMPDIR"] = str(base / "tmp")
            environment["CLICKHOUSE_WATCHDOG_ENABLE"] = "0"
            proc = subprocess.Popen(
                [str(binary), "server", f"--config-file={config_path}"],
                cwd=base,
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                env=environment,
                start_new_session=True,
            )
            log.close()
            started.append((proc, port))
            services.append({
                "layout": layout,
                "http_port": port,
                "pid": proc.pid,
                "pgid": proc.pid,
                "config_path": str(config_path),
                "launcher_log": str(log_path),
                "root": str(base),
            })
        deadline = time.monotonic() + args.startup_timeout
        pending = {port for _, port in started}
        while pending and time.monotonic() < deadline:
            for proc, port in started:
                if port not in pending:
                    continue
                if proc.poll() is not None:
                    fail(f"ClickHouse launcher exited with {proc.returncode}; see {root}")
                try:
                    actual = query(port, "SELECT version() FORMAT TabSeparated", timeout=2).decode().strip()
                except (OSError, http.client.HTTPException, RuntimeError):
                    continue
                if actual != version:
                    fail(f"ClickHouse server on port {port} reports {actual}, expected {version}")
                pending.remove(port)
            time.sleep(0.25)
        if pending:
            fail(f"ClickHouse servers did not become ready on ports {sorted(pending)}; see {root}")
    except Exception:
        for proc, _ in started:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        raise

    metadata = {
        "binary": str(binary),
        "binary_sha256": binary_sha256,
        "reported_version": reported,
        "version": version,
        "host": os.uname().nodename,
        "services": services,
    }
    (root / "native-processes.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    return metadata


def native_stop(args: argparse.Namespace) -> dict:
    root = Path(args.root)
    metadata_path = root / "native-processes.json"
    metadata = json.loads(metadata_path.read_text())
    stopped = []
    for service in metadata["services"]:
        pid = int(service["pid"])
        command = subprocess.run(
            ["ps", "-p", str(pid), "-o", "command="],
            capture_output=True, text=True,
        ).stdout.strip()
        if command and service["config_path"] not in command:
            fail(f"refusing to signal PID {pid}: command does not match owned config")
        if command:
            pgid = subprocess.run(
                ["ps", "-p", str(pid), "-o", "pgid="],
                capture_output=True, text=True,
            ).stdout.strip()
            if pgid != str(service["pgid"]):
                fail(f"refusing to signal PID {pid}: process group {pgid!r} differs from owned {service['pgid']}")
            try:
                os.killpg(int(service["pgid"]), signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + args.shutdown_timeout
        while time.monotonic() < deadline:
            current = subprocess.run(
                ["ps", "-p", str(pid), "-o", "command="],
                capture_output=True, text=True,
            ).stdout.strip()
            if not current:
                break
            # Once SIGTERM has been sent to the verified process group, keep
            # waiting through the process' short exit transition. Never signal
            # again if the command text changes during shutdown.
            time.sleep(0.1)
        else:
            fail(f"owned ClickHouse process {pid} did not exit")
        stopped.append({
            "layout": service["layout"],
            "pid": pid,
            "http_port": service["http_port"],
            "process_exited": True,
        })
    return {"stopped": stopped, "root": str(root)}


def insert_rowbinary(port: int, fixture_path: Path) -> None:
    encoded = quote("INSERT INTO bench.fixture FORMAT RowBinary", safe="")
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=300)
    try:
        conn.request("POST", f"/?query={encoded}", body=fixture_path.read_bytes())
        response = conn.getresponse()
        payload = response.read()
        if response.status != 200:
            fail(f"RowBinary insert on port {port} returned {response.status}: {payload[:400]!r}")
    finally:
        conn.close()


def splitmix64(key: int) -> int:
    value = (key + 0x9E3779B97F4A7C15) & MASK64
    value = ((value ^ (value >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
    value = ((value ^ (value >> 27)) * 0x94D049BB133111EB) & MASK64
    value ^= value >> 31
    return value & MASK64


def fixture_values(rows: int):
    for key in range(rows):
        yield key, splitmix64(key) & 0xFFFFFFFF


def aggregate_oracle(rows: int) -> bytes:
    sum_key = 0
    sum_value = 0
    sum_xor = 0
    min_value = MASK64
    max_value = 0
    for key, value in fixture_values(rows):
        sum_key = (sum_key + key) & MASK64
        sum_value = (sum_value + value) & MASK64
        sum_xor = (sum_xor + (key ^ value)) & MASK64
        min_value = min(min_value, value)
        max_value = max(max_value, value)
    return struct.pack("<6Q", rows, sum_key, sum_value, sum_xor, min_value, max_value)


def generate_fixture(path: Path, rows: int, mark_rows: int = MARK_ROWS) -> dict:
    if mark_rows <= 0 or rows <= 0 or rows % mark_rows != 0:
        fail(f"rows must be a positive multiple of mark_rows ({mark_rows})")
    path.parent.mkdir(parents=True, exist_ok=True)
    frame_hashes = []
    digest = hashlib.sha256()
    with path.open("wb") as output:
        frame = bytearray()
        for key, value in fixture_values(rows):
            frame.extend(struct.pack("<QQ", key, value))
            if len(frame) == FRAME_BYTES:
                output.write(frame)
                digest.update(frame)
                frame_hashes.append(hashlib.sha256(frame).hexdigest())
                frame.clear()
        if frame:
            output.write(frame)
            digest.update(frame)
            frame_hashes.append(hashlib.sha256(frame).hexdigest())
    return {
        "rows": rows,
        "row_bytes": 16,
        "mark_rows": mark_rows,
        "source_bytes": path.stat().st_size,
        "source_sha256": digest.hexdigest(),
        "frame_rows": FRAME_ROWS,
        "frame_sha256": frame_hashes,
        "value_formula": "SplitMix64(pk) low 32 bits; pk=0..rows-1",
        "aggregate_rowbinary_hex": aggregate_oracle(rows).hex(),
    }


def table_ddl(layout: str, mark_rows: int = MARK_ROWS) -> str:
    if layout == "wide":
        wide_settings = "min_rows_for_wide_part=0, min_bytes_for_wide_part=0"
    else:
        wide_settings = (
            "min_rows_for_wide_part=4294967295, "
            "min_bytes_for_wide_part=4294967295"
        )
    return (
        "CREATE TABLE bench.fixture (pk UInt64, value UInt64) "
        "ENGINE = MergeTree ORDER BY pk "
        f"SETTINGS index_granularity={mark_rows}, index_granularity_bytes=10485760, "
        f"{wide_settings}, min_compress_block_size=0, "
        "max_compress_block_size=4096, default_compression_codec='LZ4', "
        "compress_marks=0, compress_primary_key=0, "
        "write_marks_for_substreams_in_compact_parts=0"
    )


def ensure_native_table(port: int, layout: str, fixture_path: Path, mark_rows: int) -> None:
    query(port, "CREATE DATABASE bench")
    query(port, table_ddl(layout, mark_rows))
    insert_rowbinary(port, fixture_path)


def native_cache_capabilities(port: int) -> dict:
    payload = query(
        port,
        "SELECT name, value FROM system.settings WHERE name IN "
        "('use_query_cache','use_query_condition_cache','use_uncompressed_cache',"
        "'merge_tree_use_deserialization_prefixes_cache','optimize_trivial_count_query',"
        "'use_columns_cache') ORDER BY name FORMAT TabSeparated",
    )
    settings = {}
    for row in payload.decode("utf-8").splitlines():
        name, value = row.split("\t", 1)
        settings[name] = value
    required = {
        "use_query_cache",
        "use_query_condition_cache",
        "use_uncompressed_cache",
        "merge_tree_use_deserialization_prefixes_cache",
        "optimize_trivial_count_query",
    }
    missing = sorted(required - settings.keys())
    if missing:
        fail(f"native cache settings unavailable on port {port}: {missing}")
    columns_cache = settings.get("use_columns_cache")
    if columns_cache is not None and columns_cache not in {"0", "false"}:
        fail(f"native use_columns_cache must be off, got {columns_cache!r}")
    return {
        "system_settings": settings,
        "columns_cache_capability": "absent" if columns_cache is None else f"value={columns_cache}",
        "timed_query_overrides": {
            "use_query_cache": 0,
            "use_query_condition_cache": 0,
            "use_uncompressed_cache": 0,
            "merge_tree_use_deserialization_prefixes_cache": 0,
            "optimize_trivial_count_query": 0,
        },
    }


def tsv_row(payload: bytes, expected_fields: int, label: str) -> list[str]:
    rows = payload.decode("utf-8").splitlines()
    if len(rows) != 1:
        fail(f"{label}: expected one TSV row, got {rows!r}")
    fields = rows[0].split("\t")
    if len(fields) != expected_fields:
        fail(f"{label}: expected {expected_fields} fields, got {fields!r}")
    return fields


def physical_mark_geometry(part_path: Path, layout: str) -> dict:
    suffix, record_bytes, row_count_offset = {
        "wide": (".mrk2", 24, 16),
        "compact": (".mrk3", 40, 32),
    }[layout]
    mark_files = sorted(part_path.rglob(f"*{suffix}"))
    if not mark_files:
        fail(f"native {layout} part has no {suffix} mark files")
    vectors = []
    for mark_file in mark_files:
        data = mark_file.read_bytes()
        if len(data) % record_bytes:
            fail(f"mark file {mark_file} has {len(data)} bytes, not a multiple of {record_bytes}")
        vectors.append([
            struct.unpack_from("<Q", data, offset + row_count_offset)[0]
            for offset in range(0, len(data), record_bytes)
        ])
    reference = vectors[0]
    if any(rows != reference for rows in vectors[1:]):
        fail(f"native {layout} mark row-count vectors differ across streams")
    if not reference or reference[-1] != 0 or any(rows == 0 for rows in reference[:-1]):
        fail(f"native {layout} marks lack exactly one trailing zero-row terminal record: {reference!r}")
    return {
        "format": suffix,
        "record_bytes": record_bytes,
        "mark_files": [str(path.relative_to(part_path)) for path in mark_files],
        "physical_mark_records_including_terminal": len(reference),
        "positive_data_marks": len(reference) - 1,
        "rows_per_positive_mark": reference[:-1],
        "terminal_zero_mark_records": sum(rows == 0 for rows in reference),
    }


def part_metadata(port: int, expected_rows: int, expected_layout: str,
                  mark_rows: int = MARK_ROWS) -> dict:
    parts = query(
        port,
        "SELECT name, path, rows, marks, part_type FROM system.parts "
        "WHERE database='bench' AND table='fixture' AND active "
        "ORDER BY name FORMAT TabSeparated",
    ).decode("utf-8").splitlines()
    if len(parts) != 1:
        fail(f"expected one active native part on port {port}; got {parts!r}")
    name, raw_path, raw_rows, raw_marks, part_type = parts[0].split("\t")
    if part_type.lower() != expected_layout:
        fail(f"expected {expected_layout} part, got {part_type} at {raw_path}")
    if int(raw_rows) != expected_rows:
        fail(f"part has {raw_rows} rows, expected {expected_rows}")
    check_result = query(port, "CHECK TABLE bench.fixture").decode("utf-8").splitlines()
    check_fields = check_result[0].split("\t") if len(check_result) == 1 else []
    if len(check_fields) < 2 or check_fields[1] != "1":
        fail(f"CHECK TABLE did not return successful result row: {check_result!r}")
    part_path = Path(raw_path.rstrip("/"))
    if not part_path.is_dir():
        fail(f"system.parts returned missing part path: {raw_path!r}")
    mark_geometry = physical_mark_geometry(part_path, expected_layout.lower())
    if sum(mark_geometry["rows_per_positive_mark"]) != expected_rows:
        fail("native physical mark rows do not sum to the table row count")
    if any(rows != mark_rows for rows in mark_geometry["rows_per_positive_mark"]):
        fail(f"native physical mark geometry differs from the expected {mark_rows} rows per mark")
    files = []
    for file_path in sorted(item for item in part_path.rglob("*") if item.is_file()):
        relative = str(file_path.relative_to(part_path))
        files.append({
            "path": relative,
            "bytes": file_path.stat().st_size,
            "sha256": hashlib.sha256(file_path.read_bytes()).hexdigest(),
        })
    logical_bytes = sum(item["bytes"] for item in files if item["path"].endswith(".bin"))
    file_listing = json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    return {
        "name": name,
        "path": str(part_path),
        "rows": int(raw_rows),
        "marks": mark_geometry["positive_data_marks"],
        "system_parts_marks_including_terminal": int(raw_marks),
        "physical_mark_geometry": mark_geometry,
        "part_type": part_type,
        "data_file_bytes": logical_bytes,
        "files": files,
        "file_manifest_sha256": hashlib.sha256(file_listing).hexdigest(),
        "check_table_result": check_result[0],
    }


def assert_stream_equal(port: int, path: str, body: str, source_path: Path,
                        expected_hashes: list[str], label: str) -> list[str]:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=300)
    actual_hashes = []
    total = 0
    try:
        conn.request("POST", path, body=body)
        response = conn.getresponse()
        if response.status != 200:
            fail(f"{label}: export returned HTTP {response.status}: {response.read(400)!r}")
        with source_path.open("rb") as source:
            frame_index = 0
            while expected := source.read(FRAME_BYTES):
                actual = response.read(len(expected))
                if actual != expected:
                    fail(f"{label}: RowBinary differs in frame {frame_index}")
                actual_digest = hashlib.sha256(actual).hexdigest()
                if actual_digest != expected_hashes[frame_index]:
                    fail(f"{label}: frame digest differs in frame {frame_index}")
                actual_hashes.append(actual_digest)
                frame_index += 1
                total += len(actual)
            if response.read(1):
                fail(f"{label}: export has trailing bytes after {total}")
        if total != source_path.stat().st_size:
            fail(f"{label}: export byte count {total} differs from source")
        if len(actual_hashes) != len(expected_hashes):
            fail(f"{label}: frame count differs from source manifest")
    finally:
        conn.close()
    return actual_hashes


def validate_fixture_source(source_path: Path, fixture: dict) -> dict:
    if not source_path.is_file():
        fail(f"fixture source is missing: {source_path}")
    actual_sha = sha256_path(source_path)
    actual_size = source_path.stat().st_size
    if actual_sha != fixture["source_sha256"] or actual_size != fixture["source_bytes"]:
        fail("fixture source SHA256 or byte count differs from its manifest")
    if actual_size != fixture["rows"] * fixture["row_bytes"]:
        fail("fixture source size is inconsistent with row count")
    actual_frames = []
    with source_path.open("rb") as source:
        while frame := source.read(FRAME_BYTES):
            if len(frame) % fixture["row_bytes"]:
                fail("fixture source ends in a partial RowBinary row")
            actual_frames.append(hashlib.sha256(frame).hexdigest())
    if actual_frames != fixture["frame_sha256"]:
        fail("fixture frame hash sequence differs from its manifest")
    expected_aggregate = aggregate_oracle(fixture["rows"]).hex()
    if expected_aggregate != fixture["aggregate_rowbinary_hex"]:
        fail("independent aggregate oracle differs from its manifest")
    return {
        "source_sha256": actual_sha,
        "source_bytes": actual_size,
        "frame_count": len(actual_frames),
        "aggregate_rowbinary_hex": expected_aggregate,
    }


def reject_wrong_aggregate_request(port: int, sql: str) -> dict:
    wrong_sql = sql.replace("sum(pk)", "sum(value)", 1)
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    try:
        conn.request("POST", "/aggregate", body=wrong_sql)
        response = conn.getresponse()
        body = response.read()
        if response.status != 400:
            fail(f"Crystal worker accepted a wrong aggregate request: HTTP {response.status} {body[:200]!r}")
        return {"status": response.status, "rejected_before_scan": True}
    finally:
        conn.close()


def settings_sql(threads: int, checksum_on_read: int, *, logging: bool = False) -> str:
    parts = [
        f"max_threads={threads}",
        f"checksum_on_read={checksum_on_read}",
        CACHE_SETTINGS,
        "merge_tree_use_deserialization_prefixes_cache=0",
        READ_SCHEDULING_SETTINGS,
        "log_queries=1" if logging else "log_queries=0",
        "log_query_threads=1" if logging else "log_query_threads=0",
    ]
    return f"{AGGREGATE_PREFIX} SETTINGS {', '.join(parts)} FORMAT RowBinary"


def stat_summary(samples: list[dict]) -> dict:
    samples_ns = [sample["elapsed_ns"] for sample in samples]
    values_ms = [value / 1_000_000 for value in samples_ns]
    median_ms = statistics.median(values_ms)
    deviations = [abs(value - median_ms) for value in values_ms]
    return {
        "samples": samples,
        "samples_ms": values_ms,
        "median_ms": median_ms,
        "mad_ms": statistics.median(deviations),
        "min_ms": min(values_ms),
        "max_ms": max(values_ms),
    }


def persistent_connection(port: int) -> http.client.HTTPConnection:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=300)
    conn.connect()
    return conn


def checked_request_ns(conn: http.client.HTTPConnection, path: str, body: str,
                       expected: bytes, label: str) -> tuple[int, str, bool]:
    socket_before = conn.sock
    if socket_before is None:
        fail(f"{label}: persistent HTTP connection is not established")
    started = time.perf_counter_ns()
    conn.request("POST", path, body=body, headers={"Content-Type": "text/plain"})
    response = conn.getresponse()
    payload = response.read()
    elapsed = time.perf_counter_ns() - started
    if response.status != 200:
        fail(f"{label}: timed request returned HTTP {response.status}: {payload[:400]!r}")
    if len(payload) != 48 or payload != expected:
        fail(f"{label}: response is not the exact expected 48-byte reduction")
    socket_reused = conn.sock is socket_before
    if not socket_reused:
        fail(f"{label}: HTTP connection reconnected inside the measured series")
    return elapsed, hashlib.sha256(payload).hexdigest(), socket_reused


def run_benchmark(args: argparse.Namespace) -> dict:
    manifest_path = Path(args.manifest)
    manifest = json.loads(manifest_path.read_text())
    source_path = manifest_path.parent / "fixture.rowbinary"
    source_check = validate_fixture_source(source_path, manifest["fixture"])
    layout = args.layout
    layout_info = manifest["layouts"][layout]
    rows = manifest["fixture"]["rows"]
    mark_rows = manifest["fixture"]["mark_rows"]
    expected = bytes.fromhex(manifest["fixture"]["aggregate_rowbinary_hex"])
    checksum = 0 if layout == "wide" else 1
    sql = settings_sql(args.threads, checksum)
    crystal_port = args.crystal_port
    native_port = layout_info["http_port"]
    crystal_export_path = "/export"
    native_export_sql = f"{EXPORT_SQL} SETTINGS checksum_on_read={checksum}, {CACHE_SETTINGS}"
    wrong_request_control = reject_wrong_aggregate_request(crystal_port, sql)
    crystal_worker_witness = None
    if args.mode == "parallel":
        request(crystal_port, "/prepare", "PREPARE")
        witness_payload = request(crystal_port, "/witness", "WITNESS")
        crystal_worker_witness = json.loads(witness_payload)
        expected_marks = (rows + mark_rows - 1) // mark_rows
        if crystal_worker_witness["rows"] != rows:
            fail(f"Crystal worker witness saw {crystal_worker_witness['rows']} rows, expected {rows}")
        if crystal_worker_witness["distinct_data_marks"] != expected_marks:
            fail(
                f"Crystal worker witness saw {crystal_worker_witness['distinct_data_marks']} marks, "
                f"expected {expected_marks}"
            )
        if crystal_worker_witness["min_rows_per_mark"] != mark_rows or crystal_worker_witness["max_rows_per_mark"] != mark_rows:
            fail(
                "Crystal worker witness found nonuniform physical granules: "
                f"min={crystal_worker_witness['min_rows_per_mark']}, "
                f"max={crystal_worker_witness['max_rows_per_mark']}, expected {mark_rows}"
            )
        if not crystal_worker_witness["callback_thread_is_caller"]:
            fail("Crystal worker witness callback did not remain on its caller thread")
        if args.threads > 1 and crystal_worker_witness["isolated_contexts_at_first_callback"] != args.threads:
            fail(
                f"Crystal callback saw {crystal_worker_witness['isolated_contexts_at_first_callback']} "
                f"isolated contexts, expected {args.threads}"
            )

    request(crystal_port, "/prepare", "PREPARE")
    crystal_hashes = assert_stream_equal(
        crystal_port, crystal_export_path, EXPORT_SQL, source_path,
        manifest["fixture"]["frame_sha256"], f"Crystal {layout} export",
    )
    native_hashes = assert_stream_equal(
        native_port, "/", native_export_sql, source_path,
        manifest["fixture"]["frame_sha256"], f"ClickHouse {layout} export",
    )
    if native_hashes != crystal_hashes:
        fail("native and Crystal RowBinary frame hash sequences differ")

    crystal = persistent_connection(crystal_port)
    native = persistent_connection(native_port)
    expected_fixed_body = sql
    samples = {"crystal": [], "clickhouse": []}
    ordered = []
    response_sha = hashlib.sha256(expected).hexdigest()
    try:
        # Two untimed, alternating warmups still use the exact measured request.
        for index in range(args.warmups):
            order = ("crystal", "clickhouse") if index % 2 == 0 else ("clickhouse", "crystal")
            for name in order:
                conn = crystal if name == "crystal" else native
                path = "/aggregate" if name == "crystal" else "/"
                if name == "crystal":
                    request(crystal_port, "/prepare", "PREPARE")
                checked_request_ns(conn, path, expected_fixed_body, expected, f"warmup {name}")
        for index in range(args.repeats):
            order = ("crystal", "clickhouse") if index % 2 == 0 else ("clickhouse", "crystal")
            ordered.append(list(order))
            for name in order:
                conn = crystal if name == "crystal" else native
                path = "/aggregate" if name == "crystal" else "/"
                if name == "crystal":
                    request(crystal_port, "/prepare", "PREPARE")
                elapsed, output_sha, socket_reused = checked_request_ns(
                    conn, path, expected_fixed_body, expected, f"sample {index} {name}"
                )
                samples[name].append({
                    "pair_index": index,
                    "order": list(order),
                    "elapsed_ns": elapsed,
                    "response_sha256": output_sha,
                    "persistent_socket_reused": socket_reused,
                })
                if output_sha != response_sha:
                    fail(f"{name} sample {index} response digest differs")
    finally:
        crystal.close()
        native.close()

    layout_after = part_metadata(native_port, rows, layout, mark_rows)
    if layout_after["file_manifest_sha256"] != layout_info["part"]["file_manifest_sha256"]:
        fail("native part changed during benchmark; before/after file hashes differ")

    return {
        "layout": layout,
        "mode": args.mode,
        "rows": rows,
        "marks": layout_info["part"]["marks"],
        "threads": args.threads,
        "checksum_on_read": checksum,
        "settings_sql": sql,
        "timer": "Python time.perf_counter_ns immediately before HTTPConnection.request through full response.read; exact response checked after stop; both sockets connected before samples. Crystal selected-part reader reopens on an untimed /prepare before each witness/export and Crystal request; native server reuses loaded part metadata and creates a query pipeline per request.",
        "request_body_sha256": hashlib.sha256(expected_fixed_body.encode()).hexdigest(),
        "response_rowbinary_hex": expected.hex(),
        "response_sha256": response_sha,
        "warmups": args.warmups,
        "alternating_orders": ordered,
        "crystal": stat_summary(samples["crystal"]),
        "clickhouse": stat_summary(samples["clickhouse"]),
        "crystal_export_frame_sha256": crystal_hashes,
        "clickhouse_export_frame_sha256": native_hashes,
        "part_file_manifest_sha256_before": layout_info["part"]["file_manifest_sha256"],
        "part_file_manifest_sha256_after": layout_after["file_manifest_sha256"],
        "host": os.uname().nodename,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "cpu_count": os.cpu_count(),
        "clickhouse_version": layout_info["version"],
        "clickhouse_binary": layout_info.get("native_binary"),
        "native_read_scheduling_settings": READ_SCHEDULING_SETTINGS,
        "native_cache_capabilities": layout_info["cache_capabilities"],
        "manifest_sha256": sha256_path(manifest_path),
        "source_validation": source_check,
        "wrong_aggregate_negative_control": wrong_request_control,
        "crystal_worker_participation_witness": crystal_worker_witness,
        "crystal_worker_binary": str(Path(args.crystal_binary).resolve()),
        "crystal_worker_binary_sha256": sha256_path(Path(args.crystal_binary)),
        "source_revision": args.source_revision,
    }


def native_concurrency_probe(args: argparse.Namespace) -> dict:
    manifest = json.loads(Path(args.manifest).read_text())
    layout_info = manifest["layouts"][args.layout]
    port = layout_info["http_port"]
    sql = settings_sql(args.threads, 0 if args.layout == "wide" else 1, logging=True)
    timed_sql = settings_sql(args.threads, 0 if args.layout == "wide" else 1)
    if sql.replace("log_queries=1, log_query_threads=1", "log_queries=0, log_query_threads=0") != timed_sql:
        fail("native diagnostic SQL differs from timed SQL beyond query logging flags")
    expected = bytes.fromhex(manifest["fixture"]["aggregate_rowbinary_hex"])
    pipeline_sql = "EXPLAIN PIPELINE " + timed_sql.replace(" FORMAT RowBinary", " FORMAT TSV")
    pipeline = query(port, pipeline_sql).decode("utf-8")
    read_stream = re.search(r"MergeTreeSelect\(pool: ReadPool, algorithm: Thread\).*", pipeline)
    if args.threads > 1:
        if "ReadPoolInOrder" in pipeline or read_stream is None:
            fail(f"native pipeline did not use a parallel ReadPool/Thread: {pipeline!r}")
        if not re.search(rf"×\s*{args.threads}\b", read_stream.group(0)):
            fail(f"native read pipeline does not expose {args.threads} streams: {pipeline!r}")

    trials = []
    for trial in range(args.trials):
        query_id = f"scanbench-{args.layout}-threads-{args.threads}-{trial}-{time.time_ns()}"
        path = f"/?query_id={quote(query_id, safe='')}"
        result = request(port, path, sql)
        if result != expected:
            fail("native concurrency probe aggregate differs from independent oracle")
        query(port, "SYSTEM FLUSH LOGS")
        query_row = tsv_row(query(
            port,
            "SELECT read_rows, read_bytes, peak_threads_usage FROM system.query_log "
            f"WHERE query_id='{query_id}' AND type='QueryFinish' FORMAT TabSeparated",
        ).rstrip(b"\n"), 3, "native query log")
        thread_row = tsv_row(query(
            port,
            "SELECT countDistinct(thread_id), groupUniqArray(thread_name), sum(read_rows) "
            "FROM system.query_thread_log "
            f"WHERE query_id='{query_id}' AND read_rows > 0 FORMAT TabSeparated",
        ).rstrip(b"\n"), 3, "native thread log")
        read_rows, read_bytes, peak_threads = (int(value) for value in query_row)
        participating_threads = int(thread_row[0])
        thread_read_rows = int(thread_row[2])
        if read_rows != manifest["fixture"]["rows"]:
            fail(f"native query read_rows={read_rows}, expected {manifest['fixture']['rows']}")
        if read_bytes <= 0:
            fail(f"native query has no logical read_bytes: {read_bytes}")
        if thread_read_rows != read_rows:
            fail(f"positive-read query-thread rows sum {thread_read_rows}, expected {read_rows}")
        if peak_threads < args.threads or participating_threads != args.threads:
            fail(
                f"native max_threads={args.threads}, but peak={peak_threads}, "
                f"distinct threads with positive read_rows={participating_threads}"
            )
        trials.append({
            "query_id": query_id,
            "read_rows": read_rows,
            "read_bytes": read_bytes,
            "peak_threads_usage": peak_threads,
            "query_thread_log_distinct_thread_ids_with_positive_read_rows": participating_threads,
            "query_thread_log_names": thread_row[1],
            "query_thread_log_read_rows_sum": thread_read_rows,
        })
    return {
        "layout": args.layout,
        "requested_max_threads": args.threads,
        "pipeline_sql": pipeline_sql,
        "read_pipeline": read_stream.group(0) if read_stream else None,
        "pipeline_text": pipeline,
        "diagnostic_settings_sql": sql,
        "timed_settings_sql": timed_sql,
        "timed_logging_state": {"log_queries": 0, "log_query_threads": 0},
        "trials": trials,
    }


def prepare(args: argparse.Namespace) -> dict:
    root = Path(args.root)
    root.mkdir(parents=True, exist_ok=True)
    fixture_path = root / "fixture.rowbinary"
    fixture_manifest = generate_fixture(fixture_path, args.rows, args.mark_rows)
    processes_path = root / "native-processes.json"
    if not processes_path.is_file():
        fail("native-processes.json is missing; start the two owned servers with native-start")
    native_processes = json.loads(processes_path.read_text())
    layouts = {}
    for layout, port in (("wide", args.wide_port), ("compact", args.compact_port)):
        version = query(port, "SELECT version() FORMAT TabSeparated").decode().strip()
        if version != args.expected_version:
            fail(f"native port {port} has ClickHouse {version}, expected {args.expected_version}")
        cache_capabilities = native_cache_capabilities(port)
        ensure_native_table(port, layout, fixture_path, args.mark_rows)
        part = part_metadata(port, args.rows, layout, args.mark_rows)
        expected_marks = (args.rows + args.mark_rows - 1) // args.mark_rows
        if part["marks"] != expected_marks:
            fail(f"native {layout} has {part['marks']} marks; expected {expected_marks}")
        native_export_sql = f"{EXPORT_SQL} SETTINGS checksum_on_read={0 if layout == 'wide' else 1}, {CACHE_SETTINGS}"
        hashes = assert_stream_equal(
            port, "/", native_export_sql, fixture_path,
            fixture_manifest["frame_sha256"], f"native {layout} export",
        )
        if hashes != fixture_manifest["frame_sha256"]:
            fail(f"native {layout} RowBinary frame digests differ from source")
        aggregate_sql = settings_sql(1, 0 if layout == "wide" else 1)
        aggregate = query(port, aggregate_sql)
        if aggregate != bytes.fromhex(fixture_manifest["aggregate_rowbinary_hex"]):
            fail(f"native {layout} aggregate differs from independent oracle")
        layouts[layout] = {
            "http_port": port,
            "version": version,
            "checksum_on_read": 0 if layout == "wide" else 1,
            "cache_capabilities": cache_capabilities,
            "native_binary": {
                "path": native_processes["binary"],
                "sha256": native_processes["binary_sha256"],
                "reported_version": native_processes["reported_version"],
            },
            "part": part,
            "rowbinary_frame_sha256": hashes,
        }
    manifest = {
        "fixture": fixture_manifest,
        "layouts": layouts,
        "host": os.uname().nodename,
        "native_integrity_policy": {
            "wide": "checksum_on_read=0 (matches ordinary Crystal Wide compressed-frame behavior)",
            "compact": "checksum_on_read=1 (matches ordinary Crystal Compact frame checksum verification)",
            "preflight": "CHECK TABLE result field equals 1; exact full RowBinary sequence checked outside timed intervals",
        },
        "cache_policy": {
            "timed": CACHE_SETTINGS,
            "merge_tree_use_deserialization_prefixes_cache": 0,
            "shared_os_page_cache": "warm and shared after exact preflight exports",
            "native_columns_cache": "native_cache_capabilities records absent setting or its effective zero value",
        },
        "read_scheduling_policy": READ_SCHEDULING_SETTINGS,
        "table_settings": {
            "index_granularity": args.mark_rows,
            "index_granularity_bytes": 10485760,
            "min_compress_block_size": 0,
            "max_compress_block_size": 4096,
            "default_compression_codec": "LZ4",
            "compress_marks": 0,
            "compress_primary_key": 0,
            "write_marks_for_substreams_in_compact_parts": 0,
            "wide_part_thresholds": {"min_rows_for_wide_part": 0, "min_bytes_for_wide_part": 0},
            "compact_part_thresholds": {"min_rows_for_wide_part": 4294967295, "min_bytes_for_wide_part": 4294967295},
            "note": f"Adaptive byte granularity stays at ClickHouse's 10 MiB default because stock ClickHouse cannot create Compact parts when disabled. With 16-byte rows, index_granularity={args.mark_rows} sets the exact rows per mark. MRK3 is selected for Compact marks. The 4 KiB maximum compressed blocks are a controlled fixture choice.",
        },
    }
    manifest_path = root / "fixture-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return {"manifest_path": str(manifest_path), **manifest}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare_parser = subparsers.add_parser("prepare", help="generate/import and verify native fixtures")
    prepare_parser.add_argument("--root", required=True)
    prepare_parser.add_argument("--rows", type=int, default=DEFAULT_ROWS)
    prepare_parser.add_argument("--mark-rows", type=int, default=MARK_ROWS)
    prepare_parser.add_argument("--wide-port", type=int, default=35000)
    prepare_parser.add_argument("--compact-port", type=int, default=35003)
    prepare_parser.add_argument("--expected-version", default="26.10.1.1201")
    prepare_parser.add_argument("--output")
    prepare_parser.set_defaults(function=prepare)

    bench_parser = subparsers.add_parser("bench", help="run an alternating Crystal/ClickHouse timing pair")
    bench_parser.add_argument("--manifest", required=True)
    bench_parser.add_argument("--layout", choices=("wide", "compact"), required=True)
    bench_parser.add_argument("--crystal-port", type=int, required=True)
    bench_parser.add_argument("--mode", choices=("baseline-serial", "parallel"), required=True)
    bench_parser.add_argument("--threads", type=int, choices=(1, 4), required=True)
    bench_parser.add_argument("--warmups", type=int, default=2)
    bench_parser.add_argument("--repeats", type=int, default=15)
    bench_parser.add_argument("--crystal-binary", required=True)
    bench_parser.add_argument("--source-revision", required=True)
    bench_parser.add_argument("--output", required=True)
    bench_parser.set_defaults(function=run_benchmark)

    probe_parser = subparsers.add_parser("native-probe", help="verify native read work and participating threads")
    probe_parser.add_argument("--manifest", required=True)
    probe_parser.add_argument("--layout", choices=("wide", "compact"), required=True)
    probe_parser.add_argument("--threads", type=int, choices=(1, 4), required=True)
    probe_parser.add_argument("--trials", type=int, default=2)
    probe_parser.add_argument("--output")
    probe_parser.set_defaults(function=native_concurrency_probe)

    start_parser = subparsers.add_parser("native-start", help="start two private pinned ClickHouse servers")
    start_parser.add_argument("--root", required=True)
    start_parser.add_argument("--clickhouse-bin", required=True)
    start_parser.add_argument("--expected-version", default="26.10.1.1201")
    start_parser.add_argument("--expected-sha256", default="5bb43958f4c0806cc363b84b9858e7206e56ac80263a24acc704271322e531ae")
    start_parser.add_argument("--wide-port", type=int, default=35100)
    start_parser.add_argument("--compact-port", type=int, default=35103)
    start_parser.add_argument("--startup-timeout", type=int, default=120)
    start_parser.set_defaults(function=native_start)

    stop_parser = subparsers.add_parser("native-stop", help="stop only the servers recorded in the root")
    stop_parser.add_argument("--root", required=True)
    stop_parser.add_argument("--shutdown-timeout", type=int, default=20)
    stop_parser.set_defaults(function=native_stop)

    args = parser.parse_args()
    result = args.function(args)
    serialized = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if getattr(args, "output", None):
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(serialized)
        print(output_path)
    else:
        print(serialized, end="")


if __name__ == "__main__":
    main()
