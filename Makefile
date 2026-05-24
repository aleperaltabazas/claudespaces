.PHONY: install install-dev test

install:
	pipx install .

install-dev:
	pipx install . --suffix=-dev --force

test:
	.venv/bin/pytest
