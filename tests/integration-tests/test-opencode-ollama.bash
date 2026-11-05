#!/usr/bin/env bash
#
# OpenCode <-> Ollama integration test.
#
# Assumptions:
#   - Earlier tests verified OpenCode and Ollama availability.
#   - The selected Ollama model is already installed.
#
# Defaults:
#   Ollama: http://127.0.0.1:11434
#   Model:  qwen3.5:0.8b
#   Overall deadline: 30 seconds across ALL attempts
#   Retries: 1 extra attempt, only for empty assistant responses
#
# Each attempt gets fresh OpenCode configuration and state.
# Ollama itself is shared and is not restarted or reset.
#
# Pass condition:
#   Valid completion events and nonempty assistant text containing
#   the complete run-specific marker, ignoring letter case.
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
# Internal worker status:
#   75 = empty assistant response; eligible for retry
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
test_root=""
keep_artifacts=false

cleanup() {
    local status=$?
    trap - EXIT
    set +e

    [[ -z "$parser_file" ]] || rm -f -- "$parser_file"

    if [[ -n "$test_root" ]]; then
        if [[ "$keep_artifacts" == true ]]; then
            printf 'INFO: All attempt artifacts retained at %s\n' \
                "$test_root" >&2
        elif ! rm -rf -- "$test_root"; then
            printf 'WARN: Could not fully remove %s\n' "$test_root" >&2
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
    desc="Ollama server root URL, without /v1"

optparse.define short=m long=model \
    variable=model default=qwen3.5:0.8b \
    desc="Exact installed Ollama model name"

optparse.define short=t long=timeout \
    variable=timeout_seconds default=30 \
    desc="Overall deadline across all attempts in seconds"

optparse.define short=b long=binary \
    variable=opencode_binary default=opencode \
    desc="OpenCode executable name or path"

optparse.define short=k long=keep-artifacts \
    variable=keep_artifacts value=true \
    desc="Keep configuration and logs for every attempt"

optparse.define short=r long=retries \
    variable=retries default=1 \
    desc="Extra attempts for empty assistant responses (0-3)"

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

[[ "$retries" =~ ^[0-3]$ ]] ||
    setup_error "Retries must be an integer between 0 and 3"

retries=$((10#$retries))

while [[ "$ollama_url" == */ ]]; do
    ollama_url="${ollama_url%/}"
done

url_pattern='^https?://(\[[0-9A-Fa-f:.%]+\]|[A-Za-z0-9._-]+)(:[0-9]{1,5})?$'

[[ "$ollama_url" =~ $url_pattern ]] ||
    setup_error \
        "Use a direct server root URL without authentication or paths"

[[ "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] ||
    setup_error "Invalid model name"

[[ ! -e /etc/opencode ]] ||
    setup_error \
        "/etc/opencode exists; use an environment without managed config"

# Resolve the executable without repeating the earlier runtime/version test.
opencode_path="$(type -P -- "$opencode_binary" || true)"

[[ -n "$opencode_path" && -f "$opencode_path" && -x "$opencode_path" ]] ||
    setup_error "OpenCode executable not found: $opencode_binary"

if [[ "$opencode_path" != /* ]]; then
    opencode_path="$PWD/$opencode_path"
fi

test_root="$(mktemp -d /tmp/opencode-ollama-test.XXXXXXXX)"

print_diagnostics() {
    local sandbox="$1"
    local log

    for log in run.stderr events.jsonl response.txt; do
        if [[ -s "$sandbox/$log" ]]; then
            printf '\n--- %s: %s (last 40 lines) ---\n' \
                "${sandbox##*/}" "$log" >&2

            tail -n 40 -- "$sandbox/$log" >&2
        fi
    done
}

integration_worker() {
    set -euo pipefail

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
    local completion_summary=""
    local status=0

    fail() {
        printf 'FAIL: [%s] %s\n' "$stage" "$*" >&2
        exit 1
    }

    start_stage() {
        stage="$1"
        printf '%s\n' "$stage" > "$sandbox/stage"
        printf 'INFO: [%ss overall] %s\n' "$SECONDS" "$stage"
    }

    mkdir -p \
        "$sandbox/home" \
        "$sandbox/config/opencode" \
        "$sandbox/data" \
        "$sandbox/cache" \
        "$sandbox/state" \
        "$sandbox/work"

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

    if ! jq -n \
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
            permission: {
                "*": "deny"
            },
            compaction: {
                auto: false
            },
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
                            options: {
                                reasoningEffort: "none"
                            },
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
                    prompt: (
                        "You are a text-only connectivity test. " +
                        "Follow the user instruction directly. " +
                        "Do not use tools. Do not explain your answer."
                    ),
                    tools: {
                        "*": false
                    },
                    permission: {
                        "*": "deny"
                    }
                }
            }
        }' > "$sandbox/opencode.json"; then

        fail "Could not generate OpenCode configuration"
    fi

    # Validate generated settings, including absence of the step limit.
    if ! jq -e \
        --arg provider "$provider" \
        --arg model "$model" \
        --arg selected "$selected_model" \
        --arg base_url "$ollama_url/v1" \
        '
            .model == $selected
            and .small_model == $selected
            and .provider[$provider].options.baseURL == $base_url
            and (
                .provider[$provider].models[$model].options.reasoningEffort
                == "none"
            )
            and .provider[$provider].models[$model].limit.context == 8192
            and .provider[$provider].models[$model].limit.output == 128
            and (
                .agent["integration-test"]
                | has("steps")
                | not
            )
        ' "$sandbox/opencode.json" >/dev/null; then

        fail "Generated OpenCode configuration failed validation"
    fi

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

    case "$finish_reason" in
        stop|length)
            ;;
        *)
            fail "Unexpected completion reason: $finish_reason"
            ;;
    esac

    # Extract only assistant text events, not reasoning or logs.
    # A jq extraction failure is not eligible for retry.
    if ! reply="$(
        jq -r -s '
            [
                .[]
                | select(.type == "text")
                | .part.text
                | select(type == "string")
            ] | join("")
        ' "$sandbox/events.jsonl"
    )"; then
        fail "Could not extract assistant text"
    fi

    printf '%s\n' "$reply" > "$sandbox/response.txt"

    if [[ -z "${reply//[[:space:]]/}" ]]; then
        completion_summary="$(
            jq -c -s '
                [
                    .[]
                    | select(.type == "step_finish")
                    | {
                        reason: .part.reason,
                        tokens: .part.tokens
                    }
                ] | last
            ' "$sandbox/events.jsonl"
        )"

        printf 'FAIL: [%s] Empty assistant response; completion=%s\n' \
            "$stage" "$completion_summary" >&2

        exit 75
    fi

    # Require the complete marker, but ignore capitalization changes.
    # The original output remains unchanged in response.txt.
    if [[ "${reply,,}" != *"${marker,,}"* ]]; then
        fail "Assistant text does not contain this run's complete marker"
    fi

    if [[ "$finish_reason" == length ]]; then
        printf '%s\n' \
            'WARN: Output token limit reached; complete marker was received' >&2
    fi

    printf 'PASS: OpenCode -> Ollama -> OpenCode round trip\n'
    printf 'INFO: Completion reason: %s\n' "$finish_reason"
    printf 'INFO: Assistant response: %s\n' "$reply"
    printf 'INFO: Overall elapsed time: %ss\n' "$SECONDS"
}

run_attempts() {
    set -euo pipefail
    SECONDS=0

    local binary="$1"
    local ollama_url="$2"
    local model="$3"
    local root="$4"
    local budget="$5"
    local retries="$6"

    local total_attempts=$((1 + retries))
    local attempt
    local sandbox
    local status

    for ((attempt = 1; attempt <= total_attempts; attempt++)); do
        sandbox="$root/attempt-$attempt"
        mkdir -p "$sandbox"

        printf '%s\n' "$attempt" > "$root/current-attempt"
        printf 'INFO: Attempt %d/%d; overall elapsed %ss\n' \
            "$attempt" "$total_attempts" "$SECONDS"

        # Capture the subshell's status without disabling errexit
        # inside integration_worker.
        set +e
        (
            integration_worker \
                "$binary" \
                "$ollama_url" \
                "$model" \
                "$sandbox" \
                "$budget"
        )
        status=$?
        set -e

        printf '%s\n' "$status" > "$sandbox/worker-exit-status"

        if [[ "$status" == 0 ]]; then
            if ((attempt > 1)); then
                printf 'WARN: Passed after %d empty-response failure(s)\n' \
                    "$((attempt - 1))" >&2
            fi
            return 0
        fi

        print_diagnostics "$sandbox"

        if [[ "$status" != 75 ]]; then
            return "$status"
        fi

        if ((attempt == total_attempts)); then
            printf 'FAIL: Empty response persisted after %d attempt(s)\n' \
                "$total_attempts" >&2
            return 1
        fi

        printf '%s\n' \
            'WARN: Retrying empty response within the original overall deadline' >&2
    done

    return 1
}

export -f integration_worker print_diagnostics run_attempts

printf 'INFO: Endpoint: %s\n' "$ollama_url"
printf 'INFO: Model: %s\n' "$model"
printf 'INFO: Declared context window: 8192 tokens\n'
printf 'INFO: Output allowance: 128 tokens\n'
printf 'INFO: Requested reasoning effort: none\n'
printf 'INFO: Marker comparison: case-insensitive\n'
printf 'INFO: Overall deadline: %ss across all attempts\n' "$timeout_seconds"
printf 'INFO: Empty-response retries: %s\n' "$retries"

# One timeout covers the entire retry loop.
# Retries do not reset the deadline.
# Forced termination may add up to two seconds of cleanup grace.
if BASH_ENV=/dev/null ENV=/dev/null \
    timeout --signal=TERM --kill-after=2s "${timeout_seconds}s" \
        bash --noprofile --norc -c \
            'run_attempts "$@"' integration-attempts \
            "$opencode_path" \
            "$ollama_url" \
            "$model" \
            "$test_root" \
            "$timeout_seconds" \
            "$retries"; then
    exit 0
else
    status=$?
fi

if [[ "$status" == 124 || "$status" == 137 ]]; then
    attempt="$(cat "$test_root/current-attempt" 2>/dev/null || true)"

    if [[ "$attempt" =~ ^[1-4]$ ]]; then
        sandbox="$test_root/attempt-$attempt"
        stage="$(cat "$sandbox/stage" 2>/dev/null || true)"

        printf 'FAIL: Overall deadline exceeded during attempt %s: %s\n' \
            "$attempt" "${stage:-attempt startup}" >&2

        print_diagnostics "$sandbox"
    else
        printf 'FAIL: Overall deadline exceeded during worker startup\n' >&2
    fi

    status=124
fi

# Do not expose the internal retry-classification status.
[[ "$status" != 75 ]] || status=1

exit "$status"
