#!/usr/bin/env python3
"""Validate an existing, user-confirmed Hive receipt. Never calls an API or credential store."""
import argparse
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("receipt", type=Path)
args = parser.parse_args()
path = args.receipt
model = "hive/deepseek-ai/deepseek-v4.1-flash-1017"
fields = {"requestedModel", "observedModel", "thinkingLevel", "reasoningObserved", "toolResultRoundTrip", "streamSettled", "exitCode", "remainingProcessIDs"}
try:
    if path.name != "latest.json" or path.parent.name != "hive-verification":
        raise ValueError()
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 8192:
            raise ValueError()
        raw = source.read(8193)
    receipt = json.loads(raw)
    if not isinstance(receipt, dict) or set(receipt) != fields:
        raise ValueError()
    if not (receipt["requestedModel"] == model and receipt["observedModel"] == model
            and receipt["thinkingLevel"] == "high"
            and type(receipt["reasoningObserved"]) is bool
            and receipt["toolResultRoundTrip"] is True and receipt["streamSettled"] is True
            and type(receipt["exitCode"]) is int and receipt["exitCode"] == 0
            and receipt["remainingProcessIDs"] == []):
        raise ValueError()
except (OSError, ValueError, TypeError, KeyError):
    print("Existing Hive receipt validation failed; no API or credential access performed.", file=sys.stderr)
    sys.exit(1)

print(json.dumps({"check": "existing-user-confirmed-record-only", "freshAPICall": False,
                  "credentialAccess": False, "sha256": hashlib.sha256(raw).hexdigest(), **receipt}, sort_keys=True))
