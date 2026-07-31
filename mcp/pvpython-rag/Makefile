.PHONY: build create-dev freeze

build:
	rm -rf build
	conda run -n pvpython_rag uv build

create-dev:
	conda env create --file environment.yaml --name pvpython_rag || \
		conda env update --file environment.yaml --name pvpython_rag --prune
	conda run -n pvpython_rag uv sync --group dev
	conda run -n pvpython_rag uv pip install -e .

freeze:
	conda env export -n pvpython_rag | grep -v "^prefix:" > environment.yaml
	@echo "NOTE: After freeze, manually verify channels include 'nodefaults' and pip section does not contain 'pvpython_rag'."
