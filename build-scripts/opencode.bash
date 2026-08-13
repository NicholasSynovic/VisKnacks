#!/bin/bash

# Get script directory path
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Create directories
mkdir -p build/.opencode
mkdir build/.opencode/agents
mkdir build/.opencode/skills

# Copy OpenCode config to the config directory
cp "$SCRIPT_DIR/opencode.json.template" build/.opencode/opencode.json

# Copy agents to the agents directory
cp agents/paraview-prompt-formatter.md build/.opencode/agents/

# Copy skills to the agents directory
cp -r skills/paraview-coder build/.opencode/skills/
