package hugi_cli

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
test_cli_parse_flag_kv_and_consume_value :: proc(t: ^testing.T) {
	args := []string{"--db=my.hugidb", "-f:bench", "--lang", "zig", "-", "pkg_dir", "--quiet"}
	idx := 0

	k, v, is_flag := _parse_flag_kv(args, &idx)
	testing.expect(t, is_flag)
	testing.expect_value(t, k, "db")
	testing.expect_value(t, v, "my.hugidb")
	val, v_ok := _consume_value(args, &idx, v, k)
	testing.expect(t, v_ok)
	testing.expect_value(t, val, "my.hugidb")
	testing.expect_value(t, idx, 1)

	k, v, is_flag = _parse_flag_kv(args, &idx)
	testing.expect(t, is_flag)
	testing.expect_value(t, k, "f")
	testing.expect_value(t, v, "bench")
	val, v_ok = _consume_value(args, &idx, v, k)
	testing.expect(t, v_ok)
	testing.expect_value(t, val, "bench")
	testing.expect_value(t, idx, 2)

	k, v, is_flag = _parse_flag_kv(args, &idx)
	testing.expect(t, is_flag)
	testing.expect_value(t, k, "lang")
	testing.expect_value(t, v, "")
	val, v_ok = _consume_value(args, &idx, v, k)
	testing.expect(t, v_ok)
	testing.expect_value(t, val, "zig")
	testing.expect_value(t, idx, 4)

	k, v, is_flag = _parse_flag_kv(args, &idx)
	testing.expect(t, !is_flag, "single '-' is positional, not a flag")
	testing.expect_value(t, idx, 4)
	idx += 1

	k, v, is_flag = _parse_flag_kv(args, &idx)
	testing.expect(t, !is_flag, "positional argument is not a flag")
	testing.expect_value(t, idx, 5)
	idx += 1

	k, v, is_flag = _parse_flag_kv(args, &idx)
	testing.expect(t, is_flag)
	testing.expect_value(t, k, "quiet")
	testing.expect_value(t, v, "")
	_, missing_ok := _consume_value(args, &idx, v, k)
	testing.expect(t, !missing_ok, "missing trailing value must return false")
}

@(test)
test_cli_common_flags_and_split_range :: proc(t: ^testing.T) {
	opts := _Common_Opts {
		lang          = "odin",
		threshold_pct = 5.0,
	}
	allowed := _Common_Flag_Set{.DB, .Lang, .Filter, .Threshold}

	args := []string{"--db", "a.hugidb", "--lang=zig", "-f", "kv::", "--threshold", "2.5"}
	idx := 0
	for idx < len(args) {
		k, iv, is_flag := _parse_flag_kv(args, &idx)
		testing.expect(t, is_flag)
		st := _try_parse_common_flag("test", k, iv, args, &idx, allowed, &opts)
		testing.expect_value(t, st, _Flag_Parse_Status.Matched)
	}
	testing.expect_value(t, opts.db_flag, "a.hugidb")
	testing.expect_value(t, opts.lang, "zig")
	testing.expect_value(t, opts.filter, "kv::")
	testing.expect_value(t, opts.threshold_pct, 2.5)

	// Disallowed flag returns .Not_Matched without consuming next arg.
	commit_args := []string{"--commit", "abc123"}
	cidx := 0
	ck, civ, _ := _parse_flag_kv(commit_args, &cidx)
	testing.expect_value(
		t,
		_try_parse_common_flag("test", ck, civ, commit_args, &cidx, allowed, &opts),
		_Flag_Parse_Status.Not_Matched,
	)

	// Invalid negative threshold returns .Error.
	bad_args := []string{"--threshold", "-1.0"}
	bidx := 0
	bk, biv, _ := _parse_flag_kv(bad_args, &bidx)
	testing.expect_value(
		t,
		_try_parse_common_flag("test", bk, biv, bad_args, &bidx, allowed, &opts),
		_Flag_Parse_Status.Error,
	)

	// Help flag returns .Help.
	help_args := []string{"--help"}
	hidx := 0
	hk, hiv, _ := _parse_flag_kv(help_args, &hidx)
	testing.expect_value(
		t,
		_try_parse_common_flag("test", hk, hiv, help_args, &hidx, allowed, &opts),
		_Flag_Parse_Status.Help,
	)

	// Range splitting.
	a, b, r_ok := _split_range("  abc123 .. def456 ")
	testing.expect(t, r_ok)
	testing.expect_value(t, a, "abc123")
	testing.expect_value(t, b, "def456")

	for bad in ([]string{"abc", "..def", "abc..", " .. "}) {
		_, _, ok := _split_range(bad)
		testing.expectf(t, !ok, "range %q should be rejected", bad)
	}
}

@(test)
test_cli_infer_export_format_resolve_db_and_collections :: proc(t: ^testing.T) {
	testing.expect_value(t, _infer_export_format("Parquet", "", ""), "parquet")
	testing.expect_value(t, _infer_export_format("", "out/res.arrow", ""), "arrow")
	testing.expect_value(t, _infer_export_format("", "out/res.feather", ""), "arrow")
	testing.expect_value(t, _infer_export_format("", "out/res.ipc", ""), "arrow")
	testing.expect_value(t, _infer_export_format("", "out/res.PARQUET", ""), "parquet")
	testing.expect_value(t, _infer_export_format("", "out/res.pq", ""), "parquet")
	testing.expect_value(t, _infer_export_format("", "out/res.json", ""), "json")
	testing.expect_value(t, _infer_export_format("", "out/res.jsonl", ""), "jsonl")
	testing.expect_value(t, _infer_export_format("", "out/res.ndjson", ""), "jsonl")
	testing.expect_value(t, _infer_export_format("", "out/res.csv", ""), "csv")
	testing.expect_value(t, _infer_export_format("", "out/res.tsv", ""), "tsv")
	testing.expect_value(t, _infer_export_format("", "out/res.tab", ""), "tsv")
	testing.expect_value(t, _infer_export_format("", "out/res.md", ""), "md")
	testing.expect_value(t, _infer_export_format("", "out/res.markdown", ""), "md")
	testing.expect_value(t, _infer_export_format("", "", "README.md"), "md")
	testing.expect_value(t, _infer_export_format("", "out/res.unknown", ""), "")

	testing.expect_value(t, _resolve_db_path("custom/path.hugidb"), "custom/path.hugidb")
	default_db := _resolve_db_path("")
	testing.expect(
		t,
		default_db == "history.hugidb" ||
		default_db == "benchmarks/history.hugidb" ||
		default_db == "benchmarks/history.benchdb",
		"default db path should resolve to a canonical path",
	)

	testing.expect_value(t, _collection_name("hugi=./hugi"), "hugi")
	testing.expect_value(t, _collection_name("plain"), "plain")
	testing.expect(t, _is_reserved_collection("core"))
	testing.expect(t, _is_reserved_collection("base"))
	testing.expect(t, _is_reserved_collection("vendor"))
	testing.expect(t, !_is_reserved_collection("hugi"))

	testing.expect(t, _has_opt_flag([]string{"-o:none"}))
	testing.expect(t, _has_opt_flag([]string{"-vet", "-o:aggressive"}))
	testing.expect(t, !_has_opt_flag([]string{"-vet", "-strict-style"}))
	testing.expect(t, !_has_opt_flag([]string{}))
}

@(test)
test_cli_ols_discovery_and_export_validation :: proc(t: ^testing.T) {
	if !os.exists(".tmp") {
		_ = os.make_directory(".tmp")
	}
	base_dir := fmt.tprintf(".tmp/cli_ols_test_%d", os.get_pid())
	sub_dir, _ := filepath.join({base_dir, "sub", "nested"}, context.temp_allocator)
	iso_dir, _ := filepath.join({base_dir, "isolated"}, context.temp_allocator)
	iso_pkg, _ := filepath.join({iso_dir, "pkg"}, context.temp_allocator)
	iso_git, _ := filepath.join({iso_dir, ".git"}, context.temp_allocator)
	ols_path, _ := filepath.join({base_dir, "ols.json"}, context.temp_allocator)

	cleanup_paths := [?]string {
		ols_path,
		iso_git,
		iso_pkg,
		iso_dir,
		sub_dir,
		filepath.dir(sub_dir),
		base_dir,
	}
	for p in cleanup_paths {
		if os.exists(p) {
			_ = os.remove(p)
		}
	}
	defer {
		for p in cleanup_paths {
			if os.exists(p) {
				_ = os.remove(p)
			}
		}
	}

	_ = os.make_directory(base_dir)
	_ = os.make_directory(filepath.dir(sub_dir))
	_ = os.make_directory(sub_dir)
	_ = os.make_directory(iso_dir)
	_ = os.make_directory(iso_pkg)
	_ = os.make_directory(iso_git)

	ols_json := `{
		"collections": [
			{"name": "core", "path": "./bad_core"},
			{"name": "hugi", "path": "./hugi"},
			{"name": "ext", "path": "/opt/ext"}
		],
		"checker_args": "-vet -custom-attribute:my_attr -ignore-unknown-attributes -strict-style"
	}`
	testing.expect(t, os.write_entire_file(ols_path, transmute([]u8)ols_json) == nil)

	cols := _discover_ols_collections(sub_dir)
	testing.expect_value(t, len(cols), 2)
	if len(cols) == 2 {
		abs_base, _ := os.get_absolute_path(base_dir, context.temp_allocator)
		expected_hugi, _ := filepath.join({abs_base, "hugi"}, context.temp_allocator)
		testing.expect_value(t, cols[0], fmt.tprintf("hugi=%s", expected_hugi))
		testing.expect_value(t, cols[1], "ext=/opt/ext")
	}

	flags := _discover_ols_build_flags(sub_dir)
	testing.expect_value(t, len(flags), 2)
	if len(flags) == 2 {
		testing.expect_value(t, flags[0], "-custom-attribute:my_attr")
		testing.expect_value(t, flags[1], "-ignore-unknown-attributes")
	}

	// Upward search must stop at .git boundary and not leak parent ols.json.
	iso_cols := _discover_ols_collections(iso_pkg)
	testing.expect_value(t, len(iso_cols), 0)

	// Export flag validation checks.
	check_export :: proc(
		t: ^testing.T,
		args: []string,
		expect_ok: bool,
		expect_fmt := "",
		loc := #caller_location,
	) {
		opts, code, done := _parse_export_args(args)
		testing.expect(t, !done && code == 0, "parse_export_args should succeed", loc = loc)
		_, ok := _validate_export_opts(&opts)
		testing.expect_value(t, ok, expect_ok, loc = loc)
		if expect_ok && expect_fmt != "" {
			testing.expect_value(t, opts.format, expect_fmt, loc = loc)
		}
	}

	check_export(t, []string{"--all-commits", "--all-runs", "--out", "a.csv"}, false)
	check_export(t, []string{"--all-commits", "--commit", "abc", "--out", "a.csv"}, false)
	check_export(t, []string{"--all-runs", "--commit", "abc", "--out", "a.csv"}, false)
	check_export(t, []string{"--format", "csv"}, false)
	check_export(t, []string{"--out", "a.unknown"}, false)
	check_export(t, []string{"--out", "a.parquet"}, true, "parquet")
	check_export(t, []string{"--all-commits", "--out", "series.arrow"}, true, "arrow")
	check_export(t, []string{"--update-readme", "README.md"}, true, "md")
	check_export(t, []string{"--format", "jsonl", "--out", "-"}, true, "jsonl")
	check_export(t, []string{"--format", "arrow", "--out", "-"}, false)
	check_export(t, []string{"--format", "parquet", "--out", "-"}, false)
	check_export(t, []string{"--out", "-"}, false)

	testing.expect_value(t, _infer_report_format("", ""), "md")
	testing.expect_value(t, _infer_report_format("", "rep.json"), "json")
	testing.expect_value(t, _infer_report_format("", "rep.csv"), "csv")
	testing.expect_value(t, _infer_report_format("Markdown", ""), "md")
	testing.expect_value(t, _infer_report_format("JSON", "-"), "json")

	toks := _split_shell_tokens(
		`-o:speed -extra-linker-flags:"-L/home/pauli/.local/lib -Wl,-rpath,/home/pauli/.local/lib" -define:MSG="a \"b\"" 'plain arg'`,
		context.temp_allocator,
	)
	testing.expect_value(t, len(toks), 4)
	if len(toks) == 4 {
		testing.expect_value(t, toks[0], "-o:speed")
		testing.expect_value(
			t,
			toks[1],
			"-extra-linker-flags:-L/home/pauli/.local/lib -Wl,-rpath,/home/pauli/.local/lib",
		)
		testing.expect_value(t, toks[2], `-define:MSG=a "b"`)
		testing.expect_value(t, toks[3], "plain arg")
	}

	l1, o1 := _normalize_lang("odin")
	testing.expect_value(t, l1, "odin")
	testing.expect(t, !o1, "already-lowercase lang must not allocate")

	l2, o2 := _normalize_lang("Zig")
	defer if o2 {delete(l2)}
	testing.expect_value(t, l2, "zig")
	testing.expect(t, o2, "mixed-case lang must allocate normalized string")

	l3, o3 := _normalize_lang("ODIN")
	defer if o3 {delete(l3)}
	testing.expect_value(t, l3, "odin")
	testing.expect(t, o3, "uppercase lang must allocate normalized string")
}
