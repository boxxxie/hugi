package hugi_tests

import xitdb "../deps/xitdb/xitdb"
import hugi "../hugi"
import store "../store"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

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
	tmp, mk_err := os.make_directory_temp("", "hugi-store-nc-*", context.allocator)
	testing.expectf(t, mk_err == nil && tmp != "", "create temp store dir: %v", mk_err)
	if mk_err != nil || tmp == "" {
		return
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}
	bad_db, _ := filepath.join({tmp, "non_catalog.hugidb"}, context.temp_allocator)

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
test_v5_xitdb_root_moment_slot_layout_and_full_seal :: proc(t: ^testing.T) {
	tmp, mk_err := os.make_directory_temp("", "hugi-store-v5-*", context.allocator)
	testing.expectf(t, mk_err == nil && tmp != "", "create temp store dir: %v", mk_err)
	if mk_err != nil || tmp == "" {
		return
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}
	db_path, _ := filepath.join({tmp, "v5_layout.hugidb"}, context.temp_allocator)

	{
		st, ok := store.store_open(db_path, context.allocator)
		testing.expect(t, ok, "open v5 store")
		if !ok {
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
	}

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
	}
}

@(test)
test_commit_prefix_matching_ignores_short_tag_false_positives :: proc(t: ^testing.T) {
	st, ok := store.store_open(":memory:", context.allocator)
	testing.expect(t, ok, "open in-memory store")
	if !ok {
		return
	}
	defer store.store_close(&st)

	pkt_v1 := _make_store_test_packet("r-v1", "v1", 25.0)
	defer hugi.packet_destroy(&pkt_v1)
	testing.expect(t, store.store_ingest_packet(&st, pkt_v1), "ingest v1 tag")

	pkt_v10 := _make_store_test_packet("r-v10", "v10", 50.0)
	defer hugi.packet_destroy(&pkt_v10)
	testing.expect(t, store.store_ingest_packet(&st, pkt_v10), "ingest v10 tag")

	pkt_sha := _make_store_test_packet("r-sha", "deadbeef1234", 75.0)
	defer hugi.packet_destroy(&pkt_sha)
	testing.expect(t, store.store_ingest_packet(&st, pkt_sha), "ingest 12-char SHA")

	q_v10 := store.store_load_pooled_records(&st, "odin", "v10")
	defer store.pooled_records_destroy(q_v10)
	testing.expect_value(t, len(q_v10), 3)
	if len(q_v10) == 3 {
		testing.expect_value(t, q_v10[0].commit, "v10")
		testing.expect_value(t, q_v10[0].run_count, 1)
	}

	q_full_sha := store.store_load_pooled_records(
		&st,
		"odin",
		"deadbeef1234567890abcdef1234567890abcdef",
	)
	defer store.pooled_records_destroy(q_full_sha)
	testing.expect_value(t, len(q_full_sha), 3)
	if len(q_full_sha) == 3 {
		testing.expect_value(t, q_full_sha[0].commit, "deadbeef1234")
	}

	q_short_sha := store.store_load_pooled_records(&st, "odin", "deadbee")
	defer store.pooled_records_destroy(q_short_sha)
	testing.expect_value(t, len(q_short_sha), 3)
	if len(q_short_sha) == 3 {
		testing.expect_value(t, q_short_sha[0].commit, "deadbeef1234")
	}

	q_upper_full := store.store_load_pooled_records(
		&st,
		"odin",
		"DEADBEEF1234567890ABCDEF1234567890ABCDEF",
	)
	defer store.pooled_records_destroy(q_upper_full)
	testing.expect_value(t, len(q_upper_full), 3)
	if len(q_upper_full) == 3 {
		testing.expect_value(t, q_upper_full[0].commit, "deadbeef1234")
	}

	q_upper_short := store.store_load_pooled_records(&st, "odin", "DEADBEE")
	defer store.pooled_records_destroy(q_upper_short)
	testing.expect_value(t, len(q_upper_short), 3)
	if len(q_upper_short) == 3 {
		testing.expect_value(t, q_upper_short[0].commit, "deadbeef1234")
	}
}

@(test)
test_store_env_provenance_hot_cold_and_compact :: proc(t: ^testing.T) {
	tmp, mk_err := os.make_directory_temp("", "hugi-store-env-*", context.allocator)
	testing.expectf(t, mk_err == nil && tmp != "", "create temp store dir: %v", mk_err)
	if mk_err != nil || tmp == "" {
		return
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}
	db_path, _ := filepath.join({tmp, "env_roundtrip.hugidb"}, context.temp_allocator)

	{
		st, ok := store.store_open(db_path, context.allocator)
		testing.expect(t, ok, "open store for env provenance test")
		if !ok {
			return
		}
		defer store.store_close(&st)

		p1 := _make_store_test_packet("run-o1", "c001", 40.0)
		p1.env = hugi.Run_Env {
			cpu_model       = strings.clone("AMD Ryzen 7 7735U"),
			governor        = strings.clone("performance"),
			scaling_max_khz = 4_821_140,
			cpuinfo_max_khz = 4_821_140,
			boost_state     = 1,
			build_flags     = strings.clone("-o:speed -microarch:native"),
			runtime_version = strings.clone("dev-2026-09"),
		}
		defer hugi.packet_destroy(&p1)
		testing.expect(t, store.store_ingest_packet(&st, p1), "ingest odin env packet")

		p2 := _make_store_test_packet("run-c1", "c001", 55.0)
		delete(p2.lang)
		p2.lang = strings.clone("cpp")
		p2.env = hugi.Run_Env {
			cpu_model       = strings.clone("AMD Ryzen 7 7735U"),
			governor        = strings.clone("performance"),
			scaling_max_khz = 4_821_140,
			cpuinfo_max_khz = 4_821_140,
			boost_state     = 1,
			build_flags     = strings.clone("-O3"),
			runtime_version = strings.clone("Apache Arrow C++ 25.0.1"),
		}
		defer hugi.packet_destroy(&p2)
		testing.expect(t, store.store_ingest_packet(&st, p2), "ingest cpp env packet")

		// Verify hot-packet provenance read before compaction.
		hot_recs := store.store_load_pooled_records(&st, "cpp", "c001")
		defer store.pooled_records_destroy(hot_recs)
		testing.expect_value(t, len(hot_recs), 3)
		if len(hot_recs) == 3 {
			testing.expect_value(t, hot_recs[0].env.cpu_model, "AMD Ryzen 7 7735U")
			testing.expect_value(t, hot_recs[0].env.scaling_max_khz, u64(4_821_140))
			testing.expect_value(t, hot_recs[0].env.build_flags, "-O3")
			testing.expect_value(t, hot_recs[0].env.runtime_version, "Apache Arrow C++ 25.0.1")
		}
	}

	// Seal all hot runs into cold CZCH\x02 chunk via compact.
	_, _, comp_ok := store.store_compact_with_options(
		db_path,
		store.Store_Write_Options{keep_hot_runs = 0, cold_chunk_runs = 32},
	)
	testing.expect(t, comp_ok, "compact with keep_hot_runs=0 should succeed")

	{
		st2, ok2 := store.store_open(db_path, context.allocator)
		testing.expect(t, ok2, "reopen compacted env store")
		if !ok2 {
			return
		}
		defer store.store_close(&st2)

		all_pkts := store.store_load_all_packets(&st2)
		defer hugi.packets_destroy(all_pkts)
		testing.expect_value(t, len(all_pkts), 2)
		if len(all_pkts) == 2 {
			testing.expect_value(t, all_pkts[0].env.cpu_model, "AMD Ryzen 7 7735U")
			testing.expect_value(t, all_pkts[0].env.governor, "performance")
			testing.expect_value(t, all_pkts[0].env.scaling_max_khz, u64(4_821_140))
			testing.expect_value(t, all_pkts[0].env.cpuinfo_max_khz, u64(4_821_140))
			testing.expect_value(t, all_pkts[0].env.boost_state, i8(1))
			testing.expect_value(t, all_pkts[0].env.build_flags, "-o:speed -microarch:native")
			testing.expect_value(t, all_pkts[0].env.runtime_version, "dev-2026-09")

			testing.expect_value(t, all_pkts[1].env.build_flags, "-O3")
			testing.expect_value(t, all_pkts[1].env.runtime_version, "Apache Arrow C++ 25.0.1")
		}
	}
}
