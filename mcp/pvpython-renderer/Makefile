.PHONY: build create-dev docker-build docker-run freeze

IMAGE := pvpython-renderer:latest

build:
	rm -rf build
	conda run -n pvpython_renderer uv build

docker-build:
	docker build -t $(IMAGE) .

# Serves the MCP endpoint at http://localhost:8080/mcp
docker-run:
	docker run --rm -p 8080:8080 \
		-v paraview-logs:/home/pvuser/paraview_logs \
		$(IMAGE)

create-dev:
	conda env create --file environment.yaml --name pvpython_renderer || \
		conda env update --file environment.yaml --name pvpython_renderer --prune
	conda run -n pvpython_renderer uv sync --group dev
	conda run -n pvpython_renderer uv pip install -e .

freeze:
	conda env export -n pvpython_renderer | grep -v "^prefix:" > environment.yaml
	@echo "NOTE: After freeze, manually verify channels include 'nodefaults' and pip section does not contain 'pvpython_renderer'."
