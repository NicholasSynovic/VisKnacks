# AGENTS.md

## What this repo is

Packaging/harness for **SciVisAgent** — OpenCode-compatible ParaView
visualization tooling. This is NOT a runnable Python app. It assembles
distributable OpenCode artifacts (agents, skills) plus an MCP server into
`build/`. The actual "product" is prose/config, not code:

- `agents/paraview-prompt-formatter.md` — OpenCode subagent (frontmatter + prompt).
- `skills/paraview-coder/` — OpenCode skill: `SKILL.md` + `references/*.md`
  catalog of ParaView pvpython snippets. This is the primary content.
- `mcp/paraview-exec-mcp/` — git submodule (external repo, branch `0.3.0`),
  built as a `uv` project. **Submodule is not initialized by default** — run
  `git submodule update --init --recursive` before `make build`.
- `benchmark/` — SciVisAgentBench tasks, downloaded on demand (gitignored).

## Setup

```
make create-dev   # submodule init + pre-commit install + conda env
```

Environment is **conda** (`environment.yml`, env name `paraview-agent-harness`),
not pip/venv. Pins Python 3.14 and `paraview=6.1.1`. Activate the env before
any lint/build work.

## Build

```
make build   # assembles build/.opencode/{agents,skills} and uv-builds the MCP into build/dist
```

`make build` runs `uv build` on the MCP submodule; it fails silently-ish if the
submodule dir is empty. `make test` is a stub (`echo "test"`) — no real test
suite exists yet.

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
