package hugi_store

import obench "../deps/obench/obench"
import hugi "../hugi"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

@(private = "file")
_write_json_f64 :: proc(sb: ^strings.Builder, format: string, v: f64) {
	if math.is_nan(v) || math.is_inf(v) {
		strings.write_byte(sb, '0')
		return
	}
	fmt.sbprintf(sb, format, v)
}

@(private = "file")
_write_json_bool :: proc(sb: ^strings.Builder, v: bool) {
	strings.write_string(sb, "true" if v else "false")
}

@(private = "file", require_results)
_write_text_output :: proc(path: string, content: string) -> bool {
	if path == "-" {
		_, err := os.write_string(os.stdout, content)
		return err == nil
	}
	_ensure_parent_dir(path)
	return os.write_entire_file(path, transmute([]u8)content) == nil
}

@(private = "file")
_verdict_str :: proc "contextless" (v: Verdict, upper: bool) -> string {
	switch v {
	case .Faster:
		return "FASTER" if upper else "faster"
	case .Regression:
		return "REGRESSION" if upper else "regression"
	case .Unchanged:
		return "unchanged"
	}
	return "unchanged"
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
_write_delimited_str :: proc(sb: ^strings.Builder, s: string, delim: byte) {
	needs_quote := strings.index_byte(s, delim) >= 0 || strings.contains_any(s, "\"\n\r")
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

@(private = "file")
_write_json_record :: proc(sb: ^strings.Builder, r: Pooled_Record, pretty: bool) {
	sep := ",\n    " if pretty else ","
	kv := ": " if pretty else ":"
	if pretty {
		strings.write_string(sb, "  {\n    ")
	} else {
		strings.write_byte(sb, '{')
	}

	rc := r
	for spec, idx in EXPORT_COLUMNS[:EXPORT_SCALAR_COL_COUNT] {
		if idx > 0 {
			strings.write_string(sb, sep)
		}
		strings.write_byte(sb, '"')
		strings.write_string(sb, spec.name)
		strings.write_byte(sb, '"')
		strings.write_string(sb, kv)
		switch spec.kind {
		case .String:
			_write_json_str(sb, _export_col_str(&rc, spec.id))
		case .I64:
			fmt.sbprintf(sb, "%d", _export_col_i64(&rc, spec.id))
		case .U64:
			fmt.sbprintf(sb, "%d", _export_col_u64(&rc, spec.id))
		case .Decimal_FS:
			hugi.write_decimal_ns_fs(sb, _export_col_i64(&rc, spec.id))
		case .F64:
			_write_json_f64(sb, spec.f64_fmt, _export_col_f64(&rc, spec.id))
		case .Samples_Blob:
		}
	}

	if len(r.samples_batch_ns) > 0 {
		fmt.sbprintf(sb, `%s"samples_batch_ns"%s[`, sep, kv)
		for b, idx in r.samples_batch_ns {
			if idx > 0 {
				strings.write_string(sb, ", " if pretty else ",")
			}
			fmt.sbprintf(sb, "%d", b)
		}
		strings.write_byte(sb, ']')
	}
	fmt.sbprintf(sb, `%s"samples_ns"%s[`, sep, kv)
	for fs, idx in r.samples_fs {
		if idx > 0 {
			strings.write_string(sb, ", " if pretty else ",")
		}
		hugi.write_decimal_ns_fs(sb, fs)
	}
	if pretty {
		strings.write_string(sb, "]\n  }")
	} else {
		strings.write_string(sb, "]}")
	}
}

/*
Formats pooled benchmark records as a pretty-printed JSON array document.
*/
@(require_results)
format_json_records :: proc(records: []Pooled_Record, allocator := context.allocator) -> string {
	if len(records) == 0 {
		return strings.clone("[]\n", allocator)
	}
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "[\n")
	for r, idx in records {
		if idx > 0 {
			strings.write_string(&sb, ",\n")
		}
		_write_json_record(&sb, r, true)
	}
	strings.write_string(&sb, "\n]\n")
	return strings.to_string(sb)
}

/*
Formats pooled benchmark records as JSON Lines using the canonical 34 scalar fields.
*/
@(require_results)
format_jsonl_records :: proc(records: []Pooled_Record, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for r in records {
		_write_json_record(&sb, r, false)
		strings.write_byte(&sb, '\n')
	}
	return strings.to_string(sb)
}

/*
Exports pooled benchmark records to a formatted JSON array document (or stdout when `path == "-"`).
*/
@(require_results)
export_json :: proc(path: string, records: []Pooled_Record) -> bool {
	return _write_text_output(path, format_json_records(records, context.temp_allocator))
}

/*
Exports pooled benchmark records to JSON Lines (or stdout when `path == "-"`).
*/
@(require_results)
export_jsonl :: proc(path: string, records: []Pooled_Record) -> bool {
	return _write_text_output(path, format_jsonl_records(records, context.temp_allocator))
}

@(private = "file", require_results)
_format_delimited_records :: proc(
	records: []Pooled_Record,
	delim: byte,
	allocator := context.allocator,
) -> string {
	sb := strings.builder_make(allocator)
	for spec, idx in EXPORT_COLUMNS[:EXPORT_SCALAR_COL_COUNT] {
		if idx > 0 {
			strings.write_byte(&sb, delim)
		}
		strings.write_string(&sb, spec.name)
	}
	strings.write_byte(&sb, '\n')

	for r in records {
		rc := r
		for spec, idx in EXPORT_COLUMNS[:EXPORT_SCALAR_COL_COUNT] {
			if idx > 0 {
				strings.write_byte(&sb, delim)
			}
			switch spec.kind {
			case .String:
				_write_delimited_str(&sb, _export_col_str(&rc, spec.id), delim)
			case .I64:
				fmt.sbprintf(&sb, "%d", _export_col_i64(&rc, spec.id))
			case .U64:
				fmt.sbprintf(&sb, "%d", _export_col_u64(&rc, spec.id))
			case .Decimal_FS:
				hugi.write_decimal_ns_fs(&sb, _export_col_i64(&rc, spec.id))
			case .F64:
				fmt.sbprintf(&sb, spec.f64_fmt, _export_col_f64(&rc, spec.id))
			case .Samples_Blob:
			}
		}
		strings.write_byte(&sb, '\n')
	}

	return strings.to_string(sb)
}

/*
Formats pooled benchmark records as an RFC 4180 CSV string.
*/
@(require_results)
format_csv_records :: proc(records: []Pooled_Record, allocator := context.allocator) -> string {
	return _format_delimited_records(records, ',', allocator)
}

/*
Formats pooled benchmark records as a Tab-Separated Values (TSV) string.
*/
@(require_results)
format_tsv_records :: proc(records: []Pooled_Record, allocator := context.allocator) -> string {
	return _format_delimited_records(records, '\t', allocator)
}

/*
Exports pooled benchmark records as an RFC 4180 CSV file (or stdout when `path == "-"`).
*/
@(require_results)
export_csv :: proc(path: string, records: []Pooled_Record) -> bool {
	return _write_text_output(path, format_csv_records(records, context.temp_allocator))
}

/*
Exports pooled benchmark records as a Tab-Separated Values (TSV) file (or stdout when `path == "-"`).
*/
@(require_results)
export_tsv :: proc(path: string, records: []Pooled_Record) -> bool {
	return _write_text_output(path, format_tsv_records(records, context.temp_allocator))
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
		med_str := hugi.format_duration_fs(r.p50_fs, context.temp_allocator)
		p95_str := hugi.format_duration_fs(r.p95_fs, context.temp_allocator)
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
Exports pooled benchmark records as a GitHub-Flavored Markdown report file (or stdout when `path == "-"`).
*/
@(require_results)
export_markdown :: proc(path: string, records: []Pooled_Record) -> bool {
	return _write_text_output(path, format_markdown_table(records, context.temp_allocator))
}

/*
Writes rendered report text (`md`, `json`, `csv`) to `out_path` or stdout when empty / `"-"`.
*/
@(require_results)
export_report_text :: proc(out_path: string, content: string) -> bool {
	return _write_text_output(out_path == "" ? "-" : out_path, content)
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
		"Comparison: %s -> %s  (geomean delta: %+.2f%%, improved: %d, regressed: %d, unchanged: %d)\n",
		base_label,
		cand_label,
		rep.geomean_delta,
		rep.improvements,
		rep.regressions,
		rep.unchanged,
	)
	for w in rep.warnings {
		fmt.sbprintf(&sb, "WARNING: %s\n", w)
	}
	strings.write_byte(&sb, '\n')
	strings.write_string(
		&sb,
		"| Benchmark | Baseline p50 | Candidate p50 | Delta | Speedup | Test / p-value | Verdict |\n",
	)
	strings.write_string(&sb, "| --- | ---: | ---: | ---: | ---: | ---: | --- |\n")
	for r in rep.rows {
		base_str := hugi.format_duration_fs(r.base_p50_fs, context.temp_allocator)
		cand_str := hugi.format_duration_fs(r.cand_p50_fs, context.temp_allocator)
		test_str := ""
		if r.used_shift_ci {
			suffix := " (runs)" if r.used_run_medians else ""
			test_str = fmt.tprintf(
				"HL [%+.1f%%, %+.1f%%] p=%.4f%s",
				r.shift_low_pct,
				r.shift_high_pct,
				r.p_value,
				suffix,
			)
		} else if r.used_rank_test {
			if min(r.base_samples, r.cand_samples) >= 4 {
				test_str = fmt.tprintf("MWU p=%.4f", r.p_value)
			} else if r.welch_df > 0 {
				test_str = fmt.tprintf("Welch t=%.2f (n<4)", r.welch_t)
			} else {
				test_str = fmt.tprintf("MWU p=%.4f (n<4)", r.p_value)
			}
		} else {
			test_str = fmt.tprintf("Welch t=%.2f", r.welch_t)
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
			_verdict_str(r.verdict, upper = true),
		)
	}
	return strings.to_string(sb)
}

/*
Formats a commit/run statistical comparison report as JSON with exact fixed-point nanosecond fields.
*/
@(require_results)
format_comparison_json :: proc(
	rep: Comparison_Report,
	base_label := "Baseline",
	cand_label := "Candidate",
	allocator := context.allocator,
) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "{\n  \"baseline\": ")
	_write_json_str(&sb, base_label)
	strings.write_string(&sb, ",\n  \"candidate\": ")
	_write_json_str(&sb, cand_label)
	strings.write_string(&sb, ",\n  \"geomean_delta_pct\": ")
	_write_json_f64(&sb, "%.4f", rep.geomean_delta)
	fmt.sbprintf(
		&sb,
		",\n  \"improvements\": %d,\n  \"regressions\": %d,\n  \"unchanged\": %d,\n  \"underpowered_rows\": %d,\n  \"high_cv_rows\": %d,\n  \"drifting_rows\": %d,\n  \"multimodal_rows\": %d,\n  \"warnings\": ",
		rep.improvements,
		rep.regressions,
		rep.unchanged,
		rep.underpowered_rows,
		rep.high_cv_rows,
		rep.drifting_rows,
		rep.multimodal_rows,
	)
	_write_json_str_array(&sb, rep.warnings[:])
	strings.write_string(&sb, ",\n  \"rows\": [")
	for r, idx in rep.rows {
		if idx > 0 {
			strings.write_byte(&sb, ',')
		}
		strings.write_string(&sb, "\n    {\n      \"full_name\": ")
		_write_json_str(&sb, r.full_name)
		strings.write_string(&sb, ",\n      \"base_p50_ns\": ")
		hugi.write_decimal_ns_fs(&sb, r.base_p50_fs)
		strings.write_string(&sb, ",\n      \"cand_p50_ns\": ")
		hugi.write_decimal_ns_fs(&sb, r.cand_p50_fs)
		strings.write_string(&sb, ",\n      \"base_std_dev_ns\": ")
		hugi.write_decimal_ns_fs(&sb, r.base_std_fs)
		strings.write_string(&sb, ",\n      \"cand_std_dev_ns\": ")
		hugi.write_decimal_ns_fs(&sb, r.cand_std_fs)
		fmt.sbprintf(
			&sb,
			",\n      \"base_samples\": %d,\n      \"cand_samples\": %d,\n      \"delta_pct\": ",
			r.base_samples,
			r.cand_samples,
		)
		_write_json_f64(&sb, "%.4f", r.delta_pct)
		strings.write_string(&sb, ",\n      \"speedup\": ")
		_write_json_f64(&sb, "%.6f", r.speedup)
		strings.write_string(&sb, ",\n      \"welch_t\": ")
		_write_json_f64(&sb, "%.4f", r.welch_t)
		strings.write_string(&sb, ",\n      \"welch_df\": ")
		_write_json_f64(&sb, "%.2f", r.welch_df)
		strings.write_string(&sb, ",\n      \"used_rank_test\": ")
		_write_json_bool(&sb, r.used_rank_test)
		strings.write_string(&sb, ",\n      \"p_value\": ")
		_write_json_f64(&sb, "%.6f", r.p_value)
		strings.write_string(&sb, ",\n      \"shift_pct\": ")
		_write_json_f64(&sb, "%.4f", r.shift_pct)
		strings.write_string(&sb, ",\n      \"shift_low_pct\": ")
		_write_json_f64(&sb, "%.4f", r.shift_low_pct)
		strings.write_string(&sb, ",\n      \"shift_high_pct\": ")
		_write_json_f64(&sb, "%.4f", r.shift_high_pct)
		strings.write_string(&sb, ",\n      \"used_shift_ci\": ")
		_write_json_bool(&sb, r.used_shift_ci)
		strings.write_string(&sb, ",\n      \"used_run_medians\": ")
		_write_json_bool(&sb, r.used_run_medians)
		strings.write_string(&sb, ",\n      \"is_significant\": ")
		_write_json_bool(&sb, r.is_significant)
		strings.write_string(&sb, ",\n      \"verdict\": ")
		_write_json_str(&sb, _verdict_str(r.verdict, upper = false))
		strings.write_string(&sb, ",\n      \"base_allocs_per_op\": ")
		_write_json_f64(&sb, "%.4f", r.base_allocs)
		strings.write_string(&sb, ",\n      \"cand_allocs_per_op\": ")
		_write_json_f64(&sb, "%.4f", r.cand_allocs)
		strings.write_string(&sb, ",\n      \"base_alloc_bytes_per_op\": ")
		_write_json_f64(&sb, "%.2f", r.base_alloc_bytes)
		strings.write_string(&sb, ",\n      \"cand_alloc_bytes_per_op\": ")
		_write_json_f64(&sb, "%.2f", r.cand_alloc_bytes)
		fmt.sbprintf(
			&sb,
			",\n      \"base_footprint_bytes\": %d,\n      \"cand_footprint_bytes\": %d\n    }",
			r.base_footprint,
			r.cand_footprint,
		)
	}
	if len(rep.rows) > 0 {
		strings.write_string(&sb, "\n  ]\n}\n")
	} else {
		strings.write_string(&sb, "]\n}\n")
	}
	return strings.to_string(sb)
}

/*
Formats a commit/run statistical comparison report as RFC 4180 CSV.
*/
@(require_results)
format_comparison_csv :: proc(
	rep: Comparison_Report,
	base_label := "Baseline",
	cand_label := "Candidate",
	allocator := context.allocator,
) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(
		&sb,
		"baseline,candidate,full_name,base_p50_ns,cand_p50_ns,base_std_dev_ns,cand_std_dev_ns,base_samples,cand_samples,delta_pct,speedup,welch_t,welch_df,used_rank_test,p_value,is_significant,verdict,base_allocs_per_op,cand_allocs_per_op,base_alloc_bytes_per_op,cand_alloc_bytes_per_op,base_footprint_bytes,cand_footprint_bytes,shift_pct,shift_low_pct,shift_high_pct,used_shift_ci,used_run_medians\n",
	)
	for r in rep.rows {
		_write_delimited_str(&sb, base_label, ',')
		strings.write_byte(&sb, ',')
		_write_delimited_str(&sb, cand_label, ',')
		strings.write_byte(&sb, ',')
		_write_delimited_str(&sb, r.full_name, ',')
		strings.write_byte(&sb, ',')
		hugi.write_decimal_ns_fs(&sb, r.base_p50_fs)
		strings.write_byte(&sb, ',')
		hugi.write_decimal_ns_fs(&sb, r.cand_p50_fs)
		strings.write_byte(&sb, ',')
		hugi.write_decimal_ns_fs(&sb, r.base_std_fs)
		strings.write_byte(&sb, ',')
		hugi.write_decimal_ns_fs(&sb, r.cand_std_fs)
		fmt.sbprintf(&sb, ",%d,%d,", r.base_samples, r.cand_samples)
		_write_json_f64(&sb, "%.4f", r.delta_pct)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.6f", r.speedup)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.4f", r.welch_t)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.2f", r.welch_df)
		strings.write_byte(&sb, ',')
		_write_json_bool(&sb, r.used_rank_test)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.6f", r.p_value)
		strings.write_byte(&sb, ',')
		_write_json_bool(&sb, r.is_significant)
		strings.write_byte(&sb, ',')
		strings.write_string(&sb, _verdict_str(r.verdict, upper = false))
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.4f", r.base_allocs)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.4f", r.cand_allocs)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.2f", r.base_alloc_bytes)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.2f", r.cand_alloc_bytes)
		fmt.sbprintf(&sb, ",%d,%d,", r.base_footprint, r.cand_footprint)
		_write_json_f64(&sb, "%.4f", r.shift_pct)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.4f", r.shift_low_pct)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.4f", r.shift_high_pct)
		strings.write_byte(&sb, ',')
		_write_json_bool(&sb, r.used_shift_ci)
		strings.write_byte(&sb, ',')
		_write_json_bool(&sb, r.used_run_medians)
		strings.write_byte(&sb, '\n')
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
		"Cross-Language 1v1: %s vs %s  (%s wins: %d, %s wins: %d, ties: %d, footprint mismatches: %d)\n",
		rep.lang_a,
		rep.lang_b,
		rep.lang_a,
		rep.a_wins,
		rep.lang_b,
		rep.b_wins,
		rep.ties,
		rep.footprint_mismatches,
	)
	for w in rep.warnings {
		fmt.sbprintf(&sb, "WARNING: %s\n", w)
	}
	strings.write_byte(&sb, '\n')
	fmt.sbprintf(
		&sb,
		"| Benchmark | %s p50 (CV%%) | %s p50 (CV%%) | Winner | Speedup | Test / p-value | Footprint |\n",
		rep.lang_a,
		rep.lang_b,
	)
	strings.write_string(&sb, "| --- | ---: | ---: | --- | ---: | ---: | --- |\n")
	for r in rep.rows {
		a_str := fmt.tprintf(
			"%s (%.1f%%)",
			hugi.format_duration_fs(r.a_p50_fs, context.temp_allocator),
			r.a_cv_pct,
		)
		b_str := fmt.tprintf(
			"%s (%.1f%%)",
			hugi.format_duration_fs(r.b_p50_fs, context.temp_allocator),
			r.b_cv_pct,
		)
		winner_str := r.faster_lang
		if !r.is_significant && r.faster_lang != "tie" {
			winner_str = fmt.tprintf("%s (ns)", r.faster_lang)
		}
		test_str := ""
		if r.used_shift_ci {
			test_str = fmt.tprintf(
				"HL [%+.1f%%, %+.1f%%] p=%.4f",
				r.shift_low_pct,
				r.shift_high_pct,
				r.p_value,
			)
		} else if r.welch_t != 0 && r.p_value == 1.0 {
			test_str = fmt.tprintf("Welch t=%.2f", r.welch_t)
		} else {
			test_str = fmt.tprintf("MWU p=%.4f", r.p_value)
		}
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
			"| `%s` | %s | %s | %s | %.2fx | %s | %s |\n",
			r.full_name,
			a_str,
			b_str,
			winner_str,
			r.speedup_ratio,
			test_str,
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

@(private = "file")
_write_json_str_array :: proc(sb: ^strings.Builder, items: []string) {
	strings.write_byte(sb, '[')
	for s, idx in items {
		if idx > 0 {
			strings.write_string(sb, ", ")
		}
		_write_json_str(sb, s)
	}
	strings.write_byte(sb, ']')
}

/*
Formats a 1v1 cross-language comparison report as JSON with exact fixed-point nanosecond fields.
*/
@(require_results)
format_1v1_json :: proc(rep: Cross_Lang_Report, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "{\n  \"lang_a\": ")
	_write_json_str(&sb, rep.lang_a)
	strings.write_string(&sb, ",\n  \"lang_b\": ")
	_write_json_str(&sb, rep.lang_b)
	strings.write_string(&sb, ",\n  \"a_commit\": ")
	_write_json_str(&sb, rep.a_commit)
	strings.write_string(&sb, ",\n  \"b_commit\": ")
	_write_json_str(&sb, rep.b_commit)
	fmt.sbprintf(
		&sb,
		",\n  \"a_wins\": %d,\n  \"b_wins\": %d,\n  \"ties\": %d,\n  \"footprint_mismatches\": %d,\n  \"underpowered_rows\": %d,\n  \"high_cv_rows\": %d,\n  \"drifting_rows\": %d,\n  \"multimodal_rows\": %d,\n  \"warnings\": ",
		rep.a_wins,
		rep.b_wins,
		rep.ties,
		rep.footprint_mismatches,
		rep.underpowered_rows,
		rep.high_cv_rows,
		rep.drifting_rows,
		rep.multimodal_rows,
	)
	_write_json_str_array(&sb, rep.warnings[:])
	strings.write_string(&sb, ",\n  \"only_in_a\": ")
	_write_json_str_array(&sb, rep.only_in_a[:])
	strings.write_string(&sb, ",\n  \"only_in_b\": ")
	_write_json_str_array(&sb, rep.only_in_b[:])
	strings.write_string(&sb, ",\n  \"rows\": [")
	for r, idx in rep.rows {
		if idx > 0 {
			strings.write_byte(&sb, ',')
		}
		strings.write_string(&sb, "\n    {\n      \"full_name\": ")
		_write_json_str(&sb, r.full_name)
		fmt.sbprintf(&sb, ",\n      \"ops\": %d,\n      \"a_p50_ns\": ", r.ops)
		hugi.write_decimal_ns_fs(&sb, r.a_p50_fs)
		strings.write_string(&sb, ",\n      \"a_std_dev_ns\": ")
		hugi.write_decimal_ns_fs(&sb, r.a_std_fs)
		strings.write_string(&sb, ",\n      \"b_p50_ns\": ")
		hugi.write_decimal_ns_fs(&sb, r.b_p50_fs)
		strings.write_string(&sb, ",\n      \"b_std_dev_ns\": ")
		hugi.write_decimal_ns_fs(&sb, r.b_std_fs)
		strings.write_string(&sb, ",\n      \"a_cv_pct\": ")
		_write_json_f64(&sb, "%.4f", r.a_cv_pct)
		strings.write_string(&sb, ",\n      \"b_cv_pct\": ")
		_write_json_f64(&sb, "%.4f", r.b_cv_pct)
		strings.write_string(&sb, ",\n      \"faster_lang\": ")
		_write_json_str(&sb, r.faster_lang)
		strings.write_string(&sb, ",\n      \"speedup_ratio\": ")
		_write_json_f64(&sb, "%.6f", r.speedup_ratio)
		strings.write_string(&sb, ",\n      \"is_significant\": ")
		_write_json_bool(&sb, r.is_significant)
		strings.write_string(&sb, ",\n      \"p_value\": ")
		_write_json_f64(&sb, "%.6f", r.p_value)
		strings.write_string(&sb, ",\n      \"shift_pct\": ")
		_write_json_f64(&sb, "%.4f", r.shift_pct)
		strings.write_string(&sb, ",\n      \"shift_low_pct\": ")
		_write_json_f64(&sb, "%.4f", r.shift_low_pct)
		strings.write_string(&sb, ",\n      \"shift_high_pct\": ")
		_write_json_f64(&sb, "%.4f", r.shift_high_pct)
		strings.write_string(&sb, ",\n      \"used_shift_ci\": ")
		_write_json_bool(&sb, r.used_shift_ci)
		strings.write_string(&sb, ",\n      \"welch_t\": ")
		_write_json_f64(&sb, "%.4f", r.welch_t)
		fmt.sbprintf(
			&sb,
			",\n      \"a_footprint_bytes\": %d,\n      \"b_footprint_bytes\": %d,\n      \"footprint_mismatch\": ",
			r.a_footprint,
			r.b_footprint,
		)
		_write_json_bool(&sb, r.footprint_mismatch)
		strings.write_string(&sb, ",\n      \"a_allocs_per_op\": ")
		_write_json_f64(&sb, "%.4f", r.a_allocs)
		strings.write_string(&sb, ",\n      \"b_allocs_per_op\": ")
		_write_json_f64(&sb, "%.4f", r.b_allocs)
		strings.write_string(&sb, "\n    }")
	}
	if len(rep.rows) > 0 {
		strings.write_string(&sb, "\n  ]\n}\n")
	} else {
		strings.write_string(&sb, "]\n}\n")
	}
	return strings.to_string(sb)
}

/*
Formats a 1v1 cross-language comparison report as RFC 4180 CSV.
*/
@(require_results)
format_1v1_csv :: proc(rep: Cross_Lang_Report, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(
		&sb,
		"lang_a,lang_b,full_name,ops,a_p50_ns,a_std_dev_ns,b_p50_ns,b_std_dev_ns,a_cv_pct,b_cv_pct,faster_lang,speedup_ratio,is_significant,p_value,welch_t,a_footprint_bytes,b_footprint_bytes,footprint_mismatch,a_allocs_per_op,b_allocs_per_op,shift_pct,shift_low_pct,shift_high_pct,used_shift_ci\n",
	)
	for r in rep.rows {
		_write_delimited_str(&sb, rep.lang_a, ',')
		strings.write_byte(&sb, ',')
		_write_delimited_str(&sb, rep.lang_b, ',')
		strings.write_byte(&sb, ',')
		_write_delimited_str(&sb, r.full_name, ',')
		fmt.sbprintf(&sb, ",%d,", r.ops)
		hugi.write_decimal_ns_fs(&sb, r.a_p50_fs)
		strings.write_byte(&sb, ',')
		hugi.write_decimal_ns_fs(&sb, r.a_std_fs)
		strings.write_byte(&sb, ',')
		hugi.write_decimal_ns_fs(&sb, r.b_p50_fs)
		strings.write_byte(&sb, ',')
		hugi.write_decimal_ns_fs(&sb, r.b_std_fs)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.4f", r.a_cv_pct)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.4f", r.b_cv_pct)
		strings.write_byte(&sb, ',')
		_write_delimited_str(&sb, r.faster_lang, ',')
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.6f", r.speedup_ratio)
		strings.write_byte(&sb, ',')
		_write_json_bool(&sb, r.is_significant)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.6f", r.p_value)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.4f", r.welch_t)
		fmt.sbprintf(&sb, ",%d,%d,", r.a_footprint, r.b_footprint)
		_write_json_bool(&sb, r.footprint_mismatch)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.4f", r.a_allocs)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.4f", r.b_allocs)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.4f", r.shift_pct)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.4f", r.shift_low_pct)
		strings.write_byte(&sb, ',')
		_write_json_f64(&sb, "%.4f", r.shift_high_pct)
		strings.write_byte(&sb, ',')
		_write_json_bool(&sb, r.used_shift_ci)
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
