.PHONY: build create-dev

build:
	# Build OpenCode release
	bash -c build-scripts/opencode.bash

create-dev:
	conda env create --file environment.yaml --name VisKnacks
