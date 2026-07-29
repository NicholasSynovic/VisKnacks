#!/usr/bin/env bash
# Run metrics for all datasets and models

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"

# Iterate through each dataset directory
for dataset_dir in "$DATA_DIR"/*/; do
    dataset=$(basename "$dataset_dir")
    results_dir="$dataset_dir/results"
    ground_truth="$results_dir/${dataset}_gs.png"

    # Iterate through each model directory
    for model_dir in "$results_dir"/*/; do
        model=$(basename "$model_dir")
        input_image="$model_dir/${dataset}.png"
        output_json="$model_dir/metrics.json"

        echo "Running metrics on $dataset / $model"
        python "$SCRIPT_DIR/metrics.py" \
            --input "$input_image" \
            --ground-truth "$ground_truth" \
            --output "$output_json"
    done
done

echo "Benchmark complete!"
