"""Local storage-only small-file experiment; excludes network, queue and UI."""
import hashlib
import json
import os
from pathlib import Path
import resource
import tempfile
import time


def run(count, size):
    started = time.monotonic()
    payload = b"x" * size
    expected = hashlib.sha256(payload).digest()
    with tempfile.TemporaryDirectory(prefix="small-probe-", dir=".") as tmp:
        root = Path(tmp)
        for i in range(count):
            with (root / f"{i:05}.bin").open("wb") as f:
                f.write(payload)
                f.flush()
                os.fsync(f.fileno())
        write = time.monotonic() - started
        start_read = time.monotonic()
        for i in range(count):
            p = root / f"{i:05}.bin"
            assert p.stat().st_size == size
            assert hashlib.sha256(p.read_bytes()).digest() == expected
        assert len(list(root.iterdir())) == count
        return {"status": "passed", "count": count, "size_each": size,
                "write_fsync_seconds": round(write, 3),
                "read_hash_seconds": round(time.monotonic()-start_read, 3),
                "peak_rss_kib_linux": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                "scope": "Linux local files only; NOT end-to-end small-file acceptance"}


if __name__ == "__main__":
    results = [run(1000, 4096), run(10000, 4096), run(100, 0)]
    Path("evidence/small-files.json").write_text(json.dumps(results, indent=2)+"\n")
    print(json.dumps(results))
