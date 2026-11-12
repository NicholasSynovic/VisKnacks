#!/usr/bin/env bash
#
# pvpython/pvserver availability check for the PV Renderer MCP tests.
#
# PASS requires:
#   - pvpython and pvserver are resolvable on PATH.
#   - Each binary answers --version within the timeout with nonempty output.
#
# Assumptions:
#   This is the first test in the PV Renderer chain; it verifies the conda
#   environment that every later renderer test depends on.
#
# Dependencies:
#   Bash 4+, GNU timeout, and the supplied optparse.bash.
#
# Exit codes:
#   0   = both ParaView binaries are available
#   1   = a binary is present but failed to run or produce version output
#   2   = invalid configuration, missing dependency, or binary not on PATH

# Do not enable nounset before loading/running the supplied parser:
# it references variables that may not yet be defined.
set -eo pipefail

fail_config() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PARSER="${SCRIPT_DIR}/optparse.bash"
VERSION_CHECK="${SCRIPT_DIR}/version-check.bash"

[[ -r "$PARSER" ]] || fail_config "Cannot read parser: $PARSER"
[[ -r "$VERSION_CHECK" ]] ||
    fail_config "Cannot read version checker: $VERSION_CHECK"
source "$PARSER"

optparse.define short=t long=timeout \
    variable=timeout default=15 \
    desc="Maximum per-binary run duration in whole seconds"

# Keep the generated parser file covered by a cleanup trap, including
# when --help or an argument error exits before its own cleanup runs.
parser_file=""
trap '[[ -z "$parser_file" ]] || rm -f -- "$parser_file"' EXIT

parser_file="$(optparse.build)"
[[ -r "$parser_file" ]] || fail_config "Could not build argument parser"
source "$parser_file"

# getopts leaves OPTIND pointing to any remaining positional arguments.
shift "$((OPTIND - 1))"
[[ $# -eq 0 ]] || fail_config "Unexpected positional argument: $1"

set -u

command -v timeout >/dev/null 2>&1 ||
    fail_config "Required command not found: timeout"

[[ "$timeout" =~ ^[0-9]{1,5}$ ]] ||
    fail_config "Timeout must be an integer between 1 and 86400"

timeout=$((10#$timeout))
((timeout >= 1 && timeout <= 86400)) ||
    fail_config "Timeout must be between 1 and 86400 seconds"

# The tests pin exact tool versions; reject any other release early.
# shellcheck disable=SC1090
source "$VERSION_CHECK"

for binary in pvpython pvserver; do
    binary_path="$(type -P -- "$binary" || true)"
    [[ -n "$binary_path" && -x "$binary_path" ]] ||
        fail_config "Required ParaView binary not found on PATH: $binary"

    if version_output="$(
        timeout --signal=TERM --kill-after=2s "${timeout}s" \
            "$binary_path" --version 2>&1
    )"; then
        [[ -n "$version_output" ]] || {
            printf 'FAIL: %s --version produced no output\n' "$binary" >&2
            exit 1
        }
        printf 'PASS: %s at %s (%s)\n' \
            "$binary" "$binary_path" \
            "$(printf '%s\n' "$version_output" | head -n 1)"

        require_paraview_version "$binary_path"
    else
        printf 'FAIL: %s --version failed or timed out (exit %s)\n' \
            "$binary" "$?" >&2
        exit 1
    fi
done

printf 'INFO: ParaView environment is ready for the renderer tests\n'
