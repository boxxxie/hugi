package hugi_tests

import hugi "../hugi"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_packet_binary_roundtrip :: proc(t: ^testing.T) {
	pkt := _make_packet(
		"abc1234",
		"odin",
		"run-001",
		"suite_alpha",
		[]string{"read", "write"},
		[]f64{120.5, 450.25},
		[]u64{4096, 8192},
		selective = true,
	)
	defer hugi.packet_destroy(&pkt)

	append(&pkt.records[0].metrics, hugi.Metric{unit = strings.clone("hit%"), value = 99.5})

	encoded := hugi.encode_packet_bytes(pkt, true)
	defer delete(encoded)

	decoded, ok := hugi.decode_packet_bytes(encoded)
	defer hugi.packet_destroy(&decoded)
	testing.expect(t, ok, "packet decode should succeed")
	testing.expect_value(t, decoded.commit, "abc1234")
	testing.expect_value(t, decoded.lang, "odin")
	testing.expect_value(t, decoded.selective, true)
	testing.expect_value(t, len(decoded.records), 2)
	testing.expect_value(t, decoded.records[0].footprint_bytes, u64(4096))
	testing.expect_value(t, len(decoded.records[0].metrics), 1)
	testing.expect_value(t, decoded.records[0].metrics[0].unit, "hit%")
	testing.expect_value(t, len(decoded.records[1].samples_batch_ns), 16)
	testing.expect_value(
		t,
		decoded.records[0].samples_batch_ns[3],
		pkt.records[0].samples_batch_ns[3],
	)

	// Record binary round-trip (OBRC\x02).
	rec_bytes := hugi.encode_record_bytes(pkt.records[0], true)
	defer delete(rec_bytes)
	rec_dec, rec_ok := hugi.decode_record_bytes(rec_bytes)
	defer hugi.record_destroy(&rec_dec)
	testing.expect(t, rec_ok, "OBRC v2 record decode should succeed")
	testing.expect_value(t, rec_dec.full_name, pkt.records[0].full_name)
	testing.expect_value(t, len(rec_dec.samples_batch_ns), 16)

	// Removed v1 packet and record headers must be rejected.
	for bad_pkt in ([2][8]u8{{'H', 'P', 'K', 'T', 1, 0, 0, 0}, {'O', 'B', 'P', 'K', 1, 0, 0, 0}}) {
		buf := make([]u8, len(encoded))
		copy(buf, encoded)
		hdr := bad_pkt
		copy(buf[:8], hdr[:])
		bad_dec, bad_ok := hugi.decode_packet_bytes(buf)
		testing.expect(t, !bad_ok, "v1 packet magic must be rejected")
		hugi.packet_destroy(&bad_dec)
		delete(buf)
	}
	{
		rbuf := make([]u8, len(rec_bytes))
		copy(rbuf, rec_bytes)
		copy(rbuf[:8], transmute([]u8)string("OBRC\x01\x00\x00\x00"))
		bad_rec, bad_rok := hugi.decode_record_bytes(rbuf)
		testing.expect(t, !bad_rok, "legacy OBRC v1 magic must be rejected")
		hugi.record_destroy(&bad_rec)
		delete(rbuf)
	}
}

@(test)
test_jsonl_and_obench_json_wire_importers :: proc(t: ^testing.T) {
	tmp, mk_err := os.make_directory_temp("", "hugi-pkt-import-*", context.allocator)
	testing.expectf(t, mk_err == nil && tmp != "", "create temp import dir: %v", mk_err)
	if mk_err != nil || tmp == "" {
		return
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	// 1. Multi-packet .jsonl with blank/malformed lines + grouping + overrides.
	jsonl_in := strings.concatenate({tmp, "/multi.jsonl"}, context.temp_allocator)
	jsonl_data :=
		"\n" +
		`{"rank":1,"group":"kv","lang":"odin","commit":"imp001","run_id":"jr-1","name":"kv::get","ops":100,"runs":3,"warmup":1,"median_ns":42.5,"samples_ns":[42.0,42.5,43.0],"bytes_row":64,"mb_per_sec":1435.0,"bytes_used":512}` +
		"\n" +
		"NOT_VALID_JSON_LINE\n" +
		`{"rank":2,"group":"kv","lang":"odin","commit":"imp001","run_id":"jr-1","name":"kv::put","ops":100,"runs":3,"warmup":1,"median_ns":84.0,"samples_ns":[83.0,84.0,85.0],"bytes_used":1024}` +
		"\n" +
		`{"rank":1,"group":"kv","lang":"zig","commit":"imp001","run_id":"jr-z1","name":"kv::get","ops":100,"runs":3,"warmup":1,"median_ns":60.0,"samples_ns":[59.0,60.0,61.0],"gb_per_sec":2.5,"bytes_used":512}` +
		"\n"
	testing.expect(
		t,
		os.write_entire_file(jsonl_in, transmute([]u8)jsonl_data) == nil,
		"write sample jsonl",
	)

	jpkts, j_ok := hugi.read_jsonl_packets(jsonl_in)
	testing.expect(t, j_ok, "read_jsonl_packets should succeed")
	if j_ok {
		testing.expect_value(t, len(jpkts), 2)
		if len(jpkts) == 2 {
			testing.expect_value(t, jpkts[0].commit, "imp001")
			testing.expect_value(t, jpkts[0].lang, "odin")
			testing.expect_value(t, jpkts[0].run_id, "jr-1")
			testing.expect_value(t, len(jpkts[0].records), 2)
			testing.expect_value(t, jpkts[0].records[0].samples_batch_ns[1], u64(4250))
			testing.expect_value(t, jpkts[0].records[0].bytes_per_op, u64(64))
			testing.expect_value(t, jpkts[0].records[0].mb_per_sec, 1435.0)

			testing.expect_value(t, jpkts[1].lang, "zig")
			testing.expect_value(t, jpkts[1].run_id, "jr-z1")
			testing.expect_value(t, len(jpkts[1].records), 1)
			testing.expect_value(t, jpkts[1].records[0].mb_per_sec, 2560.0)
		}
	}
	hugi.packets_destroy(jpkts)

	// Overrides force a shared lang/commit/run_id grouping.
	jpkts_ov, j_ov_ok := hugi.read_jsonl_packets(
		jsonl_in,
		lang_override = "rust",
		commit_override = "ovr999",
		run_id_override = "forced-run",
	)
	testing.expect(t, j_ov_ok, "read_jsonl_packets with overrides should succeed")
	if j_ov_ok {
		testing.expect_value(t, len(jpkts_ov), 1)
		if len(jpkts_ov) == 1 {
			testing.expect_value(t, jpkts_ov[0].lang, "rust")
			testing.expect_value(t, jpkts_ov[0].commit, "ovr999")
			testing.expect_value(t, jpkts_ov[0].run_id, "forced-run")
			testing.expect_value(t, len(jpkts_ov[0].records), 3)
		}
	}
	hugi.packets_destroy(jpkts_ov)

	// 2. obench JSON splitting across suite names + run_id suffixing.
	ojson_in := strings.concatenate({tmp, "/obench.json"}, context.temp_allocator)
	ojson_data := `{"format_version":3,"suite_name":"default_suite","os":"linux","arch":"amd64","optimization":"Speed","odin_version":"dev","benchmarks":[{"suite_name":"alpha","group_name":"math","name":"mul","full_name":"math::mul","samples":3,"batch_size":10,"min_ns":10.0,"p50_ns":10.1,"p95_ns":10.2,"p99_ns":10.2,"max_ns":10.2,"mean_ns":10.1,"samples_batch_ns":[100,101,102]},{"suite_name":"beta","group_name":"io","name":"copy","full_name":"io::copy","samples":3,"batch_size":10,"min_ns":20.0,"p50_ns":20.1,"p95_ns":20.2,"p99_ns":20.2,"max_ns":20.2,"mean_ns":20.1,"samples_batch_ns":[200,201,202]}]}`
	testing.expect(
		t,
		os.write_entire_file(ojson_in, transmute([]u8)ojson_data) == nil,
		"write sample obench json",
	)
	opkts, o_ok := hugi.read_obench_json_packets(
		ojson_in,
		lang_override = "odin",
		commit_override = "ob001",
		run_id_override = "ob-run",
	)
	testing.expect(t, o_ok, "read_obench_json_packets should succeed")
	if o_ok {
		testing.expect_value(t, len(opkts), 2)
		if len(opkts) == 2 {
			testing.expect_value(t, opkts[0].suite_name, "alpha")
			testing.expect_value(t, opkts[0].commit, "ob001")
			testing.expect_value(t, opkts[0].lang, "odin")
			testing.expect_value(t, opkts[0].run_id, "ob-run")
			testing.expect_value(t, opkts[0].records[0].samples_batch_ns[1], u64(101))

			testing.expect_value(t, opkts[1].suite_name, "beta")
			testing.expect_value(t, opkts[1].run_id, "ob-run-1")
			testing.expect_value(t, opkts[1].records[0].samples_batch_ns[1], u64(201))
		}
	}
	hugi.packets_destroy(opkts)
}

@(test)
test_suite_create_syncs_programmatic_name_filter_to_obench :: proc(t: ^testing.T) {
	cfg := hugi.default_suite_config()
	cfg.name_filter = "fnv1a"
	cfg.quiet = true

	s := hugi.suite_create("filter_sync", cfg)
	defer hugi.suite_destroy(&s)
	testing.expect_value(t, s.obench_suite.config.filter, "fnv1a")

	cfg_multi := hugi.default_suite_config()
	cfg_multi.name_filter = "fnv1a|crc32"
	cfg_multi.quiet = true

	s_multi := hugi.suite_create("filter_multi", cfg_multi)
	defer hugi.suite_destroy(&s_multi)
	testing.expect_value(t, s_multi.obench_suite.config.filter, "")

	// Overriding cfg.name_filter after obench_cfg.filter was populated must sync cleanly.
	cfg_ovr := hugi.default_suite_config()
	cfg_ovr.obench_cfg.filter = "stale_old"
	cfg_ovr.name_filter = "fnv1a"
	cfg_ovr.quiet = true

	s_ovr := hugi.suite_create("filter_override", cfg_ovr)
	defer hugi.suite_destroy(&s_ovr)
	testing.expect_value(t, s_ovr.obench_suite.config.filter, "fnv1a")

	cfg_ovr_multi := hugi.default_suite_config()
	cfg_ovr_multi.obench_cfg.filter = "stale_old"
	cfg_ovr_multi.name_filter = "fnv1a|crc32"
	cfg_ovr_multi.quiet = true

	s_ovr_multi := hugi.suite_create("filter_override_multi", cfg_ovr_multi)
	defer hugi.suite_destroy(&s_ovr_multi)
	testing.expect_value(t, s_ovr_multi.obench_suite.config.filter, "")
}

@(test)
test_packet_env_trailer_roundtrip_and_compat :: proc(t: ^testing.T) {
	// 1. Packet with full Run_Env round-trips via HENV trailer.
	pkt := _make_packet(
		"env001",
		"odin",
		"run-env-1",
		"env_suite",
		[]string{"op"},
		[]f64{50.0},
		[]u64{1024},
	)
	defer hugi.packet_destroy(&pkt)
	pkt.env = hugi.Run_Env {
		cpu_model       = strings.clone("AMD Ryzen 7 7735U"),
		governor        = strings.clone("performance"),
		scaling_max_khz = 2_701_000,
		cpuinfo_max_khz = 4_821_140,
		boost_state     = 1,
		build_flags     = strings.clone("-o:speed -microarch:native"),
		runtime_version = strings.clone("dev-2026-09"),
	}

	enc := hugi.encode_packet_bytes(pkt, true)
	defer delete(enc)

	dec, ok := hugi.decode_packet_bytes(enc)
	defer hugi.packet_destroy(&dec)
	testing.expect(t, ok, "packet with HENV trailer should decode")
	testing.expect_value(t, dec.env.cpu_model, "AMD Ryzen 7 7735U")
	testing.expect_value(t, dec.env.governor, "performance")
	testing.expect_value(t, dec.env.scaling_max_khz, u64(2_701_000))
	testing.expect_value(t, dec.env.cpuinfo_max_khz, u64(4_821_140))
	testing.expect_value(t, dec.env.boost_state, i8(1))
	testing.expect_value(t, dec.env.build_flags, "-o:speed -microarch:native")
	testing.expect_value(t, dec.env.runtime_version, "dev-2026-09")

	// 2. Packet without env emits no HENV trailer and decodes with empty env.
	pkt_plain := _make_packet(
		"env002",
		"odin",
		"run-plain-1",
		"env_suite",
		[]string{"op"},
		[]f64{50.0},
		[]u64{1024},
	)
	defer hugi.packet_destroy(&pkt_plain)
	enc_plain := hugi.encode_packet_bytes(pkt_plain, true)
	defer delete(enc_plain)
	testing.expect(
		t,
		!strings.contains(string(enc_plain), hugi.PACKET_ENV_TRAILER_MAGIC),
		"empty env must not emit HENV trailer",
	)
	dec_plain, ok_plain := hugi.decode_packet_bytes(enc_plain)
	defer hugi.packet_destroy(&dec_plain)
	testing.expect(t, ok_plain, "plain HPKT v2 without HENV must decode")
	testing.expect(t, hugi.run_env_is_empty(dec_plain.env), "plain env should remain empty")

	// 3. Truncated or malformed HENV trailer must be rejected without leaks.
	trunc := enc[:len(enc) - 3]
	bad_trunc, ok_trunc := hugi.decode_packet_bytes(trunc)
	defer hugi.packet_destroy(&bad_trunc)
	testing.expect(t, !ok_trunc, "truncated HENV trailer must be rejected")

	bad_magic := make([]u8, len(enc_plain) + 5)
	defer delete(bad_magic)
	copy(bad_magic, enc_plain)
	copy(bad_magic[len(enc_plain):], transmute([]u8)string("BAD!\x01"))
	bad_m, ok_m := hugi.decode_packet_bytes(bad_magic)
	defer hugi.packet_destroy(&bad_m)
	testing.expect(t, !ok_m, "unknown trailing bytes must be rejected")

	// 4. check_host_env reports clamped clock, non-performance governor, and boost disabled.
	bad_env := hugi.Run_Env {
		governor        = "powersave",
		scaling_max_khz = 2_701_000,
		cpuinfo_max_khz = 4_821_140,
		boost_state     = -1,
	}
	warns := hugi.check_host_env(bad_env)
	defer {
		for w in warns {
			delete(w)
		}
		delete(warns)
	}
	testing.expect_value(t, len(warns), 3)
}

@(test)
test_suite_destroy_idempotent_and_config_survives_temp_reset :: proc(t: ^testing.T) {
	cfg := hugi.default_suite_config()
	cfg.quiet = true
	cfg.runs = 2
	cfg.warmup = 0
	cfg.obench_cfg.sample_count = 3
	cfg.obench_cfg.warmup_time = 0
	cfg.obench_cfg.fixed_batch_size = 1

	noise := make([]u8, 256, context.temp_allocator)
	for &b in noise {
		b = 0xAA
	}
	free_all(context.temp_allocator)
	noise2 := make([]u8, 256, context.temp_allocator)
	for &b in noise2 {
		b = 0x55
	}

	s := hugi.suite_create("temp_and_destroy_test", cfg)
	testing.expect(t, s.config.commit != "", "suite_create must resolve commit on s.allocator")
	testing.expect(t, s.config.run_id != "", "suite_create must resolve run_id on s.allocator")

	hugi.bench(&s, "noop", proc(b: ^hugi.Bencher) {
		for hugi.step(b) {
			_ = make([]u8, 64, context.temp_allocator)
			free_all(context.temp_allocator)
			_ = hugi.black_box(1)
		}
	})
	hugi.group_pipeline(&s, "pipe", proc(p: ^hugi.Pipeline) {
		ph := hugi.phase_begin(p, "work", ops = 1, zero_alloc = true)
		_ = hugi.black_box(42)
		hugi.phase_end(ph)
	})

	testing.expect(t, hugi.suite_execute(&s), "suite_execute should succeed")
	testing.expect_value(t, len(s.last_packet.records), 2)

	hugi.suite_destroy(&s)
	hugi.suite_destroy(&s)
}

@(test)
test_nested_pipeline_phases_alloc_check :: proc(t: ^testing.T) {
	cfg := hugi.default_suite_config()
	cfg.quiet = true
	cfg.runs = 2
	cfg.warmup = 0

	s := hugi.suite_create("nested_phase_alloc_test", cfg)
	defer hugi.suite_destroy(&s)

	hugi.group_pipeline(&s, "nested", proc(p: ^hugi.Pipeline) {
		outer := hugi.phase_begin(p, "outer_allocs", ops = 1, zero_alloc = true)
		b1 := make([]u8, 64)
		_ = hugi.black_box(b1[0])
		delete(b1)

		inner := hugi.phase_begin(p, "inner_clean", ops = 1, zero_alloc = true)
		_ = hugi.black_box(7)
		hugi.phase_end(inner)

		b2 := make([]u8, 128)
		_ = hugi.black_box(b2[0])
		delete(b2)
		hugi.phase_end(outer)

		outer2 := hugi.phase_begin(p, "outer_propagates", ops = 1, zero_alloc = true)
		inner2 := hugi.phase_begin(p, "inner_allocs", ops = 1, zero_alloc = true)
		b3 := make([]u8, 96)
		_ = hugi.black_box(b3[0])
		delete(b3)
		hugi.phase_end(inner2)
		hugi.phase_end(outer2)
	})

	ok := hugi.suite_execute(&s)
	testing.expect(t, !ok, "outer zero_alloc violations should fail suite")
	testing.expect_value(t, len(s.last_packet.records), 4)
	if len(s.last_packet.records) == 4 {
		r_outer := s.last_packet.records[0]
		r_inner := s.last_packet.records[1]
		r_outer2 := s.last_packet.records[2]
		r_inner2 := s.last_packet.records[3]

		testing.expect_value(t, r_outer.name, "outer_allocs")
		testing.expect(t, r_outer.zero_alloc_failed, "outer_allocs must detect pre/post allocs")
		testing.expect_value(t, r_outer.allocs_per_op, 2.0)
		testing.expect_value(t, r_outer.alloc_bytes_per_op, 192.0)

		testing.expect_value(t, r_inner.name, "inner_clean")
		testing.expect(t, !r_inner.zero_alloc_failed, "inner_clean must remain clean")
		testing.expect_value(t, r_inner.allocs_per_op, 0.0)
		testing.expect_value(t, r_inner.alloc_bytes_per_op, 0.0)

		testing.expect_value(t, r_outer2.name, "outer_propagates")
		testing.expect(t, r_outer2.zero_alloc_failed, "outer_propagates must observe inner alloc")
		testing.expect_value(t, r_outer2.allocs_per_op, 1.0)
		testing.expect_value(t, r_outer2.alloc_bytes_per_op, 96.0)

		testing.expect_value(t, r_inner2.name, "inner_allocs")
		testing.expect(t, r_inner2.zero_alloc_failed, "inner_allocs must fail zero_alloc")
		testing.expect_value(t, r_inner2.allocs_per_op, 1.0)
		testing.expect_value(t, r_inner2.alloc_bytes_per_op, 96.0)
	}
}

@(test)
test_decode_record_truncated_metric_no_leak :: proc(t: ^testing.T) {
	rec := hugi.Record {
		rank             = 1,
		group_name       = "core",
		name             = "m",
		full_name        = "core::m",
		ops_per_sample   = 1,
		samples          = 1,
		error            = "",
		metrics          = make([dynamic]hugi.Metric, 0, 1, context.temp_allocator),
		samples_batch_ns = make([dynamic]u64, 0, 1, context.temp_allocator),
	}
	append(&rec.metrics, hugi.Metric{unit = "hit%", value = 99.5})
	append(&rec.samples_batch_ns, u64(100))

	raw := hugi.encode_record_bytes(rec, true, context.temp_allocator)
	trunc := raw[:len(raw) - 16]
	dec, ok := hugi.decode_record_bytes(trunc, context.allocator)
	defer hugi.record_destroy(&dec, context.allocator)
	testing.expect(t, !ok, "truncated metric value must fail decode without leaking unit string")
}

@(test)
test_jsonl_summary_only_preserves_stats :: proc(t: ^testing.T) {
	tmp, mk_err := os.make_directory_temp("", "hugi-jsonl-sum-*", context.allocator)
	testing.expectf(t, mk_err == nil && tmp != "", "create temp dir: %v", mk_err)
	if mk_err != nil || tmp == "" {
		return
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	path := strings.concatenate({tmp, "/summary_only.jsonl"}, context.temp_allocator)
	payload :=
		`{"rank":1,"group":"kv","lang":"zig","commit":"sum001","run_id":"sum-z1","name":"kv::sum","runs":12,"warmup":2,"median_ns":42.345,"min_ns":40.0,"max_ns":50.0,"p95_ns":48.0,"p99_ns":49.0,"mean_ns":43.0,"stddev_ns":2.5,"cv_pct":5.8,"iqr_ns":3.0}` +
		"\n"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)payload) == nil)

	pkts, ok := hugi.read_jsonl_packets(path)
	defer hugi.packets_destroy(pkts)
	testing.expect(t, ok, "summary-only jsonl should parse")
	if ok && len(pkts) == 1 && len(pkts[0].records) == 1 {
		r := pkts[0].records[0]
		testing.expect_value(t, len(r.samples_batch_ns), 0)
		testing.expect_value(t, r.samples, 12)
		testing.expect_value(t, r.p50_fs, i64(42_345_000))
		testing.expect_value(t, r.min_fs, i64(40_000_000))
		testing.expect_value(t, r.max_fs, i64(50_000_000))
		testing.expect_value(t, r.p95_fs, i64(48_000_000))
		testing.expect_value(t, r.p99_fs, i64(49_000_000))
		testing.expect_value(t, r.mean_fs, i64(43_000_000))
		testing.expect_value(t, r.std_dev_fs, i64(2_500_000))
		testing.expect_value(t, r.cv_pct, 5.8)
		testing.expect_value(t, r.iqr_fs, i64(3_000_000))
	}
}

@(test)
test_obench_v6_json_importer_maps_metadata_and_preserves_legacy_v3 :: proc(t: ^testing.T) {
	tmp, tmp_ok := _make_temp_dir(t, "hugi-obench-v6-*")
	if !tmp_ok {
		return
	}

	v6_path := strings.concatenate({tmp, "/v6.json"}, context.temp_allocator)
	v6_json := `{
		"format_version": 6,
		"suite_name": "v6_suite",
		"os": "linux",
		"arch": "amd64",
		"optimization": "Speed",
		"odin_version": "dev-2026-10",
		"created_at": "2026-11-20T08:30:00Z",
		"git": {"commit": "deadbeef1234567890abcdef", "branch": "main", "dirty": false},
		"machine": {"cpu": "AMD Ryzen 7 7735U", "cores": 16, "governor": "performance", "boost": "on", "smt": "on"},
		"build": {"microarch": "native", "bounds_checks": "off", "odin_version_hash": "abc"},
		"benchmarks": [{
			"suite_name": "v6_suite",
			"group_name": "hash",
			"name": "fnv1a",
			"full_name": "hash::fnv1a",
			"samples": 3,
			"batch_size": 10,
			"min_ns": 10.0,
			"p50_ns": 10.1,
			"p95_ns": 10.2,
			"p99_ns": 10.2,
			"max_ns": 10.2,
			"mean_ns": 10.1,
			"samples_batch_ns": [100, 101, 102],
			"peak_heap_bytes": 4096,
			"zero_alloc_failed": true,
			"custom_metrics": [{"unit": "hit%", "value": 99.5}],
			"instructions": 120.5,
			"cycles": 45.0,
			"branch_misses": 1.25,
			"cache_misses": 0.5
		}]
	}`
	testing.expect(t, os.write_entire_file(v6_path, transmute([]u8)v6_json) == nil)

	pkts, ok := hugi.read_obench_json_packets(v6_path)
	defer hugi.packets_destroy(pkts)
	testing.expect(t, ok, "read_obench_json_packets v6 should succeed")
	testing.expect_value(t, len(pkts), 1)
	if ok && len(pkts) == 1 {
		p := pkts[0]
		expected_t, _ := time.rfc3339_to_time_utc("2026-11-20T08:30:00Z")
		expected_ts := i64(time.to_unix_nanoseconds(expected_t)) / 1_000_000_000
		testing.expect_value(t, p.commit, "deadbeef1234")
		testing.expect_value(t, p.timestamp_unix, expected_ts)
		testing.expect_value(t, p.env.cpu_model, "AMD Ryzen 7 7735U")
		testing.expect_value(t, p.env.governor, "performance")
		testing.expect_value(t, p.env.boost_state, i8(1))
		testing.expect_value(t, p.env.build_flags, "-o:speed -microarch:native -no-bounds-check")
		testing.expect_value(t, p.env.runtime_version, "dev-2026-10")

		testing.expect_value(t, len(p.records), 1)
		if len(p.records) == 1 {
			r := p.records[0]
			testing.expect_value(t, r.peak_heap_bytes, i64(4096))
			testing.expect_value(t, r.zero_alloc_failed, true)
			testing.expect_value(t, len(r.metrics), 5)
			if len(r.metrics) == 5 {
				testing.expect_value(t, r.metrics[0].unit, "hit%")
				testing.expect_value(t, r.metrics[0].value, 99.5)
				testing.expect_value(t, r.metrics[1].unit, "instructions/op")
				testing.expect_value(t, r.metrics[1].value, 120.5)
				testing.expect_value(t, r.metrics[2].unit, "cycles/op")
				testing.expect_value(t, r.metrics[2].value, 45.0)
				testing.expect_value(t, r.metrics[3].unit, "branch_misses/op")
				testing.expect_value(t, r.metrics[3].value, 1.25)
				testing.expect_value(t, r.metrics[4].unit, "cache_misses/op")
				testing.expect_value(t, r.metrics[4].value, 0.5)
			}
		}
	}

	// commit_override takes precedence over doc.git.commit, and boost="off" maps to -1.
	pkts_ovr, ovr_ok := hugi.read_obench_json_packets(v6_path, commit_override = "override999")
	defer hugi.packets_destroy(pkts_ovr)
	testing.expect(t, ovr_ok, "read_obench_json_packets with commit_override should succeed")
	if ovr_ok && len(pkts_ovr) == 1 {
		testing.expect_value(t, pkts_ovr[0].commit, "override999")
	}

	v6_off_path := strings.concatenate({tmp, "/v6_off.json"}, context.temp_allocator)
	v6_off_json := `{"format_version":6,"suite_name":"v6_off","os":"linux","arch":"amd64","optimization":"Speed","odin_version":"dev-2026-10","machine":{"cpu":"CPU","cores":4,"governor":"powersave","boost":"off"},"benchmarks":[{"suite_name":"v6_off","group_name":"g","name":"b","full_name":"g::b","samples":3,"batch_size":1,"min_ns":10.0,"p50_ns":10.0,"p95_ns":10.0,"p99_ns":10.0,"max_ns":10.0,"mean_ns":10.0}]}`
	testing.expect(t, os.write_entire_file(v6_off_path, transmute([]u8)v6_off_json) == nil)
	pkts_off, off_ok := hugi.read_obench_json_packets(v6_off_path)
	defer hugi.packets_destroy(pkts_off)
	testing.expect(t, off_ok, "read_obench_json_packets boost=off should succeed")
	if off_ok && len(pkts_off) == 1 {
		testing.expect_value(t, pkts_off[0].env.boost_state, i8(-1))
		testing.expect_value(t, pkts_off[0].env.build_flags, "-o:speed")
		if len(pkts_off[0].records) == 1 {
			testing.expect_value(t, len(pkts_off[0].records[0].metrics), 0)
		}
	}

	// Active hardware counters preserve explicit 0.0 branch_misses/cache_misses metrics.
	v6_zero_miss_path := strings.concatenate({tmp, "/v6_zero_miss.json"}, context.temp_allocator)
	v6_zero_miss_json := `{"format_version":6,"suite_name":"v6_zm","os":"linux","arch":"amd64","optimization":"Speed","odin_version":"dev-2026-10","machine":{"cpu":"CPU","cores":4},"benchmarks":[{"suite_name":"v6_zm","group_name":"g","name":"b","full_name":"g::b","samples":3,"batch_size":1,"min_ns":10.0,"p50_ns":10.0,"p95_ns":10.0,"p99_ns":10.0,"max_ns":10.0,"mean_ns":10.0,"instructions":80.0,"cycles":25.0,"branch_misses":0.0,"cache_misses":0.0}]}`
	testing.expect(
		t,
		os.write_entire_file(v6_zero_miss_path, transmute([]u8)v6_zero_miss_json) == nil,
	)
	pkts_zm, zm_ok := hugi.read_obench_json_packets(v6_zero_miss_path)
	defer hugi.packets_destroy(pkts_zm)
	testing.expect(t, zm_ok, "read_obench_json_packets zero misses should succeed")
	if zm_ok && len(pkts_zm) == 1 && len(pkts_zm[0].records) == 1 {
		ms := pkts_zm[0].records[0].metrics
		testing.expect_value(t, len(ms), 4)
		if len(ms) == 4 {
			testing.expect_value(t, ms[0].unit, "instructions/op")
			testing.expect_value(t, ms[0].value, 80.0)
			testing.expect_value(t, ms[1].unit, "cycles/op")
			testing.expect_value(t, ms[1].value, 25.0)
			testing.expect_value(t, ms[2].unit, "branch_misses/op")
			testing.expect_value(t, ms[2].value, 0.0)
			testing.expect_value(t, ms[3].unit, "cache_misses/op")
			testing.expect_value(t, ms[3].value, 0.0)
		}
	}

	// Legacy v3 report without machine/build metadata must leave pkt.env empty.
	v3_path := strings.concatenate({tmp, "/v3.json"}, context.temp_allocator)
	v3_json := `{"format_version":3,"suite_name":"v3_suite","os":"linux","arch":"amd64","optimization":"Speed","odin_version":"dev","benchmarks":[{"suite_name":"v3_suite","group_name":"math","name":"mul","full_name":"math::mul","samples":3,"batch_size":10,"min_ns":10.0,"p50_ns":10.1,"p95_ns":10.2,"p99_ns":10.2,"max_ns":10.2,"mean_ns":10.1,"samples_batch_ns":[100,101,102]}]}`
	testing.expect(t, os.write_entire_file(v3_path, transmute([]u8)v3_json) == nil)
	v3_pkts, v3_ok := hugi.read_obench_json_packets(v3_path)
	defer hugi.packets_destroy(v3_pkts)
	testing.expect(t, v3_ok, "read_obench_json_packets v3 should succeed")
	if v3_ok && len(v3_pkts) == 1 {
		testing.expect(t, hugi.run_env_is_empty(v3_pkts[0].env), "v3 report must leave env empty")
	}
}

@(test)
test_suite_failure_messages_and_host_warned_dedup :: proc(t: ^testing.T) {
	tmp, tmp_ok := _make_temp_dir(t, "hugi-fail-msgs-*")
	if !tmp_ok {
		return
	}

	// 1. Per-benchmark failure messages for micro + pipeline @zero_alloc and host_warned governor dedup.
	cfg := hugi.default_suite_config()
	cfg.quiet = true
	cfg.host_warned = true
	cfg.runs = 2
	cfg.warmup = 0
	cfg.obench_cfg.sample_count = 5
	cfg.obench_cfg.warmup_time = 0
	cfg.obench_cfg.fixed_batch_size = 1

	s := hugi.suite_create("fail_msgs_suite", cfg)
	defer hugi.suite_destroy(&s)

	g := hugi.group_add(&s, "alloc_grp")
	hugi.group_bench(g, "bad_micro", proc(b: ^hugi.Bencher) {
			for hugi.step(b) {
				buf := make([]u8, 32)
				_ = hugi.black_box(buf[0])
				delete(buf)
			}
		}, zero_alloc = true)

	hugi.group_pipeline(&s, "bad_pipe", proc(p: ^hugi.Pipeline) {
		ph := hugi.phase_begin(p, "bad_phase", ops = 1, zero_alloc = true)
		buf := make([]u8, 24)
		_ = hugi.black_box(buf[0])
		delete(buf)
		hugi.phase_end(ph)
	})

	ok := hugi.suite_execute(&s)
	testing.expect(t, !ok, "suite must fail on @zero_alloc violations")
	testing.expect_value(t, s.failed_zero_alloc, 2)

	msgs := hugi.suite_failure_messages(&s, context.allocator)
	defer {
		for m in msgs {
			delete(m)
		}
		delete(msgs)
	}
	testing.expect_value(t, len(msgs), 2)
	saw_micro, saw_pipe := false, false
	for m in msgs {
		if strings.contains(m, "alloc_grp::bad_micro") {
			saw_micro = true
		}
		if strings.contains(m, "bad_pipe::bad_phase") {
			saw_pipe = true
		}
	}
	testing.expect(t, saw_micro, "failure messages should name micro benchmark")
	testing.expect(t, saw_pipe, "failure messages should name pipeline phase")

	// Check governor deduplication around write_terminal_summary without leaking machine_state.governor.
	orig_gov := s.obench_suite.machine_state.governor
	forced_gov := strings.clone("powersave", s.allocator)
	s.obench_suite.machine_state.governor = forced_gov

	sb_dedup := strings.builder_make(context.temp_allocator)
	hugi.write_terminal_summary(&sb_dedup, &s)
	testing.expect(
		t,
		!strings.contains(strings.to_string(sb_dedup), "CPU governor is 'powersave'"),
		"host_warned=true must suppress duplicate obench governor warning",
	)
	testing.expect_value(t, s.obench_suite.machine_state.governor, forced_gov)

	s.config.host_warned = false
	sb_plain := strings.builder_make(context.temp_allocator)
	hugi.write_terminal_summary(&sb_plain, &s)
	testing.expect(
		t,
		strings.contains(strings.to_string(sb_plain), "CPU governor is 'powersave'"),
		"host_warned=false should preserve obench governor warning",
	)

	delete(forced_gov, s.allocator)
	s.obench_suite.machine_state.governor = orig_gov

	// 2. Forward failed_baseline from obench into hugi.Suite.
	base_path := strings.concatenate({tmp, "/mismatch_base.json"}, context.temp_allocator)
	mismatch_json := `{"format_version":6,"suite_name":"other","os":"windows","arch":"arm64","optimization":"None","odin_version":"dev","benchmarks":[{"suite_name":"other","group_name":"g","name":"b","full_name":"g::b","samples":3,"batch_size":1,"min_ns":10.0,"p50_ns":10.0,"p95_ns":10.0,"p99_ns":10.0,"max_ns":10.0,"mean_ns":10.0}]}`
	testing.expect(t, os.write_entire_file(base_path, transmute([]u8)mismatch_json) == nil)

	cfg_bl := hugi.default_suite_config()
	cfg_bl.quiet = true
	cfg_bl.obench_cfg.sample_count = 5
	cfg_bl.obench_cfg.warmup_time = 0
	cfg_bl.obench_cfg.fixed_batch_size = 1
	cfg_bl.obench_cfg.fail_on_regression = true
	cfg_bl.obench_cfg.baseline_load_path = base_path

	s_bl := hugi.suite_create("baseline_fwd_suite", cfg_bl)
	defer hugi.suite_destroy(&s_bl)
	hugi.bench(&s_bl, "work", proc(b: ^hugi.Bencher) {
		for hugi.step(b) {
			_ = hugi.black_box(1)
		}
	})
	bl_ok := hugi.suite_execute(&s_bl)
	testing.expect(t, !bl_ok, "mismatched baseline must fail suite_execute")
	testing.expect(t, s_bl.failed_baseline > 0, "failed_baseline must be forwarded to hugi.Suite")

	// 3. Packet write I/O failure produces a suite_failure_messages entry.
	cfg_io := hugi.default_suite_config()
	cfg_io.quiet = true
	cfg_io.obench_cfg.sample_count = 5
	cfg_io.obench_cfg.warmup_time = 0
	cfg_io.obench_cfg.fixed_batch_size = 1
	cfg_io.packet_out_path = strings.concatenate(
		{tmp, "/missing_dir/out.hpk"},
		context.temp_allocator,
	)
	s_io := hugi.suite_create("io_fail_suite", cfg_io)
	defer hugi.suite_destroy(&s_io)
	hugi.bench(&s_io, "work", proc(b: ^hugi.Bencher) {
		for hugi.step(b) {
			_ = hugi.black_box(1)
		}
	})
	io_ok := hugi.suite_execute(&s_io)
	testing.expect(t, !io_ok, "unwritable packet_out_path must fail suite_execute")
	testing.expect_value(t, s_io.failed_io, 1)
	io_msgs := hugi.suite_failure_messages(&s_io, context.allocator)
	defer {
		for m in io_msgs {
			delete(m)
		}
		delete(io_msgs)
	}
	saw_io := false
	for m in io_msgs {
		if strings.contains(m, "could not write packet") {
			saw_io = true
		}
	}
	testing.expect(t, saw_io, "suite_failure_messages should report packet write failure")

	// 4. Forward failed_alloc_regressions from obench into hugi.Suite.
	alloc_base_path := strings.concatenate({tmp, "/alloc_base.json"}, context.temp_allocator)
	cfg_ab := hugi.default_suite_config()
	cfg_ab.quiet = true
	cfg_ab.obench_cfg.sample_count = 5
	cfg_ab.obench_cfg.warmup_time = 0
	cfg_ab.obench_cfg.fixed_batch_size = 1
	cfg_ab.obench_cfg.baseline_save_path = alloc_base_path
	{
		s_ab := hugi.suite_create("alloc_reg_suite", cfg_ab)
		defer hugi.suite_destroy(&s_ab)
		hugi.bench(&s_ab, "work", proc(b: ^hugi.Bencher) {
			for hugi.step(b) {
				acc := u64(1)
				for k in 0 ..< 512 {
					acc = acc * 6364136223846793005 + u64(k)
				}
				_ = hugi.black_box(acc)
			}
		})
		testing.expect(t, hugi.suite_execute(&s_ab), "baseline save run should succeed")
	}

	cfg_ac := cfg_ab
	cfg_ac.obench_cfg.baseline_save_path = ""
	cfg_ac.obench_cfg.baseline_load_path = alloc_base_path
	cfg_ac.obench_cfg.fail_on_alloc_regression = true
	s_alloc := hugi.suite_create("alloc_reg_suite", cfg_ac)
	defer hugi.suite_destroy(&s_alloc)
	hugi.bench(&s_alloc, "work", proc(b: ^hugi.Bencher) {
		for hugi.step(b) {
			buf := make([]u8, 32)
			acc := u64(1)
			for k in 0 ..< 512 {
				acc = acc * 6364136223846793005 + u64(k)
			}
			_ = hugi.black_box(u64(buf[0]) + acc)
			delete(buf)
		}
	})
	alloc_ok := hugi.suite_execute(&s_alloc)
	testing.expect(t, !alloc_ok, "alloc regression with fail_on_alloc_regression must fail suite")
	testing.expect_value(t, s_alloc.failed_alloc_regressions, 1)
	alloc_msgs := hugi.suite_failure_messages(&s_alloc, context.allocator)
	defer {
		for m in alloc_msgs {
			delete(m)
		}
		delete(alloc_msgs)
	}
	saw_alloc_reg := false
	for m in alloc_msgs {
		if strings.contains(m, "work") && strings.contains(m, "allocates more") {
			saw_alloc_reg = true
		}
	}
	testing.expect(t, saw_alloc_reg, "suite_failure_messages should report allocation regression")
}

@(test)
test_suite_test_mode_pin_and_counters_no_leaks :: proc(t: ^testing.T) {
	// 1. test_mode runs pipelines once (warmup=0, samples=1) and still enforces @zero_alloc.
	cfg_test := hugi.default_suite_config()
	cfg_test.quiet = true
	cfg_test.obench_cfg.test_mode = true

	s_test := hugi.suite_create("test_mode_suite", cfg_test)
	defer hugi.suite_destroy(&s_test)

	hugi.group_pipeline(&s_test, "pipe", proc(p: ^hugi.Pipeline) {
			{
				_ = hugi.scoped_phase(p, "clean", ops = 1, zero_alloc = true)
				_ = hugi.black_box(42)
			}
			{
				_ = hugi.scoped_phase(p, "leaker", ops = 1, zero_alloc = true)
				buf := make([]u8, 32)
				_ = hugi.black_box(len(buf))
				delete(buf)
			}
		}, runs = 5, warmup = 2)

	ok := hugi.suite_execute(&s_test)
	testing.expect(t, !ok, "test_mode must still catch @zero_alloc pipeline violations")
	testing.expect_value(t, s_test.failed_zero_alloc, 1)
	testing.expect_value(t, len(s_test.last_packet.records), 2)
	if len(s_test.last_packet.records) == 2 {
		testing.expect_value(t, s_test.last_packet.records[0].samples, 1)
		testing.expect_value(t, s_test.last_packet.records[0].warmup, 0)
		testing.expect(t, !s_test.last_packet.records[0].zero_alloc_failed)
		testing.expect(t, s_test.last_packet.records[1].zero_alloc_failed)
	}
	sb_test := strings.builder_make(context.temp_allocator)
	hugi.write_terminal_summary(&sb_test, &s_test)
	testing.expect(
		t,
		strings.contains(strings.to_string(sb_test), "--test ran every pipeline once"),
		"terminal summary should note --test mode for pipeline-only suites",
	)

	// 2. pin_cpu + counters run cleanly without leaks even when counters are unavailable.
	cfg_hw := hugi.default_suite_config()
	cfg_hw.quiet = true
	cfg_hw.runs = 2
	cfg_hw.warmup = 0
	cfg_hw.obench_cfg.sample_count = 5
	cfg_hw.obench_cfg.warmup_time = 0
	cfg_hw.obench_cfg.fixed_batch_size = 1
	cfg_hw.obench_cfg.pin_cpu = 0
	cfg_hw.obench_cfg.counters = true

	s_hw := hugi.suite_create("pin_counters_suite", cfg_hw)
	defer hugi.suite_destroy(&s_hw)

	hugi.bench(&s_hw, "micro_step", proc(b: ^hugi.Bencher) {
		for hugi.step(b) {
			acc := 0
			for i in 0 ..< 1000 {
				acc += i
			}
			_ = hugi.black_box(acc)
		}
	})

	hugi.group_pipeline(&s_hw, "pipe", proc(p: ^hugi.Pipeline) {
			_ = hugi.scoped_phase(p, "step", ops = 1)
			acc := 0
			for i in 0 ..< 1000 {
				acc += i
			}
			_ = hugi.black_box(acc)
		}, runs = 2, warmup = 0)

	hw_ok := hugi.suite_execute(&s_hw)
	testing.expect(t, hw_ok, "pin_cpu + counters suite must succeed")
	testing.expect_value(t, len(s_hw.last_packet.records), 2)
	if s_hw.counters_unavailable == "" && len(s_hw.last_packet.records) == 2 {
		for rec, rec_idx in s_hw.last_packet.records {
			saw_insn := false
			saw_bmiss := false
			saw_cmiss := false
			for m in rec.metrics {
				testing.expectf(
					t,
					m.value >= 0.0,
					"record %q metric %q must be non-negative (got %v)",
					rec.full_name,
					m.unit,
					m.value,
				)
				if m.unit == "instructions/op" && m.value > 0 {
					saw_insn = true
				} else if m.unit == "branch_misses/op" {
					saw_bmiss = true
				} else if m.unit == "cache_misses/op" {
					saw_cmiss = true
				}
			}
			testing.expectf(
				t,
				saw_insn,
				"record %q should include instructions/op metric when counters are open",
				rec.full_name,
			)
			if rec_idx == 0 {
				testing.expectf(
					t,
					saw_bmiss && saw_cmiss,
					"micro record %q should include branch_misses/op and cache_misses/op even when 0.0",
					rec.full_name,
				)
			}
		}
	}

	// Nested pipeline phases propagate inner counter bracket overhead cleanly.
	s_nested := hugi.suite_create("nested_counters_suite", cfg_hw)
	defer hugi.suite_destroy(&s_nested)
	hugi.group_pipeline(&s_nested, "nested", proc(p: ^hugi.Pipeline) {
			_ = hugi.scoped_phase(p, "outer", ops = 1)
			{
				_ = hugi.scoped_phase(p, "inner", ops = 1)
				acc := 0
				for i in 0 ..< 500 {
					acc += i
				}
				_ = hugi.black_box(acc)
			}
			acc := 0
			for i in 0 ..< 500 {
				acc += i
			}
			_ = hugi.black_box(acc)
		}, runs = 2, warmup = 0)
	testing.expect(t, hugi.suite_execute(&s_nested), "nested counters pipeline should succeed")
	testing.expect_value(t, len(s_nested.last_packet.records), 2)
	for rec in s_nested.last_packet.records {
		for m in rec.metrics {
			testing.expect(t, m.value >= 0.0, "nested counter metrics must stay non-negative")
		}
	}

	// Quiet pipeline-only suite suppresses stderr pin warnings when pin_cpu is invalid.
	cfg_pin_quiet := hugi.default_suite_config()
	cfg_pin_quiet.quiet = true
	cfg_pin_quiet.runs = 1
	cfg_pin_quiet.warmup = 0
	cfg_pin_quiet.obench_cfg.pin_cpu = 999
	s_pin_quiet := hugi.suite_create("pin_quiet_suite", cfg_pin_quiet)
	defer hugi.suite_destroy(&s_pin_quiet)
	hugi.group_pipeline(&s_pin_quiet, "pipe", proc(p: ^hugi.Pipeline) {
			_ = hugi.scoped_phase(p, "step", ops = 1)
			_ = hugi.black_box(1)
		}, runs = 1, warmup = 0)
	testing.expect(
		t,
		hugi.suite_execute(&s_pin_quiet),
		"quiet pipeline suite with unpinnable CPU should still execute cleanly",
	)

	// Deterministic terminal note rendering for unavailable pipeline counters (and cleanup).
	s_note := hugi.suite_create("counters_note_suite", cfg_hw)
	defer hugi.suite_destroy(&s_note)
	hugi.group_pipeline(&s_note, "pipe", proc(p: ^hugi.Pipeline) {
			_ = hugi.scoped_phase(p, "step", ops = 1)
			_ = hugi.black_box(1)
		}, runs = 2, warmup = 0)
	testing.expect(t, hugi.suite_execute(&s_note))
	if s_note.counters_unavailable == "" {
		s_note.counters_unavailable = strings.clone("perf_event denied", s_note.allocator)
	}
	sb_note := strings.builder_make(context.temp_allocator)
	hugi.write_terminal_summary(&sb_note, &s_note)
	testing.expect(
		t,
		strings.contains(strings.to_string(sb_note), "--counters: no hardware counters here"),
		"unavailable hardware counters should emit a clear note",
	)
}

@(test)
test_suite_reuse_groups_filter_name_filter_and_custom_allocator_nested_phases :: proc(
	t: ^testing.T,
) {
	tmp, tmp_ok := _make_temp_dir(t, "hugi-reuse-filter-*")
	if !tmp_ok {
		return
	}

	// 1. Reusing a Suite with groups_filter matching only a Pipeline must clear stale obench
	// state and still report packet write I/O failures via failed_packet_io.
	cfg := hugi.default_suite_config()
	cfg.quiet = true
	cfg.runs = 2
	cfg.warmup = 0
	cfg.obench_cfg.sample_count = 4
	cfg.obench_cfg.warmup_time = 0
	cfg.obench_cfg.fixed_batch_size = 1

	s := hugi.suite_create("reuse_suite", cfg)
	defer hugi.suite_destroy(&s)

	g := hugi.group_add(&s, "micro_grp")
	hugi.group_bench(g, "bad_micro", proc(b: ^hugi.Bencher) {
			for hugi.step(b) {
				buf := make([]u8, 16)
				_ = hugi.black_box(buf[0])
				delete(buf)
			}
		}, zero_alloc = true)
	hugi.group_pipeline(&s, "pipe_grp", proc(p: ^hugi.Pipeline) {
			_ = hugi.scoped_phase(p, "clean_step", ops = 1, zero_alloc = true)
			_ = hugi.black_box(1)
		}, runs = 2, warmup = 0)

	testing.expect(t, !hugi.suite_execute(&s), "first run must fail due to bad_micro")
	testing.expect_value(t, len(s.obench_suite.results), 1)

	// Second run: select only pipe_grp and point packet_out_path at an unwritable directory.
	delete(s.config.groups_filter, s.allocator)
	s.config.groups_filter = strings.clone("pipe_grp", s.allocator)
	delete(s.config.packet_out_path, s.allocator)
	s.config.packet_out_path = strings.concatenate({tmp, "/no_such_dir/out.hpk"}, s.allocator)

	testing.expect(t, !hugi.suite_execute(&s), "second run must fail on packet I/O")
	testing.expect_value(t, len(s.obench_suite.results), 0)
	testing.expect_value(t, s.failed_zero_alloc, 0)
	testing.expect_value(t, s.failed_io, 1)
	testing.expect(t, s.failed_packet_io)

	sb_reuse := strings.builder_make(context.temp_allocator)
	hugi.write_terminal_summary(&sb_reuse, &s)
	reuse_txt := strings.to_string(sb_reuse)
	testing.expect(
		t,
		!strings.contains(reuse_txt, "micro_grp::bad_micro"),
		"terminal summary must not reprint stale microbenchmark results",
	)
	testing.expect(
		t,
		strings.contains(reuse_txt, "pipe_grp::clean_step"),
		"terminal summary should print selected pipeline phase",
	)

	reuse_msgs := hugi.suite_failure_messages(&s, context.allocator)
	defer {
		for m in reuse_msgs {
			delete(m)
		}
		delete(reuse_msgs)
	}
	saw_stale_micro := false
	saw_pkt_io := false
	for m in reuse_msgs {
		if strings.contains(m, "bad_micro") {
			saw_stale_micro = true
		}
		if strings.contains(m, "could not write packet") {
			saw_pkt_io = true
		}
	}
	testing.expect(t, !saw_stale_micro, "suite_failure_messages must not leak stale obench errors")
	testing.expect(t, saw_pkt_io, "suite_failure_messages must report packet write failure")

	// 2. Multi-token name_filter ("alpha|gamma") must exclude beta's failure and keep contiguous ranks.
	cfg_nf := hugi.default_suite_config()
	cfg_nf.quiet = true
	cfg_nf.name_filter = "alpha|gamma"
	cfg_nf.obench_cfg.sample_count = 4
	cfg_nf.obench_cfg.warmup_time = 0
	cfg_nf.obench_cfg.fixed_batch_size = 1

	s_nf := hugi.suite_create("name_filter_suite", cfg_nf)
	defer hugi.suite_destroy(&s_nf)
	gnf := hugi.group_add(&s_nf, "g")
	hugi.group_bench(gnf, "alpha", proc(b: ^hugi.Bencher) {
			for hugi.step(b) {
				_ = hugi.black_box(1)
			}
		}, zero_alloc = true)
	hugi.group_bench(gnf, "beta", proc(b: ^hugi.Bencher) {
			for hugi.step(b) {
				buf := make([]u8, 16)
				_ = hugi.black_box(buf[0])
				delete(buf)
			}
		}, zero_alloc = true)
	hugi.group_bench(gnf, "gamma", proc(b: ^hugi.Bencher) {
			for hugi.step(b) {
				_ = hugi.black_box(2)
			}
		}, zero_alloc = true)

	testing.expect(t, hugi.suite_execute(&s_nf), "filtered-out beta failure must not fail suite")
	testing.expect_value(t, s_nf.failed_zero_alloc, 0)
	testing.expect_value(t, len(s_nf.last_packet.records), 2)
	if len(s_nf.last_packet.records) == 2 {
		testing.expect_value(t, s_nf.last_packet.records[0].rank, 1)
		testing.expect_value(t, s_nf.last_packet.records[1].rank, 2)
	}

	// 3. Custom s.allocator != context.allocator with counters and nested phases must not leak or
	// bad-free, and pre-sized pipeline accumulators avoid allocations during Timed passes.
	custom_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&custom_track, context.allocator)
	defer {
		testing.expect_value(t, len(custom_track.allocation_map), 0)
		testing.expect_value(t, len(custom_track.bad_free_array), 0)
		mem.tracking_allocator_destroy(&custom_track)
	}
	custom_alloc := mem.tracking_allocator(&custom_track)

	cfg_cust := hugi.default_suite_config()
	cfg_cust.quiet = true
	cfg_cust.runs = 12
	cfg_cust.warmup = 1
	cfg_cust.obench_cfg.counters = true
	cfg_cust.obench_cfg.sample_count = 4
	cfg_cust.obench_cfg.warmup_time = 0
	cfg_cust.obench_cfg.fixed_batch_size = 1

	{
		s_cust := hugi.suite_create("custom_alloc_suite", cfg_cust, allocator = custom_alloc)
		defer hugi.suite_destroy(&s_cust)

		hugi.bench(&s_cust, "micro", proc(b: ^hugi.Bencher) {
			for hugi.step(b) {
				_ = hugi.black_box(1)
			}
		})
		hugi.group_pipeline(&s_cust, "nested", proc(p: ^hugi.Pipeline) {
				_ = hugi.scoped_phase(p, "outer", ops = 1)
				{
					_ = hugi.scoped_phase(p, "inner", ops = 1)
					_ = hugi.black_box(2)
				}
			}, runs = 12, warmup = 1)

		testing.expect(t, hugi.suite_execute(&s_cust))
		testing.expect_value(t, len(s_cust.last_packet.records), 3)
	}
}

@(test)
test_obench_combined_json_without_samples_batch_ns_and_suite_exit_code :: proc(t: ^testing.T) {
	tmp, tmp_ok := _make_temp_dir(t, "hugi-obench-v5-*")
	if !tmp_ok {
		return
	}

	// 1. Combined obench v0.5.0 JSON report omitting samples_batch_ns (mixed process batch sizes)
	// must infer sub-ns ops_per_sample scaling cleanly from samples_ns.
	comb_path := strings.concatenate({tmp, "/combined_v5.json"}, context.temp_allocator)
	comb_json := `{"format_version":6,"suite_name":"comb_suite","os":"linux","arch":"amd64","optimization":"Speed","odin_version":"dev-2026-11","processes":2,"benchmarks":[{"suite_name":"comb_suite","group_name":"simd","name":"hash","full_name":"simd::hash","samples":4,"batch_size":1,"min_ns":12.345678,"p50_ns":12.345955,"p95_ns":12.346123,"p99_ns":12.346123,"max_ns":12.346123,"mean_ns":12.345928,"samples_ns":[12.345678,12.346123,12.345900,12.346010],"process_medians_ns":[12.345789,12.346067]}]}`
	testing.expect(t, os.write_entire_file(comb_path, transmute([]u8)comb_json) == nil)

	pkts, ok := hugi.read_obench_json_packets(
		comb_path,
		commit_override = "comb01",
		run_id_override = "r-comb",
	)
	testing.expect(t, ok, "read combined obench JSON without samples_batch_ns")
	defer hugi.packets_destroy(pkts)
	testing.expect_value(t, len(pkts), 1)
	if len(pkts) == 1 && len(pkts[0].records) == 1 {
		r := pkts[0].records[0]
		testing.expect_value(t, r.ops_per_sample, u64(1_000_000))
		testing.expect_value(t, len(r.samples_batch_ns), 4)
		testing.expect_value(t, r.min_fs, i64(12_345_678))
		testing.expect_value(t, r.max_fs, i64(12_346_123))
		testing.expect_value(t, r.p50_fs, i64(12_345_955))
	}

	// 2. suite_exit_code parity with obench + format_bytes helper + pipeline clock override respect.
	testing.expect_value(t, hugi.suite_exit_code(nil), hugi.EXIT_SUCCESS)
	s_exit: hugi.Suite
	testing.expect_value(t, hugi.suite_exit_code(&s_exit), hugi.EXIT_SUCCESS)
	s_exit.failed_baseline = 1
	testing.expect_value(t, hugi.suite_exit_code(&s_exit), hugi.EXIT_BASELINE)
	s_exit.failed_regressions = 1
	testing.expect_value(t, hugi.suite_exit_code(&s_exit), hugi.EXIT_BASELINE)
	s_exit.failed_baseline = 0
	testing.expect_value(t, hugi.suite_exit_code(&s_exit), hugi.EXIT_FAILURE)
	s_exit.failed_regressions = 0
	s_exit.failed_baseline = 1
	s_exit.failed_errors = 1
	testing.expect_value(t, hugi.suite_exit_code(&s_exit), hugi.EXIT_FAILURE)
	s_exit.failed_errors = 0
	s_exit.failed_packet_io = true
	testing.expect_value(t, hugi.suite_exit_code(&s_exit), hugi.EXIT_FAILURE)

	fb := hugi.format_bytes(1536, context.temp_allocator)
	testing.expect_value(t, fb, "1.50 KiB")

	cfg_clk := hugi.default_suite_config()
	cfg_clk.quiet = true
	cfg_clk.runs = 2
	cfg_clk.warmup = 1
	s_clk := hugi.suite_create("clock_ovr_suite", cfg_clk)
	defer hugi.suite_destroy(&s_clk)
	s_clk.obench_suite.clock.overhead_ns = 123.0
	s_clk.obench_suite.clock.overhead_cycles = 456.0
	hugi.group_pipeline(&s_clk, "pipe", proc(p: ^hugi.Pipeline) {
			_ = hugi.scoped_phase(p, "op", ops = 1)
			_ = hugi.black_box(1)
		}, runs = 2, warmup = 1)
	testing.expect(t, hugi.suite_execute(&s_clk))
	testing.expect_value(t, s_clk.obench_suite.clock.overhead_ns, 123.0)
	testing.expect_value(t, s_clk.obench_suite.clock.overhead_cycles, 456.0)
}
