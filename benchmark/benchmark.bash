#!/usr/bin/env bash
# Run the first NUM_TASKS SciVisAgentBench tasks against every model in
# MODELS, writing each run's artifacts to results/<model>/<task>/.
#
# Deliberately not `set -e`: one failing run must not abort the rest of
# the matrix.
#
# Environment:
#   FORCE=1       re-run tasks whose output image already exists
#   NUM_TASKS=n   number of tasks to run (default: all; 0 also runs every task)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
RESULTS_DIR="$SCRIPT_DIR/results"

MODELS=(
    argo/claudeopus5
    argo/claudehaiku45
    argo/claudesonnet5
    argo/gemini35flash
    argo/gpt5sol
    argo/gpt5terra
    argo/gpt5luna
)

NUM_TASKS="${NUM_TASKS:-all}"
FORCE="${FORCE:-0}"

if [[ ! -d "$DATA_DIR" ]]; then
    echo "error: data directory not found: $DATA_DIR" >&2
    echo "hint: run 'make download-benchmark' from the repo root" >&2
    exit 1
fi

# Collect task directories in sorted order, then take the first NUM_TASKS.
mapfile -t ALL_TASKS < <(
    find "$DATA_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
)

if ((${#ALL_TASKS[@]} == 0)); then
    echo "error: no task directories under $DATA_DIR" >&2
    exit 1
fi

if [[ "$NUM_TASKS" == "all" || "$NUM_TASKS" == "0" ]]; then
    TASKS=("${ALL_TASKS[@]}")
else
    TASKS=("${ALL_TASKS[@]:0:$NUM_TASKS}")
fi

total=$((${#MODELS[@]} * ${#TASKS[@]}))
run=0
failed=0
skipped=0

echo "Running ${#TASKS[@]} task(s) x ${#MODELS[@]} model(s) = $total run(s)"
echo "Results: $RESULTS_DIR"
echo

for model in "${MODELS[@]}"; do
    # Strip the provider prefix: argo-onsite/gpt55 -> gpt55
    model_name="${model##*/}"
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
        (
            cd "$SCRIPT_DIR" || exit 1
            opencode run "$prompt" \
                --file "$task_file" \
                --model "$model" \
                --agent build \
                --auto
        ) 2>&1 | tee "$out_dir/run.log"

        status="${PIPESTATUS[0]}"
        if ((status != 0)); then
            echo "  error: opencode exited $status" >&2
            failed=$((failed + 1))
        elif [[ ! -f "$image" ]]; then
            echo "  error: no image produced at $image" >&2
            failed=$((failed + 1))
        fi
    done

    # Restore stdout/stderr before moving to the next model.
    exec 1>&3 3>&- 2>&4 4>&-

    # Package this model's results and move to the Desktop.
    tarball="$SCRIPT_DIR/${model_name}.tar"
    tar -cf "$tarball" -C "$RESULTS_DIR" "$model_name"
    mv "$tarball" "$HOME/Desktop/MODEL.tar"
    echo "Tarball moved to $HOME/Desktop/MODEL.tar"
    rm -rf "$RESULTS_DIR"
done

echo
echo "Done: $total run(s), $skipped skipped, $failed failed"

((failed == 0))
