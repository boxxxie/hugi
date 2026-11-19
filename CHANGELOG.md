# Changelog

All notable changes to **`hugi`** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-11-19

Initial release of **`hugi`** — a Git-native Odin benchmark runner, compressed transactional `.hugidb` history store, statistical auditor, and multi-format analytics exporter.

### Added

- **Zero-Store Runner (`hugi/`):**
  - Isolated `package hugi` importing only `base:*`, `core:*`, and `deps/obench/obench` (`Suite`, `Group`, `Bencher`, `Parallel_Bencher`, `step`, `black_box`, `clobber_memory`, and `run_test`).
  - Stateful multi-phase `Pipeline` lifecycles (`scoped_phase`, `phase_set_footprint`, `phase_metric`) executing in `Warmup` -> `Timed` (unwrapped allocators for zero counting overhead) -> `Alloc_Check` (`obench.Counting_Allocator`) passes.
  - Exact 64-bit fixed-point femtosecond (`10^-15 s`) timing and quantile math (`batch_ns_to_op_fs`, `percentile_sorted_fs`) backed by 128-bit intermediate scaling.
  - Git HEAD commit resolution (`resolve_git_commit`) supporting standard repositories, detached HEADs, `packed-refs`, and linked Git worktrees.
  - Self-describing `HPKT\x02` / `OBRC\x02` binary wire codec (`packet.odin`) with optional `"HENV"` v1 host/build provenance trailers (`Run_Env`, `collect_host_env`, `check_host_env`, `populate_packet_env`, `format_env_brief` in `hugi/env.odin`).
  - JSON/JSONL importers (`importers.odin`) for `obench` JSON reports and polyglot JSONL logs.
- **Transactional Historical Store & Statistical Auditor (`store/`):**
  - `xitdb`-backed `.hugidb` v5 storage layout (`HCAT\x01` catalog, `CZPK\x04` hot run packets, `CZCH\x02` transposed cold-history rollups, and `"HENV"` env persistence) with `Core_Overlay` Copy-on-Write trial runs (`store_open_overlay`) and atomic compaction (`store_compact`).
  - 5-way racing integer sample compression (`BU` header: `.Raw`, `.Zlib_Delta_Varint`, `.Zlib_BSS`, `.Zlib_Delta_BSS`, `.Zlib_Block_GCD`) supporting both `u64` batch timings and zigzag-mapped `i64` femtosecond samples.
  - Multi-run sample pooling (`store_load_pooled_records`), Mann-Whitney U (`p < 0.05`) + Welch's `t`-test comparison (`compare_records`), cross-language 1v1 comparisons with footprint `[MISMATCH]` flags, and provenance/CV/low-sample diagnostics (`pool_and_compare.odin`).
  - Canonical 35-column `EXPORT_COLUMNS` exporters (`export_schema.odin`, `export_arrow.odin`, `parquet.odin`, `export_text.odin`) targeting Apache Arrow IPC (LZ4 + `Decimal64(18, 6)`), Apache Parquet (GZIP + `DECIMAL(18, 6)`), JSON, JSONL, CSV, TSV, and Markdown (including `--out -` streaming and `--update-readme` marker updates).
- **Standalone CLI (`cmd/hugi/` -> `bin/hugi`):**
  - Subcommands: `run`, `ingest` (with `--capture-host-env`, `--build-flags`, `--runtime-version`), `history`, `inspect`, `compare`, `compare-1v1` (`--format md|json|csv`), `export`, `compact`, `doctor` (`--strict`, `--format md|json`), `help`, and `version` (`hugi 0.1.0`).
  - Upward `hugi.json` discovery (`config.odin`) for default `db`, `pkg_dir`, `runs`, `warmup`, and `extra_build_flags`, plus pre-run CPU governor/frequency/boost warnings.
- **Examples, Documentation, CI & Test Suites:**
  - Runnable examples under `examples/` (`micro_and_phases`, `custom_markdown_odin`, `custom_reports`) and guides under `docs/`.
  - Leak-checked verification suite (`-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`): **16** unit/codec/store tests (`tests/`), **5** CLI tests (`cmd/hugi/`), and **35** 4-layer ATDD specifications and seeded property tests (`specs/`).
  - Cross-platform GitHub Actions CI (`.github/workflows/ci.yml`) and tag/manual GitHub Release workflow (`.github/workflows/release.yml`).
