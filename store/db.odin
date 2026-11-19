package hugi_store

import xitdb "../deps/xitdb/xitdb"
import hugi "../hugi"
import "base:runtime"
import "core:os"
import "core:path/filepath"
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

@(private = "package")
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

@(private)
_COLD_CHUNK_MAX_RUNS :: 128

@(private = "file")
_Ingest_Batch_Ctx :: struct {
	pkts:                []hugi.Run_Packet,
	opts:                Store_Write_Options,
	allow_rollup:        bool,
	has_existing_moment: bool,
	allocator:           runtime.Allocator,
	failed:              bool,
}

@(private)
_remove_hash_key_if_exists :: proc(m: ^xitdb.Write_Hash_Map, key: string) -> xitdb.Error {
	if slot, s_err := xitdb.hash_map_get_slot(m.read_hash_map, key); s_err == nil && slot != nil {
		_, rm_err := xitdb.hash_map_remove(m, key)
		return rm_err
	}
	return nil
}

@(private, require_results)
_load_moment_catalog :: proc(
	moment: xitdb.Read_Hash_Map,
	allocator: runtime.Allocator,
) -> (
	cat: _Moment_Catalog,
	ok: bool,
) {
	cat_cur, c_err := xitdb.hash_map_get_cursor(moment, "catalog")
	if c_err != nil || cat_cur == nil {
		return {}, false
	}
	blob, b_err := xitdb.cursor_read_bytes(cat_cur.?, 0, context.temp_allocator)
	if b_err != nil {
		return {}, false
	}
	defer delete(blob, context.temp_allocator)

	cat = _catalog_init(allocator)
	if !_decode_catalog_blob(blob, &cat) {
		_catalog_destroy(&cat)
		return {}, false
	}
	return cat, true
}

@(private = "file")
_ingest_batch_cb :: proc(cursor: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	ctx := (^_Ingest_Batch_Ctx)(user_data)
	alloc := ctx.allocator
	moment := xitdb.write_hash_map_init(cursor^) or_return

	cat: _Moment_Catalog
	if ctx.has_existing_moment {
		c_ok: bool
		cat, c_ok = _load_moment_catalog(moment.read_hash_map, alloc)
		if !c_ok {
			ctx.failed = true
			return .Unexpected_Tag
		}
	} else {
		cat = _catalog_init(alloc)
	}
	defer _catalog_destroy(&cat)

	cold_count := 0
	if ctx.allow_rollup {
		keep_hot := max(ctx.opts.keep_hot_runs, 0)
		if len(ctx.pkts) - keep_hot >= 2 {
			cold_count = len(ctx.pkts) - keep_hot
		}
	}

	if cold_count > 0 {
		xerr, chk_ok := _seal_packets_to_cold_chunks(
			&moment,
			ctx.pkts[:cold_count],
			&cat.syms,
			&cat.descs,
			alloc,
		)
		if !chk_ok {
			ctx.failed = true
			return .Unexpected_Tag
		}
		if xerr != nil {
			return xerr
		}
	}

	runs_map: xitdb.Write_Hash_Map
	runs_map_open := false
	if existing_runs, er_err := xitdb.hash_map_get_cursor(moment.read_hash_map, "runs");
	   er_err == nil && existing_runs != nil {
		runs_cur := xitdb.hash_map_put_cursor(&moment, "runs") or_return
		runs_map = xitdb.write_hash_map_init(runs_cur) or_return
		runs_map_open = true
	}

	for pkt, i in ctx.pkts {
		run_key := _run_key(pkt.lang, pkt.run_id)
		is_cold := i < cold_count
		if !is_cold {
			if prev_ord, seen := cat.run_ord_by_key[run_key];
			   seen && cat.runs[prev_ord].in_cold_chunk {
				cat.has_cold_override = true
			}
		}
		run_ord, _ := _catalog_upsert_run(&cat, pkt, is_cold)
		if !is_cold {
			if !runs_map_open {
				runs_cur := xitdb.hash_map_put_cursor(&moment, "runs") or_return
				runs_map = xitdb.write_hash_map_init(runs_cur) or_return
				runs_map_open = true
			}
			pk_blob, pk_ok := _encode_hot_packet(pkt, &cat.syms, &cat.descs, alloc)
			if !pk_ok {
				ctx.failed = true
				return .Unexpected_Tag
			}
			put_err := xitdb.hash_map_put(&runs_map, run_key, pk_blob)
			delete(pk_blob, alloc)
			if put_err != nil {
				return put_err
			}
		} else if runs_map_open {
			_remove_hash_key_if_exists(&runs_map, run_key) or_return
		}
		_catalog_update_snaps(&cat, pkt, run_ord)
	}

	// Auto-seal fixed-size chronological windows of hot runs into cold columnar chunks.
	if !ctx.allow_rollup && ctx.opts.cold_chunk_runs >= 2 && runs_map_open {
		win := ctx.opts.cold_chunk_runs
		keep_hot := max(ctx.opts.keep_hot_runs, 0)
		unsealed := make([dynamic]int, 0, len(cat.runs), context.temp_allocator)
		defer delete(unsealed)
		for e, ord in cat.runs {
			if !e.in_cold_chunk {
				append(&unsealed, ord)
			}
		}
		pos := 0
		for len(unsealed) - pos >= keep_hot + win {
			seal_ords := unsealed[pos:pos + win]
			seal_pkts := make([dynamic]hugi.Run_Packet, 0, win, context.temp_allocator)
			seal_ok := true
			for sord in seal_ords {
				se := cat.runs[sord]
				srk := _run_key(se.lang, se.run_id)
				spkt, sp_ok := _read_run_packet_from_map(
					runs_map.read_hash_map,
					cat.syms,
					cat.descs,
					srk,
					alloc,
				)
				if !sp_ok {
					seal_ok = false
					break
				}
				append(&seal_pkts, spkt)
			}
			if !seal_ok {
				for &sp in seal_pkts {
					hugi.packet_destroy(&sp, alloc)
				}
				delete(seal_pkts)
				break
			}
			xerr, chk_ok := _seal_packets_to_cold_chunks(
				&moment,
				seal_pkts[:],
				&cat.syms,
				&cat.descs,
				alloc,
			)
			for &sp in seal_pkts {
				hugi.packet_destroy(&sp, alloc)
			}
			delete(seal_pkts)
			if !chk_ok {
				ctx.failed = true
				return .Unexpected_Tag
			}
			if xerr != nil {
				return xerr
			}
			for sord in seal_ords {
				se := &cat.runs[sord]
				srk := _run_key(se.lang, se.run_id)
				_remove_hash_key_if_exists(&runs_map, srk) or_return
				se.in_cold_chunk = true
			}
			pos += win
		}
	}

	hot_remaining := false
	for e in cat.runs {
		if !e.in_cold_chunk {
			hot_remaining = true
			break
		}
	}
	if !hot_remaining {
		_remove_hash_key_if_exists(&moment, "runs") or_return
	}

	cat_blob, cat_ok := _encode_catalog_blob(&cat, alloc)
	if !cat_ok {
		ctx.failed = true
		return .Unexpected_Tag
	}
	put_cat_err := xitdb.hash_map_put(&moment, "catalog", cat_blob)
	delete(cat_blob, alloc)
	return put_cat_err
}

@(private, require_results)
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
		pkts                = pkts,
		opts                = st.write_opts,
		allow_rollup        = allow_rollup,
		has_existing_moment = count > 0,
		allocator           = st.allocator,
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

@(private)
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

@(private)
_Cached_Pkt :: struct {
	pkt:   hugi.Run_Packet,
	taken: bool,
}

@(private)
_Moment_Reader :: struct {
	moment:      xitdb.Read_Hash_Map,
	runs_map:    xitdb.Read_Hash_Map,
	has_runs:    bool,
	cat:         _Moment_Catalog,
	cold_loaded: bool,
	pkt_cache:   map[string]_Cached_Pkt,
	allocator:   runtime.Allocator,
}

@(private, require_results)
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
	return _decode_hot_packet(blob, syms, descs, allocator)
}

@(private, require_results)
_moment_reader_init :: proc(
	moment: xitdb.Read_Hash_Map,
	allocator := context.allocator,
) -> (
	mr: _Moment_Reader,
	ok: bool,
) {
	cat := _load_moment_catalog(moment, allocator) or_return
	mr.cat = cat
	mr.moment = moment
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

@(private)
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
	_catalog_destroy(&mr.cat)
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
		pkts, d_ok := _decode_cold_chunk(blob, mr.cat.syms, mr.cat.descs, mr.allocator)
		delete(blob, context.temp_allocator)
		if !d_ok {
			continue
		}
		for &pkt in pkts {
			rk := _run_key(pkt.lang, pkt.run_id, mr.allocator)
			overridden := false
			if mr.has_runs {
				if slot_ptr, _ := xitdb.hash_map_get_slot(mr.runs_map, rk); slot_ptr != nil {
					overridden = true
				}
			}
			if overridden {
				delete(rk, mr.allocator)
				hugi.packet_destroy(&pkt, mr.allocator)
				continue
			}
			if prev, exists := &mr.pkt_cache[rk]; exists {
				delete(rk, mr.allocator)
				if prev.taken {
					hugi.packet_destroy(&pkt, mr.allocator)
				} else {
					hugi.packet_destroy(&prev.pkt, mr.allocator)
					prev.pkt = pkt
				}
				continue
			}
			mr.pkt_cache[rk] = _Cached_Pkt {
				pkt = pkt,
			}
		}
		delete(pkts, mr.allocator)
	}
}

@(private, require_results)
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
			mr.cat.syms,
			mr.cat.descs,
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

@(private, require_results)
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
