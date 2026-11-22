# CLI Reference & CI Workflows

The `hugi` CLI manages building and running benchmark suites, ingesting external results, inspecting history, gating regressions, compacting `.hugidb` stores, and exporting reports.

---

## 1. Database Path Resolution & Environment Variables

### Default Store Path (`--db`) & `hugi.json`

When `--db <path>` is omitted, `hugi` resolves the database path in this order:
1. If a `hugi.json` exists between `.` and the `.git` root with a non-empty `"db"` field, uses that path (resolved relative to the directory containing `hugi.json`).
2. Else if a `./benchmarks` directory exists in the current working directory:
   * Uses `benchmarks/history.benchdb` only if that legacy file already exists and `benchmarks/history.hugidb` does not.
   * Otherwise defaults to `benchmarks/history.hugidb`.
3. Otherwise defaults to `./history.hugidb`.

`hugi run` also walks upward for `hugi.json` (starting from `[pkg_dir]` if supplied, else `.`) to populate defaults for `pkg_dir`, `db`, `runs`, `warmup`, and `extra_build_flags` whenever the corresponding CLI flags are omitted.

### Flag Syntax

All CLI commands accept non-empty flags in any of three forms:
* `--db path/to/history.hugidb`
* `--db=path/to/history.hugidb`
* `--db:path/to/history.hugidb`

> **Empty Values:** Because the CLI parser checks `inline_val != ""`, passing an empty value inline (`--lang=""` or `--lang:`) treats the value as missing and consumes the *next* CLI token instead. Always pass empty flag values as two separate tokens (e.g., `--lang ""`).

### Environment Variables

| Variable | Used By | Description |
| :--- | :--- | :--- |
| `ODIN` | `hugi run` | Path to the Odin compiler executable (defaults to `odin` on `PATH`). |
| `HUGI_HOME` | `hugi run` | Path to the `hugi` repository root; used to inject `-collection:hugi` and `-collection:obench` when they are not defined in `ols.json`. (If unset, `hugi run` walks upward from the resolved binary location—which works when `bin/hugi` is symlinked via `make install`, whereas a copied binary requires `HUGI_HOME` or `ols.json`.) |

---

## 2. Git Commit Resolution

Unless `--commit <sha>` is explicitly passed, `hugi` resolves the 12-character Git HEAD SHA automatically without spawning a `git` subprocess (`hugi.resolve_git_commit`):

* Walks upward from the working directory to find `.git`.
* Supports standard `.git/` directories, detached `HEAD`s, loose branch refs (`.git/refs/heads/*`), and `.git/packed-refs` (ignoring comments and peeled `^` tag lines).
* Supports **linked Git worktrees** where `.git` is a pointer file (`gitdir: ...`) referencing a worktree directory with a `commondir` file.
* Falls back cleanly to `"unknown"` when executed outside a Git repository.

---

## 3. Subcommand Reference

### `hugi run [pkg_dir]`

Compiles `[pkg_dir]` (defaults to `.`), executes the temporary binary to produce an `HPKT\x02` packet, ingests the packet into the store, and optionally compares against a baseline commit.

```sh
hugi run ./benchmarks \
  --db benchmarks/history.hugidb \
  --runs 7 \
  --warmup 1 \
  --groups "hash,kv" \
  --filter "fnv1a|lookup" \
  --baseline-commit a1b2c3d4e5f6 \
  --threshold 5.0 \
  --fail-on-regression
```

| Option | Default | Description |
| :--- | :--- | :--- |
| `--db <path>` | Auto | Target `.hugidb` path. |
| `--no-db` | `false` | Build and run benchmarks without opening or writing to any database. |
| `--overlay` | `false` | Open the `.hugidb` file inside a Copy-on-Write RAM overlay (`Core_Overlay`); leaves disk untouched. |
| `--runs <N>` | `7` | Number of timed `Pipeline` passes (ignored by micro-benchmarks). |
| `--warmup <N>` | `1` | Warmup passes for `Pipeline` groups; when explicitly passed, also sets micro-benchmark warmup to `<N> ms`. |
| `--groups <list>` | All | Comma or `\|` separated group filter. Marks packet `selective = true` when non-empty and not `"all"`. |
| `--filter <pat>`, `-f` | All | Substring filter on benchmark `full_name` (`,` or `\|` alternation). Marks packet `selective = true`. |
| `--lang <lang>` | `odin` | Language identifier tag (lowercased automatically by both CLI subcommands and compiled binaries). |
| `--commit <sha>` | Git HEAD | Override commit identifier (stored verbatim; pass 12-char SHAs like `${GITHUB_SHA:0:12}` to pool with auto-detected Git commits). |
| `--baseline-commit <c>` | None | Immediately run statistical comparison against commit `<c>` (prefix-matched against stored SHAs, including 40-char hex SHAs against stored 12-char SHAs; expand symbolic refs like `HEAD` or `main` with `git rev-parse --short=12`). |
| `--threshold <pct>` | `5.0` | Minimum relative median delta percentage required to flag a regression/improvement. |
| `--fail-on-regression` | `false` | Exit `1` if any statistically significant regression is detected, or `3` (`EXIT_BASELINE`) if comparisons are only undecided (`too_few_samples`). |
| `--extra-build-flags <s>` | `""` | Extra flags appended to `odin build` with quote-aware splitting (e.g., `'-extra-linker-flags:"-L/usr/local/lib -Wl,-rpath,/usr/local/lib"'`). |
| `--quiet` | `false` | Suppress benchmark runner terminal report (comparison table still prints if `--baseline-commit` is set). |

> **Binary-Only Flags, Failing Runs & `run_id` Granularity:**
> * `--run-id` and `--packet-out` are managed internally by `hugi run` and rejected if passed to `hugi run` directly (they apply only when executing a compiled benchmark binary standalone).
> * If the benchmark binary writes a packet and exits non-zero due to `@zero_alloc` violations or benchmark errors, `hugi run` still ingests that packet into `.hugidb` (whenever `--no-db` is omitted) before exiting `1`. Pass `--overlay` or `--no-db` during local debugging to avoid updating your committed `.hugidb` snapshot.
> * `default_run_id()` generates `run-<unix_seconds>`, so two runs of the same `--lang` executed within the same wall-clock second overwrite each other on `(lang, run_id)`.

---

### `hugi ingest <file...>`

Ingests one or more external benchmark artifacts into `.hugidb`. File type is detected via magic bytes (`HPKT`) or file extension (`.hpk`, `.bpk`, `.jsonl`, `.json`).

```sh
# Ingest binary packets, obench JSON exports, or external JSONL logs with provenance
hugi ingest out/odin.hpk out/zig_bench.jsonl --db benchmarks/history.hugidb --commit a1b2c3d4e5f6 \
  --capture-host-env --build-flags "-O3" --runtime-version "Apache Arrow C++ 25.0.1"
```

* Accepts `--db`, `--lang`, `--commit`, `--capture-host-env`, `--build-flags <str>`, and `--runtime-version <str>` (rejects `--filter` / `-f`). `--lang <lang>` and `--commit <sha>` override the language or commit embedded in the input files.
* **Run ID collisions on batch ingest:** `hugi ingest` passes an empty `run_id_override` to `read_obench_json_packets` (which falls back to `run-<unix_seconds>`), so ingesting multiple `obench` `.json` files in one second assigns identical `(lang, run_id)` keys and the later file overwrites the earlier one. Similarly, `.jsonl` rows omitting `"run_id"` default to `jsonl-<commit>-<lang>`—set explicit `"run_id"` values in JSONL when ingesting multiple runs for the same `(commit, lang)`.

---

### `hugi doctor`

Checks host CPU model, `scaling_governor`, `scaling_max_freq` vs. `cpuinfo_max_freq`, boost/turbo status, and the nearest `hugi.json` configuration.

```sh
hugi doctor           # Human-readable host & config summary
hugi doctor --strict  # Exit 1 if clock clamping, non-performance governor, or boost-off warnings exist
hugi doctor --format json
```

---

### `hugi history`

Lists chronological commits (default) or individual runs stored in the database, ordered newest-first. Only accepts `--db` (plus `--commits` / `--runs` / `--limit`); rejects `--lang`, `--commit`, and `--filter`.

```sh
hugi history --db benchmarks/history.hugidb --commits --limit 15
hugi history --db benchmarks/history.hugidb --runs --limit 20
```

---

### `hugi inspect [filter]`

Prints a Markdown summary table of pooled benchmarks and (when `<= 25` benchmarks match) a full quantile breakdown (`min`, `p25`, `p50`, `p75`, `p95`, `p99`, `ci95`, `iqr`, `mad`, `allocs`, `footprint`). Defaults to `--lang odin` (pass `--lang <lang>` for external languages or `--lang all` for all languages).

```sh
# Inspect latest snapshot for Odin
hugi inspect --db benchmarks/history.hugidb

# Inspect a specific commit prefix or individual run_id
hugi inspect "kv::" --commit a1b2c3d4 --lang odin
hugi inspect --run run-1770000120 --lang zig
```

> **Retired/Renamed Benchmarks in Snapshots:** Default Snapshot mode (`--commit` omitted) tracks the latest seen observation per benchmark name and retains benchmarks from earlier commits even after a non-selective run removes or renames them. Pass `--commit <sha>` to inspect only the benchmarks present in a specific commit.

---

### `hugi compare`

Compares two commits or two run IDs within a single language (defaults to `--lang odin`) using exact 95% Hodges-Lehmann shift confidence intervals (when both sides have enough samples/runs: `4+ vs 4+`, `3 vs 5+`, or `2 vs 8+`) or Welch's `t`-test when raw samples are absent. Comparisons with raw samples/runs too small for an exact 95% interval (`2 vs <=7` or `3 vs 3..4`) remain undecided (`too_few_samples`), warn, and exit `3` (`EXIT_BASELINE`) under `--fail-on-regression` when no regressions occur; multi-run asymmetry (one side with multiple runs and the other with one) also warns. Supports `--format <md|json|csv>` (auto-inferred from `--out` extension if omitted, defaulting to `md`) and `--out <path|->`. Note that `--last` compares the last two entries from `store_list_commits`, which orders commits by their *first* appearance in `.hugidb`—re-running an older commit pools into its existing slot without moving it to the end (use `--runs <r1>..<r2>` for run-to-run comparison on an existing commit).

```sh
# Compare the last two commits for a language (falls back to last two runs if only 1 commit exists)
hugi compare --last

# Compare two commit prefixes (expand symbolic refs like main/HEAD via git rev-parse) and fail non-zero on regressions >= 3.0%
hugi compare --commits a1b2c3d4..f9e8d7c6 --threshold 3.0 --fail-on-regression
hugi compare --commits "$(git rev-parse --short=12 main)..$(git rev-parse --short=12 HEAD)" --threshold 3.0 --fail-on-regression

# Emit machine-readable JSON to stdout for custom downstream renderers or CI comments
hugi compare --last --format json --out -

# Compare two specific run IDs
hugi compare --runs run-1770000100..run-1770000500 --filter "scan"
```

---

### `hugi compare-1v1`

Runs a cross-language head-to-head comparison on exact-matching `full_name` benchmarks, reporting winners, speedups, Hodges-Lehmann shift CI / Mann-Whitney U `p`-values, unmatched benchmarks (`Only in <lang>`), and domain memory/disk footprint mismatches (`[MISMATCH]`). Accepts `--db`, `--commit`, `--threshold`, `--langs`, `--format`, and `--out` (rejects `--lang` and `--filter` / `-f`). When raw sample counts cannot yield an exact 95% Hodges-Lehmann interval (`2 vs <=7`, `3 vs 3..4`), rows are marked undecided (`too_few_samples`, non-significant) and asymmetric multi-run sides emit a warning.

```sh
hugi compare-1v1 --db benchmarks/history.hugidb --langs odin,zig --commit a1b2c3d4
hugi compare-1v1 --db benchmarks/history.hugidb --langs odin,zig --format json --out -
```

> **Tie Threshold vs. `--threshold`:** `hugi compare-1v1` declares a `"tie"` whenever relative `p50` difference is `< 0.5%`, and otherwise reports the faster language and Mann-Whitney U `p`-value. While `--threshold <pct>` (default `3.0`) sets `Cross_Lang_Row.is_significant` in the programmatic `hugi_store` API (`compare_1v1_langs`), the CLI table winner column and summary win/tie counts are gated only by the `0.5%` tie threshold.

---

### `hugi export`

Exports records in any of 7 formats (`arrow`, `parquet`, `json`, `jsonl`, `csv`, `tsv`, `md`) and/or updates `README.md` benchmark markers in-place. Format is inferred automatically from `--out` extension (or defaults to `md` when only `--update-readme` is passed). Pass `--out -` to stream text formats (`json`, `jsonl`, `csv`, `tsv`, `md`) cleanly to `stdout` without status chatter (`arrow` and `parquet` require a file path). Defaults to `--lang odin`; pass `--lang <lang>` for non-Odin data or `--lang all` (or `*`) to export across all languages.

```sh
# Latest pooled snapshot -> Markdown file + README marker replacement
hugi export --out reports/latest.md --update-readme README.md

# Stream pooled snapshot JSON or multi-language JSONL directly to stdout for custom renderers
hugi export --db benchmarks/history.hugidb --format json --out -
hugi export --db benchmarks/history.hugidb --lang all --all-commits --format jsonl --out -

# Longitudinal commit-by-commit time series -> Parquet / Arrow IPC
hugi export --all-commits --out reports/series.parquet
hugi export --all-commits --out reports/series.arrow

# Unpooled individual run history across all languages -> JSONL
hugi export --lang all --all-runs --out reports/all_runs.jsonl
```

> **Note:** `--all-commits`, `--all-runs`, and `--commit <sha>` are mutually exclusive scopes (and `hugi export` has no `--run <id>` flag, unlike `hugi inspect --run <id>`). As with `hugi inspect`, default Snapshot exports retain previously recorded benchmarks even if a later commit removed or renamed them unless `--commit <sha>` is specified.

---

### `hugi compact`

Seals unrolled hot runs into transposed columnar cold chunks (`CZCH\x02`), reclaims dead Copy-on-Write pages via `xitdb.database_compact`, and atomically replaces the `.hugidb` file.

```sh
# Seal all runs into cold columnar chunks (maximum compression)
hugi compact --db benchmarks/history.hugidb --keep-hot 0

# Keep the 4 most recent runs unsealed as hot CZPK packets
hugi compact --db benchmarks/history.hugidb --keep-hot 4
```

---

## 4. Recommended Git & CI Workflows

### Making `git diff` Readable on `.hugidb` Files (`.gitattributes`)

If you commit `benchmarks/history.hugidb` directly to your repository (which is practical because `.hugidb` compresses longitudinal histories down to kilobytes), add `.gitattributes` so Git treats `.hugidb` as binary and uses `hugi` for human-readable diffs:

```gitattributes
*.hugidb binary diff=hugidb
*.hpk binary
```

Developers can then opt into readable `git diff` / `git log -p` output locally with one Git config command:

```sh
git config diff.hugidb.textconv "sh -c 'hugi history --db \"$1\" && echo \"\" && hugi inspect --db \"$1\"' --"
```

### Local Iteration with `--overlay`

When tuning an algorithm locally before committing, use `--overlay` so trial runs never pollute your committed `history.hugidb` on disk. Because `--baseline-commit` performs a literal SHA prefix match (without invoking `git`), expand `HEAD` via `git rev-parse --short=12` and pass a distinct `--commit` tag so the trial run does not pool into `HEAD`:

```sh
hugi run ./benchmarks \
  --db benchmarks/history.hugidb \
  --overlay \
  --commit wip-simd \
  --baseline-commit "$(git rev-parse --short=12 HEAD)" \
  --filter "simd::"
```

### GitHub Actions PR Regression Gate

```yaml
name: Benchmark Audit

on:
  pull_request:
    branches: [main]

jobs:
  benchmark-gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Setup Odin
        uses: LukeL99/setup-odin@v2

      - name: Build hugi
        run: make -C deps/hugi build

      - name: Run & Gate Against Base Commit
        run: |
          BASE_SHA=$(git rev-parse --short=12 "${{ github.event.pull_request.base.sha }}")
          ./deps/hugi/bin/hugi run ./benchmarks \
            --db benchmarks/history.hugidb \
            --overlay \
            --baseline-commit "$BASE_SHA" \
            --threshold 5.0 \
            --fail-on-regression
```

> **Note on `BASE_SHA` History:** `--baseline-commit "$BASE_SHA"` requires `BASE_SHA` itself to have a recorded entry in `benchmarks/history.hugidb`. If `main` receives commits that did not re-run benchmarks (such as docs-only changes), copy `benchmarks/history.hugidb` to `.tmp/ci.hugidb`, run `./deps/hugi/bin/hugi run ./benchmarks --db .tmp/ci.hugidb`, and run `./deps/hugi/bin/hugi compare --db .tmp/ci.hugidb --last --threshold 5.0 --fail-on-regression` to gate against the most recent recorded commit in `.hugidb`.

> **CI Tip:** Hardware runners on shared cloud VMs exhibit higher clock jitter than bare-metal workstations. Prefer higher `--runs` for `Pipeline` groups (e.g., `--runs 11`; for `obench` micro-benchmarks, raise `cfg.obench_cfg.sample_count` in code or invoke `hugi run` multiple times on the same commit to pool samples), use `--threshold 5.0` (or `7.5` on shared runners), or run baseline and candidate back-to-back on the same runner inside an `--overlay` store before calling `hugi compare`.