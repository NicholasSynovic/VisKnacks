# TODO.ability — Code Quality Review

_Scope: whole repository (VisKnacks). Root config/docs (`README.md`, `Makefile`,
`opencode.json.template`, pre-commit/editorconfig), the two MCP subprojects
(`mcp/pvpython-renderer/`, `mcp/pvpython-rag/`), and the skill/agent artifacts.
Python source read in full for both `mcp/*` packages; skill/agent markdown and
the existing `AGENTS.md`/`TODO.md` reviewed as project conventions. Findings
that overlap with the pre-existing `TODO.md` are noted but re-severitied here._
_Last reviewed: 2026-08-04 08:02_

## Summary

| Ability          | 5 Crit | 4 Maj | 3 Mod | 2 Min | 1 Nag |
| ---------------- | ------ | ----- | ----- | ----- | ----- |
| Accessibility    | 1      | 1     | 0     | 0     | 0     |
| Documentation    | 1      | 1     | 0     | 0     | 0     |
| Maintainability  | 0      | 1     | 2     | 2     | 1     |
| Interpretability | 0      | 0     | 1     | 1     | 0     |
| Interoperability | 0      | 1     | 1     | 0     | 0     |
| Reusability      | 0      | 0     | 1     | 1     | 0     |
| Sustainability   | 0      | 2     | 2     | 0     | 0     |
| Cohesion         | 0      | 1     | 3     | 1     | 0     |

## Accessibility

- [ ] **[S5] Root `README.md` describes a repo layout that no longer exists** — `README.md:26-34,74-81,262`
      Why it matters: the README is the primary entry point for a newcomer, and
      every install/run/usage path it gives is wrong. It points at
      `mcp/renders/paraview/` (actual: `mcp/pvpython-renderer/`), the
      `paraview-mcp` console script with `v1/v2/v3` subcommands (actual:
      `pvpython-renderer-mcp`, single `execute_code` engine, no subcommands),
      the `paraview_mcp` conda env (actual: `pvpython_renderer`), and
      `skills/paraview/SKILL.md` (actual: `skills/paraview-coder/SKILL.md`).
      A new user following it verbatim cannot set up or run anything.
      Suggested fix: rewrite the README to match the real tree — one MCP server
      (`pvpython-renderer`), the `pvpython-rag` sibling, `skills/paraview-coder/`,
      and the actual console-script/env names. `AGENTS.md` already has the
      correct facts to copy from.
- [ ] **[S4] README install commands reference deleted git submodule flow and stale clone URL** — `README.md:62-70`
      Why it matters: `make create-dev` is documented as "git submodule init +
      pre-commit install" but the root `Makefile` target has no recipe (no-op);
      the clone URL is `paraview-agent-harness` while the project is now
      `VisKnacks`. A newcomer wastes time on steps that do nothing.
      Suggested fix: correct the clone URL, document `make create-dev` as a
      no-op (or restore its recipe), and tell users to run `pre-commit install`
      manually — consistent with the note already in `AGENTS.md`.

## Documentation

- [ ] **[S5] README's MCP-server section documents non-existent v1/v2/v3 engines and tools** — `README.md:140-243`
      Why it matters: the entire "MCP server engines" matrix, the 39-tool
      `tools.py` claim, the stdio v1 config, and the Claude Code/Desktop blocks
      describe the upstream `llnl/paraview_mcp` fork, not this repo's single
      `execute_code` streamable-http server (`pv_mcp.py:46,369`). Readers will
      configure tools and transports that do not exist.
      Suggested fix: replace with the single-engine reality; drop the v1/v2
      stdio and tool-count material or clearly mark it as upstream history.
- [ ] **[S4] `mcp/pvpython-rag/README.md` is empty (0 bytes)** — `mcp/pvpython-rag/README.md:1`
      Why it matters: this subproject requires a GPU, a cloned ParaView tree,
      a two-step index build, and a required `--directory` arg to serve; none of
      that is discoverable. `data/` is gitignored, so a fresh clone has no
      indexes and the server exits with `FileNotFoundError`. `pyproject.toml`
      also names it as `readme`, so the package metadata ships an empty readme.
      Suggested fix: document the build (`make clone-paraview` →
      `make create-vector-databases`), the GPU/CUDA requirement, and the
      `pvpython-rag-mcp --directory <dir> [--pv-version ...]` invocation.
- [x] **[S3] `main.py` module docstring names the wrong file and wrong Python floor** — `mcp/pvpython-rag/pvpython_rag/main.py:2`, `mcp/pvpython-rag/pvpython_rag/extract_functions.py:9` _(resolved 2026-08-04)_
      Why it matters: `main.py`'s docstring header said `build_index.py`, and
      `extract_functions.py` claimed "Requires Python 3.13+" while the project
      pins `requires-python = ">=3.10,<3.11"`. Misled maintainers about the
      supported interpreter and file identity.
      Suggested fix: fix the docstring filename to `main.py` and align the
      stated Python version with `pyproject.toml` (3.10). _Done: header now reads
      `main.py`; extractor now states "Requires Python 3.10+"._
- [x] **[S3] `execute_code` return contract does not distinguish failure classes in docs** — `mcp/pvpython-renderer/pvpython_renderer/pv_mcp.py:384-389` _(resolved 2026-08-04)_
      Why it matters: the docstring said `returncode` is `-1` "on
      launch/timeout/internal errors" — the same value for missing binary,
      launch failure, timeout, and internal error. An LLM/tool caller could not
      tell an infra failure from user-code failure except by string-matching
      stderr, which the docs did not describe.
      Suggested fix: document which stderr field carries which failure, or
      (better, see Maintainability) add a distinct status field and document it.
      _Done: docstring now defines `returncode == 0` (user code ok), `> 0`
      (user-code/pvpython failure), and `== -1` (infrastructure failure), and
      enumerates the exact `runner_stderr` messages for each infra class. The
      structured-status-field improvement remains tracked under Maintainability._

## Maintainability

- [ ] **[S4] No tests anywhere; `make test` is a stub across the repo** — `Makefile:25-26`
      Why it matters: the reverse-connection handshake, subprocess
      lifecycle/timeouts (`pv_mcp.py`), version normalization and index
      loading (`rag_mcp.py:132-200`), and the AST extractor
      (`extract_functions.py`) are all non-trivial and entirely unverified.
      The ParaView 5.13.x string-port workaround has no regression guard, so a
      version bump can silently break every call.
      Suggested fix: add unit tests for the pure functions (`_normalize_version`,
      `load_vector_db` error paths, `_extract_source`/`_resolve_module_fqn`) and
      at least one pvpython smoke test; wire a real `make test` target.
- [ ] **[S3] Embedding config duplicated between builder and server with no shared source** — `mcp/pvpython-rag/pvpython_rag/main.py:26,133` vs `mcp/pvpython-rag/pvpython_rag/rag_mcp.py:28-29`
      Why it matters: `EMBEDDING_MODEL_NAME` and `max_seq_length=2048` are
      redeclared in both modules. If the builder's model or sequence length
      changes and the server is not updated in lockstep, query embeddings become
      silently incomparable to stored ones and retrieval quality degrades with
      no error.
      Suggested fix: hoist the model name, sequence length, and normalization
      into one shared constants module imported by both; ideally record the
      model in the metadata sidecar for provenance.
- [ ] **[S3] `execute_code` collapses every failure to `returncode = -1`** — `mcp/pvpython-renderer/pvpython_renderer/pv_mcp.py:397-414,446,551`
      Why it matters: binary-not-found, launch failure, timeout, and internal
      error all return `-1`, so callers and future maintainers cannot branch on
      failure type without brittle stderr parsing.
      Suggested fix: add a `status`/`error_kind` field (e.g.
      `binary_missing`/`launch_failed`/`timeout`/`user_error`) alongside
      `returncode`.
- [ ] **[S2] Tuning constants are hard-coded module literals with no override** — `mcp/pvpython-renderer/pvpython_renderer/pv_mcp.py:59,66,71`
      Why it matters: `SUBPROCESS_TIMEOUT=120`, `RUNNER_READY_TIMEOUT=30`, and
      `CODE_PREVIEW_CHARS=200` cannot be changed without editing source; a
      legitimate long render over 120 s is killed with no user-facing knob.
      Suggested fix: expose the timeouts as CLI/env options with the current
      values as defaults.
- [ ] **[S2] `build_all_indexes.sh` excluded-tags regex is asymmetrically anchored** — `mcp/pvpython-rag/scripts/build_all_indexes.sh:36`
      Why it matters: `'^SALOME_77_EDF_2015_v1|LANL$'` parses as "starts with
      SALOME…" OR "ends with LANL", so it silently filters more tags than the
      two intended, or misses variants — a quiet correctness bug in the build
      matrix.
      Suggested fix: anchor each alternative: `'^SALOME_77_EDF_2015_v1$|^LANL$'`.
- [ ] **[S1] Leftover `echo tag` debug line in the build loop** — `mcp/pvpython-rag/scripts/build_all_indexes.sh:57`
      Why it matters: prints the literal string "tag" on every iteration,
      cluttering build output and suggesting unfinished debugging.
      Suggested fix: delete the line (or make it `echo "$tag"` if a per-tag
      progress line was intended — though line 86 already logs that).

## Interpretability

- [ ] **[S3] `query` tool shadows its parameter name with the module `query` function** — `mcp/pvpython-rag/pvpython_rag/rag_mcp.py:69-70`
      Why it matters: `def query(query: str, ...)` names the parameter the same
      as the function, so inside the body `query` refers to the string while the
      tool is also `query`; a reader (and any recursive/refactor edit) has to
      hold both meanings at once. Minor but avoidable in the project's public
      tool surface.
      Suggested fix: rename the parameter (e.g. `text` or `nl_query`) and keep
      the tool named `query`.
- [ ] **[S2] `main.py` docstring/`prog` identity is inconsistent** — `mcp/pvpython-rag/pvpython_rag/main.py:2,67`
      Why it matters: the file is `main.py`, the docstring header says
      `build_index.py`, and `argparse` `prog="build_index"`. Three names for one
      entry point make it harder to grep and reason about which command a log
      line came from.
      Suggested fix: pick one name; if the CLI should present as `build_index`,
      say so in the docstring and note the module is `main.py` for the
      `python -m pvpython_rag.main` entry.

## Interoperability

- [ ] **[S4] Both MCP servers default to port 8080; they cannot run together** — `mcp/pvpython-renderer/pvpython_renderer/pv_mcp.py:561`, `mcp/pvpython-rag/pvpython_rag/rag_mcp.py:271`, `opencode.json.template:11`
      Why it matters: `opencode.json.template` wires the renderer to
      `localhost:8080`, and `pvpython-rag-mcp` also defaults to 8080. A user who
      wants both retrieval (rag) and rendering active at once gets a bind
      collision, and there is no config that runs both.
      Suggested fix: give rag a distinct default port (e.g. 8081) and add it to
      `opencode.json.template` once it is wired into the harness.
- [ ] **[S3] Transports are streamable-http only; no stdio option** — `mcp/pvpython-renderer/pvpython_renderer/pv_mcp.py:583`, `mcp/pvpython-rag/pvpython_rag/rag_mcp.py:327`
      Why it matters: several MCP clients (Claude Desktop, some IDEs) default to
      stdio. The repo-wide http-only stance limits which clients can consume
      these servers without a proxy.
      Suggested fix: document the http-only decision explicitly, and consider a
      `--transport` flag if broader client support is a goal.

## Reusability

- [ ] **[S3] `rag_mcp.py` holds the model/DB in module-level globals** — `mcp/pvpython-rag/pvpython_rag/rag_mcp.py:64-66,102,314`
      Why it matters: `_VECTOR_DB`/`_MODEL` globals mutated by `run()` and read
      by the `query` tool mean the module cannot be imported and used twice (two
      indexes/versions) in one process, and `query` is not usable as a plain
      library function without the global side effect.
      Suggested fix: encapsulate state in a small server/service object (or
      FastMCP lifespan context) and pass it to the tool, so the retrieval logic
      is reusable independently of the global.
- [ ] **[S2] `extract_functions.py` uses pandas only to pretty-print in `__main__`** — `mcp/pvpython-rag/pvpython_rag/extract_functions.py:16,434-435`
      Why it matters: the library function `extract_functions` is cleanly
      reusable, but the module drags in a heavy `pandas` dependency purely for a
      debug `print(df)` in the CLI block — anyone reusing the module inherits
      the import cost/requirement.
      Suggested fix: drop pandas and print records with the stdlib (json/pprint),
      or move the CLI demo out of the importable module.

## Sustainability

- [ ] **[S4] `mcp/pvpython-rag` under-declares its runtime dependencies** — `mcp/pvpython-rag/pyproject.toml:7-9`
      Why it matters: the code imports `faiss`, `numpy`, `sentence_transformers`
      (`main.py:20-22`, `rag_mcp.py:18-20`) and `pandas`
      (`extract_functions.py:16`), but `dependencies` lists only `fastmcp`. It
      works today only because the conda env happens to provide them; any
      `pip install pvpython-rag` outside that env import-fails. This will bite on
      the next clean install.
      Suggested fix: add the pip-installable deps (`numpy`,
      `sentence-transformers`, `pandas`) and document that `faiss`/CUDA are
      conda-only, mirroring how the renderer documents the `paraview` omission.
- [ ] **[S4] `nomic-ai/CodeRankEmbed` is pulled from HF `main` with no revision pin** — `mcp/pvpython-rag/pvpython_rag/main.py:126-130`, `mcp/pvpython-rag/pvpython_rag/rag_mcp.py:221-225`
      Why it matters: both builder and server load the model unpinned with
      `trust_remote_code=True`. An upstream model update can shift embeddings and
      silently break comparability with already-built indexes (and executes
      remote code). This is a reproducibility and supply-chain risk.
      Suggested fix: pin a model `revision=<commit>` in both call sites and
      record it in the index metadata.
- [ ] **[S3] Dual env/lock systems can drift (`environment.yaml` + `uv.lock` + `pyproject.toml`)** — `mcp/pvpython-rag/pyproject.toml:8`, `mcp/pvpython-renderer/pyproject.toml:23-27`
      Why it matters: `fastmcp`/`mcp`/`httpx` versions live in both conda
      `environment.yaml` and `pyproject.toml`/`uv.lock`; nothing keeps them in
      sync, and `make freeze` relies on manual post-editing (self-exclusion,
      channel ordering), which is error-prone.
      Suggested fix: designate one source of truth for the pip-installable pins
      and derive/verify the other; automate the `freeze` post-edit.
- [ ] **[S3] No CI; all quality gates depend on a local pre-commit run** — `.pre-commit-config.yaml:1`, `Makefile:25`
      Why it matters: `no-commit-to-branch`, ruff, bandit, and prettier only run
      if a contributor runs `pre-commit` locally (and prettier must be on PATH
      via `language: system`). Nothing enforces them on push/PR, so drift like
      the stale README accumulates unchecked.
      Suggested fix: add a CI workflow that runs `pre-commit run --all-files`
      (with prettier installed) on PRs.

## Cohesion

- [ ] **[S4] `pvpython-rag` diverges from the renderer's established project patterns** — `mcp/pvpython-rag/pvpython_rag/rag_mcp.py:316,320`, `mcp/pvpython-rag/pyproject.toml:1-16`
      Why it matters: the renderer sets the house style — split modules
      (`cli`/`main`/`logger`/`prompts`/`pv_mcp`), a `logger.py` writing to
      `~/paraview_logs/`, `hatchling` build backend, full `pyproject` metadata,
      and `__init__` version constants. rag instead uses `print(..., stderr)`
      instead of a logger, crams everything into one `rag_mcp.py`, uses
      `setuptools`, and ships placeholder metadata. This inconsistency makes the
      two siblings feel like different projects and complicates shared tooling.
      Suggested fix: converge rag on the renderer's layout/logging/build backend,
      or explicitly document the intentional single-file choice.
- [ ] **[S3] `pvpython-rag` placeholder package metadata vs. the renderer's populated metadata** — `mcp/pvpython-rag/pyproject.toml:3-4`
      Why it matters: `version = "0.1.0"`, `description = "Add your description
    here"`, and no authors/license/urls/classifiers, while the renderer has
      all of them. Ships meaningless metadata and no license for a package that
      sits beside a BSD-licensed sibling.
      Suggested fix: fill in description/authors/license/urls to match the
      renderer's `pyproject.toml`.
- [ ] **[S3] rag build output dir vs. documented serve dir naming drift** — `mcp/pvpython-rag/scripts/build_all_indexes.sh:32`, `mcp/pvpython-rag/Makefile:20-22`, `AGENTS.md`/`TODO.md`
      Why it matters: the build writes indexes to `data/vector-db/`, while
      earlier docs/`TODO.md` reference `data/paraview-vector-db/` as the serve
      location. The current `rag_mcp.py` takes `--directory` as a required arg
      (so it can serve either), but the docs still carry the old fixed path,
      leaving readers unsure where indexes must live.
      Suggested fix: standardize on `data/vector-db/` in all docs, or document
      that `--directory` must point at wherever the build wrote them.
- [ ] **[S2] `skills/README.md` points at the nonexistent `skills/paraview/references/` path** — `README.md:28,262,296`
      Why it matters: the root README (and, per `TODO.md`, `skills/README.md`)
      still reference `skills/paraview/`, but the real directory is
      `skills/paraview-coder/`. Readers cannot find the six reference files;
      this is the exact stale path `AGENTS.md` warns about.
      Suggested fix: sweep all docs for `skills/paraview/` and replace with
      `skills/paraview-coder/`.

## Review log

- 2026-08-04 08:02 — initial whole-repo review. 8 abilities checked;
  20 findings recorded (1×S5 accessibility, 1×S5 documentation, plus major/
  moderate items across all abilities). Highest-signal issue: the root
  `README.md` describes a superseded repo layout end-to-end. Several items
  overlap the existing `TODO.md` MCP review; recorded here under the ability
  framing with `path:line` anchors.
- 2026-08-04 08:20 — resolved 2 Documentation findings (both S3): fixed the
  `main.py`/`extract_functions.py` docstring file name and Python-floor claims,
  and rewrote the `execute_code` return-contract docstring to distinguish
  user-code vs. infrastructure failures with per-message classification.
  0 new, 2 resolved. Documentation open findings now: 1×S5, 1×S4.
