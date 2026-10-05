const lib = require('lib');

function greet(name) {
  return lib.oldName(name);
}

module.exports = { greet };
