# VisKnacks

> OpenCode-compatible scientific visualization agent tooling for ParaView.

## Table of Contents

- [About](#about)
- [Demo](#demo)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Contributing](#contributing)
- [License](#license)
- [Citation](#citation)

## About

VisKnacks is a packaging harness for **SciVisAgent** — an OpenCode-compatible
agent system that lets LLMs drive [ParaView](https://www.paraview.org/)
scientific visualization pipelines. It is not a runnable Python application;
it assembles distributable OpenCode artifacts and an MCP server from prose
and configuration.

The system has three layers:

| Layer             | Artifact                                 | What it does                                                                                |
| ----------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------- |
| OpenCode skill    | `skills/paraview/` (`paraview-coder`)    | Generates complete `pvpython` scripts from natural-language requests                        |
| OpenCode subagent | `agents/paraview-prompt-formatter.md`    | Converts vague requests into structured ParaView prompts (Step 0 of every skill invocation) |
| MCP server        | `mcp/renders/paraview/` (`paraview-mcp`) | Exposes `paraview.simple` operations as typed MCP tools; three engine versions (v1/v2/v3)   |

`make build` assembles these into `build/.opencode/` for distribution. The
MCP server is a fork of
[llnl/paraview_mcp](https://github.com/llnl/paraview_mcp).

**Supported visualization tasks** (via the `paraview-coder` skill): isosurface
contours, slices, clips, volume rendering, glyphs/vector arrows, streamlines,
stream tubes, threshold filters, warp-by-vector, plot-over-line, color maps
with scalar bars, multi-view layouts, animations, and headless screenshot
export. Handles `.vtk`, `.vtu`, `.vtp`, `.vtr`, `.ex2`/Exodus, `.vtm`, `.csv`,
`.nc`, and RAW volume files.

## Demo

_Placeholder — screenshot or GIF coming soon._

## Installation

### Prerequisites

- **Conda** — `paraview` cannot be pip-installed; it is conda-only.
- **`prettier` on PATH** — the root pre-commit config uses
  `language: system` and calls `prettier` directly. Install via your system
  package manager or `npm install -g prettier`.
- **OpenCode** — required to use the skill and subagent.
- **`hf` CLI** (`huggingface_hub`) — required only for
  `make download-benchmark`.

### Root harness (lint / build)

```bash
git clone git@github.com:NicholasSynovic/paraview-agent-harness.git
cd paraview-agent-harness
make create-dev                        # git submodule init + pre-commit install
conda env create -f environment.yml    # env: paraview-agent-harness, python 3.14, paraview 6.1.1
conda activate paraview-agent-harness
```

> `make create-dev` does **not** create the conda environment — run the
> `conda env create` step separately.

### MCP server

The MCP server lives in `mcp/renders/paraview/` and uses its own environment.

```bash
cd mcp/renders/paraview
make create-dev           # creates paraview_mcp conda env, installs dev deps
conda activate paraview_mcp
pip install -e .          # registers the 'paraview-mcp' console script
```

Two separate conda environments coexist in this repo:

|          | Root harness             | MCP server                              |
| -------- | ------------------------ | --------------------------------------- |
| Config   | `environment.yml`        | `mcp/renders/paraview/environment.yaml` |
| Env name | `paraview-agent-harness` | `paraview_mcp`                          |
| Python   | 3.14                     | 3.10                                    |
| ParaView | 6.1.1                    | 5.13.3                                  |
| Purpose  | Lint / build             | MCP server runtime                      |

### Build OpenCode artifacts

```bash
make build
# Copies agents/ and skills/ into build/.opencode/
# Copies opencode.json.template to build/.opencode/opencode.json
```

> **Known breakage:** the `uv build` step in the root Makefile references
> `mcp/paraview-exec-mcp` (a stale path). The artifact copy steps succeed;
> only the MCP wheel build step fails. To build the wheel directly:
>
> ```bash
> cd mcp/renders/paraview && make build
> ```

## Configuration

### OpenCode

After running `make build`, copy or symlink the generated config into your
project:

```bash
cp build/.opencode/opencode.json .opencode/opencode.json
```

Or use the template directly:

```jsonc
// .opencode/opencode.json
{
    "$schema": "https://opencode.ai/config.json",
    "mcp": {
        "paraview-exec": {
            "type": "remote",
            "url": "http://localhost:8080/mcp",
            "enabled": true,
            "timeout": 150000,
        },
    },
}
```

This points to the v3 MCP server (recommended). The server must be running
before starting OpenCode.

### MCP server engines

Three engine versions are available. Run only one at a time on port 8080.

|                       | v1                       | v2                      | v3                   |
| --------------------- | ------------------------ | ----------------------- | -------------------- |
| Transport             | stdio                    | streamable-http         | streamable-http      |
| Tools                 | 39 (`tools.py`)          | 39 (`tools.py`)         | 1 (`execute_code`)   |
| pvserver lifecycle    | External (manual)        | External (manual)       | Per-call (automatic) |
| ParaView GUI required | Yes                      | Yes                     | No                   |
| OpenCode config type  | `"local"`                | `"remote"`              | `"remote"`           |
| Recommended for       | Interactive GUI sessions | Persistent HTTP clients | Headless / CI use    |

**v1 — stdio**

```bash
pvserver --multi-clients --server-port=11111 &   # start pvserver first
paraview-mcp v1 --paraview-server localhost --paraview-port 11111
```

OpenCode config:

```json
{
    "mcp": {
        "paraview": {
            "type": "local",
            "command": [
                "paraview-mcp",
                "v1",
                "--paraview-server",
                "localhost",
                "--paraview-port",
                "11111"
            ],
            "enabled": true
        }
    }
}
```

**v2 — streamable-http**

```bash
pvserver --multi-clients --server-port=11111 &
paraview-mcp v2 --paraview-server localhost --paraview-port 11111 \
    --server localhost --port 8080
```

OpenCode config: same as the v3 block below but point `enabled: true` at `paraview-v2`.

**v3 — stateless, no manual pvserver needed (recommended)**

```bash
paraview-mcp v3 --server localhost --port 8080
```

Spawns a fresh `pvserver --reverse-connection` per `execute_code` call and
tears it down after. No persistent ParaView session; no GUI required.

> v3 uses **reverse-connection** mode. Do not try to connect to it with
> `pvserver --multi-clients --server-port=11111` — that is the v1/v2 pattern
> and will not work for v3.

Logs: `~/paraview_logs/paraview_mcp_external.log` and per-call
`~/paraview_logs/call_<timestamp>_runner.log`.

### Claude Code

```json
{
    "mcpServers": {
        "paraview": {
            "command": "paraview-mcp",
            "args": [
                "v1",
                "--paraview-server",
                "localhost",
                "--paraview-port",
                "11111"
            ]
        }
    }
}
```

### Claude Desktop

```json
{
    "mcpServers": {
        "ParaView": {
            "command": "paraview-mcp",
            "args": [
                "v1",
                "--paraview-server",
                "localhost",
                "--paraview-port",
                "11111"
            ]
        }
    }
}
```

## Usage

### Starting the MCP server

```bash
conda activate paraview_mcp
paraview-mcp v3 --server localhost --port 8080
```

Then start OpenCode in a directory containing a configured `.opencode/opencode.json`.

### Using the OpenCode skill

Invoke the `paraview-coder` skill from within OpenCode. The skill
automatically calls the `paraview-prompt-formatter` subagent as a first step
to resolve any missing file paths or ambiguous terms before generating code.

See [`skills/paraview/SKILL.md`](skills/paraview/SKILL.md) for the full
workflow, supported file formats, filter catalog, and pvpython gotchas.

### Benchmark

```bash
make download-benchmark   # requires hf (huggingface_hub) CLI on PATH
# downloads SciVisAgentBench dataset into benchmark/scivisagentbench/
```

The benchmark evaluates generated screenshots against ground truth using
**PSNR** and **SSIM** (via scikit-image). Four local datasets (bonsai, carp,
engine, tornado) ship as tasks in `benchmark/data/`; the full 37+ volume
SciVisAgentBench suite is downloaded on demand.

## Contributing

- Work on a named branch — `no-commit-to-branch` in pre-commit **blocks all
  commits directly to `main`**.
- Fork the repo, branch off `main`, and open a pull request.
- Run `pre-commit run --all-files` before pushing. Requires `prettier` on PATH.
- Use imperative commit messages (e.g., `Adds X`, `Fixes Y`).
- `make test` is a stub — no automated test suite exists yet.

## License

This repository is licensed under the
[BSD 3-Clause License](LICENSE) (Copyright © 2026 Nicholas Synovic).

The MCP server sub-project (`mcp/renders/paraview/`) is a fork of
[llnl/paraview_mcp](https://github.com/llnl/paraview_mcp), licensed under
the BSD 3-Clause License (Copyright © 2018 Lawrence Livermore National
Security, LLC).

The skill content (`skills/paraview/`) carries a proprietary license as part
of the ChatVis research artifact.

## Citation

If you use VisKnacks or the underlying `paraview-mcp` server in your research,
please cite the upstream paper:

> S. Liu, H. Miao, and P.-T. Bremer, "Paraview-MCP: Autonomous Visualization
> Agents with Direct Tool Use," in _Proc. IEEE VIS 2025 Short Papers_, 2025.
> DOI: [10.48550/arXiv.2505.07064](https://doi.org/10.48550/arXiv.2505.07064)

```bibtex
@inproceedings{liu2025paraview,
    title     = {Paraview-MCP: Autonomous Visualization Agents with Direct Tool Use},
    author    = {Liu, S. and Miao, H. and Bremer, P.-T.},
    booktitle = {Proc. IEEE VIS 2025 Short Papers},
    pages     = {00},
    year      = {2025},
    organization = {IEEE}
}
```
