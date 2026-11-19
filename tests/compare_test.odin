package hugi_tests

import hugi "../hugi"
import store "../store"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"

@(test)
test_pooling_and_mann_whitney_welch :: proc(t: ^testing.T) {
	st, ok := store.store_open(":memory:")
	testing.expect(t, ok, "in-memory store should open")
	defer store.store_close(&st)

	for i in 0 ..< 3 {
		rid_b := fmt.tprintf("base-%d", i)
		pb := _make_packet(
			"base111",
			"odin",
			rid_b,
			"kv",
			[]string{"scan"},
			[]f64{100.0 + f64(i) * 0.2},
			[]u64{8192},
			samples_per_rec = 10,
			spread_ns = 0.2,
		)
		testing.expect(t, store.store_ingest_packet(&st, pb), "baseline run ingest")
		hugi.packet_destroy(&pb)

		rid_c := fmt.tprintf("cand-%d", i)
		pc := _make_packet(
			"cand222",
			"odin",
			rid_c,
			"kv",
			[]string{"scan"},
			[]f64{140.0 + f64(i) * 0.2},
			[]u64{8192},
			samples_per_rec = 10,
			spread_ns = 0.2,
		)
		testing.expect(t, store.store_ingest_packet(&st, pc), "candidate run ingest")
		hugi.packet_destroy(&pc)
	}

	base := store.store_load_pooled_records(&st, "odin", "base111")
	defer store.pooled_records_destroy(base)
	cand := store.store_load_pooled_records(&st, "odin", "cand222")
	defer store.pooled_records_destroy(cand)

	testing.expect_value(t, len(base), 1)
	testing.expect_value(t, base[0].run_count, 3)
	testing.expect_value(t, base[0].samples, 30)

	rep := store.compare_records(base, cand, threshold_pct = 5.0)
	defer store.comparison_report_destroy(&rep)
	testing.expect_value(t, len(rep.rows), 1)
	testing.expect_value(t, rep.regressions, 1)
	testing.expect_value(t, rep.rows[0].verdict, store.Verdict.Regression)
	testing.expect(t, rep.rows[0].p_value < 0.01, "expected significant Mann-Whitney p-value")
	testing.expect(t, rep.rows[0].delta_pct > 25.0, "expected >25% positive regression delta")
}

@(test)
test_compare_1v1_and_footprint_mismatch :: proc(t: ^testing.T) {
	st, ok := store.store_open(":memory:")
	testing.expect(t, ok, "in-memory store should open")
	defer store.store_close(&st)

	po := _make_packet(
		"cmp001",
		"odin",
		"run-shared-001",
		"db",
		[]string{"fast_op", "db_op"},
		[]f64{50.0, 120.0},
		[]u64{4096, 4096},
	)
	defer hugi.packet_destroy(&po)
	pz := _make_packet(
		"cmp001",
		"zig",
		"run-shared-001",
		"db",
		[]string{"fast_op", "db_op"},
		[]f64{100.0, 118.0},
		[]u64{4096, 16384},
	)
	defer hugi.packet_destroy(&pz)

	testing.expect(t, store.store_ingest_packet(&st, po), "ingest odin packet")
	testing.expect(t, store.store_ingest_packet(&st, pz), "ingest zig packet")

	rep := store.compare_1v1_langs(&st, "odin", "zig", "cmp001", threshold_pct = 3.0)
	defer store.cross_lang_report_destroy(&rep)

	testing.expect_value(t, len(rep.rows), 2)
	testing.expect_value(t, rep.footprint_mismatches, 1)
	testing.expect_value(t, rep.rows[0].faster_lang, "odin")
	testing.expect_value(t, rep.rows[0].footprint_mismatch, false)
	testing.expect_value(t, rep.rows[1].footprint_mismatch, true)
}

@(test)
test_small_sample_significance_parity :: proc(t: ^testing.T) {
	make_custom_pkt :: proc(lang, run_id: string, batches: [4]u64) -> hugi.Run_Packet {
		pkt := hugi.Run_Packet {
			suite_name     = strings.clone("sm_suite"),
			lang           = strings.clone(lang),
			commit         = strings.clone("sm001"),
			run_id         = strings.clone(run_id),
			os             = strings.clone("linux"),
			arch           = strings.clone("amd64"),
			optimization   = strings.clone("Speed"),
			odin_version   = strings.clone("test"),
			timestamp_unix = 1700000000,
			records        = make([dynamic]hugi.Record, 0, 1),
		}
		samples := make([dynamic]u64, 4)
		for v, i in batches {
			samples[i] = v
		}
		r := hugi.Record {
			rank             = 1,
			group_name       = strings.clone("core"),
			name             = strings.clone("small_op"),
			full_name        = strings.clone("core::small_op"),
			ops_per_sample   = 100,
			samples          = 4,
			samples_batch_ns = samples,
			metrics          = make([dynamic]hugi.Metric),
		}
		hugi.recompute_record_stats_from_samples(&r)
		hugi.refresh_record_throughput(&r)
		append(&pkt.records, r)
		return pkt
	}

	st, ok := store.store_open(":memory:")
	testing.expect(t, ok, "in-memory store should open")
	if !ok {
		return
	}
	defer store.store_close(&st)

	po := make_custom_pkt("odin", "sm-odin-1", [4]u64{10_000, 10_100, 10_200, 10_300})
	defer hugi.packet_destroy(&po)
	pz := make_custom_pkt("zig", "sm-zig-1", [4]u64{20_000, 20_100, 20_200, 500_000})
	defer hugi.packet_destroy(&pz)

	testing.expect(t, store.store_ingest_packet(&st, po), "ingest odin small-sample packet")
	testing.expect(t, store.store_ingest_packet(&st, pz), "ingest zig small-sample packet")

	base_odin := store.store_load_pooled_records(&st, "odin", "sm001")
	defer store.pooled_records_destroy(base_odin)
	cand_zig := store.store_load_pooled_records(&st, "zig", "sm001")
	defer store.pooled_records_destroy(cand_zig)

	cmp_rep := store.compare_records(base_odin, cand_zig, threshold_pct = 5.0)
	defer store.comparison_report_destroy(&cmp_rep)

	lang_rep := store.compare_1v1_langs(&st, "odin", "zig", "sm001", threshold_pct = 5.0)
	defer store.cross_lang_report_destroy(&lang_rep)

	testing.expect_value(t, len(cmp_rep.rows), 1)
	testing.expect_value(t, len(lang_rep.rows), 1)
	if len(cmp_rep.rows) == 1 && len(lang_rep.rows) == 1 {
		testing.expect(
			t,
			cmp_rep.rows[0].p_value < 0.05,
			"expected MWU p < 0.05 for separated n=4",
		)
		testing.expect(
			t,
			math.abs(cmp_rep.rows[0].p_value - lang_rep.rows[0].p_value) < 1e-12,
			"compare_records and compare_1v1_langs must compute identical MWU p-values",
		)
		testing.expect(t, cmp_rep.rows[0].is_significant, "compare_records must be significant")
		testing.expect(
			t,
			lang_rep.rows[0].is_significant,
			"compare_1v1_langs must agree on significance",
		)
	}
}
