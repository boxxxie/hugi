package hugi_tests

import skadi "../deps/skadi/skadi"
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
			samples[s] = hugi.legacy_ns_to_batch_ns(max(med + offset, 1.0), ops)
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
test_bss_codec_roundtrip_and_ratio :: proc(t: ^testing.T) {
	samples := make([]f64, 128)
	defer delete(samples)
	for i in 0 ..< len(samples) {
		// Realistic nanosecond-quantized latency readings around ~142 ns.
		samples[i] = 142.0 + f64(i % 9) * 0.25 + f64(i / 8) * 0.5
	}

	z_blob, z_ok := store.compress_samples_f64(samples, .Zlib_BSS)
	defer delete(z_blob)
	testing.expect(t, z_ok, "zlib BSS compression should succeed")

	raw_size := len(samples) * size_of(f64)
	testing.expectf(
		t,
		len(z_blob) < raw_size / 2,
		"expected zlib+BSS output (%d B) to be < 50%% of raw (%d B)",
		len(z_blob),
		raw_size,
	)

	z_back, zd_ok := store.decompress_samples_f64(z_blob)
	defer delete(z_back)
	testing.expect(t, zd_ok, "zlib BSS decompression should succeed")
	testing.expect_value(t, len(z_back), len(samples))
	for i in 0 ..< len(samples) {
		testing.expect_value(t, transmute(u64)z_back[i], transmute(u64)samples[i])
	}

	l_blob, l_ok := store.compress_samples_f64(samples, .LZ4_BSS)
	defer delete(l_blob)
	testing.expect(t, l_ok, "lz4 BSS compression should succeed")

	l_back, ld_ok := store.decompress_samples_f64(l_blob)
	defer delete(l_back)
	testing.expect(t, ld_ok, "lz4 BSS decompression should succeed")
	testing.expect_value(t, len(l_back), len(samples))
	for i in 0 ..< len(samples) {
		testing.expect_value(t, transmute(u64)l_back[i], transmute(u64)samples[i])
	}
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
			store.export_arrow_ipc(arrow_raw_path, records, .Zlib_BSS, .None),
			"uncompressed arrow export should succeed",
		)
		testing.expect(
			t,
			store.export_parquet(parquet_path, records),
			"parquet export should succeed",
		)
		testing.expect(
			t,
			store.export_parquet(parquet_raw_path, records, .Zlib_BSS, false),
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
				strings.contains(tsv_str, "commit\tlang\tsuite\tgroup"),
				"tsv header uses tabs",
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
					testing.expect_value(t, skadi.array_get(p50_col, 0, i64), records[0].p50_fs)
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
test_domain_float_codecs_bit_exact :: proc(t: ^testing.T) {
	clustered := []f64 {
		41.732,
		41.745,
		41.719,
		41.738,
		41.738,
		41.751,
		41.702,
		41.744,
		0.0,
		1024.0,
		-12.34,
		-0.005,
		100.125,
	}
	codecs := [2]store.Codec{.Zlib_XOR_BSS, .Zlib_ALP}
	for codec in codecs {
		blob, c_ok := store.compress_samples_f64(clustered, codec, context.allocator)
		testing.expect(t, c_ok, "domain codec compress should succeed")
		if c_ok {
			defer delete(blob)
			back, d_ok := store.decompress_samples_f64(blob, context.allocator)
			testing.expect(t, d_ok, "domain codec decompress should succeed")
			if d_ok {
				defer delete(back)
				testing.expect_value(t, len(back), len(clustered))
				for i in 0 ..< len(clustered) {
					testing.expect_value(t, transmute(u64)back[i], transmute(u64)clustered[i])
				}
			}
		}
	}

	best_blob, b_ok := store.compress_samples_f64_best(clustered, context.allocator)
	testing.expect(t, b_ok, "compress_samples_f64_best should succeed")
	if b_ok {
		defer delete(best_blob)
		best_back, bd_ok := store.decompress_samples_f64(best_blob, context.allocator)
		testing.expect(t, bd_ok, "compress_samples_f64_best round-trip decode")
		if bd_ok {
			defer delete(best_back)
			testing.expect_value(t, len(best_back), len(clustered))
			for i in 0 ..< len(clustered) {
				testing.expect_value(t, transmute(u64)best_back[i], transmute(u64)clustered[i])
			}
		}
	}

	// Edge floats (-0.0, subnormals, NaN, +/-Inf, huge magnitudes) must preserve every bit via fallback.
	edge_vals := []f64 {
		math.copy_sign(0.0, -1.0),
		1e-310,
		1e18,
		math.inf_f64(1),
		math.inf_f64(-1),
		math.nan_f64(),
	}
	edge_blob, e_ok := store.compress_samples_f64_best(edge_vals, context.allocator)
	testing.expect(t, e_ok, "edge float fallback compress should succeed")
	if e_ok {
		defer delete(edge_blob)
		edge_back, ed_ok := store.decompress_samples_f64(edge_blob, context.allocator)
		testing.expect(t, ed_ok, "edge float decompress should succeed")
		if ed_ok {
			defer delete(edge_back)
			testing.expect_value(t, len(edge_back), len(edge_vals))
			for i in 0 ..< len(edge_vals) {
				testing.expect_value(t, transmute(u64)edge_back[i], transmute(u64)edge_vals[i])
			}
		}
	}

	empty_blob, emp_ok := store.compress_samples_f64_best([]f64{}, context.allocator)
	testing.expect(t, emp_ok, "empty samples compress should succeed")
	if emp_ok {
		defer delete(empty_blob)
		empty_back, emp_dok := store.decompress_samples_f64(empty_blob, context.allocator)
		testing.expect(t, emp_dok, "empty samples decode should succeed")
		if emp_dok {
			defer delete(empty_back)
			testing.expect_value(t, len(empty_back), 0)
		}
	}
}

@(private = "file")
_make_v3_test_packet :: proc(run_id, commit: string, base_ns: f64) -> hugi.Run_Packet {
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
		hugi.legacy_ns_to_batch_ns(base_ns, 100),
		hugi.legacy_ns_to_batch_ns(base_ns + 0.4, 100),
		hugi.legacy_ns_to_batch_ns(base_ns - 0.2, 100),
		hugi.legacy_ns_to_batch_ns(base_ns + 0.1, 100),
		hugi.legacy_ns_to_batch_ns(base_ns + 0.5, 100),
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
		hugi.legacy_ns_to_batch_ns(base_ns * 2.0, 10),
		hugi.legacy_ns_to_batch_ns(base_ns * 2.0 + 1.0, 10),
		hugi.legacy_ns_to_batch_ns(base_ns * 2.0 - 0.5, 10),
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
test_v3_symbols_descriptors_cold_rollup_and_hot_append :: proc(t: ^testing.T) {
	if !os.exists(".tmp") {
		_ = os.make_directory(".tmp")
	}
	db_path := ".tmp/hugi_test_v3.hugidb"
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
		testing.expect(t, open_ok, "open v3 store")
		if !open_ok {
			return
		}
		defer store.store_close(&st)

		for i in 0 ..< 6 {
			pkt := _make_v3_test_packet(run_ids[i], commits[i], 40.0 + f64(i) * 5.0)
			defer hugi.packet_destroy(&pkt)
			testing.expect(t, store.store_ingest_packet(&st, pkt), "ingest v3 packet")
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
	testing.expect(t, c_ok, "v3 compact with cold rollup should succeed")
	testing.expect(t, before > 0 && after > 0 && after < before, "v3 compact shrinks store")

	st2, open2_ok := store.store_open(db_path, context.allocator)
	testing.expect(t, open2_ok, "reopen compacted v3 store")
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
			ref := _make_v3_test_packet(
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
	pkt7 := _make_v3_test_packet("r07", "c07", 75.0)
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

	// Re-ingesting an existing cold run_id (r01) must update in-place without duplicating run_order.
	pkt1_dup := _make_v3_test_packet("r01", "c01", 40.0)
	defer hugi.packet_destroy(&pkt1_dup)
	testing.expect(t, store.store_ingest_packet(&st2, pkt1_dup), "re-ingest existing run_id r01")

	runs4 := store.store_list_runs(&st2)
	defer store.run_summaries_destroy(runs4)
	testing.expect_value(t, len(runs4), 7)
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

		p1 := _make_v3_test_packet("base01", "c01", 50.0)
		defer hugi.packet_destroy(&p1)
		p2 := _make_v3_test_packet("base02", "c02", 52.0)
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

		trial := _make_v3_test_packet("trial01", "exp99", 30.0)
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
