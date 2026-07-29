.PHONY: build create-dev
build:
	# Write agents to OpenCode
	mkdir -p build/.opencode/agents
	find agents/ -type f -not -name "README.md" -exec cp {} build/.opencode/agents/ \;

	# mkdir -p build/.opencode/skills
	# mkdir -p build/dist
	# cp opencode.json.template build/.opencode/opencode.json
	# cp -r $(wildcard skills/*/) build/.opencode/skills/
	# uv build --project mcp/paraview-exec-mcp --out-dir build/dist
	#
create-dev:
	git submodule update --init --recursive
	pre-commit install

download-benchmark:
	mkdir -p benchmark/scivisagentbench
	hf download  SciVisAgentBench/SciVisAgentBench-tasks \
		--repo-type dataset \
		--local-dir benchmark/scivisagentbench

test:
	echo "test"
