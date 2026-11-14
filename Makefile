SCRIPTS := preflight.sh pull-files.sh pull-db.sh fix-urls.sh compare.sh verify.sh lib/common.sh \
	tests/run.sh tests/helpers.sh $(wildcard tests/test_*.sh) $(wildcard tests/shims/*)

.PHONY: test lint syntax
test:
	bash tests/run.sh

lint:
	shellcheck -x $(SCRIPTS)

syntax:
	for f in $(SCRIPTS); do bash -n $$f || exit 1; done
