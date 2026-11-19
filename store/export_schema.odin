package hugi_store

EXPORT_SCALAR_COL_COUNT :: 34
EXPORT_TOTAL_COL_COUNT :: 35

Export_Col_Id :: enum u8 {
	Commit = 0,
	Lang,
	Suite_Name,
	Group_Name,
	Name,
	Full_Name,
	Run_Id,
	Timestamp_Unix,
	Rank,
	Run_Count,
	Ops_Per_Sample,
	Samples,
	Min_Ns,
	P25_Ns,
	P50_Ns,
	P75_Ns,
	P95_Ns,
	P99_Ns,
	Max_Ns,
	Mean_Ns,
	Std_Dev_Ns,
	Ci95_Ns,
	Cv_Pct,
	Iqr_Ns,
	Mad_Ns,
	Ops_Per_Sec,
	Mb_Per_Sec,
	Bytes_Per_Op,
	Footprint_Bytes,
	Allocs_Per_Op,
	Alloc_Bytes_Per_Op,
	Temp_Allocs_Per_Op,
	Temp_Bytes_Per_Op,
	Peak_Heap_Bytes,
	Samples_Blob,
}

Export_Col_Kind :: enum u8 {
	String,
	I64,
	Decimal_FS,
	U64,
	F64,
	Samples_Blob,
}

Export_Col_Spec :: struct {
	id:      Export_Col_Id,
	name:    string,
	kind:    Export_Col_Kind,
	f64_fmt: string,
}

@(rodata)
EXPORT_COLUMNS := [EXPORT_TOTAL_COL_COUNT]Export_Col_Spec {
	{id = .Commit, name = "commit", kind = .String},
	{id = .Lang, name = "lang", kind = .String},
	{id = .Suite_Name, name = "suite_name", kind = .String},
	{id = .Group_Name, name = "group_name", kind = .String},
	{id = .Name, name = "name", kind = .String},
	{id = .Full_Name, name = "full_name", kind = .String},
	{id = .Run_Id, name = "run_id", kind = .String},
	{id = .Timestamp_Unix, name = "timestamp_unix", kind = .I64},
	{id = .Rank, name = "rank", kind = .I64},
	{id = .Run_Count, name = "run_count", kind = .I64},
	{id = .Ops_Per_Sample, name = "ops_per_sample", kind = .U64},
	{id = .Samples, name = "samples", kind = .I64},
	{id = .Min_Ns, name = "min_ns", kind = .Decimal_FS},
	{id = .P25_Ns, name = "p25_ns", kind = .Decimal_FS},
	{id = .P50_Ns, name = "p50_ns", kind = .Decimal_FS},
	{id = .P75_Ns, name = "p75_ns", kind = .Decimal_FS},
	{id = .P95_Ns, name = "p95_ns", kind = .Decimal_FS},
	{id = .P99_Ns, name = "p99_ns", kind = .Decimal_FS},
	{id = .Max_Ns, name = "max_ns", kind = .Decimal_FS},
	{id = .Mean_Ns, name = "mean_ns", kind = .Decimal_FS},
	{id = .Std_Dev_Ns, name = "std_dev_ns", kind = .Decimal_FS},
	{id = .Ci95_Ns, name = "ci95_ns", kind = .Decimal_FS},
	{id = .Cv_Pct, name = "cv_pct", kind = .F64, f64_fmt = "%.4f"},
	{id = .Iqr_Ns, name = "iqr_ns", kind = .Decimal_FS},
	{id = .Mad_Ns, name = "mad_ns", kind = .Decimal_FS},
	{id = .Ops_Per_Sec, name = "ops_per_sec", kind = .F64, f64_fmt = "%.3f"},
	{id = .Mb_Per_Sec, name = "mb_per_sec", kind = .F64, f64_fmt = "%.4f"},
	{id = .Bytes_Per_Op, name = "bytes_per_op", kind = .U64},
	{id = .Footprint_Bytes, name = "footprint_bytes", kind = .U64},
	{id = .Allocs_Per_Op, name = "allocs_per_op", kind = .F64, f64_fmt = "%.4f"},
	{id = .Alloc_Bytes_Per_Op, name = "alloc_bytes_per_op", kind = .F64, f64_fmt = "%.2f"},
	{id = .Temp_Allocs_Per_Op, name = "temp_allocs_per_op", kind = .F64, f64_fmt = "%.4f"},
	{id = .Temp_Bytes_Per_Op, name = "temp_bytes_per_op", kind = .F64, f64_fmt = "%.2f"},
	{id = .Peak_Heap_Bytes, name = "peak_heap_bytes", kind = .I64},
	{id = .Samples_Blob, name = "samples_blob", kind = .Samples_Blob},
}

#assert(len(Export_Col_Id) == EXPORT_TOTAL_COL_COUNT)
#assert(len(EXPORT_COLUMNS) == EXPORT_TOTAL_COL_COUNT)

@(private)
_primary_run_id :: proc(r: ^Pooled_Record) -> string {
	return len(r.run_ids) > 0 ? r.run_ids[len(r.run_ids) - 1] : ""
}

@(private)
_export_col_str :: proc(r: ^Pooled_Record, id: Export_Col_Id) -> string {
	#partial switch id {
	case .Commit:
		return r.commit
	case .Lang:
		return r.lang
	case .Suite_Name:
		return r.suite_name
	case .Group_Name:
		return r.group_name
	case .Name:
		return r.name
	case .Full_Name:
		return r.full_name
	case .Run_Id:
		return _primary_run_id(r)
	}
	return ""
}

@(private)
_export_col_i64 :: proc(r: ^Pooled_Record, id: Export_Col_Id) -> i64 {
	#partial switch id {
	case .Timestamp_Unix:
		return r.timestamp_unix
	case .Rank:
		return i64(r.rank)
	case .Run_Count:
		return i64(r.run_count)
	case .Samples:
		return i64(r.samples)
	case .Min_Ns:
		return r.min_fs
	case .P25_Ns:
		return r.p25_fs
	case .P50_Ns:
		return r.p50_fs
	case .P75_Ns:
		return r.p75_fs
	case .P95_Ns:
		return r.p95_fs
	case .P99_Ns:
		return r.p99_fs
	case .Max_Ns:
		return r.max_fs
	case .Mean_Ns:
		return r.mean_fs
	case .Std_Dev_Ns:
		return r.std_dev_fs
	case .Ci95_Ns:
		return r.ci95_fs
	case .Iqr_Ns:
		return r.iqr_fs
	case .Mad_Ns:
		return r.mad_fs
	case .Peak_Heap_Bytes:
		return r.peak_heap_bytes
	}
	return 0
}

@(private)
_export_col_u64 :: proc(r: ^Pooled_Record, id: Export_Col_Id) -> u64 {
	#partial switch id {
	case .Ops_Per_Sample:
		return r.ops_per_sample
	case .Bytes_Per_Op:
		return r.bytes_per_op
	case .Footprint_Bytes:
		return r.footprint_bytes
	}
	return 0
}

@(private)
_export_col_f64 :: proc(r: ^Pooled_Record, id: Export_Col_Id) -> f64 {
	#partial switch id {
	case .Cv_Pct:
		return r.cv_pct
	case .Ops_Per_Sec:
		return r.ops_per_sec
	case .Mb_Per_Sec:
		return r.mb_per_sec
	case .Allocs_Per_Op:
		return r.allocs_per_op
	case .Alloc_Bytes_Per_Op:
		return r.alloc_bytes_per_op
	case .Temp_Allocs_Per_Op:
		return r.temp_allocs_per_op
	case .Temp_Bytes_Per_Op:
		return r.temp_bytes_per_op
	}
	return 0
}

@(private, require_results)
_compress_pooled_samples_blob :: proc(
	r: ^Pooled_Record,
	allocator := context.temp_allocator,
) -> (
	blob: []u8,
	ok: bool,
) {
	if len(r.samples_batch_ns) == len(r.samples_fs) && len(r.samples_batch_ns) > 0 {
		return compress_samples_u64(r.samples_batch_ns[:], allocator)
	}
	return compress_samples_fs_i64(r.samples_fs[:], allocator)
}
