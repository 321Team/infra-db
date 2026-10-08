"""Offline regression tests of the Python embedded in edge01-k3s.sh.

Only the heredoc is executed. Socket/TLS calls are replaced before execution;
no shell, sudo, PostgreSQL, credentials or network access is used.
"""

import contextlib
import io
from pathlib import Path
import socket
import ssl
import struct
import sys
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "edge01-k3s.sh"
SOURCE = SCRIPT.read_text(encoding="utf-8")
PROBE_CODE = compile(
    SOURCE.split("    python3 - \"$EXPECT\" <<'PY'\n", 1)[1].split("\nPY\n", 1)[0],
    str(SCRIPT) + ":hba-probe",
    "exec",
)
SRC = "10.1.93.50"
ENGLISH = 'no pg_hba.conf entry for host "%s", user "fds_app", database "fdsdb", SSL encryption'
# M from evidence#111, 02-probe.txt (PC source .29); substitute the socket source.
# https://github.com/321Team/fds-project-evidence/blob/6de84fe3e00d923b948a4709b0a9d7ee657a45d5/evidence/P1-DB-01/pg-hba-deny-20261004T1523Z/pc/02-probe.txt
KOREAN = '호스트 "%s", 사용자 "fds_app", 데이터베이스 "fdsdb", SSL 암호화 연결에 대한 설정이 pg_hba.conf 파일에 없습니다.'


def frame(kind, payload, length=None):
    return kind + struct.pack(">i", len(payload) + 4 if length is None else length) + payload


def error(message, state="28000"):
    return frame(b"E", b"SFATAL\0C" + state.encode() + b"\0M" + message.encode("utf-8") + b"\0\0")


SCRAM = frame(b"R", struct.pack(">i", 10) + b"SCRAM-SHA-256\0\0")


class FakeSocket:
    def __init__(self, data, source=SRC, chunk_size=None, recv_error=None):
        self.data = data
        self.source = source
        self.chunk_size = chunk_size
        self.recv_error = recv_error
        self.sent = []
        self.closed = False

    def recv(self, size):
        if not self.data and self.recv_error:
            raise self.recv_error
        if self.chunk_size:
            size = min(size, self.chunk_size)
        result, self.data = self.data[:size], self.data[size:]
        return result

    def sendall(self, data):
        self.sent.append(data)

    def settimeout(self, seconds):
        self.timeout = seconds

    def getsockname(self):
        return self.source, 50000

    def version(self):
        return "TLSv1.3-MOCK"

    def close(self):
        self.closed = True


class FakeContext:
    def __init__(self, tls_error=None):
        self.tls_error = tls_error

    def wrap_socket(self, sock):
        if self.tls_error:
            raise self.tls_error
        return sock


class HbaProbeTests(unittest.TestCase):
    def run_probe(self, data, expect="rejected", rc=4, result="INCONCLUSIVE",
                  source=SRC, chunk_size=None, recv_error=None,
                  connect_error=None, tls_error=None):
        sock = FakeSocket(data, source, chunk_size, recv_error)
        output = io.StringIO()
        with patch.object(socket, "create_connection", return_value=sock,
                          side_effect=connect_error) as connect, \
                patch.object(ssl, "create_default_context", return_value=FakeContext(tls_error)), \
                patch.object(sys, "argv", ["hba-probe", expect]), \
                contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as stopped:
                exec(PROBE_CODE, {"__name__": "__main__"})
        self.assertEqual(stopped.exception.code, rc, output.getvalue())
        self.assertIn("HBA_PROBE result=" + result + " ", output.getvalue())
        connect.assert_called_once_with(("10.1.93.55", 5432), timeout=5)
        # The probe may send only SSLRequest and StartupMessage, never a password.
        self.assertLessEqual(len(sock.sent), 2)
        if sock.sent:
            self.assertEqual(sock.sent[0], struct.pack(">ii", 8, 80877103))
        if len(sock.sent) == 2:
            startup = sock.sent[1]
            self.assertEqual(struct.unpack(">i", startup[:4])[0], len(startup))
            self.assertEqual(startup[4:8], struct.pack(">i", 196608))
            self.assertEqual(startup[8:].split(b"\0"), [
                b"user", b"fds_app", b"database", b"fdsdb",
                b"application_name", b"edge01-hba-probe", b"", b"",
            ])
            self.assertTrue(sock.closed)
        return sock

    def test_english_and_korean_no_entry(self):
        for message in (ENGLISH, KOREAN):
            for source in (SRC, "10.1.93.29"):
                with self.subTest(message=message, source=source):
                    self.run_probe(b"S" + error(message % source), source=source,
                                   rc=0, result="REJECTED")

    def test_scram_allowed(self):
        self.run_probe(b"S" + SCRAM, expect="allowed", rc=0, result="ALLOWED")

    def test_opposite_result_is_not_pass(self):
        self.run_probe(b"S" + SCRAM, rc=3, result="ALLOWED")
        for message in (ENGLISH, KOREAN):
            with self.subTest(message=message):
                self.run_probe(b"S" + error(message % SRC), expect="allowed",
                               rc=3, result="REJECTED")

    def test_source_user_database_and_ssl_must_match(self):
        for template in (ENGLISH, KOREAN):
            good = template % SRC
            for bad in (good.replace(SRC, "10.1.93.29"),
                        good.replace("fds_app", "other_user"),
                        good.replace("fdsdb", "other_db"),
                        good.replace("SSL encryption", "no encryption").replace("SSL 암호화", "암호화 안함")):
                with self.subTest(message=bad):
                    self.run_probe(b"S" + error(bad))

    def test_wrong_sqlstate(self):
        for state in ("28P01", "08006", ""):
            with self.subTest(state=state):
                self.run_probe(b"S" + error(KOREAN % SRC, state))

    def test_other_error_is_not_hba_rejection(self):
        for message in ("password authentication failed for user fds_app",
                        "role fds_app is not permitted to log in", "", "untranslated error"):
            with self.subTest(message=message):
                self.run_probe(b"S" + error(message))

    def test_missing_error_fields_or_terminator(self):
        for payload in (b"C28000\0\0", b"M" + (KOREAN % SRC).encode() + b"\0\0",
                        b"C28000\0M" + (KOREAN % SRC).encode() + b"\0"):
            with self.subTest(payload=payload):
                self.run_probe(b"S" + frame(b"E", payload))

    def test_fragmented_frames(self):
        for response, expect, result in ((SCRAM, "allowed", "ALLOWED"),
                                         (error(KOREAN % SRC), "rejected", "REJECTED")):
            with self.subTest(result=result):
                self.run_probe(b"S" + response, expect=expect, chunk_size=1, rc=0, result=result)

    def test_truncated_frames(self):
        for response in (b"", b"R\0\0", SCRAM[:-1], error(KOREAN % SRC)[:-1]):
            with self.subTest(response=response):
                self.run_probe(b"S" + response)

    def test_invalid_frame_lengths(self):
        for length in (-1, 0, 3, 65537):
            with self.subTest(length=length):
                self.run_probe(b"S" + frame(b"E", b"", length))

    def test_unsupported_authentication(self):
        for payload in (struct.pack(">i", 0), struct.pack(">i", 3), struct.pack(">i", 999),
                        struct.pack(">i", 10) + b"SCRAM-SHA-256-PLUS\0\0",
                        struct.pack(">i", 10) + b"SCRAM-SHA-256\0", b"\0"):
            with self.subTest(payload=payload):
                self.run_probe(b"S" + frame(b"R", payload), expect="allowed")

    def test_unknown_message(self):
        self.run_probe(b"S" + frame(b"Z", b"I"))

    def test_ssl_refusal_or_eof(self):
        for answer in (b"N", b"", b"?"):
            with self.subTest(answer=answer):
                sock = self.run_probe(answer)
                self.assertEqual(len(sock.sent), 1)

    def test_connection_or_tls_failure(self):
        self.run_probe(b"", connect_error=ConnectionRefusedError("MOCK"))
        self.run_probe(b"S", tls_error=ssl.SSLError("MOCK"))

    def test_timeout_is_inconclusive(self):
        self.run_probe(b"S", recv_error=TimeoutError("MOCK"))


if __name__ == "__main__":
    unittest.main()
