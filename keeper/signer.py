from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any


ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
SELECTOR_RE = re.compile(r"^0x[0-9a-fA-F]{8}$")
HEX_QUANTITY_RE = re.compile(r"^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$")


class SignerBoundaryError(RuntimeError):
    pass


@dataclass(frozen=True)
class SignerPreflight:
    chain_id: int
    pending_nonce: int
    account_enumerated: bool

    def to_event(self, mode: str) -> dict[str, Any]:
        return {
            "event": "submission_preflight",
            "submissionMode": mode,
            "chainId": self.chain_id,
            "pendingNonce": self.pending_nonce,
            "accountEnumerated": self.account_enumerated,
        }


class ExternalSignerClient:
    """Narrow adapter for an RPC that signs outside the Keeper process.

    The wrapped endpoint may be a managed signer or an unlocked local Anvil
    account.  This class never accepts key material and exposes exactly one
    mutating JSON-RPC method: ``eth_sendTransaction``.
    """

    def __init__(self, transport: Any, from_address: str, mode: str):
        if mode not in ("managed-rpc", "local-unlocked"):
            raise ValueError("external signer requires an enabled submission mode")
        if not ADDRESS_RE.fullmatch(from_address):
            raise ValueError("external signer from address is invalid")
        self.transport = transport
        self.from_address = from_address.lower()
        self.mode = mode

    @staticmethod
    def _quantity(value: Any, field: str) -> int:
        if not isinstance(value, str) or not HEX_QUANTITY_RE.fullmatch(value):
            raise SignerBoundaryError(f"transaction {field} must be a canonical hex quantity")
        return int(value, 16)

    def preflight(self, expected_chain_id: int) -> SignerPreflight:
        chain_value = self.transport.request("eth_chainId", [])
        chain_id = self._quantity(chain_value, "chainId")
        if chain_id != expected_chain_id:
            raise SignerBoundaryError(
                f"submit endpoint chain ID mismatch: expected {expected_chain_id}, got {chain_id}"
            )
        nonce_value = self.transport.request("eth_getTransactionCount", [self.from_address, "pending"])
        pending_nonce = self._quantity(nonce_value, "pending nonce")
        enumerated = False
        if self.mode == "local-unlocked":
            accounts = self.transport.request("eth_accounts", [])
            if not isinstance(accounts, list) or not all(isinstance(account, str) for account in accounts):
                raise SignerBoundaryError("local unlocked submit endpoint returned malformed accounts")
            enumerated = self.from_address in {account.lower() for account in accounts}
            # Anvil --auto-impersonate intentionally permits unlisted accounts,
            # so enumeration is diagnostic and cannot prove signing authority.
        return SignerPreflight(chain_id, pending_nonce, enumerated)

    def request(self, method: str, params: list[Any]) -> Any:
        if method != "eth_sendTransaction":
            raise SignerBoundaryError(f"signer adapter forbids JSON-RPC method {method}")
        if not isinstance(params, list) or len(params) != 1 or not isinstance(params[0], dict):
            raise SignerBoundaryError("eth_sendTransaction requires one transaction object")
        transaction = params[0]
        allowed_fields = {"from", "to", "data", "gas"}
        unexpected = sorted(set(transaction) - allowed_fields)
        if unexpected:
            raise SignerBoundaryError("maintenance transaction contains forbidden fields: " + ", ".join(unexpected))
        sender = transaction.get("from")
        target = transaction.get("to")
        calldata = transaction.get("data")
        if not isinstance(sender, str) or sender.lower() != self.from_address:
            raise SignerBoundaryError("maintenance transaction sender does not match configured signer")
        if not isinstance(target, str) or not ADDRESS_RE.fullmatch(target):
            raise SignerBoundaryError("maintenance transaction target is invalid")
        if not isinstance(calldata, str) or not SELECTOR_RE.fullmatch(calldata):
            raise SignerBoundaryError("maintenance transaction must contain exactly one public function selector")
        gas = self._quantity(transaction.get("gas"), "gas")
        if gas <= 0:
            raise SignerBoundaryError("maintenance transaction gas must be positive")
        return self.transport.request(method, [dict(transaction)])
