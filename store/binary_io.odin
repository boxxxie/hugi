package hugi_store

import "base:runtime"
import "core:strings"

@(private)
_Format_Reader :: struct {
	data: []u8,
	pos:  int,
}

@(private)
_write_u32_le :: proc(dst: []u8, v: u32) {
	le := u32le(v)
	b := transmute([4]u8)le
	copy(dst[:4], b[:])
}

@(private, require_results)
_read_u32_le :: proc(src: []u8) -> u32 {
	b: [4]u8
	copy(b[:], src[:4])
	return u32(transmute(u32le)b)
}

@(private)
_fmt_append_varint_u64 :: proc(buf: ^[dynamic]u8, v: u64) {
	n := v
	for n >= 0x80 {
		append(buf, u8(n & 0x7F) | 0x80)
		n >>= 7
	}
	append(buf, u8(n))
}

@(private)
_fmt_append_zigzag_i64 :: proc(buf: ^[dynamic]u8, v: i64) {
	uv := u64(v)
	_fmt_append_varint_u64(buf, (uv << 1) ~ u64(v >> 63))
}

@(private)
_fmt_append_u32_le :: proc(buf: ^[dynamic]u8, v: u32) {
	le := u32le(v)
	b := transmute([4]u8)le
	append(buf, ..b[:])
}

@(private)
_fmt_append_u64_le :: proc(buf: ^[dynamic]u8, v: u64) {
	le := u64le(v)
	b := transmute([8]u8)le
	append(buf, ..b[:])
}

@(private)
_fmt_append_f64_le :: proc(buf: ^[dynamic]u8, v: f64) {
	_fmt_append_u64_le(buf, transmute(u64)v)
}

@(private)
_fmt_append_str :: proc(buf: ^[dynamic]u8, s: string) {
	_fmt_append_varint_u64(buf, u64(len(s)))
	if len(s) > 0 {
		append(buf, ..transmute([]u8)s)
	}
}

@(private, require_results)
_fmt_read_u8 :: proc(r: ^_Format_Reader) -> (u8, bool) {
	if r.pos + 1 > len(r.data) {
		return 0, false
	}
	v := r.data[r.pos]
	r.pos += 1
	return v, true
}

@(private, require_results)
_fmt_read_u32_le :: proc(r: ^_Format_Reader) -> (u32, bool) {
	if r.pos + 4 > len(r.data) {
		return 0, false
	}
	b: [4]u8
	copy(b[:], r.data[r.pos:r.pos + 4])
	r.pos += 4
	return u32(transmute(u32le)b), true
}

@(private, require_results)
_fmt_read_u64_le :: proc(r: ^_Format_Reader) -> (u64, bool) {
	if r.pos + 8 > len(r.data) {
		return 0, false
	}
	b: [8]u8
	copy(b[:], r.data[r.pos:r.pos + 8])
	r.pos += 8
	return u64(transmute(u64le)b), true
}

@(private, require_results)
_fmt_read_f64_le :: proc(r: ^_Format_Reader) -> (val: f64, ok: bool) {
	v := _fmt_read_u64_le(r) or_return
	return transmute(f64)v, true
}

@(private, require_results)
_fmt_read_varint_u64 :: proc(r: ^_Format_Reader) -> (val: u64, ok: bool) {
	shift: uint = 0
	for shift < 64 {
		if r.pos >= len(r.data) {
			return 0, false
		}
		b := r.data[r.pos]
		r.pos += 1
		val |= u64(b & 0x7F) << shift
		if (b & 0x80) == 0 {
			return val, true
		}
		shift += 7
	}
	return 0, false
}

@(private, require_results)
_fmt_read_varint_u32 :: proc(r: ^_Format_Reader) -> (val: u32, ok: bool) {
	v := _fmt_read_varint_u64(r) or_return
	if v > u64(max(u32)) {
		return 0, false
	}
	return u32(v), true
}

@(private, require_results)
_fmt_read_varint_nonneg_int :: proc(r: ^_Format_Reader) -> (val: int, ok: bool) {
	v := _fmt_read_varint_u64(r) or_return
	if v > u64(max(int)) {
		return 0, false
	}
	return int(v), true
}

@(private, require_results)
_fmt_read_zigzag_i64 :: proc(r: ^_Format_Reader) -> (val: i64, ok: bool) {
	uv := _fmt_read_varint_u64(r) or_return
	return i64((uv >> 1) ~ u64(-i64(uv & 1))), true
}

@(private, require_results)
_fmt_read_str :: proc(
	r: ^_Format_Reader,
	allocator: runtime.Allocator,
) -> (
	val: string,
	ok: bool,
) {
	n_u := _fmt_read_varint_u64(r) or_return
	if n_u > u64(len(r.data) - r.pos) {
		return "", false
	}
	n := int(n_u)
	s := strings.clone(string(r.data[r.pos:r.pos + n]), allocator)
	r.pos += n
	return s, true
}
