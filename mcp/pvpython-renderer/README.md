# pvpython-renderer

> An MCP server that gives LLM clients direct access to a ParaView session

## About

pvpython-renderer is an MCP server that gives LLM clients (OpenCode, Claude
Desktop, etc.) direct access to a ParaView session via a single tool:
`execute_code`. Each call runs arbitrary `paraview.simple` Python code in a
fresh, isolated ParaView session — no shared state, no manually managed
`pvserver`, no GUI required.

Each `execute_code` call is fully self-contained: the server spawns a
`pv_runner.py` listener under `pvpython`, then launches a single-client
`pvserver` in reverse-connection mode to dial back to it. The supplied code
runs inside that session, all output is captured and returned, and both
processes are torn down. Multi-step workflows must be expressed within a single
`code` string.

## Table of Contents

- [pvpython-renderer](#pvpython-renderer)
    - [About](#about)
    - [Table of Contents](#table-of-contents)
    - [Application Overview](#application-overview)
    - [How to Build](#how-to-build)
    - [How to Run](#how-to-run)
    - [Installation](#installation)
        - [Prerequisites](#prerequisites)
        - [Installation](#installation-1)
        - [Running the server](#running-the-server)
        - [MCP Tool Reference](#mcp-tool-reference)
            - [`execute_code`](#execute_code)
    - [Troubleshooting](#troubleshooting)

## Application Overview

## How to Build

## How to Run

## Installation

### Prerequisites

- **conda** (Miniforge or Miniconda) with the `conda-forge` channel configured
- **linux-64 platform** — macOS and Windows are not supported
- **`pvserver` and `pvpython` on `PATH`** — provided by the
  `conda-forge::paraview` package installed via `environment.yaml`

### Installation

```bash
make create-dev
conda activate pvpython_renderer
```

`make create-dev` creates or updates the `pvpython_renderer` conda env from
`environment.yaml`, installs the git pre-commit hooks, and runs
`uv sync --group dev` to install the dev dependency group. The `paraview`
package is provided by conda and is intentionally absent from `pyproject.toml`
(it cannot be pip-installed).

> **Python version:** the conda env _is_ the runtime. Its interpreter (Python
> 3.10, from the pinned `paraview=5.13.3=py310...` package) is what
> `pvpython-renderer-mcp` runs on. `pyproject.toml`'s
> `requires-python = ">=3.10"` is advisory only.

### Running the server

```bash
conda activate pvpython_renderer
pvpython-renderer-mcp --server localhost --port 8080
```

`--server` (default `localhost`) and `--port` (default `8080`) set the
streamable-http bind address. The MCP endpoint is served at
`http://<server>:<port>/mcp`.

### MCP Tool Reference

#### `execute_code`

Run arbitrary `paraview.simple` Python code in a fresh, stateless session.

```
execute_code(code: str) -> dict
```

**Arguments:** `code` (str) — Python source to run in a `paraview.simple`
session.

**Returns:** `returncode` (int), `runner_stdout`, `runner_stderr`,
`pvserver_stdout`, `pvserver_stderr` (all str). `returncode` is `0` on
success, positive for user-code errors, and `-1` for infrastructure failures
(binary not found, spawn error, timeout). See the tool docstring for the full
classification scheme.

**Notes:**

- Each call starts from a blank ParaView session — no shared pipeline state
  between calls.
- The runner subprocess is terminated after a 120-second timeout.
- Both `pvserver` and `pvpython` must be on `PATH` at call time.
- Per-call logs are written to `~/paraview_logs/call_<timestamp>_runner.log`
  and `~/paraview_logs/call_<timestamp>_pvserver.log`.

## Troubleshooting

**Where are the logs?**

| Log                   | Path                                             |
| --------------------- | ------------------------------------------------ |
| Main server log       | `~/paraview_logs/pvpython_renderer_external.log` |
| Per-call runner log   | `~/paraview_logs/call_<timestamp>_runner.log`    |
| Per-call pvserver log | `~/paraview_logs/call_<timestamp>_pvserver.log`  |

Both the directory and all log files are created automatically on first run.
