.POSIX:
.PHONY: all-in-one build clean dist docs lint precommit prepare test integration update

all-in-one:
	mix do deps.get --all + deps.compile + format + credo + compile + docs

dist: clean all-in-one lint test

clean:
	rm -rf _build deps

lint: # appease the linters
	# https://hexdocs.pm/dialyzex/readme.html
	# https://hexdocs.pm/credo/Credo.html
	# shows the debug info from dialyzer
	test -L ~/.mix/plts -o -d ~/.mix/plts || mkdir -p ~/.mix/plts/sofa
	env MIX_DEBUG=0 mix do format --check-formatted + dialyzer --format dialyxir + docs
	env MIX_DEBUG=0 mix credo --strict

precommit: # warnings as errors, drop unused lock entries, format, test
	mix precommit

prepare: # install hex & rebar, deps, for CI
	mix do local.hex --force --if-missing + local.rebar --force --if-missing
	mix deps.get --all

build: # deps.get + compile
	mix do deps.get + compile

docs: # generate elixir docs
	mix docs

gitup:
	@git clean -fdx
	@git fetch --force --prune --prune-tags
	@git reset --hard ${CI_REF}
	@git log --oneline HEAD -1

update:
	mix hex.outdated
	mix do deps.unlock --all + deps.update --all
	mix hex.docs fetch

test: # bypass, no real CouchDB
	mix test --trace --color --warnings-as-errors

integration: # needs a real CouchDB, see test/integration/README.md
	mix test --trace --color --include integration
