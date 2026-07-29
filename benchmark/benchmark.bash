#!/bin/bash

MODELS=(argo-onsite/claudeopus48 argo-onsite/claudesonnet46 argo-onsite/gemini35flash argo-onsite/gpt55)
COMMAND="Execute this task"

for ((i = 0; i < ${#MODELS[@]}; i++)); do
    opencode run $COMMAND \
        --file bonsai/task_description.txt \
        --model ${MODELS[i]} \
        --agent build

    opencode run $COMMAND \
        --file carp/task_description.txt \
        --model ${MODELS[i]} \
        --agent build

    opencode run $COMMAND \
        --file engine/task_description.txt \
        --model ${MODELS[i]} \
        --agent build

    opencode run $COMMAND \
        --file tornado/task_description.txt \
        --model ${MODELS[i]} \
        --agent build
done
