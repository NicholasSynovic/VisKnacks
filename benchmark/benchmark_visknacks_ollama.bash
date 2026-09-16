#!/bin/bash -l
#PBS -N visknacks_benchmark
#PBS -A EVITA
#PBS -q by-gpu
#PBS -l select=2
#PBS -l walltime=24:00:00
#PBS -l filesystems=home:eagle
#PBS -j oe

# Run the SciVisAgentBench task matrix against one local Ollama model,
# served by an in-job `ollama serve`, using the pvpython-renderer and
# pvpython-rag MCP servers started in the same job. Artifacts are written
# to results/<model>/<task>/ under the job run directory and compressed
# into a single archive in the user's home directory at the end (and on
# walltime kill).
#
# qsub -v OLLAMA_MODEL=<model>,PVPYTHON_DATA=<index-dir> \
#      [,"NUM_TASKS=<n|all>"][,"FORCE=1"][,"TASK_TIMEOUT=<seconds>"] \
#      benchmark_visknacks_ollama.bash
#
# The benchmark matrix loop deliberately runs without `set -e`: one
# failing run must not abort the rest of the matrix.

set -euo pipefail

# --- Set local script variables ---
# Specify the ollama model to benchmark against via `-v OLLAMA_MODEL=`
MODEL="${OLLAMA_MODEL:-}"
if [[ -z "${MODEL}" ]]; then
    echo "ERROR: No model specified." >&2
    echo "Usage: qsub -v OLLAMA_MODEL=<model-name>,PVPYTHON_DATA=<index-dir> benchmark_visknacks_ollama.bash" >&2
    exit 2
fi

# Specify the pvpython-rag index directory via `-v PVPYTHON_DATA=`
PVPYTHON_DATA="${PVPYTHON_DATA:-}"
if [[ -z "${PVPYTHON_DATA}" ]]; then
    echo "ERROR: No RAG index directory specified." >&2
    echo "Usage: qsub -v OLLAMA_MODEL=<model-name>,PVPYTHON_DATA=<index-dir> benchmark_visknacks_ollama.bash" >&2
    exit 2
fi

# Number of tasks to run via `-v NUM_TASKS=<n>` (default: all; 0 also
# runs every task)
NUM_TASKS="${NUM_TASKS:-all}"
FORCE="${FORCE:-0}"
if [[ "${NUM_TASKS}" != "all" ]] && [[ "${NUM_TASKS}" != "0" ]] \
    && ! [[ "${NUM_TASKS}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: NUM_TASKS must be 'all', '0', or a non-negative integer: ${NUM_TASKS}" >&2
    exit 2
fi

# Per-task opencode timeout in seconds via `-v TASK_TIMEOUT=<seconds>`;
# 0 disables the timeout (default: 3600)
TASK_TIMEOUT="${TASK_TIMEOUT:-3600}"
if ! [[ "${TASK_TIMEOUT}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: TASK_TIMEOUT must be a non-negative integer: ${TASK_TIMEOUT}" >&2
    exit 2
fi

# Set job runtime directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"
RUN_DIR="${PBS_O_WORKDIR:-${HOME}}/ollama-${PBS_JOBID:-manual}-run"
SERVER_LOG="${RUN_DIR}/ollama-server.log"
RENDERER_LOG="${RUN_DIR}/pvpython-renderer-mcp.log"
RAG_LOG="${RUN_DIR}/pvpython-rag-mcp.log"

# Compressed archive destination in the user's home directory; the model
# name is sanitized because Ollama tags may contain ':'
MODEL_SAFE="${MODEL//:/-}"
TARBALL="${HOME}/visknacks-ollama-${MODEL_SAFE}-${PBS_JOBID:-manual}.tar.gz"
ARCHIVED=0

# Specify Ollama local variables
BIND_HOST="127.0.0.1"
OLLAMA_PORT=""
OLLAMA_PID=""

# Specify MCP local variables
MCP_1_PORT=""
MCP_2_PORT=""
MCP_1_PID=""
MCP_2_PID=""
MCP_READY_TIMEOUT=120
PV_VERSION="5.13.3"
# --- End local script variables ---

# --- Load modulefiles ---
# Load conda environment
module use /soft/modulefiles
module load conda
conda activate VisKnacks
# --- End modulefiles ---

# --- Export shell variables ---
# Add Ollama and Ollama Models to the shell environment
export PATH="/eagle/EVITA/ollama/ollama/bin:$PATH"
export OLLAMA_MODELS="/eagle/EVITA/ollama-models"

# Keep the model resident between tasks instead of unloading after each
# request
export OLLAMA_KEEP_ALIVE="24h"

# Update network settings to allow for Ollama to connect to an outside port
export HTTPS_PROXY="http://proxy.alcf.anl.gov:3128"
export https_proxy="${HTTPS_PROXY}"
export NO_PROXY="127.0.0.1,localhost"
export no_proxy="${NO_PROXY}"
# --- End shell variables ---

# --- Define helper functions ---
# Stop a background process by PID
stop_pid() {
    local pid="$1"
    local name="$2"

    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
        echo "Stopping ${name} (PID ${pid})..."
        kill "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
    fi
}

# Compress the run directory into the user's home directory
archive_results() {
    echo "Archiving results to ${TARBALL}..."
    if tar -czf "${TARBALL}" \
        -C "$(dirname "${RUN_DIR}")" "$(basename "${RUN_DIR}")"; then
        ARCHIVED=1
        echo "Archive written: ${TARBALL}"
    else
        echo "ERROR: failed to write archive ${TARBALL}" >&2
    fi
}

# Kill Ollama service by PID
cleanup() {
    local status=$?

    stop_pid "${MCP_1_PID}" "pvpython-renderer-mcp"
    stop_pid "${MCP_2_PID}" "pvpython-rag-mcp"
    stop_pid "${OLLAMA_PID}" "Ollama server"

    if (( ARCHIVED == 0 )) && [[ -d "${RUN_DIR}" ]]; then
        archive_results
    fi

    exit "${status}"
}
trap cleanup EXIT INT TERM

# Find a free TCP port for the MCP and Ollama services
find_free_port() {
    local candidate

    for _ in $(seq 1 100); do
        candidate=$((20000 + RANDOM % 30000))

        if ! ss -ltn "sport = :${candidate}" | grep -q ":${candidate}"; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    echo "ERROR: Could not find an unused local TCP port after 100 attempts." >&2
    return 1
}

# Wait for an MCP server to accept HTTP connections on its port
wait_for_mcp() {
    local name="$1"
    local pid="$2"
    local port="$3"
    local log_file="$4"
    local _i

    for _i in $(seq 1 "${MCP_READY_TIMEOUT}"); do
        if ! kill -0 "${pid}" 2>/dev/null; then
            echo "ERROR: ${name} exited during startup. Log follows:" >&2
            cat "${log_file}" >&2 || true
            return 1
        fi

        if curl --silent --noproxy '*' \
            "http://${BIND_HOST}:${port}/" >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    echo "ERROR: ${name} did not become ready within ${MCP_READY_TIMEOUT} seconds." >&2
    echo "Log follows:" >&2
    cat "${log_file}" >&2 || true
    return 1
}

# Patch the benchmark opencode config with the dynamic service
# endpoints, and verify the requested model is in the allowlist
patch_opencode_config() {
    local config="${SCRIPT_DIR}/.opencode/opencode.json"

    if [[ ! -f "${config}" ]]; then
        echo "ERROR: opencode config not found: ${config}" >&2
        return 1
    fi

    python3 - "${config}" \
        "${MCP_1_PORT}" "${MCP_2_PORT}" "${OLLAMA_PORT}" "${MODEL}" \
        <<'PYEOF'
import json
import os
import sys

config, mcp1_port, mcp2_port, ollama_port, model = sys.argv[1:6]

try:
    with open(config) as f:
        cfg = json.load(f)
    cfg["mcp"]["pvpython-renderer-mcp"]["url"] = (
        f"http://localhost:{mcp1_port}/mcp"
    )
    cfg["mcp"]["pvpython-rag-mcp"]["url"] = (
        f"http://localhost:{mcp2_port}/mcp"
    )
    cfg["provider"]["ollama"]["options"]["baseURL"] = (
        f"http://localhost:{ollama_port}/v1"
    )
    models = sorted(cfg["provider"]["ollama"]["models"])
except (OSError, ValueError, KeyError, TypeError) as exc:
    print(
        f"ERROR: unexpected structure in opencode config {config}: {exc}",
        file=sys.stderr,
    )
    sys.exit(1)

if model not in models:
    available = "\n".join(f"  - {m}" for m in models)
    print(
        f"ERROR: model '{model}' is not in the opencode allowlist.\n"
        "Edit benchmark/.opencode/opencode.json on Eagle to add it "
        "under provider.ollama.models. Available models:\n"
        f"{available}",
        file=sys.stderr,
    )
    sys.exit(1)

tmp = f"{config}.tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=4)
    f.write("\n")
os.replace(tmp, config)
PYEOF

    echo "Patched ${config}:"
    echo "  pvpython-renderer-mcp -> http://localhost:${MCP_1_PORT}/mcp"
    echo "  pvpython-rag-mcp      -> http://localhost:${MCP_2_PORT}/mcp"
    echo "  ollama baseURL        -> http://localhost:${OLLAMA_PORT}/v1"
    echo "  model                 -> ${MODEL}"
}
# --- End helper functions ---

# --- Tests for specific commands ---
# Test for pvpython-rag-mcp
if ! command -v pvpython-rag-mcp >/dev/null 2>&1; then
    echo "ERROR: pvpython-rag-mcp is not available in PATH." >&2
    exit 1
fi

# Test for pvpython-renderer-mcp
if ! command -v pvpython-renderer-mcp >/dev/null 2>&1; then
    echo "ERROR: pvpython-renderer-mcp is not available in PATH." >&2
    exit 1
fi

# Test for pvpython
if ! command -v pvpython >/dev/null 2>&1; then
    echo "ERROR: pvpython is not available in PATH." >&2
    exit 1
fi

# Test for opencode
if ! command -v opencode >/dev/null 2>&1; then
    echo "ERROR: opencode is not available in PATH." >&2
    exit 1
fi

# Test for Ollama
if ! command -v ollama >/dev/null 2>&1; then
    echo "ERROR: ollama is not available in PATH." >&2
    echo "Expected installation directory: /eagle/EVITA/ollama/ollama/bin" >&2
    exit 1
fi

# Test for Ollama Model directory
if [[ ! -d "${OLLAMA_MODELS}" ]]; then
    echo "ERROR: Ollama model directory does not exist: ${OLLAMA_MODELS}" >&2
    exit 1
fi

# Test for the pvpython-rag index directory
if [[ ! -d "${PVPYTHON_DATA}" ]]; then
    echo "ERROR: RAG index directory does not exist: ${PVPYTHON_DATA}" >&2
    exit 1
fi

# Test for the pvpython-rag index and metadata files
if [[ ! -f "${PVPYTHON_DATA}/index_v${PV_VERSION}.faiss" ]] \
    || [[ ! -f "${PVPYTHON_DATA}/metadata_v${PV_VERSION}.json" ]]; then
    echo "ERROR: RAG index or metadata file missing in ${PVPYTHON_DATA}." >&2
    echo "Expected: index_v${PV_VERSION}.faiss and metadata_v${PV_VERSION}.json" >&2
    exit 1
fi

# Test for curl
if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is not available in the current environment." >&2
    exit 1
fi

# Test for ss
if ! command -v ss >/dev/null 2>&1; then
    echo "ERROR: ss is not available; cannot safely check candidate ports." >&2
    exit 1
fi

# Test for timeout (per-task opencode guard)
if ! command -v timeout >/dev/null 2>&1; then
    echo "ERROR: timeout is not available in the current environment." >&2
    exit 1
fi

# Test for the benchmark data directory and collect the task list
if [[ ! -d "${DATA_DIR}" ]]; then
    echo "ERROR: benchmark data directory not found: ${DATA_DIR}" >&2
    echo "hint: stage the benchmark data under benchmark/data on Eagle" >&2
    exit 1
fi

mapfile -t ALL_TASKS < <(
    find "${DATA_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
)

if ((${#ALL_TASKS[@]} == 0)); then
    echo "ERROR: no task directories under ${DATA_DIR}" >&2
    exit 1
fi

if [[ "${NUM_TASKS}" == "all" || "${NUM_TASKS}" == "0" ]]; then
    TASKS=("${ALL_TASKS[@]}")
else
    TASKS=("${ALL_TASKS[@]:0:${NUM_TASKS}}")
fi
# --- End tests ---

# --- Find three distinct free ports ---
# find_free_port binds nothing, so re-pick to avoid collisions between
# our own candidates
mkdir -p "${RUN_DIR}"
MCP_1_PORT="$(find_free_port)"
while :; do
    MCP_2_PORT="$(find_free_port)"
    if [[ "${MCP_2_PORT}" != "${MCP_1_PORT}" ]]; then
        break
    fi
done
while :; do
    OLLAMA_PORT="$(find_free_port)"
    if [[ "${OLLAMA_PORT}" != "${MCP_1_PORT}" ]] \
        && [[ "${OLLAMA_PORT}" != "${MCP_2_PORT}" ]]; then
        break
    fi
done
API_BASE="http://${BIND_HOST}:${OLLAMA_PORT}"
# --- End ports ---

# --- Patch the opencode config (also validates the model allowlist) ---
patch_opencode_config

echo "Host: $(hostname)"
echo "Started: $(date --iso-8601=seconds)"
echo "PBS job ID: ${PBS_JOBID:-not-set}"
echo "Model: ${MODEL}"
echo "Num tasks: ${NUM_TASKS}"
echo "Force re-run: ${FORCE}"
echo "Task timeout: ${TASK_TIMEOUT}s"
echo "Ollama listener: ${API_BASE}"
echo "Ollama models directory: ${OLLAMA_MODELS}"
echo "RAG index directory: ${PVPYTHON_DATA}"
echo "Run directory: ${RUN_DIR}"

# --- Start pvpython-renderer-mcp (MCP 1) ---
echo "Starting pvpython-renderer-mcp on port ${MCP_1_PORT}..."
pvpython-renderer-mcp \
    --server "${BIND_HOST}" \
    --port "${MCP_1_PORT}" \
    >"${RENDERER_LOG}" 2>&1 &
MCP_1_PID=$!

if ! wait_for_mcp \
    "pvpython-renderer-mcp" \
    "${MCP_1_PID}" \
    "${MCP_1_PORT}" \
    "${RENDERER_LOG}"; then
    exit 1
fi

echo "pvpython-renderer-mcp ready on ${BIND_HOST}:${MCP_1_PORT}"
# --- End MCP 1 ---

# --- Start pvpython-rag-mcp (MCP 2) ---
echo "Starting pvpython-rag-mcp on port ${MCP_2_PORT}..."
pvpython-rag-mcp \
    --host "${BIND_HOST}" \
    --port "${MCP_2_PORT}" \
    --pv-version "${PV_VERSION}" \
    --directory "${PVPYTHON_DATA}" \
    >"${RAG_LOG}" 2>&1 &
MCP_2_PID=$!

if ! wait_for_mcp \
    "pvpython-rag-mcp" \
    "${MCP_2_PID}" \
    "${MCP_2_PORT}" \
    "${RAG_LOG}"; then
    exit 1
fi

echo "pvpython-rag-mcp ready on ${BIND_HOST}:${MCP_2_PORT}"
# --- End MCP 2 ---

# --- Start Ollama server ---
# OLLAMA_HOST controls the address and port used by `ollama serve`.
export OLLAMA_HOST="${BIND_HOST}:${OLLAMA_PORT}"

echo "Starting Ollama server..."
ollama serve >"${SERVER_LOG}" 2>&1 &
OLLAMA_PID=$!

sleep 2
if ! kill -0 "${OLLAMA_PID}" 2>/dev/null; then
    echo "ERROR: Ollama exited during startup. Server log follows:" >&2
    cat "${SERVER_LOG}" >&2 || true
    exit 1
fi

echo "Waiting for Ollama API readiness..."
ready=0
for _ in $(seq 1 60); do
    if curl --silent --show-error --fail \
        --noproxy '*' \
        "${API_BASE}/api/tags" >/dev/null; then
        ready=1
        break
    fi

    sleep 1
done

if (( ready == 0 )); then
    echo "ERROR: Ollama API did not become ready within 60 seconds." >&2
    echo "Server log follows:" >&2
    cat "${SERVER_LOG}" >&2 || true
    exit 1
fi

# Do not pull models in this job. Require the requested model to already exist.
if ! OLLAMA_HOST="${BIND_HOST}:${OLLAMA_PORT}" ollama show "${MODEL}" >/dev/null 2>&1; then
    echo "ERROR: Required model is not available locally: ${MODEL}" >&2
    echo "This job is configured not to pull models." >&2
    echo "Expected model directory: ${OLLAMA_MODELS}" >&2
    exit 1
fi

echo "Verified local model: ${MODEL}"

# Warm the model into memory so the first task is not charged the load
# time. The request sets no keep_alive, so OLLAMA_KEEP_ALIVE keeps the
# model resident.
echo "Warming up ${MODEL} (model load)..."
curl --silent --show-error --fail \
    --noproxy '*' \
    -X POST "${API_BASE}/api/generate" \
    -H 'Content-Type: application/json' \
    -d "{
      \"model\": \"${MODEL}\",
      \"prompt\": \"Reply with OK.\",
      \"stream\": false
    }" \
    >/dev/null

echo "Warm-up complete: model resident."
# --- End Ollama server ---

# --- Run the SciVisAgentBench task matrix (adapted from benchmark.bash) ---
set +e
RESULTS_DIR="${RUN_DIR}/results"
MODELS=("ollama/${MODEL}")

total=$((${#MODELS[@]} * ${#TASKS[@]}))
run=0
failed=0
skipped=0

echo "Running ${#TASKS[@]} task(s) x ${#MODELS[@]} model(s) = $total run(s)"
echo "Results: $RESULTS_DIR"
echo

for model in "${MODELS[@]}"; do
    model_name="${MODEL_SAFE}"
    model_log="$RESULTS_DIR/$model_name/$model_name.log"
    mkdir -p "$RESULTS_DIR/$model_name"

    # Redirect all stdout+stderr for this model through tee into MODEL.log.
    # Use exec on a per-model fd rather than a subshell so that the failed/
    # skipped/run counters remain visible in the outer scope.
    exec 3>&1 4>&2
    exec > >(tee "$model_log") 2>&1

    for task in "${TASKS[@]}"; do
        run=$((run + 1))
        task_dir="$DATA_DIR/$task"
        task_file="$task_dir/task_description.txt"
        out_dir="$RESULTS_DIR/$model_name/$task"
        image="$out_dir/$task.png"

        printf '[%d/%d] %s / %s\n' "$run" "$total" "$model_name" "$task"

        if [[ ! -f "$task_file" ]]; then
            echo "  skip: no task_description.txt in $task_dir" >&2
            skipped=$((skipped + 1))
            continue
        fi

        if [[ -f "$image" && "$FORCE" != "1" ]]; then
            echo "  skip: $image already exists (FORCE=1 to re-run)"
            skipped=$((skipped + 1))
            continue
        fi

        mkdir -p "$out_dir"

        # The task descriptions hardcode relative input paths and
        # "<task>/results/{agent_mode}/..." output paths. Override both
        # with absolute paths rather than editing the task files.
        prompt="Execute this task.

The task's input data directory is $task_dir/ -- resolve every relative \
input path in the task description against that directory.

IGNORE the output paths given in the task description, including any \
{agent_mode} placeholder. Instead save the visualization image to \
$image, the ParaView state (if you produce one) to $out_dir/$task.pvsm, \
and the Python script (if you produce one) to $out_dir/$task.py. Write \
no other files."

        # Run from SCRIPT_DIR so opencode picks up ./.opencode (skill and
        # MCP server configuration).
        if (( TASK_TIMEOUT > 0 )); then
            (
                cd "$SCRIPT_DIR" || exit 1
                timeout "${TASK_TIMEOUT}" opencode run "$prompt" \
                    --file "$task_file" \
                    --model "$model" \
                    --agent build \
                    --auto
            ) 2>&1 | tee "$out_dir/run.log"
        else
            (
                cd "$SCRIPT_DIR" || exit 1
                opencode run "$prompt" \
                    --file "$task_file" \
                    --model "$model" \
                    --agent build \
                    --auto
            ) 2>&1 | tee "$out_dir/run.log"
        fi

        status="${PIPESTATUS[0]}"
        if ((status == 124)); then
            echo "  error: opencode timed out after ${TASK_TIMEOUT}s" >&2
            failed=$((failed + 1))
        elif ((status != 0)); then
            echo "  error: opencode exited $status" >&2
            failed=$((failed + 1))
        elif [[ ! -f "$image" ]]; then
            echo "  error: no image produced at $image" >&2
            failed=$((failed + 1))
        fi
    done

    # Restore stdout/stderr.
    exec 1>&3 3>&- 2>&4 4>&-
done
set -e
# --- End task matrix ---

# Allow the model-log tee to flush before archiving
sleep 2

archive_results

echo
echo "Done: $total run(s), $skipped skipped, $failed failed"
echo "Finished: $(date --iso-8601=seconds)"
echo "Archive: ${TARBALL}"
echo "Run directory: ${RUN_DIR}"
echo "Ollama server log: ${SERVER_LOG}"

((failed == 0))
