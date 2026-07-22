SHELL := /bin/bash
export SERVICE

.PHONY: preflight deploy status demo-failure demo-restore verify container-test destroy

preflight:
	bash scripts/preflight.sh

deploy:
	bash scripts/deploy.sh

status:
	bash scripts/status.sh

demo-failure:
ifeq ($(strip $(SERVICE)),)
	@echo "SERVICE is required (cassandra, zookeeper, or artemis)" >&2
	@exit 2
else
	bash scripts/demo-failure.sh
endif

demo-restore:
	bash scripts/demo-restore.sh

verify:
	go test -race ./...
	go vet ./...
	bash charts/twc-lab/tests/render_test.sh
	@shopt -s nullglob; \
		files=(scripts/*.sh scripts/tests/*.sh); \
		if (( $${#files[@]} == 0 )); then \
			echo "no shell scripts found to syntax-check" >&2; \
			exit 1; \
		fi; \
		bash -n "$${files[@]}"
	@test -f scripts/tests/operations_test.sh || { \
		echo "missing scripts/tests/operations_test.sh" >&2; \
		exit 1; \
	}
	bash scripts/tests/operations_test.sh

container-test:
	bash scripts/tests/container_test.sh

destroy:
	bash scripts/destroy.sh
