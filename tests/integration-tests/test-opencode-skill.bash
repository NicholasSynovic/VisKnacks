#!/usr/bin/env bash
#
# OpenCode skill-loading integration test.
#
# PASS requires:
#   - An actual skill tool call for integration-probe.
#   - Successful completion of that tool call.
#   - The skill-body marker in the tool's returned output.
#
# Reasoning, assistant text, and tool arguments do not prove loading.
# No final assistant response is required.
#
# Assumptions:
#   Earlier tests verified OpenCode, Ollama, and model availability.
#
# Dependencies:
#   Linux, Bash 4+, GNU timeout, GNU sed, curl, jq, setsid,
#   OpenCode, and the supplied optparse.bash.
#
# Budgets:
#   OpenCode-declared context: 1024 tokens
#   Generated output:         256 tokens
#   Overall worker deadline:  30 seconds by default
#
# The declared context limit does not configure Ollama's runtime num_ctx.
#
# Exit codes:
#   0   = skill loaded successfully
#   1   = integration failure
#   2   = invalid setup
#   124 = deadline exceeded

set -eo pipefail

setup_error() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PARSER="$SCRIPT_DIR/optparse.bash"

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

[[ -r "$PARSER" ]] ||
    setup_error "Cannot read parser: $PARSER"

source "$PARSER"

optparse.define short=u long=ollama-url \
    variable=ollama_url default=http://127.0.0.1:11434 \
    desc="Direct Ollama server root URL"

optparse.define short=m long=model \
    variable=model default=qwen3.5:0.8b \
    desc="Installed Ollama model"

optparse.define short=t long=timeout \
    variable=timeout_seconds default=30 \
    desc="Overall worker deadline in seconds"

optparse.define short=b long=binary \
    variable=opencode_binary default=opencode \
    desc="OpenCode executable name or path"

optparse.define short=k long=keep-artifacts \
    variable=keep_artifacts value=true \
    desc="Keep temporary configuration and logs"

parser_file="$(optparse.build)"
[[ -r "$parser_file" ]] ||
    setup_error "Could not build argument parser"

source "$parser_file"

shift "$((OPTIND - 1))"
[[ $# -eq 0 ]] ||
    setup_error "Unexpected positional argument: $1"

set -u

[[ "$(uname -s)" == Linux ]] ||
    setup_error "This implementation supports Linux only"

for dependency in bash timeout curl jq grep setsid; do
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

while [[ "$ollama_url" == */ ]]; do
    ollama_url="${ollama_url%/}"
done

url_pattern='^https?://(\[[0-9A-Fa-f:.%]+\]|[A-Za-z0-9._-]+)(:[0-9]{1,5})?$'
[[ "$ollama_url" =~ $url_pattern ]] ||
    setup_error "Use a direct server root URL without credentials or paths"

[[ "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] ||
    setup_error "Invalid model name"

[[ ! -e /etc/opencode ]] ||
    setup_error \
        "/etc/opencode exists; use an environment without managed config"

opencode_path="$(type -P -- "$opencode_binary" || true)"
[[ -n "$opencode_path" && -f "$opencode_path" && -x "$opencode_path" ]] ||
    setup_error "OpenCode executable not found: $opencode_binary"

if [[ "$opencode_path" != /* ]]; then
    opencode_path="$PWD/$opencode_path"
fi

sandbox="$(mktemp -d /tmp/opencode-skill-test.XXXXXXXX)"

skill_worker() {
    set -euo pipefail
    SECONDS=0

    local binary="$1"
    local ollama_url="$2"
    local model="$3"
    local sandbox="$4"
    local budget="$5"

    local stage=""
    local server_url=""
    local session_id=""
    local selected_model="ollama-test/$model"
    local run_id=""
    local marker=""
    local prompt_finished=false

    # Retain these for EXIT cleanup after function-local scope unwinds.
    declare -g server_pid=""
    declare -g request_pid=""

    stop_processes() {
        local status=$?
        trap - EXIT INT TERM
        set +e

        if [[ -n "${request_pid:-}" ]]; then
            kill -TERM "$request_pid" 2>/dev/null
        fi

        if [[ -n "${server_pid:-}" ]]; then
            kill -TERM -- "-$server_pid" 2>/dev/null
        fi

        sleep 0.2

        if [[ -n "${request_pid:-}" ]]; then
            kill -KILL "$request_pid" 2>/dev/null
            wait "$request_pid" 2>/dev/null
        fi

        if [[ -n "${server_pid:-}" ]]; then
            kill -KILL -- "-$server_pid" 2>/dev/null
            wait "$server_pid" 2>/dev/null
        fi

        exit "$status"
    }

    trap stop_processes EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT

    fail() {
        printf 'FAIL: [%s] %s\n' "$stage" "$*" >&2
        exit 1
    }

    start_stage() {
        stage="$1"
        printf '%s\n' "$stage" > "$sandbox/stage"
        printf 'INFO: [%ss] %s\n' "$SECONDS" "$stage"
    }

    api() {
        local method="$1"
        local path="$2"
        local output="$3"
        local body="${4:-}"

        local -a args=(
            --disable
            --silent
            --show-error
            --fail
            --noproxy '*'
            --globoff
            --connect-timeout 1
            --max-time "$budget"
            --request "$method"
            --output "$output"
        )

        if [[ -n "$body" ]]; then
            args+=(
                --header 'Content-Type: application/json'
                --data-binary "@$body"
            )
        fi

        curl "${args[@]}" "$server_url$path"
    }

    diagnose_no_load() {
        local tool_count
        local finish

        tool_count="$(jq 'length' "$sandbox/tool-parts.json")"

        finish="$(
            jq -r '
                [
                    .[]
                    | select(.info.role == "assistant")
                ]
                | last
                | .info.finish // "unknown"
            ' "$sandbox/messages.json"
        )"

        if [[ "$tool_count" == 0 ]]; then
            fail \
                "Model finished without issuing any tool call (finish=$finish); skill loading was not exercised"
        fi

        fail \
            "Model finished without a successful matching skill load (finish=$finish)"
    }

    start_stage "Create isolated skill and configuration"

    mkdir -p \
        "$sandbox/home" \
        "$sandbox/config/opencode/skills/integration-probe" \
        "$sandbox/data" \
        "$sandbox/cache" \
        "$sandbox/state" \
        "$sandbox/work"

    run_id="$(cat /proc/sys/kernel/random/uuid)"
    marker="skill-ok-${run_id:0:8}"
    printf '%s\n' "$marker" > "$sandbox/marker.txt"

    # Do not put the marker in the description or user/agent prompt.
    cat > "$sandbox/config/opencode/skills/integration-probe/SKILL.md" <<EOF
---
name: integration-probe
description: Load this skill when explicitly requested by name.
---

Skill loading verification marker: $marker

No further action is required.
EOF

    jq -n \
        --arg selected "$selected_model" \
        --arg model "$model" \
        --arg base_url "$ollama_url/v1" \
        --argjson request_timeout "$((budget * 1000))" \
        '{
            "$schema": "https://opencode.ai/config.json",
            model: $selected,
            small_model: $selected,
            default_agent: "integration-skill",
            enabled_providers: ["ollama-test"],
            autoupdate: false,
            snapshot: false,
            share: "disabled",
            plugin: [],
            mcp: {},
            instructions: [],
            compaction: {auto: false},
            permission: {"*": "deny"},
            provider: {
                "ollama-test": {
                    npm: "@ai-sdk/openai-compatible",
                    name: "Integration Ollama",
                    options: {
                        baseURL: $base_url,
                        timeout: $request_timeout
                    },
                    models: {
                        ($model): {
                            name: $model,
                            limit: {
                                context: 1024,
                                output: 256
                            }
                        }
                    }
                }
            },
            agent: {
                "integration-skill": {
                    mode: "primary",
                    model: $selected,
                    temperature: 0,
                    steps: 2,
                    prompt: (
                        "Your only task is to execute the native skill tool. " +
                        "Call skill with the argument " +
                        "skill({\"name\":\"integration-probe\"}). " +
                        "Issue an actual tool call, not text describing one. " +
                        "Do not use any other tool."
                    ),
                    permission: {
                        "*": "deny",
                        skill: {
                            "*": "deny",
                            "integration-probe": "allow"
                        }
                    }
                }
            }
        }' > "$sandbox/opencode.json"

    start_stage "Start temporary OpenCode server"

    (
        cd -- "$sandbox/work"

        exec setsid env -i \
            "PATH=$PATH" \
            "HOME=$sandbox/home" \
            "XDG_CONFIG_HOME=$sandbox/config" \
            "XDG_DATA_HOME=$sandbox/data" \
            "XDG_CACHE_HOME=$sandbox/cache" \
            "XDG_STATE_HOME=$sandbox/state" \
            "TMPDIR=$sandbox" \
            "TERM=dumb" \
            "NO_COLOR=1" \
            "NO_PROXY=*" \
            "no_proxy=*" \
            "OPENCODE_CONFIG=$sandbox/opencode.json" \
            "OPENCODE_CONFIG_DIR=$sandbox/config/opencode" \
            "OPENCODE_DISABLE_PROJECT_CONFIG=true" \
            "OPENCODE_DISABLE_CLAUDE_CODE=true" \
            "OPENCODE_DISABLE_EXTERNAL_SKILLS=true" \
            "OPENCODE_DISABLE_DEFAULT_PLUGINS=true" \
            "OPENCODE_PURE=true" \
            "OPENCODE_DISABLE_AUTOUPDATE=true" \
            "OPENCODE_DISABLE_MODELS_FETCH=true" \
            "OPENCODE_DISABLE_LSP_DOWNLOAD=true" \
            "OPENCODE_DISABLE_AUTOCOMPACT=true" \
            "OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=256" \
            "$binary" serve --hostname 127.0.0.1 --port 0
    ) > "$sandbox/server.log" 2>&1 &
    server_pid=$!

    while :; do
        kill -0 "$server_pid" 2>/dev/null ||
            fail "Temporary server exited during startup"

        server_url="$(
            grep -Eo 'http://127\.0\.0\.1:[0-9]+' \
                "$sandbox/server.log" |
                tail -n 1 || true
        )"

        if [[ -n "$server_url" ]]; then
            if api GET /global/health "$sandbox/health.json" \
                2> "$sandbox/readiness.stderr"; then

                if jq -e '.healthy == true' \
                    "$sandbox/health.json" >/dev/null; then
                    break
                fi
            fi
        fi

        sleep 0.1
    done

    printf 'INFO: Temporary server: %s\n' "$server_url"

    start_stage "Create skill test session"

    printf '{"title":"Skill loading integration test"}\n' \
        > "$sandbox/create-session.json"

    api POST /session \
        "$sandbox/session.json" \
        "$sandbox/create-session.json" ||
        fail "Could not create session"

    if ! session_id="$(
        jq -er '.id | select(type == "string" and length > 0)' \
            "$sandbox/session.json"
    )"; then
        fail "Session response did not contain an ID"
    fi

    start_stage "Request loading of integration-probe"

    jq -n '{
        agent: "integration-skill",
        parts: [
            {
                type: "text",
                text: (
                    "Execute the skill tool with " +
                    "{\"name\":\"integration-probe\"} now. " +
                    "An actual tool invocation is required."
                )
            }
        ]
    }' > "$sandbox/prompt-request.json"

    api POST "/session/$session_id/message" \
        "$sandbox/prompt-response.json" \
        "$sandbox/prompt-request.json" \
        2> "$sandbox/prompt.stderr" &
    request_pid=$!

    start_stage "Verify completed skill tool output"

    while :; do
        kill -0 "$server_pid" 2>/dev/null ||
            fail "Temporary server exited"

        # Reap first, then fetch fresh session data to avoid stale reads.
        if [[ -n "$request_pid" ]] &&
            ! kill -0 "$request_pid" 2>/dev/null; then

            if wait "$request_pid"; then
                request_pid=""
                prompt_finished=true
            else
                request_pid=""
                fail "Prompt HTTP request failed"
            fi
        fi

        api GET "/session/$session_id/message" \
            "$sandbox/messages.json" ||
            fail "Could not read session messages"

        jq -e 'type == "array"' "$sandbox/messages.json" >/dev/null ||
            fail "Invalid session-message response"

        jq '
            [
                .[]
                | select(.info.role == "assistant")
                | .parts[]
                | select(.type == "tool")
            ]
        ' "$sandbox/messages.json" > "$sandbox/tool-parts.json"

        if jq -e '
            any(.[]; .tool != "skill")
        ' "$sandbox/tool-parts.json" >/dev/null; then
            fail "Agent invoked an unrelated tool"
        fi

        if jq -e '
            any(.[];
                .state.input.name? != null
                and .state.input.name != "integration-probe"
            )
        ' "$sandbox/tool-parts.json" >/dev/null; then
            fail "Agent requested an unexpected skill"
        fi

        if jq -e '
            any(.[]; .state.status == "error")
        ' "$sandbox/tool-parts.json" >/dev/null; then
            fail "Skill tool execution failed; see tool-parts.json"
        fi

        if jq -e '
            any(.[];
                .info.role == "assistant"
                and .info.error != null
            )
        ' "$sandbox/messages.json" >/dev/null; then
            fail "Assistant returned an error"
        fi

        # Match only completed tool output, never reasoning,
        # assistant text, descriptions, or tool arguments.
        jq --arg marker "$marker" '
            [
                .[]
                | select(
                    .tool == "skill"
                    and .state.input.name == "integration-probe"
                    and .state.status == "completed"
                    and (
                        (.state.output // "")
                        | if type == "string"
                          then contains($marker)
                          else false
                          end
                    )
                )
            ]
        ' "$sandbox/tool-parts.json" > "$sandbox/matching-loads.json"

        if jq -e 'length > 0' \
            "$sandbox/matching-loads.json" >/dev/null; then

            jq '.[0]' "$sandbox/matching-loads.json" \
                > "$sandbox/skill-result.json"

            printf 'PASS: OpenCode loaded integration-probe\n'
            printf 'INFO: Session: %s\n' "$session_id"
            printf 'INFO: Skill-body marker verified: %s\n' "$marker"
            printf 'INFO: Worker elapsed time: %ss\n' "$SECONDS"
            return 0
        fi

        if jq -e '
            any(.[];
                .tool == "skill"
                and .state.input.name == "integration-probe"
                and .state.status == "completed"
            )
        ' "$sandbox/tool-parts.json" >/dev/null; then
            fail "Skill loaded but tool output lacks the expected body marker"
        fi

        if [[ "$prompt_finished" == true ]]; then
            diagnose_no_load
        fi

        sleep 0.2
    done
}

export -f skill_worker

printf 'INFO: Ollama endpoint: %s\n' "$ollama_url"
printf 'INFO: Model: %s\n' "$model"
printf 'INFO: Declared context window: 1024 tokens\n'
printf 'INFO: Output allowance: 256 tokens\n'
printf 'INFO: Overall worker deadline: %ss\n' "$timeout_seconds"

if BASH_ENV=/dev/null ENV=/dev/null \
    timeout --signal=TERM --kill-after=2s "${timeout_seconds}s" \
        bash --noprofile --norc -c \
            'skill_worker "$@"' skill-worker \
            "$opencode_path" \
            "$ollama_url" \
            "$model" \
            "$sandbox" \
            "$timeout_seconds"; then
    exit 0
else
    status=$?
fi

if [[ "$status" == 124 || "$status" == 137 ]]; then
    stage="$(cat "$sandbox/stage" 2>/dev/null || true)"
    printf 'FAIL: Deadline exceeded during: %s\n' \
        "${stage:-worker startup}" >&2
    status=124
fi

for log in \
    server.log \
    prompt.stderr \
    prompt-response.json \
    messages.json \
    tool-parts.json; do

    if [[ -s "$sandbox/$log" ]]; then
        printf '\n--- %s (last 30 lines) ---\n' "$log" >&2
        tail -n 30 -- "$sandbox/$log" >&2
    fi
done

exit "$status"
