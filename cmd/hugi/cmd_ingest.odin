package hugi_cli

import hugi "../../hugi"
import store "../../store"
import "core:fmt"
import "core:os"
import "core:strings"

@(private)
_apply_ingest_env :: proc(
	pkt: ^hugi.Run_Packet,
	capture_host_env: bool,
	build_flags: string,
	runtime_version: string,
) {
	if capture_host_env {
		hugi.populate_packet_env(
			pkt,
			build_flags = build_flags,
			runtime_version = runtime_version,
			allocator = context.allocator,
		)
		return
	}
	if build_flags != "" {
		delete(pkt.env.build_flags, context.allocator)
		pkt.env.build_flags = strings.clone(build_flags, context.allocator)
	}
	if runtime_version != "" {
		delete(pkt.env.runtime_version, context.allocator)
		pkt.env.runtime_version = strings.clone(runtime_version, context.allocator)
	}
}

@(private)
_cmd_ingest :: proc(args: []string) -> int {
	// Keep `files` on context.allocator so per-file temp_allocator flushes stay safe.
	files := make([dynamic]string, context.allocator)
	defer delete(files)
	common := _Common_Opts{}
	capture_host_env := false
	build_flags := ""
	runtime_version := ""

	allowed := _Common_Flag_Set{.DB, .Lang, .Commit}
	i := 0
	for i < len(args) {
		key, inline_val, is_flag := _parse_flag_kv(args, &i)
		if !is_flag {
			append(&files, args[i])
			i += 1
			continue
		}
		switch _try_parse_common_flag("ingest", key, inline_val, args, &i, allowed, &common) {
		case .Help:
			_print_help()
			return 0
		case .Error:
			return 1
		case .Matched:
			continue
		case .Not_Matched:
		}
		switch key {
		case "capture-host-env":
			capture_host_env = true
		case "build-flags":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {
				return 1
			}
			build_flags = v
		case "runtime-version":
			v, ok := _consume_value(args, &i, inline_val, key)
			if !ok {
				return 1
			}
			runtime_version = v
		case:
			fmt.eprintfln("hugi ingest: unknown flag '--%s'", key)
			return 1
		}
	}

	if len(files) == 0 {
		fmt.eprintln(
			"hugi ingest: expected at least one input file (.hpk, .bpk, .json, or .jsonl)",
		)
		return 1
	}

	st, db_path, open_ok := _open_store_or_err("ingest", common.db_flag)
	if !open_ok {
		return 1
	}
	defer store.store_close(&st)

	lang_override, lang_owned := _normalize_lang(common.lang)
	defer if lang_owned {delete(lang_override)}
	commit_override := common.commit
	total_pkts := 0
	total_recs := 0

	for path in files {
		defer free_all(context.temp_allocator)
		if !os.exists(path) {
			fmt.eprintfln("hugi ingest: file not found: '%s'", path)
			return 1
		}
		if _file_has_packet_magic(path) ||
		   strings.has_suffix(path, ".hpk") ||
		   strings.has_suffix(path, ".bpk") {
			pkt, ok := hugi.read_packet_file(path, context.allocator)
			if !ok {
				fmt.eprintfln("hugi ingest: failed to read packet '%s'", path)
				return 1
			}
			defer hugi.packet_destroy(&pkt)
			if lang_override != "" {
				delete(pkt.lang)
				pkt.lang = strings.clone(lang_override)
			}
			if commit_override != "" {
				delete(pkt.commit)
				pkt.commit = strings.clone(commit_override)
			}
			_apply_ingest_env(&pkt, capture_host_env, build_flags, runtime_version)
			if !store.store_ingest_packet(&st, pkt) {
				fmt.eprintfln("hugi ingest: failed to write packet '%s' to store", path)
				return 1
			}
			total_pkts += 1
			total_recs += len(pkt.records)
			continue
		}

		pkts: []hugi.Run_Packet
		ok: bool
		if strings.has_suffix(path, ".jsonl") {
			pkts, ok = hugi.read_jsonl_packets(
				path,
				lang_override,
				commit_override,
				"",
				context.allocator,
			)
		} else {
			pkts, ok = hugi.read_obench_json_packets(
				path,
				lang_override,
				commit_override,
				"",
				context.allocator,
			)
			if !ok || len(pkts) == 0 {
				if ok {
					hugi.packets_destroy(pkts)
				}
				pkts, ok = hugi.read_jsonl_packets(
					path,
					lang_override,
					commit_override,
					"",
					context.allocator,
				)
			}
		}
		if !ok {
			fmt.eprintfln("hugi ingest: failed to parse '%s'", path)
			return 1
		}
		defer hugi.packets_destroy(pkts)

		for &pkt in pkts {
			_apply_ingest_env(&pkt, capture_host_env, build_flags, runtime_version)
			if !store.store_ingest_packet(&st, pkt) {
				fmt.eprintfln("hugi ingest: failed to store packet from '%s'", path)
				return 1
			}
			total_pkts += 1
			total_recs += len(pkt.records)
		}
	}

	fmt.printfln("Ingested %d packet(s), %d record(s) into %s", total_pkts, total_recs, db_path)
	return 0
}
