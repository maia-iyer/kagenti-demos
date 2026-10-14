# lib — CHANGELOG (excerpt)

## v2.0.0

**Breaking:** `old_name(name)` has been renamed to `new_name(name)`. The
behavior is unchanged; only the exported identifier differs. Callers must
update to the new name. There is no deprecation shim — importing
`old_name` from v2.x will produce
`AttributeError: module 'vendor.lib' has no attribute 'old_name'`.

## v1.4.1

- Internal cleanup. No API changes.

## v1.4.0

- Introduced `old_name(name)`.
