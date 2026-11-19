package main

import obench "../../deps/obench/obench"
import hugi "../../hugi"
import store "../../store"
import "core:fmt"
import "core:os"
import "core:strings"

@(private = "file")
_render_grouped_markdown :: proc(
	records: []store.Pooled_Record,
	allocator := context.allocator,
) -> string {
	group_order := make([dynamic]string, context.temp_allocator)
	by_group := make(map[string][dynamic]store.Pooled_Record, context.temp_allocator)
	defer {
		for _, &rows in by_group {
			delete(rows)
		}
		delete(by_group)
		delete(group_order)
	}

	for r in records {
		g := r.group_name != "" ? r.group_name : "default"
		if g not_in by_group {
			append(&group_order, g)
			by_group[g] = make([dynamic]store.Pooled_Record, context.temp_allocator)
		}
		arr := by_group[g]
		append(&arr, r)
		by_group[g] = arr
	}

	sb := strings.builder_make(allocator)
	for g, gi in group_order {
		if gi > 0 {
			strings.write_byte(&sb, '\n')
		}
		rows := by_group[g]
		fmt.sbprintf(&sb, "### Group: `%s` (%d benchmarks)\n\n", g, len(rows))
		strings.write_string(
			&sb,
			"| Benchmark | Median | Mean ± σ | P95 | Throughput | Allocs/op |\n",
		)
		strings.write_string(&sb, "| :--- | ---: | ---: | ---: | ---: | ---: |\n")
		for r in rows {
			med_str := hugi.format_duration_fs(r.p50_fs, context.temp_allocator)
			mean_str := hugi.format_duration_fs(r.mean_fs, context.temp_allocator)
			std_str := hugi.format_duration_fs(r.std_dev_fs, context.temp_allocator)
			p95_str := hugi.format_duration_fs(r.p95_fs, context.temp_allocator)
			tp_str := fmt.tprintf("%.0f ops/s", r.ops_per_sec)
			if r.bytes_per_op > 0 && r.mb_per_sec > 0 {
				tp_str = fmt.tprintf("%.1f MB/s", r.mb_per_sec)
			}
			alloc_str := "0"
			if r.allocs_per_op > 0 || r.alloc_bytes_per_op > 0 {
				alloc_str = fmt.tprintf(
					"%.1f (%s)",
					r.allocs_per_op,
					obench.format_bytes(r.alloc_bytes_per_op, context.temp_allocator),
				)
			}
			label := r.full_name
			prefix := fmt.tprintf("%s::", g)
			if strings.has_prefix(label, prefix) {
				label = label[len(prefix):]
			}
			fmt.sbprintf(
				&sb,
				"| `%s` | **%s** | %s ± %s | %s | %s | %s |\n",
				label,
				med_str,
				mean_str,
				std_str,
				p95_str,
				tp_str,
				alloc_str,
			)
		}
	}
	return strings.to_string(sb)
}

main :: proc() {
	db_path := ".tmp/example.hugidb"
	lang := "odin"
	commit := ""
	readme_path := ""

	args := os.args[1:] if len(os.args) > 1 else nil
	i := 0
	for i < len(args) {
		switch args[i] {
		case "--db":
			if i + 1 >= len(args) {
				fmt.eprintln("custom_markdown_odin: missing value for --db")
				os.exit(1)
			}
			db_path = args[i + 1]
			i += 2
		case "--lang":
			if i + 1 >= len(args) {
				fmt.eprintln("custom_markdown_odin: missing value for --lang")
				os.exit(1)
			}
			lang = args[i + 1]
			i += 2
		case "--commit":
			if i + 1 >= len(args) {
				fmt.eprintln("custom_markdown_odin: missing value for --commit")
				os.exit(1)
			}
			commit = args[i + 1]
			i += 2
		case "--update-readme":
			if i + 1 >= len(args) {
				fmt.eprintln("custom_markdown_odin: missing value for --update-readme")
				os.exit(1)
			}
			readme_path = args[i + 1]
			i += 2
		case "-h", "--help":
			fmt.println(
				"Usage: custom_markdown_odin [--db <path>] [--lang <lang>] [--commit <sha>] [--update-readme <path>]",
			)
			return
		case:
			fmt.eprintfln("custom_markdown_odin: unknown argument '%s'", args[i])
			os.exit(1)
		}
	}

	st, ok := store.store_open(db_path, context.allocator)
	if !ok {
		fmt.eprintfln("custom_markdown_odin: could not open '%s'", db_path)
		os.exit(1)
	}
	defer store.store_close(&st)

	records := store.store_load_pooled_records(&st, lang, commit, "", "", context.allocator)
	defer store.pooled_records_destroy(records)
	if len(records) == 0 {
		fmt.eprintfln("custom_markdown_odin: no matching records in '%s'", db_path)
		os.exit(1)
	}

	md := _render_grouped_markdown(records, context.allocator)
	defer delete(md)

	if readme_path != "" {
		if !store.update_readme_markers(readme_path, md) {
			fmt.eprintfln("custom_markdown_odin: failed updating markers in '%s'", readme_path)
			os.exit(1)
		}
		fmt.printfln("Updated %s (%d records)", readme_path, len(records))
		return
	}

	fmt.print(md)
}
