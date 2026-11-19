package hugi_cli

import "core:fmt"
import "core:os"

VERSION :: "hugi 0.1.0"

@(private)
_print_help :: proc() {
	fmt.print(
		`hugi — Odin benchmark runner, compressed xitdb store, and comparison CLI

USAGE:
  hugi <command> [options]

COMMANDS:
  run [pkg_dir]          Build and execute an Odin benchmark package, ingest results into store
  ingest <file...>       Ingest HPKT .hpk/.bpk packets, obench .json reports, or .jsonl histories
  history                List commits or runs stored in the benchmark database
  inspect [filter]       Inspect pooled metrics (quantiles, CV%, allocations, footprint)
  compare                Compare commits or runs using Mann-Whitney U and Welch t-test
  compare-1v1            Cross-language 1v1 comparison (e.g., odin vs zig) with footprint checks
  export                 Export pooled benchmarks to Arrow IPC, Parquet, JSON, JSONL, CSV, TSV, or Markdown
  compact                Compact the xitdb store and reclaim dead pages
  help                   Show this help message
  version                Print version information

COMMON OPTIONS:
  --db <path>            Store path (default: benchmarks/history.hugidb or history.hugidb)
  --lang <lang>          Language tag (default: odin; export also accepts 'all' or '*')
  --commit <sha>         Commit identifier override
  --filter <pat>         Benchmark name substring filter (supports ',' or '|' alternation)

RUN OPTIONS:
  --no-db                Execute package without writing to a store
  --runs <N>             Measured pipeline runs (default: 7)
  --warmup <N>           Warmup iterations / milliseconds (default: 1)
  --groups <g1,g2>       Comma-separated group filter
  --baseline-commit <c>  Compare run immediately against baseline commit <c>
  --fail-on-regression   Exit non-zero if statistical regressions are detected
  --threshold <pct>      Regression threshold percentage (default: 5.0)
  --extra-build-flags s  Extra flags passed to 'odin build' (supports quoted arguments)
  --overlay              Ingest into an in-memory CoW Core_Overlay branch (no disk write)

COMPARE / EXPORT / COMPACT OPTIONS:
  --commits <a..b>       Compare commit <a> against commit <b>
  --runs <a..b>          Compare run_id <a> against run_id <b>
  --last                 Compare the last two commits (or last two runs)
  --langs <a,b>          Languages for compare-1v1 (default: odin,zig)
  --all-commits          Export longitudinal commit-by-commit series (instead of latest snapshot)
  --all-runs             Export every stored run individually (unpooled longitudinal series)
  --format <fmt>         export: arrow | parquet | json | jsonl | csv | tsv | md; compare/compare-1v1: md | json | csv
  --out <path|->         Output path (or '-' to stream text formats to stdout)
  --update-readme <path> Replace <!-- BEGIN_BENCHMARK_TABLE -->..<!-- END_BENCHMARK_TABLE -->
  --limit <N>            Maximum history entries to display (0 = all)
  --keep-hot <N>         Hot recent runs kept unrolled during 'compact' (default: 0)
`,
	)
}

main :: proc() {
	args := os.args[1:] if len(os.args) > 1 else nil
	if len(args) == 0 {
		_print_help()
		os.exit(0)
	}

	code := 0
	switch args[0] {
	case "run":
		code = _cmd_run(args[1:])
	case "ingest":
		code = _cmd_ingest(args[1:])
	case "history":
		code = _cmd_history(args[1:])
	case "inspect":
		code = _cmd_inspect(args[1:])
	case "compare":
		code = _cmd_compare(args[1:])
	case "compare-1v1":
		code = _cmd_compare_1v1(args[1:])
	case "export":
		code = _cmd_export(args[1:])
	case "compact":
		code = _cmd_compact(args[1:])
	case "help", "--help", "-h":
		_print_help()
	case "version", "--version", "-V":
		fmt.println(VERSION)
	case:
		fmt.eprintfln("hugi: unknown command '%s' (run 'hugi help' for usage)", args[0])
		code = 1
	}
	os.exit(code)
}
