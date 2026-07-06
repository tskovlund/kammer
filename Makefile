# Thin shims so the account-wide `make check` / `make test` muscle
# memory (tskovlund/.github conventions) works here; mix aliases in
# mix.exs remain the source of truth.

.PHONY: check test format

check:
	mix precommit

test:
	mix test

format:
	mix format
	npx prettier@3 --write .
