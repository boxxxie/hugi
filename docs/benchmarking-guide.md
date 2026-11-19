# Writing Benchmarks & Pipelines

`hugi` provides two complementary execution models inside a single `hugi.Suite`:

1. **Micro-Benchmarks (`^hugi.Bencher`):** Re-exported `obench` primitives for tight, stateless, parameterized, or multi-threaded hot loops.
2. **Stateful Pipelines (`^hugi.Pipeline`):** Multi-phase lifecycle benchmarks (`insert -> lookup -> scan -> compact`) where sequential phases share built data structures without allocator-counting overhead during timed passes.

---

## 1. Compiler Collections & `ols.json` Auto-Discovery

Benchmark binaries only depend on the `hugi` and `obench` collections—they **never** need `hugi_store`, `xitdb`, or `skadi`.

When you run `hugi run <pkg_dir>`, `hugi` walks upward from `<pkg_dir>` to the nearest `.git` boundary looking for `ols.json`:
* All non-reserved collections (`core`, `base`, and `vendor` are ignored) are resolved to absolute paths and passed as `-collection:<name>=<path>`.
* Any `-custom-attribute:*` and `-ignore-unknown-attributes` tokens in `checker_args` are forwarded to `odin build`.
* `-o:speed` is enabled automatically unless an explicit `-o:*` flag is present in `ols.json` or `--extra-build-flags`.
* If `hugi` and `obench` are not listed in `ols.json`, `hugi run` falls back to `HUGI_HOME` (or its own repository root) to inject `-collection:hugi` and `-collection:obench`.

Example `ols.json` in a downstream project:

```json
{
	"collections": [
		{ "name": "hugi", "path": "./deps/hugi/hugi" },
		{ "name": "obench", "path": "./deps/hugi/deps/obench/obench" }
	]
}
```

> **Collection Import Syntax:** Because Odin resolves imports without `:` as relative subdirectories, always import the collection as `import hugi "hugi:."` when `ols.json` (or `hugi run`'s `HUGI_HOME` fallback) maps `-collection:hugi` to `<hugi_repo>/hugi`. Tools that also import `hugi_store` must map `hugi`, `hugi_store` (`./deps/hugi/store`), and the transitive vendored collections (`obench`, `xitdb`, `skadi`) in `ols.json` or `-collection:*` flags and import `store "hugi_store:."` (avoid mapping `-collection:hugi` to the repo root if you rely on `HUGI_HOME`, since `hugi run` injects `-collection:hugi=<repo_root>/hugi`).

---

## 2. Suite Entrypoint & Configuration

When invoked via `hugi run`, your compiled benchmark binary receives CLI flags such as `--packet-out /tmp/odin_hugi_pkt_....hpk`, `--runs`, `--warmup`, `--groups`, `--filter`, `--lang`, `--commit`, and `--quiet`.

Calling `hugi.suite_create("name")` (with `config = nil`) invokes `hugi.default_suite_config()`, which parses those CLI flags automatically when `!ODIN_TEST`:

```odin
package my_bench

import "core:os"
import hugi "hugi:."

main :: proc() {
	suite := hugi.suite_create("storage_engine")
	defer hugi.suite_destroy(&suite)

	// Register micro-benchmarks and pipelines...

	if !hugi.suite_run(&suite) {
		os.exit(1)
	}
}
```

### Customizing `Suite_Config` Safely

If you need custom `obench` settings (such as fixed batch sizes or custom sample counts), **always start from `hugi.default_suite_config()`** so CLI flags like `--packet-out` are preserved.

Note that `default_suite_config()` parses `os.args` *before* returning `cfg`. Mutate non-CLI `obench_cfg` fields freely afterward, and avoid unconditionally overwriting `cfg.runs` or `cfg.warmup` unless you want a hard-coded override that ignores `--runs` / `--warmup` from the CLI:

```odin
cfg := hugi.default_suite_config()
cfg.obench_cfg.sample_count = 25
// Leave cfg.runs / cfg.warmup untouched to honor CLI `--runs` / `--warmup` (defaults: 7 and 1).
// Assigning `cfg.runs = 10` here would hard-override any `--runs` CLI flag.

suite := hugi.suite_create("storage_engine", cfg)
defer hugi.suite_destroy(&suite)
```

### Binary CLI Flags Parsed by `default_suite_config()`

When running a compiled benchmark binary directly, `default_suite_config()` recognizes all flags below (`hugi run` forwards `--runs`, `--warmup`, `--groups`, `--filter`, `--lang`, `--commit`, and `--quiet`, while managing `--packet-out` internally—passing `--run-id` or `--packet-out` to `hugi run` is rejected as an unknown flag):

| Flag | Effect |
| :--- | :--- |
| `--runs <N>` | Number of timed passes for `Pipeline` groups (default: `7`; micro-benchmarks ignore this and use `cfg.obench_cfg.sample_count`). |
| `--warmup <N>` | Warmup passes for `Pipeline` groups (default: `1`); when explicitly passed on the CLI, also sets micro-benchmark `cfg.obench_cfg.warmup_time` to `<N> ms` (otherwise `obench.default_config()`'s default applies). |
| `--groups <g1,g2>` | Run only matching group names (comma or `\|` separated; `"all"` runs everything). |
| `--filter <pat>`, `-f <pat>` | Case-insensitive substring filter on `full_name` (supports `,` or `\|` alternation). |
| `--lang <tag>` | Language tag recorded in the output packet (default: `"odin"`; lowercased by the binary). |
| `--commit <sha>` | Override auto-detected 12-char Git HEAD SHA. |
| `--run-id <id>` | *(Binary only)* Override auto-generated `run-<unix_seconds>` identifier. |
| `--packet-out <path>` | *(Binary only)* Write binary `HPKT\x02` `Run_Packet` to `<path>`. |
| `--quiet` | Suppress stdout terminal report (`suite_run` still executes and writes `--packet-out`). |

---

## 3. Writing Micro-Benchmarks (`^hugi.Bencher`)

### Standalone & Grouped Micro-Benchmarks

Use `hugi.bench` for quick standalone benchmarks in the default group, or `hugi.group_add` + `hugi.group_bench` to organize benchmarks across input sizes (`group_params`) and thread counts (`group_threads`):

```odin
bench_checksum :: proc(b: ^hugi.Bencher) {
	size := max(hugi.param(b), 64)
	buf := make([]u8, size)
	defer delete(buf)

	// Report throughput denominator and enforce 0 heap allocations inside the timed loop
	hugi.set_bytes(b, u64(size))
	hugi.expect_zero_allocs(b)

	for hugi.step(b) {
		_ = hugi.black_box(crc32_slice(buf))
	}
}

register_hash_group :: proc(suite: ^hugi.Suite) {
	g := hugi.group_add(suite, "checksum")
	hugi.group_params(g, []int{64, 1024, 65536})
	hugi.group_threads(g, []int{1, 4})
	hugi.group_bench(g, "crc32", bench_checksum, zero_alloc = true)
}
```

Parameterized and threaded benchmarks automatically format canonical `full_name` identifiers such as `checksum::crc32[1024]/t4`.

### Compiler Optimization Barriers & Timing Controls

`hugi` re-exports `obench`'s full control surface:

* `hugi.black_box(val)` — Prevents dead-code elimination on computed values.
* `hugi.keep_alive(&val)` — Forces memory writes to `val` to materialize before reading the clock.
* `hugi.clobber_memory()` — Global compiler read/write memory barrier.
* `hugi.pause(b)` / `hugi.resume(b)` / `hugi.scoped_pause(b)` — Exclude per-iteration bookkeeping from timing.
* `hugi.iter_batched` / `hugi.iter_with_large_drop` — Benchmark mutating or destructive operations with isolated per-input setup/drop.
* `hugi.run_parallel` / `hugi.parallel_next` — Coordinate work across worker threads configured via `hugi.group_threads`.
* `hugi.set_bytes(b, bytes)` / `hugi.set_items(b, items)` — Compute `mb_per_sec` and `items_per_sec` from median (`p50`) duration in live terminal reports and `hugi.Record.items_per_sec` (note that `hugi_store` and `EXPORT_COLUMNS` always export unscaled `ops_per_sec = 1e15 / p50_fs` from samples).
* `hugi.report_metric(b, value, unit)` — Attach custom domain metrics (up to `MAX_METRICS :: 8`).

---

## 4. Writing Stateful Multi-Phase Pipelines (`^hugi.Pipeline`)

Micro-benchmark loops struggle when benchmarking stateful systems such as B-trees, HAMTs, ECS worlds, or compilers, where Phase B (`lookup`) depends on state built during Phase A (`insert`), and wrapping `context.allocator` during Phase A would distort allocation-heavy timings.

`hugi.group_pipeline` solves both problems with a **3-pass execution architecture**:

1. **`Warmup` Passes (`warmup` iterations, default `1`):** Runs your `Pipeline_Proc` end-to-end with unwrapped allocators and no clock reads to warm instruction/data caches.
2. **`Timed` Passes (`runs` iterations, default `7`):** Runs your `Pipeline_Proc` with **unwrapped allocators** (`0 ns` counting-allocator distortion). Each phase bracketed by `phase_begin`..`phase_end` (or `scoped_phase`) records `clobber_memory()`-fenced clock timestamps and subtracts calibrated clock overhead.
3. **`Alloc_Check` Pass (`1` untimed pass):** Wraps `context.allocator` and `context.temp_allocator` in `obench.Counting_Allocator`s that remain **paused** outside phases and **active** inside phases. Records exact `allocs_per_op`, `resizes_per_op`, `alloc_bytes_per_op`, `peak_heap_bytes`, `temp_allocs_per_op`, `temp_bytes_per_op`, and exact source file/line/procedure locations on `@zero_alloc` violations (`zero_alloc = true` enforces zero allocations on `context.allocator` only; `context.temp_allocator` scratch usage is allowed and reported separately).

Between every pass, `hugi` resets a private `context.temp_allocator` scratch arena automatically.

### Pipeline Authoring Pattern

Because your `Pipeline_Proc` executes `warmup + runs + 1` times, **initialize and `defer` destroy shared state inside the procedure**:

```odin
bench_index_lifecycle :: proc(p: ^hugi.Pipeline) {
	n := p.has_param && p.param > 0 ? p.param : 10_000

	// Setup outside phases: untimed and excluded from phase allocation counts
	idx := index_create(capacity = n)
	defer index_destroy(&idx)

	// Phase 1: Bulk Insert
	{
		ph := hugi.scoped_phase(p, "bulk_insert", ops = n, bytes_per_op = 24)
		for i in 0 ..< n {
			index_insert(&idx, u64(i * 2654435761), u64(i))
		}
		hugi.phase_set_footprint(ph, index_memory_bytes(&idx))
	}

	// Phase 2: Point Lookups (strictly zero heap allocations)
	{
		ph := hugi.scoped_phase(p, "point_lookup", ops = n, bytes_per_op = 8, zero_alloc = true)
		hits := 0
		for i in 0 ..< n {
			if v, ok := index_get(&idx, u64(i * 2654435761)); ok {
				_ = hugi.black_box(v)
				hits += 1
			}
		}
		hugi.phase_metric(ph, f64(hits) / f64(n) * 100.0, "hit%")
	}
}
```

Registering a pipeline on a `Suite` (pass `runs = 0, warmup = -1` to inherit CLI `--runs` and `--warmup` from `suite.config`, or positive values as hard per-pipeline overrides):

```odin
hugi.group_pipeline(
	&suite,
	group_name = "index",
	procedure  = bench_index_lifecycle,
	param      = 10_000,
	has_param  = true,
	runs       = 0,  // 0 = inherit suite.config.runs (positive values override CLI --runs)
	warmup     = -1, // -1 = inherit suite.config.warmup (non-negative values override CLI --warmup)
)
```

### Nested Phases

Phases can nest up to `hugi.MAX_PHASE_DEPTH :: 8` levels deep using explicit `phase_begin` / `phase_end` or nested lexical scopes with `scoped_phase`:

```odin
{
	outer := hugi.scoped_phase(p, "compile_unit", ops = 1)
	{
		lex := hugi.scoped_phase(p, "tokenize", ops = token_count)
		tokens = tokenize(src)
	}
	{
		parse := hugi.scoped_phase(p, "parse_ast", ops = node_count, zero_alloc = true)
		ast = parse_tokens(tokens)
	}
}
```

Each phase slot is emitted as its own `Record` (e.g., `compiler::compile_unit`, `compiler::tokenize`, `compiler::parse_ast`) while preserving deterministic rank order across filtered runs.

> **Nested Allocation Tracking Note:** Wall-clock `start_ts` timestamps live on `_phase_stack` and nest cleanly up to `MAX_PHASE_DEPTH`, whereas the untimed `.Alloc_Check` pass shares a single `_heap_counter` / `_temp_counter`: an inner `phase_begin` calls `counting_allocator_reset` (wiping earlier outer-phase counts) and an inner `phase_end` pauses the counter for the remainder of the outer phase (leaving the outer phase with only residual allocations after its last child phase). Use nested phases strictly for wall-clock timing, and place `zero_alloc = true` and allocation auditing on non-overlapping leaf phases. (Note that `zero_alloc = true` checks `context.allocator` only; `context.temp_allocator` usage is permitted and reported separately.)

---

## 5. Integrating with `odin test`

Use `hugi.run_test(t, &suite)` to run benchmark suites as part of `odin test` (for example, verifying `@zero_alloc` invariants in unit tests without writing to a `.hugidb` file):

```odin
package my_pkg_tests

import "core:testing"
import hugi "hugi:."

@(test)
test_hot_path_zero_alloc :: proc(t: ^testing.T) {
	cfg := hugi.default_suite_config()
	// Micro-benchmarks read `obench_cfg` (`cfg.runs` / `cfg.warmup` apply only to Pipeline groups)
	cfg.obench_cfg.sample_count = 10
	cfg.obench_cfg.warmup_time = 0

	suite := hugi.suite_create("zero_alloc_sanity", cfg)
	defer hugi.suite_destroy(&suite)

	hugi.bench(&suite, "decode_frame", bench_decode_frame, zero_alloc = true)
	hugi.run_test(t, &suite)
}
```

`hugi.run_test` disables ANSI color codes, logs the formatted summary table via `core:log`, and fails `t` if any `@zero_alloc` violation, benchmark error, regression, or packet I/O error occurs.