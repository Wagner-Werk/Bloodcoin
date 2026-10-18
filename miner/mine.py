#!/usr/bin/env python3
"""BCUS-Miner für normale Computer (CPU). Sucht Lösungen für BcusMining und reicht sie ein.

Braucht: Python 3.9+, `pip install pycryptodome`, Foundry (`cast`) und eine Wallet mit etwas ETH auf
Base für Gas. Die Belohnung geht an die Adresse, die einreicht; sie steckt im Hash.

    python3 miner/mine.py --rpc https://sepolia.base.org --mining 0x... --account miner

`--account` ist ein Foundry-Keystore (`cast wallet import miner --interactive`). Mit `--dry-run`
sucht der Miner nur und reicht nichts ein.

Ehrlich: Mit einer CPU ist man langsam. Sobald jemand mit Grafikkarten schürft, steigt die
Schwierigkeit, und eine CPU findet kaum noch etwas. Das ist bei Bitcoin genauso.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time

try:
    from Crypto.Hash import keccak
except ImportError:
    sys.exit("pycryptodome fehlt: pip install pycryptodome")


def keccak256(data: bytes) -> bytes:
    return keccak.new(digest_bits=256, data=data).digest()


def solution_hash(challenge: bytes, miner: bytes, nonce: int) -> int:
    """Gleich wie BcusMining.solutionHash: keccak256(abi.encodePacked(challenge, miner, nonce))."""
    return int.from_bytes(keccak256(challenge + miner + nonce.to_bytes(32, "big")), "big")


def cast(*args: str) -> str:
    return subprocess.run(["cast", *args], check=True, capture_output=True, text=True).stdout.strip()


def read_state(rpc: str, mining: str) -> tuple[bytes, int]:
    challenge = bytes.fromhex(cast("call", mining, "challenge()(bytes32)", "--rpc-url", rpc)[2:])
    target = int(cast("call", mining, "currentTarget()(uint256)", "--rpc-url", rpc).split()[0])
    return challenge, target


def search(challenge: bytes, miner: bytes, target: int, start: int, count: int) -> int | None:
    for nonce in range(start, start + count):
        if solution_hash(challenge, miner, nonce) <= target:
            return nonce
    return None


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rpc", required=True)
    ap.add_argument("--mining", required=True, help="Adresse des BcusMining-Contracts")
    ap.add_argument("--account", help="Foundry-Keystore zum Einreichen")
    ap.add_argument("--address", help="eigene Adresse (nur mit --dry-run nötig)")
    ap.add_argument("--batch", type=int, default=200_000, help="Versuche zwischen zwei Abfragen")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    if a.dry_run:
        if not a.address:
            sys.exit("--dry-run braucht --address")
        me = a.address
    else:
        if not a.account:
            sys.exit("--account fehlt")
        me = cast("wallet", "address", "--account", a.account)
    miner = bytes.fromhex(me[2:].rjust(40, "0"))

    nonce = int.from_bytes(os.urandom(8), "big")     # zufälliger Start, damit zwei Miner nicht dasselbe suchen
    while True:
        challenge, target = read_state(a.rpc, a.mining)
        t0 = time.time()
        found = search(challenge, miner, target, nonce, a.batch)
        rate = a.batch / max(time.time() - t0, 1e-9)
        nonce += a.batch
        if found is None:
            print(f"{rate:,.0f} Hashes/s, noch nichts gefunden", flush=True)
            continue
        print(f"Lösung gefunden: nonce {found}", flush=True)
        if a.dry_run:
            return
        if read_state(a.rpc, a.mining)[0] != challenge:
            print("Jemand war schneller, neue Aufgabe", flush=True)
            continue
        out = cast("send", a.mining, "mine(uint256)", str(found), "--rpc-url", a.rpc, "--account", a.account)
        print(out, flush=True)


if __name__ == "__main__":
    main()
