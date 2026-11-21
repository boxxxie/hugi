package hugi_specs

import hugi "../hugi"
import store "../store"
import "base:runtime"
import "core:fmt"
import "core:math"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

Verdict :: store.Verdict

Export_Format :: enum u8 {
	Arrow,
	Parquet,
	Json,
	Jsonl,
	Csv,
	Tsv,
	Markdown,
}

Export_Scope :: enum u8 {
	Snapshot,
	All_Commits,
	All_Runs,
}

Metric_Spec :: struct {
	unit:  string,
	value: f64,
}

Bench_Observation :: struct {
	name:              string,
	group:             string,
	param:             int,
	has_param:         bool,
	threads:           int,
	has_threads:       bool,
	median_ns:         f64,
	spread_ns:         f64,
	no_spread:         bool,
	samples:           int,
	zero_samples:      bool,
	ops_per_sample:    u64,
	bytes_per_op:      u64,
	zero_bytes_per_op: bool,
	items_per_op:      u64,
	footprint_bytes:   u64,
	rank:              int,
	allocs_per_op:     f64,
	peak_heap_bytes:   i64,
	zero_alloc_failed: bool,
	error:             string,
	metric_unit:       string,
	metric_value:      f64,
	metrics:           []Metric_Spec,
	exact_batch_ns:    []u64,
}

Phase_Spec :: struct {
	name:             string,
	parent:           string,
	ops:              int,
	bytes_per_op:     u64,
	zero_alloc:       bool,
	allocates:        bool,
	footprint_bytes:  u64,
	has_footprint:    bool,
	metric_unit:      string,
	metric_value:     f64,
	has_metric:       bool,
	secondary_metric: string,
	secondary_value:  f64,
	has_secondary:    bool,
}

Benchmark_View :: struct {
	full_name:         string,
	commit:            string,
	lang:              string,
	run_count:         int,
	samples:           int,
	ops_per_sample:    u64,
	min_fs:            i64,
	p50_fs:            i64,
	max_fs:            i64,
	param:             int,
	has_param:         bool,
	threads:           int,
	has_threads:       bool,
	items_per_op:      u64,
	footprint_bytes:   u64,
	zero_alloc_failed: bool,
	error:             string,
	metrics:           []hugi.Metric,
	samples_fs_len:    int,
	batch_sample_len:  int,
	first_batch_ns:    u64,
	last_batch_ns:     u64,
}

Comparison_Row_View :: struct {
	full_name:      string,
	delta_pct:      f64,
	p_value:        f64,
	is_significant: bool,
	verdict:        Verdict,
}

Cross_Lang_Row_View :: struct {
	full_name:          string,
	faster_lang:        string,
	p_value:            f64,
	is_significant:     bool,
	footprint_mismatch: bool,
}

CLI_Output_View :: struct {
	started:   bool,
	exit_code: int,
	stdout:    string,
	stderr:    string,
}

Verdict_Matrix_Case :: struct {
	name:             string,
	base_ns:          f64,
	cand_ns:          f64,
	threshold_pct:    f64,
	expected_verdict: Verdict,
	expected_sig:     bool,
	loc:              runtime.Source_Code_Location,
}

verdict_case :: proc(
	name: string,
	base_ns, cand_ns, threshold_pct: f64,
	expected_verdict: Verdict,
	expected_sig: bool,
	loc := #caller_location,
) -> Verdict_Matrix_Case {
	return Verdict_Matrix_Case {
		name = name,
		base_ns = base_ns,
		cand_ns = cand_ns,
		threshold_pct = threshold_pct,
		expected_verdict = expected_verdict,
		expected_sig = expected_sig,
		loc = loc,
	}
}

Export_Format_Case :: struct {
	label:         string,
	format:        Export_Format,
	expected_cols: int,
	loc:           runtime.Source_Code_Location,
}

export_format_case :: proc(
	label: string,
	format: Export_Format,
	expected_cols: int,
	loc := #caller_location,
) -> Export_Format_Case {
	return Export_Format_Case {
		label = label,
		format = format,
		expected_cols = expected_cols,
		loc = loc,
	}
}

CLI_Guard_Case :: struct {
	label:           string,
	args:            []string,
	expected_stderr: string,
	loc:             runtime.Source_Code_Location,
}

cli_guard_case :: proc(
	label: string,
	args: []string,
	expected_stderr: string,
	loc := #caller_location,
) -> CLI_Guard_Case {
	return CLI_Guard_Case{label = label, args = args, expected_stderr = expected_stderr, loc = loc}
}

@(private = "file")
_Temp_Dir_Guard :: struct {
	path: string,
}

@(private = "file")
_cleanup_temp_dir_guard :: proc(raw: rawptr) {
	if raw == nil {
		return
	}
	guard := (^_Temp_Dir_Guard)(raw)
	if guard.path != "" {
		_ = os.remove_all(guard.path)
		delete(guard.path)
	}
	free(guard)
}

World :: struct {
	t:                     ^testing.T,
	arena:                 vmem.Arena,
	work_dir:              string,
	db_path:               string,
	files:                 map[string]string,
	db_store:              store.Store,
	store_open:            bool,
	overlay:               store.Store,
	overlay_open:          bool,
	disk_snapshot:         []u8,
	suite:                 hugi.Suite,
	suite_active:          bool,
	suite_executed:        bool,
	suite_ok:              bool,
	suite_pkt_label:       string,
	last_ingest_ok:        bool,
	last_compact_before:   i64,
	last_compact_after:    i64,
	last_compact_ok:       bool,
	last_export_ok:        bool,
	last_export_path:      string,
	last_export_format:    Export_Format,
	last_readme_ok:        bool,
	last_runs:             []store.Run_Summary,
	last_commits:          []store.Commit_Summary,
	last_pooled:           []store.Pooled_Record,
	last_packets:          []hugi.Run_Packet,
	last_terminal_summary: string,
	last_comparison:       store.Comparison_Report,
	has_comparison:        bool,
	last_1v1:              store.Cross_Lang_Report,
	has_1v1:               bool,
	cli_bin:               string,
	last_cli:              _CLI_Result,
}

@(private = "file")
_world_clear_runs :: proc(w: ^World) {
	if w.last_runs != nil {
		store.run_summaries_destroy(w.last_runs)
		w.last_runs = nil
	}
}

@(private = "file")
_world_clear_commits :: proc(w: ^World) {
	if w.last_commits != nil {
		store.commit_summaries_destroy(w.last_commits)
		w.last_commits = nil
	}
}

@(private = "file")
_world_clear_pooled :: proc(w: ^World) {
	if w.last_pooled != nil {
		store.pooled_records_destroy(w.last_pooled)
		w.last_pooled = nil
	}
}

@(private = "file")
_world_clear_packets :: proc(w: ^World) {
	if w.last_packets != nil {
		hugi.packets_destroy(w.last_packets)
		w.last_packets = nil
	}
}

@(private = "file")
_world_clear_comparison :: proc(w: ^World) {
	if w.has_comparison {
		store.comparison_report_destroy(&w.last_comparison)
		w.has_comparison = false
	}
}

@(private = "file")
_world_clear_1v1 :: proc(w: ^World) {
	if w.has_1v1 {
		store.cross_lang_report_destroy(&w.last_1v1)
		w.has_1v1 = false
	}
}

@(private = "file")
_world_reset_queries :: proc(w: ^World) {
	_world_clear_runs(w)
	_world_clear_commits(w)
	_world_clear_pooled(w)
	_world_clear_packets(w)
	_world_clear_comparison(w)
	_world_clear_1v1(w)
	w.last_ingest_ok = false
	w.last_compact_before = 0
	w.last_compact_after = 0
	w.last_compact_ok = false
	w.last_export_ok = false
	w.last_export_path = ""
	w.last_readme_ok = false
	w.last_terminal_summary = ""
}

@(private = "file")
_world_close_stores :: proc(w: ^World) {
	if w.overlay_open {
		_driver_store_close(&w.overlay)
		w.overlay_open = false
	}
	if w.store_open {
		_driver_store_close(&w.db_store)
		w.store_open = false
	}
}

@(private = "file")
_world_active_store :: proc(w: ^World, loc := #caller_location) -> (^store.Store, bool) {
	if w.overlay_open {
		return &w.overlay, true
	}
	if w.store_open {
		return &w.db_store, true
	}
	testing.expect(w.t, false, "no open store in World", loc = loc)
	return nil, false
}

@(private = "file")
_world_ensure_work_dir :: proc(w: ^World, loc := #caller_location) -> (string, bool) {
	if w.work_dir != "" {
		return w.work_dir, true
	}
	dir, err := os.make_directory_temp("", "hugi-spec-*", context.allocator)
	if !testing.expectf(w.t, err == nil && dir != "", "create temp work dir: %v", err, loc = loc) {
		if dir != "" {
			delete(dir)
		}
		return "", false
	}
	guard := new(_Temp_Dir_Guard)
	guard.path = dir
	testing.cleanup(w.t, _cleanup_temp_dir_guard, guard)
	w.work_dir = dir
	return dir, true
}

@(private = "file")
_world_resolve_label_path :: proc(
	w: ^World,
	label: string,
	default_ext := "",
	loc := #caller_location,
) -> (
	path: string,
	ok: bool,
) {
	if existing, found := w.files[label]; found {
		return existing, true
	}
	dir := _world_ensure_work_dir(w, loc) or_return
	arena_alloc := vmem.arena_allocator(&w.arena)
	fname := label
	if default_ext != "" && !strings.has_suffix(label, default_ext) {
		fname = fmt.tprintf("%s%s", label, default_ext)
	}
	joined, j_err := filepath.join({dir, fname}, arena_alloc)
	if !testing.expectf(w.t, j_err == nil, "join work path for %q: %v", label, j_err, loc = loc) {
		return "", false
	}
	w.files[strings.clone(label, arena_alloc)] = joined
	return joined, true
}

world_init :: proc(w: ^World, t: ^testing.T, loc := #caller_location) {
	w^ = {}
	w.t = t
	err := vmem.arena_init_growing(&w.arena)
	testing.expect_value(t, err, nil, loc = loc)
	w.files = make(map[string]string, 16)
}

world_destroy :: proc(w: ^World) {
	_world_close_stores(w)
	if w.suite_active {
		_driver_suite_destroy(&w.suite)
		w.suite_active = false
	}
	_world_clear_runs(w)
	_world_clear_commits(w)
	_world_clear_pooled(w)
	_world_clear_packets(w)
	_world_clear_comparison(w)
	_world_clear_1v1(w)
	if w.disk_snapshot != nil {
		delete(w.disk_snapshot)
		w.disk_snapshot = nil
	}
	_driver_cli_result_destroy(&w.last_cli)
	if w.cli_bin != "" {
		delete(w.cli_bin)
		w.cli_bin = ""
	}
	delete(w.files)
	vmem.arena_check_temp(&w.arena)
	vmem.arena_destroy(&w.arena)
	w^ = {}
}

world_set_timeout :: proc(w: ^World, seconds: int, loc := #caller_location) {
	testing.set_fail_timeout(w.t, time.Duration(seconds) * time.Second, loc = loc)
}

// ── Setup (Given) ───────────────────────────────────────────────────────────

given_in_memory_store :: proc(w: ^World, loc := #caller_location) {
	_world_close_stores(w)
	_world_reset_queries(w)
	st, ok := _driver_store_open(":memory:")
	if !testing.expect(w.t, ok, "open in-memory store", loc = loc) {
		return
	}
	w.db_store = st
	w.store_open = true
	w.db_path = ":memory:"
}

given_file_store :: proc(w: ^World, name := "history.hugidb", loc := #caller_location) {
	_world_close_stores(w)
	_world_reset_queries(w)
	path, p_ok := _world_resolve_label_path(w, name, ".hugidb", loc)
	if !p_ok {
		return
	}
	st, ok := _driver_store_open(path)
	if !testing.expect(w.t, ok, "open file store", loc = loc) {
		return
	}
	w.db_store = st
	w.store_open = true
	w.db_path = path
}

given_corrupt_store_file :: proc(w: ^World, name := "corrupt.hugidb", loc := #caller_location) {
	_world_close_stores(w)
	_world_reset_queries(w)
	path, p_ok := _world_resolve_label_path(w, name, ".hugidb", loc)
	if !p_ok {
		return
	}
	garbage := "CORRUPT_NON_XITDB_STORE_BYTES_0123456789"
	ok := _driver_write_file_bytes(path, transmute([]u8)garbage)
	testing.expect(w.t, ok, "write corrupt store fixture", loc = loc)
	w.db_path = path
}

given_store_write_options :: proc(
	w: ^World,
	keep_hot_runs := 0,
	cold_chunk_runs := 32,
	loc := #caller_location,
) {
	st, ok := _world_active_store(w, loc)
	if !ok {
		return
	}
	_driver_store_set_write_options(st, keep_hot_runs, cold_chunk_runs)
}

given_recorded_run_batch :: proc(
	w: ^World,
	commit, lang, run_id: string,
	benches: []Bench_Observation,
	selective := false,
	timestamp_unix: i64 = 1770000000,
	suite_name := "spec_suite",
	env := hugi.Run_Env{},
	loc := #caller_location,
) {
	st, ok := _world_active_store(w, loc)
	if !ok {
		return
	}
	pkt := _driver_build_packet(
		commit,
		lang,
		run_id,
		suite_name,
		benches,
		selective,
		timestamp_unix,
		env,
	)
	defer hugi.packet_destroy(&pkt)
	ing_ok := _driver_store_ingest_packet(st, pkt)
	w.last_ingest_ok = ing_ok
	testing.expect(w.t, ing_ok, "given_recorded_run ingest", loc = loc)
}

given_recorded_run_single :: proc(
	w: ^World,
	commit, lang, run_id: string,
	bench: Bench_Observation,
	selective := false,
	timestamp_unix: i64 = 1770000000,
	suite_name := "spec_suite",
	env := hugi.Run_Env{},
	loc := #caller_location,
) {
	arr := [1]Bench_Observation{bench}
	given_recorded_run_batch(
		w,
		commit,
		lang,
		run_id,
		arr[:],
		selective,
		timestamp_unix,
		suite_name,
		env,
		loc,
	)
}

given_recorded_run :: proc {
	given_recorded_run_single,
	given_recorded_run_batch,
}

given_suite :: proc(
	w: ^World,
	name: string,
	groups_filter := "",
	name_filter := "",
	packet_label := "",
	runs := 4,
	warmup := 1,
	loc := #caller_location,
) {
	if w.suite_active {
		_driver_suite_destroy(&w.suite)
		w.suite_active = false
	}
	_world_reset_queries(w)
	pkt_path := ""
	if packet_label != "" {
		resolved, p_ok := _world_resolve_label_path(w, packet_label, ".hpk", loc)
		if !p_ok {
			return
		}
		pkt_path = resolved
		w.suite_pkt_label = strings.clone(packet_label, vmem.arena_allocator(&w.arena))
	} else {
		w.suite_pkt_label = ""
	}
	w.suite = _driver_suite_create(name, groups_filter, name_filter, pkt_path, runs, warmup)
	w.suite_active = true
	w.suite_executed = false
	w.suite_ok = false
}

given_micro_benchmark :: proc(
	w: ^World,
	group, name: string,
	zero_alloc := false,
	allocates := false,
	params: []int = nil,
	thread_counts: []int = nil,
	loc := #caller_location,
) {
	if !testing.expect(
		w.t,
		w.suite_active,
		"given_suite must precede given_micro_benchmark",
		loc = loc,
	) {
		return
	}
	_driver_suite_add_micro(&w.suite, group, name, zero_alloc, allocates, params, thread_counts)
}

given_pipeline :: proc(
	w: ^World,
	group: string,
	phases: []Phase_Spec,
	param := 0,
	has_param := false,
	runs := 0,
	warmup := -1,
	loc := #caller_location,
) {
	if !testing.expect(w.t, w.suite_active, "given_suite must precede given_pipeline", loc = loc) {
		return
	}
	arena_alloc := vmem.arena_allocator(&w.arena)
	ctx := new(_Pipeline_Spec_Ctx, arena_alloc)
	cloned := make([]Phase_Spec, len(phases), arena_alloc)
	for ph, i in phases {
		cloned[i] = ph
		cloned[i].name = strings.clone(ph.name, arena_alloc)
		if ph.parent != "" {
			cloned[i].parent = strings.clone(ph.parent, arena_alloc)
		}
		if ph.metric_unit != "" {
			cloned[i].metric_unit = strings.clone(ph.metric_unit, arena_alloc)
		}
		if ph.secondary_metric != "" {
			cloned[i].secondary_metric = strings.clone(ph.secondary_metric, arena_alloc)
		}
	}
	ctx.phases = cloned
	_driver_suite_add_pipeline(
		&w.suite,
		group,
		ctx,
		param = param,
		has_param = has_param,
		runs = runs,
		warmup = warmup,
	)
}

given_packet_file :: proc(
	w: ^World,
	label, commit, lang, run_id: string,
	benches: []Bench_Observation,
	selective := false,
	timestamp_unix: i64 = 1770000000,
	suite_name := "spec_suite",
	env := hugi.Run_Env{},
	loc := #caller_location,
) {
	path, p_ok := _world_resolve_label_path(w, label, ".hpk", loc)
	if !p_ok {
		return
	}
	pkt := _driver_build_packet(
		commit,
		lang,
		run_id,
		suite_name,
		benches,
		selective,
		timestamp_unix,
		env,
	)
	defer hugi.packet_destroy(&pkt)
	ok := _driver_write_packet_file(path, pkt)
	testing.expect(w.t, ok, "write packet fixture", loc = loc)
}

given_legacy_jsonl_fixture :: proc(
	w: ^World,
	label, commit, lang, run_id, full_name: string,
	median_ns: f64,
	ops: u64 = 100,
	footprint_bytes: u64 = 1024,
	loc := #caller_location,
) {
	path, p_ok := _world_resolve_label_path(w, label, ".jsonl", loc)
	if !p_ok {
		return
	}
	ok := _driver_write_jsonl_fixture(
		path,
		commit,
		lang,
		run_id,
		full_name,
		median_ns,
		ops,
		footprint_bytes,
	)
	testing.expect(w.t, ok, "write legacy jsonl fixture", loc = loc)
}

given_obench_report_fixture :: proc(
	w: ^World,
	label, suite_name, group_name, bench_name: string,
	median_ns: f64,
	batch_size: u64 = 10,
	loc := #caller_location,
) {
	path, p_ok := _world_resolve_label_path(w, label, ".json", loc)
	if !p_ok {
		return
	}
	ok := _driver_write_obench_json_fixture(
		path,
		suite_name,
		group_name,
		bench_name,
		median_ns,
		batch_size,
	)
	testing.expect(w.t, ok, "write obench report fixture", loc = loc)
}

given_obench_v6_report_fixture :: proc(
	w: ^World,
	label, suite_name, group_name, bench_name: string,
	commit := "v6commit1234",
	created_at := "2026-11-20T08:30:00Z",
	cpu := "AMD Ryzen 7 7735U",
	governor := "performance",
	boost := "on",
	microarch := "native",
	bounds_checks := "off",
	median_ns: f64 = 12.1,
	batch_size: u64 = 10,
	peak_heap_bytes: i64 = 4096,
	zero_alloc_failed := false,
	instructions: f64 = 0,
	loc := #caller_location,
) {
	path, p_ok := _world_resolve_label_path(w, label, ".json", loc)
	if !p_ok {
		return
	}
	ok := _driver_write_obench_v6_json_fixture(
		path,
		suite_name,
		group_name,
		bench_name,
		commit,
		created_at,
		cpu,
		governor,
		boost,
		microarch,
		bounds_checks,
		median_ns,
		batch_size,
		peak_heap_bytes,
		zero_alloc_failed,
		instructions,
	)
	testing.expect(w.t, ok, "write obench v6 report fixture", loc = loc)
}

given_readme_file :: proc(w: ^World, label, content: string, loc := #caller_location) {
	path, p_ok := _world_resolve_label_path(w, label, ".md", loc)
	if !p_ok {
		return
	}
	ok := _driver_write_file_bytes(path, transmute([]u8)content)
	testing.expect(w.t, ok, "write readme fixture", loc = loc)
}

given_cli_workspace :: proc(w: ^World, loc := #caller_location) {
	_world_close_stores(w)
	_world_reset_queries(w)
	if w.cli_bin == "" {
		bin_path, found := _driver_locate_cli_binary()
		if !testing.expect(
			w.t,
			found,
			"missing CLI binary bin/hugi; build via 'make build'",
			loc = loc,
		) {
			return
		}
		w.cli_bin = bin_path
	}
	db_path, p_ok := _world_resolve_label_path(w, "history.hugidb", ".hugidb", loc)
	if !p_ok {
		return
	}
	w.db_path = db_path
}

given_project_config :: proc(w: ^World, content: string, loc := #caller_location) {
	path, p_ok := _world_resolve_label_path(w, "hugi.json", ".json", loc)
	if !p_ok {
		return
	}
	ok := _driver_write_file_bytes(path, transmute([]u8)content)
	testing.expect(w.t, ok, "write hugi.json fixture", loc = loc)
}

given_cli_bench_package :: proc(
	w: ^World,
	label: string,
	work_iters := 50,
	violate_zero_alloc := false,
	loc := #caller_location,
) {
	pkg_dir, p_ok := _world_resolve_label_path(w, label, "", loc)
	if !p_ok {
		return
	}
	repo_root, r_ok := _driver_locate_repo_root()
	if !testing.expect(w.t, r_ok, "locate hugi repository root", loc = loc) {
		return
	}
	defer delete(repo_root)
	ok := _driver_write_cli_bench_package(pkg_dir, repo_root, work_iters, violate_zero_alloc)
	testing.expectf(w.t, ok, "write CLI benchmark package fixture %q", label, loc = loc)
}

// ── Actions (Upon) ──────────────────────────────────────────────────────────

upon_executing_suite :: proc(w: ^World, loc := #caller_location) {
	if !testing.expect(
		w.t,
		w.suite_active,
		"given_suite must precede upon_executing_suite",
		loc = loc,
	) {
		return
	}
	_world_clear_pooled(w)
	_world_clear_packets(w)
	w.suite_ok = _driver_suite_execute(&w.suite)
	w.suite_executed = true
	w.last_terminal_summary = _driver_suite_terminal_summary(
		&w.suite,
		vmem.arena_allocator(&w.arena),
	)
}

upon_ingesting_run_batch :: proc(
	w: ^World,
	commit, lang, run_id: string,
	benches: []Bench_Observation,
	selective := false,
	timestamp_unix: i64 = 1770000000,
	suite_name := "spec_suite",
	env := hugi.Run_Env{},
	loc := #caller_location,
) {
	st, ok := _world_active_store(w, loc)
	if !ok {
		return
	}
	pkt := _driver_build_packet(
		commit,
		lang,
		run_id,
		suite_name,
		benches,
		selective,
		timestamp_unix,
		env,
	)
	defer hugi.packet_destroy(&pkt)
	w.last_ingest_ok = _driver_store_ingest_packet(st, pkt)
	testing.expect(w.t, w.last_ingest_ok, "expected ingest to succeed", loc = loc)
}

upon_ingesting_run_single :: proc(
	w: ^World,
	commit, lang, run_id: string,
	bench: Bench_Observation,
	selective := false,
	timestamp_unix: i64 = 1770000000,
	suite_name := "spec_suite",
	env := hugi.Run_Env{},
	loc := #caller_location,
) {
	arr := [1]Bench_Observation{bench}
	upon_ingesting_run_batch(
		w,
		commit,
		lang,
		run_id,
		arr[:],
		selective,
		timestamp_unix,
		suite_name,
		env,
		loc,
	)
}

upon_ingesting_run :: proc {
	upon_ingesting_run_single,
	upon_ingesting_run_batch,
}

upon_compacting_store :: proc(
	w: ^World,
	keep_hot_runs := 0,
	cold_chunk_runs := 32,
	loc := #caller_location,
) {
	if !testing.expect(
		w.t,
		w.db_path != "" && w.db_path != ":memory:",
		"compaction requires a file-backed store",
		loc = loc,
	) {
		return
	}
	_world_close_stores(w)
	before, after, ok := _driver_store_compact(w.db_path, keep_hot_runs, cold_chunk_runs)
	w.last_compact_before = before
	w.last_compact_after = after
	w.last_compact_ok = ok
	if ok {
		st, reopen_ok := _driver_store_open(w.db_path)
		if testing.expect(w.t, reopen_ok, "reopen store after compaction", loc = loc) {
			w.db_store = st
			w.store_open = true
		}
	}
}

upon_opening_overlay :: proc(w: ^World, loc := #caller_location) {
	if !testing.expect(
		w.t,
		w.db_path != "" && w.db_path != ":memory:",
		"overlay requires a file-backed store",
		loc = loc,
	) {
		return
	}
	_world_close_stores(w)

	if w.disk_snapshot != nil {
		delete(w.disk_snapshot)
		w.disk_snapshot = nil
	}
	snap, s_ok := _driver_read_file_bytes(w.db_path)
	if !testing.expect(w.t, s_ok, "capture pre-overlay disk snapshot", loc = loc) {
		return
	}
	w.disk_snapshot = snap

	ov, ov_ok := _driver_store_open_overlay(w.db_path)
	if !testing.expect(w.t, ov_ok, "open store overlay", loc = loc) {
		return
	}
	w.overlay = ov
	w.overlay_open = true
}

upon_ingesting_into_overlay :: proc(
	w: ^World,
	commit, lang, run_id: string,
	benches: []Bench_Observation,
	loc := #caller_location,
) {
	if !testing.expect(w.t, w.overlay_open, "overlay must be open", loc = loc) {
		return
	}
	pkt := _driver_build_packet(commit, lang, run_id, "overlay_suite", benches)
	defer hugi.packet_destroy(&pkt)
	w.last_ingest_ok = _driver_store_ingest_packet(&w.overlay, pkt)
	testing.expect(w.t, w.last_ingest_ok, "ingest packet into overlay", loc = loc)
}

upon_closing_overlay_and_reopening_base :: proc(w: ^World, loc := #caller_location) {
	if w.overlay_open {
		_driver_store_close(&w.overlay)
		w.overlay_open = false
	}
	st, ok := _driver_store_open(w.db_path)
	if !testing.expect(w.t, ok, "reopen base file store", loc = loc) {
		return
	}
	w.db_store = st
	w.store_open = true
}

upon_querying_latest :: proc(w: ^World, lang := "odin", filter := "", loc := #caller_location) {
	st, ok := _world_active_store(w, loc)
	if !ok {
		return
	}
	_world_clear_pooled(w)
	w.last_pooled = _driver_store_load_pooled(st, lang, "", "", filter)
}

upon_querying_commit :: proc(
	w: ^World,
	commit: string,
	lang := "odin",
	filter := "",
	loc := #caller_location,
) {
	st, ok := _world_active_store(w, loc)
	if !ok {
		return
	}
	_world_clear_pooled(w)
	w.last_pooled = _driver_store_load_pooled(st, lang, commit, "", filter)
}

upon_querying_run :: proc(
	w: ^World,
	run_id: string,
	lang := "odin",
	filter := "",
	loc := #caller_location,
) {
	st, ok := _world_active_store(w, loc)
	if !ok {
		return
	}
	_world_clear_pooled(w)
	w.last_pooled = _driver_store_load_pooled(st, lang, "", run_id, filter)
}

upon_querying_commit_series :: proc(
	w: ^World,
	lang := "odin",
	filter := "",
	loc := #caller_location,
) {
	st, ok := _world_active_store(w, loc)
	if !ok {
		return
	}
	_world_clear_pooled(w)
	w.last_pooled = _driver_store_load_commit_series(st, lang, filter)
}

upon_querying_all_runs :: proc(w: ^World, lang := "odin", filter := "", loc := #caller_location) {
	st, ok := _world_active_store(w, loc)
	if !ok {
		return
	}
	_world_clear_pooled(w)
	w.last_pooled = _driver_store_load_all_runs(st, lang, filter)
}

upon_loading_all_packets :: proc(w: ^World, loc := #caller_location) {
	st, ok := _world_active_store(w, loc)
	if !ok {
		return
	}
	_world_clear_pooled(w)
	_world_clear_packets(w)
	w.last_packets = _driver_store_load_all_packets(st)
}

upon_comparing_commits :: proc(
	w: ^World,
	base_commit, cand_commit: string,
	lang := "odin",
	threshold_pct := 5.0,
	loc := #caller_location,
) {
	st, ok := _world_active_store(w, loc)
	if !ok {
		return
	}
	_world_clear_comparison(w)
	w.last_comparison = _driver_compare_commits(st, lang, base_commit, cand_commit, threshold_pct)
	w.has_comparison = true
}

upon_comparing_1v1 :: proc(
	w: ^World,
	lang_a, lang_b: string,
	commit := "",
	threshold_pct := 3.0,
	loc := #caller_location,
) {
	st, ok := _world_active_store(w, loc)
	if !ok {
		return
	}
	_world_clear_1v1(w)
	w.last_1v1 = _driver_compare_1v1(st, lang_a, lang_b, commit, threshold_pct)
	w.has_1v1 = true
}

upon_exporting :: proc(
	w: ^World,
	format: Export_Format,
	label: string,
	scope := Export_Scope.Snapshot,
	lang := "odin",
	commit := "",
	filter := "",
	loc := #caller_location,
) {
	st, ok := _world_active_store(w, loc)
	if !ok {
		return
	}
	path, p_ok := _world_resolve_label_path(w, label, "", loc)
	if !p_ok {
		return
	}
	_world_clear_pooled(w)
	switch scope {
	case .Snapshot:
		w.last_pooled = _driver_store_load_pooled(st, lang, commit, "", filter)
	case .All_Commits:
		w.last_pooled = _driver_store_load_commit_series(st, lang, filter)
	case .All_Runs:
		w.last_pooled = _driver_store_load_all_runs(st, lang, filter)
	}
	w.last_export_format = format
	w.last_export_path = path
	w.last_export_ok = _driver_export_records(format, path, w.last_pooled)
}

upon_updating_readme :: proc(w: ^World, label: string, lang := "odin", loc := #caller_location) {
	st, ok := _world_active_store(w, loc)
	if !ok {
		return
	}
	path, found := w.files[label]
	if !testing.expectf(w.t, found, "unknown readme fixture label %q", label, loc = loc) {
		return
	}
	_world_clear_pooled(w)
	w.last_pooled = _driver_store_load_pooled(st, lang)
	w.last_readme_ok = _driver_update_readme(path, w.last_pooled)
}

@(private = "file")
_resolve_cli_arg :: proc(
	w: ^World,
	arg: string,
	loc := #caller_location,
) -> (
	res: string,
	ok: bool,
) {
	if arg == "@db" {
		if w.db_path == "" {
			p, p_ok := _world_resolve_label_path(w, "history.hugidb", ".hugidb", loc)
			if !p_ok {
				return "", false
			}
			w.db_path = p
		}
		return w.db_path, true
	}
	if strings.has_prefix(arg, "@") {
		return _world_resolve_label_path(w, arg[1:], "", loc)
	}
	if eq := strings.index(arg, "=@"); eq > 0 {
		prefix := arg[:eq + 1]
		rhs := arg[eq + 1:]
		resolved := _resolve_cli_arg(w, rhs, loc) or_return
		return fmt.tprintf("%s%s", prefix, resolved), true
	}
	return arg, true
}

upon_running_cli :: proc(w: ^World, args: ..string, loc := #caller_location) {
	if w.cli_bin == "" {
		bin_path, found := _driver_locate_cli_binary()
		if !testing.expect(
			w.t,
			found,
			"missing CLI binary bin/hugi; build via 'make build'",
			loc = loc,
		) {
			return
		}
		w.cli_bin = bin_path
	}
	work_dir, d_ok := _world_ensure_work_dir(w, loc)
	if !d_ok {
		return
	}
	_world_close_stores(w)

	resolved := make([dynamic]string, 0, len(args), context.temp_allocator)
	for a in args {
		r, r_ok := _resolve_cli_arg(w, a, loc)
		if !r_ok {
			return
		}
		append(&resolved, r)
	}

	_driver_cli_result_destroy(&w.last_cli)
	w.last_cli = _driver_exec_cli(w.cli_bin, work_dir, resolved[:])
}

// ── Pattern B Scoped Views ──────────────────────────────────────────────────

@(private = "file")
_make_benchmark_view_from_pooled :: proc(w: ^World, r: store.Pooled_Record) -> Benchmark_View {
	arena_alloc := vmem.arena_allocator(&w.arena)
	v := Benchmark_View {
		full_name        = strings.clone(r.full_name, arena_alloc),
		commit           = strings.clone(r.commit, arena_alloc),
		lang             = strings.clone(r.lang, arena_alloc),
		run_count        = r.run_count,
		samples          = r.samples,
		ops_per_sample   = r.ops_per_sample,
		min_fs           = r.min_fs,
		p50_fs           = r.p50_fs,
		max_fs           = r.max_fs,
		footprint_bytes  = r.footprint_bytes,
		samples_fs_len   = len(r.samples_fs),
		batch_sample_len = len(r.samples_batch_ns),
	}
	if len(r.samples_batch_ns) > 0 {
		v.first_batch_ns = r.samples_batch_ns[0]
		v.last_batch_ns = r.samples_batch_ns[len(r.samples_batch_ns) - 1]
	}
	if len(r.metrics) > 0 {
		cloned := make([]hugi.Metric, len(r.metrics), arena_alloc)
		for m, i in r.metrics {
			cloned[i] = hugi.Metric {
				unit  = strings.clone(m.unit, arena_alloc),
				value = m.value,
			}
		}
		v.metrics = cloned
	}
	return v
}

@(private = "file")
_make_benchmark_view_from_record :: proc(
	w: ^World,
	r: hugi.Record,
	commit, lang: string,
) -> Benchmark_View {
	arena_alloc := vmem.arena_allocator(&w.arena)
	v := Benchmark_View {
		full_name         = strings.clone(r.full_name, arena_alloc),
		commit            = strings.clone(commit, arena_alloc),
		lang              = strings.clone(lang, arena_alloc),
		run_count         = 1,
		samples           = r.samples,
		ops_per_sample    = r.ops_per_sample,
		min_fs            = r.min_fs,
		p50_fs            = r.p50_fs,
		max_fs            = r.max_fs,
		param             = r.param,
		has_param         = r.has_param,
		threads           = r.threads,
		has_threads       = r.has_threads,
		items_per_op      = r.items_per_op,
		footprint_bytes   = r.footprint_bytes,
		zero_alloc_failed = r.zero_alloc_failed,
		error             = strings.clone(r.error, arena_alloc),
		samples_fs_len    = len(r.samples_batch_ns),
		batch_sample_len  = len(r.samples_batch_ns),
	}
	if len(r.samples_batch_ns) > 0 {
		v.first_batch_ns = r.samples_batch_ns[0]
		v.last_batch_ns = r.samples_batch_ns[len(r.samples_batch_ns) - 1]
	}
	if len(r.metrics) > 0 {
		cloned := make([]hugi.Metric, len(r.metrics), arena_alloc)
		for m, i in r.metrics {
			cloned[i] = hugi.Metric {
				unit  = strings.clone(m.unit, arena_alloc),
				value = m.value,
			}
		}
		v.metrics = cloned
	}
	return v
}

viewing_benchmark :: proc(
	w: ^World,
	name: string,
	lang := "",
	commit := "",
	run_id := "",
	loc := #caller_location,
) -> (
	Benchmark_View,
	bool,
) {
	if len(w.last_pooled) > 0 {
		for r in w.last_pooled {
			if r.full_name != name && r.name != name {
				continue
			}
			if lang != "" && r.lang != lang {
				continue
			}
			if commit != "" && r.commit != commit {
				continue
			}
			if run_id != "" {
				found_run := false
				for rid in r.run_ids {
					if rid == run_id {
						found_run = true
						break
					}
				}
				if !found_run {
					continue
				}
			}
			return _make_benchmark_view_from_pooled(w, r), true
		}
	} else if len(w.last_packets) > 0 {
		for pkt in w.last_packets {
			if lang != "" && pkt.lang != lang {
				continue
			}
			if commit != "" && pkt.commit != commit {
				continue
			}
			if run_id != "" && pkt.run_id != run_id {
				continue
			}
			for r in pkt.records {
				if r.full_name == name || r.name == name {
					return _make_benchmark_view_from_record(w, r, pkt.commit, pkt.lang), true
				}
			}
		}
	} else if w.suite_executed {
		pkt := w.suite.last_packet
		if (lang == "" || pkt.lang == lang) &&
		   (commit == "" || pkt.commit == commit) &&
		   (run_id == "" || pkt.run_id == run_id) {
			for r in pkt.records {
				if r.full_name == name || r.name == name {
					return _make_benchmark_view_from_record(w, r, pkt.commit, pkt.lang), true
				}
			}
		}
	}
	testing.expectf(
		w.t,
		false,
		"benchmark %q (lang=%q, commit=%q, run=%q) not found",
		name,
		lang,
		commit,
		run_id,
		loc = loc,
	)
	return {}, false
}

shows_median_ns :: proc(
	w: ^World,
	v: Benchmark_View,
	expected_ns: f64,
	tolerance_ns := 2.0,
	loc := #caller_location,
) {
	actual_ns := hugi.fs_to_ns_f64(v.p50_fs)
	testing.expectf(
		w.t,
		math.abs(actual_ns - expected_ns) <= tolerance_ns,
		"benchmark %q median %.4fns differed from expected %.4fns by > %.4fns",
		v.full_name,
		actual_ns,
		expected_ns,
		tolerance_ns,
		loc = loc,
	)
}

shows_exact_p50_fs :: proc(
	w: ^World,
	v: Benchmark_View,
	expected_fs: i64,
	loc := #caller_location,
) {
	testing.expect_value(w.t, v.p50_fs, expected_fs, loc = loc)
}

shows_min_max_fs :: proc(
	w: ^World,
	v: Benchmark_View,
	expected_min_fs, expected_max_fs: i64,
	loc := #caller_location,
) {
	testing.expect_value(w.t, v.min_fs, expected_min_fs, loc = loc)
	testing.expect_value(w.t, v.max_fs, expected_max_fs, loc = loc)
}

shows_commit :: proc(w: ^World, v: Benchmark_View, expected: string, loc := #caller_location) {
	testing.expect_value(w.t, v.commit, expected, loc = loc)
}

shows_lang :: proc(w: ^World, v: Benchmark_View, expected: string, loc := #caller_location) {
	testing.expect_value(w.t, v.lang, expected, loc = loc)
}

shows_run_count :: proc(w: ^World, v: Benchmark_View, expected: int, loc := #caller_location) {
	testing.expect_value(w.t, v.run_count, expected, loc = loc)
}

shows_sample_count :: proc(w: ^World, v: Benchmark_View, expected: int, loc := #caller_location) {
	testing.expect_value(w.t, v.samples, expected, loc = loc)
}

shows_footprint_bytes :: proc(
	w: ^World,
	v: Benchmark_View,
	expected: u64,
	loc := #caller_location,
) {
	testing.expect_value(w.t, v.footprint_bytes, expected, loc = loc)
}

shows_metric :: proc(
	w: ^World,
	v: Benchmark_View,
	unit: string,
	expected_val: f64,
	loc := #caller_location,
) {
	for m in v.metrics {
		if m.unit == unit {
			testing.expect_value(w.t, m.value, expected_val, loc = loc)
			return
		}
	}
	testing.expectf(
		w.t,
		false,
		"expected metric %q on benchmark %q (had %d metrics)",
		unit,
		v.full_name,
		len(v.metrics),
		loc = loc,
	)
}

shows_descriptor_tags :: proc(
	w: ^World,
	v: Benchmark_View,
	param: int,
	has_param: bool,
	threads: int,
	has_threads: bool,
	items_per_op: u64 = 0,
	loc := #caller_location,
) {
	testing.expect_value(w.t, v.has_param, has_param, loc = loc)
	testing.expect_value(w.t, v.param, param, loc = loc)
	testing.expect_value(w.t, v.has_threads, has_threads, loc = loc)
	testing.expect_value(w.t, v.threads, threads, loc = loc)
	testing.expect_value(w.t, v.items_per_op, items_per_op, loc = loc)
}

shows_failure_state :: proc(
	w: ^World,
	v: Benchmark_View,
	zero_alloc_failed: bool,
	error: string,
	loc := #caller_location,
) {
	testing.expect_value(w.t, v.zero_alloc_failed, zero_alloc_failed, loc = loc)
	testing.expect_value(w.t, v.error, error, loc = loc)
}

shows_pooled_batches_cleared :: proc(
	w: ^World,
	v: Benchmark_View,
	expected_samples: int,
	loc := #caller_location,
) {
	testing.expectf(
		w.t,
		expected_samples > 0,
		"expected_samples must be > 0, got %d",
		expected_samples,
		loc = loc,
	)
	testing.expect_value(w.t, v.batch_sample_len, 0, loc = loc)
	testing.expect_value(w.t, v.samples, expected_samples, loc = loc)
	testing.expect_value(w.t, v.samples_fs_len, expected_samples, loc = loc)
}

shows_batch_sample_bounds :: proc(
	w: ^World,
	v: Benchmark_View,
	expected_len: int,
	first_ns, last_ns: u64,
	loc := #caller_location,
) {
	testing.expect_value(w.t, v.batch_sample_len, expected_len, loc = loc)
	testing.expect_value(w.t, v.first_batch_ns, first_ns, loc = loc)
	testing.expect_value(w.t, v.last_batch_ns, last_ns, loc = loc)
}

viewing_comparison_row :: proc(
	w: ^World,
	name: string,
	loc := #caller_location,
) -> (
	Comparison_Row_View,
	bool,
) {
	if !testing.expect(w.t, w.has_comparison, "no comparison report in World", loc = loc) {
		return {}, false
	}
	arena_alloc := vmem.arena_allocator(&w.arena)
	for r in w.last_comparison.rows {
		if r.full_name == name {
			return Comparison_Row_View {
					full_name = strings.clone(r.full_name, arena_alloc),
					delta_pct = r.delta_pct,
					p_value = r.p_value,
					is_significant = r.is_significant,
					verdict = r.verdict,
				},
				true
		}
	}
	testing.expectf(w.t, false, "comparison row %q not found", name, loc = loc)
	return {}, false
}

shows_verdict :: proc(
	w: ^World,
	v: Comparison_Row_View,
	expected: Verdict,
	loc := #caller_location,
) {
	testing.expect_value(w.t, v.verdict, expected, loc = loc)
}

shows_significance :: proc(
	w: ^World,
	v: Comparison_Row_View,
	expected: bool,
	max_p_value := 1.0,
	loc := #caller_location,
) {
	testing.expect_value(w.t, v.is_significant, expected, loc = loc)
	if max_p_value < 1.0 {
		testing.expectf(
			w.t,
			v.p_value < max_p_value,
			"expected p_value < %.4f, got %.6f",
			max_p_value,
			v.p_value,
			loc = loc,
		)
	}
}

shows_positive_regression_delta :: proc(
	w: ^World,
	v: Comparison_Row_View,
	min_delta_pct: f64,
	loc := #caller_location,
) {
	testing.expectf(
		w.t,
		v.delta_pct >= min_delta_pct,
		"expected delta_pct >= %.2f%%, got %.2f%%",
		min_delta_pct,
		v.delta_pct,
		loc = loc,
	)
}

viewing_1v1_row :: proc(
	w: ^World,
	name: string,
	loc := #caller_location,
) -> (
	Cross_Lang_Row_View,
	bool,
) {
	if !testing.expect(w.t, w.has_1v1, "no 1v1 report in World", loc = loc) {
		return {}, false
	}
	arena_alloc := vmem.arena_allocator(&w.arena)
	for r in w.last_1v1.rows {
		if r.full_name == name {
			return Cross_Lang_Row_View {
					full_name = strings.clone(r.full_name, arena_alloc),
					faster_lang = strings.clone(r.faster_lang, arena_alloc),
					p_value = r.p_value,
					is_significant = r.is_significant,
					footprint_mismatch = r.footprint_mismatch,
				},
				true
		}
	}
	testing.expectf(w.t, false, "1v1 row %q not found", name, loc = loc)
	return {}, false
}

shows_winner :: proc(
	w: ^World,
	v: Cross_Lang_Row_View,
	expected_lang: string,
	loc := #caller_location,
) {
	testing.expect_value(w.t, v.faster_lang, expected_lang, loc = loc)
}

shows_1v1_significance :: proc(
	w: ^World,
	v: Cross_Lang_Row_View,
	expected: bool,
	max_p_value := 1.0,
	loc := #caller_location,
) {
	testing.expect_value(w.t, v.is_significant, expected, loc = loc)
	if max_p_value < 1.0 {
		testing.expectf(
			w.t,
			v.p_value < max_p_value,
			"expected p_value < %.4f, got %.6f",
			max_p_value,
			v.p_value,
			loc = loc,
		)
	}
}

shows_footprint_mismatch :: proc(
	w: ^World,
	v: Cross_Lang_Row_View,
	expected: bool,
	loc := #caller_location,
) {
	testing.expect_value(w.t, v.footprint_mismatch, expected, loc = loc)
}

viewing_cli_output :: proc(w: ^World, loc := #caller_location) -> (CLI_Output_View, bool) {
	if !testing.expect(w.t, w.last_cli.started, "CLI process failed to start", loc = loc) {
		return {}, false
	}
	return CLI_Output_View {
			started = w.last_cli.started,
			exit_code = w.last_cli.exit_code,
			stdout = w.last_cli.stdout,
			stderr = w.last_cli.stderr,
		},
		true
}

shows_exit_code :: proc(w: ^World, v: CLI_Output_View, expected: int, loc := #caller_location) {
	testing.expectf(
		w.t,
		v.exit_code == expected,
		"expected exit code %d, got %d (stdout=%q, stderr=%q)",
		expected,
		v.exit_code,
		v.stdout,
		v.stderr,
		loc = loc,
	)
}

shows_stdout_contains :: proc(
	w: ^World,
	v: CLI_Output_View,
	substr: string,
	loc := #caller_location,
) {
	testing.expectf(
		w.t,
		strings.contains(v.stdout, substr),
		"expected stdout to contain %q, got %q",
		substr,
		v.stdout,
		loc = loc,
	)
}

shows_stdout_does_not_contain :: proc(
	w: ^World,
	v: CLI_Output_View,
	substr: string,
	loc := #caller_location,
) {
	testing.expectf(
		w.t,
		!strings.contains(v.stdout, substr),
		"expected stdout NOT to contain %q, got %q",
		substr,
		v.stdout,
		loc = loc,
	)
}

shows_stderr_contains :: proc(
	w: ^World,
	v: CLI_Output_View,
	substr: string,
	loc := #caller_location,
) {
	testing.expectf(
		w.t,
		strings.contains(v.stderr, substr),
		"expected stderr to contain %q, got %q",
		substr,
		v.stderr,
		loc = loc,
	)
}

// ── Direct Assertions (Then) ────────────────────────────────────────────────

then_suite_succeeded :: proc(w: ^World, loc := #caller_location) {
	testing.expect(w.t, w.suite_executed, "suite was not executed", loc = loc)
	testing.expect(w.t, w.suite_ok, "expected suite execution to succeed", loc = loc)
	testing.expect_value(w.t, w.suite.failed_zero_alloc, 0, loc = loc)
	testing.expect_value(w.t, w.suite.failed_errors, 0, loc = loc)
}

then_suite_failed_zero_alloc :: proc(w: ^World, min_violations := 1, loc := #caller_location) {
	testing.expect(w.t, w.suite_executed, "suite was not executed", loc = loc)
	testing.expect(w.t, !w.suite_ok, "expected suite execution to fail on zero_alloc", loc = loc)
	testing.expectf(
		w.t,
		w.suite.failed_zero_alloc >= min_violations,
		"expected >= %d zero_alloc failure(s), got %d",
		min_violations,
		w.suite.failed_zero_alloc,
		loc = loc,
	)
}

then_suite_terminal_summary_contains :: proc(
	w: ^World,
	substrs: ..string,
	loc := #caller_location,
) {
	if !testing.expect(w.t, w.suite_executed, "suite was not executed", loc = loc) {
		return
	}
	for s in substrs {
		testing.expectf(
			w.t,
			strings.contains(w.last_terminal_summary, s),
			"expected terminal summary to contain %q, got:\n%s",
			s,
			w.last_terminal_summary,
			loc = loc,
		)
	}
}

then_suite_failure_messages_contain :: proc(
	w: ^World,
	substrs: ..string,
	loc := #caller_location,
) {
	if !testing.expect(w.t, w.suite_executed, "suite was not executed", loc = loc) {
		return
	}
	msgs := _driver_suite_failure_messages(&w.suite, context.allocator)
	defer {
		for m in msgs {
			delete(m)
		}
		delete(msgs)
	}
	for s in substrs {
		found := false
		for m in msgs {
			if strings.contains(m, s) {
				found = true
				break
			}
		}
		testing.expectf(
			w.t,
			found,
			"expected suite failure messages (%v) to contain %q",
			msgs,
			s,
			loc = loc,
		)
	}
}

then_suite_recorded_benchmarks :: proc(
	w: ^World,
	expected_names: []string,
	loc := #caller_location,
) {
	if !testing.expect(w.t, w.suite_executed, "suite was not executed", loc = loc) {
		return
	}
	recs := w.suite.last_packet.records
	testing.expect_value(w.t, len(recs), len(expected_names), loc = loc)
	for exp, i in expected_names {
		if i < len(recs) {
			testing.expect_value(w.t, recs[i].full_name, exp, loc = loc)
		}
	}
}

then_suite_packet_is_selective :: proc(w: ^World, expected: bool, loc := #caller_location) {
	if !testing.expect(w.t, w.suite_executed, "suite was not executed", loc = loc) {
		return
	}
	testing.expect_value(w.t, w.suite.last_packet.selective, expected, loc = loc)
}

then_suite_packet_file_roundtrips :: proc(
	w: ^World,
	expected_records: int,
	loc := #caller_location,
) {
	if !testing.expect(
		w.t,
		w.suite_pkt_label != "",
		"suite had no configured packet output label",
		loc = loc,
	) {
		return
	}
	path, found := w.files[w.suite_pkt_label]
	if !testing.expect(w.t, found, "suite packet file not registered", loc = loc) {
		return
	}
	pkt, ok := _driver_read_packet_file(path)
	if !testing.expect(w.t, ok, "read emitted suite packet file", loc = loc) {
		return
	}
	defer hugi.packet_destroy(&pkt)
	testing.expect_value(w.t, pkt.suite_name, w.suite.name, loc = loc)
	testing.expect_value(w.t, len(pkt.records), expected_records, loc = loc)
}

then_store_file_does_not_exist :: proc(w: ^World, label: string, loc := #caller_location) {
	path, found := w.files[label]
	if !found {
		resolved, ok := _world_resolve_label_path(w, label, ".hugidb", loc)
		if !ok {
			return
		}
		path = resolved
	}
	testing.expectf(
		w.t,
		!os.exists(path),
		"expected store file %q (%s) not to exist",
		label,
		path,
		loc = loc,
	)
}

then_store_run_count :: proc(w: ^World, expected: int, loc := #caller_location) {
	st, ok := _world_active_store(w, loc)
	if !ok {
		return
	}
	_world_clear_runs(w)
	w.last_runs = _driver_store_list_runs(st)
	testing.expect_value(w.t, len(w.last_runs), expected, loc = loc)
}

then_store_commit_count :: proc(w: ^World, expected: int, loc := #caller_location) {
	st, ok := _world_active_store(w, loc)
	if !ok {
		return
	}
	_world_clear_commits(w)
	w.last_commits = _driver_store_list_commits(st)
	testing.expect_value(w.t, len(w.last_commits), expected, loc = loc)
}

then_query_returned_count :: proc(w: ^World, expected: int, loc := #caller_location) {
	testing.expect_value(w.t, len(w.last_pooled), expected, loc = loc)
}

then_loaded_packets_count :: proc(w: ^World, expected: int, loc := #caller_location) {
	testing.expect_value(w.t, len(w.last_packets), expected, loc = loc)
}

then_compaction_shrank_store :: proc(w: ^World, loc := #caller_location) {
	testing.expect(w.t, w.last_compact_ok, "expected compaction to succeed", loc = loc)
	testing.expectf(
		w.t,
		w.last_compact_before > 0 &&
		w.last_compact_after > 0 &&
		w.last_compact_after < w.last_compact_before,
		"expected compacted store size (%d -> %d) to shrink",
		w.last_compact_before,
		w.last_compact_after,
		loc = loc,
	)
}

then_compaction_failed :: proc(w: ^World, loc := #caller_location) {
	testing.expect(w.t, !w.last_compact_ok, "expected compaction to fail cleanly", loc = loc)
}

then_overlay_owns_ram_pages :: proc(w: ^World, loc := #caller_location) {
	if !testing.expect(w.t, w.overlay_open, "overlay is not open", loc = loc) {
		return
	}
	owned := store.store_overlay_owned_bytes(&w.overlay)
	testing.expectf(w.t, owned > 0, "expected overlay owned bytes > 0, got %d", owned, loc = loc)
}

then_disk_store_is_unchanged :: proc(w: ^World, loc := #caller_location) {
	if !testing.expect(w.t, w.disk_snapshot != nil, "no pre-overlay disk snapshot", loc = loc) {
		return
	}
	after, a_ok := _driver_read_file_bytes(w.db_path)
	if !testing.expect(w.t, a_ok, "read disk store after overlay", loc = loc) {
		return
	}
	defer delete(after)
	testing.expect(
		w.t,
		_driver_bytes_equal(w.disk_snapshot, after),
		"overlay mutated bytes on disk",
		loc = loc,
	)
}

then_comparison_summary :: proc(
	w: ^World,
	improvements, regressions, unchanged: int,
	loc := #caller_location,
) {
	if !testing.expect(w.t, w.has_comparison, "no comparison report in World", loc = loc) {
		return
	}
	testing.expect_value(w.t, w.last_comparison.improvements, improvements, loc = loc)
	testing.expect_value(w.t, w.last_comparison.regressions, regressions, loc = loc)
	testing.expect_value(w.t, w.last_comparison.unchanged, unchanged, loc = loc)
}

then_comparison_geomean_between :: proc(
	w: ^World,
	min_pct, max_pct: f64,
	loc := #caller_location,
) {
	if !testing.expect(w.t, w.has_comparison, "no comparison report in World", loc = loc) {
		return
	}
	g := w.last_comparison.geomean_delta
	testing.expectf(
		w.t,
		g >= min_pct && g <= max_pct,
		"expected comparison geomean_delta in [%.2f%%, %.2f%%], got %.4f%%",
		min_pct,
		max_pct,
		g,
		loc = loc,
	)
}

then_comparison_warns_containing :: proc(w: ^World, substr: string, loc := #caller_location) {
	if !testing.expect(w.t, w.has_comparison, "no comparison report in World", loc = loc) {
		return
	}
	for msg in w.last_comparison.warnings {
		if strings.contains(msg, substr) {
			return
		}
	}
	testing.expectf(
		w.t,
		false,
		"expected comparison warnings (%v) to contain %q",
		w.last_comparison.warnings,
		substr,
		loc = loc,
	)
}

then_1v1_warns_containing :: proc(w: ^World, substr: string, loc := #caller_location) {
	if !testing.expect(w.t, w.has_1v1, "no 1v1 report in World", loc = loc) {
		return
	}
	for msg in w.last_1v1.warnings {
		if strings.contains(msg, substr) {
			return
		}
	}
	testing.expectf(
		w.t,
		false,
		"expected 1v1 warnings (%v) to contain %q",
		w.last_1v1.warnings,
		substr,
		loc = loc,
	)
}

then_1v1_summary :: proc(
	w: ^World,
	a_wins, b_wins, ties, footprint_mismatches: int,
	loc := #caller_location,
) {
	if !testing.expect(w.t, w.has_1v1, "no 1v1 report in World", loc = loc) {
		return
	}
	testing.expect_value(w.t, w.last_1v1.a_wins, a_wins, loc = loc)
	testing.expect_value(w.t, w.last_1v1.b_wins, b_wins, loc = loc)
	testing.expect_value(w.t, w.last_1v1.ties, ties, loc = loc)
	testing.expect_value(w.t, w.last_1v1.footprint_mismatches, footprint_mismatches, loc = loc)
}

then_1v1_only_in :: proc(w: ^World, only_a, only_b: []string, loc := #caller_location) {
	if !testing.expect(w.t, w.has_1v1, "no 1v1 report in World", loc = loc) {
		return
	}
	testing.expect_value(w.t, len(w.last_1v1.only_in_a), len(only_a), loc = loc)
	for exp, i in only_a {
		if i < len(w.last_1v1.only_in_a) {
			testing.expect_value(w.t, w.last_1v1.only_in_a[i], exp, loc = loc)
		}
	}
	testing.expect_value(w.t, len(w.last_1v1.only_in_b), len(only_b), loc = loc)
	for exp, i in only_b {
		if i < len(w.last_1v1.only_in_b) {
			testing.expect_value(w.t, w.last_1v1.only_in_b[i], exp, loc = loc)
		}
	}
}

then_export_succeeded :: proc(w: ^World, loc := #caller_location) {
	testing.expect(w.t, w.last_export_ok, "expected export to succeed", loc = loc)
}

then_exported_artifact_valid :: proc(
	w: ^World,
	label: string,
	format: Export_Format,
	expected_rows, expected_cols: int,
	verify_samples_against_latest := false,
	loc := #caller_location,
) {
	path := w.last_export_path
	if label != "" {
		found: bool
		path, found = w.files[label]
		if !testing.expectf(w.t, found, "unknown exported file label %q", label, loc = loc) {
			return
		}
	}
	expected_recs := verify_samples_against_latest ? w.last_pooled : nil
	audit := _driver_verify_export(format, path, expected_recs)
	testing.expectf(w.t, audit.ok, "export verification failed (%s)", audit.detail, loc = loc)
	testing.expect(w.t, audit.schema_exact, "exported schema mismatch", loc = loc)
	testing.expect_value(w.t, audit.col_count, expected_cols, loc = loc)
	testing.expect_value(w.t, audit.row_count, expected_rows, loc = loc)
	if verify_samples_against_latest {
		testing.expect(
			w.t,
			audit.samples_roundtrip_ok,
			"samples_blob roundtrip mismatch",
			loc = loc,
		)
	}
}

then_file_contains :: proc(w: ^World, label: string, substr: string, loc := #caller_location) {
	path, found := w.files[label]
	if !testing.expectf(w.t, found, "unknown file label %q", label, loc = loc) {
		return
	}
	raw, r_ok := _driver_read_file_bytes(path)
	if !testing.expectf(w.t, r_ok, "failed reading file %q", label, loc = loc) {
		return
	}
	defer delete(raw)
	testing.expectf(
		w.t,
		strings.contains(string(raw), substr),
		"expected %q to contain %q",
		label,
		substr,
		loc = loc,
	)
}

then_file_does_not_contain :: proc(
	w: ^World,
	label: string,
	substr: string,
	loc := #caller_location,
) {
	path, found := w.files[label]
	if !testing.expectf(w.t, found, "unknown file label %q", label, loc = loc) {
		return
	}
	raw, r_ok := _driver_read_file_bytes(path)
	if !testing.expectf(w.t, r_ok, "failed reading file %q", label, loc = loc) {
		return
	}
	defer delete(raw)
	testing.expectf(
		w.t,
		!strings.contains(string(raw), substr),
		"expected %q not to contain %q",
		label,
		substr,
		loc = loc,
	)
}

then_readme_update_succeeded :: proc(w: ^World, loc := #caller_location) {
	testing.expect(w.t, w.last_readme_ok, "expected README update to succeed", loc = loc)
}

then_readme_update_failed :: proc(w: ^World, loc := #caller_location) {
	testing.expect(w.t, !w.last_readme_ok, "expected README update to fail cleanly", loc = loc)
}
