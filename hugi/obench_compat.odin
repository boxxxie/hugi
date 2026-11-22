package hugi

import obench "../deps/obench/obench"
import "base:runtime"
import "core:io"

/*
Isolates calls and types outside `deps/obench/STABILITY.md`'s stable package surface behind
private wrappers and type aliases so upstream `0.x` internal tool changes require updates in
only one place.

`format_bytes` is exposed as a thin public helper alongside `format_duration_fs` so downstream
packages (`hugi_store`, `hugi_cli`) do not need to import `obench` directly for formatting.
*/

@(private)
_Obench_Timestamp :: obench.Timestamp
@(private)
_Obench_Thread_Pin :: obench.Thread_Pin
@(private)
_Obench_Counter_Group :: obench.Counter_Group
@(private)
_Obench_Counter_Values :: obench.Counter_Values
@(private)
_Obench_Counting_Allocator :: obench.Counting_Allocator
@(private)
_Obench_Export_Document :: obench.Export_Document
@(private)
_Obench_Report_Error :: obench.Report_Error

/*
Formats a byte count into a human-readable string (`0 B`, `64 B`, `1.50 KiB`, `2.00 MiB`).
*/
@(require_results)
format_bytes :: proc(b: f64, allocator := context.allocator) -> string {
	return obench.format_bytes(b, allocator)
}

@(private, require_results)
_obench_clock_calibrate :: proc "contextless" () -> obench.Clock_Calibration {
	return obench.clock_calibrate()
}

@(private, require_results)
_obench_clock_now :: #force_inline proc "contextless" () -> _Obench_Timestamp {
	return obench.clock_now()
}

@(private, require_results)
_obench_clock_elapsed :: #force_inline proc "contextless" (
	start, end: _Obench_Timestamp,
) -> (
	ns: i64,
	cycles: u64,
) {
	return obench.clock_elapsed(start, end)
}

@(private, require_results)
_obench_pin_thread :: proc(cpu: int) -> (_Obench_Thread_Pin, bool, string) {
	return obench.pin_thread(cpu)
}

@(private)
_obench_unpin_thread :: proc(pin: _Obench_Thread_Pin) {
	obench.unpin_thread(pin)
}

@(private, require_results)
_obench_counter_group_open :: proc() -> (_Obench_Counter_Group, bool, string) {
	return obench.counter_group_open()
}

@(private, require_results)
_obench_counter_group_read :: proc(g: ^_Obench_Counter_Group) -> (_Obench_Counter_Values, bool) {
	return obench.counter_group_read(g)
}

@(private)
_obench_counter_group_close :: proc(g: ^_Obench_Counter_Group) {
	obench.counter_group_close(g)
}

@(private)
_obench_counting_allocator_init :: proc "contextless" (
	c: ^_Obench_Counting_Allocator,
	backing: runtime.Allocator,
) {
	obench.counting_allocator_init(c, backing)
}

@(private)
_obench_counting_allocator_set_paused :: #force_inline proc "contextless" (
	c: ^_Obench_Counting_Allocator,
	paused: bool,
) {
	obench.counting_allocator_set_paused(c, paused)
}

@(private)
_obench_counting_allocator_reset :: proc "contextless" (c: ^_Obench_Counting_Allocator) {
	obench.counting_allocator_reset(c)
}

@(private, require_results)
_obench_counting_allocator :: proc "contextless" (
	c: ^_Obench_Counting_Allocator,
) -> runtime.Allocator {
	return obench.counting_allocator(c)
}

@(private)
_obench_write_terminal_report :: proc(w: io.Writer, s: ^obench.Suite) {
	obench.write_terminal_report(w, s)
}

@(private, require_results)
_obench_compute_suite_summary :: proc "contextless" (
	results: []obench.Result,
) -> obench.Suite_Summary {
	return obench.compute_suite_summary(results)
}

@(private)
_obench_machine_state_destroy :: proc(m: ^obench.Machine_State, allocator: runtime.Allocator) {
	obench.machine_state_destroy(m, allocator)
}

@(private, require_results)
_obench_read_json_report :: proc(
	path: string,
	allocator := context.temp_allocator,
) -> (
	_Obench_Export_Document,
	_Obench_Report_Error,
) {
	return obench.read_json_report(path, allocator)
}

@(private, require_results)
_obench_format_duration_ns :: proc(ns: f64, allocator := context.allocator) -> string {
	return obench.format_duration_ns(ns, allocator)
}

@(private, require_results)
_obench_bench_error_string :: proc "contextless" (e: obench.Bench_Error) -> string {
	return obench.bench_error_string(e)
}

@(private, require_results)
_obench_lag1_autocorrelation :: proc "contextless" (samples: []f64) -> f64 {
	return obench.lag1_autocorrelation(samples)
}

@(private, require_results)
_obench_effective_sample_count :: proc "contextless" (n: int, r1: f64) -> f64 {
	return obench.effective_sample_count(n, r1)
}

@(private, require_results)
_obench_t_critical_975 :: proc "contextless" (df: f64) -> f64 {
	return obench.t_critical_975(df)
}
