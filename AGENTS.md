# Agent Guidelines for `hugi` (`odin/hugi`)

This repository provides a pure-Odin benchmarking library (`hugi`), a compressed transactional history store and cross-run/cross-language comparator (`hugi_store` built on `xitdb` + `skadi`), and a CLI (`bin/hugi`).

## Build, Format, Check, and Test Commands

Run all commands from the repository root:

```bash
make fmt          # Format all project .odin files with odinfmt -config:odinfmt.json
make fmt-check    # Verify formatting cleanly (fails on any diff)
make check        # Strict compiler/vet checks across all 6 packages
make test         # Run tests with -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
make specs        # Run 4-layer ATDD specs & property tests in specs/
make build        # Build -o:speed CLI binary at bin/hugi
```

## Architectural Boundaries & Dependency Rules

1. **Keep `hugi/` completely isolated from `xitdb` and `skadi`:**
   - `hugi/` (`package hugi`) may ONLY import `base:*`, `core:*`, and `../deps/obench/obench`.
   - `hugi/` must NEVER import `deps/xitdb` or `deps/skadi`. Downstream projects such as `xitdb`, `skadi`, and `heimdall` import `hugi` to execute benchmarks; keeping `hugi` free of storage/columnar dependencies avoids circular package dependencies.
   - All persistence, sample compression, statistical pooling/comparison, and Arrow IPC export live in `store/` (`package hugi_store`).

2. **Relative dependency imports vs collection imports:**
   - Internal files import `../hugi`, `../store`, `../deps/obench/obench`, `../deps/xitdb/xitdb`, and `../deps/skadi/skadi` via relative paths so package identities remain unambiguous. Never mix a collection import (`hugi:...`) and a relative import (`../hugi`) targeting the same directory inside a single build graph.

3. **Compiler flag split (`-disallow-do`):**
   - Check `hugi/` with strict flags including `-disallow-do`:
     `-vet -vet-tabs -vet-style -vet-cast -strict-style -warnings-as-errors -disallow-do`
   - Do NOT pass `-disallow-do` when building or checking `store/`, `cmd/hugi/`, `examples/`, `tests/`, or `specs/` because `deps/xitdb/xitdb/lua.odin` uses `do`. Always use:
     `-vet -strict-style -vet-tabs -warnings-as-errors -vet-packages:hugi,hugi_store,hugi_cli,hugi_tests,hugi_specs`
   - Still avoid `do` statements and preserve hard tabs across every `.odin` file written in this repository.

## `xitdb` Storage Invariants

- Root `history` is a `Write_Array_List` / `Read_Array_List` of `Hash_Map` moments:
  - Pass empty `xitdb.Slot{}` when creating Moment 0.
  - Pass `latest_slot.?` from `array_list_get_slot(history.read_array_list, -1)` for every subsequent moment so history preserves structural sharing and lineage.
- `Store.core` is heap-allocated (`new(xitdb.Core, allocator)`) before `xitdb.database_init` because `xitdb.Database` holds a pointer to `Core`; `Store` must stay movable by value without invalidating `st.db.core`.
- Always close any active `Store` before calling `store_compact(db_path)`. `store_compact` opens the destination file with `{.Read, .Write, .Create, .Trunc}`, compacts via `xitdb.database_compact`, and atomically renames over `db_path`.
- All `@(test)` procedures in `tests/` must pass under `-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true` with zero memory leaks.

## Upstream `obench` Dependency

`deps/obench` currently pins `feat/rational-batch-and-femtoseconds` layered on top of `odin-bench` in `boxxxie/obench` (which integrates four focused feature/perf PR branches layered cleanly on top of upstream `main` `44000fb`). Never edit files inside `deps/*` directly from `hugi`; make upstream changes in `boxxxie/obench` on feature branches and update the submodule pointer deliberately.
