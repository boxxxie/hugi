package hugi_store

import obench "../deps/obench/obench"
import hugi "../hugi"
import "core:fmt"
import "core:os"
import "core:strings"

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
			fmt.sbprintf(sb, spec.f64_fmt, _export_col_f64(&rc, spec.id))
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
Exports pooled benchmark records to a formatted JSON array document.
*/
@(require_results)
export_json :: proc(path: string, records: []Pooled_Record) -> bool {
	_ensure_parent_dir(path)

	if len(records) == 0 {
		return os.write_entire_file(path, transmute([]u8)string("[]\n")) == nil
	}

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "[\n")
	for r, idx in records {
		if idx > 0 {
			strings.write_string(&sb, ",\n")
		}
		_write_json_record(&sb, r, true)
	}
	strings.write_string(&sb, "\n]\n")

	return os.write_entire_file(path, transmute([]u8)strings.to_string(sb)) == nil
}

/*
Exports pooled benchmark records to JSON Lines using the canonical 34 scalar fields.
*/
@(require_results)
export_jsonl :: proc(path: string, records: []Pooled_Record) -> bool {
	_ensure_parent_dir(path)

	sb := strings.builder_make(context.temp_allocator)
	for r in records {
		_write_json_record(&sb, r, false)
		strings.write_byte(&sb, '\n')
	}

	return os.write_entire_file(path, transmute([]u8)strings.to_string(sb)) == nil
}

@(private = "file")
_export_delimited :: proc(path: string, records: []Pooled_Record, delim: byte) -> bool {
	_ensure_parent_dir(path)

	sb := strings.builder_make(context.temp_allocator)
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

	return os.write_entire_file(path, transmute([]u8)strings.to_string(sb)) == nil
}

/*
Exports pooled benchmark records as an RFC 4180 CSV file.
*/
@(require_results)
export_csv :: proc(path: string, records: []Pooled_Record) -> bool {
	return _export_delimited(path, records, ',')
}

/*
Exports pooled benchmark records as a Tab-Separated Values (TSV) file.
*/
@(require_results)
export_tsv :: proc(path: string, records: []Pooled_Record) -> bool {
	return _export_delimited(path, records, '\t')
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
Exports pooled benchmark records as a GitHub-Flavored Markdown report file.
*/
@(require_results)
export_markdown :: proc(path: string, records: []Pooled_Record) -> bool {
	_ensure_parent_dir(path)
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
		base_str := hugi.format_duration_fs(r.base_p50_fs, context.temp_allocator)
		cand_str := hugi.format_duration_fs(r.cand_p50_fs, context.temp_allocator)
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
			hugi.format_duration_fs(r.a_p50_fs, context.temp_allocator),
			r.a_cv_pct,
		)
		b_str := fmt.tprintf(
			"%s (%.1f%%)",
			hugi.format_duration_fs(r.b_p50_fs, context.temp_allocator),
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
