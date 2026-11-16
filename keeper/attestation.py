from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

from .config import ContractAttestation


EIP1967_IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
STORAGE_WORD_RE = re.compile(r"^0x[0-9a-fA-F]{64}$")


@dataclass(frozen=True)
class ObservedContractIdentity:
    proxy: str
    proxy_code_hash: str
    proxy_code_bytes: int
    implementation: str
    implementation_code_hash: str
    implementation_code_bytes: int

    @property
    def attestation(self) -> ContractAttestation:
        return ContractAttestation(
            self.proxy_code_hash,
            self.implementation,
            self.implementation_code_hash,
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "proxy": self.proxy.lower(),
            "proxyCodeHash": self.proxy_code_hash,
            "proxyCodeBytes": self.proxy_code_bytes,
            "implementation": self.implementation,
            "implementationCodeHash": self.implementation_code_hash,
            "implementationCodeBytes": self.implementation_code_bytes,
        }


def _runtime_code(rpc: Any, address: str, block_tag: str, label: str) -> tuple[str, int]:
    code = rpc.request("eth_getCode", [address, block_tag])
    if not isinstance(code, str) or code in ("0x", "0x0") or not re.fullmatch(r"0x[0-9a-fA-F]+", code):
        raise RuntimeError(f"{label} has no valid runtime code")
    return code, max((len(code) - 2) // 2, 0)


def _code_hash(rpc: Any, address: str, block_tag: str, label: str) -> str:
    proof = rpc.request("eth_getProof", [address, [], block_tag])
    value = proof.get("codeHash") if isinstance(proof, dict) else None
    if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-fA-F]{64}", value):
        raise RuntimeError(f"{label} returned an invalid codehash proof")
    return value.lower()


def observe_contract_identity(
    rpc: Any,
    proxy: str,
    block_tag: str,
    *,
    proxy_code: str | None = None,
    expected: ContractAttestation | None = None,
    key: str = "contract",
) -> ObservedContractIdentity:
    if proxy_code is None:
        proxy_code, proxy_code_bytes = _runtime_code(rpc, proxy, block_tag, "proxy")
    elif not re.fullmatch(r"0x[0-9a-fA-F]+", proxy_code) or proxy_code in ("0x", "0x0"):
        raise RuntimeError("proxy has no valid runtime code")
    else:
        proxy_code_bytes = max((len(proxy_code) - 2) // 2, 0)
    proxy_hash = _code_hash(rpc, proxy, block_tag, "proxy")
    if expected is not None and proxy_hash != expected.proxy_code_hash:
        raise RuntimeError(f"proxy codehash mismatch for {key}")
    storage_value = rpc.request("eth_getStorageAt", [proxy, EIP1967_IMPLEMENTATION_SLOT, block_tag])
    if not isinstance(storage_value, str) or not STORAGE_WORD_RE.fullmatch(storage_value):
        raise RuntimeError("proxy returned an invalid EIP-1967 implementation slot")
    implementation = ("0x" + storage_value[-40:]).lower()
    if implementation == "0x" + "00" * 20:
        raise RuntimeError("proxy EIP-1967 implementation is the zero address")
    if expected is not None and implementation != expected.implementation.lower():
        raise RuntimeError(f"implementation address mismatch for {key}")
    _, implementation_code_bytes = _runtime_code(rpc, implementation, block_tag, "implementation")
    implementation_hash = _code_hash(rpc, implementation, block_tag, "implementation")
    if expected is not None and implementation_hash != expected.implementation_code_hash:
        raise RuntimeError(f"implementation codehash mismatch for {key}")
    return ObservedContractIdentity(
        proxy=proxy,
        proxy_code_hash=proxy_hash,
        proxy_code_bytes=proxy_code_bytes,
        implementation=implementation,
        implementation_code_hash=implementation_hash,
        implementation_code_bytes=implementation_code_bytes,
    )


def verify_contract_attestation(
    rpc: Any,
    key: str,
    proxy: str,
    expected: ContractAttestation,
    block_tag: str,
    *,
    proxy_code: str | None = None,
) -> ObservedContractIdentity:
    return observe_contract_identity(
        rpc,
        proxy,
        block_tag,
        proxy_code=proxy_code,
        expected=expected,
        key=key,
    )
