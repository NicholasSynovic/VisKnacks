.PHONY: build create-dev

build:
	# Build OpenCode release
	bash -c build-scripts/opencode.bash

	# Build MCP services
	uv build --package pvpython-renderer
	uv build --package pvpython-rag

create-dev:
	conda env create --file environment.yaml --name VisKnacks
