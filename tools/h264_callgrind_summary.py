#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Summarize Callgrind, resolving zero-sized NASM symbols through nm.

Usage: python3 h264_callgrind_summary.py PROFILE EXECUTABLE --annotate /path/to/callgrind_annotate
Counts are exclusive instruction counts; compiler/local suffixes are grouped.
"""
import argparse
import bisect
from collections import Counter
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=Path)
    parser.add_argument("executable", type=Path)
    parser.add_argument("--annotate", required=True, type=Path)
    args = parser.parse_args()
    executable = args.executable.resolve()
    symbols = {}
    output = subprocess.check_output(
        ["nm", "-n", "--defined-only", str(executable)], text=True)
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[1].lower() == "t":
            address = int(fields[0], 16)
            if address not in symbols or fields[2].startswith("ff_"):
                symbols[address] = fields[2]
    addresses = sorted(symbols)
    for line in args.profile.read_text().splitlines():
        if line.startswith(("events:", "summary:")):
            print(line)
    annotated = subprocess.check_output(
        ["perl", str(args.annotate), "--auto=no", "--show=Ir",
         "--show-percs=no", "--threshold=100", str(args.profile)], text=True)
    # With debug information, annotate splits one function across source
    # files and can omit the object name on subsequent rows. Resolve ownership
    # in a first pass: those rows may precede the explicitly named object.
    rows = []
    owners = {}
    for line in annotated.splitlines():
        match = re.match(r"^\s*([\d,]+)\s+\S+:(.+?)(?: \[([^]]+)\])?$", line)
        if match:
            count, name, obj = match.groups()
            rows.append((count, name, obj))
            if obj:
                owners.setdefault(name, set()).add(Path(obj).resolve())
    costs = Counter()
    for count, name, obj in rows:
        if obj:
            if Path(obj).resolve() != executable:
                continue
        elif owners.get(name) != {executable}:
            # Do not guess when the function occurs in multiple objects.
            continue
        if re.fullmatch(r"0x[0-9a-fA-F]+", name):
            index = bisect.bisect_right(addresses, int(name, 16)) - 1
            if index >= 0:
                name = symbols[addresses[index]]
        costs[name.split(".")[0]] += int(count.replace(",", ""))
    print("instructions,function")
    for name, count in costs.most_common():
        print(f"{count},{name}")


if __name__ == "__main__":
    main()
