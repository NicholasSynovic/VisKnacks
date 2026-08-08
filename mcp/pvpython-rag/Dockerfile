# syntax=docker/dockerfile:1
#
# pvpython-rag MCP server — FAISS retrieval over the ParaView Python API.
#
# !! REQUIRES AN NVIDIA GPU !!
#   rag_mcp.py hardcodes device="cuda" with no CPU fallback, so the container
#   exits non-zero at startup on a GPU-less host. Run it with the NVIDIA
#   Container Toolkit installed and `--gpus all`.
#
# !! LARGE IMAGE (~10-15 GB) !!
#   environment.yaml is a full `conda env export` freeze pinning torch, the
#   nvidia-* CUDA 13 wheels, conda libtorch, and cuda-toolkit.
#
# This image is SERVE-ONLY. Building indexes (scripts/build_all_indexes.sh)
# needs a ParaView git clone and stays a host-side task; mount the resulting
# indexes at /data.
#
# Build:
#   docker build -t pvpython-rag:latest .
#
# Run:
#   docker run --rm --gpus all -p 8081:8081 \
#       -v "$(pwd)/data/vector-db:/data:ro" \
#       -v hf-cache:/cache/huggingface \
#       pvpython-rag:latest
#
# The MCP endpoint is then at http://localhost:8081/mcp

FROM condaforge/miniforge3:24.11.3-2

# environment.yaml pins packages (faiss, numpy, libtorch, ...) that resolve
# from Anaconda's `defaults` channel rather than conda-forge, so the solve
# below depends on it. Newer conda ships the `conda-anaconda-tos` plugin,
# which refuses to install from `defaults` until its Terms of Service are
# accepted; the conda in this base image predates that plugin and needs no
# acceptance. Accept it only when the subcommand exists, so the build works
# both today and after a base-image bump.
#
# Note: using `defaults` carries Anaconda's ToS/licensing terms, which may
# have commercial-use implications when redistributing this image. Switch
# environment.yaml to a conda-forge-only spec to avoid them.
RUN if conda tos --help >/dev/null 2>&1; then \
    conda tos accept --override-channels \
    --channel https://repo.anaconda.com/pkgs/main \
    --channel https://repo.anaconda.com/pkgs/r; \
    else echo "conda tos plugin not present; skipping ToS acceptance"; fi

# The conda env IS the runtime. Note that pyproject.toml declares only
# `fastmcp`, while the code imports faiss, numpy, and sentence_transformers —
# those come from environment.yaml, so it is not optional.
#
# CONDA_OVERRIDE_CUDA is required: environment.yaml pins the CUDA builds of
# faiss/libfaiss, which depend on the `__cuda` virtual package. Conda derives
# `__cuda` from the *host driver*, which is not visible during `docker build`
# (there is no --gpus at build time), so the solve fails with "nothing
# provides __cuda" on any builder — even a GPU machine. Asserting the version
# here only affects dependency resolution, not what is linked at runtime; it
# must be >= the CUDA version the pinned packages target (cuda130 -> 13.0).
COPY environment.yaml /tmp/environment.yaml
RUN CONDA_OVERRIDE_CUDA=13.0 conda env create --file /tmp/environment.yaml \
    && conda clean --all --yes \
    && rm -f /tmp/environment.yaml

# Put the env's bin on PATH rather than relying on `conda activate`.
ENV PATH=/opt/conda/envs/pvpython_rag/bin:$PATH

WORKDIR /app

# pyproject.toml sets `readme = "README.md"`, so setuptools needs it present.
COPY pyproject.toml README.md ./
COPY pvpython_rag/ ./pvpython_rag/

# --no-deps: environment.yaml already froze every runtime dependency at an
# exact version. Letting pip re-resolve `fastmcp` here would risk pulling a
# different transitive set over the pinned one.
RUN pip install --no-cache-dir --no-deps . \
    && python -c "import pvpython_rag.rag_mcp"

# Model weights (nomic-ai/CodeRankEmbed) are downloaded on first start and
# cached here. Mount a volume to avoid re-downloading on every run.
ENV HF_HOME=/cache/huggingface

# Run as a non-root user. uid 1001: the base image ships `ubuntu` at 1000.
RUN useradd --create-home --uid 1001 --shell /bin/bash raguser \
    && mkdir -p /cache/huggingface /data \
    && chown -R raguser:raguser /cache/huggingface /data
USER raguser
ENV HOME=/home/raguser

# /data holds the prebuilt index_<tag>.faiss + metadata_<tag>.json pairs.
VOLUME ["/data", "/cache/huggingface"]

EXPOSE 8081

# A plain HTTP GET on /mcp returns 406 without the MCP negotiation headers, so
# it is not a usable probe. Check that the transport is accepting TCP instead.
# start-period is generous: the embedding model loads before the server binds.
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
    CMD python -c "import socket,sys; s=socket.create_connection(('127.0.0.1',8081),3); s.close()" \
    || exit 1

# Bind 0.0.0.0: the `localhost` default is unreachable from a published port.
# --directory is a required argument and must point at the mounted indexes.
CMD ["pvpython-rag-mcp", "--host", "0.0.0.0", "--port", "8081", \
    "--directory", "/data"]
