#!/usr/bin/env python3
"""Generate the deterministic Compact MRK4 JSON fixture on a local benchmark server."""

import argparse
import json
import shutil
from pathlib import Path

from parallel_scan_benchmark import query, request, sha256_path


TABLE = "default.compact_json_scan_bench"
ROWS_PER_PART = 8192
ROWS_PER_MARK = 2048
DDL = f"""
CREATE TABLE {TABLE}
(
    id UInt64,
    doc JSON(max_dynamic_paths=4, max_dynamic_types=2, tenant_id UInt32, title String, rank Nullable(UInt32)),
    events Array(Tuple(a UInt64, b String)),
    attrs Map(String, Array(Nullable(UInt64)))
)
ENGINE = MergeTree PARTITION BY intDiv(id, {ROWS_PER_PART}) ORDER BY id
SETTINGS index_granularity={ROWS_PER_MARK}, index_granularity_bytes=10485760,
    enable_mixed_granularity_parts=1, compress_marks=0, compress_primary_key=0,
    min_compress_block_size=0, max_compress_block_size=4096,
    ratio_of_defaults_for_sparse_serialization=1, default_compression_codec='LZ4',
    serialization_info_version='with_types', propagate_types_serialization_versions_to_nested_types=1,
    string_serialization_version='with_size_stream', dynamic_serialization_version='v3',
    object_serialization_version='v3', object_shared_data_serialization_version='advanced',
    object_shared_data_serialization_version_for_zero_level_parts='advanced',
    object_shared_data_buckets_for_compact_part=2, write_marks_for_substreams_in_compact_parts=1,
    nullable_serialization_version='basic', map_serialization_version='basic',
    map_serialization_version_for_zero_level_parts='basic', min_rows_for_wide_part=1000000,
    min_bytes_for_wide_part=0
"""


def fixture_row(row_id: int, shared_overflow: bool = False) -> str:
    doc = {
        "tenant_id": row_id % 1000,
        "title": f"title-{row_id:06d}",
        "rank": None if row_id % 7 == 0 else row_id % 32768,
        "dynamic_value": f"dv-{row_id % 19:02d}" if row_id % 2 == 0 else row_id % 4096,
        "dynamic_flag": row_id % 2 == 0,
    }
    if shared_overflow:
        for path_index in range(5):
            doc[f"overflow_{path_index}"] = f"spill-{path_index}-{row_id % 43:02d}"
    events = [
        {"a": row_id % 50000, "b": f"event-{row_id % 13:02d}-a"},
        {"a": row_id % 20000, "b": f"event-{row_id % 17:02d}-b"},
    ]
    if row_id % 3 == 0:
        events.append({"a": (row_id + 7) % 50000, "b": f"event-{row_id % 11:02d}-c"})
    attrs = {"k0": [row_id % 10000, None], "k1": [None, None if row_id % 4 == 0 else row_id * 7 % 100000]}
    return json.dumps({"id": row_id, "doc": doc, "events": events, "attrs": attrs},
                      sort_keys=True, separators=(",", ":"))


def build(port: int, output: Path, part_count: int, shared_overflow: bool = False) -> None:
    version = query(port, "SELECT version()").decode().strip()
    if version != "26.10.1.1201":
        raise RuntimeError(f"expected ClickHouse 26.10.1.1201, got {version}")
    output.mkdir(parents=True, exist_ok=False)
    request(port, "/?merge_tree_use_v1_object_and_dynamic_serialization=0&flatten_nested=0", DDL)
    query(port, f"SYSTEM STOP MERGES {TABLE}")
    for part_index in range(part_count):
        first = part_index * ROWS_PER_PART
        payload = "\n".join(fixture_row(row_id, shared_overflow) for row_id in range(first, first + ROWS_PER_PART))
        query(port, f"INSERT INTO {TABLE} FORMAT JSONEachRow\n{payload}\n")

    parts = [json.loads(line) for line in query(port, """
        SELECT name, path, part_type, rows, marks FROM system.parts
        WHERE active AND database='default' AND table='compact_json_scan_bench'
        ORDER BY partition FORMAT JSONEachRow
    """).splitlines()]
    if len(parts) != part_count:
        raise RuntimeError(f"expected {part_count} active parts, got {len(parts)}")
    for part_index, part in enumerate(parts):
        if (part["part_type"], int(part["rows"]), int(part["marks"])) != ("Compact", 8192, 5):
            raise RuntimeError(f"unexpected part geometry: {part}")
        destination = output / part["name"]
        shutil.copytree(part["path"], destination)
        if not (destination / "data.mrk4").is_file():
            raise RuntimeError(f"no plain MRK4 marks in {destination}")
        first = part_index * ROWS_PER_PART
        oracle = destination.with_suffix(".rowbinary")
        oracle.write_bytes(query(port, f"""
            SELECT id, toJSONString(doc) FROM {TABLE}
            WHERE id >= {first} AND id < {first + ROWS_PER_PART} ORDER BY id
            SETTINGS checksum_on_read=1 FORMAT RowBinary
        """))
        destination.with_suffix(".tenant.rowbinary").write_bytes(query(port, f"""
            SELECT id, doc.tenant_id FROM {TABLE}
            WHERE id >= {first} AND id < {first + ROWS_PER_PART} ORDER BY id
            SETTINGS checksum_on_read=1 FORMAT RowBinary
        """))
        destination.with_suffix(".events.rowbinary").write_bytes(query(port, f"""
            SELECT events FROM {TABLE}
            WHERE id >= {first} AND id < {first + ROWS_PER_PART} ORDER BY id
            SETTINGS checksum_on_read=1 FORMAT RowBinary
        """))
        print(json.dumps({"part": str(destination), "oracle": str(oracle), "oracle_sha256": sha256_path(oracle)}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True, help="HTTP port of a disposable loopback ClickHouse server")
    parser.add_argument("--output", type=Path, required=True, help="new directory for parts and oracles")
    parser.add_argument("--parts", type=int, choices=(1, 8), default=1)
    parser.add_argument("--shared-overflow", action="store_true",
                        help="add five JSON paths to exercise Advanced SharedData overflow")
    arguments = parser.parse_args()
    build(arguments.port, arguments.output, arguments.parts, arguments.shared_overflow)
