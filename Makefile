EXTENSION = supasession
EXTVERSION = $(shell grep default_version $(EXTENSION).control | sed "s/default_version = '\(.*\)'/\1/")

.PHONY: prepare docs test
prepare:
	make clean
	cp ${EXTENSION}.sql $(EXTENSION)--$(EXTVERSION).sql

clean:
	rm -f $(EXTENSION)--*.sql

docs:
	bash scripts/update-docs.sh

test:
	bash scripts/test.sh

print-%:
	@echo $($*)