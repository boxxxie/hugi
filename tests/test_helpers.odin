package hugi_tests

import hugi "../hugi"
import "core:fmt"
import "core:strings"

@(private)
_make_packet :: proc(
	commit, lang, run_id, suite_name: string,
	names: []string,
	medians: []f64,
	footprints: []u64,
	selective := false,
	samples_per_rec := 16,
	spread_ns := 1.0,
) -> hugi.Run_Packet {
	pkt := hugi.Run_Packet {
		suite_name     = strings.clone(suite_name),
		lang           = strings.clone(lang),
		commit         = strings.clone(commit),
		run_id         = strings.clone(run_id),
		os             = strings.clone("linux"),
		arch           = strings.clone("amd64"),
		optimization   = strings.clone("Speed"),
		odin_version   = strings.clone("test"),
		timestamp_unix = 1700000000,
		selective      = selective,
		records        = make([dynamic]hugi.Record, 0, len(names)),
	}

	for name, i in names {
		med := medians[i]
		foot := footprints[i]
		ops := u64(100)
		samples := make([dynamic]u64, samples_per_rec)
		for s in 0 ..< samples_per_rec {
			offset := (f64(s) - f64(samples_per_rec - 1) * 0.5) * spread_ns
			samples[s] = hugi.ns_f64_to_batch_ns(max(med + offset, 1.0), ops)
		}

		r := hugi.Record {
			rank               = i + 1,
			group_name         = strings.clone("core"),
			name               = strings.clone(name),
			full_name          = strings.clone(fmt.tprintf("core::%s", name)),
			ops_per_sample     = ops,
			samples            = samples_per_rec,
			bytes_per_op       = 64,
			footprint_bytes    = foot,
			allocs_per_op      = 0,
			alloc_bytes_per_op = 0,
			samples_batch_ns   = samples,
			metrics            = make([dynamic]hugi.Metric),
		}
		hugi.recompute_record_stats_from_samples(&r)
		if r.p50_fs > 0 {
			r.items_per_sec = hugi.FS_PER_SEC_F64 / f64(r.p50_fs)
			r.mb_per_sec = (f64(r.bytes_per_op) * r.items_per_sec) / (1024.0 * 1024.0)
		}
		append(&pkt.records, r)
	}
	return pkt
}

@(private)
_make_store_test_packet :: proc(run_id, commit: string, base_ns: f64) -> hugi.Run_Packet {
	pkt := hugi.Run_Packet {
		run_id         = strings.clone(run_id, context.allocator),
		commit         = strings.clone(commit, context.allocator),
		timestamp_unix = 1770000000,
		lang           = strings.clone("odin", context.allocator),
		suite_name     = strings.clone("kv_bench", context.allocator),
		os             = strings.clone("linux", context.allocator),
		arch           = strings.clone("amd64", context.allocator),
		optimization   = strings.clone("-o:speed", context.allocator),
		odin_version   = strings.clone("dev-2026", context.allocator),
		records        = make([dynamic]hugi.Record, context.allocator),
	}

	r1 := hugi.Record {
		rank             = 1,
		name             = strings.clone("get", context.allocator),
		group_name       = strings.clone("core", context.allocator),
		full_name        = strings.clone("core::get", context.allocator),
		ops_per_sample   = 100,
		bytes_per_op     = 32,
		items_per_op     = 2,
		footprint_bytes  = 512,
		peak_heap_bytes  = 1024,
		samples_batch_ns = make([dynamic]u64, context.allocator),
		metrics          = make([dynamic]hugi.Metric, context.allocator),
	}
	append(
		&r1.samples_batch_ns,
		hugi.ns_f64_to_batch_ns(base_ns, 100),
		hugi.ns_f64_to_batch_ns(base_ns + 0.4, 100),
		hugi.ns_f64_to_batch_ns(base_ns - 0.2, 100),
		hugi.ns_f64_to_batch_ns(base_ns + 0.1, 100),
		hugi.ns_f64_to_batch_ns(base_ns + 0.5, 100),
	)
	hugi.recompute_record_stats_from_samples(&r1)
	if r1.p50_fs > 0 {
		ops_s := hugi.FS_PER_SEC_F64 / f64(r1.p50_fs)
		r1.items_per_sec = f64(r1.items_per_op) * ops_s
		r1.mb_per_sec = (f64(r1.bytes_per_op) * ops_s) / (1024.0 * 1024.0)
	}
	append(&pkt.records, r1)

	r2 := hugi.Record {
		rank             = 10,
		name             = strings.clone("put", context.allocator),
		group_name       = strings.clone("core", context.allocator),
		full_name        = strings.clone("special_put", context.allocator),
		param            = 64,
		has_param        = true,
		threads          = 2,
		has_threads      = true,
		ops_per_sample   = 10,
		samples_batch_ns = make([dynamic]u64, context.allocator),
		metrics          = make([dynamic]hugi.Metric, context.allocator),
	}
	append(
		&r2.samples_batch_ns,
		hugi.ns_f64_to_batch_ns(base_ns * 2.0, 10),
		hugi.ns_f64_to_batch_ns(base_ns * 2.0 + 1.0, 10),
		hugi.ns_f64_to_batch_ns(base_ns * 2.0 - 0.5, 10),
	)
	hugi.recompute_record_stats_from_samples(&r2)
	if r2.p50_fs > 0 {
		r2.items_per_sec = hugi.FS_PER_SEC_F64 / f64(r2.p50_fs)
	}
	append(&r2.metrics, hugi.Metric{unit = strings.clone("%", context.allocator), value = 99.5})
	append(&pkt.records, r2)

	r3 := hugi.Record {
		rank              = 3,
		name              = strings.clone("scan", context.allocator),
		group_name        = strings.clone("core", context.allocator),
		full_name         = strings.clone("scan", context.allocator),
		zero_alloc_failed = true,
		error             = strings.clone("timeout", context.allocator),
		samples_batch_ns  = make([dynamic]u64, context.allocator),
		metrics           = make([dynamic]hugi.Metric, context.allocator),
	}
	append(&pkt.records, r3)

	return pkt
}
