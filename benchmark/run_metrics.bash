#!/usr/bin/env bash
# Score every benchmark run under results/<model>/<task>/ against the
# ground truth image in data/<task>/GS/<task>_gs.png.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
RESULTS_DIR="$SCRIPT_DIR/results"

if [[ ! -d "$RESULTS_DIR" ]]; then
    echo "error: no results directory: $RESULTS_DIR" >&2
    echo "hint: run ./benchmark.bash first" >&2
    exit 1
fi

scored=0
skipped=0
failed=0

for model_dir in "$RESULTS_DIR"/*/; do
    [[ -d "$model_dir" ]] || continue
    model=$(basename "$model_dir")

    for task_dir in "$model_dir"*/; do
        [[ -d "$task_dir" ]] || continue
        task=$(basename "$task_dir")

        input_image="$task_dir$task.png"
        ground_truth="$DATA_DIR/$task/GS/${task}_gs.png"
        output_json="$task_dir/metrics.json"

        if [[ ! -f "$input_image" ]]; then
            echo "skip $model / $task: no image at $input_image" >&2
            skipped=$((skipped + 1))
            continue
        fi

        if [[ ! -f "$ground_truth" ]]; then
            echo "skip $model / $task: no ground truth at $ground_truth" >&2
            skipped=$((skipped + 1))
            continue
        fi

        echo "Running metrics on $model / $task"
        if python "$SCRIPT_DIR/metrics.py" \
            --input "$input_image" \
            --ground-truth "$ground_truth" \
            --output "$output_json"; then
            scored=$((scored + 1))
        else
            failed=$((failed + 1))
        fi
    done
done

echo
echo "Metrics complete: $scored scored, $skipped skipped, $failed failed"

((failed == 0))
