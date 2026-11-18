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
		samples := make([dynamic]f64, samples_per_rec)
		for s in 0 ..< samples_per_rec {
			offset := (f64(s) - f64(samples_per_rec - 1) * 0.5) * spread_ns
			samples[s] = max(med + offset, 1.0)
		}

		r := hugi.Record {
			rank               = i + 1,
			group_name         = strings.clone("core"),
			name               = strings.clone(name),
			full_name          = strings.clone(fmt.tprintf("core::%s", name)),
			ops_per_sample     = 100,
			samples            = samples_per_rec,
			bytes_per_op       = 64,
			footprint_bytes    = foot,
			allocs_per_op      = 0,
			alloc_bytes_per_op = 0,
			samples_ns         = samples,
			metrics            = make([dynamic]hugi.Metric),
		}
		hugi.recompute_record_stats_from_samples(&r)
		if r.p50_ns > 0 {
			r.items_per_sec = 1_000_000_000.0 / r.p50_ns
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
	testing.expect_value(t, len(decoded.records[1].samples_ns), 16)
	testing.expect_value(
		t,
		transmute(u64)decoded.records[0].samples_ns[3],
		transmute(u64)pkt.records[0].samples_ns[3],
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
		math.abs(latest[1].p50_ns - 38.0) < 2.0,
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
				blob_col := skadi.record_batch_column(&batches[0], "samples_blob")
				testing.expect(t, blob_col != nil, "samples_blob column should exist")
				if blob_col != nil && batches[0].length > 0 {
					raw_blob := skadi.array_get_binary(blob_col, 0)
					back_samples, d_ok := store.decompress_samples_f64(raw_blob)
					defer delete(back_samples)
					testing.expect(t, d_ok, "Arrow samples_blob should decompress")
					testing.expect_value(t, len(back_samples), len(records[0].samples_ns))
					for si in 0 ..< len(back_samples) {
						testing.expect_value(
							t,
							transmute(u64)back_samples[si],
							transmute(u64)records[0].samples_ns[si],
						)
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
		testing.expect(t, math.abs(post_compact[0].p50_ns - 75.0) < 2.0, "op_a median ~75ns")
		testing.expect_value(t, post_compact[1].full_name, "core::op_b")
		testing.expect_value(t, post_compact[1].commit, "exp001")
		testing.expect(t, math.abs(post_compact[1].p50_ns - 220.0) < 2.0, "op_b median ~220ns")
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
	testing.expect_value(t, len(suite2.last_packet.records[0].samples_ns), 4)
}
