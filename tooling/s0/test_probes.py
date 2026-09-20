import copy
import hashlib
import hmac
import http.server
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid

from protocol_core import CHUNK, decimal, chunk_length, chunk_digest, manifest_digest, manifest_bytes, path_bytes, strict_json
import storage_probe as store

ROOT = Path(__file__).resolve().parent


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.vectors = json.loads((ROOT.parents[1] / "docs/protocol/vectors-v1.json").read_text())

    def test_fixed_vectors(self):
        for v in self.vectors:
            self.assertEqual(manifest_bytes(v["manifest"]).hex(), v["canonicalHex"])
            self.assertEqual(manifest_digest(v["manifest"]), v["manifestDigest"])
            self.assertEqual(chunk_digest(v["chunks"], int(v["manifest"]["files"][0]["sizeBytes"])),
                             v["manifest"]["files"][0]["chunkManifestDigest"])

    def test_standard_hash(self):
        self.assertEqual(self.vectors[1]["manifest"]["files"][0]["fileSha256"],
                         "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

    def test_key_order_and_whitespace(self):
        m = self.vectors[1]["manifest"]
        other = dict(reversed(list(m.items())))
        self.assertEqual(manifest_digest(strict_json(json.dumps(other, indent=4))), manifest_digest(m))

    def test_reject_duplicate_keys(self):
        with self.assertRaises(ValueError):
            strict_json('{"sizeBytes":"1","sizeBytes":"2"}')

    def test_json_depth_and_size_limits(self):
        for raw in ['['*17+'0'+']'*17, '"'+'x'*1048576+'"', '\ufeff{}']:
            with self.assertRaises(ValueError):
                strict_json(raw)

    def test_total_chunk_limit(self):
        m = copy.deepcopy(self.vectors[1]["manifest"])
        m["files"][0]["sizeBytes"] = str(1048577*CHUNK)
        m["files"][0]["chunkCount"] = "1048577"
        with self.assertRaisesRegex(ValueError, "CHUNK_RESOURCE_LIMIT"):
            manifest_bytes(m)

    def test_decimal_limits(self):
        self.assertEqual(decimal(str(2**63-1)), 2**63-1)
        for value in ["01", "+1", "-1", "1e3", "1.0", str(2**63), 1, True]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                decimal(value)

    def test_20gib_offsets_and_tail(self):
        self.assertEqual(5120 * CHUNK, 20 * 2**30)
        self.assertEqual(1024 * CHUNK, 2**32)
        self.assertEqual(chunk_length(20*2**30, 5119), CHUNK)
        self.assertEqual(chunk_length(CHUNK+3, 1), 3)
        with self.assertRaises(ValueError):
            chunk_length(0, 0)

    def test_path_rejections(self):
        for value in ["../x", "/x", "C:/x", "a\\b", "a:b", "a//b", "NUL.txt", "COM¹.txt", "a.", "a\x00", "e\u0301.txt"]:
            with self.subTest(value=value), self.assertRaises((ValueError, UnicodeError)):
                path_bytes(value)

    def test_unknown_fields_and_version(self):
        m = copy.deepcopy(self.vectors[0]["manifest"])
        m["extra"] = "ignored?"
        with self.assertRaises(ValueError):
            manifest_bytes(m)
        del m["extra"]
        m["protocolMajor"] = True
        with self.assertRaises(ValueError):
            manifest_bytes(m)

    def test_chunk_order_length(self):
        v = self.vectors[2]
        for chunks in [v["chunks"][::-1], v["chunks"][:1]]:
            with self.assertRaises(ValueError):
                chunk_digest(chunks, CHUNK+3)

    def test_file_count_limit_and_duplicate_id(self):
        m = copy.deepcopy(self.vectors[0]["manifest"])
        m["files"] *= 10001
        with self.assertRaisesRegex(ValueError, "FILE_COUNT"):
            manifest_bytes(m)
        m["files"] = m["files"][:2]
        with self.assertRaisesRegex(ValueError, "DUPLICATE_FILE_ID"):
            manifest_bytes(m)

    def test_accept_10000_manifest_entries(self):
        m = copy.deepcopy(self.vectors[0]["manifest"])
        sample = m["files"][0]
        m["files"] = [dict(sample, fileId=str(uuid.UUID(int=i+1)), relativePath=f"{i}.bin") for i in range(10000)]
        self.assertEqual(len(manifest_digest(m)), 64)


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.blocks = [b"A" * 4096, b"B" * 4096, b"tail"]
        store.init(self.root, self.blocks)

    def tearDown(self):
        self.tmp.cleanup()

    def crash(self, point):
        r = subprocess.run([sys.executable, str(ROOT / "storage_probe.py"), self.root, point], capture_output=True)
        self.assertIn(r.returncode, [91, 92, 93, 94], r.stderr)

    def finish_and_check(self):
        epoch = store.recover(self.root, "finish")
        present = store.committed(self.root)
        for i, b in enumerate(self.blocks):
            if i not in present:
                store.receive(self.root, i, b, epoch)
        self.assertEqual((Path(self.root)/"data.part").read_bytes(), b"".join(self.blocks))

    def test_crash_after_write(self):
        self.crash("after_write")
        self.assertEqual(store.committed(self.root), [])
        self.finish_and_check()

    def test_crash_after_sync(self):
        self.crash("after_sync")
        self.assertEqual(store.committed(self.root), [])
        self.finish_and_check()

    def test_crash_before_commit(self):
        self.crash("before_commit")
        self.assertEqual(store.committed(self.root), [])
        self.finish_and_check()

    def test_lost_ack_after_commit(self):
        self.crash("after_commit")
        self.assertEqual(store.committed(self.root), [0])
        self.assertEqual(store.receive(self.root, 0, self.blocks[0]), "already_committed")
        self.finish_and_check()

    def test_sync_failure_not_committed(self):
        with self.assertRaises(OSError):
            store.receive(self.root, 0, self.blocks[0], crash="sync_failure")
        self.assertEqual(store.committed(self.root), [])

    def test_corruption_selective_repair(self):
        for i, b in enumerate(self.blocks):
            store.receive(self.root, i, b)
        with open(Path(self.root) / "data.part", "r+b") as f:
            f.seek(4096)
            f.write(b"X")
            f.flush()
            os.fsync(f.fileno())
        epoch = store.recover(self.root, "recover-1")
        self.assertEqual(store.committed(self.root), [0, 2])
        store.receive(self.root, 1, self.blocks[1], epoch)
        self.assertEqual(hashlib.sha256((Path(self.root)/"data.part").read_bytes()).digest(),
                         hashlib.sha256(b"".join(self.blocks)).digest())

    def test_stale_writer_and_idempotent_resume(self):
        epoch = store.recover(self.root, "r1")
        self.assertEqual(store.recover(self.root, "r1"), epoch)
        with self.assertRaisesRegex(ValueError, "STALE_LEASE"):
            store.receive(self.root, 0, self.blocks[0], 1)
        self.assertEqual(store.committed(self.root), [])
        store.recover(self.root, "r2")
        with self.assertRaisesRegex(ValueError, "STALE_RESUME_REQUEST"):
            store.recover(self.root, "r1")

    def test_wrong_content_and_range(self):
        for index, data in [(0, b"bad"), (0, b"Z"*4096), (3, b"tail")]:
            with self.assertRaises(ValueError):
                store.receive(self.root, index, data)
        self.assertEqual(store.committed(self.root), [])


class TLSTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        d = Path(cls.tmp.name)
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=localhost", "-keyout", str(d/"key.pem"), "-out", str(d/"cert.pem")],
                       check=True, capture_output=True)
        cls.pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert((d/"cert.pem").read_text())).hexdigest()
        class Handler(http.server.BaseHTTPRequestHandler):
            def handle(self):
                try:
                    super().handle()
                except (BrokenPipeError, ConnectionResetError):
                    # Expected when the pinned client rejects the cert before HTTP.
                    self.server.peer_disconnects += 1
            def do_GET(self):
                self.server.requests_seen += 1
                self.send_response(200)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"ok")
            def log_message(self, *args):
                pass
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.server.requests_seen = 0
        cls.server.peer_disconnects = 0
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.load_cert_chain(d/"cert.pem", d/"key.pem")
        cls.server.socket = ctx.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.tmp.cleanup()

    def pinned_get(self, pin, maximum=None):
        # Dedicated test connection: authentication is exact DER pin BEFORE HTTP.
        # No global trust override; never reuse unverified sockets or contexts.
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2 if maximum else ssl.TLSVersion.TLSv1_3
        if maximum:
            ctx.maximum_version = maximum
        with socket.create_connection(self.server.server_address, timeout=5) as raw:
            with ctx.wrap_socket(raw, server_hostname="localhost") as conn:
                actual = hashlib.sha256(conn.getpeercert(binary_form=True)).hexdigest()
                if not hmac.compare_digest(actual, pin):
                    raise ValueError("PIN_MISMATCH")
                version = conn.version()
                conn.sendall(b"GET /probe HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                data = bytearray()
                while part := conn.recv(4096):
                    data.extend(part)
                return version, bytes(data)

    def test_tls13_correct_pin(self):
        version, data = self.pinned_get(self.pin)
        self.assertEqual(version, "TLSv1.3")
        self.assertTrue(data.endswith(b"ok"))

    def test_wrong_pin_sends_no_http(self):
        before = self.server.requests_seen
        with self.assertRaisesRegex(ValueError, "PIN_MISMATCH"):
            self.pinned_get("0"*64)
        self.assertEqual(before, self.server.requests_seen)

    def test_tls12_rejected(self):
        with self.assertRaises(ssl.SSLError):
            self.pinned_get(self.pin, ssl.TLSVersion.TLSv1_2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
