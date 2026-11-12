# VisKnacks integration tests

`tests/integration-tests/` holds standalone bash integration tests for
the VisKnacks harness: the OpenCode/Ollama toolchain, the ParaView
environment, and the two ways the `pvpython-renderer` MCP server is
reached (directly over MCP, and end to end through OpenCode). They are
not wired into pre-commit, the Makefile, or any CI — run them directly:

```bash
bash tests/integration-tests/run-all.bash   # everything, in order
bash tests/integration-tests/test-<name>.bash   # one test
```

The stages are ordered by assumption: each test assumes the earlier
ones passed. A failing stage stops the chain unless `--keep-going` is
used; run a failing test directly to isolate it.

## Contents

| Script                                  | Verifies                                                                                                            | Default budget |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------- | -------------- |
| `test-ollama.bash`                      | Ollama API reachable, `/api/version` returns valid JSON matching the pinned version                                 | 5 s/request    |
| `test-opencode.bash`                    | OpenCode CLI runs, `--help` and `--version` work                                                                    | 10 s/check     |
| `test-opencode-ollama.bash`             | OpenCode → Ollama → OpenCode round trip; assistant text contains the run marker                                     | 30 s overall   |
| `test-opencode-skill.bash`              | An actual skill tool call for `integration-probe` completes and returns the skill-body marker                       | 30 s overall   |
| `test-opencode-subagent.bash`           | Configuration-driven subagent dispatch (`custom command -> subtask:true -> integration-child`) succeeds             | 30 s overall   |
| `test-pvpython-env.bash`                | `pvpython` and `pvserver` on PATH, each answers `--version`                                                         | 15 s/binary    |
| `test-pvpython-renderer-cli.bash`       | Renderer entry point: `--help` documents `--server`/`--port`, `--version` prints, unknown option exits 2            | 30 s           |
| `test-pvpython-renderer-handshake.bash` | Streamable-http handshake, session id required, malformed body → 400, unknown method → -32601                       | 45 s           |
| `test-pvpython-renderer-tools.bash`     | `tools/list` returns exactly `execute_code` with the documented `code` schema; unknown tool errors                  | 60 s           |
| `test-pvpython-renderer-execute.bash`   | `execute_code` happy path (marker in `runner_stdout`), user-code failure (traceback, returncode > 0), statelessness | 240 s          |
| `test-pvpython-renderer-render.bash`    | Full rendering pipeline through the pvserver reverse-connection dial-back; framed camera, PNG screenshot            | 240 s          |
| `test-opencode-renderer-discovery.bash` | OpenCode `/mcp` reports `connected` for `pvpython_renderer`; upstream `execute_code` schema verified. No inference  | 30 s           |
| `test-opencode-renderer-execute.bash`   | Model invokes `pvpython_renderer_execute_code` once with the supplied code unchanged; marker in `runner_stdout`     | 180 s          |
| `test-opencode-renderer-render.bash`    | As execute, plus a fixed sphere scene and a 256x256 screenshot validated structurally                               | 180 s          |

Shared helpers, not tests themselves:

- `optparse.bash` — vendored getopts wrapper
  (https://github.com/nk412/optparse) shared by every script. It exits 1
  for argument-parsing errors and accepts only space-separated option
  values, not `--option=value`.
- `versions.env` — the single place where the required OpenCode and
  Ollama versions are pinned. See "Pinned versions" below.
- `version-check.bash` — sourced by `run-all.bash` and every
  OpenCode-using test; provides `require_opencode_version` and
  `require_ollama_version`, which exit 2 on any mismatch.
- `mcp_client.bash` — pure-bash MCP streamable-http client plus server
  lifecycle helpers. Sourced by the direct renderer tests and the
  OpenCode renderer driver; every server test spawns its own isolated
  instance (port 0 auto-select) and shuts it down.
- `opencode-renderer-common.bash` — shared driver behind the three
  `test-opencode-renderer-*` wrappers.
- `renderer-assert.py` — stdlib-only code generator and result/PNG
  validator for the OpenCode renderer tests.
- `run-all.bash` — runs every stage in the order above and prints a
  summary.

## Requirements

Linux, Bash 4+, GNU `timeout`. Per group:

- Ollama stages: `curl`, `jq`, a local `ollama serve` (default
  `http://127.0.0.1:11434`) and the default model `qwen3.5:0.8b`
  **already installed** — nothing is downloaded or prewarmed.
- OpenCode stages: `opencode` on `PATH`.
- Renderer stages: Python with the `mcp` package (activate the VisKnacks
  conda env, or pass its interpreter). Only the tests that actually run
  pvpython code — `test-pvpython-env`, `*-execute`, `*-render` and the
  OpenCode renderer execute/render tests — additionally need
  `pvpython`/`pvserver` on PATH.

The harness stages build isolated OpenCode configuration and state per
attempt; installed binaries and the Ollama service are shared and never
restarted.

## Pinned versions

The tests drive exact OpenCode server API response shapes and Ollama
endpoints, so tool versions are pinned **exactly**:

- `tests/integration-tests/versions.env` declares
  `OPENCODE_REQUIRED_VERSION`, `OLLAMA_REQUIRED_VERSION`,
  `PARAVIEW_REQUIRED_VERSION`, and `MCP_REQUIRED_VERSION` — the only
  place versions are written.
- `run-all.bash` checks them before stage 1 (Ollama unconditionally,
  OpenCode unless `-O`/`--skip-opencode`, ParaView + the `mcp` Python
  package unless `-C`/`--skip-mcp`); each test re-checks the tools it
  uses: Ollama in `test-ollama.bash`, OpenCode in every harness test,
  ParaView in `test-pvpython-env.bash`, and the `mcp` package in every
  renderer test.
- Any mismatch, unparseable version, or unreachable version endpoint
  exits 2 (invalid setup) before any test logic runs.

The ParaView pin matters beyond cosmetics: the 5.13.3 X-only build
cannot render headless on this machine (`bad X server connection`),
while 6.1.1 falls back to EGL and renders fine. The `mcp` pin fixes
the server's streamable-http traits (the base env's `mcp` package
307-redirects `/mcp` to `/mcp/`; the tests follow redirects and work
with either trait).

To upgrade the pinned versions: update the tool install, verify the
API/protocol shapes the tests rely on, then edit `versions.env` alone.
On Homebrew, `brew pin opencode-v2` additionally blocks accidental
upgrades of the installed binary.

## Conventions

- Exit-code contract in every script: `0` pass, `1` integration
  failure, `2` invalid setup/config or missing dependency, `124`
  deadline exceeded. Argument-parsing errors exit 1 (optparse).
- `-k` / `--keep-artifacts` retains the per-test sandbox (generated
  config, logs, and — where produced — code and images) for debugging;
  otherwise everything is cleaned up on success, failure, and ordinary
  termination signals.
- The harness tests assert on observed tool behavior (an actual skill
  tool call, a configured subagent dispatch), never on assistant prose.
- The renderer tests deliberately encode known pvpython failure modes:
  the render test frames the camera before saving (the classic
  blank-image failure) and rejects solid images.

## run-all.bash

```bash
bash tests/integration-tests/run-all.bash -m qwen3.5:0.8b
```

Options: `-u`/`--ollama-url`, `-m`/`--model`, `-b`/`--opencode-binary`,
`-y`/`--python`, `-M`/`--mcp-host`, `-P`/`--mcp-port` (bind address for
the isolated renderer servers; `0` = auto-select), `-t`/`--timeout`
(forwarded per-test deadline, overriding the defaults above),
`-r`/`--retries` (extra attempts for the OpenCode→Ollama stage, 0-3),
`-k`/`--keep-artifacts`, `-g`/`--keep-going`, plus the phase skips:

- `-O` / `--skip-opencode`: skip the OpenCode/Ollama stages (tests 2-5)
  and the OpenCode renderer stages (12-14).
- `-C` / `--skip-mcp`: skip all renderer stages (6-14).

Exit codes: `0` all executed stages passed, `1` the first failed
stage's code, `2` invalid configuration, `130`/`143` interrupted.

## Direct renderer MCP tests

Each spawns an isolated `pvpython_renderer` server via
`mcp_client.bash` (`-H` bind host, `-p` bind port, `0` = auto-select)
and shuts it down afterwards:

- `test-pvpython-renderer-handshake.bash`: `initialize` returns HTTP
  200, an `mcp-session-id`, and a JSON-RPC result naming the server
  `ParaView`; `notifications/initialized` is accepted; a malformed JSON
  body is rejected with 400; an unknown method returns -32601; a
  request without the session id is rejected with 4xx.
- `test-pvpython-renderer-tools.bash`: `tools/list` returns exactly one
  tool, `execute_code`, whose inputSchema is an object requiring the
  string property `code`; a `tools/call` for an unknown tool errors
  instead of hanging. No ParaView session is exercised here.
- `test-pvpython-renderer-execute.bash`: each `execute_code` call
  spawns a fresh pvpython runner + pvserver pair (~5-15 s), hence the
  generous default. Happy path: `print()` code returns `returncode 0`
  with all five result keys and the marker in `runner_stdout`.
  Failure path: `1/0` returns `returncode > 0` with a
  `ZeroDivisionError` traceback in `runner_stderr`. Statelessness: a
  call creating a `Sphere()` is followed by a call whose fresh session
  reports zero sources.
- `test-pvpython-renderer-render.bash`: exercises the pvserver
  reverse-connection dial-back through a complete visualization
  pipeline. One `execute_code` call creates a sphere,
  frames the camera to its bounds, saves a screenshot, and returns 0;
  the screenshot exists in the sandbox, starts with the PNG magic
  bytes, and is larger than 1 KiB (catching blank/solid images); the
  render marker appears in `runner_stdout` with no traceback in
  `runner_stderr`.

## OpenCode renderer tests

These three verify the renderer MCP server end to end through OpenCode,
complementing the direct tests above. Each wrapper is a thin launcher;
the shared driver lives in `opencode-renderer-common.bash`.

- `test-opencode-renderer-discovery.bash`: starts a dedicated renderer
  and an isolated OpenCode server on loopback. Requires OpenCode's
  `/api/mcp` status to report `connected` for `pvpython_renderer`,
  then separately performs a raw MCP handshake and `tools/list` to
  verify the upstream `execute_code` schema. The schema check is
  independent of OpenCode; it is NOT proof that an OpenCode
  experimental tool-registry endpoint lists MCP schemas. No model
  inference or `execute_code` call occurs in discovery.
- `test-opencode-renderer-execute.bash`: requires one real
  `pvpython_renderer_execute_code` tool part, matching the supplied
  Python (allowing only trailing newline differences), completed state,
  returncode 0, and the run-specific marker in `runner_stdout`.
  Ordinary assistant text and reasoning never count as execution
  evidence.
- `test-opencode-renderer-render.bash`: adds a fixed Sphere scene,
  camera framing and 256x256 screenshot. Verifies the actual renderer
  result and the image: full PNG signature, chunk CRCs, decompression,
  RGB/RGBA row filters, dimensions and more than 16 distinct pixel
  colors. This rejects solid images; it is not a semantic assertion
  that every pixel depicts the intended scene or a screenshot-golden
  comparison. The validator intentionally requires noninterlaced 8-bit
  RGB/RGBA PNG output and fails on other PNG encodings.

Each invocation owns its renderer, OpenCode server, HOME, XDG
directories, configuration, session and files. No state is carried
between tests. Managed `/etc/opencode` configuration is rejected.

The renderer defaults to `../../mcp/pvpython-renderer` relative to the
scripts. Use `-P /absolute/path/to/mcp/pvpython-renderer` elsewhere.

Options shared by the three wrappers:

- `-u` / `--ollama-url`: direct root URL, default `http://127.0.0.1:11434`
- `-m` / `--model`: installed model, default `qwen3.5:0.8b`
- `-b` / `--binary`: OpenCode executable
- `-p` / `--python`: Python interpreter with mcp installed
- `-P` / `--package-dir`: renderer package directory
- `-t` / `--timeout`: ONE overall worker deadline
- `-k` / `--keep-artifacts`: retain configuration, logs, code and image
- `--help`: parser-generated help

Shutdown may add up to three seconds of forced-termination grace.
There are no retries and no model downloads/prewarming.

### Model and tool-output contract

The generated OpenCode configuration declares context 8192, output 1024
and model-level reasoningEffort none. These are client settings, not an
enforced Ollama `num_ctx` change or proof of option forwarding.
Model-driven tool use can still fail; that is reported as a
model/invocation failure, not an MCP pass. The harness does not wait
for a final assistant summary after tool completion.

Tool output must be a JSON renderer result or an MCP
structuredContent/content wrapper containing that JSON. Unexpected
wrapping fails with saved tool parts rather than being accepted via
loose string matching.

The tests use OpenCode's V2 server API under `/api` with HTTP basic
auth: `GET /api/info` (readiness, version field), `POST /api/session`,
`POST /api/session/:id/prompt` (asynchronous admission; the
experimental `POST /api/experimental/session/:id/wait` is the
turn-completion barrier), `GET /api/session?parentID=` (child
sessions), `GET /api/session/:id/message` (paginated `{data, cursor}`
flat messages), and `GET /api/mcp`. Each temporary server gets a
per-run password via `OPENCODE_SERVER_PASSWORD`; response shapes are
asserted strictly, so differences in an installed version fail
visibly with diagnostics (the version pin makes this a setup error
instead).

### Safety and deployment scope

These tests start a real `execute_code` service and submit executable
Python. HOME/XDG isolation is not a security sandbox. Use a disposable
or dedicated account with appropriately limited filesystem/network
access. Both temporary servers bind loopback; the renderer MCP server
is unauthenticated, while the OpenCode server requires the per-run
basic-auth password. Other local processes may still reach them. Do
not expose the renderer to an untrusted network.

The tests are local-only: screenshot validation assumes the renderer
and harness share the temporary directory. No SSH, reverse proxy,
remote HPC filesystem transfer, authentication, or persistent service
management is added. A free renderer port is selected by
bind-and-release; there is a small race. If another process occupies
it, readiness/connection checks must fail rather than treating
arbitrary HTTP availability as an integration pass.

### Diagnostics

Failed tests print bounded tails of the OpenCode log, renderer log, MCP
status, prompt response and tool result. `--keep-artifacts` retains
additional files including generated code, all session messages,
`renderer-result.json`, `render.png` and `image-validation.json`.
