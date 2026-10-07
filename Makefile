.POSIX:
.PHONY: all-in-one build clean dist lint precommit prepare test test-integration update

all-in-one:
	mix do deps.get --all + deps.compile + format + credo + compile + docs

dist: clean all-in-one lint test

clean:
	rm -rf _build deps

lint:
	# https://hexdocs.pm/dialyzex/readme.html
	# https://hexdocs.pm/credo/Credo.html
	# shows the debug info from dialyzer
	test -L ~/.mix/plts -o -d ~/.mix/plts || mkdir -p ~/.mix/plts/sofa
	env MIX_DEBUG=0 mix do format --check-formatted + dialyzer --format dialyxir + docs
	env MIX_DEBUG=0 mix credo --strict

# compile with warnings as errors, drop unused lock entries, format, test
precommit:
	mix precommit

# install hex & rebar, as needed on a fresh CI box
prepare:
	mix do local.hex --force --if-missing + local.rebar --force --if-missing

build:
	mix do compile + docs

gitup:
	@git clean -fdx
	@git fetch --force --prune --prune-tags
	@git reset --hard ${CI_REF}
	@git log --oneline HEAD -1

update:
	mix hex.outdated
	mix do deps.unlock --all + deps.update --all
	mix hex.docs fetch

test:
	mix test --trace --color

# needs a real CouchDB, see test/integration/README.md
test-integration:
	mix test --trace --color --include integration
