# Upstream `obench` PR Stack (`deps/obench`)

Fork: [`boxxxie/obench`](https://github.com/boxxxie/obench) (forked from [`zeybek/obench`](https://github.com/zeybek/obench)).

`deps/obench` tracks branch `odin-bench` (`cb0657a`) in `/home/pauli/projects/odin/obench`, which merges four independent PR branches layered cleanly over upstream `main` (`44000fb`):

- [#14](https://github.com/zeybek/obench/pull/14) — `perf/linux-vdso-clock-and-noalias` (`c7a1295`)
- [#15](https://github.com/zeybek/obench/pull/15) — `feat/untimed-alloc-tracking` (`29be614`)
- [#16](https://github.com/zeybek/obench/pull/16) — `feat/cli-compiler-flags-and-ols` (`0b33369`)
- [#17](https://github.com/zeybek/obench/pull/17) — `feat/programmatic-hooks-and-phases` (`71a1e5f`)

---

## PR #14 — `perf/linux-vdso-clock-and-noalias` (`c7a1295`)

**Title:** `perf: use libc vDSO clock_gettime on 64-bit Linux and #no_alias in step`

- **Motivation:** `time.tick_now()` on Linux previously paid direct syscall overhead (~700 ns per timer pair in local measurements) compared to vDSO `clock_gettime(CLOCK_MONOTONIC)`, inflating sub-microsecond fixed batches, and `step` could miss scalar alias optimizations on loop bounds.
- **Changes:**
  - `obench/clock.odin`: Uses foreign libc `clock_gettime(CLOCK_MONOTONIC, ...)` via vDSO on 64-bit Linux (`ODIN_OS == .Linux`), cutting measured timer pair overhead to ~42 ns under `-o:speed`.
  - `obench/bencher.odin`: Marks `#no_alias b: ^Bencher` in `step`.
  - `cmd/obench/main_test.odin`, `tests/obench_test.odin`: Added monotonic clock / `step` coverage.
- **Verification:** `make fmt && make fmt-check && make check && make check-barriers && make test && make smoke && make clean`

---

## PR #15 — `feat/untimed-alloc-tracking` (`29be614`)

**Title:** `feat: add untimed allocation counting option (--untimed-allocs)`

- **Motivation:** Wrapping the timed sample loop in `Counting_Allocator` adds atomic counter and lock/bookkeeping latency to nanosecond-scale loops. Separating timing from allocation inspection preserves clean latency distributions while keeping allocation counts and `@zero_alloc` enforcement accurate.
- **Changes:**
  - `obench/config.odin`, `obench/doc.odin`: Added `Config.untimed_alloc_check`, `DEFAULT_UNTIMED_ALLOCS`, `--untimed-allocs` CLI flag, and `OBENCH_UNTIMED_ALLOCS` environment variable.
  - `obench/stats.odin`: Recorded `alloc_iters` alongside `Stats`.
  - `obench/runner.odin`: Executes an untimed allocation/violation check pass when `untimed_alloc_check` is enabled while keeping timed batches on raw allocators.
  - `cmd/obench/main.odin`, `cmd/obench/main_test.odin`, `tests/obench_test.odin`: CLI flag propagation and tests verifying timing isolation and `@zero_alloc` detection.
- **Verification:** `make fmt && make fmt-check && make check && make test && make smoke && make clean`

---

## PR #16 — `feat/cli-compiler-flags-and-ols` (`0b33369`)

**Title:** `feat(cli): forward --extra-linker-flags, --custom-attribute, and ols.json collections`

- **Motivation:** Real projects using `obench` frequently rely on collections declared in `ols.json`, custom attributes (such as `zero_alloc` or domain attributes), or C library link flags. Without upward `ols.json` discovery and compiler flag forwarding, `obench run` fails on multi-package repos.
- **Changes:**
  - `cmd/obench/main.odin`: Added `discover_ols_collections` (walks upward from the target package and resolves relative collection paths), `--extra-linker-flags`, and `--custom-attribute` forwarding to `odin build`.
  - `cmd/obench/main_test.odin`: Added unit tests covering `ols.json` resolution and flag forwarding.
- **Verification:** `make fmt && make fmt-check && make check && make test && make smoke && make clean`

---

## PR #17 — `feat/programmatic-hooks-and-phases` (`71a1e5f`)

**Title:** `feat: add silent suite_execute API and preserve custom_metrics in baselines`

- **Motivation:** Wrapper libraries (like `odin/bench`) need to drive `obench` suites programmatically, combine micro results with stateful multi-phase pipelines in one summary report, and preserve `custom_metrics` across JSON baseline round-trips without memory leaks.
- **Changes:**
  - `obench/runner.odin`: Extracted public silent `suite_execute(s: ^Suite) -> bool` separately from printing.
  - `obench/report_json.odin`: Preserves `custom_metrics` cleanly on JSON export and baseline load without leaking strings/arrays.
  - `tests/obench_test.odin`: Added coverage for `suite_execute` and `custom_metrics` round-tripping.
- **Verification:** `make fmt && make fmt-check && make check && make test-lib && make clean`

---

## Integration Branch — `odin-bench` (`cb0657a`)

Merges all four PR branches above (`perf/linux-vdso-clock-and-noalias`, `feat/untimed-alloc-tracking`, `feat/cli-compiler-flags-and-ols`, `feat/programmatic-hooks-and-phases`) into a single ref consumed by `deps/obench`, verified end-to-end with `make fmt && make fmt-check && make check && make check-barriers && make test && make smoke && make clean` (46 library tests + 20 CLI tests + `core_style` + barrier probes + smoke).
