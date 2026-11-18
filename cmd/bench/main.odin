package bench_cli

import bench "../../bench"
import obench "../../deps/obench/obench"
import store "../../store"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

VERSION :: "bench 0.1.0"

@(private = "file")
_Ols_Collection :: struct {
	name: string `json:"name"`,
	path: string `json:"path"`,
}

@(private = "file")
_Ols_File :: struct {
	collections: []_Ols_Collection `json:"collections"`,
}

@(private = "file")
_print_help :: proc() {
	fmt.print(
		`bench — Odin benchmark runner, compressed xitdb store, and comparison CLI

USAGE:
  bench <command> [options]

COMMANDS:
  run [pkg_dir]          Build and execute an Odin benchmark package, ingest results into store
  ingest <file...>       Ingest .bpk packets, obench .json reports, or legacy .jsonl histories
  history                List commits or runs stored in the benchmark database
  inspect [filter]       Inspect pooled metrics (quantiles, CV%, allocations, footprint)
  compare                Compare commits or runs using Mann-Whitney U and Welch t-test
  compare-1v1            Cross-language 1v1 comparison (e.g., odin vs zig) with footprint checks
  export                 Export pooled benchmarks to Arrow IPC (.arrow), JSONL, CSV, or Markdown
  compact                Compact the xitdb store and reclaim dead pages
  help                   Show this help message
  version                Print version information

COMMON OPTIONS:
  --db <path>            Store path (default: benchmarks/history.benchdb or history.benchdb)
  --lang <lang>          Language tag (default: odin)
  --commit <sha>         Commit identifier override
  --filter <pat>         Benchmark name substring filter (supports ',' or '|' alternation)

RUN OPTIONS:
  --no-db                Execute package without writing to a store
  --runs <N>             Measured pipeline runs (default: 7)
  --warmup <N>           Warmup iterations / milliseconds (default: 1)
  --groups <g1,g2>       Comma-separated group filter
  --baseline-commit <c>  Compare run immediately against baseline commit <c>
  --fail-on-regression   Exit non-zero if statistical regressions are detected
  --threshold <pct>      Regression threshold percentage (default: 5.0)
  --extra-build-flags s  Space-separated extra flags passed to 'odin build'

COMPARE / EXPORT OPTIONS:
  --commits <a..b>       Compare commit <a> against commit <b>
  --runs <a..b>          Compare run_id <a> against run_id <b>
  --last                 Compare the last two commits (or last two runs)
  --langs <a,b>          Languages for compare-1v1 (default: odin,zig)
  --format <fmt>         Export format: arrow | jsonl | csv | md
  --out <path>           Output path for export
  --update-readme <path> Replace <!-- BEGIN_BENCHMARK_TABLE -->..<!-- END_BENCHMARK_TABLE -->
  --limit <N>            Maximum history entries to display (0 = all)
`,
	)
}

@(private = "file")
_resolve_db_path :: proc(explicit: string) -> string {
	if explicit != "" {
		return explicit
	}
	if os.is_dir("benchmarks") {
		return "benchmarks/history.benchdb"
	}
	return "history.benchdb"
}

@(private = "file")
_parse_flag_kv :: proc(args: []string, idx: ^int) -> (key: string, val: string, is_flag: bool) {
	arg := args[idx^]
	if !strings.has_prefix(arg, "-") || arg == "-" {
		return "", "", false
	}
	idx^ += 1
	trimmed := strings.trim_left(arg, "-")
	if sep := strings.index_any(trimmed, "=:"); sep >= 0 {
		return trimmed[:sep], trimmed[sep + 1:], true
	}
	return trimmed, "", true
}

@(private = "file")
_consume_value :: proc(
	args: []string,
	idx: ^int,
	inline_val: string,
	flag_name: string,
) -> (
	val: string,
	ok: bool,
) {
	if inline_val != "" {
		return inline_val, true
	}
	if idx^ >= len(args) {
		fmt.eprintfln("bench: missing value for --%s", flag_name)
		return "", false
	}
	v := args[idx^]
	idx^ += 1
	return v, true
}

@(private = "file")
_odin_executable :: proc() -> string {
	if val := os.get_env("ODIN", context.temp_allocator); val != "" {
		return val
	}
	return "odin"
}

@(private = "file")
_run_process :: proc(cmd: []string) -> bool {
	child, start_err := os.process_start(
		os.Process_Desc{command = cmd, stdout = os.stdout, stderr = os.stderr, stdin = os.stdin},
	)
	if start_err != nil {
		fmt.eprintfln("bench: failed to start '%s': %v", cmd[0], start_err)
		return false
	}
	state, wait_err := os.process_wait(child)
	return wait_err == nil && state.exited && state.exit_code == 0
}

@(private = "file")
_is_bench_repo_root :: proc(dir: string) -> bool {
	bench_file, _ := filepath.join({dir, "bench", "bench.odin"}, context.temp_allocator)
	obench_dir, _ := filepath.join({dir, "deps", "obench", "obench"}, context.temp_allocator)
	return os.exists(bench_file) && os.is_dir(obench_dir)
}

@(private = "file")
_resolve_bench_repo_root :: proc() -> string {
	if exe_dir, err := os.get_executable_directory(context.temp_allocator);
	   err == nil && exe_dir != "" {
		cur := exe_dir
		for cur != "" {
			if _is_bench_repo_root(cur) {
				return cur
			}
			parent := filepath.dir(cur)
			if parent == cur || parent == "." || parent == "" {
				break
			}
			cur = parent
		}
	}
	if cwd, err := os.get_working_directory(context.temp_allocator); err == nil && cwd != "" {
		cur := cwd
		for cur != "" {
			if _is_bench_repo_root(cur) {
				return cur
			}
			parent := filepath.dir(cur)
			if parent == cur || parent == "." || parent == "" {
				break
			}
			cur = parent
		}
	}
	return ""
}

@(private = "file")
_discover_ols_collections :: proc(start_dir: string) -> [dynamic]string {
	result := make([dynamic]string, context.temp_allocator)
	cur, abs_err := os.get_absolute_path(start_dir, context.temp_allocator)
	if abs_err != nil || cur == "" {
		cur = start_dir
	}
	if !os.is_dir(cur) {
		cur = filepath.dir(cur)
	}
	for cur != "" {
		ols_path, _ := filepath.join({cur, "ols.json"}, context.temp_allocator)
		if os.exists(ols_path) {
			data, read_err := os.read_entire_file(ols_path, context.temp_allocator)
			if read_err == nil {
				doc: _Ols_File
				if json.unmarshal(data, &doc, allocator = context.temp_allocator) == nil {
					for col in doc.collections {
						if col.name == "" || col.path == "" {
							continue
						}
						resolved := col.path
						if !filepath.is_abs(col.path) {
							resolved, _ = filepath.join({cur, col.path}, context.temp_allocator)
						}
						append(&result, fmt.tprintf("%s=%s", col.name, resolved))
					}
				}
			}
			break
		}
		parent := filepath.dir(cur)
		if parent == cur || parent == "." || parent == "" {
			break
		}
		cur = parent
	}
	return result
}

@(private = "file")
_collection_name :: proc "contextless" (entry: string) -> string {
	if eq := strings.index_byte(entry, '='); eq > 0 {
		return entry[:eq]
	}
	return entry
}

@(private = "file")
_cmd_run :: proc(args: []string) -> int {
	pkg_dir := "."
	has_pkg := false
	db_flag := ""
	no_db := false
	runs := ""
	warmup := ""
	groups := ""
	filter := ""
	lang := "odin"
	commit := ""
	baseline_commit := ""
	fail_on_reg := false
	threshold_pct := 5.0
	extra_build_flags := ""
	quiet := false

	i := 0
	for i < len(args) {
		key, inline_val, is_flag := _parse_flag_kv(args, &i)
		if !is_flag {
			if !has_pkg {
				pkg_dir = args[i]
				has_pkg = true
				i += 1
				continue
			}
			fmt.eprintfln("bench run: unexpected argument '%s'", args[i])
			return 1
		}
		switch key {
		case "h", "help":
			_print_help()
			return 0
		case "no-db":
			no_db = true
		case "quiet":
			quiet = true
		case "fail-on-regression":
			fail_on_reg = true
		case "db":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			db_flag = v
		case "runs":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			runs = v
		case "warmup":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			warmup = v
		case "groups", "group":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			groups = v
		case "filter", "f":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			filter = v
		case "lang":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			lang = v
		case "commit":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			commit = v
		case "baseline-commit":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			baseline_commit = v
		case "threshold":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			parsed, p_ok := strconv.parse_f64(v)
			if !p_ok || parsed < 0 {
				fmt.eprintfln("bench run: invalid --threshold '%s'", v)
				return 1
			}
			threshold_pct = parsed
		case "extra-build-flags":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			extra_build_flags = v
		case:
			fmt.eprintfln("bench run: unknown flag '--%s'", key)
			return 1
		}
	}

	if !os.exists(pkg_dir) {
		fmt.eprintfln("bench run: package path does not exist: '%s'", pkg_dir)
		return 1
	}

	tmp_dir, t_err := os.temp_directory(context.temp_allocator)
	if t_err != nil || tmp_dir == "" {
		tmp_dir = "/tmp"
	}
	pid := os.get_pid()
	ts := time.to_unix_nanoseconds(time.now())

	bin_name := fmt.tprintf("odin_bench_%d_%d", pid, ts)
	when ODIN_OS == .Windows {
		bin_name = fmt.tprintf("odin_bench_%d_%d.exe", pid, ts)
	}
	bin_path, _ := filepath.join({tmp_dir, bin_name}, context.temp_allocator)
	pkt_path, _ := filepath.join(
		{tmp_dir, fmt.tprintf("odin_pkt_%d_%d.bpk", pid, ts)},
		context.temp_allocator,
	)
	defer {
		if os.exists(bin_path) {
			_ = os.remove(bin_path)
		}
		if os.exists(pkt_path) {
			_ = os.remove(pkt_path)
		}
	}

	build_cmd := make([dynamic]string, context.temp_allocator)
	append(
		&build_cmd,
		_odin_executable(),
		"build",
		pkg_dir,
		fmt.tprintf("-out:%s", bin_path),
		"-o:speed",
	)

	seen_cols := make(map[string]bool, context.temp_allocator)
	for col in _discover_ols_collections(pkg_dir) {
		name := _collection_name(col)
		if name not_in seen_cols {
			append(&build_cmd, fmt.tprintf("-collection:%s", col))
			seen_cols[name] = true
		}
	}
	if repo_root := _resolve_bench_repo_root(); repo_root != "" {
		if "bench" not_in seen_cols {
			b_dir, _ := filepath.join({repo_root, "bench"}, context.temp_allocator)
			append(&build_cmd, fmt.tprintf("-collection:bench=%s", b_dir))
			seen_cols["bench"] = true
		}
		if "obench" not_in seen_cols {
			o_dir, _ := filepath.join(
				{repo_root, "deps", "obench", "obench"},
				context.temp_allocator,
			)
			append(&build_cmd, fmt.tprintf("-collection:obench=%s", o_dir))
			seen_cols["obench"] = true
		}
	}
	if extra_build_flags != "" {
		for tok in strings.fields(extra_build_flags, context.temp_allocator) {
			if tok != "" {
				append(&build_cmd, tok)
			}
		}
	}

	if !_run_process(build_cmd[:]) {
		fmt.eprintfln("bench run: build failed for '%s'", pkg_dir)
		return 1
	}
	if !os.exists(bin_path) {
		fmt.eprintfln("bench run: compiler did not emit '%s'", bin_path)
		return 1
	}

	run_cmd := make([dynamic]string, context.temp_allocator)
	append(&run_cmd, bin_path, "--packet-out", pkt_path)
	if runs != "" {
		append(&run_cmd, "--runs", runs)
	}
	if warmup != "" {
		append(&run_cmd, "--warmup", warmup)
	}
	if groups != "" {
		append(&run_cmd, "--groups", groups)
	}
	if filter != "" {
		append(&run_cmd, "--filter", filter)
	}
	if lang != "" {
		append(&run_cmd, "--lang", lang)
	}
	if commit != "" {
		append(&run_cmd, "--commit", commit)
	}
	if quiet {
		append(&run_cmd, "--quiet")
	}

	run_ok := _run_process(run_cmd[:])
	if !os.exists(pkt_path) {
		if !run_ok {
			return 1
		}
		fmt.eprintfln("bench run: binary exited cleanly but did not write '%s'", pkt_path)
		return 1
	}

	pkt, pkt_ok := bench.read_packet_file(pkt_path, context.allocator)
	if !pkt_ok {
		fmt.eprintfln("bench run: failed to decode packet '%s'", pkt_path)
		return 1
	}
	defer bench.packet_destroy(&pkt)

	if !no_db {
		db_path := _resolve_db_path(db_flag)
		st, open_ok := store.store_open(db_path, context.allocator)
		if !open_ok {
			fmt.eprintfln("bench run: could not open store '%s'", db_path)
			return 1
		}
		defer store.store_close(&st)

		if !store.store_ingest_packet(&st, pkt) {
			fmt.eprintfln("bench run: failed to ingest run packet into '%s'", db_path)
			return 1
		}

		total_samples := 0
		for &r in pkt.records {
			total_samples += len(r.samples_ns) > 0 ? len(r.samples_ns) : r.samples
		}
		fmt.printfln(
			"Ingested run %s (commit=%s, lang=%s, records=%d, samples=%d) -> %s",
			pkt.run_id,
			pkt.commit,
			pkt.lang,
			len(pkt.records),
			total_samples,
			db_path,
		)

		if baseline_commit != "" {
			base := store.store_load_pooled_records(
				&st,
				lang,
				baseline_commit,
				"",
				filter,
				context.allocator,
			)
			defer store.pooled_records_destroy(base)
			cand := store.store_load_pooled_records(
				&st,
				lang,
				pkt.commit,
				"",
				filter,
				context.allocator,
			)
			defer store.pooled_records_destroy(cand)

			if len(base) == 0 || len(cand) == 0 {
				fmt.eprintfln(
					"bench run: insufficient baseline (%d) or candidate (%d) records for commit comparison",
					len(base),
					len(cand),
				)
				return 1
			}
			rep := store.compare_records(base, cand, threshold_pct, context.allocator)
			defer store.comparison_report_destroy(&rep)
			fmt.print(
				store.format_comparison_table(
					rep,
					baseline_commit,
					pkt.commit,
					context.temp_allocator,
				),
			)
			if fail_on_reg && rep.regressions > 0 {
				return 1
			}
		}
	}

	return run_ok ? 0 : 1
}

@(private = "file")
_file_has_magic_obpk :: proc(path: string) -> bool {
	f, err := os.open(path, {.Read})
	if err != nil {
		return false
	}
	defer os.close(f)
	hdr: [4]u8
	n, r_err := os.read(f, hdr[:])
	return r_err == nil && n == 4 && string(hdr[:]) == "OBPK"
}

@(private = "file")
_cmd_ingest :: proc(args: []string) -> int {
	files := make([dynamic]string, context.temp_allocator)
	db_flag := ""
	lang_override := ""
	commit_override := ""

	i := 0
	for i < len(args) {
		key, inline_val, is_flag := _parse_flag_kv(args, &i)
		if !is_flag {
			append(&files, args[i])
			i += 1
			continue
		}
		switch key {
		case "h", "help":
			_print_help()
			return 0
		case "db":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			db_flag = v
		case "lang":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			lang_override = v
		case "commit":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			commit_override = v
		case:
			fmt.eprintfln("bench ingest: unknown flag '--%s'", key)
			return 1
		}
	}

	if len(files) == 0 {
		fmt.eprintln("bench ingest: expected at least one input file (.bpk, .json, or .jsonl)")
		return 1
	}

	db_path := _resolve_db_path(db_flag)
	st, open_ok := store.store_open(db_path, context.allocator)
	if !open_ok {
		fmt.eprintfln("bench ingest: could not open store '%s'", db_path)
		return 1
	}
	defer store.store_close(&st)

	total_pkts := 0
	total_recs := 0
	for path in files {
		if !os.exists(path) {
			fmt.eprintfln("bench ingest: file not found: '%s'", path)
			return 1
		}
		if _file_has_magic_obpk(path) || strings.has_suffix(path, ".bpk") {
			pkt, ok := bench.read_packet_file(path, context.allocator)
			if !ok {
				fmt.eprintfln("bench ingest: failed to read packet '%s'", path)
				return 1
			}
			defer bench.packet_destroy(&pkt)
			if lang_override != "" {
				delete(pkt.lang)
				pkt.lang = strings.clone(lang_override)
			}
			if commit_override != "" {
				delete(pkt.commit)
				pkt.commit = strings.clone(commit_override)
			}
			if !store.store_ingest_packet(&st, pkt) {
				fmt.eprintfln("bench ingest: failed to write packet '%s' to store", path)
				return 1
			}
			total_pkts += 1
			total_recs += len(pkt.records)
			continue
		}

		pkts: []bench.Run_Packet
		ok: bool
		if strings.has_suffix(path, ".jsonl") {
			pkts, ok = bench.read_jsonl_packets(
				path,
				lang_override,
				commit_override,
				"",
				context.allocator,
			)
		} else {
			pkts, ok = bench.read_obench_json_packets(
				path,
				lang_override,
				commit_override,
				"",
				context.allocator,
			)
			if !ok || len(pkts) == 0 {
				if ok {
					bench.packets_destroy(pkts)
				}
				pkts, ok = bench.read_jsonl_packets(
					path,
					lang_override,
					commit_override,
					"",
					context.allocator,
				)
			}
		}
		if !ok {
			fmt.eprintfln("bench ingest: failed to parse '%s'", path)
			return 1
		}
		defer bench.packets_destroy(pkts)

		for &pkt in pkts {
			if !store.store_ingest_packet(&st, pkt) {
				fmt.eprintfln("bench ingest: failed to store packet from '%s'", path)
				return 1
			}
			total_pkts += 1
			total_recs += len(pkt.records)
		}
	}

	fmt.printfln("Ingested %d packet(s), %d record(s) into %s", total_pkts, total_recs, db_path)
	return 0
}

@(private = "file")
_cmd_history :: proc(args: []string) -> int {
	db_flag := ""
	show_runs := false
	limit := 0

	i := 0
	for i < len(args) {
		key, inline_val, is_flag := _parse_flag_kv(args, &i)
		if !is_flag {
			fmt.eprintfln("bench history: unexpected argument '%s'", args[i])
			return 1
		}
		switch key {
		case "h", "help":
			_print_help()
			return 0
		case "db":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			db_flag = v
		case "runs":
			show_runs = true
		case "commits":
			show_runs = false
		case "limit":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			n, n_ok := strconv.parse_int(v)
			if !n_ok || n < 0 {
				fmt.eprintfln("bench history: invalid --limit '%s'", v)
				return 1
			}
			limit = n
		case:
			fmt.eprintfln("bench history: unknown flag '--%s'", key)
			return 1
		}
	}

	db_path := _resolve_db_path(db_flag)
	st, open_ok := store.store_open(db_path, context.allocator)
	if !open_ok {
		fmt.eprintfln("bench history: could not open store '%s'", db_path)
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
			fmt.printfln(
				"%-28s | %-12s | %-8s | %7d | %8d | %s",
				rs.run_id,
				rs.commit,
				rs.lang,
				rs.record_count,
				rs.total_samples,
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
		fmt.printfln(
			"%-14s | %-16s | %5d | %10d | %d",
			cs.commit,
			langs_str,
			len(cs.run_ids),
			cs.bench_count,
			cs.total_samples,
		)
	}
	return 0
}

@(private = "file")
_cmd_inspect :: proc(args: []string) -> int {
	db_flag := ""
	filter := ""
	has_filter := false
	commit := ""
	lang := "odin"
	run_id := ""

	i := 0
	for i < len(args) {
		key, inline_val, is_flag := _parse_flag_kv(args, &i)
		if !is_flag {
			if !has_filter {
				filter = args[i]
				has_filter = true
				i += 1
				continue
			}
			fmt.eprintfln("bench inspect: unexpected argument '%s'", args[i])
			return 1
		}
		switch key {
		case "h", "help":
			_print_help()
			return 0
		case "db":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			db_flag = v
		case "commit":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			commit = v
		case "lang":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			lang = v
		case "run":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			run_id = v
		case "filter", "f":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			filter = v
		case:
			fmt.eprintfln("bench inspect: unknown flag '--%s'", key)
			return 1
		}
	}

	db_path := _resolve_db_path(db_flag)
	st, open_ok := store.store_open(db_path, context.allocator)
	if !open_ok {
		fmt.eprintfln("bench inspect: could not open store '%s'", db_path)
		return 1
	}
	defer store.store_close(&st)

	records := store.store_load_pooled_records(
		&st,
		lang,
		commit,
		run_id,
		filter,
		context.allocator,
	)
	defer store.pooled_records_destroy(records)
	if len(records) == 0 {
		fmt.printfln(
			"No matching records found (lang=%s, commit=%q, filter=%q)",
			lang,
			commit,
			filter,
		)
		return 0
	}

	fmt.printfln("Inspect (%s, %d benchmarks):\n", lang, len(records))
	fmt.print(store.format_markdown_table(records, context.temp_allocator))
	if len(records) <= 25 {
		fmt.println("\nQuantile Breakdown:")
		for r in records {
			fmt.printfln(
				"  %-36s min=%s p25=%s p50=%s p75=%s p95=%s p99=%s ci95=±%s iqr=%s mad=%s allocs=%.1f footprint=%s",
				r.full_name,
				obench.format_duration_ns(r.min_ns, context.temp_allocator),
				obench.format_duration_ns(r.p25_ns, context.temp_allocator),
				obench.format_duration_ns(r.p50_ns, context.temp_allocator),
				obench.format_duration_ns(r.p75_ns, context.temp_allocator),
				obench.format_duration_ns(r.p95_ns, context.temp_allocator),
				obench.format_duration_ns(r.p99_ns, context.temp_allocator),
				obench.format_duration_ns(r.ci95_ns, context.temp_allocator),
				obench.format_duration_ns(r.iqr_ns, context.temp_allocator),
				obench.format_duration_ns(r.mad_ns, context.temp_allocator),
				r.allocs_per_op,
				obench.format_bytes(f64(r.footprint_bytes), context.temp_allocator),
			)
		}
	}
	return 0
}

@(private = "file")
_split_range :: proc(s: string) -> (a: string, b: string, ok: bool) {
	if idx := strings.index(s, ".."); idx >= 0 {
		left := strings.trim_space(s[:idx])
		right := strings.trim_space(s[idx + 2:])
		if left != "" && right != "" {
			return left, right, true
		}
	}
	return "", "", false
}

@(private = "file")
_cmd_compare :: proc(args: []string) -> int {
	db_flag := ""
	commits_arg := ""
	runs_arg := ""
	use_last := false
	lang := "odin"
	filter := ""
	threshold_pct := 5.0
	fail_on_reg := false

	i := 0
	for i < len(args) {
		key, inline_val, is_flag := _parse_flag_kv(args, &i)
		if !is_flag {
			fmt.eprintfln("bench compare: unexpected argument '%s'", args[i])
			return 1
		}
		switch key {
		case "h", "help":
			_print_help()
			return 0
		case "db":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			db_flag = v
		case "commits":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			commits_arg = v
		case "runs":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			runs_arg = v
		case "last":
			use_last = true
		case "lang":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			lang = v
		case "filter", "f":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			filter = v
		case "threshold":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			parsed, p_ok := strconv.parse_f64(v)
			if !p_ok || parsed < 0 {
				fmt.eprintfln("bench compare: invalid --threshold '%s'", v)
				return 1
			}
			threshold_pct = parsed
		case "fail-on-regression":
			fail_on_reg = true
		case:
			fmt.eprintfln("bench compare: unknown flag '--%s'", key)
			return 1
		}
	}

	db_path := _resolve_db_path(db_flag)
	st, open_ok := store.store_open(db_path, context.allocator)
	if !open_ok {
		fmt.eprintfln("bench compare: could not open store '%s'", db_path)
		return 1
	}
	defer store.store_close(&st)

	base_records: []store.Pooled_Record
	cand_records: []store.Pooled_Record
	base_label := "Baseline"
	cand_label := "Candidate"
	defer store.pooled_records_destroy(base_records)
	defer store.pooled_records_destroy(cand_records)

	if runs_arg != "" {
		r1, r2, r_ok := _split_range(runs_arg)
		if !r_ok {
			fmt.eprintfln("bench compare: --runs requires <run1>..<run2>, got '%s'", runs_arg)
			return 1
		}
		base_label = r1
		cand_label = r2
		base_records = store.store_load_pooled_records(
			&st,
			lang,
			"",
			r1,
			filter,
			context.allocator,
		)
		cand_records = store.store_load_pooled_records(
			&st,
			lang,
			"",
			r2,
			filter,
			context.allocator,
		)
	} else if commits_arg != "" {
		c1, c2, c_ok := _split_range(commits_arg)
		if !c_ok {
			fmt.eprintfln(
				"bench compare: --commits requires <base>..<cand>, got '%s'",
				commits_arg,
			)
			return 1
		}
		base_label = c1
		cand_label = c2
		base_records = store.store_load_pooled_records(
			&st,
			lang,
			c1,
			"",
			filter,
			context.allocator,
		)
		cand_records = store.store_load_pooled_records(
			&st,
			lang,
			c2,
			"",
			filter,
			context.allocator,
		)
	} else {
		_ = use_last
		commits := store.store_list_commits(&st, context.allocator)
		defer store.commit_summaries_destroy(commits)
		matching_commits := make([dynamic]string, context.temp_allocator)
		for cs in commits {
			has_lang := false
			for l in cs.langs {
				if l == lang {
					has_lang = true
					break
				}
			}
			if has_lang {
				append(&matching_commits, cs.commit)
			}
		}
		if len(matching_commits) >= 2 {
			c1 := matching_commits[len(matching_commits) - 2]
			c2 := matching_commits[len(matching_commits) - 1]
			base_label = strings.clone(c1, context.temp_allocator)
			cand_label = strings.clone(c2, context.temp_allocator)
			base_records = store.store_load_pooled_records(
				&st,
				lang,
				c1,
				"",
				filter,
				context.allocator,
			)
			cand_records = store.store_load_pooled_records(
				&st,
				lang,
				c2,
				"",
				filter,
				context.allocator,
			)
		} else {
			runs := store.store_list_runs(&st, context.allocator)
			defer store.run_summaries_destroy(runs)
			matching_runs := make([dynamic]string, context.temp_allocator)
			for rs in runs {
				if rs.lang == lang {
					append(&matching_runs, rs.run_id)
				}
			}
			if len(matching_runs) < 2 {
				fmt.eprintfln(
					"bench compare: need at least 2 commits or runs for lang=%s in %s",
					lang,
					db_path,
				)
				return 1
			}
			r1 := matching_runs[len(matching_runs) - 2]
			r2 := matching_runs[len(matching_runs) - 1]
			base_label = strings.clone(r1, context.temp_allocator)
			cand_label = strings.clone(r2, context.temp_allocator)
			base_records = store.store_load_pooled_records(
				&st,
				lang,
				"",
				r1,
				filter,
				context.allocator,
			)
			cand_records = store.store_load_pooled_records(
				&st,
				lang,
				"",
				r2,
				filter,
				context.allocator,
			)
		}
	}

	if len(base_records) == 0 || len(cand_records) == 0 {
		fmt.eprintfln(
			"bench compare: no records for baseline (%d) or candidate (%d)",
			len(base_records),
			len(cand_records),
		)
		return 1
	}

	rep := store.compare_records(base_records, cand_records, threshold_pct, context.allocator)
	defer store.comparison_report_destroy(&rep)
	fmt.print(store.format_comparison_table(rep, base_label, cand_label, context.temp_allocator))

	if fail_on_reg && rep.regressions > 0 {
		return 1
	}
	return 0
}

@(private = "file")
_cmd_compare_1v1 :: proc(args: []string) -> int {
	db_flag := ""
	langs_arg := "odin,zig"
	commit := ""
	threshold_pct := 3.0

	i := 0
	for i < len(args) {
		key, inline_val, is_flag := _parse_flag_kv(args, &i)
		if !is_flag {
			fmt.eprintfln("bench compare-1v1: unexpected argument '%s'", args[i])
			return 1
		}
		switch key {
		case "h", "help":
			_print_help()
			return 0
		case "db":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			db_flag = v
		case "langs":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			langs_arg = v
		case "commit":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			commit = v
		case "threshold":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			parsed, p_ok := strconv.parse_f64(v)
			if !p_ok || parsed < 0 {
				fmt.eprintfln("bench compare-1v1: invalid --threshold '%s'", v)
				return 1
			}
			threshold_pct = parsed
		case:
			fmt.eprintfln("bench compare-1v1: unknown flag '--%s'", key)
			return 1
		}
	}

	parts := strings.split(langs_arg, ",", context.temp_allocator)
	if len(parts) != 2 ||
	   strings.trim_space(parts[0]) == "" ||
	   strings.trim_space(parts[1]) == "" {
		fmt.eprintfln(
			"bench compare-1v1: --langs requires two comma-separated languages, got '%s'",
			langs_arg,
		)
		return 1
	}
	lang_a := strings.trim_space(parts[0])
	lang_b := strings.trim_space(parts[1])

	db_path := _resolve_db_path(db_flag)
	st, open_ok := store.store_open(db_path, context.allocator)
	if !open_ok {
		fmt.eprintfln("bench compare-1v1: could not open store '%s'", db_path)
		return 1
	}
	defer store.store_close(&st)

	rep := store.compare_1v1_langs(&st, lang_a, lang_b, commit, threshold_pct, context.allocator)
	defer store.cross_lang_report_destroy(&rep)
	fmt.print(store.format_1v1_table(rep, context.temp_allocator))
	return 0
}

@(private = "file")
_cmd_export :: proc(args: []string) -> int {
	db_flag := ""
	format := ""
	out_path := ""
	commit := ""
	lang := "odin"
	filter := ""
	readme_path := ""

	i := 0
	for i < len(args) {
		key, inline_val, is_flag := _parse_flag_kv(args, &i)
		if !is_flag {
			fmt.eprintfln("bench export: unexpected argument '%s'", args[i])
			return 1
		}
		switch key {
		case "h", "help":
			_print_help()
			return 0
		case "db":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			db_flag = v
		case "format":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			format = strings.to_lower(v, context.temp_allocator)
		case "out":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			out_path = v
		case "commit":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			commit = v
		case "lang":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			lang = v
		case "filter", "f":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			filter = v
		case "update-readme":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			readme_path = v
		case:
			fmt.eprintfln("bench export: unknown flag '--%s'", key)
			return 1
		}
	}

	if format == "" && readme_path != "" {
		format = "md"
	}
	if format == "" {
		fmt.eprintln("bench export: --format <arrow|jsonl|csv|md> is required")
		return 1
	}
	if out_path == "" && readme_path == "" {
		fmt.eprintln("bench export: --out <path> (or --update-readme <path>) is required")
		return 1
	}

	db_path := _resolve_db_path(db_flag)
	st, open_ok := store.store_open(db_path, context.allocator)
	if !open_ok {
		fmt.eprintfln("bench export: could not open store '%s'", db_path)
		return 1
	}
	defer store.store_close(&st)

	records := store.store_load_pooled_records(&st, lang, commit, "", filter, context.allocator)
	defer store.pooled_records_destroy(records)
	if len(records) == 0 {
		fmt.eprintfln("bench export: no matching records (lang=%s, commit=%q)", lang, commit)
		return 1
	}

	if out_path != "" {
		ok := false
		switch format {
		case "arrow", "feather":
			ok = store.export_arrow_ipc(out_path, records, .Zlib_BSS, context.allocator)
		case "jsonl":
			ok = store.export_jsonl(out_path, records)
		case "csv":
			ok = store.export_csv(out_path, records)
		case "md", "markdown":
			ok = store.export_markdown(out_path, records)
		case:
			fmt.eprintfln(
				"bench export: unsupported format '%s' (expected arrow|jsonl|csv|md)",
				format,
			)
			return 1
		}
		if !ok {
			fmt.eprintfln("bench export: failed writing %s export to '%s'", format, out_path)
			return 1
		}
		if fi, s_err := os.stat(out_path, context.temp_allocator); s_err == nil {
			fmt.printfln(
				"Exported %d record(s) (%s) -> %s (%d bytes)",
				len(records),
				format,
				out_path,
				fi.size,
			)
		} else {
			fmt.printfln("Exported %d record(s) (%s) -> %s", len(records), format, out_path)
		}
	}

	if readme_path != "" {
		md := store.format_markdown_table(records, context.temp_allocator)
		if !store.update_readme_markers(readme_path, md) {
			fmt.eprintfln("bench export: failed updating benchmark markers in '%s'", readme_path)
			return 1
		}
		fmt.printfln("Updated benchmark table in %s", readme_path)
	}

	return 0
}

@(private = "file")
_cmd_compact :: proc(args: []string) -> int {
	db_flag := ""
	i := 0
	for i < len(args) {
		key, inline_val, is_flag := _parse_flag_kv(args, &i)
		if !is_flag {
			fmt.eprintfln("bench compact: unexpected argument '%s'", args[i])
			return 1
		}
		switch key {
		case "h", "help":
			_print_help()
			return 0
		case "db":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return 1}
			db_flag = v
		case:
			fmt.eprintfln("bench compact: unknown flag '--%s'", key)
			return 1
		}
	}

	db_path := _resolve_db_path(db_flag)
	before, after, ok := store.store_compact(db_path)
	if !ok {
		fmt.eprintfln("bench compact: failed to compact '%s'", db_path)
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

main :: proc() {
	args := os.args[1:] if len(os.args) > 1 else nil
	if len(args) == 0 {
		_print_help()
		os.exit(0)
	}

	code := 0
	switch args[0] {
	case "run":
		code = _cmd_run(args[1:])
	case "ingest":
		code = _cmd_ingest(args[1:])
	case "history":
		code = _cmd_history(args[1:])
	case "inspect":
		code = _cmd_inspect(args[1:])
	case "compare":
		code = _cmd_compare(args[1:])
	case "compare-1v1":
		code = _cmd_compare_1v1(args[1:])
	case "export":
		code = _cmd_export(args[1:])
	case "compact":
		code = _cmd_compact(args[1:])
	case "help", "--help", "-h":
		_print_help()
	case "version", "--version", "-V":
		fmt.println(VERSION)
	case:
		fmt.eprintfln("bench: unknown command '%s' (run 'bench help' for usage)", args[0])
		code = 1
	}
	os.exit(code)
}
