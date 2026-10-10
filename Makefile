SHELL_FILES := bin/agbox install.sh lib/*.sh modules/*.sh scripts/*.sh tests/*.bash

.PHONY: check lint test docs docs-check dry-run

check: lint docs-check test ## Everything CI runs (except the VM end-to-end job)

lint: ## Static analysis
	shellcheck $(SHELL_FILES)

test: ## Unit + CLI tests (dry-runs only, safe on any machine)
	bats tests/

docs: ## Regenerate the settings table in docs/configuration.md
	scripts/gen-config-docs.sh

docs-check:
	scripts/gen-config-docs.sh --check

dry-run: ## Show what `agbox setup` would do on this machine
	bin/agbox setup --dry-run --yes
