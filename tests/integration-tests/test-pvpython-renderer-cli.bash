#!/usr/bin/env bash
#
# PV Renderer MCP server entry-point smoke test.
#
# PASS requires:
#   - python can import the mcp package in the active environment.
#   - python -m pvpython_renderer.main --help exits 0 and documents
#     the --server and --port options.
#   - --version prints the pvpython-renderer-mcp program name followed by
#     a version token ("unknown" is accepted for install-free runs).
#   - An unknown option exits with argparse's usage-error status (2).
#
# No server is started and no MCP session is opened.
#
# Assumptions:
#   test-pvpython-env.bash verified the ParaView binaries.
#
# Dependencies:
#   Bash 4+, GNU timeout, grep, python (with the mcp package), and the
#   supplied optparse.bash.
#
# Exit codes:
#   0   = entry point behaves as documented
#   1   = entry-point failure (import, help, version, or error handling)
#   2   = invalid setup or configuration

set -eo pipefail

fail_config() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/mcp/pvpython-renderer"
PARSER="${SCRIPT_DIR}/optparse.bash"

[[ -r "$PARSER" ]] || fail_config "Cannot read parser: $PARSER"
source "$PARSER"

optparse.define short=b long=python \
    variable=python_bin default=python \
    desc="Python interpreter to run the server module with"

optparse.define short=t long=timeout \
    variable=timeout default=30 \
    desc="Maximum per-invocation duration in whole seconds"

parser_file=""
trap '[[ -z "$parser_file" ]] || rm -f -- "$parser_file"' EXIT

parser_file="$(optparse.build)"
[[ -r "$parser_file" ]] || fail_config "Could not build argument parser"
source "$parser_file"

shift "$((OPTIND - 1))"
[[ $# -eq 0 ]] || fail_config "Unexpected positional argument: $1"

set -u

[[ "$(uname -s)" == Linux ]] ||
    fail_config "This implementation supports Linux only"

for dependency in timeout grep; do
    command -v "$dependency" >/dev/null 2>&1 ||
        fail_config "Required command not found: $dependency"
done

timeout --version 2>/dev/null | grep -q 'GNU coreutils' ||
    fail_config "GNU timeout is required"

[[ "$timeout" =~ ^[0-9]{1,5}$ ]] ||
    fail_config "Timeout must be an integer between 1 and 86400"

timeout=$((10#$timeout))
((timeout >= 1 && timeout <= 86400)) ||
    fail_config "Timeout must be between 1 and 86400 seconds"

[[ -d "$PACKAGE_DIR" ]] ||
    fail_config "Renderer package directory not found: $PACKAGE_DIR"
[[ -f "$PACKAGE_DIR/pvpython_renderer/pv_mcp.py" ]] ||
    fail_config "Renderer module not found: $PACKAGE_DIR/pvpython_renderer/pv_mcp.py"

python_path="$(type -P -- "$python_bin" || true)"
[[ -n "$python_path" ]] ||
    fail_config "Python interpreter not found: $python_bin"

work_dir="$(mktemp -d /tmp/opencode-pvcli-test.XXXXXXXX)"

run_cli() {
    # run_cli <label> <args...>; output lands in $work_dir/<label>.{out,err}.
    # Prints nothing; the caller captures the exit status with || status=$?.
    local label="$1"
    shift
    (
        cd -- "$work_dir"
        timeout --signal=TERM --kill-after=2s "${timeout}s" \
            env -i \
            "PATH=$PATH" \
            "HOME=$work_dir" \
            "PYTHONPATH=$PACKAGE_DIR" \
            "PYTHONDONTWRITEBYTECODE=1" \
            "$python_path" -m pvpython_renderer.main "$@" \
            > "$work_dir/$label.out" 2> "$work_dir/$label.err"
    )
}

if "$python_path" -c 'import mcp' >/dev/null 2>&1; then
    printf 'INFO: python can import mcp: %s\n' "$python_path"
else
    printf 'FAIL: %s cannot import the mcp package, so the renderer\n' \
        "$python_path" >&2
    printf 'FAIL: entry point cannot even be parsed\n' >&2
    exit 1
fi

printf 'INFO: Checking --help\n'
help_status=0
run_cli help --help || help_status=$?
if [[ "$help_status" -ne 0 ]]; then
    cat "$work_dir/help.err" >&2
    printf 'FAIL: --help failed or timed out (exit %s)\n' "$help_status" >&2
    exit 1
fi

[[ -s "$work_dir/help.out" ]] || {
    printf 'FAIL: --help produced no usage output\n' >&2
    exit 1
}

for option in --server --port; do
    grep -q -- "$option" "$work_dir/help.out" || {
        printf 'FAIL: --help does not document %s\n' "$option" >&2
        exit 1
    }
done
printf 'PASS: --help documents --server and --port\n'

printf 'INFO: Checking --version\n'
version_status=0
run_cli version --version || version_status=$?
if [[ "$version_status" -ne 0 ]]; then
    cat "$work_dir/version.err" >&2
    printf 'FAIL: --version failed or timed out (exit %s)\n' \
        "$version_status" >&2
    exit 1
fi

version_line="$(head -n 1 "$work_dir/version.out")"
[[ "$version_line" =~ ^pvpython-renderer-mcp[[:space:]]+[0-9A-Za-z._-]+$ ]] || {
    printf 'FAIL: --version output is unexpected: %s\n' \
        "$version_line" >&2
    exit 1
}
printf 'PASS: --version reports: %s\n' "$version_line"

printf 'INFO: Checking unknown-option handling\n'
bogus_status=0
run_cli bogus --not-a-real-option || bogus_status=$?
if [[ "$bogus_status" -eq 2 ]]; then
    printf 'PASS: unknown option exits with argparse status 2\n'
else
    cat "$work_dir/bogus.err" >&2
    printf 'FAIL: unknown option exited %s; expected 2\n' \
        "$bogus_status" >&2
    exit 1
fi

rm -rf -- "$work_dir"
printf 'INFO: PV Renderer MCP entry point is ready for the server tests\n'
