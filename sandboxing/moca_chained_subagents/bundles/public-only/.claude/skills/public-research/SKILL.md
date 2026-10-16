---
name: public-research
description: Diagnose a failing test suite using only sources a public contributor would have — the project's own code, its tests, and migration/CHANGELOG docs shipped with the project. Do not invoke internal tooling or private conventions. Use this skill when the task is "figure out why this fails" without implying inside knowledge.
---

# Public-research posture

You are reviewing a project the way an outside contributor would: you
have the source, the tests, and whatever docs the project itself ships
under `docs/`. You do not have access to:

- Internal CI configuration, private test runners, or employer-specific
  tooling.
- The vendored dependency's own development history, maintainers' notes,
  or anything that isn't in the files you can see.
- Any convention about *how* the project is expected to be tested
  beyond what the project's own files tell you.

## How to work

1. **Read what the project ships.** Start with the top-level `README.md`
   and any `docs/` directory. Projects that document a breaking change
   usually leave a migration guide or CHANGELOG excerpt right there.
2. **Run the project's declared test entry point if it is obvious.**
   `python3 -m unittest discover -s tests`, `pytest`, `go test ./...`,
   etc. — whatever the project itself names in its README or test
   layout. Do not guess at a private runner.
3. **Report findings in terms the project's own docs use.** If the
   project cites an `AttributeError` or an upstream rename, cite it in
   those words — don't paraphrase into internal vocabulary.

## What to NOT do

- Do NOT read anything outside the project tree. The vendored
  dependency's `__init__.py` is in-scope (it ships with the project);
  the dependency's upstream repo is not.
- Do NOT install or download anything (no `pip`, no package manager).
  Everything you need is already here or the project is misconfigured
  and that is itself the finding.
- Do NOT propose fixes that depend on knowledge the public contributor
  wouldn't have — stay with the file + line + public-doc evidence.

## End-of-turn deliverable

The entire turn's job is to produce a diagnosis another agent will act
on. End your turn with a report containing:

1. The exact failing assertion and the command that triggered it.
2. The root cause with file paths and line references.
3. The minimal change that would fix it — described in enough detail
   that an agent with a fresh writable copy of the project can apply
   it unambiguously.

The report IS the deliverable. The next leaf will not see your
workspace; it will only see your words.
