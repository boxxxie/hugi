package hugi_specs

import skadi "../deps/skadi/skadi"
import hugi "../hugi"
import store "../store"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

@(private)
_Export_Audit :: struct {
	ok:                   bool,
	row_count:            int,
	col_count:            int,
	schema_exact:         bool,
	samples_roundtrip_ok: bool,
	detail:               string,
}

@(private)
_CLI_Result :: struct {
	started:   bool,
	exit_code: int,
	stdout:    string,
	stderr:    string,
}

@(private)
_driver_cli_result_destroy :: proc(res: ^_CLI_Result, allocator := context.allocator) {
	if res == nil {
		return
	}
	delete(res.stdout, allocator)
	delete(res.stderr, allocator)
	res^ = {}
}

@(private)
_driver_build_packet :: proc(
	commit, lang, run_id, suite_name: string,
	benches: []Bench_Observation,
	selective := false,
	timestamp_unix: i64 = 1770000000,
	env := hugi.Run_Env{},
	allocator := context.allocator,
) -> hugi.Run_Packet {
	pkt := hugi.Run_Packet {
		suite_name     = strings.clone(suite_name, allocator),
		lang           = strings.clone(lang, allocator),
		commit         = strings.clone(commit, allocator),
		run_id         = strings.clone(run_id, allocator),
		os             = strings.clone("linux", allocator),
		arch           = strings.clone("amd64", allocator),
		optimization   = strings.clone("Speed", allocator),
		odin_version   = strings.clone("spec", allocator),
		timestamp_unix = timestamp_unix,
		selective      = selective,
		env            = hugi.run_env_clone(env, allocator),
		records        = make([dynamic]hugi.Record, 0, len(benches), allocator),
	}

	for b, i in benches {
		grp := b.group != "" ? b.group : "core"
		short_name := b.name
		full_name := ""
		if sep := strings.index(b.name, "::"); sep >= 0 {
			if b.group == "" {
				grp = b.name[:sep]
			}
			short_name = b.name[sep + 2:]
			full_name = strings.clone(b.name, allocator)
		} else {
			full_name = fmt.aprintf("%s::%s", grp, short_name, allocator = allocator)
		}

		ops := b.ops_per_sample > 0 ? b.ops_per_sample : 100
		n_samples :=
			len(b.exact_batch_ns) > 0 ? len(b.exact_batch_ns) : (b.zero_samples ? 0 : (b.samples > 0 ? b.samples : 16))
		spread := b.no_spread ? 0.0 : (b.spread_ns > 0.0 ? b.spread_ns : 1.0)
		bytes_op := b.zero_bytes_per_op ? 0 : (b.bytes_per_op > 0 ? b.bytes_per_op : 64)
		rank := b.rank > 0 ? b.rank : i + 1

		samples := make([dynamic]u64, n_samples, allocator)
		if len(b.exact_batch_ns) > 0 {
			copy(samples[:], b.exact_batch_ns)
		} else {
			for s in 0 ..< n_samples {
				offset := (f64(s) - f64(n_samples - 1) * 0.5) * spread
				samples[s] = hugi.ns_f64_to_batch_ns(max(b.median_ns + offset, 1.0), ops)
			}
		}

		metrics := make([dynamic]hugi.Metric, allocator)
		if len(b.metrics) > 0 {
			for m in b.metrics {
				append(
					&metrics,
					hugi.Metric{unit = strings.clone(m.unit, allocator), value = m.value},
				)
			}
		} else if b.metric_unit != "" {
			append(
				&metrics,
				hugi.Metric {
					unit = strings.clone(b.metric_unit, allocator),
					value = b.metric_value,
				},
			)
		}

		r := hugi.Record {
			rank              = rank,
			group_name        = strings.clone(grp, allocator),
			name              = strings.clone(short_name, allocator),
			full_name         = full_name,
			param             = b.param,
			has_param         = b.has_param,
			threads           = b.threads,
			has_threads       = b.has_threads,
			ops_per_sample    = ops,
			samples           = n_samples,
			bytes_per_op      = bytes_op,
			items_per_op      = b.items_per_op,
			footprint_bytes   = b.footprint_bytes,
			allocs_per_op     = b.allocs_per_op,
			peak_heap_bytes   = b.peak_heap_bytes,
			zero_alloc_failed = b.zero_alloc_failed,
			error             = strings.clone(b.error, allocator),
			samples_batch_ns  = samples,
			metrics           = metrics,
		}
		hugi.recompute_record_stats_from_samples(&r)
		hugi.refresh_record_throughput(&r, overwrite = true)
		append(&pkt.records, r)
	}
	return pkt
}

@(private = "file")
_driver_bench_zero_alloc :: proc(b: ^hugi.Bencher) {
	data := [8]u64{1, 2, 3, 4, 5, 6, 7, 8}
	hugi.expect_zero_allocs(b)
	for hugi.step(b) {
		acc := u64(0)
		for v in data {
			acc += v
		}
		_ = hugi.black_box(acc)
	}
}

@(private = "file")
_driver_bench_allocating :: proc(b: ^hugi.Bencher) {
	hugi.set_bytes(b, 64)
	for hugi.step(b) {
		buf := make([]u8, 64)
		buf[0] = 1
		_ = hugi.black_box(buf[0])
		delete(buf)
	}
}

@(private)
_Pipeline_Spec_Ctx :: struct {
	phases: []Phase_Spec,
}

@(private = "file")
_driver_run_phase_node :: proc(p: ^hugi.Pipeline, all: []Phase_Spec, idx: int) {
	spec := all[idx]
	ops := spec.ops > 0 ? spec.ops : 16
	ph := hugi.phase_begin(
		p,
		spec.name,
		ops = ops,
		bytes_per_op = spec.bytes_per_op,
		zero_alloc = spec.zero_alloc,
	)
	if spec.allocates {
		buf := make([]u8, 64)
		buf[0] = 1
		_ = hugi.black_box(buf[0])
		delete(buf)
	} else {
		acc := u64(p.param)
		for i in 0 ..< ops {
			acc += u64(i * 3) + 1
		}
		_ = hugi.black_box(acc)
	}
	for child, c_idx in all {
		if child.parent == spec.name && c_idx != idx {
			_driver_run_phase_node(p, all, c_idx)
		}
	}
	if spec.has_footprint {
		hugi.phase_set_footprint(ph, spec.footprint_bytes)
	}
	if spec.has_metric {
		hugi.phase_metric(ph, spec.metric_value, spec.metric_unit)
	}
	if spec.has_secondary {
		hugi.phase_metric(ph, spec.secondary_value, spec.secondary_metric)
	}
	hugi.phase_end(ph)
}

@(private = "file")
_driver_pipeline_exec :: proc(p: ^hugi.Pipeline) {
	if p == nil || p.user_ptr == nil {
		return
	}
	ctx := (^_Pipeline_Spec_Ctx)(p.user_ptr)
	for ph, i in ctx.phases {
		if ph.parent == "" {
			_driver_run_phase_node(p, ctx.phases, i)
		}
	}
}

@(private)
_driver_suite_create :: proc(
	name: string,
	groups_filter := "",
	name_filter := "",
	packet_out_path := "",
	runs := 4,
	warmup := 1,
	allocator := context.allocator,
) -> hugi.Suite {
	cfg := hugi.default_suite_config()
	cfg.quiet = true
	cfg.runs = runs
	cfg.warmup = warmup
	cfg.obench_cfg.sample_count = 15
	cfg.obench_cfg.warmup_time = 0
	cfg.obench_cfg.fixed_batch_size = 16
	cfg.lang = "odin"
	cfg.commit = "spec001"
	cfg.run_id = "spec-run-1"
	cfg.groups_filter = groups_filter
	cfg.name_filter = name_filter
	cfg.packet_out_path = packet_out_path
	if name_filter != "" && !strings.contains_any(name_filter, "|,") {
		cfg.obench_cfg.filter = name_filter
	}
	return hugi.suite_create(name, cfg, allocator)
}

@(private)
_driver_suite_add_micro :: proc(
	s: ^hugi.Suite,
	group: string,
	name: string,
	zero_alloc := false,
	allocates := false,
	params: []int = nil,
	thread_counts: []int = nil,
) {
	proc_fn := allocates ? _driver_bench_allocating : _driver_bench_zero_alloc
	if (group == "" || group == "default") && len(params) == 0 && len(thread_counts) == 0 {
		hugi.bench(s, name, proc_fn, zero_alloc = zero_alloc)
		return
	}
	grp_name := group != "" ? group : "default"
	grp_ptr: ^hugi.Group
	for g in s.obench_suite.groups {
		if g.name == grp_name {
			grp_ptr = g
			break
		}
	}
	if grp_ptr == nil {
		grp_ptr = hugi.group_add(s, grp_name)
	}
	if len(params) > 0 {
		hugi.group_params(grp_ptr, params)
	}
	if len(thread_counts) > 0 {
		hugi.group_threads(grp_ptr, thread_counts)
	}
	hugi.group_bench(grp_ptr, name, proc_fn, zero_alloc = zero_alloc)
}

@(private)
_driver_suite_add_pipeline :: proc(
	s: ^hugi.Suite,
	group: string,
	ctx: ^_Pipeline_Spec_Ctx,
	param := 0,
	has_param := false,
	runs := 0,
	warmup := -1,
) {
	hugi.group_pipeline(
		s,
		group,
		_driver_pipeline_exec,
		param = param,
		has_param = has_param,
		runs = runs,
		warmup = warmup,
		user_ptr = ctx,
	)
}

@(private)
_driver_suite_execute :: proc(s: ^hugi.Suite) -> bool {
	return hugi.suite_execute(s)
}

@(private)
_driver_suite_terminal_summary :: proc(s: ^hugi.Suite, allocator := context.allocator) -> string {
	sb: strings.Builder
	strings.builder_init(&sb, allocator)
	hugi.write_terminal_summary(&sb, s)
	return strings.to_string(sb)
}

@(private)
_driver_suite_failure_messages :: proc(
	s: ^hugi.Suite,
	allocator := context.allocator,
) -> []string {
	return hugi.suite_failure_messages(s, allocator)
}

@(private)
_driver_suite_destroy :: proc(s: ^hugi.Suite) {
	hugi.suite_destroy(s)
}

@(private)
_driver_write_packet_file :: proc(path: string, pkt: hugi.Run_Packet) -> bool {
	return hugi.write_packet_file(path, pkt) == nil
}

@(private)
_driver_read_packet_file :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	hugi.Run_Packet,
	bool,
) {
	return hugi.read_packet_file(path, allocator)
}

@(private)
_driver_write_jsonl_fixture :: proc(
	path: string,
	commit, lang, run_id, full_name: string,
	median_ns: f64,
	ops: u64,
	bytes_used: u64,
) -> bool {
	grp := "core"
	if sep := strings.index(full_name, "::"); sep >= 0 {
		grp = full_name[:sep]
	}
	line := fmt.aprintf(
		`{{"rank":1,"group":"%s","lang":"%s","commit":"%s","run_id":"%s","name":"%s","ops":%d,"runs":3,"warmup":1,"median_ns":%.6f,"samples_ns":[%.6f,%.6f,%.6f],"bytes_used":%d}}` +
		"\n",
		grp,
		lang,
		commit,
		run_id,
		full_name,
		ops,
		median_ns,
		max(median_ns - 1.0, 0.1),
		median_ns,
		median_ns + 1.0,
		bytes_used,
		allocator = context.temp_allocator,
	)
	return os.write_entire_file(path, transmute([]u8)line) == nil
}

@(private)
_driver_write_obench_json_fixture :: proc(
	path: string,
	suite_name, group_name, bench_name: string,
	median_ns: f64,
	batch_size: u64,
) -> bool {
	full_name := fmt.aprintf("%s::%s", group_name, bench_name, allocator = context.temp_allocator)
	batch_mid := u64(math_round_u64(median_ns * f64(max(batch_size, 1))))
	payload := fmt.aprintf(
		`{{"format_version":3,"suite_name":"%s","os":"linux","arch":"amd64","optimization":"Speed","odin_version":"dev","benchmarks":[{{"suite_name":"%s","group_name":"%s","name":"%s","full_name":"%s","samples":3,"batch_size":%d,"min_ns":%.6f,"p50_ns":%.6f,"p95_ns":%.6f,"p99_ns":%.6f,"max_ns":%.6f,"mean_ns":%.6f,"samples_batch_ns":[%d,%d,%d]}}]}}`,
		suite_name,
		suite_name,
		group_name,
		bench_name,
		full_name,
		batch_size,
		max(median_ns - 0.1, 0.1),
		median_ns,
		median_ns + 0.1,
		median_ns + 0.1,
		median_ns + 0.1,
		median_ns,
		max(batch_mid, 1) - 1,
		max(batch_mid, 1),
		max(batch_mid, 1) + 1,
		allocator = context.temp_allocator,
	)
	return os.write_entire_file(path, transmute([]u8)payload) == nil
}

@(private)
_driver_write_obench_v6_json_fixture :: proc(
	path: string,
	suite_name,
	group_name,
	bench_name,
	commit,
	created_at,
	cpu,
	governor,
	boost,
	microarch,
	bounds_checks: string,
	median_ns: f64,
	batch_size: u64,
	peak_heap_bytes: i64,
	zero_alloc_failed: bool,
	instructions: f64,
) -> bool {
	full_name := fmt.aprintf("%s::%s", group_name, bench_name, allocator = context.temp_allocator)
	batch_mid := u64(math_round_u64(median_ns * f64(max(batch_size, 1))))
	payload := fmt.aprintf(
		`{{"format_version":6,"suite_name":"%s","os":"linux","arch":"amd64","optimization":"Speed","odin_version":"dev-2026-10","created_at":"%s","git":{{"commit":"%s","branch":"main","dirty":false}},"machine":{{"cpu":"%s","cores":8,"governor":"%s","boost":"%s","smt":"on"}},"build":{{"microarch":"%s","bounds_checks":"%s","odin_version_hash":"abc"}},"benchmarks":[{{"suite_name":"%s","group_name":"%s","name":"%s","full_name":"%s","samples":3,"batch_size":%d,"min_ns":%.6f,"p50_ns":%.6f,"p95_ns":%.6f,"p99_ns":%.6f,"max_ns":%.6f,"mean_ns":%.6f,"samples_batch_ns":[%d,%d,%d],"peak_heap_bytes":%d,"zero_alloc_failed":%s,"instructions":%.2f}}]}}`,
		suite_name,
		created_at,
		commit,
		cpu,
		governor,
		boost,
		microarch,
		bounds_checks,
		suite_name,
		group_name,
		bench_name,
		full_name,
		batch_size,
		max(median_ns - 0.1, 0.1),
		median_ns,
		median_ns + 0.1,
		median_ns + 0.1,
		median_ns + 0.1,
		median_ns,
		max(batch_mid, 1) - 1,
		max(batch_mid, 1),
		max(batch_mid, 1) + 1,
		peak_heap_bytes,
		"true" if zero_alloc_failed else "false",
		instructions,
		allocator = context.temp_allocator,
	)
	return os.write_entire_file(path, transmute([]u8)payload) == nil
}

@(private)
_driver_write_obench_combined_json_fixture :: proc(
	path: string,
	suite_name, group_name, bench_name: string,
	samples_ns: [4]f64,
) -> bool {
	full_name := fmt.aprintf("%s::%s", group_name, bench_name, allocator = context.temp_allocator)
	payload := fmt.aprintf(
		`{{"format_version":6,"suite_name":"%s","os":"linux","arch":"amd64","optimization":"Speed","odin_version":"dev-2026-11","processes":2,"benchmarks":[{{"suite_name":"%s","group_name":"%s","name":"%s","full_name":"%s","samples":4,"batch_size":1,"min_ns":%.6f,"p50_ns":%.6f,"p95_ns":%.6f,"p99_ns":%.6f,"max_ns":%.6f,"mean_ns":%.6f,"samples_ns":[%.6f,%.6f,%.6f,%.6f],"process_medians_ns":[%.6f,%.6f]}}]}}`,
		suite_name,
		suite_name,
		group_name,
		bench_name,
		full_name,
		samples_ns[0],
		samples_ns[1],
		samples_ns[3],
		samples_ns[3],
		samples_ns[3],
		samples_ns[1],
		samples_ns[0],
		samples_ns[1],
		samples_ns[2],
		samples_ns[3],
		samples_ns[0],
		samples_ns[3],
		allocator = context.temp_allocator,
	)
	return os.write_entire_file(path, transmute([]u8)payload) == nil
}

@(private = "file")
math_round_u64 :: proc(v: f64) -> u64 {
	if v <= 0 {
		return 0
	}
	return u64(v + 0.5)
}

@(private)
_driver_store_open :: proc(path: string, allocator := context.allocator) -> (store.Store, bool) {
	return store.store_open(path, allocator)
}

@(private)
_driver_store_open_overlay :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	store.Store,
	bool,
) {
	return store.store_open_overlay(path, allocator)
}

@(private)
_driver_store_close :: proc(st: ^store.Store) {
	store.store_close(st)
}

@(private)
_driver_store_set_write_options :: proc(st: ^store.Store, keep_hot_runs, cold_chunk_runs: int) {
	store.store_set_write_options(
		st,
		store.Store_Write_Options {
			keep_hot_runs = keep_hot_runs,
			cold_chunk_runs = cold_chunk_runs,
		},
	)
}

@(private)
_driver_store_ingest_packet :: proc(st: ^store.Store, pkt: hugi.Run_Packet) -> bool {
	return store.store_ingest_packet(st, pkt)
}

@(private)
_driver_store_compact :: proc(
	db_path: string,
	keep_hot_runs := 0,
	cold_chunk_runs := 32,
) -> (
	before_bytes: i64,
	after_bytes: i64,
	ok: bool,
) {
	opts := store.Store_Write_Options {
		keep_hot_runs   = keep_hot_runs,
		cold_chunk_runs = cold_chunk_runs,
	}
	return store.store_compact_with_options(db_path, opts)
}

@(private)
_driver_store_list_runs :: proc(
	st: ^store.Store,
	allocator := context.allocator,
) -> []store.Run_Summary {
	return store.store_list_runs(st, allocator)
}

@(private)
_driver_store_list_commits :: proc(
	st: ^store.Store,
	allocator := context.allocator,
) -> []store.Commit_Summary {
	return store.store_list_commits(st, allocator)
}

@(private)
_driver_store_load_pooled :: proc(
	st: ^store.Store,
	lang := "odin",
	commit := "",
	run_id := "",
	filter := "",
	allocator := context.allocator,
) -> []store.Pooled_Record {
	return store.store_load_pooled_records(st, lang, commit, run_id, filter, allocator)
}

@(private)
_driver_store_load_commit_series :: proc(
	st: ^store.Store,
	lang := "odin",
	filter := "",
	allocator := context.allocator,
) -> []store.Pooled_Record {
	return store.store_load_commit_series_records(st, lang, filter, allocator)
}

@(private)
_driver_store_load_all_runs :: proc(
	st: ^store.Store,
	lang := "odin",
	filter := "",
	allocator := context.allocator,
) -> []store.Pooled_Record {
	return store.store_load_all_run_records(st, lang, filter, allocator)
}

@(private)
_driver_store_load_all_packets :: proc(
	st: ^store.Store,
	allocator := context.allocator,
) -> []hugi.Run_Packet {
	return store.store_load_all_packets(st, allocator)
}

@(private)
_driver_compare_commits :: proc(
	st: ^store.Store,
	lang, base_commit, cand_commit: string,
	threshold_pct := 5.0,
	allocator := context.allocator,
	use_run_medians := false,
) -> store.Comparison_Report {
	base := store.store_load_pooled_records(st, lang, base_commit, "", "", context.temp_allocator)
	defer store.pooled_records_destroy(base, context.temp_allocator)
	cand := store.store_load_pooled_records(st, lang, cand_commit, "", "", context.temp_allocator)
	defer store.pooled_records_destroy(cand, context.temp_allocator)
	return store.compare_records(
		base,
		cand,
		threshold_pct,
		allocator,
		use_run_medians = use_run_medians,
	)
}

@(private)
_driver_compare_1v1 :: proc(
	st: ^store.Store,
	lang_a, lang_b, commit: string,
	threshold_pct := 3.0,
	allocator := context.allocator,
) -> store.Cross_Lang_Report {
	return store.compare_1v1_langs(st, lang_a, lang_b, commit, threshold_pct, allocator)
}

@(private)
_driver_read_file_bytes :: proc(path: string, allocator := context.allocator) -> ([]u8, bool) {
	data, err := os.read_entire_file(path, allocator)
	return data, err == nil
}

@(private)
_driver_write_file_bytes :: proc(path: string, data: []u8) -> bool {
	return os.write_entire_file(path, data) == nil
}

@(private)
_driver_bytes_equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

@(private)
_driver_export_records :: proc(
	format: Export_Format,
	path: string,
	records: []store.Pooled_Record,
) -> bool {
	switch format {
	case .Arrow:
		return store.export_arrow_ipc(path, records, .LZ4_Frame, context.allocator)
	case .Parquet:
		return store.export_parquet(path, records, true, context.allocator)
	case .Json:
		return store.export_json(path, records)
	case .Jsonl:
		return store.export_jsonl(path, records)
	case .Csv:
		return store.export_csv(path, records)
	case .Tsv:
		return store.export_tsv(path, records)
	case .Markdown:
		return store.export_markdown(path, records)
	}
	return false
}

@(private)
_driver_update_readme :: proc(readme_path: string, records: []store.Pooled_Record) -> bool {
	md := store.format_markdown_table(records, context.temp_allocator)
	return store.update_readme_markers(readme_path, md)
}

@(private = "file")
_extract_parquet_schema_and_rows :: proc(
	pq_bytes: []u8,
	allocator := context.allocator,
) -> (
	cols: []string,
	num_rows: int,
	ok: bool,
) {
	n := len(pq_bytes)
	if n < 12 || string(pq_bytes[:4]) != "PAR1" || string(pq_bytes[n - 4:]) != "PAR1" {
		return nil, 0, false
	}
	flen_bytes: [4]u8
	copy(flen_bytes[:], pq_bytes[n - 8:n - 4])
	flen := int(u32(transmute(u32le)flen_bytes))
	if flen <= 0 || flen > n - 12 {
		return nil, 0, false
	}
	footer := pq_bytes[n - 8 - flen:n - 8]
	pos := 0

	read_u8 :: proc(data: []u8, pos: ^int) -> (u8, bool) {
		if pos^ >= len(data) {
			return 0, false
		}
		v := data[pos^]
		pos^ += 1
		return v, true
	}
	read_varint :: proc(data: []u8, pos: ^int) -> (val: u64, ok: bool) {
		shift: uint = 0
		for shift < 64 {
			b := read_u8(data, pos) or_return
			val |= u64(b & 0x7F) << shift
			if (b & 0x80) == 0 {
				return val, true
			}
			shift += 7
		}
		return 0, false
	}
	read_field_hdr :: proc(
		data: []u8,
		pos: ^int,
		prev: ^i32,
	) -> (
		fid: i32,
		ftype: u8,
		stop: bool,
		ok: bool,
	) {
		b := read_u8(data, pos) or_return
		if b == 0 {
			return 0, 0, true, true
		}
		delta := i32((b >> 4) & 0x0F)
		ftype = b & 0x0F
		if delta == 0 {
			zz := u16(read_varint(data, pos) or_return)
			fid = i32(i16((zz >> 1) ~ u16(-i16(zz & 1))))
		} else {
			fid = prev^ + delta
		}
		prev^ = fid
		return fid, ftype, false, true
	}

	out := make([dynamic]string, 0, store.EXPORT_TOTAL_COL_COUNT, allocator)
	defer if !ok {
		for s in out {
			delete(s, allocator)
		}
		delete(out)
	}
	saw_schema := false
	saw_rows := false

	fprev: i32 = 0
	for {
		fid, ftype, stop, h_ok := read_field_hdr(footer, &pos, &fprev)
		if !h_ok {
			return nil, 0, false
		}
		if stop {
			break
		}
		if fid == 2 && ftype == 9 {
			lh := read_u8(footer, &pos) or_return
			cnt := int(lh >> 4)
			elem_type := lh & 0x0F
			if cnt == 15 {
				c64 := read_varint(footer, &pos) or_return
				cnt = int(c64)
			}
			if elem_type != 12 || cnt < 1 {
				return nil, 0, false
			}
			for elem_idx in 0 ..< cnt {
				sprev: i32 = 0
				elem_name := ""
				for {
					sfid, sftype, sstop, sh_ok := read_field_hdr(footer, &pos, &sprev)
					if !sh_ok {
						return nil, 0, false
					}
					if sstop {
						break
					}
					switch sftype {
					case 5, 6:
						_ = read_varint(footer, &pos) or_return
					case 8:
						slen := int(read_varint(footer, &pos) or_return)
						if slen < 0 || pos + slen > len(footer) {
							return nil, 0, false
						}
						if sfid == 4 {
							elem_name = string(footer[pos:pos + slen])
						}
						pos += slen
					case:
						return nil, 0, false
					}
				}
				if elem_idx > 0 {
					append(&out, strings.clone(elem_name, allocator))
				}
			}
			saw_schema = true
		} else if fid == 3 && ftype == 6 {
			zz := read_varint(footer, &pos) or_return
			num_rows = int(i64((zz >> 1) ~ u64(-i64(zz & 1))))
			saw_rows = true
			if saw_schema {
				ok = true
				return out[:], num_rows, true
			}
		} else if ftype == 5 || ftype == 6 {
			_ = read_varint(footer, &pos) or_return
		} else {
			break
		}
	}
	if saw_schema && saw_rows {
		ok = true
		return out[:], num_rows, true
	}
	return nil, 0, false
}

@(private = "file")
_extract_first_json_object_keys :: proc(text: string, allocator := context.allocator) -> []string {
	keys := make([dynamic]string, allocator)
	obj_start := strings.index_byte(text, '{')
	if obj_start < 0 {
		return keys[:]
	}
	brace_depth := 0
	bracket_depth := 0
	i := obj_start
	for i < len(text) {
		ch := text[i]
		switch ch {
		case '{':
			brace_depth += 1
			i += 1
		case '}':
			brace_depth -= 1
			i += 1
			if brace_depth == 0 {
				return keys[:]
			}
		case '[':
			bracket_depth += 1
			i += 1
		case ']':
			bracket_depth -= 1
			i += 1
		case '"':
			j := i + 1
			for j < len(text) {
				if text[j] == '\\' {
					j += 2
					continue
				}
				if text[j] == '"' {
					break
				}
				j += 1
			}
			str_val := text[i + 1:min(j, len(text))]
			i = j + 1
			if brace_depth == 1 && bracket_depth == 0 {
				k := i
				for k < len(text) && (text[k] == ' ' || text[k] == '\t') {
					k += 1
				}
				if k < len(text) && text[k] == ':' {
					append(&keys, strings.clone(str_val, allocator))
				}
			}
		case:
			i += 1
		}
	}
	return keys[:]
}

@(private = "file")
_split_delimited_line :: proc(
	line: string,
	delim: byte,
	allocator := context.temp_allocator,
) -> []string {
	fields := make([dynamic]string, allocator)
	sb := strings.builder_make(allocator)
	in_quotes := false
	i := 0
	for i < len(line) {
		ch := line[i]
		if in_quotes {
			if ch == '"' {
				if i + 1 < len(line) && line[i + 1] == '"' {
					strings.write_byte(&sb, '"')
					i += 2
					continue
				}
				in_quotes = false
				i += 1
				continue
			}
			strings.write_byte(&sb, ch)
			i += 1
		} else {
			if ch == '"' && strings.builder_len(sb) == 0 {
				in_quotes = true
				i += 1
				continue
			}
			if ch == delim {
				append(&fields, strings.clone(strings.to_string(sb), allocator))
				strings.builder_reset(&sb)
				i += 1
				continue
			}
			strings.write_byte(&sb, ch)
			i += 1
		}
	}
	append(&fields, strings.clone(strings.to_string(sb), allocator))
	strings.builder_destroy(&sb)
	return fields[:]
}

@(private = "file")
_verify_json_object_keys_exact :: proc(keys: []string) -> bool {
	if len(keys) < store.EXPORT_SCALAR_COL_COUNT + 1 {
		return false
	}
	for i in 0 ..< store.EXPORT_SCALAR_COL_COUNT {
		if keys[i] != store.EXPORT_COLUMNS[i].name {
			return false
		}
	}
	if len(keys) == store.EXPORT_SCALAR_COL_COUNT + 1 {
		return keys[store.EXPORT_SCALAR_COL_COUNT] == "samples_ns"
	}
	if len(keys) == store.EXPORT_SCALAR_COL_COUNT + 2 {
		return(
			keys[store.EXPORT_SCALAR_COL_COUNT] == "samples_batch_ns" &&
			keys[store.EXPORT_SCALAR_COL_COUNT + 1] == "samples_ns" \
		)
	}
	return false
}

@(private)
_driver_verify_export :: proc(
	format: Export_Format,
	path: string,
	expected_records: []store.Pooled_Record = nil,
) -> _Export_Audit {
	switch format {
	case .Arrow:
		sc, bs, read_ok := skadi.ipc_read_file(path, context.allocator, true, false)
		if !read_ok {
			return _Export_Audit{detail = "skadi.ipc_read_file failed"}
		}
		defer {
			for &b in bs {
				skadi.record_batch_free(&b)
			}
			delete(bs)
			if sc != nil {
				skadi.schema_free(sc)
				free(sc)
			}
		}

		schema_ok := len(sc.fields) == store.EXPORT_TOTAL_COL_COUNT
		if schema_ok {
			for i in 0 ..< store.EXPORT_TOTAL_COL_COUNT {
				if sc.fields[i].name != store.EXPORT_COLUMNS[i].name {
					schema_ok = false
					break
				}
			}
		}

		total_rows := 0
		for &b in bs {
			total_rows += b.length
		}

		samples_ok := true
		row_offset := 0
		for &b in bs {
			if b.length == 0 {
				continue
			}
			p50_col := skadi.record_batch_column(&b, "p50_ns")
			if p50_col == nil ||
			   p50_col.type != skadi.DataType(skadi.Decimal64_Type{precision = 18, scale = 6}) {
				schema_ok = false
			}
			blob_col := skadi.record_batch_column(&b, "samples_blob")
			if len(expected_records) > 0 {
				for r_idx in 0 ..< b.length {
					exp_idx := row_offset + r_idx
					if exp_idx >= len(expected_records) {
						samples_ok = false
						break
					}
					if p50_col == nil ||
					   skadi.array_get(p50_col, r_idx, i64) != expected_records[exp_idx].p50_fs {
						samples_ok = false
						break
					}
					if blob_col == nil {
						samples_ok = false
						break
					}
					raw_blob := skadi.array_get_binary(blob_col, r_idx)
					back_fs, d_ok := store.decompress_exported_samples_fs(
						raw_blob,
						expected_records[exp_idx].ops_per_sample,
						context.allocator,
					)
					if !d_ok || len(back_fs) != len(expected_records[exp_idx].samples_fs) {
						delete(back_fs)
						samples_ok = false
						break
					}
					for sv, si in back_fs {
						if sv != expected_records[exp_idx].samples_fs[si] {
							samples_ok = false
							break
						}
					}
					delete(back_fs)
					if !samples_ok {
						break
					}
				}
			}
			row_offset += b.length
		}
		if len(expected_records) > 0 && row_offset != len(expected_records) {
			samples_ok = false
		}

		return _Export_Audit {
			ok = schema_ok && samples_ok,
			row_count = total_rows,
			col_count = len(sc.fields),
			schema_exact = schema_ok,
			samples_roundtrip_ok = samples_ok,
			detail = "arrow verified",
		}

	case .Parquet:
		raw, r_err := os.read_entire_file(path, context.allocator)
		if r_err != nil {
			return _Export_Audit{detail = "parquet read failed"}
		}
		defer delete(raw)
		cols, num_rows, pq_ok := _extract_parquet_schema_and_rows(raw, context.allocator)
		if !pq_ok {
			return _Export_Audit{detail = "parquet schema/footer decode failed"}
		}
		defer {
			for c in cols {
				delete(c)
			}
			delete(cols)
		}
		schema_ok := len(cols) == store.EXPORT_TOTAL_COL_COUNT
		if schema_ok {
			for i in 0 ..< store.EXPORT_TOTAL_COL_COUNT {
				if cols[i] != store.EXPORT_COLUMNS[i].name {
					schema_ok = false
					break
				}
			}
		}
		return _Export_Audit {
			ok = schema_ok,
			row_count = num_rows,
			col_count = len(cols),
			schema_exact = schema_ok,
			samples_roundtrip_ok = false,
			detail = "parquet verified",
		}

	case .Csv, .Tsv:
		raw, r_err := os.read_entire_file(path, context.allocator)
		if r_err != nil {
			return _Export_Audit{detail = "delimited read failed"}
		}
		defer delete(raw)
		delim: byte = format == .Csv ? ',' : '\t'
		lines := strings.split_lines(string(raw), context.temp_allocator)
		line_count := len(lines)
		if line_count > 0 && lines[line_count - 1] == "" {
			line_count -= 1
		}
		if line_count == 0 {
			return _Export_Audit{detail = "delimited file empty"}
		}
		hdr := _split_delimited_line(lines[0], delim, context.temp_allocator)
		schema_ok := len(hdr) == store.EXPORT_SCALAR_COL_COUNT
		if schema_ok {
			for i in 0 ..< store.EXPORT_SCALAR_COL_COUNT {
				if hdr[i] != store.EXPORT_COLUMNS[i].name {
					schema_ok = false
					break
				}
			}
		}
		rows := line_count - 1
		for ri in 1 ..< line_count {
			fields := _split_delimited_line(lines[ri], delim, context.temp_allocator)
			if len(fields) != store.EXPORT_SCALAR_COL_COUNT {
				schema_ok = false
				break
			}
		}
		return _Export_Audit {
			ok = schema_ok,
			row_count = rows,
			col_count = len(hdr),
			schema_exact = schema_ok,
			samples_roundtrip_ok = true,
			detail = "delimited verified",
		}

	case .Json:
		raw, r_err := os.read_entire_file(path, context.allocator)
		if r_err != nil {
			return _Export_Audit{detail = "json read failed"}
		}
		defer delete(raw)
		parsed, p_err := json.parse(raw, allocator = context.allocator)
		if p_err != .None {
			return _Export_Audit{detail = "json parse failed"}
		}
		defer json.destroy_value(parsed, context.allocator)
		arr, is_arr := parsed.(json.Array)
		if !is_arr {
			return _Export_Audit{detail = "json root is not array"}
		}
		schema_ok := true
		col_count := store.EXPORT_SCALAR_COL_COUNT
		if len(arr) > 0 {
			keys := _extract_first_json_object_keys(string(raw), context.allocator)
			defer {
				for k in keys {
					delete(k)
				}
				delete(keys)
			}
			schema_ok = _verify_json_object_keys_exact(keys)
			col_count = min(len(keys), store.EXPORT_SCALAR_COL_COUNT)
		}
		return _Export_Audit {
			ok = schema_ok,
			row_count = len(arr),
			col_count = col_count,
			schema_exact = schema_ok,
			samples_roundtrip_ok = true,
			detail = "json verified",
		}

	case .Jsonl:
		raw, r_err := os.read_entire_file(path, context.allocator)
		if r_err != nil {
			return _Export_Audit{detail = "jsonl read failed"}
		}
		defer delete(raw)
		lines := strings.split_lines(string(raw), context.temp_allocator)
		row_count := 0
		schema_ok := true
		col_count := store.EXPORT_SCALAR_COL_COUNT
		for line in lines {
			trimmed := strings.trim_space(line)
			if trimmed == "" {
				continue
			}
			parsed, p_err := json.parse(transmute([]u8)trimmed, allocator = context.allocator)
			if p_err != .None {
				schema_ok = false
				break
			}
			_, is_obj := parsed.(json.Object)
			json.destroy_value(parsed, context.allocator)
			if !is_obj {
				schema_ok = false
				break
			}
			if row_count == 0 {
				keys := _extract_first_json_object_keys(trimmed, context.allocator)
				schema_ok = _verify_json_object_keys_exact(keys)
				col_count = min(len(keys), store.EXPORT_SCALAR_COL_COUNT)
				for k in keys {
					delete(k)
				}
				delete(keys)
			}
			row_count += 1
		}
		return _Export_Audit {
			ok = schema_ok,
			row_count = row_count,
			col_count = col_count,
			schema_exact = schema_ok,
			samples_roundtrip_ok = true,
			detail = "jsonl verified",
		}

	case .Markdown:
		raw, r_err := os.read_entire_file(path, context.allocator)
		if r_err != nil {
			return _Export_Audit{detail = "markdown read failed"}
		}
		defer delete(raw)
		lines := strings.split_lines(string(raw), context.temp_allocator)
		if len(lines) < 2 {
			return _Export_Audit{detail = "markdown missing table header"}
		}
		schema_ok :=
			strings.has_prefix(lines[0], "| Benchmark |") && strings.has_prefix(lines[1], "| ---")
		rows := 0
		for li in 2 ..< len(lines) {
			if strings.has_prefix(lines[li], "| `") {
				rows += 1
			}
		}
		hdr_cols := 0
		for p in strings.split(lines[0], "|", context.temp_allocator) {
			if strings.trim_space(p) != "" {
				hdr_cols += 1
			}
		}
		return _Export_Audit {
			ok = schema_ok,
			row_count = rows,
			col_count = hdr_cols,
			schema_exact = schema_ok,
			samples_roundtrip_ok = true,
			detail = "markdown verified",
		}
	}
	return _Export_Audit{detail = "unknown format"}
}

@(private = "file")
_find_repo_root_upward :: proc(start_dir: string, allocator: runtime.Allocator) -> (string, bool) {
	if start_dir == "" {
		return "", false
	}
	cur := start_dir
	for cur != "" {
		hugi_file, _ := filepath.join({cur, "hugi", "hugi.odin"}, context.temp_allocator)
		obench_dir, _ := filepath.join({cur, "deps", "obench", "obench"}, context.temp_allocator)
		if os.exists(hugi_file) && os.is_dir(obench_dir) {
			abs_root, abs_err := os.get_absolute_path(cur, allocator)
			if abs_err == nil && abs_root != "" {
				return abs_root, true
			}
			return strings.clone(cur, allocator), true
		}
		parent := os.dir(cur)
		if parent == cur || parent == "." || parent == "" {
			break
		}
		cur = parent
	}
	return "", false
}

@(private)
_driver_locate_repo_root :: proc(allocator := context.allocator) -> (path: string, ok: bool) {
	if cwd, c_err := os.get_working_directory(context.temp_allocator); c_err == nil && cwd != "" {
		if found, f_ok := _find_repo_root_upward(cwd, allocator); f_ok {
			return found, true
		}
	}
	if exe_dir, e_err := os.get_executable_directory(context.temp_allocator);
	   e_err == nil && exe_dir != "" {
		if found, f_ok := _find_repo_root_upward(exe_dir, allocator); f_ok {
			return found, true
		}
	}
	return "", false
}

@(private = "file")
_find_cli_bin_upward :: proc(start_dir: string, allocator: runtime.Allocator) -> (string, bool) {
	repo_root, root_ok := _find_repo_root_upward(start_dir, context.temp_allocator)
	if !root_ok {
		return "", false
	}
	bin_name := "hugi"
	when ODIN_OS == .Windows {
		bin_name = "hugi.exe"
	}
	candidate, _ := filepath.join({repo_root, "bin", bin_name}, context.temp_allocator)
	if !os.exists(candidate) {
		return "", false
	}
	abs_bin, abs_err := os.get_absolute_path(candidate, allocator)
	if abs_err == nil && abs_bin != "" {
		return abs_bin, true
	}
	return strings.clone(candidate, allocator), true
}

@(private)
_driver_write_cli_bench_package :: proc(
	pkg_dir, repo_root: string,
	work_iters: int,
	violate_zero_alloc: bool,
) -> bool {
	work_dir := os.dir(pkg_dir)
	if work_dir == "" || work_dir == "." || os.make_directory_all(pkg_dir) != nil {
		return false
	}
	escaped_root, _ := strings.replace_all(repo_root, "\\", "\\\\", context.temp_allocator)
	escaped_root, _ = strings.replace_all(escaped_root, "\"", "\\\"", context.temp_allocator)
	ols_path, j_err := filepath.join({work_dir, "ols.json"}, context.temp_allocator)
	if j_err != nil {
		return false
	}
	ols_src := fmt.aprintf(
		"{{\n\t\"collections\": [\n\t\t{{\"name\": \"repo\", \"path\": \"%s\"}}\n\t]\n}}\n",
		escaped_root,
		allocator = context.temp_allocator,
	)
	if os.write_entire_file(ols_path, transmute([]u8)ols_src) != nil {
		return false
	}

	main_path, m_err := filepath.join({pkg_dir, "main.odin"}, context.temp_allocator)
	if m_err != nil {
		return false
	}
	main_src := fmt.aprintf(
		`package cli_spec_bench

import "core:os"
import hugi "repo:hugi"

main :: proc() {{
	cfg := hugi.default_suite_config()
	cfg.obench_cfg.sample_count = 8
	cfg.obench_cfg.warmup_time = 0
	cfg.obench_cfg.fixed_batch_size = 1
	s := hugi.suite_create("cli_spec_bench", cfg)

	hugi.group_pipeline(&s, "pipe", proc(p: ^hugi.Pipeline) {{
		ph := hugi.scoped_phase(p, "work", ops = 1, zero_alloc = true)
		_ = ph
		acc := u64(0x9e3779b97f4a7c15)
		when %v {{
			buf := make([]u8, 64)
			buf[0] = 1
			acc ~= u64(buf[0])
			delete(buf)
		}} else {{
			for i in 0 ..< %d {{
				acc = (acc ~ u64(i)) * 1099511628211
			}}
		}}
		_ = hugi.black_box(acc)
	}})

	ok := hugi.suite_run(&s)
	hugi.suite_destroy(&s)
	if !ok {{
		os.exit(1)
	}}
}}
`,
		violate_zero_alloc,
		max(work_iters, 1),
		allocator = context.temp_allocator,
	)
	return os.write_entire_file(main_path, transmute([]u8)main_src) == nil
}

@(private)
_driver_locate_cli_binary :: proc(allocator := context.allocator) -> (path: string, ok: bool) {
	if env_bin := os.get_env("HUGI_BIN", context.temp_allocator);
	   env_bin != "" && os.exists(env_bin) {
		abs_bin, abs_err := os.get_absolute_path(env_bin, allocator)
		if abs_err == nil && abs_bin != "" {
			return abs_bin, true
		}
		return strings.clone(env_bin, allocator), true
	}
	if cwd, c_err := os.get_working_directory(context.temp_allocator); c_err == nil && cwd != "" {
		if found, f_ok := _find_cli_bin_upward(cwd, allocator); f_ok {
			return found, true
		}
	}
	if exe_dir, e_err := os.get_executable_directory(context.temp_allocator);
	   e_err == nil && exe_dir != "" {
		if found, f_ok := _find_cli_bin_upward(exe_dir, allocator); f_ok {
			return found, true
		}
	}
	return "", false
}

@(private)
_driver_exec_cli :: proc(
	bin_path, work_dir: string,
	args: []string,
	allocator := context.allocator,
) -> _CLI_Result {
	cmd := make([dynamic]string, 0, 1 + len(args), context.temp_allocator)
	append(&cmd, bin_path)
	for a in args {
		append(&cmd, a)
	}
	state, out_bytes, err_bytes, exec_err := os.process_exec(
		os.Process_Desc{working_dir = work_dir, command = cmd[:]},
		allocator,
	)
	if exec_err != nil {
		if out_bytes != nil {
			delete(out_bytes, allocator)
		}
		if err_bytes != nil {
			delete(err_bytes, allocator)
		}
		return _CLI_Result{started = false}
	}
	return _CLI_Result {
		started = true,
		exit_code = state.exit_code,
		stdout = string(out_bytes),
		stderr = string(err_bytes),
	}
}
