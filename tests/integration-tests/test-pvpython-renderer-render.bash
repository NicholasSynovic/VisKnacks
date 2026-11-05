#!/usr/bin/env bash
#
# PV Renderer end-to-end rendering smoke test.
#
# This is the only test that exercises the pvserver reverse-connection
# dial-back through a complete visualization pipeline. It deliberately
# frames the camera before rendering: an unframed camera is the classic
# blank-image failure mode this suite exists to catch.
#
# PASS requires:
#   - A completed initialize/initialized handshake.
#   - One execute_code call that creates a Sphere, frames the camera to
#     its bounds, saves a screenshot, and returns returncode 0.
#   - The screenshot exists in the sandbox, starts with the PNG magic
#     bytes, and is larger than 1 KiB (catching blank/solid images).
#   - runner_stdout contains the render marker; runner_stderr contains
#     no traceback.
#
# The test spawns its own isolated server instance and shuts it down.
#
# Assumptions:
#   test-pvpython-renderer-execute.bash verified execute_code behavior.
#
# Dependencies:
#   Linux, Bash 4+, GNU timeout, curl, jq, python (with the mcp package),
#   GNU sed, awk, grep, od, tail, stat, setsid, and the supplied
#   optparse.bash.
#
# Exit codes:
#   0   = render pipeline produced a nonblank PNG
#   1   = integration failure
#   2   = invalid setup or configuration
#   124 = deadline exceeded

set -eo pipefail

setup_error() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/mcp/pvpython-renderer"
PARSER="$SCRIPT_DIR/optparse.bash"
CLIENT="$SCRIPT_DIR/mcp_client.bash"

parser_file=""
sandbox=""
keep_artifacts=false

cleanup() {
    local status=$?
    trap - EXIT
    set +e

    [[ -z "$parser_file" ]] || rm -f -- "$parser_file"

    if [[ -n "$sandbox" ]]; then
        if [[ "$keep_artifacts" == true ]]; then
            printf 'INFO: Artifacts retained at %s\n' "$sandbox" >&2
        elif ! rm -rf -- "$sandbox"; then
            printf 'WARN: Could not fully remove %s\n' "$sandbox" >&2
        fi
    fi

    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -r "$PARSER" ]] || setup_error "Cannot read parser: $PARSER"

source "$PARSER"

optparse.define short=H long=host \
    variable=bind_host default=127.0.0.1 \
    desc="Bind address for the test server"

optparse.define short=p long=port \
    variable=port default=0 \
    desc="Bind port (0 selects a free port)"

optparse.define short=t long=timeout \
    variable=timeout_seconds default=240 \
    desc="Overall worker deadline in seconds"

optparse.define short=k long=keep-artifacts \
    variable=keep_artifacts value=true \
    desc="Keep the test sandbox, server log, and screenshot"

parser_file="$(optparse.build)"
[[ -r "$parser_file" ]] || setup_error "Could not build argument parser"

source "$parser_file"

shift "$((OPTIND - 1))"
[[ $# -eq 0 ]] || setup_error "Unexpected positional argument: $1"

set -u

[[ "$(uname -s)" == Linux ]] ||
    setup_error "This implementation supports Linux only"

for dependency in timeout curl jq sed awk grep od tail stat setsid python; do
    command -v "$dependency" >/dev/null 2>&1 ||
        setup_error "Missing dependency: $dependency"
done

timeout --version 2>/dev/null | grep -q 'GNU coreutils' ||
    setup_error "GNU timeout is required"

[[ "$timeout_seconds" =~ ^[0-9]{1,5}$ ]] ||
    setup_error "Timeout must be an integer between 1 and 86400"

timeout_seconds=$((10#$timeout_seconds))
((timeout_seconds >= 1 && timeout_seconds <= 86400)) ||
    setup_error "Timeout must be between 1 and 86400"

[[ "$bind_host" != *[[:space:]/@\?\#]* ]] ||
    setup_error "Bind host must be a hostname or IP address"

[[ "$port" =~ ^[0-9]{1,5}$ ]] ||
    setup_error "Port must be an integer between 0 and 65535"

port=$((10#$port))
((port >= 0 && port <= 65535)) ||
    setup_error "Port must be between 0 and 65535"

[[ -d "$PACKAGE_DIR" ]] ||
    setup_error "Renderer package directory not found: $PACKAGE_DIR"
[[ -f "$PACKAGE_DIR/pvpython_renderer/pv_mcp.py" ]] ||
    setup_error "Renderer module not found: $PACKAGE_DIR/pvpython_renderer/pv_mcp.py"

[[ -r "$CLIENT" ]] || setup_error "Cannot read client helpers: $CLIENT"

python_path="$(type -P -- python || true)"
[[ -n "$python_path" ]] || setup_error "Python interpreter not found"

"$python_path" -c 'import mcp' >/dev/null 2>&1 ||
    setup_error "python cannot import the mcp package"

command -v pvpython >/dev/null 2>&1 ||
    setup_error "pvpython not on PATH; run test-pvpython-env.bash first"
command -v pvserver >/dev/null 2>&1 ||
    setup_error "pvserver not on PATH; run test-pvpython-env.bash first"

if [[ "$port" -eq 0 ]]; then
    port="$(
        "$python_path" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
    )" || setup_error "Could not select a free port"
    printf 'INFO: Selected free port: %s\n' "$port"
fi

sandbox="$(mktemp -d /tmp/opencode-pvrender-test.XXXXXXXX)"

server_worker() {
    set -euo pipefail
    SECONDS=0

    local client_path="$1"
    local python_bin="$2"
    local pkg_dir="$3"
    local bind="$4"
    local port="$5"
    local sandbox="$6"

    local stage=""
    local url="http://$bind:$port/mcp/"
    local code=""
    local arguments=""
    local png_file="$sandbox/render.png"
    local python_code
    local magic=""
    local size=0

    source "$client_path"

    fail() {
        printf 'FAIL: [%s] %s\n' "$stage" "$*" >&2
        exit 1
    }

    start_stage() {
        stage="$1"
        printf '%s\n' "$stage" > "$sandbox/stage"
        printf 'INFO: [%ss] %s\n' "$SECONDS" "$stage"
    }

    python_code="sphere = Sphere()
Show(sphere)
Render()
ResetCamera()
SaveScreenshot(r'$png_file')
print('render-ok')"

    trap 'mcp_stop_server' EXIT

    start_stage "Start isolated renderer MCP server"
    mcp_start_server "$python_bin" "$pkg_dir" "$bind" "$port" \
        "$sandbox" "$sandbox/server.log"

    mcp_await_ready "$bind" "$port" "$MCP_SERVER_PID" 30 ||
        fail "Server did not bind and answer HTTP within 30s"

    start_stage "MCP handshake"
    mcp_handshake "$url" "$sandbox" 20 1 ||
        fail "initialize/initialized handshake failed"

    start_stage "Render sphere and save screenshot"
    arguments="$(jq -cn --arg code "$python_code" '{code: $code}')"
    mcp_call_tool_request 2 "execute_code" "$arguments" \
        "$sandbox/render-req.json"

    if ! code="$(mcp_post "$MCP_SESSION" 180 "$url" \
        "$sandbox/render-req.json" \
        "$sandbox/render-resp.hdr" "$sandbox/render-resp.body")"; then
        fail "tools/call (render) transport failure"
    fi
    [[ "$code" == 200 ]] ||
        fail "tools/call (render) returned HTTP $code; expected 200"

    mcp_extract_json "$sandbox/render-resp.body" \
        "$sandbox/render-resp.json" ||
        fail "tools/call (render) response had no JSON payload"

    jq -e '(.id == 2) and (.jsonrpc == "2.0") and (.error == null)' \
        "$sandbox/render-resp.json" >/dev/null ||
        fail "tools/call (render) returned a JSON-RPC error"

    jq -e '
        .result
        | if type != "object" then empty else . end
        | if (.isError // false) == true then empty else . end
        | (.structuredContent // (.content[0].text | fromjson))
    ' "$sandbox/render-resp.json" > "$sandbox/render-result.json" ||
        fail "tools/call (render) returned isError or no result dict"

    jq -e '.returncode == 0' "$sandbox/render-result.json" >/dev/null ||
        fail "Render code did not complete cleanly"

    jq -r '.runner_stdout' "$sandbox/render-result.json" |
        grep -q 'render-ok' ||
        fail "runner_stdout lacks the render marker"

    if jq -r '.runner_stderr' "$sandbox/render-result.json" |
        grep -q 'Traceback'; then
        fail "runner_stderr contains a traceback"
    fi

    start_stage "Validate screenshot artifact"
    [[ -s "$png_file" ]] || fail "Screenshot file was not created"

    size="$(stat -c %s -- "$png_file")"
    ((size > 1024)) ||
        fail "Screenshot is only $size bytes; likely blank or corrupt"

    magic="$(head -c 4 -- "$png_file" | od -An -tx1 | tr -d ' \n')"
    [[ "$magic" == "89504e47" ]] ||
        fail "Screenshot does not start with the PNG magic bytes"

    start_stage "Stop server"
    mcp_stop_server

    printf 'PASS: Screenshot produced (%s bytes, PNG signature ok)\n' \
        "$size"
    printf 'INFO: Worker elapsed time: %ss\n' "$SECONDS"
}

export -f server_worker

printf 'INFO: Bind address: %s\n' "$bind_host"
printf 'INFO: Port: %s\n' "$port"
printf 'INFO: Overall worker deadline: %ss\n' "$timeout_seconds"

if BASH_ENV=/dev/null ENV=/dev/null \
    timeout --signal=TERM --kill-after=2s "${timeout_seconds}s" \
        bash --noprofile --norc -c \
            'server_worker "$@"' server-worker \
            "$CLIENT" \
            "$python_path" \
            "$PACKAGE_DIR" \
            "$bind_host" \
            "$port" \
            "$sandbox"; then
    exit 0
else
    status=$?
fi

if [[ "$status" == 124 || "$status" == 137 ]]; then
    stage="$(cat "$sandbox/stage" 2>/dev/null || true)"
    printf 'FAIL: Deadline exceeded during: %s\n' \
        "${stage:-render verification}" >&2
    status=124
fi

if [[ -s "$sandbox/server.log" ]]; then
    printf '\n--- server.log (last 30 lines) ---\n' >&2
    tail -n 30 -- "$sandbox/server.log" >&2
fi

if [[ -s "$sandbox/render-result.json" ]]; then
    printf '\n--- render-result.json ---\n' >&2
    cat "$sandbox/render-result.json" >&2
fi

exit "$status"
