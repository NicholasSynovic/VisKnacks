.PHONY: build
build:
	mkdir -p build/.opencode/agents
	mkdir -p build/.opencode/skills
	cp agents/*.md build/.opencode/agents/
	cp -r $(wildcard skills/*/) build/.opencode/skills/

create-dev:
	pre-commit install
	conda env activate

download-benchmark:
	mkdir -p benchmark/scivisagentbench
	hf download  SciVisAgentBench/SciVisAgentBench-tasks \
		--repo-type dataset \
		--local-dir benchmark/scivisagentbench

test:
	echo "test"
