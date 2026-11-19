package hugi_tests

import hugi "../hugi"
import store "../store"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_u64_codecs_all_variants_roundtrip :: proc(t: ^testing.T) {
	verify_roundtrip :: proc(
		t: ^testing.T,
		samples: []u64,
		expected_codec: store.U64_Codec,
		label: string,
		loc := #caller_location,
	) {
		blob, c_ok := store.compress_samples_u64(samples, context.allocator)
		testing.expectf(t, c_ok, "%s: compress should succeed", label, loc = loc)
		if !c_ok {
			return
		}
		defer delete(blob)

		testing.expect_value(t, blob[0], store.SAMPLES_U64_MAGIC_0, loc = loc)
		testing.expect_value(t, blob[1], store.SAMPLES_U64_MAGIC_1, loc = loc)
		testing.expect_value(t, store.U64_Codec(blob[2]), expected_codec, loc = loc)

		back, d_ok := store.decompress_samples_u64(blob, context.allocator)
		testing.expectf(t, d_ok, "%s: decompress should succeed", label, loc = loc)
		if !d_ok {
			return
		}
		defer delete(back)

		testing.expect_value(t, len(back), len(samples), loc = loc)
		for v, i in samples {
			testing.expect_value(t, back[i], v, loc = loc)
		}
	}

	// 1. Raw (empty and short high-entropy pair).
	verify_roundtrip(t, []u64{}, .Raw, "raw-empty")
	raw_pair := []u64{0xFEDC_BA98_7654_3210, 0x0123_4567_89AB_CDEF}
	verify_roundtrip(t, raw_pair, .Raw, "raw-pair")

	// 2. Zlib_Delta_Varint (coprime small integer deltas).
	delta_var := make([]u64, 64)
	defer delete(delta_var)
	for i in 0 ..< len(delta_var) {
		delta_var[i] = 1_000_000 + u64(i % 3)
	}
	verify_roundtrip(t, delta_var, .Zlib_Delta_Varint, "delta-varint")

	// 3. Zlib_BSS (large palette values with low per-byte-lane entropy and gcd == 1).
	palette := [4]u64 {
		0xA1B2_C3D4_E5F6_0718,
		0x1122_3344_5566_7788,
		0x9988_7766_5544_3322,
		0xFFEE_DDCC_BBAA_9988,
	}
	bss_samples := make([]u64, 128)
	defer delete(bss_samples)
	for i in 0 ..< len(bss_samples) {
		bss_samples[i] = palette[(i * 5 + i / 3) % 4]
	}
	verify_roundtrip(t, bss_samples, .Zlib_BSS, "zlib-bss")

	// 4. Zlib_Delta_BSS (large steady 64-bit stride with coprime jitter -> gcd == 1).
	delta_bss := make([]u64, 256)
	defer delete(delta_bss)
	acc := u64(10_000_000_000)
	for i in 0 ..< len(delta_bss) {
		acc += u64(0x1122_3344_5566_7700) + u64(i % 3)
		delta_bss[i] = acc
	}
	verify_roundtrip(t, delta_bss, .Zlib_Delta_BSS, "delta-bss")

	// 5. Zlib_Block_GCD (clustered pseudo-random multiples of 500).
	gcd_samples := make([]u64, 128)
	defer delete(gcd_samples)
	rng_state := u64(0x9E37_79B9_7F4A_7C15)
	for i in 0 ..< len(gcd_samples) {
		rng_state = rng_state * 6364136223846793005 + 1442695040888963407
		jitter := (rng_state >> 32) % 97
		gcd_samples[i] = u64(500) * (u64(10_000) + jitter)
	}
	verify_roundtrip(t, gcd_samples, .Zlib_Block_GCD, "block-gcd")
}

@(test)
test_exported_samples_fs_bu_only :: proc(t: ^testing.T) {
	// 1. flags=0 batch_ns blob scaled accurately to per-op femtoseconds.
	batches := []u64{10_000, 10_050, 10_100, 0}
	u_blob, u_ok := store.compress_samples_u64(batches, context.allocator)
	testing.expect(t, u_ok, "u64 export blob compress should succeed")
	if u_ok {
		defer delete(u_blob)
		fs_out, f_ok := store.decompress_exported_samples_fs(u_blob, ops_per_sample = 100)
		testing.expect(t, f_ok, "BU flags=0 exported samples should decode")
		if f_ok {
			defer delete(fs_out)
			testing.expect_value(t, len(fs_out), 4)
			testing.expect_value(t, fs_out[0], i64(100_000_000))
			testing.expect_value(t, fs_out[1], i64(100_500_000))
			testing.expect_value(t, fs_out[2], i64(101_000_000))
			testing.expect_value(t, fs_out[3], i64(0))
		}
	}

	// 2. flags=1 signed femtosecond blob round-trips bit-exactly.
	fs_vals := []i64{-5_000, 0, 1, 5_000, 41_732_000_000}
	fs_blob, fs_ok := store.compress_samples_fs_i64(fs_vals, context.allocator)
	testing.expect(t, fs_ok, "fs i64 export blob compress should succeed")
	if fs_ok {
		defer delete(fs_blob)
		fs_back, bd_ok := store.decompress_exported_samples_fs(fs_blob, ops_per_sample = 999)
		testing.expect(t, bd_ok, "BU flags=1 exported samples should decode")
		if bd_ok {
			defer delete(fs_back)
			testing.expect_value(t, len(fs_back), len(fs_vals))
			for v, i in fs_vals {
				testing.expect_value(t, fs_back[i], v)
			}
		}
	}

	// 3. Legacy BF float blobs and truncated headers must be rejected cleanly.
	legacy_bf := [12]u8{'B', 'F', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	bf_out, bf_ok := store.decompress_exported_samples_fs(legacy_bf[:])
	testing.expect(t, !bf_ok, "legacy BF header must be rejected")
	testing.expect(t, bf_out == nil, "rejected BF decode must not leak")

	short_blob := [4]u8{'B', 'U', 0, 0}
	s_out, s_ok := store.decompress_exported_samples_fs(short_blob[:])
	testing.expect(t, !s_ok, "truncated BU header must be rejected")
	testing.expect(t, s_out == nil, "rejected short decode must not leak")
}

@(test)
test_rational_batch_u64_and_femtosecond_decimal_precision :: proc(t: ^testing.T) {
	// 1. u64 batch codec round-trip across empty, clustered ticks, and large wrapping deltas.
	emp_blob, emp_ok := store.compress_samples_u64([]u64{}, context.allocator)
	testing.expect(t, emp_ok, "empty u64 compress should succeed")
	if emp_ok {
		defer delete(emp_blob)
		emp_back, emp_dok := store.decompress_samples_u64(emp_blob, context.allocator)
		testing.expect(t, emp_dok, "empty u64 decode should succeed")
		if emp_dok {
			defer delete(emp_back)
			testing.expect_value(t, len(emp_back), 0)
		}
	}

	clustered := []u64 {
		41_732_000,
		41_732_030,
		41_731_990,
		41_732_000,
		41_732_010,
		41_731_970,
		0,
		max(u64),
		12345,
	}
	c_blob, c_ok := store.compress_samples_u64(clustered, context.allocator)
	testing.expect(t, c_ok, "clustered/wrapping u64 compress should succeed")
	if c_ok {
		defer delete(c_blob)
		c_back, c_dok := store.decompress_samples_u64(c_blob, context.allocator)
		testing.expect(t, c_dok, "clustered/wrapping u64 decode should succeed")
		if c_dok {
			defer delete(c_back)
			testing.expect_value(t, len(c_back), len(clustered))
			for v, i in clustered {
				testing.expect_value(t, c_back[i], v)
			}
		}
	}

	// 2. Signed femtosecond sample codec round-trip (`compress_samples_fs_i64`).
	fs_vals := []i64{-123_456_789, -1, 0, 1, 5_000, 41_732_000_000}
	fs_blob, f_ok := store.compress_samples_fs_i64(fs_vals, context.allocator)
	testing.expect(t, f_ok, "fs i64 compress should succeed")
	if f_ok {
		defer delete(fs_blob)
		fs_back, f_dok := store.decompress_samples_fs_i64(fs_blob, context.allocator)
		testing.expect(t, f_dok, "fs i64 decode should succeed")
		if f_dok {
			defer delete(fs_back)
			testing.expect_value(t, len(fs_back), len(fs_vals))
			for v, i in fs_vals {
				testing.expect_value(t, fs_back[i], v)
			}
		}
	}

	// 3. Exact sub-picosecond SIMD and clamped zero formatting + CZPK\x04 / CZCH\x02 round-trip.
	sb := strings.builder_make(context.temp_allocator)
	hugi.write_decimal_ns_fs(&sb, 5_000)
	testing.expect_value(t, strings.to_string(sb), "0.005000")
	ps_str := hugi.format_duration_fs(5_000, context.allocator)
	defer delete(ps_str)
	testing.expect_value(t, ps_str, "5.00 ps")

	if !os.exists(".tmp") {
		_ = os.make_directory(".tmp")
	}
	db_path := ".tmp/hugi_test_rational.hugidb"
	csv_path := ".tmp/hugi_test_rational.csv"
	json_path := ".tmp/hugi_test_rational.json"
	for p in ([3]string{db_path, csv_path, json_path}) {
		if os.exists(p) {
			_ = os.remove(p)
		}
	}
	defer for p in ([3]string{db_path, csv_path, json_path}) {
		if os.exists(p) {
			_ = os.remove(p)
		}
	}

	make_simd_pkt := proc(run_id, commit: string) -> hugi.Run_Packet {
		pkt := hugi.Run_Packet {
			run_id         = strings.clone(run_id),
			commit         = strings.clone(commit),
			timestamp_unix = 1770000100,
			lang           = strings.clone("odin"),
			suite_name     = strings.clone("simd_suite"),
			os             = strings.clone("linux"),
			arch           = strings.clone("amd64"),
			optimization   = strings.clone("-o:speed"),
			odin_version   = strings.clone("dev"),
			records        = make([dynamic]hugi.Record),
		}

		r_simd := hugi.Record {
			rank             = 1,
			group_name       = strings.clone("simd"),
			name             = strings.clone("dot8"),
			full_name        = strings.clone("simd::dot8"),
			ops_per_sample   = 10_000_000,
			samples_batch_ns = make([dynamic]u64),
			metrics          = make([dynamic]hugi.Metric),
		}
		append(&r_simd.samples_batch_ns, 50_000, 50_000, 50_010)
		hugi.recompute_record_stats_from_samples(&r_simd)
		append(&pkt.records, r_simd)

		r_zero := hugi.Record {
			rank             = 2,
			group_name       = strings.clone("simd"),
			name             = strings.clone("clamped_zero"),
			full_name        = strings.clone("simd::clamped_zero"),
			ops_per_sample   = 1_000_000,
			samples_batch_ns = make([dynamic]u64),
			metrics          = make([dynamic]hugi.Metric),
		}
		append(&r_zero.samples_batch_ns, 0, 0, 1)
		hugi.recompute_record_stats_from_samples(&r_zero)
		append(&pkt.records, r_zero)
		return pkt
	}

	{
		st, ok := store.store_open(db_path)
		testing.expect(t, ok, "open rational store")
		if !ok {
			return
		}
		defer store.store_close(&st)

		p1 := make_simd_pkt("rr-1", "rc01")
		defer hugi.packet_destroy(&p1)
		p2 := make_simd_pkt("rr-2", "rc02")
		defer hugi.packet_destroy(&p2)
		p3 := make_simd_pkt("rr-3", "rc02")
		defer hugi.packet_destroy(&p3)
		testing.expect_value(t, p1.records[0].p50_fs, i64(5_000))
		testing.expect_value(t, p1.records[1].min_fs, i64(0))
		testing.expect_value(t, p1.records[1].p50_fs, i64(0))
		testing.expect_value(t, p1.records[1].max_fs, i64(1))

		testing.expect(t, store.store_ingest_packet(&st, p1), "ingest rational p1")
		testing.expect(t, store.store_ingest_packet(&st, p2), "ingest rational p2")
		testing.expect(t, store.store_ingest_packet(&st, p3), "ingest rational p3")
	}

	_, _, c_ok2 := store.store_compact(db_path)
	testing.expect(t, c_ok2, "compact rational store into CZCHv2")

	st_back, ok_back := store.store_open(db_path)
	testing.expect(t, ok_back, "reopen compacted rational store")
	if !ok_back {
		return
	}
	defer store.store_close(&st_back)

	all_pkts := store.store_load_all_packets(&st_back)
	defer {
		for &p in all_pkts {
			hugi.packet_destroy(&p)
		}
		delete(all_pkts)
	}
	testing.expect_value(t, len(all_pkts), 3)
	if len(all_pkts) == 3 && len(all_pkts[0].records) == 2 {
		rs := all_pkts[0].records[0]
		rz := all_pkts[0].records[1]
		testing.expect_value(t, rs.p50_fs, i64(5_000))
		testing.expect_value(t, len(rs.samples_batch_ns), 3)
		testing.expect_value(t, rs.samples_batch_ns[0], u64(50_000))
		testing.expect_value(t, rs.samples_batch_ns[2], u64(50_010))
		testing.expect_value(t, rz.min_fs, i64(0))
		testing.expect_value(t, rz.p50_fs, i64(0))
		testing.expect_value(t, rz.max_fs, i64(1))
		testing.expect_value(t, rz.samples_batch_ns[0], u64(0))
		testing.expect_value(t, rz.samples_batch_ns[2], u64(1))
	}

	pooled := store.store_load_pooled_records(&st_back, "odin")
	defer store.pooled_records_destroy(pooled)
	testing.expect_value(t, len(pooled), 2)
	if len(pooled) == 2 {
		testing.expect_value(t, pooled[0].p50_fs, i64(5_000))
		testing.expect_value(t, len(pooled[0].samples_batch_ns), 6)
		testing.expect_value(t, pooled[1].min_fs, i64(0))
		testing.expect_value(t, pooled[1].max_fs, i64(1))
	}

	testing.expect(t, store.export_csv(csv_path, pooled), "export rational csv")
	testing.expect(t, store.export_json(json_path, pooled), "export rational json")
	if csv_bytes, err := os.read_entire_file(csv_path, context.allocator); err == nil {
		defer delete(csv_bytes)
		testing.expect(
			t,
			strings.contains(string(csv_bytes), ",0.005000,"),
			"csv must format 5000 fs as exact 0.005000",
		)
	}
	if json_bytes, err := os.read_entire_file(json_path, context.allocator); err == nil {
		defer delete(json_bytes)
		testing.expect(
			t,
			strings.contains(string(json_bytes), `"samples_batch_ns": [50000,`),
			"json must include raw samples_batch_ns",
		)
		testing.expect(
			t,
			strings.contains(string(json_bytes), `"p50_ns": 0.005000`),
			"json must format DECIMAL(18, 6) p50_ns cleanly",
		)
	}
}
