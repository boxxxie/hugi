# Product Guidelines

1. **API-First Simplicity Over Visible Storage Mechanics:**
   - Storage layout, sample codecs, chunking, and catalog indexing must stay encapsulated behind `store/` and the `hugi` CLI (`run`, `ingest`, `history`, `inspect`, `compare`, `compare-1v1`, `export`, `compact`).
   - Internal optimizations must never force complexity onto callers or external `hugi` imports.

2. **Pre-1.0 Format Cleanliness:**
   - Before `1.0`, prefer one canonical, well-tested on-disk representation (`HCAT\x01` + `CZPK\x04` + `CZCH\x02`, `HPKT\x02` / `OBRC\x02`) rather than carrying superseded internal store formats, experimental toggles, or dead fallback decoders.
   - Keep external boundary importers (`read_jsonl_packets` for `.jsonl` and `read_obench_json_packets` for `obench` `.json`) intact so upstream/legacy text exports remain ingestible.

3. **Exact Timing Precision & Zero Memory Leaks:**
   - Derive all sub-nanosecond timing statistics cleanly from `(samples_batch_ns: []u64, ops_per_sample: u64)` into `i64` femtoseconds (`DECIMAL(18,6)` ns); avoid floating-point intermediate rounding in persisted samples or stats.
   - Every test in `tests/` must pass under `-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true` with `0` leaked bytes and `0` bad frees.

4. **Strict Package Isolation:**
   - Never introduce dependencies on `deps/xitdb` or `deps/skadi` into `hugi/` (`package hugi`).
   - Keep upstream fixes in `deps/*` cleanly separated (modify upstream repositories and advance submodule commits deliberately rather than hacking files directly under `deps/`).

5. **Markdown Documentation Formatting:**
   - Use inline code spans (e.g., `` `duration_ns / 1e6` ``, `` `O(hot_runs)` ``) for identifiers, units, complexity bounds, and formulas instead of `$...$` / `$$...$$` LaTeX math blocks.
