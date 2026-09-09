<!-- prettier-ignore -->
<div align="center">

# VisKnacks

> HPC ready scientific visualization agent (SciVisAgent) tooling for hybrid
> local-HPC ParaView workflows, compatible with existing agent harnesses

[![License](docs/license_badge.svg)](LICENSE)
![Python](https://img.shields.io/badge/Python-%3E%3D3.10-3776AB?style=flat-square&logo=python&logoColor=white)
![ParaView](https://img.shields.io/badge/ParaView-5.13.3-8A2BE2?style=flat-square)

[About](#about) • [System Overview](#system-overview) • [Getting
Started](#getting-started) • [Usage](#usage) • [Repository
Layout](#repository-layout) • [License](#license)

</div>

## About

Large scientific simulations on HPC systems can produce terabytes of data per timestep, making it impractical to copy datasets to local machines for post-hoc visualization --- yet scientists require iterative visualization workflows as their understanding of the data evolves. Recent scientific visualization agents (_SciVisAgents_) can generate ParaView rendering pipelines from natural language, but existing systems primarily target local execution and provide limited support for HPC deployment, remote rendering, and software packaging. _VisKnacks_ addresses this by providing a multi-agent prompt interpreter, a `paraview-coder` Agent Skill covering common ParaView pipeline operations, and two MCP services — one for ParaView Python API documentation retrieval via RAG and one for remote pipeline rendering on HPC resources — packaged as pluggable components compatible with existing agent harnesses (OpenCode, Claude Code, Kilo Code, and others). Evaluated on ParaView tasks from SciVisAgentBench on Argonne National Laboratory's ALCF Crux system, VisKnacks enables domain scientists to develop and refine pipelines locally while executing rendering jobs on remote HPC infrastructure.

## System Overview

VisKnacks is structured around three pluggable component types that together enable hybrid local–HPC visualization workflows. A **multi-agent prompt interpreter** (`paraview-prompt-formatter`) converts natural language visualization requests into structured, pipeline-ready queries before any code is generated. A **`paraview-coder` Agent Skill** encodes common ParaView pipeline operations — readers, filters, rendering, camera framing, and output — as reusable instructions an agent can load on demand. Two **MCP services** provide the HPC-facing capabilities: `pvpython-rag-mcp` exposes ParaView Python API documentation retrieval via RAG, and `pvpython-renderer-mcp` executes and renders ParaView pipelines on remote HPC resources. Together these components integrate with existing agent harnesses, allowing pipeline development and refinement to happen locally while compute- and data-intensive rendering is dispatched to HPC infrastructure.

### Subagents

#### `paraview-prompt-formatter`

[`paraview-prompt-formatter`](agents/paraview-prompt-formatter.md) is a sandboxed subagent — a bounded LLM instance invoked by the primary agent for a single, well-defined task — that translates a casual or vague natural-language visualization request into a structured, flat-prose ParaView prompt. It maps informal terms to concrete ParaView operations, preserves all user-supplied values verbatim (file paths, array names, isosurface values, coordinates), and bakes in conventions such as a default 1920×1080 screenshot resolution. If either the input data path or the output screenshot path is missing, it blocks and prompts the user before emitting anything. By design it has no access to files, code, or the filesystem — the only tool it can call is `question` — establishing a strict trust boundary between user intent and code generation. This normalization layer ensures the downstream `paraview-coder` skill always receives a complete, unambiguous prompt rather than raw user input, making script generation deterministic and reducing the risk of broken or incomplete pipelines.

### Agent Skills

#### `paraview-coder`

[`paraview-coder`](skills/paraview-coder/SKILL.md) is an Agent Skill — a reusable, on-demand instruction set that is loaded by the agent whenever a ParaView visualization task is detected. It guides the agent through producing a complete, headless `pvpython` script in eight ordered steps: formatting the request (via `paraview-prompt-formatter`), selecting the correct file reader, applying filters, creating the render view, coloring and displaying data, handling layout and multi-view comparisons, framing the camera, and saving the screenshot. To support this, the skill ships a progressively loadable catalog of working code snippets across six reference files covering readers (`.vtk`, `.vtu`, `.vtp`, `.ex2`/IOSS, and more), filters (Contour, Slice, Clip, StreamTracer, Threshold, and others), rendering and camera framing, display and color, layout, and output formats. Without it, the agent would need to rediscover ParaView's headless-specific failure modes — blank screenshots from unframed cameras, solid-black volume renders from incomplete transfer functions, broken pipelines from leftover placeholder array names — on every run; the skill encodes this domain knowledge once and makes it available to any compatible agent harness. The generated scripts target `pvpython` (ParaView 5.10+) and are designed for remote execution on HPC resources via `pvpython-renderer-mcp`.

### MCP Services

#### `pvpython-rag-mcp`

> [!WARNING]
> Status: work in progress.

[`pvpython-rag-mcp`](mcp/pvpython-rag/) is a FastMCP server that exposes a single `query` tool over streamable-http. At startup it loads a prebuilt FAISS vector index (`IndexFlatIP`, cosine similarity) and a `{function, docstring, code}` metadata sidecar for a specified ParaView version into memory, alongside the `nomic-ai/CodeRankEmbed` embedding model. When `query` is called with a natural-language description, the query is embedded with the same model used to build the index and matched against the FAISS index, returning the top-k `{function, docstring, code, score}` records from the ParaView Python API. This lets the code-generating agent look up correct `paraview.simple` API usage for a pinned version rather than relying on training-data recollection, reducing incorrect method signatures and deprecated calls — particularly important given that the `paraview.simple` API drifts significantly across ParaView versions. Index building requires a CUDA GPU; the server itself runs on CPU. Indexes must be prebuilt before the server starts and the server defaults to port 8081 to avoid collision with `pvpython-renderer-mcp`.

#### `pvpython-renderer-mcp`

[`pvpython-renderer-mcp`](mcp/pvpython-renderer/) is a FastMCP server that exposes a single `execute_code` tool over streamable-http, and is the component that enables HPC rendering. Each call is fully stateless: the server spawns an ephemeral `pvpython` runner and a single-client `pvserver` in reverse-connection mode (the server dials back to the runner, rather than the more common forward-connect pattern, because `pvserver` advertises its system hostname rather than `localhost`), executes the supplied `paraview.simple` Python script inside the resulting session, captures all stdout and stderr, and tears both processes down. The agent submits the complete `pvpython` script produced by `paraview-coder`, receives the execution logs and exit code, and uses them to determine whether the pipeline succeeded or requires refinement — all without transferring the underlying scientific dataset off the HPC system. The stateless, per-call design means iterative pipeline refinement requires no session management. The service is Linux-64 only, requires `pvserver` and `pvpython` on `PATH` at call time, and enforces a 120-second per-call execution timeout.

## Getting Started

### Prerequisites

- Conda — `paraview` is conda-only and cannot be pip-installed, so the
  runtime is a conda environment rather than a plain virtualenv.
- uv — used by `make build` to build the MCP service wheels.
- Git and pre-commit — two hooks (`prettier` and `skills-ref`) are locally
  installed and must already be on `PATH`.

### Installation

Create the single conda environment used by every component (Python 3.10,
ParaView 5.13.3, FAISS, torch, sentence-transformers), then install the git
hooks:

```bash
make create-dev
conda activate VisKnacks
pre-commit install
```

> [!NOTE]
> `paraview` is provided by conda and is intentionally absent from every
> `pyproject.toml` in this repository.

## Usage

### Build the distributable

```bash
make build
```

This assembles the OpenCode artifacts into `build/.opencode/` (the config
template, the `paraview-prompt-formatter` subagent, and the
`paraview-coder` skill) and builds a wheel for each MCP service into
`dist/`.

### Run the MCP services

Both services are stateless FastMCP servers over streamable-http and are
meant to run side by side. Neither package is installed into the conda
environment by default; start each as a module from its own package
directory.

Start the RAG service (endpoint `http://localhost:8081/mcp`):

```bash
cd mcp/pvpython-rag
python -m pvpython_rag.rag_mcp --host localhost --port 8081 \
    --directory data/paraview-vector-db
```

> [!NOTE]
> The FAISS indexes and the vendored ParaView source checkout under
> `mcp/pvpython-rag/data/` are not tracked in git and must be built before
> the server starts. See
> [`scripts/build_all_indexes.sh`](mcp/pvpython-rag/scripts/build_all_indexes.sh);
> index building requires a CUDA GPU.

Start the rendering service (endpoint `http://localhost:8080/mcp`) — see
[`mcp/pvpython-renderer/README.md`](mcp/pvpython-renderer/README.md) for
build and run instructions, the `execute_code` tool reference, and
troubleshooting.

### Connect an agent harness

Point your harness at the two endpoints registered in
[`build-scripts/opencode.json.template`](build-scripts/opencode.json.template):
`http://localhost:8080/mcp` (`pvpython-renderer-mcp`) and
`http://localhost:8081/mcp` (`pvpython-rag-mcp`). `make build` copies this
template to `build/.opencode/opencode.json` alongside the subagent and
skill.

### Development checks

There is no test suite or CI; all quality gates run through pre-commit:

```bash
pre-commit run --all-files
```

## Repository Layout

| Path                     | Description                                                                             |
| ------------------------ | --------------------------------------------------------------------------------------- |
| `agents/`                | The `paraview-prompt-formatter` OpenCode subagent                                       |
| `skills/paraview-coder/` | The `paraview-coder` Agent Skill (`SKILL.md` + six `references/*.md` snippet catalogs)  |
| `mcp/pvpython-renderer/` | FastMCP server exposing the `execute_code` headless-rendering tool                      |
| `mcp/pvpython-rag/`      | FastMCP server exposing the `query` RAG-retrieval tool, plus its index-building scripts |
| `build-scripts/`         | Assembles the OpenCode distributable into `build/.opencode/`                            |
| `benchmark/`             | SciVisAgentBench evaluation harness (`benchmark.bash`, `metrics.py`)                    |
| `environment.yaml`       | Conda environment specification (Python 3.10, ParaView 5.13.3)                          |
| `Makefile`               | `make create-dev` and `make build`                                                      |

## License

This project is licensed under BSD-3-Clause. See [LICENSE](LICENSE) for more
details.
