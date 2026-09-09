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
# Set job runtime directories
RUN_DIR="${PBS_O_WORKDIR:-${HOME}}/ollama-${PBS_JOBID:-manual}-run"
SERVER_LOG="${RUN_DIR}/ollama-server.log"
RESPONSE_FILE="${RUN_DIR}/${MODEL}-response.json"

# Specify Ollama local variables
BIND_HOST="127.0.0.1"
PORT=""
OLLAMA_PID=""
# TODO: Parameterize this
PROMPT="hello world"

# Specify the ollama model to benchmark against via `-v OLLAMA_MODEL=`
MODEL="${OLLAMA_MODEL:-}"
if [[ -z "${MODEL}" ]]; then
    echo "ERROR: No model specified." >&2
    echo "Usage: qsub -v OLLAMA_MODEL=<model-name> qsub_ollama_test.pbs" >&2
    exit 2
fi
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
# Kill Ollama service by PID
cleanup() {
    local status=$?

    if [[ -n "${OLLAMA_PID}" ]] && kill -0 "${OLLAMA_PID}" 2>/dev/null; then
        echo "Stopping Ollama server (PID ${OLLAMA_PID})..."
        kill "${OLLAMA_PID}" 2>/dev/null || true
        wait "${OLLAMA_PID}" 2>/dev/null || true
    fi

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

mkdir -p "${RUN_DIR}"

PORT="$(find_free_port)"
API_BASE="http://${BIND_HOST}:${PORT}"

# OLLAMA_HOST controls the address and port used by `ollama serve`.
export OLLAMA_HOST="${BIND_HOST}:${PORT}"

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
if ! OLLAMA_HOST="${BIND_HOST}:${PORT}" ollama show "${MODEL}" >/dev/null 2>&1; then
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
