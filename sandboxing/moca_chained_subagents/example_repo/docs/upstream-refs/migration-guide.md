# Migrating from lib v1 to v2

The single breaking change is the rename of `oldName` to `newName`.

## Before (v1.x)

```js
const lib = require('lib');
lib.oldName('world'); // => 'hello, world'
```

## After (v2.x)

```js
const lib = require('lib');
lib.newName('world'); // => 'hello, world'
```

That's it. No other API changed. If your test suite failed with
`TypeError: lib.oldName is not a function` after upgrading to v2.0.0,
this rename is the cause.
