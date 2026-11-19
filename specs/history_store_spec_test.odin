package hugi_specs

import "core:testing"

@(test)
spec_selective_run_updates_only_touched_benchmarks_in_latest_snapshot :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_in_memory_store(&w)
	given_recorded_run(
		&w,
		commit = "aaa1111",
		lang = "odin",
		run_id = "r1",
		benches = []Bench_Observation {
			{name = "insert", median_ns = 200.0, footprint_bytes = 4096},
			{name = "lookup", median_ns = 50.0, footprint_bytes = 4096},
			{name = "delete", median_ns = 150.0, footprint_bytes = 2048},
		},
	)

	upon_ingesting_run(
		&w,
		commit = "bbb2222",
		lang = "odin",
		run_id = "r2",
		bench = Bench_Observation {
			name = "lookup",
			median_ns = 38.0,
			footprint_bytes = 4096,
			rank = 2,
		},
		selective = true,
	)

	upon_querying_latest(&w, lang = "odin")
	then_query_returned_count(&w, 3)

	if ins, ok := viewing_benchmark(&w, "core::insert"); ok {
		shows_commit(&w, ins, "aaa1111")
		shows_median_ns(&w, ins, 200.0)
	}
	if lkp, ok := viewing_benchmark(&w, "core::lookup"); ok {
		shows_commit(&w, lkp, "bbb2222")
		shows_median_ns(&w, lkp, 38.0)
	}
	if del, ok := viewing_benchmark(&w, "core::delete"); ok {
		shows_commit(&w, del, "aaa1111")
		shows_median_ns(&w, del, 150.0)
	}
}

@(test)
spec_compaction_with_hot_retention_preserves_descriptors_errors_and_lineage :: proc(
	t: ^testing.T,
) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_file_store(&w, "rollup")
	put_metrics := []Metric_Spec{{unit = "%", value = 99.5}, {unit = "MB/s", value = 420.0}}
	commits := [6]string{"c01", "c02", "c03", "c04", "c05", "c06"}
	run_ids := [6]string{"r01", "r02", "r03", "r04", "r05", "r06"}
	for spec_idx in 0 ..< 6 {
		if spec_idx == 1 {
			given_recorded_run(
				&w,
				commit = commits[spec_idx],
				lang = "odin",
				run_id = run_ids[spec_idx],
				benches = []Bench_Observation {
					{
						name = "get",
						median_ns = 45.0,
						footprint_bytes = 512,
						peak_heap_bytes = 1024,
						param = 64,
						has_param = true,
						threads = 4,
						has_threads = true,
						items_per_op = 8,
					},
					{name = "put", median_ns = 90.0, rank = 10, metrics = put_metrics},
					{
						name = "oom_case",
						samples = 0,
						zero_samples = true,
						zero_alloc_failed = true,
						error = "oom",
					},
				},
			)
		} else {
			given_recorded_run(
				&w,
				commit = commits[spec_idx],
				lang = "odin",
				run_id = run_ids[spec_idx],
				benches = []Bench_Observation {
					{
						name = "get",
						median_ns = 40.0 + f64(spec_idx) * 5.0,
						footprint_bytes = 512,
						peak_heap_bytes = 1024,
					},
					{
						name = "put",
						median_ns = 80.0 + f64(spec_idx) * 10.0,
						rank = 10,
						metrics = put_metrics,
					},
				},
			)
		}
	}

	upon_compacting_store(&w, keep_hot_runs = 2)

	then_compaction_shrank_store(&w)
	then_store_run_count(&w, 6)
	then_store_commit_count(&w, 6)
	upon_loading_all_packets(&w)
	then_loaded_packets_count(&w, 6)

	if r02_get, ok := viewing_benchmark(&w, "core::get", commit = "c02", run_id = "r02"); ok {
		shows_descriptor_tags(
			&w,
			r02_get,
			param = 64,
			has_param = true,
			threads = 4,
			has_threads = true,
			items_per_op = 8,
		)
	}
	if r02_put, ok := viewing_benchmark(&w, "core::put", commit = "c02", run_id = "r02"); ok {
		shows_metric(&w, r02_put, "%", 99.5)
		shows_metric(&w, r02_put, "MB/s", 420.0)
	}
	if r02_err, ok := viewing_benchmark(&w, "core::oom_case", commit = "c02", run_id = "r02"); ok {
		shows_sample_count(&w, r02_err, 0)
		shows_failure_state(&w, r02_err, zero_alloc_failed = true, error = "oom")
	}

	upon_querying_commit(&w, commit = "c02", lang = "odin")
	then_query_returned_count(&w, 3)
	if cold_get, ok := viewing_benchmark(&w, "core::get"); ok {
		shows_median_ns(&w, cold_get, 45.0)
	}

	upon_querying_commit(&w, commit = "c05", lang = "odin")
	then_query_returned_count(&w, 2)
	if hot_get, ok := viewing_benchmark(&w, "core::get"); ok {
		shows_median_ns(&w, hot_get, 60.0)
	}

	upon_ingesting_run(
		&w,
		commit = "c02",
		lang = "odin",
		run_id = "r02",
		benches = []Bench_Observation {
			{name = "get", median_ns = 55.0, footprint_bytes = 512},
			{name = "put", median_ns = 90.0, rank = 10, metrics = put_metrics},
		},
	)
	then_store_run_count(&w, 6)
	upon_querying_commit(&w, commit = "c02", lang = "odin")
	if ov_get, ok := viewing_benchmark(&w, "core::get"); ok {
		shows_median_ns(&w, ov_get, 55.0)
	}

	upon_ingesting_run(
		&w,
		commit = "c07",
		lang = "odin",
		run_id = "r07",
		benches = []Bench_Observation {
			{name = "get", median_ns = 75.0, footprint_bytes = 512},
			{name = "put", median_ns = 150.0, rank = 10, metrics = put_metrics},
		},
	)
	then_store_run_count(&w, 7)

	upon_querying_latest(&w, lang = "odin")
	if latest_get, ok := viewing_benchmark(&w, "core::get"); ok {
		shows_commit(&w, latest_get, "c07")
		shows_median_ns(&w, latest_get, 75.0)
	}
}

@(test)
spec_auto_sealing_and_hot_override_of_sealed_run_survive_compaction :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_file_store(&w, "autoseal")
	given_store_write_options(&w, keep_hot_runs = 0, cold_chunk_runs = 3)

	commits := [7]string{"c00", "c01", "c02", "c03", "c04", "c05", "c06"}
	run_ids := [7]string{"r00", "r01", "r02", "r03", "r04", "r05", "r06"}
	for idx in 0 ..< 7 {
		given_recorded_run(
			&w,
			commit = commits[idx],
			lang = "odin",
			run_id = run_ids[idx],
			bench = Bench_Observation{name = "scan", median_ns = 40.0 + f64(idx) * 2.0},
			timestamp_unix = i64(1770000000 + idx * 60),
		)
	}

	upon_ingesting_run(
		&w,
		commit = "c00",
		lang = "odin",
		run_id = "r00",
		bench = Bench_Observation{name = "scan", median_ns = 99.0},
		timestamp_unix = 1770009999,
	)
	then_store_run_count(&w, 7)

	upon_querying_run(&w, run_id = "r00", lang = "odin")
	if ov, ok := viewing_benchmark(&w, "core::scan"); ok {
		shows_median_ns(&w, ov, 99.0)
	}

	upon_compacting_store(&w, keep_hot_runs = 0)
	then_compaction_shrank_store(&w)
	then_store_run_count(&w, 7)

	upon_querying_run(&w, run_id = "r00", lang = "odin")
	if after_ov, ok := viewing_benchmark(&w, "core::scan"); ok {
		shows_median_ns(&w, after_ov, 99.0)
	}
}

@(test)
spec_core_overlay_ingests_trial_run_without_mutating_disk :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_file_store(&w, "overlay-base")
	given_recorded_run(
		&w,
		commit = "c01",
		lang = "odin",
		run_id = "base01",
		bench = Bench_Observation{name = "get", median_ns = 50.0},
	)
	given_recorded_run(
		&w,
		commit = "c02",
		lang = "odin",
		run_id = "base02",
		bench = Bench_Observation{name = "get", median_ns = 52.0},
	)

	upon_opening_overlay(&w)
	upon_ingesting_into_overlay(
		&w,
		commit = "exp99",
		lang = "odin",
		run_id = "trial01",
		benches = []Bench_Observation{{name = "get", median_ns = 30.0}},
	)

	then_overlay_owns_ram_pages(&w)
	then_store_run_count(&w, 3)

	upon_querying_latest(&w, lang = "odin")
	if trial, ok := viewing_benchmark(&w, "core::get"); ok {
		shows_commit(&w, trial, "exp99")
		shows_median_ns(&w, trial, 30.0)
	}

	then_disk_store_is_unchanged(&w)

	upon_closing_overlay_and_reopening_base(&w)
	then_store_run_count(&w, 2)
	upon_querying_latest(&w, lang = "odin")
	if base, ok := viewing_benchmark(&w, "core::get"); ok {
		shows_commit(&w, base, "c02")
		shows_median_ns(&w, base, 52.0)
	}
}

@(test)
spec_multilang_queries_isolate_languages_without_cross_merging :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_in_memory_store(&w)
	given_recorded_run(
		&w,
		commit = "ml01",
		lang = "odin",
		run_id = "r-o1",
		bench = Bench_Observation{name = "op_a", median_ns = 50.0, footprint_bytes = 1024},
	)
	given_recorded_run(
		&w,
		commit = "ml01",
		lang = "odin",
		run_id = "r-o2",
		bench = Bench_Observation{name = "op_a", median_ns = 50.0, footprint_bytes = 1024},
	)
	given_recorded_run(
		&w,
		commit = "ml01",
		lang = "zig",
		run_id = "r-z1",
		bench = Bench_Observation{name = "op_a", median_ns = 120.0, footprint_bytes = 1024},
	)
	given_recorded_run(
		&w,
		commit = "ml02",
		lang = "odin",
		run_id = "r-o3",
		bench = Bench_Observation{name = "op_a", median_ns = 45.0, footprint_bytes = 1024},
	)
	given_recorded_run(
		&w,
		commit = "ml02",
		lang = "zig",
		run_id = "r-z2",
		bench = Bench_Observation{name = "op_a", median_ns = 115.0, footprint_bytes = 1024},
	)

	upon_querying_commit(&w, commit = "ml01", lang = "")
	then_query_returned_count(&w, 2)
	if odin_ml01, ok := viewing_benchmark(&w, "core::op_a", lang = "odin", commit = "ml01"); ok {
		shows_lang(&w, odin_ml01, "odin")
		shows_run_count(&w, odin_ml01, 2)
		shows_median_ns(&w, odin_ml01, 50.0)
	}
	if zig_ml01, ok := viewing_benchmark(&w, "core::op_a", lang = "zig", commit = "ml01"); ok {
		shows_lang(&w, zig_ml01, "zig")
		shows_run_count(&w, zig_ml01, 1)
		shows_median_ns(&w, zig_ml01, 120.0)
	}

	upon_querying_commit_series(&w, lang = "")
	then_query_returned_count(&w, 4)
	if odin_ml02, ok := viewing_benchmark(&w, "core::op_a", lang = "odin", commit = "ml02"); ok {
		shows_run_count(&w, odin_ml02, 1)
		shows_median_ns(&w, odin_ml02, 45.0)
	}
	if zig_ml02, ok := viewing_benchmark(&w, "core::op_a", lang = "zig", commit = "ml02"); ok {
		shows_run_count(&w, zig_ml02, 1)
		shows_median_ns(&w, zig_ml02, 115.0)
	}

	upon_querying_all_runs(&w, lang = "")
	then_query_returned_count(&w, 5)
}

@(test)
spec_commit_prefix_filter_and_mixed_batch_size_pooling :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_in_memory_store(&w)
	given_recorded_run(
		&w,
		commit = "deadbeefcafebabe",
		lang = "odin",
		run_id = "r-b1",
		benches = []Bench_Observation {
			{name = "get", median_ns = 40.0, ops_per_sample = 100, samples = 16},
			{name = "put", median_ns = 80.0, ops_per_sample = 100, samples = 16},
		},
	)
	given_recorded_run(
		&w,
		commit = "deadbeefcafebabe",
		lang = "odin",
		run_id = "r-b2",
		benches = []Bench_Observation {
			{name = "get", median_ns = 40.0, ops_per_sample = 100, samples = 16},
			{name = "put", median_ns = 80.0, ops_per_sample = 250, samples = 16},
		},
	)

	upon_querying_commit(&w, commit = "deadbeef", lang = "odin", filter = "put")
	then_query_returned_count(&w, 1)
	if v, ok := viewing_benchmark(&w, "core::put"); ok {
		shows_commit(&w, v, "deadbeefcafebabe")
		shows_run_count(&w, v, 2)
		shows_pooled_batches_cleared(&w, v, expected_samples = 32)
	}

	upon_exporting(
		&w,
		.Arrow,
		"mixed-ops-arrow",
		scope = .Snapshot,
		lang = "odin",
		commit = "deadbeef",
		filter = "put",
	)
	then_export_succeeded(&w)
	then_exported_artifact_valid(
		&w,
		"mixed-ops-arrow",
		.Arrow,
		expected_rows = 1,
		expected_cols = 35,
		verify_samples_against_latest = true,
	)
}

@(test)
spec_corrupt_store_file_rejects_compaction_cleanly :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_corrupt_store_file(&w, "corrupt-store")
	upon_compacting_store(&w)
	then_compaction_failed(&w)
}
