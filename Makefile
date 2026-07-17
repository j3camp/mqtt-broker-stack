SHELL := /bin/bash
.DEFAULT_GOAL := help

REPO_ROOT := $(shell pwd)
COMPOSE := docker compose

# Detect whether FORCE is set for destructive operations
FORCE ?= 0

.PHONY: help init up down restart status logs validate test test-architecture \
        create-user change-password delete-user \
        enable-acl disable-acl \
        backup restore clean

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

init: ## Initialise the stack (certificates, password file, .env)
	@./scripts/init.sh

up: ## Start the broker
	@$(COMPOSE) up -d

down: ## Stop and remove containers
	@$(COMPOSE) down

restart: ## Restart the broker
	@$(COMPOSE) restart

status: ## Show service status
	@$(COMPOSE) ps

logs: ## Follow broker logs (Ctrl-C to exit)
	@$(COMPOSE) logs -f

validate: ## Validate configuration and certificates
	@./scripts/validate.sh

test: ## Run integration tests
	@for t in tests/test-*.sh; do \
		echo ""; \
		echo "--- Running $$t ---"; \
		bash "$$t"; \
	done
	@echo ""
	@echo "All tests passed."

test-architecture: ## Validate the MQTT administration architecture decision
	@bash tests/test-admin-console-architecture.sh

create-user: ## Create a new MQTT user (set USERNAME=<name>)
	@./scripts/create-user.sh $(USERNAME)

change-password: ## Change password for a user (set USERNAME=<name>)
	@./scripts/change-password.sh $(USERNAME)

delete-user: ## Delete an MQTT user (set USERNAME=<name>)
	@./scripts/delete-user.sh $(USERNAME)

enable-acl: ## Enable ACL enforcement on the external listener
	@./scripts/enable-acl.sh

disable-acl: ## Disable ACL enforcement on the external listener
	@./scripts/disable-acl.sh

backup: ## Create a timestamped backup of broker state
	@./scripts/backup.sh

restore: ## Restore from a backup archive (set ARCHIVE=<path>)
	@./scripts/restore.sh $(ARCHIVE)

clean: ## Remove all runtime data and containers (FORCE=1 required)
	@if [ "$(FORCE)" != "1" ]; then \
		echo "ERROR: Destructive action. Run: make clean FORCE=1" >&2; \
		exit 1; \
	fi
	@$(COMPOSE) down -v --remove-orphans
	@rm -f mosquitto/config/security/passwords
	@rm -f mosquitto/config/security/acl
	@rm -f mosquitto/config/certs/server.crt
	@rm -f mosquitto/config/certs/server.key
	@rm -f mosquitto/config/certs/ca.crt
	@rm -rf certs/
	@echo "Runtime data removed."
