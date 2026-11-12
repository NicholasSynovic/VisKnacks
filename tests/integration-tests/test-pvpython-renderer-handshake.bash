#!/usr/bin/env bash
#
# PV Renderer MCP server streamable-http handshake test.
#
# PASS requires:
#   - The server binds its endpoint and answers HTTP requests on /mcp.
#   - initialize returns HTTP 200, an mcp-session-id header, and a JSON-RPC
#     result naming the server "ParaView" with a nonempty protocolVersion.
#   - notifications/initialized is accepted (HTTP 2xx).
#   - A malformed JSON body is rejected with HTTP 400.
#   - An unknown method returns JSON-RPC error -32601.
#   - A request without the session id is rejected (HTTP 4xx).
#
# The test spawns its own isolated server instance and shuts it down.
#
# Assumptions:
#   test-pvpython-env.bash and test-pvpython-renderer-cli.bash passed.
#
# Dependencies:
#   Linux, Bash 4+, GNU timeout, curl, jq, python (with the mcp package),
#   GNU sed, awk, grep, setsid, and the supplied optparse.bash.
#
# Exit codes:
#   0   = handshake and rejection behavior verified
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
    variable=timeout_seconds default=45 \
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

# The tests pin exact tool versions; reject any other release early.
# shellcheck disable=SC1090
source "$SCRIPT_DIR/version-check.bash"
require_mcp_version "$python_path"

if [[ "$port" -eq 0 ]]; then
    port="$(
        "$python_path" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
    )" || setup_error "Could not select a free port"
    printf 'INFO: Selected free port: %s\n' "$port"
fi

sandbox="$(mktemp -d /tmp/opencode-pvhandshake-test.XXXXXXXX)"

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
    local url="http://$bind:$port/mcp"
    local code=""

    source "$client_path"

    fail() {
        printf 'FAIL: [%s] %s\n' "$stage" "$*" >&2
        exit 1
    }

    start_stage() {
        stage="$1"
        printf 'INFO: [%ss] %s\n' "$SECONDS" "$stage"
    }

    trap 'mcp_stop_server' EXIT

    start_stage "Start isolated renderer MCP server"
    mcp_start_server "$python_bin" "$pkg_dir" "$bind" "$port" \
        "$sandbox" "$sandbox/server.log"

    mcp_await_ready "$bind" "$port" "$MCP_SERVER_PID" 30 ||
        fail "Server did not bind and answer HTTP within 30s"

    start_stage "MCP initialize handshake"
    mcp_handshake "$url" "$sandbox" 20 1 ||
        fail "initialize/initialized handshake failed"

    jq -e '
        (.id == 1) and
        (.jsonrpc == "2.0") and
        (.error == null) and
        (.result.serverInfo.name == "ParaView") and
        ((.result.protocolVersion // "") |
            (type == "string" and length > 0)) and
        (.result.capabilities | type == "object")
    ' "$sandbox/resp-init.json" >/dev/null ||
        fail "initialize result failed validation"

    printf 'INFO: Server name: %s, protocol: %s\n' \
        "$(jq -r '.result.serverInfo.name' "$sandbox/resp-init.json")" \
        "$(jq -r '.result.protocolVersion' "$sandbox/resp-init.json")"
    printf 'INFO: Session id: %s\n' "$MCP_SESSION"

    start_stage "Reject malformed JSON body"
    printf '{"jsonrpc":"2.0","id":99,' > "$sandbox/req-bad.json"
    code="$(mcp_post "$MCP_SESSION" 10 "$url" "$sandbox/req-bad.json" \
        "$sandbox/resp-bad.hdr" "$sandbox/resp-bad.body")" ||
        fail "Malformed-JSON request transport failure"
    [[ "$code" == 400 ]] ||
        fail "Malformed JSON returned HTTP $code; expected 400"
    printf 'INFO: Malformed JSON rejected with HTTP %s\n' "$code"

    start_stage "Reject unknown method"
    mcp_unknown_method_request 499 "$sandbox/req-unknown.json"
    code="$(mcp_post "$MCP_SESSION" 10 "$url" \
        "$sandbox/req-unknown.json" \
        "$sandbox/resp-unknown.hdr" "$sandbox/resp-unknown.body")" ||
        fail "Unknown-method request transport failure"
    [[ "$code" == 200 ]] ||
        fail "Unknown method returned HTTP $code; expected 200"
    mcp_extract_json "$sandbox/resp-unknown.body" \
        "$sandbox/resp-unknown.json" ||
        fail "Unknown-method response had no JSON payload"
    jq -e '
        (.id == 499) and
        (.jsonrpc == "2.0") and
        (.result == null) and
        (.error.code == -32601 or .error.code == -32602)
    ' "$sandbox/resp-unknown.json" >/dev/null ||
        fail "Unknown method did not return JSON-RPC -32601/-32602"

    start_stage "Reject request without session id"
    mcp_list_tools_request 500 "$sandbox/req-nosession.json"
    code="$(mcp_post "" 10 "$url" "$sandbox/req-nosession.json" \
        "$sandbox/resp-nosession.hdr" "$sandbox/resp-nosession.body")" ||
        fail "No-session request transport failure"
    [[ "$code" =~ ^4[0-9][0-9]$ ]] ||
        fail "Request without session id returned HTTP $code; expected 4xx"
    printf 'INFO: No-session request rejected with HTTP %s\n' "$code"

    start_stage "Stop server"
    mcp_stop_server

    printf 'PASS: Handshake and rejection behavior verified\n'
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
    printf 'FAIL: Deadline exceeded during server handshake\n' >&2
    status=124
fi

if [[ -s "$sandbox/server.log" ]]; then
    printf '\n--- server.log (last 30 lines) ---\n' >&2
    tail -n 30 -- "$sandbox/server.log" >&2
fi

for artifact in resp-init.hdr resp-init.body resp-bad.hdr \
    resp-bad.body resp-unknown.json resp-nosession.hdr; do
    if [[ -s "$sandbox/$artifact" ]]; then
        printf '\n--- %s (last 30 lines) ---\n' "$artifact" >&2
        tail -n 30 -- "$sandbox/$artifact" >&2
    fi
done

exit "$status"
