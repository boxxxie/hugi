package hugi_store

import obench "../deps/obench/obench"
import xitdb "../deps/xitdb/xitdb"
import hugi "../hugi"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:slice"
import "core:strings"

Store_Write_Options :: struct {
	use_symbol_table:    bool,
	use_descriptors:     bool,
	use_domain_f64:      bool,
	use_columnar_rollup: bool,
	keep_hot_runs:       int,
	use_rational_time:   bool,
	use_catalog:         bool,
	auto_seal_cold:      bool,
	cold_chunk_runs:     int,
}

@(require_results)
default_store_write_options :: proc() -> Store_Write_Options {
	return Store_Write_Options {
		use_symbol_table = true,
		use_descriptors = true,
		use_domain_f64 = true,
		use_columnar_rollup = true,
		keep_hot_runs = 0,
		use_rational_time = true,
		use_catalog = true,
		auto_seal_cold = true,
		cold_chunk_runs = 32,
	}
}

HSYM_MAGIC :: "HSYM\x01\x00\x00\x00"
HDSC_MAGIC :: "HDSC\x01\x00\x00\x00"
HSNP_MAGIC :: "HSNP\x01\x00\x00\x00"
HCAT_MAGIC :: "HCAT\x01\x00\x00\x00"
CZPK_V3_MAGIC :: "CZPK\x03\x00\x00\x00"
CZPK_V4_MAGIC :: "CZPK\x04\x00\x00\x00"
CZCH_MAGIC :: "CZCH\x01\x00\x00\x00"
CZCH_V2_MAGIC :: "CZCH\x02\x00\x00\x00"

@(private)
_V3_PKT_FLAG_SYMS :: u8(1 << 0)
@(private)
_V3_PKT_FLAG_DESCS :: u8(1 << 1)
@(private)
_V3_PKT_FLAG_SELECTIVE :: u8(1 << 2)

@(private)
_REC_FLAG_CUSTOM_RANK :: u32(1 << 0)
@(private)
_REC_FLAG_FOOTPRINT :: u32(1 << 1)
@(private)
_REC_FLAG_PEAK_HEAP :: u32(1 << 2)
@(private)
_REC_FLAG_ERROR :: u32(1 << 3)
@(private)
_REC_FLAG_ZERO_ALLOC_FAILED :: u32(1 << 4)
@(private)
_REC_FLAG_METRICS :: u32(1 << 5)
@(private)
_REC_FLAG_HEAP_ALLOCS :: u32(1 << 6)
@(private)
_REC_FLAG_TEMP_ALLOCS :: u32(1 << 7)
@(private)
_REC_FLAG_CYCLES :: u32(1 << 8)
@(private)
_REC_FLAG_NO_SAMPLES :: u32(1 << 9)
@(private)
_REC_FLAG_CUSTOM_MBS :: u32(1 << 10)

@(private)
_V3_Reader :: struct {
	data: []u8,
	pos:  int,
}

@(private)
_v3_append_varint_u64 :: proc(buf: ^[dynamic]u8, v: u64) {
	n := v
	for n >= 0x80 {
		append(buf, u8(n & 0x7F) | 0x80)
		n >>= 7
	}
	append(buf, u8(n))
}

@(private)
_v3_append_zigzag_i64 :: proc(buf: ^[dynamic]u8, v: i64) {
	uv := u64(v)
	_v3_append_varint_u64(buf, (uv << 1) ~ u64(v >> 63))
}

@(private)
_v3_append_u32_le :: proc(buf: ^[dynamic]u8, v: u32) {
	le := u32le(v)
	b := transmute([4]u8)le
	append(buf, ..b[:])
}

@(private)
_v3_append_u64_le :: proc(buf: ^[dynamic]u8, v: u64) {
	le := u64le(v)
	b := transmute([8]u8)le
	append(buf, ..b[:])
}

@(private)
_v3_append_f64_le :: proc(buf: ^[dynamic]u8, v: f64) {
	_v3_append_u64_le(buf, transmute(u64)v)
}

@(private)
_v3_append_str :: proc(buf: ^[dynamic]u8, s: string) {
	_v3_append_varint_u64(buf, u64(len(s)))
	if len(s) > 0 {
		append(buf, ..transmute([]u8)s)
	}
}

@(private, require_results)
_v3_read_u8 :: proc(r: ^_V3_Reader) -> (u8, bool) {
	if r.pos + 1 > len(r.data) {
		return 0, false
	}
	v := r.data[r.pos]
	r.pos += 1
	return v, true
}

@(private, require_results)
_v3_read_u32_le :: proc(r: ^_V3_Reader) -> (u32, bool) {
	if r.pos + 4 > len(r.data) {
		return 0, false
	}
	b: [4]u8
	copy(b[:], r.data[r.pos:r.pos + 4])
	r.pos += 4
	return u32(transmute(u32le)b), true
}

@(private, require_results)
_v3_read_u64_le :: proc(r: ^_V3_Reader) -> (u64, bool) {
	if r.pos + 8 > len(r.data) {
		return 0, false
	}
	b: [8]u8
	copy(b[:], r.data[r.pos:r.pos + 8])
	r.pos += 8
	return u64(transmute(u64le)b), true
}

@(private, require_results)
_v3_read_f64_le :: proc(r: ^_V3_Reader) -> (val: f64, ok: bool) {
	v := _v3_read_u64_le(r) or_return
	return transmute(f64)v, true
}

@(private, require_results)
_v3_read_varint_u64 :: proc(r: ^_V3_Reader) -> (val: u64, ok: bool) {
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
_v3_read_zigzag_i64 :: proc(r: ^_V3_Reader) -> (val: i64, ok: bool) {
	uv := _v3_read_varint_u64(r) or_return
	return i64((uv >> 1) ~ u64(-i64(uv & 1))), true
}

@(private, require_results)
_v3_read_str :: proc(r: ^_V3_Reader, allocator: runtime.Allocator) -> (val: string, ok: bool) {
	n_u := _v3_read_varint_u64(r) or_return
	if n_u > u64(len(r.data) - r.pos) {
		return "", false
	}
	n := int(n_u)
	s := strings.clone(string(r.data[r.pos:r.pos + n]), allocator)
	r.pos += n
	return s, true
}

// ── Technique 1: Global Root Symbol Table ───────────────────────────────────

@(private)
_Symbol_Table :: struct {
	items:         [dynamic]string, // items[0] == ""
	by_str:        map[string]u32,
	initial_count: int,
	allocator:     runtime.Allocator,
}

@(private)
_sym_table_init :: proc(allocator := context.temp_allocator) -> _Symbol_Table {
	tab := _Symbol_Table {
		items     = make([dynamic]string, allocator),
		by_str    = make(map[string]u32, allocator),
		allocator = allocator,
	}
	append(&tab.items, strings.clone("", allocator))
	tab.by_str[tab.items[0]] = 0
	return tab
}

@(private)
_sym_table_destroy :: proc(tab: ^_Symbol_Table) {
	if tab == nil {
		return
	}
	for s in tab.items {
		delete(s, tab.allocator)
	}
	delete(tab.items)
	delete(tab.by_str)
	tab^ = {}
}

@(private, require_results)
_sym_intern :: proc(tab: ^_Symbol_Table, s: string) -> u32 {
	if s == "" {
		return 0
	}
	if id, found := tab.by_str[s]; found {
		return id
	}
	id := u32(len(tab.items))
	cloned := strings.clone(s, tab.allocator)
	append(&tab.items, cloned)
	tab.by_str[cloned] = id
	return id
}

@(private, require_results)
_sym_get :: proc(tab: _Symbol_Table, id: u32) -> (string, bool) {
	if int(id) >= len(tab.items) {
		return "", false
	}
	return tab.items[id], true
}

@(private, require_results)
_sym_table_decode :: proc(blob: []u8, tab: ^_Symbol_Table) -> bool {
	if len(blob) < len(HSYM_MAGIC) || string(blob[:len(HSYM_MAGIC)]) != HSYM_MAGIC {
		return false
	}
	raw, dec_ok := decompress_bytes_zlib(blob[len(HSYM_MAGIC):], context.temp_allocator)
	if !dec_ok {
		return false
	}
	defer delete(raw, context.temp_allocator)

	rd := _V3_Reader {
		data = raw,
	}
	count := int(_v3_read_varint_u64(&rd) or_return)
	if count < 0 || count > 10_000_000 {
		return false
	}
	for _ in 0 ..< count {
		n_u := _v3_read_varint_u64(&rd) or_return
		if n_u > u64(len(rd.data) - rd.pos) {
			return false
		}
		n := int(n_u)
		s := string(rd.data[rd.pos:rd.pos + n])
		rd.pos += n
		_ = _sym_intern(tab, s)
	}
	tab.initial_count = len(tab.items)
	return rd.pos == len(rd.data)
}

@(private, require_results)
_sym_table_encode :: proc(
	tab: _Symbol_Table,
	zlib_level: c.int,
	allocator := context.temp_allocator,
) -> (
	blob: []u8,
	ok: bool,
) {
	raw := make([dynamic]u8, 0, max(len(tab.items) * 20, 64), context.temp_allocator)
	defer delete(raw)

	extra := max(len(tab.items) - 1, 0)
	_v3_append_varint_u64(&raw, u64(extra))
	for i in 1 ..< len(tab.items) {
		_v3_append_str(&raw, tab.items[i])
	}

	comp := compress_bytes_zlib(raw[:], context.temp_allocator, zlib_level) or_return
	defer delete(comp, context.temp_allocator)

	out := make([]u8, len(HSYM_MAGIC) + len(comp), allocator)
	copy(out[:len(HSYM_MAGIC)], transmute([]u8)string(HSYM_MAGIC))
	copy(out[len(HSYM_MAGIC):], comp)
	return out, true
}

@(private, require_results)
_sym_table_load_from_moment :: proc(
	moment: xitdb.Read_Hash_Map,
	allocator := context.temp_allocator,
) -> (
	tab: _Symbol_Table,
	had_existing: bool,
) {
	tab = _sym_table_init(allocator)
	scur, err := xitdb.hash_map_get_cursor(moment, "symbols")
	if err != nil || scur == nil {
		tab.initial_count = len(tab.items)
		return tab, false
	}
	blob, b_err := xitdb.cursor_read_bytes(scur.?, 0, context.temp_allocator)
	if b_err != nil {
		tab.initial_count = len(tab.items)
		return tab, false
	}
	defer delete(blob, context.temp_allocator)
	if !_sym_table_decode(blob, &tab) {
		tab.initial_count = len(tab.items)
		return tab, false
	}
	return tab, true
}

// ── Technique 2: Static Bench Descriptor Table ──────────────────────────────

@(private)
_DESC_FLAG_HAS_PARAM :: u8(1 << 0)
@(private)
_DESC_FLAG_HAS_THREADS :: u8(1 << 1)
@(private)
_DESC_FLAG_CUSTOM_FULL :: u8(1 << 2)
@(private)
_DESC_FLAG_FULL_EQ_NAME :: u8(1 << 3)

@(private)
_Bench_Desc :: struct {
	group_sym:       u32,
	name_sym:        u32,
	custom_full_sym: u32,
	param:           i64,
	threads:         i64,
	bytes_per_op:    u64,
	items_per_op:    u64,
	flags:           u8,
}

@(private)
_Descriptor_Table :: struct {
	items:         [dynamic]_Bench_Desc,
	by_desc:       map[_Bench_Desc]u32,
	initial_count: int,
	allocator:     runtime.Allocator,
}

@(private)
_desc_table_init :: proc(allocator := context.temp_allocator) -> _Descriptor_Table {
	return _Descriptor_Table {
		items = make([dynamic]_Bench_Desc, allocator),
		by_desc = make(map[_Bench_Desc]u32, allocator),
		allocator = allocator,
	}
}

@(private)
_desc_table_destroy :: proc(dt: ^_Descriptor_Table) {
	if dt == nil {
		return
	}
	delete(dt.items)
	delete(dt.by_desc)
	dt^ = {}
}

@(private, require_results)
_desc_intern :: proc(dt: ^_Descriptor_Table, syms: ^_Symbol_Table, r: hugi.Record) -> u32 {
	canonical := obench.format_full_name(
		r.group_name,
		r.name,
		r.param,
		r.has_param,
		r.threads,
		r.has_threads,
		context.temp_allocator,
	)
	defer delete(canonical, context.temp_allocator)

	flags := u8(0)
	if r.has_param {
		flags |= _DESC_FLAG_HAS_PARAM
	}
	if r.has_threads {
		flags |= _DESC_FLAG_HAS_THREADS
	}

	custom_full_sym := u32(0)
	if r.full_name != canonical {
		if r.full_name == r.name {
			flags |= _DESC_FLAG_FULL_EQ_NAME
		} else {
			flags |= _DESC_FLAG_CUSTOM_FULL
			custom_full_sym = _sym_intern(syms, r.full_name)
		}
	}

	desc := _Bench_Desc {
		group_sym       = _sym_intern(syms, r.group_name),
		name_sym        = _sym_intern(syms, r.name),
		custom_full_sym = custom_full_sym,
		param           = r.has_param ? i64(r.param) : 0,
		threads         = r.has_threads ? i64(r.threads) : 0,
		bytes_per_op    = r.bytes_per_op,
		items_per_op    = r.items_per_op,
		flags           = flags,
	}
	if id, found := dt.by_desc[desc]; found {
		return id
	}
	id := u32(len(dt.items))
	append(&dt.items, desc)
	dt.by_desc[desc] = id
	return id
}

@(private, require_results)
_desc_materialize_strings :: proc(
	dt: _Descriptor_Table,
	syms: _Symbol_Table,
	desc_id: u32,
	allocator: runtime.Allocator,
) -> (
	desc: _Bench_Desc,
	group_name: string,
	name: string,
	full_name: string,
	ok: bool,
) {
	if int(desc_id) >= len(dt.items) {
		return {}, "", "", "", false
	}
	desc = dt.items[desc_id]
	raw_group := _sym_get(syms, desc.group_sym) or_return
	raw_name := _sym_get(syms, desc.name_sym) or_return
	has_param := (desc.flags & _DESC_FLAG_HAS_PARAM) != 0
	has_threads := (desc.flags & _DESC_FLAG_HAS_THREADS) != 0

	group_name = strings.clone(raw_group, allocator)
	name = strings.clone(raw_name, allocator)

	if (desc.flags & _DESC_FLAG_FULL_EQ_NAME) != 0 {
		full_name = strings.clone(raw_name, allocator)
	} else if (desc.flags & _DESC_FLAG_CUSTOM_FULL) != 0 {
		raw_custom, c_ok := _sym_get(syms, desc.custom_full_sym)
		if !c_ok {
			delete(group_name, allocator)
			delete(name, allocator)
			return {}, "", "", "", false
		}
		full_name = strings.clone(raw_custom, allocator)
	} else {
		full_name = obench.format_full_name(
			raw_group,
			raw_name,
			int(desc.param),
			has_param,
			int(desc.threads),
			has_threads,
			allocator,
		)
	}
	return desc, group_name, name, full_name, true
}

@(private, require_results)
_desc_table_decode :: proc(blob: []u8, dt: ^_Descriptor_Table) -> bool {
	if len(blob) < len(HDSC_MAGIC) || string(blob[:len(HDSC_MAGIC)]) != HDSC_MAGIC {
		return false
	}
	raw, dec_ok := decompress_bytes_zlib(blob[len(HDSC_MAGIC):], context.temp_allocator)
	if !dec_ok {
		return false
	}
	defer delete(raw, context.temp_allocator)

	rd := _V3_Reader {
		data = raw,
	}
	count := int(_v3_read_varint_u64(&rd) or_return)
	if count < 0 || count > 10_000_000 {
		return false
	}
	for _ in 0 ..< count {
		flags := _v3_read_u8(&rd) or_return
		gs := u32(_v3_read_varint_u64(&rd) or_return)
		ns := u32(_v3_read_varint_u64(&rd) or_return)
		cs := u32(0)
		if (flags & _DESC_FLAG_CUSTOM_FULL) != 0 {
			cs = u32(_v3_read_varint_u64(&rd) or_return)
		}
		param := i64(0)
		if (flags & _DESC_FLAG_HAS_PARAM) != 0 {
			param = _v3_read_zigzag_i64(&rd) or_return
		}
		threads := i64(0)
		if (flags & _DESC_FLAG_HAS_THREADS) != 0 {
			threads = _v3_read_zigzag_i64(&rd) or_return
		}
		bpo := _v3_read_varint_u64(&rd) or_return
		ipo := _v3_read_varint_u64(&rd) or_return

		d := _Bench_Desc {
			group_sym       = gs,
			name_sym        = ns,
			custom_full_sym = cs,
			param           = param,
			threads         = threads,
			bytes_per_op    = bpo,
			items_per_op    = ipo,
			flags           = flags,
		}
		id := u32(len(dt.items))
		append(&dt.items, d)
		dt.by_desc[d] = id
	}
	dt.initial_count = len(dt.items)
	return rd.pos == len(rd.data)
}

@(private, require_results)
_desc_table_encode :: proc(
	dt: _Descriptor_Table,
	zlib_level: c.int,
	allocator := context.temp_allocator,
) -> (
	blob: []u8,
	ok: bool,
) {
	raw := make([dynamic]u8, 0, max(len(dt.items) * 12, 32), context.temp_allocator)
	defer delete(raw)

	_v3_append_varint_u64(&raw, u64(len(dt.items)))
	for d in dt.items {
		append(&raw, d.flags)
		_v3_append_varint_u64(&raw, u64(d.group_sym))
		_v3_append_varint_u64(&raw, u64(d.name_sym))
		if (d.flags & _DESC_FLAG_CUSTOM_FULL) != 0 {
			_v3_append_varint_u64(&raw, u64(d.custom_full_sym))
		}
		if (d.flags & _DESC_FLAG_HAS_PARAM) != 0 {
			_v3_append_zigzag_i64(&raw, d.param)
		}
		if (d.flags & _DESC_FLAG_HAS_THREADS) != 0 {
			_v3_append_zigzag_i64(&raw, d.threads)
		}
		_v3_append_varint_u64(&raw, d.bytes_per_op)
		_v3_append_varint_u64(&raw, d.items_per_op)
	}

	comp := compress_bytes_zlib(raw[:], context.temp_allocator, zlib_level) or_return
	defer delete(comp, context.temp_allocator)

	out := make([]u8, len(HDSC_MAGIC) + len(comp), allocator)
	copy(out[:len(HDSC_MAGIC)], transmute([]u8)string(HDSC_MAGIC))
	copy(out[len(HDSC_MAGIC):], comp)
	return out, true
}

@(private, require_results)
_desc_table_load_from_moment :: proc(
	moment: xitdb.Read_Hash_Map,
	allocator := context.temp_allocator,
) -> (
	dt: _Descriptor_Table,
	had_existing: bool,
) {
	dt = _desc_table_init(allocator)
	dcur, err := xitdb.hash_map_get_cursor(moment, "descriptors")
	if err != nil || dcur == nil {
		return dt, false
	}
	blob, b_err := xitdb.cursor_read_bytes(dcur.?, 0, context.temp_allocator)
	if b_err != nil {
		return dt, false
	}
	defer delete(blob, context.temp_allocator)
	if !_desc_table_decode(blob, &dt) {
		return dt, false
	}
	return dt, true
}

// ── Packed Snapshot Blob (HSNP\x01) ─────────────────────────────────────────

@(private)
_Snap_Ref :: struct {
	run_ord: u32,
	rec_idx: u32,
}

@(private, require_results)
_decode_hsnp_blob :: proc(
	blob: []u8,
	syms: _Symbol_Table,
	out_map: ^map[string]_Snap_Ref,
	allocator := context.temp_allocator,
) -> bool {
	if len(blob) < len(HSNP_MAGIC) || string(blob[:len(HSNP_MAGIC)]) != HSNP_MAGIC {
		return false
	}
	raw, dec_ok := decompress_bytes_zlib(blob[len(HSNP_MAGIC):], context.temp_allocator)
	if !dec_ok {
		return false
	}
	defer delete(raw, context.temp_allocator)

	rd := _V3_Reader {
		data = raw,
	}
	flags := _v3_read_u8(&rd) or_return
	sym_keys := (flags & 1) != 0
	count := int(_v3_read_varint_u64(&rd) or_return)
	if count < 0 || count > 10_000_000 {
		return false
	}
	for _ in 0 ..< count {
		key: string
		if sym_keys {
			sid := u32(_v3_read_varint_u64(&rd) or_return)
			raw_k, s_ok := _sym_get(syms, sid)
			if !s_ok {
				return false
			}
			key = strings.clone(raw_k, allocator)
		} else {
			key = _v3_read_str(&rd, allocator) or_return
		}
		ro := u32(_v3_read_varint_u64(&rd) or_return)
		ri := u32(_v3_read_varint_u64(&rd) or_return)
		out_map[key] = _Snap_Ref {
			run_ord = ro,
			rec_idx = ri,
		}
	}
	return rd.pos == len(rd.data)
}

@(private, require_results)
_encode_hsnp_blob :: proc(
	m: map[string]_Snap_Ref,
	syms: ^_Symbol_Table,
	use_syms: bool,
	zlib_level: c.int,
	allocator := context.temp_allocator,
) -> (
	blob: []u8,
	ok: bool,
) {
	keys := make([dynamic]string, 0, len(m), context.temp_allocator)
	defer delete(keys)
	for k in m {
		append(&keys, k)
	}
	slice.sort(keys[:])

	raw := make([dynamic]u8, 0, max(len(keys) * 16, 32), context.temp_allocator)
	defer delete(raw)

	append(&raw, u8(1) if use_syms else u8(0))
	_v3_append_varint_u64(&raw, u64(len(keys)))
	for k in keys {
		ref := m[k]
		if use_syms {
			_v3_append_varint_u64(&raw, u64(_sym_intern(syms, k)))
		} else {
			_v3_append_str(&raw, k)
		}
		_v3_append_varint_u64(&raw, u64(ref.run_ord))
		_v3_append_varint_u64(&raw, u64(ref.rec_idx))
	}

	comp := compress_bytes_zlib(raw[:], context.temp_allocator, zlib_level) or_return
	defer delete(comp, context.temp_allocator)

	out := make([]u8, len(HSNP_MAGIC) + len(comp), allocator)
	copy(out[:len(HSNP_MAGIC)], transmute([]u8)string(HSNP_MAGIC))
	copy(out[len(HSNP_MAGIC):], comp)
	return out, true
}

// ── Consolidated Moment Catalog (HCAT\x01) ──────────────────────────────────

@(private)
_CAT_FLAG_DESCS :: u8(1 << 0)
@(private)
_CAT_FLAG_COLD_OVERRIDE :: u8(1 << 1)

@(private)
_CAT_RUN_COLD :: u8(1 << 0)
@(private)
_CAT_RUN_SAME_LANG :: u8(1 << 1)
@(private)
_CAT_RUN_SAME_COMMIT :: u8(1 << 2)
@(private)
_CAT_RUN_SAME_SUITE :: u8(1 << 3)

@(private)
_Catalog_Run_Entry :: struct {
	run_id:         string,
	commit:         string,
	lang:           string,
	suite_name:     string,
	timestamp_unix: i64,
	record_count:   int,
	total_samples:  int,
	in_cold_chunk:  bool,
}

@(private)
_Moment_Catalog :: struct {
	syms:              _Symbol_Table,
	descs:             _Descriptor_Table,
	runs:              [dynamic]_Catalog_Run_Entry,
	run_ord_by_key:    map[string]int,
	snaps:             map[string]map[string]_Snap_Ref,
	has_cold_override: bool,
	allocator:         runtime.Allocator,
}

@(private)
_catalog_init :: proc(allocator := context.allocator) -> _Moment_Catalog {
	return _Moment_Catalog {
		syms = _sym_table_init(allocator),
		descs = _desc_table_init(allocator),
		runs = make([dynamic]_Catalog_Run_Entry, allocator),
		run_ord_by_key = make(map[string]int, allocator),
		snaps = make(map[string]map[string]_Snap_Ref, allocator),
		allocator = allocator,
	}
}

@(private)
_catalog_destroy :: proc(cat: ^_Moment_Catalog) {
	if cat == nil {
		return
	}
	_sym_table_destroy(&cat.syms)
	_desc_table_destroy(&cat.descs)
	for &r in cat.runs {
		delete(r.run_id, cat.allocator)
		delete(r.commit, cat.allocator)
		delete(r.lang, cat.allocator)
		delete(r.suite_name, cat.allocator)
	}
	delete(cat.runs)
	for k in cat.run_ord_by_key {
		delete(k, cat.allocator)
	}
	delete(cat.run_ord_by_key)
	for lk, &m in cat.snaps {
		delete(lk, cat.allocator)
		for bk in m {
			delete(bk, cat.allocator)
		}
		delete(m)
	}
	delete(cat.snaps)
	cat^ = {}
}

@(private)
_catalog_upsert_run :: proc(
	cat: ^_Moment_Catalog,
	pkt: hugi.Run_Packet,
	in_cold: bool,
) -> (
	run_ord: int,
	is_new: bool,
) {
	eff_lang := pkt.lang != "" ? pkt.lang : "odin"
	run_key := fmt.tprintf("%s:%s", eff_lang, pkt.run_id)
	tot_samples := 0
	for &r in pkt.records {
		tot_samples += len(r.samples_batch_ns) > 0 ? len(r.samples_batch_ns) : r.samples
	}
	if ord, found := cat.run_ord_by_key[run_key]; found {
		e := &cat.runs[ord]
		delete(e.run_id, cat.allocator)
		delete(e.commit, cat.allocator)
		delete(e.lang, cat.allocator)
		delete(e.suite_name, cat.allocator)
		e^ = _Catalog_Run_Entry {
			run_id         = strings.clone(pkt.run_id, cat.allocator),
			commit         = strings.clone(pkt.commit, cat.allocator),
			lang           = strings.clone(pkt.lang, cat.allocator),
			suite_name     = strings.clone(pkt.suite_name, cat.allocator),
			timestamp_unix = pkt.timestamp_unix,
			record_count   = len(pkt.records),
			total_samples  = tot_samples,
			in_cold_chunk  = in_cold,
		}
		return ord, false
	}

	ord := len(cat.runs)
	append(
		&cat.runs,
		_Catalog_Run_Entry {
			run_id = strings.clone(pkt.run_id, cat.allocator),
			commit = strings.clone(pkt.commit, cat.allocator),
			lang = strings.clone(pkt.lang, cat.allocator),
			suite_name = strings.clone(pkt.suite_name, cat.allocator),
			timestamp_unix = pkt.timestamp_unix,
			record_count = len(pkt.records),
			total_samples = tot_samples,
			in_cold_chunk = in_cold,
		},
	)
	cat.run_ord_by_key[strings.clone(run_key, cat.allocator)] = ord
	return ord, true
}

@(private)
_catalog_update_snaps :: proc(cat: ^_Moment_Catalog, pkt: hugi.Run_Packet, run_ord: int) {
	eff_lang := pkt.lang != "" ? pkt.lang : "odin"
	if eff_lang not_in cat.snaps {
		cat.snaps[strings.clone(eff_lang, cat.allocator)] = make(
			map[string]_Snap_Ref,
			cat.allocator,
		)
	}
	m := &cat.snaps[eff_lang]
	for r, rec_idx in pkt.records {
		key := r.full_name != "" ? r.full_name : r.name
		ref := _Snap_Ref {
			run_ord = u32(run_ord),
			rec_idx = u32(rec_idx),
		}
		if key in m {
			m[key] = ref
		} else {
			m[strings.clone(key, cat.allocator)] = ref
		}
	}
}

@(private, require_results)
_encode_catalog_blob :: proc(
	cat: ^_Moment_Catalog,
	use_descs: bool,
	zlib_level: c.int,
	allocator := context.temp_allocator,
) -> (
	blob: []u8,
	ok: bool,
) {
	// Map canonical/descriptor full_name -> desc_id so canonical snapshots avoid extra symbols.
	desc_by_full := make(map[string]u32, context.temp_allocator)
	defer {
		for k in desc_by_full {
			delete(k, context.temp_allocator)
		}
		delete(desc_by_full)
	}
	if use_descs {
		for _, did in cat.descs.items {
			_, _, _, full_name, m_ok := _desc_materialize_strings(
				cat.descs,
				cat.syms,
				u32(did),
				context.temp_allocator,
			)
			if m_ok {
				if full_name not_in desc_by_full {
					desc_by_full[full_name] = u32(did)
				} else {
					delete(full_name, context.temp_allocator)
				}
			}
		}
	}

	// Pre-intern all strings referenced by Runs and Snapshots before emitting Symbols table.
	for r in cat.runs {
		_ = _sym_intern(&cat.syms, r.lang)
		_ = _sym_intern(&cat.syms, r.commit)
		_ = _sym_intern(&cat.syms, r.suite_name)
	}
	langs := make([dynamic]string, 0, len(cat.snaps), context.temp_allocator)
	defer delete(langs)
	for lk, snap_m in cat.snaps {
		append(&langs, lk)
		_ = _sym_intern(&cat.syms, lk)
		for bk in snap_m {
			if !use_descs || (bk not_in desc_by_full) {
				_ = _sym_intern(&cat.syms, bk)
			}
		}
	}
	slice.sort(langs[:])

	raw := make(
		[dynamic]u8,
		0,
		max(len(cat.syms.items) * 20 + len(cat.runs) * 24, 128),
		context.temp_allocator,
	)
	defer delete(raw)

	flags := _CAT_FLAG_DESCS if use_descs else u8(0)
	if cat.has_cold_override {
		flags |= _CAT_FLAG_COLD_OVERRIDE
	}
	append(&raw, flags)

	// 1. Symbols section.
	extra := max(len(cat.syms.items) - 1, 0)
	_v3_append_varint_u64(&raw, u64(extra))
	for i in 1 ..< len(cat.syms.items) {
		_v3_append_str(&raw, cat.syms.items[i])
	}

	// 2. Descriptors section.
	if use_descs {
		_v3_append_varint_u64(&raw, u64(len(cat.descs.items)))
		for d in cat.descs.items {
			append(&raw, d.flags)
			_v3_append_varint_u64(&raw, u64(d.group_sym))
			_v3_append_varint_u64(&raw, u64(d.name_sym))
			if (d.flags & _DESC_FLAG_CUSTOM_FULL) != 0 {
				_v3_append_varint_u64(&raw, u64(d.custom_full_sym))
			}
			if (d.flags & _DESC_FLAG_HAS_PARAM) != 0 {
				_v3_append_zigzag_i64(&raw, d.param)
			}
			if (d.flags & _DESC_FLAG_HAS_THREADS) != 0 {
				_v3_append_zigzag_i64(&raw, d.threads)
			}
			_v3_append_varint_u64(&raw, d.bytes_per_op)
			_v3_append_varint_u64(&raw, d.items_per_op)
		}
	}

	// 3. Runs section.
	_v3_append_varint_u64(&raw, u64(len(cat.runs)))
	prev_ls: u32 = 0
	prev_cs: u32 = 0
	prev_ss: u32 = 0
	prev_ts: i64 = 0
	has_prev := false
	for r in cat.runs {
		ls := _sym_intern(&cat.syms, r.lang)
		cs := _sym_intern(&cat.syms, r.commit)
		ss := _sym_intern(&cat.syms, r.suite_name)

		rflags := u8(0)
		if r.in_cold_chunk {
			rflags |= _CAT_RUN_COLD
		}
		if has_prev && ls == prev_ls {
			rflags |= _CAT_RUN_SAME_LANG
		}
		if has_prev && cs == prev_cs {
			rflags |= _CAT_RUN_SAME_COMMIT
		}
		if has_prev && ss == prev_ss {
			rflags |= _CAT_RUN_SAME_SUITE
		}
		append(&raw, rflags)
		if (rflags & _CAT_RUN_SAME_LANG) == 0 {
			_v3_append_varint_u64(&raw, u64(ls))
		}
		_v3_append_str(&raw, r.run_id)
		if (rflags & _CAT_RUN_SAME_COMMIT) == 0 {
			_v3_append_varint_u64(&raw, u64(cs))
		}
		if (rflags & _CAT_RUN_SAME_SUITE) == 0 {
			_v3_append_varint_u64(&raw, u64(ss))
		}
		_v3_append_zigzag_i64(&raw, r.timestamp_unix - prev_ts)
		_v3_append_varint_u64(&raw, u64(r.record_count))
		_v3_append_varint_u64(&raw, u64(r.total_samples))

		prev_ls = ls
		prev_cs = cs
		prev_ss = ss
		prev_ts = r.timestamp_unix
		has_prev = true
	}

	// 4. Snapshots section.
	_v3_append_varint_u64(&raw, u64(len(langs)))
	for lk in langs {
		_v3_append_varint_u64(&raw, u64(_sym_intern(&cat.syms, lk)))
		snap_m := cat.snaps[lk]
		bkeys := make([dynamic]string, 0, len(snap_m), context.temp_allocator)
		for bk in snap_m {
			append(&bkeys, bk)
		}
		slice.sort(bkeys[:])
		_v3_append_varint_u64(&raw, u64(len(bkeys)))
		if len(bkeys) > 0 {
			common_ord := snap_m[bkeys[0]].run_ord
			all_same := true
			for bk in bkeys {
				if snap_m[bk].run_ord != common_ord {
					all_same = false
					break
				}
			}
			append(&raw, u8(1) if all_same else u8(0))
			if all_same {
				_v3_append_varint_u64(&raw, u64(common_ord))
			}
			for bk in bkeys {
				ref := snap_m[bk]
				if use_descs {
					if did, in_desc := desc_by_full[bk]; in_desc {
						_v3_append_varint_u64(&raw, u64(did) << 1)
					} else {
						_v3_append_varint_u64(&raw, (u64(_sym_intern(&cat.syms, bk)) << 1) | 1)
					}
				} else {
					_v3_append_varint_u64(&raw, (u64(_sym_intern(&cat.syms, bk)) << 1) | 1)
				}
				if !all_same {
					_v3_append_varint_u64(&raw, u64(ref.run_ord))
				}
				_v3_append_varint_u64(&raw, u64(ref.rec_idx))
			}
		}
		delete(bkeys)
	}

	comp := compress_bytes_zlib(raw[:], context.temp_allocator, zlib_level) or_return
	defer delete(comp, context.temp_allocator)

	out := make([]u8, len(HCAT_MAGIC) + len(comp), allocator)
	copy(out[:len(HCAT_MAGIC)], transmute([]u8)string(HCAT_MAGIC))
	copy(out[len(HCAT_MAGIC):], comp)
	return out, true
}

@(private, require_results)
_decode_catalog_blob :: proc(blob: []u8, cat: ^_Moment_Catalog) -> bool {
	if len(blob) < len(HCAT_MAGIC) || string(blob[:len(HCAT_MAGIC)]) != HCAT_MAGIC {
		return false
	}
	raw, dec_ok := decompress_bytes_zlib(blob[len(HCAT_MAGIC):], context.temp_allocator)
	if !dec_ok {
		return false
	}
	defer delete(raw, context.temp_allocator)

	rd := _V3_Reader {
		data = raw,
	}
	flags := _v3_read_u8(&rd) or_return
	has_descs := (flags & _CAT_FLAG_DESCS) != 0
	cat.has_cold_override = (flags & _CAT_FLAG_COLD_OVERRIDE) != 0

	// 1. Symbols section.
	sym_cnt := int(_v3_read_varint_u64(&rd) or_return)
	if sym_cnt < 0 || sym_cnt > 10_000_000 {
		return false
	}
	for _ in 0 ..< sym_cnt {
		n_u := _v3_read_varint_u64(&rd) or_return
		if n_u > u64(len(rd.data) - rd.pos) {
			return false
		}
		n := int(n_u)
		s := string(rd.data[rd.pos:rd.pos + n])
		rd.pos += n
		_ = _sym_intern(&cat.syms, s)
	}
	cat.syms.initial_count = len(cat.syms.items)

	// 2. Descriptors section.
	if has_descs {
		d_cnt := int(_v3_read_varint_u64(&rd) or_return)
		if d_cnt < 0 || d_cnt > 10_000_000 {
			return false
		}
		for _ in 0 ..< d_cnt {
			dflags := _v3_read_u8(&rd) or_return
			gs := u32(_v3_read_varint_u64(&rd) or_return)
			ns := u32(_v3_read_varint_u64(&rd) or_return)
			cs := u32(0)
			if (dflags & _DESC_FLAG_CUSTOM_FULL) != 0 {
				cs = u32(_v3_read_varint_u64(&rd) or_return)
			}
			param := i64(0)
			if (dflags & _DESC_FLAG_HAS_PARAM) != 0 {
				param = _v3_read_zigzag_i64(&rd) or_return
			}
			threads := i64(0)
			if (dflags & _DESC_FLAG_HAS_THREADS) != 0 {
				threads = _v3_read_zigzag_i64(&rd) or_return
			}
			bpo := _v3_read_varint_u64(&rd) or_return
			ipo := _v3_read_varint_u64(&rd) or_return

			d := _Bench_Desc {
				group_sym       = gs,
				name_sym        = ns,
				custom_full_sym = cs,
				param           = param,
				threads         = threads,
				bytes_per_op    = bpo,
				items_per_op    = ipo,
				flags           = dflags,
			}
			id := u32(len(cat.descs.items))
			append(&cat.descs.items, d)
			cat.descs.by_desc[d] = id
		}
		cat.descs.initial_count = len(cat.descs.items)
	}

	// 3. Runs section.
	run_cnt := int(_v3_read_varint_u64(&rd) or_return)
	if run_cnt < 0 || run_cnt > 10_000_000 {
		return false
	}
	reserve(&cat.runs, run_cnt)
	prev_ls: u32 = 0
	prev_cs: u32 = 0
	prev_ss: u32 = 0
	prev_ts: i64 = 0
	for i in 0 ..< run_cnt {
		rflags := _v3_read_u8(&rd) or_return
		ls := prev_ls
		if (rflags & _CAT_RUN_SAME_LANG) == 0 {
			ls = u32(_v3_read_varint_u64(&rd) or_return)
		}
		run_id := _v3_read_str(&rd, cat.allocator) or_return
		cs := prev_cs
		if (rflags & _CAT_RUN_SAME_COMMIT) == 0 {
			cs = u32(_v3_read_varint_u64(&rd) or_return)
		}
		ss := prev_ss
		if (rflags & _CAT_RUN_SAME_SUITE) == 0 {
			ss = u32(_v3_read_varint_u64(&rd) or_return)
		}
		ts_delta := _v3_read_zigzag_i64(&rd) or_return
		ts := prev_ts + ts_delta
		rec_cnt := int(_v3_read_varint_u64(&rd) or_return)
		tot_samples := int(_v3_read_varint_u64(&rd) or_return)

		raw_lang, l_ok := _sym_get(cat.syms, ls)
		if !l_ok {
			delete(run_id, cat.allocator)
			return false
		}
		raw_commit, c_ok := _sym_get(cat.syms, cs)
		if !c_ok {
			delete(run_id, cat.allocator)
			return false
		}
		raw_suite, s_ok := _sym_get(cat.syms, ss)
		if !s_ok {
			delete(run_id, cat.allocator)
			return false
		}

		eff_lang := raw_lang != "" ? raw_lang : "odin"
		rk := fmt.aprintf("%s:%s", eff_lang, run_id, allocator = cat.allocator)
		cat.run_ord_by_key[rk] = i
		append(
			&cat.runs,
			_Catalog_Run_Entry {
				run_id = run_id,
				commit = strings.clone(raw_commit, cat.allocator),
				lang = strings.clone(raw_lang, cat.allocator),
				suite_name = strings.clone(raw_suite, cat.allocator),
				timestamp_unix = ts,
				record_count = rec_cnt,
				total_samples = tot_samples,
				in_cold_chunk = (rflags & _CAT_RUN_COLD) != 0,
			},
		)

		prev_ls = ls
		prev_cs = cs
		prev_ss = ss
		prev_ts = ts
	}

	// 4. Snapshots section.
	desc_full_cache := make([]string, len(cat.descs.items), context.temp_allocator)
	defer {
		for s in desc_full_cache {
			if s != "" {
				delete(s, context.temp_allocator)
			}
		}
		delete(desc_full_cache, context.temp_allocator)
	}

	n_langs := int(_v3_read_varint_u64(&rd) or_return)
	if n_langs < 0 || n_langs > 10_000 {
		return false
	}
	for _ in 0 ..< n_langs {
		lsid := u32(_v3_read_varint_u64(&rd) or_return)
		raw_lk := _sym_get(cat.syms, lsid) or_return
		if raw_lk in cat.snaps {
			return false
		}
		snap_m := make(map[string]_Snap_Ref, cat.allocator)
		cat.snaps[strings.clone(raw_lk, cat.allocator)] = snap_m
		m_ptr := &cat.snaps[raw_lk]

		n_bkeys := int(_v3_read_varint_u64(&rd) or_return)
		if n_bkeys < 0 || n_bkeys > 10_000_000 {
			return false
		}
		if n_bkeys > 0 {
			sflags := _v3_read_u8(&rd) or_return
			all_same := (sflags & 1) != 0
			common_ord := u32(0)
			if all_same {
				common_ord = u32(_v3_read_varint_u64(&rd) or_return)
			}
			for _ in 0 ..< n_bkeys {
				tag := _v3_read_varint_u64(&rd) or_return
				bkey: string
				if (tag & 1) != 0 {
					sid := u32(tag >> 1)
					raw_bk := _sym_get(cat.syms, sid) or_return
					bkey = strings.clone(raw_bk, cat.allocator)
				} else {
					did := int(tag >> 1)
					if did < 0 || did >= len(cat.descs.items) {
						return false
					}
					if desc_full_cache[did] == "" {
						_, _, _, df, d_ok := _desc_materialize_strings(
							cat.descs,
							cat.syms,
							u32(did),
							context.temp_allocator,
						)
						if !d_ok {
							return false
						}
						desc_full_cache[did] = df
					}
					bkey = strings.clone(desc_full_cache[did], cat.allocator)
				}
				ro := common_ord
				if !all_same {
					ro = u32(_v3_read_varint_u64(&rd) or_return)
				}
				ri := u32(_v3_read_varint_u64(&rd) or_return)
				ref := _Snap_Ref {
					run_ord = ro,
					rec_idx = ri,
				}
				if bkey in m_ptr {
					m_ptr[bkey] = ref
					delete(bkey, cat.allocator)
				} else {
					m_ptr[bkey] = ref
				}
			}
		}
	}

	return rd.pos == len(rd.data)
}

// ── Shared Compression Helpers ──────────────────────────────────────────────

@(private, require_results)
_compress_sample_vec :: proc(
	samples: []f64,
	use_domain_f64: bool,
	allocator := context.temp_allocator,
) -> (
	blob: []u8,
	ok: bool,
) {
	if use_domain_f64 {
		return compress_samples_f64_best(samples, allocator)
	}
	return compress_samples_f64(samples, .Zlib_BSS, allocator)
}

@(private)
_rec_presence_flags :: proc(r: hugi.Record, rec_idx: int) -> u32 {
	flags := u32(0)
	if r.rank != rec_idx + 1 {
		flags |= _REC_FLAG_CUSTOM_RANK
	}
	if r.footprint_bytes != 0 {
		flags |= _REC_FLAG_FOOTPRINT
	}
	if r.peak_heap_bytes != 0 {
		flags |= _REC_FLAG_PEAK_HEAP
	}
	if r.error != "" {
		flags |= _REC_FLAG_ERROR
	}
	if r.zero_alloc_failed {
		flags |= _REC_FLAG_ZERO_ALLOC_FAILED
	}
	if len(r.metrics) > 0 {
		flags |= _REC_FLAG_METRICS
	}
	if r.allocs_per_op != 0 || r.resizes_per_op != 0 || r.alloc_bytes_per_op != 0 {
		flags |= _REC_FLAG_HEAP_ALLOCS
	}
	if r.temp_allocs_per_op != 0 || r.temp_bytes_per_op != 0 {
		flags |= _REC_FLAG_TEMP_ALLOCS
	}
	if r.median_cycles != 0 {
		flags |= _REC_FLAG_CYCLES
	}
	if len(r.samples_batch_ns) == 0 {
		flags |= _REC_FLAG_NO_SAMPLES
	} else if r.bytes_per_op == 0 && r.mb_per_sec != 0 {
		flags |= _REC_FLAG_CUSTOM_MBS
	}
	return flags
}

@(private)
_append_record_samples_as_f64 :: proc(dst: ^[dynamic]f64, r: hugi.Record) {
	ops := max(r.ops_per_sample, 1)
	for b in r.samples_batch_ns {
		append(dst, f64(b) / f64(ops))
	}
}

@(private)
_write_v3_stats_block :: proc(buf: ^[dynamic]u8, r: hugi.Record, rational: bool) {
	if rational {
		_v3_append_zigzag_i64(buf, r.min_fs)
		_v3_append_zigzag_i64(buf, r.p25_fs)
		_v3_append_zigzag_i64(buf, r.p50_fs)
		_v3_append_zigzag_i64(buf, r.p75_fs)
		_v3_append_zigzag_i64(buf, r.p95_fs)
		_v3_append_zigzag_i64(buf, r.p99_fs)
		_v3_append_zigzag_i64(buf, r.max_fs)
		_v3_append_zigzag_i64(buf, r.mean_fs)
		_v3_append_zigzag_i64(buf, r.std_dev_fs)
		_v3_append_zigzag_i64(buf, r.ci95_fs)
		_v3_append_f64_le(buf, r.cv_pct)
		_v3_append_zigzag_i64(buf, r.iqr_fs)
		_v3_append_zigzag_i64(buf, r.mad_fs)
	} else {
		_v3_append_f64_le(buf, hugi.fs_to_ns_f64(r.min_fs))
		_v3_append_f64_le(buf, hugi.fs_to_ns_f64(r.p25_fs))
		_v3_append_f64_le(buf, hugi.fs_to_ns_f64(r.p50_fs))
		_v3_append_f64_le(buf, hugi.fs_to_ns_f64(r.p75_fs))
		_v3_append_f64_le(buf, hugi.fs_to_ns_f64(r.p95_fs))
		_v3_append_f64_le(buf, hugi.fs_to_ns_f64(r.p99_fs))
		_v3_append_f64_le(buf, hugi.fs_to_ns_f64(r.max_fs))
		_v3_append_f64_le(buf, hugi.fs_to_ns_f64(r.mean_fs))
		_v3_append_f64_le(buf, hugi.fs_to_ns_f64(r.std_dev_fs))
		_v3_append_f64_le(buf, hugi.fs_to_ns_f64(r.ci95_fs))
		_v3_append_f64_le(buf, r.cv_pct)
		_v3_append_f64_le(buf, hugi.fs_to_ns_f64(r.iqr_fs))
		_v3_append_f64_le(buf, hugi.fs_to_ns_f64(r.mad_fs))
	}
}

@(private, require_results)
_read_v3_stats_block :: proc(rd: ^_V3_Reader, r: ^hugi.Record, rational: bool) -> bool {
	if rational {
		r.min_fs = _v3_read_zigzag_i64(rd) or_return
		r.p25_fs = _v3_read_zigzag_i64(rd) or_return
		r.p50_fs = _v3_read_zigzag_i64(rd) or_return
		r.p75_fs = _v3_read_zigzag_i64(rd) or_return
		r.p95_fs = _v3_read_zigzag_i64(rd) or_return
		r.p99_fs = _v3_read_zigzag_i64(rd) or_return
		r.max_fs = _v3_read_zigzag_i64(rd) or_return
		r.mean_fs = _v3_read_zigzag_i64(rd) or_return
		r.std_dev_fs = _v3_read_zigzag_i64(rd) or_return
		r.ci95_fs = _v3_read_zigzag_i64(rd) or_return
		r.cv_pct = _v3_read_f64_le(rd) or_return
		r.iqr_fs = _v3_read_zigzag_i64(rd) or_return
		r.mad_fs = _v3_read_zigzag_i64(rd) or_return
	} else {
		r.min_fs = hugi.ns_f64_to_fs(_v3_read_f64_le(rd) or_return)
		r.p25_fs = hugi.ns_f64_to_fs(_v3_read_f64_le(rd) or_return)
		r.p50_fs = hugi.ns_f64_to_fs(_v3_read_f64_le(rd) or_return)
		r.p75_fs = hugi.ns_f64_to_fs(_v3_read_f64_le(rd) or_return)
		r.p95_fs = hugi.ns_f64_to_fs(_v3_read_f64_le(rd) or_return)
		r.p99_fs = hugi.ns_f64_to_fs(_v3_read_f64_le(rd) or_return)
		r.max_fs = hugi.ns_f64_to_fs(_v3_read_f64_le(rd) or_return)
		r.mean_fs = hugi.ns_f64_to_fs(_v3_read_f64_le(rd) or_return)
		r.std_dev_fs = hugi.ns_f64_to_fs(_v3_read_f64_le(rd) or_return)
		r.ci95_fs = hugi.ns_f64_to_fs(_v3_read_f64_le(rd) or_return)
		r.cv_pct = _v3_read_f64_le(rd) or_return
		r.iqr_fs = hugi.ns_f64_to_fs(_v3_read_f64_le(rd) or_return)
		r.mad_fs = hugi.ns_f64_to_fs(_v3_read_f64_le(rd) or_return)
	}
	return true
}

@(private)
_finalize_record_stats_from_samples :: proc(r: ^hugi.Record, keep_existing_mbs: bool) {
	if len(r.samples_batch_ns) == 0 {
		return
	}
	saved_mbs := r.mb_per_sec
	hugi.recompute_record_stats_from_samples(r)
	if r.p50_fs > 0 {
		ops_sec := hugi.FS_PER_SEC_F64 / f64(r.p50_fs)
		if r.items_per_op > 0 {
			r.items_per_sec = f64(r.items_per_op) * ops_sec
		} else {
			r.items_per_sec = ops_sec
		}
		if r.bytes_per_op > 0 {
			r.mb_per_sec = (f64(r.bytes_per_op) * ops_sec) / (1024.0 * 1024.0)
		} else if keep_existing_mbs {
			r.mb_per_sec = saved_mbs
		}
	} else if keep_existing_mbs {
		r.mb_per_sec = saved_mbs
	}
}

// ── CZPK\x03 Packet Encoding / Decoding (Techniques 1, 2, 3) ───────────────

@(private, require_results)
_v3_encode_packet :: proc(
	pkt: hugi.Run_Packet,
	syms: ^_Symbol_Table,
	descs: ^_Descriptor_Table,
	opts: Store_Write_Options,
	allocator := context.temp_allocator,
) -> (
	out: []u8,
	ok: bool,
) {
	meta_raw := make([dynamic]u8, 0, 1024, context.temp_allocator)
	defer delete(meta_raw)

	pkt_flags := u8(0)
	if opts.use_symbol_table {
		pkt_flags |= _V3_PKT_FLAG_SYMS
	}
	if opts.use_descriptors {
		pkt_flags |= _V3_PKT_FLAG_DESCS
	}
	if pkt.selective {
		pkt_flags |= _V3_PKT_FLAG_SELECTIVE
	}

	if opts.use_symbol_table {
		_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.suite_name)))
		_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.lang)))
		_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.commit)))
		_v3_append_str(&meta_raw, pkt.run_id)
		_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.os)))
		_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.arch)))
		_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.optimization)))
		_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.odin_version)))
	} else {
		_v3_append_str(&meta_raw, pkt.suite_name)
		_v3_append_str(&meta_raw, pkt.lang)
		_v3_append_str(&meta_raw, pkt.commit)
		_v3_append_str(&meta_raw, pkt.run_id)
		_v3_append_str(&meta_raw, pkt.os)
		_v3_append_str(&meta_raw, pkt.arch)
		_v3_append_str(&meta_raw, pkt.optimization)
		_v3_append_str(&meta_raw, pkt.odin_version)
	}
	_v3_append_zigzag_i64(&meta_raw, pkt.timestamp_unix)

	_v3_append_varint_u64(&meta_raw, u64(len(pkt.records)))
	total_samples := 0
	for r in pkt.records {
		_v3_append_varint_u64(&meta_raw, u64(len(r.samples_batch_ns)))
		total_samples += len(r.samples_batch_ns)
	}

	if opts.use_descriptors {
		for r, ri in pkt.records {
			desc_id := _desc_intern(descs, syms, r)
			rflags := _rec_presence_flags(r, ri)
			_v3_append_varint_u64(&meta_raw, u64(desc_id))
			_v3_append_varint_u64(&meta_raw, u64(rflags))
			_v3_append_varint_u64(&meta_raw, r.ops_per_sample)
			_v3_append_varint_u64(&meta_raw, u64(r.samples))
			_v3_append_varint_u64(&meta_raw, u64(r.warmup))

			if (rflags & _REC_FLAG_CUSTOM_RANK) != 0 {
				_v3_append_zigzag_i64(&meta_raw, i64(r.rank))
			}
			if (rflags & _REC_FLAG_FOOTPRINT) != 0 {
				_v3_append_varint_u64(&meta_raw, r.footprint_bytes)
			}
			if (rflags & _REC_FLAG_PEAK_HEAP) != 0 {
				_v3_append_zigzag_i64(&meta_raw, r.peak_heap_bytes)
			}
			if (rflags & _REC_FLAG_ERROR) != 0 {
				_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, r.error)))
			}
			if (rflags & _REC_FLAG_METRICS) != 0 {
				_v3_append_varint_u64(&meta_raw, u64(len(r.metrics)))
				for m in r.metrics {
					_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, m.unit)))
					_v3_append_f64_le(&meta_raw, m.value)
				}
			}
			if (rflags & _REC_FLAG_HEAP_ALLOCS) != 0 {
				_v3_append_f64_le(&meta_raw, r.allocs_per_op)
				_v3_append_f64_le(&meta_raw, r.resizes_per_op)
				_v3_append_f64_le(&meta_raw, r.alloc_bytes_per_op)
			}
			if (rflags & _REC_FLAG_TEMP_ALLOCS) != 0 {
				_v3_append_f64_le(&meta_raw, r.temp_allocs_per_op)
				_v3_append_f64_le(&meta_raw, r.temp_bytes_per_op)
			}
			if (rflags & _REC_FLAG_CYCLES) != 0 {
				_v3_append_f64_le(&meta_raw, r.median_cycles)
			}
			if (rflags & _REC_FLAG_NO_SAMPLES) != 0 {
				_write_v3_stats_block(&meta_raw, r, opts.use_rational_time)
				_v3_append_f64_le(&meta_raw, r.mb_per_sec)
				_v3_append_f64_le(&meta_raw, r.items_per_sec)
			} else if (rflags & _REC_FLAG_CUSTOM_MBS) != 0 {
				_v3_append_f64_le(&meta_raw, r.mb_per_sec)
			}
		}
	} else {
		// Technique 1 isolated path: intern all record strings via `syms`, keep full fields.
		for r in pkt.records {
			_v3_append_zigzag_i64(&meta_raw, i64(r.rank))
			_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, r.group_name)))
			_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, r.name)))
			_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, r.full_name)))
			_v3_append_zigzag_i64(&meta_raw, i64(r.param))
			append(&meta_raw, u8(1) if r.has_param else u8(0))
			_v3_append_zigzag_i64(&meta_raw, i64(r.threads))
			append(&meta_raw, u8(1) if r.has_threads else u8(0))
			_v3_append_varint_u64(&meta_raw, r.ops_per_sample)
			_v3_append_varint_u64(&meta_raw, u64(r.samples))
			_v3_append_varint_u64(&meta_raw, u64(r.warmup))
			_write_v3_stats_block(&meta_raw, r, opts.use_rational_time)
			_v3_append_f64_le(&meta_raw, r.median_cycles)
			_v3_append_varint_u64(&meta_raw, r.bytes_per_op)
			_v3_append_varint_u64(&meta_raw, r.items_per_op)
			_v3_append_f64_le(&meta_raw, r.mb_per_sec)
			_v3_append_f64_le(&meta_raw, r.items_per_sec)
			_v3_append_varint_u64(&meta_raw, r.footprint_bytes)
			_v3_append_f64_le(&meta_raw, r.allocs_per_op)
			_v3_append_f64_le(&meta_raw, r.resizes_per_op)
			_v3_append_f64_le(&meta_raw, r.alloc_bytes_per_op)
			_v3_append_f64_le(&meta_raw, r.temp_allocs_per_op)
			_v3_append_f64_le(&meta_raw, r.temp_bytes_per_op)
			_v3_append_zigzag_i64(&meta_raw, r.peak_heap_bytes)
			append(&meta_raw, u8(1) if r.zero_alloc_failed else u8(0))
			_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, r.error)))
			_v3_append_varint_u64(&meta_raw, u64(len(r.metrics)))
			for m in r.metrics {
				_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, m.unit)))
				_v3_append_f64_le(&meta_raw, m.value)
			}
		}
	}

	zlib_lvl := c.int(9) if (opts.use_domain_f64 || opts.use_rational_time) else c.int(6)
	meta_comp := compress_bytes_zlib(meta_raw[:], context.temp_allocator, zlib_lvl) or_return
	defer delete(meta_comp, context.temp_allocator)

	s_blob: []u8
	if opts.use_rational_time {
		all_batches := make([dynamic]u64, 0, total_samples, context.temp_allocator)
		defer delete(all_batches)
		for r in pkt.records {
			append(&all_batches, ..r.samples_batch_ns[:])
		}
		s_blob = compress_samples_u64(all_batches[:], context.temp_allocator) or_return
	} else {
		all_samples := make([dynamic]f64, 0, total_samples, context.temp_allocator)
		defer delete(all_samples)
		for r in pkt.records {
			_append_record_samples_as_f64(&all_samples, r)
		}
		s_blob = _compress_sample_vec(
			all_samples[:],
			opts.use_domain_f64,
			context.temp_allocator,
		) or_return
	}
	defer delete(s_blob, context.temp_allocator)

	magic := CZPK_V4_MAGIC if opts.use_rational_time else CZPK_V3_MAGIC
	buf := make([dynamic]u8, 0, len(magic) + 9 + len(meta_comp) + len(s_blob), allocator)
	append(&buf, ..transmute([]u8)string(magic))
	append(&buf, pkt_flags)
	_v3_append_u32_le(&buf, u32(len(meta_comp)))
	append(&buf, ..meta_comp)
	_v3_append_u32_le(&buf, u32(len(s_blob)))
	append(&buf, ..s_blob)
	return buf[:], true
}

@(private, require_results)
_v3_decode_packet :: proc(
	blob: []u8,
	syms: _Symbol_Table,
	descs: _Descriptor_Table,
	allocator := context.allocator,
) -> (
	pkt: hugi.Run_Packet,
	ok: bool,
) {
	if len(blob) < len(CZPK_V3_MAGIC) + 1 {
		return {}, false
	}
	hdr := string(blob[:len(CZPK_V3_MAGIC)])
	if hdr != CZPK_V3_MAGIC && hdr != CZPK_V4_MAGIC {
		return {}, false
	}
	is_rational := hdr == CZPK_V4_MAGIC
	defer if !ok {
		hugi.packet_destroy(&pkt, allocator)
	}

	pos := len(CZPK_V3_MAGIC)
	pkt_flags := blob[pos]
	pos += 1
	use_syms := (pkt_flags & _V3_PKT_FLAG_SYMS) != 0
	use_descs := (pkt_flags & _V3_PKT_FLAG_DESCS) != 0
	selective := (pkt_flags & _V3_PKT_FLAG_SELECTIVE) != 0

	outer_rd := _V3_Reader {
		data = blob,
		pos  = pos,
	}
	meta_len := int(_v3_read_u32_le(&outer_rd) or_return)
	if meta_len < 0 || outer_rd.pos + meta_len > len(blob) {
		return {}, false
	}
	meta_raw := decompress_bytes_zlib(
		blob[outer_rd.pos:outer_rd.pos + meta_len],
		context.temp_allocator,
	) or_return
	defer delete(meta_raw, context.temp_allocator)
	outer_rd.pos += meta_len

	s_len := int(_v3_read_u32_le(&outer_rd) or_return)
	if s_len < 0 || outer_rd.pos + s_len > len(blob) {
		return {}, false
	}
	all_u64: []u64
	all_f64: []f64
	if is_rational {
		all_u64 = decompress_samples_u64(
			blob[outer_rd.pos:outer_rd.pos + s_len],
			context.temp_allocator,
		) or_return
	} else {
		all_f64 = decompress_samples_f64(
			blob[outer_rd.pos:outer_rd.pos + s_len],
			context.temp_allocator,
		) or_return
	}
	defer delete(all_u64, context.temp_allocator)
	defer delete(all_f64, context.temp_allocator)

	rd := _V3_Reader {
		data = meta_raw,
	}
	pkt.records = make([dynamic]hugi.Record, allocator)
	pkt.selective = selective

	read_sym_clone := proc(
		r: ^_V3_Reader,
		syms: _Symbol_Table,
		alloc: runtime.Allocator,
	) -> (
		s: string,
		ok: bool,
	) {
		id := u32(_v3_read_varint_u64(r) or_return)
		raw := _sym_get(syms, id) or_return
		return strings.clone(raw, alloc), true
	}

	if use_syms {
		pkt.suite_name = read_sym_clone(&rd, syms, allocator) or_return
		pkt.lang = read_sym_clone(&rd, syms, allocator) or_return
		pkt.commit = read_sym_clone(&rd, syms, allocator) or_return
		pkt.run_id = _v3_read_str(&rd, allocator) or_return
		pkt.os = read_sym_clone(&rd, syms, allocator) or_return
		pkt.arch = read_sym_clone(&rd, syms, allocator) or_return
		pkt.optimization = read_sym_clone(&rd, syms, allocator) or_return
		pkt.odin_version = read_sym_clone(&rd, syms, allocator) or_return
	} else {
		pkt.suite_name = _v3_read_str(&rd, allocator) or_return
		pkt.lang = _v3_read_str(&rd, allocator) or_return
		pkt.commit = _v3_read_str(&rd, allocator) or_return
		pkt.run_id = _v3_read_str(&rd, allocator) or_return
		pkt.os = _v3_read_str(&rd, allocator) or_return
		pkt.arch = _v3_read_str(&rd, allocator) or_return
		pkt.optimization = _v3_read_str(&rd, allocator) or_return
		pkt.odin_version = _v3_read_str(&rd, allocator) or_return
	}
	pkt.timestamp_unix = _v3_read_zigzag_i64(&rd) or_return

	rec_count := int(_v3_read_varint_u64(&rd) or_return)
	if rec_count < 0 || rec_count > 100_000 {
		return pkt, false
	}
	sample_counts := make([]int, rec_count, context.temp_allocator)
	defer delete(sample_counts, context.temp_allocator)
	expected_total := 0
	for i in 0 ..< rec_count {
		cnt := int(_v3_read_varint_u64(&rd) or_return)
		if cnt < 0 || cnt > 10_000_000 || expected_total > 100_000_000 - cnt {
			return pkt, false
		}
		sample_counts[i] = cnt
		expected_total += cnt
	}
	actual_total := len(all_u64) if is_rational else len(all_f64)
	if expected_total != actual_total {
		return pkt, false
	}

	reserve(&pkt.records, rec_count)
	s_off := 0
	if use_descs {
		for ri in 0 ..< rec_count {
			desc_id := u32(_v3_read_varint_u64(&rd) or_return)
			rflags := u32(_v3_read_varint_u64(&rd) or_return)
			ops := _v3_read_varint_u64(&rd) or_return
			samples := int(_v3_read_varint_u64(&rd) or_return)
			warmup := int(_v3_read_varint_u64(&rd) or_return)

			desc, g_name, b_name, f_name := _desc_materialize_strings(
				descs,
				syms,
				desc_id,
				allocator,
			) or_return

			r := hugi.Record {
				rank              = ri + 1,
				group_name        = g_name,
				name              = b_name,
				full_name         = f_name,
				param             = int(desc.param),
				has_param         = (desc.flags & _DESC_FLAG_HAS_PARAM) != 0,
				threads           = int(desc.threads),
				has_threads       = (desc.flags & _DESC_FLAG_HAS_THREADS) != 0,
				ops_per_sample    = ops,
				samples           = samples,
				warmup            = warmup,
				bytes_per_op      = desc.bytes_per_op,
				items_per_op      = desc.items_per_op,
				zero_alloc_failed = (rflags & _REC_FLAG_ZERO_ALLOC_FAILED) != 0,
				metrics           = make([dynamic]hugi.Metric, allocator),
				samples_batch_ns  = make([dynamic]u64, allocator),
			}
			append(&pkt.records, r)
			rp := &pkt.records[len(pkt.records) - 1]

			if (rflags & _REC_FLAG_CUSTOM_RANK) != 0 {
				rp.rank = int(_v3_read_zigzag_i64(&rd) or_return)
			}
			if (rflags & _REC_FLAG_FOOTPRINT) != 0 {
				rp.footprint_bytes = _v3_read_varint_u64(&rd) or_return
			}
			if (rflags & _REC_FLAG_PEAK_HEAP) != 0 {
				rp.peak_heap_bytes = _v3_read_zigzag_i64(&rd) or_return
			}
			if (rflags & _REC_FLAG_ERROR) != 0 {
				rp.error = read_sym_clone(&rd, syms, allocator) or_return
			} else {
				rp.error = strings.clone("", allocator)
			}
			if (rflags & _REC_FLAG_METRICS) != 0 {
				mc := int(_v3_read_varint_u64(&rd) or_return)
				if mc < 0 || mc > 1024 {
					return pkt, false
				}
				reserve(&rp.metrics, mc)
				for _ in 0 ..< mc {
					u := read_sym_clone(&rd, syms, allocator) or_return
					v := _v3_read_f64_le(&rd) or_return
					append(&rp.metrics, hugi.Metric{unit = u, value = v})
				}
			}
			if (rflags & _REC_FLAG_HEAP_ALLOCS) != 0 {
				rp.allocs_per_op = _v3_read_f64_le(&rd) or_return
				rp.resizes_per_op = _v3_read_f64_le(&rd) or_return
				rp.alloc_bytes_per_op = _v3_read_f64_le(&rd) or_return
			}
			if (rflags & _REC_FLAG_TEMP_ALLOCS) != 0 {
				rp.temp_allocs_per_op = _v3_read_f64_le(&rd) or_return
				rp.temp_bytes_per_op = _v3_read_f64_le(&rd) or_return
			}
			if (rflags & _REC_FLAG_CYCLES) != 0 {
				rp.median_cycles = _v3_read_f64_le(&rd) or_return
			}
			keep_mbs := false
			if (rflags & _REC_FLAG_NO_SAMPLES) != 0 {
				_read_v3_stats_block(&rd, rp, is_rational) or_return
				rp.mb_per_sec = _v3_read_f64_le(&rd) or_return
				rp.items_per_sec = _v3_read_f64_le(&rd) or_return
			} else if (rflags & _REC_FLAG_CUSTOM_MBS) != 0 {
				rp.mb_per_sec = _v3_read_f64_le(&rd) or_return
				keep_mbs = true
			}

			cnt := sample_counts[ri]
			if cnt > 0 {
				if is_rational {
					append(&rp.samples_batch_ns, ..all_u64[s_off:s_off + cnt])
				} else {
					for s in all_f64[s_off:s_off + cnt] {
						append(
							&rp.samples_batch_ns,
							hugi.legacy_ns_to_batch_ns(s, rp.ops_per_sample),
						)
					}
				}
				s_off += cnt
				_finalize_record_stats_from_samples(rp, keep_mbs)
			}
		}
	} else {
		for ri in 0 ..< rec_count {
			r := hugi.Record {
				metrics          = make([dynamic]hugi.Metric, allocator),
				samples_batch_ns = make([dynamic]u64, allocator),
			}
			append(&pkt.records, r)
			rp := &pkt.records[len(pkt.records) - 1]

			rp.rank = int(_v3_read_zigzag_i64(&rd) or_return)
			rp.group_name = read_sym_clone(&rd, syms, allocator) or_return
			rp.name = read_sym_clone(&rd, syms, allocator) or_return
			rp.full_name = read_sym_clone(&rd, syms, allocator) or_return
			rp.param = int(_v3_read_zigzag_i64(&rd) or_return)
			rp.has_param = (_v3_read_u8(&rd) or_return) != 0
			rp.threads = int(_v3_read_zigzag_i64(&rd) or_return)
			rp.has_threads = (_v3_read_u8(&rd) or_return) != 0
			rp.ops_per_sample = _v3_read_varint_u64(&rd) or_return
			rp.samples = int(_v3_read_varint_u64(&rd) or_return)
			rp.warmup = int(_v3_read_varint_u64(&rd) or_return)
			_read_v3_stats_block(&rd, rp, is_rational) or_return
			rp.median_cycles = _v3_read_f64_le(&rd) or_return
			rp.bytes_per_op = _v3_read_varint_u64(&rd) or_return
			rp.items_per_op = _v3_read_varint_u64(&rd) or_return
			rp.mb_per_sec = _v3_read_f64_le(&rd) or_return
			rp.items_per_sec = _v3_read_f64_le(&rd) or_return
			rp.footprint_bytes = _v3_read_varint_u64(&rd) or_return
			rp.allocs_per_op = _v3_read_f64_le(&rd) or_return
			rp.resizes_per_op = _v3_read_f64_le(&rd) or_return
			rp.alloc_bytes_per_op = _v3_read_f64_le(&rd) or_return
			rp.temp_allocs_per_op = _v3_read_f64_le(&rd) or_return
			rp.temp_bytes_per_op = _v3_read_f64_le(&rd) or_return
			rp.peak_heap_bytes = _v3_read_zigzag_i64(&rd) or_return
			rp.zero_alloc_failed = (_v3_read_u8(&rd) or_return) != 0
			rp.error = read_sym_clone(&rd, syms, allocator) or_return

			mc := int(_v3_read_varint_u64(&rd) or_return)
			if mc < 0 || mc > 1024 {
				return pkt, false
			}
			reserve(&rp.metrics, mc)
			for _ in 0 ..< mc {
				u := read_sym_clone(&rd, syms, allocator) or_return
				v := _v3_read_f64_le(&rd) or_return
				append(&rp.metrics, hugi.Metric{unit = u, value = v})
			}

			cnt := sample_counts[ri]
			if cnt > 0 {
				if is_rational {
					append(&rp.samples_batch_ns, ..all_u64[s_off:s_off + cnt])
				} else {
					for s in all_f64[s_off:s_off + cnt] {
						append(
							&rp.samples_batch_ns,
							hugi.legacy_ns_to_batch_ns(s, rp.ops_per_sample),
						)
					}
				}
				s_off += cnt
			}
		}
	}

	return pkt, rd.pos == len(rd.data)
}

// ── Technique 4: Transposed Cold-History Columnar Rollup Chunk (CZCH\x01) ────

@(private)
_Rec_Coord :: struct {
	pkt_i: int,
	rec_i: int,
}

@(private, require_results)
_encode_cold_chunk :: proc(
	pkts: []hugi.Run_Packet,
	syms: ^_Symbol_Table,
	descs: ^_Descriptor_Table,
	opts: Store_Write_Options,
	allocator := context.temp_allocator,
) -> (
	blob: []u8,
	ok: bool,
) {
	meta_raw := make([dynamic]u8, 0, max(len(pkts) * 256, 256), context.temp_allocator)
	defer delete(meta_raw)

	n_runs := len(pkts)
	_v3_append_varint_u64(&meta_raw, u64(n_runs))

	// Run metadata in columnar layout for stronger Zlib cross-run matching.
	for p in pkts {
		_v3_append_str(&meta_raw, p.run_id)
	}
	for p in pkts {
		_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.commit)))
	}
	for p in pkts {
		_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.lang)))
	}
	for p in pkts {
		_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.suite_name)))
	}
	for p in pkts {
		_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.os)))
	}
	for p in pkts {
		_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.arch)))
	}
	for p in pkts {
		_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.optimization)))
	}
	for p in pkts {
		_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.odin_version)))
	}
	prev_ts: i64 = 0
	for p in pkts {
		_v3_append_zigzag_i64(&meta_raw, p.timestamp_unix - prev_ts)
		prev_ts = p.timestamp_unix
	}
	for p in pkts {
		append(&meta_raw, u8(1) if p.selective else u8(0))
	}
	total_recs := 0
	for p in pkts {
		_v3_append_varint_u64(&meta_raw, u64(len(p.records)))
		total_recs += len(p.records)
	}

	// Materialize record metadata columns across all cold runs.
	desc_ids := make([dynamic]u32, 0, total_recs, context.temp_allocator)
	defer delete(desc_ids)
	rflags := make([dynamic]u32, 0, total_recs, context.temp_allocator)
	defer delete(rflags)
	ops_col := make([dynamic]u64, 0, total_recs, context.temp_allocator)
	defer delete(ops_col)
	scounts := make([dynamic]int, 0, total_recs, context.temp_allocator)
	defer delete(scounts)
	warmups := make([dynamic]int, 0, total_recs, context.temp_allocator)
	defer delete(warmups)

	by_desc := make(map[u32][dynamic]_Rec_Coord, context.temp_allocator)
	defer {
		for _, lst in by_desc {
			delete(lst)
		}
		delete(by_desc)
	}
	unique_descs := make([dynamic]u32, 0, 64, context.temp_allocator)
	defer delete(unique_descs)

	total_samples := 0
	for p, pi in pkts {
		for r, ri in p.records {
			did := _desc_intern(descs, syms, r)
			append(&desc_ids, did)
			append(&rflags, _rec_presence_flags(r, ri))
			append(&ops_col, r.ops_per_sample)
			append(&scounts, len(r.samples_batch_ns))
			append(&warmups, r.warmup)
			total_samples += len(r.samples_batch_ns)

			if did not_in by_desc {
				by_desc[did] = make([dynamic]_Rec_Coord, context.temp_allocator)
				append(&unique_descs, did)
			}
			lst := &by_desc[did]
			append(lst, _Rec_Coord{pkt_i = pi, rec_i = ri})
		}
	}

	prev_did: i64 = 0
	for did in desc_ids {
		_v3_append_zigzag_i64(&meta_raw, i64(did) - prev_did)
		prev_did = i64(did)
	}
	for fl in rflags {
		_v3_append_varint_u64(&meta_raw, u64(fl))
	}
	prev_ops: i64 = 0
	for ov in ops_col {
		_v3_append_zigzag_i64(&meta_raw, i64(ov) - prev_ops)
		prev_ops = i64(ov)
	}
	prev_sc: i64 = 0
	for sc in scounts {
		_v3_append_zigzag_i64(&meta_raw, i64(sc) - prev_sc)
		prev_sc = i64(sc)
	}
	prev_wu: i64 = 0
	for wu in warmups {
		_v3_append_zigzag_i64(&meta_raw, i64(wu) - prev_wu)
		prev_wu = i64(wu)
	}

	// Sparse record columns grouped per field across all cold runs.
	flat_idx := 0
	for p in pkts {
		for r in p.records {
			fl := rflags[flat_idx]
			flat_idx += 1
			if (fl & _REC_FLAG_CUSTOM_RANK) != 0 {
				_v3_append_zigzag_i64(&meta_raw, i64(r.rank))
			}
		}
	}
	flat_idx = 0
	for p in pkts {
		for r in p.records {
			fl := rflags[flat_idx]
			flat_idx += 1
			if (fl & _REC_FLAG_FOOTPRINT) != 0 {
				_v3_append_varint_u64(&meta_raw, r.footprint_bytes)
			}
		}
	}
	flat_idx = 0
	for p in pkts {
		for r in p.records {
			fl := rflags[flat_idx]
			flat_idx += 1
			if (fl & _REC_FLAG_PEAK_HEAP) != 0 {
				_v3_append_zigzag_i64(&meta_raw, r.peak_heap_bytes)
			}
		}
	}
	flat_idx = 0
	for p in pkts {
		for r in p.records {
			fl := rflags[flat_idx]
			flat_idx += 1
			if (fl & _REC_FLAG_ERROR) != 0 {
				_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, r.error)))
			}
		}
	}
	flat_idx = 0
	for p in pkts {
		for r in p.records {
			fl := rflags[flat_idx]
			flat_idx += 1
			if (fl & _REC_FLAG_METRICS) != 0 {
				_v3_append_varint_u64(&meta_raw, u64(len(r.metrics)))
				for m in r.metrics {
					_v3_append_varint_u64(&meta_raw, u64(_sym_intern(syms, m.unit)))
					_v3_append_f64_le(&meta_raw, m.value)
				}
			}
		}
	}
	flat_idx = 0
	for p in pkts {
		for r in p.records {
			fl := rflags[flat_idx]
			flat_idx += 1
			if (fl & _REC_FLAG_HEAP_ALLOCS) != 0 {
				_v3_append_f64_le(&meta_raw, r.allocs_per_op)
				_v3_append_f64_le(&meta_raw, r.resizes_per_op)
				_v3_append_f64_le(&meta_raw, r.alloc_bytes_per_op)
			}
		}
	}
	flat_idx = 0
	for p in pkts {
		for r in p.records {
			fl := rflags[flat_idx]
			flat_idx += 1
			if (fl & _REC_FLAG_TEMP_ALLOCS) != 0 {
				_v3_append_f64_le(&meta_raw, r.temp_allocs_per_op)
				_v3_append_f64_le(&meta_raw, r.temp_bytes_per_op)
			}
		}
	}
	flat_idx = 0
	for p in pkts {
		for r in p.records {
			fl := rflags[flat_idx]
			flat_idx += 1
			if (fl & _REC_FLAG_CYCLES) != 0 {
				_v3_append_f64_le(&meta_raw, r.median_cycles)
			}
		}
	}
	flat_idx = 0
	for p in pkts {
		for r in p.records {
			fl := rflags[flat_idx]
			flat_idx += 1
			if (fl & _REC_FLAG_NO_SAMPLES) != 0 {
				_write_v3_stats_block(&meta_raw, r, opts.use_rational_time)
				_v3_append_f64_le(&meta_raw, r.mb_per_sec)
				_v3_append_f64_le(&meta_raw, r.items_per_sec)
			} else if (fl & _REC_FLAG_CUSTOM_MBS) != 0 {
				_v3_append_f64_le(&meta_raw, r.mb_per_sec)
			}
		}
	}

	zlib_lvl := c.int(9) if (opts.use_domain_f64 || opts.use_rational_time) else c.int(6)
	meta_comp := compress_bytes_zlib(meta_raw[:], context.temp_allocator, zlib_lvl) or_return
	defer delete(meta_comp, context.temp_allocator)

	// Group samples by sorted `desc_id` across all cold runs so cross-commit samples
	// of each benchmark stay contiguous inside one single compressed stream.
	slice.sort(unique_descs[:])
	s_blob: []u8
	if opts.use_rational_time {
		grouped_batches := make([dynamic]u64, 0, total_samples, context.temp_allocator)
		defer delete(grouped_batches)
		for did in unique_descs {
			for coord in by_desc[did] {
				append(
					&grouped_batches,
					..pkts[coord.pkt_i].records[coord.rec_i].samples_batch_ns[:],
				)
			}
		}
		s_blob = compress_samples_u64(grouped_batches[:], context.temp_allocator) or_return
	} else {
		grouped_samples := make([dynamic]f64, 0, total_samples, context.temp_allocator)
		defer delete(grouped_samples)
		for did in unique_descs {
			for coord in by_desc[did] {
				_append_record_samples_as_f64(
					&grouped_samples,
					pkts[coord.pkt_i].records[coord.rec_i],
				)
			}
		}
		s_blob = _compress_sample_vec(
			grouped_samples[:],
			opts.use_domain_f64,
			context.temp_allocator,
		) or_return
	}
	defer delete(s_blob, context.temp_allocator)

	magic := CZCH_V2_MAGIC if opts.use_rational_time else CZCH_MAGIC
	out := make([dynamic]u8, 0, len(magic) + 8 + len(meta_comp) + len(s_blob), allocator)
	append(&out, ..transmute([]u8)string(magic))
	_v3_append_u32_le(&out, u32(len(meta_comp)))
	append(&out, ..meta_comp)
	_v3_append_u32_le(&out, u32(len(s_blob)))
	append(&out, ..s_blob)
	return out[:], true
}

@(private, require_results)
_decode_cold_chunk :: proc(
	blob: []u8,
	syms: _Symbol_Table,
	descs: _Descriptor_Table,
	allocator := context.allocator,
) -> (
	pkts: []hugi.Run_Packet,
	ok: bool,
) {
	if len(blob) < len(CZCH_MAGIC) {
		return nil, false
	}
	hdr := string(blob[:len(CZCH_MAGIC)])
	if hdr != CZCH_MAGIC && hdr != CZCH_V2_MAGIC {
		return nil, false
	}
	is_rational := hdr == CZCH_V2_MAGIC
	outer := _V3_Reader {
		data = blob,
		pos  = len(CZCH_MAGIC),
	}
	meta_len := int(_v3_read_u32_le(&outer) or_return)
	if meta_len < 0 || outer.pos + meta_len > len(blob) {
		return nil, false
	}
	meta_raw := decompress_bytes_zlib(
		blob[outer.pos:outer.pos + meta_len],
		context.temp_allocator,
	) or_return
	defer delete(meta_raw, context.temp_allocator)
	outer.pos += meta_len

	s_len := int(_v3_read_u32_le(&outer) or_return)
	if s_len < 0 || outer.pos + s_len > len(blob) {
		return nil, false
	}
	all_u64: []u64
	all_f64: []f64
	if is_rational {
		all_u64 = decompress_samples_u64(
			blob[outer.pos:outer.pos + s_len],
			context.temp_allocator,
		) or_return
	} else {
		all_f64 = decompress_samples_f64(
			blob[outer.pos:outer.pos + s_len],
			context.temp_allocator,
		) or_return
	}
	defer delete(all_u64, context.temp_allocator)
	defer delete(all_f64, context.temp_allocator)

	rd := _V3_Reader {
		data = meta_raw,
	}
	n_runs := int(_v3_read_varint_u64(&rd) or_return)
	if n_runs < 0 || n_runs > 100_000 {
		return nil, false
	}

	out := make([]hugi.Run_Packet, n_runs, allocator)
	defer if !ok {
		for &p in out {
			hugi.packet_destroy(&p, allocator)
		}
		delete(out, allocator)
	}
	for i in 0 ..< n_runs {
		out[i].records = make([dynamic]hugi.Record, allocator)
	}

	read_sym_clone := proc(
		r: ^_V3_Reader,
		syms: _Symbol_Table,
		alloc: runtime.Allocator,
	) -> (
		s: string,
		ok: bool,
	) {
		id := u32(_v3_read_varint_u64(r) or_return)
		raw := _sym_get(syms, id) or_return
		return strings.clone(raw, alloc), true
	}

	for i in 0 ..< n_runs {
		out[i].run_id = _v3_read_str(&rd, allocator) or_return
	}
	for i in 0 ..< n_runs {
		out[i].commit = read_sym_clone(&rd, syms, allocator) or_return
	}
	for i in 0 ..< n_runs {
		out[i].lang = read_sym_clone(&rd, syms, allocator) or_return
	}
	for i in 0 ..< n_runs {
		out[i].suite_name = read_sym_clone(&rd, syms, allocator) or_return
	}
	for i in 0 ..< n_runs {
		out[i].os = read_sym_clone(&rd, syms, allocator) or_return
	}
	for i in 0 ..< n_runs {
		out[i].arch = read_sym_clone(&rd, syms, allocator) or_return
	}
	for i in 0 ..< n_runs {
		out[i].optimization = read_sym_clone(&rd, syms, allocator) or_return
	}
	for i in 0 ..< n_runs {
		out[i].odin_version = read_sym_clone(&rd, syms, allocator) or_return
	}
	prev_ts: i64 = 0
	for i in 0 ..< n_runs {
		ts_delta := _v3_read_zigzag_i64(&rd) or_return
		prev_ts += ts_delta
		out[i].timestamp_unix = prev_ts
	}
	for i in 0 ..< n_runs {
		out[i].selective = (_v3_read_u8(&rd) or_return) != 0
	}

	total_recs := 0
	rec_counts := make([]int, n_runs, context.temp_allocator)
	defer delete(rec_counts, context.temp_allocator)
	for i in 0 ..< n_runs {
		rc := int(_v3_read_varint_u64(&rd) or_return)
		if rc < 0 || rc > 100_000 || total_recs > 10_000_000 - rc {
			return nil, false
		}
		rec_counts[i] = rc
		total_recs += rc
	}

	desc_ids := make([]u32, total_recs, context.temp_allocator)
	defer delete(desc_ids, context.temp_allocator)
	rflags := make([]u32, total_recs, context.temp_allocator)
	defer delete(rflags, context.temp_allocator)
	ops_col := make([]u64, total_recs, context.temp_allocator)
	defer delete(ops_col, context.temp_allocator)
	scounts := make([]int, total_recs, context.temp_allocator)
	defer delete(scounts, context.temp_allocator)
	warmups := make([]int, total_recs, context.temp_allocator)
	defer delete(warmups, context.temp_allocator)

	prev_did: i64 = 0
	for i in 0 ..< total_recs {
		d := _v3_read_zigzag_i64(&rd) or_return
		prev_did += d
		if prev_did < 0 {
			return nil, false
		}
		desc_ids[i] = u32(prev_did)
	}
	for i in 0 ..< total_recs {
		rflags[i] = u32(_v3_read_varint_u64(&rd) or_return)
	}
	prev_ops: i64 = 0
	for i in 0 ..< total_recs {
		d := _v3_read_zigzag_i64(&rd) or_return
		prev_ops += d
		ops_col[i] = u64(prev_ops)
	}
	expected_samples := 0
	prev_sc: i64 = 0
	for i in 0 ..< total_recs {
		d := _v3_read_zigzag_i64(&rd) or_return
		prev_sc += d
		if prev_sc < 0 || prev_sc > 10_000_000 || expected_samples > 100_000_000 - int(prev_sc) {
			return nil, false
		}
		scounts[i] = int(prev_sc)
		expected_samples += int(prev_sc)
	}
	actual_samples := len(all_u64) if is_rational else len(all_f64)
	if expected_samples != actual_samples {
		return nil, false
	}
	prev_wu: i64 = 0
	for i in 0 ..< total_recs {
		d := _v3_read_zigzag_i64(&rd) or_return
		prev_wu += d
		warmups[i] = int(prev_wu)
	}

	by_desc := make(map[u32][dynamic]_Rec_Coord, context.temp_allocator)
	defer {
		for _, lst in by_desc {
			delete(lst)
		}
		delete(by_desc)
	}
	unique_descs := make([dynamic]u32, 0, 64, context.temp_allocator)
	defer delete(unique_descs)

	flat_idx := 0
	for pi in 0 ..< n_runs {
		rc := rec_counts[pi]
		reserve(&out[pi].records, rc)
		for ri in 0 ..< rc {
			did := desc_ids[flat_idx]
			desc, g_name, b_name, f_name := _desc_materialize_strings(
				descs,
				syms,
				did,
				allocator,
			) or_return

			append(
				&out[pi].records,
				hugi.Record {
					rank = ri + 1,
					group_name = g_name,
					name = b_name,
					full_name = f_name,
					param = int(desc.param),
					has_param = (desc.flags & _DESC_FLAG_HAS_PARAM) != 0,
					threads = int(desc.threads),
					has_threads = (desc.flags & _DESC_FLAG_HAS_THREADS) != 0,
					ops_per_sample = ops_col[flat_idx],
					samples = scounts[flat_idx],
					warmup = warmups[flat_idx],
					bytes_per_op = desc.bytes_per_op,
					items_per_op = desc.items_per_op,
					zero_alloc_failed = (rflags[flat_idx] & _REC_FLAG_ZERO_ALLOC_FAILED) != 0,
					error = strings.clone("", allocator),
					metrics = make([dynamic]hugi.Metric, allocator),
					samples_batch_ns = make([dynamic]u64, allocator),
				},
			)
			if did not_in by_desc {
				by_desc[did] = make([dynamic]_Rec_Coord, context.temp_allocator)
				append(&unique_descs, did)
			}
			lst := &by_desc[did]
			append(lst, _Rec_Coord{pkt_i = pi, rec_i = ri})
			flat_idx += 1
		}
	}

	// Read sparse record columns in field order.
	flat_idx = 0
	for pi in 0 ..< n_runs {
		for ri in 0 ..< rec_counts[pi] {
			if (rflags[flat_idx] & _REC_FLAG_CUSTOM_RANK) != 0 {
				out[pi].records[ri].rank = int(_v3_read_zigzag_i64(&rd) or_return)
			}
			flat_idx += 1
		}
	}
	flat_idx = 0
	for pi in 0 ..< n_runs {
		for ri in 0 ..< rec_counts[pi] {
			if (rflags[flat_idx] & _REC_FLAG_FOOTPRINT) != 0 {
				out[pi].records[ri].footprint_bytes = _v3_read_varint_u64(&rd) or_return
			}
			flat_idx += 1
		}
	}
	flat_idx = 0
	for pi in 0 ..< n_runs {
		for ri in 0 ..< rec_counts[pi] {
			if (rflags[flat_idx] & _REC_FLAG_PEAK_HEAP) != 0 {
				out[pi].records[ri].peak_heap_bytes = _v3_read_zigzag_i64(&rd) or_return
			}
			flat_idx += 1
		}
	}
	flat_idx = 0
	for pi in 0 ..< n_runs {
		for ri in 0 ..< rec_counts[pi] {
			if (rflags[flat_idx] & _REC_FLAG_ERROR) != 0 {
				delete(out[pi].records[ri].error, allocator)
				out[pi].records[ri].error = read_sym_clone(&rd, syms, allocator) or_return
			}
			flat_idx += 1
		}
	}
	flat_idx = 0
	for pi in 0 ..< n_runs {
		for ri in 0 ..< rec_counts[pi] {
			if (rflags[flat_idx] & _REC_FLAG_METRICS) != 0 {
				mc := int(_v3_read_varint_u64(&rd) or_return)
				if mc < 0 || mc > 1024 {
					return nil, false
				}
				reserve(&out[pi].records[ri].metrics, mc)
				for _ in 0 ..< mc {
					u := read_sym_clone(&rd, syms, allocator) or_return
					v := _v3_read_f64_le(&rd) or_return
					append(&out[pi].records[ri].metrics, hugi.Metric{unit = u, value = v})
				}
			}
			flat_idx += 1
		}
	}
	flat_idx = 0
	for pi in 0 ..< n_runs {
		for ri in 0 ..< rec_counts[pi] {
			if (rflags[flat_idx] & _REC_FLAG_HEAP_ALLOCS) != 0 {
				rp := &out[pi].records[ri]
				rp.allocs_per_op = _v3_read_f64_le(&rd) or_return
				rp.resizes_per_op = _v3_read_f64_le(&rd) or_return
				rp.alloc_bytes_per_op = _v3_read_f64_le(&rd) or_return
			}
			flat_idx += 1
		}
	}
	flat_idx = 0
	for pi in 0 ..< n_runs {
		for ri in 0 ..< rec_counts[pi] {
			if (rflags[flat_idx] & _REC_FLAG_TEMP_ALLOCS) != 0 {
				rp := &out[pi].records[ri]
				rp.temp_allocs_per_op = _v3_read_f64_le(&rd) or_return
				rp.temp_bytes_per_op = _v3_read_f64_le(&rd) or_return
			}
			flat_idx += 1
		}
	}
	flat_idx = 0
	for pi in 0 ..< n_runs {
		for ri in 0 ..< rec_counts[pi] {
			if (rflags[flat_idx] & _REC_FLAG_CYCLES) != 0 {
				out[pi].records[ri].median_cycles = _v3_read_f64_le(&rd) or_return
			}
			flat_idx += 1
		}
	}

	keep_mbs_flags := make([]bool, total_recs, context.temp_allocator)
	defer delete(keep_mbs_flags, context.temp_allocator)
	flat_idx = 0
	for pi in 0 ..< n_runs {
		for ri in 0 ..< rec_counts[pi] {
			fl := rflags[flat_idx]
			rp := &out[pi].records[ri]
			if (fl & _REC_FLAG_NO_SAMPLES) != 0 {
				_read_v3_stats_block(&rd, rp, is_rational) or_return
				rp.mb_per_sec = _v3_read_f64_le(&rd) or_return
				rp.items_per_sec = _v3_read_f64_le(&rd) or_return
			} else if (fl & _REC_FLAG_CUSTOM_MBS) != 0 {
				rp.mb_per_sec = _v3_read_f64_le(&rd) or_return
				keep_mbs_flags[flat_idx] = true
			}
			flat_idx += 1
		}
	}

	// Scatter grouped samples back into their original `(pkt_i, rec_i)` order.
	flat_base := make([]int, n_runs, context.temp_allocator)
	defer delete(flat_base, context.temp_allocator)
	running := 0
	for pi in 0 ..< n_runs {
		flat_base[pi] = running
		running += rec_counts[pi]
	}

	slice.sort(unique_descs[:])
	s_off := 0
	for did in unique_descs {
		for coord in by_desc[did] {
			fi := flat_base[coord.pkt_i] + coord.rec_i
			cnt := scounts[fi]
			rp := &out[coord.pkt_i].records[coord.rec_i]
			if cnt > 0 {
				if is_rational {
					append(&rp.samples_batch_ns, ..all_u64[s_off:s_off + cnt])
				} else {
					for s in all_f64[s_off:s_off + cnt] {
						append(
							&rp.samples_batch_ns,
							hugi.legacy_ns_to_batch_ns(s, rp.ops_per_sample),
						)
					}
				}
				s_off += cnt
				_finalize_record_stats_from_samples(rp, keep_mbs_flags[fi])
			}
		}
	}

	if rd.pos != len(rd.data) {
		return nil, false
	}
	return out, true
}
