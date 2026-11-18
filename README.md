# `hugi` (`odin/hugi`)

Pure-Odin benchmarking library, compressed transactional history store, statistical comparator, and CLI built to replace bespoke per-repo benchmark harnesses, bloated `history.jsonl` logs, and Python `compare_1v1.py` analysis scripts.

## Architecture

`hugi` splits execution from storage and reporting so benchmarked libraries (`xitdb`, `skadi`, `heimdall`, `hfsm`, etc.) never hit circular package dependencies:

- [`hugi/`](hugi/) (`package hugi`) — Zero-store runner importing only `base:*`, `core:*`, and [`deps/obench/obench`](deps/obench/obench). Exposes:
  - `obench` micro-benchmarking primitives (`step`, `set_bytes`, `set_items`, `expect_zero_allocs`, `param`, `threads`, `run_parallel`) with untimed allocation checking (`untimed_alloc_check = true`) and vDSO `clock_gettime` on 64-bit Linux (~42 ns timer overhead under `-o:speed`).
  - Stateful multi-phase pipelines (`group_pipeline`, `scoped_phase`, `phase_begin`/`phase_end`, `phase_set_footprint`, `phase_metric`) where phases share mutable setup while setup/teardown stay excluded from timing and allocation wrappers.
  - Binary `HPKT` `Run_Packet` serialization (`encode_packet_bytes`, `read_packet_file`, also decoding legacy `OBPK` packets) plus importers for `obench` JSON reports and legacy `history.jsonl` files.
- [`store/`](store/) (`package hugi_store`) — Transactional [`deps/xitdb`](deps/xitdb) `.hugidb` persistence and [`deps/skadi`](deps/skadi) analytics/export:
  - Stores every run inside a copy-on-write `xitdb` `Moment` under `runs`, `run_order`, `commits`, and rank-preserving `snapshots` (`<lang>:<run_id>` keys prevent cross-language collisions at shared commits).
  - Compresses `[]f64` timing vectors via 8-way Byte-Stream-Split + zlib (`Codec.Zlib_BSS`) or LZ4 (`Codec.LZ4_BSS`), with automatic fallback to `.Raw`.
  - Pools multi-run sample vectors per `(commit, lang, benchmark)` and compares runs/commits or languages (`compare_records`, `compare_1v1_langs`) using Mann-Whitney U and Welch `t` (with Student `t` critical values and domain byte footprint mismatch flags).
  - Exports pooled records to 33-column Apache Arrow IPC / Feather v2 (`export_arrow_ipc`), `jsonl`, `csv`, and Markdown, plus updates `README.md` benchmark tables between `<!-- BEGIN_BENCHMARK_TABLE -->` and `<!-- END_BENCHMARK_TABLE -->` markers.
- [`cmd/hugi/`](cmd/hugi/) (`bin/hugi`) — Standalone pure-Odin CLI (`run`, `ingest`, `history`, `inspect`, `compare`, `compare-1v1`, `export`, `compact`).

## Quickstart

Add `hugi` (or symlink/submodule it) and import only `hugi`:

```odin
package main

import hugi "../../hugi"

fnv1a :: proc(data: []u8) -> u64 {
	h := u64(14695981039346656037)
	for b in data {
		h ~= u64(b)
		h *= 1099511628211
	}
	return h
}

bench_hash :: proc(b: ^hugi.Bencher) {
	buf := make([]u8, max(hugi.param(b), 16))
	defer delete(buf)
	hugi.set_bytes(b, u64(len(buf)))
	hugi.expect_zero_allocs(b)
	for hugi.step(b) {
		_ = hugi.black_box(fnv1a(buf))
	}
}

bench_kv_pipeline :: proc(p: ^hugi.Pipeline) {
	n := 256
	table := make(map[u64]u64, n)
	defer delete(table)

	{
		ph := hugi.scoped_phase(p, "insert", ops = n, bytes_per_op = 16)
		for i in 0 ..< n {
			table[u64(i)] = u64(i * 3)
		}
		hugi.phase_set_footprint(ph, u64(len(table) * 16))
	}
	{
		ph := hugi.scoped_phase(p, "lookup", ops = n, zero_alloc = true)
		hits := 0
		for i in 0 ..< n {
			if v, ok := table[u64(i)]; ok {
				_ = hugi.black_box(v)
				hits += 1
			}
		}
		hugi.phase_metric(ph, f64(hits) / f64(n) * 100.0, "hit%")
	}
}

main :: proc() {
	suite := hugi.suite_create("demo")
	defer hugi.suite_destroy(&suite)

	g := hugi.group_add(&suite, "hash")
	hugi.group_params(g, []int{64, 256})
	hugi.group_bench(g, "fnv1a", bench_hash, zero_alloc = true)

	hugi.group_pipeline(&suite, "kv_lifecycle", bench_kv_pipeline)

	if !hugi.suite_run(&suite) {
		panic("benchmark suite failed")
	}
}
```

Run and record it cleanly:

```bash
make build
./bin/hugi run examples/micro_and_phases --runs 5
```

## CLI Commands

| Command | Purpose | Key Flags |
| --- | --- | --- |
| `hugi run [pkg_dir]` | Build with `-o:speed` + discovered `ols.json` collections, run, and ingest packet | `--db`, `--no-db`, `--runs`, `--warmup`, `--groups`, `--filter`, `--lang`, `--baseline-commit`, `--fail-on-regression` |
| `hugi ingest <file...>` | Import `HPKT`/`OBPK` `.hpk`/`.bpk`, `obench` `.json`, or legacy `.jsonl` files | `--db`, `--lang`, `--commit` |
| `hugi history` | List stored commits or individual runs | `--db`, `--commits`, `--runs`, `--limit` |
| `hugi inspect [filter]` | Show pooled quantiles (`p25`..`p99`), CI95, CV%, allocations, and footprint | `--db`, `--commit`, `--lang`, `--run` |
| `hugi compare` | Mann-Whitney U + Welch `t` regression comparison | `--db`, `--commits a..b`, `--runs a..b`, `--last`, `--threshold`, `--fail-on-regression` |
| `hugi compare-1v1` | Cross-language 1v1 comparison with byte-footprint parity check | `--db`, `--langs odin,zig`, `--commit`, `--threshold` |
| `hugi export` | Export snapshot to Feather v2 `.arrow`, `.jsonl`, `.csv`, or Markdown | `--db`, `--format arrow\|jsonl\|csv\|md`, `--out`, `--update-readme` |
| `hugi compact` | Compact `xitdb` transactional log and reclaim superseded tree pages | `--db` |

### Updating `README.md` Benchmark Tables

Place markers anywhere in a repository's `README.md`:

```markdown
<!-- BEGIN_BENCHMARK_TABLE -->
<!-- END_BENCHMARK_TABLE -->
```

Then run:

```bash
./bin/hugi export --db benchmarks/history.hugidb --format md --update-readme README.md
```

## Measured Storage & Migration (`xitdb` History Smoke Run)

Ingesting real benchmark histories from `/home/pauli/projects/odin/xitdb/benchmarks/` (`history.jsonl` with Odin + Zig runs across 6 commits, `zig.jsonl`, and `lua.jsonl` — 13 ingested packets, 773 benchmark records across 7 commits and 3 languages):

| Artifact | Size | Notes |
| --- | ---: | --- |
| Raw `history.jsonl` + `lua.jsonl` | `297,457 B` | Plain-text JSONL (`324,077 B` when also counting standalone `zig.jsonl`) |
| Pre-compact `.hugidb` | `376,089 B` | 13 CoW `xitdb` moments with full `runs`, `commits`, and `snapshots` indices |
| Compacted `.hugidb` (`hugi compact`) | `173,073 B` | **54.0% reduction** via `xitdb.database_compact` (`41.8%` smaller than raw `history.jsonl + lua.jsonl`) |
| Latest Odin Arrow IPC (`export --format arrow`) | `35,130 B` | 75 benchmarks x 33 columns in Feather v2 with zlib+BSS compressed `samples_blob` |

### Migrating Existing Repos

1. Point the repo's benchmark package at `hugi` and replace custom JSONL writers / timers with `hugi.suite_create`, `hugi.group_add`, and `hugi.group_pipeline`.
2. Backfill historical runs once: `./bin/hugi ingest benchmarks/history.jsonl --db benchmarks/history.hugidb && ./bin/hugi compact --db benchmarks/history.hugidb`.
3. Replace Python `compare_1v1.py` invocations with `./bin/hugi compare-1v1 --db benchmarks/history.hugidb --langs odin,zig`.

## Development & Upstream `obench` PRs

Run verification checks:

```bash
make fmt && make fmt-check && make check && make test && make build
```

Details on the four upstream feature/performance PR branches carried by [`deps/obench`](deps/obench) (`odin-bench` branch) are documented in [`docs/OBENCH_PRS.md`](docs/OBENCH_PRS.md).
