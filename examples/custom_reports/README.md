# Custom Benchmark Rendering Examples

`hugi` separates measurement, compressed history, and statistical testing from presentation. Use the built-in `--update-readme` table when a single flat table fits your project, or pick one of the client-side rendering patterns below when you need grouped tables, custom columns, or multi-language pivots.

## 1. Built-In Zero-Config Markdown (`hugi export --update-readme`)

Ideal for single-suite projects that want a clean 9-column table without any custom renderer code:

```bash
hugi run ./benchmarks --runs 5
hugi export --db benchmarks/history.hugidb --update-readme README.md
```

## 2. Pure-Odin Grouped Renderer (`examples/custom_markdown_odin`)

Uses `hugi_store` directly (`store_load_pooled_records` + `update_readme_markers`) to group benchmarks by `group_name` and switch throughput units (`MB/s` vs `ops/s`):

```bash
make example
odin run examples/custom_markdown_odin \
  -collection:hugi=./hugi -collection:hugi_store=./store \
  -collection:obench=./deps/obench/obench -collection:xitdb=./deps/xitdb/xitdb -collection:skadi=./deps/skadi/skadi \
  -- --db .tmp/example.hugidb
```

## 3. Ahead-of-Time `temple` Templates over `hugi export --format json --out -`

When you want custom HTML or Markdown templates compiled directly into your Odin repository without linking `xitdb`, `skadi`, or `zlib`, invoke `hugi export --format json --out -` (or `hugi compare --format json`), unmarshal with `core:encoding/json`, and render with [`boxxxie/temple`](https://github.com/boxxxie/temple).

See [`temple/tools/bench_report/`](../../../temple/tools/bench_report/) for a full working reference that updates both `benchmarks/README.md` (grouped tables) and `README.md` (headline table) from `history.hugidb`.

## 4. Analytical SQL (`duckdb_report.sql`) & Multi-Language JSON (`render_1v1_report.py`)

Export Parquet or JSON to stdout (`--out -`) and drive custom latency-tiered tables or 1v1 reports:

```bash
# Latency tiers + commit deltas via DuckDB SQL over Parquet
hugi export --db .tmp/example.hugidb --all-commits --out .tmp/example.parquet
duckdb -markdown -light-mode -f examples/custom_reports/duckdb_report.sql

# Cross-language 1v1 + snapshot Markdown via stdlib Python
python3 examples/custom_reports/render_1v1_report.py --db benchmarks/history.hugidb --langs odin,zig
```
