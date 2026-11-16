#!/usr/bin/env python3
"""Apply the benchmark-only ClickHouse instrumentation to its pinned source tree."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


PINNED_REVISION = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
PATCH_PATH = Path(__file__).resolve().with_name("clickhouse_read_rows_profile.patch")
TOUCHED_SOURCES = (
    "src/IO/ReadBufferFromFileDescriptor.cpp",
    "src/IO/OpenedFile.cpp",
    "src/Compression/CompressedReadBufferBase.cpp",
    "src/Compression/CompressedReadBufferFromFile.cpp",
    "src/Compression/CompressionCodecLZ4.cpp",
)


def git(source: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(source), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, help="disposable ClickHouse source checkout")
    parser.add_argument("--check-only", action="store_true", help="verify the pin and patch applicability without editing")
    args = parser.parse_args()
    source = args.source.resolve()

    revision = git(source, "rev-parse", "HEAD")
    if revision != PINNED_REVISION:
        raise SystemExit(f"expected ClickHouse {PINNED_REVISION}, got {revision}")

    for diff_args in (("diff", "--quiet", "--", *TOUCHED_SOURCES), ("diff", "--cached", "--quiet", "--", *TOUCHED_SOURCES)):
        subprocess.run(["git", "-C", str(source), *diff_args], check=True)

    subprocess.run(["git", "-C", str(source), "apply", "--check", str(PATCH_PATH)], check=True)
    if args.check_only:
        print(f"patch applies cleanly to pinned ClickHouse {revision}")
        return 0

    subprocess.run(["git", "-C", str(source), "apply", str(PATCH_PATH)], check=True)
    print(f"applied benchmark instrumentation to pinned ClickHouse {revision}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
