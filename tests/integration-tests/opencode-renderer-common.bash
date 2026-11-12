#!/usr/bin/env bash
# Shared driver; normally invoked through one of the three test wrappers.
set -eo pipefail
MODE="${1:-}"
shift || true
case "$MODE" in discovery|execute|render) ;; *) echo 'ERROR: mode must be discovery, execute, or render' >&2; exit 2;; esac
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
error() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
parser_file=""
sandbox=""
keep_artifacts=false
package_dir=""
cleanup() {
    local status=$?
    trap - EXIT
    set +e
    [[ -z "$parser_file" ]] || rm -f -- "$parser_file"
    if [[ -n "$sandbox" ]]; then
        if [[ "$keep_artifacts" == true ]]; then
            printf 'INFO: Artifacts retained: %s\n' "$sandbox" >&2
        else
            rm -rf -- "$sandbox" || printf 'WARN: Cleanup incomplete: %s\n' "$sandbox" >&2
        fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[[ -r "$DIR/optparse.bash" ]] || error 'Missing optparse.bash'
source "$DIR/optparse.bash"
[[ -r "$DIR/version-check.bash" ]] || error 'Missing version-check.bash'
default_timeout=180
[[ "$MODE" != discovery ]] || default_timeout=30
optparse.define short=u long=ollama-url variable=ollama_url default=http://127.0.0.1:11434 desc="Direct Ollama server root"
optparse.define short=m long=model variable=model default=qwen3.5:0.8b desc="Installed Ollama model"
optparse.define short=t long=timeout variable=budget default="$default_timeout" desc="Overall worker deadline in seconds"
optparse.define short=b long=binary variable=binary default=opencode desc="OpenCode executable"
optparse.define short=p long=python variable=python_bin default=python desc="Python with the mcp package"
optparse.define short=P long=package-dir variable=package_dir desc="Renderer package directory"
optparse.define short=k long=keep-artifacts variable=keep_artifacts value=true desc="Retain logs, code, and image"
parser_file="$(optparse.build)"
[[ -r "$parser_file" ]] || error 'Cannot build argument parser'
source "$parser_file"
shift "$((OPTIND - 1))"
[[ $# -eq 0 ]] || error "Unexpected argument: $1"
set -u
[[ "$(uname -s)" == Linux ]] || error 'Linux required'
for dep in bash curl jq timeout setsid grep sed awk tail tr date; do
    command -v "$dep" >/dev/null || error "Missing dependency: $dep"
done
timeout --version | grep -q 'GNU coreutils' || error 'GNU timeout required'
[[ "$budget" =~ ^[0-9]{1,5}$ ]] || error 'Invalid timeout'
budget=$((10#$budget))
((budget >= 1 && budget <= 86400)) || error 'Timeout must be 1..86400'
while [[ "$ollama_url" == */ ]]; do ollama_url="${ollama_url%/}"; done
pattern='^https?://(\[[0-9A-Fa-f:.%]+\]|[A-Za-z0-9._-]+)(:[0-9]{1,5})?$'
[[ "$ollama_url" =~ $pattern ]] || error 'Use a direct Ollama origin without credentials or paths'
[[ "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] || error 'Invalid model name'
[[ ! -e /etc/opencode ]] || error 'Managed /etc/opencode configuration would break isolation'
for file in mcp_client.bash renderer-assert.py; do [[ -r "$DIR/$file" ]] || error "Missing $file"; done
binary="$(type -P -- "$binary" || true)"
python_bin="$(type -P -- "$python_bin" || true)"
[[ -n "$binary" && -x "$binary" ]] || error 'OpenCode executable not found'
[[ -n "$python_bin" && -x "$python_bin" ]] || error 'Python executable not found'
[[ "$binary" == /* ]] || binary="$PWD/$binary"
[[ "$python_bin" == /* ]] || python_bin="$PWD/$python_bin"
# The tests pin exact tool versions; reject any other release early.
# shellcheck disable=SC1090
source "$DIR/version-check.bash"
require_opencode_version "$binary"
if [[ -z "$package_dir" ]]; then package_dir="$DIR/../../mcp/pvpython-renderer"; fi
[[ -d "$package_dir" ]] || error 'Renderer package missing; use --package-dir'
package_dir="$(cd -- "$package_dir" && pwd)"
[[ -f "$package_dir/pvpython_renderer/main.py" ]] || error 'Missing pvpython_renderer/main.py'
"$python_bin" -c 'import mcp' || error 'Selected Python cannot import mcp'
# The tests pin exact tool versions; reject any other release early.
# shellcheck disable=SC1090
source "$DIR/version-check.bash"
require_mcp_version "$python_bin"
if [[ "$MODE" != discovery ]]; then
    for dep in pvpython pvserver; do command -v "$dep" >/dev/null || error "Missing $dep on PATH"; done
fi
sandbox="$(mktemp -d /tmp/opencode-renderer-test.XXXXXXXX)"
renderer_worker() {
    set -euo pipefail
    SECONDS=0
    local mode="$1" binary="$2" py="$3" package="$4" dir="$5" root="$6" budget="$7" ollama="$8" model="$9"
    local stage='' port='' oc_url='' session='' http='' marker='' tool='pvpython_renderer_execute_code'
    local oc_password='' http_code='' turn_finished=false active_seen=false active='' grace_polls=0
    declare -g MCP_SERVER_PID='' OC_PID='' REQUEST_PID=''
    source "$dir/mcp_client.bash"
    worker_cleanup() {
        local status=$?
        trap - EXIT INT TERM
        set +e
        [[ -z "${REQUEST_PID:-}" ]] || kill -TERM "$REQUEST_PID" 2>/dev/null
        for pid in "${OC_PID:-}" "${MCP_SERVER_PID:-}"; do
            [[ -z "$pid" ]] || kill -TERM -- "-$pid" 2>/dev/null
        done
        sleep 0.2
        [[ -z "${REQUEST_PID:-}" ]] || { kill -KILL "$REQUEST_PID" 2>/dev/null; wait "$REQUEST_PID" 2>/dev/null; }
        for pid in "${OC_PID:-}" "${MCP_SERVER_PID:-}"; do
            [[ -z "$pid" ]] || { kill -KILL -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
        done
        exit "$status"
    }
    trap worker_cleanup EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    fail() { printf 'FAIL: [%s] %s\n' "$stage" "$*" >&2; exit 1; }
    phase() { stage="$1"; printf '%s\n' "$stage" > "$root/stage"; printf 'INFO: [%ss] %s\n' "$SECONDS" "$stage"; }
    api() {
        local method="$1" path="$2" dest="$3" body="${4:-}"
        local -a a=(--disable --silent --show-error --fail --noproxy '*' --globoff --connect-timeout 2 --max-time "$budget" --request "$method" --user "opencode:$oc_password" --output "$dest")
        [[ -z "$body" ]] || a+=(--header 'Content-Type: application/json' --data-binary "@$body")
        curl "${a[@]}" "$oc_url$path"
    }
    phase 'Start isolated renderer'
    mkdir -p "$root/renderer" "$root/oc/home" "$root/oc/config/opencode" "$root/oc/data" "$root/oc/cache" "$root/oc/state" "$root/oc/work"
    # Bind-and-release selection is best effort; an occupied port fails readiness.
    port="$("$py" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
    mcp_start_server "$py" "$package" 127.0.0.1 "$port" "$root/renderer" "$root/renderer.log"
    mcp_await_ready 127.0.0.1 "$port" "$MCP_SERVER_PID" 30 || fail 'Renderer did not become ready'
    phase 'Generate isolated OpenCode configuration'
    jq -n --arg url "http://127.0.0.1:$port/mcp" --arg base "$ollama/v1" --arg model "$model" --argjson ms "$((budget*1000))" '
    {
        "$schema":"https://opencode.ai/config.json",
        model:("ollama-test/"+$model), small_model:("ollama-test/"+$model),
        default_agent:"renderer-integration", enabled_providers:["ollama-test"],
        autoupdate:false, snapshot:false, share:"disabled", plugin:[], instructions:[],
        compaction:{auto:false}, permission:{"*":"deny"},
        provider:{"ollama-test":{
            npm:"@ai-sdk/openai-compatible", options:{baseURL:$base,timeout:$ms},
            models:{($model):{name:$model, options:{reasoningEffort:"none"},limit:{context:8192,output:1024}}}
        }},
        mcp:{pvpython_renderer:{type:"remote",url:$url,enabled:true,oauth:false,timeout:$ms}},
        agent:{"renderer-integration":{
            mode:"primary",model:("ollama-test/"+$model),temperature:0,
            prompt:"Call pvpython_renderer_execute_code exactly once using the exact code provided. Do not use other tools. Do not change the code. Do not answer instead of making a tool call.",
            tools:{"*":false,"pvpython_renderer_execute_code":true},
            permission:{"*":"deny","pvpython_renderer_execute_code":"allow"}
        }}
    }' > "$root/oc/opencode.json"
    phase 'Start isolated OpenCode server'
    oc_password="pw-$(cat /proc/sys/kernel/random/uuid)"
    (
        cd -- "$root/oc/work"
        exec setsid env -i "PATH=$PATH" "HOME=$root/oc/home" \
            "XDG_CONFIG_HOME=$root/oc/config" "XDG_DATA_HOME=$root/oc/data" \
            "XDG_CACHE_HOME=$root/oc/cache" "XDG_STATE_HOME=$root/oc/state" \
            "TMPDIR=$root/oc" TERM=dumb NO_COLOR=1 'NO_PROXY=*' 'no_proxy=*' \
            "OPENCODE_CONFIG=$root/oc/opencode.json" "OPENCODE_CONFIG_DIR=$root/oc/config/opencode" \
            "OPENCODE_SERVER_PASSWORD=$oc_password" \
            OPENCODE_DISABLE_PROJECT_CONFIG=true OPENCODE_DISABLE_CLAUDE_CODE=true \
            OPENCODE_DISABLE_EXTERNAL_SKILLS=true OPENCODE_DISABLE_DEFAULT_PLUGINS=true OPENCODE_PURE=true \
            OPENCODE_DISABLE_AUTOUPDATE=true OPENCODE_DISABLE_MODELS_FETCH=true \
            OPENCODE_DISABLE_LSP_DOWNLOAD=true OPENCODE_DISABLE_AUTOCOMPACT=true \
            OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=1024 \
            "$binary" serve --hostname 127.0.0.1 --port 0
    ) > "$root/opencode.log" 2>&1 &
    OC_PID=$!
    while :; do
        kill -0 "$OC_PID" 2>/dev/null || fail 'OpenCode exited during startup'
        oc_url="$(grep -Eo 'http://127\.0\.0\.1:[0-9]+' "$root/opencode.log" | tail -n 1 || true)"
        if [[ -n "$oc_url" ]]; then
            # OpenCode V2 serves readiness at /api/info (no "healthy"
            # field) and requires basic auth with the server password.
            http_code="$(curl --disable --silent --show-error --noproxy '*' \
                --globoff --connect-timeout 2 --max-time "$budget" \
                --user "opencode:$oc_password" --write-out '%{http_code}' \
                --output "$root/health.json" "$oc_url/api/info" \
                2>"$root/readiness.stderr" || true)"
            case "$http_code" in
                200) jq -e '.version | type == "string" and length > 0' "$root/health.json" >/dev/null 2>&1 && break ;;
                401|403) fail "OpenCode server rejected credentials (HTTP $http_code)" ;;
            esac
        fi
        sleep 0.2
    done
    phase 'Verify OpenCode MCP connection'
    # V2 populates the MCP status asynchronously after startup, so poll
    # for the renderer connection instead of reading it once.
    mcp_deadline=$((SECONDS + 15))
    while :; do
        api GET /api/mcp "$root/mcp-status.json" || fail 'OpenCode MCP status request failed'
        if jq -e 'any(.data[]; .name == "pvpython_renderer" and .status.status == "connected")' \
            "$root/mcp-status.json" >/dev/null 2>&1; then
            break
        fi
        if ((SECONDS >= mcp_deadline)); then
            fail 'OpenCode did not connect to renderer MCP'
        fi
        sleep 0.5
    done
    # An independent protocol request validates the upstream schema, not
    # an assumed OpenCode experimental-tool registry representation.
    phase 'Verify upstream execute_code schema'
    mcp_handshake "http://127.0.0.1:$port/mcp" "$root/renderer" 15 1 || fail 'Schema-check MCP handshake failed'
    mcp_list_tools_request 2 "$root/tools-request.json"
    http="$(mcp_post "$MCP_SESSION" 15 "http://127.0.0.1:$port/mcp" "$root/tools-request.json" "$root/tools.headers" "$root/tools.body")" || fail 'tools/list transport failed'
    [[ "$http" == 200 ]] || fail "tools/list HTTP $http"
    mcp_extract_json "$root/tools.body" "$root/tools.json" || fail 'Invalid tools/list response'
    jq -e '
        .jsonrpc == "2.0" and .id == 2 and .error == null
        and (.result.tools | type == "array" and length == 1)
        and .result.tools[0].name == "execute_code"
        and .result.tools[0].inputSchema.type == "object"
        and .result.tools[0].inputSchema.properties.code.type == "string"
        and ((.result.tools[0].inputSchema.required // []) | index("code") != null)
    ' "$root/tools.json" >/dev/null || fail 'Unexpected upstream tool schema'
    if [[ "$mode" == discovery ]]; then
        printf 'PASS: OpenCode connected to renderer; upstream execute_code schema verified (no inference)\n'
        return 0
    fi
    phase 'Prepare fixed execution payload'
    marker="pv-$(cat /proc/sys/kernel/random/uuid)"
    printf '%s\n' "$marker" > "$root/marker.txt"
    "$py" "$dir/renderer-assert.py" make-code "$mode" "$root" "$marker"
    printf '{"title":"OpenCode renderer integration"}\n' > "$root/create-session.json"
    api POST /api/session "$root/session.json" "$root/create-session.json" || fail 'Cannot create session'
    session="$(jq -er '.data.id | select(type == "string" and length>0)' "$root/session.json")" || fail 'Missing session ID'
    jq -n --rawfile code "$root/code.py" '{agent:"renderer-integration",text:("Call pvpython_renderer_execute_code exactly once with the following code unchanged:\n\n"+$code)}' > "$root/prompt.json"
    phase 'Wait for actual renderer tool execution'
    api POST "/api/session/$session/prompt" "$root/prompt-response.json" "$root/prompt.json" 2>"$root/prompt.stderr" &
    REQUEST_PID=$!
    while :; do
        kill -0 "$OC_PID" 2>/dev/null || fail 'OpenCode exited'
        kill -0 "$MCP_SERVER_PID" 2>/dev/null || fail 'Renderer exited'
        if [[ -n "$REQUEST_PID" ]] && ! kill -0 "$REQUEST_PID" 2>/dev/null; then
            if wait "$REQUEST_PID"; then REQUEST_PID=''; else REQUEST_PID=''; fail 'Prompt HTTP request failed'; fi
        fi
        api GET "/api/session/$session/message?limit=200" "$root/messages.json" || fail 'Cannot read session messages'
        jq -e '.data | type == "array"' "$root/messages.json" >/dev/null || fail 'Malformed messages'
        # Turn-completion barrier: the V2 prompt endpoint admits
        # asynchronously, and a held idle-wait connection can be
        # dropped mid-run (which aborts the tool), so poll the
        # active-session map instead. The session is listed while its
        # agent loop runs and disappears when it goes idle; conclude
        # only after having seen it active. If it was never seen
        # active (an instant error can come and go between polls),
        # conclude only when the projection shows a terminal
        # assistant turn.
        api GET /api/session/active "$root/active.json" || fail 'Cannot read active sessions'
        active="$(jq -r --arg s "$session" '.data | has($s)' "$root/active.json" 2>/dev/null || true)"
        if [[ "$active" == "true" ]]; then
            active_seen=true
        elif [[ "$active_seen" == true ]]; then
            turn_finished=true
        elif jq -e '(((.data // [])[] | select(.type=="assistant") | (.finish != null or .error != null)) // false)' "$root/messages.json" >/dev/null 2>&1; then
            turn_finished=true
        fi
        jq '[.data[] | select(.type=="assistant") | .content[]? | select(.type=="tool")]' "$root/messages.json" > "$root/tool-parts.json"
        jq -e --arg tool "$tool" 'all(.[];.name==$tool)' "$root/tool-parts.json" >/dev/null || fail 'Unexpected tool invocation'
        jq -e 'length <= 1' "$root/tool-parts.json" >/dev/null || fail 'Multiple tool invocations'
        if jq -e 'any(.[];.state.status=="error")' "$root/tool-parts.json" >/dev/null; then fail 'Renderer tool failed'; fi
        if jq -e 'any(.[];.state.status=="completed")' "$root/tool-parts.json" >/dev/null; then
            phase 'Validate tool input and renderer result'
            "$py" "$dir/renderer-assert.py" result "$mode" "$root" "$marker" || fail 'Renderer result validation failed'
            # Report assistant errors even if a completed part exists.
            jq -e 'all(.data[]; .type!="assistant" or .error==null)' "$root/messages.json" >/dev/null || fail 'Assistant error'
            printf 'PASS: OpenCode -> renderer -> pvpython %s verified\n' "$mode"
            printf 'INFO: Worker elapsed: %ss\n' "$SECONDS"
            return 0
        fi
        if jq -e 'any(.data[]; .type=="assistant" and .error!=null)' "$root/messages.json" >/dev/null; then fail 'Assistant error'; fi
        if [[ "$turn_finished" == true ]]; then
            # The idle barrier fired; allow the message projection a
            # short grace period to catch up before declaring failure.
            ((grace_polls += 1))
            if ((grace_polls > 10)); then fail 'Model finished without a completed renderer tool call'; fi
        fi
        sleep 0.2
    done
}
export -f renderer_worker
printf 'INFO: Mode: %s; model: %s; overall worker deadline: %ss\n' "$MODE" "$model" "$budget"
if BASH_ENV=/dev/null ENV=/dev/null timeout --signal=TERM --kill-after=3s "${budget}s" \
    bash --noprofile --norc -c 'renderer_worker "$@"' renderer-worker \
    "$MODE" "$binary" "$python_bin" "$package_dir" "$DIR" "$sandbox" "$budget" "$ollama_url" "$model"; then
    exit 0
else
    status=$?
fi
if [[ "$status" == 124 || "$status" == 137 ]]; then
    printf 'FAIL: Deadline exceeded during: %s\n' "$(cat "$sandbox/stage" 2>/dev/null || true)" >&2
    status=124
fi
for name in opencode.log renderer.log mcp-status.json prompt.stderr prompt-response.json active.json tool-parts.json renderer-result.json; do
    if [[ -s "$sandbox/$name" ]]; then printf '\n--- %s (last 30 lines) ---\n' "$name" >&2; tail -n 30 -- "$sandbox/$name" >&2; fi
done
exit "$status"
