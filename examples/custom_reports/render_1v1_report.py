#!/usr/bin/env python3
"""Example client renderer: turn `hugi compare-1v1 --format json` and
`hugi export --lang all --format json` into a custom grouped Markdown report
and optionally splice <!-- BEGIN_BENCHMARK_TABLE -->...<!-- END_BENCHMARK_TABLE -->.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

BEGIN_MARKER = "<!-- BEGIN_BENCHMARK_TABLE -->"
END_MARKER = "<!-- END_BENCHMARK_TABLE -->"


def run_hugi_json(hugi_bin: str, args: list[str]) -> object:
    proc = subprocess.run(
        [hugi_bin, *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(proc.stdout)


def fmt_ns(ns: float) -> str:
    if ns >= 1_000_000.0:
        return f"{ns / 1_000_000.0:.2f} ms"
    if ns >= 1_000.0:
        return f"{ns / 1_000.0:.2f} us"
    return f"{ns:.2f} ns"


def render_report(snap: list[dict], cmp_rep: dict) -> str:
    lines: list[str] = []
    la = cmp_rep["lang_a"]
    lb = cmp_rep["lang_b"]

    lines.append(
        f"### Cross-Language 1v1 (`{la}` vs `{lb}` — "
        f"{la} wins: {cmp_rep['a_wins']}, {lb} wins: {cmp_rep['b_wins']}, "
        f"ties: {cmp_rep['ties']}, footprint mismatches: {cmp_rep['footprint_mismatches']})"
    )
    lines.append("")
    lines.append(
        f"| Benchmark | `{la}` p50 (CV%) | `{lb}` p50 (CV%) | Winner | Speedup | p-value | Footprint |"
    )
    lines.append("| :--- | ---: | ---: | :--- | ---: | ---: | :--- |")

    for row in cmp_rep.get("rows", []):
        sig = "*" if row["is_significant"] else "~"
        mismatch = " **[MISMATCH]**" if row["footprint_mismatch"] else ""
        fp = f"{row['a_footprint_bytes']} B / {row['b_footprint_bytes']} B{mismatch}"
        lines.append(
            f"| `{row['full_name']}` | **{fmt_ns(float(row['a_p50_ns']))}** ({row['a_cv_pct']:.1f}%) "
            f"| **{fmt_ns(float(row['b_p50_ns']))}** ({row['b_cv_pct']:.1f}%) "
            f"| `{row['faster_lang']}` | {row['speedup_ratio']:.2f}x{sig} | {row['p_value']:.4f} | {fp} |"
        )

    by_lang: dict[str, list[dict]] = {}
    for rec in snap:
        by_lang.setdefault(rec["lang"], []).append(rec)

    for lang, rows in by_lang.items():
        lines.append("")
        lines.append(f"### Latest `{lang}` Snapshot ({len(rows)} benchmarks)")
        lines.append("")
        lines.append("| Benchmark | Group | Median | P95 | Ops/s | MB/s | CV% | Allocs/op |")
        lines.append("| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |")
        for r in rows:
            mb_s = f"{r['mb_per_sec']:.1f}" if r["bytes_per_op"] > 0 else "-"
            lines.append(
                f"| `{r['full_name']}` | `{r['group_name']}` | **{fmt_ns(float(r['p50_ns']))}** "
                f"| {fmt_ns(float(r['p95_ns']))} | {r['ops_per_sec']:.0f} | {mb_s} "
                f"| {r['cv_pct']:.1f}% | {r['allocs_per_op']:.1f} |"
            )

    return "\n".join(lines) + "\n"


def update_markers(readme_path: Path, body: str) -> None:
    text = readme_path.read_text(encoding="utf-8")
    b_idx = text.find(BEGIN_MARKER)
    e_idx = text.find(END_MARKER, b_idx + len(BEGIN_MARKER)) if b_idx >= 0 else -1
    if b_idx < 0 or e_idx < 0:
        raise ValueError(f"missing {BEGIN_MARKER} .. {END_MARKER} in {readme_path}")
    after_begin = b_idx + len(BEGIN_MARKER)
    updated = f"{text[:after_begin]}\n{body.strip()}\n{text[e_idx:]}"
    readme_path.write_text(updated, encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="benchmarks/history.hugidb")
    ap.add_argument("--langs", default="odin,zig")
    ap.add_argument("--hugi-bin", default="hugi")
    ap.add_argument("--update-readme", default="")
    args = ap.parse_args()

    snap = run_hugi_json(
        args.hugi_bin,
        ["export", "--db", args.db, "--lang", "all", "--format", "json", "--out", "-"],
    )
    cmp_rep = run_hugi_json(
        args.hugi_bin,
        ["compare-1v1", "--db", args.db, "--langs", args.langs, "--format", "json", "--out", "-"],
    )
    assert isinstance(snap, list) and isinstance(cmp_rep, dict)
    md = render_report(snap, cmp_rep)

    if args.update_readme:
        update_markers(Path(args.update_readme), md)
        print(f"Updated {args.update_readme}")
    else:
        sys.stdout.write(md)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
