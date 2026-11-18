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

	total_samples := 0
	for r in pkt.records {
		total_samples += len(r.samples_ns)
	}
	all_samples := make([dynamic]f64, 0, total_samples, context.temp_allocator)
	defer delete(all_samples)
	for r in pkt.records {
		append(&all_samples, ..r.samples_ns[:])
	}
	s_blob := compress_samples_f64(all_samples[:], .Zlib_BSS, context.temp_allocator) or_return
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
		_append_u32_le(&buf, u32(len(r.samples_ns)))
	}
	_append_u32_le(&buf, u32(len(s_blob)))
	append(&buf, ..s_blob)
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
	if len(blob) < len(CZPK_V2_MAGIC) {
		return {}, false
	}
	magic := string(blob[:len(CZPK_V2_MAGIC)])
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
			clear(&pkt.records[i].samples_ns)
			append(&pkt.records[i].samples_ns, ..samples)
			delete(samples, context.temp_allocator)
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
		clear(&pkt.records[i].samples_ns)
		if cnt > 0 {
			append(&pkt.records[i].samples_ns, ..all_samples[off:off + cnt])
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
_Ingest_Ctx :: struct {
	pkt:     hugi.Run_Packet,
	pk_blob: []u8,
}

@(private = "file")
_Ingest_Batch_Ctx :: struct {
	items: []_Ingest_Ctx,
}

@(private = "file")
_array_list_index_of_str :: proc(list: xitdb.Read_Array_List, target: string) -> int {
	it, it_err := xitdb.array_list_iterator(list)
	if it_err != nil {
		return -1
	}
	idx := 0
	for {
		cur_maybe, n_err := xitdb.cursor_iterator_next(&it)
		if n_err != nil || cur_maybe == nil {
			break
		}
		s, s_err := xitdb.cursor_read_string(cur_maybe.?, 0, context.temp_allocator)
		if s_err == nil && s == target {
			return idx
		}
		idx += 1
	}
	return -1
}

@(private = "file")
_array_list_contains_str :: proc(list: xitdb.Read_Array_List, target: string) -> bool {
	return _array_list_index_of_str(list, target) >= 0
}

@(private = "file")
_put_packet_into_moment :: proc(
	moment: ^xitdb.Write_Hash_Map,
	pkt: hugi.Run_Packet,
	pk_blob: []u8,
) -> xitdb.Error {
	lang_key := pkt.lang != "" ? pkt.lang : "odin"
	run_key := fmt.tprintf("%s:%s", lang_key, pkt.run_id)

	// 1. Store compressed Run_Packet under "runs"[<lang>:<run_id>].
	runs_cur := xitdb.hash_map_put_cursor(moment, "runs") or_return
	runs_map := xitdb.write_hash_map_init(runs_cur) or_return
	existed_slot, _ := xitdb.hash_map_get_slot(runs_map.read_hash_map, run_key)
	already_in_runs := existed_slot != nil
	xitdb.hash_map_put(&runs_map, run_key, pk_blob) or_return

	// 2. Append composite run_key to "run_order" (or look up existing ordinal).
	order_cur := xitdb.hash_map_put_cursor(moment, "run_order") or_return
	order_list := xitdb.write_array_list_init(order_cur) or_return
	run_ord := -1
	if already_in_runs {
		run_ord = _array_list_index_of_str(order_list.read_array_list, run_key)
	}
	if run_ord < 0 {
		ord_cnt := xitdb.array_list_count(order_list.read_array_list) or_return
		run_ord = int(ord_cnt)
		xitdb.array_list_append(&order_list, run_key) or_return
	}

	// 3. Index composite run_key under "commits"[commit].
	commits_cur := xitdb.hash_map_put_cursor(moment, "commits") or_return
	commits_map := xitdb.write_hash_map_init(commits_cur) or_return
	commit_key := pkt.commit != "" ? pkt.commit : "unknown"
	c_list_cur := xitdb.hash_map_put_cursor(&commits_map, commit_key) or_return
	c_list := xitdb.write_array_list_init(c_list_cur) or_return
	if !_array_list_contains_str(c_list.read_array_list, run_key) {
		xitdb.array_list_append(&c_list, run_key) or_return
	}

	// 4. Update inline (run_ord << 32) | rec_idx pointers under "snapshots"[lang][full_name].
	snaps_cur := xitdb.hash_map_put_cursor(moment, "snapshots") or_return
	snaps_map := xitdb.write_hash_map_init(snaps_cur) or_return
	lang_cur := xitdb.hash_map_put_cursor(&snaps_map, lang_key) or_return
	lang_sorted := xitdb.write_sorted_map_init(lang_cur) or_return
	for r, rec_idx in pkt.records {
		key := r.full_name != "" ? r.full_name : r.name
		xitdb.sorted_map_put(&lang_sorted, key, _pack_snapshot_ref(run_ord, rec_idx)) or_return
	}
	return nil
}

@(private = "file")
_ingest_cb :: proc(cursor: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	ctx := (^_Ingest_Ctx)(user_data)
	moment := xitdb.write_hash_map_init(cursor^) or_return
	xitdb.hash_map_put(&moment, "schema_version", u64(2)) or_return
	return _put_packet_into_moment(&moment, ctx.pkt, ctx.pk_blob)
}

@(private = "file")
_ingest_batch_cb :: proc(cursor: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	ctx := (^_Ingest_Batch_Ctx)(user_data)
	moment := xitdb.write_hash_map_init(cursor^) or_return
	xitdb.hash_map_put(&moment, "schema_version", u64(2)) or_return
	for item in ctx.items {
		_put_packet_into_moment(&moment, item.pkt, item.pk_blob) or_return
	}
	return nil
}

@(private = "file", require_results)
_store_ingest_batch_single_moment :: proc(st: ^Store, pkts: []hugi.Run_Packet) -> bool {
	if st == nil {
		return false
	}
	items := make([]_Ingest_Ctx, len(pkts), context.temp_allocator)
	defer {
		for item in items {
			delete(item.pk_blob, context.temp_allocator)
		}
		delete(items, context.temp_allocator)
	}
	for pkt, i in pkts {
		pk_blob, pk_ok := _encode_compressed_packet(pkt, context.temp_allocator)
		if !pk_ok {
			return false
		}
		items[i] = _Ingest_Ctx {
			pkt     = pkt,
			pk_blob = pk_blob,
		}
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
		items = items,
	}
	return(
		xitdb.array_list_append_context(&history, base_slot, _ingest_batch_cb, &batch_ctx) ==
		nil \
	)
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
_get_cached_packet :: proc(
	cache: ^map[string]hugi.Run_Packet,
	runs_map: xitdb.Read_Hash_Map,
	rid: string,
) -> (
	pkt: hugi.Run_Packet,
	ok: bool,
) {
	if cached, exists := cache[rid]; exists {
		return cached, true
	}
	decoded, p_ok := _read_run_packet_from_map(runs_map, rid, context.temp_allocator)
	if !p_ok {
		return {}, false
	}
	cache[strings.clone(rid, context.temp_allocator)] = decoded
	return decoded, true
}

/*
Compacts the `xitdb` store at `db_path` by collapsing all historical runs into a single
clean v2 Moment (`CZPK\x02` packets + inline `u64` snapshot pointers) via `xitdb.database_compact`
and atomically replacing `db_path`.
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

	pkts := make([dynamic]hugi.Run_Packet, context.allocator)
	defer {
		for &p in pkts {
			hugi.packet_destroy(&p)
		}
		delete(pkts)
	}

	{
		src_st, open_ok := store_open(db_path, context.allocator)
		if !open_ok {
			return before_bytes, 0, false
		}
		defer store_close(&src_st)

		if moment, has_m := _latest_moment_map(&src_st); has_m {
			runs_cur, r_err := xitdb.hash_map_get_cursor(moment, "runs")
			order_cur, o_err := xitdb.hash_map_get_cursor(moment, "run_order")
			if r_err == nil && runs_cur != nil && o_err == nil && order_cur != nil {
				if runs_map, rm_err := xitdb.read_hash_map_init(runs_cur.?); rm_err == nil {
					run_keys := _read_string_list(order_cur.?, context.temp_allocator)
					defer delete(run_keys)
					for rid in run_keys {
						if pkt, pkt_ok := _read_run_packet_from_map(
							runs_map,
							rid,
							context.allocator,
						); pkt_ok {
							append(&pkts, pkt)
						}
					}
				}
			}
		}
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

		if !_store_ingest_batch_single_moment(&mem_st, pkts[:]) {
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

	pkt_cache := make(map[string]hugi.Run_Packet, context.temp_allocator)
	defer {
		for _, &p in pkt_cache {
			hugi.packet_destroy(&p, context.temp_allocator)
		}
	}

	if run_id != "" {
		prefixed_key := fmt.tprintf("%s:%s", lang != "" ? lang : "odin", run_id)
		pkt, pkt_ok := _get_cached_packet(&pkt_cache, runs_map, prefixed_key)
		if !pkt_ok {
			pkt, pkt_ok = _get_cached_packet(&pkt_cache, runs_map, run_id)
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

	if commit != "" {
		candidate_rids: [dynamic]string
		used_commits_index := false
		if c_cur, cm_err := xitdb.hash_map_get_cursor(moment, "commits");
		   cm_err == nil && c_cur != nil {
			if c_map, map_err := xitdb.read_hash_map_init(c_cur.?); map_err == nil {
				if list_cur, l_err := xitdb.hash_map_get_cursor(c_map, commit);
				   l_err == nil && list_cur != nil {
					candidate_rids = _read_string_list(list_cur.?, context.temp_allocator)
					used_commits_index = true
				}
			}
		}
		if !used_commits_index {
			order_cur, o_err := xitdb.hash_map_get_cursor(moment, "run_order")
			if o_err != nil || order_cur == nil {
				return groups[:]
			}
			candidate_rids = _read_string_list(order_cur.?, context.temp_allocator)
		}
		for rid in candidate_rids {
			pkt, pkt_ok := _get_cached_packet(&pkt_cache, runs_map, rid)
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
	lang_sorted, ls_err := xitdb.read_sorted_map_init(lang_cur.?)
	if ls_err != nil {
		return groups[:]
	}

	order_cur, o_err := xitdb.hash_map_get_cursor(moment, "run_order")
	if o_err != nil || order_cur == nil {
		return groups[:]
	}
	run_keys := _read_string_list(order_cur.?, context.temp_allocator)

	snap_latest_commit := make(map[string]string, context.temp_allocator)
	active_commits := make(map[string]bool, context.temp_allocator)
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
					if pkt, p_ok := _get_cached_packet(&pkt_cache, runs_map, run_keys[run_ord]);
					   p_ok {
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

	needed_rids := make(map[string]bool, context.temp_allocator)
	fallback_all := false
	if c_cur, cm_err := xitdb.hash_map_get_cursor(moment, "commits");
	   cm_err == nil && c_cur != nil {
		if c_map, map_err := xitdb.read_hash_map_init(c_cur.?); map_err == nil {
			for ac in active_commits {
				if list_cur, lc_err := xitdb.hash_map_get_cursor(c_map, ac);
				   lc_err == nil && list_cur != nil {
					for crid in _read_string_list(list_cur.?, context.temp_allocator) {
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
		pkt, pkt_ok := _get_cached_packet(&pkt_cache, runs_map, rid)
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
