SKILL_SYSTEMS := agents claude kilo opencode
SKILL_TARGETS := $(addprefix package-,$(addsuffix -skills,$(SKILL_SYSTEMS)))

build: $(SKILL_TARGETS)

download-benchmark:
	mkdir -p benchmark/scivisagentbench
	hf download  SciVisAgentBench/SciVisAgentBench-tasks \
		--repo-type dataset \
		--local-dir benchmark/scivisagentbench

$(SKILL_TARGETS): package-%-skills:
	rm -rf build/.$*/skills
	mkdir -p build/.$*/skills
	find skills/ -maxdepth 1 -mindepth 1 -type d -exec cp -r {} build/.$*/skills/ \;
