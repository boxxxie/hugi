package bench_store

import bench "../bench"
import obench "../deps/obench/obench"
import "core:math"
import "core:slice"
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
	ops_per_sample:     u64,
	samples:            int,
	min_ns:             f64,
	p25_ns:             f64,
	p50_ns:             f64,
	p75_ns:             f64,
	p95_ns:             f64,
	p99_ns:             f64,
	max_ns:             f64,
	mean_ns:            f64,
	std_dev_ns:         f64,
	ci95_ns:            f64,
	cv_pct:             f64,
	iqr_ns:             f64,
	mad_ns:             f64,
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
	metrics:            [dynamic]bench.Metric,
	samples_ns:         [dynamic]f64,
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
	delete(r.samples_ns)
	r^ = {}
}

pooled_records_destroy :: proc(list: []Pooled_Record, allocator := context.allocator) {
	for &r in list {
		pooled_record_destroy(&r, allocator)
	}
	delete(list, allocator)
}

/*
Pools all `samples_ns` across matching runs in `st` and computes unified quantile,
dispersion, throughput, allocation, and footprint metrics per benchmark.
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

	out := make([dynamic]Pooled_Record, 0, len(raw_groups), allocator)
	for &g in raw_groups {
		if len(g.records) == 0 {
			continue
		}
		last := g.records[len(g.records) - 1]
		pooled_samples := make([dynamic]f64, allocator)
		footprint := last.footprint_bytes
		sum_allocs := 0.0
		sum_resizes := 0.0
		sum_alloc_bytes := 0.0
		sum_temp_allocs := 0.0
		sum_temp_bytes := 0.0
		max_peak := last.peak_heap_bytes

		for &rec in g.records {
			if len(rec.samples_ns) > 0 {
				append(&pooled_samples, ..rec.samples_ns[:])
			} else if rec.p50_ns > 0 {
				append(&pooled_samples, rec.p50_ns)
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

		n_recs := f64(len(g.records))
		run_ids := make([dynamic]string, len(g.run_ids), allocator)
		for rid, i in g.run_ids {
			run_ids[i] = strings.clone(rid, allocator)
		}

		metrics := make([dynamic]bench.Metric, len(last.metrics), allocator)
		for m, i in last.metrics {
			metrics[i] = bench.Metric {
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
			samples_ns         = pooled_samples,
		}

		if len(pr.samples_ns) > 0 {
			sorted := slice.clone(pr.samples_ns[:], context.temp_allocator)
			slice.sort(sorted)
			n := len(sorted)
			pr.samples = n
			pr.min_ns = sorted[0]
			pr.max_ns = sorted[n - 1]
			pr.p25_ns = obench.percentile_sorted(sorted, 0.25)
			pr.p50_ns = obench.percentile_sorted(sorted, 0.50)
			pr.p75_ns = obench.percentile_sorted(sorted, 0.75)
			pr.p95_ns = obench.percentile_sorted(sorted, 0.95)
			pr.p99_ns = obench.percentile_sorted(sorted, 0.99)
			pr.iqr_ns = pr.p75_ns - pr.p25_ns

			sum := 0.0
			for v in sorted {
				sum += v
			}
			pr.mean_ns = sum / f64(n)

			var_sum := 0.0
			for v in sorted {
				d := v - pr.mean_ns
				var_sum += d * d
			}
			if n > 1 {
				pr.std_dev_ns = math.sqrt(var_sum / f64(n - 1))
				pr.ci95_ns =
					obench.t_critical_975(f64(n - 1)) * (pr.std_dev_ns / math.sqrt(f64(n)))
			}
			if pr.mean_ns > 0 {
				pr.cv_pct = (pr.std_dev_ns / pr.mean_ns) * 100.0
			}

			abs_devs := make([]f64, n, context.temp_allocator)
			for v, i in sorted {
				abs_devs[i] = abs(v - pr.p50_ns)
			}
			slice.sort(abs_devs)
			pr.mad_ns = obench.percentile_sorted(abs_devs, 0.50)

			delete(abs_devs, context.temp_allocator)
			delete(sorted, context.temp_allocator)

			if pr.p50_ns > 0 {
				pr.ops_per_sec = 1_000_000_000.0 / pr.p50_ns
				if pr.bytes_per_op > 0 {
					pr.mb_per_sec = (f64(pr.bytes_per_op) * pr.ops_per_sec) / (1024.0 * 1024.0)
				}
			}
		} else {
			pr.samples = last.samples
			pr.min_ns = last.min_ns
			pr.p25_ns = last.p25_ns
			pr.p50_ns = last.p50_ns
			pr.p75_ns = last.p75_ns
			pr.p95_ns = last.p95_ns
			pr.p99_ns = last.p99_ns
			pr.max_ns = last.max_ns
			pr.mean_ns = last.mean_ns
			pr.std_dev_ns = last.std_dev_ns
			pr.ci95_ns = last.ci95_ns
			pr.cv_pct = last.cv_pct
			pr.iqr_ns = last.iqr_ns
			pr.mad_ns = last.mad_ns
			pr.ops_per_sec = last.items_per_sec
		}

		append(&out, pr)
	}
	return out[:]
}

Verdict :: enum u8 {
	Unchanged,
	Faster,
	Regression,
}

Comparison_Row :: struct {
	full_name:        string,
	base_p50_ns:      f64,
	cand_p50_ns:      f64,
	base_std_ns:      f64,
	cand_std_ns:      f64,
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
	for c in cand {
		cand_by_name[c.full_name] = c
	}

	log_sum := 0.0
	log_cnt := 0

	for b in base {
		c, matched := cand_by_name[b.full_name]
		if !matched || b.p50_ns <= 0 || c.p50_ns <= 0 {
			continue
		}

		delta_pct := ((c.p50_ns - b.p50_ns) / b.p50_ns) * 100.0
		speedup := b.p50_ns / c.p50_ns
		wt, wdf := obench.welch_test(
			c.mean_ns,
			c.std_dev_ns,
			c.samples,
			b.mean_ns,
			b.std_dev_ns,
			b.samples,
		)

		used_rank := len(b.samples_ns) >= 2 && len(c.samples_ns) >= 2
		p_val := 1.0
		stat_diff := false
		if used_rank {
			_, _, p_val = obench.mann_whitney_u(
				c.samples_ns[:],
				b.samples_ns[:],
				context.temp_allocator,
			)
			// With n >= 2 per side, check both rank separation and Welch t on small N.
			if len(b.samples_ns) >= 5 && len(c.samples_ns) >= 5 {
				stat_diff = p_val < 0.05
			} else {
				stat_diff = p_val < 0.05 || (wdf > 0 && abs(wt) >= obench.t_critical_975(wdf))
			}
		} else {
			stat_diff = wdf > 0 && abs(wt) >= obench.t_critical_975(wdf)
		}

		is_sig := stat_diff && abs(delta_pct) >= threshold_pct
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

		ratio := c.p50_ns / b.p50_ns
		if ratio > 0 {
			log_sum += math.ln(ratio)
			log_cnt += 1
		}

		append(
			&rep.rows,
			Comparison_Row {
				full_name = strings.clone(b.full_name, allocator),
				base_p50_ns = b.p50_ns,
				cand_p50_ns = c.p50_ns,
				base_std_ns = b.std_dev_ns,
				cand_std_ns = c.std_dev_ns,
				base_samples = b.samples,
				cand_samples = c.samples,
				delta_pct = delta_pct,
				speedup = speedup,
				welch_t = wt,
				welch_df = wdf,
				used_rank_test = used_rank,
				p_value = p_val,
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
	a_p50_ns:           f64,
	a_std_ns:           f64,
	a_cv_pct:           f64,
	b_p50_ns:           f64,
	b_std_ns:           f64,
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
	for b in rows_b {
		map_b[b.full_name] = b
	}
	seen_b := make(map[string]bool, context.temp_allocator)

	for a in rows_a {
		b, ok := map_b[a.full_name]
		if !ok {
			append(&rep.only_in_a, strings.clone(a.full_name, allocator))
			continue
		}
		seen_b[a.full_name] = true

		a_med := max(a.p50_ns, 0.001)
		b_med := max(b.p50_ns, 0.001)
		wt, wdf := obench.welch_test(
			a.mean_ns,
			a.std_dev_ns,
			a.samples,
			b.mean_ns,
			b.std_dev_ns,
			b.samples,
		)
		p_val := 1.0
		stat_diff := false
		if len(a.samples_ns) >= 5 && len(b.samples_ns) >= 5 {
			_, _, p_val = obench.mann_whitney_u(
				a.samples_ns[:],
				b.samples_ns[:],
				context.temp_allocator,
			)
			stat_diff = p_val < 0.05
		} else {
			if len(a.samples_ns) >= 2 && len(b.samples_ns) >= 2 {
				_, _, p_val = obench.mann_whitney_u(
					a.samples_ns[:],
					b.samples_ns[:],
					context.temp_allocator,
				)
			}
			stat_diff = wdf > 0 && abs(wt) >= obench.t_critical_975(wdf)
		}

		rel_diff := abs(a_med - b_med) / min(a_med, b_med) * 100.0
		is_sig := stat_diff && rel_diff >= threshold_pct

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
				a_p50_ns = a.p50_ns,
				a_std_ns = a.std_dev_ns,
				a_cv_pct = a.cv_pct,
				b_p50_ns = b.p50_ns,
				b_std_ns = b.std_dev_ns,
				b_cv_pct = b.cv_pct,
				faster_lang = strings.clone(faster, allocator),
				speedup_ratio = ratio,
				is_significant = is_sig,
				p_value = p_val,
				welch_t = wt,
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
