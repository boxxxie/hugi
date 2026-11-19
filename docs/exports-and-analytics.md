# Exports, Statistics & Polyglot Ingestion

`hugi` separates storage from presentation: you can ingest benchmarks from any programming language, audit regressions with non-parametric and parametric statistical tests, and export results into standard columnar or text formats without writing custom parsers.

---

## 1. Canonical 35-Column Export Schema (`EXPORT_COLUMNS`)

All exporters in `store/` are driven from a single source-of-truth schema (`store/export_schema.odin`):

* **Apache Arrow IPC (`.arrow`, `.feather`, `.ipc`):** All **35 columns**. Duration columns use native `Decimal64(18, 6)` nanoseconds (`10^-6 ns = 1 fs`), and IPC record batches default to `LZ4_Frame` body compression.
* **Apache Parquet (`.parquet`, `.pq`):** All **35 columns**. Self-contained V1 DataPages with GZIP compression (optional uncompressed mode via API) and `DECIMAL(precision=18, scale=6)` logical annotations over `INT64` physical columns.
* **CSV / TSV (`.csv`, `.tsv`):** First **34 scalar columns** (RFC 4180 compliant quoting; durations formatted with exact 6-decimal fixed-point strings such as `42.125000`).
* **JSON / JSONL (`.json`, `.jsonl`):** First **34 scalar columns**, plus `"samples_batch_ns"` (`[]u64`, included whenever `ops_per_sample` is uniform across pooled runs) and `"samples_ns"` (exact 6-decimal fixed-point nanosecond numbers).

> **`.hugidb`-Only Metadata & `ops_per_sec`:** Custom `Metric` entries (`report_metric`, `phase_metric`, JSONL `pool_hits`/`pool_misses`), `median_cycles`, `resizes_per_op`, environment fields (`os`, `arch`, `optimization`, `odin_version`), `zero_alloc_failed`, and `error` strings are stored inside `.hugidb` and printed during live `suite_run`, but are not part of the 35-column `EXPORT_COLUMNS` schema. Also note that `ops_per_sec` in `Pooled_Record` and exports is always computed as `1e15 / p50_fs` from samples (even when `hugi.set_items` was used for live `hugi.Record.items_per_sec`).

### Complete Column Specification

| # | Column Name | Arrow Type | Parquet Physical / Logical | CSV / JSON Format | Description |
| :-: | :--- | :--- | :--- | :--- | :--- |
| 0 | `commit` | `Utf8` | `BYTE_ARRAY` (`UTF8`) | `string` | 12-char Git commit SHA (or override). |
| 1 | `lang` | `Utf8` | `BYTE_ARRAY` (`UTF8`) | `string` | Language tag (e.g., `"odin"`, `"zig"`). |
| 2 | `suite_name` | `Utf8` | `BYTE_ARRAY` (`UTF8`) | `string` | Suite identifier. |
| 3 | `group_name` | `Utf8` | `BYTE_ARRAY` (`UTF8`) | `string` | Benchmark or pipeline group name. |
| 4 | `name` | `Utf8` | `BYTE_ARRAY` (`UTF8`) | `string` | Short benchmark or phase name. |
| 5 | `full_name` | `Utf8` | `BYTE_ARRAY` (`UTF8`) | `string` | Canonical name (`group::name[param]/tN`). |
| 6 | `run_id` | `Utf8` | `BYTE_ARRAY` (`UTF8`) | `string` | Most recent contributing `run_id`. |
| 7 | `timestamp_unix` | `Int64` | `INT64` | `int` | Max contributing Unix timestamp (seconds). |
| 8 | `rank` | `Int64` | `INT64` | `int` | Suite execution order rank (`1`-based). |
| 9 | `run_count` | `Int64` | `INT64` | `int` | Number of runs pooled into this row. |
| 10 | `ops_per_sample` | `UInt64` | `INT64` (`UINT_64`) | `uint` | Operations per batch sample. |
| 11 | `samples` | `Int64` | `INT64` | `int` | Total pooled sample count. |
| 12 | `min_ns` | `Decimal64(18,6)` | `INT64` (`DECIMAL(18,6)`) | `0.000000` | Minimum per-op duration in ns. |
| 13 | `p25_ns` | `Decimal64(18,6)` | `INT64` (`DECIMAL(18,6)`) | `0.000000` | 25th percentile duration in ns. |
| 14 | `p50_ns` | `Decimal64(18,6)` | `INT64` (`DECIMAL(18,6)`) | `0.000000` | Median (50th percentile) duration in ns. |
| 15 | `p75_ns` | `Decimal64(18,6)` | `INT64` (`DECIMAL(18,6)`) | `0.000000` | 75th percentile duration in ns. |
| 16 | `p95_ns` | `Decimal64(18,6)` | `INT64` (`DECIMAL(18,6)`) | `0.000000` | 95th percentile duration in ns. |
| 17 | `p99_ns` | `Decimal64(18,6)` | `INT64` (`DECIMAL(18,6)`) | `0.000000` | 99th percentile duration in ns. |
| 18 | `max_ns` | `Decimal64(18,6)` | `INT64` (`DECIMAL(18,6)`) | `0.000000` | Maximum per-op duration in ns. |
| 19 | `mean_ns` | `Decimal64(18,6)` | `INT64` (`DECIMAL(18,6)`) | `0.000000` | Arithmetic mean duration in ns. |
| 20 | `std_dev_ns` | `Decimal64(18,6)` | `INT64` (`DECIMAL(18,6)`) | `0.000000` | Sample standard deviation (`n - 1`) in ns. |
| 21 | `ci95_ns` | `Decimal64(18,6)` | `INT64` (`DECIMAL(18,6)`) | `0.000000` | Half-width 95% Student's `t` confidence interval (`±ns`). |
| 22 | `cv_pct` | `Float64` | `DOUBLE` | `%.4f` | Coefficient of variation (`std_dev / mean * 100`). |
| 23 | `iqr_ns` | `Decimal64(18,6)` | `INT64` (`DECIMAL(18,6)`) | `0.000000` | Interquartile range (`p75_ns - p25_ns`). |
| 24 | `mad_ns` | `Decimal64(18,6)` | `INT64` (`DECIMAL(18,6)`) | `0.000000` | Median absolute deviation from `p50_ns`. |
| 25 | `ops_per_sec` | `Float64` | `DOUBLE` | `%.3f` | Throughput operations/sec from `p50`. |
| 26 | `mb_per_sec` | `Float64` | `DOUBLE` | `%.4f` | Throughput MiB/s (`bytes_per_op * ops_per_sec / 2^20`). |
| 27 | `bytes_per_op` | `UInt64` | `INT64` (`UINT_64`) | `uint` | Processed payload bytes per operation. |
| 28 | `footprint_bytes`| `UInt64` | `INT64` (`UINT_64`) | `uint` | Max domain memory/disk footprint in bytes. |
| 29 | `allocs_per_op` | `Float64` | `DOUBLE` | `%.4f` | Mean heap allocations + resizes per op. |
| 30 | `alloc_bytes_per_op`| `Float64` | `DOUBLE` | `%.2f` | Mean heap bytes allocated per op. |
| 31 | `temp_allocs_per_op`| `Float64` | `DOUBLE` | `%.4f` | Mean `temp_allocator` allocs + resizes per op. |
| 32 | `temp_bytes_per_op` | `Float64` | `DOUBLE` | `%.2f` | Mean `temp_allocator` bytes per op. |
| 33 | `peak_heap_bytes`| `Int64` | `INT64` | `int` | Max live heap bytes observed during phase/bench. |
| 34 | `samples_blob` | `Binary` | `BYTE_ARRAY` | *(Arrow/Parquet)* | Lossless `BU`-compressed sample array. |

---

## 2. Export Scopes

| Scope | CLI Flag | API Procedure | Row Granularity |
| :--- | :--- | :--- | :--- |
| **Snapshot** | *(default)* or `--commit <c>` | `store_load_pooled_records` | 1 row per benchmark. Pools all runs of each benchmark's latest commit (or matching `<c>` prefix). |
| **Commit Series** | `--all-commits` | `store_load_commit_series_records` | 1 row per `(commit, lang, benchmark)` in chronological commit order, pooling repeated runs within each commit. |
| **Run Series** | `--all-runs` | `store_load_all_run_records` | 1 row per `(run_id, lang, benchmark)` in chronological run order (`run_count == 1`, unpooled). |

> **CLI `--lang` & Snapshot Retention Notes:**
> * `hugi export` (like `hugi inspect` and `hugi compare`) defaults to `--lang odin`. Pass `--lang <lang>` for non-Odin histories, or `--lang all` to export across all languages. (In the `store` API, `lang = ""` coerces to `"odin"` in Snapshot mode, while `"all"` or `"*"` selects all languages across all scopes.)
> * `_catalog_update_snaps` only upserts benchmarks present in newly ingested packets and never deletes absent keys—even when `selective == false`. If a benchmark is renamed or removed, default Snapshot exports retain the old entry from its last historical commit unless `--commit <sha>` is specified.

---

## 3. Multi-Run Pooling & Statistical Methodology

### Sample Pooling Rules

When multiple runs exist for the same `(commit, lang, full_name)`:
* Every run's `samples_batch_ns` is converted to per-op `i64` femtoseconds (`samples_fs`) using that run's `ops_per_sample`, and all quantiles/dispersion metrics are recomputed from scratch over the combined `samples_fs` distribution.
* If all pooled runs share the same `ops_per_sample`, `samples_batch_ns` is also preserved; if `ops_per_sample` changed between runs, `samples_batch_ns` is cleared so callers never misinterpret mixed batch sizes, and `samples_blob` automatically switches to `BU` `flags = 1` (signed `i64` femtoseconds).
* `footprint_bytes` and `peak_heap_bytes` take the maximum across pooled runs; per-op allocation counts/bytes take the arithmetic mean across runs.

### Hypothesis Testing (`compare` & `compare-1v1`)

Benchmark timing distributions are frequently right-skewed or multi-modal due to OS interrupts and cache misses. `hugi` combines non-parametric rank testing with Welch's `t`-test:

1. **Effect Size:**
   `delta_pct = (p50_cand - p50_base) / p50_base * 100`
2. **Statistical Significance (`_compare_significance`):**
   * **Both sides have `n >= 5` samples:** Uses the two-sided **Mann-Whitney U** rank-sum test (`p < 0.05`) with tie correction.
   * **Small-sample regime (`2 <= n < 5`):** Because Mann-Whitney U's discrete permutation space cannot achieve `p < 0.05` for very small `n` (e.g., `n1 = n2 = 3` has minimum two-sided `p = 0.10`), `hugi` accepts significance when **either** Mann-Whitney U yields `p < 0.05` **or** **Welch's `t`-test** exceeds the two-sided 95% Student's `t` critical value (`|t| >= t_{0.975, nu}`) with Welch-Satterthwaite degrees of freedom `nu`.
   * **Single-sample fallback (`n < 2`):** Uses Welch's `t`-test when variance is available.
3. **Verdict Gate:**
   * `compare`: Significant **and** `|delta_pct| >= threshold_pct` (default `5.0%`) -> `FASTER` (`delta_pct < 0`) or `REGRESSION` (`delta_pct > 0`); otherwise `unchanged`. Summary header reports geometric mean delta across all matched benchmarks:
     `geomean_delta = (exp((1 / k) * sum_{i=1..k} ln(p50_cand[i] / p50_base[i])) - 1) * 100`
     (Both `compare` and `compare-1v1` support `--format json|csv` and `--out <path|->` so custom client renderers can consume exact fixed-point durations and hypothesis-test outputs directly.)
   * `compare-1v1`: Pairs benchmarks by exact `full_name` equality. Relative difference `< 0.5%` is declared a `"tie"`; otherwise `faster_lang` (and `a_wins` / `b_wins` counts in `hugi compare-1v1` CLI output) reflects whichever language has the lower `p50_fs`. In the programmatic `hugi_store` API (`compare_1v1_langs`), `Cross_Lang_Row.is_significant` additionally checks `stat_diff && |a - b| / min(a, b) * 100 >= threshold_pct` (default `3.0%`). If both languages report non-zero `footprint_bytes` that differ, `footprint_mismatch` is flagged (`[MISMATCH]`).

---

## 4. Polyglot JSONL Ingestion Schema

Non-Odin benchmark suites (C, C++, Zig, Rust, Go, Python, Lua) can ingest directly into `.hugidb` via `hugi ingest <file.jsonl>`. Each line is a standalone JSON object; blank lines and non-JSON log lines are skipped safely.

*(Note: `_Jsonl_Row` has no per-row timestamp field—`read_jsonl_packets` assigns the wall-clock import `now_ts` in seconds to all packets created during that `hugi ingest` call. Commit ordering in `.hugidb` and `--all-commits` exports still preserves the chronological order in which commits were ingested.)*

### Minimal JSONL Example

```json
{"group":"kv","lang":"zig","commit":"a1b2c3d4e5f6","run_id":"zig-1","name":"kv::get","ops":1000,"samples_batch_ns":[41200,41150,41300,41220,41180],"bytes_used":16384}
```

### Supported JSONL Fields (`hugi/importers.odin`)

| Field | Type | Notes |
| :--- | :--- | :--- |
| `name` | `string` | **Required.** Copied directly to both `name` and `full_name` (`row.group` is stored in `group_name` without prefixing `full_name`). |
| `group` | `string` | Group name (e.g., `"kv"`). |
| `lang` | `string` | Language identifier (default `"odin"` unless overridden by `--lang`). |
| `commit` | `string` | Commit SHA (default `"unknown"` unless overridden by `--commit`). |
| `run_id` | `string` | Run identifier. Packets are grouped by `(commit, lang, run_id)`. Omitting `run_id` defaults to `jsonl-<commit>-<lang>`, overwriting earlier files with the same `(commit, lang)` on ingest. |
| `rank` | `int` | Explicit suite display rank (defaults to `1`-based order in packet). |
| `ops` | `u64` | Operations per batch sample (defaults to `1`, or auto-scales `1_000` / `1_000_000` if `ops == 0` and sub-nanosecond fractional `samples_ns` are supplied). |
| `samples_batch_ns`| `[]u64` | **Preferred.** Exact integer batch durations in nanoseconds. Quantiles are computed automatically in `i64` femtoseconds. |
| `samples_ns` | `[]f64` | Per-operation nanosecond samples (used when `samples_batch_ns` is omitted). |
| `runs` / `warmup` | `int` | Sample count fallback and warmup count. |
| `median_ns` / `ns_per_op` | `f64` | When both sample arrays are empty and `median_ns` (or `ns_per_op`) is `> 0`, `read_jsonl_packets` synthesizes a 1-element `samples_batch_ns` array and runs `recompute_record_stats_from_samples`—setting `samples = 1`, overwriting `min`/`p25`/`p75`/`p95`/`p99`/`max`/`mean` with `median_ns`, and zeroing `std_dev_fs`, `ci95_fs`, `cv_pct`, `iqr_fs`, and `mad_fs`. |
| `min_ns`, `max_ns`, `mean_ns`, `stddev_ns`, `iqr_ns`, `p95_ns`, `p99_ns`, `cv_pct` | `f64` | Summary stats (overwritten whenever `samples_batch_ns`, `samples_ns`, or `median_ns`/`ns_per_op > 0` is present; preserved as-is only when all three are empty/zero). |
| `ops_per_sec` / `mb_per_sec` / `gb_per_sec` | `f64` | Throughput overrides (`gb_per_sec` is converted to `mb_per_sec` via `x 1024`). |
| `bytes_per_op` / `bytes_row` | `u64` | Processed payload bytes per operation (`bytes_row` acts as an alias for `bytes_per_op`). |
| `bytes_used` | `u64` | Mapped to `footprint_bytes` (used by `compare-1v1` footprint mismatch checks). |
| `allocs_per_run`, `resizes_per_run`, `alloc_bytes_per_run` | `u64` | Divided by `max(ops, 1)` into per-op allocation metrics. |
| `peak_live_bytes` | `i64` | Mapped to `peak_heap_bytes`. |
| `pool_hits`, `pool_misses` | `u64` | Automatically attached as custom `Metric` entries when `> 0`. |

---

## 5. Analytics Recipes (DuckDB, Polars & Odin)

### DuckDB SQL: Longitudinal Regression Hunting

```sh
hugi export --db benchmarks/history.hugidb --lang all --all-commits --out .tmp/series.parquet
```

Use `file_row_number` (which preserves `--all-commits` chronological commit emission order even when backfilled JSONL commits share the same `timestamp_unix`) and `NULLIF(..., 0)` (to guard against sub-femtosecond clamped `0.000000` baselines):

```sql
SELECT
    lang,
    commit,
    full_name,
    p50_ns,
    LAG(p50_ns) OVER (PARTITION BY lang, full_name ORDER BY file_row_number) AS prev_p50_ns,
    ROUND(
        (p50_ns - LAG(p50_ns) OVER (PARTITION BY lang, full_name ORDER BY file_row_number))
        / NULLIF(LAG(p50_ns) OVER (PARTITION BY lang, full_name ORDER BY file_row_number), 0) * 100.0,
        2
    ) AS delta_pct,
    cv_pct,
    allocs_per_op
FROM read_parquet('.tmp/series.parquet', file_row_number = true)
ORDER BY file_row_number DESC;
```

### Python + Polars: Zero-Copy Arrow IPC Analysis

```python
import polars as pl

# Reads Feather v2 / Arrow IPC with native Decimal(18, 6) columns.
# `maintain_order=True` preserves commit-series chronological order even if `timestamp_unix` ties.
df = pl.read_ipc(".tmp/series.arrow")
print(
    df.select(["lang", "commit", "full_name", "p50_ns", "p99_ns", "ops_per_sec", "footprint_bytes"])
      .sort(["lang", "full_name"], maintain_order=True)
)
```

### Odin: Decoding `samples_blob` from Arrow IPC

If you read an exported `.arrow` or `.parquet` file in Odin and want the exact `[]i64` femtosecond samples from `samples_blob`:

```odin
import store "hugi_store:." // With -collection:hugi_store=<path_to_hugi_repo>/store (or `store "hugi:store"` with -collection:hugi=<path_to_hugi_repo>)
```

```odin
raw_blob := skadi.array_get_binary(samples_col, row_idx)
ops      := skadi.array_get(ops_col, row_idx, u64)

samples_fs, ok := store.decompress_exported_samples_fs(raw_blob, ops, context.allocator)
if !ok {
	return
}
defer delete(samples_fs)
```