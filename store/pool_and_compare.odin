package hugi_store

import obench "../deps/obench/obench"
import hugi "../hugi"
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
	for rid in r.run_ids {
		delete(rid, allocator)
	}
	delete(r.run_ids)
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
	footprint := last.footprint_bytes
	sum_allocs := 0.0
	sum_resizes := 0.0
	sum_alloc_bytes := 0.0
	sum_temp_allocs := 0.0
	sum_temp_bytes := 0.0
	max_peak := last.peak_heap_bytes

	for &rec in g.records {
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
		} else if rec.p50_fs > 0 {
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
	base_samples:     int,
	cand_samples:     int,
	delta_pct:        f64,
	speedup:          f64,
	welch_t:          f64,
	welch_df:         f64,
	used_rank_test:   bool,
	p_value:          f64,
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
	rows:          [dynamic]Comparison_Row,
	improvements:  int,
	regressions:   int,
	unchanged:     int,
	geomean_delta: f64,
}

comparison_report_destroy :: proc(rep: ^Comparison_Report, allocator := context.allocator) {
	for &r in rep.rows {
		delete(r.full_name, allocator)
	}
	delete(rep.rows)
	rep^ = {}
}

@(private)
_Significance_Result :: struct {
	welch_t:        f64,
	welch_df:       f64,
	p_value:        f64,
	used_rank_test: bool,
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
	stat_diff := welch_sig
	if used_rank {
		a_f64 := _samples_fs_as_f64(samples_a, context.temp_allocator)
		b_f64 := _samples_fs_as_f64(samples_b, context.temp_allocator)
		_, _, p_val = obench.mann_whitney_u(a_f64, b_f64, context.temp_allocator)
		delete(a_f64, context.temp_allocator)
		delete(b_f64, context.temp_allocator)
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
		used_rank_test = used_rank,
		stat_diff = stat_diff,
	}
}

/*
Compares two pooled record sets using Mann-Whitney U (`p < 0.05` when both sides have >= 2
samples) alongside Welch's `t`-test with Student's `t` critical values (never hardcoded normal `z`).
*/
@(require_results)
compare_records :: proc(
	base: []Pooled_Record,
	cand: []Pooled_Record,
	threshold_pct := 5.0,
	allocator := context.allocator,
) -> Comparison_Report {
	rep := Comparison_Report {
		rows = make([dynamic]Comparison_Row, allocator),
	}

	cand_by_name := make(map[string]Pooled_Record, context.temp_allocator)
	defer delete(cand_by_name)
	for c in cand {
		cand_by_name[c.full_name] = c
	}

	log_sum := 0.0
	log_cnt := 0

	for b in base {
		c, matched := cand_by_name[b.full_name]
		if !matched || b.p50_fs <= 0 || c.p50_fs <= 0 {
			continue
		}

		delta_pct := (f64(c.p50_fs - b.p50_fs) / f64(b.p50_fs)) * 100.0
		speedup := f64(b.p50_fs) / f64(c.p50_fs)
		sig := _compare_significance(
			c.mean_fs,
			c.std_dev_fs,
			c.samples,
			c.samples_fs[:],
			b.mean_fs,
			b.std_dev_fs,
			b.samples,
			b.samples_fs[:],
		)

		is_sig := sig.stat_diff && abs(delta_pct) >= threshold_pct
		verdict := Verdict.Unchanged
		if is_sig && delta_pct < 0 {
			verdict = .Faster
			rep.improvements += 1
		} else if is_sig && delta_pct > 0 {
			verdict = .Regression
			rep.regressions += 1
		} else {
			rep.unchanged += 1
		}

		ratio := f64(c.p50_fs) / f64(b.p50_fs)
		if ratio > 0 {
			log_sum += math.ln(ratio)
			log_cnt += 1
		}

		append(
			&rep.rows,
			Comparison_Row {
				full_name = strings.clone(b.full_name, allocator),
				base_p50_fs = b.p50_fs,
				cand_p50_fs = c.p50_fs,
				base_std_fs = b.std_dev_fs,
				cand_std_fs = c.std_dev_fs,
				base_samples = b.samples,
				cand_samples = c.samples,
				delta_pct = delta_pct,
				speedup = speedup,
				welch_t = sig.welch_t,
				welch_df = sig.welch_df,
				used_rank_test = sig.used_rank_test,
				p_value = sig.p_value,
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
	rows:                 [dynamic]Cross_Lang_Row,
	a_wins:               int,
	b_wins:               int,
	ties:                 int,
	footprint_mismatches: int,
	only_in_a:            [dynamic]string,
	only_in_b:            [dynamic]string,
}

cross_lang_report_destroy :: proc(rep: ^Cross_Lang_Report, allocator := context.allocator) {
	delete(rep.lang_a, allocator)
	delete(rep.lang_b, allocator)
	for &r in rep.rows {
		delete(r.full_name, allocator)
		delete(r.faster_lang, allocator)
	}
	delete(rep.rows)
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

	for a in rows_a {
		b, ok := map_b[a.full_name]
		if !ok {
			append(&rep.only_in_a, strings.clone(a.full_name, allocator))
			continue
		}
		seen_b[a.full_name] = true

		a_med := f64(max(a.p50_fs, 1))
		b_med := f64(max(b.p50_fs, 1))
		sig := _compare_significance(
			a.mean_fs,
			a.std_dev_fs,
			a.samples,
			a.samples_fs[:],
			b.mean_fs,
			b.std_dev_fs,
			b.samples,
			b.samples_fs[:],
		)

		rel_diff := abs(a_med - b_med) / min(a_med, b_med) * 100.0
		is_sig := sig.stat_diff && rel_diff >= threshold_pct

		faster := "tie"
		ratio := 1.0
		if rel_diff < 0.5 {
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
				welch_t = sig.welch_t,
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
	return rep
}
