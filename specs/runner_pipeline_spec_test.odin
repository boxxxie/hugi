package hugi_specs

import "core:testing"

@(test)
spec_clean_micro_and_pipeline_suite_writes_roundtrip_packet_and_summary :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_suite(&w, "runner_clean_spec", packet_label = "clean-run")
	given_micro_benchmark(&w, "math", "sum_zero_alloc", zero_alloc = true)
	given_pipeline(
		&w,
		"kv_pipe",
		[]Phase_Spec {
			{
				name = "fill",
				ops = 16,
				bytes_per_op = 8,
				footprint_bytes = 128,
				has_footprint = true,
			},
			{
				name = "sum",
				ops = 16,
				bytes_per_op = 8,
				zero_alloc = true,
				metric_unit = "hit%",
				metric_value = 100.0,
				has_metric = true,
				secondary_metric = "miss%",
				secondary_value = 0.0,
				has_secondary = true,
			},
			{name = "verify", ops = 16, zero_alloc = true},
		},
	)

	upon_executing_suite(&w)

	then_suite_succeeded(&w)
	then_suite_packet_is_selective(&w, false)
	then_suite_recorded_benchmarks(
		&w,
		[]string{"math::sum_zero_alloc", "kv_pipe::fill", "kv_pipe::sum", "kv_pipe::verify"},
	)
	then_suite_packet_file_roundtrips(&w, expected_records = 4)

	if fill, ok := viewing_benchmark(&w, "kv_pipe::fill"); ok {
		shows_footprint_bytes(&w, fill, 128)
		shows_sample_count(&w, fill, 4)
	}
	if sum, ok := viewing_benchmark(&w, "kv_pipe::sum"); ok {
		shows_metric(&w, sum, "hit%", 100.0)
		shows_metric(&w, sum, "miss%", 0.0)
	}
	then_suite_terminal_summary_contains(
		&w,
		"math",
		"sum_zero_alloc",
		"kv_pipe::sum",
		"100.0 hit%",
	)
}

@(test)
spec_zero_alloc_violations_in_micro_and_pipeline_fail_suite :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_suite(&w, "runner_violation_spec")
	given_micro_benchmark(&w, "alloc_grp", "bad_micro", zero_alloc = true, allocates = true)
	given_pipeline(
		&w,
		"bad_pipe",
		[]Phase_Spec{{name = "leaking_phase", ops = 1, zero_alloc = true, allocates = true}},
	)

	upon_executing_suite(&w)

	then_suite_failed_zero_alloc(&w, min_violations = 2)
	then_suite_failure_messages_contain(&w, "alloc_grp::bad_micro", "bad_pipe::leaking_phase")
	then_suite_recorded_benchmarks(&w, []string{"alloc_grp::bad_micro", "bad_pipe::leaking_phase"})
	if mb, ok := viewing_benchmark(&w, "alloc_grp::bad_micro"); ok {
		shows_failure_state(&w, mb, zero_alloc_failed = true, error = "")
	}
	if ph, ok := viewing_benchmark(&w, "bad_pipe::leaking_phase"); ok {
		shows_sample_count(&w, ph, 4)
		shows_failure_state(&w, ph, zero_alloc_failed = true, error = "")
	}
	then_suite_terminal_summary_contains(&w, "[FAIL: @zero_alloc]")
}

@(test)
spec_parameterized_groups_threads_and_nested_phases :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_suite(&w, "param_spec", runs = 2, warmup = 0)
	given_micro_benchmark(
		&w,
		"par",
		"sum",
		zero_alloc = true,
		params = []int{16, 64},
		thread_counts = []int{1, 2},
	)
	given_pipeline(
		&w,
		"kv_pipe",
		[]Phase_Spec {
			{name = "ingest", ops = 8, zero_alloc = true},
			{name = "parse", parent = "ingest", ops = 8, zero_alloc = true},
		},
		param = 64,
		has_param = true,
	)

	upon_executing_suite(&w)

	then_suite_succeeded(&w)
	then_suite_recorded_benchmarks(
		&w,
		[]string {
			"par::sum[16]/t1",
			"par::sum[16]/t2",
			"par::sum[64]/t1",
			"par::sum[64]/t2",
			"kv_pipe::ingest[64]",
			"kv_pipe::parse[64]",
		},
	)
	if micro, ok := viewing_benchmark(&w, "par::sum[64]/t2"); ok {
		shows_descriptor_tags(
			&w,
			micro,
			param = 64,
			has_param = true,
			threads = 2,
			has_threads = true,
		)
	}
	if parsed, ok := viewing_benchmark(&w, "kv_pipe::parse[64]"); ok {
		shows_descriptor_tags(
			&w,
			parsed,
			param = 64,
			has_param = true,
			threads = 1,
			has_threads = false,
		)
	}
}

@(test)
spec_suite_group_and_name_filters_mark_packet_selective :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_suite(&w, "filtered_spec", groups_filter = "math|kv_pipe", name_filter = "alpha|sum")
	given_micro_benchmark(&w, "math", "alpha", zero_alloc = true)
	given_micro_benchmark(&w, "io", "beta", zero_alloc = true)
	given_pipeline(
		&w,
		"kv_pipe",
		[]Phase_Spec {
			{name = "fill", ops = 16},
			{name = "sum", ops = 16, zero_alloc = true},
			{name = "verify", ops = 16, zero_alloc = true},
		},
	)

	upon_executing_suite(&w)

	then_suite_succeeded(&w)
	then_suite_packet_is_selective(&w, true)
	then_suite_recorded_benchmarks(&w, []string{"math::alpha", "kv_pipe::sum"})
}

@(test)
spec_nested_phase_preserves_outer_zero_alloc_violation :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_suite(&w, "nested_alloc_spec", runs = 2, warmup = 0)
	given_pipeline(
		&w,
		"outer_pipe",
		[]Phase_Spec {
			{name = "outer", ops = 1, zero_alloc = true, allocates = true},
			{name = "inner", parent = "outer", ops = 1, zero_alloc = true, allocates = false},
		},
	)

	upon_executing_suite(&w)

	then_suite_failed_zero_alloc(&w, min_violations = 1)
	if outer, ok := viewing_benchmark(&w, "outer_pipe::outer"); ok {
		shows_failure_state(&w, outer, zero_alloc_failed = true, error = "")
	}
	if inner, ok := viewing_benchmark(&w, "outer_pipe::inner"); ok {
		shows_failure_state(&w, inner, zero_alloc_failed = false, error = "")
	}
}
