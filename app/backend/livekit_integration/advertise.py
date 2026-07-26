"""Advertise a LiveKit URL the client can actually reach.

Physical phones cannot use ws://localhost:7880 — they hit the API as
http://<lan-ip>:8801, so we rewrite localhost in LIVEKIT_URL to that LAN host.

iOS Simulator often resolves `localhost` to IPv6 (::1) while uvicorn/LiveKit
listen on IPv4 only — prefer 127.0.0.1 for local clients.
"""

from __future__ import annotations

from urllib.parse import urlparse, urlunparse

_LOCAL_HOSTS = frozenset({"localhost", "127.0.0.1", "::1"})


def _normalize_loopback(url: str) -> str:
    """Rewrite localhost / ::1 → 127.0.0.1 so IPv4-only listeners are reachable."""
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    if host not in ("localhost", "::1"):
        return url
    port = parsed.port
    netloc = f"127.0.0.1:{port}" if port else "127.0.0.1"
    return urlunparse(parsed._replace(netloc=netloc))


def advertise_livekit_url(configured_url: str, request_host: str | None) -> str:
    """
    If configured_url points at localhost/127.0.0.1 and the client reached the
    API via another host (LAN IP / hostname), rewrite the LiveKit URL host.

    Examples:
      configured=ws://localhost:7880, request_host=10.39.35.111:8801
        → ws://10.39.35.111:7880
      configured=ws://localhost:7880, request_host=localhost:8801
        → ws://127.0.0.1:7880  (IPv4 loopback for Simulator)
      configured=ws://localhost:7880, request_host=127.0.0.1:8801
        → ws://127.0.0.1:7880
    """
    if not configured_url:
        return configured_url

    if not request_host:
        return _normalize_loopback(configured_url)

    client_host = request_host.split(":")[0].strip().lower()
    if not client_host or client_host in _LOCAL_HOSTS:
        return _normalize_loopback(configured_url)

    parsed = urlparse(configured_url)
    if (parsed.hostname or "").lower() not in ("localhost", "127.0.0.1", "::1"):
        return configured_url

    port = parsed.port
    netloc = f"{client_host}:{port}" if port else client_host
    return urlunparse(parsed._replace(netloc=netloc))
