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
