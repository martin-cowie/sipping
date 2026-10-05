PERL_FILES := bin/sipping $(shell find lib t -name '*.pm' -o -name '*.t')
LOCAL_BIN  := $(CURDIR)/local/bin
PERLCRITIC := $(or $(wildcard $(LOCAL_BIN)/perlcritic),perlcritic)
PERLTIDY   := $(or $(wildcard $(LOCAL_BIN)/perltidy),perltidy)

export PERL5LIB := $(CURDIR)/local/lib/perl5

.PHONY: deps test lint tidy run

deps:
	cpm install --with-test --with-develop

test:
	prove -l -It/lib -r t

lint:
	$(PERLCRITIC) $(PERL_FILES)
	@for file in $(PERL_FILES); do \
		$(PERLTIDY) --assert-tidy --standard-output $$file > /dev/null \
			|| { echo "$$file is not tidy: run make tidy"; exit 1; }; \
	done

tidy:
	$(PERLTIDY) --backup-and-modify-in-place --backup-file-extension=/ $(PERL_FILES)

run:
	perl bin/sipping $(ARGS)
