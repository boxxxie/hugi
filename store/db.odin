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
	core:      ^xitdb.Core,
	db:        xitdb.Database,
	is_file:   bool,
	path:      string,
	allocator: runtime.Allocator,
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
	st.db = db
	return st, true
}

store_close :: proc(st: ^Store) {
	if st == nil {
		return
	}
	if st.core != nil {
		_ = xitdb.core_destroy(st.core, close_file = st.is_file)
		free(st.core, st.allocator)
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

CZPK_MAGIC :: "CZPK\x01\x00\x00\x00"
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
	allocator := context.temp_allocator,
) -> (
	out: []u8,
	ok: bool,
) {
	meta_raw := hugi.encode_packet_bytes(
		pkt,
		include_samples = false,
		allocator = context.temp_allocator,
	)
	defer delete(meta_raw, context.temp_allocator)
	meta_comp := compress_bytes_zlib(meta_raw, context.temp_allocator) or_return
	defer delete(meta_comp, context.temp_allocator)

	buf := make(
		[dynamic]u8,
		0,
		len(CZPK_MAGIC) + 4 + len(meta_comp) + len(pkt.records) * 64,
		allocator,
	)
	append(&buf, ..transmute([]u8)string(CZPK_MAGIC))
	_append_u32_le(&buf, u32(len(meta_comp)))
	append(&buf, ..meta_comp)
	_append_u32_le(&buf, u32(len(pkt.records)))

	for r in pkt.records {
		s_blob := compress_samples_f64(
			r.samples_ns[:],
			.Zlib_BSS,
			context.temp_allocator,
		) or_return
		_append_u32_le(&buf, u32(len(s_blob)))
		append(&buf, ..s_blob)
		delete(s_blob, context.temp_allocator)
	}
	return buf[:], true
}

@(private = "file", require_results)
_decode_compressed_packet :: proc(
	blob: []u8,
	allocator := context.allocator,
) -> (
	pkt: hugi.Run_Packet,
	ok: bool,
) {
	if len(blob) < len(CZPK_MAGIC) || string(blob[:len(CZPK_MAGIC)]) != CZPK_MAGIC {
		return {}, false
	}
	defer if !ok {
		hugi.packet_destroy(&pkt, allocator)
	}
	pos := len(CZPK_MAGIC)
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
	for i in 0 ..< rec_count {
		s_len := int(_read_u32_at(blob, &pos) or_return)
		if s_len < 0 || pos + s_len > len(blob) {
			return pkt, false
		}
		samples := decompress_samples_f64(blob[pos:pos + s_len], context.temp_allocator) or_return
		pos += s_len
		clear(&pkt.records[i].samples_ns)
		append(&pkt.records[i].samples_ns, ..samples)
		delete(samples, context.temp_allocator)
	}
	return pkt, true
}

@(private = "file")
_Snapshot_Entry :: struct {
	commit:         string,
	run_id:         string,
	suite_name:     string,
	timestamp_unix: i64,
	record:         hugi.Record,
}

@(private = "file")
_snapshot_entry_destroy :: proc(se: ^_Snapshot_Entry, allocator := context.allocator) {
	delete(se.commit, allocator)
	delete(se.run_id, allocator)
	delete(se.suite_name, allocator)
	hugi.record_destroy(&se.record, allocator)
	se^ = {}
}

@(private = "file", require_results)
_encode_snapshot_entry :: proc(
	pkt: hugi.Run_Packet,
	r: hugi.Record,
	allocator := context.temp_allocator,
) -> (
	out: []u8,
	ok: bool,
) {
	rec_raw := hugi.encode_record_bytes(
		r,
		include_samples = false,
		allocator = context.temp_allocator,
	)
	defer delete(rec_raw, context.temp_allocator)
	rec_comp := compress_bytes_zlib(rec_raw, context.temp_allocator) or_return
	defer delete(rec_comp, context.temp_allocator)
	s_comp := compress_samples_f64(r.samples_ns[:], .Zlib_BSS, context.temp_allocator) or_return
	defer delete(s_comp, context.temp_allocator)

	buf := make([dynamic]u8, 0, len(CZRC_MAGIC) + 64 + len(rec_comp) + len(s_comp), allocator)
	append(&buf, ..transmute([]u8)string(CZRC_MAGIC))
	_append_str_le(&buf, pkt.commit)
	_append_str_le(&buf, pkt.run_id)
	_append_str_le(&buf, pkt.suite_name)
	_append_i64_le(&buf, pkt.timestamp_unix)
	_append_u32_le(&buf, u32(len(rec_comp)))
	append(&buf, ..rec_comp)
	_append_u32_le(&buf, u32(len(s_comp)))
	append(&buf, ..s_comp)
	return buf[:], true
}

@(private = "file", require_results)
_decode_snapshot_entry :: proc(
	blob: []u8,
	allocator := context.allocator,
) -> (
	se: _Snapshot_Entry,
	ok: bool,
) {
	if len(blob) < len(CZRC_MAGIC) || string(blob[:len(CZRC_MAGIC)]) != CZRC_MAGIC {
		return {}, false
	}
	defer if !ok {
		_snapshot_entry_destroy(&se, allocator)
	}
	pos := len(CZRC_MAGIC)
	se.commit = _read_str_at(blob, &pos, allocator) or_return
	se.run_id = _read_str_at(blob, &pos, allocator) or_return
	se.suite_name = _read_str_at(blob, &pos, allocator) or_return
	se.timestamp_unix = _read_i64_at(blob, &pos) or_return

	rec_len := int(_read_u32_at(blob, &pos) or_return)
	if rec_len < 0 || pos + rec_len > len(blob) {
		return se, false
	}
	rec_raw := decompress_bytes_zlib(blob[pos:pos + rec_len], context.temp_allocator) or_return
	defer delete(rec_raw, context.temp_allocator)
	pos += rec_len

	se.record = hugi.decode_record_bytes(rec_raw, allocator) or_return

	s_len := int(_read_u32_at(blob, &pos) or_return)
	if s_len < 0 || pos + s_len > len(blob) {
		return se, false
	}
	samples := decompress_samples_f64(blob[pos:pos + s_len], context.temp_allocator) or_return
	pos += s_len
	append(&se.record.samples_ns, ..samples)
	delete(samples, context.temp_allocator)
	return se, true
}

@(private = "file")
_Ingest_Ctx :: struct {
	pkt:     hugi.Run_Packet,
	pk_blob: []u8,
}

@(private = "file")
_array_list_contains_str :: proc(list: xitdb.Read_Array_List, target: string) -> bool {
	it, it_err := xitdb.array_list_iterator(list)
	if it_err != nil {
		return false
	}
	for {
		cur_maybe, n_err := xitdb.cursor_iterator_next(&it)
		if n_err != nil || cur_maybe == nil {
			break
		}
		s, s_err := xitdb.cursor_read_string(cur_maybe.?, 0, context.temp_allocator)
		if s_err == nil && s == target {
			return true
		}
	}
	return false
}

@(private = "file")
_ingest_cb :: proc(cursor: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	ctx := (^_Ingest_Ctx)(user_data)
	pkt := ctx.pkt

	moment := xitdb.write_hash_map_init(cursor^) or_return
	xitdb.hash_map_put(&moment, "schema_version", u64(1)) or_return

	lang_key := pkt.lang != "" ? pkt.lang : "odin"
	run_key := fmt.tprintf("%s:%s", lang_key, pkt.run_id)

	// 1. Store compressed Run_Packet under "runs"[<lang>:<run_id>].
	runs_cur := xitdb.hash_map_put_cursor(&moment, "runs") or_return
	runs_map := xitdb.write_hash_map_init(runs_cur) or_return
	existed_slot, _ := xitdb.hash_map_get_slot(runs_map.read_hash_map, run_key)
	already_in_runs := existed_slot != nil
	xitdb.hash_map_put(&runs_map, run_key, ctx.pk_blob) or_return

	// 2. Append composite run_key to "run_order" if new.
	order_cur := xitdb.hash_map_put_cursor(&moment, "run_order") or_return
	order_list := xitdb.write_array_list_init(order_cur) or_return
	if !already_in_runs {
		xitdb.array_list_append(&order_list, run_key) or_return
	}

	// 3. Index composite run_key under "commits"[commit].
	commits_cur := xitdb.hash_map_put_cursor(&moment, "commits") or_return
	commits_map := xitdb.write_hash_map_init(commits_cur) or_return
	commit_key := pkt.commit != "" ? pkt.commit : "unknown"
	c_list_cur := xitdb.hash_map_put_cursor(&commits_map, commit_key) or_return
	c_list := xitdb.write_array_list_init(c_list_cur) or_return
	if !_array_list_contains_str(c_list.read_array_list, run_key) {
		xitdb.array_list_append(&c_list, run_key) or_return
	}

	// 4. Update rank-preserving Sorted_Map under "snapshots"[lang][full_name].
	snaps_cur := xitdb.hash_map_put_cursor(&moment, "snapshots") or_return
	snaps_map := xitdb.write_hash_map_init(snaps_cur) or_return
	lang_cur := xitdb.hash_map_put_cursor(&snaps_map, lang_key) or_return
	lang_sorted := xitdb.write_sorted_map_init(lang_cur) or_return
	for r in pkt.records {
		key := r.full_name != "" ? r.full_name : r.name
		snap_blob, s_ok := _encode_snapshot_entry(pkt, r, context.temp_allocator)
		if !s_ok {
			continue
		}
		xitdb.sorted_map_put(&lang_sorted, key, snap_blob) or_return
	}

	return nil
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
	pk_blob, pk_ok := _encode_compressed_packet(pkt, context.temp_allocator)
	if !pk_ok {
		return false
	}
	defer delete(pk_blob, context.temp_allocator)

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

	ctx := _Ingest_Ctx {
		pkt     = pkt,
		pk_blob = pk_blob,
	}
	return xitdb.array_list_append_context(&history, base_slot, _ingest_cb, &ctx) == nil
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
_read_run_packet_from_map :: proc(
	runs_map: xitdb.Read_Hash_Map,
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
	return _decode_compressed_packet(blob, allocator)
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
	runs_cur, r_err := xitdb.hash_map_get_cursor(moment, "runs")
	order_cur, o_err := xitdb.hash_map_get_cursor(moment, "run_order")
	if r_err != nil || runs_cur == nil || o_err != nil || order_cur == nil {
		return out[:]
	}
	runs_map, rm_err := xitdb.read_hash_map_init(runs_cur.?)
	order_list, ol_err := xitdb.read_array_list_init(order_cur.?)
	if rm_err != nil || ol_err != nil {
		return out[:]
	}

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
		pkt, pkt_ok := _read_run_packet_from_map(runs_map, rid, context.temp_allocator)
		if !pkt_ok {
			continue
		}
		total_samples := 0
		for &r in pkt.records {
			total_samples += len(r.samples_ns) > 0 ? len(r.samples_ns) : r.samples
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
		hugi.packet_destroy(&pkt, context.temp_allocator)
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
Compacts the `xitdb` store at `db_path` into a fresh file via `xitdb.database_compact`
and atomically replaces `db_path`.
*/
@(require_results)
store_compact :: proc(db_path: string) -> (before_bytes: i64, after_bytes: i64, ok: bool) {
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

		dst_core, dst_err := xitdb.core_file_open(tmp_path, {.Read, .Write, .Create, .Trunc})
		if dst_err != nil {
			return before_bytes, 0, false
		}
		defer _ = xitdb.core_destroy(&dst_core, close_file = true)

		_, comp_err := xitdb.database_compact(&src_db, &dst_core)
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
	return before_bytes, after_bytes, true
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
	runs_cur, r_err := xitdb.hash_map_get_cursor(moment, "runs")
	if r_err != nil || runs_cur == nil {
		return groups[:]
	}
	runs_map, rm_err := xitdb.read_hash_map_init(runs_cur.?)
	if rm_err != nil {
		return groups[:]
	}

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
		pkt, pkt_ok := _read_run_packet_from_map(runs_map, prefixed_key, context.temp_allocator)
		if !pkt_ok {
			pkt, pkt_ok = _read_run_packet_from_map(runs_map, run_id, context.temp_allocator)
		}
		if !pkt_ok || (lang != "" && pkt.lang != lang) {
			if pkt_ok {
				hugi.packet_destroy(&pkt, context.temp_allocator)
			}
			return groups[:]
		}
		defer hugi.packet_destroy(&pkt, context.temp_allocator)
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

	if commit != "" {
		order_cur, o_err := xitdb.hash_map_get_cursor(moment, "run_order")
		if o_err != nil || order_cur == nil {
			return groups[:]
		}
		order_list, ol_err := xitdb.read_array_list_init(order_cur.?)
		if ol_err != nil {
			return groups[:]
		}
		it, it_err := xitdb.array_list_iterator(order_list)
		if it_err != nil {
			return groups[:]
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
			pkt, pkt_ok := _read_run_packet_from_map(runs_map, rid, context.temp_allocator)
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
			hugi.packet_destroy(&pkt, context.temp_allocator)
		}
		for &g in groups {
			g.lang = strings.clone(lang != "" ? lang : "odin", allocator)
		}
		slice.sort_by(groups[:], proc(a, b: _Raw_Group) -> bool {
			return a.records[0].rank < b.records[0].rank
		})
		return groups[:]
	}

	// Default: read latest snapshots for `lang` (structurally shared across selective runs),
	// then pool any extra runs matching each benchmark's latest commit.
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
	lang_sorted, ls_err := xitdb.read_sorted_map_init(lang_cur.?)
	if ls_err != nil {
		return groups[:]
	}

	snap_latest_commit := make(map[string]string, context.temp_allocator)
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
		blob, b_err := xitdb.cursor_read_bytes(kv.value_cursor, 0, context.temp_allocator)
		if b_err != nil {
			continue
		}
		se, se_ok := _decode_snapshot_entry(blob, context.temp_allocator)
		delete(blob, context.temp_allocator)
		if !se_ok {
			continue
		}
		key := se.record.full_name != "" ? se.record.full_name : se.record.name
		if hugi.matches_name_filter(filter, key) {
			snap_latest_commit[strings.clone(key, context.temp_allocator)] = strings.clone(
				se.commit,
				context.temp_allocator,
			)
		}
		_snapshot_entry_destroy(&se, context.temp_allocator)
	}

	// Pool all runs matching each benchmark's latest commit from `run_order`.
	order_cur, o_err := xitdb.hash_map_get_cursor(moment, "run_order")
	if o_err == nil && order_cur != nil {
		if order_list, ol_err := xitdb.read_array_list_init(order_cur.?); ol_err == nil {
			oit, oit_err := xitdb.array_list_iterator(order_list)
			if oit_err == nil {
				for {
					c_maybe, n_err := xitdb.cursor_iterator_next(&oit)
					if n_err != nil || c_maybe == nil {
						break
					}
					rid, str_err := xitdb.cursor_read_string(c_maybe.?, 0, context.temp_allocator)
					if str_err != nil {
						continue
					}
					pkt, pkt_ok := _read_run_packet_from_map(runs_map, rid, context.temp_allocator)
					if !pkt_ok {
						continue
					}
					if pkt.lang == eff_lang {
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
					hugi.packet_destroy(&pkt, context.temp_allocator)
				}
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
