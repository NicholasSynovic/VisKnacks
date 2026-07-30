.PHONY: build create-dev
build:
	# Write OpenCode config
	mkdir -p build/.opencode
	cp opencode.json.template build/.opencode/opencode.json

	# Write agents to OpenCode
	mkdir -p build/.opencode/agents
	find agents/ -type f -not -name "README.md" -exec cp {} build/.opencode/agents/ \;

	# Write skills to OpenCode
	mkdir -p build/.opencode/skills
	find skills/ -maxdepth 1 -mindepth 1 -type d -exec cp -r {} build/.opencode/skills/ \;

	mkdir -p build/dist
	$(MAKE) -C mcp/pvpython-renderer build
	cp -r mcp/pvpython-renderer/dist build

download-benchmark:
	mkdir -p benchmark/scivisagentbench
	hf download  SciVisAgentBench/SciVisAgentBench-tasks \
		--repo-type dataset \
		--local-dir benchmark/scivisagentbench

test:
	echo "test"
