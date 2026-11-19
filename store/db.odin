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

@(private = "file")
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

@(private = "file")
_remove_hash_key_if_exists :: proc(m: ^xitdb.Write_Hash_Map, key: string) -> xitdb.Error {
	if slot, s_err := xitdb.hash_map_get_slot(m.read_hash_map, key); s_err == nil && slot != nil {
		_, rm_err := xitdb.hash_map_remove(m, key)
		return rm_err
	}
	return nil
}

@(private = "file", require_results)
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
		chunks_cur := xitdb.hash_map_put_cursor(&moment, "cold_chunks") or_return
		chunks_list := xitdb.write_array_list_init(chunks_cur) or_return
		off := 0
		for off < cold_count {
			end := min(off + _COLD_CHUNK_MAX_RUNS, cold_count)
			chk_blob, chk_ok := _encode_cold_chunk(ctx.pkts[off:end], &cat.syms, &cat.descs, alloc)
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
			chk_blob, chk_ok := _encode_cold_chunk(seal_pkts[:], &cat.syms, &cat.descs, alloc)
			for &sp in seal_pkts {
				hugi.packet_destroy(&sp, alloc)
			}
			delete(seal_pkts)
			if !chk_ok {
				ctx.failed = true
				return .Unexpected_Tag
			}
			chunks_cur := xitdb.hash_map_put_cursor(&moment, "cold_chunks") or_return
			chunks_list := xitdb.write_array_list_init(chunks_cur) or_return
			app_err := xitdb.array_list_append(&chunks_list, chk_blob)
			delete(chk_blob, alloc)
			if app_err != nil {
				return app_err
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
	cat:         _Moment_Catalog,
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
	return _decode_hot_packet(blob, syms, descs, allocator)
}

@(private = "file", require_results)
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

	cat, c_ok := _load_moment_catalog(moment, context.temp_allocator)
	if !c_ok {
		return out[:]
	}
	defer _catalog_destroy(&cat)

	reserve(&out, len(cat.runs))
	for e in cat.runs {
		append(
			&out,
			Run_Summary {
				run_id = strings.clone(e.run_id, allocator),
				commit = strings.clone(e.commit, allocator),
				lang = strings.clone(e.lang, allocator),
				suite_name = strings.clone(e.suite_name, allocator),
				timestamp_unix = e.timestamp_unix,
				record_count = e.record_count,
				total_samples = e.total_samples,
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

/*
Loads all lossless `Run_Packet`s from `st` in chronological ingestion order (resolving both
hot `"runs"` packets and cold `"cold_chunks"` columnar rollups).
*/
@(require_results)
store_load_all_packets :: proc(st: ^Store, allocator := context.allocator) -> []hugi.Run_Packet {
	pkts := make([dynamic]hugi.Run_Packet, allocator)
	if moment, has_m := _latest_moment_map(st); has_m {
		if mr, mr_ok := _moment_reader_init(moment, allocator); mr_ok {
			defer _moment_reader_destroy(&mr)
			for e in mr.cat.runs {
				rk := _run_key(e.lang, e.run_id)
				if pkt, pkt_ok := _moment_reader_take_packet(&mr, rk); pkt_ok {
					append(&pkts, pkt)
				}
			}
		}
	}
	return pkts[:]
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
			if n_err != nil || kv_cur == nil {
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
			if n_err != nil || cur_maybe == nil {
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

	dst_core, dst_err := xitdb.core_file_open(tmp_path, {.Read, .Write, .Create, .Trunc})
	if dst_err != nil {
		return true, false
	}
	defer _ = xitdb.core_destroy(&dst_core, close_file = true)

	if _, comp_err := xitdb.database_compact(&mem_st.db, &dst_core); comp_err != nil {
		return true, false
	}
	return true, true
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
		if fi, err := os.stat(tmp_path, context.temp_allocator); err == nil {
			after_bytes = fi.size
		}
		if os.rename(tmp_path, db_path) != nil {
			return before_bytes, 0, false
		}
		ok = true
		return before_bytes, after_bytes, true
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
Compacts the `xitdb` store at `db_path` using default `v5` write options (`HCAT\x01`, `CZPK\x04`,
`CZCH\x02` cold columnar rollups, and `BU` rational `u64` sample codecs).
*/
@(require_results)
store_compact :: proc(db_path: string) -> (before_bytes: i64, after_bytes: i64, ok: bool) {
	return store_compact_with_options(db_path, default_store_write_options())
}

@(private)
_raw_groups_add_record :: proc(
	groups: ^[dynamic]_Raw_Group,
	by_name: ^map[string]int,
	pkt_commit, pkt_run_id, pkt_lang, pkt_suite: string,
	pkt_ts: i64,
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
				lang = strings.clone(pkt_lang, allocator),
				suite_name = strings.clone(pkt_suite, allocator),
				timestamp_unix = pkt_ts,
				run_ids = make([dynamic]string, allocator),
				records = make([dynamic]hugi.Record, allocator),
			},
		)
	}
	g := &groups[g_idx]
	if pkt_ts > g.timestamp_unix {
		g.timestamp_unix = pkt_ts
	}
	append(&g.run_ids, strings.clone(pkt_run_id, allocator))
	append(&g.records, hugi.record_clone(r, allocator))
}

/*
Loads matching raw `Record`s from `st` grouped for pooling:
- If `run_id != ""`, loads only that run.
- If `commit != ""`, loads all runs matching `(commit prefix, lang)`.
- Otherwise, loads the latest snapshot per benchmark, pooling multiple runs if the
  benchmark's latest commit has > 1 run.
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

	if run_id != "" {
		prefixed_key := _run_key(lang, run_id)
		pkt, pkt_ok := _moment_reader_get_packet(&mr, prefixed_key)
		if !pkt_ok {
			pkt, pkt_ok = _moment_reader_get_packet(&mr, run_id)
		}
		if !pkt_ok || (lang != "" && pkt.lang != lang) {
			return groups[:]
		}
		for r in pkt.records {
			_raw_groups_add_record(
				&groups,
				&by_name,
				pkt.commit,
				pkt.run_id,
				pkt.lang,
				pkt.suite_name,
				pkt.timestamp_unix,
				r,
				filter,
				allocator,
			)
		}
		return groups[:]
	}

	if commit != "" {
		eff_out_lang := lang != "" ? lang : "odin"
		for e in mr.cat.runs {
			if (lang != "" && e.lang != lang) || !_match_commit_prefix(e.commit, commit) {
				continue
			}
			rk := _run_key(e.lang, e.run_id)
			pkt, pkt_ok := _moment_reader_get_packet(&mr, rk)
			if !pkt_ok {
				continue
			}
			for r in pkt.records {
				_raw_groups_add_record(
					&groups,
					&by_name,
					pkt.commit,
					pkt.run_id,
					eff_out_lang,
					pkt.suite_name,
					pkt.timestamp_unix,
					r,
					filter,
					allocator,
				)
			}
		}
		slice.sort_by(groups[:], proc(a, b: _Raw_Group) -> bool {
			return a.records[0].rank < b.records[0].rank
		})
		return groups[:]
	}

	eff_lang := lang != "" ? lang : "odin"
	snap_m, has_lang := mr.cat.snaps[eff_lang]
	if !has_lang {
		return groups[:]
	}
	snap_latest_commit := make(map[string]string, context.temp_allocator)
	active_commits := make(map[string]bool, context.temp_allocator)
	for key, ref in snap_m {
		if !hugi.matches_name_filter(filter, key) {
			continue
		}
		run_ord := int(ref.run_ord)
		if run_ord >= 0 && run_ord < len(mr.cat.runs) {
			sc := mr.cat.runs[run_ord].commit
			if sc != "" {
				snap_latest_commit[key] = sc
				active_commits[sc] = true
			}
		}
	}

	for e in mr.cat.runs {
		if e.lang != eff_lang || (e.commit not_in active_commits) {
			continue
		}
		rk := _run_key(eff_lang, e.run_id)
		pkt, pkt_ok := _moment_reader_get_packet(&mr, rk)
		if !pkt_ok || pkt.lang != eff_lang {
			continue
		}
		for r in pkt.records {
			key := r.full_name != "" ? r.full_name : r.name
			if target_commit, found := snap_latest_commit[key];
			   found && pkt.commit == target_commit {
				_raw_groups_add_record(
					&groups,
					&by_name,
					pkt.commit,
					pkt.run_id,
					eff_lang,
					pkt.suite_name,
					pkt.timestamp_unix,
					r,
					filter,
					allocator,
				)
			}
		}
	}

	slice.sort_by(groups[:], proc(a, b: _Raw_Group) -> bool {
		return a.records[0].rank < b.records[0].rank
	})
	return groups[:]
}

@(private)
_Raw_Group :: struct {
	full_name:      string,
	commit:         string,
	lang:           string,
	suite_name:     string,
	timestamp_unix: i64,
	run_ids:        [dynamic]string,
	records:        [dynamic]hugi.Record,
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

@(private)
_store_load_commit_series_raw_groups :: proc(
	st: ^Store,
	lang: string,
	filter := "",
	allocator := context.allocator,
) -> []_Raw_Group {
	out := make([dynamic]_Raw_Group, allocator)
	moment, ok := _latest_moment_map(st)
	if !ok {
		return out[:]
	}
	mr, mr_ok := _moment_reader_init(moment, context.allocator)
	if !mr_ok {
		return out[:]
	}
	defer _moment_reader_destroy(&mr)

	eff_lang := lang != "" ? lang : "odin"

	_Commit_Bucket :: struct {
		groups:  [dynamic]_Raw_Group,
		by_name: map[string]int,
	}
	commit_order := make([dynamic]string, context.temp_allocator)
	buckets := make(map[string]_Commit_Bucket, context.temp_allocator)
	defer {
		for _, &b in buckets {
			delete(b.groups)
			delete(b.by_name)
		}
		for c in commit_order {
			delete(c, context.temp_allocator)
		}
		delete(buckets)
		delete(commit_order)
	}

	for e in mr.cat.runs {
		if lang != "" && e.lang != lang {
			continue
		}
		rk := _run_key(e.lang, e.run_id)
		pkt, p_ok := _moment_reader_get_packet(&mr, rk)
		if !p_ok || (lang != "" && pkt.lang != lang) {
			continue
		}
		ckey := pkt.commit != "" ? pkt.commit : "unknown"
		if ckey not_in buckets {
			c_clone := strings.clone(ckey, context.temp_allocator)
			append(&commit_order, c_clone)
			buckets[c_clone] = _Commit_Bucket {
				groups  = make([dynamic]_Raw_Group, context.temp_allocator),
				by_name = make(map[string]int, context.temp_allocator),
			}
		}
		bp := &buckets[ckey]
		for r in pkt.records {
			_raw_groups_add_record(
				&bp.groups,
				&bp.by_name,
				pkt.commit,
				pkt.run_id,
				eff_lang,
				pkt.suite_name,
				pkt.timestamp_unix,
				r,
				filter,
				allocator,
			)
		}
	}

	for ckey in commit_order {
		bp := &buckets[ckey]
		slice.sort_by(bp.groups[:], proc(a, b: _Raw_Group) -> bool {
			return a.records[0].rank < b.records[0].rank
		})
		for g in bp.groups {
			append(&out, g)
		}
	}
	return out[:]
}

@(private)
_store_load_all_run_raw_groups :: proc(
	st: ^Store,
	lang: string,
	filter := "",
	allocator := context.allocator,
) -> []_Raw_Group {
	out := make([dynamic]_Raw_Group, allocator)
	moment, ok := _latest_moment_map(st)
	if !ok {
		return out[:]
	}
	mr, mr_ok := _moment_reader_init(moment, context.allocator)
	if !mr_ok {
		return out[:]
	}
	defer _moment_reader_destroy(&mr)

	eff_lang := lang != "" ? lang : "odin"
	for e in mr.cat.runs {
		if lang != "" && e.lang != lang {
			continue
		}
		rk := _run_key(e.lang, e.run_id)
		pkt, p_ok := _moment_reader_get_packet(&mr, rk)
		if !p_ok || (lang != "" && pkt.lang != lang) {
			continue
		}
		out_lang := pkt.lang != "" ? pkt.lang : eff_lang
		for r in pkt.records {
			key := r.full_name != "" ? r.full_name : r.name
			if !hugi.matches_name_filter(filter, key) {
				continue
			}
			rids := make([dynamic]string, allocator)
			append(&rids, strings.clone(pkt.run_id, allocator))
			recs := make([dynamic]hugi.Record, allocator)
			append(&recs, hugi.record_clone(r, allocator))
			append(
				&out,
				_Raw_Group {
					full_name = strings.clone(key, allocator),
					commit = strings.clone(pkt.commit, allocator),
					lang = strings.clone(out_lang, allocator),
					suite_name = strings.clone(pkt.suite_name, allocator),
					timestamp_unix = pkt.timestamp_unix,
					run_ids = rids,
					records = recs,
				},
			)
		}
	}
	return out[:]
}
