package main

import bench "../../bench"
import "core:fmt"
import "core:os"

@(private = "file")
_fnv1a_bytes :: proc(data: []u8) -> u64 {
	h := u64(14695981039346656037)
	for b in data {
		h ~= u64(b)
		h *= 1099511628211
	}
	return h
}

@(private = "file")
_bench_hash :: proc(b: ^bench.Bencher) {
	n := max(bench.param(b), 16)
	buf := make([]u8, n)
	defer delete(buf)
	for i in 0 ..< n {
		buf[i] = u8((i * 131 + 17) & 0xff)
	}

	bench.set_bytes(b, u64(n))
	bench.expect_zero_allocs(b)

	for bench.step(b) {
		_ = bench.black_box(_fnv1a_bytes(buf))
	}
}

@(private = "file")
_bench_kv_pipeline :: proc(p: ^bench.Pipeline) {
	n := 256
	if p.has_param && p.param > 0 {
		n = p.param
	}

	table := make(map[u64]u64, n)
	defer delete(table)

	{
		ph := bench.scoped_phase(p, "insert", ops = n, bytes_per_op = 16)
		for i in 0 ..< n {
			k := u64(i * 2654435761)
			table[k] = k ~ u64(i)
		}
		bench.phase_set_footprint(ph, u64(len(table) * 16))
	}

	{
		ph := bench.scoped_phase(p, "lookup", ops = n, bytes_per_op = 8, zero_alloc = true)
		hits := 0
		for i in 0 ..< n {
			k := u64(i * 2654435761)
			if v, ok := table[k]; ok {
				_ = bench.black_box(v)
				hits += 1
			}
		}
		bench.phase_metric(ph, f64(hits) / f64(n) * 100.0, "hit%")
	}

	{
		ph := bench.scoped_phase(p, "scan", ops = n, bytes_per_op = 16, zero_alloc = true)
		acc := u64(0)
		for k, v in table {
			acc ~= k + v
		}
		_ = bench.black_box(acc)
		bench.phase_set_footprint(ph, u64(len(table) * 16))
	}
}

main :: proc() {
	suite := bench.suite_create("micro_and_phases")
	defer bench.suite_destroy(&suite)

	hash_group := bench.group_add(&suite, "hash")
	bench.group_params(hash_group, []int{64, 256})
	bench.group_bench(hash_group, "fnv1a", _bench_hash, zero_alloc = true)

	bench.group_pipeline(&suite, "kv_lifecycle", _bench_kv_pipeline, param = 256, has_param = true)

	if !bench.suite_run(&suite) {
		fmt.eprintln("example suite failed")
		os.exit(1)
	}
}
