<!-- prettier-ignore -->
<div align="center">

# pvpython-renderer

> FastMCP server exposing headless ParaView rendering as a stateless MCP tool
> for LLM-driven visualization pipelines

[![License](../../docs/license_badge.svg)](../../LICENSE)
![Python](https://img.shields.io/badge/Python-%3E%3D3.10-3776AB?style=flat-square&logo=python&logoColor=white)
![ParaView](https://img.shields.io/badge/ParaView-5.13.3-8A2BE2?style=flat-square)

[About](#about) • [Application Overview](#application-overview) • [How to
Build](#how-to-build) • [How to Run](#how-to-run) • [MCP Tool
Reference](#mcp-tool-reference) • [Troubleshooting](#troubleshooting)

</div>

## About

ParaView is an open-source platform for large-scale scientific visualization
whose headless binaries — `pvpython` and `pvserver` — allow rendering pipelines
to run without a display against arbitrarily large simulation datasets.
`pvpython-renderer` wraps those binaries as a single-tool MCP service: each
call to `execute_code` spawns a fresh, isolated ParaView session, runs the
supplied `paraview.simple` code, captures all output, and tears the session
down — returning `returncode`, stdout, and stderr to the agent for iterative
refinement, without transferring the underlying dataset off the host system.

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
and cannot be pip-installed. The repository uses a single conda environment
(`VisKnacks`, Python 3.10, ParaView 5.13.3) for every component. From the
repository root, run:

```bash
make create-dev
conda activate VisKnacks
```

`make create-dev` creates the `VisKnacks` conda environment from the root
`environment.yaml`. The `paraview` package is provided by conda and is
intentionally absent from `pyproject.toml`; likewise, this package declares no
pip dependencies because its runtime requirements (`fastmcp`, `mcp`, and
friends) are installed by `environment.yaml`.

### Wheel

To build a distributable wheel, run from the repository root (uv is pinned
inside the conda environment, so activate it first):

```bash
make build
```

This builds wheels for both MCP services into the root `dist/`. To build only
this package:

```bash
uv build --package pvpython-renderer
```

The wheel contains only the `pvpython_renderer` Python package; `pvpython` and
`pvserver` are not bundled and must be provided by the conda environment at
runtime. Optionally install the built distributions into the active
environment:

```bash
make install
```

## How to Run

> [!WARNING]
> Both packaged entrypoints are currently broken. The `pvpython-renderer-mcp`
> console script points at `pvpython_renderer.main:main`, a module that no
> longer exists, and `python -m pvpython_renderer.mcp.main` crashes with
> `PackageNotFoundError` when the package is not installed as a distribution —
> and registers no tools even when it is. Start the server through the
> `pv_mcp` engine instead.

Activate the conda environment, then start the server from this directory:

```bash
cd mcp/pvpython-renderer
conda activate VisKnacks
python -c "from pvpython_renderer.pv_mcp import run; run('localhost', 8080)"
```

`run()` accepts the bind hostname and port as arguments
(`run(mcp_server, mcp_port)`, defaulting to `localhost` and `8080`). The MCP
endpoint is served at `http://<server>:<port>/mcp` — with the defaults above,
`http://localhost:8080/mcp`.

Both `pvpython` and `pvserver` must be on `PATH` at call time; activating the
`VisKnacks` conda environment satisfies this requirement. The service is
Linux-64 only.

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

## Resources

- [Repository root README](../../README.md) — the surrounding VisKnacks
  system: subagent, agent skill, and the RAG MCP service.
- Referenced by DOI
  [10.48550/arXiv.2505.07064](https://doi.org/10.48550/arXiv.2505.07064).

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
activated. Run `conda activate VisKnacks` before starting the server or making
calls.

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

## License

This project is licensed under BSD-3-Clause. See [LICENSE](../../LICENSE) for
more details.
