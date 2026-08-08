.PHONY: build clone-paraview create-dev create-vector-databases docker-build \
	docker-run freeze

CONDA_ENV := pvpython_rag
IMAGE := pvpython-rag:latest

build:
	rm -rf build
	conda run -n pvpython_rag uv build

docker-build:
	docker build -t $(IMAGE) .

# Requires an NVIDIA GPU (rag_mcp.py hardcodes device="cuda") and prebuilt
# indexes in data/vector-db (run `make create-vector-databases` first).
# Serves the MCP endpoint at http://localhost:8081/mcp
docker-run:
	docker run --rm --gpus all -p 8081:8081 \
		-v "$(CURDIR)/data/vector-db:/data:ro" \
		-v hf-cache:/cache/huggingface \
		$(IMAGE)

create-dev:
	conda env create --file environment.yaml --name $(CONDA_ENV) || \
		conda env update --file environment.yaml --name $(CONDA_ENV) --prune
	PY_EXEC=$$(conda run -n $(CONDA_ENV) python -c "import sys; print(sys.executable)") && \
	conda run -n $(CONDA_ENV) uv sync --python "$$PY_EXEC" && \
	conda run -n $(CONDA_ENV) uv pip install --python "$$PY_EXEC" -e .

create-vector-databases:
	mkdir -p data/vector-db
	conda run -n $(CONDA_ENV) bash scripts/build_all_indexes.sh

freeze:
	conda env export -n $(CONDA_ENV) | grep -v "^prefix:" > environment.yaml
	@echo "NOTE: After freeze, manually verify channels include 'nodefaults' and pip section does not contain 'pvpython_rag'."
