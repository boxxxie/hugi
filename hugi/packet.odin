package hugi

import obench "../deps/obench/obench"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

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

/*
Recomputes exact fixed-point femtosecond quantile/dispersion fields on `r` from
`r.samples_batch_ns` and `r.ops_per_sample`.
*/
recompute_record_stats_from_samples :: proc(r: ^Record, allocator := context.temp_allocator) {
	n := len(r.samples_batch_ns)
	if n == 0 {
		return
	}
	sorted := make([]i64, n, allocator)
	defer delete(sorted, allocator)
	ops := max(r.ops_per_sample, 1)
	for b, i in r.samples_batch_ns {
		sorted[i] = batch_ns_to_op_fs(b, ops)
	}
	slice.sort(sorted)

	r.samples = n
	r.min_fs = sorted[0]
	r.max_fs = sorted[n - 1]
	r.p25_fs = percentile_sorted_fs(sorted, 25)
	r.p50_fs = percentile_sorted_fs(sorted, 50)
	r.p75_fs = percentile_sorted_fs(sorted, 75)
	r.p95_fs = percentile_sorted_fs(sorted, 95)
	r.p99_fs = percentile_sorted_fs(sorted, 99)
	r.iqr_fs = r.p75_fs - r.p25_fs

	sum_fs: i128 = 0
	for v in sorted {
		sum_fs += i128(v)
	}
	r.mean_fs = i64((sum_fs + i128(n / 2)) / i128(n))

	var_sum := 0.0
	for v in sorted {
		d := f64(v - r.mean_fs)
		var_sum += d * d
	}
	if n > 1 {
		std_f := math.sqrt(var_sum / f64(n - 1))
		r.std_dev_fs = i64(math.round(std_f))
		r.ci95_fs = i64(
			math.round(obench.t_critical_975(f64(n - 1)) * (std_f / math.sqrt(f64(n)))),
		)
		r.cv_pct = r.mean_fs > 0 ? (std_f / f64(r.mean_fs)) * 100.0 : 0.0
	} else {
		r.std_dev_fs = 0
		r.ci95_fs = 0
		r.cv_pct = 0.0
	}

	abs_devs := make([]i64, n, allocator)
	defer delete(abs_devs, allocator)
	for v, i in sorted {
		abs_devs[i] = abs(v - r.p50_fs)
	}
	slice.sort(abs_devs)
	r.mad_fs = percentile_sorted_fs(abs_devs, 50)
}

/*
Converts an `obench` JSON report (`Export_Document`) into one `Run_Packet` per suite.
*/
@(require_results)
read_obench_json_packets :: proc(
	path: string,
	lang_override := "",
	commit_override := "",
	run_id_override := "",
	allocator := context.allocator,
) -> (
	packets: []Run_Packet,
	ok: bool,
) {
	doc, err := obench.read_json_report(path, context.temp_allocator)
	if err != nil {
		return nil, false
	}

	lang := lang_override != "" ? lang_override : "odin"
	commit :=
		commit_override != "" ? commit_override : resolve_git_commit(".", context.temp_allocator)
	base_run_id := run_id_override != "" ? run_id_override : default_run_id(context.temp_allocator)
	ts := i64(time.to_unix_nanoseconds(time.now())) / 1_000_000_000

	suite_order := make([dynamic]string, context.temp_allocator)
	by_suite := make(map[string]int, context.temp_allocator)
	pkts := make([dynamic]Run_Packet, allocator)

	for &e in doc.benchmarks {
		s_name := e.suite_name != "" ? e.suite_name : doc.suite_name
		if s_name == "" {
			s_name = "obench"
		}
		pkt_idx, seen := by_suite[s_name]
		if !seen {
			pkt_idx = len(pkts)
			by_suite[s_name] = pkt_idx
			append(&suite_order, s_name)
			rid := base_run_id
			if len(suite_order) > 1 {
				rid = fmt.tprintf("%s-%d", base_run_id, pkt_idx)
			}
			append(
				&pkts,
				Run_Packet {
					suite_name = strings.clone(s_name, allocator),
					lang = strings.clone(lang, allocator),
					commit = strings.clone(commit, allocator),
					run_id = strings.clone(rid, allocator),
					os = strings.clone(doc.os, allocator),
					arch = strings.clone(doc.arch, allocator),
					optimization = strings.clone(doc.optimization, allocator),
					odin_version = strings.clone(doc.odin_version, allocator),
					timestamp_unix = ts,
					records = make([dynamic]Record, allocator),
				},
			)
		}

		ops := u64(max(e.batch_size, 1))
		s_cnt := len(e.samples_batch_ns) > 0 ? len(e.samples_batch_ns) : len(e.samples_ns)
		r := Record {
			rank               = len(pkts[pkt_idx].records) + 1,
			group_name         = strings.clone(e.group_name, allocator),
			name               = strings.clone(e.name, allocator),
			full_name          = strings.clone(e.full_name, allocator),
			param              = e.param,
			has_param          = e.has_param,
			threads            = e.threads,
			has_threads        = e.has_threads,
			ops_per_sample     = ops,
			samples            = e.samples,
			min_fs             = ns_f64_to_fs(e.min_ns),
			p50_fs             = ns_f64_to_fs(e.p50_ns),
			p95_fs             = ns_f64_to_fs(e.p95_ns),
			p99_fs             = ns_f64_to_fs(e.p99_ns),
			max_fs             = ns_f64_to_fs(e.max_ns),
			mean_fs            = ns_f64_to_fs(e.mean_ns),
			std_dev_fs         = ns_f64_to_fs(e.std_dev_ns),
			ci95_fs            = ns_f64_to_fs(e.ci95_ns),
			mad_fs             = ns_f64_to_fs(e.mad_ns),
			median_cycles      = e.median_cycles,
			mb_per_sec         = e.mb_per_sec,
			items_per_sec      = e.items_per_sec,
			allocs_per_op      = e.allocs_per_op,
			resizes_per_op     = e.resizes_per_op,
			alloc_bytes_per_op = e.alloc_bytes_per_op,
			temp_allocs_per_op = e.temp_allocs_per_op,
			temp_bytes_per_op  = e.temp_bytes_per_op,
			error              = strings.clone(e.error, allocator),
			metrics            = make([dynamic]Metric, allocator),
			samples_batch_ns   = make([dynamic]u64, s_cnt, allocator),
		}
		if len(e.samples_batch_ns) > 0 {
			copy(r.samples_batch_ns[:], e.samples_batch_ns)
		} else {
			for s, si in e.samples_ns {
				r.samples_batch_ns[si] = ns_f64_to_batch_ns(s, ops)
			}
		}
		for m in e.custom_metrics {
			append(&r.metrics, Metric{unit = strings.clone(m.unit, allocator), value = m.value})
		}
		if r.mean_fs > 0 {
			r.cv_pct = (f64(r.std_dev_fs) / f64(r.mean_fs)) * 100.0
		}
		if len(r.samples_batch_ns) > 0 {
			recompute_record_stats_from_samples(&r)
			if r.p50_fs > 0 && r.items_per_sec <= 0 {
				r.items_per_sec = FS_PER_SEC_F64 / f64(r.p50_fs)
			}
		}
		append(&pkts[pkt_idx].records, r)
	}

	return pkts[:], true
}

@(private = "file")
_Jsonl_Row :: struct {
	rank:                int `json:"rank"`,
	group:               string `json:"group"`,
	lang:                string `json:"lang"`,
	commit:              string `json:"commit"`,
	run_id:              string `json:"run_id"`,
	name:                string `json:"name"`,
	ops:                 u64 `json:"ops"`,
	runs:                int `json:"runs"`,
	warmup:              int `json:"warmup"`,
	total_ms:            f64 `json:"total_ms"`,
	ns_per_op:           f64 `json:"ns_per_op"`,
	mean_ns:             f64 `json:"mean_ns"`,
	median_ns:           f64 `json:"median_ns"`,
	stddev_ns:           f64 `json:"stddev_ns"`,
	cv_pct:              f64 `json:"cv_pct"`,
	min_ns:              f64 `json:"min_ns"`,
	max_ns:              f64 `json:"max_ns"`,
	iqr_ns:              f64 `json:"iqr_ns"`,
	p95_ns:              f64 `json:"p95_ns"`,
	p99_ns:              f64 `json:"p99_ns"`,
	ops_per_sec:         f64 `json:"ops_per_sec"`,
	gb_per_sec:          f64 `json:"gb_per_sec"`,
	bytes_used:          u64 `json:"bytes_used"`,
	allocs_per_run:      u64 `json:"allocs_per_run"`,
	resizes_per_run:     u64 `json:"resizes_per_run"`,
	alloc_bytes_per_run: u64 `json:"alloc_bytes_per_run"`,
	peak_live_bytes:     i64 `json:"peak_live_bytes"`,
	pool_hits:           u64 `json:"pool_hits"`,
	pool_misses:         u64 `json:"pool_misses"`,
	samples_ns:          []f64 `json:"samples_ns"`,
	samples_batch_ns:    []u64 `json:"samples_batch_ns"`,
}

/*
Parses legacy `xitdb` / `skadi` / `duckdb` JSONL files into chronological `Run_Packet`s
grouped by `(commit, lang, run_id)`.
*/
@(require_results)
read_jsonl_packets :: proc(
	path: string,
	lang_override := "",
	commit_override := "",
	run_id_override := "",
	allocator := context.allocator,
) -> (
	packets: []Run_Packet,
	ok: bool,
) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return nil, false
	}

	pkts := make([dynamic]Run_Packet, allocator)
	key_to_idx := make(map[string]int, context.temp_allocator)
	now_ts := i64(time.to_unix_nanoseconds(time.now())) / 1_000_000_000

	text := string(data)
	for raw_line in strings.split_lines_iterator(&text) {
		line := strings.trim_space(raw_line)
		if len(line) == 0 || !strings.has_prefix(line, "{") {
			continue
		}
		row: _Jsonl_Row
		if json.unmarshal(transmute([]u8)line, &row, allocator = context.temp_allocator) != nil {
			continue
		}
		if row.name == "" {
			continue
		}

		lang := lang_override != "" ? lang_override : (row.lang != "" ? row.lang : "odin")
		commit :=
			commit_override != "" ? commit_override : (row.commit != "" ? row.commit : "unknown")
		rid := run_id_override
		if rid == "" {
			rid = row.run_id != "" ? row.run_id : fmt.tprintf("jsonl-%s-%s", commit, lang)
		}

		// Key packets by `(commit, lang, run_id)` so separate invocations stay distinct.
		pkt_key := fmt.tprintf("%s\x00%s\x00%s", commit, lang, rid)
		pkt_idx, found := key_to_idx[pkt_key]
		if !found {
			pkt_idx = len(pkts)
			key_to_idx[pkt_key] = pkt_idx
			append(
				&pkts,
				Run_Packet {
					suite_name = strings.clone("jsonl_import", allocator),
					lang = strings.clone(lang, allocator),
					commit = strings.clone(commit, allocator),
					run_id = strings.clone(rid, allocator),
					os = strings.clone(ODIN_OS_STRING, allocator),
					arch = strings.clone(ODIN_ARCH_STRING, allocator),
					optimization = strings.clone("Speed", allocator),
					odin_version = strings.clone("", allocator),
					timestamp_unix = now_ts,
					records = make([dynamic]Record, allocator),
				},
			)
		}

		eff_ops := max(row.ops, 1)
		if row.ops == 0 && len(row.samples_ns) > 0 {
			has_sub_ns := false
			has_sub_ps := false
			for s in row.samples_ns {
				fs := ns_f64_to_fs(s)
				if fs % FS_PER_NS != 0 {
					has_sub_ns = true
				}
				if fs % 1_000 != 0 {
					has_sub_ps = true
				}
			}
			if has_sub_ps {
				eff_ops = 1_000_000
			} else if has_sub_ns {
				eff_ops = 1_000
			}
		}

		ops_f := f64(max(row.ops, 1))
		mb_s := row.gb_per_sec * 1024.0
		med := row.median_ns > 0 ? row.median_ns : row.ns_per_op
		ops_s := row.ops_per_sec
		if ops_s <= 0 && med > 0 {
			ops_s = 1_000_000_000.0 / med
		}
		med_fs := ns_f64_to_fs(med)
		s_cnt := len(row.samples_batch_ns) > 0 ? len(row.samples_batch_ns) : len(row.samples_ns)

		r := Record {
			rank               = row.rank > 0 ? row.rank : len(pkts[pkt_idx].records) + 1,
			group_name         = strings.clone(row.group, allocator),
			name               = strings.clone(row.name, allocator),
			full_name          = strings.clone(row.name, allocator),
			ops_per_sample     = eff_ops,
			samples            = row.runs > 0 ? row.runs : s_cnt,
			warmup             = row.warmup,
			min_fs             = ns_f64_to_fs(row.min_ns),
			p50_fs             = med_fs,
			p95_fs             = ns_f64_to_fs(row.p95_ns),
			p99_fs             = ns_f64_to_fs(row.p99_ns),
			max_fs             = ns_f64_to_fs(row.max_ns),
			mean_fs            = row.mean_ns > 0 ? ns_f64_to_fs(row.mean_ns) : med_fs,
			std_dev_fs         = ns_f64_to_fs(row.stddev_ns),
			cv_pct             = row.cv_pct,
			iqr_fs             = ns_f64_to_fs(row.iqr_ns),
			mb_per_sec         = mb_s,
			items_per_sec      = ops_s,
			footprint_bytes    = row.bytes_used,
			allocs_per_op      = f64(row.allocs_per_run) / ops_f,
			resizes_per_op     = f64(row.resizes_per_run) / ops_f,
			alloc_bytes_per_op = f64(row.alloc_bytes_per_run) / ops_f,
			peak_heap_bytes    = row.peak_live_bytes,
			error              = strings.clone("", allocator),
			metrics            = make([dynamic]Metric, allocator),
			samples_batch_ns   = make([dynamic]u64, s_cnt, allocator),
		}
		if len(row.samples_batch_ns) > 0 {
			copy(r.samples_batch_ns[:], row.samples_batch_ns)
			recompute_record_stats_from_samples(&r)
		} else if len(row.samples_ns) > 0 {
			for s, si in row.samples_ns {
				r.samples_batch_ns[si] = ns_f64_to_batch_ns(s, eff_ops)
			}
			recompute_record_stats_from_samples(&r)
		} else if med > 0 {
			append(&r.samples_batch_ns, ns_f64_to_batch_ns(med, eff_ops))
			recompute_record_stats_from_samples(&r)
		}
		if row.pool_hits > 0 || row.pool_misses > 0 {
			append(
				&r.metrics,
				Metric{unit = strings.clone("pool_hits", allocator), value = f64(row.pool_hits)},
			)
			append(
				&r.metrics,
				Metric {
					unit = strings.clone("pool_misses", allocator),
					value = f64(row.pool_misses),
				},
			)
		}
		append(&pkts[pkt_idx].records, r)
	}

	return pkts[:], len(pkts) > 0
}
