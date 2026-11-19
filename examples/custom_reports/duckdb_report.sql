-- Custom benchmark report queries over a hugi Parquet export.
-- Generate input first:
--   hugi export --db .tmp/example.hugidb --all-commits --out .tmp/example.parquet
-- Then run:
--   duckdb -markdown -light-mode -f examples/custom_reports/duckdb_report.sql

-- 1. Latency-tiered Markdown summary for the latest recorded commit per benchmark
WITH ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY lang, full_name ORDER BY timestamp_unix DESC) AS rn
    FROM read_parquet('.tmp/example.parquet')
)
SELECT
    CASE
        WHEN p50_ns < 100.0 THEN '1. Sub-100ns'
        WHEN p50_ns < 1000.0 THEN '2. Sub-microsecond'
        ELSE '3. Microsecond+'
    END AS tier,
    full_name AS benchmark,
    ROUND(p50_ns, 2) AS p50_ns,
    ROUND(p95_ns, 2) AS p95_ns,
    ROUND(cv_pct, 1) AS cv_pct,
    ROUND(ops_per_sec, 0) AS ops_per_sec,
    ROUND(mb_per_sec, 1) AS mb_per_sec,
    ROUND(allocs_per_op, 1) AS allocs_per_op
FROM ranked
WHERE rn = 1
ORDER BY tier, p50_ns ASC;

-- 2. Longitudinal commit-over-commit median delta (%)
WITH series AS (
    SELECT
        commit,
        full_name,
        p50_ns,
        LAG(p50_ns) OVER (PARTITION BY lang, full_name ORDER BY timestamp_unix ASC) AS prev_p50_ns
    FROM read_parquet('.tmp/example.parquet')
)
SELECT
    commit,
    full_name AS benchmark,
    ROUND(prev_p50_ns, 2) AS prev_ns,
    ROUND(p50_ns, 2) AS curr_ns,
    ROUND(((p50_ns - prev_p50_ns) / NULLIF(prev_p50_ns, 0)) * 100.0, 2) AS delta_pct
FROM series
WHERE prev_p50_ns IS NOT NULL
ORDER BY full_name, commit;
