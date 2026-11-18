package hugi_store

import "core:os"
import "vendor:zlib"

@(private = "file")
_PQ_TYPE_INT64 :: i32(2)
@(private = "file")
_PQ_TYPE_DOUBLE :: i32(5)
@(private = "file")
_PQ_TYPE_BYTE_ARRAY :: i32(6)

@(private = "file")
_PQ_REP_REQUIRED :: i32(0)

@(private = "file")
_PQ_CTYPE_NONE :: i32(-1)
@(private = "file")
_PQ_CTYPE_UTF8 :: i32(0)
@(private = "file")
_PQ_CTYPE_UINT64 :: i32(14)

@(private = "file")
_PQ_CODEC_UNCOMPRESSED :: i32(0)
@(private = "file")
_PQ_CODEC_GZIP :: i32(2)

@(private = "file")
_PQ_TW_I32 :: u8(5)
@(private = "file")
_PQ_TW_I64 :: u8(6)
@(private = "file")
_PQ_TW_BINARY :: u8(8)
@(private = "file")
_PQ_TW_LIST :: u8(9)
@(private = "file")
_PQ_TW_STRUCT :: u8(12)

@(private = "file")
_PQ_Column_Kind :: enum u8 {
	String,
	I64,
	U64,
	F64,
	Samples_Blob,
}

@(private = "file")
_PQ_Column_Spec :: struct {
	name:      string,
	ptype:     i32,
	ctype:     i32,
	kind:      _PQ_Column_Kind,
	str_field: int,
	i64_field: int,
	u64_field: int,
	f64_field: int,
}

@(private = "file")
_pq_column_specs := [33]_PQ_Column_Spec {
	{
		name = "commit",
		ptype = _PQ_TYPE_BYTE_ARRAY,
		ctype = _PQ_CTYPE_UTF8,
		kind = .String,
		str_field = 0,
	},
	{
		name = "lang",
		ptype = _PQ_TYPE_BYTE_ARRAY,
		ctype = _PQ_CTYPE_UTF8,
		kind = .String,
		str_field = 1,
	},
	{
		name = "suite_name",
		ptype = _PQ_TYPE_BYTE_ARRAY,
		ctype = _PQ_CTYPE_UTF8,
		kind = .String,
		str_field = 2,
	},
	{
		name = "group_name",
		ptype = _PQ_TYPE_BYTE_ARRAY,
		ctype = _PQ_CTYPE_UTF8,
		kind = .String,
		str_field = 3,
	},
	{
		name = "name",
		ptype = _PQ_TYPE_BYTE_ARRAY,
		ctype = _PQ_CTYPE_UTF8,
		kind = .String,
		str_field = 4,
	},
	{
		name = "full_name",
		ptype = _PQ_TYPE_BYTE_ARRAY,
		ctype = _PQ_CTYPE_UTF8,
		kind = .String,
		str_field = 5,
	},
	{name = "rank", ptype = _PQ_TYPE_INT64, ctype = _PQ_CTYPE_NONE, kind = .I64, i64_field = 0},
	{
		name = "run_count",
		ptype = _PQ_TYPE_INT64,
		ctype = _PQ_CTYPE_NONE,
		kind = .I64,
		i64_field = 1,
	},
	{
		name = "ops_per_sample",
		ptype = _PQ_TYPE_INT64,
		ctype = _PQ_CTYPE_UINT64,
		kind = .U64,
		u64_field = 0,
	},
	{name = "samples", ptype = _PQ_TYPE_INT64, ctype = _PQ_CTYPE_NONE, kind = .I64, i64_field = 2},
	{name = "min_ns", ptype = _PQ_TYPE_DOUBLE, ctype = _PQ_CTYPE_NONE, kind = .F64, f64_field = 0},
	{name = "p25_ns", ptype = _PQ_TYPE_DOUBLE, ctype = _PQ_CTYPE_NONE, kind = .F64, f64_field = 1},
	{name = "p50_ns", ptype = _PQ_TYPE_DOUBLE, ctype = _PQ_CTYPE_NONE, kind = .F64, f64_field = 2},
	{name = "p75_ns", ptype = _PQ_TYPE_DOUBLE, ctype = _PQ_CTYPE_NONE, kind = .F64, f64_field = 3},
	{name = "p95_ns", ptype = _PQ_TYPE_DOUBLE, ctype = _PQ_CTYPE_NONE, kind = .F64, f64_field = 4},
	{name = "p99_ns", ptype = _PQ_TYPE_DOUBLE, ctype = _PQ_CTYPE_NONE, kind = .F64, f64_field = 5},
	{name = "max_ns", ptype = _PQ_TYPE_DOUBLE, ctype = _PQ_CTYPE_NONE, kind = .F64, f64_field = 6},
	{
		name = "mean_ns",
		ptype = _PQ_TYPE_DOUBLE,
		ctype = _PQ_CTYPE_NONE,
		kind = .F64,
		f64_field = 7,
	},
	{
		name = "std_dev_ns",
		ptype = _PQ_TYPE_DOUBLE,
		ctype = _PQ_CTYPE_NONE,
		kind = .F64,
		f64_field = 8,
	},
	{
		name = "ci95_ns",
		ptype = _PQ_TYPE_DOUBLE,
		ctype = _PQ_CTYPE_NONE,
		kind = .F64,
		f64_field = 9,
	},
	{
		name = "cv_pct",
		ptype = _PQ_TYPE_DOUBLE,
		ctype = _PQ_CTYPE_NONE,
		kind = .F64,
		f64_field = 10,
	},
	{
		name = "iqr_ns",
		ptype = _PQ_TYPE_DOUBLE,
		ctype = _PQ_CTYPE_NONE,
		kind = .F64,
		f64_field = 11,
	},
	{
		name = "mad_ns",
		ptype = _PQ_TYPE_DOUBLE,
		ctype = _PQ_CTYPE_NONE,
		kind = .F64,
		f64_field = 12,
	},
	{
		name = "ops_per_sec",
		ptype = _PQ_TYPE_DOUBLE,
		ctype = _PQ_CTYPE_NONE,
		kind = .F64,
		f64_field = 13,
	},
	{
		name = "mb_per_sec",
		ptype = _PQ_TYPE_DOUBLE,
		ctype = _PQ_CTYPE_NONE,
		kind = .F64,
		f64_field = 14,
	},
	{
		name = "bytes_per_op",
		ptype = _PQ_TYPE_INT64,
		ctype = _PQ_CTYPE_UINT64,
		kind = .U64,
		u64_field = 1,
	},
	{
		name = "footprint_bytes",
		ptype = _PQ_TYPE_INT64,
		ctype = _PQ_CTYPE_UINT64,
		kind = .U64,
		u64_field = 2,
	},
	{
		name = "allocs_per_op",
		ptype = _PQ_TYPE_DOUBLE,
		ctype = _PQ_CTYPE_NONE,
		kind = .F64,
		f64_field = 15,
	},
	{
		name = "alloc_bytes_per_op",
		ptype = _PQ_TYPE_DOUBLE,
		ctype = _PQ_CTYPE_NONE,
		kind = .F64,
		f64_field = 16,
	},
	{
		name = "temp_allocs_per_op",
		ptype = _PQ_TYPE_DOUBLE,
		ctype = _PQ_CTYPE_NONE,
		kind = .F64,
		f64_field = 17,
	},
	{
		name = "temp_bytes_per_op",
		ptype = _PQ_TYPE_DOUBLE,
		ctype = _PQ_CTYPE_NONE,
		kind = .F64,
		f64_field = 18,
	},
	{
		name = "peak_heap_bytes",
		ptype = _PQ_TYPE_INT64,
		ctype = _PQ_CTYPE_NONE,
		kind = .I64,
		i64_field = 3,
	},
	{
		name = "samples_blob",
		ptype = _PQ_TYPE_BYTE_ARRAY,
		ctype = _PQ_CTYPE_NONE,
		kind = .Samples_Blob,
	},
}

@(private = "file")
_tw_varint :: proc(buf: ^[dynamic]u8, v: u64) {
	n := v
	for n >= 0x80 {
		append(buf, u8(n & 0x7F) | 0x80)
		n >>= 7
	}
	append(buf, u8(n))
}

@(private = "file")
_tw_i32 :: proc(buf: ^[dynamic]u8, v: i32) {
	uv := u32(v)
	_tw_varint(buf, u64((uv << 1) ~ u32(v >> 31)))
}

@(private = "file")
_tw_i64 :: proc(buf: ^[dynamic]u8, v: i64) {
	uv := u64(v)
	_tw_varint(buf, (uv << 1) ~ u64(v >> 63))
}

@(private = "file")
_tw_field :: proc(buf: ^[dynamic]u8, field_id: i32, ftype: u8, prev: ^i32) {
	delta := field_id - prev^
	if delta > 0 && delta < 16 {
		append(buf, u8(delta) << 4 | ftype)
	} else {
		append(buf, ftype)
		n := i16(field_id)
		zz := u16(n << 1) ~ u16(n >> 15)
		_tw_varint(buf, u64(zz))
	}
	prev^ = field_id
}

@(private = "file")
_tw_field_i32 :: proc(buf: ^[dynamic]u8, field_id: i32, v: i32, prev: ^i32) {
	_tw_field(buf, field_id, _PQ_TW_I32, prev)
	_tw_i32(buf, v)
}

@(private = "file")
_tw_field_i64 :: proc(buf: ^[dynamic]u8, field_id: i32, v: i64, prev: ^i32) {
	_tw_field(buf, field_id, _PQ_TW_I64, prev)
	_tw_i64(buf, v)
}

@(private = "file")
_tw_field_string :: proc(buf: ^[dynamic]u8, field_id: i32, s: string, prev: ^i32) {
	_tw_field(buf, field_id, _PQ_TW_BINARY, prev)
	_tw_varint(buf, u64(len(s)))
	append(buf, ..transmute([]u8)s)
}

@(private = "file")
_tw_field_list_begin :: proc(
	buf: ^[dynamic]u8,
	field_id: i32,
	elem_type: u8,
	count: int,
	prev: ^i32,
) {
	_tw_field(buf, field_id, _PQ_TW_LIST, prev)
	if count < 15 {
		append(buf, u8(count) << 4 | elem_type)
	} else {
		append(buf, 0xF0 | elem_type)
		_tw_varint(buf, u64(count))
	}
}

@(private = "file")
_tw_stop :: proc(buf: ^[dynamic]u8) {
	append(buf, u8(0))
}

@(private = "file")
_append_u32_le :: proc(buf: ^[dynamic]u8, v: u32) {
	b := [4]u8{u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)}
	append(buf, ..b[:])
}

@(private = "file")
_append_u64_le :: proc(buf: ^[dynamic]u8, v: u64) {
	b := [8]u8 {
		u8(v),
		u8(v >> 8),
		u8(v >> 16),
		u8(v >> 24),
		u8(v >> 32),
		u8(v >> 40),
		u8(v >> 48),
		u8(v >> 56),
	}
	append(buf, ..b[:])
}

@(private = "file")
_pq_record_str :: proc(r: ^Pooled_Record, idx: int) -> string {
	switch idx {
	case 0:
		return r.commit
	case 1:
		return r.lang
	case 2:
		return r.suite_name
	case 3:
		return r.group_name
	case 4:
		return r.name
	case 5:
		return r.full_name
	}
	return ""
}

@(private = "file")
_pq_record_i64 :: proc(r: ^Pooled_Record, idx: int) -> i64 {
	switch idx {
	case 0:
		return i64(r.rank)
	case 1:
		return i64(r.run_count)
	case 2:
		return i64(r.samples)
	case 3:
		return r.peak_heap_bytes
	}
	return 0
}

@(private = "file")
_pq_record_u64 :: proc(r: ^Pooled_Record, idx: int) -> u64 {
	switch idx {
	case 0:
		return r.ops_per_sample
	case 1:
		return r.bytes_per_op
	case 2:
		return r.footprint_bytes
	}
	return 0
}

@(private = "file")
_pq_record_f64 :: proc(r: ^Pooled_Record, idx: int) -> f64 {
	switch idx {
	case 0:
		return r.min_ns
	case 1:
		return r.p25_ns
	case 2:
		return r.p50_ns
	case 3:
		return r.p75_ns
	case 4:
		return r.p95_ns
	case 5:
		return r.p99_ns
	case 6:
		return r.max_ns
	case 7:
		return r.mean_ns
	case 8:
		return r.std_dev_ns
	case 9:
		return r.ci95_ns
	case 10:
		return r.cv_pct
	case 11:
		return r.iqr_ns
	case 12:
		return r.mad_ns
	case 13:
		return r.ops_per_sec
	case 14:
		return r.mb_per_sec
	case 15:
		return r.allocs_per_op
	case 16:
		return r.alloc_bytes_per_op
	case 17:
		return r.temp_allocs_per_op
	case 18:
		return r.temp_bytes_per_op
	}
	return 0
}

@(private = "file")
_pq_gzip_compress :: proc(raw: []u8, dst: ^[dynamic]u8) -> bool {
	clear(dst)
	strm: zlib.z_stream
	if zlib.deflateInit2(
		   &strm,
		   zlib.BEST_COMPRESSION,
		   zlib.DEFLATED,
		   15 + 16,
		   8,
		   zlib.DEFAULT_STRATEGY,
	   ) !=
	   zlib.OK {
		return false
	}
	defer _ = zlib.deflateEnd(&strm)

	bound := int(zlib.deflateBound(&strm, zlib.uLong(len(raw)))) + 32
	resize(dst, bound)

	dummy: u8
	if len(raw) > 0 {
		strm.next_in = raw_data(raw)
		strm.avail_in = zlib.uInt(len(raw))
	} else {
		strm.next_in = &dummy
		strm.avail_in = 0
	}
	strm.next_out = raw_data(dst^)
	strm.avail_out = zlib.uInt(len(dst^))

	rc := zlib.deflate(&strm, zlib.FINISH)
	if rc != zlib.STREAM_END || strm.avail_in != 0 {
		return false
	}
	resize(dst, int(strm.total_out))
	return true
}

@(private = "file")
_PQ_Col_Chunk :: struct {
	data_page_off: i64,
	uncomp_size:   i64,
	comp_size:     i64,
	num_values:    i64,
}

/*
Exports pooled benchmark records to a self-contained Apache Parquet file (V1 DataPages,
PLAIN encoding, optional RFC 1952 GZIP page compression) using pure Odin + `vendor:zlib`.
*/
@(require_results)
export_parquet :: proc(
	path: string,
	records: []Pooled_Record,
	codec := Codec.Zlib_BSS,
	compress_pages := true,
	allocator := context.allocator,
) -> bool {
	_ensure_export_parent_dir(path)

	file_buf := make([dynamic]u8, 0, 16384, allocator)
	defer delete(file_buf)

	append(&file_buf, 'P', 'A', 'R', '1')

	col_chunks: [len(_pq_column_specs)]_PQ_Col_Chunk
	rg_total_uncomp := i64(0)
	pq_codec := _PQ_CODEC_GZIP if compress_pages else _PQ_CODEC_UNCOMPRESSED

	if len(records) > 0 {
		page_raw := make([dynamic]u8, 0, max(len(records) * 32, 256), allocator)
		defer delete(page_raw)
		page_gz := make([dynamic]u8, 0, max(len(records) * 32, 256), allocator)
		defer delete(page_gz)
		page_hdr := make([dynamic]u8, 0, 64, allocator)
		defer delete(page_hdr)

		for ci in 0 ..< len(_pq_column_specs) {
			spec := _pq_column_specs[ci]
			clear(&page_raw)

			for ri in 0 ..< len(records) {
				r := &records[ri]
				switch spec.kind {
				case .String:
					s := _pq_record_str(r, spec.str_field)
					_append_u32_le(&page_raw, u32(len(s)))
					append(&page_raw, ..transmute([]u8)s)
				case .I64:
					_append_u64_le(&page_raw, u64(_pq_record_i64(r, spec.i64_field)))
				case .U64:
					_append_u64_le(&page_raw, _pq_record_u64(r, spec.u64_field))
				case .F64:
					_append_u64_le(&page_raw, transmute(u64)_pq_record_f64(r, spec.f64_field))
				case .Samples_Blob:
					blob, comp_ok := compress_samples_f64(r.samples_ns[:], codec, allocator)
					if !comp_ok {
						delete(blob, allocator)
						return false
					}
					_append_u32_le(&page_raw, u32(len(blob)))
					append(&page_raw, ..blob)
					delete(blob, allocator)
				}
			}

			if len(page_raw) > int(max(i32)) {
				return false
			}
			uncomp_payload_len := i32(len(page_raw))
			payload := page_raw[:]
			if compress_pages {
				if !_pq_gzip_compress(page_raw[:], &page_gz) {
					return false
				}
				payload = page_gz[:]
			}
			if len(payload) > int(max(i32)) {
				return false
			}
			comp_payload_len := i32(len(payload))

			clear(&page_hdr)
			prev: i32
			_tw_field_i32(&page_hdr, 1, 0, &prev) // DATA_PAGE (0)
			_tw_field_i32(&page_hdr, 2, uncomp_payload_len, &prev)
			_tw_field_i32(&page_hdr, 3, comp_payload_len, &prev)
			_tw_field(&page_hdr, 5, _PQ_TW_STRUCT, &prev) // data_page_header
			{
				p2: i32
				_tw_field_i32(&page_hdr, 1, i32(len(records)), &p2) // num_values
				_tw_field_i32(&page_hdr, 2, 0, &p2) // PLAIN
				_tw_field_i32(&page_hdr, 3, 3, &p2) // RLE def_level
				_tw_field_i32(&page_hdr, 4, 3, &p2) // RLE rep_level
				_tw_stop(&page_hdr)
			}
			_tw_stop(&page_hdr)

			chunk_off := i64(len(file_buf))
			append(&file_buf, ..page_hdr[:])
			append(&file_buf, ..payload)

			uncomp_total := i64(len(page_hdr)) + i64(uncomp_payload_len)
			comp_total := i64(len(page_hdr)) + i64(comp_payload_len)
			col_chunks[ci] = _PQ_Col_Chunk {
				data_page_off = chunk_off,
				uncomp_size   = uncomp_total,
				comp_size     = comp_total,
				num_values    = i64(len(records)),
			}
			rg_total_uncomp += uncomp_total
		}
	}

	footer := make([dynamic]u8, 0, 2048, allocator)
	defer delete(footer)

	fprev: i32
	_tw_field_i32(&footer, 1, 1, &fprev) // Parquet format version 1

	// Field 2: schema list<SchemaElement> (root + 33 leaves)
	_tw_field_list_begin(&footer, 2, _PQ_TW_STRUCT, len(_pq_column_specs) + 1, &fprev)
	{
		sp: i32
		_tw_field_string(&footer, 4, "schema", &sp)
		_tw_field_i32(&footer, 5, i32(len(_pq_column_specs)), &sp)
		_tw_stop(&footer)
	}
	for spec in _pq_column_specs {
		sp: i32
		_tw_field_i32(&footer, 1, spec.ptype, &sp)
		_tw_field_i32(&footer, 3, _PQ_REP_REQUIRED, &sp)
		_tw_field_string(&footer, 4, spec.name, &sp)
		if spec.ctype != _PQ_CTYPE_NONE {
			_tw_field_i32(&footer, 6, spec.ctype, &sp)
		}
		_tw_stop(&footer)
	}

	// Field 3: num_rows
	_tw_field_i64(&footer, 3, i64(len(records)), &fprev)

	// Field 4: row_groups
	rg_count := 1 if len(records) > 0 else 0
	_tw_field_list_begin(&footer, 4, _PQ_TW_STRUCT, rg_count, &fprev)
	if rg_count > 0 {
		rprev: i32
		_tw_field_list_begin(&footer, 1, _PQ_TW_STRUCT, len(_pq_column_specs), &rprev)
		for ci in 0 ..< len(_pq_column_specs) {
			spec := _pq_column_specs[ci]
			cm := col_chunks[ci]
			cc_prev: i32
			_tw_field_i64(&footer, 2, cm.data_page_off, &cc_prev) // file_offset
			_tw_field(&footer, 3, _PQ_TW_STRUCT, &cc_prev) // meta_data
			{
				cm_prev: i32
				_tw_field_i32(&footer, 1, spec.ptype, &cm_prev)
				_tw_field_list_begin(&footer, 2, _PQ_TW_I32, 1, &cm_prev)
				_tw_i32(&footer, 0) // PLAIN
				_tw_field_list_begin(&footer, 3, _PQ_TW_BINARY, 1, &cm_prev)
				_tw_varint(&footer, u64(len(spec.name)))
				append(&footer, ..transmute([]u8)spec.name)
				_tw_field_i32(&footer, 4, pq_codec, &cm_prev)
				_tw_field_i64(&footer, 5, cm.num_values, &cm_prev)
				_tw_field_i64(&footer, 6, cm.uncomp_size, &cm_prev)
				_tw_field_i64(&footer, 7, cm.comp_size, &cm_prev)
				_tw_field_i64(&footer, 9, cm.data_page_off, &cm_prev)
				_tw_stop(&footer)
			}
			_tw_stop(&footer)
		}
		_tw_field_i64(&footer, 2, rg_total_uncomp, &rprev)
		_tw_field_i64(&footer, 3, i64(len(records)), &rprev)
		_tw_stop(&footer)
	}

	// Field 6: created_by
	_tw_field_string(&footer, 6, "hugi", &fprev)
	_tw_stop(&footer)

	if len(footer) > int(max(i32)) {
		return false
	}
	append(&file_buf, ..footer[:])
	_append_u32_le(&file_buf, u32(len(footer)))
	append(&file_buf, 'P', 'A', 'R', '1')

	return os.write_entire_file(path, file_buf[:]) == nil
}
