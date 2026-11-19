package hugi_store

import hugi "../hugi"
import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"

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
_match_commit_prefix :: proc(candidate, query: string) -> bool {
	if query == "" {
		return true
	}
	return strings.has_prefix(candidate, query) || strings.has_prefix(query, candidate)
}

@(private, require_results)
_open_latest_moment_reader :: proc(
	st: ^Store,
	allocator := context.allocator,
) -> (
	mr: _Moment_Reader,
	ok: bool,
) {
	moment := _latest_moment_map(st) or_return
	return _moment_reader_init(moment, allocator)
}

@(private)
_is_wildcard_lang :: proc "contextless" (lang: string) -> bool {
	return lang == "*" || lang == "all"
}

@(private, require_results)
_moment_reader_get_catalog_run :: proc(
	mr: ^_Moment_Reader,
	e: _Catalog_Run_Entry,
	lang_filter := "",
) -> (
	pkt: hugi.Run_Packet,
	pkt_lang: string,
	ok: bool,
) {
	any_lang := lang_filter == "" || _is_wildcard_lang(lang_filter)
	if !any_lang && e.lang != lang_filter {
		return {}, "", false
	}
	rk := _run_key(e.lang, e.run_id)
	pkt = _moment_reader_get_packet(mr, rk) or_return
	if !any_lang && pkt.lang != lang_filter {
		return {}, "", false
	}
	pkt_lang = pkt.lang != "" ? pkt.lang : "odin"
	return pkt, pkt_lang, true
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
	defer delete(idx_by_commit)
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
	if mr, mr_ok := _open_latest_moment_reader(st, allocator); mr_ok {
		defer _moment_reader_destroy(&mr)
		for e in mr.cat.runs {
			rk := _run_key(e.lang, e.run_id)
			if pkt, pkt_ok := _moment_reader_take_packet(&mr, rk); pkt_ok {
				append(&pkts, pkt)
			}
		}
	}
	return pkts[:]
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
	key_by_lang := false,
) {
	key := r.full_name != "" ? r.full_name : r.name
	if !hugi.matches_name_filter(filter, key) {
		return
	}
	eff_lang := pkt_lang != "" ? pkt_lang : "odin"
	map_key := key_by_lang ? fmt.tprintf("%s\x00%s", eff_lang, key) : key
	g_idx, seen := by_name[map_key]
	if !seen {
		g_idx = len(groups^)
		by_name[map_key] = g_idx
		append(
			groups,
			_Raw_Group {
				full_name = strings.clone(key, allocator),
				commit = strings.clone(pkt_commit, allocator),
				lang = strings.clone(eff_lang, allocator),
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
	defer delete(by_name)

	mr, mr_ok := _open_latest_moment_reader(st, context.allocator)
	if !mr_ok {
		return groups[:]
	}
	defer _moment_reader_destroy(&mr)

	if run_id != "" {
		any_lang := lang == "" || _is_wildcard_lang(lang)
		prefixed_key := any_lang ? run_id : _run_key(lang, run_id)
		pkt, pkt_ok := _moment_reader_get_packet(&mr, prefixed_key)
		if !pkt_ok && !any_lang {
			pkt, pkt_ok = _moment_reader_get_packet(&mr, run_id)
		}
		if !pkt_ok && any_lang {
			for e in mr.cat.runs {
				if e.run_id == run_id {
					pkt, pkt_ok = _moment_reader_get_packet(&mr, _run_key(e.lang, e.run_id))
					if pkt_ok {
						break
					}
				}
			}
		}
		if !pkt_ok || (!any_lang && pkt.lang != lang) {
			return groups[:]
		}
		pkt_lang := pkt.lang != "" ? pkt.lang : "odin"
		for r in pkt.records {
			_raw_groups_add_record(
				&groups,
				&by_name,
				pkt.commit,
				pkt.run_id,
				pkt_lang,
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
		for e in mr.cat.runs {
			if !_match_commit_prefix(e.commit, commit) {
				continue
			}
			pkt, pkt_lang, pkt_ok := _moment_reader_get_catalog_run(&mr, e, lang)
			if !pkt_ok {
				continue
			}
			for r in pkt.records {
				_raw_groups_add_record(
					&groups,
					&by_name,
					pkt.commit,
					pkt.run_id,
					pkt_lang,
					pkt.suite_name,
					pkt.timestamp_unix,
					r,
					filter,
					allocator,
					key_by_lang = (lang == "" || _is_wildcard_lang(lang)),
				)
			}
		}
		slice.sort_by(groups[:], proc(a, b: _Raw_Group) -> bool {
			if a.records[0].rank != b.records[0].rank {
				return a.records[0].rank < b.records[0].rank
			}
			return a.lang < b.lang
		})
		return groups[:]
	}

	if _is_wildcard_lang(lang) {
		snap_latest_commit := make(map[string]string, context.temp_allocator)
		active_commits := make(map[string]bool, context.temp_allocator)
		defer {
			delete(snap_latest_commit)
			delete(active_commits)
		}
		for snap_lang, snap_m in mr.cat.snaps {
			for key, ref in snap_m {
				if !hugi.matches_name_filter(filter, key) {
					continue
				}
				run_ord := int(ref.run_ord)
				if run_ord >= 0 && run_ord < len(mr.cat.runs) {
					sc := mr.cat.runs[run_ord].commit
					if sc != "" {
						sk := fmt.tprintf("%s\x00%s", snap_lang, key)
						snap_latest_commit[sk] = sc
						active_commits[sc] = true
					}
				}
			}
		}

		for e in mr.cat.runs {
			if e.commit not_in active_commits {
				continue
			}
			pkt, pkt_lang, pkt_ok := _moment_reader_get_catalog_run(&mr, e, "")
			if !pkt_ok {
				continue
			}
			for r in pkt.records {
				key := r.full_name != "" ? r.full_name : r.name
				sk := fmt.tprintf("%s\x00%s", pkt_lang, key)
				if target_commit, found := snap_latest_commit[sk];
				   found && pkt.commit == target_commit {
					_raw_groups_add_record(
						&groups,
						&by_name,
						pkt.commit,
						pkt.run_id,
						pkt_lang,
						pkt.suite_name,
						pkt.timestamp_unix,
						r,
						filter,
						allocator,
						key_by_lang = true,
					)
				}
			}
		}

		slice.sort_by(groups[:], proc(a, b: _Raw_Group) -> bool {
			if a.lang != b.lang {
				return a.lang < b.lang
			}
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
	defer {
		delete(snap_latest_commit)
		delete(active_commits)
	}
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
		pkt, pkt_lang, pkt_ok := _moment_reader_get_catalog_run(&mr, e, eff_lang)
		if !pkt_ok {
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
					pkt_lang,
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
_store_load_commit_series_raw_groups :: proc(
	st: ^Store,
	lang: string,
	filter := "",
	allocator := context.allocator,
) -> []_Raw_Group {
	out := make([dynamic]_Raw_Group, allocator)
	mr, mr_ok := _open_latest_moment_reader(st, context.allocator)
	if !mr_ok {
		return out[:]
	}
	defer _moment_reader_destroy(&mr)

	_Commit_Bucket :: struct {
		groups:  [dynamic]_Raw_Group,
		by_name: map[string]int,
	}
	bucket_order := make([dynamic]string, context.temp_allocator)
	buckets := make(map[string]_Commit_Bucket, context.temp_allocator)
	defer {
		for _, &b in buckets {
			delete(b.groups)
			delete(b.by_name)
		}
		for bk in bucket_order {
			delete(bk, context.temp_allocator)
		}
		delete(buckets)
		delete(bucket_order)
	}

	for e in mr.cat.runs {
		pkt, pkt_lang, p_ok := _moment_reader_get_catalog_run(&mr, e, lang)
		if !p_ok {
			continue
		}
		ckey := pkt.commit != "" ? pkt.commit : "unknown"
		bkey := fmt.tprintf("%s\x00%s", ckey, pkt_lang)
		if bkey not_in buckets {
			b_clone := strings.clone(bkey, context.temp_allocator)
			append(&bucket_order, b_clone)
			buckets[b_clone] = _Commit_Bucket {
				groups  = make([dynamic]_Raw_Group, context.temp_allocator),
				by_name = make(map[string]int, context.temp_allocator),
			}
		}
		bp := &buckets[bkey]
		for r in pkt.records {
			_raw_groups_add_record(
				&bp.groups,
				&bp.by_name,
				pkt.commit,
				pkt.run_id,
				pkt_lang,
				pkt.suite_name,
				pkt.timestamp_unix,
				r,
				filter,
				allocator,
			)
		}
	}

	for bkey in bucket_order {
		bp := &buckets[bkey]
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
	mr, mr_ok := _open_latest_moment_reader(st, context.allocator)
	if !mr_ok {
		return out[:]
	}
	defer _moment_reader_destroy(&mr)

	for e in mr.cat.runs {
		pkt, pkt_lang, p_ok := _moment_reader_get_catalog_run(&mr, e, lang)
		if !p_ok {
			continue
		}
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
					lang = strings.clone(pkt_lang, allocator),
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
