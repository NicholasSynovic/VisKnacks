# VisKnacks Agents

> OpenCode subagents that offload focused subtasks from the main skill workflow.

## About

Agents in this directory are OpenCode **subagents** — isolated assistants
invoked via the `Task` tool with a specific `subagent_type`. They handle a
narrow, well-defined step so the calling skill can stay focused on code
generation.

All agents here are **tools-denied by design**: they process text only and
cannot read files, run shell commands, or call other agents. This is
intentional — granting tools would widen their attack surface without adding
value for their specific roles.

## paraview-prompt-formatter

**File:** `paraview-prompt-formatter.md`
**Mode:** `subagent`

Transforms a casual or vague natural-language scientific visualization request
into a precise, flat-prose ParaView prompt that a downstream script generator
(`paraview-coder`) can execute without ambiguity.

### When it is triggered

- The user's visualization request is conversational, vague, or incomplete.
- File paths (input data file or output screenshot) are missing.
- The `paraview-coder` skill is invoked — it always calls this agent first.

### Blocking behavior

The agent **will not emit a final prompt** until it has both:

1. **Input data file path** — the dataset to read.
2. **Output screenshot file path** — where the result image is saved.

If either is missing it asks the user and waits. It never invents paths.

### Output format

```
Please generate a ParaView Python script for the following operations.
Read in the file named {input_path}.
<one imperative line per operation, in pipeline order>
Save a screenshot of the result in the filename {output_path}.
The rendered view and saved screenshot should be 1920 x 1080 pixels.
```

An optional `Notes:` block is appended only to flag assumptions or unresolved
ambiguities. It is omitted when there is nothing to note.

### Term mappings

The agent maps casual language to ParaView operations:

| User term                            | ParaView operation      |
| ------------------------------------ | ----------------------- |
| slice / cross-section / cut          | Slice                   |
| isosurface / contour / level set     | Contour                 |
| streamlines / flow lines / pathlines | StreamTracer            |
| arrows / vectors / direction         | Glyph                   |
| see inside / transparency            | Clip or opacity         |
| speed / velocity magnitude           | magnitude of the vector |
| color by / colored                   | array coloring          |
| threshold / filter out               | Threshold               |

All concrete values (file paths, numeric thresholds, array names, axis
directions, color names) are preserved verbatim — never paraphrased or
substituted.

### Permissions

All tool access is denied. This agent processes text only.

| Tool        | Permission |
| ----------- | ---------- |
| `bash`      | deny       |
| `read`      | deny       |
| `edit`      | deny       |
| `glob`      | deny       |
| `grep`      | deny       |
| `webfetch`  | deny       |
| `task`      | deny       |
| `websearch` | deny       |
| `lsp`       | deny       |
| `skill`     | deny       |
