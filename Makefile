# Thin wrapper around `zig build` for all Zag libraries. Run `make` for help.

ZIG      ?= zig
LIBS     := zag-http zag-pg
LIB      ?= zag-http
EXAMPLE  ?= hello
OPTIMIZE ?= Debug
BENCH    ?=
PG_NAME  := zag-pg-test
PG_PORT  := 54329

.DEFAULT_GOAL := help
.PHONY: help build release run test test-release bench fuzz fmt fmt-check check clean pg-up pg-down pg-shell docs package-check

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Libraries: $(LIBS)"
	@echo "  Variables: LIB=$(LIB)  EXAMPLE=$(EXAMPLE)  OPTIMIZE=$(OPTIMIZE)  BENCH=\"$(BENCH)\"  ZIG=$(ZIG)"

build: ## Build every library and its examples
	@for lib in $(LIBS); do echo "==> $$lib"; (cd $$lib && $(ZIG) build -Doptimize=$(OPTIMIZE)) || exit 1; done

release: ## Build every library with ReleaseSafe
	@$(MAKE) --no-print-directory build OPTIMIZE=ReleaseSafe

run: ## Run an example: make run EXAMPLE=json_api, make run LIB=zag-pg EXAMPLE=todos
	cd $(LIB) && $(ZIG) build run-example -Dexample=$(EXAMPLE) -Doptimize=$(OPTIMIZE)

test: ## Run tests for every library
	$(ZIG) build test --summary all -Doptimize=$(OPTIMIZE)

test-release: ## Run tests for every library in ReleaseSafe
	$(ZIG) build test --summary all -Doptimize=ReleaseSafe

bench: ## Benchmark a library: make bench BENCH="--connections 64 --duration 10 --only json"
	cd $(LIB) && $(ZIG) build bench -- $(BENCH)

fuzz: ## Fuzz one library until Ctrl-C: make fuzz LIB=zag-http
	cd $(LIB) && $(ZIG) build test --fuzz -Doptimize=ReleaseFast

# Extra users to test MD5 and cleartext auth (the default user uses SCRAM).
define PG_SETUP
psql -U zag -q -c "set password_encryption = 'md5'; do \$$\$$ begin if not exists (select from pg_roles where rolname = 'md5user') then create role md5user login password 'md5pass'; end if; end \$$\$$;" && \
psql -U zag -q -c "do \$$\$$ begin if not exists (select from pg_roles where rolname = 'plainuser') then create role plainuser login password 'plainpass'; end if; end \$$\$$;" && \
hba=/var/lib/postgresql/data/pg_hba.conf && \
(grep -q md5user $$hba || sed -i '1i host all md5user all md5\nhost all plainuser all password' $$hba) && \
psql -U zag -q -c "select pg_reload_conf();"
endef
export PG_SETUP

pg-up: ## Start a Postgres 17 test container on port 54329 (Docker or Colima)
	@docker start $(PG_NAME) >/dev/null 2>&1 || docker run -d --name $(PG_NAME) -p $(PG_PORT):5432 \
		-e POSTGRES_USER=zag -e POSTGRES_PASSWORD=zag -e POSTGRES_DB=zag postgres:17-alpine >/dev/null
	@until docker exec $(PG_NAME) pg_isready -U zag >/dev/null 2>&1; do sleep 0.5; done
	@docker exec $(PG_NAME) sh -c "$$PG_SETUP" >/dev/null
	@echo "postgres://zag:zag@127.0.0.1:$(PG_PORT)/zag  (also: md5user:md5pass, plainuser:plainpass)"

pg-down: ## Stop and remove the Postgres test container
	-docker rm -f $(PG_NAME)

pg-shell: ## Open psql in the Postgres test container
	docker exec -it $(PG_NAME) psql -U zag

fmt: ## Format all Zig files
	$(ZIG) fmt .

fmt-check: ## Fail if any file is not formatted
	$(ZIG) fmt --check .

docs: ## Generate API docs into zig-out/docs (open zig-out/docs/index.html via a web server)
	$(ZIG) build docs

package-check: ## Build a fresh project that depends on this repo, as `zig fetch` would
	.github/scripts/package-check.sh

check: fmt-check test test-release ## Everything CI runs: format check + tests in Debug and ReleaseSafe

clean: ## Remove build outputs and caches
	rm -rf zig-out .zig-cache $(addsuffix /zig-out,$(LIBS)) $(addsuffix /.zig-cache,$(LIBS))
