package hugi_specs

import hugi "../hugi"
import "core:testing"

@(test)
spec_multi_run_pooling_aggregates_samples_and_geomean_delta :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_in_memory_store(&w)
	base_ids := [3]string{"base-0", "base-1", "base-2"}
	cand_ids := [3]string{"cand-0", "cand-1", "cand-2"}
	for idx in 0 ..< 3 {
		given_recorded_run(
			&w,
			commit = "base111",
			lang = "odin",
			run_id = base_ids[idx],
			benches = []Bench_Observation {
				{
					name = "scan_reg",
					median_ns = 100.0 + f64(idx) * 0.2,
					spread_ns = 0.2,
					samples = 10,
					footprint_bytes = 8192,
				},
				{
					name = "scan_fast",
					median_ns = 140.0 + f64(idx) * 0.2,
					spread_ns = 0.2,
					samples = 10,
					footprint_bytes = 8192,
				},
				{
					name = "scan_flat",
					median_ns = 80.0 + f64(idx) * 0.05,
					spread_ns = 0.1,
					samples = 10,
					footprint_bytes = 4096,
				},
			},
		)
		given_recorded_run(
			&w,
			commit = "cand222",
			lang = "odin",
			run_id = cand_ids[idx],
			benches = []Bench_Observation {
				{
					name = "scan_reg",
					median_ns = 140.0 + f64(idx) * 0.2,
					spread_ns = 0.2,
					samples = 10,
					footprint_bytes = 8192,
				},
				{
					name = "scan_fast",
					median_ns = 100.0 + f64(idx) * 0.2,
					spread_ns = 0.2,
					samples = 10,
					footprint_bytes = 8192,
				},
				{
					name = "scan_flat",
					median_ns = 80.0 + f64(idx) * 0.05,
					spread_ns = 0.1,
					samples = 10,
					footprint_bytes = 4096,
				},
			},
		)
	}

	upon_querying_commit(&w, commit = "base111", lang = "odin")
	if pooled, ok := viewing_benchmark(&w, "core::scan_reg"); ok {
		shows_run_count(&w, pooled, 3)
		shows_sample_count(&w, pooled, 30)
	}

	upon_comparing_commits(&w, "base111", "cand222", lang = "odin", threshold_pct = 5.0)
	then_comparison_summary(&w, improvements = 1, regressions = 1, unchanged = 1)
	then_comparison_geomean_between(&w, -1.0, 1.0)
	if reg, ok := viewing_comparison_row(&w, "core::scan_reg"); ok {
		shows_verdict(&w, reg, .Regression)
		shows_significance(&w, reg, true, max_p_value = 0.01)
		shows_positive_regression_delta(&w, reg, min_delta_pct = 25.0)
	}
	if fast, ok := viewing_comparison_row(&w, "core::scan_fast"); ok {
		shows_verdict(&w, fast, .Faster)
		shows_significance(&w, fast, true, max_p_value = 0.01)
	}
	if flat, ok := viewing_comparison_row(&w, "core::scan_flat"); ok {
		shows_verdict(&w, flat, .Unchanged)
		shows_significance(&w, flat, false)
	}
}

@(test)
spec_commit_comparison_verdict_decision_matrix :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	cases := []Verdict_Matrix_Case {
		verdict_case("core::regression", 100.0, 130.0, 5.0, .Regression, true),
		verdict_case("core::faster", 100.0, 70.0, 5.0, .Faster, true),
		verdict_case("core::below_thresh", 100.0, 103.0, 5.0, .Unchanged, false),
		verdict_case("core::identical", 100.0, 100.0, 5.0, .Unchanged, false),
		verdict_case("core::high_thresh", 100.0, 115.0, 20.0, .Unchanged, false),
		verdict_case("core::tight_thresh", 100.0, 108.0, 5.0, .Regression, true),
	}

	for tc in cases {
		given_in_memory_store(&w, loc = tc.loc)
		given_recorded_run(
			&w,
			commit = "base",
			lang = "odin",
			run_id = "r-base",
			bench = Bench_Observation {
				name = tc.name,
				median_ns = tc.base_ns,
				samples = 12,
				spread_ns = 0.25,
			},
			loc = tc.loc,
		)
		given_recorded_run(
			&w,
			commit = "cand",
			lang = "odin",
			run_id = "r-cand",
			bench = Bench_Observation {
				name = tc.name,
				median_ns = tc.cand_ns,
				samples = 12,
				spread_ns = 0.25,
			},
			loc = tc.loc,
		)
		upon_comparing_commits(
			&w,
			"base",
			"cand",
			lang = "odin",
			threshold_pct = tc.threshold_pct,
			loc = tc.loc,
		)
		if row, ok := viewing_comparison_row(&w, tc.name, loc = tc.loc); ok {
			shows_verdict(&w, row, tc.expected_verdict, loc = tc.loc)
			shows_significance(&w, row, tc.expected_sig, loc = tc.loc)
		}
	}
}

@(test)
spec_cross_lang_1v1_detects_winners_ties_footprint_mismatch_and_unmatched :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_in_memory_store(&w)
	given_recorded_run(
		&w,
		commit = "cmp001",
		lang = "odin",
		run_id = "run-odin-1",
		benches = []Bench_Observation {
			{name = "fast_op", median_ns = 50.0, footprint_bytes = 4096},
			{name = "tie_op", median_ns = 80.0, footprint_bytes = 2048, spread_ns = 0.1},
			{name = "zig_op", median_ns = 150.0, footprint_bytes = 4096},
			{name = "odin_only", median_ns = 40.0, footprint_bytes = 1024},
		},
	)
	given_recorded_run(
		&w,
		commit = "cmp001",
		lang = "zig",
		run_id = "run-zig-1",
		benches = []Bench_Observation {
			{name = "fast_op", median_ns = 100.0, footprint_bytes = 4096},
			{name = "tie_op", median_ns = 80.1, footprint_bytes = 2048, spread_ns = 0.1},
			{name = "zig_op", median_ns = 90.0, footprint_bytes = 16384},
			{name = "zig_only", median_ns = 40.0, footprint_bytes = 1024},
		},
	)

	upon_comparing_1v1(&w, "odin", "zig", commit = "cmp001", threshold_pct = 3.0)

	then_1v1_summary(&w, a_wins = 1, b_wins = 1, ties = 1, footprint_mismatches = 1)
	then_1v1_only_in(&w, []string{"core::odin_only"}, []string{"core::zig_only"})

	if r1, ok := viewing_1v1_row(&w, "core::fast_op"); ok {
		shows_winner(&w, r1, "odin")
		shows_1v1_significance(&w, r1, true, max_p_value = 0.01)
		shows_footprint_mismatch(&w, r1, false)
	}
	if r2, ok := viewing_1v1_row(&w, "core::tie_op"); ok {
		shows_winner(&w, r2, "tie")
		shows_1v1_significance(&w, r2, false)
		shows_footprint_mismatch(&w, r2, false)
	}
	if r3, ok := viewing_1v1_row(&w, "core::zig_op"); ok {
		shows_winner(&w, r3, "zig")
		shows_1v1_significance(&w, r3, true, max_p_value = 0.01)
		shows_footprint_mismatch(&w, r3, true)
	}
}

@(test)
spec_clamped_zero_fs_baseline_regression_is_detected :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_in_memory_store(&w)
	given_recorded_run(
		&w,
		commit = "zf01",
		lang = "odin",
		run_id = "zf-base",
		bench = Bench_Observation {
			name = "simd::clamped_zero",
			ops_per_sample = 100_000,
			exact_batch_ns = []u64{0, 0, 0, 0, 0, 0, 0, 0},
		},
	)
	given_recorded_run(
		&w,
		commit = "zf02",
		lang = "odin",
		run_id = "zf-cand",
		bench = Bench_Observation {
			name = "simd::clamped_zero",
			ops_per_sample = 100_000,
			median_ns = 50.0,
			spread_ns = 0.2,
			samples = 8,
		},
	)

	upon_comparing_commits(&w, "zf01", "zf02", lang = "odin", threshold_pct = 5.0)
	then_comparison_summary(&w, improvements = 0, regressions = 1, unchanged = 0)
	if row, ok := viewing_comparison_row(&w, "simd::clamped_zero"); ok {
		shows_verdict(&w, row, .Regression)
		shows_significance(&w, row, true, max_p_value = 0.01)
	}
}

@(test)
spec_compare_warns_on_env_mismatch_clamped_clock_and_underpowered_samples :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_in_memory_store(&w)
	given_recorded_run(
		&w,
		commit = "env01",
		lang = "odin",
		run_id = "r-env01",
		bench = Bench_Observation{name = "core::work", median_ns = 100.0, samples = 3},
		env = hugi.Run_Env {
			cpu_model = "AMD Ryzen 7 7735U",
			governor = "performance",
			scaling_max_khz = 4_821_140,
			cpuinfo_max_khz = 4_821_140,
			boost_state = 1,
			build_flags = "-o:speed -microarch:native",
		},
	)
	given_recorded_run(
		&w,
		commit = "env02",
		lang = "odin",
		run_id = "r-env02",
		bench = Bench_Observation{name = "core::work", median_ns = 145.0, samples = 3},
		env = hugi.Run_Env {
			cpu_model = "Intel Core i7-7700HQ",
			governor = "powersave",
			scaling_max_khz = 2_701_000,
			cpuinfo_max_khz = 4_821_140,
			boost_state = 1,
			build_flags = "-o:speed",
		},
	)

	upon_comparing_commits(&w, "env01", "env02", lang = "odin", threshold_pct = 5.0)
	then_comparison_warns_containing(&w, "CPU model mismatch")
	then_comparison_warns_containing(&w, "CPU scaling_max_freq mismatch")
	then_comparison_warns_containing(&w, "clamped CPU scaling_max_freq")
	then_comparison_warns_containing(&w, "CPU scaling_governor mismatch")
	then_comparison_warns_containing(&w, "Build flags mismatch")
	then_comparison_warns_containing(&w, "< 5 samples per side")
}

@(test)
spec_compare_1v1_warns_on_cross_language_commit_drift :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_in_memory_store(&w)
	given_recorded_run(
		&w,
		commit = "c_old",
		lang = "zig",
		run_id = "r-zig-old",
		bench = Bench_Observation{name = "core::op", median_ns = 80.0, samples = 7},
	)
	given_recorded_run(
		&w,
		commit = "c_new",
		lang = "odin",
		run_id = "r-odin-new",
		bench = Bench_Observation{name = "core::op", median_ns = 50.0, samples = 7},
	)

	upon_comparing_1v1(&w, "odin", "zig", commit = "", threshold_pct = 3.0)
	then_1v1_warns_containing(&w, "Cross-language commit mismatch: odin at c_new vs zig at c_old")
}

@(test)
spec_hodges_lehmann_ci_gating_shape_warnings_and_by_run_comparison :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_in_memory_store(&w)
	// Noisy boundary shift (p < 0.05 and delta > 5%, but 95% HL CI straddles 5%) must stay Unchanged.
	given_recorded_run(
		&w,
		commit = "hl_base",
		lang = "odin",
		run_id = "r-hl-b",
		benches = []Bench_Observation {
			{
				name = "core::straddle",
				ops_per_sample = 100,
				exact_batch_ns = []u64 {
					9200,
					9500,
					9700,
					9900,
					10000,
					10000,
					10100,
					10300,
					10500,
					10800,
				},
			},
		},
	)
	given_recorded_run(
		&w,
		commit = "hl_cand",
		lang = "odin",
		run_id = "r-hl-c",
		benches = []Bench_Observation {
			{
				name = "core::straddle",
				ops_per_sample = 100,
				exact_batch_ns = []u64 {
					10100,
					10300,
					10500,
					10700,
					10800,
					10900,
					11100,
					11300,
					11500,
					11800,
				},
			},
		},
	)
	upon_comparing_commits(&w, "hl_base", "hl_cand", lang = "odin", threshold_pct = 5.0)
	if row, ok := viewing_comparison_row(&w, "core::straddle"); ok {
		shows_shift_ci(&w, row, expect_used_ci = true, expect_by_run = false)
		shows_verdict(&w, row, .Unchanged)
		shows_significance(&w, row, false, max_p_value = 0.05)
	}

	// Drifting and multimodal runs surface diagnostic warnings.
	given_recorded_run(
		&w,
		commit = "shape_b",
		lang = "odin",
		run_id = "r-sh-b",
		benches = []Bench_Observation {
			{
				name = "core::drift",
				ops_per_sample = 100,
				exact_batch_ns = []u64{10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000},
			},
			{
				name = "core::bimodal",
				ops_per_sample = 100,
				exact_batch_ns = []u64 {
					5000,
					5020,
					4990,
					5010,
					5000,
					5030,
					4980,
					5000,
					5010,
					4990,
					5020,
					5000,
					20000,
					20020,
					19990,
					20010,
					20000,
					20030,
					19980,
					20000,
					20010,
					19990,
					20020,
					20000,
				},
			},
		},
	)
	given_recorded_run(
		&w,
		commit = "shape_c",
		lang = "odin",
		run_id = "r-sh-c",
		benches = []Bench_Observation {
			{
				name = "core::drift",
				ops_per_sample = 100,
				exact_batch_ns = []u64{10000, 10800, 11600, 12400, 13200, 14000, 14800, 15600},
			},
			{
				name = "core::bimodal",
				ops_per_sample = 100,
				exact_batch_ns = []u64 {
					5000,
					5020,
					4990,
					5010,
					5000,
					5030,
					4980,
					5000,
					5010,
					4990,
					5020,
					5000,
					20000,
					20020,
					19990,
					20010,
					20000,
					20030,
					19980,
					20000,
					20010,
					19990,
					20020,
					20000,
				},
			},
		},
	)
	upon_comparing_commits(&w, "shape_b", "shape_c", lang = "odin", threshold_pct = 5.0)
	then_comparison_shape_counts(&w, drifting_rows = 1, multimodal_rows = 1)
	then_comparison_warns_containing(&w, "sample drift over the run")
	then_comparison_warns_containing(&w, "multimodal sample distributions")

	// Multi-run comparison with use_run_medians = true compares per-run medians.
	base_rids := [4]string{"br-0", "br-1", "br-2", "br-3"}
	cand_rids := [4]string{"cr-0", "cr-1", "cr-2", "cr-3"}
	for idx in 0 ..< 4 {
		given_recorded_run(
			&w,
			commit = "byrun_b",
			lang = "odin",
			run_id = base_rids[idx],
			bench = Bench_Observation {
				name = "core::op",
				median_ns = 100.0 + f64(idx) * 0.5,
				spread_ns = 0.1,
				samples = 6,
			},
		)
		given_recorded_run(
			&w,
			commit = "byrun_c",
			lang = "odin",
			run_id = cand_rids[idx],
			bench = Bench_Observation {
				name = "core::op",
				median_ns = 140.0 + f64(idx) * 0.5,
				spread_ns = 0.1,
				samples = 6,
			},
		)
	}
	upon_comparing_commits(
		&w,
		"byrun_b",
		"byrun_c",
		lang = "odin",
		threshold_pct = 5.0,
		use_run_medians = true,
	)
	if row, ok := viewing_comparison_row(&w, "core::op"); ok {
		shows_shift_ci(&w, row, expect_used_ci = true, expect_by_run = true)
		shows_verdict(&w, row, .Regression)
		shows_significance(&w, row, true, max_p_value = 0.05)
	}

	// Unequal per-run sample counts under --by-run must align delta_pct and geomean with run medians.
	heavy_200 := [20]u64 {
		20000,
		20000,
		20000,
		20000,
		20000,
		20000,
		20000,
		20000,
		20000,
		20000,
		20000,
		20000,
		20000,
		20000,
		20000,
		20000,
		20000,
		20000,
		20000,
		20000,
	}
	small_100 := [2]u64{10000, 10000}
	cand_220 := [4]u64{22000, 22000, 22000, 22000}
	uneq_b_rids := [4]string{"ub-0", "ub-1", "ub-2", "ub-3"}
	uneq_c_rids := [4]string{"uc-0", "uc-1", "uc-2", "uc-3"}
	for idx in 0 ..< 4 {
		given_recorded_run(
			&w,
			commit = "byrun_uneq_b",
			lang = "odin",
			run_id = uneq_b_rids[idx],
			bench = Bench_Observation {
				name = "core::uneq",
				ops_per_sample = 100,
				exact_batch_ns = heavy_200[:] if idx == 0 else small_100[:],
			},
		)
		given_recorded_run(
			&w,
			commit = "byrun_uneq_c",
			lang = "odin",
			run_id = uneq_c_rids[idx],
			bench = Bench_Observation {
				name = "core::uneq",
				ops_per_sample = 100,
				exact_batch_ns = cand_220[:],
			},
		)
	}
	upon_comparing_commits(
		&w,
		"byrun_uneq_b",
		"byrun_uneq_c",
		lang = "odin",
		threshold_pct = 5.0,
		use_run_medians = true,
	)
	then_comparison_geomean_between(&w, 119.0, 121.0)
	if row, ok := viewing_comparison_row(&w, "core::uneq"); ok {
		shows_shift_ci(&w, row, expect_used_ci = true, expect_by_run = true)
		shows_positive_regression_delta(&w, row, min_delta_pct = 110.0)
		shows_verdict(&w, row, .Regression)
	}

	// 1v1 ties below 0.5% stay non-significant even with threshold_pct = 0.0.
	tie_a := [10]u64{10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000}
	tie_b := [10]u64{10040, 10040, 10040, 10040, 10040, 10040, 10040, 10040, 10040, 10040}
	given_recorded_run(
		&w,
		commit = "tie01",
		lang = "odin",
		run_id = "r-tie-o",
		bench = Bench_Observation {
			name = "core::tie_zero_thresh",
			ops_per_sample = 100,
			exact_batch_ns = tie_a[:],
		},
	)
	given_recorded_run(
		&w,
		commit = "tie01",
		lang = "zig",
		run_id = "r-tie-z",
		bench = Bench_Observation {
			name = "core::tie_zero_thresh",
			ops_per_sample = 100,
			exact_batch_ns = tie_b[:],
		},
	)
	upon_comparing_1v1(&w, "odin", "zig", commit = "tie01", threshold_pct = 0.0)
	then_1v1_summary(&w, a_wins = 0, b_wins = 0, ties = 1, footprint_mismatches = 0)
	if row, ok := viewing_1v1_row(&w, "core::tie_zero_thresh"); ok {
		shows_winner(&w, row, "tie")
		shows_1v1_significance(&w, row, false)
	}
}

@(test)
spec_multirun_ambient_shift_and_skewed_1v1_avoid_false_diagnostics :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_in_memory_store(&w)

	// Two steady runs at slightly shifted ambient clocks (100ns vs 107ns) must not trigger false
	// drift or bimodal diagnostics when pooled.
	run_a := [20]u64 {
		10000,
		10005,
		9995,
		10002,
		9998,
		10004,
		9996,
		10001,
		9999,
		10003,
		9997,
		10002,
		9998,
		10005,
		9995,
		10001,
		9999,
		10004,
		9996,
		10000,
	}
	run_b := [20]u64 {
		10700,
		10705,
		10695,
		10702,
		10698,
		10704,
		10696,
		10701,
		10699,
		10703,
		10697,
		10702,
		10698,
		10705,
		10695,
		10701,
		10699,
		10704,
		10696,
		10700,
	}
	run_c1 := [20]u64 {
		11200,
		11205,
		11195,
		11202,
		11198,
		11204,
		11196,
		11201,
		11199,
		11203,
		11197,
		11202,
		11198,
		11205,
		11195,
		11201,
		11199,
		11204,
		11196,
		11200,
	}
	run_c2 := [20]u64 {
		11900,
		11905,
		11895,
		11902,
		11898,
		11904,
		11896,
		11901,
		11899,
		11903,
		11897,
		11902,
		11898,
		11905,
		11895,
		11901,
		11899,
		11904,
		11896,
		11900,
	}
	given_recorded_run(
		&w,
		commit = "amb_b",
		lang = "odin",
		run_id = "r-amb-1",
		bench = Bench_Observation {
			name = "core::steady",
			ops_per_sample = 100,
			exact_batch_ns = run_a[:],
		},
	)
	given_recorded_run(
		&w,
		commit = "amb_b",
		lang = "odin",
		run_id = "r-amb-2",
		bench = Bench_Observation {
			name = "core::steady",
			ops_per_sample = 100,
			exact_batch_ns = run_b[:],
		},
	)
	given_recorded_run(
		&w,
		commit = "amb_c",
		lang = "odin",
		run_id = "r-amb-3",
		bench = Bench_Observation {
			name = "core::steady",
			ops_per_sample = 100,
			exact_batch_ns = run_c1[:],
		},
	)
	given_recorded_run(
		&w,
		commit = "amb_c",
		lang = "odin",
		run_id = "r-amb-4",
		bench = Bench_Observation {
			name = "core::steady",
			ops_per_sample = 100,
			exact_batch_ns = run_c2[:],
		},
	)
	upon_comparing_commits(&w, "amb_b", "amb_c", lang = "odin", threshold_pct = 5.0)
	then_comparison_shape_counts(&w, drifting_rows = 0, multimodal_rows = 0)
	if row, ok := viewing_comparison_row(&w, "core::steady"); ok {
		shows_verdict(&w, row, .Regression)
	}

	// Skewed 1v1 bimodal comparison aligns winner with HL shift CI rather than raw median order.
	skew_a := []u64 {
		9900,
		9900,
		9900,
		9900,
		9900,
		9900,
		9900,
		9900,
		9900,
		9900,
		30000,
		30000,
		30000,
		30000,
		30000,
		30000,
		30000,
		30000,
		30000,
	}
	skew_b := []u64 {
		3000,
		3000,
		3000,
		3000,
		3000,
		3000,
		3000,
		3000,
		3000,
		10000,
		10000,
		10000,
		10000,
		10000,
		10000,
		10000,
		10000,
		10000,
		10000,
	}
	given_recorded_run(
		&w,
		commit = "skew01",
		lang = "odin",
		run_id = "r-skew-o",
		bench = Bench_Observation {
			name = "core::skew",
			ops_per_sample = 100,
			exact_batch_ns = skew_a,
		},
	)
	given_recorded_run(
		&w,
		commit = "skew01",
		lang = "zig",
		run_id = "r-skew-z",
		bench = Bench_Observation {
			name = "core::skew",
			ops_per_sample = 100,
			exact_batch_ns = skew_b,
		},
	)
	upon_comparing_1v1(&w, "odin", "zig", commit = "skew01", threshold_pct = 5.0)
	then_1v1_summary(&w, a_wins = 0, b_wins = 1, ties = 0, footprint_mismatches = 0)
	if row, ok := viewing_1v1_row(&w, "core::skew"); ok {
		shows_winner(&w, row, "zig")
		shows_1v1_significance(&w, row, true, max_p_value = 0.05)
	}
}

@(test)
spec_too_few_samples_stays_undecided_and_asymmetric_runs_warn :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_in_memory_store(&w)

	// 1. 3 vs 3 runs under --by-run lacks enough medians for a 95% HL interval -> undecided.
	b3_ids := [3]string{"u-b0", "u-b1", "u-b2"}
	c3_ids := [3]string{"u-c0", "u-c1", "u-c2"}
	for idx in 0 ..< 3 {
		given_recorded_run(
			&w,
			commit = "und_b",
			lang = "odin",
			run_id = b3_ids[idx],
			bench = Bench_Observation {
				name = "core::small",
				median_ns = 100.0 + f64(idx) * 0.5,
				samples = 6,
				spread_ns = 0.1,
			},
		)
		given_recorded_run(
			&w,
			commit = "und_c",
			lang = "odin",
			run_id = c3_ids[idx],
			bench = Bench_Observation {
				name = "core::small",
				median_ns = 140.0 + f64(idx) * 0.5,
				samples = 6,
				spread_ns = 0.1,
			},
		)
	}
	upon_comparing_commits(
		&w,
		"und_b",
		"und_c",
		lang = "odin",
		threshold_pct = 5.0,
		use_run_medians = true,
	)
	then_comparison_summary(&w, improvements = 0, regressions = 0, unchanged = 1)
	then_comparison_undecided_and_one_sided(&w, undecided_rows = 1, one_sided_runs_rows = 0)
	then_comparison_warns_containing(&w, "too few samples or runs per side")
	if row, ok := viewing_comparison_row(&w, "core::small"); ok {
		shows_undecided(&w, row, true)
		shows_shift_ci(&w, row, expect_used_ci = false, expect_by_run = true)
		shows_verdict(&w, row, .Unchanged)
		shows_significance(&w, row, false)
	}

	// 2. Adding 2 more candidate runs (3 vs 5) reaches an exact 95% HL interval -> Regression.
	extra_ids := [2]string{"u-c3", "u-c4"}
	for idx in 0 ..< 2 {
		given_recorded_run(
			&w,
			commit = "und_c",
			lang = "odin",
			run_id = extra_ids[idx],
			bench = Bench_Observation {
				name = "core::small",
				median_ns = 142.0 + f64(idx) * 0.5,
				samples = 6,
				spread_ns = 0.1,
			},
		)
	}
	upon_comparing_commits(
		&w,
		"und_b",
		"und_c",
		lang = "odin",
		threshold_pct = 5.0,
		use_run_medians = true,
	)
	then_comparison_summary(&w, improvements = 0, regressions = 1, unchanged = 0)
	then_comparison_undecided_and_one_sided(&w, undecided_rows = 0, one_sided_runs_rows = 0)
	if row, ok := viewing_comparison_row(&w, "core::small"); ok {
		shows_undecided(&w, row, false)
		shows_shift_ci(&w, row, expect_used_ci = true, expect_by_run = true)
		shows_verdict(&w, row, .Regression)
		shows_significance(&w, row, true)
	}

	// 3. 1 run vs multiple runs emits the asymmetric multi-run warning in commit & 1v1 comparisons.
	given_recorded_run(
		&w,
		commit = "asym_base",
		lang = "odin",
		run_id = "asym-o-1",
		bench = Bench_Observation{name = "core::work", median_ns = 100.0, samples = 8},
	)
	cand_ids := [4]string{"asym-c0", "asym-c1", "asym-c2", "asym-c3"}
	zig_ids := [4]string{"asym-z0", "asym-z1", "asym-z2", "asym-z3"}
	for idx in 0 ..< 4 {
		given_recorded_run(
			&w,
			commit = "asym_cand",
			lang = "odin",
			run_id = cand_ids[idx],
			bench = Bench_Observation {
				name = "core::work",
				median_ns = 135.0 + f64(idx),
				samples = 8,
			},
		)
		given_recorded_run(
			&w,
			commit = "asym_base",
			lang = "zig",
			run_id = zig_ids[idx],
			bench = Bench_Observation {
				name = "core::work",
				median_ns = 160.0 + f64(idx),
				samples = 8,
			},
		)
	}
	upon_comparing_commits(&w, "asym_base", "asym_cand", lang = "odin", threshold_pct = 5.0)
	then_comparison_undecided_and_one_sided(&w, undecided_rows = 0, one_sided_runs_rows = 1)
	then_comparison_warns_containing(&w, "multiple runs on only one side")

	upon_comparing_1v1(&w, "odin", "zig", commit = "asym_base", threshold_pct = 3.0)
	then_1v1_undecided_and_one_sided(&w, undecided_rows = 0, one_sided_runs_rows = 1)
	then_1v1_warns_containing(&w, "multiple runs on only one side")
}
