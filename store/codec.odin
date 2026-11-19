package hugi_store

import "core:c"
import "vendor:zlib"

SAMPLES_HEADER_LEN :: 12

BLOB_MAGIC_0 :: u8('B')
BLOB_MAGIC_1 :: u8('Z')
BLOB_MAGIC_2 :: u8(1)
BLOB_HEADER_LEN :: 8

/*
Compresses an arbitrary byte buffer with Zlib (storing raw bytes if compression does not shrink).
*/
@(require_results)
compress_bytes_zlib :: proc(
	src: []u8,
	allocator := context.allocator,
	level: c.int = 9,
) -> (
	out: []u8,
	ok: bool,
) {
	raw_len := len(src)
	if raw_len > 16 {
		bound := int(zlib.compressBound(zlib.uLong(raw_len)))
		comp, c_err := make([]u8, bound, context.temp_allocator)
		if c_err == nil {
			defer delete(comp, context.temp_allocator)
			dest_len := zlib.uLongf(bound)
			rc := zlib.compress2(
				raw_data(comp),
				&dest_len,
				raw_data(src),
				zlib.uLong(raw_len),
				level,
			)
			comp_len := int(dest_len)
			if rc == zlib.OK && comp_len > 0 && comp_len < raw_len {
				buf, a_err := make([]u8, BLOB_HEADER_LEN + comp_len, allocator)
				if a_err != nil {
					return nil, false
				}
				buf[0] = BLOB_MAGIC_0
				buf[1] = BLOB_MAGIC_1
				buf[2] = BLOB_MAGIC_2
				buf[3] = 1
				_write_u32_le(buf[4:8], u32(raw_len))
				copy(buf[BLOB_HEADER_LEN:], comp[:comp_len])
				return buf, true
			}
		}
	}

	buf, a_err := make([]u8, BLOB_HEADER_LEN + raw_len, allocator)
	if a_err != nil {
		return nil, false
	}
	buf[0] = BLOB_MAGIC_0
	buf[1] = BLOB_MAGIC_1
	buf[2] = BLOB_MAGIC_2
	buf[3] = 0
	_write_u32_le(buf[4:8], u32(raw_len))
	if raw_len > 0 {
		copy(buf[BLOB_HEADER_LEN:], src)
	}
	return buf, true
}

/*
Decompresses a buffer produced by `compress_bytes_zlib`.
*/
@(require_results)
decompress_bytes_zlib :: proc(
	blob: []u8,
	allocator := context.allocator,
) -> (
	out: []u8,
	ok: bool,
) {
	if len(blob) < BLOB_HEADER_LEN ||
	   blob[0] != BLOB_MAGIC_0 ||
	   blob[1] != BLOB_MAGIC_1 ||
	   blob[2] != BLOB_MAGIC_2 {
		return nil, false
	}
	mode := blob[3]
	raw_len := int(_read_u32_le(blob[4:8]))
	if raw_len < 0 || raw_len > 256 * 1024 * 1024 {
		return nil, false
	}
	payload := blob[BLOB_HEADER_LEN:]
	buf, err := make([]u8, raw_len, allocator)
	if err != nil {
		return nil, false
	}
	if mode == 0 {
		if len(payload) != raw_len {
			delete(buf, allocator)
			return nil, false
		}
		if raw_len > 0 {
			copy(buf, payload)
		}
		return buf, true
	}
	if mode != 1 {
		delete(buf, allocator)
		return nil, false
	}
	dest_len := zlib.uLongf(raw_len)
	rc := zlib.uncompress(raw_data(buf), &dest_len, raw_data(payload), zlib.uLong(len(payload)))
	if rc != zlib.OK || int(dest_len) != raw_len {
		delete(buf, allocator)
		return nil, false
	}
	return buf, true
}

// ── Integer u64 Batch & Femtosecond Sample Codecs (`BU`) ───────────────────

SAMPLES_U64_MAGIC_0 :: u8('B')
SAMPLES_U64_MAGIC_1 :: u8('U')

U64_Codec :: enum u8 {
	Raw               = 0,
	Zlib_Delta_Varint = 1,
	Zlib_BSS          = 2,
	Zlib_Delta_BSS    = 3,
	Zlib_Block_GCD    = 4,
}

@(private = "file")
_U64_GCD_BLOCK :: 16

@(private = "file")
_gcd_u64 :: proc "contextless" (a, b: u64) -> u64 {
	x := a
	y := b
	for y != 0 {
		x, y = y, x % y
	}
	return x
}

@(private = "file")
_build_u64_header :: proc(buf: []u8, codec: U64_Codec, flags: u8, count, raw_len: int) {
	buf[0] = SAMPLES_U64_MAGIC_0
	buf[1] = SAMPLES_U64_MAGIC_1
	buf[2] = u8(codec)
	buf[3] = flags
	_write_u32_le(buf[4:8], u32(count))
	_write_u32_le(buf[8:12], u32(raw_len))
}

@(private = "file")
_try_u64_zlib_candidate :: proc(
	src: []u8,
	codec: U64_Codec,
	raw_cap: int,
	best: ^[]u8,
	best_backing: ^[]u8,
	best_codec: ^U64_Codec,
	best_raw_len: ^int,
) {
	if len(src) == 0 {
		return
	}
	bound := int(zlib.compressBound(zlib.uLong(len(src))))
	comp, c_err := make([]u8, bound, context.temp_allocator)
	if c_err != nil {
		return
	}
	dest_len := zlib.uLongf(bound)
	rc := zlib.compress2(raw_data(comp), &dest_len, raw_data(src), zlib.uLong(len(src)), 9)
	clen := int(dest_len)
	if rc == zlib.OK && clen > 0 && clen < raw_cap && (best_codec^ == .Raw || clen < len(best^)) {
		if best_codec^ != .Raw {
			delete(best_backing^, context.temp_allocator)
		}
		best^ = comp[:clen]
		best_backing^ = comp
		best_codec^ = codec
		best_raw_len^ = len(src)
	} else {
		delete(comp, context.temp_allocator)
	}
}

@(private = "file", require_results)
_zlib_inflate_exact :: proc(
	payload: []u8,
	raw_len: int,
	allocator := context.temp_allocator,
) -> (
	out: []u8,
	ok: bool,
) {
	buf, err := make([]u8, raw_len, allocator)
	if err != nil {
		return nil, false
	}
	dest_len := zlib.uLongf(raw_len)
	rc := zlib.uncompress(raw_data(buf), &dest_len, raw_data(payload), zlib.uLong(len(payload)))
	if rc != zlib.OK || int(dest_len) != raw_len {
		delete(buf, allocator)
		return nil, false
	}
	return buf, true
}

/*
Losslessly compresses a `[]u64` integer array (typically overhead-adjusted nanosecond batch
timings) by racing zigzag delta-varint, 8-way BSS, delta-zigzag+BSS, and per-block GCD
factoring (each with Zlib-9) against raw `u64le`.
*/
@(require_results)
compress_samples_u64 :: proc(
	samples: []u64,
	allocator := context.allocator,
	flags: u8 = 0,
) -> (
	out: []u8,
	ok: bool,
) {
	n := len(samples)
	raw_len := n * 8
	if n == 0 {
		buf, err := make([]u8, SAMPLES_HEADER_LEN, allocator)
		if err != nil {
			return nil, false
		}
		_build_u64_header(buf, .Raw, flags, 0, 0)
		return buf, true
	}

	best: []u8
	best_backing: []u8
	best_codec := U64_Codec.Raw
	best_raw_len := raw_len

	// Candidate 1: Wrapping delta -> zigzag varint -> Zlib-9.
	var_raw := make([dynamic]u8, 0, max(n * 3, 16), context.temp_allocator)
	defer delete(var_raw)
	_fmt_append_varint_u64(&var_raw, samples[0])
	for i in 1 ..< n {
		diff := i64(samples[i] - samples[i - 1])
		_fmt_append_zigzag_i64(&var_raw, diff)
	}
	_try_u64_zlib_candidate(
		var_raw[:],
		.Zlib_Delta_Varint,
		raw_len,
		&best,
		&best_backing,
		&best_codec,
		&best_raw_len,
	)

	// Candidate 2: 8-way Byte-Stream-Split -> Zlib-9.
	if n > 2 {
		transposed, t_err := make([]u8, raw_len, context.temp_allocator)
		if t_err == nil {
			defer delete(transposed, context.temp_allocator)
			for s, i in samples {
				le := u64le(s)
				b := transmute([8]u8)le
				for lane in 0 ..< 8 {
					transposed[lane * n + i] = b[lane]
				}
			}
			_try_u64_zlib_candidate(
				transposed,
				.Zlib_BSS,
				raw_len,
				&best,
				&best_backing,
				&best_codec,
				&best_raw_len,
			)
		}
	}

	// Candidate 3: Wrapping delta -> zigzag -> 8-way Byte-Stream-Split -> Zlib-9.
	if n > 2 {
		transposed, t_err := make([]u8, raw_len, context.temp_allocator)
		if t_err == nil {
			defer delete(transposed, context.temp_allocator)
			le0 := u64le(samples[0])
			b0 := transmute([8]u8)le0
			for lane in 0 ..< 8 {
				transposed[lane * n] = b0[lane]
			}
			for i in 1 ..< n {
				diff := i64(samples[i] - samples[i - 1])
				zz := (u64(diff) << 1) ~ u64(diff >> 63)
				le := u64le(zz)
				b := transmute([8]u8)le
				for lane in 0 ..< 8 {
					transposed[lane * n + i] = b[lane]
				}
			}
			_try_u64_zlib_candidate(
				transposed,
				.Zlib_Delta_BSS,
				raw_len,
				&best,
				&best_backing,
				&best_codec,
				&best_raw_len,
			)
		}
	}

	// Candidate 4: Per-block (16-sample) GCD factoring + zigzag varint -> Zlib-9.
	if n >= 4 {
		gcd_raw := make([dynamic]u8, 0, max(n * 2, 32), context.temp_allocator)
		defer delete(gcd_raw)
		any_gcd_gt_1 := false
		max_safe_gcd := u64(max(i64)) >> 1

		for b0 := 0; b0 < n; b0 += _U64_GCD_BLOCK {
			m := min(_U64_GCD_BLOCK, n - b0)
			base := samples[b0]
			g := u64(0)
			for j in 1 ..< m {
				diff := i64(samples[b0 + j] - samples[b0 + j - 1])
				mag := diff < 0 ? u64(0) - u64(diff) : u64(diff)
				g = _gcd_u64(g, mag)
			}
			if g == 0 {
				if m > 1 && base > 1 && base <= max_safe_gcd {
					g = base
				} else {
					g = 1
				}
			}
			if g > max_safe_gcd {
				g = 1
			}
			if g > 1 {
				any_gcd_gt_1 = true
			}
			base_div := g > 1 && (base % g == 0)
			_fmt_append_varint_u64(&gcd_raw, (g << 1) | (u64(1) if base_div else u64(0)))
			_fmt_append_varint_u64(&gcd_raw, base / g if base_div else base)
			for j in 1 ..< m {
				diff := i64(samples[b0 + j] - samples[b0 + j - 1])
				q := diff
				if g > 1 {
					mag := diff < 0 ? u64(0) - u64(diff) : u64(diff)
					uq := mag / g
					q = diff < 0 ? -i64(uq) : i64(uq)
				}
				_fmt_append_zigzag_i64(&gcd_raw, q)
			}
		}

		if any_gcd_gt_1 {
			_try_u64_zlib_candidate(
				gcd_raw[:],
				.Zlib_Block_GCD,
				raw_len,
				&best,
				&best_backing,
				&best_codec,
				&best_raw_len,
			)
		}
	}

	if best_codec != .Raw {
		defer delete(best_backing, context.temp_allocator)
		buf, err := make([]u8, SAMPLES_HEADER_LEN + len(best), allocator)
		if err != nil {
			return nil, false
		}
		_build_u64_header(buf, best_codec, flags, n, best_raw_len)
		copy(buf[SAMPLES_HEADER_LEN:], best)
		return buf, true
	}

	buf, err := make([]u8, SAMPLES_HEADER_LEN + raw_len, allocator)
	if err != nil {
		return nil, false
	}
	_build_u64_header(buf, .Raw, flags, n, raw_len)
	for s, i in samples {
		le := u64le(s)
		b := transmute([8]u8)le
		off := SAMPLES_HEADER_LEN + i * 8
		copy(buf[off:off + 8], b[:])
	}
	return buf, true
}

@(require_results)
decompress_samples_u64_with_flags :: proc(
	blob: []u8,
	allocator := context.allocator,
) -> (
	out: []u64,
	flags: u8,
	ok: bool,
) {
	if len(blob) < SAMPLES_HEADER_LEN ||
	   blob[0] != SAMPLES_U64_MAGIC_0 ||
	   blob[1] != SAMPLES_U64_MAGIC_1 {
		return nil, 0, false
	}
	codec := U64_Codec(blob[2])
	flags = blob[3]
	count := int(_read_u32_le(blob[4:8]))
	raw_len := int(_read_u32_le(blob[8:12]))
	if count < 0 || count > 10_000_000 {
		return nil, 0, false
	}
	if count == 0 {
		arr, err := make([]u64, 0, allocator)
		return arr, flags, err == nil
	}

	payload := blob[SAMPLES_HEADER_LEN:]
	out_arr, err := make([]u64, count, allocator)
	if err != nil {
		return nil, 0, false
	}

	switch codec {
	case .Raw:
		if raw_len != count * 8 || len(payload) != raw_len {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		for i in 0 ..< count {
			b: [8]u8
			off := i * 8
			copy(b[:], payload[off:off + 8])
			out_arr[i] = u64(transmute(u64le)b)
		}
		return out_arr, flags, true

	case .Zlib_Delta_Varint:
		if raw_len <= 0 || raw_len > count * 11 + 64 {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		var_raw, v_ok := _zlib_inflate_exact(payload, raw_len)
		if !v_ok {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		defer delete(var_raw, context.temp_allocator)
		rd := _Format_Reader {
			data = var_raw,
		}
		v0, v0_ok := _fmt_read_varint_u64(&rd)
		if !v0_ok {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		out_arr[0] = v0
		for i in 1 ..< count {
			delta, d_ok := _fmt_read_zigzag_i64(&rd)
			if !d_ok {
				delete(out_arr, allocator)
				return nil, 0, false
			}
			out_arr[i] = out_arr[i - 1] + u64(delta)
		}
		if rd.pos != raw_len {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		return out_arr, flags, true

	case .Zlib_BSS:
		if raw_len != count * 8 {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		transposed, t_ok := _zlib_inflate_exact(payload, raw_len)
		if !t_ok {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		defer delete(transposed, context.temp_allocator)
		for i in 0 ..< count {
			b: [8]u8
			for lane in 0 ..< 8 {
				b[lane] = transposed[lane * count + i]
			}
			out_arr[i] = u64(transmute(u64le)b)
		}
		return out_arr, flags, true

	case .Zlib_Delta_BSS:
		if raw_len != count * 8 {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		transposed, t_ok := _zlib_inflate_exact(payload, raw_len)
		if !t_ok {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		defer delete(transposed, context.temp_allocator)
		for i in 0 ..< count {
			b: [8]u8
			for lane in 0 ..< 8 {
				b[lane] = transposed[lane * count + i]
			}
			zz := u64(transmute(u64le)b)
			if i == 0 {
				out_arr[0] = zz
			} else {
				delta := i64((zz >> 1) ~ u64(-i64(zz & 1)))
				out_arr[i] = out_arr[i - 1] + u64(delta)
			}
		}
		return out_arr, flags, true

	case .Zlib_Block_GCD:
		if raw_len <= 0 || raw_len > count * 12 + 128 {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		gcd_raw, g_ok := _zlib_inflate_exact(payload, raw_len)
		if !g_ok {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		defer delete(gcd_raw, context.temp_allocator)
		rd := _Format_Reader {
			data = gcd_raw,
		}
		for b0 := 0; b0 < count; b0 += _U64_GCD_BLOCK {
			m := min(_U64_GCD_BLOCK, count - b0)
			hdr, h_ok := _fmt_read_varint_u64(&rd)
			if !h_ok {
				delete(out_arr, allocator)
				return nil, 0, false
			}
			g := hdr >> 1
			if g == 0 {
				delete(out_arr, allocator)
				return nil, 0, false
			}
			base_div := (hdr & 1) != 0
			bval, b_ok := _fmt_read_varint_u64(&rd)
			if !b_ok || (base_div && bval > max(u64) / g) {
				delete(out_arr, allocator)
				return nil, 0, false
			}
			out_arr[b0] = bval * g if base_div else bval
			for j in 1 ..< m {
				q, q_ok := _fmt_read_zigzag_i64(&rd)
				if !q_ok {
					delete(out_arr, allocator)
					return nil, 0, false
				}
				if g == 1 {
					out_arr[b0 + j] = out_arr[b0 + j - 1] + u64(q)
				} else {
					mag := q < 0 ? u64(0) - u64(q) : u64(q)
					scaled := mag * g
					step := q < 0 ? u64(0) - scaled : scaled
					out_arr[b0 + j] = out_arr[b0 + j - 1] + step
				}
			}
		}
		if rd.pos != raw_len {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		return out_arr, flags, true
	}

	delete(out_arr, allocator)
	return nil, 0, false
}

@(require_results)
decompress_samples_u64 :: proc(
	blob: []u8,
	allocator := context.allocator,
) -> (
	out: []u64,
	ok: bool,
) {
	vals, _, dec_ok := decompress_samples_u64_with_flags(blob, allocator)
	return vals, dec_ok
}

@(require_results)
compress_samples_fs_i64 :: proc(
	samples: []i64,
	allocator := context.allocator,
) -> (
	out: []u8,
	ok: bool,
) {
	tmp := make([]u64, len(samples), context.temp_allocator)
	defer delete(tmp, context.temp_allocator)
	for v, i in samples {
		uv := u64(v)
		tmp[i] = (uv << 1) ~ u64(v >> 63)
	}
	return compress_samples_u64(tmp, allocator, flags = 1)
}

@(require_results)
decompress_samples_fs_i64 :: proc(
	blob: []u8,
	allocator := context.allocator,
) -> (
	out: []i64,
	ok: bool,
) {
	raw, flags, dec_ok := decompress_samples_u64_with_flags(blob, context.temp_allocator)
	if !dec_ok || flags != 1 {
		delete(raw, context.temp_allocator)
		return nil, false
	}
	defer delete(raw, context.temp_allocator)
	arr, err := make([]i64, len(raw), allocator)
	if err != nil {
		return nil, false
	}
	for zz, i in raw {
		arr[i] = i64((zz >> 1) ~ u64(-i64(zz & 1)))
	}
	return arr, true
}

@(require_results)
decompress_exported_samples_fs :: proc(
	blob: []u8,
	ops_per_sample: u64 = 1,
	allocator := context.allocator,
) -> (
	out: []i64,
	ok: bool,
) {
	if len(blob) < SAMPLES_HEADER_LEN ||
	   blob[0] != SAMPLES_U64_MAGIC_0 ||
	   blob[1] != SAMPLES_U64_MAGIC_1 {
		return nil, false
	}
	if blob[3] == 1 {
		return decompress_samples_fs_i64(blob, allocator)
	}
	raw, _, dec_ok := decompress_samples_u64_with_flags(blob, context.temp_allocator)
	if !dec_ok {
		return nil, false
	}
	defer delete(raw, context.temp_allocator)
	arr, err := make([]i64, len(raw), allocator)
	if err != nil {
		return nil, false
	}
	ops := max(ops_per_sample, 1)
	for b, i in raw {
		v := (u128(b) * 1_000_000 + u128(ops / 2)) / u128(ops)
		arr[i] = v > u128(max(i64)) ? max(i64) : i64(v)
	}
	return arr, true
}
