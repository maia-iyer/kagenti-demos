const test = require('node:test');
const assert = require('node:assert');
const { greet } = require('../src/index.js');

test('greet produces a friendly greeting', () => {
  assert.strictEqual(greet('world'), 'hello, world');
});
