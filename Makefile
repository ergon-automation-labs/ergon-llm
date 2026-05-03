SCRIPTS_DIRECTORY ?= $(abspath $(CURDIR)/../scripts)

.PHONY: test-handlers test-stores test-nats test-integration test-full setup help deps run test credo dialyzer coverage check format clean release publish-release setup-hooks setup-db reset-db logs logs-tail logs-errors push-and-publish

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
	@MIX_ENV=test mix ecto.create || true
	@MIX_ENV=test mix ecto.migrate
	@echo "✓ Test database created and migrations applied"

reset-db:
	@echo "⚠️  Resetting test database (dropping and recreating)..."
	@MIX_ENV=test mix ecto.drop || true
	@MIX_ENV=test mix ecto.create
	@MIX_ENV=test mix ecto.migrate
	@echo "✓ Test database reset complete"

init:
	@if [ ! -d .git ]; then git init; echo "Git initialized."; else echo "Git already initialized."; fi

deps:
	mix deps.get

run:
	mix run --no-halt

test:
	mix test

test-handlers:
	MIX_ENV=test mix test --only handlers --trace

test-stores:
	MIX_ENV=test mix test --only stores --trace

test-nats:
	MIX_ENV=test mix test --only nats --trace

test-integration:
	mix test --include integration --trace

test-full:
	mix test --include integration --include nats_live --trace

credo:
	mix credo

dialyzer: deps
	mix dialyzer

coverage:
	mix coveralls

check: test credo dialyzer
	@echo "All checks passed!"

format:
	mix format

clean:
	mix clean
	rm -rf _build cover
	rm -rf llm_proxy-*.tar.gz

release: test
	@echo "==============================================="
	@echo "Building OTP release"
	@echo "==============================================="
	MIX_ENV=prod mix release --overwrite
	@echo ""
	@echo "✓ Release built successfully"
	@echo "Location: _build/prod/rel/llm_proxy/"
	@echo ""

publish-release: release
	@echo "==============================================="
	@echo "Publishing release to GitHub"
	@echo "==============================================="
	@echo ""

	VERSION=$$(if [ -f _build/prod/rel/llm_proxy/releases/start_erl.data ]; then awk '{print $$2}' _build/prod/rel/llm_proxy/releases/start_erl.data; else tail -1 _build/prod/rel/llm_proxy/releases/RELEASES | cut -d' ' -f2; fi); \
	if [ -z "$$VERSION" ]; then echo "Could not read release version from start_erl.data or RELEASES"; exit 1; fi; \
	echo "Version: $$VERSION"; \
	echo "Creating release tarball..."; \
	tar -czf llm_proxy-$$VERSION.tar.gz -C _build/prod/rel llm_proxy/; \
	echo "✓ Tarball created: llm_proxy-$$VERSION.tar.gz"; \
	echo ""; \
	echo "Creating GitHub release v$$VERSION..."; \
	gh release create v$$VERSION llm_proxy-$$VERSION.tar.gz \
		--title "Release v$$VERSION" \
		--notes "LLM Bot Elixir release v$$VERSION. Download and deploy with Jenkins." \
		--draft=false || gh release upload v$$VERSION llm_proxy-$$VERSION.tar.gz --clobber; \
	echo "✓ Release published to GitHub"; \
	echo ""; \
	echo "Next steps:"; \
	echo "1. Jenkins will automatically detect the new release"; \
	echo "2. Trigger deployment in Jenkins UI or wait for auto-deployment"; \
	echo "3. Check deployment status: make jenkins-logs"; \
	echo ""

push-and-publish:
	@git push && $(MAKE) publish-release

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
