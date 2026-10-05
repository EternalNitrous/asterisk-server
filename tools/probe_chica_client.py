#!/usr/bin/env python3
"""Exercise the same TCP handshake used by the original Chica Client."""

from __future__ import annotations

import argparse
import socket


def read_line(stream) -> str:
    raw = stream.readline()
    if not raw:
        raise RuntimeError("server closed before sending a response")
    return raw.decode("utf-8", errors="replace").rstrip("\r\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("host", help="Wi-Fi IPv4 address shown by AsteriskServer")
    parser.add_argument("--port", type=int, default=18711)
    args = parser.parse_args()

    with socket.create_connection((args.host, args.port), timeout=1.0) as connection:
        connection.settimeout(1.0)
        stream = connection.makefile("rwb", buffering=0)
        greeting = read_line(stream)
        if not greeting.startswith("ready:"):
            raise RuntimeError(f"unexpected greeting: {greeting!r}")
        stream.write(b"ack\n")
        reply = read_line(stream)
        if not (reply.startswith("ready:") or reply.startswith("busy:")):
            raise RuntimeError(f"unexpected ack response: {reply!r}")
        stream.write(b"bye\n")
    print(f"Chica Client protocol reachable at {args.host}:{args.port}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
