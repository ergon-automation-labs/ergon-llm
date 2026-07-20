SCRIPTS_DIRECTORY ?= $(abspath $(CURDIR)/../scripts)
MIX ?= /Users/abby/.local/share/mise/shims/mix

.PHONY: test-handlers test-stores test-nats test-integration test-full setup help deps run test credo dialyzer coverage check format clean release publish-release setup-hooks setup-db reset-db logs logs-tail logs-errors git-push push-and-publish sync-release-version pre-push-cleanup

help:
	@echo "BotArmyLlm - LLM Bot"
	@echo ""
	@echo "Setup commands:"
	@echo "  make setup           - Set up project (deps.get + install git hooks + setup database)"
	@echo "  make setup-hooks     - Install git hooks for pre-push validation"
	@echo "  make setup-db        - Create and migrate test database (required for testing)"
	@echo "  make reset-db        - Drop and recreate test database (useful for troubleshooting)"
	@echo ""
	@echo "Development commands:"
	@echo "  make run             - Start LLM service (NATS consumer)"
	@echo "  make test            - Run all tests"
	@echo "  make credo           - Run linter"
	@echo "  make dialyzer        - Run static analysis"
	@echo "  make coverage        - Run tests with coverage"
	@echo "  make check           - Run all checks (test, credo, dialyzer)"
	@echo "  make format          - Format Elixir code"
	@echo "  make clean           - Clean build artifacts"
	@echo ""
	@echo "Logging commands (server /var/log/bot_army/llm_proxy.log):"
	@echo "  make logs            - Last 100 lines with grc colors"
	@echo "  make logs-tail       - Tail with grc (brew install grc; make -C .. install-grc)"
	@echo "  make logs-errors     - Recent errors/warnings with grc"
	@echo ""
	@echo "Release commands:"
	@echo "  make release         - Build OTP release (runs test first; same gate as pre-push)"
	@echo "  make publish-release - Build, package, and publish to GitHub"
	@echo ""
	@echo "Normal workflow:"
	@echo "  git push             - Fast compile+test validation"
	@echo "  make push-and-publish - Push then publish release asset"
	@echo ""

setup: init deps setup-hooks setup-db
	@echo "✓ Setup complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Configure .env with your database settings (if needed)"
	@echo "  2. Run: make test"
	@echo "  3. Start developing!"
	@echo ""

setup-hooks:
	@git config core.hooksPath git-hooks
	@echo "✓ Git hooks installed (core.hooksPath = git-hooks)"

setup-db:
	@echo "Setting up test database..."
	@MIX_ENV=test $(MIX) ecto.create || true
	@MIX_ENV=test $(MIX) ecto.migrate
	@echo "✓ Test database created and migrations applied"

reset-db:
	@echo "⚠️  Resetting test database (dropping and recreating)..."
	@MIX_ENV=test $(MIX) ecto.drop || true
	@MIX_ENV=test $(MIX) ecto.create
	@MIX_ENV=test $(MIX) ecto.migrate
	@echo "✓ Test database reset complete"

init:
	@if [ ! -d .git ]; then git init; echo "Git initialized."; else echo "Git already initialized."; fi

compile:
	@LOG_FILE="/tmp/compile-llm-$$(date +%s).log"; \
	echo "Compiling llm and logging to $$LOG_FILE..."; \
	$(MIX) compile 2>&1 | tee "$$LOG_FILE"; \
	echo "✓ Compilation log: $$LOG_FILE"

deps:
	$(MIX) deps.get

compile:
	@LOG_FILE="/tmp/compile-llm-$$(date +%s).log"; \
	echo "Compiling llm and logging to $$LOG_FILE..."; \
	$(MIX) compile 2>&1 | tee "$$LOG_FILE"; \
	echo "✓ Compilation log: $$LOG_FILE"

run:
	$(MIX) run --no-halt

test:
	@BOT_NAME=llm; \
	LOG_FILE="/tmp/test-$${BOT_NAME}-$$(date +%s).log"; \
	echo "Running tests and logging to $$LOG_FILE..."; \
	$(MIX) test 2>&1 | tee "$$LOG_FILE"; \
	echo "✓ Test log: $$LOG_FILE"

test-handlers:
	MIX_ENV=test $(MIX) test --only handlers --trace

test-stores:
	MIX_ENV=test $(MIX) test --only stores --trace

test-nats:
	MIX_ENV=test $(MIX) test --only nats --trace

test-integration:
	$(MIX) test --include integration --trace

test-full:
	$(MIX) test --include integration --include nats_live --trace

credo:
	@BOT_NAME=llm; \
	LOG_FILE="/tmp/credo-$${BOT_NAME}-$$(date +%s).log"; \
	echo "Running credo and logging to $$LOG_FILE..."; \
	$(MIX) credo --only warning 2>&1 | tee "$$LOG_FILE"; \
	echo "✓ Credo log: $$LOG_FILE"

dialyzer: deps
	$(MIX) dialyzer

coverage:
	$(MIX) coveralls

check: test credo
	@echo "All checks passed!"

format:
	$(MIX) format

clean:
	$(MIX) clean
	rm -rf _build cover
	rm -rf llm_proxy-*.tar.gz

release: check
	@echo "==============================================="
	@echo "Building OTP release"
	@echo "==============================================="
	rm -rf _build/prod/rel/llm_proxy
	MIX_ENV=prod $(MIX) release
	@echo ""
	@echo "✓ Release built successfully"
	@echo "Location: _build/prod/rel/llm_proxy/"
	@echo ""

test-release-smoke:
	@echo "==============================================="
	@echo "Running release smoke test"
	@echo "==============================================="
	@RELEASE_NAME=llm_proxy NATS_SERVERS=nats://localhost:4224 \
		bash $(SCRIPTS_DIRECTORY)/test_release_smoke.sh

# Detect if branch touches responder, NATS consumer, or bridge envelope code.
# Used as a gate in publish-release to require integration tests.
HAS_RESPONDER_CHANGES := $(shell git diff --name-only origin/main 2>/dev/null | grep -qE 'lib/.*/(responders|nats|consumers)/|lib/.*/bridge.*\.ex|lib/.*/event.*\.ex' && echo 1 || echo 0)

sync-release-version:
	@VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then \
		echo "❌ Failed to resolve version from mix.exs"; exit 1; \
	fi; \
	TIMESTAMP=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); \
	echo "$$VERSION" > .release-published; \
	echo "✅ Synced release version: v$$VERSION ($$TIMESTAMP)"

publish-release:
	@BOT_NAME=llm; \
	LOG_FILE="/tmp/publish-release-$${BOT_NAME}-$$(date +%s).log"; \
	echo "Publishing release and logging to $$LOG_FILE..."; \
	{ \
	set -e; \
	VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then \
		echo "Failed to resolve version from mix.exs"; \
		exit 1; \
	fi; \
	TARBALL=llm_proxy-$$VERSION.tar.gz; \
	echo "Version: $$VERSION"; \
	echo ""; \
	if [ -f "$$TARBALL" ]; then \
		echo "✓ Tarball already exists locally: $$TARBALL (skipping rebuild)"; \
	else \
		echo "📦 Building release (tarball not found locally)..."; \
		if [ "$(HAS_RESPONDER_CHANGES)" = "1" ] && [ "$(SKIP_INTEGRATION_GATE)" != "1" ]; then \
			echo "🔒 Responder/NATS/bridge changes detected. Integration tests required before publish."; \
			$(MAKE) test-integration || { echo "❌ Integration tests failed. Publish blocked."; exit 1; }; \
			echo "✅ Integration tests passed."; \
		else \
			[ "$(HAS_RESPONDER_CHANGES)" = "1" ] && echo "⚠️  Skipping integration gate (SKIP_INTEGRATION_GATE=1)" || true; \
		fi; \
		$(MAKE) release; \
		$(MAKE) test-release-smoke || echo "⚠️  Smoke test warnings (non-blocking) - continuing"; \
		echo "Creating release tarball..."; \
		tar -czf "$$TARBALL" -C _build/prod/rel llm_proxy/; \
		echo "✓ Tarball created: $$TARBALL"; \
	fi; \
	echo ""; \
	echo "Creating GitHub release v$$VERSION..."; \
	if gh release view "v$$VERSION" >/dev/null 2>&1; then \
		gh release upload "v$$VERSION" "$$TARBALL" --clobber; \
	else \
		gh release create "v$$VERSION" "$$TARBALL" \
			--title "Release v$$VERSION" \
			--notes "LLM Bot Elixir release v$$VERSION" \
			--draft=false; \
	fi; \
	echo "✓ Release published to GitHub"; \
	$(MAKE) sync-release-version; \
	echo ""; \
	echo "Publishing deploy.release.requested to NATS..."; \
	BOT_NAME=$$(basename $$(pwd) | sed 's/bot_army_//'); \
	REPO_SLUG=$$(git config --get remote.origin.url | sed 's/.*\///; s/\.git$$//'); \
	NATS_SERVERS=$${NATS_SERVERS:-nats://localhost:4222}; \
	nats --server "$$NATS_SERVERS" pub deploy.release.requested "$$(jq -n --arg bot "$${BOT_NAME}" --arg repo "$$REPO_SLUG" --arg version "$$VERSION" --arg tag "v$$VERSION" '{bot: $$bot, repo: $$repo, version: $$version, release_tag: $$tag}')" || { echo "⚠️  NATS publish failed (is NATS running?)"; }; \
	echo "✓ Deploy event published (deploy_pipeline_bot will pick it up)"; \
	echo ""; \
	} 2>&1 | tee "$$LOG_FILE"; \
	echo "✓ Publish-release log: $$LOG_FILE"

pre-push-cleanup:
	@echo "🧹 Cleaning up pre-push artifacts..."
	@if git diff --quiet git-hooks/pre-push; then \
		echo "✓ No hook changes"; \
	else \
		echo "📋 Staging hook changes..."; \
		git add git-hooks/pre-push git-hooks/post-push; \
		git commit -m "chore: sync hooks" || true; \
	fi
	@if git diff --quiet mix.lock; then \
		echo "✓ No lock file changes"; \
	else \
		echo "📋 Staging lock file changes..."; \
		git add mix.lock; \
		git commit -m "chore: lock file updates from pre-push validation" || true; \
	fi
	@echo "✓ Ready to push"
push: test compile credo pre-push-cleanup
	@echo "✅ All validations passed"
	@echo "$$(date +%s)" > .push-validated
	@echo "✓ Proof-of-validation created"
	@$(MAKE) git-push


git-push: pre-push-cleanup
	@BOT_NAME=llm; \
	LOG_FILE="/tmp/git-push-$${BOT_NAME}-$$(date +%s).log"; \
	echo "Pushing to origin/main and logging to $$LOG_FILE..."; \
	git push 2>&1 | tee "$$LOG_FILE"; \
	echo "✓ Log saved: $$LOG_FILE"

push-and-publish: git-push publish-release
logs:
	@echo "Last 100 lines of llm_proxy logs:"
	@echo "=================================="
	@tail -100 /var/log/bot_army/llm_proxy.log 2>/dev/null | grc --config=conf.bot_army_elixir cat || echo "Log file not found at /var/log/bot_army/llm_proxy.log (brew install grc; make -C .. install-grc)"

logs-tail:
	@$(SCRIPTS_DIRECTORY)/tail_bot_log.sh

logs-errors:
	@echo "Error and warning lines from llm_proxy logs:"
	@echo "============================================="
	@grep -E '\[error\]|\[warning\]' /var/log/bot_army/llm_proxy.log 2>/dev/null | tail -50 | grc --config=conf.bot_army_elixir cat || echo "No errors found or log file not accessible"

# Test pre-push hook workflow - v0.5.6








.PHONY: bump-version

bump-version:
	@if [ -z "$(BUMP)" ]; then echo "Usage: make bump-version BUMP=major|minor|patch"; exit 1; fi
	@OLD=$$(grep 'version:' mix.exs | head -1 | sed -E 's/.*version: "([^"]+)".*/\1/'); \
	bash $(SCRIPTS_DIRECTORY)/bump_version.sh mix.exs $(BUMP) > /dev/null; \
	NEW=$$(grep 'version:' mix.exs | head -1 | sed -E 's/.*version: "([^"]+)".*/\1/'); \
	echo "✓ Bumped: $$OLD → $$NEW"
