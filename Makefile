TOIT ?= toit
TESTS := $(wildcard tests/*-test.toit)

all: test

install-pkgs:
	$(TOIT) pkg install --project-root=tests
	$(TOIT) pkg install --project-root=examples

test: install-pkgs
	@for test in $(TESTS); do \
	  echo "--- $$test"; \
	  $(TOIT) $$test || exit 1; \
	done

# Each directory is its own package root, so they analyze separately.
analyze: install-pkgs
	$(TOIT) analyze src/*.toit
	$(TOIT) analyze examples/*.toit
	$(TOIT) analyze $(TESTS)

.PHONY: all install-pkgs test analyze
