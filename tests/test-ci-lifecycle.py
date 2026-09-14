"""Regression coverage for the CI cold-restart lifecycle helper."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import textwrap
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LifecycleTests(unittest.TestCase):
    def test_stop_waits_for_port_and_kills_term_ignoring_server(self):
        source = (ROOT / "scripts/ci-verify.sh").read_text(encoding="utf-8")
        helper = source.split("# BEGIN ci lifecycle helper\n", 1)[1].split("# END ci lifecycle helper", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            server = folder / "server.py"
            server.write_text(textwrap.dedent("""
                import ctypes, signal, sys
                from http.server import BaseHTTPRequestHandler, HTTPServer
                ctypes.CDLL(None).prctl(15, b'llama-server', 0, 0, 0)
                signal.signal(signal.SIGTERM, lambda *_: None)
                class Handler(BaseHTTPRequestHandler):
                    def do_GET(self): self.send_response(200); self.end_headers()
                    def log_message(self, *_): pass
                HTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
            """))
            process = subprocess.Popen(["python3", str(server), str(port)])
            pid_file = folder / "llama.pid"
            pid_file.write_text(str(process.pid))
            try:
                for _ in range(20):
                    try:
                        socket.create_connection(("127.0.0.1", port), timeout=.1).close()
                        break
                    except OSError:
                        time.sleep(.05)
                else:
                    self.fail("test HTTP server did not start")
                result = subprocess.run(
                    ["bash", "-c", "set -euo pipefail\n" + helper + "\nci_stop_llama \"$1\" \"$2\"", "--", str(pid_file), str(port)],
                    env={**os.environ, "CI_STOP_TIMEOUT": "1"}, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIsNotNone(process.wait(timeout=2))
                self.assertFalse(pid_file.exists())
                with self.assertRaises(OSError):
                    socket.create_connection(("127.0.0.1", port), timeout=.1)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

    def test_stop_waits_for_delayed_server_that_keeps_responding(self):
        source = (ROOT / "scripts/ci-verify.sh").read_text(encoding="utf-8")
        helper = source.split("# BEGIN ci lifecycle helper\n", 1)[1].split("# END ci lifecycle helper", 1)[0]
        with tempfile.TemporaryDirectory() as directory, socket.socket() as probe:
            folder = Path(directory)
            probe.bind(("127.0.0.1", 0)); port = probe.getsockname()[1]
            probe.close()
            server = folder / "server.py"
            server.write_text(textwrap.dedent("""
                import ctypes, os, signal, sys, threading
                from http.server import BaseHTTPRequestHandler, HTTPServer
                ctypes.CDLL(None).prctl(15, b'llama-server', 0, 0, 0)
                signal.signal(signal.SIGTERM, lambda *_: threading.Timer(2, os._exit, args=(0,)).start())
                class Handler(BaseHTTPRequestHandler):
                    def do_GET(self): self.send_response(200); self.end_headers()
                    def log_message(self, *_): pass
                HTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
            """))
            process = subprocess.Popen(["python3", str(server), str(port)])
            pid_file = folder / "llama.pid"; pid_file.write_text(str(process.pid))
            try:
                time.sleep(.15)
                stopping = subprocess.Popen(["bash", "-c", "set -euo pipefail\n" + helper + "\nci_stop_llama \"$1\" \"$2\"", "--", str(pid_file), str(port)], env={**os.environ, "CI_STOP_TIMEOUT": "5"}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                time.sleep(.3)
                socket.create_connection(("127.0.0.1", port), timeout=.2).close()
                self.assertIsNone(stopping.poll(), "must wait while the old endpoint still responds")
                _, stderr = stopping.communicate(timeout=8)
                self.assertEqual(stopping.returncode, 0, stderr)
                self.assertNotIn("sending KILL", stderr)
                self.assertIsNotNone(process.wait(timeout=2))
            finally:
                if process.poll() is None: process.kill(); process.wait()

    def test_stale_pid_with_live_port_fails_without_killing_other_process(self):
        source = (ROOT / "scripts/ci-verify.sh").read_text(encoding="utf-8")
        helper = source.split("# BEGIN ci lifecycle helper\n", 1)[1].split("# END ci lifecycle helper", 1)[0]
        with tempfile.TemporaryDirectory() as directory, socket.socket() as probe:
            folder = Path(directory)
            probe.bind(("127.0.0.1", 0)); port = probe.getsockname()[1]
            probe.close()
            occupier = subprocess.Popen(["python3", "-m", "http.server", str(port), "--bind", "127.0.0.1"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            pid_file = folder / "llama.pid"; pid_file.write_text("99999999")
            try:
                time.sleep(.15)
                result = subprocess.run(["bash", "-c", "set -euo pipefail\n" + helper + "\nci_stop_llama \"$1\" \"$2\"", "--", str(pid_file), str(port)], env={**os.environ, "CI_STOP_TIMEOUT": "1"}, capture_output=True, text=True, timeout=9)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(occupier.poll(), "must not kill an unowned port occupier")
                socket.create_connection(("127.0.0.1", port), timeout=.2).close()
            finally:
                occupier.kill(); occupier.wait()


if __name__ == "__main__":
    unittest.main()
