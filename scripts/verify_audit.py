#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verify the MemHouse audit hash chain without the MemHouse binary.

Reads the audit table as CSV on stdin. See docs/governance.md#verify-the-chain-independently
for the export query. Each event's hash is sha256 over its fields joined with 0x1f separators,
starting from the previous event's hash ("genesis" for the first).
"""
import csv
import hashlib
import sys

prev, n = "genesis", 0
for row in csv.DictReader(sys.stdin):
    parts = [prev, row["at"], row["actor"], row["action"], row["tenant"],
             row["subject"], row["memory_id"], row["detail"]]
    h = hashlib.sha256(b"".join(p.encode() + b"\x1f" for p in parts)).hexdigest()
    if row["prev_hash"] != prev or row["hash"] != h:
        sys.exit(f"chain broken at event {row['id']}")
    prev, n = row["hash"], n + 1
print(f"audit chain intact ({n} events), head {prev}")
