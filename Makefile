# llmctl - top-level Makefile
# Targets: test, lint, validate, install, archive

SHELL := /bin/bash
ROOT  := $(abspath .)
SCRIPTS := bin/llmctl $(wildcard lib/*.sh) $(wildcard tests/*.sh)

.PHONY: test lint validate install archive json-check

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

validate: json-check lint test

# install: symlink the CLI into a directory on PATH (default ~/.local/bin).
PREFIX ?= $(HOME)/.local
install:
	mkdir -p "$(PREFIX)/bin"
	ln -sf "$(ROOT)/bin/llmctl" "$(PREFIX)/bin/llmctl"
	@echo "installed: $(PREFIX)/bin/llmctl -> $(ROOT)/bin/llmctl"

archive:
	git archive --format=tar.gz -o ../llmctl.tar.gz HEAD
	cd .. && zip -qr llmctl.zip llmctl -x 'llmctl/.git/*' 'llmctl/vendor/*/build/*'
	@echo "wrote ../llmctl.tar.gz and ../llmctl.zip"
