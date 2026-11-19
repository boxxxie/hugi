package hugi_store

import hugi "../hugi"
import "core:slice"
import "core:strings"

Store_Write_Options :: struct {
	keep_hot_runs:   int,
	cold_chunk_runs: int,
}

@(require_results)
default_store_write_options :: proc() -> Store_Write_Options {
	return Store_Write_Options{keep_hot_runs = 0, cold_chunk_runs = 32}
}

CZPK_V4_MAGIC :: "CZPK\x04\x00\x00\x00"
CZCH_V2_MAGIC :: "CZCH\x02\x00\x00\x00"

@(private)
_PKT_FLAG_SYMS :: u8(1 << 0)
@(private)
_PKT_FLAG_DESCS :: u8(1 << 1)
@(private)
_PKT_FLAG_SELECTIVE :: u8(1 << 2)
@(private)
_PKT_FLAG_ENV :: u8(1 << 3)
@(private)
_COLD_EXT_ENV :: u8(0xE1)
@(private)
_COLD_EXT_SAMPLES :: u8(0xE2)

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

// ── Shared Compression Helpers ──────────────────────────────────────────────

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
_write_stats_block :: proc(buf: ^[dynamic]u8, r: hugi.Record) {
	_fmt_append_zigzag_i64(buf, r.min_fs)
	_fmt_append_zigzag_i64(buf, r.p25_fs)
	_fmt_append_zigzag_i64(buf, r.p50_fs)
	_fmt_append_zigzag_i64(buf, r.p75_fs)
	_fmt_append_zigzag_i64(buf, r.p95_fs)
	_fmt_append_zigzag_i64(buf, r.p99_fs)
	_fmt_append_zigzag_i64(buf, r.max_fs)
	_fmt_append_zigzag_i64(buf, r.mean_fs)
	_fmt_append_zigzag_i64(buf, r.std_dev_fs)
	_fmt_append_zigzag_i64(buf, r.ci95_fs)
	_fmt_append_f64_le(buf, r.cv_pct)
	_fmt_append_zigzag_i64(buf, r.iqr_fs)
	_fmt_append_zigzag_i64(buf, r.mad_fs)
}

@(private, require_results)
_read_stats_block :: proc(rd: ^_Format_Reader, r: ^hugi.Record) -> bool {
	r.min_fs = _fmt_read_zigzag_i64(rd) or_return
	r.p25_fs = _fmt_read_zigzag_i64(rd) or_return
	r.p50_fs = _fmt_read_zigzag_i64(rd) or_return
	r.p75_fs = _fmt_read_zigzag_i64(rd) or_return
	r.p95_fs = _fmt_read_zigzag_i64(rd) or_return
	r.p99_fs = _fmt_read_zigzag_i64(rd) or_return
	r.max_fs = _fmt_read_zigzag_i64(rd) or_return
	r.mean_fs = _fmt_read_zigzag_i64(rd) or_return
	r.std_dev_fs = _fmt_read_zigzag_i64(rd) or_return
	r.ci95_fs = _fmt_read_zigzag_i64(rd) or_return
	r.cv_pct = _fmt_read_f64_le(rd) or_return
	r.iqr_fs = _fmt_read_zigzag_i64(rd) or_return
	r.mad_fs = _fmt_read_zigzag_i64(rd) or_return
	return true
}

@(private)
_finalize_record_stats_from_samples :: proc(r: ^hugi.Record, keep_existing_mbs: bool) {
	if len(r.samples_batch_ns) == 0 {
		return
	}
	if !keep_existing_mbs {
		r.mb_per_sec = 0
	}
	hugi.recompute_record_stats_from_samples(r)
	hugi.refresh_record_throughput(r, overwrite = true)
}

// ── CZPK\x04 Hot Packet Encoding / Decoding ──────────────────────────────────

@(private, require_results)
_encode_hot_packet :: proc(
	pkt: hugi.Run_Packet,
	syms: ^_Symbol_Table,
	descs: ^_Descriptor_Table,
	allocator := context.temp_allocator,
) -> (
	out: []u8,
	ok: bool,
) {
	meta_raw := make([dynamic]u8, 0, 1024, context.temp_allocator)
	defer delete(meta_raw)

	pkt_flags := _PKT_FLAG_SYMS | _PKT_FLAG_DESCS
	if pkt.selective {
		pkt_flags |= _PKT_FLAG_SELECTIVE
	}
	has_env := !hugi.run_env_is_empty(pkt.env)
	if has_env {
		pkt_flags |= _PKT_FLAG_ENV
	}

	_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.suite_name)))
	_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.lang)))
	_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.commit)))
	_fmt_append_str(&meta_raw, pkt.run_id)
	_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.os)))
	_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.arch)))
	_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.optimization)))
	_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.odin_version)))
	_fmt_append_zigzag_i64(&meta_raw, pkt.timestamp_unix)
	if has_env {
		_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.env.cpu_model)))
		_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.env.governor)))
		_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.env.build_flags)))
		_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, pkt.env.runtime_version)))
		_fmt_append_varint_u64(&meta_raw, pkt.env.scaling_max_khz)
		_fmt_append_varint_u64(&meta_raw, pkt.env.cpuinfo_max_khz)
		append(&meta_raw, u8(pkt.env.boost_state))
	}

	_fmt_append_varint_u64(&meta_raw, u64(len(pkt.records)))
	total_samples := 0
	for r in pkt.records {
		_fmt_append_varint_u64(&meta_raw, u64(len(r.samples_batch_ns)))
		total_samples += len(r.samples_batch_ns)
	}

	for r, ri in pkt.records {
		desc_id := _desc_intern(descs, syms, r)
		rflags := _rec_presence_flags(r, ri)
		_fmt_append_varint_u64(&meta_raw, u64(desc_id))
		_fmt_append_varint_u64(&meta_raw, u64(rflags))
		_fmt_append_varint_u64(&meta_raw, r.ops_per_sample)
		_fmt_append_varint_u64(&meta_raw, u64(r.samples))
		_fmt_append_varint_u64(&meta_raw, u64(r.warmup))

		if (rflags & _REC_FLAG_CUSTOM_RANK) != 0 {
			_fmt_append_zigzag_i64(&meta_raw, i64(r.rank))
		}
		if (rflags & _REC_FLAG_FOOTPRINT) != 0 {
			_fmt_append_varint_u64(&meta_raw, r.footprint_bytes)
		}
		if (rflags & _REC_FLAG_PEAK_HEAP) != 0 {
			_fmt_append_zigzag_i64(&meta_raw, r.peak_heap_bytes)
		}
		if (rflags & _REC_FLAG_ERROR) != 0 {
			_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, r.error)))
		}
		if (rflags & _REC_FLAG_METRICS) != 0 {
			_fmt_append_varint_u64(&meta_raw, u64(len(r.metrics)))
			for m in r.metrics {
				_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, m.unit)))
				_fmt_append_f64_le(&meta_raw, m.value)
			}
		}
		if (rflags & _REC_FLAG_HEAP_ALLOCS) != 0 {
			_fmt_append_f64_le(&meta_raw, r.allocs_per_op)
			_fmt_append_f64_le(&meta_raw, r.resizes_per_op)
			_fmt_append_f64_le(&meta_raw, r.alloc_bytes_per_op)
		}
		if (rflags & _REC_FLAG_TEMP_ALLOCS) != 0 {
			_fmt_append_f64_le(&meta_raw, r.temp_allocs_per_op)
			_fmt_append_f64_le(&meta_raw, r.temp_bytes_per_op)
		}
		if (rflags & _REC_FLAG_CYCLES) != 0 {
			_fmt_append_f64_le(&meta_raw, r.median_cycles)
		}
		if (rflags & _REC_FLAG_NO_SAMPLES) != 0 {
			_write_stats_block(&meta_raw, r)
			_fmt_append_f64_le(&meta_raw, r.mb_per_sec)
			_fmt_append_f64_le(&meta_raw, r.items_per_sec)
		} else if (rflags & _REC_FLAG_CUSTOM_MBS) != 0 {
			_fmt_append_f64_le(&meta_raw, r.mb_per_sec)
		}
	}

	meta_comp := compress_bytes_zlib(meta_raw[:], context.temp_allocator, 9) or_return
	defer delete(meta_comp, context.temp_allocator)

	all_batches := make([dynamic]u64, 0, total_samples, context.temp_allocator)
	defer delete(all_batches)
	for r in pkt.records {
		append(&all_batches, ..r.samples_batch_ns[:])
	}
	s_blob := compress_samples_u64(all_batches[:], context.temp_allocator) or_return
	defer delete(s_blob, context.temp_allocator)

	buf := make([dynamic]u8, 0, len(CZPK_V4_MAGIC) + 9 + len(meta_comp) + len(s_blob), allocator)
	append(&buf, ..transmute([]u8)string(CZPK_V4_MAGIC))
	append(&buf, pkt_flags)
	_fmt_append_u32_le(&buf, u32(len(meta_comp)))
	append(&buf, ..meta_comp)
	_fmt_append_u32_le(&buf, u32(len(s_blob)))
	append(&buf, ..s_blob)
	return buf[:], true
}

@(private, require_results)
_decode_hot_packet :: proc(
	blob: []u8,
	syms: _Symbol_Table,
	descs: _Descriptor_Table,
	allocator := context.allocator,
) -> (
	pkt: hugi.Run_Packet,
	ok: bool,
) {
	if len(blob) < len(CZPK_V4_MAGIC) + 1 {
		return {}, false
	}
	if string(blob[:len(CZPK_V4_MAGIC)]) != CZPK_V4_MAGIC {
		return {}, false
	}
	tmp: hugi.Run_Packet
	defer if !ok {
		hugi.packet_destroy(&tmp, allocator)
	}

	pos := len(CZPK_V4_MAGIC)
	pkt_flags := blob[pos]
	pos += 1
	required_flags := _PKT_FLAG_SYMS | _PKT_FLAG_DESCS
	if (pkt_flags & required_flags) != required_flags {
		return {}, false
	}
	selective := (pkt_flags & _PKT_FLAG_SELECTIVE) != 0

	outer_rd := _Format_Reader {
		data = blob,
		pos  = pos,
	}
	meta_len := int(_fmt_read_u32_le(&outer_rd) or_return)
	if meta_len < 0 || outer_rd.pos + meta_len > len(blob) {
		return {}, false
	}
	meta_raw := decompress_bytes_zlib(
		blob[outer_rd.pos:outer_rd.pos + meta_len],
		context.temp_allocator,
	) or_return
	defer delete(meta_raw, context.temp_allocator)
	outer_rd.pos += meta_len

	s_len := int(_fmt_read_u32_le(&outer_rd) or_return)
	if s_len < 0 || outer_rd.pos + s_len > len(blob) {
		return {}, false
	}
	all_u64 := decompress_samples_u64(
		blob[outer_rd.pos:outer_rd.pos + s_len],
		context.temp_allocator,
	) or_return
	defer delete(all_u64, context.temp_allocator)

	rd := _Format_Reader {
		data = meta_raw,
	}
	tmp.records = make([dynamic]hugi.Record, allocator)
	tmp.selective = selective

	tmp.suite_name = _read_sym_clone(&rd, syms, allocator) or_return
	tmp.lang = _read_sym_clone(&rd, syms, allocator) or_return
	tmp.commit = _read_sym_clone(&rd, syms, allocator) or_return
	tmp.run_id = _fmt_read_str(&rd, allocator) or_return
	tmp.os = _read_sym_clone(&rd, syms, allocator) or_return
	tmp.arch = _read_sym_clone(&rd, syms, allocator) or_return
	tmp.optimization = _read_sym_clone(&rd, syms, allocator) or_return
	tmp.odin_version = _read_sym_clone(&rd, syms, allocator) or_return
	tmp.timestamp_unix = _fmt_read_zigzag_i64(&rd) or_return
	if (pkt_flags & _PKT_FLAG_ENV) != 0 {
		tmp.env.cpu_model = _read_sym_clone(&rd, syms, allocator) or_return
		tmp.env.governor = _read_sym_clone(&rd, syms, allocator) or_return
		tmp.env.build_flags = _read_sym_clone(&rd, syms, allocator) or_return
		tmp.env.runtime_version = _read_sym_clone(&rd, syms, allocator) or_return
		tmp.env.scaling_max_khz = _fmt_read_varint_u64(&rd) or_return
		tmp.env.cpuinfo_max_khz = _fmt_read_varint_u64(&rd) or_return
		raw_boost := _fmt_read_u8(&rd) or_return
		tmp.env.boost_state = i8(raw_boost)
	}

	rec_count := _fmt_read_varint_nonneg_int(&rd) or_return
	if rec_count < 0 || rec_count > 100_000 {
		return {}, false
	}
	sample_counts := make([]int, rec_count, context.temp_allocator)
	defer delete(sample_counts, context.temp_allocator)
	expected_total := 0
	for i in 0 ..< rec_count {
		cnt := _fmt_read_varint_nonneg_int(&rd) or_return
		if cnt < 0 || cnt > 10_000_000 || expected_total > 100_000_000 - cnt {
			return {}, false
		}
		sample_counts[i] = cnt
		expected_total += cnt
	}
	if expected_total != len(all_u64) {
		return {}, false
	}

	reserve(&tmp.records, rec_count)
	s_off := 0
	for ri in 0 ..< rec_count {
		desc_id := _fmt_read_varint_u32(&rd) or_return
		rflags := _fmt_read_varint_u32(&rd) or_return
		ops := _fmt_read_varint_u64(&rd) or_return
		samples := _fmt_read_varint_nonneg_int(&rd) or_return
		warmup := _fmt_read_varint_nonneg_int(&rd) or_return

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
		append(&tmp.records, r)
		rp := &tmp.records[len(tmp.records) - 1]

		if (rflags & _REC_FLAG_CUSTOM_RANK) != 0 {
			rp.rank = int(_fmt_read_zigzag_i64(&rd) or_return)
		}
		if (rflags & _REC_FLAG_FOOTPRINT) != 0 {
			rp.footprint_bytes = _fmt_read_varint_u64(&rd) or_return
		}
		if (rflags & _REC_FLAG_PEAK_HEAP) != 0 {
			rp.peak_heap_bytes = _fmt_read_zigzag_i64(&rd) or_return
		}
		if (rflags & _REC_FLAG_ERROR) != 0 {
			rp.error = _read_sym_clone(&rd, syms, allocator) or_return
		} else {
			rp.error = strings.clone("", allocator)
		}
		if (rflags & _REC_FLAG_METRICS) != 0 {
			mc := _fmt_read_varint_nonneg_int(&rd) or_return
			if mc < 0 || mc > 1024 {
				return {}, false
			}
			reserve(&rp.metrics, mc)
			for _ in 0 ..< mc {
				u := _read_sym_clone(&rd, syms, allocator) or_return
				v, v_ok := _fmt_read_f64_le(&rd)
				if !v_ok {
					delete(u, allocator)
					return {}, false
				}
				append(&rp.metrics, hugi.Metric{unit = u, value = v})
			}
		}
		if (rflags & _REC_FLAG_HEAP_ALLOCS) != 0 {
			rp.allocs_per_op = _fmt_read_f64_le(&rd) or_return
			rp.resizes_per_op = _fmt_read_f64_le(&rd) or_return
			rp.alloc_bytes_per_op = _fmt_read_f64_le(&rd) or_return
		}
		if (rflags & _REC_FLAG_TEMP_ALLOCS) != 0 {
			rp.temp_allocs_per_op = _fmt_read_f64_le(&rd) or_return
			rp.temp_bytes_per_op = _fmt_read_f64_le(&rd) or_return
		}
		if (rflags & _REC_FLAG_CYCLES) != 0 {
			rp.median_cycles = _fmt_read_f64_le(&rd) or_return
		}
		keep_mbs := false
		if (rflags & _REC_FLAG_NO_SAMPLES) != 0 {
			_read_stats_block(&rd, rp) or_return
			rp.mb_per_sec = _fmt_read_f64_le(&rd) or_return
			rp.items_per_sec = _fmt_read_f64_le(&rd) or_return
		} else if (rflags & _REC_FLAG_CUSTOM_MBS) != 0 {
			rp.mb_per_sec = _fmt_read_f64_le(&rd) or_return
			keep_mbs = true
		}

		cnt := sample_counts[ri]
		if cnt > 0 {
			append(&rp.samples_batch_ns, ..all_u64[s_off:s_off + cnt])
			s_off += cnt
			_finalize_record_stats_from_samples(rp, keep_mbs)
		}
	}

	if rd.pos != len(rd.data) {
		return {}, false
	}
	return tmp, true
}

// ── Transposed Cold-History Columnar Rollup Chunk (CZCH\x02) ────────────────

@(private, require_results)
_encode_cold_chunk :: proc(
	pkts: []hugi.Run_Packet,
	syms: ^_Symbol_Table,
	descs: ^_Descriptor_Table,
	allocator := context.temp_allocator,
) -> (
	blob: []u8,
	ok: bool,
) {
	meta_raw := make([dynamic]u8, 0, max(len(pkts) * 256, 256), context.temp_allocator)
	defer delete(meta_raw)

	n_runs := len(pkts)
	_fmt_append_varint_u64(&meta_raw, u64(n_runs))

	// Run metadata in columnar layout for stronger Zlib cross-run matching.
	for p in pkts {
		_fmt_append_str(&meta_raw, p.run_id)
	}
	for p in pkts {
		_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.commit)))
	}
	for p in pkts {
		_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.lang)))
	}
	for p in pkts {
		_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.suite_name)))
	}
	for p in pkts {
		_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.os)))
	}
	for p in pkts {
		_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.arch)))
	}
	for p in pkts {
		_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.optimization)))
	}
	for p in pkts {
		_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.odin_version)))
	}
	prev_ts: i64 = 0
	for p in pkts {
		_fmt_append_zigzag_i64(&meta_raw, p.timestamp_unix - prev_ts)
		prev_ts = p.timestamp_unix
	}
	for p in pkts {
		append(&meta_raw, u8(1) if p.selective else u8(0))
	}
	total_recs := 0
	for p in pkts {
		_fmt_append_varint_u64(&meta_raw, u64(len(p.records)))
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

	flat_recs := make([dynamic]^hugi.Record, 0, total_recs, context.temp_allocator)
	defer delete(flat_recs)

	by_desc := make(map[u32][dynamic]int, context.temp_allocator)
	defer {
		for _, lst in by_desc {
			delete(lst)
		}
		delete(by_desc)
	}
	unique_descs := make([dynamic]u32, 0, 64, context.temp_allocator)
	defer delete(unique_descs)

	total_samples := 0
	for &p in pkts {
		for &r, ri in p.records {
			did := _desc_intern(descs, syms, r)
			append(&desc_ids, did)
			append(&rflags, _rec_presence_flags(r, ri))
			append(&ops_col, r.ops_per_sample)
			append(&scounts, len(r.samples_batch_ns))
			append(&warmups, r.warmup)
			total_samples += len(r.samples_batch_ns)

			flat_i := len(flat_recs)
			append(&flat_recs, &r)
			if did not_in by_desc {
				by_desc[did] = make([dynamic]int, context.temp_allocator)
				append(&unique_descs, did)
			}
			lst := &by_desc[did]
			append(lst, flat_i)
		}
	}

	prev_did: i64 = 0
	for did in desc_ids {
		_fmt_append_zigzag_i64(&meta_raw, i64(did) - prev_did)
		prev_did = i64(did)
	}
	for fl in rflags {
		_fmt_append_varint_u64(&meta_raw, u64(fl))
	}
	prev_ops: i64 = 0
	for ov in ops_col {
		_fmt_append_zigzag_i64(&meta_raw, i64(ov) - prev_ops)
		prev_ops = i64(ov)
	}
	prev_sc: i64 = 0
	for sc in scounts {
		_fmt_append_zigzag_i64(&meta_raw, i64(sc) - prev_sc)
		prev_sc = i64(sc)
	}
	prev_wu: i64 = 0
	for wu in warmups {
		_fmt_append_zigzag_i64(&meta_raw, i64(wu) - prev_wu)
		prev_wu = i64(wu)
	}

	// Sparse record columns grouped per field across all cold runs.
	for r, i in flat_recs {
		if (rflags[i] & _REC_FLAG_CUSTOM_RANK) != 0 {
			_fmt_append_zigzag_i64(&meta_raw, i64(r.rank))
		}
	}
	for r, i in flat_recs {
		if (rflags[i] & _REC_FLAG_FOOTPRINT) != 0 {
			_fmt_append_varint_u64(&meta_raw, r.footprint_bytes)
		}
	}
	for r, i in flat_recs {
		if (rflags[i] & _REC_FLAG_PEAK_HEAP) != 0 {
			_fmt_append_zigzag_i64(&meta_raw, r.peak_heap_bytes)
		}
	}
	for r, i in flat_recs {
		if (rflags[i] & _REC_FLAG_ERROR) != 0 {
			_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, r.error)))
		}
	}
	for r, i in flat_recs {
		if (rflags[i] & _REC_FLAG_METRICS) != 0 {
			_fmt_append_varint_u64(&meta_raw, u64(len(r.metrics)))
			for m in r.metrics {
				_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, m.unit)))
				_fmt_append_f64_le(&meta_raw, m.value)
			}
		}
	}
	for r, i in flat_recs {
		if (rflags[i] & _REC_FLAG_HEAP_ALLOCS) != 0 {
			_fmt_append_f64_le(&meta_raw, r.allocs_per_op)
			_fmt_append_f64_le(&meta_raw, r.resizes_per_op)
			_fmt_append_f64_le(&meta_raw, r.alloc_bytes_per_op)
		}
	}
	for r, i in flat_recs {
		if (rflags[i] & _REC_FLAG_TEMP_ALLOCS) != 0 {
			_fmt_append_f64_le(&meta_raw, r.temp_allocs_per_op)
			_fmt_append_f64_le(&meta_raw, r.temp_bytes_per_op)
		}
	}
	for r, i in flat_recs {
		if (rflags[i] & _REC_FLAG_CYCLES) != 0 {
			_fmt_append_f64_le(&meta_raw, r.median_cycles)
		}
	}
	for r, i in flat_recs {
		fl := rflags[i]
		if (fl & _REC_FLAG_NO_SAMPLES) != 0 {
			_write_stats_block(&meta_raw, r^)
			_fmt_append_f64_le(&meta_raw, r.mb_per_sec)
			_fmt_append_f64_le(&meta_raw, r.items_per_sec)
		} else if (fl & _REC_FLAG_CUSTOM_MBS) != 0 {
			_fmt_append_f64_le(&meta_raw, r.mb_per_sec)
		}
	}

	has_any_env := false
	for p in pkts {
		if !hugi.run_env_is_empty(p.env) {
			has_any_env = true
			break
		}
	}
	if has_any_env {
		append(&meta_raw, _COLD_EXT_ENV)
		for p in pkts {
			_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.env.cpu_model)))
		}
		for p in pkts {
			_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.env.governor)))
		}
		for p in pkts {
			_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.env.build_flags)))
		}
		for p in pkts {
			_fmt_append_varint_u64(&meta_raw, u64(_sym_intern(syms, p.env.runtime_version)))
		}
		prev_smax: i64 = 0
		for p in pkts {
			s_i := i64(p.env.scaling_max_khz)
			_fmt_append_zigzag_i64(&meta_raw, s_i - prev_smax)
			prev_smax = s_i
		}
		prev_cmax: i64 = 0
		for p in pkts {
			c_i := i64(p.env.cpuinfo_max_khz)
			_fmt_append_zigzag_i64(&meta_raw, c_i - prev_cmax)
			prev_cmax = c_i
		}
		for p in pkts {
			append(&meta_raw, u8(p.env.boost_state))
		}
	}

	sample_override_cnt := 0
	for r in flat_recs {
		if len(r.samples_batch_ns) == 0 && r.samples > 0 {
			sample_override_cnt += 1
		}
	}
	if sample_override_cnt > 0 {
		append(&meta_raw, _COLD_EXT_SAMPLES)
		_fmt_append_varint_u64(&meta_raw, u64(sample_override_cnt))
		for r, i in flat_recs {
			if len(r.samples_batch_ns) == 0 && r.samples > 0 {
				_fmt_append_varint_u64(&meta_raw, u64(i))
				_fmt_append_varint_u64(&meta_raw, u64(r.samples))
			}
		}
	}

	meta_comp := compress_bytes_zlib(meta_raw[:], context.temp_allocator, 9) or_return
	defer delete(meta_comp, context.temp_allocator)

	// Group samples by sorted `desc_id` across all cold runs so cross-commit samples
	// of each benchmark stay contiguous inside one single compressed stream.
	slice.sort(unique_descs[:])
	grouped_batches := make([dynamic]u64, 0, total_samples, context.temp_allocator)
	defer delete(grouped_batches)
	for did in unique_descs {
		for fi in by_desc[did] {
			append(&grouped_batches, ..flat_recs[fi].samples_batch_ns[:])
		}
	}
	s_blob := compress_samples_u64(grouped_batches[:], context.temp_allocator) or_return
	defer delete(s_blob, context.temp_allocator)

	out := make([dynamic]u8, 0, len(CZCH_V2_MAGIC) + 8 + len(meta_comp) + len(s_blob), allocator)
	append(&out, ..transmute([]u8)string(CZCH_V2_MAGIC))
	_fmt_append_u32_le(&out, u32(len(meta_comp)))
	append(&out, ..meta_comp)
	_fmt_append_u32_le(&out, u32(len(s_blob)))
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
	if len(blob) < len(CZCH_V2_MAGIC) {
		return nil, false
	}
	if string(blob[:len(CZCH_V2_MAGIC)]) != CZCH_V2_MAGIC {
		return nil, false
	}
	outer := _Format_Reader {
		data = blob,
		pos  = len(CZCH_V2_MAGIC),
	}
	meta_len := int(_fmt_read_u32_le(&outer) or_return)
	if meta_len < 0 || outer.pos + meta_len > len(blob) {
		return nil, false
	}
	meta_raw := decompress_bytes_zlib(
		blob[outer.pos:outer.pos + meta_len],
		context.temp_allocator,
	) or_return
	defer delete(meta_raw, context.temp_allocator)
	outer.pos += meta_len

	s_len := int(_fmt_read_u32_le(&outer) or_return)
	if s_len < 0 || outer.pos + s_len > len(blob) {
		return nil, false
	}
	all_u64 := decompress_samples_u64(
		blob[outer.pos:outer.pos + s_len],
		context.temp_allocator,
	) or_return
	defer delete(all_u64, context.temp_allocator)

	rd := _Format_Reader {
		data = meta_raw,
	}
	n_runs := _fmt_read_varint_nonneg_int(&rd) or_return
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

	for i in 0 ..< n_runs {
		out[i].run_id = _fmt_read_str(&rd, allocator) or_return
	}
	for i in 0 ..< n_runs {
		out[i].commit = _read_sym_clone(&rd, syms, allocator) or_return
	}
	for i in 0 ..< n_runs {
		out[i].lang = _read_sym_clone(&rd, syms, allocator) or_return
	}
	for i in 0 ..< n_runs {
		out[i].suite_name = _read_sym_clone(&rd, syms, allocator) or_return
	}
	for i in 0 ..< n_runs {
		out[i].os = _read_sym_clone(&rd, syms, allocator) or_return
	}
	for i in 0 ..< n_runs {
		out[i].arch = _read_sym_clone(&rd, syms, allocator) or_return
	}
	for i in 0 ..< n_runs {
		out[i].optimization = _read_sym_clone(&rd, syms, allocator) or_return
	}
	for i in 0 ..< n_runs {
		out[i].odin_version = _read_sym_clone(&rd, syms, allocator) or_return
	}
	prev_ts: i64 = 0
	for i in 0 ..< n_runs {
		ts_delta := _fmt_read_zigzag_i64(&rd) or_return
		prev_ts += ts_delta
		out[i].timestamp_unix = prev_ts
	}
	for i in 0 ..< n_runs {
		out[i].selective = (_fmt_read_u8(&rd) or_return) != 0
	}

	total_recs := 0
	rec_counts := make([]int, n_runs, context.temp_allocator)
	defer delete(rec_counts, context.temp_allocator)
	for i in 0 ..< n_runs {
		rc := _fmt_read_varint_nonneg_int(&rd) or_return
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
		d := _fmt_read_zigzag_i64(&rd) or_return
		prev_did += d
		if prev_did < 0 || prev_did > i64(max(u32)) {
			return nil, false
		}
		desc_ids[i] = u32(prev_did)
	}
	for i in 0 ..< total_recs {
		rflags[i] = _fmt_read_varint_u32(&rd) or_return
	}
	prev_ops: i64 = 0
	for i in 0 ..< total_recs {
		d := _fmt_read_zigzag_i64(&rd) or_return
		prev_ops += d
		ops_col[i] = u64(prev_ops)
	}
	expected_samples := 0
	prev_sc: i64 = 0
	for i in 0 ..< total_recs {
		d := _fmt_read_zigzag_i64(&rd) or_return
		prev_sc += d
		if prev_sc < 0 || prev_sc > 10_000_000 || expected_samples > 100_000_000 - int(prev_sc) {
			return nil, false
		}
		scounts[i] = int(prev_sc)
		expected_samples += int(prev_sc)
	}
	actual_samples := len(all_u64)
	if expected_samples != actual_samples {
		return nil, false
	}
	prev_wu: i64 = 0
	for i in 0 ..< total_recs {
		d := _fmt_read_zigzag_i64(&rd) or_return
		prev_wu += d
		warmups[i] = int(prev_wu)
	}

	by_desc := make(map[u32][dynamic]int, context.temp_allocator)
	defer {
		for _, lst in by_desc {
			delete(lst)
		}
		delete(by_desc)
	}
	unique_descs := make([dynamic]u32, 0, 64, context.temp_allocator)
	defer delete(unique_descs)

	flat_recs := make([]^hugi.Record, total_recs, context.temp_allocator)
	defer delete(flat_recs, context.temp_allocator)

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
				by_desc[did] = make([dynamic]int, context.temp_allocator)
				append(&unique_descs, did)
			}
			lst := &by_desc[did]
			append(lst, flat_idx)
			flat_idx += 1
		}
	}

	flat_idx = 0
	for pi in 0 ..< n_runs {
		for ri in 0 ..< rec_counts[pi] {
			flat_recs[flat_idx] = &out[pi].records[ri]
			flat_idx += 1
		}
	}

	// Read sparse record columns in field order.
	for rp, i in flat_recs {
		if (rflags[i] & _REC_FLAG_CUSTOM_RANK) != 0 {
			rp.rank = int(_fmt_read_zigzag_i64(&rd) or_return)
		}
	}
	for rp, i in flat_recs {
		if (rflags[i] & _REC_FLAG_FOOTPRINT) != 0 {
			rp.footprint_bytes = _fmt_read_varint_u64(&rd) or_return
		}
	}
	for rp, i in flat_recs {
		if (rflags[i] & _REC_FLAG_PEAK_HEAP) != 0 {
			rp.peak_heap_bytes = _fmt_read_zigzag_i64(&rd) or_return
		}
	}
	for rp, i in flat_recs {
		if (rflags[i] & _REC_FLAG_ERROR) != 0 {
			err_s := _read_sym_clone(&rd, syms, allocator) or_return
			delete(rp.error, allocator)
			rp.error = err_s
		}
	}
	for rp, i in flat_recs {
		if (rflags[i] & _REC_FLAG_METRICS) != 0 {
			mc := _fmt_read_varint_nonneg_int(&rd) or_return
			if mc < 0 || mc > 1024 {
				return nil, false
			}
			reserve(&rp.metrics, mc)
			for _ in 0 ..< mc {
				u := _read_sym_clone(&rd, syms, allocator) or_return
				v, v_ok := _fmt_read_f64_le(&rd)
				if !v_ok {
					delete(u, allocator)
					return nil, false
				}
				append(&rp.metrics, hugi.Metric{unit = u, value = v})
			}
		}
	}
	for rp, i in flat_recs {
		if (rflags[i] & _REC_FLAG_HEAP_ALLOCS) != 0 {
			rp.allocs_per_op = _fmt_read_f64_le(&rd) or_return
			rp.resizes_per_op = _fmt_read_f64_le(&rd) or_return
			rp.alloc_bytes_per_op = _fmt_read_f64_le(&rd) or_return
		}
	}
	for rp, i in flat_recs {
		if (rflags[i] & _REC_FLAG_TEMP_ALLOCS) != 0 {
			rp.temp_allocs_per_op = _fmt_read_f64_le(&rd) or_return
			rp.temp_bytes_per_op = _fmt_read_f64_le(&rd) or_return
		}
	}
	for rp, i in flat_recs {
		if (rflags[i] & _REC_FLAG_CYCLES) != 0 {
			rp.median_cycles = _fmt_read_f64_le(&rd) or_return
		}
	}

	keep_mbs_flags := make([]bool, total_recs, context.temp_allocator)
	defer delete(keep_mbs_flags, context.temp_allocator)
	for rp, i in flat_recs {
		fl := rflags[i]
		if (fl & _REC_FLAG_NO_SAMPLES) != 0 {
			_read_stats_block(&rd, rp) or_return
			rp.mb_per_sec = _fmt_read_f64_le(&rd) or_return
			rp.items_per_sec = _fmt_read_f64_le(&rd) or_return
		} else if (fl & _REC_FLAG_CUSTOM_MBS) != 0 {
			rp.mb_per_sec = _fmt_read_f64_le(&rd) or_return
			keep_mbs_flags[i] = true
		}
	}

	seen_env := false
	seen_samples := false
	for rd.pos < len(rd.data) {
		ext_tag := _fmt_read_u8(&rd) or_return
		switch ext_tag {
		case _COLD_EXT_ENV:
			if seen_env {
				return nil, false
			}
			seen_env = true
			for i in 0 ..< n_runs {
				out[i].env.cpu_model = _read_sym_clone(&rd, syms, allocator) or_return
			}
			for i in 0 ..< n_runs {
				out[i].env.governor = _read_sym_clone(&rd, syms, allocator) or_return
			}
			for i in 0 ..< n_runs {
				out[i].env.build_flags = _read_sym_clone(&rd, syms, allocator) or_return
			}
			for i in 0 ..< n_runs {
				out[i].env.runtime_version = _read_sym_clone(&rd, syms, allocator) or_return
			}
			prev_smax: i64 = 0
			for i in 0 ..< n_runs {
				d := _fmt_read_zigzag_i64(&rd) or_return
				prev_smax += d
				if prev_smax < 0 {
					return nil, false
				}
				out[i].env.scaling_max_khz = u64(prev_smax)
			}
			prev_cmax: i64 = 0
			for i in 0 ..< n_runs {
				d := _fmt_read_zigzag_i64(&rd) or_return
				prev_cmax += d
				if prev_cmax < 0 {
					return nil, false
				}
				out[i].env.cpuinfo_max_khz = u64(prev_cmax)
			}
			for i in 0 ..< n_runs {
				raw_b := _fmt_read_u8(&rd) or_return
				out[i].env.boost_state = i8(raw_b)
			}
		case _COLD_EXT_SAMPLES:
			if seen_samples {
				return nil, false
			}
			seen_samples = true
			ov_cnt := _fmt_read_varint_nonneg_int(&rd) or_return
			if ov_cnt > total_recs {
				return nil, false
			}
			for _ in 0 ..< ov_cnt {
				fi := _fmt_read_varint_nonneg_int(&rd) or_return
				if fi >= total_recs {
					return nil, false
				}
				sv := _fmt_read_varint_nonneg_int(&rd) or_return
				flat_recs[fi].samples = sv
			}
		case:
			return nil, false
		}
	}

	// Scatter grouped samples back into their original `(pkt_i, rec_i)` order.
	slice.sort(unique_descs[:])
	s_off := 0
	for did in unique_descs {
		for fi in by_desc[did] {
			cnt := scounts[fi]
			rp := flat_recs[fi]
			if cnt > 0 {
				append(&rp.samples_batch_ns, ..all_u64[s_off:s_off + cnt])
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
