#!/usr/bin/env python3
"""HTTP checker for the wisecow deployment.

Reports whether the service is up, how long it took, and -- when handed a CA --
whether the certificate actually validates. Standard library only, so it runs
anywhere Python 3 does without a pip install.

Exit codes: 0 up, 1 down, 2 bad arguments.
"""

from __future__ import annotations

import argparse
import http.client
import json
import socket
import ssl
import sys
import time
from dataclasses import dataclass, field
from urllib.parse import urlsplit

USER_AGENT = "wisecow-health-checker/1.0"


@dataclass
class Attempt:
    ok: bool
    status: int | None = None
    latency_ms: float = 0.0
    error: str | None = None
    cert_subject: str | None = None
    cert_issuer: str | None = None
    cert_expires: str | None = None
    body_snippet: str = ""


@dataclass
class Result:
    url: str
    attempts: list[Attempt] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return bool(self.attempts) and self.attempts[-1].ok

    @property
    def last(self) -> Attempt | None:
        return self.attempts[-1] if self.attempts else None


def _format_name(entries) -> str:
    """Flatten the nested tuple ssl.getpeercert() returns for subject/issuer."""
    if not entries:
        return ""
    parts = []
    for rdn in entries:
        for key, value in rdn:
            parts.append(f"{key}={value}")
    return ", ".join(parts)


def check_once(url: str, timeout: float, insecure: bool, cacert: str | None,
               expect: int) -> Attempt:
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https"):
        raise ValueError(f"unsupported scheme: {parts.scheme}")
    if not parts.hostname:
        raise ValueError("url has no host")

    scheme = parts.scheme
    host = parts.hostname
    port = parts.port or (443 if scheme == "https" else 80)
    path = parts.path or "/"
    if parts.query:
        path = f"{path}?{parts.query}"

    context = None
    if scheme == "https":
        if insecure:
            context = ssl._create_unverified_context()
        elif cacert:
            context = ssl.create_default_context(cafile=cacert)
        else:
            context = ssl.create_default_context()

    connection_class = (
        http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
    )

    started = time.perf_counter()
    attempt = Attempt(ok=False)
    try:
        if scheme == "https":
            conn = connection_class(host, port, timeout=timeout, context=context)
        else:
            conn = connection_class(host, port, timeout=timeout)

        conn.request("GET", path, headers={
            "User-Agent": USER_AGENT,
            # The server closes the socket itself; asking for close keeps the
            # response framing unambiguous since there is no Content-Length.
            "Connection": "close",
        })
        response = conn.getresponse()
        body = response.read(4096)
        attempt.latency_ms = (time.perf_counter() - started) * 1000
        attempt.status = response.status
        attempt.ok = response.status == expect
        if not attempt.ok:
            attempt.error = f"expected {expect}, got {response.status}"

        # A printable cowsay line is the cheapest proof the app, not just the
        # ingress, answered.
        text = body.decode("utf-8", "replace")
        for line in text.splitlines():
            stripped = line.strip()
            if stripped and "<pre>" not in stripped:
                attempt.body_snippet = stripped[:60]
                break

        if scheme == "https" and not insecure:
            cert = getattr(conn, "sock", None)
            cert = cert.getpeercert() if cert else None
            if cert:
                attempt.cert_subject = _format_name(cert.get("subject"))
                attempt.cert_issuer = _format_name(cert.get("issuer"))
                attempt.cert_expires = cert.get("notAfter")

        conn.close()
    except ssl.SSLCertVerificationError as exc:
        attempt.latency_ms = (time.perf_counter() - started) * 1000
        attempt.error = f"TLS verification failed: {exc.verify_message}"
    except socket.timeout:
        attempt.latency_ms = (time.perf_counter() - started) * 1000
        attempt.error = f"timed out after {timeout}s"
    except ConnectionRefusedError:
        attempt.latency_ms = (time.perf_counter() - started) * 1000
        attempt.error = "connection refused"
    except (OSError, http.client.HTTPException) as exc:
        attempt.latency_ms = (time.perf_counter() - started) * 1000
        attempt.error = f"{type(exc).__name__}: {exc}"

    return attempt


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check whether the wisecow service is up.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--url", default="https://wisecow.test",
                        help="URL to check")
    parser.add_argument("--timeout", type=float, default=5.0,
                        help="per-request timeout in seconds")
    parser.add_argument("--retries", type=int, default=2,
                        help="extra attempts after the first failure")
    parser.add_argument("--interval", type=float, default=2.0,
                        help="seconds between attempts")
    parser.add_argument("--expect", type=int, default=200,
                        help="expected HTTP status")
    parser.add_argument("--max-latency", type=float, default=0.0,
                        help="warn above this many milliseconds (0 disables)")
    parser.add_argument("--cacert", help="CA bundle used to verify the server")
    parser.add_argument("--insecure", action="store_true",
                        help="skip certificate verification")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()

    if args.retries < 0:
        parser.error("--retries cannot be negative")

    result = Result(url=args.url)
    total_attempts = args.retries + 1

    for index in range(total_attempts):
        attempt = check_once(args.url, args.timeout, args.insecure,
                             args.cacert, args.expect)
        result.attempts.append(attempt)
        if attempt.ok:
            break
        if index < total_attempts - 1:
            time.sleep(args.interval)

    slow = False
    if result.ok and args.max_latency > 0 and result.last:
        slow = result.last.latency_ms > args.max_latency

    if args.json:
        payload = {
            "url": result.url,
            "up": result.ok,
            "slow": slow,
            "attempts": [a.__dict__ for a in result.attempts],
        }
        print(json.dumps(payload, indent=2))
    else:
        print(f"target  {result.url}")
        print(f"attempts {len(result.attempts)}")
        last = result.last
        if last:
            print(f"latency {last.latency_ms:.1f} ms")
            if last.status is not None:
                print(f"status  {last.status}")
            if last.cert_subject:
                print(f"subject {last.cert_subject}")
            if last.cert_issuer:
                print(f"issuer  {last.cert_issuer}")
            if last.cert_expires:
                print(f"expires {last.cert_expires}")
            if last.body_snippet:
                print(f"body    {last.body_snippet}")
            if last.error:
                print(f"error   {last.error}")
        print(f"result  {'UP' if result.ok else 'DOWN'}")
        if slow:
            print(f"warning latency above {args.max_latency:.0f} ms")

    if not result.ok:
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(1)
