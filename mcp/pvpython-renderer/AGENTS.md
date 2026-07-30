# AGENTS.md — pvpython-renderer

## What this project is

A standalone MCP server (`pvpython_renderer` package) that exposes a single
tool — `execute_code` — over streamable-http. Each call spawns an ephemeral
`pvserver` in reverse-connection mode, runs arbitrary `paraview.simple` Python
inside it, and tears everything down. No shared state between calls. No GUI.

## Console script name mismatch

`pyproject.toml` registers the entry point as **`pvpython-renderer-mcp`**, not
`paraview-mcp`. The README and internal docstrings still say `paraview-mcp` —
that is stale. After `pip install -e .` the correct command is:

```
pvpython-renderer-mcp --server localhost --port 8080
```

## Conda env is the runtime

Python version comes from the pinned `paraview=5.13.3=py310...` conda package,
not from any `.python-version` file or `requires-python`. Always activate the
env before running or installing:

```
conda activate paraview_mcp
pip install -e .   # registers the console script
```

`paraview` cannot be pip-installed and is intentionally absent from
`pyproject.toml`.

## Package layout

```
pvpython_renderer/
    __init__.py   # __prog__, __version__, __doi__
    cli.py        # argparse: --server / --port only (no subcommands)
    main.py       # entrypoint: parse args -> import pv_mcp -> pv_mcp.run()
    logger.py     # writes ~/paraview_logs/pvpython_renderer_external.log
    prompts.py    # FastMCP instructions string (no paraview import)
    pv_mcp.py     # FastMCP server + execute_code tool + subprocess lifecycle
    pv_runner.py  # spawned under pvpython; calls ReverseConnect + exec(code)
```

`pv_mcp.py` is import-clean of `paraview.simple`; only `pv_runner.py` (run as
a subprocess under `pvpython`) imports it. This is intentional — do not add
`paraview.simple` imports to `pv_mcp.py`.

## Reverse-connection is required

`pvserver` is launched with `--reverse-connection --client-host=localhost`. The
runner (`pv_runner.py`) listens first via `ReverseConnect(str(port))`, then
`pvserver` dials back. Forward `Connect("localhost", port)` does not work —
`pvserver` advertises its system hostname (not `localhost`), which causes
connection refusals for the full retry window.

`ReverseConnect` receives a **string** port, not an int — this works around a
ParaView 5.13.x bug where an int port gets concatenated into a URL string.

## Developer commands

```bash
make create-dev          # conda env update + pre-commit install + uv sync --group dev
make build               # set version from latest git tag + uv build + reinstall sdist
make freeze              # export conda env to environment.yaml (verify manually after)
pre-commit run --all-files
```

No test suite. `make test` does not exist in this project.

## pre-commit hooks

Run against this directory using the root `.pre-commit-config.yaml`
(at repo root, not here). Hooks:

- `ruff-check --fix` + `ruff-format` (Python)
- `bandit` (excludes `tests,build`)
- `prettier` — **must be on `PATH`** (`language: system`); tab-width 4,
  print-width 80, trailing-comma es5
- `no-commit-to-branch` — blocks commits to `main`; work on a branch
- `pretty-format-json` — 4-space indent, no key sorting

## F403/F405 are intentionally suppressed

`pv_runner.py` uses `from paraview.simple import *`. Ruff ignores `F403`/`F405`
project-wide (`pyproject.toml`). Do not remove the star import.

## Logs

| Log               | Path                                             |
| ----------------- | ------------------------------------------------ |
| Main server       | `~/paraview_logs/pvpython_renderer_external.log` |
| Per-call runner   | `~/paraview_logs/call_<timestamp>_runner.log`    |
| Per-call pvserver | `~/paraview_logs/call_<timestamp>_pvserver.log`  |

Directory is created automatically on first run.

## Subprocess timeouts

- Runner ready banner wait: **30 s** (`RUNNER_READY_TIMEOUT`)
- Code execution timeout: **120 s** (`SUBPROCESS_TIMEOUT`)

Both constants are at the top of `pv_mcp.py`.
