package hugi_specs

import "core:testing"

@(test)
spec_cli_version_help_ingest_history_and_inspect_workflow :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	world_set_timeout(&w, 15)
	defer world_destroy(&w)

	given_cli_workspace(&w)

	upon_running_cli(&w, "version")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "hugi 0.1.0")
	}

	upon_running_cli(&w, "help")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "USAGE:")
		shows_stdout_contains(&w, out, "COMMANDS:")
	}

	given_packet_file(
		&w,
		"pkt-odin",
		commit = "cli101",
		lang = "odin",
		run_id = "cli-r1",
		benches = []Bench_Observation {
			{name = "get", median_ns = 45.0, footprint_bytes = 1024},
			{name = "put", median_ns = 95.0, footprint_bytes = 2048},
		},
	)
	given_legacy_jsonl_fixture(
		&w,
		"pkt-zig",
		commit = "cli101",
		lang = "zig",
		run_id = "cli-z1",
		full_name = "core::get",
		median_ns = 80.0,
		ops = 100,
		footprint_bytes = 1024,
	)
	given_obench_report_fixture(
		&w,
		"pkt-obench",
		suite_name = "ob_cli",
		group_name = "math",
		bench_name = "mul",
		median_ns = 12.1,
		batch_size = 10,
	)

	upon_running_cli(
		&w,
		"ingest",
		"--db",
		"@db",
		"@pkt-odin",
		"@pkt-zig",
		"@pkt-obench",
		"--commit",
		"cli101",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Ingested 3 packet(s), 4 record(s)")
	}

	upon_running_cli(&w, "history", "--db", "@db", "--commits")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "cli101")
		shows_stdout_contains(&w, out, "odin,zig")
	}

	upon_running_cli(&w, "history", "--db", "@db", "--runs", "--limit", "2")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "cli-z1")
		shows_stdout_contains(&w, out, "ob_cli")
		shows_stdout_does_not_contain(&w, out, "cli-r1")
	}

	upon_running_cli(&w, "inspect", "--db", "@db", "--lang", "odin", "get")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Inspect (odin, 1 benchmarks)")
		shows_stdout_contains(&w, out, "core::get")
		shows_stdout_contains(&w, out, "Quantile Breakdown:")
	}

	upon_running_cli(&w, "inspect", "--db", "@db", "--lang", "odin", "--run", "cli-r1")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Inspect (odin, 2 benchmarks)")
		shows_stdout_contains(&w, out, "core::put")
	}

	upon_running_cli(&w, "inspect", "--db", "@db", "--commit", "cli101", "--lang", "zig")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Inspect (zig, 1 benchmarks)")
		shows_stdout_contains(&w, out, "core::get")
	}
}

@(test)
spec_cli_run_no_db_and_overlay :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	world_set_timeout(&w, 60)
	defer world_destroy(&w)

	given_cli_workspace(&w)
	given_cli_bench_package(&w, "clean-pkg", work_iters = 32)

	upon_running_cli(
		&w,
		"run",
		"@clean-pkg",
		"--no-db",
		"--db",
		"@nodb",
		"--extra-build-flags",
		"-o:none",
		"--quiet",
		"--runs",
		"2",
		"--warmup",
		"0",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
	}
	then_store_file_does_not_exist(&w, "nodb")

	given_packet_file(
		&w,
		"base-pkt",
		commit = "base00",
		lang = "odin",
		run_id = "r-base00",
		benches = []Bench_Observation {
			{
				name = "work",
				group = "pipe",
				median_ns = 5.0,
				spread_ns = 0.05,
				samples = 8,
				ops_per_sample = 1,
			},
		},
	)
	upon_running_cli(&w, "ingest", "--db", "@db", "@base-pkt")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
	}

	upon_running_cli(
		&w,
		"run",
		"@clean-pkg",
		"--db",
		"@db",
		"--overlay",
		"--lang",
		"ODIN",
		"--commit",
		"trial01",
		"--extra-build-flags",
		"-o:none",
		"--quiet",
		"--runs",
		"2",
		"--warmup",
		"0",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "lang=odin")
		shows_stdout_contains(&w, out, "disk untouched")
	}

	upon_running_cli(&w, "history", "--db", "@db", "--commits")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "base00")
		shows_stdout_does_not_contain(&w, out, "trial01")
	}

	upon_running_cli(
		&w,
		"run",
		"@clean-pkg",
		"--db",
		"@db",
		"--overlay",
		"--commit",
		"byr01",
		"--baseline-commit",
		"base00",
		"--by-run",
		"--extra-build-flags",
		"-o:none",
		"--quiet",
		"--runs",
		"2",
		"--warmup",
		"0",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "fell back to pooled sample comparison for --by-run")
	}
}

@(test)
spec_cli_run_baseline_regression_gate :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	world_set_timeout(&w, 90)
	defer world_destroy(&w)

	given_cli_workspace(&w)
	given_cli_bench_package(&w, "slow-pkg", work_iters = 25_000)

	given_packet_file(
		&w,
		"base-pkt",
		commit = "base00",
		lang = "odin",
		run_id = "r-base00",
		benches = []Bench_Observation {
			{
				name = "work",
				group = "pipe",
				median_ns = 5.0,
				spread_ns = 0.05,
				samples = 8,
				ops_per_sample = 1,
			},
		},
	)
	upon_running_cli(&w, "ingest", "--db", "@db", "@base-pkt")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
	}

	upon_running_cli(
		&w,
		"run",
		"@slow-pkg",
		"--db",
		"@db",
		"--commit",
		"reg01",
		"--baseline-commit",
		"base00",
		"--fail-on-regression",
		"--quiet",
		"--runs",
		"4",
		"--warmup",
		"0",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 1)
		shows_stdout_contains(&w, out, "REGRESSION")
	}
}

@(test)
spec_cli_run_zero_alloc_violation :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	world_set_timeout(&w, 60)
	defer world_destroy(&w)

	given_cli_workspace(&w)
	given_cli_bench_package(&w, "bad-pkg", work_iters = 16, violate_zero_alloc = true)

	upon_running_cli(
		&w,
		"run",
		"@bad-pkg",
		"--no-db",
		"--extra-build-flags",
		"-o:none",
		"--runs",
		"2",
		"--warmup",
		"0",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 1)
		shows_stdout_contains(&w, out, "[FAIL: @zero_alloc]")
	}
}

@(test)
spec_cli_compare_commits_runs_and_last_fallback :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	world_set_timeout(&w, 15)
	defer world_destroy(&w)

	given_cli_workspace(&w)
	given_packet_file(
		&w,
		"pkt-base",
		commit = "base01",
		lang = "odin",
		run_id = "r-base",
		benches = []Bench_Observation {
			{name = "scan", median_ns = 100.0, samples = 12, spread_ns = 0.2},
		},
	)
	given_packet_file(
		&w,
		"pkt-fast",
		commit = "fast02",
		lang = "odin",
		run_id = "r-fast",
		benches = []Bench_Observation {
			{name = "scan", median_ns = 65.0, samples = 12, spread_ns = 0.2},
		},
	)
	given_packet_file(
		&w,
		"pkt-reg",
		commit = "cand03",
		lang = "odin",
		run_id = "r-cand",
		benches = []Bench_Observation {
			{name = "scan", median_ns = 145.0, samples = 12, spread_ns = 0.2},
		},
	)

	upon_running_cli(&w, "ingest", "--db", "@db", "@pkt-base", "@pkt-fast", "@pkt-reg")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
	}

	upon_running_cli(
		&w,
		"compare",
		"--db",
		"@db",
		"--commits",
		"base01..fast02",
		"--threshold",
		"5.0",
		"--fail-on-regression",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Comparison: base01 -> fast02")
		shows_stdout_contains(&w, out, "improved: 1")
		shows_stdout_contains(&w, out, "FASTER")
	}

	upon_running_cli(
		&w,
		"compare",
		"--db",
		"@db",
		"--commits",
		"base01..cand03",
		"--threshold",
		"5.0",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Comparison: base01 -> cand03")
		shows_stdout_contains(&w, out, "REGRESSION")
	}

	upon_running_cli(
		&w,
		"compare",
		"--db",
		"@db",
		"--runs",
		"r-base..r-cand",
		"--fail-on-regression",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 1)
		shows_stdout_contains(&w, out, "Comparison: r-base -> r-cand")
		shows_stdout_contains(&w, out, "REGRESSION")
	}

	upon_running_cli(&w, "compare", "--db", "@db", "--last", "--fail-on-regression")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 1)
		shows_stdout_contains(&w, out, "Comparison: fast02 -> cand03")
		shows_stdout_contains(&w, out, "regressed: 1")
		shows_stdout_contains(&w, out, "REGRESSION")
	}

	given_packet_file(
		&w,
		"pkt-s1",
		commit = "only01",
		lang = "odin",
		run_id = "r-s1",
		benches = []Bench_Observation {
			{name = "scan", median_ns = 100.0, samples = 12, spread_ns = 0.2},
		},
	)
	given_packet_file(
		&w,
		"pkt-s2",
		commit = "only01",
		lang = "odin",
		run_id = "r-s2",
		benches = []Bench_Observation {
			{name = "scan", median_ns = 145.0, samples = 12, spread_ns = 0.2},
		},
	)
	upon_running_cli(&w, "ingest", "--db", "@single-commit-db", "@pkt-s1", "@pkt-s2")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
	}
	upon_running_cli(&w, "compare", "--db", "@single-commit-db", "--last", "--fail-on-regression")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 1)
		shows_stdout_contains(&w, out, "Comparison: r-s1 -> r-s2")
		shows_stdout_contains(&w, out, "REGRESSION")
	}

	upon_running_cli(
		&w,
		"compare",
		"--db",
		"@db",
		"--commits",
		"base01..fast02",
		"--format",
		"json",
		"--out",
		"-",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, `"baseline": "base01"`)
		shows_stdout_contains(&w, out, `"candidate": "fast02"`)
		shows_stdout_contains(&w, out, `"verdict": "faster"`)
	}

	upon_running_cli(
		&w,
		"compare",
		"--db",
		"@db",
		"--commits",
		"base01..cand03",
		"--format",
		"json",
		"--fail-on-regression",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 1)
		shows_stdout_contains(&w, out, `"verdict": "regression"`)
	}

	upon_running_cli(
		&w,
		"compare",
		"--db",
		"@db",
		"--commits",
		"base01..fast02",
		"--out",
		"@cmp.csv",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
	}
	then_file_contains(&w, "cmp.csv", "baseline,candidate,full_name,")
	then_file_contains(
		&w,
		"cmp.csv",
		",shift_pct,shift_low_pct,shift_high_pct,used_shift_ci,used_run_medians",
	)
	then_file_contains(&w, "cmp.csv", "base01,fast02,core::scan,")

	// Verify hugi inspect sample-shape annotations ([drifts ...], [N modes], [r1=..., n_eff=...]).
	given_packet_file(
		&w,
		"pkt-shape",
		commit = "shp01",
		lang = "odin",
		run_id = "r-shp01",
		benches = []Bench_Observation {
			{
				name = "drift",
				ops_per_sample = 100,
				exact_batch_ns = []u64{10000, 10800, 11600, 12400, 13200, 14000, 14800, 15600},
			},
			{
				name = "bimodal",
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
	upon_running_cli(&w, "ingest", "--db", "@shape-db", "@pkt-shape")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
	}
	upon_running_cli(&w, "inspect", "--db", "@shape-db")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "[drifts +")
		shows_stdout_contains(&w, out, "[2 modes]")
		shows_stdout_contains(&w, out, "[r1=")
		shows_stdout_contains(&w, out, "n_eff=")
	}

	// Verify --by-run on multi-run commits via CLI.
	byrun_b := [4]string{"cli-br0", "cli-br1", "cli-br2", "cli-br3"}
	byrun_b_args := [4]string{"@cli-br0", "@cli-br1", "@cli-br2", "@cli-br3"}
	byrun_c := [4]string{"cli-cr0", "cli-cr1", "cli-cr2", "cli-cr3"}
	byrun_c_args := [4]string{"@cli-cr0", "@cli-cr1", "@cli-cr2", "@cli-cr3"}
	for idx in 0 ..< 4 {
		given_packet_file(
			&w,
			byrun_b[idx],
			commit = "byr1",
			lang = "odin",
			run_id = byrun_b[idx],
			benches = []Bench_Observation {
				{name = "scan", median_ns = 100.0 + f64(idx), samples = 6, spread_ns = 0.1},
			},
		)
		given_packet_file(
			&w,
			byrun_c[idx],
			commit = "byr2",
			lang = "odin",
			run_id = byrun_c[idx],
			benches = []Bench_Observation {
				{name = "scan", median_ns = 140.0 + f64(idx), samples = 6, spread_ns = 0.1},
			},
		)
		upon_running_cli(&w, "ingest", "--db", "@byrun-db", byrun_b_args[idx], byrun_c_args[idx])
		if out, ok := viewing_cli_output(&w); ok {
			shows_exit_code(&w, out, 0)
		}
	}
	upon_running_cli(
		&w,
		"compare",
		"--db",
		"@byrun-db",
		"--commits",
		"byr1..byr2",
		"--by-run",
		"--format",
		"json",
		"--out",
		"-",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, `"used_run_medians": true`)
		shows_stdout_contains(&w, out, `"used_shift_ci": true`)
		shows_stdout_contains(&w, out, `"verdict": "regression"`)
	}
}

@(test)
spec_cli_compare_1v1_reports_winner_mismatch_and_unmatched :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	world_set_timeout(&w, 15)
	defer world_destroy(&w)

	given_cli_workspace(&w)
	given_packet_file(
		&w,
		"pkt-o",
		commit = "cmp99",
		lang = "odin",
		run_id = "o-1",
		benches = []Bench_Observation {
			{name = "fast_op", median_ns = 50.0, footprint_bytes = 4096},
			{name = "mem_op", median_ns = 120.0, footprint_bytes = 4096},
			{name = "odin_only", median_ns = 40.0, footprint_bytes = 1024},
		},
	)
	given_packet_file(
		&w,
		"pkt-z",
		commit = "cmp99",
		lang = "zig",
		run_id = "z-1",
		benches = []Bench_Observation {
			{name = "fast_op", median_ns = 100.0, footprint_bytes = 4096},
			{name = "mem_op", median_ns = 118.0, footprint_bytes = 16384},
		},
	)

	upon_running_cli(&w, "ingest", "--db", "@db", "@pkt-o", "@pkt-z")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
	}

	upon_running_cli(&w, "compare-1v1", "--db", "@db", "--langs", "Odin,ZIG", "--commit", "cmp99")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Cross-Language 1v1: odin vs zig")
		shows_stdout_contains(&w, out, "footprint mismatches: 1")
		shows_stdout_contains(&w, out, "[MISMATCH]")
		shows_stdout_contains(&w, out, "Only in odin (1):")
		shows_stdout_contains(&w, out, "core::odin_only")
	}

	upon_running_cli(
		&w,
		"compare-1v1",
		"--db",
		"@db",
		"--langs",
		"odin,zig",
		"--commit",
		"cmp99",
		"--format",
		"json",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, `"lang_a": "odin"`)
		shows_stdout_contains(&w, out, `"footprint_mismatches": 1`)
		shows_stdout_contains(&w, out, `"drifting_rows":`)
		shows_stdout_contains(&w, out, `"multimodal_rows":`)
		shows_stdout_contains(&w, out, `"shift_pct":`)
		shows_stdout_contains(&w, out, `"shift_low_pct":`)
		shows_stdout_contains(&w, out, `"shift_high_pct":`)
		shows_stdout_contains(&w, out, `"only_in_a": ["core::odin_only"]`)
	}

	upon_running_cli(
		&w,
		"compare-1v1",
		"--db",
		"@db",
		"--langs",
		"odin,zig",
		"--commit",
		"cmp99",
		"--out",
		"@cmp1v1.csv",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
	}
	then_file_contains(&w, "cmp1v1.csv", "lang_a,lang_b,full_name,")
	then_file_contains(&w, "cmp1v1.csv", "odin,zig,core::fast_op,")
}

@(test)
spec_cli_export_all_formats_filter_readme_and_compact_workflow :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	world_set_timeout(&w, 15)
	defer world_destroy(&w)

	given_cli_workspace(&w)
	given_readme_file(
		&w,
		"readme.md",
		"# Benchmarks\n\n<!-- BEGIN_BENCHMARK_TABLE -->\nstale\n<!-- END_BENCHMARK_TABLE -->\n",
	)
	given_packet_file(
		&w,
		"pkt-1",
		commit = "ex01",
		lang = "odin",
		run_id = "ex-r1",
		benches = []Bench_Observation {
			{name = "alpha", median_ns = 60.0, footprint_bytes = 1024},
			{name = "beta", median_ns = 180.0, footprint_bytes = 4096},
		},
	)
	given_packet_file(
		&w,
		"pkt-2",
		commit = "ex02",
		lang = "odin",
		run_id = "ex-r2",
		benches = []Bench_Observation {
			{name = "alpha", median_ns = 55.0, footprint_bytes = 1024},
			{name = "beta", median_ns = 175.0, footprint_bytes = 4096},
		},
	)

	upon_running_cli(&w, "ingest", "--db", "@db", "@pkt-1", "@pkt-2")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
	}

	upon_running_cli(&w, "export", "--db", "@db", "--all-commits", "--out", "@series.arrow")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Exported 4 record(s) (arrow)")
	}
	then_exported_artifact_valid(&w, "series.arrow", .Arrow, expected_rows = 4, expected_cols = 35)

	upon_running_cli(&w, "export", "--db", "@db", "--all-runs", "--out", "@runs.parquet")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Exported 4 record(s) (parquet)")
	}
	then_exported_artifact_valid(
		&w,
		"runs.parquet",
		.Parquet,
		expected_rows = 4,
		expected_cols = 35,
	)

	upon_running_cli(&w, "export", "--db", "@db", "--out", "@snap.csv")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Exported 2 record(s) (csv)")
	}
	then_exported_artifact_valid(&w, "snap.csv", .Csv, expected_rows = 2, expected_cols = 34)

	upon_running_cli(&w, "export", "--db", "@db", "--filter", "alpha", "--out", "@alpha.csv")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Exported 1 record(s) (csv)")
	}
	then_exported_artifact_valid(&w, "alpha.csv", .Csv, expected_rows = 1, expected_cols = 34)
	then_file_contains(&w, "alpha.csv", "core::alpha")
	then_file_does_not_contain(&w, "alpha.csv", "core::beta")

	upon_running_cli(&w, "export", "--db", "@db", "--update-readme", "@readme.md")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Updated benchmark table")
	}
	then_file_contains(&w, "readme.md", "core::alpha")
	then_file_does_not_contain(&w, "readme.md", "\nstale\n")

	given_legacy_jsonl_fixture(
		&w,
		"pkt-z-stream",
		commit = "ex02",
		lang = "zig",
		run_id = "ex-z1",
		full_name = "core::alpha",
		median_ns = 90.0,
		ops = 10,
	)
	upon_running_cli(&w, "ingest", "--db", "@db", "@pkt-z-stream")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
	}

	upon_running_cli(
		&w,
		"export",
		"--db",
		"@db",
		"--lang",
		"all",
		"--format",
		"jsonl",
		"--out",
		"-",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, `"lang":"odin"`)
		shows_stdout_contains(&w, out, `"lang":"zig"`)
		shows_stdout_does_not_contain(&w, out, "Exported ")
	}

	upon_running_cli(&w, "compact", "--db", "@db", "--keep-hot", "0")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Compacted ")
	}

	upon_running_cli(&w, "history", "--db", "@db", "--runs")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "ex-r1")
		shows_stdout_contains(&w, out, "ex-r2")
	}
}

@(test)
spec_cli_invalid_invocations_return_nonzero_and_diagnostics_matrix :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	world_set_timeout(&w, 15)
	defer world_destroy(&w)

	given_cli_workspace(&w)

	cases := []CLI_Guard_Case {
		cli_guard_case("unknown-cmd", []string{"bogus-cmd"}, "unknown command 'bogus-cmd'"),
		cli_guard_case(
			"ingest-no-files",
			[]string{"ingest", "--db", "@db"},
			"expected at least one input file",
		),
		cli_guard_case(
			"ingest-missing-file",
			[]string{"ingest", "--db", "@db", "@missing.hpk"},
			"file not found",
		),
		cli_guard_case(
			"compare-bad-range",
			[]string{"compare", "--db", "@db", "--commits", "onlyone"},
			"--commits requires <base>..<cand>",
		),
		cli_guard_case(
			"compare-1v1-bad-langs",
			[]string{"compare-1v1", "--db", "@db", "--langs", "odin"},
			"--langs requires two comma-separated languages",
		),
		cli_guard_case(
			"export-conflicting-scope",
			[]string{"export", "--db", "@db", "--all-commits", "--all-runs", "--out", "@a.csv"},
			"--all-commits and --all-runs cannot be combined",
		),
		cli_guard_case(
			"export-missing-out",
			[]string{"export", "--db", "@db", "--format", "csv"},
			"--out <path>",
		),
		cli_guard_case(
			"export-binary-stdout",
			[]string{"export", "--db", "@db", "--format", "arrow", "--out", "-"},
			"binary format requires a file path",
		),
		cli_guard_case(
			"compact-negative-keep-hot",
			[]string{"compact", "--db", "@db", "--keep-hot", "-2"},
			"invalid --keep-hot",
		),
		cli_guard_case("run-negative-pin", []string{"run", "--pin", "-1"}, "invalid --pin"),
	}

	for tc in cases {
		upon_running_cli(&w, ..tc.args, loc = tc.loc)
		if out, ok := viewing_cli_output(&w, loc = tc.loc); ok {
			shows_exit_code(&w, out, 1, loc = tc.loc)
			shows_stderr_contains(&w, out, tc.expected_stderr, loc = tc.loc)
		}
	}
}

@(test)
spec_cli_doctor_hugi_json_and_ingest_provenance :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	world_set_timeout(&w, 60)
	defer world_destroy(&w)

	given_cli_workspace(&w)
	given_cli_bench_package(&w, "cfg-pkg", work_iters = 16)
	given_project_config(
		&w,
		`{
	"db": "cfg.hugidb",
	"pkg_dir": "cfg-pkg",
	"runs": 3,
	"warmup": 0,
	"extra_build_flags": "-o:none"
}
`,
	)

	upon_running_cli(&w, "doctor", "--format", "json")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, `"cpu_model":`)
		shows_stdout_contains(&w, out, `"cores":`)
		shows_stdout_contains(&w, out, `"smt":`)
		shows_stdout_contains(&w, out, `"scaling_max_khz":`)
		shows_stdout_contains(&w, out, `"load_avg":`)
		shows_stdout_contains(&w, out, `"on_battery":`)
		shows_stdout_contains(&w, out, `"vm":`)
		shows_stdout_contains(&w, out, `"notes":`)
		shows_stdout_contains(&w, out, `"pkg_dir": "cfg-pkg"`)
	}

	upon_running_cli(&w, "doctor")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Logical cores:")
		shows_stdout_contains(&w, out, "SMT:")
		shows_stdout_contains(&w, out, "Load average:")
		shows_stdout_contains(&w, out, "Power:")
		shows_stdout_contains(&w, out, "Virtual machine:")
		shows_stdout_does_not_contain(&w, out, "the CPU governor is")
	}

	upon_running_cli(&w, "run", "--commit", "cfg001", "--quiet")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "samples=3")
		shows_stdout_contains(&w, out, "cfg.hugidb")
	}

	upon_running_cli(&w, "inspect", "--commit", "cfg001")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Environment:")
		shows_stdout_contains(&w, out, "-o:none")
	}

	given_packet_file(
		&w,
		"pkt-ext",
		commit = "ext001",
		lang = "cpp",
		run_id = "r-ext",
		benches = []Bench_Observation{{name = "scan", median_ns = 40.0, samples = 7}},
	)
	upon_running_cli(
		&w,
		"ingest",
		"--db",
		"@ing.hugidb",
		"@pkt-ext",
		"--capture-host-env",
		"--build-flags",
		"-O3",
		"--runtime-version",
		"GCC 14",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
	}

	upon_running_cli(&w, "inspect", "--db", "@ing.hugidb", "--lang", "cpp")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Environment:")
		shows_stdout_contains(&w, out, "-O3")
		shows_stdout_contains(&w, out, "GCC 14")
	}
}

@(test)
spec_cli_ingest_obench_v6_preserves_git_timestamp_provenance_and_heap_peak :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	world_set_timeout(&w, 15)
	defer world_destroy(&w)

	given_cli_workspace(&w)
	given_obench_v6_report_fixture(
		&w,
		"v6-rep",
		suite_name = "v6_cli",
		group_name = "hash",
		bench_name = "fnv1a",
		commit = "cafe1234567890",
		created_at = "2026-11-20T08:30:00Z",
		cpu = "AMD Ryzen 7 7735U",
		governor = "performance",
		boost = "on",
		microarch = "native",
		bounds_checks = "off",
		median_ns = 14.5,
		batch_size = 10,
		peak_heap_bytes = 8192,
		zero_alloc_failed = false,
		instructions = 142.0,
	)

	upon_running_cli(&w, "ingest", "--db", "@db", "@v6-rep")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Ingested 1 packet(s), 1 record(s)")
	}

	upon_running_cli(&w, "history", "--db", "@db", "--commits")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "cafe12345678")
	}

	upon_running_cli(&w, "inspect", "--db", "@db", "--commit", "cafe12345678")
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "Environment:")
		shows_stdout_contains(&w, out, "AMD Ryzen 7 7735U")
		shows_stdout_contains(&w, out, "-o:speed -microarch:native -no-bounds-check")
		shows_stdout_contains(&w, out, "dev-2026-10")
	}

	upon_running_cli(
		&w,
		"export",
		"--db",
		"@db",
		"--commit",
		"cafe12345678",
		"--format",
		"json",
		"--out",
		"-",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, `"peak_heap_bytes": 8192`)
		shows_stdout_contains(&w, out, `"timestamp_unix": 1795163400`)
	}
}

@(test)
spec_cli_run_test_mode_and_pin_counters :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	world_set_timeout(&w, 90)
	defer world_destroy(&w)

	given_cli_workspace(&w)
	given_cli_bench_package(&w, "ok-pkg", work_iters = 16)
	given_cli_bench_package(&w, "bad-pkg", work_iters = 16, violate_zero_alloc = true)

	upon_running_cli(
		&w,
		"run",
		"@ok-pkg",
		"--test",
		"--db",
		"@testdb",
		"--extra-build-flags",
		"-o:none",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stdout_contains(&w, out, "--test ran every pipeline once")
	}
	then_store_file_does_not_exist(&w, "testdb")

	upon_running_cli(
		&w,
		"run",
		"@ok-pkg",
		"--test",
		"--db",
		"@testdb",
		"--baseline-commit",
		"base00",
		"--extra-build-flags",
		"-o:none",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
		shows_stderr_contains(&w, out, "--test does not measure")
	}
	then_store_file_does_not_exist(&w, "testdb")

	upon_running_cli(
		&w,
		"run",
		"@bad-pkg",
		"--test",
		"--db",
		"@testdb",
		"--extra-build-flags",
		"-o:none",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 1)
		shows_stdout_contains(&w, out, "[FAIL: @zero_alloc]")
	}
	then_store_file_does_not_exist(&w, "testdb")

	upon_running_cli(
		&w,
		"run",
		"@ok-pkg",
		"--pin",
		"0",
		"--counters",
		"--no-db",
		"--quiet",
		"--runs",
		"2",
		"--warmup",
		"0",
		"--extra-build-flags",
		"-o:none",
	)
	if out, ok := viewing_cli_output(&w); ok {
		shows_exit_code(&w, out, 0)
	}
}
