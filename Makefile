.PHONY: build
build:
	mkdir -p build/.opencode/agents
	mkdir -p build/.opencode/skills
	cp agents/*.md build/.opencode/agents/
	cp -r $(wildcard skills/*/) build/.opencode/skills/

create-dev:
	pre-commit install

test:
	echo "test"
