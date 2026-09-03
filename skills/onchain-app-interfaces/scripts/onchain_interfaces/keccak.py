"""Dependency-free Ethereum Keccak-256 and address helpers."""

from __future__ import annotations

import re
from typing import Union

BytesLike = Union[bytes, bytearray, memoryview]

_MASK_64 = (1 << 64) - 1
_RATE_BYTES = 136
_ROTATIONS = (
    0,
    1,
    62,
    28,
    27,
    36,
    44,
    6,
    55,
    20,
    3,
    10,
    43,
    25,
    39,
    41,
    45,
    15,
    21,
    8,
    18,
    2,
    61,
    56,
    14,
)
_ROUND_CONSTANTS = (
    0x0000000000000001,
    0x0000000000008082,
    0x800000000000808A,
    0x8000000080008000,
    0x000000000000808B,
    0x0000000080000001,
    0x8000000080008081,
    0x8000000000008009,
    0x000000000000008A,
    0x0000000000000088,
    0x0000000080008009,
    0x000000008000000A,
    0x000000008000808B,
    0x800000000000008B,
    0x8000000000008089,
    0x8000000000008003,
    0x8000000000008002,
    0x8000000000000080,
    0x000000000000800A,
    0x800000008000000A,
    0x8000000080008081,
    0x8000000000008080,
    0x0000000080000001,
    0x8000000080008008,
)
_SIGNATURE_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\(.*\)$", re.ASCII)
_ADDRESS_RE = re.compile(r"^[0-9a-fA-F]{40}$", re.ASCII)


def _rotate_left(value: int, amount: int) -> int:
    if amount == 0:
        return value
    return ((value << amount) | (value >> (64 - amount))) & _MASK_64


def _keccak_f1600(state: list) -> None:
    for round_constant in _ROUND_CONSTANTS:
        columns = [
            state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            for x in range(5)
        ]
        deltas = [
            columns[(x - 1) % 5] ^ _rotate_left(columns[(x + 1) % 5], 1)
            for x in range(5)
        ]
        for y in range(5):
            for x in range(5):
                state[x + 5 * y] ^= deltas[x]

        lanes = [0] * 25
        for y in range(5):
            for x in range(5):
                lanes[y + 5 * ((2 * x + 3 * y) % 5)] = _rotate_left(
                    state[x + 5 * y], _ROTATIONS[x + 5 * y]
                )

        for y in range(5):
            row = 5 * y
            for x in range(5):
                state[row + x] = lanes[row + x] ^ (
                    (~lanes[row + (x + 1) % 5]) & lanes[row + (x + 2) % 5]
                )
                state[row + x] &= _MASK_64

        state[0] ^= round_constant


def keccak256(data: BytesLike) -> bytes:
    """Return the Ethereum Keccak-256 digest of a bytes-like value."""

    if not isinstance(data, (bytes, bytearray, memoryview)):
        raise TypeError("data must be bytes-like")
    value = bytes(data)
    padded = bytearray(value)
    padded.append(0x01)
    padded.extend(b"\x00" * ((_RATE_BYTES - len(padded) % _RATE_BYTES) % _RATE_BYTES))
    padded[-1] ^= 0x80

    state = [0] * 25
    for block_start in range(0, len(padded), _RATE_BYTES):
        block = padded[block_start : block_start + _RATE_BYTES]
        for index in range(_RATE_BYTES // 8):
            start = index * 8
            state[index] ^= int.from_bytes(block[start : start + 8], "little")
        _keccak_f1600(state)

    output = bytearray()
    while len(output) < 32:
        for index in range(_RATE_BYTES // 8):
            output.extend(state[index].to_bytes(8, "little"))
            if len(output) >= 32:
                break
        if len(output) < 32:
            _keccak_f1600(state)
    return bytes(output[:32])


def keccak256_hex(data: BytesLike) -> str:
    """Return an Ethereum Keccak-256 digest as a ``0x``-prefixed string."""

    return "0x" + keccak256(data).hex()


def function_selector(signature: str) -> bytes:
    """Return the four-byte selector for a canonical function/error signature."""

    if not isinstance(signature, str):
        raise TypeError("signature must be a string")
    if not _SIGNATURE_RE.fullmatch(signature) or any(
        character.isspace() for character in signature
    ):
        raise ValueError("signature must be canonical and contain no whitespace")
    try:
        encoded = signature.encode("ascii")
    except UnicodeEncodeError as error:
        raise ValueError("signature must contain only ASCII characters") from error
    return keccak256(encoded)[:4]


def function_selector_hex(signature: str) -> str:
    """Return a selector as an eight-digit ``0x``-prefixed string."""

    return "0x" + function_selector(signature).hex()


def _address_hex(address: str | BytesLike) -> str:
    if isinstance(address, str):
        value = address.removeprefix("0x")
        if not _ADDRESS_RE.fullmatch(value):
            raise ValueError("address must contain exactly 20 hexadecimal bytes")
        return value
    if isinstance(address, (bytes, bytearray, memoryview)):
        raw = bytes(address)
        if len(raw) != 20:
            raise ValueError("address must contain exactly 20 bytes")
        return raw.hex()
    raise TypeError("address must be a hexadecimal string or bytes-like value")


def to_checksum_address(address: str | BytesLike) -> str:
    """Return the EIP-55 representation of a 20-byte address."""

    lowercase = _address_hex(address).lower()
    digest = keccak256(lowercase.encode("ascii")).hex()
    checksummed = "".join(
        character.upper()
        if character in "abcdef" and int(digest[index], 16) >= 8
        else character
        for index, character in enumerate(lowercase)
    )
    return "0x" + checksummed


def is_checksum_address(address: object) -> bool:
    """Return whether a string is exactly its EIP-55 checksummed form."""

    if not isinstance(address, str) or not address.startswith("0x"):
        return False
    try:
        return address == to_checksum_address(address)
    except (TypeError, ValueError):
        return False


# Common spelling used by some Ethereum libraries.
keccak_256 = keccak256


__all__ = [
    "function_selector",
    "function_selector_hex",
    "is_checksum_address",
    "keccak256",
    "keccak256_hex",
    "keccak_256",
    "to_checksum_address",
]
