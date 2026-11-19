# `hugi` Usage Rules

Concise, high-density rules and patterns for developers and AI coding agents writing Odin benchmarks with `hugi`, querying/exporting `.hugidb` stores via `hugi_store`, or driving the `hugi` CLI in CI and polyglot workflows.

---

## 1. Collections & Build Setup

* **Benchmark packages only need `hugi` and `obench`:** The `hugi` runner package has zero dependency on `xitdb` or `skadi`.
* **`ols.json` auto-discovery:** `hugi run <pkg_dir>` walks upward to `.git` and automatically passes non-reserved `collections` (`core`, `base`, `vendor` are skipped) and `-custom-attribute:*` / `-ignore-unknown-attributes` from `ols.json` to `odin build`, defaulting to `-o:speed` unless an `-o:*` flag is already present.
* If `hugi` is not in your `ols.json`, set `HUGI_HOME=/path/to/hugi` so `hugi run` injects `-collection:hugi` and `-collection:obench` automatically.

```json
{
	"collections": [
		{ "name": "hugi", "path": "./deps/hugi/hugi" },
		{ "name": "obench", "path": "./deps/hugi/deps/obench/obench" }
	]
}
```

Add `{ "name": "hugi_store", "path": "./deps/hugi/store" }`—along with `xitdb` (`./deps/hugi/deps/xitdb/xitdb`) and `skadi` (`./deps/hugi/deps/skadi/skadi`)—**only** when calling the database/export APIs programmatically from Odin, and import with `import hugi "hugi:."` and `import store "hugi_store:."` (avoid mapping `hugi` to `./deps/hugi` if you rely on `HUGI_HOME`, because `hugi run` injects `-collection:hugi=<repo_root>/hugi`).

---

## 2. Benchmark Suite Entrypoints & Micro-Benchmarks

### Suite Entrypoint Contract (Required for `hugi run`)

`hugi run` executes your compiled binary with `--packet-out <tmp>.hpk` (plus `--runs`, `--warmup`, `--groups`, `--filter`, `--lang`, `--commit`, `--quiet`). Your `main` **must** preserve CLI config parsing from `hugi.default_suite_config()` (used automatically when `config == nil`) and exit non-zero when `hugi.suite_run` fails.

```odin
// DO: Let default_suite_config() parse CLI flags (--packet-out, --filter, --runs) and propagate exit status
main :: proc() {
	suite := hugi.suite_create("my_benchmarks")
	defer hugi.suite_destroy(&suite)

	hugi.bench(&suite, "parse_header", bench_parse_header, zero_alloc = true)

	if !hugi.suite_run(&suite) {
		os.exit(1)
	}
}

// DON'T: Construct a zero-initialized Suite_Config{} literal (wipes --packet-out and breaks `hugi run`!)
main :: proc() {
	bad_cfg := hugi.Suite_Config{runs = 5} // WRONG: loses obench defaults and CLI --packet-out
	suite := hugi.suite_create("my_benchmarks", bad_cfg)
	_ = hugi.suite_run(&suite) // WRONG: ignores @zero_alloc failures by exiting 0
}
```

If customizing `Suite_Config`, always start from `cfg := hugi.default_suite_config()` and mutate fields on `cfg` without overwriting `cfg.packet_out_path`.

### Stateless & Parameterized Micro-Benchmarks

```odin
// DO: Allocate setup before `for hugi.step(b)`, sink outputs into `black_box`, and declare throughput bytes
bench_fnv1a :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 16)
	buf := make([]u8, n)
	defer delete(buf)

	hugi.set_bytes(b, u64(n))
	hugi.expect_zero_allocs(b)

	for hugi.step(b) {
		_ = hugi.black_box(fnv1a(buf))
	}
}

// Registering parameterized / multi-threaded groups:
g := hugi.group_add(&suite, "hash")
hugi.group_params(g, []int{64, 256, 4096})
hugi.group_threads(g, []int{1, 4})
hugi.group_bench(g, "fnv1a", bench_fnv1a, zero_alloc = true)
```

### Running Inside `odin test`

```odin
// DO: Use hugi.run_test(t, &suite) inside @(test) procedures
@(test)
test_bench_alloc_contracts :: proc(t: ^testing.T) {
	suite := hugi.suite_create("alloc_gate")
	defer hugi.suite_destroy(&suite)

	hugi.bench(&suite, "fnv1a", bench_fnv1a, zero_alloc = true)
	hugi.run_test(t, &suite)
}
```

---

## 3. Stateful Multi-Phase Pipelines (`hugi.Pipeline`)

Use `hugi.group_pipeline` when sequential operations share built state (e.g., `insert -> lookup -> scan -> compact`) and you want zero counting-allocator overhead during timed passes.

### Critical Execution Lifecycle Rule

`hugi` invokes your `Pipeline_Proc` **`warmup + runs + 1` times** (`Warmup` passes -> `Timed` passes with unwrapped allocators -> 1 untimed `Alloc_Check` pass), resetting a scratch `context.temp_allocator` arena after each pass.

```odin
// DO: Create and `defer` destroy shared state INSIDE the Pipeline_Proc so every pass starts clean
bench_kv :: proc(p: ^hugi.Pipeline) {
	n := p.has_param && p.param > 0 ? p.param : 1024
	db := kv_open_memory(n) // Excluded from phase timing and phase alloc counts
	defer kv_close(&db)     // Excluded from phase timing and phase alloc counts

	{
		ph := hugi.scoped_phase(p, "insert", ops = n, bytes_per_op = 16)
		for i in 0 ..< n {
			kv_put(&db, u64(i), u64(i * 3))
		}
		hugi.phase_set_footprint(ph, kv_committed_bytes(&db))
	}

	{
		ph := hugi.scoped_phase(p, "lookup", ops = n, bytes_per_op = 8, zero_alloc = true)
		hits := 0
		for i in 0 ..< n {
			if v, ok := kv_get(&db, u64(i)); ok {
				_ = hugi.black_box(v)
				hits += 1
			}
		}
		hugi.phase_metric(ph, f64(hits) / f64(n) * 100.0, "hit%")
	}
}

// DON'T: Mutate non-reset external state via user_ptr assuming Pipeline_Proc runs only once
// DON'T: Nest phases deeper than hugi.MAX_PHASE_DEPTH (8) or attach > hugi.MAX_METRICS (8) metrics per phase
// DON'T: Put `zero_alloc = true` on an outer nested phase — inner `phase_begin`/`phase_end` resets and pauses the shared alloc counter (`zero_alloc = true` enforces 0 `context.allocator` allocs on leaf phases; `context.temp_allocator` scratch is tracked separately)
```

---

## 4. Programmatic `hugi_store` & Femtosecond Precision Rules

### Fixed-Point Femtoseconds (`i64`), Never Float Nanoseconds

All duration fields on `hugi.Record`, `hugi_store.Pooled_Record`, `Comparison_Row`, and `Cross_Lang_Row` (`min_fs`, `p25_fs`, `p50_fs`, `p75_fs`, `p95_fs`, `p99_fs`, `max_fs`, `mean_fs`, `std_dev_fs`, `ci95_fs`, `iqr_fs`, `mad_fs`) are **`i64` femtoseconds** (`1 ns = 1,000,000 fs`, `hugi.FS_PER_NS`).

```odin
// DO: Use hugi's fixed-point conversion and formatting helpers
med_str := hugi.format_duration_fs(rec.p50_fs, context.temp_allocator) // e.g., "5.00 ps", "42.50 ns"
med_ns  := hugi.fs_to_ns_f64(rec.p50_fs)                               // f64 nanoseconds when needed
hugi.write_decimal_ns_fs(&sb, rec.p50_fs)                              // exact "0.005000" ns string

// DON'T: Read `rec.p50_ns` (does not exist on Odin structs) or treat `rec.p50_fs` as nanoseconds
```

### Store Ownership, Overlays & Compaction

```odin
// DO: Pair every store open/query/comparison with its matching `*_destroy` / `store_close`
st, ok := store.store_open("benchmarks/history.hugidb")
if !ok { return }

recs := store.store_load_pooled_records(&st, lang = "odin", commit = "", filter = "kv::")
defer store.pooled_records_destroy(recs)

_ = store.export_parquet("reports/latest.parquet", recs)

// DO: Close `Store` BEFORE compacting the same file path (compact atomically renames over db_path)
store.store_close(&st)
before, after, comp_ok := store.store_compact("benchmarks/history.hugidb")

// DO: Use `store_open_overlay` for non-destructive Copy-on-Write in-memory trial runs
// (Note: `store_open_overlay` requires `path` to already exist on disk; use `":memory:"` with `store_open` otherwise)
ov, ov_ok := store.store_open_overlay("benchmarks/history.hugidb")
if ov_ok {
	defer store.store_close(&ov) // Disk file remains byte-for-byte untouched
}
```

### Decoding `samples_blob` from Arrow IPC / Parquet Exports

When reading `samples_blob` back in Odin, always use `store.decompress_exported_samples_fs(blob, ops_per_sample, allocator)` rather than `decompress_samples_u64` directly—pooled records with uniform `ops_per_sample` store `flags = 0` (`u64` batch ns), while pooled records across runs with differing `ops_per_sample` store `flags = 1` (signed `i64` femtoseconds).

---

## 5. CLI, CI Gating & Polyglot Workflows

```sh
# DO: Gate pull requests against a baseline commit with Mann-Whitney U + Welch t-test
# (`--baseline-commit` and `--commits` prefix-match stored SHAs; expand symbolic refs via git rev-parse)
hugi run ./benchmarks --db benchmarks/history.hugidb --baseline-commit "$(git rev-parse --short=12 origin/main)" --fail-on-regression --threshold 5.0

# DO: Use --overlay locally with a distinct --commit tag so the trial run does not pool into HEAD
hugi run ./benchmarks --overlay --commit wip-trial --baseline-commit "$(git rev-parse --short=12 HEAD)"

# DO: Choose ONE export scope (--all-commits, --all-runs, or --commit <sha>; never combine them)
hugi export --db benchmarks/history.hugidb --out latest.md --update-readme README.md
hugi export --db benchmarks/history.hugidb --all-commits --out series.parquet
hugi export --db benchmarks/history.hugidb --all-runs --out raw_runs.jsonl

# DO: Stream text exports or statistical comparisons cleanly to stdout (`--out -`) for custom client renderers
hugi export --db benchmarks/history.hugidb --lang all --format jsonl --out -
hugi compare --db benchmarks/history.hugidb --last --format json --out -
hugi compare-1v1 --db benchmarks/history.hugidb --langs odin,zig --format json --out -
```

* **README Markers:** Ensure `<!-- BEGIN_BENCHMARK_TABLE -->` and `<!-- END_BENCHMARK_TABLE -->` exist in the target Markdown file before running `hugi export --update-readme <path>` (missing markers return exit code `1`).
* **Custom Client Rendering:** `hugi` intentionally emits a clean 9-column default Markdown table (`--update-readme`) plus machine-readable `parquet`, `arrow`, `json`, `jsonl`, `csv`, and `compare`/`compare-1v1 --format json|csv` streams. Write project-specific grouped/tiered/pivoted tables on the client side (via `hugi_store`, AOT `temple` templates over `--format json --out -`, DuckDB SQL over Parquet, or Python/shell scripts).
* **`--lang` Defaults, Case Sensitivity & Empty Flags:** `hugi inspect`, `hugi compare`, and `hugi export` default to `--lang odin`—pass `--lang <lang>` for external languages or `--lang all` (or `*`) to export across all languages. Always pass lowercase `--lang` tags (compiled binaries lowercase `--lang`, whereas CLI queries are case-sensitive), and pass empty values as two tokens (`--lang ""`, never `--lang=""`, which consumes the next token). (`--out -` is only valid for text formats, never `arrow` or `parquet`.)
* **Failing Runs Still Record Unless `--overlay` / `--no-db`:** If a benchmark binary writes a packet and exits `1` due to `@zero_alloc` violations or errors, `hugi run` still ingests that packet into `.hugidb` before returning `1`. Pass `--overlay` or `--no-db` during local debugging.
* **Selective Runs Are Safe:** Running `hugi run ./benchmarks -f lookup` (or `--groups` other than `"all"`) marks the packet `selective = true` and updates *only* matching benchmarks in the language's latest snapshot while preserving untouched benchmarks from prior commits.
* **Cross-Language 1v1 (`compare-1v1`) & JSONL Ingestion:** Emit JSONL from non-Odin harnesses with `name` matching the exact target `full_name` (`"group::bench"` or `"group::bench[param]/tN"`, as `read_jsonl_packets` copies `name` directly to `full_name` without prepending `group`), `lang`, `commit`, distinct `run_id` (omitting `run_id` defaults every file for the same `(commit, lang)` to `jsonl-<commit>-<lang>`, overwriting on ingest), `ops`, `samples_batch_ns` (or `samples_ns`—providing only `median_ns` synthesizes a 1-sample array and zeroes dispersion stats), and `bytes_used` (mapped to `footprint_bytes`). Ingest via `hugi ingest results.jsonl` (avoid passing multiple `obench` `.json` files in one `hugi ingest` call, as they share the same 1-second `run-<unix_seconds>` ID) and run `hugi compare-1v1 --langs odin,zig`—mismatched `footprint_bytes` between languages are flagged `[MISMATCH]`.

---

## 6. Common LLM Hallucinations to Avoid

| Hallucination / Mistake | Actual `hugi` Contract |
| :--- | :--- |
| Accessing `rec.p50_ns`, `rec.mean_ns`, or `rec.samples_ns` on Odin `Record` / `Pooled_Record` | Odin structs store `i64` femtoseconds (`p50_fs`, `mean_fs`, `samples_fs`) and `u64` `samples_batch_ns`. (`*_ns` is the exported Arrow/Parquet/CSV/JSON column name.) |
| Passing `hugi.Suite_Config{...}` from scratch | Always call `cfg := hugi.default_suite_config()` first so `obench` defaults and CLI flags (`--packet-out`, `--filter`, `--runs`) stay intact. |
| Allocating pipeline state once outside `Pipeline_Proc` | `Pipeline_Proc` runs `warmup + runs + 1` passes; initialize and `defer` destroy state inside `Pipeline_Proc` on each pass. |
| Combining `--all-commits` with `--all-runs` or `--commit` in `hugi export` | Rejected by CLI validation (`exit 1`). Pick Snapshot (default / `--commit`), `--all-commits`, or `--all-runs`. |
| Calling `store_compact(path)` while a `Store` is still open on `path` | Close the `Store` first (`store_close(&st)`); `store_compact` atomically replaces `path` on disk. |
| Importing `hugi_store` just to write benchmarks | Benchmark binaries only import `hugi` (`-collection:hugi` + `-collection:obench`). |
| Using bare `import "hugi"` in a benchmark package | In Odin, an import without `:` is a relative directory import (`./hugi`). Use `import hugi "hugi:."` when `-collection:hugi` points to `.../hugi` (as in `ols.json` and `hugi run`), or `import "hugi:hugi"` when `-collection:hugi` points to the `hugi` repo root. |
| Passing `HEAD`, `main`, or `origin/main` directly to `--baseline-commit` / `--commits` | Both flags prefix-match stored 12-char hex SHAs without invoking `git`. Expand symbolic refs first (`$(git rev-parse --short=12 HEAD)`), and pass a distinct `--commit` tag on `--overlay` trial runs so they do not pool into `HEAD`. |
| Expecting custom `Metric`s, `median_cycles`, or OS/arch strings in `EXPORT_COLUMNS` | Custom metrics (`report_metric`/`phase_metric`), `median_cycles`, `resizes_per_op`, and environment metadata live in `.hugidb` and `hugi.Record` (and live `suite_run` output), not in the 35-column CSV/Parquet/Arrow/JSON exports. |