package hugi_cli

import hugi "../../hugi"
import store "../../store"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

@(private = "file")
_Ols_Collection :: struct {
	name: string `json:"name"`,
	path: string `json:"path"`,
}

@(private = "file")
_Ols_File :: struct {
	collections:  []_Ols_Collection `json:"collections"`,
	checker_args: string `json:"checker_args"`,
}

@(private = "file")
_Run_Opts :: struct {
	pkg_dir:           string,
	has_pkg:           bool,
	common:            _Common_Opts,
	no_db:             bool,
	runs:              string,
	warmup:            string,
	groups:            string,
	baseline_commit:   string,
	fail_on_reg:       bool,
	extra_build_flags: string,
	quiet:             bool,
	overlay:           bool,
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
		fmt.eprintfln("hugi: failed to start '%s': %v", cmd[0], start_err)
		return false
	}
	state, wait_err := os.process_wait(child)
	return wait_err == nil && state.exited && state.exit_code == 0
}

@(private = "file")
_is_hugi_repo_root :: proc(dir: string) -> bool {
	hugi_file, _ := filepath.join({dir, "hugi", "hugi.odin"}, context.temp_allocator)
	obench_dir, _ := filepath.join({dir, "deps", "obench", "obench"}, context.temp_allocator)
	return os.exists(hugi_file) && os.is_dir(obench_dir)
}

@(private = "file")
_find_hugi_repo_root_upward :: proc(start_dir: string) -> string {
	cur := start_dir
	for cur != "" {
		if _is_hugi_repo_root(cur) {
			return cur
		}
		parent := filepath.dir(cur)
		if parent == cur || parent == "." || parent == "" {
			break
		}
		cur = parent
	}
	return ""
}

@(private = "file")
_resolve_hugi_repo_root :: proc() -> string {
	if env_home, found := os.lookup_env("HUGI_HOME", context.temp_allocator);
	   found && env_home != "" && _is_hugi_repo_root(env_home) {
		return env_home
	}
	if exe_dir, err := os.get_executable_directory(context.temp_allocator);
	   err == nil && exe_dir != "" {
		if root := _find_hugi_repo_root_upward(exe_dir); root != "" {
			return root
		}
	}
	if cwd, err := os.get_working_directory(context.temp_allocator); err == nil && cwd != "" {
		if root := _find_hugi_repo_root_upward(cwd); root != "" {
			return root
		}
	}
	return ""
}

@(private)
_is_reserved_collection :: proc "contextless" (name: string) -> bool {
	return name == "core" || name == "base" || name == "vendor"
}

@(private = "file")
_read_nearest_ols :: proc(start_dir: string) -> (ols_dir: string, doc: _Ols_File, ok: bool) {
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
			if read_err == nil &&
			   json.unmarshal(data, &doc, allocator = context.temp_allocator) == nil {
				return cur, doc, true
			}
			break
		}
		git_marker, _ := filepath.join({cur, ".git"}, context.temp_allocator)
		if os.exists(git_marker) {
			break
		}
		parent := filepath.dir(cur)
		if parent == cur || parent == "." || parent == "" {
			break
		}
		cur = parent
	}
	return "", {}, false
}

@(private)
_discover_ols_collections :: proc(start_dir: string) -> [dynamic]string {
	result := make([dynamic]string, context.temp_allocator)
	ols_dir, doc, ok := _read_nearest_ols(start_dir)
	if !ok {
		return result
	}
	for col in doc.collections {
		if col.name == "" || col.path == "" || _is_reserved_collection(col.name) {
			continue
		}
		resolved := col.path
		if !filepath.is_abs(col.path) {
			resolved, _ = filepath.join({ols_dir, col.path}, context.temp_allocator)
		}
		append(&result, fmt.tprintf("%s=%s", col.name, resolved))
	}
	return result
}

@(private)
_discover_ols_build_flags :: proc(start_dir: string) -> [dynamic]string {
	result := make([dynamic]string, context.temp_allocator)
	_, doc, ok := _read_nearest_ols(start_dir)
	if !ok || doc.checker_args == "" {
		return result
	}
	for tok in strings.fields(doc.checker_args, context.temp_allocator) {
		if strings.has_prefix(tok, "-custom-attribute:") || tok == "-ignore-unknown-attributes" {
			append(&result, tok)
		}
	}
	return result
}

@(private)
_collection_name :: proc "contextless" (entry: string) -> string {
	if eq := strings.index_byte(entry, '='); eq > 0 {
		return entry[:eq]
	}
	return entry
}

@(private)
_has_opt_flag :: proc(flags: []string) -> bool {
	for tok in flags {
		if strings.has_prefix(tok, "-o:") {
			return true
		}
	}
	return false
}

@(private = "file")
_parse_run_args :: proc(args: []string) -> (opts: _Run_Opts, exit_code: int, done: bool) {
	opts.pkg_dir = "."
	opts.common.lang = "odin"
	opts.common.threshold_pct = 5.0

	allowed := _Common_Flag_Set{.DB, .Lang, .Commit, .Filter, .Threshold}
	i := 0
	for i < len(args) {
		key, inline_val, is_flag := _parse_flag_kv(args, &i)
		if !is_flag {
			if !opts.has_pkg {
				opts.pkg_dir = args[i]
				opts.has_pkg = true
				i += 1
				continue
			}
			fmt.eprintfln("hugi run: unexpected argument '%s'", args[i])
			return opts, 1, true
		}

		switch _try_parse_common_flag("run", key, inline_val, args, &i, allowed, &opts.common) {
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
		case "no-db":
			opts.no_db = true
		case "overlay":
			opts.overlay = true
		case "quiet":
			opts.quiet = true
		case "fail-on-regression":
			opts.fail_on_reg = true
		case "runs":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return opts, 1, true}
			opts.runs = v
		case "warmup":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return opts, 1, true}
			opts.warmup = v
		case "groups", "group":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return opts, 1, true}
			opts.groups = v
		case "baseline-commit":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return opts, 1, true}
			opts.baseline_commit = v
		case "extra-build-flags":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {return opts, 1, true}
			opts.extra_build_flags = v
		case:
			fmt.eprintfln("hugi run: unknown flag '--%s'", key)
			return opts, 1, true
		}
	}
	return opts, 0, false
}

@(private = "file")
_build_run_binary :: proc(opts: _Run_Opts, bin_path: string) -> bool {
	ols_flags := _discover_ols_build_flags(opts.pkg_dir)
	extra_flags :=
		_split_shell_tokens(opts.extra_build_flags, context.temp_allocator) if opts.extra_build_flags != "" else nil

	build_cmd := make([dynamic]string, context.temp_allocator)
	append(&build_cmd, _odin_executable(), "build", opts.pkg_dir, fmt.tprintf("-out:%s", bin_path))
	if !_has_opt_flag(ols_flags[:]) && !_has_opt_flag(extra_flags) {
		append(&build_cmd, "-o:speed")
	}

	seen_cols := make(map[string]bool, context.temp_allocator)
	for col in _discover_ols_collections(opts.pkg_dir) {
		name := _collection_name(col)
		if !_is_reserved_collection(name) && name not_in seen_cols {
			append(&build_cmd, fmt.tprintf("-collection:%s", col))
			seen_cols[name] = true
		}
	}
	if repo_root := _resolve_hugi_repo_root(); repo_root != "" {
		if "hugi" not_in seen_cols {
			h_dir, _ := filepath.join({repo_root, "hugi"}, context.temp_allocator)
			append(&build_cmd, fmt.tprintf("-collection:hugi=%s", h_dir))
			seen_cols["hugi"] = true
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
	seen_flags := make(map[string]bool, context.temp_allocator)
	for tok in ols_flags {
		if tok != "" && tok not_in seen_flags {
			append(&build_cmd, tok)
			seen_flags[tok] = true
		}
	}
	for tok in extra_flags {
		if tok != "" && tok not_in seen_flags {
			append(&build_cmd, tok)
			seen_flags[tok] = true
		}
	}

	if !_run_process(build_cmd[:]) {
		fmt.eprintfln("hugi run: build failed for '%s'", opts.pkg_dir)
		return false
	}
	if !os.exists(bin_path) {
		fmt.eprintfln("hugi run: compiler did not emit '%s'", bin_path)
		return false
	}
	return true
}

@(private = "file")
_exec_run_binary :: proc(opts: _Run_Opts, bin_path, pkt_path: string) -> (run_ok, has_pkt: bool) {
	run_cmd := make([dynamic]string, context.temp_allocator)
	append(&run_cmd, bin_path, "--packet-out", pkt_path)
	if opts.runs != "" {
		append(&run_cmd, "--runs", opts.runs)
	}
	if opts.warmup != "" {
		append(&run_cmd, "--warmup", opts.warmup)
	}
	if opts.groups != "" {
		append(&run_cmd, "--groups", opts.groups)
	}
	if opts.common.filter != "" {
		append(&run_cmd, "--filter", opts.common.filter)
	}
	if opts.common.lang != "" {
		append(&run_cmd, "--lang", opts.common.lang)
	}
	if opts.common.commit != "" {
		append(&run_cmd, "--commit", opts.common.commit)
	}
	if opts.quiet {
		append(&run_cmd, "--quiet")
	}

	run_ok = _run_process(run_cmd[:])
	if !os.exists(pkt_path) {
		if run_ok {
			fmt.eprintfln("hugi run: binary exited cleanly but did not write '%s'", pkt_path)
		}
		return run_ok, false
	}
	return run_ok, true
}

@(private = "file")
_ingest_and_compare_run_packet :: proc(opts: _Run_Opts, pkt: hugi.Run_Packet) -> int {
	db_path := _resolve_db_path(opts.common.db_flag)
	st: store.Store
	open_ok: bool
	using_overlay := false
	if opts.overlay && os.exists(db_path) {
		st, open_ok = store.store_open_overlay(db_path, context.allocator)
		using_overlay = true
	} else if opts.overlay {
		st, open_ok = store.store_open(":memory:", context.allocator)
		using_overlay = true
	} else {
		st, open_ok = store.store_open(db_path, context.allocator)
	}
	if !open_ok {
		fmt.eprintfln("hugi run: could not open store '%s'", db_path)
		return 1
	}
	defer store.store_close(&st)

	if !store.store_ingest_packet(&st, pkt) {
		fmt.eprintfln("hugi run: failed to ingest run packet into '%s'", db_path)
		return 1
	}

	total_samples := 0
	for &r in pkt.records {
		total_samples += len(r.samples_batch_ns) > 0 ? len(r.samples_batch_ns) : r.samples
	}
	if using_overlay {
		fmt.printfln(
			"Ingested run %s (commit=%s, lang=%s, records=%d, samples=%d) -> [overlay over %s; +%d RAM bytes, disk untouched]",
			pkt.run_id,
			pkt.commit,
			pkt.lang,
			len(pkt.records),
			total_samples,
			db_path,
			store.store_overlay_owned_bytes(&st),
		)
	} else {
		fmt.printfln(
			"Ingested run %s (commit=%s, lang=%s, records=%d, samples=%d) -> %s",
			pkt.run_id,
			pkt.commit,
			pkt.lang,
			len(pkt.records),
			total_samples,
			db_path,
		)
	}

	if opts.baseline_commit != "" {
		base := store.store_load_pooled_records(
			&st,
			opts.common.lang,
			opts.baseline_commit,
			"",
			opts.common.filter,
			context.allocator,
		)
		defer store.pooled_records_destroy(base)
		cand := store.store_load_pooled_records(
			&st,
			opts.common.lang,
			pkt.commit,
			"",
			opts.common.filter,
			context.allocator,
		)
		defer store.pooled_records_destroy(cand)

		if len(base) == 0 || len(cand) == 0 {
			fmt.eprintfln(
				"hugi run: insufficient baseline (%d) or candidate (%d) records for commit comparison",
				len(base),
				len(cand),
			)
			return 1
		}
		rep := store.compare_records(base, cand, opts.common.threshold_pct, context.allocator)
		defer store.comparison_report_destroy(&rep)
		fmt.print(
			store.format_comparison_table(
				rep,
				opts.baseline_commit,
				pkt.commit,
				context.temp_allocator,
			),
		)
		if opts.fail_on_reg && rep.regressions > 0 {
			return 1
		}
	}
	return 0
}

@(private)
_cmd_run :: proc(args: []string) -> int {
	opts, exit_code, done := _parse_run_args(args)
	if done {
		return exit_code
	}

	if !os.exists(opts.pkg_dir) {
		fmt.eprintfln("hugi run: package path does not exist: '%s'", opts.pkg_dir)
		return 1
	}

	tmp_dir, t_err := os.temp_directory(context.temp_allocator)
	if t_err != nil || tmp_dir == "" {
		tmp_dir = "/tmp"
	}
	pid := os.get_pid()
	ts := time.to_unix_nanoseconds(time.now())

	bin_name := fmt.tprintf("odin_hugi_%d_%d", pid, ts)
	when ODIN_OS == .Windows {
		bin_name = fmt.tprintf("odin_hugi_%d_%d.exe", pid, ts)
	}
	bin_path, _ := filepath.join({tmp_dir, bin_name}, context.temp_allocator)
	pkt_path, _ := filepath.join(
		{tmp_dir, fmt.tprintf("odin_hugi_pkt_%d_%d.hpk", pid, ts)},
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

	if !_build_run_binary(opts, bin_path) {
		return 1
	}

	run_ok, has_pkt := _exec_run_binary(opts, bin_path, pkt_path)
	if !has_pkt {
		return 1
	}

	pkt, pkt_ok := hugi.read_packet_file(pkt_path, context.allocator)
	if !pkt_ok {
		fmt.eprintfln("hugi run: failed to decode packet '%s'", pkt_path)
		return 1
	}
	defer hugi.packet_destroy(&pkt)

	if !opts.no_db {
		if code := _ingest_and_compare_run_packet(opts, pkt); code != 0 {
			return code
		}
	}

	return run_ok ? 0 : 1
}
