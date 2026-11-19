package hugi_cli

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

@(private)
_Project_Config :: struct {
	db:                string `json:"db"`,
	pkg_dir:           string `json:"pkg_dir"`,
	runs:              int `json:"runs"`,
	warmup:            int `json:"warmup"`,
	extra_build_flags: string `json:"extra_build_flags"`,
}

@(private, require_results)
_read_nearest_project_config :: proc(
	start_dir: string,
) -> (
	cfg_dir: string,
	cfg_path: string,
	cfg: _Project_Config,
	ok: bool,
) {
	cur, abs_err := os.get_absolute_path(start_dir, context.temp_allocator)
	if abs_err != nil || cur == "" {
		cur = start_dir
	}
	if !os.is_dir(cur) {
		cur = filepath.dir(cur)
	}
	for cur != "" {
		cand_path, _ := filepath.join({cur, "hugi.json"}, context.temp_allocator)
		if os.exists(cand_path) {
			data, read_err := os.read_entire_file(cand_path, context.temp_allocator)
			parsed := _Project_Config {
				warmup = -1,
			}
			if read_err == nil &&
			   json.unmarshal(data, &parsed, allocator = context.temp_allocator) == nil {
				return cur, cand_path, parsed, true
			}
			break
		}
		git_marker, _ := filepath.join({cur, ".git"}, context.temp_allocator)
		if os.exists(git_marker) {
			break
		}
		parent := filepath.dir(cur)
		if parent == cur || parent == "." || parent == "" {
			break
		}
		cur = parent
	}
	return "", "", _Project_Config{warmup = -1}, false
}

@(private, require_results)
_resolve_config_path :: proc(
	cfg_dir: string,
	rel_or_abs: string,
	allocator := context.temp_allocator,
) -> string {
	if rel_or_abs == "" {
		return ""
	}
	if filepath.is_abs(rel_or_abs) || cfg_dir == "" {
		return strings.clone(rel_or_abs, allocator)
	}
	joined, _ := filepath.join({cfg_dir, rel_or_abs}, allocator)
	return joined
}
