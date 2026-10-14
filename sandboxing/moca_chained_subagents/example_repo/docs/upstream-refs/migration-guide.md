# Migrating from lib v1 to v2

The single breaking change is the rename of `old_name` to `new_name`.

## Before (v1.x)

```python
from vendor import lib
lib.old_name('world')  # => 'hello, world'
```

## After (v2.x)

```python
from vendor import lib
lib.new_name('world')  # => 'hello, world'
```

That's it. No other API changed. If your test suite failed with
`AttributeError: module 'vendor.lib' has no attribute 'old_name'`
after upgrading to v2.0.0, this rename is the cause.
