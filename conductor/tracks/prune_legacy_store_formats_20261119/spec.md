# Track Specification: Prune Legacy `v1`–`v4` Store Formats, Float Codecs, and Ablation Flags

## Overview & Motivation

`hugi` is pre-1.0 (`feat/initial-hugi`), and downstream reference stores (`mimir/benchmarks/history.hugidb` at `2,152 B` and `temple/benchmarks/history.hugidb` at `7,208 B`) have already migrated to the canonical `v5` format (`HCAT\x01` + `CZPK\x04` + `CZCH\x02` + `BU` `u64` rational ticks).

Currently, `store/` totals `9,097` lines largely because it retains all historical `v1`–`v4` ablation experiments: `13` internal binary magics, `9` `Store_Write_Options` toggle flags branching through `store/db.odin` (`2,844` lines) and `store/v3_format.odin` (`2,582` lines), deprecated `BF` float sample codecs (`ALP`, `Gorilla`, `LZ4_BSS`, `Zlib_BSS`) in `store/codec.odin` (`1,300` lines), and `HPKT\x01` / `OBPK\x01` / `OBRC\x01` fallback decoders in `hugi/packet.odin` and `cmd/hugi/main.odin`.

Because all storage complexity is encapsulated behind `store/` and the `hugi` CLI, removing these dead `v1`–`v4` compatibility paths and toggle branches will cut thousands of lines of maintenance surface while preserving 100% of `v5` compression ratios, `O(hot_runs)` compaction speed, and external `.jsonl` / `obench` `.json` ingestion.

## Functional Requirements

1. **Canonical `v5`-Only Store Format (`store/db.odin`, `store/v3_format.odin` -> `store/format.odin`):**
   - Persist and read exclusively `"catalog"` (`HCAT\x01`), hot `"runs"` (`CZPK\x04`), and `"cold_chunks"` (`CZCH\x02`) inside each `xitdb` `Moment`.
   - Remove superseded `v1`–`v4` internal magics and serializers/decoders:
     - `CZPK_V1_MAGIC`, `CZPK_V2_MAGIC`, `CZPK_V3_MAGIC`, `CZRC_MAGIC`, `CZCH_MAGIC` (`CZCH\x01`), `HSYM_MAGIC`, `HDSC_MAGIC`, and `HSNP_MAGIC`.
     - Symbol-table / descriptor-table / snapshot standalone blob codecs (`_sym_table_decode`, `_sym_table_encode`, `_sym_table_load_from_moment`, `_desc_table_decode`, `_desc_table_encode`, `_desc_table_load_from_moment`, `_decode_hsnp_blob`, `_encode_hsnp_blob`) while keeping the shared internal helper structs (`_Symbol_Table`, `_Descriptor_Table`, `_Moment_Catalog`) used by `HCAT\x01`.
   - Remove legacy root-slot paths (`"schema_version"`, `"symbols"`, `"descriptors"`, `"run_order"`, `"commits"`, `"snapshots"`), automatic legacy-slot migration in `_load_moment_catalog`, non-catalog `_ingest_batch_cb`, `_decode_legacy_snapshot_commit`, `_encode_compressed_packet`, `_decode_compressed_packet`, `_array_list_contains_commit_ref`, `_load_order_index`, `_load_existing_snap_map`, `_update_snap_map_for_packet`, `_load_syms_and_descs`, `_read_string_list`, `_read_commit_run_keys`, and all `!has_catalog`, `!is_rational`, `!use_symbol_table`, or `!use_descriptors` branches across `_Moment_Reader`, `store_list_runs`, `store_load_all_packets`, `store_load_raw_groups`, and `store_compact_with_options`.
   - When opening a non-empty database that lacks a valid `"catalog"` (`HCAT\x01`) entry in its latest moment, return empty / `false` cleanly instead of attempting legacy fallback decoding.

2. **Simplified `Store_Write_Options` (`store/format.odin` / `store/db.odin`):**
   - Collapse the `9` ablation flags on `Store_Write_Options` (`use_symbol_table`, `use_descriptors`, `use_domain_f64`, `use_columnar_rollup`, `use_rational_time`, `use_catalog`, `auto_seal_cold`, `keep_hot_runs`, `cold_chunk_runs`) down to just:
     ```odin
     Store_Write_Options :: struct {
     	keep_hot_runs:   int,
     	cold_chunk_runs: int,
     }
     ```
   - `default_store_write_options()` returns `{keep_hot_runs = 0, cold_chunk_runs = 32}`.
   - Always write `HCAT\x01`, `CZPK\x04`, and auto-sealed `CZCH\x02` chunks (with `cold_chunk_runs <= 0` disabling mid-ingest auto-sealing if requested; default `32`).

3. **Remove Deprecated `BF` Float Sample Codecs (`store/codec.odin`):**
   - Remove `Codec` enum (`Raw`, `Zlib_BSS`, `LZ4_BSS`, `Zlib_Gorilla`, `Zlib_ALP`), `SAMPLES_MAGIC_0` / `SAMPLES_MAGIC_1` (`"BF"`), `_encode_alp_stream`, `compress_samples_f64`, `compress_samples_f64_best`, `decompress_samples_f64`, and the `BF` fallback branch inside `decompress_exported_samples_fs`.
   - Remove unused `vendor:compress/lz4` (and `core:math` if no longer referenced in `store/codec.odin`).
   - Preserve `compress_bytes_zlib`, `decompress_bytes_zlib`, and **all 5 `U64_Codec` variants** (`Raw`, `Zlib_Delta_Varint`, `Zlib_BSS`, `Zlib_Delta_BSS`, `Zlib_Block_GCD`) along with `compress_samples_u64`, `decompress_samples_u64_with_flags`, `decompress_samples_u64`, `compress_samples_fs_i64`, `decompress_samples_fs_i64`, and `decompress_exported_samples_fs` (`BU` only).

4. **Strip Legacy Binary Packet & Record Magics (`hugi/packet.odin`, `hugi/hugi.odin`, `cmd/hugi/main.odin`):**
   - Remove `LEGACY_PACKET_V1_MAGIC` (`HPKT\x01\x00\x00\x00`), `LEGACY_PACKET_MAGIC` (`OBPK\x01\x00\x00\x00`), `LEGACY_RECORD_MAGIC` (`OBRC\x01\x00\x00\x00`), and `legacy_f64: bool` branches from `_read_record_body`, `decode_record_bytes`, and `decode_packet_bytes`.
   - Update `_is_packet_file` in `cmd/hugi/main.odin` to accept `"HPKT"` only (dropping `"OBPK"`), and refresh CLI help text to match.
   - Rename `legacy_ns_to_batch_ns` to `ns_f64_to_batch_ns` across `hugi/` and `tests/` so external float-valued JSON / JSONL importers read naturally without legacy terminology.

5. **Tests & Documentation (`tests/hugi_test.odin`, `README.md`):**
   - Replace/update tests targeting removed `BF` float codecs or disabled-option `v1`–`v4` store paths with focused `U64_Codec`, `HCAT\x01`/`CZPK\x04`/`CZCH\x02` auto-seal, `has_cold_override` deduplication, invalid/non-catalog rejection, `O(hot_runs)` compaction, `Core_Overlay`, `compare`/`compare-1v1`, `Decimal64(18, 6)` Arrow IPC + Parquet, and `--all-commits`/`--all-runs` series coverage.
   - Update `README.md` to reflect the canonical `v5` format, `35`-column `Decimal64(18, 6)` exports, and current storage sizes.

## Out of Scope

- **External File Importers (`hugi ingest`):** `read_jsonl_packets` (`.jsonl`) and `read_obench_json_packets` (`obench` `.json`) MUST remain intact in `hugi/packet.odin` and `cmd/hugi/main.odin`.
- **`U64_Codec` Variants:** All 5 integer sample codecs in `store/codec.odin` stay intact.
- **`v5` Store Binary Compatibility:** Existing `v5` `.hugidb` stores — specifically `/home/pauli/projects/odin/mimir/benchmarks/history.hugidb` (`2,152 B`) and `/home/pauli/projects/odin/temple/benchmarks/history.hugidb` (`7,208 B`) — MUST continue to open, inspect, export, and re-compact with `0` byte regression.
- **Submodules (`deps/*`):** No modifications to `deps/obench`, `deps/xitdb`, or `deps/skadi`.

## Acceptance Criteria

1. `grep` confirms zero references remain to `CZPK_V1_MAGIC`, `CZPK_V2_MAGIC`, `CZPK_V3_MAGIC`, `CZRC_MAGIC`, `CZCH_MAGIC` (`\x01`), `HSYM_MAGIC`, `HDSC_MAGIC`, `HSNP_MAGIC`, `SAMPLES_MAGIC_0`, `compress_samples_f64`, `decompress_samples_f64`, `LEGACY_PACKET_V1_MAGIC`, `LEGACY_PACKET_MAGIC`, `LEGACY_RECORD_MAGIC`, or `OBPK`.
2. `Store_Write_Options` contains only `{keep_hot_runs, cold_chunk_runs}`.
3. Total `store/` line count shrinks substantially (target reduction `>= 2,500` lines from the `9,097`-line baseline) with cleaner separation in `store/format.odin` and `store/db.odin`.
4. `make fmt-check && make check && make test && make example && make build` pass with `0` failures and `0` leaked bytes (`ODIN_TEST_FAIL_ON_BAD_MEMORY=true`).
5. `hugi history`, `hugi inspect`, and `hugi compact` smoke checks pass against `mimir` (`2,152 B`) and `temple` (`7,208 B`) `.hugidb` files with intact benchmarks and unchanged compacted sizes.
