from __future__ import annotations

import hashlib
import hmac
import ipaddress
import json
import re
import time
import urllib.parse
from dataclasses import dataclass, field
from pathlib import PurePosixPath


class BoundaryViolation(ValueError):
    pass


def normalize_relative_path(value: str) -> str:
    decoded = urllib.parse.unquote(urllib.parse.unquote(value))
    if not decoded or "\x00" in decoded or "\\" in decoded or decoded.startswith("/"):
        raise BoundaryViolation("path must be a non-empty relative POSIX path")
    parts = PurePosixPath(decoded).parts
    if any(part in {"", ".", ".."} for part in parts):
        raise BoundaryViolation("path traversal segment is forbidden")
    normalized = "/".join(parts)
    if normalized != decoded:
        raise BoundaryViolation("path normalization changed the request")
    return normalized


def validate_outbound_url(value: str, allowed_hosts: set[str]) -> str:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise BoundaryViolation("outbound URL must use HTTPS without user info")
    host = parsed.hostname.rstrip(".").lower()
    if host not in {item.rstrip(".").lower() for item in allowed_hosts}:
        raise BoundaryViolation("outbound host is not allowlisted")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    if address is not None and (
        address.is_private
        or address.is_loopback
        or address.is_link_local
        or address.is_reserved
        or address.is_multicast
        or address.is_unspecified
    ):
        raise BoundaryViolation("non-public IP destinations are forbidden")
    if parsed.fragment:
        raise BoundaryViolation("fragments are not sent upstream")
    return urllib.parse.urlunsplit(parsed)


def redact(value: str) -> str:
    token_pattern = re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}|lin_api_[A-Za-z0-9]{20,}")
    bearer_pattern = re.compile(r"(?i)(authorization\s*:\s*bearer\s+)[^\s,;]+")
    redacted = token_pattern.sub("[REDACTED]", value)
    return bearer_pattern.sub(r"\1[REDACTED]", redacted)


@dataclass(frozen=True)
class Principal:
    tenant_id: str
    roles: frozenset[str]


def authorize_read(principal: Principal, resource_tenant_id: str) -> None:
    if principal.tenant_id != resource_tenant_id:
        raise BoundaryViolation("cross-tenant read is forbidden")
    if not ({"reader", "admin"} & principal.roles):
        raise BoundaryViolation("read role is required")


def sign(secret: bytes, timestamp: int, nonce: str, body: bytes) -> str:
    message = f"{timestamp}.{nonce}.".encode() + body
    return hmac.new(secret, message, hashlib.sha256).hexdigest()


@dataclass
class ReplayWindow:
    max_skew_seconds: int = 300
    seen: dict[str, int] = field(default_factory=dict)

    def verify(
        self,
        secret: bytes,
        timestamp: int,
        nonce: str,
        body: bytes,
        signature: str,
        now: int | None = None,
    ) -> None:
        current = int(time.time()) if now is None else now
        if abs(current - timestamp) > self.max_skew_seconds:
            raise BoundaryViolation("signature timestamp is outside the replay window")
        if nonce in self.seen:
            raise BoundaryViolation("nonce replay detected")
        expected = sign(secret, timestamp, nonce, body)
        if not hmac.compare_digest(expected, signature):
            raise BoundaryViolation("signature mismatch")
        self.seen[nonce] = timestamp
        cutoff = current - self.max_skew_seconds
        self.seen = {key: seen_at for key, seen_at in self.seen.items() if seen_at >= cutoff}


_INVOCATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
_ERROR_CODE = re.compile(r"^[a-z][a-z0-9_.-]{0,127}$")


def validate_stdio_response(
    wire: bytes,
    expected_invocation_id: str,
    *,
    max_output_bytes: int = 1024 * 1024,
) -> dict[str, object]:
    """Fail-closed oracle for one `stdio-json-v1` InvocationResponse line.

    The production runner owns process I/O and timeout enforcement. This model
    captures the security boundary expected from that runner before a response
    is admitted: one bounded UTF-8 JSON line, sealed v1 object shapes, exact
    invocation identity, and bounded stable error metadata.
    """

    if not _INVOCATION_ID.fullmatch(expected_invocation_id):
        raise BoundaryViolation("expected invocation id is invalid")
    if max_output_bytes < 1 or len(wire) > max_output_bytes:
        raise BoundaryViolation("lambda stdout exceeded configured byte ceiling")
    if b"\x00" in wire:
        raise BoundaryViolation("lambda stdout contains NUL")
    if not wire.endswith(b"\n") or wire.count(b"\n") != 1:
        raise BoundaryViolation("lambda stdout must contain exactly one JSON line")

    try:
        text = wire[:-1].decode("utf-8", errors="strict")
        value = json.loads(text)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BoundaryViolation("lambda stdout is not valid UTF-8 JSON") from exc

    if not isinstance(value, dict) or set(value) != {"protocol", "invocationId", "result"}:
        raise BoundaryViolation("InvocationResponse must be a sealed object")
    if value["protocol"] != "stdio-json-v1":
        raise BoundaryViolation("unsupported invocation protocol")

    invocation_id = value["invocationId"]
    if not isinstance(invocation_id, str) or not _INVOCATION_ID.fullmatch(invocation_id):
        raise BoundaryViolation("response invocationId is invalid")
    if invocation_id != expected_invocation_id:
        raise BoundaryViolation("response invocationId does not match request")

    result = value["result"]
    if not isinstance(result, dict) or not isinstance(result.get("status"), str):
        raise BoundaryViolation("response result is invalid")
    if result["status"] == "ok":
        if set(result) != {"status", "payload"}:
            raise BoundaryViolation("InvocationSuccess must be a sealed object")
    elif result["status"] == "error":
        if set(result) != {"status", "error"} or not isinstance(result["error"], dict):
            raise BoundaryViolation("InvocationFailure must be a sealed object")
        error = result["error"]
        if set(error) != {"code", "message", "retryable"}:
            raise BoundaryViolation("InvocationError must be a sealed object")
        code = error["code"]
        message = error["message"]
        retryable = error["retryable"]
        if not isinstance(code, str) or not _ERROR_CODE.fullmatch(code):
            raise BoundaryViolation("InvocationError code is invalid")
        if not isinstance(message, str) or not 1 <= len(message) <= 4096:
            raise BoundaryViolation("InvocationError message is out of bounds")
        if not isinstance(retryable, bool):
            raise BoundaryViolation("InvocationError retryable must be boolean")
    else:
        raise BoundaryViolation("unknown invocation result status")

    return value
