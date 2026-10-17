#!/usr/bin/env python3
"""Sends a STUN Binding request over UDP to each address on each port and checks
that a valid Binding success response comes back from the same address and port.

Usage: probe-stun.py [--wait SECONDS] [--ports 3478,3479] LABEL=IP [LABEL=IP ...]

Retries each probe until it succeeds or --wait runs out, because a freshly
replaced instance can take a moment to answer. Prints only the label and port,
never the address or what the server reports back: this runs in a public log.
Exit status is 0 only if every probe succeeded.
"""
import argparse
import os
import socket
import struct
import sys
import time

MAGIC_COOKIE = 0x2112A442
BINDING_REQUEST = 0x0001
BINDING_SUCCESS = 0x0101
MAPPED_ADDRESS = 0x0001
XOR_MAPPED_ADDRESS = 0x0020


def probe_once(ip, port, timeout):
    """Returns None on success, otherwise a short reason."""
    txid = os.urandom(12)
    request = struct.pack("!HHI", BINDING_REQUEST, 0, MAGIC_COOKIE) + txid
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(request, (ip, port))
        data, source = sock.recvfrom(2048)
    except socket.timeout:
        return "no response"
    except OSError as e:
        return "socket error: %s" % e.strerror
    finally:
        sock.close()

    if source != (ip, port):
        return "response came from a different address or port"
    if len(data) < 20:
        return "response too short"
    msg_type, msg_len, cookie = struct.unpack("!HHI", data[:8])
    if msg_type != BINDING_SUCCESS:
        return "not a Binding success response (type 0x%04x)" % msg_type
    if cookie != MAGIC_COOKIE or data[8:20] != txid:
        return "response does not match the request"
    if 20 + msg_len > len(data):
        return "truncated response"

    offset, end = 20, 20 + msg_len
    while offset + 4 <= end:
        attr_type, attr_len = struct.unpack("!HH", data[offset:offset + 4])
        if attr_type in (XOR_MAPPED_ADDRESS, MAPPED_ADDRESS):
            return None
        offset += 4 + attr_len + (-attr_len % 4)
    return "response carries no mapped address"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wait", type=float, default=60.0)
    parser.add_argument("--ports", default="3478,3479")
    parser.add_argument("targets", nargs="+", metavar="LABEL=IP")
    args = parser.parse_args()

    ports = [int(p) for p in args.ports.split(",")]
    targets = []
    for t in args.targets:
        label, sep, ip = t.partition("=")
        if not sep or not label or not ip:
            parser.error("target must be LABEL=IP: %r" % t)
        try:
            socket.inet_pton(socket.AF_INET, ip)  # a dotted-quad IPv4 literal only
        except OSError:
            parser.error("not an IPv4 address in %r" % label)
        targets.append((label, ip))

    deadline = time.monotonic() + args.wait
    ok = True
    for label, ip in targets:
        for port in ports:
            reason = "not tried"
            while True:
                reason = probe_once(ip, port, timeout=2.0)
                if reason is None or time.monotonic() >= deadline:
                    break
                time.sleep(2.0)
            if reason is None:
                print("  %s:%d OK" % (label, port))
            else:
                print("  %s:%d FAILED (%s)" % (label, port, reason))
                ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
