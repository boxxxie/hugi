package hugi_tests

import skadi "../deps/skadi/skadi"
import xitdb "../deps/xitdb/xitdb"
import hugi "../hugi"
import store "../store"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
_make_packet :: proc(
	commit, lang, run_id, suite_name: string,
	names: []string,
	medians: []f64,
	footprints: []u64,
	selective := false,
	samples_per_rec := 16,
	spread_ns := 1.0,
) -> hugi.Run_Packet {
	pkt := hugi.Run_Packet {
		suite_name     = strings.clone(suite_name),
		lang           = strings.clone(lang),
		commit         = strings.clone(commit),
		run_id         = strings.clone(run_id),
		os             = strings.clone("linux"),
		arch           = strings.clone("amd64"),
		optimization   = strings.clone("Speed"),
		odin_version   = strings.clone("test"),
		timestamp_unix = 1700000000,
		selective      = selective,
		records        = make([dynamic]hugi.Record, 0, len(names)),
	}

	for name, i in names {
		med := medians[i]
		foot := footprints[i]
		ops := u64(100)
		samples := make([dynamic]u64, samples_per_rec)
		for s in 0 ..< samples_per_rec {
			offset := (f64(s) - f64(samples_per_rec - 1) * 0.5) * spread_ns
			samples[s] = hugi.ns_f64_to_batch_ns(max(med + offset, 1.0), ops)
		}

		r := hugi.Record {
			rank               = i + 1,
			group_name         = strings.clone("core"),
			name               = strings.clone(name),
			full_name          = strings.clone(fmt.tprintf("core::%s", name)),
			ops_per_sample     = ops,
			samples            = samples_per_rec,
			bytes_per_op       = 64,
			footprint_bytes    = foot,
			allocs_per_op      = 0,
			alloc_bytes_per_op = 0,
			samples_batch_ns   = samples,
			metrics            = make([dynamic]hugi.Metric),
		}
		hugi.recompute_record_stats_from_samples(&r)
		if r.p50_fs > 0 {
			r.items_per_sec = hugi.FS_PER_SEC_F64 / f64(r.p50_fs)
			r.mb_per_sec = (f64(r.bytes_per_op) * r.items_per_sec) / (1024.0 * 1024.0)
		}
		append(&pkt.records, r)
	}
	return pkt
}

@(test)
test_u64_codecs_all_variants_roundtrip :: proc(t: ^testing.T) {
	verify_roundtrip :: proc(
		t: ^testing.T,
		samples: []u64,
		expected_codec: store.U64_Codec,
		label: string,
		loc := #caller_location,
	) {
		blob, c_ok := store.compress_samples_u64(samples, context.allocator)
		testing.expectf(t, c_ok, "%s: compress should succeed", label, loc = loc)
		if !c_ok {
			return
		}
		defer delete(blob)

		testing.expect_value(t, blob[0], store.SAMPLES_U64_MAGIC_0, loc = loc)
		testing.expect_value(t, blob[1], store.SAMPLES_U64_MAGIC_1, loc = loc)
		testing.expect_value(t, store.U64_Codec(blob[2]), expected_codec, loc = loc)

		back, d_ok := store.decompress_samples_u64(blob, context.allocator)
		testing.expectf(t, d_ok, "%s: decompress should succeed", label, loc = loc)
		if !d_ok {
			return
		}
		defer delete(back)

		testing.expect_value(t, len(back), len(samples), loc = loc)
		for v, i in samples {
			testing.expect_value(t, back[i], v, loc = loc)
		}
	}

	// 1. Raw (empty and short high-entropy pair).
	verify_roundtrip(t, []u64{}, .Raw, "raw-empty")
	raw_pair := []u64{0xFEDC_BA98_7654_3210, 0x0123_4567_89AB_CDEF}
	verify_roundtrip(t, raw_pair, .Raw, "raw-pair")

	// 2. Zlib_Delta_Varint (coprime small integer deltas).
	delta_var := make([]u64, 64)
	defer delete(delta_var)
	for i in 0 ..< len(delta_var) {
		delta_var[i] = 1_000_000 + u64(i % 3)
	}
	verify_roundtrip(t, delta_var, .Zlib_Delta_Varint, "delta-varint")

	// 3. Zlib_BSS (large palette values with low per-byte-lane entropy and gcd == 1).
	palette := [4]u64 {
		0xA1B2_C3D4_E5F6_0718,
		0x1122_3344_5566_7788,
		0x9988_7766_5544_3322,
		0xFFEE_DDCC_BBAA_9988,
	}
	bss_samples := make([]u64, 128)
	defer delete(bss_samples)
	for i in 0 ..< len(bss_samples) {
		bss_samples[i] = palette[(i * 5 + i / 3) % 4]
	}
	verify_roundtrip(t, bss_samples, .Zlib_BSS, "zlib-bss")

	// 4. Zlib_Delta_BSS (large steady 64-bit stride with coprime jitter -> gcd == 1).
	delta_bss := make([]u64, 256)
	defer delete(delta_bss)
	acc := u64(10_000_000_000)
	for i in 0 ..< len(delta_bss) {
		acc += u64(0x1122_3344_5566_7700) + u64(i % 3)
		delta_bss[i] = acc
	}
	verify_roundtrip(t, delta_bss, .Zlib_Delta_BSS, "delta-bss")

	// 5. Zlib_Block_GCD (clustered pseudo-random multiples of 500).
	gcd_samples := make([]u64, 128)
	defer delete(gcd_samples)
	rng_state := u64(0x9E37_79B9_7F4A_7C15)
	for i in 0 ..< len(gcd_samples) {
		rng_state = rng_state * 6364136223846793005 + 1442695040888963407
		jitter := (rng_state >> 32) % 97
		gcd_samples[i] = u64(500) * (u64(10_000) + jitter)
	}
	verify_roundtrip(t, gcd_samples, .Zlib_Block_GCD, "block-gcd")
}

@(test)
test_packet_binary_roundtrip :: proc(t: ^testing.T) {
	pkt := _make_packet(
		"abc1234",
		"odin",
		"run-001",
		"suite_alpha",
		[]string{"read", "write"},
		[]f64{120.5, 450.25},
		[]u64{4096, 8192},
		selective = true,
	)
	defer hugi.packet_destroy(&pkt)

	append(&pkt.records[0].metrics, hugi.Metric{unit = strings.clone("hit%"), value = 99.5})

	encoded := hugi.encode_packet_bytes(pkt, true)
	defer delete(encoded)

	decoded, ok := hugi.decode_packet_bytes(encoded)
	defer hugi.packet_destroy(&decoded)
	testing.expect(t, ok, "packet decode should succeed")
	testing.expect_value(t, decoded.commit, "abc1234")
	testing.expect_value(t, decoded.lang, "odin")
	testing.expect_value(t, decoded.selective, true)
	testing.expect_value(t, len(decoded.records), 2)
	testing.expect_value(t, decoded.records[0].footprint_bytes, u64(4096))
	testing.expect_value(t, len(decoded.records[0].metrics), 1)
	testing.expect_value(t, decoded.records[0].metrics[0].unit, "hit%")
	testing.expect_value(t, len(decoded.records[1].samples_batch_ns), 16)
	testing.expect_value(
		t,
		decoded.records[0].samples_batch_ns[3],
		pkt.records[0].samples_batch_ns[3],
	)

	// Record binary round-trip (OBRC\x02).
	rec_bytes := hugi.encode_record_bytes(pkt.records[0], true)
	defer delete(rec_bytes)
	rec_dec, rec_ok := hugi.decode_record_bytes(rec_bytes)
	defer hugi.record_destroy(&rec_dec)
	testing.expect(t, rec_ok, "OBRC v2 record decode should succeed")
	testing.expect_value(t, rec_dec.full_name, pkt.records[0].full_name)
	testing.expect_value(t, len(rec_dec.samples_batch_ns), 16)

	// Removed v1 packet and record headers must be rejected.
	for bad_pkt in ([2][8]u8{{'H', 'P', 'K', 'T', 1, 0, 0, 0}, {'O', 'B', 'P', 'K', 1, 0, 0, 0}}) {
		buf := make([]u8, len(encoded))
		copy(buf, encoded)
		hdr := bad_pkt
		copy(buf[:8], hdr[:])
		bad_dec, bad_ok := hugi.decode_packet_bytes(buf)
		testing.expect(t, !bad_ok, "v1 packet magic must be rejected")
		hugi.packet_destroy(&bad_dec)
		delete(buf)
	}
	{
		rbuf := make([]u8, len(rec_bytes))
		copy(rbuf, rec_bytes)
		copy(rbuf[:8], transmute([]u8)string("OBRC\x01\x00\x00\x00"))
		bad_rec, bad_rok := hugi.decode_record_bytes(rbuf)
		testing.expect(t, !bad_rok, "legacy OBRC v1 magic must be rejected")
		hugi.record_destroy(&bad_rec)
		delete(rbuf)
	}

	// Verify .jsonl and obench .json importers remain intact.
	if !os.exists(".tmp") {
		_ = os.make_directory(".tmp")
	}
	jsonl_in := ".tmp/hugi_test_import.jsonl"
	ojson_in := ".tmp/hugi_test_import_obench.json"
	defer {
		if os.exists(jsonl_in) {
			_ = os.remove(jsonl_in)
		}
		if os.exists(ojson_in) {
			_ = os.remove(ojson_in)
		}
	}

	jsonl_data :=
		`{"rank":1,"group":"kv","lang":"odin","commit":"imp001","run_id":"jr-1","name":"kv::get","ops":100,"runs":3,"warmup":1,"median_ns":42.5,"samples_ns":[42.0,42.5,43.0],"bytes_used":512}` +
		"\n"
	testing.expect(
		t,
		os.write_entire_file(jsonl_in, transmute([]u8)jsonl_data) == nil,
		"write sample jsonl",
	)
	jpkts, j_ok := hugi.read_jsonl_packets(jsonl_in)
	testing.expect(t, j_ok, "read_jsonl_packets should succeed")
	if j_ok {
		testing.expect_value(t, len(jpkts), 1)
		if len(jpkts) == 1 && len(jpkts[0].records) == 1 {
			testing.expect_value(t, jpkts[0].commit, "imp001")
			testing.expect_value(t, jpkts[0].records[0].samples_batch_ns[1], u64(4250))
		}
	}
	hugi.packets_destroy(jpkts)

	ojson_data := `{"format_version":3,"suite_name":"ob_suite","os":"linux","arch":"amd64","optimization":"Speed","odin_version":"dev","benchmarks":[{"suite_name":"ob_suite","group_name":"math","name":"mul","full_name":"math::mul","samples":3,"batch_size":10,"min_ns":10.0,"p50_ns":10.1,"p95_ns":10.2,"p99_ns":10.2,"max_ns":10.2,"mean_ns":10.1,"samples_batch_ns":[100,101,102]}]}`
	testing.expect(
		t,
		os.write_entire_file(ojson_in, transmute([]u8)ojson_data) == nil,
		"write sample obench json",
	)
	opkts, o_ok := hugi.read_obench_json_packets(ojson_in, commit_override = "ob001")
	testing.expect(t, o_ok, "read_obench_json_packets should succeed")
	if o_ok {
		testing.expect_value(t, len(opkts), 1)
		if len(opkts) == 1 && len(opkts[0].records) == 1 {
			testing.expect_value(t, opkts[0].commit, "ob001")
			testing.expect_value(t, opkts[0].records[0].samples_batch_ns[1], u64(101))
		}
	}
	hugi.packets_destroy(opkts)
}

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
test_pooling_and_mann_whitney_welch :: proc(t: ^testing.T) {
	st, ok := store.store_open(":memory:")
	testing.expect(t, ok, "in-memory store should open")
	defer store.store_close(&st)

	for i in 0 ..< 3 {
		rid_b := fmt.tprintf("base-%d", i)
		pb := _make_packet(
			"base111",
			"odin",
			rid_b,
			"kv",
			[]string{"scan"},
			[]f64{100.0 + f64(i) * 0.2},
			[]u64{8192},
			samples_per_rec = 10,
			spread_ns = 0.2,
		)
		testing.expect(t, store.store_ingest_packet(&st, pb), "baseline run ingest")
		hugi.packet_destroy(&pb)

		rid_c := fmt.tprintf("cand-%d", i)
		pc := _make_packet(
			"cand222",
			"odin",
			rid_c,
			"kv",
			[]string{"scan"},
			[]f64{140.0 + f64(i) * 0.2},
			[]u64{8192},
			samples_per_rec = 10,
			spread_ns = 0.2,
		)
		testing.expect(t, store.store_ingest_packet(&st, pc), "candidate run ingest")
		hugi.packet_destroy(&pc)
	}

	base := store.store_load_pooled_records(&st, "odin", "base111")
	defer store.pooled_records_destroy(base)
	cand := store.store_load_pooled_records(&st, "odin", "cand222")
	defer store.pooled_records_destroy(cand)

	testing.expect_value(t, len(base), 1)
	testing.expect_value(t, base[0].run_count, 3)
	testing.expect_value(t, base[0].samples, 30)

	rep := store.compare_records(base, cand, threshold_pct = 5.0)
	defer store.comparison_report_destroy(&rep)
	testing.expect_value(t, len(rep.rows), 1)
	testing.expect_value(t, rep.regressions, 1)
	testing.expect_value(t, rep.rows[0].verdict, store.Verdict.Regression)
	testing.expect(t, rep.rows[0].p_value < 0.01, "expected significant Mann-Whitney p-value")
	testing.expect(t, rep.rows[0].delta_pct > 25.0, "expected >25% positive regression delta")
}

@(test)
test_compare_1v1_and_footprint_mismatch :: proc(t: ^testing.T) {
	st, ok := store.store_open(":memory:")
	testing.expect(t, ok, "in-memory store should open")
	defer store.store_close(&st)

	po := _make_packet(
		"cmp001",
		"odin",
		"run-shared-001",
		"db",
		[]string{"fast_op", "db_op"},
		[]f64{50.0, 120.0},
		[]u64{4096, 4096},
	)
	defer hugi.packet_destroy(&po)
	pz := _make_packet(
		"cmp001",
		"zig",
		"run-shared-001",
		"db",
		[]string{"fast_op", "db_op"},
		[]f64{100.0, 118.0},
		[]u64{4096, 16384},
	)
	defer hugi.packet_destroy(&pz)

	testing.expect(t, store.store_ingest_packet(&st, po), "ingest odin packet")
	testing.expect(t, store.store_ingest_packet(&st, pz), "ingest zig packet")

	rep := store.compare_1v1_langs(&st, "odin", "zig", "cmp001", threshold_pct = 3.0)
	defer store.cross_lang_report_destroy(&rep)

	testing.expect_value(t, len(rep.rows), 2)
	testing.expect_value(t, rep.footprint_mismatches, 1)
	testing.expect_value(t, rep.rows[0].faster_lang, "odin")
	testing.expect_value(t, rep.rows[0].footprint_mismatch, false)
	testing.expect_value(t, rep.rows[1].footprint_mismatch, true)
}

@(test)
test_small_sample_significance_parity :: proc(t: ^testing.T) {
	make_custom_pkt :: proc(lang, run_id: string, batches: [4]u64) -> hugi.Run_Packet {
		pkt := hugi.Run_Packet {
			suite_name     = strings.clone("sm_suite"),
			lang           = strings.clone(lang),
			commit         = strings.clone("sm001"),
			run_id         = strings.clone(run_id),
			os             = strings.clone("linux"),
			arch           = strings.clone("amd64"),
			optimization   = strings.clone("Speed"),
			odin_version   = strings.clone("test"),
			timestamp_unix = 1700000000,
			records        = make([dynamic]hugi.Record, 0, 1),
		}
		samples := make([dynamic]u64, 4)
		for v, i in batches {
			samples[i] = v
		}
		r := hugi.Record {
			rank             = 1,
			group_name       = strings.clone("core"),
			name             = strings.clone("small_op"),
			full_name        = strings.clone("core::small_op"),
			ops_per_sample   = 100,
			samples          = 4,
			samples_batch_ns = samples,
			metrics          = make([dynamic]hugi.Metric),
		}
		hugi.recompute_record_stats_from_samples(&r)
		hugi.refresh_record_throughput(&r)
		append(&pkt.records, r)
		return pkt
	}

	st, ok := store.store_open(":memory:")
	testing.expect(t, ok, "in-memory store should open")
	if !ok {
		return
	}
	defer store.store_close(&st)

	po := make_custom_pkt("odin", "sm-odin-1", [4]u64{10_000, 10_100, 10_200, 10_300})
	defer hugi.packet_destroy(&po)
	pz := make_custom_pkt("zig", "sm-zig-1", [4]u64{20_000, 20_100, 20_200, 500_000})
	defer hugi.packet_destroy(&pz)

	testing.expect(t, store.store_ingest_packet(&st, po), "ingest odin small-sample packet")
	testing.expect(t, store.store_ingest_packet(&st, pz), "ingest zig small-sample packet")

	base_odin := store.store_load_pooled_records(&st, "odin", "sm001")
	defer store.pooled_records_destroy(base_odin)
	cand_zig := store.store_load_pooled_records(&st, "zig", "sm001")
	defer store.pooled_records_destroy(cand_zig)

	cmp_rep := store.compare_records(base_odin, cand_zig, threshold_pct = 5.0)
	defer store.comparison_report_destroy(&cmp_rep)

	lang_rep := store.compare_1v1_langs(&st, "odin", "zig", "sm001", threshold_pct = 5.0)
	defer store.cross_lang_report_destroy(&lang_rep)

	testing.expect_value(t, len(cmp_rep.rows), 1)
	testing.expect_value(t, len(lang_rep.rows), 1)
	if len(cmp_rep.rows) == 1 && len(lang_rep.rows) == 1 {
		testing.expect(
			t,
			cmp_rep.rows[0].p_value < 0.05,
			"expected MWU p < 0.05 for separated n=4",
		)
		testing.expect(
			t,
			math.abs(cmp_rep.rows[0].p_value - lang_rep.rows[0].p_value) < 1e-12,
			"compare_records and compare_1v1_langs must compute identical MWU p-values",
		)
		testing.expect(t, cmp_rep.rows[0].is_significant, "compare_records must be significant")
		testing.expect(
			t,
			lang_rep.rows[0].is_significant,
			"compare_1v1_langs must agree on significance",
		)
	}
}

@(test)
test_exporters_arrow_readme_and_compact :: proc(t: ^testing.T) {
	tmp_dir, t_err := os.temp_directory(context.temp_allocator)
	if t_err != nil || tmp_dir == "" {
		tmp_dir = "/tmp"
	}
	pid := os.get_pid()
	db_path := fmt.aprintf("%s/hugi_test_%d.hugidb", tmp_dir, pid)
	arrow_path := fmt.aprintf("%s/hugi_test_%d.arrow", tmp_dir, pid)
	arrow_raw_path := fmt.aprintf("%s/hugi_test_raw_%d.arrow", tmp_dir, pid)
	parquet_path := fmt.aprintf("%s/hugi_test_%d.parquet", tmp_dir, pid)
	parquet_raw_path := fmt.aprintf("%s/hugi_test_raw_%d.parquet", tmp_dir, pid)
	json_path := fmt.aprintf("%s/hugi_test_%d.json", tmp_dir, pid)
	jsonl_path := fmt.aprintf("%s/hugi_test_%d.jsonl", tmp_dir, pid)
	csv_path := fmt.aprintf("%s/hugi_test_%d.csv", tmp_dir, pid)
	tsv_path := fmt.aprintf("%s/hugi_test_%d.tsv", tmp_dir, pid)
	md_path := fmt.aprintf("%s/hugi_test_%d.md", tmp_dir, pid)
	readme_path := fmt.aprintf("%s/hugi_readme_%d.md", tmp_dir, pid)
	defer {
		for p in ([]string{db_path, arrow_path, arrow_raw_path, parquet_path, parquet_raw_path, json_path, jsonl_path, csv_path, tsv_path, md_path, readme_path}) {
			if os.exists(p) {
				_ = os.remove(p)
			}
			delete(p)
		}
	}

	{
		st, open_ok := store.store_open(db_path)
		testing.expect(t, open_ok, "file store should open")
		p1 := _make_packet(
			"exp001",
			"odin",
			"r-exp-1",
			"suite",
			[]string{"op_a", "op_b"},
			[]f64{80.0, 220.0},
			[]u64{1024, 4096},
		)
		testing.expect(t, store.store_ingest_packet(&st, p1), "ingest for export test")
		hugi.packet_destroy(&p1)

		p2 := _make_packet(
			"exp002",
			"odin",
			"r-exp-2",
			"suite",
			[]string{"op_a"},
			[]f64{75.0},
			[]u64{1024},
			selective = true,
		)
		testing.expect(t, store.store_ingest_packet(&st, p2), "second ingest before compact")
		hugi.packet_destroy(&p2)

		records := store.store_load_pooled_records(&st, "odin")
		testing.expect_value(t, len(records), 2)

		testing.expect(
			t,
			store.export_arrow_ipc(arrow_path, records),
			"arrow export should succeed",
		)
		testing.expect(
			t,
			store.export_arrow_ipc(arrow_raw_path, records, .None),
			"uncompressed arrow export should succeed",
		)
		testing.expect(
			t,
			store.export_parquet(parquet_path, records),
			"parquet export should succeed",
		)
		testing.expect(
			t,
			store.export_parquet(parquet_raw_path, records, false),
			"uncompressed parquet export should succeed",
		)
		testing.expect(t, store.export_json(json_path, records), "json export should succeed")
		testing.expect(t, store.export_jsonl(jsonl_path, records), "jsonl export should succeed")
		testing.expect(t, store.export_csv(csv_path, records), "csv export should succeed")
		testing.expect(t, store.export_tsv(tsv_path, records), "tsv export should succeed")
		testing.expect(
			t,
			store.export_markdown(md_path, records),
			"markdown export should succeed",
		)

		// Verify TSV structure.
		if tsv_bytes, t_err2 := os.read_entire_file(tsv_path, context.allocator); t_err2 == nil {
			defer delete(tsv_bytes)
			tsv_str := string(tsv_bytes)
			testing.expect(
				t,
				strings.contains(tsv_str, "commit\tlang\tsuite_name\tgroup_name"),
				"tsv header uses canonical column names and tabs",
			)
			testing.expect(t, strings.contains(tsv_str, "\tcore::op_a\t"), "tsv contains op_a")
			testing.expect(t, strings.contains(tsv_str, "\tcore::op_b\t"), "tsv contains op_b")
		}

		// Verify JSON structure.
		if json_bytes, j_err := os.read_entire_file(json_path, context.allocator); j_err == nil {
			defer delete(json_bytes)
			parsed, p_err := json.parse(json_bytes, allocator = context.allocator)
			testing.expect_value(t, p_err, json.Error.None)
			if p_err == .None {
				defer json.destroy_value(parsed, context.allocator)
				arr, is_arr := parsed.(json.Array)
				testing.expect(t, is_arr && len(arr) == 2, "json export must be a 2-element array")
			}
		}

		// Verify Parquet magic & footer framing (plus uncompressed & empty exports).
		if pq_bytes, pq_err := os.read_entire_file(parquet_path, context.allocator);
		   pq_err == nil {
			defer delete(pq_bytes)
			n := len(pq_bytes)
			testing.expect(t, n > 16, "parquet file should be non-empty")
			if n > 16 {
				testing.expect_value(t, string(pq_bytes[:4]), "PAR1")
				testing.expect_value(t, string(pq_bytes[n - 4:]), "PAR1")
			}
		}
		if pq_raw_bytes, pq_raw_err := os.read_entire_file(parquet_raw_path, context.allocator);
		   pq_raw_err == nil {
			defer delete(pq_raw_bytes)
			n := len(pq_raw_bytes)
			testing.expect(
				t,
				n > 16 &&
				string(pq_raw_bytes[:4]) == "PAR1" &&
				string(pq_raw_bytes[n - 4:]) == "PAR1",
			)
		}
		testing.expect(
			t,
			store.export_parquet(parquet_raw_path, nil),
			"empty parquet export should succeed",
		)
		if pq_empty_bytes, pq_e_err := os.read_entire_file(parquet_raw_path, context.allocator);
		   pq_e_err == nil {
			defer delete(pq_empty_bytes)
			n := len(pq_empty_bytes)
			testing.expect(
				t,
				n > 12 &&
				string(pq_empty_bytes[:4]) == "PAR1" &&
				string(pq_empty_bytes[n - 4:]) == "PAR1",
			)
		}

		// Verify uncompressed Arrow IPC path too.
		sc_raw, bs_raw, read_raw_ok := skadi.ipc_read_file(
			arrow_raw_path,
			context.allocator,
			true,
			true,
		)
		testing.expect(t, read_raw_ok, "uncompressed arrow file should decode cleanly")
		if read_raw_ok {
			for &b in bs_raw {
				skadi.record_batch_free(&b)
			}
			delete(bs_raw)
			if sc_raw != nil {
				skadi.schema_free(sc_raw)
				free(sc_raw)
			}
		}

		// Verify Arrow IPC file round-trip via Skadi.
		schema, batches, read_ok := skadi.ipc_read_file(arrow_path, context.allocator, true, false)
		testing.expect(t, read_ok, "skadi.ipc_read_file should decode exported Arrow file")
		if read_ok {
			defer {
				for &b in batches {
					skadi.record_batch_free(&b)
				}
				delete(batches)
				if schema != nil {
					skadi.schema_free(schema)
					free(schema)
				}
			}
			testing.expect_value(t, len(batches), 1)
			if len(batches) > 0 && len(records) > 0 {
				testing.expect_value(t, batches[0].length, 2)
				name_col := skadi.record_batch_column(&batches[0], "full_name")
				testing.expect(t, name_col != nil, "full_name column should exist")
				if name_col != nil && batches[0].length > 0 {
					testing.expect_value(
						t,
						skadi.array_get_string(name_col, 0),
						records[0].full_name,
					)
				}
				p50_col := skadi.record_batch_column(&batches[0], "p50_ns")
				testing.expect(t, p50_col != nil, "p50_ns column should exist")
				if p50_col != nil && batches[0].length > 0 {
					testing.expect_value(
						t,
						p50_col.type,
						skadi.DataType(skadi.Decimal64_Type{precision = 18, scale = 6}),
					)
					testing.expect_value(t, skadi.array_get(p50_col, 0, i64), records[0].p50_fs)
				}
				rid_col := skadi.record_batch_column(&batches[0], "run_id")
				testing.expect(t, rid_col != nil, "run_id column should exist")
				if rid_col != nil && batches[0].length > 0 && len(records[0].run_ids) > 0 {
					testing.expect_value(
						t,
						skadi.array_get_string(rid_col, 0),
						records[0].run_ids[len(records[0].run_ids) - 1],
					)
				}
				ts_col := skadi.record_batch_column(&batches[0], "timestamp_unix")
				testing.expect(t, ts_col != nil, "timestamp_unix column should exist")
				if ts_col != nil && batches[0].length > 0 {
					testing.expect_value(
						t,
						skadi.array_get(ts_col, 0, i64),
						records[0].timestamp_unix,
					)
				}
				blob_col := skadi.record_batch_column(&batches[0], "samples_blob")
				testing.expect(t, blob_col != nil, "samples_blob column should exist")
				if blob_col != nil && batches[0].length > 0 {
					raw_blob := skadi.array_get_binary(blob_col, 0)
					back_samples, d_ok := store.decompress_exported_samples_fs(
						raw_blob,
						records[0].ops_per_sample,
					)
					defer delete(back_samples)
					testing.expect(t, d_ok, "Arrow samples_blob should decompress")
					testing.expect_value(t, len(back_samples), len(records[0].samples_fs))
					for si in 0 ..< min(len(back_samples), len(records[0].samples_fs)) {
						testing.expect_value(t, back_samples[si], records[0].samples_fs[si])
					}
				}
			}
		}

		// Verify README marker updater.
		seed_readme := "# Header\n\n<!-- BEGIN_BENCHMARK_TABLE -->\nstale\n<!-- END_BENCHMARK_TABLE -->\n\n# Footer\n"
		testing.expect(
			t,
			os.write_entire_file(readme_path, transmute([]u8)seed_readme) == nil,
			"write seed README",
		)
		md_block := store.format_markdown_table(records)
		defer delete(md_block)
		testing.expect(
			t,
			store.update_readme_markers(readme_path, md_block),
			"update README markers",
		)

		updated_bytes, u_err := os.read_entire_file(readme_path, context.allocator)
		testing.expect(t, u_err == nil, "read updated README")
		if u_err == nil {
			defer delete(updated_bytes)
			updated := string(updated_bytes)
			testing.expect(t, strings.contains(updated, "# Header"), "preserve header")
			testing.expect(t, strings.contains(updated, "core::op_a"), "inject table content")
			testing.expect(t, !strings.contains(updated, "\nstale\n"), "replace stale block")
		}

		store.pooled_records_destroy(records)
		store.store_close(&st)
	}

	before, after, c_ok := store.store_compact(db_path)
	testing.expect(t, c_ok, "store_compact should succeed")
	testing.expect(
		t,
		before > 0 && after > 0 && after < before,
		"compacted store must shrink and stay non-empty",
	)

	st2, open2_ok := store.store_open(db_path)
	testing.expect(t, open2_ok, "reopening compacted store should succeed")
	defer store.store_close(&st2)
	commits := store.store_list_commits(&st2)
	defer store.commit_summaries_destroy(commits)
	testing.expect_value(t, len(commits), 2)

	post_compact := store.store_load_pooled_records(&st2, "odin")
	defer store.pooled_records_destroy(post_compact)
	testing.expect_value(t, len(post_compact), 2)
	if len(post_compact) == 2 {
		testing.expect_value(t, post_compact[0].full_name, "core::op_a")
		testing.expect_value(t, post_compact[0].commit, "exp002")
		testing.expect(
			t,
			math.abs(hugi.fs_to_ns_f64(post_compact[0].p50_fs) - 75.0) < 2.0,
			"op_a median ~75ns",
		)
		testing.expect_value(t, post_compact[1].full_name, "core::op_b")
		testing.expect_value(t, post_compact[1].commit, "exp001")
		testing.expect(
			t,
			math.abs(hugi.fs_to_ns_f64(post_compact[1].p50_fs) - 220.0) < 2.0,
			"op_b median ~220ns",
		)
	}
}

@(private = "file")
_zero_alloc_sum :: proc(b: ^hugi.Bencher) {
	data := [8]u64{1, 2, 3, 4, 5, 6, 7, 8}
	hugi.expect_zero_allocs(b)
	for hugi.step(b) {
		acc := u64(0)
		for v in data {
			acc += v
		}
		_ = hugi.black_box(acc)
	}
}

@(private = "file")
_clean_pipeline :: proc(p: ^hugi.Pipeline) {
	vals := make([]u64, 16)
	defer delete(vals)

	{
		ph := hugi.scoped_phase(p, "fill", ops = 16, bytes_per_op = 8)
		for i in 0 ..< 16 {
			vals[i] = u64(i * 3)
		}
		hugi.phase_set_footprint(ph, u64(len(vals) * size_of(u64)))
	}
	{
		ph := hugi.scoped_phase(p, "sum", ops = 16, bytes_per_op = 8, zero_alloc = true)
		acc := u64(0)
		for v in vals {
			acc += v
		}
		_ = hugi.black_box(acc)
		hugi.phase_metric(ph, 100.0, "hit%")
	}
	{
		_ = hugi.scoped_phase(p, "verify", ops = 16, zero_alloc = true)
		_ = hugi.black_box(vals[0] + vals[15])
	}
}

@(private = "file")
_violating_pipeline :: proc(p: ^hugi.Pipeline) {
	ph := hugi.scoped_phase(p, "leaking_phase", ops = 1, zero_alloc = true)
	buf := make([]u8, 64)
	_ = hugi.black_box(buf[0])
	delete(buf)
	_ = ph
}

@(test)
test_suite_pipeline_and_untimed_zero_alloc :: proc(t: ^testing.T) {
	cfg := hugi.default_suite_config()
	cfg.quiet = true
	cfg.runs = 5
	cfg.warmup = 1
	cfg.obench_cfg.sample_count = 15
	cfg.obench_cfg.warmup_time = 0
	cfg.obench_cfg.fixed_batch_size = 16

	suite := hugi.suite_create("pipeline_test", cfg)
	defer hugi.suite_destroy(&suite)

	hugi.bench(&suite, "sum_zero_alloc", _zero_alloc_sum, zero_alloc = true)
	hugi.group_pipeline(&suite, "kv_pipe", _clean_pipeline)

	ok := hugi.suite_execute(&suite)
	testing.expect(t, ok, "clean suite with @zero_alloc and phases should pass")
	testing.expect_value(t, suite.failed_zero_alloc, 0)
	testing.expect_value(t, len(suite.last_packet.records), 4)
	testing.expect_value(t, suite.last_packet.records[1].footprint_bytes, u64(16 * size_of(u64)))
	testing.expect_value(t, len(suite.last_packet.records[2].metrics), 1)
	testing.expect_value(t, suite.last_packet.records[2].metrics[0].unit, "hit%")

	cfg2 := hugi.default_suite_config()
	cfg2.quiet = true
	cfg2.runs = 4
	cfg2.warmup = 1
	suite2 := hugi.suite_create("violation_test", cfg2)
	defer hugi.suite_destroy(&suite2)

	hugi.group_pipeline(&suite2, "bad_pipe", _violating_pipeline)
	ok2 := hugi.suite_execute(&suite2)
	testing.expect(t, !ok2, "zero_alloc pipeline allocating heap memory must fail")
	testing.expect(t, suite2.failed_zero_alloc > 0, "failed_zero_alloc must be recorded")
	testing.expect_value(t, len(suite2.last_packet.records), 1)
	testing.expect_value(t, len(suite2.last_packet.records[0].samples_batch_ns), 4)
}

@(test)
test_exported_samples_fs_bu_only :: proc(t: ^testing.T) {
	// 1. flags=0 batch_ns blob scaled accurately to per-op femtoseconds.
	batches := []u64{10_000, 10_050, 10_100, 0}
	u_blob, u_ok := store.compress_samples_u64(batches, context.allocator)
	testing.expect(t, u_ok, "u64 export blob compress should succeed")
	if u_ok {
		defer delete(u_blob)
		fs_out, f_ok := store.decompress_exported_samples_fs(u_blob, ops_per_sample = 100)
		testing.expect(t, f_ok, "BU flags=0 exported samples should decode")
		if f_ok {
			defer delete(fs_out)
			testing.expect_value(t, len(fs_out), 4)
			testing.expect_value(t, fs_out[0], i64(100_000_000))
			testing.expect_value(t, fs_out[1], i64(100_500_000))
			testing.expect_value(t, fs_out[2], i64(101_000_000))
			testing.expect_value(t, fs_out[3], i64(0))
		}
	}

	// 2. flags=1 signed femtosecond blob round-trips bit-exactly.
	fs_vals := []i64{-5_000, 0, 1, 5_000, 41_732_000_000}
	fs_blob, fs_ok := store.compress_samples_fs_i64(fs_vals, context.allocator)
	testing.expect(t, fs_ok, "fs i64 export blob compress should succeed")
	if fs_ok {
		defer delete(fs_blob)
		fs_back, bd_ok := store.decompress_exported_samples_fs(fs_blob, ops_per_sample = 999)
		testing.expect(t, bd_ok, "BU flags=1 exported samples should decode")
		if bd_ok {
			defer delete(fs_back)
			testing.expect_value(t, len(fs_back), len(fs_vals))
			for v, i in fs_vals {
				testing.expect_value(t, fs_back[i], v)
			}
		}
	}

	// 3. Legacy BF float blobs and truncated headers must be rejected cleanly.
	legacy_bf := [12]u8{'B', 'F', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	bf_out, bf_ok := store.decompress_exported_samples_fs(legacy_bf[:])
	testing.expect(t, !bf_ok, "legacy BF header must be rejected")
	testing.expect(t, bf_out == nil, "rejected BF decode must not leak")

	short_blob := [4]u8{'B', 'U', 0, 0}
	s_out, s_ok := store.decompress_exported_samples_fs(short_blob[:])
	testing.expect(t, !s_ok, "truncated BU header must be rejected")
	testing.expect(t, s_out == nil, "rejected short decode must not leak")
}

@(private = "file")
_make_store_test_packet :: proc(run_id, commit: string, base_ns: f64) -> hugi.Run_Packet {
	pkt := hugi.Run_Packet {
		run_id         = strings.clone(run_id, context.allocator),
		commit         = strings.clone(commit, context.allocator),
		timestamp_unix = 1770000000,
		lang           = strings.clone("odin", context.allocator),
		suite_name     = strings.clone("kv_bench", context.allocator),
		os             = strings.clone("linux", context.allocator),
		arch           = strings.clone("amd64", context.allocator),
		optimization   = strings.clone("-o:speed", context.allocator),
		odin_version   = strings.clone("dev-2026", context.allocator),
		records        = make([dynamic]hugi.Record, context.allocator),
	}

	r1 := hugi.Record {
		rank             = 1,
		name             = strings.clone("get", context.allocator),
		group_name       = strings.clone("core", context.allocator),
		full_name        = strings.clone("core::get", context.allocator),
		ops_per_sample   = 100,
		bytes_per_op     = 32,
		items_per_op     = 2,
		footprint_bytes  = 512,
		peak_heap_bytes  = 1024,
		samples_batch_ns = make([dynamic]u64, context.allocator),
		metrics          = make([dynamic]hugi.Metric, context.allocator),
	}
	append(
		&r1.samples_batch_ns,
		hugi.ns_f64_to_batch_ns(base_ns, 100),
		hugi.ns_f64_to_batch_ns(base_ns + 0.4, 100),
		hugi.ns_f64_to_batch_ns(base_ns - 0.2, 100),
		hugi.ns_f64_to_batch_ns(base_ns + 0.1, 100),
		hugi.ns_f64_to_batch_ns(base_ns + 0.5, 100),
	)
	hugi.recompute_record_stats_from_samples(&r1)
	if r1.p50_fs > 0 {
		ops_s := hugi.FS_PER_SEC_F64 / f64(r1.p50_fs)
		r1.items_per_sec = f64(r1.items_per_op) * ops_s
		r1.mb_per_sec = (f64(r1.bytes_per_op) * ops_s) / (1024.0 * 1024.0)
	}
	append(&pkt.records, r1)

	r2 := hugi.Record {
		rank             = 10,
		name             = strings.clone("put", context.allocator),
		group_name       = strings.clone("core", context.allocator),
		full_name        = strings.clone("special_put", context.allocator),
		param            = 64,
		has_param        = true,
		threads          = 2,
		has_threads      = true,
		ops_per_sample   = 10,
		samples_batch_ns = make([dynamic]u64, context.allocator),
		metrics          = make([dynamic]hugi.Metric, context.allocator),
	}
	append(
		&r2.samples_batch_ns,
		hugi.ns_f64_to_batch_ns(base_ns * 2.0, 10),
		hugi.ns_f64_to_batch_ns(base_ns * 2.0 + 1.0, 10),
		hugi.ns_f64_to_batch_ns(base_ns * 2.0 - 0.5, 10),
	)
	hugi.recompute_record_stats_from_samples(&r2)
	if r2.p50_fs > 0 {
		r2.items_per_sec = hugi.FS_PER_SEC_F64 / f64(r2.p50_fs)
	}
	append(&r2.metrics, hugi.Metric{unit = strings.clone("%", context.allocator), value = 99.5})
	append(&pkt.records, r2)

	r3 := hugi.Record {
		rank              = 3,
		name              = strings.clone("scan", context.allocator),
		group_name        = strings.clone("core", context.allocator),
		full_name         = strings.clone("scan", context.allocator),
		zero_alloc_failed = true,
		error             = strings.clone("timeout", context.allocator),
		samples_batch_ns  = make([dynamic]u64, context.allocator),
		metrics           = make([dynamic]hugi.Metric, context.allocator),
	}
	append(&pkt.records, r3)

	return pkt
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
test_rational_batch_u64_and_femtosecond_decimal_precision :: proc(t: ^testing.T) {
	// 1. u64 batch codec round-trip across empty, clustered ticks, and large wrapping deltas.
	emp_blob, emp_ok := store.compress_samples_u64([]u64{}, context.allocator)
	testing.expect(t, emp_ok, "empty u64 compress should succeed")
	if emp_ok {
		defer delete(emp_blob)
		emp_back, emp_dok := store.decompress_samples_u64(emp_blob, context.allocator)
		testing.expect(t, emp_dok, "empty u64 decode should succeed")
		if emp_dok {
			defer delete(emp_back)
			testing.expect_value(t, len(emp_back), 0)
		}
	}

	clustered := []u64 {
		41_732_000,
		41_732_030,
		41_731_990,
		41_732_000,
		41_732_010,
		41_731_970,
		0,
		max(u64),
		12345,
	}
	c_blob, c_ok := store.compress_samples_u64(clustered, context.allocator)
	testing.expect(t, c_ok, "clustered/wrapping u64 compress should succeed")
	if c_ok {
		defer delete(c_blob)
		c_back, c_dok := store.decompress_samples_u64(c_blob, context.allocator)
		testing.expect(t, c_dok, "clustered/wrapping u64 decode should succeed")
		if c_dok {
			defer delete(c_back)
			testing.expect_value(t, len(c_back), len(clustered))
			for v, i in clustered {
				testing.expect_value(t, c_back[i], v)
			}
		}
	}

	// 2. Signed femtosecond sample codec round-trip (`compress_samples_fs_i64`).
	fs_vals := []i64{-123_456_789, -1, 0, 1, 5_000, 41_732_000_000}
	fs_blob, f_ok := store.compress_samples_fs_i64(fs_vals, context.allocator)
	testing.expect(t, f_ok, "fs i64 compress should succeed")
	if f_ok {
		defer delete(fs_blob)
		fs_back, f_dok := store.decompress_samples_fs_i64(fs_blob, context.allocator)
		testing.expect(t, f_dok, "fs i64 decode should succeed")
		if f_dok {
			defer delete(fs_back)
			testing.expect_value(t, len(fs_back), len(fs_vals))
			for v, i in fs_vals {
				testing.expect_value(t, fs_back[i], v)
			}
		}
	}

	// 3. Exact sub-picosecond SIMD and clamped zero formatting + CZPK\x04 / CZCH\x02 round-trip.
	sb := strings.builder_make(context.temp_allocator)
	hugi.write_decimal_ns_fs(&sb, 5_000)
	testing.expect_value(t, strings.to_string(sb), "0.005000")
	ps_str := hugi.format_duration_fs(5_000, context.allocator)
	defer delete(ps_str)
	testing.expect_value(t, ps_str, "5.00 ps")

	if !os.exists(".tmp") {
		_ = os.make_directory(".tmp")
	}
	db_path := ".tmp/hugi_test_rational.hugidb"
	csv_path := ".tmp/hugi_test_rational.csv"
	json_path := ".tmp/hugi_test_rational.json"
	for p in ([3]string{db_path, csv_path, json_path}) {
		if os.exists(p) {
			_ = os.remove(p)
		}
	}
	defer for p in ([3]string{db_path, csv_path, json_path}) {
		if os.exists(p) {
			_ = os.remove(p)
		}
	}

	make_simd_pkt := proc(run_id, commit: string) -> hugi.Run_Packet {
		pkt := hugi.Run_Packet {
			run_id         = strings.clone(run_id),
			commit         = strings.clone(commit),
			timestamp_unix = 1770000100,
			lang           = strings.clone("odin"),
			suite_name     = strings.clone("simd_suite"),
			os             = strings.clone("linux"),
			arch           = strings.clone("amd64"),
			optimization   = strings.clone("-o:speed"),
			odin_version   = strings.clone("dev"),
			records        = make([dynamic]hugi.Record),
		}

		r_simd := hugi.Record {
			rank             = 1,
			group_name       = strings.clone("simd"),
			name             = strings.clone("dot8"),
			full_name        = strings.clone("simd::dot8"),
			ops_per_sample   = 10_000_000,
			samples_batch_ns = make([dynamic]u64),
			metrics          = make([dynamic]hugi.Metric),
		}
		append(&r_simd.samples_batch_ns, 50_000, 50_000, 50_010)
		hugi.recompute_record_stats_from_samples(&r_simd)
		append(&pkt.records, r_simd)

		r_zero := hugi.Record {
			rank             = 2,
			group_name       = strings.clone("simd"),
			name             = strings.clone("clamped_zero"),
			full_name        = strings.clone("simd::clamped_zero"),
			ops_per_sample   = 1_000_000,
			samples_batch_ns = make([dynamic]u64),
			metrics          = make([dynamic]hugi.Metric),
		}
		append(&r_zero.samples_batch_ns, 0, 0, 1)
		hugi.recompute_record_stats_from_samples(&r_zero)
		append(&pkt.records, r_zero)
		return pkt
	}

	{
		st, ok := store.store_open(db_path)
		testing.expect(t, ok, "open rational store")
		if !ok {
			return
		}
		defer store.store_close(&st)

		p1 := make_simd_pkt("rr-1", "rc01")
		defer hugi.packet_destroy(&p1)
		p2 := make_simd_pkt("rr-2", "rc02")
		defer hugi.packet_destroy(&p2)
		p3 := make_simd_pkt("rr-3", "rc02")
		defer hugi.packet_destroy(&p3)
		testing.expect_value(t, p1.records[0].p50_fs, i64(5_000))
		testing.expect_value(t, p1.records[1].min_fs, i64(0))
		testing.expect_value(t, p1.records[1].p50_fs, i64(0))
		testing.expect_value(t, p1.records[1].max_fs, i64(1))

		testing.expect(t, store.store_ingest_packet(&st, p1), "ingest rational p1")
		testing.expect(t, store.store_ingest_packet(&st, p2), "ingest rational p2")
		testing.expect(t, store.store_ingest_packet(&st, p3), "ingest rational p3")
	}

	_, _, c_ok2 := store.store_compact(db_path)
	testing.expect(t, c_ok2, "compact rational store into CZCHv2")

	st_back, ok_back := store.store_open(db_path)
	testing.expect(t, ok_back, "reopen compacted rational store")
	if !ok_back {
		return
	}
	defer store.store_close(&st_back)

	all_pkts := store.store_load_all_packets(&st_back)
	defer {
		for &p in all_pkts {
			hugi.packet_destroy(&p)
		}
		delete(all_pkts)
	}
	testing.expect_value(t, len(all_pkts), 3)
	if len(all_pkts) == 3 && len(all_pkts[0].records) == 2 {
		rs := all_pkts[0].records[0]
		rz := all_pkts[0].records[1]
		testing.expect_value(t, rs.p50_fs, i64(5_000))
		testing.expect_value(t, len(rs.samples_batch_ns), 3)
		testing.expect_value(t, rs.samples_batch_ns[0], u64(50_000))
		testing.expect_value(t, rs.samples_batch_ns[2], u64(50_010))
		testing.expect_value(t, rz.min_fs, i64(0))
		testing.expect_value(t, rz.p50_fs, i64(0))
		testing.expect_value(t, rz.max_fs, i64(1))
		testing.expect_value(t, rz.samples_batch_ns[0], u64(0))
		testing.expect_value(t, rz.samples_batch_ns[2], u64(1))
	}

	pooled := store.store_load_pooled_records(&st_back, "odin")
	defer store.pooled_records_destroy(pooled)
	testing.expect_value(t, len(pooled), 2)
	if len(pooled) == 2 {
		testing.expect_value(t, pooled[0].p50_fs, i64(5_000))
		testing.expect_value(t, len(pooled[0].samples_batch_ns), 6)
		testing.expect_value(t, pooled[1].min_fs, i64(0))
		testing.expect_value(t, pooled[1].max_fs, i64(1))
	}

	testing.expect(t, store.export_csv(csv_path, pooled), "export rational csv")
	testing.expect(t, store.export_json(json_path, pooled), "export rational json")
	if csv_bytes, err := os.read_entire_file(csv_path, context.allocator); err == nil {
		defer delete(csv_bytes)
		testing.expect(
			t,
			strings.contains(string(csv_bytes), ",0.005000,"),
			"csv must format 5000 fs as exact 0.005000",
		)
	}
	if json_bytes, err := os.read_entire_file(json_path, context.allocator); err == nil {
		defer delete(json_bytes)
		testing.expect(
			t,
			strings.contains(string(json_bytes), `"samples_batch_ns": [50000,`),
			"json must include raw samples_batch_ns",
		)
		testing.expect(
			t,
			strings.contains(string(json_bytes), `"p50_ns": 0.005000`),
			"json must format DECIMAL(18, 6) p50_ns cleanly",
		)
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

@(private = "file")
_extract_parquet_leaf_columns :: proc(
	pq_bytes: []u8,
	allocator := context.allocator,
) -> (
	cols: []string,
	ok: bool,
) {
	n := len(pq_bytes)
	if n < 12 || string(pq_bytes[:4]) != "PAR1" || string(pq_bytes[n - 4:]) != "PAR1" {
		return nil, false
	}
	flen_bytes: [4]u8
	copy(flen_bytes[:], pq_bytes[n - 8:n - 4])
	flen := int(u32(transmute(u32le)flen_bytes))
	if flen <= 0 || flen > n - 12 {
		return nil, false
	}
	footer := pq_bytes[n - 8 - flen:n - 8]
	pos := 0

	read_u8 :: proc(data: []u8, pos: ^int) -> (u8, bool) {
		if pos^ >= len(data) {
			return 0, false
		}
		v := data[pos^]
		pos^ += 1
		return v, true
	}
	read_varint :: proc(data: []u8, pos: ^int) -> (val: u64, ok: bool) {
		shift: uint = 0
		for shift < 64 {
			b := read_u8(data, pos) or_return
			val |= u64(b & 0x7F) << shift
			if (b & 0x80) == 0 {
				return val, true
			}
			shift += 7
		}
		return 0, false
	}
	read_field_hdr :: proc(
		data: []u8,
		pos: ^int,
		prev: ^i32,
	) -> (
		fid: i32,
		ftype: u8,
		stop: bool,
		ok: bool,
	) {
		b := read_u8(data, pos) or_return
		if b == 0 {
			return 0, 0, true, true
		}
		delta := i32((b >> 4) & 0x0F)
		ftype = b & 0x0F
		if delta == 0 {
			zz := u16(read_varint(data, pos) or_return)
			fid = i32(i16((zz >> 1) ~ u16(-i16(zz & 1))))
		} else {
			fid = prev^ + delta
		}
		prev^ = fid
		return fid, ftype, false, true
	}

	fprev: i32 = 0
	for {
		fid, ftype, stop, h_ok := read_field_hdr(footer, &pos, &fprev)
		if !h_ok {
			return nil, false
		}
		if stop {
			break
		}
		if fid == 2 && ftype == 9 {
			lh := read_u8(footer, &pos) or_return
			cnt := int(lh >> 4)
			elem_type := lh & 0x0F
			if cnt == 15 {
				c64 := read_varint(footer, &pos) or_return
				cnt = int(c64)
			}
			if elem_type != 12 || cnt < 1 {
				return nil, false
			}
			out := make([dynamic]string, 0, cnt - 1, allocator)
			defer if !ok {
				for s in out {
					delete(s, allocator)
				}
				delete(out)
			}
			for elem_idx in 0 ..< cnt {
				sprev: i32 = 0
				elem_name := ""
				for {
					sfid, sftype, sstop, sh_ok := read_field_hdr(footer, &pos, &sprev)
					if !sh_ok {
						return nil, false
					}
					if sstop {
						break
					}
					switch sftype {
					case 5, 6:
						_ = read_varint(footer, &pos) or_return
					case 8:
						slen := int(read_varint(footer, &pos) or_return)
						if slen < 0 || pos + slen > len(footer) {
							return nil, false
						}
						if sfid == 4 {
							elem_name = string(footer[pos:pos + slen])
						}
						pos += slen
					case:
						return nil, false
					}
				}
				if elem_idx > 0 {
					append(&out, strings.clone(elem_name, allocator))
				}
			}
			ok = true
			return out[:], true
		}
		if ftype == 5 || ftype == 6 {
			_ = read_varint(footer, &pos) or_return
		} else {
			break
		}
	}
	return nil, false
}

@(private = "file")
_extract_first_json_object_keys :: proc(text: string, allocator := context.allocator) -> []string {
	keys := make([dynamic]string, allocator)
	obj_start := strings.index_byte(text, '{')
	if obj_start < 0 {
		return keys[:]
	}
	brace_depth := 0
	bracket_depth := 0
	i := obj_start
	for i < len(text) {
		ch := text[i]
		switch ch {
		case '{':
			brace_depth += 1
			i += 1
		case '}':
			brace_depth -= 1
			i += 1
			if brace_depth == 0 {
				return keys[:]
			}
		case '[':
			bracket_depth += 1
			i += 1
		case ']':
			bracket_depth -= 1
			i += 1
		case '"':
			j := i + 1
			for j < len(text) {
				if text[j] == '\\' {
					j += 2
					continue
				}
				if text[j] == '"' {
					break
				}
				j += 1
			}
			str_val := text[i + 1:min(j, len(text))]
			i = j + 1
			if brace_depth == 1 && bracket_depth == 0 {
				k := i
				for k < len(text) && (text[k] == ' ' || text[k] == '\t') {
					k += 1
				}
				if k < len(text) && text[k] == ':' {
					append(&keys, strings.clone(str_val, allocator))
				}
			}
		case:
			i += 1
		}
	}
	return keys[:]
}

@(test)
test_export_schema_parity_all_formats :: proc(t: ^testing.T) {
	if !os.exists(".tmp") {
		_ = os.make_directory(".tmp")
	}
	pid := os.get_pid()
	arrow_path := fmt.aprintf(".tmp/schema_parity_%d.arrow", pid)
	parquet_path := fmt.aprintf(".tmp/schema_parity_%d.parquet", pid)
	csv_path := fmt.aprintf(".tmp/schema_parity_%d.csv", pid)
	tsv_path := fmt.aprintf(".tmp/schema_parity_%d.tsv", pid)
	json_path := fmt.aprintf(".tmp/schema_parity_%d.json", pid)
	jsonl_path := fmt.aprintf(".tmp/schema_parity_%d.jsonl", pid)
	defer {
		for p in ([]string{arrow_path, parquet_path, csv_path, tsv_path, json_path, jsonl_path}) {
			if os.exists(p) {
				_ = os.remove(p)
			}
			delete(p)
		}
	}

	st, ok := store.store_open(":memory:")
	testing.expect(t, ok, "open in-memory store for schema parity")
	if !ok {
		return
	}
	defer store.store_close(&st)

	pkt := _make_packet(
		"par001",
		"odin",
		"run-par-1",
		"parity_suite",
		[]string{"alpha", "beta"},
		[]f64{80.0, 210.0},
		[]u64{1024, 4096},
	)
	pkt.records[0].temp_allocs_per_op = 1.5
	pkt.records[0].temp_bytes_per_op = 48.0
	pkt.records[0].peak_heap_bytes = 2048
	defer hugi.packet_destroy(&pkt)
	testing.expect(t, store.store_ingest_packet(&st, pkt), "ingest parity packet")

	records := store.store_load_pooled_records(&st, "odin")
	defer store.pooled_records_destroy(records)
	testing.expect_value(t, len(records), 2)

	testing.expect(t, store.export_arrow_ipc(arrow_path, records), "arrow parity export")
	testing.expect(t, store.export_parquet(parquet_path, records), "parquet parity export")
	testing.expect(t, store.export_csv(csv_path, records), "csv parity export")
	testing.expect(t, store.export_tsv(tsv_path, records), "tsv parity export")
	testing.expect(t, store.export_json(json_path, records), "json parity export")
	testing.expect(t, store.export_jsonl(jsonl_path, records), "jsonl parity export")

	// 1. Arrow IPC: exact 35 columns (34 canonical scalar + samples_blob).
	sc, bs, arrow_ok := skadi.ipc_read_file(arrow_path, context.allocator, true, false)
	testing.expect(t, arrow_ok, "read parity arrow")
	if arrow_ok {
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
		testing.expect_value(t, len(sc.fields), store.EXPORT_TOTAL_COL_COUNT)
		for i in 0 ..< min(len(sc.fields), store.EXPORT_TOTAL_COL_COUNT) {
			testing.expect_value(t, sc.fields[i].name, store.EXPORT_COLUMNS[i].name)
		}
	}

	// 2. Parquet: exact 35 columns (34 canonical scalar + samples_blob).
	if pq_bytes, pq_err := os.read_entire_file(parquet_path, context.allocator); pq_err == nil {
		defer delete(pq_bytes)
		pq_cols, pq_ok := _extract_parquet_leaf_columns(pq_bytes, context.allocator)
		testing.expect(t, pq_ok, "parse parquet schema leaves")
		if pq_ok {
			defer {
				for c in pq_cols {
					delete(c)
				}
				delete(pq_cols)
			}
			testing.expect_value(t, len(pq_cols), store.EXPORT_TOTAL_COL_COUNT)
			for i in 0 ..< min(len(pq_cols), store.EXPORT_TOTAL_COL_COUNT) {
				testing.expect_value(t, pq_cols[i], store.EXPORT_COLUMNS[i].name)
			}
		}
	}

	// 3. CSV and TSV: exact 34 canonical scalar columns in canonical order.
	verify_delimited :: proc(
		t: ^testing.T,
		path: string,
		delim: string,
		label: string,
		loc := #caller_location,
	) {
		raw, err := os.read_entire_file(path, context.allocator)
		testing.expectf(t, err == nil, "%s read", label, loc = loc)
		if err != nil {
			return
		}
		defer delete(raw)
		lines := strings.split_lines(string(raw), context.temp_allocator)
		testing.expectf(t, len(lines) >= 3, "%s lines >= 3", label, loc = loc)
		if len(lines) < 3 {
			return
		}
		hdr := strings.split(lines[0], delim, context.temp_allocator)
		testing.expect_value(t, len(hdr), store.EXPORT_SCALAR_COL_COUNT, loc = loc)
		for i in 0 ..< min(len(hdr), store.EXPORT_SCALAR_COL_COUNT) {
			testing.expect_value(t, hdr[i], store.EXPORT_COLUMNS[i].name, loc = loc)
		}
		row1 := strings.split(lines[1], delim, context.temp_allocator)
		testing.expect_value(t, len(row1), store.EXPORT_SCALAR_COL_COUNT, loc = loc)
	}
	verify_delimited(t, csv_path, ",", "csv")
	verify_delimited(t, tsv_path, "\t", "tsv")

	// 4. JSON and JSONL: exact 34 canonical scalar keys in order + samples_batch_ns + samples_ns.
	verify_json_keys :: proc(t: ^testing.T, path: string, label: string, loc := #caller_location) {
		raw, err := os.read_entire_file(path, context.allocator)
		testing.expectf(t, err == nil, "%s read", label, loc = loc)
		if err != nil {
			return
		}
		defer delete(raw)
		keys := _extract_first_json_object_keys(string(raw), context.allocator)
		defer {
			for k in keys {
				delete(k)
			}
			delete(keys)
		}
		testing.expect_value(t, len(keys), store.EXPORT_SCALAR_COL_COUNT + 2, loc = loc)
		for i in 0 ..< min(len(keys), store.EXPORT_SCALAR_COL_COUNT) {
			testing.expect_value(t, keys[i], store.EXPORT_COLUMNS[i].name, loc = loc)
		}
		if len(keys) == store.EXPORT_SCALAR_COL_COUNT + 2 {
			testing.expect_value(
				t,
				keys[store.EXPORT_SCALAR_COL_COUNT],
				"samples_batch_ns",
				loc = loc,
			)
			testing.expect_value(
				t,
				keys[store.EXPORT_SCALAR_COL_COUNT + 1],
				"samples_ns",
				loc = loc,
			)
		}
	}
	verify_json_keys(t, json_path, "json")
	verify_json_keys(t, jsonl_path, "jsonl")
}
