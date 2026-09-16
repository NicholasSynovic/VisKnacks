#!/bin/bash -l
#PBS -N visknacks_benchmark
#PBS -A EVITA
#PBS -q by-gpu
#PBS -l select=2
#PBS -l walltime=24:00:00
#PBS -l filesystems=home:eagle
#PBS -j oe

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

# Set job runtime directories
RUN_DIR="${PBS_O_WORKDIR:-${HOME}}/ollama-${PBS_JOBID:-manual}-run"
SERVER_LOG="${RUN_DIR}/ollama-server.log"
RESPONSE_FILE="${RUN_DIR}/${MODEL}-response.json"
RENDERER_LOG="${RUN_DIR}/pvpython-renderer-mcp.log"
RAG_LOG="${RUN_DIR}/pvpython-rag-mcp.log"

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

# TODO: Parameterize this
PROMPT="hello world"
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

# Kill Ollama service by PID
cleanup() {
    local status=$?

    stop_pid "${MCP_1_PID}" "pvpython-renderer-mcp"
    stop_pid "${MCP_2_PID}" "pvpython-rag-mcp"
    stop_pid "${OLLAMA_PID}" "Ollama server"

    exit "${status}"
}
trap cleanup EXIT INT TERM

# Find a free TCP port to set Ollama service to listen on
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
# --- End tests ---

# --- Find and start pvpython-renderer-mcp (MCP 1) port ---
mkdir -p "${RUN_DIR}"
MCP_1_PORT="$(find_free_port)"
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
# --- End MCP 1 port ---

# --- Find and start pvpython-rag-mcp (MCP 2) port ---
MCP_2_PORT="$(find_free_port)"
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
# --- End MCP 2 port ---


OLLAMA_PORT="$(find_free_port)"
API_BASE="http://${BIND_HOST}:${OLLAMA_PORT}"

# OLLAMA_HOST controls the address and port used by `ollama serve`.
export OLLAMA_HOST="${BIND_HOST}:${OLLAMA_PORT}"

mkdir -p "${RUN_DIR}"

echo "Host: $(hostname)"
echo "Started: $(date --iso-8601=seconds)"
echo "PBS job ID: ${PBS_JOBID:-not-set}"
echo "Model: ${MODEL}"
echo "Prompt: ${PROMPT}"
echo "Ollama listener: ${API_BASE}"
echo "Ollama models directory: ${OLLAMA_MODELS}"
echo "Run directory: ${RUN_DIR}"

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
echo "Sending prompt to ${MODEL}..."

curl --silent --show-error --fail \
    --noproxy '*' \
    -X POST "${API_BASE}/api/generate" \
    -H 'Content-Type: application/json' \
    -d "{
      \"model\": \"${MODEL}\",
      \"prompt\": \"${PROMPT}\",
      \"stream\": false,
      \"keep_alive\": 0
    }" \
    | tee "${RESPONSE_FILE}"

echo
echo "Finished: $(date --iso-8601=seconds)"
echo "Response JSON: ${RESPONSE_FILE}"
echo "Ollama server log: ${SERVER_LOG}"
