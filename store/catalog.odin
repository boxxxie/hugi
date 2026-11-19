package hugi_store

import obench "../deps/obench/obench"
import hugi "../hugi"
import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"

HCAT_MAGIC :: "HCAT\x01\x00\x00\x00"

@(private, require_results)
_run_key :: proc(lang, run_id: string, allocator := context.temp_allocator) -> string {
	eff_lang := lang != "" ? lang : "odin"
	return fmt.aprintf("%s:%s", eff_lang, run_id, allocator = allocator)
}

// ── Global Root Symbol Table ────────────────────────────────────────────────

@(private)
_Symbol_Table :: struct {
	items:     [dynamic]string, // items[0] == ""
	by_str:    map[string]u32,
	allocator: runtime.Allocator,
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
_read_sym_clone :: proc(
	r: ^_Format_Reader,
	syms: _Symbol_Table,
	alloc: runtime.Allocator,
) -> (
	s: string,
	ok: bool,
) {
	id := _fmt_read_varint_u32(r) or_return
	raw := _sym_get(syms, id) or_return
	return strings.clone(raw, alloc), true
}

// ── Static Bench Descriptor Table ───────────────────────────────────────────

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
	items:     [dynamic]_Bench_Desc,
	by_desc:   map[_Bench_Desc]u32,
	allocator: runtime.Allocator,
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

@(private)
_Snap_Ref :: struct {
	run_ord: u32,
	rec_idx: u32,
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
	run_key := _run_key(pkt.lang, pkt.run_id)
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
			if bk not_in desc_by_full {
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

	flags := _CAT_FLAG_DESCS
	if cat.has_cold_override {
		flags |= _CAT_FLAG_COLD_OVERRIDE
	}
	append(&raw, flags)

	// 1. Symbols section.
	extra := max(len(cat.syms.items) - 1, 0)
	_fmt_append_varint_u64(&raw, u64(extra))
	for i in 1 ..< len(cat.syms.items) {
		_fmt_append_str(&raw, cat.syms.items[i])
	}

	// 2. Descriptors section.
	_fmt_append_varint_u64(&raw, u64(len(cat.descs.items)))
	for d in cat.descs.items {
		append(&raw, d.flags)
		_fmt_append_varint_u64(&raw, u64(d.group_sym))
		_fmt_append_varint_u64(&raw, u64(d.name_sym))
		if (d.flags & _DESC_FLAG_CUSTOM_FULL) != 0 {
			_fmt_append_varint_u64(&raw, u64(d.custom_full_sym))
		}
		if (d.flags & _DESC_FLAG_HAS_PARAM) != 0 {
			_fmt_append_zigzag_i64(&raw, d.param)
		}
		if (d.flags & _DESC_FLAG_HAS_THREADS) != 0 {
			_fmt_append_zigzag_i64(&raw, d.threads)
		}
		_fmt_append_varint_u64(&raw, d.bytes_per_op)
		_fmt_append_varint_u64(&raw, d.items_per_op)
	}

	// 3. Runs section.
	_fmt_append_varint_u64(&raw, u64(len(cat.runs)))
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
			_fmt_append_varint_u64(&raw, u64(ls))
		}
		_fmt_append_str(&raw, r.run_id)
		if (rflags & _CAT_RUN_SAME_COMMIT) == 0 {
			_fmt_append_varint_u64(&raw, u64(cs))
		}
		if (rflags & _CAT_RUN_SAME_SUITE) == 0 {
			_fmt_append_varint_u64(&raw, u64(ss))
		}
		_fmt_append_zigzag_i64(&raw, r.timestamp_unix - prev_ts)
		_fmt_append_varint_u64(&raw, u64(r.record_count))
		_fmt_append_varint_u64(&raw, u64(r.total_samples))

		prev_ls = ls
		prev_cs = cs
		prev_ss = ss
		prev_ts = r.timestamp_unix
		has_prev = true
	}

	// 4. Snapshots section.
	_fmt_append_varint_u64(&raw, u64(len(langs)))
	for lk in langs {
		_fmt_append_varint_u64(&raw, u64(_sym_intern(&cat.syms, lk)))
		snap_m := cat.snaps[lk]
		bkeys := make([dynamic]string, 0, len(snap_m), context.temp_allocator)
		for bk in snap_m {
			append(&bkeys, bk)
		}
		slice.sort(bkeys[:])
		_fmt_append_varint_u64(&raw, u64(len(bkeys)))
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
				_fmt_append_varint_u64(&raw, u64(common_ord))
			}
			for bk in bkeys {
				ref := snap_m[bk]
				if did, in_desc := desc_by_full[bk]; in_desc {
					_fmt_append_varint_u64(&raw, u64(did) << 1)
				} else {
					_fmt_append_varint_u64(&raw, (u64(_sym_intern(&cat.syms, bk)) << 1) | 1)
				}
				if !all_same {
					_fmt_append_varint_u64(&raw, u64(ref.run_ord))
				}
				_fmt_append_varint_u64(&raw, u64(ref.rec_idx))
			}
		}
		delete(bkeys)
	}

	comp := compress_bytes_zlib(raw[:], context.temp_allocator, 9) or_return
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

	rd := _Format_Reader {
		data = raw,
	}
	flags := _fmt_read_u8(&rd) or_return
	if (flags & _CAT_FLAG_DESCS) == 0 {
		return false
	}
	cat.has_cold_override = (flags & _CAT_FLAG_COLD_OVERRIDE) != 0

	// 1. Symbols section.
	sym_cnt := _fmt_read_varint_nonneg_int(&rd) or_return
	if sym_cnt < 0 || sym_cnt > 10_000_000 {
		return false
	}
	for _ in 0 ..< sym_cnt {
		n_u := _fmt_read_varint_u64(&rd) or_return
		if n_u > u64(len(rd.data) - rd.pos) {
			return false
		}
		n := int(n_u)
		s := string(rd.data[rd.pos:rd.pos + n])
		rd.pos += n
		_ = _sym_intern(&cat.syms, s)
	}

	// 2. Descriptors section.
	d_cnt := _fmt_read_varint_nonneg_int(&rd) or_return
	if d_cnt < 0 || d_cnt > 10_000_000 {
		return false
	}
	for _ in 0 ..< d_cnt {
		dflags := _fmt_read_u8(&rd) or_return
		gs := _fmt_read_varint_u32(&rd) or_return
		ns := _fmt_read_varint_u32(&rd) or_return
		cs := u32(0)
		if (dflags & _DESC_FLAG_CUSTOM_FULL) != 0 {
			cs = _fmt_read_varint_u32(&rd) or_return
		}
		param := i64(0)
		if (dflags & _DESC_FLAG_HAS_PARAM) != 0 {
			param = _fmt_read_zigzag_i64(&rd) or_return
		}
		threads := i64(0)
		if (dflags & _DESC_FLAG_HAS_THREADS) != 0 {
			threads = _fmt_read_zigzag_i64(&rd) or_return
		}
		bpo := _fmt_read_varint_u64(&rd) or_return
		ipo := _fmt_read_varint_u64(&rd) or_return

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

	// 3. Runs section.
	run_cnt := _fmt_read_varint_nonneg_int(&rd) or_return
	if run_cnt < 0 || run_cnt > 10_000_000 {
		return false
	}
	reserve(&cat.runs, run_cnt)
	prev_ls: u32 = 0
	prev_cs: u32 = 0
	prev_ss: u32 = 0
	prev_ts: i64 = 0
	for i in 0 ..< run_cnt {
		rflags := _fmt_read_u8(&rd) or_return
		ls := prev_ls
		if (rflags & _CAT_RUN_SAME_LANG) == 0 {
			ls = _fmt_read_varint_u32(&rd) or_return
		}
		run_id := _fmt_read_str(&rd, cat.allocator) or_return
		run_id_owned := true
		defer if run_id_owned {
			delete(run_id, cat.allocator)
		}
		cs := prev_cs
		if (rflags & _CAT_RUN_SAME_COMMIT) == 0 {
			cs = _fmt_read_varint_u32(&rd) or_return
		}
		ss := prev_ss
		if (rflags & _CAT_RUN_SAME_SUITE) == 0 {
			ss = _fmt_read_varint_u32(&rd) or_return
		}
		ts_delta := _fmt_read_zigzag_i64(&rd) or_return
		ts := prev_ts + ts_delta
		rec_cnt := _fmt_read_varint_nonneg_int(&rd) or_return
		tot_samples := _fmt_read_varint_nonneg_int(&rd) or_return

		raw_lang := _sym_get(cat.syms, ls) or_return
		raw_commit := _sym_get(cat.syms, cs) or_return
		raw_suite := _sym_get(cat.syms, ss) or_return

		rk := _run_key(raw_lang, run_id, cat.allocator)
		if rk in cat.run_ord_by_key {
			delete(rk, cat.allocator)
			return false
		}
		cat.run_ord_by_key[rk] = i
		run_id_owned = false
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

	n_langs := _fmt_read_varint_nonneg_int(&rd) or_return
	if n_langs < 0 || n_langs > 10_000 {
		return false
	}
	for _ in 0 ..< n_langs {
		lsid := _fmt_read_varint_u32(&rd) or_return
		raw_lk := _sym_get(cat.syms, lsid) or_return
		if raw_lk in cat.snaps {
			return false
		}
		snap_m := make(map[string]_Snap_Ref, cat.allocator)
		cat.snaps[strings.clone(raw_lk, cat.allocator)] = snap_m
		m_ptr := &cat.snaps[raw_lk]

		n_bkeys := _fmt_read_varint_nonneg_int(&rd) or_return
		if n_bkeys < 0 || n_bkeys > 10_000_000 {
			return false
		}
		if n_bkeys > 0 {
			sflags := _fmt_read_u8(&rd) or_return
			all_same := (sflags & 1) != 0
			common_ord := u32(0)
			if all_same {
				common_ord = _fmt_read_varint_u32(&rd) or_return
			}
			for _ in 0 ..< n_bkeys {
				tag := _fmt_read_varint_u64(&rd) or_return
				raw_bkey: string
				if (tag & 1) != 0 {
					sid_u := tag >> 1
					if sid_u > u64(max(u32)) {
						return false
					}
					raw_bkey = _sym_get(cat.syms, u32(sid_u)) or_return
				} else {
					did_u := tag >> 1
					if did_u >= u64(len(cat.descs.items)) {
						return false
					}
					did := int(did_u)
					if desc_full_cache[did] == "" {
						_, g_tmp, n_tmp, df, d_ok := _desc_materialize_strings(
							cat.descs,
							cat.syms,
							u32(did),
							context.temp_allocator,
						)
						delete(g_tmp, context.temp_allocator)
						delete(n_tmp, context.temp_allocator)
						if !d_ok {
							return false
						}
						desc_full_cache[did] = df
					}
					raw_bkey = desc_full_cache[did]
				}
				ro := common_ord
				if !all_same {
					ro = _fmt_read_varint_u32(&rd) or_return
				}
				ri := _fmt_read_varint_u32(&rd) or_return
				ref := _Snap_Ref {
					run_ord = ro,
					rec_idx = ri,
				}
				if raw_bkey in m_ptr {
					m_ptr[raw_bkey] = ref
				} else {
					m_ptr[strings.clone(raw_bkey, cat.allocator)] = ref
				}
			}
		}
	}

	return rd.pos == len(rd.data)
}
