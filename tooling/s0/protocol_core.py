"""S0 reference only. No HTTP server or platform adapter is implemented here."""
import hashlib
import json
import re
import struct
import unicodedata
import uuid

CHUNK = 4194304
MAX_I64 = 2**63 - 1


def decimal(value):
    if not isinstance(value, str) or not re.fullmatch(r"0|[1-9][0-9]{0,18}", value):
        raise ValueError("INVALID_DECIMAL")
    n = int(value)
    if n > MAX_I64:
        raise ValueError("INTEGER_OVERFLOW")
    return n


def hash_bytes(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ValueError("INVALID_HASH")
    return bytes.fromhex(value)


def id_bytes(value):
    if not isinstance(value, str) or str(uuid.UUID(value)) != value:
        raise ValueError("INVALID_ID")
    return uuid.UUID(value).bytes


def path_bytes(value):
    if not isinstance(value, str) or unicodedata.normalize("NFC", value) != value:
        raise ValueError("PATH_NOT_NFC")
    raw = value.encode("utf-8", errors="strict")
    if not 1 <= len(raw) <= 1024 or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("INVALID_PATH")
    if any(c in value for c in '\\:<>"|?*'):
        raise ValueError("INVALID_PATH")
    for part in value.split("/"):
        if not part or part in (".", "..") or part.endswith((" ", ".")):
            raise ValueError("INVALID_PATH")
        stem = part.split(".")[0].upper()
        if stem in {"CON", "PRN", "AUX", "NUL"} or re.fullmatch(r"(?:COM|LPT)[1-9¹²³]", stem):
            raise ValueError("RESERVED_PATH")
    return raw


def strict_json(raw):
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", errors="strict")
    if len(raw.encode("utf-8")) > 1048576 or raw.startswith("\ufeff"):
        raise ValueError("INVALID_JSON_SIZE_OR_BOM")
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("DUPLICATE_KEY")
            result[key] = value
        return result
    try:
        result = json.loads(raw, object_pairs_hook=pairs,
                            parse_constant=lambda v: (_ for _ in ()).throw(ValueError("NONFINITE")))
    except RecursionError as e:
        raise ValueError("JSON_DEPTH") from e
    def check(value, depth):
        if isinstance(value, (list, dict)):
            if depth > 16:
                raise ValueError("JSON_DEPTH")
            for child in (value.values() if isinstance(value, dict) else value):
                check(child, depth + 1)
    check(result, 1)
    return result


def chunk_length(size, index, chunk=CHUNK):
    count = (size + chunk - 1) // chunk
    if not 0 <= index < count:
        raise ValueError("CHUNK_RANGE")
    return min(chunk, size - index * chunk)


def chunk_digest(entries, size):
    count = (size + CHUNK - 1) // CHUNK
    if len(entries) != count:
        raise ValueError("CHUNK_COUNT")
    h = hashlib.sha256(b"LFTC1\0" + struct.pack(">Q", count))
    for i, e in enumerate(entries):
        if set(e) != {"index", "length", "sha256"}:
            raise ValueError("CHUNK_FIELDS")
        if decimal(e["index"]) != i or type(e["length"]) is not int or e["length"] != chunk_length(size, i):
            raise ValueError("CHUNK_LAYOUT")
        h.update(struct.pack(">QI", i, e["length"]) + hash_bytes(e["sha256"]))
    return h.hexdigest()


def manifest_bytes(m):
    if set(m) != {"protocolMajor", "protocolMinor", "transferId", "files"}:
        raise ValueError("MANIFEST_FIELDS")
    if type(m["protocolMajor"]) is not int or type(m["protocolMinor"]) is not int or (m["protocolMajor"], m["protocolMinor"]) != (1, 0):
        raise ValueError("PROTOCOL_VERSION")
    files = m["files"]
    if not isinstance(files, list) or not 1 <= len(files) <= 10000:
        raise ValueError("FILE_COUNT")
    result = bytearray(b"LFTM1\0" + struct.pack(">HH", 1, 0) + id_bytes(m["transferId"]) + struct.pack(">I", len(files)))
    seen = set()
    total = 0
    total_chunks = 0
    for f in files:
        if set(f) != {"fileId", "relativePath", "sizeBytes", "chunkSizeBytes", "chunkCount", "fileSha256", "chunkManifestDigest"}:
            raise ValueError("FILE_FIELDS")
        fid = id_bytes(f["fileId"])
        if fid in seen:
            raise ValueError("DUPLICATE_FILE_ID")
        seen.add(fid)
        raw = path_bytes(f["relativePath"])
        size, count = decimal(f["sizeBytes"]), decimal(f["chunkCount"])
        total_chunks += count
        if total_chunks > 1048576:
            raise ValueError("CHUNK_RESOURCE_LIMIT")
        total += size
        if total > MAX_I64:
            raise ValueError("TOTAL_OVERFLOW")
        if type(f["chunkSizeBytes"]) is not int or f["chunkSizeBytes"] != CHUNK or count != (size + CHUNK - 1) // CHUNK:
            raise ValueError("FILE_LAYOUT")
        if size == 0 and (f["fileSha256"] != hashlib.sha256(b"").hexdigest() or f["chunkManifestDigest"] != chunk_digest([], 0)):
            raise ValueError("EMPTY_DIGEST")
        result += fid + struct.pack(">I", len(raw)) + raw
        result += struct.pack(">QIQ", size, CHUNK, count)
        result += hash_bytes(f["fileSha256"]) + hash_bytes(f["chunkManifestDigest"])
    return bytes(result)


def manifest_digest(m):
    return hashlib.sha256(manifest_bytes(m)).hexdigest()
