#!/usr/bin/env bash
#
# Standalone OpenCode <-> Ollama integration test.
#
# Assumptions:
#   - Earlier tests verified OpenCode and Ollama availability.
#   - The selected Ollama model is already installed.
#
# Defaults:
#   Ollama: http://127.0.0.1:11434
#   Model:  qwen3:0.6b
#   Budget: 30 seconds for the entire integration worker
#   Retries: 1 extra attempt for transient model flakes (0-3)
#
# Retry behavior:
#   An attempt that fails with exit 1 (transient model behavior such as
#   an empty assistant response) is retried up to --retries times with a
#   fresh sandbox. Setup errors (2), deadline expiry (124/137), and
#   signals (130/143) are never retried. Worst-case wall time is
#   (1 + retries) x budget seconds.
#
# Dependencies:
#   Linux, Bash 4+, GNU timeout, GNU sed, curl, jq,
#   OpenCode, and the supplied optparse.bash.
#
# Exit codes:
#   0   = integration passed
#   1   = integration failed
#   2   = invalid setup or missing dependency
#   124 = overall deadline exceeded
#
# optparse.bash itself exits 1 for parsing errors.

set -eo pipefail

setup_error() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PARSER="$SCRIPT_DIR/optparse.bash"

[[ -r "$PARSER" ]] || setup_error "Cannot read parser: $PARSER"

parser_file=""
keep_artifacts=false
sandboxes=()

cleanup() {
    local status=$?
    local path
    trap - EXIT

    [[ -z "$parser_file" ]] || rm -f -- "$parser_file"

    if ((${#sandboxes[@]} > 0)); then
        if [[ "$keep_artifacts" == true ]]; then
            for path in "${sandboxes[@]}"; do
                printf 'INFO: Test artifacts retained at %s\n' "$path" >&2
            done
        else
            rm -rf -- "${sandboxes[@]}"
        fi
    fi

    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The supplied parser references variables that may be unset,
# so enable nounset only after parsing.
source "$PARSER"

optparse.define short=u long=ollama-url \
    variable=ollama_url default=http://127.0.0.1:11434 \
    desc="Ollama server root URL, without /v1"

optparse.define short=m long=model \
    variable=model default=qwen3:0.6b \
    desc="Exact installed Ollama model name"

optparse.define short=t long=timeout \
    variable=timeout_seconds default=30 \
    desc="Overall integration deadline in seconds"

optparse.define short=b long=binary \
    variable=opencode_binary default=opencode \
    desc="OpenCode executable name or path"

optparse.define short=k long=keep-artifacts \
    variable=keep_artifacts value=true \
    desc="Keep temporary configuration and logs"

optparse.define short=r long=retries \
    variable=retries default=1 \
    desc="Extra attempts after an integration failure (0-3)"

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

for dependency in timeout curl jq bash grep; do
    command -v "$dependency" >/dev/null 2>&1 ||
        setup_error "Missing dependency: $dependency"
done

timeout --version 2>/dev/null | grep -q 'GNU coreutils' ||
    setup_error "GNU timeout is required"

[[ "$timeout_seconds" =~ ^[0-9]{1,5}$ ]] ||
    setup_error "Timeout must be an integer between 1 and 86400"

timeout_seconds=$((10#$timeout_seconds))
((timeout_seconds >= 1 && timeout_seconds <= 86400)) ||
    setup_error "Timeout must be between 1 and 86400 seconds"

[[ "$retries" =~ ^[0-9]$ ]] ||
    setup_error "Retries must be an integer between 0 and 3"

retries=$((10#$retries))
((retries <= 3)) ||
    setup_error "Retries must be between 0 and 3"

# Accept a direct server origin only: no authentication, path,
# query parameters, or fragment. Bracketed IPv6 is supported.
while [[ "$ollama_url" == */ ]]; do
    ollama_url="${ollama_url%/}"
done

url_pattern='^https?://(\[[0-9A-Fa-f:.%]+\]|[A-Za-z0-9._-]+)(:[0-9]{1,5})?$'

[[ "$ollama_url" =~ $url_pattern ]] ||
    setup_error \
        "Use a server root such as http://127.0.0.1:11434; no auth or paths"

[[ "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] ||
    setup_error "Invalid model name"

# Refuse managed configuration rather than silently merging it.
[[ ! -e /etc/opencode ]] ||
    setup_error \
        "/etc/opencode exists; use an environment without managed configuration"

# Resolve the executable, but do not repeat the earlier runtime/version test.
opencode_path="$(type -P -- "$opencode_binary" || true)"

[[ -n "$opencode_path" && -f "$opencode_path" && -x "$opencode_path" ]] ||
    setup_error "OpenCode executable not found: $opencode_binary"

if [[ "$opencode_path" != /* ]]; then
    opencode_path="$PWD/$opencode_path"
fi

integration_worker() {
    set -euo pipefail
    SECONDS=0

    local opencode_path="$1"
    local ollama_url="$2"
    local model="$3"
    local sandbox="$4"
    local timeout_seconds="$5"

    local provider="ollama-test"
    local selected_model="$provider/$model"
    local stage=""
    local digest=""
    local marker=""
    local prompt=""
    local reply=""
    local finish_reason=""
    local status=0

    fail() {
        printf 'FAIL: [%s] %s\n' "$stage" "$*" >&2
        exit 1
    }

    start_stage() {
        stage="$1"
        printf '%s\n' "$stage" > "$sandbox/stage"
        printf 'INFO: [%ss] %s\n' "$SECONDS" "$stage"
    }

    mkdir -p \
        "$sandbox/home" \
        "$sandbox/config/opencode" \
        "$sandbox/data" \
        "$sandbox/cache" \
        "$sandbox/state" \
        "$sandbox/work"

    # Only explicitly listed variables reach OpenCode.
    local -a opencode_env=(
        env -i
        "PATH=$PATH"
        "HOME=$sandbox/home"
        "XDG_CONFIG_HOME=$sandbox/config"
        "XDG_DATA_HOME=$sandbox/data"
        "XDG_CACHE_HOME=$sandbox/cache"
        "XDG_STATE_HOME=$sandbox/state"
        "TMPDIR=$sandbox"
        "TERM=dumb"
        "NO_COLOR=1"
        "NO_PROXY=*"
        "no_proxy=*"
        "OPENCODE_CONFIG=$sandbox/opencode.json"
        "OPENCODE_CONFIG_DIR=$sandbox/config/opencode"
        "OPENCODE_DISABLE_PROJECT_CONFIG=true"
        "OPENCODE_DISABLE_CLAUDE_CODE=true"
        "OPENCODE_DISABLE_EXTERNAL_SKILLS=true"
        "OPENCODE_DISABLE_DEFAULT_PLUGINS=true"
        "OPENCODE_PURE=true"
        "OPENCODE_DISABLE_AUTOUPDATE=true"
        "OPENCODE_DISABLE_MODELS_FETCH=true"
        "OPENCODE_DISABLE_LSP_DOWNLOAD=true"
        "OPENCODE_DISABLE_AUTOCOMPACT=true"
        "OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=128"
    )

    run_opencode() (
        cd -- "$sandbox/work"
        exec "${opencode_env[@]}" "$opencode_path" "$@" </dev/null
    )

    # Make a direct JSON API request without curl configuration,
    # proxy routing, or redirects.
    request_json() {
        local method="$1"
        local path="$2"
        local destination="$3"
        local request_file="${4:-}"
        local http_status=""

        local -a curl_args=(
            --disable
            --silent
            --show-error
            --noproxy '*'
            --globoff
            --connect-timeout 3
            --max-time "$timeout_seconds"
            --request "$method"
            --output "$destination"
            --write-out '%{http_code}'
        )

        if [[ -n "$request_file" ]]; then
            curl_args+=(
                --header 'Content-Type: application/json'
                --data-binary "@$request_file"
            )
        fi

        if http_status="$(
            curl "${curl_args[@]}" "$ollama_url$path"
        )"; then
            [[ "$http_status" == 200 ]] ||
                fail "$path returned HTTP $http_status; expected 200"
        else
            status=$?
            fail "Request to $path failed (curl exit $status)"
        fi
    }

    start_stage "Generate isolated configuration"

    jq -n \
        --arg provider "$provider" \
        --arg model "$model" \
        --arg selected "$selected_model" \
        --arg base_url "$ollama_url/v1" \
        --argjson request_timeout "$((timeout_seconds * 1000))" \
        '{
            "$schema": "https://opencode.ai/config.json",
            model: $selected,
            small_model: $selected,
            enabled_providers: [$provider],
            autoupdate: false,
            snapshot: false,
            share: "disabled",
            plugin: [],
            mcp: {},
            instructions: [],
            permission: {"*": "deny"},
            compaction: {auto: false},
            provider: {
                ($provider): {
                    npm: "@ai-sdk/openai-compatible",
                    name: "Integration test Ollama",
                    options: {
                        baseURL: $base_url,
                        timeout: $request_timeout
                    },
                    models: {
                        ($model): {
                            name: $model,
                            limit: {
                                context: 8192,
                                output: 128
                            }
                        }
                    }
                }
            },
            agent: {
                "integration-test": {
                    description: "Text-only connectivity test",
                    mode: "primary",
                    model: $selected,
                    temperature: 0,
                    steps: 1,
                    prompt: (
                        "You are a text-only connectivity test. " +
                        "Follow the user instruction directly. " +
                        "Do not use tools. Do not explain your answer."
                    ),
                    tools: {"*": false},
                    permission: {"*": "deny"}
                }
            }
        }' > "$sandbox/opencode.json"

    start_stage "Check exact installed model"

    request_json GET /api/tags "$sandbox/models.json"

    if ! digest="$(
        jq -er --arg model "$model" '
            [
                .models[]
                | select(.name == $model or .model == $model)
            ]
            | first
            | .digest
            | select(type == "string" and length > 0)
        ' "$sandbox/models.json"
    )"; then
        fail "Exact model '$model' is not installed; provision it separately"
    fi

    jq -n --arg model "$model" '{model: $model}' \
        > "$sandbox/show-request.json"

    request_json POST /api/show \
        "$sandbox/model-info.json" \
        "$sandbox/show-request.json"

    jq -e '
        type == "object"
        and ((.remote_host // "") == "")
        and ((.remote_model // "") == "")
    ' "$sandbox/model-info.json" >/dev/null ||
        fail "Invalid model metadata or a remote/cloud-backed model"

    printf 'PASS: Installed model: %s\n' "$model"
    printf 'INFO: Model digest: %s\n' "$digest"

    start_stage "Submit marker through OpenCode"

    marker="integration-ok-$(cat /proc/sys/kernel/random/uuid)"
    prompt="Reply with exactly this text: $marker
Do not use tools. Do not add an explanation."

    printf '%s\n' "$marker" > "$sandbox/marker.txt"
    printf '%s\n' "$prompt" > "$sandbox/prompt.txt"

    if run_opencode run \
        --model "$selected_model" \
        --agent integration-test \
        --format json \
        --title "Ollama integration test" \
        -- "$prompt" \
        > "$sandbox/events.jsonl" \
        2> "$sandbox/run.stderr"; then
        :
    else
        status=$?
        fail "OpenCode prompt execution failed (exit $status)"
    fi

    start_stage "Validate structured response"

    # Separate JSON validity from event and completion validation.
    if ! jq -e -s '
        length > 0
        and all(.[]; type == "object")
    ' "$sandbox/events.jsonl" >/dev/null; then
        fail "Malformed JSON, empty event stream, or non-object events"
    fi

    if jq -e -s '
        any(.[];
            .type == "error"
            or .type == "tool_use"
            or .type == "tool_result"
            or .part.type? == "tool"
        )
    ' "$sandbox/events.jsonl" >/dev/null; then
        fail "OpenCode returned an error event or attempted tool activity"
    fi

    if ! finish_reason="$(
        jq -er -s '
            [
                .[]
                | select(.type == "step_finish")
            ]
            | last
            | .part.reason
            | select(type == "string" and length > 0)
        ' "$sandbox/events.jsonl"
    )"; then
        fail "No step_finish event with a finish reason"
    fi

    # Token-limited output is acceptable for this connectivity test
    # only if the full marker is present in the assistant text below.
    case "$finish_reason" in
        stop|length)
            ;;
        *)
            fail "Unexpected completion reason: $finish_reason"
            ;;
    esac

    if reply="$(
        jq -er -s '
            [
                .[]
                | select(.type == "text")
                | .part.text
                | select(type == "string")
            ]
            | join("")
            | select(test("\\S"))
        ' "$sandbox/events.jsonl"
    )"; then
        printf '%s\n' "$reply" > "$sandbox/response.txt"
    else
        fail "No nonempty assistant text response"
    fi

    [[ "$reply" == *"$marker"* ]] ||
        fail "Assistant text does not contain this run's complete marker"

    if [[ "$finish_reason" == length ]]; then
        printf '%s\n' \
            'WARN: Output token limit reached; complete marker was received' >&2
    fi

    printf 'PASS: OpenCode -> Ollama -> OpenCode round trip\n'
    printf 'INFO: Completion reason: %s\n' "$finish_reason"
    printf 'INFO: Assistant response: %s\n' "$reply"
    printf 'INFO: Worker elapsed time: %ss\n' "$SECONDS"
}

export -f integration_worker

printf 'INFO: Endpoint: %s\n' "$ollama_url"
printf 'INFO: Model: %s\n' "$model"
printf 'INFO: Worker deadline: %ss per attempt\n' "$timeout_seconds"

# Each attempt gets the full budget: one deadline covers configuration
# generation, model verification, OpenCode execution, and response
# validation. Worst-case wall time is (1 + retries) x budget.
#
# Prevent inherited shell startup hooks from running in the worker.
# Forced termination may add up to two seconds beyond the deadline.
total_attempts=$((1 + retries))
status=0

for ((attempt = 1; attempt <= total_attempts; attempt++)); do
    sandbox="$(mktemp -d /tmp/opencode-ollama-test.XXXXXXXX)"
    sandboxes+=("$sandbox")

    printf 'INFO: Attempt %d/%d\n' "$attempt" "$total_attempts"

    if BASH_ENV=/dev/null ENV=/dev/null \
        timeout --signal=TERM --kill-after=2s "${timeout_seconds}s" \
            bash --noprofile --norc -c \
                'integration_worker "$@"' integration-worker \
                "$opencode_path" \
                "$ollama_url" \
                "$model" \
                "$sandbox" \
                "$timeout_seconds"; then
        if ((attempt > 1)); then
            printf 'INFO: Passed on attempt %d/%d\n' \
                "$attempt" "$total_attempts"
        fi
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

    # Only transient integration failures (exit 1) are retried; setup
    # errors, deadline expiry, and signals are not.
    if [[ "$status" != 1 ]] || ((attempt == total_attempts)); then
        break
    fi

    printf 'WARN: Attempt %d/%d failed (exit %d); retrying\n' \
        "$attempt" "$total_attempts" "$status" >&2

    # A failed intermediate attempt's sandbox is removed immediately.
    rm -rf -- "$sandbox"
done

# Print bounded diagnostics for the final attempt before default
# cleanup removes the files.
for log in run.stderr events.jsonl response.txt; do
    if [[ -s "$sandbox/$log" ]]; then
        printf '\n--- %s (last 40 lines) ---\n' "$log" >&2
        tail -n 40 -- "$sandbox/$log" >&2
    fi
done

exit "$status"
