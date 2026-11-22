package hugi_cli

import hugi "../../hugi"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sys/info"

@(private = "file")
_doctor_write_json_str :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for i := 0; i < len(s); i += 1 {
		b := s[i]
		switch b {
		case '"':
			strings.write_string(sb, `\"`)
		case '\\':
			strings.write_string(sb, `\\`)
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

@(private)
_doctor_load_avg_known :: proc(load_avg: f64, source_available: bool) -> bool {
	return source_available && !math.is_nan(load_avg) && !math.is_inf(load_avg, 0) && load_avg >= 0
}

@(private)
_doctor_write_load_avg_json :: proc(sb: ^strings.Builder, load_avg: f64, known: bool) {
	if !known || math.is_nan(load_avg) || math.is_inf(load_avg, 0) {
		strings.write_string(sb, "null")
		return
	}
	fmt.sbprintf(sb, "%.2f", load_avg)
}

@(private)
_cmd_doctor :: proc(args: []string) -> int {
	strict := false
	format_arg := ""

	i := 0
	for i < len(args) {
		key, inline_val, is_flag := _parse_flag_kv(args, &i)
		if !is_flag {
			fmt.eprintfln("hugi doctor: unexpected argument '%s'", args[i])
			return 1
		}
		switch key {
		case "h", "help":
			_print_help()
			return 0
		case "strict":
			strict = true
		case "format":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {
				return 1
			}
			format_arg = v
		case:
			fmt.eprintfln("hugi doctor: unknown flag '--%s'", key)
			return 1
		}
	}

	rep_fmt := _infer_report_format(format_arg, "")
	if rep_fmt != "md" && rep_fmt != "json" {
		fmt.eprintfln("hugi doctor: unsupported format '%s' (expected md|json)", rep_fmt)
		return 1
	}

	env := hugi.collect_host_env(context.allocator)
	defer hugi.run_env_destroy(&env)
	warnings := hugi.check_host_env(env, context.allocator)
	defer {
		for w in warnings {
			delete(w)
		}
		delete(warnings)
	}

	mstate := _obench_read_machine_state(context.allocator)
	defer _obench_machine_state_destroy(&mstate, context.allocator)
	_, cores, _ := info.cpu_core_count()
	if cores <= 0 {
		cores = os.get_processor_core_count()
	}
	mnotes := _obench_machine_notes(mstate, cores, context.temp_allocator)
	notes := make([dynamic]string, context.temp_allocator)
	for n in mnotes {
		if n.warning {
			// Avoid duplicating the governor warning already emitted by hugi.check_host_env.
			if env.governor != "" &&
			   env.governor != "performance" &&
			   strings.contains(n.text, "CPU governor") {
				continue
			}
			append(&warnings, strings.clone(n.text, context.allocator))
		} else {
			append(&notes, n.text)
		}
	}

	_, cfg_path, cfg, has_cfg := _read_nearest_project_config(".")
	load_source_available := false
	when ODIN_OS == .Linux {
		load_source_available = os.exists("/proc/loadavg")
	} else when ODIN_OS == .Darwin {
		load_source_available = true
	}
	load_known := _doctor_load_avg_known(mstate.load_avg, load_source_available)

	if rep_fmt == "json" {
		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, "{\n  \"os\": ")
		_doctor_write_json_str(&sb, ODIN_OS_STRING)
		strings.write_string(&sb, ",\n  \"arch\": ")
		_doctor_write_json_str(&sb, ODIN_ARCH_STRING)
		strings.write_string(&sb, ",\n  \"odin_version\": ")
		_doctor_write_json_str(&sb, ODIN_VERSION)
		strings.write_string(&sb, ",\n  \"cpu_model\": ")
		_doctor_write_json_str(&sb, env.cpu_model)
		fmt.sbprintf(&sb, ",\n  \"cores\": %d", cores)
		strings.write_string(&sb, ",\n  \"governor\": ")
		_doctor_write_json_str(&sb, env.governor)
		strings.write_string(&sb, ",\n  \"smt\": ")
		_doctor_write_json_str(&sb, mstate.smt)
		fmt.sbprintf(
			&sb,
			",\n  \"scaling_max_khz\": %d,\n  \"cpuinfo_max_khz\": %d,\n  \"boost_state\": %d,\n  \"load_avg\": ",
			env.scaling_max_khz,
			env.cpuinfo_max_khz,
			env.boost_state,
		)
		_doctor_write_load_avg_json(&sb, mstate.load_avg, load_known)
		fmt.sbprintf(
			&sb,
			",\n  \"on_battery\": %s,\n  \"vm\": %s,\n  \"config_path\": ",
			mstate.on_battery ? "true" : "false",
			mstate.vm ? "true" : "false",
		)
		_doctor_write_json_str(&sb, has_cfg ? cfg_path : "")
		strings.write_string(&sb, ",\n  \"config\": {\n    \"db\": ")
		_doctor_write_json_str(&sb, cfg.db)
		strings.write_string(&sb, ",\n    \"pkg_dir\": ")
		_doctor_write_json_str(&sb, cfg.pkg_dir)
		fmt.sbprintf(
			&sb,
			",\n    \"runs\": %d,\n    \"warmup\": %d,\n    \"extra_build_flags\": ",
			cfg.runs,
			cfg.warmup,
		)
		_doctor_write_json_str(&sb, cfg.extra_build_flags)
		strings.write_string(&sb, "\n  },\n  \"warnings\": [")
		for w, idx in warnings {
			if idx > 0 {
				strings.write_string(&sb, ", ")
			}
			_doctor_write_json_str(&sb, w)
		}
		strings.write_string(&sb, "],\n  \"notes\": [")
		for note, idx in notes {
			if idx > 0 {
				strings.write_string(&sb, ", ")
			}
			_doctor_write_json_str(&sb, note)
		}
		strings.write_string(&sb, "],\n  \"ok\": ")
		strings.write_string(&sb, len(warnings) == 0 ? "true" : "false")
		strings.write_string(&sb, "\n}\n")
		fmt.print(strings.to_string(sb))
		return (strict && len(warnings) > 0) ? 1 : 0
	}

	fmt.printfln(
		"Host Diagnostics (%s/%s, Odin %s)",
		ODIN_OS_STRING,
		ODIN_ARCH_STRING,
		ODIN_VERSION,
	)
	fmt.printfln("  CPU model:        %s", env.cpu_model != "" ? env.cpu_model : "unknown")
	fmt.printfln("  Logical cores:    %d", cores)
	fmt.printfln("  Governor:         %s", env.governor != "" ? env.governor : "unknown")
	fmt.printfln("  SMT:              %s", mstate.smt != "" ? mstate.smt : "unknown")
	if env.scaling_max_khz > 0 && env.cpuinfo_max_khz > 0 {
		pct := f64(env.scaling_max_khz) / f64(env.cpuinfo_max_khz) * 100.0
		fmt.printfln(
			"  Scaling max freq: %.2f GHz / %.2f GHz (%.0f%%; %d / %d kHz)",
			f64(env.scaling_max_khz) / 1_000_000.0,
			f64(env.cpuinfo_max_khz) / 1_000_000.0,
			pct,
			env.scaling_max_khz,
			env.cpuinfo_max_khz,
		)
	} else {
		fmt.println("  Scaling max freq: unknown")
	}
	boost_label := "unknown"
	if env.boost_state > 0 {
		boost_label = "enabled"
	} else if env.boost_state < 0 {
		boost_label = "disabled"
	}
	fmt.printfln("  Boost / turbo:    %s", boost_label)
	if load_known {
		fmt.printfln("  Load average:     %.2f", mstate.load_avg)
	} else {
		fmt.println("  Load average:     unknown")
	}
	fmt.printfln("  Power:            %s", mstate.on_battery ? "battery" : "AC / unknown")
	fmt.printfln("  Virtual machine:  %s", mstate.vm ? "yes" : "no")
	if has_cfg {
		fmt.printfln(
			"  Project config:   %s (db=%q, pkg_dir=%q, runs=%d, warmup=%d, extra_build_flags=%q)",
			cfg_path,
			cfg.db,
			cfg.pkg_dir,
			cfg.runs,
			cfg.warmup,
			cfg.extra_build_flags,
		)
	} else {
		fmt.println("  Project config:   none (no hugi.json discovered)")
	}

	if len(warnings) == 0 {
		fmt.println("OK: host environment ready for benchmarking")
	} else {
		for w in warnings {
			fmt.printfln("WARNING: %s", w)
		}
	}
	for note in notes {
		fmt.printfln("NOTE: %s", note)
	}

	if strict && len(warnings) > 0 {
		return 1
	}
	return 0
}
