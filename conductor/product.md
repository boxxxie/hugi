# Product Definition: `hugi` (`odin/hugi`)

`hugi` is a pure-Odin benchmarking library, compressed transactional history store, statistical comparator, and CLI built to replace bespoke per-repository benchmark harnesses, verbose JSONL history logs, and external Python comparison scripts.

## Core Capabilities & Architectural Boundaries

1. **Zero-Dependency Benchmark Runner (`hugi/` — `package hugi`):**
   - Imports **only** `base:*`, `core:*`, and `../deps/obench/obench` — never `deps/xitdb` or `deps/skadi` — so benchmarked libraries (`xitdb`, `skadi`, `mimir`, `temple`, `heimdall`) can import `hugi` without circular package dependencies.
   - Exposes `obench` micro-benchmark primitives (`step`, `set_bytes`, `set_items`, `expect_zero_allocs`, `param`, `threads`, `run_parallel`) with untimed allocation checking (`untimed_alloc_check = true`) and Linux vDSO `clock_gettime` (~42 ns overhead under `-o:speed`).
   - Supports multi-phase pipelines (`group_pipeline`, `scoped_phase`, `phase_begin`/`phase_end`, `phase_set_footprint`, `phase_metric`) where shared setup and teardown stay excluded from timing and allocation wrappers.
   - Emits compact integer binary `HPKT` `Run_Packet` (`\x02`) / `OBRC` (`\x02`) payloads, plus importers for `obench` `.json` reports and `.jsonl` histories (`read_obench_json_packets`, `read_jsonl_packets`).

2. **Canonical `v5` Transactional Store (`store/` — `package hugi_store`):**
   - Persists histories in a single crash-safe `xitdb` `.hugidb` file whose `Moment` map stores coarse-grained packed blobs:
     - `"catalog"` (`HCAT\x01`): Consolidated Zlib-9 metadata catalog (string symbol table, static benchmark descriptors, chronological run metadata, snapshot pointers, and cold chunk override flag).
     - `"runs"` (`CZPK\x04`): Compressed single-run hot packets using exact rational integer `samples_batch_ns` + `ops_per_sample`.
     - `"cold_chunks"` (`CZCH\x02`): Auto-sealed `32`-run transposed columnar chunks sharing cross-commit Zlib compression and `U64_Codec` (`Raw`, `Zlib_Delta_Varint`, `Zlib_BSS`, `Zlib_Delta_BSS`, `Zlib_Block_GCD`) sample compression.
   - Treats `(samples_batch_ns: []u64, ops_per_sample: u64)` as the single source of truth, deriving all summary statistics in exact `i64` femtoseconds (`DECIMAL(18,6)` ns) with zero float rounding drift.
   - Supports in-memory Copy-on-Write trial runs via `xitdb.Core_Overlay` (`--overlay`) and `O(hot_runs)` compaction (`hugi compact`).

3. **Statistical Analysis & Interchange (`store/` + `cmd/hugi/` -> `bin/hugi`):**
   - Standalone CLI commands: `run`, `ingest`, `history`, `inspect`, `compare`, `compare-1v1`, `export`, and `compact`.
   - Pools multi-run samples per `(commit, lang, benchmark)` and runs Mann-Whitney U + Welch `t` comparisons (with byte-footprint parity validation in `compare-1v1`).
   - Exports `35`-column snapshots or longitudinal series (`--all-commits`, `--all-runs`) to Apache Arrow IPC / Feather v2 (`Decimal64(18, 6)` + `LZ4_FRAME`), pure-Odin GZIP Parquet (`INT64` `DECIMAL(18,6)`), JSON, JSONL, CSV, TSV, and Markdown tables (`--update-readme`).
