# Technology Stack

## Language & Build System
- **Language:** Odin (strict vetting, `-strict-style -vet-tabs -warnings-as-errors`, hard tabs throughout).
- **Formatter:** `odinfmt -config:odinfmt.json` via `make fmt` / `make fmt-check`.
- **Build & Task Runner:** [Makefile](../Makefile) producing `-o:speed` CLI executable `bin/hugi` (`make install` symlinks `~/.local/bin/hugi`).

## Internal Packages
- **`hugi/` (`package hugi`):** Core runner, pipeline DSL, `HPKT\x02` / `OBRC\x02` binary packet codec, `obench` JSON & JSONL importers.
- **`store/` (`package hugi_store`):** `xitdb`-backed `.hugidb` persistence, `U64_Codec` compression, statistical pooling/testing, Arrow IPC & Parquet exporters.
- **`cmd/hugi/` (`package hugi_cli`):** Standalone CLI entrypoint.
- **`examples/micro_and_phases/` & `tests/` (`package hugi_tests`):** Example suite and leak-checked unit/integration tests.

## Submodule Dependencies (`deps/*`)
- **`deps/obench`:** Tracks `/home/pauli/projects/odin/obench` (`odin-bench` / `feat/rational-batch-and-femtoseconds`) providing exact `overhead_fs`, raw `samples_batch_ns`, untimed zero-alloc validation, and Linux vDSO timing.
- **`deps/xitdb`:** Pure-Odin append-only Copy-on-Write MVCC database (`Array_List`, `Hash_Map`, `Core_Overlay`, `database_compact`).
- **`deps/skadi`:** Columnar table engine (`feat/ipc-lz4-body-compression`) providing Arrow IPC / Feather v2 serialization with `LZ4_FRAME` body compression and native `Decimal64_Type` / `Decimal128_Type`.

## Vendor / Core Libraries & Verification Tooling
- **Compression:** `vendor:zlib` (used for `HCAT\x01`, `CZPK\x04`, `CZCH\x02`, `BU` `U64_Codec` streams, and Parquet GZIP pages). `skadi` handles Arrow IPC `LZ4_FRAME` internally.
- **External Interop Verification:** DuckDB CLI (`duckdb`) for `.parquet` schema/query verification and Python `uv run --with pyarrow --with duckdb` for `.arrow` + `.parquet` `Decimal64(18, 6)` verification.
