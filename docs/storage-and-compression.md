# Storage Format & Compression Architecture

`hugi` stores benchmark histories in `.hugidb` files built on top of **`xitdb`** (an immutable, Copy-on-Write paged database) combined with domain-specific columnar and integer codecs designed specifically for longitudinal performance series.

---

## 1. Fixed-Point Femtosecond Arithmetic (`1 fs = 10^-15 s`)

### Why Not `f64` Nanoseconds?

Standard benchmark harnesses store per-operation timings as IEEE-754 `f64` nanoseconds. That design breaks down at both extremes:
* **Sub-nanosecond batched kernels:** A SIMD loop executing `10,000,000` operations in `50,010 ns` takes `0.005001 ns/op` (`5.001 ps/op`, or `5,001 fs/op`). Integer nanoseconds truncate this to `0`, while binary `f64` introduces representation error (`0.005001` is not an exact dyadic fraction) that drifts across multi-run pooling and text/Parquet exports.
* **Deterministic quantiles:** Linearly interpolating percentiles in floating-point arithmetic can vary with rounding modes or instruction fusion.

### Exact Rational Scaling & 128-Bit Quantiles

1. **Raw Measurement (`u64` Batch Nanoseconds):**
   During execution, `hugi` stores each sample's overhead-adjusted batch elapsed time as an exact `u64` integer in `samples_batch_ns` alongside `ops_per_sample: u64`.
2. **Per-Operation Femtosecond Conversion (`batch_ns_to_op_fs`):**
   Per-operation durations are computed with rounded 128-bit unsigned integer division:
   ```text
   op_fs = (batch_ns * 1_000_000 + ops_per_sample / 2) / ops_per_sample
   ```
   Stored in signed `i64` femtoseconds (`FS_PER_NS :: 1_000_000`), `hugi` represents exact durations from `1 fs` up to `max(i64) ~= 9.22e18 fs` (`~106.75 days`) without overflow.
3. **Exact Quantile Interpolation (`percentile_sorted_fs`):**
   Percentiles (`p25`, `p50`, `p75`, `p95`, `p99`), `mean_fs`, `iqr_fs`, and `mad_fs` are computed over sorted `[]i64` slices using 128-bit signed integer (`i128`) linear interpolation—guaranteeing permutation invariance and bit-identical statistics across platforms.

---

## 2. `xitdb` Copy-on-Write Root Layout (`v5`)

At the `xitdb` layer, the database root is an append-only `Array_List` of transactional `Moment` `Hash_Map`s. Every `store_ingest_packet` appends a new `Moment` sharing unchanged B-tree/HAMT pages with prior moments.

Each `Moment` contains at most **three keys**:

| Moment Key | Magic Header | Purpose |
| :--- | :--- | :--- |
| `"catalog"` | `HCAT\x01\x00\x00\x00` | Zlib-9 compressed root catalog containing global symbols, static benchmark descriptors, chronological run index, and per-language latest-snapshot pointers. |
| `"runs"` | `CZPK\x04\x00\x00\x00` | Map of `<lang>:<run_id>` -> recent unsealed ("hot") run packets. Omitted completely when all runs are sealed into cold chunks. |
| `"cold_chunks"` | `CZCH\x02\x00\x00\x00` | Append-only `Array_List` of transposed columnar rollup chunks (up to 128 runs per chunk). |

### Copy-on-Write RAM Overlays (`Core_Overlay`)

`store_open_overlay(path)` opens an existing `.hugidb` file on disk read-only (returning `ok = false` if `path` does not exist) and wraps it in `xitdb.Core_Overlay`. Any newly ingested packets allocate pages strictly in RAM (`store_overlay_owned_bytes`), enabling full SQL/Parquet exports and baseline comparisons against historical runs with **zero disk writes** (whereas the CLI `hugi run --overlay` falls back to `store_open(":memory:")` when no `.hugidb` file exists yet).

---

## 3. Tier 1: Consolidated Moment Catalog (`HCAT\x01`)

Instead of repeating benchmark metadata inside every run or row group, `HCAT\x01` deduplicates metadata globally across the entire database:

1. **Global Symbol Table (`_Symbol_Table`):**
   Interns every repeated string (`suite_name`, `group_name`, `name`, `lang`, `commit`, `os`, `arch`, `optimization`, `odin_version`, error strings, and custom metric units) to a compact `u32` varint ID (`0` is reserved for `""`).
2. **Static Descriptor Table (`_Descriptor_Table`):**
   Interns static benchmark definitions (`group_sym`, `name_sym`, `custom_full_sym`, `param`, `threads`, `bytes_per_op`, `items_per_op`, and canonical-name flags) into a single `desc_id: u32`. Canonical `full_name` strings (like `hash::fnv1a[256]/t4`) are reconstructed on read without storing redundant strings.
3. **Delta-Compressed Run Directory:**
   Stores chronological `_Catalog_Run_Entry` rows using carry-forward flags (`SAME_LANG`, `SAME_COMMIT`, `SAME_SUITE`, `COLD`) and zigzag-varint timestamp deltas. Listing history (`hugi history`) reads **only** the `HCAT` catalog without touching hot packets or cold chunks.
4. **Per-Language Snapshot Map (`snaps[lang][bench_key] -> (run_ord, rec_idx)`):**
   Tracks which `(run_ord, rec_idx)` holds the latest observation for each benchmark. When a full-suite run updates all benchmarks together, `HCAT` sets an `all_same` bit and writes `common_ord` once instead of per benchmark.

---

## 4. Tier 2: Presence-Bitmasked Hot Packets (`CZPK\x04`)

Newly ingested runs land in `"runs"` as `CZPK\x04` blobs split into two independently compressed streams:

1. **Zlib-9 Metadata Stream:**
   Each record writes `desc_id`, a varint **presence bitmask** (`_rec_presence_flags`), `ops_per_sample`, `samples`, and `warmup`. Sparse or default fields—custom rank, `footprint_bytes`, `peak_heap_bytes`, `error`, `metrics`, heap allocations, temp allocations, CPU cycles, or zero-sample fallback stats—consume **zero bytes** unless non-zero.
2. **Unified `BU` Sample Stream:**
   All `samples_batch_ns` slices across all benchmarks in the packet are concatenated and compressed together via `compress_samples_u64`.

---

## 5. Tier 3: Transposed Columnar Cold Rollups (`CZCH\x02`)

### Auto-Sealing & `O(hot_runs)` Fast Compaction

* **Mid-Ingest Auto-Sealing:** By default (`cold_chunk_runs = 32`, `keep_hot_runs = 0`), whenever 32 unsealed hot runs accumulate, `hugi` automatically seals them into a `CZCH\x02` cold chunk and removes their keys from `"runs"`.
* **Fast Compaction (`_try_fast_catalog_compact`):** When `hugi compact` runs, already-sealed `CZCH\x02` chunks are copied **verbatim** without decompression; only the remaining hot runs (`O(hot_runs)`) are decoded and sealed into a new chunk before `xitdb.database_compact` strips dead CoW pages. Sealing the *first* cold chunk requires at least `2` unsealed runs (`rem >= 2`, so a 1-run `.hugidb` stays as a `CZPK\x04` hot packet), and fast compaction falls back to a full unpack-and-reingest rewrite whenever `has_cold_override` is set or `--keep-hot <N>` exceeds the current unsealed hot-run count (unsealing cold runs).
* **Hot Overrides:** Re-ingesting an existing `(lang, run_id)` that was previously sealed into a cold chunk sets `has_cold_override` and shadows the cold entry cleanly from `"runs"` until the next full rewrite.

### Inside a `CZCH\x02` Chunk

A cold chunk transposes up to `_COLD_CHUNK_MAX_RUNS :: 128` runs from row-oriented packets into **struct-of-arrays columns**:
* Run headers (`run_id`, `commit`, `lang`, `suite_name`, `os`, `arch`, `optimization`, `odin_version`, zigzag timestamp deltas, `selective` flags, `rec_counts`) are laid out column-by-column.
* Record arrays (`desc_ids`, `ops_per_sample`, `sample_counts`, and `warmups` are delta-zigzag encoded across all records in the chunk; `rflags` is encoded as plain unsigned varints), followed by sparse field columns.
* **Cross-Commit Benchmark Sample Grouping:** Before invoking the `BU` sample codec, `CZCH\x02` sorts unique `desc_id`s and groups **all samples for the same benchmark across all 128 runs contiguously**. Because `core::lookup` at commit `N` has nearly identical batch timings to `core::lookup` at commit `N+1`, grouping by `desc_id` gives delta/BSS/GCD transforms and Zlib's 32 KiB sliding window maximum redundancy—a key reason `.hugidb` outperforms row-grouped Parquet files.

---

## 6. Tier 4: The 5-Way Racing Sample Codec (`BU`)

Every integer sample stream (`compress_samples_u64`) carries a 12-byte header (`'B'`, `'U'`, `codec: u8`, `flags: u8`, `count: u32le`, `raw_len: u32le`) and races **five lossless encodings**, storing whichever yields the smallest byte size:

| Codec ID | Variant | Transform Pipeline | Best For |
| :---: | :--- | :--- | :--- |
| `0` | `Raw` | Uncompressed `u64le` (`count * 8` bytes) | Empty/single-element slices (`n <= 1`) or slices where no compressed candidate beats `count * 8` bytes; guarantees **zero expansion** beyond the 12-byte header. |
| `1` | `Zlib_Delta_Varint` | Wrapping `i64(s[i] - s[i-1])` -> Zigzag Varint -> Zlib-9 | Tight, low-jitter benchmark timings where adjacent samples differ by small integers (evaluated for all `n >= 1`). |
| `2` | `Zlib_BSS` | 8-way Byte-Stream-Split (`lane * n + i`) -> Zlib-9 | Clustered 64-bit values sharing identical upper bytes where non-monotonic jitter defeats varints (evaluated for `n > 2`). |
| `3` | `Zlib_Delta_BSS` | Wrapping Delta -> Zigzag `u64` -> 8-way BSS -> Zlib-9 | Large steady strides with wide magnitude where deltas share high-order zero/constant byte lanes (evaluated for `n > 2`). |
| `4` | `Zlib_Block_GCD` | Per-16-sample block GCD factoring + Zigzag quotients -> Zlib-9 | Coarse hardware clocks (e.g., 24 MHz / 100 MHz counters or fixed batch multiples) where timings are multiples of a tick quantum `g > 1` (evaluated for `n >= 4`). |

### `flags` Byte Semantics

* `flags == 0`: Payload encodes unsigned `u64` `samples_batch_ns` (used in `CZPK`, `CZCH`, and uniform-batch `samples_blob` exports).
* `flags == 1`: Payload encodes zigzag-mapped signed `i64` `samples_fs` (`compress_samples_fs_i64`), used in Arrow/Parquet `samples_blob` exports when pooling runs that used different `ops_per_sample` batch sizes.

---

## 7. Binary Wire Formats (`HPKT\x02` & `OBRC\x02`)

For inter-process transport between compiled benchmark binaries and `hugi run` (or standalone artifact archiving via `--packet-out`), `hugi/packet.odin` provides zero-dependency little-endian binary wire formats:

* **`HPKT\x02\x00\x00\x00` (`Run_Packet`):** Length-prefixed (`u32le`) UTF-8 suite/environment strings, `i64le` `timestamp_unix`, `u8` `selective` flag, `u32le` record count, and sequential record bodies.
* **`OBRC\x02\x00\x00\x00` (`Record`):** Standalone single-record binary envelope with identical field layout (`encode_record_bytes` / `decode_record_bytes`), supporting optional omission of `samples_batch_ns` (`include_samples = false`).