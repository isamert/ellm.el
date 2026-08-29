SHELL := /bin/bash

EMACS ?= emacs
BUILD_DIR ?= /tmp/ellm-dev
VERSION ?=
CHANGELOG := CHANGELOG.md

# This assumes you are using elpaca/straight etc. where other
# dependencies are available as sibling directories
LISP_DIRS := . ../emacs-async ../llm ../plz ../plz-media-type ../plz-event-source ../yaml ../s
LOAD_PATHS := $(foreach dir,$(LISP_DIRS),-L $(dir))
EMACS_BATCH := $(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' $(LOAD_PATHS)
SOURCES := ellm.el ellm-acp.el ellm-acp-extensions.el ellm-codex.el ellm-kagi.el ellm-llm.el ellm-mcp.el ellm-tools.el

.PHONY: help compile test load check release

help:
	@printf '%s\n' \
	  'make compile                Byte-compile without writing .elc files to the repository.' \
	  'make test                   Run the ERT test suite.' \
	  'make load                   Load ellm.el in a clean batch Emacs.' \
	  'make check                  Run compile, test, and load checks.' \
	  'make release VERSION=X.Y.Z  Validate, update versions, request release notes, commit, and tag.'

compile:
	mkdir -p $(BUILD_DIR)
	$(EMACS_BATCH) \
	  --eval '(setq byte-compile-dest-file-function (lambda (file) (expand-file-name (concat (file-name-base file) ".elc") "$(BUILD_DIR)")))' \
	  -f batch-byte-compile $(SOURCES)

test:
	$(EMACS_BATCH) -l ellm-test.el -f ert-run-tests-batch-and-exit

load:
	$(EMACS_BATCH) -l ellm.el

check: compile test load

release:
	@set -eu; \
	case "$(VERSION)" in \
	  ''|*[!0-9A-Za-z.-]*) echo 'VERSION must contain only letters, digits, dots, and hyphens.' >&2; exit 2 ;; \
	esac; \
	if test -n "$$(git status --porcelain --untracked-files=all)"; then \
	  echo 'Release requires a clean working tree.' >&2; exit 2; \
	fi; \
	if git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null; then \
	  echo "Tag v$(VERSION) already exists." >&2; exit 2; \
	fi; \
	command -v emacsclient >/dev/null || { echo 'emacsclient is required for release notes.' >&2; exit 2; }; \
	$(MAKE) check; \
	notes_file=$$(mktemp); \
	tag_message=$$(mktemp); \
	rm -f "$$notes_file"; \
	changelog_file="$(CURDIR)/$(CHANGELOG)"; \
	changelog_tmp=$$(mktemp "$${changelog_file}.XXXXXX"); \
	trap 'rm -f "$$notes_file" "$$tag_message" "$$changelog_tmp"' EXIT HUP INT TERM; \
	echo 'Write the release notes, save the file, then type C-x # to finish.'; \
	emacsclient "$$notes_file"; \
	test -s "$$notes_file" || { echo 'Changelog text cannot be empty.' >&2; exit 2; }; \
	{ printf '# v%s\n\n' "$(VERSION)"; cat "$$notes_file"; printf '\n\n'; } >"$$tag_message"; \
	{ cat "$$tag_message"; test ! -f "$$changelog_file" || cat "$$changelog_file"; } >"$$changelog_tmp"; \
	mv "$$changelog_tmp" "$$changelog_file"; \
	for file in $(SOURCES); do \
	  grep -q '^;; Version: ' "$$file" || { echo "No Version header in $$file" >&2; exit 2; }; \
	  version_tmp=$$(mktemp "$$file.XXXXXX"); \
	  sed 's/^;; Version: .*/;; Version: $(VERSION)/' "$$file" >"$$version_tmp"; \
	  mv "$$version_tmp" "$$file"; \
	done; \
	git add -- $(SOURCES) $(CHANGELOG); \
	git commit -m "Release v$(VERSION)"; \
	git tag -a --cleanup=verbatim "v$(VERSION)" -F "$$tag_message"
