# `hugi` Documentation

Welcome to the technical documentation for **`hugi`**—a Git-native longitudinal benchmark runner, compressed historical store (`.hugidb`), statistical auditor, and multi-format exporter written in Odin.

---

## Architecture Overview

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                        Benchmark Producers                              │
│  • Odin `hugi.Suite` (Micro-Benchmarks + Multi-Phase Pipelines)         │
│  • External Harnesses (C / Zig / Rust / Go / Python -> .jsonl)          │
│  • Standalone `obench` JSON Reports (.json) & Wire Packets (.hpk)       │
└───────────────────────────────────┬─────────────────────────────────────┘
                                    │ Run_Packet (HPKT v2)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     Transactional `.hugidb` Store                       │
│  • `xitdb` Copy-on-Write Moments + RAM-only `Core_Overlay` Branches     │
│  • `HCAT` Root Catalog (Interned Symbols, Descriptors & Snapshots)      │
│  • `CZPK` Presence-Bitmasked Hot Runs  ──► Auto-Seals ──► `CZCH` Cold   │
│    Columnar Rollups + `BU` 5-Way Racing Integer Sample Codec            │
└─────────────────┬───────────────────────────────────┬───────────────────┘
                  │                                   │
                  ▼                                   ▼
┌───────────────────────────────────┐ ┌───────────────────────────────────┐
│      Statistical Auditing         │ │       Zero Lock-In Exports        │
│  • Multi-Run Sample Pooling       │ │  • Apache Arrow IPC (.arrow)      │
│  • Exact i64 Femtosecond Quantiles│ │  • Apache Parquet (.parquet)      │
│  • Mann-Whitney U + Welch t-test  │ │  • JSON / JSONL / CSV / TSV       │
│  • Cross-Lang 1v1 + Footprint Diff│ │  • Markdown & README Auto-Update  │
└───────────────────────────────────┘ └───────────────────────────────────┘
```

---

## Documentation Guides

1. **[Writing Benchmarks & Pipelines](./benchmarking-guide.md)**
   Authoring stateless and parameterized micro-benchmarks, building stateful multi-phase `Pipeline` suites with zero allocator-wrapper distortion, enforcing `@zero_alloc` contracts, `ols.json` discovery, and `odin test` integration.

2. **[CLI Reference & CI Workflows](./cli-and-ci.md)**
   Complete reference for every `hugi` subcommand and flag, database path resolution, Git SHA & worktree tracking, Copy-on-Write `--overlay` local experiments, GitHub Actions PR regression gates, and `.gitattributes` tips for tracking `.hugidb` files in Git.

3. **[Storage Format & Compression Architecture](./storage-and-compression.md)**
   Deep dive into fixed-point femtosecond arithmetic (`1 fs = 10^-15 s`), `xitdb` Copy-on-Write transactions, `HCAT` symbol/descriptor interning, `CZPK` hot packets, `CZCH` transposed cold rollups, `O(hot_runs)` compaction, and the 5-way `BU` integer sample codec.

4. **[Exports, Statistics & Polyglot Ingestion](./exports-and-analytics.md)**
   Canonical 35-column `EXPORT_COLUMNS` schema specification, Snapshot vs. `--all-commits` vs. `--all-runs` scopes, Mann-Whitney U and Welch's `t`-test decision rules, JSONL ingestion schema for non-Odin languages, and DuckDB / Polars / Odin `samples_blob` recipes.

---

## Additional Repository Resources

* **[`../usage-rules.md`](../usage-rules.md)** — Concise `DO` / `DON'T` rules for developers and AI coding assistants consuming `hugi`.
* **[`../AGENTS.md`](../AGENTS.md)** — Architecture boundaries, compiler vet flags, memory-leak gates, and 4-layer ATDD specification guide for contributors to `hugi`.
* **[`../examples/micro_and_phases/`](../examples/micro_and_phases/)** — Self-contained runnable suite combining micro-benchmarks and stateful pipelines (`make example`).
* **[`../examples/custom_markdown_odin/`](../examples/custom_markdown_odin/)** & **[`../examples/custom_reports/`](../examples/custom_reports/)** — Client-side custom Markdown rendering recipes in Odin (`hugi_store`), DuckDB SQL over Parquet, and Python over `compare-1v1 --format json`.