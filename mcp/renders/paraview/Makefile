.PHONY: build create-dev freeze

build:
	rm -rf dist
	git tag | tr -s '[:blank:]' '\n' | sort | tail -n 1  | xargs -I % uv version %
	uv build
	uv pip install dist/*.tar.gz

create-dev:
	conda env update --file environment.yaml --prune
	conda run -n paraview_mcp pre-commit install
	rm -rf .venv
	conda run -n paraview_mcp uv sync --group dev

freeze:
	conda env export -n paraview_mcp | grep -v "^prefix:" > environment.yaml
	@echo "NOTE: After freeze, manually verify channels include 'nodefaults' and pip section does not contain 'paraview-mcp'."
