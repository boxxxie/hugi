package hugi

import obench "../deps/obench/obench"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

// Re-exported obench micro-benchmark primitives.
Bencher :: obench.Bencher
Parallel_Bencher :: obench.Parallel_Bencher
Batch_Mode :: obench.Batch_Mode
Group :: obench.Group
Bench_Proc :: obench.Bench_Proc

step :: obench.step
pause :: obench.pause
resume :: obench.resume
scoped_pause :: obench.scoped_pause
black_box :: obench.black_box
keep_alive :: obench.keep_alive
clobber_memory :: obench.clobber_memory
iter_batched :: obench.iter_batched
iter_with_large_drop :: obench.iter_with_large_drop
run_parallel :: obench.run_parallel
parallel_next :: obench.parallel_next
set_bytes :: obench.set_bytes
set_items :: obench.set_items
report_metric :: obench.report_metric
expect_zero_allocs :: obench.expect_zero_allocs
param :: obench.param
threads :: obench.threads

Suite_Config :: struct {
	obench_cfg:      obench.Config,
	runs:            int,
	warmup:          int,
	groups_filter:   string,
	name_filter:     string,
	lang:            string,
	commit:          string,
	run_id:          string,
	packet_out_path: string,
	quiet:           bool,
}

Suite :: struct {
	name:               string,
	config:             Suite_Config,
	obench_suite:       obench.Suite,
	pipelines:          [dynamic]_Pipeline_Def,
	last_packet:        Run_Packet,
	violations:         [dynamic]Phase_Violation,
	failed_zero_alloc:  int,
	failed_errors:      int,
	failed_regressions: int,
	failed_io:          int,
	allocator:          runtime.Allocator,
}

@(private = "file")
_apply_cli_flags :: proc(cfg: ^Suite_Config, args: []string) {
	i := 0
	for i < len(args) {
		arg := args[i]
		i += 1
		if arg == "--quiet" || arg == "-quiet" {
			cfg.quiet = true
			continue
		}
		if !strings.has_prefix(arg, "-") {
			continue
		}
		trimmed := strings.trim_left(arg, "-")
		key := trimmed
		val := ""
		has_inline := false
		if sep := strings.index_any(trimmed, "=:"); sep >= 0 {
			key = trimmed[:sep]
			val = trimmed[sep + 1:]
			has_inline = true
		}
		switch key {
		case "runs",
		     "warmup",
		     "groups",
		     "group",
		     "filter",
		     "f",
		     "lang",
		     "commit",
		     "run-id",
		     "packet-out":
		case:
			continue
		}
		if !has_inline {
			if i >= len(args) {
				break
			}
			val = args[i]
			i += 1
		}
		switch key {
		case "runs":
			if v, ok := strconv.parse_int(val); ok && v > 0 {
				cfg.runs = v
			}
		case "warmup":
			if v, ok := strconv.parse_int(val); ok && v >= 0 {
				cfg.warmup = v
				cfg.obench_cfg.warmup_time = time.Duration(v) * time.Millisecond
			}
		case "groups", "group":
			cfg.groups_filter = val
		case "filter", "f":
			cfg.name_filter = val
		case "lang":
			cfg.lang = strings.to_lower(val, context.temp_allocator)
		case "commit":
			cfg.commit = val
		case "run-id":
			cfg.run_id = val
		case "packet-out":
			cfg.packet_out_path = val
		}
	}
}

@(require_results)
default_suite_config :: proc() -> Suite_Config {
	ocfg := obench.default_config()
	ocfg.untimed_alloc_check = true

	cfg := Suite_Config {
		obench_cfg = ocfg,
		runs       = 7,
		warmup     = 1,
		lang       = "odin",
	}

	when !ODIN_TEST {
		args := os.args[1:] if len(os.args) > 0 else nil
		_apply_cli_flags(&cfg, args)
	}
	if cfg.name_filter != "" {
		// Micro-suite filtering happens on `Record` emission inside `Suite`, unless single-group.
		cfg.obench_cfg.filter = cfg.name_filter
	}
	if cfg.commit == "" {
		cfg.commit = resolve_git_commit(".", context.temp_allocator)
	}
	if cfg.run_id == "" {
		cfg.run_id = default_run_id(context.temp_allocator)
	}
	return cfg
}

@(private = "file")
_clone_suite_config_strings :: proc(cfg: ^Suite_Config, allocator: runtime.Allocator) {
	cfg.groups_filter = strings.clone(cfg.groups_filter, allocator)
	cfg.name_filter = strings.clone(cfg.name_filter, allocator)
	cfg.lang = strings.clone(cfg.lang, allocator)
	cfg.commit = strings.clone(cfg.commit, allocator)
	cfg.run_id = strings.clone(cfg.run_id, allocator)
	cfg.packet_out_path = strings.clone(cfg.packet_out_path, allocator)
}

@(private = "file")
_delete_suite_config_strings :: proc(cfg: ^Suite_Config, allocator: runtime.Allocator) {
	delete(cfg.groups_filter, allocator)
	delete(cfg.name_filter, allocator)
	delete(cfg.lang, allocator)
	delete(cfg.commit, allocator)
	delete(cfg.run_id, allocator)
	delete(cfg.packet_out_path, allocator)
	cfg^ = {}
}

/*
Creates a new `Suite` backed by `obench` (with `untimed_alloc_check = true` by default)
plus stateful multi-phase `Pipeline` groups.
*/
@(require_results)
suite_create :: proc(
	name: string,
	config: Maybe(Suite_Config) = nil,
	allocator := context.allocator,
	loc := #caller_location,
) -> Suite {
	cfg := config.? or_else default_suite_config()
	if config != nil {
		if cfg.runs <= 0 {
			cfg.runs = 7
		}
		if cfg.lang == "" {
			cfg.lang = "odin"
		}
		if cfg.commit == "" {
			cfg.commit = resolve_git_commit(".", context.temp_allocator)
		}
		if cfg.run_id == "" {
			cfg.run_id = default_run_id(context.temp_allocator)
		}
	}
	_clone_suite_config_strings(&cfg, allocator)
	ob_suite := obench.suite_create(name, cfg.obench_cfg, allocator, loc)
	return Suite {
		name = strings.clone(name, allocator, loc),
		config = cfg,
		obench_suite = ob_suite,
		pipelines = make([dynamic]_Pipeline_Def, allocator, loc),
		violations = make([dynamic]Phase_Violation, allocator, loc),
		allocator = allocator,
	}
}

suite_destroy :: proc(s: ^Suite) {
	if s == nil {
		return
	}
	for &p in s.pipelines {
		delete(p.group_name, s.allocator)
	}
	delete(s.pipelines)
	for &v in s.violations {
		delete(v.full_name, s.allocator)
	}
	delete(s.violations)
	packet_destroy(&s.last_packet, s.allocator)
	obench.suite_destroy(&s.obench_suite)
	_delete_suite_config_strings(&s.config, s.allocator)
	delete(s.name, s.allocator)
	s.name = ""
}

@(require_results)
group_add :: proc(s: ^Suite, name: string, loc := #caller_location) -> ^Group {
	return obench.group_add(&s.obench_suite, name, loc)
}

group_params :: proc(g: ^Group, params: []int) {
	obench.group_params(g, params)
}

group_threads :: proc(g: ^Group, thread_counts: []int) {
	obench.group_threads(g, thread_counts)
}

group_bench :: proc(
	g: ^Group,
	name: string,
	procedure: Bench_Proc,
	zero_alloc := false,
	user_ptr: rawptr = nil,
	loc := #caller_location,
) {
	obench.group_bench(g, name, procedure, zero_alloc, user_ptr, loc)
}

bench :: proc(
	s: ^Suite,
	name: string,
	procedure: Bench_Proc,
	zero_alloc := false,
	user_ptr: rawptr = nil,
	loc := #caller_location,
) {
	obench.bench(&s.obench_suite, name, procedure, zero_alloc, user_ptr, loc)
}

/*
Registers a stateful multi-phase `Pipeline` group on `s`.
Phases inside `procedure` share built state across sequential `phase_begin`/`phase_end`
sections while excluding setup/teardown and avoiding timed allocation-wrapper distortion.
*/
group_pipeline :: proc(
	s: ^Suite,
	group_name: string,
	procedure: Pipeline_Proc,
	param := 0,
	has_param := false,
	runs := 0,
	warmup := -1,
	user_ptr: rawptr = nil,
) {
	append(
		&s.pipelines,
		_Pipeline_Def {
			group_name = strings.clone(group_name, s.allocator),
			procedure = procedure,
			param = param,
			has_param = has_param,
			runs = runs,
			warmup = warmup,
			user_ptr = user_ptr,
		},
	)
}

@(require_results)
should_run_group :: proc(groups_filter: string, group_name: string) -> bool {
	if groups_filter == "" || groups_filter == "all" {
		return true
	}
	parts := strings.split_multi(groups_filter, {",", "|"}, context.temp_allocator)
	for raw_p in parts {
		p := strings.to_lower(strings.trim_space(raw_p), context.temp_allocator)
		if p == "" {
			continue
		}
		if p == "all" || strings.to_lower(group_name, context.temp_allocator) == p {
			return true
		}
	}
	return false
}

@(require_results)
matches_name_filter :: proc(name_filter: string, full_name: string) -> bool {
	if name_filter == "" {
		return true
	}
	lower_name := strings.to_lower(full_name, context.temp_allocator)
	parts := strings.split_multi(name_filter, {"|", ","}, context.temp_allocator)
	for raw_p in parts {
		p := strings.to_lower(strings.trim_space(raw_p), context.temp_allocator)
		if len(p) > 0 && strings.contains(lower_name, p) {
			return true
		}
	}
	return false
}

@(private = "file")
_obench_result_to_record :: proc(
	r: obench.Result,
	rank: int,
	allocator: runtime.Allocator,
) -> Record {
	st := r.stats
	ops := u64(max(st.batch_size, 1))
	sample_count := len(st.samples_batch_ns) > 0 ? len(st.samples_batch_ns) : len(st.samples_ns)
	rec := Record {
		rank               = rank,
		group_name         = strings.clone(r.group_name, allocator),
		name               = strings.clone(r.name, allocator),
		full_name          = strings.clone(r.full_name, allocator),
		param              = r.param,
		has_param          = r.has_param,
		threads            = r.threads,
		has_threads        = r.has_threads,
		ops_per_sample     = ops,
		samples            = st.samples,
		min_fs             = ns_f64_to_fs(st.min_ns),
		p25_fs             = ns_f64_to_fs(st.p25_ns),
		p50_fs             = ns_f64_to_fs(st.p50_ns),
		p75_fs             = ns_f64_to_fs(st.p75_ns),
		p95_fs             = ns_f64_to_fs(st.p95_ns),
		p99_fs             = ns_f64_to_fs(st.p99_ns),
		max_fs             = ns_f64_to_fs(st.max_ns),
		mean_fs            = ns_f64_to_fs(st.mean_ns),
		std_dev_fs         = ns_f64_to_fs(st.std_dev_ns),
		ci95_fs            = ns_f64_to_fs(st.ci95_ns),
		cv_pct             = st.cv_pct,
		iqr_fs             = ns_f64_to_fs(st.iqr_ns),
		mad_fs             = ns_f64_to_fs(st.mad_ns),
		median_cycles      = st.median_cycles,
		bytes_per_op       = st.bytes_per_op,
		items_per_op       = st.items_per_op,
		mb_per_sec         = st.mb_per_sec,
		items_per_sec      = st.items_per_sec,
		allocs_per_op      = st.allocs_per_op,
		resizes_per_op     = st.resizes_per_op,
		alloc_bytes_per_op = st.alloc_bytes_per_op,
		temp_allocs_per_op = st.temp_allocs_per_op,
		temp_bytes_per_op  = st.temp_bytes_per_op,
		peak_heap_bytes    = st.peak_heap_bytes,
		zero_alloc_failed  = r.zero_alloc_failed,
		error              = strings.clone(obench.bench_error_string(r.error), allocator),
		metrics            = make([dynamic]Metric, st.custom_metrics_count, allocator),
		samples_batch_ns   = make([dynamic]u64, sample_count, allocator),
	}
	if len(st.samples_batch_ns) > 0 {
		copy(rec.samples_batch_ns[:], st.samples_batch_ns)
		recompute_record_stats_from_samples(&rec)
	} else if len(st.samples_ns) > 0 {
		for s, i in st.samples_ns {
			rec.samples_batch_ns[i] = ns_f64_to_batch_ns(s, ops)
		}
		recompute_record_stats_from_samples(&rec)
	}
	refresh_record_throughput(&rec, overwrite = false)
	for i in 0 ..< st.custom_metrics_count {
		rec.metrics[i] = Metric {
			unit  = strings.clone(st.custom_metrics[i].unit, allocator),
			value = st.custom_metrics[i].value,
		}
	}
	return rec
}

/*
Executes all matching `obench` micro groups and stateful `Pipeline` groups silently,
populating `s.last_packet` and writing `--packet-out` if configured.
*/
@(require_results)
suite_execute :: proc(s: ^Suite) -> bool {
	s.failed_zero_alloc = 0
	s.failed_errors = 0
	s.failed_regressions = 0
	s.failed_io = 0
	for &v in s.violations {
		delete(v.full_name, s.allocator)
	}
	clear(&s.violations)
	packet_destroy(&s.last_packet, s.allocator)

	ts_unix := i64(time.to_unix_nanoseconds(time.now())) / 1_000_000_000
	pkt := Run_Packet {
		suite_name     = strings.clone(s.name, s.allocator),
		lang           = strings.clone(s.config.lang, s.allocator),
		commit         = strings.clone(s.config.commit, s.allocator),
		run_id         = strings.clone(s.config.run_id, s.allocator),
		os             = strings.clone(ODIN_OS_STRING, s.allocator),
		arch           = strings.clone(ODIN_ARCH_STRING, s.allocator),
		optimization   = strings.clone(fmt.tprintf("%v", ODIN_OPTIMIZATION_MODE), s.allocator),
		odin_version   = strings.clone(ODIN_VERSION, s.allocator),
		timestamp_unix = ts_unix,
		selective      = (s.config.groups_filter != "" &&
			s.config.groups_filter != "all") || s.config.name_filter != "",
		records        = make([dynamic]Record, s.allocator),
	}

	rank := 0

	// 1. Run matching obench micro-groups.
	if len(s.obench_suite.groups) > 0 {
		all_groups := make([dynamic]^Group, len(s.obench_suite.groups), context.temp_allocator)
		copy(all_groups[:], s.obench_suite.groups[:])
		clear(&s.obench_suite.groups)
		for g in all_groups {
			if should_run_group(s.config.groups_filter, g.name) {
				append(&s.obench_suite.groups, g)
			}
		}

		if len(s.obench_suite.groups) > 0 {
			// Clear obench's substring filter if multi-token `|`/` ,` filter is used,
			// so `matches_name_filter` handles multi-pattern filtering cleanly.
			saved_filter := s.obench_suite.config.filter
			if strings.contains_any(s.config.name_filter, "|,") {
				s.obench_suite.config.filter = ""
			}
			_ = obench.suite_execute(&s.obench_suite)
			s.obench_suite.config.filter = saved_filter

			s.failed_zero_alloc += s.obench_suite.failed_zero_alloc
			s.failed_errors += s.obench_suite.failed_errors
			s.failed_regressions += s.obench_suite.failed_regressions
			s.failed_io += s.obench_suite.failed_io

			for r in s.obench_suite.results {
				rank += 1
				if !matches_name_filter(s.config.name_filter, r.full_name) {
					continue
				}
				append(&pkt.records, _obench_result_to_record(r, rank, s.allocator))
			}
		}

		clear(&s.obench_suite.groups)
		for g in all_groups {
			append(&s.obench_suite.groups, g)
		}
		delete(all_groups)
	}

	// 2. Run matching stateful Pipeline groups using a private scratch arena.
	if len(s.pipelines) > 0 {
		temp_arena := runtime.Arena {
			backing_allocator = s.allocator,
		}
		defer runtime.arena_destroy(&temp_arena)

		for pdef in s.pipelines {
			if !should_run_group(s.config.groups_filter, pdef.group_name) {
				continue
			}
			recs, viols := _execute_pipeline(s, pdef, &rank, &temp_arena)
			for r in recs {
				append(&pkt.records, r)
			}
			delete(recs)
			for v in viols {
				append(&s.violations, v)
			}
			delete(viols)
		}
	}

	s.last_packet = pkt

	if s.config.packet_out_path != "" {
		if err := write_packet_file(s.config.packet_out_path, s.last_packet); err != nil {
			fmt.eprintfln("hugi: could not write packet '%s' (%v)", s.config.packet_out_path, err)
			s.failed_io += 1
		}
	}

	total_failures := s.failed_zero_alloc + s.failed_errors + s.failed_regressions + s.failed_io
	return total_failures == 0
}

/*
Writes the terminal report for `s` (both `obench` micro results and `Pipeline` phase rows) to `sb`.
*/
write_terminal_summary :: proc(sb: ^strings.Builder, s: ^Suite) {
	if len(s.obench_suite.results) > 0 {
		obench.write_terminal_report(strings.to_writer(sb), &s.obench_suite)
	}
	has_pipeline_rows := false
	for &r in s.last_packet.records {
		if r.samples > 0 || r.error != "" {
			// Skip rows already printed by obench when obench_suite.results is non-empty.
			already_in_obench := false
			for &obr in s.obench_suite.results {
				if obr.full_name == r.full_name {
					already_in_obench = true
					break
				}
			}
			if !already_in_obench {
				has_pipeline_rows = true
				break
			}
		}
	}
	if !has_pipeline_rows {
		return
	}

	fmt.sbprintf(
		sb,
		"\nhugi pipelines: %s (%s/%s, -o:%v, commit %s, clock overhead %s)\n",
		s.name,
		ODIN_OS_STRING,
		ODIN_ARCH_STRING,
		ODIN_OPTIMIZATION_MODE,
		s.last_packet.commit,
		format_duration_fs(
			s.obench_suite.clock.overhead_fs > 0 ? s.obench_suite.clock.overhead_fs : ns_f64_to_fs(s.obench_suite.clock.overhead_ns),
			context.temp_allocator,
		),
	)
	fmt.sbprintln(
		sb,
		"──────────────────────────────────────────────────────────────────────────────────────────────────────────────────",
	)
	fmt.sbprintf(
		sb,
		"%-42s │ %11s │ %11s │ %11s │ %6s │ %14s │ %s\n",
		"phase",
		"median(p50)",
		"p95",
		"ops/s",
		"CV%",
		"allocs / bytes",
		"notes",
	)
	fmt.sbprintln(
		sb,
		"──────────────────────────────────────────────────────────────────────────────────────────────────────────────────",
	)
	for &r in s.last_packet.records {
		in_obench := false
		for &obr in s.obench_suite.results {
			if obr.full_name == r.full_name {
				in_obench = true
				break
			}
		}
		if in_obench {
			continue
		}
		med_str := format_duration_fs(r.p50_fs, context.temp_allocator)
		p95_str := format_duration_fs(r.p95_fs, context.temp_allocator)
		alloc_str := "0 allocs"
		if r.allocs_per_op > 0 || r.alloc_bytes_per_op > 0 {
			alloc_str = fmt.tprintf(
				"%.1f / %s",
				r.allocs_per_op,
				obench.format_bytes(r.alloc_bytes_per_op, context.temp_allocator),
			)
		} else if r.temp_allocs_per_op > 0 {
			alloc_str = fmt.tprintf(
				"0 (tmp %.1f/%s)",
				r.temp_allocs_per_op,
				obench.format_bytes(r.temp_bytes_per_op, context.temp_allocator),
			)
		}
		notes := strings.builder_make(context.temp_allocator)
		if r.footprint_bytes > 0 {
			fmt.sbprintf(
				&notes,
				"footprint=%s ",
				obench.format_bytes(f64(r.footprint_bytes), context.temp_allocator),
			)
		}
		for m in r.metrics {
			fmt.sbprintf(&notes, "%.1f %s ", m.value, m.unit)
		}
		if r.zero_alloc_failed {
			strings.write_string(&notes, "[FAIL: @zero_alloc]")
		}
		ops_str := fmt.tprintf("%.0f", r.items_per_sec)
		cv_str := fmt.tprintf("%.1f%%", r.cv_pct)
		fmt.sbprintf(
			sb,
			"%-42s │ %11s │ %11s │ %11s │ %6s │ %14s │ %s\n",
			r.full_name,
			med_str,
			p95_str,
			ops_str,
			cv_str,
			alloc_str,
			strings.trim_space(strings.to_string(notes)),
		)
	}
	for v in s.violations {
		fmt.sbprintf(
			sb,
			"  zero-alloc violation in %s: %d bytes at %s(%d:%d) in `%s`\n",
			v.full_name,
			v.size,
			v.loc.file_path,
			v.loc.line,
			v.loc.column,
			v.loc.procedure,
		)
	}
	fmt.sbprintln(
		sb,
		"──────────────────────────────────────────────────────────────────────────────────────────────────────────────────",
	)
}

/*
Executes `s` and prints its terminal report unless `s.config.quiet` is set.
*/
@(require_results)
suite_run :: proc(s: ^Suite) -> bool {
	ok := suite_execute(s)
	if !s.config.quiet {
		sb := strings.builder_make(context.temp_allocator)
		write_terminal_summary(&sb, s)
		_, _ = os.write_string(os.stdout, strings.to_string(sb))
	}
	return ok
}

/*
Runs `s` inside an `odin test` procedure, logging the report and failing the test on any
error, `@zero_alloc` violation, regression, or file I/O failure.
*/
run_test :: proc(t: ^testing.T, s: ^Suite, loc := #caller_location) {
	color := s.obench_suite.config.color_output
	s.obench_suite.config.color_output = false
	ok := suite_execute(s)
	sb := strings.builder_make(context.temp_allocator)
	write_terminal_summary(&sb, s)
	s.obench_suite.config.color_output = color

	log.info(strings.to_string(sb), location = loc)
	testing.expectf(
		t,
		ok,
		"hugi suite %q failed: %d errors, %d @zero_alloc failures, %d regressions, %d file errors",
		s.name,
		s.failed_errors,
		s.failed_zero_alloc,
		s.failed_regressions,
		s.failed_io,
		loc = loc,
	)
}
