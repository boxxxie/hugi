.PHONY: all build check test specs example fmt fmt-check clean install

ODIN ?= odin
ODINFMT ?= odinfmt

COLS := -collection:hugi=./hugi -collection:hugi_store=./store -collection:obench=./deps/obench/obench -collection:xitdb=./deps/xitdb/xitdb -collection:skadi=./deps/skadi/skadi
HUGI_ONLY_COL := -collection:obench=./deps/obench/obench
HUGI_FLAGS := -vet -vet-tabs -vet-style -vet-cast -strict-style -warnings-as-errors -disallow-do
FULL_FLAGS := -vet -strict-style -vet-tabs -warnings-as-errors -vet-packages:hugi,hugi_store,hugi_cli,hugi_tests,hugi_specs
TEST_FLAGS ?= -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

SOURCES = $(shell find hugi store cmd examples tests specs -name '*.odin' | sort)

BIN_DIR := bin
HUGI_BIN := $(BIN_DIR)/hugi

all: check test build

build: $(HUGI_BIN)

$(HUGI_BIN): hugi/*.odin store/*.odin cmd/hugi/*.odin
	@mkdir -p $(BIN_DIR)
	$(ODIN) build cmd/hugi -out:$(HUGI_BIN) -o:speed $(COLS) $(FULL_FLAGS)

check:
	$(ODIN) check hugi -no-entry-point $(HUGI_ONLY_COL) $(HUGI_FLAGS)
	$(ODIN) check store -no-entry-point $(COLS) $(FULL_FLAGS)
	$(ODIN) check cmd/hugi $(COLS) $(FULL_FLAGS)
	$(ODIN) check examples/micro_and_phases $(COLS) $(FULL_FLAGS)
	$(ODIN) check examples/custom_markdown_odin $(COLS) $(FULL_FLAGS)
	$(ODIN) check tests -no-entry-point $(COLS) $(FULL_FLAGS)
	$(ODIN) check specs -no-entry-point $(COLS) $(FULL_FLAGS)

specs: $(HUGI_BIN)
	@mkdir -p .tmp
	$(ODIN) test specs -out:.tmp/hugi_specs $(COLS) $(FULL_FLAGS) $(TEST_FLAGS)

test: $(HUGI_BIN)
	@mkdir -p .tmp
	$(ODIN) test tests -out:.tmp/hugi_tests $(COLS) $(FULL_FLAGS) $(TEST_FLAGS)
	$(ODIN) test cmd/hugi -out:.tmp/hugi_cli_tests $(COLS) $(FULL_FLAGS) $(TEST_FLAGS)
	$(ODIN) test specs -out:.tmp/hugi_specs $(COLS) $(FULL_FLAGS) $(TEST_FLAGS)

example: build
	@mkdir -p .tmp
	./$(HUGI_BIN) run examples/micro_and_phases --db .tmp/example.hugidb --runs 5

fmt:
	@for f in $(SOURCES); do $(ODINFMT) -config:odinfmt.json -w "$$f" || exit 1; done

fmt-check:
	@status=0; for f in $(SOURCES); do \
		$(ODINFMT) -config:odinfmt.json "$$f" | diff -q "$$f" - >/dev/null || { echo "needs formatting: $$f"; status=1; }; \
	done; exit $$status

install: build
	@mkdir -p $(HOME)/.local/bin
	ln -sf $(CURDIR)/$(HUGI_BIN) $(HOME)/.local/bin/hugi

clean:
	rm -rf $(BIN_DIR) build .tmp
