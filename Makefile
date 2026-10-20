P := plugins/boxlite-agent-tooling
API_SHELL := $(P)/scripts/api-compatibility.sh \
  $(P)/.agents/hooks/preflight-commit-push.sh $(P)/.agents/hooks/cancel-verdict-audit.sh \
  $(P)/.agents/hooks/audit/preflight-commit-push.test.sh \
  $(P)/.agents/hooks/audit/run-commit-push-audit.test.sh \
  $(P)/.agents/lib/subagent.test.sh \
  $(P)/.githooks/pre-push $(P)/.githooks/githooks.test.sh

.PHONY: test\:subagent test\:verdict test\:architecture test\:parity test\:guidance test\:writing
.PHONY: test\:api-compatibility test\:plugin test\:api-lint test\:guidance-check

test\:subagent:
	bash $(P)/.agents/lib/subagent.test.sh

test\:verdict:
	bash $(P)/.agents/hooks/audit/run-verdict-audit.test.sh

test\:architecture:
	bash $(P)/architecture.test.sh

test\:parity:
	bash $(P)/host-parity.test.sh

test\:guidance:
	bash $(P)/scripts/sync-guidance.test.sh

test\:writing:
	bash $(P)/scripts/check-writing-ownership.sh .

test\:guidance-check:
	bash $(P)/scripts/sync-guidance.sh --check .

test\:api-compatibility:
	python3 -m unittest discover -s $(P)/tests -p 'test_api_compatibility*.py' -v $(API_TEST_ARGS)

test\:plugin:
	@find $(P) -type f -name '*.test.sh' -print | sort | while IFS= read -r suite; do \
	  case "$$suite" in *"$(TEST_FILTER)"*) ;; *) continue ;; esac; \
	  echo "Running $$suite"; bash "$$suite" || exit $$?; \
	done

test\:api-lint:
	@for script in $(API_SHELL); do bash -n "$$script" || exit $$?; done
	shellcheck -x -P SCRIPTDIR $(filter-out %.test.sh,$(API_SHELL))
	# Existing test fixtures intentionally contain shell source as literal strings.
	shellcheck -x -P SCRIPTDIR --severity=warning $(filter %.test.sh,$(API_SHELL))
	python3 -m py_compile $(P)/scripts/api-compatibility.py $(P)/.agents/lib/api_contract.py
