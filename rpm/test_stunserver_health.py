"""Runs stunserver-health for real against a fake instance-metadata service, fake STUN
responders and a stub aws CLI. Needs nothing but python3.

Run: python3 -I rpm/test_stunserver_health.py
"""
import http.server
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stunserver-health")
MAGIC = 0x2112A442


def free_port(kind):
    s = socket.socket(socket.AF_INET, kind)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class FakeImds:
    """Serves the metadata paths the script reads; fields can be changed live."""

    def __init__(self, stun_ports):
        self.public = {0: "203.0.113.1", 1: "203.0.113.2"}
        self.delay = 0.0
        self.down = False
        imds = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, body=b""):
                self.send_response(code)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_PUT(self):
                if imds.down:
                    return self._send(500)
                self._send(200, b"tok")

            def do_GET(self):
                time.sleep(imds.delay)
                if imds.down:
                    return self._send(500)
                p = self.path.split("/latest/meta-data/", 1)[1]
                macs = {"aa:aa": 0, "bb:bb": 1}
                if p == "network/interfaces/macs/":
                    return self._send(200, b"aa:aa/\nbb:bb/\n")
                if p == "instance-id":
                    return self._send(200, b"i-0test")
                if p == "placement/region":
                    return self._send(200, b"us-test-1")
                for mac, dev in macs.items():
                    pre = "network/interfaces/macs/%s/" % mac
                    if p == pre + "device-number":
                        return self._send(200, str(dev).encode())
                    if p == pre + "local-ipv4s":
                        return self._send(200, b"127.0.0.1")
                    if p == pre + "public-ipv4s":
                        ip = imds.public.get(dev)
                        return self._send(200, ip.encode()) if ip else self._send(404)
                self._send(404)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = "http://127.0.0.1:%d" % self.server.server_port
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()


class FakeStun:
    """A UDP responder on 127.0.0.1:port that answers Binding requests."""

    def __init__(self, port):
        self.port = port
        self.answering = True
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", port))
        self.sock.settimeout(0.2)
        self.stop = False
        threading.Thread(target=self.run, daemon=True).start()

    def run(self):
        while not self.stop:
            try:
                data, addr = self.sock.recvfrom(2048)
            except socket.timeout:
                continue
            if not self.answering or len(data) < 20:
                continue
            txid = data[8:20]
            attr = struct.pack("!HHBBH4s", 0x0020, 8, 0, 1, 0x1234 ^ (MAGIC >> 16), bytes(4))
            self.sock.sendto(struct.pack("!HHI", 0x0101, len(attr), MAGIC) + txid + attr, addr)

    def close(self):
        self.stop = True
        time.sleep(0.25)
        self.sock.close()


def http_get(port, raw=b"GET / HTTP/1.1\r\nHost: x\r\n\r\n", timeout=5):
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    s.sendall(raw)
    buf = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    s.close()
    return buf


def status_of(port):
    return http_get(port).split(b"\r\n", 1)[0]


class Harness(unittest.TestCase):
    env_extra = {}

    def setUp(self):
        self.p1, self.p2 = free_port(socket.SOCK_DGRAM), free_port(socket.SOCK_DGRAM)
        self.stun = [FakeStun(self.p1), FakeStun(self.p2)]
        self.imds = FakeImds([self.p1, self.p2])
        self.port = free_port(socket.SOCK_STREAM)
        self.tmp = tempfile.mkdtemp()
        self.aws_log = os.path.join(self.tmp, "aws.log")
        stub = os.path.join(self.tmp, "aws")
        with open(stub, "w") as f:
            f.write('#!/bin/sh\necho "$@" >> %s\n' % self.aws_log)
        os.chmod(stub, 0o755)
        env = dict(
            os.environ, STATUS_BIND="127.0.0.1", STATUS_PORT=str(self.port),
            PRIMARY_EIP="203.0.113.1", ALT_EIP="203.0.113.2",
            STUN_PORTS="%d,%d" % (self.p1, self.p2), CHECK_INTERVAL="0.3",
            UNHEALTHY_AFTER="1.5", STALE_AFTER="2", IMDS_BASE=self.imds.url, AWS_BIN=stub,
        )
        env.update(self.env_extra)
        self.proc = subprocess.Popen([sys.executable, "-I", SCRIPT], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.wait_listening()

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait(5)
        self.imds.close()
        for s in self.stun:
            s.close()

    def wait_listening(self):
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=0.2).close()
                return
            except OSError:
                time.sleep(0.1)
        self.fail("endpoint never started listening")

    def wait_for(self, want, secs=6):
        end = time.time() + secs
        while time.time() < end:
            try:
                if status_of(self.port) == want:
                    return
            except OSError:
                pass
            time.sleep(0.1)
        self.fail("never saw %r (last %r)" % (want, status_of(self.port)))

    def aws_calls(self):
        return open(self.aws_log).read().splitlines() if os.path.exists(self.aws_log) else []


OK = b"HTTP/1.1 200 OK"
BAD = b"HTTP/1.1 503 Service Unavailable"


class Tests(Harness):
    def test_healthy_serves_200_with_exact_headers_and_body(self):
        self.wait_for(OK)
        resp = http_get(self.port)
        head, body = resp.split(b"\r\n\r\n", 1)
        self.assertEqual(body, b"200 OK")
        self.assertIn(b"Content-Type: text/plain", head)
        self.assertIn(b"Content-Length: 6", head)
        self.assertEqual(self.aws_calls(), [], "must not self-report while healthy")

    def test_every_path_and_method_gets_the_same_answer(self):
        self.wait_for(OK)
        for raw in (b"GET /admin HTTP/1.1\r\n\r\n", b"POST / HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc",
                    b"\x00\xff garbage \r\n\r\n", b"GET /../../etc/passwd HTTP/1.0\r\n\r\n"):
            self.assertEqual(http_get(self.port, raw).split(b"\r\n", 1)[0], OK)

    def test_stun_down_gives_503_then_recovers(self):
        self.wait_for(OK)
        self.stun[1].answering = False
        self.wait_for(BAD)
        body = http_get(self.port).split(b"\r\n\r\n", 1)[1]
        self.assertEqual(body, b"503 Service Unavailable")
        self.stun[1].answering = True
        self.wait_for(OK)

    def test_wrong_eip_gives_503(self):
        self.wait_for(OK)
        self.imds.public[1] = "198.51.100.9"
        self.wait_for(BAD)
        self.imds.public[1] = "203.0.113.2"
        self.wait_for(OK)

    def test_missing_public_ip_gives_503(self):
        self.wait_for(OK)
        self.imds.public.pop(0)
        self.wait_for(BAD)

    def test_metadata_down_gives_503(self):
        self.wait_for(OK)
        self.imds.down = True
        self.wait_for(BAD)

    def test_hung_checker_goes_stale_and_fails_closed(self):
        self.wait_for(OK)
        self.imds.delay = 10  # every metadata read now stalls past STALE_AFTER
        self.wait_for(BAD, secs=8)

    def test_self_report_after_sustained_failure_with_correct_arguments(self):
        self.wait_for(OK)
        self.stun[0].answering = False
        end = time.time() + 8
        while time.time() < end and not self.aws_calls():
            time.sleep(0.1)
        calls = self.aws_calls()
        self.assertTrue(calls, "never self-reported")
        self.assertEqual(calls[0], "autoscaling set-instance-health --instance-id i-0test "
                         "--health-status Unhealthy --no-should-respect-grace-period --region us-test-1")

    def test_brief_failure_does_not_self_report(self):
        self.wait_for(OK)
        self.stun[0].answering = False
        self.wait_for(BAD)
        time.sleep(0.4)
        self.stun[0].answering = True
        self.wait_for(OK)
        time.sleep(2.5)
        self.assertEqual(self.aws_calls(), [])

    def test_idle_connections_do_not_block_real_requests(self):
        self.wait_for(OK)
        idle = [socket.create_connection(("127.0.0.1", self.port)) for _ in range(40)]
        t0 = time.time()
        self.assertEqual(status_of(self.port), OK)
        self.assertLess(time.time() - t0, 1.0, "a real request waited behind idle ones")
        # idle clients are answered/closed after ~2s, not held forever
        time.sleep(2.6)
        for s in idle:
            s.settimeout(1)
            self.assertTrue(s.recv(4096).startswith(b"HTTP/1.1 "))
            s.close()

    def test_oversized_request_is_dropped_and_service_unaffected(self):
        self.wait_for(OK)
        s = socket.create_connection(("127.0.0.1", self.port))
        s.settimeout(3)
        try:
            s.sendall(b"GET / HTTP/1.1\r\nX: " + b"a" * 100000 + b"\r\n\r\n")
            data = s.recv(4096)
        except (ConnectionResetError, BrokenPipeError):
            data = b""
        s.close()
        self.assertEqual(data, b"", "an oversized request must not be answered")
        self.assertEqual(status_of(self.port), OK)
        time.sleep(0.2)
        self.assertEqual(status_of(self.port), OK)


class CapTest(Harness):
    env_extra = {"MAX_CONNECTIONS": "5"}

    def test_connection_cap_drops_excess_without_hurting_service(self):
        self.wait_for(OK)
        held = [socket.create_connection(("127.0.0.1", self.port)) for _ in range(5)]
        time.sleep(0.2)
        extra = socket.create_connection(("127.0.0.1", self.port))
        extra.settimeout(1)
        self.assertEqual(extra.recv(4096), b"", "connection over the cap should be closed unanswered")
        extra.close()
        for s in held:
            s.close()
        time.sleep(0.3)
        self.assertEqual(status_of(self.port), OK)


class StartupTest(Harness):
    def setUp(self):
        # slow metadata so the very first check is still running when we ask
        self.p1, self.p2 = free_port(socket.SOCK_DGRAM), free_port(socket.SOCK_DGRAM)
        self.stun = [FakeStun(self.p1), FakeStun(self.p2)]
        self.imds = FakeImds([self.p1, self.p2])
        self.imds.delay = 1.0
        self.port = free_port(socket.SOCK_STREAM)
        self.tmp = tempfile.mkdtemp()
        env = dict(os.environ, STATUS_BIND="127.0.0.1", STATUS_PORT=str(self.port),
                   STUN_PORTS="%d,%d" % (self.p1, self.p2), CHECK_INTERVAL="0.3",
                   IMDS_BASE=self.imds.url)
        self.proc = subprocess.Popen([sys.executable, "-I", SCRIPT], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.wait_listening()

    def test_503_until_first_successful_check(self):
        self.assertEqual(status_of(self.port), BAD)
        self.imds.delay = 0
        self.wait_for(OK, secs=15)


class CheckModeTest(unittest.TestCase):
    def test_check_flag_exit_codes(self):
        p1, p2 = free_port(socket.SOCK_DGRAM), free_port(socket.SOCK_DGRAM)
        stun = [FakeStun(p1), FakeStun(p2)]
        imds = FakeImds([p1, p2])
        env = dict(os.environ, STUN_PORTS="%d,%d" % (p1, p2), IMDS_BASE=imds.url,
                   PRIMARY_EIP="203.0.113.1", ALT_EIP="203.0.113.2")
        r = subprocess.run([sys.executable, "-I", SCRIPT, "--check"], env=env, capture_output=True, text=True)
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "healthy"))
        stun[0].answering = False
        r = subprocess.run([sys.executable, "-I", SCRIPT, "--check"], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)
        self.assertIn("no response", r.stdout)
        imds.close()
        for s in stun:
            s.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
