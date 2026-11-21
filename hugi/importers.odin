package hugi

import obench "../deps/obench/obench"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"

@(private = "file", require_results)
_obench_doc_run_env :: proc(doc: obench.Export_Document, allocator: runtime.Allocator) -> Run_Env {
	has_v6_env :=
		doc.machine.cpu != "" ||
		doc.machine.governor != "" ||
		doc.machine.boost != "" ||
		doc.build.microarch != "" ||
		doc.build.bounds_checks != ""
	if !has_v6_env {
		return {}
	}
	boost: i8 = 0
	if doc.machine.boost == "on" {
		boost = 1
	} else if doc.machine.boost == "off" {
		boost = -1
	}
	build_flags := ""
	if doc.optimization != "" || doc.build.microarch != "" || doc.build.bounds_checks != "" {
		parts := make([dynamic]string, context.temp_allocator)
		if doc.optimization != "" {
			append(
				&parts,
				fmt.tprintf("-o:%s", strings.to_lower(doc.optimization, context.temp_allocator)),
			)
		}
		if doc.build.microarch != "" {
			append(&parts, fmt.tprintf("-microarch:%s", doc.build.microarch))
		}
		if doc.build.bounds_checks == "off" {
			append(&parts, "-no-bounds-check")
		}
		if len(parts) > 0 {
			build_flags = strings.join(parts[:], " ", allocator)
		}
	}
	return Run_Env {
		cpu_model = strings.clone(doc.machine.cpu, allocator),
		governor = strings.clone(doc.machine.governor, allocator),
		boost_state = boost,
		build_flags = build_flags,
		runtime_version = doc.odin_version != "" ? strings.clone(doc.odin_version, allocator) : "",
	}
}

@(private)
_append_counter_metric :: proc(
	metrics: ^[dynamic]Metric,
	unit: string,
	value: f64,
	allocator: runtime.Allocator,
	allow_zero := false,
) {
	valid := (value >= 0) if allow_zero else (value > 0)
	if !valid || math.is_inf(value, 0) || len(metrics^) >= MAX_METRICS {
		return
	}
	for m in metrics^ {
		if m.unit == unit {
			return
		}
	}
	v := 0.0 if value == 0 else value
	append(metrics, Metric{unit = strings.clone(unit, allocator), value = v})
}

/*
Converts an `obench` JSON report (`Export_Document`) into one `Run_Packet` per suite.
*/
@(require_results)
read_obench_json_packets :: proc(
	path: string,
	lang_override := "",
	commit_override := "",
	run_id_override := "",
	allocator := context.allocator,
) -> (
	packets: []Run_Packet,
	ok: bool,
) {
	doc, err := obench.read_json_report(path, context.temp_allocator)
	if err != nil {
		return nil, false
	}

	lang := lang_override != "" ? lang_override : "odin"
	commit := commit_override
	if commit == "" && doc.git.commit != "" {
		commit = len(doc.git.commit) > 12 ? doc.git.commit[:12] : doc.git.commit
	}
	if commit == "" {
		commit = resolve_git_commit(".", context.temp_allocator)
	}
	base_run_id := run_id_override != "" ? run_id_override : default_run_id(context.temp_allocator)
	ts := i64(time.to_unix_nanoseconds(time.now())) / 1_000_000_000
	if doc.created_at != "" {
		if parsed, consumed := time.rfc3339_to_time_utc(doc.created_at); consumed > 0 {
			ts = i64(time.to_unix_nanoseconds(parsed)) / 1_000_000_000
		}
	}

	suite_order := make([dynamic]string, context.temp_allocator)
	by_suite := make(map[string]int, context.temp_allocator)
	pkts := make([dynamic]Run_Packet, allocator)

	for &e in doc.benchmarks {
		s_name := e.suite_name != "" ? e.suite_name : doc.suite_name
		if s_name == "" {
			s_name = "obench"
		}
		pkt_idx, seen := by_suite[s_name]
		if !seen {
			pkt_idx = len(pkts)
			by_suite[s_name] = pkt_idx
			append(&suite_order, s_name)
			rid := base_run_id
			if len(suite_order) > 1 {
				rid = fmt.tprintf("%s-%d", base_run_id, pkt_idx)
			}
			append(
				&pkts,
				Run_Packet {
					suite_name = strings.clone(s_name, allocator),
					lang = strings.clone(lang, allocator),
					commit = strings.clone(commit, allocator),
					run_id = strings.clone(rid, allocator),
					os = strings.clone(doc.os, allocator),
					arch = strings.clone(doc.arch, allocator),
					optimization = strings.clone(doc.optimization, allocator),
					odin_version = strings.clone(doc.odin_version, allocator),
					timestamp_unix = ts,
					env = _obench_doc_run_env(doc, allocator),
					records = make([dynamic]Record, allocator),
				},
			)
		}

		ops := u64(max(e.batch_size, 1))
		s_cnt := len(e.samples_batch_ns) > 0 ? len(e.samples_batch_ns) : len(e.samples_ns)
		r := Record {
			rank               = len(pkts[pkt_idx].records) + 1,
			group_name         = strings.clone(e.group_name, allocator),
			name               = strings.clone(e.name, allocator),
			full_name          = strings.clone(e.full_name, allocator),
			param              = e.param,
			has_param          = e.has_param,
			threads            = e.threads,
			has_threads        = e.has_threads,
			ops_per_sample     = ops,
			samples            = e.samples,
			min_fs             = ns_f64_to_fs(e.min_ns),
			p50_fs             = ns_f64_to_fs(e.p50_ns),
			p95_fs             = ns_f64_to_fs(e.p95_ns),
			p99_fs             = ns_f64_to_fs(e.p99_ns),
			max_fs             = ns_f64_to_fs(e.max_ns),
			mean_fs            = ns_f64_to_fs(e.mean_ns),
			std_dev_fs         = ns_f64_to_fs(e.std_dev_ns),
			ci95_fs            = ns_f64_to_fs(e.ci95_ns),
			mad_fs             = ns_f64_to_fs(e.mad_ns),
			median_cycles      = e.median_cycles,
			mb_per_sec         = e.mb_per_sec,
			items_per_sec      = e.items_per_sec,
			allocs_per_op      = e.allocs_per_op,
			resizes_per_op     = e.resizes_per_op,
			alloc_bytes_per_op = e.alloc_bytes_per_op,
			temp_allocs_per_op = e.temp_allocs_per_op,
			temp_bytes_per_op  = e.temp_bytes_per_op,
			peak_heap_bytes    = e.peak_heap_bytes,
			zero_alloc_failed  = e.zero_alloc_failed,
			error              = strings.clone(e.error, allocator),
			metrics            = make([dynamic]Metric, allocator),
			samples_batch_ns   = make([dynamic]u64, s_cnt, allocator),
		}
		if len(e.samples_batch_ns) > 0 {
			copy(r.samples_batch_ns[:], e.samples_batch_ns)
		} else {
			for s, si in e.samples_ns {
				r.samples_batch_ns[si] = ns_f64_to_batch_ns(s, ops)
			}
		}
		for m in e.custom_metrics {
			if len(r.metrics) >= MAX_METRICS {
				break
			}
			append(&r.metrics, Metric{unit = strings.clone(m.unit, allocator), value = m.value})
		}
		has_counters := e.instructions > 0 || e.cycles > 0
		_append_counter_metric(&r.metrics, "instructions/op", e.instructions, allocator)
		_append_counter_metric(&r.metrics, "cycles/op", e.cycles, allocator)
		_append_counter_metric(
			&r.metrics,
			"branch_misses/op",
			e.branch_misses,
			allocator,
			allow_zero = has_counters,
		)
		_append_counter_metric(
			&r.metrics,
			"cache_misses/op",
			e.cache_misses,
			allocator,
			allow_zero = has_counters,
		)
		if r.mean_fs > 0 {
			r.cv_pct = (f64(r.std_dev_fs) / f64(r.mean_fs)) * 100.0
		}
		if len(r.samples_batch_ns) > 0 {
			recompute_record_stats_from_samples(&r)
			refresh_record_throughput(&r, overwrite = false)
		}
		append(&pkts[pkt_idx].records, r)
	}

	return pkts[:], true
}

@(private = "file")
_Jsonl_Row :: struct {
	rank:                int `json:"rank"`,
	group:               string `json:"group"`,
	lang:                string `json:"lang"`,
	commit:              string `json:"commit"`,
	run_id:              string `json:"run_id"`,
	name:                string `json:"name"`,
	ops:                 u64 `json:"ops"`,
	runs:                int `json:"runs"`,
	warmup:              int `json:"warmup"`,
	total_ms:            f64 `json:"total_ms"`,
	ns_per_op:           f64 `json:"ns_per_op"`,
	mean_ns:             f64 `json:"mean_ns"`,
	median_ns:           f64 `json:"median_ns"`,
	stddev_ns:           f64 `json:"stddev_ns"`,
	cv_pct:              f64 `json:"cv_pct"`,
	min_ns:              f64 `json:"min_ns"`,
	max_ns:              f64 `json:"max_ns"`,
	iqr_ns:              f64 `json:"iqr_ns"`,
	p95_ns:              f64 `json:"p95_ns"`,
	p99_ns:              f64 `json:"p99_ns"`,
	ops_per_sec:         f64 `json:"ops_per_sec"`,
	mb_per_sec:          f64 `json:"mb_per_sec"`,
	gb_per_sec:          f64 `json:"gb_per_sec"`,
	bytes_per_op:        u64 `json:"bytes_per_op"`,
	bytes_row:           u64 `json:"bytes_row"`,
	bytes_used:          u64 `json:"bytes_used"`,
	allocs_per_run:      u64 `json:"allocs_per_run"`,
	resizes_per_run:     u64 `json:"resizes_per_run"`,
	alloc_bytes_per_run: u64 `json:"alloc_bytes_per_run"`,
	peak_live_bytes:     i64 `json:"peak_live_bytes"`,
	pool_hits:           u64 `json:"pool_hits"`,
	pool_misses:         u64 `json:"pool_misses"`,
	samples_ns:          []f64 `json:"samples_ns"`,
	samples_batch_ns:    []u64 `json:"samples_batch_ns"`,
}

/*
Parses legacy `xitdb` / `skadi` / `duckdb` JSONL files into chronological `Run_Packet`s
grouped by `(commit, lang, run_id)`.
*/
@(require_results)
read_jsonl_packets :: proc(
	path: string,
	lang_override := "",
	commit_override := "",
	run_id_override := "",
	allocator := context.allocator,
) -> (
	packets: []Run_Packet,
	ok: bool,
) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return nil, false
	}

	pkts := make([dynamic]Run_Packet, allocator)
	key_to_idx := make(map[string]int, context.temp_allocator)
	now_ts := i64(time.to_unix_nanoseconds(time.now())) / 1_000_000_000

	text := string(data)
	for raw_line in strings.split_lines_iterator(&text) {
		line := strings.trim_space(raw_line)
		if len(line) == 0 || !strings.has_prefix(line, "{") {
			continue
		}
		row: _Jsonl_Row
		if json.unmarshal(transmute([]u8)line, &row, allocator = context.temp_allocator) != nil {
			continue
		}
		if row.name == "" {
			continue
		}

		lang := lang_override != "" ? lang_override : (row.lang != "" ? row.lang : "odin")
		commit :=
			commit_override != "" ? commit_override : (row.commit != "" ? row.commit : "unknown")
		rid := run_id_override
		if rid == "" {
			rid = row.run_id != "" ? row.run_id : fmt.tprintf("jsonl-%s-%s", commit, lang)
		}

		// Key packets by `(commit, lang, run_id)` so separate invocations stay distinct.
		pkt_key := fmt.tprintf("%s\x00%s\x00%s", commit, lang, rid)
		pkt_idx, found := key_to_idx[pkt_key]
		if !found {
			pkt_idx = len(pkts)
			key_to_idx[pkt_key] = pkt_idx
			append(
				&pkts,
				Run_Packet {
					suite_name = strings.clone("jsonl_import", allocator),
					lang = strings.clone(lang, allocator),
					commit = strings.clone(commit, allocator),
					run_id = strings.clone(rid, allocator),
					os = strings.clone(ODIN_OS_STRING, allocator),
					arch = strings.clone(ODIN_ARCH_STRING, allocator),
					optimization = strings.clone("Speed", allocator),
					odin_version = strings.clone("", allocator),
					timestamp_unix = now_ts,
					records = make([dynamic]Record, allocator),
				},
			)
		}

		eff_ops := max(row.ops, 1)
		if row.ops == 0 && len(row.samples_ns) > 0 {
			has_sub_ns := false
			has_sub_ps := false
			for s in row.samples_ns {
				fs := ns_f64_to_fs(s)
				if fs % FS_PER_NS != 0 {
					has_sub_ns = true
				}
				if fs % 1_000 != 0 {
					has_sub_ps = true
				}
			}
			if has_sub_ps {
				eff_ops = 1_000_000
			} else if has_sub_ns {
				eff_ops = 1_000
			}
		}

		ops_f := f64(max(row.ops, 1))
		bpo := row.bytes_per_op > 0 ? row.bytes_per_op : row.bytes_row
		mb_s := row.gb_per_sec > 0 ? row.gb_per_sec * 1024.0 : row.mb_per_sec
		med := row.median_ns > 0 ? row.median_ns : row.ns_per_op
		ops_s := row.ops_per_sec
		if ops_s <= 0 && med > 0 {
			ops_s = 1_000_000_000.0 / med
		}
		med_fs := ns_f64_to_fs(med)
		s_cnt := len(row.samples_batch_ns) > 0 ? len(row.samples_batch_ns) : len(row.samples_ns)

		r := Record {
			rank               = row.rank > 0 ? row.rank : len(pkts[pkt_idx].records) + 1,
			group_name         = strings.clone(row.group, allocator),
			name               = strings.clone(row.name, allocator),
			full_name          = strings.clone(row.name, allocator),
			ops_per_sample     = eff_ops,
			samples            = row.runs > 0 ? row.runs : s_cnt,
			warmup             = row.warmup,
			min_fs             = ns_f64_to_fs(row.min_ns),
			p50_fs             = med_fs,
			p95_fs             = ns_f64_to_fs(row.p95_ns),
			p99_fs             = ns_f64_to_fs(row.p99_ns),
			max_fs             = ns_f64_to_fs(row.max_ns),
			mean_fs            = row.mean_ns > 0 ? ns_f64_to_fs(row.mean_ns) : med_fs,
			std_dev_fs         = ns_f64_to_fs(row.stddev_ns),
			cv_pct             = row.cv_pct,
			iqr_fs             = ns_f64_to_fs(row.iqr_ns),
			bytes_per_op       = bpo,
			mb_per_sec         = mb_s,
			items_per_sec      = ops_s,
			footprint_bytes    = row.bytes_used,
			allocs_per_op      = f64(row.allocs_per_run) / ops_f,
			resizes_per_op     = f64(row.resizes_per_run) / ops_f,
			alloc_bytes_per_op = f64(row.alloc_bytes_per_run) / ops_f,
			peak_heap_bytes    = row.peak_live_bytes,
			error              = strings.clone("", allocator),
			metrics            = make([dynamic]Metric, allocator),
			samples_batch_ns   = make([dynamic]u64, s_cnt, allocator),
		}
		if len(row.samples_batch_ns) > 0 {
			copy(r.samples_batch_ns[:], row.samples_batch_ns)
			recompute_record_stats_from_samples(&r)
			refresh_record_throughput(&r, overwrite = false)
		} else if len(row.samples_ns) > 0 {
			for s, si in row.samples_ns {
				r.samples_batch_ns[si] = ns_f64_to_batch_ns(s, eff_ops)
			}
			recompute_record_stats_from_samples(&r)
			refresh_record_throughput(&r, overwrite = false)
		} else if med > 0 {
			if r.samples == 0 {
				r.samples = 1
			}
			if r.cv_pct == 0 && r.mean_fs > 0 && r.std_dev_fs > 0 {
				r.cv_pct = (f64(r.std_dev_fs) / f64(r.mean_fs)) * 100.0
			}
			refresh_record_throughput(&r, overwrite = false)
		}
		if row.pool_hits > 0 || row.pool_misses > 0 {
			append(
				&r.metrics,
				Metric{unit = strings.clone("pool_hits", allocator), value = f64(row.pool_hits)},
			)
			append(
				&r.metrics,
				Metric {
					unit = strings.clone("pool_misses", allocator),
					value = f64(row.pool_misses),
				},
			)
		}
		append(&pkts[pkt_idx].records, r)
	}

	return pkts[:], len(pkts) > 0
}
