.PHONY: build create-dev freeze

build:
	rm -rf dist
	uv build
	uv pip install dist/*.tar.gz

create-dev:
	conda env create --file environment.yaml --name pvpython_renderer || \
		conda env update --file environment.yaml --name pvpython_renderer --prune
	conda run -n pvpython_renderer uv sync --group dev
	conda run -n pvpython_renderer uv pip install -e .

freeze:
	conda env export -n pvpython_renderer | grep -v "^prefix:" > environment.yaml
	@echo "NOTE: After freeze, manually verify channels include 'nodefaults' and pip section does not contain 'pvpython_renderer'."
