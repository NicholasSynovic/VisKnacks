# AGENTS.md

## What this repo is

Packaging/harness for **SciVisAgent** — OpenCode-compatible ParaView
visualization tooling. This is NOT a runnable Python app. It assembles
distributable OpenCode artifacts (agents, skills) plus an MCP server into
`build/`. The actual "product" is prose/config, not code:

- `agents/paraview-prompt-formatter.md` — OpenCode subagent (frontmatter + prompt).
- `skills/paraview/` — OpenCode skill: `SKILL.md` + `references/*.md`
  catalog of ParaView pvpython snippets. This is the primary content.
  The `SKILL.md` frontmatter declares `name: paraview-coder` (logical name
  differs from directory name).
- `mcp/pvpython-renderer/` — MCP server source. Built separately as a `uv`
  project. See `mcp/pvpython-renderer/AGENTS.md` for details.
- `benchmark/` — SciVisAgentBench tasks, downloaded on demand (gitignored).

## Setup

```
# Submodule init + pre-commit install only (does NOT create the conda env)
make create-dev

# Create the conda env separately
conda env create -f environment.yml   # env: paraview-agent-harness, python 3.14, paraview 6.1.1
conda activate paraview-agent-harness
```

Two separate conda environments exist in this repo:

|          | Root harness             | MCP server                               |
| -------- | ------------------------ | ---------------------------------------- |
| Config   | `environment.yml`        | `mcp/pvpython-renderer/environment.yaml` |
| Env name | `paraview-agent-harness` | `paraview_mcp`                           |
| Python   | 3.14                     | 3.10                                     |
| ParaView | 6.1.1                    | 5.13.3                                   |
| Purpose  | Lint/build               | Runtime for MCP server                   |

Activate the right env for the right task.

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
  the `paraview-coder` gotchas in `skills/paraview/SKILL.md` intact —
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

## Benchmark

```
make download-benchmark   # requires hf (huggingface_hub) CLI on PATH
```

`benchmark/` scripts are tracked; data dirs (`benchmark/data/`,
`benchmark/scivisagentbench/`) are gitignored and downloaded on demand.
