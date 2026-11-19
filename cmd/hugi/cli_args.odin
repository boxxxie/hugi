package hugi_cli

import store "../../store"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

@(private)
_Common_Flag :: enum u8 {
	DB,
	Lang,
	Commit,
	Filter,
	Threshold,
}

@(private)
_Common_Flag_Set :: bit_set[_Common_Flag;u8]

@(private)
_Common_Opts :: struct {
	db_flag:       string,
	lang:          string,
	commit:        string,
	filter:        string,
	threshold_pct: f64,
}

@(private)
_Flag_Parse_Status :: enum u8 {
	Not_Matched,
	Matched,
	Help,
	Error,
}

@(private, require_results)
_normalize_lang :: proc(
	lang: string,
	allocator := context.allocator,
) -> (
	res: string,
	owned: bool,
) {
	for i := 0; i < len(lang); i += 1 {
		if lang[i] >= 'A' && lang[i] <= 'Z' {
			return strings.to_lower(lang, allocator), true
		}
	}
	return lang, false
}

@(private, require_results)
_resolve_db_path :: proc(explicit: string) -> string {
	if explicit != "" {
		return explicit
	}
	if cfg_dir, _, cfg, cfg_ok := _read_nearest_project_config("."); cfg_ok && cfg.db != "" {
		return _resolve_config_path(cfg_dir, cfg.db, context.temp_allocator)
	}
	if os.is_dir("benchmarks") {
		if !os.exists("benchmarks/history.hugidb") && os.exists("benchmarks/history.benchdb") {
			return "benchmarks/history.benchdb"
		}
		return "benchmarks/history.hugidb"
	}
	return "history.hugidb"
}

@(private, require_results)
_parse_flag_kv :: proc(args: []string, idx: ^int) -> (key: string, val: string, is_flag: bool) {
	arg := args[idx^]
	if !strings.has_prefix(arg, "-") || arg == "-" {
		return "", "", false
	}
	idx^ += 1
	trimmed := strings.trim_left(arg, "-")
	if sep := strings.index_any(trimmed, "=:"); sep >= 0 {
		return trimmed[:sep], trimmed[sep + 1:], true
	}
	return trimmed, "", true
}

@(private, require_results)
_consume_value :: proc(
	args: []string,
	idx: ^int,
	inline_val: string,
	flag_name: string,
) -> (
	val: string,
	ok: bool,
) {
	if inline_val != "" {
		return inline_val, true
	}
	if idx^ >= len(args) {
		fmt.eprintfln("hugi: missing value for --%s", flag_name)
		return "", false
	}
	v := args[idx^]
	idx^ += 1
	return v, true
}

@(private, require_results)
_try_parse_common_flag :: proc(
	cmd_name: string,
	key: string,
	inline_val: string,
	args: []string,
	idx: ^int,
	allowed: _Common_Flag_Set,
	opts: ^_Common_Opts,
) -> _Flag_Parse_Status {
	switch key {
	case "h", "help":
		return .Help
	case "db":
		if .DB not_in allowed {
			return .Not_Matched
		}
		v, ok := _consume_value(args, idx, inline_val, key)
		if !ok {
			return .Error
		}
		opts.db_flag = v
		return .Matched
	case "lang":
		if .Lang not_in allowed {
			return .Not_Matched
		}
		v, ok := _consume_value(args, idx, inline_val, key)
		if !ok {
			return .Error
		}
		opts.lang = v
		return .Matched
	case "commit":
		if .Commit not_in allowed {
			return .Not_Matched
		}
		v, ok := _consume_value(args, idx, inline_val, key)
		if !ok {
			return .Error
		}
		opts.commit = v
		return .Matched
	case "filter", "f":
		if .Filter not_in allowed {
			return .Not_Matched
		}
		v, ok := _consume_value(args, idx, inline_val, key)
		if !ok {
			return .Error
		}
		opts.filter = v
		return .Matched
	case "threshold":
		if .Threshold not_in allowed {
			return .Not_Matched
		}
		v, ok := _consume_value(args, idx, inline_val, key)
		if !ok {
			return .Error
		}
		parsed, p_ok := strconv.parse_f64(v)
		if !p_ok || parsed < 0 {
			fmt.eprintfln("hugi %s: invalid --threshold '%s'", cmd_name, v)
			return .Error
		}
		opts.threshold_pct = parsed
		return .Matched
	}
	return .Not_Matched
}

@(private, require_results)
_parse_nonneg_int_flag :: proc(
	cmd_name: string,
	flag_name: string,
	args: []string,
	idx: ^int,
	inline_val: string,
) -> (
	val: int,
	ok: bool,
) {
	v, v_ok := _consume_value(args, idx, inline_val, flag_name)
	if !v_ok {
		return 0, false
	}
	n, n_ok := strconv.parse_int(v)
	if !n_ok || n < 0 {
		fmt.eprintfln("hugi %s: invalid --%s '%s'", cmd_name, flag_name, v)
		return 0, false
	}
	return n, true
}

@(private, require_results)
_split_range :: proc(s: string) -> (a: string, b: string, ok: bool) {
	if idx := strings.index(s, ".."); idx >= 0 {
		left := strings.trim_space(s[:idx])
		right := strings.trim_space(s[idx + 2:])
		if left != "" && right != "" {
			return left, right, true
		}
	}
	return "", "", false
}

@(private, require_results)
_file_has_packet_magic :: proc(path: string) -> bool {
	f, err := os.open(path, {.Read})
	if err != nil {
		return false
	}
	defer os.close(f)
	hdr: [4]u8
	n, r_err := os.read(f, hdr[:])
	return r_err == nil && n == 4 && string(hdr[:]) == "HPKT"
}

@(private, require_results)
_infer_export_format :: proc(format, out_path, readme_path: string) -> string {
	fmt_out := strings.to_lower(format, context.temp_allocator)
	if fmt_out == "" && out_path != "" {
		ext := strings.to_lower(filepath.ext(out_path), context.temp_allocator)
		switch ext {
		case ".arrow", ".feather", ".ipc":
			fmt_out = "arrow"
		case ".parquet", ".pq":
			fmt_out = "parquet"
		case ".json":
			fmt_out = "json"
		case ".jsonl", ".ndjson":
			fmt_out = "jsonl"
		case ".csv":
			fmt_out = "csv"
		case ".tsv", ".tab":
			fmt_out = "tsv"
		case ".md", ".markdown":
			fmt_out = "md"
		}
	}
	if fmt_out == "" && readme_path != "" {
		fmt_out = "md"
	}
	return fmt_out
}

@(private, require_results)
_infer_report_format :: proc(format, out_path: string) -> string {
	fmt_out := strings.to_lower(format, context.temp_allocator)
	if fmt_out == "markdown" {
		return "md"
	}
	if fmt_out == "" && out_path != "" && out_path != "-" {
		ext := strings.to_lower(filepath.ext(out_path), context.temp_allocator)
		switch ext {
		case ".json":
			return "json"
		case ".csv":
			return "csv"
		case ".md", ".markdown":
			return "md"
		}
	}
	if fmt_out == "" {
		return "md"
	}
	return fmt_out
}

@(private, require_results)
_split_shell_tokens :: proc(s: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	cur := strings.builder_make(allocator)
	has_tok := false
	quote: byte = 0

	for i := 0; i < len(s); i += 1 {
		b := s[i]
		if quote != 0 {
			if b == quote {
				quote = 0
				continue
			}
			if quote == '"' && b == '\\' && i + 1 < len(s) {
				next := s[i + 1]
				if next == '"' || next == '\\' {
					strings.write_byte(&cur, next)
					i += 1
					continue
				}
			}
			strings.write_byte(&cur, b)
			continue
		}

		if b == '\'' || b == '"' {
			quote = b
			has_tok = true
			continue
		}
		if b == ' ' || b == '\t' || b == '\n' || b == '\r' {
			if has_tok {
				append(&out, strings.clone(strings.to_string(cur), allocator))
				strings.builder_reset(&cur)
				has_tok = false
			}
			continue
		}
		strings.write_byte(&cur, b)
		has_tok = true
	}

	if has_tok {
		append(&out, strings.clone(strings.to_string(cur), allocator))
	}
	strings.builder_destroy(&cur)
	return out[:]
}

@(private, require_results)
_open_store_or_err :: proc(
	cmd_name: string,
	db_flag: string,
	allocator := context.allocator,
) -> (
	st: store.Store,
	db_path: string,
	ok: bool,
) {
	resolved := _resolve_db_path(db_flag)
	st, ok = store.store_open(resolved, allocator)
	if !ok {
		fmt.eprintfln("hugi %s: could not open store '%s'", cmd_name, resolved)
		return {}, resolved, false
	}
	return st, st.path, true
}
