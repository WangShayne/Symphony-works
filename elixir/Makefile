.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e runner-deps runner-fmt-check runner-test runner-dialyzer runner-ci

MIX ?= mix

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

runner-deps:
	cd ../runner && $(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

runner-fmt-check: runner-deps
	cd ../runner && $(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

runner-test: runner-deps
	cd ../runner && $(MIX) test --cover

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

runner-dialyzer: runner-deps
	cd ../runner && $(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

runner-ci: runner-fmt-check runner-test runner-dialyzer

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) runner-ci
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
