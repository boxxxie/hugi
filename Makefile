.PHONY: all build check test example fmt fmt-check clean

ODIN ?= odin
ODINFMT ?= odinfmt

COLS := -collection:bench=./bench -collection:bench_store=./store -collection:obench=./deps/obench/obench -collection:xitdb=./deps/xitdb/xitdb -collection:skadi=./deps/skadi/skadi
BENCH_ONLY_COL := -collection:obench=./deps/obench/obench
BENCH_FLAGS := -vet -vet-tabs -vet-style -vet-cast -strict-style -warnings-as-errors -disallow-do
FULL_FLAGS := -vet -strict-style -vet-tabs -warnings-as-errors -vet-packages:bench,bench_store,bench_cli,bench_tests
TEST_FLAGS ?= -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

SOURCES := bench/*.odin store/*.odin cmd/bench/*.odin examples/micro_and_phases/*.odin tests/*.odin

BIN_DIR := bin
BENCH_BIN := $(BIN_DIR)/bench

all: check test build

build: $(BENCH_BIN)

$(BENCH_BIN): bench/*.odin store/*.odin cmd/bench/*.odin
	@mkdir -p $(BIN_DIR)
	$(ODIN) build cmd/bench -out:$(BENCH_BIN) -o:speed $(COLS) $(FULL_FLAGS)

check:
	$(ODIN) check bench -no-entry-point $(BENCH_ONLY_COL) $(BENCH_FLAGS)
	$(ODIN) check store -no-entry-point $(COLS) $(FULL_FLAGS)
	$(ODIN) check cmd/bench $(COLS) $(FULL_FLAGS)
	$(ODIN) check examples/micro_and_phases $(COLS) $(FULL_FLAGS)
	$(ODIN) check tests -no-entry-point $(COLS) $(FULL_FLAGS)

test:
	@mkdir -p .tmp
	$(ODIN) test tests -out:.tmp/bench_tests $(COLS) $(FULL_FLAGS) $(TEST_FLAGS)

example: build
	@mkdir -p .tmp
	./$(BENCH_BIN) run examples/micro_and_phases --db .tmp/example.benchdb --runs 5

fmt:
	@for f in $(SOURCES); do $(ODINFMT) -config:odinfmt.json -w "$$f" || exit 1; done

fmt-check:
	@status=0; for f in $(SOURCES); do \
		$(ODINFMT) -config:odinfmt.json "$$f" | diff -q "$$f" - >/dev/null || { echo "needs formatting: $$f"; status=1; }; \
	done; exit $$status

clean:
	rm -rf $(BIN_DIR) build .tmp
