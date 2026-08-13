# pvpython-renderer

> FastMCP server exposing headless ParaView rendering as a stateless MCP tool
> for LLM-driven visualization pipelines

## About

ParaView is an open-source platform for large-scale scientific visualization
whose headless binaries — `pvpython` and `pvserver` — allow rendering pipelines
to run without a display against arbitrarily large simulation datasets.
`pvpython-renderer` wraps those binaries as a single-tool MCP service: each
call to `execute_code` spawns a fresh, isolated ParaView session, runs the
supplied `paraview.simple` code, captures all output, and tears the session
down — returning `returncode`, stdout, and stderr to the agent for iterative
refinement, without transferring the underlying dataset off the host system.

## Table of Contents

- [pvpython-renderer](#pvpython-renderer)
    - [About](#about)
    - [Table of Contents](#table-of-contents)
    - [Application Overview](#application-overview)
    - [How to Build](#how-to-build)
        - [Development environment](#development-environment)
        - [Wheel](#wheel)
    - [How to Run](#how-to-run)
    - [MCP Tool Reference](#mcp-tool-reference)
        - [`execute_code`](#execute_code)
    - [Troubleshooting](#troubleshooting)

## Application Overview

Each call to `execute_code` goes through the following lifecycle, entirely
within the MCP server process:

The server first resolves `pvpython` and `pvserver` on `PATH` via
`shutil.which`. If either binary is missing, the call returns immediately with
`returncode: -1` and an explanatory message in `runner_stderr` — no ParaView
process is started.

The server then selects an ephemeral free TCP port on `localhost`. It spawns
`pv_runner.py` as a subprocess under `pvpython --force-offscreen-rendering`.
The runner opens a reverse-connection listening socket on that port by calling
`ReverseConnect(port)` from `paraview.simple`, then waits for the server to
dial back. The runner must be started first because it is the listener in
reverse-connection mode.

Once the runner's listening socket is confirmed open (detected by a readiness
banner on its stdout), `pvserver` is launched with `--reverse-connection
--client-host=localhost --server-port=<port>`. The server dials back to the
runner, completing the ParaView client–server session.

The runner then `exec`s the user-supplied code inside the live
`paraview.simple` session. When the code finishes (or the 120-second timeout
expires), the runner exits. The MCP server terminates both subprocesses,
collects their stdout and stderr, writes per-call log files, and returns the
result dict to the MCP client.

**Why reverse-connection?** `pvserver` advertises its system hostname — not
`localhost` — when binding. A conventional forward `Connect("localhost")` from
the runner is refused for the entirety of ParaView's internal connect-retry
window, deadlocking every call. In reverse mode the runner listens on
`localhost` and instructs `pvserver` to dial back there, sidestepping the
hostname mismatch entirely.

**Stateless per-call design.** Each call starts from a blank ParaView session.
No pipeline state is shared between calls. Any multi-step workflow must be
expressed within a single `code` string.

## How to Build

### Development environment

The runtime for this component is a conda environment — not a plain Python
virtualenv — because `paraview` is only installable via conda (`conda-forge`)
and cannot be pip-installed. The pinned `paraview=5.13.3=py310_...` package
fixes both the ParaView version and the Python interpreter (3.10) for the
entire environment.

From `mcp/pvpython-renderer/`, run:

```bash
make create-dev
conda activate pvpython_renderer
```

`make create-dev` performs three steps: creates or updates the
`pvpython_renderer` conda environment from `environment.yaml`, installs the
git pre-commit hooks, and runs `uv sync --group dev` to install the dev
dependency group (ruff, pre-commit, uv). The `paraview` package is provided
by conda and is intentionally absent from `pyproject.toml`.

### Wheel

To build a distributable wheel from `mcp/pvpython-renderer/`:

```bash
conda activate pvpython_renderer
uv build
```

The wheel is written to `dist/`. It contains only the `pvpython_renderer`
Python package; `pvpython` and `pvserver` are not bundled and must be provided
by the conda environment at runtime. Install the wheel into an environment that
already has `paraview` available via conda:

```bash
uv pip install dist/pvpython_renderer-*.whl
```

## How to Run

Activate the conda environment, then start the server:

```bash
conda activate pvpython_renderer
pvpython-renderer-mcp --server localhost --port 8080
```

The MCP endpoint is served at `http://<server>:<port>/mcp`. With the defaults
above that is `http://localhost:8080/mcp`.

`--server` (default `localhost`) sets the bind hostname for the streamable-http
transport. `--port` (default `8080`) sets the bind port. Both `pvpython` and
`pvserver` must be on `PATH` at call time; activating the `pvpython_renderer`
conda environment satisfies this requirement.

## MCP Tool Reference

### `execute_code`

Run arbitrary `paraview.simple` Python code in a fresh, stateless session.

```
execute_code(code: str) -> dict
```

**Arguments**

| Name   | Type | Required | Description                                         |
| ------ | ---- | -------- | --------------------------------------------------- |
| `code` | str  | yes      | Python source to run in a `paraview.simple` session |

**Returns**

| Key               | Type | Description                                    |
| ----------------- | ---- | ---------------------------------------------- |
| `returncode`      | int  | Exit code; see classification table below      |
| `runner_stdout`   | str  | stdout captured from the `pvpython` subprocess |
| `runner_stderr`   | str  | stderr captured from the `pvpython` subprocess |
| `pvserver_stdout` | str  | stdout captured from the `pvserver` subprocess |
| `pvserver_stderr` | str  | stderr captured from the `pvserver` subprocess |

**Return code classification**

| `returncode` | Meaning                                                                                        |
| ------------ | ---------------------------------------------------------------------------------------------- |
| `0`          | User code ran to completion without raising an exception                                       |
| `> 0`        | User code or `pvpython` itself exited with an error; inspect `runner_stderr` for the traceback |
| `-1`         | Infrastructure failure; user code never ran; see `runner_stderr` for the sub-case              |

Infrastructure failure sub-cases (`returncode == -1`):

| `runner_stderr` content                    | Cause                                               |
| ------------------------------------------ | --------------------------------------------------- |
| `"pvpython not found on PATH"`             | `pvpython` binary missing; conda env not activated  |
| `"pvserver not found on PATH"`             | `pvserver` binary missing; conda env not activated  |
| `"Error launching pv_runner: ..."`         | Subprocess could not be spawned                     |
| `"Error launching pvserver: ..."`          | `pvserver` could not be spawned                     |
| `"Subprocess timed out after 120 seconds"` | User code exceeded the 120-second execution timeout |
| `"Error running pv_runner.py: ..."`        | Internal error while awaiting the runner            |

**Notes**

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

**Common failures**

`pvpython` or `pvserver` not found on PATH. The conda environment is not
activated. Run `conda activate pvpython_renderer` before starting the server
or making calls.

`returncode: -1` with `"Subprocess timed out after 120 seconds"` in
`runner_stderr`. The user code exceeded the per-call execution limit. Simplify
the pipeline or split long operations across multiple calls.

Blank or solid-black output image with `returncode: 0`. The pipeline ran
without error but produced an empty render. Common causes: camera not framed
to the data bounds, volume rendering transfer function not fully configured, or
a `Threshold` filter that excluded all data. The `paraview-coder` skill
encodes mitigations for each of these.

Manual `pvserver` pre-start has no effect. `pvpython-renderer` spawns and
tears down its own `pvserver` instance per call in reverse-connection mode. A
separately running `pvserver` will not be used and should not be started.
