# AGENTS.md

## What this repo is

Packaging/harness for **SciVisAgent** — OpenCode-compatible ParaView
visualization tooling. This is NOT a runnable Python app. It assembles
distributable OpenCode artifacts (agents, skills) plus an MCP server into
`build/`. The actual "product" is prose/config, not code:

- `agents/paraview-prompt-formatter.md` — OpenCode subagent (frontmatter + prompt).
- `skills/paraview-coder/` — OpenCode skill: `SKILL.md` + `references/*.md`
  catalog of ParaView pvpython snippets. This is the primary content.
  The `SKILL.md` frontmatter declares `name: paraview-coder`, matching the
  directory name (older docs/READMEs still say `skills/paraview/` — that
  path no longer exists, ignore it).
- `mcp/pvpython-renderer/` — MCP server source, the one wired up in
  `opencode.json.template`. Built separately as a `uv` project. See
  `mcp/pvpython-renderer/AGENTS.md` for details.
- `mcp/pvpython-rag/` — sibling project (now tracked and working, despite
  the name it is not yet an MCP server): AST-based function extraction
  (`extract_functions.py`) + FAISS index builder (`pvpython_rag/main.py`,
  entry `python -m pvpython_rag.main`) that embeds ParaView Python API
  source with `nomic-ai/CodeRankEmbed` for RAG retrieval. Not wired into
  the root `make build` or `opencode.json.template` — it produces vector DBs,
  not a runtime server. `README.md` here is empty; use the module docstrings.
  See "pvpython-rag quick reference" below.
- `benchmark/` — SciVisAgentBench tasks, downloaded on demand (gitignored).

## Setup

```
make create-dev   # currently a no-op: target is declared .PHONY but has no
                   # recipe in the root Makefile. Previously ran submodule
                   # init + pre-commit install; the submodule was deleted
                   # and the pre-commit step was never restored. Run
                   # `pre-commit install` manually instead.

conda env create -f environment.yml   # env: paraview-agent-harness, python 3.14, paraview 6.1.1
conda activate paraview-agent-harness
```

Three separate conda environments exist in this repo (one per
`mcp/*/environment.yaml`, plus the root):

|          | Root harness             | pvpython-renderer                        | pvpython-rag                        |
| -------- | ------------------------ | ---------------------------------------- | ----------------------------------- |
| Config   | `environment.yml`        | `mcp/pvpython-renderer/environment.yaml` | `mcp/pvpython-rag/environment.yaml` |
| Env name | `paraview-agent-harness` | `pvpython_renderer`                      | `pvpython_rag`                      |
| Python   | 3.14                     | 3.10                                     | 3.10                                |
| ParaView | 6.1.1                    | 5.13.3                                   | 5.13.3                              |
| Purpose  | Lint/build               | Runtime for MCP server                   | RAG extraction (WIP)                |

Activate the right env for the right task. Each `mcp/*` subproject has its
own `make create-dev` (conda env create/update + `uv sync --group dev` +
`uv pip install -e .`) — that one _does_ work, unlike the root target.

## Build

```
make build   # assembles build/.opencode/{agents,skills}, copies opencode.json template
```

`build/` is gitignored. `make test` is a stub (`echo "test"`) — no test suite.

To build the MCP wheel directly:

```
# inside mcp/pvpython-renderer/
make build
```

## Lint / format

All quality gates run through **pre-commit** (`.pre-commit-config.yaml`):

```
pre-commit run --all-files
```

- Python: `ruff-check --fix` + `ruff-format` (ruff 0.15.21), `bandit`
  (excludes `tests,build`).
- All other files: `prettier` — **must be installed on PATH** (`language: system`,
  not managed by pre-commit). tab-width 4, print-width 80, trailing-comma es5.
- `no-commit-to-branch` blocks commits to `main`. Work on a branch.
- JSON is auto-formatted to 4-space indent, `--no-sort-keys`.

Style (`.editorconfig`): 4-space indent, LF, max line 80, **no final newline**
(Makefile uses tabs).

## Conventions specific to this repo

- Editing agent/skill behavior means editing markdown prompts, not code. Keep
  the `paraview-coder` gotchas in `skills/paraview-coder/SKILL.md` intact —
  they encode hard-won pvpython failure modes (unframed camera → blank image,
  leftover `'var0'` array, volume transfer-function quartets, `InsideOut`
  unreliable, Threshold `LowerThreshold`/`UpperThreshold` on 5.10+).
- The prompt-formatter subagent has all tool permissions denied by design; it
  only reformats prompts. Don't grant it tools.
- `mcp/pvpython-renderer/pvpython_renderer/pv_runner.py` uses
  `from paraview.simple import *` at module top. `F403`/`F405` are
  intentionally ignored in ruff config — do not remove the star import.
- `paraview` cannot be pip-installed; it is conda-only. `pyproject.toml`
  omits it from dependencies by design.

## MCP server quick reference

The server (streamable-http, stateless) is what `opencode.json.template`
points to. Start it with:

```
pvpython-renderer-mcp --server localhost --port 8080
```

The registered console script is `pvpython-renderer-mcp` (from
`mcp/pvpython-renderer/pyproject.toml`). The README says `paraview-mcp` —
that name is stale.

Uses **reverse-connection** to pvserver (not forward-connect). Running
`pvserver --multi-clients --server-port=11111` is not needed and does not work.

Logs: `~/paraview_logs/pvpython_renderer_external.log` and per-call
`~/paraview_logs/call_<timestamp>_runner.log`.

## pvpython-rag quick reference

Builds FAISS indexes over ParaView's Python API for RAG retrieval. Run all
commands from `mcp/pvpython-rag/` in the `pvpython_rag` conda env.

```
make clone-paraview          # git clones Kitware/ParaView into data/paraview-code
make create-vector-databases # runs scripts/build_all_indexes.sh
```

- `scripts/build_all_indexes.sh` iterates every eligible git tag of the
  vendored ParaView clone, checks each out into an isolated `git worktree`,
  and builds `index_<tag>.faiss` + `metadata_<tag>.json` in `data/vector-db/`.
  It skips tags lacking `Wrapping/Python/paraview`, RC/dev/final suffixes,
  and already-built tags. `FORCE=1` rebuilds existing tags. Failures per tag
  are logged and skipped; the script exits non-zero if any tag failed.
- Embedding uses `device="cuda"` (see `pvpython_rag/main.py`) — a GPU is
  required; there is no CPU fallback. `batch_size=1` and
  `max_seq_length=2048` are deliberate OOM mitigations; the `environment.yaml`
  carries GPU/CUDA deps.
- `make freeze` regenerates `environment.yaml` from the live env, then prints
  a reminder to manually verify channels include `nodefaults` and the pip
  section excludes `pvpython_rag` itself.
- `data/` (the ParaView clone and vector DBs) is gitignored.

## Benchmark

```
make download-benchmark   # requires hf (huggingface_hub) CLI on PATH
```

`benchmark/` scripts are tracked; data dirs (`benchmark/data/`,
`benchmark/scivisagentbench/`) are gitignored and downloaded on demand.
