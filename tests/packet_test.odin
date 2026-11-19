package hugi_tests

import hugi "../hugi"
import "core:os"
import "core:strings"
import "core:testing"

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
