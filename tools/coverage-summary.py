#!/usr/bin/env python3
"""Write line and branch coverage totals to GITHUB_STEP_SUMMARY from kcov output."""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path


def load_coverage_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def line_totals(coverage_root: Path) -> tuple[int, int, float]:
    """Return (covered_lines, total_lines, percent) from kcov coverage.json files."""
    covered = 0
    total = 0
    for path in coverage_root.rglob("coverage.json"):
        data = load_coverage_json(path)
        if not data:
            continue
        covered += int(data.get("covered_lines", 0))
        total += int(data.get("total_lines", 0))
    if total == 0:
        return 0, 0, 0.0
    return covered, total, 100.0 * covered / total


def parse_line_js(path: Path) -> tuple[int, int]:
    """Parse kcov per-file JS (var data = {lines:[...]}) for branch hits."""
    text = path.read_text(encoding="utf-8", errors="replace")
    branch_line = re.compile(
        r'"hits"\s*:\s*"(\d+)"[^}]*"possible_hits"\s*:\s*"(\d+)"',
    )
    branch_covered = 0
    branch_total = 0
    for match in branch_line.finditer(text):
        hits = int(match.group(1))
        possible = int(match.group(2))
        branch_total += possible
        branch_covered += min(hits, possible)
    return branch_covered, branch_total


def branch_totals(coverage_root: Path) -> tuple[int, int, float]:
    covered = 0
    total = 0
    for path in coverage_root.rglob("*.js"):
        if path.name in ("index.js", "kcov.js"):
            continue
        if path.parent.name == "data":
            continue
        c, t = parse_line_js(path)
        covered += c
        total += t
    if total == 0:
        return 0, 0, 0.0
    return covered, total, 100.0 * covered / total


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <coverage-dir>", file=sys.stderr)
        return 2

    root = Path(sys.argv[1])
    if not root.is_dir():
        print(f"coverage directory not found: {root}", file=sys.stderr)
        return 1

    line_cov, line_tot, line_pct = line_totals(root)
    br_cov, br_tot, br_pct = branch_totals(root)

    md = (
        "## Code coverage\n\n"
        f"| Metric | Covered | Total | Percent |\n"
        f"|--------|---------|-------|--------|\n"
        f"| Lines | {line_cov} | {line_tot} | {line_pct:.2f}% |\n"
        f"| Branches | {br_cov} | {br_tot} | {br_pct:.2f}% |\n\n"
        "Download the **coverage-report** workflow artifact and open `index.html` "
        "for per-file line and branch detail.\n"
    )

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        Path(summary_path).write_text(md, encoding="utf-8")
    else:
        print(md)

    print(
        f"Line coverage: {line_pct:.2f}% ({line_cov}/{line_tot})",
        file=sys.stderr,
    )
    print(
        f"Branch coverage: {br_pct:.2f}% ({br_cov}/{br_tot})",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
