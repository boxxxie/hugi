package hugi_specs

import obench "../deps/obench/obench"
import hugi "../hugi"
import store "../store"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
prop_u64_sample_codec_lossless_roundtrip :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)

	rng_state := rand.create(t.seed)
	context.random_generator = rand.default_random_generator(&rng_state)

	buf: [160]u64
	seen_codecs: bit_set[store.U64_Codec]
	for iter in 0 ..< 350 {
		defer free_all(context.temp_allocator)

		dist := iter % 7
		n := 0
		switch dist {
		case 0:
			// Empty and tiny edge arrays (< 4 always select .Raw).
			n = rand.int_max(4)
			for i in 0 ..< n {
				switch rand.int_max(4) {
				case 0:
					buf[i] = 0
				case 1:
					buf[i] = max(u64)
				case:
					buf[i] = rand.uint64()
				}
			}
		case 1:
			// Monotonic small deltas (< 64) to exercise .Zlib_Delta_Varint.
			n = 64 + rand.int_max(len(buf) - 63)
			acc := u64(rand.int_max(1000))
			for i in 0 ..< n {
				acc += u64(1 + rand.int_max(60))
				buf[i] = acc
			}
		case 2:
			// Monotonic large-stride streams with small jitter to exercise .Zlib_Delta_BSS.
			n = 64 + rand.int_max(len(buf) - 63)
			acc := u64(rand.uint32())
			stride := (u64(1) << 28) + u64(1 + rand.int_max(255))
			for i in 0 ..< n {
				acc += stride + u64(rand.int_max(7))
				buf[i] = acc
			}
		case 3:
			// Clustered odd 64-bit values (non-monotonic, coprime -> GCD=1) for .Zlib_BSS.
			n = 64 + rand.int_max(len(buf) - 63)
			prefix := (u64(0x1234_5678_9A00) ~ (u64(rand.uint32()) << 16)) & ~u64(0xFF)
			for i in 0 ..< n {
				buf[i] = prefix | (u64(rand.int_max(64)) * 2 + 1)
			}
		case 4:
			// Exact block-GCD multiples to exercise .Zlib_Block_GCD.
			n = 64 + rand.int_max(len(buf) - 63)
			gcd_factor := u64(1_000_000_000) + u64(rand.int_max(4095))
			base := u64(10 + rand.int_max(500))
			for i in 0 ..< n {
				buf[i] = gcd_factor * (base + u64(rand.int_max(128)))
			}
		case 5:
			// Constant streams.
			n = 8 + rand.int_max(len(buf) - 7)
			val := rand.uint64()
			for i in 0 ..< n {
				buf[i] = val
			}
		case:
			// Arbitrary full-64-bit values including boundary extremes.
			n = 1 + rand.int_max(len(buf))
			for i in 0 ..< n {
				switch rand.int_max(16) {
				case 0:
					buf[i] = 0
				case 1:
					buf[i] = max(u64)
				case 2:
					buf[i] = u64(1) << 63
				case:
					buf[i] = rand.uint64()
				}
			}
		}

		samples := buf[:n]
		blob, c_ok := store.compress_samples_u64(samples, context.temp_allocator)
		if !testing.expectf(
			t,
			c_ok && len(blob) >= store.SAMPLES_HEADER_LEN,
			"seed=%d iter=%d dist=%d compress failed",
			t.seed,
			iter,
			dist,
		) {
			return
		}
		if !testing.expectf(
			t,
			blob[0] == store.SAMPLES_U64_MAGIC_0 && blob[1] == store.SAMPLES_U64_MAGIC_1,
			"seed=%d iter=%d invalid BU magic",
			t.seed,
			iter,
		) {
			return
		}
		codec_byte := blob[2]
		if codec_byte <= u8(max(store.U64_Codec)) {
			seen_codecs += {store.U64_Codec(codec_byte)}
		}

		decoded, d_ok := store.decompress_samples_u64(blob, context.temp_allocator)
		if !testing.expectf(
			t,
			d_ok,
			"seed=%d iter=%d dist=%d codec=%d decompress failed",
			t.seed,
			iter,
			dist,
			blob[2],
		) {
			return
		}
		if !testing.expectf(
			t,
			slice.equal(decoded, samples),
			"seed=%d iter=%d dist=%d roundtrip mismatch (len=%d)",
			t.seed,
			iter,
			dist,
			n,
		) {
			return
		}
	}

	for codec in store.U64_Codec {
		testing.expectf(
			t,
			codec in seen_codecs,
			"expected U64_Codec.%v to be exercised across property suite (seed=%d, seen=%v)",
			codec,
			t.seed,
			seen_codecs,
		)
	}
}

@(test)
prop_fs_i64_sample_codec_lossless_roundtrip :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)

	rng_state := rand.create(t.seed)
	context.random_generator = rand.default_random_generator(&rng_state)

	ibuf: [128]i64
	ubuf: [64]u64
	for iter in 0 ..< 250 {
		defer free_all(context.temp_allocator)

		n := rand.int_max(len(ibuf) + 1)
		for i in 0 ..< n {
			switch rand.int_max(12) {
			case 0:
				ibuf[i] = 0
			case 1:
				ibuf[i] = min(i64)
			case 2:
				ibuf[i] = max(i64)
			case 3:
				ibuf[i] = -1
			case:
				raw := i64(rand.uint64())
				if iter % 2 == 0 {
					raw = (raw % 1_000_000) - 500_000
				}
				ibuf[i] = raw
			}
		}

		vals := ibuf[:n]
		blob, c_ok := store.compress_samples_fs_i64(vals, context.temp_allocator)
		if !testing.expectf(
			t,
			c_ok && len(blob) >= store.SAMPLES_HEADER_LEN && blob[3] == 1,
			"seed=%d iter=%d fs_i64 compress failed",
			t.seed,
			iter,
		) {
			return
		}

		dec_fs, d_ok := store.decompress_samples_fs_i64(blob, context.temp_allocator)
		if !testing.expectf(
			t,
			d_ok && slice.equal(dec_fs, vals),
			"seed=%d iter=%d fs_i64 direct decode mismatch",
			t.seed,
			iter,
		) {
			return
		}

		dec_exp, e_ok := store.decompress_exported_samples_fs(
			blob,
			ops_per_sample = 777,
			allocator = context.temp_allocator,
		)
		if !testing.expectf(
			t,
			e_ok && slice.equal(dec_exp, vals),
			"seed=%d iter=%d fs_i64 export decode mismatch",
			t.seed,
			iter,
		) {
			return
		}

		// Verify flags=0 batch_ns export decoding matches `hugi.batch_ns_to_op_fs`.
		bn := rand.int_max(len(ubuf) + 1)
		ops := u64(1 + rand.int_max(10_000_000))
		for i in 0 ..< bn {
			ubuf[i] = rand.uint64() % 1_000_000_000_000
		}
		batches := ubuf[:bn]
		u_blob, u_ok := store.compress_samples_u64(batches, context.temp_allocator)
		if !testing.expectf(t, u_ok, "seed=%d iter=%d u64 compress failed", t.seed, iter) {
			return
		}
		fs_scaled, f_ok := store.decompress_exported_samples_fs(
			u_blob,
			ops_per_sample = ops,
			allocator = context.temp_allocator,
		)
		if !testing.expectf(
			t,
			f_ok && len(fs_scaled) == bn,
			"seed=%d iter=%d u64 export decode failed",
			t.seed,
			iter,
		) {
			return
		}
		for i in 0 ..< bn {
			exp := hugi.batch_ns_to_op_fs(batches[i], ops)
			if !testing.expectf(
				t,
				fs_scaled[i] == exp,
				"seed=%d iter=%d batch[%d] scaling mismatch (%d != %d)",
				t.seed,
				iter,
				i,
				fs_scaled[i],
				exp,
			) {
				return
			}
		}
	}
}

@(test)
prop_zlib_blob_codec_lossless_roundtrip :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)

	rng_state := rand.create(t.seed)
	context.random_generator = rand.default_random_generator(&rng_state)

	buf: [2048]u8
	for iter in 0 ..< 200 {
		defer free_all(context.temp_allocator)

		n := rand.int_max(len(buf) + 1)
		src := buf[:n]
		if iter % 2 == 0 {
			_ = rand.read(src)
		} else {
			pattern := [4]u8 {
				u8(rand.uint32() & 0xFF),
				u8(rand.uint32() & 0xFF),
				u8(rand.uint32() & 0xFF),
				u8(rand.uint32() & 0xFF),
			}
			for i in 0 ..< n {
				src[i] = pattern[i % len(pattern)]
			}
		}

		blob, c_ok := store.compress_bytes_zlib(src, context.temp_allocator)
		if !testing.expectf(
			t,
			c_ok &&
			len(blob) >= store.BLOB_HEADER_LEN &&
			blob[0] == store.BLOB_MAGIC_0 &&
			blob[1] == store.BLOB_MAGIC_1 &&
			blob[2] == store.BLOB_MAGIC_2,
			"seed=%d iter=%d zlib compress failed",
			t.seed,
			iter,
		) {
			return
		}

		back, d_ok := store.decompress_bytes_zlib(blob, context.temp_allocator)
		if !testing.expectf(
			t,
			d_ok && slice.equal(back, src),
			"seed=%d iter=%d zlib roundtrip mismatch (len=%d)",
			t.seed,
			iter,
			n,
		) {
			return
		}
	}
}

@(private = "file")
_f64_bits_equal :: proc "contextless" (a, b: f64) -> bool {
	return transmute(u64)a == transmute(u64)b
}

@(private = "file")
_records_bit_equal :: proc(a, b: hugi.Record, include_samples: bool) -> (bool, string) {
	if a.rank != b.rank {return false, "rank"}
	if a.group_name != b.group_name {return false, "group_name"}
	if a.name != b.name {return false, "name"}
	if a.full_name != b.full_name {return false, "full_name"}
	if a.param != b.param {return false, "param"}
	if a.has_param != b.has_param {return false, "has_param"}
	if a.threads != b.threads {return false, "threads"}
	if a.has_threads != b.has_threads {return false, "has_threads"}
	if a.ops_per_sample != b.ops_per_sample {return false, "ops_per_sample"}
	if a.samples != b.samples {return false, "samples"}
	if a.warmup != b.warmup {return false, "warmup"}
	if a.min_fs != b.min_fs {return false, "min_fs"}
	if a.p25_fs != b.p25_fs {return false, "p25_fs"}
	if a.p50_fs != b.p50_fs {return false, "p50_fs"}
	if a.p75_fs != b.p75_fs {return false, "p75_fs"}
	if a.p95_fs != b.p95_fs {return false, "p95_fs"}
	if a.p99_fs != b.p99_fs {return false, "p99_fs"}
	if a.max_fs != b.max_fs {return false, "max_fs"}
	if a.mean_fs != b.mean_fs {return false, "mean_fs"}
	if a.std_dev_fs != b.std_dev_fs {return false, "std_dev_fs"}
	if a.ci95_fs != b.ci95_fs {return false, "ci95_fs"}
	if !_f64_bits_equal(a.cv_pct, b.cv_pct) {return false, "cv_pct"}
	if a.iqr_fs != b.iqr_fs {return false, "iqr_fs"}
	if a.mad_fs != b.mad_fs {return false, "mad_fs"}
	if !_f64_bits_equal(a.median_cycles, b.median_cycles) {return false, "median_cycles"}
	if a.bytes_per_op != b.bytes_per_op {return false, "bytes_per_op"}
	if a.items_per_op != b.items_per_op {return false, "items_per_op"}
	if !_f64_bits_equal(a.mb_per_sec, b.mb_per_sec) {return false, "mb_per_sec"}
	if !_f64_bits_equal(a.items_per_sec, b.items_per_sec) {return false, "items_per_sec"}
	if a.footprint_bytes != b.footprint_bytes {return false, "footprint_bytes"}
	if !_f64_bits_equal(a.allocs_per_op, b.allocs_per_op) {return false, "allocs_per_op"}
	if !_f64_bits_equal(a.resizes_per_op, b.resizes_per_op) {return false, "resizes_per_op"}
	if !_f64_bits_equal(a.alloc_bytes_per_op, b.alloc_bytes_per_op) {
		return false, "alloc_bytes_per_op"
	}
	if !_f64_bits_equal(a.temp_allocs_per_op, b.temp_allocs_per_op) {
		return false, "temp_allocs_per_op"
	}
	if !_f64_bits_equal(a.temp_bytes_per_op, b.temp_bytes_per_op) {
		return false, "temp_bytes_per_op"
	}
	if a.peak_heap_bytes != b.peak_heap_bytes {return false, "peak_heap_bytes"}
	if a.zero_alloc_failed != b.zero_alloc_failed {return false, "zero_alloc_failed"}
	if a.error != b.error {return false, "error"}
	if len(a.metrics) != len(b.metrics) {return false, "metrics.len"}
	for ma, mi in a.metrics {
		mb := b.metrics[mi]
		if ma.unit != mb.unit || !_f64_bits_equal(ma.value, mb.value) {
			return false, "metrics"
		}
	}
	if include_samples {
		if !slice.equal(a.samples_batch_ns[:], b.samples_batch_ns[:]) {
			return false, "samples_batch_ns"
		}
	} else {
		if len(a.samples_batch_ns) != 0 {
			return false, "samples_batch_ns.excluded"
		}
	}
	return true, ""
}

@(test)
prop_packet_and_record_binary_roundtrip :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)

	rng_state := rand.create(t.seed)
	context.random_generator = rand.default_random_generator(&rng_state)

	langs := [3]string{"odin", "zig", "lua"}
	oses := [3]string{"linux", "windows", "darwin"}
	arches := [2]string{"amd64", "arm64"}
	opts := [3]string{"Speed", "None", "Size"}
	vers := [2]string{"dev-2026", "release-1.0"}

	for iter in 0 ..< 150 {
		defer free_all(context.temp_allocator)

		rec_count := rand.int_max(6)
		pkt := hugi.Run_Packet {
			suite_name     = fmt.tprintf("suite_%d", iter),
			lang           = langs[rand.int_max(len(langs))],
			commit         = fmt.tprintf("c%06x", rand.uint32() & 0xFF_FFFF),
			run_id         = fmt.tprintf("run-%d-%d", iter, rand.int_max(999)),
			os             = oses[rand.int_max(len(oses))],
			arch           = arches[rand.int_max(len(arches))],
			optimization   = opts[rand.int_max(len(opts))],
			odin_version   = vers[rand.int_max(len(vers))],
			timestamp_unix = i64(1770000000 + rand.int_max(100_000)),
			selective      = (iter % 2) == 1,
			records        = make([dynamic]hugi.Record, 0, rec_count, context.temp_allocator),
		}

		for ri in 0 ..< rec_count {
			ops := u64(1 + rand.int_max(10_000))
			sc := rand.int_max(20)
			samples := make([dynamic]u64, sc, context.temp_allocator)
			for si in 0 ..< sc {
				samples[si] = u64(100 + rand.int_max(500_000))
			}

			mc := rand.int_max(3)
			metrics := make([dynamic]hugi.Metric, mc, context.temp_allocator)
			for mi in 0 ..< mc {
				metrics[mi] = hugi.Metric {
					unit  = fmt.tprintf("m%d", mi),
					value = f64(rand.int_max(10_000)) / 100.0,
				}
			}

			grp := fmt.tprintf("g%d", ri)
			name := fmt.tprintf("op_%d_%d", iter, ri)
			r := hugi.Record {
				rank               = ri + 1 + rand.int_max(4),
				group_name         = grp,
				name               = name,
				full_name          = fmt.tprintf("%s::%s", grp, name),
				param              = rand.int_max(512),
				has_param          = (ri % 2) == 0,
				threads            = 1 + rand.int_max(8),
				has_threads        = (iter % 3) == 0,
				ops_per_sample     = ops,
				samples            = sc,
				warmup             = rand.int_max(5),
				median_cycles      = f64(rand.int_max(50_000)) / 10.0,
				bytes_per_op       = u64(rand.int_max(4096)),
				items_per_op       = u64(1 + rand.int_max(16)),
				footprint_bytes    = u64(rand.int_max(65536)),
				allocs_per_op      = f64(rand.int_max(200)) / 10.0,
				resizes_per_op     = f64(rand.int_max(50)) / 10.0,
				alloc_bytes_per_op = f64(rand.int_max(16384)),
				temp_allocs_per_op = f64(rand.int_max(50)) / 10.0,
				temp_bytes_per_op  = f64(rand.int_max(4096)),
				peak_heap_bytes    = i64(rand.int_max(65536)),
				zero_alloc_failed  = (iter + ri) % 5 == 0,
				error              = (iter + ri) % 7 == 0 ? "err_msg" : "",
				metrics            = metrics,
				samples_batch_ns   = samples,
			}
			hugi.recompute_record_stats_from_samples(&r)
			hugi.refresh_record_throughput(&r)
			append(&pkt.records, r)
		}

		include_samples := (iter % 2) == 0
		encoded := hugi.encode_packet_bytes(pkt, include_samples, context.temp_allocator)
		decoded, p_ok := hugi.decode_packet_bytes(encoded, context.allocator)
		defer hugi.packet_destroy(&decoded)

		if !testing.expectf(
			t,
			p_ok &&
			strings.clone_from_bytes(encoded[:len(hugi.PACKET_MAGIC)], context.temp_allocator) ==
				hugi.PACKET_MAGIC,
			"seed=%d iter=%d packet decode failed",
			t.seed,
			iter,
		) {
			return
		}
		if !testing.expectf(
			t,
			decoded.suite_name == pkt.suite_name &&
			decoded.lang == pkt.lang &&
			decoded.commit == pkt.commit &&
			decoded.run_id == pkt.run_id &&
			decoded.os == pkt.os &&
			decoded.arch == pkt.arch &&
			decoded.optimization == pkt.optimization &&
			decoded.odin_version == pkt.odin_version &&
			decoded.timestamp_unix == pkt.timestamp_unix &&
			decoded.selective == pkt.selective &&
			len(decoded.records) == len(pkt.records),
			"seed=%d iter=%d packet header mismatch",
			t.seed,
			iter,
		) {
			return
		}

		for src_rec, ri in pkt.records {
			got := decoded.records[ri]
			eq_ok, diff_field := _records_bit_equal(got, src_rec, include_samples)
			if !testing.expectf(
				t,
				eq_ok,
				"seed=%d iter=%d record[%d] field %q mismatch",
				t.seed,
				iter,
				ri,
				diff_field,
			) {
				return
			}

			rec_blob := hugi.encode_record_bytes(src_rec, include_samples, context.temp_allocator)
			rec_back, r_ok := hugi.decode_record_bytes(rec_blob, context.allocator)
			defer hugi.record_destroy(&rec_back)
			rec_eq, rec_diff := _records_bit_equal(rec_back, src_rec, include_samples)
			if !testing.expectf(
				t,
				r_ok && rec_eq,
				"seed=%d iter=%d standalone record[%d] field %q mismatch",
				t.seed,
				iter,
				ri,
				rec_diff,
			) {
				return
			}
		}
	}
}

@(test)
prop_femtosecond_stats_monotonicity_and_permutation_invariance :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)

	rng_state := rand.create(t.seed)
	context.random_generator = rand.default_random_generator(&rng_state)

	buf: [128]i64
	shuf_buf: [128]i64
	for iter in 0 ..< 300 {
		defer free_all(context.temp_allocator)

		n := 1 + rand.int_max(len(buf))
		if iter % 10 == 0 {
			// Constant distribution invariant.
			c := i64(rand.uint64() % 10_000_000_000)
			for i in 0 ..< n {
				buf[i] = c
			}
		} else {
			for i in 0 ..< n {
				buf[i] = i64(rand.uint64() % 100_000_000_000)
			}
		}

		samples := buf[:n]
		st := hugi.compute_stats_fs(samples, context.temp_allocator)

		ordered :=
			st.samples == n &&
			st.min_fs >= 0 &&
			st.min_fs <= st.p25_fs &&
			st.p25_fs <= st.p50_fs &&
			st.p50_fs <= st.p75_fs &&
			st.p75_fs <= st.p95_fs &&
			st.p95_fs <= st.p99_fs &&
			st.p99_fs <= st.max_fs &&
			st.min_fs <= st.mean_fs &&
			st.mean_fs <= st.max_fs &&
			st.iqr_fs == st.p75_fs - st.p25_fs &&
			st.std_dev_fs >= 0 &&
			st.ci95_fs >= 0 &&
			st.mad_fs >= 0 &&
			st.cv_pct >= 0.0

		if !testing.expectf(
			t,
			ordered,
			"seed=%d iter=%d monotonicity/bounds violated: %v",
			t.seed,
			iter,
			st,
		) {
			return
		}

		if st.min_fs == st.max_fs {
			if !testing.expectf(
				t,
				st.std_dev_fs == 0 &&
				st.ci95_fs == 0 &&
				st.iqr_fs == 0 &&
				st.mad_fs == 0 &&
				st.p50_fs == st.min_fs &&
				st.mean_fs == st.min_fs,
				"seed=%d iter=%d constant slice had non-zero dispersion: %v",
				t.seed,
				iter,
				st,
			) {
				return
			}
		}

		if n > 1 {
			sum_sq := 0.0
			for v in samples {
				d := f64(v - st.mean_fs)
				sum_sq += d * d
			}
			std_f := math.sqrt(sum_sq / f64(n - 1))
			unadj_ci95 := i64(
				math.round(obench.t_critical_975(f64(n - 1)) * (std_f / math.sqrt(f64(n)))),
			)
			if !testing.expectf(
				t,
				st.ci95_fs >= unadj_ci95,
				"seed=%d iter=%d expected AR(1) ci95_fs (%d) >= unadjusted (%d)",
				t.seed,
				iter,
				st.ci95_fs,
				unadj_ci95,
			) {
				return
			}
		}

		copy(shuf_buf[:n], samples)
		shuffled := shuf_buf[:n]
		rand.shuffle(shuffled)
		st2 := hugi.compute_stats_fs(shuffled, context.temp_allocator)

		order_invariant :=
			st2.samples == st.samples &&
			st2.min_fs == st.min_fs &&
			st2.p25_fs == st.p25_fs &&
			st2.p50_fs == st.p50_fs &&
			st2.p75_fs == st.p75_fs &&
			st2.p95_fs == st.p95_fs &&
			st2.p99_fs == st.p99_fs &&
			st2.max_fs == st.max_fs &&
			st2.mean_fs == st.mean_fs &&
			st2.std_dev_fs == st.std_dev_fs &&
			st2.cv_pct == st.cv_pct &&
			st2.iqr_fs == st.iqr_fs &&
			st2.mad_fs == st.mad_fs &&
			st2.ci95_fs >= 0

		if !testing.expectf(
			t,
			order_invariant,
			"seed=%d iter=%d permutation broke order-independent stats (%v != %v)",
			t.seed,
			iter,
			st2,
			st,
		) {
			return
		}
	}
}
