# Implementation Plan: Prune Legacy `v1`–`v4` Store Formats, Float Codecs, and Ablation Flags

Follow [workflow.md](../../workflow.md): keep `hugi/` isolated from `xitdb`/`skadi`, avoid `do` statements, and execute the Phase Completion Verification and Checkpointing Protocol at the end of every phase.

---

## Phase 1: Prune `BF` Float Sample Codecs (`store/codec.odin`)

- [x] Task: Update tests in `tests/hugi_test.odin` for `U64_Codec`-only coverage before removing `BF` float codecs
    - [x] Replace `test_bss_codec_roundtrip_and_ratio` and `test_domain_float_codecs_bit_exact` (`BF` float codec coverage) with unit tests verifying all 5 `U64_Codec` variants (`Raw`, `Zlib_Delta_Varint`, `Zlib_BSS`, `Zlib_Delta_BSS`, `Zlib_Block_GCD`) and `decompress_exported_samples_fs` (`BU` format only).
    - [x] Verify new/updated tests compile cleanly once `BF` codec removal lands.
- [x] Task: Remove `BF` float sample codecs from `store/codec.odin`
    - [x] Delete `Codec` enum, `SAMPLES_MAGIC_0`, `SAMPLES_MAGIC_1`, `_encode_alp_stream`, `compress_samples_f64`, `compress_samples_f64_best`, and `decompress_samples_f64`.
    - [x] Remove the `BF` fallback branch inside `decompress_exported_samples_fs` so exported sample blobs decode via `SAMPLES_U64_MAGIC_0`/`1` (`BU`) only.
    - [x] Remove unused `vendor:compress/lz4` and `core:math` imports from `store/codec.odin`.
    - [x] Verify all 5 `U64_Codec` codecs, `compress_bytes_zlib`, `decompress_bytes_zlib`, `compress_samples_u64`, `decompress_samples_u64_with_flags`, `decompress_samples_u64`, `compress_samples_fs_i64`, and `decompress_samples_fs_i64` remain intact.
- [x] Task: Conductor - User Manual Verification 'Phase 1: Prune BF Float Sample Codecs' (Protocol in workflow.md)

---

## Phase 2: Simplify `Store_Write_Options` and Strip `v1`–`v4` Packed Formats (`store/v3_format.odin` -> `store/format.odin`)

- [x] Task: Collapse `Store_Write_Options` and rename `store/v3_format.odin` to `store/format.odin`
    - [x] Simplify `Store_Write_Options` to `{keep_hot_runs: int, cold_chunk_runs: int}` with `default_store_write_options() -> Store_Write_Options{keep_hot_runs = 0, cold_chunk_runs = 32}`.
    - [x] Move/rename `store/v3_format.odin` to `store/format.odin` (`git mv`) and update helper naming where `v3` prefixes are now obsolete (`_Format_Reader`, `_encode_hot_packet`, `_decode_hot_packet`, `_write_stats_block`, `_read_stats_block`).
- [x] Task: Delete obsolete `v3`/`v4` standalone metadata and float-sample format paths in `store/format.odin`
    - [x] Remove `HSYM_MAGIC`, `HDSC_MAGIC`, `HSNP_MAGIC`, `CZPK_V3_MAGIC`, `CZCH_MAGIC` (`CZCH\x01`), leaving only `HCAT_MAGIC` (`HCAT\x01`), `CZPK_V4_MAGIC` (`CZPK\x04`), and `CZCH_V2_MAGIC` (`CZCH\x02`).
    - [x] Delete standalone table/snapshot codecs (`_sym_table_decode`, `_sym_table_encode`, `_sym_table_load_from_moment`, `_desc_table_decode`, `_desc_table_encode`, `_desc_table_load_from_moment`, `_decode_hsnp_blob`, `_encode_hsnp_blob`) while retaining `_Symbol_Table`, `_Descriptor_Table`, `_Snap_Ref`, `_Bench_Desc`, and `_Moment_Catalog` used by `HCAT\x01`.
    - [x] Delete `_compress_sample_vec`, `_append_record_samples_as_f64`, float/non-rational branches (`rational: bool`, `!opts.use_symbol_table`, `!opts.use_descriptors`, `!opts.use_rational_time`), and `f64` stat serialization paths from hot packet and cold chunk encoders/decoders.
- [x] Task: Conductor - User Manual Verification 'Phase 2: Simplify Store_Write_Options and Strip v1-v4 Packed Formats' (Protocol in workflow.md)

---

## Phase 3: Remove Legacy Store Paths and Migration Code (`store/db.odin`)

- [x] Task: Update store tests in `tests/hugi_test.odin` for canonical `v5`-only store behavior
    - [x] Update `test_v3_symbols_descriptors_cold_rollup_and_hot_append` and any tests calling `store_set_write_options` or checking `"symbols"`/`"descriptors"`/`"snapshots"`/`"commits"`/`"run_order"` root keys so they test the canonical `HCAT\x01` + `CZPK\x04` + `CZCH\x02` paths (`keep_hot_runs`, `cold_chunk_runs`).
    - [x] Add an explicit test confirming a non-empty `xitdb` store without `"catalog"` (`HCAT\x01`) is cleanly rejected (returns `false` / empty results, zero crashes or leaks).
- [x] Task: Remove `v1`–`v4` store encoders, decoders, and migration helpers from `store/db.odin`
    - [x] Delete `CZPK_V1_MAGIC`, `CZPK_V2_MAGIC`, `CZRC_MAGIC`, `_encode_compressed_packet`, `_decode_compressed_packet`, and `_decode_legacy_snapshot_commit`.
    - [x] Delete legacy root-collection helpers (`_array_list_contains_commit_ref`, `_load_order_index`, `_load_existing_snap_map`, `_update_snap_map_for_packet`, `_load_syms_and_descs`, `_read_string_list`, `_read_commit_run_keys`) and the non-catalog `_ingest_batch_cb` callback.
    - [x] Simplify `_load_moment_catalog` (decode `"catalog"` `HCAT\x01` only — remove the legacy 6-key migration branch), `_store_ingest_batch_single_moment` / `_ingest_batch_cb_catalog`, `_Moment_Reader` (`_ensure_cold_chunks_loaded`, `_read_run_packet_from_map`, `_moment_reader_get_packet`), `store_list_runs`, `store_load_all_packets`, `store_load_raw_groups`, and `store_compact_with_options` (always use canonical catalog fast-compact).
- [x] Task: Conductor - User Manual Verification 'Phase 3: Remove Legacy Store Paths and Migration Code' (Protocol in workflow.md)

---

## Phase 4: Remove Legacy Binary Packet & Record Magics (`hugi/`, `cmd/hugi/`)

- [x] Task: Strip `HPKT\x01`, `OBPK\x01`, and `OBRC\x01` decoders in `hugi/`
    - [x] Update tests in `tests/hugi_test.odin` if referencing `legacy_ns_to_batch_ns` -> `ns_f64_to_batch_ns` and ensure `HPKT\x02`/`OBRC\x02` binary round-trips + `.jsonl` + `obench` `.json` ingestion tests pass.
    - [x] Remove `LEGACY_PACKET_V1_MAGIC`, `LEGACY_PACKET_MAGIC`, `LEGACY_RECORD_MAGIC`, and `legacy_f64` branches from `hugi/packet.odin`; rename `legacy_ns_to_batch_ns` -> `ns_f64_to_batch_ns` in `hugi/packet.odin` and `hugi/hugi.odin` while keeping `read_jsonl_packets` and `read_obench_json_packets` untouched functionally.
- [x] Task: Update `cmd/hugi/main.odin` packet detection and CLI help text
    - [x] Update `_is_packet_file` to match `"HPKT"` only (dropping `"OBPK"`).
    - [x] Update `_print_help` to reference `.hpk`/`.bpk` (`HPKT\x02`), `obench` `.json`, and `.jsonl` imports without obsolete `OBPK` wording.
- [x] Task: Conductor - User Manual Verification 'Phase 4: Remove Legacy Binary Packet and Record Magics' (Protocol in workflow.md)

---

## Phase 5: Final Verification, Repo Compatibility Check & Docs Sync

- [x] Task: Verify zero residual legacy references and check code-size reduction
    - [x] Confirm `grep` finds zero matches for `CZPK_V1_MAGIC`, `CZPK_V2_MAGIC`, `CZPK_V3_MAGIC`, `CZRC_MAGIC`, `CZCH_MAGIC`, `HSYM_MAGIC`, `HDSC_MAGIC`, `HSNP_MAGIC`, `SAMPLES_MAGIC_0`, `compress_samples_f64`, `decompress_samples_f64`, `LEGACY_PACKET_V1_MAGIC`, `LEGACY_PACKET_MAGIC`, `LEGACY_RECORD_MAGIC`, or `OBPK`.
    - [x] Measure final `wc -l store/*.odin` vs the `9,097`-line baseline.
- [x] Task: Sync `README.md` documentation with canonical `v5` behavior
    - [x] Update [README.md](../../README.md) architecture and export sections to reflect `HCAT\x01` + `CZPK\x04` + `CZCH\x02`, `u64` rational batch ticks, `35`-column `Decimal64(18, 6)` Arrow IPC / Parquet exports (`--all-commits`, `--all-runs`), and clean inline code spans (no `$...$` MathJax with underscores).
- [x] Task: Smoke-test existing `v5` repo databases (`mimir` & `temple`) and run full build/test gates
    - [x] Run `make fmt && make fmt-check && make check && make test && make example && make install && rm -rf .tmp build`.
    - [x] Copy `/home/pauli/projects/odin/mimir/benchmarks/history.hugidb` (`2,152 B`) and `/home/pauli/projects/odin/temple/benchmarks/history.hugidb` (`7,208 B`) to `/tmp` (clean up after) and verify `hugi history`, `hugi inspect`, `hugi export --format parquet`, and `hugi compact` preserve exact byte sizes (`2,152 B` and `7,208 B`) and all records.
- [x] Task: Conductor - User Manual Verification 'Phase 5: Final Verification, Repo Compatibility Check & Docs Sync' (Protocol in workflow.md)
