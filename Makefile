# llmctl - top-level Makefile
# Targets: test, lint, validate, install, archive

SHELL := /bin/bash
ROOT  := $(abspath .)
SCRIPTS := bin/llmctl $(wildcard lib/*.sh) $(wildcard tests/*.sh)

.PHONY: test lint validate install archive json-check llmctld-build llmctld-test llmctld-lint bench-all

test:
	bash tests/run_tests.sh

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "shellcheck $$(shellcheck --version | awk '/^version/{print $$2}')"; \
		shellcheck -S warning $(SCRIPTS); \
	else \
		echo "shellcheck not installed - skipping lint (install it for stricter checks)"; \
	fi

json-check:
	python3 -c 'import json; d=json.load(open("models/catalog.json")); print("catalog OK:", len(d["profiles"]), "profiles")'

# llmctld: opt-in cluster daemon (Go). Single-host `make validate` stays
# bash-only and fast; these targets are invoked explicitly or via
# `make validate LLMCTL_CLUSTER_MODE=1`.
llmctld-build:
	@if command -v go >/dev/null 2>&1; then \
		cd llmctld && go build ./...; \
	else \
		echo "go not installed - skipping llmctld-build (install Go to build the cluster daemon)"; \
	fi

llmctld-test:
	@if command -v go >/dev/null 2>&1; then \
		cd llmctld && go test ./...; \
	else \
		echo "go not installed - skipping llmctld-test"; \
	fi

llmctld-lint:
	@if command -v golangci-lint >/dev/null 2>&1; then \
		echo "golangci-lint $$(golangci-lint --version)"; \
		cd llmctld && golangci-lint run ./...; \
	else \
		echo "golangci-lint not installed - skipping llmctld-lint (install it for stricter checks)"; \
	fi

# bench-all: 008-full-test-coverage T020 (User Story 3) - consolidates
# llmctld's three already-existing, already-passing benchmark files
# (internal/tenancy/quota_bench_test.go, internal/auth/jwt_bench_test.go,
# internal/auth/rbac_bench_test.go) into ONE report via a single
# `go test -bench=. -benchmem ./...` invocation from llmctld/ (Go's own
# tooling requires no per-file registration - `-bench=.` matches every
# BenchmarkXxx function in the module, confirmed research.md R3) -
# writes the combined, timestamped raw output to
# docs/testing/bench_runs/, never rewriting the three existing benchmark
# functions themselves. See docs/testing/BENCHMARK_BASELINE.md for the
# documented baseline + acceptable-variance this target's output is
# compared against.
bench-all:
	@if command -v go >/dev/null 2>&1; then \
		mkdir -p docs/testing/bench_runs; \
		ts=$$(date -u +%Y%m%dT%H%M%SZ); \
		out="docs/testing/bench_runs/bench_$${ts}.txt"; \
		echo "llmctld consolidated benchmark suite - captured $${ts}" > "$${out}"; \
		( cd llmctld && go test -bench=. -benchmem -run='^$$' ./... ) >> "$${out}" 2>&1; \
		echo "wrote $${out}"; \
	else \
		echo "go not installed - skipping bench-all"; \
	fi

ifeq ($(LLMCTL_CLUSTER_MODE),1)
validate: json-check lint test llmctld-build llmctld-lint llmctld-test
else
validate: json-check lint test
endif

# install: symlink the CLI into a directory on PATH (default ~/.local/bin).
PREFIX ?= $(HOME)/.local
install:
	mkdir -p "$(PREFIX)/bin"
	ln -sf "$(ROOT)/bin/llmctl" "$(PREFIX)/bin/llmctl"
	@echo "installed: $(PREFIX)/bin/llmctl -> $(ROOT)/bin/llmctl"

# `git archive` is fundamentally submodule-blind (it emits an EMPTY
# directory for every submodule, verified via `git archive HEAD | tar -tf -`
# - zero of any submodule's actual file content, at any nesting depth).
# scripts/release/build_archive.sh does a real filesystem-level tar/zip of
# the checked-out tree instead, which naturally includes every submodule's
# real content recursively (submodule/constitution nesting is a git-level
# concept with no special filesystem representation) plus the real `.git`
# directory itself, so extracting the archive anywhere produces a fully
# self-contained, buildable git repo (spec.md FR-014, Clarification 4;
# proven by tests/test_archive_completeness.sh).
archive:
	bash scripts/release/build_archive.sh "$(ROOT)" ../llmctl
	@echo "wrote ../llmctl.tar.gz and ../llmctl.zip"
