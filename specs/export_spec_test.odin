package hugi_specs

import "core:testing"

@(test)
spec_export_schema_contract_across_all_seven_formats_matrix :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_in_memory_store(&w)
	given_recorded_run(
		&w,
		commit = "par001",
		lang = "odin",
		run_id = "run-par-1",
		benches = []Bench_Observation {
			{name = "alpha", median_ns = 80.0, footprint_bytes = 1024, peak_heap_bytes = 2048},
			{name = "beta", median_ns = 210.0, footprint_bytes = 4096},
		},
	)

	cases := []Export_Format_Case {
		export_format_case("out-arrow", .Arrow, 35),
		export_format_case("out-parquet", .Parquet, 35),
		export_format_case("out-json", .Json, 34),
		export_format_case("out-jsonl", .Jsonl, 34),
		export_format_case("out-csv", .Csv, 34),
		export_format_case("out-tsv", .Tsv, 34),
		export_format_case("out-md", .Markdown, 9),
	}

	for tc in cases {
		upon_exporting(&w, tc.format, tc.label, scope = .Snapshot, lang = "odin", loc = tc.loc)
		then_export_succeeded(&w, loc = tc.loc)
		then_exported_artifact_valid(
			&w,
			tc.label,
			tc.format,
			expected_rows = 2,
			expected_cols = tc.expected_cols,
			verify_samples_against_latest = (tc.format == .Arrow),
			loc = tc.loc,
		)
	}
}

@(test)
spec_longitudinal_commit_series_and_all_runs_exports :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_file_store(&w, "longitudinal")
	run_ids := [4]string{"r-01", "r-02", "r-03", "r-04"}
	commits := [4]string{"c01", "c01", "c02", "c02"}
	for idx in 0 ..< 4 {
		given_recorded_run(
			&w,
			commit = commits[idx],
			lang = "odin",
			run_id = run_ids[idx],
			benches = []Bench_Observation {
				{name = "get", median_ns = 40.0 + f64(idx)},
				{name = "put", median_ns = 90.0 + f64(idx)},
			},
			timestamp_unix = i64(1770000000 + idx * 60),
		)
	}
	upon_compacting_store(&w, keep_hot_runs = 0)
	then_compaction_shrank_store(&w)

	upon_exporting(&w, .Arrow, "series-arrow", scope = .All_Commits, lang = "odin")
	then_export_succeeded(&w)
	then_exported_artifact_valid(&w, "series-arrow", .Arrow, expected_rows = 4, expected_cols = 35)

	upon_exporting(&w, .Parquet, "series-parquet", scope = .All_Commits, lang = "odin")
	then_export_succeeded(&w)
	then_exported_artifact_valid(
		&w,
		"series-parquet",
		.Parquet,
		expected_rows = 4,
		expected_cols = 35,
	)

	upon_exporting(&w, .Csv, "series-put-csv", scope = .All_Commits, lang = "odin", filter = "put")
	then_export_succeeded(&w)
	then_exported_artifact_valid(&w, "series-put-csv", .Csv, expected_rows = 2, expected_cols = 34)
	then_file_contains(&w, "series-put-csv", "core::put")
	then_file_does_not_contain(&w, "series-put-csv", "core::get")

	upon_exporting(&w, .Jsonl, "all-runs-jsonl", scope = .All_Runs, lang = "odin")
	then_export_succeeded(&w)
	then_exported_artifact_valid(
		&w,
		"all-runs-jsonl",
		.Jsonl,
		expected_rows = 8,
		expected_cols = 34,
	)
	then_file_contains(&w, "all-runs-jsonl", `"run_id":"r-01"`)
	then_file_contains(&w, "all-runs-jsonl", `"run_id":"r-04"`)

	given_recorded_run(
		&w,
		commit = "c02",
		lang = "zig",
		run_id = "rz-01",
		benches = []Bench_Observation{{name = "get", median_ns = 70.0}},
		timestamp_unix = i64(1770000300),
	)
	upon_exporting(&w, .Jsonl, "all-langs-snap", scope = .Snapshot, lang = "all")
	then_export_succeeded(&w)
	then_exported_artifact_valid(
		&w,
		"all-langs-snap",
		.Jsonl,
		expected_rows = 3,
		expected_cols = 34,
	)
	then_file_contains(&w, "all-langs-snap", `"lang":"odin"`)
	then_file_contains(&w, "all-langs-snap", `"lang":"zig"`)

	upon_exporting(&w, .Jsonl, "all-langs-series", scope = .All_Commits, lang = "all")
	then_export_succeeded(&w)
	then_exported_artifact_valid(
		&w,
		"all-langs-series",
		.Jsonl,
		expected_rows = 5,
		expected_cols = 34,
	)
}

@(test)
spec_sub_picosecond_precision_survives_compaction_pooling_and_exports :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_file_store(&w, "rational-fs-export")
	benches := []Bench_Observation {
		{
			name = "dot8",
			group = "simd",
			ops_per_sample = 10_000_000,
			exact_batch_ns = []u64{50_000, 50_000, 50_010},
		},
		{
			name = "clamped_zero",
			group = "simd",
			ops_per_sample = 1_000_000,
			exact_batch_ns = []u64{0, 0, 1},
		},
	}

	given_recorded_run(&w, commit = "rc01", lang = "odin", run_id = "rr-1", benches = benches)
	given_recorded_run(&w, commit = "rc02", lang = "odin", run_id = "rr-2", benches = benches)
	given_recorded_run(&w, commit = "rc02", lang = "odin", run_id = "rr-3", benches = benches)

	upon_compacting_store(&w, keep_hot_runs = 0)
	then_compaction_shrank_store(&w)

	upon_querying_latest(&w, lang = "odin")
	then_query_returned_count(&w, 2)
	if simd, ok := viewing_benchmark(&w, "simd::dot8"); ok {
		shows_exact_p50_fs(&w, simd, 5_000)
		shows_batch_sample_bounds(&w, simd, expected_len = 6, first_ns = 50_000, last_ns = 50_010)
	}
	if zero_op, ok := viewing_benchmark(&w, "simd::clamped_zero"); ok {
		shows_min_max_fs(&w, zero_op, expected_min_fs = 0, expected_max_fs = 1)
		shows_exact_p50_fs(&w, zero_op, 0)
	}

	upon_exporting(&w, .Csv, "fs-csv", scope = .Snapshot, lang = "odin")
	then_export_succeeded(&w)
	then_file_contains(&w, "fs-csv", ",0.005000,")

	upon_exporting(&w, .Json, "fs-json", scope = .Snapshot, lang = "odin")
	then_export_succeeded(&w)
	then_file_contains(&w, "fs-json", `"samples_batch_ns": [50000,`)
	then_file_contains(&w, "fs-json", `"p50_ns": 0.005000`)

	upon_exporting(&w, .Arrow, "fs-arrow", scope = .Snapshot, lang = "odin")
	then_export_succeeded(&w)
	then_exported_artifact_valid(
		&w,
		"fs-arrow",
		.Arrow,
		expected_rows = 2,
		expected_cols = 35,
		verify_samples_against_latest = true,
	)
}

@(test)
spec_readme_marker_update_replaces_table_and_rejects_missing_markers :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_in_memory_store(&w)
	given_recorded_run(
		&w,
		commit = "rm01",
		lang = "odin",
		run_id = "rm-r1",
		bench = Bench_Observation{name = "op_a", median_ns = 75.0, footprint_bytes = 1024},
	)
	given_readme_file(
		&w,
		"marked-readme",
		"# Header\n\n<!-- BEGIN_BENCHMARK_TABLE -->\nstale\n<!-- END_BENCHMARK_TABLE -->\n\n# Footer\n",
	)
	given_readme_file(&w, "plain-readme", "# Plain\nNo benchmark markers present.\n")

	upon_updating_readme(&w, "marked-readme", lang = "odin")
	then_readme_update_succeeded(&w)
	then_file_contains(&w, "marked-readme", "# Header")
	then_file_contains(&w, "marked-readme", "core::op_a")
	then_file_contains(&w, "marked-readme", "# Footer")
	then_file_does_not_contain(&w, "marked-readme", "\nstale\n")

	upon_updating_readme(&w, "plain-readme", lang = "odin")
	then_readme_update_failed(&w)
	then_file_contains(&w, "plain-readme", "No benchmark markers present.")
}
