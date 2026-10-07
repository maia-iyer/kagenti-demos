# example_repo (demo fixture)

Small Node.js fixture used by the `moca_chained_subagents` demo. The code
calls a deprecated API on a vendored stand-in library and the tests fail.
A migration guide lives under `docs/upstream-refs/` describing the rename.

The intended demo arc:

1. A **researcher** leaf diagnoses the failure by reading `src/`, `test/`,
   `node_modules/lib/index.js`, and `docs/upstream-refs/`.
2. A **fixer** leaf applies the one-line rename, runs the tests, and
   reports success.

Run tests locally with `node --test test/index.test.js` from this directory.
