package hugi_tests

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
	// 1. Positively autocorrelated ramp widens ci95_fs compared to alternating permutation.
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
	testing.expectf(
		t,
		st_ramp.ci95_fs > st_osc.ci95_fs,
		"expected AR(1) ci95_fs (%d) > unautocorrelated (%d)",
		st_ramp.ci95_fs,
		st_osc.ci95_fs,
	)

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

	js := store.format_1v1_json(rep, context.temp_allocator)
	testing.expect(t, strings.contains(js, `"drifting_rows": 1`))
	testing.expect(t, strings.contains(js, `"multimodal_rows": 1`))
	testing.expect(t, strings.contains(js, `"shift_pct":`))
	testing.expect(t, strings.contains(js, `"shift_low_pct":`))
	testing.expect(t, strings.contains(js, `"shift_high_pct":`))
}
