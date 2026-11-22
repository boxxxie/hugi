# Changelog

All notable changes to **`hugi`** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.4] - 2026-11-22

### Changed

- **Dependencies (`deps/obench`):**
  - Updated vendored `deps/obench` submodule to [`v0.5.0`](https://github.com/zeybek/obench/releases/tag/v0.5.0) (`c1dd6d2`), bringing median-of-block-means per-benchmark post-warmup clock calibration, two-loop auto-calibrated empty-loop floors (`_empty_step` vs `_black_box_step`), `also_fits` ambiguous Big-O reporting, safe `process_medians_ns` allocator cloning in `load_baseline_file`, omitting mismatched `samples_batch_ns` in combined multi-process reports, clamped-baseline allocation regression checks, and undecided (`too_few_samples`) handling when a side lacks enough values for a 95% Hodges-Lehmann interval.

## [0.1.3] - 2026-11-21

### Changed

- **Dependencies (`deps/xitdb`):**
  - Updated vendored `deps/xitdb` submodule to [`v2.1.0`](https://github.com/boxxxie/odin-xitdb/releases/tag/v2.1.0) (`9ad5d10`), bringing Odin `dev-2026-11a+` escape-analysis and ARM64 `-vet` compatibility, hardened B-tree/HAMT/cursor/wire bounds validation, in-place iterator initialization, and pooled Lua/DSL iterators.

## [0.1.2] - 2026-11-21

### Fixed

- **CLI Flag Parsing (`cmd/hugi/`):**
  - Return `Maybe(string)` from `_parse_flag_kv` and `_consume_value` in `cli_args.odin` so explicit empty inline values (such as `--filter=` or `--build-flags=`) resolve to `""` instead of consuming the following CLI argument.
  - Guard `--threshold` parsing in `_try_parse_common_flag` with `math.is_nan` and `math.is_inf` so `NaN` and `±Inf` values are rejected.

### Tests

- Added CLI flag-parser tests for `--filter=` and non-finite `--threshold` inputs (`cmd/hugi/cli_test.odin`) and a `mem.Tracking_Allocator` leak check for deep non-repository traversal in `resolve_git_commit` (`tests/git_test.odin`).

## [0.1.1] - 2026-11-21

### Fixed

- **Statistical Comparison & 1v1 Reporting (`store/`):**
  - Compute `lag1_autocorrelation`, `effective_sample_count`, `sample_trend`, and `count_modes` per individual `Record` inside `_pool_raw_group` rather than across concatenated multi-run sample slices, preventing steady ambient clock shifts between runs from triggering false drift/multimodal warnings or collapsing `effective_samples` and `ci95_fs`.
  - Pass `adjust_for_autocorrelation = false` when comparing independent `--by-run` medians (`run_medians_fs`), align `--by-run` deltas and geometric means with per-run medians under unequal sample counts, and tighten sub-`0.5%` 1v1 ties when `threshold_pct = 0`.
  - Adjust Mann-Whitney U `p_value` for autocorrelation alongside `_hodges_lehmann_shift_eff` when `n > 20` on either side so `p_value` and 95% Hodges-Lehmann confidence intervals stay consistent.
  - Orient 1v1 Hodges-Lehmann shifts in `compare_1v1_langs` by pairwise HL shift direction (rather than raw sample median order) so skewed/bimodal distributions never emit negative `shift_pct` or contradict `faster_lang`.
  - Surface HL shift bounds and `used_shift_ci` across `format_1v1_table` (`Test / p-value` column and `(ns)` non-significant marker), `format_1v1_json`, and `format_1v1_csv`.
- **Runner, Pipelines & Importers (`hugi/`):**
  - Calibrate hardware counter bracket overhead once per suite (`_calibrate_counter_overhead`) and propagate `_nested_hw_brackets` across nested pipeline phases; skip `pin_thread` and `counter_group_open` when no pipelines match `groups_filter`, and pre-size pipeline `samples_batch_ns`, `samples_cycles`, and `samples_hw` buffers to avoid mid-pass heap reallocations.
  - Clear stale `obench_suite` state when `groups_filter` skips microbenchmarks, track `failed_packet_io` independently of `obench_suite.failed_io`, filter `name_filter` exclusions before tallying microbenchmark failures and assigning contiguous `Record.rank` values, and initialize zero-valued `[dynamic]Metric` allocators in `_append_counter_metric`.
  - Preserve explicit zero-valued `branch_misses/op` and `cache_misses/op` hardware counter metrics, and retain `std_dev`, `ci95`, `cv`, `iqr`, and `mad` metadata on imported `obench` JSON reports when raw samples are absent.
- **CLI & Diagnostics (`cmd/hugi/`):**
  - Add `--by-run` to `hugi help`, distinguish known `0.00` load averages from unsupported platforms or non-finite values in `hugi doctor` (`null` in JSON, `unknown` in text), and emit a prioritized `Sample-Shape Warnings` banner in `hugi inspect` when suites exceed 25 benchmarks.

### Tests

- Expanded leak-checked verification (`-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`) to **32** unit/codec/store tests (`tests/`), **8** CLI tests (`cmd/hugi/`), and **41** 4-layer ATDD specifications and seeded property tests (`specs/`).

## [0.1.0] - 2026-11-21

Initial release of **`hugi`** — a Git-native Odin benchmark runner, compressed transactional `.hugidb` history store, statistical auditor, and multi-format analytics exporter.

### Added

- **Zero-Store Runner (`hugi/`):**
  - Isolated `package hugi` importing only `base:*`, `core:*`, and upstream [`zeybek/obench`](https://github.com/zeybek/obench) (`v0.4.0`: `Suite`, `Group`, `Bencher`, `Parallel_Bencher`, `step`, `black_box`, `clobber_memory`, and `run_test`).
  - Stateful multi-phase `Pipeline` lifecycles (`scoped_phase`, `phase_set_footprint`, `phase_metric`) executing in `Warmup` -> `Timed` (unwrapped allocators for zero counting overhead) -> `Alloc_Check` (`obench.Counting_Allocator`) passes, with `--pin <cpu>` thread pinning, `--counters` Linux `perf_event` hardware counter sampling (`instructions/op`, `cycles/op`, `branch_misses/op`, `cache_misses/op`), and `--test` smoke-run mode.
  - Exact 64-bit fixed-point femtosecond (`10^-15 s`) timing and quantile math (`batch_ns_to_op_fs`, `percentile_sorted_fs`) backed by 128-bit intermediate scaling.
  - Git HEAD commit resolution (`resolve_git_commit`) supporting standard repositories, detached HEADs, `packed-refs`, and linked Git worktrees.
  - Self-describing `HPKT\x02` / `OBRC\x02` binary wire codec (`packet.odin`) with optional `"HENV"` v1 host/build provenance trailers (`Run_Env`, `collect_host_env`, `check_host_env`, `populate_packet_env`, `format_env_brief` in `hugi/env.odin`, including cross-platform `core:sys/info` CPU model fallback).
  - JSON/JSONL importers (`importers.odin`) for `obench` v6 JSON reports (importing `ci95`, `skewness`, `kurtosis`, `shape`, `bimodal`, `sample_warnings`, `hardware_counters`, and `run_metadata`) and polyglot JSONL logs.
- **Transactional Historical Store & Statistical Auditor (`store/`):**
  - `xitdb`-backed `.hugidb` v5 storage layout (`HCAT\x01` catalog, `CZPK\x04` hot run packets, `CZCH\x02` transposed cold-history rollups, and `"HENV"` env persistence) with `Core_Overlay` Copy-on-Write trial runs (`store_open_overlay`) and atomic compaction (`store_compact`).
  - 5-way racing integer sample compression (`BU` header: `.Raw`, `.Zlib_Delta_Varint`, `.Zlib_BSS`, `.Zlib_Delta_BSS`, `.Zlib_Block_GCD`) supporting both `u64` batch timings and zigzag-mapped `i64` femtosecond samples.
  - Multi-run sample pooling (`store_load_pooled_records`), Hodges-Lehmann shift confidence interval gating + Mann-Whitney U (`p < 0.05`) + Welch's `t`-test + AR(1) autocorrelation-adjusted `ci95` (`compare_records`), cross-language 1v1 comparisons with footprint `[MISMATCH]` flags, `--by-run` per-run median comparisons, and provenance/CV/low-sample/sample-shape diagnostics (`pool_and_compare.odin`).
  - Canonical 35-column `EXPORT_COLUMNS` exporters (`export_schema.odin`, `export_arrow.odin`, `parquet.odin`, `export_text.odin`) targeting Apache Arrow IPC (LZ4 + `Decimal64(18, 6)`), Apache Parquet (GZIP + `DECIMAL(18, 6)`), JSON, JSONL, CSV, TSV, and Markdown (including `--out -` streaming and `--update-readme` marker updates).
- **Standalone CLI (`cmd/hugi/` -> `bin/hugi`):**
  - Subcommands: `run` (`--pin`, `--counters`, `--test`, `--by-run`), `ingest` (with `--capture-host-env`, `--build-flags`, `--runtime-version`), `history`, `inspect`, `compare` (`--by-run`, `--format md|json|csv`), `compare-1v1` (`--format md|json|csv`), `export`, `compact`, `doctor` (`--strict`, `--format md|json` with `obench` machine state: logical `cores`, `smt`, `load_avg`, `on_battery`, `vm`, and notes), `help`, and `version` (`hugi 0.1.0`).
  - Upward `hugi.json` discovery (`config.odin`) for default `db`, `pkg_dir`, `runs`, `warmup`, and `extra_build_flags`, plus deduplicated pre-run CPU governor/frequency/boost warnings.
- **Examples, Documentation, CI & Test Suites:**
  - Runnable examples under `examples/` (`micro_and_phases`, `custom_markdown_odin`, `custom_reports`) and guides under `docs/`.
  - Leak-checked verification suite (`-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`): **28** unit/codec/store tests (`tests/`), **7** CLI tests (`cmd/hugi/`), and **39** 4-layer ATDD specifications and seeded property tests (`specs/`).
  - Cross-platform GitHub Actions CI (`.github/workflows/ci.yml`) and tag/manual GitHub Release workflow (`.github/workflows/release.yml`).
