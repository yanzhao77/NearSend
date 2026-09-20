"""Local one-file storage experiment, NOT production storage/HTTP code.
Uses tiny chunks in crash tests for speed; protocol chunk size remains 4 MiB.
"""
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys


def connect(root):
    db = sqlite3.connect(Path(root) / "resume.sqlite", isolation_level=None)
    assert db.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
    db.execute("PRAGMA synchronous=FULL")
    return db


def init(root, blocks):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    with open(root / "data.part", "wb") as f:
        f.flush()
        os.fsync(f.fileno())
    db = connect(root)
    db.executescript("""
    CREATE TABLE meta(id INTEGER PRIMARY KEY CHECK(id=1), epoch INTEGER NOT NULL, seq INTEGER NOT NULL);
    INSERT INTO meta VALUES(1,1,0);
    CREATE TABLE chunks(i INTEGER PRIMARY KEY, off INTEGER, length INTEGER, hash TEXT, committed INTEGER DEFAULT 0);
    CREATE TABLE resumes(request TEXT PRIMARY KEY, epoch INTEGER NOT NULL);
    """)
    offset = 0
    for i, b in enumerate(blocks):
        db.execute("INSERT INTO chunks(i,off,length,hash) VALUES(?,?,?,?)", (i, offset, len(b), hashlib.sha256(b).hexdigest()))
        offset += len(b)
    db.close()


def receive(root, index, body, epoch=1, crash=None):
    db = connect(root)
    try:
        db.execute("BEGIN IMMEDIATE")
        current = db.execute("SELECT epoch FROM meta").fetchone()[0]
        if epoch != current:
            raise ValueError("STALE_LEASE")
        row = db.execute("SELECT off,length,hash,committed FROM chunks WHERE i=?", (index,)).fetchone()
        if row is None or len(body) != row[1] or hashlib.sha256(body).hexdigest() != row[2]:
            raise ValueError("CHUNK_MISMATCH")
        if row[3]:
            db.commit()
            return "already_committed"
        with open(Path(root) / "data.part", "r+b", buffering=0) as f:
            f.seek(row[0])
            view = memoryview(body)
            while view:
                n = f.write(view)
                if not n:
                    raise OSError("short write")
                view = view[n:]
            if crash == "after_write":
                os._exit(91)
            if crash == "sync_failure":
                raise OSError("injected fsync failure")
            os.fsync(f.fileno())
        if crash == "after_sync":
            os._exit(92)
        db.execute("UPDATE chunks SET committed=1 WHERE i=?", (index,))
        db.execute("UPDATE meta SET seq=seq+1")
        if crash == "before_commit":
            os._exit(93)
        db.commit()
        if crash == "after_commit":
            os._exit(94)
        return "committed"
    finally:
        db.close()


def recover(root, request):
    db = connect(root)
    try:
        db.execute("BEGIN IMMEDIATE")
        current = db.execute("SELECT epoch FROM meta").fetchone()[0]
        prior = db.execute("SELECT epoch FROM resumes WHERE request=?", (request,)).fetchone()
        if prior:
            if prior[0] != current:
                raise ValueError("STALE_RESUME_REQUEST")
            db.commit()
            return current
        with open(Path(root) / "data.part", "rb") as f:
            for i, off, length, digest in db.execute("SELECT i,off,length,hash FROM chunks WHERE committed=1").fetchall():
                f.seek(off)
                if hashlib.sha256(f.read(length)).hexdigest() != digest:
                    db.execute("UPDATE chunks SET committed=0 WHERE i=?", (i,))
        current += 1
        db.execute("UPDATE meta SET epoch=?, seq=seq+1", (current,))
        db.execute("INSERT INTO resumes VALUES(?,?)", (request, current))
        db.commit()
        return current
    finally:
        db.close()


def committed(root):
    db = connect(root)
    result = [r[0] for r in db.execute("SELECT i FROM chunks WHERE committed=1 ORDER BY i")]
    db.close()
    return result


if __name__ == "__main__":
    receive(sys.argv[1], 0, b"A" * 4096, crash=sys.argv[2])
