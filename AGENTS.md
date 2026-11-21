# Agent Guidelines for `hugi` (`odin/hugi`)

This repository provides a pure-Odin benchmarking library (`hugi`), a compressed transactional history store and cross-run/cross-language comparator (`hugi_store` built on `xitdb` + `skadi`), and a CLI (`bin/hugi`).

## 1. Package Topology & Architectural Boundaries

| Directory | Package | Role & Allowed Dependencies |
| :--- | :--- | :--- |
| `hugi/` | `hugi` | Zero-store runner, `obench` micro-benchmark re-exports, stateful `Pipeline`/`Phase` lifecycles, Git HEAD resolver, `HPKT\x02`/`OBRC\x02` wire codec, JSON/JSONL importers. **MUST ONLY import `base:*`, `core:*`, and `../deps/obench/obench`.** Never import `store`, `deps/xitdb`, or `deps/skadi` here (downstream projects such as `xitdb`, `skadi`, and `heimdall` import `hugi` to avoid circular package dependencies). |
| `store/` | `hugi_store` | Transactional `xitdb` `.hugidb` database, `HCAT\x01` root catalog, `CZPK\x04` hot packets, `CZCH\x02` transposed cold rollups, `BU` 5-way integer sample codecs, pooling, statistical tests, and Arrow IPC (`skadi`), Parquet, JSON, JSONL, CSV, TSV, and Markdown exporters. |
| `cmd/hugi/` | `hugi_cli` | Standalone CLI (`run`, `ingest`, `history`, `inspect`, `compare`, `compare-1v1`, `export`, `compact`) and `ols.json` discovery. |
| `tests/` | `hugi_tests` | Focused unit tests for codecs, wire formats, Git layouts, `xitdb` slot layouts, significance parity, and export edge cases. |
| `specs/` | `hugi_specs` | 4-layer black-box ATDD specifications (`*_spec_test.odin`) and seeded property invariants (`invariants_prop_test.odin`). |
| `deps/` | Vendored | `obench`, `xitdb`, and `skadi` submodules. Never edit files inside `deps/*` directly from `hugi`; make upstream changes on feature branches in their own repositories and update the submodule pointer deliberately. |

### Relative Dependency Imports vs. Collection Imports

Internal files import `../hugi`, `../store`, `../deps/obench/obench`, `../deps/xitdb/xitdb`, and `../deps/skadi/skadi` via relative paths so package identities remain unambiguous. Never mix a collection import (`hugi:...`) and a relative import (`../hugi`) targeting the same directory inside a single build graph.

## 2. Build, Format, Check, and Test Commands

Always run `make check`, `make test`, and `make fmt-check` from the repository root before considering any change complete:

```bash
make fmt          # Format all project .odin files with odinfmt -config:odinfmt.json
make fmt-check    # Verify formatting cleanly (fails on any diff)
make check        # Strict compiler/vet checks across all 6 packages
make test         # Run tests, CLI tests, and specs with -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
make specs        # Build bin/hugi and run 4-layer ATDD specs & property tests in specs/
make build        # Build -o:speed CLI binary at bin/hugi
```

### Running a Single Test or Spec Scenario

Pass `-define:ODIN_TEST_NAMES=<package>.<proc_name>` with the tracking allocator enabled:

```bash
odin test specs -out:.tmp/hugi_specs \
  -collection:hugi=./hugi -collection:hugi_store=./store \
  -collection:obench=./deps/obench/obench -collection:xitdb=./deps/xitdb/xitdb -collection:skadi=./deps/skadi/skadi \
  -vet -strict-style -vet-tabs -warnings-as-errors \
  -vet-packages:hugi,hugi_store,hugi_cli,hugi_tests,hugi_specs \
  -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true \
  -define:ODIN_TEST_NAMES=hugi_specs.spec_selective_run_updates_only_touched_benchmarks_in_latest_snapshot
```

To replay a failing seeded property test deterministically, append `-define:ODIN_TEST_RANDOM_SEED=<seed>`.

## 3. Compiler Flags, Style & Memory Discipline

1. **Compiler Flag Split (`-disallow-do`):**
   - Check `hugi/` with strict flags including `-disallow-do`:
     `-vet -vet-tabs -vet-style -vet-cast -strict-style -warnings-as-errors -disallow-do`
   - Do NOT pass `-disallow-do` when building or checking `store/`, `cmd/hugi/`, `examples/`, `tests/`, or `specs/` because `deps/xitdb/xitdb/lua.odin` uses `do`. Always use:
     `-vet -strict-style -vet-tabs -warnings-as-errors -vet-packages:hugi,hugi_store,hugi_cli,hugi_tests,hugi_specs`
   - Still avoid `do` statements and preserve hard tabs (`tabs_width: 4`, `character_width: 100`, `1TBS` braces per `odinfmt.json`) across every `.odin` file written in this repository.
2. **Zero Leaks & Zero Bad Frees (`ODIN_TEST_FAIL_ON_BAD_MEMORY=true`):**
   - All `@(test)` procedures in `tests/`, `cmd/hugi/`, and `specs/` must pass under `-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true` with zero memory leaks.
   - Annotate procedures that return owned memory or fallible `ok` booleans with `@(require_results)`.
   - Pair every owned struct/slice constructor with an explicit `*_destroy` procedure that frees all nested strings, maps, and dynamic arrays, and zeroes the struct (`r^ = {}`).
   - When using `context.temp_allocator` inside loops (e.g., `cmd_ingest` or `invariants_prop_test`), keep loop-spanning state on `context.allocator` so `free_all(context.temp_allocator)` never invalidates live slices.
3. **Visibility:**
   - Keep internal wire helpers, catalog tables, and CLI flag parsers marked `@(private)` or `@(private = "file")` so `specs/` tests only exercise public package contracts.

## 4. Core Domain, Storage & Format Invariants

1. **`xitdb` Storage Invariants:**
   - Root `history` is a `Write_Array_List` / `Read_Array_List` of `Hash_Map` moments:
     - Pass empty `xitdb.Slot{}` when creating Moment 0.
     - Pass `latest_slot.?` from `array_list_get_slot(history.read_array_list, -1)` for every subsequent moment so history preserves structural sharing and lineage.
   - `Store.core` is heap-allocated (`new(xitdb.Core, allocator)`) before `xitdb.database_init` because `xitdb.Database` holds a pointer to `Core`; `Store` must stay movable by value without invalidating `st.db.core`.
   - Always close any active `Store` before calling `store_compact(db_path)`. `store_compact` opens the destination file with `{.Read, .Write, .Create, .Trunc}`, compacts via `xitdb.database_compact`, and atomically renames over `db_path`.
2. **Exact Fixed-Point Femtosecond Arithmetic (`1 ns = 10^6 fs`):**
   - All duration statistics (`min_fs`, `p25_fs`, `p50_fs`, `p75_fs`, `p95_fs`, `p99_fs`, `max_fs`, `mean_fs`, `std_dev_fs`, `ci95_fs`, `iqr_fs`, `mad_fs`) are stored and pooled as signed `i64` femtoseconds (`10^-15 s`), never `f64` nanoseconds.
   - Scale batch nanosecond timings (`u64`) via `batch_ns_to_op_fs` (`u128` intermediate math) and interpolate quantiles via `percentile_sorted_fs` (`i128` intermediate math).
   - Export durations as `Decimal64(18, 6)` in Arrow IPC, `DECIMAL(18, 6)` (`INT64` physical) in Parquet, and exact 6-decimal fixed-point strings (`write_decimal_ns_fs`) in JSON/JSONL/CSV/TSV.
3. **Pipeline Zero-Overhead Timing Model:**
   - `_execute_pipeline` runs in three distinct phases: `Warmup` (unwrapped allocators, untimed) -> `Timed` (unwrapped allocators for `0 ns` wrapper distortion) -> `Alloc_Check` (1 untimed pass with `obench.Counting_Allocator` paused outside `phase_begin`..`phase_end`). Never wrap `context.allocator` with a counting allocator during `.Timed` passes.
4. **Wire & Storage Magic Headers:**
   - Wire packets: `HPKT\x02\x00\x00\x00` and `OBRC\x02\x00\x00\x00`. Legacy `v1` headers must be cleanly rejected without leaking memory.
   - Store format (`v5` layout): Root `xitdb` `Moment` maps contain `"catalog"` (`HCAT\x01`), optional `"runs"` (`CZPK\x04` hot packets), and optional `"cold_chunks"` (`CZCH\x02` transposed columnar chunks). Legacy non-catalog `xitdb` moments must return `false` / empty results cleanly without panicking.
   - Sample codec (`BU`): `compress_samples_u64` races `.Raw`, `.Zlib_Delta_Varint`, `.Zlib_BSS`, `.Zlib_Delta_BSS`, and `.Zlib_Block_GCD`. `flags == 0` encodes `u64` `samples_batch_ns`; `flags == 1` encodes zigzag-mapped `i64` `samples_fs` (used when pooled runs have mixed `ops_per_sample`). Legacy `BF` float sample headers must be rejected.
5. **Canonical 35-Column Export Schema (`store/export_schema.odin`):**
   - `EXPORT_COLUMNS` defines 34 scalar columns (`EXPORT_SCALAR_COL_COUNT :: 34`) plus `samples_blob` (`EXPORT_TOTAL_COL_COUNT :: 35`). Arrow and Parquet emit all 35 columns; CSV/TSV emit the 34 scalar columns; JSON/JSONL emit the 34 scalar columns plus `samples_batch_ns` (when uniform `ops_per_sample`) and `samples_ns`. Keep all exporters driven from `EXPORT_COLUMNS`.

## 5. 4-Layer ATDD `specs/` Architecture

New user-facing features or bugfixes must include black-box behavioral coverage in `specs/`:

- **Layer 1 (`specs/*_spec_test.odin`):** Declarative `spec_*` tests using `given_*`, `upon_*`, `viewing_*` / `shows_*`, and `then_*` domain verbs. No raw storage cursors, file paths, or low-level assertions in Layer 1.
- **Layer 2 (`specs/dsl_test.odin`):** `World` state management (`world_init(&w, t)` in-place; never return `World` by value because `vmem.Arena` pointers cannot move) and DSL verbs. Every DSL verb that calls `testing.expect*` **must** accept `loc := #caller_location` and forward `loc = loc`, returning early on `!testing.expect*`. Use constructor functions (e.g., `verdict_case`, `export_format_case`, `cli_guard_case`) to capture `#caller_location` per table row.
- **Layer 3 (`specs/driver_test.odin`):** Protocol drivers invoking public `hugi` / `hugi_store` APIs or executing `./bin/hugi` subprocesses in isolated temp workspaces. Register external temp directories with `testing.cleanup` so timeouts or `fail_now` still clean up disk artifacts.
- **Property Tests (`specs/invariants_prop_test.odin`):** `prop_*` tests seeded from `t.seed` with `testing.set_fail_timeout` and per-iteration `defer free_all(context.temp_allocator)`.

## 6. Upstream `obench` Dependency

`deps/obench` tracks upstream `zeybek/obench` (`main`). Never edit files inside `deps/*` directly from `hugi`; submit upstream changes to `zeybek/obench` and update the submodule pointer deliberately.
