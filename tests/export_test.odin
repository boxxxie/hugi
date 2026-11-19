package hugi_tests

import skadi "../deps/skadi/skadi"
import hugi "../hugi"
import store "../store"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_exporters_arrow_readme_and_compact :: proc(t: ^testing.T) {
	tmp_dir, t_err := os.temp_directory(context.temp_allocator)
	if t_err != nil || tmp_dir == "" {
		tmp_dir = "/tmp"
	}
	pid := os.get_pid()
	db_path := fmt.aprintf("%s/hugi_test_%d.hugidb", tmp_dir, pid)
	arrow_path := fmt.aprintf("%s/hugi_test_%d.arrow", tmp_dir, pid)
	arrow_raw_path := fmt.aprintf("%s/hugi_test_raw_%d.arrow", tmp_dir, pid)
	parquet_path := fmt.aprintf("%s/hugi_test_%d.parquet", tmp_dir, pid)
	parquet_raw_path := fmt.aprintf("%s/hugi_test_raw_%d.parquet", tmp_dir, pid)
	json_path := fmt.aprintf("%s/hugi_test_%d.json", tmp_dir, pid)
	jsonl_path := fmt.aprintf("%s/hugi_test_%d.jsonl", tmp_dir, pid)
	csv_path := fmt.aprintf("%s/hugi_test_%d.csv", tmp_dir, pid)
	tsv_path := fmt.aprintf("%s/hugi_test_%d.tsv", tmp_dir, pid)
	md_path := fmt.aprintf("%s/hugi_test_%d.md", tmp_dir, pid)
	readme_path := fmt.aprintf("%s/hugi_readme_%d.md", tmp_dir, pid)
	defer {
		for p in ([]string{db_path, arrow_path, arrow_raw_path, parquet_path, parquet_raw_path, json_path, jsonl_path, csv_path, tsv_path, md_path, readme_path}) {
			if os.exists(p) {
				_ = os.remove(p)
			}
			delete(p)
		}
	}

	{
		st, open_ok := store.store_open(db_path)
		testing.expect(t, open_ok, "file store should open")
		p1 := _make_packet(
			"exp001",
			"odin",
			"r-exp-1",
			"suite",
			[]string{"op_a", "op_b"},
			[]f64{80.0, 220.0},
			[]u64{1024, 4096},
		)
		testing.expect(t, store.store_ingest_packet(&st, p1), "ingest for export test")
		hugi.packet_destroy(&p1)

		p2 := _make_packet(
			"exp002",
			"odin",
			"r-exp-2",
			"suite",
			[]string{"op_a"},
			[]f64{75.0},
			[]u64{1024},
			selective = true,
		)
		testing.expect(t, store.store_ingest_packet(&st, p2), "second ingest before compact")
		hugi.packet_destroy(&p2)

		records := store.store_load_pooled_records(&st, "odin")
		testing.expect_value(t, len(records), 2)

		testing.expect(
			t,
			store.export_arrow_ipc(arrow_path, records),
			"arrow export should succeed",
		)
		testing.expect(
			t,
			store.export_arrow_ipc(arrow_raw_path, records, .None),
			"uncompressed arrow export should succeed",
		)
		testing.expect(
			t,
			store.export_parquet(parquet_path, records),
			"parquet export should succeed",
		)
		testing.expect(
			t,
			store.export_parquet(parquet_raw_path, records, false),
			"uncompressed parquet export should succeed",
		)
		testing.expect(t, store.export_json(json_path, records), "json export should succeed")
		testing.expect(t, store.export_jsonl(jsonl_path, records), "jsonl export should succeed")
		testing.expect(t, store.export_csv(csv_path, records), "csv export should succeed")
		testing.expect(t, store.export_tsv(tsv_path, records), "tsv export should succeed")
		testing.expect(
			t,
			store.export_markdown(md_path, records),
			"markdown export should succeed",
		)

		// Verify TSV structure.
		if tsv_bytes, t_err2 := os.read_entire_file(tsv_path, context.allocator); t_err2 == nil {
			defer delete(tsv_bytes)
			tsv_str := string(tsv_bytes)
			testing.expect(
				t,
				strings.contains(tsv_str, "commit\tlang\tsuite_name\tgroup_name"),
				"tsv header uses canonical column names and tabs",
			)
			testing.expect(t, strings.contains(tsv_str, "\tcore::op_a\t"), "tsv contains op_a")
			testing.expect(t, strings.contains(tsv_str, "\tcore::op_b\t"), "tsv contains op_b")
		}

		// Verify JSON structure.
		if json_bytes, j_err := os.read_entire_file(json_path, context.allocator); j_err == nil {
			defer delete(json_bytes)
			parsed, p_err := json.parse(json_bytes, allocator = context.allocator)
			testing.expect_value(t, p_err, json.Error.None)
			if p_err == .None {
				defer json.destroy_value(parsed, context.allocator)
				arr, is_arr := parsed.(json.Array)
				testing.expect(t, is_arr && len(arr) == 2, "json export must be a 2-element array")
			}
		}

		// Verify Parquet magic & footer framing (plus uncompressed & empty exports).
		if pq_bytes, pq_err := os.read_entire_file(parquet_path, context.allocator);
		   pq_err == nil {
			defer delete(pq_bytes)
			n := len(pq_bytes)
			testing.expect(t, n > 16, "parquet file should be non-empty")
			if n > 16 {
				testing.expect_value(t, string(pq_bytes[:4]), "PAR1")
				testing.expect_value(t, string(pq_bytes[n - 4:]), "PAR1")
			}
		}
		if pq_raw_bytes, pq_raw_err := os.read_entire_file(parquet_raw_path, context.allocator);
		   pq_raw_err == nil {
			defer delete(pq_raw_bytes)
			n := len(pq_raw_bytes)
			testing.expect(
				t,
				n > 16 &&
				string(pq_raw_bytes[:4]) == "PAR1" &&
				string(pq_raw_bytes[n - 4:]) == "PAR1",
			)
		}
		testing.expect(
			t,
			store.export_parquet(parquet_raw_path, nil),
			"empty parquet export should succeed",
		)
		if pq_empty_bytes, pq_e_err := os.read_entire_file(parquet_raw_path, context.allocator);
		   pq_e_err == nil {
			defer delete(pq_empty_bytes)
			n := len(pq_empty_bytes)
			testing.expect(
				t,
				n > 12 &&
				string(pq_empty_bytes[:4]) == "PAR1" &&
				string(pq_empty_bytes[n - 4:]) == "PAR1",
			)
		}

		// Verify uncompressed Arrow IPC path too.
		sc_raw, bs_raw, read_raw_ok := skadi.ipc_read_file(
			arrow_raw_path,
			context.allocator,
			true,
			true,
		)
		testing.expect(t, read_raw_ok, "uncompressed arrow file should decode cleanly")
		if read_raw_ok {
			for &b in bs_raw {
				skadi.record_batch_free(&b)
			}
			delete(bs_raw)
			if sc_raw != nil {
				skadi.schema_free(sc_raw)
				free(sc_raw)
			}
		}

		// Verify Arrow IPC file round-trip via Skadi.
		schema, batches, read_ok := skadi.ipc_read_file(arrow_path, context.allocator, true, false)
		testing.expect(t, read_ok, "skadi.ipc_read_file should decode exported Arrow file")
		if read_ok {
			defer {
				for &b in batches {
					skadi.record_batch_free(&b)
				}
				delete(batches)
				if schema != nil {
					skadi.schema_free(schema)
					free(schema)
				}
			}
			testing.expect_value(t, len(batches), 1)
			if len(batches) > 0 && len(records) > 0 {
				testing.expect_value(t, batches[0].length, 2)
				name_col := skadi.record_batch_column(&batches[0], "full_name")
				testing.expect(t, name_col != nil, "full_name column should exist")
				if name_col != nil && batches[0].length > 0 {
					testing.expect_value(
						t,
						skadi.array_get_string(name_col, 0),
						records[0].full_name,
					)
				}
				p50_col := skadi.record_batch_column(&batches[0], "p50_ns")
				testing.expect(t, p50_col != nil, "p50_ns column should exist")
				if p50_col != nil && batches[0].length > 0 {
					testing.expect_value(
						t,
						p50_col.type,
						skadi.DataType(skadi.Decimal64_Type{precision = 18, scale = 6}),
					)
					testing.expect_value(t, skadi.array_get(p50_col, 0, i64), records[0].p50_fs)
				}
				rid_col := skadi.record_batch_column(&batches[0], "run_id")
				testing.expect(t, rid_col != nil, "run_id column should exist")
				if rid_col != nil && batches[0].length > 0 && len(records[0].run_ids) > 0 {
					testing.expect_value(
						t,
						skadi.array_get_string(rid_col, 0),
						records[0].run_ids[len(records[0].run_ids) - 1],
					)
				}
				ts_col := skadi.record_batch_column(&batches[0], "timestamp_unix")
				testing.expect(t, ts_col != nil, "timestamp_unix column should exist")
				if ts_col != nil && batches[0].length > 0 {
					testing.expect_value(
						t,
						skadi.array_get(ts_col, 0, i64),
						records[0].timestamp_unix,
					)
				}
				blob_col := skadi.record_batch_column(&batches[0], "samples_blob")
				testing.expect(t, blob_col != nil, "samples_blob column should exist")
				if blob_col != nil && batches[0].length > 0 {
					raw_blob := skadi.array_get_binary(blob_col, 0)
					back_samples, d_ok := store.decompress_exported_samples_fs(
						raw_blob,
						records[0].ops_per_sample,
					)
					defer delete(back_samples)
					testing.expect(t, d_ok, "Arrow samples_blob should decompress")
					testing.expect_value(t, len(back_samples), len(records[0].samples_fs))
					for si in 0 ..< min(len(back_samples), len(records[0].samples_fs)) {
						testing.expect_value(t, back_samples[si], records[0].samples_fs[si])
					}
				}
			}
		}

		// Verify README marker updater.
		seed_readme := "# Header\n\n<!-- BEGIN_BENCHMARK_TABLE -->\nstale\n<!-- END_BENCHMARK_TABLE -->\n\n# Footer\n"
		testing.expect(
			t,
			os.write_entire_file(readme_path, transmute([]u8)seed_readme) == nil,
			"write seed README",
		)
		md_block := store.format_markdown_table(records)
		defer delete(md_block)
		testing.expect(
			t,
			store.update_readme_markers(readme_path, md_block),
			"update README markers",
		)

		updated_bytes, u_err := os.read_entire_file(readme_path, context.allocator)
		testing.expect(t, u_err == nil, "read updated README")
		if u_err == nil {
			defer delete(updated_bytes)
			updated := string(updated_bytes)
			testing.expect(t, strings.contains(updated, "# Header"), "preserve header")
			testing.expect(t, strings.contains(updated, "core::op_a"), "inject table content")
			testing.expect(t, !strings.contains(updated, "\nstale\n"), "replace stale block")
		}

		store.pooled_records_destroy(records)
		store.store_close(&st)
	}

	before, after, c_ok := store.store_compact(db_path)
	testing.expect(t, c_ok, "store_compact should succeed")
	testing.expect(
		t,
		before > 0 && after > 0 && after < before,
		"compacted store must shrink and stay non-empty",
	)

	st2, open2_ok := store.store_open(db_path)
	testing.expect(t, open2_ok, "reopening compacted store should succeed")
	defer store.store_close(&st2)
	commits := store.store_list_commits(&st2)
	defer store.commit_summaries_destroy(commits)
	testing.expect_value(t, len(commits), 2)

	post_compact := store.store_load_pooled_records(&st2, "odin")
	defer store.pooled_records_destroy(post_compact)
	testing.expect_value(t, len(post_compact), 2)
	if len(post_compact) == 2 {
		testing.expect_value(t, post_compact[0].full_name, "core::op_a")
		testing.expect_value(t, post_compact[0].commit, "exp002")
		testing.expect(
			t,
			math.abs(hugi.fs_to_ns_f64(post_compact[0].p50_fs) - 75.0) < 2.0,
			"op_a median ~75ns",
		)
		testing.expect_value(t, post_compact[1].full_name, "core::op_b")
		testing.expect_value(t, post_compact[1].commit, "exp001")
		testing.expect(
			t,
			math.abs(hugi.fs_to_ns_f64(post_compact[1].p50_fs) - 220.0) < 2.0,
			"op_b median ~220ns",
		)
	}
}

@(private = "file")
_extract_parquet_leaf_columns :: proc(
	pq_bytes: []u8,
	allocator := context.allocator,
) -> (
	cols: []string,
	ok: bool,
) {
	n := len(pq_bytes)
	if n < 12 || string(pq_bytes[:4]) != "PAR1" || string(pq_bytes[n - 4:]) != "PAR1" {
		return nil, false
	}
	flen_bytes: [4]u8
	copy(flen_bytes[:], pq_bytes[n - 8:n - 4])
	flen := int(u32(transmute(u32le)flen_bytes))
	if flen <= 0 || flen > n - 12 {
		return nil, false
	}
	footer := pq_bytes[n - 8 - flen:n - 8]
	pos := 0

	read_u8 :: proc(data: []u8, pos: ^int) -> (u8, bool) {
		if pos^ >= len(data) {
			return 0, false
		}
		v := data[pos^]
		pos^ += 1
		return v, true
	}
	read_varint :: proc(data: []u8, pos: ^int) -> (val: u64, ok: bool) {
		shift: uint = 0
		for shift < 64 {
			b := read_u8(data, pos) or_return
			val |= u64(b & 0x7F) << shift
			if (b & 0x80) == 0 {
				return val, true
			}
			shift += 7
		}
		return 0, false
	}
	read_field_hdr :: proc(
		data: []u8,
		pos: ^int,
		prev: ^i32,
	) -> (
		fid: i32,
		ftype: u8,
		stop: bool,
		ok: bool,
	) {
		b := read_u8(data, pos) or_return
		if b == 0 {
			return 0, 0, true, true
		}
		delta := i32((b >> 4) & 0x0F)
		ftype = b & 0x0F
		if delta == 0 {
			zz := u16(read_varint(data, pos) or_return)
			fid = i32(i16((zz >> 1) ~ u16(-i16(zz & 1))))
		} else {
			fid = prev^ + delta
		}
		prev^ = fid
		return fid, ftype, false, true
	}

	fprev: i32 = 0
	for {
		fid, ftype, stop, h_ok := read_field_hdr(footer, &pos, &fprev)
		if !h_ok {
			return nil, false
		}
		if stop {
			break
		}
		if fid == 2 && ftype == 9 {
			lh := read_u8(footer, &pos) or_return
			cnt := int(lh >> 4)
			elem_type := lh & 0x0F
			if cnt == 15 {
				c64 := read_varint(footer, &pos) or_return
				cnt = int(c64)
			}
			if elem_type != 12 || cnt < 1 {
				return nil, false
			}
			out := make([dynamic]string, 0, cnt - 1, allocator)
			defer if !ok {
				for s in out {
					delete(s, allocator)
				}
				delete(out)
			}
			for elem_idx in 0 ..< cnt {
				sprev: i32 = 0
				elem_name := ""
				for {
					sfid, sftype, sstop, sh_ok := read_field_hdr(footer, &pos, &sprev)
					if !sh_ok {
						return nil, false
					}
					if sstop {
						break
					}
					switch sftype {
					case 5, 6:
						_ = read_varint(footer, &pos) or_return
					case 8:
						slen := int(read_varint(footer, &pos) or_return)
						if slen < 0 || pos + slen > len(footer) {
							return nil, false
						}
						if sfid == 4 {
							elem_name = string(footer[pos:pos + slen])
						}
						pos += slen
					case:
						return nil, false
					}
				}
				if elem_idx > 0 {
					append(&out, strings.clone(elem_name, allocator))
				}
			}
			ok = true
			return out[:], true
		}
		if ftype == 5 || ftype == 6 {
			_ = read_varint(footer, &pos) or_return
		} else {
			break
		}
	}
	return nil, false
}

@(private = "file")
_extract_first_json_object_keys :: proc(text: string, allocator := context.allocator) -> []string {
	keys := make([dynamic]string, allocator)
	obj_start := strings.index_byte(text, '{')
	if obj_start < 0 {
		return keys[:]
	}
	brace_depth := 0
	bracket_depth := 0
	i := obj_start
	for i < len(text) {
		ch := text[i]
		switch ch {
		case '{':
			brace_depth += 1
			i += 1
		case '}':
			brace_depth -= 1
			i += 1
			if brace_depth == 0 {
				return keys[:]
			}
		case '[':
			bracket_depth += 1
			i += 1
		case ']':
			bracket_depth -= 1
			i += 1
		case '"':
			j := i + 1
			for j < len(text) {
				if text[j] == '\\' {
					j += 2
					continue
				}
				if text[j] == '"' {
					break
				}
				j += 1
			}
			str_val := text[i + 1:min(j, len(text))]
			i = j + 1
			if brace_depth == 1 && bracket_depth == 0 {
				k := i
				for k < len(text) && (text[k] == ' ' || text[k] == '\t') {
					k += 1
				}
				if k < len(text) && text[k] == ':' {
					append(&keys, strings.clone(str_val, allocator))
				}
			}
		case:
			i += 1
		}
	}
	return keys[:]
}

@(test)
test_export_schema_parity_all_formats :: proc(t: ^testing.T) {
	if !os.exists(".tmp") {
		_ = os.make_directory(".tmp")
	}
	pid := os.get_pid()
	arrow_path := fmt.aprintf(".tmp/schema_parity_%d.arrow", pid)
	parquet_path := fmt.aprintf(".tmp/schema_parity_%d.parquet", pid)
	csv_path := fmt.aprintf(".tmp/schema_parity_%d.csv", pid)
	tsv_path := fmt.aprintf(".tmp/schema_parity_%d.tsv", pid)
	json_path := fmt.aprintf(".tmp/schema_parity_%d.json", pid)
	jsonl_path := fmt.aprintf(".tmp/schema_parity_%d.jsonl", pid)
	defer {
		for p in ([]string{arrow_path, parquet_path, csv_path, tsv_path, json_path, jsonl_path}) {
			if os.exists(p) {
				_ = os.remove(p)
			}
			delete(p)
		}
	}

	st, ok := store.store_open(":memory:")
	testing.expect(t, ok, "open in-memory store for schema parity")
	if !ok {
		return
	}
	defer store.store_close(&st)

	pkt := _make_packet(
		"par001",
		"odin",
		"run-par-1",
		"parity_suite",
		[]string{"alpha", "beta"},
		[]f64{80.0, 210.0},
		[]u64{1024, 4096},
	)
	pkt.records[0].temp_allocs_per_op = 1.5
	pkt.records[0].temp_bytes_per_op = 48.0
	pkt.records[0].peak_heap_bytes = 2048
	defer hugi.packet_destroy(&pkt)
	testing.expect(t, store.store_ingest_packet(&st, pkt), "ingest parity packet")

	records := store.store_load_pooled_records(&st, "odin")
	defer store.pooled_records_destroy(records)
	testing.expect_value(t, len(records), 2)

	testing.expect(t, store.export_arrow_ipc(arrow_path, records), "arrow parity export")
	testing.expect(t, store.export_parquet(parquet_path, records), "parquet parity export")
	testing.expect(t, store.export_csv(csv_path, records), "csv parity export")
	testing.expect(t, store.export_tsv(tsv_path, records), "tsv parity export")
	testing.expect(t, store.export_json(json_path, records), "json parity export")
	testing.expect(t, store.export_jsonl(jsonl_path, records), "jsonl parity export")

	// 1. Arrow IPC: exact 35 columns (34 canonical scalar + samples_blob).
	sc, bs, arrow_ok := skadi.ipc_read_file(arrow_path, context.allocator, true, false)
	testing.expect(t, arrow_ok, "read parity arrow")
	if arrow_ok {
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
		for i in 0 ..< min(len(sc.fields), store.EXPORT_TOTAL_COL_COUNT) {
			testing.expect_value(t, sc.fields[i].name, store.EXPORT_COLUMNS[i].name)
		}
	}

	// 2. Parquet: exact 35 columns (34 canonical scalar + samples_blob).
	if pq_bytes, pq_err := os.read_entire_file(parquet_path, context.allocator); pq_err == nil {
		defer delete(pq_bytes)
		pq_cols, pq_ok := _extract_parquet_leaf_columns(pq_bytes, context.allocator)
		testing.expect(t, pq_ok, "parse parquet schema leaves")
		if pq_ok {
			defer {
				for c in pq_cols {
					delete(c)
				}
				delete(pq_cols)
			}
			testing.expect_value(t, len(pq_cols), store.EXPORT_TOTAL_COL_COUNT)
			for i in 0 ..< min(len(pq_cols), store.EXPORT_TOTAL_COL_COUNT) {
				testing.expect_value(t, pq_cols[i], store.EXPORT_COLUMNS[i].name)
			}
		}
	}

	// 3. CSV and TSV: exact 34 canonical scalar columns in canonical order.
	verify_delimited :: proc(
		t: ^testing.T,
		path: string,
		delim: string,
		label: string,
		loc := #caller_location,
	) {
		raw, err := os.read_entire_file(path, context.allocator)
		testing.expectf(t, err == nil, "%s read", label, loc = loc)
		if err != nil {
			return
		}
		defer delete(raw)
		lines := strings.split_lines(string(raw), context.temp_allocator)
		testing.expectf(t, len(lines) >= 3, "%s lines >= 3", label, loc = loc)
		if len(lines) < 3 {
			return
		}
		hdr := strings.split(lines[0], delim, context.temp_allocator)
		testing.expect_value(t, len(hdr), store.EXPORT_SCALAR_COL_COUNT, loc = loc)
		for i in 0 ..< min(len(hdr), store.EXPORT_SCALAR_COL_COUNT) {
			testing.expect_value(t, hdr[i], store.EXPORT_COLUMNS[i].name, loc = loc)
		}
		row1 := strings.split(lines[1], delim, context.temp_allocator)
		testing.expect_value(t, len(row1), store.EXPORT_SCALAR_COL_COUNT, loc = loc)
	}
	verify_delimited(t, csv_path, ",", "csv")
	verify_delimited(t, tsv_path, "\t", "tsv")

	// 4. JSON and JSONL: exact 34 canonical scalar keys in order + samples_batch_ns + samples_ns.
	verify_json_keys :: proc(t: ^testing.T, path: string, label: string, loc := #caller_location) {
		raw, err := os.read_entire_file(path, context.allocator)
		testing.expectf(t, err == nil, "%s read", label, loc = loc)
		if err != nil {
			return
		}
		defer delete(raw)
		keys := _extract_first_json_object_keys(string(raw), context.allocator)
		defer {
			for k in keys {
				delete(k)
			}
			delete(keys)
		}
		testing.expect_value(t, len(keys), store.EXPORT_SCALAR_COL_COUNT + 2, loc = loc)
		for i in 0 ..< min(len(keys), store.EXPORT_SCALAR_COL_COUNT) {
			testing.expect_value(t, keys[i], store.EXPORT_COLUMNS[i].name, loc = loc)
		}
		if len(keys) == store.EXPORT_SCALAR_COL_COUNT + 2 {
			testing.expect_value(
				t,
				keys[store.EXPORT_SCALAR_COL_COUNT],
				"samples_batch_ns",
				loc = loc,
			)
			testing.expect_value(
				t,
				keys[store.EXPORT_SCALAR_COL_COUNT + 1],
				"samples_ns",
				loc = loc,
			)
		}
	}
	verify_json_keys(t, json_path, "json")
	verify_json_keys(t, jsonl_path, "jsonl")
}
