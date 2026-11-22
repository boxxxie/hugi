package hugi_store

import obench "../deps/obench/obench"

/*
Isolates statistical, sample-shape, and formatting helpers outside `deps/obench/STABILITY.md`'s
stable package surface behind package-private wrappers.
*/

@(private)
_OBENCH_TREND_MIN_PCT :: obench.TREND_MIN_PCT

@(private, require_results)
_obench_lag1_autocorrelation :: proc "contextless" (samples: []f64) -> f64 {
	return obench.lag1_autocorrelation(samples)
}

@(private, require_results)
_obench_effective_sample_count :: proc "contextless" (n: int, r1: f64) -> f64 {
	return obench.effective_sample_count(n, r1)
}

@(private, require_results)
_obench_sample_trend :: proc(
	samples: []f64,
	allocator := context.temp_allocator,
) -> (
	change_pct: f64,
	z: f64,
) {
	return obench.sample_trend(samples, allocator)
}

@(private, require_results)
_obench_count_modes :: proc(samples: []f64, allocator := context.temp_allocator) -> int {
	return obench.count_modes(samples, allocator)
}

@(private, require_results)
_obench_t_critical_975 :: proc "contextless" (df: f64) -> f64 {
	return obench.t_critical_975(df)
}

@(private, require_results)
_obench_hodges_lehmann_shift :: proc(
	current, baseline: []f64,
	adjust_for_autocorrelation := true,
	allocator := context.temp_allocator,
) -> (
	shift_pct, low_pct, high_pct: f64,
	ok: bool,
) {
	return obench.hodges_lehmann_shift(current, baseline, adjust_for_autocorrelation, allocator)
}

@(private, require_results)
_obench_welch_test :: proc "contextless" (
	mean_a, sd_a: f64,
	n_a: int,
	mean_b, sd_b: f64,
	n_b: int,
) -> (
	t: f64,
	df: f64,
) {
	return obench.welch_test(mean_a, sd_a, n_a, mean_b, sd_b, n_b)
}

@(private, require_results)
_obench_mann_whitney_u :: proc(
	a, b: []f64,
	allocator := context.temp_allocator,
) -> (
	u: f64,
	z: f64,
	p: f64,
) {
	return obench.mann_whitney_u(a, b, allocator)
}

@(private, require_results)
_obench_format_full_name :: proc(
	group_name, bench_name: string,
	param_val: int,
	has_param: bool,
	thread_val: int = 1,
	has_threads: bool = false,
	allocator := context.allocator,
) -> string {
	return obench.format_full_name(
		group_name,
		bench_name,
		param_val,
		has_param,
		thread_val,
		has_threads,
		allocator,
	)
}
