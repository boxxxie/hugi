package hugi_store

import skadi "../deps/skadi/skadi"
import "core:mem"

/*
Exports pooled benchmark records to an Apache Arrow IPC (Feather v2) file via `skadi`,
encoding duration quantiles/statistics as native `Decimal64(18, 6)` nanoseconds and
embedding lossless compressed `samples_blob` arrays alongside optional `LZ4_Frame` IPC body compression.
*/
@(require_results)
export_arrow_ipc :: proc(
	path: string,
	records: []Pooled_Record,
	ipc_compression := skadi.IPC_Compression.LZ4_Frame,
	allocator := context.allocator,
) -> bool {
	_ensure_parent_dir(path)

	dec_ns := skadi.Decimal64_Type {
		precision = 18,
		scale     = 6,
	}
	fields: [EXPORT_TOTAL_COL_COUNT]skadi.Field
	for spec, ci in EXPORT_COLUMNS {
		dt: skadi.DataType
		switch spec.kind {
		case .String:
			dt = skadi.String_Type{}
		case .I64:
			dt = skadi.Int64_Type{}
		case .Decimal_FS:
			dt = dec_ns
		case .U64:
			dt = skadi.UInt64_Type{}
		case .F64:
			dt = skadi.Float64_Type{}
		case .Samples_Blob:
			dt = skadi.Binary_Type{}
		}
		fields[ci] = skadi.field_make(spec.name, dt, false)
	}

	schema, schema_err := skadi.schema_make(fields[:], allocator)
	if schema_err != nil {
		return false
	}
	defer skadi.schema_free(&schema)

	cap_n := max(len(records), 1)
	cols: [EXPORT_TOTAL_COL_COUNT]skadi.Array
	finished := 0
	rb_created := false
	defer if !rb_created {
		for i in 0 ..< finished {
			skadi.array_free(&cols[i], allocator)
		}
	}

	for spec, ci in EXPORT_COLUMNS {
		finish_err: mem.Allocator_Error
		switch spec.kind {
		case .String:
			b := skadi.string_builder_make(cap_n, allocator)
			defer skadi.string_builder_destroy(&b)
			for &r in records {
				skadi.string_builder_append(&b, _export_col_str(&r, spec.id))
			}
			cols[ci], finish_err = skadi.string_builder_finish(&b, allocator)
		case .I64, .Decimal_FS:
			b := skadi.builder_make(i64, cap_n, allocator)
			defer skadi.builder_destroy(&b)
			for &r in records {
				skadi.builder_append(&b, _export_col_i64(&r, spec.id))
			}
			if spec.kind == .Decimal_FS {
				cols[ci], finish_err = skadi.builder_finish_as(&b, dec_ns, allocator)
			} else {
				cols[ci], finish_err = skadi.builder_finish(&b, allocator)
			}
		case .U64:
			b := skadi.builder_make(u64, cap_n, allocator)
			defer skadi.builder_destroy(&b)
			for &r in records {
				skadi.builder_append(&b, _export_col_u64(&r, spec.id))
			}
			cols[ci], finish_err = skadi.builder_finish(&b, allocator)
		case .F64:
			b := skadi.builder_make(f64, cap_n, allocator)
			defer skadi.builder_destroy(&b)
			for &r in records {
				skadi.builder_append(&b, _export_col_f64(&r, spec.id))
			}
			cols[ci], finish_err = skadi.builder_finish(&b, allocator)
		case .Samples_Blob:
			b := skadi.binary_builder_make(cap_n, allocator)
			defer skadi.binary_builder_destroy(&b)
			for &r in records {
				blob, comp_ok := _compress_pooled_samples_blob(&r, context.temp_allocator)
				if !comp_ok {
					delete(blob, context.temp_allocator)
					return false
				}
				skadi.binary_builder_append(&b, blob)
				delete(blob, context.temp_allocator)
			}
			cols[ci], finish_err = skadi.binary_builder_finish(&b, allocator)
		}
		if finish_err != nil {
			return false
		}
		finished += 1
	}

	rb, rb_ok := skadi.record_batch_make(&schema, cols[:], allocator)
	if !rb_ok {
		return false
	}
	rb_created = true
	defer skadi.record_batch_free(&rb)

	batches := [1]skadi.Record_Batch{rb}
	return skadi.ipc_write_file(path, &schema, batches[:], ipc_compression)
}
