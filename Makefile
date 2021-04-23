.POSIX:
.PHONY: all-in-one build clean dist lint test update

all-in-one:
	mix do deps.get --all, deps.compile, format, credo, compile

dist: clean all-in-one lint test

clean:
	rm -rf _build deps

lint:
	# https://hexdocs.pm/dialyzex/readme.html
	# https://hexdocs.pm/credo/Credo.html
	# shows the debug info from dialyzer
	test -L ~/.mix/plts -o -d ~/.mix/plts || mkdir p ~/.mix/plts/sofa
	env MIX_DEBUG=0 mix do format --check-formatted, credo --strict, dialyzer

build:
	mix compile

gitup:
	@git clean -fdx
	@git fetch --force --prune --prune-tags
	@git reset --hard ${CI_REF}
	@git log --oneline HEAD -1

update:
	mix hex.outdated
	mix do deps.unlock --all, deps.update --all
	mix hex.docs fetch

test:
	mix test --trace
