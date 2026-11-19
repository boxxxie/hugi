package hugi

import obench "../deps/obench/obench"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"

PACKET_MAGIC :: "HPKT\x02\x00\x00\x00"
RECORD_MAGIC :: "OBRC\x02\x00\x00\x00"
MAX_METRICS :: 8

FS_PER_NS :: i64(1_000_000)
FS_PER_SEC_F64 :: 1_000_000_000_000_000.0

batch_ns_to_op_fs :: #force_inline proc "contextless" (batch_ns: u64, ops_per_sample: u64) -> i64 {
	ops := max(ops_per_sample, 1)
	v := (u128(batch_ns) * 1_000_000 + u128(ops / 2)) / u128(ops)
	return v > u128(max(i64)) ? max(i64) : i64(v)
}

ns_f64_to_fs :: #force_inline proc "contextless" (ns: f64) -> i64 {
	if !(ns > 0.0) {
		return 0
	}
	scaled := ns * 1_000_000.0
	if scaled >= f64(max(i64)) {
		return max(i64)
	}
	return i64(math.round(scaled))
}

fs_to_ns_f64 :: #force_inline proc "contextless" (fs: i64) -> f64 {
	return f64(fs) * 1e-6
}

ns_f64_to_batch_ns :: #force_inline proc "contextless" (ns: f64, ops_per_sample: u64) -> u64 {
	if !(ns > 0.0) {
		return 0
	}
	prod := ns * f64(max(ops_per_sample, 1))
	if prod >= f64(max(u64)) {
		return max(u64)
	}
	return u64(math.round(prod))
}

percentile_sorted_fs :: proc "contextless" (sorted: []i64, pct_num: int) -> i64 {
	n := len(sorted)
	if n == 0 {
		return 0
	}
	if n == 1 || pct_num <= 0 {
		return sorted[0]
	}
	if pct_num >= 100 {
		return sorted[n - 1]
	}
	num := i128(pct_num) * i128(n - 1)
	lo := int(num / 100)
	rem := num % 100
	if lo >= n - 1 || rem == 0 {
		return sorted[min(lo, n - 1)]
	}
	lo_val := i128(sorted[lo])
	hi_val := i128(sorted[lo + 1])
	interp := lo_val * 100 + (hi_val - lo_val) * rem
	if interp >= 0 {
		return i64((interp + 50) / 100)
	}
	return i64((interp - 50) / 100)
}

write_decimal_ns_fs :: proc(sb: ^strings.Builder, fs: i64) {
	if fs < 0 {
		strings.write_byte(sb, '-')
		mag := u64(-fs) if fs != min(i64) else (u64(max(i64)) + 1)
		fmt.sbprintf(sb, "%d.%06d", mag / 1_000_000, mag % 1_000_000)
		return
	}
	mag := u64(fs)
	fmt.sbprintf(sb, "%d.%06d", mag / 1_000_000, mag % 1_000_000)
}

@(require_results)
format_duration_fs :: proc(fs: i64, allocator := context.allocator) -> string {
	if fs > 0 && fs < 1_000 {
		return fmt.aprintf("%d fs", fs, allocator = allocator)
	}
	if fs >= 1_000 && fs < 1_000_000 {
		return fmt.aprintf("%.2f ps", f64(fs) / 1000.0, allocator = allocator)
	}
	return obench.format_duration_ns(fs_to_ns_f64(fs), allocator)
}

Metric :: struct {
	unit:  string,
	value: f64,
}

Record :: struct {
	rank:               int,
	group_name:         string,
	name:               string,
	full_name:          string,
	param:              int,
	has_param:          bool,
	threads:            int,
	has_threads:        bool,
	ops_per_sample:     u64,
	samples:            int,
	warmup:             int,
	min_fs:             i64,
	p25_fs:             i64,
	p50_fs:             i64,
	p75_fs:             i64,
	p95_fs:             i64,
	p99_fs:             i64,
	max_fs:             i64,
	mean_fs:            i64,
	std_dev_fs:         i64,
	ci95_fs:            i64,
	cv_pct:             f64,
	iqr_fs:             i64,
	mad_fs:             i64,
	median_cycles:      f64,
	bytes_per_op:       u64,
	items_per_op:       u64,
	mb_per_sec:         f64,
	items_per_sec:      f64,
	footprint_bytes:    u64,
	allocs_per_op:      f64,
	resizes_per_op:     f64,
	alloc_bytes_per_op: f64,
	temp_allocs_per_op: f64,
	temp_bytes_per_op:  f64,
	peak_heap_bytes:    i64,
	zero_alloc_failed:  bool,
	error:              string,
	metrics:            [dynamic]Metric,
	samples_batch_ns:   [dynamic]u64,
}

Run_Packet :: struct {
	suite_name:     string,
	lang:           string,
	commit:         string,
	run_id:         string,
	os:             string,
	arch:           string,
	optimization:   string,
	odin_version:   string,
	timestamp_unix: i64,
	selective:      bool,
	records:        [dynamic]Record,
}

@(require_results)
record_clone :: proc(r: Record, allocator := context.allocator) -> Record {
	out := r
	out.group_name = strings.clone(r.group_name, allocator)
	out.name = strings.clone(r.name, allocator)
	out.full_name = strings.clone(r.full_name, allocator)
	out.error = strings.clone(r.error, allocator)
	out.metrics = make([dynamic]Metric, len(r.metrics), allocator)
	for m, i in r.metrics {
		out.metrics[i] = Metric {
			unit  = strings.clone(m.unit, allocator),
			value = m.value,
		}
	}
	out.samples_batch_ns = make([dynamic]u64, len(r.samples_batch_ns), allocator)
	copy(out.samples_batch_ns[:], r.samples_batch_ns[:])
	return out
}

record_destroy :: proc(r: ^Record, allocator := context.allocator) {
	if r == nil {
		return
	}
	delete(r.group_name, allocator)
	delete(r.name, allocator)
	delete(r.full_name, allocator)
	delete(r.error, allocator)
	for m in r.metrics {
		delete(m.unit, allocator)
	}
	delete(r.metrics)
	delete(r.samples_batch_ns)
	r^ = {}
}

packet_destroy :: proc(pkt: ^Run_Packet, allocator := context.allocator) {
	if pkt == nil {
		return
	}
	delete(pkt.suite_name, allocator)
	delete(pkt.lang, allocator)
	delete(pkt.commit, allocator)
	delete(pkt.run_id, allocator)
	delete(pkt.os, allocator)
	delete(pkt.arch, allocator)
	delete(pkt.optimization, allocator)
	delete(pkt.odin_version, allocator)
	for &r in pkt.records {
		record_destroy(&r, allocator)
	}
	delete(pkt.records)
	pkt^ = {}
}

packets_destroy :: proc(pkts: []Run_Packet, allocator := context.allocator) {
	for &p in pkts {
		packet_destroy(&p, allocator)
	}
	delete(pkts, allocator)
}

@(private = "file")
_append_u8 :: proc(buf: ^[dynamic]u8, v: u8) {
	append(buf, v)
}

@(private = "file")
_append_u32 :: proc(buf: ^[dynamic]u8, v: u32) {
	val := u32le(v)
	bytes := transmute([4]u8)val
	append(buf, ..bytes[:])
}

@(private = "file")
_append_u64 :: proc(buf: ^[dynamic]u8, v: u64) {
	val := u64le(v)
	bytes := transmute([8]u8)val
	append(buf, ..bytes[:])
}

@(private = "file")
_append_i64 :: proc(buf: ^[dynamic]u8, v: i64) {
	_append_u64(buf, u64(v))
}

@(private = "file")
_append_f64 :: proc(buf: ^[dynamic]u8, v: f64) {
	_append_u64(buf, transmute(u64)v)
}

@(private = "file")
_append_str :: proc(buf: ^[dynamic]u8, s: string) {
	_append_u32(buf, u32(len(s)))
	if len(s) > 0 {
		append(buf, ..transmute([]u8)s)
	}
}

@(private = "file")
_Reader :: struct {
	data: []u8,
	pos:  int,
}

@(private = "file", require_results)
_read_u8 :: proc(r: ^_Reader) -> (u8, bool) {
	if r.pos + 1 > len(r.data) {
		return 0, false
	}
	v := r.data[r.pos]
	r.pos += 1
	return v, true
}

@(private = "file", require_results)
_read_u32 :: proc(r: ^_Reader) -> (u32, bool) {
	if r.pos + 4 > len(r.data) {
		return 0, false
	}
	b: [4]u8
	copy(b[:], r.data[r.pos:r.pos + 4])
	r.pos += 4
	return u32(transmute(u32le)b), true
}

@(private = "file", require_results)
_read_u64 :: proc(r: ^_Reader) -> (u64, bool) {
	if r.pos + 8 > len(r.data) {
		return 0, false
	}
	b: [8]u8
	copy(b[:], r.data[r.pos:r.pos + 8])
	r.pos += 8
	return u64(transmute(u64le)b), true
}

@(private = "file", require_results)
_read_i64 :: proc(r: ^_Reader) -> (val: i64, ok: bool) {
	v := _read_u64(r) or_return
	return i64(v), true
}

@(private = "file", require_results)
_read_f64 :: proc(r: ^_Reader) -> (val: f64, ok: bool) {
	v := _read_u64(r) or_return
	return transmute(f64)v, true
}

@(private = "file", require_results)
_read_str :: proc(r: ^_Reader, allocator: runtime.Allocator) -> (val: string, ok: bool) {
	n := int(_read_u32(r) or_return)
	if n < 0 || r.pos + n > len(r.data) {
		return "", false
	}
	s := strings.clone(string(r.data[r.pos:r.pos + n]), allocator)
	r.pos += n
	return s, true
}

@(private = "file")
_write_record_body :: proc(buf: ^[dynamic]u8, r: Record, include_samples: bool) {
	_append_i64(buf, i64(r.rank))
	_append_str(buf, r.group_name)
	_append_str(buf, r.name)
	_append_str(buf, r.full_name)
	_append_i64(buf, i64(r.param))
	_append_u8(buf, 1 if r.has_param else 0)
	_append_i64(buf, i64(r.threads))
	_append_u8(buf, 1 if r.has_threads else 0)
	_append_u64(buf, r.ops_per_sample)
	_append_u32(buf, u32(r.samples))
	_append_u32(buf, u32(r.warmup))
	_append_i64(buf, r.min_fs)
	_append_i64(buf, r.p25_fs)
	_append_i64(buf, r.p50_fs)
	_append_i64(buf, r.p75_fs)
	_append_i64(buf, r.p95_fs)
	_append_i64(buf, r.p99_fs)
	_append_i64(buf, r.max_fs)
	_append_i64(buf, r.mean_fs)
	_append_i64(buf, r.std_dev_fs)
	_append_i64(buf, r.ci95_fs)
	_append_f64(buf, r.cv_pct)
	_append_i64(buf, r.iqr_fs)
	_append_i64(buf, r.mad_fs)
	_append_f64(buf, r.median_cycles)
	_append_u64(buf, r.bytes_per_op)
	_append_u64(buf, r.items_per_op)
	_append_f64(buf, r.mb_per_sec)
	_append_f64(buf, r.items_per_sec)
	_append_u64(buf, r.footprint_bytes)
	_append_f64(buf, r.allocs_per_op)
	_append_f64(buf, r.resizes_per_op)
	_append_f64(buf, r.alloc_bytes_per_op)
	_append_f64(buf, r.temp_allocs_per_op)
	_append_f64(buf, r.temp_bytes_per_op)
	_append_i64(buf, r.peak_heap_bytes)
	_append_u8(buf, 1 if r.zero_alloc_failed else 0)
	_append_str(buf, r.error)

	_append_u32(buf, u32(len(r.metrics)))
	for m in r.metrics {
		_append_str(buf, m.unit)
		_append_f64(buf, m.value)
	}

	if include_samples {
		_append_u32(buf, u32(len(r.samples_batch_ns)))
		for s in r.samples_batch_ns {
			_append_u64(buf, s)
		}
	} else {
		_append_u32(buf, 0)
	}
}

@(private = "file", require_results)
_read_record_body :: proc(rd: ^_Reader, allocator: runtime.Allocator) -> (rec: Record, ok: bool) {
	defer if !ok {
		record_destroy(&rec, allocator)
	}
	rec.metrics = make([dynamic]Metric, allocator)
	rec.samples_batch_ns = make([dynamic]u64, allocator)

	rank_i := _read_i64(rd) or_return
	rec.rank = int(rank_i)
	rec.group_name = _read_str(rd, allocator) or_return
	rec.name = _read_str(rd, allocator) or_return
	rec.full_name = _read_str(rd, allocator) or_return
	param_i := _read_i64(rd) or_return
	rec.param = int(param_i)
	rec.has_param = (_read_u8(rd) or_return) != 0
	threads_i := _read_i64(rd) or_return
	rec.threads = int(threads_i)
	rec.has_threads = (_read_u8(rd) or_return) != 0
	rec.ops_per_sample = _read_u64(rd) or_return
	rec.samples = int(_read_u32(rd) or_return)
	rec.warmup = int(_read_u32(rd) or_return)
	rec.min_fs = _read_i64(rd) or_return
	rec.p25_fs = _read_i64(rd) or_return
	rec.p50_fs = _read_i64(rd) or_return
	rec.p75_fs = _read_i64(rd) or_return
	rec.p95_fs = _read_i64(rd) or_return
	rec.p99_fs = _read_i64(rd) or_return
	rec.max_fs = _read_i64(rd) or_return
	rec.mean_fs = _read_i64(rd) or_return
	rec.std_dev_fs = _read_i64(rd) or_return
	rec.ci95_fs = _read_i64(rd) or_return
	rec.cv_pct = _read_f64(rd) or_return
	rec.iqr_fs = _read_i64(rd) or_return
	rec.mad_fs = _read_i64(rd) or_return
	rec.median_cycles = _read_f64(rd) or_return
	rec.bytes_per_op = _read_u64(rd) or_return
	rec.items_per_op = _read_u64(rd) or_return
	rec.mb_per_sec = _read_f64(rd) or_return
	rec.items_per_sec = _read_f64(rd) or_return
	rec.footprint_bytes = _read_u64(rd) or_return
	rec.allocs_per_op = _read_f64(rd) or_return
	rec.resizes_per_op = _read_f64(rd) or_return
	rec.alloc_bytes_per_op = _read_f64(rd) or_return
	rec.temp_allocs_per_op = _read_f64(rd) or_return
	rec.temp_bytes_per_op = _read_f64(rd) or_return
	rec.peak_heap_bytes = _read_i64(rd) or_return
	rec.zero_alloc_failed = (_read_u8(rd) or_return) != 0
	rec.error = _read_str(rd, allocator) or_return

	m_count := int(_read_u32(rd) or_return)
	if m_count < 0 || m_count > 1024 {
		return rec, false
	}
	reserve(&rec.metrics, m_count)
	for _ in 0 ..< m_count {
		unit := _read_str(rd, allocator) or_return
		val := _read_f64(rd) or_return
		append(&rec.metrics, Metric{unit = unit, value = val})
	}

	s_count := int(_read_u32(rd) or_return)
	if s_count < 0 || rd.pos + s_count * 8 > len(rd.data) {
		return rec, false
	}
	reserve(&rec.samples_batch_ns, s_count)
	for _ in 0 ..< s_count {
		s := _read_u64(rd) or_return
		append(&rec.samples_batch_ns, s)
	}

	return rec, true
}

/*
Serializes `rec` into a compact binary `OBRC` byte buffer. When `include_samples` is
`false`, the `samples_batch_ns` array is omitted so callers can store it separately compressed.
*/
@(require_results)
encode_record_bytes :: proc(
	rec: Record,
	include_samples := true,
	allocator := context.allocator,
) -> []u8 {
	buf := make([dynamic]u8, 0, 256, allocator)
	append(&buf, ..transmute([]u8)string(RECORD_MAGIC))
	_write_record_body(&buf, rec, include_samples)
	return buf[:]
}

/*
Decodes a single `OBRC\x02` record byte buffer into `Record`.
*/
@(require_results)
decode_record_bytes :: proc(
	data: []u8,
	allocator := context.allocator,
) -> (
	rec: Record,
	ok: bool,
) {
	if len(data) < len(RECORD_MAGIC) || string(data[:len(RECORD_MAGIC)]) != RECORD_MAGIC {
		return {}, false
	}
	rd := _Reader {
		data = data,
		pos  = len(RECORD_MAGIC),
	}
	return _read_record_body(&rd, allocator)
}

/*
Serializes `pkt` into a compact little-endian binary `HPKT` byte buffer.
*/
@(require_results)
encode_packet_bytes :: proc(
	pkt: Run_Packet,
	include_samples := true,
	allocator := context.allocator,
) -> []u8 {
	buf := make([dynamic]u8, 0, 1024, allocator)
	append(&buf, ..transmute([]u8)string(PACKET_MAGIC))
	_append_str(&buf, pkt.suite_name)
	_append_str(&buf, pkt.lang)
	_append_str(&buf, pkt.commit)
	_append_str(&buf, pkt.run_id)
	_append_str(&buf, pkt.os)
	_append_str(&buf, pkt.arch)
	_append_str(&buf, pkt.optimization)
	_append_str(&buf, pkt.odin_version)
	_append_i64(&buf, pkt.timestamp_unix)
	_append_u8(&buf, 1 if pkt.selective else 0)
	_append_u32(&buf, u32(len(pkt.records)))
	for r in pkt.records {
		_write_record_body(&buf, r, include_samples)
	}
	return buf[:]
}

/*
Decodes an `HPKT\x02` binary buffer into a `Run_Packet`.
*/
@(require_results)
decode_packet_bytes :: proc(
	data: []u8,
	allocator := context.allocator,
) -> (
	pkt: Run_Packet,
	ok: bool,
) {
	if len(data) < len(PACKET_MAGIC) || string(data[:len(PACKET_MAGIC)]) != PACKET_MAGIC {
		return {}, false
	}
	defer if !ok {
		packet_destroy(&pkt, allocator)
	}
	rd := _Reader {
		data = data,
		pos  = len(PACKET_MAGIC),
	}
	pkt.records = make([dynamic]Record, allocator)

	pkt.suite_name = _read_str(&rd, allocator) or_return
	pkt.lang = _read_str(&rd, allocator) or_return
	pkt.commit = _read_str(&rd, allocator) or_return
	pkt.run_id = _read_str(&rd, allocator) or_return
	pkt.os = _read_str(&rd, allocator) or_return
	pkt.arch = _read_str(&rd, allocator) or_return
	pkt.optimization = _read_str(&rd, allocator) or_return
	pkt.odin_version = _read_str(&rd, allocator) or_return
	pkt.timestamp_unix = _read_i64(&rd) or_return
	pkt.selective = (_read_u8(&rd) or_return) != 0

	rec_count := int(_read_u32(&rd) or_return)
	if rec_count < 0 || rec_count > 100_000 {
		return pkt, false
	}
	reserve(&pkt.records, rec_count)
	for _ in 0 ..< rec_count {
		r := _read_record_body(&rd, allocator) or_return
		append(&pkt.records, r)
	}
	return pkt, true
}

@(require_results)
write_packet_file :: proc(path: string, pkt: Run_Packet) -> os.Error {
	raw := encode_packet_bytes(pkt, true, context.temp_allocator)
	return os.write_entire_file(path, raw)
}

@(require_results)
read_packet_file :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	pkt: Run_Packet,
	ok: bool,
) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	return decode_packet_bytes(data, allocator)
}

Stats_FS :: struct {
	samples:    int,
	min_fs:     i64,
	p25_fs:     i64,
	p50_fs:     i64,
	p75_fs:     i64,
	p95_fs:     i64,
	p99_fs:     i64,
	max_fs:     i64,
	mean_fs:    i64,
	std_dev_fs: i64,
	ci95_fs:    i64,
	cv_pct:     f64,
	iqr_fs:     i64,
	mad_fs:     i64,
}

/*
Computes exact fixed-point femtosecond quantiles, mean, standard deviation, CI95, CV%, IQR, and
MAD from `samples_fs` without mutating the input slice.
*/
@(require_results)
compute_stats_fs :: proc(
	samples_fs: []i64,
	allocator := context.temp_allocator,
) -> (
	st: Stats_FS,
) {
	n := len(samples_fs)
	if n == 0 {
		return {}
	}
	sorted := slice.clone(samples_fs, allocator)
	defer delete(sorted, allocator)
	slice.sort(sorted)

	st.samples = n
	st.min_fs = sorted[0]
	st.max_fs = sorted[n - 1]
	st.p25_fs = percentile_sorted_fs(sorted, 25)
	st.p50_fs = percentile_sorted_fs(sorted, 50)
	st.p75_fs = percentile_sorted_fs(sorted, 75)
	st.p95_fs = percentile_sorted_fs(sorted, 95)
	st.p99_fs = percentile_sorted_fs(sorted, 99)
	st.iqr_fs = st.p75_fs - st.p25_fs

	sum_fs: i128 = 0
	for v in sorted {
		sum_fs += i128(v)
	}
	st.mean_fs = i64((sum_fs + i128(n / 2)) / i128(n))

	var_sum := 0.0
	for v in sorted {
		d := f64(v - st.mean_fs)
		var_sum += d * d
	}
	if n > 1 {
		std_f := math.sqrt(var_sum / f64(n - 1))
		st.std_dev_fs = i64(math.round(std_f))
		st.ci95_fs = i64(
			math.round(obench.t_critical_975(f64(n - 1)) * (std_f / math.sqrt(f64(n)))),
		)
		st.cv_pct = st.mean_fs > 0 ? (std_f / f64(st.mean_fs)) * 100.0 : 0.0
	}

	abs_devs := make([]i64, n, allocator)
	defer delete(abs_devs, allocator)
	for v, i in sorted {
		abs_devs[i] = abs(v - st.p50_fs)
	}
	slice.sort(abs_devs)
	st.mad_fs = percentile_sorted_fs(abs_devs, 50)
	return st
}

@(require_results)
compute_throughput_from_p50 :: proc "contextless" (
	p50_fs: i64,
	bytes_per_op: u64 = 0,
	items_per_op: u64 = 0,
) -> (
	ops_per_sec: f64,
	items_per_sec: f64,
	mb_per_sec: f64,
) {
	if p50_fs <= 0 {
		return 0, 0, 0
	}
	ops_per_sec = FS_PER_SEC_F64 / f64(p50_fs)
	items_per_sec = items_per_op > 0 ? f64(items_per_op) * ops_per_sec : ops_per_sec
	if bytes_per_op > 0 {
		mb_per_sec = (f64(bytes_per_op) * ops_per_sec) / (1024.0 * 1024.0)
	}
	return ops_per_sec, items_per_sec, mb_per_sec
}

refresh_record_throughput :: proc "contextless" (r: ^Record, overwrite := true) {
	if r == nil || r.p50_fs <= 0 {
		return
	}
	_, items_s, mb_s := compute_throughput_from_p50(r.p50_fs, r.bytes_per_op, r.items_per_op)
	if overwrite || r.items_per_sec <= 0 {
		r.items_per_sec = items_s
	}
	if r.bytes_per_op > 0 && (overwrite || r.mb_per_sec <= 0) {
		r.mb_per_sec = mb_s
	}
}

/*
Recomputes exact fixed-point femtosecond quantile/dispersion fields on `r` from
`r.samples_batch_ns` and `r.ops_per_sample`.
*/
recompute_record_stats_from_samples :: proc(r: ^Record, allocator := context.temp_allocator) {
	if r == nil || len(r.samples_batch_ns) == 0 {
		return
	}
	n := len(r.samples_batch_ns)
	samples_fs := make([]i64, n, allocator)
	defer delete(samples_fs, allocator)
	ops := max(r.ops_per_sample, 1)
	for b, i in r.samples_batch_ns {
		samples_fs[i] = batch_ns_to_op_fs(b, ops)
	}
	st := compute_stats_fs(samples_fs, allocator)
	r.samples = st.samples
	r.min_fs = st.min_fs
	r.p25_fs = st.p25_fs
	r.p50_fs = st.p50_fs
	r.p75_fs = st.p75_fs
	r.p95_fs = st.p95_fs
	r.p99_fs = st.p99_fs
	r.max_fs = st.max_fs
	r.mean_fs = st.mean_fs
	r.std_dev_fs = st.std_dev_fs
	r.ci95_fs = st.ci95_fs
	r.cv_pct = st.cv_pct
	r.iqr_fs = st.iqr_fs
	r.mad_fs = st.mad_fs
}
