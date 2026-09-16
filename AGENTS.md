# AGENTS.md

## What this repo is

VisKnacks packages ParaView visualization tooling as **pluggable agent-harness
artifacts**, not as a runnable application. The deliverables are mostly
markdown prompts plus two MCP servers:

- `agents/paraview-prompt-formatter.md` — OpenCode subagent (frontmatter +
  prompt). All tools denied except `question`, by design. Do not grant it more.
- `skills/paraview-coder/` — the primary content. `SKILL.md` + six
  `references/*.md` snippet catalogs. The "Known pitfalls" section of `SKILL.md`
  encodes hard-won pvpython failure modes (unframed camera → blank image,
  leftover `'var0'` array name, volume transfer-function quartets,
  `InsideOut` unreliable, `LowerThreshold`/`UpperThreshold` on 5.10+). Do not
  trim it for brevity.
- `mcp/pvpython-renderer/` — FastMCP server, one tool `execute_code`. The
  `README.md` is accurate; the `pv_mcp.py` module docstring remains the
  source of truth for internals.
- `mcp/pvpython-rag/` — FastMCP server, one tool `query`, over FAISS indexes of
  the ParaView Python API. WIP. The `README.md` (index building, run commands,
  `query` tool) is current; module docstrings remain the source of truth for
  internals.
- `build-scripts/` — assembles the distributable into `build/`.
- `benchmark/` — SciVisAgentBench harness: a local matrix runner
  (`benchmark.bash`) and a one-shot ALCF PBS job
  (`benchmark_visknacks_ollama.bash`). Scripts tracked; `benchmark/data/`,
  `benchmark/results/`, and `benchmark/.opencode/` are gitignored.

Editing agent/skill behavior means editing markdown, not Python.

## Environment

**One conda env for everything**, defined by the root `environment.yaml`
(name `VisKnacks`, python 3.10.20, paraview 5.13.3, faiss 1.14.1, torch,
sentence-transformers).

```bash
make create-dev          # conda env create --file environment.yaml --name VisKnacks
conda activate VisKnacks
pre-commit install       # not done by create-dev
```

`paraview` is conda-only and cannot be pip-installed; it is intentionally
absent from every `pyproject.toml`.

Use `conda activate` (or the env's absolute interpreter). `conda run -n
VisKnacks python ...` resolves to base's python3.13 site-packages on this
machine and fails on `import fastmcp`.

## Stale docs — do not follow

Commit `a3ac0ba` consolidated the per-subproject envs into the root one and
deleted supporting files. The following referenced commands/paths **no longer
exist**; ignore them when the docs mention them:

- `mcp/pvpython-renderer/README.md` was rewritten against the single-env
  layout (commit `a3ac0ba` follow-up); its build/run instructions are current.
- `mcp/pvpython-rag/`: no `Makefile`, no `environment.yaml`. The
  `make clone-paraview` (in `scripts/build_all_indexes.sh`) and
  `make download-benchmark` (in `benchmark/benchmark.bash`) targets do not
  exist — clone/download manually.
- `mcp/pvpython-rag/pvpython_rag.egg-info/` is stale build residue.
- Any mention of the `paraview-mcp` script name: the real console script is
  `pvpython-renderer-mcp`.

## Build

```bash
make build
```

Two stages: `build-scripts/opencode.bash` copies `opencode.json.template`, the
subagent, and the skill into `build/.opencode/`; then `uv build --package` runs
for each MCP server, writing wheels + sdists into the root `dist/`.
`build/` and `dist/` are gitignored. `uv` is pinned inside the conda env
(`uv=0.12.3`), so activate the env before building.

`make install` runs `uv pip install dist/*.tar.gz` into the active env — the
only way the console scripts get onto `PATH` (the PBS benchmark script expects
them there).

Gotcha: `opencode.bash` uses bare `mkdir` (not `-p`) for the `agents`/`skills`
subdirs, so re-running over an existing `build/.opencode` prints errors while
still exiting 0. `rm -rf build/.opencode` first for a clean build.

### uv workspace

The root is a **virtual** workspace root (`[tool.uv] package = false`) with both
MCP servers as members. Always build by package:

```bash
uv build --package pvpython-renderer
uv build --package pvpython-rag
```

Bare `uv build` fails, but not for the reason you would guess: `package = false`
is not honored by `uv build`, which still tries to build the root `visknacks`
project. Because the root declares no `[build-system]`, uv falls back to
setuptools, which rejects the deprecated `License :: OSI Approved :: BSD
License` classifier alongside the PEP 639 `license = "BSD-3-Clause"` expression.
Dropping that one classifier is the fix if bare `uv build` is ever wanted.

Both members use the `uv_build` backend with a **flat layout**, so each needs

```toml
[tool.uv.build-backend]
module-root = ""
```

Without it `uv_build` looks for `src/<module>/__init__.py` and the build fails.

Wheel metadata is **not** inherited from the root. uv workspaces share a
lockfile and resolution environment only — never `[project]` fields.

Both member `pyproject.toml`s declare `dependencies = []`. This is intentional:
the packages are only ever installed into the `VisKnacks` conda env, which
already contains all runtime deps (`fastmcp`, `mcp`, `httpx`, etc.) via
`environment.yaml`. The wheels are not meant for standalone pip installation.

Both console scripts (`pvpython-renderer-mcp`, `pvpython-rag-mcp`) work after
`make install`. `pvpython-rag-mcp` used to point at the index builder
(`pvpython_rag.main:main`) and was fixed to `pvpython_rag.rag_mcp:main`
(commit `dfb0e9c`) — an older installed copy may still be broken, so re-run
`make build && make install` if `--help` misbehaves.

## Lint / format / test

There is **no test suite and no CI**. All quality gates run through
pre-commit only:

```bash
pre-commit run --all-files
```

- ruff (`line-length = 80`); `F403`/`F405` are ignored project-wide because
  `from paraview.simple import *` in `pv_runner.py` is load-bearing. Do not
  "fix" the star import.
- bandit (excludes `tests,build`).
- `prettier` and `skills-ref` hooks are `language: system` — both must already
  be on `PATH`, pre-commit will not install them. The skill validator runs on
  any change under `skills/paraview-coder/`, so the `SKILL.md` frontmatter
  `name:` must keep matching the directory name.
- `no-commit-to-branch` blocks commits to `main`. Branches are named
  `issue-<n>`; `dev` is the integration branch.
- `.editorconfig` says `insert_final_newline = false`, but pre-commit's
  `end-of-file-fixer` adds one. pre-commit wins.

## MCP servers

Both are stateless, streamable-http, single-tool. Ports differ deliberately
(the renderer defaults to 8080, the RAG server to 8081).

The packages are not installed into the `VisKnacks` env by default, so run the
RAG server as a module from its own package directory; the renderer can also
run install-free as a module:

```bash
# from mcp/pvpython-renderer/ (install-free), or `pvpython-renderer-mcp` after `make install`
python -m pvpython_renderer.main --server localhost --port 8080
# from mcp/pvpython-rag/
python -m pvpython_rag.rag_mcp --host localhost --port 8081 \
    --directory data/paraview-vector-db
```

(A stale `paraview-mcp` script from an unrelated upstream package may be on
`PATH` in conda `base`. It is not this project.)

Renderer (`execute_code`):

- Spawns an ephemeral `pvpython` runner + `pvserver` per call in
  **reverse-connection** mode (`pvserver` advertises its system hostname, so a
  forward `Connect("localhost")` deadlocks). Pre-starting your own `pvserver`
  does nothing.
- 120 s per-call timeout; `returncode: -1` means infrastructure failure, user
  code never ran. Logs land in `~/paraview_logs/`.
- Each call is a blank session — multi-step workflows must fit in one `code`
  string.

RAG (`query`):

- `--directory` is required. Indexes are `index_v<ver>.faiss` +
  `metadata_v<ver>.json`; `--pv-version` defaults to `5.13.3`.
- Known inconsistency: `scripts/build_all_indexes.sh` writes to
  `data/vector-db/`, but the shipped/expected index directory is
  `data/paraview-vector-db/`.
- Index building requires CUDA (`device="cuda"`, no CPU fallback);
  `batch_size=1` and `max_seq_length=2048` are deliberate OOM mitigations. The
  server itself loads the model on CPU.
- Queries must carry the `QUERY_PREFIX` instruction string (CodeRankEmbed is
  asymmetric); embedding config in `rag_mcp.py` must stay identical to
  `main.py` or retrieval silently degrades.
- `mcp/pvpython-rag/data/` is gitignored — indexes and the vendored ParaView
  clone are local-only.

## Benchmark

`benchmark/benchmark.bash` runs `opencode run --agent build --auto` for a
matrix of models × tasks, `cd`-ing into `benchmark/` so the gitignored
`benchmark/.opencode/` config (MCP endpoints 8080/8081) is picked up. Keep that
file in sync with `build-scripts/opencode.json.template`.

- Env knobs: `NUM_TASKS=n` (default all), `FORCE=1` (re-run tasks with an
  existing image).
- It deliberately does not `set -e`.
- Destructive: after each model it tars the results, moves them to
  `~/Desktop/MODEL.tar` — a literal fixed filename, so **every model
  overwrites the previous tarball** — then `rm -rf`s `benchmark/results/`.
- `run_metrics.bash` expects ground truth at
  `benchmark/data/<task>/GS/<task>_gs.png`; no `GS/` directories exist in the
  checked-out data, so scoring skips everything until they are supplied.
- `benchmark/metrics.py` imports `imageio` and `skimage`, neither of which is
  listed in `environment.yaml`. A freshly created env cannot run it — install
  `imageio` and `scikit-image` manually.
- `benchmark_visknacks_ollama.bash` is the **one-shot ALCF PBS job** (`qsub`,
  not runnable locally) that folds the whole harness into a single
  submission: it starts both MCP servers and `ollama serve` in-job on
  **dynamic ports**, rewrites `benchmark/.opencode/opencode.json` in place
  (atomic tmp+rename) with those ports, and **fails fast if `OLLAMA_MODEL`
  is not in that config's `provider.ollama.models` allowlist** — adding a
  model means editing that file on Eagle, the script never injects it. Knobs
  via `qsub -v`: `OLLAMA_MODEL`, `PVPYTHON_DATA` (RAG index dir; checked for
  `index_v5.13.3.faiss` + `metadata_v5.13.3.json`), `NUM_TASKS=n|all`,
  `FORCE=1`, `TASK_TIMEOUT=<sec>` (default 3600, `0` disables). It exports
  `OLLAMA_KEEP_ALIVE=24h` and warms the model with one generate call before
  the matrix; the model must already exist in `/eagle/EVITA/ollama-models`
  (the job never pulls). Results land in
  `<RUN_DIR>/results/<model>/<task>/<task>.png` (run_metrics-compatible) and
  the whole `RUN_DIR` is tar-gzipped to
  `~/visknacks-ollama-<model>-<jobid>.tar.gz` both at the end and from the
  EXIT/TERM trap, so a walltime kill still archives. Staging prerequisites:
  `benchmark/data/` + `benchmark/.opencode/` (incl. `node_modules`) on Eagle,
  console scripts installed via `make install`, and `opencode`/`ollama`/
  `pvpython` on `PATH` inside the job.
