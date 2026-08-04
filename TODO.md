# TODO — MCP services

Review of the MCP services under `mcp/` covering implementation, deployment,
maintainability, sustainability, reproducibility, and interoperability.
Severity: **High** = blocks correct deployment/use, **Medium** = important
but not blocking, **Low** = polish.

# pvpython-rag (`mcp/pvpython-rag/`)

## Outstanding tasks (implementation & deployment)

- [ ] **[High] Under-declared dependencies in `pyproject.toml`.** Declared
      deps are `fastmcp` only, but the runtime imports `faiss`, `numpy`, and
      `sentence_transformers` (`main.py` uses them too). It works today only
      because the conda env provides them; `pip install pvpython-rag` outside
      that env would import-fail. `faiss` and `torch`/CUDA are conda-only
      (like `paraview` in the renderer), so either add the pip-installable
      ones (`numpy`, `sentence-transformers`) or explicitly comment why each
      is omitted, and document conda as the runtime.
- [ ] **[High] Port collision with the renderer.** `opencode.json.template`
      wires `pvpython-renderer-mcp` to `http://localhost:8080/mcp`, and rag
      also defaults to `8080`; both cannot run at once. Pick a distinct
      default port for rag.
- [ ] **[High] rag service is not wired into the harness.** It is not
      referenced in `opencode.json.template` or the root `Makefile`, so it is
      not deployable into the OpenCode harness yet.
- [ ] **[High] Data directory naming mismatch breaks the build flow.** The
      Makefile `create-vector-databases` target and `build_all_indexes.sh`
      write to `data/vector-db/`, but the committed indexes the server loads
      live in `data/paraview-vector-db/`. Build output location != serve
      location; re-running the build won't produce files where the server
      expects them. Standardize on one directory name.
- [ ] **[Medium] `build_all_indexes.sh` bugs.**
    - [ ] Line 57: `echo tag` — leftover debug line printing the literal
          string "tag" every iteration; remove it.
    - [ ] Line 36:
          `EXCLUDED_TAGS_PATTERN='^SALOME_77_EDF_2015_v1|LANL$'` —
          asymmetric anchoring; the `|` splits into "starts with SALOME…" OR
          "ends with LANL", matching more than intended. Likely should be
          `^SALOME_77_EDF_2015_v1$|^LANL$`.
- [ ] **[Medium] `.python-version` says `3.14` but the project is Python
      3.10** (`requires-python = ">=3.10,<3.11"`, conda env is 3.10, all
      `X | None` syntax targets 3.10). The stray file will mislead
      `uv`/pyenv and onboarding.
- [ ] **[Medium] Empty `README.md`.** Zero bytes. No run instructions, no
      data-acquisition story, no note that `data/` is gitignored (so a fresh
      clone has no indexes and the server won't start).
- [ ] **[Medium] `pyproject.toml` metadata placeholders.**
      `description = "Add your description here"`, `version = "0.1.0"`, no
      authors/license/urls/classifiers (the renderer has all of these). Also
      uses `setuptools` while the renderer uses `hatchling` — inconsistent
      build backend across the sibling MCP projects.

## Maintainability

- [ ] Divergent structure from the renderer. The renderer splits concerns
      (`cli.py`, `main.py`, `logger.py`, `prompts.py`, `pv_mcp.py`); rag puts
      everything (`cli`, `run`, `main`, tool, loaders) in one `rag_mcp.py`.
      Decide: converge on the renderer's layout, or explicitly keep rag
      single-file.
- [ ] `print(..., file=sys.stderr)` instead of a logger. The renderer has a
      `logger.py` writing to `~/paraview_logs/`. rag uses ad-hoc prints: no
      structured logging, no log file, no per-request logging of
      queries/latency.
- [ ] No FastMCP `instructions`/prompt. The renderer passes
      `instructions=default_prompt` so clients know how to use the tool.
      rag's `FastMCP("pvpython-rag")` has none — an LLM client gets no
      guidance on what `query` is for or that it is ParaView-version-specific.
- [ ] No `__init__.py` metadata (`__version__`, etc.) unlike the renderer.

## Sustainability / correctness

- [ ] **[Medium] Hardcoded `device="cuda"` with no fallback in the server.**
      Matches the builder deliberately, but serving is a different use case
      than a batch build — CPU inference is viable (slow but works) and would
      widen where this can run. At minimum document the choice; ideally add a
      `--device` flag defaulting to `cuda`.
- [ ] Embedding-config drift risk. `EMBEDDING_MODEL_NAME`,
      `MODEL_MAX_SEQ_LENGTH`, and normalization are duplicated as constants in
      both `main.py` and `rag_mcp.py`. If the builder's model changes, the
      server must change in lockstep or retrieval silently breaks. No shared
      module, and nothing records which model built a given index (metadata
      JSON has no provenance header).
- [ ] No model pinning. `nomic-ai/CodeRankEmbed` is pulled from HF at `main`;
      no revision/commit hash pinned, so an upstream model update could shift
      embeddings and break comparability with prebuilt indexes.

## Reproducibility

- [ ] **[Medium] `data/` is entirely gitignored with no acquisition path for
      the serve indexes.** `make clone-paraview` + `make create-vector-databases`
      rebuilds from scratch (GPU + hours) but writes to `data/vector-db/`, not
      `data/paraview-vector-db/`. There is no `make download` for prebuilt
      indexes and no documented provenance. A new machine cannot reproduce a
      running server without a GPU rebuild plus a manual dir rename.
- [ ] Two lockfile/env systems (`environment.yaml` conda + `uv.lock`) with the
      fastmcp version duplicated across both — they can drift.
- [ ] `freeze` target relies on manual post-editing (channels/self-exclusion),
      which is error-prone.

## Interoperability

- [ ] Transport is streamable-http only, no stdio. Many MCP clients (Claude
      Desktop, some IDEs) expect stdio. The renderer is also http-only, so
      this is a repo-wide stance, but worth noting for broader client support.
- [ ] Single fixed ParaView version per process. The server loads exactly one
      version at startup; a caller wanting a different version needs a second
      process on a different port. No per-query version selection or
      multi-index support.
- [ ] No tests. No unit tests for `_normalize_version`, `load_vector_db` error
      paths, or `query` edge cases (only inline doctests on `cli`). `make test`
      does not exist here.

## Suggested prioritization

- **Must-fix before deployment:** dependencies, port + harness wiring, data
  directory mismatch.
- **High-value, low-effort:** script bugs, `.python-version`, README,
  pyproject metadata.
- **Strategic:** shared embedding-config module + index provenance,
  `--device` flag, logger, FastMCP instructions, tests, prebuilt-index
  acquisition path.

# pvpython-renderer (`mcp/pvpython-renderer/`)

The renderer is the more mature sibling (real `README.md`, `logger.py`,
split module layout, populated `pyproject.toml`, per-call logging). Most
issues are documentation drift and packaging hygiene rather than missing
functionality.

## Outstanding tasks (implementation & deployment)

- [ ] **[High] README documents the wrong console-script name, env name, and
      clone URL.** `README.md` refers to the `paraview-mcp` console script,
      the `paraview_mcp` conda env, and `git clone .../paraview_mcp.git`
      throughout (install, run, dev sections). The actual script is
      `pvpython-renderer-mcp` (`pyproject.toml` `[project.scripts]`), the env
      is `pvpython_renderer` (Makefile/`environment.yaml`), and the repo is
      `VisKnacks`. `AGENTS.md` already flags the script-name staleness but the
      README was never fixed. Following the README verbatim fails.
- [ ] **[High] README links to files that do not exist.** It references
      `./opencode.json` ("This repository ships a ready-to-use opencode.json")
      and `./LICENSE` ("See LICENSE for the full text"); neither file exists
      in `mcp/pvpython-renderer/`. Either add the files or fix the references.
- [ ] **[Medium] OpenCode config key mismatch.** The root
      `opencode.json.template` registers the server under the key
      `pvpython-renderer-mcp`, but the README's example `mcp` block uses the
      key `paraview`. Pick one and make them consistent.
- [ ] **[Medium] `dist/` is committed / not ignored.** There is no
      `.gitignore` in `mcp/pvpython-renderer/` (rag has one), and `dist/` is
      not ignored, so build artifacts can be accidentally committed. Add a
      `.gitignore` covering `dist/`, `.venv/`, `.ruff_cache/`,
      `*.egg-info/`.

## Documentation drift (README vs. actual config)

- [ ] README claims prettier requires [`bun`](https://bun.sh) on `PATH`, but
      `.pre-commit-config.yaml` runs prettier as `language: system` — it must
      be a `prettier` binary on `PATH`, not bun. (rag's `AGENTS.md` states the
      system-prettier requirement correctly.)
- [ ] README says `make create-dev` "installs the git pre-commit hooks," but
      the renderer `Makefile` `create-dev` target only does conda env
      create/update + `uv sync --group dev` + `uv pip install -e .`; it does
      **not** run `pre-commit install`. Either add the step or fix the docs.
- [ ] README mixes the env name in commands (`conda env create ... -n
paraview_mcp`) while the Makefile and `environment.yaml` use
      `pvpython_renderer`. Same root cause as the console-script drift; sweep
      the whole README for the stale name.

## Maintainability

- [ ] No `.gitignore` (see above) — caches (`.ruff_cache/`, `.venv/`) and
      build output (`dist/`) are untracked only by luck.
- [ ] Tuning constants (`SUBPROCESS_TIMEOUT=120`, `RUNNER_READY_TIMEOUT=30`,
      `CODE_PREVIEW_CHARS=200`) are module-level literals in `pv_mcp.py` with
      no CLI/env override. A long render that legitimately exceeds 120 s is
      killed with no way to raise the limit without editing source.
- [ ] `execute_code` returns `returncode = -1` for every failure class
      (binary-not-found, launch failure, timeout, internal error). Callers
      cannot distinguish a user-code error from an infrastructure failure
      except by string-matching stderr. Consider distinct codes or a status
      field.

## Sustainability / correctness

- [ ] **[Medium] `execute_code` runs `exec(args.code)` on arbitrary input**
      (`pv_runner.py`, `# nosec B102`). This is the intended mechanism, but it
      is unsandboxed arbitrary code execution on the host. Fine for a trusted
      local LLM client; a real risk if the MCP endpoint is ever exposed
      beyond `localhost`. Document the trust boundary explicitly and keep the
      bind host defaulted to `localhost`.
- [ ] Per-call subprocess model spawns a fresh `pvpython` runner **and** a
      fresh `pvserver` for every `execute_code` call, with a 30 s readiness
      wait. This is deliberate (statelessness) but expensive; heavy multi-step
      workflows pay full startup cost each call and must be crammed into one
      `code` string. Note the tradeoff; revisit only if latency becomes a
      problem.
- [ ] Version coupling to ParaView 5.13.x. `ReverseConnect(str(port))` works
      around a 5.13.x int-port bug, and the reverse-connection approach is
      tied to observed `pvserver` hostname-advertisement behavior. Neither is
      version-guarded; a ParaView upgrade could silently change the handshake.
      No test asserts the handshake still works.

## Reproducibility

- [ ] Dual env/lock systems (`environment.yaml` conda + `uv.lock`) as with
      rag; the `fastmcp`/`mcp`/`httpx` versions live in `pyproject.toml` and
      must not drift from the conda pins.
- [ ] `make freeze` relies on manual post-editing (verify `nodefaults`
      channel ordering, delete the self-referential editable install from the
      pip section). Error-prone; same issue as rag.
- [ ] `make build` requires a pre-existing git tag (sets version via
      `uv version` from the latest tag) but this prerequisite is only in the
      README prose, not enforced by the target. Building without a tag
      produces a wrong/again-`0.0.0` version silently.

## Interoperability

- [ ] Transport is streamable-http only, no stdio. Claude Desktop and several
      IDE MCP clients default to stdio. (Repo-wide stance shared with rag.)
- [ ] linux-64 only (documented). `pvserver`/`pvpython` reverse-connection and
      the conda `paraview` build restrict the server to Linux; macOS/Windows
      are unsupported. Acceptable but worth surfacing in a capability matrix.
- [ ] No tests. No unit or integration tests (`make test` does not exist here
      either). The subprocess lifecycle, timeout handling, and reverse-connect
      handshake are entirely unverified by CI.

## Suggested prioritization

- **Must-fix (docs are actively misleading):** console-script/env/clone-URL
  drift, missing `opencode.json`/`LICENSE` references, OpenCode config key
  mismatch.
- **High-value, low-effort:** add `.gitignore` (ignore `dist/`), fix
  prettier-bun and `pre-commit install` claims, sweep stale env name.
- **Strategic:** configurable timeouts, richer error/status reporting,
  document the `exec` trust boundary, add handshake/lifecycle tests,
  version-guard the ParaView 5.13.x workarounds.

# TODO — skill & agent

Review of the OpenCode artifacts under `skills/` and `agents/` (the primary
"product" content) covering implementation, deployment, maintainability,
sustainability, reproducibility, and interoperability. Same severity scale as
above.

# paraview-coder (`skills/paraview-coder/`)

## Outstanding tasks (implementation & deployment)

- [ ] **[High] `skills/README.md` points at a nonexistent reference path.**
      The reference-file table (line 45) says
      `skills/paraview/references/`, but the real directory is
      `skills/paraview-coder/references/`. `skills/paraview/` does not exist.
      This is the exact stale `paraview/` path the root `AGENTS.md` warns
      about; fix the README so readers can find the six reference files.
- [ ] **[Medium] Skill/dir/name coupling is correct but undocumented and
      fragile.** `make build` (Makefile line 13) copies each top-level
      `skills/*` directory by its directory name, and the OpenCode skill
      loader keys off frontmatter `name:`. Today both are `paraview-coder`,
      so it works — but renaming one without the other silently breaks
      loading. Note the invariant somewhere near the build target.

## Maintainability

- [ ] **[Medium] Non-standard frontmatter keys.** `SKILL.md` declares
      `license`, `compatibility`, and `metadata` (author/version). The
      OpenCode skill spec only consumes `name` and `description`; the rest is
      ignored at load time. Harmless, but it implies behavior the loader does
      not provide. Either drop them or move the provenance/version info into
      prose so it is not mistaken for enforced config.
- [ ] **[Medium] Provenance is inconsistent across the repo.** The skill
      `license` reads "Proprietary. Part of the ChatVis research artifact"
      and `metadata.author: chatvis`, while the surrounding repo is
      "VisKnacks"/"SciVisAgent". Pick one project identity (or document the
      ChatVis lineage explicitly) so the licensing story is unambiguous.
- [ ] **[Low] README workflow duplicates SKILL.md.** The 8-step workflow and
      trigger list are copied nearly verbatim into `skills/README.md`; they
      will drift. Consider having the README link to `SKILL.md` for the
      canonical workflow rather than restating it.

## Sustainability / correctness

- [ ] **[Medium] Version-target drift risk.** `SKILL.md` claims snippets
      target ParaView 5.12+, but the renderer runtime is pinned to 5.13.3 and
      the gotchas encode 5.10+ behavior (Threshold `LowerThreshold`/
      `UpperThreshold`, histogram bin-count via `GetProperty`). The
      paraview.simple API drifts between versions; nothing ties the skill's
      claimed range to the environment it actually runs in. Reconcile the
      stated version window with the deployed ParaView.
- [ ] **[Low] Hard-won gotchas are load-bearing and untested.** The gotchas
      block (unframed camera → blank, leftover `'var0'`, volume TF quartets,
      `InsideOut` unreliable) is the highest-value content but has no
      regression guard; a reference-snippet edit could silently reintroduce a
      failure mode. Consider a smoke test that runs one representative
      generated script under pvpython.

## Reproducibility

- [ ] **[Low] Skill output is only as reproducible as the model.** The skill
      relies on the LLM to substitute placeholders (`<input_path>`,
      `<output_path>`, `'var0'`) correctly every time. This is inherent to the
      approach, but the "leftover `'var0'`" failure is common enough that a
      post-generation lint (reject scripts still containing the sentinels)
      would make outputs deterministically safe.

## Interoperability

- [ ] **[Low] Hard dependency on the formatter subagent.** Step 0 mandates
      calling `paraview-prompt-formatter` for every request. If that agent is
      not present in the target harness (e.g. skill copied without the agent),
      the workflow's first step fails. Document the pairing, or degrade
      gracefully when the subagent is unavailable.

# paraview-prompt-formatter (`agents/paraview-prompt-formatter.md`)

## Maintainability

- [ ] **[Medium] No model or temperature pinned.** The subagent frontmatter
      sets only `description`, `mode`, and `permission`. For a deterministic
      text-reformatting task, pinning a small model and a low temperature
      would improve consistency and cut cost; leaving it unset inherits the
      caller's (possibly large, high-temp) model.
- [ ] **[Low] Term-mapping table is duplicated.** The casual-term → ParaView
      operation mapping lives in both `paraview-prompt-formatter.md` and
      `agents/README.md`; keep one canonical copy to avoid drift.
- [ ] **[Low] Permission list may over-specify.** The frontmatter denies ten
      named tools. If OpenCode defaults subagents to no tools, an explicit
      allow-list (or `tools: {}`) is terser and future-proof against newly
      added tool types that would otherwise default to allowed. Confirm the
      default stance and simplify accordingly.

## Sustainability / correctness

- [ ] **[Low] 1920x1080 convention is hard-coded in three places.** The size
      convention appears in `SKILL.md`, the agent prompt, and both READMEs.
      Changing the house resolution means editing all of them.

## Interoperability

- [ ] **[Low] Blocking-on-paths contract is prose-only.** The agent promises
      not to emit a prompt until both paths are supplied, and the skill
      promises to relay its question. Nothing enforces the handshake; a
      caller that ignores the "ask" reply will get no formatted prompt with no
      machine-detectable signal. Acceptable for an LLM workflow, but worth a
      note.

## Suggested prioritization

- **Must-fix (docs actively misleading):** correct the
  `skills/paraview/references/` path in `skills/README.md`.
- **High-value, low-effort:** reconcile ChatVis/VisKnacks provenance, pin the
  formatter's model/temperature, de-duplicate the workflow and term-mapping
  tables.
- **Strategic:** reconcile the ParaView version window with the deployed
  runtime, add a placeholder-sentinel lint and a pvpython smoke test for the
  gotchas.
