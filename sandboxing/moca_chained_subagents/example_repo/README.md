# example_repo (demo fixture)

Small Python fixture used by the `moca_chained_subagents` demo. The code
calls a deprecated API on a vendored stand-in library and the tests fail.
A migration guide lives under `docs/upstream-refs/` describing the rename.

The intended demo arc:

1. A **researcher** leaf diagnoses the failure by reading `src/`, `tests/`,
   `vendor/lib/__init__.py`, and `docs/upstream-refs/`.
2. A **fixer** leaf applies the one-line rename, runs the tests, and
   reports success.

Run tests locally with `python3 -m unittest discover -s tests` from this
directory. Stdlib-only — no `pip install` required.
