.PHONY: build
build:
	mkdir -p build/.opencode/agents
	cp $(filter-out agents/README.md,$(wildcard agents/*.md)) build/.opencode/agents/

create-dev:
	pre-commit install

test:
	echo "test"
