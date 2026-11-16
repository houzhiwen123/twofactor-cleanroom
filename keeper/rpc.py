from __future__ import annotations

import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable


def safe_endpoint(url: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    host = parsed.hostname or ""
    if parsed.port:
        host = f"{host}:{parsed.port}"
    # Provider paths frequently embed API tokens.  Operational events only
    # need the transport/host identity, never a credential-bearing path.
    return urllib.parse.urlunsplit((parsed.scheme, host, "", "", ""))


def extract_revert_data(value: Any) -> str | None:
    if isinstance(value, str):
        match = re.search(r"0x[0-9a-fA-F]{8,}", value)
        return match.group(0).lower() if match else None
    if isinstance(value, dict):
        for key in ("data", "result", "return", "originalError", "error"):
            if key in value:
                found = extract_revert_data(value[key])
                if found:
                    return found
        for nested in value.values():
            found = extract_revert_data(nested)
            if found:
                return found
    if isinstance(value, list):
        for nested in value:
            found = extract_revert_data(nested)
            if found:
                return found
    return None


class RpcTransportError(RuntimeError):
    pass


class RpcResponseError(RuntimeError):
    def __init__(self, code: int, message: str, data: Any = None):
        super().__init__(f"JSON-RPC {code}: {message}")
        self.code = code
        self.message = message
        self.data = data
        self.revert_data = extract_revert_data(data) or extract_revert_data(message)

    @property
    def is_evm_revert(self) -> bool:
        return self.revert_data is not None or "revert" in self.message.lower()

    @property
    def revert_selector(self) -> str | None:
        if self.revert_data and len(self.revert_data) >= 10:
            return self.revert_data[:10].lower()
        return None


class HttpJsonRpcClient:
    def __init__(self, url: str, timeout_sec: float = 10.0):
        self.url = url
        self.timeout_sec = timeout_sec
        self._request_id = 0

    @property
    def endpoint(self) -> str:
        return safe_endpoint(self.url)

    def request(self, method: str, params: list[Any]) -> Any:
        self._request_id += 1
        body = json.dumps(
            {"jsonrpc": "2.0", "id": self._request_id, "method": method, "params": params},
            separators=(",", ":"),
        ).encode()
        request = urllib.request.Request(
            self.url,
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout_sec) as response:
                payload = json.loads(response.read())
        except urllib.error.HTTPError as exc:
            try:
                payload = json.loads(exc.read())
            except (OSError, json.JSONDecodeError) as decode_error:
                raise RpcTransportError(f"{self.endpoint}: HTTP {exc.code}") from decode_error
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
            raise RpcTransportError(f"{self.endpoint}: {type(exc).__name__}") from exc
        if not isinstance(payload, dict):
            raise RpcTransportError(f"{self.endpoint}: malformed JSON-RPC response")
        if "error" in payload:
            error = payload["error"]
            if not isinstance(error, dict):
                raise RpcTransportError(f"{self.endpoint}: malformed JSON-RPC error")
            raise RpcResponseError(error.get("code", -32000), error.get("message", "RPC error"), error.get("data"))
        if "result" not in payload:
            raise RpcTransportError(f"{self.endpoint}: malformed JSON-RPC response")
        return payload["result"]


@dataclass
class RpcAttempt:
    endpoint: str
    error: str


class RpcPool:
    """Read-only RPC failover.

    Deterministic EVM reverts are returned to the caller and never retried on
    another provider. Transport/provider failures rotate through the pool once.
    """

    def __init__(
        self,
        clients: list[Any],
        on_failover: Callable[[RpcAttempt], None] | None = None,
        *,
        max_attempts: int | None = None,
        base_backoff_sec: float = 0.25,
        sleep: Callable[[float], None] = time.sleep,
    ):
        if not clients:
            raise ValueError("at least one read RPC client is required")
        self.clients = clients
        self.on_failover = on_failover
        self.max_attempts = max_attempts or len(clients)
        if self.max_attempts <= 0 or base_backoff_sec < 0:
            raise ValueError("invalid read retry policy")
        self.base_backoff_sec = base_backoff_sec
        self.sleep = sleep
        self._cursor = 0

    def request(self, method: str, params: list[Any]) -> Any:
        failures: list[str] = []
        for attempt in range(self.max_attempts):
            index = (self._cursor + attempt) % len(self.clients)
            client = self.clients[index]
            try:
                result = client.request(method, params)
                self._cursor = index
                return result
            except RpcResponseError as exc:
                if exc.is_evm_revert or exc.code in (-32600, -32601, -32602):
                    raise
                failure = f"{client.endpoint}: rpc {exc.code}"
            except RpcTransportError as exc:
                failure = str(exc)
            failures.append(failure)
            if self.on_failover:
                self.on_failover(RpcAttempt(client.endpoint, failure))
            if attempt + 1 < self.max_attempts and self.base_backoff_sec:
                self.sleep(self.base_backoff_sec * (2 ** min(attempt, 4)))
        self._cursor = (self._cursor + 1) % len(self.clients)
        raise RpcTransportError("all read RPC endpoints failed: " + "; ".join(failures))
