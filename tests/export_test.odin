package hugi_tests

import skadi "../deps/skadi/skadi"
import hugi "../hugi"
import store "../store"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_export_uncompressed_empty_and_escaping_edge_cases :: proc(t: ^testing.T) {
	tmp, mk_err := os.make_directory_temp("", "hugi-export-edge-*", context.allocator)
	testing.expectf(t, mk_err == nil && tmp != "", "create temp export dir: %v", mk_err)
	if mk_err != nil || tmp == "" {
		return
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	tmp_file :: proc(dir, name: string) -> string {
		p, _ := filepath.join({dir, name}, context.temp_allocator)
		return p
	}

	// Build a record containing special CSV/JSON/Markdown characters.
	special_full := `core::edge,"q",tab	\slash` + "\nline"
	recs := make([]store.Pooled_Record, 1, context.temp_allocator)
	run_ids := make([dynamic]string, context.temp_allocator)
	append(&run_ids, "r-edge-1")
	metrics := make([dynamic]hugi.Metric, context.temp_allocator)
	append(&metrics, hugi.Metric{unit = `ops,"/s"\u`, value = 42.5})
	samples_fs := make([dynamic]i64, context.temp_allocator)
	append(&samples_fs, 100_000_000, 100_500_000, 101_000_000, 102_000_000)
	samples_batch := make([dynamic]u64, context.temp_allocator)
	append(&samples_batch, 10_000, 10_050, 10_100, 10_200)

	recs[0] = store.Pooled_Record {
		rank               = 1,
		commit             = "edg001",
		lang               = "odin",
		suite_name         = "edge_suite",
		group_name         = "core",
		name               = `edge,"q"`,
		full_name          = special_full,
		run_count          = 1,
		run_ids            = run_ids,
		timestamp_unix     = 1770000000,
		ops_per_sample     = 100,
		samples            = 4,
		min_fs             = 100_000_000,
		p50_fs             = 100_750_000,
		p95_fs             = 102_000_000,
		max_fs             = 102_000_000,
		mean_fs            = 100_875_000,
		cv_pct             = 0.8,
		ops_per_sec        = 9_925_000.0,
		footprint_bytes    = 2048,
		allocs_per_op      = 2.5,
		alloc_bytes_per_op = 128.0,
		metrics            = metrics,
		samples_fs         = samples_fs,
		samples_batch_ns   = samples_batch,
	}

	// 1. Uncompressed Arrow IPC and uncompressed Parquet round-trips.
	raw_arrow := tmp_file(tmp, "raw.arrow")
	testing.expect(
		t,
		store.export_arrow_ipc(raw_arrow, recs, ipc_compression = .None),
		"uncompressed Arrow IPC export should succeed",
	)
	sc, bs, ipc_ok := skadi.ipc_read_file(raw_arrow, context.allocator, true, false)
	testing.expect(t, ipc_ok, "read uncompressed Arrow IPC")
	if ipc_ok {
		defer {
			for &b in bs {
				skadi.record_batch_free(&b)
			}
			delete(bs)
			if sc != nil {
				skadi.schema_free(sc)
				free(sc)
			}
		}
		testing.expect_value(t, len(sc.fields), store.EXPORT_TOTAL_COL_COUNT)
		testing.expect_value(t, len(bs), 1)
		if len(bs) == 1 {
			testing.expect_value(t, bs[0].length, 1)
		}
	}

	raw_pq := tmp_file(tmp, "raw.parquet")
	testing.expect(
		t,
		store.export_parquet(raw_pq, recs, compress_pages = false),
		"uncompressed Parquet export should succeed",
	)
	if pq_bytes, err := os.read_entire_file(raw_pq, context.allocator); err == nil {
		defer delete(pq_bytes)
		testing.expect(t, len(pq_bytes) > 8, "parquet must contain footer and magic")
		if len(pq_bytes) >= 8 {
			testing.expect_value(t, string(pq_bytes[:4]), "PAR1")
			testing.expect_value(t, string(pq_bytes[len(pq_bytes) - 4:]), "PAR1")
		}
	}

	// 2. Empty 0-record exports across all 7 formats.
	empty: []store.Pooled_Record = nil

	empty_arrow := tmp_file(tmp, "empty.arrow")
	testing.expect(t, store.export_arrow_ipc(empty_arrow, empty), "empty Arrow export")
	esc, ebs, e_ipc_ok := skadi.ipc_read_file(empty_arrow, context.allocator, true, false)
	testing.expect(t, e_ipc_ok, "read empty Arrow IPC")
	if e_ipc_ok {
		defer {
			for &b in ebs {
				skadi.record_batch_free(&b)
			}
			delete(ebs)
			if esc != nil {
				skadi.schema_free(esc)
				free(esc)
			}
		}
		testing.expect_value(t, len(esc.fields), store.EXPORT_TOTAL_COL_COUNT)
		total_rows := 0
		for &b in ebs {
			total_rows += b.length
		}
		testing.expect_value(t, total_rows, 0)
	}

	empty_pq := tmp_file(tmp, "empty.parquet")
	testing.expect(t, store.export_parquet(empty_pq, empty), "empty Parquet export")
	if epq, err := os.read_entire_file(empty_pq, context.allocator); err == nil {
		defer delete(epq)
		testing.expect(t, len(epq) >= 8, "empty parquet magic bounds")
		if len(epq) >= 8 {
			testing.expect_value(t, string(epq[:4]), "PAR1")
			testing.expect_value(t, string(epq[len(epq) - 4:]), "PAR1")
		}
	}

	empty_csv := tmp_file(tmp, "empty.csv")
	empty_tsv := tmp_file(tmp, "empty.tsv")
	empty_json := tmp_file(tmp, "empty.json")
	empty_jsonl := tmp_file(tmp, "empty.jsonl")
	empty_md := tmp_file(tmp, "empty.md")
	testing.expect(t, store.export_csv(empty_csv, empty), "empty CSV export")
	testing.expect(t, store.export_tsv(empty_tsv, empty), "empty TSV export")
	testing.expect(t, store.export_json(empty_json, empty), "empty JSON export")
	testing.expect(t, store.export_jsonl(empty_jsonl, empty), "empty JSONL export")
	testing.expect(t, store.export_markdown(empty_md, empty), "empty Markdown export")

	if b, err := os.read_entire_file(empty_json, context.allocator); err == nil {
		defer delete(b)
		testing.expect_value(t, string(b), "[]\n")
	}
	if b, err := os.read_entire_file(empty_jsonl, context.allocator); err == nil {
		defer delete(b)
		testing.expect_value(t, len(b), 0)
	}
	if b, err := os.read_entire_file(empty_csv, context.allocator); err == nil {
		defer delete(b)
		lines := strings.split_lines(string(b), context.temp_allocator)
		testing.expect_value(t, len(lines), 2)
		testing.expect(t, strings.has_prefix(lines[0], "commit,lang,"), "CSV header intact")
		testing.expect_value(t, lines[1], "")
	}
	if b, err := os.read_entire_file(empty_tsv, context.allocator); err == nil {
		defer delete(b)
		lines := strings.split_lines(string(b), context.temp_allocator)
		testing.expect_value(t, len(lines), 2)
		testing.expect(t, strings.has_prefix(lines[0], "commit\tlang\t"), "TSV header intact")
	}
	if b, err := os.read_entire_file(empty_md, context.allocator); err == nil {
		defer delete(b)
		lines := strings.split_lines(string(b), context.temp_allocator)
		testing.expect_value(t, len(lines), 3)
		testing.expect(t, strings.has_prefix(lines[0], "| Benchmark |"), "Markdown header")
		testing.expect(t, strings.has_prefix(lines[1], "| ---"), "Markdown separator")
	}

	// 3. Special character escaping across CSV/TSV/JSON/JSONL/Markdown.
	esc_csv := tmp_file(tmp, "esc.csv")
	esc_tsv := tmp_file(tmp, "esc.tsv")
	esc_json := tmp_file(tmp, "esc.json")
	esc_jsonl := tmp_file(tmp, "esc.jsonl")
	esc_md := tmp_file(tmp, "esc.md")
	testing.expect(t, store.export_csv(esc_csv, recs), "escaped CSV export")
	testing.expect(t, store.export_tsv(esc_tsv, recs), "escaped TSV export")
	testing.expect(t, store.export_json(esc_json, recs), "escaped JSON export")
	testing.expect(t, store.export_jsonl(esc_jsonl, recs), "escaped JSONL export")
	testing.expect(t, store.export_markdown(esc_md, recs), "escaped Markdown export")

	if raw_json, err := os.read_entire_file(esc_json, context.allocator); err == nil {
		defer delete(raw_json)
		parsed, p_err := json.parse(raw_json, allocator = context.allocator)
		testing.expect(t, p_err == .None, "escaped JSON must parse cleanly")
		if p_err == .None {
			defer json.destroy_value(parsed, context.allocator)
			arr, is_arr := parsed.(json.Array)
			testing.expect(t, is_arr && len(arr) == 1, "expected 1 JSON record")
			if is_arr && len(arr) == 1 {
				obj, is_obj := arr[0].(json.Object)
				testing.expect(t, is_obj, "JSON element is object")
				if is_obj {
					fn, has_fn := obj["full_name"].(json.String)
					testing.expect(t, has_fn, "full_name field is string")
					testing.expect_value(t, fn, special_full)
				}
			}
		}
	}
	if raw_jsonl, err := os.read_entire_file(esc_jsonl, context.allocator); err == nil {
		defer delete(raw_jsonl)
		trimmed := strings.trim_space(string(raw_jsonl))
		parsed, p_err := json.parse(transmute([]u8)trimmed, allocator = context.allocator)
		testing.expect(t, p_err == .None, "escaped JSONL must parse cleanly")
		if p_err == .None {
			json.destroy_value(parsed, context.allocator)
		}
	}
	if raw_csv, err := os.read_entire_file(esc_csv, context.allocator); err == nil {
		defer delete(raw_csv)
		testing.expect(
			t,
			strings.contains(string(raw_csv), `"core::edge,""q"",tab` + "\t\\slash\nline\""),
			"CSV must quote commas, newlines, and double quotes per RFC 4180",
		)
	}
	if raw_tsv, err := os.read_entire_file(esc_tsv, context.allocator); err == nil {
		defer delete(raw_tsv)
		testing.expect(
			t,
			strings.contains(string(raw_tsv), `"core::edge,""q"",tab` + "\t\\slash\nline\""),
			"TSV must quote tabs, quotes, and newlines",
		)
	}
	if raw_md, err := os.read_entire_file(esc_md, context.allocator); err == nil {
		defer delete(raw_md)
		testing.expect(
			t,
			strings.contains(string(raw_md), "2.5 (128 B)"),
			"Markdown must format non-zero alloc summary",
		)
	}

	// 4. Table formatters edge cases (empty comparison, unmatched 1v1 buckets, [MISMATCH]).
	empty_cmp: store.Comparison_Report
	cmp_txt := store.format_comparison_table(empty_cmp, "baseA", "candB", context.allocator)
	defer delete(cmp_txt)
	testing.expect(
		t,
		strings.contains(
			cmp_txt,
			"Comparison: baseA -> candB  (geomean delta: +0.00%, improved: 0, regressed: 0, unchanged: 0)",
		),
		"empty comparison table header formatting",
	)

	rep_1v1 := store.Cross_Lang_Report {
		lang_a               = strings.clone("odin"),
		lang_b               = strings.clone("zig"),
		rows                 = make([dynamic]store.Cross_Lang_Row),
		a_wins               = 1,
		footprint_mismatches = 1,
		only_in_a            = make([dynamic]string),
		only_in_b            = make([dynamic]string),
	}
	defer store.cross_lang_report_destroy(&rep_1v1)
	append(
		&rep_1v1.rows,
		store.Cross_Lang_Row {
			full_name = strings.clone("core::op"),
			ops = 10,
			a_p50_fs = 50_000_000,
			b_p50_fs = 100_000_000,
			faster_lang = strings.clone("odin"),
			speedup_ratio = 2.0,
			is_significant = true,
			p_value = 0.002,
			a_footprint = 1024,
			b_footprint = 4096,
			footprint_mismatch = true,
		},
	)
	append(&rep_1v1.only_in_a, strings.clone("core::only_odin"))
	append(&rep_1v1.only_in_b, strings.clone("core::only_zig"))

	t_1v1 := store.format_1v1_table(rep_1v1, context.allocator)
	defer delete(t_1v1)
	testing.expect(t, strings.contains(t_1v1, "[MISMATCH]"), "1v1 table marks footprint mismatch")
	testing.expect(t, strings.contains(t_1v1, "Only in odin (1):"), "1v1 only_in_a bucket")
	testing.expect(t, strings.contains(t_1v1, "Only in zig (1):"), "1v1 only_in_b bucket")

	// 5. Machine-readable comparison and 1v1 JSON / CSV formatters.
	cmp_rep := store.Comparison_Report {
		rows          = make([dynamic]store.Comparison_Row),
		improvements  = 1,
		geomean_delta = -25.0,
	}
	defer store.comparison_report_destroy(&cmp_rep)
	append(
		&cmp_rep.rows,
		store.Comparison_Row {
			full_name = strings.clone("core::op"),
			base_p50_fs = 100_000_000,
			cand_p50_fs = 75_000_000,
			base_std_fs = 1_500_000,
			cand_std_fs = 1_000_000,
			base_samples = 5,
			cand_samples = 5,
			delta_pct = -25.0,
			speedup = 1.333333,
			welch_t = -4.2,
			welch_df = 7.5,
			used_rank_test = true,
			p_value = 0.008,
			is_significant = true,
			verdict = .Faster,
			base_footprint = 1024,
			cand_footprint = 1024,
		},
	)

	cmp_json := store.format_comparison_json(cmp_rep, "c01", "c02", context.allocator)
	defer delete(cmp_json)
	if parsed, p_err := json.parse(transmute([]u8)cmp_json, allocator = context.allocator);
	   p_err == .None {
		defer json.destroy_value(parsed, context.allocator)
		obj, is_obj := parsed.(json.Object)
		testing.expect(t, is_obj, "comparison json root must be object")
		if is_obj {
			testing.expect_value(t, obj["baseline"].(json.String) or_else "", "c01")
			testing.expect_value(t, obj["candidate"].(json.String) or_else "", "c02")
			rows_arr, has_rows := obj["rows"].(json.Array)
			testing.expect(t, has_rows && len(rows_arr) == 1, "expected 1 comparison row")
			if has_rows && len(rows_arr) == 1 {
				row_obj := rows_arr[0].(json.Object)
				testing.expect_value(t, row_obj["verdict"].(json.String) or_else "", "faster")
			}
		}
	} else {
		testing.expectf(t, false, "comparison json failed to parse: %v", p_err)
	}

	cmp_csv := store.format_comparison_csv(cmp_rep, "c01", "c02", context.allocator)
	defer delete(cmp_csv)
	testing.expect(
		t,
		strings.contains(cmp_csv, "baseline,candidate,full_name,"),
		"comparison csv header",
	)
	testing.expect(
		t,
		strings.contains(cmp_csv, "c01,c02,core::op,100.000000,75.000000"),
		"comparison csv row",
	)

	json_1v1 := store.format_1v1_json(rep_1v1, context.allocator)
	defer delete(json_1v1)
	if parsed, p_err := json.parse(transmute([]u8)json_1v1, allocator = context.allocator);
	   p_err == .None {
		defer json.destroy_value(parsed, context.allocator)
		obj, is_obj := parsed.(json.Object)
		testing.expect(t, is_obj, "1v1 json root must be object")
		if is_obj {
			testing.expect_value(t, obj["lang_a"].(json.String) or_else "", "odin")
			testing.expect_value(t, obj["lang_b"].(json.String) or_else "", "zig")
			rows_arr, has_rows := obj["rows"].(json.Array)
			testing.expect(t, has_rows && len(rows_arr) == 1, "expected 1 1v1 row")
			if has_rows && len(rows_arr) == 1 {
				row_obj := rows_arr[0].(json.Object)
				testing.expect_value(t, row_obj["faster_lang"].(json.String) or_else "", "odin")
				testing.expect_value(
					t,
					row_obj["footprint_mismatch"].(json.Boolean) or_else false,
					true,
				)
			}
		}
	} else {
		testing.expectf(t, false, "1v1 json failed to parse: %v", p_err)
	}

	csv_1v1 := store.format_1v1_csv(rep_1v1, context.allocator)
	defer delete(csv_1v1)
	testing.expect(t, strings.contains(csv_1v1, "lang_a,lang_b,full_name,"), "1v1 csv header")
	testing.expect(
		t,
		strings.contains(csv_1v1, "odin,zig,core::op,10,50.000000,0.000000,100.000000"),
		"1v1 csv row",
	)

	// 6. Wildcard "--lang all" loads snapshot and commit-series across multiple languages.
	st_multi, m_ok := store.store_open(":memory:", context.allocator)
	testing.expect(t, m_ok, "open in-memory store for wildcard lang test")
	if m_ok {
		defer store.store_close(&st_multi)
		p_odin := _make_store_test_packet("r-o1", "ml01", 40.0)
		defer hugi.packet_destroy(&p_odin)
		p_zig := _make_store_test_packet("r-z1", "ml01", 80.0)
		defer hugi.packet_destroy(&p_zig)
		delete(p_zig.lang)
		p_zig.lang = strings.clone("zig")

		testing.expect(t, store.store_ingest_packet(&st_multi, p_odin), "ingest odin packet")
		testing.expect(t, store.store_ingest_packet(&st_multi, p_zig), "ingest zig packet")

		all_snap := store.store_load_pooled_records(&st_multi, "all")
		defer store.pooled_records_destroy(all_snap)
		testing.expect_value(t, len(all_snap), 6)
		if len(all_snap) == 6 {
			testing.expect_value(t, all_snap[0].lang, "odin")
			testing.expect_value(t, all_snap[2].lang, "odin")
			testing.expect_value(t, all_snap[3].lang, "zig")
			testing.expect_value(t, all_snap[5].lang, "zig")
		}

		all_series := store.store_load_commit_series_records(&st_multi, "*")
		defer store.pooled_records_destroy(all_series)
		testing.expect_value(t, len(all_series), 6)
	}
}
