package hugi_store

import obench "../deps/obench/obench"
import skadi "../deps/skadi/skadi"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

@(private = "file")
_ensure_export_parent_dir :: proc(path: string) {
	dir := filepath.dir(path)
	if dir == "" || dir == "." || dir == "/" || os.exists(dir) {
		return
	}
	_ensure_export_parent_dir(dir)
	_ = os.make_directory(dir)
}

@(private = "file")
_write_json_str :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for i := 0; i < len(s); i += 1 {
		b := s[i]
		switch b {
		case '"':
			strings.write_string(sb, `\"`)
		case '\\':
			strings.write_string(sb, `\\`)
		case '\b':
			strings.write_string(sb, `\b`)
		case '\f':
			strings.write_string(sb, `\f`)
		case '\n':
			strings.write_string(sb, `\n`)
		case '\r':
			strings.write_string(sb, `\r`)
		case '\t':
			strings.write_string(sb, `\t`)
		case:
			if b < 0x20 {
				fmt.sbprintf(sb, `\u%04x`, int(b))
			} else {
				strings.write_byte(sb, b)
			}
		}
	}
	strings.write_byte(sb, '"')
}

@(private = "file")
_write_csv_str :: proc(sb: ^strings.Builder, s: string) {
	needs_quote := strings.contains_any(s, ",\"\n\r")
	if !needs_quote {
		strings.write_string(sb, s)
		return
	}
	strings.write_byte(sb, '"')
	for i := 0; i < len(s); i += 1 {
		b := s[i]
		if b == '"' {
			strings.write_string(sb, `""`)
		} else {
			strings.write_byte(sb, b)
		}
	}
	strings.write_byte(sb, '"')
}

/*
Exports pooled benchmark records to an Apache Arrow IPC (Feather v2) file via `skadi`,
including lossless `Codec.Zlib_BSS` or `Codec.LZ4_BSS` compressed `samples_blob` columns.
*/
@(require_results)
export_arrow_ipc :: proc(
	path: string,
	records: []Pooled_Record,
	codec := Codec.Zlib_BSS,
	allocator := context.allocator,
) -> bool {
	_ensure_export_parent_dir(path)

	fields := [33]skadi.Field {
		skadi.field_make("commit", skadi.String_Type{}, false),
		skadi.field_make("lang", skadi.String_Type{}, false),
		skadi.field_make("suite_name", skadi.String_Type{}, false),
		skadi.field_make("group_name", skadi.String_Type{}, false),
		skadi.field_make("name", skadi.String_Type{}, false),
		skadi.field_make("full_name", skadi.String_Type{}, false),
		skadi.field_make("rank", skadi.Int64_Type{}, false),
		skadi.field_make("run_count", skadi.Int64_Type{}, false),
		skadi.field_make("ops_per_sample", skadi.UInt64_Type{}, false),
		skadi.field_make("samples", skadi.Int64_Type{}, false),
		skadi.field_make("min_ns", skadi.Float64_Type{}, false),
		skadi.field_make("p25_ns", skadi.Float64_Type{}, false),
		skadi.field_make("p50_ns", skadi.Float64_Type{}, false),
		skadi.field_make("p75_ns", skadi.Float64_Type{}, false),
		skadi.field_make("p95_ns", skadi.Float64_Type{}, false),
		skadi.field_make("p99_ns", skadi.Float64_Type{}, false),
		skadi.field_make("max_ns", skadi.Float64_Type{}, false),
		skadi.field_make("mean_ns", skadi.Float64_Type{}, false),
		skadi.field_make("std_dev_ns", skadi.Float64_Type{}, false),
		skadi.field_make("ci95_ns", skadi.Float64_Type{}, false),
		skadi.field_make("cv_pct", skadi.Float64_Type{}, false),
		skadi.field_make("iqr_ns", skadi.Float64_Type{}, false),
		skadi.field_make("mad_ns", skadi.Float64_Type{}, false),
		skadi.field_make("ops_per_sec", skadi.Float64_Type{}, false),
		skadi.field_make("mb_per_sec", skadi.Float64_Type{}, false),
		skadi.field_make("bytes_per_op", skadi.UInt64_Type{}, false),
		skadi.field_make("footprint_bytes", skadi.UInt64_Type{}, false),
		skadi.field_make("allocs_per_op", skadi.Float64_Type{}, false),
		skadi.field_make("alloc_bytes_per_op", skadi.Float64_Type{}, false),
		skadi.field_make("temp_allocs_per_op", skadi.Float64_Type{}, false),
		skadi.field_make("temp_bytes_per_op", skadi.Float64_Type{}, false),
		skadi.field_make("peak_heap_bytes", skadi.Int64_Type{}, false),
		skadi.field_make("samples_blob", skadi.Binary_Type{}, false),
	}

	schema, schema_err := skadi.schema_make(fields[:], allocator)
	if schema_err != nil {
		return false
	}
	defer skadi.schema_free(&schema)

	cap_n := max(len(records), 1)
	b_commit := skadi.string_builder_make(cap_n, allocator)
	defer skadi.string_builder_destroy(&b_commit)
	b_lang := skadi.string_builder_make(cap_n, allocator)
	defer skadi.string_builder_destroy(&b_lang)
	b_suite := skadi.string_builder_make(cap_n, allocator)
	defer skadi.string_builder_destroy(&b_suite)
	b_group := skadi.string_builder_make(cap_n, allocator)
	defer skadi.string_builder_destroy(&b_group)
	b_name := skadi.string_builder_make(cap_n, allocator)
	defer skadi.string_builder_destroy(&b_name)
	b_full := skadi.string_builder_make(cap_n, allocator)
	defer skadi.string_builder_destroy(&b_full)

	b_rank := skadi.builder_make(i64, cap_n, allocator)
	defer skadi.builder_destroy(&b_rank)
	b_run_count := skadi.builder_make(i64, cap_n, allocator)
	defer skadi.builder_destroy(&b_run_count)
	b_ops_per_sample := skadi.builder_make(u64, cap_n, allocator)
	defer skadi.builder_destroy(&b_ops_per_sample)
	b_samples := skadi.builder_make(i64, cap_n, allocator)
	defer skadi.builder_destroy(&b_samples)

	b_min := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_min)
	b_p25 := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_p25)
	b_p50 := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_p50)
	b_p75 := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_p75)
	b_p95 := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_p95)
	b_p99 := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_p99)
	b_max := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_max)
	b_mean := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_mean)
	b_std := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_std)
	b_ci95 := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_ci95)
	b_cv := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_cv)
	b_iqr := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_iqr)
	b_mad := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_mad)
	b_ops_sec := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_ops_sec)
	b_mb_sec := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_mb_sec)

	b_bytes_op := skadi.builder_make(u64, cap_n, allocator)
	defer skadi.builder_destroy(&b_bytes_op)
	b_footprint := skadi.builder_make(u64, cap_n, allocator)
	defer skadi.builder_destroy(&b_footprint)

	b_allocs := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_allocs)
	b_alloc_bytes := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_alloc_bytes)
	b_temp_allocs := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_temp_allocs)
	b_temp_bytes := skadi.builder_make(f64, cap_n, allocator)
	defer skadi.builder_destroy(&b_temp_bytes)

	b_peak_heap := skadi.builder_make(i64, cap_n, allocator)
	defer skadi.builder_destroy(&b_peak_heap)

	b_samples_blob := skadi.binary_builder_make(cap_n, allocator)
	defer skadi.binary_builder_destroy(&b_samples_blob)

	for r in records {
		skadi.string_builder_append(&b_commit, r.commit)
		skadi.string_builder_append(&b_lang, r.lang)
		skadi.string_builder_append(&b_suite, r.suite_name)
		skadi.string_builder_append(&b_group, r.group_name)
		skadi.string_builder_append(&b_name, r.name)
		skadi.string_builder_append(&b_full, r.full_name)

		skadi.builder_append(&b_rank, i64(r.rank))
		skadi.builder_append(&b_run_count, i64(r.run_count))
		skadi.builder_append(&b_ops_per_sample, r.ops_per_sample)
		skadi.builder_append(&b_samples, i64(r.samples))

		skadi.builder_append(&b_min, r.min_ns)
		skadi.builder_append(&b_p25, r.p25_ns)
		skadi.builder_append(&b_p50, r.p50_ns)
		skadi.builder_append(&b_p75, r.p75_ns)
		skadi.builder_append(&b_p95, r.p95_ns)
		skadi.builder_append(&b_p99, r.p99_ns)
		skadi.builder_append(&b_max, r.max_ns)
		skadi.builder_append(&b_mean, r.mean_ns)
		skadi.builder_append(&b_std, r.std_dev_ns)
		skadi.builder_append(&b_ci95, r.ci95_ns)
		skadi.builder_append(&b_cv, r.cv_pct)
		skadi.builder_append(&b_iqr, r.iqr_ns)
		skadi.builder_append(&b_mad, r.mad_ns)
		skadi.builder_append(&b_ops_sec, r.ops_per_sec)
		skadi.builder_append(&b_mb_sec, r.mb_per_sec)

		skadi.builder_append(&b_bytes_op, r.bytes_per_op)
		skadi.builder_append(&b_footprint, r.footprint_bytes)

		skadi.builder_append(&b_allocs, r.allocs_per_op)
		skadi.builder_append(&b_alloc_bytes, r.alloc_bytes_per_op)
		skadi.builder_append(&b_temp_allocs, r.temp_allocs_per_op)
		skadi.builder_append(&b_temp_bytes, r.temp_bytes_per_op)

		skadi.builder_append(&b_peak_heap, r.peak_heap_bytes)

		blob, comp_ok := compress_samples_f64(r.samples_ns[:], codec, context.temp_allocator)
		if !comp_ok {
			return false
		}
		skadi.binary_builder_append(&b_samples_blob, blob)
	}

	cols: [33]skadi.Array
	finished := 0
	free_partial_cols := proc(cols: []skadi.Array, count: int, allocator := context.allocator) {
		for i := 0; i < count; i += 1 {
			skadi.array_free(&cols[i], allocator)
		}
	}

	e: mem.Allocator_Error
	if cols[0], e = skadi.string_builder_finish(&b_commit, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[1], e = skadi.string_builder_finish(&b_lang, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[2], e = skadi.string_builder_finish(&b_suite, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[3], e = skadi.string_builder_finish(&b_group, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[4], e = skadi.string_builder_finish(&b_name, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[5], e = skadi.string_builder_finish(&b_full, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1

	if cols[6], e = skadi.builder_finish(&b_rank, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[7], e = skadi.builder_finish(&b_run_count, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[8], e = skadi.builder_finish(&b_ops_per_sample, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[9], e = skadi.builder_finish(&b_samples, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1

	if cols[10], e = skadi.builder_finish(&b_min, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[11], e = skadi.builder_finish(&b_p25, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[12], e = skadi.builder_finish(&b_p50, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[13], e = skadi.builder_finish(&b_p75, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[14], e = skadi.builder_finish(&b_p95, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[15], e = skadi.builder_finish(&b_p99, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[16], e = skadi.builder_finish(&b_max, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[17], e = skadi.builder_finish(&b_mean, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[18], e = skadi.builder_finish(&b_std, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[19], e = skadi.builder_finish(&b_ci95, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[20], e = skadi.builder_finish(&b_cv, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[21], e = skadi.builder_finish(&b_iqr, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[22], e = skadi.builder_finish(&b_mad, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[23], e = skadi.builder_finish(&b_ops_sec, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[24], e = skadi.builder_finish(&b_mb_sec, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1

	if cols[25], e = skadi.builder_finish(&b_bytes_op, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[26], e = skadi.builder_finish(&b_footprint, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1

	if cols[27], e = skadi.builder_finish(&b_allocs, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[28], e = skadi.builder_finish(&b_alloc_bytes, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[29], e = skadi.builder_finish(&b_temp_allocs, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[30], e = skadi.builder_finish(&b_temp_bytes, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1

	if cols[31], e = skadi.builder_finish(&b_peak_heap, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1
	if cols[32], e = skadi.binary_builder_finish(&b_samples_blob, allocator); e != nil {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	finished += 1

	rb, rb_ok := skadi.record_batch_make(&schema, cols[:], allocator)
	if !rb_ok {
		free_partial_cols(cols[:], finished, allocator)
		return false
	}
	defer skadi.record_batch_free(&rb)

	batches := [1]skadi.Record_Batch{rb}
	return skadi.ipc_write_file(path, &schema, batches[:])
}

/*
Exports pooled benchmark records to JSON Lines compatible with legacy `history.jsonl` tools.
*/
@(require_results)
export_jsonl :: proc(path: string, records: []Pooled_Record) -> bool {
	_ensure_export_parent_dir(path)

	sb := strings.builder_make(context.temp_allocator)
	for r in records {
		strings.write_string(&sb, `{"commit":`)
		_write_json_str(&sb, r.commit)
		strings.write_string(&sb, `,"lang":`)
		_write_json_str(&sb, r.lang)
		strings.write_string(&sb, `,"suite":`)
		_write_json_str(&sb, r.suite_name)
		strings.write_string(&sb, `,"group":`)
		_write_json_str(&sb, r.group_name)
		strings.write_string(&sb, `,"name":`)
		_write_json_str(&sb, r.name)
		strings.write_string(&sb, `,"full_name":`)
		_write_json_str(&sb, r.full_name)
		fmt.sbprintf(
			&sb,
			`,"rank":%d,"runs":%d,"samples":%d,"ops_per_sample":%d,"min_ns":%.6f,"p25_ns":%.6f,"p50_ns":%.6f,"p75_ns":%.6f,"p95_ns":%.6f,"p99_ns":%.6f,"max_ns":%.6f,"mean_ns":%.6f,"std_dev_ns":%.6f,"ci95_ns":%.6f,"cv_pct":%.4f,"ops_per_sec":%.3f,"bytes_per_op":%d,"mb_per_sec":%.4f,"footprint_bytes":%d,"allocs_per_op":%.4f,"alloc_bytes_per_op":%.2f,"samples_ns":[`,
			r.rank,
			r.run_count,
			r.samples,
			r.ops_per_sample,
			r.min_ns,
			r.p25_ns,
			r.p50_ns,
			r.p75_ns,
			r.p95_ns,
			r.p99_ns,
			r.max_ns,
			r.mean_ns,
			r.std_dev_ns,
			r.ci95_ns,
			r.cv_pct,
			r.ops_per_sec,
			r.bytes_per_op,
			r.mb_per_sec,
			r.footprint_bytes,
			r.allocs_per_op,
			r.alloc_bytes_per_op,
		)
		for s, idx in r.samples_ns {
			if idx > 0 {
				strings.write_byte(&sb, ',')
			}
			fmt.sbprintf(&sb, "%.3f", s)
		}
		strings.write_string(&sb, "]}\n")
	}

	return os.write_entire_file(path, transmute([]u8)strings.to_string(sb)) == nil
}

/*
Exports pooled benchmark records as an RFC 4180 CSV file.
*/
@(require_results)
export_csv :: proc(path: string, records: []Pooled_Record) -> bool {
	_ensure_export_parent_dir(path)

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&sb,
		"commit,lang,suite,group,name,full_name,rank,runs,samples,ops_per_sample,min_ns,p25_ns,p50_ns,p75_ns,p95_ns,p99_ns,max_ns,mean_ns,std_dev_ns,ci95_ns,cv_pct,ops_per_sec,bytes_per_op,mb_per_sec,footprint_bytes,allocs_per_op,alloc_bytes_per_op\n",
	)
	for r in records {
		_write_csv_str(&sb, r.commit)
		strings.write_byte(&sb, ',')
		_write_csv_str(&sb, r.lang)
		strings.write_byte(&sb, ',')
		_write_csv_str(&sb, r.suite_name)
		strings.write_byte(&sb, ',')
		_write_csv_str(&sb, r.group_name)
		strings.write_byte(&sb, ',')
		_write_csv_str(&sb, r.name)
		strings.write_byte(&sb, ',')
		_write_csv_str(&sb, r.full_name)
		fmt.sbprintf(
			&sb,
			",%d,%d,%d,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.4f,%.3f,%d,%.4f,%d,%.4f,%.2f\n",
			r.rank,
			r.run_count,
			r.samples,
			r.ops_per_sample,
			r.min_ns,
			r.p25_ns,
			r.p50_ns,
			r.p75_ns,
			r.p95_ns,
			r.p99_ns,
			r.max_ns,
			r.mean_ns,
			r.std_dev_ns,
			r.ci95_ns,
			r.cv_pct,
			r.ops_per_sec,
			r.bytes_per_op,
			r.mb_per_sec,
			r.footprint_bytes,
			r.allocs_per_op,
			r.alloc_bytes_per_op,
		)
	}

	return os.write_entire_file(path, transmute([]u8)strings.to_string(sb)) == nil
}

/*
Renders a GitHub-Flavored Markdown table summarizing pooled benchmark records.
*/
@(require_results)
format_markdown_table :: proc(records: []Pooled_Record, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(
		&sb,
		"| Benchmark | Runs | Samples | Median | P95 | Ops/s | CV% | Footprint | Allocs/op |\n",
	)
	strings.write_string(&sb, "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n")
	for r in records {
		med_str := obench.format_duration_ns(r.p50_ns, context.temp_allocator)
		p95_str := obench.format_duration_ns(r.p95_ns, context.temp_allocator)
		foot_str := "-"
		if r.footprint_bytes > 0 {
			foot_str = obench.format_bytes(f64(r.footprint_bytes), context.temp_allocator)
		}
		alloc_str := "0"
		if r.allocs_per_op > 0 || r.alloc_bytes_per_op > 0 {
			alloc_str = fmt.tprintf(
				"%.1f (%s)",
				r.allocs_per_op,
				obench.format_bytes(r.alloc_bytes_per_op, context.temp_allocator),
			)
		}
		fmt.sbprintf(
			&sb,
			"| `%s` | %d | %d | **%s** | %s | %.0f | %.1f%% | %s | %s |\n",
			r.full_name,
			r.run_count,
			r.samples,
			med_str,
			p95_str,
			r.ops_per_sec,
			r.cv_pct,
			foot_str,
			alloc_str,
		)
	}
	return strings.to_string(sb)
}

/*
Exports pooled benchmark records as a GitHub-Flavored Markdown report file.
*/
@(require_results)
export_markdown :: proc(path: string, records: []Pooled_Record) -> bool {
	_ensure_export_parent_dir(path)
	md := format_markdown_table(records, context.temp_allocator)
	return os.write_entire_file(path, transmute([]u8)md) == nil
}

/*
Formats a commit/run statistical comparison report as a readable terminal/Markdown table.
*/
@(require_results)
format_comparison_table :: proc(
	rep: Comparison_Report,
	base_label := "Baseline",
	cand_label := "Candidate",
	allocator := context.allocator,
) -> string {
	sb := strings.builder_make(allocator)
	fmt.sbprintf(
		&sb,
		"Comparison: %s -> %s  (geomean delta: %+.2f%%, improved: %d, regressed: %d, unchanged: %d)\n\n",
		base_label,
		cand_label,
		rep.geomean_delta,
		rep.improvements,
		rep.regressions,
		rep.unchanged,
	)
	strings.write_string(
		&sb,
		"| Benchmark | Baseline p50 | Candidate p50 | Delta | Speedup | Test / p-value | Verdict |\n",
	)
	strings.write_string(&sb, "| --- | ---: | ---: | ---: | ---: | ---: | --- |\n")
	for r in rep.rows {
		base_str := obench.format_duration_ns(r.base_p50_ns, context.temp_allocator)
		cand_str := obench.format_duration_ns(r.cand_p50_ns, context.temp_allocator)
		test_str := ""
		if r.used_rank_test {
			test_str = fmt.tprintf("MWU p=%.4f", r.p_value)
		} else {
			test_str = fmt.tprintf("Welch t=%.2f", r.welch_t)
		}
		verdict_str := "unchanged"
		switch r.verdict {
		case .Faster:
			verdict_str = "FASTER"
		case .Regression:
			verdict_str = "REGRESSION"
		case .Unchanged:
			verdict_str = "unchanged"
		}
		fmt.sbprintf(
			&sb,
			"| `%s` | %s | %s | %+.2f%% | %.2fx | %s | %s |\n",
			r.full_name,
			base_str,
			cand_str,
			r.delta_pct,
			r.speedup,
			test_str,
			verdict_str,
		)
	}
	return strings.to_string(sb)
}

/*
Formats a 1v1 cross-language comparison report including speedup, significance, and
footprint mismatch flags.
*/
@(require_results)
format_1v1_table :: proc(rep: Cross_Lang_Report, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	fmt.sbprintf(
		&sb,
		"Cross-Language 1v1: %s vs %s  (%s wins: %d, %s wins: %d, ties: %d, footprint mismatches: %d)\n\n",
		rep.lang_a,
		rep.lang_b,
		rep.lang_a,
		rep.a_wins,
		rep.lang_b,
		rep.b_wins,
		rep.ties,
		rep.footprint_mismatches,
	)
	fmt.sbprintf(
		&sb,
		"| Benchmark | %s p50 (CV%%) | %s p50 (CV%%) | Winner | Speedup | p-value | Footprint |\n",
		rep.lang_a,
		rep.lang_b,
	)
	strings.write_string(&sb, "| --- | ---: | ---: | --- | ---: | ---: | --- |\n")
	for r in rep.rows {
		a_str := fmt.tprintf(
			"%s (%.1f%%)",
			obench.format_duration_ns(r.a_p50_ns, context.temp_allocator),
			r.a_cv_pct,
		)
		b_str := fmt.tprintf(
			"%s (%.1f%%)",
			obench.format_duration_ns(r.b_p50_ns, context.temp_allocator),
			r.b_cv_pct,
		)
		foot_str := "ok"
		if r.a_footprint > 0 || r.b_footprint > 0 {
			foot_str = fmt.tprintf(
				"%s / %s",
				obench.format_bytes(f64(r.a_footprint), context.temp_allocator),
				obench.format_bytes(f64(r.b_footprint), context.temp_allocator),
			)
			if r.footprint_mismatch {
				foot_str = fmt.tprintf("%s [MISMATCH]", foot_str)
			}
		}
		fmt.sbprintf(
			&sb,
			"| `%s` | %s | %s | %s | %.2fx | %.4f | %s |\n",
			r.full_name,
			a_str,
			b_str,
			r.faster_lang,
			r.speedup_ratio,
			r.p_value,
			foot_str,
		)
	}
	if len(rep.only_in_a) > 0 {
		fmt.sbprintf(&sb, "\nOnly in %s (%d):", rep.lang_a, len(rep.only_in_a))
		for s in rep.only_in_a {
			fmt.sbprintf(&sb, " `%s`", s)
		}
		strings.write_byte(&sb, '\n')
	}
	if len(rep.only_in_b) > 0 {
		fmt.sbprintf(&sb, "\nOnly in %s (%d):", rep.lang_b, len(rep.only_in_b))
		for s in rep.only_in_b {
			fmt.sbprintf(&sb, " `%s`", s)
		}
		strings.write_byte(&sb, '\n')
	}
	return strings.to_string(sb)
}

/*
Replaces content strictly between `begin_marker` and `end_marker` in `readme_path`.
*/
@(require_results)
update_readme_markers :: proc(
	readme_path: string,
	markdown_block: string,
	begin_marker := "<!-- BEGIN_BENCHMARK_TABLE -->",
	end_marker := "<!-- END_BENCHMARK_TABLE -->",
) -> bool {
	raw, read_err := os.read_entire_file(readme_path, context.temp_allocator)
	if read_err != nil {
		return false
	}
	content := string(raw)

	b_idx := strings.index(content, begin_marker)
	if b_idx < 0 {
		return false
	}
	after_begin := b_idx + len(begin_marker)
	rel_end := strings.index(content[after_begin:], end_marker)
	if rel_end < 0 {
		return false
	}
	e_idx := after_begin + rel_end

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, content[:after_begin])
	strings.write_byte(&sb, '\n')
	strings.write_string(&sb, strings.trim_space(markdown_block))
	strings.write_byte(&sb, '\n')
	strings.write_string(&sb, content[e_idx:])

	return os.write_entire_file(readme_path, transmute([]u8)strings.to_string(sb)) == nil
}
