package hugi_cli

import store "../../store"
import "core:fmt"
import "core:os"

@(private)
_Export_Opts :: struct {
	common:      _Common_Opts,
	format:      string,
	out_path:    string,
	readme_path: string,
	all_commits: bool,
	all_runs:    bool,
}

@(private, require_results)
_parse_export_args :: proc(args: []string) -> (opts: _Export_Opts, exit_code: int, done: bool) {
	opts.common.lang = "odin"
	allowed := _Common_Flag_Set{.DB, .Commit, .Lang, .Filter}
	i := 0
	for i < len(args) {
		key, inline_val, is_flag := _parse_flag_kv(args, &i)
		if !is_flag {
			fmt.eprintfln("hugi export: unexpected argument '%s'", args[i])
			return opts, 1, true
		}
		switch _try_parse_common_flag("export", key, inline_val, args, &i, allowed, &opts.common) {
		case .Help:
			_print_help()
			return opts, 0, true
		case .Error:
			return opts, 1, true
		case .Matched:
			continue
		case .Not_Matched:
		}
		switch key {
		case "all-commits":
			opts.all_commits = true
		case "all-runs":
			opts.all_runs = true
		case "format":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return opts, 1, true}
			opts.format = v
		case "out":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return opts, 1, true}
			opts.out_path = v
		case "update-readme":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return opts, 1, true}
			opts.readme_path = v
		case:
			fmt.eprintfln("hugi export: unknown flag '--%s'", key)
			return opts, 1, true
		}
	}
	return opts, 0, false
}

@(private, require_results)
_validate_export_opts :: proc(opts: ^_Export_Opts) -> (err_msg: string, ok: bool) {
	if opts.all_commits && opts.all_runs {
		return "hugi export: --all-commits and --all-runs cannot be combined", false
	}
	if (opts.all_commits || opts.all_runs) && opts.common.commit != "" {
		return "hugi export: --all-commits / --all-runs cannot be combined with --commit", false
	}
	opts.format = _infer_export_format(opts.format, opts.out_path, opts.readme_path)
	if opts.format == "" {
		return "hugi export: --format <arrow|parquet|json|jsonl|csv|tsv|md> is required", false
	}
	if opts.out_path == "" && opts.readme_path == "" {
		return "hugi export: --out <path> (or --update-readme <path>) is required", false
	}
	return "", true
}

@(private)
_cmd_export :: proc(args: []string) -> int {
	opts, exit_code, done := _parse_export_args(args)
	if done {
		return exit_code
	}
	if err_msg, v_ok := _validate_export_opts(&opts); !v_ok {
		fmt.eprintln(err_msg)
		return 1
	}

	st, _, open_ok := _open_store_or_err("export", opts.common.db_flag)
	if !open_ok {
		return 1
	}
	defer store.store_close(&st)

	records: []store.Pooled_Record
	if opts.all_commits {
		records = store.store_load_commit_series_records(
			&st,
			opts.common.lang,
			opts.common.filter,
			context.allocator,
		)
	} else if opts.all_runs {
		records = store.store_load_all_run_records(
			&st,
			opts.common.lang,
			opts.common.filter,
			context.allocator,
		)
	} else {
		records = store.store_load_pooled_records(
			&st,
			opts.common.lang,
			opts.common.commit,
			"",
			opts.common.filter,
			context.allocator,
		)
	}
	defer store.pooled_records_destroy(records)
	if len(records) == 0 {
		fmt.eprintfln(
			"hugi export: no matching records (lang=%s, commit=%q)",
			opts.common.lang,
			opts.common.commit,
		)
		return 1
	}

	if opts.out_path != "" {
		ok := false
		switch opts.format {
		case "arrow", "feather", "ipc":
			ok = store.export_arrow_ipc(opts.out_path, records, .LZ4_Frame, context.allocator)
		case "parquet", "pq":
			ok = store.export_parquet(opts.out_path, records, true, context.allocator)
		case "json":
			ok = store.export_json(opts.out_path, records)
		case "jsonl", "ndjson":
			ok = store.export_jsonl(opts.out_path, records)
		case "csv":
			ok = store.export_csv(opts.out_path, records)
		case "tsv", "tab":
			ok = store.export_tsv(opts.out_path, records)
		case "md", "markdown":
			ok = store.export_markdown(opts.out_path, records)
		case:
			fmt.eprintfln(
				"hugi export: unsupported format '%s' (expected arrow|parquet|json|jsonl|csv|tsv|md)",
				opts.format,
			)
			return 1
		}
		if !ok {
			fmt.eprintfln(
				"hugi export: failed writing %s export to '%s'",
				opts.format,
				opts.out_path,
			)
			return 1
		}
		if fi, s_err := os.stat(opts.out_path, context.temp_allocator); s_err == nil {
			fmt.printfln(
				"Exported %d record(s) (%s) -> %s (%d bytes)",
				len(records),
				opts.format,
				opts.out_path,
				fi.size,
			)
		} else {
			fmt.printfln(
				"Exported %d record(s) (%s) -> %s",
				len(records),
				opts.format,
				opts.out_path,
			)
		}
	}

	if opts.readme_path != "" {
		md := store.format_markdown_table(records, context.temp_allocator)
		if !store.update_readme_markers(opts.readme_path, md) {
			fmt.eprintfln(
				"hugi export: failed updating benchmark markers in '%s'",
				opts.readme_path,
			)
			return 1
		}
		fmt.printfln("Updated benchmark table in %s", opts.readme_path)
	}

	return 0
}

@(private)
_cmd_compact :: proc(args: []string) -> int {
	common := _Common_Opts{}
	opts := store.default_store_write_options()
	allowed := _Common_Flag_Set{.DB}

	i := 0
	for i < len(args) {
		key, inline_val, is_flag := _parse_flag_kv(args, &i)
		if !is_flag {
			fmt.eprintfln("hugi compact: unexpected argument '%s'", args[i])
			return 1
		}
		switch _try_parse_common_flag("compact", key, inline_val, args, &i, allowed, &common) {
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
		case "keep-hot":
			n, ok := _parse_nonneg_int_flag("compact", key, args, &i, inline_val)
			if !ok {
				return 1
			}
			opts.keep_hot_runs = n
		case:
			fmt.eprintfln("hugi compact: unknown flag '--%s'", key)
			return 1
		}
	}

	db_path := _resolve_db_path(common.db_flag)
	before, after, ok := store.store_compact_with_options(db_path, opts)
	if !ok {
		fmt.eprintfln("hugi compact: failed to compact '%s'", db_path)
		return 1
	}
	saved_pct := 0.0
	if before > 0 {
		saved_pct = f64(before - after) / f64(before) * 100.0
	}
	fmt.printfln(
		"Compacted %s: %d -> %d bytes (%.1f%% reduction)",
		db_path,
		before,
		after,
		saved_pct,
	)
	return 0
}
