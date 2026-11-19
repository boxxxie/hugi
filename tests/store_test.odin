package hugi_tests

import skadi "../deps/skadi/skadi"
import xitdb "../deps/xitdb/xitdb"
import hugi "../hugi"
import store "../store"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_store_selective_snapshot_sharing :: proc(t: ^testing.T) {
	st, ok := store.store_open(":memory:")
	testing.expect(t, ok, "in-memory store should open")
	defer store.store_close(&st)

	p1 := _make_packet(
		"aaa1111",
		"odin",
		"r1",
		"kv",
		[]string{"insert", "lookup", "delete"},
		[]f64{200.0, 50.0, 150.0},
		[]u64{4096, 4096, 2048},
		selective = false,
	)
	defer hugi.packet_destroy(&p1)
	testing.expect(t, store.store_ingest_packet(&st, p1), "first ingest should succeed")

	p2 := _make_packet(
		"bbb2222",
		"odin",
		"r2",
		"kv",
		[]string{"lookup"},
		[]f64{38.0},
		[]u64{4096},
		selective = true,
	)
	p2.records[0].rank = 2
	defer hugi.packet_destroy(&p2)
	testing.expect(t, store.store_ingest_packet(&st, p2), "selective ingest should succeed")

	latest := store.store_load_pooled_records(&st, "odin")
	defer store.pooled_records_destroy(latest)
	testing.expect_value(t, len(latest), 3)
	testing.expect_value(t, latest[0].full_name, "core::insert")
	testing.expect_value(t, latest[1].full_name, "core::lookup")
	testing.expect_value(t, latest[2].full_name, "core::delete")
	testing.expect(
		t,
		math.abs(hugi.fs_to_ns_f64(latest[1].p50_fs) - 38.0) < 2.0,
		"selective lookup should update to ~38ns",
	)
	testing.expect_value(t, latest[1].commit, "bbb2222")
	testing.expect_value(t, latest[0].commit, "aaa1111")
}

@(test)
test_store_catalog_descriptors_cold_rollup_and_hot_append :: proc(t: ^testing.T) {
	if !os.exists(".tmp") {
		_ = os.make_directory(".tmp")
	}
	db_path := ".tmp/hugi_test_rollup.hugidb"
	if os.exists(db_path) {
		_ = os.remove(db_path)
	}
	defer if os.exists(db_path) {
		_ = os.remove(db_path)
	}

	commits := [6]string{"c01", "c02", "c03", "c04", "c05", "c06"}
	run_ids := [6]string{"r01", "r02", "r03", "r04", "r05", "r06"}

	{
		st, open_ok := store.store_open(db_path, context.allocator)
		testing.expect(t, open_ok, "open v5 store")
		if !open_ok {
			return
		}
		defer store.store_close(&st)

		for i in 0 ..< 6 {
			pkt := _make_store_test_packet(run_ids[i], commits[i], 40.0 + f64(i) * 5.0)
			defer hugi.packet_destroy(&pkt)
			testing.expect(t, store.store_ingest_packet(&st, pkt), "ingest v5 packet")
		}

		runs := store.store_list_runs(&st)
		defer store.run_summaries_destroy(runs)
		testing.expect_value(t, len(runs), 6)

		latest := store.store_load_pooled_records(&st, "odin")
		defer store.pooled_records_destroy(latest)
		testing.expect_value(t, len(latest), 3)
		if len(latest) == 3 {
			testing.expect_value(t, latest[0].full_name, "core::get")
			testing.expect_value(t, latest[0].commit, "c06")
			testing.expect_value(t, latest[0].bytes_per_op, u64(32))
			testing.expect_value(t, latest[0].footprint_bytes, u64(512))
			testing.expect_value(t, latest[0].peak_heap_bytes, i64(1024))
			testing.expect(
				t,
				math.abs(hugi.fs_to_ns_f64(latest[0].p50_fs) - 65.1) < 0.01,
				"p50_fs recomputed accurately",
			)
			testing.expect(
				t,
				latest[0].ops_per_sec > 0.0 && latest[0].mb_per_sec > 0.0,
				"throughput stats recomputed",
			)
			testing.expect_value(t, latest[1].full_name, "scan")
			testing.expect_value(t, latest[2].full_name, "special_put")
			testing.expect_value(t, latest[2].rank, 10)
			testing.expect_value(t, len(latest[2].metrics), 1)
			if len(latest[2].metrics) == 1 {
				testing.expect_value(t, latest[2].metrics[0].unit, "%")
				testing.expect_value(t, latest[2].metrics[0].value, 99.5)
			}
		}
	}

	opts := store.default_store_write_options()
	opts.keep_hot_runs = 2
	before, after, c_ok := store.store_compact_with_options(db_path, opts)
	testing.expect(t, c_ok, "v5 compact with cold rollup should succeed")
	testing.expect(t, before > 0 && after > 0 && after < before, "v5 compact shrinks store")

	st2, open2_ok := store.store_open(db_path, context.allocator)
	testing.expect(t, open2_ok, "reopen compacted v5 store")
	if !open2_ok {
		return
	}
	defer store.store_close(&st2)

	runs2 := store.store_list_runs(&st2)
	defer store.run_summaries_destroy(runs2)
	testing.expect_value(t, len(runs2), 6)
	if len(runs2) == 6 {
		testing.expect_value(t, runs2[0].run_id, "r01")
		testing.expect_value(t, runs2[5].run_id, "r06")
	}

	loaded_pkts := store.store_load_all_packets(&st2, context.allocator)
	defer {
		for &lp in loaded_pkts {
			hugi.packet_destroy(&lp)
		}
		delete(loaded_pkts)
	}
	testing.expect_value(t, len(loaded_pkts), 6)
	if len(loaded_pkts) == 6 {
		// Verify cold c02 (idx 1) and hot c06 (idx 5) preserve descriptors, flags, and exact bits.
		for chk_idx in ([2]int{1, 5}) {
			ref := _make_store_test_packet(
				run_ids[chk_idx],
				commits[chk_idx],
				40.0 + f64(chk_idx) * 5.0,
			)
			defer hugi.packet_destroy(&ref)
			got := loaded_pkts[chk_idx]
			testing.expect_value(t, len(got.records), 3)
			if len(got.records) == 3 {
				testing.expect(t, got.records[0].items_per_sec > 0.0, "items_per_sec restored")
				testing.expect_value(t, got.records[1].param, 64)
				testing.expect(t, got.records[1].has_param, "has_param preserved")
				testing.expect_value(t, got.records[1].threads, 2)
				testing.expect(t, got.records[1].has_threads, "has_threads preserved")
				testing.expect_value(t, got.records[1].rank, 10)
				testing.expect_value(t, got.records[2].full_name, "scan")
				testing.expect(t, got.records[2].zero_alloc_failed, "zero_alloc_failed preserved")
				testing.expect_value(t, got.records[2].error, "timeout")
				testing.expect_value(
					t,
					len(got.records[0].samples_batch_ns),
					len(ref.records[0].samples_batch_ns),
				)
				for si in 0 ..< min(len(got.records[0].samples_batch_ns), len(ref.records[0].samples_batch_ns)) {
					testing.expect_value(
						t,
						got.records[0].samples_batch_ns[si],
						ref.records[0].samples_batch_ns[si],
					)
				}
			}
		}
	}

	// Query a cold run (r02 / c02 rolled into CZCH) and a hot run (r05 / c05).
	cold_rec := store.store_load_pooled_records(&st2, "odin", commit = "c02")
	defer store.pooled_records_destroy(cold_rec)
	testing.expect_value(t, len(cold_rec), 3)
	if len(cold_rec) == 3 {
		testing.expect(
			t,
			math.abs(hugi.fs_to_ns_f64(cold_rec[0].p50_fs) - 45.1) < 0.01,
			"cold c02 p50_fs accurate",
		)
	}

	hot_rec := store.store_load_pooled_records(&st2, "odin", commit = "c05")
	defer store.pooled_records_destroy(hot_rec)
	testing.expect_value(t, len(hot_rec), 3)
	if len(hot_rec) == 3 {
		testing.expect(
			t,
			math.abs(hugi.fs_to_ns_f64(hot_rec[0].p50_fs) - 60.1) < 0.01,
			"hot c05 p50_fs accurate",
		)
	}

	// Incremental hot append onto compacted cold+hot store.
	pkt7 := _make_store_test_packet("r07", "c07", 75.0)
	defer hugi.packet_destroy(&pkt7)
	testing.expect(t, store.store_ingest_packet(&st2, pkt7), "hot append c07 onto compacted store")

	runs3 := store.store_list_runs(&st2)
	testing.expect_value(t, len(runs3), 7)
	store.run_summaries_destroy(runs3)

	latest2 := store.store_load_pooled_records(&st2, "odin")
	defer store.pooled_records_destroy(latest2)
	testing.expect_value(t, len(latest2), 3)
	if len(latest2) == 3 {
		testing.expect_value(t, latest2[0].commit, "c07")
		testing.expect(
			t,
			math.abs(hugi.fs_to_ns_f64(latest2[0].p50_fs) - 75.1) < 0.01,
			"snapshot updated to c07",
		)
	}

	// Re-ingesting an existing cold run_id (r01) must update in-place without duplicating catalog runs.
	pkt1_dup := _make_store_test_packet("r01", "c01", 40.0)
	defer hugi.packet_destroy(&pkt1_dup)
	testing.expect(t, store.store_ingest_packet(&st2, pkt1_dup), "re-ingest existing run_id r01")

	runs4 := store.store_list_runs(&st2)
	defer store.run_summaries_destroy(runs4)
	testing.expect_value(t, len(runs4), 7)
}

@(test)
test_store_auto_seal_disable_and_non_catalog_rejection :: proc(t: ^testing.T) {
	// 1. cold_chunk_runs <= 0 disables mid-ingest auto-sealing; cold_chunk_runs == 2 seals at 2 runs.
	{
		st_no_seal, ok1 := store.store_open(":memory:", context.allocator)
		testing.expect(t, ok1, "open in-memory store for no-autoseal test")
		defer store.store_close(&st_no_seal)
		store.store_set_write_options(
			&st_no_seal,
			store.Store_Write_Options{keep_hot_runs = 0, cold_chunk_runs = 0},
		)

		for i in 0 ..< 4 {
			pkt := _make_store_test_packet(
				fmt.tprintf("ns-%d", i),
				fmt.tprintf("c%d", i),
				50.0 + f64(i),
			)
			testing.expect(t, store.store_ingest_packet(&st_no_seal, pkt), "ingest no-seal run")
			hugi.packet_destroy(&pkt)
		}

		rc := xitdb.database_root_cursor(&st_no_seal.db)
		hist, _ := xitdb.read_array_list_init(rc.read_cursor)
		m_cur, _ := xitdb.array_list_get_cursor(hist, -1)
		mmap, _ := xitdb.read_hash_map_init(m_cur.?)
		cc_slot, _ := xitdb.hash_map_get_slot(mmap, "cold_chunks")
		testing.expect(t, cc_slot == nil, "cold_chunk_runs=0 must skip mid-ingest auto-sealing")
		r_slot, _ := xitdb.hash_map_get_slot(mmap, "runs")
		testing.expect(t, r_slot != nil, "all 4 runs remain in hot runs map")
	}

	{
		st_seal, ok2 := store.store_open(":memory:", context.allocator)
		testing.expect(t, ok2, "open in-memory store for custom cold_chunk_runs=2")
		defer store.store_close(&st_seal)
		store.store_set_write_options(
			&st_seal,
			store.Store_Write_Options{keep_hot_runs = 0, cold_chunk_runs = 2},
		)

		for i in 0 ..< 3 {
			pkt := _make_store_test_packet(
				fmt.tprintf("as-%d", i),
				fmt.tprintf("c%d", i),
				50.0 + f64(i),
			)
			testing.expect(t, store.store_ingest_packet(&st_seal, pkt), "ingest auto-seal run")
			hugi.packet_destroy(&pkt)
		}

		rc := xitdb.database_root_cursor(&st_seal.db)
		hist, _ := xitdb.read_array_list_init(rc.read_cursor)
		m_cur, _ := xitdb.array_list_get_cursor(hist, -1)
		mmap, _ := xitdb.read_hash_map_init(m_cur.?)
		cc_cur, _ := xitdb.hash_map_get_cursor(mmap, "cold_chunks")
		testing.expect(t, cc_cur != nil, "cold_chunk_runs=2 must seal first 2 runs")
		if cc_cur != nil {
			cc_list, _ := xitdb.read_array_list_init(cc_cur.?)
			cc_cnt, _ := xitdb.array_list_count(cc_list)
			testing.expect_value(t, cc_cnt, i64(1))
		}
	}

	// 2. Non-empty xitdb store lacking a valid HCAT\x01 "catalog" is cleanly rejected.
	if !os.exists(".tmp") {
		_ = os.make_directory(".tmp")
	}
	bad_db := ".tmp/hugi_test_non_catalog.hugidb"
	if os.exists(bad_db) {
		_ = os.remove(bad_db)
	}
	defer if os.exists(bad_db) {
		_ = os.remove(bad_db)
	}

	{
		st_raw, raw_ok := store.store_open(bad_db, context.allocator)
		testing.expect(t, raw_ok, "create raw xitdb file")
		if !raw_ok {
			return
		}
		defer store.store_close(&st_raw)

		rc := xitdb.database_root_cursor(&st_raw.db)
		hist, h_err := xitdb.write_array_list_init(rc)
		testing.expect(t, h_err == nil, "init raw history array")

		seed_legacy_cb :: proc(cursor: ^xitdb.Write_Cursor, _: rawptr) -> xitdb.Error {
			m := xitdb.write_hash_map_init(cursor^) or_return
			xitdb.hash_map_put(&m, "schema_version", u64(2)) or_return
			ord_cur := xitdb.hash_map_put_cursor(&m, "run_order") or_return
			ord_list := xitdb.write_array_list_init(ord_cur) or_return
			xitdb.array_list_append(&ord_list, "odin:legacy-run-1") or_return
			return nil
		}
		app_err := xitdb.array_list_append_context(&hist, xitdb.Slot{}, seed_legacy_cb, nil)
		testing.expect(t, app_err == nil, "seed non-catalog legacy moment")

		runs := store.store_list_runs(&st_raw)
		testing.expect_value(t, len(runs), 0)
		store.run_summaries_destroy(runs)

		commits := store.store_list_commits(&st_raw)
		testing.expect_value(t, len(commits), 0)
		store.commit_summaries_destroy(commits)

		pkts := store.store_load_all_packets(&st_raw)
		testing.expect_value(t, len(pkts), 0)
		hugi.packets_destroy(pkts)

		pooled := store.store_load_pooled_records(&st_raw, "odin")
		testing.expect_value(t, len(pooled), 0)
		store.pooled_records_destroy(pooled)

		cseries := store.store_load_commit_series_records(&st_raw, "odin")
		testing.expect_value(t, len(cseries), 0)
		store.pooled_records_destroy(cseries)

		rseries := store.store_load_all_run_records(&st_raw, "odin")
		testing.expect_value(t, len(rseries), 0)
		store.pooled_records_destroy(rseries)

		pkt := _make_store_test_packet("new-1", "abc1", 42.0)
		defer hugi.packet_destroy(&pkt)
		testing.expect(
			t,
			!store.store_ingest_packet(&st_raw, pkt),
			"ingest into non-catalog DB must return false cleanly",
		)
	}

	_, _, comp_ok := store.store_compact(bad_db)
	testing.expect(t, !comp_ok, "compacting non-catalog DB must return false cleanly")
}

@(test)
test_store_core_overlay_zero_disk_mutation :: proc(t: ^testing.T) {
	if !os.exists(".tmp") {
		_ = os.make_directory(".tmp")
	}
	db_path := ".tmp/hugi_test_overlay.hugidb"
	if os.exists(db_path) {
		_ = os.remove(db_path)
	}
	defer if os.exists(db_path) {
		_ = os.remove(db_path)
	}

	{
		st, ok := store.store_open(db_path, context.allocator)
		testing.expect(t, ok, "seed base store")
		if !ok {
			return
		}
		defer store.store_close(&st)

		p1 := _make_store_test_packet("base01", "c01", 50.0)
		defer hugi.packet_destroy(&p1)
		p2 := _make_store_test_packet("base02", "c02", 52.0)
		defer hugi.packet_destroy(&p2)
		testing.expect(t, store.store_ingest_packet(&st, p1), "ingest base01")
		testing.expect(t, store.store_ingest_packet(&st, p2), "ingest base02")
	}

	disk_before, b_err := os.read_entire_file(db_path, context.allocator)
	testing.expect(t, b_err == nil, "read base file before overlay")
	if b_err != nil {
		return
	}
	defer delete(disk_before)

	{
		ov, ov_ok := store.store_open_overlay(db_path, context.allocator)
		testing.expect(t, ov_ok, "open Core_Overlay over base file")
		if !ov_ok {
			return
		}
		defer store.store_close(&ov)
		testing.expect(t, ov.is_overlay, "overlay flag set")

		trial := _make_store_test_packet("trial01", "exp99", 30.0)
		defer hugi.packet_destroy(&trial)
		testing.expect(t, store.store_ingest_packet(&ov, trial), "ingest trial run into overlay")
		testing.expect(
			t,
			store.store_overlay_owned_bytes(&ov) > 0,
			"overlay owns modified CoW pages",
		)

		ov_runs := store.store_list_runs(&ov)
		defer store.run_summaries_destroy(ov_runs)
		testing.expect_value(t, len(ov_runs), 3)

		ov_latest := store.store_load_pooled_records(&ov, "odin")
		defer store.pooled_records_destroy(ov_latest)
		testing.expect_value(t, len(ov_latest), 3)
		if len(ov_latest) == 3 {
			testing.expect_value(t, ov_latest[0].commit, "exp99")
		}
	}

	disk_after, a_err := os.read_entire_file(db_path, context.allocator)
	testing.expect(t, a_err == nil, "read base file after overlay")
	if a_err != nil {
		return
	}
	defer delete(disk_after)
	testing.expect_value(t, len(disk_after), len(disk_before))
	if len(disk_after) == len(disk_before) {
		same := true
		for i in 0 ..< len(disk_before) {
			if disk_after[i] != disk_before[i] {
				same = false
				break
			}
		}
		testing.expect(t, same, "overlay must not mutate a single byte on disk")
	}

	st_reopen, r_ok := store.store_open(db_path, context.allocator)
	testing.expect(t, r_ok, "reopen base store after overlay")
	if r_ok {
		defer store.store_close(&st_reopen)
		base_runs := store.store_list_runs(&st_reopen)
		defer store.run_summaries_destroy(base_runs)
		testing.expect_value(t, len(base_runs), 2)
	}
}

@(test)
test_v5_gcd_bss_catalog_autoseal_and_longitudinal_series :: proc(t: ^testing.T) {
	// 1. U64_Codec.Zlib_Block_GCD & Zlib_Delta_BSS lossless round-trips + codec selection.
	gcd_samples := make([]u64, 128, context.allocator)
	defer delete(gcd_samples)
	rng_state := u64(0x9E37_79B9_7F4A_7C15)
	for i in 0 ..< len(gcd_samples) {
		rng_state = rng_state * 6364136223846793005 + 1442695040888963407
		jitter := (rng_state >> 32) % 97
		gcd_samples[i] = u64(500) * (u64(10_000) + jitter)
	}
	gcd_blob, gcd_ok := store.compress_samples_u64(gcd_samples, context.allocator)
	testing.expect(t, gcd_ok, "GCD-friendly u64 samples compress")
	if gcd_ok {
		defer delete(gcd_blob)
		testing.expect_value(t, store.U64_Codec(gcd_blob[2]), store.U64_Codec.Zlib_Block_GCD)
		back, dok := store.decompress_samples_u64(gcd_blob, context.allocator)
		testing.expect(t, dok, "Zlib_Block_GCD decompress")
		if dok {
			defer delete(back)
			testing.expect_value(t, len(back), len(gcd_samples))
			for v, i in gcd_samples {
				testing.expect_value(t, back[i], v)
			}
		}
	}

	// Constant block + coprime clustered ticks + extreme 0/max(u64) wrapping deltas.
	const_blk := [16]u64{}
	for &v in const_blk {
		v = 777_000
	}
	cb_blob, cb_ok := store.compress_samples_u64(const_blk[:], context.allocator)
	testing.expect(t, cb_ok, "constant u64 block compress")
	if cb_ok {
		defer delete(cb_blob)
		cb_back, cbd_ok := store.decompress_samples_u64(cb_blob, context.allocator)
		testing.expect(t, cbd_ok, "constant u64 block decompress")
		if cbd_ok {
			defer delete(cb_back)
			testing.expect_value(t, len(cb_back), len(const_blk))
			for v, i in const_blk {
				testing.expect_value(t, cb_back[i], v)
			}
		}
	}

	clustered_32 := make([]u64, 32, context.allocator)
	defer delete(clustered_32)
	for i in 0 ..< 32 {
		clustered_32[i] = u64(10_000_000) + u64((i * 3) % 19)
	}
	cl_blob, cl_ok := store.compress_samples_u64(clustered_32, context.allocator)
	testing.expect(t, cl_ok, "clustered u64 compress")
	if cl_ok {
		defer delete(cl_blob)
		cl_back, cld_ok := store.decompress_samples_u64(cl_blob, context.allocator)
		testing.expect(t, cld_ok, "clustered u64 decompress")
		if cld_ok {
			defer delete(cl_back)
			testing.expect_value(t, len(cl_back), len(clustered_32))
			for v, i in clustered_32 {
				testing.expect_value(t, cl_back[i], v)
			}
		}
	}

	edge_wrap := []u64{0, max(u64), 0, max(u64) - 5, 17, 0, u64(1) << 63, max(u64)}
	ew_blob, ew_ok := store.compress_samples_u64(edge_wrap, context.allocator)
	testing.expect(t, ew_ok, "wrapping u64 edge compress")
	if ew_ok {
		defer delete(ew_blob)
		ew_back, ewd_ok := store.decompress_samples_u64(ew_blob, context.allocator)
		testing.expect(t, ewd_ok, "wrapping u64 edge decompress")
		if ewd_ok {
			defer delete(ew_back)
			testing.expect_value(t, len(ew_back), len(edge_wrap))
			for v, i in edge_wrap {
				testing.expect_value(t, ew_back[i], v)
			}
		}
	}

	// 2. Consolidated HCAT\x01 catalog + 32-run auto-sealing + O(hot_runs) compaction + longitudinal exports.
	if !os.exists(".tmp") {
		_ = os.make_directory(".tmp")
	}
	db_path := ".tmp/hugi_test_v5.hugidb"
	arrow_path := ".tmp/hugi_test_v5_commits.arrow"
	parquet_path := ".tmp/hugi_test_v5_commits.parquet"
	csv_path := ".tmp/hugi_test_v5_runs.csv"
	tsv_path := ".tmp/hugi_test_v5_runs.tsv"
	json_path := ".tmp/hugi_test_v5_runs.json"
	jsonl_path := ".tmp/hugi_test_v5_runs.jsonl"
	all_paths := [7]string {
		db_path,
		arrow_path,
		parquet_path,
		csv_path,
		tsv_path,
		json_path,
		jsonl_path,
	}
	for p in all_paths {
		if os.exists(p) {
			_ = os.remove(p)
		}
	}
	defer for p in all_paths {
		if os.exists(p) {
			_ = os.remove(p)
		}
	}

	{
		st, open_ok := store.store_open(db_path, context.allocator)
		testing.expect(t, open_ok, "open v5 catalog store")
		if !open_ok {
			return
		}
		defer store.store_close(&st)

		for i in 0 ..< 36 {
			rid := fmt.tprintf("r_%03d", i)
			csha := fmt.tprintf("c%02d", i / 2)
			pkt := _make_store_test_packet(rid, csha, 40.0 + f64(i))
			pkt.timestamp_unix = i64(1770000000 + i * 60)
			testing.expect(t, store.store_ingest_packet(&st, pkt), "ingest v5 packet")
			hugi.packet_destroy(&pkt)
		}

		// Inspect raw xitdb root Moment: only catalog + 1 cold_chunks entry + 4 hot runs.
		rc := xitdb.database_root_cursor(&st.db)
		hist, h_err := xitdb.read_array_list_init(rc.read_cursor)
		testing.expect(t, h_err == nil, "read history")
		m_cur, m_err := xitdb.array_list_get_cursor(hist, -1)
		testing.expect(t, m_err == nil && m_cur != nil, "latest moment cursor")
		if m_err == nil && m_cur != nil {
			mmap, mm_err := xitdb.read_hash_map_init(m_cur.?)
			testing.expect(t, mm_err == nil, "latest moment map")
			cat_slot, _ := xitdb.hash_map_get_slot(mmap, "catalog")
			testing.expect(t, cat_slot != nil, "root Moment must have 'catalog'")
			for legacy_k in ([6]string{"schema_version", "symbols", "descriptors", "run_order", "commits", "snapshots"}) {
				ls, _ := xitdb.hash_map_get_slot(mmap, legacy_k)
				testing.expect(t, ls == nil, "legacy root slot must not exist in v5")
			}

			cc_cur, cc_err := xitdb.hash_map_get_cursor(mmap, "cold_chunks")
			testing.expect(t, cc_err == nil && cc_cur != nil, "auto-sealed cold_chunks must exist")
			if cc_err == nil && cc_cur != nil {
				cc_list, _ := xitdb.read_array_list_init(cc_cur.?)
				cc_cnt, _ := xitdb.array_list_count(cc_list)
				testing.expect_value(t, cc_cnt, i64(1))
			}

			r_cur, r_err := xitdb.hash_map_get_cursor(mmap, "runs")
			testing.expect(t, r_err == nil && r_cur != nil, "remaining 4 hot runs must exist")
			if r_cur != nil {
				rm, _ := xitdb.read_hash_map_init(r_cur.?)
				it, _ := xitdb.hash_map_iterator(rm)
				hot_cnt := 0
				for {
					kv_c, n_err := xitdb.cursor_iterator_next(&it)
					if n_err != nil || kv_c == nil {
						break
					}
					hot_cnt += 1
				}
				testing.expect_value(t, hot_cnt, 4)
			}
		}

		// Commit-by-commit & all-run longitudinal loads while mixed cold + hot.
		commit_series := store.store_load_commit_series_records(&st, "odin", "", context.allocator)
		defer store.pooled_records_destroy(commit_series)
		testing.expect_value(t, len(commit_series), 18 * 3)
		if len(commit_series) == 54 {
			testing.expect_value(t, commit_series[0].commit, "c00")
			testing.expect_value(t, commit_series[0].run_count, 2)
			testing.expect_value(t, commit_series[0].timestamp_unix, i64(1770000060))
			testing.expect_value(t, commit_series[51].commit, "c17")
		}

		run_series := store.store_load_all_run_records(&st, "odin", "", context.allocator)
		defer store.pooled_records_destroy(run_series)
		testing.expect_value(t, len(run_series), 36 * 3)
		if len(run_series) == 108 {
			testing.expect_value(t, run_series[0].run_ids[0], "r_000")
			testing.expect_value(t, run_series[0].run_count, 1)
			testing.expect_value(t, run_series[0].timestamp_unix, i64(1770000000))
			testing.expect_value(t, run_series[105].run_ids[0], "r_035")
			testing.expect_value(t, run_series[105].timestamp_unix, i64(1770000000 + 35 * 60))
		}
	}

	// Fast O(hot_runs) compaction with keep_hot_runs = 0 should seal all 36 runs and omit empty "runs".
	before_b, after_b, comp_ok := store.store_compact(db_path)
	testing.expect(
		t,
		comp_ok && before_b > 0 && after_b > 0 && after_b < before_b,
		"v5 fast compact shrinks store",
	)

	{
		st2, ok2 := store.store_open(db_path, context.allocator)
		testing.expect(t, ok2, "reopen compacted v5 store")
		if !ok2 {
			return
		}
		defer store.store_close(&st2)

		rc := xitdb.database_root_cursor(&st2.db)
		hist, _ := xitdb.read_array_list_init(rc.read_cursor)
		m_cur, _ := xitdb.array_list_get_cursor(hist, -1)
		mmap, _ := xitdb.read_hash_map_init(m_cur.?)
		cc_cur, _ := xitdb.hash_map_get_cursor(mmap, "cold_chunks")
		testing.expect(t, cc_cur != nil, "cold_chunks present after full seal")
		if cc_cur != nil {
			cc_list, _ := xitdb.read_array_list_init(cc_cur.?)
			cc_cnt, _ := xitdb.array_list_count(cc_list)
			testing.expect_value(t, cc_cnt, i64(2))
		}
		runs_slot, _ := xitdb.hash_map_get_slot(mmap, "runs")
		testing.expect(t, runs_slot == nil, "empty 'runs' omitted when 0 hot runs remain")

		// Exports on longitudinal commit series + all-run series.
		commit_series := store.store_load_commit_series_records(
			&st2,
			"odin",
			"",
			context.allocator,
		)
		defer store.pooled_records_destroy(commit_series)
		testing.expect_value(t, len(commit_series), 54)
		testing.expect(
			t,
			store.export_arrow_ipc(arrow_path, commit_series),
			"export commit-series arrow",
		)
		testing.expect(
			t,
			store.export_parquet(parquet_path, commit_series),
			"export commit-series parquet",
		)

		sc, bs, r_ok := skadi.ipc_read_file(arrow_path, context.allocator, true, false)
		testing.expect(t, r_ok, "read longitudinal arrow file")
		if r_ok {
			defer {
				for &b in bs {
					skadi.record_batch_free(&b)
				}
				delete(bs)
				if sc != nil {
					skadi.schema_free(sc)
					free(sc)
				}
			}
			testing.expect_value(t, len(bs), 1)
			if len(bs) == 1 {
				testing.expect_value(t, bs[0].length, 54)
				p50_col := skadi.record_batch_column(&bs[0], "p50_ns")
				testing.expect(t, p50_col != nil)
				if p50_col != nil {
					testing.expect_value(
						t,
						p50_col.type,
						skadi.DataType(skadi.Decimal64_Type{precision = 18, scale = 6}),
					)
				}
				ts_col := skadi.record_batch_column(&bs[0], "timestamp_unix")
				testing.expect(t, ts_col != nil)
				if ts_col != nil {
					testing.expect_value(t, skadi.array_get(ts_col, 0, i64), i64(1770000060))
				}
			}
		}

		all_runs := store.store_load_all_run_records(&st2, "odin", "", context.allocator)
		defer store.pooled_records_destroy(all_runs)
		testing.expect_value(t, len(all_runs), 108)
		testing.expect(t, store.export_csv(csv_path, all_runs), "export all-runs csv")
		testing.expect(t, store.export_tsv(tsv_path, all_runs), "export all-runs tsv")
		testing.expect(t, store.export_json(json_path, all_runs), "export all-runs json")
		testing.expect(t, store.export_jsonl(jsonl_path, all_runs), "export all-runs jsonl")
		if jb, jerr := os.read_entire_file(jsonl_path, context.allocator); jerr == nil {
			defer delete(jb)
			jstr := string(jb)
			testing.expect(t, strings.contains(jstr, `"run_id":"r_000"`), "jsonl includes r_000")
			testing.expect(t, strings.contains(jstr, `"run_id":"r_035"`), "jsonl includes r_035")
			testing.expect(
				t,
				strings.contains(jstr, `"timestamp_unix":1770000000`),
				"jsonl includes timestamp_unix",
			)
		}

		// Hot override of an already-sealed cold run must win and survive compaction.
		ov_pkt := _make_store_test_packet("r_000", "c00", 99.0)
		ov_pkt.timestamp_unix = 1770009999
		testing.expect(
			t,
			store.store_ingest_packet(&st2, ov_pkt),
			"override sealed cold run r_000",
		)
		hugi.packet_destroy(&ov_pkt)

		ov_rec := store.store_load_pooled_records(&st2, "odin", run_id = "r_000")
		defer store.pooled_records_destroy(ov_rec)
		testing.expect_value(t, len(ov_rec), 3)
		if len(ov_rec) == 3 {
			testing.expect(
				t,
				math.abs(hugi.fs_to_ns_f64(ov_rec[0].p50_fs) - 99.1) < 0.01,
				"hot override replaces sealed cold packet",
			)
		}
	}

	_, _, c_ov_ok := store.store_compact(db_path)
	testing.expect(t, c_ov_ok, "compact after hot override of sealed cold run")
	st3, ok3 := store.store_open(db_path, context.allocator)
	testing.expect(t, ok3, "reopen after override compact")
	if ok3 {
		defer store.store_close(&st3)
		runs3 := store.store_list_runs(&st3)
		defer store.run_summaries_destroy(runs3)
		testing.expect_value(t, len(runs3), 36)
		ov_rec3 := store.store_load_pooled_records(&st3, "odin", run_id = "r_000")
		defer store.pooled_records_destroy(ov_rec3)
		testing.expect_value(t, len(ov_rec3), 3)
		if len(ov_rec3) == 3 {
			testing.expect(
				t,
				math.abs(hugi.fs_to_ns_f64(ov_rec3[0].p50_fs) - 99.1) < 0.01,
				"overridden r_000 preserved after compact",
			)
		}
	}
}

@(test)
test_store_multilang_empty_lang_queries :: proc(t: ^testing.T) {
	st, ok := store.store_open(":memory:")
	testing.expect(t, ok, "in-memory store should open")
	if !ok {
		return
	}
	defer store.store_close(&st)

	inputs := [5]struct {
		commit, lang, run_id: string,
		ns:                   f64,
	} {
		{"ml01", "odin", "r-o1", 50.0},
		{"ml01", "odin", "r-o2", 50.0},
		{"ml01", "zig", "r-z1", 120.0},
		{"ml02", "odin", "r-o3", 45.0},
		{"ml02", "zig", "r-z2", 115.0},
	}
	for item in inputs {
		pkt := _make_packet(
			item.commit,
			item.lang,
			item.run_id,
			"ml",
			[]string{"op_a"},
			[]f64{item.ns},
			[]u64{1024},
		)
		testing.expect(t, store.store_ingest_packet(&st, pkt), "ingest multilang packet")
		hugi.packet_destroy(&pkt)
	}

	// 1. Commit query with lang == "" must preserve distinct "odin" and "zig" pooled rows.
	ml01 := store.store_load_pooled_records(&st, lang = "", commit = "ml01")
	defer store.pooled_records_destroy(ml01)
	testing.expect_value(t, len(ml01), 2)
	if len(ml01) == 2 {
		testing.expect_value(t, ml01[0].lang, "odin")
		testing.expect_value(t, ml01[0].run_count, 2)
		testing.expect(
			t,
			math.abs(hugi.fs_to_ns_f64(ml01[0].p50_fs) - 50.0) < 2.0,
			"odin ml01 median ~50ns",
		)
		testing.expect_value(t, ml01[1].lang, "zig")
		testing.expect_value(t, ml01[1].run_count, 1)
		testing.expect(
			t,
			math.abs(hugi.fs_to_ns_f64(ml01[1].p50_fs) - 120.0) < 2.0,
			"zig ml01 median ~120ns",
		)
	}

	// 2. Commit series with lang == "" must preserve (commit, lang) buckets without cross-lang merge.
	series := store.store_load_commit_series_records(&st, lang = "")
	defer store.pooled_records_destroy(series)
	testing.expect_value(t, len(series), 4)
	if len(series) == 4 {
		expected := [4]struct {
			commit, lang: string,
			run_count:    int,
			ns:           f64,
		} {
			{"ml01", "odin", 2, 50.0},
			{"ml01", "zig", 1, 120.0},
			{"ml02", "odin", 1, 45.0},
			{"ml02", "zig", 1, 115.0},
		}
		for exp, i in expected {
			testing.expect_value(t, series[i].commit, exp.commit)
			testing.expect_value(t, series[i].lang, exp.lang)
			testing.expect_value(t, series[i].run_count, exp.run_count)
			testing.expect(
				t,
				math.abs(hugi.fs_to_ns_f64(series[i].p50_fs) - exp.ns) < 2.0,
				"commit series median matches expected language",
			)
		}
	}

	// 3. All-run series with lang == "" must preserve all 5 runs with their true languages.
	all_runs := store.store_load_all_run_records(&st, lang = "")
	defer store.pooled_records_destroy(all_runs)
	testing.expect_value(t, len(all_runs), 5)
	if len(all_runs) == 5 {
		odin_cnt := 0
		zig_cnt := 0
		for r in all_runs {
			if r.lang == "odin" {
				odin_cnt += 1
			} else if r.lang == "zig" {
				zig_cnt += 1
			}
		}
		testing.expect_value(t, odin_cnt, 3)
		testing.expect_value(t, zig_cnt, 2)
	}
}
