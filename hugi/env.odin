package hugi

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

Run_Env :: struct {
	cpu_model:       string,
	governor:        string,
	scaling_max_khz: u64,
	cpuinfo_max_khz: u64,
	boost_state:     i8, // 0 = unknown, 1 = enabled, -1 = disabled
	build_flags:     string,
	runtime_version: string,
}

/*
Reports whether `e` has no populated provenance fields.
*/
run_env_is_empty :: proc "contextless" (e: Run_Env) -> bool {
	return(
		e.cpu_model == "" &&
		e.governor == "" &&
		e.scaling_max_khz == 0 &&
		e.cpuinfo_max_khz == 0 &&
		e.boost_state == 0 &&
		e.build_flags == "" &&
		e.runtime_version == "" \
	)
}

/*
Returns a deep copy of `e` with all strings allocated on `allocator`.
*/
@(require_results)
run_env_clone :: proc(e: Run_Env, allocator := context.allocator) -> Run_Env {
	return Run_Env {
		cpu_model = strings.clone(e.cpu_model, allocator),
		governor = strings.clone(e.governor, allocator),
		scaling_max_khz = e.scaling_max_khz,
		cpuinfo_max_khz = e.cpuinfo_max_khz,
		boost_state = e.boost_state,
		build_flags = strings.clone(e.build_flags, allocator),
		runtime_version = strings.clone(e.runtime_version, allocator),
	}
}

/*
Frees all owned string fields in `e` and zeroes the struct.
*/
run_env_destroy :: proc(e: ^Run_Env, allocator := context.allocator) {
	if e == nil {
		return
	}
	delete(e.cpu_model, allocator)
	delete(e.governor, allocator)
	delete(e.build_flags, allocator)
	delete(e.runtime_version, allocator)
	e^ = {}
}

@(private = "file", require_results)
_read_trimmed_sysfs :: proc(
	path: string,
	allocator := context.temp_allocator,
) -> (
	val: string,
	ok: bool,
) {
	raw, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return "", false
	}
	defer delete(raw, context.temp_allocator)
	trimmed := strings.trim_space(string(raw))
	if trimmed == "" {
		return "", false
	}
	return strings.clone(trimmed, allocator), true
}

@(private = "file", require_results)
_read_u64_sysfs :: proc(path: string) -> (val: u64, ok: bool) {
	s, s_ok := _read_trimmed_sysfs(path, context.temp_allocator)
	if !s_ok {
		return 0, false
	}
	defer delete(s, context.temp_allocator)
	parsed, p_ok := strconv.parse_u64(s)
	return parsed, p_ok
}

/*
Inspects host CPU model, cpufreq scaling limits, governor, and boost state.
Leaves unavailable fields empty/zero on unsupported platforms or restricted sandboxes.
*/
@(require_results)
collect_host_env :: proc(allocator := context.allocator) -> Run_Env {
	env := Run_Env{}
	when ODIN_OS == .Linux {
		if cpuinfo, err := os.read_entire_file("/proc/cpuinfo", context.temp_allocator);
		   err == nil {
			defer delete(cpuinfo, context.temp_allocator)
			txt := string(cpuinfo)
			for raw_line in strings.split_lines_iterator(&txt) {
				if strings.has_prefix(raw_line, "model name") {
					if colon := strings.index_byte(raw_line, ':'); colon >= 0 {
						model := strings.trim_space(raw_line[colon + 1:])
						if model != "" {
							env.cpu_model = strings.clone(model, allocator)
							break
						}
					}
				}
			}
		}

		if gov, g_ok := _read_trimmed_sysfs(
			"/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor",
			allocator,
		); g_ok {
			env.governor = gov
		}

		for i := 0; i < 128; i += 1 {
			cpu_dir := fmt.tprintf("/sys/devices/system/cpu/cpu%d", i)
			if !os.is_directory(cpu_dir) {
				break
			}
			cpufreq_dir := fmt.tprintf("%s/cpufreq", cpu_dir)
			if !os.is_directory(cpufreq_dir) {
				continue
			}
			if smax, s_ok := _read_u64_sysfs(fmt.tprintf("%s/scaling_max_freq", cpufreq_dir));
			   s_ok && smax > 0 {
				if env.scaling_max_khz == 0 || smax < env.scaling_max_khz {
					env.scaling_max_khz = smax
				}
			}
			cmax, c_ok := _read_u64_sysfs(fmt.tprintf("%s/cpuinfo_max_freq", cpufreq_dir))
			if !c_ok || cmax == 0 {
				cmax, c_ok = _read_u64_sysfs(fmt.tprintf("%s/amd_pstate_max_freq", cpufreq_dir))
			}
			if c_ok && cmax > env.cpuinfo_max_khz {
				env.cpuinfo_max_khz = cmax
			}
		}

		boost_str, b_ok := _read_trimmed_sysfs(
			"/sys/devices/system/cpu/cpufreq/boost",
			context.temp_allocator,
		)
		if !b_ok {
			boost_str, b_ok = _read_trimmed_sysfs(
				"/sys/devices/system/cpu/cpu0/cpufreq/boost",
				context.temp_allocator,
			)
		}
		if b_ok {
			defer delete(boost_str, context.temp_allocator)
			if boost_str == "1" {
				env.boost_state = 1
			} else if boost_str == "0" {
				env.boost_state = -1
			}
		} else if nt_str, nt_ok := _read_trimmed_sysfs(
			"/sys/devices/system/cpu/intel_pstate/no_turbo",
			context.temp_allocator,
		); nt_ok {
			defer delete(nt_str, context.temp_allocator)
			if nt_str == "0" {
				env.boost_state = 1
			} else if nt_str == "1" {
				env.boost_state = -1
			}
		}
	} else {
		_ = allocator
	}
	return env
}

/*
Returns human-readable diagnostic warnings when `env` indicates clamped clocks,
non-performance governor, or disabled CPU boost/turbo.
*/
@(require_results)
check_host_env :: proc(env: Run_Env, allocator := context.allocator) -> [dynamic]string {
	warnings := make([dynamic]string, allocator)
	if env.scaling_max_khz > 0 &&
	   env.cpuinfo_max_khz > 0 &&
	   env.scaling_max_khz * 100 < env.cpuinfo_max_khz * 95 {
		pct := f64(env.scaling_max_khz) / f64(env.cpuinfo_max_khz) * 100.0
		append(
			&warnings,
			fmt.aprintf(
				"CPU scaling_max_freq is clamped to %.2f GHz (%.0f%% of %.2f GHz max); lift with: sudo cpupower frequency-set -u %d",
				f64(env.scaling_max_khz) / 1_000_000.0,
				pct,
				f64(env.cpuinfo_max_khz) / 1_000_000.0,
				env.cpuinfo_max_khz,
				allocator = allocator,
			),
		)
	}
	if env.governor != "" && env.governor != "performance" {
		append(
			&warnings,
			fmt.aprintf(
				"CPU scaling_governor is '%s' (expected 'performance')",
				env.governor,
				allocator = allocator,
			),
		)
	}
	if env.boost_state < 0 {
		append(&warnings, strings.clone("CPU boost / turbo is disabled", allocator))
	}
	return warnings
}

/*
Populates empty host provenance fields on `pkt.env`, optionally overriding `build_flags` and
`runtime_version` (defaulting Odin `runtime_version` to `pkt.odin_version` when unset).
*/
populate_packet_env :: proc(
	pkt: ^Run_Packet,
	build_flags := "",
	runtime_version := "",
	allocator := context.allocator,
) {
	if pkt == nil {
		return
	}
	host := collect_host_env(context.temp_allocator)
	defer run_env_destroy(&host, context.temp_allocator)

	if pkt.env.cpu_model == "" && host.cpu_model != "" {
		pkt.env.cpu_model = strings.clone(host.cpu_model, allocator)
	}
	if pkt.env.governor == "" && host.governor != "" {
		pkt.env.governor = strings.clone(host.governor, allocator)
	}
	if pkt.env.scaling_max_khz == 0 && host.scaling_max_khz > 0 {
		pkt.env.scaling_max_khz = host.scaling_max_khz
	}
	if pkt.env.cpuinfo_max_khz == 0 && host.cpuinfo_max_khz > 0 {
		pkt.env.cpuinfo_max_khz = host.cpuinfo_max_khz
	}
	if pkt.env.boost_state == 0 && host.boost_state != 0 {
		pkt.env.boost_state = host.boost_state
	}
	if build_flags != "" {
		delete(pkt.env.build_flags, allocator)
		pkt.env.build_flags = strings.clone(build_flags, allocator)
	}
	if runtime_version != "" {
		delete(pkt.env.runtime_version, allocator)
		pkt.env.runtime_version = strings.clone(runtime_version, allocator)
	} else if pkt.env.runtime_version == "" && pkt.lang == "odin" && pkt.odin_version != "" {
		pkt.env.runtime_version = strings.clone(pkt.odin_version, allocator)
	}
}

/*
Formats `env` into a concise single-line provenance summary.
*/
@(require_results)
format_env_brief :: proc(env: Run_Env, allocator := context.allocator) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	defer delete(parts)

	if env.cpu_model != "" {
		append(&parts, env.cpu_model)
	}
	if env.scaling_max_khz > 0 ||
	   env.cpuinfo_max_khz > 0 ||
	   env.governor != "" ||
	   env.boost_state != 0 {
		sb := strings.builder_make(context.temp_allocator)
		if env.scaling_max_khz > 0 && env.cpuinfo_max_khz > 0 {
			fmt.sbprintf(
				&sb,
				"%.2f/%.2f GHz",
				f64(env.scaling_max_khz) / 1_000_000.0,
				f64(env.cpuinfo_max_khz) / 1_000_000.0,
			)
		} else if env.scaling_max_khz > 0 {
			fmt.sbprintf(&sb, "%.2f GHz", f64(env.scaling_max_khz) / 1_000_000.0)
		} else if env.cpuinfo_max_khz > 0 {
			fmt.sbprintf(&sb, "max %.2f GHz", f64(env.cpuinfo_max_khz) / 1_000_000.0)
		}
		has_parens := env.governor != "" || env.boost_state != 0
		if has_parens {
			if strings.builder_len(sb) > 0 {
				strings.write_string(&sb, " (")
			} else {
				strings.write_byte(&sb, '(')
			}
			wrote_inner := false
			if env.governor != "" {
				strings.write_string(&sb, env.governor)
				wrote_inner = true
			}
			if env.boost_state != 0 {
				if wrote_inner {
					strings.write_string(&sb, ", ")
				}
				strings.write_string(&sb, env.boost_state > 0 ? "boost=on" : "boost=off")
			}
			strings.write_byte(&sb, ')')
		}
		append(&parts, strings.to_string(sb))
	}
	if env.build_flags != "" {
		append(&parts, env.build_flags)
	}
	if env.runtime_version != "" {
		append(&parts, env.runtime_version)
	}
	return strings.join(parts[:], " | ", allocator)
}
