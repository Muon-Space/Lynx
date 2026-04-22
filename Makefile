mix          ?= mix
iex          ?= iex


help: Makefile
	@echo
	@echo " Choose a command run in Lynx:"
	@echo
	@sed -n 's/^##//p' $< | column -t -s ':' |  sed -e 's/^/ /'
	@echo


## fmt: Format code.
.PHONY: fmt
fmt:
	@echo ">> ============= Format code ============= <<"
	@$(mix) format mix.exs "lib/**/*.{ex,exs}" "test/**/*.{ex,exs}"


## fmt_check: Check code format.
.PHONY: fmt_check
fmt_check:
	@echo ">> ============= Check code format ============= <<"
	@$(mix) format mix.exs "lib/**/*.{ex,exs}" "test/**/*.{ex,exs}" --check-formatted


## deps: Fetch dependencies
.PHONY: deps
deps:
	@echo ">> ============= Fetch dependencies ============= <<"
	@$(mix) deps.get


## test: Test code
.PHONY: test
test:
	@echo ">> ============= Test code ============= <<"
	@$(mix) test --trace


## coverage: Run tests with coverage report (enforces threshold from coveralls.json)
.PHONY: coverage
coverage:
	@echo ">> ============= Test coverage ============= <<"
	@$(mix) coveralls


## coverage_html: Run tests with coverage and generate HTML report at cover/excoveralls.html
.PHONY: coverage_html
coverage_html:
	@echo ">> ============= Coverage HTML report ============= <<"
	@$(mix) coveralls.html


## build: Build code
.PHONY: build
build:
	@echo ">> ============= Build code ============= <<"
	@$(mix) compile --warnings-as-errors --all-warnings


## i: Run interactive shell
.PHONY: i
i:
	@echo ">> ============= Interactive shell ============= <<"
	@$(iex) -S mix phx.server


## migrate: Create database
.PHONY: migrate
migrate:
	@echo ">> ============= Create database ============= <<"
	@$(mix) ecto.setup


## run: Run lynx
.PHONY: run
run:
	@echo ">> ============= Run lynx ============= <<"
	@$(mix) phx.server


## ecto: Run ecto
.PHONY: ecto
ecto:
	@echo ">> ============= Run ecto ============= <<"
	@$(mix) ecto


## v: Get version
.PHONY: v
v:
	@echo ">> ============= Get application version ============= <<"
	@$(mix) version


## openapi_dump: Regenerate api.yml from controller @operation annotations
.PHONY: openapi_dump
openapi_dump:
	@echo ">> ============= Dump OpenAPI spec ============= <<"
	@$(mix) lynx.openapi.dump


## openapi_check: Fail if api.yml has drifted from controllers (CI)
.PHONY: openapi_check
openapi_check:
	@echo ">> ============= Check OpenAPI spec drift ============= <<"
	@$(mix) lynx.openapi.dump --check


## ci: Run ci (tests + coverage gate + OpenAPI drift check)
.PHONY: ci
ci: coverage openapi_check


## playwright_install: Install chromium browser for feature tests (one-shot)
.PHONY: playwright_install
playwright_install:
	@echo ">> ============= Install Playwright chromium ============= <<"
	@cd assets && npm install
	@npx --prefix assets playwright install --with-deps chromium


## assets_deploy: Build JS + CSS bundles into priv/static/assets
.PHONY: assets_deploy
assets_deploy:
	@echo ">> ============= Build assets ============= <<"
	@$(mix) assets.deploy


## feature_test: Run browser-driven feature tests (PhoenixTest.Playwright)
.PHONY: feature_test
feature_test: assets_deploy
	@echo ">> ============= Feature tests (Playwright) ============= <<"
	@$(mix) test --only feature


## ci_feature: CI entry point for feature tests (install browser, then run)
.PHONY: ci_feature
ci_feature: playwright_install feature_test
