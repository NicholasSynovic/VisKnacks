#!/usr/bin/env bash
# Dependencies: Bash 4+, curl, jq, and the supplied optparse.bash.
#
# Exit codes:
#   0 = Ollama API check passed
#   1 = connection, HTTP, or response validation failed
#   2 = invalid configuration or missing dependency
#
# optparse.bash itself exits 1 for argument parsing errors.

# Do not enable nounset before loading/running the supplied parser:
# it references variables that may not yet be defined.
set -eo pipefail

fail_config() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PARSER="${SCRIPT_DIR}/optparse.bash"

[[ -r "$PARSER" ]] || fail_config "Cannot read parser: $PARSER"
source "$PARSER"

optparse.define short=H long=host \
    variable=host default=127.0.0.1 \
    desc="Server hostname or IP address"

optparse.define short=p long=port \
    variable=port default=11434 \
    desc="Server TCP port"

optparse.define short=t long=timeout \
    variable=timeout default=5 \
    desc="Maximum request duration in whole seconds"

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

for command_name in curl jq; do
    command -v "$command_name" >/dev/null 2>&1 ||
        fail_config "Required command not found: $command_name"
done

# Validate length before arithmetic to avoid overflow on oversized input.
[[ "$port" =~ ^[0-9]{1,5}$ ]] ||
    fail_config "Port must be an integer between 1 and 65535"

port=$((10#$port))
((port >= 1 && port <= 65535)) ||
    fail_config "Port must be between 1 and 65535"

[[ "$timeout" =~ ^[0-9]{1,5}$ ]] ||
    fail_config "Timeout must be an integer between 1 and 86400"

timeout=$((10#$timeout))
((timeout >= 1 && timeout <= 86400)) ||
    fail_config "Timeout must be between 1 and 86400 seconds"

# Accept a hostname, IPv4 address, or bare IPv6 address, not a URL.
[[ -n "$host" && "$host" != *[[:space:]/@\?\#]* ]] ||
    fail_config "Host must be a hostname or IP address, without a URL scheme"

# Bracket bare IPv6 addresses when constructing the URL.
url_host="$host"
if [[ "$host" == *:* && "$host" != \[*\] ]]; then
    url_host="[$host]"
fi

url="http://${url_host}:${port}/api/version"

# Append the status code after the body so no response file is needed.
# Disable proxy use: this test must reach the specified service directly.
if response="$(
    curl \
        --silent \
        --show-error \
        --noproxy '*' \
        --globoff \
        --connect-timeout "$timeout" \
        --max-time "$timeout" \
        --write-out $'\n%{http_code}' \
        "$url"
)"; then
    http_status="${response##*$'\n'}"
    body="${response%$'\n'*}"
else
    curl_status=$?
    printf 'FAIL: Cannot reach Ollama at %s (curl exit %s)\n' \
        "$url" "$curl_status" >&2
    exit 1
fi

if [[ "$http_status" != 200 ]]; then
    printf 'FAIL: %s returned HTTP %s; expected 200\n' \
        "$url" "$http_status" >&2
    exit 1
fi

# Require exactly one JSON document containing a nonempty version string.
if version="$(
    jq -er -s '
        if length == 1 then
            .[0]
            | select(type == "object")
            | .version
            | select(type == "string")
            | select(length > 0)
        else
            empty
        end
    ' <<< "$body" 2>/dev/null
)"; then
    printf 'PASS: Ollama API is responding at %s (version %s)\n' \
        "$url" "$version"
else
    printf 'FAIL: %s did not return valid Ollama version JSON\n' \
        "$url" >&2
    exit 1
fi
