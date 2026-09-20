"""Maintainer utility: regenerate only after reviewing a protocol change.
Consumers must compare to committed vectors, not regenerate before tests.

The output is written as UTF-8 explicitly: the vectors contain non-ASCII paths,
and letting the process locale decide would emit cp936 bytes on Windows and
produce a different file from the same inputs.
"""
import hashlib
import json
from pathlib import Path
from protocol_core import CHUNK, chunk_digest, manifest_bytes, manifest_digest

vectors = []
for name, path, payload in [("empty", "empty.bin", b""), ("abc_unicode", "资料/测试.txt", b"abc"),
                            ("tail", "tail.bin", b"a" * CHUNK + b"xyz")]:
    chunks = [{"index": str(i // CHUNK), "length": len(payload[i:i+CHUNK]),
               "sha256": hashlib.sha256(payload[i:i+CHUNK]).hexdigest()} for i in range(0, len(payload), CHUNK)]
    m = {"protocolMajor": 1, "protocolMinor": 0, "transferId": "00000000-0000-4000-8000-000000000001",
         "files": [{"fileId": "00000000-0000-4000-8000-000000000002", "relativePath": path,
                    "sizeBytes": str(len(payload)), "chunkSizeBytes": CHUNK, "chunkCount": str(len(chunks)),
                    "fileSha256": hashlib.sha256(payload).hexdigest(), "chunkManifestDigest": chunk_digest(chunks, len(payload))}]}
    vectors.append({"name": name, "manifest": m, "chunks": chunks,
                    "canonicalHex": manifest_bytes(m).hex(), "manifestDigest": manifest_digest(m)})
(Path(__file__).resolve().parents[2] / "docs/protocol/vectors-v1.json").write_text(
    json.dumps(vectors, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
