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
_PQ_CTYPE_DECIMAL :: i32(5)
@(private = "file")
_PQ_CTYPE_UINT64 :: i32(14)

@(private = "file")
_PQ_DECIMAL_SCALE :: i32(6)
@(private = "file")
_PQ_DECIMAL_PRECISION :: i32(18)

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
_pq_phys_type :: proc "contextless" (kind: Export_Col_Kind) -> i32 {
	switch kind {
	case .String, .Samples_Blob:
		return _PQ_TYPE_BYTE_ARRAY
	case .I64, .Decimal_FS, .U64:
		return _PQ_TYPE_INT64
	case .F64:
		return _PQ_TYPE_DOUBLE
	}
	return _PQ_TYPE_BYTE_ARRAY
}

@(private = "file")
_pq_converted_type :: proc "contextless" (kind: Export_Col_Kind) -> i32 {
	switch kind {
	case .String:
		return _PQ_CTYPE_UTF8
	case .Decimal_FS:
		return _PQ_CTYPE_DECIMAL
	case .U64:
		return _PQ_CTYPE_UINT64
	case .I64, .F64, .Samples_Blob:
		return _PQ_CTYPE_NONE
	}
	return _PQ_CTYPE_NONE
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
	compress_pages := true,
	allocator := context.allocator,
) -> bool {
	_ensure_parent_dir(path)

	file_buf := make([dynamic]u8, 0, 16384, allocator)
	defer delete(file_buf)

	append(&file_buf, 'P', 'A', 'R', '1')

	col_chunks: [EXPORT_TOTAL_COL_COUNT]_PQ_Col_Chunk
	rg_total_uncomp := i64(0)
	pq_codec := _PQ_CODEC_GZIP if compress_pages else _PQ_CODEC_UNCOMPRESSED

	if len(records) > 0 {
		page_raw := make([dynamic]u8, 0, max(len(records) * 32, 256), allocator)
		defer delete(page_raw)
		page_gz := make([dynamic]u8, 0, max(len(records) * 32, 256), allocator)
		defer delete(page_gz)
		page_hdr := make([dynamic]u8, 0, 64, allocator)
		defer delete(page_hdr)

		for spec, ci in EXPORT_COLUMNS {
			clear(&page_raw)

			for ri in 0 ..< len(records) {
				r := &records[ri]
				switch spec.kind {
				case .String:
					s := _export_col_str(r, spec.id)
					_fmt_append_u32_le(&page_raw, u32(len(s)))
					append(&page_raw, ..transmute([]u8)s)
				case .I64, .Decimal_FS:
					_fmt_append_u64_le(&page_raw, u64(_export_col_i64(r, spec.id)))
				case .U64:
					_fmt_append_u64_le(&page_raw, _export_col_u64(r, spec.id))
				case .F64:
					_fmt_append_u64_le(&page_raw, transmute(u64)_export_col_f64(r, spec.id))
				case .Samples_Blob:
					blob, comp_ok := _compress_pooled_samples_blob(r, allocator)
					if !comp_ok {
						delete(blob, allocator)
						return false
					}
					_fmt_append_u32_le(&page_raw, u32(len(blob)))
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

	// Field 2: schema list<SchemaElement> (root + 35 leaves)
	_tw_field_list_begin(&footer, 2, _PQ_TW_STRUCT, len(EXPORT_COLUMNS) + 1, &fprev)
	{
		sp: i32
		_tw_field_string(&footer, 4, "schema", &sp)
		_tw_field_i32(&footer, 5, i32(len(EXPORT_COLUMNS)), &sp)
		_tw_stop(&footer)
	}
	for spec in EXPORT_COLUMNS {
		ptype := _pq_phys_type(spec.kind)
		ctype := _pq_converted_type(spec.kind)
		sp: i32
		_tw_field_i32(&footer, 1, ptype, &sp)
		_tw_field_i32(&footer, 3, _PQ_REP_REQUIRED, &sp)
		_tw_field_string(&footer, 4, spec.name, &sp)
		if ctype != _PQ_CTYPE_NONE {
			_tw_field_i32(&footer, 6, ctype, &sp)
			if ctype == _PQ_CTYPE_DECIMAL {
				_tw_field_i32(&footer, 7, _PQ_DECIMAL_SCALE, &sp)
				_tw_field_i32(&footer, 8, _PQ_DECIMAL_PRECISION, &sp)
			}
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
		_tw_field_list_begin(&footer, 1, _PQ_TW_STRUCT, len(EXPORT_COLUMNS), &rprev)
		for spec, ci in EXPORT_COLUMNS {
			cm := col_chunks[ci]
			ptype := _pq_phys_type(spec.kind)
			cc_prev: i32
			_tw_field_i64(&footer, 2, cm.data_page_off, &cc_prev) // file_offset
			_tw_field(&footer, 3, _PQ_TW_STRUCT, &cc_prev) // meta_data
			{
				cm_prev: i32
				_tw_field_i32(&footer, 1, ptype, &cm_prev)
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
	_fmt_append_u32_le(&file_buf, u32(len(footer)))
	append(&file_buf, 'P', 'A', 'R', '1')

	return os.write_entire_file(path, file_buf[:]) == nil
}
