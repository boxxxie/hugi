package hugi_tests

import hugi "../hugi"
import store "../store"
import "core:math"
import "core:strings"
import "core:testing"

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

@(test)
test_compare_records_handles_zero_fs_baselines :: proc(t: ^testing.T) {
	base_arr := make([]store.Pooled_Record, 1)
	base_arr[0] = store.Pooled_Record {
		full_name  = strings.clone("simd::clamped_zero"),
		samples    = 8,
		p50_fs     = 0,
		mean_fs    = 0,
		samples_fs = make([dynamic]i64, 8),
	}
	defer store.pooled_records_destroy(base_arr)

	cand_reg := make([]store.Pooled_Record, 1)
	cand_reg[0] = store.Pooled_Record {
		full_name  = strings.clone("simd::clamped_zero"),
		samples    = 8,
		p50_fs     = 50_000_000,
		mean_fs    = 50_000_000,
		samples_fs = make([dynamic]i64, 8),
	}
	for i in 0 ..< 8 {
		cand_reg[0].samples_fs[i] = 50_000_000 + i64(i) * 1_000
	}
	defer store.pooled_records_destroy(cand_reg)

	rep_reg := store.compare_records(base_arr, cand_reg, threshold_pct = 5.0)
	defer store.comparison_report_destroy(&rep_reg)
	testing.expect_value(t, len(rep_reg.rows), 1)
	testing.expect_value(t, rep_reg.regressions, 1)
	if len(rep_reg.rows) == 1 {
		testing.expect_value(t, rep_reg.rows[0].verdict, store.Verdict.Regression)
		testing.expect(t, rep_reg.rows[0].is_significant, "0 fs -> 50 ns must be significant")
	}

	cand_same := make([]store.Pooled_Record, 1)
	cand_same[0] = store.Pooled_Record {
		full_name  = strings.clone("simd::clamped_zero"),
		samples    = 8,
		p50_fs     = 0,
		mean_fs    = 0,
		samples_fs = make([dynamic]i64, 8),
	}
	defer store.pooled_records_destroy(cand_same)

	rep_same := store.compare_records(base_arr, cand_same, threshold_pct = 5.0)
	defer store.comparison_report_destroy(&rep_same)
	testing.expect_value(t, len(rep_same.rows), 1)
	testing.expect_value(t, rep_same.unchanged, 1)
	if len(rep_same.rows) == 1 {
		testing.expect_value(t, rep_same.rows[0].verdict, store.Verdict.Unchanged)
		testing.expect_value(t, rep_same.rows[0].delta_pct, 0.0)
	}
}
