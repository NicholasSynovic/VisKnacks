#!/usr/bin/env bash
#
# Run every integration test in assumption order and report a summary.
#
# Order (each stage assumes the earlier ones passed):
#   1.  test-ollama.bash                    Ollama API reachable
#   2.  test-opencode.bash                  OpenCode CLI smoke
#   3.  test-opencode-ollama.bash           OpenCode -> Ollama run
#   4.  test-opencode-skill.bash            Skill actually loads
#   5.  test-opencode-subagent.bash         Subagent dispatch
#   6.  test-pvpython-env.bash              ParaView binaries present
#   7.  test-pvpython-renderer-cli.bash     Renderer entry point
#   8.  test-pvpython-renderer-handshake.bash
#   9.  test-pvpython-renderer-tools.bash
#   10. test-pvpython-renderer-execute.bash
#   11. test-pvpython-renderer-render.bash
#   12. test-opencode-renderer-discovery.bash
#   13. test-opencode-renderer-execute.bash
#   14. test-opencode-renderer-render.bash
#
# Each test runs with its own default budget unless --timeout is given.
#
# Dependencies: Bash 4+, GNU timeout (used by the individual tests),
# and the supplied optparse.bash.
#
# Exit codes:
#   0   = all executed tests passed
#   1   = a test failed (exit code of the first failure is preserved)
#   2   = invalid configuration or missing dependency
#   130 = interrupted (SIGINT)
#   143 = terminated (SIGTERM)
#
# optparse.bash itself exits 1 for argument parsing errors.

# Do not enable nounset before loading/running the supplied parser:
# it references variables that may not yet be defined.
set -eo pipefail

setup_error() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PARSER="${SCRIPT_DIR}/optparse.bash"

[[ -r "$PARSER" ]] || setup_error "Cannot read parser: $PARSER"

parser_file=""

trap '[[ -z "$parser_file" ]] || rm -f -- "$parser_file"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

source "$PARSER"

optparse.define short=u long=ollama-url \
    variable=ollama_url default=http://127.0.0.1:11434 \
    desc="Ollama server root URL, without /v1"

optparse.define short=m long=model \
    variable=model default=qwen3.5:0.8b \
    desc="Exact installed Ollama model name"

optparse.define short=b long=opencode-binary \
    variable=opencode_binary default=opencode \
    desc="OpenCode executable name or path"

optparse.define short=y long=python \
    variable=python_binary default=python \
    desc="Python interpreter with mcp for the renderer tests"

optparse.define short=M long=mcp-host \
    variable=mcp_host default=127.0.0.1 \
    desc="Bind hostname for isolated renderer MCP servers"

optparse.define short=P long=mcp-port \
    variable=mcp_port default=0 \
    desc="Bind port for isolated servers; 0 = auto-select free port"

optparse.define short=t long=timeout \
    variable=timeout_seconds default=0 \
    desc="Forwarded per-test deadline in seconds; 0 = per-test defaults"

optparse.define short=r long=retries \
    variable=retries default=1 \
    desc="Extra attempts for the OpenCode->Ollama stage (0-3)"

optparse.define short=k long=keep-artifacts \
    variable=keep_artifacts value=true \
    desc="Keep per-test sandboxes for tests that support it"

optparse.define short=O long=skip-opencode \
    variable=skip_opencode value=true \
    desc="Skip the OpenCode/Ollama stages (tests 2-5, 12-14)"

optparse.define short=C long=skip-mcp \
    variable=skip_mcp value=true \
    desc="Skip the MCP renderer stages (tests 6-14)"

optparse.define short=g long=keep-going \
    variable=keep_going value=true \
    desc="Continue after a failed test instead of stopping"

# Boolean flags are only assigned when the option is passed, so initialize
# them before sourcing the generated parser and enabling nounset.
keep_artifacts=false
skip_opencode=false
skip_mcp=false
keep_going=false

parser_file="$(optparse.build)"
[[ -r "$parser_file" ]] || setup_error "Could not build argument parser"
source "$parser_file"

# getopts leaves OPTIND pointing to any remaining positional arguments.
shift "$((OPTIND - 1))"
[[ $# -eq 0 ]] || setup_error "Unexpected positional argument: $1"

set -u

# ============================================================================
# Validate configuration
# ============================================================================

if command -v timeout >/dev/null 2>&1; then
    :
elif command -v gtimeout >/dev/null 2>&1; then
    :
else
    setup_error "GNU timeout is required (timeout or gtimeout)"
fi

[[ "$timeout_seconds" =~ ^[0-9]{1,5}$ ]] ||
    setup_error "Timeout must be an integer between 0 and 86400"

timeout_seconds=$((10#$timeout_seconds))
((timeout_seconds <= 86400)) ||
    setup_error "Timeout must be between 0 and 86400 seconds"

[[ "$retries" =~ ^[0-9]$ ]] ||
    setup_error "Retries must be an integer between 0 and 3"

retries=$((10#$retries))
((retries <= 3)) ||
    setup_error "Retries must be between 0 and 3"

[[ "$mcp_port" =~ ^[0-9]{1,5}$ ]] ||
    setup_error "MCP port must be an integer between 0 and 65535"

mcp_port=$((10#$mcp_port))
((mcp_port <= 65535)) ||
    setup_error "MCP port must be between 0 and 65535"

# Decompose the Ollama URL into the host/port pair that test-ollama.bash
# expects: scheme://host[:port][/path] with no trailing path allowed.
url_body="${ollama_url#*://}"
[[ "$url_body" != "$ollama_url" ]] ||
    setup_error "Ollama URL must include a scheme: $ollama_url"

url_body="${url_body%%/}"
[[ -n "$url_body" && "$url_body" != */* ]] ||
    setup_error "Ollama URL must not contain a path: $ollama_url"

ollama_host="${url_body%%:*}"
if [[ "$url_body" == *:* ]]; then
    ollama_port="${url_body##*:}"
else
    ollama_port="11434"
fi

# Strip IPv6 brackets: test-ollama.bash brackets bare addresses itself.
ollama_host="${ollama_host#\[}"
ollama_host="${ollama_host%\]}"

[[ -n "$ollama_host" && "$ollama_host" != *[[:space:]/@\?\#]* ]] ||
    setup_error "Ollama URL host must be a hostname or IP: $ollama_url"

[[ "$ollama_port" =~ ^[0-9]{1,5}$ ]] ||
    setup_error "Ollama URL port must be an integer: $ollama_url"

ollama_port=$((10#$ollama_port))
((ollama_port >= 1 && ollama_port <= 65535)) ||
    setup_error "Ollama URL port must be between 1 and 65535: $ollama_url"

# ============================================================================
# Validate pinned tool versions
# ============================================================================

# Stage 1 always exercises Ollama, so its version is checked
# unconditionally; OpenCode is only required when its stages run.
[[ -r "$SCRIPT_DIR/version-check.bash" ]] ||
    setup_error "Cannot read version checker: $SCRIPT_DIR/version-check.bash"

source "$SCRIPT_DIR/version-check.bash"

require_ollama_version "$ollama_url"

if [[ "$skip_opencode" != true ]]; then
    opencode_preflight="$(type -P -- "$opencode_binary" || true)"
    [[ -n "$opencode_preflight" ]] ||
        setup_error "OpenCode executable not found: $opencode_binary"
    require_opencode_version "$opencode_preflight"
fi

if [[ "$skip_mcp" != true ]]; then
    renderer_python="$(type -P -- "$python_binary" || true)"
    [[ -n "$renderer_python" ]] ||
        setup_error "Python interpreter not found: $python_binary"
    require_mcp_version "$renderer_python"

    pvpython_preflight="$(type -P -- pvpython || true)"
    [[ -n "$pvpython_preflight" ]] ||
        setup_error "pvpython not found on PATH"
    require_paraview_version "$pvpython_preflight"
fi

# ============================================================================
# Build the per-test argument lists
# ============================================================================

timeout_args=()
if ((timeout_seconds > 0)); then
    timeout_args=(-t "$timeout_seconds")
fi

keep_args=()
if [[ "$keep_artifacts" == true ]]; then
    keep_args=(-k)
fi

ollama_stage_args=(-u "$ollama_url" -m "$model" -b "$opencode_binary")
renderer_stage_args=(-H "$mcp_host" -p "$mcp_port")
opencode_renderer_args=("${ollama_stage_args[@]}" -p "$python_binary")

run_list=(
    "test-ollama.bash|-H $ollama_host -p $ollama_port ${timeout_args[*]-}"
    "test-opencode.bash|-b $opencode_binary ${timeout_args[*]-}"
    "test-opencode-ollama.bash|${ollama_stage_args[*]} -r $retries ${timeout_args[*]-} ${keep_args[*]-}"
    "test-opencode-skill.bash|${ollama_stage_args[*]} ${timeout_args[*]-} ${keep_args[*]-}"
    "test-opencode-subagent.bash|${ollama_stage_args[*]} ${timeout_args[*]-} ${keep_args[*]-}"
    "test-pvpython-env.bash|${timeout_args[*]-}"
    "test-pvpython-renderer-cli.bash|-b $python_binary ${timeout_args[*]-}"
    "test-pvpython-renderer-handshake.bash|${renderer_stage_args[*]} ${timeout_args[*]-} ${keep_args[*]-}"
    "test-pvpython-renderer-tools.bash|${renderer_stage_args[*]} ${timeout_args[*]-} ${keep_args[*]-}"
    "test-pvpython-renderer-execute.bash|${renderer_stage_args[*]} ${timeout_args[*]-} ${keep_args[*]-}"
    "test-pvpython-renderer-render.bash|${renderer_stage_args[*]} ${timeout_args[*]-} ${keep_args[*]-}"
    "test-opencode-renderer-discovery.bash|${opencode_renderer_args[*]} ${timeout_args[*]-} ${keep_args[*]-}"
    "test-opencode-renderer-execute.bash|${opencode_renderer_args[*]} ${timeout_args[*]-} ${keep_args[*]-}"
    "test-opencode-renderer-render.bash|${opencode_renderer_args[*]} ${timeout_args[*]-} ${keep_args[*]-}"
)

# ============================================================================
# Execute
# ============================================================================

total=${#run_list[@]}
index=0
first_failure_code=0
first_failure_test=""
statuses=()
printf '=== VisKnacks integration tests: %d stages ===\n' "$total"

for entry in "${run_list[@]}"; do
    test_script="${entry%%|*}"
    test_args="${entry#*|}"
    index=$((index + 1))

    # Phase skips, keyed by the assumption order documented above.
    if [[ "$skip_opencode" == true ]] &&
        [[ "$test_script" == test-opencode*.bash ]]; then
        statuses+=("SKIP")
        continue
    fi

    if [[ "$skip_mcp" == true ]] &&
        [[ "$test_script" == test-pvpython*.bash ||
           "$test_script" == test-opencode-renderer-*.bash ]]; then
        statuses+=("SKIP")
        continue
    fi

    [[ -f "$SCRIPT_DIR/$test_script" ]] ||
        setup_error "Test script not found: $SCRIPT_DIR/$test_script"

    printf '\n=== [%d/%d] %s ===\n' "$index" "$total" "$test_script"

    stage_start=$SECONDS
    status=0
    # shellcheck disable=SC2086
    bash "$SCRIPT_DIR/$test_script" $test_args || status=$?
    stage_elapsed=$((SECONDS - stage_start))
    statuses+=("exit $status in ${stage_elapsed}s")

    if [[ "$status" -ne 0 ]]; then
        if [[ -z "$first_failure_test" ]]; then
            first_failure_code="$status"
            first_failure_test="$test_script"
        fi

        if [[ "$keep_going" != true ]]; then
            printf '\nFAIL: %s exited %d; stopping (use --keep-going to continue)\n' \
                "$test_script" "$status" >&2
            break
        fi
    fi
done

# ============================================================================
# Summary
# ============================================================================

printf '\n=== Summary ===\n'
for i in "${!run_list[@]}"; do
    entry="${run_list[$i]}"
    test_script="${entry%%|*}"
    # Stages never reached in fail-fast mode have no status entry.
    printf '%-45s %s\n' "$test_script" "${statuses[$i]:-NOT RUN}"
done

if [[ -n "$first_failure_test" ]]; then
    printf '\nFirst failure: %s (exit %d)\n' \
        "$first_failure_test" "$first_failure_code" >&2
    exit "$first_failure_code"
fi

printf '\nPASS: all executed integration tests passed\n'
