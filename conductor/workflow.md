# Development Workflow

## Coding & Package Rules
1. **Dependency Boundary Check:**
   - `hugi/` (`package hugi`) MUST only import `base:*`, `core:*`, and `../deps/obench/obench` — never `deps/xitdb` or `deps/skadi`.
   - Use relative imports (`../hugi`, `../store`, `../deps/*`) rather than mixing collection imports and relative imports inside the project build graph.
2. **Compiler Flag Split:**
   - Check `hugi/` with `-vet -vet-tabs -vet-style -vet-cast -strict-style -warnings-as-errors -disallow-do`.
   - Check `store/`, `cmd/hugi/`, `examples/micro_and_phases/`, and `tests/` with `-vet -strict-style -vet-tabs -warnings-as-errors -vet-packages:hugi,hugi_store,hugi_cli,hugi_tests` (because `deps/xitdb/xitdb/lua.odin` uses `do`). Never use `do` statements in repo source files.
3. **Git Discipline:**
   - Work and commit strictly on feature branches (e.g., `feat/initial-hugi`). Never commit or push directly to `master` or push remotes unless explicitly instructed.
   - Clean temporary test artifacts (`rm -rf .tmp build`) after verification runs; never commit compiled binaries.

## Mandatory Verification Commands
Run from the repository root:
- `make fmt` / `make fmt-check`
- `make check`
- `make test` (`-define:ODIN_TEST_FANCY=false -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`)
- `make example && make build && rm -rf .tmp build` (when modifying CLI, store formats, or closing a phase/track)

## Phase Completion Verification and Checkpointing Protocol
At the end of each phase in a track's `plan.md`:
1. Run `make fmt && make fmt-check && make check && make test`, confirming `0` failures and `0` leaked/bad-freed bytes (`ODIN_TEST_FAIL_ON_BAD_MEMORY=true`), plus `make example && make build` when CLI or store formats changed, and remove `.tmp` / `build`.
2. Verify any format/interop compatibility invariants required by the track `spec.md` (e.g., `hugi history` / `hugi inspect` on compacted reference `.hugidb` files).
3. Update `plan.md` task checkboxes (`[x]`) and review diffs before advancing to the next phase.
