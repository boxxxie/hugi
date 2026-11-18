package hugi_store

import "core:c"
import "core:math"
import "vendor:compress/lz4"
import "vendor:zlib"

Codec :: enum u8 {
	Raw          = 0,
	LZ4_BSS      = 1,
	Zlib_BSS     = 2,
	Zlib_XOR_BSS = 3,
	Zlib_ALP     = 4,
}

SAMPLES_MAGIC_0 :: u8('B')
SAMPLES_MAGIC_1 :: u8('F')
SAMPLES_HEADER_LEN :: 12

BLOB_MAGIC_0 :: u8('B')
BLOB_MAGIC_1 :: u8('Z')
BLOB_MAGIC_2 :: u8(1)
BLOB_HEADER_LEN :: 8

@(private = "file")
_write_u32_le :: proc(dst: []u8, v: u32) {
	le := u32le(v)
	b := transmute([4]u8)le
	copy(dst[:4], b[:])
}

@(private = "file", require_results)
_read_u32_le :: proc(src: []u8) -> u32 {
	b: [4]u8
	copy(b[:], src[:4])
	return u32(transmute(u32le)b)
}

@(private = "file")
_ALP_BLOCK :: 64

@(private = "file")
_alp_pow10 := [6]f64{1.0, 10.0, 100.0, 1000.0, 10_000.0, 1_000_000.0}

@(private = "file")
_append_varint_u64 :: proc(buf: ^[dynamic]u8, v: u64) {
	n := v
	for n >= 0x80 {
		append(buf, u8(n & 0x7F) | 0x80)
		n >>= 7
	}
	append(buf, u8(n))
}

@(private = "file")
_append_zigzag_i64 :: proc(buf: ^[dynamic]u8, v: i64) {
	uv := u64(v)
	_append_varint_u64(buf, (uv << 1) ~ u64(v >> 63))
}

@(private = "file", require_results)
_read_varint_u64 :: proc(src: []u8, pos: ^int) -> (val: u64, ok: bool) {
	shift: uint = 0
	for shift < 64 {
		if pos^ >= len(src) {
			return 0, false
		}
		b := src[pos^]
		pos^ += 1
		val |= u64(b & 0x7F) << shift
		if (b & 0x80) == 0 {
			return val, true
		}
		shift += 7
	}
	return 0, false
}

@(private = "file", require_results)
_read_zigzag_i64 :: proc(src: []u8, pos: ^int) -> (val: i64, ok: bool) {
	uv := _read_varint_u64(src, pos) or_return
	return i64((uv >> 1) ~ u64(-i64(uv & 1))), true
}

@(private = "file", require_results)
_encode_alp_stream :: proc(
	samples: []f64,
	allocator := context.temp_allocator,
) -> (
	raw: []u8,
	ok: bool,
) {
	n := len(samples)
	for s in samples {
		if math.is_nan(s) || math.is_inf(s, 0) {
			return nil, false
		}
	}

	buf := make([dynamic]u8, 0, n * 4, allocator)
	q_vals: [_ALP_BLOCK]i64
	ulp_vals: [_ALP_BLOCK]i64

	idx := 0
	for idx < n {
		blk_n := min(_ALP_BLOCK, n - idx)
		blk := samples[idx:idx + blk_n]

		best_e := -1
		best_score := max(i64)
		for scale, e in _alp_pow10 {
			fits := true
			zero_ulps := 0
			total_ulp_abs: i64 = 0
			for s in blk {
				scaled := s * scale
				if math.abs(scaled) > 4.0e15 {
					fits = false
					break
				}
				q := i64(math.round(scaled))
				approx := f64(q) / scale
				diff := i128(transmute(u64)s) - i128(transmute(u64)approx)
				if diff < -(1 << 48) || diff > (1 << 48) {
					fits = false
					break
				}
				if diff == 0 {
					zero_ulps += 1
				} else {
					ad := diff >= 0 ? i64(diff) : i64(-diff)
					total_ulp_abs += min(ad, 1_000_000)
				}
			}
			if !fits {
				continue
			}
			score := i64(blk_n - zero_ulps) * 1_000_000_000 + total_ulp_abs + i64(e)
			if score < best_score {
				best_score = score
				best_e = e
				if zero_ulps == blk_n {
					break
				}
			}
		}

		if best_e < 0 {
			delete(buf)
			return nil, false
		}

		scale := _alp_pow10[best_e]
		has_ulp := false
		for s, k in blk {
			q := i64(math.round(s * scale))
			approx := f64(q) / scale
			ulp := i64(transmute(u64)s - transmute(u64)approx)
			q_vals[k] = q
			ulp_vals[k] = ulp
			if ulp != 0 {
				has_ulp = true
			}
		}

		hdr := u8(best_e & 0x07) | (u8(0x08) if has_ulp else u8(0))
		append(&buf, hdr)
		_append_zigzag_i64(&buf, q_vals[0])
		for k in 1 ..< blk_n {
			_append_zigzag_i64(&buf, q_vals[k] - q_vals[k - 1])
		}
		if has_ulp {
			for k in 0 ..< blk_n {
				_append_zigzag_i64(&buf, ulp_vals[k])
			}
		}
		idx += blk_n
	}

	return buf[:], true
}

/*
Losslessly compresses a `[]f64` sample array using 8-way Byte-Stream-Split (optionally with
sequential IEEE-754 XOR delta), or adaptive ALP decimal quantization, followed by Zlib or LZ4.
Falls back to `.Raw` whenever compression does not reduce byte length (except when `.Zlib_ALP`
is impossible on non-finite inputs, which returns `false` unless fallback is requested).
*/
@(require_results)
compress_samples_f64 :: proc(
	samples: []f64,
	codec := Codec.Zlib_BSS,
	allocator := context.allocator,
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
		buf[0] = SAMPLES_MAGIC_0
		buf[1] = SAMPLES_MAGIC_1
		buf[2] = u8(Codec.Raw)
		buf[3] = 0
		_write_u32_le(buf[4:8], 0)
		_write_u32_le(buf[8:12], 0)
		return buf, true
	}

	if codec == .Zlib_ALP {
		if alp_raw, alp_ok := _encode_alp_stream(samples, context.temp_allocator); alp_ok {
			defer delete(alp_raw, context.temp_allocator)
			if len(alp_raw) > 0 {
				bound := int(zlib.compressBound(zlib.uLong(len(alp_raw))))
				comp, c_err := make([]u8, bound, context.temp_allocator)
				if c_err == nil {
					defer delete(comp, context.temp_allocator)
					dest_len := zlib.uLongf(bound)
					rc := zlib.compress2(
						raw_data(comp),
						&dest_len,
						raw_data(alp_raw),
						zlib.uLong(len(alp_raw)),
						9,
					)
					comp_len := int(dest_len)
					if rc == zlib.OK && comp_len > 0 && comp_len < raw_len {
						buf, a_err := make([]u8, SAMPLES_HEADER_LEN + comp_len, allocator)
						if a_err != nil {
							return nil, false
						}
						buf[0] = SAMPLES_MAGIC_0
						buf[1] = SAMPLES_MAGIC_1
						buf[2] = u8(Codec.Zlib_ALP)
						buf[3] = 0
						_write_u32_le(buf[4:8], u32(n))
						_write_u32_le(buf[8:12], u32(len(alp_raw)))
						copy(buf[SAMPLES_HEADER_LEN:], comp[:comp_len])
						return buf, true
					}
				}
			}
		}
	}

	if (codec == .Zlib_BSS || codec == .LZ4_BSS || codec == .Zlib_XOR_BSS) && n > 2 {
		transposed, t_err := make([]u8, raw_len, context.temp_allocator)
		if t_err == nil {
			defer delete(transposed, context.temp_allocator)
			use_xor := codec == .Zlib_XOR_BSS
			prev: u64 = 0
			for s, i in samples {
				bits := transmute(u64)s
				val := bits if (!use_xor || i == 0) else (bits ~ prev)
				prev = bits
				le := u64le(val)
				b := transmute([8]u8)le
				for lane in 0 ..< 8 {
					transposed[lane * n + i] = b[lane]
				}
			}

			switch codec {
			case .Zlib_BSS, .Zlib_XOR_BSS:
				bound := int(zlib.compressBound(zlib.uLong(raw_len)))
				comp, c_err := make([]u8, bound, context.temp_allocator)
				if c_err == nil {
					defer delete(comp, context.temp_allocator)
					dest_len := zlib.uLongf(bound)
					rc := zlib.compress2(
						raw_data(comp),
						&dest_len,
						raw_data(transposed),
						zlib.uLong(raw_len),
						9,
					)
					comp_len := int(dest_len)
					if rc == zlib.OK && comp_len > 0 && comp_len < raw_len {
						buf, a_err := make([]u8, SAMPLES_HEADER_LEN + comp_len, allocator)
						if a_err != nil {
							return nil, false
						}
						buf[0] = SAMPLES_MAGIC_0
						buf[1] = SAMPLES_MAGIC_1
						buf[2] = u8(codec)
						buf[3] = 0
						_write_u32_le(buf[4:8], u32(n))
						_write_u32_le(buf[8:12], u32(raw_len))
						copy(buf[SAMPLES_HEADER_LEN:], comp[:comp_len])
						return buf, true
					}
				}
			case .LZ4_BSS:
				bound := int(lz4.compressBound(c.int(raw_len)))
				comp, c_err := make([]u8, bound, context.temp_allocator)
				if c_err == nil {
					defer delete(comp, context.temp_allocator)
					written := int(
						lz4.compress_default(
							raw_data(transposed),
							raw_data(comp),
							c.int(raw_len),
							c.int(bound),
						),
					)
					if written > 0 && written < raw_len {
						buf, a_err := make([]u8, SAMPLES_HEADER_LEN + written, allocator)
						if a_err != nil {
							return nil, false
						}
						buf[0] = SAMPLES_MAGIC_0
						buf[1] = SAMPLES_MAGIC_1
						buf[2] = u8(Codec.LZ4_BSS)
						buf[3] = 0
						_write_u32_le(buf[4:8], u32(n))
						_write_u32_le(buf[8:12], u32(raw_len))
						copy(buf[SAMPLES_HEADER_LEN:], comp[:written])
						return buf, true
					}
				}
			case .Raw, .Zlib_ALP:
			}
		}
	}

	buf, a_err := make([]u8, SAMPLES_HEADER_LEN + raw_len, allocator)
	if a_err != nil {
		return nil, false
	}
	buf[0] = SAMPLES_MAGIC_0
	buf[1] = SAMPLES_MAGIC_1
	buf[2] = u8(Codec.Raw)
	buf[3] = 0
	_write_u32_le(buf[4:8], u32(n))
	_write_u32_le(buf[8:12], u32(raw_len))
	for s, i in samples {
		le := transmute(u64le)s
		b := transmute([8]u8)le
		off := SAMPLES_HEADER_LEN + i * 8
		copy(buf[off:off + 8], b[:])
	}
	return buf, true
}

/*
Evaluates `.Zlib_BSS`, `.Zlib_XOR_BSS`, and `.Zlib_ALP` on `samples` and returns the smallest
lossless bit-exact encoding.
*/
@(require_results)
compress_samples_f64_best :: proc(
	samples: []f64,
	allocator := context.allocator,
) -> (
	out: []u8,
	ok: bool,
) {
	best: []u8
	has_best := false
	for codec in ([]Codec{.Zlib_BSS, .Zlib_XOR_BSS, .Zlib_ALP}) {
		cand, c_ok := compress_samples_f64(samples, codec, context.temp_allocator)
		if !c_ok {
			continue
		}
		if !has_best || len(cand) < len(best) {
			if has_best {
				delete(best, context.temp_allocator)
			}
			best = cand
			has_best = true
		} else {
			delete(cand, context.temp_allocator)
		}
	}
	if !has_best {
		return compress_samples_f64(samples, .Raw, allocator)
	}
	defer delete(best, context.temp_allocator)
	cloned := make([]u8, len(best), allocator)
	copy(cloned, best)
	return cloned, true
}

/*
Decompresses a blob written by `compress_samples_f64` back into exact IEEE-754 `[]f64` values.
*/
@(require_results)
decompress_samples_f64 :: proc(
	blob: []u8,
	allocator := context.allocator,
) -> (
	out: []f64,
	ok: bool,
) {
	if len(blob) < SAMPLES_HEADER_LEN || blob[0] != SAMPLES_MAGIC_0 || blob[1] != SAMPLES_MAGIC_1 {
		return nil, false
	}
	codec := Codec(blob[2])
	count := int(_read_u32_le(blob[4:8]))
	raw_len := int(_read_u32_le(blob[8:12]))
	if count < 0 || count > 10_000_000 {
		return nil, false
	}
	if count == 0 {
		arr, err := make([]f64, 0, allocator)
		return arr, err == nil
	}

	payload := blob[SAMPLES_HEADER_LEN:]
	if codec == .Zlib_ALP {
		if raw_len <= 0 || raw_len > count * 24 + 64 {
			return nil, false
		}
		alp_raw, a_err := make([]u8, raw_len, context.temp_allocator)
		if a_err != nil {
			return nil, false
		}
		defer delete(alp_raw, context.temp_allocator)

		dest_len := zlib.uLongf(raw_len)
		rc := zlib.uncompress(
			raw_data(alp_raw),
			&dest_len,
			raw_data(payload),
			zlib.uLong(len(payload)),
		)
		if rc != zlib.OK || int(dest_len) != raw_len {
			return nil, false
		}

		out_arr, out_err := make([]f64, count, allocator)
		if out_err != nil {
			return nil, false
		}

		pos := 0
		idx := 0
		q_vals: [_ALP_BLOCK]i64
		for idx < count {
			if pos >= raw_len {
				delete(out_arr, allocator)
				return nil, false
			}
			hdr := alp_raw[pos]
			pos += 1
			exp_idx := int(hdr & 0x07)
			if exp_idx >= len(_alp_pow10) {
				delete(out_arr, allocator)
				return nil, false
			}
			has_ulp := (hdr & 0x08) != 0
			scale := _alp_pow10[exp_idx]
			blk_n := min(_ALP_BLOCK, count - idx)

			q, q0_ok := _read_zigzag_i64(alp_raw, &pos)
			if !q0_ok {
				delete(out_arr, allocator)
				return nil, false
			}
			q_vals[0] = q
			for k in 1 ..< blk_n {
				delta, d_ok := _read_zigzag_i64(alp_raw, &pos)
				if !d_ok {
					delete(out_arr, allocator)
					return nil, false
				}
				q_vals[k] = q_vals[k - 1] + delta
			}

			if has_ulp {
				for k in 0 ..< blk_n {
					ulp, u_ok := _read_zigzag_i64(alp_raw, &pos)
					if !u_ok {
						delete(out_arr, allocator)
						return nil, false
					}
					approx := f64(q_vals[k]) / scale
					bits := transmute(u64)approx + u64(ulp)
					out_arr[idx + k] = transmute(f64)bits
				}
			} else {
				for k in 0 ..< blk_n {
					out_arr[idx + k] = f64(q_vals[k]) / scale
				}
			}
			idx += blk_n
		}
		if pos != raw_len {
			delete(out_arr, allocator)
			return nil, false
		}
		return out_arr, true
	}

	if raw_len != count * 8 {
		return nil, false
	}

	out_arr, err := make([]f64, count, allocator)
	if err != nil {
		return nil, false
	}

	if codec == .Raw {
		if len(payload) != raw_len {
			delete(out_arr, allocator)
			return nil, false
		}
		for i in 0 ..< count {
			b: [8]u8
			off := i * 8
			copy(b[:], payload[off:off + 8])
			out_arr[i] = transmute(f64)(transmute(u64le)b)
		}
		return out_arr, true
	}

	transposed, t_err := make([]u8, raw_len, context.temp_allocator)
	if t_err != nil {
		delete(out_arr, allocator)
		return nil, false
	}
	defer delete(transposed, context.temp_allocator)

	switch codec {
	case .Zlib_BSS, .Zlib_XOR_BSS:
		dest_len := zlib.uLongf(raw_len)
		rc := zlib.uncompress(
			raw_data(transposed),
			&dest_len,
			raw_data(payload),
			zlib.uLong(len(payload)),
		)
		if rc != zlib.OK || int(dest_len) != raw_len {
			delete(out_arr, allocator)
			return nil, false
		}
	case .LZ4_BSS:
		dec := int(
			lz4.decompress_safe(
				raw_data(payload),
				raw_data(transposed),
				c.int(len(payload)),
				c.int(raw_len),
			),
		)
		if dec != raw_len {
			delete(out_arr, allocator)
			return nil, false
		}
	case .Raw, .Zlib_ALP:
	}

	use_xor := codec == .Zlib_XOR_BSS
	prev: u64 = 0
	for i in 0 ..< count {
		b: [8]u8
		for lane in 0 ..< 8 {
			b[lane] = transposed[lane * count + i]
		}
		val := u64(transmute(u64le)b)
		cur := val if (!use_xor || i == 0) else (prev ~ val)
		prev = cur
		out_arr[i] = transmute(f64)cur
	}
	return out_arr, true
}

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
	_append_varint_u64(&var_raw, samples[0])
	for i in 1 ..< n {
		diff := i64(samples[i] - samples[i - 1])
		_append_zigzag_i64(&var_raw, diff)
	}
	if len(var_raw) > 0 {
		bound := int(zlib.compressBound(zlib.uLong(len(var_raw))))
		comp, c_err := make([]u8, bound, context.temp_allocator)
		if c_err == nil {
			dest_len := zlib.uLongf(bound)
			rc := zlib.compress2(
				raw_data(comp),
				&dest_len,
				raw_data(var_raw[:]),
				zlib.uLong(len(var_raw)),
				9,
			)
			clen := int(dest_len)
			if rc == zlib.OK && clen > 0 && clen < raw_len {
				best = comp[:clen]
				best_backing = comp
				best_codec = .Zlib_Delta_Varint
				best_raw_len = len(var_raw)
			} else {
				delete(comp, context.temp_allocator)
			}
		}
	}

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
			bound := int(zlib.compressBound(zlib.uLong(raw_len)))
			comp, c_err := make([]u8, bound, context.temp_allocator)
			if c_err == nil {
				dest_len := zlib.uLongf(bound)
				rc := zlib.compress2(
					raw_data(comp),
					&dest_len,
					raw_data(transposed),
					zlib.uLong(raw_len),
					9,
				)
				clen := int(dest_len)
				if rc == zlib.OK &&
				   clen > 0 &&
				   clen < raw_len &&
				   (best_codec == .Raw || clen < len(best)) {
					if best_codec != .Raw {
						delete(best_backing, context.temp_allocator)
					}
					best = comp[:clen]
					best_backing = comp
					best_codec = .Zlib_BSS
					best_raw_len = raw_len
				} else {
					delete(comp, context.temp_allocator)
				}
			}
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
			bound := int(zlib.compressBound(zlib.uLong(raw_len)))
			comp, c_err := make([]u8, bound, context.temp_allocator)
			if c_err == nil {
				dest_len := zlib.uLongf(bound)
				rc := zlib.compress2(
					raw_data(comp),
					&dest_len,
					raw_data(transposed),
					zlib.uLong(raw_len),
					9,
				)
				clen := int(dest_len)
				if rc == zlib.OK &&
				   clen > 0 &&
				   clen < raw_len &&
				   (best_codec == .Raw || clen < len(best)) {
					if best_codec != .Raw {
						delete(best_backing, context.temp_allocator)
					}
					best = comp[:clen]
					best_backing = comp
					best_codec = .Zlib_Delta_BSS
					best_raw_len = raw_len
				} else {
					delete(comp, context.temp_allocator)
				}
			}
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
			_append_varint_u64(&gcd_raw, (g << 1) | (u64(1) if base_div else u64(0)))
			_append_varint_u64(&gcd_raw, base / g if base_div else base)
			for j in 1 ..< m {
				diff := i64(samples[b0 + j] - samples[b0 + j - 1])
				q := diff
				if g > 1 {
					mag := diff < 0 ? u64(0) - u64(diff) : u64(diff)
					uq := mag / g
					q = diff < 0 ? -i64(uq) : i64(uq)
				}
				_append_zigzag_i64(&gcd_raw, q)
			}
		}

		if any_gcd_gt_1 && len(gcd_raw) > 0 {
			bound := int(zlib.compressBound(zlib.uLong(len(gcd_raw))))
			comp, c_err := make([]u8, bound, context.temp_allocator)
			if c_err == nil {
				dest_len := zlib.uLongf(bound)
				rc := zlib.compress2(
					raw_data(comp),
					&dest_len,
					raw_data(gcd_raw[:]),
					zlib.uLong(len(gcd_raw)),
					9,
				)
				clen := int(dest_len)
				if rc == zlib.OK &&
				   clen > 0 &&
				   clen < raw_len &&
				   (best_codec == .Raw || clen < len(best)) {
					if best_codec != .Raw {
						delete(best_backing, context.temp_allocator)
					}
					best = comp[:clen]
					best_backing = comp
					best_codec = .Zlib_Block_GCD
					best_raw_len = len(gcd_raw)
				} else {
					delete(comp, context.temp_allocator)
				}
			}
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
		var_raw, v_err := make([]u8, raw_len, context.temp_allocator)
		if v_err != nil {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		defer delete(var_raw, context.temp_allocator)

		dest_len := zlib.uLongf(raw_len)
		rc := zlib.uncompress(
			raw_data(var_raw),
			&dest_len,
			raw_data(payload),
			zlib.uLong(len(payload)),
		)
		if rc != zlib.OK || int(dest_len) != raw_len {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		pos := 0
		v0, v0_ok := _read_varint_u64(var_raw, &pos)
		if !v0_ok {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		out_arr[0] = v0
		for i in 1 ..< count {
			delta, d_ok := _read_zigzag_i64(var_raw, &pos)
			if !d_ok {
				delete(out_arr, allocator)
				return nil, 0, false
			}
			out_arr[i] = out_arr[i - 1] + u64(delta)
		}
		if pos != raw_len {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		return out_arr, flags, true

	case .Zlib_BSS:
		if raw_len != count * 8 {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		transposed, t_err := make([]u8, raw_len, context.temp_allocator)
		if t_err != nil {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		defer delete(transposed, context.temp_allocator)

		dest_len := zlib.uLongf(raw_len)
		rc := zlib.uncompress(
			raw_data(transposed),
			&dest_len,
			raw_data(payload),
			zlib.uLong(len(payload)),
		)
		if rc != zlib.OK || int(dest_len) != raw_len {
			delete(out_arr, allocator)
			return nil, 0, false
		}
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
		transposed, t_err := make([]u8, raw_len, context.temp_allocator)
		if t_err != nil {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		defer delete(transposed, context.temp_allocator)

		dest_len := zlib.uLongf(raw_len)
		rc := zlib.uncompress(
			raw_data(transposed),
			&dest_len,
			raw_data(payload),
			zlib.uLong(len(payload)),
		)
		if rc != zlib.OK || int(dest_len) != raw_len {
			delete(out_arr, allocator)
			return nil, 0, false
		}
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
		gcd_raw, g_err := make([]u8, raw_len, context.temp_allocator)
		if g_err != nil {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		defer delete(gcd_raw, context.temp_allocator)

		dest_len := zlib.uLongf(raw_len)
		rc := zlib.uncompress(
			raw_data(gcd_raw),
			&dest_len,
			raw_data(payload),
			zlib.uLong(len(payload)),
		)
		if rc != zlib.OK || int(dest_len) != raw_len {
			delete(out_arr, allocator)
			return nil, 0, false
		}
		pos := 0
		for b0 := 0; b0 < count; b0 += _U64_GCD_BLOCK {
			m := min(_U64_GCD_BLOCK, count - b0)
			hdr, h_ok := _read_varint_u64(gcd_raw, &pos)
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
			bval, b_ok := _read_varint_u64(gcd_raw, &pos)
			if !b_ok || (base_div && bval > max(u64) / g) {
				delete(out_arr, allocator)
				return nil, 0, false
			}
			out_arr[b0] = bval * g if base_div else bval
			for j in 1 ..< m {
				q, q_ok := _read_zigzag_i64(gcd_raw, &pos)
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
		if pos != raw_len {
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
	if len(blob) >= SAMPLES_HEADER_LEN &&
	   blob[0] == SAMPLES_U64_MAGIC_0 &&
	   blob[1] == SAMPLES_U64_MAGIC_1 {
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

	fvals, f_ok := decompress_samples_f64(blob, context.temp_allocator)
	if !f_ok {
		return nil, false
	}
	defer delete(fvals, context.temp_allocator)
	arr, err := make([]i64, len(fvals), allocator)
	if err != nil {
		return nil, false
	}
	for f, i in fvals {
		if f > 0.0 {
			scaled := f * 1_000_000.0
			arr[i] = scaled >= f64(max(i64)) ? max(i64) : i64(math.round(scaled))
		}
	}
	return arr, true
}
