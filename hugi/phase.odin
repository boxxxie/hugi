package hugi

import obench "../deps/obench/obench"
import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"

Pipeline_Proc :: #type proc(p: ^Pipeline)

@(private)
_Pipeline_Def :: struct {
	group_name: string,
	procedure:  Pipeline_Proc,
	param:      int,
	has_param:  bool,
	runs:       int,
	warmup:     int,
	user_ptr:   rawptr,
}

@(private)
_Phase_Pass_Mode :: enum u8 {
	Warmup,
	Timed,
	Alloc_Check,
}

MAX_PHASE_DEPTH :: 8

@(private = "file")
_Alloc_Counter_Snap :: struct {
	alloc_count:          u64,
	resize_count:         u64,
	bytes_allocated:      u64,
	current_bytes:        i64,
	peak_bytes:           i64,
	zero_alloc_violated:  bool,
	first_violation_loc:  runtime.Source_Code_Location,
	first_violation_size: int,
}

@(private = "file")
_snap_merge_snap :: proc "contextless" (dst: ^_Alloc_Counter_Snap, src: _Alloc_Counter_Snap) {
	dst.peak_bytes = max(dst.peak_bytes, dst.current_bytes + src.peak_bytes)
	dst.current_bytes += src.current_bytes
	dst.peak_bytes = max(dst.peak_bytes, dst.current_bytes)
	dst.alloc_count += src.alloc_count
	dst.resize_count += src.resize_count
	dst.bytes_allocated += src.bytes_allocated
	if !dst.zero_alloc_violated && src.zero_alloc_violated {
		dst.zero_alloc_violated = true
		dst.first_violation_loc = src.first_violation_loc
		dst.first_violation_size = src.first_violation_size
	}
}

@(private = "file")
_snap_merge_counter :: proc "contextless" (
	dst: ^_Alloc_Counter_Snap,
	c: ^obench.Counting_Allocator,
) {
	if c == nil {
		return
	}
	snap := _Alloc_Counter_Snap {
		alloc_count          = intrinsics.atomic_load_explicit(&c.alloc_count, .Relaxed),
		resize_count         = intrinsics.atomic_load_explicit(&c.resize_count, .Relaxed),
		bytes_allocated      = intrinsics.atomic_load_explicit(&c.bytes_allocated, .Relaxed),
		current_bytes        = intrinsics.atomic_load_explicit(&c.current_bytes, .Relaxed),
		peak_bytes           = intrinsics.atomic_load_explicit(&c.peak_bytes, .Relaxed),
		zero_alloc_violated  = intrinsics.atomic_load_explicit(&c.zero_alloc_violated, .Relaxed),
		first_violation_loc  = c.first_violation_loc,
		first_violation_size = c.first_violation_size,
	}
	_snap_merge_snap(dst, snap)
}

Phase :: struct {
	pipeline:            ^Pipeline,
	slot_idx:            int,
	name:                string,
	ops:                 int,
	bytes_per_op:        u64,
	zero_alloc:          bool,
	start_ts:            obench.Timestamp,
	footprint_bytes:     u64,
	metrics:             [MAX_METRICS]Metric,
	metrics_count:       int,
	_metric_buf:         [MAX_METRICS][obench.MAX_METRIC_UNIT_LEN]u8,
	_heap_acc:           _Alloc_Counter_Snap,
	_temp_acc:           _Alloc_Counter_Snap,
	_counters_before:    obench.Counter_Values,
	_counters_ok:        bool,
	_nested_hw_brackets: int,
	active:              bool,
}

@(private)
_Phase_Accum :: struct {
	name:               string,
	ops:                int,
	bytes_per_op:       u64,
	zero_alloc:         bool,
	footprint_bytes:    u64,
	metrics:            [MAX_METRICS]Metric,
	metrics_count:      int,
	samples_batch_ns:   [dynamic]u64,
	samples_cycles:     [dynamic]f64,
	samples_hw:         [4][dynamic]f64,
	allocs_per_op:      f64,
	resizes_per_op:     f64,
	alloc_bytes_per_op: f64,
	temp_allocs_per_op: f64,
	temp_bytes_per_op:  f64,
	peak_heap_bytes:    i64,
	zero_alloc_failed:  bool,
	violation_loc:      runtime.Source_Code_Location,
	violation_size:     int,
}

Pipeline :: struct {
	group_name:            string,
	param:                 int,
	has_param:             bool,
	user_ptr:              rawptr,
	clock_overhead_fs:     i64,
	clock_overhead_cycles: f64,
	_mode:                 _Phase_Pass_Mode,
	_slot_cursor:          int,
	_accums:               [dynamic]_Phase_Accum,
	_phase_stack:          [MAX_PHASE_DEPTH]Phase,
	_stack_depth:          int,
	_heap_counter:         ^obench.Counting_Allocator,
	_temp_counter:         ^obench.Counting_Allocator,
	_counters:             ^obench.Counter_Group,
	_counter_overhead:     obench.Counter_Values,
	_enforce_zero_alloc:   bool,
	_allocator:            runtime.Allocator,
}

/*
Begins a measured phase inside a stateful `group_pipeline` callback.
All prior setup and later teardown outside `phase_begin`..`phase_end` are excluded from
timing and allocation counting.
*/
@(require_results)
phase_begin :: proc(
	p: ^Pipeline,
	name: string,
	ops := 1,
	bytes_per_op: u64 = 0,
	zero_alloc := false,
) -> ^Phase {
	assert(p != nil, "phase_begin called with nil Pipeline")
	assert(p._stack_depth < MAX_PHASE_DEPTH, "phase_begin nesting exceeded MAX_PHASE_DEPTH")

	slot := p._slot_cursor
	p._slot_cursor += 1
	eff_ops := max(ops, 1)
	eff_zero := zero_alloc || p._enforce_zero_alloc

	if slot >= len(p._accums) {
		acc := _Phase_Accum {
			name             = strings.clone(name, p._allocator),
			ops              = eff_ops,
			bytes_per_op     = bytes_per_op,
			zero_alloc       = eff_zero,
			samples_batch_ns = make([dynamic]u64, p._allocator),
			samples_cycles   = make([dynamic]f64, p._allocator),
		}
		if p._counters != nil && p._counters.open {
			for k in 0 ..< 4 {
				acc.samples_hw[k] = make([dynamic]f64, p._allocator)
			}
		}
		append(&p._accums, acc)
	} else {
		acc := &p._accums[slot]
		fmt.assertf(
			acc.name == name,
			"hugi: phase_begin slot %d expected phase %q, got %q (Pipeline_Proc must open phases in a deterministic sequence across all passes)",
			slot,
			acc.name,
			name,
		)
		acc.ops = eff_ops
		if bytes_per_op > 0 {
			acc.bytes_per_op = bytes_per_op
		}
		acc.zero_alloc = acc.zero_alloc || eff_zero
	}

	parent_depth := p._stack_depth
	ph := &p._phase_stack[parent_depth]
	p._stack_depth += 1
	ph^ = Phase {
		pipeline     = p,
		slot_idx     = slot,
		name         = name,
		ops          = eff_ops,
		bytes_per_op = bytes_per_op,
		zero_alloc   = eff_zero,
		active       = true,
	}

	switch p._mode {
	case .Warmup:
	case .Alloc_Check:
		if parent_depth > 0 {
			obench.counting_allocator_set_paused(p._heap_counter, true)
			obench.counting_allocator_set_paused(p._temp_counter, true)
			parent := &p._phase_stack[parent_depth - 1]
			_snap_merge_counter(&parent._heap_acc, p._heap_counter)
			_snap_merge_counter(&parent._temp_acc, p._temp_counter)
		}
		obench.counting_allocator_reset(p._heap_counter)
		obench.counting_allocator_reset(p._temp_counter)
		p._heap_counter.enforce_zero_allocs = true
		obench.counting_allocator_set_paused(p._heap_counter, false)
		obench.counting_allocator_set_paused(p._temp_counter, false)
	case .Timed:
		if p._counters != nil && p._counters.open {
			ph._counters_before, ph._counters_ok = obench.counter_group_read(p._counters)
		}
		obench.clobber_memory()
		ph.start_ts = obench.clock_now()
	}
	return ph
}

/*
Ends the measured phase started by `phase_begin`.
*/
phase_end :: proc(ph: ^Phase) {
	if ph == nil || !ph.active {
		return
	}
	p := ph.pipeline
	end_ts: obench.Timestamp
	counters_after: obench.Counter_Values
	counters_after_ok: bool
	if p._mode == .Timed {
		end_ts = obench.clock_now()
		obench.clobber_memory()
		if ph._counters_ok && p._counters != nil && p._counters.open {
			counters_after, counters_after_ok = obench.counter_group_read(p._counters)
		}
	} else if p._mode == .Alloc_Check {
		obench.counting_allocator_set_paused(p._heap_counter, true)
		obench.counting_allocator_set_paused(p._temp_counter, true)
	}

	ph.active = false
	if p._stack_depth > 0 {
		p._stack_depth -= 1
	}

	acc := &p._accums[ph.slot_idx]
	if ph.footprint_bytes > 0 {
		acc.footprint_bytes = ph.footprint_bytes
	}
	for i in 0 ..< ph.metrics_count {
		_acc_set_metric(acc, ph.metrics[i].unit, ph.metrics[i].value, p._allocator)
	}

	switch p._mode {
	case .Warmup:
	case .Timed:
		ns, cyc := obench.clock_elapsed(ph.start_ts, end_ts)
		ov_ns := (i128(p.clock_overhead_fs) + 500_000) / 1_000_000
		adj_batch_ns := u64(max(i128(ns) - ov_ns, 0))
		append(&acc.samples_batch_ns, adj_batch_ns)
		append(&acc.samples_cycles, max(f64(cyc) - p.clock_overhead_cycles, 0.0) / f64(ph.ops))
		if ph._counters_ok && counters_after_ok {
			per_op := f64(max(ph.ops, 1))
			brackets := f64(1 + ph._nested_hw_brackets)
			append(
				&acc.samples_hw[0],
				max(
					counters_after.instructions -
					ph._counters_before.instructions -
					p._counter_overhead.instructions * brackets,
					0.0,
				) /
				per_op,
			)
			append(
				&acc.samples_hw[1],
				max(
					counters_after.cycles -
					ph._counters_before.cycles -
					p._counter_overhead.cycles * brackets,
					0.0,
				) /
				per_op,
			)
			append(
				&acc.samples_hw[2],
				max(
					counters_after.branch_misses -
					ph._counters_before.branch_misses -
					p._counter_overhead.branch_misses * brackets,
					0.0,
				) /
				per_op,
			)
			append(
				&acc.samples_hw[3],
				max(
					counters_after.cache_misses -
					ph._counters_before.cache_misses -
					p._counter_overhead.cache_misses * brackets,
					0.0,
				) /
				per_op,
			)
			if p._stack_depth > 0 {
				p._phase_stack[p._stack_depth - 1]._nested_hw_brackets +=
					1 + ph._nested_hw_brackets
			}
		}
	case .Alloc_Check:
		_snap_merge_counter(&ph._heap_acc, p._heap_counter)
		_snap_merge_counter(&ph._temp_acc, p._temp_counter)

		ops_f := f64(max(ph.ops, 1))
		acc.allocs_per_op = f64(ph._heap_acc.alloc_count + ph._heap_acc.resize_count) / ops_f
		acc.resizes_per_op = f64(ph._heap_acc.resize_count) / ops_f
		acc.alloc_bytes_per_op = f64(ph._heap_acc.bytes_allocated) / ops_f
		acc.peak_heap_bytes = ph._heap_acc.peak_bytes

		acc.temp_allocs_per_op = f64(ph._temp_acc.alloc_count + ph._temp_acc.resize_count) / ops_f
		acc.temp_bytes_per_op = f64(ph._temp_acc.bytes_allocated) / ops_f

		if ph.zero_alloc && ph._heap_acc.zero_alloc_violated {
			acc.zero_alloc_failed = true
			acc.violation_loc = ph._heap_acc.first_violation_loc
			acc.violation_size = ph._heap_acc.first_violation_size
		}

		if p._stack_depth > 0 {
			parent := &p._phase_stack[p._stack_depth - 1]
			_snap_merge_snap(&parent._heap_acc, ph._heap_acc)
			_snap_merge_snap(&parent._temp_acc, ph._temp_acc)
			obench.counting_allocator_reset(p._heap_counter)
			obench.counting_allocator_reset(p._temp_counter)
			p._heap_counter.enforce_zero_allocs = true
			obench.counting_allocator_set_paused(p._heap_counter, false)
			obench.counting_allocator_set_paused(p._temp_counter, false)
		}
	}
}

/*
Scoped RAII helper for a pipeline phase:

	{
		ph := hugi.scoped_phase(p, "HAMT lookup", ops = N)
		...
	}
*/
@(deferred_out = phase_end)
scoped_phase :: proc(
	p: ^Pipeline,
	name: string,
	ops := 1,
	bytes_per_op: u64 = 0,
	zero_alloc := false,
) -> ^Phase {
	return phase_begin(p, name, ops, bytes_per_op, zero_alloc)
}

/*
Records a domain byte footprint (e.g., committed database size) on `ph`.
*/
phase_set_footprint :: proc "contextless" (ph: ^Phase, bytes: u64) {
	if ph != nil {
		ph.footprint_bytes = bytes
	}
}

/*
Records a custom metric (e.g., `"pool_hits"`, `"hit%"`) on `ph`.
*/
phase_metric :: proc "contextless" (ph: ^Phase, value: f64, unit: string) {
	if ph == nil || unit == "" {
		return
	}
	n := min(len(unit), obench.MAX_METRIC_UNIT_LEN)
	for n > 0 && n < len(unit) && unit[n] & 0xC0 == 0x80 {
		n -= 1
	}
	key := unit[:n]
	for i in 0 ..< ph.metrics_count {
		if ph.metrics[i].unit == key {
			ph.metrics[i].value = value
			return
		}
	}
	if ph.metrics_count < MAX_METRICS {
		i := ph.metrics_count
		copy(ph._metric_buf[i][:], key)
		ph.metrics[i] = Metric {
			unit  = string(ph._metric_buf[i][:n]),
			value = value,
		}
		ph.metrics_count += 1
	}
}

@(private = "file")
_acc_set_metric :: proc(
	acc: ^_Phase_Accum,
	unit: string,
	value: f64,
	allocator: runtime.Allocator,
) {
	for i in 0 ..< acc.metrics_count {
		if acc.metrics[i].unit == unit {
			acc.metrics[i].value = value
			return
		}
	}
	if acc.metrics_count < MAX_METRICS {
		i := acc.metrics_count
		acc.metrics[i] = Metric {
			unit  = strings.clone(unit, allocator),
			value = value,
		}
		acc.metrics_count += 1
	}
}

@(private)
_destroy_phase_accums :: proc(accums: []_Phase_Accum, allocator: runtime.Allocator) {
	for &acc in accums {
		delete(acc.name, allocator)
		for i in 0 ..< acc.metrics_count {
			delete(acc.metrics[i].unit, allocator)
		}
		delete(acc.samples_batch_ns)
		delete(acc.samples_cycles)
		for k in 0 ..< 4 {
			delete(acc.samples_hw[k])
		}
	}
}

@(private)
_calibrate_counter_overhead :: proc(counters: ^obench.Counter_Group) -> obench.Counter_Values {
	if counters == nil || !counters.open {
		return {}
	}
	WARMUP :: 8
	SAMPLES :: 32
	for _ in 0 ..< WARMUP {
		b, _ := obench.counter_group_read(counters)
		obench.clobber_memory()
		t0 := obench.clock_now()
		t1 := obench.clock_now()
		obench.clobber_memory()
		a, _ := obench.counter_group_read(counters)
		_ = obench.black_box(t0)
		_ = obench.black_box(t1)
		_ = obench.black_box(b)
		_ = obench.black_box(a)
	}
	best := obench.Counter_Values {
		instructions  = max(f64),
		cycles        = max(f64),
		branch_misses = max(f64),
		cache_misses  = max(f64),
	}
	got_any := false
	for _ in 0 ..< SAMPLES {
		before, ok1 := obench.counter_group_read(counters)
		obench.clobber_memory()
		t0 := obench.clock_now()
		t1 := obench.clock_now()
		obench.clobber_memory()
		after, ok2 := obench.counter_group_read(counters)
		_ = obench.black_box(t0)
		_ = obench.black_box(t1)
		if ok1 && ok2 {
			got_any = true
			best.instructions = min(
				best.instructions,
				max(after.instructions - before.instructions, 0.0),
			)
			best.cycles = min(best.cycles, max(after.cycles - before.cycles, 0.0))
			best.branch_misses = min(
				best.branch_misses,
				max(after.branch_misses - before.branch_misses, 0.0),
			)
			best.cache_misses = min(
				best.cache_misses,
				max(after.cache_misses - before.cache_misses, 0.0),
			)
		}
	}
	if !got_any {
		return {}
	}
	return best
}

@(private)
_execute_pipeline :: proc(
	s: ^Suite,
	def: _Pipeline_Def,
	base_rank: ^int,
	temp_arena: ^runtime.Arena,
	counters: ^obench.Counter_Group = nil,
	counter_overhead: obench.Counter_Values = {},
) -> (
	records: [dynamic]Record,
	violations: [dynamic]Phase_Violation,
) {
	records = make([dynamic]Record, s.allocator)
	violations = make([dynamic]Phase_Violation, s.allocator)

	runs := def.runs > 0 ? def.runs : s.config.runs
	if runs <= 0 {
		runs = 7
	}
	warmup := def.warmup >= 0 ? def.warmup : s.config.warmup
	if warmup < 0 {
		warmup = 1
	}
	if s.obench_suite.config.test_mode {
		warmup = 0
		runs = 1
	}

	clock_ov_fs := ns_f64_to_fs(s.obench_suite.clock.overhead_ns)
	p := Pipeline {
		group_name            = def.group_name,
		param                 = def.param,
		has_param             = def.has_param,
		user_ptr              = def.user_ptr,
		clock_overhead_fs     = clock_ov_fs,
		clock_overhead_cycles = s.obench_suite.clock.overhead_cycles,
		_accums               = make([dynamic]_Phase_Accum, s.allocator),
		_counters             = counters,
		_counter_overhead     = counter_overhead,
		_enforce_zero_alloc   = s.obench_suite.config.enforce_zero_allocs,
		_allocator            = s.allocator,
	}
	defer {
		_destroy_phase_accums(p._accums[:], s.allocator)
		delete(p._accums)
	}

	arena_alloc := runtime.arena_allocator(temp_arena)

	// 1. Warmup passes (unwrapped allocators, untimed).
	p._mode = .Warmup
	for _ in 0 ..< warmup {
		p._slot_cursor = 0
		p._stack_depth = 0
		ctx := context
		ctx.temp_allocator = arena_alloc
		{
			context = ctx
			def.procedure(&p)
		}
		runtime.arena_free_all(temp_arena)
	}

	// 2. Timed passes (unwrapped allocators -> 0 ns Counting_Allocator distortion).
	p._mode = .Timed
	for _ in 0 ..< runs {
		p._slot_cursor = 0
		p._stack_depth = 0
		ctx := context
		ctx.temp_allocator = arena_alloc
		{
			context = ctx
			def.procedure(&p)
		}
		runtime.arena_free_all(temp_arena)
	}

	// 3. One untimed allocation-counting pass across all phases.
	heap_counter: obench.Counting_Allocator
	temp_counter: obench.Counting_Allocator
	obench.counting_allocator_init(&heap_counter, context.allocator)
	obench.counting_allocator_init(&temp_counter, arena_alloc)
	obench.counting_allocator_set_paused(&heap_counter, true)
	obench.counting_allocator_set_paused(&temp_counter, true)

	p._mode = .Alloc_Check
	p._heap_counter = &heap_counter
	p._temp_counter = &temp_counter
	p._slot_cursor = 0
	p._stack_depth = 0
	{
		ctx := context
		ctx.allocator = obench.counting_allocator(&heap_counter)
		ctx.temp_allocator = obench.counting_allocator(&temp_counter)
		{
			context = ctx
			def.procedure(&p)
		}
	}
	runtime.arena_free_all(temp_arena)

	// 4. Materialize records (preserving rank numbers across filtered runs).
	for &acc in p._accums {
		base_rank^ += 1
		rank := base_rank^
		full_name :=
			def.group_name != "" ? strings.clone(fmt.tprintf("%s::%s", def.group_name, acc.name), s.allocator) : strings.clone(acc.name, s.allocator)
		if def.has_param {
			old := full_name
			full_name = strings.clone(fmt.tprintf("%s[%d]", old, def.param), s.allocator)
			delete(old, s.allocator)
		}

		if !matches_name_filter(s.config.name_filter, full_name) {
			delete(full_name, s.allocator)
			continue
		}

		if acc.zero_alloc_failed {
			s.failed_zero_alloc += 1
			append(
				&violations,
				Phase_Violation {
					full_name = strings.clone(full_name, s.allocator),
					loc = acc.violation_loc,
					size = acc.violation_size,
				},
			)
		}

		r := Record {
			rank               = rank,
			group_name         = strings.clone(def.group_name, s.allocator),
			name               = strings.clone(acc.name, s.allocator),
			full_name          = full_name,
			param              = def.param,
			has_param          = def.has_param,
			threads            = 1,
			has_threads        = false,
			ops_per_sample     = u64(max(acc.ops, 1)),
			samples            = len(acc.samples_batch_ns),
			warmup             = warmup,
			bytes_per_op       = acc.bytes_per_op,
			footprint_bytes    = acc.footprint_bytes,
			allocs_per_op      = acc.allocs_per_op,
			resizes_per_op     = acc.resizes_per_op,
			alloc_bytes_per_op = acc.alloc_bytes_per_op,
			temp_allocs_per_op = acc.temp_allocs_per_op,
			temp_bytes_per_op  = acc.temp_bytes_per_op,
			peak_heap_bytes    = acc.peak_heap_bytes,
			zero_alloc_failed  = acc.zero_alloc_failed,
			error              = strings.clone("", s.allocator),
			metrics            = make([dynamic]Metric, acc.metrics_count, s.allocator),
			samples_batch_ns   = make([dynamic]u64, len(acc.samples_batch_ns), s.allocator),
		}
		copy(r.samples_batch_ns[:], acc.samples_batch_ns[:])
		for i in 0 ..< acc.metrics_count {
			r.metrics[i] = Metric {
				unit  = strings.clone(acc.metrics[i].unit, s.allocator),
				value = acc.metrics[i].value,
			}
		}

		recompute_record_stats_from_samples(&r)
		refresh_record_throughput(&r, overwrite = true)
		if len(acc.samples_cycles) > 0 {
			cyc := slice.clone(acc.samples_cycles[:], context.temp_allocator)
			slice.sort(cyc)
			r.median_cycles = obench.percentile_sorted(cyc, 0.50)
		}
		if len(acc.samples_hw[0]) > 0 {
			hw_units := [4]string {
				"instructions/op",
				"cycles/op",
				"branch_misses/op",
				"cache_misses/op",
			}
			for k in 0 ..< 4 {
				vals := slice.clone(acc.samples_hw[k][:], context.temp_allocator)
				slice.sort(vals)
				_append_counter_metric(
					&r.metrics,
					hw_units[k],
					obench.percentile_sorted(vals, 0.50),
					s.allocator,
					allow_zero = k >= 2 && counters != nil && counters.fds[k] >= 0,
				)
			}
		}

		append(&records, r)
	}

	return records, violations
}

@(private)
Phase_Violation :: struct {
	full_name: string,
	loc:       runtime.Source_Code_Location,
	size:      int,
}
