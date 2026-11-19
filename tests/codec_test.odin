package hugi_tests

import hugi "../hugi"
import store "../store"
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
test_femtosecond_decimal_and_duration_formatting :: proc(t: ^testing.T) {
	Decimal_Case :: struct {
		fs:       i64,
		expected: string,
	}
	decimal_cases := []Decimal_Case {
		{0, "0.000000"},
		{42, "0.000042"},
		{5_000, "0.005000"},
		{125_000, "0.125000"},
		{42_125_000, "42.125000"},
		{1_250_000_000, "1250.000000"},
	}

	sb := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&sb)
	for tc in decimal_cases {
		strings.builder_reset(&sb)
		hugi.write_decimal_ns_fs(&sb, tc.fs)
		testing.expect_value(t, strings.to_string(sb), tc.expected)
	}

	Duration_Case :: struct {
		fs:       i64,
		expected: string,
	}
	duration_cases := []Duration_Case {
		{0, "0.00 ns"},
		{42, "42 fs"},
		{5_000, "5.00 ps"},
		{125_000, "125.00 ps"},
		{42_500_000, "42.50 ns"},
		{1_250_000_000, "1.25 us"},
		{2_500_000_000_000, "2.50 ms"},
		{1_500_000_000_000_000, "1.500 s"},
	}
	for tc in duration_cases {
		got := hugi.format_duration_fs(tc.fs, context.allocator)
		testing.expect_value(t, got, tc.expected)
		delete(got)
	}
}
