#!/usr/bin/env bash
#
# Check that OpenCode:
#   1. Is available as an executable.
#   2. Runs successfully with --help.
#   3. Returns a nonempty version with --version.
#
# No prompts or model requests are submitted.
#
# Dependencies: Bash 4+, GNU timeout, supplied optparse.bash
#
# Exit codes:
#   0 = all checks passed
#   1 = OpenCode check failed
#   2 = missing dependency or invalid configuration
#
# The supplied optparse.bash exits 1 for parsing errors.

# Enable nounset only after running the supplied parser.
set -eo pipefail

config_error() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PARSER="${SCRIPT_DIR}/optparse.bash"

[[ -r "$PARSER" ]] ||
    config_error "Cannot read parser: $PARSER"

parser_file=""
test_dir=""

cleanup() {
    [[ -z "$parser_file" ]] || rm -f -- "$parser_file"
    [[ -z "$test_dir" ]] || rm -rf -- "$test_dir"
}
trap cleanup EXIT

source "$PARSER"

optparse.define short=b long=binary \
    variable=opencode_binary default=opencode \
    desc="OpenCode executable name or path"

optparse.define short=t long=timeout \
    variable=timeout_seconds default=10 \
    desc="Timeout per check in whole seconds"

parser_file="$(optparse.build)"
[[ -r "$parser_file" ]] ||
    config_error "Could not build argument parser"

source "$parser_file"

shift "$((OPTIND - 1))"
[[ $# -eq 0 ]] ||
    config_error "Unexpected positional argument: $1"

set -u

# Use GNU timeout, or gtimeout when installed under that name.
if command -v timeout >/dev/null 2>&1; then
    timeout_command="$(command -v timeout)"
elif command -v gtimeout >/dev/null 2>&1; then
    timeout_command="$(command -v gtimeout)"
else
    config_error "GNU timeout is required (timeout or gtimeout)"
fi

[[ "$timeout_seconds" =~ ^[0-9]{1,5}$ ]] ||
    config_error "Timeout must be an integer between 1 and 86400"

timeout_seconds=$((10#$timeout_seconds))
((timeout_seconds >= 1 && timeout_seconds <= 86400)) ||
    config_error "Timeout must be between 1 and 86400 seconds"

# Resolve an executable file rather than an alias or shell function.
opencode_path="$(type -P -- "$opencode_binary" || true)"

[[ -n "$opencode_path" && -f "$opencode_path" && -x "$opencode_path" ]] ||
    fail "OpenCode executable not found: $opencode_binary"

# Resolve relative paths before changing the working directory.
if [[ "$opencode_path" != /* ]]; then
    opencode_path="$PWD/$opencode_path"
fi

printf 'PASS: OpenCode is available: %s\n' "$opencode_path"

# Keep test output and any incidental user-level state temporary.
test_dir="$(mktemp -d)"
mkdir -p \
    "$test_dir/home" \
    "$test_dir/config" \
    "$test_dir/data" \
    "$test_dir/cache" \
    "$test_dir/state" \
    "$test_dir/work"

run_opencode() (
    cd -- "$test_dir/work"

    # Do not inherit custom OpenCode environment variables, credentials,
    # provider settings, or the caller's home/XDG directories.
    exec "$timeout_command" --kill-after=2s "${timeout_seconds}s" \
        env -i \
        "PATH=$PATH" \
        "HOME=$test_dir/home" \
        "XDG_CONFIG_HOME=$test_dir/config" \
        "XDG_DATA_HOME=$test_dir/data" \
        "XDG_CACHE_HOME=$test_dir/cache" \
        "XDG_STATE_HOME=$test_dir/state" \
        "TMPDIR=$test_dir" \
        "TERM=dumb" \
        "NO_COLOR=1" \
        "$opencode_path" "$@"
)

# Verify CLI execution, accepting help on stdout or stderr.
if run_opencode --help \
    >"$test_dir/help.out" 2>"$test_dir/help.err"; then

    if [[ ! -s "$test_dir/help.out" && ! -s "$test_dir/help.err" ]]; then
        fail "OpenCode --help exited successfully but returned no output"
    fi

    printf 'PASS: OpenCode runs successfully\n'
else
    status=$?
    cat "$test_dir/help.out" "$test_dir/help.err" >&2
    fail "OpenCode --help failed or timed out (exit $status)"
fi

# Retrieve the version and verify that it contains non-whitespace text.
if version="$(run_opencode --version 2>"$test_dir/version.err")"; then
    [[ -n "${version//[[:space:]]/}" ]] ||
        fail "OpenCode --version returned an empty version"

    printf 'PASS: OpenCode version: %s\n' "$version"
else
    status=$?
    cat "$test_dir/version.err" >&2
    fail "OpenCode --version failed or timed out (exit $status)"
fi
