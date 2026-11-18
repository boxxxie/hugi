package hugi_store

import "core:c"
import "vendor:compress/lz4"
import "vendor:zlib"

Codec :: enum u8 {
	Raw      = 0,
	LZ4_BSS  = 1,
	Zlib_BSS = 2,
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

/*
Losslessly compresses a `[]f64` sample array using 8-way Byte-Stream-Split followed by
Zlib or LZ4. Falls back to `.Raw` whenever compression does not reduce byte length.
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

	if codec != .Raw && n > 2 {
		transposed, t_err := make([]u8, raw_len, context.temp_allocator)
		if t_err == nil {
			defer delete(transposed, context.temp_allocator)
			for s, i in samples {
				le := transmute(u64le)s
				b := transmute([8]u8)le
				for lane in 0 ..< 8 {
					transposed[lane * n + i] = b[lane]
				}
			}

			switch codec {
			case .Zlib_BSS:
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
						6,
					)
					comp_len := int(dest_len)
					if rc == zlib.OK && comp_len > 0 && comp_len < raw_len {
						buf, a_err := make([]u8, SAMPLES_HEADER_LEN + comp_len, allocator)
						if a_err != nil {
							return nil, false
						}
						buf[0] = SAMPLES_MAGIC_0
						buf[1] = SAMPLES_MAGIC_1
						buf[2] = u8(Codec.Zlib_BSS)
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
			case .Raw:
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
	if count < 0 || count > 10_000_000 || raw_len != count * 8 {
		return nil, false
	}
	if count == 0 {
		arr, err := make([]f64, 0, allocator)
		return arr, err == nil
	}

	payload := blob[SAMPLES_HEADER_LEN:]
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
	case .Zlib_BSS:
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
	case .Raw:
	}

	for i in 0 ..< count {
		b: [8]u8
		for lane in 0 ..< 8 {
			b[lane] = transposed[lane * count + i]
		}
		out_arr[i] = transmute(f64)(transmute(u64le)b)
	}
	return out_arr, true
}

/*
Compresses an arbitrary byte buffer with Zlib (storing raw bytes if compression does not shrink).
*/
@(require_results)
compress_bytes_zlib :: proc(src: []u8, allocator := context.allocator) -> (out: []u8, ok: bool) {
	raw_len := len(src)
	if raw_len > 16 {
		bound := int(zlib.compressBound(zlib.uLong(raw_len)))
		comp, c_err := make([]u8, bound, context.temp_allocator)
		if c_err == nil {
			defer delete(comp, context.temp_allocator)
			dest_len := zlib.uLongf(bound)
			rc := zlib.compress2(raw_data(comp), &dest_len, raw_data(src), zlib.uLong(raw_len), 6)
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
