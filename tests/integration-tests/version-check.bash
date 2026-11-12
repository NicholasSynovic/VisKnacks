#!/usr/bin/env bash
#
# Shared exact-version checks for the integration tests.
#
# Sourcing this file reads versions.env and defines:
#   require_opencode_version <opencode-path>
#   require_ollama_version  <base-url>
#
# Both functions exit 2 on a mismatch or unreadable state, following
# the exit-code contract shared by the integration tests. Versions
# must match the pinned values exactly: the tests encode OpenCode
# server API response shapes that change between releases.

version_check_fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

VERSION_CHECK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_FILE="$VERSION_CHECK_DIR/versions.env"

[[ -r "$VERSIONS_FILE" ]] ||
    version_check_fail "Cannot read versions file: $VERSIONS_FILE"

# shellcheck disable=SC1091
source "$VERSIONS_FILE"

[[ "${OPENCODE_REQUIRED_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    version_check_fail \
        "Invalid OPENCODE_REQUIRED_VERSION: ${OPENCODE_REQUIRED_VERSION:-unset}"

[[ "${OLLAMA_REQUIRED_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    version_check_fail \
        "Invalid OLLAMA_REQUIRED_VERSION: ${OLLAMA_REQUIRED_VERSION:-unset}"

[[ "${PARAVIEW_REQUIRED_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    version_check_fail \
        "Invalid PARAVIEW_REQUIRED_VERSION: ${PARAVIEW_REQUIRED_VERSION:-unset}"

[[ "${MCP_REQUIRED_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    version_check_fail \
        "Invalid MCP_REQUIRED_VERSION: ${MCP_REQUIRED_VERSION:-unset}"

# Extract a bare X.Y.Z version from OpenCode's --version output
# (for example "opencode v2.2.7") and require an exact match.
require_opencode_version() {
    local binary="$1"
    local raw=""
    local version=""

    if ! raw="$("$binary" --version 2>/dev/null)"; then
        version_check_fail "Could not read OpenCode version from: $binary"
    fi

    version="$(
        printf '%s\n' "$raw" |
            grep -Eo '[0-9]+(\.[0-9]+)+' |
            head -n 1 || true
    )"

    [[ -n "$version" ]] ||
        version_check_fail "Could not parse OpenCode version from: $raw"

    if [[ "$version" != "$OPENCODE_REQUIRED_VERSION" ]]; then
        version_check_fail \
            "OpenCode version mismatch: found $version, integration tests require exactly $OPENCODE_REQUIRED_VERSION (pinned in $VERSIONS_FILE)"
    fi

    printf 'INFO: OpenCode version check: %s\n' "$version"
}

# Fetch Ollama's /api/version over HTTP (the binary may not be on
# PATH) and require an exact match.
require_ollama_version() {
    local base_url="${1%/}"
    local url=""
    local body=""
    local version=""

    url="$base_url/api/version"

    for dependency in curl jq; do
        command -v "$dependency" >/dev/null 2>&1 ||
            version_check_fail "Required command not found: $dependency"
    done

    if ! body="$(curl \
        --disable \
        --silent \
        --show-error \
        --fail \
        --noproxy '*' \
        --globoff \
        --connect-timeout 2 \
        --max-time 5 \
        "$url" 2>&1)"; then
        version_check_fail "Cannot reach Ollama version endpoint: $url ($body)"
    fi

    version="$(
        jq -er '.version | select(type == "string" and length > 0)' \
            <<< "$body" 2>/dev/null
    )" ||
        version_check_fail "Ollama version endpoint returned no version: $url"

    if [[ "$version" != "$OLLAMA_REQUIRED_VERSION" ]]; then
        version_check_fail \
            "Ollama version mismatch at $url: found $version, integration tests require exactly $OLLAMA_REQUIRED_VERSION (pinned in $VERSIONS_FILE)"
    fi

    printf 'INFO: Ollama version check: %s\n' "$version"
}

# Extract a bare X.Y.Z version from pvpython's --version output
# (for example "paraview version 6.1.1") and require an exact match.
require_paraview_version() {
    local binary="$1"
    local raw=""
    local version=""

    if ! raw="$(timeout 15 "$binary" --version 2>/dev/null)"; then
        version_check_fail "Could not read ParaView version from: $binary"
    fi

    version="$(
        printf '%s\n' "$raw" |
            grep -Eo '[0-9]+(\.[0-9]+)+' |
            head -n 1 || true
    )"

    [[ -n "$version" ]] ||
        version_check_fail "Could not parse ParaView version from: $raw"

    if [[ "$version" != "$PARAVIEW_REQUIRED_VERSION" ]]; then
        version_check_fail \
            "ParaView version mismatch: found $version, integration tests require exactly $PARAVIEW_REQUIRED_VERSION (pinned in $VERSIONS_FILE)"
    fi

    printf 'INFO: ParaView version check: %s\n' "$version"
}

# Read the installed mcp package version through importlib.metadata
# and require an exact match. The renderer server's streamable-http
# behavior (including /mcp redirect handling) is an mcp-package trait.
require_mcp_version() {
    local python_bin="$1"
    local version=""

    if ! version="$("$python_bin" -c \
        'from importlib.metadata import version; print(version("mcp"))' \
        2>/dev/null)"; then
        version_check_fail \
            "Could not read the mcp package version from: $python_bin"
    fi

    [[ -n "$version" ]] ||
        version_check_fail \
            "The mcp package version reported by $python_bin is empty"

    if [[ "$version" != "$MCP_REQUIRED_VERSION" ]]; then
        version_check_fail \
            "mcp package version mismatch: found $version, integration tests require exactly $MCP_REQUIRED_VERSION (pinned in $VERSIONS_FILE)"
    fi

    printf 'INFO: mcp package version check: %s\n' "$version"
}
