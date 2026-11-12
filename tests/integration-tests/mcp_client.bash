#!/usr/bin/env bash
#
# Shared helpers for the pvpython-renderer MCP integration tests.
#
# Not a test itself; it is sourced by the test-*.bash scripts. Provides
# pure-bash MCP streamable-http client functions (curl + jq + sed) and
# server lifecycle helpers so every server test spawns its own isolated
# instance.
#
# Dependencies: curl, jq, sed, awk, grep, tail, tr, date.
#
# Helpers never exit on failure; callers check return values so that a
# failure maps to the suite exit-code contract (0 pass, 1 failure,
# 2 setup error, 124 deadline).

# ---------------------------------------------------------------------------
# Low-level HTTP plumbing
# ---------------------------------------------------------------------------

# mcp_http_code <url> [max_time]
# Bare GET request; prints the final HTTP status code after following
# redirects (some MCP server builds answer /mcp with a 307 to /mcp/),
# or an empty string when the transport fails. Used for server
# readiness polling.
mcp_http_code() {
    local url="$1" max_time="${2:-2}"
    curl --disable --silent --location --output /dev/null \
        --write-out '%{http_code}' \
        --noproxy '*' --globoff \
        --connect-timeout 1 --max-time "$max_time" "$url" 2>/dev/null || true
}

# mcp_header <header-file> <header-name>
# Print the first value of the named HTTP response header
# (case-insensitive), or an empty string when absent.
mcp_header() {
    local file="$1"
    local lname
    lname="$(printf '%s' "$2" | tr 'A-Z' 'a-z')"
    sed -e 's/\r$//' "$file" 2>/dev/null |
        awk -v name="$lname" \
            'tolower($0) ~ "^"name":" {
                sub(/^[^:]*:[[:space:]]*/, "")
                print
                exit
            }'
}

# mcp_post <session_id> <max_time> <url> <json_file> <hdr_out> <body_out>
# POST a JSON-RPC document to the streamable-http endpoint. Follows
# redirects; curl re-issues the POST with its body for 307/308
# responses, so server builds that redirect /mcp to /mcp/ stay
# transparent. Prints the final HTTP status code on stdout; returns the
# curl exit code. Response headers are the final hop's. An empty
# <session_id> omits the mcp-session-id request header.
mcp_post() {
    local session="$1" max_time="$2" url="$3" json_file="$4"
    local hdr_out="$5" body_out="$6"
    local -a args=(
        --noproxy '*'
        --globoff
        --location
        --connect-timeout 2
        --max-time "$max_time"
        --request POST
        --header 'Content-Type: application/json'
        --header 'Accept: application/json, text/event-stream'
        --data-binary "@$json_file"
        --dump-header "$hdr_out"
        --output "$body_out"
        --write-out '%{http_code}'
        --silent
        --show-error
    )
    if [[ -n "$session" ]]; then
        args+=(--header "mcp-session-id: $session")
    fi
    curl --disable "${args[@]}" "$url"
}

# mcp_extract_json <body_file> <out_file>
# Extract the JSON-RPC payload from an HTTP response body: an SSE body
# (the last `data:` line) or a plain JSON body. CR characters are
# stripped. Returns 1 when no payload could be written.
mcp_extract_json() {
    local body="$1" out="$2" payload=""
    if grep -q '^data:' "$body" 2>/dev/null; then
        payload="$(grep '^data:' "$body" | tail -n 1 | sed 's/^data://')"
    else
        payload="$(tr -d '\r' < "$body")"
    fi
    [[ -n "$payload" ]] || return 1
    printf '%s\n' "$payload" | tr -d '\r' > "$out"
    [[ -s "$out" ]] || return 1
}

# ---------------------------------------------------------------------------
# JSON-RPC request builders (jq)
# ---------------------------------------------------------------------------

# mcp_init_request <id> <out_file>
mcp_init_request() {
    jq -n --argjson id "$1" '
        {
            jsonrpc: "2.0",
            id: $id,
            method: "initialize",
            params: {
                protocolVersion: "2025-03-26",
                capabilities: {},
                clientInfo: {
                    name: "visknacks-pvpython-renderer-test",
                    version: "1.0"
                }
            }
        }' > "$2"
}

# mcp_initialized_notification <out_file>
mcp_initialized_notification() {
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        > "$1"
}

# mcp_list_tools_request <id> <out_file>
mcp_list_tools_request() {
    jq -n --argjson id "$1" '
        {jsonrpc: "2.0", id: $id, method: "tools/list", params: {}}' \
        > "$2"
}

# mcp_call_tool_request <id> <tool_name> <arguments_json> <out_file>
mcp_call_tool_request() {
    jq -n --argjson id "$1" --arg name "$2" --argjson args "$3" '
        {
            jsonrpc: "2.0",
            id: $id,
            method: "tools/call",
            params: {name: $name, arguments: $args}
        }' > "$4"
}

# mcp_unknown_method_request <id> <out_file>
mcp_unknown_method_request() {
    jq -n --argjson id "$1" '
        {
            jsonrpc: "2.0",
            id: $id,
            method: "server/definitely/not/a/method",
            params: {}
        }' > "$2"
}

# ---------------------------------------------------------------------------
# Server lifecycle (each test spawns its own isolated instance)
# ---------------------------------------------------------------------------

# mcp_start_server <python_bin> <pkg_dir> <bind_host> <port> <sandbox> <log>
# Spawn the renderer MCP server (install-free, module invocation) inside a
# scrubbed environment with a sandboxed HOME. The subprocess runs in its
# own session (setsid) so cleanup can kill the whole group. Sets the
# global MCP_SERVER_PID.
mcp_start_server() {
    local python_bin="$1" pkg_dir="$2" bind_host="$3" port="$4"
    local sandbox="$5" log_file="$6"
    (
        cd -- "$sandbox"
        exec setsid env -i \
            "PATH=$PATH" \
            "HOME=$sandbox" \
            "TMPDIR=$sandbox" \
            "TERM=dumb" \
            "NO_COLOR=1" \
            "NO_PROXY=*" \
            "no_proxy=*" \
            "PYTHONPATH=$pkg_dir" \
            "PYTHONDONTWRITEBYTECODE=1" \
            "$python_bin" -m pvpython_renderer.main \
            --server "$bind_host" --port "$port"
    ) > "$log_file" 2>&1 &
    MCP_SERVER_PID=$!
}

# mcp_stop_server
# Terminate the server process group started by mcp_start_server.
mcp_stop_server() {
    local pid="${MCP_SERVER_PID:-}"
    [[ -n "$pid" ]] || return 0
    kill -TERM -- "-$pid" 2>/dev/null || true
    sleep 0.2
    if kill -0 -- "-$pid" 2>/dev/null; then
        kill -KILL -- "-$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    MCP_SERVER_PID=""
}

# mcp_await_ready <host> <port> <server_pid> <max_seconds>
# Poll until the server answers an HTTP request on /mcp with a final
# (redirect-followed) status. Returns 1 when the server process dies
# or the deadline expires first.
mcp_await_ready() {
    local host="$1" port="$2" pid="$3" max_seconds="$4"
    local code=""
    local deadline=$(( $(date +%s) + max_seconds ))
    while (( $(date +%s) < deadline )); do
        kill -0 "$pid" 2>/dev/null || return 1
        code="$(mcp_http_code "http://$host:$port/mcp" 2)"
        if [[ "$code" =~ ^[245][0-9][0-9]$ ]]; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

# mcp_handshake <url> <sandbox_dir> <max_time> <request_id>
# Perform initialize + notifications/initialized and validate the
# responses. Sets the global MCP_SESSION on success; returns 1 on any
# transport, HTTP, or payload failure.
mcp_handshake() {
    local url="$1" sandbox="$2" max_time="$3" request_id="$4"
    local code=""

    mcp_init_request "$request_id" "$sandbox/req-init.json" || return 1

    code="$(mcp_post "" "$max_time" "$url" "$sandbox/req-init.json" \
        "$sandbox/resp-init.hdr" "$sandbox/resp-init.body")" || return 1
    [[ "$code" == 200 ]] || return 1

    MCP_SESSION="$(mcp_header "$sandbox/resp-init.hdr" 'mcp-session-id')"
    [[ -n "$MCP_SESSION" ]] || return 1

    mcp_extract_json "$sandbox/resp-init.body" \
        "$sandbox/resp-init.json" || return 1

    mcp_initialized_notification "$sandbox/req-initialized.json" || return 1
    code="$(mcp_post "$MCP_SESSION" "$max_time" "$url" \
        "$sandbox/req-initialized.json" \
        "$sandbox/resp-initialized.hdr" \
        "$sandbox/resp-initialized.body")" || return 1
    [[ "$code" =~ ^2[0-9][0-9]$ ]] || return 1

    return 0
}
