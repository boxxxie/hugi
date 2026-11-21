package hugi_tests

import obench "../deps/obench/obench"
import hugi "../hugi"
import store "../store"
import "core:fmt"
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

@(test)
test_hodges_lehmann_ci_gating_and_ar1_ci95_widening :: proc(t: ^testing.T) {
	// 1. Positively autocorrelated ramp widens ci95_fs compared to alternating permutation
	// (osc has r1 < 0, which obench.effective_sample_count clamps to 0 so eff == n).
	ramp := [12]i64 {
		10_000_000,
		12_000_000,
		14_000_000,
		16_000_000,
		18_000_000,
		20_000_000,
		22_000_000,
		24_000_000,
		26_000_000,
		28_000_000,
		30_000_000,
		32_000_000,
	}
	osc := [12]i64 {
		10_000_000,
		32_000_000,
		12_000_000,
		30_000_000,
		14_000_000,
		28_000_000,
		16_000_000,
		26_000_000,
		18_000_000,
		24_000_000,
		20_000_000,
		22_000_000,
	}
	st_ramp := hugi.compute_stats_fs(ramp[:])
	st_osc := hugi.compute_stats_fs(osc[:])
	testing.expect_value(t, st_ramp.p50_fs, st_osc.p50_fs)
	testing.expect_value(t, st_ramp.std_dev_fs, st_osc.std_dev_fs)

	osc_var_sum := 0.0
	for v in osc {
		d := f64(v - st_osc.mean_fs)
		osc_var_sum += d * d
	}
	osc_std_f := math.sqrt(osc_var_sum / f64(len(osc) - 1))
	expected_unadj_ci95 := i64(
		math.round(
			obench.t_critical_975(f64(len(osc) - 1)) * (osc_std_f / math.sqrt(f64(len(osc)))),
		),
	)
	testing.expect_value(t, st_osc.ci95_fs, expected_unadj_ci95)
	testing.expectf(
		t,
		st_ramp.ci95_fs > st_osc.ci95_fs,
		"expected AR(1) ci95_fs (%d) > clamped r1<0 unadjusted (%d)",
		st_ramp.ci95_fs,
		st_osc.ci95_fs,
	)

	pair := [2]i64{10_000_000, 20_000_000}
	st_pair := hugi.compute_stats_fs(pair[:])
	testing.expect(t, st_pair.ci95_fs > 0, "expected n=2 ci95_fs to remain finite and positive")

	// 2. HL CI gating rejects noisy shifts whose 95% CI straddles threshold_pct.
	make_rec :: proc(name: string, ns_vals: []f64) -> store.Pooled_Record {
		samples := make([dynamic]i64, len(ns_vals))
		for v, i in ns_vals {
			samples[i] = hugi.ns_f64_to_fs(v)
		}
		st := hugi.compute_stats_fs(samples[:])
		return store.Pooled_Record {
			full_name = strings.clone(name),
			samples = len(ns_vals),
			p50_fs = st.p50_fs,
			mean_fs = st.mean_fs,
			std_dev_fs = st.std_dev_fs,
			ci95_fs = st.ci95_fs,
			cv_pct = st.cv_pct,
			modes = 1,
			samples_fs = samples,
		}
	}

	base_noisy := make([]store.Pooled_Record, 1)
	base_noisy[0] = make_rec("core::border", []f64{92, 95, 97, 99, 100, 100, 101, 103, 105, 108})
	defer store.pooled_records_destroy(base_noisy)

	cand_noisy := make([]store.Pooled_Record, 1)
	cand_noisy[0] = make_rec(
		"core::border",
		[]f64{101, 103, 105, 107, 108, 109, 111, 113, 115, 118},
	)
	defer store.pooled_records_destroy(cand_noisy)

	rep_straddle := store.compare_records(base_noisy, cand_noisy, threshold_pct = 5.0)
	defer store.comparison_report_destroy(&rep_straddle)
	testing.expect_value(t, len(rep_straddle.rows), 1)
	if len(rep_straddle.rows) == 1 {
		r := rep_straddle.rows[0]
		testing.expect(t, r.used_shift_ci, "expected HL CI to be used for n=10")
		testing.expect(t, r.delta_pct > 5.0, "expected median delta > 5%")
		testing.expect(t, r.p_value < 0.05, "expected MWU p < 0.05")
		testing.expect(t, r.shift_low_pct < 5.0, "expected HL lower bound below 5%")
		testing.expect(t, !r.is_significant, "straddling HL CI must not be flagged significant")
		testing.expect_value(t, r.verdict, store.Verdict.Unchanged)
	}

	// Clear shift with entire 95% CI above threshold passes gate.
	cand_clear := make([]store.Pooled_Record, 1)
	cand_clear[0] = make_rec(
		"core::border",
		[]f64{114, 115, 116, 117, 118, 119, 120, 121, 122, 123},
	)
	defer store.pooled_records_destroy(cand_clear)

	rep_clear := store.compare_records(base_noisy, cand_clear, threshold_pct = 5.0)
	defer store.comparison_report_destroy(&rep_clear)
	testing.expect_value(t, rep_clear.regressions, 1)
	if len(rep_clear.rows) == 1 {
		testing.expect(t, rep_clear.rows[0].shift_low_pct > 5.0)
		testing.expect_value(t, rep_clear.rows[0].verdict, store.Verdict.Regression)
	}
}

@(test)
test_compare_drift_multimodal_warnings_and_by_run_medians :: proc(t: ^testing.T) {
	make_pkt :: proc(commit, run_id: string, name: string, ns_vals: []f64) -> hugi.Run_Packet {
		pkt := hugi.Run_Packet {
			suite_name     = strings.clone("diag_suite"),
			lang           = strings.clone("odin"),
			commit         = strings.clone(commit),
			run_id         = strings.clone(run_id),
			os             = strings.clone("linux"),
			arch           = strings.clone("amd64"),
			optimization   = strings.clone("Speed"),
			odin_version   = strings.clone("test"),
			timestamp_unix = 1770000000,
			records        = make([dynamic]hugi.Record, 0, 1),
		}
		samples := make([dynamic]u64, len(ns_vals))
		for v, i in ns_vals {
			samples[i] = hugi.ns_f64_to_batch_ns(v, 100)
		}
		r := hugi.Record {
			rank             = 1,
			group_name       = strings.clone("core"),
			name             = strings.clone(name),
			full_name        = strings.concatenate({"core::", name}),
			ops_per_sample   = 100,
			samples          = len(ns_vals),
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

	// 1. Drift & multimodal shape detection.
	p_steady := make_pkt(
		"sh01",
		"r-sh1",
		"drift_op",
		[]f64{100, 100, 100, 100, 100, 100, 100, 100, 100, 100},
	)
	defer hugi.packet_destroy(&p_steady)
	p_drift := make_pkt(
		"sh02",
		"r-sh2",
		"drift_op",
		[]f64{100, 105, 110, 115, 120, 125, 130, 135, 140, 145},
	)
	defer hugi.packet_destroy(&p_drift)

	bimodal := [24]f64 {
		50,
		50.2,
		49.9,
		50.1,
		50.0,
		50.3,
		49.8,
		50.0,
		50.1,
		49.9,
		50.2,
		50.0,
		200,
		200.2,
		199.9,
		200.1,
		200.0,
		200.3,
		199.8,
		200.0,
		200.1,
		199.9,
		200.2,
		200.0,
	}
	p_bimodal_base := make_pkt("sh01", "r-sh1b", "bimodal_op", bimodal[:])
	defer hugi.packet_destroy(&p_bimodal_base)
	p_bimodal_cand := make_pkt("sh02", "r-sh2b", "bimodal_op", bimodal[:])
	defer hugi.packet_destroy(&p_bimodal_cand)

	testing.expect(t, store.store_ingest_packet(&st, p_steady))
	testing.expect(t, store.store_ingest_packet(&st, p_drift))
	testing.expect(t, store.store_ingest_packet(&st, p_bimodal_base))
	testing.expect(t, store.store_ingest_packet(&st, p_bimodal_cand))

	b_recs := store.store_load_pooled_records(&st, "odin", "sh01")
	defer store.pooled_records_destroy(b_recs)
	c_recs := store.store_load_pooled_records(&st, "odin", "sh02")
	defer store.pooled_records_destroy(c_recs)

	rep_shape := store.compare_records(b_recs, c_recs, threshold_pct = 5.0)
	defer store.comparison_report_destroy(&rep_shape)
	testing.expect_value(t, rep_shape.drifting_rows, 1)
	testing.expect_value(t, rep_shape.multimodal_rows, 1)

	md_shape := store.format_comparison_table(rep_shape, "sh01", "sh02", context.temp_allocator)
	testing.expect(t, strings.contains(md_shape, "sample drift over the run"))
	testing.expect(t, strings.contains(md_shape, "multimodal sample distributions"))
	testing.expect(t, strings.contains(md_shape, "HL ["))
	js_shape := store.format_comparison_json(rep_shape, "sh01", "sh02", context.temp_allocator)
	testing.expect(t, strings.contains(js_shape, `"drifting_rows": 1`))
	testing.expect(t, strings.contains(js_shape, `"multimodal_rows": 1`))
	testing.expect(t, strings.contains(js_shape, `"used_shift_ci": true`))

	// Fallback warning when --by-run is enabled with only 1 run per side.
	rep_fallback := store.compare_records(
		b_recs,
		c_recs,
		threshold_pct = 5.0,
		use_run_medians = true,
	)
	defer store.comparison_report_destroy(&rep_fallback)
	md_fb := store.format_comparison_table(rep_fallback, "sh01", "sh02", context.temp_allocator)
	testing.expect(t, strings.contains(md_fb, "fell back to pooled sample comparison"))

	// 2. Multi-run --by-run compares per-run medians across >= 4 runs per side.
	for idx in 0 ..< 4 {
		b_vals := [6]f64 {
			100 + f64(idx),
			100 + f64(idx),
			100 + f64(idx),
			100 + f64(idx),
			100 + f64(idx),
			100 + f64(idx),
		}
		c_vals := [6]f64 {
			140 + f64(idx),
			140 + f64(idx),
			140 + f64(idx),
			140 + f64(idx),
			140 + f64(idx),
			140 + f64(idx),
		}
		pb := make_pkt("run_b", fmt.tprintf("rb-%d", idx), "op", b_vals[:])
		defer hugi.packet_destroy(&pb)
		pc := make_pkt("run_c", fmt.tprintf("rc-%d", idx), "op", c_vals[:])
		defer hugi.packet_destroy(&pc)
		testing.expect(t, store.store_ingest_packet(&st, pb))
		testing.expect(t, store.store_ingest_packet(&st, pc))
	}
	rb := store.store_load_pooled_records(&st, "odin", "run_b")
	defer store.pooled_records_destroy(rb)
	rc := store.store_load_pooled_records(&st, "odin", "run_c")
	defer store.pooled_records_destroy(rc)

	rep_runs := store.compare_records(rb, rc, threshold_pct = 5.0, use_run_medians = true)
	defer store.comparison_report_destroy(&rep_runs)
	testing.expect_value(t, len(rep_runs.rows), 1)
	if len(rep_runs.rows) == 1 {
		r := rep_runs.rows[0]
		testing.expect(t, r.used_run_medians, "expected used_run_medians=true")
		testing.expect(t, r.used_shift_ci, "expected HL CI over 4 run medians")
		testing.expect_value(t, r.base_samples, 4)
		testing.expect_value(t, r.cand_samples, 4)
		testing.expect_value(t, r.verdict, store.Verdict.Regression)
	}
	md_runs := store.format_comparison_table(rep_runs, "run_b", "run_c", context.temp_allocator)
	testing.expect(t, strings.contains(md_runs, " (runs)"))
	js_runs := store.format_comparison_json(rep_runs, "run_b", "run_c", context.temp_allocator)
	testing.expect(t, strings.contains(js_runs, `"used_run_medians": true`))
	csv_runs := store.format_comparison_csv(rep_runs, "run_b", "run_c", context.temp_allocator)
	testing.expect(
		t,
		strings.contains(
			csv_runs,
			",shift_pct,shift_low_pct,shift_high_pct,used_shift_ci,used_run_medians\n",
		),
	)
	testing.expect(t, strings.contains(csv_runs, ",true,true\n"))
}

@(test)
test_compare_1v1_hl_ci_symmetry_and_shape_diagnostics :: proc(t: ^testing.T) {
	add_bench :: proc(pkt: ^hugi.Run_Packet, rank: int, name: string, ns_vals: []f64) {
		samples := make([dynamic]u64, len(ns_vals))
		for v, i in ns_vals {
			samples[i] = hugi.ns_f64_to_batch_ns(v, 100)
		}
		r := hugi.Record {
			rank             = rank,
			group_name       = strings.clone("core"),
			name             = strings.clone(name),
			full_name        = strings.concatenate({"core::", name}),
			ops_per_sample   = 100,
			samples          = len(ns_vals),
			samples_batch_ns = samples,
			metrics          = make([dynamic]hugi.Metric),
		}
		hugi.recompute_record_stats_from_samples(&r)
		hugi.refresh_record_throughput(&r)
		append(&pkt.records, r)
	}
	make_lang_pkt :: proc(lang: string) -> hugi.Run_Packet {
		return hugi.Run_Packet {
			suite_name = strings.clone("suite_1v1"),
			lang = strings.clone(lang),
			commit = strings.clone("c1v1"),
			run_id = strings.concatenate({"r-", lang}),
			os = strings.clone("linux"),
			arch = strings.clone("amd64"),
			optimization = strings.clone("Speed"),
			odin_version = strings.clone("test"),
			timestamp_unix = 1770000000,
			records = make([dynamic]hugi.Record, 0, 5),
		}
	}

	st, ok := store.store_open(":memory:")
	testing.expect(t, ok, "open in-memory store")
	if !ok {
		return
	}
	defer store.store_close(&st)

	straddle_fast := [10]f64{100, 92, 105, 95, 108, 97, 103, 99, 101, 100}
	straddle_slow := [10]f64{108, 101, 115, 103, 118, 105, 113, 107, 111, 109}
	low_series := [10]f64{98, 101, 99, 102, 100, 100, 101, 99, 100, 100}
	high_series := [10]f64{128, 131, 129, 132, 130, 130, 131, 129, 130, 130}
	steady_100 := [10]f64{100, 100, 100, 100, 100, 100, 100, 100, 100, 100}
	drift_ramp := [10]f64{100, 105, 110, 115, 120, 125, 130, 135, 140, 145}
	bimodal := [24]f64 {
		50,
		50.2,
		49.9,
		50.1,
		50.0,
		50.3,
		49.8,
		50.0,
		50.1,
		49.9,
		50.2,
		50.0,
		200,
		200.2,
		199.9,
		200.1,
		200.0,
		200.3,
		199.8,
		200.0,
		200.1,
		199.9,
		200.2,
		200.0,
	}

	po := make_lang_pkt("odin")
	defer hugi.packet_destroy(&po)
	add_bench(&po, 1, "straddle", straddle_fast[:])
	add_bench(&po, 2, "odin_fast", low_series[:])
	add_bench(&po, 3, "zig_fast", high_series[:])
	add_bench(&po, 4, "drift_1v1", steady_100[:])
	add_bench(&po, 5, "bimodal_1v1", steady_100[:])

	pz := make_lang_pkt("zig")
	defer hugi.packet_destroy(&pz)
	add_bench(&pz, 1, "straddle", straddle_slow[:])
	add_bench(&pz, 2, "odin_fast", high_series[:])
	add_bench(&pz, 3, "zig_fast", low_series[:])
	add_bench(&pz, 4, "drift_1v1", drift_ramp[:])
	add_bench(&pz, 5, "bimodal_1v1", bimodal[:])

	testing.expect(t, store.store_ingest_packet(&st, po))
	testing.expect(t, store.store_ingest_packet(&st, pz))

	rep := store.compare_1v1_langs(&st, "odin", "zig", "c1v1", threshold_pct = 5.0)
	defer store.cross_lang_report_destroy(&rep)
	testing.expect_value(t, len(rep.rows), 5)
	testing.expect_value(t, rep.drifting_rows, 1)
	testing.expect_value(t, rep.multimodal_rows, 1)

	found_straddle, found_ofast, found_zfast := false, false, false
	row_ofast, row_zfast: store.Cross_Lang_Row
	for r in rep.rows {
		switch r.full_name {
		case "core::straddle":
			found_straddle = true
			testing.expect(t, r.used_shift_ci, "straddle 1v1 should use HL shift CI")
			testing.expect(t, r.shift_low_pct < 5.0, "straddle HL lower bound should be < 5%")
			testing.expect(t, !r.is_significant, "straddle 1v1 must not be marked significant")
		case "core::odin_fast":
			found_ofast = true
			row_ofast = r
			testing.expect(t, r.used_shift_ci)
			testing.expect_value(t, r.faster_lang, "odin")
			testing.expect(t, r.is_significant)
			testing.expect(t, r.shift_low_pct > 5.0)
		case "core::zig_fast":
			found_zfast = true
			row_zfast = r
			testing.expect(t, r.used_shift_ci)
			testing.expect_value(t, r.faster_lang, "zig")
			testing.expect(t, r.is_significant)
			testing.expect(t, r.shift_low_pct > 5.0)
		}
	}
	testing.expect(t, found_straddle && found_ofast && found_zfast)
	testing.expect(
		t,
		math.abs(row_ofast.shift_pct - row_zfast.shift_pct) < 1e-6,
		"1v1 HL shift_pct must be symmetric between a<b and a>b",
	)
	testing.expect(
		t,
		math.abs(row_ofast.shift_low_pct - row_zfast.shift_low_pct) < 1e-6,
		"1v1 HL shift_low_pct must be symmetric between a<b and a>b",
	)
	testing.expect(
		t,
		math.abs(row_ofast.shift_high_pct - row_zfast.shift_high_pct) < 1e-6,
		"1v1 HL shift_high_pct must be symmetric between a<b and a>b",
	)
	testing.expect(t, row_ofast.welch_t < 0, "a < b must preserve negative welch_t sign")
	testing.expect(t, row_zfast.welch_t > 0, "a > b must preserve positive welch_t sign")
	testing.expect(
		t,
		math.abs(row_ofast.welch_t + row_zfast.welch_t) < 1e-9,
		"1v1 welch_t must be antisymmetric between a<b and a>b",
	)

	js := store.format_1v1_json(rep, context.temp_allocator)
	testing.expect(t, strings.contains(js, `"drifting_rows": 1`))
	testing.expect(t, strings.contains(js, `"multimodal_rows": 1`))
	testing.expect(t, strings.contains(js, `"shift_pct":`))
	testing.expect(t, strings.contains(js, `"shift_low_pct":`))
	testing.expect(t, strings.contains(js, `"shift_high_pct":`))

	// Ties below 0.5% relative diff must stay non-significant even when threshold_pct = 0.0.
	st_tie, ok_tie := store.store_open(":memory:")
	testing.expect(t, ok_tie)
	if ok_tie {
		defer store.store_close(&st_tie)
		tight_a := [10]f64{100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0}
		tight_b := [10]f64{100.4, 100.4, 100.4, 100.4, 100.4, 100.4, 100.4, 100.4, 100.4, 100.4}
		pta := make_lang_pkt("odin")
		defer hugi.packet_destroy(&pta)
		add_bench(&pta, 1, "tight_tie", tight_a[:])
		ptb := make_lang_pkt("zig")
		defer hugi.packet_destroy(&ptb)
		add_bench(&ptb, 1, "tight_tie", tight_b[:])
		testing.expect(t, store.store_ingest_packet(&st_tie, pta))
		testing.expect(t, store.store_ingest_packet(&st_tie, ptb))
		rep_tie := store.compare_1v1_langs(&st_tie, "odin", "zig", "c1v1", threshold_pct = 0.0)
		defer store.cross_lang_report_destroy(&rep_tie)
		testing.expect_value(t, rep_tie.ties, 1)
		testing.expect_value(t, len(rep_tie.rows), 1)
		if len(rep_tie.rows) == 1 {
			testing.expect_value(t, rep_tie.rows[0].faster_lang, "tie")
			testing.expect(
				t,
				!rep_tie.rows[0].is_significant,
				"tie below 0.5% must not report is_significant=true when threshold_pct=0",
			)
		}
	}
}

@(test)
test_multirun_pooling_avoids_stitched_shape_false_positives_and_ar1_p_parity :: proc(
	t: ^testing.T,
) {
	make_pkt :: proc(commit, run_id: string, name: string, ns_vals: []f64) -> hugi.Run_Packet {
		pkt := hugi.Run_Packet {
			suite_name     = strings.clone("pool_shape_suite"),
			lang           = strings.clone("odin"),
			commit         = strings.clone(commit),
			run_id         = strings.clone(run_id),
			os             = strings.clone("linux"),
			arch           = strings.clone("amd64"),
			optimization   = strings.clone("Speed"),
			odin_version   = strings.clone("test"),
			timestamp_unix = 1770000000,
			records        = make([dynamic]hugi.Record, 0, 1),
		}
		samples := make([dynamic]u64, len(ns_vals))
		for v, i in ns_vals {
			samples[i] = hugi.ns_f64_to_batch_ns(v, 100)
		}
		r := hugi.Record {
			rank             = 1,
			group_name       = strings.clone("core"),
			name             = strings.clone(name),
			full_name        = strings.concatenate({"core::", name}),
			ops_per_sample   = 100,
			samples          = len(ns_vals),
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

	// 1. Two steady, unimodal, zero-autocorrelation runs at slightly shifted ambient clocks
	// (100 ns vs 107 ns) must NOT trigger false drift, 2 modes, or collapsed n_eff.
	run1 := [20]f64 {
		100.00,
		100.05,
		99.95,
		100.02,
		99.98,
		100.04,
		99.96,
		100.01,
		99.99,
		100.03,
		99.97,
		100.02,
		99.98,
		100.05,
		99.95,
		100.01,
		99.99,
		100.04,
		99.96,
		100.00,
	}
	run2 := [20]f64 {
		107.00,
		107.05,
		106.95,
		107.02,
		106.98,
		107.04,
		106.96,
		107.01,
		106.99,
		107.03,
		106.97,
		107.02,
		106.98,
		107.05,
		106.95,
		107.01,
		106.99,
		107.04,
		106.96,
		107.00,
	}
	p1 := make_pkt("amb_b", "r-amb-1", "steady", run1[:])
	defer hugi.packet_destroy(&p1)
	p2 := make_pkt("amb_b", "r-amb-2", "steady", run2[:])
	defer hugi.packet_destroy(&p2)
	testing.expect(t, store.store_ingest_packet(&st, p1))
	testing.expect(t, store.store_ingest_packet(&st, p2))

	pooled := store.store_load_pooled_records(&st, "odin", "amb_b")
	defer store.pooled_records_destroy(pooled)
	testing.expect_value(t, len(pooled), 1)
	if len(pooled) == 1 {
		pr := pooled[0]
		testing.expect_value(t, pr.samples, 40)
		testing.expect(t, pr.trend_pct == 0.0, "steady multi-run must not report stitched drift")
		testing.expect_value(t, pr.modes, 1)
		testing.expect(
			t,
			pr.autocorrelation < 0.25,
			"steady multi-run must not report high stitched autocorrelation",
		)
		testing.expect(
			t,
			pr.effective_samples > 35.0,
			"steady multi-run must preserve per-run effective_samples (~40)",
		)
	}

	// Compare pooled steady multi-run against slightly higher steady multi-run (108 vs 115 ns):
	// stitched r1 would have collapsed n_eff and over-widened HL CI, whereas per-run n_eff keeps
	// pooled HL CI tight and consistent.
	p_c1 := make_pkt(
		"amb_c",
		"r-ambc-1",
		"steady",
		[]f64 {
			112.00,
			112.05,
			111.95,
			112.02,
			111.98,
			112.04,
			111.96,
			112.01,
			111.99,
			112.03,
			111.97,
			112.02,
			111.98,
			112.05,
			111.95,
			112.01,
			111.99,
			112.04,
			111.96,
			112.00,
		},
	)
	defer hugi.packet_destroy(&p_c1)
	p_c2 := make_pkt(
		"amb_c",
		"r-ambc-2",
		"steady",
		[]f64 {
			119.00,
			119.05,
			118.95,
			119.02,
			118.98,
			119.04,
			118.96,
			119.01,
			118.99,
			119.03,
			118.97,
			119.02,
			118.98,
			119.05,
			118.95,
			119.01,
			118.99,
			119.04,
			118.96,
			119.00,
		},
	)
	defer hugi.packet_destroy(&p_c2)
	testing.expect(t, store.store_ingest_packet(&st, p_c1))
	testing.expect(t, store.store_ingest_packet(&st, p_c2))
	pooled_c := store.store_load_pooled_records(&st, "odin", "amb_c")
	defer store.pooled_records_destroy(pooled_c)

	rep_amb := store.compare_records(pooled, pooled_c, threshold_pct = 5.0)
	defer store.comparison_report_destroy(&rep_amb)
	testing.expect_value(t, rep_amb.drifting_rows, 0)
	testing.expect_value(t, rep_amb.multimodal_rows, 0)
	testing.expect_value(t, len(rep_amb.rows), 1)
	if len(rep_amb.rows) == 1 {
		testing.expect_value(t, rep_amb.rows[0].verdict, store.Verdict.Regression)
	}

	// 2. --by-run with >20 monotonic runs must use adjust_for_autocorrelation = false.
	base_meds := make([]f64, 24)
	cand_meds := make([]f64, 24)
	for idx in 0 ..< 24 {
		bv := 100.0 + f64(idx) * 0.2
		cv := 106.0 + f64(idx) * 0.2
		base_meds[idx] = bv
		cand_meds[idx] = cv
		pb := make_pkt("br24_b", fmt.tprintf("br24-b-%d", idx), "mono", []f64{bv, bv, bv, bv})
		defer hugi.packet_destroy(&pb)
		pc := make_pkt("br24_c", fmt.tprintf("br24-c-%d", idx), "mono", []f64{cv, cv, cv, cv})
		defer hugi.packet_destroy(&pc)
		testing.expect(t, store.store_ingest_packet(&st, pb))
		testing.expect(t, store.store_ingest_packet(&st, pc))
	}
	defer delete(base_meds)
	defer delete(cand_meds)
	br24_b := store.store_load_pooled_records(&st, "odin", "br24_b")
	defer store.pooled_records_destroy(br24_b)
	br24_c := store.store_load_pooled_records(&st, "odin", "br24_c")
	defer store.pooled_records_destroy(br24_c)
	rep_br24 := store.compare_records(br24_b, br24_c, threshold_pct = 0.0, use_run_medians = true)
	defer store.comparison_report_destroy(&rep_br24)
	_, exp_low, exp_high, exp_ok := obench.hodges_lehmann_shift(
		cand_meds,
		base_meds,
		adjust_for_autocorrelation = false,
		allocator = context.temp_allocator,
	)
	testing.expect(t, exp_ok)
	testing.expect_value(t, len(rep_br24.rows), 1)
	if len(rep_br24.rows) == 1 {
		r := rep_br24.rows[0]
		testing.expect(
			t,
			math.abs(r.shift_low_pct - exp_low) < 1e-6 &&
			math.abs(r.shift_high_pct - exp_high) < 1e-6,
			"--by-run HL CI must match adjust_for_autocorrelation=false",
		)
	}

	// 3. Positively autocorrelated single runs (n=40): when 95% HL CI straddles 0%, adjusted MWU
	// p_value must also be >= 0.05 (no contradiction between CI and p-value).
	ac_a := make([]f64, 40)
	ac_b := make([]f64, 40)
	defer delete(ac_a)
	defer delete(ac_b)
	for i in 0 ..< 40 {
		ac_a[i] = 100.0 + f64(i) * 1.5
		ac_b[i] = 112.0 + f64(i) * 1.5
	}
	p_aca := make_pkt("ac_b", "r-ac-a", "ramp", ac_a)
	defer hugi.packet_destroy(&p_aca)
	p_acb := make_pkt("ac_c", "r-ac-b", "ramp", ac_b)
	defer hugi.packet_destroy(&p_acb)
	testing.expect(t, store.store_ingest_packet(&st, p_aca))
	testing.expect(t, store.store_ingest_packet(&st, p_acb))
	ra := store.store_load_pooled_records(&st, "odin", "ac_b")
	defer store.pooled_records_destroy(ra)
	rb := store.store_load_pooled_records(&st, "odin", "ac_c")
	defer store.pooled_records_destroy(rb)
	rep_ac := store.compare_records(ra, rb, threshold_pct = 0.0)
	defer store.comparison_report_destroy(&rep_ac)
	testing.expect_value(t, len(rep_ac.rows), 1)
	if len(rep_ac.rows) == 1 {
		r := rep_ac.rows[0]
		testing.expect(t, r.used_shift_ci)
		testing.expect(t, r.shift_low_pct < 0.0, "autocorrelated 95% HL CI must straddle 0%")
		testing.expect_value(t, r.verdict, store.Verdict.Unchanged)
		testing.expectf(
			t,
			r.p_value >= 0.05,
			"autocorrelation-adjusted MWU p_value (%.4f) must agree with HL CI straddling 0%%",
			r.p_value,
		)
	}
}

@(test)
test_compare_1v1_skewed_hl_orientation_and_table_json_csv_visibility :: proc(t: ^testing.T) {
	make_lang_pkt :: proc(lang: string, name: string, ns_vals: []f64) -> hugi.Run_Packet {
		pkt := hugi.Run_Packet {
			suite_name     = strings.clone("skew_1v1_suite"),
			lang           = strings.clone(lang),
			commit         = strings.clone("sk1"),
			run_id         = strings.concatenate({"r-", lang}),
			os             = strings.clone("linux"),
			arch           = strings.clone("amd64"),
			optimization   = strings.clone("Speed"),
			odin_version   = strings.clone("test"),
			timestamp_unix = 1770000000,
			records        = make([dynamic]hugi.Record, 0, 1),
		}
		samples := make([dynamic]u64, len(ns_vals))
		for v, i in ns_vals {
			samples[i] = hugi.ns_f64_to_batch_ns(v, 100)
		}
		r := hugi.Record {
			rank             = 1,
			group_name       = strings.clone("core"),
			name             = strings.clone(name),
			full_name        = strings.concatenate({"core::", name}),
			ops_per_sample   = 100,
			samples          = len(ns_vals),
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

	// Skewed/bimodal distribution where a_med (99) < b_med (100), yet pairwise HL shift
	// significantly favors b (b has fast tail at 30ns, a has slow tail at 300ns).
	skew_a := []f64 {
		99,
		99,
		99,
		99,
		99,
		99,
		99,
		99,
		99,
		99,
		300,
		300,
		300,
		300,
		300,
		300,
		300,
		300,
		300,
	}
	skew_b := []f64 {
		30,
		30,
		30,
		30,
		30,
		30,
		30,
		30,
		30,
		100,
		100,
		100,
		100,
		100,
		100,
		100,
		100,
		100,
		100,
	}

	pa := make_lang_pkt("odin", "skew", skew_a)
	defer hugi.packet_destroy(&pa)
	pb := make_lang_pkt("zig", "skew", skew_b)
	defer hugi.packet_destroy(&pb)
	testing.expect(t, store.store_ingest_packet(&st, pa))
	testing.expect(t, store.store_ingest_packet(&st, pb))

	rep_ab := store.compare_1v1_langs(&st, "odin", "zig", "sk1", threshold_pct = 5.0)
	defer store.cross_lang_report_destroy(&rep_ab)
	rep_ba := store.compare_1v1_langs(&st, "zig", "odin", "sk1", threshold_pct = 5.0)
	defer store.cross_lang_report_destroy(&rep_ba)

	testing.expect_value(t, len(rep_ab.rows), 1)
	testing.expect_value(t, len(rep_ba.rows), 1)
	if len(rep_ab.rows) == 1 && len(rep_ba.rows) == 1 {
		rab := rep_ab.rows[0]
		rba := rep_ba.rows[0]
		testing.expect(t, rab.used_shift_ci)
		testing.expect(t, rab.shift_pct > 0, "1v1 shift_pct must never be negative")
		testing.expect(t, rab.shift_low_pct > 5.0, "1v1 shift_low_pct must exceed threshold")
		testing.expect(
			t,
			rab.is_significant,
			"significant HL shift favoring zig must not be missed",
		)
		testing.expect_value(t, rab.faster_lang, "zig")
		testing.expect_value(t, rep_ab.b_wins, 1)

		testing.expect_value(t, rba.faster_lang, "zig")
		testing.expect(t, rba.is_significant)
		testing.expect(t, math.abs(rab.shift_pct - rba.shift_pct) < 1e-6)
		testing.expect(t, math.abs(rab.shift_low_pct - rba.shift_low_pct) < 1e-6)
		testing.expect(t, math.abs(rab.shift_high_pct - rba.shift_high_pct) < 1e-6)
	}

	md := store.format_1v1_table(rep_ab, context.temp_allocator)
	testing.expect(
		t,
		strings.contains(md, "Test / p-value"),
		"1v1 table must show Test / p-value header",
	)
	testing.expect(t, strings.contains(md, "HL ["), "1v1 table must display HL shift CI bounds")

	js := store.format_1v1_json(rep_ab, context.temp_allocator)
	testing.expect(
		t,
		strings.contains(js, `"used_shift_ci": true`),
		"1v1 JSON must serialize used_shift_ci",
	)

	csv := store.format_1v1_csv(rep_ab, context.temp_allocator)
	testing.expect(
		t,
		strings.contains(csv, ",shift_pct,shift_low_pct,shift_high_pct,used_shift_ci\n"),
		"1v1 CSV header must include shift CI columns",
	)
	testing.expect(t, strings.contains(csv, ",true\n"), "1v1 CSV row must emit used_shift_ci")
}

@(test)
test_compare_by_run_aligns_medians_delta_geomean_and_fallback_gate :: proc(t: ^testing.T) {
	make_pkt :: proc(commit, run_id: string, name: string, ns_vals: []f64) -> hugi.Run_Packet {
		pkt := hugi.Run_Packet {
			suite_name     = strings.clone("byrun_suite"),
			lang           = strings.clone("odin"),
			commit         = strings.clone(commit),
			run_id         = strings.clone(run_id),
			os             = strings.clone("linux"),
			arch           = strings.clone("amd64"),
			optimization   = strings.clone("Speed"),
			odin_version   = strings.clone("test"),
			timestamp_unix = 1770000000,
			records        = make([dynamic]hugi.Record, 0, 1),
		}
		samples := make([dynamic]u64, len(ns_vals))
		for v, i in ns_vals {
			samples[i] = hugi.ns_f64_to_batch_ns(v, 100)
		}
		r := hugi.Record {
			rank             = 1,
			group_name       = strings.clone("core"),
			name             = strings.clone(name),
			full_name        = strings.concatenate({"core::", name}),
			ops_per_sample   = 100,
			samples          = len(ns_vals),
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

	// 1. 4-run unequal-sample case:
	// Base pooled: 20x 200ns + 6x 100ns => pooled p50=200ns, pooled CV=24.3% (<25%).
	// Base run medians: [200, 100, 100, 100]ns => run p50=100ns, run CV=40.0% (>25%).
	heavy_200 := [20]f64 {
		200,
		200,
		200,
		200,
		200,
		200,
		200,
		200,
		200,
		200,
		200,
		200,
		200,
		200,
		200,
		200,
		200,
		200,
		200,
		200,
	}
	small_100 := [2]f64{100, 100}
	cand_140 := [4]f64{140, 140, 140, 140}
	cand_220 := [4]f64{220, 220, 220, 220}

	p_b0 := make_pkt("c4_base", "r-b0", "op", heavy_200[:])
	defer hugi.packet_destroy(&p_b0)
	testing.expect(t, store.store_ingest_packet(&st, p_b0))
	for i in 1 ..< 4 {
		pb := make_pkt("c4_base", fmt.tprintf("r-b%d", i), "op", small_100[:])
		defer hugi.packet_destroy(&pb)
		testing.expect(t, store.store_ingest_packet(&st, pb))
	}
	for i in 0 ..< 4 {
		p140 := make_pkt("c4_140", fmt.tprintf("r-140-%d", i), "op", cand_140[:])
		defer hugi.packet_destroy(&p140)
		testing.expect(t, store.store_ingest_packet(&st, p140))

		p220 := make_pkt("c4_220", fmt.tprintf("r-220-%d", i), "op", cand_220[:])
		defer hugi.packet_destroy(&p220)
		testing.expect(t, store.store_ingest_packet(&st, p220))
	}

	b4 := store.store_load_pooled_records(&st, "odin", "c4_base")
	defer store.pooled_records_destroy(b4)
	c4_140 := store.store_load_pooled_records(&st, "odin", "c4_140")
	defer store.pooled_records_destroy(c4_140)
	c4_220 := store.store_load_pooled_records(&st, "odin", "c4_220")
	defer store.pooled_records_destroy(c4_220)

	// 140ns vs base run p50=100ns flips sign from pooled (-30%) to run-median (+40%) and flags run CV>25%.
	rep_140 := store.compare_records(b4, c4_140, threshold_pct = 5.0, use_run_medians = true)
	defer store.comparison_report_destroy(&rep_140)
	testing.expect_value(t, len(rep_140.rows), 1)
	testing.expect_value(t, rep_140.high_cv_rows, 1)
	testing.expect(t, math.abs(rep_140.geomean_delta - 40.0) < 0.01)
	if len(rep_140.rows) == 1 {
		r := rep_140.rows[0]
		testing.expect(t, r.used_run_medians)
		testing.expect_value(t, r.base_p50_fs, i64(100_000_000))
		testing.expect_value(t, r.cand_p50_fs, i64(140_000_000))
		testing.expect(t, math.abs(r.delta_pct - 40.0) < 0.01)
		testing.expect(t, math.abs(r.speedup - (100.0 / 140.0)) < 1e-6)
		testing.expect(t, r.base_cv_pct > 25.0)
	}

	// 220ns vs base run medians [200, 100, 100, 100] keeps HL shift_low_pct >= +10% => Regression.
	rep_220 := store.compare_records(b4, c4_220, threshold_pct = 5.0, use_run_medians = true)
	defer store.comparison_report_destroy(&rep_220)
	testing.expect_value(t, len(rep_220.rows), 1)
	testing.expect_value(t, rep_220.high_cv_rows, 1)
	testing.expect(t, math.abs(rep_220.geomean_delta - 120.0) < 0.01)
	if len(rep_220.rows) == 1 {
		r := rep_220.rows[0]
		testing.expect(t, r.used_run_medians)
		testing.expect(t, r.used_shift_ci)
		testing.expect_value(t, r.base_p50_fs, i64(100_000_000))
		testing.expect_value(t, r.cand_p50_fs, i64(220_000_000))
		testing.expect(t, math.abs(r.delta_pct - 120.0) < 0.01)
		testing.expect(t, math.abs(r.speedup - (100.0 / 220.0)) < 1e-6)
		testing.expect_value(t, r.verdict, store.Verdict.Regression)
	}

	// 2. 3-run Welch fallback path (used_shift_ci == false):
	// Base pooled p50=101ns (+4.46% vs 105.5ns, below 5% gate), run medians [100, 100, 101] => run p50=100ns (+5.5% >= 5% gate).
	heavy_101 := [20]f64 {
		101,
		101,
		101,
		101,
		101,
		101,
		101,
		101,
		101,
		101,
		101,
		101,
		101,
		101,
		101,
		101,
		101,
		101,
		101,
		101,
	}
	small_100_3 := [3]f64{100, 100, 100}
	cand_1055 := [3]f64{105.5, 105.5, 105.5}

	p3_b0 := make_pkt("c3_base", "r3-b0", "op", heavy_101[:])
	defer hugi.packet_destroy(&p3_b0)
	p3_b1 := make_pkt("c3_base", "r3-b1", "op", small_100_3[:])
	defer hugi.packet_destroy(&p3_b1)
	p3_b2 := make_pkt("c3_base", "r3-b2", "op", small_100_3[:])
	defer hugi.packet_destroy(&p3_b2)
	testing.expect(t, store.store_ingest_packet(&st, p3_b0))
	testing.expect(t, store.store_ingest_packet(&st, p3_b1))
	testing.expect(t, store.store_ingest_packet(&st, p3_b2))

	for i in 0 ..< 3 {
		pc := make_pkt("c3_cand", fmt.tprintf("r3-c%d", i), "op", cand_1055[:])
		defer hugi.packet_destroy(&pc)
		testing.expect(t, store.store_ingest_packet(&st, pc))
	}

	b3 := store.store_load_pooled_records(&st, "odin", "c3_base")
	defer store.pooled_records_destroy(b3)
	c3 := store.store_load_pooled_records(&st, "odin", "c3_cand")
	defer store.pooled_records_destroy(c3)

	rep3 := store.compare_records(b3, c3, threshold_pct = 5.0, use_run_medians = true)
	defer store.comparison_report_destroy(&rep3)
	testing.expect_value(t, len(rep3.rows), 1)
	testing.expect(t, math.abs(rep3.geomean_delta - 5.5) < 0.01)
	if len(rep3.rows) == 1 {
		r := rep3.rows[0]
		testing.expect(t, r.used_run_medians)
		testing.expect(t, !r.used_shift_ci)
		testing.expect_value(t, r.base_p50_fs, i64(100_000_000))
		testing.expect_value(t, r.cand_p50_fs, i64(105_500_000))
		testing.expect(t, math.abs(r.delta_pct - 5.5) < 0.01)
		testing.expect(t, r.is_significant)
		testing.expect_value(t, r.verdict, store.Verdict.Regression)
	}
}
