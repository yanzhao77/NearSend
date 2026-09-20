"""Synthetic local sequential write/fsync/read/hash probe. No network or export.
Temporary data auto-deleted; --gib 20 requires 25 GiB free. Not a sparse test.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import struct
import tempfile
import time


def run(gib):
    size = gib * 2**30
    if shutil.disk_usage(".").free < size + 5 * 2**30:
        raise RuntimeError("Need requested file size plus 5 GiB free")
    chunk = 4 * 2**20
    buf = bytearray(b"\xa5" * chunk)
    expected = hashlib.sha256()
    start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="large-probe-", dir=".") as d:
        path = Path(d) / "payload.bin"
        with path.open("wb", buffering=0) as f:
            for index in range(size // chunk):
                struct.pack_into(">Q", buf, 0, index)
                expected.update(buf)
                view = memoryview(buf)
                while view:
                    n = f.write(view)
                    if not n:
                        raise OSError("short write")
                    view = view[n:]
                if (index + 1) % 4 == 0:
                    os.fsync(f.fileno())
            os.fsync(f.fileno())
        write_seconds = time.monotonic() - start
        allocated = path.stat().st_blocks * 512
        assert path.stat().st_size == size
        actual = hashlib.sha256()
        read_start = time.monotonic()
        with path.open("rb", buffering=0) as f:
            while n := f.readinto(buf):
                actual.update(memoryview(buf)[:n])
        assert actual.digest() == expected.digest()
        return {"status": "passed", "sizeBytes": str(size), "allocatedBytes": str(allocated),
                "sha256": actual.hexdigest(), "write_sync_hash_seconds": round(write_seconds, 3),
                "read_hash_seconds": round(time.monotonic()-read_start, 3),
                "peak_rss_kib_linux": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                "chunkBytes": chunk, "syncEveryBytes": 4*chunk,
                "scope": "Linux local synthetic file, no network, no SQLite, no export, no power-loss test"}


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--gib", type=int, choices=[1, 20], required=True)
    p.add_argument("--output", required=True)
    args = p.parse_args()
    result = run(args.gib)
    Path(args.output).write_text(json.dumps(result, indent=2)+"\n")
    print(json.dumps(result))
