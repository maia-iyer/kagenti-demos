# lib — CHANGELOG (excerpt)

## v2.0.0

**Breaking:** `oldName(name)` has been renamed to `newName(name)`. The
behavior is unchanged; only the exported identifier differs. Callers must
update to the new name. There is no deprecation shim — importing
`oldName` from v2.x will produce `TypeError: lib.oldName is not a function`.

## v1.4.1

- Internal cleanup. No API changes.

## v1.4.0

- Introduced `oldName(name)`.
