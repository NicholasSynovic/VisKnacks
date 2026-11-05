#!/usr/bin/env bash
#
# PV Renderer execute_code behavior test.
#
# Each execute_code call spawns a fresh pvpython runner + pvserver pair
# (~5-15s per call), so the default deadline is generous.
#
# PASS requires:
#   - A completed initialize/initialized handshake.
#   - Happy path: print() code returns returncode 0 with all five result
#     keys (returncode, runner_stdout, runner_stderr, pvserver_stdout,
#     pvserver_stderr) and the marker text in runner_stdout.
#   - User-code failure: 1/0 returns returncode > 0 with a
#     ZeroDivisionError traceback in runner_stderr.
#   - Statelessness: a call that creates a Sphere() is followed by a call
#     whose fresh session reports zero sources.
#
# The test spawns its own isolated server instance and shuts it down.
#
# Assumptions:
#   test-pvpython-env.bash verified pvpython/pvserver, and
#   test-pvpython-renderer-tools.bash verified the tool surface.
#
# Dependencies:
#   Linux, Bash 4+, GNU timeout, curl, jq, python (with the mcp package),
#   GNU sed, awk, grep, setsid, and the supplied optparse.bash.
#
# Exit codes:
#   0   = execute_code behavior verified
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
    desc="Keep the test sandbox and server log"

parser_file="$(optparse.build)"
[[ -r "$parser_file" ]] || setup_error "Could not build argument parser"

source "$parser_file"

shift "$((OPTIND - 1))"
[[ $# -eq 0 ]] || setup_error "Unexpected positional argument: $1"

set -u

[[ "$(uname -s)" == Linux ]] ||
    setup_error "This implementation supports Linux only"

for dependency in timeout curl jq sed awk grep setsid python; do
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

sandbox="$(mktemp -d /tmp/opencode-pvexecute-test.XXXXXXXX)"

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
    local call_max_time=150

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

    # execute_code returns a dict; FastMCP wraps it in
    # result.structuredContent (or content[0].text as JSON). This extracts
    # the raw dict into $sandbox/tool-result.json for the caller.
    extract_tool_result() {
        local response_file="$1" out_file="$2"
        jq -e '
            .result
            | if type != "object" then empty else . end
            | if (.isError // false) == true then empty else . end
            | (.structuredContent // (.content[0].text | fromjson))
        ' "$response_file" > "$out_file"
    }

    # call_execute_code <id> <code> <label>
    # Performs the tools/call and writes the extracted result dict to
    # $sandbox/<label>-result.json. Fails via fail() on any protocol issue.
    call_execute_code() {
        local request_id="$1" python_code="$2" label="$3"
        arguments="$(jq -cn --arg code "$python_code" '{code: $code}')"
        mcp_call_tool_request "$request_id" "execute_code" \
            "$arguments" "$sandbox/$label-req.json"
        if ! code="$(mcp_post "$MCP_SESSION" "$call_max_time" "$url" \
            "$sandbox/$label-req.json" \
            "$sandbox/$label-resp.hdr" "$sandbox/$label-resp.body")"; then
            fail "tools/call ($label) transport failure"
        fi
        [[ "$code" == 200 ]] ||
            fail "tools/call ($label) returned HTTP $code; expected 200"
        mcp_extract_json "$sandbox/$label-resp.body" \
            "$sandbox/$label-resp.json" ||
            fail "tools/call ($label) response had no JSON payload"
        jq -e "(.id == $request_id) and (.jsonrpc == \"2.0\") and
            (.error == null)" "$sandbox/$label-resp.json" >/dev/null ||
            fail "tools/call ($label) returned a JSON-RPC error"
        if ! extract_tool_result "$sandbox/$label-resp.json" \
            "$sandbox/$label-result.json"; then
            fail "tools/call ($label) returned isError or no result dict"
        fi
    }

    trap 'mcp_stop_server' EXIT

    start_stage "Start isolated renderer MCP server"
    mcp_start_server "$python_bin" "$pkg_dir" "$bind" "$port" \
        "$sandbox" "$sandbox/server.log"

    mcp_await_ready "$bind" "$port" "$MCP_SERVER_PID" 30 ||
        fail "Server did not bind and answer HTTP within 30s"

    start_stage "MCP handshake"
    mcp_handshake "$url" "$sandbox" 20 1 ||
        fail "initialize/initialized handshake failed"

    start_stage "execute_code happy path"
    call_execute_code 2 "print('hello-pv-test')" happy

    jq -e '
        ((keys | sort) == [
            "pvserver_stderr",
            "pvserver_stdout",
            "returncode",
            "runner_stderr",
            "runner_stdout"
        ]) and
        (.returncode == 0) and
        (.runner_stdout | contains("hello-pv-test"))
    ' "$sandbox/happy-result.json" >/dev/null ||
        fail "Happy path did not return the expected result dict"

    start_stage "execute_code user-code failure"
    call_execute_code 3 "1/0" failure

    jq -e '
        (.returncode > 0) and
        (.runner_stderr | contains("ZeroDivisionError"))
    ' "$sandbox/failure-result.json" >/dev/null ||
        fail "User-code failure did not surface as returncode > 0
            with a ZeroDivisionError traceback"

    start_stage "execute_code statelessness (create sphere)"
    call_execute_code 4 \
        "Sphere()
print('sphere-created')" stateless-a

    jq -e '.returncode == 0' "$sandbox/stateless-a-result.json" >/dev/null ||
        fail "Sphere creation call failed"

    start_stage "execute_code statelessness (fresh session)"
    call_execute_code 5 \
        "print('sources=%d' % len(GetSources()))" stateless-b

    jq -e '
        (.returncode == 0) and
        (.runner_stdout | contains("sources=0"))
    ' "$sandbox/stateless-b-result.json" >/dev/null ||
        fail "Second call did not start from a blank session"

    start_stage "Stop server"
    mcp_stop_server

    printf 'PASS: execute_code happy path, failure, and statelessness verified\n'
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
        "${stage:-execute_code verification}" >&2
    status=124
fi

if [[ -s "$sandbox/server.log" ]]; then
    printf '\n--- server.log (last 30 lines) ---\n' >&2
    tail -n 30 -- "$sandbox/server.log" >&2
fi

for artifact in happy-result.json failure-result.json \
    stateless-a-result.json stateless-b-result.json; do
    if [[ -s "$sandbox/$artifact" ]]; then
        printf '\n--- %s ---\n' "$artifact" >&2
        cat "$sandbox/$artifact" >&2
    fi
done

exit "$status"
