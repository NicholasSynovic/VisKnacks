#!/usr/bin/env bash
# Explicit OpenCode subagent integration test.
#
# Dispatch is configuration-driven, not model-selected:
#   custom command -> subtask:true -> integration-child
#
# Assumptions:
#   - Earlier tests verified OpenCode and Ollama availability.
#   - The selected Ollama model is already installed.
#
# Dependencies:
#   Linux, Bash 4+, GNU timeout, GNU sed, curl, jq, setsid,
#   OpenCode, and the supplied optparse.bash.
#
# Defaults:
#   Ollama: http://127.0.0.1:11434
#   Model:  qwen3.5:0.8b
#   Overall worker deadline: 30 seconds
#
# Exit codes:
#   0   = passed
#   1   = integration failure
#   2   = invalid setup
#   124 = deadline exceeded
#
# optparse.bash itself exits 1 for parsing errors.

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

# Enable nounset only after running the supplied parser.
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

# Direct server origin only: no credentials, paths, query, or fragment.
url_pattern='^https?://(\[[0-9A-Fa-f:.%]+\]|[A-Za-z0-9._-]+)(:[0-9]{1,5})?$'

[[ "$ollama_url" =~ $url_pattern ]] ||
    setup_error \
        "Use a direct server root URL without credentials or paths"

[[ "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] ||
    setup_error "Invalid model name"

[[ ! -e /etc/opencode ]] ||
    setup_error \
        "/etc/opencode exists; use an environment without managed config"

# Resolve the executable without repeating its version/runtime test.
opencode_path="$(type -P -- "$opencode_binary" || true)"

[[ -n "$opencode_path" && -f "$opencode_path" && -x "$opencode_path" ]] ||
    setup_error "OpenCode executable not found: $opencode_binary"

if [[ "$opencode_path" != /* ]]; then
    opencode_path="$PWD/$opencode_path"
fi

sandbox="$(mktemp -d /tmp/opencode-subagent-test.XXXXXXXX)"

subagent_worker() {
    set -euo pipefail
    SECONDS=0

    local binary="$1"
    local ollama_url="$2"
    local model="$3"
    local sandbox="$4"
    local budget="$5"

    local stage=""
    local server_url=""
    local parent_id=""
    local child_id=""
    local run_id=""
    local marker=""
    local reply=""
    local finish_reason=""
    local selected_model="ollama-test/$model"
    local command_finished=false

    # EXIT traps must retain these after function-local scope unwinds.
    # These globals exist only in this separate worker Bash process.
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
            # setsid creates a process group whose ID is server_pid.
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

    start_stage "Generate isolated subagent configuration"

    mkdir -p \
        "$sandbox/home" \
        "$sandbox/config/opencode" \
        "$sandbox/data" \
        "$sandbox/cache" \
        "$sandbox/state" \
        "$sandbox/work"

    run_id="$(cat /proc/sys/kernel/random/uuid)"
    marker="sa-${run_id:0:8}"
    printf '%s\n' "$marker" > "$sandbox/marker.txt"

    jq -n \
        --arg selected "$selected_model" \
        --arg model "$model" \
        --arg base_url "$ollama_url/v1" \
        --argjson request_timeout "$((budget * 1000))" \
        '{
            "$schema": "https://opencode.ai/config.json",
            model: $selected,
            small_model: $selected,
            default_agent: "integration-parent",
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
                                context: 8192,
                                output: 512
                            }
                        }
                    }
                }
            },
            agent: {
                "integration-parent": {
                    mode: "primary",
                    model: $selected,
                    prompt: (
                        "This session hosts an explicitly invoked test command."
                    ),
                    permission: {"*": "deny"}
                },
                "integration-child": {
                    description: "Text-only explicit subagent test",
                    mode: "subagent",
                    model: $selected,
                    temperature: 0,
                    prompt: (
                        "Return the marker supplied in the task unchanged. " +
                        "Do not use tools or add explanations."
                    ),
                    tools: {"*": false},
                    permission: {"*": "deny"}
                }
            },
            command: {
                "integration-subagent": {
                    description: "Explicitly launch integration-child",
                    agent: "integration-child",
                    model: $selected,
                    subtask: true,
                    template: (
                        "Reply with exactly this marker: $ARGUMENTS\n" +
                        "Do not use tools or explain your answer.\n/no_think"
                    )
                }
            }
        }' > "$sandbox/opencode.json"

    start_stage "Start temporary OpenCode server"

    (
        cd -- "$sandbox/work"

        # Dedicated process group allows cleanup of server descendants.
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
            "OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=512" \
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

    start_stage "Create parent session"

    printf '{"title":"Explicit subagent integration test"}\n' \
        > "$sandbox/create-session.json"

    api POST /session \
        "$sandbox/parent.json" \
        "$sandbox/create-session.json" ||
        fail "Could not create parent session"

    if ! parent_id="$(
        jq -er '.id | select(type == "string" and length > 0)' \
            "$sandbox/parent.json"
    )"; then
        fail "Parent response did not contain a session ID"
    fi

    start_stage "Explicitly invoke integration-child"

    jq -n --arg marker "$marker" '{
        agent: "integration-parent",
        command: "integration-subagent",
        arguments: $marker
    }' > "$sandbox/command-request.json"

    # The command selects the child in configuration.
    # The parent model is not asked to choose or launch an agent.
    api POST "/session/$parent_id/command" \
        "$sandbox/command-response.json" \
        "$sandbox/command-request.json" \
        2> "$sandbox/command.stderr" &
    request_pid=$!

    start_stage "Verify child session and assistant response"

    while :; do
        kill -0 "$server_pid" 2>/dev/null ||
            fail "Temporary server exited"

        # Reap a finished command before fetching the latest child data.
        # This avoids checking stale data immediately after completion.
        if [[ -n "$request_pid" ]] &&
            ! kill -0 "$request_pid" 2>/dev/null; then

            if wait "$request_pid"; then
                request_pid=""
                command_finished=true
            else
                request_pid=""
                fail "Explicit command request failed"
            fi
        fi

        api GET "/session/$parent_id/children" \
            "$sandbox/children.json" ||
            fail "Could not list child sessions"

        jq -e 'type == "array"' \
            "$sandbox/children.json" >/dev/null ||
            fail "Invalid child-session response"

        local child_count
        child_count="$(
            jq --arg parent "$parent_id" '
                [
                    .[]
                    | select(.parentID == $parent)
                ] | length
            ' "$sandbox/children.json"
        )"

        ((child_count <= 1)) ||
            fail "Expected one child session; found $child_count"

        child_id="$(
            jq -r --arg parent "$parent_id" '
                [
                    .[]
                    | select(.parentID == $parent)
                ]
                | first
                | .id // empty
            ' "$sandbox/children.json"
        )"

        if [[ -n "$child_id" ]]; then
            api GET "/session/$child_id/message" \
                "$sandbox/child-messages.json" ||
                fail "Could not read child messages"

            jq -e 'type == "array"' \
                "$sandbox/child-messages.json" >/dev/null ||
                fail "Invalid child-message response"

            if jq -e '
                any(.[];
                    .info.role == "assistant"
                    and .info.agent == "integration-child"
                    and .info.error != null
                )
            ' "$sandbox/child-messages.json" >/dev/null; then
                fail "Child assistant returned an error"
            fi

            if jq -e '
                any(.[].parts[]?; .type == "tool")
            ' "$sandbox/child-messages.json" >/dev/null; then
                fail "Child attempted unexpected tool activity"
            fi

            if jq -e '
                any(.[];
                    .info.role == "assistant"
                    and .info.agent == "integration-child"
                    and .info.time.completed != null
                )
            ' "$sandbox/child-messages.json" >/dev/null; then

                jq '
                    [
                        .[]
                        | select(
                            .info.role == "assistant"
                            and .info.agent == "integration-child"
                            and .info.time.completed != null
                        )
                    ] | last
                ' "$sandbox/child-messages.json" \
                    > "$sandbox/child-result.json"

                finish_reason="$(
                    jq -r '.info.finish // empty' \
                        "$sandbox/child-result.json"
                )"

                case "$finish_reason" in
                    stop|length)
                        ;;
                    *)
                        fail \
                            "Unexpected child finish reason: ${finish_reason:-missing}"
                        ;;
                esac

                # Reasoning is deliberately excluded.
                reply="$(
                    jq -r '
                        [
                            .parts[]
                            | select(.type == "text")
                            | .text
                            | select(type == "string")
                        ] | join("")
                    ' "$sandbox/child-result.json"
                )"

                printf '%s\n' "$reply" > "$sandbox/response.txt"

                [[ -n "${reply//[[:space:]]/}" ]] ||
                    fail \
                        "Child launched but returned no final text (finish=$finish_reason)"

                [[ "$reply" == *"$marker"* ]] ||
                    fail \
                        "Child launched but final text lacks the complete marker"

                break
            fi
        fi

        if [[ "$command_finished" == true ]]; then
            fail \
                "Command finished without a completed matching child response"
        fi

        sleep 0.2
    done

    if [[ "$finish_reason" == length ]]; then
        printf '%s\n' \
            'WARN: Child reached the token cap after returning the marker' >&2
    fi

    printf 'PASS: Explicit subagent invocation succeeded\n'
    printf 'INFO: Parent session: %s\n' "$parent_id"
    printf 'INFO: Child session: %s\n' "$child_id"
    printf 'INFO: Agent: integration-child\n'
    printf 'INFO: Completion reason: %s\n' "$finish_reason"
    printf 'INFO: Child response: %s\n' "$reply"
    printf 'INFO: Worker elapsed time: %ss\n' "$SECONDS"
}

export -f subagent_worker

printf 'INFO: Ollama endpoint: %s\n' "$ollama_url"
printf 'INFO: Model: %s\n' "$model"
printf 'INFO: Overall worker deadline: %ss\n' "$timeout_seconds"

# One deadline covers configuration, temporary-server startup,
# explicit invocation, and child-response validation.
#
# Cleanup has a two-second forced-termination grace period.
if BASH_ENV=/dev/null ENV=/dev/null \
    timeout --signal=TERM --kill-after=2s "${timeout_seconds}s" \
        bash --noprofile --norc -c \
            'subagent_worker "$@"' subagent-worker \
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
    command.stderr \
    command-response.json \
    child-messages.json \
    response.txt; do

    if [[ -s "$sandbox/$log" ]]; then
        printf '\n--- %s (last 30 lines) ---\n' "$log" >&2
        tail -n 30 -- "$sandbox/$log" >&2
    fi
done

exit "$status"pencode_binary default=opencode \
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

# Direct server origin only: no credentials, paths, query, or fragment.
url_pattern='^https?://(\[[0-9A-Fa-f:.%]+\]|[A-Za-z0-9._-]+)(:[0-9]{1,5})?$'

[[ "$ollama_url" =~ $url_pattern ]] ||
    setup_error \
        "Use a direct server root URL without credentials or paths"

[[ "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] ||
    setup_error "Invalid model name"

[[ ! -e /etc/opencode ]] ||
    setup_error \
        "/etc/opencode exists; use an environment without managed config"

# Resolve the executable without repeating its version/runtime test.
opencode_path="$(type -P -- "$opencode_binary" || true)"

[[ -n "$opencode_path" && -f "$opencode_path" && -x "$opencode_path" ]] ||
    setup_error "OpenCode executable not found: $opencode_binary"

if [[ "$opencode_path" != /* ]]; then
    opencode_path="$PWD/$opencode_path"
fi

sandbox="$(mktemp -d /tmp/opencode-subagent-test.XXXXXXXX)"

subagent_worker() {
    set -euo pipefail
    SECONDS=0

    local binary="$1"
    local ollama_url="$2"
    local model="$3"
    local sandbox="$4"
    local budget="$5"

    local stage=""
    local server_url=""
    local parent_id=""
    local child_id=""
    local run_id=""
    local marker=""
    local reply=""
    local finish_reason=""
    local selected_model="ollama-test/$model"
    local command_finished=false

    # EXIT traps must retain these after function-local scope unwinds.
    # These globals exist only in this separate worker Bash process.
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
            # setsid creates a process group whose ID is server_pid.
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

    start_stage "Generate isolated subagent configuration"

    mkdir -p \
        "$sandbox/home" \
        "$sandbox/config/opencode" \
        "$sandbox/data" \
        "$sandbox/cache" \
        "$sandbox/state" \
        "$sandbox/work"

    run_id="$(cat /proc/sys/kernel/random/uuid)"
    marker="sa-${run_id:0:8}"
    printf '%s\n' "$marker" > "$sandbox/marker.txt"

    jq -n \
        --arg selected "$selected_model" \
        --arg model "$model" \
        --arg base_url "$ollama_url/v1" \
        --argjson request_timeout "$((budget * 1000))" \
        '{
            "$schema": "https://opencode.ai/config.json",
            model: $selected,
            small_model: $selected,
            default_agent: "integration-parent",
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
                                context: 8192,
                                output: 512
                            }
                        }
                    }
                }
            },
            agent: {
                "integration-parent": {
                    mode: "primary",
                    model: $selected,
                    prompt: (
                        "This session hosts an explicitly invoked test command."
                    ),
                    permission: {"*": "deny"}
                },
                "integration-child": {
                    description: "Text-only explicit subagent test",
                    mode: "subagent",
                    model: $selected,
                    temperature: 0,
                    prompt: (
                        "Return the marker supplied in the task unchanged. " +
                        "Do not use tools or add explanations."
                    ),
                    tools: {"*": false},
                    permission: {"*": "deny"}
                }
            },
            command: {
                "integration-subagent": {
                    description: "Explicitly launch integration-child",
                    agent: "integration-child",
                    model: $selected,
                    subtask: true,
                    template: (
                        "Reply with exactly this marker: $ARGUMENTS\n" +
                        "Do not use tools or explain your answer.\n/no_think"
                    )
                }
            }
        }' > "$sandbox/opencode.json"

    start_stage "Start temporary OpenCode server"

    (
        cd -- "$sandbox/work"

        # Dedicated process group allows cleanup of server descendants.
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
            "OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=512" \
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

    start_stage "Create parent session"

    printf '{"title":"Explicit subagent integration test"}\n' \
        > "$sandbox/create-session.json"

    api POST /session \
        "$sandbox/parent.json" \
        "$sandbox/create-session.json" ||
        fail "Could not create parent session"

    if ! parent_id="$(
        jq -er '.id | select(type == "string" and length > 0)' \
            "$sandbox/parent.json"
    )"; then
        fail "Parent response did not contain a session ID"
    fi

    start_stage "Explicitly invoke integration-child"

    jq -n --arg marker "$marker" '{
        agent: "integration-parent",
        command: "integration-subagent",
        arguments: $marker
    }' > "$sandbox/command-request.json"

    # The command selects the child in configuration.
    # The parent model is not asked to choose or launch an agent.
    api POST "/session/$parent_id/command" \
        "$sandbox/command-response.json" \
        "$sandbox/command-request.json" \
        2> "$sandbox/command.stderr" &
    request_pid=$!

    start_stage "Verify child session and assistant response"

    while :; do
        kill -0 "$server_pid" 2>/dev/null ||
            fail "Temporary server exited"

        # Reap a finished command before fetching the latest child data.
        # This avoids checking stale data immediately after completion.
        if [[ -n "$request_pid" ]] &&
            ! kill -0 "$request_pid" 2>/dev/null; then

            if wait "$request_pid"; then
                request_pid=""
                command_finished=true
            else
                request_pid=""
                fail "Explicit command request failed"
            fi
        fi

        api GET "/session/$parent_id/children" \
            "$sandbox/children.json" ||
            fail "Could not list child sessions"

        jq -e 'type == "array"' \
            "$sandbox/children.json" >/dev/null ||
            fail "Invalid child-session response"

        local child_count
        child_count="$(
            jq --arg parent "$parent_id" '
                [
                    .[]
                    | select(.parentID == $parent)
                ] | length
            ' "$sandbox/children.json"
        )"

        ((child_count <= 1)) ||
            fail "Expected one child session; found $child_count"

        child_id="$(
            jq -r --arg parent "$parent_id" '
                [
                    .[]
                    | select(.parentID == $parent)
                ]
                | first
                | .id // empty
            ' "$sandbox/children.json"
        )"

        if [[ -n "$child_id" ]]; then
            api GET "/session/$child_id/message" \
                "$sandbox/child-messages.json" ||
                fail "Could not read child messages"

            jq -e 'type == "array"' \
                "$sandbox/child-messages.json" >/dev/null ||
                fail "Invalid child-message response"

            if jq -e '
                any(.[];
                    .info.role == "assistant"
                    and .info.agent == "integration-child"
                    and .info.error != null
                )
            ' "$sandbox/child-messages.json" >/dev/null; then
                fail "Child assistant returned an error"
            fi

            if jq -e '
                any(.[].parts[]?; .type == "tool")
            ' "$sandbox/child-messages.json" >/dev/null; then
                fail "Child attempted unexpected tool activity"
            fi

            if jq -e '
                any(.[];
                    .info.role == "assistant"
                    and .info.agent == "integration-child"
                    and .info.time.completed != null
                )
            ' "$sandbox/child-messages.json" >/dev/null; then

                jq '
                    [
                        .[]
                        | select(
                            .info.role == "assistant"
                            and .info.agent == "integration-child"
                            and .info.time.completed != null
                        )
                    ] | last
                ' "$sandbox/child-messages.json" \
                    > "$sandbox/child-result.json"

                finish_reason="$(
                    jq -r '.info.finish // empty' \
                        "$sandbox/child-result.json"
                )"

                case "$finish_reason" in
                    stop|length)
                        ;;
                    *)
                        fail \
                            "Unexpected child finish reason: ${finish_reason:-missing}"
                        ;;
                esac

                # Reasoning is deliberately excluded.
                reply="$(
                    jq -r '
                        [
                            .parts[]
                            | select(.type == "text")
                            | .text
                            | select(type == "string")
                        ] | join("")
                    ' "$sandbox/child-result.json"
                )"

                printf '%s\n' "$reply" > "$sandbox/response.txt"

                [[ -n "${reply//[[:space:]]/}" ]] ||
                    fail \
                        "Child launched but returned no final text (finish=$finish_reason)"

                [[ "$reply" == *"$marker"* ]] ||
                    fail \
                        "Child launched but final text lacks the complete marker"

                break
            fi
        fi

        if [[ "$command_finished" == true ]]; then
            fail \
                "Command finished without a completed matching child response"
        fi

        sleep 0.2
    done

    if [[ "$finish_reason" == length ]]; then
        printf '%s\n' \
            'WARN: Child reached the token cap after returning the marker' >&2
    fi

    printf 'PASS: Explicit subagent invocation succeeded\n'
    printf 'INFO: Parent session: %s\n' "$parent_id"
    printf 'INFO: Child session: %s\n' "$child_id"
    printf 'INFO: Agent: integration-child\n'
    printf 'INFO: Completion reason: %s\n' "$finish_reason"
    printf 'INFO: Child response: %s\n' "$reply"
    printf 'INFO: Worker elapsed time: %ss\n' "$SECONDS"
}

export -f subagent_worker

printf 'INFO: Ollama endpoint: %s\n' "$ollama_url"
printf 'INFO: Model: %s\n' "$model"
printf 'INFO: Overall worker deadline: %ss\n' "$timeout_seconds"

# One deadline covers configuration, temporary-server startup,
# explicit invocation, and child-response validation.
#
# Cleanup has a two-second forced-termination grace period.
if BASH_ENV=/dev/null ENV=/dev/null \
    timeout --signal=TERM --kill-after=2s "${timeout_seconds}s" \
        bash --noprofile --norc -c \
            'subagent_worker "$@"' subagent-worker \
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
    command.stderr \
    command-response.json \
    child-messages.json \
    response.txt; do

    if [[ -s "$sandbox/$log" ]]; then
        printf '\n--- %s (last 30 lines) ---\n' "$log" >&2
        tail -n 30 -- "$sandbox/$log" >&2
    fi
done

exit "$status"
