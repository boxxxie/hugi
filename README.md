# `hugi`

[![CI](https://github.com/boxxxie/hugi/actions/workflows/ci.yml/badge.svg)](https://github.com/boxxxie/hugi/actions/workflows/ci.yml)
[![Version](https://img.shields.io/badge/version-0.1.0-blue.svg)](cmd/hugi/main.odin)
[![Odin](https://img.shields.io/badge/Odin-lang-3882D2.svg)](https://odin-lang.org/)
[![Store Format](https://img.shields.io/badge/store-xitdb%20v5-5C6BC0.svg)](store/format.odin)
[![Export](https://img.shields.io/badge/export-Arrow%20IPC%20%7C%20Parquet-orange.svg)](store/export_schema.odin)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Pure-Odin benchmarking library, compressed transactional history store, statistical comparator, and CLI built to replace bespoke per-repo benchmark harnesses, bloated `history.jsonl` logs, and Python `compare_1v1.py` analysis scripts.

## Architecture

`hugi` splits execution from storage and reporting so benchmarked libraries (`xitdb`, `skadi`, `heimdall`, `hfsm`, etc.) never hit circular package dependencies:

- [`hugi/`](hugi/) (`package hugi`) — Zero-store runner importing only `base:*`, `core:*`, and [`deps/obench/obench`](deps/obench/obench). Exposes:
  - `obench` micro-benchmarking primitives (`step`, `set_bytes`, `set_items`, `expect_zero_allocs`, `param`, `threads`, `run_parallel`) with untimed allocation checking (`untimed_alloc_check = true`) and vDSO `clock_gettime` on 64-bit Linux (~42 ns timer overhead under `-o:speed`) in [`hugi/hugi.odin`](hugi/hugi.odin).
  - Stateful multi-phase pipelines (`group_pipeline`, `scoped_phase`, `phase_begin`/`phase_end`, `phase_set_footprint`, `phase_metric`) in [`hugi/phase.odin`](hugi/phase.odin) where phases share mutable setup while setup/teardown stay excluded from timing and allocation wrappers.
  - Binary `HPKT\x02` (`OBRC\x02`) `Run_Packet` serialization (`encode_packet_bytes`, `read_packet_file`) and shared `Stats_FS` / throughput math in [`hugi/packet.odin`](hugi/packet.odin), plus `obench` JSON and `history.jsonl` importers (`read_obench_json_packets`, `read_jsonl_packets`) in [`hugi/importers.odin`](hugi/importers.odin).
- [`store/`](store/) (`package hugi_store`) — Transactional [`deps/xitdb`](deps/xitdb) `.hugidb` persistence and [`deps/skadi`](deps/skadi) analytics/export:
  - Modular `v5` `xitdb` storage & compaction across [`store/binary_io.odin`](store/binary_io.odin), [`store/catalog.odin`](store/catalog.odin), [`store/format.odin`](store/format.odin), [`store/db.odin`](store/db.odin), [`store/query.odin`](store/query.odin), and [`store/compact.odin`](store/compact.odin): consolidated Zlib catalog (`catalog` with `HCAT\x01` global symbol/descriptor tables, run metadata, and rank-preserving snapshot index), hot `runs` (`CZPK\x04`), transposed `cold_chunks` (`CZCH\x02` auto-sealed every 32 runs with `O(hot_runs)` chunk-preserving compaction), plus `Core_Overlay` in-memory CoW branching (`--overlay`).
  - Losslessly compresses exact `u64` rational batch ticks via unified `BU` `U64_Codec` competition (`Raw`, `Zlib_Delta_Varint`, `Zlib_BSS`, `Zlib_Delta_BSS`, and `Zlib_Block_GCD`) in [`store/codec.odin`](store/codec.odin).
  - Pools multi-run sample vectors per `(commit, lang, benchmark)` and compares runs/commits or languages (`compare_records`, `compare_1v1_langs`) using shared Mann-Whitney U and Welch `t` significance logic (with Student `t` critical values and domain byte footprint mismatch flags) in [`store/pool_and_compare.odin`](store/pool_and_compare.odin).
  - Exports pooled records, commit series (`--all-commits`), or per-run histories (`--all-runs`) via a unified `35`-column schema in [`store/export_schema.odin`](store/export_schema.odin) across Apache Arrow IPC / Feather v2 ([`store/export_arrow.odin`](store/export_arrow.odin), `Decimal64(18, 6)` + `LZ4_FRAME`), pure-Odin GZIP Apache Parquet ([`store/parquet.odin`](store/parquet.odin)), and `json`, `jsonl`, `csv`, `tsv`, and Markdown (`md`) + `README.md` marker updates ([`store/export_text.odin`](store/export_text.odin)).
- [`cmd/hugi/`](cmd/hugi/) (`bin/hugi`) — Modular pure-Odin CLI (`main.odin`, `cli_args.odin`, `cmd_run.odin`, `cmd_ingest.odin`, `cmd_query.odin`, `cmd_export.odin`, plus unit tests in `cli_test.odin`).
- [`tests/`](tests/) (`package hugi_tests`) — Leak-checked subsystem test suites (`codec_test.odin`, `packet_test.odin`, `git_test.odin`, `store_test.odin`, `compare_test.odin`, `export_test.odin`, and `test_helpers.odin`).
- [`specs/`](specs/) (`package hugi_specs`) — 4-layer ATDD executable specifications (`runner_pipeline_spec_test.odin`, `history_store_spec_test.odin`, `comparison_spec_test.odin`, `export_spec_test.odin`, `cli_e2e_spec_test.odin`) and property tests (`invariants_prop_test.odin`) built on `dsl_test.odin` and `driver_test.odin`.

## Clone & Prerequisites

```bash
git clone https://github.com/boxxxie/hugi.git
cd hugi
git submodule update --init
```

Use non-recursive `git submodule update --init` (this skips `deps/xitdb`'s optional Zig reference submodules).

- The zero-store `hugi/` runner requires only the Odin compiler and `deps/obench`.
- Building `store/` and `bin/hugi` additionally requires system development headers for `zlib` (`zlib1g-dev` on Debian/Ubuntu) and `liblz4` (`liblz4-dev`).

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
| `hugi run [pkg_dir]` | Build with `-o:speed` + discovered `ols.json` collections, run, and ingest packet | `--db`, `--no-db`, `--runs`, `--warmup`, `--groups`, `--filter`, `--lang`, `--baseline-commit`, `--fail-on-regression`, `--overlay` |
| `hugi ingest <file...>` | Import `HPKT\x02` `.hpk`/`.bpk`, `obench` `.json`, or `.jsonl` files | `--db`, `--lang`, `--commit` |
| `hugi history` | List stored commits or individual runs | `--db`, `--commits`, `--runs`, `--limit` |
| `hugi inspect [filter]` | Show pooled quantiles (`p25`..`p99`), CI95, CV%, allocations, and footprint | `--db`, `--commit`, `--lang`, `--run` |
| `hugi compare` | Mann-Whitney U + Welch `t` regression comparison | `--db`, `--commits a..b`, `--runs a..b`, `--last`, `--threshold`, `--fail-on-regression` |
| `hugi compare-1v1` | Cross-language 1v1 comparison with byte-footprint parity check | `--db`, `--langs odin,zig`, `--commit`, `--threshold` |
| `hugi export` | Export snapshot or longitudinal series to Feather v2 `.arrow`, `.parquet`, `.json`, `.jsonl`, `.csv`, `.tsv`, or `.md` | `--db`, `--format arrow\|parquet\|json\|jsonl\|csv\|tsv\|md`, `--all-commits`, `--all-runs`, `--out`, `--update-readme` |
| `hugi compact` | Compact `xitdb` store (seals cold chunks + reclaims dead pages) | `--db`, `--keep-hot` |

### Standardized Export Schema

All structured exports (`arrow`, `parquet`, `csv`, `tsv`, `json`, and `jsonl`) share the exact same `34` canonical scalar columns in fixed order from [`store/export_schema.odin`](store/export_schema.odin):

`commit`, `lang`, `suite_name`, `group_name`, `name`, `full_name`, `run_id`, `timestamp_unix`, `rank`, `run_count`, `ops_per_sample`, `samples`, `min_ns`, `p25_ns`, `p50_ns`, `p75_ns`, `p95_ns`, `p99_ns`, `max_ns`, `mean_ns`, `std_dev_ns`, `ci95_ns`, `cv_pct`, `iqr_ns`, `mad_ns`, `ops_per_sec`, `mb_per_sec`, `bytes_per_op`, `footprint_bytes`, `allocs_per_op`, `alloc_bytes_per_op`, `temp_allocs_per_op`, `temp_bytes_per_op`, `peak_heap_bytes`.

Column `35` in `arrow` and `parquet` is `samples_blob` (lossless `BU`-compressed per-sample ticks); `json` and `jsonl` instead append `samples_batch_ns` (when present) and `samples_ns` per record.

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

Ingesting real benchmark histories from [`boxxxie/odin-xitdb`](https://github.com/boxxxie/odin-xitdb)'s `benchmarks/` directory (`history.jsonl` with Odin + Zig runs across 6 commits, `zig.jsonl`, and `lua.jsonl` — 13 ingested packets, 773 benchmark records across 7 commits and 3 languages):

| Artifact | Size | Notes |
| --- | ---: | --- |
| Raw `history.jsonl` + `lua.jsonl` (`+ zig.jsonl`) | `297,457 B` (`324,077 B`) | Plain-text JSONL |
| Pre-compact `.hugidb` (`v5`: `HCAT\x01` + `CZPK\x04`) | `41,871 B` | 13 CoW `xitdb` moments |
| Compacted `.hugidb` (`hugi compact` -> `CZCH\x02`) | `7,513 B` | **97.7% smaller** than all JSONLs (13 runs sealed into cold rollup chunk) |
| Latest Odin Arrow IPC (`export --format arrow`) | `22,514 B` | 75 benchmarks x 35 columns (`Decimal64(18, 6)` durations) in Feather v2 with `LZ4_FRAME` + `BU` `samples_blob` |
| Latest Odin Parquet (`export --format parquet`) | `12,604 B` | 75 benchmarks x 35 columns (`Decimal64(18, 6)` durations) in pure-Odin GZIP Parquet |

### Migrating Existing Repos

1. Point the repo's benchmark package at `hugi` and replace custom JSONL writers / timers with `hugi.suite_create`, `hugi.group_add`, and `hugi.group_pipeline`.
2. Backfill historical runs once: `./bin/hugi ingest benchmarks/history.jsonl --db benchmarks/history.hugidb && ./bin/hugi compact --db benchmarks/history.hugidb`.
3. Replace Python `compare_1v1.py` invocations with `./bin/hugi compare-1v1 --db benchmarks/history.hugidb --langs odin,zig`.

## Development & Upstream `obench` PRs

Run verification checks (including `make specs` for the ATDD & property suite):

```bash
make fmt && make fmt-check && make check && make test && make specs && make build
```

Details on the upstream feature/performance PR branches carried by [`deps/obench`](deps/obench) are documented in [`docs/OBENCH_PRS.md`](docs/OBENCH_PRS.md).

## License

Released under the [MIT License](LICENSE).
