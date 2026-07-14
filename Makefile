.PHONY: build create-dev
build:
	mkdir -p build/.opencode/agents
	mkdir -p build/.opencode/skills
	mkdir -p build/dist
	cp agents/*.md build/.opencode/agents/
	cp -r $(wildcard skills/*/) build/.opencode/skills/
	uv build --project mcp/paraview-exec-mcp --out-dir build/dist

create-dev:
	git submodule update --init --recursive
	pre-commit install

test:
	echo "test"
