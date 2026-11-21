package hugi_store

import obench "../deps/obench/obench"
import hugi "../hugi"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"

Pooled_Record :: struct {
	rank:               int,
	commit:             string,
	lang:               string,
	suite_name:         string,
	group_name:         string,
	name:               string,
	full_name:          string,
	run_count:          int,
	run_ids:            [dynamic]string,
	timestamp_unix:     i64,
	env:                hugi.Run_Env,
	env_mixed:          bool,
	ops_per_sample:     u64,
	samples:            int,
	min_fs:             i64,
	p25_fs:             i64,
	p50_fs:             i64,
	p75_fs:             i64,
	p95_fs:             i64,
	p99_fs:             i64,
	max_fs:             i64,
	mean_fs:            i64,
	std_dev_fs:         i64,
	ci95_fs:            i64,
	cv_pct:             f64,
	iqr_fs:             i64,
	mad_fs:             i64,
	median_cycles:      f64,
	bytes_per_op:       u64,
	mb_per_sec:         f64,
	ops_per_sec:        f64,
	footprint_bytes:    u64,
	allocs_per_op:      f64,
	resizes_per_op:     f64,
	alloc_bytes_per_op: f64,
	temp_allocs_per_op: f64,
	temp_bytes_per_op:  f64,
	peak_heap_bytes:    i64,
	autocorrelation:    f64,
	effective_samples:  f64,
	trend_pct:          f64,
	modes:              int,
	run_medians_fs:     [dynamic]i64,
	metrics:            [dynamic]hugi.Metric,
	samples_fs:         [dynamic]i64,
	samples_batch_ns:   [dynamic]u64,
}

pooled_record_destroy :: proc(r: ^Pooled_Record, allocator := context.allocator) {
	if r == nil {
		return
	}
	delete(r.commit, allocator)
	delete(r.lang, allocator)
	delete(r.suite_name, allocator)
	delete(r.group_name, allocator)
	delete(r.name, allocator)
	delete(r.full_name, allocator)
	hugi.run_env_destroy(&r.env, allocator)
	for rid in r.run_ids {
		delete(rid, allocator)
	}
	delete(r.run_ids)
	delete(r.run_medians_fs)
	for m in r.metrics {
		delete(m.unit, allocator)
	}
	delete(r.metrics)
	delete(r.samples_fs)
	delete(r.samples_batch_ns)
	r^ = {}
}

pooled_records_destroy :: proc(list: []Pooled_Record, allocator := context.allocator) {
	for &r in list {
		pooled_record_destroy(&r, allocator)
	}
	delete(list, allocator)
}

@(private = "file")
_samples_fs_as_f64 :: proc(src: []i64, allocator := context.temp_allocator) -> []f64 {
	out := make([]f64, len(src), allocator)
	for v, i in src {
		out[i] = f64(v)
	}
	return out
}

@(private = "file", require_results)
_pool_raw_group :: proc(g: ^_Raw_Group, allocator := context.allocator) -> Pooled_Record {
	last := g.records[len(g.records) - 1]
	first_ops := g.records[0].ops_per_sample
	same_ops := true
	pooled_fs := make([dynamic]i64, allocator)
	pooled_batches := make([dynamic]u64, allocator)
	run_medians := make([dynamic]i64, 0, len(g.records), allocator)
	footprint := last.footprint_bytes
	sum_allocs := 0.0
	sum_resizes := 0.0
	sum_alloc_bytes := 0.0
	sum_temp_allocs := 0.0
	sum_temp_bytes := 0.0
	max_peak := last.peak_heap_bytes

	for &rec in g.records {
		if rec.p50_fs > 0 || rec.samples > 0 {
			append(&run_medians, rec.p50_fs)
		}
		if rec.ops_per_sample != first_ops {
			same_ops = false
		}
		if len(rec.samples_batch_ns) > 0 {
			ops := max(rec.ops_per_sample, 1)
			for b in rec.samples_batch_ns {
				append(&pooled_fs, hugi.batch_ns_to_op_fs(b, ops))
			}
			if same_ops {
				append(&pooled_batches, ..rec.samples_batch_ns[:])
			}
		} else if len(g.records) > 1 && rec.p50_fs > 0 {
			append(&pooled_fs, rec.p50_fs)
			same_ops = false
		}
		if rec.footprint_bytes > footprint {
			footprint = rec.footprint_bytes
		}
		if rec.peak_heap_bytes > max_peak {
			max_peak = rec.peak_heap_bytes
		}
		sum_allocs += rec.allocs_per_op
		sum_resizes += rec.resizes_per_op
		sum_alloc_bytes += rec.alloc_bytes_per_op
		sum_temp_allocs += rec.temp_allocs_per_op
		sum_temp_bytes += rec.temp_bytes_per_op
	}
	if !same_ops {
		clear(&pooled_batches)
	}

	n_recs := f64(len(g.records))
	run_ids := make([dynamic]string, len(g.run_ids), allocator)
	for rid, i in g.run_ids {
		run_ids[i] = strings.clone(rid, allocator)
	}

	metrics := make([dynamic]hugi.Metric, len(last.metrics), allocator)
	for m, i in last.metrics {
		metrics[i] = hugi.Metric {
			unit  = strings.clone(m.unit, allocator),
			value = m.value,
		}
	}

	pr := Pooled_Record {
		rank               = last.rank,
		commit             = strings.clone(g.commit, allocator),
		lang               = strings.clone(g.lang, allocator),
		suite_name         = strings.clone(g.suite_name, allocator),
		group_name         = strings.clone(last.group_name, allocator),
		name               = strings.clone(last.name, allocator),
		full_name          = strings.clone(g.full_name, allocator),
		run_count          = len(g.run_ids),
		run_ids            = run_ids,
		timestamp_unix     = g.timestamp_unix,
		env                = hugi.run_env_clone(g.env, allocator),
		env_mixed          = g.env_mixed,
		ops_per_sample     = last.ops_per_sample,
		bytes_per_op       = last.bytes_per_op,
		mb_per_sec         = last.mb_per_sec,
		median_cycles      = last.median_cycles,
		footprint_bytes    = footprint,
		allocs_per_op      = sum_allocs / n_recs,
		resizes_per_op     = sum_resizes / n_recs,
		alloc_bytes_per_op = sum_alloc_bytes / n_recs,
		temp_allocs_per_op = sum_temp_allocs / n_recs,
		temp_bytes_per_op  = sum_temp_bytes / n_recs,
		peak_heap_bytes    = max_peak,
		modes              = 1,
		run_medians_fs     = run_medians,
		metrics            = metrics,
		samples_fs         = pooled_fs,
		samples_batch_ns   = pooled_batches,
	}

	if len(pr.samples_fs) > 0 {
		st := hugi.compute_stats_fs(pr.samples_fs[:], context.temp_allocator)
		pr.samples = st.samples
		pr.min_fs = st.min_fs
		pr.p25_fs = st.p25_fs
		pr.p50_fs = st.p50_fs
		pr.p75_fs = st.p75_fs
		pr.p95_fs = st.p95_fs
		pr.p99_fs = st.p99_fs
		pr.max_fs = st.max_fs
		pr.mean_fs = st.mean_fs
		pr.std_dev_fs = st.std_dev_fs
		pr.ci95_fs = st.ci95_fs
		pr.cv_pct = st.cv_pct
		pr.iqr_fs = st.iqr_fs
		pr.mad_fs = st.mad_fs

		samples_f64 := _samples_fs_as_f64(pr.samples_fs[:], context.temp_allocator)
		defer delete(samples_f64, context.temp_allocator)
		pr.autocorrelation = obench.lag1_autocorrelation(samples_f64)
		pr.effective_samples = obench.effective_sample_count(len(samples_f64), pr.autocorrelation)
		trend, trend_z := obench.sample_trend(samples_f64, context.temp_allocator)
		if abs(trend_z) > 2.576 && abs(trend) >= obench.TREND_MIN_PCT {
			pr.trend_pct = trend
		}
		pr.modes = obench.count_modes(samples_f64, context.temp_allocator)

		if pr.p50_fs > 0 {
			ops_s, _, mb_s := hugi.compute_throughput_from_p50(pr.p50_fs, pr.bytes_per_op)
			pr.ops_per_sec = ops_s
			if pr.bytes_per_op > 0 {
				pr.mb_per_sec = mb_s
			}
		}
	} else {
		pr.samples = last.samples
		pr.min_fs = last.min_fs
		pr.p25_fs = last.p25_fs
		pr.p50_fs = last.p50_fs
		pr.p75_fs = last.p75_fs
		pr.p95_fs = last.p95_fs
		pr.p99_fs = last.p99_fs
		pr.max_fs = last.max_fs
		pr.mean_fs = last.mean_fs
		pr.std_dev_fs = last.std_dev_fs
		pr.ci95_fs = last.ci95_fs
		pr.cv_pct = last.cv_pct
		pr.iqr_fs = last.iqr_fs
		pr.mad_fs = last.mad_fs
		pr.ops_per_sec = last.items_per_sec
		if pr.ops_per_sec <= 0 && pr.p50_fs > 0 {
			ops_s, _, mb_s := hugi.compute_throughput_from_p50(pr.p50_fs, pr.bytes_per_op)
			pr.ops_per_sec = ops_s
			if pr.bytes_per_op > 0 && pr.mb_per_sec <= 0 {
				pr.mb_per_sec = mb_s
			}
		}
	}

	return pr
}

@(private = "file", require_results)
_pool_raw_groups :: proc(
	raw_groups: []_Raw_Group,
	allocator := context.allocator,
) -> []Pooled_Record {
	out := make([dynamic]Pooled_Record, 0, len(raw_groups), allocator)
	for &g in raw_groups {
		if len(g.records) == 0 {
			continue
		}
		append(&out, _pool_raw_group(&g, allocator))
	}
	return out[:]
}

/*
Pools all per-op durations (`samples_fs`, plus `samples_batch_ns` when `ops_per_sample` matches
across runs) across matching runs in `st` and computes unified quantile, dispersion, throughput,
allocation, and footprint metrics per benchmark.
*/
@(require_results)
store_load_pooled_records :: proc(
	st: ^Store,
	lang := "odin",
	commit := "",
	run_id := "",
	filter := "",
	allocator := context.allocator,
) -> []Pooled_Record {
	raw_groups := store_load_raw_groups(st, lang, commit, run_id, filter, context.temp_allocator)
	defer _raw_groups_destroy(raw_groups, context.temp_allocator)
	return _pool_raw_groups(raw_groups, allocator)
}

/*
Loads longitudinal commit-by-commit pooled records in chronological commit order for `lang`.
*/
@(require_results)
store_load_commit_series_records :: proc(
	st: ^Store,
	lang := "odin",
	filter := "",
	allocator := context.allocator,
) -> []Pooled_Record {
	raw_groups := _store_load_commit_series_raw_groups(st, lang, filter, context.temp_allocator)
	defer _raw_groups_destroy(raw_groups, context.temp_allocator)
	return _pool_raw_groups(raw_groups, allocator)
}

/*
Loads every individual benchmark run chronologically as its own unpooled `Pooled_Record` (`run_count == 1`).
*/
@(require_results)
store_load_all_run_records :: proc(
	st: ^Store,
	lang := "odin",
	filter := "",
	allocator := context.allocator,
) -> []Pooled_Record {
	raw_groups := _store_load_all_run_raw_groups(st, lang, filter, context.temp_allocator)
	defer _raw_groups_destroy(raw_groups, context.temp_allocator)
	return _pool_raw_groups(raw_groups, allocator)
}

Verdict :: enum u8 {
	Unchanged,
	Faster,
	Regression,
}

Comparison_Row :: struct {
	full_name:        string,
	base_p50_fs:      i64,
	cand_p50_fs:      i64,
	base_std_fs:      i64,
	cand_std_fs:      i64,
	base_cv_pct:      f64,
	cand_cv_pct:      f64,
	base_samples:     int,
	cand_samples:     int,
	underpowered:     bool,
	delta_pct:        f64,
	speedup:          f64,
	welch_t:          f64,
	welch_df:         f64,
	used_rank_test:   bool,
	p_value:          f64,
	shift_pct:        f64,
	shift_low_pct:    f64,
	shift_high_pct:   f64,
	used_shift_ci:    bool,
	used_run_medians: bool,
	base_trend_pct:   f64,
	cand_trend_pct:   f64,
	base_modes:       int,
	cand_modes:       int,
	is_significant:   bool,
	verdict:          Verdict,
	base_allocs:      f64,
	cand_allocs:      f64,
	base_alloc_bytes: f64,
	cand_alloc_bytes: f64,
	base_footprint:   u64,
	cand_footprint:   u64,
}

Comparison_Report :: struct {
	rows:              [dynamic]Comparison_Row,
	improvements:      int,
	regressions:       int,
	unchanged:         int,
	geomean_delta:     f64,
	underpowered_rows: int,
	high_cv_rows:      int,
	drifting_rows:     int,
	multimodal_rows:   int,
	base_env:          hugi.Run_Env,
	cand_env:          hugi.Run_Env,
	warnings:          [dynamic]string,
}

comparison_report_destroy :: proc(rep: ^Comparison_Report, allocator := context.allocator) {
	for &r in rep.rows {
		delete(r.full_name, allocator)
	}
	delete(rep.rows)
	for w in rep.warnings {
		delete(w, allocator)
	}
	delete(rep.warnings)
	hugi.run_env_destroy(&rep.base_env, allocator)
	hugi.run_env_destroy(&rep.cand_env, allocator)
	rep^ = {}
}

@(private = "file")
_env_differs_core :: proc "contextless" (a, b: hugi.Run_Env) -> bool {
	if hugi.run_env_is_empty(a) || hugi.run_env_is_empty(b) {
		return false
	}
	return(
		a.cpu_model != b.cpu_model ||
		a.scaling_max_khz != b.scaling_max_khz ||
		a.build_flags != b.build_flags \
	)
}

@(private = "file")
_collect_comparison_warnings :: proc(
	warnings: ^[dynamic]string,
	label_a, label_b: string,
	a_env, b_env: hugi.Run_Env,
	a_mixed, b_mixed: bool,
	a_commit, b_commit: string,
	check_build_flags: bool,
	total_rows, underpowered_rows, high_cv_rows, drifting_rows, multimodal_rows: int,
	allocator: runtime.Allocator,
) {
	if total_rows <= 0 {
		return
	}
	a_empty := hugi.run_env_is_empty(a_env)
	b_empty := hugi.run_env_is_empty(b_env)

	if a_env.cpu_model != "" && b_env.cpu_model != "" && a_env.cpu_model != b_env.cpu_model {
		append(
			warnings,
			fmt.aprintf(
				"CPU model mismatch: %s (%q) vs %s (%q)",
				label_a,
				a_env.cpu_model,
				label_b,
				b_env.cpu_model,
				allocator = allocator,
			),
		)
	}

	if a_env.scaling_max_khz > 0 && b_env.scaling_max_khz > 0 {
		hi := max(a_env.scaling_max_khz, b_env.scaling_max_khz)
		lo := min(a_env.scaling_max_khz, b_env.scaling_max_khz)
		if (hi - lo) * 100 > hi * 5 {
			append(
				warnings,
				fmt.aprintf(
					"CPU scaling_max_freq mismatch: %.2f GHz vs %.2f GHz (timings are not directly comparable)",
					f64(a_env.scaling_max_khz) / 1_000_000.0,
					f64(b_env.scaling_max_khz) / 1_000_000.0,
					allocator = allocator,
				),
			)
		}
	}

	if a_env.scaling_max_khz > 0 &&
	   a_env.cpuinfo_max_khz > 0 &&
	   a_env.scaling_max_khz * 100 < a_env.cpuinfo_max_khz * 95 {
		append(
			warnings,
			fmt.aprintf(
				"%s ran with clamped CPU scaling_max_freq (%.2f/%.2f GHz)",
				label_a,
				f64(a_env.scaling_max_khz) / 1_000_000.0,
				f64(a_env.cpuinfo_max_khz) / 1_000_000.0,
				allocator = allocator,
			),
		)
	}
	if b_env.scaling_max_khz > 0 &&
	   b_env.cpuinfo_max_khz > 0 &&
	   b_env.scaling_max_khz * 100 < b_env.cpuinfo_max_khz * 95 {
		append(
			warnings,
			fmt.aprintf(
				"%s ran with clamped CPU scaling_max_freq (%.2f/%.2f GHz)",
				label_b,
				f64(b_env.scaling_max_khz) / 1_000_000.0,
				f64(b_env.cpuinfo_max_khz) / 1_000_000.0,
				allocator = allocator,
			),
		)
	}

	if a_env.governor != "" && b_env.governor != "" && a_env.governor != b_env.governor {
		append(
			warnings,
			fmt.aprintf(
				"CPU scaling_governor mismatch: %s (%s) vs %s (%s)",
				label_a,
				a_env.governor,
				label_b,
				b_env.governor,
				allocator = allocator,
			),
		)
	}

	if check_build_flags &&
	   a_env.build_flags != "" &&
	   b_env.build_flags != "" &&
	   a_env.build_flags != b_env.build_flags {
		append(
			warnings,
			fmt.aprintf(
				"Build flags mismatch: %s (%s) vs %s (%s)",
				label_a,
				a_env.build_flags,
				label_b,
				b_env.build_flags,
				allocator = allocator,
			),
		)
	}

	if a_mixed {
		append(
			warnings,
			fmt.aprintf(
				"%s pooled runs with mixed CPU/clock/build environments",
				label_a,
				allocator = allocator,
			),
		)
	}
	if b_mixed {
		append(
			warnings,
			fmt.aprintf(
				"%s pooled runs with mixed CPU/clock/build environments",
				label_b,
				allocator = allocator,
			),
		)
	}

	if a_empty != b_empty {
		missing_label := a_empty ? label_a : label_b
		append(
			warnings,
			fmt.aprintf(
				"%s has no recorded host/build provenance (legacy run; clock/CPU comparability unverified)",
				missing_label,
				allocator = allocator,
			),
		)
	}

	if a_commit != "" && b_commit != "" && a_commit != b_commit {
		append(
			warnings,
			fmt.aprintf(
				"Cross-language commit mismatch: %s at %s vs %s at %s",
				label_a,
				a_commit,
				label_b,
				b_commit,
				allocator = allocator,
			),
		)
	}

	if underpowered_rows > 0 {
		append(
			warnings,
			fmt.aprintf(
				"%d/%d benchmark(s) have < 5 samples per side (Mann-Whitney U cannot reach p < 0.05 below n=4; run with --runs 7+)",
				underpowered_rows,
				total_rows,
				allocator = allocator,
			),
		)
	}

	if high_cv_rows > 0 {
		append(
			warnings,
			fmt.aprintf(
				"%d/%d benchmark(s) have high variance (CV > 25%%); medians and verdicts may be noisy",
				high_cv_rows,
				total_rows,
				allocator = allocator,
			),
		)
	}

	if drifting_rows > 0 {
		append(
			warnings,
			fmt.aprintf(
				"%d/%d benchmark(s) show significant sample drift over the run (possible thermal throttling or warmup drift)",
				drifting_rows,
				total_rows,
				allocator = allocator,
			),
		)
	}

	if multimodal_rows > 0 {
		append(
			warnings,
			fmt.aprintf(
				"%d/%d benchmark(s) have multimodal sample distributions (>= 2 peaks); check CPU pinning or bimodal paths",
				multimodal_rows,
				total_rows,
				allocator = allocator,
			),
		)
	}
}

@(private)
_Significance_Result :: struct {
	welch_t:        f64,
	welch_df:       f64,
	p_value:        f64,
	shift_pct:      f64,
	shift_low_pct:  f64,
	shift_high_pct: f64,
	used_rank_test: bool,
	used_shift_ci:  bool,
	stat_diff:      bool,
}

@(private, require_results)
_compare_significance :: proc(
	mean_a, std_a: i64,
	n_a: int,
	samples_a: []i64,
	mean_b, std_b: i64,
	n_b: int,
	samples_b: []i64,
) -> _Significance_Result {
	wt, wdf := obench.welch_test(f64(mean_a), f64(std_a), n_a, f64(mean_b), f64(std_b), n_b)
	welch_sig := wdf > 0 && abs(wt) >= obench.t_critical_975(wdf)

	used_rank := len(samples_a) >= 2 && len(samples_b) >= 2
	p_val := 1.0
	shift_pct, shift_low_pct, shift_high_pct := 0.0, 0.0, 0.0
	used_shift_ci := false
	stat_diff := welch_sig
	if used_rank {
		a_f64 := _samples_fs_as_f64(samples_a, context.temp_allocator)
		b_f64 := _samples_fs_as_f64(samples_b, context.temp_allocator)
		defer delete(a_f64, context.temp_allocator)
		defer delete(b_f64, context.temp_allocator)
		_, _, p_val = obench.mann_whitney_u(a_f64, b_f64, context.temp_allocator)
		shift, low, high, shift_ok := obench.hodges_lehmann_shift(
			a_f64,
			b_f64,
			adjust_for_autocorrelation = true,
			allocator = context.temp_allocator,
		)
		if shift_ok {
			shift_pct = shift
			shift_low_pct = low
			shift_high_pct = high
		}
		used_shift_ci = shift_ok && len(samples_a) >= 4 && len(samples_b) >= 4
		if len(samples_a) >= 5 && len(samples_b) >= 5 {
			stat_diff = p_val < 0.05
		} else {
			stat_diff = p_val < 0.05 || welch_sig
		}
	}

	return _Significance_Result {
		welch_t = wt,
		welch_df = wdf,
		p_value = p_val,
		shift_pct = shift_pct,
		shift_low_pct = shift_low_pct,
		shift_high_pct = shift_high_pct,
		used_rank_test = used_rank,
		used_shift_ci = used_shift_ci,
		stat_diff = stat_diff,
	}
}

/*
Compares two pooled record sets using the 95% confidence interval of the Hodges-Lehmann
location shift (Mann-Whitney U inversion with autocorrelation adjustment when both sides have
>= 4 samples), falling back to Welch's `t`-test with Student's `t` critical values for smaller
or summary-only records. When `use_run_medians` is true and both sides have >= 2 runs, each
run's `p50_fs` is compared instead of pooled raw samples.
*/
@(require_results)
compare_records :: proc(
	base: []Pooled_Record,
	cand: []Pooled_Record,
	threshold_pct := 5.0,
	allocator := context.allocator,
	use_run_medians := false,
) -> Comparison_Report {
	rep := Comparison_Report {
		rows     = make([dynamic]Comparison_Row, allocator),
		warnings = make([dynamic]string, allocator),
	}

	cand_by_name := make(map[string]Pooled_Record, context.temp_allocator)
	defer delete(cand_by_name)
	for c in cand {
		cand_by_name[c.full_name] = c
	}

	log_sum := 0.0
	log_cnt := 0
	base_mixed := false
	cand_mixed := false
	run_median_fallbacks := 0

	for b in base {
		c, matched := cand_by_name[b.full_name]
		if !matched ||
		   b.p50_fs < 0 ||
		   c.p50_fs < 0 ||
		   (b.p50_fs == 0 && b.samples <= 0) ||
		   (c.p50_fs == 0 && c.samples <= 0) {
			continue
		}

		base_mixed ||= b.env_mixed
		cand_mixed ||= c.env_mixed
		if !hugi.run_env_is_empty(b.env) {
			if hugi.run_env_is_empty(rep.base_env) {
				rep.base_env = hugi.run_env_clone(b.env, allocator)
			} else if _env_differs_core(rep.base_env, b.env) {
				base_mixed = true
			}
		}
		if !hugi.run_env_is_empty(c.env) {
			if hugi.run_env_is_empty(rep.cand_env) {
				rep.cand_env = hugi.run_env_clone(c.env, allocator)
			} else if _env_differs_core(rep.cand_env, c.env) {
				cand_mixed = true
			}
		}

		row_base_p50_fs := b.p50_fs
		row_cand_p50_fs := c.p50_fs
		row_base_std_fs := b.std_dev_fs
		row_cand_std_fs := c.std_dev_fs
		row_base_cv_pct := b.cv_pct
		row_cand_cv_pct := c.cv_pct
		sig: _Significance_Result
		row_used_run_medians := false
		row_base_samples := b.samples
		row_cand_samples := c.samples
		if use_run_medians && len(b.run_medians_fs) >= 2 && len(c.run_medians_fs) >= 2 {
			b_run_st := hugi.compute_stats_fs(b.run_medians_fs[:], context.temp_allocator)
			c_run_st := hugi.compute_stats_fs(c.run_medians_fs[:], context.temp_allocator)
			row_base_p50_fs = b_run_st.p50_fs
			row_cand_p50_fs = c_run_st.p50_fs
			row_base_std_fs = b_run_st.std_dev_fs
			row_cand_std_fs = c_run_st.std_dev_fs
			row_base_cv_pct = b_run_st.cv_pct
			row_cand_cv_pct = c_run_st.cv_pct
			row_base_samples = len(b.run_medians_fs)
			row_cand_samples = len(c.run_medians_fs)
			sig = _compare_significance(
				c_run_st.mean_fs,
				c_run_st.std_dev_fs,
				row_cand_samples,
				c.run_medians_fs[:],
				b_run_st.mean_fs,
				b_run_st.std_dev_fs,
				row_base_samples,
				b.run_medians_fs[:],
			)
			row_used_run_medians = true
		} else {
			if use_run_medians {
				run_median_fallbacks += 1
			}
			sig = _compare_significance(
				c.mean_fs,
				c.std_dev_fs,
				c.samples,
				c.samples_fs[:],
				b.mean_fs,
				b.std_dev_fs,
				b.samples,
				b.samples_fs[:],
			)
		}

		b_med := f64(max(row_base_p50_fs, 1))
		c_med := f64(max(row_cand_p50_fs, 1))
		delta_pct := (f64(row_cand_p50_fs - row_base_p50_fs) / b_med) * 100.0
		speedup := b_med / c_med

		underpowered := min(row_base_samples, row_cand_samples) < 5
		if underpowered {
			rep.underpowered_rows += 1
		}
		if row_base_cv_pct > 25.0 || row_cand_cv_pct > 25.0 {
			rep.high_cv_rows += 1
		}
		if b.trend_pct != 0 || c.trend_pct != 0 {
			rep.drifting_rows += 1
		}
		if b.modes > 1 || c.modes > 1 {
			rep.multimodal_rows += 1
		}

		is_sig := false
		verdict := Verdict.Unchanged
		if sig.used_shift_ci {
			if sig.shift_low_pct > threshold_pct {
				is_sig = true
				verdict = .Regression
				rep.regressions += 1
			} else if sig.shift_high_pct < -threshold_pct {
				is_sig = true
				verdict = .Faster
				rep.improvements += 1
			} else {
				rep.unchanged += 1
			}
		} else {
			is_sig = sig.stat_diff && abs(delta_pct) >= threshold_pct
			if is_sig && delta_pct < 0 {
				verdict = .Faster
				rep.improvements += 1
			} else if is_sig && delta_pct > 0 {
				verdict = .Regression
				rep.regressions += 1
			} else {
				rep.unchanged += 1
			}
		}

		if row_base_p50_fs > 0 && row_cand_p50_fs > 0 {
			log_sum += math.ln(f64(row_cand_p50_fs) / f64(row_base_p50_fs))
			log_cnt += 1
		} else if row_base_p50_fs == 0 && row_cand_p50_fs == 0 {
			log_cnt += 1
		}

		append(
			&rep.rows,
			Comparison_Row {
				full_name = strings.clone(b.full_name, allocator),
				base_p50_fs = row_base_p50_fs,
				cand_p50_fs = row_cand_p50_fs,
				base_std_fs = row_base_std_fs,
				cand_std_fs = row_cand_std_fs,
				base_cv_pct = row_base_cv_pct,
				cand_cv_pct = row_cand_cv_pct,
				base_samples = row_base_samples,
				cand_samples = row_cand_samples,
				underpowered = underpowered,
				delta_pct = delta_pct,
				speedup = speedup,
				welch_t = sig.welch_t,
				welch_df = sig.welch_df,
				used_rank_test = sig.used_rank_test,
				p_value = sig.p_value,
				shift_pct = sig.shift_pct,
				shift_low_pct = sig.shift_low_pct,
				shift_high_pct = sig.shift_high_pct,
				used_shift_ci = sig.used_shift_ci,
				used_run_medians = row_used_run_medians,
				base_trend_pct = b.trend_pct,
				cand_trend_pct = c.trend_pct,
				base_modes = b.modes,
				cand_modes = c.modes,
				is_significant = is_sig,
				verdict = verdict,
				base_allocs = b.allocs_per_op,
				cand_allocs = c.allocs_per_op,
				base_alloc_bytes = b.alloc_bytes_per_op,
				cand_alloc_bytes = c.alloc_bytes_per_op,
				base_footprint = b.footprint_bytes,
				cand_footprint = c.footprint_bytes,
			},
		)
	}

	if log_cnt > 0 {
		rep.geomean_delta = (math.exp(log_sum / f64(log_cnt)) - 1.0) * 100.0
	}
	_collect_comparison_warnings(
		&rep.warnings,
		"Baseline",
		"Candidate",
		rep.base_env,
		rep.cand_env,
		base_mixed,
		cand_mixed,
		"",
		"",
		check_build_flags = true,
		total_rows = len(rep.rows),
		underpowered_rows = rep.underpowered_rows,
		high_cv_rows = rep.high_cv_rows,
		drifting_rows = rep.drifting_rows,
		multimodal_rows = rep.multimodal_rows,
		allocator = allocator,
	)
	if use_run_medians && run_median_fallbacks > 0 && len(rep.rows) > 0 {
		append(
			&rep.warnings,
			fmt.aprintf(
				"%d/%d benchmark(s) had < 2 runs per side; fell back to pooled sample comparison for --by-run",
				run_median_fallbacks,
				len(rep.rows),
				allocator = allocator,
			),
		)
	}
	return rep
}

Cross_Lang_Row :: struct {
	full_name:          string,
	ops:                u64,
	a_p50_fs:           i64,
	a_std_fs:           i64,
	a_cv_pct:           f64,
	b_p50_fs:           i64,
	b_std_fs:           i64,
	b_cv_pct:           f64,
	faster_lang:        string, // `lang_a`, `lang_b`, or `"tie"`
	speedup_ratio:      f64,
	is_significant:     bool,
	p_value:            f64,
	shift_pct:          f64,
	shift_low_pct:      f64,
	shift_high_pct:     f64,
	used_shift_ci:      bool,
	welch_t:            f64,
	a_footprint:        u64,
	b_footprint:        u64,
	footprint_mismatch: bool,
	a_allocs:           f64,
	b_allocs:           f64,
}

Cross_Lang_Report :: struct {
	lang_a:               string,
	lang_b:               string,
	a_commit:             string,
	b_commit:             string,
	rows:                 [dynamic]Cross_Lang_Row,
	a_wins:               int,
	b_wins:               int,
	ties:                 int,
	footprint_mismatches: int,
	underpowered_rows:    int,
	high_cv_rows:         int,
	drifting_rows:        int,
	multimodal_rows:      int,
	a_env:                hugi.Run_Env,
	b_env:                hugi.Run_Env,
	warnings:             [dynamic]string,
	only_in_a:            [dynamic]string,
	only_in_b:            [dynamic]string,
}

cross_lang_report_destroy :: proc(rep: ^Cross_Lang_Report, allocator := context.allocator) {
	delete(rep.lang_a, allocator)
	delete(rep.lang_b, allocator)
	delete(rep.a_commit, allocator)
	delete(rep.b_commit, allocator)
	for &r in rep.rows {
		delete(r.full_name, allocator)
		delete(r.faster_lang, allocator)
	}
	delete(rep.rows)
	for w in rep.warnings {
		delete(w, allocator)
	}
	delete(rep.warnings)
	hugi.run_env_destroy(&rep.a_env, allocator)
	hugi.run_env_destroy(&rep.b_env, allocator)
	for s in rep.only_in_a {
		delete(s, allocator)
	}
	delete(rep.only_in_a)
	for s in rep.only_in_b {
		delete(s, allocator)
	}
	delete(rep.only_in_b)
	rep^ = {}
}

/*
Performs a 1v1 cross-language statistical comparison (`lang_a` vs `lang_b`) inside `st`.
*/
@(require_results)
compare_1v1_langs :: proc(
	st: ^Store,
	lang_a := "odin",
	lang_b := "zig",
	commit := "",
	threshold_pct := 3.0,
	allocator := context.allocator,
) -> Cross_Lang_Report {
	rep := Cross_Lang_Report {
		lang_a    = strings.clone(lang_a, allocator),
		lang_b    = strings.clone(lang_b, allocator),
		rows      = make([dynamic]Cross_Lang_Row, allocator),
		warnings  = make([dynamic]string, allocator),
		only_in_a = make([dynamic]string, allocator),
		only_in_b = make([dynamic]string, allocator),
	}

	rows_a := store_load_pooled_records(st, lang_a, commit, "", "", context.temp_allocator)
	defer pooled_records_destroy(rows_a, context.temp_allocator)
	rows_b := store_load_pooled_records(st, lang_b, commit, "", "", context.temp_allocator)
	defer pooled_records_destroy(rows_b, context.temp_allocator)

	map_b := make(map[string]Pooled_Record, context.temp_allocator)
	defer delete(map_b)
	for b in rows_b {
		map_b[b.full_name] = b
	}
	seen_b := make(map[string]bool, context.temp_allocator)
	defer delete(seen_b)

	a_mixed := false
	b_mixed := false
	saw_commit_mismatch := false

	for a in rows_a {
		b, ok := map_b[a.full_name]
		if !ok {
			append(&rep.only_in_a, strings.clone(a.full_name, allocator))
			continue
		}
		seen_b[a.full_name] = true

		a_mixed ||= a.env_mixed
		b_mixed ||= b.env_mixed
		if !hugi.run_env_is_empty(a.env) {
			if hugi.run_env_is_empty(rep.a_env) {
				rep.a_env = hugi.run_env_clone(a.env, allocator)
			} else if _env_differs_core(rep.a_env, a.env) {
				a_mixed = true
			}
		}
		if !hugi.run_env_is_empty(b.env) {
			if hugi.run_env_is_empty(rep.b_env) {
				rep.b_env = hugi.run_env_clone(b.env, allocator)
			} else if _env_differs_core(rep.b_env, b.env) {
				b_mixed = true
			}
		}

		if a.commit != "" && b.commit != "" && a.commit != b.commit && !saw_commit_mismatch {
			delete(rep.a_commit, allocator)
			delete(rep.b_commit, allocator)
			rep.a_commit = strings.clone(a.commit, allocator)
			rep.b_commit = strings.clone(b.commit, allocator)
			saw_commit_mismatch = true
		} else {
			if rep.a_commit == "" && a.commit != "" {
				rep.a_commit = strings.clone(a.commit, allocator)
			}
			if rep.b_commit == "" && b.commit != "" {
				rep.b_commit = strings.clone(b.commit, allocator)
			}
		}

		if min(a.samples, b.samples) < 5 {
			rep.underpowered_rows += 1
		}
		if a.cv_pct > 25.0 || b.cv_pct > 25.0 {
			rep.high_cv_rows += 1
		}
		if a.trend_pct != 0 || b.trend_pct != 0 {
			rep.drifting_rows += 1
		}
		if a.modes > 1 || b.modes > 1 {
			rep.multimodal_rows += 1
		}

		a_med := f64(max(a.p50_fs, 1))
		b_med := f64(max(b.p50_fs, 1))
		sig: _Significance_Result
		welch_t := 0.0
		if a_med <= b_med {
			sig = _compare_significance(
				b.mean_fs,
				b.std_dev_fs,
				b.samples,
				b.samples_fs[:],
				a.mean_fs,
				a.std_dev_fs,
				a.samples,
				a.samples_fs[:],
			)
			welch_t = sig.welch_t == 0 ? 0.0 : -sig.welch_t
		} else {
			sig = _compare_significance(
				a.mean_fs,
				a.std_dev_fs,
				a.samples,
				a.samples_fs[:],
				b.mean_fs,
				b.std_dev_fs,
				b.samples,
				b.samples_fs[:],
			)
			welch_t = sig.welch_t
		}

		hl_shift, hl_low, hl_high := sig.shift_pct, sig.shift_low_pct, sig.shift_high_pct
		hl_used_ci := sig.used_shift_ci

		rel_diff := abs(a_med - b_med) / min(a_med, b_med) * 100.0
		is_sig :=
			hl_low > threshold_pct if hl_used_ci else (sig.stat_diff && rel_diff >= threshold_pct)

		faster := "tie"
		ratio := 1.0
		if rel_diff < 0.5 {
			is_sig = false
			rep.ties += 1
		} else if a_med < b_med {
			faster = lang_a
			ratio = b_med / a_med
			rep.a_wins += 1
		} else {
			faster = lang_b
			ratio = a_med / b_med
			rep.b_wins += 1
		}

		fp_mismatch :=
			a.footprint_bytes > 0 &&
			b.footprint_bytes > 0 &&
			a.footprint_bytes != b.footprint_bytes
		if fp_mismatch {
			rep.footprint_mismatches += 1
		}

		append(
			&rep.rows,
			Cross_Lang_Row {
				full_name = strings.clone(a.full_name, allocator),
				ops = a.ops_per_sample,
				a_p50_fs = a.p50_fs,
				a_std_fs = a.std_dev_fs,
				a_cv_pct = a.cv_pct,
				b_p50_fs = b.p50_fs,
				b_std_fs = b.std_dev_fs,
				b_cv_pct = b.cv_pct,
				faster_lang = strings.clone(faster, allocator),
				speedup_ratio = ratio,
				is_significant = is_sig,
				p_value = sig.p_value,
				shift_pct = hl_shift,
				shift_low_pct = hl_low,
				shift_high_pct = hl_high,
				used_shift_ci = hl_used_ci,
				welch_t = welch_t,
				a_footprint = a.footprint_bytes,
				b_footprint = b.footprint_bytes,
				footprint_mismatch = fp_mismatch,
				a_allocs = a.allocs_per_op,
				b_allocs = b.allocs_per_op,
			},
		)
	}

	for b in rows_b {
		if b.full_name not_in seen_b {
			append(&rep.only_in_b, strings.clone(b.full_name, allocator))
		}
	}

	_collect_comparison_warnings(
		&rep.warnings,
		lang_a,
		lang_b,
		rep.a_env,
		rep.b_env,
		a_mixed,
		b_mixed,
		rep.a_commit,
		rep.b_commit,
		check_build_flags = false,
		total_rows = len(rep.rows),
		underpowered_rows = rep.underpowered_rows,
		high_cv_rows = rep.high_cv_rows,
		drifting_rows = rep.drifting_rows,
		multimodal_rows = rep.multimodal_rows,
		allocator = allocator,
	)
	return rep
}
