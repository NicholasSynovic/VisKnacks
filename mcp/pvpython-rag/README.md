<!-- prettier-ignore -->
<div align="center">

# pvpython-rag-mcp

> ParaView Python API code retrieval via RAG, exposed as an MCP tool

[![License](../../docs/license_badge.svg)](../../LICENSE)
![Python](https://img.shields.io/badge/Python-%3E%3D3.10-3776AB?style=flat-square&logo=python&logoColor=white)
![ParaView](https://img.shields.io/badge/ParaView-5.13.3-8A2BE2?style=flat-square)

[About](#about) • [Requirements](#requirements) • [Building the
Indexes](#building-the-indexes) • [Running the Server](#running-the-server) •
[The `query` Tool](#the-query-tool) • [Project Layout](#project-layout)

</div>

> [!WARNING]
> Status: work in progress.

## About

`pvpython-rag-mcp` is a FastMCP server that exposes a single `query` tool over
streamable-http. At startup it loads a prebuilt FAISS vector index
(`IndexFlatIP`, cosine similarity) and a `{function, docstring, code}` metadata
sidecar for a specified ParaView version, alongside the
`nomic-ai/CodeRankEmbed` embedding model. When `query` is called with a
natural-language description, the query is embedded with the same model used to
build the index and matched against the FAISS index, returning the top-k
matching records from the ParaView Python API.

This lets a code-generating agent look up correct `paraview.simple` usage for
a pinned ParaView version rather than relying on training-data recollection —
important because the `paraview.simple` API drifts significantly across
ParaView versions. The index builder (`pvpython_rag.main`) is also intended to
be queried with raw `pvpython` stderr/traceback text to retrieve relevant API
usage snippets.

Index building requires a CUDA GPU; the server itself runs on CPU. Indexes
must be prebuilt before the server starts.

## Requirements

The runtime is the single conda environment shared by every component of this
repository — `paraview` is conda-only and cannot be pip-installed. From the
repository root:

```bash
make create-dev
conda activate VisKnacks
```

This provides Python 3.10, ParaView 5.13.3, FAISS, torch,
sentence-transformers, and FastMCP. The first server start additionally needs
network access to download the `CodeRankEmbed` model from Hugging Face.

## Building the Indexes

Indexes are built from a local ParaView source checkout, one index per git
tag, by extracting every function from `Wrapping/Python/paraview` and embedding
its source code. Neither the clone nor the built indexes are tracked in git.

Clone ParaView into `data/paraview-code`:

```bash
mkdir -p data
git clone https://github.com/Kitware/ParaView.git data/paraview-code
```

Build an index for every eligible tag (release candidates, `-dev`, and `-final`
tags are skipped). Output lands in `data/vector-db/`:

```bash
bash scripts/build_all_indexes.sh
```

> [!NOTE]
> `build_all_indexes.sh` writes to `data/vector-db/`, while the run commands
> below use `data/paraview-vector-db/`. Either pass the directory you built to
> `--directory`, or copy the built files over.

To build an index for a single version instead, run the builder directly:

```bash
python -m pvpython_rag.main \
    --input-dir data/paraview-code/Wrapping/Python/paraview \
    --output-dir data/paraview-vector-db \
    --tag v5.13.3
```

This produces `index_v5.13.3.faiss` and `metadata_v5.13.3.json`. Index
building requires a CUDA GPU (`batch_size=1` and `max_seq_length=2048` are
deliberate out-of-memory mitigations). Set `FORCE=1` to re-run
`build_all_indexes.sh` over already-built tags.

## Running the Server

From this directory:

```bash
conda activate VisKnacks
python -m pvpython_rag.rag_mcp --host localhost --port 8081 \
    --directory data/paraview-vector-db
```

The endpoint is `http://localhost:8081/mcp`. Port 8081 is deliberately not
8080, so this server can run side by side with `pvpython-renderer-mcp`. When
containerized, pass `--host 0.0.0.0` to be reachable from outside the
container's network namespace.

> [!NOTE]
> The `pvpython-rag-mcp` console script (installed by `make install`) runs
> this server; the module invocation above is equivalent and needs no
> installation.

A missing or inconsistent index/metadata pair for `--pv-version` (default
`5.13.3`) fails fast at startup before the server binds.

## The `query` Tool

| Parameter | Type  | Default | Description                                                        |
| --------- | ----- | ------- | ------------------------------------------------------------------ |
| `query`   | `str` | —       | Natural-language description of the desired functionality          |
| `k`       | `int` | `5`     | Maximum number of results, ordered by descending cosine similarity |

Returns up to `k` records, each a `{function, docstring, code, score}` dict
where `score` is the cosine similarity (higher is better). The CodeRankEmbed
query-instruction prefix is added internally — callers pass plain text.

> [!IMPORTANT]
> The embedding configuration in `pvpython_rag/rag_mcp.py` (model, sequence
> length, normalization) must stay identical to `pvpython_rag/main.py`, which
> builds the indexes — otherwise query embeddings are not comparable to the
> stored document embeddings and retrieval silently degrades.

## Project Layout

| Path                                | Description                                                                   |
| ----------------------------------- | ----------------------------------------------------------------------------- |
| `pvpython_rag/rag_mcp.py`           | The MCP server (`query` tool, CLI, index/metadata loading)                    |
| `pvpython_rag/main.py`              | Index builder: extract, embed, and persist a FAISS index for one source tree  |
| `pvpython_rag/extract_functions.py` | AST-based extraction of function/method `{function, docstring, code}` records |
| `scripts/build_all_indexes.sh`      | Builds one index per eligible ParaView git tag using isolated git worktrees   |
| `data/`                             | Gitignored: the vendored ParaView clone (`paraview-code`) and built indexes   |

## License

This project is licensed under BSD-3-Clause. See [LICENSE](../../LICENSE) for
more details.
