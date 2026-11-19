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

	// Verify .jsonl and obench .json importers remain intact.
	if !os.exists(".tmp") {
		_ = os.make_directory(".tmp")
	}
	jsonl_in := ".tmp/hugi_test_import.jsonl"
	ojson_in := ".tmp/hugi_test_import_obench.json"
	defer {
		if os.exists(jsonl_in) {
			_ = os.remove(jsonl_in)
		}
		if os.exists(ojson_in) {
			_ = os.remove(ojson_in)
		}
	}

	jsonl_data :=
		`{"rank":1,"group":"kv","lang":"odin","commit":"imp001","run_id":"jr-1","name":"kv::get","ops":100,"runs":3,"warmup":1,"median_ns":42.5,"samples_ns":[42.0,42.5,43.0],"bytes_used":512}` +
		"\n"
	testing.expect(
		t,
		os.write_entire_file(jsonl_in, transmute([]u8)jsonl_data) == nil,
		"write sample jsonl",
	)
	jpkts, j_ok := hugi.read_jsonl_packets(jsonl_in)
	testing.expect(t, j_ok, "read_jsonl_packets should succeed")
	if j_ok {
		testing.expect_value(t, len(jpkts), 1)
		if len(jpkts) == 1 && len(jpkts[0].records) == 1 {
			testing.expect_value(t, jpkts[0].commit, "imp001")
			testing.expect_value(t, jpkts[0].records[0].samples_batch_ns[1], u64(4250))
		}
	}
	hugi.packets_destroy(jpkts)

	ojson_data := `{"format_version":3,"suite_name":"ob_suite","os":"linux","arch":"amd64","optimization":"Speed","odin_version":"dev","benchmarks":[{"suite_name":"ob_suite","group_name":"math","name":"mul","full_name":"math::mul","samples":3,"batch_size":10,"min_ns":10.0,"p50_ns":10.1,"p95_ns":10.2,"p99_ns":10.2,"max_ns":10.2,"mean_ns":10.1,"samples_batch_ns":[100,101,102]}]}`
	testing.expect(
		t,
		os.write_entire_file(ojson_in, transmute([]u8)ojson_data) == nil,
		"write sample obench json",
	)
	opkts, o_ok := hugi.read_obench_json_packets(ojson_in, commit_override = "ob001")
	testing.expect(t, o_ok, "read_obench_json_packets should succeed")
	if o_ok {
		testing.expect_value(t, len(opkts), 1)
		if len(opkts) == 1 && len(opkts[0].records) == 1 {
			testing.expect_value(t, opkts[0].commit, "ob001")
			testing.expect_value(t, opkts[0].records[0].samples_batch_ns[1], u64(101))
		}
	}
	hugi.packets_destroy(opkts)
}

@(private = "file")
_zero_alloc_sum :: proc(b: ^hugi.Bencher) {
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
_clean_pipeline :: proc(p: ^hugi.Pipeline) {
	vals := make([]u64, 16)
	defer delete(vals)

	{
		ph := hugi.scoped_phase(p, "fill", ops = 16, bytes_per_op = 8)
		for i in 0 ..< 16 {
			vals[i] = u64(i * 3)
		}
		hugi.phase_set_footprint(ph, u64(len(vals) * size_of(u64)))
	}
	{
		ph := hugi.scoped_phase(p, "sum", ops = 16, bytes_per_op = 8, zero_alloc = true)
		acc := u64(0)
		for v in vals {
			acc += v
		}
		_ = hugi.black_box(acc)
		hugi.phase_metric(ph, 100.0, "hit%")
	}
	{
		_ = hugi.scoped_phase(p, "verify", ops = 16, zero_alloc = true)
		_ = hugi.black_box(vals[0] + vals[15])
	}
}

@(private = "file")
_violating_pipeline :: proc(p: ^hugi.Pipeline) {
	ph := hugi.scoped_phase(p, "leaking_phase", ops = 1, zero_alloc = true)
	buf := make([]u8, 64)
	_ = hugi.black_box(buf[0])
	delete(buf)
	_ = ph
}

@(test)
test_suite_pipeline_and_untimed_zero_alloc :: proc(t: ^testing.T) {
	cfg := hugi.default_suite_config()
	cfg.quiet = true
	cfg.runs = 5
	cfg.warmup = 1
	cfg.obench_cfg.sample_count = 15
	cfg.obench_cfg.warmup_time = 0
	cfg.obench_cfg.fixed_batch_size = 16

	suite := hugi.suite_create("pipeline_test", cfg)
	defer hugi.suite_destroy(&suite)

	hugi.bench(&suite, "sum_zero_alloc", _zero_alloc_sum, zero_alloc = true)
	hugi.group_pipeline(&suite, "kv_pipe", _clean_pipeline)

	ok := hugi.suite_execute(&suite)
	testing.expect(t, ok, "clean suite with @zero_alloc and phases should pass")
	testing.expect_value(t, suite.failed_zero_alloc, 0)
	testing.expect_value(t, len(suite.last_packet.records), 4)
	testing.expect_value(t, suite.last_packet.records[1].footprint_bytes, u64(16 * size_of(u64)))
	testing.expect_value(t, len(suite.last_packet.records[2].metrics), 1)
	testing.expect_value(t, suite.last_packet.records[2].metrics[0].unit, "hit%")

	cfg2 := hugi.default_suite_config()
	cfg2.quiet = true
	cfg2.runs = 4
	cfg2.warmup = 1
	suite2 := hugi.suite_create("violation_test", cfg2)
	defer hugi.suite_destroy(&suite2)

	hugi.group_pipeline(&suite2, "bad_pipe", _violating_pipeline)
	ok2 := hugi.suite_execute(&suite2)
	testing.expect(t, !ok2, "zero_alloc pipeline allocating heap memory must fail")
	testing.expect(t, suite2.failed_zero_alloc > 0, "failed_zero_alloc must be recorded")
	testing.expect_value(t, len(suite2.last_packet.records), 1)
	testing.expect_value(t, len(suite2.last_packet.records[0].samples_batch_ns), 4)
}
