package hugi

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

/*
Resolves the 12-character Git HEAD commit SHA by walking upward from `start_dir`.
Supports both standard `.git/` directories and Git worktree `.git` pointer files,
loose branch refs, and `packed-refs`. Returns `"unknown"` outside a Git repo.
*/
@(require_results)
resolve_git_commit :: proc(start_dir := ".", allocator := context.allocator) -> string {
	cur, abs_err := os.get_absolute_path(start_dir, context.temp_allocator)
	if abs_err != nil || cur == "" {
		cur = start_dir
	}

	git_dir := ""
	for cur != "" {
		candidate, _ := filepath.join({cur, ".git"}, context.temp_allocator)
		if os.is_directory(candidate) {
			git_dir = candidate
			break
		}
		if os.exists(candidate) {
			raw_ptr_file, read_err := os.read_entire_file(candidate, context.temp_allocator)
			if read_err == nil {
				line := strings.trim_space(string(raw_ptr_file))
				if strings.has_prefix(line, "gitdir:") {
					rel := strings.trim_space(line[len("gitdir:"):])
					if filepath.is_abs(rel) {
						git_dir = rel
					} else {
						git_dir, _ = filepath.join({cur, rel}, context.temp_allocator)
					}
					break
				}
			}
		}
		parent := filepath.dir(cur)
		if parent == cur || parent == "" {
			break
		}
		cur = parent
	}

	if git_dir == "" {
		return strings.clone("unknown", allocator)
	}

	common_dir := git_dir
	commondir_file, _ := filepath.join({git_dir, "commondir"}, context.temp_allocator)
	if c_bytes, c_err := os.read_entire_file(commondir_file, context.temp_allocator);
	   c_err == nil {
		rel_common := strings.trim_space(string(c_bytes))
		if rel_common != "" {
			if filepath.is_abs(rel_common) {
				common_dir = rel_common
			} else {
				common_dir, _ = filepath.join({git_dir, rel_common}, context.temp_allocator)
			}
		}
	}

	head_path, _ := filepath.join({git_dir, "HEAD"}, context.temp_allocator)
	head_bytes, head_err := os.read_entire_file(head_path, context.temp_allocator)
	if head_err != nil {
		return strings.clone("unknown", allocator)
	}
	head_str := strings.trim_space(string(head_bytes))

	if strings.has_prefix(head_str, "ref: ") {
		ref_rel := strings.trim_space(head_str[5:])
		for dir in ([?]string{git_dir, common_dir}) {
			ref_path, _ := filepath.join({dir, ref_rel}, context.temp_allocator)
			if ref_bytes, r_err := os.read_entire_file(ref_path, context.temp_allocator);
			   r_err == nil {
				sha := strings.trim_space(string(ref_bytes))
				if len(sha) > 12 {
					sha = sha[:12]
				}
				return strings.clone(sha, allocator)
			}
		}
		for dir in ([?]string{git_dir, common_dir}) {
			packed_path, _ := filepath.join({dir, "packed-refs"}, context.temp_allocator)
			if packed_bytes, p_err := os.read_entire_file(packed_path, context.temp_allocator);
			   p_err == nil {
				suffix := fmt.tprintf(" %s", ref_rel)
				lines := strings.split_lines(string(packed_bytes), context.temp_allocator)
				for line in lines {
					trimmed := strings.trim_space(line)
					if len(trimmed) == 0 ||
					   strings.has_prefix(trimmed, "#") ||
					   strings.has_prefix(trimmed, "^") {
						continue
					}
					if strings.has_suffix(trimmed, suffix) && len(trimmed) >= 12 {
						return strings.clone(trimmed[:12], allocator)
					}
				}
			}
		}
		return strings.clone("unknown", allocator)
	}

	if len(head_str) > 12 {
		head_str = head_str[:12]
	}
	if head_str == "" {
		head_str = "unknown"
	}
	return strings.clone(head_str, allocator)
}

/*
Returns a monotonic wall-clock run identifier `run-<unix_seconds>`.
*/
@(require_results)
default_run_id :: proc(allocator := context.allocator) -> string {
	unix_sec := i64(time.to_unix_nanoseconds(time.now())) / 1_000_000_000
	return strings.clone(fmt.tprintf("run-%d", unix_sec), allocator)
}
