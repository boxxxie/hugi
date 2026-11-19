# `hugi`

[![CI](https://github.com/boxxxie/hugi/actions/workflows/ci.yml/badge.svg)](https://github.com/boxxxie/hugi/actions/workflows/ci.yml)
[![Version](https://img.shields.io/badge/version-0.1.0-blue.svg)](cmd/hugi/main.odin)
[![Odin](https://img.shields.io/badge/Odin-dev--2026-3882D2?logo=odin&logoColor=white)](https://odin-lang.org/)
[![Precision](https://img.shields.io/badge/precision-1%20fs%20(10%E2%81%BB%C2%B9%E2%81%B5%20s)-0A7B83)](#architecture-how-hugidb-beats-parquet--preserves-femtoseconds)
[![Store Format](https://img.shields.io/badge/store-xitdb%20v5-5C6BC0.svg)](store/format.odin)
[![Export](https://img.shields.io/badge/export-Arrow%20IPC%20%7C%20Parquet-orange.svg)](store/export_schema.odin)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](#license)

**Git-native longitudinal benchmark runner, ultra-compressed historical store, statistical auditor, and multi-format exporter.**

`hugi` is a benchmark harness and historical performance database written in Odin. Instead of treating benchmarks as ephemeral terminal output or ad-hoc log files, `hugi` records every run against its Git commit SHA inside a compact, transactional `.hugidb` file—allowing you to track performance over the lifetime of a codebase, add or filter benchmarks arbitrarily without breaking schemas, audit regressions with statistical rigor, and export clean datasets or reports into standard analytics formats.

> **Built on [`obench`](https://github.com/zeybek/obench):** `hugi` relies heavily on [`obench`](https://github.com/zeybek/obench) (`deps/obench`) as its core micro-benchmarking and measurement engine. Its `Bencher` / `Parallel_Bencher` / `Group` primitives, `step` loop, optimizer barriers (`black_box`, `clobber_memory`), calibrated platform clock timing, `Counting_Allocator` heap/temp tracking, and terminal report formatter are powered directly by `obench`, which `hugi` extends with stateful multi-phase `Pipeline` lifecycles, exact femtosecond storage, longitudinal `.hugidb` history, statistical regression gates, and dataset exports.

---

## Why `hugi`?

Most benchmarking workflows break down once a project grows past a handful of micro-benchmarks:

1. **Benchmark results are usually ephemeral.** Numbers get pasted into pull requests and lost. `hugi` ties every run to its 12-character Git SHA (supporting standard repos, detached HEADs, `packed-refs`, and linked Git worktrees), OS/architecture, and compiler optimization mode.
2. **Benchmark suites evolve constantly.** Over months of development, you add new benchmarks, parameterize groups, or run selective filters (`-f hash`) while iterating locally. `hugi` maintains per-benchmark snapshot lineage: selective runs update only touched benchmarks while preserving untouched baselines, and newly added benchmarks join the historical timeline seamlessly without schema migrations.
3. **Floating-point nanoseconds lose precision.** Standard `f64` nanosecond timers suffer from rounding drift on batched sub-nanosecond SIMD kernels and large multi-second pipelines alike. `hugi` computes, pools, and exports all durations in exact 64-bit fixed-point **femtoseconds** (`10^-15 s`, or `1 ns = 10^6 fs`), backed by 128-bit intermediate scaling and native `DECIMAL(18, 6)` nanosecond exports.
4. **Raw sample histories bloat repositories—even in Parquet.** Keeping raw per-iteration sample arrays across hundreds of commits makes JSON/CSV unusable and bloats standard columnar files. `hugi`'s `.hugidb` format combines global symbol/descriptor deduplication, transposed cold-history rollups, and a 5-way racing integer sample codec to achieve smaller footprints than Apache Parquet.
5. **Zero format lock-in.** You never need to learn `.hugidb` internals to analyze or share your data. `hugi` exports directly to **Apache Arrow IPC (Feather v2)**, **Apache Parquet**, **JSON**, **JSONL**, **CSV**, **TSV**, and **GitHub-Flavored Markdown** (including automated `README.md` marker updates).

---

## Key Capabilities

* **Zero-Store Runner Isolation:** `hugi/` imports only `base:*`, `core:*`, and `deps/obench/obench`—never `deps/xitdb` or `deps/skadi`—so benchmarked libraries (including `xitdb` and `skadi` themselves) never hit circular package dependencies.
* **Micro-Benchmarks + Stateful Multi-Phase Pipelines:** Combines `obench` micro-benchmark loops (with vDSO `clock_gettime` on 64-bit Linux, ~42 ns timer overhead under `-o:speed`) with stateful `Pipeline` lifecycles (`insert -> lookup -> scan`) where shared state carries across phases, setup/teardown is excluded, and timed passes execute with **unwrapped allocators** (`0 ns` counting overhead) followed by a dedicated untimed `@zero_alloc` verification pass.
* **Statistical Auditing & CI Gates:** Pools samples across repeated runs of the same commit and evaluates changes using the **Mann-Whitney U** non-parametric rank test (`p < 0.05`) alongside **Welch's `t`-test** with Student's `t` critical values and geometric mean deltas.
* **Cross-Language 1v1 Audits (`compare-1v1`):** Compare implementations across languages (e.g., `odin` vs `zig` or `rust`) on matching benchmark names, automatically flagging domain memory/disk footprint discrepancies (`[MISMATCH]`) so speedups achieved by trading off memory are immediately visible.
* **Copy-on-Write Trial Runs (`--overlay`):** Execute and compare experimental local changes against your `.hugidb` history inside an in-memory Copy-on-Write (`xitdb.Core_Overlay`) branch without modifying a single byte on disk.
* **Polyglot Ingestion:** Use `hugi` as a standalone historical store and report generator for any language by ingesting JSONL benchmark logs, `obench` JSON reports, or binary `HPKT\x02` (`.hpk`/`.bpk`) packets.

---

## Clone, Prerequisites & Building

### Clone

```bash
git clone https://github.com/boxxxie/hugi.git
cd hugi
git submodule update --init
```

Use non-recursive `git submodule update --init` (this skips `deps/xitdb`'s optional Zig reference submodules).

### Prerequisites

* [Odin compiler](https://odin-lang.org/) (`odin` available on `PATH` or specified via `ODIN=/path/to/odin`).
* The zero-store `hugi/` runner requires only the Odin compiler and `deps/obench`.
* Building `store/` and `bin/hugi` additionally requires system development headers for `zlib` (`zlib1g-dev` on Debian/Ubuntu) and `liblz4` (`liblz4-dev`).

### Build from Source

```bash
# Build the standalone CLI binary into ./bin/hugi (-o:speed)
make build

# Symlink ~/.local/bin/hugi -> ./bin/hugi
make install

# Run unit tests, CLI tests, and 4-layer ATDD specifications (with memory leak checking)
make test
```

> **Symlink vs. Copy:** `make install` creates a symlink into this repository so `hugi run` can locate `hugi/` and `deps/obench/obench` by walking upward from the binary when `ols.json` omits them. If you copy `bin/hugi` to another directory, set `HUGI_HOME=/path/to/hugi` or declare both collections in your project's `ols.json`.

---

## Quick Start (CLI Workflow)

### 1. Run Benchmarks & Record History

Point `hugi run` at any Odin benchmark package. It automatically discovers collections and custom attributes from your nearest `ols.json`, compiles with `-o:speed` (unless overridden), runs the suite, and commits the resulting packet into `benchmarks/history.hugidb` (or `history.hugidb`):

```bash
# Build, run, and record against the current Git HEAD SHA
./bin/hugi run examples/micro_and_phases --runs 5

# Run a specific subset while iterating locally (updates only matching benchmarks in snapshot)
hugi run ./benchmarks -f "kv_lifecycle" --runs 10

# Trial run in an in-memory CoW overlay (compare against baseline without touching disk)
hugi run ./benchmarks --overlay --baseline-commit a1b2c3d4e5f6
```

> **Note:** Even when a benchmark fails (`@zero_alloc` violation or benchmark error) and `hugi run` exits `1`, the run packet is still ingested into `.hugidb` unless `--overlay` or `--no-db` is passed.

### 2. Audit History & Inspect Quantiles

```bash
# View chronological commit summaries (languages, run counts, benchmark counts, total samples)
hugi history

# View individual runs
hugi history --runs --limit 10

# Inspect pooled quantiles (min, p25, p50, p75, p95, p99, CI95, IQR, MAD), CV%, allocs, and footprint
hugi inspect
hugi inspect "hash::fnv1a" --commit a1b2c3d4
```

### 3. Detect Regressions & Gate CI

```bash
# Compare the last two recorded commits (or last two runs)
hugi compare --last

# Audit a specific commit range and fail CI (non-zero exit) on statistically significant regressions > 3%
hugi compare --commits "$(git rev-parse --short=12 main)..$(git rev-parse --short=12 HEAD)" --threshold 3.0 --fail-on-regression

# Run and gate against a baseline commit in one step
hugi run ./benchmarks --baseline-commit a1b2c3d4e5f6 --fail-on-regression
```

### 4. Export Reports & Datasets

```bash
# Auto-update <!-- BEGIN_BENCHMARK_TABLE --> ... <!-- END_BENCHMARK_TABLE --> in your README
hugi export --update-readme README.md

# Export full commit-by-commit longitudinal time series to Parquet or Arrow IPC
hugi export --all-commits --out reports/history.parquet
hugi export --all-commits --out reports/history.arrow

# Compact the database file and seal hot runs into transposed columnar cold chunks
hugi compact
```

---

## Writing Benchmarks in Odin

Add `hugi` (or symlink/submodule it) and import `hugi "hugi:."` (configured via `ols.json` or `HUGI_HOME`; examples inside this repository such as [`examples/micro_and_phases/`](examples/micro_and_phases/) use relative `import hugi "../../hugi"`). `hugi` supports both classic stateless micro-benchmarks and stateful multi-phase pipelines in the same suite:

```odin
package bench_example

import hugi "hugi:."
import "core:os"

// 1. Stateless / Parameterized Micro-Benchmark
bench_fnv1a :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 16)
	buf := make([]u8, n)
	defer delete(buf)

	hugi.set_bytes(b, u64(n))
	hugi.expect_zero_allocs(b)

	for hugi.step(b) {
		h := u64(14695981039346656037)
		for byte in buf {
			h ~= u64(byte)
			h *= 1099511628211
		}
		_ = hugi.black_box(h)
	}
}

// 2. Stateful Multi-Phase Pipeline
// Setup and teardown outside `scoped_phase` are excluded from timing and allocation counts.
// Timed passes run with unwrapped allocators; allocation counting runs in a separate untimed pass.
bench_kv_lifecycle :: proc(p: ^hugi.Pipeline) {
	n := p.has_param && p.param > 0 ? p.param : 1024
	table := make(map[u64]u64, n)
	defer delete(table)

	{
		ph := hugi.scoped_phase(p, "insert", ops = n, bytes_per_op = 16)
		for i in 0 ..< n {
			k := u64(i) * 2654435761
			table[k] = k ~ u64(i)
		}
		hugi.phase_set_footprint(ph, u64(len(table) * 16))
	}

	{
		ph := hugi.scoped_phase(p, "lookup", ops = n, bytes_per_op = 8, zero_alloc = true)
		hits := 0
		for i in 0 ..< n {
			k := u64(i) * 2654435761
			if v, ok := table[k]; ok {
				_ = hugi.black_box(v)
				hits += 1
			}
		}
		hugi.phase_metric(ph, f64(hits) / f64(n) * 100.0, "hit%")
	}
}

main :: proc() {
	suite := hugi.suite_create("storage_benchmarks")
	defer hugi.suite_destroy(&suite)

	// Register a parameterized micro-benchmark group
	hash_grp := hugi.group_add(&suite, "hash")
	hugi.group_params(hash_grp, []int{64, 256, 1024})
	hugi.group_bench(hash_grp, "fnv1a", bench_fnv1a, zero_alloc = true)

	// Register a stateful multi-phase pipeline
	hugi.group_pipeline(&suite, "kv", bench_kv_lifecycle, param = 1024, has_param = true)

	if !hugi.suite_run(&suite) {
		os.exit(1)
	}
}
```

### Integrating with `odin test`

You can also execute benchmark suites inside standard Odin test suites—failing the test automatically on `@zero_alloc` violations, benchmark errors, or I/O failures:

```odin
import "core:testing"

@(test)
test_zero_alloc_benchmarks :: proc(t: ^testing.T) {
	suite := hugi.suite_create("ci_sanity")
	defer hugi.suite_destroy(&suite)

	hugi.bench(&suite, "fast_path", bench_fnv1a, zero_alloc = true)
	hugi.run_test(t, &suite)
}
```

---

## Programmatic `hugi_store` API (Odin)

In addition to the `hugi` CLI, you can embed `.hugidb` storage, Copy-on-Write overlays, multi-run sample pooling, statistical auditing, and multi-format exporting directly inside custom Odin tools, dashboards, or CI runners.

### Compiler Collections

While benchmark binaries only need `hugi` and `obench` (`-collection:hugi=./deps/hugi/hugi`, matching `HUGI_HOME` in `hugi run`), tools that also import `hugi_store` must pass the transitive vendored collections (`obench`, `xitdb`, and `skadi`) in `ols.json` or on the command line:

```bash
odin build ./cmd/my_audit_tool \
  -collection:hugi=./deps/hugi/hugi \
  -collection:hugi_store=./deps/hugi/store \
  -collection:obench=./deps/hugi/deps/obench/obench \
  -collection:xitdb=./deps/hugi/deps/xitdb/xitdb \
  -collection:skadi=./deps/hugi/deps/skadi/skadi
```

### End-to-End Library Example: Ingest, Compare & Export

```odin
package custom_audit

import "core:fmt"
import "core:os"
import hugi "hugi:."
import store "hugi_store:."

run_and_audit :: proc(db_path: string, baseline_sha: string) -> bool {
	// 1. Execute a benchmark suite silently in-process
	cfg := hugi.default_suite_config()
	cfg.quiet = true
	suite := hugi.suite_create("engine_suite", cfg)
	defer hugi.suite_destroy(&suite)

	// (... register benchmarks / pipelines on &suite ...)
	if !hugi.suite_execute(&suite) {
		return false
	}

	// 2. Open the transactional .hugidb store
	//    (Or use `store.store_open_overlay(db_path)` for a RAM-only Copy-on-Write trial branch)
	st, open_ok := store.store_open(db_path)
	if !open_ok {
		return false
	}

	// 3. Commit the run packet as a new CoW Moment
	if !store.store_ingest_packet(&st, suite.last_packet) {
		store.store_close(&st)
		return false
	}

	// 4. Pool samples for baseline vs. current commit (all durations in exact i64 femtoseconds)
	base := store.store_load_pooled_records(&st, lang = "odin", commit = baseline_sha)
	defer store.pooled_records_destroy(base)

	cand := store.store_load_pooled_records(&st, lang = "odin", commit = suite.last_packet.commit)
	defer store.pooled_records_destroy(cand)

	// 5. Run Mann-Whitney U (p < 0.05) + Welch's t-test comparison
	rep := store.compare_records(base, cand, threshold_pct = 5.0)
	defer store.comparison_report_destroy(&rep)

	table := store.format_comparison_table(rep, baseline_sha, suite.last_packet.commit, context.temp_allocator)
	fmt.print(table)

	// 6. Export longitudinal commit series to Parquet & update README markers
	series := store.store_load_commit_series_records(&st, lang = "odin")
	defer store.pooled_records_destroy(series)
	_ = store.export_parquet("reports/commit_series.parquet", series)

	latest_md := store.format_markdown_table(cand, context.temp_allocator)
	_ = store.update_readme_markers("README.md", latest_md)

	// 7. Close the store handle BEFORE compacting the underlying file on disk
	store.store_close(&st)
	if before, after, ok := store.store_compact(db_path); ok {
		fmt.printfln("Compacted %s: %d -> %d bytes", db_path, before, after)
	}

	return rep.regressions == 0
}

main :: proc() {
	if !run_and_audit("benchmarks/history.hugidb", "a1b2c3d4e5f6") {
		os.exit(1)
	}
}
```

### Core `hugi_store` Procedures

| Category | Procedure | Notes & Ownership |
| :--- | :--- | :--- |
| **Lifecycle** | `store_open(path)` | Pass file path or `":memory:"`; pair with `store_close(&st)`. |
| **CoW Overlay** | `store_open_overlay(path)` | Wraps disk store in `xitdb.Core_Overlay`; writes stay in RAM (`store_overlay_owned_bytes(&st)`). |
| **Write Tuning** | `store_set_write_options(&st, opts)` | Configure `keep_hot_runs` (default `0`) and auto-seal window `cold_chunk_runs` (default `32`). |
| **Ingest** | `store_ingest_packet(&st, pkt)` | Commits `hugi.Run_Packet` into a new `xitdb` `Moment` and updates per-benchmark snapshots. |
| **History** | `store_list_commits(&st)` / `store_list_runs(&st)` | Free returned slices with `commit_summaries_destroy` / `run_summaries_destroy`. |
| **Queries** | `store_load_pooled_records(&st, lang, commit, run_id, filter)` | Pools per-op `samples_fs` (`i64` femtoseconds). Free with `pooled_records_destroy`. |
| **Time Series** | `store_load_commit_series_records` / `store_load_all_run_records` | Chronological pooled-per-commit or unpooled per-run records. Free with `pooled_records_destroy`. |
| **Auditing** | `compare_records(base, cand, threshold_pct)` | Mann-Whitney U + Welch's `t`-test + geomean delta. Free with `comparison_report_destroy(&rep)`. |
| **Cross-Lang** | `compare_1v1_langs(&st, lang_a, lang_b, commit, threshold_pct)` | 1v1 language audit with `footprint_mismatch` detection. Free with `cross_lang_report_destroy(&rep)`. |
| **Exporters** | `export_arrow_ipc`, `export_parquet`, `export_json`, `export_jsonl`, `export_csv`, `export_tsv`, `export_markdown` | Driven by the canonical 35-column `EXPORT_COLUMNS` schema (`Decimal64(18, 6)` durations). |
| **Sample Decode** | `decompress_exported_samples_fs(blob, ops_per_sample)` | Decodes exported `BU` `samples_blob` (both `flags=0` batch `u64` and `flags=1` signed `i64` fs) to `[]i64` femtoseconds. |
| **Compaction** | `store_compact(path)` / `store_compact_with_options(path, opts)` | Seals hot runs into `CZCH` cold chunks and atomically replaces `path`. Close `Store` first. |

---

## Multi-Format Exports (No Lock-In)

You do not need to write Odin code or parse `.hugidb` files to build dashboards, notebooks, or audit reports. `hugi export` auto-detects the output format from `--out` (or `--format`):

| Format | Extensions | Schema & Precision Details |
| :--- | :--- | :--- |
| **Apache Arrow IPC** | `.arrow`, `.feather`, `.ipc` | 35 columns; `Decimal64(18, 6)` nanosecond durations, `LZ4_Frame` IPC compression, plus lossless `BU`-compressed `samples_blob`. |
| **Apache Parquet** | `.parquet`, `.pq` | 35 columns; pure-Odin V1 DataPages with GZIP compression, `DECIMAL(18, 6)` logical duration columns, and `samples_blob`. |
| **JSON** | `.json` | Pretty-printed array with 34 scalar metrics plus exact 6-decimal `samples_ns` and raw `samples_batch_ns` arrays. |
| **JSON Lines** | `.jsonl`, `.ndjson` | Streaming newline-delimited JSON objects with full sample arrays and 6-decimal femtosecond precision. |
| **CSV / TSV** | `.csv`, `.tsv`, `.tab` | RFC 4180 compliant 34-column flat tables with exact fixed-point `0.000000` nanosecond formatting. |
| **Markdown** | `.md`, `.markdown` | GitHub-Flavored Markdown summary tables (median, p95, ops/s, CV%, footprint, allocations). |

### Standardized 35-Column Export Schema

All structured exports (`arrow`, `parquet`, `csv`, `tsv`, `json`, and `jsonl`) share the exact same `34` canonical scalar columns in fixed order from [`store/export_schema.odin`](store/export_schema.odin):

`commit`, `lang`, `suite_name`, `group_name`, `name`, `full_name`, `run_id`, `timestamp_unix`, `rank`, `run_count`, `ops_per_sample`, `samples`, `min_ns`, `p25_ns`, `p50_ns`, `p75_ns`, `p95_ns`, `p99_ns`, `max_ns`, `mean_ns`, `std_dev_ns`, `ci95_ns`, `cv_pct`, `iqr_ns`, `mad_ns`, `ops_per_sec`, `mb_per_sec`, `bytes_per_op`, `footprint_bytes`, `allocs_per_op`, `alloc_bytes_per_op`, `temp_allocs_per_op`, `temp_bytes_per_op`, `peak_heap_bytes`.

Column `35` in `arrow` and `parquet` is `samples_blob` (lossless `BU`-compressed per-sample ticks); `json` and `jsonl` instead append `samples_batch_ns` (when present) and `samples_ns` per record.

### Export Scopes

* **Latest Snapshot (default):** Exports the current state of every tracked benchmark for a language (or for a specific `--commit <sha>`), pooling samples across multiple runs of the same commit.
* **Commit Time Series (`--all-commits`):** Exports one pooled record per `(commit, benchmark)` in chronological order—ideal for plotting performance trends over Git history.
* **Every Individual Run (`--all-runs`):** Exports every historical run unpooled (`run_count == 1`) for auditing machine variance and run-to-run stability.

### Querying Directly with DuckDB or Polars

Because `hugi` exports native `DECIMAL(18, 6)` columns to Parquet and Arrow IPC, you can query sub-nanosecond histories immediately in SQL or Python without precision loss:

```bash
hugi export --all-commits --out history.parquet
duckdb -c "SELECT commit, full_name, p50_ns, p99_ns, ops_per_sec FROM read_parquet('history.parquet', file_row_number = true) ORDER BY file_row_number DESC LIMIT 10;"
```

*(Ordering by `file_row_number` preserves chronological commit order even for backfilled JSONL histories where multiple commits were imported in the same second.)*

### Automated README Benchmark Tables

Place markers anywhere in a repository's `README.md` or documentation:

```markdown
<!-- BEGIN_BENCHMARK_TABLE -->
<!-- END_BENCHMARK_TABLE -->
```

Then run:

```bash
./bin/hugi export --db benchmarks/history.hugidb --format md --update-readme README.md
```

`hugi` replaces only the block between the markers while leaving the rest of your document untouched.

### Customizing Benchmark Reports & Real-World Showcase

`hugi` separates measurement, compressed history, and statistical inference from presentation. When a project outgrows the built-in 9-column table—such as needing grouped sections, latency-tiered bandwidth tables, multi-runtime pivots, or source `#L` links—consume `hugi`'s machine-readable streams (`--out -`, `--lang all`, `compare --format json|csv`, `compare-1v1 --format json|csv`, Parquet/Arrow IPC) or embed `hugi_store` directly:

* **Runnable Recipes in This Repo:**
  * [`examples/custom_markdown_odin/`](examples/custom_markdown_odin/) — Pure-Odin renderer importing `hugi_store` to group benchmarks by `group_name`, switch `MB/s` vs `ops/s`, and update README markers.
  * [`examples/custom_reports/`](examples/custom_reports/) — [`duckdb_report.sql`](examples/custom_reports/duckdb_report.sql) (latency-tiered tables and commit deltas over Parquet) and [`render_1v1_report.py`](examples/custom_reports/render_1v1_report.py) (stdlib Python renderer consuming `hugi compare-1v1 --format json --out -` and `hugi export --lang all --format json --out -`).

* **Real-World Odin Ecosystem References:**

| Repository | Rendering Pattern | How `hugi` Is Used |
| :--- | :--- | :--- |
| **`mimir`** | Zero-config built-in Markdown | `hugi run benchmarks` + `hugi export --update-readme benchmarks/README.md` (17 micro & pipeline benchmarks). |
| [**`boxxxie/heimdall`**](https://github.com/boxxxie/heimdall) | Zero-config built-in Markdown | Strict `-disallow-do` suite (`zero_cost` micro-benchmarks + 6 pipeline groups, 31 benchmarks) updated directly via `hugi export --update-readme`. |
| [**`boxxxie/temple`**](https://github.com/boxxxie/temple) | **AOT `temple` templates (`tools/bench_report/`)** | Streams `hugi export --format json --out -` into Odin structs and renders grouped suite tables + root README headline table with `temple`'s zero-alloc AOT `.temple.twig` templates. |
| [**`boxxxie/odin-duckdb`**](https://github.com/boxxxie/odin-duckdb) | **Latency-tiered bandwidth + DuckDB SQL** | Emits `hugi` packets (`--extra-build-flags` for `libduckdb`), streams `hugi export --all-commits --format jsonl --out -` into tiered bandwidth tables, and includes `query_hugidb.sql` over Parquet. |
| [**`boxxxie/odin-xitdb`**](https://github.com/boxxxie/odin-xitdb) | **Polyglot 1v1 + code-slice links** | Unifies `odin`, `zig`, and `lua` histories in `history.hugidb` (`hugi compare-1v1 --langs odin,zig`) and streams `--lang all --all-commits --format jsonl --out -` into tiered diff + slice reports. |
| [**`boxxxie/skadi`**](https://github.com/boxxxie/skadi) | **Pivoted ST/MT/Actor vs C++ 1v1** | Records exact batch ticks + `Buffer_Pool` custom metrics (`pool_hits`/`pool_misses`), ingests `odin` + `cpp` runs, and drives `compare_1v1.py --from-hugidb` via `hugi export --lang all --format jsonl --out -`. |
| [**`boxxxie/sleipnir`**](https://github.com/boxxxie/sleipnir) | **Multi-runtime concurrency suite** | Captures all 5 actor/mailbox workloads (`1.4M`–`825M` msgs/s across `chan`, DOD, MPSC, SPSC, and `M:N` swarms) into `benchmarks/history.hugidb`. |

---

## Ingesting External & Cross-Language Benchmarks

`hugi` is language-agnostic at the storage, comparison, and export layers. Any benchmark harness in C, Zig, Rust, Go, or Python can emit a simple `.jsonl` line per benchmark and ingest it into `.hugidb`:

```json
{"group":"kv","lang":"zig","commit":"a1b2c3d4e5f6","run_id":"zig-run-1","name":"kv::lookup[1024]","ops":1000,"runs":7,"median_ns":41.25,"samples_ns":[41.1,41.25,41.4],"bytes_used":16384}
```

```bash
# Ingest external JSONL logs, obench JSON reports, or binary .hpk packets
hugi ingest zig_results.jsonl --db benchmarks/history.hugidb

# Inspect or export a non-Odin language explicitly (inspect/compare/export default to --lang odin)
hugi inspect --db benchmarks/history.hugidb --lang zig

# Run a 1v1 statistical & memory-footprint audit between Odin and Zig (matches on exact full_name)
hugi compare-1v1 --db benchmarks/history.hugidb --langs odin,zig --commit a1b2c3d4e5f6
```

---

## Architecture: How `.hugidb` Beats Parquet & Preserves Femtoseconds

### Exact Fixed-Point Femtosecond Arithmetic

Floating-point `f64` IEEE-754 significands have 53 bits of precision, which introduces representation error when scaling batched clock deltas or aggregating quantiles.

* Inside `hugi`, raw batch timings are recorded as overhead-adjusted `u64` nanoseconds alongside `ops_per_sample`.
* Per-operation durations are scaled using 128-bit integer arithmetic (`u128`) into signed 64-bit **femtoseconds** (`1 fs = 10^-15 s = 10^-6 ns`), supporting exact sub-picosecond SIMD measurements (e.g., `5,000 fs = 5.00 ps`) up to `> 9.22 million seconds (~106.75 days)` without overflow or floating-point rounding drift.
* Quantiles (`min`, `p25`, `p50`, `p75`, `p95`, `p99`, `max`), `mean`, `IQR`, and `MAD` are computed deterministically over `i64` femtoseconds using `i128` linear interpolation.

### Multi-Tiered Compression (`xitdb v5` + `HCAT\x01` + `CZPK\x04` + `CZCH\x02` + `BU`)

Parquet is a general-purpose row-group format that repeats column metadata per row group and treats sample arrays as generic nested lists or binary blobs. `.hugidb` (`v5`) is purpose-built for longitudinal benchmark histories on top of [`deps/xitdb`](https://github.com/boxxxie/odin-xitdb) Copy-on-Write transactions and [`deps/skadi`](https://github.com/boxxxie/skadi) analytics/export:

1. **Consolidated Root Catalog (`HCAT\x01`):** Interns all repeated strings (suite names, groups, benchmark names, OS/arch, compiler flags, commit SHAs, custom metric units) and static benchmark descriptors (`_Bench_Desc`) once across the entire database history, alongside run metadata and a rank-preserving snapshot index.
2. **Presence-Bitmasked Hot Packets (`CZPK\x04`):** Recent runs omit zero/default fields (such as zero allocations, zero errors, or sequential ranks) via compact varint bitmasks.
3. **Transposed Columnar Cold Rollups (`CZCH\x02`):** As runs accumulate (every 32 runs by default, or on `hugi compact`), `hugi` seals older runs into transposed columnar chunks (`O(hot_runs)` chunk-preserving compaction). Metadata fields are delta-zigzag encoded across runs, and **raw sample arrays are grouped contiguously by benchmark descriptor across commits**—maximizing cross-commit LZ77 window locality.
4. **5-Way Racing Sample Codec (`BU`):** Every sample stream races five lossless integer encodings under Zlib level 9 and stores whichever produces the smallest byte payload:
   * `Raw`: Uncompressed `u64le` fallback for tiny high-entropy slices (guarantees zero expansion).
   * `Zlib_Delta_Varint`: Wrapping first-order delta + zigzag varint + Zlib-9 (ideal for low-jitter timings).
   * `Zlib_BSS`: 8-way Byte-Stream-Split lane transposition + Zlib-9 (groups high-order constant bytes across 64-bit timings).
   * `Zlib_Delta_BSS`: Wrapping delta + zigzag + 8-way Byte-Stream-Split + Zlib-9 (ideal for steady strides with wide magnitude).
   * `Zlib_Block_GCD`: 16-sample block Greatest Common Divisor factoring + zigzag quotients + Zlib-9 (eliminates quantized timer tick multipliers).

---

## Storage Efficiency: `.hugidb` vs. Apache Parquet, Arrow IPC & JSONL

Even though a `.hugidb` file is a full transactional database—preserving chronological run lineage, per-language latest-snapshot indexes, and every raw `u64` batch sample—a compacted `.hugidb` store is consistently **smaller on disk than an equivalent GZIP-compressed Apache Parquet export** of the same runs.

### Why `.hugidb` Beats Parquet on Benchmark Histories

| Capability / Overhead | `.hugidb` (`xitdb` + `HCAT` + `CZCH` + `BU`) | Apache Parquet (`.parquet`, GZIP) | Apache Arrow IPC (`.arrow`, LZ4) | JSON Lines (`.jsonl`) |
| :--- | :--- | :--- | :--- | :--- |
| **Schema & Footer Overhead** | 1 global `HCAT` symbol + descriptor table across all history | Thrift `FileMetaData` + 35 `SchemaElement`s + 35 `ColumnChunk` headers | Flatbuffer `Schema` + `Footer` + 35 buffer descriptors per batch | Repeated field names on every line |
| **Zero / Default Columns** | **Omitted** via presence bitmasks (0 bytes for zero allocs/errors/cycles) | Materialized across all 35 column pages | Materialized across all 35 column buffers | Serialized as `0` / `0.0000` text on every row |
| **String Deduplication** | Global symbol IDs (`varint`) shared across commits, suites, and metrics | Per-column PLAIN + GZIP within a single row group | Contiguous UTF-8 offsets + LZ4 frame | Uncompressed repeated UTF-8 strings |
| **Sample Array Locality** | **Grouped by benchmark across commits** in one contiguous `u64` stream | Isolated per-row `BYTE_ARRAY` blobs separated by 4-byte length prefixes | Isolated per-row binary slices | ASCII decimal text arrays |
| **Integer Sample Codec** | **5-way race** (Raw, Delta-Varint, 8-way BSS, Delta-BSS, 16-sample Block-GCD) + Zlib-9 | Per-row `BU` blob + page-level GZIP | Per-row `BU` blob + LZ4 frame | Text formatting |
| **Incremental Compaction** | `O(hot_runs)` — reuses sealed `CZCH` cold chunks verbatim | Full file rewrite required | Full file rewrite required | Append-only (no deduplication) |
| **Decimal Precision** | Exact `i64` femtoseconds (`10^-15 s`) + exact `u64` batch ns | `DECIMAL(18, 6)` (`10^-15 s`) | `Decimal64(18, 6)` (`10^-15 s`) | Fixed 6-decimal ns (`0.000000`) |

### Measured Format Comparison (`odin-xitdb` History)

Exporting the exact same full-fidelity Odin run history from [`boxxxie/odin-xitdb`](https://github.com/boxxxie/odin-xitdb)'s `benchmarks/history.jsonl` (6 Odin runs across 6 commits, 320 benchmark records, 1,600 raw samples) via `--all-runs`:

| Format | File Size (6 runs, 320 records, 1,600 samples) | Relative to Parquet | Lossless Raw Samples? | Transactional Snapshots? |
| :--- | ---: | ---: | :---: | :---: |
| **`.hugidb` (compacted, `CZCH\x02`)** | **`4,789 B`** | **`0.16x` (6.3x smaller)** | Yes | Yes |
| **Apache Parquet (GZIP)** | `30,046 B` | `1.00x` | Yes | No |
| **Apache Arrow IPC (LZ4)** | `52,426 B` | `1.74x` | Yes | No |
| **CSV (34 scalar cols)** | `106,983 B` | `3.56x` | Scalar quantiles only | No |
| **JSONL (`--all-runs`, with sample arrays)** | `283,855 B` | `9.45x` | Yes | No |

Across the full multi-language [`boxxxie/odin-xitdb`](https://github.com/boxxxie/odin-xitdb) history (`history.jsonl`, `lua.jsonl`, and `zig.jsonl` — 13 ingested packets, 773 benchmark records across 7 commits and 3 languages), `324,077 B` of raw JSONLs compact to `41,871 B` pre-compact (`v5`: `HCAT\x01` + `CZPK\x04`) and **`7,510 B`** after `hugi compact --keep-hot 0` (**97.7% smaller**), while a single latest-Odin snapshot exports to `12,604 B` in Parquet or `22,514 B` in Arrow IPC.

*(Note: `.hugidb` also retains `.hugidb`-only metadata omitted from the 35-column Parquet/Arrow exports, including custom `Metric` values, `median_cycles`, `resizes_per_op`, OS/arch/compiler flags, and `@zero_alloc` / error flags.)*

### Reproducing Size Benchmarks on Your Own Suite

You can audit exact byte sizes on your own benchmark history at any time by exporting all unpooled runs (`--all-runs`, which preserves 100% of runs and sample arrays) and comparing against the compacted `.hugidb` file (pass `--lang all` on multi-language stores, or `--lang <lang>` for non-Odin stores, since `hugi export` defaults to `--lang odin`):

```bash
# 1. Seal cold runs and reclaim dead xitdb pages
hugi compact --db benchmarks/history.hugidb --keep-hot 0

# 2. Export the exact same full-fidelity run history to Parquet, Arrow IPC, CSV, and JSONL
hugi export --db benchmarks/history.hugidb --lang all --all-runs --out .tmp/all_runs.parquet
hugi export --db benchmarks/history.hugidb --lang all --all-runs --out .tmp/all_runs.arrow
hugi export --db benchmarks/history.hugidb --lang all --all-runs --out .tmp/all_runs.csv
hugi export --db benchmarks/history.hugidb --lang all --all-runs --out .tmp/all_runs.jsonl

# 3. Compare resulting file sizes
wc -c benchmarks/history.hugidb .tmp/all_runs.parquet .tmp/all_runs.arrow .tmp/all_runs.csv .tmp/all_runs.jsonl
```

### Migrating Existing Repos

1. Point your benchmark package at `hugi` and replace ad-hoc timers or log writers with `hugi.suite_create`, `hugi.group_add`, and `hugi.group_pipeline`.
2. Backfill any existing JSONL or `obench` JSON logs once: `./bin/hugi ingest results.jsonl --db benchmarks/history.hugidb && ./bin/hugi compact --db benchmarks/history.hugidb`.
3. Run cross-language comparisons directly via `./bin/hugi compare-1v1 --db benchmarks/history.hugidb --langs odin,zig` without custom comparison scripts.

---

## CLI Reference

| Command | Description |
| :--- | :--- |
| `hugi run [pkg_dir]` | Build and run an Odin benchmark package and ingest results into the store (`--no-db`, `--overlay`, `--runs`, `--warmup`, `--groups`, `-f`, `--baseline-commit`, `--fail-on-regression`). |
| `hugi ingest <file...>` | Ingest `.hpk`/`.bpk` binary packets, `obench` `.json` reports, or `.jsonl` benchmark logs (`--lang`, `--commit`). |
| `hugi history` | List stored commits (`--commits`, default) or individual runs (`--runs`, `--limit <N>`). |
| `hugi inspect [filter]` | Display Markdown summary and quantile/allocation breakdown (`--commit`, `--run`, `--lang`). |
| `hugi compare` | Statistical comparison across `--commits <a..b>`, `--runs <a..b>`, or `--last` (`--threshold <pct>`, `--fail-on-regression`, `--format md|json|csv`, `--out <path|->`). |
| `hugi compare-1v1` | Cross-language 1v1 comparison with Mann-Whitney U / Welch `t`-test and footprint checks (`--langs <a,b>`, `--commit`, `--format md|json|csv`, `--out <path|->`). |
| `hugi export` | Export snapshot, `--all-commits`, or `--all-runs` (`--lang odin|<lang>|all`) to `arrow`, `parquet`, `json`, `jsonl`, `csv`, `tsv`, or `md` (including `--out -` stdout streaming) or `--update-readme <path>`. |
| `hugi compact` | Seal cold runs into `CZCH\x02` columnar chunks and atomically compact dead `xitdb` pages (`--keep-hot <N>`). |

---

## Repository Layout

* [`hugi/`](hugi/) (`package hugi`) — Zero-store benchmark runner, `obench` micro-benchmark re-exports (`hugi.odin`), stateful `Pipeline` phases (`phase.odin`), Git SHA resolver (`git.odin`), `HPKT\x02` binary wire format (`packet.odin`), and JSON/JSONL importers (`importers.odin`).
* [`store/`](store/) (`package hugi_store`) — `.hugidb` transactional store (`db.odin`, `query.odin`, `compact.odin`), `HCAT\x01` catalog (`catalog.odin`), `CZPK\x04`/`CZCH\x02` encoders (`format.odin`, `binary_io.odin`), `BU` racing integer codecs (`codec.odin`), multi-run sample pooling & statistical tests (`pool_and_compare.odin`), and Arrow/Parquet/JSON/CSV/Markdown exporters (`export_schema.odin`, `export_arrow.odin`, `parquet.odin`, `export_text.odin`).
* [`cmd/hugi/`](cmd/hugi/) (`bin/hugi`) — Modular pure-Odin CLI (`main.odin`, `cli_args.odin`, `cmd_run.odin`, `cmd_ingest.odin`, `cmd_query.odin`, `cmd_export.odin`, `cli_test.odin`).
* [`examples/`](examples/) — Runnable suites and custom renderers: [`micro_and_phases/`](examples/micro_and_phases/) (`make example`), [`custom_markdown_odin/`](examples/custom_markdown_odin/) (pure-Odin grouped Markdown), and [`custom_reports/`](examples/custom_reports/) (DuckDB SQL + Python JSON renderers).
* [`tests/`](tests/) (`package hugi_tests`) & [`specs/`](specs/) (`package hugi_specs`) — Leak-checked unit tests, property-based codec/stats invariants, and 4-layer ATDD executable specifications.
* [`docs/`](docs/) — Technical guides covering [writing benchmarks & pipelines](docs/benchmarking-guide.md), [CLI & CI workflows](docs/cli-and-ci.md), [storage & compression architecture](docs/storage-and-compression.md), and [exports & analytics](docs/exports-and-analytics.md).

---

## Development & Verification

Run all formatting, static checks, unit/CLI tests, 4-layer ATDD specs, and release build:

```bash
make fmt && make fmt-check && make check && make test && make specs && make build
```

`deps/obench` tracks [`boxxxie/obench`](https://github.com/boxxxie/obench) (`feat/integer-batch-samples`, [PR #21](https://github.com/zeybek/obench/pull/21) on `zeybek/obench` layered on upstream `v0.3.0` after PRs `#14`–`#17` merged).

---

## AI Coding Agents & Usage Rules

* **Using `hugi` in your project:** Point your AI coding assistant (Claude Code, Cursor, Windsurf, Codex, etc.) at [`usage-rules.md`](./usage-rules.md) for concise `DO` / `DON'T` patterns covering `Suite` CLI flags, multi-pass `Pipeline` lifecycles, `i64` femtosecond helpers, and `.hugidb` compaction rules.
* **Contributing to `hugi`:** See [`AGENTS.md`](./AGENTS.md) for package dependency boundaries, compiler vet flags, memory-tracking test commands, and the 4-layer ATDD specification suite.

---

## License

Distributed under the **MIT License**. See [`LICENSE`](./LICENSE) for full details.
