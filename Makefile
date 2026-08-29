EMACS ?= emacs
BUILD_DIR ?= /tmp/ellm-dev

# This assumes you are using elpaca/straight etc. where other
# dependencies are available as sibling directories
LISP_DIRS := . ../emacs-async ../llm ../plz ../plz-media-type ../plz-event-source ../yaml ../s
LOAD_PATHS := $(foreach dir,$(LISP_DIRS),-L $(dir))
EMACS_BATCH := $(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' $(LOAD_PATHS)
SOURCES := ellm.el ellm-acp.el ellm-acp-extensions.el ellm-codex.el ellm-kagi.el ellm-llm.el ellm-mcp.el ellm-tools.el

.PHONY: help compile test load check

help:
	@printf '%s\n' \
	  'make compile  Byte-compile without writing .elc files to the repository.' \
	  'make test     Run the ERT test suite.' \
	  'make load     Load ellm.el in a clean batch Emacs.' \
	  'make check    Run compile, test, and load checks.'

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
