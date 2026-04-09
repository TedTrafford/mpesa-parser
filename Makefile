# Makefile — local development helpers for the M-PESA statement parser
# Usage: make <target>

.PHONY: help install install-dev test test-cov lint check clean hooks

PYTHON   ?= $(shell which python3)
PIP      ?= $(PYTHON) -m pip
PYTEST   ?= $(PYTHON) -m pytest
FLAKE8   ?= $(PYTHON) -m flake8
SRC      := config.py parser/ db/ parse_single.py process_all_pdfs.py

# ── default ───────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "  M-PESA Statement Parser — local dev commands"
	@echo ""
	@echo "  make install        Install runtime dependencies"
	@echo "  make install-dev    Install runtime + dev/test dependencies"
	@echo "  make test           Run the test suite"
	@echo "  make test-cov       Run tests with coverage report"
	@echo "  make lint           Run flake8 linter"
	@echo "  make check          lint + test  (mirrors CI)"
	@echo "  make hooks          Install the pre-push git hook"
	@echo "  make clean          Remove .pyc files and __pycache__ dirs"
	@echo ""

# ── dependencies ──────────────────────────────────────────────────────────────
install:
	$(PIP) install -r requirements.txt

install-dev:
	$(PIP) install -r requirements-dev.txt

# ── testing ───────────────────────────────────────────────────────────────────
test:
	$(PYTEST) tests/ -v

test-cov:
	$(PYTEST) tests/ \
		--cov=config \
		--cov=parser \
		--cov=parse_single \
		--cov-report=term-missing \
		--cov-report=html:htmlcov \
		-v
	@echo ""
	@echo "  Coverage HTML report: htmlcov/index.html"

# ── linting ───────────────────────────────────────────────────────────────────
lint:
	$(FLAKE8) $(SRC) \
		--count \
		--select=E9,F63,F7,F82,F4 \
		--show-source \
		--statistics
	$(FLAKE8) $(SRC) \
		--count \
		--max-line-length=120 \
		--extend-ignore=E203,E221,E272,E302,E303,E305,E402,E501,W291,W292,W293,W503 \
		--statistics

# ── combined check (mirrors CI) ───────────────────────────────────────────────
check: lint test
	@echo ""
	@echo "  All checks passed — safe to push."

# ── git hooks ─────────────────────────────────────────────────────────────────
hooks:
	@cp scripts/pre-push .git/hooks/pre-push
	@chmod +x .git/hooks/pre-push
	@echo "  pre-push hook installed at .git/hooks/pre-push"

# ── housekeeping ──────────────────────────────────────────────────────────────
clean:
	find . -type f -name "*.pyc" -delete
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	rm -rf .pytest_cache htmlcov coverage.xml .coverage
