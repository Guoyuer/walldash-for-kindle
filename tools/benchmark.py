"""Summarize instrumented WallDash latency samples, in milliseconds."""

import argparse
from collections import defaultdict
import csv
import math
import os
from pathlib import Path
import statistics
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", nargs="?", type=Path, help="saved TSV instead of the Kindle's current log")
    parser.add_argument("--version", help="show only this deployed version")
    args = parser.parse_args()
    if args.log:
        body = args.log.read_text(encoding="utf-8")
    else:
        host = os.environ.get("KINDLE_SSH", "kindle")
        result = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "cat /tmp/deskdash_bench.tsv"],
            capture_output=True,
            text=True,
        )
        if result.returncode:
            parser.exit(1, "Cannot read benchmark samples. Connect the charger and run a sample first.\n"
                        + result.stderr)
        body = result.stdout

    samples = defaultdict(list)
    for _, version, kind, phase, elapsed in csv.reader(body.splitlines(), delimiter="\t"):
        if args.version is None or version == args.version:
            samples[version, kind, phase].append(float(elapsed))
    if not samples:
        parser.exit(1, "No matching benchmark samples.\n")

    print(f"{'version':<16} {'kind':<16} {'phase':<24} {'n':>4} {'median':>9} {'p95':>9} {'max':>9}")
    for (version, kind, phase), values in sorted(samples.items()):
        count = len(values)
        p95 = f"{sorted(values)[math.ceil(0.95 * count) - 1]:.1f}" if count >= 20 else "-"
        print(f"{version:<16} {kind:<16} {phase:<24} {count:>4} "
              f"{statistics.median(values):>9.1f} {p95:>9} {max(values):>9.1f}")


if __name__ == "__main__":
    main()
