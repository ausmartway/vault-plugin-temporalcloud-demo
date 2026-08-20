# Vault + Temporal Cloud dynamic secrets demo.
# `make demo` from a clean checkout is the whole thing.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# Read VAULT_PORT out of .env for the port check without sourcing the whole file.
VAULT_PORT := $(shell [ -f .env ] && grep -E '^VAULT_PORT=' .env | cut -d= -f2 || echo 8200)

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: check-env
check-env: ## Fail early if .env is missing
	@[ -f .env ] || { echo "ERROR: no .env — copy .env.example to .env and fill it in."; exit 1; }

.PHONY: check-ports
check-ports: check-env ## Verify VAULT_PORT is free before starting anything
# The demo's own container holds the port once it is up, so a plain "is anything
# listening?" check turns `make demo` into a one-shot command: after a Ctrl-C the
# obvious recovery (run it again) is refused, and so is `make up`. Recognise our
# own container and reuse it; only a foreign listener is a real conflict.
	@if [ -n "$$(docker compose ps --status running --quiet vault 2>/dev/null)" ]; then \
		echo "port $(VAULT_PORT) is held by this demo's own Vault — reusing it"; \
	elif lsof -nP -iTCP:$(VAULT_PORT) -sTCP:LISTEN >/dev/null 2>&1; then \
		echo "ERROR: port $(VAULT_PORT) is already in use:"; \
		lsof -nP -iTCP:$(VAULT_PORT) -sTCP:LISTEN; \
		echo "Change VAULT_PORT in .env, or stop the process above."; \
		exit 1; \
	else \
		echo "port $(VAULT_PORT) is free"; \
	fi

.PHONY: plugin
plugin: check-env ## Download + checksum-verify the plugin binary into ./plugins
	@./scripts/fetch-plugin.sh

.PHONY: up
up: check-ports plugin ## Start Vault dev server with the plugin available
	@docker compose up -d --wait
	@echo "Vault is up at http://127.0.0.1:$(VAULT_PORT) (token: root)"

.PHONY: demo
demo: up ## Run the interactive demo (type-along, advances on ENTER)
	@./demo.sh

.PHONY: auto
auto: up ## Run the demo unattended, no keypresses (AUTO_PLAY_MODE)
	@AUTO_PLAY_MODE=1 ./demo.sh

.PHONY: reset
reset: ## Revoke leases, delete Temporal Cloud service accounts, tear Vault down
	@./reset.sh

.PHONY: status
status: ## Show what currently exists in Vault and in Temporal Cloud
	@./scripts/status.sh

.PHONY: down
down: ## Stop Vault without touching Temporal Cloud (prefer `make reset`)
	@docker compose down -v
