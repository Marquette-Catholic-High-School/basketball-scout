# Basketball Scout - shortcuts for development. `make help` lists them.
# Servers use scripts/install.sh, scripts/update.sh and scripts/uninstall.sh instead.

PYTHON ?= python3
VENV := .venv
PY := $(VENV)/bin/python
HOST ?= 127.0.0.1
PORT ?= 8000
# Run a command with .env loaded the way the app reads it (python-dotenv), so the
# Modal CLI sees MODAL_TOKEN_ID / MODAL_TOKEN_SECRET and SCOUT_MODAL_GPU from .env.
WITH_ENV := $(if $(wildcard .env),$(PY) -m dotenv -f .env run --,)
RUFF := $(firstword $(wildcard $(VENV)/bin/ruff) $(shell command -v ruff 2>/dev/null))

.DEFAULT_GOAL := help
.PHONY: help install dev test run-web run-worker deploy-modal warmup-modal lint clean

help: ## Show the available commands
	@awk 'BEGIN { FS = ":.*## " } /^[a-z-]+:.*## / { printf "  make %-13s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

install: $(PY) ## Create .venv and install the app and test requirements
	$(PY) -m pip install --disable-pip-version-check -r requirements-dev.txt

$(PY):
	@$(PYTHON) -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else "Python 3.11 or newer is needed, e.g.: make install PYTHON=python3.12")'
	$(PYTHON) -m venv $(VENV)
	$(PY) -m pip install --quiet --disable-pip-version-check --upgrade pip

dev: ## Run the web app (auto-reload) and the worker together; Ctrl-C stops both
	PORT=$(PORT) HOST=$(HOST) scripts/dev.sh

# pyproject.toml's addopts already pass -q: a second -q would hide the pass/fail count.
test: ## Run the test suite (no GPU, network or API keys needed)
	$(PY) -m pytest

run-web: ## Run only the web app on http://127.0.0.1:8000 (auto-reload; PORT=... to change)
	$(PY) -m uvicorn scout.main:app --reload --reload-dir scout --host $(HOST) --port $(PORT)

run-worker: ## Run only the background worker
	$(PY) -m scout.worker

deploy-modal: ## Deploy the GPU app to Modal (first time: 10-20 minutes)
	$(WITH_ENV) $(VENV)/bin/modal deploy modal_app/app.py

warmup-modal: ## Start one GPU container and load the models (checks the deployment)
	$(WITH_ENV) $(VENV)/bin/modal run modal_app/app.py::warmup

lint: ## ruff (when installed) and a bash syntax check of scripts/*.sh
	@if [ -n "$(RUFF)" ]; then $(RUFF) check scout modal_app tests; \
	else echo "ruff is not installed (pip install ruff); skipping the Python lint"; fi
	@for script in scripts/*.sh; do bash -n "$$script" || exit 1; done; echo "scripts/*.sh: syntax OK"

clean: ## Delete caches and build files (never touches .env, data/ or .venv)
	find . -path ./.venv -prune -o -type d -name __pycache__ -exec rm -rf {} +
	rm -rf .pytest_cache .ruff_cache build dist *.egg-info
