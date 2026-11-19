package hugi_store

import xitdb "../deps/xitdb/xitdb"
import hugi "../hugi"
import "base:runtime"
import "core:fmt"
import "core:os"

@(private, require_results)
_seal_packets_to_cold_chunks :: proc(
	moment: ^xitdb.Write_Hash_Map,
	pkts: []hugi.Run_Packet,
	syms: ^_Symbol_Table,
	descs: ^_Descriptor_Table,
	allocator: runtime.Allocator,
) -> (
	xitdb_err: xitdb.Error,
	encode_ok: bool,
) {
	if len(pkts) == 0 {
		return nil, true
	}
	chunks_cur, c_err := xitdb.hash_map_put_cursor(moment, "cold_chunks")
	if c_err != nil {
		return c_err, true
	}
	chunks_list, l_err := xitdb.write_array_list_init(chunks_cur)
	if l_err != nil {
		return l_err, true
	}
	off := 0
	for off < len(pkts) {
		end := min(off + _COLD_CHUNK_MAX_RUNS, len(pkts))
		chk_blob, chk_ok := _encode_cold_chunk(pkts[off:end], syms, descs, allocator)
		if !chk_ok {
			return nil, false
		}
		app_err := xitdb.array_list_append(&chunks_list, chk_blob)
		delete(chk_blob, allocator)
		if app_err != nil {
			return app_err, true
		}
		off = end
	}
	return nil, true
}

@(private, require_results)
_compact_db_to_tmp :: proc(src_db: ^xitdb.Database, tmp_path: string) -> bool {
	dst_core, dst_err := xitdb.core_file_open(tmp_path, {.Read, .Write, .Create, .Trunc})
	if dst_err != nil {
		return false
	}
	defer _ = xitdb.core_destroy(&dst_core, close_file = true)

	_, comp_err := xitdb.database_compact(src_db, &dst_core)
	return comp_err == nil
}

@(private, require_results)
_finalize_atomic_replace :: proc(
	tmp_path: string,
	db_path: string,
) -> (
	after_bytes: i64,
	ok: bool,
) {
	if fi, err := os.stat(tmp_path, context.temp_allocator); err == nil {
		after_bytes = fi.size
	}
	if os.rename(tmp_path, db_path) != nil {
		return 0, false
	}
	return after_bytes, true
}

@(private, require_results)
_compact_db_to_path_atomic :: proc(
	src_db: ^xitdb.Database,
	db_path: string,
	tmp_path: string,
) -> (
	after_bytes: i64,
	ok: bool,
) {
	if !_compact_db_to_tmp(src_db, tmp_path) {
		return 0, false
	}
	return _finalize_atomic_replace(tmp_path, db_path)
}

@(private = "file")
_Fast_Compact_Ctx :: struct {
	cat:         ^_Moment_Catalog,
	chunk_blobs: [][]u8,
	hot_blobs:   map[int][]u8,
	keep_ords:   []int,
	failed:      bool,
}

@(private = "file")
_fast_compact_moment_cb :: proc(cursor: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	ctx := (^_Fast_Compact_Ctx)(user_data)
	moment := xitdb.write_hash_map_init(cursor^) or_return

	if len(ctx.chunk_blobs) > 0 {
		chunks_cur := xitdb.hash_map_put_cursor(&moment, "cold_chunks") or_return
		chunks_list := xitdb.write_array_list_init(chunks_cur) or_return
		for cb in ctx.chunk_blobs {
			xitdb.array_list_append(&chunks_list, cb) or_return
		}
	}

	if len(ctx.keep_ords) > 0 {
		runs_cur := xitdb.hash_map_put_cursor(&moment, "runs") or_return
		runs_map := xitdb.write_hash_map_init(runs_cur) or_return
		for ord in ctx.keep_ords {
			e := ctx.cat.runs[ord]
			rk := _run_key(e.lang, e.run_id)
			xitdb.hash_map_put(&runs_map, rk, ctx.hot_blobs[ord]) or_return
		}
	}

	cat_blob, cat_ok := _encode_catalog_blob(ctx.cat, context.temp_allocator)
	if !cat_ok {
		ctx.failed = true
		return .Unexpected_Tag
	}
	put_cat_err := xitdb.hash_map_put(&moment, "catalog", cat_blob)
	delete(cat_blob, context.temp_allocator)
	return put_cat_err
}

@(private = "file")
_try_fast_catalog_compact :: proc(
	db_path: string,
	tmp_path: string,
	opts: Store_Write_Options,
) -> (
	attempted: bool,
	ok: bool,
) {
	src_st, open_ok := store_open(db_path, context.allocator)
	if !open_ok {
		return false, false
	}
	defer store_close(&src_st)

	moment, has_m := _latest_moment_map(&src_st)
	if !has_m {
		return false, false
	}
	cat, dec_ok := _load_moment_catalog(moment, context.allocator)
	if !dec_ok {
		return true, false
	}
	defer _catalog_destroy(&cat)
	if len(cat.runs) == 0 || cat.has_cold_override {
		return false, false
	}

	hot_blobs := make(map[int][]u8, context.temp_allocator)
	defer {
		for _, blob in hot_blobs {
			delete(blob, context.temp_allocator)
		}
		delete(hot_blobs)
	}
	if runs_cur, r_err := xitdb.hash_map_get_cursor(moment, "runs");
	   r_err == nil && runs_cur != nil {
		runs_map, rm_err := xitdb.read_hash_map_init(runs_cur.?)
		if rm_err != nil {
			return true, false
		}
		it, it_err := xitdb.hash_map_iterator(runs_map)
		if it_err != nil {
			return true, false
		}
		for {
			kv_cur, n_err := xitdb.cursor_iterator_next(&it)
			if n_err != nil {
				return true, false
			}
			if kv_cur == nil {
				break
			}
			kv, kv_err := xitdb.cursor_read_kv_pair(kv_cur.?, context.temp_allocator)
			if kv_err != nil {
				return true, false
			}
			rk, k_err := xitdb.cursor_read_string(kv.key_cursor, 0, context.temp_allocator)
			if k_err != nil {
				return true, false
			}
			ord, known := cat.run_ord_by_key[rk]
			delete(rk, context.temp_allocator)
			if !known || cat.runs[ord].in_cold_chunk {
				return true, false
			}
			val_blob, vb_err := xitdb.cursor_read_bytes(kv.value_cursor, 0, context.temp_allocator)
			if vb_err != nil ||
			   len(val_blob) < len(CZPK_V4_MAGIC) ||
			   string(val_blob[:len(CZPK_V4_MAGIC)]) != CZPK_V4_MAGIC {
				delete(val_blob, context.temp_allocator)
				return true, false
			}
			hot_blobs[ord] = val_blob
		}
	}

	unsealed_ords := make([dynamic]int, 0, len(cat.runs), context.temp_allocator)
	defer delete(unsealed_ords)
	sealed_count := 0
	for e, ord in cat.runs {
		if e.in_cold_chunk {
			sealed_count += 1
		} else {
			if ord not_in hot_blobs {
				return true, false
			}
			append(&unsealed_ords, ord)
		}
	}

	chunk_blobs := make([dynamic][]u8, context.temp_allocator)
	defer {
		for cb in chunk_blobs {
			delete(cb, context.temp_allocator)
		}
		delete(chunk_blobs)
	}
	if chunks_cur, ch_err := xitdb.hash_map_get_cursor(moment, "cold_chunks");
	   ch_err == nil && chunks_cur != nil {
		chunks_list, cl_err := xitdb.read_array_list_init(chunks_cur.?)
		if cl_err != nil {
			return true, false
		}
		it, it_err := xitdb.array_list_iterator(chunks_list)
		if it_err != nil {
			return true, false
		}
		for {
			cur_maybe, n_err := xitdb.cursor_iterator_next(&it)
			if n_err != nil {
				return true, false
			}
			if cur_maybe == nil {
				break
			}
			cb, cb_err := xitdb.cursor_read_bytes(cur_maybe.?, 0, context.temp_allocator)
			if cb_err != nil ||
			   len(cb) < len(CZCH_V2_MAGIC) ||
			   string(cb[:len(CZCH_V2_MAGIC)]) != CZCH_V2_MAGIC {
				delete(cb, context.temp_allocator)
				return true, false
			}
			append(&chunk_blobs, cb)
		}
	}
	if (sealed_count > 0 && len(chunk_blobs) == 0) || (sealed_count == 0 && len(chunk_blobs) > 0) {
		return true, false
	}

	keep_hot := max(opts.keep_hot_runs, 0)
	if sealed_count > 0 && len(unsealed_ords) < keep_hot {
		return false, false
	}

	to_seal_n := 0
	if len(unsealed_ords) > keep_hot {
		rem := len(unsealed_ords) - keep_hot
		if len(chunk_blobs) > 0 || rem >= 2 {
			to_seal_n = rem
		}
	}

	if to_seal_n > 0 {
		off := 0
		for off < to_seal_n {
			end := min(off + _COLD_CHUNK_MAX_RUNS, to_seal_n)
			batch_n := end - off
			seal_pkts := make([dynamic]hugi.Run_Packet, 0, batch_n, context.temp_allocator)
			for ord in unsealed_ords[off:end] {
				pkt, p_ok := _decode_hot_packet(
					hot_blobs[ord],
					cat.syms,
					cat.descs,
					context.allocator,
				)
				if !p_ok {
					for &sp in seal_pkts {
						hugi.packet_destroy(&sp)
					}
					delete(seal_pkts)
					return true, false
				}
				append(&seal_pkts, pkt)
			}
			new_chk, chk_ok := _encode_cold_chunk(
				seal_pkts[:],
				&cat.syms,
				&cat.descs,
				context.temp_allocator,
			)
			for &sp in seal_pkts {
				hugi.packet_destroy(&sp)
			}
			delete(seal_pkts)
			if !chk_ok {
				return true, false
			}
			append(&chunk_blobs, new_chk)
			for ord in unsealed_ords[off:end] {
				cat.runs[ord].in_cold_chunk = true
			}
			off = end
		}
	}

	mem_st, mem_ok := store_open(":memory:", context.allocator)
	if !mem_ok {
		return true, false
	}
	defer store_close(&mem_st)
	store_set_write_options(&mem_st, opts)

	rc := xitdb.database_root_cursor(&mem_st.db)
	history, h_err := xitdb.write_array_list_init(rc)
	if h_err != nil {
		return true, false
	}
	fctx := _Fast_Compact_Ctx {
		cat         = &cat,
		chunk_blobs = chunk_blobs[:],
		hot_blobs   = hot_blobs,
		keep_ords   = unsealed_ords[to_seal_n:],
	}
	if app_err := xitdb.array_list_append_context(
		&history,
		xitdb.Slot{},
		_fast_compact_moment_cb,
		&fctx,
	); app_err != nil || fctx.failed {
		return true, false
	}

	return true, _compact_db_to_tmp(&mem_st.db, tmp_path)
}

/*
Compacts the `xitdb` store at `db_path` using `opts` (`HCAT\x01`, `CZPK\x04`, global symbol/descriptor
tables, rational `u64` codecs, and cold columnar rollup chunks) via `xitdb.database_compact` and
atomically replaces `db_path`. Reuses already-sealed `CZCH\x02` chunks verbatim in `O(hot_runs)`
when possible.
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

	if attempted, fast_ok := _try_fast_catalog_compact(db_path, tmp_path, opts); attempted {
		if !fast_ok {
			return before_bytes, 0, false
		}
		after, rep_ok := _finalize_atomic_replace(tmp_path, db_path)
		if !rep_ok {
			return before_bytes, 0, false
		}
		ok = true
		return before_bytes, after, true
	}

	pkts: []hugi.Run_Packet
	{
		src_st, open_ok := store_open(db_path, context.allocator)
		if !open_ok {
			return before_bytes, 0, false
		}
		defer store_close(&src_st)
		if moment, has_m := _latest_moment_map(&src_st); has_m {
			cat, c_ok := _load_moment_catalog(moment, context.temp_allocator)
			if !c_ok {
				return before_bytes, 0, false
			}
			_catalog_destroy(&cat)
		}
		pkts = store_load_all_packets(&src_st, context.allocator)
	}
	defer {
		for &p in pkts {
			hugi.packet_destroy(&p)
		}
		delete(pkts)
	}

	if len(pkts) == 0 {
		{
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
			if !_compact_db_to_tmp(&src_db, tmp_path) {
				return before_bytes, 0, false
			}
		}
		after, rep_ok := _finalize_atomic_replace(tmp_path, db_path)
		if !rep_ok {
			return before_bytes, 0, false
		}
		ok = true
		return before_bytes, after, true
	}

	mem_st, mem_ok := store_open(":memory:", context.allocator)
	if !mem_ok {
		return before_bytes, 0, false
	}
	defer store_close(&mem_st)
	store_set_write_options(&mem_st, opts)

	if !_store_ingest_batch_single_moment(&mem_st, pkts, allow_rollup = true) {
		return before_bytes, 0, false
	}

	after, comp_ok := _compact_db_to_path_atomic(&mem_st.db, db_path, tmp_path)
	if !comp_ok {
		return before_bytes, 0, false
	}
	ok = true
	return before_bytes, after, true
}

/*
Compacts the `xitdb` store at `db_path` using default `v5` write options (`HCAT\x01`, `CZPK\x04`,
`CZCH\x02` cold columnar rollups, and `BU` rational `u64` sample codecs).
*/
@(require_results)
store_compact :: proc(db_path: string) -> (before_bytes: i64, after_bytes: i64, ok: bool) {
	return store_compact_with_options(db_path, default_store_write_options())
}
