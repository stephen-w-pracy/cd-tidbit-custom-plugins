.PHONY: setup validate verify cleanup port-forward

setup:
	./scripts/setup.sh

validate:
	./scripts/validate-setup.sh

# Post-run: confirm setup.sh actually created every Harness resource.
verify:
	./scripts/verify-setup.sh

cleanup:
	./scripts/cleanup.sh

# Foreground port-forward to Dev (8080), QA (8081), Prod (8082), and Kanboard
# (8090). Auto-reconnects when pods rotate. Ctrl-C cleans them all up.
port-forward:
	./scripts/port-forward.sh
