SHELL  = /bin/sh
EMACS ?= emacs
BATCH  = $(EMACS) -Q --batch -L .

SRCS = parallel-path.el parallel-path-projectile.el

.PHONY: test compile lint clean

test:
	$(BATCH) -l test/parallel-path-test.el -f ert-run-tests-batch-and-exit

compile:
	$(BATCH) -f batch-byte-compile $(SRCS)

lint:
	$(BATCH) --eval "(checkdoc-file \"parallel-path.el\")"
	$(BATCH) --eval "(checkdoc-file \"parallel-path-projectile.el\")"

clean:
	rm -f *.elc test/*.elc
