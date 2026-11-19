# Track Specification: Refactor Store, Exporters, CLI, and Test Suite for Modularity and Schema Consistency

## Overview & Motivation

Following the legacy `v1`–`v4` store pruning track (`prune_legacy_store_formats_20261119`), `hugi` now compiles and passes all tests cleanly on its canonical `v5` format (`HCAT\x01` + `CZPK\x04` + `CZCH\x02` + `BU` `u64` rational ticks). However, rapid feature growth left five large monolith files (`tests/hugi_test.odin` at `1,915` lines, `store/format.odin` at `1,893` lines, `store/db.odin` at `1,589` lines, `cmd/hugi/main.odin` at `1,543` lines, and `store/export.odin` at `984` lines) alongside duplicated logic that has already begun drifting subtly across modules:

- Small-sample (`2 <= n < 5`) significance testing diverges between `compare_records` and `compare_1v1_langs` in `store/pool_and_compare.odin`.
- Three raw-group loaders in `store/db.odin` handle `lang == ""` inconsistently, coercing empty `lang` to `"odin"` in commit and commit-series queries instead of preserving `pkt.lang`.
- Export schemas are defined independently in `store/export.odin` (`390`-line `export_arrow_ipc` with `35` manual finish/cleanup blocks, `29`-column CSV/TSV, and renamed JSON/JSONL keys) and `store/parquet.odin` (`_pq_column_specs` with magic integer field indices and a stale `root + 33 leaves` comment).
- Internal helpers (femtosecond quantile/dispersion stats, throughput math, `"%s:%s"` run-key formatting across `13` sites, `_ensure_parent_dir`, `store/` binary LE/varint readers, and cold-chunk sealing/compaction) are duplicated across files.
- `cmd/hugi/main.odin` duplicates flag-parsing switches across `8` subcommands, has a `320`-line `_cmd_run`, leaves a dead `_ = use_last` local in `_cmd_compare`, omits per-file `free_all(context.temp_allocator)` in `_cmd_ingest`, and currently has zero unit tests.

This track resolves these behavioral inconsistencies, unifies export schemas across all formats, modularizes oversized files without changing any on-disk wire formats, and adds CLI unit test coverage.

## Functional Requirements

1. **Core Hygiene, Drift Fixes & Shared Helpers (`hugi/`, `store/`):**
   - **Unified Small-Sample Significance Testing (`store/pool_and_compare.odin`):**
     - Extract a single `@(private)` helper (e.g., `_compare_significance`) shared by `compare_records` and `compare_1v1_langs`.
     - Apply the canonical `compare_records` rule to both comparators:
       - Compute Welch `t` and degrees of freedom `wdf` via `obench.welch_test`.
       - When both sides have `>= 2` samples in `samples_fs`, compute Mann-Whitney U `p_val` via `obench.mann_whitney_u` (`used_rank = true`):
         - For `min(len_a, len_b) >= 5`: `stat_diff = p_val < 0.05`.
         - For `2 <= min(len_a, len_b) < 5`: `stat_diff = p_val < 0.05 || (wdf > 0 && abs(wt) >= obench.t_critical_975(wdf))`.
       - Otherwise (`min < 2`): `stat_diff = wdf > 0 && abs(wt) >= obench.t_critical_975(wdf)`.
   - **Shared Femtosecond Stats & Throughput Math (`hugi/packet.odin`, `hugi/hugi.odin`, `hugi/phase.odin`, `store/format.odin`, `store/pool_and_compare.odin`):**
     - Extract `Stats_FS` and `compute_stats_fs(samples_fs: []i64, allocator := context.temp_allocator) -> Stats_FS` in `hugi` computing `min_fs`, `p25_fs`, `p50_fs`, `p75_fs`, `p95_fs`, `p99_fs`, `max_fs`, `mean_fs`, `std_dev_fs`, `ci95_fs`, `cv_pct`, `iqr_fs`, and `mad_fs`.
     - Reuse `compute_stats_fs` from both `hugi.recompute_record_stats_from_samples` and `store._pool_raw_group`.
     - Extract `hugi.compute_throughput_from_p50` (or `refresh_record_throughput`) so `_obench_result_to_record`, `_execute_pipeline`, `read_obench_json_packets`, `_finalize_record_stats_from_samples`, and `_pool_raw_group` share one throughput derivation.
   - **Consistent `lang == ""` Handling & Shared Query Helpers (`store/query.odin`):**
     - Extract a single `@(private)` `_run_key(lang, run_id, allocator := context.temp_allocator) -> string` helper replacing all `13` repeated `"%s:%s"` run-key formatting call sites across `store/`.
     - Extract shared `_ensure_parent_dir` across `store/` (removing duplicate `_ensure_export_parent_dir` in `store/export.odin`).
     - Consolidate repeated `_latest_moment_map` -> `_moment_reader_init` -> `mr.cat.runs` scan logic across `store_load_raw_groups`, `_store_load_commit_series_raw_groups`, and `_store_load_all_run_raw_groups`.
     - Preserve each packet's actual `pkt.lang` (falling back to `"odin"` only when `pkt.lang == ""`) when callers pass `lang == ""`:
       - `store_load_raw_groups` (`commit != ""`, `lang == ""`) keys groups by `(lang, full_name)` so records from different languages on the same commit do not merge under `"odin"`.
       - `_store_load_commit_series_raw_groups` (`lang == ""`) buckets by `(commit, lang)` so multi-language commits stay distinct.
   - **Shared `store/` Binary I/O (`store/binary_io.odin`):**
     - Consolidate `_Format_Reader`, `_fmt_append_*`, `_fmt_read_*`, and fixed-width LE helpers in `store/binary_io.odin`.
     - Remove duplicate `_read_u32_le`, `_read_varint_u64`, and `_read_zigzag_i64` from `store/codec.odin` and duplicate `_append_u32_le` / `_append_u64_le` from `store/parquet.odin`.
   - **Shared Cold-Chunk Sealing & Compaction Writer (`store/compact.odin`):**
     - Extract shared `_seal_packets_to_cold_chunks` and atomic `_compact_db_to_path_atomic` helpers eliminating duplication across `_ingest_batch_cb`, `_try_fast_catalog_compact`, and `store_compact_with_options`.

2. **Unified 35-Column Export Schema & Standardized Text Exports (`store/`):**
   - **Canonical Schema Table (`store/export_schema.odin`):**
     - Define one typed `Export_Col_Id` enum and `@(rodata)` `35`-column `EXPORT_COLUMNS` table covering `34` canonical scalar columns in fixed order plus `samples_blob` (column `35`):
       `commit`, `lang`, `suite_name`, `group_name`, `name`, `full_name`, `run_id`, `timestamp_unix`, `rank`, `run_count`, `ops_per_sample`, `samples`, `min_ns`, `p25_ns`, `p50_ns`, `p75_ns`, `p95_ns`, `p99_ns`, `max_ns`, `mean_ns`, `std_dev_ns`, `ci95_ns`, `cv_pct`, `iqr_ns`, `mad_ns`, `ops_per_sec`, `mb_per_sec`, `bytes_per_op`, `footprint_bytes`, `allocs_per_op`, `alloc_bytes_per_op`, `temp_allocs_per_op`, `temp_bytes_per_op`, `peak_heap_bytes`, `samples_blob`.
     - Provide typed value accessors (`_export_col_str`, `_export_col_i64`, `_export_col_u64`, `_export_col_f64`) and one shared `_compress_pooled_samples_blob` helper.
   - **Parquet Exporter (`store/parquet.odin`):**
     - Drive schema elements, column chunks, and PLAIN page encoding from `EXPORT_COLUMNS` + typed `Export_Col_Id` accessors, removing `_pq_column_specs`, magic integer indices, and the stale `root + 33 leaves` comment.
   - **Arrow IPC Exporter (`store/export_arrow.odin`):**
     - Drive `skadi.Field` creation, builder population, and error-safe `cols[0..<finished]` finalization/cleanup from `EXPORT_COLUMNS`, eliminating the `~180` lines of repeated manual `cols[N]` error-cleanup blocks.
   - **Standardized CSV/TSV & JSON/JSONL Exporters (`store/export_text.odin`):**
     - Drive CSV and TSV (`_export_delimited`) headers and rows from all `34` canonical scalar columns of `EXPORT_COLUMNS` (upgrading from `29` to `34` columns; renaming `suite`/`group`/`runs` -> `suite_name`/`group_name`/`run_count` and adding `iqr_ns`, `mad_ns`, `temp_allocs_per_op`, `temp_bytes_per_op`, `peak_heap_bytes`).
     - Standardize JSON and JSONL (`_write_json_record`) to emit the exact same `34` canonical scalar field names in order, followed by `samples_batch_ns` (when non-empty) and `samples_ns`.
     - Retain Markdown table and README marker helpers (`format_markdown_table`, `export_markdown`, `format_comparison_table`, `format_1v1_table`, `update_readme_markers`).

3. **File Modularization (Preserving All Public APIs & Package Boundaries):**
   - **`hugi/` (`package hugi`):** Move external importers (`read_obench_json_packets`, `_Jsonl_Row`, `read_jsonl_packets`) from `hugi/packet.odin` into `hugi/importers.odin`. Keep `hugi/` importing strictly `base:*`, `core:*`, and `../deps/obench/obench`, and passing `-disallow-do -vet-cast`.
   - **`store/` (`package hugi_store`):**
     - `store/format.odin` -> `store/binary_io.odin`, `store/catalog.odin`, `store/format.odin`
     - `store/db.odin` -> `store/db.odin`, `store/compact.odin`, `store/query.odin`
     - `store/export.odin` -> `store/export_schema.odin`, `store/export_arrow.odin`, `store/export_text.odin`
     - Retain focused `store/codec.odin`, `store/parquet.odin`, `store/pool_and_compare.odin`
   - **`cmd/hugi/` (`package hugi_cli`):**
     - `cmd/hugi/main.odin` (`VERSION`, `_print_help`, `main` dispatch)
     - `cmd/hugi/cli_args.odin` (shared flag parsing, `_resolve_db_path`, `_split_range`, `_infer_export_format`, `_file_has_packet_magic`, `_open_store_or_err`)
     - `cmd/hugi/cmd_run.odin` (`ols.json` discovery, single upward directory-walk helper replacing duplicated `exe_dir`/`cwd` loops, and decomposed build/run/ingest/compare helpers)
     - `cmd/hugi/cmd_ingest.odin` (`_cmd_ingest` with per-file `free_all(context.temp_allocator)`)
     - `cmd/hugi/cmd_query.odin` (`_cmd_history`, `_cmd_inspect`, `_cmd_compare` removing dead `_ = use_last` and consolidating repeated `store_load_pooled_records` branches, `_cmd_compare_1v1`)
     - `cmd/hugi/cmd_export.odin` (`_cmd_export`, `_cmd_compact`)

4. **Test Modularization, Regression Coverage & CLI Unit Tests (`tests/`, `cmd/hugi/`, `Makefile`):**
   - Split `tests/hugi_test.odin` into focused `package hugi_tests` files: `tests/test_helpers.odin`, `tests/codec_test.odin`, `tests/packet_test.odin`, `tests/store_test.odin`, `tests/compare_test.odin`, and `tests/export_test.odin`.
   - Add regression tests for:
     - `2 <= n < 5` small-sample significance parity between `compare_records` and `compare_1v1_langs`.
     - `lang == ""` multi-language commit and commit-series raw-group queries preserving `pkt.lang` without cross-language merging.
     - Exact `34`-column scalar name/order parity across Arrow IPC, Parquet, CSV, TSV, JSON, and JSONL exports.
   - Add `cmd/hugi/cli_test.odin` (`package hugi_cli`) covering flag parsing, `_split_range`, `_infer_export_format`, `_resolve_db_path`, `_collection_name` / `_is_reserved_collection`, `ols.json` discovery, and mutually-exclusive export flags.
   - Update `Makefile` `test` target to run `odin test cmd/hugi` alongside `odin test tests` under `-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`.

5. **Documentation Sync (`README.md`):**
   - Update `README.md` to reflect standardized `34`-column CSV/TSV/JSON/JSONL field names and updated module layout using inline code spans (no `$...$` MathJax blocks).

## Out of Scope

- **On-Disk Wire Formats (`HCAT\x01`, `CZPK\x04`, `CZCH\x02`, `BU`, `HPKT\x02`, `OBRC\x02`):** Zero binary layout or compression changes. Existing `v5` databases — specifically `/home/pauli/projects/odin/mimir/benchmarks/history.hugidb` (`2,152 B`) and `/home/pauli/projects/odin/temple/benchmarks/history.hugidb` (`7,208 B`) — MUST open, inspect, export, and re-compact with `0` byte regression.
- **External Boundary Importers:** `read_jsonl_packets` and `read_obench_json_packets` MUST remain functionally unchanged for legacy `.jsonl` and `obench` `.json` files (only relocated to `hugi/importers.odin`).
- **Submodules (`deps/*`):** Zero edits inside `deps/obench`, `deps/xitdb`, or `deps/skadi`.
- **Public API Signatures:** Keep existing public `hugi` and `hugi_store` procedures, structs, and CLI commands/flags source-compatible (apart from the explicitly approved standardized CSV/TSV/JSON/JSONL column names).

## Acceptance Criteria

1. `compare_records` and `compare_1v1_langs` share one significance helper and produce identical significance verdicts on `2 <= n < 5` sample inputs.
2. `store_load_raw_groups` (commit queries) and `store_load_commit_series_records` with `lang == ""` preserve distinct languages instead of coercing to `"odin"`.
3. Arrow IPC, Parquet, CSV, TSV, JSON, and JSONL exports all emit the exact same `34` canonical scalar field names in canonical order (plus `samples_blob` in Arrow/Parquet and `samples_batch_ns`/`samples_ns` in JSON/JSONL), driven by `store/export_schema.odin`.
4. Oversized monoliths (`store/format.odin`, `store/db.odin`, `store/export.odin`, `cmd/hugi/main.odin`, `tests/hugi_test.odin`) are split into cohesive single-responsibility files with `hugi/` remaining strictly isolated from `deps/xitdb` and `deps/skadi`.
5. `cmd/hugi/cli_test.odin` passes under `make test` with `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`.
6. `make fmt-check && make check && make test && make example && make build` pass with `0` failures and `0` leaked/bad-freed bytes.
7. Reference `v5` database smoke tests (`mimir` `2,152 B` and `temple` `7,208 B`) pass `hugi history`, `hugi inspect`, `hugi export` (`.arrow`, `.parquet`, `.csv`, `.json`), and `hugi compact` with identical compacted byte sizes.
