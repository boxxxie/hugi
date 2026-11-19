package hugi_tests

import hugi "../hugi"
import store "../store"
import "core:math"
import "core:strings"
import "core:testing"

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
test_compare_records_handles_zero_fs_baselines :: proc(t: ^testing.T) {
	base_arr := make([]store.Pooled_Record, 1)
	base_arr[0] = store.Pooled_Record {
		full_name  = strings.clone("simd::clamped_zero"),
		samples    = 8,
		p50_fs     = 0,
		mean_fs    = 0,
		samples_fs = make([dynamic]i64, 8),
	}
	defer store.pooled_records_destroy(base_arr)

	cand_reg := make([]store.Pooled_Record, 1)
	cand_reg[0] = store.Pooled_Record {
		full_name  = strings.clone("simd::clamped_zero"),
		samples    = 8,
		p50_fs     = 50_000_000,
		mean_fs    = 50_000_000,
		samples_fs = make([dynamic]i64, 8),
	}
	for i in 0 ..< 8 {
		cand_reg[0].samples_fs[i] = 50_000_000 + i64(i) * 1_000
	}
	defer store.pooled_records_destroy(cand_reg)

	rep_reg := store.compare_records(base_arr, cand_reg, threshold_pct = 5.0)
	defer store.comparison_report_destroy(&rep_reg)
	testing.expect_value(t, len(rep_reg.rows), 1)
	testing.expect_value(t, rep_reg.regressions, 1)
	testing.expect_value(t, rep_reg.geomean_delta, 0.0)
	if len(rep_reg.rows) == 1 {
		testing.expect_value(t, rep_reg.rows[0].verdict, store.Verdict.Regression)
		testing.expect(t, rep_reg.rows[0].is_significant, "0 fs -> 50 ns must be significant")
	}

	// Mixing a 0 fs -> 50 ns row with an unchanged positive-median row must not distort geomean_delta.
	base_mix := make([]store.Pooled_Record, 2)
	base_mix[0] = store.Pooled_Record {
		full_name  = strings.clone("simd::clamped_zero"),
		samples    = 8,
		p50_fs     = 0,
		mean_fs    = 0,
		samples_fs = make([dynamic]i64, 8),
	}
	base_mix[1] = store.Pooled_Record {
		full_name  = strings.clone("simd::steady"),
		samples    = 8,
		p50_fs     = 100_000_000,
		mean_fs    = 100_000_000,
		samples_fs = make([dynamic]i64, 8),
	}
	for i in 0 ..< 8 {
		base_mix[1].samples_fs[i] = 100_000_000
	}
	defer store.pooled_records_destroy(base_mix)

	cand_mix := make([]store.Pooled_Record, 2)
	cand_mix[0] = store.Pooled_Record {
		full_name  = strings.clone("simd::clamped_zero"),
		samples    = 8,
		p50_fs     = 50_000_000,
		mean_fs    = 50_000_000,
		samples_fs = make([dynamic]i64, 8),
	}
	cand_mix[1] = store.Pooled_Record {
		full_name  = strings.clone("simd::steady"),
		samples    = 8,
		p50_fs     = 100_000_000,
		mean_fs    = 100_000_000,
		samples_fs = make([dynamic]i64, 8),
	}
	for i in 0 ..< 8 {
		cand_mix[0].samples_fs[i] = 50_000_000 + i64(i) * 1_000
		cand_mix[1].samples_fs[i] = 100_000_000
	}
	defer store.pooled_records_destroy(cand_mix)

	rep_mix := store.compare_records(base_mix, cand_mix, threshold_pct = 5.0)
	defer store.comparison_report_destroy(&rep_mix)
	testing.expect_value(t, len(rep_mix.rows), 2)
	testing.expect_value(t, rep_mix.regressions, 1)
	testing.expect(
		t,
		math.abs(rep_mix.geomean_delta) < 1e-9,
		"asymmetric 0-fs row must not distort geomean_delta",
	)

	// Unmeasured/errored row (p50_fs == 0 and samples == 0) must still be skipped.
	base_err := make([]store.Pooled_Record, 1)
	base_err[0] = store.Pooled_Record {
		full_name  = strings.clone("simd::clamped_zero"),
		samples    = 0,
		p50_fs     = 0,
		mean_fs    = 0,
		samples_fs = make([dynamic]i64, 0),
	}
	defer store.pooled_records_destroy(base_err)

	rep_err := store.compare_records(base_err, cand_reg, threshold_pct = 5.0)
	defer store.comparison_report_destroy(&rep_err)
	testing.expect_value(t, len(rep_err.rows), 0)

	cand_same := make([]store.Pooled_Record, 1)
	cand_same[0] = store.Pooled_Record {
		full_name  = strings.clone("simd::clamped_zero"),
		samples    = 8,
		p50_fs     = 0,
		mean_fs    = 0,
		samples_fs = make([dynamic]i64, 8),
	}
	defer store.pooled_records_destroy(cand_same)

	rep_same := store.compare_records(base_arr, cand_same, threshold_pct = 5.0)
	defer store.comparison_report_destroy(&rep_same)
	testing.expect_value(t, len(rep_same.rows), 1)
	testing.expect_value(t, rep_same.unchanged, 1)
	if len(rep_same.rows) == 1 {
		testing.expect_value(t, rep_same.rows[0].verdict, store.Verdict.Unchanged)
		testing.expect_value(t, rep_same.rows[0].delta_pct, 0.0)
	}
}

@(test)
test_compare_env_mismatch_underpowered_and_1v1_commit_warnings :: proc(t: ^testing.T) {
	make_n3_pkt :: proc(
		lang, commit, run_id, cpu, gov, flags: string,
		smax, cmax: u64,
		vals: [3]u64,
	) -> hugi.Run_Packet {
		pkt := hugi.Run_Packet {
			suite_name = strings.clone("cmp_env"),
			lang = strings.clone(lang),
			commit = strings.clone(commit),
			run_id = strings.clone(run_id),
			os = strings.clone("linux"),
			arch = strings.clone("amd64"),
			optimization = strings.clone("Speed"),
			odin_version = strings.clone("test"),
			timestamp_unix = 1770000000,
			env = hugi.Run_Env {
				cpu_model = strings.clone(cpu),
				governor = strings.clone(gov),
				scaling_max_khz = smax,
				cpuinfo_max_khz = cmax,
				boost_state = 1,
				build_flags = strings.clone(flags),
				runtime_version = strings.clone("test"),
			},
			records = make([dynamic]hugi.Record, 0, 1),
		}
		samples := make([dynamic]u64, 3)
		for v, i in vals {
			samples[i] = v
		}
		r := hugi.Record {
			rank             = 1,
			group_name       = strings.clone("core"),
			name             = strings.clone("op"),
			full_name        = strings.clone("core::op"),
			ops_per_sample   = 100,
			samples          = 3,
			samples_batch_ns = samples,
			metrics          = make([dynamic]hugi.Metric),
		}
		hugi.recompute_record_stats_from_samples(&r)
		hugi.refresh_record_throughput(&r)
		append(&pkt.records, r)
		return pkt
	}

	st, ok := store.store_open(":memory:")
	testing.expect(t, ok, "open in-memory store")
	if !ok {
		return
	}
	defer store.store_close(&st)

	// Base: Ryzen, 4.82 GHz, performance, -o:speed -microarch:native, n=3
	p_base := make_n3_pkt(
		"odin",
		"c_base",
		"r1",
		"AMD Ryzen 7 7735U",
		"performance",
		"-o:speed -microarch:native",
		4_821_140,
		4_821_140,
		[3]u64{10_000, 10_100, 10_200},
	)
	defer hugi.packet_destroy(&p_base)
	// Cand: Intel/clamped/powersave/flags mismatch + high CV + n=3
	p_cand := make_n3_pkt(
		"odin",
		"c_cand",
		"r2",
		"Intel Core i7-7700HQ",
		"powersave",
		"-o:speed",
		2_701_000,
		4_821_140,
		[3]u64{10_000, 20_000, 40_000},
	)
	defer hugi.packet_destroy(&p_cand)
	// Zig at older commit c_base while odin latest is c_cand
	p_zig := make_n3_pkt(
		"zig",
		"c_base",
		"rz1",
		"AMD Ryzen 7 7735U",
		"performance",
		"-Doptimize=ReleaseFast",
		4_821_140,
		4_821_140,
		[3]u64{25_000, 25_100, 25_200},
	)
	defer hugi.packet_destroy(&p_zig)

	testing.expect(t, store.store_ingest_packet(&st, p_base))
	testing.expect(t, store.store_ingest_packet(&st, p_cand))
	testing.expect(t, store.store_ingest_packet(&st, p_zig))

	base_recs := store.store_load_pooled_records(&st, "odin", "c_base")
	defer store.pooled_records_destroy(base_recs)
	cand_recs := store.store_load_pooled_records(&st, "odin", "c_cand")
	defer store.pooled_records_destroy(cand_recs)

	rep := store.compare_records(base_recs, cand_recs, threshold_pct = 5.0)
	defer store.comparison_report_destroy(&rep)
	testing.expect_value(t, rep.underpowered_rows, 1)
	testing.expect_value(t, rep.high_cv_rows, 1)
	testing.expect(t, len(rep.warnings) >= 6, "expected env, underpowered, and high CV warnings")

	md := store.format_comparison_table(rep, "c_base", "c_cand", context.temp_allocator)
	testing.expect(t, strings.contains(md, "WARNING: CPU model mismatch"), "CPU mismatch warning")
	testing.expect(
		t,
		strings.contains(md, "WARNING: CPU scaling_max_freq mismatch"),
		"freq mismatch warning",
	)
	testing.expect(
		t,
		strings.contains(md, "clamped CPU scaling_max_freq"),
		"clamped clock warning",
	)
	testing.expect(t, strings.contains(md, "CPU scaling_governor mismatch"), "governor warning")
	testing.expect(t, strings.contains(md, "Build flags mismatch"), "build flags warning")
	testing.expect(t, strings.contains(md, "< 5 samples per side"), "underpowered warning")
	testing.expect(t, strings.contains(md, "CV > 25%"), "high CV warning")
	testing.expect(t, strings.contains(md, "(n<4)"), "n<4 Welch display in comparison table")

	js := store.format_comparison_json(rep, "c_base", "c_cand", context.temp_allocator)
	testing.expect(t, strings.contains(js, `"underpowered_rows": 1`))
	testing.expect(t, strings.contains(js, `"high_cv_rows": 1`))
	testing.expect(t, strings.contains(js, `"warnings": [`))

	rep1v1 := store.compare_1v1_langs(&st, "odin", "zig", "", threshold_pct = 3.0)
	defer store.cross_lang_report_destroy(&rep1v1)
	md1v1 := store.format_1v1_table(rep1v1, context.temp_allocator)
	testing.expect(
		t,
		strings.contains(
			md1v1,
			"WARNING: Cross-language commit mismatch: odin at c_cand vs zig at c_base",
		),
		"1v1 must warn when latest language snapshots come from different commits",
	)
	js1v1 := store.format_1v1_json(rep1v1, context.temp_allocator)
	testing.expect(t, strings.contains(js1v1, `"a_commit": "c_cand"`))
	testing.expect(t, strings.contains(js1v1, `"b_commit": "c_base"`))
	testing.expect(t, strings.contains(js1v1, `"warnings": [`))
}
