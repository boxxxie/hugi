package hugi_cli

import obench "../../deps/obench/obench"
import hugi "../../hugi"
import store "../../store"
import "core:fmt"
import "core:strings"

@(private)
_cmd_history :: proc(args: []string) -> int {
	common := _Common_Opts{}
	show_runs := false
	limit := 0

	allowed := _Common_Flag_Set{.DB}
	i := 0
	for i < len(args) {
		key, inline_val, is_flag := _parse_flag_kv(args, &i)
		if !is_flag {
			fmt.eprintfln("hugi history: unexpected argument '%s'", args[i])
			return 1
		}
		switch _try_parse_common_flag("history", key, inline_val, args, &i, allowed, &common) {
		case .Help:
			_print_help()
			return 0
		case .Error:
			return 1
		case .Matched:
			continue
		case .Not_Matched:
		}
		switch key {
		case "runs":
			show_runs = true
		case "commits":
			show_runs = false
		case "limit":
			n, ok := _parse_nonneg_int_flag("history", key, args, &i, inline_val)
			if !ok {
				return 1
			}
			limit = n
		case:
			fmt.eprintfln("hugi history: unknown flag '--%s'", key)
			return 1
		}
	}

	st, db_path, open_ok := _open_store_or_err("history", common.db_flag)
	if !open_ok {
		return 1
	}
	defer store.store_close(&st)

	if show_runs {
		runs := store.store_list_runs(&st, context.allocator)
		defer store.run_summaries_destroy(runs)
		if len(runs) == 0 {
			fmt.printfln("No runs stored in %s", db_path)
			return 0
		}
		start := 0
		if limit > 0 && len(runs) > limit {
			start = len(runs) - limit
		}
		fmt.printfln(
			"%-28s | %-12s | %-8s | %7s | %8s | %s",
			"Run ID",
			"Commit",
			"Lang",
			"Records",
			"Samples",
			"Suite",
		)
		fmt.println(
			"-----------------------------+--------------+----------+---------+----------+--------------------",
		)
		for idx := len(runs) - 1; idx >= start; idx -= 1 {
			rs := runs[idx]
			recs_str := fmt.tprintf("%d", rs.record_count)
			samples_str := fmt.tprintf("%d", rs.total_samples)
			fmt.printfln(
				"%-28s | %-12s | %-8s | %7s | %8s | %s",
				rs.run_id,
				rs.commit,
				rs.lang,
				recs_str,
				samples_str,
				rs.suite_name,
			)
		}
		return 0
	}

	commits := store.store_list_commits(&st, context.allocator)
	defer store.commit_summaries_destroy(commits)
	if len(commits) == 0 {
		fmt.printfln("No commits stored in %s", db_path)
		return 0
	}
	start := 0
	if limit > 0 && len(commits) > limit {
		start = len(commits) - limit
	}
	fmt.printfln(
		"%-14s | %-16s | %5s | %10s | %s",
		"Commit",
		"Languages",
		"Runs",
		"Benchmarks",
		"Samples",
	)
	fmt.println("---------------+------------------+-------+------------+----------")
	for idx := len(commits) - 1; idx >= start; idx -= 1 {
		cs := commits[idx]
		langs_str := strings.join(cs.langs[:], ",", context.temp_allocator)
		runs_str := fmt.tprintf("%d", len(cs.run_ids))
		benches_str := fmt.tprintf("%d", cs.bench_count)
		samples_str := fmt.tprintf("%d", cs.total_samples)
		fmt.printfln(
			"%-14s | %-16s | %5s | %10s | %s",
			cs.commit,
			langs_str,
			runs_str,
			benches_str,
			samples_str,
		)
	}
	return 0
}

@(private)
_cmd_inspect :: proc(args: []string) -> int {
	common := _Common_Opts {
		lang = "odin",
	}
	has_filter := false
	run_id := ""

	allowed := _Common_Flag_Set{.DB, .Commit, .Lang, .Filter}
	i := 0
	for i < len(args) {
		key, inline_val, is_flag := _parse_flag_kv(args, &i)
		if !is_flag {
			if !has_filter {
				common.filter = args[i]
				has_filter = true
				i += 1
				continue
			}
			fmt.eprintfln("hugi inspect: unexpected argument '%s'", args[i])
			return 1
		}
		switch _try_parse_common_flag("inspect", key, inline_val, args, &i, allowed, &common) {
		case .Help:
			_print_help()
			return 0
		case .Error:
			return 1
		case .Matched:
			continue
		case .Not_Matched:
		}
		switch key {
		case "run":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			run_id = v
		case:
			fmt.eprintfln("hugi inspect: unknown flag '--%s'", key)
			return 1
		}
	}

	st, _, open_ok := _open_store_or_err("inspect", common.db_flag)
	if !open_ok {
		return 1
	}
	defer store.store_close(&st)

	records := store.store_load_pooled_records(
		&st,
		common.lang,
		common.commit,
		run_id,
		common.filter,
		context.allocator,
	)
	defer store.pooled_records_destroy(records)
	if len(records) == 0 {
		fmt.printfln(
			"No matching records found (lang=%s, commit=%q, filter=%q)",
			common.lang,
			common.commit,
			common.filter,
		)
		return 0
	}

	fmt.printfln("Inspect (%s, %d benchmarks):\n", common.lang, len(records))
	fmt.print(store.format_markdown_table(records, context.temp_allocator))
	if len(records) <= 25 {
		fmt.println("\nQuantile Breakdown:")
		for r in records {
			fmt.printfln(
				"  %-36s min=%s p25=%s p50=%s p75=%s p95=%s p99=%s ci95=±%s iqr=%s mad=%s allocs=%.1f footprint=%s",
				r.full_name,
				hugi.format_duration_fs(r.min_fs, context.temp_allocator),
				hugi.format_duration_fs(r.p25_fs, context.temp_allocator),
				hugi.format_duration_fs(r.p50_fs, context.temp_allocator),
				hugi.format_duration_fs(r.p75_fs, context.temp_allocator),
				hugi.format_duration_fs(r.p95_fs, context.temp_allocator),
				hugi.format_duration_fs(r.p99_fs, context.temp_allocator),
				hugi.format_duration_fs(r.ci95_fs, context.temp_allocator),
				hugi.format_duration_fs(r.iqr_fs, context.temp_allocator),
				hugi.format_duration_fs(r.mad_fs, context.temp_allocator),
				r.allocs_per_op,
				obench.format_bytes(f64(r.footprint_bytes), context.temp_allocator),
			)
		}
	}
	return 0
}

@(private)
_cmd_compare :: proc(args: []string) -> int {
	common := _Common_Opts {
		lang          = "odin",
		threshold_pct = 5.0,
	}
	commits_arg := ""
	runs_arg := ""
	format_arg := ""
	out_path := ""
	fail_on_reg := false

	allowed := _Common_Flag_Set{.DB, .Lang, .Filter, .Threshold}
	i := 0
	for i < len(args) {
		key, inline_val, is_flag := _parse_flag_kv(args, &i)
		if !is_flag {
			fmt.eprintfln("hugi compare: unexpected argument '%s'", args[i])
			return 1
		}
		switch _try_parse_common_flag("compare", key, inline_val, args, &i, allowed, &common) {
		case .Help:
			_print_help()
			return 0
		case .Error:
			return 1
		case .Matched:
			continue
		case .Not_Matched:
		}
		switch key {
		case "commits":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			commits_arg = v
		case "runs":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			runs_arg = v
		case "format":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			format_arg = v
		case "out":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			out_path = v
		case "last":
		// Default behavior when neither --commits nor --runs is provided.
		case "fail-on-regression":
			fail_on_reg = true
		case:
			fmt.eprintfln("hugi compare: unknown flag '--%s'", key)
			return 1
		}
	}

	rep_fmt := _infer_report_format(format_arg, out_path)
	if rep_fmt != "md" && rep_fmt != "json" && rep_fmt != "csv" {
		fmt.eprintfln("hugi compare: unsupported format '%s' (expected md|json|csv)", rep_fmt)
		return 1
	}

	st, db_path, open_ok := _open_store_or_err("compare", common.db_flag)
	if !open_ok {
		return 1
	}
	defer store.store_close(&st)

	base_commit, cand_commit := "", ""
	base_run, cand_run := "", ""
	base_label, cand_label := "Baseline", "Candidate"

	if runs_arg != "" {
		r1, r2, r_ok := _split_range(runs_arg)
		if !r_ok {
			fmt.eprintfln("hugi compare: --runs requires <run1>..<run2>, got '%s'", runs_arg)
			return 1
		}
		base_run, cand_run = r1, r2
		base_label, cand_label = r1, r2
	} else if commits_arg != "" {
		c1, c2, c_ok := _split_range(commits_arg)
		if !c_ok {
			fmt.eprintfln("hugi compare: --commits requires <base>..<cand>, got '%s'", commits_arg)
			return 1
		}
		base_commit, cand_commit = c1, c2
		base_label, cand_label = c1, c2
	} else {
		commits := store.store_list_commits(&st, context.allocator)
		defer store.commit_summaries_destroy(commits)
		matching_commits := make([dynamic]string, context.temp_allocator)
		for cs in commits {
			has_lang := false
			for l in cs.langs {
				if l == common.lang {
					has_lang = true
					break
				}
			}
			if has_lang {
				append(&matching_commits, cs.commit)
			}
		}
		if len(matching_commits) >= 2 {
			c1 := strings.clone(
				matching_commits[len(matching_commits) - 2],
				context.temp_allocator,
			)
			c2 := strings.clone(
				matching_commits[len(matching_commits) - 1],
				context.temp_allocator,
			)
			base_commit, cand_commit = c1, c2
			base_label, cand_label = c1, c2
		} else {
			runs := store.store_list_runs(&st, context.allocator)
			defer store.run_summaries_destroy(runs)
			matching_runs := make([dynamic]string, context.temp_allocator)
			for rs in runs {
				if rs.lang == common.lang {
					append(&matching_runs, rs.run_id)
				}
			}
			if len(matching_runs) < 2 {
				fmt.eprintfln(
					"hugi compare: need at least 2 commits or runs for lang=%s in %s",
					common.lang,
					db_path,
				)
				return 1
			}
			r1 := strings.clone(matching_runs[len(matching_runs) - 2], context.temp_allocator)
			r2 := strings.clone(matching_runs[len(matching_runs) - 1], context.temp_allocator)
			base_run, cand_run = r1, r2
			base_label, cand_label = r1, r2
		}
	}

	base_records := store.store_load_pooled_records(
		&st,
		common.lang,
		base_commit,
		base_run,
		common.filter,
		context.allocator,
	)
	defer store.pooled_records_destroy(base_records)
	cand_records := store.store_load_pooled_records(
		&st,
		common.lang,
		cand_commit,
		cand_run,
		common.filter,
		context.allocator,
	)
	defer store.pooled_records_destroy(cand_records)

	if len(base_records) == 0 || len(cand_records) == 0 {
		fmt.eprintfln(
			"hugi compare: no records for baseline (%d) or candidate (%d)",
			len(base_records),
			len(cand_records),
		)
		return 1
	}

	rep := store.compare_records(
		base_records,
		cand_records,
		common.threshold_pct,
		context.allocator,
	)
	defer store.comparison_report_destroy(&rep)
	text := ""
	switch rep_fmt {
	case "json":
		text = store.format_comparison_json(rep, base_label, cand_label, context.temp_allocator)
	case "csv":
		text = store.format_comparison_csv(rep, base_label, cand_label, context.temp_allocator)
	case:
		text = store.format_comparison_table(rep, base_label, cand_label, context.temp_allocator)
	}
	if !store.export_report_text(out_path, text) {
		fmt.eprintfln("hugi compare: failed writing %s report to '%s'", rep_fmt, out_path)
		return 1
	}

	if fail_on_reg && rep.regressions > 0 {
		return 1
	}
	return 0
}

@(private)
_cmd_compare_1v1 :: proc(args: []string) -> int {
	common := _Common_Opts {
		threshold_pct = 3.0,
	}
	langs_arg := "odin,zig"
	format_arg := ""
	out_path := ""

	allowed := _Common_Flag_Set{.DB, .Commit, .Threshold}
	i := 0
	for i < len(args) {
		key, inline_val, is_flag := _parse_flag_kv(args, &i)
		if !is_flag {
			fmt.eprintfln("hugi compare-1v1: unexpected argument '%s'", args[i])
			return 1
		}
		switch _try_parse_common_flag("compare-1v1", key, inline_val, args, &i, allowed, &common) {
		case .Help:
			_print_help()
			return 0
		case .Error:
			return 1
		case .Matched:
			continue
		case .Not_Matched:
		}
		switch key {
		case "langs":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			langs_arg = v
		case "format":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			format_arg = v
		case "out":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			out_path = v
		case:
			fmt.eprintfln("hugi compare-1v1: unknown flag '--%s'", key)
			return 1
		}
	}

	rep_fmt := _infer_report_format(format_arg, out_path)
	if rep_fmt != "md" && rep_fmt != "json" && rep_fmt != "csv" {
		fmt.eprintfln("hugi compare-1v1: unsupported format '%s' (expected md|json|csv)", rep_fmt)
		return 1
	}

	parts := strings.split(langs_arg, ",", context.temp_allocator)
	if len(parts) != 2 ||
	   strings.trim_space(parts[0]) == "" ||
	   strings.trim_space(parts[1]) == "" {
		fmt.eprintfln(
			"hugi compare-1v1: --langs requires two comma-separated languages, got '%s'",
			langs_arg,
		)
		return 1
	}
	lang_a := strings.trim_space(parts[0])
	lang_b := strings.trim_space(parts[1])

	st, _, open_ok := _open_store_or_err("compare-1v1", common.db_flag)
	if !open_ok {
		return 1
	}
	defer store.store_close(&st)

	rep := store.compare_1v1_langs(
		&st,
		lang_a,
		lang_b,
		common.commit,
		common.threshold_pct,
		context.allocator,
	)
	defer store.cross_lang_report_destroy(&rep)
	text := ""
	switch rep_fmt {
	case "json":
		text = store.format_1v1_json(rep, context.temp_allocator)
	case "csv":
		text = store.format_1v1_csv(rep, context.temp_allocator)
	case:
		text = store.format_1v1_table(rep, context.temp_allocator)
	}
	if !store.export_report_text(out_path, text) {
		fmt.eprintfln("hugi compare-1v1: failed writing %s report to '%s'", rep_fmt, out_path)
		return 1
	}
	return 0
}
