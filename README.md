# `odin/bench`

Pure-Odin benchmarking library, compressed transactional history store, statistical comparator, and CLI built to replace bespoke per-repo benchmark harnesses, bloated `history.jsonl` logs, and Python `compare_1v1.py` analysis scripts.

## Architecture

`odin/bench` splits execution from storage and reporting so benchmarked libraries (`xitdb`, `skadi`, `heimdall`, etc.) never hit circular package dependencies:

- [`bench/`](bench/) (`package bench`) — Zero-store runner importing only `base:*`, `core:*`, and [`deps/obench/obench`](deps/obench/obench). Exposes:
  - `obench` micro-benchmarking primitives (`step`, `set_bytes`, `set_items`, `expect_zero_allocs`, `param`, `threads`, `run_parallel`) with untimed allocation checking (`untimed_alloc_check = true`) and vDSO `clock_gettime` on 64-bit Linux (~42 ns timer overhead under `-o:speed`).
  - Stateful multi-phase pipelines (`group_pipeline`, `scoped_phase`, `phase_begin`/`phase_end`, `phase_set_footprint`, `phase_metric`) where phases share mutable setup while setup/teardown stay excluded from timing and allocation wrappers.
  - Binary `OBPK` `Run_Packet` serialization (`encode_packet_bytes`, `read_packet_file`) plus importers for `obench` JSON reports and legacy `history.jsonl` files.
- [`store/`](store/) (`package bench_store`) — Transactional [`deps/xitdb`](deps/xitdb) `.benchdb` persistence and [`deps/skadi`](deps/skadi) analytics/export:
  - Stores every run inside a copy-on-write `xitdb` `Moment` under `runs`, `run_order`, `commits`, and rank-preserving `snapshots` (`<lang>:<run_id>` keys prevent cross-language collisions at shared commits).
  - Compresses `[]f64` timing vectors via 8-way Byte-Stream-Split + zlib (`Codec.Zlib_BSS`) or LZ4 (`Codec.LZ4_BSS`), with automatic fallback to `.Raw`.
  - Pools multi-run sample vectors per `(commit, lang, benchmark)` and compares runs/commits or languages (`compare_records`, `compare_1v1_langs`) using Mann-Whitney U and Welch `t` (with Student `t` critical values and domain byte footprint mismatch flags).
  - Exports pooled records to 33-column Apache Arrow IPC / Feather v2 (`export_arrow_ipc`), `jsonl`, `csv`, and Markdown, plus updates `README.md` benchmark tables between `<!-- BEGIN_BENCHMARK_TABLE -->` and `<!-- END_BENCHMARK_TABLE -->` markers.
- [`cmd/bench/`](cmd/bench/) (`bin/bench`) — Standalone pure-Odin CLI (`run`, `ingest`, `history`, `inspect`, `compare`, `compare-1v1`, `export`, `compact`).

## Quickstart

Add `bench` (or symlink/submodule it) and import only `bench`:

```odin
package main

import bench "../../bench"

fnv1a :: proc(data: []u8) -> u64 {
	h := u64(14695981039346656037)
	for b in data {
		h ~= u64(b)
		h *= 1099511628211
	}
	return h
}

bench_hash :: proc(b: ^bench.Bencher) {
	buf := make([]u8, max(bench.param(b), 16))
	defer delete(buf)
	bench.set_bytes(b, u64(len(buf)))
	bench.expect_zero_allocs(b)
	for bench.step(b) {
		_ = bench.black_box(fnv1a(buf))
	}
}

bench_kv_pipeline :: proc(p: ^bench.Pipeline) {
	n := 256
	table := make(map[u64]u64, n)
	defer delete(table)

	{
		ph := bench.scoped_phase(p, "insert", ops = n, bytes_per_op = 16)
		for i in 0 ..< n {
			table[u64(i)] = u64(i * 3)
		}
		bench.phase_set_footprint(ph, u64(len(table) * 16))
	}
	{
		ph := bench.scoped_phase(p, "lookup", ops = n, zero_alloc = true)
		hits := 0
		for i in 0 ..< n {
			if v, ok := table[u64(i)]; ok {
				_ = bench.black_box(v)
				hits += 1
			}
		}
		bench.phase_metric(ph, f64(hits) / f64(n) * 100.0, "hit%")
	}
}

main :: proc() {
	suite := bench.suite_create("demo")
	defer bench.suite_destroy(&suite)

	g := bench.group_add(&suite, "hash")
	bench.group_params(g, []int{64, 256})
	bench.group_bench(g, "fnv1a", bench_hash, zero_alloc = true)

	bench.group_pipeline(&suite, "kv_lifecycle", bench_kv_pipeline)

	if !bench.suite_run(&suite) {
		panic("benchmark suite failed")
	}
}
```

Run and record it cleanly:

```bash
make build
./bin/bench run examples/micro_and_phases --runs 5
```

## CLI Commands

| Command | Purpose | Key Flags |
| --- | --- | --- |
| `bench run [pkg_dir]` | Build with `-o:speed` + discovered `ols.json` collections, run, and ingest packet | `--db`, `--no-db`, `--runs`, `--warmup`, `--groups`, `--filter`, `--lang`, `--baseline-commit`, `--fail-on-regression` |
| `bench ingest <file...>` | Import `OBPK` `.bpk`, `obench` `.json`, or legacy `.jsonl` files | `--db`, `--lang`, `--commit` |
| `bench history` | List stored commits or individual runs | `--db`, `--commits`, `--runs`, `--limit` |
| `bench inspect [filter]` | Show pooled quantiles (`p25`..`p99`), CI95, CV%, allocations, and footprint | `--db`, `--commit`, `--lang`, `--run` |
| `bench compare` | Mann-Whitney U + Welch `t` regression comparison | `--db`, `--commits a..b`, `--runs a..b`, `--last`, `--threshold`, `--fail-on-regression` |
| `bench compare-1v1` | Cross-language 1v1 comparison with byte-footprint parity check | `--db`, `--langs odin,zig`, `--commit`, `--threshold` |
| `bench export` | Export snapshot to Feather v2 `.arrow`, `.jsonl`, `.csv`, or Markdown | `--db`, `--format arrow\|jsonl\|csv\|md`, `--out`, `--update-readme` |
| `bench compact` | Compact `xitdb` transactional log and reclaim superseded tree pages | `--db` |

### Updating `README.md` Benchmark Tables

Place markers anywhere in a repository's `README.md`:

```markdown
<!-- BEGIN_BENCHMARK_TABLE -->
<!-- END_BENCHMARK_TABLE -->
```

Then run:

```bash
./bin/bench export --db benchmarks/history.benchdb --format md --update-readme README.md
```

## Measured Storage & Migration (`xitdb` History Smoke Run)

Ingesting real benchmark histories from `/home/pauli/projects/odin/xitdb/benchmarks/` (`history.jsonl` with Odin + Zig runs across 6 commits, `zig.jsonl`, and `lua.jsonl` — 13 ingested packets, 773 benchmark records across 7 commits and 3 languages):

| Artifact | Size | Notes |
| --- | ---: | --- |
| Raw `history.jsonl` + `lua.jsonl` | `297,457 B` | Plain-text JSONL (`324,077 B` when also counting standalone `zig.jsonl`) |
| Pre-compact `.benchdb` | `376,089 B` | 13 CoW `xitdb` moments with full `runs`, `commits`, and `snapshots` indices |
| Compacted `.benchdb` (`bench compact`) | `173,073 B` | **54.0% reduction** via `xitdb.database_compact` (`41.8%` smaller than raw `history.jsonl + lua.jsonl`) |
| Latest Odin Arrow IPC (`export --format arrow`) | `35,130 B` | 75 benchmarks x 33 columns in Feather v2 with zlib+BSS compressed `samples_blob` |

### Migrating Existing Repos

1. Point the repo's benchmark package at `bench` and replace custom JSONL writers / timers with `bench.suite_create`, `bench.group_add`, and `bench.group_pipeline`.
2. Backfill historical runs once: `./bin/bench ingest benchmarks/history.jsonl --db benchmarks/history.benchdb && ./bin/bench compact --db benchmarks/history.benchdb`.
3. Replace Python `compare_1v1.py` invocations with `./bin/bench compare-1v1 --db benchmarks/history.benchdb --langs odin,zig`.

## Development & Upstream `obench` PRs

Run verification checks:

```bash
make fmt && make fmt-check && make check && make test && make build
```

Details on the four upstream feature/performance PR branches carried by [`deps/obench`](deps/obench) (`odin-bench` branch) are documented in [`docs/OBENCH_PRS.md`](docs/OBENCH_PRS.md).
