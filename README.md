# VisKnacks

> OpenCode compatible scientific visualization agent (SciVisAgent) tooling for
> rendering scientific data on HPC

## Table of Contents

- [VisKnacks](#visknacks)
    - [Table of Contents](#table-of-contents)
    - [About](#about)
    - [Provided Tooling](#provided-tooling)
        - [Subagents](#subagents)
            - [`paraview-prompt-formatter`](#paraview-prompt-formatter)
        - [Agent Skills](#agent-skills)
            - [`paraview-coder`](#paraview-coder)
        - [MCP Services](#mcp-services)
            - [`pvpython-rag-mcp`](#pvpython-rag-mcp)
            - [`pvpython-renderer-mcp`](#pvpython-renderer-mcp)
    - [Installing](#installing)
        - [Dependencies](#dependencies)
    - [Contributing](#contributing)
    - [Benchmarking](#benchmarking)

## About

VisKnacks provides subagemts, agent skills, and MCP services for rendering data on high-performance computing resources using existing coding agent harnesses.

## Provided Tooling

VisKnacks provides

- subagents,
- agent skills, and
- model-context provider (MCP) services

for translating natural language prompts and scientific datasets into ParaView
visualizations.

### Subagents

Subagents allow the dispatching of individual jobs to seperate instances of LLMs with specific instructions. This enables workflows where ephemeral models with little to no context of the greater plan to operate on natural language and feed the results back to the parent model.

#### `paraview-prompt-formatter`

TODO: Add description of agents/paraview-prompt-formatter.md

### Agent Skills

#### `paraview-coder`

### MCP Services

#### `pvpython-rag-mcp`

#### `pvpython-renderer-mcp`

## Installing

### Dependencies

## Contributing

## Benchmarking
