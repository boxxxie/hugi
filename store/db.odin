package hugi_store

import xitdb "../deps/xitdb/xitdb"
import hugi "../hugi"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Store :: struct {
	core:       ^xitdb.Core,
	base_core:  ^xitdb.Core,
	db:         xitdb.Database,
	is_file:    bool,
	is_overlay: bool,
	path:       string,
	write_opts: Store_Write_Options,
	allocator:  runtime.Allocator,
}

Commit_Summary :: struct {
	commit:        string,
	langs:         [dynamic]string,
	run_ids:       [dynamic]string,
	bench_count:   int,
	total_samples: int,
}

Run_Summary :: struct {
	run_id:         string,
	commit:         string,
	lang:           string,
	suite_name:     string,
	timestamp_unix: i64,
	record_count:   int,
	total_samples:  int,
}

@(private = "file")
_ensure_parent_dir :: proc(path: string) {
	dir := filepath.dir(path)
	if dir == "" || dir == "." || dir == "/" || os.exists(dir) {
		return
	}
	_ensure_parent_dir(dir)
	_ = os.make_directory(dir)
}

/*
Opens or creates an `xitdb` transactional benchmark store at `path` (pass `":memory:"`
for an in-memory store).
*/
@(require_results)
store_open :: proc(path: string, allocator := context.allocator) -> (st: Store, ok: bool) {
	core_ptr, core_err := new(xitdb.Core, allocator)
	if core_err != nil {
		return {}, false
	}

	st.allocator = allocator
	st.core = core_ptr
	st.path = strings.clone(path, allocator)
	if path == ":memory:" {
		core_ptr^ = xitdb.core_memory_init(allocator)
		st.is_file = false
	} else {
		_ensure_parent_dir(path)
		c, open_err := xitdb.core_buffered_file_open(
			path,
			2 * 1024 * 1024,
			{.Read, .Write, .Create},
			true,
			allocator,
		)
		if open_err != nil {
			free(core_ptr, allocator)
			delete(st.path, allocator)
			return {}, false
		}
		core_ptr^ = c
		st.is_file = true
	}

	db, db_err := xitdb.database_init(core_ptr, xitdb.sha1_hasher())
	if db_err != nil {
		_ = xitdb.core_destroy(core_ptr, close_file = st.is_file)
		free(core_ptr, allocator)
		delete(st.path, allocator)
		return {}, false
	}
	st.write_opts = default_store_write_options()
	st.db = db
	return st, true
}

/*
Opens an existing `.hugidb` file wrapped in an in-memory `xitdb.Core_Overlay`
Copy-on-Write branch so writes allocate RAM pages without modifying `path` on disk.
*/
@(require_results)
store_open_overlay :: proc(path: string, allocator := context.allocator) -> (st: Store, ok: bool) {
	if path == "" || path == ":memory:" || !os.exists(path) {
		return {}, false
	}
	base_ptr, base_err := new(xitdb.Core, allocator)
	if base_err != nil {
		return {}, false
	}
	base_c, open_err := xitdb.core_buffered_file_open(
		path,
		2 * 1024 * 1024,
		{.Read},
		false,
		allocator,
	)
	if open_err != nil {
		free(base_ptr, allocator)
		return {}, false
	}
	base_ptr^ = base_c

	base_size, sz_err := xitdb.core_length(base_ptr)
	if sz_err != nil {
		_ = xitdb.core_destroy(base_ptr, close_file = true)
		free(base_ptr, allocator)
		return {}, false
	}

	core_ptr, core_err := new(xitdb.Core, allocator)
	if core_err != nil {
		_ = xitdb.core_destroy(base_ptr, close_file = true)
		free(base_ptr, allocator)
		return {}, false
	}
	ov_c, ov_err := xitdb.core_overlay_init(base_ptr, base_size, allocator)
	if ov_err != nil {
		free(core_ptr, allocator)
		_ = xitdb.core_destroy(base_ptr, close_file = true)
		free(base_ptr, allocator)
		return {}, false
	}
	core_ptr^ = ov_c

	db, db_err := xitdb.database_init(core_ptr, xitdb.sha1_hasher())
	if db_err != nil {
		_ = xitdb.core_destroy(core_ptr, close_file = false)
		free(core_ptr, allocator)
		_ = xitdb.core_destroy(base_ptr, close_file = true)
		free(base_ptr, allocator)
		return {}, false
	}

	st.allocator = allocator
	st.core = core_ptr
	st.base_core = base_ptr
	st.is_file = true
	st.is_overlay = true
	st.path = strings.clone(path, allocator)
	st.write_opts = default_store_write_options()
	st.db = db
	return st, true
}

store_set_write_options :: proc(st: ^Store, opts: Store_Write_Options) {
	if st == nil {
		return
	}
	st.write_opts = opts
}

store_overlay_owned_bytes :: proc(st: ^Store) -> i64 {
	if st == nil || st.core == nil || !st.is_overlay {
		return 0
	}
	return xitdb.core_overlay_owned_bytes(st.core)
}

store_close :: proc(st: ^Store) {
	if st == nil {
		return
	}
	if st.core != nil {
		_ = xitdb.core_destroy(st.core, close_file = st.is_file && !st.is_overlay)
		free(st.core, st.allocator)
	}
	if st.base_core != nil {
		_ = xitdb.core_destroy(st.base_core, close_file = true)
		free(st.base_core, st.allocator)
	}
	delete(st.path, st.allocator)
	st^ = {}
}

commit_summary_destroy :: proc(cs: ^Commit_Summary, allocator := context.allocator) {
	delete(cs.commit, allocator)
	for l in cs.langs {
		delete(l, allocator)
	}
	delete(cs.langs)
	for r in cs.run_ids {
		delete(r, allocator)
	}
	delete(cs.run_ids)
	cs^ = {}
}

commit_summaries_destroy :: proc(list: []Commit_Summary, allocator := context.allocator) {
	for &cs in list {
		commit_summary_destroy(&cs, allocator)
	}
	delete(list, allocator)
}

run_summary_destroy :: proc(rs: ^Run_Summary, allocator := context.allocator) {
	delete(rs.run_id, allocator)
	delete(rs.commit, allocator)
	delete(rs.lang, allocator)
	delete(rs.suite_name, allocator)
	rs^ = {}
}

run_summaries_destroy :: proc(list: []Run_Summary, allocator := context.allocator) {
	for &rs in list {
		run_summary_destroy(&rs, allocator)
	}
	delete(list, allocator)
}

CZPK_V1_MAGIC :: "CZPK\x01\x00\x00\x00"
CZPK_V2_MAGIC :: "CZPK\x02\x00\x00\x00"
CZRC_MAGIC :: "CZRC\x01\x00\x00\x00"

@(private = "file")
_append_u32_le :: proc(buf: ^[dynamic]u8, v: u32) {
	le := u32le(v)
	b := transmute([4]u8)le
	append(buf, ..b[:])
}

@(private = "file")
_append_i64_le :: proc(buf: ^[dynamic]u8, v: i64) {
	le := u64le(u64(v))
	b := transmute([8]u8)le
	append(buf, ..b[:])
}

@(private = "file")
_append_str_le :: proc(buf: ^[dynamic]u8, s: string) {
	_append_u32_le(buf, u32(len(s)))
	if len(s) > 0 {
		append(buf, ..transmute([]u8)s)
	}
}

@(private = "file", require_results)
_read_u32_at :: proc(data: []u8, pos: ^int) -> (val: u32, ok: bool) {
	if pos^ + 4 > len(data) {
		return 0, false
	}
	b: [4]u8
	copy(b[:], data[pos^:pos^ + 4])
	pos^ += 4
	return u32(transmute(u32le)b), true
}

@(private = "file", require_results)
_read_i64_at :: proc(data: []u8, pos: ^int) -> (val: i64, ok: bool) {
	if pos^ + 8 > len(data) {
		return 0, false
	}
	b: [8]u8
	copy(b[:], data[pos^:pos^ + 8])
	pos^ += 8
	return i64(u64(transmute(u64le)b)), true
}

@(private = "file", require_results)
_read_str_at :: proc(
	data: []u8,
	pos: ^int,
	allocator: runtime.Allocator,
) -> (
	val: string,
	ok: bool,
) {
	n := int(_read_u32_at(data, pos) or_return)
	if n < 0 || pos^ + n > len(data) {
		return "", false
	}
	s := strings.clone(string(data[pos^:pos^ + n]), allocator)
	pos^ += n
	return s, true
}

@(private = "file", require_results)
_encode_compressed_packet :: proc(
	pkt: hugi.Run_Packet,
	opts: Store_Write_Options,
	syms: ^_Symbol_Table = nil,
	descs: ^_Descriptor_Table = nil,
	allocator := context.temp_allocator,
) -> (
	out: []u8,
	ok: bool,
) {
	if (opts.use_symbol_table || opts.use_descriptors || opts.use_rational_time) && syms != nil {
		return _v3_encode_packet(pkt, syms, descs, opts, allocator)
	}

	meta_raw := hugi.encode_packet_bytes(
		pkt,
		include_samples = false,
		allocator = context.temp_allocator,
	)
	defer delete(meta_raw, context.temp_allocator)
	meta_comp := compress_bytes_zlib(meta_raw, context.temp_allocator) or_return
	defer delete(meta_comp, context.temp_allocator)

	total_samples := 0
	for r in pkt.records {
		total_samples += len(r.samples_batch_ns)
	}
	all_samples := make([dynamic]f64, 0, total_samples, context.temp_allocator)
	defer delete(all_samples)
	for r in pkt.records {
		_append_record_samples_as_f64(&all_samples, r)
	}
	s_blob := _compress_sample_vec(
		all_samples[:],
		opts.use_domain_f64,
		context.temp_allocator,
	) or_return
	defer delete(s_blob, context.temp_allocator)

	buf := make(
		[dynamic]u8,
		0,
		len(CZPK_V2_MAGIC) + 12 + len(meta_comp) + len(pkt.records) * 4 + len(s_blob),
		allocator,
	)
	append(&buf, ..transmute([]u8)string(CZPK_V2_MAGIC))
	_append_u32_le(&buf, u32(len(meta_comp)))
	append(&buf, ..meta_comp)
	_append_u32_le(&buf, u32(len(pkt.records)))
	for r in pkt.records {
		_append_u32_le(&buf, u32(len(r.samples_batch_ns)))
	}
	_append_u32_le(&buf, u32(len(s_blob)))
	append(&buf, ..s_blob)
	return buf[:], true
}

@(private = "file", require_results)
_decode_compressed_packet :: proc(
	blob: []u8,
	syms: _Symbol_Table = {},
	descs: _Descriptor_Table = {},
	allocator := context.allocator,
) -> (
	pkt: hugi.Run_Packet,
	ok: bool,
) {
	if len(blob) < len(CZPK_V2_MAGIC) {
		return {}, false
	}
	magic := string(blob[:len(CZPK_V2_MAGIC)])
	if magic == CZPK_V3_MAGIC || magic == CZPK_V4_MAGIC {
		return _v3_decode_packet(blob, syms, descs, allocator)
	}
	if magic != CZPK_V1_MAGIC && magic != CZPK_V2_MAGIC {
		return {}, false
	}
	defer if !ok {
		hugi.packet_destroy(&pkt, allocator)
	}
	pos := len(CZPK_V2_MAGIC)
	meta_len := int(_read_u32_at(blob, &pos) or_return)
	if meta_len < 0 || pos + meta_len > len(blob) {
		return {}, false
	}
	meta_raw := decompress_bytes_zlib(blob[pos:pos + meta_len], context.temp_allocator) or_return
	defer delete(meta_raw, context.temp_allocator)
	pos += meta_len

	pkt = hugi.decode_packet_bytes(meta_raw, allocator) or_return

	rec_count := int(_read_u32_at(blob, &pos) or_return)
	if rec_count != len(pkt.records) {
		return pkt, false
	}

	if magic == CZPK_V1_MAGIC {
		for i in 0 ..< rec_count {
			s_len := int(_read_u32_at(blob, &pos) or_return)
			if s_len < 0 || pos + s_len > len(blob) {
				return pkt, false
			}
			samples := decompress_samples_f64(
				blob[pos:pos + s_len],
				context.temp_allocator,
			) or_return
			pos += s_len
			clear(&pkt.records[i].samples_batch_ns)
			ops := pkt.records[i].ops_per_sample
			for s in samples {
				append(&pkt.records[i].samples_batch_ns, hugi.legacy_ns_to_batch_ns(s, ops))
			}
			delete(samples, context.temp_allocator)
			if len(pkt.records[i].samples_batch_ns) > 0 {
				keep_mbs := pkt.records[i].bytes_per_op == 0 && pkt.records[i].mb_per_sec != 0
				_finalize_record_stats_from_samples(&pkt.records[i], keep_mbs)
			}
		}
		return pkt, true
	}

	sample_counts := make([]int, rec_count, context.temp_allocator)
	defer delete(sample_counts, context.temp_allocator)
	expected_total := 0
	for i in 0 ..< rec_count {
		cnt := int(_read_u32_at(blob, &pos) or_return)
		if cnt < 0 || cnt > 10_000_000 || expected_total > 100_000_000 - cnt {
			return pkt, false
		}
		sample_counts[i] = cnt
		expected_total += cnt
	}

	s_len := int(_read_u32_at(blob, &pos) or_return)
	if s_len < 0 || pos + s_len > len(blob) {
		return pkt, false
	}
	all_samples := decompress_samples_f64(blob[pos:pos + s_len], context.temp_allocator) or_return
	defer delete(all_samples, context.temp_allocator)
	if len(all_samples) != expected_total {
		return pkt, false
	}

	off := 0
	for i in 0 ..< rec_count {
		cnt := sample_counts[i]
		clear(&pkt.records[i].samples_batch_ns)
		if cnt > 0 {
			ops := pkt.records[i].ops_per_sample
			for s in all_samples[off:off + cnt] {
				append(&pkt.records[i].samples_batch_ns, hugi.legacy_ns_to_batch_ns(s, ops))
			}
			keep_mbs := pkt.records[i].bytes_per_op == 0 && pkt.records[i].mb_per_sec != 0
			_finalize_record_stats_from_samples(&pkt.records[i], keep_mbs)
		}
		off += cnt
	}
	return pkt, true
}

@(private = "file")
_pack_snapshot_ref :: #force_inline proc "contextless" (run_ord: int, rec_idx: int) -> u64 {
	return (u64(u32(run_ord) & 0x7FFF_FFFF) << 32) | u64(u32(rec_idx))
}

@(private = "file")
_unpack_snapshot_ref :: #force_inline proc "contextless" (
	packed: u64,
) -> (
	run_ord: int,
	rec_idx: int,
) {
	return int((packed >> 32) & 0x7FFF_FFFF), int(packed & 0xFFFF_FFFF)
}

@(private = "file", require_results)
_decode_legacy_snapshot_commit :: proc(
	blob: []u8,
	allocator := context.temp_allocator,
) -> (
	commit: string,
	ok: bool,
) {
	if len(blob) < len(CZRC_MAGIC) || string(blob[:len(CZRC_MAGIC)]) != CZRC_MAGIC {
		return "", false
	}
	pos := len(CZRC_MAGIC)
	return _read_str_at(blob, &pos, allocator)
}

@(private = "file")
_COLD_CHUNK_MAX_RUNS :: 128

@(private = "file")
_Ingest_Batch_Ctx :: struct {
	pkts:         []hugi.Run_Packet,
	opts:         Store_Write_Options,
	allow_rollup: bool,
	allocator:    runtime.Allocator,
	failed:       bool,
}

@(private = "file")
_array_list_contains_commit_ref :: proc(
	list: xitdb.Read_Array_List,
	run_ord: int,
	run_key: string,
) -> bool {
	it, it_err := xitdb.array_list_iterator(list)
	if it_err != nil {
		return false
	}
	for {
		cur_maybe, n_err := xitdb.cursor_iterator_next(&it)
		if n_err != nil || cur_maybe == nil {
			break
		}
		cur := cur_maybe.?
		#partial switch cur.slot_ptr.slot.tag {
		case .Uint:
			ord, u_err := xitdb.cursor_read_uint(cur)
			if u_err == nil && int(ord) == run_ord {
				return true
			}
		case .Bytes, .Short_Bytes:
			s, s_err := xitdb.cursor_read_string(cur, 0, context.temp_allocator)
			if s_err == nil {
				matched := s == run_key
				delete(s, context.temp_allocator)
				if matched {
					return true
				}
			}
		}
	}
	return false
}

@(private = "file")
_load_order_index :: proc(
	list: xitdb.Read_Array_List,
	allocator: runtime.Allocator,
) -> (
	known: map[string]int,
	count: int,
) {
	known = make(map[string]int, allocator)
	it, it_err := xitdb.array_list_iterator(list)
	if it_err != nil {
		return known, 0
	}
	idx := 0
	for {
		cur_maybe, n_err := xitdb.cursor_iterator_next(&it)
		if n_err != nil || cur_maybe == nil {
			break
		}
		s, s_err := xitdb.cursor_read_string(cur_maybe.?, 0, allocator)
		if s_err == nil {
			known[s] = idx
		}
		idx += 1
	}
	return known, idx
}

@(private = "file")
_load_existing_snap_map :: proc(
	snaps_read: xitdb.Read_Hash_Map,
	lang_key: string,
	syms: _Symbol_Table,
	out_map: ^map[string]_Snap_Ref,
	allocator: runtime.Allocator,
) -> bool {
	cur, err := xitdb.hash_map_get_cursor(snaps_read, lang_key)
	if err != nil || cur == nil {
		return true
	}
	#partial switch cur.?.slot_ptr.slot.tag {
	case .None:
		return true
	case .Bytes, .Short_Bytes:
		blob, b_err := xitdb.cursor_read_bytes(cur.?, 0, allocator)
		if b_err != nil {
			return false
		}
		defer delete(blob, allocator)
		return _decode_hsnp_blob(blob, syms, out_map, allocator)
	case .Sorted_Map:
		sm, sm_err := xitdb.read_sorted_map_init(cur.?)
		if sm_err != nil {
			return false
		}
		it, it_err := xitdb.sorted_map_iterator(sm)
		if it_err != nil {
			return false
		}
		for {
			kv_cur, n_err := xitdb.cursor_iterator_next(&it)
			if n_err != nil || kv_cur == nil {
				break
			}
			kv, kv_err := xitdb.cursor_read_kv_pair(kv_cur.?, context.temp_allocator)
			if kv_err != nil {
				continue
			}
			if kv.value_cursor.slot_ptr.slot.tag == .Uint {
				packed, u_err := xitdb.cursor_read_uint(kv.value_cursor)
				if u_err == nil {
					k, k_err := xitdb.cursor_read_string(kv.key_cursor, 0, allocator)
					if k_err == nil {
						r_ord, rec_idx := _unpack_snapshot_ref(packed)
						ref := _Snap_Ref {
							run_ord = u32(r_ord),
							rec_idx = u32(rec_idx),
						}
						if k in out_map {
							out_map[k] = ref
							delete(k, allocator)
						} else {
							out_map[k] = ref
						}
					}
				}
			}
		}
		return true
	}
	return false
}

@(private = "file")
_update_snap_map_for_packet :: proc(
	m: ^map[string]_Snap_Ref,
	pkt: hugi.Run_Packet,
	run_ord: int,
	allocator: runtime.Allocator,
) {
	for r, rec_idx in pkt.records {
		key := r.full_name != "" ? r.full_name : r.name
		ref := _Snap_Ref {
			run_ord = u32(run_ord),
			rec_idx = u32(rec_idx),
		}
		if key in m {
			m[key] = ref
		} else {
			m[strings.clone(key, allocator)] = ref
		}
	}
}

@(private = "file")
_load_syms_and_descs :: proc(
	moment: xitdb.Read_Hash_Map,
	need_syms: bool,
	need_descs: bool,
	allocator: runtime.Allocator,
) -> (
	syms: _Symbol_Table,
	descs: _Descriptor_Table,
	had_syms: bool,
	had_descs: bool,
	ok: bool,
) {
	if need_syms {
		if sym_cur, s_err := xitdb.hash_map_get_cursor(moment, "symbols");
		   s_err == nil && sym_cur != nil {
			had_syms = true
			s_ok: bool
			syms, s_ok = _sym_table_load_from_moment(moment, allocator)
			if !s_ok {
				return {}, {}, false, false, false
			}
		} else {
			syms = _sym_table_init(allocator)
		}
	}
	if need_descs {
		if desc_cur, d_err := xitdb.hash_map_get_cursor(moment, "descriptors");
		   d_err == nil && desc_cur != nil {
			had_descs = true
			d_ok: bool
			descs, d_ok = _desc_table_load_from_moment(moment, allocator)
			if !d_ok {
				_sym_table_destroy(&syms)
				return {}, {}, false, false, false
			}
		} else {
			descs = _desc_table_init(allocator)
		}
	}
	return syms, descs, had_syms, had_descs, true
}

@(private = "file")
_ingest_batch_cb :: proc(cursor: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	ctx := (^_Ingest_Batch_Ctx)(user_data)
	alloc := ctx.allocator
	moment := xitdb.write_hash_map_init(cursor^) or_return

	need_syms :=
		ctx.opts.use_symbol_table || ctx.opts.use_descriptors || ctx.opts.use_rational_time
	is_v3 := need_syms || ctx.opts.use_columnar_rollup
	schema_ver := u64(is_v3 ? 3 : 2)
	xitdb.hash_map_put(&moment, "schema_version", schema_ver) or_return

	syms, descs, had_syms, had_descs, sd_ok := _load_syms_and_descs(
		moment.read_hash_map,
		need_syms,
		ctx.opts.use_descriptors,
		alloc,
	)
	if !sd_ok {
		ctx.failed = true
		return .Unexpected_Tag
	}
	defer _sym_table_destroy(&syms)
	defer _desc_table_destroy(&descs)

	cold_count := 0
	if ctx.allow_rollup && ctx.opts.use_columnar_rollup {
		keep_hot := max(ctx.opts.keep_hot_runs, 0)
		if len(ctx.pkts) - keep_hot >= 2 {
			cold_count = len(ctx.pkts) - keep_hot
		}
	}

	runs_cur := xitdb.hash_map_put_cursor(&moment, "runs") or_return
	runs_map := xitdb.write_hash_map_init(runs_cur) or_return
	order_cur := xitdb.hash_map_put_cursor(&moment, "run_order") or_return
	order_list := xitdb.write_array_list_init(order_cur) or_return
	commits_cur := xitdb.hash_map_put_cursor(&moment, "commits") or_return
	commits_map := xitdb.write_hash_map_init(commits_cur) or_return
	snaps_cur := xitdb.hash_map_put_cursor(&moment, "snapshots") or_return
	snaps_map := xitdb.write_hash_map_init(snaps_cur) or_return

	if cold_count > 0 {
		chunks_cur := xitdb.hash_map_put_cursor(&moment, "cold_chunks") or_return
		chunks_list := xitdb.write_array_list_init(chunks_cur) or_return
		off := 0
		for off < cold_count {
			end := min(off + _COLD_CHUNK_MAX_RUNS, cold_count)
			chk_blob, chk_ok := _encode_cold_chunk(
				ctx.pkts[off:end],
				&syms,
				&descs,
				ctx.opts,
				alloc,
			)
			if !chk_ok {
				ctx.failed = true
				return .Unexpected_Tag
			}
			app_err := xitdb.array_list_append(&chunks_list, chk_blob)
			delete(chk_blob, alloc)
			if app_err != nil {
				return app_err
			}
			off = end
		}
	}

	known_order, next_ord := _load_order_index(order_list.read_array_list, alloc)
	defer {
		for k in known_order {
			delete(k, alloc)
		}
		delete(known_order)
	}

	touched_snaps := make(map[string]map[string]_Snap_Ref, alloc)
	defer {
		for lk, &m in touched_snaps {
			delete(lk, alloc)
			for sk in m {
				delete(sk, alloc)
			}
			delete(m)
		}
		delete(touched_snaps)
	}

	for pkt, i in ctx.pkts {
		lang_key := pkt.lang != "" ? pkt.lang : "odin"
		run_key := fmt.aprintf("%s:%s", lang_key, pkt.run_id, allocator = alloc)
		run_ord, seen_ord := known_order[run_key]
		if !seen_ord {
			run_ord = next_ord
			next_ord += 1
			xitdb.array_list_append(&order_list, run_key) or_return
			known_order[strings.clone(run_key, alloc)] = run_ord
		}

		if i >= cold_count {
			pk_blob, pk_ok := _encode_compressed_packet(pkt, ctx.opts, &syms, &descs, alloc)
			if !pk_ok {
				delete(run_key, alloc)
				ctx.failed = true
				return .Unexpected_Tag
			}
			put_err := xitdb.hash_map_put(&runs_map, run_key, pk_blob)
			delete(pk_blob, alloc)
			if put_err != nil {
				delete(run_key, alloc)
				return put_err
			}
		}

		commit_key := pkt.commit != "" ? pkt.commit : "unknown"
		c_list_cur := xitdb.hash_map_put_cursor(&commits_map, commit_key) or_return
		c_list := xitdb.write_array_list_init(c_list_cur) or_return
		if !_array_list_contains_commit_ref(c_list.read_array_list, run_ord, run_key) {
			if ctx.opts.use_descriptors {
				xitdb.array_list_append(&c_list, u64(run_ord)) or_return
			} else {
				xitdb.array_list_append(&c_list, run_key) or_return
			}
		}
		delete(run_key, alloc)

		if ctx.opts.use_descriptors {
			if lang_key not_in touched_snaps {
				m := make(map[string]_Snap_Ref, alloc)
				if !_load_existing_snap_map(snaps_map.read_hash_map, lang_key, syms, &m, alloc) {
					for sk in m {
						delete(sk, alloc)
					}
					delete(m)
					ctx.failed = true
					return .Unexpected_Tag
				}
				touched_snaps[strings.clone(lang_key, alloc)] = m
			}
			snap_ptr := &touched_snaps[lang_key]
			_update_snap_map_for_packet(snap_ptr, pkt, run_ord, alloc)
		} else {
			lang_cur := xitdb.hash_map_put_cursor(&snaps_map, lang_key) or_return
			lang_sorted := xitdb.write_sorted_map_init(lang_cur) or_return
			for r, rec_idx in pkt.records {
				key := r.full_name != "" ? r.full_name : r.name
				xitdb.sorted_map_put(
					&lang_sorted,
					key,
					_pack_snapshot_ref(run_ord, rec_idx),
				) or_return
			}
		}
	}

	if ctx.opts.use_descriptors {
		for lang_key, snap_m in touched_snaps {
			hsnp_blob, hs_ok := _encode_hsnp_blob(
				snap_m,
				&syms,
				ctx.opts.use_symbol_table,
				9,
				alloc,
			)
			if !hs_ok {
				ctx.failed = true
				return .Unexpected_Tag
			}
			hs_err := xitdb.hash_map_put(&snaps_map, lang_key, hsnp_blob)
			delete(hsnp_blob, alloc)
			if hs_err != nil {
				return hs_err
			}
		}
	}

	if ctx.opts.use_descriptors && (!had_descs || len(descs.items) > descs.initial_count) {
		d_blob, d_ok := _desc_table_encode(descs, 9, alloc)
		if !d_ok {
			ctx.failed = true
			return .Unexpected_Tag
		}
		d_err := xitdb.hash_map_put(&moment, "descriptors", d_blob)
		delete(d_blob, alloc)
		if d_err != nil {
			return d_err
		}
	}

	if need_syms && (!had_syms || len(syms.items) > syms.initial_count) {
		s_blob, s_ok := _sym_table_encode(syms, 9, alloc)
		if !s_ok {
			ctx.failed = true
			return .Unexpected_Tag
		}
		s_err := xitdb.hash_map_put(&moment, "symbols", s_blob)
		delete(s_blob, alloc)
		if s_err != nil {
			return s_err
		}
	}
	return nil
}

@(private = "file", require_results)
_store_ingest_batch_single_moment :: proc(
	st: ^Store,
	pkts: []hugi.Run_Packet,
	allow_rollup := false,
) -> bool {
	if st == nil {
		return false
	}
	if len(pkts) == 0 {
		return true
	}

	rc := xitdb.database_root_cursor(&st.db)
	history, h_err := xitdb.write_array_list_init(rc)
	if h_err != nil {
		return false
	}
	count, c_err := xitdb.array_list_count(history.read_array_list)
	if c_err != nil {
		return false
	}
	base_slot := xitdb.Slot{}
	if count > 0 {
		latest, l_err := xitdb.array_list_get_slot(history.read_array_list, -1)
		if l_err != nil || latest == nil {
			return false
		}
		base_slot = latest.?
	}
	batch_ctx := _Ingest_Batch_Ctx {
		pkts         = pkts,
		opts         = st.write_opts,
		allow_rollup = allow_rollup,
		allocator    = st.allocator,
	}
	err := xitdb.array_list_append_context(&history, base_slot, _ingest_batch_cb, &batch_ctx)
	return err == nil && !batch_ctx.failed
}

/*
Commits `pkt` into `st` as a new CoW `xitdb` `Moment`, structurally sharing untouched
runs, commits, and benchmark snapshot subtrees.
*/
@(require_results)
store_ingest_packet :: proc(st: ^Store, pkt: hugi.Run_Packet) -> bool {
	if st == nil {
		return false
	}
	single := [1]hugi.Run_Packet{pkt}
	return _store_ingest_batch_single_moment(st, single[:], allow_rollup = false)
}

@(private = "file")
_latest_moment_map :: proc(st: ^Store) -> (m: xitdb.Read_Hash_Map, ok: bool) {
	if st == nil {
		return {}, false
	}
	rc := xitdb.database_root_cursor(&st.db)
	history, h_err := xitdb.read_array_list_init(rc.read_cursor)
	if h_err != nil {
		return {}, false
	}
	cnt, c_err := xitdb.array_list_count(history)
	if c_err != nil || cnt <= 0 {
		return {}, false
	}
	cur_maybe, g_err := xitdb.array_list_get_cursor(history, -1)
	if g_err != nil || cur_maybe == nil {
		return {}, false
	}
	rm, m_err := xitdb.read_hash_map_init(cur_maybe.?)
	if m_err != nil {
		return {}, false
	}
	return rm, true
}

@(private = "file")
_Cached_Pkt :: struct {
	pkt:   hugi.Run_Packet,
	taken: bool,
}

@(private = "file")
_Moment_Reader :: struct {
	moment:      xitdb.Read_Hash_Map,
	runs_map:    xitdb.Read_Hash_Map,
	has_runs:    bool,
	syms:        _Symbol_Table,
	descs:       _Descriptor_Table,
	cold_loaded: bool,
	pkt_cache:   map[string]_Cached_Pkt,
	allocator:   runtime.Allocator,
}

@(private = "file", require_results)
_read_run_packet_from_map :: proc(
	runs_map: xitdb.Read_Hash_Map,
	syms: _Symbol_Table,
	descs: _Descriptor_Table,
	run_id: string,
	allocator := context.allocator,
) -> (
	pkt: hugi.Run_Packet,
	ok: bool,
) {
	rc_maybe, err := xitdb.hash_map_get_cursor(runs_map, run_id)
	if err != nil || rc_maybe == nil {
		return {}, false
	}
	blob, b_err := xitdb.cursor_read_bytes(rc_maybe.?, 0, context.temp_allocator)
	if b_err != nil {
		return {}, false
	}
	defer delete(blob, context.temp_allocator)
	return _decode_compressed_packet(blob, syms, descs, allocator)
}

@(private = "file", require_results)
_moment_reader_init :: proc(
	moment: xitdb.Read_Hash_Map,
	allocator := context.allocator,
) -> (
	mr: _Moment_Reader,
	ok: bool,
) {
	syms, descs, _, _, sd_ok := _load_syms_and_descs(
		moment,
		need_syms = true,
		need_descs = true,
		allocator = allocator,
	)
	if !sd_ok {
		return {}, false
	}
	mr.moment = moment
	mr.syms = syms
	mr.descs = descs
	mr.allocator = allocator
	mr.pkt_cache = make(map[string]_Cached_Pkt, allocator)
	if runs_cur, r_err := xitdb.hash_map_get_cursor(moment, "runs");
	   r_err == nil && runs_cur != nil {
		if runs_map, rm_err := xitdb.read_hash_map_init(runs_cur.?); rm_err == nil {
			mr.runs_map = runs_map
			mr.has_runs = true
		}
	}
	return mr, true
}

@(private = "file")
_moment_reader_destroy :: proc(mr: ^_Moment_Reader) {
	if mr == nil {
		return
	}
	for k, &entry in mr.pkt_cache {
		delete(k, mr.allocator)
		if !entry.taken {
			hugi.packet_destroy(&entry.pkt, mr.allocator)
		}
	}
	delete(mr.pkt_cache)
	_sym_table_destroy(&mr.syms)
	_desc_table_destroy(&mr.descs)
	mr^ = {}
}

@(private = "file")
_ensure_cold_chunks_loaded :: proc(mr: ^_Moment_Reader) {
	if mr.cold_loaded {
		return
	}
	mr.cold_loaded = true
	chunks_cur, c_err := xitdb.hash_map_get_cursor(mr.moment, "cold_chunks")
	if c_err != nil || chunks_cur == nil {
		return
	}
	chunks_list, cl_err := xitdb.read_array_list_init(chunks_cur.?)
	if cl_err != nil {
		return
	}
	it, it_err := xitdb.array_list_iterator(chunks_list)
	if it_err != nil {
		return
	}
	for {
		cur_maybe, n_err := xitdb.cursor_iterator_next(&it)
		if n_err != nil || cur_maybe == nil {
			break
		}
		blob, b_err := xitdb.cursor_read_bytes(cur_maybe.?, 0, context.temp_allocator)
		if b_err != nil {
			continue
		}
		pkts, d_ok := _decode_cold_chunk(blob, mr.syms, mr.descs, mr.allocator)
		delete(blob, context.temp_allocator)
		if !d_ok {
			continue
		}
		for &pkt in pkts {
			lang_key := pkt.lang != "" ? pkt.lang : "odin"
			rk := fmt.aprintf("%s:%s", lang_key, pkt.run_id, allocator = mr.allocator)
			overridden := false
			if mr.has_runs {
				if slot_ptr, _ := xitdb.hash_map_get_slot(mr.runs_map, rk); slot_ptr != nil {
					overridden = true
				}
			}
			if overridden || rk in mr.pkt_cache {
				delete(rk, mr.allocator)
				hugi.packet_destroy(&pkt, mr.allocator)
				continue
			}
			mr.pkt_cache[rk] = _Cached_Pkt {
				pkt = pkt,
			}
		}
		delete(pkts, mr.allocator)
	}
}

@(private = "file", require_results)
_moment_reader_get_packet :: proc(
	mr: ^_Moment_Reader,
	rid: string,
) -> (
	pkt: hugi.Run_Packet,
	ok: bool,
) {
	if entry, exists := mr.pkt_cache[rid]; exists {
		return entry.pkt, !entry.taken
	}
	if mr.has_runs {
		if decoded, p_ok := _read_run_packet_from_map(
			mr.runs_map,
			mr.syms,
			mr.descs,
			rid,
			mr.allocator,
		); p_ok {
			mr.pkt_cache[strings.clone(rid, mr.allocator)] = _Cached_Pkt {
				pkt = decoded,
			}
			return decoded, true
		}
	}
	_ensure_cold_chunks_loaded(mr)
	if entry, exists := mr.pkt_cache[rid]; exists {
		return entry.pkt, !entry.taken
	}
	return {}, false
}

@(private = "file", require_results)
_moment_reader_take_packet :: proc(
	mr: ^_Moment_Reader,
	rid: string,
) -> (
	pkt: hugi.Run_Packet,
	ok: bool,
) {
	_, p_ok := _moment_reader_get_packet(mr, rid)
	if !p_ok {
		return {}, false
	}
	entry := mr.pkt_cache[rid]
	if entry.taken {
		return {}, false
	}
	entry.taken = true
	mr.pkt_cache[rid] = entry
	return entry.pkt, true
}

@(private = "file")
_match_commit_prefix :: proc(candidate, query: string) -> bool {
	if query == "" {
		return true
	}
	return strings.has_prefix(candidate, query) || strings.has_prefix(query, candidate)
}

/*
Returns chronological run summaries stored in `st`.
*/
@(require_results)
store_list_runs :: proc(st: ^Store, allocator := context.allocator) -> []Run_Summary {
	out := make([dynamic]Run_Summary, allocator)
	moment, ok := _latest_moment_map(st)
	if !ok {
		return out[:]
	}
	order_cur, o_err := xitdb.hash_map_get_cursor(moment, "run_order")
	if o_err != nil || order_cur == nil {
		return out[:]
	}
	order_list, ol_err := xitdb.read_array_list_init(order_cur.?)
	if ol_err != nil {
		return out[:]
	}
	mr, mr_ok := _moment_reader_init(moment, context.allocator)
	if !mr_ok {
		return out[:]
	}
	defer _moment_reader_destroy(&mr)

	it, it_err := xitdb.array_list_iterator(order_list)
	if it_err != nil {
		return out[:]
	}
	for {
		c_maybe, n_err := xitdb.cursor_iterator_next(&it)
		if n_err != nil || c_maybe == nil {
			break
		}
		rid, s_err := xitdb.cursor_read_string(c_maybe.?, 0, context.temp_allocator)
		if s_err != nil {
			continue
		}
		pkt, pkt_ok := _moment_reader_get_packet(&mr, rid)
		delete(rid, context.temp_allocator)
		if !pkt_ok {
			continue
		}
		total_samples := 0
		for &r in pkt.records {
			total_samples += len(r.samples_batch_ns) > 0 ? len(r.samples_batch_ns) : r.samples
		}
		append(
			&out,
			Run_Summary {
				run_id = strings.clone(pkt.run_id, allocator),
				commit = strings.clone(pkt.commit, allocator),
				lang = strings.clone(pkt.lang, allocator),
				suite_name = strings.clone(pkt.suite_name, allocator),
				timestamp_unix = pkt.timestamp_unix,
				record_count = len(pkt.records),
				total_samples = total_samples,
			},
		)
	}
	return out[:]
}

/*
Returns per-commit summaries (aggregated across runs and languages) in `st`.
*/
@(require_results)
store_list_commits :: proc(st: ^Store, allocator := context.allocator) -> []Commit_Summary {
	out := make([dynamic]Commit_Summary, allocator)
	runs := store_list_runs(st, context.temp_allocator)
	defer run_summaries_destroy(runs, context.temp_allocator)

	idx_by_commit := make(map[string]int, context.temp_allocator)
	for rs in runs {
		idx, seen := idx_by_commit[rs.commit]
		if !seen {
			idx = len(out)
			idx_by_commit[rs.commit] = idx
			append(
				&out,
				Commit_Summary {
					commit = strings.clone(rs.commit, allocator),
					langs = make([dynamic]string, allocator),
					run_ids = make([dynamic]string, allocator),
				},
			)
		}
		cs := &out[idx]
		has_lang := false
		for l in cs.langs {
			if l == rs.lang {
				has_lang = true
				break
			}
		}
		if !has_lang {
			append(&cs.langs, strings.clone(rs.lang, allocator))
		}
		append(&cs.run_ids, strings.clone(rs.run_id, allocator))
		if rs.record_count > cs.bench_count {
			cs.bench_count = rs.record_count
		}
		cs.total_samples += rs.total_samples
	}
	return out[:]
}

@(private = "file", require_results)
_read_string_list :: proc(
	list_cur: xitdb.Read_Cursor,
	allocator := context.temp_allocator,
) -> [dynamic]string {
	out := make([dynamic]string, allocator)
	list, err := xitdb.read_array_list_init(list_cur)
	if err != nil {
		return out
	}
	it, it_err := xitdb.array_list_iterator(list)
	if it_err != nil {
		return out
	}
	for {
		c_maybe, n_err := xitdb.cursor_iterator_next(&it)
		if n_err != nil || c_maybe == nil {
			break
		}
		s, s_err := xitdb.cursor_read_string(c_maybe.?, 0, allocator)
		if s_err == nil {
			append(&out, s)
		}
	}
	return out
}

@(private = "file", require_results)
_read_commit_run_keys :: proc(
	list_cur: xitdb.Read_Cursor,
	run_keys: []string,
	allocator := context.temp_allocator,
) -> [dynamic]string {
	out := make([dynamic]string, allocator)
	list, err := xitdb.read_array_list_init(list_cur)
	if err != nil {
		return out
	}
	it, it_err := xitdb.array_list_iterator(list)
	if it_err != nil {
		return out
	}
	for {
		c_maybe, n_err := xitdb.cursor_iterator_next(&it)
		if n_err != nil || c_maybe == nil {
			break
		}
		cur := c_maybe.?
		#partial switch cur.slot_ptr.slot.tag {
		case .Uint:
			ord, u_err := xitdb.cursor_read_uint(cur)
			if u_err == nil && int(ord) < len(run_keys) {
				append(&out, strings.clone(run_keys[int(ord)], allocator))
			}
		case .Bytes, .Short_Bytes:
			s, s_err := xitdb.cursor_read_string(cur, 0, allocator)
			if s_err == nil {
				append(&out, s)
			}
		}
	}
	return out
}

/*
Loads all lossless `Run_Packet`s from `st` in chronological ingestion order (resolving both
hot `"runs"` packets and cold `"cold_chunks"` columnar rollups).
*/
@(require_results)
store_load_all_packets :: proc(st: ^Store, allocator := context.allocator) -> []hugi.Run_Packet {
	pkts := make([dynamic]hugi.Run_Packet, allocator)
	if moment, has_m := _latest_moment_map(st); has_m {
		order_cur, o_err := xitdb.hash_map_get_cursor(moment, "run_order")
		if o_err == nil && order_cur != nil {
			if mr, mr_ok := _moment_reader_init(moment, allocator); mr_ok {
				defer _moment_reader_destroy(&mr)
				run_keys := _read_string_list(order_cur.?, context.temp_allocator)
				defer {
					for rk in run_keys {
						delete(rk, context.temp_allocator)
					}
					delete(run_keys)
				}
				for rid in run_keys {
					if pkt, pkt_ok := _moment_reader_take_packet(&mr, rid); pkt_ok {
						append(&pkts, pkt)
					}
				}
			}
		}
	}
	return pkts[:]
}

/*
Compacts the `xitdb` store at `db_path` using `opts` (`CZPK\x03`, global symbol/descriptor
tables, domain float codecs, and cold columnar rollup chunks when enabled) via
`xitdb.database_compact` and atomically replaces `db_path`.
*/
@(require_results)
store_compact_with_options :: proc(
	db_path: string,
	opts: Store_Write_Options,
) -> (
	before_bytes: i64,
	after_bytes: i64,
	ok: bool,
) {
	if db_path == "" || db_path == ":memory:" || !os.exists(db_path) {
		return 0, 0, false
	}
	if fi, err := os.stat(db_path, context.temp_allocator); err == nil {
		before_bytes = fi.size
	}

	tmp_path := fmt.tprintf("%s.compact.tmp", db_path)
	defer if !ok && os.exists(tmp_path) {
		_ = os.remove(tmp_path)
	}

	pkts: []hugi.Run_Packet
	{
		src_st, open_ok := store_open(db_path, context.allocator)
		if !open_ok {
			return before_bytes, 0, false
		}
		defer store_close(&src_st)
		pkts = store_load_all_packets(&src_st, context.allocator)
	}
	defer {
		for &p in pkts {
			hugi.packet_destroy(&p)
		}
		delete(pkts)
	}

	if len(pkts) == 0 {
		src_core, src_err := xitdb.core_buffered_file_open(
			db_path,
			2 * 1024 * 1024,
			{.Read},
			false,
		)
		if src_err != nil {
			return before_bytes, 0, false
		}
		defer _ = xitdb.core_destroy(&src_core, close_file = true)

		src_db, db_err := xitdb.database_init(&src_core, xitdb.sha1_hasher())
		if db_err != nil {
			return before_bytes, 0, false
		}

		dst_core, dst_err := xitdb.core_file_open(tmp_path, {.Read, .Write, .Create, .Trunc})
		if dst_err != nil {
			return before_bytes, 0, false
		}
		defer _ = xitdb.core_destroy(&dst_core, close_file = true)

		_, comp_err := xitdb.database_compact(&src_db, &dst_core)
		if comp_err != nil {
			return before_bytes, 0, false
		}
	} else {
		mem_st, mem_ok := store_open(":memory:", context.allocator)
		if !mem_ok {
			return before_bytes, 0, false
		}
		defer store_close(&mem_st)
		store_set_write_options(&mem_st, opts)

		if !_store_ingest_batch_single_moment(&mem_st, pkts, allow_rollup = true) {
			return before_bytes, 0, false
		}

		dst_core, dst_err := xitdb.core_file_open(tmp_path, {.Read, .Write, .Create, .Trunc})
		if dst_err != nil {
			return before_bytes, 0, false
		}
		defer _ = xitdb.core_destroy(&dst_core, close_file = true)

		_, comp_err := xitdb.database_compact(&mem_st.db, &dst_core)
		if comp_err != nil {
			return before_bytes, 0, false
		}
	}

	if fi, err := os.stat(tmp_path, context.temp_allocator); err == nil {
		after_bytes = fi.size
	}
	if os.rename(tmp_path, db_path) != nil {
		return before_bytes, 0, false
	}
	ok = true
	return before_bytes, after_bytes, true
}

/*
Compacts the `xitdb` store at `db_path` using default v3 write options (`CZPK\x03`,
symbols, descriptors, domain float codecs, and cold columnar rollups).
*/
@(require_results)
store_compact :: proc(db_path: string) -> (before_bytes: i64, after_bytes: i64, ok: bool) {
	return store_compact_with_options(db_path, default_store_write_options())
}

/*
Loads matching raw `Record`s from `st` grouped for pooling:
- If `run_id != ""`, loads only that run.
- If `commit != ""`, loads all runs matching `(commit prefix, lang)`.
- Otherwise, loads the latest snapshot per benchmark from `"snapshots"[lang]`, pooling
  multiple runs if the benchmark's latest commit has > 1 run in `"commits"`.
*/
@(require_results)
store_load_raw_groups :: proc(
	st: ^Store,
	lang: string,
	commit := "",
	run_id := "",
	filter := "",
	allocator := context.allocator,
) -> []_Raw_Group {
	groups := make([dynamic]_Raw_Group, allocator)
	by_name := make(map[string]int, context.temp_allocator)

	moment, ok := _latest_moment_map(st)
	if !ok {
		return groups[:]
	}
	mr, mr_ok := _moment_reader_init(moment, context.allocator)
	if !mr_ok {
		return groups[:]
	}
	defer _moment_reader_destroy(&mr)

	add_record := proc(
		groups: ^[dynamic]_Raw_Group,
		by_name: ^map[string]int,
		pkt_commit, pkt_run_id, pkt_suite: string,
		r: hugi.Record,
		filter: string,
		allocator: runtime.Allocator,
	) {
		key := r.full_name != "" ? r.full_name : r.name
		if !hugi.matches_name_filter(filter, key) {
			return
		}
		g_idx, seen := by_name[key]
		if !seen {
			g_idx = len(groups^)
			by_name[key] = g_idx
			append(
				groups,
				_Raw_Group {
					full_name = strings.clone(key, allocator),
					commit = strings.clone(pkt_commit, allocator),
					lang = "",
					suite_name = strings.clone(pkt_suite, allocator),
					run_ids = make([dynamic]string, allocator),
					records = make([dynamic]hugi.Record, allocator),
				},
			)
		}
		g := &groups[g_idx]
		append(&g.run_ids, strings.clone(pkt_run_id, allocator))
		append(&g.records, hugi.record_clone(r, allocator))
	}

	if run_id != "" {
		prefixed_key := fmt.tprintf("%s:%s", lang != "" ? lang : "odin", run_id)
		pkt, pkt_ok := _moment_reader_get_packet(&mr, prefixed_key)
		if !pkt_ok {
			pkt, pkt_ok = _moment_reader_get_packet(&mr, run_id)
		}
		if !pkt_ok || (lang != "" && pkt.lang != lang) {
			return groups[:]
		}
		for r in pkt.records {
			add_record(
				&groups,
				&by_name,
				pkt.commit,
				pkt.run_id,
				pkt.suite_name,
				r,
				filter,
				allocator,
			)
		}
		for &g in groups {
			g.lang = strings.clone(pkt.lang, allocator)
		}
		return groups[:]
	}

	run_keys: [dynamic]string
	if order_cur, o_err := xitdb.hash_map_get_cursor(moment, "run_order");
	   o_err == nil && order_cur != nil {
		run_keys = _read_string_list(order_cur.?, context.temp_allocator)
	}

	if commit != "" {
		candidate_rids: [dynamic]string
		used_commits_index := false
		if c_cur, cm_err := xitdb.hash_map_get_cursor(moment, "commits");
		   cm_err == nil && c_cur != nil {
			if c_map, map_err := xitdb.read_hash_map_init(c_cur.?); map_err == nil {
				if list_cur, l_err := xitdb.hash_map_get_cursor(c_map, commit);
				   l_err == nil && list_cur != nil {
					candidate_rids = _read_commit_run_keys(
						list_cur.?,
						run_keys[:],
						context.temp_allocator,
					)
					used_commits_index = true
				}
			}
		}
		if !used_commits_index {
			if len(run_keys) == 0 {
				return groups[:]
			}
			candidate_rids = run_keys
		}
		for rid in candidate_rids {
			pkt, pkt_ok := _moment_reader_get_packet(&mr, rid)
			if !pkt_ok {
				continue
			}
			if (lang == "" || pkt.lang == lang) && _match_commit_prefix(pkt.commit, commit) {
				for r in pkt.records {
					add_record(
						&groups,
						&by_name,
						pkt.commit,
						pkt.run_id,
						pkt.suite_name,
						r,
						filter,
						allocator,
					)
				}
			}
		}
		for &g in groups {
			g.lang = strings.clone(lang != "" ? lang : "odin", allocator)
		}
		slice.sort_by(groups[:], proc(a, b: _Raw_Group) -> bool {
			return a.records[0].rank < b.records[0].rank
		})
		return groups[:]
	}

	// Default: read latest snapshot pointers for `lang`, then pool matching commits.
	eff_lang := lang != "" ? lang : "odin"
	snaps_cur, s_err := xitdb.hash_map_get_cursor(moment, "snapshots")
	if s_err != nil || snaps_cur == nil {
		return groups[:]
	}
	snaps_map, sm_err := xitdb.read_hash_map_init(snaps_cur.?)
	if sm_err != nil {
		return groups[:]
	}
	lang_cur, l_err := xitdb.hash_map_get_cursor(snaps_map, eff_lang)
	if l_err != nil || lang_cur == nil {
		return groups[:]
	}
	if len(run_keys) == 0 {
		return groups[:]
	}

	snap_latest_commit := make(map[string]string, context.temp_allocator)
	active_commits := make(map[string]bool, context.temp_allocator)

	#partial switch lang_cur.?.slot_ptr.slot.tag {
	case .Bytes, .Short_Bytes:
		blob, b_err := xitdb.cursor_read_bytes(lang_cur.?, 0, context.temp_allocator)
		if b_err != nil {
			return groups[:]
		}
		hsnp_map := make(map[string]_Snap_Ref, context.temp_allocator)
		dec_ok := _decode_hsnp_blob(blob, mr.syms, &hsnp_map, context.temp_allocator)
		delete(blob, context.temp_allocator)
		if !dec_ok {
			return groups[:]
		}
		for key, ref in hsnp_map {
			if !hugi.matches_name_filter(filter, key) {
				continue
			}
			run_ord := int(ref.run_ord)
			if run_ord >= 0 && run_ord < len(run_keys) {
				if pkt, p_ok := _moment_reader_get_packet(&mr, run_keys[run_ord]);
				   p_ok && pkt.commit != "" {
					snap_latest_commit[strings.clone(key, context.temp_allocator)] = strings.clone(
						pkt.commit,
						context.temp_allocator,
					)
					active_commits[pkt.commit] = true
				}
			}
		}
	case .Sorted_Map:
		lang_sorted, ls_err := xitdb.read_sorted_map_init(lang_cur.?)
		if ls_err != nil {
			return groups[:]
		}
		it, it_err := xitdb.sorted_map_iterator(lang_sorted)
		if it_err != nil {
			return groups[:]
		}
		for {
			cur_maybe, n_err := xitdb.cursor_iterator_next(&it)
			if n_err != nil || cur_maybe == nil {
				break
			}
			kv, kv_err := xitdb.cursor_read_kv_pair(cur_maybe.?, context.temp_allocator)
			if kv_err != nil {
				continue
			}
			key, k_err := xitdb.cursor_read_string(kv.key_cursor, 0, context.temp_allocator)
			if k_err != nil || !hugi.matches_name_filter(filter, key) {
				continue
			}

			snap_commit := ""
			#partial switch kv.value_cursor.slot_ptr.slot.tag {
			case .Uint:
				packed, u_err := xitdb.cursor_read_uint(kv.value_cursor)
				if u_err == nil {
					run_ord, _ := _unpack_snapshot_ref(packed)
					if run_ord >= 0 && run_ord < len(run_keys) {
						if pkt, p_ok := _moment_reader_get_packet(&mr, run_keys[run_ord]); p_ok {
							snap_commit = pkt.commit
						}
					}
				}
			case .Bytes, .Short_Bytes:
				blob, b_err := xitdb.cursor_read_bytes(kv.value_cursor, 0, context.temp_allocator)
				if b_err == nil {
					if legacy_commit, c_ok := _decode_legacy_snapshot_commit(
						blob,
						context.temp_allocator,
					); c_ok {
						snap_commit = legacy_commit
					}
					delete(blob, context.temp_allocator)
				}
			}
			if snap_commit != "" {
				snap_latest_commit[strings.clone(key, context.temp_allocator)] = strings.clone(
					snap_commit,
					context.temp_allocator,
				)
				active_commits[snap_commit] = true
			}
		}
	case:
		return groups[:]
	}

	needed_rids := make(map[string]bool, context.temp_allocator)
	fallback_all := false
	if c_cur, cm_err := xitdb.hash_map_get_cursor(moment, "commits");
	   cm_err == nil && c_cur != nil {
		if c_map, map_err := xitdb.read_hash_map_init(c_cur.?); map_err == nil {
			for ac in active_commits {
				if list_cur, lc_err := xitdb.hash_map_get_cursor(c_map, ac);
				   lc_err == nil && list_cur != nil {
					for crid in _read_commit_run_keys(list_cur.?, run_keys[:], context.temp_allocator) {
						needed_rids[crid] = true
					}
				} else {
					fallback_all = true
					break
				}
			}
		} else {
			fallback_all = true
		}
	} else {
		fallback_all = true
	}

	for rid in run_keys {
		if !fallback_all && rid not_in needed_rids {
			continue
		}
		pkt, pkt_ok := _moment_reader_get_packet(&mr, rid)
		if !pkt_ok || pkt.lang != eff_lang {
			continue
		}
		for r in pkt.records {
			key := r.full_name != "" ? r.full_name : r.name
			if target_commit, found := snap_latest_commit[key];
			   found && pkt.commit == target_commit {
				add_record(
					&groups,
					&by_name,
					pkt.commit,
					pkt.run_id,
					pkt.suite_name,
					r,
					filter,
					allocator,
				)
			}
		}
	}

	for &g in groups {
		g.lang = strings.clone(eff_lang, allocator)
	}
	slice.sort_by(groups[:], proc(a, b: _Raw_Group) -> bool {
		return a.records[0].rank < b.records[0].rank
	})
	return groups[:]
}

@(private)
_Raw_Group :: struct {
	full_name:  string,
	commit:     string,
	lang:       string,
	suite_name: string,
	run_ids:    [dynamic]string,
	records:    [dynamic]hugi.Record,
}

@(private)
_raw_groups_destroy :: proc(groups: []_Raw_Group, allocator := context.allocator) {
	for &g in groups {
		delete(g.full_name, allocator)
		delete(g.commit, allocator)
		delete(g.lang, allocator)
		delete(g.suite_name, allocator)
		for r in g.run_ids {
			delete(r, allocator)
		}
		delete(g.run_ids)
		for &rec in g.records {
			hugi.record_destroy(&rec, allocator)
		}
		delete(g.records)
	}
	delete(groups, allocator)
}
