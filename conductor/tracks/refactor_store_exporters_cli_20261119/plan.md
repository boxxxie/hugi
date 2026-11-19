# Implementation Plan: Refactor Store, Exporters, CLI, and Test Suite for Modularity and Schema Consistency

Follow [workflow.md](../../workflow.md): keep `hugi/` isolated from `xitdb`/`skadi`, avoid `do` statements, keep all `v5` wire formats byte-compatible, and execute the Phase Completion Verification and Checkpointing Protocol at the end of every phase.

---

## Phase 1: Core Math, Significance Parity, and `hugi/` Importer Split

- [x] Task: Add regression test for small-sample (`2 <= n < 5`) significance parity
    - [x] Add a `@(test)` case in `tests/hugi_test.odin` exercising `n = 3` or `n = 4` separated sample sets where `compare_records` and `compare_1v1_langs` must agree on `is_significant` (`MWU p < 0.05 || Welch`).
- [x] Task: Extract shared femtosecond stats and throughput math in `hugi/`
    - [x] Define `Stats_FS`, `compute_stats_fs`, and `compute_throughput_from_p50` (or `refresh_record_throughput`) in `hugi/packet.odin`.
    - [x] Refactor `hugi.recompute_record_stats_from_samples`, `_obench_result_to_record` (`hugi/hugi.odin`), `_execute_pipeline` (`hugi/phase.odin`), `read_obench_json_packets` (`hugi/packet.odin`), `_finalize_record_stats_from_samples` (`store/format.odin`), and `_pool_raw_group` (`store/pool_and_compare.odin`) to call the shared helpers.
- [x] Task: Unify statistical significance testing in `store/pool_and_compare.odin`
    - [x] Extract `@(private)` `_compare_significance` implementing the canonical `compare_records` rule (`n >= 5`: `p_val < 0.05`; `2 <= n < 5`: `p_val < 0.05 || welch_sig`; `n < 2`: `welch_sig`).
    - [x] Update both `compare_records` and `compare_1v1_langs` to call `_compare_significance`, eliminating duplicated `_samples_fs_as_f64` / `mann_whitney_u` / `welch_test` blocks.
- [x] Task: Split external JSON/JSONL importers out of `hugi/packet.odin`
    - [x] Move `read_obench_json_packets`, `_Jsonl_Row`, and `read_jsonl_packets` into `hugi/importers.odin` with zero functional change to external `.json` / `.jsonl` parsing.
    - [x] Verify `odin check hugi -no-entry-point -collection:obench=./deps/obench/obench -vet -vet-tabs -vet-style -vet-cast -strict-style -warnings-as-errors -disallow-do` passes cleanly.
- [x] Task: Conductor - User Manual Verification 'Phase 1: Core Math, Significance Parity, and hugi/ Importer Split' (Protocol in workflow.md)

---

## Phase 2: Consolidate `store/` Binary I/O and Modularize `store/format.odin`

- [x] Task: Extract unified `store/` binary I/O helpers (`store/binary_io.odin`)
    - [x] Move `_Format_Reader`, `_fmt_append_varint_u64`, `_fmt_append_zigzag_i64`, `_fmt_append_u32_le`, `_fmt_append_u64_le`, `_fmt_append_f64_le`, `_fmt_append_str`, `_fmt_read_u8`, `_fmt_read_u32_le`, `_fmt_read_u64_le`, `_fmt_read_f64_le`, `_fmt_read_varint_u64`, `_fmt_read_zigzag_i64`, `_fmt_read_str`, plus fixed-slice `_write_u32_le` / `_read_u32_le` into `store/binary_io.odin`.
    - [x] Remove duplicate `_write_u32_le`, `_read_u32_le`, `_read_varint_u64`, and `_read_zigzag_i64` from `store/codec.odin` and duplicate `_append_u32_le` / `_append_u64_le` from `store/parquet.odin`, switching both files to `store/binary_io.odin`.
- [x] Task: Extract `HCAT\x01` catalog and tables (`store/catalog.odin`)
    - [x] Move `_Symbol_Table`, `_Descriptor_Table`, `_Bench_Desc`, `_Snap_Ref`, `_Catalog_Run_Entry`, `_Moment_Catalog`, and `_encode_catalog_blob` / `_decode_catalog_blob` from `store/format.odin` into `store/catalog.odin`.
    - [x] Add `@(private)` `_run_key(lang, run_id, allocator := context.temp_allocator) -> string` in `store/catalog.odin` and replace all `13` repeated `"%s:%s"` formatting call sites across `store/`.
- [x] Task: Keep `store/format.odin` focused on `CZPK\x04` and `CZCH\x02`
    - [x] Retain `Store_Write_Options`, `default_store_write_options`, `CZPK_V4_MAGIC`, `CZCH_V2_MAGIC`, `_encode_hot_packet`, `_decode_hot_packet`, `_encode_cold_chunk`, and `_decode_cold_chunk` in `store/format.odin` with zero wire-format changes.
- [x] Task: Conductor - User Manual Verification 'Phase 2: Consolidate store/ Binary I/O and Modularize store/format.odin' (Protocol in workflow.md)

---

## Phase 3: Unify `store/` Queries, Compaction, and Modularize `store/db.odin`

- [x] Task: Add regression tests for `lang == ""` multi-language queries
    - [x] Add `@(test)` assertions in `tests/hugi_test.odin` verifying `store_load_raw_groups(..., lang = "", commit = ...)` and `store_load_commit_series_records(..., lang = "")` preserve distinct `"odin"` and `"zig"` rows rather than coercing to `"odin"` or merging across languages.
- [x] Task: Extract query and raw-group loaders (`store/query.odin`)
    - [x] Move `store_list_runs`, `store_list_commits`, `store_load_all_packets`, `_Raw_Group`, `_raw_groups_destroy`, `_raw_groups_add_record`, `store_load_raw_groups`, `_store_load_commit_series_raw_groups`, and `_store_load_all_run_raw_groups` into `store/query.odin`.
    - [x] Factor shared moment-open / catalog run iteration helpers and fix `lang == ""` keying (`(lang, full_name)` for commit queries and `(commit, lang)` for commit-series queries).
- [x] Task: Extract cold-chunk sealing and compaction (`store/compact.odin`)
    - [x] Extract shared `@(private)` `_seal_packets_to_cold_chunks` and `_compact_db_to_path_atomic` helpers.
    - [x] Move `_Fast_Compact_Ctx`, `_fast_compact_moment_cb`, `_try_fast_catalog_compact`, `store_compact_with_options`, and `store_compact` into `store/compact.odin`, reusing the shared sealing/atomic-write helpers from `_ingest_batch_cb` and compaction paths.
- [x] Task: Clean up `store/db.odin` and deduplicate `_ensure_parent_dir`
    - [x] Mark `_ensure_parent_dir` `@(private = "package")` in `store/db.odin` and remove duplicate `_ensure_export_parent_dir` from `store/export.odin` (updating `store/parquet.odin` and export files).
    - [x] Confirm `store/db.odin` focuses strictly on `Store` open/overlay/close, ingestion, and `_Moment_Reader`.
- [x] Task: Conductor - User Manual Verification 'Phase 3: Unify store/ Queries, Compaction, and Modularize store/db.odin' (Protocol in workflow.md)

---

## Phase 4: Unified 35-Column Export Schema, Arrow/Parquet Cleanup, and Standardized Text Exports

- [x] Task: Update and expand export schema parity tests
    - [x] Update existing TSV/CSV/JSON/JSONL assertions in `tests/hugi_test.odin` to expect the canonical `34` scalar field names (`suite_name`, `group_name`, `run_count`, `iqr_ns`, `mad_ns`, `temp_allocs_per_op`, `temp_bytes_per_op`, `peak_heap_bytes`, etc.).
    - [x] Add an explicit schema-parity test verifying identical `34`-column scalar names and ordering across Arrow IPC, Parquet, CSV, TSV, JSON, and JSONL outputs (plus `samples_blob` in Arrow/Parquet and `samples_batch_ns`/`samples_ns` in JSON/JSONL).
- [x] Task: Create unified `35`-column export schema (`store/export_schema.odin`)
    - [x] Define `Export_Col_Id`, `Export_Col_Kind`, `Export_Col_Spec`, and `@(rodata)` `EXPORT_COLUMNS` (`34` scalar columns + `samples_blob`).
    - [x] Add typed value accessors (`_export_col_str`, `_export_col_i64`, `_export_col_u64`, `_export_col_f64`) and shared `_compress_pooled_samples_blob`.
- [x] Task: Refactor `store/parquet.odin` to consume `EXPORT_COLUMNS`
    - [x] Remove `_pq_column_specs`, `_pq_record_str`, `_pq_record_i64`, `_pq_record_u64`, `_pq_record_f64`, and magic integer field indices.
    - [x] Use `EXPORT_COLUMNS`, typed accessors, and `_compress_pooled_samples_blob`, and fix the stale `root + 33 leaves` comment.
- [x] Task: Split `store/export.odin` into `store/export_arrow.odin` and `store/export_text.odin`
    - [x] Implement `export_arrow_ipc` in `store/export_arrow.odin` driven by `EXPORT_COLUMNS` with a clean column-builder array / loop-based error cleanup (removing the `35` copy-pasted finish/cleanup blocks) and `_compress_pooled_samples_blob`.
    - [x] Implement `export_json`, `export_jsonl`, `export_csv`, `export_tsv`, `format_markdown_table`, `export_markdown`, `format_comparison_table`, `format_1v1_table`, and `update_readme_markers` in `store/export_text.odin`, driving CSV/TSV and JSON/JSONL scalar fields from the canonical `34` columns of `EXPORT_COLUMNS`.
    - [x] Delete the old monolithic `store/export.odin`.
- [x] Task: Conductor - User Manual Verification 'Phase 4: Unified 35-Column Export Schema, Arrow/Parquet Cleanup, and Standardized Text Exports' (Protocol in workflow.md)

---

## Phase 5: Modularize `cmd/hugi/` CLI and Add CLI Unit Tests

- [x] Task: Extract shared CLI argument and store helpers (`cmd/hugi/cli_args.odin`)
    - [x] Move `_resolve_db_path`, `_parse_flag_kv`, `_consume_value`, `_split_range`, `_file_has_packet_magic`, plus extracted `_infer_export_format` and `_open_store_or_err` into `cmd/hugi/cli_args.odin`.
    - [x] Add reusable shared flag parsing helpers covering common flags (`--db`, `--lang`, `--commit`, `--filter`/`-f`, `--threshold`, `--help`/`-h`) across subcommands.
- [x] Task: Split subcommands out of `cmd/hugi/main.odin`
    - [x] Extract `cmd/hugi/cmd_run.odin`: unify upward parent-directory walk in `_resolve_hugi_repo_root`, keep `ols.json` discovery clean, and decompose the `320`-line `_cmd_run` into build, execute, ingest, and baseline-compare helpers.
    - [x] Extract `cmd/hugi/cmd_ingest.odin`: add `free_all(context.temp_allocator)` per ingested file so large batch ingests keep scratch memory bounded.
    - [x] Extract `cmd/hugi/cmd_query.odin`: move `_cmd_history`, `_cmd_inspect`, `_cmd_compare` (removing dead `_ = use_last` and consolidating the `4` repeated `store_load_pooled_records` branches), and `_cmd_compare_1v1`.
    - [x] Extract `cmd/hugi/cmd_export.odin`: move `_cmd_export` and `_cmd_compact`, using `_infer_export_format` and `_open_store_or_err`.
    - [x] Keep `cmd/hugi/main.odin` minimal (`VERSION`, `_print_help`, `main` dispatch).
- [x] Task: Add CLI unit tests (`cmd/hugi/cli_test.odin`) and update `Makefile`
    - [x] Add `@(test)` coverage in `cmd/hugi/cli_test.odin` for `_parse_flag_kv`, `_consume_value`, `_split_range`, `_infer_export_format`, `_resolve_db_path`, `_collection_name` / `_is_reserved_collection`, `ols.json` collection & build-flag discovery, and export flag validation (`--all-commits` + `--all-runs` / `--commit` rejection).
    - [x] Update `Makefile` `test` target to run `$(ODIN) test cmd/hugi -out:.tmp/hugi_cli_tests $(COLS) $(FULL_FLAGS) $(TEST_FLAGS)` alongside `$(ODIN) test tests`.
- [x] Task: Conductor - User Manual Verification 'Phase 5: Modularize cmd/hugi/ CLI and Add CLI Unit Tests' (Protocol in workflow.md)

---

## Phase 6: Split `tests/hugi_test.odin`, Sync Docs, and Full Reference-DB Verification

- [ ] Task: Split `tests/hugi_test.odin` by subsystem
    - [ ] Split `tests/hugi_test.odin` into `tests/test_helpers.odin`, `tests/codec_test.odin`, `tests/packet_test.odin`, `tests/store_test.odin`, `tests/compare_test.odin`, and `tests/export_test.odin` (all `package hugi_tests`), then delete `tests/hugi_test.odin`.
    - [ ] Verify every test procedure runs and passes under `make test` with `0` leaks.
- [ ] Task: Sync documentation (`README.md`)
    - [ ] Update `README.md` export documentation to reflect standardized `34`-column scalar field names across Arrow IPC, Parquet, CSV, TSV, JSON, and JSONL, and updated repository module structure (inline code spans only; zero `$...$` MathJax blocks).
- [ ] Task: Final full build/test gate and `v5` reference-DB smoke check
    - [ ] Run `make fmt && make fmt-check && make check && make test && make example && make build && rm -rf .tmp build`.
    - [ ] Copy `/home/pauli/projects/odin/mimir/benchmarks/history.hugidb` (`2,152 B`) and `/home/pauli/projects/odin/temple/benchmarks/history.hugidb` (`7,208 B`) to `/tmp` (delete after) and verify `./bin/hugi history`, `./bin/hugi inspect`, `./bin/hugi export` (`.arrow`, `.parquet`, `.csv`, `.json`), and `./bin/hugi compact` preserve exact byte sizes (`2,152 B` and `7,208 B`) and all records.
- [ ] Task: Conductor - User Manual Verification 'Phase 6: Split tests/hugi_test.odin, Sync Docs, and Full Reference-DB Verification' (Protocol in workflow.md)
